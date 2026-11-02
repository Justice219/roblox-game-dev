--!strict
--[[
	audio_check_client.luau — PLAY-MODE verification of the game audio (eval_client_runtime,
	holding the B4 Studio lock). Proves: SoundController running, context rule, music streaming,
	every SFX key loads + plays (2D + one 3D), override crossfade, rebirth sting ducking, and the
	music / sfx settings end-to-end through the real SetSetting remote.
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local SoundController = (require :: any)(client.Audio.SoundController)
local Sound = (require :: any)(client.Audio.Sound)
local AudioConfig = (require :: any)(ReplicatedStorage.Shared.Config.AudioConfig)
local WorldLayout = (require :: any)(ReplicatedStorage.Shared.Config.WorldLayout)
local Remotes = (require :: any)(ReplicatedStorage.Shared.Net.Remotes)
SoundController.Init()
SoundController.Start()
local out = {}
local function add(line: string)
	table.insert(out, line)
end
local function music(): (Sound?, Sound?)
	return SoundService:FindFirstChild("SN_Music1") :: Sound?, SoundService:FindFirstChild("SN_Music2") :: Sound?
end
local function describe(s: Sound?): string
	if s == nil then
		return "nil"
	end
	return string.format(
		"%s playing=%s loaded=%s vol=%.2f t=%.1f",
		s.SoundId,
		tostring(s.IsPlaying),
		tostring(s.IsLoaded),
		s.Volume,
		s.TimePosition
	)
end
task.wait(4)
add("context=" .. tostring(SoundController.currentContext()))
local a, b = music()
add("A " .. describe(a))
add("B " .. describe(b))
-- context rule samples
local p1 = WorldLayout.plotOrigin(1)
add(
	string.format(
		"contextAt hub=%s event=%s plot1row1=%s plot1row4=%s ring=%s",
		tostring(SoundController.contextAt(Vector3.new(0, 5, 0), false)),
		tostring(SoundController.contextAt(Vector3.new(10, 5, 10), true)),
		tostring(SoundController.contextAt((p1 * CFrame.new(-30, 3, 60)).Position, false)),
		tostring(SoundController.contextAt((p1 * CFrame.new(30, 3, 360)).Position, false)),
		tostring(SoundController.contextAt(Vector3.new(0, 5, 250), false))
	)
)
-- every SFX key: play (2D), then check load
local keys = {}
for key in AudioConfig.Sfx do
	table.insert(keys, key)
end
table.sort(keys)
for _, key in keys do
	Sound.play(key, { volume = 0.15 })
	task.wait(0.05)
end
local root = Players.LocalPlayer.Character and Players.LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
if root then
	Sound.play("cash_big", { position = (root :: BasePart).Position + Vector3.new(6, 0, 0), volume = 0.2 })
end
task.wait(3)
local loaded, total, missing = 0, 0, {}
for _, s in (SoundService:FindFirstChild("SN_Sfx2D") :: Folder):GetChildren() do
	if s:IsA("Sound") then
		total += 1
		if s.IsLoaded then
			loaded += 1
		else
			table.insert(missing, s.Name)
		end
	end
end
add(
	string.format(
		"sfx 2D voices loaded %d/%d missing=[%s] stats=%s",
		loaded,
		total,
		table.concat(missing, ","),
		tostring(Sound.stats().voices) .. "/" .. tostring(Sound.stats().emitters)
	)
)
-- override crossfade
SoundController.setOverride("event")
task.wait(1.2)
a, b = music()
add("override event (mid-crossfade): A " .. describe(a) .. " | B " .. describe(b))
task.wait(2)
-- sting ducking
SoundController.playSting("rebirth")
task.wait(1.0)
local sting = SoundService:FindFirstChild("SN_MusicSting") :: Sound?
a, b = music()
add("sting " .. describe(sting) .. " | A " .. describe(a) .. " | B " .. describe(b))
SoundController.setOverride(nil)
-- settings end-to-end (server profile -> ProfileChanged -> groups)
Remotes.event("SetSetting"):FireServer("music", false)
Remotes.event("SetSetting"):FireServer("sfx", false)
task.wait(2)
local groupMusic = SoundService:FindFirstChild("SN_Music") :: SoundGroup?
local groupSfx = SoundService:FindFirstChild("SN_SFX") :: SoundGroup?
a, b = music()
add(
	string.format(
		"settings off: musicGroup=%.2f sfxGroup=%.2f A.playing=%s B.playing=%s",
		groupMusic and groupMusic.Volume or -1,
		groupSfx and groupSfx.Volume or -1,
		tostring(a and a.IsPlaying),
		tostring(b and b.IsPlaying)
	)
)
Remotes.event("SetSetting"):FireServer("music", true)
Remotes.event("SetSetting"):FireServer("sfx", true)
task.wait(2)
a, b = music()
add(
	string.format(
		"settings on: musicGroup=%.2f sfxGroup=%.2f A.playing=%s B.playing=%s",
		groupMusic and groupMusic.Volume or -1,
		groupSfx and groupSfx.Volume or -1,
		tostring(a and a.IsPlaying),
		tostring(b and b.IsPlaying)
	)
)
return table.concat(out, "\n")
