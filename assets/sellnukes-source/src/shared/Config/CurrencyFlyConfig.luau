--!strict
--[[
	CurrencyFlyConfig — tunables of the HUD "money flies into the counter" effect (owner R46: "add
	particles on screen going into the money on the top").

	Purpose:
		Presentation numbers only — never an amount, price or reward. Cash / gem sprites burst from
		where the money came from (a producer's pop point, the screen centre for rewards, purchases
		and the offline claim) and fly on a curved path into the HUD counter, which bumps + glints
		with a soft coin tick as each one lands. The counter's number itself is the server's.

	Units:
		Distances are in "icon units": multiples of the on-screen size (px) of the HUD counter's
		icon, so the effect scales with the device (phone / tablet / desktop / TV) for free.
		Times are seconds. Counts are particles per burst at the High graphics tier.

	Connects to: Client/UI/Hud/CurrencyFlyRules (pure maths), Client/UI/Hud/CurrencyFly (driver),
	Client/UI/Hud/HudCurrency (bump / glint), tests/currency-fly.luau.

	Example: CurrencyFlyConfig.Sources.reward.Max --> 20
]]

export type Source = "click" | "tick" | "reward" | "purchase" | "offline"

export type SourceSpec = {
	Min: number, -- particles for a tiny amount (High tier)
	Max: number, -- particles for an amount at / above 10^LogHigh
	Reduced: number, -- most particles with Reduce Motion on (short straight fades)
	Sparkles: number, -- share of the burst drawn as white sparkles (no landing tick)
	Gap: number, -- min seconds between two bursts of this source (merges spam)
	Big: boolean, -- centre-of-screen burst: full-circle spread, longer flight
}

-- Freezes one source row (re-typed as SourceSpec: frozen tables are read-only to the solver).
local function spec(value: SourceSpec): SourceSpec
	local frozen: any = table.freeze(value)
	return frozen
end

return table.freeze({
	-- Most sprites alive at once = the pool size (all built at start: no Instance.new afterwards).
	Capacity = 40,
	-- Overlay ScreenGui order: above the HUD (5) and windows (20), below toasts (45) and the
	-- press-feedback layer (1000), so reward coins fly over the window they were claimed from.
	DisplayOrder = 40,

	-- Particle counts per source. "click" = a clicked producer's payout, "tick" = an automated
	-- producer's payout (occasional: one small burst per Gap at most, on-screen producers only).
	Sources = table.freeze({
		click = spec({ Min = 2, Max = 4, Reduced = 1, Sparkles = 0, Gap = 0.08, Big = false }),
		tick = spec({ Min = 1, Max = 2, Reduced = 1, Sparkles = 0, Gap = 1.2, Big = false }),
		reward = spec({ Min = 12, Max = 20, Reduced = 3, Sparkles = 0.25, Gap = 0.25, Big = true }),
		purchase = spec({ Min = 12, Max = 20, Reduced = 3, Sparkles = 0.25, Gap = 0.25, Big = true }),
		offline = spec({ Min = 14, Max = 20, Reduced = 3, Sparkles = 0.25, Gap = 0.5, Big = true }),
	}) :: { [string]: SourceSpec },
	-- Amounts map onto Min..Max by log10 between these exponents (1 .. 1 trillion).
	LogLow = 0,
	LogHigh = 12,
	-- Fraction used when the amount is unknown (e.g. the offline claim when its payload was missed).
	UnknownFraction = 0.75,
	-- Count multiplier per Tycoon/Fx/FxQuality tier (owner: Low graphics = a third).
	TierScale = table.freeze({ Low = 1 / 3, Mid = 0.7, High = 1 }) :: { [string]: number },

	-- Sprite look.
	Sprite = table.freeze({
		Scale = 0.62, -- sprite size = counter icon size x this
		SparkleScale = 0.42,
		MinPx = 14,
		MaxPx = 72,
		StartScale = 0.45, -- pops out small ...
		PeakScale = 1, -- ... grows during the burst ...
		LandScale = 0.55, -- ... and shrinks into the counter
		FadeIn = 0.08, -- share of the life spent fading in
		GemSpin = 0.4, -- gems turn slower than cash bills
	}),

	-- Flight path (icon units / seconds / degrees).
	Path = table.freeze({
		Duration = 0.85, -- reward / purchase / offline flight
		SmallDuration = 0.62, -- click / tick flight
		DurationJitter = 0.12,
		BurstShare = 0.3, -- share of the life spent popping out to the burst point
		BurstMin = 0.9, -- burst radius range (big bursts)
		BurstMax = 2.6,
		SmallBurst = 0.5, -- radius multiplier for click / tick bursts (upper arc only)
		OriginJitter = 0.35, -- start spread around the origin (big bursts; small = a third)
		Momentum = 0.75, -- first control point keeps the burst's outward momentum
		CurveMin = 0.12, -- sideways bend of the swoop, share of the remaining distance
		CurveMax = 0.32,
		ApproachDrop = 1.3, -- sprites arrive from just below the counter (swoop up into it)
		FlyEase = 1.8, -- >1: accelerates into the counter
		Stagger = 0.028, -- start delay per sprite
		MaxStagger = 0.42,
		StaggerJitter = 0.05,
		SpinMin = 90,
		SpinMax = 320,
	}),

	-- Reduce Motion: sprites appear just under the counter and rise straight into it while fading.
	Reduced = table.freeze({
		Duration = 0.45,
		Rise = 1.1, -- start this far below the counter
		Spread = 0.5, -- sideways spread of the starts
		Scale = 0.8,
		Stagger = 0.06,
	}),

	-- Landing feedback on the counter.
	Land = table.freeze({
		BumpGap = 0.05, -- most one icon pop per this many seconds
		BumpScale = 1.22, -- icon pop size
		BumpSeconds = 0.08, -- up; the settle back takes twice as long
		GlintGap = 0.12, -- sparkle + number flash
		GlintSeconds = 0.32,
		GlintLighten = 0.45, -- number flashes this much towards white
		TickGap = 0.07, -- most one coin tick per this many seconds
		TickVolume = 0.35, -- multiplier on the key's volume (soft)
		TickPitch = 1.15, -- first tick of a streak ...
		TickPitchStep = 0.04, -- ... each next landing a little higher ...
		TickPitchMax = 1.6, -- ... up to this
		StreakReset = 0.6, -- seconds without a landing that restart the pitch climb
		-- Landing tick per fly kind (a world currency without a row ticks like cash; R57 Bones).
		Sounds = table.freeze({ cash = "cash_small", gems = "sparkle", bones = "cash_small" }) :: {
			[string]: string,
		},
	}),

	-- Which cash increases are rewards / purchases (flown from the screen centre). A profile cash
	-- increase counts as a grant only when it beats the expected income (rate x time + producer
	-- payouts) AND a reward toast / PurchaseGranted arrives within the windows below, in either
	-- order (reward toasts arrive before the profile push; PurchaseGranted after the save).
	Attribution = table.freeze({
		HintAfter = 1.5, -- a reward / purchase signal waits this long for its cash
		GrantBefore = 8, -- unexplained cash waits this long for its signal
		IncomeSlack = 2, -- expected income x this (+ RateGrace seconds) is "just income"
		RateGrace = 1,
		PopSlack = 1.5, -- producer payouts seen in the last PopWindow s x this are "just income"
		PopWindow = 1.5,
		MaxDt = 2, -- seconds of income at most between two pushes
		MinShare = 0.5, -- the unexplained part must be at least this share of the increase
		OfflineAbsorb = 3, -- s after the welcome-back window opens: its cash is the offline payout
	}),

	-- World sources (producer payouts).
	World = table.freeze({
		MaxDistance = 180, -- studs from the camera; farther producers never spawn sprites
		EdgeMargin = 8, -- px: a point this close to the screen edge counts as off-screen
		-- A manual producer's payout is a "click" only this many seconds past its cycle after the
		-- player's own click; auto-clicker chained payouts are occasional "tick"s.
		ClickGrace = 1.5,
	}),

	-- The offline-earnings popup; its close is the "claim" that flies the payout in.
	OfflineScreen = "WelcomeBack",
})
