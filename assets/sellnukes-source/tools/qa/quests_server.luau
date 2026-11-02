--!nocheck
--[[
	quests_server.luau — server-VM probe for R78 Quests, run by tools/qa/quests.py through
	eval_server_runtime during ONE solo playtest (Studio profile store "_Studio": live saves are
	never touched; "restore" puts the profile back anyway).

		COMMAND  "prepare"   backs up quests / gems / spin, then sets a demo state through the LIVE
		                     rules: goals 1-3 completed (goal 1 claimed), today's missions re-seeded
		                     with mission 1 finished, life.click = 150 (Clicker I ready); pushes it
		         "progress"  fires ProgressEvents.progress(player, stat ARGS[1] index, ARGS[2]) for a
		                     stat of today's mission 2 (the real bus → QuestService)
		         "claim"     QuestService.claim("starter", 2) twice (paid once: idempotent) + gems delta
		         "claimAll"  claims mission 1 + the clicker trophy through QuestService.claim
		         "reroll"    QuestService.reroll on the first unfinished slot twice (second refused)
		         "garbage"   hostile QuestClaim / QuestReroll arguments (all refused, nothing paid)
		         "status"    QuestService.status + claimable count + the snapshot's quests step
		         "restore"   restores the backed-up quests / gems / spin and pushes
	Every command returns a JSON string.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local server = ServerScriptService:WaitForChild("Server")
local PlayerDataService = require(server.Services.PlayerDataService)
local QuestService = require(server.Services.QuestService)
local QuestLogic = require(server.Quests.QuestLogic)
local ProgressEvents = require(server.Progression.ProgressEvents)
local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)

local player = Players:GetPlayers()[1]
if player == nil then
	return HttpService:JSONEncode({ error = "no player" })
end
local profile = PlayerDataService.getProfile(player)
if profile == nil then
	return HttpService:JSONEncode({ error = "profile not loaded" })
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

local BACKUP = "QuestsQaBackup"

local function status(): { [string]: any }
	local facts = QuestConfig.facts(profile)
	local today = QuestConfig.utcDay(os.time())
	local picks = {}
	for _, pick in profile.quests.daily.picks do
		table.insert(picks, `{pick.stat} {pick.progress}/{pick.target}{if pick.claimed then " claimed" else ""}`)
	end
	return {
		summary = QuestService.status(player),
		claimable = QuestConfig.claimableCount(profile.quests, facts, today),
		step = profile.quests.starter.step,
		claimed = profile.quests.starter.claimed,
		picks = picks,
		chest = profile.quests.daily.chest,
		rerolled = profile.quests.daily.rerolled,
		lifeClick = profile.quests.life.click or 0,
		gems = profile.gems,
		bonusSpins = profile.spin.bonus,
	}
end

if COMMAND == "prepare" then
	if _G[BACKUP] == nil then
		_G[BACKUP] = { quests = deepCopy(profile.quests), gems = profile.gems, spin = deepCopy(profile.spin) }
	end
	local state = profile.quests
	state.starter.step = 3
	for i = 1, QuestConfig.GoalCount do
		state.starter.claimed[i] = i == 1
	end
	local facts = QuestConfig.facts(profile)
	QuestLogic.resetDay(state, QuestConfig.utcDay(os.time()), player.UserId, QuestConfig.tierOf(facts), false)
	local first = state.daily.picks[1]
	if first ~= nil then
		first.progress = first.target
	end
	state.life.click = 150
	PlayerDataService.markChanged(player, false, { "quests" })
	return HttpService:JSONEncode(status())
elseif COMMAND == "progress" then
	local pick = profile.quests.daily.picks[2]
	if pick == nil then
		return HttpService:JSONEncode({ error = "no mission 2" })
	end
	local before = pick.progress
	ProgressEvents.progress(player, pick.stat, math.max(1, math.floor(ARGS[1] or 1)))
	return HttpService:JSONEncode({ stat = pick.stat, before = before, after = pick.progress, target = pick.target })
elseif COMMAND == "claim" then
	local gems = profile.gems
	local first = QuestService.claim(player, "starter", 2)
	local mid = profile.gems
	local second = QuestService.claim(player, "starter", 2)
	return HttpService:JSONEncode({
		first = first,
		second = second,
		paid = mid - gems,
		paidAgain = profile.gems - mid,
		claimed2 = profile.quests.starter.claimed[2],
	})
elseif COMMAND == "claimAll" then
	local gems = profile.gems
	local mission = QuestService.claim(player, "daily", 1)
	local trophy = QuestService.claim(player, "trophy", "clicker")
	return HttpService:JSONEncode({
		mission = mission,
		trophy = trophy,
		gems = profile.gems - gems,
		clicker = profile.quests.trophies.clicker or 0,
	})
elseif COMMAND == "reroll" then
	local slot = nil
	for index, pick in profile.quests.daily.picks do
		if not pick.claimed and pick.progress < pick.target then
			slot = index
			break
		end
	end
	if slot == nil then
		return HttpService:JSONEncode({ error = "no unfinished mission" })
	end
	local before = profile.quests.daily.picks[slot].stat
	local first = QuestService.reroll(player, slot)
	local after = profile.quests.daily.picks[slot].stat
	local second = QuestService.reroll(player, slot)
	return HttpService:JSONEncode({ slot = slot, before = before, after = after, first = first, second = second })
elseif COMMAND == "garbage" then
	local gems = profile.gems
	local refused = 0
	local passed = {}
	local hostile = { nil, 0 / 0, math.huge, -1, 0, 1.5, 13, "", "clicker\0", {}, true, string.rep("x", 999) }
	for _, kind in { "starter", "daily", "chest", "trophy", "nope", 7 } do
		for _, id in hostile do
			if kind == "chest" then
				continue -- the chest ignores ids (it is locked anyway in this state)
			end
			if QuestService.claim(player, kind, id) then
				table.insert(passed, `{tostring(kind)}:{tostring(id)}`)
			else
				refused += 1
			end
		end
	end
	for _, slot in hostile do
		if QuestService.reroll(player, slot) then
			table.insert(passed, `reroll:{tostring(slot)}`)
		else
			refused += 1
		end
	end
	return HttpService:JSONEncode({ refused = refused, passed = passed, gemsDelta = profile.gems - gems })
elseif COMMAND == "status" then
	return HttpService:JSONEncode(status())
elseif COMMAND == "restore" then
	local backup = _G[BACKUP]
	if backup == nil then
		return HttpService:JSONEncode({ restored = false, reason = "no backup" })
	end
	profile.quests = backup.quests
	profile.gems = backup.gems
	profile.spin = backup.spin
	_G[BACKUP] = nil
	PlayerDataService.markChanged(player, true, { "quests", "gems", "spin" })
	return HttpService:JSONEncode({ restored = true })
end
return HttpService:JSONEncode({ error = "unknown command" })
