--!strict
--[[
	BoostConfig — timed boosts: personal ones saved in profile.boosts (key → expiry unix time) and
	the per-server "Server 2x Cash" boost.

	Personal boosts (BoostService): rewards and the "2x Cash (30 min)" product add time; time
	STACKS (a second 30 min adds 30 more) up to MaxStackSeconds ahead of now. An active boost
	multiplies the tycoon modifier `field` (TycoonTypes.Modifiers: boostCash / boostSpeed) by its
	multiplier. Expiry is wall-clock time (boosts also run while offline, like most tycoons; the
	offline payout itself ignores timed boosts, see B5's Offline rules).

	Server boost (ServerBoostService): the ServerCash2x product makes EVERYONE in that server earn
	x Server.Multiplier for Server.Seconds per purchase (stacking up to Server.MaxStackSeconds).
	Per server only (spec §11); replicated as ReplicatedStorage attributes
	ServerBoostEndsAt / ServerBoostBy so every client can show the banner.

	Example:
		local def = BoostConfig.Boosts.cash2x
		print(def.name, def.multiplier) --> "2x Cash" 2
]]

export type ModifierField = "boostCash" | "boostSpeed"

export type BoostDef = {
	key: string,
	name: string,
	icon: string, -- IconAssets key
	field: ModifierField,
	multiplier: number,
}

local BoostConfig = {}

local BOOSTS: { [string]: BoostDef } = {
	cash2x = table.freeze({
		key = "cash2x",
		name = "2x Cash",
		icon = "x2Cash",
		field = "boostCash" :: ModifierField,
		multiplier = 2,
	}) :: any,
	speed2x = table.freeze({
		key = "speed2x",
		name = "2x Speed",
		icon = "Clock",
		field = "boostSpeed" :: ModifierField,
		multiplier = 2,
	}) :: any,
}
BoostConfig.Boosts = table.freeze(BOOSTS)

-- Personal boost time can stack at most this far ahead of now.
BoostConfig.MaxStackSeconds = 24 * 3600
-- How often the server prunes expired boosts and refreshes modifiers (seconds).
BoostConfig.PruneEverySeconds = 5

BoostConfig.Server = table.freeze({
	Multiplier = 2,
	MaxStackSeconds = 3 * 3600,
	-- Attribute names on ReplicatedStorage (client banner).
	EndsAtAttribute = "ServerBoostEndsAt",
	ByAttribute = "ServerBoostBy",
})

--[[ The boost definition for a key, or nil. ]]
function BoostConfig.get(key: string): BoostDef?
	return BOOSTS[key]
end

--[[
	Seconds left on boost `key` in `boosts` (profile.boosts) at `now` (0 when inactive).
	Example: BoostConfig.secondsLeft(profile.boosts, "cash2x", now)
]]
function BoostConfig.secondsLeft(boosts: { [string]: number }, key: string, now: number): number
	local expires = boosts[key]
	if type(expires) ~= "number" or expires ~= expires then
		return 0
	end
	return math.max(0, expires - now)
end

return table.freeze(BoostConfig)
