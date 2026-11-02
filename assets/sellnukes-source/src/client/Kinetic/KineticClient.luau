--!strict
--[[
	KineticClient — the client of owner R90's Mega Lever + Tip Jar (spec docs/superpowers/specs/
	2026-10-31-r90-hands-on-design.md §2 / §3; docs/kinetic.md). Boot list "Kinetic/KineticClient".

	Per prop that streams in (CollectionService tags KineticConfig.Tags, server-set):
		every client   the lever's stud-panel countdown board ("MEGA LEVER" + READY! / m:ss /
		               RESTING); the arm swing when PulledAt changes (KineticVisuals.swing); the
		               jar's coin pile from Fill (KineticVisuals.setCoins); the coin burst when
		               CollectedAt changes and the coin shower when TippedAt changes (KineticFx)
		the owner      (model attribute OwnerUserId == the local player) client-only ProximityPrompts —
		               nobody else sees or can use them:
		                   lever  "Pull!" HOLD (Lever.Prompt.HoldSeconds), enabled only while ready
		                   jar    "Collect tips" short hold, enabled while it holds coins
		               keyboard E / gamepad X / tap-and-hold on touch — the engine draws the device
		               glyph and the tap target (>= 44 pt). Prompts pause while any modal window is
		               open (ScreenManager), so nothing triggers behind a menu. Triggered sends the
		               KineticAction intent ("pull" / "collect"); the server decides everything.
		               The jar's own board ("TIP JAR" + fill % / FULL! WALK IN) is the owner's only.
	Owner wire (S→C "Kinetic", KineticLogic.decodeWire first):
		pull     the chute ride + confetti + the "MEGA PULL!" banner with "Every machine made bonus
		         nukes: +$X" (KineticFx.megaPull; owner R112 wording), coins fly into
		         the HUD (CurrencyFly.fromWorld "reward"), gamepad / phone rumble (Haptics "Purchase")
		collect  CurrencyFly from the jar + "+$X TIPS!" + Haptics "Reward" (the burst itself comes
		         from CollectedAt, so everyone nearby sees it)
		tip      a small "+$X" over the jar (the shower comes from TippedAt)

	Performance: event-driven (tags, attribute signals, modal open / close) plus ONE 1 Hz Heartbeat
	accumulator that exists only while a prop is streamed in (countdown text + prompt enable);
	board text writes only on change; boards cull at their MaxDistance; FX on KineticFx's transient
	driver with pools. Everything a prop owns is parented under it, so streaming out cleans it up.

	Connects to: Shared/Config/{KineticConfig}, Shared/Tycoon/KineticLogic, Shared/Net/Remotes,
	Kinetic/{KineticFx, KineticVisuals}, Tycoon/WorldLookup (amount labels), Platform/Haptics,
	UI/{Create, ScreenManager, Kit/StudUI, Widgets/PanelBackdrop, Hud/CurrencyFly}.

	Example: KineticClient.Start() -- from the client boot list
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Create = require(script.Parent.Parent.UI.Create)
local CurrencyFly = require(script.Parent.Parent.UI.Hud.CurrencyFly)
local Haptics = require(script.Parent.Parent.Platform.Haptics)
local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)
local KineticFx = require(script.Parent.KineticFx)
local KineticLogic = require(ReplicatedStorage.Shared.Tycoon.KineticLogic)
local KineticVisuals = require(script.Parent.KineticVisuals)
local PanelBackdrop = require(script.Parent.Parent.UI.Widgets.PanelBackdrop)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)
local WorldLookup = require(script.Parent.Parent.Tycoon.WorldLookup)

local ATTR = KineticConfig.Attr
local LEVER = KineticConfig.Lever
local JAR = KineticConfig.TipJar
local COPY = KineticConfig.Copy

local KineticClient = {}

-- Instance names QA probes read (tools/qa/kinetic_client.luau).
KineticClient.LeverPromptName = "MegaLeverPrompt"
KineticClient.JarPromptName = "TipJarPrompt"
KineticClient.BoardName = "KineticBoard"

