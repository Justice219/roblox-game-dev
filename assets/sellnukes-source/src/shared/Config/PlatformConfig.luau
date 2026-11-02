--!strict
--[[
	PlatformConfig — THE action map and every console / mobile tunable (owner R11, spec §16).

	Purpose:
		SellNukes is console + mobile first. Every game action is declared ONCE here with all
		three input families:
			keys     keyboard keys (KB/M players)
			buttons  gamepad buttons (Xbox naming; PlayStation maps by position)
			touch    an on-screen StudUI button spec (Platform/TouchButtons) — or nil when the
			         action already has a tappable HUD button / billboard on phones
		plus how the platform layer treats it:
			priority     ContextActionService priority (Platform/ActionMap binds every action
			             with CAS, so a higher priority wins a shared key and Sinks it — e.g. Buy
			             on ButtonA beats Roblox's default jump while you stand on a pad)
			contexts     the action is bound only while ANY of these contexts is on (nil = always)
			freeNav      unbound while a GUI object holds the gamepad selection (the D-pad then
			             walks the menu instead of opening screens)
			whileBlocked still bound while a modal window is open (UI actions only; gameplay
			             actions are unbound behind menus: "menu open → only UI navigation")
			screen       ActionMap toggles this ScreenManager screen when the action fires
			hint         hint-bar text (Platform/HintBar) — systems may override it live through
			             ActionMap.setHintText ("Upgrade x10", "Buy $1.2K")
			idleHint     shown on a GAMEPAD even with no context (console navigation hints)
		InputConfig re-exports `Actions` / `ActionName` / `Binding` from here (one table; the
		fields InputController reads — keys, buttons, whileBlocked, studioOnly, label — are kept).

	Contexts (who sets them):
		Producer        an own producer is within reach        Tycoon/Interaction (B2/B6)
		ManualProducer  that producer is not automated yet      Tycoon/Interaction
		Pad             an own buy pad is within reach          Tycoon/Interaction (incl. owner R80
		                (tycoon pad or defence BUY pad)          defence pads via Attack/DefenseWorld)
		Tower           an own AA tower is within reach         Tycoon/Interaction ← Attack/DefenseWorld
		                (UPGRADE with Interact, owner R80)
		Egg             an egg stand is within reach            pets client (B9)
		LobbyFixture    a lobby fixture (Lucky Wheel stage,     Client/Lobby/LobbyFixtures (R99)
		                group chest, codes board) is in reach
		AttackUnlocked  profile.attack.launcher > 0             ActionMap (from ClientState)
		EventLive       the Harvest Feast event is running      event client (B11)
		Tabs            a tabbed / cycling screen is open       Platform/GamepadNav.cycler
		Selecting       a GUI object holds the gamepad cursor   ActionMap (GuiService)
		(the modal "menu" state is not a context: it comes from ScreenManager directly)

	Security: input is presentation-only — every action ends in a server-validated INTENT.

	Connects to: Shared/Config/InputConfig (re-export), Platform/{ActionMap, ActionLogic, HintBar,
	TouchButtons, Haptics, SafeArea, GamepadNav, MenuWheel}, Controllers/InputController.

	Example:
		local binding = PlatformConfig.Actions.Produce
		print(binding.buttons[1]) --> Enum.KeyCode.ButtonR2
		print(PlatformConfig.SafeArea.TvFraction) --> 0.05
]]

-- Every action name. Add new actions here AND in Actions below (tests/platform-actions.luau
-- checks the two agree and that every action has a gamepad binding).
export type ActionName =
	"Interact"
	| "Produce"
	| "UpgradeMode"
	| "Buy"
	| "Hatch"
	| "HudFocus"
	| "OffersFocus"
	| "Menu"
	| "Teleport"
	| "Attack"
	| "Deselect"
	| "TabPrev"
	| "TabNext"
	| "DevGallery"
	| "GemUpgrade" -- owner R86
	| "LobbyUse" -- owner R99: use the lobby fixture in reach (Lucky Wheel / group chest / codes)

export type ContextName =
	"Producer"
	| "ManualProducer"
	| "Pad"
	| "Tower"
	| "Egg"
	| "AttackUnlocked"
	| "EventLive"
	| "Tabs"
	| "Selecting"
	| "GemUpgrade" -- owner R86: an own producer in reach can take a gem level now
	| "LobbyFixture" -- owner R99: a lobby fixture's prompt point is in reach (Client/Lobby/LobbyFixtures)

-- Touch button size class (PlatformConfig.Touch.Sizes, in device points).
export type TouchSize = "large" | "normal" | "small"

-- On-screen touch button for an action (Platform/TouchButtons).
export type TouchSpec = {
	label: string, -- default caption (the hint-text override replaces it, e.g. "BUY $1.2K")
	icon: string?, -- IconAssets key shown left of the caption
	color: string, -- UIStyleConfig ColorName
	size: TouchSize,
	order: number, -- 1 = the slot nearest the jump button
}

export type Binding = {
	keys: { Enum.KeyCode }, -- keyboard keys (empty = no keyboard binding)
	buttons: { Enum.KeyCode }, -- gamepad buttons (empty = none)
	whileBlocked: boolean, -- still bound while a modal is open (UI-only actions)
	studioOnly: boolean?, -- developer tool, never bound on live servers
	label: string, -- short human label (How-to-play rows, docs)
	priority: number, -- ContextActionService priority
	-- Bound while ANY is on (nil = always). Plain strings so the literal tables below type-check;
	-- every entry must be a ContextName (tests/platform-actions.luau enforces it).
	contexts: { string }?,
	freeNav: boolean?, -- unbound while a GUI object holds the gamepad selection
	screen: string?, -- ScreenManager screen toggled when the action fires
	hint: string?, -- hint-bar text (nil = never shown in the hint bar)
	hintOrder: number?, -- lower = further left in the hint bar
	idleHint: boolean?, -- gamepad-only navigation hint shown without any context
	touch: TouchSpec?, -- on-screen touch button (nil = HUD / billboard covers touch)
}

local PlatformConfig = {}

--[[
	ContextActionService priorities. Roblox's default character controls bind at Medium (2000;
	ButtonA = jump), ScreenManager binds modal Back at High (3000).
		Gameplay   2100  above the default controls (Buy on ButtonA beats jump on a pad)
		Contextual 2200  beats Gameplay on a shared key (Hatch at an egg stand over Interact)
		Ui         2900  menu actions; still below the modal Back (B / X / Backspace)
]]
PlatformConfig.Priority = table.freeze({
	Gameplay = Enum.ContextActionPriority.Medium.Value + 100,
	Contextual = Enum.ContextActionPriority.Medium.Value + 200,
	Ui = Enum.ContextActionPriority.High.Value - 100,
})

