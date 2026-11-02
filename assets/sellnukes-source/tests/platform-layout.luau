--!strict
--[[
	Platform layout regressions (Platform/LayoutLogic + Platform/NavLogic). Run:
		lune run tests/platform-layout

	Proves on the shipped modules:
	  1. TV-safe insets: 5 % per side at 1080p and 4K, invalid input → zero, cap at 20 %.
	  2. Default jump-button geometry (Roblox TouchJump small / large screens).
	  3. Touch placement on a 844x390 phone and a 1180x820 tablet: every button is inside the
	     canvas, never over the jump button, never over another touch button, never over the
	     HUD columns / thumbstick; the primary button sits left of the jump button when free;
	     the column fallback still keeps buttons off the jump button and each other.
	  4. Menu ring positions and tile sizing.
	  5. Grid links (partial last row, wrap, list), scroll-follow targets, reading order.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local LayoutLogic = loader.load("src/client/Platform/LayoutLogic")
local NavLogic = loader.load("src/client/Platform/NavLogic")
local PlatformConfig = loader.load("src/shared/Config/PlatformConfig")
local TouchLayout = loader.load("src/shared/Util/TouchLayout")

local checks = 0
local function eq(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(`{label}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
	checks += 1
end
local function truthy(value: any, label: string)
	if not value then
		error(`{label}: expected truthy, got {tostring(value)}`, 2)
	end
	checks += 1
end

-- 1. TV insets.
local tv = LayoutLogic.tvInsets(1920, 1080, 0.05)
eq(tv.left, 96, "1080p left")
eq(tv.top, 54, "1080p top")
eq(tv.right, 96, "1080p right")
eq(tv.bottom, 54, "1080p bottom")
local tv4k = LayoutLogic.tvInsets(3840, 2160, 0.05)
eq(tv4k.left, 192, "4K left")
eq(tv4k.top, 108, "4K top")
eq(LayoutLogic.tvInsets(0 / 0, 1080, 0.05).left, 0, "NaN viewport")
eq(LayoutLogic.tvInsets(1920, 1080, -1).left, 0, "negative fraction")
eq(LayoutLogic.tvInsets(1000, 1000, 0.9).left, 200, "capped at 20 %")
truthy(LayoutLogic.insetsEqual(tv, { left = 96, top = 54, right = 96, bottom = 54 }), "insetsEqual")

-- 2. Jump geometry.
local cfg = PlatformConfig.Touch
local phoneJump = LayoutLogic.jumpRect(844, 390, cfg.DefaultJump)
eq(phoneJump.x, 749, "phone jump x")
eq(phoneJump.y, 300, "phone jump y")
eq(phoneJump.w, 70, "phone jump size")
local tabletJump = LayoutLogic.jumpRect(1180, 820, cfg.DefaultJump)
eq(tabletJump.w, 120, "tablet jump size")
eq(tabletJump.x, 1010, "tablet jump x")

-- 3. Touch placement. Design-px canvases at the DeviceProfile scales: phone 0.62
-- (844x390 pt -> 1361x629), tablet 1180/1920 ≈ 0.6146 -> 1920x1334 (fit to width).
local function check(
	name: string,
	canvasX: number,
	canvasY: number,
	scale: number,
	jumpPts: any,
	reserved: { any },
	sizes: { string }
)
	local jump = { x = jumpPts.x / scale, y = jumpPts.y / scale, w = jumpPts.w / scale, h = jumpPts.h / scale }
	local px: { number } = {}
	for index, class in sizes do
		px[index] = TouchLayout.pointsToDesign(cfg.Sizes[class], scale)
	end
	local rects = LayoutLogic.placeTouchButtons({
		canvasX = canvasX,
		canvasY = canvasY,
		jump = jump,
		sizes = px,
		reserved = reserved,
		gap = cfg.Gap / scale,
		margin = cfg.EdgeMargin / scale,
	})
	eq(#rects, #sizes, `{name}: one rect per button`)
	for index, rect in rects do
		truthy(LayoutLogic.inside(rect, canvasX, canvasY, 0), `{name} #{index} inside the canvas`)
		truthy(not LayoutLogic.overlaps(rect, jump), `{name} #{index} clear of the jump button`)
		eq(rect.w, px[index], `{name} #{index} keeps its size`)
		for other = index + 1, #rects do
			truthy(not LayoutLogic.overlaps(rect, rects[other]), `{name} #{index}/#{other} do not overlap`)
		end
	end
	return rects, jump
end

-- Phone: HUD right offer column (x ≥ 1217, down to y 459) + thumbstick zone reserved.
local phoneRight = { x = 1217, y = 60, w = 128, h = 399 }
local phoneStick = LayoutLogic.thumbstickRect(1361, 629, cfg.ThumbstickZone.width, cfg.ThumbstickZone.height)
local phoneRects, phoneJumpDesign = check(
	"phone",
	1361,
	629,
	0.62,
	phoneJump,
	{ phoneRight, phoneStick },
	{ "large", "normal", "small" }
)
for index, rect in phoneRects do
	truthy(not LayoutLogic.overlaps(rect, phoneRight), `phone #{index} clear of the offers`)
	truthy(not LayoutLogic.overlaps(rect, phoneStick), `phone #{index} clear of the thumbstick`)
end
truthy(phoneRects[1].x + phoneRects[1].w <= phoneJumpDesign.x, "phone primary left of the jump button")
-- Tablet.
local tabletRects = check("tablet", 1920, 1334, 1180 / 1920, tabletJump, {}, { "large", "normal", "small" })
truthy(tabletRects[1].x < tabletJump.x / (1180 / 1920), "tablet primary left of the jump button")
-- Live iPhone 13 geometry captured in Studio (design px): the HUD corner box is tight — the
-- objective chip ends at x 928, the offer column ends at y 438. The cluster must find the free
-- pocket up-left of the jump button and stay connected.
do
	local jump = { x = 1054, y = 482, w = 112, h = 112 }
	local right = { x = 1040, y = 122, w = 152, h = 316 }
	local chip = { x = 280, y = 547, w = 648, h = 64 }
	local left = { x = 16, y = 104, w = 472, h = 351 }
	local top = { x = 304, y = 8, w = 600, h = 160 }
	local reserved = { right, chip, left, top }
	local rects = LayoutLogic.placeTouchButtons({
		canvasX = 1208,
		canvasY = 627,
		jump = jump,
		sizes = { 117, 97, 78 },
		reserved = reserved,
		gap = 16,
		margin = 13,
	})
	for index, rect in rects do
		truthy(LayoutLogic.inside(rect, 1208, 627, 13), `live phone #{index} inside`)
		truthy(not LayoutLogic.overlaps(rect, jump), `live phone #{index} off the jump button`)
		for _, zone in reserved do
			truthy(not LayoutLogic.overlaps(rect, zone), `live phone #{index} off the HUD zones`)
		end
		for other = index + 1, #rects do
			truthy(not LayoutLogic.overlaps(rect, rects[other]), `live phone #{index}/#{other} apart`)
		end
	end
	eq(rects[1].x, 921, "primary in the pocket up-left of the jump button (x)")
	eq(rects[1].y, 349, "primary in the pocket up-left of the jump button (y)")
	eq(rects[2].x + 97 + 16, jump.x, "second button hugs the jump button's left side")
	-- Connected: every button touches the jump button or another button within gap + 1 px.
	for index, rect in rects do
		local near = false
		for _, other in { jump, rects[1], rects[2], rects[3] } do
			if other ~= rect then
				local gapX = math.max(other.x - (rect.x + rect.w), rect.x - (other.x + other.w))
				local gapY = math.max(other.y - (rect.y + rect.h), rect.y - (other.y + other.h))
				if math.max(gapX, gapY) <= 17 then
					near = true
				end
			end
		end
		truthy(near, `live phone #{index} is part of the cluster`)
	end
end
-- Everything reserved: the column fallback still never covers the jump button or each other.
check("fallback", 1361, 629, 0.62, phoneJump, { { x = 0, y = 0, w = 1361, h = 629 } }, { "large", "normal", "small" })

-- 4. Ring.
local ring = LayoutLogic.ring(4, 100)
eq(ring[1].x, 0, "ring starts at the top (x)")
eq(ring[1].y, -100, "ring starts at the top (y)")
eq(ring[2].x, 100, "clockwise: right second")
eq(ring[3].y, 100, "bottom third")
eq(#LayoutLogic.ring(0, 100), 0, "empty ring")
eq(LayoutLogic.ringTile(4, 270, 14, 82, 140), 140, "4 tiles at radius 270 fit the maximum")
eq(LayoutLogic.ringTile(10, 270, 14, 82, 140), 121, "10 square tiles: Chebyshev gap, not the chord")
eq(LayoutLogic.ringTile(13, 340, 14, 82, 140), 107, "13 tiles at the menu-wheel radius stay big")
eq(LayoutLogic.ringTile(40, 270, 14, 82, 140), 82, "never below the minimum")
-- Property (QA 2026-10-30): whenever the minimum clamp does not bind, no two square tiles of the
-- returned side overlap (centre gap on X or Y >= side + gap), for every count the wheel can show.
for count = 2, 16 do
	for _, radius in { 270, 340 } do
		local side = LayoutLogic.ringTile(count, radius, 14, 1, 1000)
		local points = LayoutLogic.ring(count, radius)
		for i = 1, #points - 1 do
			for j = i + 1, #points do
				local dx = math.abs(points[i].x - points[j].x)
				local dy = math.abs(points[i].y - points[j].y)
				eq(
					math.max(dx, dy) >= side + 14 - 1e-6,
					true,
					`ring {count}@{radius}: tiles {i}/{j} clear at side {side}`
				)
			end
		end
	end
end

-- 5. Navigation math.
local grid = NavLogic.gridLinks(5, 3, false, false)
eq(grid[1].right, 2, "grid right")
eq(grid[1].left, nil, "no wrap left")
eq(grid[1].down, 4, "grid down")
eq(grid[3].down, 5, "short column links down to the last cell")
eq(grid[5].up, 2, "last row up")
eq(grid[5].right, nil, "row end")
eq(grid[4].down, nil, "no wrap down")
local wrap = NavLogic.gridLinks(4, 2, true, true)
eq(wrap[1].left, 2, "wrap left")
eq(wrap[2].right, 1, "wrap right")
eq(wrap[1].up, 3, "wrap up")
eq(wrap[3].down, 1, "wrap down")
local partialWrap = NavLogic.gridLinks(5, 3, false, true)
eq(partialWrap[3].up, nil, "column 3 has no bottom cell: no self link")
eq(partialWrap[1].up, 4, "column 1 wraps to its bottom cell")
local column = NavLogic.listLinks(3, true, true)
eq(column[1].up, 3, "list wrap up")
eq(column[3].down, 1, "list wrap down")
eq(column[1].left, nil, "column has no left")
local row = NavLogic.listLinks(3, false, false)
eq(row[2].left, 1, "row left")
eq(row[2].up, nil, "row has no up")
eq(#NavLogic.gridLinks(0, 3, true, true), 0, "empty grid")
eq(NavLogic.gridLinks(1, 3, true, true)[1].left, nil, "single cell never links to itself")
eq(NavLogic.scrollTarget(900, 100, 0, 400, 2000, 20), 620, "scroll down into view")
eq(NavLogic.scrollTarget(100, 100, 500, 400, 2000, 20), 80, "scroll up into view")
eq(NavLogic.scrollTarget(600, 100, 500, 400, 2000, 20), 500, "already visible")
eq(NavLogic.scrollTarget(1950, 100, 0, 400, 2000, 20), 1600, "clamped to the end")
eq(NavLogic.scrollTarget(0, 900, 300, 400, 2000, 20), 0, "huge item aligns to its start (clamped)")
local order = NavLogic.readingOrder({ { x = 200, y = 10 }, { x = 10, y = 14 }, { x = 10, y = 200 } }, 8)
eq(order[1], 2, "reading order: left of the first row")
eq(order[2], 1, "then right")
eq(order[3], 3, "then the next row")

print(`[platform-layout] {checks} checks passed`)
