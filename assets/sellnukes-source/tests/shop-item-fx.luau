--!strict
--[[
	Shop item plates + idle animation (owner R98: "the item in the shop should be animated. also
	they are hard to see with the stud background"). Run:
		lune run tests/shop-item-fx

	Loads the REAL src/client/UI/Screens/Shop/{ItemFxLogic, ShopModels}.luau and
	src/shared/Config/{ShopItemFxConfig, UIStyleConfig}.luau and proves:
	  1. Config: Low graphics parks the motion (rate 0), Medium / High step at a sane rate; the
	     bob / pulse are gentle; a glint is shorter than its period.
	  2. phase: in [0, 2pi); neighbouring items of a card and neighbouring cards are staggered;
	     junk input still gives a finite phase.
	  3. pose: rests at (0, 1) at t = 0 / phase 0 and for junk input; stays within the bob /
	     pulse bounds; is periodic; scale peaks at the top of the bob; a 30 Hz step never jumps
	     more than the sine's slope allows; a card's items are never in lock-step.
	  4. glint: nothing glints the instant the Shop opens; it shows for Glint.Seconds of every
	     period, pops 0 -> ~1 -> 0 while turning 0 .. SweepDegrees; the glints of a 4- or 5-tile
	     rare pack never overlap (they travel across the card); junk input hides it.
	  5. plateLook: for EVERY UIStyleConfig colour the plate is darker than its card face and
	     white text on it (through the plate's transparency, over the card's lightest and
	     darkest face colour) has >= 4.5:1 contrast (WCAG AA) — the R98 readability promise.
	  6. parked: Low graphics or Reduce Motion park the motion; Medium / High do not.
	  7. ShopModels.isRare: pets / eggs / crates glint, props / nukes / icons do not; the packs'
	     pet tile is rare, the other Starter Pack tiles are not.
]]

local Loader = require("./fixtures/RobloxLoader")
local roblox = require("@lune/roblox")

local Color3 = roblox.Color3
type Color3 = roblox.Color3

local loader = Loader.new()
local Logic = loader.load("src/client/UI/Screens/Shop/ItemFxLogic")
local ShopModels = loader.load("src/client/UI/Screens/Shop/ShopModels")
local Cfg = loader.load("src/shared/Config/ShopItemFxConfig")
local UIStyleConfig = loader.load("src/shared/Config/UIStyleConfig")
local ShopConfig = loader.load("src/shared/Config/ShopConfig")
local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local function finite(x: number): boolean
	return type(x) == "number" and x == x and x > -math.huge and x < math.huge
end

local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-6)
end

local TAU = 2 * math.pi
local BOB, PULSE = Cfg.Bob.Pixels, Cfg.Pulse.Amount
local PERIOD = Cfg.Bob.PeriodSeconds
local GLINT_PERIOD, GLINT_SECONDS = Cfg.Glint.PeriodSeconds, Cfg.Glint.Seconds

-- 1. Config ---------------------------------------------------------------------------------------

check(Cfg.Hz.Low == 0, "Low graphics parks the item motion")
check(Cfg.Hz.Medium > 0 and Cfg.Hz.Medium <= Cfg.Hz.High and Cfg.Hz.High <= 60, "Medium / High rates sane")
check(BOB > 0 and BOB <= 6, "bob is gentle (<= 6 design px)")
check(PULSE > 0 and PULSE <= 0.08, "pulse is slight (<= 8 %)")
check(PERIOD >= 1.5, "bob is slow (>= 1.5 s period)")
check(GLINT_SECONDS > 0 and GLINT_SECONDS < GLINT_PERIOD / 2, "a glint is short next to its period")
check(Cfg.Glint.Size > 0 and Cfg.Glint.Size < 1, "glint fits the slot")
check(Cfg.Glint.RayWidth > 0 and Cfg.Glint.RayWidth < 0.5, "glint rays are thin")

-- 2. phase ----------------------------------------------------------------------------------------

for seed = 0, 12 do
	for index = 1, 6 do
		local p = Logic.phase(seed, index)
		check(finite(p) and p >= 0 and p < TAU, `phase({seed}, {index}) in [0, 2pi)`)
	end
	local step = (Logic.phase(seed, 2) - Logic.phase(seed, 1)) % TAU
	check(near(step, Cfg.Stagger.ItemRadians % TAU, 1e-9), `items of card {seed} are staggered`)
end
check(not near(Logic.phase(1, 1), Logic.phase(2, 1)), "neighbouring cards are staggered")
check(finite(Logic.phase(0 / 0, math.huge)), "junk seed / index still give a finite phase")
check(Logic.phase(0, 1) == 0, "first item of seed 0 starts at phase 0")

