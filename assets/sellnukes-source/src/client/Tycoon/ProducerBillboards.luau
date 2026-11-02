--!strict
--[[
	ProducerBillboards — the stud-style billboard over every producer (references 08 / 15).

	Layout (scale-based inside a stud-sized BillboardGui, so it shrinks with distance like the
	references):
		name                                      (white, outlined)
		$340.59B                     [x8]         (big green $ per cycle, yellow milestone badge)
		[==== progress ====  0.1s]   Lv 75        (stud progress bar; "CLICK" bar when manual + idle)
		[x10] [   UPGRADE   ] (E)                 (mode toggle, cyan pill: cost, key glyph)
	Other players' producers get a read-only billboard (name, amount, badge, bar).

	Data (all server truth): the producer attributes on the Anchor (Tycoon/TycoonContract:
	PerCycle, CycleTime, CycleStart, Automated, Badge, Level, NextCost, ClickCooldown) and, for
	the local player's own producers, the profile (levels + cash) so costs / affordability react
	the moment a purchase lands. Costs come from the shared TycoonLogic (same maths as the server).

	Placement + size (owner R31 / R32, lead QA "never covers the producer or its manager"): the
	pure solver Tycoon/BillboardPlacement picks the spot (`place`: above the producer when there
	is clear, readable headroom, else beside it at eye height; never inside geometry, never over
	the producer's click box or its manager's work area from where players stand) and the board
	height (`heightAt`: studs, clamped to a viewport-height budget, so it shrinks with distance
	but never balloons up close or vanishes far away). Placement runs on stream-in, when builds /
	area bases land nearby and on layout change, never per frame.

	Performance: ONE PreRender connection drives every billboard (no per-billboard connections):
	each frame it moves the progress fills of VISIBLE billboards only; at RefreshHz it re-checks
	distance (MaxDistance culling), re-sizes the board (only when it changed > SizeEpsilon) and
	re-reads attributes / costs, writing text only when it changed. Billboards are created when an
	anchor streams in and destroyed when it streams out.

	Input: the CLICK bar and UPGRADE pill are TextButtons (mouse / touch); tapping / clicking the
	3D producer (its ClickBox) and the keyboard / gamepad actions go through Tycoon/Interaction,
	which calls `click` / `upgrade` here. A click is only sent while the producer is idle (the
	server accepts nothing else) and starts the bar optimistically; the server decides
	(ProducerClick / ProducerUpgrade intents).

	Tutorial focus (owner R84): Tycoon/TutorialHighlight rings this board's UPGRADE pill
	(`record.upgrade`) or make bar (`record.well`) and the HUD arrow points at it; `Changed`
	(producerId) fires after a board is built / destroyed so the tutorial re-targets at once.
	The board does not clip its children, so the ring may reach past its bottom edge.

	Worlds (owner R57, spec §7): every lookup goes through Tycoon/WorldLookup, keyed by the
	record's world (the producer id is globally unique and prefixed: "dp3_ptero_express" is Dino
	Valley's). Config, levels, costs and the wallet are that world's (WorldLookup.producer /
	tycoon / logic / wallet); amounts are written in its currency style (Nuke Town "$1.2K"; Dino
	"1.2K" beside a bone icon in the currency's colour, built once per billboard); the slot frame,
	the shipped spot (BillboardSpots.worlds[worldId]) and the runtime solve sources are that
	world's. Nuke Town's billboards are unchanged.

	Connects to: Tycoon/{TycoonWorld, TycoonContract, UpgradeMode, Interaction, WorldLookup,
	BillboardPlacement, IncomePops (popPoint / popDrift)}, Client/ClientState (via WorldLookup),
	Shared/Config/{TycoonClientConfig, UIStyleConfig, ManagerNpcConfig, WorldLayout, MeshAssets,
	BillboardSpots}, Shared/Net/Remotes, UI/Widgets/{StudWindow, InputGlyph}, UI/Kit/StudUI
	(currency icon).

	Example:
		ProducerBillboards.start()
		local record = ProducerBillboards.nearestOwn(rootPosition, 18)
		if record then ProducerBillboards.upgrade(record) end
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local BillboardPlacement = require(script.Parent.BillboardPlacement)
local BillboardProps = require(script.Parent.BillboardProps)
local BillboardSpots = require(ReplicatedStorage.Shared.Config.BillboardSpots)
local ButtonFeedback = require(script.Parent.Parent.UI.ButtonFeedback)
local ClickCombo = require(script.Parent.Fx.ClickCombo)
local Contract = require(script.Parent.TycoonContract)
local Create = require(script.Parent.Parent.UI.Create)
local InputGlyph = require(script.Parent.Parent.UI.Widgets.InputGlyph)
local KnockdownConfig = require(ReplicatedStorage.Shared.Config.KnockdownConfig)
local ManagerNpcConfig = require(ReplicatedStorage.Shared.Config.ManagerNpcConfig)
local MeshAssets = require(ReplicatedStorage.Shared.Config.MeshAssets)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.UI.Widgets.StudWindow)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local TycoonTypes = require(ReplicatedStorage.Shared.Tycoon.TycoonTypes)
local TycoonWorld = require(script.Parent.TycoonWorld)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local UpgradeMode = require(script.Parent.UpgradeMode)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldLookup = require(script.Parent.WorldLookup)

local Attr = Contract.Attr
local KnockAttr = KnockdownConfig.Attr
local Config = TycoonClientConfig.Billboard
local Placement = TycoonClientConfig.Placement
local Neutral = UIStyleConfig.Neutral

export type Record = {
	anchor: BasePart,
	point: Attachment, -- billboard adornee (placed in clear space: see placement section)
	popPoint: Attachment, -- where income pops start (beside the billboard)
	popDrift: Vector3, -- world direction pops drift (outward + up, never over the text)
	popAway: Vector3, -- unit, horizontal: the board's outer side (away from the producer)
	id: string,
	worldId: string, -- owner R57: the producer's world ("main" / "dino"; from its unique id)
	mine: boolean,
	cfg: TycoonTypes.ProducerConfig?,
	gui: BillboardGui,
	device: boolean, -- phone / tablet / console sizing (BillboardPlacement.heightAt)
	height: number, -- current board height in studs (resized at RefreshHz)
	plot: Model?, -- plot containing the anchor (its PlotIndex gives the slot frame)
	area: number, -- the producer's area index (Anchor `Area`; 0 when unknown)
	placement: BillboardPlacement.Result?, -- last placement decision (debug / verification)
	fallback: boolean, -- placed from the live click box (no slot / layout): re-placed on stream-in
	nameLabel: TextLabel,
	amount: TextLabel,
	badge: Frame,
	badgeText: TextLabel,
	level: TextLabel,
	barFill: Frame,
	barText: TextLabel,
	well: Frame, -- the bar's well (the CLICK bar covers it while idle): the tutorial "make" target
	areaModel: Instance?, -- the producer's area model (AreaNN: carries KnockedUntil, owner R50)
	knock: Frame, -- red "KNOCKED DOWN 0:45" plate over the bar while the area is knocked down
	knockText: TextLabel,
	knockedUntil: number, -- server time the area comes back up (0 / past = up)
	pausedAt: number, -- server time the payout loop paused this producer (0 = running)
	knockShown: number, -- last countdown second written (-1 = plate hidden)
	click: TextButton,
	upgrade: TextButton,
	upgradeSurface: StudWindow.Surface,
	upgradeCost: TextLabel,
	modeText: TextLabel,
	-- Owner R86 gem upgrade button (owner only; painted by Tycoon/GemUpgrade via paintGem).
	gem: TextButton,
	gemSurface: StudWindow.Surface,
	gemText: TextLabel,
	gemPainted: string, -- last painted "visible|text|color" (writes only on change)
	controls: { GuiObject }, -- owner-only controls (hidden on other players' billboards)
	-- cached server state (refreshed at RefreshHz)
	perCycle: number,
	cycleTime: number,
	cycleStart: number,
	automated: boolean,
	cooldown: number,
	-- local state
	localStart: number, -- optimistic cycle start after our own click (server time)
	lastClick: number,
	lastUpgrade: number,
	visible: boolean,
	barShown: number, -- last bar text value (tenths) written
	affordable: boolean,
	count: number, -- levels the current mode would buy
}

local ProducerBillboards = {}

--[[
	Owner R84: fires (producerId) after a billboard was built or destroyed (stream in / out, a
	plot rebuild). Tycoon/TutorialHighlight listens so the tutorial arrow + highlight ring move
	onto the UPGRADE pill / make bar of the board that exists right now.
]]
ProducerBillboards.Changed = Signal.new() :: Signal.Signal<string>

--[[
	Owner R86: fires (record) when the player presses an own board's gem button (touch / mouse).
	Tycoon/GemUpgrade owns what happens (confirm, intent, feedback).
]]
ProducerBillboards.GemPressed = Signal.new() :: Signal.Signal<Record>

local records: { [BasePart]: Record } = {}
local renderConnection: RBXScriptConnection? = nil
local refreshClock = 0
local started = false

-- An outlined, scaled text label.
local function label(parent: Instance, props: { [string]: any }): TextLabel
	local text = Create.new("TextLabel", {
		BackgroundTransparency = 1,
		TextScaled = true,
		FontFace = props.font or UIStyleConfig.Fonts.Title,
		TextColor3 = props.color or Neutral.Text,
		Text = props.text or "",
		Size = props.size,
		Position = props.position or UDim2.new(),
		AnchorPoint = props.anchor or Vector2.zero,
		TextXAlignment = props.align or Enum.TextXAlignment.Center,
		ZIndex = props.zIndex or 3,
		Name = props.name or "Label",
		Parent = parent,
		Children = {
			Create.new("UIStroke", {
				Color = Neutral.TextStroke,
				Thickness = props.stroke or 2,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
				LineJoinMode = Enum.LineJoinMode.Round,
			}),
		},
	}) :: TextLabel
	return text
end

-- A producer's level: the anchor's server Level attribute, or (own billboards) the profile's
-- level when that is newer (profile deltas and attribute replication can land in either order;
-- levels only grow within a run, so the larger one is the latest).
local function levelOf(record: Record): number
	local published = Contract.num(record.anchor:GetAttribute(Attr.Level), 0)
	-- The record's world state (Nuke Town: profile.tycoon; Dino: profile.worlds.dino.tycoon).
	local tycoon = if record.mine then WorldLookup.tycoon(record.worldId) else nil
	if tycoon ~= nil then
		return math.max(published, WorldLookup.logic(record.worldId).levelOf(tycoon, record.id))
	end
	return published
end

-- The player's balance in the record's world currency right now (Cash / Bones; server-synced
-- profile, 0 before the first snapshot).
local function wallet(record: Record): number
	return WorldLookup.wallet(record.worldId)
end

--[[
	Levels + cost the current upgrade mode would buy for `record`.
	@return (count, cost): count 0 when nothing is affordable / possible (cost = next x1 price)
]]
local function upgradeQuote(record: Record): (number, number)
	local cfg = record.cfg
	local level = levelOf(record)
	if cfg == nil or level < 1 then
		return 0, math.huge
	end
	-- The world's own economy maths (same curves the server charges with).
	local logic = WorldLookup.logic(record.worldId)
	local mode = UpgradeMode.get()
	if mode == "max" then
		local count, cost = logic.maxAffordable(cfg, level, wallet(record))
		if count > 0 then
			return count, cost
		end
		return 0, logic.upgradeCost(cfg, level, 1)
	end
	local count = if mode == "10" then 10 else 1
	return count, logic.upgradeCost(cfg, level, count)
end

--[[
	A currency icon (UI/Kit/StudUI: the uploaded IconAssets image, glyph fallback) that sits left of
	a scaled amount label inside the stud-sized billboard (owner R57: Dino amounts show the bone
	icon instead of "$"). Square via an aspect constraint on the label's height, so it scales with
	the board like the text. Built once per billboard; never touched per frame.
	@param parent   the frame / gui the label lives in
	@param key      IconAssets key (WorldLookup.currencyOf(worldId).icon, e.g. "Bones")
	@param position top-left of the icon (scale of `parent`)
	@param height   icon height (scale of `parent`'s height)
	@param zIndex   ZIndex of the icon
	@return the icon Frame
	Example: currencyIcon(gui, "Bones", UDim2.fromScale(0.04, 0.13), 0.22, 3)
]]
local function currencyIcon(parent: Instance, key: string, position: UDim2, height: number, zIndex: number): Frame
	local icon = StudUI.icon(key, 64, zIndex)
	icon.Name = "CurrencyIcon"
	icon.Size = UDim2.fromScale(1, height)
	icon.Position = position
	icon.ZIndex = zIndex
	Create.new("UIAspectRatioConstraint", {
		AspectRatio = 1,
		DominantAxis = Enum.DominantAxis.Height,
		Parent = icon,
	})
	icon.Parent = parent
	return icon
end

--[[
	The area model a producer anchor belongs to (Plot<N>/AreaNN, which carries the R50 knockdown
	attributes): the first ancestor with an AreaIndex attribute, else Anchor.Parent.Parent.
]]
local function areaModelOf(anchor: BasePart): Instance?
	local node: Instance? = anchor.Parent
	while node ~= nil and node ~= Workspace do
		if node:GetAttribute(Attr.AreaIndex) ~= nil then
			return node
		end
		node = node.Parent
	end
	local producer = anchor.Parent
	return if producer ~= nil then producer.Parent else nil
end

-- Builds the billboard Instances for one anchor.
local function build(anchor: BasePart, id: string, mine: boolean): Record
	local player = Players.LocalPlayer
	-- The producer's world (owner R57): its unique id names it; an unknown id (config not loaded,
	-- a placeholder) falls back to the plot's world. Fixed for the record's life.
	local idWorld, cfg = WorldLookup.producer(id)
	local worldId = idWorld or TycoonWorld.worldOf(anchor)
	local currency = WorldLookup.currencyOf(worldId)
	-- Icon worlds (Dino Bones): amounts read "1.2K" beside the currency icon, in its colour.
	local withIcon = WorldLookup.usesIcon(worldId)
	local amountColor = if withIcon then currency.color else Neutral.CashGreen
	-- Phones, tablets and ten-foot consoles get larger billboards (readable + bigger tap targets).
	local device = ScreenManager.device.class ~= "Desktop"
	local height = Config.HeightStuds * (if device then Config.DeviceScale else 1)
	-- Client-only adornee points (owner R31/R32): placed in clear space by `place`.
	-- Parented at the very end of `build`, so a build that fails part-way leaves nothing behind.
	local point = Instance.new("Attachment")
	point.Name = `ProducerBillboardPoint_{id}`
	local popPoint = Instance.new("Attachment")
	popPoint.Name = `ProducerPopPoint_{id}`
	local gui = Create.new("BillboardGui", {
		Name = `ProducerBillboard_{id}`,
		Adornee = point,
		Size = UDim2.fromScale(height * Config.Aspect, height),
		MaxDistance = if mine then Config.MaxDistance else Config.OthersMaxDistance,
		LightInfluence = 0,
		AlwaysOnTop = false,
		-- R84: the tutorial's highlight ring around the UPGRADE pill (the board's bottom row)
		-- reaches a few px past the board's edge.
		ClipsDescendants = false,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Active = mine,
	}) :: BillboardGui
	local nameLabel = label(gui, {
		name = "Name",
		size = UDim2.fromScale(0.9, 0.12),
		position = UDim2.fromScale(0.5, 0),
		anchor = Vector2.new(0.5, 0),
	})
	-- Icon worlds: a square icon (0.22 of the board height = 0.22 / Aspect of its width) leads
	-- the amount, which starts just after it and keeps its right edge (0.74).
	local iconWidth = 0.22 / Config.Aspect
	local amountX = if withIcon then 0.05 + iconWidth + 0.01 else 0.06
	local amount = label(gui, {
		name = "Amount",
		font = UIStyleConfig.Fonts.Number,
		color = amountColor,
		stroke = 3,
		size = UDim2.fromScale(0.74 - amountX, 0.24),
		position = UDim2.fromScale(amountX, 0.12),
		align = Enum.TextXAlignment.Left,
	})
	if withIcon then
		currencyIcon(gui, currency.icon, UDim2.fromScale(0.05, 0.13), 0.22, 3)
	end
	local badge = Create.new("Frame", {
		Name = "Badge",
		Size = UDim2.fromScale(0.18, 0.22),
		Position = UDim2.fromScale(0.78, 0.13),
		Visible = false,
		ZIndex = 2,
		Parent = gui,
	}) :: Frame
	StudWindow.surface(badge, "yellow", { studTransparency = 1, edge = 3, corner = 6 })
	local badgeText =
		label(badge, { name = "BadgeText", size = UDim2.fromScale(0.86, 0.8), position = UDim2.fromScale(0.07, 0.1) })
	local level = label(gui, {
		name = "Level",
		color = Color3.fromRGB(255, 226, 90),
		size = UDim2.fromScale(0.24, 0.1),
		position = UDim2.fromScale(0.75, 0.345),
	})
	-- Progress bar: dark well + green stud fill + time text.
	local well = Create.new("Frame", {
		Name = "BarWell",
		Size = UDim2.fromScale(0.92, 0.17),
		Position = UDim2.fromScale(0.04, 0.45),
		BackgroundColor3 = Neutral.Well,
		ZIndex = 2,
		Parent = gui,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 6) }) },
	}) :: Frame
	StudWindow.edge(well, 3)
	local barFill = Create.new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		ZIndex = 2,
		Parent = well,
	}) :: Frame
	StudWindow.surface(barFill, "green", { tile = UIStyleConfig.StudTile.Button, studTransparency = 0.55, corner = 6 })
	local barText = label(well, {
		name = "Time",
		size = UDim2.fromScale(0.5, 0.8),
		position = UDim2.fromScale(0.5, 0.1),
		anchor = Vector2.new(0.5, 0),
		zIndex = 4,
	})
	-- CLICK bar: covers the well while a manual producer is idle (owner only).
	local click = Create.new("TextButton", {
		Name = "Click",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 5,
		Parent = well,
	}) :: TextButton
	StudWindow.surface(
		click,
		"green",
		{ tile = UIStyleConfig.StudTile.Button, studTransparency = 0.5, edge = 3, corner = 6 }
	)
	label(click, {
		name = "ClickText",
		text = "CLICK",
		font = UIStyleConfig.Fonts.Number,
		size = UDim2.fromScale(0.6, 0.8),
		position = UDim2.fromScale(0.5, 0.1),
		anchor = Vector2.new(0.5, 0),
		zIndex = 6,
	})
	-- Bottom row (owner R86 made room for the gem button):
	--   [x1 0.02-0.15] [ UPGRADE 0.17-0.63 ] [ gem 75 0.65-0.98 ]
	-- The Interact / GemUpgrade key glyphs sit on the top-right corners of their buttons.
	-- Mode toggle (x1 / x10 / MAX).
	local mode = Create.new("TextButton", {
		Name = "Mode",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(0.13, 0.2),
		Position = UDim2.fromScale(0.02, 0.72),
		ZIndex = 3,
		Parent = gui,
	}) :: TextButton
	StudWindow.surface(
		mode,
		"yellow",
		{ tile = UIStyleConfig.StudTile.Button, studTransparency = 0.6, edge = 3, corner = 6 }
	)
	local modeText = label(mode, {
		name = "ModeText",
		size = UDim2.fromScale(0.86, 0.7),
		position = UDim2.fromScale(0.07, 0.15),
		zIndex = 4,
	})
	-- UPGRADE pill: cyan stud face, "UPGRADE" + cost (green), level tag, key glyph.
	local upgrade = Create.new("TextButton", {
		Name = "Upgrade",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(0.46, 0.28),
		Position = UDim2.fromScale(0.17, 0.68),
		ZIndex = 3,
		Parent = gui,
		Children = { Create.new("UIScale", { Name = "Pop", Scale = 1 }) },
	}) :: TextButton
	-- Starts grey (record.affordable = false); refresh() paints it cyan once affordable.
	local upgradeSurface = StudWindow.surface(upgrade, "grey", {
		tile = UIStyleConfig.StudTile.Button,
		studTransparency = 0.6,
		edge = 3,
		corner = 10,
	})
	label(upgrade, {
		name = "UpgradeText",
		text = "UPGRADE",
		font = UIStyleConfig.Fonts.Number,
		stroke = 3,
		size = UDim2.fromScale(0.9, 0.56),
		position = UDim2.fromScale(0.05, 0.04),
		zIndex = 4,
	})
	-- Cost line: centred "$1.2K" (Nuke Town), or a bone icon + left-aligned "1.2K" (icon worlds).
	local upgradeCost = label(upgrade, {
		name = "Cost",
		color = amountColor,
		size = if withIcon then UDim2.fromScale(0.62, 0.34) else UDim2.fromScale(0.8, 0.34),
		position = if withIcon then UDim2.fromScale(0.27, 0.6) else UDim2.fromScale(0.1, 0.6),
		align = if withIcon then Enum.TextXAlignment.Left else nil,
		zIndex = 4,
	})
	if withIcon then
		currencyIcon(upgrade, currency.icon, UDim2.fromScale(0.13, 0.6), 0.34, 4)
	end
	-- Owner R86 gem button: [gem icon] "75" on a purple stud face; Tycoon/GemUpgrade paints it
	-- ("SURE?" yellow while armed, "NEED 75" grey when short, hidden at MaxLevel / switched off).
	local gem = Create.new("TextButton", {
		Name = "GemUpgrade",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(0.33, 0.28),
		Position = UDim2.fromScale(0.65, 0.68),
		ZIndex = 3,
		Visible = false,
		Parent = gui,
		Children = { Create.new("UIScale", { Name = "Pop", Scale = 1 }) },
	}) :: TextButton
	local gemSurface = StudWindow.surface(gem, "purple", {
		tile = UIStyleConfig.StudTile.Button,
		studTransparency = 0.6,
		edge = 3,
		corner = 10,
	})
	-- The gem icon fills the button's height on the left (square), the text the rest.
	local gemIcon = StudUI.icon("Gems", 64, 4)
	gemIcon.Name = "GemIcon"
	gemIcon.AnchorPoint = Vector2.new(0, 0.5)
	gemIcon.Position = UDim2.fromScale(0.04, 0.5)
	gemIcon.Size = UDim2.fromScale(1, 0.78)
	Create.new("UIAspectRatioConstraint", {
		AspectRatio = 1,
		DominantAxis = Enum.DominantAxis.Height,
		Parent = gemIcon,
	})
	gemIcon.Parent = gem
	local gemText = label(gem, {
		name = "GemText",
		text = "",
		font = UIStyleConfig.Fonts.Number,
		stroke = 3,
		size = UDim2.fromScale(0.58, 0.62),
		position = UDim2.fromScale(0.38, 0.19),
		zIndex = 4,
	})
	local controls: { GuiObject } = { click, mode, upgrade }
	if mine then
		-- Key glyphs on the top-right corner of their buttons ([E] / (X), [C] / (LB)).
		local glyph = InputGlyph.action("Interact", 22)
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.62, 0.7)
		glyph.ZIndex = 5
		glyph.Parent = gui
		table.insert(controls, glyph)
		local gemGlyph = InputGlyph.action("GemUpgrade", 22)
		gemGlyph.Name = "GemGlyph"
		gemGlyph.AnchorPoint = Vector2.new(0.5, 0.5)
		gemGlyph.Position = UDim2.fromScale(1, 0.12)
		gemGlyph.ZIndex = 5
		gemGlyph.Parent = gem
	end
	for _, control in controls do
		control.Visible = mine and control ~= click
	end
	-- Knockdown plate (owner R50): covers the bar while the area is knocked down, counting down to
	-- the auto-rebuild ("KNOCKED DOWN 0:45", "REBUILDING!" at the end). Everyone sees it.
	local knock = Create.new("Frame", {
		Name = "Knocked",
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 6,
		Parent = well,
	}) :: Frame
	StudWindow.surface(
		knock,
		"red",
		{ tile = UIStyleConfig.StudTile.Button, studTransparency = 0.5, edge = 3, corner = 6 }
	)
	local knockText = label(knock, {
		name = "KnockText",
		size = UDim2.fromScale(0.94, 0.8),
		position = UDim2.fromScale(0.5, 0.1),
		anchor = Vector2.new(0.5, 0),
		zIndex = 7,
	})
	point.Parent = Workspace.Terrain
	popPoint.Parent = Workspace.Terrain
	gui.Parent = player:FindFirstChildOfClass("PlayerGui")
	local record: Record = {
		anchor = anchor,
		point = point,
		popPoint = popPoint,
		popDrift = Vector3.yAxis,
		popAway = Vector3.xAxis,
		id = id,
		worldId = worldId,
		mine = mine,
		cfg = cfg,
		gui = gui,
		device = device,
		height = height,
		plot = TycoonWorld.plotOf(anchor),
		area = Contract.num(anchor:GetAttribute("Area"), 0),
		placement = nil,
		fallback = false,
		nameLabel = nameLabel,
		amount = amount,
		badge = badge,
		badgeText = badgeText,
		level = level,
		barFill = barFill,
		barText = barText,
		well = well,
		areaModel = areaModelOf(anchor),
		knock = knock,
		knockText = knockText,
		knockedUntil = 0,
		pausedAt = 0,
		knockShown = -1,
		click = click,
		upgrade = upgrade,
		upgradeSurface = upgradeSurface,
		upgradeCost = upgradeCost,
		modeText = modeText,
		gem = gem,
		gemSurface = gemSurface,
		gemText = gemText,
		gemPainted = "",
		controls = controls,
		perCycle = 0,
		cycleTime = 1,
		cycleStart = 0,
		automated = false,
		cooldown = Config.MinClickGap,
		localStart = 0,
		lastClick = -math.huge,
		lastUpgrade = -math.huge,
		visible = true,
		barShown = -1,
		affordable = false,
		count = 0,
	}
	if mine then
		-- Press feedback (owner R22) is fired by click() / upgrade() themselves, so taps, keys,
		-- gamepad and 3D taps all get the same sound + burst (FeedbackManual = no auto-bind).
		click:SetAttribute("FeedbackManual", true)
		click:SetAttribute("FeedbackKind", "Studs")
		click:SetAttribute("FeedbackColor", "green")
		click:SetAttribute("FeedbackSound", "producer_pop")
		upgrade:SetAttribute("FeedbackManual", true)
		upgrade:SetAttribute("FeedbackKind", "Coins")
		upgrade:SetAttribute("FeedbackColor", "cyan")
		upgrade:SetAttribute("FeedbackSound", "upgrade")
		mode:SetAttribute("FeedbackColor", "yellow")
		click.Activated:Connect(function()
			ProducerBillboards.click(record)
		end)
		upgrade.Activated:Connect(function()
			ProducerBillboards.upgrade(record)
		end)
		mode.Activated:Connect(UpgradeMode.cycle)
		-- R86: the gem button's press goes to Tycoon/GemUpgrade (confirm + intent), which also
		-- fires the press feedback itself (arm vs buy sound differ).
		gem:SetAttribute("FeedbackManual", true)
		gem:SetAttribute("FeedbackKind", "Coins")
		gem:SetAttribute("FeedbackColor", "purple")
		gem:SetAttribute("FeedbackSound", "upgrade")
		gem.Activated:Connect(function()
			ProducerBillboards.GemPressed:Fire(record)
		end)
	end
	return record
