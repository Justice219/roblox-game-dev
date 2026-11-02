--!strict
--[[
	DefenseWorld — the local player's in-world defence buttons (owner R80: "there are no buttons to
	like buy AA towers or anything like that for your island. Or your plot ... And they need to be
	upgradable.").

	What it shows (own plot only; other players just see the pads / towers):
		* over every blue defence BUY pad (Server/Attack/AttackWorld.setDefensePad, tag
		  AttackConfig.Tags.DefensePad, OwnerUserId = me): the tower's name, "Shoots down nukes!"
		  and its price — a tap target, coloured sky blue when affordable, grey when not (exactly
		  the tycoon PadBillboards look), shown out to PadMaxDistance (the pads stand on the open
		  flanks of the plot). Walking onto the pad buys it too (server Touched).
		* by every own AA tower (tag AttackConfig.Tags.Turret, Plot = my plot): the HQ Feature
		  tower (Tower 0, board above it) and each defence slot tower (board like a sign on the
		  plot side at eye level) — "NAME  Lv n/5" and a stud UPGRADE pill with the next level's
		  price and the Interact key glyph (like the producer UPGRADE pill); MAX LEVEL in green
		  once maxed.

	Placement + size (owner R105 "the site launch gui is clipping": the Silo Launch producer board
	overlapped the AA TOWER / SILO TOWER boards): every board is a constant, smaller pixel size
	(Towers.Billboard.Pixels / DesktopPixels — no studs part, so it never balloons up close), the
	WHOLE board is the tap target, culling is shorter (MaxDistance / PadMaxDistance), and its spot is
	solved clear of the producer boards and the other defence boards from where players stand
	(Client/Attack/DefenseBoardPlacement; re-solved on a device / viewport change). A runtime
	declutter (DECLUTTER_SECONDS, only while boards exist) hides a board from the few live camera
	views where it would still overlap a visible producer board or a nearer defence board (never
	the board of the pad / tower the player stands at).

	Input (owner R11, console + mobile first): touch / mouse tap anywhere on a board; keyboard E,
	gamepad X and the touch Interact button act on the nearest pad / tower in reach through
	Tycoon/Interaction (DefenseWorld registers a provider, so the hint bar shows "Buy $1.2T" /
	"Upgrade $4.8T" and gamepad A buys a pad you stand at). Billboards are a stud size plus a
	pixel size, so the tap targets stay >= 44 pt at any distance on phones / tablets / TVs.

	Intents only (the server prices, checks and decides): a pad / slot tower sends
	DefenseTower(slot, toLevel) and the HQ tower DefenseUpgrade("aa", toLevel), where toLevel is the
	level the player SAW — a repeated tap is refused by the server instead of buying twice.
	Prices on the buttons use the server's shared maths (Shared/Attack/DefenseTowers,
	AttackLogic.upgradeCost), display only.

	Performance: event-driven. Records are built when a pad / tower streams in or is replaced (an
	upgrade swaps the tower model) and destroyed when it streams out; colours / texts are only
	re-written when the wallet or the attack profile changes; BillboardGui.MaxDistance culls
	rendering; the Interaction provider is a scan of <= 5 records. Every board sits on its own local
	invisible anchor part (above the pad / above the tower whatever its level; it never rides the
	build-in fly-in, and boards adorned straight to the streamed pad Trigger did not render).

	Connects to: Shared/Config/{AttackConfig, TycoonConfig, TycoonClientConfig, UIStyleConfig},
	Shared/Attack/{DefenseTowers, AttackLogic}, Shared/Net/Remotes, Client/ClientState,
	Client/Attack/DefenseBoardPlacement, Tycoon/{Interaction, ProducerBillboards (live producer
	boards for the declutter)}, UI/{Create, ButtonFeedback, ScreenManager, Widgets/StudWindow,
	Widgets/InputGlyph}, Client/Attack/AttackClient (starts it).

	Example:
		DefenseWorld.start()
		local offer = DefenseWorld.nearest(rootPosition) -- { distance, context, hint, act }?
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local AttackLogic = require(ReplicatedStorage.Shared.Attack.AttackLogic)
local ButtonFeedback = require(script.Parent.Parent.UI.ButtonFeedback)
local ClientState = require(script.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.UI.Create)
local DefenseBoardPlacement = require(script.Parent.DefenseBoardPlacement)
local DefenseTowers = require(ReplicatedStorage.Shared.Attack.DefenseTowers)
local InputGlyph = require(script.Parent.Parent.UI.Widgets.InputGlyph)
local Interaction = require(script.Parent.Parent.Tycoon.Interaction)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local ProducerBillboards = require(script.Parent.Parent.Tycoon.ProducerBillboards)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local StudWindow = require(script.Parent.Parent.UI.Widgets.StudWindow)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local DefenseWorld = {}

local TOWERS = AttackConfig.Towers
local BOARD = TOWERS.Billboard
local TAGS = AttackConfig.Tags
local LOCAL = Players.LocalPlayer
local Neutral = UIStyleConfig.Neutral
local PAD_ACCENT = UIStyleConfig.Colors.sky.accent

-- Seconds between two intents from this client (the server rate-limits and checks the level too).
local INTENT_DEBOUNCE = 0.35
-- Seconds between two declutter passes (owner R105; only while boards exist).
local DECLUTTER_SECONDS = 0.25
-- Pixels kept clear around boards by the declutter (matches the solver's MarginPixels).
local DECLUTTER_MARGIN = BOARD.Placement.MarginPixels

type Kind = "pad" | "tower"

-- One own pad / tower and its billboard.
type Record = {
	kind: Kind,
	instance: Model,
	tower: number, -- 0 = the HQ Feature tower, 1.. = defence slot
	level: number, -- the tower's level (0 for a pad)
	position: Vector3, -- ground centre (reach checks)
	gui: BillboardGui,
	anchor: BasePart?, -- local invisible anchor the billboard sits on
	plot: number, -- the plot the object stands on (placement solve)
	placeKind: DefenseBoardPlacement.Kind, -- "pad" | "slot" | "hq" (placement solve)
	maxDistance: number, -- the board's culling distance
	hidden: boolean, -- the declutter hid it this pass (gui.Enabled = false)
	button: TextButton, -- the tap target (pad price / UPGRADE pill)
	title: TextLabel,
	cost: TextLabel,
	surface: StudWindow.Surface?, -- the UPGRADE pill face (towers)
	affordable: boolean?,
	maxed: boolean,
	act: () -> (),
	connections: { RBXScriptConnection },
}

local records: { [Instance]: Record } = {}
local lastIntent = -math.huge
local started = false
local anchorFolder: Folder? = nil
local declutterRunning = false

-- A finite number, else `fallback`.
local function num(value: unknown, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

-- The player's Nuke Town cash (synced profile; 0 before the first snapshot).
local function cash(): number
	local profile: any = ClientState.profile
	return if type(profile) == "table" then num(profile.cash, 0) else 0
end

-- The local player's plot (server attribute; 0 = none).
local function myPlot(): number
	return math.floor(num(LOCAL:GetAttribute(AttackConfig.Attr.Plot), 0))
end

-- The display name of a record's tower.
local function nameOf(tower: number): string
	if tower == 0 then
		return "AA Tower"
	end
	local slot = DefenseTowers.slot(tower)
	return if slot ~= nil then slot.name else "AA Tower"
end

--[[
	The next purchase a record offers: (target level, price). A pad = level 1 of its slot; the HQ
	tower = AttackLogic.upgradeCost on the Feature pad price; a slot tower = DefenseTowers.nextStep.
	(0, math.huge) when maxed.
]]
local function nextStep(record: Record): (number, number)
	if record.kind == "pad" then
		return 1, DefenseTowers.costTo(record.tower, 1)
	end
	if record.tower == 0 then
		local padId = TycoonConfig.FeaturePadOf[AttackConfig.FeatureAA]
		local pad = if padId ~= nil then TycoonConfig.PadsById[padId] else nil
		local cost = AttackLogic.upgradeCost(record.level, if pad ~= nil then pad.cost else 0)
		return if cost == math.huge then 0 else record.level + 1, cost
	end
	return DefenseTowers.nextStep(record.tower, record.level)
end

--[[
	Sends a record's buy / upgrade intent (debounced; the server decides) with press feedback
	(coins + purchase sound, or the locked sound when unaffordable).
	@param record Record
	@return boolean — true when an intent was sent
]]
local function act(record: Record): boolean
	local clock = os.clock()
	if clock - lastIntent < INTENT_DEBOUNCE or record.instance.Parent == nil then
		return false
	end
	local toLevel, cost = nextStep(record)
	if toLevel < 1 then
		return false
	end
	lastIntent = clock
	record.button:SetAttribute("FeedbackLocked", cash() < cost)
	ButtonFeedback.fire(record.button)
	local tower = record.tower
	task.spawn(function()
		if tower == 0 then
			Remotes.event("DefenseUpgrade"):FireServer("aa", toLevel)
		else
			Remotes.event("DefenseTower"):FireServer(tower, toLevel)
		end
	end)
	return true
end

-- Re-colours / re-texts one record for the wallet and its level (writes only on change).
local function paint(record: Record)
	local toLevel, cost = nextStep(record)
	local maxed = toLevel < 1
	local affordable = not maxed and cash() >= cost
	local text = if maxed then "" else NumberFormat.money(cost)
	if record.cost.Text ~= text then
		record.cost.Text = text
	end
	if record.affordable == affordable and record.maxed == maxed then
		return
	end
	record.affordable = affordable
	record.maxed = maxed
	if record.kind == "pad" then
		record.cost.TextColor3 = if affordable then PAD_ACCENT else Neutral.Placeholder
		return
	end
	local surface = record.surface
	if surface ~= nil then
		surface.setColor(if maxed then "green" elseif affordable then "cyan" else "grey")
	end
	local upgradeText = record.button:FindFirstChild("UpgradeText")
	if upgradeText ~= nil and upgradeText:IsA("TextLabel") then
		upgradeText.Text = if maxed then "MAX LEVEL" else "UPGRADE"
		upgradeText.Size = if maxed then UDim2.fromScale(0.9, 0.7) else UDim2.fromScale(0.9, 0.56)
		upgradeText.Position = if maxed then UDim2.fromScale(0.05, 0.15) else UDim2.fromScale(0.05, 0.04)
	end
	record.cost.TextColor3 = if affordable then Neutral.CashGreen else Neutral.Placeholder
	record.button.AutoButtonColor = false
	record.button.Active = not maxed
end

-- An outlined, scaled text label.
local function label(parent: Instance, props: { [string]: any }): TextLabel
	return Create.new("TextLabel", {
		Name = props.name or "Label",
		BackgroundTransparency = 1,
		TextScaled = true,
		FontFace = props.font or UIStyleConfig.Fonts.Title,
		TextColor3 = props.color or Neutral.Text,
		Text = props.text or "",
		Size = props.size,
		Position = props.position or UDim2.new(),
		TextXAlignment = props.align or Enum.TextXAlignment.Center,
		ZIndex = props.zIndex or 3,
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
end

-- The placement view of this screen: device class + live viewport height, at the default camera's
-- FOV (boards are read while walking; the picker / launch cinematic FOVs must not re-place them).
local function placementView(): DefenseBoardPlacement.View
	local camera = Workspace.CurrentCamera
	return DefenseBoardPlacement.view(
		ScreenManager.device.class ~= "Desktop",
		if camera ~= nil then camera.ViewportSize.Y else nil,
		TycoonClientConfig.Placement.Fov
	)
end

--[[
	A billboard of a constant pixel size (owner R105: smaller, never ballooning up close; the whole
	board is the tap target, >= 44 pt on touch / TV), depth-tested like every board in the game
	(Studio QA 2026-10-31: AlwaysOnTop boards did not render at all in the playtest client).
	@param maxDistance number — culling distance (pads: PadMaxDistance, towers: MaxDistance)
]]
local function board(name: string, pixels: Vector2, adornee: BasePart, maxDistance: number): BillboardGui
	return Create.new("BillboardGui", {
		Name = name,
		Adornee = adornee,
		Size = UDim2.fromOffset(math.floor(pixels.X), math.floor(pixels.Y)),
		MaxDistance = maxDistance,
		LightInfluence = 0,
		ResetOnSpawn = false,
		Active = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}) :: BillboardGui
end

-- A transparent button covering the whole board (the tap target; visuals sit above it and do not
-- sink input). Activated → the record's act.
local function tapTarget(gui: BillboardGui): TextButton
	return Create.new("TextButton", {
		Name = "Tap",
		Text = "",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Parent = gui,
	}) :: TextButton
end

-- The local folder holding billboard anchors (client-only: never replicated, never streamed out;
-- in Workspace rather than the camera, which a script may replace).
local function anchors(): Folder
	local existing = anchorFolder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "SN_DefenseAnchors"
	folder.Parent = Workspace
	anchorFolder = folder
	return folder
end

-- A local, invisible, physics-free anchor part for one billboard (client-only; destroyed with
-- its record).
local function anchorPart(name: string, position: Vector3): BasePart
	local anchor = Instance.new("Part")
	anchor.Name = name
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.CastShadow = false
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = anchors()
	return anchor
end

-- Builds the record of an own defence BUY pad.
local function buildPad(model: Model, tower: number, plot: number): Record?
	local trigger = model:FindFirstChild("Trigger")
	if trigger == nil or not trigger:IsA("BasePart") then
		return nil
	end
	-- A local anchor at the solved spot above the pad (owner R105: clear of the producer boards;
	-- Studio QA 2026-10-31: boards adorned straight to the streamed pad Trigger did not render on
	-- the client; the local anchor, like the towers', always does).
	local view = placementView()
	local spot = DefenseBoardPlacement.solve(plot, tower, "pad", 0, view)
	local anchor = anchorPart(`PadAnchor_{tower}`, spot.position)
	local gui = board(`DefensePad_{tower}`, view.pixels, anchor, BOARD.PadMaxDistance)
	local tap = tapTarget(gui)
	local title = label(gui, {
		name = "Name",
		text = string.upper(nameOf(tower)),
		font = UIStyleConfig.Fonts.Number,
		size = UDim2.fromScale(1, 0.3),
	})
	local blurb = label(gui, {
		name = "Blurb",
		text = "Shoots down nukes!",
		color = Neutral.TextDim,
		size = UDim2.fromScale(1, 0.2),
		position = UDim2.fromScale(0, 0.29),
	})
	blurb.FontFace = Font.new(blurb.FontFace.Family, Enum.FontWeight.Regular, Enum.FontStyle.Italic)
	local price = Create.new("TextButton", {
		Name = "Price",
		Text = "",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 0.48),
		Position = UDim2.fromScale(0, 0.5),
		ZIndex = 2,
		Parent = gui,
	}) :: TextButton
	price:SetAttribute("FeedbackManual", true)
	price:SetAttribute("FeedbackKind", "Coins")
	price:SetAttribute("FeedbackSound", "purchase")
	price:SetAttribute("FeedbackColor", "sky")
	local cost = label(price, {
		name = "Cost",
		font = UIStyleConfig.Fonts.Number,
		color = PAD_ACCENT,
		stroke = 3,
		size = UDim2.fromScale(1, 1),
	})
	local record: Record = {
		kind = "pad",
		instance = model,
		tower = tower,
		level = 0,
		position = model:GetPivot().Position,
		gui = gui,
		anchor = anchor,
		plot = plot,
		placeKind = "pad",
		maxDistance = BOARD.PadMaxDistance,
		hidden = false,
		button = price,
		title = title,
		cost = cost,
		surface = nil,
		affordable = nil,
		maxed = false,
		act = function() end,
		connections = {},
	}
	record.act = function()
		act(record)
	end
	table.insert(
		record.connections,
		price.Activated:Connect(function()
			record.act()
		end)
	)
	table.insert(
		record.connections,
		tap.Activated:Connect(function()
			record.act()
		end)
	)
	return record
end

-- Builds the record of an own AA tower (HQ or a defence slot).
local function buildTower(model: Model, tower: number, level: number, plot: number): Record
	local pivot = model:GetPivot()
	-- HQ tower: above its mesh. Slot towers (on the plot's flanks): a sign on the plot side at eye
	-- level. Both solved clear of the producer boards (owner R105, DefenseBoardPlacement).
	local placeKind: DefenseBoardPlacement.Kind = if tower == 0 then "hq" else "slot"
	local view = placementView()
	local spot = DefenseBoardPlacement.solve(plot, tower, placeKind, level, view)
	local anchor = anchorPart(`Anchor_{tower}`, spot.position)
	local gui = board(`DefenseTower_{tower}`, view.pixels, anchor, BOARD.MaxDistance)
	local tap = tapTarget(gui)
	local title = label(gui, {
		name = "Name",
		text = `{string.upper(nameOf(tower))}  Lv {level}/{AttackConfig.MaxLevel}`,
		font = UIStyleConfig.Fonts.Number,
		size = UDim2.fromScale(1, 0.34),
	})
	-- UPGRADE pill: cyan stud face (grey while unaffordable, green MAX LEVEL), cost, key glyph.
	local pill = Create.new("TextButton", {
		Name = "Upgrade",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(0.78, 0.6),
		Position = UDim2.fromScale(0.04, 0.38),
		ZIndex = 3,
		Parent = gui,
	}) :: TextButton
	pill:SetAttribute("FeedbackManual", true)
	pill:SetAttribute("FeedbackKind", "Coins")
	pill:SetAttribute("FeedbackSound", "purchase")
	pill:SetAttribute("FeedbackColor", "cyan")
	local surface = StudWindow.surface(pill, "grey", {
		tile = UIStyleConfig.StudTile.Button,
		studTransparency = 0.6,
		edge = 3,
		corner = 10,
	})
	label(pill, {
		name = "UpgradeText",
		text = "UPGRADE",
		font = UIStyleConfig.Fonts.Number,
		stroke = 3,
		size = UDim2.fromScale(0.9, 0.56),
		position = UDim2.fromScale(0.05, 0.04),
		zIndex = 4,
	})
	local cost = label(pill, {
		name = "Cost",
		font = UIStyleConfig.Fonts.Number,
		color = Neutral.Placeholder,
		size = UDim2.fromScale(0.8, 0.34),
		position = UDim2.fromScale(0.1, 0.6),
		zIndex = 4,
	})
	local glyph = InputGlyph.action("Interact", 22)
	glyph.AnchorPoint = Vector2.new(0, 0.5)
	glyph.Position = UDim2.fromScale(0.85, 0.68)
	glyph.ZIndex = 5
	glyph.Parent = gui
	local record: Record = {
		kind = "tower",
		instance = model,
		tower = tower,
		level = level,
		position = pivot.Position,
		gui = gui,
		anchor = anchor,
		plot = plot,
		placeKind = placeKind,
		maxDistance = BOARD.MaxDistance,
		hidden = false,
		button = pill,
		title = title,
		cost = cost,
		surface = surface,
		affordable = nil,
		maxed = false,
		act = function() end,
		connections = {},
	}
	record.act = function()
		act(record)
	end
	table.insert(
		record.connections,
		pill.Activated:Connect(function()
			record.act()
		end)
	)
	table.insert(
		record.connections,
		tap.Activated:Connect(function()
			record.act()
		end)
	)
	return record
end

--[[
	Owner R105 runtime declutter (one pass): projects every own board and every visible own
	producer board (Tycoon/ProducerBillboards: live adornee + current studs height) with the LIVE
	camera; nearest boards first, a defence board whose screen rectangle (+ DECLUTTER_MARGIN px)
	overlaps a producer board or a nearer kept defence board is hidden (gui.Enabled = false) — except
	the board of the pad / tower the player stands at (its Interact target). Writes only on change.
]]
local function declutter()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local viewportY = camera.ViewportSize.Y
	local tanHalf = math.tan(math.rad(camera.FieldOfView) / 2)
	local eye = camera.CFrame.Position
	local character = LOCAL.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	local rootPosition = if root ~= nil and root:IsA("BasePart") then root.Position else nil
	-- Screen rectangles: { x, y, half x, half y } (viewport px).
	local blockers: { { number } } = {}
	for _, producer in ProducerBillboards.ownRecords() do
		local gui = producer.gui
		if producer.visible and gui.Enabled and gui.Parent ~= nil then
			local world = producer.point.WorldPosition
			if (world - eye).Magnitude <= gui.MaxDistance then
				local screen, onScreen = camera:WorldToViewportPoint(world)
				if onScreen and screen.Z > 0.5 then
					local height = producer.height / (2 * screen.Z * tanHalf) * viewportY
					table.insert(
						blockers,
						{ screen.X, screen.Y, height * TycoonClientConfig.Billboard.Aspect / 2, height / 2 }
					)
				end
			end
		end
	end
	type Seen = { record: Record, x: number, y: number, depth: number }
	local seen: { Seen } = {}
	for _, record in records do
		local anchor = record.anchor
		if anchor == nil then
			continue
		end
		local screen, onScreen = camera:WorldToViewportPoint(anchor.Position)
		if onScreen and screen.Z > 0.5 and (anchor.Position - eye).Magnitude <= record.maxDistance then
			table.insert(seen, { record = record, x = screen.X, y = screen.Y, depth = screen.Z })
		elseif record.hidden then
			-- Off screen / culled anyway: show it again for when it comes back into view.
			record.hidden = false
			record.gui.Enabled = true
		end
	end
	table.sort(seen, function(a: Seen, b: Seen): boolean
		return a.depth < b.depth
	end)
	for _, entry in seen do
		local record = entry.record
		local size = record.gui.Size
		local hx, hy = size.X.Offset / 2, size.Y.Offset / 2
		local clash = false
		local reach = if record.kind == "pad" then TOWERS.PadReach else TOWERS.TowerReach
		local standing = false
		if rootPosition ~= nil then
			local offset = record.position - rootPosition
			standing = math.sqrt(offset.X * offset.X + offset.Z * offset.Z) <= reach + 2
		end
		if not standing then
			for _, other in blockers do
				if
					math.abs(entry.x - other[1]) < hx + other[3] + DECLUTTER_MARGIN
					and math.abs(entry.y - other[2]) < hy + other[4] + DECLUTTER_MARGIN
				then
					clash = true
					break
				end
			end
		end
		if clash ~= record.hidden then
			record.hidden = clash
			record.gui.Enabled = not clash
		end
		if not clash then
			-- Kept boards block the farther ones (the nearer board wins).
			table.insert(blockers, { entry.x, entry.y, hx, hy })
		end
	end
end

-- Runs the declutter while any board exists (one task; restarted by `add` when needed).
local function startDeclutter()
	if declutterRunning then
		return
	end
	declutterRunning = true
	task.spawn(function()
		while next(records) ~= nil do
			local ok, err = pcall(declutter)
			if not ok then
				warn(`[DefenseWorld] declutter failed: {err}`)
			end
			task.wait(DECLUTTER_SECONDS)
		end
		declutterRunning = false
	end)
end

-- Device class / viewport changed: re-solve every board's spot + size (memoised per view).
local lastViewKey = ""
local function replaceAll()
	local view = placementView()
	local key = `{view.device}:{view.viewportY}`
	if key == lastViewKey then
		return
	end
	lastViewKey = key
	for _, record in records do
		local spot = DefenseBoardPlacement.solve(record.plot, record.tower, record.placeKind, record.level, view)
		if record.anchor ~= nil then
			record.anchor.CFrame = CFrame.new(spot.position)
		end
		record.gui.Size = UDim2.fromOffset(math.floor(view.pixels.X), math.floor(view.pixels.Y))
	end
end

-- Removes one record (billboard, anchor, connections).
local function remove(instance: Instance)
	local record = records[instance]
	if record == nil then
		return
	end
	records[instance] = nil
	for _, connection in record.connections do
		connection:Disconnect()
	end
	record.gui:Destroy()
	if record.anchor ~= nil then
		record.anchor:Destroy()
	end
end

-- Builds a record for a pad / tower when it is the local player's (idempotent per instance).
local function add(instance: Instance, kind: Kind)
	if records[instance] ~= nil or not instance:IsA("Model") or instance.Parent == nil then
		return
	end
	local tower = math.floor(num(instance:GetAttribute("Tower"), 0))
	local record: Record? = nil
	if kind == "pad" then
		local plot = math.floor(num(instance:GetAttribute("Plot"), 0))
		if
			instance:GetAttribute("OwnerUserId") ~= LOCAL.UserId
			or AttackGeometry.validTower(tower) == nil
			or AttackGeometry.validPlot(plot) == nil
		then
			return
		end
		record = buildPad(instance, tower, plot)
	else
		local plot = math.floor(num(instance:GetAttribute("Plot"), 0))
		local level = math.floor(num(instance:GetAttribute("Level"), 0))
		-- Own plot only (rival islands / test bots use slots past the plots or other plots).
		if plot < 1 or plot ~= myPlot() or AttackGeometry.validPlot(plot) == nil or level < 1 then
			return
		end
		if tower ~= 0 and AttackGeometry.validTower(tower) == nil then
			return
		end
		record = buildTower(instance, tower, level, plot)
	end
	if record == nil then
		return
	end
	records[instance] = record
	paint(record)
	record.gui.Parent = LOCAL:FindFirstChildOfClass("PlayerGui")
	startDeclutter()
end

-- Re-evaluates every tagged pad / tower (the plot changed hands, or start).
local function rebuild()
	for instance in records do
		remove(instance)
	end
	for _, instance in CollectionService:GetTagged(TAGS.DefensePad) do
		add(instance, "pad")
	end
	for _, instance in CollectionService:GetTagged(TAGS.Turret) do
		add(instance, "tower")
	end
end

--[[
	The nearest own pad / tower in reach that still has something to buy (Interaction provider):
	pads within Towers.PadReach, towers within Towers.TowerReach (horizontal studs).
	@param root Vector3 — the character root position
	@return Interaction.Interactable?
]]
function DefenseWorld.nearest(root: Vector3): Interaction.Interactable?
	local best: Record? = nil
	local bestDistance = math.huge
	for _, record in records do
		if record.maxed or record.instance.Parent == nil then
			continue
		end
		local offset = record.position - root
		local distance = math.sqrt(offset.X * offset.X + offset.Z * offset.Z)
		local reach = if record.kind == "pad" then TOWERS.PadReach else TOWERS.TowerReach
		if distance <= reach and distance < bestDistance then
			best, bestDistance = record, distance
		end
	end
	if best == nil then
		return nil
	end
	local _, cost = nextStep(best)
	return {
		distance = bestDistance,
		context = if best.kind == "pad" then "Pad" else "Tower",
		hint = `{if best.kind == "pad" then "Buy" else "Upgrade"} {NumberFormat.money(cost)}`,
		act = best.act,
	}
end

--[[
	Every own board's diagnostics (QA, tools/qa/attack_view.py): kind, tower, level, spot, size,
	hidden by the declutter.
]]
function DefenseWorld.boards(): { { [string]: any } }
	local list: { { [string]: any } } = {}
	for _, record in records do
		local entry: { [string]: any } = {
			kind = record.placeKind,
			tower = record.tower,
			level = record.level,
			plot = record.plot,
			position = if record.anchor ~= nil then record.anchor.Position else nil,
			size = record.gui.Size,
			maxDistance = record.gui.MaxDistance,
			hidden = record.hidden,
		}
		table.insert(list, entry)
	end
	return list
end

--[[ Number of own billboards shown (debug / verification). ]]
function DefenseWorld.count(): number
	local count = 0
	for _ in records do
		count += 1
	end
	return count
end

--[[ Starts the in-world defence buttons (idempotent; AttackClient.start calls it). ]]
function DefenseWorld.start()
	if started then
		return
	end
	started = true
	CollectionService:GetInstanceAddedSignal(TAGS.DefensePad):Connect(function(instance: Instance)
		add(instance, "pad")
	end)
	CollectionService:GetInstanceRemovedSignal(TAGS.DefensePad):Connect(remove)
	CollectionService:GetInstanceAddedSignal(TAGS.Turret):Connect(function(instance: Instance)
		add(instance, "tower")
	end)
	CollectionService:GetInstanceRemovedSignal(TAGS.Turret):Connect(remove)
	-- My plot index arrives / changes (join, plot swap): own-ness of every tower changes.
	LOCAL:GetAttributeChangedSignal(AttackConfig.Attr.Plot):Connect(rebuild)
	-- Wallet or attack levels changed: re-colour (texts / colours only change on change).
	ClientState.ProfileChanged:Connect(function(_profile, fields)
		if fields == nil or table.find(fields, "cash") ~= nil or table.find(fields, "attack") ~= nil then
			for _, record in records do
				paint(record)
			end
		end
	end)
	Interaction.addProvider(DefenseWorld.nearest)
	-- Owner R105: a device / viewport change re-solves the board spots + sizes.
	ScreenManager.LayoutChanged:Connect(replaceAll)
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			task.defer(replaceAll)
		end)
	end
	lastViewKey = (function(): string
		local view = placementView()
		return `{view.device}:{view.viewportY}`
	end)()
	rebuild()
end

return DefenseWorld
