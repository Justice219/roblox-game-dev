--!strict
--[[
	PopupQueue — the client's ONE popup priority queue (owner R102: "sometimes UI will clip like
	this when it pops up, need a priority queue"). Presenters keep their look; only the WHEN and
	the WHERE go through here.

	Channels (PopupQueueConfig.Kinds):
		center  the ATTENTION lane, one popup at a time, highest priority first: plot reveal (a
		        hold) > flavour reveal > Happy Hour start > flavour shout > juice milestone. Lower
		        ones wait (maxWait, then expire), a higher one pre-empts (the lower resumes with its
		        full hold, or drops). Kinds wait while a menu window / a cinematic is up (no popup
		        under or around a window). Banners sit in the free band between the currency stack
		        and the objective chip / hint bar (`placeTop`); the flavour reveal (anchor "feed",
		        owner R108) is a card at the bottom of the FEED (`placeFeedCard`).
		chip    the Lucky Button arrow + the Happy Hours pill: hidden while a centre popup is up
		        (`chipsHidden`), never over the reserved bottom strip (`reservedRects`); the moving
		        arrow also steers around the other chips' published rects (`chipRects`).
		feed    the bottom-left column (owner R108 + R111): UI/Hud/Toasts stacks every toast and the
		        Big Pop pills there (newest at the bottom) and asks `feedArea` where it may live: clear
		        of the left grid, the objective chip, the hint bar (HudZones "Hints"), a centre popup,
		        the touch thumbstick / jump reserve and any open window (`windowRect`); pill sizes
		        come from `pillMetrics` (phones: >= 14 pt text). The reveal card sits under the pills.
	The pure rules (ordering, pre-emption, expiry, replacement, band maths) are PopupQueueLogic
	(tests/popup-queue.luau) and the feed's are FeedLogic (tests/popup-feed.luau); this module adds
	the clock, the gates, the live measurements and the presenter callbacks.

	Performance: no per-frame work. ONE delayed task armed for the next deadline (a hold ending, a
	wait expiring), re-armed after every change; gates are re-checked on ScreenManager Opened /
	Closed / FocusChanged and, only while a popup waits on a presenter predicate, every
	PopupQueueConfig.PollSeconds. The band is recomputed on demand (zones are cheap reads) and the
	shown popup is re-placed on HudZones / layout / currency-stack size changes (coalesced).

	Robustness: presenter callbacks run in pcall (a broken presenter never jams the lane); a
	presenter-driven popup that never reports done is ended after its maxShow.

	Connects to: UI/Widgets/{PopupQueueLogic, FeedLogic, HudZones, HudPlacement (touch reserve)},
	UI/ScreenManager, UI/Hud/HudCurrency (the measured stack), Platform/LayoutLogic (jump rect),
	Shared/Config/{PopupQueueConfig, PlatformConfig}, Shared/Util/{Signal, TouchLayout}; presenters
	Tycoon/Fx/{BigPopBanner, JuiceBanner}, Tycoon/{FlavorController, PlotReveal, YouMarker},
	HappyHour/HappyHourClient, UI/Hud/Toasts, UI/Screens/{FlavorReveal, LuckyButtons/LuckyArrowScreen,
	HappyHour/HappyHourChipScreen}, Worlds/WorldClient (polite moments wait for the centre lane).

	Example (a queue-timed banner):
		local handle = PopupQueue.request({
			kind = "juice",
			seconds = 2.4,
			height = 196,
			show = function(slot)
				card.Position = UDim2.new(0.5, 0, 0, slot.top(196) + 98)
				card.Visible = true
			end,
			hide = function(_reason) card.Visible = false end,
		})
	Example (presenter-driven, ends itself): handle.done() when the screen closed.
	Example (a hold): local release = PopupQueue.hold("plotReveal", 170) ... release()
	Example (the feed): local area = PopupQueue.feedArea(112) --> { x, top, bottom, width, ... }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FeedLogic = require(script.Parent.FeedLogic)
local HudCurrency = require(script.Parent.Parent.Hud.HudCurrency)
local HudPlacement = require(script.Parent.HudPlacement)
local HudZones = require(script.Parent.HudZones)
local LayoutLogic = require(script.Parent.Parent.Parent.Platform.LayoutLogic)
local Logic = require(script.Parent.PopupQueueLogic)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local PopupQueueConfig = require(ReplicatedStorage.Shared.Config.PopupQueueConfig)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)

export type Rect = Logic.Rect
export type Band = Logic.Band
export type FeedArea = FeedLogic.Area
export type PillMetrics = FeedLogic.PillMetrics

-- What a presenter gets when its turn comes.
export type Slot = {
	id: number,
	kind: string,
	resumed: boolean, -- true when it comes back after a pre-emption
	-- The design-px top y for a card of `height` in this kind's anchor (records the rect toasts
	-- avoid). Call it at show and from `place`.
	top: (height: number) -> number,
}

