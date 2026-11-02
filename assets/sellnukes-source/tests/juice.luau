--!strict
--[[
	Juice pass regressions (Client/Tycoon/Fx/JuiceRules, owner R71). Run:
		lune run tests/juice
	Proves on the shipped module:
	  1. Combo: chains within the window, resets after it / on bad input; the pitch ladder climbs one
	     semitone per press from 1.0 and never passes MaxPitch; "x12!" labels from LabelFrom; rings
	     every 10, big bursts at 25 / 50 / 100 and every 100 after; the label punch eases back to 1.
	  2. Milestones: only a level-up that crosses a multiple of MilestoneEvery counts (the highest
	     one crossed by a multi-level buy); odd = cash, even = speed, at the cycle floor = cash; text.
	  3. Camera punch: the FOV kick rises then returns to 0, the shake decays, nothing after the end.
	  4. Fireworks: launch points stay within Spread, heights / rise times within their jitter,
	     stagger grows with the index, colours vary.
	  5. Per-tier picks and the rebirth total (main + every world).
	  6. Config sanity: Reduce-Motion-sensitive strengths in range, pools small (console / phone).
]]
local Loader = require("./fixtures/RobloxLoader")
local loader = Loader.new()
local Rules = loader.load("src/client/Tycoon/Fx/JuiceRules")
local Config = loader.load("src/shared/Config/JuiceConfig")

local checks = 0
local function ok(condition: boolean, label: string)
	checks += 1
	assert(condition, label)
end

-- 1. Combo
local Combo = Config.Combo
ok(Rules.comboNext(0, -math.huge, 1) == 1, "first press starts a combo")
ok(Rules.comboNext(4, 10, 10 + Combo.Window * 0.5) == 5, "a press inside the window chains")
ok(Rules.comboNext(4, 10, 10 + Combo.Window + 0.01) == 1, "a press after the window resets")
ok(Rules.comboNext(4, 10, 9) == 1, "clock going backwards resets")
ok(Rules.comboNext(0 / 0, 10, 10.1) == 1, "NaN count resets")
local count, last = 0, -math.huge
for press = 1, 120 do
	local now = press * 0.3
	count = Rules.comboNext(count, last, now)
	last = now
	ok(count == press, `press {press} keeps the chain`)
end
ok(Rules.comboPitch(1) == 1, "first press at pitch 1.0")
ok(math.abs(Rules.comboPitch(2) - 2 ^ (Combo.SemitonesPerStep / 12)) < 1e-9, "one semitone per press")
local previous = 0
for n = 1, 200 do
	local pitch = Rules.comboPitch(n)
	ok(pitch >= previous and pitch <= Combo.MaxPitch + 1e-9, `pitch ladder climbs, capped ({n})`)
	previous = pitch
end
ok(math.abs(Rules.comboPitch(200) - Combo.MaxPitch) < 1e-9, "the ladder tops out at MaxPitch")
ok(Rules.comboLabel(1) == nil, "no label for a single press")
ok(Rules.comboLabel(12) == "x12!", "x12! label")
ok(Rules.comboLabel(0 / 0) == nil, "NaN label")
ok(Rules.comboEvent(10) == "ring" and Rules.comboEvent(20) == "ring", "rings every 10")
ok(
	Rules.comboEvent(25) == "big" and Rules.comboEvent(50) == "big" and Rules.comboEvent(100) == "big",
	"big at 25/50/100"
)
ok(Rules.comboEvent(200) == "big" and Rules.comboEvent(300) == "big", "big every 100 after")
ok(Rules.comboEvent(30) == "ring" and Rules.comboEvent(150) == "ring", "rings between bigs")
ok(Rules.comboEvent(7) == nil and Rules.comboEvent(12.5) == nil and Rules.comboEvent(-10) == nil, "ordinary presses")
ok(Rules.comboPunches(100) and Rules.comboPunches(200), "100+ big bursts punch")
ok(not Rules.comboPunches(25) and not Rules.comboPunches(50) and not Rules.comboPunches(30), "smaller ones do not")
ok(math.abs(Rules.labelScale(0) - (1 + Combo.LabelPunch)) < 1e-9, "label punches on a press")
ok(Rules.labelScale(Combo.PunchSeconds) == 1 and Rules.labelScale(5) == 1, "label settles")
ok(Rules.labelScale(Combo.PunchSeconds * 0.5) < Rules.labelScale(0), "label eases back")

