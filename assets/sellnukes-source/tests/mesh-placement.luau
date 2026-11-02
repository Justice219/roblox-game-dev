--!strict
--[[
	MeshPlacement regressions (owner R17 / R25 / R26: pieces spun 180° by the FBX import). Run:
		lune run tests/mesh-placement

	Proves on the shipped src/shared/World/MeshPlacement.luau:
	  1. ImportYaw is exactly 180° about +Y: local (x, y, z) -> (-x, y, -z), which is what decoding
	     an uploaded model shows (Workbench: Cabinet offset x -3.05 imported at +3.05, Drawers
	     z -1.86 at +1.86; x100 import scale).
	  2. pieceCFrame(mesh) keeps the authored position but faces the authored front again;
	     pieceCFrame(fallback) is untouched; MeshLibrary uses pieceCFrame with MeshYaw (source check).
	  3. face(): yawed pieces swap Front/Back and Left/Right, Top/Bottom stay; fallback unchanged.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(label, 2)
	end
	checks += 1
end
local function near(a: any, b: any, label: string)
	ok((a - b).Magnitude < 1e-4, `{label}: {a} vs {b}`)
end

local MeshPlacement = luau.load(fs.readFile("src/shared/World/MeshPlacement.luau"), {
	debugName = "MeshPlacement",
	environment = {
		CFrame = roblox.CFrame,
		Vector3 = roblox.Vector3,
		Color3 = roblox.Color3,
		Enum = roblox.Enum,
		math = math,
	},
})()
local V = roblox.Vector3.new
local CF = roblox.CFrame

-- 1. the importer's yaw, reproduced from decoded data (manifest offset -> imported position / 100)
local yaw = MeshPlacement.ImportYaw
near(yaw:PointToWorldSpace(V(1, 2, 3)), V(-1, 2, -3), "yaw maps (x,y,z) -> (-x,y,-z)")
for _, sample in { { V(-3.05, 1.3, 0), V(305, 130, 0) }, { V(-3.05, 1.325, -1.86), V(305, 132.5, 186) } } do
	near(yaw:PointToWorldSpace(sample[1]), sample[2] / 100, "decoded Workbench piece position")
end

-- 2. pieceCFrame
local pivot = CF.new(10, 0, 20) * CF.Angles(0, math.rad(37), 0)
local offset = V(-3.05, 1.3, 0.7)
local mesh = MeshPlacement.pieceCFrame(pivot, offset, true)
local box = MeshPlacement.pieceCFrame(pivot, offset, false)
near(mesh.Position, (pivot * CF.new(offset)).Position, "mesh keeps the authored position")
near(box.Position, mesh.Position, "fallback same position")
near(mesh.LookVector, -pivot.LookVector, "mesh piece turned 180° so its pre-rotated vertices face the model front")
near(box.LookVector, pivot.LookVector, "fallback not rotated")
local source = fs.readFile("src/server/World/MeshLibrary.luau")
ok(
	string.find(source, "MeshPlacement.pieceCFrame(pivot, piece.offset, useMeshes)", 1, true) ~= nil,
	"MeshLibrary places pieces through pieceCFrame"
)
ok(string.find(source, "MeshPlacement.YawAttribute", 1, true) ~= nil, "MeshLibrary tags yawed pieces")

-- 3. faces
local function fakePart(yawed: boolean): any
	return {
		GetAttribute = function(_self: any, name: string): any
			return if name == MeshPlacement.YawAttribute and yawed then true else nil
		end,
	}
end
local N = roblox.Enum.NormalId
ok(MeshPlacement.face(fakePart(true), N.Front) == N.Back, "yawed Front -> Back")
ok(MeshPlacement.face(fakePart(true), N.Left) == N.Right, "yawed Left -> Right")
ok(MeshPlacement.face(fakePart(true), N.Top) == N.Top, "Top unchanged")
ok(MeshPlacement.face(fakePart(false), N.Front) == N.Front, "fallback unchanged")

print(`[mesh-placement] {checks} checks passed`)
