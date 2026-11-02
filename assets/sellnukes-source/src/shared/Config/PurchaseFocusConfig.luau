--!strict
--[[
	PurchaseFocusConfig — tunables of the owner R122 "no accidental purchase prompts" pack (spec
	docs/superpowers/specs/2026-11-01-r122-algorithm-pack-design.md §2.4).

	Why: of ~190 Robux prompts in two days, 0 were bought and most closed in under 2 s: paid Lucky
	Buttons prompted when walked into, console screens opened with the gamepad cursor already on a
	BUY button (Shop → Starter Pack) and one tap on a HUD offer chip prompted at once. Owner R120:
	popups are annoying — keep everything small and non-modal.

	The rules this file tunes:
		Guard     A Robux BUY press is honoured only when the press BEGAN after its surface opened
		          (+ PressAfterOpen) and the surface has been up ArmSeconds: the press that opens a
		          screen / card can never also buy something inside it (UI/PurchaseGuard).
		BuyAttribute   set on every Robux BUY button (PurchaseGuard.markBuy) so default-selection
		          helpers never land the gamepad cursor on one (PurchaseGuard.safeDefault).
		DealCard  the small non-modal DEAL card (UI/Screens/DealCard): a paid Lucky Button walk-in
		          (bottom-left feed card) and a HUD offer chip tap (beside the chip). Only its BUY
		          opens the Robux prompt; it is never auto-focused on console; a bound button buys
		          (X / E — never A, which is jump while running), B / X / Backspace closes.

	Connects to: UI/PurchaseGuard (+ PurchaseGuardLogic), UI/Screens/DealCard, UI/Hud/HudOffers,
	Client/LuckyButtons/LuckyButtonClient, every prompt-source screen (Shop, Lucky Wheel, Pets / egg
	hatch, Teleport, attack screens, Event / Crate shops, Nuke Pass, Welcome Back),
	Shared/Config/{PlatformConfig (priorities), InputConfig (close keys)}, tests/purchase-focus.luau.

	Example:
		local guard = PurchaseFocusConfig.Guard
		print(guard.ArmSeconds, guard.PressAfterOpen) --> 0.3 0.08
]]

local PlatformConfig = require(script.Parent.PlatformConfig)

local PurchaseFocusConfig = {}

-- ── Opening-press guard (UI/PurchaseGuard) ──────────────────────────────────────────────────────

PurchaseFocusConfig.Guard = table.freeze({
	-- Seconds after a surface opened before its BUY presses count: an activation whose press began
	-- earlier (the press that OPENED the surface, incl. a gamepad A released over the newly
	-- selected button) is refused. Generous enough for a press handled in the same frame as the
	-- open, far below any deliberate second press (> 0.15 s for people).
	PressAfterOpen = 0.08,
	-- Seconds a surface must have been on screen before any BUY counts (a fast double-tap on a chip
	-- that opens a card never lands on the card's BUY).
	ArmSeconds = 0.3,
	-- Surfaces remembered at once (screen names + card ids); the oldest is forgotten first.
	MaxSurfaces = 64,
})

-- Instance attribute marking a Robux BUY button (PurchaseGuard.markBuy / isBuy).
PurchaseFocusConfig.BuyAttribute = "RobuxBuy"
-- Instance attribute marking a non-buy gamepad landing (PurchaseGuard.landing): the place the
-- cursor starts on a screen whose only other controls are BUY buttons (Shop section headings).
PurchaseFocusConfig.LandingAttribute = "PurchaseLanding"
-- The landing's selection ring (white outline like StudUI's SelectionRing).
PurchaseFocusConfig.LandingRing = table.freeze({ Thickness = 4, Corner = 12, Pad = 6 })

-- ── DEAL card (UI/Screens/DealCard) ─────────────────────────────────────────────────────────────

PurchaseFocusConfig.DealCard = table.freeze({
	-- Design px at fit 1 (1080p canvas): art left, title + line beside it, CLOSE + BUY along the
	-- bottom. Widgets/FeedCardMetrics grows text / buttons on phones so they stay >= 14 pt / 44 pt
	-- at the fit the space allows (never under MinFit).
	Width = 500,
	MinFit = 0.62,
	ArtSize = 110,
	TitleSize = 34,
	LineSize = 24,
	LineRows = 2,
	ButtonHeight = 62,
	BuyWidth = 220,
	CloseWidth = 150,
	Pad = 14,
	Gap = 10,
	-- Glyph height beside BUY / CLOSE (gamepad / keyboard only; hidden on touch).
	GlyphHeight = 30,
	-- Gap between a HUD chip (offer / golden revenge) and its card (design px).
	ChipGap = 14,
	-- A card opened from a HUD chip closes itself after this long (it is only a preview); a Lucky
	-- Button card stays while the player stands at the button.
	ChipAutoClose = 10,
	-- Pop-in (Reduce Motion: none).
	PopFrom = 0.6,
	PopSeconds = 0.22,
	-- Colour preset of the card (UIStyleConfig.Colors) per source.
	Colors = table.freeze({ lucky = "purple", offer = "blue", attack = "orange" } :: { [string]: string }),
	-- Words (kid-friendly, short).
	Text = table.freeze({
		Close = "CLOSE",
		LuckyTitle = "LUCKY DEAL!",
	}),
})

-- Bindings of the card's BUY: X (gamepad) / E (keyboard) — never A (jump while running). Bound at
-- a priority BELOW every gameplay action (PlatformConfig.Priority.Gameplay), so a pad / producer
-- / hatch / lobby action on the same key always wins: a press meant for a pad never opens a Robux
-- prompt. Close: gamepad B and the keyboard close keys (InputConfig.CloseKeys) at High priority
-- (only while a card is up).
PurchaseFocusConfig.DealKeys = table.freeze({
	BuyKey = Enum.KeyCode.E,
	BuyPad = Enum.KeyCode.ButtonX,
	BuyPriority = PlatformConfig.Priority.Gameplay - 50,
	ClosePriority = Enum.ContextActionPriority.High.Value + 10,
})

return table.freeze(PurchaseFocusConfig)
