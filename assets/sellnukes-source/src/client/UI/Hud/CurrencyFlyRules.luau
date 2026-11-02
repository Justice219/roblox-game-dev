--!strict
--[[
	CurrencyFlyRules — pure maths of the "money flies into the counter" effect (owner R46).

	Purpose:
		No Instances, no services: Lune-testable decisions used by UI/Hud/CurrencyFly.
			fraction(amount)                    0..1 position of an amount on the log10 scale
			count(source, amount, tier, reduced) sprites per burst (log-scaled, tier-scaled, capped
			                                    with Reduce Motion)
			sparkles(source, n)                 how many of those n are white sparkles
			admit(requested, live, capacity)    how many fit under the global cap
			plan(out, seed, index, source, x0, y0, unit, reduced)
			                                    fills one sprite's flight constants (no allocation:
			                                    the driver re-uses one Plan table per pooled sprite)
			pose(plan, age, tx, ty)             where that sprite is `age` s after the burst, flying
			                                    to the counter at (tx, ty) (read every frame, so a
			                                    re-laid-out HUD still catches it)
			grantPart(delta, rate, dt, popSum)  the share of a cash increase that is NOT income
			payoutSource(automated, sinceClick, cycleTime)
			                                    "click" right after a real click, else "tick"
			newMatcher / onGrant / onHint / clearGrant
			                                    pairs unexplained cash with a reward / purchase
			                                    signal in either order
			counterFor(kind, worldCurrency) the counter a kind lands on in the current world (R61)
			isIncrease(previous, value)      only real increases may fly (spends never, R61)
			isKind(kind) / iconOf(kind) / sound(kind)
			                                    the fly kinds (owner R57 World 2): "cash", "gems" and
			                                    every world currency ("bones", ...) with their sprite
			                                    icon and landing sound

	Flight (full motion): POP out from the origin to a seeded burst point (ease-out, growing),
	then SWOOP on a cubic bezier into the counter: the first control keeps the burst's outward
	momentum, the second sits just under the counter with a seeded sideways bend, so sprites curve
	and arrive moving upward, accelerating (t ^ FlyEase) and shrinking, spinning all the way.
	Reduce Motion: a short straight rise from just under the counter with a fade in / out.

	Connects to: Shared/Config/CurrencyFlyConfig (all numbers), Shared/Config/Worlds/WorldsConfig
	(world currency kinds), UI/Hud/CurrencyFly (the only caller), tests/currency-fly.luau.

	Example:
		local plan = Rules.newPlan()
		Rules.plan(plan, 7, 1, "reward", 960, 540, 48, false)
		local x, y, rotation, scale, transparency, done = Rules.pose(plan, 0.3, 960, 40)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config.CurrencyFlyConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

export type Source = Config.Source

-- One sprite's flight constants (canvas px / seconds / degrees). Filled by plan(), read by pose().
export type Plan = {
	x0: number, -- start
	y0: number,
	bx: number, -- burst point (Reduce Motion: start offset from the counter)
	by: number,
	c1x: number, -- first bezier control (momentum)
	c1y: number,
	side: number, -- signed sideways bend, share of the burst->counter distance
	drop: number, -- px under the counter of the second control
	delay: number,
	duration: number,
	spin: number, -- deg / s (signed)
	rot0: number,
	scale: number, -- size multiplier (sparkles are smaller)
	reduced: boolean,
}

-- Pairs unexplained cash increases with reward / purchase signals (see onGrant / onHint).
export type Matcher = {
	grant: number,
	grantAt: number,
	hint: Source?,
	hintAt: number,
}

local Rules = {}

local Sources = Config.Sources
local Path = Config.Path
local Sprite = Config.Sprite
local Reduced = Config.Reduced
local Attribution = Config.Attribution

-- A finite number, else nil (NaN / inf / non-numbers never reach the maths).
local function finite(value: unknown): number?
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- Deterministic 0..1 noise for (seed, k): the same seed always draws the same sprite.
local function noise(seed: number, k: number): number
	local v = math.sin(seed * 12.9898 + k * 78.233) * 43758.5453
	return v - math.floor(v)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

--[[
	Where `amount` sits between 10^LogLow and 10^LogHigh (0..1). Unknown / invalid -> nil.
	Example: Rules.fraction(1e6) --> 0.5 (with LogLow 0, LogHigh 12)
]]
function Rules.fraction(amount: unknown): number?
	local value = finite(amount)
	if value == nil or value <= 0 then
		return nil
	end
	local exponent = math.log10(math.max(value, 1))
	return math.clamp((exponent - Config.LogLow) / math.max(Config.LogHigh - Config.LogLow, 1e-6), 0, 1)
end

--[[
	Sprites in one burst.
	@param source  "click" | "tick" | "reward" | "purchase" | "offline" (unknown -> 0)
	@param amount  the money paid (finite > 0); nil = unknown (Config.UnknownFraction)
	@param tier    FxQuality tier "Low" | "Mid" | "High" (unknown -> Mid scale)
	@param reduced Reduce Motion: at most the source's Reduced count
	@return count >= 0 (0 for invalid amounts)
	Example: Rules.count("click", 25, "High", false) --> 2
]]
function Rules.count(source: string, amount: number?, tier: string, reduced: boolean): number
	local spec = Sources[source]
	if spec == nil then
		return 0
	end
	local f: number
	if amount == nil then
		f = Config.UnknownFraction
	else
		local known = Rules.fraction(amount)
		if known == nil then
			return 0
		end
		f = known
	end
	local base = spec.Min + math.floor((spec.Max - spec.Min) * f + 0.5)
	local scale = Config.TierScale[tier] or Config.TierScale.Mid
	local n = math.max(1, math.floor(base * scale + 0.5))
	if reduced then
		n = math.min(n, spec.Reduced)
	end
	return n
end

--[[
	How many of a burst's `n` sprites are white sparkles (big bursts only; never all of them).
	Example: Rules.sparkles("reward", 20) --> 5
]]
function Rules.sparkles(source: string, n: number): number
	local spec = Sources[source]
	if spec == nil or n <= 1 then
		return 0
	end
	return math.min(math.floor(n * spec.Sparkles), n - 1)
end

--[[
	The part of a request that fits under the global cap.
	Example: Rules.admit(20, 35, 40) --> 5
]]
function Rules.admit(requested: number, live: number, capacity: number): number
	return math.max(0, math.min(requested, capacity - live))
end

--[[ A blank Plan (one per pooled sprite; plan() overwrites every field). ]]
function Rules.newPlan(): Plan
	return {
		x0 = 0,
		y0 = 0,
		bx = 0,
		by = 0,
		c1x = 0,
		c1y = 0,
		side = 0,
		drop = 0,
		delay = 0,
		duration = 1,
		spin = 0,
		rot0 = 0,
		scale = 1,
		reduced = false,
	}
end

--[[
	Fills `out` with one sprite's flight.
	@param out      the sprite's re-used Plan
	@param seed     per-sprite seed (decorrelates sprites and bursts)
	@param index    1-based position in its burst (start stagger)
	@param source   burst source (big sources spread in a full circle; small ones pop upward)
	@param x0, y0   origin, canvas px
	@param unit     icon unit, px (the counter icon's on-screen size)
	@param reduced  Reduce Motion: short straight rise under the counter
	@param sparkle  draw as a (smaller) sparkle
	@return out
]]
function Rules.plan(
	out: Plan,
	seed: number,
	index: number,
	source: string,
	x0: number,
	y0: number,
	unit: number,
	reduced: boolean,
	sparkle: boolean?
): Plan
	local spec = Sources[source]
	local big = spec ~= nil and spec.Big
	out.reduced = reduced
	out.scale = if sparkle then Sprite.SparkleScale / Sprite.Scale else 1
	if reduced then
		-- Start just under the counter (offset from it), no spin, quick staggered fades.
		out.bx = (noise(seed, 1) - 0.5) * 2 * unit * Reduced.Spread
		out.by = unit * Reduced.Rise
		out.x0, out.y0, out.c1x, out.c1y = 0, 0, 0, 0
		out.side, out.drop, out.spin, out.rot0 = 0, 0, 0, 0
		out.duration = Reduced.Duration
		out.delay = (index - 1) * Reduced.Stagger
		return out
	end
	local jitter = unit * Path.OriginJitter * (if big then 1 else 1 / 3)
	local sx = x0 + (noise(seed, 2) - 0.5) * 2 * jitter
	local sy = y0 + (noise(seed, 3) - 0.5) * 2 * jitter
	-- Burst direction: big bursts spread in a full circle; small ones pop up (an upper arc).
	local angle = if big then noise(seed, 4) * 2 * math.pi else -math.pi / 2 + (noise(seed, 4) - 0.5) * math.pi * 0.9 -- within 81 deg of straight up
	local radius = unit * lerp(Path.BurstMin, Path.BurstMax, noise(seed, 5)) * (if big then 1 else Path.SmallBurst)
	local bx = sx + math.cos(angle) * radius
	local by = sy + math.sin(angle) * radius
	out.x0, out.y0, out.bx, out.by = sx, sy, bx, by
	out.c1x = bx + (bx - sx) * Path.Momentum
	out.c1y = by + (by - sy) * Path.Momentum
	out.side = (if noise(seed, 6) < 0.5 then -1 else 1) * lerp(Path.CurveMin, Path.CurveMax, noise(seed, 7))
	out.drop = unit * Path.ApproachDrop * lerp(0.7, 1.3, noise(seed, 8))
	out.duration = (if big then Path.Duration else Path.SmallDuration)
		+ (noise(seed, 9) - 0.5) * 2 * Path.DurationJitter
	out.delay = math.min((index - 1) * Path.Stagger, Path.MaxStagger) + noise(seed, 10) * Path.StaggerJitter
	out.spin = (if noise(seed, 11) < 0.5 then -1 else 1) * lerp(Path.SpinMin, Path.SpinMax, noise(seed, 12))
	out.rot0 = (noise(seed, 13) - 0.5) * 40
	return out
end

--[[
	A sprite's pose `age` seconds after its burst, flying into the counter at (tx, ty).
	@return x, y (canvas px), rotation (deg), scale (x Sprite.Scale x unit), transparency (0..1),
	        done (true once it reached the counter: the driver plays the landing)
	Before its start delay the sprite is fully transparent at its origin.
]]
function Rules.pose(plan: Plan, age: number, tx: number, ty: number): (number, number, number, number, number, boolean)
	local life = age - plan.delay
	if plan.reduced then
		local sx, sy = tx + plan.bx, ty + plan.by
		if life < 0 then
			return sx, sy, 0, Reduced.Scale * plan.scale, 1, false
		end
		local u = life / plan.duration
		if u >= 1 then
			return tx, ty, 0, Reduced.Scale * plan.scale, 1, true
		end
		local e = 1 - (1 - u) * (1 - u) -- ease-out: a straight, calm rise
		local transparency = if u < 0.3 then 1 - u / 0.3 elseif u > 0.7 then (u - 0.7) / 0.3 else 0
		return sx + (tx - sx) * e, sy + (ty - sy) * e, 0, Reduced.Scale * plan.scale, transparency, false
	end
	if life < 0 then
		return plan.x0, plan.y0, plan.rot0, Sprite.StartScale * plan.scale, 1, false
	end
	local u = life / plan.duration
	if u >= 1 then
		return tx, ty, plan.rot0 + plan.spin * plan.duration, Sprite.LandScale * plan.scale, 0, true
	end
	local x: number, y: number, scale: number
	local burst = Path.BurstShare
	if u < burst then
		-- Pop out to the burst point (ease-out cubic), growing.
		local k = u / burst
		local e = 1 - (1 - k) ^ 3
		x = plan.x0 + (plan.bx - plan.x0) * e
		y = plan.y0 + (plan.by - plan.y0) * e
		scale = lerp(Sprite.StartScale, Sprite.PeakScale, e)
	else
		-- Swoop: cubic bezier burst point -> counter, accelerating.
		local k = (u - burst) / (1 - burst)
		local t = k ^ Path.FlyEase
		local dx, dy = tx - plan.bx, ty - plan.by
		-- Second control: under the counter, bent sideways (perpendicular of burst->counter).
		local c2x = tx - dy * plan.side
		local c2y = ty + plan.drop + dx * plan.side
		local m = 1 - t
		local a, b, c, d = m * m * m, 3 * m * m * t, 3 * m * t * t, t * t * t
		x = a * plan.bx + b * plan.c1x + c * c2x + d * tx
		y = a * plan.by + b * plan.c1y + c * c2y + d * ty
		scale = lerp(Sprite.PeakScale, Sprite.LandScale, t)
	end
	local transparency = if u < Sprite.FadeIn then 1 - u / Sprite.FadeIn else 0
	return x, y, plan.rot0 + plan.spin * life, scale * plan.scale, transparency, false
end

--[[
	The part of a cash increase that is NOT explained by income (0 = it is just income).
	@param delta  cash increase between two profile pushes (> 0)
	@param rate   current $/s (nil / invalid = 0)
	@param dt     seconds since the previous cash value (clamped to MaxDt)
	@param popSum producer payouts seen in the last PopWindow seconds
	@return the unexplained cash (>= MinShare of delta), else 0
	Example: Rules.grantPart(5000, 10, 0.25, 0) --> 4965
]]
function Rules.grantPart(delta: number, rate: number?, dt: number, popSum: number): number
	local d = finite(delta)
	if d == nil or d <= 0 then
		return 0
	end
	local r = math.max(finite(rate) or 0, 0)
	local seconds = math.clamp(finite(dt) or 0, 0, Attribution.MaxDt)
	local pops = math.max(finite(popSum) or 0, 0)
	local expected = r * seconds * Attribution.IncomeSlack + r * Attribution.RateGrace + pops * Attribution.PopSlack
	local extra = d - expected
	if extra <= 0 or extra < d * Attribution.MinShare then
		return 0
	end
	return extra
end

--[[
	The burst source of a producer payout: "click" right after the player's own click on a manual
	producer, else "tick" (automated producers and auto-clicker chains: occasional, small).
	@param automated  the producer has a manager
	@param sinceClick seconds since the player's last click on it (inf = never)
	@param cycleTime  the producer's seconds per cycle
	Example: Rules.payoutSource(false, 0.6, 0.5) --> "click"
]]
function Rules.payoutSource(automated: boolean, sinceClick: number, cycleTime: number): Source
	local since = finite(sinceClick)
	local cycle = math.max(finite(cycleTime) or 0, 0)
	if automated or since == nil or since < 0 or since > cycle + Config.World.ClickGrace then
		return "tick"
	end
	return "click"
end

--[[ A fresh grant / signal matcher. ]]
function Rules.newMatcher(): Matcher
	return { grant = 0, grantAt = -math.huge, hint = nil, hintAt = -math.huge }
end

--[[
	An unexplained cash increase arrived. With a fresh signal waiting it flies now; otherwise it
	waits GrantBefore seconds for one (successive increases add up).
	@return amount, source to fly now (nil = wait)
]]
function Rules.onGrant(m: Matcher, amount: number, now: number): (number?, Source?)
	local hint = m.hint
	if hint ~= nil and now - m.hintAt <= Attribution.HintAfter then
		m.hint = nil
		return amount, hint
	end
	m.hint = nil
	m.grant = if now - m.grantAt <= Attribution.GrantBefore then m.grant + amount else amount
	m.grantAt = now
	return nil, nil
end

--[[
	A reward toast / PurchaseGranted arrived. Pending unexplained cash flies now; otherwise the
	signal waits HintAfter seconds for its cash (a pet / spin reward simply expires).
	@return amount, source to fly now (nil = wait)
]]
function Rules.onHint(m: Matcher, source: Source, now: number): (number?, Source?)
	if m.grant > 0 and now - m.grantAt <= Attribution.GrantBefore then
		local amount = m.grant
		m.grant = 0
		m.hint = nil
		return amount, source
	end
	m.hint = source
	m.hintAt = now
	return nil, nil
end

--[[ Drops pending unexplained cash (it was shown elsewhere, e.g. the offline payout). ]]
function Rules.clearGrant(m: Matcher)
	m.grant = 0
	m.grantAt = -math.huge
end

-- Fly kinds (owner R57 World 2) ------------------------------------------------------------------

--[[
	True for a kind money can fly as: "cash", "gems", or any world's currency key ("bones", ...;
	WorldsConfig.worldOfCurrency). Rebirth tokens / Amber and junk are not fly kinds.
	Example: Rules.isKind("bones") --> true ; Rules.isKind("amber") --> false
]]
function Rules.isKind(kind: unknown): boolean
	if kind == "cash" or kind == "gems" then
		return true
	end
	if type(kind) ~= "string" then
		return false
	end
	local worldId = WorldsConfig.worldOfCurrency(kind)
	local def = if worldId ~= nil then WorldsConfig.get(worldId) else nil
	return def ~= nil and def.currency.key == kind
end

--[[
	The IconAssets key a kind's sprites show: "Cash", "Gems", or the world currency's icon
	("Bones"). Unknown kinds -> "Cash".
	Example: Rules.iconOf("bones") --> "Bones"
]]
function Rules.iconOf(kind: string): string
	if kind == "gems" then
		return "Gems"
	end
	if kind ~= "cash" and Rules.isKind(kind) then
		local def = WorldsConfig.get(WorldsConfig.worldOfCurrency(kind) :: string)
		if def ~= nil then
			return def.currency.icon
		end
	end
	return "Cash"
end

--[[
	The landing tick's SoundAssets key of a kind (CurrencyFlyConfig.Land.Sounds; a world currency
	without its own row ticks like cash).
	Example: Rules.sound("bones") --> "cash_small"
]]
function Rules.sound(kind: string): string?
	local sounds = Config.Land.Sounds
	return sounds[kind] or (if kind ~= "gems" then sounds.cash else nil)
