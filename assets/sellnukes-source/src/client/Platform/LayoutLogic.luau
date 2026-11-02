--!strict
--[[
	LayoutLogic — pure screen geometry for the platform layer (no services / Instances; Lune
	tests in tests/platform-layout.luau).

	Units: every function works in ONE unit system the caller chooses (Platform code passes
	design px on the ScreenManager canvas). Rects are { x, y, w, h } with y growing downward,
	the same shape as Widgets/HudZones.Rect.

	Functions:
		tvInsets          console TV-safe inset per side (fraction of the viewport)
		insetsEqual       compare two inset tables
		jumpRect          Roblox's default TouchJump rect when the live button is unknown
		thumbstickRect    the bottom-left area the dynamic thumbstick owns
		overlaps / inside rect tests
		placeTouchButtons one connected cluster of square buttons grown from the jump button
		                  (closest free slot first) that avoids every reserved rect (HUD
		                  zones, thumbstick) and the screen edges
		ring              tile centres on a circle (the menu wheel)

	Connects to: Platform/{SafeArea, TouchButtons, MenuWheel}, Shared/Config/PlatformConfig.

	Example:
		local rects = LayoutLogic.placeTouchButtons({
			canvasX = 1361, canvasY = 629, jump = { x = 1208, y = 484, w = 113, h = 113 },
			sizes = { 135, 106 }, reserved = {}, gap = 16, margin = 13,
		})
]]

export type Rect = { x: number, y: number, w: number, h: number }
export type Insets = { left: number, top: number, right: number, bottom: number }

export type PlaceInput = {
	canvasX: number,
	canvasY: number,
	jump: Rect, -- the jump button (never covered)
	sizes: { number }, -- square button sides, in placement priority order
	reserved: { Rect }, -- HUD zones, thumbstick, chat, ... (never covered when avoidable)
	gap: number, -- space between buttons / the jump button
	margin: number, -- space kept from the canvas edges
}

local LayoutLogic = {}

-- True for a finite number (rejects NaN and ±inf).
local function finite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

--[[
	The TV-safe inset per side: `fraction` of the viewport width (left / right) and height
	(top / bottom), rounded to whole points. Invalid input gives zero insets.
	@param viewportX viewport width (points)
	@param viewportY viewport height (points)
	@param fraction  inset per side (PlatformConfig.SafeArea.TvFraction = 0.05)
	Example: LayoutLogic.tvInsets(1920, 1080, 0.05) --> { left = 96, top = 54, right = 96, bottom = 54 }
]]
function LayoutLogic.tvInsets(viewportX: number, viewportY: number, fraction: number): Insets
	if
		not finite(viewportX)
		or not finite(viewportY)
		or not finite(fraction)
		or viewportX <= 0
		or viewportY <= 0
		or fraction <= 0
	then
		return { left = 0, top = 0, right = 0, bottom = 0 }
	end
	local f = math.min(fraction, 0.2) -- never eat more than 20 % per side
	local x = math.floor(viewportX * f + 0.5)
	local y = math.floor(viewportY * f + 0.5)
	return { left = x, top = y, right = x, bottom = y }
end

--[[ True when two inset tables are identical. ]]
function LayoutLogic.insetsEqual(a: Insets, b: Insets): boolean
	return a.left == b.left and a.top == b.top and a.right == b.right and a.bottom == b.bottom
end

--[[
	Roblox's default TouchJump button rect (TouchJump.lua geometry) in POINTS.
	@param viewportX / viewportY screen size in points
	@param defaults PlatformConfig.Touch.DefaultJump
	Example: LayoutLogic.jumpRect(844, 390, cfg) --> { x = 749, y = 300, w = 70, h = 70 }
]]
function LayoutLogic.jumpRect(
	viewportX: number,
	viewportY: number,
	defaults: {
		read SmallScreenMax: number,
		read Small: { read size: number, read right: number, read bottom: number },
		read Large: { read size: number, read right: number, read bottom: number },
	}
): Rect
	local small = math.min(viewportX, viewportY) <= defaults.SmallScreenMax
	local g = if small then defaults.Small else defaults.Large
	return { x = viewportX - g.right, y = viewportY - g.bottom, w = g.size, h = g.size }
end

--[[
	The bottom-left rect the dynamic thumbstick owns (fractions of the canvas).
	Example: LayoutLogic.thumbstickRect(1000, 500, 0.4, 0.6) --> { x = 0, y = 200, w = 400, h = 300 }
]]
function LayoutLogic.thumbstickRect(
	canvasX: number,
	canvasY: number,
	widthFraction: number,
	heightFraction: number
): Rect
	local h = canvasY * heightFraction
	return { x = 0, y = canvasY - h, w = canvasX * widthFraction, h = h }
end

--[[ True when two rects intersect with a positive area. ]]
function LayoutLogic.overlaps(a: Rect, b: Rect): boolean
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

--[[ True when `rect` lies inside the canvas with `margin` free on every side. ]]
function LayoutLogic.inside(rect: Rect, canvasX: number, canvasY: number, margin: number): boolean
	return rect.x >= margin
		and rect.y >= margin
		and rect.x + rect.w <= canvasX - margin
		and rect.y + rect.h <= canvasY - margin
end

