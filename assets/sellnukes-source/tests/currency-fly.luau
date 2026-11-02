--!strict
--[[
	Money-flies-into-the-counter regressions (UI/Hud/CurrencyFlyRules, owner R46). Run:
		lune run tests/currency-fly
	Proves on the shipped module:
	  1. Counts: click 2-4, tick 1-2, reward / purchase 12-20, growing with log10(amount); Low
	     graphics = about a third; Reduce Motion caps; invalid amounts spawn nothing; unknown
	     amounts use the configured fraction; sparkles never take the whole burst.
	  2. Cap: admit never lets the live sprites exceed the pool.
	  3. Path: starts at the origin (transparent before its delay), pops OUTWARD, is spread across
	     seeds, ends exactly on the counter (even after the counter moved) and arrives moving UP
	     from below; small bursts pop upward; poses stay finite and near the path's hull.
	  4. Reduce Motion: a short straight rise from just under the counter, no spin, fades in + out.
	  4b. Payout source: click only right after a real click; managers / auto clicker = tick.
	  5. Attribution: income-sized increases are not grants; rewards are; payouts explain clicks;
	     a signal pairs with unexplained cash in either order inside the windows, never outside;
	     clearGrant drops pending cash.
	  6. Fly kinds (owner R57 World 2): cash, gems and every world currency (Bones) fly, with the
	     currency's own icon and a landing tick; rebirth tokens (Amber) and junk never fly.
	  7. Owner bug R61 (coins piled up around the left HUD tiles on a Dino UPGRADE):
	     - the target is the VISIBLE counter of the current world in BOTH worlds
	       (counterFor: Nuke Town cash / gems; Dino Bones / gems; Cash has no counter in Dino, R60),
	     - spends (a balance decrease: upgrade, pad, egg) and a world swap (no balance change)
	       never fly; NaN / inf never fly,
	     - a world swap re-baselines nothing into a grant: the same balance before / after the
	       swap is not an increase, and a later real reward still pairs normally,
	     - billboard buttons (UPGRADE) are projected to their real screen rect
	       (Widgets/ScreenRect.billboard), never left at their billboard-canvas position.
]]
local Loader = require("./fixtures/RobloxLoader")
local loader = Loader.new()
local Rules = loader.load("src/client/UI/Hud/CurrencyFlyRules")
local Config = loader.load("src/shared/Config/CurrencyFlyConfig")

local checks = 0
local function ok(condition: boolean, label: string)
	checks += 1
	assert(condition, label)
end

-- 1. Counts
for _, source in { "click", "tick", "reward", "purchase", "offline" } do
	local spec = Config.Sources[source]
	local low = Rules.count(source, 1, "High", false)
	local high = Rules.count(source, 1e15, "High", false)
	ok(low == spec.Min, `{source}: tiny amount = Min ({low})`)
	ok(high == spec.Max, `{source}: huge amount = Max ({high})`)
	local previous = 0
	for exponent = 0, 13 do
		local n = Rules.count(source, 10 ^ exponent, "High", false)
		ok(n >= previous, `{source}: count never shrinks as the amount grows (1e{exponent})`)
		previous = n
	end
	ok(
		Rules.count(source, 1e6, "Low", false) <= math.ceil(Rules.count(source, 1e6, "High", false) / 3),
		`{source}: Low ~ a third`
	)
	ok(Rules.count(source, 1e6, "Low", false) >= 1, `{source}: Low still shows one`)
	ok(Rules.count(source, 1e15, "High", true) <= spec.Reduced, `{source}: Reduce Motion caps`)
	ok(Rules.count(source, nil, "High", false) >= spec.Min, `{source}: unknown amount still flies`)
	ok(Rules.sparkles(source, high) < high, `{source}: sparkles never take the whole burst`)
end
ok(Rules.count("click", 25, "High", false) >= 2 and Rules.count("click", 1e9, "High", false) <= 4, "click = 2..4")
ok(Rules.count("tick", 1e9, "High", false) <= 2, "tick = 1..2 (occasional)")
ok(
	Rules.count("reward", 50, "High", false) >= 12 and Rules.count("purchase", 1e12, "High", false) <= 20,
	"reward = 12..20"
)
ok(Rules.count("reward", 0, "High", false) == 0, "zero spawns nothing")
ok(Rules.count("reward", -5, "High", false) == 0, "negative spawns nothing")
ok(Rules.count("reward", 0 / 0, "High", false) == 0, "NaN spawns nothing")
ok(Rules.count("reward", math.huge, "High", false) == 0, "inf spawns nothing")
ok(Rules.count("bogus", 100, "High", false) == 0, "unknown source spawns nothing")
ok(Rules.count("reward", 1e6, "Weird", false) == Rules.count("reward", 1e6, "Mid", false), "unknown tier = Mid")
ok(Rules.fraction(1) == 0 and Rules.fraction(1e12) == 1 and Rules.fraction(-1) == nil, "fraction range")

