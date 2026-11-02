--!strict
--[[
	GlyphFamily — button glyphs that match the player's device: Xbox, PlayStation, keyboard
	(touch shows no glyphs; on-screen buttons replace them).

	Purpose:
		Hints must show the controller the player is holding. The engine already returns the
		right IMAGE per platform (UserInputService:GetImageForKeyCode gives PlayStation shapes on
		a PlayStation), so the image path needs no detection. The text FALLBACK (no engine image,
		or the Studio override below) needs the family: a PlayStation reports its face buttons as
		"ButtonCross" / "ButtonCircle" ... through GetStringForKeyCode, which this module reads
		once per gamepad connect.
		Studio-only override: LocalPlayer attribute `DevGlyphFamily = "PlayStation"` draws the
		PlayStation text glyphs on a desktop (device-matrix screenshots).

	API:
		GlyphFamily.family()                    "Xbox" | "PlayStation"
		GlyphFamily.label(keyCode)              caption for a gamepad button or keyboard key
		GlyphFamily.glyph(keyCode, height)      a GuiObject: key cap (keyboard), engine image or
		                                        round chip (gamepad)
		GlyphFamily.Changed                     fires when the family changes (gamepad swap)

	Connects to: Shared/Config/{PlatformConfig, InputConfig}, UI/Widgets/InputGlyph (key caps),
	Platform/HintBar, Platform/MenuWheel.

	Example:
		local glyph = GlyphFamily.glyph(Enum.KeyCode.ButtonA, 34)
		glyph.Parent = chip
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Create = require(script.Parent.Parent.UI.Create)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local InputGlyph = require(script.Parent.Parent.UI.Widgets.InputGlyph)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Theme = require(script.Parent.Parent.UI.Theme)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type Family = "Xbox" | "PlayStation"

local GlyphFamily = {}

GlyphFamily.Changed = Signal.new() :: Signal.Signal<Family>

local detected: Family = "Xbox"
local started = false

-- True for gamepad KeyCodes (Button*, DPad*, Thumbstick*).
local function isGamepadKey(keyCode: Enum.KeyCode): boolean
	local name = keyCode.Name
	return string.sub(name, 1, 6) == "Button"
		or string.sub(name, 1, 4) == "DPad"
		or string.sub(name, 1, 10) == "Thumbstick"
end

-- Reads the platform's name for ButtonA ("ButtonCross" on PlayStation). pcall: older clients.
local function detect(): Family
	if RunService:IsStudio() then
		local forced = Players.LocalPlayer:GetAttribute(PlatformConfig.GlyphFamilyAttr)
		if forced == "PlayStation" or forced == "Xbox" then
			return forced
		end
	end
	local ok, name = pcall(function()
		return UserInputService:GetStringForKeyCode(Enum.KeyCode.ButtonA)
	end)
	if ok and type(name) == "string" and string.find(name, "Cross", 1, true) ~= nil then
		return "PlayStation"
	end
	return "Xbox"
end

-- Re-detects and fires Changed when the family differs.
local function refresh()
	local family = detect()
	if family ~= detected then
		detected = family
		GlyphFamily.Changed:Fire(family)
	end
end

--[[ The current gamepad glyph family. ]]
function GlyphFamily.family(): Family
	return detected
end

--[[
	Caption for a key or button: PlayStation shapes / Xbox letters / keyboard key-cap text.
	Example: GlyphFamily.label(Enum.KeyCode.ButtonA) --> "A" (Xbox) or "✕" (PlayStation)
]]
function GlyphFamily.label(keyCode: Enum.KeyCode): string
	if not isGamepadKey(keyCode) then
		return InputGlyph.keyboardText(keyCode)
	end
	if detected == "PlayStation" then
		return PlatformConfig.PlayStationLabels[keyCode.Name] or keyCode.Name
	end
	return InputConfig.ButtonLabels[keyCode.Name] or keyCode.Name
end

-- Engine image for a gamepad KeyCode (platform-correct), or nil.
local function engineImage(keyCode: Enum.KeyCode): string?
	-- A Studio PlayStation override must not show the Xbox images Studio returns.
	if RunService:IsStudio() and Players.LocalPlayer:GetAttribute(PlatformConfig.GlyphFamilyAttr) ~= nil then
		return nil
	end
	local ok, image = pcall(function()
		return UserInputService:GetImageForKeyCode(keyCode)
	end)
	if ok and type(image) == "string" and image ~= "" then
		return image
	end
	return nil
end

-- A round (face buttons) or pill (shoulders / D-pad / View) chip with the family caption.
local function chip(keyCode: Enum.KeyCode, height: number): Frame
	local text = GlyphFamily.label(keyCode)
	local face = if detected == "PlayStation"
		then PlatformConfig.PlayStationColors[keyCode.Name]
		else InputConfig.ButtonColors[keyCode.Name]
	local round = face ~= nil
	local frame = Create.new("Frame", {
		Name = `Pad_{keyCode.Name}`,
		BackgroundColor3 = if detected == "PlayStation" and face ~= nil
			then UIStyleConfig.Neutral.Well
			else (face or UIStyleConfig.Neutral.Well),
		Size = UDim2.fromOffset(height, height),
		AutomaticSize = if round then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(if round then 0.5 else 0.3, 0) }),
			Create.new("UIStroke", { Color = UIStyleConfig.Neutral.Edge, Thickness = 2 }),
			Create.new("UIPadding", {
				PaddingLeft = UDim.new(0, if round then 0 else math.floor(height * 0.2)),
				PaddingRight = UDim.new(0, if round then 0 else math.floor(height * 0.2)),
			}),
		},
	}) :: Frame
	Create.new("TextLabel", {
		Name = "Caption",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(if round then 1 else 0, 1),
		AutomaticSize = if round then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
		Text = text,
		-- PlayStation shapes are drawn in their colour on a dark chip; Xbox letters are white
		-- on a coloured chip (both conventions players know).
		TextColor3 = if detected == "PlayStation" and face ~= nil then face else Theme.Colors.Text,
		FontFace = Theme.Fonts.Body,
		TextSize = math.floor(height * (if utf8.len(text) == 1 then 0.62 else 0.46)),
		Parent = frame,
	})
	return frame
end

--[[
	A glyph for `keyCode`: keyboard key cap, else the engine's gamepad image, else a chip.
	@param keyCode keyboard key or gamepad button
	@param height  design px
	Example: GlyphFamily.glyph(Enum.KeyCode.F, 34)
]]
function GlyphFamily.glyph(keyCode: Enum.KeyCode, height: number): GuiObject
	if not isGamepadKey(keyCode) then
		return InputGlyph.keyboard(keyCode, height)
	end
	local image = engineImage(keyCode)
	if image ~= nil then
		return Create.new("ImageLabel", {
			Name = `Pad_{keyCode.Name}`,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(height, height),
			Image = image,
			ScaleType = Enum.ScaleType.Fit,
		}) :: ImageLabel
	end
	return chip(keyCode, height)
end

--[[ Starts family detection (once): on boot, gamepad connect / disconnect, Studio override. ]]
function GlyphFamily.start()
	if started then
		return
	end
	started = true
	UserInputService.GamepadConnected:Connect(refresh)
	UserInputService.GamepadDisconnected:Connect(refresh)
	if RunService:IsStudio() then
		Players.LocalPlayer:GetAttributeChangedSignal(PlatformConfig.GlyphFamilyAttr):Connect(function()
			refresh()
			-- Fire even when the family name is unchanged: the image / chip choice changed.
			GlyphFamily.Changed:Fire(detected)
		end)
	end
	refresh()
end

return GlyphFamily
