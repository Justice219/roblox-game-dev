--!strict
--[[
	TycoonClientConfig — presentation tunables of the tycoon CLIENT (B6): producer / pad
	billboards, interaction ranges, income pops, the YOU marker and the tutorial beam.

	Purpose:
		Display-only numbers (sizes in studs, distances, rates, colours). Nothing here is a price,
		a cooldown the server trusts, or a reward: the server re-checks every intent (click
		cooldown, pad distance, affordability).

	Connects to: Client/Tycoon/{ProducerBillboards, PadBillboards, Interaction, IncomePops,
	YouMarker, Tutorial, StandSign}.

	Example: TycoonClientConfig.Billboard.MaxDistance --> 110
]]

return table.freeze({
	-- Producer billboard (reference 08 / 15). Size: a camera-facing board measured in studs (it
	-- shrinks with distance like the world), clamped so it always fills [MinScreen, MaxScreen] of
	-- the viewport height: never balloons over the scene up close, stays readable far away
	-- (Tycoon/BillboardPlacement.heightAt; resized at RefreshHz, only when it changed > SizeEpsilon).
	Billboard = table.freeze({
		HeightStuds = 6.4, -- board height in studs (width = HeightStuds x Aspect)
		Aspect = 1.25, -- width / height of the board layout
		DeviceScale = 1.15, -- phones / tablets / ten-foot consoles: a bit bigger (readable, taps)
		MaxScreen = 0.28, -- at most this fraction of the viewport height (desktop) ...
		MaxScreenDevice = 0.34, -- ... (phone / tablet / console)
		MinScreen = 0.12, -- at least this fraction (desktop) ...
		MinScreenDevice = 0.16, -- ... (phone / tablet / console)
		SizeEpsilon = 0.03, -- rewrite the size only when it changed by more than 3 %
		MaxDistance = 110, -- own producers
		OthersMaxDistance = 70, -- other players' producers (read-only billboards)
		RefreshHz = 4, -- attribute / cost / affordability / size refresh of VISIBLE billboards
		FullBarBelow = 0.25, -- automated cycles shorter than this show a full bar ("0.1s")
		MinClickGap = 0.1, -- client floor between two ProducerClick intents
		UpgradeDebounce = 0.15,
		RebuildingBelow = 3, -- knockdown plate (owner R50): "REBUILDING!" in the last seconds
	}),
	-- Producer billboard placement (owner R31 / R32 + lead QA: the board NEVER covers the producer
	-- or its working manager from where players stand, never sits inside an awning / sign / beam,
	-- stays at a readable height; income pops beside it, never over it). Studs / degrees.
	-- Solver: Tycoon/BillboardPlacement (pure, audited by tests/billboard-clearance.luau).
	Placement = table.freeze({
		-- Where players look from: standing this far in front of the producer's front face (toward
		-- the plot road), this far either side, head HeadHeight up (boxes around it: the room the
		-- player is in, ignored), Roblox's default camera (zoom 12.5) CameraBack behind +
		-- CameraUp above the ground.
		Stands = table.freeze({ 5, 12 }),
		StandScale = 16, -- producers wider / taller than this: stands x (size / StandScale)
		Lateral = table.freeze({ -5, 0, 5 }),
		HeadHeight = 4.5,
		CameraBack = 12,
		CameraUp = 8, -- camera height above the producer's ground
		EntranceStand = 26, -- extra far viewpoint (walking in from the road): sight lines only
		Fov = 70, -- camera vertical field of view assumed by the solver (Roblox default)
		-- Candidate spots.
		Gap = 0.6, -- above the protected boxes' top
		SideGap = 0.8, -- beside the producer's side
		EyeHeight = 6.5, -- side boards: centre this high above the ground ...
		MinBottom = 0.8, -- ... and their bottom at least this high
		MaxAbove = 16, -- highest "above" spot: body top + this
		StepUp = 1.2, -- "above" spots step up by this
		-- Acceptance.
		ScreenMargin = 0.5, -- studs (at the board's depth) kept clear around protected boxes
		-- Owner R117 ("orbital launches upgrade ui is too high up"): tightened from 16 / 30 and an
		-- absolute height cap added, so no board sits high in the sky from the stands.
		MaxElevation = 13, -- board top at most this many degrees above the mid camera's horizon (R32)
		NearElevation = 24, -- ... and this many from the closest stand (still in view, no tilt)
		MaxCentre = 10, -- board centre at most this many studs above the producer's floor (R117)
		TallBody = 9, -- producers whose top is higher than this above their floor: no "above" board
		PropClear = 10, -- beside-spots within this many studs of another system's prop pay ...
		PropPenalty = 1.5, -- ... up to this soft cost (AA towers, Mega Lever, Tip Jar)
		-- Bearings (R119): 46 / 51 (was 45 / 50). A 16:9 view at FOV 70 is ~51.2° to the side, so both
		-- stay on screen; the extra degree lets the Megastore's camera-facing device board stay low
		-- and outside its glass shell (the alternative was a board high in the sky: R117).
		MaxBearing = 46, -- far stand: the board's outer edge within this many degrees of the producer
		NearBearing = 51, -- closer stand: its centre within this (16:9 half-FOV ~51.2°: still on screen)
		SeeThrough = 0.25, -- parts at least this transparent (glass) never block sight lines
		LosPenalty = 6, -- cost per blocked sight line (centre viewpoints -> board centre / corners)
		EvaluateMax = 200, -- slab-clear candidates compared on sight lines (spots are solved offline)
		ObstacleRadius = 50, -- visible geometry considered around the producer
		-- Areas whose producer is round (silo, rocket, reactor dome): its silhouette is the
		-- cylinder inside the click box, not the box (the box's corners are empty air).
		RoundBodies = table.freeze({ [7] = true, [9] = true, [10] = true }) :: { [number]: boolean },
		-- The same, per NON-main world (owner R57; BillboardPlacement.Sources.roundBodies). Every
		-- world of WorldsConfig.Order except "main" needs a row (tests/billboard-clearance.luau).
		-- Dino Valley: only D5's round adobe Fossil Lab hut (walls r 9.5 + posts inside the 21 x 21
		-- click box) is a vertical cylinder filling its box. D1 stone bench and D2 shell counter are
		-- boxes; D3's nest-tower box and D4's vent-mound box both carry a straight counter / pump
		-- bench at their front face whose corners lie OUTSIDE the inscribed cylinder (round would
		-- leave them unprotected); D6's box is a slab of the volcano's door face, not a cylinder.
		WorldRoundBodies = table.freeze({
			dino = table.freeze({ [5] = true }) :: { [number]: boolean },
			-- Moon Base (R70): only M5's Lab Dome (a 20 x 20 dome filling its click box) is a
			-- vertical cylinder; M1 bench / M2 counter / M6 core slab are boxes, and M3's saucer dock
			-- / M4's drill rig carry square decks and gantries at their box corners (round would leave
			-- those unprotected, like D3 / D4). Non-round is always the safe default.
			moon = table.freeze({ [5] = true }) :: { [number]: boolean },
		}) :: { [string]: { [number]: boolean } },
		ManagerReach = 1.4, -- manager walk region: waypoints widened by this ...
		ManagerHeadroom = 0.6, -- ... and topped this far above the head
		-- Income pops (IncomePops): start beside the board on its outer side, drift outward + up.
		PopSideGap = 1.2, -- the pop's inner edge starts this far outside the board's edge
		PopDrop = 0.15, -- pops start this fraction of the board height below its centre
		PopDriftSide = 2.5, -- pops drift outward ...
		PopDriftUp = 3.5, -- ... and up while fading
	}),
	-- Pad billboard (reference 09 / 11 / 17).
	Pad = table.freeze({
		SizeStuds = Vector2.new(7, 3.6),
		OffsetStuds = Vector3.new(0, 4.5, 0),
		MaxDistance = 80,
	}),
	-- Price colour per pad kind (UIStyleConfig ColorName accents; grey when unaffordable).
	PadKindColor = table.freeze({
		Build = "red",
		Multiplier = "yellow",
		Speed = "yellow",
		Manager = "cyan",
		Unlock = "green",
		Feature = "purple",
	} :: { [string]: string }),
	-- Keyboard / gamepad interaction ranges (studs from the character).
	Interact = table.freeze({
		ProducerRange = 18,
		PadRange = 9,
	}),
	-- Floating "+$X" income pops (pooled BillboardGuis).
	Pops = table.freeze({
		PoolSize = 14,
		Seconds = 1.4,
		RiseStuds = 4,
		SizeStuds = Vector2.new(8, 2.6),
		MaxDistance = 90,
	}),
	-- "YOU" marker over the local player's plot entrance.
	You = table.freeze({
		OffsetStuds = Vector3.new(0, 10, 0),
		SizePx = Vector2.new(170, 120),
		MaxDistance = 3000,
	}),
	-- Tutorial guide arrows (owner R27): pooled yellow chevrons on the ground flowing from the
	-- character toward the objective target (no line / beam).
	TutorialArrows = table.freeze({
		Count = 8, -- pooled chevrons
		Spacing = 4.5, -- studs between chevrons along the path
		Speed = 7, -- studs / second the chevrons flow forward (reduced motion: static)
		HideWithin = 8, -- no arrows once the target is this close (the bouncing arrow remains)
		FadeNear = 6, -- chevrons fade out over the last studs before the target
		StartGap = 2.5, -- first chevron this far in front of the character
		ArmLength = 1.7,
		ArmWidth = 0.38,
		ArmHeight = 0.18,
		ArmAngle = 38, -- degrees each arm leans off the path (the "V")
		Hover = 0.2, -- studs above the ground hit
		Color = Color3.fromRGB(255, 214, 40),
		Transparency = 0.12,
	}),
	-- Owner R84: the tutorial highlights the exact control to press (Tycoon/TutorialHighlight)
	-- and the HUD arrow points at it (UI/Hud/HudObjective + PointerLogic).
	TutorialHighlight = table.freeze({
		Color = Color3.fromRGB(255, 214, 40), -- the ring (same yellow as the chevrons / arrow)
		HaloColor = Color3.fromRGB(255, 244, 170), -- the soft outer halo ring
		-- Ring margin outside the control and stroke thickness, as fractions of the control's
		-- shorter side (so the ring looks the same on a stud-scaled billboard and a 72 pt button).
		Pad = 0.14, -- ring gap at rest
		PadGrow = 0.1, -- extra gap at the pulse peak
		Thickness = 0.07, -- stroke at rest
		ThicknessGrow = 0.05, -- extra stroke at the pulse peak
		MinThickness = 2, -- px (canvas px of the control's GUI)
		HaloPad = 0.3, -- the halo sits this far out (fraction of the shorter side)
		HaloTransparency = 0.55, -- halo stroke transparency at rest (fades out on the pulse)
		PulseSpeed = 5, -- radians / s (about 0.8 pulses / s)
		-- Steps / s per graphics tier through the shared OfferFx driver. Low keeps a slow pulse:
		-- this is guidance, not decoration (Reduce Motion still parks it: a static bright ring).
		Hz = table.freeze({ Low = 15, Medium = 30, High = 60 }),
		Corner = 10, -- ring corner radius (px) when the control has no UICorner of its own
	}),
	-- Owner R84: the HUD arrow beside a button + its callout glyph badge (design px).
	TutorialPointer = table.freeze({
		Gap = 10, -- arrow tip <-> the button's board, arrow <-> badge
		Bob = 10, -- px the arrow bobs away from the button (Reduce Motion: still)
		BadgeGlyph = 46, -- the glyph's height inside the badge
		BadgePad = 8, -- badge padding around the glyph
	}),
	-- Rename stand: client-side length cap (the server filters + re-validates).
	RenameMaxLength = 24,
	-- Plot reveal (owner R13): camera swoop from the lobby to the newly assigned plot.
	-- Camera / look points are PLOT-LOCAL (WorldLayout: +Z away from the hub, entrance at z = 4).
	Reveal = table.freeze({
		SwoopSeconds = 2.5,
		HoldSeconds = 1.2, -- look at the plot before handing the camera back
		ReducedHoldSeconds = 2, -- reduced motion: instant cut to the plot, hold, cut back
		BannerSeconds = 4.5,
		CameraLocal = Vector3.new(0, 70, -55),
		LookLocal = Vector3.new(0, 0, 110),
		WaitForMenusSeconds = 8, -- wait for a join pop-up to close before swooping (max)
		WaitForPlotSeconds = 6, -- wait for Plot<N>.PlotReady (builds placed) before swooping (max)
	}),
	-- Teleporting within your OWN plot (areas + hub) is free (lead decision 2026-10-30); the
	-- Teleporter pass adds teleports to other players' plots. Display mirror only: the server
	-- enforces its own rule (set true only if the server gates own-area teleports again).
	TeleportNeedsPass = false,
})