-- 3. pose -----------------------------------------------------------------------------------------

local y0, s0 = Logic.pose(0, 0)
check(near(y0, 0) and near(s0, 1), "rest pose at t = 0, phase 0")
for _, junk in { 0 / 0, math.huge, -math.huge } do
	local y, s = Logic.pose(junk, 0)
	check(y == 0 and s == 1, "junk time rests the item")
	y, s = Logic.pose(1, junk)
	check(y == 0 and s == 1, "junk phase rests the item")
end

local HZ = 30
local maxStep = BOB * TAU / PERIOD / HZ -- the sine's steepest slope over one 30 Hz step
for index = 1, 5 do
	local phase = Logic.phase(3, index)
	local lastY: number? = nil
	local topY, topScale = math.huge, 0
	for frame = 0, math.floor(PERIOD * HZ * 2) do
		local t = frame / HZ
		local y, s = Logic.pose(t, phase)
		check(finite(y) and finite(s), "pose finite")
		check(y >= -BOB - 1e-9 and y <= BOB + 1e-9, "bob within +/- Bob.Pixels")
		check(s >= 1 - PULSE - 1e-9 and s <= 1 + PULSE + 1e-9, "pulse within 1 +/- Pulse.Amount")
		-- Bob and pulse share one sine: scale - 1 is proportional to -y.
		check(near((s - 1) / PULSE, -y / BOB, 1e-9), "scale peaks at the top of the bob")
		local py, ps = Logic.pose(t + PERIOD, phase)
		check(near(py, y, 1e-6) and near(ps, s, 1e-9), "pose is periodic")
		if lastY ~= nil then
			check(math.abs(y - lastY) <= maxStep + 1e-9, "no jump between 30 Hz steps")
		end
		lastY = y
		if y < topY then
			topY, topScale = y, s
		end
	end
	check(near(topY, -BOB, BOB * 0.02) and topScale > 1 + PULSE * 0.98, "reaches the top of the bob, largest there")
end
-- A card's items never move in lock-step: at some sampled time neighbours differ visibly.
local differs = false
for frame = 0, 60 do
	local a = Logic.pose(frame / HZ, Logic.phase(1, 1))
	local b = Logic.pose(frame / HZ, Logic.phase(1, 2))
	if math.abs(a - b) > BOB * 0.5 then
		differs = true
	end
end
check(differs, "neighbouring tiles ripple, not lock-step")

-- 4. glint ----------------------------------------------------------------------------------------

local amount0 = Logic.glint(0, 0)
check(amount0 == 0, "nothing glints the instant the Shop opens")
for _, junk in { 0 / 0, math.huge } do
	check(Logic.glint(junk, 0) == 0 and Logic.glint(1, junk) == 0, "junk input hides the glint")
end
local GLINT_HZ = 240
local shown, peak, minRot, maxRot = 0, 0, math.huge, -math.huge
local samples = math.floor(GLINT_PERIOD * GLINT_HZ)
for frame = 0, samples - 1 do
	local amount, rotation = Logic.glint(frame / GLINT_HZ, 0)
	check(finite(amount) and amount >= 0 and amount <= 1, "glint amount in [0, 1]")
	if amount > 0 then
		shown += 1
		peak = math.max(peak, amount)
		minRot, maxRot = math.min(minRot, rotation), math.max(maxRot, rotation)
		check(rotation >= 0 and rotation <= Cfg.Glint.SweepDegrees + 1e-9, "glint turns within its sweep")
	else
		check(rotation == 0, "hidden glint has no rotation")
	end
end
check(near(shown / samples, GLINT_SECONDS / GLINT_PERIOD, 2 / GLINT_HZ), "glint shows Glint.Seconds per period")
check(peak > 0.99, "glint pops to full size")
check(minRot < 5 and maxRot > Cfg.Glint.SweepDegrees - 5, "glint turns through its sweep")
local a1 = Logic.glint(GLINT_PERIOD - GLINT_SECONDS / 2, 0)
check(near(a1, 1, 1e-9), "glint peaks mid-window")
local a2 = Logic.glint(GLINT_PERIOD * 3 - GLINT_SECONDS / 2, 0)
check(near(a2, 1, 1e-9), "glint repeats every period")

