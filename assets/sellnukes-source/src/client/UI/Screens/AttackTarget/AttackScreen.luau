--!strict
--[[
	AttackScreen ("Attack") — the target picker of Attack mode (spec §6 "Attack target picker
	(◀ name ▶, CANCEL)", reference docs/reference/missiles-vs-cities/22 + 25).

	Look: no window — the world IS the screen. The camera flies to a top-down view over the
	picked plot (Scriptable camera, tweened between targets), a red reticle sits over the base, and
	stud UI frames it:
		top     [ < ]  target name plate  [ > ]   + an info line (area, AA level, $/s, status)
		bottom  DEFENSE · LAUNCH! / REVENGE! (orange) · BARRAGE xN (stored) or BARRAGE R$ (product) ·
		        CANCEL — one centred row, scaled to fit the canvas width (never overlapping). Owner
		        R80: DEFENSE turns into a red DEFEND! while I can be nuked with no AA tower or can
		        afford an unbuilt tower slot (AttackClient.defenceAlert) — the HUD Attack button is
		        the route to the Defense window, and it shows as soon as I can be nuked.
		right   your launcher / stored nukes + the Mega Launcher pass (above the row; middle right
		        on short phone canvases)
	Touch: the thumbstick / jump button are hidden while the picker owns the camera (restored on
	close), so nothing sits under the row and no unseen walking happens.
	Streaming (owner R104 "you cant see peoples bases in the attack menu"): every framed target goes
	through Client/Attack/PickerView — a server replication focus (Server/Attack/PickerFocus) keeps
	the base streamed in while the picker is open, plus a RequestStreamAroundAsync first push — and a
	"LOADING BASE..." stud plate with a shimmer bar shows until the target's parts are there (static
	under Reduce Motion). Camera.Focus follows the framed target (Scriptable camera LOD / lighting).
	Owner R133 ("when attacking people all I see is this, not their base still"): the camera frames
	the target's BUILT areas close up (Shared/Attack/PickerFrame: <= 320 studs, a new garage ~156;
	the old whole-plot view sat ~890 studs up and a live client drew nothing there), a big base
	keeps the aimed area in view (changing the aim pans), the stream focus sits on the built base,
	and the info lines live in an inner Content frame (the studded plate had grown into a ~550 px
	grey wall over the middle of the screen).
	The HUD fades out while it is open (ScreenManager focus reason "AttackPicker"). No "IN COMBAT"
	banner: nobody loses anything.

	Targets (owner R43, never an unexplained empty list): eligible players first (Revenge, ready),
	then ineligible players GREYED with their reason (shield countdown / "still new"), then the
	Rival Factories (NPC bases on islands off the map edge; the camera flies out to the island,
	the info line shows their AA level and what one hit pays). The empty card only appears when
	the owner admin switched the rivals off and nobody else is around; it says why.

	Input (owner R11, console + mobile first):
		gamepad  LB / RB previous / next target, A on the selected button (LAUNCH first), Y BARRAGE,
		         X REVENGE, LT DEFENSE, B close; D-pad / stick move the selection
		keyboard Q / E or ← / → targets, Enter / Space launch, B barrage, R revenge, V defense,
		         X / Backspace close
		touch    every action is a >= 44 pt stud button; CANCEL closes
	All bindings live in AttackConfig.Client.Keys and are bound only while the picker is open.
	Owner R122 (no accidental purchase prompts): the Robux buttons (BARRAGE while no Barrage nukes
	are stored, the Mega Launcher pass) are tagged BUYs behind UI/PurchaseGuard — the cursor opens
	on LAUNCH / CANCEL, and neither a button nor the B / Y key prompts for the press that opened
	the picker.

	Trust: every number comes from replicated server attributes / the synced profile, and the
	buttons only send intents (AttackClient); the server re-checks everything.

	Connects to: Client/Attack/{AttackClient, PickerView}, Shared/Attack/{AttackGeometry, AttackLogic,
	PickerFrame}, Shared/Config/{AttackConfig, MonetizationConfig}, UI/{ScreenManager, Create,
	Kit/StudUI, Widgets/StudWindow}, Screens/Defense (DEFENSE button).

	Example: ScreenManager.open("Attack")   (HUD Attack button, the console prompt, REVENGE chips)
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AttackClient = require(script.Parent.Parent.Parent.Parent.Attack.AttackClient)
local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local AttackLogic = require(ReplicatedStorage.Shared.Attack.AttackLogic)
local PickerFrame = require(ReplicatedStorage.Shared.Attack.PickerFrame)
local KnockdownConfig = require(ReplicatedStorage.Shared.Config.KnockdownConfig)
local ClientState = require(script.Parent.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Parent.Create)
local InputGlyph = require(script.Parent.Parent.Parent.Widgets.InputGlyph)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PickerLayout = require(script.Parent.PickerLayout)
local PickerView = require(script.Parent.Parent.Parent.Parent.Attack.PickerView)
-- Owner R122 purchase-focus hygiene (opening-press guard, BUY tags, safe default selection).
local PurchaseGuard = require(script.Parent.Parent.Parent.PurchaseGuard)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)

local NAME = "Attack"
local FOCUS_REASON = "AttackPicker"
local BIND_PREFIX = "SN_AttackPicker_"
local CLIENT = AttackConfig.Client
local KEYS = CLIENT.Keys
local LOCAL = Players.LocalPlayer

-- One AttackConfig.Client.Keys entry (frozen config tables are read-only).
type Binding = typeof(KEYS.PrevTarget)
-- Platform/GamepadNav.cycler handle (LB / RB, Q / E while enabled).
type Cycler = { enable: () -> (), disable: () -> () }

-- Status line text + colour per target status.
local STATUS_TEXT: { [string]: string } = {
	ready = "READY TO NUKE!",
	shield = "SHIELDED",
	protected = "PROTECTED",
	revenge = "REVENGE READY!",
}
local STATUS_COLOR: { [string]: Color3 } = {
	ready = Color3.fromRGB(120, 230, 90),
	shield = Color3.fromRGB(120, 200, 255),
	protected = Color3.fromRGB(200, 200, 210),
	revenge = Color3.fromRGB(255, 170, 60),
}
-- Name plate text of a listed-but-ineligible player (owner R43: greyed with the reason).
local GREYED_NAME = Color3.fromRGB(170, 172, 186)

--[[ Bottom row (design px): DEFENSE · LAUNCH · BARRAGE · CANCEL in one centred list, scaled down
     to fit narrow canvases (relayout). QA 2026-10-30 device matrix: the old corner DEFENSE button
     overlapped LAUNCH on phone, tablet and console. ]]
local ROW_BUTTONS = { defense = 270, launch = 380, barrage = 340, cancel = 230 }
local ROW_GAP = 22
local BOTTOM_WIDTH = ROW_BUTTONS.defense + ROW_BUTTONS.launch + ROW_BUTTONS.barrage + ROW_BUTTONS.cancel + 3 * ROW_GAP
local BOTTOM_HEIGHT = 190
-- Px under the bottom row (canvas bottom margin).
local BOTTOM_MARGIN = 60
-- Top block: name plate (112) + gap + the stacked info plate (owner R118), design px at scale 1.
local TOP_WIDTH = 1120
local TOP_HEIGHT = 250
-- The info plate under the name plate (owner R118 / R133): width, vertical padding and the gap
-- between its lines (design px). Three lines = 130 px, so the plate (at y 120) ends at TOP_HEIGHT.
local INFO_WIDTH = 940
local INFO_PAD_Y = 5
local INFO_GAP = 2
local LAYOUT = AttackConfig.Client.PickerLayout
-- Side margin (design px) the bottom row keeps from the canvas edges.
local SIDE_MARGIN = 24
-- Canvases shorter than this (phones) move the launcher / Mega Launcher panel to the middle right.
local SHORT_CANVAS = 860

