# SellNukes platform layer: console + mobile first (B16)

Owner R11: *"The game is optimized for console and mobile... make sure we have a controller
handler and on mobile the UI doesn't look too bad."* Spec §16, CLAUDE.md rule 11. Every action
has keyboard/mouse, gamepad and touch input. Every screen can be driven with a controller. Every
layout fits a phone, a tablet and a TV. The device matrix is in
`docs/verification/platform/device-matrix.md`.

## 1. Files

| File | Job |
|------|-----|
| `src/shared/Config/PlatformConfig.luau` | **The one action map** (`Actions`, `ActionName`, `Binding`, `ContextName`) plus the hint-bar, touch, safe-area, haptics, menu-wheel and PlayStation-glyph tunables. `InputConfig` re-exports `Actions` / `ActionName` / `Binding` from here |
| `src/client/Platform/PlatformController.luau` | Boot entry (`Platform/PlatformController` in `init.client.luau`, after UIController). Turns `GuiService.AutoSelectGuiEnabled` off and starts everything below |
| `Platform/ActionMap.luau` | Runtime: ContextActionService binding per action, contexts, providers, hint texts, `tap` for touch |
| `Platform/ActionLogic.luau` | Pure: `isActive`, `activeSet`, `hints`, `touchButtons`, `validate` |
| `Platform/HintBar.luau` | `PlatformHints` screen: bottom-centre hints using the active device's glyphs |
| `Platform/GlyphFamily.luau` | Picks Xbox, PlayStation or keyboard glyphs (engine images, with a text-chip fallback) |
| `Platform/TouchButtons.luau` | `PlatformTouch` screen: big StudUI buttons around Roblox's jump button |
| `Platform/LayoutLogic.luau` | Pure: TV insets, jump / thumbstick rects, touch-button arc placement, menu ring |
| `Platform/Haptics.luau` | Rumble presets (gamepad motors) and phone `HapticEffect` |
| `Platform/SafeArea.luau` | 5 % TV-safe inset on console via `ScreenManager.setSafeInsets`; phone notch report |
| `Platform/GamepadNav.luau` | Helpers for screen builders: grid links, scroll-follow, default selection, trap, LB/RB cycler |
| `Platform/NavLogic.luau` | Pure: grid / list links, scroll target, reading order |
| `Platform/MenuWheel.luau` | `MenuWheel` modal: every HUD screen in a ring (View/Select or M) |
| `Platform/JoinFlow.luau` + `JoinFlowLogic.luau` | R78 §6: the ONE join-time attention queue. `request(key, priority, open)` opens queued pop-ups one at a time after the loading screen + plot reveal, in a calm moment (no window / focus / purchase prompt, 1.5 s gap), highest priority first (`FtueConfig.Join.Priority`: Welcome Back 100, tutorial coach 95, ...). During the guided tutorial steps 1–3 only Essential (≥ 90) items open; `guiding()` also hides the Lucky Button arrow and (server) holds Lucky Button spawns; `isQuiet()` / `pending()` for self-polling pop-ups (NotifyPrompt, What's New). Never selectable, never grabs the gamepad cursor |
| `tests/platform-actions.luau`, `tests/platform-layout.luau` | Lune suites (map validity, contexts, priorities, hints, touch, placement, nav math) |

## 2. The action map

| Action | Keyboard | Gamepad | Touch | Bound while (contexts) | Priority |
|--------|----------|---------|-------|------------------------|----------|
| Produce | F | RT (R2) | **TAP!** button | `ManualProducer` | Gameplay 2100 |
| Interact (upgrade / buy) | E | X (□) | **UPGRADE** / **BUY $X** button | `Producer` or `Pad` | Gameplay 2100 |
| UpgradeMode (x1 → x10 → MAX) | Q | Y (△) | **x1** button | `Producer` | Gameplay 2100 |
| GemUpgrade (owner R86: one level for gems) | C | LB (L1) | **GEMS** button (normal, 60 pt) | `GemUpgrade` | Gameplay 2100 (LB is TabPrev only inside menus, Ui priority) |
| Buy (pad you stand on) | (E via Interact) | **A (✕)**, beats jump | (via Interact) | `Pad`, no selection held (A then presses the selected button) | Gameplay 2100 > jump 2000 |
| Hatch | E | X | **HATCH** button | `Egg` | Contextual 2200 (beats Interact) |
| LobbyUse (R99) | E | X | **USE** button, caption = fixture hint ("Spin!", "Group gift", "Codes") | `LobbyFixture` (Client/Lobby/LobbyFixtures) | Contextual 2200 |
| HudFocus | (mouse) | D-pad ◀ | HUD tiles | no selection held | Gameplay |
| OffersFocus | (mouse) | D-pad ▶ | HUD offers | no selection held | Gameplay |
| Teleport | T | D-pad ▲ | HUD tile | no selection held | Gameplay |
| Attack | G | D-pad ▼ | HUD tile | `AttackUnlocked`, no selection held | Gameplay |
| Menu (quick-menu wheel) | M | View / Select (Create) | (HUD) | always, also inside menus | Ui 2900 |
| Deselect | — | B with the cursor on the HUD | — | `Selecting`, no modal | Ui |
| TabPrev / TabNext | Q / E | LB / RB | on-screen tabs | `Tabs` (a cycler is enabled) | Ui |
| Close / Back (ScreenManager) | X / Backspace | B (○) | red X | modal open | High 3000 |
| DevGallery (Studio) | F6 | — | — | Studio | Ui |

Rules (`ActionLogic.isActive`):
- **Menu open → UI navigation only.** Any action without `whileBlocked` is unbound while a modal
  is open.
- **freeNav.** D-pad actions are unbound while a GUI object holds the gamepad cursor, so the
  D-pad moves the cursor instead.
- **Contexts.** An action is bound if any one of its contexts is on. `nil` means always bound.
- **Studio-only** actions are never bound on a live server.

Flow: key or button → CAS (`BindActionAtPriority` only while the action is active) →
`InputController.pressAction(action)` → `ActionPressed`. A press that fires is **Sunk**, so
Roblox's default jump never sees ButtonA while you stand on a pad. Touch buttons call
`ActionMap.tap(action)`, which goes down the same path. `InputController` keeps sole ownership
of the input **mode** and the gameplay-blocked switch.

Rebinding is coalesced: any number of changes in one frame cost one recompute (`task.defer`).
There is no per-frame work.

### Contexts: who sets them

| Context | Source |
|---------|--------|
| `Producer`, `ManualProducer`, `Pad` | Tycoon client (`Tycoon/Interaction`, B2/B6) via `addContextProvider` |
| `GemUpgrade` | Tycoon client (`Tycoon/GemUpgrade`, owner R86) via `addContextProvider`: the own producer in reach is built, below MaxLevel and the admin switch is on; it also sets the caption ("Gem upgrade (75)", "Sure? 75 gems", "Need 75 gems") |
| `Egg` | Pets client (B9) |
| `EventLive` | Event client (B11): also shows the Event tile in the menu wheel |
| `AttackUnlocked` | ActionMap itself (`profile.attack.launcher > 0`) |
| `Selecting` | ActionMap itself (`GuiService.SelectedObject`) |
| `Tabs` | `GamepadNav.cycler` (enabled cyclers) |

### ActionMap API

```lua
local ActionMap = require(script.Parent.Parent.Platform.ActionMap)  -- from a Client/* module
ActionMap.addContextProvider(function(root: Vector3) return { Producer = ..., Pad = ... } end) -- polled 5 Hz, one loop
ActionMap.setContext("Egg", true)                 -- or push a context yourself
ActionMap.setHintText("Interact", "Buy $1.2K")     -- live hint / touch caption (nil = default)
ActionMap.isActive("Produce")                      -- bound right now?
ActionMap.activeSet()                              -- { [name]: true }
ActionMap.tap("Produce")                           -- programmatic press (touch)
ActionMap.Changed:Connect(fn)                      -- active set / hint text changed
```
Studio hook: setting the LocalPlayer attribute `DevPlatformContexts = "Producer,ManualProducer"`
forces contexts on, for screenshots.

## 3. Hint bar (`PlatformHints`, DisplayOrder 44)

The bar is a grey stud pill, bottom-centre, placed just above the HUD objective chip
(`HudZones "Bottom"`). It shows:
- **Keyboard:** contextual hints only, e.g. `[F] Make nukes [E] Upgrade x10 [Q] Amount`.
- **Gamepad:** contextual hints first, then idle navigation hints (`◀ Menus`, `View Quick menu`),
  at most 4. Inside a modal it shows `A Select · B Back`, plus `LB RB Tabs` on tabbed screens.
- **Touch:** nothing, because the touch buttons replace it.
- **Focus mode:** hidden.

Glyphs: `GlyphFamily.glyph(keyCode, h)` returns a keyboard cap or the engine's gamepad image,
which is platform-correct, so PlayStation players see PlayStation shapes. When there is no
image, it falls back to a round chip with ✕ ○ □ △ in PlayStation colours, or A/B/X/Y in Xbox
colours. Studio: `DevGlyphFamily = "PlayStation"`.

## 4. Touch buttons (`PlatformTouch`, DisplayOrder 7)

- **When:** Touch mode, no modal open, not in focus mode.
- **Which:** the active actions that have a `touch` spec. Near a producer that is TAP!, UPGRADE
  and x1. On a pad it is BUY. At an egg stand it is HATCH.
- **Sizes:** 72 / 60 / 48 pt, all ≥ 44 pt, converted with `TouchLayout.pointsToDesign`, so a
  button is the same physical size on every phone.
- **Placement** (`LayoutLogic.placeTouchButtons`): an arc around the real
  `TouchGui.TouchControlFrame.JumpButton`. If that button can't be found, Roblox's default
  geometry is used. The order of preference is left of the jump button, then up-left, then up,
  moving to further rings when needed. Buttons never cover the jump button, the thumbstick zone
  or the HUD button / offer columns. They avoid the objective chip when they can (pass 1) and
  only cover it on tiny screens (pass 2). If nothing is free, they fall back to a column above
  the jump button.
- **On press:** a light `Haptics "Tap"`. Touch buttons are never gamepad-selectable.

## 5. Haptics

`Haptics.play("Tap" | "Purchase" | "BuildComplete" | "Hatch" | "Hit" | "Reward" | "Error")`
- **Gamepad:** small + large motor envelopes (`SetMotor` on the gamepad the player last used).
  A newer buzz replaces the older one.
- **Phone:** a pooled `HapticEffect` (UIClick / UINotification / GameplayCollision /
  GameplayExplosion).
- **Keyboard / mouse:** nothing.
- **Setting:** respects `profile.settings.haptics` (the Vibration toggle; missing counts as on).
- **Rate limit:** the same preset won't restart within 0.12 s.
- **Motors stop** when the window loses focus.

Automatic hooks:
- `PurchaseGranted` and purchase toasts → Purchase
- reward toasts → Reward
- error toasts → Error
- a gamepad Produce → Tap

Still to wire, by the owning builders:
- build-in complete → `"BuildComplete"` (B4)
- hatch reveal → `"Hatch"` (B9)
- nuke hit on your plot → `"Hit"` (B10)

## 6. Safe area

- **Console (ten-foot):** a 5 % inset per side (96 × 54 pt at 1080p).
  `ScreenManager.setSafeInsets` pads every registered ScreenGui (UIPadding `SafeArea`, which the
  AutoScale UIScale scales; verified in Studio). It also shrinks `canvasSize()` / `safeTop()`, so
  the HUD, windows and hint bar re-lay out inside it. A screen opts out with `safeArea = false`.
- **Phones:** Roblox's `DeviceSafeInsets`, which ScreenManager already uses.
  `SafeArea.deviceInsets()` measures the notch inset per side for QA.
- **Studio:** the `DevTvSafe = true` player attribute forces the TV inset.

## 7. GamepadNav: what every screen builder calls

```lua
local GamepadNav = require(<Client>.Platform.GamepadNav)
GamepadNav.linkGrid(cards, 3, { up = tabs[1], down = footer, wrapH = true })  -- NextSelection links
GamepadNav.linkList(rows, true)                                              -- one column
GamepadNav.followScroll(window.body :: ScrollingFrame)                       -- cursor stays in view (padded, eased)
local cycler = GamepadNav.cycler(prevTab, nextTab)                           -- LB/RB (Q/E) while enabled
-- ScreenHandle:
return {
	onOpen = function() cycler.enable() end,
	onClose = function() cycler.disable() end,
	defaultSelection = GamepadNav.defaultSelection(window.body, claim.instance), -- preferred, else first in reading order
}
GamepadNav.trap(dialog.frame)         -- the cursor cannot leave a confirm dialog
GamepadNav.select(button)             -- set the cursor (gamepad mode only)
```

Checklist for every screen:
- a `defaultSelection` that is never the close X when there is content
- grids linked
- scroll lists followed
- tabs on LB/RB
- no hover-only affordances
- tap targets ≥ 44 pt (`TouchLayout.pointsToDesign`)
- text ≥ 14 pt after scaling
- nothing in the thumbstick / jump corners

## 8. Menu wheel (`MenuWheel`)

The menu wheel opens with View / Select, M, or `ScreenManager.toggle("MenuWheel")`. It is a
StudUI teal window holding a ring of HUD-style tiles: the `HudZonesConfig.Left` rows (Attack
after unlock, Event while `EventLive`), plus Settings once that screen exists. The cursor starts
on Shop. A opens a screen (the wheel closes first). B closes the wheel.

Tile size (`LayoutLogic.ringTile`) is square-safe: the closest pair of ring points measured on
X or Y (Chebyshev), minus `TileGap`, clamped to [`UIStyleConfig.Hud.MinButtonSize`, `TileMax`].
The chord overstated the room by √2 for diagonal neighbours, so 11 tiles overlapped (QA
2026-10-30). `PlatformConfig.MenuWheel.Radius = 340` keeps 13 tiles at ≥ 107 px;
`tests/platform-layout` checks that no two tiles overlap for 2–16 items.

## 9. Tests / verification

- `lune run tests/platform-actions` covers the map, contexts, priorities, hints and touch
  buttons.
- `lune run tests/platform-layout` covers TV insets, jump geometry, phone and tablet placement,
  the ring and the nav math.
- `lune run tests/hud-cluster` (QA 2026-10-30) runs the shipped `HudPlacement.compute`, fed like
  `UI/Hud/Hud` feeds it (DeviceProfile scale, jump reserve, TV insets, `minTap`), on 15 viewports
  (iPhone SE … Fold, iPads, laptop, 1080p / 4K TV) × default / all HUD rows × 6 / 1 offers. It
  checks that every left button, offer slot and the objective chip are on screen below the top
  bar, that the clusters never overlap each other or the currency stack (`TopZoneWidth/Height`),
  that touch layouts stay clear of the jump button and the thumbstick ring, that every touch tap is
  ≥ 44 pt on both sides, and that desktop / console cells stay ≥ `MinButtonSize`. The touch
  placement order it pins: beside the currency stack at `MinButtonSize`, then beside it at the
  44 pt tap, then below the stack (up to `TouchMaxColumns`), then below at the 44 pt tap.
- Device matrix: `docs/verification/platform/device-matrix.md`.

## 10. Next steps

- B9: call `setContext("Egg")`.
- B11: call `setContext("EventLive")`.
- B4 / B9 / B10: call `Haptics.play` at their moments.
- Every screen builder: use GamepadNav (the issue lists are in the device-matrix doc).
