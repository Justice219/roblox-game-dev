--!strict
--[[
	Remotes — the single registry of every RemoteEvent in SellNukes.

	Purpose:
		All client↔server communication goes through remotes declared here, so the full network
		surface of the game is auditable in one file (build plan "Contracts → Remotes"). The
		server creates them once at boot (`Remotes.createAll()`, before any service Init); clients
		fetch them by typed name. A typo in a remote name is a type error (names are string-literal
		unions). There are NO RemoteFunctions: server→client invokes can hang a server thread
		forever, and client→server invokes are replaced by an event + a result event.

	Security reminders for every server handler (CLAUDE.md "Security rules"):
		- The first argument (Player) is authentic; every other argument is untrusted: type it as
		  `unknown` and narrow it with Shared/Net/Validate (type, finite, range, allowlist).
		- Clients send INTENTS only ("click producer 3", "buy pad X"), never amounts or results.
		- Rate-limit per player (Shared/Util/RateLimiter) and Forget the player on leave.
		- Connect with `Remotes.onServerEvent(name, handler)`: it drops events from a player who
		  already left, so a late packet can never re-create per-player state (limiter buckets,
		  request memories) after the PlayerRemoving cleanup forgot it.
		- Check the player's state (profile loaded, owns the plot, pad unlocked, in range, ...).

	Direction legend: C→S client to server, S→C server to client. Payload shapes are listed next to
	each name; the owning service documents the details.

	Server → client sends go through `Remotes.fireClient` / `fireAllClients` /
	`fireUnreliableClient` / `fireUnreliableAllClients` (not `Remotes.event(x):FireClient`). They
	fire exactly the same remote with the same arguments, then report (name, estimated bytes,
	recipients) to the optional send observer (`setSendObserver`, installed by the server health /
	analytics layer, spec §13) so a bandwidth spike can be traced to its remote. With no observer
	installed the report costs one nil check.

	Example (server):
		Remotes.onServerEvent("ProducerClick", function(player, rawId: unknown)
			local producerId = Validate.key(rawId, 32)
			if producerId == nil then return end
		end)
		Remotes.fireClient("Notify", player, { kind = "success", text = "Saved!" })
	Example (client):
		Remotes.event("ProducerClick"):FireServer("garage")
		Remotes.event("Notify").OnClientEvent:Connect(function(payload: unknown) ... end)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local WireSize = require(script.Parent.WireSize)

-- Name of the ReplicatedStorage folder that holds every remote.
local FOLDER_NAME = "Remotes"

-- Seconds a client waits for the folder / one remote to replicate before erroring.
local FOLDER_WAIT_SECONDS = 60
local REMOTE_WAIT_SECONDS = 30

export type EventName =
	-- Core: profile sync (Server/Services/PlayerDataService, Client/ProfileSyncClient) --------------
	"ProfileUpdate" -- S→C (snapshot: table, seq: number?) full owner snapshot (ProfileLogic.snapshot)
	| "ProfileDelta" -- S→C (delta: { v, seq, base, set, cleared }) changed top-level fields only
	| "ProfileDeltaAck" -- C→S (version: number) "I can apply deltas of this version" (rate-limited)
	| "ProfileResync" -- C→S () "my delta base is wrong, send a full snapshot" (rate-limited)
	-- Core: toasts, purchases, settings ---------------------------------------------------------------
	| "Notify" -- S→C ({ kind: string, text: string, icon: string? }) toast
	| "PromptProduct" -- C→S (productKey: string) prompt a developer product (MonetizationService)
	| "PromptPass" -- C→S (passKey: string) prompt a game pass (MonetizationService)
	| "PurchaseGranted" -- S→C ({ key: string, kind: string }) a product/pass grant is durable
	| "SetSetting" -- C→S (key: string, value: boolean) one settings toggle (ProfileLogic.applySetting)
	-- Tycoon (B5 server / B6 client) -------------------------------------------------------------------
	| "ProducerClick" -- C→S (producerId: string) run one manual cycle of an un-managed producer
	| "ProducerUpgrade" -- C→S (producerId: string, mode: "1" | "10" | "max") buy producer levels
	| "ProducerGemUpgrade" -- C→S (producerId: string) owner R86: buy ONE level for the flat gem price
	| "PadBuy" -- C→S (padId: string) buy the pad the player stands on (server re-checks distance)
	| "RenameStand" -- C→S (text: string) rename the stand sign (filtered with TextService)
	-- C→S (text: string) owner R88: name the plot's entrance sign in every world ("" = reset to the
	-- default "<DisplayName>'s Nukes"); Tycoon/PlotNames: PlotNameLogic.parse, RateLimiter, owns a
	-- plot, TextService broadcast filter (censored names refused), re-checked after the yield
	| "RenamePlot"
	| "TeleportArea" -- C→S (areaIndex: number) teleport to an unlocked area of the own plot
	| "TeleportHub" -- C→S () teleport to the hub
	-- C→S (plotIndex: number) teleport to plot N's entrance; own plot free, other players' plots
	-- need the Teleporter pass (B5 PlotService: validated, rate limited, 5 s cooldown)
	| "TeleportPlot"
	-- C→S (worldId: string?) rebirth that world's run (only after its finale). nil = "main" (old
	-- clients unchanged); anything else must pass Validate.worldIdOrMain (R57 World 2)
	| "Rebirth"
	-- C→S (upgradeKey: string, worldId: string?) buy a rebirth shop upgrade of that world with its
	-- tokens (main: Rebirth Tokens, dino: Amber); validated with Validate.rebirthShopBuy against
	-- THAT world's rebirth.Shop (per-world allowlist; R57)
	| "RebirthShopBuy"
	-- S→C ({ amount: number, seconds: number, rate: number, worlds: { { id: string, amount: number } }? })
	-- welcome back; `worlds` (R57) lists every other world's non-zero payout (display only)
	| "OfflineEarnings"
	| "TutorialState" -- S→C ({ step: number }) tutorial objective chip / arrow
	-- C→S () the client's plot-reveal intro finished or was skipped; the server ends the caller's
	-- PENDING reveal early (B5 PlotService; rate-limited; the server ends it itself after 3 s)
	| "PlotRevealDone"
	-- Worlds (owner R57 World 2, Server/Tycoon/WorldService, Client/Worlds/WorldClient) ----------------
	-- C→S (worldId: string, target: "spawn" | "area" | "plot", index: number?, source: string?) travel
	-- intent. `source` is analytics-only (allowlisted by WorldService, anything else → "menu"). Parsed by
	-- Validate.travelRequest (known world, allowlisted target, index: area 1..that world's area
	-- count, plot 1..PlotCount, nil for spawn); then RateLimiter + cooldown + one travel in flight +
	-- unlock / enabled / alive / plot checks. The destination CFrame is computed server-side only.
	| "TravelWorld"
	-- S→C ({ worldId: string, phase: "out" | "in" | "fail", reason: string?, at: number }) travel
	-- overlay / failure toast (cosmetic only; `at` = server time)
	| "WorldTravel"
	-- Retention (B7) -------------------------------------------------------------------------------------
	| "ClaimDaily" -- C→S () claim today's daily reward
	| "ClaimTimeReward" -- C→S (index: number) claim a playtime gift
	-- Owner R89 gift ladder (Server/Services/PlaytimeService, Retention/FavoritePrompt):
	| "ClaimTimeRewardsAll" -- C→S () open every gift that is ready today (one step, one toast)
	-- S→C ({ moment: "gift" | "rebirth" }) a happy moment: the client may show the one-time
	-- experience favorite prompt when calm (never rewarded; the server gates it)
	| "FavoriteMoment"
	-- C→S (report: "shown" | "Success" | "PermissionDenied" | "Failed") the favorite dialog was
	-- shown / answered (allowlisted, rate-limited, accepted only after an announced moment)
	| "FavoriteReport"
	| "SpinWheel" -- C→S (requestId: number) spin the Lucky Wheel
	| "SpinResult" -- S→C ({ requestId, slice, reward, ... }) the server-rolled spin
	| "RedeemCode" -- C→S (text: string) redeem a code
	| "CodeResult" -- S→C ({ ok: boolean, text: string }) redeem outcome
	| "ClaimGroupReward" -- C→S () claim the group reward (IsInGroup re-checked)
	| "GroupRewardResult" -- S→C ({ ok: boolean, text: string }) group claim outcome
	| "ClaimNotifyReward" -- C→S () claim the notifications opt-in reward
	-- WHAT'S NEW change notes (owner R58; Server/Services/ChangeNotesService, docs/change-notes.md):
	-- C→S (verb, noteId, arg?) verb ∈ ChangeNotesConfig.Actions: "seen" (moves profile.notes.seen
	-- FORWARD only), "shown" (arg = source "auto" | "menu"), "cta", "closed" (arg = seconds open,
	-- clamped; analytics only). Known, visible note ids only; rate-limited; nothing is granted.
	| "ChangeNotesAction"
	-- S→C ({ action: "preview" | "replay" }) owner admin only (ChangeNotesAdmin): open the panel in
	-- preview mode (hidden notes too, nothing marked / counted) or replay the returning-player
	-- auto pop-up after a seen reset.
	| "ChangeNotesAdmin"
	-- Pets / eggs / crates (B9) -------------------------------------------------------------------------
	| "HatchEgg" -- C→S (eggId: string, count: number, requestId: number) hatch eggs
	| "HatchResult" -- S→C ({ requestId, pets, ... }) server-rolled hatch results
	| "EquipPet" -- C→S (uid: string, on: boolean) equip / unequip one pet
	| "DeletePets" -- C→S (uids: { string }) delete pets (bounded list)
	| "EquipBest" -- C→S () equip the best pets
	| "OpenCrate" -- C→S (crateId: string, requestId: number) open a Supply Crate
	| "CrateResult" -- S→C ({ requestId, rewards, ... }) server-rolled crate result
	| "LockPets" -- C→S (uids: { string }, locked: boolean) lock / unlock pets (bounded list)
	| "EquipTrail" -- C→S (trailId: string) equip an owned trail ("" = unequip)
	| "PetIndexClaim" -- C→S (milestone: number 1..7) claim a Pet Index milestone (R78, PetService)
	-- Attack mode (B10) ---------------------------------------------------------------------------------
	| "AttackLaunch" -- C→S (targetUserId: number) launch a nuke at another plot
	| "NukeFlight" -- S→C all ({ id, fromUserId, toUserId, t0, flight, intercepted, interceptAt })
	| "DefenseUpgrade" -- C→S (kind: string, toLevel: number?) upgrade the HQ AA tower / launcher
	-- C→S (slot: number, toLevel: number) owner R80: buy (toLevel 1) / upgrade a defence tower slot
	| "DefenseTower"
	| "ShieldActivate" -- C→S () activate an owned shield
	-- C→S (slot: number) owner R104: the picker frames target slot `slot` (0 = closed); the server
	-- streams it in with a replication focus (Server/Attack/PickerFocus, PickerStream.readSlot)
	| "AttackPickerFocus"
	-- Area knockdown (owner R50, Server/Tycoon/Knockdown) ---------------------------------------------
	| "KnockdownTap" -- C→S (areaIndex: number) "TAP TO REBUILD!" on one of your own knocked-down areas
	| "KnockdownState" -- S→C ({ areas = { { area, untilTime, appliedAt, label } }, immuneUntil })
	-- Harvest Feast event (B11) -------------------------------------------------------------------------
	| "EventCollect" -- C→S (turkeyId: string) tap a Golden Turkey
	| "EventRedeemSheet" -- C→S () redeem a completed Feast Sticker Sheet
	| "EventState" -- S→C ({ ... }) event window / turkeys / sheet state
	-- C→S (itemKey: string) buy a Harvest Shop item (decoration / boost) with acorns (B11; the server
	-- validates with Validate.configKey against EventConfig.ShopByKey)
	| "EventShopBuy"
	-- Lucky Buttons (owner R69, Server/Services/LuckyButtonService) ---------------------------------
	-- S→C ({ kind = "spawn" | "claimed" | "expired" | "clear", button?, id?, amount?, currency? })
	-- the player's OWN buttons (spawn wire = LuckyButtonLogic.Wire)
	| "LuckyButtons"
	-- C→S (id: string) walked into a button: free = grant, paid = purchase prompt (server checks
	-- owner, world, expiry, distance; Validate.key + RateLimiter)
	| "LuckyButtonClaim"
	-- Quests (R78, Server/Services/QuestService) ------------------------------------------------------
	-- C→S (kind: "starter" | "daily" | "chest" | "trophy", id: number | string?) claim a completed
	-- starter goal (1..12) / finished mission (1..3) / the Daily Chest / a trophy's next tier
	-- (QuestLogic.readClaim; RateLimiter; idempotent claim flag + reward in one step)
	| "QuestClaim"
	-- C→S (slot: number 1..3) today's one free reroll of an unfinished mission
	| "QuestReroll"
	-- Nuke Pass (R78, Server/Services/PassService) -------------------------------------------------
	-- C→S (track: "free" | "premium" | "overflow", tier: number 1..30; overflow: 0 = every earned
	-- bonus chest) claim one reached tier (server checks the season, reached, unclaimed, premium
	-- owned; RateLimiter; idempotent)
	| "PassClaim"
	-- C→S () CLAIM ALL: every reached, unclaimed tier of both tracks + the earned bonus chests
	| "PassClaimAll"
	-- Rush + Friends (R78, Server/Services/{RushService, FriendService}) ------------------------------
	-- S→C ({ kind = "friends", count, percent, names } | { kind = "comeback", away, seconds,
	-- multiplier }) the player's Friend Boost state / a fresh Comeback Rush (Welcome Back screen)
	| "Social"
	-- C→S (action: string, recipients: number?) invite prompt analytics ONLY (the prompt itself is
	-- client-side SocialService; allowlisted action, clamped count, RateLimiter; grants nothing)
	| "FriendInvite"
	-- Surprise Batches + Flavour Book + Big Pop (owner R89, Server/Tycoon/FlavorService) -----------
	-- C→S (key: "<world>:<flavor>" | "all") claim a Flavour Book discovery reward (FlavorLogic
	-- .parseKey allowlist, RateLimiter, profile writable, found + unclaimed; idempotent)
	| "FlavorClaim"
	-- C→S () owner R112: the one-time "what are Lucky Nukes?" tip card was dismissed (sets
	-- profile.flavors.tip; RateLimiter; idempotent; carries no data)
	| "FlavorTipSeen"
	-- S→C ({ producerId, flavor, worldId, oneIn, mult, amount }) owner only: a Galaxy+ batch just
	-- popped on your producer (the reveal; client-throttled, never over a menu / the tutorial)
	| "FlavorHighlight"
	-- S→C all ({ entries = { { userId, name, kind, id, label, oneIn, rank, at } }, more }) a
	-- server-wide Big Pop: Galaxy+ batch / Mythic+ hatch / rebirth (globally throttled + coalesced;
	-- display names only — clients build the text from these fields)
	| "BigPop"
	-- Nukey's Happy Hours (owner R89, Server/Services/HappyHourService + HappyHour/HappyHourPickups) ---
	-- S→C ({ kind = "spawn", pickup } | { kind = "claimed", id, amount, currency, gems, golden } |
	-- { kind = "gone", id } | { kind = "clear" }) the player's OWN event pickups (Confetti Storm coins,
	-- Egg Stampede eggs, Low-Gravity moon rocks; wire = HappyHourPickupLogic.Wire)
	| "HappyHour"
	-- C→S (id: string) walked into an own pickup (server checks owner, live event, world, alive,
	-- cooldown, distance to the pickup's server-side pose; Validate.key + RateLimiter)
	| "HappyHourCollect"
	-- Mega Lever + Tip Jar (owner R90, Server/Kinetic/KineticService) --------------------------------
	-- C→S (action: "pull" | "collect") pull the own Mega Lever / empty the own Tip Jar in the world
	-- the player stands in (Validate.oneOf allowlist, RateLimiter; owner, unlock, reach, cooldown
	-- and every amount are decided on the server; walking into the jar is a server Touched)
	| "KineticAction"
	-- S→C (KineticLogic.Wire) owner only: { kind = "pull", world, total, currency, readyAt, cycles }
	-- a Mega Batch paid / { kind = "collect", world, amount, currency } tips paid out /
	-- { kind = "tip", world, amount, currency } bonus coins dropped into the jar (TipJar.addCoins;
	-- no caller since owner R128 removed the Order Window, whose big tips used it)
	| "Kinetic"
	-- Analytics (B13, spec §13) ---------------------------------------------------------------------
	| "FunnelStep" -- C→S (stepId: string, payload: table?) a client-only funnel step (allowlisted)
	| "OffersSeen" -- C→S ({ offerId }) offers that actually rendered (offer shown → click funnel)
	| "ClientDevice" -- C→S (info: table) device class / platform / input (once per session)
	| "ClientPerf" -- C→S (report: table) packed client perf report (frame time, memory, ping)
	| "AnalyticsRequest" -- C→S (requestId: number, range: table) admin: dashboard data request
	| "AnalyticsReport" -- S→C (requestId: number, report: table) admin: dashboard data
	| "AnalyticsRawRequest" -- C→S (requestId: number, page: number) admin: raw export page request
	| "AnalyticsRawPage" -- S→C (requestId: number, page: table) admin: one raw export page
	-- Owner admin panel (B14, spec §14) ----------------------------------------------------------------
	| "AdminCommand" -- C→S (name: string, args: table) one admin command (re-authorised every call)
	| "AdminResult" -- S→C ({ ok: boolean, name: string, text: string, data: table? }) command result
	| "AdminState" -- S→C (state: table) admin-only panel state (sent to admins only)

export type UnreliableName =
	"IncomePop" -- S→C ({ producerId: string, amount: number }) "+$X" pop over a producer
	-- S→C ({ producerId, flavor, count, amount, worldId }) owner R89 (+ R120 amount / worldId for the
	-- feed pills): a flavoured batch on your producer (the pop tint
	-- + flavour word + sparkle; the best flavour of that producer per server flush, owner only)
	| "FlavorPop"
	-- S→C ({ anchor: BasePart, flavor }) owner R89: a Rainbow+ batch — glow that producer's anchor
	-- for a few seconds (players in that world; per-producer server cooldown)
	| "FlavorGlow"

local EVENT_NAMES: { EventName } = {
	"ProfileUpdate",
	"ProfileDelta",
	"ProfileDeltaAck",
	"ProfileResync",
	"Notify",
	"PromptProduct",
	"PromptPass",
	"PurchaseGranted",
	"SetSetting",
	"ProducerClick",
	"ProducerUpgrade",
	"ProducerGemUpgrade", -- owner R86
	"PadBuy",
	"RenameStand",
	"RenamePlot", -- owner R88
	"TeleportArea",
	"TeleportHub",
	"TeleportPlot",
	"Rebirth",
	"RebirthShopBuy",
	"OfflineEarnings",
	"TutorialState",
	"PlotRevealDone",
	"TravelWorld",
	"WorldTravel",
	"ClaimDaily",
	"ClaimTimeReward",
	"ClaimTimeRewardsAll", -- owner R89
	"FavoriteMoment", -- owner R89
	"FavoriteReport", -- owner R89
	"SpinWheel",
	"SpinResult",
	"RedeemCode",
	"CodeResult",
	"ClaimGroupReward",
	"GroupRewardResult",
	"ClaimNotifyReward",
	"ChangeNotesAction",
	"ChangeNotesAdmin",
	"HatchEgg",
	"HatchResult",
	"EquipPet",
	"DeletePets",
	"EquipBest",
	"OpenCrate",
	"CrateResult",
	"LockPets",
	"EquipTrail",
	"PetIndexClaim",
	"AttackLaunch",
	"NukeFlight",
	"DefenseUpgrade",
	"DefenseTower",
	"ShieldActivate",
	"AttackPickerFocus", -- owner R104
	"KnockdownTap",
	"KnockdownState",
	"EventCollect",
	"EventRedeemSheet",
	"EventState",
	"EventShopBuy",
	"LuckyButtons",
	"LuckyButtonClaim",
	"QuestClaim",
	"QuestReroll",
	"PassClaim",
	"PassClaimAll",
	"Social",
	"FriendInvite",
	"FlavorClaim", -- owner R89
	"FlavorTipSeen", -- owner R112
	"FlavorHighlight", -- owner R89
	"BigPop", -- owner R89
	"HappyHour", -- owner R89 Happy Hours
	"HappyHourCollect", -- owner R89 Happy Hours
	"KineticAction", -- owner R90 Mega Lever + Tip Jar
	"Kinetic", -- owner R90 Mega Lever + Tip Jar
	"FunnelStep",
	"OffersSeen",
	"ClientDevice",
	"ClientPerf",
	"AnalyticsRequest",
	"AnalyticsReport",
	"AnalyticsRawRequest",
	"AnalyticsRawPage",
	"AdminCommand",
	"AdminResult",
	"AdminState",
}

local UNRELIABLE_NAMES: { UnreliableName } = {
	"IncomePop",
	"FlavorPop", -- owner R89
	"FlavorGlow", -- owner R89
}

local Remotes = {}

local folderCache: Folder? = nil
local eventCache: { [string]: RemoteEvent } = {}
local unreliableCache: { [string]: UnreliableRemoteEvent } = {}

--[[
	Server only: creates the Remotes folder and every remote. Idempotent (a second call reuses the
	existing folder). The folder is parented LAST so clients receive it complete in one step.
	Example: Remotes.createAll() -- first line of the server bootstrap
]]
function Remotes.createAll()
	assert(RunService:IsServer(), "Remotes.createAll is server-only")
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if folder == nil then
		local newFolder = Instance.new("Folder")
		newFolder.Name = FOLDER_NAME
		for _, name in EVENT_NAMES do
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = newFolder
		end
		for _, name in UNRELIABLE_NAMES do
			local remote = Instance.new("UnreliableRemoteEvent")
			remote.Name = name
			remote.Parent = newFolder
		end
		newFolder.Parent = ReplicatedStorage
		folder = newFolder
	end
	assert(folder ~= nil and folder:IsA("Folder"), "Remotes folder")
	folderCache = folder
end

-- The Remotes folder (cached; yields on the client until it replicates).
local function getFolder(): Folder
	local cached = folderCache
	if cached ~= nil then
		return cached
	end
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, FOLDER_WAIT_SECONDS)
	if folder == nil or not folder:IsA("Folder") then
		error(`[Remotes] Remotes folder did not replicate within {FOLDER_WAIT_SECONDS} seconds`)
	end
	folderCache = folder
	return folder
