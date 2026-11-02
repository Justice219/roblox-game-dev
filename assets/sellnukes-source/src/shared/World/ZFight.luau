--!strict
--[[
	ZFight — z-fighting (coplanar flicker) audit, ported from RoBeasts
	(src/server/Tests/GameMapsTests.luau `zFightPairs`, src/server/Maps/MapGeometry.luau) and
	extended for SellNukes' Blender MeshParts. Owner rule R18: "use the z-clipping thing that
	RoBeasts has to prevent z-clipping".

	Two passes, both pure (no instances created, no services):
		1. BOX pass — ZFight.box / ZFight.boxFromPart + ZFight.pairs(boxes): the RoBeasts audit.
		   Every box is an axis-aligned bounding box in a chosen frame (default: world). A box whose
		   rotation is not a multiple of 90° about the frame axes cannot be represented exactly and
		   is SKIPPED (reported by `box` as `nil, "rotated"`), exactly like RoBeasts. Two boxes
		   z-fight when a face of each lies on the same plane (within PLANE_EPS), both faces point
		   the same way, and their overlap is wider than OVERLAP_MIN on both in-plane axes.
		   Downward (-Y) faces are skipped: cameras never look up at the underside of a floor.
		   Use it live in Studio (World-QA tour): collect visible BaseParts -> boxFromPart -> pairs.
		   For MeshParts the box is the mesh's bounding box, so a non-box mesh (disc, ring, wedge)
		   can produce a pair whose real surfaces never touch; confirm those with pass 2.
		2. FACE pass — ZFight.facePairs(triangles): exact. Takes real mesh triangles already placed
		   in one frame (any rotation), groups them by plane (normal + offset), and measures the
		   actual overlap area of same-facing coplanar triangles that belong to DIFFERENT pieces.
		   tests/zfight-audit.luau feeds it every placed piece's triangles from the exported GLBs.

	How it connects:
		* tests/zfight-audit.luau — the static audit of the whole world as built in game (HubLayout,
		  plot frame, every AreaLayout fully built, BuyPads) using pass 2, plus pass 1 as a smoke test.
		* World-QA tour (B4, Studio): pass 1 over workspace parts. Layer rule: docs/areas-art.md
		  ("Z-fighting layer rule").
		* Fix pattern (RoBeasts MapGeometry): floors butt edge to edge, or sit on distinct layers
		  (plot ground y = 0, area floors +0.06, build floors +0.12, decals +0.18); never share a plane.

	Example (Studio):
		local ZFight = require(ReplicatedStorage.Shared.World.ZFight)
		local boxes = {}
		for _, part in workspace.Plots.Plot1:GetDescendants() do
			if part:IsA("BasePart") then
				local box = ZFight.boxFromPart(part)
				if box then table.insert(boxes, box) end
			end
		end
		for _, offender in ZFight.pairs(boxes) do warn(ZFight.describe(offender)) end
]]

local ZFight = {}

-- Faces closer than this on the same plane are coplanar (RoBeasts value).
ZFight.PLANE_EPS = 0.004
-- Box pass: overlap must exceed this on BOTH in-plane axes to count (touching edges never flicker).
ZFight.OVERLAP_MIN = 0.02
-- A box is axis-aligned when every local axis is within this of a frame axis.
ZFight.AXIS_EPS = 1e-4
-- Spatial hash cell (studs) for both passes.
ZFight.CELL = 16
-- Face pass: overlap area (studs²) below this is numeric dust, not a visible flicker.
ZFight.AREA_MIN = 0.05
-- Face pass: normals closer than this (1 - dot) are "the same facing".
ZFight.NORMAL_EPS = 1e-4

export type Box = {
	name: string,
	owner: string?,
	min: { number },
	max: { number },
}

export type Offender = {
	a: Box,
	b: Box,
	axis: string, -- "X" | "Y" | "Z"
	sign: string, -- "+" | "-"
	plane: number,
	overlapU: number,
	overlapV: number,
}