-- "1:05" / "12s" for a short countdown.
local function shortClock(seconds: number): string
	local s = math.max(math.ceil(seconds), 0)
	if s >= 60 then
		return string.format("%d:%02d", s // 60, s % 60)
	end
	return `{s}s`
end

-- True when the player turned on Reduce Motion (profile settings; no tweens / sweeps then).
local function reducedMotion(): boolean
	local profile: any = ClientState.profile
	return type(profile) == "table" and type(profile.settings) == "table" and profile.settings.reducedMotion == true
end

-- True when the local player owns a game pass (profile cache; the server is the truth).
local function ownsPass(key: string): boolean
	local profile: any = ClientState.profile
	return type(profile) == "table" and type(profile.passes) == "table" and profile.passes[key] == true
end

local module: ScreenManager.ScreenModule = {
	name = NAME,
	modal = true,
	closeOnBack = true,
	displayOrder = 22,
	lazy = true,
	blur = false,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		-- The picker draws its own CANCEL button (no touch X needed).
		gui:SetAttribute(ScreenManager.BackButtonAttribute, true)
		local root = Create.new("Frame", {
			Name = "AttackPicker",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(1920, 1080),
			Parent = gui,
		}) :: Frame

		-- Reticle over the target base (screen centre; the camera centres the impact zone).
		local reticle = Create.new("Frame", {
			Name = "Reticle",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.52),
			Size = UDim2.fromOffset(190, 190),
			BackgroundTransparency = 1,
			Parent = root,
			Children = {
				Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }),
				Create.new("UIStroke", { Thickness = 10, Color = Color3.fromRGB(240, 60, 50), Transparency = 0.1 }),
				Create.new("UIScale", { Name = "Pulse", Scale = 1 }),
			},
		}) :: Frame
		for _, bar in { UDim2.fromOffset(12, 90), UDim2.fromOffset(90, 12) } do
			Create.new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = bar,
				BackgroundColor3 = Color3.fromRGB(240, 60, 50),
				BackgroundTransparency = 0.15,
				BorderSizePixel = 0,
				Parent = reticle,
			})
		end
		local pulse = reticle:FindFirstChild("Pulse") :: UIScale
		local pulseTween = TweenService:Create(
			pulse,
			TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Scale = 1.12 }
		)

		-- Top bar: [ < ] name plate [ > ] + the stacked info plate. Scaled down on short canvases
		-- (owner R118: PickerLayout.blocks; relayout writes the Fit scale).
		local top = Create.new("Frame", {
			Name = "Top",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 90),
			Size = UDim2.fromOffset(TOP_WIDTH, TOP_HEIGHT),
			BackgroundTransparency = 1,
			Parent = root,
			Children = { Create.new("UIScale", { Name = "Fit", Scale = 1 }) },
		}) :: Frame
		local plate = Create.new("Frame", {
			Name = "Plate",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.fromOffset(780, 112),
			Parent = top,
		}) :: Frame
		StudWindow.surface(plate, "grey", { edge = 5, tile = 0 })
		local nameLabel = StudUI.text({
			text = "",
			textSize = 64,
			font = "shout",
			scaled = true,
			size = UDim2.new(1, -40, 1, -16),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
			zIndex = 4,
			parent = plate,
		})
		-- Owner R118: the info / status / aim lines STACK on one stud backing plate (UIListLayout: they
		-- can never overlap each other, an empty line takes no space, and nothing behind — world
		-- text, a fading HUD — shows through). Each line shrinks its text to fit its width instead of
		-- spilling.
		-- Owner R133 ("when attacking people all I see is this, not their base still"): the layout
		-- used to be a DIRECT child of the studded plate, so UIListLayout also stacked the surface's
		-- own decorations (TopHighlight, PanelBackdrop — Widgets/PanelBackdrop "Layout rule") as list
		-- items above the lines, and AutomaticSize grew the plate around those scale-sized children:
		-- a ~550 px grey stud wall over the middle of the screen, exactly where the base is. Now the
		-- layout + lines live in a transparent inner "Content" frame and the plate's height is set
		-- explicitly from the visible lines (`fitInfo`), so no decoration is ever laid out or sized
		-- by the list. tests/attack-view.luau §8 guards both rules.
		local infoPlate = Create.new("Frame", {
			Name = "Info",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 120),
			Size = UDim2.fromOffset(INFO_WIDTH, 0),
			Parent = top,
		}) :: Frame
		StudWindow.surface(infoPlate, "grey", { edge = 3, tile = 0, studTransparency = 0.85 })
		local infoContent = Create.new("Frame", {
			Name = "Content",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 3,
			Parent = infoPlate,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					Padding = UDim.new(0, INFO_GAP),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				Create.new("UIPadding", {
					PaddingTop = UDim.new(0, INFO_PAD_Y),
					PaddingBottom = UDim.new(0, INFO_PAD_Y),
					PaddingLeft = UDim.new(0, 16),
					PaddingRight = UDim.new(0, 16),
				}),
			},
		}) :: Frame
		local function infoLine(order: number, textSize: number, font: string?, color: Color3?): TextLabel
			local line = StudUI.text({
				text = "",
				textSize = textSize,
				font = font :: any,
				color = color,
				scaled = true,
				size = UDim2.new(1, 0, 0, textSize + 6),
				layoutOrder = order,
				zIndex = 3,
				parent = infoContent,
			})
			line.Visible = false
			return line
		end
		local infoLabel = infoLine(1, 32)
		local statusLabel = infoLine(2, 36, "shout")
		-- Owner R50: what the next nuke aims at ("AIM: LAB").
		local aimLabel = infoLine(3, 30, "shout", Color3.fromRGB(255, 200, 80))
		local infoLines = { infoLabel, statusLabel, aimLabel }
		-- Sizes the plate to its visible lines (padding + line heights + gaps); hidden when empty.
		-- Example: all three lines -> 5 + 38 + 2 + 42 + 2 + 36 + 5 = 130 px (fits under TOP_HEIGHT).
		local function fitInfo()
			local height, shown = 2 * INFO_PAD_Y, 0
			for _, line in infoLines do
				if line.Visible then
					height += line.Size.Y.Offset
					shown += 1
				end
			end
			height += math.max(shown - 1, 0) * INFO_GAP
			infoPlate.Visible = shown > 0
			if infoPlate.Size.Y.Offset ~= height then
				infoPlate.Size = UDim2.fromOffset(INFO_WIDTH, height)
			end
		end
		-- Writes one info line; an empty line hides (the plate shrinks, nothing overlaps).
		local function setLine(line: TextLabel, text: string)
			if line.Text ~= text then
				line.Text = text
			end
			line.Visible = text ~= ""
			fitInfo()
		end

		-- The selected entry's AttackClient key ("p<userId>" / "r<rivalId>").
		local selectedKey: string? = nil
		local refresh: () -> ()
		local cycle: (delta: number) -> ()

		-- Aiming (owner R50) -----------------------------------------------------------------------
		-- The chosen area per target key (kept while cycling targets); default = the highest built
		-- area (usually the biggest earner), a Rival's first section.
		local aims: { [string]: number } = {}
		local function aimOf(target: AttackClient.Target): number
			local chosen = aims[target.key]
			if chosen ~= nil and table.find(target.areas, chosen) ~= nil then
				return chosen
			end
			local areas = target.areas
			if #areas == 0 then
				return 0
			end
			return if target.rival ~= nil then areas[1] else areas[#areas]
		end
		-- The short label of an aimable area (plot area name / rival section name).
		local function aimLabelOf(target: AttackClient.Target, area: number): string
			if target.rival ~= nil then
				local section = AttackConfig.Rivals.Sections[area]
				return if section ~= nil then section.label else `SECTION {area}`
			end
			return KnockdownConfig.areaLabel(area)
		end
		-- Server time the area's knockdown ends (0 = standing) — read from the streamed world.
		local function downUntil(target: AttackClient.Target, area: number): number
			local model: Instance? = nil
			if target.rival ~= nil then
				local rival = AttackConfig.Rivals.List[target.rival]
				local folder = Workspace:FindFirstChild(AttackConfig.Rivals.Folder)
				local island = if folder ~= nil then folder:FindFirstChild(rival.id) else nil
				local inner = if island ~= nil then island:FindFirstChild("Island") else nil
				model = if inner ~= nil then inner:FindFirstChild(`Section{area}`) else nil
			else
				local plots = Workspace:FindFirstChild("Plots")
				local plot = if plots ~= nil then plots:FindFirstChild(`Plot{target.plot}`) else nil
				model = if plot ~= nil then plot:FindFirstChild(string.format("Area%02d", area)) else nil
			end
			local untilTime = if model ~= nil then model:GetAttribute(KnockdownConfig.Attr.Until) else nil
			return if type(untilTime) == "number" then untilTime else 0
		end

		local prevButton = StudUI.button({
			text = "<",
			color = "sky",
			textSize = 72,
			size = UDim2.fromOffset(130, 112),
			position = UDim2.fromOffset(0, 0),
			parent = top,
			onActivated = function()
				cycle(-1)
			end,
		})
		local nextButton = StudUI.button({
			text = ">",
			color = "sky",
			textSize = 72,
			size = UDim2.fromOffset(130, 112),
			position = UDim2.new(1, -130, 0, 0),
			parent = top,
			onActivated = function()
				cycle(1)
			end,
		})

		-- Empty state card.
		local empty = StudUI.card({
			color = "blue",
			title = "Nobody to nuke right now!",
			titleSize = 46,
			size = UDim2.fromOffset(980, 250),
			anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.42),
			parent = root,
		})
		StudUI.text({
			text = "The Rival Factories are taking a break on this server. Players join Attack mode when they reach Launch Silos (area 7), and shield bubbles block nukes.",
			textSize = 30,
			wrap = true,
			size = UDim2.new(1, -40, 1, -70),
			position = UDim2.fromOffset(20, 60),
			parent = empty.content,
		})

		-- Owner R104: "LOADING BASE..." plate while the framed target streams in (PickerView). A
		-- stud plate above the reticle with a white shimmer sweeping along a bar (one engine tween on
		-- a UIGradient offset; played only while visible, never under Reduce Motion).
		-- Owner R118: it sits just under the top block (relayout), scaled with it, so it never covers
		-- the info lines on short canvases.
		local loadingPlate = Create.new("Frame", {
			Name = "Loading",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 380),
			Size = UDim2.fromOffset(560, 124),
			Visible = false,
			ZIndex = 6,
			Parent = root,
			Children = { Create.new("UIScale", { Name = "Fit", Scale = 1 }) },
		}) :: Frame
		StudWindow.surface(loadingPlate, "blue", { edge = 4, tile = 0, zIndex = 6 })
		StudUI.text({
			name = "LoadingText",
			text = "LOADING BASE...",
			textSize = 46,
			font = "shout",
			scaled = true,
			size = UDim2.new(1, -40, 0, 56),
			position = UDim2.fromOffset(20, 14),
			zIndex = 8,
			parent = loadingPlate,
		})
		local shimmerBar = Create.new("Frame", {
			Name = "ShimmerBar",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 82),
			Size = UDim2.new(1, -60, 0, 18),
			BackgroundColor3 = Color3.fromRGB(30, 60, 120),
			BackgroundTransparency = 0.2,
			BorderSizePixel = 0,
			ZIndex = 7,
			Parent = loadingPlate,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }) },
		}) :: Frame
		local shimmer = Create.new("Frame", {
			Name = "Shimmer",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			ZIndex = 8,
			Parent = shimmerBar,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }) },
		}) :: Frame
		local shimmerGradient = Create.new("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.42, 1),
				NumberSequenceKeypoint.new(0.5, 0.05),
				NumberSequenceKeypoint.new(0.58, 1),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Offset = Vector2.new(-1, 0),
			Parent = shimmer,
		}) :: UIGradient
		local shimmerTween = TweenService:Create(
			shimmerGradient,
			TweenInfo.new(1.1, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1),
			{ Offset = Vector2.new(1, 0) }
		)
		-- Shows / hides the plate for PickerView's loading state (the tween only runs while shown).
		local function showLoading(loading: boolean)
			loadingPlate.Visible = loading
			if loading and not reducedMotion() then
				shimmerGradient.Offset = Vector2.new(-1, 0)
				shimmerTween:Play()
			else
				shimmerTween:Cancel()
				-- Reduce Motion: a static half-lit bar still reads as "in progress".
				shimmerGradient.Offset = if loading then Vector2.zero else Vector2.new(-1, 0)
			end
		end

		-- Bottom row.
		local bottom = Create.new("Frame", {
			Name = "Bottom",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -BOTTOM_MARGIN),
			Size = UDim2.fromOffset(BOTTOM_WIDTH, BOTTOM_HEIGHT),
			BackgroundTransparency = 1,
			Parent = root,
			-- Fit-to-width scale (relayout).
			Children = { Create.new("UIScale", { Name = "Fit", Scale = 1 }) },
		}) :: Frame
		local barrageHint = StudUI.text({
			text = "",
			textSize = 30,
			color = Color3.fromRGB(255, 120, 100),
			size = UDim2.new(1, 0, 0, 38),
			position = UDim2.fromOffset(0, 0),
			parent = bottom,
		})
		local row = Create.new("Frame", {
			Name = "Row",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, 50),
			Size = UDim2.new(1, 0, 0, 130),
			Parent = bottom,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, ROW_GAP),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame

		local launchKind: AttackLogic.LaunchKind = "normal"
		local flashUntil = 0
		local launchButton = StudUI.button({
			text = "LAUNCH!",
			color = "green",
			icon = "Nuke",
			size = UDim2.fromOffset(ROW_BUTTONS.launch, 116),
			layoutOrder = 1,
			parent = row,
			onActivated = function()
				local target = if selectedKey ~= nil then AttackClient.target(selectedKey) else nil
				if target == nil then
					return
				end
				local ok, kind = AttackClient.launchPlan(target)
				if ok and AttackClient.launch(target.id, kind, aimOf(target)) then
					flashUntil = os.clock() + 0.8
					refresh()
				end
			end,
		})
		--[[
			Owner R122: BARRAGE launches stored nukes for free, but with none stored it PROMPTS the
			Barrage product. That prompt passes PurchaseGuard.allow (the press that opened the
			picker never buys; a key press passes its own time).
			@param pressAt os.clock() of a ContextActionService press, nil for a button activation
		]]
		local function barrageAt(pressAt: number?)
			local target = if selectedKey ~= nil then AttackClient.target(selectedKey) else nil
			if target == nil then
				return
			end
			if AttackClient.myState().barrage <= 0 and not PurchaseGuard.allow(NAME, pressAt) then
				return
			end
			AttackClient.barrage(target.id, aimOf(target))
		end
		local barrageButton = StudUI.button({
			text = "BARRAGE",
			color = "red",
			icon = "Barrage",
			size = UDim2.fromOffset(ROW_BUTTONS.barrage, 116),
			layoutOrder = 2,
			parent = row,
			onActivated = function()
				barrageAt(nil)
			end,
		})
		local cancelButton = StudUI.button({
			text = "CANCEL",
			color = "grey",
			size = UDim2.fromOffset(ROW_BUTTONS.cancel, 116),
			layoutOrder = 3,
			parent = row,
			onActivated = function()
				ScreenManager.close(NAME)
			end,
		})

		-- Device-following key hints on the buttons (keyboard key / gamepad button; hidden on touch).
		local function hint(button: StudUI.Button, binding: Binding)
			local glyph = InputGlyph.dynamic(binding.keys[1], binding.pads[1], 34)
			glyph.AnchorPoint = Vector2.new(1, 0)
			glyph.Position = UDim2.new(1, 10, 0, -18)
			glyph.ZIndex = 8
			glyph.Parent = button.instance
		end
		hint(launchButton, { keys = KEYS.Launch.keys, pads = { Enum.KeyCode.ButtonA } })
		hint(barrageButton, KEYS.Barrage)
		hint(cancelButton, { keys = { Enum.KeyCode.X }, pads = { Enum.KeyCode.ButtonB } })

		-- DEFENSE leads the bottom row; my launcher / Mega Launcher sit on the right (relayout).
		local defenseButton = StudUI.button({
			text = "DEFENSE",
			color = "blue",
			icon = "Shield",
			size = UDim2.fromOffset(ROW_BUTTONS.defense, 116),
			layoutOrder = 0,
			parent = row,
			onActivated = function()
				ScreenManager.open("Defense", { source = "other" })
			end,
		})
		hint(defenseButton, KEYS.Defense)
		local mine = Create.new("Frame", {
			Name = "Mine",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -SIDE_MARGIN, 1, -(60 + BOTTOM_HEIGHT + 12)),
			Size = UDim2.fromOffset(380, 170),
			BackgroundTransparency = 1,
			Parent = root,
			Children = { Create.new("UIScale", { Name = "Fit", Scale = 1 }) },
		}) :: Frame
		local mineLabel = StudUI.text({
			text = "",
			textSize = 28,
			wrap = true,
			align = Enum.TextXAlignment.Right,
			size = UDim2.new(1, 0, 0, 70),
			parent = mine,
		})
		local megaPass = MonetizationConfig.getPass(AttackConfig.Reward.MegaLauncherPass)
		local megaButton = StudUI.button({
			text = "x2 REWARDS",
			color = "purple",
			icon = "MegaLauncher",
			productKey = if megaPass ~= nil then megaPass.key else nil, -- live price (PriceBook)
			size = UDim2.fromOffset(340, 84),
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, 0, 0, 78),
			parent = mine,
			-- R122: a guarded Robux BUY (never the default cursor; the opening press never buys).
			onActivated = PurchaseGuard.gate(NAME, function()
				AttackClient.buy(AttackConfig.Reward.MegaLauncherPass, true)
			end),
		})
		PurchaseGuard.markBuy(megaButton.instance)
		local barrageProduct = MonetizationConfig.getProduct("Barrage")
		-- Owner R85: launch a stored GOLDEN revenge nuke at the selected target (no reload, extra
		-- armor). Shown above my launcher panel only while I hold golden charges.
		local goldenButton = StudUI.button({
			text = "GOLDEN NUKE",
			color = "yellow",
			icon = "Nuke",
			size = UDim2.fromOffset(340, 84),
			anchor = Vector2.new(1, 1),
			position = UDim2.new(1, 0, 0, -8),
			parent = mine,
			onActivated = function()
				local target = if selectedKey ~= nil then AttackClient.target(selectedKey) else nil
				if target ~= nil and AttackClient.launch(target.id, "golden", aimOf(target)) then
					flashUntil = os.clock() + 0.8
					refresh()
				end
			end,
		})
		goldenButton.instance.Visible = false
		hint(goldenButton, KEYS.Golden)

		-- Camera ---------------------------------------------------------------------------------
		local savedType: Enum.CameraType? = nil
		local savedSubject: Instance? = nil
		local savedFov = 70
		-- The player's camera view before the picker took it (restored on close, QA 2026-10-30:
		-- without it the Custom camera resumed from the picker's steep overhead angle).
		local savedCFrame: CFrame? = nil
		local cameraTween: Tween? = nil
		-- Owner R133: the last framing key ("slot|areas|aim|aspect") and goal, so the 2 Hz refresh
		-- re-frames only when something that moves the camera changed.
		local cameraKey = ""
		local cameraGoal: CFrame? = nil
		-- GuiService.TouchControlsEnabled before the picker hid the touch controls (nil = not hidden).
		local savedTouchControls: boolean? = nil

		--[[
			Moves the camera over a target slot — a plot, or a Rival Factory island out at sea.
			Owner R133 ("all I see is this, not their base still"): the old whole-plot view sat ~890
			studs up and a live client drew nothing from there. Shared/Attack/PickerFrame frames the
			target's BUILT areas as close as they fit between the name plate and the button row
			(<= MaxDistance); a big base keeps the AIMED area in view, so changing the aim pans the
			camera. Tweened unless Reduce Motion / `instant`.
			@param plot number — the target slot
			@param areas { number }? — its built areas (nil = the whole plot: my own, no targets)
			@param aim number? — the aimed area
			@param instant boolean — jump instead of tweening
			Example: frameCameraOn(target.plot, target.areas, aimOf(target), false)
		]]
		local function frameCameraOn(plot: number, areas: { number }?, aim: number?, instant: boolean)
			local camera = Workspace.CurrentCamera
			if camera == nil or AttackGeometry.validTarget(plot) == nil then
				return
			end
			local viewport = camera.ViewportSize
			local aspect = if viewport.Y > 0 then viewport.X / viewport.Y else nil
			local areaKey = if areas ~= nil then table.concat(areas, ",") else "*"
			local aspectKey = if aspect ~= nil then math.floor(aspect * 100 + 0.5) else 0
			local key = `{plot}|{areaKey}|{aim or 0}|{aspectKey}`
			if key == cameraKey then
				return
			end
			cameraKey = key
			local view = PickerFrame.view(plot, areas, aim, aspect)
			local goal = CFrame.lookAt(view.eye, view.focus)
			-- Scriptable camera: the engine's LOD / lighting detail follows Camera.Focus.
			camera.Focus = CFrame.new(view.focus)
			-- An aim change on a base that fits whole frames the same view: nothing to move.
			local previous = cameraGoal
			local same = previous ~= nil
				and (previous.Position - goal.Position).Magnitude < 0.05
				and (previous.LookVector - goal.LookVector).Magnitude < 1e-4
			if not same then
				cameraGoal = goal
				if cameraTween ~= nil then
					cameraTween:Cancel()
					cameraTween = nil
				end
				if instant or reducedMotion() then
					camera.CFrame = goal
				else
					local tween = TweenService:Create(
						camera,
						TweenInfo.new(CLIENT.PickerTween, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ CFrame = goal }
					)
					cameraTween = tween
					tween:Play()
				end
			end
			-- Owner R104 / R133: stream the target base in and keep it (server replication focus on
			-- the middle of the built base + a RequestStreamAroundAsync first push); the loading
			-- plate shows until it is there.
			PickerView.focus(plot, areas)
		end

		local function takeCamera()
			local camera = Workspace.CurrentCamera
			if camera == nil then
				return
			end
			-- Keep the FIRST save: ScreenManager.open on an already-open picker (console prompt, a
			-- Revenge chip, open with { userId }) re-runs onOpen, and saving again would store the
			-- picker's own Scriptable / overhead view and "restore" that on close (Q4 QA 2026-10-30;
			-- LaunchCam inherits whatever the picker restores).
			if savedType == nil then
				savedType = camera.CameraType
				savedSubject = camera.CameraSubject
				savedFov = camera.FieldOfView
				savedCFrame = camera.CFrame
			end
			-- The thumbstick / jump button would walk a character the player cannot see (the camera
			-- is over the target) and sit under the bottom row on phones (owner R11): hidden while
			-- the picker is open, restored on close.
			if savedTouchControls == nil then
				savedTouchControls = GuiService.TouchControlsEnabled
				GuiService.TouchControlsEnabled = false
			end
			camera.CameraType = Enum.CameraType.Scriptable
			camera.FieldOfView = CLIENT.PickerFov
			cameraKey = ""
			cameraGoal = nil
		end

		local function restoreCamera()
			if cameraTween ~= nil then
				cameraTween:Cancel()
				cameraTween = nil
			end
			if savedTouchControls ~= nil then
				GuiService.TouchControlsEnabled = savedTouchControls
				savedTouchControls = nil
			end
			local camera = Workspace.CurrentCamera
			if camera == nil then
				savedType, savedSubject, savedCFrame = nil, nil, nil
				return
			end
			-- Put the view back BEFORE handing the camera to the player module: the Custom camera
			-- derives its yaw / pitch from the current CFrame when it resumes.
			if savedCFrame ~= nil then
				camera.CFrame = savedCFrame
				savedCFrame = nil
			end
			camera.CameraType = savedType or Enum.CameraType.Custom
			local character = LOCAL.Character
			local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
			camera.CameraSubject = (
				if savedSubject ~= nil and savedSubject.Parent ~= nil then savedSubject else humanoid
			) :: any
			camera.FieldOfView = savedFov
			-- The next open saves the player's camera afresh.
			savedType = nil
			savedSubject = nil
			cameraKey = ""
			cameraGoal = nil
		end

		-- Aim markers (owner R50, R118) ------------------------------------------------------------
		-- One stud chip per aimable area. Owner R118 ("all of these clip": BIG MACHINE / WAREHOUSE /
		-- WORKSHOP / TOY SHOP covered each other in one row): chips NEVER overlap. PickerLayout pins
		-- each near its area (de-collided by whole chip rows, then sideways; a leader line to a dot
		-- on the area when moved) or, when they crowd, lays them all out as one tidy row just above
		-- the action buttons (a sideways-scrolling strip when wider than the canvas). Chips are
		-- >= 44 pt (relayout's ChipH) and as wide as their longest label. Tap / click / A selects;
		-- the aimed one is orange and the reticle sits on its area. Pooled, never rebuilt.
		type Marker = { button: StudUI.Button, area: number, text: string, dot: Frame, line: Frame }
		local markers: { Marker } = {}
		local markerTarget: AttackClient.Target? = nil
		local lastCameraCFrame: CFrame? = nil
		local lastLayoutStamp = -1
		local renderConnection: RBXScriptConnection? = nil
		-- The sideways strip (strip mode only when the row is wider than the canvas).
		local strip = Create.new("ScrollingFrame", {
			Name = "AimStrip",
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollingDirection = Enum.ScrollingDirection.X,
			ScrollBarThickness = 6,
			CanvasSize = UDim2.new(),
			Selectable = false,
			Visible = false,
			Parent = root,
		}) :: ScrollingFrame
		local function markerAt(index: number): Marker
			local existing = markers[index]
			if existing ~= nil then
				return existing
			end
			local marker: Marker = { button = nil :: any, area = 0, text = "", dot = nil :: any, line = nil :: any }
			marker.button = StudUI.button({
				text = "",
				name = "AimChip",
				color = "sky",
				textSize = PickerLayout.CHIP_TEXT,
				size = UDim2.fromOffset(LAYOUT.Chip.X, LAYOUT.Chip.Y),
				anchor = Vector2.new(0.5, 0.5),
				parent = root,
				onActivated = function()
					local target = markerTarget
					if target ~= nil and marker.area >= 1 then
						aims[target.key] = marker.area
						refresh()
					end
				end,
			})
			marker.button.instance.Visible = false
			-- Dot on the area + leader line to the chip (drawn under the chips).
			marker.dot = Create.new("Frame", {
				Name = "AimDot",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(18, 18),
				BackgroundColor3 = Color3.new(1, 1, 1),
				Visible = false,
				ZIndex = 0,
				Parent = root,
				Children = {
					Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }),
					Create.new("UIStroke", { Thickness = 3, Color = Color3.fromRGB(30, 34, 48) }),
				},
			}) :: Frame
			marker.line = Create.new("Frame", {
				Name = "AimLeader",
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundColor3 = Color3.new(1, 1, 1),
				BackgroundTransparency = 0.15,
				BorderSizePixel = 0,
				Visible = false,
				ZIndex = 0,
				Parent = root,
				Children = { Create.new("UIStroke", { Thickness = 1.5, Color = Color3.fromRGB(30, 34, 48) }) },
			}) :: Frame
			markers[index] = marker
			return marker
		end
		-- Hides one marker's chip, dot and line.
		local function hideMarker(marker: Marker)
			marker.button.instance.Visible = false
			marker.dot.Visible = false
			marker.line.Visible = false
		end
		-- Re-lays every visible chip + the reticle (camera moved, layout changed or the aim changed).
		local function placeMarkers(force: boolean)
			local camera = Workspace.CurrentCamera
			local target = markerTarget
			if camera == nil or target == nil then
				return
			end
			local stamp = root:GetAttribute("LayoutStamp")
			local layoutStamp = if type(stamp) == "number" then stamp else 0
			if not force and lastCameraCFrame == camera.CFrame and layoutStamp == lastLayoutStamp then
				return
			end
			lastCameraCFrame = camera.CFrame
			lastLayoutStamp = layoutStamp
			local scale = math.max(root.AbsoluteSize.X / math.max(root.Size.X.Offset, 1), 0.01)
			local canvasX = root.Size.X.Offset
			local aim = aimOf(target)
			-- The clear band between the top block (+ the loading plate while shown) and the bottom row.
			local function bottomOf(frame: GuiObject?): number
				return if frame ~= nil and frame.Visible
					then (frame.AbsolutePosition.Y + frame.AbsoluteSize.Y - root.AbsolutePosition.Y) / scale
					else 0
			end
			local topFrame = root:FindFirstChild("Top") :: GuiObject?
			local bottomFrame = root:FindFirstChild("Bottom") :: GuiObject?
			local bandTop = math.max(bottomOf(topFrame), bottomOf(loadingPlate)) + LAYOUT.BandPad
			local bandBottom = if bottomFrame ~= nil
				then (bottomFrame.AbsolutePosition.Y - root.AbsolutePosition.Y) / scale - LAYOUT.BandPad
				else root.Size.Y.Offset
			-- Chip size: >= 44 pt tall (relayout), as wide as the longest label (StudUI also shrinks).
			local chipAttr = root:GetAttribute("ChipH")
			local chipH = if type(chipAttr) == "number" then chipAttr else LAYOUT.Chip.Y
			local active: { Marker } = {}
			local labels: { string } = {}
			for _, marker in markers do
				if marker.area >= 1 and AttackGeometry.validTarget(target.plot) ~= nil then
					table.insert(active, marker)
					table.insert(labels, marker.text)
				else
					hideMarker(marker)
				end
			end
			local chip = PickerLayout.chipFor(labels, chipH)
			-- Projected anchors (+ which side of its point a plot chip sits: away from the road).
			local anchors: { Vector2 } = {}
			local sides: { number } = {}
			for index, marker in active do
				local world = AttackGeometry.aimPoint(target.plot, marker.area, 0, 0)
				local screen, inFront = camera:WorldToScreenPoint(world)
				local at = (Vector2.new(screen.X, screen.Y) - root.AbsolutePosition) / scale
				anchors[index] = if inFront then at else Vector2.new(canvasX / 2, bandBottom)
				local side = 0
				if target.rival == nil then
					local origin = AttackGeometry.plotOrigin(target.plot)
					local road = origin * Vector3.new(0, 0, origin:PointToObjectSpace(world).Z)
					local roadScreen = camera:WorldToScreenPoint(road)
					side = if screen.X < roadScreen.X then -1 else 1
				end
				sides[index] = side
			end
			-- The launcher / Mega Launcher panel (bottom right, or middle right on phones) is kept
			-- clear: chips use the canvas left of it when it reaches into the band.
			local layoutWidth = canvasX
			local minePanel = root:FindFirstChild("Mine") :: GuiObject?
			if minePanel ~= nil and minePanel.Visible then
				local mineTop = (minePanel.AbsolutePosition.Y - root.AbsolutePosition.Y) / scale
				local mineBottom = mineTop + minePanel.AbsoluteSize.Y / scale
				if mineBottom > bandTop and mineTop < bandBottom then
					layoutWidth = math.max(
						(minePanel.AbsolutePosition.X - root.AbsolutePosition.X) / scale - 8,
						chip.X + 2 * LAYOUT.Margin
					)
				end
			end
			local layout = PickerLayout.markers(anchors, sides, bandTop, bandBottom, layoutWidth, chip)
			local scrolling = layout.mode == "strip" and layout.scroll
			strip.Visible = scrolling
			if scrolling then
				strip.Position = UDim2.fromOffset(layoutWidth / 2, layout.stripY)
				strip.Size = UDim2.fromOffset(layoutWidth - 2 * LAYOUT.Margin, chip.Y + 14)
				strip.CanvasSize = UDim2.fromOffset(layout.stripWidth, 0)
			end
			local navIndex: { [number]: number } = {}
			for slot, index in layout.order do
				navIndex[index] = slot
			end
			for index, marker in active do
				local button = marker.button.instance
				local parent: Instance = if scrolling then strip else root
				if button.Parent ~= parent then
					button.Parent = parent
				end
				button.AnchorPoint = Vector2.new(0.5, 0.5)
				button.Size = UDim2.fromOffset(chip.X, chip.Y)
				local centre = layout.centres[index]
				button.Position = UDim2.fromOffset(centre.X, if scrolling then centre.Y + 7 else centre.Y)
				button.LayoutOrder = navIndex[index] or index
				button.Visible = true
				-- The area's dot: its projected point, kept inside the band and the canvas.
				local raw = anchors[index]
				local spot = Vector2.new(
					math.clamp(raw.X, LAYOUT.Margin, math.max(canvasX - LAYOUT.Margin, LAYOUT.Margin)),
					math.clamp(raw.Y, bandTop, math.max(bandBottom, bandTop))
				)
				marker.dot.Position = UDim2.fromOffset(spot.X, spot.Y)
				marker.dot.Visible = layout.leader[index] or layout.mode == "strip"
				if layout.leader[index] then
					local delta = centre - spot
					marker.line.Size = UDim2.fromOffset(delta.Magnitude, 4)
					marker.line.Position = UDim2.fromOffset((spot.X + centre.X) / 2, (spot.Y + centre.Y) / 2)
					marker.line.Rotation = math.deg(math.atan2(delta.Y, delta.X))
					marker.line.Visible = true
				else
					marker.line.Visible = false
				end
				if marker.area == aim then
					reticle.Position = UDim2.fromOffset(spot.X, spot.Y)
				end
			end
			-- Strip: explicit left / right gamepad order (pinned chips use geometric navigation).
			for slot, index in layout.order do
				local button = active[index].button.instance
				local left = if layout.mode == "strip" and slot > 1 then active[layout.order[slot - 1]] else nil
				local right = if layout.mode == "strip" and slot < #layout.order
					then active[layout.order[slot + 1]]
					else nil
				button.NextSelectionLeft = (if left ~= nil then left.button.instance else nil) :: any
				button.NextSelectionRight = (if right ~= nil then right.button.instance else nil) :: any
			end
		end
		-- Shows one marker per aimable area of `target` (nil hides them all).
		local function syncMarkers(target: AttackClient.Target?)
			markerTarget = target
			local areas = if target ~= nil then target.areas else {}
			local t = Workspace:GetServerTimeNow()
			local aim = if target ~= nil then aimOf(target) else 0
			for index = 1, math.max(#areas, #markers) do
				local area = areas[index]
				if area == nil then
					local marker = markers[index]
					if marker ~= nil then
						marker.area = 0
						hideMarker(marker)
					end
					continue
				end
				local marker = markerAt(index)
				marker.area = area
				if target ~= nil then
					local down = downUntil(target, area) > t
					local text = if down then `{aimLabelOf(target, area)} - DOWN` else aimLabelOf(target, area)
					marker.text = text
					marker.button.setText(text)
					marker.button.setColor(if area == aim then "orange" elseif down then "grey" else "sky")
				end
			end
			if target == nil then
				strip.Visible = false
			end
			placeMarkers(true)
		end
		-- Moves the aim to the previous / next aimable area of the selected target.
		local function cycleAim(delta: number)
			local target = if selectedKey ~= nil then AttackClient.target(selectedKey) else nil
			if target == nil or #target.areas == 0 then
				return
			end
			local index = table.find(target.areas, aimOf(target)) or 1
			index = ((index - 1 + delta) % #target.areas) + 1
			aims[target.key] = target.areas[index]
			refresh()
		end

		-- Rendering -------------------------------------------------------------------------------

		refresh = function()
			local list = AttackClient.targets()
			local me = AttackClient.myState()
			local t = Workspace:GetServerTimeNow()
			-- Keep the selection stable; fall back to the first target.
			local target: AttackClient.Target? = nil
			for _, entry in list do
				if entry.key == selectedKey then
					target = entry
				end
			end
			if target == nil then
				target = list[1]
				selectedKey = if target ~= nil then target.key else nil
			end
			local hasTargets = target ~= nil
			empty.frame.Visible = not hasTargets
			plate.Visible = hasTargets
			reticle.Visible = hasTargets
			prevButton.instance.Visible = #list > 1
			nextButton.instance.Visible = #list > 1
			-- Owner R85: everyone has a launcher (no Attack Console needed for Barrage either).
			barrageButton.instance.Visible = hasTargets
			launchButton.instance.Visible = hasTargets

			-- Owner R80: the DEFENSE button shouts while I can be nuked with no tower / an affordable
			-- tower slot is waiting (the HUD route to buying AA towers).
			local alert = AttackClient.defenceAlert()
			defenseButton.setText(if alert then "DEFEND!" else "DEFENSE")
			defenseButton.setColor(if alert then "red" else "blue")

			-- Right corner: my launcher + stored nukes + Mega Launcher.
			local launcherText = if me.console then `Launcher Lv {me.launcher}` else `Starter Launcher Lv {me.launcher}`
			mineLabel.Text = `{launcherText} · {me.barrage} Barrage nukes`
			megaButton.instance.Visible = not ownsPass(AttackConfig.Reward.MegaLauncherPass)

			if target == nil then
				setLine(infoLabel, "")
				setLine(statusLabel, "")
				setLine(aimLabel, "")
				barrageHint.Text = ""
				syncMarkers(nil)
				if me.plot >= 1 then
					frameCameraOn(me.plot, nil, nil, false)
				end
				return
			end
			frameCameraOn(target.plot, target.areas, aimOf(target), false)
			-- Owner R51: admin test bots carry a BOT tag.
			nameLabel.Text = if target.bot ~= nil then `{target.name} [BOT]` else target.name
			-- Ineligible players are listed but greyed (owner R43), with the reason on the status line.
			local greyed = target.rival == nil and (target.status == "protected" or target.status == "shield")
			nameLabel.TextColor3 = if greyed then GREYED_NAME else Color3.new(1, 1, 1)
			-- Owner R80: players defend with several towers (the HQ + defence slots).
			local aaText = if target.towers > 1
				then `{target.towers} AA towers`
				elseif target.aa > 0 or target.towers == 1 then (if target.aa > 0
					then `AA Lv {target.aa}`
					else "1 AA tower")
				else "No AA tower"
			if target.rival ~= nil then
				-- A Rival Factory: what one hit pays (a fraction of MY income; smaller than a player).
				setLine(infoLabel, `Rival Factory · {aaText} · Pays {NumberFormat.money(target.reward)} a hit`)
			elseif target.bot ~= nil then
				setLine(infoLabel, `TEST BOT · Area {math.max(target.area, 1)} · {aaText} · admins only`)
			else
				setLine(infoLabel, `Area {math.max(target.area, 1)} · {aaText} · {NumberFormat.rate(target.income)}`)
			end
			local statusText = STATUS_TEXT[target.status] or ""
			if target.status == "shield" then
				statusText ..= ` {shortClock(target.shieldUntil - t)}`
			elseif target.status == "revenge" then
				statusText ..= ` {shortClock(target.revengeUntil - t)}`
			elseif target.status == "protected" and target.reason ~= nil then
				statusText = string.upper(target.reason)
			end
			setLine(statusLabel, statusText)
			statusLabel.TextColor3 = STATUS_COLOR[target.status] or Color3.new(1, 1, 1)

			-- Aim (owner R50): the chosen area + its markers over the view.
			local aim = aimOf(target)
			if aim >= 1 then
				local down = downUntil(target, aim) > t
				setLine(
					aimLabel,
					if down
						then `AIM: {aimLabelOf(target, aim)} (already down - smaller reward)`
						else `AIM: {aimLabelOf(target, aim)}`
				)
			else
				setLine(aimLabel, "Nothing built to aim at yet")
			end
			syncMarkers(target)

			-- LAUNCH / REVENGE button state.
			local ok, kind, reason = AttackClient.launchPlan(target)
			launchKind = kind
			if os.clock() < flashUntil then
				launchButton.setState("claimed", "LAUNCHED!")
			elseif ok then
				launchButton.setState("normal")
				launchButton.setText(if kind == "revenge" then "REVENGE!" else "LAUNCH!")
				launchButton.setColor(if kind == "revenge" then "orange" else "green")
			elseif reason == "cooldown" then
				launchButton.setState("disabled", `RELOADING {shortClock(me.cooldownUntil - t)}`)
			elseif reason == "shield" then
				launchButton.setState("locked", "SHIELDED")
			elseif reason == "protected" then
				launchButton.setState("locked", "PROTECTED")
			else
				launchButton.setState("locked", "CAN'T LAUNCH")
			end

			-- Owner R85 GOLDEN: stored golden nukes; any targetable, unshielded target (or the one who
			-- hit me — their new-player protection does not count then; the server re-checks).
			local goldenOk = (target.targetable or target.revengeUntil > t) and target.shieldUntil <= t
			goldenButton.instance.Visible = me.golden > 0 and AttackConfig.Golden.Enabled
			goldenButton.setText(`GOLDEN x{me.golden}`)
			goldenButton.setState(if goldenOk then "normal" else "disabled")

			-- BARRAGE: stored nukes, else the product's Robux price.
			local barrageOk = target.targetable and target.shieldUntil <= t
			if me.barrage > 0 then
				barrageButton.setRobux(nil)
				barrageButton.setText(`BARRAGE x{math.min(me.barrage, AttackConfig.BarrageSize)}`)
			else
				barrageButton.setText("BARRAGE")
				barrageButton.setProductKey(if barrageProduct ~= nil then barrageProduct.key else nil)
			end
			-- R122: a Robux BUY only while it sells the product (never a default selection then).
			PurchaseGuard.setBuy(barrageButton.instance, me.barrage <= 0)
			barrageButton.setState(if barrageOk then "normal" else "disabled")
			barrageHint.Text = if barrageOk then `Send {AttackConfig.BarrageSize} nukes at {target.name}!` else ""
		end

		cycle = function(delta: number)
			local list = AttackClient.targets()
			if #list == 0 then
				return
			end
			local index = 1
			for i, entry in list do
				if entry.key == selectedKey then
					index = i
				end
			end
			index = ((index - 1 + delta) % #list) + 1
			selectedKey = list[index].key
			refresh()
		end

		-- Bindings (only while open) ------------------------------------------------------------
		local function bind(name: string, binding: Binding, fn: () -> ())
			local inputs: { Enum.KeyCode } = {}
			for _, key in binding.keys do
				table.insert(inputs, key)
			end
			for _, key in binding.pads do
				table.insert(inputs, key)
			end
			ContextActionService:BindActionAtPriority(
				BIND_PREFIX .. name,
				function(_action: string, state: Enum.UserInputState): Enum.ContextActionResult
					if state == Enum.UserInputState.Begin then
						fn()
					end
					return Enum.ContextActionResult.Sink
				end,
				false,
				Enum.ContextActionPriority.High.Value,
				table.unpack(inputs)
			)
		end
		-- LB / RB + Q / E through the platform layer's cycler (hint bar shows "LB RB Tabs"); our
		-- own binding of the same keys only when the platform layer is missing.
		local cycler: Cycler? = nil
		pcall(function()
			local nav: any = require(script.Parent.Parent.Parent.Parent.Platform.GamepadNav)
			cycler = nav.cycler(function()
				cycle(-1)
			end, function()
				cycle(1)
			end) :: Cycler
		end)
		local BOUND = {
			"Prev",
			"Next",
			"CyclePrev",
			"CycleNext",
			"Launch",
			"Barrage",
			"Revenge",
			"Golden",
			"Defense",
			"AimPrev",
			"AimNext",
		}
		local function bindAll()
			local activeCycler = cycler
			if activeCycler ~= nil then
				activeCycler.enable()
			else
				bind("CyclePrev", KEYS.CyclePrev, function()
					cycle(-1)
				end)
				bind("CycleNext", KEYS.CycleNext, function()
					cycle(1)
				end)
			end
			bind("Prev", KEYS.PrevTarget, function()
				cycle(-1)
			end)
			bind("Next", KEYS.NextTarget, function()
				cycle(1)
			end)
			bind("Launch", KEYS.Launch, function()
				if launchButton.state() == "normal" then
					local target = if selectedKey ~= nil then AttackClient.target(selectedKey) else nil
					if target ~= nil and AttackClient.launch(target.id, launchKind, aimOf(target)) then
						flashUntil = os.clock() + 0.8
						refresh()
					end
				end
			end)
			bind("Barrage", KEYS.Barrage, function()
				if barrageButton.state() == "normal" then
					-- This key press began now (R122 guard: never the picker's opening press).
					barrageAt(os.clock())
				end
			end)
			bind("Golden", KEYS.Golden, function()
				local target = if selectedKey ~= nil then AttackClient.target(selectedKey) else nil
				if goldenButton.instance.Visible and goldenButton.state() == "normal" and target ~= nil then
					AttackClient.launch(target.id, "golden", aimOf(target))
				end
			end)
			bind("Revenge", KEYS.Revenge, function()
				local target = if selectedKey ~= nil then AttackClient.target(selectedKey) else nil
				if target ~= nil and target.revengeUntil > 0 then
					AttackClient.launch(target.id, "revenge", aimOf(target))
				end
			end)
			bind("AimPrev", KEYS.AimPrev, function()
				cycleAim(-1)
			end)
			bind("AimNext", KEYS.AimNext, function()
				cycleAim(1)
			end)
			bind("Defense", KEYS.Defense, function()
				ScreenManager.open("Defense", { source = "other" })
			end)
		end
		local function unbindAll()
			local activeCycler = cycler
			if activeCycler ~= nil then
				activeCycler.disable()
			end
			for _, name in BOUND do
				ContextActionService:UnbindAction(BIND_PREFIX .. name)
			end
		end

		local changedConnection: any = nil
		-- Owner R104: PickerView.Changed → the loading plate (connected while open).
		local loadingConnection: any = nil
		local ticker: thread? = nil
		local open = false

		return {
			onOpen = function(args: any?)
				open = true
				-- A specific target (REVENGE chip) or keep the last one.
				if type(args) == "table" and type(args.userId) == "number" then
					selectedKey = AttackClient.playerKey(args.userId)
				else
					-- Opened without a target: the newest Revenge first (gamepad path to Revenge).
					local revengePlayer = AttackClient.latestRevenge()
					if revengePlayer ~= nil then
						selectedKey = AttackClient.playerKey(revengePlayer.UserId)
					end
				end
				AttackClient.reportOpen(NAME, if type(args) == "table" then args.source else "hud")
				ScreenManager.setFocusReason(FOCUS_REASON, true, { "Hud", "AttackHud", "KnockdownHud" })
				takeCamera()
				refresh()
				bindAll()
				if changedConnection == nil then
					changedConnection = AttackClient.Changed:Connect(refresh)
				end
				pulseTween:Play()
				if loadingConnection == nil then
					loadingConnection = PickerView.Changed:Connect(showLoading)
				end
				showLoading(PickerView.loading())
				-- Markers follow the camera (tween) — one connection while the picker is open, and it
				-- only re-projects when the camera actually moved.
				if renderConnection == nil then
					renderConnection = RunService.RenderStepped:Connect(function()
						placeMarkers(false)
					end)
				end
				if ticker == nil then
					ticker = task.spawn(function()
						while open do
							task.wait(CLIENT.RefreshSeconds)
							if open then
								refresh()
								-- Keep the server's stream focus alive while the picker stays open.
								PickerView.keepAlive()
							end
						end
					end)
				end
			end,
			onClose = function()
				open = false
				ticker = nil
				if renderConnection ~= nil then
					renderConnection:Disconnect()
					renderConnection = nil
				end
				syncMarkers(nil)
				reticle.Position = UDim2.fromScale(0.5, 0.52)
				unbindAll()
				pulseTween:Cancel()
				if changedConnection ~= nil then
					changedConnection:Disconnect()
					changedConnection = nil
				end
				restoreCamera()
				-- Owner R104: stop probing; the server lingers on the target (launch cinematic), then drops it.
				if loadingConnection ~= nil then
					loadingConnection:Disconnect()
					loadingConnection = nil
				end
				PickerView.release()
				showLoading(false)
				ScreenManager.setFocusReason(FOCUS_REASON, false)
			end,
			-- LAUNCH (free), else CANCEL; never a Robux BUY (R122 PurchaseGuard).
			defaultSelection = function(): GuiObject?
				return PurchaseGuard.safeDefault({ launchButton.instance, cancelButton.instance })
			end,
		}
	end,
}

-- Keeps the root sized to the design canvas (UIScale-aware) on every layout change.
local baseBuild = module.build
module.build = function(gui: ScreenGui): ScreenManager.ScreenHandle
	local handle = baseBuild(gui)
	local root = gui:FindFirstChild("AttackPicker") :: Frame?
	local function relayout()
		if root == nil then
			return
		end
		local canvas = ScreenManager.canvasSize(gui)
		if canvas.X > 0 and canvas.Y > 0 then
			root.Size = UDim2.fromOffset(canvas.X, canvas.Y)
			-- Owner R118: the top block and the bottom row share the canvas height so a clear band for
			-- the aim chips always remains (never below the 44 pt tap size; PickerLayout.blocks).
			local safeTop = ScreenManager.safeTop(16)
			local blocks = PickerLayout.blocks(
				canvas,
				safeTop,
				ScreenManager.pointScale(),
				TOP_HEIGHT,
				BOTTOM_HEIGHT,
				BOTTOM_WIDTH,
				BOTTOM_MARGIN,
				TOP_WIDTH
			)
			local top = root:FindFirstChild("Top") :: Frame?
			if top ~= nil then
				top.Position = UDim2.new(0.5, 0, 0, safeTop)
				local topScale = top:FindFirstChild("Fit")
				if topScale ~= nil and topScale:IsA("UIScale") then
					topScale.Scale = blocks.topScale
				end
			end
			local loading = root:FindFirstChild("Loading") :: Frame?
			if loading ~= nil then
				loading.Position = UDim2.new(0.5, 0, 0, safeTop + TOP_HEIGHT * blocks.topScale + 8)
				local loadingScale = loading:FindFirstChild("Fit")
				if loadingScale ~= nil and loadingScale:IsA("UIScale") then
					loadingScale.Scale = blocks.topScale
				end
			end
			-- Bottom row: one centred list, scaled to the canvas width and height share (never overlapping).
			local fit = blocks.bottomScale
			local bottom = root:FindFirstChild("Bottom")
			local bottomScale = if bottom ~= nil then bottom:FindFirstChild("Fit") else nil
			if bottomScale ~= nil and bottomScale:IsA("UIScale") then
				bottomScale.Scale = fit
			end
			-- Aim chips: >= 44 pt; a new stamp re-lays them on the next frame.
			root:SetAttribute("ChipH", blocks.chip.Y)
			local stamp = root:GetAttribute("LayoutStamp")
			root:SetAttribute("LayoutStamp", (if type(stamp) == "number" then stamp else 0) + 1)
			-- Launcher / Mega Launcher panel: above the row's right end on tall canvases, middle right
			-- (clear of the name plate, the reticle and the row) on short ones (phones).
			local mine = root:FindFirstChild("Mine")
			if mine ~= nil and mine:IsA("Frame") then
				local mineScale = mine:FindFirstChild("Fit")
				if canvas.Y < SHORT_CANVAS then
					mine.AnchorPoint = Vector2.new(1, 0.5)
					mine.Position = UDim2.new(1, -SIDE_MARGIN, 0.55, 0)
					if mineScale ~= nil and mineScale:IsA("UIScale") then
						mineScale.Scale = 0.75
					end
				else
					mine.AnchorPoint = Vector2.new(1, 1)
					mine.Position = UDim2.new(1, -SIDE_MARGIN, 1, -(BOTTOM_MARGIN + BOTTOM_HEIGHT * fit + 12))
					if mineScale ~= nil and mineScale:IsA("UIScale") then
						mineScale.Scale = 1
					end
				end
			end
		end
	end
	ScreenManager.LayoutChanged:Connect(relayout)
	ScreenManager.SafeAreaChanged:Connect(relayout)
	-- LayoutChanged can fire before the ScreenGui's AbsoluteSize follows a device / orientation
	-- switch (QA 2026-10-30 device matrix: the root kept the previous device's size), so re-run on
	-- the gui's own resize too (deferred once per frame; fires only on an actual resize).
	local relayoutQueued = false
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if relayoutQueued then
			return
		end
		relayoutQueued = true
		task.defer(function()
			relayoutQueued = false
			relayout()
		end)
	end)
	local onOpen = handle.onOpen
	return {
		onOpen = function(args: any?)
			relayout()
			if onOpen ~= nil then
				onOpen(args)
			end
			-- Once more after ScreenManager enabled the gui: a lazy modal measured while disabled
			-- reads a stale size (ScreenManager.canvasSize), so the first pass can be off.
			task.defer(relayout)
		end,
		onClose = handle.onClose,
		onBack = handle.onBack,
		defaultSelection = handle.defaultSelection,
	}
end

return module