-- 2. Cap
ok(Rules.admit(20, 0, Config.Capacity) == 20, "room for a full burst")
ok(Rules.admit(20, 35, 40) == 5, "only the room left")
ok(Rules.admit(20, 40, 40) == 0, "full pool admits nothing")
ok(Rules.admit(20, 45, 40) == 0, "never negative")
local liveSim = 0
for _ = 1, 50 do
	liveSim += Rules.admit(Rules.count("reward", 1e9, "High", false), liveSim, Config.Capacity)
	ok(liveSim <= Config.Capacity, "repeated bursts stay under the cap")
end

-- 3. Path
local unit = 48
local ox, oy = 960, 700
local tx, ty = 960, 60
local burstEnds: { [string]: boolean } = {}
for seed = 1, 40 do
	local plan = Rules.plan(Rules.newPlan(), seed, (seed - 1) % 20 + 1, "reward", ox, oy, unit, false, false)
	local life = plan.delay + plan.duration
	ok(plan.duration > 0.4 and plan.duration < 1.2, `seed {seed}: sensible duration`)
	ok(
		plan.delay >= 0 and plan.delay <= Config.Path.MaxStagger + Config.Path.StaggerJitter,
		`seed {seed}: bounded stagger`
	)
	local x0, y0, _, _, t0, done0 = Rules.pose(plan, 0, tx, ty)
	ok(not done0, `seed {seed}: not done at start`)
	ok(math.abs(x0 - ox) <= unit and math.abs(y0 - oy) <= unit, `seed {seed}: starts at the origin`)
	if plan.delay > 0 then
		ok(t0 == 1, `seed {seed}: invisible before its delay`)
	end
	-- Pops outward: distance from the start grows during the burst phase.
	local burstAge = plan.delay + plan.duration * Config.Path.BurstShare * 0.95
	local bx, by = Rules.pose(plan, burstAge, tx, ty)
	ok(
		math.sqrt((bx - plan.x0) ^ 2 + (by - plan.y0) ^ 2) >= unit * Config.Path.BurstMin * 0.8,
		`seed {seed}: pops outward`
	)
	burstEnds[`{math.floor(bx / 8)}:{math.floor(by / 8)}`] = true
	-- Visible mid-flight, finite everywhere, stays near the screen.
	for step = 1, 30 do
		local age = plan.delay + plan.duration * step / 31
		local x, y, rotation, scale, transparency, done = Rules.pose(plan, age, tx, ty)
		ok(x == x and y == y and rotation == rotation and scale == scale, `seed {seed}: finite pose`)
		ok(not done, `seed {seed}: still flying at step {step}`)
		ok(
			x > ox - 8 * unit and x < ox + 8 * unit and y > ty - 4 * unit and y < oy + 5 * unit,
			`seed {seed}: near its path`
		)
		ok(scale > 0 and scale <= Config.Sprite.PeakScale + 1e-6, `seed {seed}: sane scale`)
		if step > 3 then
			ok(transparency == 0, `seed {seed}: opaque in flight`)
		end
	end
	-- Arrives moving up from below the counter.
	local _, yLate = Rules.pose(plan, life - plan.duration * 0.04, tx, ty)
	local _, yLater = Rules.pose(plan, life - plan.duration * 0.01, tx, ty)
	ok(yLater < yLate, `seed {seed}: swoops UP into the counter`)
	ok(yLate >= ty - 2, `seed {seed}: approaches from below`)
	local xe, ye, _, scaleEnd, _, doneEnd = Rules.pose(plan, life + 0.001, tx, ty)
	ok(doneEnd and xe == tx and ye == ty, `seed {seed}: lands exactly on the counter`)
	ok(math.abs(scaleEnd - Config.Sprite.LandScale) < 1e-6, `seed {seed}: shrinks into the counter`)
	-- The counter moved (HUD re-layout): the sprite still lands on it.
	local xm, ym, _, _, _, doneMoved = Rules.pose(plan, life + 0.001, 700, 90)
	ok(doneMoved and xm == 700 and ym == 90, `seed {seed}: follows a moved counter`)
end
local spread = 0
for _ in burstEnds do
	spread += 1
