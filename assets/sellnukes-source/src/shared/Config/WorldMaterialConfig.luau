--!strict
--[[
	WorldMaterialConfig — the SellNukes world stud material (every world surface, owner rule 2).

	How the stud look is applied (decision + evidence: docs/world-art.md):
		ONE set of three images (colour / normal / roughness, tools/ui/build_world_studs.py) is used
		by a few MaterialVariants that differ only in StudsPerTile. Any BasePart (primitive Part OR
		Blender MeshPart) gets studs by `Material = Plastic` + `MaterialVariant = "SNStuds"`, and
		its `Color` tints the near-white stud map. Roblox projects MaterialVariant textures in
		object space for MeshParts too (it ignores mesh UVs and compensates for scaling), so studs
		are exactly as dense on meshes as on primitives. Zero extra instances per part.

	Why the variants are instances, not runtime-created:
		MaterialVariant ColorMap/NormalMap/RoughnessMap are PluginSecurity — game scripts cannot set
		them. They live in src/server/World/StudMaterialVariants.model.json (Rojo) and
		WorldMaterials.ensure() clones them into MaterialService once at boot.

	The generated block (Images + Variants) is rewritten by tools/ui/upload_world_studs.py, which
	also regenerates the model.json from the same values. Edit `Materials` below by hand.

	Example:
		local WorldMaterialConfig = require(ReplicatedStorage.Shared.Config.WorldMaterialConfig)
		local spec = WorldMaterialConfig.Materials.Studs
		part.Material = spec.material
		part.MaterialVariant = spec.variant or ""
]]

export type VariantSpec = {
	-- MaterialVariant instance name inside MaterialService (BasePart.MaterialVariant value).
	name: string,
	-- Studs covered by one 512 px texture tile; the tile holds 2 x 2 stud cells.
	studsPerTile: number,
}

export type MaterialSpec = {
	-- Base material set on the part (physics + fallback look when the variant is missing).
	material: Enum.Material,
	-- Variant name, or nil for plain built-in materials (Neon, Glass, SmoothPlastic).
	variant: string?,
}

local WorldMaterialConfig = {}

-- BEGIN GENERATED STUD IMAGES (tools/ui/upload_world_studs.py)
local IMAGES = {
	Color = 111053696270611,
	Normal = 88518149682413,
	Roughness = 93245873035569,
}
local VARIANTS: { [string]: VariantSpec } = {
	Studs = { name = "SNStuds", studsPerTile = 2 },
	StudsSmall = { name = "SNStudsSmall", studsPerTile = 1 },
	StudsLarge = { name = "SNStudsLarge", studsPerTile = 4 },
}
-- END GENERATED STUD IMAGES

-- Uploaded Image asset ids of the three stud maps (also baked into the variant model.json).
WorldMaterialConfig.Images = IMAGES
-- Config key ("Studs", ...) -> MaterialVariant name + density. Installed by WorldMaterials.ensure().
WorldMaterialConfig.Variants = VARIANTS

-- Folder (Rojo model.json, sibling of WorldMaterials.luau) that holds the authored variants.
WorldMaterialConfig.TemplateFolderName = "StudMaterialVariants"

--[[
	Manifest material name (tools/blender/snkit/core.py MATERIALS) -> how a part is dressed.
	"Studs" is the default for every world surface; "StudsSmall" for props a few studs big;
	"StudsLarge" only for huge far-away surfaces; Neon/Glass/Smooth stay stud-free on purpose.
]]
local MATERIALS: { [string]: MaterialSpec } = {
	Studs = { material = Enum.Material.Plastic, variant = "SNStuds" },
	StudsSmall = { material = Enum.Material.Plastic, variant = "SNStudsSmall" },
	StudsLarge = { material = Enum.Material.Plastic, variant = "SNStudsLarge" },
	Smooth = { material = Enum.Material.SmoothPlastic },
	Neon = { material = Enum.Material.Neon },
	Glass = { material = Enum.Material.Glass },
}
WorldMaterialConfig.Materials = MATERIALS

-- Used when a manifest names a material this table does not know (should never happen; the
-- lune test tests/mesh-assets.luau guards it).
WorldMaterialConfig.DefaultMaterial = "Studs"

return WorldMaterialConfig
