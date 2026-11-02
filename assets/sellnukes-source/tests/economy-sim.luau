--!strict
--[[
	Economy pacing simulator (spec §2 "Pacing target", plan "Tycoon").

	What it does
		Loads the REAL TycoonConfig / TycoonLogic / RebirthConfig and plays the whole game with a
		realistic greedy player, event-driven (income is constant between purchases, so the sim
		jumps straight to the moment the next chosen purchase becomes affordable — exact, and
		~1000x faster than ticking every second):

		* Before a producer's Manager the player CLICKS it: a cycle starts ReactionSeconds after the
		  previous one finished, so manual income = clickValue / (clickCycleTime + ReactionSeconds).
		  Only the newest producer is ever manual (every area's Manager comes before its Unlock).
		* Walking: stepping onto a pad costs PadWalkSeconds; acting in another area (upgrading an
		  old producer) costs AreaWalkSeconds per area of distance (capped). Manual clicking
		  pauses while walking; automated producers keep paying.
		* Purchase choice — "goal" pads (a new area's builder pad, Manager, Feature, Unlock) are
		  beelined: the player saves for them and only buys a producer upgrade if doing so reaches
		  the goal sooner. Otherwise the player buys whatever has the best payback score
		  cost / income + cost / gain (time to afford + time to earn it back) among: +1 level and
		  "to the next milestone" for every producer, and the next 1..3 pads as a bundle (so a weak
		  decoration pad in front of a strong multiplier is valued together with it).
		* Per area it records the minutes from opening the area to buying its Unlock pad.

		Asserts every area lands within TycoonConfig.Pacing.Tolerance (+/-20 %) of its target and
		(R122 / R130 / R137, OPENING_CHECKS) that each checked area hires its first Manager early
		with no long wait between pads (area 1 also: no 45 s without a new pad in its first 2 min),
		then simulates run 2 after one rebirth (tokens spent greedily in the Rebirth
		shop) and asserts it is clearly faster. Prints both tables, the opening, the cash scale
		reached and the Rebirth Token reward.

	Retuning
		lune run tests/economy-sim.luau [--world <id>] --tune [--write] [--upto <n>]
		Area by area (each on top of the already-tuned earlier ones) it sets the producer's
		baseRevenue from the measured arrival income (SIM.StartFraction) and bisects the area's
		`local SCALE = ...` until the area takes its target minutes (never past a SCALE that breaks
		OPENING_CHECKS). Prints the values; --write rewrites the AreaNN.luau lines in place;
		--upto <n> tunes only areas 1..n (later areas keep their values — R122 re-paced the Garage
		Lab alone). Re-run without --tune afterwards. docs/economy.md.
		For a non-main world it also sets the rebirth shop's starting-currency values (Dino: the
		"Bone Stash") to the tuned Unlock-pad prices of areas 1..N (the currency that opens the
		next area) and rewrites the `local STASH_VALUES = { ... }` line of <Name>Rebirth.luau.

	Worlds (World 2 plan §4 W1.5)
		--world <id> (default "main") simulates that world's economy through WorldsConfig +
		TycoonLogic.forWorld(id): its areas (Worlds/<Name>/Areas/AreaNN), pacing targets, rebirth
		track (Amber for Dino) and number scale. The simulated player has no bonuses (no pets,
		passes or cross-world link): veterans arrive faster, which is the intended reward.
		check.sh runs this file once with no arguments: Nuke Town, then every other world in
		WorldsConfig.Order (all must pass).

	Surprise Batches (owner R89, Shared/Config/FlavorConfig): every batch rolls a flavour that may
	pay x2 .. x100. The simulated player earns the AVERAGE of that — every producer's income is
	multiplied by FlavorLogic.expectedMultiplier(FlavorConfig.PacingLuck) (+7.1 % today) — so the
	pacing below already contains the flavour lift and FlavorConfig odds / multipliers are tuned
	against it (docs/economy.md "Surprise Batches"). --no-flavor drops the lift for a comparison.

	Mega Lever + Tip Jar (owner R90, Shared/Config/KineticConfig): from KineticConfig.UnlockArea on,
	every producer's income is also multiplied by 1 + KineticLogic.pacingLift(flavour lift) — a pull
	every cooldown at the batch ceiling + the jar always filling (+6.3 % today, capped by
	KineticConfig.Pacing.MaxLift). --no-kinetic drops it (docs/economy.md "Mega Lever + Tip Jar").

	(The R115 Order Window auto-serve lift, +3.6 % once the window area's manager was owned, went
	away with the order system: owner R128 "bro honestly just remove the orders system entirely".)

	Run: lune run tests/economy-sim.luau              (from the repo root; every world)
	     lune run tests/economy-sim.luau --world dino (one world)
	     lune run tests/economy-sim.luau --timeline   (also prints every pad purchase with time + income)
	     lune run tests/economy-sim.luau --tune --write --upto 1 (re-pace the Garage Lab only, R122)
	     lune run tests/economy-sim.luau --no-flavor  (pacing without the R89 flavour lift)
	     lune run tests/economy-sim.luau --no-kinetic (pacing without the R90 Mega Lever + Tip Jar lift)
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

--------------------------------------------------------------------------------------------------
-- Simulated player behaviour (sim-only constants; game tunables live in TycoonConfig)
--------------------------------------------------------------------------------------------------

local TIMELINE = table.find(process.args, "--timeline") ~= nil

-- --world <id>: which world to simulate / tune (nil = every world in WorldsConfig.Order).
local WORLD_ARG: string? = nil
do
	local at = table.find(process.args, "--world")
	if at ~= nil then
		WORLD_ARG = process.args[at + 1]
		assert(WORLD_ARG ~= nil and string.match(WORLD_ARG, "^[a-z][a-z0-9]*$"), "--world needs a world id")
	end
end

local SIM = {
	ReactionSeconds = 0.25, -- delay between a manual bar filling and the next click
	PadWalkSeconds = 3, -- walking onto the next pad in the current area
	AreaWalkSeconds = 4, -- per area of distance when acting in another area
	MaxWalkSeconds = 12, -- longest walk (teleport menu caps it)
	BundleDepth = 3, -- how many upcoming pads are valued together
	-- --tune: a new producer's level-1 clicked income = this fraction of the income on arrival.
	StartFraction = 0.01,
	MaxSimSeconds = 40 * 3600, -- safety stop (a broken config must fail, not hang)
	MaxDecisions = 2_000_000,
	-- Run 2 must take at most this fraction of run 1 ("clearly faster").
	Run2MaxFraction = 0.85,
	-- Rebirth shop priority for the simulated player (cheapest affordable first among these;
	-- clickPower = "Power Production").
	ShopPriority = { "clickPower", "managerSpeed", "startingCash", "rebirthPower" },
}

--[[
	R122 "automation by minute ~4" (spec 2026-11-01 §2.2): the opening a first-run player gets.
	Live data: players hand-clicked the Workbench ~11 min before Uncle Atom and the tutorial lost
	74 % between step 6 and 7, so Uncle Atom moved to pad 4 of the Garage Lab and the sim now
	asserts, per world and checked area (only worlds / areas listed here are checked):
		* firstManagerMinutes — the greedy run-1 player hires the area's first Manager by then
		                        (counted from the moment the area opens);
		* maxPadGapSeconds    — no two consecutive pad purchases of the area (counted from the
		                        moment the area opens, the free builder pad included) lie further apart.
	Owner R130 added BoomDash Delivery (area 3): live data showed its Manager (Dispatcher) as pad 8
	after a 6:20 wait and 41 -> 4 players reaching the next area; the Dispatcher is pad 4 now.
	Owner R137 ("do whatever you want and fix"; ~50 % of first sessions end within 3 min) re-paced
	the first two minutes of the Garage Lab and added the Nuke Stand (area 2, Cashier Bot pad 4):
		* earlyMinutes / earlyGapSeconds (optional) — inside the area's first `earlyMinutes` there is
		                        never a stretch longer than `earlyGapSeconds` without a new pad
		                        (waits clipped at the window's end, the area opening counts as a
		                        start): "something new builds every 20-40 s" while a first-time
		                        player decides whether to stay.
	The tuner (--tune) honours the same limits for the area it tunes: it never picks a SCALE whose
	run breaks them, taking the passing SCALE closest to the target from a grid (R137 — the limits
	are not monotone in SCALE, see tune) (docs/economy.md "Garage Lab opening" / "BoomDash order" /
	"Nuke Stand order (R137)").
]]
type OpeningCheck = {
	area: number,
	firstManagerMinutes: number,
	maxPadGapSeconds: number,
	earlyMinutes: number?,
	earlyGapSeconds: number?,
}
local OPENING_CHECKS: { [string]: { OpeningCheck } } = {
	main = {
		-- Owner R137: sim today Tool Wall 0.48 / Glow Lamp 0.64 / Uncle Atom 1.22 / Garage Door 1.90 min,
		-- longest early stretch 41 s, longest wait 83 s (R122: 1.10 / 1.61 / 1.93 / 2.54 min, 63 s, 83 s).
		{ area = 1, firstManagerMinutes = 1.5, maxPadGapSeconds = 85, earlyMinutes = 2, earlyGapSeconds = 45 },
		-- Owner R137: sim today 0.85 min / ~132 s (the old order: 6.5 min / 189 s).
		{ area = 2, firstManagerMinutes = 2.0, maxPadGapSeconds = 150 },
		-- Owner R130: sim today 1.7 min / ~265 s (the old order: 18.2 min / 402 s).
		{ area = 3, firstManagerMinutes = 3.0, maxPadGapSeconds = 300 },
	},
}

-- Owner R89 Surprise Batches: the average payout multiplier of a batch at the pacing luck, applied
-- to every producer's income (clicked and automated alike — both roll flavours on the server).
-- Loaded through the Roblox loader fixture because FlavorConfig reads ReplicatedStorage paths.
local FLAVOR_MULTIPLIER = 1
if table.find(process.args, "--no-flavor") == nil then
	local Loader = require("./fixtures/RobloxLoader")
	local flavorLoader = Loader.new()
	local FlavorConfig = flavorLoader.load("src/shared/Config/FlavorConfig")
	local FlavorLogic = flavorLoader.load("src/shared/Tycoon/FlavorLogic")
	-- The ship switch: with Surprise Batches off nobody rolls, so the pacing has no lift.
	FLAVOR_MULTIPLIER = if FlavorConfig.DefaultEnabled
		then FlavorLogic.expectedMultiplier(FlavorConfig.PacingLuck)
		else 1
	assert(FLAVOR_MULTIPLIER >= 1 and FLAVOR_MULTIPLIER < 2, "economy sim: implausible flavour lift")
end

-- Owner R90 Mega Lever + Tip Jar (Shared/Config/KineticConfig, docs/economy.md "Mega Lever + Tip
-- Jar"): optional bonuses on top of passive income, counted CONSERVATIVELY — a pull every cooldown
-- at the batch ceiling (flavoured) + the jar's fill rate all the time — from the area the props
-- unlock at (KineticConfig.UnlockArea; area 1 stays untouched). --no-kinetic drops the lift.
local KINETIC_MULTIPLIER = 1
local KINETIC_UNLOCK_AREA = math.huge
if table.find(process.args, "--no-kinetic") == nil then
	local Loader = require("./fixtures/RobloxLoader")
	local kineticLoader = Loader.new()
	local KineticConfig = kineticLoader.load("src/shared/Config/KineticConfig")
	local KineticLogic = kineticLoader.load("src/shared/Tycoon/KineticLogic")
	KINETIC_MULTIPLIER = 1 + KineticLogic.pacingLift(FLAVOR_MULTIPLIER)
	KINETIC_UNLOCK_AREA = KineticConfig.UnlockArea
	assert(
		KINETIC_MULTIPLIER >= 1 and KINETIC_MULTIPLIER <= 1 + KineticConfig.Pacing.MaxLift + 1e-9,
		"economy sim: kinetic lift above KineticConfig.Pacing.MaxLift"
	)
end

--------------------------------------------------------------------------------------------------
-- Module loader: real sources from src/, a fake `script` so `script.Parent.X` requires resolve,
-- and optional source patches (used by --tune to swap an area's SCALE).
--------------------------------------------------------------------------------------------------

--[[
	A fake Instance path node: node("src/shared/Tycoon/TycoonLogic").Parent.Modifiers has
	.path = "src/shared/Tycoon/Modifiers".
]]
local function node(path: string): any
	return setmetatable({ path = path }, {
		__index = function(_, key)
			if key == "Parent" then
				return node(string.match(path, "^(.*)/[^/]+$") :: string)
			end
			return node(path .. "/" .. key)
		end,
	})
end

--[[
	Creates an isolated module loader (own cache) with optional per-path source patches.
	@param patches {[path]: (source) -> source}?
	@return (path) -> any
]]
local function makeLoader(patches: { [string]: (string) -> string }?): (string) -> any
	local cache: { [string]: any } = {}
	local function load(path: string): any
		if cache[path] ~= nil then
			return cache[path]
		end
		local source = fs.readFile(path .. ".luau")
		local patch = if patches then patches[path] else nil
		if patch then
			source = patch(source)
		end
		local env = {
			script = node(path),
			require = function(ref: any)
				return load(ref.path)
			end,
			-- Roblox datatypes the world registry uses at load (currency colours, world origins).
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			Vector3 = roblox.Vector3,
		}
		local value = luau.load(source, { debugName = path, environment = env })()
		cache[path] = value
		return value
	end
	return load
end

-- Where a world's area sources live: Nuke Town's TycoonAreas, other worlds' Worlds/<Name>/Areas
-- (<Name> = the id with a capital first letter: "dino" -> Worlds/Dino). Set per world by useWorld.
local AREA_PATH = "src/shared/Config/TycoonAreas/Area%02d"
-- A non-main world's rebirth track source (its STASH_VALUES line is tuned), e.g. Dino/DinoRebirth.
local REBIRTH_PATH: string? = nil
-- The world being simulated ("main" until useWorld picks another).
local WORLD = "main"

--[[
	Points the loader / tuner at a world's sources.
	@param worldId string
]]
local function useWorld(worldId: string)
	WORLD = worldId
	if worldId == "main" then
		AREA_PATH = "src/shared/Config/TycoonAreas/Area%02d"
		REBIRTH_PATH = nil
		return
	end
	local name = string.upper(string.sub(worldId, 1, 1)) .. string.sub(worldId, 2)
	AREA_PATH = `src/shared/Config/Worlds/{name}/Areas/Area%02d`
	REBIRTH_PATH = `src/shared/Config/Worlds/{name}/{name}Rebirth.luau`
	assert(fs.isFile(string.format(AREA_PATH, 1) .. ".luau"), `economy sim: no area sources for world {worldId}`)
end

-- The two tuned lines of every AreaNN.luau (see the area file headers).
local SCALE_LINE = "\nlocal SCALE = ([%d%.e%+%-]+)\n"
local REVENUE_LINE = "\n\t\tbaseRevenue = ([%d%.e%+%-]+),\n"

-- Per-area values the tuner tries (absolute, not factors). Missing fields keep the file's value.
export type AreaOverride = { scale: number?, revenue: number? }

--[[
	Reads an area source's tuned numbers.
	@param areaIndex number
	@return number, number — SCALE, baseRevenue
]]
local function readArea(areaIndex: number): (number, number)
	local source = fs.readFile(string.format(AREA_PATH, areaIndex) .. ".luau")
	local scale = tonumber(string.match(source, SCALE_LINE))
	local revenue = tonumber(string.match(source, REVENUE_LINE))
	assert(scale and revenue, `Area{areaIndex}: missing a "local SCALE = " or "baseRevenue = " line`)
	return scale :: number, revenue :: number
end

--[[
	Formats a tuned number the way the area files write it (plain integers below 1e6, else %.3g).
	@param x number
	@return string
]]
local function literal(x: number): string
	if x < 1e6 and x == math.floor(x) then
		return string.format("%d", x)
	end
	return (string.gsub(string.format("%.3g", x), "e%+0*", "e"))
end

--[[
	Rewrites an area source's SCALE / baseRevenue lines with an override.
	@param source string
	@param override AreaOverride
	@return string
]]
local function patchArea(source: string, override: AreaOverride): string
	local patched, count = source, 0
	if override.scale then
		patched, count = string.gsub(patched, SCALE_LINE, "\nlocal SCALE = " .. literal(override.scale) .. "\n", 1)
		assert(count == 1, "SCALE patch failed")
	end
	if override.revenue then
		patched, count =
			string.gsub(patched, REVENUE_LINE, "\n\t\tbaseRevenue = " .. literal(override.revenue) .. ",\n", 1)
		assert(count == 1, "baseRevenue patch failed")
	end
	return patched
end

--[[
	Loads the current world's economy, applying per-area overrides to the area sources first.
	Nuke Town: TycoonConfig / TycoonLogic / RebirthConfig exactly as before. Other worlds: the
	world's EconomyIndex (WorldsConfig), its bound Logic (TycoonLogic.forWorld) and its RebirthDef.
	@param overrides {[areaIndex]: AreaOverride}?
	@return Config (an EconomyIndex-shaped table), Logic, RebirthDef, friendlyPrice
]]
local function loadModules(overrides: { [number]: AreaOverride }?): (any, any, any, (number) -> number)
	local patches: { [string]: (string) -> string } = {}
	if overrides then
		for areaIndex, override in overrides do
			patches[string.format(AREA_PATH, areaIndex)] = function(source: string): string
				return patchArea(source, override)
			end
		end
	end
	local load = makeLoader(patches)
	local friendlyPrice = load("src/shared/Tycoon/EconomyIndex").friendlyPrice
	if WORLD == "main" then
		return load("src/shared/Config/TycoonConfig"),
			load("src/shared/Tycoon/TycoonLogic"),
			load("src/shared/Config/RebirthConfig"),
			friendlyPrice
	end
	local def = load("src/shared/Config/Worlds/WorldsConfig").get(WORLD)
	assert(def ~= nil, `economy sim: unknown world {WORLD}`)
	return def.economy, load("src/shared/Tycoon/TycoonLogic").forWorld(WORLD), def.rebirth, friendlyPrice
end

--------------------------------------------------------------------------------------------------
-- Formatting helpers
--------------------------------------------------------------------------------------------------

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

-- Currency symbol of the report: "$" for Nuke Town cash, none for count currencies (Bones).
local SYMBOL = "$"

-- Short currency string ("$1.23B" / "1.23B") for the report.
local function money(x: number): string
	if x < 1000 then
		return string.format("%s%.0f", SYMBOL, x)
	end
	local tier = math.min(math.floor(math.log10(x) / 3), #SUFFIXES - 1)
	return string.format("%s%.2f%s", SYMBOL, x / 10 ^ (tier * 3), SUFFIXES[tier + 1])
end

-- "h:mm" clock string for the cumulative column.
local function clock(seconds: number): string
	local minutes = math.floor(seconds / 60 + 0.5)
	return string.format("%d:%02d", minutes // 60, minutes % 60)
end

--------------------------------------------------------------------------------------------------
-- The simulated player
--------------------------------------------------------------------------------------------------

export type AreaResult = {
	area: number,
	name: string,
	seconds: number,
	unlockCost: number,
	incomeAtUnlock: number,
	producerLevel: number,
}

-- One pad purchase of a run (R122: the opening assertions read the Garage Lab ones).
export type PadPurchase = {
	id: string,
	area: number,
	kind: string,
	seconds: number, -- run time of the purchase (s since the run started)
	cost: number,
}

export type RunResult = {
	areas: { AreaResult },
	pads: { PadPurchase }, -- every pad bought, in purchase order
	totalSeconds: number,
	totalEarned: number,
	finalIncome: number,
	state: any,
	finished: boolean,
}

--[[
	Plays one run with the greedy player.
	@param Config, Logic — loaded TycoonConfig / TycoonLogic
	@param mods Modifiers? — rebirth bonuses for run 2
	@param startCash number
	@param stopAfterArea number? — stop once this area's Unlock pad is bought (tuning)
	@return RunResult
]]
local function simulate(Config: any, Logic: any, mods: any, startCash: number, stopAfterArea: number?): RunResult
	local state = Logic.newState()
	local cash = startCash
	local earned = 0
	local t = 0
	local location = 1
	local areaStart = 0
	local areas: { AreaResult } = {}
	local padLog: { PadPurchase } = {}
	local finalArea = stopAfterArea or #Config.Areas

	local goalPad: { [string]: boolean } = {}
	for _, pad in Config.PadOrder do
		if pad.kind == "Manager" or pad.kind == "Feature" or pad.kind == "Unlock" or Config.ProducerBuiltBy[pad.id] then
			goalPad[pad.id] = true
		end
	end

	-- Cash per second one producer contributes while the player stands at `home`.
	local function producerRate(producerId: string, home: number): number
		local cfg = Config.ProducersById[producerId]
		local level = Logic.levelOf(state, producerId)
		if level < 1 then
			return 0
		end
		-- R90: the Mega Lever + Tip Jar lift applies once the props exist (home area >= unlock).
		local lift = FLAVOR_MULTIPLIER * (if home >= KINETIC_UNLOCK_AREA then KINETIC_MULTIPLIER else 1)
		if Logic.isAutomated(state, producerId) then
			return lift * Logic.producerOutput(cfg, level, mods, state) / Logic.cycleTime(cfg, level, mods, state)
		end
		if cfg.area ~= home then
			return 0 -- manual producers only earn while the player is next to them clicking
		end
		return lift
			* Logic.clickValue(cfg, level, mods, state)
			/ (Logic.clickCycleTime(cfg, level, mods, state) + SIM.ReactionSeconds)
	end

	-- Where the player stands between purchases: the newest unlocked area, which is where the only
	-- manual producer (if any) lives — every older producer is already automated.
	local function homeArea(): number
		return state.area
	end

	-- Total cash per second while standing in area `at` (-1 = walking: automated producers only).
	local function totalRate(at: number): number
		local total = 0
		for _, cfg in Config.Producers do
			total += producerRate(cfg.id, at)
		end
		return total
	end

	-- Passes `seconds` of time while standing at `at`.
	local function advance(seconds: number, at: number)
		local gained = totalRate(at) * seconds
		cash += gained
		earned += gained
		t += seconds
	end

	-- Walk to `area` (manual clicking pauses on the way), then stand there.
	local function walkTo(area: number, extra: number)
		local seconds = extra + math.min(SIM.MaxWalkSeconds, math.abs(area - location) * SIM.AreaWalkSeconds)
		if seconds > 0 then
			advance(seconds, -1) -- -1 = "nowhere": only automated producers pay while walking
		end
		location = area
	end

	type Candidate = {
		kind: "pad" | "level",
		cost: number,
		gain: number,
		padId: string?,
		producerId: string?,
		count: number?,
	}

	-- Income gain of applying `fn` to the state (fn mutates; undo restores).
	local function gainOf(producerIds: { string }, apply: () -> (), undo: () -> ()): number
		local home = homeArea()
		local before = 0
		for _, id in producerIds do
			before += producerRate(id, home)
		end
		apply()
		local after = 0
		for _, id in producerIds do
			after += producerRate(id, home)
		end
		undo()
		return after - before
	end

	-- Upgrade options: +1 level and "up to the next milestone" for every built producer.
	local function levelCandidates(): { Candidate }
		local list: { Candidate } = {}
		for _, cfg in Config.Producers do
			local level = Logic.levelOf(state, cfg.id)
			if level >= 1 and level < Config.MaxLevel then
				local toMilestone = Config.MilestoneEvery - level % Config.MilestoneEvery
				local counts = { 1 }
				if toMilestone > 1 and level + toMilestone <= Config.MaxLevel then
					table.insert(counts, toMilestone)
				end
				for _, count in counts do
					local cost = Logic.upgradeCost(cfg, level, count)
					local gain = gainOf({ cfg.id }, function()
						state.producers[cfg.id] = level + count
					end, function()
						state.producers[cfg.id] = level
					end)
					table.insert(list, { kind = "level", cost = cost, gain = gain, producerId = cfg.id, count = count })
				end
			end
		end
		return list
	end

	-- Applies a list of pads temporarily, measuring the gain over every producer they touch.
	local function padsGain(pads: { any }): number
		local touched: { string } = {}
		local seen: { [string]: boolean } = {}
		for _, pad in pads do
			local id = pad.target or Config.ProducerBuiltBy[pad.id]
			if id and not seen[id] then
				seen[id] = true
				table.insert(touched, id)
			end
		end
		local savedLevels: { [string]: number } = {}
		local savedArea = state.area
		return gainOf(touched, function()
			for _, pad in pads do
				state.pads[pad.id] = true
				local built = Config.ProducerBuiltBy[pad.id]
				if built then
					savedLevels[built] = state.producers[built] or 0
					state.producers[built] = 1
				end
			end
		end, function()
			for _, pad in pads do
				state.pads[pad.id] = nil
			end
			for id, level in savedLevels do
				state.producers[id] = if level > 0 then level else nil
			end
			state.area = savedArea
		end)
	end

	-- Payback score in seconds: time to afford + time for the gain to repay the cost (lower = better).
	local function score(candidate: Candidate, income: number): number
		if candidate.gain <= 0 or candidate.cost == math.huge then
			return math.huge
		end
		return candidate.cost / math.max(income, 1e-9) + candidate.cost / candidate.gain
	end

	-- Pays for and applies a purchase (walking to it first), recording area completions.
	local function buy(candidate: Candidate)
		cash -= candidate.cost
		if candidate.kind == "pad" then
			local padId = candidate.padId :: string
			local pad = Config.PadsById[padId]
			walkTo(pad.area, SIM.PadWalkSeconds)
			assert(Logic.applyPad(state, padId), "pad not available: " .. padId)
			table.insert(padLog, { id = padId, area = pad.area, kind = pad.kind, seconds = t, cost = pad.cost })
			if TIMELINE then
				print(
					string.format(
						"  %7.1f min  area %2d  %-22s %-10s %10s  income %s/s  lv %d",
						t / 60,
						pad.area,
						pad.name,
						pad.kind,
						money(pad.cost),
						money(totalRate(homeArea())),
						Logic.levelOf(state, Config.Areas[pad.area].producer.id)
					)
				)
			end
			if pad.kind == "Unlock" then
				table.insert(areas, {
					area = pad.area,
					name = Config.Areas[pad.area].name,
					seconds = t - areaStart,
					unlockCost = pad.cost,
					incomeAtUnlock = totalRate(homeArea()),
					producerLevel = Logic.levelOf(state, Config.Areas[pad.area].producer.id),
				})
				areaStart = t
			end
		else
			local producerId = candidate.producerId :: string
			walkTo(Config.ProducersById[producerId].area, 0)
			Logic.applyLevels(state, producerId, candidate.count)
		end
	end

	local decisions = 0
	while #areas < finalArea do
		decisions += 1
		assert(decisions < SIM.MaxDecisions, "economy sim: too many decisions (stuck?)")
		assert(t < SIM.MaxSimSeconds, `economy sim: exceeded {SIM.MaxSimSeconds / 3600} h (area {#areas + 1})`)

		-- Stand at home (next to the manual producer) unless walking somewhere for a purchase.
		if location ~= homeArea() then
			walkTo(homeArea(), 0)
		end
		local income = totalRate(location)
		local upcoming = Logic.nextPads(state)[1]
		assert(upcoming ~= nil, "economy sim: no next pad before the finale")

		local chosen: Candidate? = nil
		if goalPad[upcoming.id] then
			-- Beeline the goal; take a detour only if it reaches the goal sooner.
			local goal: Candidate = { kind = "pad", cost = upcoming.cost, gain = 0, padId = upcoming.id }
			if cash >= goal.cost then
				chosen = goal
			else
				local direct = (goal.cost - cash) / math.max(income, 1e-9)
				local best, bestTime = goal, direct
				for _, candidate in levelCandidates() do
					if candidate.gain > 0 then
						local wait = math.max(0, candidate.cost - cash) / math.max(income, 1e-9)
						local after = math.max(0, cash - candidate.cost)
						local viaTime = wait + (goal.cost - after) / (income + candidate.gain)
						if viaTime < bestTime then
							best, bestTime = candidate, viaTime
						end
					end
				end
				chosen = best
			end
		else
			-- Best payback among levels and the upcoming pad bundles.
			local best: Candidate? = nil
			local bestScore = math.huge
			for _, candidate in levelCandidates() do
				local s = score(candidate, income)
				if s < bestScore then
					best, bestScore = candidate, s
				end
			end
			local bundle = {}
			local bundleCost = 0
			local index = Config.PadIndex[upcoming.id]
			for depth = 1, SIM.BundleDepth do
				local pad = Config.PadOrder[index + depth - 1]
				if pad == nil or goalPad[pad.id] then
					break
				end
				table.insert(bundle, pad)
				bundleCost += pad.cost
				local candidate: Candidate =
					{ kind = "pad", cost = bundleCost, gain = padsGain(bundle), padId = upcoming.id }
				local s = score(candidate, income)
				if s < bestScore then
					-- Buying a bundle = buying its first pad now; the rest are re-decided after.
					best, bestScore =
						{ kind = "pad", cost = upcoming.cost, gain = candidate.gain, padId = upcoming.id }, s
				end
			end
			chosen = best or { kind = "pad", cost = upcoming.cost, gain = 0, padId = upcoming.id }
		end

		local target = chosen :: Candidate
		if cash < target.cost then
			assert(income > 0, `economy sim: zero income while saving for {target.padId or target.producerId}`)
			advance((target.cost - cash) / income, location)
			cash = math.max(cash, target.cost) -- float guard: the wait was computed to land exactly here
		end
		buy(target)
		if stopAfterArea == nil and upcoming.id == Config.FinalePadId and Logic.canRebirth(state) then
			break
		end
	end

	return {
		areas = areas,
		pads = padLog,
		totalSeconds = t,
		totalEarned = earned + startCash,
		finalIncome = totalRate(homeArea()),
		state = state,
		finished = Logic.canRebirth(state),
	}
end

--------------------------------------------------------------------------------------------------
-- Opening checks (R122)
--------------------------------------------------------------------------------------------------

export type Opening = {
	firstManagerSeconds: number, -- seconds from the area opening to its first Manager (math.huge = none)
	maxGapSeconds: number, -- longest wait between two consecutive pad purchases of the area
	gapPadId: string?, -- the pad that ended that longest wait
	earlyMaxGapSeconds: number, -- R137: longest stretch without a pad inside the early window (0 = no window)
	earlyGapPadId: string?, -- the pad that ended (or, past the window, would end) that stretch
}

--[[
	Measures how a run opened one area: when its first Manager was hired and the longest wait
	between two of its pad purchases. Times count from the moment the area opened (the previous
	area's Unlock purchase, or the run start for area 1). With `earlyMinutes` it also measures the
	longest stretch without a new pad inside the area's first `earlyMinutes` — each wait clipped at
	the window's end (R137 cadence check).
	@param run RunResult
	@param areaIndex number
	@param earlyMinutes number? — the early window (nil = none; earlyMaxGapSeconds stays 0)
	@return Opening
	Example: measureOpening(run1, 1, 2).earlyMaxGapSeconds --> 41 (Uncle Atom -> Garage Door, R137)
	(the Garage Door -> Mini Reactor wait starts at ~1.9 min and only its first ~6 s are inside)
]]
local function measureOpening(run: RunResult, areaIndex: number, earlyMinutes: number?): Opening
	local opened = 0
	for _, pad in run.pads do
		if pad.area == areaIndex - 1 and pad.kind == "Unlock" then
			opened = pad.seconds
		end
	end
	local previous = opened
	local earlyEnd = opened + (earlyMinutes or 0) * 60
	local result: Opening = {
		firstManagerSeconds = math.huge,
		maxGapSeconds = 0,
		gapPadId = nil,
		earlyMaxGapSeconds = 0,
		earlyGapPadId = nil,
	}
	for _, pad in run.pads do
		if pad.area == areaIndex then
			local gap = pad.seconds - previous
			if gap > result.maxGapSeconds then
				result.maxGapSeconds = gap
				result.gapPadId = pad.id
			end
			-- R137: the part of this wait that lies inside the early window.
			local earlyGap = math.min(pad.seconds, earlyEnd) - previous
			if previous < earlyEnd and earlyGap > result.earlyMaxGapSeconds then
				result.earlyMaxGapSeconds = earlyGap
				result.earlyGapPadId = pad.id
			end
			previous = pad.seconds
			if pad.kind == "Manager" and result.firstManagerSeconds == math.huge then
				result.firstManagerSeconds = pad.seconds - opened
			end
		end
	end
	return result
end

--[[
	The OPENING_CHECKS limits a run breaks for the current world (empty = fine, or no check).
	@param run RunResult — must have reached the end of every checked area (or of `onlyArea`)
	@param onlyArea number? — check just this area (the tuner, whose run stops at the tuned area)
	@return {string} — human-readable failures
]]
local function openingFailures(run: RunResult, onlyArea: number?): { string }
	local failures = {}
	for _, limits in OPENING_CHECKS[WORLD] or {} do
		if onlyArea ~= nil and limits.area ~= onlyArea then
			continue
		end
		local opening = measureOpening(run, limits.area, limits.earlyMinutes)
		if opening.firstManagerSeconds > limits.firstManagerMinutes * 60 then
			table.insert(
				failures,
				string.format(
					"area %d: first Manager at %.2f min (want <= %.1f)",
					limits.area,
					opening.firstManagerSeconds / 60,
					limits.firstManagerMinutes
				)
			)
		end
		if opening.maxGapSeconds > limits.maxPadGapSeconds then
			table.insert(
				failures,
				string.format(
					"area %d: %.0f s wait before %s (want <= %d s)",
					limits.area,
					opening.maxGapSeconds,
					opening.gapPadId or "?",
					limits.maxPadGapSeconds
				)
			)
		end
		-- R137: the early cadence window, when the check has one.
		local earlyGap = limits.earlyGapSeconds
		if limits.earlyMinutes ~= nil and earlyGap ~= nil and opening.earlyMaxGapSeconds > earlyGap then
			table.insert(
				failures,
				string.format(
					"area %d: %.0f s without a new pad (before %s) inside the first %.1f min (want <= %d s)",
					limits.area,
					opening.earlyMaxGapSeconds,
					opening.earlyGapPadId or "?",
					limits.earlyMinutes,
					earlyGap
				)
			)
		end
	end
	return failures
end

-- The OPENING_CHECKS row of `areaIndex` in the current world, or nil (the tuner's guard).
local function openingCheckFor(areaIndex: number): OpeningCheck?
	for _, check in OPENING_CHECKS[WORLD] or {} do
		if check.area == areaIndex then
			return check
		end
	end
	return nil
end

--------------------------------------------------------------------------------------------------
-- Reports
--------------------------------------------------------------------------------------------------

local function printRun(title: string, Config: any, run: RunResult, compare: RunResult?)
	print(title)
	print(" #  Area                     Target   Sim min   Dev    Cum    Unlock cost   $/s at unlock   Lv")
	local cumulative = 0
	for _, area in run.areas do
		cumulative += area.seconds
		local target = Config.Pacing.TargetMinutes[area.area]
		local minutes = area.seconds / 60
		local deviation = if compare then "" else string.format("%+4.0f%%", (minutes / target - 1) * 100)
		print(
			string.format(
				"%2d  %-24s %6d %9.1f %6s %6s %13s %15s %4d",
				area.area,
				area.name,
				target,
				minutes,
				deviation,
				clock(cumulative),
				money(area.unlockCost),
				money(area.incomeAtUnlock),
				area.producerLevel
			)
		)
	end
	print(
		string.format(
			"Total %s (%.1f min); lifetime earned %s; final idle income %s/s",
			clock(run.totalSeconds),
			run.totalSeconds / 60,
			money(run.totalEarned),
			money(run.finalIncome)
		)
	)
end

--------------------------------------------------------------------------------------------------
-- Tuning mode
--------------------------------------------------------------------------------------------------

--[[
	Rounds to 3 significant digits (the precision SCALE is written with), so every value the
	tuner simulates is exactly the value it prints / writes.
]]
local function sig3(x: number): number
	local magnitude = 10 ^ (math.floor(math.log10(x)) - 2)
	return math.floor(x / magnitude + 0.5) * magnitude
end

--[[
	Sequential tuner. For area k (areas 1..k-1 already tuned), measured from the simulated player:
	1. baseRevenue_k = friendly(StartFraction * arrival income * (baseCycle + reaction)): a freshly
	                   built producer's clicked income is a small, visible slice of what the player
	                   already earns (area 1 keeps its file value — nothing is earned before it);
	2. SCALE_k       = log-space bisection (around the arrival income) until the area takes its
	                   target minutes. Every price in the area is a multiple of SCALE. In a world's
	                   OPENING_CHECKS area (Nuke Town: Garage Lab, Nuke Stand, BoomDash) a SCALE
	                   whose run breaks the opening limits (first Manager late, a pad gap too
	                   long) is never picked: when the length-matching SCALE breaks them, a grid
	                   around it (x0.25 .. x1.25, 1 % steps) supplies the passing SCALE closest to
	                   the target (R122; R137 replaced the "counts as too slow" bisection, which
	                   assumed the limits break only above one SCALE — they do not).
	Every candidate is rounded exactly as it is written, so the printed values reproduce the result.
	@param write boolean — rewrite the AreaNN.luau files in place with the tuned values
	@param upto number? — tune (and write) only areas 1..upto; later areas keep their file values
	                      (R122 re-paced the Garage Lab alone: `--tune --write --upto 1`)
]]
local function tune(write: boolean, upto: number?)
	local overrides: { [number]: AreaOverride } = {}
	local Config = loadModules(nil)
	for areaIndex = 1, math.min(#Config.Areas, upto or #Config.Areas) do
		local opening = openingCheckFor(areaIndex) -- R122 / R130 limits of this area, if any
		local scale0, revenue0 = readArea(areaIndex)
		local override: AreaOverride = { scale = scale0, revenue = revenue0 }
		overrides[areaIndex] = override
		local arrival = 1
		if areaIndex > 1 then
			local C, L, _, friendlyPrice = loadModules(overrides)
			arrival = simulate(C, L, nil, 0, areaIndex - 1).areas[areaIndex - 1].incomeAtUnlock
			local cycle = C.Areas[areaIndex].producer.baseCycle
			override.revenue = friendlyPrice(SIM.StartFraction * arrival * (cycle + SIM.ReactionSeconds))
		end

		local target = Config.Pacing.TargetMinutes[areaIndex] * 60
		local lo, hi = math.log(arrival / 1e4), math.log(arrival * 1e4)
		local bestScale, bestError, bestSeconds = scale0, math.huge, 0
		for _ = 1, 80 do
			local mid = (lo + hi) / 2
			override.scale = sig3(math.exp(mid))
			local ok, run = pcall(function()
				local C, L = loadModules(overrides)
				return simulate(C, L, nil, 0, areaIndex)
			end)
			local seconds = if ok then (run :: RunResult).areas[areaIndex].seconds else math.huge
			if math.abs(seconds - target) < bestError then
				bestScale, bestError, bestSeconds = override.scale :: number, math.abs(seconds - target), seconds
			end
			if seconds > target then
				hi = mid
			else
				lo = mid
			end
			if hi - lo < 1e-5 or bestError < 1 then
				break
			end
		end
		assert(bestError < math.huge, `economy sim: no SCALE keeps area {areaIndex} playable`)

		--[[
			Opening guard (R122 / R130 / R137 OPENING_CHECKS of this area). The limits are NOT
			monotone in SCALE: a price crossing a level milestone flips the moment one pad is
			bought (R137 Garage Lab: SCALE 5.5 breaks the 85 s wait, 6.49 keeps it, 6.8 breaks it
			again; 1.2 .. 6.0 break the 45 s early cadence), so the old "a failing SCALE counts as
			too slow" bisection settled at SCALE 1.14 / 2.8 min. Instead: if the length-matching
			SCALE breaks the limits, scan a geometric grid around it and keep the passing SCALE
			whose length is closest to the target.
		]]
		if opening ~= nil then
			-- Area length (s) at `scale` and whether the run keeps this area's opening limits.
			local function measure(scale: number): (number, boolean)
				override.scale = scale
				local ok, run = pcall(function()
					local C, L = loadModules(overrides)
					return simulate(C, L, nil, 0, areaIndex)
				end)
				if not ok then
					return math.huge, false
				end
				local result = run :: RunResult
				return result.areas[areaIndex].seconds, #openingFailures(result, areaIndex) == 0
			end
			local _, passes = measure(bestScale)
			if not passes then
				local guardScale: number? = nil
				local guardError, guardSeconds = math.huge, 0
				for step = -140, 22 do -- x1.01^-140 = x0.25 .. x1.01^22 = x1.25
					local scale = sig3(bestScale * 1.01 ^ step)
					local seconds, ok = measure(scale)
					if ok and math.abs(seconds - target) < guardError then
						guardScale, guardError, guardSeconds = scale, math.abs(seconds - target), seconds
					end
				end
				assert(guardScale ~= nil, `economy sim: no SCALE keeps area {areaIndex}'s opening limits`)
				bestScale, bestSeconds = guardScale :: number, guardSeconds
			end
		end
		override.scale = bestScale
		print(
			string.format(
				"Area%02d: SCALE = %s (%.2f s of arrival income), baseRevenue = %s  (%.1f min, target %d)",
				areaIndex,
				literal(bestScale),
				bestScale / arrival,
				literal(override.revenue :: number),
				bestSeconds / 60,
				target / 60
			)
		)
	end
	-- Non-main worlds: the rebirth shop's starting currency (Dino "Bone Stash") level k starts a run
	-- with the tuned price of area k's Unlock pad — the currency that opens area k + 1.
	local stashLine: string? = nil
	if REBIRTH_PATH ~= nil then
		local C, _, Rebirth = loadModules(overrides)
		local upgrade = Rebirth.Shop.startingCash
		assert(upgrade ~= nil and upgrade.values ~= nil, `economy sim: {WORLD} rebirth has no startingCash values`)
		assert(upgrade.maxLevel < #C.Areas, `economy sim: {WORLD} startingCash has more levels than areas - 1`)
		local values = {}
		for level = 1, upgrade.maxLevel do
			local unlockPads = C.AreaPads[level]
			table.insert(values, literal(unlockPads[#unlockPads].cost))
		end
		stashLine = "local STASH_VALUES = { " .. table.concat(values, ", ") .. " }"
		print(`{REBIRTH_PATH}: {stashLine}`)
	end
	if write then
		for areaIndex, override in overrides do
			local path = string.format(AREA_PATH, areaIndex) .. ".luau"
			fs.writeFile(path, patchArea(fs.readFile(path), override))
		end
		print(`Wrote tuned SCALE / baseRevenue into {string.format(AREA_PATH, 1)}..`)
		if REBIRTH_PATH ~= nil and stashLine ~= nil then
			local source = fs.readFile(REBIRTH_PATH)
			local patched, count =
				string.gsub(source, "\nlocal STASH_VALUES = {[^\n]*}\n", "\n" .. stashLine .. "\n", 1)
			assert(count == 1, `{REBIRTH_PATH}: missing the one-line "local STASH_VALUES = {"{ ... }"}" line`)
			fs.writeFile(REBIRTH_PATH, patched)
			print(`Wrote the starting-currency values into {REBIRTH_PATH}`)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------------------------

--[[
	Number scale every world's run must reach (spec: Nuke Town climbs K -> Qi, the finale in the
	B..Qa+ range; Dino Valley's Bones finale sits around the low billions — a fresh climb, visibly
	separate from Nuke Town's Qi).
]]
local SCALE_CHECKS: { [string]: { finaleMin: number, finaleMax: number, earnedMin: number } } = {
	main = { finaleMin = 1e9, finaleMax = math.huge, earnedMin = 1e12 },
	dino = { finaleMin = 1e8, finaleMax = 1e14, earnedMin = 1e9 },
	-- R70 World 3: Moon Base mirrors Dino's structure pad-for-pad, so the same scale.
	moon = { finaleMin = 1e8, finaleMax = 1e14, earnedMin = 1e9 },
}

--[[
	Simulates one world: run 1 (fresh, no Robux) against its pacing targets and number scale, then
	run 2 after one rebirth (tokens spent greedily in its rebirth shop), which must take at most
	SIM.Run2MaxFraction of run 1. Prints both tables. Errors on any failed assertion.
	@param worldId string
]]
local function runWorld(worldId: string)
	useWorld(worldId)
	local Config, Logic, RebirthConfig = loadModules(nil)
	SYMBOL = if worldId == "main" then "$" else ""
	print(`==== World "{worldId}" ====`)

	-- Run 1: fresh player, no Robux, no rebirths.
	local run1 = simulate(Config, Logic, nil, 0, nil)
	assert(run1.finished, `economy sim ({worldId}): run 1 never reached the finale`)
	printRun("Run 1 (first playthrough, no Robux):", Config, run1, nil)

	local failures = {}
	local tolerance = Config.Pacing.Tolerance
	for _, area in run1.areas do
		local target = Config.Pacing.TargetMinutes[area.area]
		local minutes = area.seconds / 60
		if math.abs(minutes / target - 1) > tolerance then
			table.insert(
				failures,
				string.format(
					"area %d %s: %.1f min vs target %d (+/-%d%%)",
					area.area,
					area.name,
					minutes,
					target,
					tolerance * 100
				)
			)
		end
	end
	assert(#failures == 0, `economy sim ({worldId}) pacing out of tolerance:\n  ` .. table.concat(failures, "\n  "))

	-- R122 / R130 / R137 openings: the first Manager early, no long wait between the checked areas'
	-- pads, and (R137, where set) a new pad every few seconds in the area's first minutes.
	local checks = OPENING_CHECKS[worldId]
	if checks ~= nil then
		for _, limits in checks do
			local opening = measureOpening(run1, limits.area, limits.earlyMinutes)
			print(
				string.format(
					"Opening (area %d): first Manager at %.2f min (limit %.1f), longest pad wait %.0f s before %s (limit %d s)",
					limits.area,
					opening.firstManagerSeconds / 60,
					limits.firstManagerMinutes,
					opening.maxGapSeconds,
					opening.gapPadId or "?",
					limits.maxPadGapSeconds
				)
			)
			if limits.earlyMinutes ~= nil and limits.earlyGapSeconds ~= nil then
				print(
					string.format(
						"  first %.1f min of area %d: longest stretch without a new pad %.0f s, before %s (limit %d s)",
						limits.earlyMinutes,
						limits.area,
						opening.earlyMaxGapSeconds,
						opening.earlyGapPadId or "?",
						limits.earlyGapSeconds
					)
				)
			end
		end
		local broken = openingFailures(run1)
		assert(#broken == 0, `economy sim ({worldId}) opening:\n  ` .. table.concat(broken, "\n  "))
	end

	-- Every price strictly rises along each area's chain (the free first pad aside).
	for _, area in Config.Areas do
		local previous = -1
		for _, pad in area.pads do
			assert(
				pad.cost > previous or (pad.cost == 0 and previous == -1),
				`economy sim ({worldId}): {pad.id} costs {pad.cost}, not above the pad before it`
			)
			previous = pad.cost
		end
	end

	-- Number scale.
	local finaleCost = Config.PadsById[Config.FinalePadId].cost
	local scale = SCALE_CHECKS[worldId] or SCALE_CHECKS.dino
	assert(
		finaleCost >= scale.finaleMin and finaleCost <= scale.finaleMax,
		`finale costs {money(finaleCost)} (want {money(scale.finaleMin)}..{money(scale.finaleMax)})`
	)
	assert(run1.totalEarned >= scale.earnedMin, `lifetime earned only {money(run1.totalEarned)} by the finale`)

	-- Rebirth: tokens for run 1, spent greedily on the shop priority list.
	local tokens = Logic.rebirthReward(run1.state, 0)
	assert(tokens > 0, "rebirth must pay tokens after the finale")
	local shop: { [string]: number } = {}
	local spent = 0
	while true do
		local bestKey, bestCost = nil, math.huge
		for _, key in SIM.ShopPriority do
			local cost = Logic.rebirthShopCost(key, shop[key] or 0)
			if cost < bestCost then
				bestKey, bestCost = key, cost
			end
		end
		if bestKey == nil or bestCost > tokens - spent then
			break
		end
		shop[bestKey] = (shop[bestKey] or 0) + 1
		spent += bestCost
	end
	local shopParts = {}
	for _, key in SIM.ShopPriority do
		table.insert(shopParts, `{key} {shop[key] or 0}`)
	end
	local mods = { rebirths = 1, rebirthShop = shop }
	local run2 = simulate(Config, Logic, mods, Logic.startingCash(shop), nil)
	assert(run2.finished, `economy sim ({worldId}): run 2 never reached the finale`)
	print("")
	printRun(
		string.format(
			"Run 2 (after 1 rebirth: x%.2f (+%d%%/rebirth), %d tokens -> %s, start %s):",
			Logic.rebirthMultiplier(1, shop),
			RebirthConfig.BonusPerRebirth * 100,
			tokens,
			table.concat(shopParts, ", "),
			money(Logic.startingCash(shop))
		),
		Config,
		run2,
		run1
	)
	local fraction = run2.totalSeconds / run1.totalSeconds
	print(
		string.format(
			"Run 2 is %.0f%% faster than run 1 (%s vs %s).",
			(1 - fraction) * 100,
			clock(run2.totalSeconds),
			clock(run1.totalSeconds)
		)
	)
	assert(
		fraction <= SIM.Run2MaxFraction,
		string.format(
			"%s: run 2 only %.0f%% faster (want >= %.0f%%)",
			worldId,
			(1 - fraction) * 100,
			(1 - SIM.Run2MaxFraction) * 100
		)
	)

	print(
		string.format(
			"\neconomy-sim (%s): OK (finale %s, rebirth pays %d tokens)\n",
			worldId,
			money(finaleCost),
			tokens
		)
	)
end

if table.find(process.args, "--tune") then
	useWorld(WORLD_ARG or "main")
	-- --upto <n>: tune only areas 1..n (R122).
	local uptoAt = table.find(process.args, "--upto")
	local upto: number? = nil
	if uptoAt ~= nil then
		upto = tonumber(process.args[uptoAt + 1])
		assert(upto ~= nil and upto >= 1 and upto == math.floor(upto), "--upto needs an area number")
	end
	tune(table.find(process.args, "--write") ~= nil, upto)
	return
end

-- Every world (or just --world <id>): Nuke Town first, then WorldsConfig.Order.
local worlds: { string } = { WORLD_ARG or "main" }
if WORLD_ARG == nil then
	useWorld("main")
	local load = makeLoader(nil)
	worlds = table.clone(load("src/shared/Config/Worlds/WorldsConfig").Order)
end
for _, worldId in worlds do
	runWorld(worldId)
end
