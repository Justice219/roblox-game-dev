--!strict
--[[
	RenameStand — the naming window (reference 10): a text box with the current name and red CANCEL /
	green CONFIRM buttons. Two modes share the one window (args.mode on open):
		"stand" (default)  "Name your stand!" — opened by the stand-sign ProximityPrompt
		                   (Tycoon/StandSign) once the player owns the StandRename feature;
		                   sends RenameStand(name).
		"plot"             owner R88 "Name your plot!" — opened by a click / tap on the player's own
		                   entrance sign or its walk-up prompt (Tycoon/PlotSign), no unlock. Adds a
		                   blue RESET button (back to "<DisplayName>'s Nukes"); sends RenamePlot(name)
		                   or RenamePlot("") for the reset.
	Re-opening while open switches the mode (ScreenManager re-runs onOpen with the new args).

	Console + mobile (owner R11): the text box is the default gamepad selection (A opens the
	on-screen keyboard on console; tapping it opens the phone keyboard; Enter / Done confirms), the
	buttons are gamepad-selectable, B / Back and the X close it (modalScreen closeOnBack).

	Security: the client only cleans the text (PlotNameLogic.clean: UTF-8, no control characters,
	invisible characters dropped, spaces collapsed, 1..cap characters) before sending the INTENT;
	the server re-validates, rate-limits, filters with TextService and checks the feature / plot.
	Signs show only the server's filtered names (plot attributes StandName / PlotName).

	Connects to: Kit/StudUI, UI/ScreenManager, Client/ClientState (current names: tycoon.standName,
	plotName), Shared/Net/Remotes ("RenameStand", "RenamePlot"), Shared/Tycoon/PlotNameLogic,
	Shared/Config/{TycoonClientConfig, PlotNameConfig}.

	Example:
		ScreenManager.open("RenameStand")                     -- the stand sign
		ScreenManager.open("RenameStand", { mode = "plot" })  -- the plot's entrance sign (R88)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Create)
local PlotNameConfig = require(ReplicatedStorage.Shared.Config.PlotNameConfig)
local PlotNameLogic = require(ReplicatedStorage.Shared.Tycoon.PlotNameLogic)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)

local NAME = "RenameStand"

type Mode = "stand" | "plot"

-- Per-mode copy + limits (the plot copy lives in PlotNameConfig, shared with the server's toasts).
type ModeSpec = {
	title: string,
	heading: string,
	hint: string, -- "%d" = the cap
	placeholder: () -> string,
	maxLength: number,
	remote: Remotes.EventName,
	current: (profile: any) -> string,
	reset: boolean, -- shows the RESET button
}

local PlotCopy = PlotNameConfig.Copy

local MODES: { [Mode]: ModeSpec } = {
	stand = {
		title = "Rename Stand",
		heading = "Name your stand!",
		hint = "Up to %d letters. Everyone sees it on your sign.",
		placeholder = function(): string
			return "My Nuke Stand"
		end,
		maxLength = TycoonClientConfig.RenameMaxLength,
		remote = "RenameStand",
		current = function(profile: any): string
			local tycoon = if type(profile) == "table" then profile.tycoon else nil
			local name = if type(tycoon) == "table" then tycoon.standName else nil
			return if type(name) == "string" then name else ""
		end,
		reset = false,
	},
	plot = {
		title = PlotCopy.Title,
		heading = PlotCopy.Heading,
		hint = PlotCopy.Hint,
		-- The default sign text as the placeholder ("Sam's Nukes"): what RESET brings back.
		placeholder = function(): string
			local player = Players.LocalPlayer
			return PlotNameLogic.defaultName(
				if player ~= nil then player.DisplayName else "Your",
				PlotNameConfig.MainSuffix
			)
		end,
		maxLength = PlotNameConfig.MaxChars,
		remote = "RenamePlot",
		current = function(profile: any): string
			local name = if type(profile) == "table" then profile.plotName else nil
			return if type(name) == "string" then name else ""
		end,
		reset = true,
	},
}

-- The typing cap of the shared text box (each mode re-checks its own cap before sending).
local BOX_MAX = math.max(MODES.stand.maxLength, MODES.plot.maxLength)

-- Reads the mode from the open args (anything but "plot" is the stand: old callers unchanged).
local function modeOf(args: any?): Mode
	if type(args) == "table" and args.mode == "plot" then
		return "plot"
	end
	return "stand"
end

return StudUI.modalScreen({
	name = NAME,
	title = MODES.stand.title,
	color = "orange",
	icon = "Codes",
	size = Vector2.new(880, 480),
	build = function(window: StudUI.Window): any
		local mode: Mode = "stand"
		local body = window.body
		Create.new("UIListLayout", {
			Padding = UDim.new(0, 18),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = body,
		})
		local heading = StudUI.text({
			text = MODES.stand.heading,
			textSize = 52,
			size = UDim2.new(1, 0, 0, 60),
			layoutOrder = 1,
			parent = body,
		})
		local hint = StudUI.text({
			text = string.format(MODES.stand.hint, MODES.stand.maxLength),
			textSize = 26,
			color = Color3.fromRGB(196, 204, 222),
			size = UDim2.new(1, 0, 0, 32),
			layoutOrder = 2,
			parent = body,
		})
		-- Filled in below once `submit` exists (Enter in the box confirms).
		local actions = { submit = function() end }
		local box = StudUI.textBox({
			placeholder = MODES.stand.placeholder(),
			maxLength = BOX_MAX,
			size = UDim2.fromOffset(680, 92),
			layoutOrder = 3,
			parent = body,
			onSubmit = function()
				actions.submit()
			end,
		})
		local row = Create.new("Frame", {
			Name = "Buttons",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 84),
			LayoutOrder = 4,
			Parent = body,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, 24),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame
		StudUI.button({
			text = "CANCEL",
			color = "red",
			size = UDim2.fromOffset(240, 72),
			layoutOrder = 1,
			parent = row,
			onActivated = function()
				ScreenManager.close(NAME)
			end,
		})
		-- Owner R88 (plot mode only): back to the default "<DisplayName>'s Nukes".
		local resetButton = StudUI.button({
			text = PlotCopy.ResetButton,
			color = "blue",
			size = UDim2.fromOffset(240, 72),
			layoutOrder = 2,
			name = "Button_RESET",
			parent = row,
			onActivated = function()
				local spec = MODES[mode]
				if not spec.reset then
					return
				end
				if spec.current(ClientState.profile) == "" then
					hint.Text = PlotCopy.HintAlreadyDefault
					return
				end
				Remotes.event(spec.remote):FireServer("")
				ScreenManager.close(NAME)
			end,
		})
		resetButton.instance.Visible = false
		-- Sends the intent when the name is valid; otherwise explains why in the hint line.
		local function submit()
			local spec = MODES[mode]
			local name = PlotNameLogic.clean(box.text(), spec.maxLength)
			if name == nil then
				hint.Text = string.format(PlotCopy.HintEmpty, spec.maxLength)
				return
			end
			if spec.reset and name == spec.current(ClientState.profile) then
				hint.Text = PlotCopy.Same
				return
			end
			Remotes.event(spec.remote):FireServer(name)
			ScreenManager.close(NAME)
		end
		actions.submit = submit
		StudUI.button({
			text = "CONFIRM",
			color = "green",
			size = UDim2.fromOffset(240, 72),
			layoutOrder = 3,
			parent = row,
			onActivated = submit,
		})
		return {
			onOpen = function(args: any?)
				mode = modeOf(args)
				local spec = MODES[mode]
				window.setTitle(spec.title)
				heading.Text = spec.heading
				hint.Text = string.format(spec.hint, spec.maxLength)
				box.instance.PlaceholderText = spec.placeholder()
				box.instance.Text = spec.current(ClientState.profile)
				resetButton.instance.Visible = spec.reset
			end,
			defaultSelection = function(): GuiObject?
				return box.instance
			end,
		}
	end,
})
