# UI framework: stud panels, screens, HUD, devices

This file explains how SellNukes builds its UI and how to build a Roblox game's UI the same way.
SellNukes has no Studio GUI objects. Every screen, HUD tile, toast and popup is built in Luau by
one framework: `Create`, `Theme`, `Components`, `ScreenManager`, the `StudUI` kit and widgets,
all ported from the RoBeasts repo (`~/IdeaProjects/RoBeasts/src/client/UI`). It is laid out on a
1920 x 1080 design canvas, scaled per device, and tested with pure Lune modules before Studio
sees it. Read this file before you build or change any screen. It covers where code goes, the
rules every screen must follow (stud texture, touch, gamepad, TV-safe), and the lessons the owner
has already paid for. Paths are relative to the SellNukes repo root. The source docs are
`docs/ui.md`, `docs/platform.md`, `docs/brand.md`, `docs/icons.md`, `docs/juice.md` and
`docs/happy-hours.md`.

## Contents

1. [Layers and folders](#1-layers-and-folders)
2. [Design canvas and UI scale per device](#2-design-canvas-and-ui-scale-per-device)
3. [Device rules: phone, tablet, console (owner R11)](#3-device-rules-phone-tablet-console-owner-r11)
4. [The stud look: panels, StudUI, colours, fonts](#4-the-stud-look-panels-studui-colours-fonts)
5. [ScreenManager: modal, non-modal, focus, handoff](#5-screenmanager-modal-non-modal-focus-handoff)
6. [HUD zones and avoiding overlaps](#6-hud-zones-and-avoiding-overlaps)
7. [PopupQueue: one queue for everything that pops](#7-popupqueue-one-queue-for-everything-that-pops)
8. [Juice and animation patterns](#8-juice-and-animation-patterns)
9. [Icons, brand art and the loading gate](#9-icons-brand-art-and-the-loading-gate)
10. [Build a new screen end to end](#10-build-a-new-screen-end-to-end)
11. [Pure layout logic vs the Instance-building screen](#11-pure-layout-logic-vs-the-instance-building-screen)
12. [Lessons from owner feedback](#12-lessons-from-owner-feedback)
13. [Carrying this to another game](#13-carrying-this-to-another-game)

---

## 1. Layers and folders

Keep each layer in its own folder, so builders working in parallel never fight over a shared
file. A new screen is a new file, and a new HUD button is one config row.

| Layer | Path (`src/client/UI/...`) | Job |
|---|---|---|
| Builder | `Create.luau` | `Create.new(class, props)`: properties, `Children`, `[Create.event("Activated")]` handlers, `Parent` set last so nothing renders half-built. It also binds `ButtonFeedback` to every button it creates. |
| Theme | `Theme.luau` | The few neutral colours, fonts and sizes the framework needs. It mirrors `UIStyleConfig`, so both always agree. |
| Components | `Components.luau` | Low-level parts: `corner`, `stroke`, `padding`, `label`, `panel`, and the chunky 3D `button` (`Selectable`, grows on hover or selection, squashes on press). |
| Screen stack | `ScreenManager.luau` | Registers screens, opens and closes them, keeps the modal stack, focus mode, handoff, device layout, safe insets and Back handling. |
| Kit | `Kit/StudUI.luau`, `Kit/Glyphs.luau` | The public style kit every screen uses (section 4). `Glyphs` draws fallback icons from frames. |
| Widgets | `Widgets/*` | `PanelBackdrop` / `StudTexture*` (stud material), `StudWindow` (surface parts), `ModalShell` (fit and pop-in), `GuiFade`, `OfferFx` (the one animation driver), `InputGlyph`, `HudPlacement` (pure HUD maths), `HudZones` (live HUD rects), `PopupQueue` + `PopupQueueLogic` + `FeedLogic`, `LoadingGate`, `ScreenRect`, `ModelViewport`, `ActionCard`. |
| HUD | `Hud/*` | The `Hud` façade plus `HudCurrency`, `HudButtons`, `HudMoreMenu` + `HudMoreLogic`, `HudOffers`, `HudObjective` + `PointerLogic`, `HudWhatsNew`, `HudAdminChip`, `HudInvite`, `Toasts`, `CurrencyFly` + `CurrencyFlyRules`. |
| Screens | `Screens/*` | One module per screen, about 40 today: Shop, Pets, Quests, RewardsHub, DailyRewards, LuckyWheel, Teleport, Rebirth, NukePass, HappyHour, WorldTravel, Admin, UIGallery, ComingSoon and more. `Controllers/UIController` finds them automatically. |
| Feedback | `ButtonFeedback.luau` + `ButtonFeedbackRules.luau` | A sound and a pooled particle burst on every GuiButton (owner R22). |
| Commerce | `PriceBook.luau`, `PurchaseGuard.luau` + `PurchaseGuardLogic.luau` | Live Robux prices for buttons, and one-tap-one-prompt guards. |
| Platform | `src/client/Platform/*` | `ActionMap`, `GamepadNav`, `GlyphFamily`, `HintBar`, `TouchButtons`, `SafeArea`, `MenuWheel`, `Haptics`, `LayoutLogic` (pure). See `docs/platform.md`. |

The config modules live in `src/shared/Config/`: `UIStyleConfig` (palette and geometry),
`DeviceConfig` (scale), `TouchUIConfig` (tap sizes, modal fit), `HudZonesConfig` (HUD rows and
margins), `HudFocusConfig` (fade timings, hidden screens), `InputConfig` / `PlatformConfig`
(actions), `IconAssets` (generated), `OfferFxConfig`, `PanelTextureAssets`, `PanelStudPixels`,
`PopupQueueConfig`, `JuiceConfig` and `CurrencyFlyConfig`.

**Boot order.** `init.client.luau` runs `InputController`, then `CameraController`, then
`UIController` (`Init` for all three, then `Start`). `UIController.Start`:
1. Feeds the `DeviceProfile` into `ScreenManager`.
2. Registers the HUD (kept hidden until loading finishes).
3. Discovers `UI/Screens`:
   - every direct-child ModuleScript is a screen;
   - inside a Folder, only modules named `*Screen` are screens;
   - `UIGallery` registers only in Studio.
4. Sets the `ComingSoon` fallback.
5. Prebuilds lazy screens marked `prebuild` during idle time.
6. Wires D-pad left / right onto the HUD columns.
7. Mirrors Reduce Motion into `OfferFx`.
8. In Studio only, honours the `DevOpenScreen` player attribute, so MCP can open a screen for a
   screenshot.

## 2. Design canvas and UI scale per device

Author every size in **design px on a 1920 x 1080 canvas**
(`DeviceConfig.DesignWidth/DesignHeight`). One `UIScale` per ScreenGui maps the design canvas to
the real viewport, so a layout written once works on every screen.

| Device class (`DeviceProfile.classify`) | Rule | Scale clamp (`DeviceConfig.Scale`) |
|---|---|---|
| Phone: viewport short side < `PhoneShortSide` = 600 pt | Height-led, so text stays readable on a ~390 pt tall landscape screen. The HUD re-flows into the wider canvas, and windows shrink to fit. | min **0.62**, max 1.25 |
| Tablet: primary input is touch and the device is not a phone | Fits the whole design | min 0.5, max 1.25 |
| Desktop: everything else (touch laptops with a keyboard stay Desktop) | Fits the whole design (min of the two axis ratios) | min 0.4, max 1.25 |
| Console: ten-foot UI, gamepad only | Same as Desktop, plus a 5 % TV-safe inset | min 0.4, max **2.0** (a 4K-point TV must keep 1080p proportions) |

Why 0.62 on phones: it gives ≈ 11 pt for the smallest (18 px) body text and ≥ 44 pt for a 72 px
button. At that scale a phone's design canvas is about **1360 x 630 design px**. The usable band
between the top bar and the thumb zones is about **485 design px** tall. Design phone windows
short and wide.

Rules:
- **Never measure `gui.AbsoluteSize` yourself.** Use `ScreenManager.canvasSize(gui)` (usable
  canvas in design px, minus the safe insets) and `ScreenManager.safeTop(margin?)` (design px
  below the Roblox top bar). Re-lay out on `ScreenManager.LayoutChanged` and `SafeAreaChanged`.
  A disabled ScreenGui reports a stale size.
- Convert physical sizes with `TouchLayout.pointsToDesign(points, ScreenManager.pointScale())`.
  A 44 pt tap is a different number of design px on every phone.
- Read the device from `ScreenManager.device` (`class`, `isTouch`, `isPhone`, `isTablet`,
  `uiScale`). Ask `ScreenManager.touchTargets()` whether finger-sized targets are needed now (the
  player may switch input mid-session).
- **Text-size constraints count rendered px, never design px** (R78 lesson). A
  `UITextSizeConstraint` floor of 14 on touch means 14 rendered px = 14 pt. Do not compute it
  from the design size.

## 3. Device rules: phone, tablet, console (owner R11)

> R11: "The game is optimized for console and mobile ... we need to make sure we have a controller
> handler and on mobile the UI doesn't look too bad."

Console and mobile are the primary platforms. Keyboard and mouse still work. Every screen must pass
this checklist (`docs/platform.md` §7):

**Touch (phone / tablet)**
- Every interactive element is **≥ 44 pt** (`TouchUIConfig.MinTapPoints`) on both sides, and text
  is **≥ 14 pt** after scaling.
- Nothing sits in the **thumbstick corner** (bottom-left, `LayoutLogic.thumbstickRect`) or the
  **jump-button corner** (bottom-right, `LayoutLogic` reads the real
  `TouchGui.TouchControlFrame.JumpButton` and falls back to Roblox's default geometry).
- Contextual touch buttons (TAP!, UPGRADE, BUY, HATCH; `Platform/TouchButtons`, 72 / 60 / 48 pt)
  grow as one arc around the jump button. They never cover the jump button, the thumbstick or the
  HUD columns.
- Windows shrink through `ModalShell`: margins of 48 design px on desktop and 16 on touch, and
  never below `MinFit` 0.55. When a reference grid would shrink below the tap or text floor, use
  a **`ResponsiveModal`** (`Screens/DailyRewards/ResponsiveModal`). It lets a screen list several
  authored sizes ("modes", for example `wide` 1560 x 860 and `phone` 1320 x 620). On touch it
  picks the mode that renders biggest; with a mouse or gamepad it always uses the first
  (reference) mode.
- A modal that draws no close button of its own gets a 48 pt touch X automatically
  (`TouchUIConfig.Close`). Every StudUI window already has its red X.
- Phone notch and home bar: Roblox's `DeviceSafeInsets`, applied by ScreenManager.

**Console (gamepad, TV)**
- A **5 % TV-safe inset** per side (96 x 54 pt at 1080p, `Platform/SafeArea` →
  `ScreenManager.setSafeInsets`). Every ScreenGui gets a `SafeArea` UIPadding. A full-bleed
  screen opts out with `safeArea = false`. In Studio, set the player attribute `DevTvSafe = true`
  to test it.
- **Controller navigation through `GuiService.SelectedObject`:**
  - Every button is `Selectable`.
  - Every modal returns a `defaultSelection`, and it is never the close X when the screen has
    content.
  - Grids are linked with `GamepadNav.linkGrid` or `linkList`.
  - Scroll lists follow the cursor (`GamepadNav.followScroll`).
  - Tabs cycle on LB / RB (`GamepadNav.cycler`).
  - Confirm dialogs trap the cursor (`GamepadNav.trap`).
  - Avoid hover-only affordances.
- **B / Back closes the top modal** (`closeOnBack`, the default). Keyboard X / Backspace also
  close it, but never while a TextBox has focus (`Shared/Util/PopupCloseRule`): typing a code must
  not close the Codes window. A screen can intercept with `onBack() -> true`.
- While a modal is open on a gamepad, the character pauses so the stick drives the menu. D-pad
  left / right jump onto the HUD columns (`Hud.focusButtons()` / `Hud.focusOffers()`).
- **Button-hint glyphs follow the device.** `Widgets/InputGlyph` and `Platform/GlyphFamily` show a
  key cap on keyboard and the engine's gamepad image on a controller (correct Xbox or PlayStation
  shapes, with a text-chip fallback), and they collapse on touch. The `PlatformHints` bar
  (DisplayOrder 44, bottom centre) shows `A Select · B Back` inside modals. It is hidden on touch
  and in focus mode.
- **MenuWheel** (View / Select or M) lists every HUD screen in a ring, so a controller reaches
  everything without walking the HUD.
- **Haptics** (`Platform/Haptics`): Tap, Purchase, BuildComplete, Hatch, Hit, Reward, Error.
  They respect the Vibration setting.

**Accessibility (all devices)**: Reduce Motion (the Roblox setting or
`profile.settings.reducedMotion`) and Low graphics park every animation. The blur behind windows
is skipped on Low graphics. An unknown screen name opens `ComingSoon`, so no button is ever dead.

## 4. The stud look: panels, StudUI, colours, fonts

**Owner rule 2: every UI surface uses the stud texture.** The look comes from the owner's
reference shots (`assets/reference/ui-style/*.jpg`, described in `reference-screenshots.md`):
- coloured surfaces have a vertical gradient (lighter top) under a tiled stud texture and a thick
  near-black outline;
- buttons add a darker 3D "lip" underneath;
- windows have a coloured stud header (icon, big outlined title, red square X) over a dark slate
  body;
- all text is white with a fat dark outline.

**Stud material.** `Widgets/PanelBackdrop` is the only way a surface gets studs. It tiles (never
stretches) `PanelTextureAssets.StudImage`, the RoBeasts stud tile, as a full-size child under the
panel's content. It is never Active or Selectable. Header studs drift sideways through one `OfferFx`
registration, which costs nothing while hidden. Tile size comes per surface class from
`UIStyleConfig.StudTile` (Window 96, Card 84, Button 56, Hud 64 design px per two studs).
Opacity comes from `StudTransparency` (Header 0.45, Card 0.5, Button 0.6, Hud 0.5, Body 0.9).
**Layout rule:** never put a `UIListLayout` or `UIGridLayout` directly on a studded frame, because
it would lay out the backdrop as a list item. Put content in the window's `body` or the card's
`content` frame. Studio warns about violations. `PanelTextureAssets.LocalBitmap = false` by
default: the experience has the EditableImage API disabled, and Studio renders a client bitmap as
a magenta placeholder.

**StudUI API** (`Kit/StudUI.luau`; all sizes in design px; every builder accepts `parent` and
`layoutOrder`):

| Builder | Use |
|---|---|
| `StudUI.modalScreen(spec)` | A complete modal ScreenModule around a window: ModalShell fit, pop-in, X / Back / B, default selection. `spec = {name, title, color?, icon?, size: Vector2, scroll?, lazy?, prebuild?, displayOrder?, blur?, build(window, gui) -> ScreenHandle?}` |
| `StudUI.window(o)` | Header plus slate body. Returns `{frame, header, body, closeButton, titleLabel, setTitle, setColor, Destroy}` |
| `StudUI.card(o)` | A coloured stud card (`color` may be `"rainbow"`), with optional sunburst and title |
| `StudUI.button(o)` | A stud button. Options: `{text, color?, robux?, productKey?, icon?, size?, textSize?, onActivated?}`. States: `normal`, `locked`, `claimed`, `disabled`. It ignores a second activation within 0.25 s and shrinks an overflowing label down to 60 % (R94) |
| `StudUI.hudButton(o)` | The left-column HUD tile: icon, label, badge, wide variant |
| `StudUI.starburst(o)` | The right-column Robux offer: spiky burst, icon, label and a live price |
| `StudUI.moneyLabel`, `countdown`, `progressBar`, `textBox`, `toast`, `sectionLabel`, `robuxTag`, `closeButton`, `text`, `icon`, `fitWidth` | Counters with roll-up, server-time countdowns (one shared 1 Hz thread on `Workspace:GetServerTimeNow()`), a dark-well text box, toast chips, "- LIMITED TIME -" headings, and so on |

Show prices only through `productKey` (the live managed price from `UI/PriceBook`, which shows
"..." until it is known) or a number the server sent. Buttons only call your callback. Every
purchase and claim is validated on the server.

**Colour presets** (`UIStyleConfig.Colors`; each is `{top, bottom, lip, accent}`):

| Preset | Use |
|---|---|
| `green` | CLAIM, Redeem, Robux buy, DOUBLE IT!, confirm |
| `yellow` | Shop header, paid spin bundles, highlights |
| `red` | close X, Daily header, Starter Pack, danger |
| `blue` | Codes header, info |
| `sky` | Daily day cards |
| `purple` | gems, premium, purchase toast |
| `orange` | Time Rewards cards, Group header |
| `grey` | LOCKED!, OKAY, secondary actions |
| `white` | Secret Pack card |
| `teal` / `cyan` | Rebirth, Teleport, world tabs |
| `rainbow` | Day 7 / final cards, the Lucky Wheel tile (it shimmers on the `OfferFx` driver) |

The neutrals are in `UIStyleConfig.Neutral`: `Body` (slate window body), `Well` (dark inset),
`Edge` (every outline), `TextStroke`, `CashGreen`, `GemPurple`, `RobuxGreen` and `Danger`.

**Fonts** (`UIStyleConfig.Fonts`): `Title` and `Body` use **Fredoka One** (rounded, heavy, used for
labels). `Number` and **`Shout`** use **Luckiest Guy** (cash counters and shouty headlines like
"WELCOME BACK!"). Pass `font = "shout"` to `StudUI.text`. Text outline thickness =
`TextSize × 0.085` (`Button.TextStrokeRatio`, minimum 2).

**Geometry** (`UIStyleConfig`):
- Window: header 104, title 60, close 78, edge 5.
- Button: lip 5, hover 1.05, press 0.93, default height 64.
- HUD: tile 132, `MinButtonSize` 82, offer 190, `MaxOfferSlots` 2, objective chip 64 tall and at
  most 760 wide.
- `IconFill` sets how far icons poke out of their slot. HUD tile 0.8, centred at 0.44 (R14 shrank
  it from 1.0); header 1.18; starburst 0.66; button 0.82; money 1.2.
- `ItemPlate` (R98) gives shop items a dark backing disc, so icons read on studs (contrast is
  ≥ 4.5:1, tested).

**Dev gallery:** press F6 in a Studio playtest, or open `"UIGallery"`, to see every component
and compare it with the references after a style change.

## 5. ScreenManager: modal, non-modal, focus, handoff

A screen is a ModuleScript that returns a **ScreenModule**:

```lua
return {
	name = "Shop",
	modal = true,          -- blocks gameplay while open; false = HUD-style overlay
	autoOpen = false,      -- HUD widgets / chips set true (open at boot)
	closeOnBack = true,    -- default true for modals (B / X / Backspace)
	displayOrder = 20,     -- default 20 modal, 5 non-modal
	lazy = true,           -- build on first open (shorter phone boot)
	prebuild = false,      -- with lazy: build during idle time after boot
	blur = true,           -- modal only: soft world blur (skipped on Low graphics)
	safeArea = true,       -- false = full-bleed (no TV-safe padding)
	build = function(gui: ScreenGui): ScreenHandle ... end,
}
-- ScreenHandle = { onOpen(args)?, onClose()?, onBack() -> boolean?, defaultSelection() -> GuiObject? }
```

**Modal vs non-modal.** While any modal is open:
- gameplay input is blocked (`InputController` "Menus");
- the mouse is freed;
- the world is blurred;
- the gamepad cursor goes to `defaultSelection`;
- Back closes the top modal.

Modals stack (`topModalName`, `isTopModal`, `closeTopModal`, `closeAllModals`).

Non-modal screens are HUD-style overlays that never take input focus: chips, banners, boost
badges, the Lucky Button edge arrow. Mark their elements `Active = false` and not selectable.

**Display order bands in use:**

| DisplayOrder | Screens |
|---|---|
| 5 | non-modal default (the `Hud` itself) |
| 6 | chips |
| 7 | touch buttons |
| 16 | banners |
| 20 | modals |
| 40 | `CurrencyFly` |
| 44 | the hint bar |
| 45 | `Toasts` |

**Opening.** Use `ScreenManager.open(name, args)`, `toggle(name, args)`, `close(name)`,
`isOpen(name)`, `getGui(name)`, and the signals `Opened` / `Closed`. By convention `args.source`
says who opened the screen (`"hud"`, `"chip"`, `"hub"`, `"offer"`, `"auto"`, ...). The screen
forwards it to analytics. Other args are screen-specific deep links, for example
`open("RewardsHub", { open = "Daily" })` or `open("Teleport", { area = 3 })`. An unregistered name
opens `ComingSoon` with `{ requested = name }`, so a HUD button for an unfinished system never does
nothing.

**Handoff (owner R79).** `ScreenManager.handoff(from, to, args)` opens modal `to` from modal
`from`:
- `from` stays in the stack but hides while `to` is open;
- when `to` closes, `from` comes back with the cursor on the button that was pressed.

Quests GO → Lucky Wheel and Nuke Pass OPEN use it. Use it whenever one window leads to another.
Never close and reopen by hand.

**Focus mode.** `ScreenManager.setFocusReason(reason, on, hiddenScreens?)` fades the listed
non-modal screens out through `GuiFade` (default `{ "Hud" }`) for clean moments, such as the egg
hatch, the attack target picker or the tutorial's first click. It fades them back in when every
reason has been cleared. Use `isFocusMode()` and `FocusChanged` to check it. Timings come from
`HudFocusConfig` (out 0.18 s, in 0.24 s).

**Menus hide the side columns (owner R79).** The left buttons, the offers, WHAT'S NEW and the
objective chip live in one `HudRoot/MenuLayer`. That layer fades out while
`ScreenManager.anyModalOpen()` and back in when the last window closes. Only the currency stack
stays. While a screen in `HudFocusConfig.CurrencyHiddenScreens` is open (today `LuckyWheel`,
R127), the currency stack fades out too.

## 6. HUD zones and avoiding overlaps

The HUD (`UI/Hud/Hud.luau`) has zones around the play view:

| Zone | Contents |
|---|---|
| **Left** | The square stud tiles: Shop, Pets, Quests, Rewards, Attack and **MORE** (R110). It is a 2 x 3 grid on every device. MORE opens a flyout with Teleport, Rebirth, Event (while live) and Settings. |
| **Right** | Starburst Robux offers. At most `MaxOfferSlots` = **2** show (R95); the rest rotate through the second slot every 6 s. WHAT'S NEW sits under them (R58). |
| **Top** | The centre currency stack: gems, cash, +$/s, and the boost badge on the cash corner (R82). |
| **Bottom** | The objective chip, plus the tutorial arrow. |
| **TopRight** | The admin wrench chip (admins only) and INVITE. |
| **Hints** | The platform hint bar while it shows. |

**What goes in each zone is config.** `HudZonesConfig.Left` lists every left destination
(`{key, label, icon, color, screen, wide?, hidden?, more?}`). `HudZonesConfig.Offers` lists the
offers. To add a HUD button, add one row and one screen. `Hud.setButtonVisible`,
`setButtonBadge` and `setButtonNew` work by key. The badges of keys inside the MORE flyout roll
up onto MORE (`HudMoreLogic.rollup`).

**Where the zones go is pure maths.** `Widgets/HudPlacement.compute(...)` turns the config, the
canvas, the safe insets, the jump reserve and the minimum tap into rects:
- **Phones (R59):** `computePhone` packs a 2 x 3 grid into the top-left corner under the top bar.
  Each tile is exactly the 44 pt tap tall and 1.35 x as wide (`HudZonesConfig.Phone`). Offers
  shrink to 0.63 x, and WHAT'S NEW becomes an icon-only star.
- **Free screen target:** ≥ **60 %** of the screen must stay free of HUD (`Phone.FreeShare`).
  Measured worst cases: iPhone SE 74 %, iPhone 14 80 %.
- **Desktop player list (R123):** Hud reserves the area of Roblox's player list in the top-right,
  about 252 pt wide plus 41 pt per player. The TopRight row moves left of it, and the offer column
  starts below it.

**Avoiding overlaps.** The HUD publishes its live rects to `Widgets/HudZones` (design px, event
driven). Every overlay must read them before it places itself:

```lua
local HudZones = require(script.Parent.Parent.Widgets.HudZones)
local left = HudZones.rect("Left")                     -- Rect? {x, y, w, h}
if HudZones.overlaps(myRect, "Left") then nudgeRight() end
HudZones.Changed:Connect(relayout)                     -- re-place on any HUD change
```

Zone names: `Left`, `Right`, `Top`, `Bottom`, `TopRight`, `Boosts` and `Hints`. Chips and banners
also avoid:
- the Roblox top-bar buttons (`GuiService.TopbarInset`);
- the thumb zones;
- other chips, through `PopupQueue`: a chip publishes its rect with `setChipRect(kind, rect)`, and
  `chipRects(exceptKind)` returns the others. `HudZones` has no chip zone.

Only the Lucky arrow reads `chipRects` today; `HappyHourChipLogic.place` does not. A second chip in the
phone's top band must pass `chipRects` to its `place` as obstacles, and Happy Hour must be changed to do
the same, or the two can overlap. Test both chips live, on measured zones.

For "is this feature ready?" use `RewardsBadges.forFeature(id)` and its `Updated` signal, not a loop or a
new remote.

When nothing fits cleanly, **hide the element**. Never squeeze it below its readable size. The
Happy Hour pill and the Lucky Button arrow both do this.

**Billboard buttons are not in screen space.** A BillboardGui descendant's `AbsolutePosition` is in
the billboard's own canvas. Project it with `Widgets/ScreenRect.of(object)` before you fly coins or
place feedback (the R61 bug sent coins to the top-left HUD).

`tests/hud-cluster.luau` runs the shipped `HudPlacement` on **15 viewports** (iPhone SE … Fold,
iPads, laptop, 1080p and 4K TVs) x HUD variants. It proves:
- nothing overlaps;
- everything is on screen and below the top bar;
- every touch tap is ≥ 44 pt;
- every desktop / console cell is ≥ `MinButtonSize`;
- the thumbs stay clear.

Extend it whenever the HUD changes.

## 7. PopupQueue: one queue for everything that pops

> R102: "sometimes UI will clip like this when it pops up, need a priority queue."

`Widgets/PopupQueue` is the client's **single** popup queue. Presenters keep their own look, and
the queue decides **when** and **where** each popup shows. There are three channels
(`PopupQueueConfig.Kinds`):

- **center:** the attention lane shows one popup at a time, by priority: plot reveal > flavour
  reveal > Happy Hour start > flavour shout > juice milestone.
  - Lower popups wait (up to `maxWait`, then expire). A higher one pre-empts the current one.
  - Popups wait while a menu window or a cinematic is up.
  - Banners sit in the free band between the currency stack and the objective chip / hint bar
    (`slot.top(height)`).
- **chip:** the Lucky Button arrow and the Happy Hours pill. They hide while a centre popup is up
  and never cover the reserved bottom strip.
- **feed:** the bottom-left column (R108 / R111). Every toast and Big Pop pill stacks there,
  newest at the bottom, at most 4, with repeats merged ("Goal claimed! x3").
  - `feedArea(height)` keeps the feed clear of the left grid, the objective chip, the hint bar,
    the thumb zones and any open window.

```lua
local handle = PopupQueue.request({
	kind = "juice", seconds = 2.4, height = 196,
	show = function(slot) card.Position = UDim2.new(0.5, 0, 0, slot.top(196) + 98); card.Visible = true end,
	hide = function(_reason) card.Visible = false end,
})
-- presenter-driven: omit `seconds`, call handle.done() when finished
-- a hold:           local release = PopupQueue.hold("plotReveal", 170) ... release()
```

There is no per-frame work: one delayed task is armed for the next deadline, and presenters run
in `pcall`. The pure rules live in `PopupQueueLogic` (`tests/popup-queue.luau`) and `FeedLogic`
(`tests/popup-feed.luau`). **Never show a new banner, toast or reveal outside the queue.**

## 8. Juice and animation patterns

Owner R22: every press has a sound and particles. R71: "more fun ... better sound effects, more
visual effects". All of it is cosmetic only and never changes a value.

| Pattern | Module | Rule |
|---|---|---|
| One animation driver | `Widgets/OfferFx` | One `PreRender` connection steps every registered decoration **that is on screen**: drifting header studs, spinning starbursts, rainbow shimmer, button shine. It disconnects when nothing is visible. Low graphics → rate 0; Reduce Motion parks motion. Register with `OfferFx.register(step)`; never add your own RenderStepped. |
| Press feedback | `UI/ButtonFeedback` + `ButtonFeedbackRules` | Every GuiButton gets a sound plus a pooled star / stud / coin burst that orbits, then drops. `Create` binds it, and a `DescendantAdded` fallback catches the rest. Attributes: `FeedbackKind`, `FeedbackColor`, `FeedbackSound`, `FeedbackLocked`, `FeedbackBig`, `FeedbackManual`. The pool is 36; the burst count follows FxQuality (5 / 8 / 12); Reduce Motion plays the sound only. |
| Money flies to the counter | `Hud/CurrencyFly` + `CurrencyFlyRules` (R46) | Pooled sprites (40) follow a bezier curve into the HUD counter, which pops on landing. The count scales with log10(amount). A fly only happens on a real increase and only to a counter that is visible. |
| Fades | `Widgets/GuiFade` | Tweens each element's transparency, then restores the exact values. **No CanvasGroup**: a full-screen group costs about 8 MB of texture on a phone. |
| Window pop-in | `Widgets/ModalShell.popIn` | One reused UIScale tween; instant with Reduce Motion |
| Banners / camera | `Tycoon/Fx/JuiceBanner`, `CameraPunch`, `Fireworks`, `ClickCombo` | Banners go through PopupQueue. A camera punch is an FOV kick plus a small shake, bound only while it runs. |
| Lucky Wheel | `Screens/LuckyWheel/{WheelFx, SpinMotion, WheelDrawing}` | The pure spin curve is in `SpinMotion`. One driver runs only while the wheel moves. The client lands on the slice the server rolled. |

Performance rules for all juice:
- One connection per system, connected only while something animates.
- Every emitter, label and sprite is pooled, with no `Instance.new` per frame.
- Effect budgets follow `FxQuality` (Low / Mid / High).
- Reduce Motion keeps the sounds and drops shake, flash and motion.
- Tunables live in `JuiceConfig`, `CurrencyFlyConfig` and `OfferFxConfig`.

## 9. Icons, brand art and the loading gate

**Icons (owner R9: "rendered instead of flat ... they look 3D").** Every icon (122 keys) is a
chunky, glossy picture with an 18 px dark outline on a transparent 512 x 512 canvas. The sources:
- **Microsoft Fluent Emoji 3D** (MIT, pinned by commit and sha256), with saturation and hue tweaks;
- original **Blender** renders in one soft-toon style (`tools/blender/ui_icons/render_icons.py`);
- composites of the two.

```bash
python3 tools/ui/icons/icons.py fetch | render [--only Key] | sheet | upload [--only K] [--replace K] | moderation | sync | status
open assets/icons/contact-sheet.png assets/icons/contact-sheet-small.png   # R12: show the owner
python3 -m unittest discover -s tools/ui/icons -p 'test_*.py'
```

- `assets/icons/sources.json` is the catalogue. `src/shared/Config/IconAssets.luau` is
  **generated**; never hand-edit it.
- UI code reads icons only through `StudUI.icon(key, size)` and `StudUI.iconImage(key)`. Those use
  pcall, type checks and `rbxassetid://` validation, and fall back to `Kit/Glyphs` while `image`
  is `""` (not uploaded, changed since upload, or rejected by moderation). A regenerated icon file
  therefore needs no UI change.
- Lookup order: exact key → alias (for example the MonetizationConfig product keys) →
  case-insensitive.
- `contact-sheet-small.png` checks every icon at 40 / 56 px (phone HUD) and 96 px (TV distance).
  Every icon must keep a distinct silhouette at 40 px.
- Uploads go through a journalled, idempotent Open Cloud client (`tools/ui/icons/opencloud.py`).
  The key is read from a mode-600 file or an environment variable and is never printed or put on
  argv.
- Other tools in `tools/ui/`: `brand/brand.py` (logo, mascot, key art: `render | compose | upload
  | sync | open`), `sky/`, `build_world_studs.py` and `upload_world_studs.py` (the world stud
  material).

**Loading screen and LoadingGate (owner R16).** The ReplicatedFirst loading screen
(`src/first/LoadingScreen/`) covers the join until all of these are true:
- `game:IsLoaded()`;
- `ClientBooted`;
- the profile has arrived;
- `Workspace.WorldReady`;
- the player's `PlotReady`;
- a real `ContentProvider:PreloadAsync` of the hot assets has run. Pass **instances, never bare id
  strings**: strings report Failure, and meshes fail every time.

It then sets `LocalPlayer.LoadingDone`. `Widgets/LoadingGate.onDone(fn)` is the one place that
answers "is loading finished?":
- the HUD stays hidden until then;
- the plot reveal and the tutorial wait for it;
- a 35 s safety timeout (`HudFocusConfig.LoadingTimeoutSeconds`) means nothing stays stuck.

## 10. Build a new screen end to end

The order is: config → pure logic + test → screen module → HUD entry → controller nav → analytics
"open" → checks → device matrix → docs.

> The "Mailbox" below is an invented example to show the steps. SellNukes has no Mailbox; do not
> look for these files in the repo.

**1. Config** (`src/shared/Config/MailboxConfig.luau`). Put every number here, never inline. Size
the window for phones: short and wide, so text stays ≥ 14 pt after `ModalShell`'s fit.

```lua
--!strict
--[[
	MailboxConfig — tunables for the Mailbox window (owner Rnn). Presentation only.
	Connects to: Client/Mailbox/MailboxLogic, UI/Screens/Mailbox. Example: MailboxConfig.MaxRows --> 6
]]
return table.freeze({
	WindowSize = Vector2.new(1000, 560), -- design px at 1080p; ≤ ~485 tall stays readable on phones
	MaxRows = 6,
	RowHeight = 84, -- ≥ the 44 pt tap at the 0.62 phone floor
})
```

**2. Pure logic plus a Lune test.** Put copy, ordering, states and geometry in an Instance-free
module (`src/client/Mailbox/MailboxLogic.luau`). Test it in `tests/mailbox.luau` with
`fixtures/RobloxLoader` (section 11).

**3. The screen module** (`src/client/UI/Screens/Mailbox/init.luau`). `UIController` finds it;
there is no list to edit.

```lua
--!strict
--[[
	Mailbox — the stud "Mailbox" window (owner Rnn). Shows server-sent gifts; CLAIM sends an intent.
	Connects to: Kit/StudUI, Platform/GamepadNav, Analytics/ClientAnalytics, Shared/Net/Remotes,
	Client/Mailbox/MailboxLogic, Shared/Config/MailboxConfig.
	Example: ScreenManager.open("Mailbox", { source = "hud" })
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local MailboxConfig = require(ReplicatedStorage.Shared.Config.MailboxConfig)
local MailboxLogic = require(script.Parent.Parent.Parent.Mailbox.MailboxLogic)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)

local ANALYTICS_ID = "Mailbox" -- must be in AnalyticsConfig.ClientFunnel.Screens

-- The opener's source ("hud" when the HUD tile opened it); forwarded to analytics.
local function sourceOf(args: any?): string
	return if type(args) == "table" and type(args.source) == "string" then args.source else "hud"
end

return StudUI.modalScreen({
	name = "Mailbox", title = "Mailbox", color = "blue", icon = "Mailbox",
	size = MailboxConfig.WindowSize,
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		local claim = StudUI.button({ text = "CLAIM", color = "green", parent = window.body,
			onActivated = function() Remotes.event("MailboxClaim"):FireServer() end }) -- intent only
		GamepadNav.linkList({ claim.instance }, true, { up = window.closeButton })
		return {
			onOpen = function(args: any?)
				ClientAnalytics.screenOpened(ANALYTICS_ID, sourceOf(args)) -- "open:Mailbox" / "openFrom:Mailbox:<src>"
				claim.setState(if MailboxLogic.canClaim() then "normal" else "claimed")
			end,
			defaultSelection = GamepadNav.defaultSelection(window.body, claim.instance), -- never the X
		}
	end,
})
```

**4. HUD entry.**
- Add one row to `HudZonesConfig.Left` (`more = true` puts it in the MORE flyout and keeps the
  stack at 6), or add an offer row.
- Give the icon key a source in `assets/icons/sources.json`, then `render` and `upload`.
- If something should point the player at the screen, use `Hud.setButtonBadge` or
  `Hud.setObjective`.

**5. Server.** Add the remote to `Shared/Net/Remotes` and connect it with
`Remotes.onServerEvent`. The handler must:
- `typeof`-check every argument;
- validate ids against config tables;
- apply a per-player rate limit;
- check state (owns the plot, in range, ...).

The client never sends amounts.

**6. Analytics and admin.** Add `"Mailbox"` to `AnalyticsConfig.ClientFunnel.Screens`; the test
suite fails on unknown ids. Where it makes sense, register an audited admin command and an
admin-panel control (hard rule 9).

**7. Checks.** Run `./scripts/check.sh`: stylua, selene, strict luau-lsp, `luau-compile` and every
Lune suite. Also extend `tests/hud-cluster.luau` if the HUD changed.

**8. Device matrix.** Only the lead does this, in one Studio pass at the end (builders never touch
Studio):
1. `python3 scripts/studio-lock.py acquire <name>`.
2. Start a solo playtest (never multiplayer).
3. Open the screen: player attribute `DevOpenScreen`, or
   `ScreenManager.open("Mailbox")` via `eval_client_runtime`.
4. Run `capture_device_matrix` with `iphone_14` landscape, `ipad_10th_generation`, `xbox` and
   `hd_1080`.
5. Save the images as `docs/verification/r<N>/<device>.jpg` with a README, then `open` them (R12).
6. Release the lock.

`tools/qa/*.py` scripts wrap this, for example `matrix()` in `tools/qa/attack_view.py`. When the
owner says "code checks only" (R132), skip Studio. Instead, list what the owner should check by
eye.

**9. Docs.** Do all of these:
- add a section to `docs/ui.md` (or the system's doc);
- update `SELLNUKES_CLAUDE_DOCUMENTATION.md`;
- log the request in `docs/owner-requests.md`;
- for player-facing changes, bump `VersionConfig` and add a `ChangeNotesConfig` note (WHAT'S NEW).

## 11. Pure layout logic vs the Instance-building screen

Split every non-trivial UI into two modules:

| Pure logic (no Instances, no services) | Screen / presenter (Instances) |
|---|---|
| Copy, states, ordering, sizes, placement rects, "should this show now" | Builds frames, reads live measurements, connects signals, calls the logic |
| Runs in Lune: `lune run tests/<name>` | Verified with the device matrix in Studio |
| Examples: `HappyHour/HappyHourChipLogic`, `Widgets/HudPlacement`, `PopupQueueLogic`, `FeedLogic`, `Hud/HudMoreLogic`, `Hud/PointerLogic`, `Screens/RewardsHub/HubLayout`, `Screens/AttackTarget/PickerLayout`, `UI/RewardsBadges.evaluate`, `LuckyWheel/SpinMotion`, `Platform/LayoutLogic`, `ButtonFeedbackRules`, `CurrencyFlyRules` | `HappyHourChipScreen`, `Hud`, `PopupQueue`, `HudMoreMenu`, `RewardsHub/init`, `AttackScreen`, `WheelFx` |

**Worked example: `HappyHourChipLogic` (R89 → R92 → R138).** Its functions:
- `chipText(live, nextLive, now, phone, localTime)` returns `LIVE: CONFETTI 3:12`,
  `SPRINKLES IN 15:40`, or on a phone just `0:13`.
- `size(text, phone)` returns 52 design px tall on desktop, tablet and console, and 72 on phones
  (≥ 44 pt tap, ≥ 14 pt text). The phone chip has one fixed width (159 design px, 99 pt), so it never
  jitters while it ticks; a rare longer clock shrinks because the label is TextScaled.
- `place({canvas, safeTop, size, gap, zones, obstacles, phone})` tries candidate spots in order:
  topLeft → topRight → underTop on desktop, and rightOfTop → leftOfTop → underTopRight → underTop on
  phones (underTop sits above the character's head, so it is the last resort). A spot slides down
  past obstacles. The first clear fit wins. **`nil` means hide.** The winner is published as the
  ScreenGui attribute `HappyHourChipSpot`, so a capture can be checked by number. Build placement
  tests from zones measured on a device preset; the first version of this fix passed tests on a
  made-up layout and still sat over the character on a real iPhone 14 (`hard-won-lessons.md` §4).
- `shouldAnnounce(...)` decides on the start banner: once per event instance, deferred (not
  dropped) under the loading screen or tutorial.

The screen only:
- measures (`ScreenManager.canvasSize`, `safeTop`, `HudZones.rect`, `GuiService.TopbarInset`);
- calls `place`;
- draws the result;
- ticks at 1 Hz while a countdown shows.

`tests/happy-hours.luau` proves the copy, sizes, placement and banner rules without Studio. The
general rule: if a bug report is about **where** or **when** something shows, the fix and its
regression test belong in the logic module.

Lune test skeleton (house style: `--!strict`, a header that says what it proves, a counting `ok`
helper):

```lua
--!strict
--[[ Mailbox logic regression (owner Rnn). Run: lune run tests/mailbox ]]
local Loader = require("./fixtures/RobloxLoader")
local loader = Loader.new()
local MailboxLogic = loader.load("src/client/Mailbox/MailboxLogic")

local checks = 0
local function ok(value: any, label: string)
	if not value then error(`{label}: expected truthy, got {tostring(value)}`, 2) end
	checks += 1
end

ok(MailboxLogic.rowText({ kind = "gems", amount = 25 }) == "+25 Gems", "gem row copy")
print(`mailbox: {checks} checks passed`)
```

## 12. Lessons from owner feedback

Each R number is in `docs/owner-requests.md`. These rules recur.

| Owner request | What went wrong | The rule now |
|---|---|---|
| R11 | Consoles and phones are the main platforms | Every screen: ≥ 44 pt taps, ≥ 14 pt text, TV-safe 5 %, thumb zones clear, full gamepad navigation, device glyphs, device-matrix screenshots before "done". |
| R14 | HUD icons "a little bit too big ... come out of the boxes" | Icons sit inside their tiles (`IconFill.Hud` 0.8). Overflow is only a deliberate accent. |
| R16 | Models popped in after the plot reveal | A real loading screen gates the HUD and reveals (`LoadingGate`). |
| R22 | Presses felt dead | A sound and particles on every button (`ButtonFeedback`). |
| R59 | On phones "the cards are just kind of covering the whole screen" | Phone HUD = a tight top-left grid of 44 pt tiles; ≥ 60 % of the screen free, proven in `hud-cluster`. |
| R62, R110 | "a lot of buttons on the left", "there is just a bunch lol" | Fold related features into hubs (Rewards hub) and a MORE flyout. The left stack stays at 6 tiles, and badges roll up. |
| R79 | Menus fought the HUD, and the hint bar covered the wheel | Menus hide the side columns. Window-to-window uses `handoff`. The hint bar sits above the objective chip. |
| R84 | The tutorial arrow pointed at the model, not the button | Point at the exact GuiObject to press (`PointerLogic`), with a highlight ring and the device glyph. |
| R92, R138 | The R92 Studio pass found the first 440 x 96 Happy Hour card far too big; then R138: "takes up a lot of the screen on my iphone" (a third of the width) | **Phones show only the essential value** (the countdown). The banner names the event, and a tap opens the details. Measure in Studio on a real phone viewport. |
| R94 | A button label spilled past its edge | `StudUI.button` shrinks an overflowing label (≥ 60 %). Size buttons for their longest text. |
| R95 | "a lot of UI on the screen ... 1-2 offers at a time" | `MaxOfferSlots = 2`; the rest rotate. |
| R98 | Shop items hard to read on studs | A dark backing plate under item art; contrast ≥ 4.5:1 is tested. |
| R102 | Popups clipped each other | One `PopupQueue` with priorities. Nothing pops outside it. |
| R108, R111 | Big Pop banners and claim toasts covered windows | Toasts and minor announcements go to a compact bottom-left feed, never over a window. |
| R118 | Attack picker labels overlapped | De-collide projected labels (push apart with leader lines, or fall back to a tidy row). |
| R123 | Roblox's player list covered INVITE | Reserve Roblox's own CoreGui areas (player list, top-bar buttons) as obstacles. |
| R127 | The cash counter clipped into the wheel title | Config list `CurrencyHiddenScreens` hides the stack for screens that need the top. |
| R12 | The owner wants to see results | `open` contact sheets and screenshots on the Mac, and list the paths. |

The meta-lessons:
- **Phones are where the UI breaks.** Design phone-first, and treat the 1080p desktop look as the
  expansion.
- **Every new HUD element must claim a zone** and avoid every other zone, CoreGui and the thumbs.
  If it can't, it hides; it never squeezes below readable.
- **Prove geometry in pure tests on many viewports**, then confirm with one device-matrix pass.
- **Quote the owner's words** in the request log, then write a general rule, not a one-off patch.

## 13. Carrying this to another game

1. Copy the framework layer from RoBeasts or SellNukes as-is: `Create`, `Theme`, `Components`,
   `ScreenManager`, `Widgets/{ModalShell, GuiFade, OfferFx, HudZones, HudPlacement, PopupQueue*,
   LoadingGate, ScreenRect, InputGlyph}`, `Platform/*`, `ButtonFeedback*`, plus
   `Shared/Util/{DeviceProfile, TouchLayout, PopupCloseRule}`.
2. Re-skin through config only: `UIStyleConfig` (palette, fonts, geometry), `PanelTextureAssets`
   (the surface texture), `IconAssets` (your icon pipeline), `HudZonesConfig` (your buttons).
3. Keep the contracts:
   - design px at 1920 x 1080;
   - one screen per module, discovered automatically;
   - intents only to the server;
   - every screen with `defaultSelection` and an analytics "open";
   - every HUD element in a published zone;
   - every popup through the queue.
4. Ship each screen with its pure logic test, a device-matrix capture and a doc section.
