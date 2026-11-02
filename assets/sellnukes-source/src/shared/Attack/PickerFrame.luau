--!strict
--[[
	PickerFrame — where the attack target picker's camera sits and where the target's stream focus
	goes (owner R133: "when attacking people all I see is this, not their base still").

	Why it exists: the picker used to frame the WHOLE plot (all ten areas, owner R50) from ~890
	studs up (AttackGeometry.pickerView). Studio at high graphics draws that, but a live client on
	automatic graphics showed empty blue sky, before (R104) and after (R104 added a server stream
	focus). Two different streaming fixes left the symptom unchanged, so the distance itself is the
	problem. Also, a new player's only building (area 1, next to the hub) was a speck at the bottom of
	that view, and ~200 studs from the old stream focus point in the middle of the empty plot.

	The rules:
		* frame the target's BUILT areas: the union of their footprints (+ Pad), as close as fits
		  inside the band between the name plate and the button row (FitX / FitTop / FitBottom of
		  the half-FOV), between MinDistance and MaxDistance;
		* the camera looks away from the hub at Pitch degrees below the horizon (eye toward the hub,
		  like before), so the plot reads like a map with the road going up the screen;
		* when the built footprint does not fit even at MaxDistance (a big base), the camera stays
		  at MaxDistance and slides along the plot so the AIMED area is always fully in view, as far
		  toward the footprint's middle as that allows (cycling the aim pans the camera);
		* Rival islands keep their close island view (AttackGeometry.pickerView, ~214 studs);
		* the stream focus point is the middle of the built footprint (`streamPoint`), so a small
		  base sits well inside StreamingMinRadius of the server's replication focus.

	Projection matches Roblox's CFrame.lookAt(eye, focus) basis with the world up axis (forward,
	right = forward x up, up' = right x forward) and Camera:WorldToScreenPoint, the same maths as
	tests/attack-view.luau. No services, no Instances: lune-testable.

	Connects to: Shared/Attack/AttackGeometry (slots, plot frames, rival views), Shared/Config/
	{AttackConfig (Client.PickerFrame, Client.PickerFov), WorldLayout (slot rectangles)}; used by
	Client/UI/Screens/AttackTarget/AttackScreen (camera), Shared/Attack/PickerStream (focus point)
	and Server/Attack/PickerFocus.

	Example:
		local view = PickerFrame.view(3, { 1 }, 1, 16 / 9)   -- a new player's garage, close up
		camera.CFrame = CFrame.lookAt(view.eye, view.focus)
		local point = PickerFrame.streamPoint(3, { 1 })      -- the server's replication focus
]]

local AttackConfig = require(script.Parent.Parent.Config.AttackConfig)
local AttackGeometry = require(script.Parent.AttackGeometry)
local WorldLayout = require(script.Parent.Parent.Config.WorldLayout)

local PickerFrame = {}

local CFG = AttackConfig.Client.PickerFrame
local WORLD_UP = Vector3.new(0, 1, 0)

-- One framed view: the camera eye, the point it looks at, the eye-to-focus distance (studs) and
-- whether the built footprint was too big for MaxDistance (the view then follows the aimed area).
export type View = {
	eye: Vector3,
	focus: Vector3,
	distance: number,
	clamped: boolean,
}

-- A plot-local rectangle on the ground (studs).
type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }

--[[
	The built areas of a plot as the picker uses them: whole numbers in 1..AreaCount, unique,
	ascending; anything else (NaN, fractions, strings, out of range) is dropped.
	@param areas unknown — e.g. AttackClient.Target.areas or a decoded server attribute
	@return { number }
	Example: PickerFrame.builtAreas({ 3, 1, 3, 0 / 0, 99 }) --> { 1, 3 }
]]
function PickerFrame.builtAreas(areas: unknown): { number }
	local out: { number } = {}
	if type(areas) ~= "table" then
		return out
	end
	local seen: { [number]: boolean } = {}
	for _, value in areas :: { [any]: any } do
		if
			type(value) == "number"
			and value == value
			and value % 1 == 0
			and value >= 1
			and value <= WorldLayout.AreaCount
			and not seen[value]
		then
			seen[value] = true
			table.insert(out, value)
		end
	end
	table.sort(out)
	return out
end

