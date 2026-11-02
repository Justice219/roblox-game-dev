--!nocheck
--[[
	pet_index_server.luau — server-VM probe for the R78 Pet Index rewards + Golden Nukey, run by
	tools/qa/pet_index.py through eval_server_runtime during ONE solo playtest (Studio profile store
	"_Studio": live saves are never touched; "restore" puts the profile back anyway).

		COMMAND  "prepare"   backs up the player's pets / gems, sets the Index to EXACTLY the first
		                     ARGS[1] regular pets, then grants + equips a Golden Nukey through the
		                     LIVE PetService.grantPet path (the Nuke Pass grant path: it marks the
		                     exclusive pet, which counts once owned); returns the Index status
		         "claim"     PetService.handleIndexClaim(player, ARGS[1]) like the remote; returns
		                     ok, gems delta, Index Bonus, claimed ids, petCash from ModifierSources
		         "garbage"   hostile claim arguments through the same handler (all must be refused)
		         "status"    PetIndexLogic.status + equipped ids + the SNPets attribute
		         "restore"   restores the backed-up pets block + gems, removes the QA pet, refreshes
	Every command returns a JSON string.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local server = ServerScriptService:WaitForChild("Server")
local PetService = require(server.Services.PetService)
local PlayerDataService = require(server.Services.PlayerDataService)
local PetIndexLogic = require(server.Pets.PetIndexLogic)
local PetState = require(server.Pets.PetState)
local ModifierSources = require(server.Tycoon.ModifierSources)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetIndexConfig = require(ReplicatedStorage.Shared.Config.PetIndexConfig)

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

local function claimedIds(): { string }
	local out = {}
	for _, milestone in PetIndexConfig.Milestones do
		if PetState.pets(profile).indexClaimed[milestone.id] == true then
			table.insert(out, milestone.id)
		end
	end
	return out
end

local function petCash(): number
	local mods = ModifierSources.build(player, profile)
	return mods.petCash or 0
end

local function status(): { [string]: any }
	local s = PetIndexLogic.status(profile)
	local ready = {}
	for _, milestone in PetIndexConfig.claimable(PetState.pets(profile)) do
		table.insert(ready, milestone.id)
	end
	return {
		found = s.found,
		total = s.total,
		claimed = claimedIds(),
		ready = ready,
		bonus = s.bonus,
		gems = profile.gems,
		petCash = petCash(),
		attribute = player:GetAttribute(PetConfig.Attribute),
	}
end

if COMMAND == "prepare" then
	_G.__SNPetIndexQA = _G.__SNPetIndexQA or { pets = deepCopy(profile.pets), gems = profile.gems }
	local before = petCash()
	-- Exactly ARGS[1] regular pets discovered, no claims (restored afterwards).
	local index = PetState.pets(profile).index
	table.clear(index)
	local want = math.floor(ARGS[1] or 11)
	local marked = 0
	for _, id in PetConfig.Order do
		if marked >= want then
			break
		end
		if not PetConfig.Pets[id].exclusive then
			index[id] = true
			marked += 1
		end
	end
	table.clear(PetState.pets(profile).indexClaimed)
	local ok, uid = PetService.grantPet(player, "golden_nukey", "admin")
	local equipped = false
	if ok and uid ~= nil then
		local pets = PetState.pets(profile)
		if table.find(pets.equipped, uid) == nil then
			-- Put the Golden Nukey FIRST so it is the pet that follows right behind the player.
			table.insert(pets.equipped, 1, uid)
			local slots = PetService.slotsFor(player, profile)
			while #pets.equipped > slots do
				table.remove(pets.equipped)
			end
		end
		equipped = table.find(pets.equipped, uid) ~= nil
		_G.__SNPetIndexQA.uid = uid
	end
	PlayerDataService.markChanged(player, true, { "pets" })
	PetService.refresh(player)
	local out = status()
	out.granted = ok
	out.equipped = equipped
	out.petCashBefore = before
	return HttpService:JSONEncode(out)
elseif COMMAND == "claim" then
	local gems = profile.gems
	local cash = petCash()
	local ok = PetService.handleIndexClaim(player, ARGS[1])
	local out = status()
	out.ok = ok
	out.gemsDelta = profile.gems - gems
	out.petCashDelta = out.petCash - cash
	return HttpService:JSONEncode(out)
elseif COMMAND == "garbage" then
	local results = {}
	for _, bad in { 0, 8, 1.5, 0 / 0, math.huge, "1", {}, true } do
		task.wait(1.1) -- past the claim rate limit, so every refusal is the VALIDATION's
		table.insert(results, PetService.handleIndexClaim(player, bad))
	end
	local anyTrue = false
	for _, value in results do
		anyTrue = anyTrue or value == true
	end
	return HttpService:JSONEncode({ anyAccepted = anyTrue, count = #results, status = status() })
elseif COMMAND == "status" then
	return HttpService:JSONEncode(status())
elseif COMMAND == "restore" then
	local backup = _G.__SNPetIndexQA
	if backup == nil then
		return HttpService:JSONEncode({ restored = false })
	end
	profile.pets = deepCopy(backup.pets)
	profile.gems = backup.gems
	_G.__SNPetIndexQA = nil
	PlayerDataService.markChanged(player, true, { "pets", "gems" })
	PetService.refresh(player)
	return HttpService:JSONEncode({ restored = true, status = status() })
end
return "unknown"
