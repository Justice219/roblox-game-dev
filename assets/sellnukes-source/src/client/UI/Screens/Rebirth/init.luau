--!strict
--[[
	Rebirth — the per-world rebirth preview + rebirth shops (spec §2.5, RebirthConfig; owner R57
	World 2 spec §6.4 Dino rebirth + Amber shop, §6.5 link lines, §14; plan §3.5).

	Layout (one scrolling stud window):
		World tabs  Worlds/WorldTabBar (NUKE TOWN | DINO VALLEY ...; LB / RB cycle). The window
		            opens on the tab of the world the player is in (WorldClient.current()).
		OPEN tab    that world's rebirth pane (built once per WorldsConfig.Order world):
		  Card:     "Rebirth #N" (non-main: "Dino Rebirth #N") · "<Currency> bonus xA -> xB" ·
		            "+T <Tokens>" (Rebirth Tokens / Amber) · non-main worlds: the requirement line
		            (the finale pad, e.g. the Golden T-Rex Statue, built or not) · what resets /
		            what stays, and the REBIRTH button (two presses: REBIRTH -> "SURE?" within
		            4 s -> Rebirth intent). Locked ("FINISH AREA 10" / "FINISH AREA 6") until the
		            finale is owned: TycoonLogic.forWorld(id).canRebirth on the synced tycoon, or
		            (non-main) the server's Player attribute FeatureRebirth_<id>.
		  Links:    the cross-world link lines (WorldClientLogic.linkLines, spec §6.5), e.g.
		            "Dino Bonus: +30% Nuke Town cash (3 Dino rebirths)" and
		            "Nuke Town Bonus: +25% Bones", shown on BOTH tabs once that world is unlocked
		            (a player who has never seen Dino Valley gets no "+0% Dino" teaser line).
		  Shop:     one row per def.rebirth.ShopOrder upgrade: name, blurb, level / max (non-main
		            worlds also the effect "now -> next"), and a BUY button with its token price
		            (MAX when complete; dimmed when unaffordable) -> RebirthShopBuy(key[, worldId]).
		LOCKED tab  lock art (the world icon + Lock badge), the world name + tagline, the
		            WorldClientLogic.lockHint text ("Reach BoomDash Delivery to unlock!") and the
		            progress bar of the area before the unlock area ("6 / 9 purchases").
		CLOSED tab  (admin kill switch) the world icon + Clock badge and WorldClientConfig.ClosedText.
		Locked / closed tabs send nothing.
		The Nuke Town tab is the pre-R57 screen unchanged (same texts, numbers and intents with no
		worldId argument) plus the link lines.

	Data: every number comes from the shared TycoonLogic.forWorld(id) / WorldsConfig maths on the
	server-synced profile (main = top-level rebirths / rebirthTokens / rebirthShop / tycoon; other
	worlds = ClientState.world(id) with the same field names). The server re-validates every intent
	and does the reset itself.

	Console + mobile (owner R11, spec §14): LB / RB cycle the tabs (WorldTabBar cycler, enabled
	only while open); D-pad Down from any tab enters the shown pane (REBIRTH, then the BUY column),
	Up from REBIRTH returns to the selected tab. The gamepad cursor starts on the first actionable
	button of the visible tab (REBIRTH when ready, else the first affordable BUY, else the first
	BUY; the selected tab button on a locked / closed tab) and follows the scroll
	(GamepadNav.followScroll). Switching tabs with LB / RB moves the cursor to the new tab's
	default (or along the tab row when it was on a tab). B / Back closes (ScreenManager). Taps
	>= 72 design px tall, text >= 24 design px (>= 44 pt / >= 14 pt on a phone).

	Performance: built once (lazy). While open it re-renders only the shown pane, coalesced to
	one render per frame, on events: ClientState.ProfileChanged (only when a watched field
	changed — a cash tick never re-renders), WorldClient.StateChanged (unlock / kill switch /
	world change), the FeatureRebirth_<id> attributes and ScreenManager.LayoutChanged (phone tab
	labels). Everything disconnects on close.

	Security: display + intents only. The client sends Rebirth([worldId]) and
	RebirthShopBuy(key[, worldId]); never an amount. The server validates the world id, the
	shop key against THAT world's shop, the finale, the price and the saving session.

	Connects to: Kit/StudUI, UI/{Create, ScreenManager}, Widgets/StudWindow, Platform/GamepadNav,
	Client/ClientState, Worlds/{WorldClient, WorldClientLogic, WorldTabBar},
	Shared/Tycoon/TycoonLogic, Shared/Config/{UIStyleConfig, WorldClientConfig,
	Worlds/WorldsConfig (def.rebirth = RebirthConfig / Worlds/Dino/DinoRebirth)},
	Shared/Util/NumberFormat, Shared/Net/Remotes (Rebirth, RebirthShopBuy). Server side:
	RebirthService (applyRebirth(profile, worldId)), TycoonService (FeatureRebirth_<id>).

	Example: ScreenManager.open("Rebirth") -- opens on WorldClient.current()'s tab
	         ScreenManager.open("Rebirth", { world = "dino" }) -- an explicit tab (like Teleport)
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Create)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldClient = require(script.Parent.Parent.Parent.Worlds.WorldClient)
local WorldClientConfig = require(ReplicatedStorage.Shared.Config.WorldClientConfig)
local WorldClientLogic = require(script.Parent.Parent.Parent.Worlds.WorldClientLogic)
local WorldTabBar = require(script.Parent.Parent.Parent.Worlds.WorldTabBar)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local NAME = "Rebirth"
local MAIN = WorldsConfig.MAIN
local CONFIRM_SECONDS = 4
local localPlayer = Players.LocalPlayer

-- Profile fields whose change can alter anything this screen shows (cash ticks are ignored).
local WATCHED_FIELDS = table.freeze({ "rebirths", "rebirthTokens", "rebirthShop", "tycoon", "worlds" })
-- Player attribute the server sets per non-main world while its finale is owned
-- (TycoonService: `Feature{feature}_{worldId}`, e.g. FeatureRebirth_dino).
local FEATURE_ATTR_PREFIX = "FeatureRebirth_"
-- Preview card colour per world (purple = the pre-R57 Nuke Town card); other worlds fall back to
-- their tab colour (WorldClientConfig.Tabs) so a World 3 needs no change here.
local CARD_COLORS: { [string]: StudUI.ColorName } = table.freeze({ main = "purple", dino = "teal" }) :: any

-- Geometry (design px).
local CARD_HEIGHT = 270 -- Nuke Town card (unchanged)
local WORLD_CARD_HEIGHT = 320 -- other worlds: one more line (the requirement)
local SHOP_ROW_HEIGHT = 100
local BUY_SIZE = Vector2.new(280, 72) -- >= 44 pt on a phone
local MIDDLE_COLUMN = 0.46 -- non-main shop rows: level / effect column start (row width scale)
local LINK_LINE_HEIGHT = 72 -- fits two wrapped lines at MIN_TEXT (24) on phones
local LINK_TEXT_SIZE = 28 -- link line text (two wrapped lines fit LINK_LINE_HEIGHT)
local LINK_ICON_SIZE = 40
local INFO_CARD_HEIGHT = 470
local ART_SIZE = 150
local ART_BADGE_SIZE = 64
local PROGRESS_SIZE = Vector2.new(560, 34)
local MIN_TEXT = 24 -- readability floor for scaled labels (>= 14 pt on a phone)

-- One rebirth-shop row's live parts.
type ShopRow = { key: string, level: TextLabel, effect: TextLabel?, buy: StudUI.Button }

-- One world's rebirth track as the synced profile reports it (finite, defaulted).
type Track = { rebirths: number, shop: { [string]: any }, tycoon: any?, tokens: number }

-- The link-lines well inside a pane.
type LinkPanel = { frame: Frame, render: () -> () }

-- One world's rebirth pane (preview card + link lines + shop).
type Pane = {
	frame: Frame,
	render: () -> (),
	-- Drops a pending "SURE?" confirmation (open / tab switch).
	reset: () -> (),
	-- The topmost focusable (gamepad Down from the tab row lands here).
	first: () -> GuiObject,
	-- The first actionable button (screen default selection).
	defaultTarget: () -> GuiObject,
}

-- The shared locked / closed pane (one card, re-filled per world).
type InfoPane = { frame: Frame, show: (worldId: string, state: WorldClientLogic.TabState) -> () }

--[[
	A finite number from an untyped profile field.
	@param value   anything (server snapshot field)
	@param default returned for non-numbers, NaN and +-inf
	Example: num(profile.rebirths, 0) --> 3
]]
local function num(value: unknown, default: number): number
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return default
end

--[[
	"x2.5" style multiplier text (one decimal, trailing ".0" dropped).
	Example: multiplierText(2) --> "x2" ; multiplierText(1.55) --> "x1.6"
]]
local function multiplierText(value: number): string
	local text = string.format("%.1f", value)
	return "x" .. (string.gsub(text, "%.0$", ""))
end

--[[
	Readability floor for a scaled label: it never shrinks below `size` design px.
	Example: minText(StudUI.text({ text = "...", scaled = true }), 24)
]]
local function minText(label: TextLabel, size: number)
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if constraint ~= nil then
		constraint.MinTextSize = size
	end
end

--[[
	True when a ProfileChanged push may change this screen.
	@param fields the changed top-level field names (nil = a full snapshot)
	Example: watched({ "cash" }) --> false ; watched({ "worlds" }) --> true ; watched(nil) --> true
]]
local function watched(fields: { string }?): boolean
	if fields == nil then
		return true
	end
	for _, field in WATCHED_FIELDS do
		if table.find(fields, field) ~= nil then
			return true
		end
	end
	return false
end

--[[
	One world's rebirth track from the synced profile: main reads the top-level fields, any other
	world its ClientState.world(id) entry (same field names). A world missing from the snapshot
	reads as a fresh track.
	@param worldId WorldsConfig id
	@return Track, or nil before the first profile snapshot
	Example: trackOf("dino").tokens --> 12 (Amber)
]]
local function trackOf(worldId: string): Track?
	local profile: any = ClientState.profile
	if type(profile) ~= "table" then
		return nil
	end
	local source: any = if worldId == MAIN then profile else ClientState.world(worldId)
	if type(source) ~= "table" then
		source = {}
	end
	return {
		rebirths = num(source.rebirths, 0),
		shop = if type(source.rebirthShop) == "table" then source.rebirthShop else {},
		tycoon = if type(source.tycoon) == "table" then source.tycoon else nil,
		tokens = num(source.rebirthTokens, 0),
	}
end

--[[
	The effect of a rebirth-shop upgrade at `level`, for display: explicit-value upgrades (Bone
	Stash) in the world currency, whole-number per-level upgrades as "+N", the rest as a percent.
	@param logic TycoonLogic.forWorld(def.id)
	@param def   the world
	@param key   shop key (def.rebirth.Shop)
	@param level upgrade level (0 = not bought)
	@return string
	Example: effectText(dinoLogic, dino, "clickPower", 3) --> "+30%"
	         effectText(dinoLogic, dino, "startingCash", 1) --> "65K Bones"
]]
local function effectText(logic: TycoonLogic.Logic, def: WorldsConfig.WorldDef, key: string, level: number): string
	local upgrade = def.rebirth.Shop[key]
	local value = logic.rebirthShopEffect(key, level)
	if upgrade ~= nil and upgrade.values ~= nil then
		return WorldClientLogic.formatAmount(def.currency, value)
	end
	if upgrade ~= nil and upgrade.perLevel ~= nil and upgrade.perLevel >= 1 then
		return `+{NumberFormat.commas(value)}`
	end
	return `+{math.floor(value * 100 + 0.5)}%`
end

--[[
	The link-lines well (spec §6.5): one icon + text line per WorldClientLogic.linkLines entry.
	The line count is fixed (WorldsConfig is static: two lines per linked world), so the lines are
	built once and render() only refreshes text / colour / visibility. A world's pair of lines
	shows once that world is unlocked; the well hides when no line shows.
	@param parent      the pane frame
	@param layoutOrder order in the pane
	@return LinkPanel
	Example: local links = buildLinkPanel(pane, 2); links.render()
]]
local function buildLinkPanel(parent: Instance, layoutOrder: number): LinkPanel
	local frame = Create.new("Frame", {
		Name = "WorldLinks",
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = UIStyleConfig.Neutral.Well,
		LayoutOrder = layoutOrder,
		Visible = false,
		Parent = parent,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }),
			Create.new("UIPadding", {
				PaddingTop = UDim.new(0, 10),
				PaddingBottom = UDim.new(0, 10),
				PaddingLeft = UDim.new(0, 20),
				PaddingRight = UDim.new(0, 20),
			}),
			Create.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
		},
	}) :: Frame
	StudWindow.edge(frame, 4)
	local lines: { { row: Frame, label: TextLabel } } = {}
	-- The model's shape (worlds + order) never changes; zero counts give the line list to build.
	for index, line in WorldClientLogic.linkLines({}) do
		local row = Create.new("Frame", {
			Name = `Link{index}`,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, LINK_LINE_HEIGHT),
			LayoutOrder = index,
			Parent = frame,
		}) :: Frame
		-- The icon of the world whose rebirths pay this bonus.
		local icon = StudUI.icon(WorldClientLogic.style(line.worldId).icon, LINK_ICON_SIZE)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.fromScale(0, 0.5)
		icon.Parent = row
		local label = StudUI.text({
			text = line.text,
			textSize = 30,
			scaled = true,
			align = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(LINK_ICON_SIZE + 12, 0),
			size = UDim2.new(1, -(LINK_ICON_SIZE + 12), 1, 0),
			parent = row,
		})
		-- A fixed readable size that WRAPS onto a second line on narrow (phone) windows instead of
		-- scaling a one-line run past the well's edge (verified in the device matrix).
		label.TextScaled = false
		label.TextSize = LINK_TEXT_SIZE
		label.TextWrapped = true
		table.insert(lines, { row = row, label = label })
	end

	return {
		frame = frame,
		render = function()
			local profile: any = ClientState.profile
			local counts: { [string]: any } = { [MAIN] = if type(profile) == "table" then profile.rebirths else 0 }
			for _, def in WorldsConfig.extra() do
				local world = ClientState.world(def.id)
				counts[def.id] = if world ~= nil then world.rebirths else 0
			end
			local model = WorldClientLogic.linkLines(counts)
			local any = false
			for index, entry in lines do
				local line = model[index]
				-- linkLines returns (toMain, fromMain) pairs per linked world; the pair's first
				-- line carries that world's id.
				local head = model[index - (index - 1) % 2]
				if line ~= nil and head ~= nil and WorldClient.isUnlocked(head.worldId) then
					entry.row.Visible = true
					entry.label.Text = line.text
					-- A bonus still at +0% reads dimmer than a paying one.
					entry.label.TextColor3 = if line.percent > 0
						then UIStyleConfig.Neutral.Text
						else UIStyleConfig.Neutral.TextDim
					any = true
				else
					entry.row.Visible = false
				end
			end
			frame.Visible = any
		end,
	}
