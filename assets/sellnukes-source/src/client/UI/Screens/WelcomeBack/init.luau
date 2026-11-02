--!strict
--[[
	WelcomeBack — the offline-earnings popup (reference
	docs/reference/ui-style/07-offline-earnings-welcome-back.png): a green stud window titled
	"WELCOME BACK!" with

		You were offline for 54m 35s and earned...
		( $377,536,939,622 )                         big green number in a dark stud well
		[  OKAY  ]   x2 [ DOUBLE IT! ]               grey closes; green prompts the
		                  (R) 39                     DoubleOffline developer product

	Flow:
		1. At boot (lazy = false) the screen listens to the server's OfflineEarnings remote
		   ({ amount, seconds, rate, worlds = { { id, amount } }? }); a valid payload (table,
		   finite main amount >= 0, finite seconds >= 0, at least one world with a payout > 0)
		   opens the window with it. The server computed and already credited every payout; the
		   window only shows the server's numbers.
		2. DOUBLE IT! sends the intent PromptProduct("DoubleOffline", "welcomeBack"). The server
		   validates the prompt and, on a durable grant, doubles every pending payout once. Owner
		   R122: a tagged BUY behind UI/PurchaseGuard (never the default cursor; a press that began
		   before the popup opened never prompts).
		3. ClientState.PurchaseGranted with kind "DoubleOffline" while open: the number(s) roll up
		   to x 2, the button turns into a claimed "DOUBLED!", and the window closes itself 2 s
		   later.
		Closing the window (any way) is the CurrencyFly "offline" claim (CurrencyFlyConfig
		.OfflineScreen = "WelcomeBack"): the screen name and close flow are part of that contract.

	Worlds (owner R57 World 2, spec §6.6 / §14): `amount` is Nuke Town's cash payout; `worlds`
	lists every OTHER world's non-zero payout. Only Nuke Town paid -> the pre-R57 window exactly
	(the big "$377,536,939,622" number). Any other world paid -> the well shows one row per world
	with a payout, in WorldsConfig.Order: the world's currency icon, its name and the amount via
	WorldClientLogic.formatAmount ("Nuke Town  $1.2T" / "Dino Valley  4.5M Bones"); DOUBLE IT!
	rolls every row to x 2. Up to 2 rows stack in one column, more use two columns (each row then
	is [currency icon][amount], no name — R70, half-width rows cannot fit one), and the rows
	scroll (and become D-pad selectable) only if they ever overflow the well. Every world entry is
	validated (known non-main id, no duplicates, finite amount > 0, at most WorldsConfig.MaxWorlds).
		Unpublished product (MonetizationConfig.isProductAvailable false): DOUBLE IT! is locked
		with "SOON" (its price stays visible under it).

	Console + mobile (owner R11, docs/platform.md §7): OKAY <-> DOUBLE IT! are linked for the
	D-pad (GamepadNav.linkList) and the gamepad cursor starts on OKAY (a stray A press never
	starts a purchase); B / Back closes (ScreenManager). Sized so a phone (0.62 pt per design px)
	keeps the buttons >= 44 pt, the red X ~44 pt and the offline line >= 14 pt (its scaled text
	never shrinks below 14 rendered px = 14 pt; R78 corrected the floor, see LINE_MIN_TEXT).

	Performance: built once at boot (a handful of instances; no work until the remote fires).
	The roll-up is one short tween on a NumberValue (skipped with Reduce Motion).

	Security: purely presentational. Amounts come from the server payload (validated here);
	the only thing sent is the purchase intent, which MonetizationService validates.

	Connects to: Kit/StudUI, UI/{Create, ScreenManager}, Widgets/{StudWindow, PanelBackdrop,
	OfferFx}, Platform/GamepadNav, Client/ClientState (PurchaseGranted), Analytics/ClientAnalytics,
	Worlds/WorldClientLogic (formatAmount), Shared/Net/Remotes (OfflineEarnings, PromptProduct),
	Shared/Config/{MonetizationConfig, UIStyleConfig, Worlds/WorldsConfig}, Shared/Util/NumberFormat,
	UI/Hud/CurrencyFly (the close is the "offline" claim). Server side: OfflineService (per-world
	payout + DoubleOffline product handler, MonetizationService).

	Comeback Rush (owner R78 spec §3, R-social): when the server grants a Comeback Rush on this join
	(RushService → `Social { kind = "comeback" }` → Client/Social/SocialClient), the window carries
	an orange stud banner "COMEBACK RUSH! 2x CASH for 10 min" between the offline line and the well
	(the line and well shrink a little so the buttons keep their size). With an offline payout it
	is the normal window plus the banner; a comeback WITHOUT a payout (nothing was automated yet)
	opens a rush-only window: "You were away for 3d 4h!", a big "2x CASH" in the well, the banner,
	and one centred LET'S GO! button (no DOUBLE IT). The comeback request goes through the same
	JoinFlow key as the payout and opens with the payout when one is queued, so neither replaces
	the other; a payout arriving later swaps the rush-only window into the payout window in place.

	Example (what the remote does):
		ScreenManager.open("WelcomeBack", { amount = 377536939622, seconds = 3275 })
		ScreenManager.open("WelcomeBack", { amount = 1.2e12, seconds = 3275,
			worlds = { { id = "dino", amount = 4.5e6 } } }) -- two rows
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Create)
local FtueConfig = require(ReplicatedStorage.Shared.Config.FtueConfig)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local JoinFlow = require(script.Parent.Parent.Parent.Platform.JoinFlow)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local OfferFx = require(script.Parent.Parent.Widgets.OfferFx)
local PanelBackdrop = require(script.Parent.Parent.Widgets.PanelBackdrop)
-- Owner R122 purchase-focus hygiene (opening-press guard, BUY tag, safe default selection).
local PurchaseGuard = require(script.Parent.Parent.PurchaseGuard)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local SocialClient = require(script.Parent.Parent.Parent.Social.SocialClient)
local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldClientLogic = require(script.Parent.Parent.Parent.Worlds.WorldClientLogic)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local NAME = "WelcomeBack"
local MAIN = WorldsConfig.MAIN
-- 550 tall: on a landscape phone ModalShell's fit stays ~0.9, so taps stay >= 44 pt.
local WINDOW_SIZE = Vector2.new(1000, 550)
local PRODUCT_KEY = "DoubleOffline"
-- PurchasePromptConfig.Sources / AnalyticsConfig sources for this surface.
local PROMPT_SOURCE = "welcomeBack"
local OFFER_SOURCE = "welcome"
-- Seconds the doubled number stays on screen before the window closes itself.
local CLOSE_AFTER_DOUBLE = 2
-- Roll-up of the doubled number.
local ROLL_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Geometry (design px).
local LINE_HEIGHT = 48
-- Readability floor of the scaled offline line, in RENDERED px (a UITextSizeConstraint counts
-- rendered pixels = device points on phones, NOT design px): 14 = the platform's 14 pt minimum.
-- R78 fix: the old 28 was meant as design px but acted as 28 rendered px, so the line could not
-- shrink and spilled out of its box on small screens (measured in tools/qa/social.py text_fit).
local LINE_MIN_TEXT = 14
local WELL_HEIGHT = 140
local WELL_CORNER = 44
local BUTTON_SIZE = Vector2.new(340, 96)
local BUTTON_GAP = 40
local ROW_HEIGHT = 196
local X2_HEIGHT = 50
-- R57 world rows inside the well (design px): row height, gap, side inset, icon, text floor.
local WORLD_ROW_HEIGHT = 58
local WORLD_ROW_GAP = 8
local WORLD_ROWS_INSET = 30
local WORLD_ROWS_MAX_HEIGHT = WELL_HEIGHT - 16 -- two rows fit exactly: 2 x 58 + 8
local WORLD_ROW_ICON = 50
-- Rendered-px floor of the world rows' scaled text (14 = 14 pt; same R78 fix as LINE_MIN_TEXT).
local WORLD_ROW_MIN_TEXT = 14
-- Up to this many rows stack in one column; more use two columns.
local ONE_COLUMN_ROWS = 2
-- R78 Comeback Rush banner (design px): with it the line and well shrink so the body still fits.
local BANNER_HEIGHT = 40
local BANNER_LINE_HEIGHT = 40
local BANNER_WELL_HEIGHT = 120
local BANNER_PADDING = 6
local BODY_PADDING = 12

-- One world's payout line (WorldsConfig id + the server's amount for it).
type WorldPayout = { id: string, amount: number }

