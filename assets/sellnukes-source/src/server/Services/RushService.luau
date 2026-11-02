--!strict
--[[
	RushService — the R78 Rush boosts (spec §3; docs/social.md): Rookie Rush for brand-new
	players and Comeback Rush for lapsed players. Pure rules: Server/Social/RushLogic.

	What it does
		* Rookie Rush: the FIRST load of a brand-new profile (PlayerDataService ProfileLoaded with
		  isNew, on a saving session — never an in-memory fallback of an existing player) gets
		  profile.rush.rookieLeft = RookieMinutes * 60. The seconds only count down while the player
		  is online: on load they become a session end time; every Rush.SyncSeconds, at leave and
		  before a New Player Mode swap the rest is written back (and pushed: snapshot field `rush`).
		  Saves from before 0.6.0 have no `rush` record → rookieLeft 0 → never a Rookie Rush.
		* Comeback Rush: on a JOIN whose previous save is >= ComebackAwayHours old (the server's own
		  profile.offline.lastSeenAt, never the client), comebackUntil = now + ComebackMinutes * 60,
		  and a `Social { kind = "comeback" }` event lets the Welcome Back screen say
		  "COMEBACK RUSH!". The two rushes never stack (the larger multiplier applies).
		* Income: ModifierSources provider "rush" → { rushCash = 2 } while a rush runs, registered
		  with offline = false (never inflates offline earnings; RewardLogic never reads it). Its
		  validUntil is the rush end, so the tycoon recomputes exactly when it runs out.
		* Kill switch / tunables: ReplicatedStorage attributes (SocialConfig.Attributes) set by the
		  admin commands below. OFF = neutral multiplier and the Rookie Rush clock pauses.

	Ordering note (why ProfileLoaded is connected in Init): OfflineService.payOnJoin re-stamps
	profile.offline.lastSeenAt in ITS ProfileLoaded handler (connected in its Start). Signal
	handlers run in connection order and every Init runs before any Start, so connecting here in
	Init reads the previous save's timestamp before it is overwritten.

	Analytics (retention family): rush:grant:<rookie|comeback>, rush:sec:<rookie|comeback>
	(boosted seconds played per session), rush:done:<rookie|comeback> (ran out while playing),
	rush:awayDays:<2-31> (days away at a comeback, 31 = 31+).
	Admin (Lazy.registerAdmin): RushToggle, RushMinutes (Server tab); RushGrant, RushClear,
	RushStatus (Players tab). Audited except the status read.

	Public API:
		RushService.status(player) -> { rookieLeft, comebackLeft, multiplier, kind }?
		RushService.grant(player, "rookie" | "comeback", seconds) -> boolean
		RushService.clear(player) -> boolean

	Connects to: PlayerDataService (signals, profile, markChanged, canMutate, load reason),
	Tycoon/ModifierSources, Shared/Config/SocialConfig, Social/RushLogic, Shared/Net/Remotes
	("Social"), Server/Event/Lazy (analytics + admin), Client/Social/SocialClient,
	UI/Screens/{BoostChips, WelcomeBack}.

	Usage: FEATURE service (boot list after OfflineService; before AdminService).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Lazy = require(ServerScriptService.Server.Event.Lazy)
local ModifierSources = require(ServerScriptService.Server.Tycoon.ModifierSources)
local PlayerDataService = require(script.Parent.PlayerDataService)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RushLogic = require(ServerScriptService.Server.Social.RushLogic)
local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)

local RUSH = SocialConfig.Rush
local ATTR = SocialConfig.Attributes
local RATES: RushLogic.Rates = { rookie = RUSH.RookieMultiplier, comeback = RUSH.ComebackMultiplier }
-- Analytics bucket cap of rush:awayDays (31 = "31 or more days").
local MAX_AWAY_DAYS = 31

-- One player's live rush bookkeeping (never saved; the profile holds the durable part).
type Session = {
	profile: any, -- the profile this session belongs to (a New Player Mode swap replaces it)
	rookieEndsAt: number?, -- running Rookie Rush end (os.time); nil = none / paused
	rookieUsed: number, -- Rookie Rush seconds played this session (analytics)
	lastSync: number, -- os.time() of the last rookieLeft write + push
	comebackFrom: number?, -- when this session's comeback time started counting (analytics)
}

local RushService = {}

local sessions: { [Player]: Session } = {}
local started = false

-- The admin-overridable values right now (ReplicatedStorage attributes).
local function live(): SocialConfig.Live
	return SocialConfig.live(function(name: string): any
		return ReplicatedStorage:GetAttribute(name)
	end)
end

-- Counts one retention analytics key (never errors / yields).
local function track(player: Player?, key: string, amount: number?)
	Lazy.analytics("retention", player, key, amount)
end

--[[
	Writes the running Rookie Rush's remaining seconds into the profile and accumulates the
	seconds played (analytics). Never yields.
	@return true when rookieLeft changed
]]
local function syncRookie(session: Session, now: number): boolean
	local rush = session.profile.rush
	local before = rush.rookieLeft
	local after = RushLogic.consume(rush, session.rookieEndsAt, now)
	if after < before then
		session.rookieUsed += before - after
	end
	session.lastSync = now
	return after ~= before
end

--[[
	Persists + pushes profile.rush (the snapshot field `rush`). A running Rookie Rush is synced
	first, so every push carries an exact rookieLeft (the client counts down from it).
]]
local function pushRush(player: Player, session: Session, now: number, saveSoon: boolean)
	if session.rookieEndsAt ~= nil then
		syncRookie(session, now)
	end
	PlayerDataService.markChanged(player, saveSoon, { "rush" })
end

-- Records the Comeback Rush seconds this session played (since comebackFrom). Never yields.
local function recordComeback(player: Player, session: Session, now: number)
	local from = session.comebackFrom
	if from == nil then
		return
	end
	session.comebackFrom = nil
	local untilTime = math.min(now, session.profile.rush.comebackUntil)
	if untilTime > from then
		track(player, "rush:sec:comeback", untilTime - from)
	end
end

-- Records a session's boosted seconds (rookie + comeback) and clears the counters. Never yields.
local function recordUsage(player: Player, session: Session, now: number)
	if session.rookieUsed > 0 then
		track(player, "rush:sec:rookie", session.rookieUsed)
		session.rookieUsed = 0
	end
	recordComeback(player, session, now)
end

-- Ends a player's session: final rookie write + usage analytics. Never yields; idempotent.
local function flush(player: Player)
	local session = sessions[player]
	if session == nil then
		return
	end
	sessions[player] = nil
	local now = os.time()
	if session.rookieEndsAt ~= nil then
		syncRookie(session, now)
	end
	recordUsage(player, session, now)
end

-- Starts / pauses the Rookie Rush clock to match the kill switch. Returns true when it changed.
local function applySwitch(session: Session, on: boolean, now: number): boolean
	local rush = session.profile.rush
	if on and session.rookieEndsAt == nil and rush.rookieLeft > 0 then
		session.rookieEndsAt = RushLogic.sessionEndsAt(rush, now)
		session.lastSync = now
		return true
	end
	if not on and session.rookieEndsAt ~= nil then
		syncRookie(session, now)
		session.rookieEndsAt = nil
		return true
	end
	return false
end

--[[
	ProfileLoaded (connected in Init, see the header): Rookie grant, Comeback check, session.
	Never yields.
]]
local function onLoaded(player: Player, profile: any, isNew: boolean)
	flush(player) -- a New Player Mode swap: the old profile was flushed on ProfileUnloading already
	local now = os.time()
	local settings = live()
	local rush = profile.rush
	local changed = false
	-- Rookie: brand-new profile on a session that saves (never an existing player's in-memory
	-- fallback). A New Player Mode sandbox is brand-new too, so an admin sees the real first minute.
	-- Granted even while the kill switch is OFF: OFF only pauses the clock, so a newcomer who
	-- joins during an outage still gets their full rush once it is back on.
	if isNew and PlayerDataService.canMutate(player) then
		if RushLogic.grantRookie(rush, settings.rookieMinutes * 60) then
			changed = true
			track(player, "rush:grant:rookie")
		end
	end
	-- Comeback: a real join (never a New Player Mode swap) of a profile that was saved before.
	local comebackSeconds = settings.comebackMinutes * 60
	local comebackAway: number? = nil
	if not isNew and settings.rushOn and PlayerDataService.getLoadReason(player) == "join" then
		local due, away =
			RushLogic.comebackDue(rush, profile.offline.lastSeenAt, now, RUSH.ComebackAwayHours, comebackSeconds)
		if due and away ~= nil then
			RushLogic.grantComeback(rush, now, comebackSeconds)
			changed = true
			comebackAway = away
			track(player, "rush:grant:comeback")
			track(player, `rush:awayDays:{math.clamp(math.floor(away / 86400), 2, MAX_AWAY_DAYS)}`)
		end
	end
	local session: Session = {
		profile = profile,
		rookieEndsAt = nil,
		rookieUsed = 0,
		lastSync = now,
		comebackFrom = if rush.comebackUntil > now then now else nil,
	}
	sessions[player] = session
	applySwitch(session, settings.rushOn, now)
	if changed then
		PlayerDataService.markChanged(player, true, { "rush" })
	end
	ModifierSources.invalidate(player)
	if comebackAway ~= nil then
		-- Deferred: after OfflineService's OfflineEarnings of this same join (the Welcome Back
		-- screen then shows the payout WITH the comeback line).
		local away = comebackAway
		task.defer(function()
			if player.Parent == Players and sessions[player] == session then
				Remotes.fireClient("Social", player, {
					kind = "comeback",
					away = away,
					seconds = comebackSeconds,
					multiplier = RUSH.ComebackMultiplier,
				})
			end
		end)
	end