export type Spec = {
	kind: string, -- PopupQueueConfig.Kinds key ("center" channel)
	seconds: number?, -- queue-timed hold; nil = presenter-driven (call handle.done())
	group: string?, -- same group replaces (default: the kind)
	rank: number?, -- a newer same-group popup replaces only when its rank is >= (default 0)
	height: number?, -- design px card height (the rect toasts avoid before `top` is called)
	maxShow: number?, -- presenter-driven cap (default PopupQueueConfig.MaxShowSeconds)
	force: boolean?, -- a hold: shows at once, skips the menu / cinematic gates
	canShow: (() -> boolean)?, -- extra presenter gate (e.g. no tutorial step)
	show: (slot: Slot) -> boolean?, -- draw now; return false when it cannot (it is then dropped)
	hide: ((reason: string) -> ())?, -- stop drawing ("done" | "timeout" | "preempted" | "replaced" | "cancelled")
	place: ((slot: Slot) -> ())?, -- re-place while shown (HUD zones / layout changed)
	onExpire: (() -> ())?, -- waited past maxWait without ever showing
}

export type Handle = {
	id: number,
	done: () -> (), -- the presenter finished (no hide callback)
	cancel: () -> (), -- withdraw it (hide callback when it is on screen)
	showing: () -> boolean,
}

type Record = { spec: Spec, slot: Slot, showing: boolean }

local Kinds = PopupQueueConfig.Kinds :: { [string]: PopupQueueConfig.KindDef }

local PopupQueue = {}

-- Fires (what) after the centre lane changed ("center"), the free band / HUD zones / an open window
-- moved ("band") or the feed's reveal card came / went ("feed").
PopupQueue.Changed = Signal.new() :: Signal.Signal<string>

local state = Logic.new()
local records: { [number]: Record } = {}
local pending: { Logic.Action } = {}
local processing = false
local wakeToken = 0
local started = false
local activeRect: Rect? = nil -- design px rect of the centre popup on screen
local lastActiveId = 0
local bandDirty = false
local chipRectsByKind: { [string]: Rect } = {}
local counters = { requested = 0, shown = 0, preempted = 0, resumed = 0, expired = 0, dropped = 0, replaced = 0 }
local requesting: Spec? = nil -- the spec PopupQueueLogic.request is queuing right now
local stackFrame: GuiObject? = nil
local stackConnection: RBXScriptConnection? = nil
local feedCardRect: Rect? = nil -- the reveal card at the bottom of the feed (design px)
local feedCardArea: FeedArea? = nil -- the column it was placed in
local Feed = PopupQueueConfig.Feed

local function now(): number
	return os.clock()
end

--------------------------------------------------------------------------------------------------
-- Zones + band
--------------------------------------------------------------------------------------------------

-- The HUD's currency stack frame (the "Currency" ancestor of HudCurrency's boost corner), or nil
-- before the HUD is built. Watched for size changes (a world's taller stack, an event row).
local function stack(): GuiObject?
	local current = stackFrame
	if current ~= nil and current.Parent ~= nil then
		return current
	end
	local corner = HudCurrency.corner()
	local found = if corner ~= nil then corner:FindFirstAncestor("Currency") else nil
	if found == nil or not found:IsA("GuiObject") then
		return nil
	end
	stackFrame = found
	if stackConnection ~= nil then
		stackConnection:Disconnect()
	end
	stackConnection = found:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		PopupQueue.zonesChanged()
	end)
	return found