--[[
	A validated OfflineEarnings payload (the fields this window shows). `amount` is Nuke Town's
	cash (0 when only another world paid); `worlds` holds EVERY world with a payout > 0 (Nuke Town
	included), in WorldsConfig.Order, never empty.
]]
type Payload = { amount: number, seconds: number, worlds: { WorldPayout } }

-- One world's row in the well (built once per world at boot).
type WorldRow = {
	frame: Frame,
	name: TextLabel, -- the world's name (one-column layout only)
	amount: TextLabel,
	currency: WorldsConfig.CurrencyDef,
	-- R70 (3+ worlds = two columns): a half-width row has no room for a readable name, so it is
	-- [currency icon][amount] — the icon names the world, the amount drops its currency word.
	compact: boolean,
}

--[[
	A finite, strictly positive number, or nil.
	Example: positive(12.5) --> 12.5 ; positive(0) --> nil ; positive(0 / 0) --> nil
]]
local function positive(value: unknown): number?
	if type(value) == "number" and value == value and value > 0 and value < math.huge then
		return value
	end
	return nil
end

--[[
	Validates an untrusted OfflineEarnings payload / onOpen args.
	@param value anything
	@return Payload when value is a table with a finite main amount >= 0, finite seconds >= 0 and
	        at least one world paying > 0. `worlds` entries must be tables with a known non-main
	        WorldsConfig id (first entry per id wins) and a finite amount > 0; junk entries are
	        skipped and at most WorldsConfig.MaxWorlds entries are read.
	Example: readPayload({ amount = 1500, seconds = 600, rate = 2.5 })
	           --> { amount = 1500, seconds = 600, worlds = { { id = "main", amount = 1500 } } }
	         readPayload({ amount = 0, seconds = 600, worlds = { { id = "dino", amount = 9 } } })
	           --> { amount = 0, seconds = 600, worlds = { { id = "dino", amount = 9 } } }
]]
local function readPayload(value: unknown): Payload?
	if type(value) ~= "table" then
		return nil
	end
	local raw = value :: { [string]: unknown }
	local amount = raw.amount
	local seconds = raw.seconds
	if type(amount) ~= "number" or amount ~= amount or amount < 0 or amount == math.huge then
		return nil
	end
	if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 or seconds == math.huge then
		return nil
	end
	local byWorld: { [string]: number } = {}
	if amount > 0 then
		byWorld[MAIN] = amount
	end
	local list = raw.worlds
	if type(list) == "table" then
		local entries = list :: { unknown }
		for index = 1, WorldsConfig.MaxWorlds do
			local entry = entries[index]
			if type(entry) ~= "table" then
				break
			end
			local fields = entry :: { [string]: unknown }
			local id = fields.id
			local worldAmount = positive(fields.amount)
			if
				type(id) == "string"
				and id ~= MAIN
				and byWorld[id] == nil
				and worldAmount ~= nil
				and WorldsConfig.get(id) ~= nil
			then
				byWorld[id] = worldAmount
			end
		end
	end
	local worlds: { WorldPayout } = {}
	for _, worldId in WorldsConfig.Order do
		local paid = byWorld[worldId]
		if paid ~= nil then
			table.insert(worlds, { id = worldId, amount = paid })
		end
	end
	if #worlds == 0 then
		return nil
	end
	return { amount = amount, seconds = seconds, worlds = worlds }
