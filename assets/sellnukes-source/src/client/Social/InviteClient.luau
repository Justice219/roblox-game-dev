--!strict
--[[
	InviteClient — the client runtime of the owner R122 co-play surfaces (spec §2.4): the HUD
	INVITE button (UI/Hud/HudInvite) and the once-per-session invite moment card
	(UI/Screens/InviteMoment). Rules: Client/Social/InviteLogic (pure); tunables:
	Shared/Config/InviteConfig.

	What it does:
		Availability  asks SocialService:CanSendGameInviteAsync once at start (InviteConfig.
		              Availability: a few attempts, then a slow re-check), and again whenever the
		              invite flow reports "unavailable". `available()` + `Changed` drive the HUD
		              button's visibility: hidden while unknown / refused (never a dead button).
		Invite        `invite(surface)` counts the surface's report (friends:hud:tap /
		              friends:moment:invite) and opens Roblox's invite prompt through the existing
		              R78 flow (Social/SocialClient.invite: PromptGameInvite + the server-counted
		              friends:invite:<outcome>). Referrals ride Roblox's own invite join data
		              (Server/Services/FriendService).
		Moment        watches the player's main-world progress (ClientState profile: area MinArea
		              unlocked, or rebirths > 0). Once eligible it arms ONE delayed task for the due
		              time (InviteLogic.momentDueAt); when it fires and the gate passes (invites
		              available, no friend here, no tutorial step) it asks PopupQueue's centre lane
		              for a low-priority "inviteMoment" feed card (waits behind reveals / banners,
		              never over a menu or a cinematic). Gate refused / lane busy → retry after
		              Moment.RetrySeconds. Shown → never again this session.
		Reports       `report(action)` sends an allowlisted surface report on the FriendInvite remote
		              (analytics only; FriendService caps each per session). "shown" reports are
		              also de-duplicated here (once per session).

	Studio QA only (ignored on live servers; for the lead's capture_device_matrix pass): the
	LocalPlayer attribute DevInviteAvailable = true forces the HUD button on (Studio may refuse
	CanSendGameInviteAsync), and DevInviteMoment = true shows the moment card now (once per set).

	Security: presentation + analytics intents only. Nothing is granted from these reports; the
	invite prompt is Roblox's own UI.

	Performance: one availability task (sleeps between checks), one delayed moment task at a time,
	ClientState / SocialClient change events; no per-frame work.

	Connects to: Client/{ClientState, Social/SocialClient, Social/InviteLogic}, UI/{ScreenManager,
	Widgets/PopupQueue}, Tycoon/Tutorial (lazy, at gate time: it requires the HUD), Shared/Config/
	{InviteConfig, SocialConfig}, Shared/Net/Remotes ("FriendInvite"), Shared/Tycoon/TycoonLogic.

	Example:
		InviteClient.start()
		if InviteClient.available() then InviteClient.invite("hud") end
		InviteClient.Changed:Connect(function() print(InviteClient.available()) end)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")

local ClientState = require(script.Parent.Parent.ClientState)
local InviteConfig = require(ReplicatedStorage.Shared.Config.InviteConfig)
local InviteLogic = require(script.Parent.InviteLogic)
local PopupQueue = require(script.Parent.Parent.UI.Widgets.PopupQueue)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SocialClient = require(script.Parent.SocialClient)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)

export type Surface = "hud" | "moment"

local InviteClient = {}

-- Fires () when availability or the Friend Boost sticker inputs change (HudInvite re-renders).
InviteClient.Changed = Signal.new() :: Signal.Signal<>

local MOMENT_SCREEN = "InviteMoment"
-- Studio QA attributes on the LocalPlayer (ignored outside Studio).
local DEV_AVAILABLE = "DevInviteAvailable"
local DEV_MOMENT = "DevInviteMoment"
local Moment = InviteConfig.Moment
local Availability = InviteConfig.Availability

local started = false
local canSend: boolean? = nil -- nil = not known yet
local checking = false
local moment = InviteLogic.newMoment(os.clock())
local profileSeen = false
local momentToken = 0 -- invalidates a pending delayed moment task
local momentHandle: PopupQueue.Handle? = nil
local momentRequested = false
-- Studio QA (DevInviteMoment): the next request skips the friends / tutorial / availability gate.
local forceNext = false
-- "shown" reports already sent this session (client-side de-duplication; the server caps too).
local reported: { [string]: boolean } = {}
-- Session counters (QA: InviteClient.stats()).
local counters: { [string]: number } = { checks = 0, invites = 0, moments = 0, gateRefused = 0 }

-- ── Availability ─────────────────────────────────────────────────────────────────────────────

-- Sets the cached answer and fires Changed on a change.
local function setCanSend(value: boolean?)
	if canSend ~= value then
		canSend = value
		InviteClient.Changed:Fire()
	end
