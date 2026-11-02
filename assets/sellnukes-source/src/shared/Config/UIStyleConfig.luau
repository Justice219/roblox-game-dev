--!strict
--[[
	UIStyleConfig — the SellNukes stud-UI palette and geometry (the "style kit" numbers).

	Purpose:
		Every screen is built with UI/Kit/StudUI, and StudUI reads ALL of its colours and sizes
		from here, so the whole game re-themes from one file. Values were sampled from the owner's
		reference shots (docs/reference/ui-style/*.png):
			- coloured surfaces are a vertical gradient: a lighter (often pinker / yellower) top
			  fading to the deeper base colour at the bottom, covered by the RoBeasts stud tile;
			- every surface has a thick near-black outline; buttons add a darker 3D "lip";
			- window bodies are a dark slate blue-grey; text is white with a fat dark outline.
		Presentation only: nothing here is ever a price, reward or game rule.

	Colour presets (ColorName): green | yellow | red | blue | sky | purple | orange | grey | white
	| teal | cyan | rainbow. `rainbow` is a multi-stop gradient (Day 7 card, Lucky Wheel button).

	Connects to: UI/Kit/StudUI (reads everything), UI/Hud/* (HUD sizes), docs/ui.md (the table
	of presets and when to use each).

	Example:
		local preset = UIStyleConfig.Colors.green
		frame.BackgroundColor3 = preset.bottom
		gradient.Color = ColorSequence.new(preset.top, preset.bottom)
]]

export type ColorName =
	"green"
	| "yellow"
	| "red"
	| "blue"
	| "sky"
	| "purple"
	| "orange"
	| "grey"
	| "white"
	| "teal"
	| "cyan"
	| "rainbow"

-- One colour preset: gradient top / bottom of the face, the darker 3D lip under buttons and a
-- light accent for text that sits on the dark slate body (e.g. a green "+$12/s").
export type Preset = { top: Color3, bottom: Color3, lip: Color3, accent: Color3 }

local function preset(top: Color3, bottom: Color3, lip: Color3, accent: Color3): Preset
	-- Frozen (read-only at runtime); cast because table.freeze yields read-only property types.
	return table.freeze({ top = top, bottom = bottom, lip = lip, accent = accent }) :: any
end

local UIStyleConfig = {}

UIStyleConfig.Colors = table.freeze({
	-- CLAIM / Redeem / buy-with-Robux / confirm.
	green = preset(
		Color3.fromRGB(168, 248, 104),
		Color3.fromRGB(96, 204, 50),
		Color3.fromRGB(52, 128, 30),
		Color3.fromRGB(130, 244, 80)
	),
	-- Shop header, paid spin bundles, highlights.
	yellow = preset(
		Color3.fromRGB(255, 242, 88),
		Color3.fromRGB(244, 160, 48),
		Color3.fromRGB(176, 100, 18),
		Color3.fromRGB(255, 224, 70)
	),
	-- Close X, Daily header, Starter Pack card, danger.
	red = preset(
		Color3.fromRGB(238, 66, 124),
		Color3.fromRGB(230, 48, 56),
		Color3.fromRGB(140, 22, 38),
		Color3.fromRGB(255, 96, 110)
	),
	-- Codes header, info.
	blue = preset(
		Color3.fromRGB(80, 148, 250),
		Color3.fromRGB(44, 96, 240),
		Color3.fromRGB(26, 56, 160),
		Color3.fromRGB(120, 180, 255)
	),
	-- Light-blue reward cards (Daily day tiles).
	sky = preset(
		Color3.fromRGB(132, 204, 252),
		Color3.fromRGB(84, 168, 246),
		Color3.fromRGB(38, 106, 186),
		Color3.fromRGB(150, 214, 255)
	),
	-- Gems, VIP-ish premium, event.
	purple = preset(
		Color3.fromRGB(190, 116, 252),
		Color3.fromRGB(126, 60, 226),
		Color3.fromRGB(76, 32, 146),
		Color3.fromRGB(206, 150, 255)
	),
	-- Time rewards, Group rewards header, attack.
	orange = preset(
		Color3.fromRGB(250, 152, 66),
		Color3.fromRGB(234, 102, 38),
		Color3.fromRGB(152, 58, 18),
		Color3.fromRGB(255, 176, 90)
	),
	-- LOCKED! / OKAY / secondary.
	grey = preset(
		Color3.fromRGB(180, 180, 186),
		Color3.fromRGB(100, 102, 110),
		Color3.fromRGB(56, 58, 64),
		Color3.fromRGB(200, 204, 214)
	),
	-- Secret Pack card, neutral light surfaces.
	white = preset(
		Color3.fromRGB(248, 248, 250),
		Color3.fromRGB(196, 198, 206),
		Color3.fromRGB(126, 128, 138),
		Color3.fromRGB(240, 240, 246)
	),
	-- Teleport, reactor-glow accents.
	teal = preset(
		Color3.fromRGB(96, 236, 220),
		Color3.fromRGB(30, 170, 178),
		Color3.fromRGB(16, 100, 110),
		Color3.fromRGB(110, 240, 230)
	),
	-- Producer UPGRADE pill (reference 08 / 15: light cyan with a white-ish top).
	cyan = preset(
		Color3.fromRGB(170, 248, 255),
		Color3.fromRGB(64, 206, 244),
		Color3.fromRGB(22, 118, 160),
		Color3.fromRGB(120, 236, 255)
	),
	-- Rainbow: top/bottom are the gradient ends; StudUI draws the full Rainbow sequence below.
	rainbow = preset(
		Color3.fromRGB(250, 70, 70),
		Color3.fromRGB(150, 80, 240),
		Color3.fromRGB(70, 40, 120),
		Color3.fromRGB(255, 220, 90)
	),
}) :: { [ColorName]: Preset }

-- The rainbow surface gradient (rotated diagonally by StudUI).
UIStyleConfig.Rainbow = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(244, 58, 70)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(250, 150, 40)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(250, 228, 60)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(100, 220, 80)),
	ColorSequenceKeypoint.new(0.8, Color3.fromRGB(60, 150, 250)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 80, 240)),
})

-- Neutral surfaces.
UIStyleConfig.Neutral = table.freeze({
	Body = Color3.fromRGB(80, 92, 114), -- window body (dark slate)
	Well = Color3.fromRGB(42, 48, 62), -- dark inset well (text box, money well)
	Edge = Color3.fromRGB(18, 18, 24), -- every outline
	Text = Color3.fromRGB(255, 255, 255),
	TextStroke = Color3.fromRGB(20, 20, 28),
	TextDim = Color3.fromRGB(196, 204, 222),
	Placeholder = Color3.fromRGB(150, 158, 178),
	Shadow = Color3.fromRGB(0, 0, 0),
	CashGreen = Color3.fromRGB(120, 240, 70), -- the chunky cash number
	GemPurple = Color3.fromRGB(206, 130, 255),
	RobuxGreen = Color3.fromRGB(96, 214, 70), -- the Robux tag on offers
	Danger = Color3.fromRGB(255, 70, 70), -- "Limited Stock" red text
})

-- Fonts: Fredoka One for titles / labels (matches the references' rounded heavy type), Luckiest
-- Guy for big numbers and shouty headlines ("WELCOME BACK!", cash counter).
UIStyleConfig.Fonts = table.freeze({
	Title = Font.fromEnum(Enum.Font.FredokaOne),
	Body = Font.fromEnum(Enum.Font.FredokaOne),
	Number = Font.fromEnum(Enum.Font.LuckiestGuy),
	Shout = Font.fromEnum(Enum.Font.LuckiestGuy),
})

-- Stud tile draw size (design px per 2x2 tile = two studs) per surface size class, so small
-- buttons still show 3-4 studs per row like the references.
UIStyleConfig.StudTile = table.freeze({
	Window = 96,
	Card = 84,
	Button = 56,
	Hud = 64,
	Starburst = 0, -- starbursts have no stud face
})

-- Stud texture opacity per surface (1 = invisible). The light studs read as a lighter square,
-- the dark ones as a darker square, on top of the gradient face.
UIStyleConfig.StudTransparency = table.freeze({
	Header = 0.45,
	Card = 0.5,
	Button = 0.6,
	Hud = 0.5,
	Body = 0.9,
})

--[[
	Icon fill per slot: the icon's side as a fraction of its slot's HEIGHT. Values above 1 make
	the rendered 3D icon poke out of its button like the references (the Shop basket handle rises
	above its tile, the Daily calendar above the window header, the wheel past the Lucky Wheel
	bar). `CenterY` is where the icon's centre sits in a square HUD tile (0 = top, 1 = bottom), so
	the overflow goes UP and the label overlaps the icon's foot.
]]
UIStyleConfig.IconFill = table.freeze({
	-- Owner R14 (2026-10-30): left-column icons were "a little bit too big... come out of the boxes",
	-- so they now sit inside the tile (top edge ~4 % below the tile top), label overlapping the
	-- bottom like the reference Daily/Shop shots. Was Hud = 1.0 / HudCenterY = 0.4 / HudWide = 1.16.
	Hud = 0.8, -- square left-column tile
	HudCenterY = 0.44,
	HudWide = 0.98, -- the wheel over the wide Lucky Wheel tile
	Header = 1.18, -- window header bar (pokes above and below the bar)
	Starburst = 0.66, -- right-column offer slot
	Button = 0.82, -- icon inside a text button
	Money = 1.2, -- money stack / gem beside a currency number
	Toast = 0.95,
	Close = 1.12, -- a rendered "Close" icon over the red X button
})

-- Geometry (design px at 1080p). Corner radii are RENDERED px (no extra scaling).
UIStyleConfig.Window = table.freeze({
	Edge = 5, -- outer outline thickness
	Corner = 6,
	HeaderHeight = 104,
	TitleSize = 60,
	CloseSize = 78,
	BodyPadding = 16,
	-- The header's drop lip (a dark strip under the coloured plate).
	HeaderLip = 5,
})

UIStyleConfig.Card = table.freeze({
	Edge = 4,
	Corner = 6,
	TitleSize = 36,
	Padding = 8,
})

UIStyleConfig.Button = table.freeze({
	Edge = 3,
	Corner = 8,
	Lip = 5, -- 3D depth (the darker strip under the face)
	TextStrokeRatio = 0.085, -- text outline = TextSize * ratio (min 2)
	HoverScale = 1.05,
	PressScale = 0.93,
	DefaultHeight = 64,
})

UIStyleConfig.Hud = table.freeze({
	ButtonSize = 132, -- left-column square button side at 1080p (desktop)
	WideHeight = 104, -- the wide Lucky Wheel button's height
	Gap = 12,
	MinButtonSize = 82, -- never smaller on phones (≥ 44 pt at the phone scale floor)
	LabelRatio = 0.26, -- label TextSize = button side * ratio
	SideMargin = 16,
	-- Right offer column.
	OfferSize = 190, -- starburst slot side
	OfferMinSize = 128,
	OfferRotateSeconds = 6, -- when not every offer fits, cycle the last slot this often
	-- Owner R95: at most this many offers on screen at once (the rest rotate through the last slot).
	MaxOfferSlots = 2,
	-- Top-centre currency stack.
	CashTextSize = 64,
	GemTextSize = 44,
	RateTextSize = 28,
	-- Bottom objective chip.
	ObjectiveHeight = 64,
	ObjectiveMaxWidth = 760,
	-- Toasts.
	ToastHeight = 58,
	ToastMax = 4,
	ToastSeconds = 3.5,
})

--[[
	Item backing plates (owner R98: shop items were "hard to see with the stud background"): the
	soft dark disc behind every Shop item icon / model, the glow ring + halo in the card's colour,
	its drop shadow, and the dark name-plate behind item captions / descriptions.
	The fill is the card's own lip colour pulled toward the dark Neutral.Well (FillDarken), so
	each plate is a deeper shade of its card and white outlined text reads on every colour
	(tests/shop-item-fx.luau proves >= 4.5:1 contrast for every preset, through the stud face).
	Read by Screens/Shop/ItemFxLogic (colours) + Screens/Shop/ItemFx (instances).
]]
UIStyleConfig.ItemPlate = table.freeze({
	FillDarken = 0.4, -- 0 = the card's lip colour, 1 = Neutral.Well
	FillTransparency = 0.12, -- a hint of the stud face shows through
	-- Plate gradient (top lighter -> bottom darker): colour multiplier at the bottom.
	BottomShade = 0.72,
	DiscScale = 1.0, -- plate diameter / item slot
	RingThickness = 3, -- glow ring stroke (card accent colour)
	RingTransparency = 0.15,
	HaloScale = 1.14, -- soft halo disc behind the plate (card accent colour)
	HaloTransparency = 0.72,
	ShadowOffset = 4, -- design px down
	ShadowTransparency = 0.55,
	-- Name-plates behind captions / descriptions.
	LabelCorner = 10,
	LabelStroke = 3, -- caption text outline on a plate (px; never thinner than StudUI's)
})

return table.freeze(UIStyleConfig)