local P = PlatformConfig.Priority

PlatformConfig.Actions = table.freeze({
	-- Use what you stand at: buy the own pad in reach, else (owner R80) buy / upgrade the own
	-- defence pad / AA tower in reach, else upgrade the nearest own producer by the current x1 /
	-- x10 / MAX amount. Tycoon/Interaction listens; hint text "Upgrade x10" /
	-- "Buy $1.2K" comes from it through ActionMap.setHintText.
	Interact = table.freeze({
		keys = { Enum.KeyCode.E },
		buttons = { Enum.KeyCode.ButtonX },
		whileBlocked = false,
		label = "Interact",
		priority = P.Gameplay,
		contexts = { "Producer", "Pad", "Tower" },
		hint = "Upgrade",
		hintOrder = 2,
		touch = { label = "UPGRADE", icon = "Arrow", color = "orange", size = "normal", order = 2 },
	}) :: Binding,
	-- Run one cycle of the nearest own MANUAL producer (the billboard CLICK bar / tapping the
	-- producer do the same).
	Produce = table.freeze({
		keys = { Enum.KeyCode.F },
		buttons = { Enum.KeyCode.ButtonR2 },
		whileBlocked = false,
		label = "Produce",
		priority = P.Gameplay,
		contexts = { "ManualProducer" },
		hint = "Make nukes",
		hintOrder = 1,
		touch = { label = "TAP!", icon = "Cash", color = "green", size = "large", order = 1 },
	}) :: Binding,
	-- Cycle the upgrade amount x1 -> x10 -> MAX on every producer billboard.
	UpgradeMode = table.freeze({
		keys = { Enum.KeyCode.Q },
		buttons = { Enum.KeyCode.ButtonY },
		whileBlocked = false,
		label = "Upgrade amount",
		priority = P.Gameplay,
		contexts = { "Producer" },
		hint = "Amount",
		hintOrder = 3,
		touch = { label = "x1", color = "sky", size = "small", order = 3 },
	}) :: Binding,
	-- Owner R86: buy ONE level of the nearest own producer for the flat gem price. Kid-friendly
	-- confirm (Tycoon/GemUpgrade): the first press arms ("Sure? 75 gems"), a second press within
	-- 3 s buys. C on a keyboard (free: R is the Revenge chip / stand sign, G Attack); LB on a pad
	-- (TabPrev owns LB only while a tabbed menu is open, when gameplay actions are unbound). The
	-- "GemUpgrade" context (Tycoon/GemUpgrade's provider) is on while the producer in reach is
	-- built, below MaxLevel and the admin switch is on; the caption says "Need 75 gems" when short.
	GemUpgrade = table.freeze({
		keys = { Enum.KeyCode.C },
		buttons = { Enum.KeyCode.ButtonL1 },
		whileBlocked = false,
		label = "Gem upgrade",
		priority = P.Gameplay,
		contexts = { "GemUpgrade" },
		hint = "Gem upgrade",
		hintOrder = 4,
		touch = { label = "GEMS", icon = "Gems", color = "purple", size = "normal", order = 4 },
	}) :: Binding,
	-- Gamepad: A buys the pad you stand on (out-prioritises the default jump only while a pad
	-- is in reach). Keyboard / touch players buy with Interact (E / the UPGRADE→BUY button).
	Buy = table.freeze({
		keys = {},
		buttons = { Enum.KeyCode.ButtonA },
		whileBlocked = false,
		label = "Buy",
		priority = P.Gameplay,
		contexts = { "Pad" },
		-- With the cursor on a HUD button, A must press THAT button (not buy the pad).
		freeNav = true,
		hint = "Buy",
		hintOrder = 0,
	}) :: Binding,
	-- At an egg stand: open the hatch (wins over Interact on the shared key). Pets client (B9).
	Hatch = table.freeze({
		keys = { Enum.KeyCode.E },
		buttons = { Enum.KeyCode.ButtonX },
		whileBlocked = false,
		label = "Hatch",
		priority = P.Contextual,
		contexts = { "Egg" },
		hint = "Hatch",
		hintOrder = 1,
		touch = { label = "HATCH", icon = "Pets", color = "purple", size = "large", order = 1 },
	}) :: Binding,
	-- Owner R99: at a lobby fixture (Lucky Wheel stage, group chest, codes board) open its screen.
	-- Client/Lobby/LobbyFixtures sets the context + the live hint / touch caption ("Spin!",
	-- "Group gift", "Codes"); the fixtures' ProximityPrompts stay as the mouse / tap fallback.
	LobbyUse = table.freeze({
		keys = { Enum.KeyCode.E },
		buttons = { Enum.KeyCode.ButtonX },
		whileBlocked = false,
		label = "Use",
		priority = P.Contextual,
		contexts = { "LobbyFixture" },
		hint = "Use",
		hintOrder = 1,
		touch = { label = "USE", color = "yellow", size = "large", order = 1 },
	}) :: Binding,
	-- Gamepad: put the selection cursor on the left HUD button column (UIController).
	HudFocus = table.freeze({
		keys = {},
		buttons = { Enum.KeyCode.DPadLeft },
		whileBlocked = false,
		label = "Menu buttons",
		priority = P.Gameplay,
		freeNav = true,
		hint = "Menus",
		hintOrder = 20,
		idleHint = true,
	}) :: Binding,
	-- Gamepad: put the selection cursor on the right offer column (UIController).
	OffersFocus = table.freeze({
		keys = {},
		buttons = { Enum.KeyCode.DPadRight },
		whileBlocked = false,
		label = "Offers",
		priority = P.Gameplay,
		freeNav = true,
		hint = "Offers",
		hintOrder = 22,
	}) :: Binding,
	-- The quick-menu wheel (every HUD screen in one ring). View / Select on a pad, M on a keyboard.
	Menu = table.freeze({
		keys = { Enum.KeyCode.M },
		buttons = { Enum.KeyCode.ButtonSelect },
		whileBlocked = true,
		label = "Quick menu",
		priority = P.Ui,
		screen = "MenuWheel",
		hint = "Quick menu",
		hintOrder = 21,
		idleHint = true,
	}) :: Binding,
	-- Teleport list (D-pad up / T).
	Teleport = table.freeze({
		keys = { Enum.KeyCode.T },
		buttons = { Enum.KeyCode.DPadUp },
		whileBlocked = false,
		label = "Teleport",
		priority = P.Gameplay,
		freeNav = true,
		screen = "Teleport",
		hint = "Teleport",
		hintOrder = 23,
	}) :: Binding,
	-- Attack target picker once the launcher is built (D-pad down / G).
	Attack = table.freeze({
		keys = { Enum.KeyCode.G },
		buttons = { Enum.KeyCode.DPadDown },
		whileBlocked = false,
		label = "Attack",
		priority = P.Gameplay,
		freeNav = true,
		contexts = { "AttackUnlocked" },
		screen = "Attack",
		hint = "Attack",
		hintOrder = 24,
	}) :: Binding,
	-- Gamepad B with the cursor on the HUD (no modal): drop the selection, back to walking.
	Deselect = table.freeze({
		keys = {},
		buttons = { Enum.KeyCode.ButtonB },
		whileBlocked = false,
		label = "Back",
		priority = P.Ui,
		contexts = { "Selecting" },
		hint = "Back",
		hintOrder = 30,
	}) :: Binding,
	-- Previous / next tab (or target) on a tabbed screen: LB / RB, Q / E on a keyboard (free
	-- while a menu is open: gameplay keys are unbound then).
	TabPrev = table.freeze({
		keys = { Enum.KeyCode.Q },
		buttons = { Enum.KeyCode.ButtonL1 },
		whileBlocked = true,
		label = "Previous tab",
		priority = P.Ui,
		contexts = { "Tabs" },
		hint = "Prev",
		hintOrder = 40,
	}) :: Binding,
	TabNext = table.freeze({
		keys = { Enum.KeyCode.E },
		buttons = { Enum.KeyCode.ButtonR1 },
		whileBlocked = true,
		label = "Next tab",
		priority = P.Ui,
		contexts = { "Tabs" },
		hint = "Next",
		hintOrder = 41,
	}) :: Binding,
	-- Studio only: toggles the dev UIGallery screen (every StudUI component on one page).
	DevGallery = table.freeze({
		keys = { Enum.KeyCode.F6 },
		buttons = {},
		whileBlocked = true,
		studioOnly = true,
		label = "UI gallery (Studio)",
		priority = P.Ui,
	}) :: Binding,
}) :: { [ActionName]: Binding }

-- Every context name (tests + ActionMap validation of setContext names).
PlatformConfig.Contexts = table.freeze({
	"Producer",
	"ManualProducer",
	"Pad",
	"Tower", -- owner R80: an own AA tower in reach (Interact upgrades it)
	"Egg",
	"AttackUnlocked",
	"EventLive",
	"Tabs",
	"Selecting",
	"GemUpgrade", -- owner R86: an own producer in reach can take a gem level (Tycoon/GemUpgrade)
	"LobbyFixture", -- owner R99: a lobby fixture in reach (Client/Lobby/LobbyFixtures)
} :: { ContextName })

-- Actions without a keyboard key on purpose (mouse players click the HUD instead).
PlatformConfig.NoKeyboardOk = table.freeze({
	Buy = true, -- keyboard buys with Interact (E)
	HudFocus = true, -- the mouse clicks the HUD
	OffersFocus = true,
	Deselect = true, -- gamepad selection only
} :: { [string]: boolean })

-- How often (Hz) ActionMap polls registered context providers (one loop for all of them).
PlatformConfig.ContextHz = 5

--[[
	Hint bar (Platform/HintBar): bottom-centre chips "[glyph] label" for the active device.
		Height       chip row height (design px)
		GlyphHeight  glyph size inside a chip
		TextSize     label size
		Gap          px between chips
		MaxHints     never more chips than this (contextual first, idle navigation hints after)
		Margin       px above the HUD objective chip / screen bottom
		DisplayOrder above modals (39) so menu hints show, below toasts (45)
		MenuButtons  gamepad hints shown while a modal is open (A select / B back)
]]
PlatformConfig.HintBar = table.freeze({
	-- Ten-foot readable: 30 px labels / 40 px glyphs at 1080p (≈ 14 pt+ on a phone if shown).
	Height = 50,
	GlyphHeight = 40,
	TextSize = 30,
	Gap = 22,
	MaxWidth = 1500,
	MaxHints = 4,
	Margin = 10,
	DisplayOrder = 44,
	MenuButtons = table.freeze({
		table.freeze({ button = Enum.KeyCode.ButtonA, text = "Select" }),
		table.freeze({ button = Enum.KeyCode.ButtonB, text = "Back" }),
	}),
})

--[[
	Touch buttons (Platform/TouchButtons): big StudUI buttons beside Roblox's jump button.
		Sizes          button side per size class in DEVICE POINTS (always ≥ MinTapPoints 44)
		Gap            points between buttons and the jump button
		EdgeMargin     points kept free from the screen edges
		TextRatio      caption TextSize = side * ratio
		DefaultJump    Roblox's TouchJump geometry when the real button is not found (Studio
		               forced Touch mode): small screens (short side ≤ SmallScreenMax pt) use
		               70 pt at (1, -95, 1, -90), larger ones 120 pt at (1, -170, 1, -210)
		ThumbstickZone fraction of the screen (from the bottom-left) the dynamic thumbstick owns
		DisplayOrder   above the HUD (5), below modals (20)
]]
PlatformConfig.Touch = table.freeze({
	-- large ≈ the 70 pt phone jump button; every size ≥ TouchUIConfig.MinTapPoints (44).
	Sizes = table.freeze({ large = 72, normal = 60, small = 48 } :: { [TouchSize]: number }),
	Gap = 10,
	EdgeMargin = 8,
	TextRatio = 0.3,
	DefaultJump = table.freeze({
		SmallScreenMax = 500,
		Small = table.freeze({ size = 70, right = 95, bottom = 90 }),
		Large = table.freeze({ size = 120, right = 170, bottom = 210 }),
	}),
	ThumbstickZone = table.freeze({ width = 0.4, height = 0.6 }),
	DisplayOrder = 7,
})

