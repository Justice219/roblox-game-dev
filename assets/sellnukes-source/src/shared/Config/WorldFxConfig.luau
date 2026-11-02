--!strict
--[[
	WorldFxConfig — data-driven world animation + sound table (client WorldFxController, server
	MeshLibrary tagging, BuildInController sounds).

	How pieces get animated (no code per model):
		Blender builders name animatable pieces with the words below (`Rotor`, `Belt`, `Glow`, ...).
		MeshLibrary.spawn tags every piece whose name resolves to an entry of `Pieces` with the
		CollectionService tag `WorldFxConfig.Tag`; WorldFxController animates tagged parts within
		range of the camera in ONE update loop. Resolution: exact name first, then `Aliases`, then the
		leading word of the name (`Rotor2`, `Rotor_Left` -> `Rotor`; `BeltA` -> `Belt`).

	Motions (all client-side, purely visual, on anchored visual pieces):
		spin       continuous rotation about a local axis at `speed` deg/s
		oscillate  back-and-forth rotation about a local axis, `amplitude` deg, `period` s
		bob        up-and-down along world Y, `amplitude` studs, `period` s
		scroll     moving stud texture along the part's local Z (conveyor belts), `speed` studs/s;
		           `faces` lists the faces carrying it (default { "Top" }; a waterfall adds "Front")
		none       no motion (light / particles only)
	Optional extras: `light` (PointLight, brightness pulsing by `pulse` fraction; only the tier's
	MaxLights nearest are enabled), `particles = "steam"` (soft white puffs), `sound` (a periodic
	row plays an AudioConfig SFX once per period at fraction `at`, e.g. a geyser's whoosh as it
	surges; only the tier's MaxSounds nearest moving sources, within `range`).
	Model ambience (`Ambience[modelKey]`): an occasional sound from a spawned model while it is
	near (the tamed volcano's soft rumble), sharing the same MaxSounds budget.

	Worlds (owner R57, Dino Valley): the rows below are world-agnostic (piece names decide); Dino
	art adds Flame (torches / fire pit: soft flicker light only), Ears (the mammoth fan), Sock (the
	wind sock), LavaFlow / LavaFall (scrolling lava; exact names only, so LavaCracks / LavaStreaks
	/ the Valley backdrop's Lava stay still), Wobble (incubator eggs) and, through Assemblies, the
	two D4 geyser jets (Column + ColumnFoam, keyed by model because Nuke Town A6 / A9 have static
	pieces called Column), the slower D4 water wheel (Wheel + WheelTrim) and the Time Machine's
	portal swirl (Hub_TimeMachine only: Shop_Teleporter's Swirl stays still).

	Example (an art builder adding a windmill): name the blade piece "Rotor" in Blender — done.
	Need a new behaviour? Add a row here, e.g. `Fan = { motion = "spin", axis = "Z", speed = 240 }`.
]]

export type Motion = "spin" | "oscillate" | "bob" | "scroll" | "swing" | "none"
export type Axis = "X" | "Y" | "Z"

export type LightFx = {
	color: Color3?, -- default: the piece's own colour
	range: number,
	brightness: number,
	pulse: number?, -- 0..1 brightness swing
	flicker: boolean?, -- noisy flame flicker instead of a smooth pulse (same `pulse` bound)
}

-- A periodic row's sound: plays once per motion period when the cycle passes `at` (owner R57).
export type SoundFx = {
	key: string, -- AudioConfig.Sfx key
	at: number, -- fraction of the period (0..1); bob: 0 = rising through the middle, 0.25 = top
	range: number, -- studs from the camera (beyond: silent)
	volume: number?,
}

-- A model's occasional ambience sound (Ambience below).
export type AmbientSound = {
	key: string, -- AudioConfig.Sfx key
	interval: number, -- mean seconds between plays
	jitter: number, -- +- seconds of random spread (never a metronome)
	range: number, -- studs from the camera (beyond: silent)
	volume: number?,
}

--[[
	Owner R75 "swing" motion (the Glow Rock miners' pickaxes): a keyframed angle loop about `axis`
	(Shared/World/SwingCurve: { t = 0..1 of the period, angle = degrees, ease = "in" | "out" |
	"inout" }). Swing groups of one model share ONE phase (the arm and the body lean stay in step),
	different models get different phases (each miner on its own beat).
]]
export type SwingKey = { t: number, angle: number, ease: string? }
-- Reduce Motion's replacement for a swing: a slow small sine sway, no impact.
export type GentleFx = { amplitude: number, period: number }
-- The impact sound: a short 3D one-shot, budgeted with the other world-FX sounds (MaxSounds).
export type ImpactSound = { key: string, range: number, volume: number?, pitch: number? }
--[[
	A swing's impact (the pick hitting the rock), once per loop as the cycle passes `at`: a pooled
	particle burst (`burst` = a WorldFxConfig.Bursts kind, scaled by the tier's Bursts, none on Low
	or under Reduce Motion), the sound, and a `flash` (seconds) of the model's glow lights at their
	pulse maximum (still inside the R19 caps). Only within `range` studs of the camera, on screen.
]]
export type ImpactFx = { at: number, range: number, burst: string?, sound: ImpactSound?, flash: number? }

export type PieceFx = {
	motion: Motion,
	axis: Axis?,
	speed: number?,
	amplitude: number?,
	period: number?,
	light: LightFx?,
	particles: "steam"?,
	faces: { string }?, -- scroll: Enum.NormalId names carrying the moving texture (default Top)
	sound: SoundFx?,
	keys: { SwingKey }?, -- swing: the keyframed loop
	gentle: GentleFx?, -- swing: Reduce Motion sway (a swing without one rests under Reduce Motion)
	impact: ImpactFx?, -- swing: the strike event
}

local WorldFxConfig = {}

-- CollectionService tag MeshLibrary puts on animatable pieces (server-side, replicated).
WorldFxConfig.Tag = "WorldFx"

-- Seconds between distance re-rankings (never per frame).
WorldFxConfig.RefreshInterval = 0.5

export type FxBudget = {
	Range: number, -- animate only pieces within this many studs of the camera
	MaxMoving: number, -- hard cap on moving pieces per frame (nearest first)
	MaxLights: number, -- PointLights enabled at once (nearest first; lights are costly)
	MaxEmitters: number, -- steam emitters active at once (nearest first)
	-- Moving groups farther than this update every other frame (staggered; motion is time-based,
	-- so a far rotor at 30 Hz looks the same and costs half the BulkMoveTo work).
	HalfRateBeyond: number,
	MaxSounds: number, -- world-FX sound sources (row sounds + model ambience) audible at once
	-- Impact bursts (owner R75 pick strikes): particle-count scale; 0 = no bursts or impact sounds
	-- (Low: the swing only).
	Bursts: number,
}

-- Per-frame view culling (perf pass 2026-10-30): a moving group whose centre is outside the camera
-- cone (frustum diagonal + ViewMarginDeg) holds its pose instead of moving; groups within
-- AlwaysMoveWithin studs always move (big pieces next to the camera). See Shared/Util/ViewCone.
WorldFxConfig.ViewMarginDeg = 20
WorldFxConfig.AlwaysMoveWithin = 60

-- Light caps (owner R19: "when you do anything glowing, it's not overly bright"). Every `light`
-- row stays within these; tests/glow-budget.luau enforces them. Lights are also pulled toward
-- warm white and never cast shadows (WorldFxController).
WorldFxConfig.LightCaps = { Brightness = 0.6, Range = 10, Pulse = 0.2 }

-- Per-device budgets (owner R11: hold frame rate on a low-end phone). FxQuality picks the tier.
local TIERS: { [string]: FxBudget } = {
	Low = {
		Range = 140,
		MaxMoving = 48,
		MaxLights = 4,
		MaxEmitters = 2,
		HalfRateBeyond = 60,
		MaxSounds = 1,
		Bursts = 0,
	},
	Mid = {
		Range = 200,
		MaxMoving = 100,
		MaxLights = 8,
		MaxEmitters = 5,
		HalfRateBeyond = 100,
		MaxSounds = 2,
		Bursts = 0.7,
	},
	High = {
		Range = 260,
		MaxMoving = 160,
		MaxLights = 12,
		MaxEmitters = 8,
		HalfRateBeyond = 140,
		MaxSounds = 3,
		Bursts = 1,
	},
}
WorldFxConfig.Tiers = TIERS

local PIECES: { [string]: PieceFx } = {
	Rotor = { motion = "spin", axis = "Y", speed = 200 },
	Turbine = { motion = "spin", axis = "Z", speed = 320 },
	Fan = { motion = "spin", axis = "Z", speed = 260 },
	Wheel = { motion = "spin", axis = "X", speed = 120 },
	Dish = { motion = "oscillate", axis = "Y", amplitude = 55, period = 7 },
	Arm = { motion = "oscillate", axis = "X", amplitude = 22, period = 2.6 },
	Belt = { motion = "scroll", speed = 3 },
	Glow = {
		motion = "bob",
		amplitude = 0.3,
		period = 2.4,
		light = { range = 10, brightness = 0.5, pulse = 0.15 },
	},
	Core = { motion = "none", light = { range = 8, brightness = 0.5, pulse = 0.15 } },
	-- Crystals are often embedded in cave walls: they glow and pulse but never float.
	Crystal = { motion = "none", light = { range = 9, brightness = 0.45, pulse = 0.15 } },
	Liquid = { motion = "none", light = { range = 8, brightness = 0.55, pulse = 0.15 } },
	Bubbles = { motion = "bob", amplitude = 0.09, period = 0.7 },
	Bulb = { motion = "none", light = { range = 10, brightness = 0.6, pulse = 0.08 } },
	VentGlow = { motion = "none", light = { range = 6, brightness = 0.4, pulse = 0.2 } },
	Steam = { motion = "none", particles = "steam" },
	Nuke = { motion = "bob", amplitude = 0.2, period = 1.9 },
	Rocket = { motion = "bob", amplitude = 0.05, period = 0.35 },
	Door = { motion = "none" },
	-- Space elevator pod rides its column (B8d): 14 studs up and down every 12 s.
	Climber = { motion = "bob", amplitude = 14, period = 12 },
	-- Rocket engine flame: soft flickering light only (the piece itself follows its assembly).
	EngineGlow = { motion = "none", light = { range = 9, brightness = 0.55, pulse = 0.2, flicker = true } },
	-- Assembly-only rows (used through Assemblies below, never matched by a piece name alone).
	CarIdle = { motion = "bob", amplitude = 0.07, period = 1.4 },
	Hover = { motion = "bob", amplitude = 0.22, period = 2.3 },
	RocketIdle = { motion = "bob", amplitude = 0.18, period = 3 },
	-- Lobby centre ambient motion (owner R55, L1-lobby; tools/blender/models/hub_plaza.py). The
	-- words are unique to the hub pieces (no existing piece starts with them).
	Ripple = { motion = "bob", amplitude = 0.06, period = 1.3 }, -- fountain water rings
	-- Nukey's waving arm: the WaveArm / WaveGlove boxes are mirrored about the shoulder in Blender,
	-- so the piece turns about the joint (the piece CFrame = its bounding-box centre).
	Wave = { motion = "oscillate", axis = "Z", amplitude = 14, period = 1.7 },
	Streamer = { motion = "oscillate", axis = "Y", amplitude = 6, period = 3.4 }, -- banners twist in the wind
	Pennant = { motion = "oscillate", axis = "X", amplitude = 5, period = 2.6 }, -- bunting strings swing
	-- Slow spin: Moon M5 planet mobile / M6 nebula, Dino D6 (the R55 teleport-pad stars until owner R134).
	Twirl = { motion = "spin", axis = "Y", speed = 40 },
	Whirl = { motion = "spin", axis = "Y", speed = 110 }, -- floating coins
	Carousel = { motion = "spin", axis = "Y", speed = 20 }, -- coin halo orbiting over Nukey

	-- Dino Valley (owner R57; tools/blender/models/dino_area0N.py, docs/areas-art.md "For W10").
	-- D1 torch walls FlameA/B/C + fire pit FlameOuter/FlameInner, D5 / D6 arch torch Flame: a soft
	-- noisy flicker of a warm light, nothing moves (R19 caps: brightness 0.45 x (1 +- 0.2)).
	Flame = { motion = "none", light = { range = 8, brightness = 0.45, pulse = 0.2, flicker = true } },
	-- D2 mammoth fan: ONE piece holds both ears, its box centred on the head's vertical axis, so a
	-- swing about local Y sweeps the pair like a desk fan.
	Ears = { motion = "oscillate", axis = "Y", amplitude = 14, period = 1.6 },
	-- D3 wind sock: Sock + SockStripes (one group), boxes centred on the pole axis by a balance
	-- cube, so the sock swings round its pole in a lazy breeze.
	Sock = { motion = "oscillate", axis = "Y", amplitude = 30, period = 4.5 },
	-- D6 lava: the lava channel's troughs (LavaFlow, strips along local Z) and the lava falls'
	-- stream + fall ribbon (LavaFall: the top stream on Top, the cliff ribbon on its road-facing
	-- Front face) scroll a warm stud texture. Exact names only (no "Lava" row: the floor's
	-- LavaCracks, the cone's LavaStreaks and the Valley backdrop's Lava stay still).
	LavaFlow = { motion = "scroll", speed = 1.5 },
	LavaFall = { motion = "scroll", speed = 1.5, faces = { "Top", "Front" } },
	-- D5 incubators: the three eggs + their speckles (WobbleEgg*, WobbleSpots*) jiggle as one.
	Wobble = { motion = "bob", amplitude = 0.08, period = 0.7 },
	-- Assembly-only Dino rows (Assemblies below; no piece is named after them).
	-- Geyser jets surge on a 6 s cycle and whoosh as they rise (the jets start inside their
	-- mounds, so a 1.2 stud bob never shows a gap; W7).
	Geyser = {
		motion = "bob",
		amplitude = 1.2,
		period = 6,
		sound = { key = "geyser_whoosh", at = 0.02, range = 90, volume = 0.8 },
	},
	-- The D4 water wheel turns slower than Nuke Town's wheels (a big lazy paddle wheel).
	WaterWheel = { motion = "spin", axis = "X", speed = 40 },
	-- The Time Machine portal (lobby + Base Camp, W9): its two cyan swirl arms per face are
	-- rotationally symmetric about the ring centre, so the piece spins about its local Z.
	-- Assembly-only: the shop's Teleporter prop has a static piece called Swirl too.
	TimeSwirl = { motion = "spin", axis = "Z", speed = 90 },
	-- Moon Base Landing Plaza (owner R70, W9b): the comms antennas' tip bulb blinks softly (the
	-- strongest pulse the R19 caps allow; nothing moves). Assembly-only (Assemblies.Moon_Antenna).
	MoonBlink = { motion = "none", light = { range = 8, brightness = 0.5, pulse = 0.2 } },
	-- The Moon Rocket portal's star swirl (Assemblies.Hub_MoonRocket): the Time Machine's turn, but
	-- its own row so the Dino rows stay Dino-only (tests/world-fx "main unchanged").
	MoonSwirl = { motion = "spin", axis = "Z", speed = 90 },

	-- Moon Base M1/M2 (owner R70, W6; tools/blender/models/moon_area0{1,2}.py).
	-- M1 solar panels: SolarPanel + SolarCells + SolarFrame (one group per stand), symmetric about
	-- the axle so the group's box centre sits on it: a slow sun-tracking tilt about local X.
	Solar = { motion = "oscillate", axis = "X", amplitude = 8, period = 7 },
	-- M2 rocket jukebox light bands (JukeboxLightsMint / JukeboxLightsSun): a soft pulsing glow,
	-- nothing moves (R19 caps: brightness 0.45 x (1 +- 0.2)).
	Jukebox = { motion = "none", light = { range = 8, brightness = 0.45, pulse = 0.2 } },

	-- Moon Base M3/M4 (owner R70, W7; tools/blender/models/moon_area0{3,4}.py). Assembly-only rows
	-- (Assemblies below; no piece is named after them). Everything else in M3 / M4 uses existing
	-- rows: Belt (dock + sorter conveyors), Nuke* (floating moon nukes), Rotor (drill bit), Hover.
	-- M3 radar dish: the dish + counterweight (Dish) and its hub ring (DishTrim) are centred on the
	-- mast axis, so the pair sweeps round the sky.
	RadarSpin = { motion = "spin", axis = "Y", speed = 36 },
	-- Tethered / magnet-held rocks and the tractor beam's rings drift up and down. Every cable or
	-- magnet tip that touches a floating rock reaches >= 0.9 into it (> amplitude), so no gap shows.
	Float = { motion = "bob", amplitude = 0.45, period = 4.2 },
	-- The M4 Mega Asteroid: a slower, bigger drift (its four cables reach 1.6 into the rock).
	FloatBig = { motion = "bob", amplitude = 0.7, period = 7 },

	-- Moon Base M5/M6 (owner R70, W8; tools/blender/models/moon_area0{5,6}.py). Everything else
	-- in M5 / M6 uses existing rows: Twirl* (M5 planet mobile, M6 nebula swirl), Carousel* (M6
	-- orbit rings), WheelFly* (M6 coolant flywheels → Wheel), Core* (the star-core sun pulse,
	-- the nebula orb), Crystal* (crown sparkles), Bubbles, Steam*, Pennant*, Lamp.
	-- M6 meteor falls: the sparkly "star water" stream on the cliff top + the fall ribbon on its
	-- road-facing front scroll a soft stud texture (same as the Dino LavaFall; exact name only).
	StarFall = { motion = "scroll", speed = 1.5, faces = { "Top", "Front" } },

	-- Owner R75 (W7): Nuke Town's static workers come alive. Assembly-only rows (A4_Miner,
	-- A9_AstronautCrew below), driven about model-space hinges.
	-- The Glow Rock miners' pickaxe arm: ready -> wind-up back over the head -> fast accelerating
	-- strike onto the rock (impact: rock chips + green sparkles, a soft clink, the rock's gems flash)
	-- -> small recoil -> rest on the rock -> lift back. Angles about the miner's local X (+ = back).
	PickSwing = {
		motion = "swing",
		axis = "X",
		period = 2.6,
		keys = {
			{ t = 0, angle = 0 },
			{ t = 0.3, angle = 40 },
			{ t = 0.38, angle = 46, ease = "out" },
			{ t = 0.47, angle = -52, ease = "in" }, -- the pick's lower tip bites into the rock top
			{ t = 0.52, angle = -44, ease = "out" },
			{ t = 0.58, angle = -50 },
			{ t = 0.8, angle = -48 },
			{ t = 1, angle = 0 },
		},
		gentle = { amplitude = 8, period = 5.2 },
		-- The strike: rock chips + green sparkles at the rock, the glow gems flash, and H1's soft
		-- toy "tok-tink" (`pick_clink`; its volume, pitch wobble and minInterval live in AudioConfig).
		impact = {
			at = 0.47,
			range = 90,
			burst = "rockChips",
			flash = 0.35,
			sound = { key = "pick_clink", range = 60 },
		},
	},
	-- The miner's body leans back with the wind-up and forward into the strike (the pick arm rides it).
	MinerLean = {
		motion = "swing",
		axis = "X",
		period = 2.6,
		keys = {
			{ t = 0, angle = 0 },
			{ t = 0.36, angle = 5 },
			{ t = 0.47, angle = -6, ease = "in" },
			{ t = 0.6, angle = -5 },
			{ t = 0.8, angle = -4 },
			{ t = 1, angle = 0 },
		},
		gentle = { amplitude = 1.2, period = 5.2 },
	},
	-- A9 crew's mission flag: a lazy flutter about the pole (its hinge), not about its own centre.
	FlagFlutter = { motion = "oscillate", axis = "Y", amplitude = 12, period = 2.6 },
}
WorldFxConfig.Pieces = PIECES

--[[
	Impact particle bursts (owner R75), pooled by Client/Tycoon/Fx/ImpactBursts: `chips` stud squares
	in `chipColors` (one colour per particle) that hop and fall, plus `sparkles` soft glints. Counts
	are scaled by the tier's Bursts (Low 0 = none).
]]
export type BurstFx = {
	chips: number,
	chipColors: { Color3 },
	chipSize: number,
	sparkles: number,
	sparkleColor: Color3,
}
WorldFxConfig.Bursts = {
	-- Glow Rock pick strikes: sandy rock chips + green glow sparkles.
	rockChips = {
		chips = 8,
		chipColors = { Color3.fromRGB(196, 136, 80), Color3.fromRGB(232, 172, 104), Color3.fromRGB(150, 104, 64) },
		chipSize = 0.32,
		sparkles = 6,
		sparkleColor = Color3.fromRGB(150, 250, 132),
	},
} :: { [string]: BurstFx }

--[[
	MOTION GROUPS (owner R25 / R26: an animated part must never move without what is attached
	to it). Rules, applied per spawned model (the MeshKey attribute MeshLibrary sets):
	  * Default: every piece of one model that resolves to the SAME row moves as ONE group — one
	    shared motion, each piece keeps its offset from the group leader (no cap drifting off its
	    body, no phase differences between pieces of one toy).
	  * Assemblies[modelKey][groupName] widens / overrides that: `members` (exact piece names) or
	    `exclude` (every piece of the model except these) move together with the row `fx`
	    ("none" freezes them). Pieces listed here are tagged for the client even when their name
	    alone would not animate (e.g. a car Body carrying a rocket).
	Lights / steam / belts stay per piece (each piece's own row).
]]
export type Assembly = {
	members: { string }?,
	exclude: { string }?,
	fx: string, -- PIECES row name for the shared motion, or "none"
	-- Owner R75: rotate about this MODEL-space point (the model's WorldPivot frame; the row's axis is
	-- a model axis too) instead of the leader's box centre: a shoulder, hips, a flag pole.
	hinge: Vector3?,
	-- Another group name of the same model whose motion this group rides on top of its own (the
	-- pick arm follows the body lean).
	follow: string?,
	-- Swing impact point (model space) for the burst / sound; default the hinge.
	impactAt: Vector3?,
}

-- Row used by an assembly whose fx is "none" (frozen group).
local NONE_ROW: PieceFx = { motion = "none" }

local ASSEMBLIES: { [string]: { [string]: Assembly } } = {
	-- Garage Lab parked car: body, roof rack and the rocket bounce together; wheels stay planted.
	A1_NukeMobile = { Car = { exclude = { "Tyres", "Hubs" }, fx = "CarIdle" } },
	-- B8a (R25 / R26): pieces whose NAME alone would move without what is attached to them.
	A1_ReactorPack = { Coolant = { members = { "Glow" }, fx = "Core" } }, -- fan disc behind the grille: light only
	A2_Fridge = { Stock = { members = { "NukeRed", "NukeOrange", "NukeMint", "NukeNoses" }, fx = "none" } },
	A3_AppPhone = { Icons = { members = { "NukeRed", "NukeMint", "NukeBlue", "NukeNoses" }, fx = "none" } },
	A3_GPSBeacon = {
		Dish = { members = { "Dish" }, fx = "none" }, -- its arm is in Mast
		Ring = { members = { "GlowRing" }, fx = "Core" }, -- glows, never floats off the platform
	},
	A3_ParkingLot = { Stops = { members = { "WheelStops" }, fx = "none" } }, -- concrete, not wheels
	-- Space Port rocket idles: the whole rocket hovers gently (B8d); EngineGlow keeps its flicker light.
	A9_Rocket = { Rocket = { exclude = {}, fx = "RocketIdle" } },
	-- Dino Valley (owner R57). Geyser jets: the water column + its foam cap surge together. Keyed
	-- by model ON PURPOSE: Nuke Town's A6_ShellBack / A6_ShellSide / A9_SpaceElevator have static
	-- pieces called Column (never a global Column row).
	D4_GeyserVent = { Jet = { members = { "Column", "ColumnFoam" }, fx = "Geyser" } },
	D4_MegaGeyser = { Jet = { members = { "Column", "ColumnFoam" }, fx = "Geyser" } },
	-- The water wheel's rims / paddles / spokes (Wheel) and hub trim (WheelTrim): both boxes are
	-- centred on the axle (0, 7.2, 0), so they turn together, slower than the Wheel row.
	D4_WaterWheel = { Wheel = { members = { "Wheel", "WheelTrim" }, fx = "WaterWheel" } },
	-- The Time Machine's swirl arms (box centred on the ring centre (0, 10, 0)) turn slowly.
	Hub_TimeMachine = { Swirl = { members = { "Swirl" }, fx = "TimeSwirl" } },
	-- The Moon Rocket portal (lobby + Landing Plaza, R70 W9b): its star swirl (box centred on the
	-- launch ring (0, 8.6, 0)) turns like the Time Machine's (MoonSwirl); the warm Neon porthole above the sign
	-- gets a soft light only (it never moves off the rocket).
	Hub_MoonRocket = {
		Swirl = { members = { "Swirl" }, fx = "MoonSwirl" },
		Porthole = { members = { "Porthole" }, fx = "Core" },
	},
	-- Landing Plaza comms antennas (W9b): the dish (+ its counterweight, box centred on the mast
	-- axis) sweeps through the Dish row by name; the tip bulb blinks softly instead of the steady
	-- Bulb light.
	Moon_Antenna = { Beacon = { members = { "Bulb" }, fx = "MoonBlink" } },
	-- Owner R75 (W7): the Glow Rock miners swing their picks about the right shoulder (hinge =
	-- area04.py MINER_SHOULDER) while the body leans about the hips (MINER_HIP); the pick arm rides
	-- the lean. Legs, the rock and its Glow gems stay put (the gems keep their own Glow row).
	A4_Miner = {
		Pick = {
			members = { "ArmRShirt", "ArmRSkin", "ArmRPick" },
			fx = "PickSwing",
			hinge = Vector3.new(1.45, 4.1, 0),
			follow = "Lean",
			impactAt = Vector3.new(1.35, 2.6, -3.2),
		},
		Lean = {
			members = {
				"TorsoShirt",
				"TorsoDark",
				"TorsoHat",
				"HeadSkin",
				"HeadDark",
				"HeadHat",
				"HeadNeon",
				"ArmLShirt",
				"ArmLSkin",
			},
			fx = "MinerLean",
			hinge = Vector3.new(0, 2.3, 0),
		},
	},
	-- The Space Port crew: astronaut 1 really waves (about the left shoulder, area09.py
	-- CREW_WAVE_SHOULDER) and the mission flag flutters about its pole (CREW_FLAG_POLE).
	A9_AstronautCrew = {
		Wave = { members = { "WaveSuit", "WaveStripe", "WaveGlove" }, fx = "Wave", hinge = Vector3.new(-7.8, 4.65, 0) },
		Flag = { members = { "Flag", "Stars" }, fx = "FlagFlutter", hinge = Vector3.new(8.3, 8.4, 1.7) },
	},
	-- Moon Base M3/M4 (owner R70, W7). Keyed by model: the generic names (Dish, Rock, Top, ...) also
	-- appear on static pieces elsewhere.
	M3_RadarDish = { Dish = { members = { "Dish", "DishTrim" }, fx = "RadarSpin" } },
	M3_FleetSaucer = { Ship = { exclude = { "Pad", "PadRing" }, fx = "Hover" } }, -- saucer hovers, pad stays
	M3_TractorBeam = { Rings = { members = { "BeamRings" }, fx = "Float" } },
	M4_TetherRock = { Rock = { exclude = { "Anchor", "Cable" }, fx = "Float" } },
	M4_GravityMagnet = { Rock = { members = { "Rock", "RockPink", "RockCyan", "Sparkles" }, fx = "Float" } },
	M4_MegaAsteroid = { Rock = { exclude = { "Anchors", "Cables" }, fx = "FloatBig" } },
	M4_HoverStep = { Step = { exclude = {}, fx = "Hover" } },
	M4_HoverDeck = { Deck = { exclude = {}, fx = "Hover" } },
}
WorldFxConfig.Assemblies = ASSEMBLIES

--[[
	Model ambience (owner R57): an occasional soft sound from a spawned model while it is near the
	camera (WorldFxController; FxQuality MaxSounds budget, nearest first). Keyed by MeshKey; the
	model needs at least one animated / lit piece (its FX groups carry the position). Sparse by
	design: long intervals with random jitter, never a loop.
]]
local AMBIENCE: { [string]: AmbientSound } = {
	-- The tamed volcano (D6 crater rim, steam cloud + core lava light): a friendly low rumble.
	D6_VolcanoTop = { key = "volcano_rumble_soft", interval = 18, jitter = 7, range = 120, volume = 0.8 },
	-- Moon Base M3/M4 (owner R70, W7; H1's Moon 3D sounds): a soft star chime now and then from the
	-- UFO dock (its Belt / floating Nuke groups carry the position) and the floating Mega Asteroid.
	M3_SaucerDock = { key = "star_chime", interval = 22, jitter = 8, range = 110, volume = 0.6 },
	M4_MegaAsteroid = { key = "star_chime", interval = 26, jitter = 9, range = 140, volume = 0.5 },
	-- Moon Base M5/M6 (owner R70, W8; H1's `star_chime`): the spinning planet mobile (Twirl group)
	-- and the finale's smiling mini-sun (CoreSun pulse light) twinkle now and then.
	M5_PlanetMobile = { key = "star_chime", interval = 24, jitter = 8, range = 110, volume = 0.5 },
	M6_StarCore = { key = "star_chime", interval = 20, jitter = 7, range = 160, volume = 0.6 },
}
WorldFxConfig.Ambience = AMBIENCE

--[[
	Manager NPC models: the ManagerController owns their motion (owner R30), so WorldFx never moves
	their pieces (lights / steam on their own rows still work, frozen in place). The sibling module
	ManagerNpcConfig.ownsModel(modelKey) is the source of truth once it exists; until then (or if it
	fails to load) this list is the fallback: every `kind = "Manager"` build key in
	TycoonAreas/Area01..10 (tests/build-in-plan.luau keeps the two in sync).
]]
local FALLBACK_MANAGERS: { [string]: boolean } = {
	A1_UncleAtom = true,
	A2_CashierBot = true,
	A3_Dispatcher = true,
	A4_Foreman = true,
	A5_HeadScientist = true,
	A6_FactoryBoss = true,
	A7_LaunchDirector = true,
	A8_StoreManager = true,
	A9_FlightDirector = true,
	A10_ChiefEngineer = true,
}
WorldFxConfig.FallbackManagers = FALLBACK_MANAGERS
local managerConfig: any = nil -- nil = not looked up yet, false = absent / invalid

--[[
	True when `modelKey` is a manager NPC model (ManagerNpcConfig when present, else the fallback).
	The sibling module is looked up once, lazily (no hard require: WorldFxConfig must keep loading
	while ManagerNpcConfig does not exist yet, and a load error / cyclic require falls back too).
	Example: WorldFxConfig.isManager("A2_CashierBot") --> true
]]
function WorldFxConfig.isManager(modelKey: string): boolean
	if managerConfig == nil then
		managerConfig = false
		-- The whole lookup is guarded: a missing sibling, a load error, `script` being nil (a bare
		-- lune load) or anything unexpected leaves the fallback list in charge, never an error.
		local loaded, result = pcall(function(): any
			local parent = (script :: any).Parent
			-- Real Instances: FindFirstChild (nil when absent). Lune RobloxLoader path nodes
			-- (tests/fixtures) have no methods; indexing a node resolves straight to the file.
			local module = if typeof(parent) == "Instance"
				then (parent :: Instance):FindFirstChild("ManagerNpcConfig")
				else parent.ManagerNpcConfig
			return if module ~= nil then (require :: any)(module) else nil
		end)
		if loaded and type(result) == "table" and type(result.ownsModel) == "function" then
			managerConfig = result
		end
	end
	if managerConfig then
		local owns, answer = pcall(managerConfig.ownsModel, modelKey)
		return owns and answer == true
	end
	return FALLBACK_MANAGERS[modelKey] == true
end

--[[
	Vehicles / machines driven along routes by Client/Tycoon/Fx/VehicleRoutes (owner R56): WorldFx
	never moves their pieces (VehicleRoutes moves the whole model as one unit, R25); a piece with a
	light / steam row still glows, frozen in the "@Routed" group (the light rides the part). Must
	equal VehicleRouteConfig.RoutedModels (tests/vehicle-routes.luau checks it). A static list, not a
	require, so the server's MeshLibrary tagging never loads the route tables.
]]
local ROUTED_MODELS: { [string]: boolean } = {
	A3_DeliveryVan = true,
	A3_Scooter = true,
	A4_MineCart = true,
	A6_DeliveryTruck = true,
	A6_Forklift = true,
	A6_ToyRocket = true,
	A8_ShopperCar = true,
	-- Dino Valley (owner R57): the ptero courier flies parcels in / out of the D3 nest deck; its
	-- WingL / WingR flap through VehicleRoutes' wing hook, never through WorldFx (R25).
	D3_PteroCourier = true,
	-- Moon Base M3/M4 (owner R70, W7): UFO couriers fly parcels from the M3 landing deck (FinL /
	-- FinR wiggle through the flyer hook); M4 ore carts loop the track to the crystal sorter.
	M3_UfoCourier = true,
	M4_OreCart = true,
}
WorldFxConfig.RoutedModels = ROUTED_MODELS

--[[
	The motion group a piece belongs to, or nil when it does not animate. Manager NPC pieces with a
	light / steam row land in the frozen "@NpcStill" group; their other pieces are never animated.
	Routed vehicle pieces (RoutedModels) likewise: light / steam rows -> frozen "@Routed", else nil.
	@return groupName string, row PieceFx (the shared motion row)
	Example: WorldFxConfig.groupFor("A1_NukeMobile", "Roof") --> "Car", PIECES.CarIdle
]]
function WorldFxConfig.groupFor(modelKey: string?, pieceName: string): (string?, PieceFx?)
	if modelKey ~= nil and WorldFxConfig.isManager(modelKey) then
		-- Manager NPCs move only through ManagerController; keep their lights / steam, still.
		local row = WorldFxConfig.resolve(pieceName)
		if row ~= nil and (row.light ~= nil or row.particles ~= nil) then
			return "@NpcStill", NONE_ROW
		end
		return nil, nil
	end
	if modelKey ~= nil and ROUTED_MODELS[modelKey] then
		local row = WorldFxConfig.resolve(pieceName)
		if row ~= nil and (row.light ~= nil or row.particles ~= nil) then
			return "@Routed", NONE_ROW
		end
		return nil, nil
	end
	local assemblies = if modelKey ~= nil then ASSEMBLIES[modelKey] else nil
	if assemblies ~= nil then
		for groupName, assembly in assemblies do
			local inGroup = false
			if assembly.members ~= nil then
				inGroup = table.find(assembly.members, pieceName) ~= nil
			elseif assembly.exclude ~= nil then
				inGroup = table.find(assembly.exclude, pieceName) == nil
			end
			if inGroup then
				local row: PieceFx = PIECES[assembly.fx] or NONE_ROW
				return `@{groupName}`, row
			end
		end
	end
	local row, rowName = WorldFxConfig.resolve(pieceName)
	if row == nil then
		return nil, nil
	end
	return rowName, row
end

-- Extra names mapping to a PIECES row (lets builders use natural words).
local ALIASES: { [string]: string } = {
	Propeller = "Rotor",
	Blades = "Rotor",
	Conveyor = "Belt",
	Radar = "Dish",
	Lamp = "Bulb",
	Lamps = "Bulb",
	-- Cashier robot's neon face (A2_CashierBot, a manager NPC): a soft light only, never moves.
	FaceGlow = "Core",
}
WorldFxConfig.Aliases = ALIASES

--[[
	Resolve a piece name to its FX row + canonical row name (nil = not animated). Pure; used by
	MeshLibrary (tagging) and WorldFxController (behaviour).
	Example: WorldFxConfig.resolve("Rotor_Left") --> PIECES.Rotor, "Rotor"
]]
function WorldFxConfig.resolve(name: string): (PieceFx?, string?)
	local direct = PIECES[name]
	if direct ~= nil then
		return direct, name
	end
	local alias = ALIASES[name]
	if alias ~= nil then
		return PIECES[alias], alias
	end
	-- Leading capitalised word: "Rotor2" -> "Rotor", "BeltA" -> "Belt", "Glow_1" -> "Glow".
	local word = string.match(name, "^(%u%l+)")
	if word ~= nil and word ~= name then
		if PIECES[word] ~= nil then
			return PIECES[word], word
		end
		local wordAlias = ALIASES[word]
		if wordAlias ~= nil then
			return PIECES[wordAlias], wordAlias
		end
	end
	return nil, nil
end

-- Steam particles (client ParticleEmitter, built-in smoke texture shipped with every client).
WorldFxConfig.Steam = {
	texture = "rbxasset://textures/particles/smoke_main.dds",
	rate = 6,
	lifetime = NumberRange.new(2.2, 3.4),
	speed = NumberRange.new(4, 7),
	size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(1, 7),
	}),
	transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	}),
}

-- Pad purchase "squish": the pad sinks by Depth studs and springs back over Duration seconds.
WorldFxConfig.PadSquish = { Depth = 0.45, Duration = 0.35 }
-- CollectionService tag on buy pad Models (B5 PlotBuilder; shared with B6) + the server attribute
-- set when a pad is bought (B5 destroys the pad 0.6 s later).
WorldFxConfig.PadTag = "SNPad"
WorldFxConfig.PadPressedAttribute = "PressedAt"
-- Area unlock fanfare: attribute (= area index) B5 sets on the Base Model of an area opened by an
-- Unlock pad purchase.
WorldFxConfig.AreaUnlockAttribute = "AreaUnlock"

-- Sounds (clack, whoosh, sparkle, kaching, pop, fanfare) live in SoundAssets / AudioConfig and play
-- through src/client/Audio/Sound.luau (FxSound is the adapter).

return WorldFxConfig
