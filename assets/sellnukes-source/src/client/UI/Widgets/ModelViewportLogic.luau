--!strict
--[[
	ModelViewportLogic — the numbers and the pure maths behind Widgets/ModelViewport (rotating, lit
	3D models in the UI, owner R39 "in the shop we should use real 3d models").

	Pure: no services, no instances, no requires. Unit-tested by tests/model-viewport.luau.

	What lives here:
		Config         tunables (camera, light, spin speed, live budget per FxQuality tier, pools,
		               template loading limits)
		sweptBounds    the turntable axis + swept radius / half height of the model's actual part
		               corners (much tighter than its bounding box for piles of copies, crowns,
		               coins: the empty corners of the box never get framed)
		fitSwept       how far the camera sits so the WHOLE model stays inside the frame at every
		               turntable angle (the parts swept around the vertical axis fill a cylinder;
		               the fit is exact for that cylinder, so nothing ever clips)
		fitDistance    fitSwept for a plain bounding-box size
		profile        the convex (radius, height) hull of the part corners around the turntable
		               axis: every corner's swept circle lies inside the solid this hull revolves
		fitProfile     the EXACT turntable fit of that hull (binary search between 0 and the
		               cylinder fit, checking each hull circle sampled around the axis): round /
		               tapered props (crowns, coins, potions, pets) fill the slot instead of half
		               of it, and still never clip at any angle
		orbit          the camera CFrame for a turntable angle (the camera orbits, the model never
		               moves: one property write per spinning viewport per step)
		lightDirection the key light fixed in CAMERA space, so the lit side never swings away while
		               the camera orbits (it reads as the model turning under a fixed studio light)
		copyOffsets    where 1..5 copies of a unit model stand ("x5 Lucky Spins" shows a little pile)
		maxLive        how many viewports may spin at once for a graphics tier
		copies         the sanitised copy count of a spec

	Example:
		local L = ModelViewportLogic
		local distance = L.fitDistance(Vector3.new(2, 3, 2), L.Config.FieldOfView, 1, L.Config.Pitch, 1)
		camera.CFrame = L.orbit(center, distance, L.Config.Pitch, L.Config.RestYaw)
		viewport.LightDirection = L.lightDirection(camera.CFrame)
]]

-- FxQuality tiers (Client/Tycoon/Fx/FxQuality): Low = still frames only.
export type Tier = "Low" | "Mid" | "High"

local ModelViewportLogic = {}

ModelViewportLogic.Config = table.freeze({
	-- Vertical field of view (degrees). Narrow = little perspective distortion on small icons.
	FieldOfView = 30,
	-- Camera elevation above the model centre (degrees): a slight look-down like a shop shelf.
	Pitch = 14,
	-- Resting turntable angle (degrees): a three-quarter view (still frames + start of a spin).
	RestYaw = 25,
	-- The fitted distance is multiplied by this: a hair of air at the model's widest angle.
	Padding = 1.02,
	-- The ViewportFrame is this much larger than its slot (centred, never clipped by it): the
	-- exact fit keeps the model inside the VIEWPORT at its widest turntable angle, so most of the
	-- time it fills ~85 % of the SLOT and only its widest corners pass into the slot's margin.
	Overflow = 1.2,
	-- Turntable speed (degrees per second): slow, calm, readable.
	SpinSpeed = 40,
	-- Spinning viewports allowed at once per FxQuality tier; the rest show a still frame.
	MaxLive = table.freeze({ Low = 0, Mid = 8, High = 12 }) :: { [Tier]: number },
	-- OfferFx step rates (steps / s per OfferFx graphics tier; Low parks motion).
	Hz = table.freeze({ Low = 0, Medium = 30, High = 60 }),
	-- Seconds between sweeps that free the spin slots of viewports that left the screen.
	PruneSeconds = 0.25,
	-- Soft studio lighting (ViewportFrame.Ambient / LightColor) and the key light in camera space
	-- (+X right, +Y up, -Z forward): from the upper left, slightly behind the camera.
	Ambient = Color3.fromRGB(176, 176, 192),
	LightColor = Color3.fromRGB(255, 248, 236),
	LightLocal = Vector3.new(0.45, -1, -0.6),
	-- Most copies of a unit model one viewport shows.
	MaxCopies = 5,
	-- Scale of the copy layouts (LAYOUTS below are in unit footprints; < 1 packs copies tighter).
	CopySpacing = 1,
	-- Pooled ViewportFrame rigs kept for reuse, and pooled built models per spec / in total.
	RigPool = 16,
	ModelPoolPerSpec = 2,
	ModelPoolTotal = 24,
	-- Template loading (AssetService:CreateMeshPartAsync): requests in flight for viewports on
	-- screen, and for background prefetch (never more than this, never ahead of a viewport).
	MaxInFlight = 8,
	MaxBackgroundInFlight = 3,
	-- Attempts per template, first retry delay (doubles), and the cool-down of a failed MeshId.
	MaxAttempts = 3,
	RetryBaseDelay = 0.5,
	RetryCooldown = 60,
	-- An aspect ratio change below this fraction does not re-frame the camera.
	AspectEpsilon = 0.02,
	-- fitProfile: points sampled around each hull circle (the radius is inflated by
	-- 1 / cos(pi / n) so the sampled polygon still encloses the true circle) and search steps
	-- (each halves the gap to the exact distance: 18 -> 1/262144 of the cylinder fit).
	ProfileSamples = 24,
	FitIterations = 18,
})