-- 2. Milestones
ok(Rules.milestoneCrossed(24, 25, 25) == 25, "24 -> 25 crosses 25")
ok(Rules.milestoneCrossed(25, 26, 25) == nil, "25 -> 26 crosses nothing")
ok(Rules.milestoneCrossed(10, 60, 25) == 50, "a multi-level buy reports the highest crossed")
ok(Rules.milestoneCrossed(60, 10, 25) == nil, "a reset (rebirth) is not a milestone")
ok(Rules.milestoneCrossed(0, 24, 25) == nil, "below the first milestone")
ok(Rules.milestoneCrossed(0 / 0, 30, 25) == nil and Rules.milestoneCrossed(1, 30, 0) == nil, "bad input")
ok(Rules.milestoneKind(25, 25, false) == "Cash", "25 = cash")
ok(Rules.milestoneKind(50, 25, false) == "Speed", "50 = speed")
ok(Rules.milestoneKind(75, 25, false) == "Cash", "75 = cash")
ok(Rules.milestoneKind(100, 25, true) == "Cash", "speed at the cycle floor is paid as cash")
local title, reward = Rules.milestoneText(50, "Speed")
ok(title == "LEVEL 50!" and reward == "x2 SPEED!", "banner text (speed)")
local title2, reward2 = Rules.milestoneText(75, "Cash")
ok(title2 == "LEVEL 75!" and reward2 == "x2 CASH!", "banner text (cash)")

-- 3. Camera punch
local seconds = Config.Punch.Seconds
local f0, s0 = Rules.punch(0, seconds)
ok(f0 == 0 and s0 == 1, "punch starts with full shake, FOV rising")
local peak = 0
local lastFov = -1
local falling = false
for step = 1, 99 do
	local fov, shake = Rules.punch(seconds * step / 100, seconds)
	ok(fov >= 0 and fov <= 1 and shake >= 0 and shake <= 1, `punch envelope in range ({step})`)
	if fov < lastFov then
		falling = true
	elseif falling then
		ok(fov <= lastFov + 1e-9, `FOV never rises again after peaking ({step})`)
	end
	peak = math.max(peak, fov)
	lastFov = fov
end
ok(peak > 0.95, "FOV kick reaches its peak")
local fEnd, sEnd = Rules.punch(seconds, seconds)
ok(fEnd == 0 and sEnd == 0, "nothing after the end")
local fNeg = Rules.punch(-1, seconds)
ok(fNeg == 0, "nothing before the start")

-- 4. Fireworks
local F = Config.Fireworks
local hues: { [number]: boolean } = {}
local lastDelay = -1
for index = 1, 8 do
	local dx, dz, height, rise, delay, hue = Rules.fireworkPlan(7, index)
	ok(math.sqrt(dx * dx + dz * dz) <= F.Spread + 1e-6, `rocket {index} inside the spread`)
	ok(math.abs(height - F.Height) <= F.HeightJitter + 1e-6, `rocket {index} height`)
	ok(math.abs(rise - F.RiseSeconds) <= F.RiseJitter + 1e-6 and rise > 0.3, `rocket {index} rise time`)
	ok(delay > lastDelay, `rocket {index} staggered`)
	ok(hue >= 0 and hue < 1, `rocket {index} hue`)
	hues[math.floor(hue * 10)] = true
	lastDelay = delay
end
local distinct = 0
for _ in hues do
	distinct += 1
end
ok(distinct >= 3, "rocket colours vary")

-- 5. Per tier + rebirth total
ok(Rules.perTier(Config.PadBuy.Coins, "Low") == Config.PadBuy.Coins.Low, "Low tier")
ok(Rules.perTier(Config.PadBuy.Coins, "High") == Config.PadBuy.Coins.High, "High tier")
ok(Rules.perTier(Config.PadBuy.Coins, "Weird") == Config.PadBuy.Coins.Mid, "unknown tier = Mid")
ok(
	Rules.rebirthTotal({ rebirths = 2, worlds = { dino = { rebirths = 1 }, moon = { rebirths = 3 } } }) == 6,
	"rebirth total"
)
ok(Rules.rebirthTotal({ rebirths = 0 / 0, worlds = { dino = { rebirths = "x" } } }) == 0, "bad counts ignored")
ok(Rules.rebirthTotal(nil) == 0, "no profile")

-- 6. Config sanity (console / phone budgets, Reduce Motion handled by the callers)
for _, row in { Config.PadBuy.Coins, Config.Fireworks.Sparks, Config.Ambient.Emitters, Config.Finale.Confetti } do
	ok(row.Low <= row.Mid and row.Mid <= row.High, "tiers grow Low -> High")
end
ok(Config.Fireworks.Pool <= 12 and Config.UpgradeGlow.Pool <= 4 and Config.Combo.LabelPool <= 4, "pools stay small")
ok(Config.Ambient.Emitters.High <= 8, "ambient emitters capped")
ok(Config.Punch.FovKick <= 10 and Config.Punch.Shake <= 0.5, "camera punch stays gentle")
ok(Config.Rebirth.FlashPeak <= 0.6, "the rebirth flash is soft (owner R19)")
ok(Config.Combo.MaxPitch <= 1.6 and Config.Combo.Window > 0, "combo ladder bounds")

print(`[juice] {checks} checks passed`)
