--!strict
--[[
	HatchAnimConfig — every tunable of the egg hatch cinematic (owner R49: "actually animate the egg
	opening animation, it's really bad right now"). Presentation numbers only: the server already
	rolled the pet (PetService); nothing here changes what a player gets.

	The beats of one egg (seconds; `Profiles.Normal`, scaled down by `Fast` / auto-hatch):
		Intro    the real 3D egg pops into its slot (scale overshoot)
		Idle     a gentle bob
		Wobble   `Rarity[rank].bursts` shake bursts that grow in strength AND speed with squash /
		         stretch; crack stage 1..3 (EggShards "Crack<k>") appears on three of the bursts
		         while rarity-coloured light leaks through (Neon crack cores, halo, rays)
		Squash   a crouch, then a stretch
		Burst    soft flash (R19: never blinding), the ShellTop cap + Shard chips fly off with
		         spin + gravity, the ShellBottom cup drops away
		Pop      the pet springs out with an overshoot bounce, then idles (PetAnim, R44)
		Banner   the stud rarity banner pops in under the pet; confetti + sparkles by rarity
	Mythic / Secret (`dramatic`): more bursts, the room darkens, the viewport jitters like a camera
	shake and the burst is gold. Reduced motion: a still egg cross-fades into the pet.

	Units: seconds, studs (3D), design px (UI), degrees (angles here; HatchAnim converts),
	transparency 0..1 means Roblox transparency (1 = invisible) unless the name says opacity.

	Connects to: Client/Pets/HatchAnim (pure timeline maths), UI/Screens/EggHatch/{HatchRevealScreen,
	HatchStage, HatchConfetti}, Client/Audio/Sound (stinger keys must be AudioConfig.Sfx keys —
	tests/hatch-anim.luau checks), Tycoon/Fx/FxQuality (per-tier budgets).

	Example:
		local beat = HatchAnimConfig.Rarity[5]  -- Legendary
		print(beat.bursts, HatchAnimConfig.Profiles.Fast.Stagger) --> 4 0.2
]]

-- One sound cue: an AudioConfig.Sfx key with pitch / volume multipliers and a delay (seconds)
-- after the beat it belongs to.
export type Cue = { key: string, pitch: number, volume: number, delay: number }

-- Per-rarity drama (indexed by PetConfig rarity rank 1 = Common .. 7 = Secret).
export type RarityBeat = {
	bursts: number, -- anticipation shake bursts (crack stages land on three of them)
	strength: number, -- wobble amplitude multiplier
	dramatic: boolean, -- Mythic / Secret: darker + longer build-up, viewport jitter, gold burst
	glow: number, -- 0..1 strength of the leaking light (crack glow, halo, rays)
	rays: boolean, -- rotating rays behind the egg already during the build-up
	raySpeed: number, -- degrees per second once revealed
	confetti: number, -- confetti pieces at High FX quality
	sparkles: number, -- twinkles around the pet at High FX quality
	gold: boolean, -- gold confetti + gold flash tint (Legendary+)
	chance: boolean, -- show the "1 in N" chance in the banner (Rare+)
	reveal: { Cue }, -- stinger at the burst (Sound.play keys)
}

-- Speed profile of the whole cinematic.
export type Profile = {
	Intro: number,
	Idle: number,
	BurstTime: number, -- one wobble burst
	BurstGrowth: number, -- each later burst is this much shorter (x per burst)
	Pause: number, -- rest between bursts (shrinks with BurstGrowth too)
	MaxBursts: number, -- cap of `Rarity.bursts` (fast hatch keeps it short)
	Squash: number,
	Pop: number,
	BannerDelay: number, -- after the burst
	Banner: number,
	Fly: number, -- how long the cap / shards fly
	IntroStagger: number, -- triple hatch: eggs pop in left to right this far apart
	Stagger: number, -- triple hatch: wobble start delay between eggs (worst rarity first)
	MinBurstGap: number, -- triple hatch: bursts at least this far apart
	Hold: number, -- reduced motion: egg shown still before the cross-fade
	Fade: number, -- reduced motion: cross-fade length
	AutoHold: number, -- auto / fast hatch: seconds on the result before it continues by itself
	MinReveal: number, -- a tap closes only this long after the last burst (no accidental close)
}

export type Tier = {
	shards: number, -- Shard pieces that fly (of 7)
	confetti: number, -- multiplier on Rarity.confetti
	sparkles: number, -- multiplier on Rarity.sparkles
	jitter: boolean, -- dramatic viewport jitter
}

local HatchAnimConfig = {}

-- Rank of the first rarity shown with its odds ("1 in 400") on the banner.
HatchAnimConfig.ChanceFromRank = 3

local function cue(key: string, pitch: number?, volume: number?, delay: number?): Cue
	local made: Cue = { key = key, pitch = pitch or 1, volume = volume or 1, delay = delay or 0 }
	-- Frozen through `any` so `made` keeps its writable Cue type for the checker.
	table.freeze(made :: any)
	return made
end

local RARITY: { RarityBeat } = {
	-- 1 Common
	{
		bursts = 3,
		strength = 1,
		dramatic = false,
		glow = 0.45,
		rays = false,
		raySpeed = 16,
		confetti = 12,
		sparkles = 4,
		gold = false,
		chance = false,
		reveal = { cue("ui_claim", 1.05, 0.9) },
	},
	-- 2 Uncommon
	{
		bursts = 3,
		strength = 1.05,
		dramatic = false,
		glow = 0.55,
		rays = false,
		raySpeed = 18,
		confetti = 18,
		sparkles = 6,
		gold = false,
		chance = false,
		reveal = { cue("ui_claim", 1.1, 1) },
	},
	-- 3 Rare
	{
		bursts = 3,
		strength = 1.12,
		dramatic = false,
		glow = 0.7,
		rays = true,
		raySpeed = 22,
		confetti = 28,
		sparkles = 9,
		gold = false,
		chance = true,
		reveal = { cue("sparkle", 1, 1), cue("sparkle", 1.25, 0.6, 0.28) },
	},
	-- 4 Epic
	{
		bursts = 3,
		strength = 1.2,
		dramatic = false,
		glow = 0.8,
		rays = true,
		raySpeed = 26,
		confetti = 38,
		sparkles = 12,
		gold = false,
		chance = true,
		reveal = { cue("sparkle", 0.95, 1), cue("ui_claim", 1.2, 0.8, 0.12), cue("sparkle", 1.3, 0.6, 0.32) },
	},
	-- 5 Legendary
	{
		bursts = 4,
		strength = 1.3,
		dramatic = false,
		glow = 0.9,
		rays = true,
		raySpeed = 32,
		confetti = 50,
		sparkles = 16,
		gold = true,
		chance = true,
		reveal = { cue("fanfare", 1, 0.9), cue("sparkle", 1.2, 0.8, 0.2), cue("sparkle", 1.4, 0.6, 0.45) },
	},
	-- 6 Mythic
	{
		bursts = 5,
		strength = 1.4,
		dramatic = true,
		glow = 1,
		rays = true,
		raySpeed = 38,
		confetti = 62,
		sparkles = 20,
		gold = true,
		chance = true,
		reveal = {
			cue("nuke_boom", 0.62, 0.45),
			cue("fanfare", 0.97, 1),
			cue("sparkle", 1.15, 0.9, 0.22),
			cue("sparkle", 1.4, 0.7, 0.5),
		},
	},
	-- 7 Secret
	{
		bursts = 5,
		strength = 1.5,
		dramatic = true,
		glow = 1,
		rays = true,
		raySpeed = 44,
		confetti = 72,
		sparkles = 24,
		gold = true,
		chance = true,
		reveal = {
			cue("nuke_boom", 0.55, 0.5),
			cue("fanfare", 0.92, 1),
			cue("sparkle", 1.1, 1, 0.2),
			cue("kaching", 1.25, 0.6, 0.4),
			cue("sparkle", 1.45, 0.8, 0.62),
		},
	},
}
for _, beat in RARITY do
	table.freeze(beat.reveal)
	table.freeze(beat)
end
HatchAnimConfig.Rarity = table.freeze(RARITY)

-- Sound cues of the build-up (rank-independent; `pitch` / `volume` grow per burst / stage).
HatchAnimConfig.Sounds = table.freeze({
	Intro = cue("pop", 1.2, 0.5), -- egg pops into its slot
	Wobble = cue("clack", 0.82, 0.45), -- every shake burst (+ WobblePitchStep per burst)
	WobblePitchStep = 0.07,
	Crack = cue("clack", 1.35, 0.8), -- every crack stage (+ CrackPitchStep per stage)
	CrackPitchStep = 0.12,
	Rumble = cue("whoosh", 0.55, 1.6), -- dramatic build-up start (a low swell)
	Burst = cue("hatch", 1, 1), -- the shell blows open
	BurstPop = cue("pop", 0.9, 0.8),
})

-- Speed profiles. Fast = the Settings "Fast Hatch" toggle and auto-hatch.
HatchAnimConfig.Profiles = table.freeze({
	Normal = table.freeze({
		Intro = 0.34,
		Idle = 0.4,
		BurstTime = 0.44,
		BurstGrowth = 0.92,
		Pause = 0.2,
		MaxBursts = 5,
		Squash = 0.26,
		Pop = 0.62,
		BannerDelay = 0.26,
		Banner = 0.38,
		Fly = 0.95,
		IntroStagger = 0.1,
		Stagger = 0.42,
		MinBurstGap = 0.34,
		Hold = 0.35,
		Fade = 0.35,
		AutoHold = 1.2,
		MinReveal = 0.45,
	}) :: Profile,
	Fast = table.freeze({
		Intro = 0.16,
		Idle = 0.08,
		BurstTime = 0.26,
		BurstGrowth = 0.92,
		Pause = 0.07,
		MaxBursts = 3,
		Squash = 0.14,
		Pop = 0.42,
		BannerDelay = 0.12,
		Banner = 0.24,
		Fly = 0.7,
		IntroStagger = 0.05,
		Stagger = 0.2,
		MinBurstGap = 0.16,
		Hold = 0.2,
		Fade = 0.22,
		AutoHold = 0.9,
		MinReveal = 0.25,
	}) :: Profile,
})

-- Egg motion (studs / degrees / Hz).
HatchAnimConfig.Egg = table.freeze({
	IntroFrom = 0.25, -- intro scale start (pops to 1 with an overshoot)
	BobHeight = 0.07, -- idle bob amplitude
	BobPeriod = 1.1,
	WobbleDegrees = 7, -- burst 1 peak roll; later bursts grow by WobbleGrowth each
	WobbleGrowth = 0.55,
	WobbleHz = 3.4, -- burst 1 shake frequency; later bursts faster by HzGrowth each
	HzGrowth = 0.3,
	LeanRatio = 0.35, -- forward / back lean as a fraction of the roll (a livelier wobble)
	HopHeight = 0.14, -- little hop at the start of every burst (x burst strength)
	WobbleSquash = 0.06, -- squash / stretch while shaking (fraction of height)
	CrouchScale = 0.78, -- squash beat: lowest Y scale ...
	CrouchAt = 0.62, -- ... reached at this fraction of the squash beat
	StretchScale = 1.14, -- ... then stretched to this at the burst
	RestYaw = 12, -- three-quarter view of the decorated face
})

-- Shell pieces after the burst (studs, studs/s, rad/s, studs/s²).
HatchAnimConfig.Shell = table.freeze({
	Gravity = 24,
	CapVelocity = Vector3.new(1.4, 8.2, -2.6), -- the ShellTop cap: up, toward the camera, aside
	CapSpin = Vector3.new(-5.2, 1.4, 3.1), -- rad/s about X / Y / Z (tips back over its hinge)
	CupDrop = 0.55, -- the ShellBottom cup sinks this far ...
	CupShrink = 0.82, -- ... shrinking to this scale ...
	CupTip = 14, -- ... tipping this many degrees
	CupTime = 0.5, -- seconds
	-- Outward speed range (studs/s): chips fade out before they reach the viewport's edge (its
	-- rectangle clips them), ~4 studs from the egg at the camera distance used.
	ShardSpeed = Vector2.new(4.2, 6.6),
	ShardLift = Vector2.new(4.5, 7.5), -- upward speed range
	ShardSpin = Vector2.new(7, 15), -- spin range (rad/s)
	FadeFrom = 0.55, -- fraction of Fly after which pieces fade out
})

