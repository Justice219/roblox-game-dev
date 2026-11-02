--!strict
--[[
	ViewCone regressions (src/shared/Util/ViewCone.luau). Run:
		lune run tests/view-cone

	Proves:
	  1. cosLimit(): the frustum's diagonal half-angle + margin (70° FOV, 16:9, +20° ≈ 75°), wider
	     for wider screens / bigger margins, and -1 ("everything visible") for junk input.
	  2. visible(): straight ahead yes, behind no, just inside / outside the cone edge, the `near`
	     radius always visible, and every corner of the real frustum is inside the cone (so a
	     piece on screen is never culled).
]]

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
local ViewCone = require("../src/shared/Util/ViewCone")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- 1. cosLimit
local c = ViewCone.cosLimit(70, 16 / 9, 20)
local halfDeg = math.deg(math.acos(c))
check(math.abs(halfDeg - 75.0) < 0.2, `70° / 16:9 / +20° -> ~75° half-angle (got {halfDeg})`)
check(ViewCone.cosLimit(70, 21 / 9, 20) < c, "wider screen -> wider cone")
check(ViewCone.cosLimit(70, 16 / 9, 30) < c, "bigger margin -> wider cone")
check(ViewCone.cosLimit(0 / 0, 1, 20) == -1, "NaN fov -> everything visible")
check(ViewCone.cosLimit(70, 0, 20) == -1, "zero aspect -> everything visible")
check(ViewCone.cosLimit(-5, 1, 20) == -1, "negative fov -> everything visible")
check(ViewCone.cosLimit(170, 4, 120) == -1, "cone past 180° -> everything visible")

-- 2. visible
local look = Vector3.new(0, 0, -1)
check(ViewCone.visible(Vector3.new(0, 0, -100), look, c, 10), "straight ahead")
check(not ViewCone.visible(Vector3.new(0, 0, 100), look, c, 10), "behind")
check(ViewCone.visible(Vector3.new(0, 0, 5), look, c, 10), "behind but within near")
local function at(angleDeg: number): Vector3
	local r = math.rad(angleDeg)
	return Vector3.new(math.sin(r), 0, -math.cos(r)) * 100
end
check(ViewCone.visible(at(halfDeg - 1), look, c, 10), "just inside the edge")
check(not ViewCone.visible(at(halfDeg + 1), look, c, 10), "just outside the edge")
check(ViewCone.visible(Vector3.new(1, 2, 3), look, -1, 0), "cosLimit -1 -> always visible")

-- Every frustum corner (any camera orientation) is inside the cone, with a hair of margin (0.01°,
-- float slack: a corner lies exactly ON the margin-free cone).
local tight = ViewCone.cosLimit(70, 16 / 9, 0.01)
local tanV = math.tan(math.rad(35))
local tanH = tanV * 16 / 9
for _, orientation in { CFrame.new(), CFrame.Angles(0.3, 1.2, -0.4), CFrame.Angles(-1.1, 2.9, 0.2) } do
	local camLook = orientation.LookVector
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			local corner = orientation:VectorToWorldSpace(Vector3.new(sx * tanH, sy * tanV, -1)) * 50
			check(ViewCone.visible(corner, camLook, tight, 0), "frustum corner inside the cone")
		end
	end
end

print(`[view-cone] {checks} checks passed`)
