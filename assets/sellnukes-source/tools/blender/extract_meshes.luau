--!strict
--[[
	extract_meshes.luau — decode an Open Cloud-imported Model (rbxm/rbxmx bytes) as INERT data and
	write {[meshPartName] = {assetId = number}} as JSON. Ported from RoBeasts extract_offer_meshes.

	Called by tools/blender/upload_meshes.py:
		lune run tools/blender/extract_meshes.luau <model-file> <out.json>

	Safety: nothing is parented or executed; any script inside the model aborts extraction (our
	Blender FBX imports never contain code). The Python caller verifies the names against the
	hash-bound Blender manifest before any receipt changes.
]]
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local source = process.args[1]
local target = process.args[2]
assert(type(source) == "string" and type(target) == "string", "usage: extract_meshes.luau <model> <out.json>")

local roots = roblox.deserializeModel(fs.readFile(source))
local meshes: { [string]: { assetId: number } } = {}

-- New imports serialize MeshContent; older ones MeshId. Reading a missing reflected property can
-- throw in Lune, so both are probed inside pcall. Accepts rbxassetid://N and ...?id=N forms.
local function meshAssetId(item: Instance): string?
	for _, property in { "MeshContent", "MeshId" } do
		local ok, content = pcall(function()
			return (item :: any)[property]
		end)
		if ok then
			local value = tostring(content)
			local id = value:match("rbxassetid://(%d+)") or value:match("[?&]id=(%d+)")
			if id then
				return id
			end
		end
	end
	return nil
end

-- Records one MeshPart; rejects code and duplicate names (names are the piece identity).
local function inspect(item: Instance)
	assert(not item:IsA("LuaSourceContainer"), "Unexpected code in an authored mesh model")
	if item:IsA("MeshPart") then
		assert(meshes[item.Name] == nil, `Duplicate imported mesh name {item.Name}`)
		local id = meshAssetId(item)
		assert(id ~= nil, `Imported MeshPart {item.Name} has no asset id`)
		meshes[item.Name] = { assetId = tonumber(id) :: number }
	end
end

for _, root in roots do
	inspect(root)
	for _, item in root:GetDescendants() do
		inspect(item)
	end
end

fs.writeFile(target, serde.encode("json", meshes, true))