-- One triangle of a placed piece. `piece` identifies the placed piece (two triangles of the same
-- piece never count against each other: same colour + material = no visible flicker).
export type Triangle = {
	piece: number,
	x1: number,
	y1: number,
	z1: number,
	x2: number,
	y2: number,
	z2: number,
	x3: number,
	y3: number,
	z3: number,
}

export type FaceOffender = {
	a: number, -- piece id (smaller)
	b: number, -- piece id (larger)
	area: number, -- total overlapping area (studs²)
	normal: Vector3,
	offset: number, -- plane offset along the normal
}

export type PairOptions = { includeDown: boolean? }

local AXIS_NAMES = { "X", "Y", "Z" }

--[[
	Axis-aligned bounds of a block of `size` at `cf`, expressed in `frame` (default world).
	@return Box, or nil + "rotated" when the rotation is not a multiple of 90° about the frame axes
	Example: ZFight.box(CFrame.new(0, -0.5, 0), Vector3.new(16, 1, 16), "Floor")
]]
function ZFight.box(cf: CFrame, size: Vector3, name: string, owner: string?, frame: CFrame?): (Box?, string?)
	local relative = if frame ~= nil then frame:ToObjectSpace(cf) else cf
	local axes = { relative.RightVector, relative.UpVector, -relative.LookVector }
	local sizes = { size.X, size.Y, size.Z }
	local extent = { 0, 0, 0 }
	for index, axis in axes do
		local components = { math.abs(axis.X), math.abs(axis.Y), math.abs(axis.Z) }
		local found = false
		for frameAxis = 1, 3 do
			if math.abs(components[frameAxis] - 1) <= ZFight.AXIS_EPS then
				extent[frameAxis] = sizes[index] / 2
				found = true
			end
		end
		if not found then
			return nil, "rotated"
		end
	end
	local p = relative.Position
	return {
		name = name,
		owner = owner,
		min = { p.X - extent[1], p.Y - extent[2], p.Z - extent[3] },
		max = { p.X + extent[1], p.Y + extent[2], p.Z + extent[3] },
	},
		nil
end

--[[
	Studio helper: the audit box of a VISIBLE block-like part (Parts with Shape = Block, and
	MeshParts by their bounding box). Invisible helpers (Transparency >= 0.9), balls, cylinders and
	wedges return nil + a reason.
	@param part BasePart
	@param frame CFrame? — audit frame (e.g. a plot origin so 90° plot yaws stay exact)
]]
function ZFight.boxFromPart(part: BasePart, frame: CFrame?): (Box?, string?)
	if part.Transparency >= 0.9 then
		return nil, "invisible"
	end
	if part:IsA("Part") then
		if part.Shape ~= Enum.PartType.Block then
			return nil, "shape"
		end
	elseif not part:IsA("MeshPart") then
		return nil, "class"
	end
	local model = part:FindFirstAncestorOfClass("Model")
	local label = if model ~= nil then `{model.Name}.{part.Name}` else part.Name
	return ZFight.box(part.CFrame, part.Size, label, nil, frame)
end

-- Overlap length of [a0, a1] and [b0, b1] (0 when they only touch).
local function overlapLength(a0: number, a1: number, b0: number, b1: number): number
	return math.max(0, math.min(a1, b1) - math.max(a0, b0))
end

