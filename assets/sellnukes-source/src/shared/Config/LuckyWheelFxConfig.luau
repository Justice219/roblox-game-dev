--!strict
--[[
	LuckyWheelFxConfig — every tunable of the Lucky Wheel spin presentation (owner R81: "spin needs
	like a ticker effect and more effects. It's just kind of boring.").

	PRESENTATION ONLY. The server rolls the slice and pays the reward the moment SpinWheel arrives
	(LuckySpinService); the client only animates the disc onto the slice the server sent. Nothing
	here changes what a player gets, or the odds.

	What it tunes (consumers: Client/UI/Screens/LuckyWheel/{init, WheelDrawing, WheelFx, SpinMotion};
	tests/lucky-wheel-fx.luau proves the maths and the config):
		Spin / QuickSpin  launch + slowdown curve, whole turns, the small overshoot + rock-back;
		                  back-to-back spins (2x / 5x / 10x bundles) use the shorter QuickSpin
		WindUp            the back-rotation before launch (it also hides the request round trip)
		Pegs / Flapper    rim pegs on every slice edge and the ticker flapper they knock aside
		Tick              the tick sound: pitch + volume follow the disc speed, a minimum gap
		Bulbs             rim light bulbs: slow chase idle, speed-linked chase spinning, blink on win
		Streaks           translucent motion arcs over the disc while it is fast
		Glow / Rays       the winning slice's pulsing glow and the light rays behind the wheel
		Tiers / SliceTier per-reward celebration size (sting, confetti, shake, rays, haptic)
		Quality           per graphics tier (Widgets/OfferFx.tier()) FX budgets: Low trims the extras

	Angles are degrees clockwise from the top (same as WheelDrawing). Speeds are degrees / second.
	Sound keys are AudioConfig.Sfx keys or aliases (tests check every one resolves).

	Example:
		local tier = LuckyWheelFxConfig.Tiers[LuckyWheelFxConfig.SliceTier.pet] -- jackpot
		print(tier.confetti, #tier.sting) --> 70 5
]]

-- One sound cue: an AudioConfig key with pitch / volume multipliers and a delay (s) after its beat.
export type Cue = { key: string, pitch: number, volume: number, delay: number }
-- A numeric range (inclusive).
export type Range = { Min: number, Max: number }
-- Celebration size names (cheapest → biggest).
export type TierName = "small" | "medium" | "big" | "rare" | "jackpot"

-- One celebration size (see Tiers).
export type Tier = {
	seconds: number, -- glow + rays + bulb blink length
	glow: number, -- peak opacity of the white slice glow (0..1)
	pulseHz: number, -- glow pulses per second
	rays: boolean, -- light rays behind the wheel (also needs Quality.rays)
	confetti: number, -- confetti pieces at High quality
	sparkles: number, -- twinkles around the winning slice at High quality
	sideBursts: boolean, -- extra confetti cannons left + right of the wheel
	shake: number, -- wheel shake amplitude (design px; 0 = none)
	haptic: ("Reward" | "Hatch")?, -- extra Platform/Haptics preset (Hud.notify already buzzes Reward)
	sting: { Cue },
}

-- Ticker flapper tuning (SpinMotion.FlapperTuning + the drawing / write fields).
export type Flapper = {
	MaxDeflect: number,
	Contact: number,
	Stiffness: number,
	Damping: number,
	HitFraction: number,
	Pivot: number,
	WriteStep: number,
}
-- Steps / s per graphics tier (same shape as OfferFxConfig.PerTier, for OfferFx.register).
export type PerTier = { Low: number, Medium: number, High: number }

-- Per graphics tier budgets (Widgets/OfferFx.tier()).
export type Quality = {
	confetti: number, -- multiplier on Tier.confetti
	sparkles: number, -- multiplier on Tier.sparkles
	streaks: boolean, -- motion arcs while fast
	rays: boolean, -- win rays behind the wheel
	shake: boolean,
}

local LuckyWheelFxConfig = {}

--[[
	A normal spin. Its launch + slowdown take LuckySpinConfig.SpinAnimationSeconds in total (the
	shared spin length); the wind-up and the rock-back come on top (~0.6 s together).
	Speed curve (SpinMotion.plan): the disc accelerates to top speed in `Launch` s, then slows with
	ω ∝ (1 − u)^Power — a higher Power spends longer creeping at the end (the suspense). It lands
	`Overshoot` degrees past the slice centre and rocks back in `Settle` s (no peg is crossed: the
	slice centre is half a peg gap from the nearest peg).
]]
LuckyWheelFxConfig.Spin = table.freeze({
	Turns = 5, -- whole turns before the landing delta
	Launch = 0.22,
	Power = 1.6,
	Overshoot = 2.5,
	Settle = 0.34,
})

--[[
	Back-to-back spins (a 2x / 5x / 10x bundle spent one press after another): a press within
	WindowSeconds of the last landing spins fewer turns and Scale × as long, so ten spins never
	mean ten slow waits. Still ticks, still celebrates (the server rate limit is 0.5 spins / s).
]]
LuckyWheelFxConfig.QuickSpin = table.freeze({
	WindowSeconds = 8,
	Turns = 3,
	Scale = 0.62,
})

--[[
	Wind-up: the disc is pulled back `Degrees` (eased) the moment SPIN is pressed, then trembles
	(`Tremble` degrees at `TrembleHz`) until the server's answer arrives, then launches. A refusal or
	timeout eases it forward again in `Unwind` s. Degrees stays below half a peg gap, so pulling
	back from a slice centre presses the flapper against the peg behind it without crossing it.
]]
LuckyWheelFxConfig.WindUp = table.freeze({
	Degrees = 16,
	Seconds = 0.3,
	QuickSeconds = 0.18,
	Tremble = 0.6,
	TrembleHz = 16,
	Unwind = 0.22,
})

--[[
	Rim pegs (drawn on the disc, so they turn with it). PerSlice must be ODD: the wheel rests on a
	slice centre, and with an odd count that centre sits exactly halfway between two pegs.
	1 = one peg on every slice edge (the divider).
]]
LuckyWheelFxConfig.Pegs = table.freeze({
	PerSlice = 1,
	Radius = 0.955, -- peg centre distance from the hub (× disc radius)
	Size = 0.036, -- peg diameter (× disc diameter)
	Color = Color3.fromRGB(255, 222, 92),
	Edge = 2, -- dark outline (px)
})

--[[
	The ticker flapper (the top pointer, hinged near its top). A peg within `Contact` degrees
	before the pointer pushes the tip aside (up to `MaxDeflect` degrees just before it slips past),
	then a damped spring (`Stiffness`, `Damping`; per second²) snaps it back with a little
	overshoot. A peg that crosses completely inside one frame (fast spin) knocks it to
	HitFraction × MaxDeflect. Pivot = hinge height as a fraction of the pointer's height.
]]
LuckyWheelFxConfig.Flapper = table.freeze({
	MaxDeflect = 26,
	Contact = 9,
	Stiffness = 900,
	Damping = 19,
	HitFraction = 0.85,
	Pivot = 0.22,
	-- Rotation writes are quantised to this many degrees (no write when it did not move).
	WriteStep = 0.2,
}) :: Flapper

--[[
	The tick: one per peg crossing, at most one per MinGap seconds (a fast spin becomes a rattle,
	the slowdown spaces the ticks out by itself). Pitch and volume (multipliers on the sound's
	AudioConfig spec) rise with speed / TopSpeed. `Key` is the AudioConfig alias "wheel_tick".
]]
LuckyWheelFxConfig.Tick = table.freeze({
	Key = "wheel_tick",
	MinGap = 0.045,
	TopSpeed = 1300,
	Pitch = table.freeze({ Min = 0.86, Max = 1.42 }) :: Range,
	Volume = table.freeze({ Min = 0.75, Max = 1.1 }) :: Range,
})

-- One-shot cues around the spin itself.
LuckyWheelFxConfig.Sounds = table.freeze({
	-- Wind-up: a low creak of the flapper meeting the peg.
	WindUp = table.freeze({ key = "wheel_tick", pitch = 0.62, volume = 1, delay = 0 }) :: Cue,
	-- Launch: a whoosh as the disc leaves.
	Launch = table.freeze({ key = "whoosh", pitch = 1.25, volume = 1.8, delay = 0 }) :: Cue,
})

--[[
	Rim light bulbs on the white rim (they never turn). `Count` evenly spaced from the top; the top
	one is skipped (the pointer sits there). Every `Group`-th bulb is lit and the lit set steps
	clockwise: IdleHz steps / s while idle (via Widgets/OfferFx, parked on Low graphics and with
	Reduce Motion), SpinHz.Min → Max with speed while spinning, and on a win every bulb blinks in
	the winning slice's colour at WinBlinkHz.
]]
LuckyWheelFxConfig.Bulbs = table.freeze({
	Count = 24,
	Group = 3,
	IdleHz = 2.5,
	SpinHz = table.freeze({ Min = 6, Max = 22 }) :: Range,
	WinBlinkHz = 5,
	Size = 0.62, -- bulb diameter (× rim width)
	Edge = 2,
	Lit = Color3.fromRGB(255, 240, 160),
	Dim = Color3.fromRGB(168, 150, 112),
	-- OfferFx step rate of the idle chase per graphics tier (Low = parked, art stays).
	IdleRates = table.freeze({ Low = 0, Medium = 10, High = 12 }) :: PerTier,
})

--[[
	Motion arcs over the disc while it is fast: Arcs × Segments short tangent bars (head opaque,
	tail fading, trailing behind the motion) that turn with the disc. Opacity rises from 0 at
	StartSpeed to MaxOpacity at FullSpeed (quantised to Step so a steady speed writes nothing).
]]
LuckyWheelFxConfig.Streaks = table.freeze({
	Radii = table.freeze({ 0.64, 0.82 }), -- arc radii (× disc radius); arcs per radius = Copies
	Copies = 3,
	Segments = 7,
	SegmentDegrees = 8,
	Width = 0.012, -- bar thickness (× disc diameter)
	StartSpeed = 260,
	FullSpeed = 900,
	MaxOpacity = 0.5,
	Step = 0.05,
})

--[[
	The winning slice's glow: a white wedge over the slice under the pointer (a small CanvasGroup;
	only its GroupTransparency pulses, the content never re-renders).
	Rays: light rays behind the wheel in the slice's colour, turning slowly, faded in / out.
]]
LuckyWheelFxConfig.Glow = table.freeze({
	EdgeInset = 1.4, -- degrees kept clear of the slice's dark dividers
	Length = 0.965, -- wedge reach (× disc radius; stays inside the disc edge)
})
LuckyWheelFxConfig.Rays = table.freeze({
	Count = 10, -- bars through the centre (two rays each)
	Size = 1.9, -- burst diameter (× wheel side)
	Width = 0.07, -- bar width (× burst size)
	DegreesPerSecond = 24,
	Opacity = 0.55, -- brightest point
	FadeIn = 0.25,
	FadeOut = 0.5,
	Whiten = 0.35, -- slice colour lerped this far toward white
})

--[[
	The "You won ...!" pop over the wheel: the slice's icon above the text, both punch in.
	PopSeconds is how long it stays (a new spin hides it earlier).
]]
LuckyWheelFxConfig.Pop = table.freeze({
	Seconds = 2.6,
	IconSize = 120,
	StartScale = 0.45,
	PunchSeconds = 0.36,
})

--[[
	Celebration sizes. Stings scale with the reward: a soft claim for the small slices, coins for
	the mid ones, a fanfare + fireworks for the EGG and the RARE PET (the jackpot also gets side
	confetti cannons, the strongest shake and a Hatch rumble).
]]
local TIERS: { [TierName]: Tier } = {
	small = {
		seconds = 1.3,
		glow = 0.4,
		pulseHz = 2.2,
		rays = false,
		confetti = 18,
		sparkles = 4,
		sideBursts = false,
		shake = 0,
		haptic = nil,
		sting = {
			{ key = "ui_claim", pitch = 1, volume = 1, delay = 0 },
			{ key = "sparkle", pitch = 1.1, volume = 0.6, delay = 0.06 },
		},
	},
	medium = {
		seconds = 1.6,
		glow = 0.45,
		pulseHz = 2.4,
		rays = false,
		confetti = 28,
		sparkles = 6,
		sideBursts = false,
		shake = 3,
		haptic = nil,
		sting = {
			{ key = "kaching", pitch = 1, volume = 0.9, delay = 0 },
			{ key = "sparkle", pitch = 1.05, volume = 0.7, delay = 0.08 },
		},
	},
	big = {
		seconds = 2,
		glow = 0.5,
		pulseHz = 2.6,
		rays = true,
		confetti = 40,
		sparkles = 8,
		sideBursts = false,
		shake = 5,
		haptic = nil,
		sting = {
			{ key = "coin_burst", pitch = 1, volume = 1, delay = 0 },
			{ key = "milestone", pitch = 1, volume = 0.9, delay = 0.05 },
		},
	},
	rare = {
		seconds = 2.6,
		glow = 0.55,
		pulseHz = 3,
		rays = true,
		confetti = 56,
		sparkles = 12,
		sideBursts = false,
		shake = 7,
		haptic = "Hatch",
		sting = {
			{ key = "fanfare", pitch = 1, volume = 1, delay = 0 },
			{ key = "sparkle", pitch = 1.15, volume = 0.8, delay = 0.12 },
			{ key = "firework_pop", pitch = 1.05, volume = 0.9, delay = 0.35 },
		},
	},
	jackpot = {
		seconds = 3.2,
		glow = 0.6,
		pulseHz = 3.4,
		rays = true,
		confetti = 70,
		sparkles = 16,
		sideBursts = true,
		shake = 9,
		haptic = "Hatch",
		sting = {
			{ key = "fanfare", pitch = 1, volume = 1, delay = 0 },
			{ key = "lucky_claim", pitch = 1, volume = 0.9, delay = 0.1 },
			{ key = "firework_whistle", pitch = 1.1, volume = 0.8, delay = 0.05 },
			{ key = "firework_pop", pitch = 1, volume = 1, delay = 0.45 },
			{ key = "firework_pop", pitch = 1.2, volume = 0.9, delay = 0.72 },
		},
	},
}
for _, tier in TIERS do
	for _, cue in tier.sting do
		table.freeze(cue)
	end
	table.freeze(tier.sting)
	table.freeze(tier)
end
LuckyWheelFxConfig.Tiers = table.freeze(TIERS)

--[[
	Which celebration each LuckySpinConfig slice id gets (tests: every slice has one). Unknown ids
	fall back to DefaultTier.
]]
local SLICE_TIER: { [string]: TierName } = {
	cashS = "small",
	gemsS = "small",
	cashM = "medium",
	boost = "medium",
	cashL = "big",
	gemsL = "big",
	egg = "rare",
	pet = "jackpot",
}
LuckyWheelFxConfig.SliceTier = table.freeze(SLICE_TIER)
local DEFAULT_TIER: TierName = "small"
LuckyWheelFxConfig.DefaultTier = DEFAULT_TIER

--[[ Per graphics tier FX budgets (Widgets/OfferFx.tier(): Roblox's quality slider). ]]
LuckyWheelFxConfig.Quality = table.freeze({
	Low = table.freeze({ confetti = 0.35, sparkles = 0.4, streaks = false, rays = false, shake = true }) :: Quality,
	Medium = table.freeze({ confetti = 0.65, sparkles = 0.7, streaks = true, rays = true, shake = true }) :: Quality,
	High = table.freeze({ confetti = 1, sparkles = 1, streaks = true, rays = true, shake = true }) :: Quality,
})

-- Pooled confetti / sparkle pieces (Screens/EggHatch/HatchConfetti, built once with the screen).
LuckyWheelFxConfig.ConfettiPool = 96

--[[
	The celebration for slice id `sliceId` (DefaultTier for an unknown id).
	@param sliceId LuckySpinConfig slice id
	@return Tier, TierName
	Example: LuckyWheelFxConfig.tierFor("egg").rays --> true
]]
function LuckyWheelFxConfig.tierFor(sliceId: string): (Tier, TierName)
	local name = LuckyWheelFxConfig.SliceTier[sliceId] or LuckyWheelFxConfig.DefaultTier
	return TIERS[name], name
end

--[[
	Every sound key the wheel can play (Sound.warm on the first open, tests check them).
	@return { string } (deduplicated)
]]
function LuckyWheelFxConfig.soundKeys(): { string }
	local seen: { [string]: boolean } = {}
	local keys: { string } = {}
	local function add(key: string)
		if not seen[key] then
			seen[key] = true
			table.insert(keys, key)
		end
	end
	add(LuckyWheelFxConfig.Tick.Key)
	add(LuckyWheelFxConfig.Sounds.WindUp.key)
	add(LuckyWheelFxConfig.Sounds.Launch.key)
	for _, tier in TIERS do
		for _, cue in tier.sting do
			add(cue.key)
		end
	end
	table.sort(keys)
	return keys
end

return table.freeze(LuckyWheelFxConfig)
