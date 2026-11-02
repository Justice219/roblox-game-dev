--!nocheck
--[[
	nuke_pass_server.luau — server-VM probe for the R78 Nuke Pass (P-pass), run by
	tools/qa/nuke_pass.py through eval_server_runtime during ONE solo playtest (Studio profile store
	"_Studio": live saves are never touched; "restore" puts every touched field back anyway).

		COMMAND  "prepare"   backs up the touched profile fields, shifts the Studio pass clock by
		                     ARGS[1] days (ReplicatedStorage.NukePassClockOffset; Season 1 starts
		                     2026-11-01), resets profile.pass, forces the paid-random policy to
		                     "allowed", settles the season; returns status()
		         "xp"        PassService.grantXp(player, ARGS[1], "admin")
		         "claim"     PassService.claim(player, track ARGS[1] (1 free / 2 premium / 3 overflow),
		                     tier ARGS[2]) — the remote's handler after validation
		         "claimall"  PassService.claimAll(player)
		         "receipt"   MonetizationService.simulateReceiptAsync(player, "NukePassPremium",
		                     "qa-pass-<ARGS[1]>") — the REAL receipt path (ledger, handler, durable)
		         "policy"    ARGS[1]: 1 restricted / 0 allowed / -1 clear (setPolicyOverride)
		         "clock"     sets the Studio pass clock to ARGS[1] days and settles (season end test)
		         "status"    status(): pass state + PassConfig.status + gems / spins / trails / titles
		         "restore"   restores the backed-up fields + the Title attribute, clears the clock
	Every command returns a JSON string.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local server = ServerScriptService:WaitForChild("Server")
local PassService = require(server.Services.PassService)
local PlayerDataService = require(server.Services.PlayerDataService)
local PlayerTitleService = require(server.Services.PlayerTitleService)
local MonetizationService = require(server.Services.MonetizationService)
local PassConfig = require(ReplicatedStorage.Shared.Config.PassConfig)

local BACKUP_FIELDS = { "pass", "gems", "cash", "totalEarned", "spin", "boosts", "trails", "titles", "pets", "receipts" }

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

local function now(): number
	return PassConfig.clockNow(os.time())
end

local function setOffsetDays(days: number?)
	ReplicatedStorage:SetAttribute(PassConfig.ClockOffsetAttribute, if days ~= nil then days * 86400 else nil)
end

local function list(set: { [number]: true }): { number }
	local out = {}
	for tier in set do
		table.insert(out, tier)
	end
	table.sort(out)
	return out
end

local function status(): { [string]: any }
	local pass = profile.pass
	local st = PassConfig.status(pass, now())
	local trails = {}
	for id in profile.trails.owned do
		table.insert(trails, id)
	end
	local titles = {}
	for key in profile.titles do
		table.insert(titles, key)
	end
	local petCount = 0
	for _ in profile.pets.owned do
		petCount += 1
	end
	local eggs = profile.pets.eggs.lucky_egg or 0
	return {
		season = pass.season,
		activeSeason = if st.season ~= nil then st.season.id else "",
		xp = pass.xp,
		tier = st.tier,
		xpInto = st.xpInto,
		premium = st.premium,
		premiumSeasons = deepCopy(pass.premium),
		claimedFree = list(pass.claimedFree),
		claimedPremium = list(pass.claimedPremium),
		overflow = pass.overflow,
		claimable = PassConfig.claimableCount(pass, now()),
		freeClaimable = #st.freeClaimable,
		premiumClaimable = #st.premiumClaimable,
		premiumLocked = #st.premiumLocked,
		gems = profile.gems,
		cash = profile.cash,
		bonusSpins = profile.spin.bonus,
		paidSpins = profile.spin.paid,
		luckyEggs = eggs,
		pets = petCount,
		trails = trails,
		titles = titles,
		titleAttr = player:GetAttribute("Title"),
		clockDays = (now() - os.time()) / 86400,
	}
end

if COMMAND == "prepare" then
	if _G.NukePassQaBackup == nil then
		local backup = {}
		for _, field in BACKUP_FIELDS do
			backup[field] = deepCopy(profile[field])
		end
		_G.NukePassQaBackup = backup
	end
	setOffsetDays(ARGS[1])
	profile.pass = PassConfig.newState()
	PlayerDataService.setPolicyOverride(player, false)
	PassService.settle(player)
	PlayerDataService.markChanged(player, false, { "pass" })
	return HttpService:JSONEncode(status())
elseif COMMAND == "xp" then
	local added = PassService.grantXp(player, ARGS[1] or 0, "admin")
	local out = status()
	out.added = added
	return HttpService:JSONEncode(out)
elseif COMMAND == "claim" then
	local tracks = { "free", "premium", "overflow" }
	local before = profile.gems
	local grants = PassService.claim(player, tracks[ARGS[1] or 1], ARGS[2] or 0)
	local out = status()
	out.grants = #grants
	out.gemsDelta = profile.gems - before
	return HttpService:JSONEncode(out)
elseif COMMAND == "claimall" then
	local before = { gems = profile.gems, cash = profile.cash, bonus = profile.spin.bonus, paid = profile.spin.paid }
	local grants = PassService.claimAll(player)
	local out = status()
	out.grants = #grants
	out.gemsDelta = profile.gems - before.gems
	out.cashDelta = profile.cash - before.cash
	out.bonusSpinsDelta = profile.spin.bonus - before.bonus
	out.paidSpinsDelta = profile.spin.paid - before.paid
	return HttpService:JSONEncode(out)
elseif COMMAND == "receipt" then
	local before = profile.gems
	local decision = MonetizationService.simulateReceiptAsync(player, "NukePassPremium", `qa-pass-{ARGS[1] or 1}`)
	task.wait(0.5)
	local out = status()
	out.decision = tostring(decision)
	out.gemsDelta = profile.gems - before
	return HttpService:JSONEncode(out)
elseif COMMAND == "policy" then
	local mode = ARGS[1] or -1
	PlayerDataService.setPolicyOverride(player, if mode == 1 then true elseif mode == 0 then false else nil)
	return HttpService:JSONEncode({ restricted = PlayerDataService.isPaidRandomRestricted(player) })
elseif COMMAND == "clock" then
	setOffsetDays(ARGS[1])
	local before = profile.gems
	PassService.settle(player)
	local out = status()
	out.gemsDelta = profile.gems - before
	return HttpService:JSONEncode(out)
elseif COMMAND == "status" then
	return HttpService:JSONEncode(status())
elseif COMMAND == "restore" then
	local backup = _G.NukePassQaBackup
	setOffsetDays(nil)
	PlayerDataService.setPolicyOverride(player, nil)
	if backup == nil then
		return HttpService:JSONEncode({ restored = false, reason = "no backup" })
	end
	for _, field in BACKUP_FIELDS do
		profile[field] = deepCopy(backup[field])
	end
	_G.NukePassQaBackup = nil
	player:SetAttribute("Title", PlayerTitleService.titleOf(player) or "")
	PlayerDataService.markChanged(player, true)
	return HttpService:JSONEncode({ restored = true, status = status() })
end
return HttpService:JSONEncode({ error = "unknown command " .. COMMAND })
