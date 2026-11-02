--!strict
--[[
	OfferFx — the ONE per-frame driver behind every animated UI decoration (ported from RoBeasts'
	UI/Economy/OfferFx, trimmed to the scheduler SellNukes needs).

	Purpose:
		Stud UI decorations move a little: window-header studs drift sideways, starbursts behind
		Robux offers spin, sunbursts behind reward icons turn, rainbow cards shimmer, buy buttons
		get a shine sweep. Many of these exist at once (HUD offers, every open card), most of them
		hidden most of the time, so all of them share this driver:

		- `OfferFx.register(animator)` adds a decoration's step function. ONE RunService.PreRender
		  connection steps every registered decoration that is ON SCREEN right now; it is
		  connected only while at least one is, so hidden decorations cost nothing per frame.
		- On screen = the root and every GuiObject above it Visible, its ScreenGui Enabled and in
		  a PlayerGui, and a positive area left after clipping by every ClipsDescendants ancestor
		  and the screen. One scanner thread (every OfferFxConfig.VisibilityCheckSeconds while
		  anything is registered) re-checks; owners can force a re-check (`handle.refresh()`) or
		  switch a decoration off (`handle.setEnabled(false)`); `OfferFx.batch(fn)` folds many
		  such switches into ONE re-check (the Shop's item animators on open / close).
		- Steps are throttled per graphics tier (`rates`): Low graphics parks motion (rate 0),
		  and Reduce Motion (Roblox's GuiService.ReducedMotionEnabled OR SellNukes' own
		  `settings.reducedMotion`, fed by UIController through setReducedMotion) parks every
		  animation. Decorations stay drawn, just still.
		- A failing step pauses only its own decoration (pcall + one warning).

	Performance budget: 1 PreRender connection (only while something animates on screen), 1
	scanner thread at 4 Hz (only while anything is registered), O(visible) property writes/frame,
	no Instance or table allocation per frame.

	Connects to: Shared/Config/OfferFxConfig, Shared/Util/OfferFxRules, Widgets/PanelBackdrop
	(header drift), Kit/StudUI (starburst / sunburst / rainbow / shine), Controllers/UIController
	(setReducedMotion).

	Example:
		local handle = OfferFx.register({
			root = burst,
			rates = OfferFxConfig.Starburst.Hz,
			step = function(_dt, elapsed) burst.Rotation = elapsed * 14 % 360 end,
		})
		trove:Add(handle.destroy)
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local OfferFxConfig = require(ReplicatedStorage.Shared.Config.OfferFxConfig)
local OfferFxRules = require(ReplicatedStorage.Shared.Util.OfferFxRules)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type Tier = OfferFxConfig.Tier

-- What a decoration registers.
export type Animator = {
	root: GuiObject, -- the visibility subject
	-- Called each (throttled) frame while on screen: seconds since the last step, seconds the
	-- decoration has been running in total (pauses while hidden, so it resumes smoothly).
	step: (dt: number, elapsed: number) -> (),
	rates: OfferFxConfig.PerTier?, -- most steps / s per tier (nil = every frame)
}

-- The owner's handle on a registered animator.
export type Handle = {
	setEnabled: (enabled: boolean) -> (), -- owner gate (default true)
	refresh: () -> (), -- re-check visibility now (and once more next frame)
	running: () -> boolean, -- enabled AND on screen AND motion allowed
	destroy: () -> (),
}

type Item = {
	animator: Animator,
	enabled: boolean,
	running: boolean,
	elapsed: number,
	accum: number,
	interval: number,
	dead: boolean,
	destroying: RBXScriptConnection?,
}

local OfferFx = {}

-- Fires () when the graphics tier or the reduce-motion preference changes.
OfferFx.Changed = Signal.new() :: Signal.Signal<>

local items: { Item } = {}
local renderConnection: RBXScriptConnection? = nil
local scanning = false
local tier: Tier = "High"
local reducedSetting = false
local watching = false
-- OfferFx.batch: nesting depth, and whether a handle asked for a re-check inside the batch.
local batchDepth = 0
local batchDirty = false
-- Forward declaration: re-checks every item now (assigned once `scan` exists).
local rescan: () -> () = function() end

--[[ The current graphics tier ("Low" | "Medium" | "High"; from Roblox's quality slider). ]]
function OfferFx.tier(): Tier
	return tier
end

--[[ True while motion is reduced (Roblox Reduce Motion or SellNukes settings.reducedMotion). ]]
function OfferFx.reducedMotion(): boolean
	return reducedSetting or GuiService.ReducedMotionEnabled
end

--[[
	Feeds SellNukes' own reduce-motion setting (profile.settings.reducedMotion). UIController
	calls this on every profile change; repeated equal values are ignored.
	Example: OfferFx.setReducedMotion(profile.settings.reducedMotion == true)
]]
function OfferFx.setReducedMotion(on: boolean)
	if on == reducedSetting then
		return
	end
	reducedSetting = on
	-- Re-gate every item at once (motion parks / resumes without waiting for the scanner).
	rescan()
	OfferFx.Changed:Fire()
end

-- Seconds between steps for an item under the current tier.
local function intervalFor(rates: OfferFxConfig.PerTier?): number
	return if rates ~= nil then OfferFxRules.stepInterval(rates, tier) else 0
end

-- Reads Roblox's graphics quality (client-only API, pcall: it can be unavailable in tests).
local function readTier(): Tier
	local ok, level = pcall(function(): number
		local settings = UserSettings():GetService("UserGameSettings")
		return settings.SavedQualityLevel.Value
	end)
	return OfferFxRules.tierFor(if ok then level else 0)
end

-- Starts listening to the quality slider and Roblox's Reduce Motion (once).
local function watchSettings()
	if watching then
		return
	end
	watching = true
	tier = readTier()
	pcall(function()
		local settings = UserSettings():GetService("UserGameSettings")
		settings:GetPropertyChangedSignal("SavedQualityLevel"):Connect(function()
			local newTier = readTier()
			if newTier == tier then
				return
			end
			tier = newTier
			for _, item in items do
				item.interval = intervalFor(item.animator.rates)
			end
			rescan()
			OfferFx.Changed:Fire()
		end)
	end)
	GuiService:GetPropertyChangedSignal("ReducedMotionEnabled"):Connect(function()
		rescan()
		OfferFx.Changed:Fire()
	end)
end

--[[
	True when `root` is really drawn somewhere on screen (see the module header). Walks the
	ancestors once; numbers only (OfferFxRules.clipRect), no allocation.
]]
local function isOnScreen(root: GuiObject): boolean
	if not root.Visible then
		return false
	end
	local position, size = root.AbsolutePosition, root.AbsoluteSize
	local x0, y0 = position.X, position.Y
	local x1, y1 = x0 + size.X, y0 + size.Y
	if not OfferFxRules.hasArea(x0, y0, x1, y1) then
		return false
	end
	local node: Instance? = root.Parent
	while node ~= nil do
		if node:IsA("GuiObject") then
			if not node.Visible then
				return false
			end
			if node.ClipsDescendants then
				local p, s = node.AbsolutePosition, node.AbsoluteSize
				x0, y0, x1, y1 = OfferFxRules.clipRect(x0, y0, x1, y1, p.X, p.Y, p.X + s.X, p.Y + s.Y)
				if not OfferFxRules.hasArea(x0, y0, x1, y1) then
					return false
				end
			end
		elseif node:IsA("ScreenGui") then
			if not node.Enabled or node:FindFirstAncestorOfClass("PlayerGui") == nil then
				return false
			end
			local p, s = node.AbsolutePosition, node.AbsoluteSize
			x0, y0, x1, y1 = OfferFxRules.clipRect(x0, y0, x1, y1, p.X, p.Y, p.X + s.X, p.Y + s.Y)
			return OfferFxRules.hasArea(x0, y0, x1, y1)
		elseif node:IsA("LayerCollector") then
			-- SurfaceGui / BillboardGui: no screen rect to clip against; Enabled decides.
			return node.Enabled
		end
		node = node.Parent
	end
	return false
end

-- Steps one item, pausing it (once, with a warning) if its step errors.
local function safeStep(item: Item, dt: number, elapsed: number)
	local ok, err = pcall(item.animator.step, dt, elapsed)
	if not ok then
		warn(`[OfferFx] decoration step failed; pausing it: {err}`)
		item.enabled = false
		item.running = false
	end
end

-- The single per-frame step (connected only while at least one item runs).
local function onPreRender(dt: number)
	for _, item in items do
		if item.running then
			local accum = item.accum + dt
			if accum >= item.interval then
				item.accum = 0
				item.elapsed += accum
				safeStep(item, accum, item.elapsed)
			else
				item.accum = accum
			end
		end
	end
end

local function updateConnection()
	local any = false
	for _, item in items do
		if item.running then
			any = true
			break
		end
	end
	if any and renderConnection == nil then
		renderConnection = RunService.PreRender:Connect(onPreRender)
	elseif not any and renderConnection ~= nil then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

-- Re-checks every item's visibility / motion permission and (dis)connects the step.
local function scan()
	local still = OfferFx.reducedMotion()
	for index = #items, 1, -1 do
		local item = items[index]
		if item ~= nil and not item.dead then
			local run = item.enabled and not still and item.interval < math.huge and isOnScreen(item.animator.root)
			if run ~= item.running then
				item.running = run
				item.accum = 0
			end
		end
	end
	updateConnection()
end

rescan = scan

-- The visibility scanner: one thread, alive only while anything is registered.
local function ensureScanner()
	if scanning then
		return
	end
	scanning = true
	task.spawn(function()
		while #items > 0 do
			scan()
			task.wait(OfferFxConfig.VisibilityCheckSeconds)
		end
		scanning = false
		updateConnection()
	end)
end

local function remove(item: Item)
	if item.dead then
		return
	end
	item.dead = true
	item.running = false
	local destroying = item.destroying
	item.destroying = nil
	if destroying ~= nil then
		destroying:Disconnect()
	end
	local index = table.find(items, item)
	if index ~= nil then
		table.remove(items, index)
	end
	updateConnection()
end

--[[
	Registers a decoration's animator with the shared driver (see module header). The item
	removes itself when its root is destroyed; call `destroy()` to remove it earlier.
	@param animator root + step (+ rates)
	@return Handle
]]
function OfferFx.register(animator: Animator): Handle
	watchSettings()
	local item: Item = {
		animator = animator,
		enabled = true,
		running = false,
		elapsed = 0,
		accum = 0,
		interval = intervalFor(animator.rates),
		dead = false,
		destroying = nil,
	}
	table.insert(items, item)
	item.destroying = animator.root.Destroying:Connect(function()
		remove(item)
	end)
	ensureScanner()

	local function refresh()
		if item.dead then
			return
		end
		if batchDepth > 0 then
			-- Inside OfferFx.batch: one re-check runs when the batch ends.
			batchDirty = true
			return
		end
		scan()
		-- AbsoluteSize / Position of a root laid out this frame settle on the next one.
		task.defer(function()
			if not item.dead then
				scan()
			end
		end)
	end

	return {
		setEnabled = function(enabled: boolean)
			if item.dead or item.enabled == enabled then
				return
			end
			item.enabled = enabled
			refresh()
		end,
		refresh = refresh,
		running = function(): boolean
			return item.running and not item.dead
		end,
		destroy = function()
			remove(item)
		end,
	}
end

--[[
	Runs `fn` with visibility re-checks deferred: every handle.setEnabled / handle.refresh inside
	it marks the driver dirty instead of scanning, and ONE scan (+ one next frame, for layouts
	settling) runs when the outermost batch ends. Use it to switch many decorations at once
	(the Shop toggles all its item animators on open / close) without O(n^2) scans.
	Errors inside `fn` still end the batch (and re-scan) before they propagate.
	@param fn the switching work
	Example:
		OfferFx.batch(function()
			for _, handle in handles do handle.setEnabled(false) end
		end)
]]
function OfferFx.batch(fn: () -> ())
	batchDepth += 1
	local ok, err = pcall(fn)
	batchDepth -= 1
	if batchDepth == 0 and batchDirty then
		batchDirty = false
		scan()
		task.defer(scan)
	end
	if not ok then
		error(err, 2)
	end
end

--[[
	Driver stats (Studio probes / tests): registered decorations, ones being stepped, and whether
	the single PreRender connection is live.
	Example: print(OfferFx.stats().running)
]]
function OfferFx.stats(): { registered: number, running: number, connected: boolean }
	local running = 0
	for _, item in items do
		if item.running then
			running += 1
		end
	end
	return { registered = #items, running = running, connected = renderConnection ~= nil }
end

return OfferFx
