--!strict
--[[
	TycoonWorld — the client's live registry of the server-built tycoon world: producer anchors,
	buy pads and plots (tree in Tycoon/TycoonContract).

	Purpose:
		StreamingEnabled is on, so plot content appears and disappears as players move (the
		owner's Pads / Producer models are PersistentPerPlayer). Every tycoon client module needs
		"which producer anchors exist / which are mine / where is pad X", so this module watches
		EVERY world's plots folder ONCE (Tycoon/PlotFolders: `Workspace.Plots` for Nuke Town,
		`Workspace.Worlds.<id>.Plots` for the others; DescendantAdded / DescendantRemoving,
		event-driven, no polling) and offers lookups + Added / Removed signals:
			producer = an `Anchor` Part inside a `Producer` Model (ProducerId on the model)
			pad      = a `Trigger` Part inside a Model under a `Pads` folder (PadId on the model)
		Ownership is the containing plot's OwnerUserId (re-read live; plots change owners).

	Worlds (owner R57): the player owns one plot per world (same index). `myPlot()` stays Nuke
	Town's (tutorial, stand sign, plot reveal are Nuke Town only); `myPlot(worldId)` /
	`MyWorldPlotChanged` cover every world; `worldOf(instance)` names the world of any plot
	instance. Ids are globally unique, so `myPad` / `myProducer` search all worlds.

	Performance: the descendant filters are two name comparisons per streamed instance; lookups
	walk the (small) registry sets.

	Connects to: Tycoon/TycoonContract (names), Tycoon/{ProducerBillboards, PadBillboards,
	Interaction, IncomePops, Tutorial, YouMarker, StandSign}.

	Example:
		TycoonWorld.ProducerAdded:Connect(function(anchor) ... end)
		local anchor = TycoonWorld.myProducer("a1_workbench")
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Contract = require(script.Parent.TycoonContract)
local PlotFolders = require(script.Parent.PlotFolders)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local Names = Contract.Names
local Attr = Contract.Attr

local TycoonWorld = {}

TycoonWorld.ProducerAdded = Signal.new() :: Signal.Signal<BasePart>
TycoonWorld.ProducerRemoved = Signal.new() :: Signal.Signal<BasePart>
TycoonWorld.PadAdded = Signal.new() :: Signal.Signal<BasePart>
TycoonWorld.PadRemoved = Signal.new() :: Signal.Signal<BasePart>
-- Fires when the local player's NUKE TOWN plot is found / changes (nil when they have none).
TycoonWorld.MyPlotChanged = Signal.new() :: Signal.Signal<Model?>
-- Fires when the local player's plot in ANY world is found / changes: (worldId, plot or nil).
TycoonWorld.MyWorldPlotChanged = Signal.new() :: Signal.Signal<string, Model?>

local producers: { [BasePart]: true } = {}
local pads: { [BasePart]: true } = {}
local myPlots: { [string]: Model } = {} -- worldId -> the local player's plot there
local started = false

--[[
	The plot Model (a direct child of any world's plots folder) containing `instance`, or nil.
	Example: TycoonWorld.plotOf(anchor) --> Workspace.Worlds.dino.Plots.Plot3
]]
function TycoonWorld.plotOf(instance: Instance): Model?
	local node: Instance? = instance
	while node ~= nil and not PlotFolders.isPlotsFolder(node.Parent) do
		node = node.Parent
	end
	return if node ~= nil and node:IsA("Model") then node else nil
end

--[[
	The world id of a plot (or anything inside one): the plot's WorldId attribute (validated
	against WorldsConfig), else its folder's world; "main" when `instance` is in no plot.
	Example: TycoonWorld.worldOf(anchor) --> "dino"
]]
function TycoonWorld.worldOf(instance: Instance): string
	local plot = TycoonWorld.plotOf(instance)
	if plot == nil then
		return WorldsConfig.MAIN
	end
	local attr = plot:GetAttribute(Attr.WorldId)
	if type(attr) == "string" and WorldsConfig.get(attr) ~= nil then
		return attr
	end
	return PlotFolders.worldOf(plot.Parent) or WorldsConfig.MAIN
end

--[[ True when `instance` lies in the local player's plot (plot OwnerUserId == my UserId). ]]
function TycoonWorld.isMine(instance: Instance): boolean
	local player = Players.LocalPlayer
	local plot = TycoonWorld.plotOf(instance)
	return player ~= nil and plot ~= nil and Contract.num(plot:GetAttribute(Attr.OwnerUserId), -1) == player.UserId
end

--[[ The producer id of an anchor (from its Producer model, else the anchor; "" when missing). ]]
function TycoonWorld.producerId(anchor: Instance): string
	local model = anchor.Parent
	local fromModel = if model ~= nil then Contract.str(model:GetAttribute(Attr.ProducerId), "") else ""
	return if fromModel ~= "" then fromModel else Contract.str(anchor:GetAttribute(Attr.ProducerId), "")
end

--[[ The pad Model of a pad trigger (its parent), or nil. ]]
function TycoonWorld.padModel(trigger: Instance): Model?
	local model = trigger.Parent
	return if model ~= nil and model:IsA("Model") then model else nil
end

--[[ An attribute of a pad (read from its Model). ]]
function TycoonWorld.padAttr(trigger: Instance, name: string): unknown
	local model = TycoonWorld.padModel(trigger)
	return if model ~= nil then model:GetAttribute(name) else nil
end

--[[ The pad id of a pad trigger ("" when missing). ]]
function TycoonWorld.padId(trigger: Instance): string
	return Contract.str(TycoonWorld.padAttr(trigger, Attr.PadId), "")
end

--[[ Every streamed-in producer anchor (any owner). ]]
function TycoonWorld.producers(): { BasePart }
	local list: { BasePart } = {}
	for anchor in producers do
		table.insert(list, anchor)
	end
	return list
end

--[[ Every streamed-in pad trigger (any owner). ]]
function TycoonWorld.pads(): { BasePart }
	local list: { BasePart } = {}
	for trigger in pads do
		table.insert(list, trigger)
	end
	return list
end

--[[ The local player's streamed-in anchor for `producerId`, or nil. ]]
function TycoonWorld.myProducer(producerId: string): BasePart?
	for anchor in producers do
		if TycoonWorld.producerId(anchor) == producerId and TycoonWorld.isMine(anchor) then
			return anchor
		end
	end
	return nil
end

--[[ The local player's streamed-in pad trigger for `padId`, or nil. ]]
function TycoonWorld.myPad(padId: string): BasePart?
	for trigger in pads do
		if TycoonWorld.padId(trigger) == padId and TycoonWorld.isMine(trigger) then
			return trigger
		end
	end
	return nil
end

--[[
	The local player's plot Model in a world (default Nuke Town), or nil.
	Example: TycoonWorld.myPlot("dino") --> Workspace.Worlds.dino.Plots.Plot3
]]
function TycoonWorld.myPlot(worldId: string?): Model?
	return myPlots[worldId or WorldsConfig.MAIN]
end

--[[
	The local player's build Model for a BuildKey (searched on demand in the key's world), or nil.
	Example: TycoonWorld.myBuild("D3_WindSock")
]]
function TycoonWorld.myBuild(buildKey: string): Model?
	local plot = myPlots[WorldsConfig.worldOfBuildKey(buildKey) or WorldsConfig.MAIN]
	if plot == nil or buildKey == "" then
		return nil
	end
	for _, area in plot:GetChildren() do
		local builds = area:FindFirstChild(Names.BuildsFolder)
		local build = if builds ~= nil then builds:FindFirstChild(buildKey) else nil
		if build ~= nil and build:IsA("Model") then
			return build
		end
	end
	return nil
end

--[[
	The click box of a producer anchor: its "ClickBox" sibling in the Producer model (current
	PlotBuilder) or child (earlier contract), else the anchor itself.
]]
function TycoonWorld.clickBox(anchor: BasePart): BasePart
	local model = anchor.Parent
	local box = (if model ~= nil then model:FindFirstChild(Names.ClickBox) else nil)
		or anchor:FindFirstChild(Names.ClickBox)
	return if box ~= nil and box:IsA("BasePart") then box else anchor
end

-- Re-finds the local player's plot in one world's folder (a child with OwnerUserId == my UserId).
local function refreshPlot(folder: Instance, worldId: string)
	local player = Players.LocalPlayer
	local found: Model? = nil
	if player ~= nil and folder.Parent ~= nil then
		for _, plot in folder:GetChildren() do
			if plot:IsA("Model") and Contract.num(plot:GetAttribute(Attr.OwnerUserId), -1) == player.UserId then
				found = plot
				break
			end
		end
	end
	if found ~= myPlots[worldId] then
		myPlots[worldId] = found :: any
		if worldId == WorldsConfig.MAIN then
			TycoonWorld.MyPlotChanged:Fire(found)
		end
		TycoonWorld.MyWorldPlotChanged:Fire(worldId, found)
	end
end

-- Classifies one streamed instance (cheap name checks first).
local function onAdded(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local parent = instance.Parent
	if parent == nil then
		return
	end
	if instance.Name == Names.Anchor and parent.Name == Names.Producer then
		if producers[instance] == nil then
			producers[instance] = true
			TycoonWorld.ProducerAdded:Fire(instance)
		end
	elseif instance.Name == Names.Trigger and parent.Parent ~= nil and parent.Parent.Name == Names.PadsFolder then
		if pads[instance] == nil then
			pads[instance] = true
			TycoonWorld.PadAdded:Fire(instance)
		end
	end
end

local function onRemoving(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	if producers[instance] ~= nil then
		producers[instance] = nil
		TycoonWorld.ProducerRemoved:Fire(instance)
	elseif pads[instance] ~= nil then
		pads[instance] = nil
		TycoonWorld.PadRemoved:Fire(instance)
	end
end

-- Hooks one world's plots folder (descendants + plot ownership).
local function watchFolder(folder: Instance, worldId: string)
	local function refresh()
		refreshPlot(folder, worldId)
	end
	folder.DescendantAdded:Connect(onAdded)
	folder.DescendantRemoving:Connect(onRemoving)
	local function watchPlot(plot: Instance)
		if plot:IsA("Model") then
			plot:GetAttributeChangedSignal(Attr.OwnerUserId):Connect(refresh)
		end
	end
	for _, plot in folder:GetChildren() do
		watchPlot(plot)
	end
	folder.ChildAdded:Connect(function(plot: Instance)
		watchPlot(plot)
		refresh()
	end)
	folder.ChildRemoved:Connect(refresh)
	folder.AncestryChanged:Connect(refresh) -- a torn-down world forgets its plot
	for _, descendant in folder:GetDescendants() do
		onAdded(descendant)
	end
	refresh()
end

--[[ Starts watching every world's plots (once; TycoonClient calls it). ]]
function TycoonWorld.start()
	if started then
		return
	end
	started = true
	PlotFolders.watch(watchFolder)
end

return TycoonWorld
