--!strict
--[[
	WhatsNew — the WHAT'S NEW panel (owner R58; the RoBeasts change-notes system ported onto the
	SellNukes stud kit): every VISIBLE change note from Shared/Config/ChangeNotesConfig, NEWEST
	FIRST, in a scrolling purple-header stud window.

	Opened by:
		- the returning-player auto pop-up      ScreenManager.open("WhatsNew", { source = "auto" })
		  (ChangeNotes/ChangeNotesClient: once per join, at a polite moment)
		- the HUD's bottom-right chip / Settings ScreenManager.open("WhatsNew", { source = "menu" })
		  (no args = "menu")
		- the owner admin preview               ScreenManager.open("WhatsNew", { source = "preview" })
		  (ChangeNotesAdmin: every note incl. ones still hidden by ShowFrom, labelled SOON; nothing
		  is marked seen or counted)

	One stud card per note:
		(hero) TITLE                                          [ v0.3.0 ]   ← version pill
		(    ) Oct 31, 2026                                   [  NEW!  ]   ← unseen at open
		Tagline, wrapped
		[NEW]  or  SECTION HEADING                ← a heading named after a tag draws as its pill
		[icon] item text, wrapped                 [IMPROVED]  ← item pill only when its tag differs
		[ CTA BUTTON ]                            ← optional deep link (Shop section, Pets, ...)
	Hero: a big kit icon on a coloured disc, a live 3D pet (Pets/PetViewport), or an uploaded image.
	Tag pill colours: NEW green, IMPROVED blue, FIXED orange, LIMITED red.

	Seen + analytics (ChangeNotesClient → server ChangeNotesService): opening reports "shown"
	(source auto / menu) for the newest visible note; closing — red X, B, Back, Esc, or the CTA —
	marks that note seen (forward only) and reports "closed" with the seconds the panel was open; a
	CTA press reports "cta". A preview reports nothing.

	Layout: cards are sized in exact design px (StudUI stud surfaces must not use AutomaticSize),
	so each wrapped text block is measured with TextService when the notes are built. The body is
	a ScrollingFrame (AutomaticCanvasSize Y).

	Console + mobile (owner R11): a ResponsiveModal — the 1000 x 700 window on desktop / console /
	tablet, a wide 1320 x 500 one on a landscape phone. Every text is lifted to the layout's 14 pt
	minimum on touch and every CTA button to the 44 pt tap. Gamepad: each note's header block, each
	section and each CTA button are selectable, linked top to bottom (GamepadNav.linkList);
	GamepadNav.followScroll keeps the selected block in view; the cursor starts on the newest note
	(never the close X); B closes.

	Performance: built on first open (lazy screen) and rebuilt only when the layout mode / text
	minimum, the visible notes, the preview flag or the seen position (NEW ribbons) changed since
	the last build; nothing runs per frame (a hero pet viewport animates through PetViewport's one
	shared loop, only while visible).

	Security: display only (config text); every report is re-validated by the server.

	Connects to: Kit/StudUI, Screens/DailyRewards/ResponsiveModal, Platform/GamepadNav,
	ChangeNotes/ChangeNotesClient, Pets/PetViewport, Shared/Config/{ChangeNotesConfig,
	VersionConfig, UIStyleConfig, PetConfig}, Shared/Util/ChangeNotesLogic, UI/ScreenManager.

	Example:
		ScreenManager.open("WhatsNew")                          -- from a menu
		ScreenManager.open("WhatsNew", { source = "preview" })  -- admin preview
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local ChangeNotesClient = require(script.Parent.Parent.Parent.ChangeNotes.ChangeNotesClient)
local ChangeNotesConfig = require(ReplicatedStorage.Shared.Config.ChangeNotesConfig)
local ChangeNotesLogic = require(ReplicatedStorage.Shared.Util.ChangeNotesLogic)
local Create = require(script.Parent.Parent.Create)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetViewport = require(script.Parent.Parent.Parent.Pets.PetViewport)
local ResponsiveModal = require(script.Parent.DailyRewards.ResponsiveModal)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local VersionConfig = require(ReplicatedStorage.Shared.Config.VersionConfig)

local NAME = ChangeNotesConfig.Screen

-- Window modes (ResponsiveModal): the reference size first, the phone-friendly wide one second.
local MODES: { ResponsiveModal.Mode } = {
	{ name = "tall", size = Vector2.new(1000, 700) },
	{ name = "wide", size = Vector2.new(1320, 500) },
}

-- ── Geometry (design px) ───────────────────────────────────────────────────────────────────────
-- Room kept right of the cards for the scroll bar.
local SCROLL_RESERVE = 14
-- Inner margin from the card content's left / right edge (on top of StudUI's card padding).
local SIDE = 12
local CARD_GAP = 14
-- The hero disc (icon / pet / image) and the icon inside it.
local HERO = 104
local HERO_ICON = 80
-- Authored text / slot sizes (lifted to the layout's minText on touch).
local TITLE_SIZE = 40
local VERSION_TEXT_SIZE = 24
local VERSION_PILL_WIDTH = 130
local DATE_SIZE = 24
local TAGLINE_SIZE = 28
local SECTION_SIZE = 32
local ITEM_SIZE = 26
local ITEM_ICON = 40
local ITEM_MIN_HEIGHT = 44
local TAG_TEXT_SIZE = 22
local TAG_PILL_WIDTH = 150
local CTA_WIDTH = 420
local CTA_TEXT_SIZE = 30
-- A pill is its text plus this much height, and at least this many text-heights wide.
local PILL_PAD = 14
local PILL_WIDTH_PER_TEXT = 6.2
-- Extra px per measured line (the fat text outline sits outside the glyph box).
local OUTLINE_SLACK = 6

-- Kit icon keys per ChangeNotesConfig icon name, best first (the first the kit can draw wins).
local ICON_KEYS: { [string]: { string } } = {
	nuke = { "Nuke", "Star" },
	cash = { "Cash" },
	gem = { "Gems" },
	star = { "Star" },
	gift = { "GiftBox", "Gift" },
	clock = { "Clock", "Time" },
	pet = { "Pets" },
	egg = { "Egg" },
	rocket = { "Attack" },
	turkey = { "Turkey", "Event" },
	trophy = { "Trophy" },
	check = { "Check" },
}
-- An item without its own icon shows its tag's (or its section heading's) icon.
local TAG_ICONS: { [string]: ChangeNotesConfig.Icon } = {
	NEW = "star",
	IMPROVED = "rocket",
	FIXED = "check",
	LIMITED = "clock",
}

