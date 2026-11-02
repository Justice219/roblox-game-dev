--!strict
--[[
	CodesService — redeemable codes (design spec §7; table in Shared/Config/CodesConfig).

	RedeemCode (C→S, text): token bucket (a refusal answers "Slow down!") → CodesConfig.normalize
	(trim + upper case; junk → invalid) → configured or runtime code → profile + canMutate →
	CodeLogic.check (used / expired / not started) → CodeLogic.redeem + reward in the SAME
	non-yielding step → save soon → CodeResult { ok, text, codeId? } (the screen shows `text`).

	Analytics: retention "code:ok:<codeId>", "code:fail:<invalid|expired|used|limit>".
	Admin seam: addCode(def) adds a code to THIS server only (not persisted; lost on restart —
	permanent codes belong in CodesConfig), listCodes().

	Example:
		CodesService.redeem(player, "nukes") --> { ok = true, text = "Code redeemed! +$1K, +10 Gems", codeId = "launch" }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CodeLogic = require(ServerScriptService.Server.Retention.CodeLogic)
local CodesConfig = require(ReplicatedStorage.Shared.Config.CodesConfig)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local RewardGrant = require(ServerScriptService.Server.Retention.RewardGrant)
local RewardLogic = require(ServerScriptService.Server.Retention.RewardLogic)

export type CodeResult = { ok: boolean, text: string, codeId: string? }

local CodesService = {}

local limiter = RateLimiter.new(CodesConfig.Limit.Burst, CodesConfig.Limit.PerSecond)
-- Answers to over-the-limit requests are throttled too (security audit 2026-10-30): a spammer gets
-- at most one "Slow down!" reply (and one code:fail:limit count) per 5 s, not one per packet.
local refusalLimiter = RateLimiter.new(1, 0.2)
-- Admin-added codes (this server only), by normalized code text.
local runtimeCodes: { [string]: CodesConfig.Code } = {}

-- The definition for player input: config first, then runtime codes.
local function lookup(text: unknown): CodesConfig.Code?
	local def = CodesConfig.find(text)
	if def ~= nil then
		return def
	end
	local normalized = CodesConfig.normalize(text)
	return if normalized ~= nil then runtimeCodes[normalized] else nil
end

-- Sends (and returns) a CodeResult.
local function answer(player: Player, result: CodeResult): CodeResult
	Remotes.fireClient("CodeResult", player, result)
	return result
end

--[[ Redeems `text` for `player` (the RedeemCode handler without its rate limit; tests call it). ]]
function CodesService.redeem(player: Player, text: unknown): CodeResult
	local def = lookup(text)
	if def == nil then
		RewardGrant.track(player, "code:fail:invalid")
		return answer(player, { ok = false, text = "Invalid code!" })
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not PlayerDataService.canMutate(player) then
		return answer(player, { ok = false, text = "Your save is still loading - try again in a moment." })
	end
	local check = CodeLogic.check(def, profile.codes, os.time())
	if check == "used" then
		RewardGrant.track(player, "code:fail:used")
		return answer(player, { ok = false, text = "You already redeemed this code!", codeId = def.id })
	elseif check == "expired" or check == "notStarted" then
		RewardGrant.track(player, "code:fail:expired")
		local message = if check == "expired" then "This code has expired!" else "This code isn't active yet!"
		return answer(player, { ok = false, text = message, codeId = def.id })
	end
	CodeLogic.redeem(def, profile.codes)
	-- profile.codes is private (not in the snapshot): only the reward's fields are pushed;
	-- saveSoon makes the one-time redeem durable within seconds.
	local summary = RewardGrant.grant(player, def.reward, "code", { saveSoon = true })
	RewardGrant.track(player, `code:ok:{def.id}`)
	local reward = if summary ~= nil then RewardLogic.describe(summary) else ""
	return answer(player, { ok = true, text = `Code redeemed! {reward}`, codeId = def.id })
end

--[[
	Admin: adds a code to this server (not persisted). The id must be new, the code text valid and
	the reward valid. @return true when added
	Example: CodesService.addCode({ id = "stream1", code = "STREAM", reward = { gems = 5 } })
]]
function CodesService.addCode(def: CodesConfig.Code): boolean
	local normalized = CodesConfig.normalize(def.code)
	if normalized == nil or type(def.id) ~= "string" or #def.id < 1 or #def.id > 32 then
		return false
	end
	if string.find(def.id, "^[%w_%-]+$") == nil or not RetentionConfig.isRewardValid(def.reward) then
		return false
	end
	if CodesConfig.find(normalized) ~= nil or runtimeCodes[normalized] ~= nil then
		return false
	end
	for _, existing in CodesConfig.Codes do
		if existing.id == def.id then
			return false
		end
	end
	runtimeCodes[normalized] = table.freeze({
		id = def.id,
		code = normalized,
		reward = def.reward,
		startsAt = def.startsAt,
		expiresAt = def.expiresAt,
	}) :: any
	return true
end

--[[ Admin: every code this server accepts (config + runtime). ]]
function CodesService.listCodes(): { CodesConfig.Code }
	local list = table.clone(CodesConfig.Codes) :: { CodesConfig.Code }
	for _, def in runtimeCodes do
		table.insert(list, def)
	end
	return list
end

function CodesService.Init()
	RewardGrant.registerIds("codeId", function(id: string): boolean
		for _, def in CodesService.listCodes() do
			if def.id == id then
				return true
			end
		end
		return false
	end)
end

function CodesService.Start()
	Remotes.onServerEvent("RedeemCode", function(player: Player, text: unknown)
		if not limiter:Allow(player) then
			if refusalLimiter:Allow(player) then
				RewardGrant.track(player, "code:fail:limit")
				answer(player, { ok = false, text = "Slow down! Try again in a few seconds." })
			end
			return
		end
		CodesService.redeem(player, text)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		limiter:Forget(player)
		refusalLimiter:Forget(player)
	end)
end

return CodesService
