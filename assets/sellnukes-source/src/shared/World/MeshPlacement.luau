--!strict
--[[
	MeshPlacement — the two rules every place that turns MeshAssets pieces into parts must apply
	(server MeshLibrary, and any client preview / pet / hatch / attack code that clones meshes).

	1. IMPORT YAW (owner R17 / R25 / R26 root cause, found by B8a):
	   Roblox's FBX importer turns every uploaded model 180° about Y. Decoding an uploaded model
	   shows each MeshPart with identity rotation at (-x, y, -z) of its Blender offset (e.g.
	   Workbench Cabinet x -3.05 -> +3.05), i.e. the vertex data of every piece is pre-rotated
	   180°. Placing a mesh piece at `pivot * offset` therefore shows it spun 180° in place
	   (mirrored sign text, caps beside bodies, back details in front). Mesh pieces must be placed
	   at `pivot * offset * ImportYaw`. Primitive fallback boxes are NOT rotated (no vertex data).
	   The axis-aligned size is unchanged by a 180° yaw, so bounds / sizes need no change.

	2. GLOW BUDGET (owner R19: glowing pieces blew the scene out with bloom):
	   Neon only for small accents. A "Neon" piece whose largest box face exceeds NeonMaxArea
	   studs² renders as SmoothPlastic in a brightened colour instead (still reads as glowing,
	   cannot bloom). Bulbs, reactor cores, crystal tips stay Neon.

	3. FACES: because of rule 1 a mesh piece's own Front faces the model's back. Put SurfaceGuis /
	   decals on `MeshPlacement.face(part, Enum.NormalId.Front)`, never a hard-coded Front.

	Pure (no services): unit-tested by tests/mesh-placement.luau and tests/glow-budget.luau.

	Example:
		part.CFrame = MeshPlacement.pieceCFrame(pivot, piece.offset, true)
		gui.Face = MeshPlacement.face(part, Enum.NormalId.Front)
		local material, color = MeshPlacement.resolveGlow(piece.material, piece.size, piece.color)
]]

local MeshPlacement = {}

-- 180° about +Y: undoes the rotation Roblox's FBX importer bakes into every uploaded mesh.
MeshPlacement.ImportYaw = CFrame.Angles(0, math.pi, 0)

-- Largest box face (studs²) a piece may have and still render as Neon.
MeshPlacement.NeonMaxArea = 6
-- Material a too-large Neon piece renders as, and how much its colour is lifted toward white.
MeshPlacement.NeonFallbackMaterial = "Smooth"
MeshPlacement.NeonFallbackLift = 0.18

--[[
	World CFrame of one piece.
	@param pivot CFrame     model pivot
	@param offset Vector3   piece box centre relative to the pivot (MeshAssets)
	@param isMesh boolean   true for an uploaded MeshPart clone, false for a primitive fallback
]]
function MeshPlacement.pieceCFrame(pivot: CFrame, offset: Vector3, isMesh: boolean): CFrame
	local cf = pivot * CFrame.new(offset)
	return if isMesh then cf * MeshPlacement.ImportYaw else cf
end

-- Attribute MeshLibrary sets on every mesh piece placed with ImportYaw.
MeshPlacement.YawAttribute = "MeshYaw"

-- Face swaps under a 180° yaw, keyed by name (works for Roblox and lune EnumItems alike).
local SWAP: { [string]: Enum.NormalId } = {
	Front = Enum.NormalId.Back,
	Back = Enum.NormalId.Front,
	Left = Enum.NormalId.Right,
	Right = Enum.NormalId.Left,
}

--[[
	The part face that shows on the MODEL's `face` side. Mesh pieces are yawed 180° (rule 1), so
	their own Front points at the model's back: use this for every SurfaceGui / Decal / Texture put
	on a spawned piece. Primitive fallback pieces (no yaw) return `face` unchanged.
	Example: gui.Face = MeshPlacement.face(signPiece, Enum.NormalId.Front)
]]
function MeshPlacement.face(part: BasePart, face: Enum.NormalId): Enum.NormalId
	if part:GetAttribute(MeshPlacement.YawAttribute) == true then
		return SWAP[face.Name] or face
	end
	return face
end

-- Largest face area (studs²) of a piece's box.
function MeshPlacement.glowArea(size: Vector3): number
	return math.max(size.X * size.Y, size.Y * size.Z, size.X * size.Z)
end

--[[
	Material + colour a piece actually renders with under the glow budget.
	@return string  WorldMaterialConfig.Materials key
	@return Color3  colour to use
]]
function MeshPlacement.resolveGlow(material: string, size: Vector3, color: Color3): (string, Color3)
	if material ~= "Neon" or MeshPlacement.glowArea(size) <= MeshPlacement.NeonMaxArea then
		return material, color
	end
	return MeshPlacement.NeonFallbackMaterial, color:Lerp(Color3.new(1, 1, 1), MeshPlacement.NeonFallbackLift)
end

return MeshPlacement
