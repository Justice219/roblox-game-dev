--!strict
--[[
	GroupRewardService — "Join our ROBLOX Group" reward (design spec §7; Shared/Config/GroupConfig).

	ClaimGroupReward (C→S): answers GroupRewardResult { ok, text }.
		GroupConfig.GroupId == 0        → "Group coming soon!" (no web call)
		token bucket / one claim in flight per player / profile + canMutate / already claimed
		Player:IsInGroupAsync(GroupId)  re-checked on EVERY claim (pcall; yields)
		after the yield the session is re-checked (still here, still unclaimed), then
		profile.group.claimed = true + the reward in one non-yielding step, save soon.

	Analytics: retention "group:claim", "group:notMember".
	Admin seam: resetClaim(player).

	Example: GroupRewardService.claim(player) --> { ok = false, text = "Group coming soon!" }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GroupConfig = require(ReplicatedStorage.Shared.Config.GroupConfig)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RewardGrant = require(ServerScriptService.Server.Retention.RewardGrant)
local RewardLogic = require(ServerScriptService.Server.Retention.RewardLogic)

export type GroupResult = { ok: boolean, text: string }

local GroupRewardService = {}

local limiter = RateLimiter.new(GroupConfig.Limit.Burst, GroupConfig.Limit.PerSecond)
local inFlight: { [Player]: boolean } = {}

local function answer(player: Player, result: GroupResult): GroupResult
	if player.Parent == Players then
		Remotes.fireClient("GroupRewardResult", player, result)
	end
	return result
end

--[[ Membership check (pcall). @return true / false, or nil when Roblox could not answer ]]
local function isMemberAsync(player: Player): boolean?
	local ok, member = pcall(function(): boolean
		return player:IsInGroupAsync(GroupConfig.GroupId)
	end)
	if not ok then
		return nil
	end
	return member == true
end

--[[ Claims the group reward (the handler without its rate limit). Yields (group check). ]]
function GroupRewardService.claim(player: Player): GroupResult
	if not GroupConfig.isEnabled() then
		return answer(player, { ok = false, text = "Group coming soon!" })
	end
	if inFlight[player] then
		return { ok = false, text = "Checking..." }
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not PlayerDataService.canMutate(player) then
		return answer(player, { ok = false, text = "Your save is still loading - try again in a moment." })
	end
	if profile.group.claimed then
		return answer(player, { ok = false, text = "You already claimed the group reward!" })
	end
	inFlight[player] = true
	local member = isMemberAsync(player)
	inFlight[player] = nil
	if member == nil then
		return answer(player, { ok = false, text = "Couldn't check the group right now. Try again soon!" })
	end
	if not member then
		RewardGrant.track(player, "group:notMember")
		return answer(player, { ok = false, text = "Join the group first, then press CLAIM!" })
	end
	-- Re-check after the yield: same session, still unclaimed.
	local current = PlayerDataService.getProfile(player)
	if current == nil or current ~= profile or current.group.claimed or not PlayerDataService.canMutate(player) then
		return answer(player, { ok = false, text = "You already claimed the group reward!" })
	end
	current.group.claimed = true
	local summary =
		RewardGrant.grant(player, GroupConfig.Reward, "group", { saveSoon = true, extraFields = { "group" } })
	RewardGrant.track(player, "group:claim")
	local text = if summary ~= nil then RewardLogic.describe(summary) else ""
	return answer(player, { ok = true, text = `Thanks for joining! {text}` })
end

--[[ Admin: clears the claim flag (re-test the flow). ]]
function GroupRewardService.resetClaim(player: Player): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false
	end
	profile.group.claimed = false
	PlayerDataService.markChanged(player, true, { "group" })
	return true
end

function GroupRewardService.Init() end

function GroupRewardService.Start()
	Remotes.onServerEvent("ClaimGroupReward", function(player: Player)
		if limiter:Allow(player) then
			GroupRewardService.claim(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		limiter:Forget(player)
		inFlight[player] = nil
	end)
end

return GroupRewardService