end

--[[
	Returns a reliable RemoteEvent by name (yields on the client until it replicates; cached).
	Example: Remotes.event("PadBuy"):FireServer(padId)
]]
function Remotes.event(name: EventName): RemoteEvent
	local cached = eventCache[name]
	if cached ~= nil then
		return cached
	end
	local remote = getFolder():WaitForChild(name, REMOTE_WAIT_SECONDS)
	if remote == nil or not remote:IsA("RemoteEvent") then
		error(`[Remotes] missing RemoteEvent {name}`)
	end
	eventCache[name] = remote
	return remote
end

--[[
	Wraps a C→S handler so it only runs for a player who is still in the game (Player.Parent is
	the Players service). Events can still be delivered after PlayerRemoving fired; running the
	handler then would re-create per-player state the leave cleanup already forgot (a slow leak
	keyed by a departed Player) or act for someone who is gone. Pure (the presence test is the
	only thing it adds); onServerEvent uses it, tests call it directly.
	Example: local guarded = Remotes.fromPresentPlayer(function(player, raw) ... end)
]]
function Remotes.fromPresentPlayer<A...>(handler: (player: Player, A...) -> ()): (player: Player, A...) -> ()
	local players = game:GetService("Players")
	return function(player: Player, ...: A...)
		-- (OnServerEvent's first argument is always the authentic sender, so only presence is checked.)
		if player.Parent ~= players then
			return
		end
		handler(player, ...)
	end
end

--[[
	Server only: connects `handler(player, ...)` to a C→S RemoteEvent through fromPresentPlayer
	(see above). Every server handler connects this way (security audit 2026-10-30).
	@return the connection
	Example: Remotes.onServerEvent("PadBuy", function(player, rawPadId: unknown) ... end)
]]
function Remotes.onServerEvent<A...>(name: EventName, handler: (player: Player, A...) -> ()): RBXScriptConnection
	assert(RunService:IsServer(), "Remotes.onServerEvent is server-only")
	return Remotes.event(name).OnServerEvent:Connect(Remotes.fromPresentPlayer(handler) :: any)
end

--[[
	Returns an UnreliableRemoteEvent by name (yields on the client until it replicates; cached).
	Unreliable = may be dropped or reordered; only for cosmetic, high-frequency sends (IncomePop).
]]
function Remotes.unreliable(name: UnreliableName): UnreliableRemoteEvent
	local cached = unreliableCache[name]
	if cached ~= nil then
		return cached
	end
	local remote = getFolder():WaitForChild(name, REMOTE_WAIT_SECONDS)
	if remote == nil or not remote:IsA("UnreliableRemoteEvent") then
		error(`[Remotes] missing UnreliableRemoteEvent {name}`)
	end
	unreliableCache[name] = remote
	return remote
end

--[[
	Observer of every server→client send made through the helpers below.
		name: the remote's name (EventName or UnreliableName)
		bytes: WireSize.ofArgs estimate of ONE copy of the payload (EventOverhead included)
		recipients: 1 for a single player; Remotes.AllClients (-1) for FireAllClients, which the
		            observer resolves to its live player count
]]
export type SendObserver = (name: string, bytes: number, recipients: number) -> ()

-- `recipients` value meaning "every connected client" (see SendObserver).
local ALL_CLIENTS = -1
Remotes.AllClients = ALL_CLIENTS

local sendObserver: SendObserver? = nil

--[[
	Server only: installs (or, with nil, removes) the send observer. Measurement only; it never
	changes what is sent.
	Example: Remotes.setSendObserver(function(name, bytes, recipients) ... end)
]]
function Remotes.setSendObserver(observer: SendObserver?)
	assert(RunService:IsServer(), "Remotes.setSendObserver is server-only")
	sendObserver = observer
end

-- Measures one send and hands it to the observer (always called under pcall, see observe).
local function report(observer: SendObserver, name: string, recipients: number, ...: any)
	observer(name, WireSize.ofArgs(...), recipients)
end

local reportFailed = false

--[[
	Reports one completed send to the observer, if any. Runs under pcall so a telemetry bug can
	never turn into an error at a gameplay call site (the send already happened); the first
	failure is warned once.
]]
local function observe(name: string, recipients: number, ...: any)
	local observer = sendObserver
	if observer == nil then
		return
	end
	local ok, err = pcall(report, observer, name, recipients, ...)
	if not ok and not reportFailed then
		reportFailed = true
		warn(`[Remotes] send observer failed (reported once): {err}`)
	end
end

--[[
	Reliable server→client fire to one player, then the observer report. Varargs are forwarded
	verbatim to RemoteEvent:FireClient (each remote's payload is documented in EventName).
	Example: Remotes.fireClient("Notify", player, { kind = "success", text = "Saved!" })
]]
function Remotes.fireClient(name: EventName, player: Player, ...: any)
	Remotes.event(name):FireClient(player, ...)
	observe(name, 1, ...)
end

--[[
	Reliable server→client fire to every client, then the observer report.
	Example: Remotes.fireAllClients("NukeFlight", flight)
]]
function Remotes.fireAllClients(name: EventName, ...: any)
	Remotes.event(name):FireAllClients(...)
	observe(name, ALL_CLIENTS, ...)
end

--[[
	Unreliable server→client fire to one player, then the observer report.
	Example: Remotes.fireUnreliableClient("IncomePop", player, { producerId = "garage", amount = 25 })
]]
function Remotes.fireUnreliableClient(name: UnreliableName, player: Player, ...: any)
	Remotes.unreliable(name):FireClient(player, ...)
	observe(name, 1, ...)
end

--[[ Unreliable server→client fire to every client, then the observer report. ]]
function Remotes.fireUnreliableAllClients(name: UnreliableName, ...: any)
	Remotes.unreliable(name):FireAllClients(...)
	observe(name, ALL_CLIENTS, ...)
end

-- Frozen name lists (tests assert every name is unique and every plan remote is declared).
Remotes.EventNames = table.freeze(EVENT_NAMES)
Remotes.UnreliableNames = table.freeze(UNRELIABLE_NAMES)
Remotes.FolderName = FOLDER_NAME

return table.freeze(Remotes)