--[[
	Safe area (Platform/SafeArea).
		TvFraction   inset per side on a ten-foot (console) client: 5 % of the viewport (TV
		             overscan / title-safe area); phones get Roblox's DeviceSafeInsets instead
		StudioAttr   Studio-only LocalPlayer attribute that forces the TV inset on a desktop
		             session (device-matrix screenshots of the console layout)
]]
PlatformConfig.SafeArea = table.freeze({
	TvFraction = 0.05,
	StudioAttr = "DevTvSafe",
})

--[[
	Haptics (Platform/Haptics). Each preset drives the gamepad's small (high-frequency) and
	large (low-frequency) motors for `seconds`; on phones the matching HapticEffect type plays.
	MinGap: the same preset never restarts within this many seconds (a burst of purchase toasts
	is one buzz).
]]
export type HapticPreset = {
	small: number, -- 0..1 small motor strength
	large: number, -- 0..1 large motor strength
	seconds: number,
	effect: Enum.HapticEffectType, -- phone / modern-gamepad waveform
}

export type HapticName = "Tap" | "Purchase" | "BuildComplete" | "Hatch" | "Hit" | "Reward" | "Error"

PlatformConfig.Haptics = table.freeze({
	MinGap = 0.12,
	Presets = table.freeze({
		Tap = table.freeze({ small = 0.25, large = 0, seconds = 0.05, effect = Enum.HapticEffectType.UIClick }),
		Purchase = table.freeze({
			small = 0.5,
			large = 0.25,
			seconds = 0.12,
			effect = Enum.HapticEffectType.UINotification,
		}),
		BuildComplete = table.freeze({
			small = 0.35,
			large = 0.6,
			seconds = 0.22,
			effect = Enum.HapticEffectType.GameplayCollision,
		}),
		Hatch = table.freeze({
			small = 0.6,
			large = 0.8,
			seconds = 0.35,
			effect = Enum.HapticEffectType.GameplayExplosion,
		}),
		Hit = table.freeze({
			small = 0.8,
			large = 1,
			seconds = 0.3,
			effect = Enum.HapticEffectType.GameplayExplosion,
		}),
		Reward = table.freeze({
			small = 0.4,
			large = 0.2,
			seconds = 0.1,
			effect = Enum.HapticEffectType.UINotification,
		}),
		Error = table.freeze({ small = 0, large = 0.45, seconds = 0.08, effect = Enum.HapticEffectType.UIClick }),
	} :: { [HapticName]: HapticPreset }),
})

