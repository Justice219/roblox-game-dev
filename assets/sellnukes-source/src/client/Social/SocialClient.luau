--!strict
--[[
	SocialClient — the client side of the R78 Rush boosts + Friend Boost + invites (spec §3 / §4;
	docs/social.md). A boot controller (Init / Start): "Social/SocialClient". Display + the invite
	prompt only: every multiplier, timer and reward is decided by the server (RushService /
	FriendService); this module never sends amounts.

	State it keeps (read by UI/Screens/{BoostChips, Friends, WelcomeBack}, UI/RewardsBadges):
		rush      from the profile snapshot field `rush` ({ rookieLeft, comebackUntil }): the
		          Rookie Rush end = server time of the push + rookieLeft (it only counts down while
		          online, and the server re-pushes every Rush.SyncSeconds), the Comeback Rush end =
		          comebackUntil. `SocialClient.rush()`.
		friends   the server's `Social { kind = "friends", count, percent, names }` (validated:
		          whole count 0..7, percent 0..MaxPercent, ≤ MaxNames short strings).
		comeback  a fresh `Social { kind = "comeback", away, seconds, multiplier }` (validated) for
		          the Welcome Back screen (peekComeback / takeComeback; stale after
		          Client.ComebackFreshSeconds).
		referral  from the snapshot field `referral` ({ paid, invited }).
		live      SocialConfig.live(ReplicatedStorage attributes): the admin switches / percent.
	Signals: Changed() (any of the above), ComebackArrived(Comeback), InviteResult(action).

	Invites (SocialService needs the CLIENT): invite() → CanSendGameInviteAsync (pcall) →
	PromptGameInvite(player, ExperienceInviteOptions { PromptMessage }) → GameInvitePromptClosed
	(recipient count). Each outcome is reported to the server's `FriendInvite` remote for
	analytics only ("prompted" | "sent" | "closed" | "unavailable" | "failed").

	Performance: event-driven (profile pushes, one remote, attribute signals); no loops.

	Connects to: Client/ClientState, Shared/Net/Remotes ("Social", "FriendInvite"),
	Shared/Config/SocialConfig, Server/Services/{RushService, FriendService}.

	Example:
		local rush = SocialClient.rush()        --> { rookieEndsAt = 1793000861, comebackEndsAt = 0, ... }
		SocialClient.invite()                   -- opens Roblox's invite prompt (when allowed)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.Parent.ClientState)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)

export type Friends = { count: number, percent: number, names: { string } }
export type Rush = {
	rookieEndsAt: number, -- server unix time (0 = none)
	comebackEndsAt: number, -- server unix time (0 = none)
	rookieMultiplier: number,
	comebackMultiplier: number,
}
export type Comeback = { away: number, seconds: number, multiplier: number, receivedAt: number }
export type Referral = { paid: number, max: number, invited: boolean }
export type InviteAction = "prompted" | "sent" | "closed" | "unavailable" | "failed"

local SocialClient = {}

SocialClient.Changed = Signal.new() :: Signal.Signal<>
SocialClient.ComebackArrived = Signal.new() :: Signal.Signal<Comeback>
SocialClient.InviteResult = Signal.new() :: Signal.Signal<InviteAction>

-- Longest friend display name accepted from the server (Roblox caps display names far lower).
local MAX_NAME_BYTES = 80

local friends: Friends = { count = 0, percent = 0, names = {} }
local rookieEndsAt = 0
local comebackEndsAt = 0
local referral: Referral = { paid = 0, max = SocialConfig.Referral.MaxPaid, invited = false }
local comeback: Comeback? = nil
local inviting = false
local started = false

-- Server unix time (the clock every countdown uses).
local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- A finite number within [lo, hi], else nil.
local function within(value: unknown, lo: number, hi: number): number?
	if type(value) ~= "number" or value ~= value or value < lo or value > hi then
		return nil
	end
	return value
end

--[[ The admin-overridable switches / values (ReplicatedStorage attributes). ]]
function SocialClient.live(): SocialConfig.Live
	return SocialConfig.live(function(name: string): any
		return ReplicatedStorage:GetAttribute(name)
	end)
end

--[[ A copy of the Friend Boost state (the server's last push). ]]
function SocialClient.friends(): Friends
	return { count = friends.count, percent = friends.percent, names = table.clone(friends.names) }
end

--[[ The Rush timers (server time) + multipliers. ]]
function SocialClient.rush(): Rush
	return {
		rookieEndsAt = rookieEndsAt,
		comebackEndsAt = comebackEndsAt,
		rookieMultiplier = SocialConfig.Rush.RookieMultiplier,
		comebackMultiplier = SocialConfig.Rush.ComebackMultiplier,
	}
end

--[[ Referral progress (inviter rewards received / the lifetime cap, joined through an invite). ]]
function SocialClient.referral(): Referral
	return table.clone(referral)
end

--[[ The fresh Comeback Rush announcement, or nil (stale ones are dropped). ]]
function SocialClient.peekComeback(): Comeback?
	local fresh = comeback
	if fresh ~= nil and serverNow() - fresh.receivedAt > SocialConfig.Client.ComebackFreshSeconds then
		comeback = nil
		return nil
	end
	return fresh
end

--[[ Takes the fresh Comeback Rush announcement (shown once; the Welcome Back screen calls it). ]]
function SocialClient.takeComeback(): Comeback?
	local fresh = SocialClient.peekComeback()
	comeback = nil
	return fresh
end

-- Reports an invite outcome to the server (analytics only) and to listeners.
local function report(action: InviteAction, recipients: number?)
	Remotes.event("FriendInvite"):FireServer(action, recipients)
	SocialClient.InviteResult:Fire(action)
end

--[[
	Opens Roblox's invite prompt (when this account / device may send invites). Never yields the
	caller; one prompt at a time. The outcome arrives on InviteResult.
	@return false when a prompt is already in progress
	Example: SocialClient.invite()
]]
function SocialClient.invite(): boolean
	if inviting then
		return false
	end
	inviting = true
	task.spawn(function()
		local player = Players.LocalPlayer
		local okCan, can = pcall(function(): boolean
			return SocialService:CanSendGameInviteAsync(player)
		end)
		if not okCan or can ~= true then
			inviting = false
			report("unavailable")
			return
		end
		local okPrompt, err = pcall(function()
			local options = Instance.new("ExperienceInviteOptions")
			options.PromptMessage = SocialConfig.Invite.PromptMessage
			SocialService:PromptGameInvite(player, options)
		end)
		if not okPrompt then
			warn(`[SocialClient] invite prompt failed: {err}`)
			inviting = false
			report("failed")
			return
		end
		report("prompted")
	end)
	return true
end

--[[ True while an invite prompt is open. ]]
function SocialClient.isInviting(): boolean
	return inviting
end

-- Reads the profile's `rush` / `referral` fields (validated; junk = none).
local function readProfile(profile: ClientState.Profile, fields: { string }?)
	local changed = false
	local function touched(name: string): boolean
		return fields == nil or table.find(fields, name) ~= nil
	end
	if touched("rush") then
		local raw = profile.rush
		local left = if type(raw) == "table" then within(raw.rookieLeft, 0, SocialConfig.Rush.MaxMinutes * 60) else nil
		local untilTime = if type(raw) == "table" then within(raw.comebackUntil, 0, 9_999_999_999) else nil
		local now = serverNow()
		rookieEndsAt = if left ~= nil and left > 0 then now + left else 0
		comebackEndsAt = untilTime or 0
		changed = true
	end
	if touched("referral") then
		local raw = profile.referral
		local paid = if type(raw) == "table" then within(raw.paid, 0, 1000) else nil
		referral = {
			paid = math.floor(paid or 0),
			max = SocialConfig.Referral.MaxPaid,
			invited = type(raw) == "table" and raw.invited == true,
		}
		changed = true
	end
	if changed then
		SocialClient.Changed:Fire()
	end
end

-- Validates and applies one `Social` push.
local function onSocial(payload: unknown)
	if type(payload) ~= "table" then
		return
	end
	local data = payload :: { [string]: unknown }
	if data.kind == "friends" then
		local count = within(data.count, 0, 7)
		local percent = within(data.percent, 0, SocialConfig.Friends.MaxPercent)
		if count == nil or percent == nil or count % 1 ~= 0 then
			return
		end
		local names: { string } = {}
		local list = data.names
		if type(list) == "table" then
			for index = 1, SocialConfig.Friends.MaxNames do
				local name = (list :: { unknown })[index]
				if type(name) ~= "string" then
					break
				end
				if #name > 0 and #name <= MAX_NAME_BYTES and utf8.len(name) ~= nil then
					table.insert(names, name)
				end
			end
		end
		friends = { count = count, percent = math.floor(percent), names = names }
		SocialClient.Changed:Fire()
	elseif data.kind == "comeback" then
		local away = within(data.away, 0, 1e10)
		local seconds = within(data.seconds, 1, SocialConfig.Rush.MaxMinutes * 60)
		local multiplier = within(data.multiplier, 1, SocialConfig.Rush.MaxMultiplier)
		if away == nil or seconds == nil or multiplier == nil then
			return
		end
		local fresh: Comeback = { away = away, seconds = seconds, multiplier = multiplier, receivedAt = serverNow() }
		comeback = fresh
		SocialClient.ComebackArrived:Fire(fresh)
	end
end

function SocialClient.Init() end

--[[ Start: profile pushes, the Social remote, invite prompt results, admin attribute changes. ]]
function SocialClient.Start()
	if started then
		return
	end
	started = true
	ClientState.ProfileChanged:Connect(readProfile)
	local profile = ClientState.profile
	if profile ~= nil then
		readProfile(profile, nil)
	end
	SocialService.GameInvitePromptClosed:Connect(function(sender: Instance, recipientIds: { number })
		if sender ~= Players.LocalPlayer or not inviting then
			return
		end
		inviting = false
		local count = if type(recipientIds) == "table" then #recipientIds else 0
		if count > 0 then
			report("sent", math.min(count, SocialConfig.Invite.MaxRecipients))
		else
			report("closed")
		end
	end)
	local attrs = SocialConfig.Attributes
	for _, name in
		{ attrs.RushEnabled, attrs.FriendsEnabled, attrs.RookieMinutes, attrs.ComebackMinutes, attrs.FriendPercent }
	do
		ReplicatedStorage:GetAttributeChangedSignal(name):Connect(function()
			SocialClient.Changed:Fire()
		end)
	end
	-- Connected off the boot thread: Remotes.event may wait for replication.
	task.spawn(function()
		Remotes.event("Social").OnClientEvent:Connect(onSocial)
	end)
end

return SocialClient
