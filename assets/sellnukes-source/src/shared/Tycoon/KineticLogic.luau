--!strict
--[[
	KineticLogic — the pure maths + save state of owner R90's Mega Lever and Tip Jar (spec
	docs/superpowers/specs/2026-10-31-r90-hands-on-design.md §2 / §3; system doc docs/kinetic.md).
	No services, no yields, no instances: the server (Server/Kinetic/*), the client
	(Client/Kinetic/*), ProfileLogic (profile.kinetic) and the Lune tests (tests/kinetic-logic.luau,
	tests/economy-sim.luau) all run it.

	Save state (profile.kinetic; owned here like FlavorLogic owns profile.flavors)
		{ worlds = { [worldId] = { readyAt, jar, tips } } }
			readyAt  unix seconds the world's Mega Lever is ready again (0 = ready)
			jar      passive Tip Jar coins of that world's currency (<= jarCap(income))
			tips     bonus coins in the jar (TipJar.addCoins; <= BonusCapIncomeSeconds x income;
			         the R90 Order Window's big tips until owner R128 removed it)
		Keys are world ids (^[a-z][a-z0-9]*$, <= 16 chars, at most MaxWorlds entries); numbers are
		finite, >= 0 and clamped, so a corrupted save can never mint money.

	Mega Lever maths (leverPlan)
		Each built producer i completes ONE bonus cycle worth `multiplier` cycles: raw_i =
		perCycle_i x multiplier. The batch is clamped to [minSeconds, maxSeconds] x rate, where
		rate = Σ perCycle_i / cycle_i (the plot's production rate), by ONE common scale, so every
		producer keeps its share. Flavours are rolled per bonus cycle by FlavorService on the server.
	Tip Jar maths
		jarCap(income)     = FillFraction x 60 x CapMinutes x income
		jarFill(...)       grows by FillFraction x income x dt up to the cap; NEVER shrinks (a
		                   lower income after a boost ends never takes coins away)
		addTips(...)       the bonus bucket, capped at BonusCapIncomeSeconds x income
		collectable(...)   pays jar + tips when jar >= MinCollectFraction x cap or tips > 0,
		                   clamped to HardCapIncomeSeconds x income

	Example:
		local plan = KineticLogic.leverPlan({ { id = "p1", perCycle = 100, cycle = 2 } }, 10, 12, 24)
		print(plan.total) --> 1000 (10 cycles = 20 s of the 50/s rate: inside [12, 24] s)
		print(KineticLogic.jarCap(1000)) --> 24000
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)

local JAR = KineticConfig.TipJar
local LEVER = KineticConfig.Lever

export type WorldEntry = { readyAt: number, jar: number, tips: number }
export type State = { worlds: { [string]: WorldEntry } }
export type Cycle = { id: string, perCycle: number, cycle: number }
export type LeverPlan = {
	total: number, -- currency of the whole Mega Pull payout before flavours
	scale: number, -- the common clamp factor applied to every raw bonus
	rate: number, -- Σ perCycle / cycle (currency per second)
	bonuses: { number }, -- per input cycle (same order), already scaled
}
export type WireCycle = { id: string, amount: number, flavor: string }
export type Wire =
	{
		kind: "pull",
		world: string,
		total: number,
		currency: string,
		readyAt: number,
		cycles: { WireCycle },
	}
	| { kind: "collect", world: string, amount: number, currency: string }
	| { kind: "tip", world: string, amount: number, currency: string }

local KineticLogic = {}

-- At most this many world entries are kept in a save (there are 3 worlds today).
KineticLogic.MaxWorlds = 8
-- World keys: the ProfileLogic world-key rule, "main" included.
KineticLogic.MaxWorldKeyLength = 16
-- Any stored / wired amount above this is junk (doubles hold far more; the economy never gets close).
KineticLogic.MaxAmount = 1e300
-- A readyAt more than this far in the future is junk (a corrupted clock); it is clamped.
KineticLogic.MaxCooldownAhead = 7 * 24 * 3600

-- True for a finite number (not NaN / ±inf).
local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
KineticLogic.isFinite = isFinite

-- A finite amount clamped to [0, MaxAmount] (junk → 0).
local function amount(value: unknown): number
	if not isFinite(value) then
		return 0
	end
	return math.clamp(value :: number, 0, KineticLogic.MaxAmount)
end

--[[
	True for a valid world key ("main", "dino", "moon", or any future ^[a-z][a-z0-9]*$ id).
	Example: KineticLogic.isWorldKey("dino") --> true; KineticLogic.isWorldKey("Dino!") --> false
]]
function KineticLogic.isWorldKey(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= KineticLogic.MaxWorldKeyLength
		and string.find(value, "^[a-z][a-z0-9]*$") ~= nil
end

--------------------------------------------------------------------------------------------------
-- Save state
--------------------------------------------------------------------------------------------------

--[[ A fresh profile.kinetic: no world touched yet. ]]
function KineticLogic.newState(): State
	return { worlds = {} }
end

--[[ A fresh world entry: lever ready, empty jar. ]]
function KineticLogic.newEntry(): WorldEntry
	return { readyAt = 0, jar = 0, tips = 0 }
end

--[[
	Repairs a stored profile.kinetic (missing in every pre-R90 save → fresh). Keeps at most MaxWorlds
	valid world keys; every number finite and clamped; readyAt whole seconds >= 0.
	@param raw unknown — the stored value
	@return State — always a fresh table (never the input)
	Example: KineticLogic.reconcileState({ worlds = { main = { readyAt = 5, jar = -3 } } })
		--> { worlds = { main = { readyAt = 5, jar = 0, tips = 0 } } }
]]
function KineticLogic.reconcileState(raw: unknown): State
	local state = KineticLogic.newState()
	if type(raw) ~= "table" then
		return state
	end
	local worlds = (raw :: { [any]: any }).worlds
	if type(worlds) ~= "table" then
		return state
	end
	local kept = 0
	for key, value in worlds :: { [any]: any } do
		if kept >= KineticLogic.MaxWorlds then
			break
		end
		if KineticLogic.isWorldKey(key) and type(value) == "table" then
			local source = value :: { [any]: any }
			local readyAt = if isFinite(source.readyAt) then math.max(0, math.floor(source.readyAt)) else 0
			state.worlds[key :: string] = {
				readyAt = readyAt,
				jar = amount(source.jar),
				tips = amount(source.tips),
			}
			kept += 1
		end
	end
	return state
end

--[[
	The (created on demand) entry of one world, or nil for a bad key / a full state.
	@param state State — profile.kinetic (mutated: a missing entry is added)
	@param worldId string
	@return WorldEntry?
	Example: KineticLogic.entry(profile.kinetic, "main").readyAt
]]
function KineticLogic.entry(state: State, worldId: string): WorldEntry?
	if type(state) ~= "table" or type(state.worlds) ~= "table" or not KineticLogic.isWorldKey(worldId) then
		return nil
	end
	local existing = state.worlds[worldId]
	if existing ~= nil then
		return existing
	end
	local count = 0
	for _ in state.worlds do
		count += 1
	end
	if count >= KineticLogic.MaxWorlds then
		return nil
	end
	local made = KineticLogic.newEntry()
	state.worlds[worldId] = made
	return made
end

--[[ The entry of one world without creating it (nil when absent / bad input). ]]
function KineticLogic.peek(state: State, worldId: string): WorldEntry?
	if type(state) ~= "table" or type(state.worlds) ~= "table" then
		return nil
	end
	return state.worlds[worldId]
end

--------------------------------------------------------------------------------------------------
-- Mega Lever
--------------------------------------------------------------------------------------------------

--[[
	Seconds until the lever is ready (0 = ready now). A readyAt implausibly far ahead counts as
	MaxCooldownAhead at most (a corrupted save never locks a lever for years).
	Example: KineticLogic.cooldownLeft(1000, 940) --> 60
]]
function KineticLogic.cooldownLeft(readyAt: number, now: number): number
	if not isFinite(readyAt) or not isFinite(now) then
		return 0
	end
	return math.clamp(readyAt - now, 0, KineticLogic.MaxCooldownAhead)
end

--[[ True when the lever can be pulled at `now`. ]]
function KineticLogic.isReady(readyAt: number, now: number): boolean
	return KineticLogic.cooldownLeft(readyAt, now) <= 0
end

--[[
	The readyAt a pull at `now` sets (whole seconds, rounded up so a pull never comes back early).
	Example: KineticLogic.nextReadyAt(1000.2) --> 1601
]]
function KineticLogic.nextReadyAt(now: number, cooldown: number?): number
	return math.ceil(now + (cooldown or LEVER.CooldownSeconds))
end

--[[
	The Mega Pull payout of one pull: every input cycle pays perCycle x multiplier, the whole payout
	clamped to [minSeconds, maxSeconds] x rate by one common scale. Junk cycles (non-finite,
	<= 0) are skipped and pay 0 (their bonus slot is 0).
	@param cycles { Cycle } — one per built, running producer of the world
	@param multiplier number? — default Lever.CycleMultiplier
	@param minSeconds number? — default Lever.MinIncomeSeconds
	@param maxSeconds number? — default Lever.MaxIncomeSeconds
	@return LeverPlan — total 0 when nothing can pay
	Example: leverPlan({ { id = "a", perCycle = 1, cycle = 0.1 } }) --> total = 12 x 10/s = 120
	         (raw 10 x 1 = 10 is below the 12 s floor of the 10/s rate, so it is scaled up x12)
]]
function KineticLogic.leverPlan(
	cycles: { Cycle },
	multiplier: number?,
	minSeconds: number?,
	maxSeconds: number?
): LeverPlan
	local mult = multiplier or LEVER.CycleMultiplier
	local low = minSeconds or LEVER.MinIncomeSeconds
	local high = maxSeconds or LEVER.MaxIncomeSeconds
	local bonuses: { number } = table.create(#cycles, 0)
	local raw, rate = 0, 0
	for index, cycle in cycles do
		local perCycle, seconds = cycle.perCycle, cycle.cycle
		if isFinite(perCycle) and perCycle > 0 and isFinite(seconds) and seconds > 0 then
			bonuses[index] = perCycle * mult
			raw += perCycle * mult
			rate += perCycle / seconds
		end
	end
	if raw <= 0 or rate <= 0 or not isFinite(raw) or not isFinite(rate) then
		return { total = 0, scale = 0, rate = 0, bonuses = table.create(#cycles, 0) }
	end
	local total = math.clamp(raw, rate * low, rate * high)
	local scale = total / raw
	for index, bonus in bonuses do
		bonuses[index] = bonus * scale
	end
	return { total = total, scale = scale, rate = rate, bonuses = bonuses }
end

--[[
	The flavour a FlavorService.batch bonus stands for (the server only gets the bonus back:
	bonus = perCycle x (mult - 1) for one cycle), by the nearest FlavorConfig multiplier.
	@return string — a FlavorConfig flavour id ("plain" when no bonus / bad input)
	Example: KineticLogic.flavorOf(50, 100) --> "sprinkle" (x1.5)
]]
function KineticLogic.flavorOf(bonus: number, perCycle: number): string
	if not isFinite(bonus) or not isFinite(perCycle) or perCycle <= 0 or bonus <= 0 then
		return "plain"
	end
	local ratio = 1 + bonus / perCycle
	local best, bestGap = "plain", math.huge
	for _, def in FlavorConfig.Flavors do
		local gap = math.abs(def.mult - ratio)
		if gap < bestGap then
			best, bestGap = def.id, gap
		end
	end
	return best
end

--------------------------------------------------------------------------------------------------
-- Tip Jar
--------------------------------------------------------------------------------------------------

--[[
	The passive cap of the jar for an income per second (CapMinutes of filling).
	Example: KineticLogic.jarCap(1000) --> 0.02 x 60 x 20 x 1000 = 24000
]]
function KineticLogic.jarCap(income: number): number
	if not isFinite(income) or income <= 0 then
		return 0
	end
	return math.min(JAR.FillFraction * 60 * JAR.CapMinutes * income, KineticLogic.MaxAmount)
end

--[[
	One fill step: + FillFraction x income x dt, up to the cap. Never shrinks the jar (a stored
	value above a lower cap simply stops growing) and never goes negative.
	@param stored number — current passive coins
	@param income number — the world's income per second
	@param dt number — seconds since the last step (clamped to [0, 5]: a hitch never overfills)
	@return number — the new stored value
	Example: KineticLogic.jarFill(0, 1000, 1) --> 20
]]
function KineticLogic.jarFill(stored: number, income: number, dt: number): number
	local current = amount(stored)
	local cap = KineticLogic.jarCap(income)
	if cap <= 0 or not isFinite(dt) or dt <= 0 or current >= cap then
		return current
	end
	local step = JAR.FillFraction * income * math.min(dt, 5)
	return math.min(current + step, cap)
end

--[[
	Adds bonus tip coins to the bonus bucket (capped at BonusCapIncomeSeconds x income; TipJar.addCoins
	— no caller since owner R128 removed the Order Window).
	@return (newTips, accepted) — accepted = 0 for junk / a full bucket / no income
	Example: KineticLogic.addTips(0, 500, 10) --> 500, 500 (cap 1200)
]]
function KineticLogic.addTips(tips: number, add: number, income: number): (number, number)
	local current = amount(tips)
	if not isFinite(add) or add <= 0 or not isFinite(income) or income <= 0 then
		return current, 0
	end
	local cap = math.min(JAR.BonusCapIncomeSeconds * income, KineticLogic.MaxAmount)
	if current >= cap then
		return current, 0
	end
	local accepted = math.min(add, cap - current)
	return current + accepted, accepted
end

--[[
	What walking into the jar pays right now.
	@return (payout, reason) — reason "empty" (below MinCollectFraction of the cap and no tips) or
	        "noIncome" (no production to size the jar from) when payout is 0
	Example: KineticLogic.collectable(24000, 0, 1000) --> 24000, nil
]]
function KineticLogic.collectable(stored: number, tips: number, income: number): (number, string?)
	local jar, bonus = amount(stored), amount(tips)
	if not isFinite(income) or income <= 0 then
		return 0, "noIncome"
	end
	local cap = KineticLogic.jarCap(income)
	if bonus <= 0 and (jar <= 0 or jar < cap * JAR.MinCollectFraction) then
		return 0, "empty"
	end
	local ceiling = math.min(JAR.HardCapIncomeSeconds * income, KineticLogic.MaxAmount)
	local payout = math.min(jar + bonus, ceiling)
	if payout <= 0 then
		return 0, "empty"
	end
	return payout, nil
end

--[[
	The jar's visible fill (0..1) in FillSteps steps: passive coins against the cap, tips on top
	(a tipped jar shows fuller; never above 1).
	Example: KineticLogic.fillRatio(12000, 0, 1000) --> 0.5
]]
function KineticLogic.fillRatio(stored: number, tips: number, income: number): number
	local cap = KineticLogic.jarCap(income)
	if cap <= 0 then
		return if amount(stored) + amount(tips) > 0 then 1 else 0
	end
	local ratio = math.clamp((amount(stored) + amount(tips)) / cap, 0, 1)
	local steps = JAR.FillSteps
	-- Floor to a step, but any coins at all show the first step (the pile never looks empty).
	local stepped = math.floor(ratio * steps + 1e-9) / steps
	if stepped <= 0 and ratio > 0 then
		stepped = 1 / steps
	end
	return stepped
end

--------------------------------------------------------------------------------------------------
-- Pacing, placement, reach
--------------------------------------------------------------------------------------------------

--[[
	The conservative income lift the pacing simulator applies (KineticConfig.Pacing header).
	@param flavorMultiplier number — FlavorLogic.expectedMultiplier at the pacing luck (1 = none)
	@return number — e.g. 0.063 = +6.3 %
]]
function KineticLogic.pacingLift(flavorMultiplier: number): number
	local flavor = if isFinite(flavorMultiplier) and flavorMultiplier >= 1 then flavorMultiplier else 1
	local pacing = KineticConfig.Pacing
	local lever = LEVER.MaxIncomeSeconds / LEVER.CooldownSeconds * pacing.LeverPullShare * flavor
	local jar = JAR.FillFraction * pacing.JarPresenceShare
	return lever + jar
end

--[[
	The SLOT-local CFrame of a prop (KineticConfig.Placement, the same in every world; owner R116:
	inside the plot, in Area `Placement.Area`'s front yard).
	@param which "Lever" | "Jar"
	Example: KineticLogic.slotCFrame("Jar").Position --> (15, 0.5, 9.5)
]]
function KineticLogic.slotCFrame(which: "Lever" | "Jar"): CFrame
	return if which == "Lever" then KineticConfig.Placement.Lever else KineticConfig.Placement.Jar
end

--[[
	World CFrame of a prop's pivot on a plot (its slot-local spot through the Area slot frame).
	@param plotIndex number — 1..8
	@param worldId string? — nil / "main" = Nuke Town
	@param which "Lever" | "Jar"
	Example: KineticLogic.mountCFrame(1, "main", "Lever")
		--> WorldLayout.slotToWorld(1, 1, CFrame.new(-18, 0.5, 12)) (plot-local (-22, 0.5, 34))
]]
function KineticLogic.mountCFrame(plotIndex: number, worldId: string?, which: "Lever" | "Jar"): CFrame
	return WorldLayout.slotToWorld(plotIndex, KineticConfig.Placement.Area, KineticLogic.slotCFrame(which), worldId)
end

--[[
	True when a PLOT-LOCAL point is on or near the plot (footprint + TipJar.NearMargin).
	@param localPoint Vector3 — WorldLayout.plotOrigin(plot, world):PointToObjectSpace(root)
	@param plotLength number — WorldLayout.plotLength(world)
]]
function KineticLogic.nearPlot(localPoint: Vector3, plotLength: number): boolean
	local margin = JAR.NearMargin
	return math.abs(localPoint.X) <= WorldLayout.PlotHalfWidth + margin
		and localPoint.Z >= -margin
		and localPoint.Z <= plotLength + margin
end

--[[
	Server reach rule: horizontal distance <= reach and vertical distance <= vertical.
	Example: KineticLogic.withinReach(Vector3.new(0, 3, 0), Vector3.new(10, 0, 0), 18, 20) --> true
]]
function KineticLogic.withinReach(a: Vector3, b: Vector3, reach: number, vertical: number): boolean
	local dx, dz = a.X - b.X, a.Z - b.Z
	return dx * dx + dz * dz <= reach * reach and math.abs(a.Y - b.Y) <= vertical
end

--[[
	"m:ss" of a cooldown (whole seconds, rounded up; 0 → "0:00").
	Example: KineticLogic.formatCountdown(599.2) --> "10:00"
]]
function KineticLogic.formatCountdown(seconds: number): string
	local whole = if isFinite(seconds) then math.max(0, math.ceil(seconds)) else 0
	return string.format("%d:%02d", whole // 60, whole % 60)
end

--------------------------------------------------------------------------------------------------
-- Wire (S→C "Kinetic", owner only) — the client validates before it draws anything
--------------------------------------------------------------------------------------------------

-- A short identifier ([%w_] <= 32 chars: producer ids, flavour ids, currency keys).
local function shortId(value: unknown): string?
	if type(value) ~= "string" or #value < 1 or #value > 32 or string.find(value, "^[%w_]+$") == nil then
		return nil
	end
	return value
end

-- A finite amount >= 0 (nil for junk).
local function wireAmount(value: unknown): number?
	if not isFinite(value) or (value :: number) < 0 or (value :: number) > KineticLogic.MaxAmount then
		return nil
	end
	return value :: number
end

--[[
	Validates a "Kinetic" payload (defensive: the server built it, but a client never trusts shape).
	@return Wire? — nil for anything malformed
	Example: KineticLogic.decodeWire({ kind = "tip", world = "main", amount = 5, currency = "cash" })
]]
function KineticLogic.decodeWire(raw: unknown): Wire?
	if type(raw) ~= "table" then
		return nil
	end
	-- rawget everywhere: a payload's metatable (never on a real remote, but a client never trusts
	-- shape) can't run code here.
	local source = raw :: { [any]: any }
	local rawWorld = rawget(source, "world")
	local world = if KineticLogic.isWorldKey(rawWorld) then rawWorld :: string else nil
	local currency = shortId(rawget(source, "currency"))
	if world == nil or currency == nil then
		return nil
	end
	local kind = rawget(source, "kind")
	if kind == "pull" then
		local total = wireAmount(rawget(source, "total"))
		local readyAt = wireAmount(rawget(source, "readyAt"))
		local rawCycles = rawget(source, "cycles")
		if total == nil or readyAt == nil or type(rawCycles) ~= "table" then
			return nil
		end
		local cycles: { WireCycle } = {}
		for index = 1, LEVER.MaxWireCycles do
			local entry = rawget(rawCycles :: { [any]: any }, index)
			if type(entry) ~= "table" then
				continue
			end
			local id = shortId(rawget(entry, "id"))
			local paid = wireAmount(rawget(entry, "amount"))
			local flavor = shortId(rawget(entry, "flavor"))
			if id ~= nil and paid ~= nil and flavor ~= nil then
				table.insert(cycles, { id = id, amount = paid, flavor = flavor })
			end
		end
		return {
			kind = "pull",
			world = world,
			total = total,
			currency = currency,
			readyAt = readyAt,
			cycles = cycles,
		}
	elseif kind == "collect" or kind == "tip" then
		local paid = wireAmount(rawget(source, "amount"))
		if paid == nil then
			return nil
		end
		if kind == "collect" then
			return { kind = "collect", world = world, amount = paid, currency = currency }
		end
		return { kind = "tip", world = world, amount = paid, currency = currency }
	end
	return nil
end

return table.freeze(KineticLogic)
