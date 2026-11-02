--!strict
--[[
	PointerLogic — where the HUD's objective arrow sits when it points at an on-screen BUTTON
	(owner R84: "it doesn't actually point to the GUI ... it kind of points towards the bench").
	Pure: numbers in, numbers out; no Instances. Unit-tested by tests/ftue-logic.luau.

	Why: the old arrow bounced a fixed 9 studs over the target MODEL, so on the tutorial's "press
	UPGRADE" step it hovered over the Workbench (or over the billboard's name) instead of the
	UPGRADE button the player had to press. Now Tycoon/Tutorial hands the HUD the button itself
	(a GuiObject on the producer billboard, or the on-screen TAP! / UPGRADE touch button) and
	this module picks a spot BESIDE it:
		- the arrow's tip stops `gap` px outside `avoid` (the button's whole board for billboard
		  buttons, so the arrow never covers the board's other text either; the button itself for
		  screen buttons) and points straight at the button's centre line, so it can never
		  overlap or hide the button;
		- the callout badge (the device glyph: X / E / a tap hand) sits behind the arrow's tail on
		  the same axis, reading "[X] -> UPGRADE";
		- sides are tried in the caller's preference order ("below" first for the UPGRADE pill at
		  the bottom of a billboard; "left" first for the make bar in the middle of one; "above"
		  first for touch buttons in the thumb corner); the first whose arrow + badge box stays
		  inside `bounds` and clear of every `blocked` rect (HUD columns, the objective chip,
		  other touch buttons) wins;
		- the previous frame's side is kept while it still fits (no flip-flop when the camera
		  moves a little); nothing fits: the first preference, clamped into `bounds`.
	The arrow bob moves AWAY from the button along the pointing axis, so `bob` px are reserved
	on the tail side of the box.

	Coordinates: design px on the HUD canvas, y down. Boxes are { x0, y0, x1, y1 } (x0 <= x1).

	Performance: HudObjective calls `place` every frame while it points at a button, so the hot
	path allocates nothing: candidate boxes are plain numbers, and `place(input, out)` writes into
	the caller's reused Placement (the caller also reuses its Input and Box tables).

	Connects to: UI/Hud/HudObjective (the only runtime caller), tests/ftue-logic.luau.

	Example:
		local placed = PointerLogic.place({
			target = { x0 = 900, y0 = 600, x1 = 1020, y1 = 650 },
			avoid = { x0 = 860, y0 = 420, x1 = 1060, y1 = 660 },
			arrow = 84, gap = 10, bob = 10, badgeW = 64, badgeH = 64,
			bounds = { x0 = 70, y0 = 70, x1 = 1850, y1 = 1010 },
			blocked = {}, order = { "below", "left", "right", "above" }, previous = nil,
		})
		--> placed.side == "below", placed.rotation == -180 (pointing up at the button)
]]

export type Box = { x0: number, y0: number, x1: number, y1: number }
export type Side = "below" | "above" | "left" | "right"

export type Input = {
	target: Box, -- the button's rect
	avoid: Box, -- the arrow + badge stay outside this rect (contains `target`)
	arrow: number, -- arrow glyph side
	gap: number, -- px between `avoid` and the arrow tip, and between the arrow and the badge
	bob: number, -- px the arrow bobs away from the button (reserved on the tail side)
	badgeW: number, -- callout badge size (0 x 0 = no badge)
	badgeH: number,
	bounds: Box, -- the play area the whole pointer must stay inside
	blocked: { Box }, -- rects to keep clear (HUD zones, other buttons)
	order: { Side }, -- preferred sides, best first
	previous: Side?, -- last frame's side (sticky while it fits)
}

export type Placement = {
	side: Side,
	x: number, -- arrow centre (no bob applied)
	y: number,
	rotation: number, -- arrow Rotation in degrees (the Arrow glyph points down at 0)
	dirX: number, -- unit vector the arrow points along (toward the button)
	dirY: number,
	badgeX: number, -- badge centre (no bob applied)
	badgeY: number,
	fits: boolean, -- false = nothing fitted; the first preference was clamped into bounds
}

local PointerLogic = {}

-- The default side order (UPGRADE-pill style: under the board first).
PointerLogic.DefaultOrder = table.freeze({ "below", "left", "right", "above" }) :: { Side }

--[[ True when two boxes overlap with a positive area (touching edges do not count). ]]
function PointerLogic.overlaps(a: Box, b: Box): boolean
	return a.x0 < b.x1 and b.x0 < a.x1 and a.y0 < b.y1 and b.y0 < a.y1
end

--[[
	The arrow Rotation (degrees) that makes the down-pointing Arrow glyph point along (dx, dy).
	Example: PointerLogic.rotationFor(0, -1) --> -180 (pointing up)
]]
function PointerLogic.rotationFor(dx: number, dy: number): number
	return math.deg(math.atan2(dy, dx)) - 90
end

--[[
	The unit direction the arrow points on `side` (toward the button; screen y grows down).
	@return (dx, dy)
]]
local function directionOf(side: Side): (number, number)
	if side == "below" then
		return 0, -1 -- under the button, pointing up
	elseif side == "above" then
		return 0, 1 -- over it, pointing down
	elseif side == "left" then
		return 1, 0 -- left of it, pointing right
	end
	return -1, 0 -- right of it, pointing left
end

-- True for the four known sides (untrusted `previous` / `order` entries are skipped).
local function isSide(side: any): boolean
	return side == "below" or side == "above" or side == "left" or side == "right"
