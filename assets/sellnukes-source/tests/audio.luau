--!strict
--[[
	Game audio regressions (B4). Run:
		lune run tests/audio

	Loads the REAL src/shared/Config/{AudioConfig,SoundAssets}.luau and the SFX manifests, and
	proves:
	  1. Every AudioConfig.Sfx key has an uploaded id (SoundAssets.SfxIds > 0) and every synthesised
	     sound in assets/audio/{world,game}-sfx/manifest.json has a playback spec (nothing orphaned).
	  2. Specs are sane: group SFX/UI, volume 0..1, pitchVar 0..0.25, voices 1..4, a small hot
	     preload set (mobile memory, owner R11), aliases point at real keys.
	  3. Music: every context playlist / sting names an existing track; tracks have ids, titles,
	     credits and durations; group + track volumes 0..1; crossfade + context-check timings sane.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(label, 2)
	end
	checks += 1
end

local function load(path: string): any
	return luau.load(fs.readFile(path), { debugName = path, environment = { math = math, table = table } })()
end

local AudioConfig = load("src/shared/Config/AudioConfig.luau")
local SoundAssets = load("src/shared/Config/SoundAssets.luau")

-- 1. ids <-> specs
for key, spec in AudioConfig.Sfx do
	local id = SoundAssets.SfxIds[key]
	ok(type(id) == "number" and id > 0 and id % 1 == 0, `{key}: uploaded id`)
	ok(spec.group == "SFX" or spec.group == "UI", `{key}: group`)
	ok(spec.volume > 0 and spec.volume <= 1, `{key}: volume`)
	ok((spec.pitchVar or 0) >= 0 and (spec.pitchVar or 0) <= 0.25, `{key}: pitchVar`)
	ok((spec.voices or 2) >= 1 and (spec.voices or 2) <= 4, `{key}: voices`)
	ok((spec.minInterval or 0.03) > 0, `{key}: minInterval`)
end
for _, dir in { "assets/audio/world-sfx", "assets/audio/game-sfx" } do
	local manifest = serde.decode("json", fs.readFile(`{dir}/manifest.json`))
	for name in manifest do
		ok(AudioConfig.Sfx[name] ~= nil, `{dir}/{name}: synthesised but has no AudioConfig spec`)
	end
end
for key in SoundAssets.SfxIds do
	ok(AudioConfig.Sfx[key] ~= nil, `SfxIds.{key} has no playback spec`)
end

-- 2. aliases + hot set
for alias, target in AudioConfig.Aliases do
	ok(AudioConfig.Sfx[target] ~= nil and AudioConfig.Sfx[alias] == nil, `alias {alias} -> {target}`)
end
local hot = 0
for _, spec in AudioConfig.Sfx do
	if spec.preload then
		hot += 1
	end
end
ok(hot >= 3 and hot <= 12, `hot preload set should stay small, got {hot}`)
ok(AudioConfig.Emitters3D >= 4 and AudioConfig.Emitters3D <= 16, "3D emitter pool size")

-- 3. music
for name, volume in AudioConfig.Groups do
	ok(volume > 0 and volume <= 1, `group {name} volume`)
end
for _, required in { "hub", "early", "late", "event" } do
	ok(AudioConfig.Contexts[required] ~= nil and #AudioConfig.Contexts[required] >= 1, `context {required}`)
end
for name, list in AudioConfig.Contexts do
	for _, key in list do
		ok(SoundAssets.Music[key] ~= nil, `context {name} -> unknown track {key}`)
	end
end
for name, key in AudioConfig.Stings do
	local track = SoundAssets.Music[key]
	ok(track ~= nil and track.seconds <= 20, `sting {name} must be a short track`)
end
for key, track in SoundAssets.Music do
	ok(track.id > 0 and #track.title > 0 and #track.artist > 0 and #track.album > 0, `track {key} metadata`)
	ok(track.seconds > 0, `track {key} duration`)
end
ok(#SoundAssets.MusicLicence > 40, "licence statement present")
local music = AudioConfig.Music
ok(music.Volume > 0 and music.Volume <= 1 and music.StingVolume <= 1, "music volumes")
ok(music.Crossfade >= 0.5 and music.Crossfade <= 5, "crossfade seconds")
ok(music.ContextCheck >= 0.25, "context check is never per frame")
ok(music.DuckVolume > 0 and music.DuckVolume < 1, "duck factor")

print(`[audio] {checks} checks passed`)
