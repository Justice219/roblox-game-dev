--!strict
--[[
	JuiceConfig — tunables of the R71 juice pass (owner: "better sound effects, more visual effects
	… retention max"; Nuke Town's content and numbers do NOT change). Cosmetic only: nothing here
	is an amount, a price, a reward or a timer the server uses.

	Sections:
		Combo        click combo ladder (pitch climb, "x12!" label, sparkle ring, big bursts)
		PadBuy       coin burst + layered "pad_buy" pop when a pad is bought
		Milestone    centre banner "LEVEL 50!" / "x2 SPEED!" + ding when a producer crosses one
		Fireworks    pooled toy rockets (whistle up, sparkly pop) for unlocks / rebirths
		AreaUnlock   fireworks over a new area + a camera punch (your own unlock)
		Rebirth      soft white flash + fireworks + punch (the sting is SoundController's)
		Finale       big confetti cannon when a world's finale statue finishes building in
		Punch        CameraPunch defaults (FOV kick + tiny shake)
		Ambient      gentle income sparkles over your automated producers
		Manager      puff + "manager_hired" when a producer gets its manager
		UpgradeGlow  soft gold glow on a producer you just upgraded
	Per-tier tables are keyed by Tycoon/Fx/FxQuality tiers ("Low" | "Mid" | "High"). Reduce Motion
	(Roblox or SellNukes setting) removes every shake, punch, flash and moving burst; sounds stay.

	Connects to: Client/Tycoon/Fx/{JuiceRules, JuiceController, ClickCombo, CameraPunch, Fireworks,
	JuiceParticles, JuiceBanner, ProducerJuice}, tests/juice.luau.

	Example: JuiceConfig.Combo.Window --> 0.7
]]

export type PerTier = { Low: number, Mid: number, High: number }

local function tier(low: number, mid: number, high: number): PerTier
	local value: any = table.freeze({ Low = low, Mid = mid, High = high })
	return value
end

return table.freeze({
	Combo = table.freeze({
		-- Seconds between two presses on your own manual producers that keep a combo going. Every
		-- press counts (also one on a producer still mid-cycle): the combo is pure feedback.
		Window = 0.7,
		-- Click sound pitch ladder: one semitone per press from 1.0, capped at MaxPitch.
		SemitonesPerStep = 1,
		MaxPitch = 1.6,
		Sound = "combo_tick",
		Volume = 0.55,
		-- The "x12!" label shows from this combo on, over the producer, and fades LabelHold s after
		-- the last press.
		LabelFrom = 2,
		LabelHold = 0.9,
		LabelFade = 0.25,
		LabelPunch = 0.35, -- extra scale on each press (eases back over PunchSeconds)
		PunchSeconds = 0.16,
		LabelStuds = Vector2.new(7, 2.6), -- BillboardGui size (studs)
		LabelRise = -3.2, -- studs from the producer's pop point (negative: under the "+$X" pop start)
		PopPointRange = 40, -- use the pop point only when it is this close to the producer anchor
		LabelAbove = 2, -- otherwise: studs above the producer anchor's top
		LabelMaxDistance = 120,
		LabelPool = 2,
		-- A sparkle ring every RingEvery presses; a big burst at BigAt (and every BigEvery after).
		RingEvery = 10,
		RingSparkles = tier(10, 16, 24),
		BigAt = table.freeze({ 25, 50, 100 }) :: { number },
		BigEvery = 100,
		BigSound = "coin_burst",
		BigConfetti = tier(14, 24, 36),
		BigSparkles = tier(8, 14, 20),
		BigPunch = 0.35, -- camera punch strength at the 100 / every-100 bursts (0 = none)
	}),

	PadBuy = table.freeze({
		Sound = "pad_buy",
		Coins = tier(5, 9, 14),
		Sparkles = tier(4, 8, 12),
		Rise = 2.5, -- studs above the pad pivot
	}),

	Milestone = table.freeze({
		Sound = "milestone",
		BannerSeconds = 2.4,
		BannerCooldown = 0.5, -- a newer milestone replaces the banner after this long
		Confetti = tier(10, 18, 28),
		Sparkles = tier(6, 10, 16),
	}),

	Fireworks = table.freeze({
		Pool = 8, -- pooled rockets (each: a trail emitter + a burst emitter)
		RiseSeconds = 0.9, -- whistle up ...
		RiseJitter = 0.2,
		Height = 26, -- ... this many studs (+- HeightJitter)
		HeightJitter = 6,
		Spread = 16, -- launch points spread around the centre (studs)
		Stagger = 0.22, -- seconds between launches
		Sparks = tier(18, 30, 44), -- sparks per burst
		WhistleSound = "firework_whistle",
		PopSound = "firework_pop",
		WhistleVolume = 0.5,
		PopVolume = 0.7,
		MaxDistance = 260, -- farther shows are skipped (not your view)
	}),

	AreaUnlock = table.freeze({
		Rockets = tier(2, 4, 6),
		Punch = 0.6,
		PunchDelay = 0.05,
	}),

	Rebirth = table.freeze({
		Rockets = tier(3, 5, 8),
		Punch = 0.8,
		FlashSeconds = 0.55,
		FlashPeak = 0.55, -- peak opacity of the warm white overlay (soft: never a hard white frame)
	}),

	Finale = table.freeze({
		Volleys = 3, -- confetti cannon volleys
		VolleyGap = 0.35,
		Confetti = tier(30, 60, 90),
		Sparkles = tier(12, 24, 36),
		Rockets = tier(3, 6, 8),
		Punch = 0.7,
	}),

	Punch = table.freeze({
		FovKick = 7, -- degrees at strength 1
		Shake = 0.22, -- studs at strength 1
		Seconds = 0.45,
		ShakeHz = 23,
	}),

	Ambient = table.freeze({
		Refresh = 1, -- seconds between re-ranking the nearest automated producers
		Range = 90, -- studs from the camera
		Emitters = tier(2, 4, 6), -- pooled sparkle emitters (nearest automated producers)
		Rate = 1.6, -- sparkles per second per producer
		Rise = 3.5, -- studs above the anchor
	}),

	Manager = table.freeze({
		Sound = "manager_hired",
		Puff = tier(8, 14, 20),
		Sparkles = tier(6, 10, 14),
	}),

	UpgradeGlow = table.freeze({
		Seconds = 0.55,
		Pool = 2, -- pooled Highlights (engine limit is 31 per client: stay tiny)
		FillTransparency = 0.6, -- brightest fill (soft gold, owner R19: never neon)
		OutlineTransparency = 0.35,
		Color = Color3.fromRGB(255, 214, 92),
		Gap = 0.25, -- min seconds between two glows on the same producer (MAX buys)
		Sparkles = tier(3, 5, 8),
	}),
})
