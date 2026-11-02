--!strict
--[[
	GuiFade — fades a whole ScreenGui (or one GuiObject subtree) out and back in, without a
	CanvasGroup (ported from RoBeasts' HUD focus mode; Shared/Config/HudFocusConfig).

	Why not a CanvasGroup: GroupTransparency renders the group into an offscreen texture; a
	full-screen group per faded HUD screen would cost ~8 MB of texture each on a phone for the
	length of the fade. Instead the fade tweens the transparency properties of the visible
	elements themselves (BackgroundTransparency, TextTransparency, TextStrokeTransparency,
	ImageTransparency, UIStroke.Transparency) and puts every value back exactly afterwards:

		fade out: snapshot the real values → tween them to 1 → disable (ScreenGui.Enabled = false,
		          or Visible = false for a subtree) → restore the snapshot while hidden, so the
		          screen keeps its true state for when it shows again.
		fade in:  snapshot the real values (whatever the screen set while hidden) → set them to 1
		          → enable → tween back to the snapshot.

	A reversal mid-fade cancels the running fade (values restored at once) and starts the other
	direction. cancel() stops any fade and restores the snapshot (ScreenManager calls it whenever
	visibility changes for a reason other than focus: open / close / cinematic mode). Objects past
	HudFocusConfig.MaxFadeObjects skip the animation (instant).

	Input: a fading-out gui stays enabled only for the fade's length; once hidden it is disabled,
	so it takes no clicks, taps or gamepad selection (KB+M, Xbox and touch alike).

	Performance: one Tween per faded element, created only on a focus change (rare); no per-frame
	work; a single task.delay per fade ends it (no per-tween Completed connections).

	Connects to: UI/ScreenManager (focus visibility), Shared/Config/HudFocusConfig. Must not
	require ScreenManager (ScreenManager requires this module).

	Example:
		GuiFade.setShown(gui, false, 0.2) -- fades the HUD screen out, then disables it
		GuiFade.setShown(gui, true, 0.2)  -- enables it and fades it back in
		GuiFade.cancel(gui)               -- stop + restore (instant)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local HudFocusConfig = require(ReplicatedStorage.Shared.Config.HudFocusConfig)

export type Root = ScreenGui | GuiObject

-- One element's saved transparency values (property name → value).
type Saved = { [Instance]: { [string]: number } }
type Fade = { mode: "in" | "out", token: number, tweens: { Tween }, saved: Saved }

local GuiFade = {}

local fades: { [Instance]: Fade } = {}
local tokens = 0

-- Values at or above this count as already invisible (never tweened, never restored).
local INVISIBLE = 0.999

-- The transparency properties of `object` this module fades (by class).
local function propertiesOf(object: Instance): { string }?
	if object:IsA("UIStroke") then
		return { "Transparency" }
	elseif object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
		return { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" }
	elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
		return { "BackgroundTransparency", "ImageTransparency" }
	elseif object:IsA("ViewportFrame") then
		return { "BackgroundTransparency", "ImageTransparency" }
	elseif object:IsA("GuiObject") then
		return { "BackgroundTransparency" }
	end
	return nil
end

--[[
	The current, still-visible transparency values under `root` (root included when it is a
	GuiObject, whatever its own Visible: a fade in starts from a hidden root). Invisible
	descendants (Visible = false) and already-transparent values are skipped.
	@return the snapshot, or nil when it would exceed MaxFadeObjects (fade skipped)
]]
local function snapshot(root: Root): Saved?
	local saved: Saved = {}
	local count = 0
	local rootInstance: Instance = root
	local function take(object: Instance)
		if object ~= rootInstance and object:IsA("GuiObject") and not object.Visible then
			return
		end
		local properties = propertiesOf(object)
		if properties == nil then
			return
		end
		local values: { [string]: number }? = nil
		for _, property in properties do
			local value = (object :: any)[property] :: number
			if value < INVISIBLE then
				values = values or {}
				(values :: { [string]: number })[property] = value
			end
		end
		if values ~= nil then
			saved[object] = values
			count += 1
		end
	end
	if root:IsA("GuiObject") then
		take(root)
	end
	for _, object in root:GetDescendants() do
		take(object)
		if count > HudFocusConfig.MaxFadeObjects then
			return nil
		end
	end
	return saved
end

-- Writes `saved` back (objects destroyed meanwhile are skipped).
local function restore(saved: Saved)
	for object, values in saved do
		if object.Parent ~= nil then
			for property, value in values do
				(object :: any)[property] = value
			end
		end
	end
end

-- Shown state of `root` (ScreenGui.Enabled, GuiObject.Visible).
local function isShown(root: Root): boolean
	if root:IsA("ScreenGui") then
		return root.Enabled
	end
	return (root :: GuiObject).Visible
end

local function setRootShown(root: Root, shown: boolean)
	if root:IsA("ScreenGui") then
		root.Enabled = shown
	else
		(root :: GuiObject).Visible = shown
	end
end

--[[
	Stops any fade on `root` and restores the real values at once (Enabled / Visible untouched).
	Safe to call when nothing fades.
]]
function GuiFade.cancel(root: Instance)
	local fade = fades[root]
	if fade == nil then
		return
	end
	fades[root] = nil
	for _, tween in fade.tweens do
		tween:Cancel()
	end
	restore(fade.saved)
end

--[[
	Ends a running fade on `root` at once in its target state (fade out: hidden; fade in: shown)
	with the real values restored. Owner R79 nesting guard: the HUD fades a sub-layer (side
	columns while a menu is open) inside the HUD ScreenGui, which focus mode fades as a whole; two
	overlapping fades would snapshot each other's mid-tween transparencies and restore those as
	"real" (a half-invisible HUD). setShown finishes any running ancestor / descendant fade first.
]]
local function finish(root: Instance)
	local fade = fades[root]
	if fade == nil then
		return
	end
	fades[root] = nil
	for _, tween in fade.tweens do
		tween:Cancel()
	end
	if fade.mode == "out" and (root:IsA("ScreenGui") or root:IsA("GuiObject")) then
		setRootShown(root :: any, false)
	end
	restore(fade.saved)
end

--[[ True while `root` is fading (either direction). ]]
function GuiFade.isFading(root: Instance): boolean
	return fades[root] ~= nil
end

--[[
	Shows or hides `root` with a fade of `seconds` (see the header). Idempotent: asking for the
	state it is already in (or already fading to) does nothing.
	@param root    a ScreenGui (Enabled) or a GuiObject subtree (Visible)
	@param shown   the state to end in
	@param seconds fade length (≤ 0 → instant)
]]
function GuiFade.setShown(root: Root, shown: boolean, seconds: number)
	local running = fades[root]
	if running ~= nil then
		if running.mode == (if shown then "in" else "out") then
			return -- already heading there
		end
		GuiFade.cancel(root) -- reverse: drop the running fade (values restored)
	end
	if isShown(root) == shown then
		return
	end
	-- Nested fades (see finish): settle any fade running above or below this root first, so the
	-- snapshot below reads real values, never another fade's mid-tween ones.
	local nested: { Instance } = {}
	local self: Instance = root
	for other in fades do
		if other ~= self and (self:IsDescendantOf(other) or other:IsDescendantOf(self)) then
			table.insert(nested, other)
		end
	end
	for _, other in nested do
		finish(other)
	end
	local saved = if seconds > 0 then snapshot(root) else nil
	if saved == nil then
		setRootShown(root, shown) -- instant (no fade, or too big to fade)
		return
	end
	local info = TweenInfo.new(
		seconds,
		Enum.EasingStyle.Quad,
		if shown then Enum.EasingDirection.Out else Enum.EasingDirection.In
	)
	tokens += 1
	local token = tokens
	local fade: Fade = { mode = if shown then "in" else "out", token = token, tweens = {}, saved = saved }
	fades[root] = fade
	if shown then
		-- Start invisible, then reveal and tween each value back to what the screen set.
		for object, values in saved do
			for property in values do
				(object :: any)[property] = 1
			end
		end
		setRootShown(root, true)
	end
	for object, values in saved do
		local goal: { [string]: number } = {}
		for property, value in values do
			goal[property] = if shown then value else 1
		end
		local tween = TweenService:Create(object, info, goal)
		table.insert(fade.tweens, tween)
		tween:Play()
	end
	task.delay(seconds, function()
		if fades[root] ~= fade then
			return -- cancelled or replaced
		end
		fades[root] = nil
		if not shown then
			-- Hidden now: put the real values back for the next show. (A fade in needs nothing:
			-- its tweens end on exactly the snapshot, and rewriting it could undo a change the
			-- screen made during the fade.)
			-- Stop the tweens FIRST (QA 2026-10-30): this delay and the tweens share a length,
			-- so on a slow frame (the join loading screen) the tweens' final step can land
			-- after this callback and write 1 over the restored values. The next fade in then
			-- snapshots those 1s as "already invisible" and never shows them again — that left
			-- the whole HUD invisible after joining. Cancel() freezes the tweens; restore wins.
			for _, tween in fade.tweens do
				tween:Cancel()
			end
			setRootShown(root, false)
			restore(saved)
		end
	end)
end

return table.freeze(GuiFade)