end

-- Writes `text` only when it changed (no per-frame string churn on the Instance).
local function setText(target: TextLabel, text: string)
	if target.Text ~= text then
		target.Text = text
	end
end

-- Re-reads attributes, costs and affordability of one VISIBLE billboard.
local function refresh(record: Record)
	local anchor = record.anchor
	local cfg = record.cfg
	record.perCycle = Contract.num(anchor:GetAttribute(Attr.PerCycle), 0)
	record.cycleTime = math.max(Contract.num(anchor:GetAttribute(Attr.CycleTime), 1), 0.01)
	record.cycleStart = Contract.num(anchor:GetAttribute(Attr.CycleStart), 0)
	record.automated = Contract.bool(anchor:GetAttribute(Attr.Automated))
	record.cooldown = math.max(Contract.num(anchor:GetAttribute(Attr.ClickCooldown), 0), Config.MinClickGap)
	-- Owner R50 knockdown: paused payout (bar frozen) + the area's rebuild time (countdown plate).
	record.pausedAt = Contract.num(anchor:GetAttribute(KnockAttr.PausedAt), 0)
	local area = record.areaModel
	record.knockedUntil = if area ~= nil then Contract.num(area:GetAttribute(KnockAttr.Until), 0) else 0
	setText(record.nameLabel, if cfg ~= nil then cfg.name else record.id)
	setText(record.amount, WorldLookup.format(record.worldId, record.perCycle))
	local badgeText = Contract.str(anchor:GetAttribute(Attr.Badge), "")
	record.badge.Visible = badgeText ~= ""
	setText(record.badgeText, badgeText)
	setText(record.level, `x{levelOf(record)}`)
	if not record.mine then
		return
	end
	setText(record.modeText, UpgradeMode.label())
	local count, cost = upgradeQuote(record)
	record.count = count
	local affordable = count > 0 and cost < math.huge and wallet(record) >= cost
	if affordable ~= record.affordable then
		record.affordable = affordable
		record.upgradeSurface.setColor(if affordable then "cyan" else "grey")
	end
	local price = if cost < math.huge then WorldLookup.format(record.worldId, cost) else "MAX"
	setText(record.upgradeCost, if UpgradeMode.get() == "max" and count > 1 then `{price} (x{count})` else price)
