--!strict
--[[
	CodeLogic — the redeem decision for a code (CodesConfig rules) against profile.codes.

	check(def, codes, now) → "ok" | "used" | "expired" | "notStarted"; `redeem` marks the code
	used and is called by CodesService in the same non-yielding step as the reward.

	Example:
		local result = CodeLogic.check(def, profile.codes, os.time())
		if result == "ok" then CodeLogic.redeem(def, profile.codes) end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CodesConfig = require(ReplicatedStorage.Shared.Config.CodesConfig)

export type Result = "ok" | "used" | "expired" | "notStarted"

local CodeLogic = {}

--[[ Whether `def` can be redeemed into `codes` at `now`. ]]
function CodeLogic.check(def: CodesConfig.Code, codes: { [string]: true }, now: number): Result
	if codes[def.id] then
		return "used"
	end
	if def.startsAt ~= nil and now < def.startsAt then
		return "notStarted"
	end
	if def.expiresAt ~= nil and now >= def.expiresAt then
		return "expired"
	end
	return "ok"
end

--[[ Marks `def` used. @return false when it already was ]]
function CodeLogic.redeem(def: CodesConfig.Code, codes: { [string]: true }): boolean
	if codes[def.id] then
		return false
	end
	codes[def.id] = true
	return true
end

return table.freeze(CodeLogic)