type Board = { gui: BillboardGui, status: TextLabel }
-- The parts of KineticConfig's frozen Board / Prompt tables these builders read.
type BoardConfig = {
	read SizeStuds: Vector2,
	read Offset: Vector3,
	read MaxDistance: number,
	read Title: string,
	read Color: Color3,
	read Stroke: Color3,
	read TileSize: number,
	read TextureTransparency: number,
}
type PromptConfig = {
	read ActionText: string,
	read ObjectText: string,
	read HoldSeconds: number,
	read MaxDistance: number,
	read Offset: Vector3,
	read KeyboardKey: Enum.KeyCode,
	read GamepadKey: Enum.KeyCode,
}
type Record = {
	model: Model,
	kind: "lever" | "jar",
	mine: boolean,
	board: Board?,
	prompt: ProximityPrompt?,
	connections: { RBXScriptConnection },
}

local records: { [Model]: Record } = {}
local recordCount = 0
local ticker: RBXScriptConnection? = nil
local accumulator = 0
local started = false

-- The prop's invisible server collider (the anchor for boards + prompt attachments), or nil.
local function colliderOf(model: Model): BasePart?
	local part = model:FindFirstChild("Collider")
	return if part ~= nil and part:IsA("BasePart") then part else nil
end

-- True when the local player owns this prop.
local function isMine(model: Model): boolean
	return model:GetAttribute(ATTR.Owner) == Players.LocalPlayer.UserId
end

-- The world id a prop stands in ("main" when missing).
local function worldOf(model: Model): string
	local value = model:GetAttribute(ATTR.World)
	return if KineticLogic.isWorldKey(value) then value :: string else "main"
end

-- A switch attribute (missing = on).
local function switchOn(name: string): boolean
	return ReplicatedStorage:GetAttribute(name) ~= false
end

--[[
	A stud-panel board hung over a prop (studs-sized BillboardGui: shrinks with distance, culls at
	MaxDistance). Title on top, a status line under it.
]]
local function buildBoard(model: Model, anchor: BasePart, config: BoardConfig): Board
	local worldOffset = (model:GetPivot() * config.Offset) - anchor.Position
	local gui = Create.new("BillboardGui", {
		Name = KineticClient.BoardName,
		Size = UDim2.fromScale(config.SizeStuds.X, config.SizeStuds.Y),
		StudsOffsetWorldSpace = worldOffset,
		MaxDistance = config.MaxDistance,
		LightInfluence = 0,
		AlwaysOnTop = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Adornee = anchor,
	}) :: BillboardGui
	local panel = Create.new("Frame", {
		Name = "Panel",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = config.Color,
		BorderSizePixel = 0,
		Parent = gui,
	}) :: Frame
	Create.new("UICorner", { CornerRadius = UDim.new(0.2, 0), Parent = panel })
	Create.new("UIStroke", {
		Color = config.Stroke,
		Thickness = 3,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = panel,
	})
	-- Owner rule 2: every UI surface wears the RoBeasts stud material.
	PanelBackdrop.new(panel, { tileSize = config.TileSize, textureTransparency = config.TextureTransparency })
	StudUI.text({
		name = "Title",
		text = config.Title,
		textSize = 48,
		font = "shout",
		scaled = true,
		size = UDim2.fromScale(0.92, 0.48),
		position = UDim2.fromScale(0.04, 0.04),
		zIndex = 2,
		parent = panel,
	})
	local status = StudUI.text({
		name = "Status",
		text = "",
		textSize = 40,
		font = "number",
		scaled = true,
		size = UDim2.fromScale(0.92, 0.42),
		position = UDim2.fromScale(0.04, 0.54),
		zIndex = 2,
		parent = panel,
	})
	gui.Parent = anchor -- last: appears whole, streams out with the prop
	return { gui = gui, status = status }