-- Where a new button may sit relative to an ANCHOR (the jump button or a placed button), in
-- tie-break order. Each returns the new square's top-left for side `s` and gap `g`.
type Slot = (anchor: Rect, s: number, g: number) -> (number, number)
local SLOTS: { Slot } = {
	-- left, vertically centred (the resting right thumb slides left)
	function(a: Rect, s: number, g: number): (number, number)
		return a.x - g - s, a.y + a.h / 2 - s / 2
	end,
	-- above, horizontally centred
	function(a: Rect, s: number, g: number): (number, number)
		return a.x + a.w / 2 - s / 2, a.y - g - s
	end,
	-- up-left diagonal
	function(a: Rect, s: number, g: number): (number, number)
		return a.x - g - s, a.y - g - s
	end,
	-- left, bottoms aligned
	function(a: Rect, s: number, g: number): (number, number)
		return a.x - g - s, a.y + a.h - s
	end,
	-- above, right edges aligned
	function(a: Rect, s: number, g: number): (number, number)
		return a.x + a.w - s, a.y - g - s
	end,
}

--[[
	Places square touch buttons as one tidy cluster grown from the jump button (see the module
	header).
	Rule: each button, in order, takes the FREE candidate closest to the jump button's centre
	(thumb reach), where candidates are the SLOTS around the jump button and around every button
	already placed (so the cluster stays connected). Free = inside the canvas (with margin) and
	overlapping neither the jump button, a reserved rect, nor a placed button. Ties keep the SLOTS
	order (left before above). If nothing is free (tiny screens), the button stacks in a column
	above the jump button, clamped to the canvas — it may then overlap a reserved rect, but never
	the jump button or another touch button.
	@return one rect per size, same order
]]
function LayoutLogic.placeTouchButtons(input: PlaceInput): { Rect }
	local jump = input.jump
	local jx = jump.x + jump.w / 2
	local jy = jump.y + jump.h / 2
	local placed: { Rect } = {}
	local function free(rect: Rect): boolean
		if not LayoutLogic.inside(rect, input.canvasX, input.canvasY, input.margin) then
			return false
		end
		if LayoutLogic.overlaps(rect, jump) then
			return false
		end
		for _, other in input.reserved do
			if LayoutLogic.overlaps(rect, other) then
				return false
			end
		end
		for _, other in placed do
			if LayoutLogic.overlaps(rect, other) then
				return false
			end
		end
		return true
	end
	-- The column fallback's next free top edge (above the jump button and earlier fallbacks).
	local columnTop = jump.y
	local result: { Rect } = {}
	for index, size in input.sizes do
		local best: Rect? = nil
		local bestDistance = math.huge
		local anchors: { Rect } = { jump }
		for _, rect in placed do
			table.insert(anchors, rect)
		end
		for _, anchor in anchors do
			for _, slot in SLOTS do
				local x, y = slot(anchor, size, input.gap)
				local rect = { x = math.floor(x + 0.5), y = math.floor(y + 0.5), w = size, h = size }
				if free(rect) then
					local dx = rect.x + size / 2 - jx
					local dy = rect.y + size / 2 - jy
					local distance = math.sqrt(dx * dx + dy * dy)
					-- Strictly closer wins, so equal distances keep the first (SLOTS order).
					if distance < bestDistance - 0.5 then
						best = rect
						bestDistance = distance
					end
				end
			end
		end
		if best == nil then
			local y = math.max(input.margin, columnTop - input.gap - size)
			local x = math.clamp(
				jump.x + jump.w - size,
				input.margin,
				math.max(input.margin, input.canvasX - input.margin - size)
			)
			local column = { x = x, y = y, w = size, h = size }
			-- Step above any cluster button already in the way (bounded: one step per button).
			for _ = 1, #placed do
				local blocker: Rect? = nil
				for _, other in placed do
					if LayoutLogic.overlaps(column, other) then
						blocker = other
					end
				end
				if blocker == nil then
					break
				end
				column.y = math.max(input.margin, blocker.y - input.gap - size)
			end
			best = column
			columnTop = column.y
		end
		local rect = best :: Rect
		placed[index] = rect
		result[index] = rect
	end
	return result
end

--[[
	Centres of `count` tiles on a circle of `radius`, starting at the top and going clockwise.
	@return offsets from the circle centre (x right, y down)
	Example: LayoutLogic.ring(4, 100) --> (0,-100) (100,0) (0,100) (-100,0)
]]
function LayoutLogic.ring(count: number, radius: number): { { x: number, y: number } }
	local result: { { x: number, y: number } } = {}
	local n = math.max(0, math.floor(count))
	for index = 1, n do
		local angle = -math.pi / 2 + (index - 1) * 2 * math.pi / n
		-- Round away float noise (cos(pi/2) is 6e-17, not 0).
		local x = math.floor(radius * math.cos(angle) * 1000 + 0.5) / 1000
		local y = math.floor(radius * math.sin(angle) * 1000 + 0.5) / 1000
		table.insert(result, { x = x, y = y })
	end
	return result
end

--[[
	The largest tile side that keeps `count` square tiles on a ring of `radius` at least `gap`
	apart, clamped to [minSide, maxSide].

	Why not the chord (QA 2026-10-30): tiles are axis-aligned SQUARES, so two of them clear each
	other only when their centres are side + gap apart on X or on Y (the Chebyshev distance), and
	for neighbours that sit diagonally (45°) that is the chord / √2. Sizing by the chord made the
	11-item menu wheel overlap at the top and sides. O(count²) over the ring points; count is a
	dozen HUD screens and this runs only when the wheel opens.
	Example: LayoutLogic.ringTile(10, 270, 14, 82, 150) --> 121
]]
function LayoutLogic.ringTile(count: number, radius: number, gap: number, minSide: number, maxSide: number): number
	if count <= 1 then
		return maxSide
	end
	local points = LayoutLogic.ring(count, radius)
	local closest = math.huge
	for i = 1, #points - 1 do
		local a = points[i]
		for j = i + 1, #points do
			local b = points[j]
			closest = math.min(closest, math.max(math.abs(a.x - b.x), math.abs(a.y - b.y)))
		end
	end
	return math.floor(math.clamp(closest - gap, minSide, maxSide))
end

return table.freeze(LayoutLogic)
