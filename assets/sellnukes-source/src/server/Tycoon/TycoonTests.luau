--!strict
--[[
	TycoonTests — B5 Studio smoke tests (TestRunner suite "Tycoon"; Run mode, no players needed).

	Cases:
		World          the hub (spawn, no plot teleport pads — R134) and 8 plots (YouAnchor, shell, entrance)
		Layouts        every area resolves a layout (art / partial / placeholder) that is complete
		Restore        a saved state rebuilds instantly: bases, builds, producer anchors, NO BuildIn
		Purchase       buildPurchase stamps BuildIn + BuyerUserId + the "BuildIn" tag before parenting;
		               an Unlock pad builds the next area's Base with AreaUnlock
		Pads           syncPads shows exactly the next pads (tag SNPad + attributes); pressPad sets
		               PressedAt and removes the pad PadPressSeconds later
		Rules          TycoonRules / TutorialLogic agree with Lune in the engine (float64 CFrames)
		Worlds         R57: every non-main world's 8 plot frames (Workspace.Worlds.<id>.Plots,
		               WorldId attribute, entrances on that world's plots), every area's layout
		               complete against that world's geometry, and a restore + purchase on the
		               free plot through PlotBuilder.world(id) (no BuildIn on restore, BuildIn on a
		               purchase, the producer anchor, clear)
	Runs on plot 8 (or the highest unowned plot) and clears it afterwards.

	Register (lead, Server/Tests/TestRunner.getSuites):
		Tycoon = require(script.Parent.Parent.Tycoon.TycoonTests) :: { TestCase },
	Run: StudioTestService:ExecuteRunModeAsync({ suite = "Tycoon" })
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AreaLayouts = require(script.Parent.AreaLayouts)
local HubBuilder = require(script.Parent.Parent.World.HubBuilder)
local LayoutLogic = require(script.Parent.LayoutLogic)
local MeshAssets = require(ReplicatedStorage.Shared.Config.MeshAssets)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)
local PlotService = require(script.Parent.PlotService)
local TestContext = require(script.Parent.Parent.Tests.TestContext)
local TutorialLogic = require(script.Parent.TutorialLogic)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonRules = require(script.Parent.TycoonRules)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type TestCase = { name: string, run: (ctx: TestContext.TestContext) -> () }

-- A fake buyer: buildPurchase only reads UserId.
local BUYER = { UserId = 424242, Parent = nil } :: any

-- The highest plot nobody owns (tests never touch a real player's plot).
local function testPlot(): number?
	PlotBuilder.createPlots()
	for index = WorldLayout.PlotCount, 1, -1 do
		if PlotService.getOwner(index) == nil then
			return index
		end
	end
	return nil
end

-- Waits until `predicate()` or `timeout` seconds.
local function waitFor(predicate: () -> boolean, timeout: number): boolean
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		if predicate() then
			return true
		end
		task.wait(0.1)
	end
	return predicate()
end

-- A state that owns the first `count` pads of the chain.
local function stateWithPads(count: number): any
	local state = TycoonLogic.newState()
	for index = 1, count do
		assert(TycoonLogic.applyPad(state, TycoonConfig.PadOrder[index].id))
	end
	return state
end

local function areaModel(plot: Model, area: number): Instance?
	return plot:FindFirstChild(string.format("Area%02d", area))
end

local cases: { TestCase } = {
	{
		name = "World",
		run = function(ctx)
			local hub = HubBuilder.build()
			ctx.check("hub model", hub.model.Parent == Workspace)
			ctx.check("hub spawn", hub.model:FindFirstChild("Spawn") ~= nil)
			-- Owner R134: the hub has no plot teleport pads (no "Portals" trigger folder, no fallback).
			ctx.check("no plot teleport pads", hub.model:FindFirstChild("Portals") == nil)
			local plots = PlotBuilder.createPlots()
			ctx.check("8 plots", #plots == WorldLayout.PlotCount)
			for index, plot in plots do
				ctx.check(`plot {index} attributes`, plot:GetAttribute("PlotIndex") == index)
				ctx.check(`plot {index} YouAnchor`, plot:FindFirstChild("YouAnchor") ~= nil)
				ctx.check(
					`plot {index} shell`,
					plot:FindFirstChild("Frame") ~= nil or plot:FindFirstChild("Entrance") ~= nil
				)
				ctx.check(
					`plot {index} entrance on the plot`,
					WorldLayout.plotAt(PlotBuilder.entrance(index).Position) == index
				)
			end
		end,
	},
	{
		name = "Layouts",
		run = function(ctx)
			for _, area in TycoonConfig.Areas do
				local layout = AreaLayouts.get(area.index)
				local problems = LayoutLogic.validate(layout, area, MeshAssets :: any, false)
				ctx.check(`area {area.index} complete`, #problems == 0, table.concat(problems, "; "))
				ctx.metric(`source{area.index}`, AreaLayouts.source(area.index))
			end
		end,
	},
	{
		name = "Worlds",
		run = function(ctx)
			local index = testPlot()
			for _, def in WorldsConfig.extra() do
				local builder = PlotBuilder.world(def.id)
				local logic = TycoonLogic.forWorld(def.id)
				local plots = builder.createPlots()
				ctx.check(`{def.id}: 8 plots`, #plots == WorldLayout.PlotCount)
				for plotIndex, plot in plots do
					ctx.check(`{def.id} plot {plotIndex} WorldId`, plot:GetAttribute("WorldId") == def.id)
					ctx.check(
						`{def.id} plot {plotIndex} tree`,
						plot.Parent ~= nil and plot.Parent.Parent ~= nil and plot.Parent.Parent.Name == def.id
					)
					ctx.check(
						`{def.id} plot {plotIndex} entrance on its plot`,
						WorldLayout.plotAt(builder.entrance(plotIndex).Position, def.id) == plotIndex
					)
				end
				for _, area in def.economy.Areas do
					local layout = AreaLayouts.get(area.index, def.id)
					local problems = LayoutLogic.validate(layout, area, MeshAssets :: any, false, def.id)
					ctx.check(`{def.id} area {area.index} complete`, #problems == 0, table.concat(problems, "; "))
					ctx.metric(`{def.id}Source{area.index}`, AreaLayouts.source(area.index, def.id))
				end
				if not ctx.check(`{def.id}: free plot`, index ~= nil) then
					continue
				end
				local plotIndex = index :: number
				local plot = builder.getPlot(plotIndex)
				builder.clear(plotIndex)
				-- Area 1 fully bought: area 2 opens.
				local state = logic.newState()
				for _, pad in def.economy.AreaPads[1] do
					assert(logic.applyPad(state, pad.id), `{def.id}: {pad.id} applies in chain order`)
				end
				local started = os.clock()
				ctx.check(`{def.id}: restore completes`, builder.restore(plotIndex, state))
				ctx.metric(`{def.id}RestoreSeconds`, os.clock() - started)
				ctx.check(`{def.id}: PlotReady`, plot:GetAttribute("PlotReady") == true)
				local area1, area2 = areaModel(plot, 1), areaModel(plot, 2)
				ctx.check(`{def.id}: area 1 built`, area1 ~= nil and area1:FindFirstChild("Base") ~= nil)
				ctx.check(`{def.id}: area 2 opened`, area2 ~= nil and area2:FindFirstChild("Base") ~= nil)
				local producer = def.economy.Areas[1].producer.id
				ctx.check(`{def.id}: producer anchor`, builder.getProducerAnchor(plotIndex, producer) ~= nil)
				local stamped = 0
				for _, item in plot:GetDescendants() do
					if item:GetAttribute("BuildIn") ~= nil then
						stamped += 1
					end
				end
				ctx.check(`{def.id}: restore has no BuildIn`, stamped == 0, `{stamped}`)
				-- A purchase in area 2 builds in.
				local pad = def.economy.AreaPads[2][2]
				assert(
					logic.applyPad(state, def.economy.AreaPads[2][1].id) and logic.applyPad(state, pad.id),
					`{def.id}: area 2 pads apply in order`
				)
				builder.buildPurchase(plotIndex, pad.id, BUYER)
				local function build(): Instance?
					local area = areaModel(plot, 2)
					local builds = if area ~= nil then area:FindFirstChild("Builds") else nil
					return if builds ~= nil then builds:FindFirstChild(pad.build) else nil
				end
				ctx.check(
					`{def.id}: purchase builds`,
					waitFor(function()
						return build() ~= nil
					end, 20)
				)
				local model = build()
				ctx.check(`{def.id}: BuildIn stamped`, model ~= nil and type(model:GetAttribute("BuildIn")) == "number")
				builder.clear(plotIndex)
				ctx.check(`{def.id}: clear removes areas`, areaModel(plot, 1) == nil)
			end
		end,
	},
	{
		name = "Restore",
		run = function(ctx)
			local index = testPlot()
			if not ctx.check("free plot", index ~= nil) then
				return
			end
			local plotIndex = index :: number
			local plot = PlotBuilder.getPlot(plotIndex)
			PlotBuilder.clear(plotIndex)
			-- Area 1 fully bought + area 2's first pads.
			local state = stateWithPads(#TycoonConfig.AreaPads[1] + 3)
			local started = os.clock()
			ctx.check("PlotReady false while empty", plot:GetAttribute("PlotReady") == false)
			ctx.check("restore completes", PlotBuilder.restore(plotIndex, state))
			ctx.check("PlotReady after restore", plot:GetAttribute("PlotReady") == true)
			ctx.metric("restoreSeconds", os.clock() - started)
			local area1, area2 = areaModel(plot, 1), areaModel(plot, 2)
			ctx.check("area 1 built", area1 ~= nil and area1:FindFirstChild("Base") ~= nil)
			ctx.check("area 2 built (unlocked)", area2 ~= nil and area2:FindFirstChild("Base") ~= nil)
			ctx.check("area 3 not built", areaModel(plot, 3) == nil)
			local builds = if area1 ~= nil then area1:FindFirstChild("Builds") else nil
			ctx.check("A1_ToolWall built", builds ~= nil and builds:FindFirstChild("A1_ToolWall") ~= nil)
			ctx.check("no EntryArch build in area 1", builds ~= nil and builds:FindFirstChild("A2_EntryArch") == nil)
			local stamped = 0
			for _, item in plot:GetDescendants() do
				if item:GetAttribute("BuildIn") ~= nil or CollectionService:HasTag(item, PlotBuilder.Tags.BuildIn) then
					stamped += 1
				end
			end
			ctx.check("restore has no BuildIn", stamped == 0, `{stamped}`)
			ctx.check("workbench anchor", PlotBuilder.getProducerAnchor(plotIndex, "p1_workbench") ~= nil)
			ctx.check("stand anchor", PlotBuilder.getProducerAnchor(plotIndex, "p2_nuke_stand") ~= nil)
			local anchor = PlotBuilder.getProducerAnchor(plotIndex, "p1_workbench")
			local clickBox = if anchor ~= nil and anchor.Parent ~= nil
				then anchor.Parent:FindFirstChild("ClickBox")
				else nil
			ctx.check("anchor tag", anchor ~= nil and CollectionService:HasTag(anchor, PlotBuilder.Tags.Producer))
			ctx.check(
				"ClickBox + ClickDetector",
				clickBox ~= nil and clickBox:FindFirstChildOfClass("ClickDetector") ~= nil
			)
			-- Locked slots (HubLayout.lockedSlot): areas 1-2 open, 3-10 locked.
			local locked = plot:FindFirstChild("Locked")
			if locked ~= nil then
				ctx.check("area 1 slot unlocked", locked:FindFirstChild("Locked01") == nil)
				ctx.check("area 3 slot locked", locked:FindFirstChild("Locked03") ~= nil)
			end
			PlotBuilder.clear(plotIndex)
			ctx.check("clear removes areas", areaModel(plot, 1) == nil)
			ctx.check("PlotReady false after clear", plot:GetAttribute("PlotReady") == false)
		end,
	},
	{
		name = "Purchase",
		run = function(ctx)
			local index = testPlot()
			if not ctx.check("free plot", index ~= nil) then
				return
			end
			local plotIndex = index :: number
			local plot = PlotBuilder.getPlot(plotIndex)
			PlotBuilder.clear(plotIndex)
			local state = stateWithPads(1)
			PlotBuilder.restore(plotIndex, state)
			-- A normal build.
			PlotBuilder.buildPurchase(plotIndex, "a1_tool_wall", BUYER)
			local function build(): Instance?
				local area = areaModel(plot, 1)
				local builds = if area ~= nil then area:FindFirstChild("Builds") else nil
				return if builds ~= nil then builds:FindFirstChild("A1_ToolWall") else nil
			end
			ctx.check(
				"build appears",
				waitFor(function()
					return build() ~= nil
				end, 20)
			)
			local model = build()
			ctx.check("BuildIn stamped", model ~= nil and type(model:GetAttribute("BuildIn")) == "number")
			ctx.check("BuyerUserId", model ~= nil and model:GetAttribute("BuyerUserId") == BUYER.UserId)
			ctx.check("BuildIn tag", model ~= nil and CollectionService:HasTag(model, PlotBuilder.Tags.BuildIn))
			ctx.check("PadId attribute", model ~= nil and model:GetAttribute("PadId") == "a1_tool_wall")
			-- The Unlock pad builds area 2's base with AreaUnlock.
			PlotBuilder.buildPurchase(plotIndex, "a1_open_stand", BUYER)
			local function base(): Instance?
				local area = areaModel(plot, 2)
				return if area ~= nil then area:FindFirstChild("Base") else nil
			end
			ctx.check(
				"area 2 base appears",
				waitFor(function()
					return base() ~= nil
				end, 20)
			)
			local area2Base = base()
			ctx.check("AreaUnlock", area2Base ~= nil and area2Base:GetAttribute("AreaUnlock") == 2)
			ctx.check("unlock base BuildIn", area2Base ~= nil and area2Base:GetAttribute("BuildIn") ~= nil)
			-- A purchase finishing after a clear is discarded (generation guard).
			PlotBuilder.buildPurchase(plotIndex, "a1_glow_lamp", BUYER)
			PlotBuilder.clear(plotIndex)
			task.wait(1)
			ctx.check("stale build discarded", areaModel(plot, 1) == nil)
		end,
	},
	{
		name = "Pads",
		run = function(ctx)
			local index = testPlot()
			if not ctx.check("free plot", index ~= nil) then
				return
			end
			local plotIndex = index :: number
			PlotBuilder.clear(plotIndex)
			local state = stateWithPads(2)
			PlotBuilder.restore(plotIndex, state)
			PlotBuilder.syncPads(plotIndex, TycoonLogic.nextPads(state))
			local pad = PlotBuilder.getPad(plotIndex, "a1_glow_lamp")
			ctx.check("next pad shown", pad ~= nil)
			-- The pad after the Glow Lamp (Uncle Atom since owner R122) is not shown yet.
			ctx.check("only the next pad", PlotBuilder.getPad(plotIndex, "a1_uncle_atom") == nil)
			if pad ~= nil then
				ctx.check("SNPad tag", CollectionService:HasTag(pad, PlotBuilder.Tags.Pad))
				ctx.check("Cost", pad:GetAttribute("Cost") == TycoonConfig.PadsById.a1_glow_lamp.cost)
				ctx.check("Kind", pad:GetAttribute("Kind") == "Multiplier")
				ctx.check("Blurb", type(pad:GetAttribute("Blurb")) == "string")
				ctx.check("Trigger", pad:FindFirstChild("Trigger") ~= nil)
				local position = PlotBuilder.padPosition(plotIndex, "a1_glow_lamp")
				ctx.check(
					"pad on its slot",
					position ~= nil and WorldLayout.plotAt(position) == plotIndex,
					tostring(position)
				)
				PlotBuilder.pressPad(plotIndex, "a1_glow_lamp")
				ctx.check("PressedAt", type(pad:GetAttribute("PressedAt")) == "number")
				PlotBuilder.syncPads(plotIndex, {})
				ctx.check("pressed pad survives sync", pad.Parent ~= nil)
				task.wait(PlotBuilder.PadPressSeconds + 0.3)
				ctx.check("pressed pad removed", pad.Parent == nil)
			end
			PlotBuilder.clear(plotIndex)
		end,
	},
	{
		name = "Rules",
		run = function(ctx)
			local cycles = TycoonRules.catchUp(10, 0.5, 11.2, 100)
			ctx.check("catchUp", cycles == 2)
			local state = TycoonLogic.newState()
			ctx.check("tutorial starts at 1", TutorialLogic.evaluate(state, 0, 0) == 1)
			local slot = WorldLayout.slotOrigin(1, 1)
			ctx.check("slot frame upright", slot.UpVector:Dot(Vector3.yAxis) > 0.9999)
		end,
	},
}

return cases
