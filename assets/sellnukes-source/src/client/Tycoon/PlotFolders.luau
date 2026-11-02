--!strict
--[[
	PlotFolders — finds every world's plots folder on the client (owner R57, plan §3.5).

	Purpose:
		Nuke Town's plots live in `Workspace.Plots`; every other world's in
		`Workspace.Worlds.<worldId>.Plots` (Tycoon/TycoonContract). Several client systems watch
		plot descendants (TycoonWorld's registry, Npc/ManagerController, Fx/VehicleRoutes); this
		module discovers the folders ONCE (a handful of ChildAdded hooks on Workspace / Worlds /
		Worlds.<id>, no polling) and hands each folder to every subscriber exactly once, with its
		world id. Folders are plain Folders (non-spatial), so they replicate at join even with
		StreamingEnabled; the hooks also cover a world whose folder is created later (lazy hubs).

	Trust: a world folder counts only when its name is a registered non-main world
	(`WorldsConfig.get`), so a stray folder never becomes a "world".

	Connects to: Tycoon/TycoonContract (names), Shared/Config/Worlds/WorldsConfig (ids),
	Tycoon/{TycoonWorld, Npc/ManagerController, Fx/VehicleRoutes}.

	Example:
		PlotFolders.watch(function(folder, worldId)
			folder.DescendantAdded:Connect(onAdded) -- once per folder, "main" and "dino" alike
		end)
		print(PlotFolders.worldOf(Workspace.Plots)) --> "main"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Contract = require(script.Parent.TycoonContract)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local Names = Contract.Names

local PlotFolders = {}

export type Callback = (folder: Instance, worldId: string) -> ()

local folders: { [Instance]: string } = {} -- plots folder -> world id
local order: { Instance } = {} -- discovery order (replayed to late subscribers)
local subscribers: { Callback } = {}
local hooked = false

-- Registers one plots folder (idempotent) and tells every subscriber about it.
local function addFolder(folder: Instance, worldId: string)
	if folders[folder] ~= nil then
		return
	end
	folders[folder] = worldId
	table.insert(order, folder)
	-- A destroyed folder (a world torn down) is forgotten; its subscribers' connections die with it.
	folder.AncestryChanged:Connect(function(_, parent: Instance?)
		if parent == nil and folders[folder] ~= nil then
			folders[folder] = nil
			local index = table.find(order, folder)
			if index ~= nil then
				table.remove(order, index)
			end
		end
	end)
	for _, callback in subscribers do
		task.spawn(callback, folder, worldId)
	end
end

-- Workspace.Worlds.<id>: waits for its Plots child.
local function watchWorld(worldFolder: Instance)
	local worldId = worldFolder.Name
	local def = WorldsConfig.get(worldId)
	if def == nil or worldId == WorldsConfig.MAIN then
		return
	end
	local function consider(child: Instance)
		if child.Name == Names.PlotsFolder then
			addFolder(child, worldId)
		end
	end
	worldFolder.ChildAdded:Connect(consider)
	for _, child in worldFolder:GetChildren() do
		consider(child)
	end
end

-- Workspace.Worlds: every registered world folder in it.
local function watchWorlds(root: Instance)
	root.ChildAdded:Connect(watchWorld)
	for _, child in root:GetChildren() do
		watchWorld(child)
	end
end

-- Installs the Workspace hooks once (lazy: the first subscriber pays).
local function hook()
	if hooked then
		return
	end
	hooked = true
	local worldsRoot: Instance? = nil
	local function consider(child: Instance)
		if child.Name == Names.PlotsFolder then
			addFolder(child, WorldsConfig.MAIN)
		elseif child.Name == Names.WorldsFolder and worldsRoot == nil then
			worldsRoot = child
			watchWorlds(child)
		end
	end
	Workspace.ChildAdded:Connect(consider)
	for _, child in Workspace:GetChildren() do
		consider(child)
	end
end

--[[
	Calls `callback(folder, worldId)` once for every plots folder that exists now and for every one
	that appears later (each subscriber sees each folder once; callbacks run in their own thread).
	@param callback (folder: Instance, worldId: string) -> ()
	Example: PlotFolders.watch(function(folder, worldId) print(worldId, folder:GetFullName()) end)
]]
function PlotFolders.watch(callback: Callback)
	-- Hook first (it may discover the folders right now, telling only the OLD subscribers), then
	-- subscribe and replay the snapshot: every folder reaches this callback exactly once.
	hook()
	local snapshot = table.clone(order)
	table.insert(subscribers, callback)
	for _, folder in snapshot do
		local worldId = folders[folder]
		if worldId ~= nil then
			task.spawn(callback, folder, worldId)
		end
	end
end

--[[
	The world id of a plots folder, or nil when `instance` is not one.
	Example: PlotFolders.worldOf(Workspace.Worlds.dino.Plots) --> "dino"
]]
function PlotFolders.worldOf(instance: Instance?): string?
	return if instance ~= nil then folders[instance] else nil
end

--[[ True when `instance` is a known plots folder (any world). ]]
function PlotFolders.isPlotsFolder(instance: Instance?): boolean
	return instance ~= nil and folders[instance] ~= nil
end

--[[
	Every known plots folder (snapshot list). Example: for _, f in PlotFolders.list() do ... end
]]
function PlotFolders.list(): { Instance }
	hook()
	return table.clone(order)
end

return PlotFolders