end

--[[
	True when the payout needs the per-world rows (any world other than Nuke Town paid); a Nuke
	Town-only payout keeps the pre-R57 big number.
	Example: usesRows({ ..., worlds = { { id = "main", amount = 5 } } }) --> false
]]
local function usesRows(payload: Payload): boolean
	local first = payload.worlds[1]
	return #payload.worlds > 1 or (first ~= nil and first.id ~= MAIN)
end

--[[
	Readability floor for a scaled label: it never shrinks below `size` design px.
	Example: minTextSize(label, 28)
]]
local function minTextSize(label: TextLabel, size: number)
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if constraint ~= nil then
		constraint.MinTextSize = size
	end
end

--[[
	Builds one world's row (hidden until a payout shows it): currency icon, world name (left) and
	the amount in the currency's colour (right). Sorted by def.order in the rows grid.
	@param def    the world
	@param parent the rows frame
	@return WorldRow
	Example: buildWorldRow(WorldsConfig.get("dino"), rows).amount.Text = "4.5M Bones"
]]
local function buildWorldRow(def: WorldsConfig.WorldDef, parent: Instance): WorldRow
	local frame = Create.new("Frame", {
		Name = `World_{def.id}`,
		BackgroundTransparency = 1,
		LayoutOrder = def.order,
		Visible = false,
		ZIndex = 3,
		Parent = parent,
	}) :: Frame
	local icon = StudUI.icon(def.currency.icon, WORLD_ROW_ICON, 4)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0, 0.5)
	icon.Parent = frame
	local name = StudUI.text({
		name = "WorldName",
		text = def.name,
		textSize = 36,
		scaled = true,
		align = Enum.TextXAlignment.Left,
		position = UDim2.fromOffset(WORLD_ROW_ICON + 12, 0),
		size = UDim2.new(0.42, -(WORLD_ROW_ICON + 12), 1, 0),
		zIndex = 4,
		parent = frame,
	})
	minTextSize(name, WORLD_ROW_MIN_TEXT)
	local amount = StudUI.text({
		name = "Amount",
		text = "",
		textSize = 52,
		font = "number",
		color = def.currency.color,
		scaled = true,
		align = Enum.TextXAlignment.Right,
		position = UDim2.fromScale(0.42, 0),
		size = UDim2.fromScale(0.58, 1),
		zIndex = 4,
		parent = frame,
	})
	minTextSize(amount, WORLD_ROW_MIN_TEXT)
	StudWindow.outline(amount, 4)
	return {
		frame = frame,
		name = name,
		amount = amount,
		currency = def.currency,
		compact = false,
	}
