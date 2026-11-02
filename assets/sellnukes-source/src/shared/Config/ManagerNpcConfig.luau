--!strict
--[[
	ManagerNpcConfig — tunables + per-manager rigs for the animated manager NPCs (owner R30: "the
	little NPCs that you hire to automate things ... actually move around and be animated and not
	just a still prop").

	Who reads it:
		- client `Tycoon/Npc/ManagerController` (ONE animation loop for every hired manager)
		- client `Tycoon/Npc/NpcBrain` + `Tycoon/Npc/NpcPose` (pure state machine / pose maths)
		- client `Tycoon/Fx/WorldFxController` (skips manager models via `ownsModel`, so the generic
		  piece bob / spin never fights the NPC rig)
		- `tests/npc-logic.luau` (lune: brain, pose, rig table vs MeshAssets)

	Rig pieces (built by tools/blender/models/_npc_rig.py `rig_split`):
		Every manager mesh is split into body-part pieces named `<Group><Colour>` — `TorsoCoat`,
		`ArmLSkin`, `LegRShoes`, ... — where Group is one of `Groups`. `groupOf(pieceName)` reads the
		leading group word; pieces without one (desks, podiums, consoles that ship in the same
		model) are static props the controller never moves.

	Coordinates: every Vector3 / yaw in `Rigs` is in the manager MODEL's space (relative to the
	spawned model's WorldPivot, the Blender pivot; front = -Z). Yaw is degrees about +Y with the
	Roblox convention used by AreaLayouts `at()`: 0 = facing the model front (-Z), 90 = toward -X,
	-90 = toward +X, 180 = toward +Z.

	Worlds (owner R57, W10): every world's managers live in this one table. `ManagerKeys` stays
	Nuke Town's ten keys (index = area, as tests/build-in-plan and the billboard solver expect);
	`WorldManagerKeys[worldId]` lists each world's keys by area (Dino Valley: D1_RockyRaptor ..
	D6_ChiefTyra) and `managerKeysOf(worldId)` reads it. Build keys are globally unique and
	prefixed, so `Rigs[key]` / `ownsModel(key)` need no world; a rig row's optional `world` field
	(nil = "main") documents where it lives and is checked by tests/npc-logic.luau.

	Usage:
		local ManagerNpcConfig = require(ReplicatedStorage.Shared.Config.ManagerNpcConfig)
		-- Spawned build models are named "<key>_<n>"; the exact key is the MeshKey attribute.
		local meshKey = model:GetAttribute("MeshKey")
		if type(meshKey) == "string" and ManagerNpcConfig.ownsModel(meshKey) then return end
		local rig = ManagerNpcConfig.Rigs.A1_UncleAtom
]]

export type GroupName = "Torso" | "Head" | "ArmL" | "ArmR" | "LegL" | "LegR"
export type Arm = "ArmL" | "ArmR"
export type WorkAction = "Tap" | "Hammer" | "Press"
export type Style = "Biped" | "Hover"

-- One stop on a manager's work loop (figure feet centre, model space).
export type Waypoint = {
	at: Vector3,
	-- Facing on arrival: model-space yaw degrees, "producer" (turn to the producer anchor, live),
	-- or nil (keep the walking heading).
	face: (number | string)?,
	work: boolean?, -- perform the work action here, synced to the producer cycle
	pause: number?, -- idle seconds here (non-work stops); default Motion.PauseDefault
}

export type Rig = {
	style: Style, -- Biped: legs stride; Hover: no legs, floats with a soft bob (robots)
	figure: { base: Vector3, yaw: number }, -- rest position + facing of the figure root
	joints: { [string]: Vector3 }, -- model-space pivot per rig group (from the [npc_rig] print)
	waveArm: Arm, -- arm raised to wave at the owner
	workArm: Arm, -- arm that taps / hammers (Press uses both)
	workAction: WorkAction,
	carry: { [string]: boolean }?, -- arms holding a prop: small walk swing
	waypoints: { Waypoint }, -- [1] = home (rest pose position)
	world: string?, -- owner R57: the world the manager lives in (nil = Nuke Town "main")
}

export type Tier = {
	Range: number, -- animate managers within this many studs of the camera
	MaxActive: number, -- nearest N animate; the rest stand still (no per-frame cost)
	HalfRateBeyond: number, -- active managers farther than this update every other frame
}

local ManagerNpcConfig = {}

