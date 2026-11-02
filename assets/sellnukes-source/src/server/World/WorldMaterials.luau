--!strict
--[[
	WorldMaterials — installs the SellNukes stud MaterialVariants and dresses parts with them.

	Why: every world surface must carry the stud look (owner rule 2). The look is ONE shared texture
	set exposed through a few MaterialVariants (WorldMaterialConfig). Their image properties are
	PluginSecurity, so they are authored as instances in StudMaterialVariants.model.json (a Folder
	next to this module, synced by Rojo) and cloned into MaterialService here, exactly once. The
	clones replicate to every client with MaterialService. Clones (not moves) keep the Rojo-managed
	originals untouched in edit mode.

	Connections:
		* MeshLibrary.spawn/preload call ensure() lazily, so no boot-order dependency exists.
		* PlotBuilder / HubBuilder (B5) call WorldMaterials.apply(part, "Studs") on any primitive
		  Part they create (collision floors, fallback blocks) so primitives match the meshes.

	Performance: zero instances per dressed part (only Material + MaterialVariant properties),
	one texture set in memory for the whole world. No per-frame work.

	Example:
		local WorldMaterials = require(ServerScriptService.Server.World.WorldMaterials)
		WorldMaterials.ensure()
		WorldMaterials.apply(floorPart, "Studs")      -- 1-stud studs, tinted by floorPart.Color
		WorldMaterials.apply(bulb, "Neon")             -- plain Neon, no variant
]]

local MaterialService = game:GetService("MaterialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldMaterialConfig = require(ReplicatedStorage.Shared.Config.WorldMaterialConfig)

local WorldMaterials = {}

-- true once ensure() has run successfully (variants present in MaterialService).
local installed = false
-- true once a missing-template warning was printed (warn once, not per call).
local warned = false

--[[
	Clone every configured variant from the Rojo template folder into MaterialService, once.
	Idempotent and cheap after the first call. Returns true when every variant is installed;
	false (with one warning) if the template folder is missing, in which case parts still render
	as plain Plastic in their colour — degraded look, never an error.
]]
function WorldMaterials.ensure(): boolean
	if installed then
		return true
	end
	local templates = script.Parent:FindFirstChild(WorldMaterialConfig.TemplateFolderName)
	local ok = true
	for _, spec in WorldMaterialConfig.Variants do
		local existing = MaterialService:FindFirstChild(spec.name)
		if existing ~= nil and existing:IsA("MaterialVariant") then
			continue
		end
		local template = templates and templates:FindFirstChild(spec.name)
		if template == nil or not template:IsA("MaterialVariant") then
			ok = false
			continue
		end
		local clone = template:Clone()
		-- StudsPerTile is script-writable: keep the config authoritative even if the model.json
		-- and config ever drift apart.
		clone.StudsPerTile = spec.studsPerTile
		clone.Parent = MaterialService
	end
	if not ok and not warned then
		warned = true
		warn("[WorldMaterials] stud variant templates missing; run tools/ui/upload_world_studs.py")
	end
	installed = ok
	return ok
end

--[[
	Dress one part with a WorldMaterialConfig material ("Studs", "StudsSmall", "StudsLarge",
	"Smooth", "Neon", "Glass"). Unknown names fall back to DefaultMaterial. Does not touch Color.

	@param part BasePart  any primitive Part or MeshPart
	@param materialName string  key of WorldMaterialConfig.Materials
]]
function WorldMaterials.apply(part: BasePart, materialName: string)
	local spec = WorldMaterialConfig.Materials[materialName]
		or WorldMaterialConfig.Materials[WorldMaterialConfig.DefaultMaterial]
	part.Material = spec.material
	part.MaterialVariant = spec.variant or ""
end

--[[
	Convenience for level builders: dress every BasePart under `root` (inclusive) with the stud
	material unless it is Neon/Glass/ForceField (glows and windows stay plain).
]]
function WorldMaterials.studAll(root: Instance, materialName: string?)
	local name = materialName or "Studs"
	local function dress(item: Instance)
		if item:IsA("BasePart") then
			local m = item.Material
			if m ~= Enum.Material.Neon and m ~= Enum.Material.Glass and m ~= Enum.Material.ForceField then
				WorldMaterials.apply(item, name)
			end
		end
	end
	dress(root)
	for _, item in root:GetDescendants() do
		dress(item)
	end
end

return WorldMaterials
