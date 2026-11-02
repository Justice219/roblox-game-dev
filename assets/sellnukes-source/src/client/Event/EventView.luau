--!strict
--[[
	EventView — the client's read-only view of the Harvest Feast for the HUD and the screens.

	Purpose:
		One place that turns the server's data into display facts:
			- the event window / force state: ReplicatedStorage attributes written by EventService
			  (EventConfig.Attributes: Active, EndsAt, RedeemUntil),
			- the player's season record: ClientState.profile.event (acorns, the sticker array,
			  redeemed, and — once the profile schema carries them — decor / turkeys / lures).
		`Changed` fires (coalesced to one per frame) whenever either source changes, so screens and
		the HUD button re-render once instead of polling. Nothing here is trusted by the server:
		every action is re-validated there.

	Connects to: Client/ClientState, Shared/Config/EventConfig, Client/Event/EventController (HUD
	button), UI/Screens/StickerSheet + EventShop.

	Example:
		EventView.start()
		EventView.Changed:Connect(function() print(EventView.acorns(), EventView.count()) end)
		if EventView.buttonVisible() then Hud.setButtonVisible("Event", true) end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.Parent.ClientState)
local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local EventView = {}

-- Fires (deferred, coalesced) when the event state or the player's event record changed.
EventView.Changed = Signal.new() :: Signal.Signal<>

local started = false
local queued = false

-- A finite whole number from an untyped field (default when junk).
local function whole(value: unknown, default: number): number
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return math.floor(value)
	end
	return default
end

-- The raw profile.event table (or an empty table before the profile arrives).
local function record(): { [string]: any }
	local profile = ClientState.profile
	if type(profile) == "table" and type(profile.event) == "table" then
		return profile.event :: any
	end
	return {}
end

-- Coalesces bursts (profile delta + attribute change in one frame) into one Changed.
local function queueChanged()
	if queued then
		return
	end
	queued = true
	task.defer(function()
		queued = false
		EventView.Changed:Fire()
	end)
end

--[[ True while the Harvest Feast runs (server attribute; follows the admin force). ]]
function EventView.active(): boolean
	return ReplicatedStorage:GetAttribute(EventConfig.Attributes.Active) == true
end

--[[ Unix time the season ends (server attribute, config fallback). ]]
function EventView.endsAt(): number
	return whole(ReplicatedStorage:GetAttribute(EventConfig.Attributes.EndsAt), EventConfig.Season.ends)
end

--[[ Unix time until which a completed sheet may still be redeemed. ]]
function EventView.redeemUntil(): number
	return whole(ReplicatedStorage:GetAttribute(EventConfig.Attributes.RedeemUntil), EventConfig.redeemUntil())
end

--[[ The player's acorns (as the server sent them). ]]
function EventView.acorns(): number
	return math.max(0, whole(record().acorns, 0))
end

--[[ Owned sticker set { [index] = true } (from the snapshot's sorted array). ]]
function EventView.stickers(): { [number]: boolean }
	return EventConfig.stickerSet(record().stickers)
end

--[[ Stickers owned (0..StickerCount). ]]
function EventView.count(): number
	return EventConfig.countStickers(record().stickers)
end

--[[ All stickers collected. ]]
function EventView.complete(): boolean
	return EventView.count() >= EventConfig.StickerCount
end

--[[ This season's Gobble Bomb was redeemed. ]]
function EventView.redeemed(): boolean
	return record().redeemed == true
end

--[[ True once the profile snapshot carries event.decor (decor purchases persist). ]]
function EventView.decorSupported(): boolean
	return type(record().decor) == "table"
end

--[[ True when the player owns the decoration `key` (snapshot set or array form). ]]
function EventView.ownsDecor(key: string): boolean
	local raw = record().decor
	if type(raw) ~= "table" then
		return false
	end
	local decor = raw :: { [any]: any }
	if decor[key] == true then
		return true
	end
	for _, value in decor do
		if value == key then
			return true
		end
	end
	return false
end

--[[ Turkeys caught this season (0 until the schema carries event.turkeys). ]]
function EventView.turkeys(): number
	return math.max(0, whole(record().turkeys, 0))
end

--[[ True while a completed, unredeemed sheet can still be redeemed. ]]
function EventView.canRedeem(): boolean
	if not EventView.complete() or EventView.redeemed() then
		return false
	end
	return EventView.active() or Workspace:GetServerTimeNow() < EventView.redeemUntil()
end

--[[
	The HUD Event button shows while the event runs, and during the redeem grace only for players
	who still have a completed sheet to redeem.
]]
function EventView.buttonVisible(): boolean
	return EventView.active() or EventView.canRedeem()
end

--[[ Connects the change sources once (EventController.Start). ]]
function EventView.start()
	if started then
		return
	end
	started = true
	ClientState.ProfileChanged:Connect(function(_profile: any, fields: { string }?)
		if fields == nil or table.find(fields, "event") ~= nil then
			queueChanged()
		end
	end)
	local names = EventConfig.Attributes
	for _, name in { names.Active, names.StartsAt, names.EndsAt, names.RedeemUntil, names.Forced } do
		ReplicatedStorage:GetAttributeChangedSignal(name):Connect(queueChanged)
	end
	queueChanged()
end

return EventView