end

-- A client-only ProximityPrompt on an attachment at a model-space point of the prop.
local function buildPrompt(
	model: Model,
	anchor: BasePart,
	name: string,
	config: PromptConfig,
	action: string
): ProximityPrompt
	local attachment = Create.new("Attachment", { Name = name .. "Anchor", Parent = anchor }) :: Attachment
	attachment.WorldPosition = model:GetPivot() * config.Offset
	local prompt = Create.new("ProximityPrompt", {
		Name = name,
		ActionText = config.ActionText,
		ObjectText = config.ObjectText,
		HoldDuration = config.HoldSeconds,
		MaxActivationDistance = config.MaxDistance,
		KeyboardKeyCode = config.KeyboardKey,
		GamepadKeyCode = config.GamepadKey,
		RequiresLineOfSight = false,
		ClickablePrompt = true,
		Enabled = false,
		Parent = attachment,
	}) :: ProximityPrompt
	prompt.Triggered:Connect(function()
		Remotes.event("KineticAction"):FireServer(action)
	end)
	return prompt
end

-- Writes a TextLabel's text / colour only when they change.
local function setText(label: TextLabel, text: string, color: Color3?)
	if label.Text ~= text then
		label.Text = text
	end
	if color ~= nil and label.TextColor3 ~= color then
		label.TextColor3 = color
	end
end

-- Lever board text + owner prompt enable from ReadyAt / the switch / open menus.
local function syncLever(record: Record)
	local model = record.model
	local readyAt = model:GetAttribute(ATTR.ReadyAt)
	local left =
		KineticLogic.cooldownLeft(if type(readyAt) == "number" then readyAt else 0, Workspace:GetServerTimeNow())
	local on = switchOn(ATTR.LeverOn)
	local board = record.board
	if board ~= nil then
		local Board = LEVER.Board
		if not on then
			setText(board.status, Board.Off, Board.WaitColor)
		elseif left > 0 then
			setText(board.status, KineticLogic.formatCountdown(left), Board.WaitColor)
		else
			setText(board.status, if record.mine then Board.Ready else Board.ReadyOther, Board.ReadyColor)
		end
	end
	local prompt = record.prompt
	if prompt ~= nil then
		local enabled = on and left <= 0 and not ScreenManager.anyModalOpen()
		if prompt.Enabled ~= enabled then
			prompt.Enabled = enabled
		end
	end
end

-- Jar coin pile (everyone) + the owner's board / prompt from Fill / Full / the switch.
local function syncJar(record: Record, pile: boolean)
	local model = record.model
	local fill = model:GetAttribute(ATTR.Fill)
	local ratio = if type(fill) == "number" then fill else 0
	if pile then
		KineticVisuals.setCoins(model, ratio)
	end
	local on = switchOn(ATTR.JarOn)
	local board = record.board
	if board ~= nil then
		local text = if model:GetAttribute(ATTR.Full) == true
			then JAR.Board.Full
			else `{math.floor(ratio * 100 + 0.5)}%`
		setText(board.status, text, JAR.Board.TextColor)
	end
	local prompt = record.prompt
	if prompt ~= nil then
		local enabled = on and ratio > 0 and not ScreenManager.anyModalOpen()
		if prompt.Enabled ~= enabled then
			prompt.Enabled = enabled
		end
	end
end

-- The 1 Hz pass over every streamed-in prop (countdowns tick, prompts follow the clock).
local function syncAll()
	for _, record in records do
		if record.kind == "lever" then
			syncLever(record)
		else
			syncJar(record, false)
		end
	end
end

-- Connects / disconnects the 1 Hz ticker with the number of tracked props.
local function updateTicker()
	if recordCount > 0 and ticker == nil then
		ticker = RunService.Heartbeat:Connect(function(dt: number)
			accumulator += dt
			if accumulator >= 1 then
				accumulator = 0
				syncAll()
			end
		end)
	elseif recordCount == 0 and ticker ~= nil then
		ticker:Disconnect()
		ticker = nil
	end
