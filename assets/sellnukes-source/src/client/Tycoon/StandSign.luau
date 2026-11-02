--!strict
--[[
	StandSign — the "Rename" prompt on the player's stand sign (reference 10).

	Purpose:
		Renaming unlocks with the StandRename feature (it rides on the Nuke Stand's Neon Sign pad,
		TycoonConfig.FeaturePadOf.StandRename). Once the player owns it, a client ProximityPrompt
		("Rename", R / D-pad up / tap) sits on that pad's build model and opens the RenameStand
		screen. ProximityPrompt handles keyboard, gamepad and touch natively; only the owner sees
		it (client-created). The server still checks the feature + filters the text.

	Performance: event-driven (profile tycoon changes, plot change, the build streaming in).

	Owner R88: start() also starts Tycoon/PlotSign — the click / tap / walk-up "Name your plot" rig
	on the player's own ENTRANCE sign (no unlock), which opens the same window in plot mode.

	Connects to: Client/ClientState, Tycoon/TycoonWorld, UI/ScreenManager (RenameStand),
	Shared/Tycoon/TycoonLogic (hasFeature), Shared/Config/TycoonConfig, Tycoon/PlotSign (R88).

	Example: StandSign.start()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.UI.Create)
local PlotSign = require(script.Parent.PlotSign)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonWorld = require(script.Parent.TycoonWorld)

local StandSign = {}

local FEATURE = "StandRename"
local prompt: ProximityPrompt? = nil
local plotConnection: RBXScriptConnection? = nil
local started = false

-- The build key of the sign (the StandRename feature pad's build), or "".
local function signBuildKey(): string
	local padId = TycoonConfig.FeaturePadOf[FEATURE]
	local pad = if padId ~= nil then TycoonConfig.PadsById[padId] else nil
	return if pad ~= nil then pad.build else ""
end

-- Adds / moves / removes the prompt for the current profile + world.
local function refresh()
	local profile = ClientState.profile
	local owns = profile ~= nil
		and type(profile.tycoon) == "table"
		and TycoonLogic.hasFeature(profile.tycoon :: any, FEATURE)
	local build = if owns then TycoonWorld.myBuild(signBuildKey()) else nil
	local part = if build ~= nil then (build.PrimaryPart or build:FindFirstChildWhichIsA("BasePart", true)) else nil
	if part == nil then
		if prompt ~= nil then
			prompt:Destroy()
			prompt = nil
		end
		return
	end
	local current = prompt
	if current ~= nil and current.Parent == part then
		return
	end
	if current ~= nil then
		current:Destroy()
	end
	local created = Create.new("ProximityPrompt", {
		Name = "RenameStandPrompt",
		ActionText = "Rename",
		ObjectText = "Stand sign",
		KeyboardKeyCode = Enum.KeyCode.R,
		GamepadKeyCode = Enum.KeyCode.DPadUp,
		HoldDuration = 0,
		MaxActivationDistance = 14,
		RequiresLineOfSight = false,
		Parent = part,
	}) :: ProximityPrompt
	created.Triggered:Connect(function()
		ScreenManager.open("RenameStand", { mode = "stand" })
	end)
	prompt = created
end

-- Watches the own plot for the sign build streaming in.
local function watchPlot(plot: Model?)
	if plotConnection ~= nil then
		plotConnection:Disconnect()
		plotConnection = nil
	end
	if plot ~= nil then
		local key = signBuildKey()
		plotConnection = plot.DescendantAdded:Connect(function(descendant: Instance)
			if descendant.Name == key then
				task.defer(refresh)
			end
		end)
	end
	refresh()
end

--[[ Starts the sign prompt (once; TycoonClient calls it) and the R88 plot-sign naming rig. ]]
function StandSign.start()
	if started then
		return
	end
	started = true
	PlotSign.start()
	ClientState.ProfileChanged:Connect(function(_profile, fields)
		if fields == nil or table.find(fields, "tycoon") ~= nil then
			refresh()
		end
	end)
	TycoonWorld.MyPlotChanged:Connect(watchPlot)
	watchPlot(TycoonWorld.myPlot())
end

return StandSign
