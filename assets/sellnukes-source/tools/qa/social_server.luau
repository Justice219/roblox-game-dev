--!nocheck
--[[
	social_server.luau — SERVER half of the R78 Rush + Friends Studio QA (R-social), run by
	tools/qa/social.py through eval_server_runtime in ONE solo playtest (Studio lock held).
	The driver substitutes COMMAND (whitelisted) and ARGS (numbers only).

		COMMAND  "status"         RushService.status, online / offline modifiers, friend %, referral
		         "clear_rush"     RushService.clear (admin seam)
		         "grant_rookie"   RushService.grant(player, "rookie", ARGS[1] seconds)
		         "grant_comeback" RushService.grant(player, "comeback", ARGS[1]) + the join's
		                          Social comeback announcement (away = ARGS[2] seconds) — exactly
		                          what RushService sends on a real >= 48 h comeback join
		         "fake_friends"   DISPLAY ONLY: a Social friends push (2 friends, +20 %); solo
		                          playtests cannot have a second Roblox friend (owner R72)
		         "no_friends"     DISPLAY ONLY: back to 0 friends
		         "offline"        an OfflineEarnings payload (amount ARGS[1], seconds ARGS[2])
		         "admin"          runs admin commands through AdminService.dispatchAsync
		                          (ARGS[1]: 1 RushStatus, 2 RushToggle off, 3 RushToggle on,
		                          4 FriendBoostPercent 20, 5 FriendBoostPercent 10, 6 FriendStatus,
		                          7 ReferralStatus, 8 RushMinutes rookie 20, 9 RushMinutes rookie 15,
		                          10 NewPlayerMode (a brand-new sandbox profile: the REAL Rookie Rush
		                          grant path), 11 ExitNewPlayerMode)
		         "referral"       end-to-end queue test on the Studio store: enqueue newcomer
		                          ARGS[1] for THIS player, consume (ReferralTest), consume again
	Everything goes through the real service code. Studio DataStores are separate from production
	(SellNukesReferrals_v1_Studio).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local Server = ServerScriptService:WaitForChild("Server")
local AdminService = require(Server.Services.AdminService)
local FriendLogic = require(Server.Social.FriendLogic)
local FriendService = require(Server.Services.FriendService)
local ModifierSources = require(Server.Tycoon.ModifierSources)
local PlayerDataService = require(Server.Services.PlayerDataService)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RushService = require(Server.Services.RushService)
local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)
local Modifiers = require(ReplicatedStorage.Shared.Tycoon.Modifiers)

local player = Players:GetPlayers()[1]
if player == nil then
	return "no player"
end
local caller = { userId = player.UserId, name = player.Name, player = player }

local function status()
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return { loaded = false }
	end
	local online = ModifierSources.build(player, profile)
	local offline = ModifierSources.build(player, profile, true)
	return {
		loaded = true,
		rush = RushService.status(player),
		saved = { rookieLeft = profile.rush.rookieLeft, comebackUntil = profile.rush.comebackUntil },
		now = os.time(),
		online = { rushCash = online.rushCash, friendCash = online.friendCash, cash = Modifiers.resolve(online).cash },
		offline = { rushCash = offline.rushCash, friendCash = offline.friendCash, cash = Modifiers.resolve(offline).cash },
		friendPercent = FriendService.percent(player),
		referral = FriendService.referralStatus(player),
		gems = profile.gems,
		bonusSpins = profile.spin.bonus,
		saving = PlayerDataService.isSavingEnabled(),
		canMutate = PlayerDataService.canMutate(player),
		income = player:GetAttribute("IncomePerSecond"),
	}
end

local function admin(name, args)
	local ok, result = pcall(AdminService.dispatchAsync, caller, name, args)
	if not ok then
		return { ok = false, text = tostring(result) }
	end
	return { ok = result.ok, text = result.text }
end

local out
if COMMAND == "status" then
	out = status()
elseif COMMAND == "clear_rush" then
	out = { cleared = RushService.clear(player), status = status() }
elseif COMMAND == "grant_rookie" then
	out = { granted = RushService.grant(player, "rookie", ARGS[1]), status = status() }
elseif COMMAND == "grant_comeback" then
	local granted = RushService.grant(player, "comeback", ARGS[1])
	Remotes.fireClient("Social", player, {
		kind = "comeback",
		away = ARGS[2],
		seconds = ARGS[1],
		multiplier = SocialConfig.Rush.ComebackMultiplier,
	})
	out = { granted = granted, status = status() }
elseif COMMAND == "fake_friends" then
	Remotes.fireClient("Social", player, { kind = "friends", count = 2, percent = 20, names = { "Bob", "Ann" } })
	out = { sent = true }
elseif COMMAND == "no_friends" then
	Remotes.fireClient("Social", player, { kind = "friends", count = 0, percent = 0, names = {} })
	out = { sent = true }
elseif COMMAND == "offline" then
	Remotes.fireClient("OfflineEarnings", player, { amount = ARGS[1], seconds = ARGS[2], rate = 0.5 })
	out = { sent = true }
elseif COMMAND == "admin" then
	local which = ARGS[1]
	local commands = {
		{ "RushStatus", { userId = player.UserId } },
		{ "RushToggle", { mode = "off" } },
		{ "RushToggle", { mode = "on" } },
		{ "FriendBoostPercent", { percent = 20 } },
		{ "FriendBoostPercent", { percent = 10 } },
		{ "FriendStatus", {} },
		{ "ReferralStatus", { userId = player.UserId } },
		{ "RushMinutes", { kind = "rookie", minutes = 20 } },
		{ "RushMinutes", { kind = "rookie", minutes = 15 } },
		{ "NewPlayerMode", {} },
		{ "ExitNewPlayerMode", {} },
	}
	local entry = commands[which]
	out = { command = entry[1], result = admin(entry[1], entry[2]), status = status() }
elseif COMMAND == "referral" then
	local newcomer = ARGS[1]
	local store = DataStoreService:GetDataStore(SocialConfig.Referral.StoreName .. SocialConfig.Referral.StudioSuffix)
	local key = SocialConfig.Referral.KeyPrefix .. player.UserId
	local maxAge = SocialConfig.Referral.QueueMaxAgeDays * 86400
	local before = status()
	-- Another server's newcomer write (exactly FriendService's transform).
	local wrote, writeError = pcall(function()
		store:UpdateAsync(key, function(old)
			local record = FriendLogic.enqueue(old, newcomer, os.time(), SocialConfig.Referral.MaxQueue, maxAge)
			if record == nil then
				return nil
			end
			return record, FriendLogic.recordUserIds(record, player.UserId)
		end)
	end)
	local queued = store:GetAsync(key)
	local first = admin("ReferralTest", { userId = player.UserId, mode = "consume", otherId = 1 })
	task.wait(6)
	local afterFirst = status()
	local remaining = store:GetAsync(key)
	-- Replay: re-queue the SAME newcomer (a crash before the dequeue) and consume again.
	pcall(function()
		store:UpdateAsync(key, function(old)
			local record = FriendLogic.enqueue(old, newcomer, os.time(), SocialConfig.Referral.MaxQueue, maxAge)
			return record, if record then FriendLogic.recordUserIds(record, player.UserId) else nil
		end)
	end)
	admin("ReferralTest", { userId = player.UserId, mode = "consume", otherId = 1 })
	task.wait(6)
	local afterReplay = status()
	out = {
		wrote = wrote,
		writeError = if wrote then nil else tostring(writeError),
		queued = queued,
		consume = first,
		remaining = remaining,
		before = before.referral,
		afterFirst = afterFirst.referral,
		afterReplay = afterReplay.referral,
		gems = { before = before.gems, afterFirst = afterFirst.gems, afterReplay = afterReplay.gems },
		spins = { before = before.bonusSpins, afterFirst = afterFirst.bonusSpins, afterReplay = afterReplay.bonusSpins },
		finalQueue = store:GetAsync(key),
	}
else
	out = { error = "unknown command" }
end
return HttpService:JSONEncode(out)
