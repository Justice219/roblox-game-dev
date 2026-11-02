--!strict
--[[
	Nukey's Happy Hours regressions (owner R89 §2; docs/happy-hours.md). Run:
		lune run tests/happy-hours
	Proves on the shipped modules (Shared/Config/HappyHourConfig, Shared/Events/{HappyHourLogic,
	HappyHourPickupLogic}, Client/HappyHour/HappyHourChipLogic, Server/Analytics/KeySpec):
	  1. Config: five events, rotation = EventIds, every pickup / sound / colour / world sane.
	  2. Schedule boundaries: headline [:00, :05), mini [:30, :33), nothing in between, exact edges
	     (t - 1 / t / t + 1 around every start and end), slotAt / slotIndex.
	  3. Rotation: the five events in order by UTC hour; over 120 hours each event runs exactly 24
	     times and visits every hour of the day (fair to every time zone).
	  4. Luck: Sprinkle Surge headline = luck, the :30 mini = miniLuck, 1 everywhere else, always in
	     [1, MaxLuck], never NaN; Double Pops cash multiplier.
	  5. DST-free UTC: across the 2026 US / EU daylight-saving switches every slot start is :00 or
	     :30 UTC with second 0, slots are exactly 1800 s apart and headlines start on the UTC hour.
	  6. Override: force / stop / skip / kill switch / prune / upcoming / next hidden by a force;
	     sanitize refuses junk (NaN, unknown ids, hostile arrays) and round-trips through the
	     JSON-safe encode and the ReplicatedStorage attributes; the installed override is used
	     when a query passes none (FlavorLogic's flavorLuckAt path).
	  7. Pickups: wire validation, fall / float / run (Golden Turkey path) positions, lagged
	     distance, spawn caps, golden caps, id shape.
	  8. Analytics: every Happy Hour key of every event id passes the KeySpec allowlist.
	  9. Low gravity: the event-lowered Moon Base apex still fits every server reach check.
	 10. HUD chip: placement never overlaps a HUD zone / the boost badge / the admin chip on desktop,
	     phone and console layouts, stays on screen; copy for live / next / later / kill switch.
]]

local DateTime = require("@lune/datetime")
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local Config = loader.load("src/shared/Config/HappyHourConfig")
local Logic = loader.load("src/shared/Events/HappyHourLogic")
local Pickup = loader.load("src/shared/Events/HappyHourPickupLogic")
local ChipLogic = loader.load("src/client/HappyHour/HappyHourChipLogic")
local KeySpec = loader.load("src/server/Analytics/KeySpec")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
local WorldClientConfig = loader.load("src/shared/Config/WorldClientConfig")
local WorldGravityConfig = loader.load("src/shared/Config/WorldGravityConfig")
local MovementConfig = loader.load("src/shared/Config/MovementConfig")
local AudioConfig = loader.load("src/shared/Config/AudioConfig")
local UIStyleConfig = loader.load("src/shared/Config/UIStyleConfig")

local Vector3 = roblox.Vector3
local Vector2 = roblox.Vector2

local checks = 0
local function ok(condition: boolean, label: string)
	checks += 1
	assert(condition, label)
end

local function near(a: number, b: number, epsilon: number, label: string)
	ok(math.abs(a - b) <= epsilon, `{label}: {a} vs {b}`)
end

local HOUR = 3600
local SLOT = Config.Schedule.SlotSeconds
local HEAD = Config.Schedule.HeadlineSeconds
local MINI = Config.Schedule.MiniSeconds
-- A fixed UTC hour start well inside 2026 (2026-11-02T10:00:00Z).
local T0 = DateTime.fromUniversalTime({ year = 2026, month = 11, day = 2, hour = 10, minute = 0, second = 0 }).unixTimestamp
ok(T0 % HOUR == 0, "fixture is on an hour")
-- Shipped default ON (owner R92 "just finish em": DefaultEnabled = true): a never-written override
-- runs the schedule; the admin HappyHourToggle (kill switch) still turns it off for every server.
ok(Config.DefaultEnabled == true, "Happy Hours ship ON")
ok(Logic.liveAt(T0 + 1, Logic.emptyOverride()) ~= nil, "default ON: the :00 headline is live")
ok(Logic.nextAt(T0, Logic.emptyOverride()) ~= nil, "default ON: something is next")
local KILLED = Logic.withKill(Logic.emptyOverride(), true, T0, 1)
ok(Logic.liveAt(T0 + 1, KILLED) == nil, "kill switch: nothing live")
ok(Logic.flavorLuckAt(T0 + 1, KILLED) == 1, "kill switch: luck 1")
ok(Logic.cashMultiplierAt(T0 + 1, KILLED) == 1, "kill switch: no cash bonus")
-- The schedule tests below run with Happy Hours switched ON (the admin toggle's override).
local EMPTY = Logic.withKill(Logic.emptyOverride(), false, T0, 1)
ok(EMPTY.v == 1 and not Logic.isOff(EMPTY), "toggle ON enables the schedule")

-- 1. Config -------------------------------------------------------------------------------------------
do
	ok(#Config.EventIds == 5, "five events")
	ok(#Config.Schedule.Rotation == 5, "five rotation entries")
	for index, id in Config.EventIds do
		ok(Config.Schedule.Rotation[index] == id, `rotation order {id}`)
		local def = Config.get(id)
		ok(def ~= nil and def.id == id, `event {id} defined`)
		ok(#def.name > 0 and #def.blurb > 0 and #def.banner > 0, `{id} copy`)
		-- Phone readability: the schedule row line and the chip title stay short.
		ok(#def.tagline > 0 and #def.tagline <= 31, `{id} tagline <= 31 chars`)
		ok(#("LIVE: " .. def.name) <= 22, `{id} chip title <= 22 chars`)
		ok(UIStyleConfig.Colors[def.color] ~= nil, `{id} colour preset`)
		ok(AudioConfig.Sfx[def.sound] ~= nil, `{id} start sound exists`)
		ok(def.world == nil or WorldsConfig.get(def.world) ~= nil, `{id} world registered`)
		local pickup = def.pickup
		if pickup ~= nil then
			ok(pickup.maxLive >= 1 and pickup.maxPerEvent >= pickup.maxLive, `{id} pickup caps`)
			ok(pickup.intervalMin > 0 and pickup.intervalMax >= pickup.intervalMin, `{id} interval`)
			ok(pickup.life > 0 and pickup.life <= Config.Pickups.MaxLife, `{id} life`)
			ok(pickup.incomeSeconds > 0 and pickup.incomeSeconds <= 30, `{id} reward is small`)
			ok(pickup.goldenChance >= 0 and pickup.goldenChance < 0.5, `{id} golden chance`)
			ok(pickup.goldenGems >= 0 and pickup.goldenGems * pickup.maxGoldenPerEvent <= 10, `{id} gems per event bounded`)
			ok(#pickup.meshKey > 0 and #pickup.goldenMeshKey > 0, `{id} meshes`)
		end
	end
	ok(Config.get("nope") == nil and Config.get(5) == nil and Config.get(nil) == nil, "unknown ids refused")
	ok(Config.Events.sprinkle.luck == 2 and Config.Events.sprinkle.miniLuck == 1.5, "sprinkle luck values")
	ok(HEAD == 300 and MINI == 180 and SLOT == 1800, "spec durations")
	ok(#Config.Client.MiniTagline <= 31, "mini tagline <= 31 chars")
	-- Meshes are real Blender meshes (MeshAssets keys).
	local meshes = fs.readFile("src/shared/Config/MeshAssets.luau")
	for _, id in Config.EventIds do
		local pickup = Config.Events[id].pickup
		if pickup ~= nil then
			ok(string.find(meshes, `MeshAssets.{pickup.meshKey} = \{`, 1, true) ~= nil, `{id} mesh {pickup.meshKey}`)
			ok(
				string.find(meshes, `MeshAssets.{pickup.goldenMeshKey} = \{`, 1, true) ~= nil,
				`{id} golden mesh {pickup.goldenMeshKey}`
			)
		end
	end
	ok(string.find(meshes, `MeshAssets.{Config.Client.CloudKey} = \{`, 1, true) ~= nil, "cloud mesh")
end

-- 2. Schedule boundaries ------------------------------------------------------------------------------
do
	for hour = 0, 47 do
		local start = T0 + hour * HOUR
		local headline = Logic.headlineOf(start // HOUR)
		ok(Logic.scheduledLiveAt(start - 1) == nil, `nothing live just before :00 (hour {hour})`)
		local live = Logic.liveAt(start, EMPTY)
		ok(live ~= nil and live.id == headline and not live.mini, `headline live at :00 (hour {hour})`)
		ok(live.startsAt == start and live.endsAt == start + HEAD, "headline window")
		ok(Logic.liveAt(start + HEAD - 1, EMPTY) ~= nil, "headline live at :04:59")
		ok(Logic.liveAt(start + HEAD, EMPTY) == nil, "headline over at :05:00")
		ok(Logic.liveAt(start + SLOT - 1, EMPTY) == nil, "nothing at :29:59")
		local mini = Logic.liveAt(start + SLOT, EMPTY)
		ok(mini ~= nil and mini.id == "sprinkle" and mini.mini, "mini surge at :30")
		ok(Logic.liveAt(start + SLOT + MINI - 1, EMPTY) ~= nil, "mini live at :32:59")
		ok(Logic.liveAt(start + SLOT + MINI, EMPTY) == nil, "mini over at :33:00")
		local nextLive = Logic.nextAt(start + 1, EMPTY)
		ok(nextLive ~= nil and nextLive.startsAt == start + SLOT and nextLive.mini, "next after a headline = the mini")
		local afterMini = Logic.nextAt(start + SLOT, EMPTY)
		ok(afterMini ~= nil and afterMini.startsAt == start + HOUR and not afterMini.mini, "next after the mini = next headline")
		ok(Logic.slotIndex(start) * SLOT == start and Logic.slotAt(start + 100).startsAt == start, "slot maths")
	end
	ok(Logic.liveAt(0 / 0, EMPTY) == nil and Logic.nextAt(math.huge, EMPTY) == nil, "junk times are safe")
	-- Fractional server times (GetServerTimeNow) behave like whole seconds.
	ok(Logic.liveAt(T0 + 0.25, EMPTY) ~= nil and Logic.liveAt(T0 - 0.001, EMPTY) == nil, "fractional edges")
end

-- 3. Rotation -----------------------------------------------------------------------------------------
do
	local hour0 = T0 // HOUR
	for step = 0, 9 do
		ok(Logic.headlineOf(hour0 + step) == Config.Schedule.Rotation[((hour0 + step) % 5) + 1], `rotation step {step}`)
	end
	local counts: { [string]: number } = {}
	local hours: { [string]: { [number]: boolean } } = {}
	for step = 0, 119 do
		local id = Logic.headlineOf(hour0 + step)
		counts[id] = (counts[id] or 0) + 1
		hours[id] = hours[id] or {}
		hours[id][(hour0 + step) % 24] = true
	end
	for _, id in Config.EventIds do
		ok(counts[id] == 24, `{id} runs 24 times in 120 hours`)
		local seen = 0
		for _ in hours[id] do
			seen += 1
		end
		ok(seen == 24, `{id} visits every UTC hour of the day over 5 days`)
	end
end

-- 4. Luck + cash multiplier ---------------------------------------------------------------------------
do
	local sprinkleHour: number? = nil
	local popsHour: number? = nil
	for step = 0, 4 do
		local start = T0 + step * HOUR
		local id = Logic.headlineOf(start // HOUR)
		if id == "sprinkle" then
			sprinkleHour = start
		elseif id == "doublePops" then
			popsHour = start
		end
	end
	ok(sprinkleHour ~= nil and popsHour ~= nil, "found a sprinkle and a double pops hour")
	ok(Logic.flavorLuckAt(sprinkleHour :: number, EMPTY) == 2, "headline surge luck 2")
	ok(Logic.flavorLuckAt((sprinkleHour :: number) + HEAD, EMPTY) == 1, "luck 1 after the surge")
	ok(Logic.flavorLuckAt(T0 + SLOT + 10, EMPTY) == 1.5, "mini surge luck 1.5")
	ok(Logic.flavorLuckAt(T0 + SLOT + MINI, EMPTY) == 1, "luck 1 after the mini")
	ok(Logic.flavorLuckAt(0 / 0, EMPTY) == 1, "NaN time -> luck 1")
	for t = T0, T0 + 6 * HOUR, 97 do
		local luck = Logic.flavorLuckAt(t, EMPTY)
		ok(luck >= 1 and luck <= Config.MaxLuck and luck == luck, "luck in [1, MaxLuck]")
	end
	ok(Logic.cashMultiplierAt(popsHour :: number, EMPTY) == 1.25, "double pops +25%")
	ok(Logic.cashMultiplierAt((popsHour :: number) + HEAD, EMPTY) == 1, "no cash bonus after it")
	ok(Logic.cashMultiplierAt(sprinkleHour :: number, EMPTY) == 1, "sprinkle has no cash bonus")
	-- Kill switch / skip turn the luck off.
	local killed = Logic.withKill(EMPTY, true, T0, 1)
	ok(Logic.flavorLuckAt(sprinkleHour :: number, killed) == 1, "kill switch -> luck 1")
	local skipped = Logic.withStop(EMPTY, sprinkleHour :: number, 2)
	ok(Logic.flavorLuckAt((sprinkleHour :: number) + 5, skipped) == 1, "stopped surge -> luck 1")
end

-- 5. DST-free UTC math --------------------------------------------------------------------------------
do
	-- 2026 switches: US spring 03-08 07:00Z, EU spring 03-29 01:00Z, EU autumn 10-25 01:00Z,
	-- US autumn 11-01 06:00Z.
	local switches = {
		{ month = 3, day = 8, hour = 7 },
		{ month = 3, day = 29, hour = 1 },
		{ month = 10, day = 25, hour = 1 },
		{ month = 11, day = 1, hour = 6 },
	}
	for _, switch in switches do
		local at = DateTime.fromUniversalTime({
			year = 2026,
			month = switch.month,
			day = switch.day,
			hour = switch.hour,
			minute = 0,
			second = 0,
		}).unixTimestamp
		local previous: number? = nil
		for k = Logic.slotIndex(at) - 12, Logic.slotIndex(at) + 12 do
			local slot = Logic.slot(k)
			local utc = DateTime.fromUnixTimestamp(slot.startsAt):toUniversalTime()
			ok(utc.second == 0 and (utc.minute == 0 or utc.minute == 30), "slot starts on :00 / :30 UTC")
			ok((utc.minute == 0) == not slot.mini, "headlines on the hour, minis at :30")
			if previous ~= nil then
				ok(slot.startsAt - previous == SLOT, "slots exactly 1800 s apart across a DST switch")
			end
			previous = slot.startsAt
		end
		-- The headline of the switch hour is the one of its UTC hour index, nothing local.
		ok(Logic.liveAt(at, EMPTY).id == Logic.headlineOf(at // HOUR), "switch hour headline by UTC index")
	end
end

-- 6. Override -----------------------------------------------------------------------------------------
do
	local now = T0 + 600 -- 10:10 UTC: nothing live
	ok(Logic.liveAt(now, EMPTY) == nil, "quiet at :10")
	-- Force.
	local forced = Logic.withForce(EMPTY, "stampede", now, 120, 10)
	ok(forced ~= nil and forced.v == 10, "force builds a new override")
	local live = Logic.liveAt(now + 1, forced)
	ok(live ~= nil and live.id == "stampede" and live.forced and live.world == "dino", "forced stampede live")
	ok(Logic.liveAt(now + 120, forced) == nil, "force ends after its seconds")
	ok(Logic.withForce(EMPTY, "nope", now, 60, 1) == nil, "force refuses unknown ids")
	ok(Logic.withForce(EMPTY, "confetti", 0 / 0, 60, 1) == nil, "force refuses NaN time")
	local clamped = Logic.withForce(EMPTY, "confetti", now, 99999, 1) :: any
	ok(clamped.force.endsAt - clamped.force.startsAt == Config.Override.ForceMaxSeconds, "force length clamped")
	local defaulted = Logic.withForce(EMPTY, "confetti", now, nil, 1) :: any
	ok(defaulted.force.endsAt - defaulted.force.startsAt == HEAD, "force default = headline length")
	-- A force hides a scheduled start inside it, and the slot reappears after it.
	local over = Logic.withForce(EMPTY, "doublePops", T0 + SLOT - 30, 120, 3) :: any
	ok(Logic.liveAt(T0 + SLOT + 10, over).id == "doublePops", "force beats the scheduled mini")
	ok(Logic.liveAt(T0 + SLOT + 100, over).id == "sprinkle", "the mini resumes after the force")
	local hiddenNext = Logic.nextAt(T0 + SLOT - 20, over)
	ok(hiddenNext ~= nil and hiddenNext.startsAt == T0 + HOUR, "next skips a slot that starts inside the force")
	-- Stop: a forced event, then a scheduled one.
	local stoppedForce, stoppedId = Logic.withStop(forced :: any, now + 5, 11)
	ok(stoppedId == "stampede" and stoppedForce.force == nil, "stop clears a live force")
	local stopped, scheduledId = Logic.withStop(EMPTY, T0 + 30, 12)
	ok(scheduledId == Logic.headlineOf(T0 // HOUR), "stop names the scheduled event")
	ok(Logic.liveAt(T0 + 31, stopped) == nil and Logic.isSkipped(stopped, T0), "stop skips the live slot")
	local _, nothing = Logic.withStop(EMPTY, now, 13)
	ok(nothing == nil, "stop with nothing live")
	-- Skip next.
	local skipped, slot = Logic.withSkipNext(EMPTY, now, 14)
	ok(slot ~= nil and slot.startsAt == T0 + SLOT and Logic.isSkipped(skipped, T0 + SLOT), "skip = the next slot")
	local nextAfterSkip = Logic.nextAt(now, skipped)
	ok(nextAfterSkip ~= nil and nextAfterSkip.startsAt == T0 + HOUR, "next moves past the skipped slot")
	-- Kill switch.
	local killed = Logic.withKill(EMPTY, true, now, 15)
	ok(Logic.liveAt(T0 + 1, killed) == nil and Logic.nextAt(now, killed) == nil, "kill switch: nothing live / next")
	ok(#Logic.upcoming(now, 8, killed) == 0, "kill switch: empty schedule")
	local revived = Logic.withKill(killed, false, now, 16)
	ok(Logic.liveAt(T0 + 1, revived) ~= nil, "kill switch off: back on schedule")
	-- Upcoming rows.
	local rows = Logic.upcoming(T0 + 1, 8, EMPTY)
	ok(#rows == 8 and rows[1].startsAt == T0 and rows[2].startsAt == T0 + SLOT, "upcoming: live first")
	for index = 2, #rows do
		ok(rows[index].startsAt > rows[index - 1].startsAt, "upcoming strictly increasing")
	end
	-- Prune + MaxSkips.
	local many = EMPTY
	for step = 1, 40 do
		many = (Logic.withSkipNext(many, now + step * SLOT, 100 + step))
	end
	ok(#many.skips <= Config.Override.MaxSkips, "skips bounded")
	local pruned = Logic.prune(many, now + 100 * SLOT)
	ok(#pruned.skips == 0, "old skips pruned")
	-- Sanitize.
	ok(Logic.sanitize(nil) == nil and Logic.sanitize("x") == nil and Logic.sanitize({ v = 0 / 0 }) == nil, "junk refused")
	ok(Logic.sanitize({ v = -1 }) == nil, "negative version refused")
	local cleaned = Logic.sanitize({
		v = 5,
		kill = "yes",
		force = { id = "hack", startsAt = 1, endsAt = 2 },
		skips = { 1800, 1801, 0 / 0, "x", 3600, 3600 },
		extra = true,
	}) :: any
	ok(cleaned.kill == false and cleaned.force == nil, "bad kill / force dropped")
	ok(#cleaned.skips == 2 and cleaned.skips[1] == 1800 and cleaned.skips[2] == 3600, "only whole-slot unique skips")
	ok(cleaned.extra == nil, "unknown fields dropped")
	local long = Logic.sanitize({ v = 1, force = { id = "confetti", startsAt = 0, endsAt = 999999 } }) :: any
	ok(long.force == nil, "over-long force refused")
	local hostile = {}
	for index = 1, 100000 do
		hostile[index] = index * SLOT
	end
	local bounded = Logic.sanitize({ v = 1, skips = hostile }) :: any
	ok(#bounded.skips <= Config.Override.MaxSkips, "hostile skip array bounded")
	-- Encode / attributes round trip.
	local full = Logic.withSkipNext(Logic.withForce(EMPTY, "lowGravity", now, 200, 50) :: any, now, 51)
	local decoded = Logic.sanitize(Logic.encode(full)) :: any
	ok(decoded.v == 51 and decoded.force.id == "lowGravity" and #decoded.skips == 1, "encode round trip")
	local attributes = Logic.toAttributes(full)
	local rebuilt = Logic.overrideFromAttributes(function(name: string): any
		return attributes[name]
	end)
	ok(rebuilt.v == 51 and rebuilt.force ~= nil and rebuilt.force.id == "lowGravity", "attributes round trip: force")
	ok(rebuilt.skips[1] == full.skips[1], "attributes round trip: skips")
	local blank = Logic.overrideFromAttributes(function(): any
		return nil
	end)
	ok(blank.v == 0 and not blank.kill and blank.force == nil, "missing attributes = no override")
	-- Installed override (what FlavorLogic's flavorLuckAt(now) uses).
	Logic.setOverride(killed)
	ok(Logic.liveAt(T0 + 1) == nil and Logic.currentOverride().kill, "installed override used by default")
	Logic.setOverride("junk")
	ok(not Logic.currentOverride().kill and Logic.liveAt(T0 + 1) ~= nil, "junk installs the empty (default ON) override")
	Logic.setOverride(EMPTY)
	ok(Logic.liveAt(T0 + 1) ~= nil, "installed ON override runs the schedule")
	Logic.setOverride(nil)
	ok(Logic.signature(nil) == "" and Logic.signature(Logic.liveAt(T0, EMPTY)) == `{Logic.headlineOf(T0 // HOUR)}@{T0}`, "signature")
end

-- 7. Pickups ------------------------------------------------------------------------------------------
do
	local fallWire = {
		id = "H1",
		event = "confetti",
		style = "fall",
		golden = false,
		points = { Vector3.new(10, 1.8, 20) },
		t0 = 1000,
		life = 20,
	}
	local wire = Pickup.readWire(fallWire)
	ok(wire ~= nil and wire.id == "H1", "valid fall wire")
	local compiled = Pickup.compile(wire)
	local top = Pickup.position(compiled, 1000)
	near(top.Y, 1.8 + (Config.Events.confetti.pickup :: any).dropHeight, 1e-6, "fall starts at the cloud")
	local landed, alive = Pickup.position(compiled, 1000 + (Config.Events.confetti.pickup :: any).fallSeconds)
	ok(alive and landed == Vector3.new(10, 1.8, 20), "fall rests on its point")
	local _, dead = Pickup.position(compiled, 1020)
	ok(not dead, "dead at t0 + life")
	ok(Pickup.distance(compiled, 1005, Vector3.new(10, 3, 22), { 0 }) <= Config.Pickups.CatchRadius, "walk-in distance")
	ok(Pickup.distance(compiled, 1005, Vector3.new(40, 3, 22), { 0 }) > 20, "far away")
	ok(Pickup.distance(compiled, 1100, Vector3.new(10, 3, 20), { 0, 0.4 }) == math.huge, "long dead = huge")
	-- Float.
	local float = Pickup.readWire({
		id = "H2",
		event = "lowGravity",
		style = "float",
		golden = true,
		points = { Vector3.new(0, 13, 0) },
		t0 = 0,
		life = 25,
	})
	ok(float ~= nil and float.golden, "valid float wire")
	local floatCompiled = Pickup.compile(float)
	ok(Pickup.position(floatCompiled, 5) == Vector3.new(0, 13, 0), "float hangs still")
	ok(Pickup.distance(floatCompiled, 5, Vector3.new(0, 3, 0), { 0 }) > Config.Pickups.CatchRadius, "standing under it is too low")
	ok(Pickup.distance(floatCompiled, 5, Vector3.new(0, 11, 0), { 0 }) <= Config.Pickups.CatchRadius, "jumping reaches it")
	-- Run: the Golden Turkey path maths.
	local run = Pickup.readWire({
		id = "H3",
		event = "stampede",
		style = "run",
		golden = false,
		points = { Vector3.new(0, 0, 0), Vector3.new(0, 0, 32), Vector3.new(5, 0, 16) },
		t0 = 0,
		life = 16,
	})
	ok(run ~= nil, "valid run wire")
	local runCompiled = Pickup.compile(run)
	ok(runCompiled.path ~= nil, "run compiles to a turkey path")
	ok(Pickup.position(runCompiled, 0) == Vector3.new(0, 0, 0), "run starts at its first point")
	local moved = Pickup.position(runCompiled, 3)
	ok(moved.Z > 0, "run moves along its loop")
	ok(Pickup.distance(runCompiled, 3, moved + Vector3.new(0, 3, 0), { 0 }) < 1, "distance to the moving egg")
	-- Hostile wires.
	local bad = {
		nil,
		"x",
		{},
		{ id = "H1", event = "sprinkle", style = "fall", points = { Vector3.new() }, t0 = 0, life = 5 }, -- no pickup
		{ id = "L1", event = "confetti", style = "fall", points = { Vector3.new() }, t0 = 0, life = 5 }, -- id shape
		{ id = "H1", event = "confetti", style = "run", points = { Vector3.new() }, t0 = 0, life = 5 }, -- style
		{ id = "H1", event = "confetti", style = "fall", points = { Vector3.new() }, t0 = 0 / 0, life = 5 },
		{ id = "H1", event = "confetti", style = "fall", points = { Vector3.new() }, t0 = 0, life = 1e9 },
		{ id = "H1", event = "confetti", style = "fall", points = {}, t0 = 0, life = 5 },
		{ id = "H1", event = "confetti", style = "fall", points = { Vector3.new(0 / 0, 0, 0) }, t0 = 0, life = 5 },
		{ id = "H1", event = "confetti", style = "fall", points = { [2] = Vector3.new() }, t0 = 0, life = 5 },
		{ id = "H1", event = "stampede", style = "run", points = { Vector3.new() }, t0 = 0, life = 5 }, -- 1 point
	}
	for index, raw in bad do
		ok(Pickup.readWire(raw) == nil, `hostile wire {index} refused`)
	end
	local many = {}
	for index = 1, Config.Pickups.MaxPoints + 1 do
		many[index] = Vector3.new()
	end
	ok(Pickup.readWire({ id = "H1", event = "stampede", style = "run", points = many, t0 = 0, life = 5 }) == nil, "too many points")
	-- Ids, caps, golden.
	ok(Pickup.validId("H1") and Pickup.validId("H123456") and not Pickup.validId("H") and not Pickup.validId("Hx1"), "id shape")
	ok(not Pickup.validId(string.rep("1", 20)) and not Pickup.validId(5), "id junk")
	local stampede = Config.Events.stampede.pickup :: any
	ok(Pickup.spawnCount(stampede, 0, 0) == stampede.batch, "a herd spawns together")
	ok(Pickup.spawnCount(stampede, stampede.maxLive - 1, 0) == 1, "live cap")
	ok(Pickup.spawnCount(stampede, 0, stampede.maxPerEvent) == 0, "event cap")
	ok(Pickup.rollGolden(stampede, 0, 0) and not Pickup.rollGolden(stampede, stampede.maxGoldenPerEvent, 0), "golden cap")
	ok(not Pickup.rollGolden(stampede, 0, 0.99), "golden chance")
	local delay = Pickup.nextDelay(stampede, 0.5)
	ok(delay >= stampede.intervalMin and delay <= stampede.intervalMax, "delay window")
	local ring = Pickup.ringPoint(Vector3.new(), 8, 22, 0, 0)
	near(ring.Magnitude, 8, 1e-6, "ring radius")
	local loop = Pickup.runLoop(Vector3.new(), Vector3.new(0, 0, 1), 16, 4)
	ok(#loop == 3 and loop[1] == Vector3.new(0, 0, -16) and loop[2] == Vector3.new(0, 0, 16), "run loop")
end

-- 8. Analytics allowlist ------------------------------------------------------------------------------
do
	for _, id in Config.EventIds do
		for _, head in { "start", "seen", "spawn", "pickup", "golden" } do
			local key = `hh:{head}:{id}`
			ok(KeySpec.check("event", key) == key, `analytics key {key} allowlisted`)
		end
	end
	ok(KeySpec.check("event", "hh:gems") == "hh:gems", "hh:gems allowlisted")
	for _, action in { "force", "stop", "skip", "on", "off" } do
		ok(KeySpec.check("event", `hh:admin:{action}`) ~= nil, `hh:admin:{action} allowlisted`)
	end
	ok(KeySpec.check("event", "hh:pickup:nope") == nil, "unknown event id refused")
	ok(#KeySpec.invalidPatterns() == 0, "every recorder pattern compiles")
end

-- 9. Low gravity vs server reach checks ---------------------------------------------------------------
do
	local def = Config.Events.lowGravity
	local world = def.world :: string
	local Limits = WorldGravityConfig.Limits
	local row = (WorldClientConfig :: any).Physics[world]
	local base = if row ~= nil then row.gravityScale else 0.4
	local scale = math.clamp(math.min(base, 0.4) * (def.gravityMultiplier :: number), Limits.MinScale, Limits.MaxScale)
	local gravity = 196.2 * scale
	local apex = MovementConfig.JumpPower ^ 2 / (2 * gravity)
	local measured = apex * 1.15 -- the Humanoid take-off margin tests/world-gravity.luau uses
	local service = fs.readFile("src/server/Tycoon/TycoonService.luau")
	local padVertical = tonumber(string.match(service, "TycoonService%.PadReachVertical = ([%d%.]+)")) or 0
	local clickVertical = tonumber(string.match(service, "TycoonService%.ClickReachVertical = ([%d%.]+)")) or 0
	print(`[happy-hours] Low-Gravity Hour scale {scale}: measured apex {math.floor(measured * 10) / 10} studs`)
	ok(padVertical >= measured + 3, `PadReachVertical {padVertical} >= event apex {measured} + 3`)
	ok(clickVertical >= measured + 3, `ClickReachVertical {clickVertical} >= event apex {measured} + 3`)
	ok(60 >= measured * 2, "boundary walls stay over twice the event apex")
	ok((def.glideFallSpeed :: number) > 0, "glide caps the fall")
	-- Floating moon rocks are reachable with a normal low-gravity jump (root ~3 above the feet).
	local pickup = def.pickup :: any
	ok(pickup.floatMax <= apex + 3 + Config.Pickups.FloatVerticalTolerance + Config.Pickups.CatchRadius, "moon rocks reachable")
	-- ... but never by just standing under them (root ~3 above the feet).
	ok(pickup.floatMin - 3 - Config.Pickups.FloatVerticalTolerance > Config.Pickups.CatchRadius, "moon rocks need a jump")
end

-- 10. HUD pill + start banner --------------------------------------------------------------------------
do
	local function at(unix: number): string
		return `{unix % 100}:00 PM`
	end
	-- Copy: one short line; phones show the LIVE state only.
	local live = Logic.liveAt(T0 + 10, EMPTY)
	local liveText = ChipLogic.chipText(live, Logic.nextAt(T0 + 10, EMPTY), T0 + 10, false, at)
	local liveDef = Config.get(live.id)
	ok(liveText ~= nil and liveText.live and liveText.text == `LIVE: {liveDef.short} 4:50`, `live line ({liveText and liveText.text})`)
	ok(liveText.color == liveDef.color and liveText.icon == Config.Client.PillIcon, "live colour + star")
	local phoneLive = ChipLogic.chipText(live, nil, T0 + 10, true, at)
	-- R138: a phone shows only the countdown, in the event's colour with the star.
	ok(phoneLive ~= nil and phoneLive.live and phoneLive.text == "4:50", `phones show the live countdown ({phoneLive and phoneLive.text})`)
	ok(phoneLive.color == liveDef.color and phoneLive.icon == Config.Client.PillIcon, "phone: event colour + star")
	local soon = ChipLogic.chipText(nil, Logic.nextAt(T0 + 600, EMPTY), T0 + 600, false, at)
	ok(soon ~= nil and not soon.live and soon.text == "SPRINKLES IN 20:00" and soon.color == "blue", `next within the hour ({soon and soon.text})`)
	ok(ChipLogic.chipText(nil, Logic.nextAt(T0 + 600, EMPTY), T0 + 600, true, at) == nil, "phones hide the NEXT state")
	local farNext = { id = "doublePops", startsAt = T0 + 2 * HOUR, endsAt = T0 + 2 * HOUR + HEAD, mini = false, forced = false, luck = 1 }
	local later = ChipLogic.chipText(nil, farNext, T0, false, at)
	ok(later.text == `DOUBLE POPS AT {string.upper(at(T0 + 2 * HOUR))}`, `later = local clock ({later.text})`)
	ok(ChipLogic.chipText(nil, nil, T0, false, at) == nil, "off / kill switch: nothing to show")
	for _, id in Config.EventIds do
		local def = Config.get(id)
		ok(#`LIVE: {def.short} 4:59` <= 22, `{id} live line stays short`)
	end
	ok(ChipLogic.countdownVisible(nil, farNext, T0) == false, "no ticker for far events")
	ok(ChipLogic.countdownVisible(live, nil, T0) == true, "ticker while live")
	ok(ChipLogic.clock(192) == "3:12" and ChipLogic.clock(3723) == "1:02:03" and ChipLogic.clock(0 / 0) == "0:00", "clock")
	ok(ChipLogic.rowTime(live, T0 + 10, at) == "LIVE 4:50", "row live time")
	-- Size: compact on desktop, a >= 44 pt tap target with >= 14 pt text on the smallest phone scale.
	local desktopSize = ChipLogic.size(liveText.text, false)
	local phoneSize = ChipLogic.size(phoneLive.text, true)
	ok(desktopSize.Y == Config.Client.PillHeight and desktopSize.Y <= 56, "desktop pill ~52 design px tall")
	ok(desktopSize.X < 480, `desktop pill compact ({desktopSize.X})`)
	local phoneScale = 0.62 -- DeviceConfig.Scale.Phone.min
	ok(phoneSize.Y * phoneScale >= 44, "phone pill tap target >= 44 pt")
	ok(Config.Client.PillTextSizePhone * phoneScale >= 14, "phone pill text >= 14 pt")
	-- R138: the phone pill is a small chip (was ~446 design px wide with the full line) and keeps
	-- its width while the clock ticks from "10:00" to "9:59".
	ok(phoneSize.X <= 162, `phone pill fits the measured iPhone 14 gap ({phoneSize.X})`)
	ok(phoneSize.X < 447 * 0.4, "phone pill well under half its old 447 design px width")
	ok(ChipLogic.size("10:00", true) == ChipLogic.size("9:59", true), "width stable while ticking")
	ok(ChipLogic.size("0:13", true) == phoneSize, "every clock has the same width")

	-- Placement: never over a HUD zone / obstacle, never off screen; phones only under the stack.
	local function check(label: string, input: any, expected: string)
		local rect, which = ChipLogic.place(input)
		ok(which == expected, `{label}: {which} (expected {expected})`)
		if rect == nil then
			return
		end
		ok(rect.x >= 0 and rect.y >= input.safeTop, `{label}: on screen (top-left)`)
		ok(rect.x + rect.w <= input.canvas.X and rect.y + rect.h <= input.canvas.Y, `{label}: on screen`)
		for name, zone in input.zones do
			ok(not ChipLogic.overlaps(rect, zone, 0), `{label}: clear of {name}`)
		end
		for index, obstacle in input.obstacles do
			ok(not ChipLogic.overlaps(rect, obstacle, 0), `{label}: clear of obstacle {index}`)
		end
		-- Never over the screen centre (the character).
		local cx, cy = input.canvas.X / 2, input.canvas.Y / 2
		ok(not (cx > rect.x and cx < rect.x + rect.w and cy > rect.y and cy < rect.y + rect.h), `{label}: not over the centre`)
	end
	local desktopZones = {
		Top = { x = 660, y = 20, w = 600, h = 190 },
		Left = { x = 110, y = 330, w = 300, h = 600 },
		Right = { x = 1640, y = 380, w = 220, h = 660 },
		Bottom = { x = 640, y = 940, w = 640, h = 110 },
		TopRight = { x = 1790, y = 60, w = 100, h = 90 },
	}
	-- Desktop / console: top-left, under the Roblox top-bar buttons (an obstacle) and the badge.
	check("desktop", {
		canvas = Vector2.new(1920, 1080),
		safeTop = 58,
		size = desktopSize,
		gap = 14,
		zones = desktopZones,
		obstacles = { { x = 1180, y = 100, w = 110, h = 70 }, { x = 0, y = 0, w = 120, h = 58 } },
		phone = false,
	}, "topLeft")
	-- Console with a TV-safe top bar band reaching lower: still clear of it.
	check("console", {
		canvas = Vector2.new(1920, 1080),
		safeTop = 10,
		size = desktopSize,
		gap = 14,
		zones = desktopZones,
		obstacles = { { x = 0, y = 0, w = 130, h = 64 } },
		phone = false,
	}, "topLeft")
	-- Phone: tucked under the currency stack, small enough to clear the badge and the grid.
	local phoneZones = {
		Top = { x = 785, y = 10, w = 600, h = 230 },
		Left = { x = 140, y = 150, w = 330, h = 520 },
		Right = { x = 1840, y = 340, w = 220, h = 400 },
		Bottom = { x = 660, y = 800, w = 850, h = 180 },
		TopRight = { x = 1900, y = 150, w = 130, h = 130 },
	}
	check("phone", {
		canvas = Vector2.new(2170, 1000),
		safeTop = 70,
		size = phoneSize,
		gap = 14,
		zones = phoneZones,
		obstacles = { { x = 1380, y = 90, w = 150, h = 110 } },
		phone = true,
	}, "rightOfTop")
	-- R138: right of the stack in the top band, pushed down under the boost badge when it is there.
	do
		local rect = ChipLogic.place({
			canvas = Vector2.new(2170, 1000),
			safeTop = 70,
			size = phoneSize,
			gap = 14,
			zones = phoneZones,
			obstacles = { { x = 1380, y = 90, w = 150, h = 110 } },
			phone = true,
		})
		assert(rect ~= nil, "phone rect")
		ok(rect.x >= phoneZones.Top.x + phoneZones.Top.w, "phone chip right of the currency stack")
		ok(rect.y >= 90 + 110, "phone chip slides under the boost badge")
		ok(rect.y + rect.h <= phoneZones.Top.y + phoneZones.Top.h + 80, "phone chip stays in the top band")
		local free = ChipLogic.place({
			canvas = Vector2.new(2170, 1000),
			safeTop = 70,
			size = phoneSize,
			gap = 14,
			zones = phoneZones,
			obstacles = {},
			phone = true,
		})
		assert(free ~= nil, "phone rect without a badge")
		ok(free.y == 84, `no badge: level with the top band ({free.y})`)
	end
	-- R138 regression: zones MEASURED on an iphone_14 preset in Studio (2026-11-01). The old 177 px
	-- chip fit neither side gap and sat above the character's head ("underTop").
	local iphone14 = {
		canvas = Vector2.new(1208, 626),
		safeTop = 94,
		size = phoneSize,
		gap = 14,
		zones = {
			Top = { x = 404, y = 8, w = 400, h = 166 },
			Left = { x = 16, y = 104, w = 198, h = 225 },
			Right = { x = 1073, y = 220, w = 119, h = 236 },
			Bottom = { x = 344, y = 514, w = 520, h = 96 },
			TopRight = { x = 942, y = 104, w = 250, h = 71 },
		},
		obstacles = { { x = 0, y = 0, w = 335, h = 94 } },
		phone = true,
	}
	check("iphone 14 measured", iphone14, "leftOfTop")
	local oldChip = table.clone(iphone14)
	oldChip.size = Vector2.new(177, 72)
	check("iphone 14, a chip too wide for the side gaps", oldChip, "underTopRight")
	-- Something right of the stack (e.g. a wide INVITE row): left of the stack instead.
	local busyRight = table.clone(phoneZones)
	busyRight.TopRight = { x = 1395, y = 60, w = 700, h = 230 }
	check("phone right busy", {
		canvas = Vector2.new(2170, 1000),
		safeTop = 70,
		size = phoneSize,
		gap = 14,
		zones = busyRight,
		obstacles = {},
		phone = true,
	}, "leftOfTop")
	-- Both sides of the stack taken: under the INVITE row, still off the character.
	local busyBoth = table.clone(busyRight)
	busyBoth.Left = { x = 0, y = 60, w = 780, h = 600 }
	busyBoth.Right = { x = 1395, y = 60, w = 700, h = 600 }
	check("phone both sides busy", {
		canvas = Vector2.new(2170, 1000),
		safeTop = 70,
		size = phoneSize,
		gap = 14,
		zones = busyBoth,
		obstacles = {},
		phone = true,
	}, "underTopRight")
	-- Nothing free under the INVITE row either: the last resort, under the stack.
	local busyAll = table.clone(busyBoth)
	busyAll.TopRight = { x = 1395, y = 60, w = 700, h = 700 }
	check("phone every side busy", {
		canvas = Vector2.new(2170, 1000),
		safeTop = 70,
		size = phoneSize,
		gap = 14,
		zones = busyAll,
		obstacles = {},
		phone = true,
	}, "underTop")
	-- A tall stack reaching the centre: no room under it, but the R138 chip fits beside it.
	check("phone crowded", {
		canvas = Vector2.new(1200, 620),
		safeTop = 40,
		size = phoneSize,
		gap = 14,
		zones = { Top = { x = 300, y = 0, w = 600, h = 300 }, Bottom = { x = 300, y = 360, w = 600, h = 260 } },
		obstacles = {},
		phone = true,
	}, "rightOfTop")
	-- Phone with no clean spot (the stack spans the width and reaches the centre): hidden, banner only.
	check("phone full", {
		canvas = Vector2.new(1200, 620),
		safeTop = 40,
		size = phoneSize,
		gap = 14,
		zones = { Top = { x = 0, y = 0, w = 1200, h = 300 }, Bottom = { x = 300, y = 360, w = 600, h = 260 } },
		obstacles = {},
		phone = true,
	}, "none")
	-- Crowded desktop: hidden rather than overlapping.
	check("crowded", {
		canvas = Vector2.new(800, 400),
		safeTop = 40,
		size = desktopSize,
		gap = 14,
		zones = { Top = { x = 0, y = 0, w = 800, h = 400 } },
		obstacles = {},
		phone = false,
	}, "none")

	-- Start banner: once per instance (forced ones too), deferred — not dropped — while blocked.
	local show, signature = ChipLogic.shouldAnnounce("", live, true, false)
	ok(show and signature == Logic.signature(live), "a new live event announces")
	local again = ChipLogic.shouldAnnounce(signature, live, true, false)
	ok(not again, "the same instance never announces twice")
	local blocked, kept = ChipLogic.shouldAnnounce("", live, false, false)
	ok(not blocked and kept == "", "loading screen: deferred, nothing remembered")
	local guided = ChipLogic.shouldAnnounce("", live, true, true)
	ok(not guided, "guided tutorial: deferred")
	ok(ChipLogic.shouldAnnounce("", live, true, false), "after the block lifts it announces")
	ok(not ChipLogic.shouldAnnounce("", nil, true, false), "nothing live: no banner")
	-- An admin Force mid-hour is a NEW instance: the banner shows and the pill turns LIVE.
	local forced = Logic.withForce(EMPTY, "confetti", T0 + 900, 240, 77) :: any
	local forcedLive = Logic.liveAt(T0 + 901, forced)
	ok(forcedLive ~= nil and forcedLive.forced and forcedLive.id == "confetti", "force is live at once")
	ok((ChipLogic.shouldAnnounce(signature, forcedLive, true, false)), "a forced event announces")
	local forcedText = ChipLogic.chipText(forcedLive, Logic.nextAt(T0 + 901, forced), T0 + 901, false, at)
	ok(forcedText ~= nil and forcedText.live and forcedText.text == "LIVE: CONFETTI 3:59", `forced pill LIVE ({forcedText and forcedText.text})`)
	local bannerTitle, bannerLine = ChipLogic.bannerText(forcedLive, true, "")
	ok(bannerTitle == "CONFETTI STORM!" and bannerLine == Config.Events.confetti.banner, "banner lines")
	local miniTitle, miniLine = ChipLogic.bannerText(Logic.liveAt(T0 + SLOT + 5, EMPTY), true, "")
	ok(miniTitle == "SPRINKLE SURGE!" and miniLine == Config.Client.MiniTagline, "mini banner line")
	local away = { id = "stampede", startsAt = T0, endsAt = T0 + HEAD, mini = false, forced = false, world = "dino", luck = 1 }
	local _, awayLine = ChipLogic.bannerText(away, false, "Dino Valley")
	ok(awayLine == "Now in Dino Valley! Hop over to join!", "away banner names the world")
	ok(Config.Client.BannerSeconds >= 4, "banner holds long enough to be seen")
end

print(`happy-hours: {checks} checks passed`)
