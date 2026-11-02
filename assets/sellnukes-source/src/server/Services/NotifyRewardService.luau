--!strict
--[[
	NotifyRewardService — the "Get notified! TURN ON" reward (design spec §7).

	Roblox's opt-in dialog (ExperienceNotificationService:PromptOptIn) is CLIENT-only and never
	tells the game whether the player accepted (OptInPromptClosed carries no answer; RoBeasts hit
	the same wall). The server therefore cannot verify an opt-in. The reward is small and paid ONCE
	per player (profile.notify.claimed), so the honest client report is accepted under these rules:
		ClaimNotifyReward("shown")     the client opened Roblox's dialog → arms a window
		ClaimNotifyReward("accepted")  pays once, only within RetentionConfig.Notify.ArmWindowSeconds
		                               of a "shown" from THIS server session
		ClaimNotifyReward("declined")  counted, disarms
		ClaimNotifyReward("card", moment)
		                               owner R122 §2.3: the opt-in card opened at `moment`
		                               ("manager" = right after the first manager hire, "area2",
		                               "other" = returning-player fallback / Settings); counted
		                               once per moment per player session, never pays anything
		(any other / missing argument is ignored)
	Token bucket per player; profile + canMutate; save soon.

	Analytics: retention "notify:<shown|accepted|declined|claim>" and
	"rnotify:promptAt:<manager|area2|other>" (NotifyConfig.PromptMoments).
	Admin seam: resetClaim(player).

	Example (client): Remotes.event("ClaimNotifyReward"):FireServer("card", "manager")
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local NotifyConfig = require(ReplicatedStorage.Shared.Config.NotifyConfig)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local RewardGrant = require(ServerScriptService.Server.Retention.RewardGrant)
local RewardLogic = require(ServerScriptService.Server.Retention.RewardLogic)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)

local NotifyRewardService = {}

local limiter = RateLimiter.new(RetentionConfig.Limits.Notify.Burst, RetentionConfig.Limits.Notify.PerSecond)
-- os.clock() of each player's last "shown" report (the arm).
local armedAt: { [Player]: number } = {}

local STATUSES = { "shown", "accepted", "declined" }
-- Opt-in card moments already counted this session, per player ("rnotify:promptAt:<moment>").
local cardMoments: { [Player]: { [string]: boolean } } = {}

--[[
	Counts the opt-in card opening at `rawMoment` (once per moment per player session). Analytics
	only: nothing is paid, nothing is armed.
	@return true when counted
]]
local function reportCard(player: Player, rawMoment: unknown): boolean
	local moment = Validate.oneOf(rawMoment, NotifyConfig.PromptMoments)
	if moment == nil then
		return false
	end
	local seen = cardMoments[player]
	if seen == nil then
		seen = {}
		cardMoments[player] = seen
	end
	if seen[moment] then
		return false
	end
	seen[moment] = true
	RewardGrant.track(player, `rnotify:promptAt:{moment}`)
	return true
end

--[[
	Handles one report (the remote handler without its rate limit; tests call it).
	@param rawStatus unknown — "shown" | "accepted" | "declined" | "card"
	@param rawMoment unknown — only for "card": a NotifyConfig.PromptMoments value
	@return true when the reward was paid
]]
function NotifyRewardService.report(player: Player, rawStatus: unknown, rawMoment: unknown?): boolean
	if rawStatus == "card" then
		reportCard(player, rawMoment)
		return false
	end
	local status = Validate.oneOf(rawStatus, STATUSES)
	if status == nil then
		return false
	end
	RewardGrant.track(player, `notify:{status}`)
	if status == "shown" then
		armedAt[player] = os.clock()
		return false
	elseif status == "declined" then
		armedAt[player] = nil
		return false
	end
	local armed = armedAt[player]
	armedAt[player] = nil
	if armed == nil or os.clock() - armed > RetentionConfig.Notify.ArmWindowSeconds then
		return false
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not PlayerDataService.canMutate(player) or profile.notify.claimed then
		return false
	end
	profile.notify.claimed = true
	local summary = RewardGrant.grant(
		player,
		RetentionConfig.Notify.Reward,
		"notify",
		{ saveSoon = true, extraFields = { "notify" } }
	)
	RewardGrant.track(player, "notify:claim")
	if summary ~= nil then
		PlayerDataService.notify(player, `Notifications on! {RewardLogic.describe(summary)}`, "reward", "Star")
	end
	return true
end

--[[
	Admin: clears the claim flag (the reward can be earned again; ResetClaims command).
	@return true when the player had a profile
]]
function NotifyRewardService.resetClaim(player: Player): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false
	end
	profile.notify.claimed = false
	PlayerDataService.markChanged(player, true, { "notify" })
	return true
end

--[[ Service contract: nothing to wire before Start. ]]
function NotifyRewardService.Init() end

--[[ Service contract: the ClaimNotifyReward remote (rate-limited) + per-player cleanup. ]]
function NotifyRewardService.Start()
	Remotes.onServerEvent("ClaimNotifyReward", function(player: Player, rawStatus: unknown, rawMoment: unknown)
		if limiter:Allow(player) then
			NotifyRewardService.report(player, rawStatus, rawMoment)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		limiter:Forget(player)
		armedAt[player] = nil
		cardMoments[player] = nil
	end)
end

return NotifyRewardService
