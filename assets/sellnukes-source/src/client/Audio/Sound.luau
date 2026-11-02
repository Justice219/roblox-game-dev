--!strict
--[[
	Sound — the ONE client API for sound effects. Every system calls it; nobody creates Sounds.

		Sound.play("ui_click")                                  -- 2D (UI / your own events)
		Sound.play("cash_big", { position = pad.Position })     -- 3D, distance-attenuated
		Sound.play("clack", { position = p, pitch = 1.2, volume = 0.5 })

	Behaviour (AudioConfig.Sfx per key; ids in SoundAssets.SfxIds):
		* Three SoundGroups under SoundService — Music, SFX, UI — so settings mute whole groups
		  (settings.music / settings.sfx, applied by SoundController via setGroupEnabled).
		* 2D voices are pooled per key (AudioConfig `voices`); when all are busy the oldest is
		  re-used. 3D plays move one of AudioConfig.Emitters3D pooled Attachments (Terrain) to the
		  position. All Sound instances are created on first use and then re-used forever:
		  no Instance.new on the hot path.
		* Random pitch variation per play (`pitchVar`), per-key minimum interval (no stacking buzz).
		* Keys with id 0 (not uploaded) or a muted group are skipped silently.
		* preloadHot() fetches only `preload` keys (mobile memory, owner R11).

	Trust: keys come from client code; unknown keys warn once and are ignored.
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local AudioConfig = require(ReplicatedStorage.Shared.Config.AudioConfig)
local SoundAssets = require(ReplicatedStorage.Shared.Config.SoundAssets)

export type PlayOptions = {
	position: Vector3?, -- world position -> 3D sound; nil -> 2D
	pitch: number?, -- multiplier on PlaybackSpeed (before variation)
	volume: number?, -- multiplier on the key's volume
}

local Sound = {}

local groups: { [string]: SoundGroup } = {}
local enabled: { [string]: boolean } = { Music = true, SFX = true, UI = true }
local voices2D: { [string]: { Sound } } = {}
local nextVoice: { [string]: number } = {}
local emitters: { Attachment } = {}
local nextEmitter = 1
local lastPlayed: { [string]: number } = {}
local warned: { [string]: boolean } = {}
local folder2D: Folder? = nil
local random = Random.new()

--[[ Creates the SoundGroups + 2D folder once (idempotent). Returns the groups by name. ]]
function Sound.ensure(): { [string]: SoundGroup }
	if next(groups) ~= nil then
		return groups
	end
	for name, volume in AudioConfig.Groups do
		local group = Instance.new("SoundGroup")
		group.Name = `SN_{name}`
		group.Volume = volume
		group.Parent = SoundService
		groups[name] = group
	end
	local holder = Instance.new("Folder")
	holder.Name = "SN_Sfx2D"
	holder.Parent = SoundService
	folder2D = holder
	return groups
end

--[[
	Enables / mutes a whole group (settings). Muted groups also skip play() entirely, so no
	decoding cost is spent on sounds nobody hears.
]]
function Sound.setGroupEnabled(name: string, on: boolean)
	local group = Sound.ensure()[name]
	enabled[name] = on
	if group ~= nil then
		group.Volume = if on then AudioConfig.Groups[name] or 1 else 0
	end
end

function Sound.isGroupEnabled(name: string): boolean
	return enabled[name] ~= false
end

-- Resolves aliases; returns the canonical key.
local function canonical(key: string): string
	return AudioConfig.Aliases[key] or key
end

-- A new Sound for `key` wired to its group (only called while pools warm up).
local function makeSound(key: string, id: number, spec: AudioConfig.SfxSpec, parent: Instance): Sound
	local sound = Instance.new("Sound")
	sound.Name = key
	sound.SoundId = `rbxassetid://{id}`
	sound.SoundGroup = groups[spec.group]
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = 10
	sound.RollOffMaxDistance = spec.range or 150
	sound.Parent = parent
	return sound
end

-- Next 2D voice for a key (pool grows to `voices`, then round-robins = oldest re-used).
local function voice2D(key: string, id: number, spec: AudioConfig.SfxSpec): Sound
	local pool = voices2D[key]
	if pool == nil then
		pool = {}
		voices2D[key] = pool
	end
	local limit = math.max(spec.voices or 2, 1)
	if #pool < limit then
		local sound = makeSound(key, id, spec, folder2D :: Folder)
		table.insert(pool, sound)
		return sound
	end
	local index = nextVoice[key] or 1
	nextVoice[key] = index % limit + 1
	return pool[index]
end

-- A pooled 3D emitter's Sound for `key`, moved to `position`.
local function voice3D(key: string, id: number, spec: AudioConfig.SfxSpec, position: Vector3): Sound
	if #emitters == 0 then
		for i = 1, AudioConfig.Emitters3D do
			local attachment = Instance.new("Attachment")
			attachment.Name = `SN_Sfx3D{i}`
			attachment.Parent = workspace.Terrain
			emitters[i] = attachment
		end
	end
	local attachment = emitters[nextEmitter]
	nextEmitter = nextEmitter % #emitters + 1
	attachment.WorldPosition = position
	local existing = attachment:FindFirstChild(key)
	if existing ~= nil and existing:IsA("Sound") then
		return existing
	end
	return makeSound(key, id, spec, attachment)
end

--[[
	Plays a sound effect.
	@param key string  AudioConfig.Sfx key or alias ("ui_click", "cash_big", "area_unlock", ...)
	@param opts PlayOptions?  position (3D), pitch, volume multipliers
]]
function Sound.play(key: string, opts: PlayOptions?)
	local name = canonical(key)
	local spec = AudioConfig.Sfx[name]
	if spec == nil then
		if not warned[name] then
			warned[name] = true
			warn(`[Sound] unknown sound key "{name}"`)
		end
		return
	end
	local id = SoundAssets.SfxIds[name] or 0
	if id <= 0 or enabled[spec.group] == false then
		return
	end
	local now = os.clock()
	if now - (lastPlayed[name] or -math.huge) < (spec.minInterval or 0.03) then
		return
	end
	lastPlayed[name] = now
	Sound.ensure()
	local options: PlayOptions = opts or {}
	local position = options.position
	local sound = if position ~= nil then voice3D(name, id, spec, position) else voice2D(name, id, spec)
	local variation = spec.pitchVar or 0
	sound.PlaybackSpeed = (options.pitch or 1) * (1 + random:NextNumber(-variation, variation))
	sound.Volume = spec.volume * (options.volume or 1)
	sound.TimePosition = 0
	sound:Play()
end

--[[
	Preloads only the hot keys (AudioConfig `preload`), off the calling thread. Everything else
	streams in on first play (keeps phone / console memory small).
]]
function Sound.preloadHot()
	Sound.ensure()
	local hot: { Instance } = {}
	for key, spec in AudioConfig.Sfx do
		local id = SoundAssets.SfxIds[key] or 0
		if spec.preload and id > 0 then
			table.insert(hot, voice2D(key, id, spec))
		end
	end
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(hot)
		end)
	end)