end

-- Moves one VISIBLE billboard's progress bar for `now` (server time).
local function step(record: Record, now: number)
	-- Knockdown plate (owner R50): seconds left until the area rebuilds, written once a second.
	local left = record.knockedUntil - now
	local shown = if left > 0 then math.ceil(left) else -1
	if shown ~= record.knockShown then
		record.knockShown = shown
		record.knock.Visible = shown > 0
		if shown > 0 then
			record.knockText.Text = if left <= Config.RebuildingBelow
				then "REBUILDING!"
				else string.format("KNOCKED DOWN %d:%02d", shown // 60, shown % 60)
		end
	end
	-- While the payout loop has the producer paused, the bar freezes where it stopped (the server
	-- shifts CycleStart by the paused time on resume, so it continues from the same spot).
	if record.pausedAt > 0 then
		now = record.pausedAt
	end
	local cycle = record.cycleTime
	local start = math.max(record.cycleStart, record.localStart)
	local fill = 0
	local remaining = cycle
	local running = false
	if record.automated then
		running = true
		if cycle < Config.FullBarBelow then
			fill, remaining = 1, cycle
		elseif start > 0 then
			local into = (now - start) % cycle
			fill, remaining = into / cycle, cycle - into
		end
	elseif start > 0 and now < start + cycle then
		running = true
		fill = math.clamp((now - start) / cycle, 0, 1)
		remaining = start + cycle - now
	end
	record.barFill.Size = UDim2.fromScale(fill, 1)
	record.barFill.Visible = fill > 0
	-- Owner + manual + idle: the CLICK bar covers the well (not while knocked down: paused).
	record.click.Visible = record.mine and not running and shown <= 0 and record.pausedAt <= 0
	local tenths = math.max(0, math.ceil(remaining * 10))
	if tenths ~= record.barShown then
		record.barShown = tenths
		record.barText.Text = string.format("%.1fs", tenths / 10)
	end
end

--[[
	Re-anchors the income-pop start beside the board's CURRENT size (the board's stud height is
	clamped to a screen budget, so it can be wider than its stud size far away): the pop's inner
	edge starts PopSideGap outside the board's edge on its outer side, slightly lower, drifting
	outward + up (IncomePops; pops are AlwaysOnTop, so they must never start over the text).
	Called on placement and whenever the board is resized (never per frame).
]]
local function placePop(record: Record)
	local half = record.height * Config.Aspect / 2
	local start = half + Placement.PopSideGap + TycoonClientConfig.Pops.SizeStuds.X / 2
	record.popPoint.WorldPosition = record.point.WorldPosition
		+ record.popAway * start
		- Vector3.new(0, record.height * Placement.PopDrop, 0)
	record.popDrift = record.popAway * Placement.PopDriftSide + Vector3.new(0, Placement.PopDriftUp, 0)
