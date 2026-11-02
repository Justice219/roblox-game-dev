--!strict
--[[
	OfflineService — offline earnings ("Welcome back!", spec §7) and the DOUBLE IT! product.

	How it works
		* On ProfileLoaded (once per session) the elapsed time is computed from the SERVER's own
		  saved timestamp profile.offline.lastSeenAt (never the client): elapsed = os.time() - it.
		  The payout is TycoonLogic.offlineEarnings(tycoon, mods, elapsed, cap, rate) with
		  cap / rate from TycoonLogic.offlineLimits(profile.rebirthShop, owns Offline Max) and
		  modifiers from ModifierSources built in OFFLINE mode (providers registered with
		  offline = false, e.g. timed boosts, do not count). Paid with grantCash("offline"), then
		  OfflineEarnings { amount, seconds, rate } goes to the client (welcome-back popup).
		* lastSeenAt is written on ProfileReleasing (before the final save) and every
		  StampSeconds while playing (ProfileStore also stamps it on each save), so a crash loses at
		  most a minute of offline time.
		* DoubleOffline product: pays the pending payout again EXACTLY once. Prompting is refused
		  when nothing is pending, it was already doubled, or the 10-minute window passed. A receipt
		  that still arrives (bought in the last second, or the player rejoined another server where
		  nothing is pending) pays the pending amount if present, otherwise the TycoonRules fallback
		  (10 minutes of idle income, at least $1K) — Robux is never taken for nothing.

	Worlds (owner R57, spec §6.6)
		The same join also pays every UNLOCKED non-main world (Dino Valley) from the same elapsed
		time, cap and rate (player-level: Nuke Town's shop + the Offline Max pass), with that
		world's automated income and offline-mode modifiers (ModifierSources.build(..., true, w):
		its rebirth track + linkCash), granted in that world's currency (grantCurrency "offline").
		The payload gains `worlds = { { id, amount } }` (nil when no world paid); `amount` (Nuke
		Town cash) may then be 0. DOUBLE IT! doubles EVERY pending row exactly once. The
		no-pending fallback stays Cash-only. `preview(player, seconds)` is the read-only maths for
		the admin WorldOfflinePreview command.

	Connections
		PlayerDataService (profile, signals, grantCash / grantCurrency), MonetizationService
		(handler, refusal, OfflineMax pass), ModifierSources, TycoonLogic, TycoonRules,
		TycoonAnalytics, Remotes, Shared/Config/Worlds/WorldsConfig.

	Usage: boot list after TycoonService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModifierSources = require(script.Parent.ModifierSources)
local MonetizationService = require(script.Parent.Parent.Services.MonetizationService)
local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TycoonAnalytics = require(script.Parent.TycoonAnalytics)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonRules = require(script.Parent.TycoonRules)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local OfflineService = {}

-- Seconds the DOUBLE IT! offer stays available after the welcome-back payout.
OfflineService.DoubleWindowSeconds = 600
-- Seconds between in-session lastSeenAt stamps.
OfflineService.StampSeconds = 60

-- One non-main world's offline payout (granted amount, in that world's currency).
type WorldRow = { id: string, currency: string, amount: number, seconds: number }
-- amount = Nuke Town cash (may be 0 when only another world paid); worlds = the other rows.
type Pending = {
	amount: number,
	seconds: number,
	rate: number,
	expiresAt: number,
	doubled: boolean,
	worlds: { WorldRow },
}

local pending: { [Player]: Pending } = {}
local paidProfiles: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--[[
	What every UNLOCKED non-main world earns for `elapsed` offline seconds (read-only maths).
	@return {WorldRow} — rows with amount > 0 (amount = the un-granted payout)
]]
local function worldEarnings(player: Player, profile: any, elapsed: number, cap: number, rate: number): { WorldRow }
	local rows: { WorldRow } = {}
	local worlds = profile.worlds
	if type(worlds) ~= "table" then
		return rows
	end
	for _, def in WorldsConfig.extra() do
		local state = worlds[def.id]
		if type(state) ~= "table" or state.unlocked ~= true then
			continue
		end
		local mods = ModifierSources.build(player, profile, true, def.id)
		local amount, seconds = TycoonLogic.forWorld(def.id).offlineEarnings(state.tycoon, mods, elapsed, cap, rate)
		if amount > 0 then
			table.insert(rows, { id = def.id, currency = def.currency.key, amount = amount, seconds = seconds })
		end
	end
	return rows
end

--[[
	Read-only: what `seconds` offline would pay right now, per world (admin WorldOfflinePreview).
	Same cap / rate / modifiers as a real join; nothing is granted or stamped.
	@param player Player
	@param seconds number — hypothetical time away (clamped >= 0)
	@return {{ id: string, amount: number }} — Nuke Town first, then every unlocked world (0 rows kept)
	Example: OfflineService.preview(player, 8 * 3600) --> { { id = "main", amount = 1.2e12 }, { id = "dino", amount = 4.5e6 } }
]]
function OfflineService.preview(player: Player, seconds: number): { { id: string, amount: number } }
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return {}
	end
	local elapsed = if type(seconds) == "number"
			and seconds == seconds
			and seconds > 0
		then math.min(seconds, 1e9)
		else 0
	local cap, rate = TycoonLogic.offlineLimits(profile.rebirthShop, MonetizationService.ownsPass(player, "OfflineMax"))
	local mods = ModifierSources.build(player, profile, true)
	local amount = TycoonLogic.offlineEarnings(profile.tycoon, mods, elapsed, cap, rate)
	local rows: { { id: string, amount: number } } = { { id = WorldsConfig.MAIN, amount = amount } }
	local paid: { [string]: number } = {}
	for _, row in worldEarnings(player, profile, elapsed, cap, rate) do
		paid[row.id] = row.amount
	end
	for _, def in WorldsConfig.extra() do
		local state = if type(profile.worlds) == "table" then profile.worlds[def.id] else nil
		if type(state) == "table" and state.unlocked == true then
			table.insert(rows, { id = def.id, amount = paid[def.id] or 0 })
		end
	end
	return rows
end

--[[
	Computes and pays one player's offline earnings (once per loaded profile), Nuke Town and every
	unlocked world. Never yields.
	@param player Player
	@param profile any — the loaded profile
]]
function OfflineService.payOnJoin(player: Player, profile: any)
	if paidProfiles[profile] then
		return
	end
	paidProfiles[profile] = true
	local lastSeen = profile.offline.lastSeenAt
	if type(lastSeen) ~= "number" or lastSeen <= 0 then
		profile.offline.lastSeenAt = os.time()
		return -- a brand-new profile has never been away
	end
	local elapsed = os.time() - lastSeen
	local cap, rate = TycoonLogic.offlineLimits(profile.rebirthShop, MonetizationService.ownsPass(player, "OfflineMax"))
	local mods = ModifierSources.build(player, profile, true)
	local amount, seconds = TycoonLogic.offlineEarnings(profile.tycoon, mods, elapsed, cap, rate)
	local earned = worldEarnings(player, profile, elapsed, cap, rate)
	profile.offline.lastSeenAt = os.time()
	if amount <= 0 and #earned == 0 then
		return
	end
	local added = if amount > 0 then PlayerDataService.grantCash(player, amount, "offline") else 0
	-- Other worlds: granted in their own currency; rows that could not be granted are dropped.
	local rows: { WorldRow } = {}
	for _, row in earned do
		local granted = PlayerDataService.grantCurrency(player, row.currency, row.amount, "offline")
		if granted > 0 then
			row.amount = granted
			table.insert(rows, row)
			seconds = math.max(seconds, row.seconds)
		end
	end
	if added <= 0 and #rows == 0 then
		return
	end
	pending[player] = {
		amount = added,
		seconds = seconds,
		rate = rate,
		expiresAt = os.clock() + OfflineService.DoubleWindowSeconds,
		doubled = false,
		worlds = rows,
	}
	local payload: { [string]: any } = { amount = added, seconds = seconds, rate = rate }
	if #rows > 0 then
		local list: { { id: string, amount: number } } = {}
		for _, row in rows do
			table.insert(list, { id = row.id, amount = row.amount })
		end
		payload.worlds = list
	end
	Remotes.fireClient("OfflineEarnings", player, payload)
	if added > 0 then
		TycoonAnalytics.call("offlinePaid", player, seconds, added)
	end
	for _, row in rows do
		TycoonAnalytics.call("worldOfflinePaid", player, row.id, row.seconds, row.amount)
	end
end

--[[ The player's pending (undoubled, unexpired) offline payout, or nil. ]]
function OfflineService.pendingDouble(player: Player): Pending?
	local entry = pending[player]
	if entry == nil or entry.doubled or os.clock() > entry.expiresAt then
		return nil
	end
	return entry
end

-- DoubleOffline receipt: every pending row again, once; otherwise the fallback grant (Cash).
local function grantDouble(player: Player, _profile: any, _product: any, _receipt: any): boolean
	local entry = pending[player]
	local amount: number
	if entry ~= nil and not entry.doubled then
		amount = entry.amount -- even just past the window: the player paid for this payout
		entry.doubled = true
		for _, row in entry.worlds do
			PlayerDataService.grantCurrency(player, row.currency, row.amount, "offlineDouble")
			TycoonAnalytics.call("worldOfflineDoubled", player, row.id)
		end
		if amount <= 0 then
			return true -- only other worlds were pending (paid above)
		end
		TycoonAnalytics.call("offlineDoubled", player)
	else
		local profile = PlayerDataService.getProfile(player)
		local income = if profile ~= nil
			then TycoonLogic.incomePerSecond(profile.tycoon, (ModifierSources.build(player, profile, true)))
			else 0
		amount = TycoonRules.fallbackGrant(income)
	end
	PlayerDataService.grantCash(player, amount, "offlineDouble")
	return true
end

function OfflineService.Init()
	MonetizationService.registerProductHandler("DoubleOffline", grantDouble)
	MonetizationService.registerPromptRefusal("DoubleOffline", function(player: Player, _product: any): string?
		if OfflineService.pendingDouble(player) == nil then
			return "Nothing to double right now!"
		end
		return nil
	end)
end

function OfflineService.Start()
	PlayerDataService.ProfileLoaded:Connect(function(player: Player, profile: any)
		OfflineService.payOnJoin(player, profile)
	end)
	PlayerDataService.ProfileReleasing:Connect(function(_player: Player, profile: any)
		profile.offline.lastSeenAt = os.time() -- before the final save; never yields
	end)
	for _, player in Players:GetPlayers() do
		local profile = PlayerDataService.getProfile(player)
		if profile ~= nil then
			OfflineService.payOnJoin(player, profile) -- loaded before this service started
		end
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		pending[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(OfflineService.StampSeconds)
			local stamp = os.time()
			for _, player in Players:GetPlayers() do
				local profile = PlayerDataService.getProfile(player)
				if profile ~= nil then
					profile.offline.lastSeenAt = stamp
				end
			end
		end
	end)
end

return OfflineService
