--!strict
--[[
	FlavorBook — the Flavour Book window (owner R89 Surprise Batches, spec §1): every special flavour
	in every world as a stud tile, discovery rewards claimed once.

		┌ Flavour Book ─────────────────────────────────────────────────────── X ┐
		│ [LUCK x2!]        Discovered 4 / 15                   [ CLAIM ALL (2) ] │
		│ Nuke Town    [Sprinkle][Glitter][ ? ][ ? ][ ? ]                          │
		│ Dino Valley  [ ? ][ ? ][ ? ][ ? ][ ? ]                                   │
		│ Moon Base    [ ? ][ ? ][ ? ][ ? ][ ? ]                                   │
		│ Every batch rolls a flavour! Rarer flavours pay more.                    │
		└──────────────────────────────────────────────────────────────────────────┘
	Tile states (one stud tile per world x flavour):
		undiscovered  grey "?" toy, "???", the live "1 in N" + its multiplier, "+N gems" (locked)
		ready         the flavour colour, its toy, name, "x3 · 1 in 100", a green CLAIM +N pill
		claimed       the flavour colour, "Found 1,234" (lifetime batches), a dim CLAIMED pill
	The odds shown are the ones the server rolls with right now (ReplicatedStorage FlavorLuck, the
	Happy Hours x admin luck; a "LUCK x2!" chip appears above x1).

	Data: ClientState.profile.flavors (the server's Book; FlavorLogic reads it defensively). CLAIM /
	CLAIM ALL only send FlavorClaim intents; a tile shows "..." until the server's `flavors` push
	arrives (or 3 s pass). The server re-checks everything (Server/Tycoon/FlavorService).

	HUD route (no new left-stack button, owner rule): the FLAVOURS button in the Pets window's top
	bar (FlavorBook/EntryButton, a ScreenManager.handoff: B returns to Pets), the discovery toast,
	and the HUD Pets badge counts ready rewards (Pets/PetController).

	Console + mobile (owner R11): ResponsiveModal modes "grid" (1400 x 900) and "wide" (1500 x 640,
	landscape phones). Mouse / gamepad (desktop, console) get the GRID layout: the whole 5 x 3 grid
	with world row labels. Every TOUCH device (phones and tablets) gets the PAGE layout: WORLD TABS
	(NUKE TOWN / DINO VALLEY / MOON BASE, "(n)" = ready rewards) over that world's five flavours in
	3 columns (2 rows, the grid scrolls when the window is short), each tile an icon + FOUR stacked
	lines (name / "SELLS x3" / "1 in 100" / pill) at least the 14 pt floor tall — 15 tiles at 14 pt
	cut the words ("SPRINKL", "X1.5 · 1 IN": Studio pass 2026-10-31). Every word comes from
	FlavorConfig.Text (owner R112: the subtitle "Rare nukes your machines can make. Find each one for
	gems!" shows in both layouts; tiles say "SELLS x3"). Every tile / tab / button
	>= 44 pt (layout.tap), every text >= 14 pt (layout.minText); scaled text never breaks a word.
	Gamepad: the visible tiles are linked as a grid (GamepadNav.linkGrid) under CLAIM ALL (page:
	under the world tabs, LB / RB switch worlds; the grid follows the cursor); the cursor starts on
	the first ready tile, else CLAIM ALL when ready, else the first tile; B / Back closes (back to
	Pets when opened from there).

	Analytics: ClientAnalytics.screenOpened("FlavorBook", source) — sources "pets" (the button),
	"hud" (default).

	Connects to: Client/ClientState, Shared/Config/{FlavorConfig, UIStyleConfig, Worlds/WorldsConfig},
	Shared/Tycoon/FlavorLogic, Shared/Net/Remotes (FlavorClaim), Screens/DailyRewards/ResponsiveModal,
	Kit/StudUI, Widgets/StudWindow, Platform/GamepadNav, Analytics/ClientAnalytics, Tycoon/Fx/FlavorPops.

	Example: ScreenManager.open("FlavorBook", { source = "pets" })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Create)
local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local FlavorLogic = require(ReplicatedStorage.Shared.Tycoon.FlavorLogic)
local FlavorPops = require(script.Parent.Parent.Parent.Tycoon.Fx.FlavorPops)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ResponsiveModal = require(script.Parent.DailyRewards.ResponsiveModal)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldLookup = require(script.Parent.Parent.Parent.Tycoon.WorldLookup)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local NAME = FlavorConfig.BookScreen
local ANALYTICS_ID = "FlavorBook"
local PENDING_SECONDS = 3
local COLUMNS = FlavorConfig.SpecialCount
local GAP = 12
local Neutral = UIStyleConfig.Neutral

-- One Book tile (world x flavour).
type Tile = {
	key: string,
	worldId: string,
	def: FlavorConfig.FlavorDef,
	button: TextButton,
	surface: StudWindow.Surface,
	icon: Frame,
	iconImage: ImageLabel?,
	question: TextLabel,
	name: TextLabel,
	odds: TextLabel,
	mult: TextLabel, -- touch page only: its own "x1.5" line
	pill: Frame,
	pillSurface: StudWindow.Surface,
	pillText: TextLabel,
	state: string, -- "locked" | "ready" | "claimed" (last painted)
}

-- The world's display name ("Nuke Town").
local function worldName(worldId: string): string
	local def = WorldsConfig.get(worldId)
	return if def ~= nil then def.name else worldId
end

-- The live luck the server rolls with (ReplicatedStorage attribute; 1 when unknown / junk).
local function liveLuck(): number
	return FlavorLogic.clampLuck(ReplicatedStorage:GetAttribute(FlavorConfig.Attr.Luck) or 1)
end

-- Applies a scaled text's size cap and floor (touch: never below layout.minText).
local function fitText(label: TextLabel, maxSize: number, minText: number)
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if constraint ~= nil then
		constraint.MaxTextSize = math.max(maxSize, minText)
		constraint.MinTextSize = math.max(10, minText)
	end
end

return ResponsiveModal.screen({
	name = NAME,
	title = FlavorConfig.Text.BookTitle,
	color = "rainbow",
	icon = "Nuke",
	modes = {
		{ name = "grid", size = Vector2.new(1400, 900) },
		{ name = "wide", size = Vector2.new(1500, 640) },
	},
	build = function(window: StudUI.Window, _gui: ScreenGui, layout: ResponsiveModal.Controller)
		local body = window.body
		local isOpen = false
		local pending: { [string]: number } = {}
		-- Touch page layout (phones + tablets): one world's page at a time, picked with the world tabs.
		local wideMode = false
		local selectedWorld = FlavorConfig.Worlds[1]

		-- ── Header: luck chip · discovered · CLAIM ALL ───────────────────────────────────────
		local header = Create.new("Frame", {
			Name = "Header",
			BackgroundTransparency = 1,
			Parent = body,
		}) :: Frame
		local luckChip = Create.new("Frame", {
			Name = "LuckChip",
			BackgroundTransparency = 0,
			Visible = false,
			Parent = header,
		}) :: Frame
		StudWindow.surface(luckChip, "yellow", { edge = 3, corner = 14 })
		local luckText = StudUI.text({
			name = "Text",
			text = "LUCK x2!",
			textSize = 30,
			font = "shout",
			scaled = true,
			size = UDim2.new(1, -16, 1, -8),
			position = UDim2.fromOffset(8, 4),
			zIndex = 3,
			parent = luckChip,
		})
		local discovered = StudUI.text({
			name = "Discovered",
			text = "",
			textSize = 34,
			font = "number",
			scaled = true,
			align = Enum.TextXAlignment.Center,
			parent = header,
		})
		local claimAll = StudUI.button({
			name = "ClaimAll",
			text = "CLAIM ALL",
			color = "green",
			icon = "Gems",
			size = UDim2.fromOffset(340, 86), -- the text / icon size follow this height (place() resizes)
			textSize = 34,
			parent = header,
			onActivated = function()
				pending.all = os.clock() + PENDING_SECONDS
				Remotes.event("FlavorClaim"):FireServer("all")
			end,
		})

		-- ── World tabs (touch page layout only) ─────────────────────────────────────────────
		local tabBar = Create.new("Frame", {
			Name = "WorldTabs",
			BackgroundTransparency = 1,
			Visible = false,
			Parent = body,
		}) :: Frame
		local worldTabs: { [string]: StudUI.Button } = {}
		local tabList: { GuiObject } = {}
		local selectWorld: (worldId: string) -> ()

		-- ── The grid: world rows x flavour tiles ─────────────────────────────────────────────
		-- A ScrollingFrame: the touch page layout (3 columns, 2 rows) may be taller than the window;
		-- desktop / console fit and never scroll.
		local grid = Create.new("ScrollingFrame", {
			Name = "Grid",
			BackgroundColor3 = Neutral.Well,
			BorderSizePixel = 0,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 10,
			ScrollBarImageColor3 = Neutral.Edge,
			AutomaticCanvasSize = Enum.AutomaticSize.None,
			Selectable = false,
			Parent = body,
			Children = {
				Create.new("UICorner", { CornerRadius = UDim.new(0, 12) }),
			},
		}) :: ScrollingFrame
		GamepadNav.followScroll(grid)
		local rowLabels: { TextLabel } = {}
		local tiles: { Tile } = {}
		local buttons: { GuiObject } = {}
		local render: () -> ()

		for row, worldId in FlavorConfig.Worlds do
			local label = StudUI.text({
				name = `Row_{worldId}`,
				text = worldName(worldId),
				textSize = 32,
				scaled = true,
				align = Enum.TextXAlignment.Left,
				parent = grid,
			})
			label.TextWrapped = true
			rowLabels[row] = label
			for _, def in FlavorConfig.Special do
				local key = FlavorLogic.key(worldId, def.id)
				local button = Create.new("TextButton", {
					Name = `Tile_{key}`,
					Text = "",
					AutoButtonColor = false,
					Selectable = true,
					BackgroundTransparency = 0,
					SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }),
					Parent = grid,
				}) :: TextButton
				local surface = StudWindow.surface(button, "grey", { edge = 3, corner = 14 })
				local ring = Create.new("UIStroke", {
					Name = "Ring",
					Color = Color3.new(1, 1, 1),
					Thickness = 5,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					Enabled = false,
					Parent = button,
				}) :: UIStroke
				button.SelectionGained:Connect(function()
					ring.Enabled = true
				end)
				button.SelectionLost:Connect(function()
					ring.Enabled = false
				end)
				local icon = StudUI.icon("Nuke", 96, 3)
				icon.Parent = button
				local question = StudUI.text({
					name = "Question",
					text = "?",
					textSize = 80,
					font = "shout",
					scaled = true,
					zIndex = 5,
					parent = button,
				})
				local nameLabel = StudUI.text({
					name = "Name",
					text = "",
					textSize = 28,
					font = "shout",
					scaled = true,
					zIndex = 4,
					parent = button,
				})
				local odds = StudUI.text({
					name = "Odds",
					text = "",
					textSize = 24,
					font = "number",
					scaled = true,
					zIndex = 4,
					parent = button,
				})
				-- The touch page's own multiplier line ("x1.5"); hidden on desktop / console, where
				-- the odds line reads "x1.5 · 1 in 20".
				local multLabel = StudUI.text({
					name = "Mult",
					text = "",
					textSize = 24,
					font = "number",
					scaled = true,
					color = Color3.fromRGB(255, 232, 110),
					zIndex = 4,
					parent = button,
				})
				-- Scaled text shrinks to the WIDTH instead of breaking a word across lines
				-- ("SPRINKL" + "E" on phones before).
				nameLabel.TextWrapped = false
				odds.TextWrapped = false
				multLabel.TextWrapped = false
				local pill = Create.new("Frame", {
					Name = "Pill",
					BackgroundTransparency = 0,
					ZIndex = 4,
					Parent = button,
				}) :: Frame
				local pillSurface = StudWindow.surface(pill, "grey", { edge = 2, corner = 10, zIndex = 4 })
				local pillText = StudUI.text({
					name = "Text",
					text = "",
					textSize = 24,
					font = "shout",
					scaled = true,
					size = UDim2.new(1, -10, 1, -4),
					position = UDim2.fromOffset(5, 2),
					zIndex = 6,
					parent = pill,
				})
				pillText.TextWrapped = false
				local tile: Tile = {
					key = key,
					worldId = worldId,
					def = def,
					button = button,
					surface = surface,
					icon = icon,
					iconImage = icon:FindFirstChildOfClass("ImageLabel"),
					question = question,
					name = nameLabel,
					odds = odds,
					mult = multLabel,
					pill = pill,
					pillSurface = pillSurface,
					pillText = pillText,
					state = "",
				}
				button.Activated:Connect(function()
					if tile.state == "ready" and (pending[key] or 0) < os.clock() then
						pending[key] = os.clock() + PENDING_SECONDS
						Remotes.event("FlavorClaim"):FireServer(key)
						render()
					end
				end)
				table.insert(tiles, tile)
				table.insert(buttons, button)
			end
		end

		for order, worldId in FlavorConfig.Worlds do
			local tab = StudUI.button({
				name = `Tab_{worldId}`,
				text = string.upper(worldName(worldId)),
				color = "grey",
				size = UDim2.fromOffset(440, 80),
				textSize = 32,
				layoutOrder = order,
				parent = tabBar,
				onActivated = function()
					selectWorld(worldId)
				end,
			})
			worldTabs[worldId] = tab
			table.insert(tabList, tab.instance)
		end

		local hint = StudUI.text({
			name = "Hint",
			text = FlavorConfig.Text.BookSubtitle, -- owner R112: "Rare nukes your machines can make. ..."
			textSize = 24,
			scaled = true,
			color = Neutral.TextDim,
			parent = body,
		})

		-- ── Layout (re-run on every layout change / world switch) ─────────────────────────────
		-- Two layouts:
		--   grid  (mouse / gamepad: desktop, console) every world as a row of 5 tiles; tile = icon on
		--         top, name / "x3 · 1 in 100" / pill below.
		--   page  (any TOUCH device: phones in "wide", tablets in "grid" mode) world tabs + the
		--         selected world's 5 tiles in 3 columns (2 rows, the grid scrolls when needed); tile
		--         = icon left, FOUR stacked lines right (name / x3 / 1 in 100 / pill), each line at
		--         least the 14 pt text floor tall, so the full name, multiplier and odds always fit
		--         (5 columns at 14 pt cut them: "SPRINKL", "X1.5 · 1 IN" — Studio pass 2026-10-31).
		local PAGE_COLUMNS = 3

		-- Grid-layout tile content (desktop / console).
		local function placeGridTile(tile: Tile, tileW: number, tileH: number, minText: number)
			local inner = 8
			local pillH = math.max(34, minText + 10)
			local lineH = math.max(26, minText + 6)
			local side = math.min(tileW - inner * 2, math.max(40, tileH - inner * 3 - pillH - lineH * 2))
			tile.icon.Position = UDim2.fromOffset((tileW - side) / 2, inner)
			tile.icon.Size = UDim2.fromOffset(side, side)
			tile.question.Position = tile.icon.Position
			tile.question.Size = tile.icon.Size
			local y0 = inner + side
			tile.name.Position = UDim2.fromOffset(inner, y0)
			tile.name.Size = UDim2.fromOffset(tileW - inner * 2, lineH)
			tile.odds.Position = UDim2.fromOffset(inner, y0 + lineH)
			tile.odds.Size = UDim2.fromOffset(tileW - inner * 2, lineH)
			tile.mult.Visible = false
			tile.pill.Position = UDim2.fromOffset(inner * 2, tileH - inner - pillH)
			tile.pill.Size = UDim2.fromOffset(tileW - inner * 4, pillH)
			fitText(tile.name, 28, minText)
			fitText(tile.odds, 24, minText)
			fitText(tile.pillText, 24, minText)
			fitText(tile.question, 120, minText)
		end

		-- The height of one page-layout line at this device's text floor.
		local function pageLine(minText: number): number
			return math.max(40, minText + 12)
		end

		-- Page-layout tile content (touch): icon left, four stacked lines right.
		local function placePageTile(tile: Tile, tileW: number, tileH: number, minText: number)
			local inner = 12
			local lineH = pageLine(minText)
			local side = math.min(tileH - inner * 2, tileW * 0.22)
			tile.icon.Position = UDim2.fromOffset(inner, (tileH - side) / 2)
			tile.icon.Size = UDim2.fromOffset(side, side)
			tile.question.Position = tile.icon.Position
			tile.question.Size = tile.icon.Size
			local textX = inner * 2 + side
			local textW = tileW - textX - inner
			local y0 = (tileH - lineH * 4) / 2
			tile.name.Position = UDim2.fromOffset(textX, y0)
			tile.name.Size = UDim2.fromOffset(textW, lineH)
			tile.mult.Visible = true
			tile.mult.Position = UDim2.fromOffset(textX, y0 + lineH)
			tile.mult.Size = UDim2.fromOffset(textW, lineH)
			tile.odds.Position = UDim2.fromOffset(textX, y0 + lineH * 2)
			tile.odds.Size = UDim2.fromOffset(textW, lineH)
			tile.pill.Position = UDim2.fromOffset(textX, y0 + lineH * 3 + 2)
			tile.pill.Size = UDim2.fromOffset(textW, lineH - 4)
			local textMax = lineH - 6
			fitText(tile.name, textMax, minText)
			fitText(tile.mult, textMax, minText)
			fitText(tile.odds, textMax, minText)
			fitText(tile.pillText, textMax - 6, minText)
			fitText(tile.question, 120, minText)
		end

		local function place(current: ResponsiveModal.Layout)
			local area = current.area
			local paged = current.touch or current.mode == "wide"
			wideMode = paged
			local minText = current.minText
			local tap = current.tap
			local headerH = math.max(if paged then 78 else 90, tap, minText + 30)
			-- The subtitle line shows in both layouts (owner R112: say what the Book is for).
			local hintH = math.max(34, minText + 8)
			header.Position = UDim2.fromOffset(0, 0)
			header.Size = UDim2.fromOffset(area.X, headerH)
			-- Luck chip (left), CLAIM ALL (right), discovered (centre).
			local chipW = if paged then 260 else 280
			luckChip.Position = UDim2.fromOffset(0, 6)
			luckChip.Size = UDim2.fromOffset(chipW, headerH - 12)
			fitText(luckText, 30, minText)
			local claimW = if paged then 360 else 340
			claimAll.instance.AnchorPoint = Vector2.new(1, 0)
			claimAll.instance.Position = UDim2.new(1, 0, 0, 2)
			claimAll.instance.Size = UDim2.fromOffset(claimW, headerH - 4)
			discovered.Position = UDim2.fromOffset(chipW + GAP, 0)
			discovered.Size = UDim2.fromOffset(math.max(100, area.X - chipW - claimW - GAP * 2), headerH)
			fitText(discovered, 34, minText)
			-- World tabs (page layout only).
			local top = headerH + GAP
			tabBar.Visible = paged
			if paged then
				local tabH = math.max(72, tap, minText + 28)
				local tabW = (area.X - GAP * (#tabList - 1)) / #tabList
				tabBar.Position = UDim2.fromOffset(0, top)
				tabBar.Size = UDim2.fromOffset(area.X, tabH)
				for index, worldId in FlavorConfig.Worlds do
					local tab = worldTabs[worldId].instance
					tab.Position = UDim2.fromOffset((index - 1) * (tabW + GAP), 0)
					tab.Size = UDim2.fromOffset(tabW, tabH)
				end
				top += tabH + GAP
			end
			-- Grid area.
			local gridH = area.Y - top - (if hintH > 0 then hintH + GAP else 0)
			grid.Position = UDim2.fromOffset(0, top)
			grid.Size = UDim2.fromOffset(area.X, gridH)
			local pad = 10
			local scrollBar = if paged then 14 else 0
			if paged then
				-- 3 columns x 2 rows of the selected world; tiles as tall as four text lines need.
				local tileW = (area.X - pad * 2 - scrollBar - GAP * (PAGE_COLUMNS - 1)) / PAGE_COLUMNS
				local tileH = math.max(tap, pageLine(minText) * 4 + 24)
				local rows = math.ceil(COLUMNS / PAGE_COLUMNS)
				for _, label in rowLabels do
					label.Visible = false
				end
				for index, tile in tiles do
					local visible = tile.worldId == selectedWorld
					tile.button.Visible = visible
					local slot = (index - 1) % COLUMNS -- 0..4 within its world
					local row = slot // PAGE_COLUMNS
					local column = slot % PAGE_COLUMNS
					tile.button.Position = UDim2.fromOffset(pad + column * (tileW + GAP), pad + row * (tileH + GAP))
					tile.button.Size = UDim2.fromOffset(tileW, tileH)
					placePageTile(tile, tileW, tileH, minText)
				end
				local contentH = pad * 2 + rows * tileH + (rows - 1) * GAP
				grid.CanvasSize = UDim2.fromOffset(0, contentH)
				grid.ScrollingEnabled = contentH > gridH
			else
				local labelW = 200
				local rows = #FlavorConfig.Worlds
				local tileW = (area.X - pad * 2 - labelW - GAP * (COLUMNS - 1)) / COLUMNS
				local tileH = (gridH - pad * 2 - GAP * (rows - 1)) / rows
				for row, label in rowLabels do
					label.Visible = true
					label.Position = UDim2.fromOffset(pad, pad + (row - 1) * (tileH + GAP))
					label.Size = UDim2.fromOffset(labelW - GAP, tileH)
					fitText(label, 34, minText)
				end
				for index, tile in tiles do
					tile.button.Visible = true
					local row = (index - 1) // COLUMNS
					local column = (index - 1) % COLUMNS
					tile.button.Position =
						UDim2.fromOffset(pad + labelW + column * (tileW + GAP), pad + row * (tileH + GAP))
					tile.button.Size = UDim2.fromOffset(tileW, tileH)
					placeGridTile(tile, tileW, tileH, minText)
				end
				grid.CanvasSize = UDim2.fromOffset(0, gridH)
				grid.ScrollingEnabled = false
				grid.CanvasPosition = Vector2.zero
			end
			grid.ScrollBarThickness = scrollBar
			hint.Visible = hintH > 0
			hint.Position = UDim2.fromOffset(0, area.Y - hintH)
			hint.Size = UDim2.fromOffset(area.X, hintH)
			fitText(hint, 24, minText)
		end

		-- ── Render (server data only) ────────────────────────────────────────────────────────
		-- Paints one tile for its state (only writes what changed state-wise + the live texts).
		local function paintTile(tile: Tile, found: number, claimed: boolean, luck: number, now: number)
			local def = tile.def
			local state = if found < 1 then "locked" elseif claimed then "claimed" else "ready"
			local oneIn = FlavorLogic.formatOdds(FlavorLogic.oneIn(def.rank, luck))
			local mult = FlavorPops.multText(def.mult)
			if state ~= tile.state then
				tile.state = state
				local discoveredTile = state ~= "locked"
				tile.surface.setColor(if discoveredTile then def.ui else "grey")
				tile.question.Visible = not discoveredTile
				local image = tile.iconImage
				if image ~= nil then
					image.ImageColor3 = if discoveredTile
						then def.color:Lerp(Color3.new(1, 1, 1), 0.35)
						else Color3.fromRGB(70, 74, 88)
				end
			end
			local Text = FlavorConfig.Text
			tile.name.Text = if state == "locked" then Text.TileUnknown else string.upper(def.name)
			-- Page layout (touch): "x3" and "1 in 100" on their own lines; grid: one combined line.
			tile.mult.Text = string.format(Text.TileSells, mult) -- "SELLS x3"
			tile.odds.Text = if wideMode
				then (if oneIn ~= "" then oneIn else "-")
				elseif oneIn ~= "" then `{mult} · {oneIn}`
				else mult
			local sending = (pending[tile.key] or 0) > now or (pending.all or 0) > now
			if state == "ready" then
				tile.pillSurface.setColor("green")
				tile.pillText.Text = if sending then "..." else string.format(Text.TileClaim, def.gems)
			elseif state == "claimed" then
				tile.pillSurface.setColor("grey")
				tile.pillText.Text = string.format(Text.TileFound, NumberFormat.short(found))
			else
				tile.pillSurface.setColor("grey")
				tile.pillText.Text = string.format(Text.TileGems, def.gems)
			end
		end

		-- The tiles on screen (all 15; touch page layout: the selected world's five).
		local function visibleButtons(): { GuiObject }
			if not wideMode then
				return buttons
			end
			local out: { GuiObject } = {}
			for _, tile in tiles do
				if tile.worldId == selectedWorld then
					table.insert(out, tile.button)
				end
			end
			return out
		end

		-- Gamepad links: grid mode = the 5 x 3 grid under CLAIM ALL; wide = the world's row under
		-- the tabs, the tabs under CLAIM ALL.
		local function relink()
			local visible = visibleButtons()
			if wideMode then
				local active = worldTabs[selectedWorld].instance
				GamepadNav.linkGrid(visible, PAGE_COLUMNS, { up = active })
				GamepadNav.linkList(tabList, false)
				for _, tab in tabList do
					tab.NextSelectionUp = claimAll.instance
					tab.NextSelectionDown = visible[1]
				end
				claimAll.instance.NextSelectionDown = active
			else
				GamepadNav.linkGrid(visible, COLUMNS, { up = claimAll.instance })
				claimAll.instance.NextSelectionDown = visible[1]
			end
		end

		render = function()
			local book: any = if type(ClientState.profile) == "table" then (ClientState.profile :: any).flavors else nil
			local found = if type(book) == "table" and type(book.found) == "table" then book.found else {}
			local claimedMap = if type(book) == "table" and type(book.claimed) == "table" then book.claimed else {}
			local luck = liveLuck()
			local now = os.clock()
			for _, tile in tiles do
				local count = found[tile.key]
				paintTile(
					tile,
					if type(count) == "number" and count == count then count else 0,
					claimedMap[tile.key] == true,
					luck,
					now
				)
			end
			local ready = FlavorLogic.claimableCount(book)
			discovered.Text = `Discovered {FlavorLogic.discovered(book)} / {FlavorLogic.total()}`
			-- World tabs: selected = orange; "(n)" = that world's ready rewards.
			for _, worldId in FlavorConfig.Worlds do
				local worldReady = #FlavorLogic.claimable(book, { worldId })
				local label = string.upper(worldName(worldId))
				local tab = worldTabs[worldId]
				tab.setColor(if worldId == selectedWorld then "orange" elseif worldReady > 0 then "green" else "grey")
				tab.setText(if worldReady > 0 then `{label} ({worldReady})` else label)
			end
			if ready > 0 then
				-- (setState's text only applies to non-normal states: the live count goes through setText.)
				local sending = (pending.all or 0) > now
				claimAll.setState("normal")
				claimAll.setText(if sending then "..." else `CLAIM ALL ({ready})`)
			else
				claimAll.setState("locked", "CLAIM ALL")
			end
			local eventLuck = ReplicatedStorage:GetAttribute(FlavorConfig.Attr.EventLuck)
			luckChip.Visible = luck > 1.001
			luckText.Text = if type(eventLuck) == "number" and eventLuck > 1.001
				then `SPRINKLE SURGE {FlavorPops.multText(luck)}!`
				else `LUCK {FlavorPops.multText(luck)}!`
		end

		selectWorld = function(worldId: string)
			if selectedWorld == worldId then
				return
			end
			selectedWorld = worldId
			place(layout.current())
			relink()
			render()
		end
		-- LB / RB (Q / E) switch worlds on the phone layout (B16 GamepadNav cycler).
		local function cycleWorld(delta: number)
			if not wideMode then
				return
			end
			local index = table.find(FlavorConfig.Worlds, selectedWorld) or 1
			local count = #FlavorConfig.Worlds
			selectWorld(FlavorConfig.Worlds[(index - 1 + delta) % count + 1])
		end
		local cycler = GamepadNav.cycler(function()
			cycleWorld(-1)
		end, function()
			cycleWorld(1)
		end)

		layout.onChanged(function(current: ResponsiveModal.Layout)
			place(current)
			relink()
			render()
		end)
		place(layout.current())
		relink()

		local connections: { any } = {}
		-- Re-renders once more after a claim's pending window ends (the push may have been lost).
		local function scheduleRefresh()
			task.delay(PENDING_SECONDS + 0.1, function()
				if isOpen then
					render()
				end
			end)
		end

		return {
			onOpen = function(args: any?)
				isOpen = true
				local source = if type(args) == "table" and type(args.source) == "string" then args.source else "hud"
				ClientAnalytics.screenOpened(ANALYTICS_ID, source)
				-- Phone page: the world with the first ready reward, else the world you are in.
				local profile: any = ClientState.profile
				local ready = FlavorLogic.claimable(if type(profile) == "table" then profile.flavors else nil)
				local first = ready[1]
				local readyWorld: string? = if first ~= nil then string.match(first, "^([^:]+):") else nil
				local pick: string = readyWorld or WorldLookup.current()
				selectedWorld = if table.find(FlavorConfig.Worlds, pick) ~= nil then pick else FlavorConfig.Worlds[1]
				place(layout.current())
				relink()
				cycler.enable()
				render()
				if #connections == 0 then
					table.insert(
						connections,
						ClientState.ProfileChanged:Connect(function(_profile: any, fields: { string }?)
							if fields == nil or table.find(fields, "flavors") ~= nil or table.find(fields, "gems") then
								table.clear(pending)
								render()
							end
						end)
					)
					table.insert(
						connections,
						ReplicatedStorage:GetAttributeChangedSignal(FlavorConfig.Attr.Luck):Connect(render)
					)
					table.insert(
						connections,
						claimAll.instance.Activated:Connect(function()
							render()
							scheduleRefresh()
						end)
					)
					for _, tile in tiles do
						table.insert(connections, tile.button.Activated:Connect(scheduleRefresh))
					end
				end
			end,
			onClose = function()
				isOpen = false
				cycler.disable()
				for _, connection in connections do
					connection:Disconnect()
				end
				table.clear(connections)
			end,
			defaultSelection = function(): GuiObject?
				for _, tile in tiles do
					if tile.state == "ready" and tile.button.Visible then
						return tile.button
					end
				end
				if claimAll.state() == "normal" then
					return claimAll.instance
				end
				return visibleButtons()[1] or tiles[1].button
			end,
		}
	end,
})
