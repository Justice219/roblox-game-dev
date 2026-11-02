--!strict
--[[
	LobbyBubbles — the lobby visitors' speech bubbles (owner R100 "walk around and talk"): a white
	stud bubble with a tail and a short dark line over a visitor's head, popping in with a UIScale
	tween (instant with reduced motion). The same look as the manager speech bubbles (Tycoon/Npc/
	ManagerTags) so every NPC in the game "talks" alike; stud panels per owner rule 2.

	Sizing (owner R11): studs + a pixel floor (UDim2 scale + offset), width from the line length, so
	it shrinks with distance like the world but stays readable on phones / TVs (DeviceScale).
	Lifetime + performance: BillboardGuis live in PlayerGui (ResetOnSpawn off) and are ADORNED to the
	visitor's Head, so they follow the animated rig with no per-frame writes; built once, pooled
	(`acquire` / `release`), MaxDistance culled, AlwaysOnTop off (walls hide them). The single pop
	tween per bubble is created once.

	Connects to: Shared/Config/{LobbyNpcConfig (Bubble), UIStyleConfig}, UI/{Create, Widgets/StudWindow};
	used by Client/Lobby/LobbyNpcs.

	Example:
		local bubble = LobbyBubbles.acquire()
		if bubble ~= nil then LobbyBubbles.show(bubble, head, "Nukey says hi!", false, false) end
		LobbyBubbles.release(bubble)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Create = require(script.Parent.Parent.UI.Create)
local LobbyNpcConfig = require(ReplicatedStorage.Shared.Config.LobbyNpcConfig)
local StudWindow = require(script.Parent.Parent.UI.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Bubble = LobbyNpcConfig.Bubble
local BUBBLE_TEXT = Color3.fromRGB(40, 48, 84) -- dark navy on the white stud panel
local POOL_CAP = 4

export type BubbleVisual = {
	gui: BillboardGui,
	label: TextLabel,
	scale: UIScale,
	pop: Tween,
}

local LobbyBubbles = {}

local pool: { BubbleVisual } = {}

local function playerGui(): Instance?
	return Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
end

-- Builds one hidden bubble under `parent`.
local function build(parent: Instance): BubbleVisual
	local gui = Create.new("BillboardGui", {
		Name = "LobbyBubble",
		Size = UDim2.new(4, 80, Bubble.StudsHeight, Bubble.PixelHeight),
		LightInfluence = 0,
		AlwaysOnTop = false,
		ClipsDescendants = false,
		ResetOnSpawn = false,
		Active = false,
		Enabled = false,
		MaxDistance = Bubble.MaxDistance,
		StudsOffsetWorldSpace = Vector3.new(0, Bubble.HeadGap, 0),
		SizeOffset = Vector2.new(0, 0.5),
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}) :: BillboardGui
	-- Holder pops from its bottom centre (the tail side) via the UIScale.
	local holder = Create.new("Frame", {
		Name = "Holder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(1, 1),
		Active = false,
		Parent = gui,
	}) :: Frame
	local scale = Create.new("UIScale", { Scale = 1, Parent = holder }) :: UIScale
	-- Tail: a small rotated square peeking out under the panel (drawn behind it).
	local tail = Create.new("Frame", {
		Name = "Tail",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.88),
		Size = UDim2.fromScale(0.3, 0.3),
		Rotation = 45,
		BackgroundColor3 = UIStyleConfig.Colors.white.bottom,
		BorderSizePixel = 0,
		Active = false,
		ZIndex = 1,
		Parent = holder,
		Children = { Create.new("UIAspectRatioConstraint", { AspectRatio = 1 }) },
	}) :: Frame
	StudWindow.edge(tail, 2)
	local panel = Create.new("Frame", {
		Name = "Panel",
		Size = UDim2.fromScale(1, 0.84),
		Active = false,
		ZIndex = 2,
		Parent = holder,
	}) :: Frame
	StudWindow.surface(panel, "white", { edge = 2, corner = 12, zIndex = 2 })
	local label = Create.new("TextLabel", {
		Name = "Line",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.9, 0.72),
		Text = "",
		TextScaled = true,
		TextWrapped = true,
		FontFace = UIStyleConfig.Fonts.Title,
		TextColor3 = BUBBLE_TEXT,
		ZIndex = 4,
		Parent = panel,
		Children = { Create.new("UITextSizeConstraint", { MaxTextSize = Bubble.TextSize, MinTextSize = 10 }) },
	}) :: TextLabel
	local pop = TweenService:Create(
		scale,
		TweenInfo.new(Bubble.PopSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	)
	gui.Parent = parent
	return { gui = gui, label = label, scale = scale, pop = pop }
end

--[[ A hidden bubble from the pool (or a new one); nil only before PlayerGui exists. ]]
function LobbyBubbles.acquire(): BubbleVisual?
	local pooled = table.remove(pool)
	if pooled ~= nil then
		return pooled
	end
	local parent = playerGui()
	if parent == nil then
		return nil
	end
	return build(parent)
end

--[[
	Shows `line` over `head`.
	@param device   phone / tablet / console: DeviceScale bigger
	@param reduced  reduced motion: no pop
]]
function LobbyBubbles.show(bubble: BubbleVisual, head: BasePart, line: string, device: boolean, reduced: boolean)
	local k = if device then Bubble.DeviceScale else 1
	local chars = #line
	bubble.gui.Size = UDim2.new(
		(Bubble.StudsWidthBase + Bubble.StudsWidthPerChar * chars) * k,
		(Bubble.PixelWidthBase + Bubble.PixelWidthPerChar * chars) * k,
		Bubble.StudsHeight * k,
		Bubble.PixelHeight * k
	)
	bubble.gui.Adornee = head
	if bubble.label.Text ~= line then
		bubble.label.Text = line
	end
	bubble.pop:Cancel()
	if reduced then
		bubble.scale.Scale = 1
	else
		bubble.scale.Scale = 0.35
		bubble.pop:Play()
	end
	bubble.gui.Enabled = true
end

--[[ Hides a bubble, detaches it and pools it. ]]
function LobbyBubbles.release(bubble: BubbleVisual)
	bubble.pop:Cancel()
	bubble.gui.Enabled = false
	(bubble.gui :: any).Adornee = nil
	if #pool < POOL_CAP then
		table.insert(pool, bubble)
	else
		bubble.gui:Destroy()
	end
end

return table.freeze(LobbyBubbles)