end

-- The "rush" ModifierSources provider (pure, never yields; see the header).
local function provider(player: Player, profile: any): (any, number?)
	if type(profile) ~= "table" or type(profile.rush) ~= "table" then
		return nil, nil
	end
	if ReplicatedStorage:GetAttribute(ATTR.RushEnabled) == false then
		return nil, nil
	end
	local session = sessions[player]
	local endsAt = if session ~= nil and session.profile == profile then session.rookieEndsAt else nil
	local comebackUntil = profile.rush.comebackUntil
	local multiplier, validUntil =
		RushLogic.multiplier(endsAt, if type(comebackUntil) == "number" then comebackUntil else 0, os.time(), RATES)
	if multiplier <= 1 then
		return nil, validUntil
	end
	return { rushCash = multiplier }, validUntil
end

-- One bookkeeping pass for every session (the ONE loop): switch, expiry, periodic sync.
local function tick()
	local now = os.time()
	local on = live().rushOn
	for player, session in sessions do
		if PlayerDataService.getProfile(player) ~= session.profile then
			continue -- a swap is in progress; ProfileLoaded rebuilds the session
		end
		local fields = false
		if applySwitch(session, on, now) then
			ModifierSources.invalidate(player)
			fields = true
		end
		local endsAt = session.rookieEndsAt
		if endsAt ~= nil then
			if now >= endsAt then
				syncRookie(session, now)
				session.rookieEndsAt = nil
				track(player, "rush:done:rookie")
				ModifierSources.invalidate(player)
				fields = true
			elseif now - session.lastSync >= RUSH.SyncSeconds then
				fields = syncRookie(session, now) or fields
			end
		end
		local rush = session.profile.rush
		if session.comebackFrom ~= nil and rush.comebackUntil > 0 and now >= rush.comebackUntil then
			recordComeback(player, session, now)
			rush.comebackUntil = 0
			track(player, "rush:done:comeback")
			fields = true
		end
		if fields then
			pushRush(player, session, now, false)
		end
	end
