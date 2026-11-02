--!strict
--[[
	BoostService — personal timed boosts (profile.boosts; Shared/Config/BoostConfig).

	- Product handler "Boost" (MonetizationConfig Cash2x30: boostKey + durationSeconds): adds the
	  time (stacking, capped) in the receipt's non-yielding grant step.
	- Rewards add boosts through RewardLogic (daily Day 4 / 7, wheel, codes, packs).
	- Income: registers the modifier provider "personalBoosts" with B5's Tycoon/ModifierSources
	  (via Retention/ModifierHook, offline = false so boosts never inflate offline earnings) —
	  provider(player, profile) → ({ boostCash = 2, boostSpeed = 2 } for the ACTIVE boosts, the
	  soonest expiry). Every boost change invalidates B5's cached modifiers for that player.
	- One loop prunes expired boosts every PruneEverySeconds and pushes `boosts` when one ran out
	  (HUD boost chips, Shop "active" labels).

	Public API: grant(player, key, seconds) → expiry?, multipliers(player), secondsLeft(player, key).
	Example: BoostService.grant(player, "cash2x", 600)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BoostConfig = require(ReplicatedStorage.Shared.Config.BoostConfig)
local BoostLogic = require(ServerScriptService.Server.Retention.BoostLogic)
local ModifierHook = require(ServerScriptService.Server.Retention.ModifierHook)
local MonetizationService = require(script.Parent.MonetizationService)
local PlayerDataService = require(script.Parent.PlayerDataService)

local BoostService = {}

--[[
	Adds boost time for `player` (admin, other services). Saves soon and pushes `boosts`.
	@return the new expiry (unix seconds) or nil when refused
]]
function BoostService.grant(player: Player, key: string, seconds: number): number?
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return nil
	end
	local expires = BoostLogic.extend(profile.boosts, key, seconds, os.time())
	if expires ~= nil then
		PlayerDataService.markChanged(player, true, { "boosts" })
		ModifierHook.invalidate(player)
	end
	return expires
end

--[[ The tycoon modifier fields of the player's active boosts ({} when none / not loaded). ]]
function BoostService.multipliers(player: Player): { [string]: number }
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return {}
	end
	return BoostLogic.multipliers(profile.boosts, os.time())
end

--[[ Seconds left on a boost (0 when inactive / not loaded). ]]
function BoostService.secondsLeft(player: Player, key: string): number
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return 0
	end
	return BoostConfig.secondsLeft(profile.boosts, key, os.time())
end

-- Prunes expired boosts for everyone; pushes when something ran out.
local function pruneLoop()
	while true do
		task.wait(BoostConfig.PruneEverySeconds)
		local now = os.time()
		for _, player in Players:GetPlayers() do
			local profile = PlayerDataService.getProfile(player)
			if profile ~= nil and next(profile.boosts) ~= nil and BoostLogic.prune(profile.boosts, now) > 0 then
				PlayerDataService.markChanged(player, false, { "boosts" })
				ModifierHook.invalidate(player)
			end
		end
	end
end

function BoostService.Init()
	MonetizationService.registerProductHandler("Boost", function(player, profile, product, _receipt): boolean
		local key, seconds = product.boostKey, product.durationSeconds
		if type(key) ~= "string" or type(seconds) ~= "number" then
			return false
		end
		if BoostLogic.extend(profile.boosts, key, seconds, os.time()) == nil then
			return false
		end
		-- Deferred: the grant step must not run anything that could yield.
		task.defer(ModifierHook.invalidate, player)
		return true
	end)
end

function BoostService.Start()
	ModifierHook.register("personalBoosts", function(_player: Player, profile: any): ({ [string]: number }?, number?)
		if type(profile) ~= "table" or type(profile.boosts) ~= "table" then
			return nil, nil
		end
		local now = os.time()
		return BoostLogic.multipliers(profile.boosts, now), BoostLogic.nextExpiry(profile.boosts, now)
	end)
	-- B5's ModifierSources may load after us: retry for the first minute.
	task.spawn(function()
		for _ = 1, 60 do
			if ModifierHook.flush() then
				return
			end
			task.wait(1)
		end
	end)
	task.spawn(pruneLoop)
end

return BoostService