--[[
	Pass 1: pairs of boxes with coplanar, same-facing, overlapping faces. Spatial hash on the
	frame's XZ so it is ~linear in the box count. Upward, side and end faces are checked; downward
	(-Y) faces only with opts.includeDown.
	@return { Offender }
]]
function ZFight.pairs(boxes: { Box }, opts: PairOptions?): { Offender }
	local includeDown = opts ~= nil and opts.includeDown == true
	local cell = ZFight.CELL
	local cells: { [string]: { number } } = {}
	for index, box in boxes do
		for cx = math.floor(box.min[1] / cell), math.floor(box.max[1] / cell) do
			for cz = math.floor(box.min[3] / cell), math.floor(box.max[3] / cell) do
				local key = `{cx},{cz}`
				local bucket = cells[key]
				if bucket == nil then
					bucket = {}
					cells[key] = bucket
				end
				table.insert(bucket, index)
			end
		end
	end
	local found: { Offender } = {}
	local seen: { [number]: boolean } = {}
	local count = #boxes
	for _, bucket in cells do
		for i = 1, #bucket do
			for j = i + 1, #bucket do
				local ia, ib = bucket[i], bucket[j]
				local key = math.min(ia, ib) * (count + 1) + math.max(ia, ib)
				if seen[key] then
					continue
				end
				seen[key] = true
				local a, b = boxes[ia], boxes[ib]
				for axis = 1, 3 do
					local u = axis % 3 + 1
					local v = (axis + 1) % 3 + 1
					local overlapU = overlapLength(a.min[u], a.max[u], b.min[u], b.max[u])
					local overlapV = overlapLength(a.min[v], a.max[v], b.min[v], b.max[v])
					if overlapU <= ZFight.OVERLAP_MIN or overlapV <= ZFight.OVERLAP_MIN then
						continue
					end
					local sign: string? = nil
					local plane = 0
					if math.abs(a.max[axis] - b.max[axis]) <= ZFight.PLANE_EPS then
						sign, plane = "+", a.max[axis]
					elseif (axis ~= 2 or includeDown) and math.abs(a.min[axis] - b.min[axis]) <= ZFight.PLANE_EPS then
						sign, plane = "-", a.min[axis]
					end
					if sign ~= nil then
						table.insert(found, {
							a = a,
							b = b,
							axis = AXIS_NAMES[axis],
							sign = sign,
							plane = plane,
							overlapU = overlapU,
							overlapV = overlapV,
						})
						break
					end
				end
			end
		end
	end
	return found
end

--[[ One-line description of a box-pass offender: "A / B +Y @ 0.000 (12.0 x 4.0)". ]]
function ZFight.describe(o: Offender): string
	return string.format(
		"%s / %s %s%s @ %.3f (%.1f x %.1f)",
		o.a.name,
		o.b.name,
		o.sign,
		o.axis,
		o.plane,
		o.overlapU,
		o.overlapV
	)
end

-- ---- Face pass ----------------------------------------------------------------------------------

-- Signed area of a 2-D polygon given as flat {u1, v1, u2, v2, ...}.
local function signedArea(poly: { number }): number
	local area = 0
	local n = #poly // 2
	for i = 1, n do
		local j = i % n + 1
		area += poly[2 * i - 1] * poly[2 * j] - poly[2 * j - 1] * poly[2 * i]
	end
	return area / 2
end

--[[
	Area of the intersection of two 2-D triangles (flat {u1, v1, u2, v2, u3, v3}), by
	Sutherland-Hodgman clipping of `a` against the (counter-clockwise) edges of `b`.
]]
local function triangleOverlap(a: { number }, b: { number }): (number, number)
	local clip: { number } = b
	if signedArea(clip) < 0 then
		clip = { b[1], b[2], b[5], b[6], b[3], b[4] }
	end
	local output: { number } = a
	for e = 1, 3 do
		local ax, ay = clip[2 * e - 1], clip[2 * e]
		local f = e % 3 + 1
		local bx, by = clip[2 * f - 1], clip[2 * f]
		local input: { number } = output
		output = {}
		local n = #input // 2
		if n == 0 then
			break
		end
		local function inside(px: number, py: number): boolean
			return (bx - ax) * (py - ay) - (by - ay) * (px - ax) >= -1e-9
		end
		for i = 1, n do
			local px, py = input[2 * i - 1], input[2 * i]
			local j = i % n + 1
			local qx, qy = input[2 * j - 1], input[2 * j]
			local pIn, qIn = inside(px, py), inside(qx, qy)
			if pIn ~= qIn then
				-- Intersection of PQ with the clip edge line.
				local dx, dy = qx - px, qy - py
				local ex, ey = bx - ax, by - ay
				local denom = dx * ey - dy * ex
				if math.abs(denom) > 1e-12 then
					local t = ((ax - px) * ey - (ay - py) * ex) / denom
					table.insert(output, px + dx * t)
					table.insert(output, py + dy * t)
				end
			end
			if qIn then
				table.insert(output, qx)
				table.insert(output, qy)
			end
		end
	end
	if #output < 6 then
		return 0, 0
	end
	-- Longest axis extent of the overlap, so a sliver (area / extent < OVERLAP_MIN) can be ignored.
	local umin: number, umax: number, vmin: number, vmax: number = math.huge, -math.huge, math.huge, -math.huge
	for i = 1, #output, 2 do
		local u: number, v: number = output[i], output[i + 1]
		umin, umax = math.min(umin, u), math.max(umax, u)
		vmin, vmax = math.min(vmin, v), math.max(vmax, v)
	end
	return math.abs(signedArea(output)), math.max(umax - umin, vmax - vmin)
