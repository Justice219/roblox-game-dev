--!strict
--[[
	TycoonLogic — the pure formulas of the SellNukes tycoon economy.

	Purpose
		Everything about money that both the server (authoritative) and the client (billboards,
		previews) need: producer output and cycle time, milestones, upgrade costs and bulk-buy,
		idle income, offline earnings, the pad chain, area progress and rebirth rewards.
		No Instances, no services, no clock, no randomness — every function is deterministic and
		safe to call with hostile-ish input (NaN / inf / negative / wrong types never produce
		NaN, inf or negative cash; unknown ids return neutral values).

	Core formulas (all tunables in Shared/Config/TycoonConfig + RebirthConfig; see docs/economy.md)
		milestones m        = floor(level / 25)                  (25 = MilestoneEvery)
		milestone cash      = 2 ^ ceil(m / 2)                    (odd milestones: 25, 75, 125 ...)
		milestone speed     = 2 ^ floor(m / 2)                   (even milestones: 50, 100, 150 ...)
		pad cash            = product(Multiplier pads) * (1 + sum(Build pad values))
		pad speed           = product(Speed pads)
		total speed         = milestone speed * pad speed * mods.speed * (automated ? mods.managerSpeed : 1)
		raw cycle           = baseCycle / total speed
		cycle               = max(raw cycle, CycleFloor (0.1 s))
		floor conversion    = max(1, CycleFloor / raw cycle): speed that does not fit under the floor
		                      becomes cash, so $/s is exactly preserved and, once at the floor, every
		                      further x2 speed milestone is exactly x2 cash
		output per cycle    = baseRevenue * level * milestone cash * floor conversion * pad cash * mods.cash
		click payout        = output computed as not automated (no manager speed)

	Monotonicity (kid-friendly rule, enforced by tests/tycoon-logic.luau): no pad, level or shop
	purchase ever lowers a producer's shown cash per cycle, its speed, or idle $/s. Every factor
	above is non-decreasing in every purchase; the exact (not power-of-two) floor conversion keeps
	the cycle from ever getting LONGER when speed is added, and Power Production multiplies clicked
	and automated cycles alike, so buying a Manager never lowers cash per cycle.
		cost of L -> L+1    = baseCost * costGrowth^(L-1)
		cost of L -> L+n    = baseCost * g^(L-1) * (g^n - 1) / (g - 1)  (geometric series, ceil'd)
		idle $/s            = sum over AUTOMATED producers of output / cycle
		offline             = idle $/s * clamp(elapsed, 0, cap) * clamp(rate, 0, 1)

	State
		`state` is `profile.tycoon` (TycoonTypes.TycoonState): `pads[padId] = true`,
		`producers[producerId] = level` (0 / missing = not built), `area` = highest unlocked area.
		Read-only everywhere except `applyPad` / `applyLevels` / `newState`, which the server
		calls AFTER it has validated the request and spent the cash.

	Worlds (World 2 plan §3.1)
		Every world (Nuke Town "main", Dino Valley "dino", ...) runs the same formulas on its own
		economy. `TycoonLogic.bind(index, rebirthDef)` builds one `Logic` — a table with every
		function below as a closure over that world's EconomyIndex and RebirthDef (built once, so the
		hot paths cost exactly what they did before). `TycoonLogic.forWorld(id)` returns the cached
		Logic of a world (lazily requires WorldsConfig for non-main ids; errors on unknown ids).
		The module-level functions (`TycoonLogic.producerOutput`, ...) ARE `forWorld("main")`'s, so
		every existing caller is unchanged. `offlineLimits` on every Logic reads the PLAYER-level
		Nuke Town shop keys (offlineHours / offlineRate): callers always pass profile.rebirthShop.

	Connections
		* Config: `Shared/Config/TycoonConfig` (areas, pads, producers, tunables), `RebirthConfig`,
		  `Shared/Config/Worlds/WorldsConfig` (every world's economy + rebirth track).
		* `Shared/Tycoon/Modifiers` resolves the global modifiers table.
		* Server (B5): TycoonService tick / ProducerClick / ProducerUpgrade / PadBuy / Offline / Rebirth.
		* Client (B6): billboards (producerStats, upgradeCost, maxAffordable), pads (nextPads,
		  padAvailable), teleport list (areaProgress), Rebirth screen (rebirthReward, shop costs).

	Usage
		local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
		local cfg = TycoonConfig.ProducersById["p1_workbench"]
		local count, cost = TycoonLogic.maxAffordable(cfg, level, profile.cash)
		local perSecond = TycoonLogic.incomePerSecond(profile.tycoon, mods)
		-- Another world: same API on that world's Logic.
		local Dino = TycoonLogic.forWorld("dino")
		local bones = Dino.incomePerSecond(profile.worlds.dino.tycoon, dinoMods)
]]

local Modifiers = require(script.Parent.Modifiers)
local RebirthConfig = require(script.Parent.Parent.Config.RebirthConfig)
local SafeMath = require(script.Parent.SafeMath)
local TycoonConfig = require(script.Parent.Parent.Config.TycoonConfig)
local TycoonTypes = require(script.Parent.TycoonTypes)

type ProducerConfig = TycoonTypes.ProducerConfig
type PadConfig = TycoonTypes.PadConfig
type TycoonState = TycoonTypes.TycoonState
type Modifiers = TycoonTypes.Modifiers
type ResolvedModifiers = TycoonTypes.ResolvedModifiers
type MilestoneBadge = TycoonTypes.MilestoneBadge
type ProducerStats = TycoonTypes.ProducerStats
type EconomyIndex = TycoonTypes.EconomyIndex
type RebirthDef = TycoonTypes.RebirthDef

--[[
	One world's economy API: the world identity plus every TycoonLogic function bound to that
	world's EconomyIndex (`index`) and rebirth track (`rebirth`). Signatures are exactly the
	module-level ones (which are Nuke Town's Logic).
]]
export type Logic = {
	worldId: string,
	index: EconomyIndex,
	rebirth: RebirthDef,
	ownsPad: (state: any, padId: any) -> boolean,
	levelOf: (state: any, producerId: any) -> number,
	isAutomated: (state: any, producerId: any) -> boolean,
	padMultipliers: (state: any, producerId: string) -> (number, number),
	milestoneMultipliers: (level: any) -> (number, number),
	milestoneBadge: (level: any) -> MilestoneBadge,
	producerOutput: (cfg: ProducerConfig, level: any, mods: Modifiers?, state: TycoonState?) -> number,
	cycleTime: (cfg: ProducerConfig, level: any, mods: Modifiers?, state: TycoonState?) -> number,
	clickValue: (cfg: ProducerConfig, level: any, mods: Modifiers?, state: TycoonState?) -> number,
	clickCycleTime: (cfg: ProducerConfig, level: any, mods: Modifiers?, state: TycoonState?) -> number,
	upgradeCost: (cfg: ProducerConfig, level: any, count: any) -> number,
	maxAffordable: (cfg: ProducerConfig, level: any, cash: any) -> (number, number),
	producerStats: (state: TycoonState, producerId: any, mods: Modifiers?) -> ProducerStats?,
	incomePerSecond: (state: TycoonState, mods: Modifiers?) -> number,
	offlineLimits: (shop: any, hasOfflinePass: boolean?) -> (number, number),
	offlineEarnings: (
		state: TycoonState,
		mods: Modifiers?,
		elapsedSeconds: any,
		capSeconds: any,
		rate: any
	) -> (number, number),
	padAvailable: (state: TycoonState, padId: any) -> (boolean, string?),
	nextPads: (state: TycoonState) -> { PadConfig },
	areaProgress: (state: TycoonState, area: any) -> (number, number),
	areaUnlocked: (state: TycoonState, area: any) -> boolean,
	hasFeature: (state: TycoonState, feature: any) -> boolean,
	newState: () -> TycoonState,
	applyPad: (state: TycoonState, padId: any) -> boolean,
	applyLevels: (state: TycoonState, producerId: any, count: any) -> number,
	totalLevels: (state: TycoonState) -> number,
	canRebirth: (state: TycoonState) -> boolean,
	rebirthReward: (state: TycoonState, rebirths: any?) -> number,
	rebirthMultiplier: (rebirths: any, shop: any) -> number,
	rebirthShopCost: (key: any, level: any) -> number,
	rebirthShopEffect: (key: any, level: any) -> number,
	startingCash: (shop: any) -> number,
}

local TycoonLogic = {}

local EMPTY: { [any]: any } = table.freeze({} :: { [any]: any })

-- Relative slack used when rounding geometric sums up, so 4.0000000001 (float noise on an exact
-- price) does not become 5.
local CEIL_SLACK = 1e-12

--[[
	Builds one world's Logic: every economy function as a closure over that world's EconomyIndex
	and RebirthDef. Call once per world (forWorld caches); the closures read their config through
	upvalues, so a bound call costs the same as the old module-level function.
	@param index EconomyIndex — the world's economy (TycoonConfig.Index, WorldsConfig.Worlds[id].economy)
	@param rebirth RebirthDef — the world's rebirth track (RebirthConfig, DinoRebirth)
	@return Logic — frozen
	Example: local Dino = TycoonLogic.bind(def.economy, def.rebirth)
	         Dino.producerOutput(Dino.index.ProducersById.dp1_pebble_bench, 10, nil, nil) --> 10 * baseRevenue
]]
function TycoonLogic.bind(index: EconomyIndex, rebirth: RebirthDef): Logic
	local MAX_LEVEL = index.MaxLevel
	local MILESTONE_EVERY = index.MilestoneEvery
	local MILESTONE_FACTOR = index.MilestoneFactor
	local CYCLE_FLOOR = index.CycleFloor

	-- Filled below; the functions reference each other through this table (exactly like the old
	-- module-level `TycoonLogic.x` calls). Checked against the Logic type at the end of bind.
	local Logic = {
		worldId = index.WorldId,
		index = index,
		rebirth = rebirth,
	}

	--------------------------------------------------------------------------------------------------
	-- State readers (hostile-safe)
	--------------------------------------------------------------------------------------------------

	--[[
		The pad set of a state, or an empty table when the state / its pads are not tables.
		@param state any — a TycoonState (or garbage)
		@return {[any]: any}
	]]
	local function padsOf(state: any): { [any]: any }
		if type(state) == "table" and type(state.pads) == "table" then
			return state.pads
		end
		return EMPTY
	end

	--[[
		True when the state owns pad `padId` (stored as `pads[id] = true`; any other value is not owned).
		@param state any — TycoonState
		@param padId any — pad id
		@return boolean
		Example: TycoonLogic.ownsPad(profile.tycoon, "a1_workbench") --> true after the tutorial
	]]
	function Logic.ownsPad(state: any, padId: any): boolean
		return type(padId) == "string" and padsOf(state)[padId] == true
	end

	--[[
		The sanitised level of a producer in a state: integer in [0, MaxLevel], 0 = not built.
		@param state any — TycoonState
		@param producerId any — producer id
		@return number
		Example: TycoonLogic.levelOf(profile.tycoon, "p1_workbench") --> 37
	]]
	function Logic.levelOf(state: any, producerId: any): number
		if type(state) ~= "table" or type(state.producers) ~= "table" or type(producerId) ~= "string" then
			return 0
		end
		return SafeMath.int(state.producers[producerId], 0, MAX_LEVEL)
	end

	--[[
		True when the producer's Manager pad is owned (the producer runs by itself, idle + offline).
		@param state any — TycoonState
		@param producerId any — producer id
		@return boolean
	]]
	function Logic.isAutomated(state: any, producerId: any): boolean
		if type(producerId) ~= "string" then
			return false
		end
		local managerPad = index.ManagerPadOf[producerId]
		return managerPad ~= nil and padsOf(state)[managerPad] == true
	end

	--[[
		Cash and speed multipliers a producer gets from its owned pads.
		cash = product(Multiplier values) * (1 + sum(Build values)); speed = product(Speed values).
		@param state any — TycoonState (nil / garbage = no pads)
		@param producerId string
		@return number, number — padCash, padSpeed (both >= 1)
		Example: with Glow Lamp (x2) + Tool Wall (+10 %) --> 2.2, 1
	]]
	function Logic.padMultipliers(state: any, producerId: string): (number, number)
		local pads = padsOf(state)
		local targeted = index.PadsByTarget[producerId]
		if targeted == nil or pads == EMPTY then
			return 1, 1
		end
		local cash, buildBonus, speed = 1, 0, 1
		for _, pad in targeted do
			if pads[pad.id] == true then
				local value = pad.value or 0
				if pad.kind == "Multiplier" then
					cash *= value
				elseif pad.kind == "Build" then
					buildBonus += value
				elseif pad.kind == "Speed" then
					speed *= value
				end
			end
		end
		return cash * (1 + buildBonus), speed
	end

	--------------------------------------------------------------------------------------------------
	-- Milestones, output, cycle
	--------------------------------------------------------------------------------------------------

	--[[
		Milestone multipliers at a level. Milestone k (every 25 levels) alternates: odd k doubles cash,
		even k doubles speed. Level 24 -> (1, 1), 25 -> (2, 1), 50 -> (2, 2), 75 -> (4, 2), 100 -> (4, 4).
		@param level any — clamped to [0, MaxLevel]
		@return number, number — milestone cash multiplier, milestone speed multiplier
	]]
	function Logic.milestoneMultipliers(level: any): (number, number)
		local milestones = SafeMath.int(level, 0, MAX_LEVEL) // MILESTONE_EVERY
		local cashMilestones = (milestones + 1) // 2
		local speedMilestones = milestones // 2
		return MILESTONE_FACTOR ^ cashMilestones, MILESTONE_FACTOR ^ speedMilestones
	end

	--[[
		The billboard milestone badge ("x8" next to the level): milestone cash multiplier plus where
		the next milestone is. Pure in the level; the full cash multiplier including pads, the cycle
		floor conversion and modifiers is `producerStats(...).cashMultiplier`.
		@param level any — producer level (clamped)
		@return MilestoneBadge
		Example: TycoonLogic.milestoneBadge(77) --> { milestones = 3, cash = 4, speed = 2, nextAt = 100,
		         nextKind = "Speed", text = "x4" }
	]]
	function Logic.milestoneBadge(level: any): MilestoneBadge
		local safeLevel = SafeMath.int(level, 0, MAX_LEVEL)
		local milestones = safeLevel // MILESTONE_EVERY
		local cash, speed = Logic.milestoneMultipliers(safeLevel)
		local nextAt = (milestones + 1) * MILESTONE_EVERY
		local nextKind: ("Cash" | "Speed")? = if (milestones + 1) % 2 == 1 then "Cash" else "Speed"
		return {
			milestones = milestones,
			cash = cash,
			speed = speed,
			nextAt = if nextAt <= MAX_LEVEL then nextAt else nil,
			nextKind = if nextAt <= MAX_LEVEL then nextKind else nil,
			text = string.format("x%d", cash),
		}
	end

	--[[
		Core evaluation shared by every output / cycle function.
		@param cfg ProducerConfig
		@param level number — sanitised level (>= 1)
		@param resolved ResolvedModifiers
		@param padCash number, padSpeed number — from padMultipliers
		@param automated boolean — manager owned (manager speed applies only then)
		@return number, number, number, number — output per cycle, cycle seconds, cash multiplier
		        (everything except level and baseRevenue), effective speed multiplier (baseCycle / cycle)
	]]
	local function evaluate(
		cfg: ProducerConfig,
		level: number,
		resolved: ResolvedModifiers,
		padCash: number,
		padSpeed: number,
		automated: boolean
	): (number, number, number, number)
		local milestoneCash, milestoneSpeed = Logic.milestoneMultipliers(level)
		local speed = milestoneSpeed * padSpeed * resolved.speed * (if automated then resolved.managerSpeed else 1)
		local cycle = cfg.baseCycle / speed
		local conversion = 1
		if cycle < CYCLE_FLOOR then
			-- Clamp to the floor and pay the speed that did not fit as cash: output / cycle (income per
			-- second) stays exactly what the raw speed would give, and the cycle never lengthens when
			-- speed is added (a power-of-two conversion could turn 0.11 s into 0.18 s).
			conversion = CYCLE_FLOOR / cycle
			cycle = CYCLE_FLOOR
		end
		local cashMultiplier = milestoneCash * conversion * padCash * resolved.cash
		return cfg.baseRevenue * level * cashMultiplier, cycle, cashMultiplier, cfg.baseCycle / cycle
	end

	--[[
		True when `cfg` looks like a producer config (guards every public entry point).
	]]
	local function isProducer(cfg: any): boolean
		return type(cfg) == "table" and type(cfg.baseRevenue) == "number" and type(cfg.baseCycle) == "number"
	end

	--[[
		Cash paid per cycle by a producer at `level` (the "$192,524" on the billboard).
		Linear in level x milestone cash x cycle-floor conversion x pad multipliers x global mods.
		@param cfg ProducerConfig — e.g. index.ProducersById[id]
		@param level any — level to evaluate (pass level + 1 to preview the next upgrade); < 1 -> 0
		@param mods Modifiers? — global modifiers (nil = none)
		@param state TycoonState? — supplies pad multipliers and automation (nil = no pads, manual)
		@return number — >= 0, finite
		Example: TycoonLogic.producerOutput(workbench, 10, nil, nil) --> 10 (baseRevenue 1 x level 10)
	]]
	function Logic.producerOutput(cfg: ProducerConfig, level: any, mods: Modifiers?, state: TycoonState?): number
		local safeLevel = SafeMath.int(level, 0, MAX_LEVEL)
		if safeLevel < 1 or not isProducer(cfg) then
			return 0
		end
		local padCash, padSpeed = Logic.padMultipliers(state, cfg.id)
		local output = evaluate(
			cfg,
			safeLevel,
			Modifiers.resolve(mods, rebirth),
			padCash,
			padSpeed,
			Logic.isAutomated(state, cfg.id)
		)
		return output
	end

	--[[
		Seconds per cycle (the "0.1s" on the progress bar), never below TycoonConfig.CycleFloor.
		@param cfg ProducerConfig
		@param level any — producer level (milestone speed); < 1 evaluates as level 1's cycle
		@param mods Modifiers?
		@param state TycoonState? — pad speed + automation (manager speed)
		@return number — seconds, >= CycleFloor
		Example: TycoonLogic.cycleTime(workbench, 50, nil, nil) --> 0.5 (baseCycle 1, one speed milestone)
	]]
	function Logic.cycleTime(cfg: ProducerConfig, level: any, mods: Modifiers?, state: TycoonState?): number
		if not isProducer(cfg) then
			return CYCLE_FLOOR
		end
		local safeLevel = math.max(1, SafeMath.int(level, 0, MAX_LEVEL))
		local padCash, padSpeed = Logic.padMultipliers(state, cfg.id)
		local _, cycle = evaluate(
			cfg,
			safeLevel,
			Modifiers.resolve(mods, rebirth),
			padCash,
			padSpeed,
			Logic.isAutomated(state, cfg.id)
		)
		return cycle
	end

	--[[
		Cash paid by ONE manually started cycle (the player clicked the producer before its Manager).
		Evaluated as not automated (manager speed never applies to clicks; Power Production applies to
		clicked and automated cycles alike through mods.cash). The server pays this when a clicked
		cycle completes. Buying the Manager can only keep or raise the per-cycle number.
		@param cfg ProducerConfig
		@param level any — producer level (< 1 -> 0)
		@param mods Modifiers?
		@param state TycoonState? — pad multipliers
		@return number — >= 0
		Example: TycoonLogic.clickValue(workbench, 1, { rebirthShop = { clickPower = 4 } }, nil) --> 1.4
	]]
	function Logic.clickValue(cfg: ProducerConfig, level: any, mods: Modifiers?, state: TycoonState?): number
		local safeLevel = SafeMath.int(level, 0, MAX_LEVEL)
		if safeLevel < 1 or not isProducer(cfg) then
			return 0
		end
		local padCash, padSpeed = Logic.padMultipliers(state, cfg.id)
		local output = evaluate(cfg, safeLevel, Modifiers.resolve(mods, rebirth), padCash, padSpeed, false)
		return output
	end

	--[[
		Cycle length of a manually started cycle (no manager speed), >= CycleFloor. The server uses it
		to time clicked cycles; it equals cycleTime() unless the Rebirth shop's manager speed is owned.
		@param cfg ProducerConfig
		@param level any
		@param mods Modifiers?
		@param state TycoonState?
		@return number — seconds
	]]
	function Logic.clickCycleTime(cfg: ProducerConfig, level: any, mods: Modifiers?, state: TycoonState?): number
		if not isProducer(cfg) then
			return CYCLE_FLOOR
		end
		local safeLevel = math.max(1, SafeMath.int(level, 0, MAX_LEVEL))
		local padCash, padSpeed = Logic.padMultipliers(state, cfg.id)
		local _, cycle = evaluate(cfg, safeLevel, Modifiers.resolve(mods, rebirth), padCash, padSpeed, false)
		return cycle
	end

	--------------------------------------------------------------------------------------------------
	-- Upgrade costs
	--------------------------------------------------------------------------------------------------

	--[[
		Price of buying `count` levels starting at `level` (geometric series closed form, rounded up).
		cost(L -> L+n) = baseCost * g^(L-1) * (g^n - 1) / (g - 1)
		@param cfg ProducerConfig
		@param level any — current level; < 1 (not built) -> math.huge (cannot upgrade)
		@param count any — levels to buy (floored, clamped to [0, MaxBulkLevels]); 0 -> 0
		@return number — cash; math.huge when the producer is unbuilt or level + count > MaxLevel
		Example: TycoonLogic.upgradeCost(workbench, 1, 1) --> baseCost (14)
	]]
	function Logic.upgradeCost(cfg: ProducerConfig, level: any, count: any): number
		if not isProducer(cfg) then
			return math.huge
		end
		local safeLevel = SafeMath.int(level, 0, MAX_LEVEL)
		local n = SafeMath.int(count, 0, index.MaxBulkLevels)
		if safeLevel < 1 then
			return math.huge
		end
		if n == 0 then
			return 0
		end
		if safeLevel + n > MAX_LEVEL then
			return math.huge
		end
		local g = cfg.costGrowth
		local first = cfg.baseCost * g ^ (safeLevel - 1)
		local total = if n == 1 then first else first * (g ^ n - 1) / (g - 1)
		return math.ceil(total * (1 - CEIL_SLACK))
	end

	--[[
		How many levels `cash` buys right now (the "max" upgrade mode), and what they cost.
		Uses the inverted geometric series n = floor(log(1 + cash(g-1)/c0) / log g), then nudges n by
		the exact upgradeCost so float rounding can never sell a level the player cannot afford.
		@param cfg ProducerConfig
		@param level any — current level (< 1 -> 0, 0)
		@param cash any — available cash (NaN / inf / negative -> 0, 0)
		@return number, number — levels affordable (<= MaxLevel - level, <= MaxBulkLevels), their cost
		Example: TycoonLogic.maxAffordable(workbench, 1, 100) --> 4, 76 (levels 2..5: 14 + 16.8 + 20.16 + 24.19, rounded up)
	]]
	function Logic.maxAffordable(cfg: ProducerConfig, level: any, cash: any): (number, number)
		if not isProducer(cfg) then
			return 0, 0
		end
		local safeLevel = SafeMath.int(level, 0, MAX_LEVEL)
		local budget = SafeMath.num(cash, 0)
		if safeLevel < 1 or budget <= 0 then
			return 0, 0
		end
		local room = math.min(MAX_LEVEL - safeLevel, index.MaxBulkLevels)
		if room <= 0 then
			return 0, 0
		end
		local g = cfg.costGrowth
		local first = cfg.baseCost * g ^ (safeLevel - 1)
		local estimate = math.log(1 + budget * (g - 1) / first) / math.log(g)
		local n = if SafeMath.isFinite(estimate) then math.clamp(math.floor(estimate), 0, room) else room
		-- Exact correction against the real (rounded) price; drift is at most a step or two.
		while n > 0 and Logic.upgradeCost(cfg, safeLevel, n) > budget do
			n -= 1
		end
		while n < room and Logic.upgradeCost(cfg, safeLevel, n + 1) <= budget do
			n += 1
		end
		if n == 0 then
			return 0, 0
		end
		return n, Logic.upgradeCost(cfg, safeLevel, n)
	end

	--------------------------------------------------------------------------------------------------
	-- Income
	--------------------------------------------------------------------------------------------------

	--[[
		Everything a producer billboard / the server tick needs about one producer, in one call.
		@param state TycoonState
		@param producerId any — producer id (unknown -> nil)
		@param mods Modifiers?
		@return ProducerStats? — nil for unknown ids
		Example: local s = TycoonLogic.producerStats(profile.tycoon, "p2_nuke_stand", mods)
		         billboard:set(s.output, s.cycle, s.badge.text, s.level, s.nextCost)
	]]
	function Logic.producerStats(state: TycoonState, producerId: any, mods: Modifiers?): ProducerStats?
		local cfg = if type(producerId) == "string" then index.ProducersById[producerId] else nil
		if cfg == nil then
			return nil
		end
		local level = Logic.levelOf(state, cfg.id)
		local automated = Logic.isAutomated(state, cfg.id)
		local resolved = Modifiers.resolve(mods, rebirth)
		local padCash, padSpeed = Logic.padMultipliers(state, cfg.id)
		local evalLevel = math.max(level, 1)
		local output, cycle, cashMultiplier, speedMultiplier =
			evaluate(cfg, evalLevel, resolved, padCash, padSpeed, automated)
		local manualOutput = evaluate(cfg, evalLevel, resolved, padCash, padSpeed, false)
		local built = level >= 1
		return {
			id = cfg.id,
			level = level,
			built = built,
			automated = automated,
			output = if built then output else 0,
			clickPayout = if built then manualOutput else 0,
			cycle = cycle,
			perSecond = if built and automated then output / cycle else 0,
			cashMultiplier = cashMultiplier,
			speedMultiplier = speedMultiplier,
			badge = Logic.milestoneBadge(level),
			nextCost = Logic.upgradeCost(cfg, level, 1),
		}
	end

	--[[
		Idle income: cash per second from every AUTOMATED producer (Manager owned, level >= 1).
		Manual producers are excluded — they only earn while the player clicks. Shown as "+$X/s" and
		the basis of offline earnings.
		@param state TycoonState
		@param mods Modifiers?
		@return number — >= 0, finite
		Example: TycoonLogic.incomePerSecond(profile.tycoon, mods) --> 1234.5
	]]
	function Logic.incomePerSecond(state: TycoonState, mods: Modifiers?): number
		local pads = padsOf(state)
		if pads == EMPTY then
			return 0
		end
		local resolved = Modifiers.resolve(mods, rebirth)
		local total = 0
		for _, cfg in index.Producers do
			local managerPad = index.ManagerPadOf[cfg.id]
			if pads[managerPad] == true then
				local level = Logic.levelOf(state, cfg.id)
				if level >= 1 then
					local padCash, padSpeed = Logic.padMultipliers(state, cfg.id)
					local output, cycle = evaluate(cfg, level, resolved, padCash, padSpeed, true)
					total += output / cycle
				end
			end
		end
		return total
	end

	--[[
		Offline cap and rate for a player, from the Rebirth shop and the Offline Max pass.
		cap  = min(MaxCap, BaseCap + offlineHours effect * 3600)   (pass: at least PassCapSeconds)
		rate = min(MaxRate, BaseRate + offlineRate effect)          (pass: at least PassRate)
		@param shop any — profile.rebirthShop
		@param hasOfflinePass boolean? — owns the Offline Max game pass
		@return number, number — cap seconds, rate in [0, 1]
		Example: TycoonLogic.offlineLimits({}, false) --> 10800, 0.5
	]]
	function Logic.offlineLimits(shop: any, hasOfflinePass: boolean?): (number, number)
		local offline = index.Offline
		local capSeconds = offline.BaseCapSeconds
			+ Modifiers.shopEffect("offlineHours", Modifiers.shopLevel(shop, "offlineHours")) * 3600
		local rate = offline.BaseRate + Modifiers.shopEffect("offlineRate", Modifiers.shopLevel(shop, "offlineRate"))
		if hasOfflinePass == true then
			capSeconds = math.max(capSeconds, offline.PassCapSeconds)
			rate = math.max(rate, offline.PassRate)
		end
		return math.min(capSeconds, offline.MaxCapSeconds), math.min(rate, offline.MaxRate)
	end

	--[[
		Offline earnings for an absence (spec §7). The server computes `elapsedSeconds` from ITS OWN
		saved timestamp (never the client's), then pays the result once.
		amount = incomePerSecond(state, mods) * clamp(elapsed, 0, cap) * clamp(rate, 0, MaxRate)
		Absences shorter than Offline.MinSeconds pay nothing (no popup for a quick rejoin).
		@param state TycoonState
		@param mods Modifiers? — modifiers to apply (the server decides which boosts count offline)
		@param elapsedSeconds any — seconds away (negative / NaN -> 0)
		@param capSeconds any — cap from offlineLimits (clamped to [0, Offline.MaxCapSeconds])
		@param rate any — rate from offlineLimits (clamped to [0, Offline.MaxRate])
		@return number, number — cash earned (>= 0), seconds actually credited
		Example: TycoonLogic.offlineEarnings(state, mods, 7200, 10800, 0.5) --> 3600 * $/s, 7200
	]]
	function Logic.offlineEarnings(
		state: TycoonState,
		mods: Modifiers?,
		elapsedSeconds: any,
		capSeconds: any,
		rate: any
	): (number, number)
		local offline = index.Offline
		local elapsed = SafeMath.num(elapsedSeconds, 0)
		if elapsed < offline.MinSeconds then
			return 0, 0
		end
		local cap = SafeMath.clamp(capSeconds, 0, offline.MaxCapSeconds, 0)
		local credited = math.min(elapsed, cap)
		local safeRate = SafeMath.clamp(rate, 0, offline.MaxRate, 0)
		if credited <= 0 or safeRate <= 0 then
			return 0, 0
		end
		return Logic.incomePerSecond(state, mods) * credited * safeRate, credited
	end

	--------------------------------------------------------------------------------------------------
	-- Pads and areas
	--------------------------------------------------------------------------------------------------

	--[[
		Whether a pad can be bought now (ignoring cash): known id, not owned, prerequisite owned.
		@param state TycoonState
		@param padId any — pad id from the client (untrusted)
		@return boolean, string? — ok, and on failure a reason: "unknown" | "owned" | "locked"
		Example: TycoonLogic.padAvailable(TycoonLogic.newState(), "a1_workbench") --> true
	]]
	function Logic.padAvailable(state: TycoonState, padId: any): (boolean, string?)
		local pad = if type(padId) == "string" then index.PadsById[padId] else nil
		if pad == nil then
			return false, "unknown"
		end
		local pads = padsOf(state)
		if pads[pad.id] == true then
			return false, "owned"
		end
		if pad.requires ~= nil and pads[pad.requires] ~= true then
			return false, "locked"
		end
		return true, nil
	end

	--[[
		Every pad that can be bought right now, in buy order (the chain is linear, so normally one).
		Pads appear on the plot as soon as they are returned here (spec §2.3: shown in order).
		@param state TycoonState
		@return {PadConfig}
		Example: TycoonLogic.nextPads(TycoonLogic.newState())[1].id --> "a1_workbench"
	]]
	function Logic.nextPads(state: TycoonState): { PadConfig }
		local result: { PadConfig } = {}
		local pads = padsOf(state)
		for _, pad in index.PadOrder do
			if pads[pad.id] ~= true and (pad.requires == nil or pads[pad.requires] == true) then
				table.insert(result, pad)
			end
		end
		return result
	end

	--[[
		Purchase progress of one area: pads owned / pads total (for the teleport list, which shows the
		PREVIOUS area's progress on a locked area: "7 / 8 purchases").
		@param state TycoonState
		@param area any — area index (1..#Areas); anything else -> 0, 0
		@return number, number — bought, total
		Example: TycoonLogic.areaProgress(profile.tycoon, 1) --> 7, 9
	]]
	function Logic.areaProgress(state: TycoonState, area: any): (number, number)
		local areaIndex = SafeMath.num(area, 0)
		local areaPads = if areaIndex == math.floor(areaIndex) then index.AreaPads[areaIndex] else nil
		if areaPads == nil then
			return 0, 0
		end
		local pads = padsOf(state)
		local bought = 0
		for _, pad in areaPads do
			if pads[pad.id] == true then
				bought += 1
			end
		end
		return bought, #areaPads
	end

	--[[
		Whether an area is open: area 1 always; area N when the previous area's Unlock pad is owned.
		@param state TycoonState
		@param area any — area index
		@return boolean
	]]
	function Logic.areaUnlocked(state: TycoonState, area: any): boolean
		local areaIndex = SafeMath.num(area, 0)
		if areaIndex ~= math.floor(areaIndex) or areaIndex < 1 or areaIndex > #index.Areas then
			return false
		end
		if areaIndex == 1 then
			return true
		end
		local previous = index.AreaPads[areaIndex - 1]
		return padsOf(state)[previous[#previous].id] == true
	end

	--[[
		Whether a feature pad has been bought ("StandRename", "AATower", "AttackConsole", "Rebirth").
		@param state TycoonState
		@param feature any — feature key
		@return boolean
	]]
	function Logic.hasFeature(state: TycoonState, feature: any): boolean
		local padId = if type(feature) == "string" then index.FeaturePadOf[feature] else nil
		return padId ~= nil and padsOf(state)[padId] == true
	end

	--[[
		A fresh tycoon state (new profile / after rebirth). Matches the profile schema's `tycoon` table.
		@return TycoonState
	]]
	function Logic.newState(): TycoonState
		return { pads = {}, producers = {}, area = 1, standName = "", lastSaveAt = 0, tutorialStep = 0 }
	end

	--[[
		Applies a pad purchase to the state (does NOT touch cash — the server validates with
		padAvailable and spends first). Builder pads set their producer to level 1; Unlock pads raise
		`state.area`.
		@param state TycoonState — mutated
		@param padId any
		@return boolean — false when the pad is not available or the state is malformed (nothing changes)
		Example: if TycoonLogic.padAvailable(t, id) and PlayerData.trySpendCash(p, pad.cost) then
		             Logic.applyPad(t, id) end
	]]
	function Logic.applyPad(state: TycoonState, padId: any): boolean
		-- A malformed state (corrupted profile) is never written to.
		if type(state) ~= "table" or type(state.pads) ~= "table" or type(state.producers) ~= "table" then
			return false
		end
		if not Logic.padAvailable(state, padId) then
			return false
		end
		local pad = index.PadsById[padId :: string]
		state.pads[pad.id] = true
		local producerId = index.ProducerBuiltBy[pad.id]
		if producerId ~= nil and Logic.levelOf(state, producerId) < 1 then
			state.producers[producerId] = 1
		end
		if pad.unlocks ~= nil then
			state.area = math.max(SafeMath.int(state.area, 1, #index.Areas), pad.unlocks)
		end
		return true
	end

	--[[
		Adds levels to a built producer (does NOT touch cash — price them with upgradeCost first).
		@param state TycoonState — mutated
		@param producerId any
		@param count any — levels to add (clamped so the level never exceeds MaxLevel)
		@return number — the new level (unchanged when unbuilt / unknown)
	]]
	function Logic.applyLevels(state: TycoonState, producerId: any, count: any): number
		local level = Logic.levelOf(state, producerId)
		if level < 1 or index.ProducersById[producerId] == nil then
			return level
		end
		local newLevel = math.min(MAX_LEVEL, level + SafeMath.int(count, 0, index.MaxBulkLevels))
		state.producers[producerId :: string] = newLevel
		return newLevel
	end

	--------------------------------------------------------------------------------------------------
	-- Rebirth
	--------------------------------------------------------------------------------------------------

	--[[
		Sum of every producer's level (drives the Rebirth Token reward).
		@param state TycoonState
		@return number
	]]
	function Logic.totalLevels(state: TycoonState): number
		local total = 0
		for _, cfg in index.Producers do
			total += Logic.levelOf(state, cfg.id)
		end
		return total
	end

	--[[
		Whether the player may rebirth (owns the finale pad, the Golden Atom Statue).
		@param state TycoonState
		@return boolean
	]]
	function Logic.canRebirth(state: TycoonState): boolean
		return padsOf(state)[index.FinalePadId] == true
	end

	--[[
		Rebirth Tokens paid for rebirthing now (0 when the finale is not owned).
		tokens = floor((Tokens.Base + totalLevels / Tokens.LevelsPerToken) * (1 + GrowthPerRebirth * rebirths))
		@param state TycoonState
		@param rebirths any? — rebirths already done (profile.rebirths; clamped)
		@return number — whole tokens >= 0
		Example: TycoonLogic.rebirthReward(state, 0) --> floor(20 + 330 / 25) = 33 (a typical first run)
	]]
	function Logic.rebirthReward(state: TycoonState, rebirths: any?): number
		if not Logic.canRebirth(state) then
			return 0
		end
		local tokens = rebirth.Tokens
		local done = SafeMath.int(rebirths, 0, rebirth.MaxRebirths)
		local base = tokens.Base + Logic.totalLevels(state) / tokens.LevelsPerToken
		return math.floor(base * (1 + tokens.GrowthPerRebirth * done))
	end

	--[[
		Permanent cash multiplier from rebirths (+50 % each, additive; Rebirth Power adds more).
		Re-exported from Modifiers so callers have one economy API.
		@param rebirths any — rebirth count
		@param shop any — profile.rebirthShop
		@return number — >= 1
		Example: TycoonLogic.rebirthMultiplier(1, nil) --> 1.5
	]]
	function Logic.rebirthMultiplier(rebirths: any, shop: any): number
		return Modifiers.rebirthMultiplier(rebirths, shop, rebirth)
	end

	--[[
		Token price of the next level of a Rebirth shop upgrade: ceil(baseCost * costGrowth^level).
		@param key any — upgrade key (RebirthConfig.Shop)
		@param level any — current level
		@return number — tokens; math.huge for unknown keys or when already at maxLevel
		Example: TycoonLogic.rebirthShopCost("clickPower", 0) --> 3
	]]
	function Logic.rebirthShopCost(key: any, level: any): number
		local upgrade = if type(key) == "string" then rebirth.Shop[key] else nil
		if upgrade == nil then
			return math.huge
		end
		local current = SafeMath.int(level, 0, upgrade.maxLevel)
		if current >= upgrade.maxLevel then
			return math.huge
		end
		return math.ceil(upgrade.baseCost * upgrade.costGrowth ^ current * (1 - CEIL_SLACK))
	end

	--[[
		Effect of a Rebirth shop upgrade at a level (see RebirthConfig header). Delegates to Modifiers.
		@param key any — upgrade key
		@param level any — level
		@return number — e.g. ("petSlots", 2) --> 2 extra slots; ("offlineRate", 4) --> 0.2
	]]
	function Logic.rebirthShopEffect(key: any, level: any): number
		if type(key) ~= "string" then
			return 0
		end
		return Modifiers.shopEffect(key, level, rebirth)
	end

	--[[
		Cash a fresh run starts with (Rebirth shop "Head Start").
		@param shop any — profile.rebirthShop
		@return number — >= 0
		Example: TycoonLogic.startingCash({ startingCash = 1 }) --> 1000
	]]
	function Logic.startingCash(shop: any): number
		return Modifiers.shopEffect("startingCash", Modifiers.shopLevel(shop, "startingCash", rebirth), rebirth)
	end

	-- The type checker verifies here that every function above matches the Logic type exactly.
	local logic: Logic = Logic
	-- Frozen so no caller can swap a formula at runtime (cast: solver V2 would type a frozen table's
	-- fields read-only, which the exported Logic type does not promise).
	table.freeze(Logic :: any)
	return logic
end

--------------------------------------------------------------------------------------------------
-- Worlds: the main Logic (module-level API) and the per-world cache
--------------------------------------------------------------------------------------------------

-- Nuke Town's Logic. Built eagerly at require time; never requires WorldsConfig (no cycle).
local MAIN: Logic = TycoonLogic.bind(TycoonConfig.Index, RebirthConfig)

-- worldId -> its bound Logic (built on first use).
local LOGICS: { [string]: Logic } = { [MAIN.worldId] = MAIN }

--[[
	The cached Logic of a world.
	@param worldId string — a WorldsConfig id ("main", "dino", ...)
	@return Logic — errors on an unknown id (a programming bug: validate player input with
	        WorldsConfig.get / Validate.worldId first)
	Example: TycoonLogic.forWorld("dino").incomePerSecond(profile.worlds.dino.tycoon, mods)
]]
function TycoonLogic.forWorld(worldId: string): Logic
	local cached = LOGICS[worldId]
	if cached ~= nil then
		return cached
	end
	assert(type(worldId) == "string", "TycoonLogic.forWorld: worldId must be a string")
	-- Lazy require: WorldsConfig builds every world's economy; only non-main callers pay for it,
	-- and the main path (every existing caller) never depends on it.
	local WorldsConfig = require(script.Parent.Parent.Config.Worlds.WorldsConfig)
	local def = WorldsConfig.get(worldId)
	if def == nil then
		error(`TycoonLogic.forWorld: unknown world {worldId}`)
	end
	local logic = TycoonLogic.bind(def.economy, def.rebirth)
	LOGICS[worldId] = logic
	return logic
end

-- The module-level API is Nuke Town's Logic (every existing caller is unchanged).
TycoonLogic.worldId = MAIN.worldId
TycoonLogic.index = MAIN.index
TycoonLogic.rebirth = MAIN.rebirth
TycoonLogic.ownsPad = MAIN.ownsPad
TycoonLogic.levelOf = MAIN.levelOf
TycoonLogic.isAutomated = MAIN.isAutomated
TycoonLogic.padMultipliers = MAIN.padMultipliers
TycoonLogic.milestoneMultipliers = MAIN.milestoneMultipliers
TycoonLogic.milestoneBadge = MAIN.milestoneBadge
TycoonLogic.producerOutput = MAIN.producerOutput
TycoonLogic.cycleTime = MAIN.cycleTime
TycoonLogic.clickValue = MAIN.clickValue
TycoonLogic.clickCycleTime = MAIN.clickCycleTime
TycoonLogic.upgradeCost = MAIN.upgradeCost
TycoonLogic.maxAffordable = MAIN.maxAffordable
TycoonLogic.producerStats = MAIN.producerStats
TycoonLogic.incomePerSecond = MAIN.incomePerSecond
TycoonLogic.offlineLimits = MAIN.offlineLimits
TycoonLogic.offlineEarnings = MAIN.offlineEarnings
TycoonLogic.padAvailable = MAIN.padAvailable
TycoonLogic.nextPads = MAIN.nextPads
TycoonLogic.areaProgress = MAIN.areaProgress
TycoonLogic.areaUnlocked = MAIN.areaUnlocked
TycoonLogic.hasFeature = MAIN.hasFeature
TycoonLogic.newState = MAIN.newState
TycoonLogic.applyPad = MAIN.applyPad
TycoonLogic.applyLevels = MAIN.applyLevels
TycoonLogic.totalLevels = MAIN.totalLevels
TycoonLogic.canRebirth = MAIN.canRebirth
TycoonLogic.rebirthReward = MAIN.rebirthReward
TycoonLogic.rebirthMultiplier = MAIN.rebirthMultiplier
TycoonLogic.rebirthShopCost = MAIN.rebirthShopCost
TycoonLogic.rebirthShopEffect = MAIN.rebirthShopEffect
TycoonLogic.startingCash = MAIN.startingCash

return TycoonLogic
