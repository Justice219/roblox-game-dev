--!strict
--[[
	KineticConfig — every tunable of owner R90's hands-on plot props built by K-kinetic: the Mega
	Lever (spec docs/superpowers/specs/2026-10-31-r90-hands-on-design.md §2) and the Tip Jar (§3).
	System doc: docs/kinetic.md. Economy notes: docs/economy.md "Mega Lever + Tip Jar".

	What the two props do
		Mega Lever  a giant candy-striped lever machine on every plot (every world), INSIDE the plot in
		            Area 1's front yard beside the road (owner R116; across from the Nuke Stand in
		            Nuke Town — see Placement). The owner HOLDS its prompt (E / gamepad X /
		            tap-and-hold) to pull it once per Lever.CooldownSeconds (server clock, saved per
		            world so a rejoin never resets it). A pull is a MEGA PULL (owner R112 wording): every built producer of
		            that world instantly completes ONE bonus cycle worth Lever.CycleMultiplier normal
		            cycles; the whole payout is clamped to [MinIncomeSeconds, MaxIncomeSeconds] of the
		            plot's production rate, and each bonus cycle rolls a Surprise Batch flavour through
		            FlavorService.batch (the public R89 API). Toy nukes ride the lever's chute, confetti.
		Tip Jar     a glass jar on every plot that fills with coins while the owner is ONLINE, in that
		            world and near their plot: TipJar.FillFraction of the world's income per second,
		            holding at most TipJar.CapMinutes of filling. Walking into it (touch) pays it out;
		            an Interact prompt does the same (accessibility). Coin burst + CurrencyFly. Bonus
		            coins can be dropped in through TipJar.addCoins (a separate bucket capped at
		            BonusCapIncomeSeconds of income; the R90 Order Window's big tips used it until
		            owner R128 removed that system).
		Both appear (LEGO fly-in) once the world's plot reaches UnlockArea (the Nuke Stand in Nuke
		Town), so a brand-new player's first minutes stay focused on the tutorial.

	Security: clients send only "pull" / "collect" intents (KineticAction); ownership, world, reach,
	cooldown, unlock, amounts and flavours are server-side. Performance: one 1 Hz server loop for
	every player; attributes change only on change; client work is event-driven + one short-lived
	render connection while an arm swings / nukes ride.

	Connects to: Shared/Tycoon/KineticLogic (pure maths over this config), Server/Kinetic/* (the
	service), Client/Kinetic/* (rigs, visuals, FX), tests/kinetic-logic.luau, tests/economy-sim.luau
	(pacing lift), tools/blender/models/kinetic.py (the two models; geometry constants mirrored in
	Lever.Hinge / Lever.Chute / TipJar.Coins).

	Example:
		local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)
		print(KineticConfig.Lever.CooldownSeconds) --> 600
		print(KineticConfig.TipJar.FillFraction)   --> 0.02
]]

local KineticConfig = {}

--------------------------------------------------------------------------------------------------
-- Unlock + identity
--------------------------------------------------------------------------------------------------

-- Both props appear once the world's plot owns this area (Nuke Town: Area 2 "Nuke Stand", reached
-- ~8 min into a first run; the same index in every world). Below it nothing is instanced.
KineticConfig.UnlockArea = 2

-- Model keys (tools/blender/models/kinetic.py → MeshAssets; primitive fallback until uploaded).
KineticConfig.Models = table.freeze({
	Lever = "Kinetic_Lever",
	Jar = "Kinetic_TipJar",
})

-- Server instance names (Workspace.Plots.PlotN.Kinetic.{MegaLever, TipJar}; every world's plot).
KineticConfig.FolderName = "Kinetic"
KineticConfig.LeverName = "MegaLever"
KineticConfig.JarName = "TipJar"
KineticConfig.TriggerName = "JarTrigger"

-- CollectionService tags (server-set on the models; the client finds them as they stream in).
KineticConfig.Tags = table.freeze({
	Lever = "SNKineticLever",
	Jar = "SNKineticJar",
})

-- Attributes. Model attributes are server-set (clients only read them):
--   lever: OwnerUserId, WorldId, Plot, ReadyAt (unix s the lever is ready; 0 = ready),
--          PulledAt (server time of the last pull — every client swings the arm)
--   jar:   OwnerUserId, WorldId, Plot, Fill (0..1 in FillSteps steps), Full (bool),
--          CollectedAt (server time of the last payout — coin burst for everyone nearby),
--          TippedAt (server time of the last bonus tip via TipJar.addCoins — coin shower)
-- ReplicatedStorage kill switches (server-set at Start, admin KineticSwitch): LeverOn / JarOn.
KineticConfig.Attr = table.freeze({
	Owner = "OwnerUserId",
	World = "WorldId",
	Plot = "Plot",
	ReadyAt = "ReadyAt",
	PulledAt = "PulledAt",
	Fill = "Fill",
	Full = "Full",
	CollectedAt = "CollectedAt",
	TippedAt = "TippedAt",
	LeverOn = "KineticLeverOn",
	JarOn = "KineticJarOn",
})

--------------------------------------------------------------------------------------------------
-- Placement (SLOT-LOCAL in the Area `Placement.Area` slot: WorldLayout slot frame, +Z away from
-- the road, identity rotation = the model's front (-Z) faces the road)
--------------------------------------------------------------------------------------------------

--[[
	Owner R116 ("these things are out of the plot"): both props stand INSIDE the plot, in the front
	yard of Area 1 beside the road — directly across the road from the Nuke Stand in Nuke Town, next
	to Area 2 in Dino Valley / Moon Base — on the plot's own walkable ground. The
	same slot-local spots in every world (all three Area 1 layouts have the lot at y = 0.5 and room
	there):
		Lever  (-18, 0.5, 12)  left of Area 1's entry path, where Area 1's pads stood
		Jar    ( 15, 0.5, 9.5) right of the entry path, beside the road (the spot was also chosen
		                       clear of the R90 Order Window's customer walk, removed by owner R128)
	Why Area 1's front yard: the props appear at UnlockArea (2), and Area 1's chain is linear (its
	Unlock pad is its last pad), so EVERY Area 1 pad is already bought (and gone) whenever the props
	exist — they never stand in front of a pad the player still needs. Area 2's front yard would put
	them right in front of the pads that just appeared. The road-side ground of Area 1 is also clear
	of the area's entry path and spawn point.
	tests/kinetic-logic.luau proves on EVERY world's shipped layout data (area layout incl. every
	build, billboard spots, the plot frame's colliders; Dino's D1_Jungle clumps from its builder):
	the whole footprint inside the slot / plot / fence line and on walkable ground, clear of solids,
	the producer + billboards, the spawn point, the entry arch, D-defense's tower slots and the
	plot sign — and never where a Lucky Button / Happy
	Hour pickup can spawn (every footprint point is inside LuckyButtonLogic's pad keep-out).
	Footprints are model-local boxes (centre offset + size) used by that test.
]]
KineticConfig.Placement = table.freeze({
	Area = 1,
	Lever = CFrame.new(-18, 0.5, 12),
	Jar = CFrame.new(15, 0.5, 9.5),
	-- Model-local footprint boxes (x/z extent; the lever's chute + tray reach x = -9.9).
	LeverFootprint = table.freeze({ center = Vector3.new(-3.1, 0, 0), size = Vector3.new(13.8, 7, 6.6) }),
	JarFootprint = table.freeze({ center = Vector3.new(0, 0, 0), size = Vector3.new(4.4, 5, 4.4) }),
	-- Slot-local keep-outs (Area 1) other builders avoid (each footprint + 1 stud of air).
	KeepOut = table.freeze({
		Lever = table.freeze({ minX = -29, maxX = -13, minZ = 7.5, maxZ = 16.5 }),
		Jar = table.freeze({ minX = 11.5, maxX = 18.5, minZ = 6, maxZ = 13 }),
	}),
})

--------------------------------------------------------------------------------------------------
-- Mega Lever
--------------------------------------------------------------------------------------------------

KineticConfig.Lever = table.freeze({
	-- Seconds between pulls per (player, world); saved as a unix time in profile.kinetic.
	CooldownSeconds = 600,
	-- One bonus cycle of a producer is worth this many normal cycles of it.
	CycleMultiplier = 10,
	-- The whole Mega Pull payout is clamped to this window, in seconds of the plot's production rate
	-- (Σ perCycle / cycle over the built producers): a floor so a pull always feels mega even at
	-- the 0.1 s cycle floor, a ceiling that keeps the pacing simulator green (docs/economy.md).
	MinIncomeSeconds = 12,
	MaxIncomeSeconds = 24,
	-- Server reach from the lever pivot (horizontal / vertical studs). The prompt's own
	-- MaxActivationDistance is shorter; the slack covers latency and the machine's size.
	Reach = 18,
	ReachVertical = 20,
	-- Bonus cycles described to the client for the chute FX (the payout covers every producer).
	MaxWireCycles = 12,
	-- Arm swing (client): hinge in model space (tools/blender/models/kinetic.py HINGE), axis = the
	-- model's +X; the arm is authored at its rest tilt, the pull swings it forward (toward -Z).
	Hinge = Vector3.new(3.2, 3.6, 0.2),
	ArmPieces = table.freeze({ "Arm", "ArmStripes" }),
	PullDegrees = 95, -- forward swing from the rest pose
	DownSeconds = 0.2,
	HoldSeconds = 0.35,
	UpSeconds = 0.75,
	-- A PulledAt older than this when a lever streams in is history: no swing.
	FreshSeconds = 3,
	-- The owner's hold prompt (client-created; ProximityPrompt draws the device glyph itself).
	Prompt = table.freeze({
		ActionText = "Pull!",
		ObjectText = "Mega Lever",
		HoldSeconds = 0.8,
		MaxDistance = 11,
		-- Model-local attachment point (in front of the machine at chest height).
		Offset = Vector3.new(1.6, 3.4, -4),
		KeyboardKey = Enum.KeyCode.E,
		GamepadKey = Enum.KeyCode.ButtonX,
	}),
	-- Countdown board over the machine (client; studs-sized BillboardGui, stud panel).
	Board = table.freeze({
		SizeStuds = Vector2.new(7, 3),
		Offset = Vector3.new(0, 9.6, 0),
		MaxDistance = 90,
		Title = "MEGA LEVER",
		Ready = "READY! HOLD TO PULL",
		ReadyOther = "READY!",
		Off = "RESTING",
		-- Stud panel colours (candy red with a dark rim; the ready line turns green).
		Color = Color3.fromRGB(232, 64, 56),
		Stroke = Color3.fromRGB(110, 22, 22),
		ReadyColor = Color3.fromRGB(150, 255, 110),
		WaitColor = Color3.fromRGB(255, 240, 200),
		TileSize = 40,
		TextureTransparency = 0.55,
	}),
	-- Chute ride (client, model space; tools/blender/models/kinetic.py CHUTE_TOP / CHUTE_END):
	-- hopper → chute top → chute end → catch tray. The toy nuke is a clone of the HopperNuke piece.
	Chute = table.freeze({
		Points = table.freeze({
			Vector3.new(-0.6, 6.3, 0.2),
			Vector3.new(-1.9, 5.1, 0.2),
			Vector3.new(-9.0, 1.5, 0.2),
			Vector3.new(-9.5, 1.15, 0.2),
		}),
		NukePiece = "HopperNuke",
		RideSeconds = 1.1,
		StaggerSeconds = 0.16,
	}),
})

--------------------------------------------------------------------------------------------------
-- Tip Jar
--------------------------------------------------------------------------------------------------

KineticConfig.TipJar = table.freeze({
	-- Fill rate: this fraction of the world's idle income per second (TycoonService
	-- .incomePerSecond, modifiers included) while the owner is online, in that world, near the plot.
	FillFraction = 0.02,
	-- The jar holds at most this many minutes of filling (= FillFraction x 60 x CapMinutes seconds
	-- of income: 24 s today). Full = it stops filling until the owner walks into it.
	CapMinutes = 20,
	-- A payout needs at least this fraction of the cap (no spam payouts of crumbs); bonus tips (the
	-- TipJar.addCoins bucket) always pay.
	MinCollectFraction = 0.05,
	-- Bonus tips (TipJar.addCoins; the R90 Order Window's until owner R128 removed it) live in a
	-- bonus bucket capped at this many seconds of income (earned rewards, so above the passive cap
	-- — never unbounded).
	BonusCapIncomeSeconds = 120,
	-- Ceiling of ANY single payout in seconds of the current income (a stale jar after an admin
	-- run reset can never pay pre-reset money into a fresh run). Above passive cap + bonus cap.
	HardCapIncomeSeconds = 180,
	-- "Near their plot": the owner's root within this many studs of the plot footprint.
	NearMargin = 40,
	-- Fill attribute steps (the coin pile moves in 1/FillSteps; attribute writes only on a step).
	FillSteps = 20,
	-- Touch payout debounce per player (seconds) and server reach from the jar pivot.
	TouchCooldown = 1,
	Reach = 14,
	ReachVertical = 16,
	-- The jar's in-memory fill is marked for save at most this often (payouts save at once).
	SaveSeconds = 30,
	-- Coin pile (tools/blender/models/kinetic.py: full height 1.45 .. 4.38, bottom fixed).
	CoinPiece = "Coins",
	CoinBottom = 1.45,
	-- Touch trigger (server, model-local box around the jar; a little larger than the crate).
	TriggerSize = Vector3.new(6, 6, 6),
	TriggerOffset = Vector3.new(0, 3, 0),
	-- Collision box for the crate + jar (server; the mesh pieces never collide).
	ColliderSize = Vector3.new(4, 4.9, 4),
	Prompt = table.freeze({
		ActionText = "Collect tips",
		ObjectText = "Tip Jar",
		HoldSeconds = 0.25,
		MaxDistance = 9,
		Offset = Vector3.new(0, 3, -2.6),
		KeyboardKey = Enum.KeyCode.E,
		GamepadKey = Enum.KeyCode.ButtonX,
	}),
	Board = table.freeze({
		SizeStuds = Vector2.new(5, 1.6),
		Offset = Vector3.new(0, 6.6, 0),
		MaxDistance = 60,
		Title = "TIP JAR",
		Full = "FULL! WALK IN",
		Color = Color3.fromRGB(255, 176, 36),
		Stroke = Color3.fromRGB(140, 84, 10),
		TextColor = Color3.fromRGB(255, 255, 255),
		TileSize = 40,
		TextureTransparency = 0.55,
	}),
})

-- Collision box of the lever machine (server, model-local; the chute stays walk-through).
KineticConfig.LeverCollider = table.freeze({ center = Vector3.new(0, 2.4, 0), size = Vector3.new(7, 4.8, 6.4) })

--------------------------------------------------------------------------------------------------
-- Server loop, remotes, rate limits
--------------------------------------------------------------------------------------------------

KineticConfig.TickSeconds = 1
-- KineticAction intents per player: a burst, then this many per second.
KineticConfig.ActionBurst = 4
KineticConfig.ActionRefill = 1
-- "Not ready yet" toasts at most this often per player.
KineticConfig.NoticeSeconds = 3
-- Wire actions (C→S KineticAction allowlist).
KineticConfig.Actions = table.freeze({ "pull", "collect" })
-- Analytics: the recorder family (AnalyticsConfig.Metrics.kinetic documents every key).
KineticConfig.AnalyticsFamily = "kinetic"
-- Grant reasons (PlayerDataService analytics labels, [%w_-] <= 32).
KineticConfig.Reasons = table.freeze({ Lever = "megaLever", Jar = "tipJar" })

--------------------------------------------------------------------------------------------------
-- Pacing (tests/economy-sim.luau, docs/economy.md)
--------------------------------------------------------------------------------------------------

--[[
	The simulator multiplies every producer's income by 1 + KineticLogic.pacingLift(flavourLift):
		jar   = FillFraction x JarPresenceShare
		lever = MaxIncomeSeconds / CooldownSeconds x LeverPullShare x flavourLift
	Conservative on purpose: the shares are 1 (a pull EVERY cooldown at the CEILING, always beside
	the jar), so the real lift is lower. tests/kinetic-logic.luau caps it at MaxLift.
]]
KineticConfig.Pacing = table.freeze({
	LeverPullShare = 1,
	JarPresenceShare = 1,
	MaxLift = 0.065,
})

--------------------------------------------------------------------------------------------------
-- Client FX (FxQuality tiers: Low / Mid / High)
--------------------------------------------------------------------------------------------------

KineticConfig.Fx = table.freeze({
	-- Toy nukes riding the chute per pull (capped by the bonus cycles described on the wire).
	ChuteNukes = table.freeze({ Low = 3, Mid = 6, High = 10 }),
	-- Confetti squares + sparkles at the catch tray / jar.
	Confetti = table.freeze({ Low = 8, Mid = 20, High = 34 }),
	Sparkles = table.freeze({ Low = 2, Mid = 6, High = 10 }),
	-- Coin parts falling into the jar on a bonus tip (TipJar.addCoins).
	TipCoins = table.freeze({ Low = 3, Mid = 6, High = 10 }),
	CoinPool = 12,
	CoinSize = Vector3.new(0.9, 0.18, 0.9),
	CoinColor = Color3.fromRGB(255, 200, 40),
	CoinDropStuds = 6,
	CoinDropSeconds = 0.55,
	-- The big "+$X" pop over the tray / jar (studs-sized billboard, pooled).
	PopSizeStuds = Vector2.new(8, 2.6),
	-- Extra height (studs) of a pop's second line (the MEGA PULL! subline) and its colour.
	PopSubStuds = 1.1,
	PopSubColor = Color3.fromRGB(255, 255, 255),
	PopRiseStuds = 3.5,
	PopSeconds = 1.6,
	PopMaxDistance = 120,
})

-- Player-facing copy (kid-friendly; toasts come from the server, board text from the client).
KineticConfig.Copy = table.freeze({
	LeverCooldown = "The Mega Lever is recharging - back in %s!",
	LeverNoProducers = "Build a machine first - then pull the Mega Lever!",
	LeverOff = "The Mega Lever is resting right now.",
	LeverTooFar = "Walk up to your Mega Lever to pull it!",
	JarFilling = "Your Tip Jar is still filling - come back soon!",
	JarOff = "The Tip Jar is resting right now.",
	-- Owner R112: the pull banner never says "batch" (players found it confusing).
	MegaPull = "MEGA PULL!",
	MegaPullSub = "Every machine made bonus nukes: %s", -- %s = the amount label ("+$1.2M")
	Tips = "TIPS!",
})

return table.freeze(KineticConfig)
