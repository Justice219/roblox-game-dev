--!strict
--[[
	TycoonBridge — the ONE place Attack mode talks to the tycoon server (B3/B5: Tycoon/PlotService,
	Tycoon/TycoonService). Everything attack-related about "the tycoon" goes through here, so a
	tycoon API change is a one-file fix.

	What it provides
		plotIndex(player)            the player's plot (PlotService.getPlotIndex), nil when none
		incomePerSecond(player)      idle $/s with the player's cached modifiers (TycoonService);
		                             falls back to the pure base income while the runtime warms up
		hasFeature(player, profile, key)  Feature pad owned (AATower / AttackConsole)
		featurePrice(key)            the Feature pad's cash price (TycoonConfig) — upgrade prices
		                             are multiples of it (AttackConfig.CostMultiplier)
		PlotAssigned / PlotReleased / PadBought  re-exported tycoon signals

	Why the fallbacks: the boot order puts the attack services after the tycoon, but the profile
	can be read a frame before TycoonService has built its runtime for a joining player; the
	pure formula keeps rewards sane in that window instead of paying 0.

	Connects to: Server/Tycoon/{PlotService, TycoonService}, Shared/Tycoon/TycoonLogic,
	Shared/Config/{TycoonConfig, AttackConfig}, Server/Services/{AttackService, DefenseService}.

	Example:
		local plot = TycoonBridge.plotIndex(player)
		local income = TycoonBridge.incomePerSecond(player, profile)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotService = require(script.Parent.Parent.Tycoon.PlotService)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonService = require(script.Parent.Parent.Tycoon.TycoonService)

local TycoonBridge = {}

TycoonBridge.PlotAssigned = PlotService.PlotAssigned
TycoonBridge.PlotReleased = PlotService.PlotReleased
TycoonBridge.PadBought = TycoonService.PadBought

-- A finite, non-negative number, else 0.
local function nonNegative(value: unknown): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value < 0 then
		return 0
	end
	return value
end

--[[
	The player's plot index (1..8), or nil when they have none (queued / leaving).
	@param player Player
	@return number?
]]
function TycoonBridge.plotIndex(player: Player): number?
	local index = PlotService.getPlotIndex(player)
	if type(index) == "number" and index >= 1 then
		return index
	end
	return nil
end

--[[
	The player's current idle income ($/s, automated producers, cached modifiers).
	@param player Player
	@param profile any — the loaded profile (fallback: base income from profile.tycoon)
	@return number — finite, >= 0
]]
function TycoonBridge.incomePerSecond(player: Player, profile: any): number
	if TycoonService.isReady(player) then
		return nonNegative(TycoonService.incomePerSecond(player))
	end
	if type(profile) == "table" and type(profile.tycoon) == "table" then
		return nonNegative(TycoonLogic.incomePerSecond(profile.tycoon, nil))
	end
	return 0
end

--[[
	True when the player owns a Feature pad ("AATower" / "AttackConsole"), read from the profile
	(the authoritative state) so it is right even before the tycoon runtime is ready.
	@param profile any
	@param key string — TycoonConfig feature key
	@return boolean
]]
function TycoonBridge.hasFeature(profile: any, key: string): boolean
	if type(profile) ~= "table" or type(profile.tycoon) ~= "table" then
		return false
	end
	return TycoonLogic.hasFeature(profile.tycoon, key)
end

--[[
	The cash price of a Feature pad (0 when the feature is unknown — upgrades then refuse).
	@param key string — "AATower" / "AttackConsole"
	@return number
]]
function TycoonBridge.featurePrice(key: string): number
	local padId = TycoonConfig.FeaturePadOf[key]
	local pad = if padId ~= nil then TycoonConfig.PadsById[padId] else nil
	return if pad ~= nil then nonNegative(pad.cost) else 0
end

--[[ The pad id that unlocks a feature (for PadBought filtering), or nil. ]]
function TycoonBridge.featurePad(key: string): string?
	return TycoonConfig.FeaturePadOf[key]
end

--[[
	The highest unlocked area of a profile (1 when unknown).
	@param profile any
	@return number
]]
function TycoonBridge.area(profile: any): number
	if type(profile) == "table" and type(profile.tycoon) == "table" and type(profile.tycoon.area) == "number" then
		return profile.tycoon.area
	end
	return 1
end

return TycoonBridge