end

--[[
	A player's rush right now, or nil when not loaded.
	@return { rookieLeft, comebackLeft, multiplier, kind, running }
	Example: RushService.status(player).multiplier --> 2
]]
function RushService.status(player: Player): {
	rookieLeft: number,
	comebackLeft: number,
	multiplier: number,
	kind: string,
	running: boolean,
}?
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return nil
	end
	local now = os.time()
	local session = sessions[player]
	local endsAt = if session ~= nil and session.profile == profile then session.rookieEndsAt else nil
	local rookieLeft = if endsAt ~= nil then math.max(0, endsAt - now) else profile.rush.rookieLeft
	local multiplier, _, kind = RushLogic.multiplier(endsAt, profile.rush.comebackUntil, now, RATES)
	if ReplicatedStorage:GetAttribute(ATTR.RushEnabled) == false then
		multiplier, kind = 1, "none"
	end
	return {
		rookieLeft = rookieLeft,
		comebackLeft = math.max(0, profile.rush.comebackUntil - now),
		multiplier = multiplier,
		kind = kind,
		running = endsAt ~= nil,
	}
end

--[[
	Admin / tests: sets a rush for a player (REPLACES the current one of that kind).
	@param kind "rookie" | "comeback"
	@param seconds number — 1 .. Rush.MaxMinutes * 60
	@return true when applied
	Example: RushService.grant(player, "comeback", 600)
]]
function RushService.grant(player: Player, kind: string, seconds: number): boolean
	local profile = PlayerDataService.getProfile(player)
	local session = sessions[player]
	if profile == nil or session == nil or session.profile ~= profile then
		return false
	end
	if type(seconds) ~= "number" or seconds ~= seconds or seconds < 1 then
		return false
	end
	local amount = math.clamp(math.floor(seconds), 1, RUSH.MaxMinutes * 60)
	local now = os.time()
	if kind == "rookie" then
		if session.rookieEndsAt ~= nil then
			syncRookie(session, now)
		end
		profile.rush.rookieLeft = amount
		session.rookieEndsAt = nil
		applySwitch(session, live().rushOn, now)
	elseif kind == "comeback" then
		recordComeback(player, session, now)
		profile.rush.comebackUntil = now + amount
		session.comebackFrom = now
	else
		return false
	end
	pushRush(player, session, now, true)
	ModifierSources.invalidate(player)
	return true