end

-- Forgets a prop (streamed out / destroyed / untagged): connections + client instances.
local function drop(model: Model)
	local record = records[model]
	if record == nil then
		return
	end
	records[model] = nil
	recordCount -= 1
	for _, connection in record.connections do
		connection:Disconnect()
	end
	if record.board ~= nil then
		record.board.gui:Destroy()
	end
	if record.prompt ~= nil then
		local attachment = record.prompt.Parent
		record.prompt:Destroy()
		if attachment ~= nil then
			attachment:Destroy()
		end
	end
	updateTicker()
end

-- A server time stamp attribute that changed recently enough to animate (not history on stream-in).
local function fresh(model: Model, attribute: string): boolean
	local stamp = model:GetAttribute(attribute)
	return type(stamp) == "number" and stamp > 0 and Workspace:GetServerTimeNow() - stamp <= LEVER.FreshSeconds
end

-- Starts tracking a lever model.
local function addLever(model: Model)
	local anchor = colliderOf(model)
	if anchor == nil then
		return
	end
	local record: Record = { model = model, kind = "lever", mine = isMine(model), connections = {} }
	record.board = buildBoard(model, anchor, LEVER.Board)
	if record.mine then
		record.prompt = buildPrompt(model, anchor, KineticClient.LeverPromptName, LEVER.Prompt, "pull")
	end
	table.insert(
		record.connections,
		model:GetAttributeChangedSignal(ATTR.PulledAt):Connect(function()
			if fresh(model, ATTR.PulledAt) then
				KineticVisuals.swing(model)
			end
		end)
	)
	table.insert(
		record.connections,
		model:GetAttributeChangedSignal(ATTR.ReadyAt):Connect(function()
			syncLever(record)
		end)
	)
	records[model] = record
	recordCount += 1
	syncLever(record)
	updateTicker()
end

-- Starts tracking a jar model.
local function addJar(model: Model)
	local anchor = colliderOf(model)
	if anchor == nil then
		return
	end
	local record: Record = { model = model, kind = "jar", mine = isMine(model), connections = {} }
	if record.mine then
		record.board = buildBoard(model, anchor, JAR.Board)
		record.prompt = buildPrompt(model, anchor, KineticClient.JarPromptName, JAR.Prompt, "collect")
	end
	for _, name in { ATTR.Fill, ATTR.Full } do
		table.insert(
			record.connections,
			model:GetAttributeChangedSignal(name):Connect(function()
				syncJar(record, true)
			end)
		)
	end
	table.insert(
		record.connections,
		model:GetAttributeChangedSignal(ATTR.CollectedAt):Connect(function()
			if fresh(model, ATTR.CollectedAt) then
				KineticFx.coinBurst(model)
			end
		end)
	)
	table.insert(
		record.connections,
		model:GetAttributeChangedSignal(ATTR.TippedAt):Connect(function()
			if fresh(model, ATTR.TippedAt) then
				KineticFx.coinShower(model)
			end
		end)
	)
	records[model] = record
	recordCount += 1
	syncJar(record, true)
	-- A build-in animates the pieces (and their transparency) for a few seconds: apply the coin
	-- pile again once it has settled.
	local settle = KineticVisuals.buildInLeft(model)
	if settle > 0 then
		task.delay(settle, function()
			if records[model] == record then
				syncJar(record, true)
			end
		end)
	end
	updateTicker()
end

-- A tagged instance streamed in / was tagged.
local function consider(instance: Instance, kind: "lever" | "jar")
	if not instance:IsA("Model") or records[instance] ~= nil then
		return
	end
	local model = instance :: Model
	-- The server parents the collider before the model, so it is normally there already; a short
	-- wait covers a streaming edge where the model arrives first.
	if colliderOf(model) == nil then
		task.spawn(function()
			model:WaitForChild("Collider", 5)
			if model.Parent ~= nil and records[model] == nil then
				if kind == "lever" then
					addLever(model)
				else
					addJar(model)
				end
			end
		end)
		return
	end
	if kind == "lever" then
		addLever(model)
	else
		addJar(model)
	end
