--!strict
--[[
	JuiceController — boots the R71 juice pass and runs the purchase / unlock / rebirth / finale
	celebrations (owner: "better sound effects, more visual effects … retention max"). Cosmetic
	only; Nuke Town's areas, pads, prices and pacing are untouched.

	What it adds (everything pooled, FxQuality-budgeted, Reduce Motion aware):
		pad buy      WorldFxController.PadPressed -> a burst of tumbling cash sprites + sparkles at
		             the pad (its sound "pad_buy" + "ka-ching" play in WorldFxController)
		area unlock  your own new area's base finished building in (BuildInController.BuildFinished,
		             isAreaBase + isBuyer) -> fireworks over it + a camera punch (the fanfare + confetti
		             stay in WorldFxController)
		finale       your world's finale statue finished building in (the pad whose feature is
		             "Rebirth": TycoonConfig.FinalePadId / every world's economy.FinalePadId) -> a
		             confetti cannon (three volleys), fireworks, "fanfare", a punch
		rebirth      the profile's total rebirths (main + every world) went up -> a soft white flash,
		             fireworks around you and a punch; a world rebirth also plays the rebirth sting
		             (SoundController already plays it for Nuke Town rebirths)
		+ boots ProducerJuice (upgrade glow, milestone banner, manager puff, ambient sparkles) and
		  registers JuiceBanner's screens; ClickCombo is driven by ProducerBillboards.click.
	Reduce Motion: no fireworks rockets, punches or flash — a sparkle burst + the sounds instead.

	Boot: controller contract Init() / Start() (init.client.luau, after WorldFxController).

	Connects to: Client/Tycoon/Fx/{WorldFxController, Fireworks, JuiceParticles, JuiceBanner,
	ProducerJuice, CameraPunch, Confetti, FxQuality, FxSound, JuiceRules},
	Tycoon/BuildIn/BuildInController, Client/{ClientState, Audio/SoundController},
	UI/Widgets/OfferFx, Shared/Config/{JuiceConfig, TycoonConfig, Worlds/WorldsConfig}.

	Example: JuiceController.celebrateRebirth() -- Studio probe
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BuildInConfig = require(ReplicatedStorage.Shared.Config.BuildInConfig)
local BuildInController = require(script.Parent.Parent.BuildIn.BuildInController)
local CameraPunch = require(script.Parent.CameraPunch)
local ClickCombo = require(script.Parent.ClickCombo)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Confetti = require(script.Parent.Confetti)
local Fireworks = require(script.Parent.Fireworks)
local FxQuality = require(script.Parent.FxQuality)
local FxSound = require(script.Parent.FxSound)
local JuiceBanner = require(script.Parent.JuiceBanner)
local JuiceConfig = require(ReplicatedStorage.Shared.Config.JuiceConfig)
local JuiceParticles = require(script.Parent.JuiceParticles)
local JuiceRules = require(script.Parent.JuiceRules)
local OfferFx = require(script.Parent.Parent.Parent.UI.Widgets.OfferFx)
local PlotWatcher = require(script.Parent.PlotWatcher)
local ProducerJuice = require(script.Parent.ProducerJuice)
local Sound = require(script.Parent.Parent.Parent.Audio.Sound)
local SoundController = require(script.Parent.Parent.Parent.Audio.SoundController)
local WorldFxController = require(script.Parent.WorldFxController)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local JuiceController = {}

-- Juice sounds fetched right after boot so the first combo / purchase never waits on a download.
local WARM_KEYS: { string } = {
	JuiceConfig.Combo.Sound,
	JuiceConfig.Combo.BigSound,
	JuiceConfig.PadBuy.Sound,
	JuiceConfig.Milestone.Sound,
	JuiceConfig.Fireworks.WhistleSound,
	JuiceConfig.Fireworks.PopSound,
	JuiceConfig.Manager.Sound,
}

local started = false
local lastRebirths: number? = nil
local lastMainRebirths: number? = nil
local finalePads: { [string]: boolean } = {}

-- Every world's finale pad id (the statue whose feature is "Rebirth").
local function collectFinalePads()
	for _, id in WorldsConfig.Order do
		local def = WorldsConfig.get(id)
		local economy: any = if def ~= nil then def.economy else nil
		if economy ~= nil and type(economy.FinalePadId) == "string" and economy.FinalePadId ~= "" then
			finalePads[economy.FinalePadId] = true
		end
	end
end

-- The top centre of a model's bounding box (+ lift studs).
local function topOf(model: Model, lift: number): Vector3
	local ok, cf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok then
		return cf.Position + Vector3.new(0, size.Y / 2 + lift, 0)
	end
	return model:GetPivot().Position + Vector3.new(0, lift, 0)
end

-- The ground point under a model's bounding box centre.
local function baseOf(model: Model): Vector3
	local ok, cf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok then
		return cf.Position - Vector3.new(0, size.Y / 2, 0)
	end
	return model:GetPivot().Position
end

--[[
	A fireworks show (full motion) or, with Reduce Motion, one sparkle burst + the pop.
	@param ground launch centre (ground level)
	@param rockets rockets at the High tier budget already picked by the caller
]]
local function fireworks(ground: Vector3, rockets: number)
	local tier = FxQuality.tier()
	if OfferFx.reducedMotion() then
		local top = ground + Vector3.new(0, JuiceConfig.Fireworks.Height * 0.6, 0)
		Confetti.burst(top, 0, JuiceRules.perTier(JuiceConfig.Fireworks.Sparks, tier))
		FxSound.play(JuiceConfig.Fireworks.PopSound, top, { volume = JuiceConfig.Fireworks.PopVolume })
		return
	end
	Fireworks.show(ground, rockets, JuiceRules.perTier(JuiceConfig.Fireworks.Sparks, tier))
end

-- Pad bought near the camera: tumbling cash sprites + sparkles.
local function onPadPressed(_model: Model, position: Vector3)
	if OfferFx.reducedMotion() then
		return
	end
	local tier = FxQuality.tier()
	JuiceParticles.coins(
		position + Vector3.new(0, JuiceConfig.PadBuy.Rise, 0),
		JuiceRules.perTier(JuiceConfig.PadBuy.Coins, tier),
		JuiceRules.perTier(JuiceConfig.PadBuy.Sparkles, tier)
	)
end

-- A build finished flying in: your area unlock -> fireworks + punch; your finale -> cannon.
local function onBuildFinished(model: Model, info: PlotWatcher.BuildInfo)
	if not info.isBuyer or info.age > BuildInConfig.FreshWindow then
		return
	end
	local tier = FxQuality.tier()
	if info.isAreaBase then
		fireworks(baseOf(model), JuiceRules.perTier(JuiceConfig.AreaUnlock.Rockets, tier))
		task.delay(JuiceConfig.AreaUnlock.PunchDelay, CameraPunch.punch, JuiceConfig.AreaUnlock.Punch)
		return
	end
	local padId = info.padId
	if padId == nil or not finalePads[padId] then
		return
	end
	JuiceController.celebrateFinale(model)
end

--[[
	The finale statue's confetti cannon: Finale.Volleys confetti volleys rising over the statue,
	fireworks, the fanfare and a punch (Reduce Motion: one sparkle burst + the fanfare).
	@param model the finale build
]]
function JuiceController.celebrateFinale(model: Model)
	local Finale = JuiceConfig.Finale
	local top = topOf(model, 3)
	FxSound.play("fanfare", top)
	local tier = FxQuality.tier()
	if OfferFx.reducedMotion() then
		Confetti.burst(top, 0, JuiceRules.perTier(Finale.Sparkles, tier))
		return
	end
	local confetti = JuiceRules.perTier(Finale.Confetti, tier)
	local sparkles = JuiceRules.perTier(Finale.Sparkles, tier)
	for volley = 0, Finale.Volleys - 1 do
		task.delay(volley * Finale.VolleyGap, function()
			Confetti.burst(top + Vector3.new(0, volley * 3, 0), confetti, sparkles)
			FxSound.play(JuiceConfig.Fireworks.PopSound, top, { volume = 0.5 })
		end)
	end
	fireworks(baseOf(model), JuiceRules.perTier(Finale.Rockets, tier))
	CameraPunch.punch(Finale.Punch)
end

--[[
	The rebirth celebration: soft white flash, fireworks around the character, a punch.
	(The rebirth sting is SoundController's.) Callable from Studio probes.
]]
function JuiceController.celebrateRebirth()
	local Rebirth = JuiceConfig.Rebirth
	JuiceBanner.flash()
	local character = Players.LocalPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") then
		local ground = root.Position + root.CFrame.LookVector * 18 - Vector3.new(0, 3, 0)
		fireworks(ground, JuiceRules.perTier(Rebirth.Rockets, FxQuality.tier()))
	end
	CameraPunch.punch(Rebirth.Punch)
end

-- Profile pushes: a rise of the total rebirth count (any world) is a rebirth.
local function onProfile(profile: ClientState.Profile, fields: { string }?)
	if fields ~= nil and table.find(fields, "rebirths") == nil and table.find(fields, "worlds") == nil then
		return
	end
	local total = JuiceRules.rebirthTotal(profile)
	local main = if type(profile.rebirths) == "number" then profile.rebirths else 0
	local previous, previousMain = lastRebirths, lastMainRebirths
	lastRebirths, lastMainRebirths = total, main
	if fields == nil or previous == nil or total <= previous then
		return -- a snapshot (join / resync) only records the baseline
	end
	JuiceController.celebrateRebirth()
	if previousMain ~= nil and main <= previousMain then
		-- A world rebirth: SoundController only stings Nuke Town's, so play it here.
		SoundController.playSting("rebirth")
	end
end

function JuiceController.Init() end

--[[ Wires the celebrations + boots the producer juice (once). ]]
function JuiceController.Start()
	if started then
		return
	end
	started = true
	collectFinalePads()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	JuiceBanner.register(playerGui)
	ProducerJuice.start()
	WorldFxController.PadPressed:Connect(onPadPressed)
	BuildInController.BuildFinished:Connect(onBuildFinished)
	ClientState.ProfileChanged:Connect(onProfile)
	local profile = ClientState.profile
	if profile ~= nil then
		onProfile(profile, nil)
	end
	-- Warm the juice sounds off-thread (not in the join preload set: tests/audio caps it at 12).
	Sound.warm(WARM_KEYS)
	-- Build every pool up front, off the boot path (a few dozen Instances once; no first-use hitch).
	task.defer(function()
		ClickCombo.prewarm()
		JuiceParticles.prewarm()
		Fireworks.prewarm()
		ProducerJuice.prewarm()
	end)
end

return JuiceController
