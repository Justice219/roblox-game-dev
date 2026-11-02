--!strict
--[[
	SettingsService — the SetSetting remote (design spec §6 Settings: music, sfx, reduced motion,
	hide others' pets, vibration, fast hatch, and the AutoClicker pass on / off — owner R64).

	SetSetting (C→S, key, value): token bucket → profile loaded → ProfileLogic.applySetting
	(allowlisted keys, booleans only) → markChanged({ "settings" }) on a change; a refused or
	unchanged request re-sends the stored settings so an optimistic toggle snaps back.
	Settings are preferences: they need a loaded profile but not a saving session. Most are read
	by the client; `autoClicker` is read by the server (TycoonService), which listens to
	SettingsService.Changed instead of polling the profile. The toggle only ever turns a perk the
	player owns OFF / back ON — it can never grant the pass (TycoonRules.autoClickerOn).

	API
		SettingsService.set(player, key, value) -> boolean          the handler without its rate limit
		SettingsService.get(player, key) -> boolean?                the stored value
		SettingsService.Changed: Signal(player, key, value)         after a stored value changed

	Example: SettingsService.set(player, "music", false) --> true
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerDataService = require(script.Parent.PlayerDataService)
local ProfileLogic = require(ServerScriptService.Server.Economy.ProfileLogic)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local SettingsService = {}

-- Fired after a stored setting changed (player, key, new value). Example: TycoonService re-reads
-- the AutoClicker toggle: SettingsService.Changed:Connect(function(p, key) ... end)
SettingsService.Changed = Signal.new() :: Signal.Signal<Player, string, boolean>

local limiter = RateLimiter.new(RetentionConfig.Limits.Settings.Burst, RetentionConfig.Limits.Settings.PerSecond)

--[[ Applies one setting (the handler without its rate limit). @return true when it changed ]]
function SettingsService.set(player: Player, key: unknown, value: unknown): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false
	end
	if ProfileLogic.applySetting(profile.settings, key, value) then
		PlayerDataService.markChanged(player, false, { "settings" })
		-- applySetting accepted it, so key is an allowlisted string and value a boolean.
		SettingsService.Changed:Fire(player, key :: string, value :: boolean)
		return true
	end
	PlayerDataService.refresh(player, { "settings" })
	return false
end

--[[ The player's stored setting (server code, e.g. audio defaults). ]]
function SettingsService.get(player: Player, key: ProfileLogic.SettingKey): boolean?
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return nil
	end
	return (profile.settings :: any)[key]
end

function SettingsService.Init() end

function SettingsService.Start()
	Remotes.onServerEvent("SetSetting", function(player: Player, key: unknown, value: unknown)
		if limiter:Allow(player) then
			SettingsService.set(player, key, value)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		limiter:Forget(player)
	end)
end

return SettingsService
