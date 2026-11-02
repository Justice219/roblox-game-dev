--!strict
--[[
	MovementConfig — player run speed and the client wind effect (owner R21, 2026-10-30: "make the
	player run faster, they feel a little too slow, and add like a wind effect on the screen").

	Server (Server/Services/MovementService): every character gets
		WalkSpeed = clamp(BaseWalkSpeed × product of active multipliers, MinWalkSpeed, MaxWalkSpeed)
	where the multipliers are the owned game passes in `Passes` (FastWalk ×1.35), the active
	personal boosts in `BoostWalkMultipliers` (none today: BoostConfig's speed2x / FeastSpeed boost
	PRODUCTION speed, not running) and any server source set with MovementService.setMultiplier
	(each clamped to MaxSourceMultiplier). Jump: JumpPower (UseJumpPower = true).
	Roblox's default is 16 studs/s; tycoons of this genre run ~24–30 so long plots feel quick.

	Client (Client/Movement/WindController): `Wind` tunes the speed-line overlay, the near-camera
	wind particles and the whoosh. Intensity 0..1 comes from the character's HORIZONTAL speed
	(Client/Movement/WindLogic) — 0 when standing still, full at roughly base run speed.

	Example:
		MovementConfig.walkSpeedFor({ 1.35 })  --> 36.45 (base 27 × FastWalk)
		MovementConfig.walkSpeedFor({})        --> 27
]]

local MovementConfig = {}

-- Run speed (studs / s) every character gets with no pass or boost (Roblox default: 16).
MovementConfig.BaseWalkSpeed = 27
-- Hard bounds of the final WalkSpeed whatever stacks (a bad multiplier never launches a player).
MovementConfig.MinWalkSpeed = 8
MovementConfig.MaxWalkSpeed = 60
-- Largest single multiplier a source may apply (passes, boosts, MovementService.setMultiplier).
MovementConfig.MaxSourceMultiplier = 3
-- Jump: classic JumpPower model (Roblox default 50; a little higher suits the faster run).
MovementConfig.UseJumpPower = true
MovementConfig.JumpPower = 55

-- Game pass key (MonetizationConfig.Passes) → run speed multiplier while owned.
MovementConfig.Passes = table.freeze({
	FastWalk = 1.35,
} :: { [string]: number })

-- Personal boost key (BoostConfig) → run speed multiplier while active. Empty on purpose: today's
-- speed boosts multiply PRODUCTION speed (tycoon modifier boostSpeed), not running. A future
-- "run faster" boost only needs a line here.
MovementConfig.BoostWalkMultipliers = table.freeze({} :: { [string]: number })
-- Seconds between boost re-checks (only runs while BoostWalkMultipliers is non-empty).
MovementConfig.BoostCheckSeconds = 5

--[[
	Client wind effect tunables.
		MinSpeed / FullSpeed     horizontal studs/s: below MinSpeed → no wind; FullSpeed → intensity 1
		Attack / Release         exponential smoothing rates (per second) when speeding up / slowing
		Lines / LinesLowEnd      speed-line count (phones and consoles use the smaller pool)
		LineLength / LineThickness  pixels at intensity 1 (length scales with intensity)
		LineSpeed                fraction of the screen half-diagonal a line travels per second
		LineInner / LineOuter    radial band the lines live in (0 = centre, 1 = corner); the centre
		                         stays clear so the player and the HUD are never covered
		LineMaxOpacity           0..1 opacity of a line at intensity 1 (subtle)
		ParticleRate / ParticleRateLowEnd  near-camera wind particles per second at intensity 1
		ParticleDistance         studs in front of the camera the emitter sits
		WhooshAt / WhooshRearm   intensity that plays the whoosh when crossed upward, and the
		                         intensity it must fall below before it can play again
		WhooshCooldown           seconds between whooshes; WhooshVolume = volume multiplier
		SettingsPollSeconds      how often reduced-motion (profile + platform setting) is re-read
]]
MovementConfig.Wind = table.freeze({
	MinSpeed = 6,
	FullSpeed = 26,
	Attack = 4,
	Release = 6,
	Lines = 14,
	LinesLowEnd = 8,
	LineLength = 140,
	LineThickness = 2,
	LineSpeed = 0.9,
	LineInner = 0.55,
	LineOuter = 1.05,
	LineMaxOpacity = 0.35,
	ParticleRate = 14,
	ParticleRateLowEnd = 6,
	ParticleDistance = 6,
	WhooshAt = 0.6,
	WhooshRearm = 0.2,
	WhooshCooldown = 3,
	WhooshVolume = 0.7,
	WhooshKey = "whoosh",
	SettingsPollSeconds = 0.5,
})

--[[
	The final WalkSpeed for a list of active multipliers. Non-finite / non-positive multipliers are
	ignored, each is capped at MaxSourceMultiplier, and the product is clamped to Min/MaxWalkSpeed.
	@param multipliers active multipliers (passes, boosts, server sources)
	@return studs per second
	Example: MovementConfig.walkSpeedFor({ 1.35, 0 / 0 }) --> 36.45
]]
function MovementConfig.walkSpeedFor(multipliers: { number }): number
	local speed = MovementConfig.BaseWalkSpeed
	for _, multiplier in multipliers do
		if type(multiplier) == "number" and multiplier == multiplier and multiplier > 0 and multiplier < math.huge then
			speed *= math.min(multiplier, MovementConfig.MaxSourceMultiplier)
		end
	end
	return math.clamp(speed, MovementConfig.MinWalkSpeed, MovementConfig.MaxWalkSpeed)
end

return table.freeze(MovementConfig)