-- Tag pill colour per ChangeNotesConfig tag.
local TAG_COLORS: { [string]: StudUI.ColorName } = {
	NEW = "green",
	IMPROVED = "blue",
	FIXED = "orange",
	LIMITED = "red",
}

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- The section header colour (the yellow preset's light accent reads well on the sky card).
local SECTION_COLOR = UIStyleConfig.Colors.yellow.accent
-- The hero disc's default colour (a note without Hero.Color / a pet rarity).
local HERO_COLOR = UIStyleConfig.Colors.yellow.bottom

-- Sizes for one build (authored sizes lifted to the touch minimum; widths from the layout).
type Metrics = {
	cardWidth: number,
	innerWidth: number, -- usable width inside a card's padded content (minus SIDE margins)
	title: number,
	versionText: number,
	versionPill: Vector2,
	date: number,
	tagline: number,
	section: number,
	item: number,
	tagText: number,
	tagPill: Vector2,
	cta: Vector2,
	ctaText: number,
}

-- What a build shows (rebuild only when any of it changed).
type BuildKey = { mode: string, minText: number, tap: number, preview: boolean, count: number, seen: number }

--[[
	Sizes for `layout`: every text at least `layout.minText` (14 pt on touch), pills grown to
	their text, the CTA at least the 44 pt tap, widths from the window body.
	@param layout the active ResponsiveModal layout
	@return Metrics
]]
local function metricsFor(layout: ResponsiveModal.Layout): Metrics
	local function text(authored: number): number
		return math.max(authored, layout.minText)
	end
	local cardWidth = layout.area.X - SCROLL_RESERVE
	local innerWidth = cardWidth - 2 * UIStyleConfig.Card.Padding - 2 * SIDE
	local versionText = text(VERSION_TEXT_SIZE)
	local tagText = text(TAG_TEXT_SIZE)
	local ctaText = text(CTA_TEXT_SIZE)
	return {
		cardWidth = cardWidth,
		innerWidth = innerWidth,
		title = text(TITLE_SIZE),
		versionText = versionText,
		versionPill = Vector2.new(
			math.max(VERSION_PILL_WIDTH, math.ceil(versionText * PILL_WIDTH_PER_TEXT)),
			versionText + PILL_PAD + 2
		),
		date = text(DATE_SIZE),
		tagline = text(TAGLINE_SIZE),
		section = text(SECTION_SIZE),
		item = text(ITEM_SIZE),
		tagText = tagText,
		tagPill = Vector2.new(math.max(TAG_PILL_WIDTH, math.ceil(tagText * PILL_WIDTH_PER_TEXT)), tagText + PILL_PAD),
		cta = Vector2.new(
			math.min(innerWidth, CTA_WIDTH),
			math.max(UIStyleConfig.Button.DefaultHeight, layout.tap, ctaText + 24)
		),
		ctaText = ctaText,
	}
end

--[[
	Kit icon key for a change-note icon name ("gem" -> "Gems"); unknown names draw a star.
	Example: iconKey("nuke") --> "Nuke" (or "Star" when the kit cannot draw a nuke)
]]
local function iconKey(name: string?): string
	for _, key in (if name ~= nil then ICON_KEYS[name] else nil) or {} do
		if StudUI.hasIcon(key) then
			return key
		end
	end
	return "Star"
end

--[[
	"Oct 31, 2026" for a unix time, in UTC (the note's Id date is its UTC date), built from
	ChangeNotesConfig.utcDateText so the client, the server and Lune agree.
	Example: formatDate(1_793_404_800) --> "Oct 31, 2026"
]]
local function formatDate(unixTime: number): string
	local year, month, day = string.match(ChangeNotesConfig.utcDateText(unixTime), "^(%d+)%-(%d+)%-(%d+)$")
	local monthName = MONTHS[tonumber(month) or 0]
	if year == nil or day == nil or monthName == nil then
		return ""
	end
	return `{monthName} {tonumber(day)}, {year}`
end

--[[
	Height (design px) of `text` wrapped to `width` at `size` (Fredoka One, the kit's body font).
	Example: wrappedHeight("Hello", 26, 700) --> 32
]]
local function wrappedHeight(text: string, size: number, width: number): number
	local bounds = TextService:GetTextSize(text, size, Enum.Font.FredokaOne, Vector2.new(width, 100_000))
	local lines = math.max(1, math.ceil(bounds.Y / size - 0.01))
	return math.ceil(bounds.Y) + lines * OUTLINE_SLACK
end

--[[
	A small stud pill (version / tag / NEW): a tiny StudUI card with centred text.
	@param parent   where it goes
	@param text     the label
	@param color    preset
	@param size     design px
	@param textSize max text size (scaled down only if it cannot fit)
	@param position top-left in its parent
	@return the pill frame
]]
local function pill(
	parent: Instance,
	text: string,
	color: StudUI.ColorName,
	size: Vector2,
	textSize: number,
	position: UDim2
): Frame
	local card = StudUI.card({
		name = `Pill_{text}`,
		color = color,
		size = UDim2.fromOffset(size.X, size.Y),
		position = position,
		parent = parent,
	})
	StudUI.text({
		name = "Label",
		text = text,
		textSize = textSize,
		size = UDim2.fromScale(1, 1),
		scaled = true,
		zIndex = 4,
		parent = card.frame,
	})
	return card.frame
end

--[[
	An invisible, gamepad-selectable block over part of a card, so a controller can step through
	long notes (GamepadNav.followScroll keeps it in view).
	@return the block
]]
local function focusBlock(parent: Instance, top: number, height: number): Frame
	return Create.new("Frame", {
		Name = "Focus",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(-SIDE, top),
		Size = UDim2.new(1, 2 * SIDE, 0, height),
		Selectable = true,
		ZIndex = 1,
		Parent = parent,
	}) :: Frame
end

--[[
	The hero slot: a round coloured disc (outlined) holding the note's art — a kit icon, a live 3D
	pet (PetViewport; returned so a rebuild can destroy it) or an uploaded image.
	@param parent   the card content
	@param hero     the note's Hero
	@param position top-left of the slot
	@return the slot frame, the pet viewport (Kind "Pet" only)
]]
local function heroSlot(parent: Instance, hero: ChangeNotesConfig.Hero, position: UDim2): (Frame, PetViewport.Viewport?)
	local pet = if hero.Kind == "Pet" then PetConfig.get(hero.PetId) else nil
	local rarity = if pet ~= nil then PetConfig.rarity(pet.id) else nil
	local color = hero.Color or (if rarity ~= nil then rarity.color else HERO_COLOR)
	local disc = Create.new("Frame", {
		Name = "Hero",
		Position = position,
		Size = UDim2.fromOffset(HERO, HERO),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = parent,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			Create.new("UIStroke", { Color = UIStyleConfig.Neutral.Edge, Thickness = 4 }),
		},
	}) :: Frame
	local viewport: PetViewport.Viewport? = nil
	if pet ~= nil then
		local view = PetViewport.new({
			name = "HeroPet",
			size = UDim2.fromScale(1.15, 1.15),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
			spin = true,
			zIndex = 4,
			parent = disc,
		})
		view.set("pet", pet.id)
		viewport = view
	elseif hero.Kind == "Image" and hero.Image ~= nil then
		Create.new("ImageLabel", {
			Name = "HeroImage",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(HERO_ICON, HERO_ICON),
			Image = hero.Image,
			ScaleType = Enum.ScaleType.Fit,
			ZIndex = 4,
			Parent = disc,
		})
	else
		local icon = StudUI.icon(iconKey(hero.Icon), HERO_ICON, 4)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Parent = disc
	end
	return disc, viewport
end

-- What one note card needs besides the note (build-wide state).
type NoteContext = {
	m: Metrics,
	unseen: boolean, -- NEW ribbon (newer than the seen position when the panel opened)
	hidden: boolean, -- preview only: still hidden by ShowFrom (SOON ribbon + reveal date)
	blocks: { GuiObject }, -- receives the card's selectable blocks / buttons, top to bottom
	viewports: { PetViewport.Viewport }, -- receives hero pet viewports (destroyed on rebuild)
	onCta: (note: ChangeNotesConfig.Note) -> (),
}

--[[
	Builds one note's card (layout in the module header) at its exact height.
	@param parent the window body
	@param note   the change note
	@param order  LayoutOrder (1 = newest)
	@param ctx    sizes, ribbons and the shared lists
	@return the card frame
]]
local function buildNote(parent: Instance, note: ChangeNotesConfig.Note, order: number, ctx: NoteContext): Frame
	local m = ctx.m
	local card = StudUI.card({
		name = `Note_{note.Id}`,
		color = "sky",
		size = UDim2.fromOffset(m.cardWidth, 100), -- height set once the content is measured
		layoutOrder = order,
		parent = parent,
	})
	-- Content area: the card's padded content frame with an extra side margin.
	local content = Create.new("Frame", {
		Name = "Note",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(SIDE, 0),
		Size = UDim2.new(1, -2 * SIDE, 1, 0),
		ZIndex = 3,
		Parent = card.content,
	}) :: Frame

	-- Header: hero disc left; title + version pill, then date + NEW / SOON ribbon beside it.
	local y = 8
	local textX = HERO + 14
	local titleRow = math.max(m.title + 8, m.versionPill.Y)
	local dateRow = math.max(m.date + 6, m.tagPill.Y)
	local headerHeight = math.max(HERO, titleRow + 6 + dateRow)
	local _, viewport = heroSlot(content, note.Hero, UDim2.fromOffset(0, y + (headerHeight - HERO) // 2))
	if viewport ~= nil then
		table.insert(ctx.viewports, viewport)
	end
	local textTop = y + (headerHeight - (titleRow + 6 + dateRow)) // 2
	StudUI.text({
		name = "Title",
		text = note.Title,
		textSize = m.title,
		scaled = true,
		align = Enum.TextXAlignment.Left,
		position = UDim2.fromOffset(textX, textTop + (titleRow - (m.title + 8)) // 2),
		size = UDim2.fromOffset(m.innerWidth - textX - m.versionPill.X - 12, m.title + 8),
		zIndex = 4,
		parent = content,
	})
	pill(
		content,
		VersionConfig.label(note.Version),
		"purple",
		m.versionPill,
		m.versionText,
		UDim2.fromOffset(m.innerWidth - m.versionPill.X, textTop + (titleRow - m.versionPill.Y) // 2)
	)
	local dateTop = textTop + titleRow + 6
	local showFrom = note.ShowFrom
	local dateText = if ctx.hidden and showFrom ~= nil
		then `Shows {formatDate(showFrom)} (preview)`
		else formatDate(note.Date)
	StudUI.text({
		name = "Date",
		text = dateText,
		textSize = m.date,
		scaled = true,
		color = UIStyleConfig.Neutral.TextDim,
		align = Enum.TextXAlignment.Left,
		position = UDim2.fromOffset(textX, dateTop + (dateRow - (m.date + 6)) // 2),
		size = UDim2.fromOffset(m.innerWidth - textX - m.tagPill.X - 12, m.date + 6),
		zIndex = 4,
		parent = content,
	})
	if ctx.hidden or ctx.unseen then
		local ribbon = pill(
			content,
			if ctx.hidden then "SOON" else "NEW!",
			if ctx.hidden then "grey" else "red",
			m.tagPill,
			m.tagText,
			UDim2.fromOffset(m.innerWidth - m.tagPill.X, dateTop + (dateRow - m.tagPill.Y) // 2)
		)
		ribbon.Name = "Ribbon"
	end
	y += headerHeight + 10

	-- Tagline (full width).
	local taglineHeight = wrappedHeight(note.Tagline, m.tagline, m.innerWidth)
	StudUI.text({
		name = "Tagline",
		text = note.Tagline,
		textSize = m.tagline,
		wrap = true,
		align = Enum.TextXAlignment.Left,
		alignY = Enum.TextYAlignment.Top,
		position = UDim2.fromOffset(0, y),
		size = UDim2.fromOffset(m.innerWidth, taglineHeight),
		zIndex = 4,
		parent = content,
	})
	y += taglineHeight + 12
	table.insert(ctx.blocks, focusBlock(content, 0, y))

	-- Sections: heading (a tag name draws as its coloured pill), then one row per item.
	local itemTextX = ITEM_ICON + 12
	for sectionIndex, section in note.Sections do
		local sectionTop = y
		local headingTag = if ChangeNotesConfig.TagSet[section.Heading] then section.Heading else nil
		if headingTag ~= nil then
			local headingPill = pill(
				content,
				headingTag,
				TAG_COLORS[headingTag] or "grey",
				m.tagPill,
				m.tagText,
				UDim2.fromOffset(0, y)
			)
			headingPill.Name = `Section{sectionIndex}`
			y += m.tagPill.Y + 10
		else
			StudUI.text({
				name = `Section{sectionIndex}`,
				text = section.Heading,
				textSize = m.section,
				color = SECTION_COLOR,
				align = Enum.TextXAlignment.Left,
				position = UDim2.fromOffset(0, y),
				size = UDim2.fromOffset(m.innerWidth, m.section + 8),
				zIndex = 4,
				parent = content,
			})
			y += m.section + 12
		end
		for _, item in section.Items do
			-- An item pill only when its tag differs from a tag-named heading (RoBeasts rule).
			local itemTag = if item.Tag ~= nil and item.Tag ~= headingTag then item.Tag else nil
			local textWidth = m.innerWidth - itemTextX - (if itemTag ~= nil then m.tagPill.X + 12 else 0)
			local textHeight = wrappedHeight(item.Text, m.item, textWidth)
			local rowHeight = math.max(ITEM_MIN_HEIGHT, textHeight + 8, if itemTag ~= nil then m.tagPill.Y + 8 else 0)
			local iconName: string? = item.Icon or TAG_ICONS[item.Tag or headingTag or ""]
			local itemIcon = StudUI.icon(iconKey(iconName), ITEM_ICON, 4)
			itemIcon.AnchorPoint = Vector2.new(0, 0.5)
			itemIcon.Position = UDim2.fromOffset(0, y + rowHeight // 2)
			itemIcon.Parent = content
			StudUI.text({
				name = "Item",
				text = item.Text,
				textSize = m.item,
				wrap = true,
				align = Enum.TextXAlignment.Left,
				position = UDim2.fromOffset(itemTextX, y + (rowHeight - textHeight) // 2),
				size = UDim2.fromOffset(textWidth, textHeight),
				zIndex = 4,
				parent = content,
			})
			if itemTag ~= nil then
				pill(
					content,
					itemTag,
					TAG_COLORS[itemTag] or "grey",
					m.tagPill,
					m.tagText,
					UDim2.fromOffset(m.innerWidth - m.tagPill.X, y + (rowHeight - m.tagPill.Y) // 2)
				)
			end
			y += rowHeight + 6
		end
		table.insert(ctx.blocks, focusBlock(content, sectionTop, y - sectionTop))
		y += 6
	end

	-- Optional call to action (a stud button: selectable, ≥ 44 pt on touch).
	local cta = note.Cta
	if cta ~= nil and not ctx.hidden then
		y += 4
		local button = StudUI.button({
			name = "Cta",
			text = cta.Label,
			color = "green",
			textSize = m.ctaText,
			size = UDim2.fromOffset(m.cta.X, m.cta.Y),
			position = UDim2.fromOffset(0, y),
			parent = content,
			onActivated = function()
				ctx.onCta(note)
			end,
		})
		button.instance.ZIndex = 5
		table.insert(ctx.blocks, button.instance)
		-- The button's dark lip hangs below its face.
		y += m.cta.Y + UIStyleConfig.Button.Lip + 10
	end

	-- The card's padded content frame is the card minus its padding on both sides.
	card.frame.Size = UDim2.fromOffset(m.cardWidth, y + 2 * UIStyleConfig.Card.Padding)
	return card.frame
end

return ResponsiveModal.screen({
	name = NAME,
	title = "What's New",
	color = "purple",
	icon = "Star",
	modes = MODES,
	scroll = true,
	build = function(
		window: StudUI.Window,
		_gui: ScreenGui,
		layout: ResponsiveModal.Controller
	): ScreenManager.ScreenHandle?
		local body = window.body
		Create.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, CARD_GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = body,
		})
		if body:IsA("ScrollingFrame") then
			-- The gamepad cursor's block stays in view (padded, eased; instant with Reduce Motion).
			GamepadNav.followScroll(body)
		end

		local built: { GuiObject } = {}
		local blocks: { GuiObject } = {}
		local viewports: { PetViewport.Viewport } = {}
		local builtFor: BuildKey? = nil
		-- This opening: how it was opened, when, and the newest note it showed (seen on close).
		local isOpen = false
		local source: ChangeNotesClient.OpenSource = "menu"
		local openedAt = 0
		local shownId: string? = nil
		-- The seen position frozen at open (NEW ribbons do not vanish while the panel is up).
		local seenAtOpen = 0

		-- A CTA press: report it, close (which marks the note seen), then open its screen.
		local function onCta(note: ChangeNotesConfig.Note)
			local cta = note.Cta
			if cta == nil or not isOpen then
				return
			end
			if source ~= "preview" then
				ChangeNotesClient.report("cta", note.Id, nil)
			end
			ScreenManager.close(NAME)
			if cta.Screen == "Shop" then
				ScreenManager.open("Shop", { section = cta.Tab, source = "popup" })
			elseif ScreenManager.isRegistered(cta.Screen) then
				ScreenManager.open(cta.Screen)
			end
		end

		-- What the panel should show now for `current`.
		local function keyFor(current: ResponsiveModal.Layout): BuildKey
			local preview = source == "preview"
			return {
				mode = current.mode,
				minText = current.minText,
				tap = current.tap,
				preview = preview,
				count = if preview then #ChangeNotesConfig.Notes else ChangeNotesClient.visibleCount(),
				seen = seenAtOpen,
			}
		end

		-- (Re)builds every note card (newest first) and links the selectable blocks.
		local function buildAll(key: BuildKey, current: ResponsiveModal.Layout)
			for _, view in viewports do
				view.Destroy()
			end
			table.clear(viewports)
			for _, frame in built do
				frame:Destroy()
			end
			table.clear(built)
			table.clear(blocks)
			builtFor = key
			local visible = ChangeNotesClient.visibleCount()
			local ctx: NoteContext = {
				m = metricsFor(current),
				unseen = false,
				hidden = false,
				blocks = blocks,
				viewports = viewports,
				onCta = onCta,
			}
			local notes = ChangeNotesConfig.Notes
			local order = 0
			-- Newest first: walk the append-only list backwards (preview: hidden notes too).
			for index = key.count, 1, -1 do
				order += 1
				ctx.hidden = index > visible
				ctx.unseen = not ctx.hidden and index > key.seen
				table.insert(built, buildNote(body, notes[index], order, ctx))
			end
			if order == 0 then
				local size = math.max(36, current.minText)
				table.insert(
					built,
					StudUI.text({
						name = "Empty",
						text = "No news yet. Check back soon!",
						textSize = size,
						size = UDim2.new(1, 0, 0, size + 24),
						parent = body,
					})
				)
			end
			GamepadNav.linkList(blocks, true)
		end

		-- Rebuilds when anything the cards show differs from the last build.
		local function refresh(current: ResponsiveModal.Layout)
			local key = keyFor(current)
			local previous = builtFor
			if
				previous == nil
				or previous.mode ~= key.mode
				or previous.minText ~= key.minText
				or previous.tap ~= key.tap
				or previous.preview ~= key.preview
				or previous.count ~= key.count
				or previous.seen ~= key.seen
			then
				buildAll(key, current)
			end
		end

		-- Rotation / device switch while open (or between opens) re-lays the cards out.
		layout.onChanged(function(current: ResponsiveModal.Layout)
			if builtFor ~= nil then
				refresh(current)
			end
		end)

		return {
			onOpen = function(args: any?)
				local requested = if type(args) == "table" then args.source else nil
				local nextSource: ChangeNotesClient.OpenSource = if requested == "auto"
					then "auto"
					elseif requested == "preview" then "preview"
					else "menu"
				if isOpen then
					-- Re-opened in place (an admin preview over the open panel): only re-render.
					if nextSource == "preview" then
						source = "preview"
						refresh(layout.current())
					end
					return
				end
				isOpen = true
				source = nextSource
				openedAt = os.clock()
				seenAtOpen = ChangeNotesLogic.seenIndex(ChangeNotesClient.seen())
				if source == "menu" and ChangeNotesClient.autoState() == "waiting" then
					-- Opened by hand while the auto pop-up still waited: that counts as its showing.
					ChangeNotesClient.setAutoState("done")
				end
				refresh(layout.current())
				-- Always start at the newest note.
				if body:IsA("ScrollingFrame") then
					body.CanvasPosition = Vector2.zero
				end
				local count = ChangeNotesClient.visibleCount()
				shownId = if count > 0 then ChangeNotesConfig.Notes[count].Id else nil
				local id = shownId
				if source ~= "preview" and id ~= nil then
					ChangeNotesClient.report("shown", id, if source == "auto" then "auto" else "menu")
				end
			end,
			onClose = function()
				if not isOpen then
					return
				end
				isOpen = false
				local id = shownId
				if source ~= "preview" and id ~= nil then
					ChangeNotesClient.markSeen(id)
					ChangeNotesClient.report("closed", id, os.clock() - openedAt)
				end
				if source == "auto" then
					ChangeNotesClient.setAutoState("done")
				end
				-- Hero pets stop animating while closed (PetViewport skips disabled ScreenGuis).
			end,
			-- Gamepad starts on the newest note's header block (never the close X).
			defaultSelection = function(): GuiObject?
				return GamepadNav.defaultSelection(body, blocks[1])()
			end,
		}
	end,
})