--[[
	The plot-local ground rectangle of one area's slot (the road-side strip it is built on).
	@param area number — 1..AreaCount
	@return Rect
	Example: PickerFrame.footprint(1) --> { minX = 10, maxX = 80, minZ = ..., maxZ = ... }
]]
local function footprint(area: number): Rect
	-- Nuke Town's slot frame (attacks only target the main world); the explicit world id picks the
	-- two-argument overload (a bare `slotLocal(area)` call is ambiguous to the type checker).
	local slot = WorldLayout.slotLocal(area, "main")
	local rect = { minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge }
	for _, sx in { -WorldLayout.SlotHalfWidth, WorldLayout.SlotHalfWidth } do
		for _, sz in { 0, WorldLayout.SlotDepth } do
			local point = slot * Vector3.new(sx, 0, sz)
			rect.minX = math.min(rect.minX, point.X)
			rect.maxX = math.max(rect.maxX, point.X)
			rect.minZ = math.min(rect.minZ, point.Z)
			rect.maxZ = math.max(rect.maxZ, point.Z)
		end
	end
	return rect
end
PickerFrame.footprint = footprint

-- The areas a view frames: nil = the whole plot, else the sanitised list (empty -> area 1).
local function resolveBuilt(areas: { number }?): { number }
	if areas == nil then
		local all: { number } = {}
		for area = 1, WorldLayout.AreaCount do
			all[area] = area
		end
		return all
	end
	local built = PickerFrame.builtAreas(areas)
	return if #built == 0 then { 1 } else built
end

-- The union of the areas' footprints, grown by Pad and kept on the plot.
local function builtRect(built: { number }): Rect
	local rect = { minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge }
	for _, area in built do
		local one = footprint(area)
		rect.minX = math.min(rect.minX, one.minX)
		rect.maxX = math.max(rect.maxX, one.maxX)
		rect.minZ = math.min(rect.minZ, one.minZ)
		rect.maxZ = math.max(rect.maxZ, one.maxZ)
	end
	rect.minX = math.max(rect.minX - CFG.Pad, -WorldLayout.PlotHalfWidth)
	rect.maxX = math.min(rect.maxX + CFG.Pad, WorldLayout.PlotHalfWidth)
	rect.minZ = math.max(rect.minZ - CFG.Pad, 0)
	rect.maxZ = math.min(rect.maxZ + CFG.Pad, WorldLayout.PlotLength)
	return rect
end

-- The four world-space ground corners of a plot-local rectangle.
local function corners(origin: CFrame, rect: Rect): { Vector3 }
	return {
		origin * Vector3.new(rect.minX, 0, rect.minZ),
		origin * Vector3.new(rect.maxX, 0, rect.minZ),
		origin * Vector3.new(rect.minX, 0, rect.maxZ),
		origin * Vector3.new(rect.maxX, 0, rect.maxZ),
	}
end

--[[
	Normalised screen position of `point` for a camera at `eye` looking along `forward` (Roblox's
	lookAt basis with the world up axis): x in [-1, 1] left to right, y in [-1, 1] bottom to top
	at the edge of the FOV; `depth` <= 0 means behind the camera.
	@return (x, y, depth)
]]
function PickerFrame.project(
	eye: Vector3,
	forward: Vector3,
	point: Vector3,
	tanH: number,
	tanV: number
): (number, number, number)
	local right = forward:Cross(WORLD_UP).Unit
	local up = right:Cross(forward)
	local offset = point - eye
	local depth = offset:Dot(forward)
	if depth <= 0 then
		return 0, 0, depth
	end
	return offset:Dot(right) / depth / tanH, offset:Dot(up) / depth / tanV, depth
end

-- True when every point lies inside the fit window (FitX / FitTop / FitBottom) of the view.
local function fits(eye: Vector3, forward: Vector3, points: { Vector3 }, tanH: number, tanV: number): boolean
	for _, point in points do
		local x, y, depth = PickerFrame.project(eye, forward, point, tanH, tanV)
		if depth <= 0 or math.abs(x) > CFG.FitX or y > CFG.FitTop or y < CFG.FitBottom then
			return false
		end
	end
	return true
end

-- The viewport aspect the maths uses (junk -> Default, clamped to [Min, Max]).
local function aspectOf(aspect: number?): number
	local a = if type(aspect) == "number" and aspect == aspect then aspect else CFG.Aspect.Default
	return math.clamp(a, CFG.Aspect.Min, CFG.Aspect.Max)
end