end
ok(spread >= 30, `bursts spread across seeds ({spread} distinct burst points)`)
-- Small (click) bursts pop upward and stay tight.
for seed = 1, 30 do
	local plan = Rules.plan(Rules.newPlan(), seed, 1, "click", ox, oy, unit, false, false)
	ok(plan.by < plan.y0, `click seed {seed}: pops upward`)
	ok(
		math.abs(plan.bx - plan.x0) <= unit * Config.Path.BurstMax * Config.Path.SmallBurst + 1,
		`click seed {seed}: tight`
	)
	ok(plan.duration < Config.Path.Duration, `click seed {seed}: quicker flight`)
end
-- Sparkles are smaller.
local sparkle = Rules.plan(Rules.newPlan(), 3, 1, "reward", ox, oy, unit, false, true)
local coin = Rules.plan(Rules.newPlan(), 3, 1, "reward", ox, oy, unit, false, false)
ok(sparkle.scale < coin.scale, "sparkles are smaller than coins")

-- 4. Reduce Motion
for seed = 1, 20 do
	local plan = Rules.plan(Rules.newPlan(), seed, (seed - 1) % 3 + 1, "reward", ox, oy, unit, true, false)
	ok(plan.reduced, `reduced seed {seed}: flagged`)
	local life = plan.delay + plan.duration
	local sx, sy, r0 = Rules.pose(plan, plan.delay, tx, ty)
	ok(
		math.abs(sy - ty) <= unit * Config.Reduced.Rise * 1.01 and sy > ty,
		`reduced seed {seed}: starts just under the counter`
	)
	ok(math.abs(sx - tx) <= unit * Config.Reduced.Spread + 1e-6, `reduced seed {seed}: small sideways spread`)
	ok(r0 == 0, `reduced seed {seed}: no spin`)
	local mx, my, _, _, tm = Rules.pose(plan, plan.delay + plan.duration * 0.5, tx, ty)
	ok(tm == 0, `reduced seed {seed}: visible mid-way`)
	-- Straight: the mid point lies on the start -> counter segment.
	local cross = (mx - sx) * (ty - sy) - (my - sy) * (tx - sx)
	ok(math.abs(cross) < 1e-6, `reduced seed {seed}: straight line`)
	local _, _, _, _, tStart = Rules.pose(plan, plan.delay + 0.001, tx, ty)
	local _, _, _, _, tLate = Rules.pose(plan, life - 0.01, tx, ty)
	ok(tStart > 0.9 and tLate > 0.9, `reduced seed {seed}: fades in and out`)
	ok(plan.duration <= Config.Reduced.Duration, `reduced seed {seed}: short`)
end

-- 4b. Payout source
ok(Rules.payoutSource(false, 0.6, 0.5) == "click", "a payout right after a click = click")
ok(Rules.payoutSource(true, 0.1, 0.5) == "tick", "managers = tick")
ok(Rules.payoutSource(false, 30, 0.5) == "tick", "auto-clicker chains long after a click = tick")
ok(Rules.payoutSource(false, math.huge, 1) == "tick", "never clicked = tick")
ok(Rules.payoutSource(false, 0 / 0, 1) == "tick", "NaN = tick")
ok(Rules.payoutSource(false, 1 + Config.World.ClickGrace - 0.01, 1) == "click", "grace window")

-- 5. Attribution
ok(Rules.grantPart(30, 100, 0.25, 0) == 0, "a tick of income is not a grant")
ok(Rules.grantPart(500, 100, 2, 0) == 0, "two seconds of income is not a grant")
ok(Rules.grantPart(50_000, 100, 0.25, 0) > 40_000, "a big jump is a grant")
ok(Rules.grantPart(1_000, 0, 0.25, 1_000) == 0, "a producer payout explains a click")
ok(Rules.grantPart(10_000, 0, 0.25, 1_000) > 0, "a reward on top of a click is still a grant")
ok(Rules.grantPart(0 / 0, 100, 1, 0) == 0 and Rules.grantPart(-5, 100, 1, 0) == 0, "invalid deltas")
ok(Rules.grantPart(5_000, 0 / 0, 0 / 0, 0 / 0) > 0, "invalid income inputs are ignored")
ok(Rules.grantPart(1_000, 400, 0.5, 0) == 0, "MinShare: mostly-income increases never fly")

