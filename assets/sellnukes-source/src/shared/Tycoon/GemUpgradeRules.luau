--!strict
--[[
	GemUpgradeRules — the pure rules of the owner R86 gem upgrade ("add a button ... to also just buy
	the next upgrade with gems, but it stays at the same price for everything"). No Instances: the
	server handler (Server/Tycoon/TycoonService.onProducerGemUpgrade) and the client billboard
	(Tycoon/ProducerBillboards) share them, and tests/gem-upgrade.luau proves them.

	Rules:
		- one gem purchase = exactly ONE level, for a FLAT price (TycoonConfig.GemUpgradePrice; the
		  admin panel may override it per server within GemUpgrade.MinPrice..MaxPrice);
		- the producer must be built (level >= 1) and below MaxLevel (same as the cash upgrade:
		  it has no reach rule, the billboard can be pressed wherever it is drawn);
		- the button can be switched off per server (admin); then nothing is sold;
		- the player must hold at least the price in gems (the server's atomic spend re-checks it).

	The live price / switch replicate as ReplicatedStorage attributes written by the server only
	(TycoonConfig.GemUpgrade.PriceAttribute / EnabledAttribute); `price` / `enabled` turn an
	untrusted attribute value into a safe one (anything malformed = the config default).

	Connects to: Shared/Config/TycoonConfig (GemUpgradePrice, GemUpgrade), Server/Tycoon/
	{TycoonService, GemUpgradeSettings}, Client/Tycoon/ProducerBillboards, tests/gem-upgrade.luau.

	Example:
		local ok, reason = GemUpgradeRules.check({ enabled = true, level = 12, maxLevel = 1000,
			gems = 40, price = 75 })
		--> false, "gems"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)

export type Reason = "ok" | "off" | "notBuilt" | "max" | "gems"

export type Facts = {
	enabled: boolean, -- the per-server switch
	level: number, -- the producer's current level (0 = not built)
	maxLevel: number, -- the world's MaxLevel
	gems: number?, -- the player's gems (nil = do not check: the server spends atomically)
	price: number, -- the live flat price
}

local GemUpgradeRules = {}

local Gem = TycoonConfig.GemUpgrade

-- True for a finite whole number.
local function isWhole(value: unknown): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and math.abs(value) < math.huge
end

--[[
	A safe live price from an untrusted value (a replicated attribute / admin input): a whole number
	within [MinPrice, MaxPrice], else the config default.
	Example: GemUpgradeRules.price(nil) --> 75; GemUpgradeRules.price(0 / 0) --> 75
]]
function GemUpgradeRules.price(raw: unknown): number
	if isWhole(raw) then
		local value = raw :: number
		if value >= Gem.MinPrice and value <= Gem.MaxPrice then
			return value
		end
	end
	return TycoonConfig.GemUpgradePrice
end

--[[
	The live switch from an untrusted value: off ONLY for an explicit `false` (a missing attribute
	means the server has not published yet: on, the server re-checks every purchase anyway).
]]
function GemUpgradeRules.enabled(raw: unknown): boolean
	return raw ~= false
end

--[[
	Whether one gem level may be bought, and why not.
	@param facts Facts
	@return (ok, reason) — reason "ok" | "off" | "notBuilt" | "max" | "gems"
]]
function GemUpgradeRules.check(facts: Facts): (boolean, Reason)
	if not facts.enabled then
		return false, "off"
	end
	if not isWhole(facts.level) or facts.level < 1 then
		return false, "notBuilt"
	end
	if facts.level >= facts.maxLevel then
		return false, "max"
	end
	local gems = facts.gems
	if gems ~= nil and (gems ~= gems or gems < facts.price) then
		return false, "gems"
	end
	return true, "ok"
end

--[[
	How many levels `gems` buy at `price` (docs / pacing guard).
	Example: GemUpgradeRules.levelsFor(3000, 75) --> 40
]]
function GemUpgradeRules.levelsFor(gems: number, price: number): number
	if gems ~= gems or price ~= price or price <= 0 or gems <= 0 then
		return 0
	end
	return math.floor(gems / price)
end

return table.freeze(GemUpgradeRules)