local Config = ModelViewportLogic.Config

--[[
	The turntable bounds of a cloud of points (every visible part's 8 box corners): a vertical
	axis through the XZ centre of their bounding box, the largest horizontal distance of any point
	from that axis (the radius the model sweeps while it turns) and the vertical centre / half
	height. Empty / nil-free input only (callers skip invisible parts).
	@param points world points (at least one)
	@return (center: Vector3, radius: number, halfHeight: number)
	Example: ModelViewportLogic.sweptBounds({ Vector3.new(1, 0, 0), Vector3.new(-1, 2, 0) })
		--> (0, 1, 0), 1, 1
]]
function ModelViewportLogic.sweptBounds(points: { Vector3 }): (Vector3, number, number)
	local minX: number, minY: number, minZ: number = math.huge, math.huge, math.huge
	local maxX: number, maxY: number, maxZ: number = -math.huge, -math.huge, -math.huge
	for _, point in points do
		minX = math.min(minX, point.X)
		maxX = math.max(maxX, point.X)
		minY = math.min(minY, point.Y)
		maxY = math.max(maxY, point.Y)
		minZ = math.min(minZ, point.Z)
		maxZ = math.max(maxZ, point.Z)
	end
	if minX > maxX then
		return Vector3.zero, 0, 0
	end
	local cx: number = (minX + maxX) / 2
	local cz: number = (minZ + maxZ) / 2
	local radiusSq = 0
	for _, point in points do
		local dx, dz = point.X - cx, point.Z - cz
		radiusSq = math.max(radiusSq, dx * dx + dz * dz)
	end
	return Vector3.new(cx, (minY + maxY) / 2, cz), math.sqrt(radiusSq), (maxY - minY) / 2
end

--[[
	Camera distance (studs, from the swept centre) at which a model that sweeps a vertical cylinder
	of `radius` and `halfHeight` while it turns fits the frame at EVERY turntable angle.

	Seen from `pitchDeg` above, that cylinder's camera-space half extents are
		right  r
		up     h·cos(p) + r·sin(p)
		depth  r·cos(p) + h·sin(p)
	A point fits when |lateral| / (distance − depth) ≤ tan(fov / 2) on both axes, so the distance is
	the larger lateral fit plus the half depth (conservative: pairs the widest point with the
	nearest depth). The horizontal half FOV follows the frame's aspect ratio (width / height).

	@param radius     swept radius (sweptBounds)
	@param halfHeight half the model height
	@param fovDeg     vertical field of view (degrees)
	@param aspect     frame width / height (> 0; 1 = square)
	@param pitchDeg   camera elevation (degrees)
	@param zoom       magnification (1 = fitted, 1.25 = 25 % closer; nil / <= 0 = 1)
	@return distance (studs, > 0)
	Example: ModelViewportLogic.fitSwept(math.sqrt(2), 1, 30, 1, 0, 1) --> about 7.0
]]
function ModelViewportLogic.fitSwept(
	radius: number,
	halfHeight: number,
	fovDeg: number,
	aspect: number,
	pitchDeg: number,
	zoom: number?
): number
	local r = if radius == radius then math.max(radius, 0) else 0
	local h = if halfHeight == halfHeight then math.max(halfHeight, 0) else 0
	local pitch = math.rad(pitchDeg)
	local sinP, cosP = math.sin(pitch), math.cos(pitch)
	local halfUp = h * cosP + r * sinP
	local halfDepth = r * cosP + h * sinP
	local tanV = math.tan(math.rad(math.clamp(fovDeg, 1, 120)) / 2)
	local safeAspect = if aspect == aspect and aspect > 0 then aspect else 1
	local tanH = tanV * safeAspect
	local fit = math.max(halfUp / tanV, r / tanH) + halfDepth
	local magnify = if zoom ~= nil and zoom == zoom and zoom > 0 then zoom else 1
	return math.max(fit * Config.Padding / magnify, 1e-3)
end

--[[
	fitSwept for a model of bounding-box `size` turning about the box's vertical centre line
	(radius = half the footprint diagonal, half height = size.Y / 2).
	Example: ModelViewportLogic.fitDistance(Vector3.new(2, 2, 2), 30, 1, 0, 1) --> about 7.0
]]
function ModelViewportLogic.fitDistance(
	size: Vector3,
	fovDeg: number,
	aspect: number,
	pitchDeg: number,
	zoom: number?
): number
	local radius = math.sqrt(size.X * size.X + size.Z * size.Z) / 2
	return ModelViewportLogic.fitSwept(radius, size.Y / 2, fovDeg, aspect, pitchDeg, zoom)
end

-- 2D cross product of (b - a) x (c - a) on { r, y } pairs (> 0: counter-clockwise turn).
local function cross(a: { number }, b: { number }, c: { number }): number
	return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
end

--[[
	The convex hull of a point cloud's turntable profile: each point becomes (r, y) = (distance
	from the vertical axis through `center`, height above `center`), the axis segment between
	the lowest and highest point is added, and the hull is returned (Andrew's monotone chain).
	Why it is enough to frame the hull: at any turntable angle the map (r, y) -> 3D point is
	linear, so every point's swept circle is a convex mix of the hull points' circles, and the
	region a camera sees is convex — if the hull circles are inside, every point is.
	@param points world points (part corners)
	@param center sweptBounds centre (the axis passes through its X / Z)
	@return { { r, y } } hull vertices (empty when `points` is empty)
	Example: #ModelViewportLogic.profile(corners, center) --> usually 4..12
]]
function ModelViewportLogic.profile(points: { Vector3 }, center: Vector3): { { number } }
	local profilePoints: { { number } } = {}
	local minY: number, maxY: number = math.huge, -math.huge
	for _, point in points do
		local dx, dz = point.X - center.X, point.Z - center.Z
		local y = point.Y - center.Y
		table.insert(profilePoints, { math.sqrt(dx * dx + dz * dz), y })
		minY = math.min(minY, y)
		maxY = math.max(maxY, y)
	end
	if #profilePoints == 0 then
		return {}
	end
	table.insert(profilePoints, { 0, minY })
	table.insert(profilePoints, { 0, maxY })
	table.sort(profilePoints, function(a: { number }, b: { number }): boolean
		return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
	end)
	local hull: { { number } } = {}
	-- Lower chain, then upper chain (the last point of each is the first of the other).
	for _, point in profilePoints do
		while #hull >= 2 and cross(hull[#hull - 1], hull[#hull], point) <= 0 do
			table.remove(hull)
		end
		table.insert(hull, point)
	end
	local lowerCount = #hull + 1
	for index = #profilePoints - 1, 1, -1 do
		local point = profilePoints[index]
		while #hull >= lowerCount and cross(hull[#hull - 1], hull[#hull], point) <= 0 do
			table.remove(hull)
		end
		table.insert(hull, point)
	end
	table.remove(hull) -- the closing point repeats the first
	return hull
end

--[[
	The camera distance at which every hull circle (ModelViewportLogic.profile) fits the frame —
	i.e. the whole model at EVERY turntable angle (the circles are the same at every angle, so
	one camera position is checked). Binary search between 0 and the cylinder fit (fitSwept,
	which always fits); each step projects every circle sample (radius inflated by
	1 / cos(pi / ProfileSamples) so the samples' polygon encloses the circle).
	@param hull     profile hull ({ r, y } around the centre)
	@param fovDeg   vertical field of view (degrees)
	@param aspect   frame width / height
	@param pitchDeg camera elevation (degrees)
	@param zoom     magnification (1 = fitted; nil / <= 0 = 1)
	@return distance (studs, > 0; padded by Config.Padding like fitSwept)
	Example: ModelViewportLogic.fitProfile(ModelViewportLogic.profile(corners, c), 30, 1, 14, 1)
]]
function ModelViewportLogic.fitProfile(
	hull: { { number } },
	fovDeg: number,
	aspect: number,
	pitchDeg: number,
	zoom: number?
): number
	local radius: number, halfHeight: number = 0, 0
	for _, point in hull do
		radius = math.max(radius, point[1])
		halfHeight = math.max(halfHeight, math.abs(point[2]))
	end
	local magnify = if zoom ~= nil and zoom == zoom and zoom > 0 then zoom else 1
	-- The cylinder fit without padding / zoom: always fits, the search's upper bound.
	local hi = ModelViewportLogic.fitSwept(radius, halfHeight, fovDeg, aspect, pitchDeg, 1) / Config.Padding
	if #hull == 0 or radius <= 0 then
		return math.max(hi * Config.Padding / magnify, 1e-3)
	end
	local pitch = math.rad(pitchDeg)
	local sinP, cosP = math.sin(pitch), math.cos(pitch)
	local tanV = math.tan(math.rad(math.clamp(fovDeg, 1, 120)) / 2)
	local safeAspect = if aspect == aspect and aspect > 0 then aspect else 1
	local tanH = tanV * safeAspect
	local samples = Config.ProfileSamples
	local inflate = 1 / math.cos(math.pi / samples)
	-- True when every sampled hull circle projects inside the frame from distance `d` (camera at
	-- (0, d·sin p, -d·cos p) looking at the centre; forward (0, -sin p, cos p), up (0, cos p, sin p)).
	local function fits(d: number): boolean
		local camY, camZ = d * sinP, -d * cosP
		for _, point in hull do
			local r, y = point[1] * inflate, point[2]
			local vy = y - camY
			for k = 0, samples - 1 do
				local angle = 2 * math.pi * k / samples
				local px, pz = r * math.cos(angle), r * math.sin(angle)
				local vz = pz - camZ
				local depth = -vy * sinP + vz * cosP
				if depth <= 1e-6 then
					return false
				end
				if math.abs(px) > tanH * depth or math.abs(vy * cosP + vz * sinP) > tanV * depth then
					return false
				end
			end
		end
		return true
	end
	local lo = 0
	for _ = 1, Config.FitIterations do
		local mid = (lo + hi) / 2
		if fits(mid) then
			hi = mid
		else
			lo = mid
		end
	end
	return math.max(hi * Config.Padding / magnify, 1e-3)
end

--[[
	The camera CFrame that shows a model turned `yawDeg` on a turntable: the camera orbits the
	centre instead (models face -Z, so yaw 0 looks at the model's front from -Z).
	Turning the model by +yaw is the camera at R_y(-yaw): offset (sin y · cos p, sin p, -cos y · cos p).
	Built from rotations (no CFrame.lookAt): turn to face +Z (π) minus the yaw, tilt down by the
	pitch, then step back `distance` along the camera's own +Z — always looks at `center`, with
	no degenerate up vector at steep pitches.
	@param center   model bounding-box centre
	@param distance camera distance (fitDistance)
	@param pitchDeg camera elevation (degrees)
	@param yawDeg   turntable angle (degrees)
	@return camera CFrame looking at `center`
	Example: ModelViewportLogic.orbit(Vector3.zero, 10, 0, 0).Position --> (0, 0, -10)
]]
function ModelViewportLogic.orbit(center: Vector3, distance: number, pitchDeg: number, yawDeg: number): CFrame
	return CFrame.new(center)
		* CFrame.Angles(0, math.pi - math.rad(yawDeg), 0)
		* CFrame.Angles(-math.rad(pitchDeg), 0, 0)
		* CFrame.new(0, 0, distance)
end

--[[
	The ViewportFrame.LightDirection (world space) of the key light held fixed relative to the
	camera (Config.LightLocal), so every turntable angle is lit from the same screen direction.
	@param cameraCf the viewport camera CFrame
	@return unit Vector3
	Example: viewport.LightDirection = ModelViewportLogic.lightDirection(camera.CFrame)
]]
function ModelViewportLogic.lightDirection(cameraCf: CFrame): Vector3
	return cameraCf:VectorToWorldSpace(Config.LightLocal).Unit
end

--[[
	A copy count from an untrusted / optional value: a whole number in 1..Config.MaxCopies.
	Example: ModelViewportLogic.copies(9) --> 5 ; ModelViewportLogic.copies(nil) --> 1
]]
function ModelViewportLogic.copies(value: number?): number
	if value == nil or value ~= value then
		return 1
	end
	return math.clamp(math.floor(value), 1, Config.MaxCopies)
end

-- Copy layouts: { x, z, yaw } with x / z in footprints (scaled by CopySpacing) and yaw in degrees.
-- Front is -Z (the camera side): the centre copies stand in front, the outer ones fan out behind.
local LAYOUTS: { { { number } } } = {
	{ { 0, 0, 0 } },
	{ { -0.55, 0.12, 14 }, { 0.55, -0.12, -14 } },
	{ { -0.75, 0.25, 18 }, { 0.75, 0.25, -18 }, { 0, -0.3, 0 } },
	{ { -0.85, 0.35, 18 }, { 0.85, 0.35, -18 }, { -0.35, -0.35, 8 }, { 0.35, -0.35, -8 } },
	{ { -1.1, 0.4, 22 }, { 0, 0.5, 0 }, { 1.1, 0.4, -22 }, { -0.55, -0.35, 10 }, { 0.55, -0.35, -10 } },
}

--[[
	Where each of `count` copies of a unit model stands (relative to the group pivot), scaled by
	the unit's footprint so any prop size reads as a tidy little pile. Symmetric about X = 0.
	@param count    copies (sanitised with ModelViewportLogic.copies)
	@param unitSize the unit model's bounding size
	@return { CFrame } one per copy
	Example: #ModelViewportLogic.copyOffsets(3, Vector3.new(2, 3, 1)) --> 3
]]
function ModelViewportLogic.copyOffsets(count: number, unitSize: Vector3): { CFrame }
	local layout = LAYOUTS[ModelViewportLogic.copies(count)]
	local footprint = math.max(unitSize.X, unitSize.Z, 0.1) * Config.CopySpacing
	local result: { CFrame } = {}
	for index, slot in layout do
		result[index] = CFrame.new(slot[1] * footprint, 0, slot[2] * footprint) * CFrame.Angles(0, math.rad(slot[3]), 0)
	end
	return result
end

--[[
	How many viewports may spin at once.
	@param tier    FxQuality tier ("Low" | "Mid" | "High"; unknown = "Mid")
	@param reduced Reduce Motion is on (Roblox or SellNukes setting): nothing spins
	@return count (0 = still frames only)
	Example: ModelViewportLogic.maxLive("High", false) --> 12
]]
function ModelViewportLogic.maxLive(tier: string, reduced: boolean): number
	if reduced then
		return 0
	end
	local budget = (Config.MaxLive :: { [string]: number })[tier]
	return if budget ~= nil then budget else Config.MaxLive.Mid
end

return table.freeze(ModelViewportLogic)