local m = Rules.newMatcher()
-- Signal first (reward toast arrives before the profile push).
local a1, s1 = Rules.onHint(m, "reward", 10)
ok(a1 == nil and s1 == nil, "a signal alone waits")
local a2, s2 = Rules.onGrant(m, 5_000, 10.2)
ok(a2 == 5_000 and s2 == "reward", "signal then cash flies")
local a3 = Rules.onGrant(m, 7_000, 10.4)
ok(a3 == nil, "a consumed signal never flies twice")
-- Cash first (PurchaseGranted after the save).
local b1, t1 = Rules.onHint(m, "purchase", 14)
ok(b1 == 7_000 and t1 == "purchase", "cash then signal flies with the signal's source")
-- Stale pairs never fly.
Rules.onGrant(m, 3_000, 20)
local c1 = Rules.onHint(m, "purchase", 20 + Config.Attribution.GrantBefore + 0.1)
ok(c1 == nil, "cash older than GrantBefore never pairs")
local c2 = Rules.onGrant(m, 2_000, 20 + Config.Attribution.GrantBefore + 0.1 + Config.Attribution.HintAfter + 0.1)
ok(c2 == nil, "a signal older than HintAfter never pairs (pet / spin rewards expire)")
-- Successive unexplained increases add up; clearGrant drops them.
local fresh = Rules.newMatcher()
Rules.onGrant(fresh, 100, 1)
Rules.onGrant(fresh, 200, 2)
local d1 = Rules.onHint(fresh, "reward", 3)
ok(d1 == 300, "pending grants add up")
Rules.onGrant(fresh, 900, 4)
Rules.clearGrant(fresh)
ok(Rules.onHint(fresh, "reward", 4.5) == nil, "clearGrant drops pending cash")

-- 6. Fly kinds (R57 World 2)
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
ok(Rules.isKind("cash") and Rules.isKind("gems"), "cash + gems are fly kinds")
ok(Rules.iconOf("cash") == "Cash" and Rules.iconOf("gems") == "Gems", "cash / gem sprite icons")
for _, def in WorldsConfig.extra() do
	local key = def.currency.key
	ok(Rules.isKind(key), `world currency {key} is a fly kind`)
	ok(Rules.iconOf(key) == def.currency.icon, `{key} sprites show the {def.currency.icon} icon`)
	ok(Rules.sound(key) ~= nil, `{key} landings tick`)
	ok(not Rules.isKind(def.tokens.key), `rebirth tokens ({def.tokens.key}) never fly`)
end
ok(Rules.isKind("bones") and Rules.iconOf("bones") == "Bones", "Dino Valley: Bones fly with the bone icon")
ok(Rules.sound("gems") == Config.Land.Sounds.gems and Rules.sound("cash") == Config.Land.Sounds.cash, "sounds")
ok(not Rules.isKind("junk") and not Rules.isKind(5) and not Rules.isKind(nil), "junk kinds never fly")
ok(Rules.iconOf("junk") == "Cash", "an unknown kind falls back to the cash sprite")

-- 7. R61: targets per world, spends, world swaps, billboard origins
for _, def in WorldsConfig.extra() do
	local key = def.currency.key
	-- Nuke Town (no world currency): cash + gems counters; a world currency has no counter.
	ok(Rules.counterFor("cash", nil) == "cash", "Nuke Town: cash lands on the cash counter")
	ok(Rules.counterFor("gems", nil) == "gems", "Nuke Town: gems land on the gem counter")
	ok(Rules.counterFor(key, nil) == nil, `Nuke Town: {key} has no counter (never flies there)`)
	-- In the world: its currency's primary counter + gems; Cash has none (R60).
	ok(Rules.counterFor(key, key) == "world", `{def.id}: {key} lands on the world's own counter`)
	ok(Rules.counterFor("gems", key) == "gems", `{def.id}: gems still land on the gem counter`)
	ok(Rules.counterFor("cash", key) == nil, `{def.id}: Nuke Town cash has no counter here (R60)`)
	ok(Rules.counterFor("junk", key) == nil and Rules.counterFor(nil, key) == nil, `{def.id}: junk kinds never land`)
end
-- Spends + world swaps never fly.
ok(not Rules.isIncrease(1_000, 400), "an upgrade / pad / egg spend (decrease) never flies")
ok(not Rules.isIncrease(9.99e12, 9.99e12), "a world swap (unchanged balance) never flies")
ok(not Rules.isIncrease(nil, 5), "no baseline yet: never flies")
ok(not Rules.isIncrease(5, 0 / 0) and not Rules.isIncrease(0 / 0, 5), "NaN never flies")
ok(not Rules.isIncrease(5, math.huge) and not Rules.isIncrease(-math.huge, 5), "inf never flies")
ok(Rules.isIncrease(400, 1_000), "a real increase may fly")
-- A big spend right after income must not turn the following tick into a grant either: the
-- tick's delta is income-sized (rate x dt), so grantPart stays 0.
ok(Rules.grantPart(4_160, 4_160, 1, 0) == 0, "an income tick after a spend is income, not a grant")
-- Swap: the balance before == after, then a reward arrives and pairs normally.
local swap = Rules.newMatcher()
ok(not Rules.isIncrease(500, 500), "swap: no increase")
local rewardPart = Rules.grantPart(10_000, 10, 1, 0)
ok(rewardPart > 0, "after a swap a real reward is still unexplained money")
Rules.onGrant(swap, rewardPart, 10)
local paired = Rules.onHint(swap, "reward", 10.2)
ok(paired ~= nil and paired > 0, "after a swap a real reward still pairs with its toast")

