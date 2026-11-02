--!strict
--[[
	BuildInConfig — tunables for the LEGO "master builder" purchase animation (owner R1, spec §5).

	Contract with the server (B5 TycoonService / PlotBuilder):
		* A purchased build Model is tagged `Tag` and carries attributes `TimeAttribute`
		  (workspace:GetServerTimeNow() when placed) and `BuyerAttribute` (buyer UserId), set BEFORE
		  it is parented. Restored plots carry neither, so they appear finished.
		* Pieces spawned by MeshLibrary carry `OrderAttribute` (bottom-to-top index). Invisible
		  collision Parts (Transparency >= 1) are never animated.
	The client (src/client/Tycoon/BuildIn/BuildInController.luau) hides the real pieces with
	LocalTransparencyModifier, flies pooled translucent ghosts in, then reveals each real piece.

	Modes:
		Full   the buyer (camera within LightRange): ghosts launch from scattered points around the
		       buyer, arc in with a spin, fade translucent -> solid, clack sounds, confetti finale.
		Light  everyone else within LightRange: pieces drop in from just above with a fade, one
		       sound and a small sparkle — cheap and readable from afar.
		None   beyond the tier's LightRange, late joiners (older than FreshWindow), or Reduce
		       Motion: no flight.
]]

export type BuildBudget = {
	MaxGhosts: number,
	MaxFlownPerBuild: number,
	ConfettiScale: number,
	LightRange: number,
}

local TIERS: { [string]: BuildBudget } = {
	Low = { MaxGhosts = 24, MaxFlownPerBuild = 14, ConfettiScale = 0.45, LightRange = 200 },
	Mid = { MaxGhosts = 40, MaxFlownPerBuild = 26, ConfettiScale = 0.75, LightRange = 260 },
	High = { MaxGhosts = 60, MaxFlownPerBuild = 40, ConfettiScale = 1, LightRange = 320 },
}

local BuildInConfig = {
	Tag = "BuildIn",
	TimeAttribute = "BuildIn",
	BuyerAttribute = "BuyerUserId",
	OrderAttribute = "BuildOrder",

	-- Seconds after the server's BuildIn time during which a model still animates (covers
	-- replication/streaming delay). Older models just appear finished.
	FreshWindow = 2.5,

	-- Full mode timing: each ghost flies `Flight` seconds; ghosts start `stagger` apart where
	-- stagger is clamped to [MinStagger, MaxStagger] and the last piece lands by MaxTotal.
	Flight = 0.62,
	MinStagger = 0.035,
	MaxStagger = 0.16,
	MinTotal = 1.2,
	MaxTotal = 2.5,
	LightFlight = 0.38,

	--[[
		Per-device budgets (owner R11: phones + consoles are primary; hold frame rate on a low-end
		phone). FxQuality picks the tier from the device class + the player's graphics quality.
			MaxGhosts         simultaneous ghosts across ALL builds (hard cap; extra pieces fade in place)
			MaxFlownPerBuild  pieces flown per build (the rest fade in place)
			ConfettiScale     multiplier on Confetti / Sparkle counts
			LightRange        camera distance (studs) up to which a build animates at all
	]]
	Tiers = TIERS,
	-- Fade-in-place duration for capped pieces.
	FadeInPlace = 0.3,

	-- Full-mode scatter around the buyer: horizontal radius and height above the buyer's root.
	ScatterRadius = NumberRange.new(7, 16),
	ScatterHeight = NumberRange.new(3, 11),
	-- Peak height of the flight arc above the straight line (studs).
	ArcHeight = 5,
	-- Max random start rotation (degrees) that unwinds during the flight.
	SpinDegrees = 75,
	-- Ghost transparency at launch (ends at the real piece's transparency).
	StartTransparency = 0.85,
	-- Ghosts never start closer than this to the camera (camera-safe: nothing pops in your face).
	CameraClearance = 6,
	-- Light mode: drop height above the target.
	LightDrop = NumberRange.new(5, 8),

	-- Play a clack every N landed pieces (pitch rises with progress: 0.9 -> 1.25).
	ClackEvery = 3,
	ClackPitch = NumberRange.new(0.9, 1.25),
	-- Confetti + sparkle particle counts for the finale (Light uses SparkleLight only).
	Confetti = 46,
	Sparkle = 26,
	SparkleLight = 10,

	-- Ghost pool: max pooled ghosts per mesh, and in total (extra ghosts are destroyed).
	PoolPerKey = 6,
	PoolTotal = 160,
}

return table.freeze(BuildInConfig)
