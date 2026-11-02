--!strict
--[[
	DefenseTowers — the pure rules of the buyable defence tower SLOTS (owner R80: "there are no
	buttons to like buy AA towers ... for your plot. So people can just nuke you ... And they need
	to be upgradable."). Tunables: AttackConfig.Towers (slots, prices, placement).

	What it decides (shared on purpose: the server decides with it; the client uses the SAME maths
	to price and grey the in-world BUY / UPGRADE billboards and the Defense window cards — display
	only, the server re-checks everything):
		* slot validation (hostile values → nil), level reads from any stored list (dense, whole,
		  0..MaxLevel), the slot's unlock area;
		* prices: BUY = friendlyPrice(pricePad's cost x priceFactor); level L (2..MaxLevel) =
		  friendlyPrice(BUY x AttackConfig.CostMultiplier[L]);
		* `plan`: is DefenseTower(slot, toLevel) allowed right now, and for how much? toLevel must be
		  EXACTLY the stored level + 1, so a repeated / stale intent (double tap, two clients, a lag
		  spike) is refused instead of buying twice — the remote is idempotent per target level;
		* what is active (slots below their unlock area count as no tower; nothing is ever removed).

	Hostile input: every function accepts any value (NaN, inf, strings, tables) and degrades to the
	safe answer (nil slot, level 0, price math.huge, "not allowed").

	Connects to: Shared/Config/{AttackConfig, TycoonConfig}, Server/Services/DefenseService,
	Server/Attack/AttackProfile, Client/Attack/{AttackClient, DefenseWorld}, Screens/Defense,
	tests/attack-defense.luau.

	Example:
		local ok, cost, reason = DefenseTowers.plan(profile.attack.towers, area, 1, 1)
		if ok then print("Middle Tower costs", cost) end
		DefenseTowers.costTo(1, 3) --> the price of Middle Tower level 2 -> 3
]]

local AttackConfig = require(script.Parent.Parent.Config.AttackConfig)
local TycoonConfig = require(script.Parent.Parent.Config.TycoonConfig)

local DefenseTowers = {}

local SLOTS = AttackConfig.Towers.Slots
local MAX_LEVEL = AttackConfig.MaxLevel

-- Why a DefenseTower intent is refused: unknown slot / slot not unlocked at this area / toLevel is
-- not stored + 1 (stale or repeated) / already MaxLevel / no finite price (config bug).
export type Reason = "slot" | "locked" | "level" | "max" | "price"

-- A finite number, else `fallback`.
local function num(value: unknown, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

--[[ Number of defence tower slots per plot. ]]
function DefenseTowers.count(): number
	return #SLOTS
end

--[[
	A whole slot index 1..count() from any value, else nil (the remote's slot validation).
	Example: DefenseTowers.validSlot(2) --> 2 ; validSlot(2.5) --> nil ; validSlot("2") --> nil
]]
function DefenseTowers.validSlot(raw: unknown): number?
	if type(raw) == "number" and raw == raw and raw % 1 == 0 and raw >= 1 and raw <= #SLOTS then
		return raw
	end
	return nil
end

--[[
	A whole target level 1..MaxLevel from any value, else nil (the remote's toLevel validation).
	Example: DefenseTowers.validLevel(5) --> 5 ; validLevel(0) --> nil ; validLevel(math.huge) --> nil
]]
function DefenseTowers.validLevel(raw: unknown): number?
	if type(raw) == "number" and raw == raw and raw % 1 == 0 and raw >= 1 and raw <= MAX_LEVEL then
		return raw
	end
	return nil
end

--[[ The config of slot `index` (nil for an invalid index). ]]
function DefenseTowers.slot(index: unknown): AttackConfig.TowerSlot?
	local i = DefenseTowers.validSlot(index)
	return if i ~= nil then SLOTS[i] else nil
end

--[[
	The stored level of slot `index` in any stored list (profile.attack.towers): whole, clamped to
	0..MaxLevel; junk / missing → 0.
	@param levels any — the stored list (may be nil, a table with holes, hostile values)
	@param index number
	@return number
]]
function DefenseTowers.level(levels: unknown, index: number): number
	if type(levels) ~= "table" or DefenseTowers.validSlot(index) == nil then
		return 0
	end
	return math.clamp(math.floor(num((levels :: any)[index], 0)), 0, MAX_LEVEL)
end

--[[
	A dense, sanitised copy of a stored list with exactly count() entries (never shares the input).
	Example: DefenseTowers.normalize({ 2, "x", 9 }) --> { 2, 0, 5, 0 }
]]
function DefenseTowers.normalize(levels: unknown): { number }
	local out = table.create(#SLOTS, 0)
	for index = 1, #SLOTS do
		out[index] = DefenseTowers.level(levels, index)
	end
	return out
end

--[[
	True when slot `index` is unlocked at `area` (area >= the slot's unlockArea). Owner R85: callers
	pass the player's highest area while they are TARGETABLE and 0 while they are still protected as
	a brand-new player (nobody can nuke them yet, so no pad shows and nothing can be bought).
	Example: DefenseTowers.unlocked(1, 1) --> true ; unlocked(4, 7) --> false (area 8)
]]
function DefenseTowers.unlocked(index: number, area: unknown): boolean
	local slot = DefenseTowers.slot(index)
	if slot == nil then
		return false
	end
	return num(area, 0) >= math.max(slot.unlockArea, 1)
end

--[[
	Owner R85: the area value the slot rules use — the player's highest area while targetable,
	0 while protected (see unlocked).
	@param area any
	@param targetable boolean
	@return number
]]
function DefenseTowers.areaFor(area: unknown, targetable: boolean): number
	return if targetable == true then num(area, 0) else 0
end

--[[
	The level that counts in play for slot `index`: the stored level while the slot is unlocked at
	`area`, else 0 (hidden after a Rebirth until the area reopens; the stored level is kept).
]]
function DefenseTowers.effective(levels: unknown, index: number, area: unknown): number
	if not DefenseTowers.unlocked(index, area) then
		return 0
	end
	return DefenseTowers.level(levels, index)
end

--[[
	The BUY price of slot `index` (level 0 → 1): friendlyPrice(pricePad cost x priceFactor).
	@return number — cash, or math.huge for a bad slot / missing pad (the purchase then refuses)
	Example: DefenseTowers.buyCost(1) --> 0.5 x the a7_silo_pad price
]]
function DefenseTowers.buyCost(index: unknown): number
	local slot = DefenseTowers.slot(index)
	local pad = if slot ~= nil then TycoonConfig.PadsById[slot.pricePad] else nil
	if slot == nil or pad == nil then
		return math.huge
	end
	local raw = num(pad.cost, 0) * num(slot.priceFactor, 0)
	if raw <= 0 then
		return math.huge
	end
	return TycoonConfig.friendlyPrice(raw)
end

--[[
	The price of taking slot `index` from level toLevel - 1 to `toLevel` (toLevel 1 = buying it).
	@return number — cash, or math.huge when that step does not exist (bad slot / level)
	Example: DefenseTowers.costTo(1, 2) --> buyCost(1) x CostMultiplier[2]
]]
function DefenseTowers.costTo(index: unknown, toLevel: unknown): number
	local target = DefenseTowers.validLevel(toLevel)
	local buy = DefenseTowers.buyCost(index)
	if target == nil or buy == math.huge then
		return math.huge
	end
	if target == 1 then
		return buy
	end
	local multiplier = AttackConfig.CostMultiplier[target]
	if multiplier == nil then
		return math.huge
	end
	return TycoonConfig.friendlyPrice(buy * multiplier)
end

--[[
	The next purchase of slot `index` at stored level `current` (buy when 0, else upgrade).
	@return (number, number) — (target level, price); (0, math.huge) when maxed / invalid
]]
function DefenseTowers.nextStep(index: unknown, current: unknown): (number, number)
	local level = math.clamp(math.floor(num(current, 0)), 0, MAX_LEVEL)
	if DefenseTowers.validSlot(index) == nil or level >= MAX_LEVEL then
		return 0, math.huge
	end
	return level + 1, DefenseTowers.costTo(index, level + 1)
end

--[[
	The server's rule for one DefenseTower(slot, toLevel) intent (the caller then spends `cost`
	atomically). Order: slot valid → unlocked at `area` → not maxed → toLevel is stored + 1 →
	finite price.
	@param levels any — profile.attack.towers
	@param area any — the player's highest unlocked area
	@param slot any — client value
	@param toLevel any — client value (the level the player saw on the button)
	@return (boolean, number, Reason?) — allowed?, price (math.huge when refused), reason
	Example: DefenseTowers.plan({ 0, 0, 0, 0 }, 7, 1, 1) --> true, buyCost(1), nil
]]
function DefenseTowers.plan(levels: unknown, area: unknown, slot: unknown, toLevel: unknown): (boolean, number, Reason?)
	local index = DefenseTowers.validSlot(slot)
	if index == nil then
		return false, math.huge, "slot"
	end
	if not DefenseTowers.unlocked(index, area) then
		return false, math.huge, "locked"
	end
	local current = DefenseTowers.level(levels, index)
	if current >= MAX_LEVEL then
		return false, math.huge, "max"
	end
	local target = DefenseTowers.validLevel(toLevel)
	if target == nil or target ~= current + 1 then
		return false, math.huge, "level"
	end
	local cost = DefenseTowers.costTo(index, target)
	if cost == math.huge then
		return false, math.huge, "price"
	end
	return true, cost, nil
end

--[[
	Number of built + unlocked defence slots (the HQ Feature tower is counted by the caller).
	Example: DefenseTowers.activeCount({ 2, 0, 1, 3 }, 7) --> 2 (slot 4 unlocks at area 9)
]]
function DefenseTowers.activeCount(levels: unknown, area: unknown): number
	local count = 0
	for index = 1, #SLOTS do
		if DefenseTowers.effective(levels, index, area) >= 1 then
			count += 1
		end
	end
	return count
end

--[[
	The cheapest unlocked, NOT yet bought slot (the HUD's "defend yourself" nudge), or nil.
	@return (number?, number) — slot index, its buy price (math.huge when none)
]]
function DefenseTowers.cheapestOpen(levels: unknown, area: unknown): (number?, number)
	local best: number? = nil
	local bestCost = math.huge
	for index = 1, #SLOTS do
		if DefenseTowers.unlocked(index, area) and DefenseTowers.level(levels, index) == 0 then
			local cost = DefenseTowers.buyCost(index)
			if cost < bestCost then
				best, bestCost = index, cost
			end
		end
	end
	return best, bestCost
end

return table.freeze(DefenseTowers)