end

-- The single per-frame driver for every billboard.
local function onPreRender(dt: number)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	refreshClock += dt
	local refreshDue = refreshClock >= 1 / Config.RefreshHz
	if refreshDue then
		refreshClock = 0
	end
	local cameraPosition = camera.CFrame.Position
	local now = Workspace:GetServerTimeNow()
	for _, record in records do
		if refreshDue then
			local limit = if record.mine then Config.MaxDistance else Config.OthersMaxDistance
			record.visible = (record.anchor.Position - cameraPosition).Magnitude <= limit
			if record.visible then
				refresh(record)
				-- Size (lead QA): the stud size clamped to the viewport-height budget, so the
				-- board never balloons over the scene up close and stays readable far away.
				-- Written only when it changed by more than SizeEpsilon.
				local distance = (record.point.WorldPosition - cameraPosition).Magnitude
				local height = BillboardPlacement.heightAt(distance, Config, record.device, camera.FieldOfView)
				if math.abs(height - record.height) > record.height * Config.SizeEpsilon then
					record.height = height
					record.gui.Size = UDim2.fromScale(height * Config.Aspect, height)
					placePop(record) -- keep the pops clear of the resized board
				end
			end
		end
		if record.visible then
			step(record, now)
		end
	end
end

local function updateConnection()
	if next(records) ~= nil and renderConnection == nil then
		renderConnection = RunService.PreRender:Connect(onPreRender)
	elseif next(records) == nil and renderConnection ~= nil then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