end

-- Asks Roblox (yields; pcall): true / false, or nil when the web call failed.
local function ask(): boolean?
	counters.checks += 1
	local ok, result = pcall(function(): boolean
		return SocialService:CanSendGameInviteAsync(Players.LocalPlayer)
	end)
	if not ok or type(result) ~= "boolean" then
		return nil
	end
	return result
end

-- One availability check with retries (never two at once).
local function check()
	if checking then
		return
	end
	checking = true
	task.spawn(function()
		for attempt = 1, Availability.Attempts do
			local answer = ask()
			if answer ~= nil then
				setCanSend(answer)
				break
			end
			if attempt < Availability.Attempts then
				task.wait(Availability.RetrySeconds)
			end
		end
		checking = false
	end)
end

-- Studio QA: the DevInviteAvailable attribute forces availability (never on a live server).
local function devAvailable(): boolean
	return RunService:IsStudio() and Players.LocalPlayer:GetAttribute(DEV_AVAILABLE) == true
end

--[[ True while the HUD INVITE button / moment may show (InviteLogic.available). ]]
function InviteClient.available(): boolean
	return InviteLogic.available(canSend) or devAvailable()
end

--[[ The "+10%" sticker text from the live Friend Boost settings (nil while the boost is off). ]]
function InviteClient.badgeText(): string?
	local live = SocialClient.live()
	return InviteLogic.badgeText({ friendsOn = live.friendsOn, friendPercent = live.friendPercent })
end

--[[ The live Friend Boost percent per friend (0 while the boost is off). ]]
function InviteClient.percent(): number
	local live = SocialClient.live()
	return if live.friendsOn then live.friendPercent else 0
end

-- ── Reports + invite ─────────────────────────────────────────────────────────────────────────

--[[
	Sends one surface report (InviteConfig.Reports) to the server's FriendInvite remote. "…:shown"
	reports go once per session.
	Example: InviteClient.report("hud:shown")
]]
function InviteClient.report(action: string)
	if table.find(InviteConfig.Reports, action) == nil then
		return
	end
	if string.sub(action, -6) == ":shown" then
		if reported[action] then
			return
		end
		reported[action] = true
	end
	Remotes.event("FriendInvite"):FireServer(action)
end

--[[
	Opens Roblox's invite prompt from a surface (counts friends:<surface>:tap / :invite first).
	@return false when a prompt is already open or invites are unavailable
	Example: InviteClient.invite("hud")
]]
function InviteClient.invite(surface: Surface): boolean
	if not InviteClient.available() then
		return false
	end
	InviteClient.report(if surface == "hud" then "hud:tap" else "moment:invite")
	counters.invites += 1
	return SocialClient.invite()
end

-- ── The once-per-session moment ──────────────────────────────────────────────────────────────

-- True when the main world's area MinArea is unlocked (or the player rebirthed: they did before).
local function eligibleIn(profile: any): boolean
	if type(profile) ~= "table" then
		return false
	end
	local rebirths = profile.rebirths
	if type(rebirths) == "number" and rebirths > 0 then
		return true
	end
	local tycoon = profile.tycoon
	if type(tycoon) ~= "table" then
		return false
	end
	local ok, unlocked = pcall(TycoonLogic.areaUnlocked, tycoon, Moment.MinArea)
	return ok and unlocked == true
end

-- True while a tutorial step runs (lazy require: Tycoon/Tutorial requires the HUD, which
-- requires this module through HudInvite; by gate time every module has loaded).
local function tutorialRunning(): boolean
	local client = script.Parent.Parent
	local ok, step = pcall(function(): number
		local Tutorial = require(client.Tycoon.Tutorial) :: any
		return Tutorial.step()
	end)
	return ok and type(step) == "number" and step > 0
end

local scheduleMoment: () -> ()

-- The card closed (any reason): free the lane.
local function finishMoment()
	local handle = momentHandle
	momentHandle = nil
	momentRequested = false
	if handle ~= nil then
		handle.done()
	end
end