-- Billboard buttons are projected (Widgets/ScreenRect, used by ButtonFeedback + fromGui).
local roblox = require("@lune/roblox")
local Vector2, Vector3, UDim2 = roblox.Vector2, roblox.Vector3, roblox.UDim2
-- ScreenRect only touches GuiService / Workspace inside `of` (live); a stub is enough here.
local ScreenRect = Loader.new({ GuiService = {} }).load("src/client/UI/Widgets/ScreenRect")
-- A 10 x 5 stud billboard 20 studs away at the screen centre (1920 x 1080, fov 70), whose canvas
-- the engine reports at 0, 0 (billboard space); the UPGRADE button sits in its lower middle.
local base = {
	point = Vector3.new(960, 540, 20),
	viewportY = 1080,
	fov = 70,
	size = UDim2.fromScale(10, 5),
	sizeOffset = Vector2.new(0, 0),
	guiPosition = Vector2.new(0, 0),
	guiSize = Vector2.new(400, 200),
	objectPosition = Vector2.new(100, 150),
	objectSize = Vector2.new(200, 40),
	inset = Vector2.new(0, 58),
}
local pixelsPerStud = 1080 / (2 * 20 * math.tan(math.rad(70) / 2))
-- Roblox vectors are float32: compare to 0.01 px.
local position, size = ScreenRect.billboard(base)
ok(position ~= nil and size ~= nil, "billboard button projects")
if position ~= nil and size ~= nil then
	local width, height = 10 * pixelsPerStud, 5 * pixelsPerStud
	local left, top = 960 - width / 2, 540 - height / 2 - 58
	ok(math.abs(position.X - (left + 100 * width / 400)) < 1e-2, "projected x = billboard left + scaled offset")
	ok(math.abs(position.Y - (top + 150 * height / 200)) < 1e-2, "projected y (GUI space, minus the top bar)")
	ok(math.abs(size.X - 200 * width / 400) < 1e-2 and math.abs(size.Y - 40 * height / 200) < 1e-2, "scaled size")
	-- The bug: the raw billboard-space position (100, 150) is near the top-left HUD tiles; the
	-- projected one is around the screen centre where the billboard is drawn.
	ok(position.X > 600 and position.Y > 300, "the burst is at the billboard, not the top-left HUD")
end
-- When the engine already reports screen space (canvas at its on-screen rect, ~1:1), the
-- mapping keeps the button where it is.
local width, height = 10 * pixelsPerStud, 5 * pixelsPerStud
local screenSpace = table.clone(base)
screenSpace.guiPosition = Vector2.new(960 - width / 2, 540 - height / 2 - 58)
screenSpace.guiSize = Vector2.new(width, height)
screenSpace.objectPosition = screenSpace.guiPosition + Vector2.new(30, 60)
screenSpace.objectSize = Vector2.new(120, 30)
local p2, s2 = ScreenRect.billboard(screenSpace)
ok(p2 ~= nil and s2 ~= nil, "screen-space billboard projects")
if p2 ~= nil and s2 ~= nil then
	ok((p2 - screenSpace.objectPosition).Magnitude < 1e-2, "screen-space reports stay put")
	ok((s2 - screenSpace.objectSize).Magnitude < 1e-2, "screen-space sizes stay put")
end
-- Behind the camera / degenerate: no rect (no burst at a bogus place).
local behind = table.clone(base)
behind.point = Vector3.new(960, 540, -5)
ok(ScreenRect.billboard(behind) == nil, "a billboard behind the camera has no screen rect")
local empty = table.clone(base)
empty.guiSize = Vector2.new(0, 0)
ok(ScreenRect.billboard(empty) == nil, "an unlaid-out billboard has no screen rect")
local offset = table.clone(base)
offset.sizeOffset = Vector2.new(0, 0.5)
local p3 = ScreenRect.billboard(offset)
ok(
	p3 ~= nil and position ~= nil and math.abs((p3 :: any).Y - ((position :: any).Y - 0.5 * 5 * pixelsPerStud)) < 1e-2,
	"SizeOffset lifts it"
)

print(`[currency-fly] {checks} checks passed`)
