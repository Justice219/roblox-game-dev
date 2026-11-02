--!strict
--[[
	PickerLayout — pure layout maths of the attack target picker (owner R118: "all of these clip" —
	the aim buttons BIG MACHINE / WAREHOUSE / WORKSHOP / TOY SHOP sat on top of each other in one
	row, each covering the next one's label).

	Root cause: on short canvases (phones) the top block (name plate + info lines, 244 px) and the
	bottom row (190 px + margin) left NO band between them, and every projected marker was clamped
	into that empty band — one overlapping line. Rival sections (26 studs apart) also project closer
	than a chip is wide.

	Rules (tunables AttackConfig.Client.PickerLayout):
		1. `blocks`: the top block and the bottom row scale down to TopShare / BottomShare of the
		   canvas height (and the canvas width), never below the scale that keeps their buttons
		   >= MinTapPoints; chips are >= MinTapPoints tall. The band between them is what is left.
		2. `markers`, pinned mode: chips are placed in order (top to bottom, then left to right) at
		   their area's projected point (plots: on the side away from the road), else the cheapest
		   free spot — whole chip rows up / down (<= MaxShiftRows), then sideways (<= MaxShiftX of
		   the width) — inside the band and the canvas margins, never overlapping a placed chip
		   (+ Gap). A chip moved more than LeaderMin from its spot gets a leader line.
		3. If ANY chip has no free spot (or the band is shorter than a chip), strip mode: all chips in
		   one row just above the bottom row, ordered by their area's x (so leader lines do not
		   cross), centred; wider than the canvas → it scrolls (no leader lines then).
	Guarantee (tests/attack-view.luau, randomised anchors / counts / canvases): no two chips
	overlap, every chip is inside the canvas (strip: inside its scroll canvas) and inside the band
	when pinned. No services, no Instances.

	Connects to: Shared/Config/AttackConfig (Client.PickerLayout); used by
	Screens/AttackTarget/AttackScreen.

	Example:
		local blocks = PickerLayout.blocks(Vector2.new(1361, 629), 110, 0.62, 244, 250, 1286, 60)
		local layout = PickerLayout.markers(anchors, sides, blocks.bandTop, blocks.bandBottom,
			1361, blocks.chip)
		-- layout.mode, layout.centres[i], layout.leader[i]
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)

local PickerLayout = {}

local CFG = AttackConfig.Client.PickerLayout
-- Chip label text size (design px at the base chip height), the stud font's widest average
-- character (share of the text size) and the label's side padding (px).
local CHIP_TEXT = 24
local CHAR_WIDTH = 0.62
local CHIP_PAD = 44
PickerLayout.CHIP_TEXT = CHIP_TEXT

export type Blocks = {
	topScale: number,
	bottomScale: number,
	chip: Vector2, -- chip size (design px)
	bandTop: number, -- the clear band between the blocks (design px, canvas space)
	bandBottom: number,
}

export type Layout = {
	mode: "pinned" | "strip",
	centres: { Vector2 }, -- chip centres (pinned / fitting strip: canvas px; scrolling strip: strip px)
	spots: { Vector2 }, -- where each chip wanted to be (its area, clamped into the band)
	leader: { boolean }, -- draw a leader line from the chip to its area's dot
	scroll: boolean, -- strip wider than the canvas: the row scrolls
	stripY: number, -- strip row centre (canvas px)
	stripWidth: number, -- strip content width (px)
	order: { number }, -- chip indices in navigation order (left to right / top to bottom)
}

-- A finite number, else `fallback`.
local function finite(value: unknown, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

--[[
	Block scales, chip size and the clear band for a canvas.
	@param canvas Vector2 — design px
	@param safeTop number — design px y where the top block starts (below the Roblox top bar)
	@param pointScale number — points per design px (ScreenManager.pointScale)
	@param topHeight number — the top block's design height at scale 1
	@param bottomHeight number — the bottom row's design height at scale 1
	@param bottomWidth number — the bottom row's design width at scale 1
	@param bottomMargin number — px under the bottom row
	@param topWidth number? — the top block's design width (default 1120)
	@param tapTop number? — tallest tap control in the top block (default 112: the < > buttons)
	@param tapBottom number? — tallest tap control in the bottom row (default 116)
	@return Blocks
]]
function PickerLayout.blocks(
	canvas: Vector2,
	safeTop: number,
	pointScale: number,
	topHeight: number,
	bottomHeight: number,
	bottomWidth: number,
	bottomMargin: number,
	topWidth: number?,
	tapTop: number?,
	tapBottom: number?
): Blocks
	local scale = math.max(finite(pointScale, 1), 0.05)
	local width = math.max(finite(canvas.X, 1920), 1)
	local height = math.max(finite(canvas.Y, 1080), 1)
	local minTap = CFG.MinTapPoints / scale -- design px a control needs for MinTapPoints
	local function fit(share: number, size: number, wide: number, tap: number): number
		local byHeight = share * height / math.max(size, 1)
		local byWidth = (width - 2 * CFG.Margin) / math.max(wide, 1)
		local floor = math.min(minTap / math.max(tap, 1), 1)
		return math.clamp(math.min(byHeight, byWidth, 1), floor, 1)
	end
	local topScale = fit(CFG.TopShare, topHeight, topWidth or 1120, tapTop or 112)
	local bottomScale = fit(CFG.BottomShare, bottomHeight, bottomWidth, tapBottom or 116)
	local chipHeight = math.max(CFG.Chip.Y, minTap)
	local chip = Vector2.new(CFG.Chip.X * chipHeight / CFG.Chip.Y, chipHeight)
	return {
		topScale = topScale,
		bottomScale = bottomScale,
		chip = chip,
		bandTop = finite(safeTop, 0) + topHeight * topScale + CFG.BandPad,
		bandBottom = height - finite(bottomMargin, 0) - bottomHeight * bottomScale - CFG.BandPad,
	}
end

--[[
	The chip size for a set of labels: `chipHeight` tall (Blocks.chip.Y, >= MinTapPoints) and wide
	enough for the longest label at the chip's text size (a conservative per-character width for the
	stud font + padding; StudUI also shrinks a label that would still overflow), at most MaxChipWidth.
	@param labels { string }
	@param chipHeight number
	@return Vector2
]]
function PickerLayout.chipFor(labels: { string }, chipHeight: number): Vector2
	local height = math.max(finite(chipHeight, CFG.Chip.Y), 1)
	local textScale = height / CFG.Chip.Y
	local longest = 0
	for _, label in labels do
		if type(label) == "string" then
			longest = math.max(longest, utf8.len(label) or #label)
		end
	end
	local width = math.max(CFG.Chip.X * textScale, longest * CHIP_TEXT * CHAR_WIDTH * textScale + CHIP_PAD)
	return Vector2.new(math.min(width, CFG.MaxChipWidth * textScale), height)
end

-- True when two centred rects of `size` (+ gap) overlap.
local function overlap(a: Vector2, b: Vector2, size: Vector2, gap: number): boolean
	return math.abs(a.X - b.X) < size.X + gap and math.abs(a.Y - b.Y) < size.Y + gap
end
PickerLayout.overlap = overlap

-- Candidate offsets (in chip units), cheapest first: rows up / down, then sideways, then both.
local candidates: { Vector2 } = {}
do
	local list: { { offset: Vector2, cost: number } } = {}
	local xs = { 0, -0.5, 0.5, -1, 1 }
	for row = -CFG.MaxShiftRows, CFG.MaxShiftRows do
		for _, x in xs do
			local dx = x * CFG.MaxShiftX
			table.insert(list, { offset = Vector2.new(dx, row), cost = math.abs(row) + math.abs(dx) * 1.5 })
		end
	end
	table.sort(list, function(a: { offset: Vector2, cost: number }, b: { offset: Vector2, cost: number }): boolean
		if a.cost ~= b.cost then
			return a.cost < b.cost
		end
		-- Ties: up before down, left before right (deterministic).
		if a.offset.Y ~= b.offset.Y then
			return a.offset.Y < b.offset.Y
		end
		return a.offset.X < b.offset.X
	end)
	for _, entry in list do
		table.insert(candidates, entry.offset)
	end
end

--[[
	Lays out the aim chips.
	@param anchors { Vector2 } — each area's projected point (canvas design px; junk → canvas centre)
	@param sides { number }? — per chip: -1 = the chip sits LEFT of its point, 1 = right, 0 / nil =
	       centred (plots put a row's two areas either side of the road; Rival sections centred)
	@param bandTop number, bandBottom number — the clear band (Blocks)
	@param canvasX number — canvas width (design px)
	@param chip Vector2 — chip size (Blocks.chip)
	@return Layout
]]
function PickerLayout.markers(
	anchors: { Vector2 },
	sides: { number }?,
	bandTop: number,
	bandBottom: number,
	canvasX: number,
	chip: Vector2
): Layout
	local count = #anchors
	local width = math.max(finite(canvasX, 1920), chip.X + 2 * CFG.Margin)
	local gap = CFG.Gap
	local half = chip / 2
	local minX, maxX = CFG.Margin + half.X, width - CFG.Margin - half.X
	local minY, maxY = finite(bandTop, 0) + half.Y, finite(bandBottom, 0) - half.Y
	-- Each chip's preferred spot: its point (clamped into the band and the canvas), shifted to its side.
	local spots: { Vector2 } = {}
	for index = 1, count do
		local raw = anchors[index]
		local x = finite(if typeof(raw) == "Vector2" then raw.X else nil, width / 2)
		local y = finite(if typeof(raw) == "Vector2" then raw.Y else nil, (minY + maxY) / 2)
		local side = if sides ~= nil then finite(sides[index], 0) else 0
		side = if side > 0 then 1 elseif side < 0 then -1 else 0
		x += side * (half.X + 4)
		spots[index] = Vector2.new(math.clamp(x, minX, math.max(maxX, minX)), math.clamp(y, minY, math.max(maxY, minY)))
	end
	local leader: { boolean } = table.create(count, false)
	-- Pinned: cheapest free spot per chip, top to bottom then left to right.
	local order: { number } = {}
	for index = 1, count do
		order[index] = index
	end
	table.sort(order, function(a: number, b: number): boolean
		local pa, pb = spots[a], spots[b]
		if math.abs(pa.Y - pb.Y) > 1e-6 then
			return pa.Y < pb.Y
		end
		if math.abs(pa.X - pb.X) > 1e-6 then
			return pa.X < pb.X
		end
		return a < b
	end)
	local centres: { Vector2 } = table.create(count, Vector2.zero)
	local pinned = maxY >= minY and maxX >= minX
	if pinned then
		local placed: { Vector2 } = {}
		for _, index in order do
			local spot = spots[index]
			local found: Vector2? = nil
			for _, offset in candidates do
				local at = spot + Vector2.new(offset.X * chip.X, offset.Y * (chip.Y + gap))
				if at.X >= minX - 1e-6 and at.X <= maxX + 1e-6 and at.Y >= minY - 1e-6 and at.Y <= maxY + 1e-6 then
					local free = true
					for _, other in placed do
						if overlap(at, other, chip, gap) then
							free = false
							break
						end
					end
					if free then
						found = at
						break
					end
				end
			end
			if found == nil then
				pinned = false
				break
			end
			centres[index] = found
			leader[index] = (found - spot).Magnitude > CFG.LeaderMin
			table.insert(placed, found)
		end
	end
	if pinned then
		return {
			mode = "pinned",
			centres = centres,
			spots = spots,
			leader = leader,
			scroll = false,
			stripY = 0,
			stripWidth = 0,
			order = order,
		}
	end
	-- Strip: one row above the bottom row, ordered by the areas' x (leader lines never cross).
	local byX: { number } = {}
	for index = 1, count do
		byX[index] = index
	end
	table.sort(byX, function(a: number, b: number): boolean
		local pa, pb = spots[a], spots[b]
		if math.abs(pa.X - pb.X) > 1e-6 then
			return pa.X < pb.X
		end
		return a < b
	end)
	local total = count * chip.X + math.max(count - 1, 0) * gap
	local available = width - 2 * CFG.Margin
	local scroll = total > available + 1e-6
	local stripY = math.max(finite(bandBottom, 0) - half.Y, finite(bandTop, 0) + half.Y)
	local start = if scroll then half.X else width / 2 - total / 2 + half.X
	for slot, index in byX do
		centres[index] = Vector2.new(start + (slot - 1) * (chip.X + gap), if scroll then half.Y else stripY)
		leader[index] = not scroll
	end
	return {
		mode = "strip",
		centres = centres,
		spots = spots,
		leader = leader,
		scroll = scroll,
		stripY = stripY,
		stripWidth = total,
		order = byX,
	}
end

return PickerLayout
