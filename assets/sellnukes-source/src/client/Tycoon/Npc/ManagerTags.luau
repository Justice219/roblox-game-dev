--!strict
--[[
	ManagerTags — the Instances of the manager nametags + speech bubbles (owner R87: "in sell lemons
	the managers/automaters all have nametags"). Pure visuals: Tycoon/Npc/ManagerController decides
	who gets a tag, when it shows and who speaks (with the pure ManagerTagLogic); this module only
	builds, pools, styles, places and toggles the billboards.

	Tag (one pooled BillboardGui per manager in range):
		[ FOREMAN ]        role chip — a small coloured stud pill (ManagerTagConfig.ChipColors by world)
		Captain Kaboom     name — big white outlined text
		runs Glow Rock Drill    "runs <producer>" — smaller warm-yellow outlined text
	Speech bubble (one per plot at a time, owner only): a white stud bubble with a tail and a short
	dark line, stacked right above the tag; pops in with a UIScale tween (instant with reduced motion).

	Sizing (owner R11 console + mobile first): every billboard is sized in STUDS + a PIXEL floor
	(UDim2 scale + offset), so it shrinks with distance like the world but never below a readable
	size on phones / TVs; phones, tablets and consoles get DeviceScale more. The tag's bottom edge
	sits on its anchor point (SizeOffset Y 0.5), and the bubble uses the same studs : pixels mix at
	HeightRatio of the tag, so `SizeOffset` can stack it exactly above the tag at every distance.

	Lifetime + performance:
		* Billboards live in PlayerGui (ResetOnSpawn off) and are ADORNED to the manager's head piece,
		  so they follow the animated NPC for free (no per-frame writes) and survive the server
		  model streaming out (the controller releases the tag back to the pool on unregister).
		* Built once, then pooled (`acquire` / `release`); styling writes only changed text.
		* AlwaysOnTop off (walls hide them, like the player title tags; an always-on-top variant did
		  not render in Studio captures during R87 QA), LightInfluence 0, MaxDistance per owner.
		* Nothing here runs per frame; the one TweenService tween per bubble is created once.

	Connects to: Shared/Config/ManagerTagConfig (sizes, colours), Shared/Config/UIStyleConfig,
	UI/{Create, Kit/StudUI, Widgets/StudWindow}, Tycoon/Npc/ManagerTagLogic (Tag type).

	Example (ManagerController):
		local tag = ManagerTags.acquire()
		if tag ~= nil then
			ManagerTags.style(tag, info, "main", true, device)
			ManagerTags.place(tag, headPart, 1.2)
			ManagerTags.setShown(tag, true)
		end
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ManagerTagConfig = require(ReplicatedStorage.Shared.Config.ManagerTagConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local Create = require(script.Parent.Parent.Parent.UI.Create)
local ManagerTagLogic = require(script.Parent.ManagerTagLogic)
local StudUI = require(script.Parent.Parent.Parent.UI.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.UI.Widgets.StudWindow)

local Tag = ManagerTagConfig.Tag
local Bubble = ManagerTagConfig.Bubble

-- One pooled nametag.
export type TagVisual = {
	gui: BillboardGui,
	chip: Frame,
	chipSurface: StudWindow.Surface,
	chipLabel: TextLabel,
	nameLabel: TextLabel,
	runsLabel: TextLabel,
	device: boolean, -- sized for a phone / tablet / console
	widthScale: number, -- share of the full width its text needs (ManagerTagLogic.widthScale)
	lift: number, -- studs added to the anchor offset (DazedLift while dazed)
	offset: number, -- studs from the adornee's centre to the tag's bottom edge
	nudge: number, -- studs slid sideways (camera right) to stay clear of the producer board
}

-- One pooled speech bubble.
export type BubbleVisual = {
	gui: BillboardGui,
	label: TextLabel,
	scale: UIScale,
	pop: Tween,
}

local ManagerTags = {}

-- Pools (billboards disabled + detached, still parented to PlayerGui). Capped so a long session
-- that once streamed many plots does not keep every billboard ever built.
local POOL_CAP = 24
local tagPool: { TagVisual } = {}
local bubblePool: { BubbleVisual } = {}
-- Bubble text: dark slate on the white stud bubble (no outline: dark on light reads cleanly).
local BUBBLE_TEXT = UIStyleConfig.Neutral.Well

-- The PlayerGui the billboards live in (nil until it exists).
local function playerGui(): Instance?
	local player = Players.LocalPlayer
	return if player ~= nil then player:FindFirstChildOfClass("PlayerGui") else nil
end

-- Writes `text` only when it changed (no string churn on the Instance).
local function setText(label: TextLabel, text: string)
	if label.Text ~= text then
		label.Text = text
	end
end

-- The tag size (studs + pixel floor) for a device class and a width share.
local function tagSize(device: boolean, widthScale: number): UDim2
	local k = if device then Tag.DeviceScale else 1
	local w = k * widthScale
	return UDim2.new(Tag.StudsWidth * w, Tag.PixelWidth * w, Tag.StudsHeight * k, Tag.PixelHeight * k)
end

--[[
	tagPixels — the on-screen size (px) of a tag whose anchor is `depth` studs in front of a camera
	with `focal` = viewportHeight / (2 tan(fov / 2)). Matches the billboard's studs + px sizing, so
	the controller's overlap test needs no AbsoluteSize read.
	@param widthScale  the tag's width share (TagVisual.widthScale; 1 = full width)
	@return width, height
]]
function ManagerTags.tagPixels(focal: number, depth: number, device: boolean, widthScale: number): (number, number)
	local k = if device then Tag.DeviceScale else 1
	local perStud = focal / math.max(depth, 0.1)
	return (Tag.StudsWidth * perStud + Tag.PixelWidth) * k * widthScale,
		(Tag.StudsHeight * perStud + Tag.PixelHeight) * k
end

--[[
	bubblePixels — the on-screen size (px) of a bubble showing `chars` characters, same model as
	`tagPixels`. @return width, height
]]
function ManagerTags.bubblePixels(focal: number, depth: number, device: boolean, chars: number): (number, number)
	local k = if device then Tag.DeviceScale else 1
	local perStud = focal / math.max(depth, 0.1)
	local studsWide = Bubble.StudsWidthBase + Bubble.StudsWidthPerChar * chars
	local pixelsWide = Bubble.PixelWidthBase + Bubble.PixelWidthPerChar * chars
	local studsHigh = Tag.StudsHeight * Bubble.HeightRatio
	local pixelsHigh = Tag.PixelHeight * Bubble.HeightRatio
	return (studsWide * perStud + pixelsWide) * k, (studsHigh * perStud + pixelsHigh) * k
end

-- Builds one nametag billboard (disabled, detached).
local function buildTag(parent: Instance): TagVisual
	local gui = Create.new("BillboardGui", {
		Name = "ManagerTag",
		Size = tagSize(false, 1),
		-- Bottom edge on the anchor point: the px floor never pushes the tag into the head.
		SizeOffset = Vector2.new(0, 0.5),
		LightInfluence = 0,
		AlwaysOnTop = false,
		ClipsDescendants = false,
		ResetOnSpawn = false,
		Active = false,
		Enabled = false,
		MaxDistance = Tag.MaxDistanceOwn,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}) :: BillboardGui
	-- Role chip: a coloured stud pill centred on the top row.
	local chip = Create.new("Frame", {
		Name = "RoleChip",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(Tag.ChipMinWidth, Tag.ChipHeight),
		Active = false,
		ZIndex = 1,
		Parent = gui,
	}) :: Frame
	-- A px corner (not a 0.5 scale pill): the stud texture inside follows the same px radius, so
	-- no studs poke out of the rounded ends; small chips clamp to a full pill anyway.
	local chipSurface = StudWindow.surface(chip, ManagerTagConfig.DefaultChipColor :: any, { edge = 2, corner = 9 })
	local chipLabel = StudUI.text({
		name = "Role",
		text = "",
		textSize = Tag.ChipTextSize,
		font = "title",
		scaled = true,
		anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.52),
		size = UDim2.fromScale(0.86, 0.8),
		zIndex = 3,
		parent = chip,
	})
	StudWindow.outline(chipLabel, 2)
	local nameLabel = StudUI.text({
		name = "Name",
		text = "",
		textSize = Tag.NameTextSize,
		font = "title",
		scaled = true,
		anchor = Vector2.new(0.5, 0),
		position = UDim2.fromScale(0.5, Tag.ChipHeight + 0.01),
		size = UDim2.fromScale(1, Tag.NameHeight),
		zIndex = 2,
		parent = gui,
	})
	StudWindow.outline(nameLabel, 3)
	local runsLabel = StudUI.text({
		name = "Runs",
		text = "",
		textSize = Tag.RunsTextSize,
		font = "title",
		scaled = true,
		color = Tag.RunsColor,
		anchor = Vector2.new(0.5, 0),
		position = UDim2.fromScale(0.5, Tag.ChipHeight + Tag.NameHeight + 0.02),
		size = UDim2.fromScale(0.96, Tag.RunsHeight),
		zIndex = 2,
		parent = gui,
	})
	StudWindow.outline(runsLabel, 2)
	gui.Parent = parent
	return {
		gui = gui,
		chip = chip,
		chipSurface = chipSurface,
		chipLabel = chipLabel,
		nameLabel = nameLabel,
		runsLabel = runsLabel,
		device = false,
		widthScale = 1,
		lift = 0,
		offset = 0,
		nudge = 0,
	}
end

-- Builds one speech bubble billboard (disabled, detached).
local function buildBubble(parent: Instance): BubbleVisual
	local gui = Create.new("BillboardGui", {
		Name = "ManagerBubble",
		Size = UDim2.new(2, 60, Tag.StudsHeight * Bubble.HeightRatio, Tag.PixelHeight * Bubble.HeightRatio),
		LightInfluence = 0,
		AlwaysOnTop = false,
		ClipsDescendants = false,
		ResetOnSpawn = false,
		Active = false,
		Enabled = false,
		MaxDistance = Tag.MaxDistanceOwn,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}) :: BillboardGui
	-- Holder: pops from its bottom centre (the tail tip side) via the UIScale.
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
	-- Tail: a small rotated square peeking out under the bubble (drawn behind the panel).
	local tail = Create.new("Frame", {
		Name = "Tail",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.9),
		Size = UDim2.fromScale(0.34, 0.34),
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
		Size = UDim2.fromScale(1, 0.86),
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
		Size = UDim2.fromScale(0.88, 0.74),
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

---------------------------------------------------------------------------------------------------
-- Tags
---------------------------------------------------------------------------------------------------

--[[
	acquire — a disabled nametag from the pool (or a new one). nil only before PlayerGui exists
	(the controller simply retries on its next refresh).
]]
function ManagerTags.acquire(): TagVisual?
	local pooled = table.remove(tagPool)
	if pooled ~= nil then
		return pooled
	end
	local parent = playerGui()
	if parent == nil then
		return nil
	end
	return buildTag(parent)
end

--[[ release — hides a tag, drops its adornee (never keeps a streamed-out part alive) and pools it. ]]
function ManagerTags.release(tag: TagVisual)
	tag.gui.Enabled = false
	-- `any` view: a nil Adornee (detached) is valid but the definitions type it non-optional.
	(tag.gui :: any).Adornee = nil
	tag.lift = 0
	ManagerTags.setNudge(tag, 0)
	if #tagPool < POOL_CAP then
		table.insert(tagPool, tag)
	else
		tag.chipSurface.Destroy()
		tag.gui:Destroy()
	end
end

--[[
	style — writes what a tag says and how it looks (text, chip colour + width, owner cull
	distance, device size). Cheap when nothing changed (every write is guarded).
	@param info    ManagerTagLogic.describe result
	@param worldId the manager's world (chip colour)
	@param mine    true for the local player's managers (longer MaxDistance)
	@param device  phone / tablet / console sizing
]]
function ManagerTags.style(tag: TagVisual, info: ManagerTagLogic.Tag, worldId: string, mine: boolean, device: boolean)
	local role = string.upper(info.role)
	local runsText = if info.runs ~= "" then `{Tag.RunsPrefix} {info.runs}` else ""
	setText(tag.chipLabel, role)
	setText(tag.nameLabel, info.name)
	setText(tag.runsLabel, runsText)
	-- Just as wide as its own text (short names cover less of the scene).
	tag.widthScale = ManagerTagLogic.widthScale(info.name, runsText, role, Tag, Tag.FullWidthChars, Tag.MinWidthScale)
	tag.chipSurface.setColor((ManagerTagConfig.ChipColors[worldId] or ManagerTagConfig.DefaultChipColor) :: any)
	-- Chip width follows its text (a short "MANAGER" stays a small pill), relative to the fitted tag.
	local width =
		math.clamp((Tag.ChipBase + Tag.ChipPerChar * #role) / tag.widthScale, Tag.ChipMinWidth, Tag.ChipMaxWidth)
	local chipSize = UDim2.fromScale(width, Tag.ChipHeight)
	if tag.chip.Size ~= chipSize then
		tag.chip.Size = chipSize
	end
	local maxDistance = if mine then Tag.MaxDistanceOwn else Tag.MaxDistanceOther
	if tag.gui.MaxDistance ~= maxDistance then
		tag.gui.MaxDistance = maxDistance
	end
	tag.device = not device -- force the resize below (width share may have changed)
	ManagerTags.setDevice(tag, device)
end

--[[ setDevice — resizes a tag for a phone / tablet / console (true) or desktop (false). ]]
function ManagerTags.setDevice(tag: TagVisual, device: boolean)
	if tag.device ~= device then
		tag.device = device
		tag.gui.Size = tagSize(device, tag.widthScale)
	end
end

--[[
	setNudge — slides the tag `studs` sideways in camera space (StudsOffset X: + = screen right),
	clear of its producer's billboard. The controller eases the value; this only writes it.
]]
function ManagerTags.setNudge(tag: TagVisual, studs: number)
	if tag.nudge == studs then
		return
	end
	tag.nudge = studs
	tag.gui.StudsOffset = Vector3.new(studs, 0, 0)
end

--[[
	place — rides the tag on `adornee` with its bottom edge `offset` studs above the part's centre
	(world up; plus the current lift).
]]
function ManagerTags.place(tag: TagVisual, adornee: BasePart, offset: number)
	tag.offset = offset
	if tag.gui.Adornee ~= adornee then
		tag.gui.Adornee = adornee
	end
	local studs = Vector3.new(0, offset + tag.lift, 0)
	if tag.gui.StudsOffsetWorldSpace ~= studs then
		tag.gui.StudsOffsetWorldSpace = studs
	end
end

--[[ setLift — raises the tag by `lift` studs (dazed: clear of the orbiting stars) or back (0). ]]
function ManagerTags.setLift(tag: TagVisual, lift: number)
	if tag.lift == lift then
		return
	end
	tag.lift = lift
	tag.gui.StudsOffsetWorldSpace = Vector3.new(0, tag.offset + lift, 0)
end

--[[ setShown — shows / hides a tag (writes only on change). ]]
function ManagerTags.setShown(tag: TagVisual, shown: boolean)
	if tag.gui.Enabled ~= shown then
		tag.gui.Enabled = shown
	end
end

---------------------------------------------------------------------------------------------------
-- Speech bubbles
---------------------------------------------------------------------------------------------------

--[[ acquireBubble — a disabled bubble from the pool (or a new one); nil before PlayerGui exists. ]]
function ManagerTags.acquireBubble(): BubbleVisual?
	local pooled = table.remove(bubblePool)
	if pooled ~= nil then
		return pooled
	end
	local parent = playerGui()
	if parent == nil then
		return nil
	end
	return buildBubble(parent)
end

--[[
	showBubble — pops `line` up over a tag: same adornee, stacked right above the tag's top edge.
	@param tag      the speaking manager's (shown) tag
	@param line     ManagerTagConfig.Lines entry
	@param reduced  reduced motion: appear without the pop
]]
function ManagerTags.showBubble(bubble: BubbleVisual, tag: TagVisual, line: string, reduced: boolean)
	local k = if tag.device then Tag.DeviceScale else 1
	local chars = #line
	bubble.gui.Size = UDim2.new(
		(Bubble.StudsWidthBase + Bubble.StudsWidthPerChar * chars) * k,
		(Bubble.PixelWidthBase + Bubble.PixelWidthPerChar * chars) * k,
		Tag.StudsHeight * Bubble.HeightRatio * k,
		Tag.PixelHeight * Bubble.HeightRatio * k
	)
	-- Bubble centre = tag bottom + tag height + gap + half a bubble, in bubble heights (the bubble
	-- shares the tag's studs : px mix, so this ratio holds at every distance).
	bubble.gui.SizeOffset = Vector2.new(0, 0.5 + 1 / Bubble.HeightRatio + Bubble.Gap)
	bubble.gui.Adornee = tag.gui.Adornee
	bubble.gui.StudsOffsetWorldSpace = tag.gui.StudsOffsetWorldSpace
	bubble.gui.StudsOffset = tag.gui.StudsOffset
	bubble.gui.MaxDistance = tag.gui.MaxDistance
	setText(bubble.label, line)
	bubble.pop:Cancel()
	if reduced then
		bubble.scale.Scale = 1
	else
		bubble.scale.Scale = 0.35
		bubble.pop:Play()
	end
	bubble.gui.Enabled = true
end

--[[ nudgeBubble — keeps a showing bubble on its tag's sideways offset (studs, camera right). ]]
function ManagerTags.nudgeBubble(bubble: BubbleVisual, studs: number)
	local offset = Vector3.new(studs, 0, 0)
	if bubble.gui.StudsOffset ~= offset then
		bubble.gui.StudsOffset = offset
	end
end

--[[ releaseBubble — hides a bubble, detaches it and pools it. ]]
function ManagerTags.releaseBubble(bubble: BubbleVisual)
	bubble.pop:Cancel()
	bubble.gui.Enabled = false
	(bubble.gui :: any).Adornee = nil
	if #bubblePool < POOL_CAP then
		table.insert(bubblePool, bubble)
	else
		bubble.gui:Destroy()
	end
end

return ManagerTags
