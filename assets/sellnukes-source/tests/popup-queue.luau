--!strict
--[[
	Popup priority queue regressions (owner R102: "sometimes UI will clip like this when it pops
	up, need a priority queue"). Run:
		lune run tests/popup-queue

	Proves on the shipped modules (Shared/Config/PopupQueueConfig, Client/UI/Widgets/
	PopupQueueLogic) with a fake clock:
	  1. Config: every kind is sane; the owner's order plot reveal > flavour reveal > Happy Hour >
	     juice > Lucky arrow > Happy pill; chips are "chip" kinds; R108: the reveal is a feed card
	     and Big Pop is not a lane popup; R120: no centre flavour popup at all (the shout is gone).
	  2. One per channel: a free lane shows at once; a queue-timed popup ends exactly at its hold.
	  3. Waiting + expiry: a lower popup waits behind a higher one and shows after it, or expires
	     after maxWait without ever showing.
	  4. Pre-emption: a higher popup cuts in; "resume" kinds come back with their FULL hold
	     (kid-friendly: never shorter than before R102), "drop" kinds end.
	  5. Same group: a newer request replaces a waiting one; replaceActive replaces the shown one
	     (after minShow: the juice 0.5 s rule); a lower rank is dropped; first-come among equals.
	  6. Gates: menus / cinematics hold popups back (polled), a hold (force) skips them.
	  7. Presenter-driven popups: finish() frees the lane without a hide; a stuck one times out.
	  8. Input hygiene: unknown / chip kinds refused; NaN / inf / huge holds sanitised.
	  9. Randomised soak: invariants over 4000 random operations (one on screen, the best allowed
	     one on screen after every step, every request ends exactly once, nobody shown shorter than
	     its hold unless pre-empted / replaced).
	 10. Placement (the R102 screenshots): the band sits between the currency stack (incl. a
	     taller measured stack) and the objective chip / hint bar on desktop / phone / tablet /
	     console canvases; no centre card overlaps the Top / Bottom / Hints zones when it fits.
	 12. Chips hide while a centre popup is up; the YOU marker overlap test (margin hysteresis).
	(The bottom-left feed — toasts, Big Pop pills, the reveal card — is tests/popup-feed.luau.)
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local Config = loader.load("src/shared/Config/PopupQueueConfig")
local Logic = loader.load("src/client/UI/Widgets/PopupQueueLogic")

local checks = 0
local function ok(condition: boolean, label: string)
	checks += 1
	if not condition then
		error(label, 2)
	end
end

local function near(a: number, b: number, label: string)
	ok(math.abs(a - b) < 1e-6, `{label}: {a} vs {b}`)
end

local Kinds = Config.Kinds
local function allow(_entry: any): boolean
	return true
end
local function deny(_entry: any): boolean
	return false
end

-- "show:juice#1:free" strings for compact assertions.
local kindOf: { [number]: string } = {}
local function fmt(actions: { any }): { string }
	local out = {}
	for _, action in actions do
		table.insert(
			out,
			`{action.op}:{kindOf[action.id] or "?"}#{action.id}:{action.reason}{if action.final then "!" else ""}`
		)
	end
	return out
end
local function same(actual: { string }, expected: { string }, label: string)
	ok(table.concat(actual, ",") == table.concat(expected, ","), `{label}: got [{table.concat(actual, ",")}]`)
end

local function request(state: any, spec: any, now: number, gate: any?): (number, { string })
	local id, actions = Logic.request(state, spec, now, gate or allow)
	if id ~= 0 then
		kindOf[id] = spec.kind
	end
	return id, fmt(actions)
end

local function step(state: any, now: number, gate: any?): { string }
	return fmt(Logic.step(state, now, gate or allow))
end

--------------------------------------------------------------------------------------------------
-- 1. Config
--------------------------------------------------------------------------------------------------

do
	-- Owner R122: luckyDeal (the Lucky Button DEAL card) above juice; the notification opt-in card
	-- (notifyPrompt) and the invite moment below it (both can follow area 2: notify first).
	local order = {
		"plotReveal",
		"flavorReveal",
		"happyHour",
		"luckyDeal",
		"juice",
		"notifyPrompt",
		"inviteMoment",
		"luckyArrow",
		"happyHourChip",
	}
	for index, name in order do
		local def = Kinds[name]
		ok(def ~= nil, `kind {name} exists`)
		ok(def.channel == "center" or def.channel == "chip", `{name} channel`)
		ok(def.preempt == "resume" or def.preempt == "drop", `{name} preempt`)
		ok(
			def.anchor == "top" or def.anchor == "bottom" or def.anchor == "fill" or def.anchor == "feed",
			`{name} anchor`
		)
		ok(def.maxWait >= 0 and def.maxWait == def.maxWait and def.maxWait < 120, `{name} maxWait`)
		ok(def.minShow >= 0 and def.minShow < 5, `{name} minShow`)
		if index > 1 then
			ok(Kinds[order[index - 1]].priority > def.priority, `owner order: {order[index - 1]} > {name}`)
		end
	end
	for name, def in Kinds do
		ok(table.find(order, name) ~= nil, `kind {name} is in the owner order`)
		ok(table.isfrozen(def), `{name} frozen`)
	end
	ok(Kinds.luckyArrow.channel == "chip" and Kinds.happyHourChip.channel == "chip", "chips are chip kinds")
	ok(Config.PollSeconds > 0 and Config.PollSeconds <= 1, "poll period")
	ok(Config.MaxShowSeconds >= 10, "presenter cap leaves the 2.8 s reveal + QA room")
	ok(Kinds.flavorReveal.anchor == "feed", "R108: the reveal is a feed card, never centre-screen")
	-- Owner R120 / R122: the new cards are small non-modal feed cards, never centre-screen.
	ok(Kinds.luckyDeal.anchor == "feed" and Kinds.inviteMoment.anchor == "feed", "R122: deal + invite are feed cards")
	ok(Kinds.luckyDeal.waitForModal and Kinds.inviteMoment.waitForModal, "R122: never under / around a menu")
	ok(Kinds.inviteMoment.priority < Kinds.juice.priority, "R122: the invite moment never cuts in")
	ok(Kinds.bigPop == nil, "R108: Big Pop is a feed pill, not a lane popup")
	-- Owner R120: no Lucky Nuke ever shows centre-screen.
	ok(Kinds.flavorShout == nil, "R120: the centre flavour shout is gone")
	for name, def in Kinds do
		if string.find(string.lower(name), "flavor", 1, true) ~= nil then
			ok(def.anchor == "feed", `R120: {name} is a bottom-left feed card, never centre`)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- 2. One per channel, holds end on time
--------------------------------------------------------------------------------------------------

do
	local state = Logic.new()
	local id, actions = request(state, { kind = "juice", seconds = 2.4 }, 0)
	same(actions, { `show:juice#{id}:free` }, "free lane shows at once")
	same(step(state, 2.39), {}, "still up before its hold")
	same(step(state, 2.4), { `hide:juice#{id}:done!` }, "hold ends exactly")
	ok(Logic.activeOf(state, "center") == nil, "lane free again")
	ok(Logic.nextWake(state, 3, 0.5, allow) == nil, "nothing pending: no wake")
end

--------------------------------------------------------------------------------------------------
-- 3. Waiting + expiry
--------------------------------------------------------------------------------------------------

do
	local state = Logic.new()
	local big = request(state, { kind = "happyHour", seconds = 4.5 }, 0)
	local juice, actions = request(state, { kind = "juice", seconds = 2.4 }, 1)
	same(actions, {}, "a lower popup waits")
	ok(Logic.waitingCount(state, "center") == 1, "one waiting")
	near(Logic.nextWake(state, 1, 0.5, allow) :: number, 4.5, "wakes at the Big Pop's end (before juice expiry 6)")
	same(step(state, 4.5), { `hide:happyHour#{big}:done!`, `show:juice#{juice}:free` }, "then it shows")
	local entry = Logic.activeOf(state, "center")
	near(entry.endsAt, 4.5 + 2.4, "full hold after waiting")

	-- Expiry: the higher one outlasts maxWait (juice 5 s).
	local state2 = Logic.new()
	request(state2, { kind = "happyHour", seconds = 8 }, 0)
	local late = request(state2, { kind = "juice", seconds = 2.4 }, 0)
	near(Logic.nextWake(state2, 0, 0.5, allow) :: number, Kinds.juice.maxWait, "wakes for the expiry")
	same(step(state2, Kinds.juice.maxWait), { `expire:juice#{late}:maxWait!` }, "expires unseen")
	ok(Logic.waitingCount(state2, "center") == 0, "gone from the queue")
end

--------------------------------------------------------------------------------------------------
-- 4. Pre-emption
--------------------------------------------------------------------------------------------------

do
	-- resume: the juice comes back with its full hold.
	local state = Logic.new()
	local juice = request(state, { kind = "juice", seconds = 2.4 }, 0)
	local reveal, actions = request(state, { kind = "flavorReveal", maxShow = 10 }, 1)
	same(actions, { `hide:juice#{juice}:preempted`, `show:flavorReveal#{reveal}:preempt` }, "a higher one cuts in")
	same(fmt(Logic.finish(state, reveal, 3.8, allow)), { `show:juice#{juice}:resumed` }, "resumes after")
	near(Logic.activeOf(state, "center").endsAt, 3.8 + 2.4, "resumed with its FULL hold")
	same(step(state, 6.2), { `hide:juice#{juice}:done!` }, "then ends normally")

	-- drop: a reveal pre-empted by the plot reveal hold ends for good.
	local state2 = Logic.new()
	local r2 = request(state2, { kind = "flavorReveal" }, 0)
	local hold, actions2 = request(state2, { kind = "plotReveal", force = true }, 0.5, deny)
	same(actions2, { `hide:flavorReveal#{r2}:preempted!`, `show:plotReveal#{hold}:preempt` }, "drop kind ends")
	same(fmt(Logic.finish(state2, hold, 5, allow)), {}, "nothing to resume")

	-- resume window: a pre-empted juice whose wait runs out while the reveal plays expires.
	local state3 = Logic.new()
	local j3 = request(state3, { kind = "juice", seconds = 2.4 }, 0)
	request(state3, { kind = "flavorReveal", maxShow = 30 }, 0.1)
	same(step(state3, 0.1 + Kinds.juice.maxWait), { `expire:juice#{j3}:maxWait!` }, "resume window expires")

	-- equal priority never pre-empts.
	local state4 = Logic.new()
	local a = request(state4, { kind = "juice", seconds = 2.4, group = "a" }, 0)
	local _, actions4 = request(state4, { kind = "juice", seconds = 2.4, group = "b" }, 0.1)
	same(actions4, {}, "equal priority waits")
	ok(Logic.activeOf(state4, "center").id == a, "first stays")
end

--------------------------------------------------------------------------------------------------
-- 5. Same group, rank, first-come
--------------------------------------------------------------------------------------------------

do
	-- Waiting replaced by a newer one (same group: the newest wins).
	local state = Logic.new()
	request(state, { kind = "flavorReveal" }, 0)
	local b1 = request(state, { kind = "happyHour", seconds = 4.5 }, 0.2)
	local b2, actions = request(state, { kind = "happyHour", seconds = 4.5 }, 0.4)
	same(actions, { `drop:happyHour#{b1}:replaced!` }, "newer waiting replaces older")
	ok(Logic.waitingCount(state, "center") == 1, "only the newest waits")

	-- Shown one replaced (replaceActive, after minShow).
	local state2 = Logic.new()
	local s1 = request(state2, { kind = "juice", seconds = 2.4 }, 0)
	local s2, actions2 = request(state2, { kind = "juice", seconds = 2.4 }, 1)
	same(
		actions2,
		{ `hide:juice#{s1}:replaced!`, `show:juice#{s2}:replace` },
		"newer milestone replaces the shown one (after minShow)"
	)

	-- Juice minShow (0.5 s, the pre-R102 BannerCooldown).
	local state3 = Logic.new()
	local j1 = request(state3, { kind = "juice", seconds = 2.4 }, 0)
	local j2, early = request(state3, { kind = "juice", seconds = 2.4 }, 0.2)
	same(early, {}, "too early: waits behind it")
	local j3, later = request(state3, { kind = "juice", seconds = 2.4 }, 0.6)
	same(
		later,
		{ `drop:juice#{j2}:replaced!`, `hide:juice#{j1}:replaced!`, `show:juice#{j3}:replace` },
		"after minShow the newest replaces both"
	)

	-- Rank: a weaker newer request is dropped.
	local state4 = Logic.new()
	request(state4, { kind = "happyHour", seconds = 4.5 }, 0)
	local strong = request(state4, { kind = "juice", seconds = 2.4, group = "g", rank = 5 }, 0)
	local weak, actions4 = request(state4, { kind = "juice", seconds = 2.4, group = "g", rank = 4 }, 0.1)
	same(actions4, { `drop:juice#{weak}:outranked!` }, "outranked newer is dropped")
	ok(state4.waiting.center[1].id == strong, "the stronger keeps waiting")

	-- First-come among equals (different groups, same kind).
	local state5 = Logic.new()
	local top = request(state5, { kind = "happyHour", seconds = 2 }, 0)
	local first = request(state5, { kind = "juice", seconds = 1.5, group = "x" }, 0.1)
	local second = request(state5, { kind = "juice", seconds = 1.5, group = "y" }, 0.2)
	same(step(state5, 2), { `hide:happyHour#{top}:done!`, `show:juice#{first}:free` }, "first-come wins ties")
	same(step(state5, 3.5), { `hide:juice#{first}:done!`, `show:juice#{second}:free` }, "then the next")
end

--------------------------------------------------------------------------------------------------
-- 6. Gates
--------------------------------------------------------------------------------------------------

do
	local state = Logic.new()
	local id, actions = request(state, { kind = "happyHour", seconds = 4.5 }, 0, deny)
	same(actions, {}, "a menu / cinematic holds it back")
	near(Logic.nextWake(state, 0, 0.5, deny) :: number, 0.5, "gate-blocked: polled")
	same(step(state, 0.5, deny), {}, "still blocked")
	same(step(state, 1, allow), { `show:happyHour#{id}:free` }, "gate opens: shows")
	near(Logic.activeOf(state, "center").endsAt, 5.5, "full hold from when it showed")

	-- Gates do not stop what is already on screen.
	same(step(state, 2, deny), {}, "shown popup keeps its turn under a later menu")

	-- A blocked better one does not stop a lower allowed one; it cuts in when allowed.
	local state2 = Logic.new()
	local function onlyJuice(entry: any): boolean
		return entry.kind == "juice"
	end
	local big = request(state2, { kind = "happyHour", seconds = 4.5 }, 0, onlyJuice)
	local juice, a2 = request(state2, { kind = "juice", seconds = 2.4 }, 0, onlyJuice)
	same(a2, { `show:juice#{juice}:free` }, "allowed lower one shows")
	same(step(state2, 1, allow), { `hide:juice#{juice}:preempted`, `show:happyHour#{big}:preempt` }, "better cuts in")

	-- A hold skips gates and pre-empts.
	local state3 = Logic.new()
	local low = request(state3, { kind = "happyHour", seconds = 5 }, 0)
	local hold, a3 = request(state3, { kind = "plotReveal", force = true }, 1, deny)
	same(a3, { `hide:happyHour#{low}:preempted`, `show:plotReveal#{hold}:preempt` }, "hold ignores gates")
	ok(Logic.chipsHidden(state3), "chips yield to the hold")

	-- A new hold replaces the previous one without freeing the lane (PlotReveal.openBanner).
	local state4 = Logic.new()
	local h1 = request(state4, { kind = "plotReveal", force = true }, 0)
	local waiting = request(state4, { kind = "juice", seconds = 2 }, 0.1)
	local h2, a4 = request(state4, { kind = "plotReveal", force = true }, 1, deny)
	same(a4, { `hide:plotReveal#{h1}:replaced!`, `show:plotReveal#{h2}:replace` }, "hold replaces hold")
	ok(state4.waiting.center[1].id == waiting, "the waiting banner never flashed up in between")
	same(fmt(Logic.finish(state4, h1, 1.1, allow)), {}, "releasing the old hold is a no-op")

	-- Custom cross-kind groups: a less important newer popup never replaces a shown one.
	local state5 = Logic.new()
	local big = request(state5, { kind = "happyHour", seconds = 4, group = "g" }, 0)
	local small, a5 = request(state5, { kind = "juice", seconds = 2, group = "g" }, 1)
	same(a5, {}, "lower priority waits instead of replacing")
	ok(Logic.activeOf(state5, "center").id == big and small > 0, "big pop stays")
end

--------------------------------------------------------------------------------------------------
-- 7. Presenter-driven
--------------------------------------------------------------------------------------------------

do
	local state = Logic.new()
	local reveal = request(state, { kind = "flavorReveal", maxShow = 12 }, 0)
	local big = request(state, { kind = "happyHour", seconds = 4.5 }, 0.5)
	near(Logic.activeOf(state, "center").endsAt, 12, "presenter cap")
	same(
		fmt(Logic.finish(state, reveal, 2.8, allow)),
		{ `show:happyHour#{big}:free` },
		"finish frees the lane, no hide"
	)
	local state2 = Logic.new()
	local stuck = request(state2, { kind = "flavorReveal" }, 0)
	near(Logic.activeOf(state2, "center").endsAt, Config.MaxShowSeconds, "default cap")
	same(step(state2, Config.MaxShowSeconds), { `hide:flavorReveal#{stuck}:timeout!` }, "a stuck one times out")
	-- Finishing a waiting one withdraws it silently.
	local state3 = Logic.new()
	request(state3, { kind = "happyHour", seconds = 4.5 }, 0)
	local waiting = request(state3, { kind = "juice", seconds = 2 }, 0)
	same(fmt(Logic.finish(state3, waiting, 1, allow)), {}, "withdrawn")
	ok(Logic.waitingCount(state3, "center") == 0, "queue empty")
end

--------------------------------------------------------------------------------------------------
-- 8. Input hygiene
--------------------------------------------------------------------------------------------------

do
	local state = Logic.new()
	ok((Logic.request(state, { kind = "nope", seconds = 1 }, 0, allow)) == 0, "unknown kind refused")
	ok((Logic.request(state, { kind = "luckyArrow", seconds = 1 }, 0, allow)) == 0, "chip kinds do not queue")
	local nan = request(state, { kind = "juice", seconds = 0 / 0 }, 0)
	ok(
		Logic.activeOf(state, "center").id == nan and Logic.activeOf(state, "center").seconds == nil,
		"NaN → presenter-driven"
	)
	near(Logic.activeOf(state, "center").endsAt, Config.MaxShowSeconds, "NaN capped by maxShow")
	local state2 = Logic.new()
	request(state2, { kind = "juice", seconds = math.huge }, 0)
	ok(Logic.activeOf(state2, "center").seconds == nil, "inf refused")
	local state3 = Logic.new()
	request(state3, { kind = "juice", seconds = 1e9 }, 0)
	near(Logic.activeOf(state3, "center").seconds, 60, "huge hold capped at 60 s")
	local state4 = Logic.new()
	request(state4, { kind = "juice", seconds = -3 }, 0)
	ok(Logic.activeOf(state4, "center").seconds == nil, "negative refused")
	local state5 = Logic.new()
	request(state5, { kind = "flavorReveal", maxShow = 1e9 }, 0)
	near(Logic.activeOf(state5, "center").endsAt, 600, "presenter cap capped")
	local state6 = Logic.new()
	request(state6, { kind = "happyHour", seconds = 4, rank = 0 / 0 }, 0)
	ok(Logic.activeOf(state6, "center").rank == 0, "NaN rank → 0")
end

--------------------------------------------------------------------------------------------------
-- 9. Randomised soak
--------------------------------------------------------------------------------------------------

do
	local seed = 20261031
	local function rand(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local center: { string } = {}
	for name, def in Kinds do
		if def.channel == "center" then
			table.insert(center, name)
		end
	end
	table.sort(center)
	local state = Logic.new()
	local now = 0
	local gateOpen = true
	local function gate(_entry: any): boolean
		return gateOpen
	end
	local ended: { [number]: number } = {} -- id → final count
	local requested: { [number]: boolean } = {}
	local shownAt: { [number]: number } = {}
	local holdOf: { [number]: number? } = {}
	local function apply(actions: { any })
		for _, action in actions do
			if action.op == "show" then
				shownAt[action.id] = now
			elseif action.op == "hide" then
				local since = shownAt[action.id]
				ok(since ~= nil, "hide of something shown")
				local hold = holdOf[action.id]
				if action.reason == "done" and hold ~= nil then
					ok(now - since >= hold - 1e-9, "never shorter than its hold")
				end
				shownAt[action.id] = nil
			end
			if action.final then
				ended[action.id] = (ended[action.id] or 0) + 1
			end
		end
		-- Invariants after every operation.
		local active = Logic.activeOf(state, "center")
		local list = state.waiting.center or {}
		for _, entry in list do
			ok(entry ~= active, "an entry is never both waiting and shown")
			if active ~= nil and (entry.force or gate(entry)) then
				ok(entry.priority <= active.priority, "no allowed better popup waits behind a worse one")
			end
			if active == nil then
				ok(not (entry.force or gate(entry)), "a free lane leaves only blocked entries waiting")
			end
		end
	end
	for _ = 1, 4000 do
		now += rand() * 1.2
		local roll = rand()
		if roll < 0.45 then
			local kind = center[1 + math.floor(rand() * #center)]
			local timed = kind ~= "flavorReveal" and kind ~= "plotReveal"
			local seconds = if timed then 1 + rand() * 4 else nil
			local id, actions = Logic.request(state, {
				kind = kind,
				seconds = seconds,
				force = kind == "plotReveal",
				group = if rand() < 0.3 then "shared" else nil,
				rank = math.floor(rand() * 3),
				maxShow = if timed then nil else 3,
			}, now, gate)
			if id ~= 0 then
				requested[id] = true
				holdOf[id] = seconds
			end
			apply(actions)
		elseif roll < 0.6 then
			local active = Logic.activeOf(state, "center")
			if active ~= nil and active.seconds == nil then
				shownAt[active.id] = nil
				ended[active.id] = (ended[active.id] or 0) + 1
				apply(Logic.finish(state, active.id, now, gate))
			end
		elseif roll < 0.7 then
			gateOpen = not gateOpen
			apply(Logic.step(state, now, gate))
		else
			apply(Logic.step(state, now, gate))
		end
	end
	-- Drain: open the gates, finish presenter-driven ones, run time forward.
	gateOpen = true
	for _ = 1, 400 do
		now += 1
		local active = Logic.activeOf(state, "center")
		if active ~= nil and active.seconds == nil then
			shownAt[active.id] = nil
			ended[active.id] = (ended[active.id] or 0) + 1
			apply(Logic.finish(state, active.id, now, gate))
		else
			apply(Logic.step(state, now, gate))
		end
	end
	local count = 0
	for id in requested do
		count += 1
		ok(ended[id] == 1, `request {id} ended exactly once (got {ended[id] or 0})`)
	end
	ok(count > 1000, "soak exercised enough requests")
	ok(Logic.activeOf(state, "center") == nil and Logic.waitingCount(state, "center") == 0, "drained")
end

--------------------------------------------------------------------------------------------------
-- 10. Placement (the R102 screenshots)
--------------------------------------------------------------------------------------------------

-- Canvases in design px with HUD zones as Hud.luau / HintBar publish them (desktop, phone,
-- tablet, console with TV-safe insets). Hints = the measured hint bar.
local CANVASES = {
	{
		name = "desktop",
		w = 1920,
		h = 1080,
		zones = {
			top = { x = 760, y = 8, w = 400, h = 166 },
			bottom = { x = 660, y = 1000, w = 600, h = 64 },
			hints = { x = 760, y = 928, w = 400, h = 62 },
		},
	},
	{
		name = "phone",
		w = 2010,
		h = 930,
		zones = {
			top = { x = 805, y = 8, w = 400, h = 166 },
			topRight = { x = 1240, y = 8, w = 500, h = 96 },
			bottom = { x = 745, y = 760, w = 520, h = 100 },
			stackBottom = 236, -- a taller real stack (event row / another world)
		},
	},
	{
		name = "tablet",
		w = 1440,
		h = 1080,
		zones = {
			top = { x = 520, y = 8, w = 400, h = 166 },
			boosts = { x = 560, y = 174, w = 320, h = 40 },
			bottom = { x = 420, y = 900, w = 600, h = 80 },
		},
	},
	{
		name = "console",
		w = 1728,
		h = 972,
		zones = {
			top = { x = 664, y = 8, w = 400, h = 166 },
			bottom = { x = 564, y = 890, w = 600, h = 64 },
			hints = { x = 464, y = 818, w = 800, h = 62 },
		},
	},
}

local CARDS = { tallBanner = 196, juice = 196, happyHour = 196, smallBanner = 132, plotReveal = 170 }

do
	-- Desktop band numbers.
	local band = Logic.band(CANVASES[1].zones, 1920, 1080)
	near(band.top, 8 + 166 + Config.Band.TopGap, "band starts under the Top zone")
	near(band.bottom, 928 - Config.Band.BottomGap, "band ends above the hint bar")
	ok(band.known, "known with a Top zone")
	-- No zones: MinTop + canvas edge.
	local empty = Logic.band({}, 1920, 1080)
	near(empty.top, Config.Band.MinTop, "MinTop fallback")
	near(empty.bottom, 1080 - Config.Band.EdgeMargin, "canvas edge fallback")
	ok(not empty.known, "unknown without zones")
	-- Measured stack lower than the Top zone wins.
	near(Logic.band(CANVASES[2].zones, 2010, 930).top, 236 + Config.Band.TopGap, "measured stack lowers the band")
	-- TopRight outside the centre lane is ignored; inside it lowers the band.
	local outside = Logic.band(
		{ top = { x = 760, y = 8, w = 400, h = 166 }, topRight = { x = 1700, y = 8, w = 200, h = 300 } },
		1920,
		1080
	)
	near(outside.top, 188, "TopRight outside the lane ignored")
	local inside = Logic.band(
		{ top = { x = 760, y = 8, w = 400, h = 166 }, topRight = { x = 1300, y = 8, w = 300, h = 220 } },
		1920,
		1080
	)
	near(inside.top, 228 + Config.Band.TopGap, "TopRight reaching the lane counts")
	-- Junk measurements ignored.
	near(Logic.band({ stackBottom = 0 / 0 }, 1920, 1080).top, Config.Band.MinTop, "NaN stack ignored")
	near(
		Logic.band({ stackBottom = 900 }, 1920, 1080).top,
		Config.Band.MinTop,
		"a stack below mid-screen is not a stack"
	)

	-- place(): anchors + the overflow rule.
	local b = { top = 188, bottom = 900, known = true }
	local y, fits = Logic.place(b, 196, "top")
	ok(y == 188 and fits, "top anchor")
	y, fits = Logic.place(b, 132, "bottom")
	ok(y == 900 - 132 and fits, "bottom anchor")
	y, fits = Logic.place({ top = 188, bottom = 300, known = true }, 196, "top")
	ok(not fits and math.abs((y + 98) - 244) < 1e-6, "too tall: centred in the band")
	y = Logic.place(b, 999, "fill")
	ok(y == 188, "fill starts at the band top")

	-- Every centre card in every canvas, both anchors: never over Top / Bottom / Hints / stack.
	for _, canvas in CANVASES do
		local zones = canvas.zones :: any
		local band2 = Logic.band(zones, canvas.w, canvas.h)
		local avoid = {}
		for _, key in { "top", "topRight", "bottom", "hints", "boosts" } do
			if zones[key] ~= nil then
				table.insert(avoid, zones[key])
			end
		end
		if zones.stackBottom ~= nil then
			table.insert(avoid, { x = 0, y = 0, w = canvas.w, h = zones.stackBottom })
		end
		for kind, height in CARDS do
			for _, anchor in { "top", "bottom" } do
				local top, fit = Logic.place(band2, height, anchor)
				ok(fit, `{canvas.name} {kind} fits ({anchor})`)
				local lane = Config.Band.LaneWidth
				local rect = { x = canvas.w / 2 - lane / 2, y = top, w = lane, h = height }
				for _, zone in avoid do
					-- TopRight outside the lane never meets the lane rect anyway.
					ok(not Logic.overlaps(rect, zone, 0), `{canvas.name} {kind} ({anchor}) clear of the HUD`)
				end
			end
		end
	end
	-- The R102 Big Pop screenshot: with its old "above Bottom" spot the card covered the hint bar;
	-- in the band it ends above the measured hint bar.
	local desk = CANVASES[1].zones
	local old = { x = 960 - 430, y = desk.bottom.y - 14 - 132, w = 860, h = 132 }
	ok(Logic.overlaps(old, desk.hints, 0), "pre-R102 Big Pop spot overlapped the hint bar (repro)")
	local bandDesk = Logic.band(desk, 1920, 1080)
	local fixedY = Logic.place(bandDesk, 132, "bottom")
	ok(not Logic.overlaps({ x = 530, y = fixedY, w = 860, h = 132 }, desk.hints, 0), "R102: clear of the hint bar")
end

--------------------------------------------------------------------------------------------------
-- 12. Chips + YOU marker
--------------------------------------------------------------------------------------------------

do
	local state = Logic.new()
	ok(not Logic.chipsHidden(state), "chips show with a free lane")
	local id = request(state, { kind = "juice", seconds = 1 }, 0)
	ok(Logic.chipsHidden(state) == Config.HideChipsDuringCenter, "chips hide while a centre popup is up")
	step(state, 1)
	ok(not Logic.chipsHidden(state), "and come back after")
	ok(id > 0, "juice id")

	local stack = { { x = 760, y = 8, w = 400, h = 200 } }
	ok(Logic.coversAny({ x = 900, y = 150, w = 170, h = 120 }, stack, 0), "YOU over the stack: hidden")
	ok(not Logic.coversAny({ x = 900, y = 214, w = 170, h = 120 }, stack, 0), "just under: shown")
	ok(Logic.coversAny({ x = 900, y = 212, w = 170, h = 120 }, stack, 6), "margin keeps it hidden near the edge")
	ok(not Logic.coversAny({ x = 0, y = 0, w = 10, h = 10 }, {}, 6), "no stack: never covered")
end

print(`[popup-queue] {checks} checks passed`)
