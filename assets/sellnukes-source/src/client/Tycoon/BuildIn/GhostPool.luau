--!strict
--[[
	GhostPool — pooled client-only "ghost" copies of build pieces for the LEGO build-in.

	A ghost looks exactly like the real piece (same mesh, size, colour, stud material) but is a
	local, non-colliding, shadowless part that flies in while the real piece is hidden. Ghosts are
	recycled per mesh: the first purchase of a mesh clones the real piece once; every later build of
	that mesh reuses the pooled ghost and just copies size/colour/material onto it.

	Cost: one Clone per NEW mesh (bounded by PoolPerKey / PoolTotal), zero Instance.new per frame.
	Ghosts are parented to a local folder in Workspace only while flying.

	Safety: a clone of a server piece would also copy its CollectionService tags (e.g. WorldFx) and
	children (prompts, lights). Every tag is stripped and only visual children are kept, BEFORE the
	ghost is parented, so no other client system ever sees a ghost.

	Example:
		local ghost = GhostPool.acquire(realPart)   -- nil if the piece cannot be cloned
		... fly it ...
		GhostPool.release(ghost)
]]

local BuildInConfigModule = game:GetService("ReplicatedStorage").Shared.Config.BuildInConfig
local BuildInConfig = require(BuildInConfigModule)

local GhostPool = {}

local pools: { [string]: { BasePart } } = {}
local keyOf: { [BasePart]: string } = {}
local pooledCount = 0
local folder: Folder? = nil

-- Child classes kept on a ghost (everything else, e.g. ProximityPrompt / Light / Script, is removed).
local VISUAL_CHILDREN: { [string]: boolean } = {
	SurfaceAppearance = true,
	Decal = true,
	Texture = true,
	SpecialMesh = true,
}

-- Local folder holding in-flight ghosts.
function GhostPool.folder(): Folder
	local current = folder
	if current ~= nil and current.Parent ~= nil then
		return current
	end
	local created = Instance.new("Folder")
	created.Name = "SN_BuildGhosts"
	created.Parent = workspace
	folder = created
	return created
end

-- Pool key: one pool per mesh (MeshPart) or per primitive shape.
local function poolKey(real: BasePart): string
	if real:IsA("MeshPart") then
		return "M" .. real.MeshId
	elseif real:IsA("Part") then
		return "P" .. real.Shape.Name
	end
	return "C" .. real.ClassName
end

-- Copies everything visible from the real piece onto a ghost.
local function dress(ghost: BasePart, real: BasePart)
	ghost.Size = real.Size
	ghost.Color = real.Color
	ghost.Material = real.Material
	ghost.MaterialVariant = real.MaterialVariant
	ghost.Reflectance = real.Reflectance
	ghost.CFrame = real.CFrame
end

-- Turns a fresh clone into an inert local ghost.
local function sanitize(ghost: BasePart)
	for _, tag in ghost:GetTags() do
		ghost:RemoveTag(tag)
	end
	for _, child in ghost:GetChildren() do
		if not VISUAL_CHILDREN[child.ClassName] then
			child:Destroy()
		end
	end
	ghost.Name = "Ghost"
	ghost.Anchored = true
	ghost.CanCollide = false
	ghost.CanQuery = false
	ghost.CanTouch = false
	ghost.CastShadow = false
	ghost.Massless = true
	ghost.LocalTransparencyModifier = 0
end

--[[
	A ghost for `real`, positioned on it (caller moves it). nil when the piece is not Archivable
	(cannot be cloned) — the caller then fades the real piece in place instead.
]]
function GhostPool.acquire(real: BasePart): BasePart?
	local key = poolKey(real)
	local pool = pools[key]
	local ghost: BasePart? = nil
	if pool ~= nil and #pool > 0 then
		ghost = table.remove(pool)
		pooledCount -= 1
	else
		local ok, clone = pcall(function()
			return real:Clone()
		end)
		if not ok or clone == nil then
			return nil
		end
		ghost = clone :: BasePart
		sanitize(ghost :: BasePart)
	end
	local result = ghost :: BasePart
	keyOf[result] = key
	dress(result, real)
	result.Parent = GhostPool.folder()
	return result
end

-- Returns a ghost to its pool (or destroys it when the pool is full).
function GhostPool.release(ghost: BasePart)
	local key = keyOf[ghost]
	ghost.Parent = nil
	if key == nil then
		ghost:Destroy()
		return
	end
	local pool = pools[key]
	if pool == nil then
		pool = {}
		pools[key] = pool
	end
	if #pool >= BuildInConfig.PoolPerKey or pooledCount >= BuildInConfig.PoolTotal then
		keyOf[ghost] = nil
		ghost:Destroy()
		return
	end
	table.insert(pool, ghost)
	pooledCount += 1
end

-- Debug counters.
function GhostPool.stats(): { pooled: number, keys: number }
	local keys = 0
	for _ in pools do
		keys += 1
	end
	return { pooled = pooledCount, keys = keys }
end

return GhostPool
