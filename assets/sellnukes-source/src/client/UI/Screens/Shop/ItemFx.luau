--!strict
--[[
	ItemFx — backing plates + the idle animation of every Shop item (owner R98: "the item in the
	shop should be animated. also they are hard to see with the stud background").

	What it builds (once per item, never per frame):

		Slot holder (positioned / sized by the card exactly like the old icon slot)
		├── Halo        soft disc in the card's accent colour, a little larger than the plate
		├── Shadow      dark disc, ShadowOffset px lower (drop shadow)
		├── Plate       the dark disc (a deep shade of the card) + glow ring (UIStroke, accent)
		│               + a top-light gradient
		└── Float       what moves: the item's icon / 3D model fills it; UIScale = the pulse
		    └── Glint   rare items only: a 4-ray sparkle that pops in now and then

		labelPlate(label)   a dark rounded name-plate behind a caption + a thicker text outline
		panel(parent)       the same plate as a free frame (ShopCard's preview + description)

	Animation (ItemFx.animate — ONE OfferFx animator per card, stepping all its slots):
		- a staggered bob + scale pulse (ItemFxLogic.pose), and on rare items a glint that
		  travels across the card (ItemFxLogic.glint);
		- runs on Widgets/OfferFx's single visibility-gated PreRender driver: a card animates only
		  while it is really on screen (Shop open, not scrolled away); the Shop also switches
		  every group off on close / on again on open (ItemFx.setEnabled, one batched re-check);
		- Low graphics (ShopItemFxConfig.Hz.Low = 0) and Reduce Motion park it; parked / disabled
		  items snap back to their rest pose (no offset, scale 1, glint hidden);
		- a step writes at most 4 properties per slot and skips sub-pixel changes
		  (ShopItemFxConfig.WriteEpsilon); no Instance or table is created per frame.

	Plates and glints are decorative: Active / Selectable false, so taps, gamepad selection and
	layouts are untouched.

	Connects to: Screens/Shop/{ItemFxLogic, PackCard, ShopCard, init}, Widgets/OfferFx,
	UI/Create, Shared/Config/{ShopItemFxConfig, UIStyleConfig (ItemPlate, Colors), OfferFxConfig}.

	Example:
		local slot = ItemFx.slot({ color = "red", parent = tile, zIndex = 3, seed = 1, index = 2,
			count = 5, rare = false })
		icon.Parent = slot.float -- the icon / model fills the float
		local group = ItemFx.animate(card.frame, { slot })
		ItemFx.setEnabled({ group }, false) -- Shop closed: rest + stop
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Parent.Create)
local ItemFxLogic = require(script.Parent.ItemFxLogic)
local OfferFx = require(script.Parent.Parent.Parent.Widgets.OfferFx)
local OfferFxConfig = require(ReplicatedStorage.Shared.Config.OfferFxConfig)
local ShopItemFxConfig = require(ReplicatedStorage.Shared.Config.ShopItemFxConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

type ColorName = UIStyleConfig.ColorName

export type SlotOptions = {
	color: ColorName, -- the card's colour (plate shade + glow)
	parent: Instance,
	zIndex: number, -- the holder's ZIndex among the card's content
	seed: number, -- the card's seed (LayoutOrder): staggers cards against each other
	index: number, -- 1-based item index inside the card
	count: number, -- items on the card (spreads the glints)
	rare: boolean, -- adds the sparkle glint
	name: string?,
}

-- A rare item's sparkle.
type Glint = { frame: Frame, scale: UIScale }

export type Slot = {
	frame: Frame, -- the holder: position / size it like an icon slot
	float: Frame, -- parent the icon / model here (fill it: ItemFx.fill)
	scale: UIScale, -- the pulse
	glint: Glint?,
	phase: number,
	glintOffset: number,
	-- Last written pose (writes are skipped while the change is invisible).
	y: number,
	s: number,
	glintShown: boolean,
}

export type Group = {
	-- Owner gate (default on); off also snaps every slot back to rest.
	setEnabled: (enabled: boolean) -> (),
	-- Snaps every slot to its rest pose (no offset, scale 1, glint hidden).
	rest: () -> (),
	-- True while OfferFx steps the group (enabled, on screen, motion allowed).
	running: () -> boolean,
	destroy: () -> (),
}

local ItemFx = {}

local Plate = UIStyleConfig.ItemPlate
local GlintCfg = ShopItemFxConfig.Glint
local EPS_PX = ShopItemFxConfig.WriteEpsilon.Pixels
local EPS_SCALE = ShopItemFxConfig.WriteEpsilon.Scale
local REST_POSITION = UDim2.fromScale(0.5, 0.5)
local CENTER = Vector2.new(0.5, 0.5)
local ROUND = UDim.new(0.5, 0)
local GLINT_COLOR = Color3.fromRGB(255, 252, 214)
-- A ray fades out toward both tips (bright centre): the classic 4-point glint.
local RAY_FADE = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.5, 0),
	NumberSequenceKeypoint.new(1, 1),
})

-- Plate colours per card colour, computed once each.
local looks: { [ColorName]: ItemFxLogic.PlateLook } = {}
-- Live groups (weak keys): re-posed at rest when motion parks (Low graphics / Reduce Motion).
local live: { [Group]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local watching = false

-- The (cached) plate colours of a card colour; unknown names use grey.
local function lookFor(color: ColorName): ItemFxLogic.PlateLook
	local cached = looks[color]
	if cached ~= nil then
		return cached
	end
	local preset = UIStyleConfig.Colors[color] or UIStyleConfig.Colors.grey
	local look = ItemFxLogic.plateLook(preset)
	looks[color] = look
	return look
end

-- A non-interactive, borderless disc of `scale` x its parent, centred.
local function disc(
	name: string,
	parent: Instance,
	color: Color3,
	transparency: number,
	scale: number,
	zIndex: number
): Frame
	return Create.new("Frame", {
		Name = name,
		AnchorPoint = CENTER,
		Position = REST_POSITION,
		Size = UDim2.fromScale(scale, scale),
		BackgroundColor3 = color,
		BackgroundTransparency = transparency,
		BorderSizePixel = 0,
		Active = false,
		Selectable = false,
		ZIndex = zIndex,
		Parent = parent,
		Children = { Create.new("UICorner", { CornerRadius = ROUND }) },
	}) :: Frame
end

-- One tapered ray of the glint (horizontal, or vertical when `vertical`).
local function ray(parent: Instance, vertical: boolean, zIndex: number): ()
	local width = GlintCfg.RayWidth
	Create.new("Frame", {
		Name = if vertical then "RayV" else "RayH",
		AnchorPoint = CENTER,
		Position = REST_POSITION,
		Size = if vertical then UDim2.fromScale(width, 1) else UDim2.fromScale(1, width),
		BackgroundColor3 = GLINT_COLOR,
		BorderSizePixel = 0,
		Active = false,
		Selectable = false,
		ZIndex = zIndex,
		Parent = parent,
		Children = {
			Create.new("UICorner", { CornerRadius = ROUND }),
			Create.new("UIGradient", { Transparency = RAY_FADE, Rotation = if vertical then 90 else 0 }),
		},
	})
end

-- The sparkle of a rare item (hidden until its first glint).
local function buildGlint(parent: Instance, zIndex: number): Glint
	local scale = Create.new("UIScale", { Name = "GlintScale", Scale = 0 }) :: UIScale
	local frame = Create.new("Frame", {
		Name = "Glint",
		AnchorPoint = CENTER,
		Position = UDim2.fromScale(GlintCfg.X, GlintCfg.Y),
		Size = UDim2.fromScale(GlintCfg.Size, GlintCfg.Size),
		BackgroundTransparency = 1,
		Active = false,
		Selectable = false,
		Visible = false,
		ZIndex = zIndex,
		Parent = parent,
		Children = { scale },
	}) :: Frame
	ray(frame, false, zIndex)
	ray(frame, true, zIndex)
	-- A soft bright core where the rays cross.
	disc("Core", frame, GLINT_COLOR, 0.1, GlintCfg.RayWidth * 2.2, zIndex + 1)
	return { frame = frame, scale = scale }
end

-- Snaps one slot to rest (only writes what is not at rest already).
local function restSlot(slot: Slot)
	if slot.y ~= 0 then
		slot.y = 0
		slot.float.Position = REST_POSITION
	end
	if slot.s ~= 1 then
		slot.s = 1
		slot.scale.Scale = 1
	end
	local glint = slot.glint
	if glint ~= nil and slot.glintShown then
		slot.glintShown = false
		glint.frame.Visible = false
	end
end

-- One step of a slot at `elapsed` seconds (skips invisible changes; no allocation but UDim2).
local function stepSlot(slot: Slot, elapsed: number)
	local y, s = ItemFxLogic.pose(elapsed, slot.phase)
	if math.abs(y - slot.y) >= EPS_PX then
		slot.y = y
		slot.float.Position = UDim2.new(0.5, 0, 0.5, y)
	end
	if math.abs(s - slot.s) >= EPS_SCALE then
		slot.s = s
		slot.scale.Scale = s
	end
	local glint = slot.glint
	if glint ~= nil then
		local amount, rotation = ItemFxLogic.glint(elapsed, slot.glintOffset)
		local show = amount > 0
		if show ~= slot.glintShown then
			slot.glintShown = show
			glint.frame.Visible = show
		end
		if show then
			glint.scale.Scale = amount
			glint.frame.Rotation = rotation
		end
	end
end

-- Listens once for motion parking (graphics tier / Reduce Motion) and rests every live group.
local function watchParking()
	if watching then
		return
	end
	watching = true
	OfferFx.Changed:Connect(function()
		if ItemFxLogic.parked(ShopItemFxConfig.Hz, OfferFx.tier(), OfferFx.reducedMotion()) then
			for group in live do
				group.rest()
			end
		end
	end)
end

--[[
	Builds an item's slot holder with its halo, drop shadow, plate (+ glow ring) and the float
	the item goes into (see the module header). Position / size `slot.frame` like an icon.
	@param options colour / parent / zIndex / seed / index / count / rare
	@return Slot
	Example: see the module header
]]
function ItemFx.slot(options: SlotOptions): Slot
	local look = lookFor(options.color)
	local holder = Create.new("Frame", {
		Name = options.name or "Slot",
		BackgroundTransparency = 1,
		Active = false,
		Selectable = false,
		ZIndex = options.zIndex,
		Parent = options.parent,
	}) :: Frame
	holder:SetAttribute("Decorative", true)
	-- Sibling ZIndex inside the holder: halo < shadow < plate < float (< glint inside it).
	disc("Halo", holder, look.halo, Plate.HaloTransparency, Plate.HaloScale, 1)
	local shadow = disc("Shadow", holder, look.shadow, Plate.ShadowTransparency, Plate.DiscScale, 2)
	shadow.Position = UDim2.new(0.5, 0, 0.5, Plate.ShadowOffset)
	local plate = disc("Plate", holder, look.fill, Plate.FillTransparency, Plate.DiscScale, 3)
	Create.new("UIStroke", {
		Name = "GlowRing",
		Color = look.ring,
		Thickness = Plate.RingThickness,
		Transparency = Plate.RingTransparency,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = plate,
	})
	Create.new("UIGradient", {
		Name = "TopLight",
		Rotation = 90,
		Color = ColorSequence.new(
			Color3.new(1, 1, 1),
			Color3.new(Plate.BottomShade, Plate.BottomShade, Plate.BottomShade)
		),
		Parent = plate,
	})
	local scale = Create.new("UIScale", { Name = "Pulse", Scale = 1 }) :: UIScale
	local float = Create.new("Frame", {
		Name = "Float",
		AnchorPoint = CENTER,
		Position = REST_POSITION,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Active = false,
		Selectable = false,
		ZIndex = 4,
		Parent = holder,
		Children = { scale },
	}) :: Frame
	return {
		frame = holder,
		float = float,
		scale = scale,
		glint = if options.rare then buildGlint(float, 8) else nil,
		phase = ItemFxLogic.phase(options.seed, options.index),
		glintOffset = ItemFxLogic.glintOffset(options.index, options.count),
		y = 0,
		s = 1,
		glintShown = false,
	}
end

--[[
	Makes an icon / model slot fill its float (centred, full size) and parents it there.
	@param item the icon frame or ModelViewport frame
	@param slot the slot built by ItemFx.slot
	Example: ItemFx.fill(StudUI.icon("Gems", 96, 3), slot)
]]
function ItemFx.fill(item: GuiObject, slot: Slot)
	item.AnchorPoint = CENTER
	item.Position = REST_POSITION
	item.Size = UDim2.fromScale(1, 1)
	item.Parent = slot.float
end

--[[
	Puts a dark rounded name-plate (the card's plate shade) behind a label and thickens its text
	outline to UIStyleConfig.ItemPlate.LabelStroke, so it reads on any stud card. The label's
	size, position and text limits are unchanged.
	@param label the TextLabel (a StudUI.text)
	@param color the card's colour
	Example: ItemFx.labelPlate(captionLabel, "white")
]]
function ItemFx.labelPlate(label: TextLabel, color: ColorName)
	label.BackgroundColor3 = lookFor(color).fill
	label.BackgroundTransparency = Plate.FillTransparency
	label.BorderSizePixel = 0
	Create.new("UICorner", { Name = "PlateCorner", CornerRadius = UDim.new(0, Plate.LabelCorner), Parent = label })
	for _, child in label:GetChildren() do
		if child:IsA("UIStroke") and child.ApplyStrokeMode == Enum.ApplyStrokeMode.Contextual then
			child.Thickness = math.max(child.Thickness, Plate.LabelStroke)
		end
	end
end

--[[
	A free dark rounded plate (same shade as labelPlate) to sit behind a group of labels; the
	owner positions / sizes it. Decorative (not Active / Selectable).
	@param parent where it goes
	@param color  the card's colour
	@param zIndex below the labels it backs
	@param name   instance name
	@return Frame
	Example: local plate = ItemFx.panel(card.content, "purple", 3, "InfoPlate")
]]
function ItemFx.panel(parent: Instance, color: ColorName, zIndex: number, name: string): Frame
	local frame = Create.new("Frame", {
		Name = name,
		BackgroundColor3 = lookFor(color).fill,
		BackgroundTransparency = Plate.FillTransparency,
		BorderSizePixel = 0,
		Active = false,
		Selectable = false,
		ZIndex = zIndex,
		Parent = parent,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, Plate.LabelCorner) }) },
	}) :: Frame
	frame:SetAttribute("Decorative", true)
	return frame