end

-- One triangle in its plane group's 2-D frame. `offset` = its own plane offset (studs), used by the
-- seam pass to tell a piece's internal quad diagonals from its outline edges.
type PlaneTri =
	{ piece: number, uv: { number }, offset: number, umin: number, umax: number, vmin: number, vmax: number }
type Group = { nx: number, ny: number, nz: number, bucket: number, offset: number, mode: number, tris: { PlaneTri } }

--[[
	Number -> integer key (thousandths by default, or `scale`) for plane / edge keys. -0 becomes 0: math.round(-0.0001 * 1000)
	is -0, which prints as "-0", so two triangles of ONE plane whose zero component has float noise
	of opposite sign would land in different groups and never be compared (found 2026-10-30).
]]
local function quantise(component: number, scale: number?): number
	local q = math.round(component * (scale or 1000))
	return if q == 0 then 0 else q
end

--[[
	Groups triangles by plane: key = quantised normal (1e-3) + offset bucket (2 * PLANE_EPS wide;
	callers also compare each group with the next bucket). Each group projects its triangles onto
	the two axes perpendicular to its dominant QUANTISED normal component, chosen once per group (a
	per-triangle choice flips on 45° planes and would compare triangles in different 2-D frames).
	Downward-facing triangles are dropped unless includeDown.
]]
local function groupByPlane(triangles: { Triangle }, includeDown: boolean): { [string]: Group }
	local eps = ZFight.PLANE_EPS
	local groups: { [string]: Group } = {}
	for _, t in triangles do
		local ux, uy, uz = t.x2 - t.x1, t.y2 - t.y1, t.z2 - t.z1
		local vx, vy, vz = t.x3 - t.x1, t.y3 - t.y1, t.z3 - t.z1
		local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
		local len = math.sqrt(nx * nx + ny * ny + nz * nz)
		if len < 1e-9 then
			continue -- degenerate
		end
		nx, ny, nz = nx / len, ny / len, nz / len
		if ny < -0.99 and not includeDown then
			continue
		end
		local offset = nx * t.x1 + ny * t.y1 + nz * t.z1
		local qx, qy, qz = quantise(nx), quantise(ny), quantise(nz)
		local bucket = math.floor(offset / (2 * eps))
		local key = `{qx},{qy},{qz},{bucket}`
		local group = groups[key]
		if group == nil then
			local ax, ay, az = math.abs(qx), math.abs(qy), math.abs(qz)
			local mode = if ay >= ax and ay >= az then 2 elseif ax >= az then 1 else 3
			group = { nx = qx, ny = qy, nz = qz, bucket = bucket, offset = offset, mode = mode, tris = {} }
			groups[key] = group
		end
		local uv: { number }
		if group.mode == 2 then
			uv = { t.x1, t.z1, t.x2, t.z2, t.x3, t.z3 }
		elseif group.mode == 1 then
			uv = { t.y1, t.z1, t.y2, t.z2, t.y3, t.z3 }
		else
			uv = { t.x1, t.y1, t.x2, t.y2, t.x3, t.y3 }
		end
		table.insert(group.tris, {
			piece = t.piece,
			uv = uv,
			offset = offset,
			umin = math.min(uv[1], uv[3], uv[5]),
			umax = math.max(uv[1], uv[3], uv[5]),
			vmin = math.min(uv[2], uv[4], uv[6]),
			vmax = math.max(uv[2], uv[4], uv[6]),
		})
	end
	return groups
