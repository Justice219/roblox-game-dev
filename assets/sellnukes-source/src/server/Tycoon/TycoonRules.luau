--!strict
--[[
	TycoonRules — the pure decisions of the tycoon server, separated from Instances so they are
	unit-tested under Lune (tests/tycoon-server-logic.luau).

	Contents
		upgradeCount       "1" | "10" | "max" → how many levels to buy and their price
		catchUp            how many whole automated cycles completed since `start` (batched payouts)
		preservePhase      a new CycleStart that keeps the bar's progress when the cycle time changes
		cashPackAmount     Cash product grant: incomeSeconds × $/s, at least the floor
		fallbackGrant      what a product receipt pays when its normal target is gone (never nothing)
		reachedAreas       the areas a batch of granted pads opens (admin grants announce them once)
		withinReach        server distance checks (pads, producer clicks)
		mergeModifiers     ModifierSources: combine every source's partial Modifiers + rebirth data
		autoClickerOn      owner R64: is the AutoClicker pass clicking for this player right now
		manualStep         owner R64: one tick of an UN-MANAGED producer's cycle (pay / stop / chain)

	All functions are deterministic and hostile-input safe (NaN / inf / wrong types → the safe
	answer: buy nothing, pay the floor, refuse reach).

	Usage
		local count, cost = TycoonRules.upgradeCount("max", cfg, level, profile.cash)
		local cycles, newStart = TycoonRules.catchUp(start, cycle, now, 1000)
		local paid, running, start = TycoonRules.manualStep(false, 0, 1, now, false, 20) --> 0, false, 0
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SafeMath = require(ReplicatedStorage.Shared.Tycoon.SafeMath)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonTypes = require(ReplicatedStorage.Shared.Tycoon.TycoonTypes)

type Modifiers = TycoonTypes.Modifiers
type ProducerConfig = TycoonTypes.ProducerConfig

local TycoonRules = {}

-- Upgrade modes the ProducerUpgrade remote accepts.
TycoonRules.UpgradeModes = table.freeze({ "1", "10", "max" })

-- Fallback grant for a receipt whose target is gone: this many seconds of idle income, at least
-- FallbackFloor cash (a product is never charged for nothing).
TycoonRules.FallbackSeconds = 600
TycoonRules.FallbackFloor = 1_000

--[[
	How many levels a ProducerUpgrade buys and what they cost. "1" and "10" buy exactly that many
	(fewer only when the level cap is closer); "max" buys as many as the cash allows. Returns 0, 0
	when the request cannot be bought (unbuilt, capped, unaffordable, unknown mode).
	@param mode any — "1" | "10" | "max" (untrusted)
	@param cfg ProducerConfig
	@param level number — current level
	@param cash number — the player's wallet in the producer's world (Cash / Bones)
	@param logic Logic? — R57: the producer's world economy (TycoonLogic.forWorld); nil = Nuke Town
	@return number, number — levels, cost
	Example: TycoonRules.upgradeCount("10", workbench, 5, 1e6) --> 10, 1234
	         TycoonRules.upgradeCount("max", dinoBench, 3, bones, TycoonLogic.forWorld("dino"))
]]
function TycoonRules.upgradeCount(
	mode: any,
	cfg: ProducerConfig,
	level: number,
	cash: number,
	logic: TycoonLogic.Logic?
): (number, number)
	local economy: any = if logic ~= nil then logic else TycoonLogic
	local maxLevel = if logic ~= nil then logic.index.MaxLevel else TycoonConfig.MaxLevel
	local safeLevel = SafeMath.int(level, 0, maxLevel)
	local budget = SafeMath.num(cash, 0)
	if safeLevel < 1 or budget <= 0 then
		return 0, 0
	end
	if mode == "max" then
		return economy.maxAffordable(cfg, safeLevel, budget)
	end
	local wanted = if mode == "1" then 1 elseif mode == "10" then 10 else 0
	local count = math.min(wanted, maxLevel - safeLevel)
	if count <= 0 then
		return 0, 0
	end
	local cost = economy.upgradeCost(cfg, safeLevel, count)
	if cost > budget then
		return 0, 0
	end
	return count, cost
end

--[[
	Whole automated cycles completed between `start` and `now`, capped (a server hitch or a long
	freeze never pays more than `maxCycles` at once), and the new cycle start.
	@param start number — server time the current cycle began
	@param cycle number — seconds per cycle (> 0)
	@param now number — server time
	@param maxCycles number — cap per call
	@return number, number — cycles completed, new start (start + cycles * cycle, or now - phase on cap)
	Example: TycoonRules.catchUp(10, 0.5, 11.2, 100) --> 2, 11
]]
function TycoonRules.catchUp(start: number, cycle: number, now: number, maxCycles: number): (number, number)
	if not SafeMath.isFinite(start) or not SafeMath.isFinite(now) or not SafeMath.isFinite(cycle) or cycle <= 0 then
		return 0, now
	end
	local elapsed = now - start
	if elapsed < cycle then
		return 0, start
	end
	local cycles = math.floor(elapsed / cycle)
	if cycles > maxCycles then
		-- Too far behind (hitch): pay the cap and restart the phase from now.
		return maxCycles, now - (elapsed % cycle)
	end
	return cycles, start + cycles * cycle
end

--[[
	A new cycle start that keeps the bar's fractional progress when the cycle time changes (an
	upgrade or speed pad never throws away a half-finished cycle).
	@param start number — current cycle start
	@param oldCycle number, newCycle number — seconds
	@param now number — server time
	@return number — new start (now when inputs are unusable)
]]
function TycoonRules.preservePhase(start: number, oldCycle: number, newCycle: number, now: number): number
	if
		not SafeMath.isFinite(start)
		or not SafeMath.isFinite(oldCycle)
		or not SafeMath.isFinite(newCycle)
		or oldCycle <= 0
		or newCycle <= 0
	then
		return now
	end
	local progress = math.clamp((now - start) / oldCycle, 0, 1)
	return now - progress * newCycle
end

--[[
	Cash granted by a "Cash" product: `incomeSeconds` of the buyer's idle income, at least `floor`.
	@param incomeSeconds number, floor number — from MonetizationConfig
	@param incomePerSecond number — the buyer's current idle $/s
	@return number — finite, >= floor (>= 0)
	Example: TycoonRules.cashPackAmount(600, 1000, 50) --> 30000
]]
function TycoonRules.cashPackAmount(incomeSeconds: number, floor: number, incomePerSecond: number): number
	local safeFloor = SafeMath.clamp(floor, 0, 1e300, 0)
	local scaled = SafeMath.clamp(incomeSeconds, 0, 1e9, 0) * SafeMath.clamp(incomePerSecond, 0, 1e290, 0)
	if not SafeMath.isFinite(scaled) then
		scaled = 0
	end
	return math.max(safeFloor, scaled)
end

--[[
	What a receipt pays when its normal target is gone (SkipPad with every pad owned, DoubleOffline
	with nothing pending after a rejoin elsewhere): FallbackSeconds of idle income, at least
	FallbackFloor.
	@param incomePerSecond number
	@return number
]]
function TycoonRules.fallbackGrant(incomePerSecond: number): number
	return TycoonRules.cashPackAmount(TycoonRules.FallbackSeconds, TycoonRules.FallbackFloor, incomePerSecond)
end

--[[
	The areas a batch of granted pads opens, in grant (chain) order: every Unlock pad's `unlocks`
	area above `areaBefore`, each area once. TycoonService.grantPads (admin SetArea / UnlockAll, any
	world) fires AreaReached / WorldAreaReached for exactly these, so world unlocks, badges and
	analytics follow an admin jump like natural purchases, and an area the player had already
	reached is never announced twice.
	@param padsById {[string]: PadConfig} — the world's economy index (PadsById)
	@param applied {string} — pad ids newly applied, in the order they were applied
	@param areaBefore number — the tycoon's area before the batch (garbage counts as 1)
	@return {number} — newly reached areas, ascending in apply order
	Example: TycoonRules.reachedAreas(TycoonConfig.PadsById, { "a1_open_stand", "a2_hire_couriers" }, 1)
	         --> { 2, 3 }
]]
function TycoonRules.reachedAreas(padsById: { [string]: any }, applied: { string }, areaBefore: number): { number }
	local reached: { number } = {}
	local seen: { [number]: boolean } = {}
	local floor = if SafeMath.isFinite(areaBefore) then areaBefore else 1
	for _, padId in applied do
		local pad = padsById[padId]
		local area = if pad ~= nil then pad.unlocks else nil
		if type(area) == "number" and area > floor and not seen[area] then
			seen[area] = true
			table.insert(reached, area)
		end
	end
	return reached
end

--[[
	Server reach check: horizontal distance <= `horizontal` and vertical gap <= `vertical`.
	@param a Vector3?, b Vector3? — positions (nil → false)
	@param horizontal number, vertical number — studs
	@return boolean
]]
function TycoonRules.withinReach(a: Vector3?, b: Vector3?, horizontal: number, vertical: number): boolean
	if a == nil or b == nil then
		return false
	end
	local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
	if dx ~= dx or dy ~= dy or dz ~= dz then
		return false
	end
	return dx * dx + dz * dz <= horizontal * horizontal and math.abs(dy) <= vertical
end

--[[
	Merges partial Modifiers from every source into one Modifiers table (Tycoon/ModifierSources):
		petCash                                  summed
		cashPass, vip                            OR
		boostCash, boostSpeed, serverCash, eventCash   multiplied
		rushCash, friendCash                     multiplied (R78 Rush / Friend Boost)
		rebirths, rebirthShop                    always from the profile (sources cannot set them;
		                                         R57: the track of the world being built)
		linkCash                                 R57: the cross-world link, from the caller
	Non-finite / non-positive numbers and wrong types are ignored (Modifiers.resolve sanitises
	again; this keeps one bad source from poisoning the others).
	@param partials {any} — each source's returned table (nil entries skipped)
	@param rebirths number, rebirthShop {[string]: number} — from the profile (that world's track)
	@param linkCash number? — WorldsConfig.linkCash(worldId, rebirthsByWorld); nil / < 1 = none
	@return Modifiers
]]
function TycoonRules.mergeModifiers(
	partials: { any },
	rebirths: number,
	rebirthShop: { [string]: number },
	linkCash: number?
): Modifiers
	local petCash = 0
	local cashPass, vip = false, false
	local products = { boostCash = 1, boostSpeed = 1, serverCash = 1, eventCash = 1, rushCash = 1, friendCash = 1 }
	for _, partial in partials do
		if type(partial) ~= "table" then
			continue
		end
		local pet = partial.petCash
		if SafeMath.isFinite(pet) and pet > 0 then
			petCash += pet
		end
		cashPass = cashPass or partial.cashPass == true
		vip = vip or partial.vip == true
		for key in products do
			local value = partial[key]
			if SafeMath.isFinite(value) and value > 0 then
				products[key] *= value
			end
		end
	end
	return {
		petCash = petCash,
		cashPass = cashPass,
		vip = vip,
		boostCash = products.boostCash,
		boostSpeed = products.boostSpeed,
		serverCash = products.serverCash,
		eventCash = products.eventCash,
		-- R78: Rookie / Comeback Rush and Friend Boost (offline = false providers).
		rushCash = products.rushCash,
		friendCash = products.friendCash,
		rebirths = rebirths,
		rebirthShop = rebirthShop,
		-- R57 cross-world link (WorldsConfig.linkCash, >= 1); nil when the caller has none.
		linkCash = if SafeMath.isFinite(linkCash) and (linkCash :: number) >= 1 then linkCash else nil,
	}
end

--[[
	Owner R64 (2026-10-31): whether the AutoClicker pass is clicking for a player right now. It is
	the ONLY thing besides a producer's own Manager pad that runs an un-managed producer by itself,
	and the pass advertises "Toggle it any time": the player's Settings toggle
	(profile.settings.autoClicker, default ON) turns it off. Pass ownership comes from
	MonetizationService.ownsPass, which already answers false in New Player Mode.
	Why this matters: Roblox gives a game's creator every game pass of the game, so the owner's own
	account (and any tester who bought it) auto-clicked from the first second of a fresh start and
	could not turn it off — the R64 report "the first button is already automatic".
	@param ownsPass any — MonetizationService.ownsPass(player, "AutoClicker") (only `true` counts)
	@param setting any — profile.settings.autoClicker (only an explicit `false` turns it off)
	@return boolean
	Example: TycoonRules.autoClickerOn(true, false) --> false; autoClickerOn(true, nil) --> true
]]
function TycoonRules.autoClickerOn(ownsPass: any, setting: any): boolean
	return ownsPass == true and setting ~= false
end

--[[
	Owner R83 (2026-10-31): how many of this tick's auto-clicked cycles count as "click" quest
	progress. The AutoClicker pass makes manual clicks no-ops, so without this a pass owner could
	never finish "Click your machines N times" or the Clicker trophies. Credit accrues into a small
	bank at `rate` per second (capped at one second's worth, so idle time never banks a burst) and
	is spent only on cycles the pass really started.
	Hostile numbers (NaN / inf / negative) credit nothing and reset the bank to 0.
	@param bank number — fractional credit carried from the last tick (0 at start)
	@param elapsed number — seconds since the last credit tick (clamped to [0, 1])
	@param rate number — QuestConfig.AutoClickCreditPerSecond
	@param cycles number — auto-clicked cycles finished this tick
	@return number, number — whole clicks to credit, the bank after
	Example: TycoonRules.autoClickCredit(0, 0.2, 4, 10)  --> 0, 0.8   (not a whole click yet)
	         TycoonRules.autoClickCredit(0.8, 0.2, 4, 10) --> 1, 0.6
	         TycoonRules.autoClickCredit(0.8, 0.2, 4, 0)  --> 0, 1.6   (bank waits for a cycle)
]]
function TycoonRules.autoClickCredit(bank: number, elapsed: number, rate: number, cycles: number): (number, number)
	if
		not SafeMath.isFinite(bank)
		or not SafeMath.isFinite(elapsed)
		or not SafeMath.isFinite(rate)
		or not SafeMath.isFinite(cycles)
		or rate <= 0
	then
		return 0, 0
	end
	local cap = rate -- one second's worth
	local filled = math.clamp(math.max(bank, 0) + math.clamp(elapsed, 0, 1) * rate, 0, cap)
	local credit = math.min(math.floor(filled), math.max(math.floor(cycles), 0))
	return credit, filled - credit
end

--[[
	One server tick of an UN-MANAGED (manual) producer's cycle (owner R64: it only runs when clicked).
	A running cycle that finished is paid exactly once. Without the auto clicker the producer then
	goes IDLE until the next ProducerClick; with it, the next cycle chains straight on (several per
	tick for short cycles, at most `maxChain`; a far-behind chain after a hitch restarts from now).
	An idle producer is started here ONLY by the auto clicker — never by time, level or a purchase.
	Hostile numbers (NaN / inf / non-positive cycle) pay nothing and never loop past `maxChain`.
	@param running boolean — a cycle is in progress
	@param start number — when it started (server clock)
	@param cycleTime number — seconds per clicked cycle (ProducerStats.cycle)
	@param now number — server clock
	@param autoClicker boolean — TycoonRules.autoClickerOn(...) for the player
	@param maxChain number — most cycles paid in one tick (TycoonService.MaxManualChain)
	@return number, boolean, number — finished cycles to pay, running after the tick, start after
	Example: TycoonRules.manualStep(true, 10, 1, 11.2, false, 20) --> 1, false, 10   (paid, then idle)
	         TycoonRules.manualStep(false, 0, 1, 50, false, 20)   --> 0, false, 0    (idle stays idle)
	         TycoonRules.manualStep(false, 0, 1, 50, true, 20)    --> 0, true, 50    (auto clicker starts)
]]
function TycoonRules.manualStep(
	running: boolean,
	start: number,
	cycleTime: number,
	now: number,
	autoClicker: boolean,
	maxChain: number
): (number, boolean, number)
	if not SafeMath.isFinite(now) then
		return 0, running, start
	end
	local paid = 0
	if SafeMath.isFinite(start) and SafeMath.isFinite(cycleTime) and cycleTime > 0 then
		while running and now >= start + cycleTime and paid < maxChain do
			paid += 1
			if autoClicker then
				start += cycleTime
			else
				running = false
			end
		end
		if paid > 0 and running and now >= start + cycleTime then
			start = now -- far behind (hitch): restart the chain from now
		end
	end
	if not running and autoClicker then
		running, start = true, now
	end
	return paid, running, start
end

return TycoonRules
