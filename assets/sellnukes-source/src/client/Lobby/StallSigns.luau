--!strict
--[[
	StallSigns — captions on the lobby fixtures' own sign boards (owner R101 "the stall nametags clip
	in loby"; Shared/Config/LobbyConfig header has the root cause).

	A sign = one SurfaceGui (PlayerGui, ResetOnSpawn off) ADORNED to the art's board piece ("Sign",
	or the codes board's "Screen") on its model-side Front face (MeshPlacement.face: FBX import yaw).
	Inside: a padded frame (LobbyConfig.Sign.PadX / PadY of the board) holding the title and an
	optional status line, both TextScaled with a UITextSizeConstraint cap, so ANY text fits inside
	the board with its outline — nothing can spill past the frame or under the stall's awning, and
	short words do not balloon. Pure display: the text comes from LobbyConfig + RewardsBadges.

	Lifetime: the caller (Client/Lobby/LobbyFixtures) builds a sign when the art model streams in and
	`destroy`s it when the board leaves (streaming out / world change); text writes skip unchanged
	values, nothing runs per frame.

	Connects to: Shared/Config/{LobbyConfig, UIStyleConfig}, Shared/World/MeshPlacement, UI/Create.

	Example:
		local sign = StallSigns.build(boardPart, { title = "SUPPLY CRATES" })
		StallSigns.setStatus(sign, "SPIN NOW!", "ready")
		StallSigns.destroy(sign)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.UI.Create)
local LobbyConfig = require(ReplicatedStorage.Shared.Config.LobbyConfig)
local MeshPlacement = require(ReplicatedStorage.Shared.World.MeshPlacement)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Neutral = UIStyleConfig.Neutral
local SignTune = LobbyConfig.Sign

-- Status tones → text colour (RewardsBadges.statusText tones: "ready" | "wait" | "info" | "done").
local TONE_COLORS: { [string]: Color3 } = {
	ready = Neutral.CashGreen,
	wait = Color3.fromRGB(255, 226, 120),
	info = Neutral.Text,
	done = Neutral.TextDim,
}
-- Title colour on the cream boards / on the dark codes screen.
local TITLE_ON_LIGHT = Neutral.Text
local TITLE_ON_DARK = Color3.fromRGB(255, 214, 50)

export type Sign = {
	gui: SurfaceGui,
	title: TextLabel,
	status: TextLabel,
	statusText: string,
}

local StallSigns = {}

-- One outlined, auto-fitting caption line.
local function caption(
	parent: Instance,
	name: string,
	font: Font,
	color: Color3,
	maxSize: number,
	order: number
): TextLabel
	return Create.new("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		TextScaled = true,
		TextWrapped = false,
		FontFace = font,
		TextColor3 = color,
		LayoutOrder = order,
		Parent = parent,
		Children = {
			Create.new("UITextSizeConstraint", { MaxTextSize = maxSize, MinTextSize = 8 }),
			Create.new("UIStroke", {
				Color = Neutral.TextStroke,
				Thickness = 3,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
				LineJoinMode = Enum.LineJoinMode.Round,
			}),
		},
	}) :: TextLabel
end

-- Lays the title alone (full padded height) or title + status (TitleShare split).
local function layout(sign: Sign)
	local hasStatus = sign.statusText ~= ""
	local share = if hasStatus then SignTune.TitleShare else 1
	sign.title.Size = UDim2.fromScale(1, share)
	sign.status.Size = UDim2.fromScale(1, 1 - share)
	sign.status.Visible = hasStatus
end

--[[
	Builds a sign on `board`.
	@param board  the art piece (a MeshPart / Part of the fixture model)
	@param spec   LobbyConfig SignSpec (title, dark)
	@return Sign
]]
function StallSigns.build(board: BasePart, spec: LobbyConfig.SignSpec): Sign
	local gui = Create.new("SurfaceGui", {
		Name = "LobbySign",
		Adornee = board,
		Face = MeshPlacement.face(board, Enum.NormalId.Front),
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = SignTune.PixelsPerStud,
		LightInfluence = 0,
		MaxDistance = SignTune.MaxDistance,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}) :: SurfaceGui
	-- Padded content box: the text (and its outline) always stays inside the board's frame.
	local box = Create.new("Frame", {
		Name = "Box",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1 - 2 * SignTune.PadX, 1 - 2 * SignTune.PadY),
		Parent = gui,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
	local title = caption(
		box,
		"Title",
		UIStyleConfig.Fonts.Shout,
		if spec.dark == true then TITLE_ON_DARK else TITLE_ON_LIGHT,
		SignTune.MaxTitleSize,
		1
	)
	title.Text = spec.title
	local status = caption(box, "Status", UIStyleConfig.Fonts.Title, TONE_COLORS.wait, SignTune.MaxStatusSize, 2)
	local sign: Sign = { gui = gui, title = title, status = status, statusText = "" }
	layout(sign)
	gui.Parent = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	return sign
end

--[[
	Sets the status line (empty string = title only). Writes nothing when unchanged.
	@param tone  "ready" (green) | "info" (white) | "done" (dim) | "wait" / anything else (warm yellow)
]]
function StallSigns.setStatus(sign: Sign, text: string, tone: string?)
	local color = TONE_COLORS[tone or "wait"] or TONE_COLORS.wait
	if sign.status.TextColor3 ~= color then
		sign.status.TextColor3 = color
	end
	if sign.statusText == text then
		return
	end
	local hadStatus = sign.statusText ~= ""
	sign.statusText = text
	sign.status.Text = text
	if hadStatus ~= (text ~= "") then
		layout(sign)
	end
end

--[[ True while the sign still has its board (not streamed out / destroyed). ]]
function StallSigns.alive(sign: Sign): boolean
	local adornee = sign.gui.Adornee
	return adornee ~= nil and adornee.Parent ~= nil and sign.gui.Parent ~= nil
end

--[[ Removes the sign. ]]
function StallSigns.destroy(sign: Sign)
	sign.gui:Destroy()
end

return table.freeze(StallSigns)