-- Asks the centre lane for the card (presenter-driven: the screen ends it).
local function requestMoment()
	if momentRequested or moment.shown then
		return
	end
	local forced = forceNext
	forceNext = false
	local ok, refusal = InviteLogic.momentGate(moment, {
		available = forced or InviteClient.available(),
		friendsHere = if forced then 0 else SocialClient.friends().count,
		tutorial = not forced and tutorialRunning(),
	})
	if not ok then
		counters.gateRefused += 1
		if refusal ~= "shown" then
			-- Try again later this session (a friend may leave, the tutorial may end).
			momentToken += 1
			local token = momentToken
			task.delay(Moment.RetrySeconds, function()
				if token == momentToken then
					requestMoment()
				end
			end)
		end
		return
	end
	momentRequested = true
	local handle = PopupQueue.request({
		kind = "inviteMoment",
		maxShow = Moment.ShowSeconds + 2,
		show = function(): boolean
			if moment.shown then
				return false
			end
			ScreenManager.open(MOMENT_SCREEN, { percent = InviteClient.percent() })
			local opened = ScreenManager.isOpen(MOMENT_SCREEN)
			if opened then
				InviteLogic.markShown(moment)
				counters.moments += 1
				InviteClient.report("moment:shown")
			end
			return opened
		end,
		hide = function(_reason: string)
			momentHandle = nil
			momentRequested = false
			ScreenManager.close(MOMENT_SCREEN)
		end,
		onExpire = function()
			-- The lane stayed busy past maxWait: retry later (still once per session).
			momentRequested = false
			momentHandle = nil
			momentToken += 1
			local token = momentToken
			task.delay(Moment.RetrySeconds, function()
				if token == momentToken then
					requestMoment()
				end
			end)
		end,
	})
	if handle == nil then
		-- Dropped at once (presenter refused) — retry later unless it already showed.
		momentRequested = false
		if not moment.shown then
			momentToken += 1
			local token = momentToken
			task.delay(Moment.RetrySeconds, function()
				if token == momentToken then
					requestMoment()
				end
			end)
		end
		return
	end
	if moment.shown and not ScreenManager.isOpen(MOMENT_SCREEN) then
		-- Shown and already closed within the request (cannot normally happen): free the lane.
		handle.done()
		momentRequested = false
		return
	end
	momentHandle = handle
end

-- Arms ONE delayed task for the moment's due time (replacing any earlier one).
scheduleMoment = function()
	local due = InviteLogic.momentDueAt(moment)
	if due == nil then
		return
	end
	momentToken += 1
	local token = momentToken
	task.delay(math.max(0, due - os.clock()), function()
		if token == momentToken then
			requestMoment()
		end
	end)
end

-- Reads the progress from a profile push (first push = "at join").
local function onProfile(profile: any, fields: { string }?)
	if fields ~= nil and table.find(fields, "tycoon") == nil and table.find(fields, "rebirths") == nil then
		return
	end
	local atJoin = not profileSeen
	profileSeen = true
	local before = moment.eligibleAt
	InviteLogic.noteProgress(moment, eligibleIn(profile), os.clock(), atJoin)
	if before == nil and moment.eligibleAt ~= nil then
		scheduleMoment()
	end
end

--[[
	The moment card closed (INVITE, LATER, timeout or a hide): frees the popup lane. Called by
	UI/Screens/InviteMoment's onClose.
]]
function InviteClient.momentClosed()
	finishMoment()
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────────────────────

--[[
	Starts availability checks, the moment watcher and the change relays (idempotent; HudInvite
	calls it when the HUD builds).
]]
function InviteClient.start()
	if started then
		return
	end
	started = true
	moment = InviteLogic.newMoment(os.clock())
	check()
	-- Slow re-check (settings can change during a long session).
	task.spawn(function()
		while true do
			task.wait(Availability.RecheckSeconds)
			check()
		end
	end)
	-- The invite flow found invites unavailable: hide until Roblox says otherwise.
	SocialClient.InviteResult:Connect(function(action: string)
		if action == "unavailable" then
			setCanSend(false)
		end
	end)
	-- Friend Boost settings (admin percent / switch) change the sticker.
	SocialClient.Changed:Connect(function()
		InviteClient.Changed:Fire()
	end)
	ClientState.ProfileChanged:Connect(onProfile)
	local profile = ClientState.profile
	if profile ~= nil then
		onProfile(profile, nil)
	end
	-- Studio QA hooks (device-matrix captures): never active on a live server.
	if RunService:IsStudio() then
		local localPlayer = Players.LocalPlayer
		localPlayer:GetAttributeChangedSignal(DEV_AVAILABLE):Connect(function()
			InviteClient.Changed:Fire()
		end)
		localPlayer:GetAttributeChangedSignal(DEV_MOMENT):Connect(function()
			if localPlayer:GetAttribute(DEV_MOMENT) == true then
				moment.shown = false
				momentRequested = false
				InviteLogic.noteProgress(moment, true, os.clock(), true)
				forceNext = true
				requestMoment()
			end
		end)
	end
end

--[[ A copy of this session's counters (QA): checks, invites, moments, gateRefused. ]]
function InviteClient.stats(): { [string]: number }
	local copy = table.clone(counters)
	copy.canSend = if canSend == true then 1 elseif canSend == false then 0 else -1
	copy.shown = if moment.shown then 1 else 0
	return copy
end

return InviteClient