end

-- The measured stack's bottom edge in HUD design px (nil = unknown / hidden / not laid out).
local function measuredStackBottom(): number?
	local frame = stack()
	local container = if frame ~= nil then frame.Parent else nil
	if frame == nil or container == nil or not container:IsA("GuiObject") or not frame.Visible then
		return nil
	end
	local scale = math.max(ScreenManager.scale, 0.01)
	if frame.AbsoluteSize.Y <= 0 then
		return nil
	end
	return (frame.AbsolutePosition.Y + frame.AbsoluteSize.Y - container.AbsolutePosition.Y) / scale
end

-- The hint bar's rect while it shows (Platform/HintBar publishes HudZones "Hints").
local function hintsZone(): Rect?
	return HudZones.rect("Hints")
end

-- Every zone the band reads.
local function zones(): Logic.Zones
	return {
		top = HudZones.rect("Top"),
		topRight = HudZones.rect("TopRight"),
		boosts = HudZones.rect("Boosts"),
		bottom = HudZones.rect("Bottom"),
		hints = hintsZone(),
		stackBottom = measuredStackBottom(),
	}
end

--[[
	The free band for centre popups and toasts right now (design px on the HUD canvas).
	@return Band — { top, bottom, known }
]]
function PopupQueue.band(): Band
	local canvas = ScreenManager.canvasSize(nil)
	return Logic.band(zones(), canvas.X, canvas.Y)
end

-- The rect a kind occupies at `top` (fill kinds own the whole canvas).
local function rectFor(kind: string, top: number, height: number): Rect
	local canvas = ScreenManager.canvasSize(nil)
	local def = Kinds[kind]
	if def ~= nil and def.anchor == "fill" then
		return { x = 0, y = 0, w = canvas.X, h = canvas.Y }
	end
	if def ~= nil and def.anchor == "feed" then
		-- Placed by placeFeedCard; until then it occupies nothing.
		return feedCardRect or { x = 0, y = 0, w = 0, h = 0 }
	end
	local width = PopupQueueConfig.Band.LaneWidth
	return { x = canvas.X / 2 - width / 2, y = top, w = width, h = height }
end

--[[
	The design-px top y of a `height`-tall card for `kind` (its anchor in the free band). When
	`kind` is the centre popup on screen, its rect is recorded for the toast / chip rules.
	@param kind PopupQueueConfig.Kinds key
	@param height number — design px
	@return number
	Example: card.Position = UDim2.new(0.5, 0, 0, PopupQueue.placeTop("juice", 196) + 98)
]]
function PopupQueue.placeTop(kind: string, height: number): number
	local def = Kinds[kind]
	local anchor: PopupQueueConfig.Anchor = if def ~= nil then def.anchor else "top"
	local top = Logic.place(PopupQueue.band(), height, anchor)
	local active = Logic.activeOf(state, "center")
	if active ~= nil and active.kind == kind then
		activeRect = rectFor(kind, top, height)
	end
	return top
end

--------------------------------------------------------------------------------------------------
-- Scheduling
--------------------------------------------------------------------------------------------------

