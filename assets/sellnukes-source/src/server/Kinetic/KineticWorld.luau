--!strict
--[[
	KineticWorld — the server instances of owner R90's Mega Lever + Tip Jar (docs/kinetic.md): one
	lever machine and one tip jar per (player, world) on that player's plot, placed, tagged,
	attributed and removed here. No gameplay rules live in this module (Server/Kinetic/MegaLever,
	Server/Kinetic/TipJar and Server/Kinetic/KineticService decide WHEN; this module does HOW).

	Instance tree (every world's plot; names + attributes are the client contract):
		<plot Model>.Kinetic (Folder)
		  MegaLever (Model)   tag SNKineticLever; attributes OwnerUserId, WorldId, Plot, ReadyAt
		                      (unix s, 0 = ready), PulledAt (server time of the last pull)
		    <mesh pieces>     MeshLibrary Kinetic_Lever (Arm / ArmStripes swing on the client)
		    Collider (Part)   invisible, CanCollide, CanQuery/CanTouch false (the machine is solid)
		  TipJar (Model)      tag SNKineticJar; attributes OwnerUserId, WorldId, Plot, Fill (0..1),
		                      Full, CollectedAt, TippedAt
		    <mesh pieces>     MeshLibrary Kinetic_TipJar (Coins scaled by Fill on the client)
		    Collider (Part)   invisible, solid crate + jar
		    JarTrigger (Part) invisible, CanTouch only: the server Touched that pays the jar out
		A reveal (the plot just reached KineticConfig.UnlockArea) sets BuildIn + BuyerUserId + the
		BuildIn tag BEFORE parenting, so every client plays the LEGO fly-in (owner rule 4); a restore
		(join, travel back) appears finished. Models are Atomic (never half-streamed).

	Async safety: MeshLibrary.spawn may yield while templates load; every placement captures a
	per-(player, world) generation, and remove() bumps it, so a spawn finishing after a leave /
	relock is destroyed instead of appearing on a plot nobody owns.

	Performance: instances only while unlocked (none for new players), attribute writes only on
	change (setAttr), no per-frame work, one Touched connection per jar (destroyed with the part).

	Connects to: Shared/Config/{KineticConfig, BuildInConfig, MeshAssets}, Shared/Tycoon/KineticLogic
	(mountCFrame), Server/World/{MeshLibrary, PlotBuilder}.

	Example:
		KineticWorld.place(player, "main", 3, true, onJarTouched) -- async, builds in
		local lever = KineticWorld.lever(player, "main")
		KineticWorld.setAttr(lever, "PulledAt", Workspace:GetServerTimeNow())
		KineticWorld.removeAll(player)
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BuildInConfig = require(ReplicatedStorage.Shared.Config.BuildInConfig)
local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)
local KineticLogic = require(ReplicatedStorage.Shared.Tycoon.KineticLogic)
local MeshAssets = require(ReplicatedStorage.Shared.Config.MeshAssets)
local MeshLibrary = require(script.Parent.Parent.World.MeshLibrary)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)

local ATTR = KineticConfig.Attr
local JAR = KineticConfig.TipJar

-- A placement whose meshes failed to spawn is retried at most this often (no warn spam from the
-- 1 Hz reconcile).
local RETRY_SECONDS = 15

-- Touched callback the service installs on every jar trigger: (owner, the part that touched).
export type TouchHandler = (owner: Player, hit: BasePart) -> ()

-- One (player, world) pair's props.
export type Props = {
	worldId: string,
	plot: number,
	lever: Model?,
	jar: Model?,
	generation: number,
	pending: boolean, -- a placement is in flight
	failedAt: number?, -- os.clock() of the last failed spawn (retried after RETRY_SECONDS)
}

local KineticWorld = {}

-- props[player][worldId]
local props: { [Player]: { [string]: Props } } = {}

-- The props of a (player, world), or nil.
function KineticWorld.get(player: Player, worldId: string): Props?
	local byWorld = props[player]
	return if byWorld ~= nil then byWorld[worldId] else nil
end

-- The placed lever model of a (player, world) (nil while locked / loading / removed).
function KineticWorld.lever(player: Player, worldId: string): Model?
	local entry = KineticWorld.get(player, worldId)
	local model = if entry ~= nil then entry.lever else nil
	return if model ~= nil and model.Parent ~= nil then model else nil
end

-- The placed jar model of a (player, world) (nil while locked / loading / removed).
function KineticWorld.jar(player: Player, worldId: string): Model?
	local entry = KineticWorld.get(player, worldId)
	local model = if entry ~= nil then entry.jar else nil
	return if model ~= nil and model.Parent ~= nil then model else nil
end

-- True when both props of a (player, world) stand on the plot.
function KineticWorld.isPlaced(player: Player, worldId: string): boolean
	return KineticWorld.lever(player, worldId) ~= nil and KineticWorld.jar(player, worldId) ~= nil
end

-- True while a placement of a (player, world) is in flight.
function KineticWorld.isPending(player: Player, worldId: string): boolean
	local entry = KineticWorld.get(player, worldId)
	return entry ~= nil and entry.pending
end

--[[
	Sets an attribute only when it changes (no replication for an unchanged value).
	@param instance Instance? — nil is ignored (a prop that is not placed)
	Example: KineticWorld.setAttr(jar, "Fill", 0.35)
]]
function KineticWorld.setAttr(instance: Instance?, name: string, value: any)
	if instance ~= nil and instance:GetAttribute(name) ~= value then
		instance:SetAttribute(name, value)
	end
end

-- The plot's Kinetic folder (created on demand), or nil when the world has no plots.
local function folderOf(worldId: string, plot: number): Folder?
	local builder = PlotBuilder.world(worldId)
	if not builder.hasPlots() then
		return nil
	end
	local ok, model = pcall(builder.getPlot, plot)
	if not ok or model == nil then
		return nil
	end
	local existing = model:FindFirstChild(KineticConfig.FolderName)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = KineticConfig.FolderName
	folder.Parent = model
	return folder
end

-- An invisible part (collider / trigger) inside a prop model.
local function helperPart(name: string, size: Vector3, cf: CFrame, collide: boolean, touch: boolean): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Anchored = true
	part.CanCollide = collide
	part.CanQuery = false
	part.CanTouch = touch
	part.Transparency = 1
	part.CastShadow = false
	part.Massless = true
	return part
end

-- Spawns one prop model at `pivot` (MeshLibrary: meshes or the primitive fallback); nil on error.
local function spawnProp(key: string, name: string, pivot: CFrame): Model?
	if MeshAssets[key] == nil then
		warn(`[KineticWorld] model key {key} is not in MeshAssets`)
		return nil
	end
	local options: MeshLibrary.SpawnOptions = {
		name = name,
		streamingMode = Enum.ModelStreamingMode.Atomic,
	}
	local ok, model = pcall(MeshLibrary.spawn, key, nil, pivot, options)
	if not ok then
		warn(`[KineticWorld] {key} failed to spawn: {model}`)
		return nil
	end
	return model :: Model
end

-- Common attributes + tag + optional build-in stamp; the caller parents the model last.
local function stamp(model: Model, owner: Player, worldId: string, plot: number, tag: string, flyIn: boolean)
	model:SetAttribute(ATTR.Owner, owner.UserId)
	model:SetAttribute(ATTR.World, worldId)
	model:SetAttribute(ATTR.Plot, plot)
	CollectionService:AddTag(model, tag)
	if flyIn then
		model:SetAttribute(BuildInConfig.TimeAttribute, Workspace:GetServerTimeNow())
		model:SetAttribute(BuildInConfig.BuyerAttribute, owner.UserId)
		CollectionService:AddTag(model, BuildInConfig.Tag)
	end
end

--[[
	Places (async) the lever + jar of a (player, world) on plot `plot`. Idempotent while placed or
	pending. Old props of the same names in that plot's folder are replaced (an owner change).
	@param owner Player
	@param worldId string — "main" / "dino" / ...
	@param plot number — 1..8 (the player's plot index; the same in every world)
	@param flyIn boolean — true = reveal with the LEGO build-in
	@param initial { readyAt: number, fill: number, full: boolean } — first attribute values
	@param onTouched TouchHandler — jar trigger Touched (the service validates everything)
]]
function KineticWorld.place(
	owner: Player,
	worldId: string,
	plot: number,
	flyIn: boolean,
	initial: { readyAt: number, fill: number, full: boolean },
	onTouched: TouchHandler
)
	local byWorld = props[owner]
	if byWorld == nil then
		byWorld = {}
		props[owner] = byWorld
	end
	local entry = byWorld[worldId]
	if entry ~= nil and (entry.pending or (entry.lever ~= nil and entry.jar ~= nil)) then
		return
	end
	local failedAt = if entry ~= nil then entry.failedAt else nil
	if failedAt ~= nil and os.clock() - failedAt < RETRY_SECONDS then
		return
	end
	if entry == nil then
		entry = { worldId = worldId, plot = plot, lever = nil, jar = nil, generation = 0, pending = false }
		byWorld[worldId] = entry
	end
	local slot = entry :: Props
	slot.generation += 1
	slot.pending = true
	slot.plot = plot
	local generation = slot.generation
	task.spawn(function()
		local folder = folderOf(worldId, plot)
		local leverPivot = KineticLogic.mountCFrame(plot, worldId, "Lever")
		local jarPivot = KineticLogic.mountCFrame(plot, worldId, "Jar")
		local lever = if folder ~= nil
			then spawnProp(KineticConfig.Models.Lever, KineticConfig.LeverName, leverPivot)
			else nil
		local jar = if folder ~= nil then spawnProp(KineticConfig.Models.Jar, KineticConfig.JarName, jarPivot) else nil
		-- Superseded (left / relocked / re-placed) while the meshes loaded: throw the result away.
		if slot.generation ~= generation or props[owner] ~= byWorld or folder == nil or folder.Parent == nil then
			if lever ~= nil then
				lever:Destroy()
			end
			if jar ~= nil then
				jar:Destroy()
			end
			if slot.generation == generation then
				slot.pending = false
			end
			return
		end
		slot.pending = false
		if lever == nil or jar == nil then
			if lever ~= nil then
				lever:Destroy()
			end
			if jar ~= nil then
				jar:Destroy()
			end
			slot.failedAt = os.clock()
			return -- logged by spawnProp; a later reconcile retries after RETRY_SECONDS
		end
		local leverModel, jarModel = lever :: Model, jar :: Model
		local holder = folder :: Folder
		-- Lever: attributes, solid machine collider.
		stamp(leverModel, owner, worldId, plot, KineticConfig.Tags.Lever, flyIn)
		leverModel:SetAttribute(ATTR.ReadyAt, initial.readyAt)
		leverModel:SetAttribute(ATTR.PulledAt, 0)
		local leverBox = KineticConfig.LeverCollider
		helperPart("Collider", leverBox.size, leverPivot * CFrame.new(leverBox.center), true, false).Parent = leverModel
		-- Jar: attributes, collider, touch trigger (server Touched → TipJar.collect via the service).
		stamp(jarModel, owner, worldId, plot, KineticConfig.Tags.Jar, flyIn)
		jarModel:SetAttribute(ATTR.Fill, initial.fill)
		jarModel:SetAttribute(ATTR.Full, initial.full)
		jarModel:SetAttribute(ATTR.CollectedAt, 0)
		jarModel:SetAttribute(ATTR.TippedAt, 0)
		helperPart("Collider", JAR.ColliderSize, jarPivot * CFrame.new(0, JAR.ColliderSize.Y / 2, 0), true, false).Parent =
			jarModel
		local trigger = helperPart(
			KineticConfig.TriggerName,
			JAR.TriggerSize,
			jarPivot * CFrame.new(JAR.TriggerOffset),
			false,
			true
		)
		trigger.Parent = jarModel
		trigger.Touched:Connect(function(hit: BasePart)
			onTouched(owner, hit)
		end)
		-- Replace stale props of the same names (a previous owner's), then parent last.
		for _, name in { KineticConfig.LeverName, KineticConfig.JarName } do
			local old = holder:FindFirstChild(name)
			if old ~= nil then
				old:Destroy()
			end
		end
		leverModel.Parent = holder
		jarModel.Parent = holder
		slot.lever = leverModel
		slot.jar = jarModel
		slot.failedAt = nil
	end)
end

--[[ Removes the props of a (player, world) (and cancels an in-flight placement). ]]
function KineticWorld.remove(player: Player, worldId: string)
	local byWorld = props[player]
	local entry = if byWorld ~= nil then byWorld[worldId] else nil
	if entry == nil then
		return
	end
	entry.generation += 1
	entry.pending = false
	if entry.lever ~= nil then
		entry.lever:Destroy()
		entry.lever = nil
	end
	if entry.jar ~= nil then
		entry.jar:Destroy()
		entry.jar = nil
	end
	byWorld[worldId] = nil
end

--[[ Removes every prop of a player (leave / plot released). ]]
function KineticWorld.removeAll(player: Player)
	local byWorld = props[player]
	if byWorld == nil then
		return
	end
	for worldId in table.clone(byWorld) do
		KineticWorld.remove(player, worldId)
	end
	props[player] = nil
end

--[[ QA / admin: how many props are placed and pending on this server. ]]
function KineticWorld.counts(): { placed: number, pending: number }
	local placed, pending = 0, 0
	for _, byWorld in props do
		for _, entry in byWorld do
			if entry.pending then
				pending += 1
			elseif entry.lever ~= nil and entry.jar ~= nil then
				placed += 1
			end
		end
	end
	return { placed = placed, pending = pending }
end

return KineticWorld
