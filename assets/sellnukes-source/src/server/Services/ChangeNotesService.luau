--!strict
--[[
	ChangeNotesService — the server half of WHAT'S NEW change notes (port of RoBeasts'
	ChangeNotesService, owner R58; data Shared/Config/ChangeNotesConfig, rules
	Shared/Util/ChangeNotesLogic, docs/change-notes.md).

	What it does:
		1. On every profile load (PlayerDataService.ProfileLoaded, also after a New Player Mode
		   swap): a player with no context — a brand-new profile (ProfileStore migration "new") or
		   a tutorial that is not finished (profile.tycoon.tutorialStep < TutorialLogic.DoneStep) —
		   gets the NEWEST VISIBLE note marked seen in profile.notes, so they never get the auto
		   pop-up and the HUD chip's NEW dot stays off. Returning players are left untouched: their
		   client auto-opens the panel once (ChangeNotes/ChangeNotesClient). Runs synchronously
		   inside ProfileLoaded, before PlayerDataService's first snapshot push, so a new player's
		   client never even sees an "unseen" note.
		   REVEALS (a note published early with a future ShowFrom): the server arms ONE task.delay
		   to ChangeNotesConfig.nextShowFrom; when it fires it re-runs the same rule for every
		   loaded session (no-context = classified so at load OR still so now), saves + pushes each
		   change ("notes") and re-arms. Clients reveal Auto.RevealLagSeconds later (then wait
		   FirstCheckDelay + PoliteChecks), so the pushed `seen` lands first and a new player never
		   gets the revealed note's pop-up.
		2. ChangeNotesAction(verb, noteId, arg?) C→S (Remotes):
		     "seen"    profile.notes.seen moves FORWARD to noteId — a known, visible note strictly
		               newer than the stored one (ChangeNotesLogic.markSeen); junk / backwards ids
		               are ignored. Saved soon + pushed (snapshot field `notes`).
		     "shown"   (arg = source "auto" | "menu") → retention "notes:shown:<id>:<source>"
		     "cta"     → "notes:cta:<id>"
		     "closed"  (arg = seconds open, clamped 0..Server.MaxOpenSeconds) → "notes:closed:<id>",
		               + "notes:openSec:<id>" (summed seconds; avg = openSec / closed) and the
		               histogram "notes:openLen:<lt5|5to15|15to60|gt60>"
		   Security: every argument is untrusted (ChangeNotesLogic.parseAction: allowlisted verb, a
		   KNOWN note id ≤ MaxIdLength that is visible at the server's os.time(), allowlisted source,
		   clamped finite seconds), a per-player token bucket (Server.ActionBurst / ActionPerSecond),
		   a per-session cap per analytics key (Server.MaxReportsPerKey), canMutate for the profile
		   write. Nothing is ever granted.
		3. Purchase-flow hint (ChangeNotesConfig.PurchaseFlow): when the player asks for a Roblox
		   purchase prompt (PromptProduct / PromptPass — an extra listener next to
		   MonetizationService's, which still validates and prompts), the replicated Player
		   attribute PurchaseFlowAt = unix seconds is set; Roblox's PromptProduct / GamePass
		   "Finished" events clear it, and one 2 s sweep clears holds older than HoldSeconds. The
		   client never auto-opens the panel while it is set. UI hint only.
		4. Owner admin (Server/Admin/ChangeNotesAdmin, hard rule 9): reset a player's seen note
		   (adminReset — the only way it moves BACK) and preview the panel (adminPreview).

	Connects to: PlayerDataService (getSession / getProfile / canMutate / markChanged /
	ProfileLoaded), AnalyticsService (retention / record / registerIds), Server/Tycoon/TutorialLogic
	(DoneStep), Server/Admin/ChangeNotesAdmin, Remotes, MarketplaceService.

	Example:
		ChangeNotesService.handleAction(player, "seen", ChangeNotesConfig.newest().Id) --> "Ok"
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsService = require(script.Parent.AnalyticsService)
local ChangeNotesAdmin = require(script.Parent.Parent.Admin.ChangeNotesAdmin)
local ChangeNotesConfig = require(ReplicatedStorage.Shared.Config.ChangeNotesConfig)
local ChangeNotesLogic = require(ReplicatedStorage.Shared.Util.ChangeNotesLogic)
local PlayerDataService = require(script.Parent.PlayerDataService)
local ProfileLogic = require(script.Parent.Parent.Economy.ProfileLogic)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TutorialLogic = require(script.Parent.Parent.Tycoon.TutorialLogic)

type Profile = ProfileLogic.Profile

-- What handleAction did (tests read it; the remote ignores it).
export type Outcome = "Ok" | "Counted" | "Capped" | "RateLimited" | "Invalid" | "NoProfile" | ChangeNotesLogic.Verdict

local Server = ChangeNotesConfig.Server
local PurchaseFlow = ChangeNotesConfig.PurchaseFlow

-- Remotes that ask the server for a Roblox purchase prompt (MonetizationService validates them).
local PURCHASE_REMOTES: { Remotes.EventName } = { "PromptProduct", "PromptPass" }
-- The hold sweep's period (seconds): one loop for the whole server, idle while nothing is held.
local SWEEP_SECONDS = 2
-- A reveal timer that fires a hair early (os.time() is whole seconds) re-arms after at least this.
local REVEAL_RETRY_SECONDS = 0.25
-- Fire this far past ShowFrom so os.time() has certainly reached it.
local REVEAL_EPSILON_SECONDS = 0.05

local ChangeNotesService = {}

local limiter = RateLimiter.new(Server.ActionBurst, Server.ActionPerSecond)
-- Analytics reports counted this session: player → metric key → count (capped per key).
local reports: { [Player]: { [string]: number } } = {}
-- Purchase-flow holds: player → os.clock() deadline.
local holds: { [Player]: number } = {}
local sweeping = false
local started = false
-- Players the load rule classified as no-context this session (the reveal re-check keeps them so).
local noContextAtLoad: { [Player]: boolean } = {}
-- The one pending reveal timer (task.delay), nil while none is armed.
local revealThread: thread? = nil

-- True when the player's tutorial is finished (the SellNukes "has context" rule).
local function tutorialDone(profile: Profile): boolean
	return profile.tycoon.tutorialStep >= TutorialLogic.DoneStep
end

-- Counts one analytics key (+ optional amount) for the player, at most MaxReportsPerKey per session.
local function countCapped(player: Player, key: string): boolean
	local counted = reports[player]
	if counted == nil then
		counted = {}
		reports[player] = counted
	end
	local n = counted[key] or 0
	if n >= Server.MaxReportsPerKey then
		return false
	end
	counted[key] = n + 1
	AnalyticsService.retention(player, key)
	return true
end

--[[
	Profile load hook (see the module header, 1). Exposed for tests.
	@return true when profile.notes changed (the newest note was marked seen)
]]
function ChangeNotesService.onProfileLoaded(player: Player, profile: Profile): boolean
	local session = PlayerDataService.getSession(player)
	if session == nil or session.profile ~= profile or not PlayerDataService.canMutate(player) then
		return false
	end
	local done = tutorialDone(profile)
	noContextAtLoad[player] = if ChangeNotesLogic.isNoContextPlayer(session.migration, done) then true else nil
	if ChangeNotesLogic.onProfileLoaded(profile.notes, session.migration, done, os.time()) then
		PlayerDataService.markChanged(player, false, { "notes" })
		return true
	end
	return false
end

--[[
	Re-applies the no-context rule to one loaded session at `now` (a reveal just happened). A
	player the LOAD classified as no-context stays no-context for the session (they may have
	finished the tutorial since, but they are still on their first visit). Exposed for tests.
	@return true when profile.notes changed (saved soon + pushed)
]]
function ChangeNotesService.revealFor(player: Player, now: number): boolean
	local session = PlayerDataService.getSession(player)
	local profile = if session ~= nil then session.profile else nil
	if session == nil or profile == nil or not PlayerDataService.canMutate(player) then
		return false
	end
	local done = noContextAtLoad[player] ~= true and tutorialDone(profile)
	if ChangeNotesLogic.onProfileLoaded(profile.notes, session.migration, done, now) then
		PlayerDataService.markChanged(player, true, { "notes" })
		return true
	end
	return false
end

--[[
	One reveal pass over every online player (the timer's body; tests call it directly).
	@return how many profiles changed
]]
function ChangeNotesService.revealPass(now: number): number
	local changed = 0
	for _, player in Players:GetPlayers() do
		if ChangeNotesService.revealFor(player, now) then
			changed += 1
		end
	end
	return changed
end

-- Arms ONE task.delay to the next ShowFrom (replacing any pending one); no-op when none is left.
local function armReveal()
	if revealThread ~= nil then
		task.cancel(revealThread)
		revealThread = nil
	end
	local at = ChangeNotesConfig.nextShowFrom(os.time())
	if at == nil then
		return
	end
	-- Sub-second clock so the pass runs just after ShowFrom, not up to a second late.
	local exactNow = DateTime.now().UnixTimestampMillis / 1000
	local delaySeconds = math.max(REVEAL_RETRY_SECONDS, at - exactNow + REVEAL_EPSILON_SECONDS)
	revealThread = task.delay(delaySeconds, function()
		revealThread = nil
		local ok, err = pcall(ChangeNotesService.revealPass, os.time())
		if not ok then
			warn(`[ChangeNotesService] reveal pass failed: {err}`)
		end
		armReveal()
	end)
end

--[[
	ChangeNotesAction C→S handler (see the module header, 2). Exposed for tests.
	@param rawVerb "seen" | "shown" | "cta" | "closed" (untrusted)
	@param rawId   a ChangeNotesConfig note id (untrusted)
	@param rawArg  "shown": "auto" | "menu"; "closed": seconds open (untrusted)
	@return Outcome (what happened; the remote ignores it)
]]
function ChangeNotesService.handleAction(player: Player, rawVerb: unknown, rawId: unknown, rawArg: unknown): Outcome
	if not limiter:Allow(player) then
		return "RateLimited"
	end
	-- One server clock reading for the whole request (visibility and the stored time agree).
	local now = os.time()
	local action = ChangeNotesLogic.parseAction(rawVerb, rawId, rawArg, now)
	if action == nil then
		return "Invalid"
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return "NoProfile"
	end
	if action.verb == "seen" then
		if not PlayerDataService.canMutate(player) then
			return "NoProfile"
		end
		local verdict = ChangeNotesLogic.markSeen(profile.notes, action.id, now)
		if verdict == "Ok" then
			PlayerDataService.markChanged(player, true, { "notes" })
			countCapped(player, ChangeNotesLogic.metricKey(action))
		end
		return verdict
	end
	if not countCapped(player, ChangeNotesLogic.metricKey(action)) then
		return "Capped"
	end
	-- "Time open" of a counted close (the same per-key cap bounds these too).
	local seconds = action.seconds
	if action.verb == "closed" and seconds ~= nil then
		AnalyticsService.record("retention", player, `notes:openSec:{action.id}`, seconds)
		AnalyticsService.retention(player, `notes:openLen:{ChangeNotesLogic.openBucket(seconds)}`)
	end
	return "Counted"
end

-- Admin (Server/Admin/ChangeNotesAdmin) --------------------------------------------------------

--[[
	OWNER ADMIN: sets `player`'s seen note BACK to `id` ("" = nothing seen), saves + pushes it and
	tells their client to replay the returning-player auto pop-up (it opens at the next polite
	moment). The admin pipeline has already authorised the caller.
	@return (ok, message)
	Example: ChangeNotesService.adminReset(player, "") --> true, "..."
]]
function ChangeNotesService.adminReset(player: Player, id: string): (boolean, string)
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not PlayerDataService.canMutate(player) then
		return false, `{player.Name}'s profile is not loaded (or read-only)`
	end
	if not ChangeNotesLogic.resetSeen(profile.notes, id, os.time()) then
		return false, "Unknown note"
	end
	PlayerDataService.markChanged(player, true, { "notes" })
	-- The session's capped report counts start over, so the replayed pop-up is counted again.
	reports[player] = nil
	Remotes.fireClient("ChangeNotesAdmin", player, { action = "replay" })
	local unseen = ChangeNotesLogic.unseenCount(id, os.time())
	return true, `{player.Name}: {unseen} note(s) unseen — What's New pops up at the next calm moment`
end

--[[
	OWNER ADMIN: opens the panel on `player`'s screen in PREVIEW mode (every note, hidden ones too;
	nothing is marked seen or counted).
	@return (ok, message)
]]
function ChangeNotesService.adminPreview(player: Player): (boolean, string)
	if player.Parent ~= Players then
		return false, "Player left"
	end
	Remotes.fireClient("ChangeNotesAdmin", player, { action = "preview" })
	return true, `What's New preview opened for {player.Name}`
end

-- Purchase-flow hint ----------------------------------------------------------------------------

-- Clears the player's purchase-flow hint.
local function clearPurchaseFlow(player: Player)
	holds[player] = nil
	if player:GetAttribute(PurchaseFlow.Attr) ~= nil then
		player:SetAttribute(PurchaseFlow.Attr, nil)
	end
end

-- One sweep thread while any hold exists: expired holds clear (a refused prompt never "finishes").
local function ensureSweep()
	if sweeping then
		return
	end
	sweeping = true
	task.spawn(function()
		while next(holds) ~= nil do
			task.wait(SWEEP_SECONDS)
			local now = os.clock()
			for player, deadline in holds do
				if now >= deadline or player.Parent ~= Players then
					clearPurchaseFlow(player)
				end
			end
		end
		sweeping = false
	end)
end

--[[
	Marks a purchase flow as open for `player` (see the module header, 3). Repeated requests only
	push the deadline (no thread per request). Exposed for tests.
]]
function ChangeNotesService.markPurchaseFlow(player: Player)
	if player.Parent ~= Players then
		return
	end
	holds[player] = os.clock() + PurchaseFlow.HoldSeconds
	player:SetAttribute(PurchaseFlow.Attr, os.time())
	ensureSweep()
end

--[[ Tests: the player's session counters (a copy) and whether a purchase hold is set. ]]
function ChangeNotesService.testState(player: Player): { reports: { [string]: number }, purchaseHold: boolean }
	local counted = reports[player]
	return {
		reports = if counted ~= nil then table.clone(counted) else {},
		purchaseHold = holds[player] ~= nil,
	}
end

function ChangeNotesService.Init() end

function ChangeNotesService.Start()
	if started then
		return
	end
	started = true
	-- Exact ids for the analytics kind "noteId" (AnalyticsConfig.Metrics retention "notes:*").
	AnalyticsService.registerIds("noteId", function(id: string): boolean
		return ChangeNotesConfig.get(id) ~= nil
	end)
	Remotes.onServerEvent(
		"ChangeNotesAction",
		function(player: Player, rawVerb: unknown, rawId: unknown, rawArg: unknown)
			ChangeNotesService.handleAction(player, rawVerb, rawId, rawArg)
		end
	)
	PlayerDataService.ProfileLoaded:Connect(function(player: Player, profile: Profile)
		ChangeNotesService.onProfileLoaded(player, profile)
	end)
	-- Profiles that loaded before this Start (Studio fast joins) get the same treatment once.
	for _, player in Players:GetPlayers() do
		local profile = PlayerDataService.getProfile(player)
		if profile ~= nil then
			ChangeNotesService.onProfileLoaded(player, profile)
		end
	end
	armReveal()

	-- Purchase-flow hint: an extra listener on each prompt-requesting remote (MonetizationService
	-- still validates and prompts; this only notes "a prompt may be on screen").
	for _, name in PURCHASE_REMOTES do
		Remotes.onServerEvent(name, function(player: Player)
			ChangeNotesService.markPurchaseFlow(player)
		end)
	end
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number)
		local player = Players:GetPlayerByUserId(userId)
		if player ~= nil then
			clearPurchaseFlow(player)
		end
	end)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player)
		clearPurchaseFlow(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		reports[player] = nil
		holds[player] = nil
		noContextAtLoad[player] = nil
		limiter:Forget(player)
	end)

	-- Owner admin commands (guarded: a missing AdminService registers nothing, never errors).
	ChangeNotesAdmin.install(ChangeNotesService)
end

return ChangeNotesService
