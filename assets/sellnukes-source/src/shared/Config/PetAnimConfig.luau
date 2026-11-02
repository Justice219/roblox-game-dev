--!strict
--[[
	PetAnimConfig — every tunable of the procedural pet animation (owner R44: "make sure all of the
	pets have animations and stuff too"). Pure data: Client/Pets/PetAnim reads it to pose a pet,
	Client/Pets/{PetController, PetViewport, PetEmotes} read the per-device budgets.

	How a pet moves (see docs/pets.md "Animation"):
		* Every species is rigged from its piece names (B8f art contract, docs/pets-art.md §1):
		  `Head*` / `Tail*` / `WingL*` / `WingR*` / `ClawL*` / `ClawR*` / `Orbit*` groups rotate about
		  the joints in the MeshAssets pivot string; everything else is the rigid body.
		* The body STYLE is derived (claws -> Scuttle, hover + wings -> Fly, hover -> Float, else
		  Walk); `Species` overrides only the few that need it (hoppers, swimmers, tail axes).
		* Layers: style locomotion (scaled by how fast the pet moves) + idle (breathe, look around,
		  random cute actions) + events (happy spin + hearts, sleepy Zzz).
	Angles are DEGREES here (PetAnim converts), distances studs, rates cycles per second.

	Example:
		local walk = PetAnimConfig.Motion.Walk
		print(walk.Bounce, PetAnimConfig.Tiers.Mid.FullRange)
]]

export type Style = "Walk" | "Hop" | "Blob" | "Fly" | "Swim" | "Float" | "Scuttle"
export type TailAxis = "Yaw" | "Pitch" | "Roll" | "Sway"
export type Action = "Sit" | "Spin" | "Hop" | "Swoop" | "Flip" | "Wave" | "Jiggle"

-- Per-species overrides (MeshAssets key → fields); anything missing is derived from the rig.
export type SpeciesOverride = {
	style: Style?,
	tailAxis: TailAxis?, -- how the Tail group swings (default Yaw = side-to-side wag)
	jiggle: number?, -- multiplier of the Float / Blob jelly pulse (default 1)
}

-- Per-device budget (FxQuality tier, owner R11: hold frame rate on a low-end phone).
export type Tier = {
	FullRange: number, -- studs (camera → owner): full animation within this
	SimpleRange: number, -- body bob + wings only within this; beyond: rigid (no pose math)
	MaxFull: number, -- most pets fully animated at once (nearest owners first, yours first)
	Viewports: number, -- most pet viewports (inventory cards, reveal) animated at once
	ViewportHz: number, -- viewport animation tick rate
	Hearts: number, -- pooled heart bursts
	Zzz: number, -- pooled sleep bubbles
	EmoteRange: number, -- studs: hearts / Zzz for other players' pets only within this
}

local PetAnimConfig = {}

-- Detail levels a pet is animated at (PetAnim.Detail mirrors these numbers).
PetAnimConfig.Detail = table.freeze({ Off = 0, Simple = 1, Full = 2 })

local SPECIES: { [string]: SpeciesOverride } = {
	-- Blobs / hoppers: bouncy hops with big squash-stretch instead of a waddle.
	GlowSlime = { style = "Blob" },
	UraniumBunny = { style = "Hop" },
	AcornSquirrel = { style = "Hop" },
	GoldenNukey = { style = "Hop" },
	-- R78 Golden Nukey (pet_golden_nukey.py): the lobby mascot as a chibi stands on its fins like
	-- the older GoldenNukey, so it hops (no Head group: its face IS the body; the sparkle ring spins).
	SparkleNukey = { style = "Hop" },
	-- Swimmers float at their hover height, undulate and paddle their flippers.
	NuclearNarwhal = { style = "Swim", tailAxis = "Pitch" },
	AtomicAxolotl = { style = "Swim" },
	-- The jelly's "Tail" is its tentacle skirt: a slow circular sway, not a wag.
	IonJelly = { tailAxis = "Sway" },
	-- A floating cat: drifts like a floater but barely jiggles.
	VoidCat = { jiggle = 0.2 },
	-- The beaver thumps its flat tail up and down; the turkey fans its tail.
	BuilderBeaver = { tailAxis = "Pitch" },
	GobbleBomb = { tailAxis = "Roll" },
	-- World 3 Moon Base (owner R70, pets_moon.py): the bunny hops, the sky-whale swims and thumps its
	-- fluke like the narwhal, and the octopus's tentacle skirt under its saucer sways like the jelly.
	MoonBunny = { style = "Hop" },
	GalaxyWhale = { style = "Swim", tailAxis = "Pitch" },
	SaucerOcto = { tailAxis = "Sway" },
}
for _, row in SPECIES do
	table.freeze(row)
end
PetAnimConfig.Species = table.freeze(SPECIES)

-- Exact piece names whose Size squashes with the body (the big body shells); every other piece
-- only moves (positions compress about the pivot) so heads sink in and feet spread.
local SQUASH_PIECES: { [string]: boolean } = {
	Body = true,
	Belly = true,
	Band = true,
	Spikes = true,
	Limbs = true,
	Collar = true,
	Fins = true,
}
PetAnimConfig.SquashPieces = table.freeze(SQUASH_PIECES)

-- Piece names containing this pulse their Transparency softly (owner R19: never brighter).
PetAnimConfig.GlowToken = "Glow"

PetAnimConfig.Motion = table.freeze({
	MaxDt = 0.1, -- s: longer frames are clamped (hitches never fling a pose)
	MoveSpeedRef = 12, -- studs/s counted as a full stride (the owner walks at 16)
	MoveDeadzone = 0.6, -- studs/s below which the pet is standing
	MoveBlendRate = 7, -- smoothing of the stride blend (1/s)
	TurnSmoothing = 8, -- smoothing of the turn rate used for banking / head lead (1/s)
	HeadLead = 0.22, -- s of turn rate the head looks ahead into a turn
	HeadLeadMax = 28, -- deg

	Walk = table.freeze({
		StrideLength = 1.35, -- studs per step
		MaxStepRate = 7, -- steps/s cap (faster owners → longer strides, not a frantic blur)
		Bounce = 0.26, -- studs of hop per step
		Waddle = 9, -- deg side-to-side rock (alternates every step)
		Lean = 6, -- deg forward lean at full stride
		Squash = 0.14, -- landing squash (fraction of height)
		Stretch = 0.07, -- mid-step stretch
		HeadBob = 5, -- deg nod, twice per step
		WingFlap = 16, -- deg (ducks flap a little while they waddle)
	}),
	Hop = table.freeze({
		HopLength = 2.4, -- studs per hop
		MinRate = 2.2, -- hops/s while moving at all
		MaxRate = 3.4, -- hops/s cap (faster → longer leaps)
		Height = 0.72,
		Tilt = 10, -- deg nose-up at take-off, nose-down on landing
		Squash = 0.22,
		Stretch = 0.14,
	}),
	Blob = table.freeze({
		Jiggle = 0.05, -- idle wobble (fraction of height)
		JiggleRate = 2.4,
	}),
	Fly = table.freeze({
		FlapRateIdle = 2.4,
		FlapRateMove = 4.2,
		FlapIdle = 28, -- deg
		FlapMove = 40,
		Bob = 0.12, -- studs of lift per wing beat
		Lean = 10,
		BankGain = 0.3, -- deg of bank per deg/s of turn
		BankMax = 26,
		TailSwing = 7,
	}),
	Swim = table.freeze({
		Rate = 0.75,
		RateMove = 1.5,
		Undulate = 4, -- deg body pitch wave
		TailSwing = 18,
		Flipper = 24,
		Bob = 0.14,
		Lean = 6,
		BankScale = 0.5, -- of Fly banking
	}),
	Float = table.freeze({
		Rate = 1.0,
		RateMove = 1.6,
		Pulse = 0.08, -- bell contraction (fraction of height)
		Tentacle = 10, -- deg
		Drift = 0.12, -- studs of lazy figure-eight drift
		Lean = 8,
		Bob = 0.14,
	}),
	Scuttle = table.freeze({
		StrideLength = 0.8,
		MaxStepRate = 9,
		Bounce = 0.08,
		Rock = 7,
		ClawRaise = 18,
		ClawSnip = 12,
		SnipRate = 3,
	}),
	Tail = table.freeze({
		Idle = 14, -- deg wag
		Move = 26,
		RateIdle = 1.4,
		RateMove = 3.6,
		HappyRate = 5,
	}),
	-- Airborne styles bob around their hover height (PetConfig.Follow BobRate / BobHeight).
	AirBobScale = 1,
	OrbitSpeed = 100, -- deg/s of the Neon atom rings
	Glow = table.freeze({
		Period = 1.8, -- s per pulse
		Amount = 0.22, -- added Transparency at the dim end (never brighter than at rest)
		Step = 0.02, -- quantisation: writes only when the level changes
	}),
	SizeEpsilon = 0.004, -- squash Size writes only when the scale changed this much
})

PetAnimConfig.Idle = table.freeze({
	BreathePeriod = 2.6, -- s
	Breathe = 0.035, -- fraction of height
	LookEvery = table.freeze({ 2.2, 4.8 }), -- s between new look targets (random in range)
	LookYaw = 35, -- deg
	LookPitch = 8,
	LookSharpness = 4,
	ActionEvery = table.freeze({ 6, 14 }), -- s between random cute actions
	MaxMoveForAction = 0.1, -- stride blend above which no new action starts
})

-- Random cute actions per style (the follower world) and in UI viewports (no big hops there).
local ACTIONS: { [Style]: { Action } } = {
	Walk = { "Sit", "Spin", "Hop" },
	Hop = { "Hop", "Spin", "Sit" },
	Blob = { "Jiggle", "Hop", "Spin" },
	Fly = { "Spin", "Swoop", "Flip" },
	Swim = { "Spin", "Flip" },
	Float = { "Jiggle", "Spin" },
	Scuttle = { "Wave", "Spin" },
}
local VIEWPORT_ACTIONS: { [Style]: { Action } } = {
	Walk = { "Sit", "Spin" },
	Hop = { "Sit", "Spin" },
	Blob = { "Jiggle", "Spin" },
	Fly = { "Spin", "Flip" },
	Swim = { "Spin", "Flip" },
	Float = { "Jiggle", "Spin" },
	Scuttle = { "Wave", "Spin" },
}
for _, list in ACTIONS do
	table.freeze(list)
end
for _, list in VIEWPORT_ACTIONS do
	table.freeze(list)
end
PetAnimConfig.Actions = table.freeze(ACTIONS)
PetAnimConfig.ViewportActions = table.freeze(VIEWPORT_ACTIONS)

local ACTION_DURATION: { [Action]: number } = {
	Sit = 2.4,
	Spin = 0.9,
	Hop = 0.9,
	Swoop = 1.4,
	Flip = 1.0,
	Wave = 1.6,
	Jiggle = 1.0,
}
PetAnimConfig.ActionDuration = table.freeze(ACTION_DURATION)
PetAnimConfig.ActionShape = table.freeze({
	SitPitch = 14, -- deg tilt back
	SitDrop = 0.08,
	SitLookUp = 8,
	SpinHop = 0.45, -- studs
	HopHeight = 0.55,
	SwoopDip = 0.5,
	SwoopPitch = 14,
	WaveRaise = 55,
	WaveWiggle = 15,
	Jiggle = 0.16,
	ViewportLift = 0.5, -- vertical offsets scale inside UI viewports (stay in frame)
})

-- Happy spin + hearts on the owner's purchase / hatch / equip.
PetAnimConfig.Happy = table.freeze({
	Duration = 1.15, -- s per spin
	Stagger = 0.09, -- s between team members (a little wave of spins)
	Height = 0.8, -- studs hop (ground pets)
	AirHeight = 0.45,
	FlapBoost = 1.6, -- wing beat multiplier while happy
	Landing = 0.16, -- squash on landing
	FreshBuild = 3, -- s: only purchases this fresh trigger it (not old builds streaming in)
	HatchFallback = 12, -- s: if the reveal never closes, celebrate anyway
	Hearts = 3, -- hearts per burst
	HeartsTime = 1.5, -- s
	HeartColor = Color3.fromRGB(255, 92, 142),
})

-- Sleepy when the owner is away.
PetAnimConfig.Sleep = table.freeze({
	After = 60, -- s without input / movement
	MoveStuds = 0.6, -- root movement between samples that counts as activity
	BlendRate = 1.2, -- per second (fall asleep / wake up over ~1 s)
	Drop = 0.12, -- studs (ground pets lie down)
	Flatten = 0.07,
	Droop = 20, -- deg head droop
	Curl = 35, -- deg tail curled round
	HoverDrop = 0.4, -- fraction of the hover height flyers sink
	BreatheSlow = 0.6, -- breathing period multiplier added while asleep
	ZzzPeriod = 2.4, -- s per Z
	ZzzColor = Color3.fromRGB(225, 236, 255),
})

-- Reduce Motion (profile setting): gentle idle only (no hops, spins or look-arounds).
PetAnimConfig.Reduced = table.freeze({
	Scale = 0.35, -- amplitude of the remaining wing / tail / bob motion
	OrbitScale = 0.3,
})

local TIERS: { [string]: Tier } = {
	-- Low: body bob + wings only for every pet (no head / tail / squash / glow / orbit work).
	Low = {
		FullRange = 0,
		SimpleRange = 60,
		MaxFull = 0,
		Viewports = 6,
		ViewportHz = 15,
		Hearts = 4,
		Zzz = 3,
		EmoteRange = 40,
	},
	Mid = {
		FullRange = 55,
		SimpleRange = 110,
		MaxFull = 14,
		Viewports = 16,
		ViewportHz = 30,
		Hearts = 10,
		Zzz = 8,
		EmoteRange = 70,
	},
	High = {
		FullRange = 90,
		SimpleRange = 160,
		MaxFull = 28,
		Viewports = 20,
		ViewportHz = 60,
		Hearts = 16,
		Zzz = 14,
		EmoteRange = 100,
	},
}

for _, tier in TIERS do
	table.freeze(tier)
end
PetAnimConfig.Tiers = table.freeze(TIERS)

-- Hard bounds the pose never leaves (tests/pet-anim.luau proves them for all species).
PetAnimConfig.Limits = table.freeze({
	MinY = -1, -- studs below the follow height
	MaxY = 2.5,
	MinScaleY = 0.72,
	MaxScaleY = 1.3,
	MinScaleX = 0.82,
	MaxScaleX = 1.2,
	MaxSway = 0.5, -- studs
	MaxJointAngle = 80, -- deg on any limb axis
})

return table.freeze(PetAnimConfig)