-- The runtime gate (menus, cinematics, the presenter's own predicate).
local function gate(entry: Logic.Entry): boolean
	local def = Kinds[entry.kind]
	if def == nil then
		return false
	end
	if def.waitForModal and ScreenManager.anyModalOpen() then
		return false
	end
	if def.waitForFocus and ScreenManager.isFocusMode() then
		return false
	end
	local record = records[entry.id]
	local predicate = if record ~= nil then record.spec.canShow else nil
	-- The popup being queued right now has no record yet (it is the newest entry).
	local queuing = requesting
	if record == nil and queuing ~= nil and entry.id == state.seq then
		predicate = queuing.canShow
	end
	if predicate ~= nil then
		local ok, allowed = pcall(predicate)
		return ok and allowed == true
	end
	return true
end

local process: (actions: { Logic.Action }) -> ()

-- Runs one presenter callback safely (a broken presenter never jams the lane).
local function call(label: string, fn: any, ...: any): (boolean, any)
	local ok, result = pcall(fn, ...)
	if not ok then
		warn(`[PopupQueue] {label} failed: {result}`)
	end
	return ok, result
end

-- Performs one action (see PopupQueueLogic.Action).
local function perform(action: Logic.Action)
	local record = records[action.id]
	if record == nil then
		return
	end
	local spec = record.spec
	if action.op == "show" then
		counters.shown += 1
		if action.reason == "resumed" then
			counters.resumed += 1
		end
		record.showing = true
		record.slot.resumed = action.reason == "resumed"
		-- A first guess of its rect (the presenter's slot.top refines it with the real height).
		PopupQueue.placeTop(spec.kind, spec.height or 0)
		local ok, result = call(`show {spec.kind}`, spec.show, record.slot)
		if not ok or result == false then
			-- It could not draw: free the lane for the next one.
			record.showing = false
			records[action.id] = nil
			process(Logic.finish(state, action.id, now(), gate))
		end
	elseif action.op == "hide" then
		if action.reason == "preempted" then
			counters.preempted += 1
		elseif action.reason == "replaced" then
			counters.replaced += 1
		end
		record.showing = false
		if spec.hide ~= nil then
			call(`hide {spec.kind}`, spec.hide, action.reason)
		end
		if action.final then
			records[action.id] = nil
		end
	elseif action.op == "expire" then
		counters.expired += 1
		records[action.id] = nil
		if spec.onExpire ~= nil then
			call(`expire {spec.kind}`, spec.onExpire)
		end
	else
		counters.dropped += 1
		records[action.id] = nil
	end
end

-- Re-arms the single wake-up timer for the next deadline.
local function arm()
	wakeToken += 1
	local at = Logic.nextWake(state, now(), PopupQueueConfig.PollSeconds, gate)
	if at == nil then
		return
	end
	local mine = wakeToken
	-- A frame of slack so the step never lands a hair before the deadline.
	task.delay(math.max(0, at - now()) + 1 / 60, function()
		if mine == wakeToken then
			process(Logic.step(state, now(), gate))
		end
	end)
end

-- Performs actions in order (re-entrant calls append), then re-arms and announces changes.
process = function(actions: { Logic.Action })
	for _, action in actions do
		table.insert(pending, action)
	end
	if processing then
		return
	end
	processing = true
	while #pending > 0 do
		-- An unexpected error in one action must never leave the queue jammed in `processing`.
		local ok, err = pcall(perform, table.remove(pending, 1) :: Logic.Action)
		if not ok then
			warn(`[PopupQueue] action failed: {err}`)
		end
	end
	processing = false
	local active = Logic.activeOf(state, "center")
	if active == nil then
		activeRect = nil
	end
	arm()
	local activeId = if active ~= nil then active.id else 0
	if activeId ~= lastActiveId then
		lastActiveId = activeId
		PopupQueue.Changed:Fire("center")
	end
end

-- Re-checks the gates when a menu / cinematic opens or closes (only when something waits).
local function regate()
	if Logic.waitingCount(state, "center") > 0 then
		process(Logic.step(state, now(), gate))
	end
end

--[[
	Coalesces a zone / layout / stack change: re-places the shown popup and fires Changed("band")
	once on the next resumption point.
]]
function PopupQueue.zonesChanged()
	if bandDirty then
		return
	end
	bandDirty = true
	task.defer(function()
		bandDirty = false
		local active = Logic.activeOf(state, "center")
		local record = if active ~= nil then records[active.id] else nil
		if record ~= nil and record.showing and record.spec.place ~= nil then
			call(`place {record.spec.kind}`, record.spec.place, record.slot)
		end
		PopupQueue.Changed:Fire("band")
	end)
end

-- Connects the event sources once.
local function start()
	if started then
		return
	end
	started = true
	-- A window opening / closing re-gates the lane AND moves the feed (its gutter rule).
	ScreenManager.Opened:Connect(function()
		regate()
		PopupQueue.zonesChanged()
	end)
	ScreenManager.Closed:Connect(function()
		regate()
		PopupQueue.zonesChanged()
	end)
	ScreenManager.FocusChanged:Connect(regate)
	HudZones.Changed:Connect(PopupQueue.zonesChanged)
	ScreenManager.LayoutChanged:Connect(PopupQueue.zonesChanged)
	HudCurrency.Changed:Connect(PopupQueue.zonesChanged)
end

-- Withdraws a record (done = presenter finished; cancel = also hide it).
local function withdraw(id: number, hideIt: boolean)
	local record = records[id]
	if record == nil then
		return
	end
	records[id] = nil
	if hideIt and record.showing and record.spec.hide ~= nil then
		call(`hide {record.spec.kind}`, record.spec.hide, "cancelled")
	end
	record.showing = false
	process(Logic.finish(state, id, now(), gate))
end

--[[
	Asks for a slot (see Spec). The popup shows at once when its channel is free and its gates
	allow, else it waits its turn (or pre-empts a less important one).
	@param spec Spec
	@return Handle? — nil when the kind is unknown / not a queued channel / show is missing, or
	        when it was refused at once (outranked, or its presenter could not draw)
	Example: see the module header.
]]
function PopupQueue.request(spec: Spec): Handle?
	start()
	local def = if type(spec) == "table" and type(spec.kind) == "string" then Kinds[spec.kind] else nil
	if def == nil or def.channel ~= "center" or type(spec.show) ~= "function" then
		return nil
	end
	counters.requested += 1
	requesting = spec
	local id, actions = Logic.request(state, {
		kind = spec.kind,
		seconds = spec.seconds,
		group = spec.group,
		rank = spec.rank,
		force = spec.force,
		maxShow = spec.maxShow,
	}, now(), gate)
	requesting = nil
	if id == 0 then
		return nil
	end
	local kind = spec.kind
	local slot: Slot = {
		id = id,
		kind = kind,
		resumed = false,
		top = function(height: number): number
			return PopupQueue.placeTop(kind, height)
		end,
	}
	records[id] = { spec = spec, slot = slot, showing = false }
	process(actions)
	if records[id] == nil then
		return nil -- dropped / expired at once, or its presenter could not draw
	end
	return {
		id = id,
		done = function()
			withdraw(id, false)
		end,
		cancel = function()
			withdraw(id, true)
		end,
		showing = function(): boolean
			local record = records[id]
			return record ~= nil and record.showing
		end,
	}
end

--[[
	Claims the centre lane for a presenter-driven moment that cannot wait (the plot reveal's
	fly-over): shows at once (pre-empting lower popups, which resume later) and keeps the lane
	until the returned release is called (or PopupQueueConfig.MaxShowSeconds).
	@param kind PopupQueueConfig.Kinds key (highest priority kinds only make sense here)
	@param height number? — design px of the banner (the rect toasts avoid)
	@return () -> () — release (idempotent)
	Example: local release = PopupQueue.hold("plotReveal", 170); ...; release()
]]
function PopupQueue.hold(kind: string, height: number?): () -> ()
	local handle = PopupQueue.request({
		kind = kind,
		force = true,
		height = height,
		show = function(): boolean
			return true
		end,
	})
	if handle == nil then
		return function() end
	end
	local released = false
	return function()
		if not released then
			released = true
			handle.done()
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Reads for the chip + toast channels
--------------------------------------------------------------------------------------------------

--[[ True while a centre popup is on screen. ]]
function PopupQueue.centerActive(): boolean
	return Logic.activeOf(state, "center") ~= nil
end

--[[ The kind of the centre popup on screen (nil = free). ]]
function PopupQueue.centerKind(): string?
	local active = Logic.activeOf(state, "center")
	return if active ~= nil then active.kind else nil
end

--[[ The design-px rect of the centre popup on screen (nil = free). ]]
function PopupQueue.centerRect(): Rect?
	if Logic.activeOf(state, "center") == nil then
		return nil
	end
	return activeRect
end

--[[ True while chips must yield (a centre popup is on screen). ]]
function PopupQueue.chipsHidden(): boolean
	return Logic.chipsHidden(state)
end

--[[
	The strip every chip / popup keeps clear at the bottom: the objective chip (HudZones "Bottom")
	and the hint bar (measured from its live screen), design px.
]]
function PopupQueue.reservedRects(): { Rect }
	local list: { Rect } = {}
	local bottom, hints = HudZones.rect("Bottom"), hintsZone()
	if bottom ~= nil and bottom.h > 0 then
		table.insert(list, bottom)
	end
	if hints ~= nil and hints.h > 0 then
		table.insert(list, hints)
	end
	return list
end

--[[
	Publishes (or clears) a static chip's design-px rect so moving chips steer around it.
	@param kind PopupQueueConfig.Kinds key of a "chip" kind
	@param rect Rect? — nil clears
]]
function PopupQueue.setChipRect(kind: string, rect: Rect?)
	local def = Kinds[kind]
	if def == nil or def.channel ~= "chip" then
		return
	end
	chipRectsByKind[kind] = if rect ~= nil then table.freeze(table.clone(rect)) :: any else nil
end

--[[
	True when a chip at `rect` (design px) would cover the currency stack (Top / TopRight), the
	objective chip / hint bar (reservedRects) or another published chip — it then hides there.
	@param kind the asking chip's kind (its own published rect is ignored)
	@param rect Rect
	@return boolean
	Example: chip.Visible = not PopupQueue.chipBlockedAt("luckyArrow", { x = 900, y = 40, w = 84, h = 84 })
]]
function PopupQueue.chipBlockedAt(kind: string, rect: Rect): boolean
	local avoid = PopupQueue.reservedRects()
	local top, topRight = HudZones.rect("Top"), HudZones.rect("TopRight")
	if top ~= nil then
		table.insert(avoid, top)
	end
	if topRight ~= nil then
		table.insert(avoid, topRight)
	end
	for chipKind, chipRect in chipRectsByKind do
		if chipKind ~= kind then
			table.insert(avoid, chipRect)
		end
	end
	return Logic.coversAny(rect, avoid, 0)
end

--[[ The published rects of every chip except `exceptKind` (design px). ]]
function PopupQueue.chipRects(exceptKind: string?): { Rect }
	local list: { Rect } = {}
	for kind, rect in chipRectsByKind do
		if kind ~= exceptKind then
			table.insert(list, rect)
		end
	end
	return list
end

--------------------------------------------------------------------------------------------------
-- The bottom-left feed (owner R108 + R111)
--------------------------------------------------------------------------------------------------

-- True on a phone (smaller pills, >= 14 pt text, above the thumbstick reserve).
local function isPhone(): boolean
	local device: any = ScreenManager.device
	return ScreenManager.isTouchDevice() and type(device) == "table" and device.isPhone == true
end

--[[
	Design px kept clear above the bottom edge on touch devices: the HUD's bottom reserve or the
	jump button / thumbstick ring height + 12 pt (exactly how UI/Hud/Hud reserves it), nil off touch.
]]
function PopupQueue.touchReserve(): number?
	if not ScreenManager.isTouchDevice() then
		return nil
	end
	local device = ScreenManager.device
	local scale = math.max(ScreenManager.pointScale(), 0.01)
	if device.viewportY <= 0 then
		return HudPlacement.TouchBottomReserve
	end
	local jump = LayoutLogic.jumpRect(device.viewportX, device.viewportY, PlatformConfig.Touch.DefaultJump)
	return math.max(HudPlacement.TouchBottomReserve, (device.viewportY - jump.y + 12) / scale)
end

-- A GuiObject's rect in design px relative to `origin` (absolute px).
local function designRect(object: GuiObject, origin: Vector2): Rect
	local scale = math.max(ScreenManager.scale, 0.01)
	local offset = (object.AbsolutePosition - origin) / scale
	return { x = offset.X, y = offset.Y, w = object.AbsoluteSize.X / scale, h = object.AbsoluteSize.Y / scale }
end

--[[
	The open (top) modal window's rect in HUD design px, or nil. Kit/StudUI windows live in a
	Widgets/ModalShell ("ModalShell" → "FitHolder", fitted, before the pop scale); any other modal
	is measured as the bounding box of its visible content (full-canvas holders / backdrops are
	looked through). Toasts are drawn above windows, so the feed keeps out of this rect.
]]
function PopupQueue.windowRect(): Rect?
	local name = ScreenManager.topModalName()
	local gui = if name ~= nil then ScreenManager.getGui(name) else nil
	if gui == nil or not gui.Enabled then
		return nil
	end
	local holder = gui:FindFirstChild("FitHolder", true)
	local shell = if holder ~= nil then holder.Parent else nil
	if holder ~= nil and holder:IsA("GuiObject") and shell ~= nil and shell:IsA("GuiObject") then
		return designRect(holder, shell.AbsolutePosition)
	end
	-- Generic modal: the union of its visible, not-full-canvas content.
	local padding = gui:FindFirstChild("SafeArea")
	local origin = gui.AbsolutePosition
	if padding ~= nil and padding:IsA("UIPadding") then
		origin += Vector2.new(padding.PaddingLeft.Offset, padding.PaddingTop.Offset)
	end
	local full = gui.AbsoluteSize * 0.95
	local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
	local function include(object: GuiObject)
		local position, size = object.AbsolutePosition, object.AbsoluteSize
		x1, y1 = math.min(x1, position.X), math.min(y1, position.Y)
		x2, y2 = math.max(x2, position.X + size.X), math.max(y2, position.Y + size.Y)
	end
	for _, child in gui:GetChildren() do
		if child:IsA("GuiObject") and child.Visible then
			if child.AbsoluteSize.X >= full.X and child.AbsoluteSize.Y >= full.Y then
				for _, inner in child:GetChildren() do
					if inner:IsA("GuiObject") and inner.Visible and inner.AbsoluteSize.X < full.X then
						include(inner)
					end
				end
			else
				include(child)
			end
		end
	end
	if x1 == math.huge then
		return nil
	end
	local scale = math.max(ScreenManager.scale, 0.01)
	return { x = (x1 - origin.X) / scale, y = (y1 - origin.Y) / scale, w = (x2 - x1) / scale, h = (y2 - y1) / scale }
end

--[[
	One feed pill's metrics right now: desktop / tablet / console the config sizes; phones the
	text from PhoneTextPoints (>= 14 pt, owner R111) and the pill from it.
	@return PillMetrics
]]
function PopupQueue.pillMetrics(): PillMetrics
	local textSize, height = Feed.TextSize, Feed.PillHeight
	if isPhone() then
		textSize = math.ceil(TouchLayout.pointsToDesign(Feed.PhoneTextPoints, ScreenManager.pointScale()))
		height = math.ceil(textSize * Feed.PillHeightPerText)
	end
	return {
		height = height,
		textSize = textSize,
		iconSize = math.floor(height * Feed.IconFill),
		padX = Feed.PadX,
		maxLines = Feed.MaxLines,
	}
end

--[[
	Where the bottom-left feed column may live right now (FeedLogic.area with the live zones,
	the centre popup, the open window and the touch reserve).
	@param need number — the height the content wants (design px)
	@return FeedArea
]]
function PopupQueue.feedArea(need: number): FeedArea
	start()
	local canvas = ScreenManager.canvasSize(nil)
	local obstacles: { Rect } = PopupQueue.reservedRects()
	local active = Logic.activeOf(state, "center")
	local def = if active ~= nil then Kinds[active.kind] else nil
	local center = PopupQueue.centerRect()
	if center ~= nil and def ~= nil and def.anchor ~= "feed" and center.w > 0 then
		table.insert(obstacles, center)
	end
	return FeedLogic.area({
		canvasW = canvas.X,
		canvasH = canvas.Y,
		bandTop = PopupQueue.band().top,
		left = HudZones.rect("Left"),
		obstacles = obstacles,
		window = PopupQueue.windowRect(),
		touchReserve = PopupQueue.touchReserve(),
		need = need,
		phone = isPhone(),
	})
end

--[[
	Places the reveal card at the bottom of the feed column (fitted between minFit and 1) and
	reserves it: the pills stack above it (Changed("feed")).
	@param width number, height number — the card's design size
	@param minFit number — smallest fit allowed
	@return (x, y, fit) — the card's top-left (design px) and its fit scale
	Example: local x, y, fit = PopupQueue.placeFeedCard(540, 230, 0.7)
]]
function PopupQueue.placeFeedCard(width: number, height: number, minFit: number): (number, number, number)
	local area = PopupQueue.feedArea(height)
	local room = area.bottom - area.top
	local fit = math.clamp(math.min(area.width / width, room / height, 1), math.min(minFit, 1), 1)
	local rect = { x = area.x, y = area.bottom - height * fit, w = width * fit, h = height * fit }
	feedCardRect = rect
	feedCardArea = area
	local active = Logic.activeOf(state, "center")
	if active ~= nil and Kinds[active.kind] ~= nil and Kinds[active.kind].anchor == "feed" then
		activeRect = rect
	end
	PopupQueue.Changed:Fire("feed")
	return rect.x, rect.y, fit
end

--[[ Frees the reveal card's slot (the screen closed). ]]
function PopupQueue.clearFeedCard()
	if feedCardRect == nil then
		return
	end
	feedCardRect = nil
	feedCardArea = nil
	PopupQueue.Changed:Fire("feed")
end

--[[ The reveal card's rect (design px) + the column it sits in, or nil. ]]
function PopupQueue.feedCard(): (Rect?, FeedArea?)
	return feedCardRect, feedCardArea
end

--[[
	The currency stack's boxes in SCREEN px (GuiObject.AbsolutePosition space; the space of
	Camera:WorldToScreenPoint): the Top zone stretched to the measured stack's bottom, plus the
	phone's TopRight row. World markers (Tycoon/YouMarker) hide while they would sit over it.
	@return { Rect }
]]
function PopupQueue.stackScreenRects(): { Rect }
	local list: { Rect } = {}
	local frame = stack()
	local container = if frame ~= nil then frame.Parent else nil
	if container == nil or not container:IsA("GuiObject") then
		return list
	end
	local origin = container.AbsolutePosition
	local scale = math.max(ScreenManager.scale, 0.01)
	local function toScreen(rect: Rect)
		table.insert(
			list,
			{ x = origin.X + rect.x * scale, y = origin.Y + rect.y * scale, w = rect.w * scale, h = rect.h * scale }
		)
	end
	local top = HudZones.rect("Top")
	if top ~= nil then
		local bottom = math.max(top.y + top.h, measuredStackBottom() or 0)
		toScreen({ x = top.x, y = top.y, w = top.w, h = bottom - top.y })
	end
	local topRight = HudZones.rect("TopRight")
	if topRight ~= nil then
		toScreen(topRight)
	end
	return list
end

--[[
	True when a SCREEN-px box (Camera:WorldToScreenPoint space) covers the currency stack, grown by
	PopupQueueConfig.YouMarker.Margin design px (doubled when `sticky`: a hidden marker only comes
	back once it is clearly off the stack — no flicker on the edge).
	@param rect Rect — screen px
	@param sticky boolean? — the caller is currently hidden because of the stack
	@return boolean
]]
function PopupQueue.coversStack(rect: Rect, sticky: boolean?): boolean
	local margin = PopupQueueConfig.YouMarker.Margin * math.max(ScreenManager.scale, 0.01)
	return Logic.coversAny(rect, PopupQueue.stackScreenRects(), if sticky then margin * 2 else margin)
end

--[[ QA probe (tools/qa/popup_queue.py): the lane, the band, the waiting kinds and counters. ]]
function PopupQueue.stats(): { [string]: any }
	local active = Logic.activeOf(state, "center")
	local waiting: { string } = {}
	local list = state.waiting.center
	if list ~= nil then
		for _, entry in list do
			table.insert(waiting, entry.kind)
		end
	end
	local band = PopupQueue.band()
	return {
		active = if active ~= nil then active.kind else nil,
		activeRect = PopupQueue.centerRect(),
		waiting = waiting,
		band = { top = band.top, bottom = band.bottom, known = band.known },
		chipsHidden = PopupQueue.chipsHidden(),
		counters = table.clone(counters),
		feedCard = feedCardRect,
		window = PopupQueue.windowRect(),
	}
end

return PopupQueue
