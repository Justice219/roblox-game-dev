--!strict
--[[
	PlotSign — name your plot from its entrance sign (owner R88: "allow players to name there plots
	by clicking on it and on controller being near the sign in the front").

	Purpose:
		The server tags every plot's owner-sign part (PlotNameConfig.SignTag; World/PlotBuilder).
		For each tagged sign on the LOCAL player's own plot (any world) this module hangs ONE
		client-only rig on it — nobody else sees or can use it:
			ClickBox (Part)      invisible, CanQuery, a little larger than the sign (the arch meshes
			                     are CanQuery = false, so the box is what clicks / taps hit)
			  ClickDetector      mouse hover cursor + click, touch tap → the naming window
			  Highlight          yellow outline on the sign while the mouse hovers it
			  Attachment         at chest height UNDER the sign (it hangs high on the arch), holding
			    ProximityPrompt  "Name your plot" / "Rename your plot" — controller X, keyboard E,
			                     touch tap; short hold so walking through the arch never opens it
		Both open ScreenManager "RenameStand" in plot mode (Screens/RenameStand). No unlock: every
		owner can name their plot from the start. The server validates, filters and saves
		(RenamePlot, Server/Tycoon/PlotNames); the sign shows only the server's filtered text.

	Lifecycle (event-driven, no polling): CollectionService tag added / removed (streaming in and
	out), TycoonWorld.MyWorldPlotChanged (plot ownership found / changed), ClientState
	ProfileChanged "plotName" (prompt wording), ScreenManager Opened / Closed (rigs pause while any
	modal is open, so nothing opens over a window). The rig is parented to the sign part, so a sign
	streaming out takes its rig with it.

	Connects to: Shared/Config/PlotNameConfig, Shared/Config/WorldLayout (ground height),
	Tycoon/TycoonWorld (isMine, plotOf), Client/ClientState, UI/ScreenManager, UI/Create.
	Started by Tycoon/StandSign.start (the tycoon client's sign module).

	Example: PlotSign.start()
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.UI.Create)
local PlotNameConfig = require(ReplicatedStorage.Shared.Config.PlotNameConfig)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local TycoonWorld = require(script.Parent.TycoonWorld)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local PlotSign = {}

-- The naming window (plot mode) and the rig's instance names (QA probes read them).
local SCREEN = "RenameStand"
PlotSign.ClickBoxName = "PlotSignClickBox"
PlotSign.PromptName = "PlotNamePrompt"

type Rig = {
	box: Part,
	prompt: ProximityPrompt,
	detector: ClickDetector,
	highlight: Highlight,
	connections: { RBXScriptConnection },
}

local Prompt = PlotNameConfig.Prompt
local Click = PlotNameConfig.Click

local rigs: { [BasePart]: Rig } = {}
local started = false

-- True while the player has a custom plot name (the prompt then says "Rename your plot").
local function hasCustomName(): boolean
	local profile: any = ClientState.profile
	local name = if type(profile) == "table" then profile.plotName else nil
	return type(name) == "string" and name ~= ""
end

-- Rigs are idle while ANY modal is open (nothing opens over a window; no prompt under the blur).
local function paused(): boolean
	return ScreenManager.anyModalOpen()
end

-- Opens the naming window in plot mode (never on top of another window).
local function openNaming()
	if paused() then
		return
	end
	ScreenManager.open(SCREEN, { mode = "plot" })
end

--[[
	World Y of the ground under a sign: its plot's origin height (WorldLayout; the plot model's
	PlotIndex / WorldId attributes). Falls back to the sign's own height minus a typical arch
	height when the attributes are missing.
]]
local function groundY(sign: BasePart): number
	local plot = TycoonWorld.plotOf(sign)
	local index = if plot ~= nil then plot:GetAttribute("PlotIndex") else nil
	local worldId = if plot ~= nil then plot:GetAttribute("WorldId") else nil
	if type(index) == "number" then
		local ok, origin = pcall(
			WorldLayout.plotOrigin,
			index,
			if type(worldId) == "string" and WorldsConfig.get(worldId) ~= nil then worldId else nil
		)
		if ok and typeof(origin) == "CFrame" then
			return origin.Position.Y
		end
	end
	return sign.Position.Y - 18
end

-- Applies the current wording + pause state to one rig.
local function syncRig(rig: Rig)
	local idle = paused()
	rig.prompt.ActionText = if hasCustomName() then Prompt.ActionTextRename else Prompt.ActionText
	rig.prompt.Enabled = not idle
	rig.detector.MaxActivationDistance = if idle then 0 else Click.MaxDistance
	if idle then
		rig.highlight.Enabled = false
	end
end

--[[
	Builds the client-only naming rig on one of the player's own signs (see the header).
	@param sign BasePart — a tagged owner-sign part of the local player's plot
	@return Rig
]]
local function buildRig(sign: BasePart): Rig
	local padding = Vector3.one * (Click.Padding * 2)
	local box = Create.new("Part", {
		Name = PlotSign.ClickBoxName,
		Anchored = true,
		CanCollide = false,
		CanTouch = false,
		CanQuery = true,
		CastShadow = false,
		Massless = true,
		Transparency = 1,
		Size = sign.Size + padding,
		CFrame = sign.CFrame,
	}) :: Part
	local detector = Create.new("ClickDetector", {
		MaxActivationDistance = Click.MaxDistance,
		Parent = box,
	}) :: ClickDetector
	local Highlights = PlotNameConfig.Highlight
	local highlight = Create.new("Highlight", {
		Adornee = sign,
		Enabled = false,
		DepthMode = Enum.HighlightDepthMode.Occluded,
		FillColor = Highlights.FillColor,
		FillTransparency = Highlights.FillTransparency,
		OutlineColor = Highlights.OutlineColor,
		OutlineTransparency = Highlights.OutlineTransparency,
		Parent = box,
	}) :: Highlight
	-- The prompt sits under the sign at chest height (where the owner walks through the arch).
	local anchor = Create.new("Attachment", { Name = "PromptAnchor", Parent = box }) :: Attachment
	anchor.WorldPosition = Vector3.new(sign.Position.X, groundY(sign) + Prompt.Height, sign.Position.Z)
	local prompt = Create.new("ProximityPrompt", {
		Name = PlotSign.PromptName,
		ActionText = Prompt.ActionText,
		ObjectText = Prompt.ObjectText,
		KeyboardKeyCode = Prompt.KeyboardKey,
		GamepadKeyCode = Prompt.GamepadKey,
		HoldDuration = Prompt.HoldSeconds,
		MaxActivationDistance = Prompt.MaxDistance,
		RequiresLineOfSight = false,
		ClickablePrompt = true,
		Parent = anchor,
	}) :: ProximityPrompt
	local rig: Rig = {
		box = box,
		prompt = prompt,
		detector = detector,
		highlight = highlight,
		connections = {},
	}
	table.insert(
		rig.connections,
		detector.MouseClick:Connect(function(clicker: Player)
			if clicker == Players.LocalPlayer then
				openNaming()
			end
		end)
	)
	table.insert(
		rig.connections,
		detector.MouseHoverEnter:Connect(function(hoverer: Player)
			if hoverer == Players.LocalPlayer and not paused() then
				highlight.Enabled = true
			end
		end)
	)
	table.insert(
		rig.connections,
		detector.MouseHoverLeave:Connect(function()
			highlight.Enabled = false
		end)
	)
	table.insert(rig.connections, prompt.Triggered:Connect(openNaming))
	syncRig(rig)
	box.Parent = sign -- last: the rig appears whole (and streams out with the sign)
	return rig
end

-- Removes a sign's rig (sign streamed out, untagged, or no longer the player's).
local function dropRig(sign: BasePart)
	local rig = rigs[sign]
	if rig == nil then
		return
	end
	rigs[sign] = nil
	for _, connection in rig.connections do
		connection:Disconnect()
	end
	rig.box:Destroy()
end

-- Adds / removes the rig of one tagged instance to match "is this sign on my plot?".
local function consider(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local sign = instance :: BasePart
	local mine = sign.Parent ~= nil and TycoonWorld.isMine(sign)
	if mine and rigs[sign] == nil then
		rigs[sign] = buildRig(sign)
	elseif not mine and rigs[sign] ~= nil then
		dropRig(sign)
	end
end

-- Re-checks every tagged sign (plot ownership found / changed).
local function refreshAll()
	for sign in rigs do
		if sign.Parent == nil or not TycoonWorld.isMine(sign) then
			dropRig(sign)
		end
	end
	for _, instance in CollectionService:GetTagged(PlotNameConfig.SignTag) do
		consider(instance)
	end
end

-- Re-applies wording + pause state to every rig.
local function syncAll()
	for _, rig in rigs do
		syncRig(rig)
	end
end

--[[ Starts the plot-sign naming rigs (once; StandSign.start calls it). ]]
function PlotSign.start()
	if started then
		return
	end
	started = true
	local tag = PlotNameConfig.SignTag
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance: Instance)
		-- Deferred: the sign's ancestors + plot attributes settle in the same replication step.
		task.defer(consider, instance)
	end)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance: Instance)
		if instance:IsA("BasePart") then
			dropRig(instance)
		end
	end)
	TycoonWorld.MyWorldPlotChanged:Connect(function()
		refreshAll()
	end)
	ClientState.ProfileChanged:Connect(function(_profile, fields)
		if fields == nil or table.find(fields, "plotName") ~= nil then
			syncAll()
		end
	end)
	ScreenManager.Opened:Connect(syncAll)
	ScreenManager.Closed:Connect(syncAll)
	refreshAll()
end

--[[ The live rigs' sign parts (QA probes / tests). ]]
function PlotSign.signs(): { BasePart }
	local list: { BasePart } = {}
	for sign in rigs do
		table.insert(list, sign)
	end
	return list
end

return PlotSign
