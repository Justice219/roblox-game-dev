--!strict
--[[
	FxSound — positional world sounds for the build-in + world FX, routed through the game-wide
	audio API (src/client/Audio/Sound.luau). Kept as a tiny adapter so the FX code reads naturally:

		FxSound.play("clack", part.Position, { pitch = 1.1 })

	Pooling, SoundGroups (SFX), pitch variation, minimum intervals, settings.sfx muting and the
	asset ids (SoundAssets.SfxIds: clack, whoosh, sparkle, kaching, pop, fanfare) all live in
	Sound / AudioConfig / SoundAssets.
]]

local Sound = require(script.Parent.Parent.Parent.Audio.Sound)

local FxSound = {}

export type PlayOptions = { pitch: number?, volume: number? }

--[[
	Plays a world sound at a position (3D, distance-attenuated).
	@param key string  AudioConfig.Sfx key
	@param position Vector3
	@param options PlayOptions?  pitch / volume multipliers
]]
function FxSound.play(key: string, position: Vector3, options: PlayOptions?)
	local opts: PlayOptions = options or {}
	Sound.play(key, { position = position, pitch = opts.pitch, volume = opts.volume })
end

return FxSound
