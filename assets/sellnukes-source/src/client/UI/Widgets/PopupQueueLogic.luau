--!strict
--[[
	PopupQueueLogic — the PURE rules of the popup priority queue (owner R102: "sometimes UI will
	clip like this when it pops up, need a priority queue"). No Instances, no services, no clock:
	every function takes `now` (seconds, any monotonic clock) and returns what the runtime must do,
	so tests/popup-queue.luau drives it with a fake clock. The runtime is UI/Widgets/PopupQueue.

	Scheduling (one queue per channel; only "center" queues today, chips only yield):
		- One popup on screen per channel. The best waiting popup = highest priority, then
		  first-come (`seq`), among those the runtime's gate allows now (`canShow`: no menu window /
		  cinematic for kinds that wait for them, plus the presenter's own predicate).
		- A waiting popup expires after its kind's maxWait (→ an "expire" action, never shown).
		- A better popup pre-empts the shown one: the shown one gets "hide" (reason "preempted");
		  kind preempt = "resume" puts it back in the queue with a fresh maxWait and its FULL hold
		  (kid-friendly: never shorter than before R102), "drop" ends it (final hide).
		- Same group (default: the kind): a newer request replaces a WAITING one when its rank is
		  >= (Big Pop: the newest broadcast wins), and replaces the SHOWN one when the kind has
		  replaceActive and the shown one has been up for minShow (juice: 0.5 s, as before R102)
		  (then the lane is re-decided, so a better waiting popup still goes first); otherwise it
		  waits behind it. A lower-ranked newer request is dropped at once.
		- A queue-timed popup (`seconds`) ends by itself ("hide", reason "done"); a presenter-driven
		  one (`seconds` = nil: the reveal closes itself, a hold) ends through `finish`, capped at
		  maxShow ("hide", reason "timeout") so a stuck presenter never blocks the lane.
		- A `force` request (a hold: the plot reveal's fly-over) skips the gates and never expires.

	Placement (design px on the HUD canvas):
		band(zones, canvas)      the free vertical band between the currency stack (Top / TopRight
		                         when it reaches into the centre lane / Boosts / the measured stack)
		                         and the objective chip (Bottom) / the measured hint bar.
		place(band, h, anchor)   the top y of an h-tall card: "top" right under the stack, "bottom"
		                         right above the objective / hint bar, centred when it cannot fit.
		(the bottom-left feed column — toasts, Big Pop pills, the reveal card — is FeedLogic.)
		chipsHidden(state)       chips yield while a centre popup is on screen.
		coversAny(rect, rects)   overlap test with a margin (the YOU marker vs the currency stack).

	Connects to: Shared/Config/PopupQueueConfig, UI/Widgets/PopupQueue (runtime), tests/popup-queue.

	Example:
		local state = PopupQueueLogic.new()
		local id, actions = PopupQueueLogic.request(state, { kind = "juice", seconds = 2.4 }, 0, allow)
		--> actions = { { op = "show", id = 1, reason = "free", final = false } }
		actions = PopupQueueLogic.step(state, 2.4, allow)
		--> { { op = "hide", id = 1, reason = "done", final = true } }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PopupQueueConfig = require(ReplicatedStorage.Shared.Config.PopupQueueConfig)

export type Rect = { x: number, y: number, w: number, h: number }
export type Band = { top: number, bottom: number, known: boolean }
export type Anchor = PopupQueueConfig.Anchor

-- One queued / shown popup.
export type Entry = {
	id: number,
	kind: string,
	channel: string,
	priority: number,
	seconds: number?, -- queue-timed hold; nil = presenter-driven (ends through finish)
	maxShow: number, -- longest time on screen per showing (timed: = seconds)
	maxWait: number,
	preempt: PopupQueueConfig.Preempt,
	replaceActive: boolean,
	minShow: number,
	group: string,
	rank: number,
	force: boolean,
	seq: number,
	expiresAt: number,
	shownAt: number?,
	endsAt: number?,
	resumed: boolean,
	replacing: boolean, -- it took the place of the shown one of its group (action reason "replace")
}

-- What a request asks for (the runtime validates presenter input before calling).
export type Spec = {
	kind: string,
	seconds: number?,
	group: string?,
	rank: number?,
	force: boolean?,
	maxShow: number?,
}

-- An instruction for the runtime, in order. `final` = forget the entry afterwards.
--   show    draw it now
--   hide    stop drawing it (done / timeout / preempted / replaced)
--   expire  it waited too long and was never (re)shown
--   drop    removed while waiting (replaced by a newer one / outranked)
export type Op = "show" | "hide" | "expire" | "drop"
export type Action = { op: Op, id: number, reason: string, final: boolean }

export type State = {
	seq: number,
	active: { [string]: Entry },
	waiting: { [string]: { Entry } },
}

-- The runtime gate: may this entry show right now (menus, cinematics, presenter predicate)?
export type Gate = (entry: Entry) -> boolean

-- Zones the band reads (any may be nil when the HUD has not published it / hides it).
export type Zones = {
	top: Rect?,
	topRight: Rect?,
	boosts: Rect?,
	bottom: Rect?,
	hints: Rect?,
	stackBottom: number?, -- the MEASURED currency stack's bottom edge (taller in other worlds)
}

local Kinds = PopupQueueConfig.Kinds :: { [string]: PopupQueueConfig.KindDef }

-- Longest queue-timed hold accepted (seconds; QA captures pass long holds, never forever).
local MAX_SECONDS = 60

local PopupQueueLogic = {}

--[[ A fresh, empty queue state. ]]
function PopupQueueLogic.new(): State
	return { seq = 0, active = {}, waiting = {} }
end

-- A finite number > 0, or nil.
local function positive(value: number?): number?
	if value == nil or value ~= value or value <= 0 or value == math.huge then
		return nil
	end
	return value
end

-- True when `a` should show before `b` (priority, then first-come).
local function better(a: Entry, b: Entry): boolean
	if a.priority ~= b.priority then
		return a.priority > b.priority
	end
	return a.seq < b.seq
end

-- Appends one action (typed: keeps `op` a literal union for the strict solver).
local function emit(actions: { Action }, op: Op, id: number, reason: string, final: boolean)
	local action: Action = { op = op, id = id, reason = reason, final = final }
	table.insert(actions, action)
end

-- The waiting list of a channel (created on demand).
local function listOf(state: State, channel: string): { Entry }
	local list = state.waiting[channel]
	if list == nil then
		list = {}
		state.waiting[channel] = list
	end
	return list
end

-- Puts `entry` on screen (removes it from the waiting list when it is there).
local function show(state: State, entry: Entry, now: number, reason: string, actions: { Action })
	local list = listOf(state, entry.channel)
	local index = table.find(list, entry)
	if index ~= nil then
		table.remove(list, index)
	end
	entry.shownAt = now
	entry.endsAt = now + (entry.seconds or entry.maxShow)
	state.active[entry.channel] = entry
	emit(actions, "show", entry.id, reason, false)
end

-- Takes the shown entry off screen for `reason`; a resumable pre-empted entry goes back in line.
local function takeDown(state: State, entry: Entry, now: number, reason: string, actions: { Action })
	if state.active[entry.channel] == entry then
		state.active[entry.channel] = nil
	end
	local resume = reason == "preempted" and entry.preempt == "resume" and entry.maxWait > 0
	emit(actions, "hide", entry.id, reason, not resume)
	if resume then
		entry.shownAt = nil
		entry.endsAt = nil
		entry.resumed = true
		entry.expiresAt = now + entry.maxWait
		table.insert(listOf(state, entry.channel), entry)
	end
end

-- Promotes the best allowed waiting entry of one channel (pre-empting a worse shown one).
local function promote(state: State, channel: string, now: number, canShow: Gate, actions: { Action })
	local list = listOf(state, channel)
	local best: Entry? = nil
	for _, entry in list do
		if (entry.force or canShow(entry)) and (best == nil or better(entry, best)) then
			best = entry
		end
	end
	if best == nil then
		return
	end
	local active = state.active[channel]
	if active == nil then
		local reason = if best.replacing then "replace" elseif best.resumed then "resumed" else "free"
		best.replacing = false
		show(state, best, now, reason, actions)
	elseif best.priority > active.priority then
		takeDown(state, active, now, "preempted", actions)
		show(state, best, now, "preempt", actions)
	end
end

--[[
	Advances time and re-evaluates the gates: ends finished holds, expires stale waits, promotes.
	@param state State
	@param now number — seconds (monotonic)
	@param canShow Gate — the runtime's gate for non-forced entries
	@return { Action } — in order
	Example: PopupQueueLogic.step(state, os.clock(), gate)
]]
function PopupQueueLogic.step(state: State, now: number, canShow: Gate): { Action }
	local actions: { Action } = {}
	-- Channels with anything shown or waiting (sorted: deterministic action order for tests).
	local channels: { string } = {}
	for channel in state.active do
		table.insert(channels, channel)
	end
	for channel, list in state.waiting do
		if #list > 0 and state.active[channel] == nil then
			table.insert(channels, channel)
		end
	end
	table.sort(channels)
	for _, channel in channels do
		local active = state.active[channel]
		if active ~= nil and active.endsAt ~= nil and now >= active.endsAt then
			takeDown(state, active, now, if active.seconds ~= nil then "done" else "timeout", actions)
		end
		local list = listOf(state, channel)
		for index = #list, 1, -1 do
			local entry = list[index]
			if not entry.force and now >= entry.expiresAt then
				table.remove(list, index)
				emit(actions, "expire", entry.id, "maxWait", true)
			end
		end
		promote(state, channel, now, canShow, actions)
	end
	return actions
end

--[[
	Queues one popup (and shows it at once when its channel allows).
	@param state State
	@param spec Spec — kind (PopupQueueConfig.Kinds, "center" channel), seconds (nil = presenter-
	       driven), group (default kind), rank (default 0), force (hold), maxShow (presenter cap)
	@param now number
	@param canShow Gate
	@return (number, { Action }) — the entry id (0 = refused: unknown / non-queue kind) + actions
	Example: PopupQueueLogic.request(state, { kind = "happyHour", seconds = 5 }, now, gate)
]]
function PopupQueueLogic.request(state: State, spec: Spec, now: number, canShow: Gate): (number, { Action })
	local def = Kinds[spec.kind]
	if def == nil or def.channel ~= "center" then
		return 0, {}
	end
	local seconds = positive(spec.seconds)
	if seconds ~= nil then
		seconds = math.min(seconds, MAX_SECONDS)
	end
	state.seq += 1
	local rank = spec.rank
	local entry: Entry = {
		id = state.seq,
		kind = spec.kind,
		channel = def.channel,
		priority = def.priority,
		seconds = seconds,
		maxShow = seconds or math.min(positive(spec.maxShow) or PopupQueueConfig.MaxShowSeconds, 600),
		maxWait = def.maxWait,
		preempt = def.preempt,
		replaceActive = def.replaceActive,
		minShow = def.minShow,
		group = spec.group or spec.kind,
		rank = if rank ~= nil and rank == rank then rank else 0,
		force = spec.force == true,
		seq = state.seq,
		expiresAt = now + def.maxWait,
		shownAt = nil,
		endsAt = nil,
		resumed = false,
		replacing = false,
	}
	local actions: { Action } = {}
	local list = listOf(state, entry.channel)
	-- Same group waiting: the newer one wins unless it is outranked.
	for index = #list, 1, -1 do
		local other = list[index]
		if other.group == entry.group then
			if entry.rank >= other.rank then
				table.remove(list, index)
				emit(actions, "drop", other.id, "replaced", true)
			else
				emit(actions, "drop", entry.id, "outranked", true)
				return entry.id, actions
			end
		end
	end
	-- Same group on screen: replace it (after minShow) when the kind allows; else wait behind it.
	-- The lane is then re-decided by `step`, so a better popup that was waiting behind the replaced
	-- one still goes first (groups are per kind in practice; this keeps custom groups honest).
	local active = state.active[entry.channel]
	if
		active ~= nil
		and active.group == entry.group
		and active.replaceActive
		and entry.rank >= active.rank
		and entry.priority >= active.priority
		and now - (active.shownAt or now) >= active.minShow
		and (entry.force or canShow(entry))
	then
		state.active[entry.channel] = nil
		emit(actions, "hide", active.id, "replaced", true)
		entry.replacing = true
		active = nil
	end
	if def.maxWait <= 0 and not entry.force then
		-- A kind that never waits: show now or not at all.
		local blocked = (active ~= nil and active.priority >= entry.priority) or not canShow(entry)
		if blocked then
			emit(actions, "expire", entry.id, "busy", true)
			return entry.id, actions
		end
	end
	table.insert(list, entry)
	for _, action in PopupQueueLogic.step(state, now, canShow) do
		table.insert(actions, action)
	end
	entry.replacing = false -- only labels the show that happens right now
	return entry.id, actions
end

--[[
	Ends / withdraws a popup the presenter finished (or cancelled) itself — no "hide" action for
	it (the presenter already took it down) — then promotes the next one.
	@param state State
	@param id number
	@param now number
	@param canShow Gate
	@return { Action } — for the OTHER entries (promotions / expiries)
]]
function PopupQueueLogic.finish(state: State, id: number, now: number, canShow: Gate): { Action }
	for channel, entry in state.active do
		if entry.id == id then
			state.active[channel] = nil
		end
	end
	for _, list in state.waiting do
		for index = #list, 1, -1 do
			if list[index].id == id then
				table.remove(list, index)
			end
		end
	end
	return PopupQueueLogic.step(state, now, canShow)
end

--[[
	When the runtime must call `step` next (one timer, re-armed after every change), or nil when
	nothing is pending. A waiting entry its gate blocks (and nothing else will wake it) is polled.
	@param state State
	@param now number
	@param pollSeconds number
	@param canShow Gate
	@return number?
]]
function PopupQueueLogic.nextWake(state: State, now: number, pollSeconds: number, canShow: Gate): number?
	local wake: number? = nil
	local function consider(at: number)
		if wake == nil or at < (wake :: number) then
			wake = at
		end
	end
	for _, entry in state.active do
		if entry.endsAt ~= nil then
			consider(entry.endsAt)
		end
	end
	for _, list in state.waiting do
		for _, entry in list do
			if not entry.force then
				consider(entry.expiresAt)
			end
			if not entry.force and not canShow(entry) then
				consider(now + pollSeconds)
			end
		end
	end
	return wake
end

--[[ The entry on screen in `channel` (nil = free). ]]
function PopupQueueLogic.activeOf(state: State, channel: string): Entry?
	return state.active[channel]
end

--[[ How many entries wait in `channel`. ]]
function PopupQueueLogic.waitingCount(state: State, channel: string): number
	local list = state.waiting[channel]
	return if list ~= nil then #list else 0
end

--[[ Chips yield while a centre popup is on screen (PopupQueueConfig.HideChipsDuringCenter). ]]
function PopupQueueLogic.chipsHidden(state: State): boolean
	return PopupQueueConfig.HideChipsDuringCenter and state.active.center ~= nil
end

--------------------------------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------------------------------

--[[
	True when two rects overlap with a positive area (after growing `b` by `margin` on each side).
	Example: PopupQueueLogic.overlaps({ x = 0, y = 0, w = 10, h = 10 }, { x = 5, y = 5, w = 10, h = 10 }, 0) --> true
]]
function PopupQueueLogic.overlaps(a: Rect, b: Rect, margin: number?): boolean
	local m = margin or 0
	return a.x < b.x + b.w + m and b.x - m < a.x + a.w and a.y < b.y + b.h + m and b.y - m < a.y + a.h
end

--[[ True when `rect` overlaps any of `rects` (grown by `margin`). ]]
function PopupQueueLogic.coversAny(rect: Rect, rects: { Rect }, margin: number?): boolean
	for _, other in rects do
		if PopupQueueLogic.overlaps(rect, other, margin) then
			return true
		end
	end
	return false
end

--[[
	The free vertical band for centre popups and the toast stack (design px).
	@param zones Zones — HUD zones + the measured currency stack bottom
	@param canvasW number, canvasH number — the HUD canvas (design px)
	@return Band — { top, bottom, known } (known = a top-side zone told us where the stack ends)
	Example: PopupQueueLogic.band({ top = { x = 760, y = 8, w = 400, h = 166 } }, 1920, 1080).top --> 188
]]
function PopupQueueLogic.band(zones: Zones, canvasW: number, canvasH: number): Band
	local cfg = PopupQueueConfig.Band
	local lane: Rect = { x = canvasW / 2 - cfg.LaneWidth / 2, y = 0, w = cfg.LaneWidth, h = canvasH }
	local stackBottom: number? = nil
	local function lower(y: number)
		if stackBottom == nil or y > (stackBottom :: number) then
			stackBottom = y
		end
	end
	local top, boosts, topRight = zones.top, zones.boosts, zones.topRight
	if top ~= nil then
		lower(top.y + top.h)
	end
	if boosts ~= nil then
		lower(boosts.y + boosts.h)
	end
	-- The phone's compact top-right row only matters when it reaches into the centre lane.
	if topRight ~= nil and topRight.y < canvasH / 2 and PopupQueueLogic.overlaps(topRight, lane, 0) then
		lower(topRight.y + topRight.h)
	end
	local measured = zones.stackBottom
	if measured ~= nil and measured == measured and measured > 0 and measured < canvasH / 2 then
		lower(measured)
	end
	local bandTop = math.max(cfg.MinTop, if stackBottom ~= nil then stackBottom + cfg.TopGap else 0)
	local bandBottom = canvasH - cfg.EdgeMargin
	local bottom, hints = zones.bottom, zones.hints
	if bottom ~= nil and bottom.h > 0 then
		bandBottom = math.min(bandBottom, bottom.y - cfg.BottomGap)
	end
	if hints ~= nil and hints.h > 0 then
		bandBottom = math.min(bandBottom, hints.y - cfg.BottomGap)
	end
	return { top = bandTop, bottom = bandBottom, known = stackBottom ~= nil }
end

--[[
	The top y of an h-tall card in the band for `anchor`.
	@return (number, boolean) — top y (design px) and whether it fits cleanly; a card taller than
	        the band is centred in it (it then shares the overflow with both ends evenly).
	Example: PopupQueueLogic.place({ top = 188, bottom = 900, known = true }, 196, "top") --> 188, true
]]
function PopupQueueLogic.place(band: Band, height: number, anchor: Anchor): (number, boolean)
	local room = band.bottom - band.top
	if anchor == "fill" or anchor == "feed" then
		return band.top, true -- "feed" cards are placed by FeedLogic / PopupQueue.placeFeedCard
	end
	if room < height then
		return band.top + (room - height) / 2, false
	end
	if anchor == "bottom" then
		return band.bottom - height, true
	end
	return band.top, true
end

return table.freeze(PopupQueueLogic)