for _, count in { 1, 2, 4, 5 } do
	local offsets: { number } = {}
	for index = 1, count do
		local offset = Logic.glintOffset(index, count)
		check(offset >= 0 and offset < GLINT_PERIOD, "glint offset inside the period")
		for _, other in offsets do
			check(not near(offset, other, 1e-9), "glint offsets distinct")
		end
		table.insert(offsets, offset)
	end
	if count >= 2 and GLINT_PERIOD / count >= GLINT_SECONDS then
		-- A rare pack's glints travel across it: never two tiles at once.
		for frame = 0, samples - 1 do
			local lit = 0
			for index = 1, count do
				if Logic.glint(frame / GLINT_HZ, offsets[index]) > 0 then
					lit += 1
				end
			end
			check(lit <= 1, `at most one of {count} tiles glints at a time`)
		end
	end
end
check(GLINT_PERIOD / 5 >= GLINT_SECONDS, "a 5-tile Secret Pack's glints never overlap (period / 5 >= glint)")
check(Logic.glintOffset(0 / 0, 0 / 0) == 0, "junk glint offset -> 0")

-- 5. plateLook: readable white text on every card colour --------------------------------------

-- WCAG relative luminance of an sRGB colour (components 0..1).
local function channel(c: number): number
	return if c <= 0.03928 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
end
local function luminance(c: Color3): number
	return 0.2126 * channel(c.R) + 0.7152 * channel(c.G) + 0.0722 * channel(c.B)
end
local function contrast(a: Color3, b: Color3): number
	local la, lb = luminance(a), luminance(b)
	return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
end
-- What a `transparency` plate of `fill` looks like over `under`.
local function over(fill: Color3, transparency: number, under: Color3): Color3
	local k = 1 - transparency
	return Color3.new(
		fill.R * k + under.R * (1 - k),
		fill.G * k + under.G * (1 - k),
		fill.B * k + under.B * (1 - k)
	)
end

local Plate = UIStyleConfig.ItemPlate
local white = UIStyleConfig.Neutral.Text
local colours = 0
for name, preset in UIStyleConfig.Colors do
	colours += 1
	local look = Logic.plateLook(preset)
	check(look.ring == preset.accent and look.halo == preset.accent, `{name}: ring + halo in the card's accent`)
	check(luminance(look.fill) < luminance(preset.bottom), `{name}: plate darker than the card face`)
	for _, face in { preset.top, preset.bottom } do
		local seen = over(look.fill, Plate.FillTransparency, face)
		local ratio = contrast(white, seen)
		check(ratio >= 4.5, `{name}: white text on the plate >= 4.5:1 (got {math.floor(ratio * 100) / 100})`)
	end
	-- The plate's gradient darkens toward the bottom: still readable there, naturally.
	check(Plate.BottomShade > 0 and Plate.BottomShade <= 1, "plate bottom shade multiplies down")
end
check(colours >= 12, "every UIStyleConfig colour preset checked")
check(Plate.FillTransparency >= 0 and Plate.FillTransparency < 0.3, "plate mostly opaque")
check(Plate.HaloScale > Plate.DiscScale, "halo peeks out around the plate")
check(Plate.LabelStroke >= 2, "plated captions keep a fat outline")

-- 6. parked ---------------------------------------------------------------------------------------

check(Logic.parked(Cfg.Hz, "Low", false), "Low graphics parks")
check(not Logic.parked(Cfg.Hz, "Medium", false) and not Logic.parked(Cfg.Hz, "High", false), "Medium / High run")
check(Logic.parked(Cfg.Hz, "High", true), "Reduce Motion parks")

-- 7. ShopModels.isRare ----------------------------------------------------------------------------

check(ShopModels.isRare({ pet = "starter_atom_pup" }), "a pet is rare")
check(ShopModels.isRare({ egg = "lucky_egg" }), "an egg is rare")
check(ShopModels.isRare({ crate = "mega_crate" }), "a crate is rare")
check(not ShopModels.isRare({ key = "Shop_CashStack" }), "a shop prop is not rare")
check(not ShopModels.isRare({ key = "A7_SiloNuke_Gold" }), "a nuke is not rare")
check(not ShopModels.isRare(nil), "an icon-only item is not rare")
for _, packKey in { "StarterPack", "SecretPack" } do
	local pack = ShopConfig[packKey]
	local tiles = ShopModels.packItems(packKey, pack, false)
	check(ShopModels.isRare(tiles[#pack.lines]), `{packKey}: the pet tile glints`)
	if packKey == "StarterPack" then
		for index = 1, #pack.lines - 1 do
			check(not ShopModels.isRare(tiles[index]), `StarterPack tile {index} does not glint (only its pet)`)
		end
	end
end
check(ShopModels.isRare(ShopModels.forPass(MonetizationConfig.getPass("LuckyEggs"))), "Lucky Eggs pass glints")

print(`[shop-item-fx] {checks} checks passed`)
