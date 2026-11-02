--!strict
--[[
	LaunchCamConfig — tunables for the launch cinematic (owner R54: "when you launch an attack on
	somebody that you follow the missile as well with like an animated 3, 2, 1. And a voiceover").

	What it drives (Client/Attack/LaunchCam + UI/Screens/LaunchCountdown):
		1. COUNTDOWN — a big stud "3 … 2 … 1 … LAUNCH!" over a silo shot, synced to the SERVER's
		   flight start `t0`: number n shows from t0 − n × Beat, "LAUNCH!" exactly at t0. The
		   countdown lives INSIDE the server's flight lead-in (AttackConfig.Flight.LeadIn =
		   #Steps × Beat + NetSlack), so it adds no delay and never changes an outcome; a late
		   packet simply joins mid-countdown.
		2. CHASE — the camera rides behind / above the toy nuke on its arc (spring-damped offset +
		   look direction), turns toward the target late in the flight, eases into an impact shot
		   ("slow-mo feel" = camera deceleration + FOV narrowing, never time scaling), holds on the
		   POP / confetti hit (longer when a knockdown topples the area), then eases back to the
		   player's own camera.
	Every number below is design data; presentation only (the server decided everything already).

	Units: seconds, studs, degrees, design px at 1080p. Times marked "rel" are seconds after the
	flight's server t0 (negative = still counting down).

	Connects to: Client/Attack/LaunchCam (director), UI/Screens/LaunchCountdown/{LaunchCountdownScreen,
	CountdownOverlay} (overlay), Shared/Attack/LaunchCamMath (pure math), Shared/Config/AttackConfig
	(Flight.LeadIn must fit the countdown: tests/launch-cam.luau), Client/Audio/Sound (voice keys),
	Client/Platform/Haptics (presets).

	Example:
		local beat = LaunchCamConfig.Countdown.Beat          --> 1
		local voice = LaunchCamConfig.Countdown.Voice[3]     --> "vo_three"
]]

local LaunchCamConfig = {}

-- Master switch (a ReplicatedStorage attribute `KillSwitchAttribute = true` also turns it off live).
LaunchCamConfig.Enabled = true
-- ReplicatedStorage attribute: true = no launch cinematic on this server (admin kill switch).
LaunchCamConfig.KillSwitchAttribute = "SN_LaunchCamOff"

-- Screen name of the overlay (UI/Screens/LaunchCountdown/LaunchCountdownScreen).
LaunchCamConfig.ScreenName = "LaunchCountdown"
-- Non-modal screens faded out while the cinematic plays (Toasts stay: "BOOM! +$X" is the payoff).
LaunchCamConfig.FocusHidden = table.freeze({ "Hud", "AttackHud", "KnockdownHud" } :: { string })

--------------------------------------------------------------------------------------------------
-- Countdown (overlay timing is locked to the server t0)
--------------------------------------------------------------------------------------------------

export type ColorName = "red" | "orange" | "yellow" | "green" | "sky" | "purple" | "blue"

LaunchCamConfig.Countdown = table.freeze({
	-- Seconds per number. 3 numbers -> the countdown starts 3 s before t0.
	Beat = 1.0,
	-- The numbers, in order.
	Steps = table.freeze({ 3, 2, 1 } :: { number }),
	-- Seconds of the server lead-in reserved for the NukeFlight packet to arrive before "3".
	NetSlack = 0.4,
	-- "LAUNCH!" stays this long after t0 (the nuke is lifting off behind it).
	LaunchHold = 1.0,
	-- A beat first seen later than this after it started plays without its voice line (a late
	-- packet never says "three" over "two").
	LateVoiceSeconds = 0.25,
	-- Punch-in: scale from PunchFrom to 1 with a back-out overshoot over PunchSeconds, rotating in
	-- from ±PunchDegrees (alternating side per number).
	PunchFrom = 2.4,
	PunchSeconds = 0.32,
	PunchDegrees = 16,
	-- Last ExitSeconds of a beat: shrink away to ExitScale (stud plates pop out; no alpha fade).
	ExitSeconds = 0.16,
	ExitScale = 0,
	-- Stud badge colour per number, then LAUNCH!.
	Colors = table.freeze({ [3] = "red", [2] = "orange", [1] = "yellow" } :: { [number]: ColorName }),
	LaunchColor = "green" :: ColorName,
	-- Announcer voice keys (AudioConfig.Sfx; a missing key is skipped silently).
	Voice = table.freeze({ [3] = "vo_three", [2] = "vo_two", [1] = "vo_one" } :: { [number]: string }),
	LaunchVoice = "vo_launch",
	-- Haptics presets (Client/Platform/Haptics): a tick per number, a rumble at LAUNCH!.
	BeatHaptic = "Tap",
	LaunchHaptic = "Hit",
	-- Design px of the number badge (square) and the LAUNCH! banner.
	BadgeSize = 300,
	NumberTextSize = 230,
	BannerSize = Vector2.new(820, 210),
	LaunchTextSize = 150,
})

-- One outcome shout: banner text, stud colour, announcer voice key.
export type Shout = { text: string, color: ColorName, voice: string }

-- Outcome shout + announcer line (shown / said for the followed nuke only).
LaunchCamConfig.Outcome = table.freeze({
	Shouts = table.freeze({
		Hit = table.freeze({ text = "DIRECT HIT!", color = "yellow", voice = "vo_direct_hit" }),
		Intercepted = table.freeze({ text = "INTERCEPTED!", color = "sky", voice = "vo_intercepted" }),
		Knockdown = table.freeze({ text = "KNOCKDOWN!", color = "orange", voice = "vo_knockdown" }),
	} :: { [string]: Shout }),
	-- Seconds the shout stays up (punch-in, hold, exit).
	ShowSeconds = 1.6,
	TextSize = 110,
	BannerSize = Vector2.new(760, 170),
})

--------------------------------------------------------------------------------------------------
-- Camera shots (studs / seconds; see Shared/Attack/LaunchCamMath for the formulas)
--------------------------------------------------------------------------------------------------

LaunchCamConfig.Shots = table.freeze({
	-- Silo shot: eye behind the silo (away from the target) and above its mouth, looking ahead /
	-- up along the launch direction. PushIn = share of the back distance the camera dollies in
	-- during the countdown.
	SiloBack = 34,
	SiloUp = 10,
	SiloSide = 10,
	SiloLookAhead = 40,
	SiloLookUp = 10,
	PushIn = 0.25,
	-- After t0 the silo shot holds this long (look follows the rising nuke), then blends into the
	-- chase over ChaseBlend seconds.
	LiftHold = 0.75,
	ChaseBlend = 0.9,
	-- Chase: camera offset from the nuke = back along the horizontal travel + up.
	ChaseBack = 34,
	ChaseUp = 13,
	-- Look point = nuke + look direction x LookAhead; the direction leans toward the horizon by
	-- HorizonBias and toward the target from TargetTurnFrom (share of the flight) on.
	LookAhead = 70,
	HorizonBias = 0.35,
	TargetTurnFrom = 0.4,
	-- Spring stiffness (rad/s) of the chase offset and the look direction (critically damped).
	OffsetOmega = 3.6,
	LookOmega = 5,
	-- Impact approach: over the last ApproachSeconds the camera brakes to a stop on the arc BEHIND
	-- the nuke (camera time slows 1 → 0) while its look turns onto the outcome point, so the nuke
	-- races ahead into the target — the slow-mo feel, camera easing only (never time scaling).
	ApproachSeconds = 1.7,
	-- Impact shot (ground hit): eye back / up / to the side of the impact point.
	ImpactBack = 92,
	ImpactUp = 52,
	ImpactSide = 30,
	-- Intercept shot (mid-air POP): closer and level with the nuke.
	InterceptBack = 62,
	InterceptUp = 16,
	InterceptSide = 22,
	-- Hold on the outcome, slowly orbiting (deg / s); a knockdown adds KnockdownHold. During the
	-- first HoldBlend seconds the camera eases from where it braked into the 3/4 outcome shot.
	Hold = 1.9,
	HoldBlend = 1.3,
	KnockdownHold = 1.6,
	OrbitDegreesPerSecond = 5,
	-- Ease back to the player's camera (normal end / skip).
	ReturnSeconds = 0.9,
	SkipReturnSeconds = 0.35,
	-- Occlusion: shots are pulled in front of anything between the subject and the eye, keeping
	-- this many studs of clearance.
	OcclusionClearance = 3,
	-- Longest frame step fed to the springs (a hitch never flings the camera).
	MaxDt = 1 / 15,
})

LaunchCamConfig.Fov = table.freeze({
	-- Degrees added at lift-off, decaying over KickSeconds.
	LiftKick = 9,
	KickSeconds = 1.1,
	-- Degrees removed (zoom in) by the end of the impact approach.
	ApproachZoom = 10,
	-- Cinematic base FOV while the shots run (the player's own FOV comes back on return).
	Base = 70,
})

LaunchCamConfig.Shake = table.freeze({
	-- Light lift-off shake (studs), decaying over LiftSeconds.
	LiftAmplitude = 0.5,
	LiftSeconds = 0.9,
	-- Small bump at a ground hit.
	ImpactAmplitude = 0.35,
	ImpactSeconds = 0.5,
	-- Base frequency (Hz) of the deterministic noise.
	Frequency = 9,
})

-- Reduce Motion: no shake / FOV kick / orbit / rotation, hard cuts between static shots, instant return.
LaunchCamConfig.Reduced = table.freeze({
	-- Static wide shot of the whole arc, placed this far to the side of the arc's midpoint
	-- (x the flight's horizontal length, clamped).
	WideSideFactor = 0.55,
	WideSideMin = 160,
	WideSideMax = 700,
	WideUp = 60,
	-- Cut to the wide shot this long after t0, and to the impact shot this long before the outcome.
	WideCutAt = 0.6,
	ImpactCutBefore = 1.2,
})

--------------------------------------------------------------------------------------------------
-- Overlay FX budget per FxQuality tier (pooled, built once)
--------------------------------------------------------------------------------------------------

export type FxBudget = { burst: number, confetti: number }

LaunchCamConfig.FxTiers = table.freeze({
	Low = table.freeze({ burst = 5, confetti = 10 }),
	Mid = table.freeze({ burst = 10, confetti = 24 }),
	High = table.freeze({ burst = 16, confetti = 40 }),
} :: { [string]: FxBudget })

LaunchCamConfig.Burst = table.freeze({
	-- Stud brick pieces flying out of each number badge.
	PieceSize = 46,
	Seconds = 0.55,
	-- Design px the pieces travel (min / max, seeded per piece).
	DistanceMin = 220,
	DistanceMax = 420,
	SpinDegrees = 240,
})

LaunchCamConfig.Confetti = table.freeze({
	Seconds = 1.6,
	-- Launch speed (design px / s) range and gravity (design px / s²).
	SpeedMin = 650,
	SpeedMax = 1250,
	Gravity = 1500,
	PieceSize = Vector2.new(18, 30),
	SpinDegrees = 720,
	Colors = table.freeze({
		Color3.fromRGB(255, 86, 120),
		Color3.fromRGB(255, 214, 64),
		Color3.fromRGB(110, 230, 90),
		Color3.fromRGB(84, 176, 255),
		Color3.fromRGB(196, 120, 255),
		Color3.fromRGB(255, 150, 60),
	} :: { Color3 }),
})

-- Letterbox bars (dark stud strips) slide in while the cinematic plays.
LaunchCamConfig.Letterbox = table.freeze({
	-- Share of the canvas height each bar covers.
	Height = 0.075,
	SlideSeconds = 0.35,
})

--------------------------------------------------------------------------------------------------
-- Input + safety
--------------------------------------------------------------------------------------------------

LaunchCamConfig.Input = table.freeze({
	-- Taps / clicks / button presses inside this many seconds after the cinematic opened are
	-- ignored (the click that pressed LAUNCH! never skips its own cinematic).
	SkipGraceSeconds = 0.4,
	-- Extra skip keys bound while active (Back = B / X / Backspace comes from ScreenManager).
	SkipKeys = table.freeze({ Enum.KeyCode.Escape, Enum.KeyCode.ButtonSelect } :: { Enum.KeyCode }),
	-- SKIP button (design px).
	SkipSize = Vector2.new(250, 96),
})

-- Knockdown detection after a ground hit (KnockdownConfig tag + attributes): samples (seconds
-- after the hit) and how close the knock centre must be to the impact (studs).
LaunchCamConfig.KnockdownWatch = table.freeze({
	Samples = table.freeze({ 0.3, 0.7, 1.2 } :: { number }),
	CenterRadius = 140,
	PivotRadius = 320,
	-- "KNOCKDOWN!" + its voice line wait until this long after the hit, so "Direct hit!" (~1.6 s)
	-- finishes first.
	SayAfter = 1.6,
})

-- Watchdog: the cinematic always ends this long after its scheduled return start.
LaunchCamConfig.WatchdogSlack = 2

-- Studio-only verification hook: a number attribute "DebugHoldAt" on the LaunchCountdown
-- ScreenGui freezes the OVERLAY clock at that rel second (screenshots of exact beats).
LaunchCamConfig.DebugHoldAttribute = "DebugHoldAt"

return table.freeze(LaunchCamConfig)