end

-- The prop model of the local player in a world (nil when not streamed in).
local function myProp(kind: "lever" | "jar", worldId: string): Model?
	for model, record in records do
		if record.kind == kind and record.mine and worldOf(model) == worldId then
			return model
		end
	end
	return nil
end

-- An amount label in the world's currency style ("+$1.2M" / "+1.2K Bones").
local function plus(worldId: string, amount: number): string
	return "+" .. WorldLookup.label(worldId, amount)
end

-- The owner's wire: payouts + tips (FX + CurrencyFly + rumble).
local function onWire(raw: unknown)
	local wire = KineticLogic.decodeWire(raw)
	if wire == nil then
		return
	end
	if wire.kind == "pull" then
		local lever = myProp("lever", wire.world)
		if lever ~= nil then
			KineticFx.megaPull(
				lever,
				wire.cycles,
				COPY.MegaPull,
				string.format(COPY.MegaPullSub, plus(wire.world, wire.total))
			)
			local tray = lever:GetPivot() * LEVER.Chute.Points[#LEVER.Chute.Points]
			CurrencyFly.fromWorld(wire.currency, wire.total, tray, "reward")
		end
		Haptics.play("Purchase")
	elseif wire.kind == "collect" then
		local jar = myProp("jar", wire.world)
		if jar ~= nil then
			local mouth = jar:GetPivot() * Vector3.new(0, 5.5, 0)
			KineticFx.pop(mouth + Vector3.new(0, 2, 0), `{plus(wire.world, wire.amount)} {COPY.Tips}`, nil)
			CurrencyFly.fromWorld(wire.currency, wire.amount, mouth, "reward")
		end
		Haptics.play("Reward")
	elseif wire.kind == "tip" then
		local jar = myProp("jar", wire.world)
		if jar ~= nil then
			KineticFx.pop(jar:GetPivot() * Vector3.new(0, 7.5, 0), plus(wire.world, wire.amount), nil)
		end
	end
end

--[[ QA probe: tracked props + FX state (tools/qa/kinetic_client.luau). ]]
function KineticClient.stats(): { [string]: any }
	local levers, jars, mineLever, mineJar = 0, 0, 0, 0
	for _, record in records do
		if record.kind == "lever" then
			levers += 1
			mineLever += if record.mine then 1 else 0
		else
			jars += 1
			mineJar += if record.mine then 1 else 0
		end
	end
	return {
		levers = levers,
		jars = jars,
		myLevers = mineLever,
		myJars = mineJar,
		ticking = ticker ~= nil,
		fx = KineticFx.stats(),
	}
end

function KineticClient.Init() end

function KineticClient.Start()
	if started then
		return
	end
	started = true
	for kind, tag in { lever = KineticConfig.Tags.Lever, jar = KineticConfig.Tags.Jar } :: { [string]: string } do
		local which: "lever" | "jar" = if kind == "lever" then "lever" else "jar"
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance: Instance)
			consider(instance, which)
		end)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance: Instance)
			if instance:IsA("Model") then
				drop(instance)
			end
		end)
		for _, instance in CollectionService:GetTagged(tag) do
			consider(instance, which)
		end
	end
	Remotes.event("Kinetic").OnClientEvent:Connect(onWire)
	-- Prompts pause behind menus and come back when they close; switches apply at once.
	ScreenManager.Opened:Connect(syncAll)
	ScreenManager.Closed:Connect(syncAll)
	ReplicatedStorage:GetAttributeChangedSignal(ATTR.LeverOn):Connect(syncAll)
	ReplicatedStorage:GetAttributeChangedSignal(ATTR.JarOn):Connect(syncAll)
end

return KineticClient