-- Producer ids already warned about (one warning per id and problem, never a flood per join).
local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if not warned[key] then
		warned[key] = true
		warn(message)
	end
end

--[[
	`place` that can never throw: on an unexpected error the board still gets a usable spot (just
	above the producer's click box, the pre-R31 default) and the problem is warned once per
	producer id, so one bad producer never leaves its billboard unplaced or breaks the others.
]]
local function placeSafely(record: Record)
	local ok, err = pcall(ProducerBillboards.place, record)
	if not ok then
		local box = TycoonWorld.clickBox(record.anchor)
		record.point.WorldPosition = box.Position + Vector3.new(0, box.Size.Y / 2 + record.height / 2 + 1, 0)
		record.popAway = Vector3.xAxis
		placePop(record)
		record.fallback = true
		warnOnce(`place:{record.id}`, `[ProducerBillboards] placement failed for {record.id}: {err}`)
	end
end

--[[
	Builds + registers the billboard of one streamed-in producer anchor (TycoonWorld.ProducerAdded).
	Robust per producer: a failing build is warned once per id and skipped (nothing half-built is
	left behind, see `build`), a failing placement falls back (`placeSafely`), and neither ever
	reaches the other producers' listeners.
]]
local function add(anchor: BasePart)
	if records[anchor] ~= nil or anchor.Parent == nil then
		return
	end
	local id = TycoonWorld.producerId(anchor)
	if id == "" then
		return
	end
	local ok, built = pcall(build, anchor, id, TycoonWorld.isMine(anchor))
	if not ok then
		warnOnce(`build:{id}`, `[ProducerBillboards] billboard build failed for {id}: {built}`)
		return
	end
	local record: Record = built
	records[anchor] = record
	placeSafely(record)
	refresh(record)
	updateConnection()
	-- R84: the tutorial focus re-resolves its UPGRADE / make targets onto the new board.
	ProducerBillboards.Changed:Fire(id)
end

local function remove(anchor: BasePart)
	local record = records[anchor]
	if record == nil then
		return
	end
	records[anchor] = nil
	record.gui:Destroy()
	record.point:Destroy()
	record.popPoint:Destroy()
	updateConnection()
	-- R84: a tutorial arrow / ring on this board falls back (or moves to its rebuilt twin).
	ProducerBillboards.Changed:Fire(record.id)
end

-- ── Placement (owner R31 / R32 + lead QA) ───────────────────────────────────────────────────

-- The producer's body box: its ClickBox (the server sizes it over the producer), else the anchor.
local function bodyOf(record: Record): (CFrame, Vector3)
	local box = TycoonWorld.clickBox(record.anchor)
	return box.CFrame, box.Size
end

-- The producer's slot frame (Plot<N> + Area attribute), or nil when either is unknown.
local function slotOf(record: Record): CFrame?
	local plot = record.plot
	local index = if plot ~= nil then Contract.num(plot:GetAttribute(Attr.PlotIndex), 0) else 0
	local area = record.area
	if index < 1 or index > WorldLayout.PlotCount or index % 1 ~= 0 then
		return nil
	end
	if area < 1 or area > WorldLayout.areaCount(record.worldId) or area % 1 ~= 0 then
		return nil
	end
	-- The plot's frame in its own world (Dino plots sit around the Valley, not Nuke Town's hub).
	return WorldLayout.slotOrigin(index, area, record.worldId)
