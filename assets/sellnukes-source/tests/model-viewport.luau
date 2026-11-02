--!strict
--[[
	ModelViewport framing + Shop model mapping regressions (owner R39: real 3D models in the Shop).
	Run:
		lune run tests/model-viewport

	Proves on the shipped src/client/UI/Widgets/ModelViewportLogic.luau:
	  1. fitDistance + orbit FRAME THE WHOLE MODEL at every turntable angle: every corner of the
	     bounding box, seen from the orbit camera at 72 yaw steps, projects inside the field of
	     view (vertical FOV + the frame's aspect) — for tall, flat, wide, tiny and huge boxes,
	     several pitches and aspects; and the fit is tight (some corner reaches >= 80 % of the
	     frame edge, so models are not shown postage-stamp small). Zoom divides the distance.
	  1b. sweptBounds + fitSwept on real part-corner clouds (1..5 copies of a prop arranged by
	     copyOffsets): every corner stays inside the frame at every angle around the swept
	     centre, and the framing is tighter than the group bounding box's (piles fill the slot).
	  1c. profile + fitProfile (the EXACT fit the widget uses) on those clouds, a tapered "crown"
	     and a tall thin "nuke": the hull contains every (r, y) point, every corner stays inside
	     the frame at every turntable angle and pitch / aspect, the fit is never farther than the
	     cylinder fit, and it is tight (the worst corner reaches >= 95 % of a frame edge).
	  2. orbit: yaw 0 sits in front of the model (-Z) looking at the centre, at `distance`.
	  3. lightDirection: unit length and CONSTANT in camera space across turntable angles.
	  4. copies / copyOffsets: clamped 1..MaxCopies, one CFrame per copy, symmetric about X = 0,
	     distinct positions.
	  5. maxLive: High 12 (the owner's cap), Mid 8, Low 0 (still frames), Reduce Motion 0.
	And on src/client/UI/Screens/Shop/ShopModels.luau:
	  6. every Shop section item (passes, cash, gems, spins, boosts, packs) has a model spec;
	     key specs exist in MeshAssets or are A2-props' pending Shop_* props; pet / egg / crate
	     ids exist; pack tiles cover every line with the reward pet on the last line; the spins
	     tile swaps to SpinsAsGems; allSpecs is de-duplicated and includes both pack pets.
	  6b. ShopConfig.WorldSections (Dino Valley, Moon Base): every row's product exists, its icon is
	     uploaded and its shop prop is a synced, uploaded MeshAssets model within budget.
	  7. ShopText.scaled (src/client/UI/Screens/Shop/ShopText.luau): design text limits scale with
	     the label, so a two-line caption box always fits two lines at its minimum.
]]

local Loader = require("./fixtures/RobloxLoader")
local roblox = require("@lune/roblox")

local loader = Loader.new()
local L = loader.load("src/client/UI/Widgets/ModelViewportLogic")
local ShopModels = loader.load("src/client/UI/Screens/Shop/ShopModels")
local ShopConfig = loader.load("src/shared/Config/ShopConfig")
local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local PetConfig = loader.load("src/shared/Config/PetConfig")
local EggConfig = loader.load("src/shared/Config/EggConfig")
local CrateConfig = loader.load("src/shared/Config/CrateConfig")
local ShopText = loader.load("src/client/UI/Screens/Shop/ShopText")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")

local V = roblox.Vector3.new
local CF = roblox.CFrame

-- Length of the horizontal offset (dx, dz).
local function horizontalLength(dx: number, dz: number): number
	return math.sqrt(dx * dx + dz * dz)
end

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(label, 2)
	end
	checks += 1
end
local function near(a: number, b: number, label: string, eps: number?)
	ok(math.abs(a - b) <= (eps or 1e-4), `{label}: {a} vs {b}`)
end

local Config = L.Config

-- 1. framing: project every box corner at every turntable angle --------------------------------
local SIZES = {
	V(2, 3, 2), -- typical prop
	V(1, 6, 1), -- tall nuke
	V(6, 0.6, 6), -- flat buy pad
	V(8, 2, 1), -- wide sign
	V(0.2, 0.2, 0.2), -- tiny
	V(40, 25, 30), -- huge
	V(3, 2.4, 7), -- long
}
local PITCHES = { 0, Config.Pitch, 30 }
local ASPECTS = { 1, 0.6, 1.8 }
local CENTERS = { V(0, 0, 0), V(0.4, 1.5, -0.3) }
for _, size in SIZES do
	for _, pitch in PITCHES do
		for _, aspect in ASPECTS do
			for _, center in CENTERS do
				local distance = L.fitDistance(size, Config.FieldOfView, aspect, pitch, 1)
				ok(distance > 0 and distance == distance, "distance positive + finite")
				local tanV = math.tan(math.rad(Config.FieldOfView) / 2)
				local tanH = tanV * aspect
				local widest = 0
				for step = 0, 71 do
					local cam = L.orbit(center, distance, pitch, step * 5)
					for sx = -1, 1, 2 do
						for sy = -1, 1, 2 do
							for sz = -1, 1, 2 do
								local corner = center + V(sx * size.X / 2, sy * size.Y / 2, sz * size.Z / 2)
								local local_ = cam:PointToObjectSpace(corner)
								local depth = -local_.Z -- camera looks down -Z
								ok(depth > 0, "corner in front of the camera")
								local fx = math.abs(local_.X) / depth / tanH
								local fy = math.abs(local_.Y) / depth / tanV
								ok(fx <= 1 + 1e-6, `corner inside horizontally ({size}, pitch {pitch}, aspect {aspect}): {fx}`)
								ok(fy <= 1 + 1e-6, `corner inside vertically ({size}, pitch {pitch}, aspect {aspect}): {fy}`)
								widest = math.max(widest, fx, fy)
							end
						end
					end
				end
				-- Tight: the conservative cylinder fit still fills most of the frame.
				ok(widest >= 0.6, `model fills the frame ({size}, pitch {pitch}, aspect {aspect}): {widest}`)
			end
		end
	end
end
-- A typical cube-ish prop at the default pitch on a square slot fills >= 80 % of the frame.
do
	local size = V(2, 2.6, 2)
	local distance = L.fitDistance(size, Config.FieldOfView, 1, Config.Pitch, 1)
	local tanV = math.tan(math.rad(Config.FieldOfView) / 2)
	local widest = 0
	for step = 0, 71 do
		local cam = L.orbit(V(0, 1.3, 0), distance, Config.Pitch, step * 5)
		for sx = -1, 1, 2 do
			for sy = -1, 1, 2 do
				for sz = -1, 1, 2 do
					local p = cam:PointToObjectSpace(V(sx, 1.3 + sy * 1.3, sz))
					widest = math.max(widest, math.abs(p.X) / -p.Z / tanV, math.abs(p.Y) / -p.Z / tanV)
				end
			end
		end
	end
	ok(widest >= 0.8, `typical prop fills >= 80 %: {widest}`)
end
-- zoom: magnification divides the distance; bad zoom values mean 1.
do
	local size = V(2, 3, 2)
	local base = L.fitDistance(size, 30, 1, 10, 1)
	near(L.fitDistance(size, 30, 1, 10, 2), base / 2, "zoom 2 halves the distance")
	near(L.fitDistance(size, 30, 1, 10, nil), base, "nil zoom = 1")
	near(L.fitDistance(size, 30, 1, 10, 0), base, "zero zoom = 1")
	near(L.fitDistance(size, 30, 1, 10, 0 / 0), base, "NaN zoom = 1")
	near(L.fitDistance(size, 30, 0 / 0, 10, 1), base, "NaN aspect = square")
	-- Hand check (2 x 2 x 2 cube, pitch 0, square): (r / tan15 + r) * padding, r = sqrt(2).
	local r = math.sqrt(2)
	near(L.fitDistance(V(2, 2, 2), 30, 1, 0, 1), (r / math.tan(math.rad(15)) + r) * Config.Padding, "hand check", 1e-6)
	near(L.fitSwept(r, 1, 30, 1, 0, 1), L.fitDistance(V(2, 2, 2), 30, 1, 0, 1), "fitDistance = fitSwept of the box", 1e-9)
	near(L.fitSwept(0 / 0, 1, 30, 1, 0, 1), L.fitSwept(0, 1, 30, 1, 0, 1), "NaN radius = 0")
end

-- 1b. swept bounds of part-corner clouds --------------------------------------------------------
do
	local center, radius, halfHeight = L.sweptBounds({ V(1, 0, 0), V(-1, 2, 0) })
	near((center - V(0, 1, 0)).Magnitude, 0, "sweptBounds centre")
	near(radius, 1, "sweptBounds radius")
	near(halfHeight, 1, "sweptBounds half height")
	local _, emptyRadius = L.sweptBounds({})
	near(emptyRadius, 0, "sweptBounds of nothing is empty")
	local unit = V(1.6, 2.6, 0.5) -- a coin-like prop standing on its edge
	for count = 1, Config.MaxCopies do
		local points = {}
		local minP, maxP = V(math.huge, math.huge, math.huge), V(-math.huge, -math.huge, -math.huge)
		for _, offset in L.copyOffsets(count, unit) do
			for sx = -1, 1, 2 do
				for sy = 0, 1 do
					for sz = -1, 1, 2 do
						local p = offset:PointToWorldSpace(V(sx * unit.X / 2, sy * unit.Y, sz * unit.Z / 2))
						table.insert(points, p)
						minP, maxP = minP:Min(p), maxP:Max(p)
					end
				end
			end
		end
		local c, r, h = L.sweptBounds(points)
		local distance = L.fitSwept(r, h, Config.FieldOfView, 1, Config.Pitch, 1)
		local boxDistance = L.fitDistance(maxP - minP, Config.FieldOfView, 1, Config.Pitch, 1)
		ok(distance <= boxDistance + 1e-6, `{count} copies: swept fit never farther than the box fit`)
		if count >= 2 then
			ok(distance < boxDistance * 0.97, `{count} copies: swept fit is tighter ({distance} vs {boxDistance})`)
		end
		local tanV = math.tan(math.rad(Config.FieldOfView) / 2)
		for step = 0, 71 do
			local cam = L.orbit(c, distance, Config.Pitch, step * 5)
			for _, p in points do
				local q = cam:PointToObjectSpace(p)
				ok(-q.Z > 0, "point in front of the camera")
				ok(math.abs(q.X) / -q.Z <= tanV + 1e-9 and math.abs(q.Y) / -q.Z <= tanV + 1e-9, `{count} copies inside the frame`)
			end
		end
	end
end

-- 1c. exact profile fit ------------------------------------------------------------------------
do
	-- Point clouds: piles of a coin-like prop, a tapered crown-like stack, a tall thin nuke.
	local clouds: { { any } } = {}
	local unit = V(1.6, 2.6, 0.5)
	for count = 1, Config.MaxCopies do
		local points = {}
		for _, offset in L.copyOffsets(count, unit) do
			for sx = -1, 1, 2 do
				for sy = 0, 1 do
					for sz = -1, 1, 2 do
						table.insert(points, offset:PointToWorldSpace(V(sx * unit.X / 2, sy * unit.Y, sz * unit.Z / 2)))
					end
				end
			end
		end
		table.insert(clouds, { `{count} coins`, points })
	end
	local function boxCorners(points: { any }, cf: any, size: any)
		for sx = -1, 1, 2 do
			for sy = -1, 1, 2 do
				for sz = -1, 1, 2 do
					table.insert(points, cf:PointToWorldSpace(V(sx * size.X / 2, sy * size.Y / 2, sz * size.Z / 2)))
				end
			end
		end
	end
	local crown = {}
	boxCorners(crown, CF.new(0, 0.3, 0), V(3, 0.6, 3)) -- wide base band
	boxCorners(crown, CF.new(0, 1.2, 0) * CF.Angles(0, math.rad(30), 0), V(2.2, 1.2, 2.2))
	boxCorners(crown, CF.new(0, 2.2, 0), V(0.5, 0.8, 0.5)) -- narrow tip
	table.insert(clouds, { "crown", crown })
	local nuke = {}
	boxCorners(nuke, CF.new(0.3, 3, 0), V(1, 6, 1))
	boxCorners(nuke, CF.new(0.3, 0.4, 0), V(2.4, 0.8, 0.4)) -- fins
	table.insert(clouds, { "nuke", nuke })

	for _, entry in clouds do
		local label, points = entry[1], entry[2]
		local center = L.sweptBounds(points)
		local hull = L.profile(points, center)
		ok(#hull >= 3, `{label}: profile hull has an area`)
		-- Every (r, y) lies inside (or on) the counter-clockwise hull.
		for _, p in points do
			local r = horizontalLength(p.X - center.X, p.Z - center.Z)
			local y = p.Y - center.Y
			for index, a in hull do
				local b = hull[index % #hull + 1]
				ok((b[1] - a[1]) * (y - a[2]) - (b[2] - a[2]) * (r - a[1]) >= -1e-9, `{label}: point inside the hull`)
			end
		end
		for _, pitch in { 0, Config.Pitch, 30 } do
			for _, aspect in { 1, 0.7, 1.6 } do
				local _, radius, halfHeight = L.sweptBounds(points)
				local exact = L.fitProfile(hull, Config.FieldOfView, aspect, pitch, 1)
				local cylinder = L.fitSwept(radius, halfHeight, Config.FieldOfView, aspect, pitch, 1)
				ok(exact <= cylinder + 1e-9, `{label}: exact fit never farther than the cylinder fit`)
				local tanV = math.tan(math.rad(Config.FieldOfView) / 2)
				local tanH = tanV * aspect
				local widest = 0
				for step = 0, 143 do
					local cam = L.orbit(center, exact, pitch, step * 2.5)
					for _, p in points do
						local q = cam:PointToObjectSpace(p)
						ok(-q.Z > 0, `{label}: point in front of the camera`)
						local fx, fy = math.abs(q.X) / -q.Z / tanH, math.abs(q.Y) / -q.Z / tanV
						ok(fx <= 1 + 1e-6 and fy <= 1 + 1e-6, `{label} pitch {pitch} aspect {aspect}: inside ({fx}, {fy})`)
						widest = math.max(widest, fx, fy)
					end
				end
				ok(widest * Config.Padding >= 0.95, `{label} pitch {pitch} aspect {aspect}: tight fit ({widest})`)
			end
		end
	end
	ok(#L.profile({}, V(0, 0, 0)) == 0, "empty profile")
	ok(L.fitProfile({}, 30, 1, 14, 1) > 0, "empty hull still returns a distance")
end

-- 2. orbit ----------------------------------------------------------------------------------
do
	local cam = L.orbit(V(1, 2, 3), 10, 0, 0)
	near((cam.Position - V(1, 2, -7)).Magnitude, 0, "yaw 0 pitch 0: straight in front (-Z)")
	near((cam.LookVector - V(0, 0, 1)).Magnitude, 0, "looks +Z at the model front")
	local high = L.orbit(V(0, 0, 0), 10, 30, 90)
	near(high.Position.Magnitude, 10, "orbit keeps the distance")
	near(high.Position.Y, 10 * math.sin(math.rad(30)), "pitch lifts the camera")
	ok(high.Position.X > 9 * math.cos(math.rad(30)) * 0.99, "yaw 90 orbits to +X")
	near((high.LookVector + high.Position.Unit).Magnitude, 0, "always looks at the centre")
end

-- 3. light fixed in camera space --------------------------------------------------------------
do
	local expected = Config.LightLocal.Unit
	for step = 0, 11 do
		local cam = L.orbit(V(0, 1, 0), 8, Config.Pitch, step * 30)
		local dir = L.lightDirection(cam)
		near(dir.Magnitude, 1, "light direction is a unit vector")
		near((cam:VectorToObjectSpace(dir) - expected).Magnitude, 0, "light constant in camera space")
	end
end

-- 4. copies -------------------------------------------------------------------------------------
near(L.copies(nil), 1, "nil copies = 1")
near(L.copies(0 / 0), 1, "NaN copies = 1")
near(L.copies(-3), 1, "negative copies = 1")
near(L.copies(2.7), 2, "fractional copies floor")
near(L.copies(99), Config.MaxCopies, "copies clamp to MaxCopies")
for count = 1, Config.MaxCopies do
	local offsets = L.copyOffsets(count, V(2, 3, 1.5))
	ok(#offsets == count, `{count} copies -> {count} offsets`)
	local sumX = 0
	for i, a in offsets do
		sumX += a.Position.X
		ok(math.abs(a.Position.Y) < 1e-9, "copies stand on the ground plane")
		for j, b in offsets do
			if i < j then
				ok((a.Position - b.Position).Magnitude > 0.5, `copies {i} / {j} do not stack in place`)
			end
		end
	end
	near(sumX, 0, `{count} copies symmetric about X = 0`)
end

-- 5. live budget --------------------------------------------------------------------------------
near(L.maxLive("High", false), 12, "High: 12 spinning (owner cap)")
near(L.maxLive("Mid", false), 8, "Mid: 8 spinning")
near(L.maxLive("Low", false), 0, "Low: still frames only")
near(L.maxLive("High", true), 0, "Reduce Motion: still frames")
near(L.maxLive("???", false), 8, "unknown tier = Mid")
for _, tier in { "Low", "Mid", "High" } do
	ok(L.maxLive(tier, false) <= 12, "never more than 12 live viewports")
end

-- 6. Shop mapping ---------------------------------------------------------------------------------
-- Shop props A2-props is building (synced into MeshAssets as they land; icon fallback until then).
local PENDING_PROPS = {
	Shop_CashStack = true,
	Shop_CashPile = true,
	Shop_GemCluster = true,
	Shop_GemChest = true,
	Shop_SpinToken = true,
	Shop_BoostPotion = true,
	Shop_MoneyBag = true,
	Shop_VipCrown = true,
	Shop_ServerBoost = true,
	Shop_Teleporter = true,
	Shop_FastShoe = true,
	Shop_AutoClicker = true,
	Shop_OfflineMoon = true,
	Shop_PetSlots = true,
	Shop_TripleEgg = true,
}
local function validSpec(spec: any, label: string)
	ok(type(spec) == "table", `{label}: has a model spec`)
	if spec.pet ~= nil then
		ok(PetConfig.get(spec.pet) ~= nil, `{label}: pet {spec.pet} exists`)
	elseif spec.egg ~= nil then
		ok(EggConfig.get(spec.egg) ~= nil, `{label}: egg {spec.egg} exists`)
	elseif spec.crate ~= nil then
		ok(CrateConfig.get(spec.crate) ~= nil, `{label}: crate {spec.crate} exists`)
	else
		ok(type(spec.key) == "string", `{label}: key spec`)
		ok(MeshAssets[spec.key] ~= nil or PENDING_PROPS[spec.key], `{label}: {spec.key} is a MeshAssets key / pending prop`)
	end
	ok(spec.copies == nil or (spec.copies >= 1 and spec.copies <= Config.MaxCopies), `{label}: copies in range`)
end
for _, section in ShopConfig.Sections do
	for _, ref in section.items do
		if ref.kind == "pass" then
			validSpec(ShopModels.forPass(MonetizationConfig.getPass(ref.key)), `pass {ref.key}`)
		else
			validSpec(ShopModels.forProduct(MonetizationConfig.getProduct(ref.key)), `product {ref.key}`)
		end
	end
end
-- Robux crates map through CrateConfig.ByProduct.
for product, crateId in CrateConfig.ByProduct do
	local spec = ShopModels.forProduct(MonetizationConfig.getProduct(product))
	ok(spec ~= nil and spec.crate == crateId, `crate product {product} -> {crateId}`)
end
ok(ShopModels.forProduct(nil) == nil and ShopModels.forPass(nil) == nil, "nil defs -> nil")
-- Pack tiles.
for _, packKey in { "StarterPack", "SecretPack" } do
	local pack = ShopConfig[packKey]
	for _, asGems in { false, true } do
		local items = ShopModels.packItems(packKey, pack, asGems)
		for line = 1, #pack.lines do
			validSpec(items[line], `{packKey} tile {line}`)
		end
		ok(items[#pack.lines].pet == pack.reward.pet, `{packKey}: last tile is the reward pet`)
		if asGems then
			ok(items[pack.spinLine] == ShopModels.SpinsAsGems, `{packKey}: spins tile shows gems when restricted`)
		else
			ok(items[pack.spinLine].key == "Shop_SpinToken", `{packKey}: spins tile shows spin tokens`)
		end
	end
end
-- allSpecs: de-duplicated, includes both pack pets.
do
	local all = ShopModels.allSpecs()
	local seen: { [string]: boolean } = {}
	local pets: { [string]: boolean } = {}
	for _, spec in all do
		local id = `{spec.key}|{spec.pet}|{spec.egg}|{spec.crate}|{spec.copies}`
		ok(not seen[id], `allSpecs has no duplicate {id}`)
		seen[id] = true
		if spec.pet ~= nil then
			pets[spec.pet] = true
		end
	end
	ok(pets[ShopConfig.StarterPack.reward.pet] and pets[ShopConfig.SecretPack.reward.pet], "allSpecs includes pack pets")
	ok(#all >= 15, `allSpecs covers the shop ({#all})`)
end

-- 6b. World sections (R57 Dino Valley, R70 Moon Base): every row names a real product, an icon the
-- pipeline uploaded and a synced shop-prop mesh; ShopModels.worldSpecs covers every row.
do
	local IconAssets = loader.load("src/shared/Config/IconAssets")
	for _, section in ShopConfig.WorldSections do
		ok(WorldsConfig.get(section.world) ~= nil, `world section {section.id}: known world {section.world}`)
		local specs = ShopModels.worldSpecs(section.world)
		ok(#specs >= #section.items, `world section {section.id}: worldSpecs covers every row`)
		for _, item in section.items do
			ok(MonetizationConfig.getProduct(item.key) ~= nil, `{section.id}: product {item.key} exists`)
			local icon = IconAssets.get(item.icon)
			ok(icon ~= nil and icon.image ~= "", `{section.id}: icon {item.icon} is uploaded`)
			local asset = MeshAssets[item.model]
			ok(asset ~= nil, `{section.id}: shop prop {item.model} is in MeshAssets`)
			for name, piece in asset.pieces do
				ok(piece.id > 0, `{section.id}: {item.model}.{name} is uploaded`)
			end
			ok(asset.triangles <= 2000, `{section.id}: {item.model} within the 2,000-triangle prop budget`)
		end
	end
end

-- 7. ShopText: design text limits follow the on-screen scale (small-screen captions keep line 2).
do
	local min, max = ShopText.scaled(18, 28, 0.5)
	ok(min == 9 and max == 14, `half scale halves the limits ({min}, {max})`)
	min, max = ShopText.scaled(18, 28, 1.37)
	ok(min == 25 and max == 38, `touch scale grows them ({min}, {max})`)
	min, max = ShopText.scaled(18, 28, 0 / 0)
	ok(min == 18 and max == 28, "NaN scale = design")
	min, max = ShopText.scaled(18, 28, 0.01)
	ok(min >= 1 and max >= min, "never below 1 px, max never below min")
	-- The pack caption box (56 design px) holds two lines at the design minimum at ANY scale.
	for _, factor in { 0.35, 0.5, 0.75, 1, 1.4, 2 } do
		local floorPx = ShopText.scaled(18, 28, factor)
		ok(2 * floorPx <= 56 * factor + 1, `two caption lines fit at scale {factor}`)
	end
end

print(`[model-viewport] {checks} checks passed`)