end

--[[
	The arrow + badge centres for one side, and the box they cover (bob room included), as plain
	numbers (no allocation).
	@return (arrowX, arrowY, badgeX, badgeY, x0, y0, x1, y1)
]]
local function layout(input: Input, side: Side): (number, number, number, number, number, number, number, number)
	local target, avoid = input.target, input.avoid
	local half = input.arrow / 2
	local gap, bob = input.gap, input.bob
	local bw, bh = input.badgeW, input.badgeH
	local hasBadge = bw > 0 and bh > 0
	local cx, cy = (target.x0 + target.x1) / 2, (target.y0 + target.y1) / 2
	local ax, ay, bx, by = cx, cy, cx, cy
	if side == "below" then
		ay = avoid.y1 + gap + half
		by = ay + half + bob + gap + bh / 2
	elseif side == "above" then
		ay = avoid.y0 - gap - half
		by = ay - half - bob - gap - bh / 2
	elseif side == "left" then
		ax = avoid.x0 - gap - half
		bx = ax - half - bob - gap - bw / 2
	else -- right
		ax = avoid.x1 + gap + half
		bx = ax + half + bob + gap + bw / 2
	end
	-- The arrow's box, stretched by the bob on its tail side (away from the button).
	local dx, dy = directionOf(side)
	local x0, y0, x1, y1 = ax - half, ay - half, ax + half, ay + half
	if dx > 0 then
		x0 -= bob
	elseif dx < 0 then
		x1 += bob
	elseif dy > 0 then
		y0 -= bob
	else
		y1 += bob
	end
	if hasBadge then
		x0 = math.min(x0, bx - bw / 2)
		y0 = math.min(y0, by - bh / 2)
		x1 = math.max(x1, bx + bw / 2)
		y1 = math.max(y1, by + bh / 2)
	end
	return ax, ay, bx, by, x0, y0, x1, y1
end

-- True when the pointer box is fully inside the bounds and clear of every blocked rect.
local function fits(input: Input, x0: number, y0: number, x1: number, y1: number): boolean
	local bounds = input.bounds
	if x0 < bounds.x0 or y0 < bounds.y0 or x1 > bounds.x1 or y1 > bounds.y1 then
		return false
	end
	for _, rect in input.blocked do
		if x0 < rect.x1 and rect.x0 < x1 and y0 < rect.y1 and rect.y0 < y1 then
			return false
		end
	end
	return true
end

-- Writes a side's result into `out` (the caller's reused Placement).
local function write(out: Placement, side: Side, ax: number, ay: number, bx: number, by: number, ok: boolean): Placement
	local dx, dy = directionOf(side)
	out.side = side
	out.x, out.y = ax, ay
	out.rotation = PointerLogic.rotationFor(dx, dy)
	out.dirX, out.dirY = dx, dy
	out.badgeX, out.badgeY = bx, by
	out.fits = ok
	return out
end

--[[
	Picks the arrow + badge spot beside a button (see the module header).
	@param input Input
	@param out   optional Placement to fill (reused every frame by HudObjective); a new table
	             when nil
	@return the filled Placement (never nil)
]]
function PointerLogic.place(input: Input, out: Placement?): Placement
	local result: Placement = out
		or {
			side = "below",
			x = 0,
			y = 0,
			rotation = 0,
			dirX = 0,
			dirY = -1,
			badgeX = 0,
			badgeY = 0,
			fits = false,
		}
	local order = if #input.order > 0 then input.order else PointerLogic.DefaultOrder
	-- Sticky: keep last frame's side while it still fits.
	local previous = input.previous
	if previous ~= nil and isSide(previous) then
		local ax, ay, bx, by, x0, y0, x1, y1 = layout(input, previous)
		if fits(input, x0, y0, x1, y1) then
			return write(result, previous, ax, ay, bx, by, true)
		end
	end
	for _, side in order do
		if side ~= previous and isSide(side) then
			local ax, ay, bx, by, x0, y0, x1, y1 = layout(input, side)
			if fits(input, x0, y0, x1, y1) then
				return write(result, side, ax, ay, bx, by, true)
			end
		end
	end
	-- Nothing fits: the first preference, shifted (both axes) so its box lies inside the bounds
	-- as far as possible. It may then touch the board, but the arrow still points at the button.
	local side: Side = if isSide(order[1]) then order[1] else "below"
	local ax, ay, bx, by, x0, y0, x1, y1 = layout(input, side)
	local bounds = input.bounds
	local dx, dy = 0, 0
	if x0 < bounds.x0 then
		dx = bounds.x0 - x0
	elseif x1 > bounds.x1 then
		dx = bounds.x1 - x1
	end
	if y0 < bounds.y0 then
		dy = bounds.y0 - y0
	elseif y1 > bounds.y1 then
		dy = bounds.y1 - y1
	end
	return write(result, side, ax + dx, ay + dy, bx + dx, by + dy, false)
end

--[[
	The arrow's own box for a placement (bob not applied): what must never cover the button.
	Example: PointerLogic.overlaps(PointerLogic.arrowBox(placed, 84), target) --> false
]]
function PointerLogic.arrowBox(placed: Placement, arrow: number): Box
	local half = arrow / 2
	return { x0 = placed.x - half, y0 = placed.y - half, x1 = placed.x + half, y1 = placed.y + half }
end

return table.freeze(PointerLogic)
