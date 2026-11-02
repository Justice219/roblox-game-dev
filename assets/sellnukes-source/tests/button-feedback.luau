--!strict
--[[
	Button press feedback regressions (UI/ButtonFeedbackRules, owner R22). Run:
		lune run tests/button-feedback
	Proves on the shipped module:
	  1. Counts: reduced motion = 0 (sound only); Low < Mid < High; big presses get more.
	  2. Motion: particles start on the button outline, ORBIT (stay near it) during the orbit share,
	     then DROP (y grows with gravity) and are fully faded at the end of their life.
	  3. Sounds: locked -> ui_locked; explicit key wins ("" = silent); Coins -> ui_claim; else
	     ui_click; unknown kinds fall back to Stars.
]]
local Loader = require("./fixtures/RobloxLoader")
local loader = Loader.new()
local Rules = loader.load("src/client/UI/ButtonFeedbackRules")

local checks = 0
local function ok(condition: boolean, label: string)
	checks += 1
	assert(condition, label)
end

-- 1. Counts
ok(Rules.count("High", true, true) == 0, "reduced motion = sound only")
ok(Rules.count("Low", false, false) > 0, "phones (Low) still burst")
ok(Rules.count("Low", false, false) < Rules.count("Mid", false, false), "Low < Mid")
ok(Rules.count("Mid", false, false) < Rules.count("High", false, false), "Mid < High")
ok(Rules.count("Mid", false, true) > Rules.count("Mid", false, false), "big presses burst more")
ok(Rules.count("High", false, true) <= Rules.Capacity, "a burst never exceeds the pool")

-- 2. Motion: orbit near the outline, then drop, then gone.
local w, h = 200, 60
for seed = 1, 24 do
	local x0, y0 = Rules.pose(seed, 0, w, h)
	ok(math.abs(x0) <= w / 2 + 12 + 1 and math.abs(y0) <= h / 2 + 12 + 1, `seed {seed}: starts on the outline`)
	local orbitAge = Rules.Duration * Rules.Orbit * 0.9
	local xo, yo = Rules.pose(seed, orbitAge, w, h)
	ok(math.abs(xo) <= w / 2 + 13 and math.abs(yo) <= h / 2 + 13, `seed {seed}: orbits around the button`)
	local _, yEnd, _, fadeEnd = Rules.pose(seed, Rules.Duration * 0.999, w, h)
	ok(yEnd > yo, `seed {seed}: drops after the orbit`)
	ok(fadeEnd > 0.95, `seed {seed}: faded out at the end`)
	local _, _, _, fadeStart = Rules.pose(seed, 0.05, w, h)
	ok(fadeStart == 0, `seed {seed}: opaque at the start`)
end

-- 3. Sounds
ok(Rules.soundFor("Coins", true, "upgrade") == "ui_locked", "locked wins")
ok(Rules.soundFor("Stars", false, "upgrade") == "upgrade", "explicit key")
ok(Rules.soundFor("Stars", false, "") == "", "explicit silence")
ok(Rules.soundFor("Coins", false, nil) == "ui_claim", "coins -> claim")
ok(Rules.soundFor("Studs", false, nil) == "ui_click", "default click")
ok(Rules.kind("Bogus") == "Stars" and Rules.kind(42) == "Stars" and Rules.kind("Coins") == "Coins", "kind sanitising")

print(`[button-feedback] {checks} checks passed`)
