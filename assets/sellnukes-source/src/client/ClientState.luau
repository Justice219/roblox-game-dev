--!strict
--[[
	ClientState — the client's cache of server-pushed per-player state (pattern from RoBeasts).

	Purpose:
		Many screens need the same data (cash on the HUD, the shop and every pad billboard; settings
		in the settings screen and the audio controller). This module listens to the server ONCE
		and exposes the latest values plus change signals, so screens never wire their own remote
		listeners for the same thing.

	Sources:
		ProfileUpdate(snapshot, seq) + ProfileDelta(delta)  → ClientState.profile / ProfileChanged
			(Client/ProfileSyncClient merges deltas into a NEW table, so ClientState.profile is
			replaced, never mutated in place; ProfileChanged fires once per push with the full
			current profile and the changed top-level field names — nil after a full snapshot)
		Notify({ kind, text, icon? })    → Notified(payload)        (toasts; validated shape)
		PurchaseGranted({ key, kind })   → PurchaseGranted(payload) (a Robux grant is durable)

	The profile is the server's ProfileLogic.snapshot (see that module for the exact shape): cash,
	gems, totalEarned, rebirths, rebirthTokens, rebirthShop, tycoon { pads, producers, area,
	standName, tutorialStep }, stats, passes, pets { owned, equipped, eggs, pity, index },
	crates { held, pity, opened }, trails { owned, equipped }, boosts, daily,
	timeRewards { day, seconds, claimed = { n } }, spin, group, notify, starter, secretPack,
	attack { aa, launcher, shieldUntil, cooldownUntil, hitsTaken, barrage },
	event { season, acorns, stickers = { n }, redeemed, decor, turkeys, lures }, settings, saveStatus,
	policy { paidRandomRestricted, known }, and (schema v2, owner R57 World 2):
	worlds { [worldId] = { unlocked, unlockedAt, tycoon { pads, producers, area }, rebirths,
	rebirthTokens, rebirthShop, stats { visits }, starter { bought } } } (structure, pushed on
	change), worldCash { [worldId] = { cash, totalEarned } } (each world's currency, e.g. Bones;
	its own small delta field so a Bones tick never resends the structure), lastWorld.
	"main" is never in `worlds` (its data is the top-level fields). Read worlds through the
	helpers below (world / worldUnlocked / worldCash / lastWorld): they tolerate a missing or
	malformed snapshot. Treat it as READ-ONLY server truth: never mutate it, never send it back.
	Clients only send intents.

	Example:
		ClientState.ProfileChanged:Connect(function(profile, fields)
			if fields == nil or table.find(fields, "cash") then
				cashLabel.Text = NumberFormat.money(profile.cash)
			end
		end)
		local profile = ClientState.waitForProfile() -- yields until the first snapshot
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileSyncClient = require(script.Parent.ProfileSyncClient)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type Profile = { [string]: any }
export type NotifyPayload = { kind: string, text: string, icon: string? }
export type GrantPayload = { key: string, kind: string }

local ClientState = {}

ClientState.profile = nil :: Profile?

ClientState.ProfileChanged = Signal.new() :: Signal.Signal<Profile, { string }?>
ClientState.Notified = Signal.new() :: Signal.Signal<NotifyPayload>
ClientState.PurchaseGranted = Signal.new() :: Signal.Signal<GrantPayload>

-- Caps for server text shown in toasts (defensive: a broken payload can never flood the UI).
local MAX_NOTIFY_TEXT = 300
local MAX_SHORT_TEXT = 32

local started = false

-- A non-empty string of at most `cap` bytes, else nil.
local function shortString(value: unknown, cap: number): string?
	if type(value) == "string" and #value >= 1 and #value <= cap then
		return value
	end
	return nil
end

--[[
	Starts listening (idempotent). Called from the client bootstrap before any controller starts,
	so every screen can read ClientState.profile / connect ProfileChanged in its Init.
]]
function ClientState.start()
	if started then
		return
	end
	started = true
	-- Full snapshots and deltas both end here as the complete current profile.
	ProfileSyncClient.start(function(profile: Profile, fields: { string }?)
		ClientState.profile = profile
		ClientState.ProfileChanged:Fire(profile, fields)
	end)
	Remotes.event("Notify").OnClientEvent:Connect(function(payload: unknown)
		if type(payload) ~= "table" then
			return
		end
		local raw = payload :: { [string]: unknown }
		local text = shortString(raw.text, MAX_NOTIFY_TEXT)
		if text == nil then
			return
		end
		ClientState.Notified:Fire({
			kind = shortString(raw.kind, MAX_SHORT_TEXT) or "info",
			text = text,
			icon = shortString(raw.icon, MAX_SHORT_TEXT),
		})
	end)
	Remotes.event("PurchaseGranted").OnClientEvent:Connect(function(payload: unknown)
		if type(payload) ~= "table" then
			return
		end
		local raw = payload :: { [string]: unknown }
		local key = shortString(raw.key, MAX_SHORT_TEXT)
		local kind = shortString(raw.kind, MAX_SHORT_TEXT)
		if key ~= nil and kind ~= nil then
			ClientState.PurchaseGranted:Fire({ key = key, kind = kind })
		end
	end)
end

-- The main world's id (its data is the snapshot's top-level fields).
local MAIN_WORLD = "main"

-- A finite number, else 0 (defensive read of server numbers).
local function finiteOrZero(value: unknown): number
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return 0
end

--[[
	R57: a non-main world's snapshot structure (unlocked, tycoon, rebirths, rebirthTokens,
	rebirthShop, stats, starter), or nil: no profile yet, "main" (top-level fields), or a world
	this snapshot does not carry. READ-ONLY.
	Example: local dino = ClientState.world("dino"); if dino then print(dino.tycoon.area) end
]]
function ClientState.world(worldId: string): Profile?
	local profile = ClientState.profile
	local worlds = if profile ~= nil then profile.worlds else nil
	if worldId == MAIN_WORLD or type(worlds) ~= "table" then
		return nil
	end
	local world = worlds[worldId]
	return if type(world) == "table" then world else nil