end

-- A world's round-producer row (Placement.RoundBodies for Nuke Town, WorldRoundBodies[worldId]
-- for the others; an unknown world -> no round producers).
local NO_ROUND: { [number]: boolean } = table.freeze({} :: { [number]: boolean })
local function roundBodiesOf(worldId: string): { [number]: boolean }
	if worldId == WorldLookup.MAIN then
		return Placement.RoundBodies
	end
	return Placement.WorldRoundBodies[worldId] or NO_ROUND
end

--[[
	World direction from the producer toward where players stand: the slot's road side (slot -Z,
	every area faces its plot road), else the click box's front.
]]
local function towardRoad(record: Record, fallback: Vector3): Vector3
	local slot = slotOf(record)
	local flat = if slot ~= nil then slot.LookVector else fallback
	flat = Vector3.new(flat.X, 0, flat.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
end

--[[
	The config one world's area solve reads (BillboardPlacement.Sources), built once per world on
	first use (only for an area missing from BillboardSpots). Layouts come from the world's own
	folder through WorldLookup.layout (required under pcall and cached there): a broken layout file
	only loses its own area (that producer falls back to the live click box), never every
	billboard. Managers, slot frames and round producers are the world's too, exactly what
	tests/fixtures/BillboardSources feeds the offline generator.
	Example: BillboardPlacement.areaInput(3, sourcesOf("dino"), false, Config, Placement)
]]
local sourcesByWorld: { [string]: BillboardPlacement.Sources } = {}
local function sourcesOf(worldId: string): BillboardPlacement.Sources
	local cached = sourcesByWorld[worldId]
	if cached ~= nil then
		return cached
	end
	local layouts: { [number]: any } = {}
	for area = 1, WorldLayout.areaCount(worldId) do
		local layout = WorldLookup.layout(worldId, area)
		if layout ~= nil then
			layouts[area] = layout
		else
			warn(`[ProducerBillboards] {worldId} Area{area} layout unavailable for placement`)
		end
	end
	local built: BillboardPlacement.Sources = {
		layouts = layouts,
		meshAssets = MeshAssets,
		slotLocal = function(area: number): CFrame
			return WorldLayout.slotLocal(area, worldId)
		end,
		managerKeys = ManagerNpcConfig.managerKeysOf(worldId),
		rigs = ManagerNpcConfig.Rigs,
		-- nil for Nuke Town: the solver then reads Placement.RoundBodies (unchanged behaviour).
		roundBodies = if worldId == WorldLookup.MAIN then nil else roundBodiesOf(worldId),
		-- Owner R117: the AA tower slots, Mega Lever + Tip Jar are obstacles too.
		props = BillboardProps.boxes(worldId, function(area: number): CFrame
			return WorldLayout.slotLocal(area, worldId)
		end, MeshAssets, Placement.SeeThrough),
	}
	sourcesByWorld[worldId] = built
	return built
end

-- A world's shipped spot rows (Nuke Town: the top-level table; others: BillboardSpots.worlds).
local function shippedSpots(worldId: string): { [number]: BillboardSpots.AreaSpots }?
	if worldId == WorldLookup.MAIN then
		return BillboardSpots
	end
	local worlds = BillboardSpots.worlds
	return if worlds ~= nil then worlds[worldId] else nil
end

--[[
	The slot-local spot of an area's billboard for a device class, shared by all 8 plots of a
	world (plot frames are rigid). Normally a lookup in Shared/Config/BillboardSpots (solved offline
	by the same code, kept current by tests/billboard-clearance.luau; other worlds under
	`BillboardSpots.worlds[worldId]`): zero solve cost at join. An area missing from the table is
	solved here once (BillboardPlacement, ~0.1 s) and cached; `false` caches "no usable layout"
	(the caller falls back to the live click box).
	Example: spotOf("dino", 3, false) --> Result (slot-local position, side, right, ...)
]]
local spots: { [string]: BillboardPlacement.Result | false } = {}
local function spotOf(worldId: string, area: number, device: boolean): BillboardPlacement.Result?
	local key = `{worldId}:{area}:{device}`
	local cached = spots[key]
	if cached ~= nil then
		return cached or nil
	end
	local rows = shippedSpots(worldId)
	local row = if rows ~= nil then rows[area] else nil
	local shipped = if row ~= nil then (if device then row.device else row.desktop) else nil
	local result: BillboardPlacement.Result? = nil
	if shipped ~= nil then
		result = {
			position = shipped.position,
			side = shipped.side,
			right = shipped.right,
			family = shipped.family,
			clear = shipped.clear,
			readable = shipped.readable,
			slabClear = shipped.slabClear,
			blockedRays = shipped.blockedRays,
			elevation = shipped.elevation,
			height = shipped.height,
		}
	else
		local input = BillboardPlacement.areaInput(area, sourcesOf(worldId), device, Config, Placement)
		result = if input ~= nil then BillboardPlacement.choose(input) else nil
	end
	spots[key] = result or false
	return result
end

--[[
	Places a billboard (and its pop start point) where it never covers the producer or its
	manager from where players stand (Tycoon/BillboardPlacement): right above the producer when
	there is clear, readable headroom, else beside it at eye height; never inside an awning /
	sign / beam. The spot comes from config (the fully built area: Shared/Config/BillboardSpots,
	solved offline by BillboardPlacement; `spotOf`) per area + device and is mapped through this
	plot's slot frame, so it never depends on streaming or on what has been bought. Producers
	without a slot / layout fall back to a solve around the live click box. Runs on stream-in
	and on device / layout change (never per frame).
	@param record a producer record
]]
function ProducerBillboards.place(record: Record)
	-- The device class can change (a tablet docked to a screen): size + place for the current one.
	record.device = ScreenManager.device.class ~= "Desktop"
	local slot = slotOf(record)
	local spot = if slot ~= nil then spotOf(record.worldId, record.area, record.device) else nil
	local result: BillboardPlacement.Result
	local position: Vector3
	local right: Vector3
	if slot ~= nil and spot ~= nil then
		result = spot
		position = slot * spot.position
		right = slot:VectorToWorldSpace(spot.right)
		record.fallback = false
	else
		-- No slot frame / layout: solve around the live click box (no geometry known).
		local bodyCFrame, bodySize = bodyOf(record)
		local body: BillboardPlacement.Box =
			{ cf = bodyCFrame, size = bodySize, round = roundBodiesOf(record.worldId)[record.area] == true }
		local half = bodySize / 2
		local ground = bodyCFrame.Position.Y
			- (
				math.abs(bodyCFrame.RightVector.Y) * half.X
				+ math.abs(bodyCFrame.UpVector.Y) * half.Y
				+ math.abs(bodyCFrame.LookVector.Y) * half.Z
			)
		result = BillboardPlacement.choose({
			body = body,
			protect = { body },
			forward = towardRoad(record, bodyCFrame.LookVector),
			ground = ground,
			obstacles = {},
			device = record.device,
			fov = Placement.Fov,
			size = Config,
			cfg = Placement,
		})
		position = result.position
		right = result.right
		record.fallback = true
	end
	record.point.WorldPosition = position
	record.popAway = right * result.side
	placePop(record)
	record.placement = result
end

--[[
	Runs one manual cycle of an own producer (CLICK bar, tap on the producer, F / R2). Ignored
	while a cycle runs, for automated producers and inside the server's ClickCooldown; starts the
	bar optimistically (the server's CycleStart takes over when it replicates).
	@param record an own producer record
	@param sendIntent false when the server already got the press through the producer's
	       ClickDetector (3D click / tap): only the bar starts, no ProducerClick (default true)
	@return true when the cycle was started locally
]]
function ProducerBillboards.click(record: Record, sendIntent: boolean?): boolean
	if not record.mine or record.automated then
		return false
	end
	-- Click combo ladder (owner R71): every press on an own manual producer, cosmetic only.
	ClickCombo.press(record.anchor, record.popPoint)
	local now = Workspace:GetServerTimeNow()
	local start = math.max(record.cycleStart, record.localStart)
	if start > 0 and now < start + record.cycleTime then
		return false
	end
	if now - record.lastClick < record.cooldown then
		return false
	end
	record.lastClick = now
	record.localStart = now
	ButtonFeedback.fire(record.click)
	if sendIntent ~= false then
		task.spawn(function()
			Remotes.event("ProducerClick"):FireServer(record.id)
		end)
	end
	return true
end

--[[
	Buys levels of an own producer with the current x1 / x10 / MAX mode (UPGRADE pill, E / X).
	Skipped locally when unaffordable (the server re-checks everything anyway).
	@return true when the intent was sent
]]
function ProducerBillboards.upgrade(record: Record): boolean
	if not record.mine then
		return false
	end
	local now = os.clock()
	if now - record.lastUpgrade < Config.UpgradeDebounce then
		return false
	end
	refresh(record)
	-- Feedback either way: an unaffordable press plays the locked sound (no burst).
	record.upgrade:SetAttribute("FeedbackLocked", not record.affordable)
	ButtonFeedback.fire(record.upgrade)
	if not record.affordable then
		return false
	end
	record.lastUpgrade = now
	local mode = UpgradeMode.get()
	task.spawn(function()
		Remotes.event("ProducerUpgrade"):FireServer(record.id, mode)
	end)
	local pop = record.upgrade:FindFirstChild("Pop")
	if pop ~= nil and pop:IsA("UIScale") then
		pop.Scale = 0.88
		TweenService:Create(pop, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
			:Play()
	end
	return true
end

--[[
	The nearest OWN producer record within `range` studs of `position`, or nil.
	Example: local record = ProducerBillboards.nearestOwn(root.Position, 18)
]]
function ProducerBillboards.nearestOwn(position: Vector3, range: number): Record?
	local best: Record? = nil
	local bestDistance = range
	for anchor, record in records do
		if record.mine then
			local distance = (anchor.Position - position).Magnitude
			if distance <= bestDistance then
				best, bestDistance = record, distance
			end
		end
	end
	return best
end

--[[ The record of a producer anchor (any owner), or nil. ]]
function ProducerBillboards.byAnchor(anchor: BasePart): Record?
	return records[anchor]
end

--[[ The record of an own producer by id, or nil. ]]
function ProducerBillboards.byId(producerId: string): Record?
	for _, record in records do
		if record.mine and record.id == producerId then
			return record
		end
	end
	return nil
end

--[[ Owner R86: the record's current level (server attribute or the newer profile level). ]]
function ProducerBillboards.level(record: Record): number
	return levelOf(record)
end

--[[ Owner R86: every own billboard record right now (a fresh list; event-time use only). ]]
function ProducerBillboards.ownRecords(): { Record }
	local list: { Record } = {}
	for _, record in records do
		if record.mine then
			table.insert(list, record)
		end
	end
	return list
end

--[[
	Owner R86: paints an own board's gem button (Tycoon/GemUpgrade decides the look). Writes only
	when something changed (one string compare otherwise).
	@param visible false hides the button (MaxLevel, switched off, not built)
	@param text    "75", "SURE?" or "NEED 75"
	@param color   stud preset: "purple" (buy), "yellow" (armed), "grey" (short of gems)
	Example: ProducerBillboards.paintGem(record, true, "SURE?", "yellow")
]]
function ProducerBillboards.paintGem(record: Record, visible: boolean, text: string, color: string)
	if not record.mine then
		return
	end
	local key = `{visible}|{text}|{color}`
	if key == record.gemPainted then
		return
	end
	record.gemPainted = key
	record.gem.Visible = visible
	setText(record.gemText, text)
	record.gemSurface.setColor(color :: any)
	record.gem:SetAttribute("FeedbackLocked", color == "grey")
end

--[[ Starts the billboards (once; TycoonClient calls it after TycoonWorld.start). ]]
function ProducerBillboards.start()
	if started then
		return
	end
	started = true
	TycoonWorld.ProducerAdded:Connect(function(anchor: BasePart)
		add(anchor)
		-- A fallback placement (no slot / layout) used the live ClickBox, which may stream in
		-- right after the anchor: place it again once.
		task.defer(function()
			local record = records[anchor]
			if record ~= nil and record.fallback then
				placeSafely(record)
			end
		end)
	end)
	TycoonWorld.ProducerRemoved:Connect(remove)
	for _, anchor in TycoonWorld.producers() do
		add(anchor)
	end
	-- Placement depends only on the slot, the area and the device class (the spot is solved from
	-- the fully built area's config, never from streamed geometry), so builds landing need no
	-- re-placement. A device / layout change re-places every billboard (cached spots: cheap).
	ScreenManager.LayoutChanged:Connect(function()
		for _, record in records do
			placeSafely(record)
		end
	end)
	-- A plot changing hands flips which billboards are interactive: rebuild that world's (owner
	-- R57: MyWorldPlotChanged fires per world, Nuke Town included; other worlds stay untouched).
	TycoonWorld.MyWorldPlotChanged:Connect(function(worldId: string)
		for _, anchor in TycoonWorld.producers() do
			local record = records[anchor]
			if record == nil or record.worldId == worldId then
				remove(anchor)
				add(anchor)
			end
		end
	end)
	-- Mode / profile changes re-quote every own billboard at once (not just at the next tick).
	UpgradeMode.Changed:Connect(function()
		for _, record in records do
			if record.mine and record.visible then
				refresh(record)
			end
		end
	end)
end

return ProducerBillboards
