--!strict
--[[
	SoundController — background music by context, music stings, and the music/SFX settings.

	Music contexts (AudioConfig.Contexts, tracks in SoundAssets.Music — Roblox-licensed APM):
		hub    in the hub plaza (or "event" while the Harvest Feast runs: ReplicatedStorage
		       attribute EventConfig.Attributes.Active)
		early  on a plot, rows 1-2 (areas 1-4)       late  on a plot, deeper rows (areas 5-10)
	The context is re-evaluated every AudioConfig.Music.ContextCheck seconds from the character's
	position (WorldLayout.plotAt) — never per frame. Ring road / wedges keep the previous context.
	Context changes crossfade (two Music-group Sound instances A/B, TweenService); a playlist
	advances when a track ends. Screens may force a context with setOverride(name) (nil = auto).

	Stings: playSting("rebirth") ducks the music, plays the short cue, restores. Fired
	automatically when profile.rebirths increases.

	Settings: profile.settings.music -> Music group (and the players are stopped, so no streaming /
	decoding while muted); profile.settings.sfx -> SFX + UI groups (Sound.setGroupEnabled).

	Memory (owner R11): at most THREE music Sound instances exist (A, B, sting); only one track
	streams except during a crossfade. Hot SFX are preloaded at Start; the rest stream on demand.

	Boot path: Audio/SoundController (Init / Start, idempotent).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local AudioConfig = require(ReplicatedStorage.Shared.Config.AudioConfig)
local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local SoundAssets = require(ReplicatedStorage.Shared.Config.SoundAssets)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local ClientState = require(script.Parent.Parent.ClientState)
local Sound = require(script.Parent.Sound)

local SoundController = {}

local started = false
local musicOn = true
local players: { Sound } = {}
local active: Sound? = nil
local stingSound: Sound? = nil
local context: string? = nil
local override: string? = nil
local playlistIndex: { [string]: number } = {}
local duck = 1
local lastRebirths: number? = nil

local MUSIC = AudioConfig.Music

local function tweenVolume(sound: Sound, volume: number, seconds: number): Tween
	local tween = TweenService:Create(
		sound,
		TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ Volume = volume }
	)
	tween:Play()
	return tween
end

local function eventActive(): boolean
	return ReplicatedStorage:GetAttribute(EventConfig.Attributes.Active) == true
end

--[[
	Pure-ish context rule for a world position (exposed for tests / debug):
	hub plaza -> "hub" (or "event"); plot rows 1..EarlyRows -> "early"; deeper rows -> "late";
	anywhere else -> nil (keep the current context).
]]
function SoundController.contextAt(position: Vector3, isEvent: boolean): string?
	local flat = Vector3.new(position.X, 0, position.Z)
	if flat.Magnitude <= WorldLayout.HubRadius + MUSIC.HubPadding then
		return if isEvent then "event" else "hub"
	end
	local plot = WorldLayout.plotAt(position)
	if plot == nil then
		return nil
	end
	local localPoint = WorldLayout.plotOrigin(plot):PointToObjectSpace(position)
	local row = math.floor(math.max(localPoint.Z, 0) / WorldLayout.RowLength) + 1
	return if row <= MUSIC.EarlyRows then "early" else "late"
end

-- Starts the next track of `name`'s playlist, crossfading from whatever plays now.
local function startTrack(name: string)
	local list = AudioConfig.Contexts[name]
	if list == nil or #list == 0 or not musicOn then
		return
	end
	local index = (playlistIndex[name] or 0) % #list + 1
	playlistIndex[name] = index
	local track = SoundAssets.Music[list[index]]
	if track == nil then
		return
	end
	local incoming = if active == players[1] then players[2] else players[1]
	local outgoing = active
	incoming.SoundId = `rbxassetid://{track.id}`
	incoming.Volume = 0
	incoming.TimePosition = 0
	incoming:Play()
	tweenVolume(incoming, MUSIC.Volume * duck, MUSIC.Crossfade)
	active = incoming
	if outgoing ~= nil and outgoing ~= incoming then
		local fade = tweenVolume(outgoing, 0, MUSIC.Crossfade)
		fade.Completed:Once(function()
			if active ~= outgoing then
				outgoing:Stop()
			end
		end)
	end
end

local function setContext(name: string?)
	if name == nil or name == context then
		return
	end
	context = name
	startTrack(name)
end

-- Re-evaluates where the player is (once per ContextCheck, from the context loop).
local function evaluate()
	if override ~= nil then
		setContext(override)
		return
	end
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		if context == nil then
			setContext("hub")
		end
		return
	end
	setContext(SoundController.contextAt(root.Position, eventActive()) or context or "hub")
end

local function setMusicEnabled(on: boolean)
	if on == musicOn then
		return
	end
	musicOn = on
	Sound.setGroupEnabled("Music", on)
	if not on then
		for _, player in players do
			player:Stop()
		end
		active = nil
	elseif context ~= nil then
		startTrack(context)
	end
end

-- Applies settings.music / settings.sfx and fires the rebirth sting on a rebirth.
local function onProfile(profile: ClientState.Profile)
	local settings = profile.settings
	if type(settings) == "table" then
		setMusicEnabled(settings.music ~= false)
		local sfx = settings.sfx ~= false
		Sound.setGroupEnabled("SFX", sfx)
		Sound.setGroupEnabled("UI", sfx)
	end
	local rebirths = profile.rebirths
	if type(rebirths) == "number" then
		if lastRebirths ~= nil and rebirths > lastRebirths then
			SoundController.playSting("rebirth")
		end
		lastRebirths = rebirths
	end
end

--[[
	Plays a short music cue (AudioConfig.Stings), ducking the background track meanwhile.
	@param name string  e.g. "rebirth"
]]
function SoundController.playSting(name: string)
	local key = AudioConfig.Stings[name]
	local track = key and SoundAssets.Music[key]
	if track == nil or not musicOn then
		return
	end
	local sting = stingSound
	if sting == nil then
		local created = Instance.new("Sound")
		created.Name = "SN_MusicSting"
		created.SoundGroup = Sound.ensure().Music
		created.Parent = SoundService
		created.Ended:Connect(function()
			duck = 1
			if active ~= nil then
				tweenVolume(active, MUSIC.Volume, MUSIC.DuckFade)
			end
		end)
		stingSound = created
		sting = created
	end
	local cue = sting :: Sound
	duck = MUSIC.DuckVolume
	if active ~= nil then
		tweenVolume(active, MUSIC.Volume * duck, MUSIC.DuckFade)
	end
	cue.SoundId = `rbxassetid://{track.id}`
	cue.Volume = MUSIC.StingVolume
	cue.TimePosition = 0
	cue:Play()
end

--[[ Forces a music context ("hub" | "early" | "late" | "event") or nil for automatic. ]]
function SoundController.setOverride(name: string?)
	override = if name ~= nil and AudioConfig.Contexts[name] ~= nil then name else nil
	evaluate()
end

-- Current context (debug / verification).
function SoundController.currentContext(): string?
	return context
end

function SoundController.Init() end

function SoundController.Start()
	if started then
		return
	end
	started = true
	local groups = Sound.ensure()
	for i = 1, 2 do
		local player = Instance.new("Sound")
		player.Name = `SN_Music{i}`
		player.SoundGroup = groups.Music
		player.Looped = false
		player.Parent = SoundService
		player.Ended:Connect(function()
			-- Playlist: the active track finished -> next track of the same context.
			if active == player and context ~= nil and musicOn then
				startTrack(context)
			end
		end)
		players[i] = player
	end
	Sound.preloadHot()
	if ClientState.profile ~= nil then
		onProfile(ClientState.profile)
	end
	ClientState.ProfileChanged:Connect(onProfile)
	task.spawn(function()
		while true do
			evaluate()
			task.wait(MUSIC.ContextCheck)
		end
	end)
end

return SoundController