-- Pet pop (the spring is a damped cosine: 1 - e^(-Damping u) cos(Frequency u)).
HatchAnimConfig.Pet = table.freeze({
	From = 0.2, -- start scale (inside the egg)
	Damping = 5.5,
	Frequency = 11,
	JumpHeight = 0.95, -- studs: the pet jumps out of the cup ...
	JumpPart = 0.55, -- ... during this fraction of the Pop beat, then lands
	RestYaw = 15,
	HappyAfter = 0.1, -- seconds after the pop settles: the PetAnim happy spin
})

-- Light: halo discs, rays, flash, crack glow, room dim, viewport ambient (opacities 0..1).
HatchAnimConfig.Light = table.freeze({
	HaloStage = { 0.18, 0.36, 0.55 }, -- halo strength per crack stage (x Rarity.glow)
	HaloBurst = 1, -- at the burst ...
	HaloRest = 0.5, -- ... settling here behind the pet
	HaloDiscOpacity = 0.2, -- each of the halo's stacked discs (4 stack to ~0.6 at the centre)
	RayOpacity = 0.75, -- revealed rays (R19 soft)
	RayBuildOpacity = 0.4, -- build-up rays (Rarity.rays)
	RayScaleBuild = 0.75, -- ray size before / after the burst (x slot ray size)
	RayScaleRest = 1.2,
	RayBuildSpeed = 14, -- degrees per second during the build-up
	FlashPeak = 0.62, -- soft flash peak opacity (owner R19: never blinding)
	FlashRise = 0.05,
	FlashFall = 0.45,
	FlashTint = 0.35, -- Rare+: flash colour lerped this far toward the rarity colour
	WashPeak = 0.1, -- full-screen wash opacity at the burst, + WashPerRank x rank
	WashPerRank = 0.025,
	CrackFadeIn = 0.08, -- a crack stage fades in this fast
	CrackPulseHz = 2.2, -- crack glow pulse
	DimBase = 0.38, -- room dim transparency
	DimDramatic = 0.12, -- dramatic build-up darkens the room to this
	DimReveal = 0.3, -- after the burst
	AmbientCracked = 0.72, -- viewport ambient factor once cracked (Neon cracks pop)
	AmbientDramatic = 0.42,
	JitterPixels = 7, -- dramatic viewport jitter at the end of the build-up
	JitterBurst = 5, -- jitter kick at a Legendary+ burst, decaying over JitterDecay
	JitterDecay = 0.35,
})

