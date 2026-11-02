--!strict
--[[
	InputGlyph — button prompts that follow the player's device (ported from RoBeasts).

	Purpose:
		Prompts like "[E] Upgrade" or a modal's "[X] close" chip must show the right thing for
		the device in use: a key cap on keyboard, the Xbox button image on a gamepad, nothing (or
		a tap hint) on touch. Gamepad images come from UserInputService:GetImageForKeyCode
		(built-in engine textures, no uploads), with a text-cap fallback.

	API:
		InputGlyph.keyCap(text, height?)              static white key cap with a dark lip
		InputGlyph.keyboard(keyCode, height?)         key cap for a KeyCode
		InputGlyph.gamepad(keyCode, height?)          Xbox button image (text fallback)
		InputGlyph.dynamic(keyboard?, gamepad?, h?)   switches with the input mode; collapses in
		                                              Touch mode (a finger has no keys)
		InputGlyph.action(action, height?)            dynamic glyph for an InputConfig action

	Connects to: Shared/Config/InputConfig (labels), Controllers/InputController (mode),
	UI/Components (hideInTouch), Kit/StudUI (window close chip), Tycoon client prompts.

	Example:
		local hint = InputGlyph.dynamic(InputConfig.CloseKey, InputConfig.BackButton, 30)
		hint.Parent = footer
		InputGlyph.action("Interact", 32).Parent = upgradePrompt
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Components = require(script.Parent.Parent.Components)
local Create = require(script.Parent.Parent.Create)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local InputController = require(script.Parent.Parent.Parent.Controllers.InputController)
local Theme = require(script.Parent.Parent.Theme)

local InputGlyph = {}

local DEFAULT_HEIGHT = 34

--[[
	A static key cap: white rounded rectangle with dark text and a darker lip under it.
	@param text   label on the cap (e.g. "E", "Space")
	@param height px height at 1080p (width grows with the text)
	Example: InputGlyph.keyCap("E", 30)
]]
function InputGlyph.keyCap(text: string, height: number?): Frame
	local h = height or DEFAULT_HEIGHT
	-- The holder IS the lip: 3 px taller than the face so its darker background peeks out under
	-- it. Its width follows the face's automatic (text-driven) width.
	local holder = Create.new("Frame", {
		Name = `Key_{text}`,
		BackgroundColor3 = Theme.Colors.TextDim,
		Size = UDim2.fromOffset(0, h + 3),
		AutomaticSize = Enum.AutomaticSize.X,
		Children = { Components.corner(Theme.CornerSmall), Components.stroke(Theme.Colors.Edge, 2) },
	}) :: Frame
	Create.new("TextLabel", {
		Name = "Face",
		BackgroundColor3 = Theme.Colors.Text,
		Size = UDim2.fromOffset(h, h),
		AutomaticSize = Enum.AutomaticSize.X,
		Text = text,
		TextColor3 = Theme.Colors.TextDark,
		FontFace = Theme.Fonts.Body,
		TextSize = math.floor(h * 0.55),
		Parent = holder,
		Children = {
			Components.corner(Theme.CornerSmall),
			Create.new("UIPadding", {
				PaddingLeft = UDim.new(0, math.floor(h * 0.22)),
				PaddingRight = UDim.new(0, math.floor(h * 0.22)),
			}),
		},
	})
	return holder
end

--[[ Key-cap text for a keyboard KeyCode (InputConfig.KeyLabels, else the Enum name). ]]
function InputGlyph.keyboardText(keyCode: Enum.KeyCode): string
	return InputConfig.KeyLabels[keyCode.Name] or keyCode.Name
end

--[[ A static key cap for a keyboard key. ]]
function InputGlyph.keyboard(keyCode: Enum.KeyCode, height: number?): Frame
	return InputGlyph.keyCap(InputGlyph.keyboardText(keyCode), height)
end

-- Engine image for a gamepad KeyCode, or nil if unavailable.
local function gamepadImage(keyCode: Enum.KeyCode): string?
	local ok, imageId = pcall(function()
		return UserInputService:GetImageForKeyCode(keyCode)
	end)
	if ok and type(imageId) == "string" and imageId ~= "" then
		return imageId
	end
	return nil
end

--[[ A static Xbox button glyph (engine image; text cap fallback). ]]
function InputGlyph.gamepad(keyCode: Enum.KeyCode, height: number?): GuiObject
	local h = height or DEFAULT_HEIGHT
	local imageId = gamepadImage(keyCode)
	if imageId ~= nil then
		return Create.new("ImageLabel", {
			Name = `Pad_{keyCode.Name}`,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(h, h),
			Image = imageId,
			ScaleType = Enum.ScaleType.Fit,
		}) :: ImageLabel
	end
	return InputGlyph.keyCap(InputConfig.ButtonLabels[keyCode.Name] or keyCode.Name, h)
end

--[[
	A prompt that shows `keyboard` for keyboard/mouse players and `gamepad` for controller
	players, swapping live when the player switches devices; collapses in Touch mode.
	Either side may be nil (that side then shows nothing).
	Example: InputGlyph.dynamic(InputConfig.CloseKey, InputConfig.BackButton, 30)
]]
function InputGlyph.dynamic(keyboard: Enum.KeyCode?, gamepad: Enum.KeyCode?, height: number?): Frame
	local h = height or DEFAULT_HEIGHT
	local frame = Create.new("Frame", {
		Name = "DynamicGlyph",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, h + 3),
		AutomaticSize = Enum.AutomaticSize.X,
	}) :: Frame
	local keyGlyph: GuiObject? = if keyboard ~= nil then InputGlyph.keyboard(keyboard, h) else nil
	local padGlyph: GuiObject? = if gamepad ~= nil then InputGlyph.gamepad(gamepad, h) else nil
	if keyGlyph ~= nil then
		keyGlyph.Parent = frame
	end
	if padGlyph ~= nil then
		padGlyph.Parent = frame
	end
	Components.hideInTouch(frame)
	local function render()
		local pad = InputController.mode == "Gamepad"
		if keyGlyph ~= nil then
			keyGlyph.Visible = not pad
		end
		if padGlyph ~= nil then
			padGlyph.Visible = pad
		end
	end
	render()
	local connection = InputController.ModeChanged:Connect(render)
	frame.Destroying:Once(function()
		connection:Disconnect()
	end)
	return frame
end

--[[
	A dynamic glyph for an InputConfig action (its first key and first gamepad button).
	Example: InputGlyph.action("Interact", 30) -- [E] / (X)
]]
function InputGlyph.action(action: InputConfig.ActionName, height: number?): Frame
	local binding = InputConfig.Actions[action]
	return InputGlyph.dynamic(binding.keys[1], binding.buttons[1], height)
end

return table.freeze(InputGlyph)