end

--[[
	Calls visit(t, s) once for every pair of triangles of DIFFERENT pieces in the same plane (same
	group, or a group and the next offset bucket within PLANE_EPS) whose 2-D bounds, grown by
	`margin`, overlap. Spatial hash per group, so cost is ~linear in the triangle count.
]]
local function forEachNearPair(
	groups: { [string]: Group },
	margin: number,
	visit: (group: Group, t: PlaneTri, s: PlaneTri) -> ()
)
	local cell = ZFight.CELL
	local function compare(g: Group, h: Group?)
		local other = if h ~= nil then h else g
		local cells: { [string]: { PlaneTri } } = {}
		for _, t in other.tris do
			for cu = math.floor((t.umin - margin) / cell), math.floor((t.umax + margin) / cell) do
				for cv = math.floor((t.vmin - margin) / cell), math.floor((t.vmax + margin) / cell) do
					local key = `{cu},{cv}`
					local bucket = cells[key]
					if bucket == nil then
						bucket = {}
						cells[key] = bucket
					end
					table.insert(bucket, t)
				end
			end
		end
		for _, t in g.tris do
			local done: { [PlaneTri]: boolean } = {}
			for cu = math.floor((t.umin - margin) / cell), math.floor((t.umax + margin) / cell) do
				for cv = math.floor((t.vmin - margin) / cell), math.floor((t.vmax + margin) / cell) do
					for _, s in cells[`{cu},{cv}`] or {} do
						if done[s] or s.piece == t.piece then
							continue
						end
						done[s] = true
						if h == nil and s.piece < t.piece then
							continue -- each unordered pair once within a group
						end
						if
							s.umin >= t.umax + margin
							or s.umax <= t.umin - margin
							or s.vmin >= t.vmax + margin
							or s.vmax <= t.vmin - margin
						then
							continue
						end
						visit(g, t, s)
					end
				end
			end
		end
	end
	for _, group in groups do
		compare(group, nil)
		local neighbour = groups[`{group.nx},{group.ny},{group.nz},{group.bucket + 1}`]
		if neighbour ~= nil and math.abs(neighbour.offset - group.offset) <= ZFight.PLANE_EPS then
			compare(group, neighbour)
		end
	end
end

--[[
	Pass 2 (exact): same-facing coplanar triangles of DIFFERENT pieces whose real overlap area is
	at least AREA_MIN. Works for any rotation (planes are grouped by quantised normal + offset).
	Downward-facing triangles are skipped unless opts.includeDown.
	@param triangles { Triangle } — every placed piece's triangles in one frame
	@return { FaceOffender } — one entry per (piece pair, plane), area summed, largest first
]]
function ZFight.facePairs(triangles: { Triangle }, opts: PairOptions?): { FaceOffender }
	local includeDown = opts ~= nil and opts.includeDown == true
	local totals: { [string]: FaceOffender } = {}
	forEachNearPair(groupByPlane(triangles, includeDown), 0, function(g: Group, t: PlaneTri, s: PlaneTri)
		local area, extent = triangleOverlap(t.uv, s.uv)
		if area <= 1e-6 or extent <= 0 or area / extent < ZFight.OVERLAP_MIN then
			return -- nothing, or a float sliver along a shared edge
		end
		local a, b = math.min(t.piece, s.piece), math.max(t.piece, s.piece)
		local key = `{a}|{b}|{g.nx},{g.ny},{g.nz}`
		local entry = totals[key]
		if entry == nil then
			entry = {
				a = a,
				b = b,
				area = 0,
				normal = Vector3.new(g.nx / 1000, g.ny / 1000, g.nz / 1000),
				offset = g.offset,
			}
			totals[key] = entry
		end
		entry.area += area
	end)
	local result: { FaceOffender } = {}
	for _, entry in totals do
		if entry.area >= ZFight.AREA_MIN then
			table.insert(result, entry)
		end
	end
	table.sort(result, function(x: FaceOffender, y: FaceOffender): boolean
		return x.area > y.area
	end)
	return result
