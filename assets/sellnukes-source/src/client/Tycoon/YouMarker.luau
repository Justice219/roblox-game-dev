--!strict
--[[
	YouMarker — the big yellow "YOU" + arrow floating over the local player's plot entrance
	(spec §4, reference 17), so a player in the hub always sees which plot is theirs.

	Purpose:
		Client-only (only the owner sees it). It floats over the plot's YouAnchor (an invisible part
		above the entrance arch); because plot content streams (the hub is far from the plot),
		the marker is adorned to a client Attachment under Workspace.Terrain placed at the anchor's
		position, or at the plot pivot while the anchor is streamed out, so it never disappears.
		Fixed pixel size + AlwaysOnTop: readable from the hub.

	Worlds (owner R57): the marker floats over the player's plot in the world they are in right
	now (Player attribute CurrentWorld via Tycoon/WorldLookup.current): their Nuke Town plot in
	the hub, their Dino plot in the Valley (same YouAnchor contract, Workspace.Worlds.dino.Plots).

	Currency stack (owner R102): a BillboardGui always renders UNDER the 2D HUD, so where the
	marker's projected box meets the currency stack the yellow "YOU" peeked through the counters.
	While its box covers the stack (UI/Widgets/PopupQueue.coversStack: the Top zone stretched to the
	measured stack + the phone's top-right row) the marker is hidden; it comes back once it is
	clearly clear of it (sticky margin, no flicker).

	Performance: placement is event-driven (plot change, world change, YouAnchor streaming in); the
	stack check is ONE Heartbeat connection, throttled to PopupQueueConfig.YouMarker.CheckSeconds,
	connected only while the marker has a plot to point at (one WorldToScreenPoint per check).

	Connects to: Tycoon/{TycoonWorld, TycoonContract, WorldLookup}, Kit/StudUI (text + arrow
	icon), UI/Widgets/PopupQueue (stack overlap), Shared/Config/{TycoonClientConfig,
	PopupQueueConfig}.

	Example: YouMarker.start()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Contract = require(script.Parent.TycoonContract)
local Create = require(script.Parent.Parent.UI.Create)
local PopupQueue = require(script.Parent.Parent.UI.Widgets.PopupQueue)
local PopupQueueConfig = require(ReplicatedStorage.Shared.Config.PopupQueueConfig)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local TycoonWorld = require(script.Parent.TycoonWorld)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldLookup = require(script.Parent.WorldLookup)

local Config = TycoonClientConfig.You
local Names = Contract.Names

local YouMarker = {}

local attachment: Attachment? = nil
local gui: BillboardGui? = nil
local plotConnection: RBXScriptConnection? = nil
local watchedPlot: Model? = nil -- the plot whose YouAnchor stream-in is being watched
local started = false
local wanted = false -- the marker has a plot to point at
local overStack = false -- hidden because its box covers the currency stack (R102)
local checkConnection: RBXScriptConnection? = nil
local sinceCheck = 0

-- Builds the marker once.
local function ensureGui(): BillboardGui
	local existing = gui
	if existing ~= nil then
		return existing
	end
	local point = Create.new("Attachment", { Name = "YouMarkerPoint", Parent = Workspace.Terrain }) :: Attachment
	attachment = point
	local built = Create.new("BillboardGui", {
		Name = "YouMarker",
		Adornee = point,
		Size = UDim2.fromOffset(Config.SizePx.X, Config.SizePx.Y),
		StudsOffsetWorldSpace = Config.OffsetStuds,
		MaxDistance = Config.MaxDistance,
		AlwaysOnTop = true,
		LightInfluence = 0,
		ResetOnSpawn = false,
		Enabled = false,
		Parent = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui"),
	}) :: BillboardGui
	StudUI.text({
		name = "You",
		text = "YOU",
		textSize = 64,
		font = "number",
		color = UIStyleConfig.Colors.yellow.accent,
		size = UDim2.fromScale(1, 0.55),
		parent = built,
	})
	local arrow = StudUI.icon("Arrow", 52, 2)
	arrow.AnchorPoint = Vector2.new(0.5, 0)
	arrow.Position = UDim2.fromScale(0.5, 0.55)
	arrow.Parent = built
	gui = built
	return built
end

-- Hides the marker while its projected box covers the currency stack (one throttled check).
local function checkStack()
	local marker, point = gui, attachment
	local camera = Workspace.CurrentCamera
	if marker == nil or point == nil or camera == nil then
		return
	end
	local screen = camera:WorldToScreenPoint(point.WorldPosition + Config.OffsetStuds)
	local covered = false
	if screen.Z > 0 then
		local size = Config.SizePx
		local box = { x = screen.X - size.X / 2, y = screen.Y - size.Y / 2, w = size.X, h = size.Y }
		covered = PopupQueue.coversStack(box, overStack)
	end
	overStack = covered
	marker.Enabled = wanted and not covered
end

-- Connects / disconnects the throttled stack check with `wanted`.
local function watchStack()
	if wanted and checkConnection == nil then
		sinceCheck = math.huge -- check on the first frame
		checkConnection = RunService.Heartbeat:Connect(function(dt: number)
			sinceCheck += dt
			if sinceCheck >= PopupQueueConfig.YouMarker.CheckSeconds then
				sinceCheck = 0
				checkStack()
			end
		end)
	elseif not wanted and checkConnection ~= nil then
		checkConnection:Disconnect()
		checkConnection = nil
		overStack = false
	end
end

-- Re-places the marker over the local player's plot in the current world (or hides it).
local function place()
	local marker = ensureGui()
	local plot = TycoonWorld.myPlot(WorldLookup.current())
	local point = attachment
	if plot == nil or point == nil then
		wanted = false
		marker.Enabled = false
		watchStack()
		return
	end
	local anchor = plot:FindFirstChild(Names.YouAnchor)
	local position = if anchor ~= nil and anchor:IsA("BasePart") then anchor.Position else plot:GetPivot().Position
	point.WorldPosition = position
	wanted = true
	marker.Enabled = not overStack
	watchStack()
end

-- Watches the plot for its YouAnchor streaming in (one connection, own plot only).
local function watchPlot(plot: Model?)
	watchedPlot = plot
	if plotConnection ~= nil then
		plotConnection:Disconnect()
		plotConnection = nil
	end
	if plot ~= nil then
		plotConnection = plot.DescendantAdded:Connect(function(descendant: Instance)
			if descendant.Name == Names.YouAnchor then
				place()
			end
		end)
	end
	place()
end

--[[ Starts the marker (once; TycoonClient calls it after TycoonWorld.start). ]]
function YouMarker.start()
	if started then
		return
	end
	started = true
	-- Follow the plot of the world the player is in: its plot changing, or the player travelling.
	local function follow()
		local plot = TycoonWorld.myPlot(WorldLookup.current())
		if plot ~= watchedPlot then
			watchPlot(plot)
		else
			place()
		end
	end
	TycoonWorld.MyWorldPlotChanged:Connect(follow)
	local player = Players.LocalPlayer
	if player ~= nil then
		player:GetAttributeChangedSignal(Contract.Attr.CurrentWorld):Connect(follow)
	end
	watchPlot(TycoonWorld.myPlot(WorldLookup.current()))
end

return YouMarker
