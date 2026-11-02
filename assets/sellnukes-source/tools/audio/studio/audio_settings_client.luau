--!strict
--[[
	audio_settings_client.luau — verifies SoundController's settings handling by firing the real
	ClientState.ProfileChanged with settings toggled (what the server's profile sync does once
	SettingsService handles SetSetting), then restores the real profile.
]]
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local client = Players.LocalPlayer.PlayerScripts.Client
local ClientState = (require :: any)(client.ClientState)
local Sound = (require :: any)(client.Audio.Sound)
local real = ClientState.profile
local function with(music: boolean, sfx: boolean)
	local copy = table.clone(real)
	copy.settings = table.clone(real.settings)
	copy.settings.music = music
	copy.settings.sfx = sfx
	ClientState.ProfileChanged:Fire(copy, { "settings" })
end
local function state(label: string): string
	local m = SoundService:FindFirstChild("SN_Music") :: SoundGroup
	local s = SoundService:FindFirstChild("SN_SFX") :: SoundGroup
	local u = SoundService:FindFirstChild("SN_UI") :: SoundGroup
	local a = SoundService:FindFirstChild("SN_Music1") :: Sound
	local b = SoundService:FindFirstChild("SN_Music2") :: Sound
	return string.format(
		"%s: music=%.2f sfx=%.2f ui=%.2f A=%s B=%s sfxEnabled=%s",
		label,
		m.Volume,
		s.Volume,
		u.Volume,
		tostring(a.IsPlaying),
		tostring(b.IsPlaying),
		tostring(Sound.isGroupEnabled("SFX"))
	)
end
local out = { state("start") }
with(false, false)
task.wait(0.5)
table.insert(out, state("off"))
with(true, true)
task.wait(2.5)
table.insert(out, state("on"))
ClientState.ProfileChanged:Fire(real, { "settings" })
return table.concat(out, "\n")