end

-- ---- LOD seam pass ------------------------------------------------------------------------------

-- LOD margin: parallel coplanar edges of two pieces closer than this (studs) count as one seam.
-- Roblox's LOD keeps fewer vertices on a curve, so its chords sag inward by up to ~1 stud on our
-- big arcs; a chamfer groove or gap narrower than this can close and the faces overlap at range
-- (the owner's ring-road screenshots: a 0.4-stud groove between flush curbs and asphalt).
ZFight.SEAM_GAP = 0.6
-- Minimum shared length of one edge pair (studs).
ZFight.SEAM_TOL = 0.02
-- Seams shorter than this in total (studs) are ignored.
ZFight.SEAM_MIN = 1.0
-- Seam directions closer than this (degrees) are the same direction (a straight seam).
ZFight.SEAM_SAME_DEG = 0.5
-- Two CONNECTED seam edges (sharing an end point) that turn by more than SEAM_SAME_DEG but less than
-- this mean the seam CURVES: an arc is a chain of short edges turning a little at each joint.
-- Rectangle / chamfer corners turn 45-90°, and separate straight seams (hazard-ring segments) are
-- not connected, so neither counts.
ZFight.SEAM_CURVE_DEG = 20
-- A seam CURVES only with at least this many joints. One joint can be two unrelated straight seams
-- that happen to end within SEAM_GAP of each other at a slight angle (a hazard ring's radial seam
-- next to a door band's edge); any real arc of three or more chords has two or more.
ZFight.SEAM_MIN_JOINTS = 2

export type SeamOffender = {
	a: number,
	b: number,
	length: number, -- total shared seam length (studs)
	joints: number, -- connected small-angle turns found along the seam
	normal: Vector3,
	offset: number,
}

--[[
	Collinear overlap of edge i of triangle p with edge j of triangle q (2-D): its length, direction
	in degrees [0, 180) and end points. Length 0 when they are not on one line within SEAM_TOL.
]]
local function sharedEdge(p: { number }, i: number, q: { number }, j: number): (number, number, { number })
	local p1x, p1y = p[2 * i - 1], p[2 * i]
	local i2 = i % 3 + 1
	local p2x, p2y = p[2 * i2 - 1], p[2 * i2]
	local q1x, q1y = q[2 * j - 1], q[2 * j]
	local j2 = j % 3 + 1
	local q2x, q2y = q[2 * j2 - 1], q[2 * j2]
	local dx, dy = p2x - p1x, p2y - p1y
	local len = math.sqrt(dx * dx + dy * dy)
	local tol = ZFight.SEAM_TOL
	local gap = ZFight.SEAM_GAP
	if len < tol then
		return 0, 0, {}
	end
	local ux, uy = dx / len, dy / len
	-- Parallel within ~1° and within the LOD margin of p's line.
	local qx, qy = q2x - q1x, q2y - q1y
	local qlen = math.sqrt(qx * qx + qy * qy)
	if qlen < tol or math.abs(ux * qy - uy * qx) / qlen > 0.02 then
		return 0, 0, {}
	end
	if math.abs((q1x - p1x) * uy - (q1y - p1y) * ux) > gap or math.abs((q2x - p1x) * uy - (q2y - p1y) * ux) > gap then
		return 0, 0, {}
	end
	local t1 = (q1x - p1x) * ux + (q1y - p1y) * uy
	local t2 = (q2x - p1x) * ux + (q2y - p1y) * uy
	local lo = math.max(math.min(t1, t2), 0)
	local hi = math.min(math.max(t1, t2), len)
	if hi - lo <= tol then
		return 0, 0, {}
	end
	return hi - lo, math.deg(math.atan2(uy, ux)) % 180, { p1x + ux * lo, p1y + uy * lo, p1x + ux * hi, p1y + uy * hi }
end

--[[
	Outline edges of every triangle in `groups`: outline[t][i] is true when edge i (corner i ->
	corner i % 3 + 1) of t is NOT shared with another triangle of the same piece in the same plane.
	A quad's diagonal is shared by its two triangles, so it is not an outline edge and can't fake a
	seam (narrow hazard stripes: two stripes' parallel diagonals 0.6 apart read as a curve).
	Edge identity: piece + quantised normal + plane offset (0.01) + both 2-D end points (0.001).
	@return { [PlaneTri]: { boolean } }
]]
local function outlineEdges(groups: { [string]: Group }): { [PlaneTri]: { boolean } }
	local function edgeKey(g: Group, t: PlaneTri, i: number): string
		local j = i % 3 + 1
		local a = `{quantise(t.uv[2 * i - 1])},{quantise(t.uv[2 * i])}`
		local b = `{quantise(t.uv[2 * j - 1])},{quantise(t.uv[2 * j])}`
		if a > b then
			a, b = b, a
		end
		return `{t.piece}|{g.nx},{g.ny},{g.nz}|{quantise(t.offset, 100)}|{a}|{b}`
	end
	local uses: { [string]: number } = {}
	for _, g in groups do
		for _, t in g.tris do
			for i = 1, 3 do
				local key = edgeKey(g, t, i)
				uses[key] = (uses[key] or 0) + 1
			end
		end
	end
	local outline: { [PlaneTri]: { boolean } } = {}
	for _, g in groups do
		for _, t in g.tris do
			outline[t] = { uses[edgeKey(g, t, 1)] == 1, uses[edgeKey(g, t, 2)] == 1, uses[edgeKey(g, t, 3)] == 1 }
		end
	end
	return outline
end

--[[
	LOD seam pass: pairs of DIFFERENT pieces whose same-facing coplanar faces BUTT (or come within
	SEAM_GAP) along a CURVED seam. Roblox simplifies each MeshPart's LOD on its own (RenderFidelity
	Automatic), so the two sides of a curved same-height seam become different chords that cross
	and flicker at distance (the owner's ring-road screenshots). Straight seams and seams with
	corners only (rectangles, chamfers) survive LOD and are not reported. Only UPWARD faces
	(floors, roads, roofs: normal y > 0.99) are checked: that is where a seam flicker reads;
	side-face seams around bevels don't.
	How: only OUTLINE edges count (outlineEdges: a quad's diagonal is not a seam); each piece pair
	is judged per plane (one height), every shared stretch once; a seam curves when it has at
	least SEAM_MIN_JOINTS small-angle joints.
	Fix: change one side's height (a curb, a dais) or make the seam straight.

	Example:
		for _, seam in ZFight.seamPairs(sceneTriangles) do
			print(seam.a, seam.b, seam.length, seam.joints) -- piece ids, studs, joint count
		end
	@param triangles { Triangle } — every placed piece's triangles in one frame
	@param opts PairOptions? — includeDown has no effect here (only upward faces are checked)
	@return { SeamOffender } — longest first
]]
function ZFight.seamPairs(triangles: { Triangle }, opts: PairOptions?): { SeamOffender }
	local includeDown = opts ~= nil and opts.includeDown == true
	type Segment = { angle: number, ends: { number } }
	type Acc = {
		a: number,
		b: number,
		length: number,
		segments: { Segment },
		seen: { [string]: boolean }, -- segment keys already counted (one edge pair can be visited twice)
		normal: Vector3,
		offset: number,
	}
	local acc: { [string]: Acc } = {}
	-- Only upward faces are checked (see above): drop every other plane before pairing.
	local groups: { [string]: Group } = {}
	for key, g in groupByPlane(triangles, includeDown) do
		if g.ny >= 990 then
			groups[key] = g
		end
	end
	local outline = outlineEdges(groups)
	forEachNearPair(groups, ZFight.SEAM_GAP, function(g: Group, t: PlaneTri, s: PlaneTri)
		local tEdges, sEdges = outline[t], outline[s]
		for i = 1, 3 do
			if not tEdges[i] then
				continue -- internal diagonal of t's own surface, not a seam
			end
			for j = 1, 3 do
				if not sEdges[j] then
					continue
				end
				local length, angle, ends = sharedEdge(t.uv, i, s.uv, j)
				if length > 0 then
					local a, b = math.min(t.piece, s.piece), math.max(t.piece, s.piece)
					-- One entry per piece pair AND plane: joints are judged in 2-D, so seams of the
					-- same pair at different heights (a ring top and a band top) must not mix.
					local key = `{a}|{b}|{g.nx},{g.ny},{g.nz}|{g.bucket}`
					local entry = acc[key]
					if entry == nil then
						entry = {
							a = a,
							b = b,
							length = 0,
							segments = {},
							seen = {},
							normal = Vector3.new(g.nx / 1000, g.ny / 1000, g.nz / 1000),
							offset = g.offset,
						}
						acc[key] = entry
					end
					-- Same shared stretch found again (e.g. through a neighbouring offset bucket): count once.
					local p1 = `{quantise(ends[1], 100)},{quantise(ends[2], 100)}`
					local p2 = `{quantise(ends[3], 100)},{quantise(ends[4], 100)}`
					local segmentKey = if p1 < p2 then `{p1}|{p2}` else `{p2}|{p1}`
					if not entry.seen[segmentKey] then
						entry.seen[segmentKey] = true
						entry.length += length
						table.insert(entry.segments, { angle = angle, ends = ends })
					end
				end
			end
		end
	end)
	local result: { SeamOffender } = {}
	for _, entry in acc do
		if entry.length < ZFight.SEAM_MIN then
			continue
		end
		-- Curved = seam edges that share end points and turn by a small (non-zero) angle, at
		-- SEAM_MIN_JOINTS or more joints.
		local joints = 0
		-- Seam pieces of one curve stop up to ~SEAM_GAP short of each other (the two sides' vertices
		-- don't line up), so joints connect within the same LOD margin.
		local near = ZFight.SEAM_GAP
		local segments = entry.segments
		for x = 1, #segments do
			for y = x + 1, #segments do
				local diff = math.abs(segments[x].angle - segments[y].angle) % 180
				diff = math.min(diff, 180 - diff)
				if diff <= ZFight.SEAM_SAME_DEG or diff >= ZFight.SEAM_CURVE_DEG then
					continue
				end
				local e, f = segments[x].ends, segments[y].ends
				local touching = false
				for m = 0, 1 do
					for n = 0, 1 do
						local du = e[2 * m + 1] - f[2 * n + 1]
						local dv = e[2 * m + 2] - f[2 * n + 2]
						if du * du + dv * dv <= near * near then
							touching = true
						end
					end
				end
				if touching then
					joints += 1
				end
			end
		end
		if joints >= ZFight.SEAM_MIN_JOINTS then
			table.insert(result, {
				a = entry.a,
				b = entry.b,
				length = entry.length,
				joints = joints,
				normal = entry.normal,
				offset = entry.offset,
			})
		end
	end
	table.sort(result, function(x: SeamOffender, y: SeamOffender): boolean
		return x.length > y.length
	end)
	return result
end

return table.freeze(ZFight)