-- Banner (stud panel under the pet).
HatchAnimConfig.Banner = table.freeze({
	From = 0.3, -- pop-in start scale
	Damping = 6,
	Frequency = 12,
})

-- Confetti + sparkles (design px, px/s, px/s², degrees/s, seconds).
HatchAnimConfig.Confetti = table.freeze({
	Pool = 96, -- pooled pieces (built once with the screen)
	Speed = Vector2.new(360, 760),
	Spread = 70, -- degrees either side of straight up
	Gravity = 980,
	Drag = 0.9, -- velocity kept per second (air drag)
	Spin = Vector2.new(180, 720),
	Life = Vector2.new(1.3, 2),
	Size = Vector2.new(10, 18),
	SparkleLife = Vector2.new(0.5, 1),
	SparkleRadius = 150, -- twinkles around the pet within this radius
	SparkleSize = Vector2.new(14, 26),
	Gold = table.freeze({ Color3.fromRGB(255, 214, 64), Color3.fromRGB(255, 240, 160), Color3.fromRGB(240, 170, 40) }),
	Party = table.freeze({
		Color3.fromRGB(255, 92, 140),
		Color3.fromRGB(84, 200, 255),
		Color3.fromRGB(120, 230, 110),
		Color3.fromRGB(255, 214, 64),
		Color3.fromRGB(190, 120, 255),
	}),
})

-- FxQuality budgets (Tycoon/Fx/FxQuality tiers).
HatchAnimConfig.Tiers = table.freeze({
	Low = table.freeze({ shards = 4, confetti = 0.35, sparkles = 0.4, jitter = true }) :: Tier,
	Mid = table.freeze({ shards = 7, confetti = 0.65, sparkles = 0.7, jitter = true }) :: Tier,
	High = table.freeze({ shards = 7, confetti = 1, sparkles = 1, jitter = true }) :: Tier,
})

-- Generic shard / crack overlay (tools/blender/models/egg_shards.py).
HatchAnimConfig.ShardsKey = "EggShards"
HatchAnimConfig.ShardCount = 7
HatchAnimConfig.CrackStages = 3

return table.freeze(HatchAnimConfig)