end

--[[
	Builds one world's rebirth pane (see the module header). The Nuke Town pane keeps the pre-R57
	texts, geometry and intents (Rebirth() / RebirthShopBuy(key) with no worldId); every other
	world's pane is built from its WorldDef (currency, tokens, rebirth track, finale pad), so a
	World 3 needs no code here.
	@param worldId     WorldsConfig id ("main", "dino", ...)
	@param parent      the window body
	@param layoutOrder order in the body list
	@return Pane
	Example: local dino = buildPane("dino", window.body, 2); dino.frame.Visible = true; dino.render()
]]
local function buildPane(worldId: string, parent: Instance, layoutOrder: number): Pane
	local def = WorldsConfig.get(worldId)
	assert(def ~= nil, `Rebirth: unknown world {worldId}`)
	local isMain = worldId == MAIN
	local logic = TycoonLogic.forWorld(worldId)
	local style = WorldClientLogic.style(worldId)
	local rebirthDef = def.rebirth
	local tokensName = def.tokens.name
	local economy = def.economy
	-- The finale pad (feature "Rebirth") and its area: the rebirth requirement.
	local finalePad = economy.PadsById[economy.FinalePadId]
	local finaleArea = if finalePad ~= nil then finalePad.area else #economy.Areas
	local finaleAreaConfig = economy.Areas[finaleArea]
	local mainDef = WorldsConfig.get(MAIN)
	local mainName = if mainDef ~= nil then mainDef.name else "Nuke Town"

	local frame = Create.new("Frame", {
		Name = `Pane_{worldId}`,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0), -- height follows the content (AutomaticSize Y)
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder,
		Visible = false,
		Parent = parent,
		Children = {
			Create.new("UIListLayout", {
				Padding = UDim.new(0, 14),
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame

	-- Preview card.
	local card = StudUI.card({
		color = CARD_COLORS[worldId] or (style.color :: any),
		sunburst = true,
		size = UDim2.new(1, -8, 0, if isMain then CARD_HEIGHT else WORLD_CARD_HEIGHT),
		layoutOrder = 1,
		parent = frame,
	})
	local heading = StudUI.text({
		text = "Rebirth #1",
		textSize = 56,
		font = "shout",
		size = UDim2.new(1, 0, 0, 64),
		parent = card.content,
	})
	local bonus = StudUI.text({
		text = "",
		textSize = 38,
		position = UDim2.fromOffset(0, 68),
		size = UDim2.new(0.62, 0, 0, 46),
		align = Enum.TextXAlignment.Left,
		color = if isMain then UIStyleConfig.Neutral.CashGreen else def.currency.color,
		parent = card.content,
	})
	local tokens = StudUI.text({
		text = "",
		textSize = 38,
		position = UDim2.fromOffset(0, 116),
		size = UDim2.new(0.62, 0, 0, 46),
		align = Enum.TextXAlignment.Left,
		color = if isMain then UIStyleConfig.Colors.yellow.accent else def.tokens.color,
		parent = card.content,
	})
	-- Non-main worlds: the requirement line (spec §6.4 "own the finale").
	local requirement: TextLabel? = nil
	if not isMain then
		local line = StudUI.text({
			text = "",
			textSize = 28,
			scaled = true,
			position = UDim2.fromOffset(0, 164),
			size = UDim2.new(0.62, 0, 0, 36),
			align = Enum.TextXAlignment.Left,
			parent = card.content,
		})
		minText(line, MIN_TEXT)
		requirement = line
	end
	StudUI.text({
		text = if isMain
			then "Resets cash, levels and pads. Keeps pets, gems, passes and cosmetics."
			else `Resets {def.currency.name}, levels and pads here. Keeps {tokensName}, the {tokensName} Shop, {mainName}, pets and gems.`,
		textSize = 24,
		wrap = true,
		position = UDim2.fromOffset(0, if isMain then 168 else 206),
		size = UDim2.new(0.62, 0, 0, 64),
		align = Enum.TextXAlignment.Left,
		parent = card.content,
	})
	local confirmUntil = 0
	local rebirthButton: StudUI.Button
	rebirthButton = StudUI.button({
		text = "REBIRTH",
		color = "green",
		size = UDim2.fromOffset(330, 92),
		position = UDim2.new(1, -10, 0.5, 20),
		anchor = Vector2.new(1, 0.5),
		parent = card.content,
		onActivated = function()
			local now = os.clock()
			if now > confirmUntil then
				-- First press: ask for confirmation (a rebirth resets the run).
				confirmUntil = now + CONFIRM_SECONDS
				rebirthButton.setText("SURE?")
				rebirthButton.setColor("yellow" :: StudUI.ColorName)
				task.delay(CONFIRM_SECONDS, function()
					if os.clock() >= confirmUntil then
						rebirthButton.setText("REBIRTH")
						rebirthButton.setColor("green" :: StudUI.ColorName)
					end
				end)
				return
			end
			confirmUntil = 0
			-- Intent only. Nuke Town keeps the pre-R57 argument-less call (nil = main).
			if isMain then
				Remotes.event("Rebirth"):FireServer()
			else
				Remotes.event("Rebirth"):FireServer(worldId)
			end
			ScreenManager.close(NAME)
		end,
	})

	-- Cross-world link lines (both tabs).
	local links = buildLinkPanel(frame, 2)

	-- Shop.
	local section = StudUI.sectionLabel(if isMain then "Rebirth Shop" else `{tokensName} Shop`, 44)
	section.LayoutOrder = 3
	section.Parent = frame
	local wallet =
		StudUI.text({ text = "", textSize = 34, size = UDim2.new(1, 0, 0, 40), layoutOrder = 4, parent = frame })
	local rows: { ShopRow } = {}
	-- Left column width (name + blurb): Nuke Town keeps its layout; other worlds make room for the
	-- level / effect column.
	local leftWidth = if isMain then 0.6 else MIDDLE_COLUMN - 0.02
	for order, key in rebirthDef.ShopOrder do
		local upgrade = rebirthDef.Shop[key]
		local row = Create.new("Frame", {
			Name = `Shop_{key}`,
			Size = UDim2.new(1, -8, 0, SHOP_ROW_HEIGHT),
			BackgroundColor3 = UIStyleConfig.Neutral.Well,
			LayoutOrder = 10 + order,
			Parent = frame,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }) },
		}) :: Frame
		StudWindow.edge(row, 4)
		StudUI.text({
			text = upgrade.name,
			textSize = 38,
			align = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(20, 6),
			size = UDim2.new(leftWidth, 0, 0, 46),
			parent = row,
		})
		StudUI.text({
			text = upgrade.blurb,
			textSize = 24,
			color = UIStyleConfig.Neutral.TextDim,
			align = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(20, 54),
			size = UDim2.new(leftWidth, 0, 0, 32),
			parent = row,
		})
		local level: TextLabel
		local effect: TextLabel? = nil
		if isMain then
			level = StudUI.text({
				text = "",
				textSize = 30,
				position = UDim2.new(0.58, 0, 0, 30),
				size = UDim2.fromOffset(150, 40),
				parent = row,
			})
		else
			-- Level on top, the effect "now -> next" under it (spec §14 "level/max, effect").
			local columnWidth = UDim2.new(1 - MIDDLE_COLUMN, -(BUY_SIZE.X + 34), 0, 40)
			level = StudUI.text({
				text = "",
				textSize = 30,
				position = UDim2.new(MIDDLE_COLUMN, 0, 0, 8),
				size = columnWidth,
				parent = row,
			})
			local effectLabel = StudUI.text({
				text = "",
				textSize = 26,
				scaled = true,
				color = UIStyleConfig.Neutral.CashGreen,
				position = UDim2.new(MIDDLE_COLUMN, 0, 0, 52),
				size = UDim2.new(1 - MIDDLE_COLUMN, -(BUY_SIZE.X + 34), 0, 36),
				parent = row,
			})
			minText(effectLabel, MIN_TEXT)
			effect = effectLabel
		end
		local upgradeKey = key
		local buy = StudUI.button({
			text = "",
			color = "yellow",
			size = UDim2.fromOffset(BUY_SIZE.X, BUY_SIZE.Y),
			position = UDim2.new(1, -14, 0.5, -2),
			anchor = Vector2.new(1, 0.5),
			parent = row,
			onActivated = function()
				-- Intent only (the key); the server prices it from THAT world's shop.
				if isMain then
					Remotes.event("RebirthShopBuy"):FireServer(upgradeKey)
				else
					Remotes.event("RebirthShopBuy"):FireServer(upgradeKey, worldId)
				end
			end,
		})
		table.insert(rows, { key = key, level = level, effect = effect, buy = buy })
	end

	-- D-pad: REBIRTH, then the BUY column (Up from REBIRTH -> the tab row, set by the screen).
	local focus: { GuiObject } = { rebirthButton.instance }
	for _, row in rows do
		table.insert(focus, row.buy.instance)
	end
	GamepadNav.linkList(focus, true)

	--[[ Re-renders the whole pane from the current profile (no-op before the first snapshot). ]]
	local function render()
		local track = trackOf(worldId)
		if track == nil then
			return
		end
		local rebirths = track.rebirths
		local shop = track.shop
		local tycoon = track.tycoon
		heading.Text = if isMain then `Rebirth #{rebirths + 1}` else `{style.bonusName} Rebirth #{rebirths + 1}`
		bonus.Text =
			`{def.currency.name} bonus {multiplierText(logic.rebirthMultiplier(rebirths, shop))} -> {multiplierText(
				logic.rebirthMultiplier(rebirths + 1, shop)
			)}`
		local reward = if tycoon ~= nil then logic.rebirthReward(tycoon, rebirths) else 0
		tokens.Text = `+{NumberFormat.commas(reward)} {tokensName}`
		-- Ready: the synced tycoon owns the finale; non-main worlds also accept the server's
		-- FeatureRebirth_<id> attribute (same truth, may land a frame earlier).
		local ready = tycoon ~= nil and logic.canRebirth(tycoon)
		if not ready and not isMain then
			ready = localPlayer:GetAttribute(FEATURE_ATTR_PREFIX .. worldId) == true
		end
		if ready then
			rebirthButton.setState("normal")
		else
			rebirthButton.setState("locked", `FINISH AREA {finaleArea}`)
		end
		local requirementLabel = requirement
		if requirementLabel ~= nil then
			local padName = if finalePad ~= nil then finalePad.name else "finale"
			if ready then
				requirementLabel.Text = `{padName} built: ready to rebirth!`
				requirementLabel.TextColor3 = UIStyleConfig.Neutral.CashGreen
			else
				local areaName = if finaleAreaConfig ~= nil then finaleAreaConfig.name else `Area {finaleArea}`
				requirementLabel.Text = `Needs the {padName} ({areaName})`
				requirementLabel.TextColor3 = UIStyleConfig.Neutral.Text
			end
		end
		local ownedTokens = track.tokens
		wallet.Text = if isMain
			then `Your tokens: {NumberFormat.commas(ownedTokens)}`
			else `Your {tokensName}: {NumberFormat.commas(ownedTokens)}`
		for _, row in rows do
			local upgrade = rebirthDef.Shop[row.key]
			-- Clamp junk levels into 0..max so the label and the price stay sane.
			local current = math.clamp(math.floor(num(shop[row.key], 0)), 0, upgrade.maxLevel)
			local maxed = current >= upgrade.maxLevel
			row.level.Text = `Lv {current} / {upgrade.maxLevel}`
			local effectLabel = row.effect
			if effectLabel ~= nil then
				local now = effectText(logic, def, row.key, current)
				effectLabel.Text = if maxed
					then `{now} (max)`
					else `{now} -> {effectText(logic, def, row.key, current + 1)}`
			end
			if maxed then
				row.buy.setText("MAX")
				row.buy.setState("claimed", "MAX")
			else
				local cost = logic.rebirthShopCost(row.key, current)
				row.buy.setText(
					if isMain then `{NumberFormat.commas(cost)} Tokens` else `{NumberFormat.commas(cost)} {tokensName}`
				)
				row.buy.setState(if ownedTokens >= cost then "normal" else "disabled")
			end
		end
		links.render()
	end

	return {
		frame = frame,
		render = render,
		reset = function()
			confirmUntil = 0
			rebirthButton.setText("REBIRTH")
			rebirthButton.setColor("green" :: StudUI.ColorName)
		end,
		first = function(): GuiObject
			return rebirthButton.instance
		end,
		defaultTarget = function(): GuiObject
			if rebirthButton.state() == "normal" then
				return rebirthButton.instance
			end
			for _, row in rows do
				if row.buy.state() == "normal" then
					return row.buy.instance
				end
			end
			return if #rows > 0 then rows[1].buy.instance else rebirthButton.instance
		end,
	}
end

--[[
	Shows `worldId`'s tab icon inside an art holder: one icon frame per world, built on first use
	and toggled afterwards (no per-render instancing).
	@param art   the holder frame
	@param icons the holder's per-world icon cache
	@param worldId WorldsConfig id
	Example: showArt(lockArt, lockIcons, "dino")
]]
local function showArt(art: Frame, icons: { [string]: Frame }, worldId: string)
	if icons[worldId] == nil then
		local icon = StudUI.icon(WorldClientLogic.style(worldId).icon, ART_SIZE, 4)
		icon.Parent = art
		icons[worldId] = icon
	end
	for id, icon in icons do
		icon.Visible = id == worldId
	end
end

--[[
	The locked / closed pane: one grey stud card re-filled for the selected world.
	  locked: the world icon + Lock badge, name, tagline, WorldClientLogic.lockHint text and the
	          progress bar + "6 / 9 purchases" (hidden when the rule has no progress area).
	  closed: the world icon + Clock badge, name and WorldClientConfig.ClosedText.
	Nothing in it is interactive: it never sends anything.
	@param parent      the window body
	@param layoutOrder order in the body list
	@return InfoPane
	Example: info.show("dino", "locked")
]]
local function buildInfoPane(parent: Instance, layoutOrder: number): InfoPane
	local card = StudUI.card({
		color = "grey",
		size = UDim2.new(1, -8, 0, INFO_CARD_HEIGHT),
		layoutOrder = layoutOrder,
		name = "WorldInfo",
		parent = parent,
	})
	card.frame.Visible = false
	local content = card.content
	Create.new("UIListLayout", {
		Padding = UDim.new(0, 10),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = content,
	})
	local art = Create.new("Frame", {
		Name = "Art",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(ART_SIZE, ART_SIZE),
		LayoutOrder = 1,
		Parent = content,
	}) :: Frame
	-- Corner badges over the world icon: Lock (locked) / Clock (kill switch).
	local function badge(key: string): Frame
		local mark = StudUI.icon(key, ART_BADGE_SIZE, 8)
		mark.AnchorPoint = Vector2.new(0.5, 0.5)
		mark.Position = UDim2.new(1, -14, 1, -14)
		mark.Visible = false
		mark.Parent = art
		return mark
	end
	local lockBadge = badge("Lock")
	local clockBadge = badge("Clock")
	local icons: { [string]: Frame } = {}
	local title = StudUI.text({
		text = "",
		textSize = 52,
		font = "shout",
		size = UDim2.new(1, 0, 0, 60),
		layoutOrder = 2,
		parent = content,
	})
	local tagline = StudUI.text({
		text = "",
		textSize = 26,
		wrap = true,
		color = UIStyleConfig.Neutral.TextDim,
		size = UDim2.new(0.9, 0, 0, 34),
		layoutOrder = 3,
		parent = content,
	})
	local message = StudUI.text({
		text = "",
		textSize = 36,
		wrap = true,
		color = UIStyleConfig.Colors.yellow.accent,
		size = UDim2.new(0.9, 0, 0, 44),
		layoutOrder = 4,
		parent = content,
	})
	local bar = StudUI.progressBar({
		color = "green",
		size = UDim2.fromOffset(PROGRESS_SIZE.X, PROGRESS_SIZE.Y),
		layoutOrder = 5,
		parent = content,
	})
	local progress = StudUI.text({
		text = "",
		textSize = 28,
		size = UDim2.new(1, 0, 0, 34),
		layoutOrder = 6,
		parent = content,
	})

	return {
		frame = card.frame,
		show = function(worldId: string, state: WorldClientLogic.TabState)
			local def = WorldsConfig.get(worldId)
			showArt(art, icons, worldId)
			title.Text = if def ~= nil then def.name else worldId
			tagline.Text = if def ~= nil then def.tagline else ""
			local closed = state == "closed"
			lockBadge.Visible = not closed
			clockBadge.Visible = closed
			if closed then
				message.Text = WorldClientConfig.ClosedText
				bar.frame.Visible = false
				progress.Visible = false
				return
			end
			-- Locked: the hint + the progress of the rule world's area before the unlock area.
			local rule: any = if def ~= nil then def.unlock else nil
			local ruleTrack = if rule ~= nil and rule.kind == "progress" then trackOf(rule.world) else nil
			local hint, _areaName, bought, total =
				WorldClientLogic.lockHint(worldId, if ruleTrack ~= nil then ruleTrack.tycoon else nil)
			message.Text = hint
			local hasProgress = total > 0
			bar.frame.Visible = hasProgress
			progress.Visible = hasProgress
			if hasProgress then
				bar.setProgress(bought / total)
				progress.Text = WorldClientLogic.fill(
					WorldClientConfig.LockedProgress,
					{ bought = tostring(bought), total = tostring(total) }
				)
			end
		end,
	}
end

return StudUI.modalScreen({
	name = NAME,
	title = "Rebirth",
	color = "teal",
	icon = "Rebirth",
	size = Vector2.new(1180, 780),
	scroll = true,
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		local body = window.body
		Create.new("UIListLayout", {
			Padding = UDim.new(0, 14),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = body,
		})

		-- ── State ──────────────────────────────────────────────────────────────────────────
		local selected = MAIN -- the shown tab's world id
		local isOpen = false
		local shown: Pane? = nil -- the shown rebirth pane (nil on a locked / closed tab)
		local tabRowLinked = false
		local renderQueued = false
		local connections: { any } = {}

		-- World tabs (LB / RB cycle while open). Forward-declared: the bar calls back into it.
		local selectTab: (worldId: string) -> ()
		local tabBar = WorldTabBar.new({
			parent = body,
			layoutOrder = 0,
			onSelect = function(worldId: string)
				selectTab(worldId)
			end,
		})
		local panes: { [string]: Pane } = {}
		for index, worldId in WorldsConfig.Order do
			panes[worldId] = buildPane(worldId, body, index)
		end
		local info = buildInfoPane(body, #WorldsConfig.Order + 1)
		if body:IsA("ScrollingFrame") then
			GamepadNav.followScroll(body)
		end

		--[[ The tab model entry of `worldId`, or nil. ]]
		local function tabOf(tabs: { WorldClientLogic.Tab }, worldId: string): WorldClientLogic.Tab?
			for _, tab in tabs do
				if tab.id == worldId then
					return tab
				end
			end
			return nil
		end

		--[[
			Re-renders the tab row and the selected tab's content (only the shown pane renders),
			then rewires the gamepad links: every tab's Down -> the shown pane's top button, that
			button's Up -> the selected tab.
		]]
		local function renderAll()
			local tabs = WorldClient.tabs()
			local tab = tabOf(tabs, selected)
			if tab == nil then
				selected = MAIN
				tab = tabOf(tabs, MAIN)
			end
			local state: WorldClientLogic.TabState = if tab ~= nil then tab.state else "open"
			tabBar.render(tabs, selected)
			local pane = if state == "open" then panes[selected] else nil
			shown = pane
			for _, each in panes do
				each.frame.Visible = each == pane
			end
			if pane ~= nil then
				pane.render()
			end
			info.frame.Visible = pane == nil
			if pane == nil then
				info.show(selected, state)
			end
			local buttons = tabBar.buttons()
			if not tabRowLinked and #buttons > 0 then
				-- The tab row: Left / Right between tabs (built on the first render, never rebuilt).
				GamepadNav.linkList(buttons, false)
				tabRowLinked = true
			end
			-- (NextSelection* accept nil at runtime = engine default; the type defs say GuiObject.)
			local below: GuiObject? = if pane ~= nil then pane.first() else nil
			for _, button in buttons do
				button.NextSelectionDown = below :: any
			end
			if below ~= nil then
				below.NextSelectionUp = tabBar.button(selected) :: any
			end
		end

		--[[
			Coalesces bursts of change signals (a profile push fires ProfileChanged and
			WorldClient.StateChanged together) into one render on the next resumption point.
		]]
		local function queueRender()
			if renderQueued then
				return
			end
			renderQueued = true
			task.defer(function()
				renderQueued = false
				if isOpen then
					renderAll()
				end
			end)
		end

		--[[ The first actionable button of the visible tab (the selected tab when none). ]]
		local function defaultTarget(): GuiObject?
			local pane = shown
			if pane ~= nil then
				return pane.defaultTarget()
			end
			return tabBar.button(selected)
		end

		--[[
			Shows `worldId`'s tab (a tab press or LB / RB). A pending "SURE?" never survives a
			tab switch. Gamepad: a cursor on the tab row follows to the new tab; a cursor in the
			content moves to the new tab's default (the old pane is hidden now).
			Example: selectTab("dino")
		]]
		selectTab = function(worldId: string)
			local target = if WorldsConfig.get(worldId) ~= nil then worldId else MAIN
			local cursor = GuiService.SelectedObject
			local onTabs = cursor ~= nil and cursor:IsDescendantOf(tabBar.frame)
			if target ~= selected then
				for _, pane in panes do
					pane.reset()
				end
				selected = target
			end
			renderAll()
			if isOpen then
				local focus = if onTabs then tabBar.button(target) else defaultTarget()
				if focus ~= nil then
					GamepadNav.select(focus)
				end
			end
		end

		--[[ Connects the while-open event sources (once; onClose disconnects them). ]]
		local function connect()
			if #connections > 0 then
				return
			end
			table.insert(
				connections,
				ClientState.ProfileChanged:Connect(function(_profile: any, fields: { string }?)
					if watched(fields) then
						queueRender()
					end
				end)
			)
			table.insert(connections, WorldClient.StateChanged:Connect(queueRender))
			table.insert(connections, ScreenManager.LayoutChanged:Connect(queueRender))
			for _, def in WorldsConfig.extra() do
				table.insert(
					connections,
					localPlayer:GetAttributeChangedSignal(FEATURE_ATTR_PREFIX .. def.id):Connect(queueRender)
				)
			end
		end

		return {
			onOpen = function(args: any?)
				isOpen = true
				-- Opens on the current world's tab, or an explicit known { world = id } (same
				-- contract as Teleport; a junk id falls back to the current world).
				local requested = if type(args) == "table" then args.world else nil
				selected = if type(requested) == "string" and WorldsConfig.get(requested) ~= nil
					then requested
					else WorldClient.current()
				for _, pane in panes do
					pane.reset()
				end
				renderAll()
				tabBar.enable()
				connect()
			end,
			onClose = function()
				isOpen = false
				tabBar.disable()
				for _, connection in connections do
					connection:Disconnect()
				end
				table.clear(connections)
			end,
			defaultSelection = defaultTarget,
		}
	end,
})