end

-- Targets + spends (owner R60 / R61) -------------------------------------------------------------

export type Counter = "cash" | "gems" | "world"

--[[
	Which HUD counter a kind's sprites land on in the world the player is in (owner R61: the
	target must be the VISIBLE counter of the current world; R60: other worlds show only their
	own currency + gems, so Cash has no counter there).
	@param kind          a fly kind
	@param worldCurrency the current world's currency key, nil in Nuke Town
	@return "cash" (Nuke Town's cash counter) | "gems" | "world" (the world's primary counter) |
	        nil = no counter on screen: nothing flies
	Example: Rules.counterFor("bones", "bones") --> "world" ; Rules.counterFor("cash", "bones") --> nil
]]
function Rules.counterFor(kind: unknown, worldCurrency: string?): Counter?
	if kind == "gems" then
		return "gems"
	end
	if worldCurrency == nil then
		return if kind == "cash" then "cash" else nil
	end
	return if kind == worldCurrency and Rules.isKind(kind) then "world" else nil
end

--[[
	True only for a real balance INCREASE (owner R61: spends — upgrades, pad buys, eggs — and a
	world swap, which moves no balance, never fly). NaN / inf / a missing previous value: false.
	Example: Rules.isIncrease(100, 40) --> false (a spend) ; Rules.isIncrease(100, 100) --> false
]]
function Rules.isIncrease(previous: unknown, value: unknown): boolean
	if type(previous) ~= "number" or type(value) ~= "number" then
		return false
	end
	if previous ~= previous or value ~= value or math.abs(previous) == math.huge or math.abs(value) == math.huge then
		return false
	end
	return value > previous
end

return table.freeze(Rules)
