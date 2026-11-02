--!strict
--[[
	ViewCone — cheap "could this point be on screen?" test for per-frame animation culling.

	Why: client animation loops (WorldFxController, ManagerController) move hundreds of anchored
	pieces with Workspace:BulkMoveTo every frame, and the engine cost is per moved part. A piece
	behind the camera does not need to move: skipping it saves the move and its render update,
	and nothing visible changes (its motion is time-based, so it resumes at the right phase the
	moment it re-enters the view).

	The cone is the camera frustum's DIAGONAL half-angle plus a margin, so it contains the whole
	frustum; the margin absorbs piece extents and camera turns between checks. Points within
	`near` studs always count as visible (big pieces right next to the camera).

	Pure math on Vector3 values (no Instance reads), so it is safe per frame and testable in Lune.

	Connects to: Client/Tycoon/Fx/WorldFxController, tests/view-cone.luau.

	Example:
		local cosLimit = ViewCone.cosLimit(camera.FieldOfView, viewport.X / viewport.Y, 20)
		if ViewCone.visible(part.Position - camPos, camera.CFrame.LookVector, cosLimit, 60) then ... end
]]

local ViewCone = {}

--[[
	Cosine of the cone half-angle that contains a camera frustum plus `marginDeg`.
	@param fovDeg vertical field of view in degrees (Camera.FieldOfView)
	@param aspect viewport width / height (> 0)
	@param marginDeg extra degrees around the frustum (piece extents + camera turn slack)
	@return cosine limit in [-1, 1]; -1 means "everything is visible" (degenerate input or a cone
		wider than a hemisphere's double)
	Example: ViewCone.cosLimit(70, 16 / 9, 20) --> ~0.26 (≈ 75° half-angle)
]]
function ViewCone.cosLimit(fovDeg: number, aspect: number, marginDeg: number): number
	if fovDeg ~= fovDeg or aspect ~= aspect or fovDeg <= 0 or aspect <= 0 or fovDeg >= 180 then
		return -1
	end
	local tanV = math.tan(math.rad(fovDeg) / 2)
	local tanH = tanV * aspect
	local half = math.atan(math.sqrt(tanV * tanV + tanH * tanH)) + math.rad(math.max(0, marginDeg))
	if half >= math.pi then
		return -1
	end
	return math.cos(half)
end

--[[
	True when a point at `offset` from the camera may be on screen (inside the cone or near).
	@param offset point - camera position
	@param look camera LookVector (unit)
	@param cosLimit from ViewCone.cosLimit
	@param near studs within which a point always counts as visible
	Example: ViewCone.visible(Vector3.new(0, 0, -50), Vector3.new(0, 0, -1), 0.5, 10) --> true
]]
function ViewCone.visible(offset: Vector3, look: Vector3, cosLimit: number, near: number): boolean
	local distance = offset.Magnitude
	if distance <= near or cosLimit <= -1 then
		return true
	end
	-- cos(angle) = offset·look / |offset|; compare without dividing.
	return offset:Dot(look) >= cosLimit * distance
end

return table.freeze(ViewCone)
