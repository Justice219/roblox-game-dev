--!strict
--[[
	RetentionService — Daily Rewards (design spec §7: a 7-day streak, Day 7 the big rainbow reward,
	a missed day restarts the streak).

	ClaimDaily (C→S, no arguments): token bucket → profile loaded + canMutate → DailyLogic.claim on
	the server's UTC day (never the client's) → the card's reward through RewardGrant in the SAME
	non-yielding step → save soon → toast. The Daily Rewards screen renders from profile.daily with
	RetentionConfig.dailyStatus (identical rule), so no result remote is needed.

	Analytics: retention "daily:claim:<1-7>", "daily:reset" (a broken streak restarted).
	Admin seam: resetDaily(player), setStreak(player, streak, lastDay).

	Example: RetentionService.resetDaily(player) -- admin panel "reset daily"
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DailyLogic = require(ServerScriptService.Server.Retention.DailyLogic)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local RewardGrant = require(ServerScriptService.Server.Retention.RewardGrant)
local ProgressEvents = require(ServerScriptService.Server.Progression.ProgressEvents)
local RewardLogic = require(ServerScriptService.Server.Retention.RewardLogic)

local RetentionService = {}

local limiter = RateLimiter.new(RetentionConfig.Limits.Claim.Burst, RetentionConfig.Limits.Claim.PerSecond)

--[[
	Claims today's Daily Reward for `player` (the ClaimDaily handler; callable by tests).
	@return the card index paid, or nil when refused
]]
function RetentionService.claimDaily(player: Player): number?
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not PlayerDataService.canMutate(player) then
		PlayerDataService.notify(player, "Your save is still loading - try again in a moment.", "info")
		return nil
	end
	local index, reset = DailyLogic.claim(profile.daily, RetentionConfig.utcDay(os.time()))
	if index == nil then
		PlayerDataService.notify(player, "Come back tomorrow for your next reward!", "info", "Daily")
		return nil
	end
	local summary = RewardGrant.grant(
		player,
		RetentionConfig.Days[index].reward,
		"daily",
		{ saveSoon = true, extraFields = { "daily" } }
	)
	if reset then
		RewardGrant.track(player, "daily:reset")
	end
	RewardGrant.track(player, `daily:claim:{index}`)
	ProgressEvents.progress(player, "daily") -- R78 Quests / Pass: a daily reward claimed
	if summary ~= nil then
		PlayerDataService.notify(player, `Day {index} claimed! {RewardLogic.describe(summary)}`, "reward", "Daily")
	end
	return index
end

--[[ Admin: clears the player's streak (next claim = Day 1, available now). ]]
function RetentionService.resetDaily(player: Player): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false
	end
	profile.daily.streak = 0
	profile.daily.lastDay = -1
	PlayerDataService.markChanged(player, true, { "daily" })
	return true
end

--[[
	Admin / tests: sets the streak state directly (e.g. streak 6 claimed yesterday → Day 7 opens).
	@param lastDay UTC day number of the last claim (-1 = never)
]]
function RetentionService.setStreak(player: Player, streak: number, lastDay: number): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or streak ~= streak or lastDay ~= lastDay then
		return false
	end
	profile.daily.streak = math.clamp(math.floor(streak), 0, 10_000)
	profile.daily.lastDay = math.max(-1, math.floor(lastDay))
	PlayerDataService.markChanged(player, true, { "daily" })
	return true
end

function RetentionService.Init() end

function RetentionService.Start()
	Remotes.onServerEvent("ClaimDaily", function(player: Player)
		if limiter:Allow(player) then
			RetentionService.claimDaily(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		limiter:Forget(player)
	end)
end

return RetentionService
