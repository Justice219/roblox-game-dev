--!strict
--[[
	ServerBoostService — "Server 2x Cash" (design spec §11: 15 min, whole server; per server, no
	MessagingService).

	- Product handler "ServerBoost" (MonetizationConfig ServerCash2x: durationSeconds, multiplier):
	  extends this server's boost from max(now, current end) by the product's seconds, capped at
	  BoostConfig.Server.MaxStackSeconds ahead; records the buyer's display name. Non-yielding.
	- Replicated as ReplicatedStorage attributes (BoostConfig.Server.EndsAtAttribute = unix end,
	  ByAttribute = buyer name) so every client draws the banner / timer; a server-wide Notify
	  thanks the buyer.
	- Income: modifier provider "serverBoost" → ({ serverCash = multiplier }, endsAt) while active
	  (offline = false); start / stop invalidate every player's cached modifiers.
	- If the buyer's receipt is processed on a server where they no longer are, the receipt waits
	  (MonetizationService defers receipts for absent buyers) and the boost starts where they are.

	Public API: start(seconds, byName) (admin), stop() (admin), endsAt(), isActive(), multiplier().
	Example: ServerBoostService.start(900, "Admin") -- admin panel "server 2x boost on"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BoostConfig = require(ReplicatedStorage.Shared.Config.BoostConfig)
local ModifierHook = require(ServerScriptService.Server.Retention.ModifierHook)
local MonetizationService = require(script.Parent.MonetizationService)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TextUtil = require(ReplicatedStorage.Shared.Util.TextUtil)

local ServerBoostService = {}

local state = { endsAt = 0, by = "" }

-- Publishes the state as ReplicatedStorage attributes.
local function publish()
	ReplicatedStorage:SetAttribute(BoostConfig.Server.EndsAtAttribute, state.endsAt)
	ReplicatedStorage:SetAttribute(BoostConfig.Server.ByAttribute, state.by)
end

--[[
	Starts / extends the server boost by `seconds` (stacking, capped). Never yields.
	@return the new end time (unix seconds), or nil for bad input
]]
function ServerBoostService.start(seconds: number, byName: string): number?
	if seconds ~= seconds or seconds <= 0 or seconds == math.huge then
		return nil
	end
	local now = os.time()
	local from = math.max(now, state.endsAt)
	state.endsAt = math.floor(math.min(from + seconds, now + BoostConfig.Server.MaxStackSeconds))
	state.by = TextUtil.cutChars(byName, 32)
	publish()
	-- Deferred: start() also runs inside the receipt grant step, which must not yield.
	task.defer(ModifierHook.invalidateAll)
	local minutes = math.max(1, math.floor(seconds / 60 + 0.5))
	Remotes.fireAllClients("Notify", {
		kind = "reward",
		text = `{state.by} turned on 2x Cash for everyone for {minutes} minutes! Thank you!`,
		icon = "x2Cash",
	})
	return state.endsAt
end

--[[ Admin: ends the server boost now. ]]
function ServerBoostService.stop()
	state.endsAt = 0
	state.by = ""
	publish()
	ModifierHook.invalidateAll()
end

--[[ Unix end time of the server boost (0 = never started). ]]
function ServerBoostService.endsAt(): number
	return state.endsAt
end

--[[ True while the server boost runs. ]]
function ServerBoostService.isActive(): boolean
	return os.time() < state.endsAt
end

--[[ The server cash multiplier right now (1 when inactive). ]]
function ServerBoostService.multiplier(): number
	return if ServerBoostService.isActive() then BoostConfig.Server.Multiplier else 1
end

function ServerBoostService.Init()
	MonetizationService.registerProductHandler("ServerBoost", function(player, _profile, product, _receipt): boolean
		local seconds = product.durationSeconds
		if type(seconds) ~= "number" or seconds <= 0 then
			return false
		end
		return ServerBoostService.start(seconds, player.DisplayName) ~= nil
	end)
end

function ServerBoostService.Start()
	publish()
	ModifierHook.register("serverBoost", function(_player: Player, _profile: any): ({ [string]: number }?, number?)
		if ServerBoostService.isActive() then
			return { serverCash = BoostConfig.Server.Multiplier }, state.endsAt
		end
		return nil, nil
	end)
	-- Late joiners read the attributes; nothing else needs sending.
end

return ServerBoostService
