--!strict
--[[
	WorldUnlockedScreen — the WORLD UNLOCKED! stud popup (owner R57 World 2, spec §4.2 / §14).

	Two modes (args from Worlds/WorldClient):
		{ worldId, mode = "unlocked" }  the once-per-join celebration, opened at a polite moment:
		    a rotating 3D Time Machine (R39 ModelViewport; icon fallback while the mesh is not
		    uploaded), "DINO VALLEY UNLOCKED! A whole new world with its own Bones, dino pets and
		    rebirths. Your Nuke Town keeps earning while you're away!" and two buttons:
		    GO NOW! (default selection) -> WorldClient.travel(world, "spawn", nil, "popup")
		    LATER (B / X / the red X close)
		{ worldId, mode = "locked" }    the locked preview (a locked portal / tab): "Reach BoomDash
		    Delivery: 6 / 9 purchases" + a progress bar + OK. Never sends anything.
	Starburst + confetti tone in unlocked mode; the plain stud window in locked mode.

	Worlds (R70, every extra world): the turntable model, the header icon and the "{pets}" word of
	the body come from the world's portal (WorldClientLogic.portal: WorldClientConfig.Portals —
	Dino the Time Machine, Moon Base the rocket), and the locked preview measures progress in the
	unlock rule's OWN world (not always Nuke Town).

	Security: GO NOW only sends the travel intent; the server re-validates the unlock.

	Analytics (W12, rule 9): each open reports ClientAnalytics.screenOpened("WorldUnlocked",
	args.source: "auto" for the celebration, "portal" / "hud" for a locked preview) and
	ClientAnalytics.worldPopup(world, action): "shown" / "lockedPreview" on open, then "go" (GO
	NOW) or "later" (closed any other way) for the celebration.

	Connects to: Worlds/{WorldClient, WorldClientLogic}, Kit/StudUI (modalScreen, button, text,
	progressBar), Widgets/{ModelViewport, StudWindow}, UI/{ScreenManager, Create}, Client/ClientState,
	Analytics/ClientAnalytics, Shared/Config/{WorldClientConfig, Worlds/WorldsConfig}.

	Example: ScreenManager.open("WorldUnlocked", { worldId = "dino", mode = "unlocked" })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientAnalytics = require(script.Parent.Parent.Parent.Parent.Analytics.ClientAnalytics)
local ClientState = require(script.Parent.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Parent.Create)
local ModelViewport = require(script.Parent.Parent.Parent.Widgets.ModelViewport)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local WorldClient = require(script.Parent.Parent.Parent.Parent.Worlds.WorldClient)
local WorldClientConfig = require(ReplicatedStorage.Shared.Config.WorldClientConfig)
local WorldClientLogic = require(script.Parent.Parent.Parent.Parent.Worlds.WorldClientLogic)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local NAME = WorldClient.UnlockScreen
local Unlock = WorldClientConfig.Unlock
local WINDOW_SIZE = Vector2.new(1000, 640)
local MODEL_SIZE = 380

return StudUI.modalScreen({
	name = NAME,
	title = Unlock.Title,
	color = "green",
	icon = Unlock.ModelIcon, -- replaced per world on every open (window.setIcon, portal icon)
	size = WINDOW_SIZE,
	displayOrder = 24,
	build = function(window: StudUI.Window): any
		local body = window.body
		-- The first extra world until onOpen names one (args are always given by WorldClient).
		local firstExtra = WorldsConfig.extra()[1]
		local worldId = if firstExtra ~= nil then firstExtra.id else WorldsConfig.MAIN
		local mode = "unlocked"
		-- True once GO NOW was pressed this open (else closing = "later" for the analytics).
		local went = false

		-- Left: the world's rotating portal on a soft sunburst (R39 3D model, icon fallback).
		local stage = Create.new("Frame", {
			Name = "Stage",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(20, 20),
			Size = UDim2.fromOffset(MODEL_SIZE + 40, MODEL_SIZE + 40),
			Parent = body,
		}) :: Frame
		StudWindow.sunburst(stage, { zIndex = 1 })
		local model = ModelViewport.new({
			key = Unlock.ModelKey,
			icon = Unlock.ModelIcon,
			size = UDim2.fromOffset(MODEL_SIZE, MODEL_SIZE),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
			zIndex = 3,
			spin = true,
			name = "PortalModel",
			parent = stage,
		})

		-- Right: the message (+ the locked-mode progress bar).
		local textX = MODEL_SIZE + 80
		local message = StudUI.text({
			text = "",
			textSize = 34,
			wrap = true,
			align = Enum.TextXAlignment.Left,
			alignY = Enum.TextYAlignment.Top,
			position = UDim2.fromOffset(textX, 30),
			size = UDim2.new(1, -(textX + 30), 0, 250),
			parent = body,
		})
		local bar = StudUI.progressBar({ color = "sky", size = UDim2.new(1, -(textX + 30), 0, 30), parent = body })
		bar.frame.Position = UDim2.fromOffset(textX, 300)

		-- Buttons (bottom right): GO NOW! + LATER, or OK in locked mode.
		local goNow = StudUI.button({
			text = Unlock.Go,
			color = "green",
			size = UDim2.fromOffset(280, 88),
			textSize = 40,
			position = UDim2.new(1, -330, 1, -30),
			anchor = Vector2.new(1, 1),
			name = "GoNow",
			parent = body,
			onActivated = function()
				went = true
				ClientAnalytics.worldPopup(worldId, "go")
				ScreenManager.close(NAME)
				WorldClient.travel(worldId, "spawn", nil, "popup")
			end,
		})
		local later = StudUI.button({
			text = Unlock.Later,
			color = "grey",
			size = UDim2.fromOffset(260, 88),
			textSize = 36,
			position = UDim2.new(1, -30, 1, -30),
			anchor = Vector2.new(1, 1),
			name = "Later",
			parent = body,
			onActivated = function()
				ScreenManager.close(NAME)
			end,
		})
		goNow.instance.NextSelectionRight = later.instance;
		(later.instance :: any).NextSelectionLeft = goNow.instance

		-- Fills the window for the current world + mode.
		local function render()
			local def = WorldsConfig.get(worldId)
			local name = if def ~= nil then def.name else WorldClientLogic.style(worldId).label
			local currency = if def ~= nil then def.currency.name else "coins"
			-- This world's portal: turntable model + header icon (no-op when unchanged).
			local portal = WorldClientLogic.portal(worldId)
			model.set({ key = portal.model }, portal.icon)
			window.setIcon(portal.icon)
			if mode == "locked" then
				-- Progress is measured in the unlock rule's own world (Nuke Town today for both).
				local profile: any = ClientState.profile
				local ruleWorld = if def ~= nil and def.unlock.kind == "progress"
					then (def.unlock :: any).world
					else WorldsConfig.MAIN
				local source = if ruleWorld == WorldsConfig.MAIN then profile else ClientState.world(ruleWorld)
				local tycoon = if type(source) == "table" then source.tycoon else nil
				local _, areaName, bought, total = WorldClientLogic.lockHint(worldId, tycoon)
				window.setTitle(`{string.upper(name)}: {Unlock.LockedTitle}`)
				window.setColor("grey")
				message.Text = WorldClientLogic.fill(
					Unlock.LockedBody,
					{ area = areaName, bought = tostring(bought), total = tostring(total) }
				)
				bar.frame.Visible = total > 0
				bar.setProgress(if total > 0 then bought / total else 0)
				goNow.instance.Visible = false
				later.setText(Unlock.Ok)
				later.setColor("green")
			else
				window.setTitle(Unlock.Title)
				window.setColor(WorldClientLogic.style(worldId).color :: any)
				message.Text = WorldClientLogic.fill(
					Unlock.Body,
					{ world = string.upper(name), currency = currency, pets = portal.pets }
				)
				bar.frame.Visible = false
				goNow.instance.Visible = true
				later.setText(Unlock.Later)
				later.setColor("grey")
			end
		end

		return {
			onOpen = function(args: any?)
				local raw = if type(args) == "table" then args else {}
				worldId = if type(raw.worldId) == "string" and WorldsConfig.get(raw.worldId) ~= nil
					then raw.worldId
					else worldId
				mode = if raw.mode == "locked" then "locked" else "unlocked"
				went = false
				render()
				model.setSpin(true)
				local source = if type(raw.source) == "string" then raw.source else "auto"
				ClientAnalytics.screenOpened(NAME, source)
				ClientAnalytics.worldPopup(worldId, if mode == "locked" then "lockedPreview" else "shown")
			end,
			onClose = function()
				model.setSpin(false)
				if mode == "unlocked" and not went then
					ClientAnalytics.worldPopup(worldId, "later")
				end
			end,
			defaultSelection = function(): GuiObject?
				return if goNow.instance.Visible then goNow.instance else later.instance
			end,
		}
	end,
})