--[[
	Menu wheel (Platform/MenuWheel): every HUD screen in a ring, opened with View / Select or M.
		Size        window design size
		Radius      ring radius (design px, before the window fit)
		TileMax     largest tile side; tiles shrink to fit the ring circumference
		Extra       screens added after the HUD rows when they are registered
]]
PlatformConfig.MenuWheel = table.freeze({
	Size = Vector2.new(1040, 900), -- body ≈ 870 px tall: ring diameter 680 + a 140 px tile fits
	-- 340 keeps 13 square tiles (12 HUD screens + Settings) ≥ 107 px without overlapping
	-- (LayoutLogic.ringTile sizes by the square-safe Chebyshev gap; 270 gave 82 px tiles).
	Radius = 340,
	TileMax = 140,
	TileGap = 14,
	Extra = table.freeze({
		table.freeze({ key = "Settings", label = "Settings", icon = "Star", color = "grey", screen = "Settings" }),
	}),
})

-- PlayStation glyph captions by gamepad KeyCode name (text fallback when the engine has no image).
PlatformConfig.PlayStationLabels = table.freeze({
	ButtonA = "✕",
	ButtonB = "○",
	ButtonX = "□",
	ButtonY = "△",
	ButtonL1 = "L1",
	ButtonR1 = "R1",
	ButtonL2 = "L2",
	ButtonR2 = "R2",
	ButtonL3 = "L3",
	ButtonR3 = "R3",
	DPadLeft = "◀",
	DPadRight = "▶",
	DPadUp = "▲",
	DPadDown = "▼",
	ButtonSelect = "Create",
	ButtonStart = "Options",
} :: { [string]: string })

-- PlayStation face-button chip colours (Cross blue, Circle red, Square pink, Triangle teal).
PlatformConfig.PlayStationColors = table.freeze({
	ButtonA = Color3.fromRGB(110, 160, 235),
	ButtonB = Color3.fromRGB(235, 90, 96),
	ButtonX = Color3.fromRGB(214, 130, 196),
	ButtonY = Color3.fromRGB(64, 200, 180),
} :: { [string]: Color3 })

-- Studio-only LocalPlayer attribute forcing a glyph family for screenshots ("PlayStation").
PlatformConfig.GlyphFamilyAttr = "DevGlyphFamily"

return table.freeze(PlatformConfig)