end

--[[
	Animates a card's slots with ONE OfferFx animator (root = the card: it steps only while the
	card is on screen). Starts enabled.
	@param root  the card frame (visibility subject)
	@param slots the card's slots (the list may be read later; slots never change identity)
	@return Group
	Example: local group = ItemFx.animate(card.frame, slots)
]]
function ItemFx.animate(root: GuiObject, slots: { Slot }): Group
	watchParking()
	local handle = OfferFx.register({
		root = root,
		rates = ShopItemFxConfig.Hz :: OfferFxConfig.PerTier,
		step = function(_dt: number, elapsed: number)
			for _, slot in slots do
				stepSlot(slot, elapsed)
			end
		end,
	})
	local function rest()
		for _, slot in slots do
			restSlot(slot)
		end
	end
	local group: Group = {
		setEnabled = function(enabled: boolean)
			handle.setEnabled(enabled)
			if enabled then
				-- Already-enabled groups (the first open after the lazy build) start now too,
				-- not at the next scanner tick (inside ItemFx.setEnabled: one batched re-check).
				handle.refresh()
			else
				rest()
			end
		end,
		rest = rest,
		running = handle.running,
		destroy = function() end,
	}
	group.destroy = function()
		live[group] = nil
		handle.destroy()
		rest()
	end
	live[group] = true
	return group
end

--[[
	Switches many groups at once (the Shop on open / close) with ONE visibility re-check
	(OfferFx.batch); switching off also rests every slot.
	@param groups the groups
	@param enabled on / off
	Example: ItemFx.setEnabled(shopGroups, isOpen)
]]
function ItemFx.setEnabled(groups: { Group }, enabled: boolean)
	OfferFx.batch(function()
		for _, group in groups do
			group.setEnabled(enabled)
		end
	end)
end

return table.freeze(ItemFx)