end

--[[
	Admin: removes both rushes from a player.
	@return true when the player was loaded
]]
function RushService.clear(player: Player): boolean
	local profile = PlayerDataService.getProfile(player)
	local session = sessions[player]
	if profile == nil or session == nil or session.profile ~= profile then
		return false
	end
	local now = os.time()
	if session.rookieEndsAt ~= nil then
		syncRookie(session, now)
	end
	recordUsage(player, session, now)
	session.rookieEndsAt = nil
	profile.rush.rookieLeft = 0
	profile.rush.comebackUntil = 0
	PlayerDataService.markChanged(player, true, { "rush" })
	ModifierSources.invalidate(player)
	return true
end

-- ── Admin ────────────────────────────────────────────────────────────────────────────────────

-- "12:34" for whole seconds (admin status text).
local function clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

-- Registers the owner-panel commands (Server tab order 80+, Players tab order 80+).
local function registerAdmin()
	Lazy.registerAdmin({
		name = "RushToggle",
		tab = "Server",
		label = "Rush Boosts On/Off",
		description = "Kill switch for Rookie + Comeback Rush on this server (OFF = no 2x; the Rookie clock pauses).",
		target = "None",
		args = { mode = { kind = "enum", values = { "on", "off" }, labels = { "ON", "OFF" }, label = "Mode" } },
		argOrder = { "mode" },
		cooldown = 2,
		audited = true,
		confirm = false,
		color = "orange",
		order = 80,
	}, function(ctx: any): (boolean, string)
		local on = ctx.args.mode == "on"
		ReplicatedStorage:SetAttribute(ATTR.RushEnabled, on)
		tick()
		ModifierSources.invalidateAll()
		return true, `Rush boosts: {if on then "ON" else "OFF"}`
	end)
	Lazy.registerAdmin({
		name = "RushMinutes",
		tab = "Server",
		label = "Rush Minutes",
		description = "Minutes of NEW Rookie / Comeback Rush grants on this server (running rushes keep theirs).",
		target = "None",
		args = {
			kind = {
				kind = "enum",
				values = { "rookie", "comeback" },
				labels = { "Rookie", "Comeback" },
				label = "Rush",
			},
			minutes = {
				kind = "integer",
				min = RUSH.MinMinutes,
				max = RUSH.MaxMinutes,
				presets = { 5, 10, 15, 30, 60 },
				label = "Minutes",
				format = "minutes",
				default = RUSH.RookieMinutes,
			},
		},
		argOrder = { "kind", "minutes" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = 81,
	}, function(ctx: any): (boolean, string)
		local minutes = math.clamp(math.floor(ctx.args.minutes), RUSH.MinMinutes, RUSH.MaxMinutes)
		local attribute = if ctx.args.kind == "rookie" then ATTR.RookieMinutes else ATTR.ComebackMinutes
		ReplicatedStorage:SetAttribute(attribute, minutes)
		return true, `{ctx.args.kind} rush: {minutes} min for new grants`
	end)
	Lazy.registerAdmin({
		name = "RushGrant",
		tab = "Players",
		label = "Grant Rush",
		description = "Gives the player a Rookie (online minutes) or Comeback (wall-clock) 2x Cash rush, replacing theirs.",
		target = "Player",
		args = {
			kind = {
				kind = "enum",
				values = { "rookie", "comeback" },
				labels = { "Rookie", "Comeback" },
				label = "Rush",
			},
			minutes = {
				kind = "integer",
				min = RUSH.MinMinutes,
				max = RUSH.MaxMinutes,
				presets = { 5, 10, 15, 30, 60 },
				label = "Minutes",
				format = "minutes",
				default = RUSH.RookieMinutes,
			},
		},
		argOrder = { "kind", "minutes" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = 80,
	}, function(ctx: any): (boolean, string)
		local player = if ctx.target ~= nil then ctx.target.player else nil
		if player == nil then
			return false, "Player not in this server"
		end
		local ok = RushService.grant(player, ctx.args.kind, ctx.args.minutes * 60)
		return ok, if ok then `{ctx.args.kind} rush {ctx.args.minutes} min → {player.Name}` else "Profile not loaded"
	end)
	Lazy.registerAdmin({
		name = "RushClear",
		tab = "Players",
		label = "Clear Rush",
		description = "Removes the player's Rookie and Comeback Rush.",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = 81,
	}, function(ctx: any): (boolean, string)
		local player = if ctx.target ~= nil then ctx.target.player else nil
		if player == nil then
			return false, "Player not in this server"
		end
		local ok = RushService.clear(player)
		return ok, if ok then `Rush cleared for {player.Name}` else "Profile not loaded"
	end)
	Lazy.registerAdmin({
		name = "RushStatus",
		tab = "Players",
		label = "Rush Status",
		description = "The player's Rookie / Comeback Rush time left and current multiplier.",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = false,
		confirm = false,
		color = "orange",
		order = 82,
	}, function(ctx: any): (boolean, string)
		local player = if ctx.target ~= nil then ctx.target.player else nil
		local status = if player ~= nil then RushService.status(player) else nil
		if player == nil or status == nil then
			return false, "Player not loaded"
		end
		local settings = live()
		return true,
			`{player.Name}: x{status.multiplier} ({status.kind}) · rookie {clock(status.rookieLeft)} ({if status.running
				then "running"
				else "paused"}) · comeback {clock(status.comebackLeft)} · server {if settings.rushOn
				then "ON"
				else "OFF"}, new grants {settings.rookieMinutes} / {settings.comebackMinutes} min`
	end)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────────────────────

--[[ Init: connects the profile signals (BEFORE OfflineService's Start; see the header). ]]
function RushService.Init()
	PlayerDataService.ProfileLoaded:Connect(onLoaded)
	-- A New Player Mode swap: flush into the OLD profile before it is swapped out.
	PlayerDataService.ProfileUnloading:Connect(flush)
	-- Leave / shutdown: the final rookieLeft lands in the final save.
	PlayerDataService.ProfileReleasing:Connect(function(player: Player, _profile: any)
		flush(player)
	end)
end

--[[ Start: the income provider, admin commands and the ONE bookkeeping loop. Idempotent. ]]
function RushService.Start()
	if started then
		return
	end
	started = true
	-- Timed boosts never count toward offline earnings (offline = false).
	ModifierSources.register("rush", provider, { offline = false })
	-- Profiles loaded before this service existed (none in a normal boot): bookkeeping only.
	for _, player in Players:GetPlayers() do
		local profile = PlayerDataService.getProfile(player)
		if profile ~= nil and sessions[player] == nil then
			local now = os.time()
			local session: Session = {
				profile = profile,
				rookieEndsAt = nil,
				rookieUsed = 0,
				lastSync = now,
				comebackFrom = if profile.rush.comebackUntil > now then now else nil,
			}
			sessions[player] = session
			applySwitch(session, live().rushOn, now)
			ModifierSources.invalidate(player)
		end
	end
	Players.PlayerRemoving:Connect(flush)
	registerAdmin()
	task.spawn(function()
		while true do
			task.wait(RUSH.TickSeconds)
			tick()
		end
	end)
end

return RushService