end

--[[
	R57: true when the server says `worldId` is unlocked for this player ("main" always). Display
	only: the server re-checks every travel / purchase.
	Example: if ClientState.worldUnlocked("dino") then showPortalOpen() end
]]
function ClientState.worldUnlocked(worldId: string): boolean
	if worldId == MAIN_WORLD then
		return true
	end
	local world = ClientState.world(worldId)
	return world ~= nil and world.unlocked == true
end

--[[
	R57: a world's currency balance and lifetime total ("main" → cash / totalEarned; "dino" →
	Bones from worldCash). 0, 0 before the first snapshot or for an unknown world.
	Example: local bones = ClientState.worldCash("dino")
]]
function ClientState.worldCash(worldId: string): (number, number)
	local profile = ClientState.profile
	if profile == nil then
		return 0, 0
	end
	if worldId == MAIN_WORLD then
		return finiteOrZero(profile.cash), finiteOrZero(profile.totalEarned)
	end
	local all = profile.worldCash
	local entry = if type(all) == "table" then all[worldId] else nil
	if type(entry) ~= "table" then
		return 0, 0
	end
	return finiteOrZero(entry.cash), finiteOrZero(entry.totalEarned)
end

--[[ R57: the world the last session ended in ("main" before the first snapshot / when unset). ]]
function ClientState.lastWorld(): string
	local profile = ClientState.profile
	local last = if profile ~= nil then profile.lastWorld else nil
	return if type(last) == "string" and #last >= 1 then last else MAIN_WORLD
end

--[[
	Yields until the first profile snapshot arrives (returns at once when it already has).
	@param timeout optional seconds; nil waits as long as it takes
	@return the profile, or nil when `timeout` passed first
	Example: local profile = ClientState.waitForProfile(30)
]]
function ClientState.waitForProfile(timeout: number?): Profile?
	local current = ClientState.profile
	if current ~= nil then
		return current
	end
	local thread = coroutine.running()
	local finished = false
	local connection: Signal.Connection
	local timer: thread? = nil
	local function finish(profile: Profile?)
		if finished then
			return
		end
		finished = true
		connection:Disconnect()
		if timer ~= nil and coroutine.running() ~= timer then
			task.cancel(timer)
		end
		task.spawn(thread, profile)
	end
	connection = ClientState.ProfileChanged:Connect(function(profile: Profile)
		finish(profile)
	end)
	if timeout ~= nil then
		timer = task.delay(timeout, function()
			finish(nil)
		end)
	end
	return coroutine.yield()
end

return ClientState