-- The ten manager build keys (pads with kind = "Manager" in Config/TycoonAreas/*, one per area).
-- These are both the pad `build` keys and the MeshAssets model keys.
ManagerNpcConfig.ManagerKeys = {
	"A1_UncleAtom",
	"A2_CashierBot",
	"A3_Dispatcher",
	"A4_Foreman",
	"A5_HeadScientist",
	"A6_FactoryBoss",
	"A7_LaunchDirector",
	"A8_StoreManager",
	"A9_FlightDirector",
	"A10_ChiefEngineer",
} :: { string }

-- Rig groups, in the order the controller resolves them (Torso first: arms / head ride on it).
ManagerNpcConfig.Groups = { "Torso", "Head", "ArmL", "ArmR", "LegL", "LegR" } :: { GroupName }

--[[
	Every world's manager build keys, by area (owner R57). "main" IS `ManagerKeys`; Dino Valley's
	six are the `kind = "Manager"` pads of Worlds/Dino/Areas/Area01..06 (tests/npc-logic.luau
	checks both lists against the pad configs). Plain data: no WorldsConfig require, so the server's
	WorldFxConfig.isManager lookup and the lune tests stay dependency-free.
]]
ManagerNpcConfig.WorldManagerKeys = {
	main = ManagerNpcConfig.ManagerKeys,
	dino = {
		"D1_RockyRaptor",
		"D2_StegoSally",
		"D3_CaptainPtera",
		"D4_ParaPete",
		"D5_DrTrike",
		"D6_ChiefTyra",
	},
	-- Moon Base M1/M2 (owner R70, W6): the six `kind = "Manager"` build keys of
	-- Worlds/Moon/Areas/Area01..06 (spec 2026-10-31-r69 §2.2). Rigs land with each area's art
	-- (W6 M1-M2, W7 M3-M4, W8 M5-M6); tests/npc-logic.luau reports a listed key without art as pending.
	moon = {
		"M1_BleepBot",
		"M2_ZipZorp",
		"M3_CaptainGlorp",
		"M4_Drillbert",
		"M5_DrNova",
		"M6_CommanderLux",
	},
} :: { [string]: { string } }

-- Shared empty list for unknown worlds (never mutated).
local NO_KEYS: { string } = table.freeze({} :: { string })

--[[
	managerKeysOf — a world's manager build keys, indexed by area (empty for an unknown world).

	@param worldId  "main", "dino", ...
	@return {string} frozen-by-convention list (never mutate)
	Example: managerKeysOf("dino")[3] --> "D3_CaptainPtera"; managerKeysOf("main") == ManagerKeys
]]
function ManagerNpcConfig.managerKeysOf(worldId: string): { string }
	return ManagerNpcConfig.WorldManagerKeys[worldId] or NO_KEYS
end

-- O(1) lookup set built once from every world's keys.
local MANAGER_SET: { [string]: boolean } = {}
for _, keys in ManagerNpcConfig.WorldManagerKeys do
	for _, key in keys do
		MANAGER_SET[key] = true
	end
end

--[[
	ownsModel — true when a spawned model is a manager NPC that ManagerController animates.

	Accepts the MeshAssets key ("A1_UncleAtom"), the build container's name (same) and the spawned
	mesh model's name, which PlotBuilder suffixes with its placement index ("A1_UncleAtom_1").

	@param modelKey  model name or MeshKey attribute
	@return boolean  true for every world's managers (WorldManagerKeys), false for everything else
	Example: ownsModel("A1_UncleAtom_1") --> true; ownsModel("A1_Workbench") --> false
]]
function ManagerNpcConfig.ownsModel(modelKey: string): boolean
	if MANAGER_SET[modelKey] == true then
		return true
	end
	local stem = string.match(modelKey, "^(.-)_%d+$")
	return stem ~= nil and MANAGER_SET[stem] == true
end

--[[
	groupOf — the rig group a piece belongs to, from its leading group word.

	@param pieceName  MeshAssets piece / MeshPart name ("ArmLCoat", "TorsoTie", "Desk")
	@return GroupName? nil for static prop pieces
	Example: groupOf("LegRShoes") --> "LegR"; groupOf("HeadHeadset") --> "Head"; groupOf("Desk") --> nil
]]
function ManagerNpcConfig.groupOf(pieceName: string): GroupName?
	-- Order matters only for shared prefixes; none of the six words prefixes another.
	for _, group in ManagerNpcConfig.Groups do
		if string.sub(pieceName, 1, #group) == group then
			-- The next character must start a colour word (upper case), so "Torsos" never matches.
			local nextChar = string.sub(pieceName, #group + 1, #group + 1)
			if nextChar ~= "" and string.match(nextChar, "%u") ~= nil then
				return group
			end
		end
	end
	return nil
end

-- Seconds between camera-distance re-rankings and owner / producer look-ups (never per frame).
ManagerNpcConfig.RefreshInterval = 0.25

-- Per-frame view culling (perf pass 2026-10-30): an active manager whose home is outside the camera
-- cone (frustum diagonal + ViewMarginDeg, Shared/Util/ViewCone) keeps thinking (brain + pose) but
-- its pieces are not moved that frame; managers within AlwaysMoveWithin studs always move.
ManagerNpcConfig.ViewMarginDeg = 25
ManagerNpcConfig.AlwaysMoveWithin = 25

-- Device budgets (FxQuality tiers, owner R11: console + mobile first).
ManagerNpcConfig.Tiers = {
	Low = { Range = 70, MaxActive = 3, HalfRateBeyond = 30 },
	Mid = { Range = 110, MaxActive = 6, HalfRateBeyond = 50 },
	High = { Range = 160, MaxActive = 10, HalfRateBeyond = 80 },
} :: { [string]: Tier }

-- Motion tunables (degrees / studs / seconds). Pure data: NpcBrain + NpcPose read it.
ManagerNpcConfig.Motion = {
	-- Walking.
	WalkSpeed = 4.2, -- studs/s at full stride
	Accel = 3.0, -- stride blend 0..1 per second (eases into / out of a walk)
	TurnSpeed = 320, -- deg/s
	TurnBeforeWalk = 60, -- turn in place first when the heading is off by more than this
	StrideLength = 2.6, -- studs per full gait cycle (two steps)
	ArriveRadius = 0.08, -- studs: snapped onto the waypoint inside this
	LegSwing = 30,
	ArmSwing = 24,
	CarrySwing = 6, -- arms holding a prop
	HoverArmScale = 0.5, -- Hover robots swing their arms less
	WalkBob = 0.14, -- studs of body bounce per step
	WalkLean = 4, -- forward lean while walking
	HoverLean = 9,
	HoverBob = 0.22,
	HoverPeriod = 2.2,
	-- Idle.
	BreathePeriod = 3.4,
	BreatheLift = 0.045, -- studs
	BreatheNod = 1.6,
	SwayDegrees = 1.4,
	PauseDefault = 2.0,
	PauseJitter = 0.8, -- +- seconds of random variation so plots never pace in lock-step
	-- Work (synced to the producer cycle).
	WorkBeats = 3, -- actions per visit to the work spot
	WorkMinSeconds = 2.5,
	WorkMaxSeconds = 9.0,
	MinBeatInterval = 0.9, -- fast cycles: skip beats rather than flail
	UnsyncedBeatSeconds = 1.8, -- producer unknown / not automated: steady fallback cadence
	ActionSeconds = { Tap = 0.45, Hammer = 0.6, Press = 0.55 } :: { [string]: number },
	-- Fraction of the action at which it "lands" (sound + sparkle).
	HitFraction = { Tap = 0.45, Hammer = 0.62, Press = 0.5 } :: { [string]: number },
	TapReach = 62, -- arm pitch at the top of a tap
	HammerRaise = 135, -- wind-up
	HammerStrike = 25, -- arm pitch at the strike
	PressReach = 70,
	WorkLean = 6,
	WorkNod = 10,
	-- Wave at the owner.
	WaveRadius = 14, -- studs (owner R30 "waves/turns toward the owner when near")
	WaveSeconds = 2.2,
	WaveCooldown = 12,
	WaveLift = 150, -- arm raised sideways (deg)
	WaveWiggle = 22,
	WaveRate = 2.6, -- wiggles per second
	LookRadius = 22, -- head follows the owner inside this
	LookLimit = 50, -- max head turn (deg)
	LookSpeed = 6, -- head turn smoothing (1/s)
	-- Happy hop on a new purchase on the same plot.
	HopHeight = 1.3,
	HopSeconds = 0.55,
	HopArms = 55, -- both arms fling outward
	HopWindow = 6, -- only purchases younger than this many seconds
	HopStagger = 0.18, -- seconds between managers of one plot (a little cheering wave)
	-- A fresh hire stays put while the LEGO build-in plays (BuildFinished releases it earlier).
	BuildHoldSeconds = 4.0,
}

-- Sound + sparkle for a landed work action (keys in AudioConfig.Sfx; 3D, distance-attenuated).
ManagerNpcConfig.Fx = {
	WorkSound = "clack",
	WorkVolume = 0.4,
	WorkPitch = { Tap = 1.25, Hammer = 0.95, Press = 1.1 } :: { [string]: number },
	HopSound = "pop",
	HopVolume = 0.35,
	SoundRange = 45, -- only managers this close to the camera make noise
	SparkleCount = 3, -- Confetti sparkles per landed action (0 = off)
	SparkleRange = 60,
	SparkleTiers = { Low = false, Mid = true, High = true } :: { [string]: boolean },
	--[[
		Owner R57: a world's managers celebrate with their own voice instead of the hop "pop"
		(Dino Valley: a happy little roar). Sparse: at most one per `Cooldown` seconds per client
		(the other hops in between keep the soft pop), only on the listed FxQuality tiers, and the
		usual SoundRange / one-sound-per-frame budget still applies.
	]]
	WorldHopVoice = {
		dino = {
			key = "dino_happy_roar",
			volume = 0.5,
			cooldown = 4,
			tiers = { Low = false, Mid = true, High = true } :: { [string]: boolean },
		},
		-- Moon Base (owner R70, W6): robots and aliens chirp a friendly beep (H1's 3D `robot_beep`,
		-- range 120; silent until its moderation review clears, like any unapproved sound).
		moon = {
			key = "robot_beep",
			volume = 0.45,
			cooldown = 4,
			tiers = { Low = false, Mid = true, High = true } :: { [string]: boolean },
		},
	} :: { [string]: { key: string, volume: number, cooldown: number, tiers: { [string]: boolean } } },
}

--[[
	Per-manager rigs (every world; build keys are unique). joints/figure come from the `[npc_rig]` print of `tools/blender/generate_world.py`
	(rig_split); waypoints were authored against each AreaLayouts placement + neighbouring collision
	(paths keep ~1.3 studs of body clearance, stay on the figure's own floor / deck / podium).
]]
ManagerNpcConfig.Rigs = {
	-- Garage (AreaLayouts/Area01 UNCLE = GARAGE * at(5, GF, 1, 15)): bench to his left, tool wall
	-- behind-right. Loop: home -> bench front (work, faces the producer) -> aisle -> tool wall.
	A1_UncleAtom = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 2.02, 0),
			Head = Vector3.new(0, 4.12, 0),
			ArmL = Vector3.new(-1.42, 3.97, 0),
			ArmR = Vector3.new(1.42, 3.97, 0),
			LegL = Vector3.new(-0.5, 2.02, 0),
			LegR = Vector3.new(0.5, 2.02, 0),
		},
		waveArm = "ArmL",
		workArm = "ArmL",
		workAction = "Hammer",
		carry = { ArmR = true }, -- pocket nuke in his right hand
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 }, -- home
			{ at = Vector3.new(-6.69, 0, -0.14), face = "producer", work = true }, -- bench front
			{ at = Vector3.new(-2.42, 0, -0.65), pause = 0 }, -- aisle (keeps clear of the bench corner)
			{ at = Vector3.new(0.78, 0, 5.59), face = 165, pause = 1.8 }, -- tool wall
		},
	},
	-- Nuke Stand, behind the counter: register (work) -> home -> back rack.
	A2_CashierBot = {
		style = "Hover",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 0.9, 0),
			Head = Vector3.new(0, 4.5, 0),
			ArmL = Vector3.new(-1.35, 3.8, 0),
			ArmR = Vector3.new(1.35, 3.8, 0),
		},
		waveArm = "ArmL",
		workArm = "ArmL",
		workAction = "Tap",
		carry = { ArmR = true },
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 },
			{ at = Vector3.new(6.2, 0, 0), face = 0, work = true }, -- register
			{ at = Vector3.new(-3.8, 0, 0), face = 150, pause = 2 }, -- back rack
		},
	},
	-- BoomDash dispatch desk (desk at model +X): desk / pickup window (work) -> watches the lane.
	A3_Dispatcher = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 2.02, 0),
			Head = Vector3.new(0, 4.12, 0),
			ArmL = Vector3.new(-1.42, 3.97, 0),
			ArmR = Vector3.new(1.42, 3.97, 0),
			LegL = Vector3.new(-0.5, 2.02, 0),
			LegR = Vector3.new(0.5, 2.02, 0),
		},
		waveArm = "ArmR",
		workArm = "ArmR",
		workAction = "Tap",
		carry = { ArmL = true }, -- clipboard
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 },
			{ at = Vector3.new(1.0, 0, -0.6), face = "producer", work = true },
			{ at = Vector3.new(-3.2, 0, -0.2), face = 20, pause = 2 },
		},
	},
	-- Glow mine, beside his shack (AreaLayouts/Area04 FOREMAN_FIGURE): checks the drill (work).
	A4_Foreman = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 2.3, 0),
			Head = Vector3.new(0, 4.45, 0),
			ArmL = Vector3.new(-1.45, 4.1, 0),
			ArmR = Vector3.new(1.45, 4.1, 0),
			LegL = Vector3.new(-0.52, 2.3, 0),
			LegR = Vector3.new(0.52, 2.3, 0),
		},
		waveArm = "ArmL",
		workArm = "ArmL",
		workAction = "Tap",
		carry = { ArmR = true }, -- clipboard
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 },
			{ at = Vector3.new(-4.1, 0, -3.1), face = "producer", work = true },
			{ at = Vector3.new(-6.1, 0, -2.0), face = 90, pause = 1.5 },
		},
	},
	-- Lab podium (top y 0.8, radius 2.8; lectern at x >= 1.0): small pacing loop on the podium.
	A5_HeadScientist = {
		style = "Biped",
		figure = { base = Vector3.new(-0.6, 0.8, 0.2), yaw = 0 },
		joints = {
			Torso = Vector3.new(-0.6, 3.1, 0.2),
			Head = Vector3.new(-0.6, 5.25, 0.2),
			ArmL = Vector3.new(-2.05, 4.9, 0.2),
			ArmR = Vector3.new(0.85, 4.9, 0.2),
			LegL = Vector3.new(-1.12, 3.1, 0.2),
			LegR = Vector3.new(-0.08, 3.1, 0.2),
		},
		waveArm = "ArmL",
		workArm = "ArmL",
		workAction = "Tap",
		carry = { ArmR = true },
		waypoints = {
			{ at = Vector3.new(-0.6, 0.8, 0.2), face = 0, pause = 2 },
			{ at = Vector3.new(-0.9, 0.8, -0.2), face = "producer", work = true },
			{ at = Vector3.new(-1.3, 0.8, -0.8), face = 30, pause = 1.5 },
			{ at = Vector3.new(-1.2, 0.8, 1.1), face = 60, pause = 1.5 },
		},
	},
	-- Mezzanine deck (top y 5.6): never leaves the deck.
	A6_FactoryBoss = {
		style = "Biped",
		figure = { base = Vector3.new(-1.0, 5.6, -1.3), yaw = 0 },
		joints = {
			Torso = Vector3.new(-1.0, 7.9, -1.3),
			Head = Vector3.new(-1.0, 10.05, -1.3),
			ArmL = Vector3.new(-2.45, 9.7, -1.3),
			ArmR = Vector3.new(0.45, 9.7, -1.3),
			LegL = Vector3.new(-1.52, 7.9, -1.3),
			LegR = Vector3.new(-0.48, 7.9, -1.3),
		},
		waveArm = "ArmL",
		workArm = "ArmR",
		workAction = "Tap", -- megaphone call
		carry = { ArmR = true },
		waypoints = {
			{ at = Vector3.new(-1.0, 5.6, -1.3), face = 0, pause = 2 },
			{ at = Vector3.new(-2.4, 5.6, 1.2), face = 90, pause = 1.5 },
			{ at = Vector3.new(2.2, 5.6, -0.6), face = "producer", work = true },
		},
	},
	-- Silo deck robot: walks back to the silo (work, hammer-chop "go!") and around.
	A7_LaunchDirector = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 2.5, 0),
			Head = Vector3.new(0, 5.6, 0),
			ArmL = Vector3.new(-1.9, 5.1, 0),
			ArmR = Vector3.new(1.9, 5.1, 0),
			LegL = Vector3.new(-0.8, 2.5, 0),
			LegR = Vector3.new(0.8, 2.5, 0),
		},
		waveArm = "ArmR",
		workArm = "ArmR",
		workAction = "Hammer",
		carry = { ArmL = true }, -- clipboard
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 },
			{ at = Vector3.new(-2.5, 0, 6.0), face = "producer", work = true },
			{ at = Vector3.new(3.5, 0, 4.0), face = 180, pause = 1.5 },
		},
	},
	-- Mega-mart plaza robot on a rolling base: checkout (work) and the shelves.
	A8_StoreManager = {
		style = "Hover",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 0.9, 0),
			Head = Vector3.new(0, 5.0, 0),
			ArmL = Vector3.new(-1.7, 3.9, 0),
			ArmR = Vector3.new(1.7, 3.9, 0),
		},
		waveArm = "ArmR",
		workArm = "ArmR",
		workAction = "Tap",
		carry = { ArmL = true }, -- basket
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 },
			{ at = Vector3.new(2.5, 0, 2.5), face = "producer", work = true },
			{ at = Vector3.new(-3.0, 0, 1.0), face = 90, pause = 1.5 },
		},
	},
	-- Mission control: home IS the console (work), small steps on the mat behind it.
	A9_FlightDirector = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0.2, 0.9), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 2.5, 0.9),
			Head = Vector3.new(0, 4.65, 0.9),
			ArmL = Vector3.new(-1.45, 4.3, 0.9),
			ArmR = Vector3.new(1.45, 4.3, 0.9),
			LegL = Vector3.new(-0.52, 2.5, 0.9),
			LegR = Vector3.new(0.52, 2.5, 0.9),
		},
		waveArm = "ArmL",
		workArm = "ArmL",
		workAction = "Press",
		carry = { ArmR = true },
		waypoints = {
			{ at = Vector3.new(0, 0.2, 0.9), face = 0, work = true }, -- at the console
			{ at = Vector3.new(0.9, 0.2, 1.45), face = -90, pause = 2.5 }, -- watches the launch pad
			{ at = Vector3.new(-0.6, 0.2, 1.5), face = 0, pause = 1.5 },
		},
	},
	-- Blueprint mat (drafting table at model +X): drafts at the table (work), checks the reactor.
	A10_ChiefEngineer = {
		style = "Biped",
		figure = { base = Vector3.new(-1.0, 0.2, 0.2), yaw = 0 },
		joints = {
			Torso = Vector3.new(-1.0, 2.5, 0.2),
			Head = Vector3.new(-1.0, 4.65, 0.2),
			ArmL = Vector3.new(-2.45, 4.3, 0.2),
			ArmR = Vector3.new(0.45, 4.3, 0.2),
			LegL = Vector3.new(-1.52, 2.5, 0.2),
			LegR = Vector3.new(-0.48, 2.5, 0.2),
		},
		waveArm = "ArmL",
		workArm = "ArmL",
		workAction = "Tap",
		carry = { ArmR = true },
		waypoints = {
			{ at = Vector3.new(-1.0, 0.2, 0.2), face = 0, pause = 2 },
			{ at = Vector3.new(-0.7, 0.2, 0.9), face = -90, work = true }, -- drafting table
			{ at = Vector3.new(-1.9, 0.2, -0.6), face = "producer", pause = 2 },
		},
	},

	--[[
		Dino Valley managers (owner R57, W10). Every one is W6's shared `dino_biped` body
		(tools/blender/models/dino_area01.py; joints = `dino_bones`, matching each build's [npc_rig]
		print): figure at the model origin, yaw 0, feet on the lot (y 0). Joint maths per body
		(bw, bh, bd): Torso (0, 1.85, 0.1); Head (0, 1.85 + 1.57·bh, -0.1); ArmL/R (∓0.78·bw,
		1.85 + 1.1·bh, 0.1 - 0.45·bd); LegL/R (∓0.48·bw, 1.85, 0.05).
		Waypoints are MODEL space (like every rig above), authored against the Dino layouts
		(Worlds/Dino/Layouts/AreaNN) so the figure root keeps >= 1.3 studs from every collision box
		and >= 1.4 from the producer click box along the whole loop (tests/npc-logic.luau proves it).
		Several Dino managers stand away from their producer (the post captain on the landing apron,
		the lab and reactor chiefs at their own desk / podium); their work stop is their own station
		and the "producer" stop turns them toward the producer they run (live anchor).
	]]
	-- D1 Cave Workshop (Area01 RAPTOR = at(5.5, LOT, 47), stone bench at model (-5.5, -5)): chisels
	-- the bench (work, behind its back edge), peeks into the cave mouth, eyes the bone-tool rack.
	D1_RockyRaptor = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 1.85, 0.1),
			Head = Vector3.new(0, 4.205, -0.1),
			ArmL = Vector3.new(-1.014, 3.5, -0.44),
			ArmR = Vector3.new(1.014, 3.5, -0.44),
			LegL = Vector3.new(-0.624, 1.85, 0.05),
			LegR = Vector3.new(0.624, 1.85, 0.05),
		},
		waveArm = "ArmL",
		workArm = "ArmR",
		workAction = "Hammer",
		carry = { ArmR = true }, -- the chisel rides ArmR
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 }, -- home, in front of the cave mouth
			{ at = Vector3.new(-5.5, 0, -1.2), face = "producer", work = true }, -- behind the bench
			{ at = Vector3.new(-2.5, 0, 2.5), face = 150, pause = 1.6 }, -- peeks into the cave
			{ at = Vector3.new(2.2, 0, -1.6), face = -55, pause = 1.5 }, -- eyes the bone-tool rack
		},
		world = "dino",
	},
	-- D2 Fern Market (Area02 at(-2.5, LOT, 43.2), shell counter in front, coconut till at model
	-- x 6.5): rings up at the till (work), then strolls to the -X end of the counter.
	D2_StegoSally = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 1.85, 0.1),
			Head = Vector3.new(0, 4.205, -0.1),
			ArmL = Vector3.new(-1.131, 3.5, -0.508),
			ArmR = Vector3.new(1.131, 3.5, -0.508),
			LegL = Vector3.new(-0.696, 1.85, 0.05),
			LegR = Vector3.new(0.696, 1.85, 0.05),
		},
		waveArm = "ArmL",
		workArm = "ArmR",
		workAction = "Tap",
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 }, -- home, behind the counter
			{ at = Vector3.new(5.5, 0, 0), face = 0, work = true }, -- coconut till
			{ at = Vector3.new(-3.0, 0, 0.6), face = 30, pause = 1.8 }, -- -X end of the counter
		},
		world = "dino",
	},
	-- D3 Ptero Post (Area03 CAPTAIN = at(17, FLOOR, 26, 20); landing pad behind-left at model
	-- (7.6, 11.3), Nest Tower far to the right): checks parcels toward the tower (work), watches
	-- the landing pad, looks out over the walkway.
	D3_CaptainPtera = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 1.85, 0.1),
			Head = Vector3.new(0, 4.284, -0.1),
			ArmL = Vector3.new(-1.053, 3.555, -0.463),
			ArmR = Vector3.new(1.053, 3.555, -0.463),
			LegL = Vector3.new(-0.648, 1.85, 0.05),
			LegR = Vector3.new(0.648, 1.85, 0.05),
		},
		waveArm = "ArmL",
		workArm = "ArmR",
		workAction = "Tap",
		carry = { ArmR = true }, -- the parcel + right membrane ride ArmR
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 }, -- home, on the apron
			{ at = Vector3.new(-2.0, 0, 1.0), face = "producer", work = true }, -- sorts toward the tower
			{ at = Vector3.new(2.4, 0, 2.2), face = -140, pause = 1.8 }, -- watches the landing pad
			{ at = Vector3.new(0.8, 0, -2.0), face = 10, pause = 1.5 }, -- looks out at the walkway
		},
		world = "dino",
	},
	-- D4 Geyser Springs (Area04 PETE = at(10, FLOOR, 29, 25); pressure valves at model (6.4, 5.2),
	-- yaw -10): wrenches the valves from their -X end (work, side-on to the road), then turns to
	-- the geyser vent.
	D4_ParaPete = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 1.85, 0.1),
			Head = Vector3.new(0, 4.284, -0.1),
			ArmL = Vector3.new(-1.053, 3.555, -0.463),
			ArmR = Vector3.new(1.053, 3.555, -0.463),
			LegL = Vector3.new(-0.648, 1.85, 0.05),
			LegR = Vector3.new(0.648, 1.85, 0.05),
		},
		waveArm = "ArmL",
		workArm = "ArmR",
		workAction = "Hammer",
		carry = { ArmR = true }, -- the bone wrench rides ArmR
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 }, -- home
			{ at = Vector3.new(1.9, 0, 4.4), face = -100, work = true }, -- -X end of the valves
			{ at = Vector3.new(-2.5, 0, 1.0), face = "producer", pause = 1.8 }, -- checks the vent
			{ at = Vector3.new(-1.0, 0, -2.5), face = 15, pause = 1.5 }, -- looks out at the walkway
		},
		world = "dino",
	},
	-- D5 Fossil Lab (Area05 DR_TRIKE = at(-42.9, LOT, 44); specimen desk at model x 3.9, mat
	-- x -1.8..5.4): studies the specimen through the magnifier (work), then looks over at the lab.
	D5_DrTrike = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 1.85, 0.1),
			Head = Vector3.new(0, 4.284, -0.1),
			ArmL = Vector3.new(-1.053, 3.555, -0.463),
			ArmR = Vector3.new(1.053, 3.555, -0.463),
			LegL = Vector3.new(-0.648, 1.85, 0.05),
			LegR = Vector3.new(0.648, 1.85, 0.05),
		},
		waveArm = "ArmL",
		workArm = "ArmR",
		workAction = "Tap",
		carry = { ArmR = true }, -- the magnifier rides ArmR (raised)
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 }, -- home, on the mat
			-- Facing +X the right arm (magnifier) sits over the jar at the desk centre.
			{ at = Vector3.new(1.0, 0, -0.6), face = -90, work = true },
			{ at = Vector3.new(-1.4, 0, 1.0), face = "producer", pause = 2 }, -- looks over at the lab
			{ at = Vector3.new(-0.6, 0, -1.8), face = 20, pause = 1.5 }, -- toward the microscope / road
		},
		world = "dino",
	},
	-- D6 Volcano Reactor (Area06 TYRA = at(-18.9, LOT, 23); control podium at model x 4.1, mat
	-- x -1.9..5.5): works the podium with both hands on the clipboard (Press), then watches the
	-- volcano.
	D6_ChiefTyra = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 1.85, 0.1),
			Head = Vector3.new(0, 4.284, -0.1),
			ArmL = Vector3.new(-1.092, 3.555, -0.485),
			ArmR = Vector3.new(1.092, 3.555, -0.485),
			LegL = Vector3.new(-0.672, 1.85, 0.05),
			LegR = Vector3.new(0.672, 1.85, 0.05),
		},
		waveArm = "ArmL",
		workArm = "ArmR",
		workAction = "Press",
		carry = { ArmL = true, ArmR = true }, -- both tiny arms hold the clipboard (it rides ArmR)
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 }, -- home, on the mat
			{ at = Vector3.new(1.4, 0, -0.5), face = -90, work = true }, -- at the control podium
			{ at = Vector3.new(-1.2, 0, -1.2), face = "producer", pause = 2 }, -- watches the volcano
		},
		world = "dino",
	},

	-- Moon Base M1/M2 (owner R70, W6). Both are W6's shared `toon_biped` body
	-- (tools/blender/models/moon_area01.py; joints = `toon_bones`, matching each build's [npc_rig]
	-- print): figure at the model origin, yaw 0, feet on the lot (y 0). Waypoints are MODEL space,
	-- authored against Worlds/Moon/Layouts/Area01/02 so the figure keeps >= 1.3 studs from every
	-- collision box and >= 1.35 from the producer click box (tests/npc-logic.luau section 6).
	-- M1 Crater Camp (Area01 BLEEP = at(5.5, LOT, 45); workbench in front at model (-5.5, -5), globe
	-- lamp at model (4.5, 2.5), tool rack at model (10.5, -3)): checks the tool rack, hammers at the
	-- back of the bench (work), then looks over at the landed capsule.
	M1_BleepBot = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 1.5, 0),
			Head = Vector3.new(0, 3.684, 0),
			ArmL = Vector3.new(-1.161, 3.086, 0),
			ArmR = Vector3.new(1.161, 3.086, 0),
			LegL = Vector3.new(-0.608, 1.5, 0),
			LegR = Vector3.new(0.608, 1.5, 0),
		},
		waveArm = "ArmL",
		workArm = "ArmR",
		workAction = "Hammer",
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 }, -- home, behind the bench
			{ at = Vector3.new(3, 0, -1), face = -75, pause = 1.5 }, -- eyes the tool rack
			{ at = Vector3.new(-4, 0, -1.4), face = "producer", work = true }, -- back of the bench
			{ at = Vector3.new(-7, 0, 1.5), face = 105, pause = 1.6 }, -- looks at the capsule
		},
		world = "moon",
	},
	-- M2 Cosmic Diner (Area02 ZORP = COUNTER * (-2.5, 0, 3.4); counter in front, star register at
	-- model x 7.1, shake machine at model x -1.9, diner door at model (2.5, 5.6+)): rings up at the
	-- register (work, tray stays in the right hand), skates to the shake machine, greets at the door.
	M2_ZipZorp = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 1.7, 0),
			Head = Vector3.new(0, 3.8, 0),
			ArmL = Vector3.new(-1.032, 3.225, 0),
			ArmR = Vector3.new(1.032, 3.225, 0),
			LegL = Vector3.new(-0.54, 1.7, 0),
			LegR = Vector3.new(0.54, 1.7, 0),
		},
		waveArm = "ArmL",
		workArm = "ArmL",
		workAction = "Tap",
		carry = { ArmR = true }, -- the tray + milkshake ride ArmR
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 }, -- home, behind the counter
			{ at = Vector3.new(7.1, 0, 0), face = 0, work = true }, -- star register
			{ at = Vector3.new(-3.5, 0, 0.2), face = 10, pause = 1.5 }, -- shake machine end
			{ at = Vector3.new(2.5, 0, 5.6), face = 180, pause = 1.4 }, -- greets at the diner door
		},
		world = "moon",
	},

	-- Moon Base M3/M4 (owner R70, W7; tools/blender/models/moon_area0{3,4}.py). Same shared
	-- `toon_biped` body (joints = `toon_bones`, matching each build's [npc_rig] print), figure at the
	-- model origin, yaw 0, feet on the floor. Waypoints are MODEL space, authored against
	-- Worlds/Moon/Layouts/Area03/04 (>= 1.3 studs from every collision box, >= 1.35 from the producer
	-- click box; tests/npc-logic.luau section 6).
	-- M3 UFO Delivery (Area03 CAPTAIN = at(17, FLOOR, 26, 20); tractor-beam pad behind-left at model
	-- (7.6, 11.3), Saucer Dock far to the right): scans parcels toward the dock (work), watches the
	-- tractor pad, looks out over the walkway.
	M3_CaptainGlorp = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 1.6, 0),
			Head = Vector3.new(0, 3.7, 0),
			ArmL = Vector3.new(-1.118, 3.125, 0),
			ArmR = Vector3.new(1.118, 3.125, 0),
			LegL = Vector3.new(-0.585, 1.6, 0),
			LegR = Vector3.new(0.585, 1.6, 0),
		},
		waveArm = "ArmL",
		workArm = "ArmR",
		workAction = "Tap",
		carry = { ArmR = true }, -- the parcel scanner rides ArmR
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 }, -- home, beside the side path
			{ at = Vector3.new(-2.0, 0, 1.0), face = "producer", work = true }, -- scans toward the dock
			{ at = Vector3.new(2.4, 0, 2.2), face = -140, pause = 1.8 }, -- watches the tractor pad
			{ at = Vector3.new(0.8, 0, -2.0), face = 10, pause = 1.5 }, -- looks out at the walkway
		},
		world = "moon",
	},
	-- M4 Asteroid Mine (Area04 DRILLBERT = at(8, FLOOR, 27, 20); Drill Rig far to the right-back,
	-- the ore-cart loop behind-left at model (1.2, 14.3)): hammers toward the drill rig (work),
	-- watches the carts go round, looks out over the walkway.
	M4_Drillbert = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 1.6, 0),
			Head = Vector3.new(0, 3.7, 0),
			ArmL = Vector3.new(-1.118, 3.125, 0),
			ArmR = Vector3.new(1.118, 3.125, 0),
			LegL = Vector3.new(-0.585, 1.6, 0),
			LegR = Vector3.new(0.585, 1.6, 0),
		},
		waveArm = "ArmL",
		workArm = "ArmR",
		workAction = "Hammer",
		carry = { ArmR = true }, -- the toy wrench rides ArmR
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 }, -- home, beside the walkway
			{ at = Vector3.new(-1.5, 0, 1.0), face = "producer", work = true }, -- hammers toward the drill
			{ at = Vector3.new(2.0, 0, 1.6), face = -175, pause = 2 }, -- watches the ore carts
			{ at = Vector3.new(0.6, 0, -1.8), face = 10, pause = 1.5 }, -- looks out at the walkway
		},
		world = "moon",
	},

	-- Moon Base M5/M6 (owner R70, W8). Same shared `toon_biped` body as M1/M2 (joints = `toon_bones`,
	-- matching each build's [npc_rig] print), figure at the model origin, yaw 0, feet on the lot.
	-- Waypoints are MODEL space, authored against Worlds/Moon/Layouts/Area05/06 (>= 1.3 studs from
	-- every collision box, >= 1.35 from the producer click box; tests/npc-logic.luau section 6).
	-- M5 Star Lab (Area05 DR_NOVA = at(-43, LOT, 44); lab bench at model x 3.9, box x 2.7..5.1):
	-- taps test tubes at the bench (work, beaker in the raised right hand), then looks over at the
	-- lab dome and out toward the planet mobile.
	M5_DrNova = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 1.6, 0),
			Head = Vector3.new(0, 3.7, 0),
			ArmL = Vector3.new(-1.118, 3.125, 0),
			ArmR = Vector3.new(1.118, 3.125, 0),
			LegL = Vector3.new(-0.585, 1.6, 0),
			LegR = Vector3.new(0.585, 1.6, 0),
		},
		waveArm = "ArmL",
		workArm = "ArmR",
		workAction = "Tap",
		carry = { ArmR = true }, -- the beaker rides ArmR (raised)
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 }, -- home
			{ at = Vector3.new(1.2, 0, -0.6), face = -90, work = true }, -- at the lab bench (faces +X)
			{ at = Vector3.new(-1.4, 0, 1.0), face = "producer", pause = 2 }, -- looks over at the dome
			{ at = Vector3.new(-0.6, 0, -1.8), face = 20, pause = 1.5 }, -- toward the road / garden
		},
		world = "moon",
	},
	-- M6 Star Reactor (Area06 LUX = at(-22, LOT, 22); mission console at model x 4.1, box x
	-- 2.9..5.3): presses console buttons with the clipboard in both hands, then watches the star.
	M6_CommanderLux = {
		style = "Biped",
		figure = { base = Vector3.new(0, 0, 0), yaw = 0 },
		joints = {
			Torso = Vector3.new(0, 1.6, 0),
			Head = Vector3.new(0, 3.784, 0),
			ArmL = Vector3.new(-1.161, 3.186, 0),
			ArmR = Vector3.new(1.161, 3.186, 0),
			LegL = Vector3.new(-0.608, 1.6, 0),
			LegR = Vector3.new(0.608, 1.6, 0),
		},
		waveArm = "ArmL",
		workArm = "ArmR",
		workAction = "Press",
		carry = { ArmL = true, ArmR = true }, -- both hands hold the clipboard (it rides ArmR)
		waypoints = {
			{ at = Vector3.new(0, 0, 0), face = 0, pause = 2 }, -- home
			{ at = Vector3.new(1.4, 0, -0.5), face = -90, work = true }, -- at the mission console
			{ at = Vector3.new(-1.2, 0, -1.2), face = "producer", pause = 2 }, -- watches the star core
		},
		world = "moon",
	},
} :: { [string]: Rig }

return ManagerNpcConfig