end

-- Keys already warmed by Sound.warm (each key is fetched at most once per session).
local warmed: { [string]: boolean } = {}

--[[
	Warms a feature's sounds on demand, right before they are needed, instead of at join (the
	join-time `preload` set stays small for phone / console memory, tests/audio caps it).
	Idempotent per key, off the calling thread, unknown / not-yet-uploaded keys are ignored.
	@param keys AudioConfig.Sfx keys (aliases resolve like Sound.play)
	Example (launch cinematic, owner R54): when the attack picker opens,
		Sound.warm({ "vo_three", "vo_two", "vo_one", "vo_launch" })
]]
function Sound.warm(keys: { string })
	Sound.ensure()
	local batch: { Instance } = {}
	for _, raw in keys do
		local key = canonical(raw)
		local spec = AudioConfig.Sfx[key]
		local id = SoundAssets.SfxIds[key] or 0
		if not warmed[key] and spec ~= nil and id > 0 then
			warmed[key] = true
			table.insert(batch, voice2D(key, id, spec))
		end
	end
	if #batch == 0 then
		return
	end
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(batch)
		end)
	end)
end

--[[
	Stops every playing 2D voice of `key` — a line that must be CUT when the next one starts (the
	launch announcer, owner R54: "three" is ~1.2 s long but the next beat comes after 1 s).
	No-op for keys never played; 3D emitters are left alone (positional SFX just finish).
	@param key AudioConfig.Sfx key or alias
	Example: Sound.stop("vo_three"); Sound.play("vo_two")
]]
function Sound.stop(key: string)
	local pool = voices2D[canonical(key)]
	if pool == nil then
		return
	end
	for _, sound in pool do
		if sound.IsPlaying then
			sound:Stop()
		end
	end
end

-- Debug counters.
function Sound.stats(): { voices: number, emitters: number }
	local count = 0
	for _, pool in voices2D do
		count += #pool
	end
	return { voices = count, emitters = #emitters }
end

return Sound