--[[
	The picker camera for a target slot.
	@param slot number — a valid target slot (a plot or a Rival island)
	@param areas { number }? — the target's built areas (nil = the whole plot, e.g. my own empty
	       target list); junk entries are dropped, an empty list frames area 1
	@param aim number? — the aimed area (kept fully in view when the footprint is too big);
	       default / not built = the highest built area (the picker's default aim)
	@param aspect number? — viewport width / height (default CFG.Aspect.Default)
	@return View
	Example:
		local view = PickerFrame.view(5, target.areas, aimOf(target), size.X / size.Y)
]]
function PickerFrame.view(slot: number, areas: { number }?, aim: number?, aspect: number?): View
	local s = assert(AttackGeometry.validTarget(slot), "PickerFrame: bad slot")
	if AttackGeometry.rivalOfSlot(s) ~= nil then
		-- Rival islands are small: their close island view never had the problem.
		local eye, focus = AttackGeometry.pickerView(s)
		return { eye = eye, focus = focus, distance = (focus - eye).Magnitude, clamped = false }
	end

	local built = resolveBuilt(areas)
	local rect = builtRect(built)
	local origin = AttackGeometry.plotOrigin(s)
	local tanV = math.tan(math.rad(AttackConfig.Client.PickerFov) / 2)
	local tanH = tanV * aspectOf(aspect)
	local pitch = math.rad(CFG.Pitch)
	-- Plot-local +Z points away from the hub: look that way and down.
	local forward = origin:VectorToWorldSpace(Vector3.new(0, -math.sin(pitch), math.cos(pitch)))
	local function eyeFor(focus: Vector3, distance: number): Vector3
		return focus - forward * distance
	end

	-- 1. The whole built footprint, centred, as close as it fits.
	local centreLocal = Vector3.new((rect.minX + rect.maxX) / 2, 0, (rect.minZ + rect.maxZ) / 2)
	local centre = origin * centreLocal
	local box = corners(origin, rect)
	if fits(eyeFor(centre, CFG.MaxDistance), forward, box, tanH, tanV) then
		local distance = CFG.MaxDistance
		if fits(eyeFor(centre, CFG.MinDistance), forward, box, tanH, tanV) then
			distance = CFG.MinDistance
		else
			-- Smallest fitting distance in (Min, Max]: fitting is monotonic in the distance.
			local low, high = CFG.MinDistance, CFG.MaxDistance
			for _ = 1, CFG.Steps do
				local mid = (low + high) / 2
				if fits(eyeFor(centre, mid), forward, box, tanH, tanV) then
					high = mid
				else
					low = mid
				end
			end
			distance = high
		end
		return { eye = eyeFor(centre, distance), focus = centre, distance = distance, clamped = false }
	end

	-- 2. Too big for MaxDistance: keep the AIMED area fully in view, slid as far toward the middle
	--    of the footprint as that allows (no empty plot beyond the last building).
	local aimed = built[#built]
	if type(aim) == "number" and table.find(built, aim) ~= nil then
		aimed = aim
	end
	local aimRect = footprint(aimed)
	aimRect.minX -= CFG.Pad
	aimRect.maxX += CFG.Pad
	aimRect.minZ -= CFG.Pad
	aimRect.maxZ += CFG.Pad
	local aimBox = corners(origin, aimRect)
	-- The slide runs along the road (z) only; x stays on the footprint's middle so both sides of
	-- the road show.
	local fromLocal = Vector3.new(centreLocal.X, 0, (aimRect.minZ + aimRect.maxZ) / 2)
	local function focusAt(t: number): Vector3
		return origin * fromLocal:Lerp(centreLocal, t)
	end
	local best = 0
	if fits(eyeFor(focusAt(1), CFG.MaxDistance), forward, aimBox, tanH, tanV) then
		best = 1
	else
		local low, high = 0, 1
		for _ = 1, CFG.Steps do
			local mid = (low + high) / 2
			if fits(eyeFor(focusAt(mid), CFG.MaxDistance), forward, aimBox, tanH, tanV) then
				low = mid
			else
				high = mid
			end
		end
		best = low
	end
	local focus = focusAt(best)
	return { eye = eyeFor(focus, CFG.MaxDistance), focus = focus, distance = CFG.MaxDistance, clamped = true }
end

--[[
	World point the target's stream focus sits on: the middle of the built footprint at ground
	level (plots), the island view's look-at point (Rival islands). A new player's single area is
	then well inside StreamingMinRadius of the focus instead of ~200 studs from it.
	@param slot number — a valid target slot
	@param areas { number }? — the target's built areas (nil = the whole plot)
	@return Vector3
	Example: PickerFrame.streamPoint(2, { 1, 2 })
]]
function PickerFrame.streamPoint(slot: number, areas: { number }?): Vector3
	local s = assert(AttackGeometry.validTarget(slot), "PickerFrame: bad slot")
	if AttackGeometry.rivalOfSlot(s) ~= nil then
		local _, focus = AttackGeometry.pickerView(s)
		return focus
	end
	local built = resolveBuilt(areas)
	local rect = builtRect(built)
	return AttackGeometry.plotOrigin(s) * Vector3.new((rect.minX + rect.maxX) / 2, 0, (rect.minZ + rect.maxZ) / 2)
end

return PickerFrame