end

--[[ Full money text for the big number (whole dollars, like the reference). ]]
local function moneyText(amount: number): string
	return NumberFormat.moneyFull(math.floor(amount))
end

return StudUI.modalScreen({
	name = NAME,
	title = "WELCOME BACK!",
	color = "green",
	size = WINDOW_SIZE,
	-- Built at boot: it must listen to OfflineEarnings before the first payout arrives.
	lazy = false,
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		window.titleLabel.FontFace = UIStyleConfig.Fonts.Shout
		local body = window.body
		local bodyList = Create.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, BODY_PADDING),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = body,
		}) :: UIListLayout

		local line = StudUI.text({
			name = "OfflineLine",
			text = "",
			textSize = 40,
			scaled = true,
			size = UDim2.new(1, -20, 0, LINE_HEIGHT),
			layoutOrder = 1,
			parent = body,
		})
		-- Readability floor: the scaled line never shrinks below LINE_MIN_TEXT rendered px (14 pt).
		local lineConstraint = line:FindFirstChildOfClass("UITextSizeConstraint")
		if lineConstraint ~= nil then
			lineConstraint.MinTextSize = LINE_MIN_TEXT
		end

		-- R78 Comeback Rush banner: an orange stud pill (hidden unless a comeback was granted).
		local banner = Create.new("Frame", {
			Name = "ComebackBanner",
			Size = UDim2.new(0.94, 0, 0, BANNER_HEIGHT),
			LayoutOrder = 2,
			Visible = false,
			Parent = body,
		}) :: Frame
		StudWindow.surface(banner, "orange", { edge = 3, corner = math.floor(BANNER_HEIGHT / 2), highlight = true })
		local bannerIcon = StudUI.icon("Star", BANNER_HEIGHT - 8, 4)
		bannerIcon.AnchorPoint = Vector2.new(0, 0.5)
		bannerIcon.Position = UDim2.new(0, 10, 0.5, 0)
		bannerIcon.Parent = banner
		local bannerLabel = StudUI.text({
			name = "BannerText",
			text = "",
			textSize = 32,
			font = "shout",
			scaled = true,
			position = UDim2.fromOffset(BANNER_HEIGHT + 8, 0),
			size = UDim2.new(1, -(BANNER_HEIGHT + 8) - 16, 1, 0),
			zIndex = 4,
			parent = banner,
		})
		-- No size floor: a floor (absolute px) kept the line from shrinking on phones and clipped
		-- it; the wide banner keeps the scaled text far above 14 pt on every device anyway.

		-- The dark stud well holding the big green number.
		local well = Create.new("Frame", {
			Name = "AmountWell",
			Size = UDim2.new(1, -60, 0, WELL_HEIGHT),
			BackgroundColor3 = UIStyleConfig.Neutral.Well,
			LayoutOrder = 3,
			Parent = body,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, WELL_CORNER) }) },
		}) :: Frame
		StudWindow.edge(well, 4)
		PanelBackdrop.new(well, {
			zIndex = 1,
			textureTransparency = UIStyleConfig.StudTransparency.Body,
			tileSize = UIStyleConfig.StudTile.Window,
			cornerRadius = WELL_CORNER,
		})
		local amountLabel = StudUI.text({
			name = "Amount",
			text = "$0",
			textSize = 110,
			font = "number",
			color = UIStyleConfig.Neutral.CashGreen,
			scaled = true,
			size = UDim2.new(1, -60, 1, -24),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
			zIndex = 3,
			parent = well,
		})
		StudWindow.outline(amountLabel, 6)

		-- R57: the per-world rows (shown instead of the big number when another world paid).
		-- A scrolling frame that hugs its rows, centred in the well; it scrolls only on overflow.
		local rowsFrame = Create.new("ScrollingFrame", {
			Name = "WorldRows",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, -2 * WORLD_ROWS_INSET, 0, WORLD_ROWS_MAX_HEIGHT),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 8,
			ScrollingEnabled = false,
			Selectable = false,
			ZIndex = 3,
			Visible = false,
			Parent = well,
		}) :: ScrollingFrame
		local rowsGrid = Create.new("UIGridLayout", {
			CellPadding = UDim2.fromOffset(WORLD_ROW_GAP, WORLD_ROW_GAP),
			CellSize = UDim2.new(1, 0, 0, WORLD_ROW_HEIGHT),
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = rowsFrame,
		}) :: UIGridLayout
		-- One row per world, built once at boot (a handful of instances; ids never change).
		local worldRows: { [string]: WorldRow } = {}
		for _, worldId in WorldsConfig.Order do
			local def = WorldsConfig.get(worldId)
			if def ~= nil then
				worldRows[worldId] = buildWorldRow(def, rowsFrame)
			end
		end

		-- Rows frame height cap: WORLD_ROWS_MAX_HEIGHT, or less while the R78 banner shrinks the well.
		local rowsMaxHeight = WORLD_ROWS_MAX_HEIGHT

		-- Buttons row: OKAY (left) and DOUBLE IT! (right, "x2" above, Robux price below).
		local row = Create.new("Frame", {
			Name = "Buttons",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			LayoutOrder = 4,
			Parent = body,
		}) :: Frame
		local okay = StudUI.button({
			name = "Okay",
			text = "OKAY",
			color = "grey",
			size = UDim2.fromOffset(BUTTON_SIZE.X, BUTTON_SIZE.Y),
			anchor = Vector2.new(1, 0),
			position = UDim2.new(0.5, -BUTTON_GAP / 2, 0, X2_HEIGHT - 4),
			parent = row,
			onActivated = function()
				ScreenManager.close(NAME)
			end,
		})
		local product = MonetizationConfig.getProduct(PRODUCT_KEY)
		local double = StudUI.button({
			name = "DoubleIt",
			text = "DOUBLE IT!",
			color = "green",
			productKey = if product ~= nil then PRODUCT_KEY else nil, -- live managed price (PriceBook)
			size = UDim2.fromOffset(BUTTON_SIZE.X, BUTTON_SIZE.Y),
			anchor = Vector2.new(0, 0),
			position = UDim2.new(0.5, BUTTON_GAP / 2, 0, X2_HEIGHT - 4),
			parent = row,
			-- R122: only a press that began after the popup opened (the join flow can open it while
			-- the player is still tapping / pressing A) may prompt (PurchaseGuard).
			onActivated = PurchaseGuard.gate(NAME, function()
				Remotes.event("PromptProduct"):FireServer(PRODUCT_KEY, PROMPT_SOURCE)
			end),
		})
		PurchaseGuard.markBuy(double.instance)
		local x2 = StudUI.text({
			name = "Times2",
			text = "x2",
			textSize = 44,
			font = "shout",
			size = UDim2.fromOffset(120, X2_HEIGHT),
			anchor = Vector2.new(0.5, 0),
			position = UDim2.new(0.5, BUTTON_GAP / 2 + BUTTON_SIZE.X / 2, 0, 0),
			zIndex = 6,
			parent = row,
		})
		-- The price stays readable under a locked (SOON) button, whose own tag hides.
		local sidePrice = StudUI.robuxTag(nil, 30, if product ~= nil then PRODUCT_KEY else nil)
		sidePrice.AnchorPoint = Vector2.new(0.5, 0)
		sidePrice.Position = UDim2.new(0.5, BUTTON_GAP / 2 + BUTTON_SIZE.X / 2, 0, X2_HEIGHT - 4 + BUTTON_SIZE.Y + 14)
		sidePrice.Visible = false
		sidePrice.Parent = row
		-- D-pad: OKAY <-> DOUBLE IT! (one row).
		GamepadNav.linkList({ okay.instance :: GuiObject, double.instance }, false)

		--[[
			Shows the rows of `payload` (hides the others) and sizes the rows frame: one column up
			to ONE_COLUMN_ROWS rows, two beyond; the frame hugs the rows and only scrolls when they
			overflow the well — then it is D-pad selectable (Up from the buttons) so a gamepad
			can scroll it too.
			@param payload the shown payout (rows mode)
		]]
		local function layoutRows(payload: Payload)
			for _, worldRow in worldRows do
				worldRow.frame.Visible = false
			end
			local count = 0
			for _, entry in payload.worlds do
				local worldRow = worldRows[entry.id]
				if worldRow ~= nil then
					worldRow.frame.Visible = true
					count += 1
				end
			end
			local columns = if count <= ONE_COLUMN_ROWS then 1 else 2
			-- Two columns (3+ worlds, R70) halve each row: any name would be cut ("Nuk" / "TOW" on
			-- a phone, verified in the device matrix), so a compact row is [icon][amount] — the
			-- currency icon names the world and the amount gets the whole row after it.
			local compact = columns > 1
			for _, worldRow in worldRows do
				if worldRow.compact ~= compact then
					worldRow.compact = compact
					worldRow.name.Visible = not compact
					local amount = worldRow.amount
					if compact then
						amount.Position = UDim2.fromOffset(WORLD_ROW_ICON + 12, 0)
						amount.Size = UDim2.new(1, -(WORLD_ROW_ICON + 12), 1, 0)
						amount.TextXAlignment = Enum.TextXAlignment.Left
					else
						amount.Position = UDim2.fromScale(0.42, 0)
						amount.Size = UDim2.fromScale(0.58, 1)
						amount.TextXAlignment = Enum.TextXAlignment.Right
					end
				end
			end
			local lines = math.max(1, math.ceil(count / columns))
			local content = lines * WORLD_ROW_HEIGHT + (lines - 1) * WORLD_ROW_GAP
			-- The well is shorter while the R78 Comeback banner shows (rowsMaxHeight follows it).
			local overflow = content > rowsMaxHeight
			rowsGrid.CellSize =
				UDim2.new(1 / columns, if columns > 1 then -WORLD_ROW_GAP / 2 else 0, 0, WORLD_ROW_HEIGHT)
			rowsFrame.Size = UDim2.new(1, -2 * WORLD_ROWS_INSET, 0, math.min(content, rowsMaxHeight))
			rowsFrame.CanvasPosition = Vector2.zero
			rowsFrame.ScrollingEnabled = overflow
			rowsFrame.Selectable = overflow
			rowsFrame.NextSelectionDown = okay.instance
			-- (nil = the engine default; the type defs say GuiObject.)
			okay.instance.NextSelectionUp = (if overflow then rowsFrame else nil) :: any
			double.instance.NextSelectionUp = (if overflow then rowsFrame else nil) :: any
		end

		-- ── State ────────────────────────────────────────────────────────────────────────────
		local isOpen = false
		local doubled = false
		local current: Payload? = nil
		-- R78: the Comeback Rush shown in this window (kept while it stays open).
		local comebackShown: SocialClient.Comeback? = nil
		-- R78: the newest payout waiting in the join queue (the comeback request opens with it, so
		-- the two requests sharing the JoinFlow key never drop the payout).
		local queuedPayload: Payload? = nil
		-- Bumped on every open / close: a stale auto-close timer never closes a newer popup.
		local openToken = 0
		-- Rolling number: the label follows this value (one tween at a time).
		local roll = Create.new("NumberValue", { Name = "AmountRoll", Value = 0 }) :: NumberValue
		roll.Changed:Connect(function(value: number)
			amountLabel.Text = moneyText(value)
		end)
		local rollTween: Tween? = nil
		-- Rows mode rolls a multiplier (1 -> 2 on DOUBLE IT!) that every row's amount follows.
		local rowRoll = Create.new("NumberValue", { Name = "RowsRoll", Value = 1 }) :: NumberValue
		local rowTween: Tween? = nil

		--[[ Writes every shown row's amount at `factor` x its payout (1 = paid, 2 = doubled). ]]
		local function renderRows(payload: Payload, factor: number)
			for _, entry in payload.worlds do
				local worldRow = worldRows[entry.id]
				if worldRow ~= nil then
					-- Compact rows (two columns) show the bare amount ("$1.2T", "250K"): the icon
					-- beside it already says which currency.
					local value = entry.amount * factor
					worldRow.amount.Text = if worldRow.compact
						then WorldClientLogic.balanceText(worldRow.currency, value)
						else WorldClientLogic.formatAmount(worldRow.currency, value)
				end
			end
		end
		rowRoll.Changed:Connect(function(value: number)
			local payload = current
			if payload ~= nil then
				renderRows(payload, value)
			end
		end)

		-- Cancels the rows roll-up tween (if any).
		local function stopRowTween()
			local running = rowTween
			if running ~= nil then
				running:Cancel()
				rowTween = nil
			end
		end

		--[[
			Rows mode: lays out `payload`'s rows and shows them at `factor`, rolling up from the
			current factor when `animate` (Reduce Motion snaps).
			Example: showRows(payload, 2, true) -- DOUBLE IT! granted
		]]
		local function showRows(payload: Payload, factor: number, animate: boolean)
			stopRowTween()
			layoutRows(payload)
			if animate and not OfferFx.reducedMotion() and factor > rowRoll.Value then
				local tween = TweenService:Create(rowRoll, ROLL_TWEEN, { Value = factor })
				rowTween = tween
				tween:Play()
			else
				rowRoll.Value = factor
				renderRows(payload, factor)
			end
		end

		-- Shows `amount`, rolling up from the current value when `animate` (Reduce Motion snaps).
		local function showAmount(amount: number, animate: boolean)
			local running = rollTween
			if running ~= nil then
				running:Cancel()
				rollTween = nil
			end
			if animate and not OfferFx.reducedMotion() and amount > roll.Value then
				local tween = TweenService:Create(roll, ROLL_TWEEN, { Value = amount })
				rollTween = tween
				tween:Play()
			else
				roll.Value = amount
				amountLabel.Text = moneyText(amount)
			end
		end

		-- DOUBLE IT! look: buyable, SOON (unpublished), or DOUBLED! (claimed).
		local function renderDouble()
			if doubled then
				double.setState("claimed", "DOUBLED!")
				sidePrice.Visible = false
				x2.Visible = false
				return
			end
			x2.Visible = true
			local available = MonetizationConfig.isProductAvailable(PRODUCT_KEY, Workspace:GetServerTimeNow())
			if available then
				double.setState("normal")
			else
				double.setState("locked", "SOON")
			end
			sidePrice.Visible = not available
		end

		--[[
			R78: shows / hides the Comeback Rush banner and switches the rush-only button row
			(one centred LET'S GO!) vs the payout row (OKAY + DOUBLE IT!). With the banner the line
			and well shrink (BANNER_*), so the buttons keep their full size inside the window.
			@param comeback the shown comeback (nil = none)
			@param rushOnly true when there is no offline payout to show
		]]
		local function applyComeback(comeback: SocialClient.Comeback?, rushOnly: boolean)
			local on = comeback ~= nil
			banner.Visible = on
			line.Size = UDim2.new(1, -20, 0, if on then BANNER_LINE_HEIGHT else LINE_HEIGHT)
			local wellHeight = if on then BANNER_WELL_HEIGHT else WELL_HEIGHT
			well.Size = UDim2.new(1, -60, 0, wellHeight)
			rowsMaxHeight = wellHeight - 16
			bodyList.Padding = UDim.new(0, if on then BANNER_PADDING else BODY_PADDING)
			if comeback ~= nil then
				bannerLabel.Text = string.format(
					SocialConfig.Text.ComebackBanner,
					SocialConfig.times(comeback.multiplier),
					math.max(1, math.floor(comeback.seconds / 60 + 0.5))
				)
			end
			double.instance.Visible = not rushOnly
			if rushOnly then
				x2.Visible = false
				sidePrice.Visible = false
				okay.setText(SocialConfig.Text.ComebackGo)
				okay.setColor("green")
				okay.instance.AnchorPoint = Vector2.new(0.5, 0)
				okay.instance.Position = UDim2.new(0.5, 0, 0, X2_HEIGHT - 4)
			else
				okay.setText("OKAY")
				okay.setColor("grey")
				okay.instance.AnchorPoint = Vector2.new(1, 0)
				okay.instance.Position = UDim2.new(0.5, -BUTTON_GAP / 2, 0, X2_HEIGHT - 4)
			end
		end

		-- Server payouts open the window (validated; the queue holds events sent before this
		-- listener connected, so connecting one frame late loses nothing).
		task.defer(function()
			local ok, remote = pcall(function(): RemoteEvent
				return Remotes.event("OfflineEarnings")
			end)
			if not ok then
				warn(`[WelcomeBack] OfflineEarnings remote missing: {remote}`)
				return
			end
			remote.OnClientEvent:Connect(function(value: unknown)
				local payload = readPayload(value)
				if payload == nil then
					return
				end
				-- Already showing: refresh in place. Otherwise wait in the join queue (R78 §6):
				-- after the loading screen and the plot reveal, first in line (latest payload wins).
				if ScreenManager.isOpen(NAME) then
					ScreenManager.open(NAME, payload)
					return
				end
				queuedPayload = payload
				JoinFlow.request(NAME, FtueConfig.Join.Priority.WelcomeBack, function()
					ScreenManager.open(NAME, payload)
				end)
			end)
		end)

		-- R78 Comeback Rush: refresh in place when open; otherwise queue (with any queued payout).
		SocialClient.ComebackArrived:Connect(function(_comeback: SocialClient.Comeback)
			if isOpen then
				ScreenManager.open(NAME, nil)
				return
			end
			JoinFlow.request(NAME, FtueConfig.Join.Priority.WelcomeBack, function()
				ScreenManager.open(NAME, queuedPayload or { comeback = true })
			end)
		end)

		-- A durable DoubleOffline grant while open: show the doubled payout, then close.
		ClientState.PurchaseGranted:Connect(function(grant: ClientState.GrantPayload)
			if grant.kind ~= PRODUCT_KEY and grant.key ~= PRODUCT_KEY then
				return
			end
			local payload = current
			if not isOpen or doubled or payload == nil then
				return
			end
			doubled = true
			-- Every pending row doubles once (spec §6.6); Nuke Town-only keeps the big number.
			if usesRows(payload) then
				showRows(payload, 2, true)
			else
				showAmount(payload.amount * 2, true)
			end
			renderDouble()
			local token = openToken
			task.delay(CLOSE_AFTER_DOUBLE, function()
				if token == openToken and isOpen then
					ScreenManager.close(NAME)
				end
			end)
		end)

		return {
			onOpen = function(args: any?)
				local payload = readPayload(args) or current
				-- R78: a fresh Comeback Rush joins this window and stays while it is open.
				local comeback = SocialClient.takeComeback() or comebackShown
				if payload == nil and comeback == nil then
					-- Opened by name without a payout to show: nothing to welcome back.
					task.defer(ScreenManager.close, NAME)
					return
				end
				if payload ~= nil and payload == queuedPayload then
					queuedPayload = nil -- shown: the comeback request no longer needs to carry it
				end
				local fresh = not isOpen
				local changed = payload ~= current
				isOpen = true
				openToken += 1
				comebackShown = comeback
				applyComeback(comeback, payload == nil)
				if payload == nil and comeback ~= nil then
					-- R78 rush-only: nothing was automated while away, so no payout — just the rush.
					current = nil
					doubled = false
					line.Text = string.format(SocialConfig.Text.ComebackAway, NumberFormat.duration(comeback.away))
					rowsFrame.Visible = false
					amountLabel.Visible = true
					local running = rollTween
					if running ~= nil then
						running:Cancel()
						rollTween = nil
					end
					amountLabel.Text =
						string.format(SocialConfig.Text.ComebackCash, SocialConfig.times(comeback.multiplier))
					if fresh then
						ClientAnalytics.screenOpened("Welcome", "auto")
					end
					return
				end
				if payload == nil then
					return -- (unreachable: payload or comeback is set; keeps the type checker sure)
				end
				if changed then
					current = payload
					doubled = false
				end
				line.Text = `You were offline for {NumberFormat.duration(payload.seconds)} and earned...`
				-- Nuke Town only: the pre-R57 big number. Another world paid: one row per world.
				local rows = usesRows(payload)
				amountLabel.Visible = not rows
				rowsFrame.Visible = rows
				if rows then
					showRows(payload, if doubled then 2 else 1, false)
				else
					okay.instance.NextSelectionUp = nil :: any
					double.instance.NextSelectionUp = nil :: any
					showAmount(if doubled then payload.amount * 2 else payload.amount, false)
				end
				renderDouble()
				if fresh then
					ClientAnalytics.screenOpened("Welcome", "auto")
					if
						not doubled and MonetizationConfig.isProductAvailable(PRODUCT_KEY, Workspace:GetServerTimeNow())
					then
						ClientAnalytics.offerSeen(PRODUCT_KEY, OFFER_SOURCE, true)
					end
				end
			end,
			onClose = function()
				isOpen = false
				openToken += 1
				-- The payout has been seen; a later open by name has nothing stale to show.
				current = nil
				doubled = false
				comebackShown = nil
				queuedPayload = nil
				local running = rollTween
				if running ~= nil then
					running:Cancel()
					rollTween = nil
				end
				stopRowTween()
			end,
			defaultSelection = function(): GuiObject?
				-- The safe choice first (a gamepad A press never starts a purchase by accident);
				-- PurchaseGuard.safeDefault keeps it that way if the layout ever changes (R122).
				return PurchaseGuard.safeDefault({ okay.instance })
			end,
		}
	end,
})
