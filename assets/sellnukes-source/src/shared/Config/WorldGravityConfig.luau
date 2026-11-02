--!strict
--[[
	WorldGravityConfig — tunables of the per-world gravity twist (owner R70 "a space world": Moon
	Base has low gravity) and its landing feedback (Client/Worlds/WorldGravity).

	The SCALE itself is world data: `WorldClientConfig.Physics[worldId].gravityScale` (W9b owns the
	world rows; a missing row = 1 = normal gravity). This file only holds the limits every scale is
	clamped to and the landing "boing + dust puff" tuning, so a new low-gravity world needs one
	config row and no code.

	Physics (what the scale changes, for the record): the client sets
	Workspace.Gravity = default x scale while the player's CurrentWorld is that world. The player's
	own character is client-simulated, so only their jumps change: with MovementConfig.JumpPower 55
	a jump reaches 55² / (2 x 196.2 x 0.4) ~ 19.3 studs at 0.4 (7.7 at 1) and hangs 1.4 s (0.56 s).
	Server reach checks are touch / prompt based or have a generous vertical allowance (see
	docs/tycoon-client.md "Low gravity"); world boundary walls are 60 studs tall.

	Connects to: Client/Worlds/{WorldGravity, GravityLogic}, tests/world-gravity.luau.

	Example:
		local scale = GravityLogic.scaleFor(WorldClientConfig.Physics, "moon", WorldGravityConfig.Limits) --> 0.4
]]

export type Limits = {
	MinScale: number, -- smallest accepted gravityScale (anything lower is clamped up)
	MaxScale: number, -- largest accepted gravityScale
}

export type Landing = {
	FxBelowScale: number, -- landing feedback only in worlds whose scale is below this (low gravity)
	MinFallSpeed: number, -- studs/s of downward speed at touchdown below which a landing is silent
	Sound: string, -- AudioConfig.Sfx key (H1-cashfx: a soft cartoon "boing", 2D for your own landing)
	PitchBase: number, -- PlaybackSpeed multiplier for the softest audible landing ...
	PitchPerSpeed: number, -- ... rising this much per stud/s of fall speed above MinFallSpeed ...
	PitchMaxBonus: number, -- ... up to this much higher (bigger landings boing a little higher)
	Volume: number, -- volume multiplier on the key's volume
}

export type Puff = {
	Texture: string, -- built-in soft smoke texture (ships with every client)
	Color: Color3, -- moon-dust lilac grey (darker than the ground it lands on)
	CountMin: number, -- particles for the softest audible landing ...
	CountMax: number, -- ... up to this for a big one ...
	CountPerSpeed: number, -- ... adding this many per stud/s above MinFallSpeed
	LowTierScale: number, -- FxQuality "Low": particle count multiplier (phones)
	Lifetime: NumberRange,
	Speed: NumberRange, -- outward speed (studs/s), slowed quickly by Drag
	Drag: number,
	SpreadDeg: number, -- cone half-angle from straight up: ~80 = a flat ring along the ground
	Rise: number, -- upward acceleration (studs/s²): the dust drifts up a little as it fades
	SizeStart: number,
	SizeEnd: number,
	TransparencyStart: number,
}

return table.freeze({
	Limits = table.freeze({ MinScale = 0.1, MaxScale = 2 }) :: Limits,
	Landing = table.freeze({
		FxBelowScale = 0.999,
		MinFallSpeed = 14,
		Sound = "moon_boing",
		PitchBase = 0.9,
		PitchPerSpeed = 1 / 120,
		PitchMaxBonus = 0.3,
		Volume = 1,
	}) :: Landing,
	Puff = table.freeze({
		Texture = "rbxasset://textures/particles/smoke_main.dds",
		-- A shade darker than Moon Base's near-white lilac ground, so the ring reads on it (the first
		-- Studio pass used (214, 206, 232): invisible on the white plots).
		Color = Color3.fromRGB(170, 162, 200),
		CountMin = 8,
		CountMax = 16,
		CountPerSpeed = 0.25,
		LowTierScale = 0.5,
		Lifetime = NumberRange.new(0.6, 1.1), -- long enough to read, gone before the next jump lands
		Speed = NumberRange.new(5, 9),
		Drag = 5,
		SpreadDeg = 80,
		Rise = 2,
		SizeStart = 1.4,
		SizeEnd = 4,
		TransparencyStart = 0.2,
	}) :: Puff,
})
