--!strict
--[[
	BoostLogic — pure rules for personal timed boosts in profile.boosts (key → expiry unix time).

	Rules:
		extend      adds `seconds` from max(now, current expiry), capped at now + maxStack: time
		            stacks, an expired boost restarts from now, junk input changes nothing
		multipliers the tycoon modifier fields of every ACTIVE boost (BoostConfig field ×
		            multiplier; two boosts on the same field multiply)
		prune       drops expired / unknown entries (keeps the saved map small)

	Example:
		BoostLogic.extend(profile.boosts, "cash2x", 1800, os.time())
		local mods = BoostLogic.multipliers(profile.boosts, os.time()) --> { boostCash = 2 }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoostConfig = require(ReplicatedStorage.Shared.Config.BoostConfig)

local BoostLogic = {}

-- True for a finite number.
local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--[[
	Adds boost time (see the header).
	@return the new expiry (unix seconds), or nil when nothing changed (unknown key / bad input)
]]
function BoostLogic.extend(
	boosts: { [string]: number },
	key: string,
	seconds: number,
	now: number,
	maxStack: number?
): number?
	if BoostConfig.get(key) == nil or not finite(seconds) or seconds <= 0 or not finite(now) then
		return nil
	end
	local current = boosts[key]
	local from = if finite(current) and (current :: number) > now then current :: number else now
	local cap = now + (maxStack or BoostConfig.MaxStackSeconds)
	local expires = math.floor(math.min(from + seconds, cap))
	if expires <= now then
		return nil
	end
	boosts[key] = expires
	return expires
end

--[[ The modifier fields of every active boost at `now` (fields absent when no boost applies). ]]
function BoostLogic.multipliers(boosts: { [string]: number }, now: number): { [string]: number }
	local out: { [string]: number } = {}
	for key, expires in boosts do
		local def = BoostConfig.get(key)
		if def ~= nil and finite(expires) and expires > now then
			out[def.field] = (out[def.field] or 1) * def.multiplier
		end
	end
	return out
end

--[[ The soonest expiry among ACTIVE known boosts (nil when none is active). Cache hint for B5. ]]
function BoostLogic.nextExpiry(boosts: { [string]: number }, now: number): number?
	local soonest: number? = nil
	for key, expires in boosts do
		if BoostConfig.get(key) ~= nil and finite(expires) and expires > now then
			if soonest == nil or expires < soonest then
				soonest = expires
			end
		end
	end
	return soonest
end

--[[ Removes expired or unknown boosts. @return how many were removed ]]
function BoostLogic.prune(boosts: { [string]: number }, now: number): number
	local removed = 0
	for key, expires in table.clone(boosts) do
		if BoostConfig.get(key) == nil or not finite(expires) or expires <= now then
			boosts[key] = nil
			removed += 1
		end
	end
	return removed
end

return table.freeze(BoostLogic)
