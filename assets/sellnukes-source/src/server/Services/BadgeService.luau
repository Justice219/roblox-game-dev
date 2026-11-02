--!strict
--[[
	BadgeService (SellNukes) — permanent Roblox badges for milestones (docs/leaderboards.md
	§ Badges): Welcome, each area reached (2–10), first manager, first rebirth, first hatch, the
	completed Harvest Feast sticker sheet and (owner R57) Dino Valley's Time Traveler (first visit)
	and Volcano Tamer (first Dino finale). Catalog + pure rules: Shared/Config/BadgeConfig; Roblox
	IO: Server/Badges/BadgeAwardsQueue (one serial worker, paced, cancellable).

	How it decides: qualification is read from the authoritative profile only
	(BadgeConfig.qualifiedMask). Triggers merely WAKE the check: ProfileLoaded (also backfills
	veterans), the event's StickerFound / SheetRedeemed, B9's PetService.Hatched and the tycoon's
	PadBought / AreaReached / Rebirthed signals when those services expose them (guarded lazy
	lookups; R57: TycoonService.WorldPadBought, RebirthService.WorldRebirthed and
	WorldService.WorldChanged wake the world badges), plus a cheap re-observe of present players every ObserveEverySeconds as the safety
	net. No remote exists; clients cannot ask for a badge.

	Safety:
		- Only saving, mutable sessions qualify (never the in-memory fallback, read-only / lost
		  sessions or the admin New Player Mode sandbox).
		- BadgeId 0 (not created on the dashboard yet): the award is SKIPPED and logged once per
		  badge per server ("qualified but not created yet").
		- Studio: no live Roblox calls; qualifications are logged instead ("(Studio) would award").
		- The player attribute EarnedBadgesMask carries CONFIRMED ownership only.

	Owner admin: "BadgeStatus" (Players tab) lists a player's qualified / owned / not-created badges.

	Example: bootstrap calls Init() then Start(); reaching area 2 qualifies "Area2" within seconds.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RobloxBadges = game:GetService("BadgeService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local BadgeAwardsQueue = require(ServerScriptService.Server.Badges.BadgeAwardsQueue)
local BadgeConfig = require(ReplicatedStorage.Shared.Config.BadgeConfig)
local EventService = require(script.Parent.EventService)
local Lazy = require(ServerScriptService.Server.Event.Lazy)
local PlayerDataService = require(script.Parent.PlayerDataService)

local BadgeService = {}

type Entry = { player: Player, profile: any }

local isStudio = RunService:IsStudio()
local entries: { [number]: Entry } = {}
local pending: thread? = nil
local pendingAt = 0
local running = false
local started = false
-- Badge keys already logged as "not created yet" this server (log once per badge).
local loggedZero: { [string]: boolean } = {}
-- userId -> badge keys already logged as "(Studio) would award".
local loggedStudio: { [number]: { [string]: boolean } } = {}

-- A captured profile is valid only while that exact saving session is loaded.
local function isCurrent(userId: number): boolean
	local entry = entries[userId]
	return entry ~= nil
		and entry.player.Parent == Players
		and PlayerDataService.getProfile(entry.player) == entry.profile
		and PlayerDataService.canMutate(entry.player)
		and entry.player:GetAttribute("NewPlayerMode") ~= true
end

local badgeIds: { number } = {}
for _, def in BadgeConfig.Definitions do
	table.insert(badgeIds, def.BadgeId)
end

local queue = BadgeAwardsQueue.new(badgeIds, {
	now = os.clock,
	isCurrent = isCurrent,
	checkOwnedAsync = function(userId: number, ids: { number }): { number }
		return RobloxBadges:CheckUserBadgesAsync(userId, ids) :: { number }
	end,
	isEnabledAsync = function(badgeId: number): boolean
		local info = RobloxBadges:GetBadgeInfoAsync(badgeId)
		return info.IsEnabled == true
	end,
	-- AwardBadgeAsync's boolean result matters separately from pcall's success boolean.
	awardAsync = function(userId: number, badgeId: number): boolean
		return RobloxBadges:AwardBadgeAsync(userId, badgeId)
	end,
	publish = function(userId: number, mask: number)
		local entry = entries[userId]
		if entry ~= nil and isCurrent(userId) then
			entry.player:SetAttribute(BadgeConfig.OwnedMaskAttribute, mask)
		end
	end,
}, BadgeConfig.Worker, BadgeConfig.OwnershipBatch)

-- Keeps ONE cancellable timer while work exists (none while idle).
local function wake()
	if running then
		return
	end
	local delay = queue.nextDelay()
	if delay == nil then
		if pending ~= nil then
			task.cancel(pending)
			pending = nil
		end
		return
	end
	local due = os.clock() + delay
	if pending ~= nil then
		if pendingAt <= due then
			return
		end
		task.cancel(pending)
	end
	pendingAt = due
	pending = task.delay(delay, function()
		pending = nil
		running = true
		local ok, err = pcall(queue.stepAsync)
		running = false
		if not ok then
			warn(`[BadgeService] award step failed: {err}`)
		end
		wake()
	end)
end

-- Logs qualified badges that cannot be awarded (id 0 → once per server; Studio → once per player).
local function logSkipped(player: Player, mask: number)
	for index, def in BadgeConfig.Definitions do
		if bit32.band(mask, bit32.lshift(1, index - 1)) == 0 then
			continue
		end
		if not BadgeConfig.isConfigured(def.BadgeId) then
			if not loggedZero[def.Id] then
				loggedZero[def.Id] = true
				print(
					`[BadgeService] {def.Id} qualified ({player.Name}) but BadgeConfig id is 0 - award skipped until the badge is created`
				)
			end
		elseif isStudio then
			local seen = loggedStudio[player.UserId]
			if seen == nil then
				seen = {}
				loggedStudio[player.UserId] = seen
			end
			if not seen[def.Id] then
				seen[def.Id] = true
				print(`[BadgeService] (Studio) {player.Name} qualifies for {def.Id}; live servers award it`)
			end
		end
	end
end

-- Re-reads a player's qualification from their profile and queues any missing award.
local function observe(player: Player)
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not PlayerDataService.canMutate(player) or player:GetAttribute("NewPlayerMode") == true then
		return
	end
	local userId = player.UserId
	if userId <= 0 then
		return
	end
	local existing = entries[userId]
	if existing == nil or existing.profile ~= profile then
		queue.forget(userId)
		entries[userId] = { player = player, profile = profile }
		player:SetAttribute(BadgeConfig.OwnedMaskAttribute, 0)
	end
	local mask = BadgeConfig.qualifiedMask(profile)
	logSkipped(player, mask)
	if isStudio then
		return -- no live platform calls from Studio (admin tests included)
	end
	queue.observe(userId, mask)
	wake()
end

local function forget(player: Player)
	queue.forget(player.UserId)
	entries[player.UserId] = nil
	loggedStudio[player.UserId] = nil
	player:SetAttribute(BadgeConfig.OwnedMaskAttribute, nil)
	wake()
end

-- Connects `handler(player, ...)` to `service[signalName]` when that signal exists (guarded).
local function listen(serviceName: string, signalName: string)
	local service = Lazy.service(serviceName)
	local signal = if service ~= nil then service[signalName] else nil
	if type(signal) ~= "table" or type(signal.Connect) ~= "function" then
		return
	end
	pcall(function()
		signal:Connect(function(player: unknown)
			if typeof(player) == "Instance" and (player :: Instance):IsA("Player") then
				observe(player :: Player)
			end
		end)
	end)
end

--[[ Status lines for the admin panel ("Area2: owned", "FirstHatch: qualified", ...). ]]
function BadgeService.status(player: Player): string
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return "profile not loaded"
	end
	local owned = player:GetAttribute(BadgeConfig.OwnedMaskAttribute)
	local ownedMask = if type(owned) == "number" then owned else 0
	local parts: { string } = {}
	for index, def in BadgeConfig.Definitions do
		local bit = bit32.lshift(1, index - 1)
		local label = if bit32.band(ownedMask, bit) ~= 0
			then "owned"
			elseif BadgeConfig.qualifies(profile, def) then (if BadgeConfig.isConfigured(def.BadgeId)
				then "qualified"
				else "qualified (id 0)")
			else "-"
		table.insert(parts, `{def.Id}: {label}`)
	end
	return table.concat(parts, ", ")
end

function BadgeService.Init() end

function BadgeService.Start()
	if started then
		return
	end
	started = true
	PlayerDataService.ProfileLoaded:Connect(function(player: Player)
		observe(player)
	end)
	PlayerDataService.ProfileUnloading:Connect(forget)
	Players.PlayerRemoving:Connect(forget)
	EventService.StickerFound:Connect(function(player: Player)
		observe(player)
	end)
	EventService.SheetRedeemed:Connect(function(player: Player)
		observe(player)
	end)
	listen("PetService", "Hatched")
	listen("Tycoon/TycoonService", "PadBought")
	listen("Tycoon/TycoonService", "AreaReached")
	listen("Tycoon/RebirthService", "Rebirthed")
	-- R57 world badges (Time Traveler / Volcano Tamer): guarded, so they wire once W3 / W4 exist.
	listen("Tycoon/TycoonService", "WorldPadBought")
	listen("Tycoon/RebirthService", "WorldRebirthed")
	listen("Tycoon/WorldService", "WorldChanged")
	Lazy.registerAdmin({
		name = "BadgeStatus",
		tab = "Players",
		label = "Badge Status",
		description = "Show which badges this player owns / qualifies for.",
		target = "Player",
		args = {},
		cooldown = 2,
		audited = false,
		confirm = false,
		color = "blue",
		order = 80,
	}, function(ctx: any): (boolean, string)
		local target = ctx.target
		local player = if type(target) == "table" then target.player else nil
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return false, "Pick a player first"
		end
		observe(player)
		return true, BadgeService.status(player)
	end)
	for _, player in Players:GetPlayers() do
		observe(player)
	end
	-- Safety net: re-observe present players (cheap: a few profile reads each).
	task.spawn(function()
		while true do
			task.wait(BadgeConfig.ObserveEverySeconds)
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(observe, player)
				if not ok then
					warn(`[BadgeService] observe failed: {err}`)
				end
			end
		end
	end)
end

return BadgeService
