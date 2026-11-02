--!strict
--[[
	PlotWatcher — the ONE place the client discovers purchase builds and buy pads, shared by the
	build-in and world-FX controllers. Tag-based (CollectionService InstanceAdded), so it costs
	nothing per unrelated instance and works for anything placed anywhere in Workspace (tycoon
	builds by B5, event decorations by B11, ...).

	Contract (confirmed with B5 PlotBuilder, docs/build-in.md §1):
		Build: Model tagged `BuildInConfig.Tag` ("BuildIn") with attributes BuildIn (server time),
		       BuyerUserId; optional PadId, AreaIndex, AreaUnlock (area base of an Unlock purchase).
		Pad:   Model tagged `WorldFxConfig.PadTag` ("SNPad") with PadId; PressedAt set on purchase.

	Signals:
		BuildAdded(model, info)  info = { age, buyerUserId, isBuyer, padId?, areaIndex?, isAreaBase }.
		                         Fired one frame after arrival (task.defer) so the whole Atomic
		                         model has finished replicating.
		PadAdded(model)

	Trust: attribute values are display input from the server; type-checked here; they only
	drive visuals and sounds.

	Example:
		PlotWatcher.BuildAdded:Connect(function(model, info) ... end)
		PlotWatcher.start()
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BuildInConfig = require(ReplicatedStorage.Shared.Config.BuildInConfig)
local WorldFxConfig = require(ReplicatedStorage.Shared.Config.WorldFxConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type BuildInfo = {
	age: number, -- seconds since the server stamped BuildIn (>= 0)
	buyerUserId: number,
	isBuyer: boolean,
	padId: string?,
	areaIndex: number?,
	isAreaBase: boolean, -- the base of an area opened by an Unlock purchase -> fanfare
}

local PlotWatcher = {}

PlotWatcher.BuildAdded = Signal.new() :: Signal.Signal<Model, BuildInfo>
PlotWatcher.PadAdded = Signal.new() :: Signal.Signal<Model>

local started = false
-- Instances already reported (weak keys: destroyed ones drop out by themselves).
local seen: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- A finite number attribute, else nil.
local function numberAttr(instance: Instance, name: string): number?
	local value = instance:GetAttribute(name)
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- A short string attribute, else nil.
local function stringAttr(instance: Instance, name: string): string?
	local value = instance:GetAttribute(name)
	if type(value) == "string" and #value > 0 and #value <= 120 then
		return value
	end
	return nil
end

-- The Model a tagged instance stands for (the tag may sit on the Model or one of its parts).
local function modelOf(instance: Instance): Model?
	if instance:IsA("Model") then
		return instance
	end
	return instance:FindFirstAncestorOfClass("Model")
end

local function onBuildTagged(instance: Instance)
	local model = modelOf(instance)
	if model == nil or seen[model] then
		return
	end
	local stamp = numberAttr(model, BuildInConfig.TimeAttribute)
	if stamp == nil then
		return
	end
	seen[model] = true
	-- Defer one frame: the rest of an Atomic model replicates in the same batch.
	task.defer(function()
		if model.Parent == nil then
			return
		end
		local buyer = numberAttr(model, BuildInConfig.BuyerAttribute) or 0
		local areaIndex = numberAttr(model, "AreaIndex")
		local unlock = numberAttr(model, WorldFxConfig.AreaUnlockAttribute)
		local info: BuildInfo = {
			age = math.max(Workspace:GetServerTimeNow() - stamp, 0),
			buyerUserId = buyer,
			isBuyer = buyer ~= 0 and buyer == Players.LocalPlayer.UserId,
			padId = stringAttr(model, "PadId"),
			areaIndex = areaIndex,
			isAreaBase = unlock ~= nil and unlock > 1,
		}
		PlotWatcher.BuildAdded:Fire(model, info)
	end)
end

local function onPadTagged(instance: Instance)
	local model = modelOf(instance)
	if model == nil or seen[model] or stringAttr(model, "PadId") == nil then
		return
	end
	seen[model] = true
	PlotWatcher.PadAdded:Fire(model)
end

--[[ Starts listening (idempotent); already-present tagged instances are reported too. ]]
function PlotWatcher.start()
	if started then
		return
	end
	started = true
	CollectionService:GetInstanceAddedSignal(BuildInConfig.Tag):Connect(onBuildTagged)
	CollectionService:GetInstanceAddedSignal(WorldFxConfig.PadTag):Connect(onPadTagged)
	for _, instance in CollectionService:GetTagged(BuildInConfig.Tag) do
		onBuildTagged(instance)
	end
	for _, instance in CollectionService:GetTagged(WorldFxConfig.PadTag) do
		onPadTagged(instance)
	end
end

return PlotWatcher
