# SellNukes UI — the stud kit, screens, HUD

Every SellNukes surface uses the **RoBeasts stud texture** (owner rule 2) and follows the reference
shots in `docs/reference/ui-style/`. Build every screen with **`src/client/UI/Kit/StudUI.luau`**;
never hand-build panels or use Studio GUI objects. Verified look: `docs/verification/ui/*.png`.

## 1. Layers (who does what)

| Layer | Files | Job |
|-------|-------|-----|
| Kit | `UI/Kit/StudUI`, `UI/Kit/Glyphs` | Public style kit (windows, cards, buttons, offers, HUD tiles, money, countdowns, toasts) + fallback icon glyphs |
| Framework | `UI/{Create,Theme,Components,ScreenManager}` | Instance builder, theme constants, low-level button, screen stack / input mode / device layout |
| Widgets | `UI/Widgets/*` | Stud material (`PanelBackdrop`, `StudTexture*`), surface parts (`StudWindow`), shared animation driver (`OfferFx`), `ModalShell` (fit + pop), `GuiFade`, `InputGlyph`, `LauncherStuds`, `HudPlacement` (pure HUD math), `HudZones` (live HUD rects) |
| HUD | `UI/Hud/*` | `Hud` façade + `HudCurrency`, `HudButtons`, `HudOffers`, `HudObjective`, `Toasts` |
| Screens | `UI/Screens/*` | One module per screen, discovered automatically by `Controllers/UIController` |
| Config | `Shared/Config/{UIStyleConfig, IconAssets, HudZonesConfig, InputConfig, TouchUIConfig, DeviceConfig, OfferFxConfig, HudFocusConfig, PanelTextureAssets, PanelStudPixels}` | All numbers / colours / ids |

Boot: `init.client.luau` → `InputController`, `CameraController`, `UIController` (`Init` then
`Start`). `UIController.Start` registers the HUD, discovers `UI/Screens`, sets the `ComingSoon`
fallback and wires gamepad / Studio hooks.

## 2. Build a screen (copy this)

Create `src/client/UI/Screens/Codes.luau` — no list to edit; UIController finds it.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Create = require(script.Parent.Parent.Create)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)

return StudUI.modalScreen({
	name = "Codes", title = "Codes", color = "blue", icon = "Codes",
	size = Vector2.new(900, 520),             -- design px at 1080p; ModalShell shrinks it on phones
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		Create.new("UIListLayout", { Padding = UDim.new(0, 16), Parent = window.body,
			HorizontalAlignment = Enum.HorizontalAlignment.Center })
		StudUI.text({ text = "Follow us for exclusive codes!", textSize = 44, parent = window.body })
		local box = StudUI.textBox({ placeholder = "Code Here", maxLength = 24, parent = window.body })
		local redeem = StudUI.button({ text = "Redeem", color = "green", parent = window.body,
			onActivated = function() Remotes.event("RedeemCode"):FireServer(box.text()) end })
		return {
			onOpen = function(args) box.clear() end,          -- args from ScreenManager.open(name, args)
			defaultSelection = function() return redeem.instance end, -- gamepad start
		}
	end,
})
```

Rules: put content in `window.body` (layouts are allowed there; never add a `UIListLayout` directly
to a studded frame — use its `content` / `body`). Send **intents only** to the server; never show a
value the server did not send. Screens default to `lazy = true` (built on first open).

## 3. StudUI API (exact signatures)

```lua
StudUI.text(o: TextOptions): TextLabel                    -- {text, textSize?, font? "title"|"body"|"number"|"shout", color?, size?, position?, anchor?, align?, wrap?, scaled?, autoWidth?, parent?}
StudUI.icon(key: string, size: number, zIndex: number?): Frame   -- IconAssets image, else Glyphs fallback
StudUI.window(o: WindowOptions): Window                   -- {title, color?, icon?, size: Vector2?, scroll?, onClose?}; Window = {frame, header, body, closeButton, titleLabel, setTitle, setColor, Destroy}
StudUI.modalScreen(spec: ModalSpec): ScreenModule         -- {name, title, color?, icon?, size: Vector2, scroll?, lazy?, build(window, gui) -> ScreenHandle?}
StudUI.card(o: CardOptions): Card                         -- {color? (or "rainbow"), sunburst?, title?, titleSize?, size?}; Card = {frame, content, titleLabel?, setColor, setTitle, Destroy}
StudUI.button(o: ButtonOptions): Button                   -- {text, color?, robux?, productKey? (LIVE price, wins), icon?, size?, textSize?, onActivated?}
    -- Button = {instance, label, setText, setColor, setState("normal"|"locked"|"claimed"|"disabled", text?), state, setRobux(price?), setProductKey(key?), setCallback, Destroy}
StudUI.closeButton(o: {size?, onActivated?, parent?, position?, anchor?}): Button   -- red square X
StudUI.starburst(o: StarburstOptions): Starburst          -- {label, robuxPrice?, productKey? (LIVE price), icon?, size?, onActivated?}; = {instance, setLabel, setPrice, setProductKey, setIcon, setSize, setCallback, pop, Destroy}
StudUI.hudButton(o: HudButtonOptions): HudButton          -- {label, icon, color?, wide?, size: Vector2?, onActivated?}; = {instance, setSize(w,h), setBadge(text?), setLabel, setColor, Destroy}
StudUI.moneyLabel(o: MoneyOptions): MoneyLabel            -- {kind? "cash"|"gems"|"rate", textSize?, icon?, amount?, format?}; = {frame, label, setAmount(n, animate?), amount, Destroy}
StudUI.countdown(o: CountdownOptions): Countdown          -- {endsAt (server unix s), format? "auto"|"hms"|"ms", prefix?, suffix?, doneText?, onFinished?}; = {label, setEndsAt, remaining, Destroy}
StudUI.formatClock(seconds: number, format?): string      -- "02:59:11" / "04:11" / "1d 02:03:04"
StudUI.toast(o: {text, kind? "info"|"success"|"error"|"reward"|"purchase", icon?, parent?}): Frame
StudUI.sectionLabel(text: string, textSize: number?): TextLabel   -- "- LIMITED TIME -"
StudUI.textBox(o: TextBoxOptions): TextBoxHandle          -- {placeholder?, maxLength?, size?, onSubmit?}; = {instance, frame, text, clear, Destroy}
StudUI.robuxTag(price: number?, textSize: number?, productKey: string?): Frame   -- productKey: follows UI/PriceBook (managed price; "..." until known)
StudUI.progressBar(o: {color?, size?, parent?}): ProgressBar      -- = {frame, setProgress(0..1), Destroy}
StudUI.fitWidth(frame, content, padding, maxWidth | () -> number): () -> ()  -- width-to-content without AutomaticSize feedback
```

Buttons ignore a second activation within 0.25 s (one tap never sends two purchase prompts) and
only fire in state `normal`. Countdowns share one 1 Hz thread on `Workspace:GetServerTimeNow()`.

## 4. Colour presets (`UIStyleConfig.Colors`)

| Preset | Use (references) |
|--------|------------------|
| `green` | CLAIM, Redeem, Robux buy, DOUBLE IT!, confirm |
| `yellow` | Shop header, paid spin bundles |
| `red` | close X, Daily header, Starter Pack card, danger |
| `blue` | Codes header, info |
| `sky` | Daily day cards |
| `purple` | gems, premium, purchase toast |
| `orange` | Time rewards cards, Group rewards header |
| `grey` | LOCKED!, OKAY, secondary |
| `white` | Secret Pack card |
| `teal` | Rebirth, Teleport |
| `rainbow` | Day 7 / final cards, Lucky Wheel (shimmers on the OfferFx driver) |

Neutrals (`UIStyleConfig.Neutral`): slate `Body`, dark `Well`, near-black `Edge`, `CashGreen`,
`GemPurple`, `RobuxGreen`. Fonts: Fredoka One (titles / labels), Luckiest Guy (numbers / shouts).

## 5. Icons (rendered 3D icons; pipeline owned by B15)

Every icon is a rendered, 3D-looking icon (Fluent Emoji 3D style + thick dark outline, Blender for
custom ones) — never flat. The icon builder (B15) owns `Shared/Config/IconAssets.luau` and its
pipeline; its agreed shape is `IconAssets.Icons[key] = { image = "rbxassetid://N" | "", size =
Vector2 }` + `IconAssets.get(key)`. The UI reads it ONLY through `StudUI.iconImage(key)` (pcall +
type checks + `rbxassetid://` validation), so a regenerated file needs no UI change.

- `StudUI.icon(key, size)` renders an `ImageLabel` (ScaleType Fit) filling its slot; the
  frame-drawn `Kit/Glyphs` fallback is used **only while `image == ""`** (or the key is missing).
- Slots are sized from `UIStyleConfig.IconFill` so icons poke out of their buttons like the
  references: HUD tile 1.0× its height centred at 40% (overflows the top), wide Lucky Wheel 1.16×,
  window header 1.18×, offers 0.66×, money 1.2×, toasts 0.95×, buttons 0.82×. A rendered `Close`
  icon replaces the text X on every close button once uploaded.
- Keys the kit + HUD use (`StudUI.IconKeys`): Shop, Rewards, Daily, Codes, LuckyWheel, Time, Pets,
  Rebirth, Teleport, Attack, Event, x2Cash, StarterPack, VIP, Spins, Teleporter, SecretPack, Cash,
  Gems, Robux, Close, Star, Check, Lock, Gift, Arrow. Shop cards may pass MonetizationConfig's
  lowercase icon names (cash, gem, spin, crown, egg, ...); Glyphs aliases them for the fallback.

## 6. HUD (`UI/Hud/Hud.luau`)

```lua
Hud.setIncomeSource(fn: (() -> number)?)      -- tycoon client: current $/s (polled 1 Hz + on profile change)
Hud.setObjective(text: string?, target: (BasePart | Attachment | Model | Vector3 | GuiObject)?)  -- chip + arrow
-- R84: a GuiObject target (billboard / touch button) gets the arrow BESIDE it (UI/Hud/PointerLogic);
-- HudObjective.setCallout({ target, build?, sides?, keepClear? }) adds the device-glyph badge.
Hud.setButtonVisible(key: string, visible: boolean)  -- "Attack" (auto when profile.attack.launcher > 0), "Event"
Hud.setButtonBadge(key: string, text: string?)       -- "!" claimable, nil hides
Hud.notify(kind: string, text: string, icon: string?) -- local toast; server toasts arrive via Notify
Hud.focusButtons() / Hud.focusOffers()                -- gamepad D-pad left / right
```

Bottom-right (owner R58): the WHAT'S NEW chip (`Hud/HudWhatsNew`, purple stud button + red NEW
badge while a change note is unseen). `HudPlacement.compute({ corner = size })` reserves it under the
offer column (desktop / console: on the bottom margin inside the TV-safe canvas; touch: just above
the jump-button reserve, ≥ 44 pt tall, text ≥ 14 pt) and returns `layout.corner`; Hud publishes it
as part of the "Right" HudZones rect. Not on the left stack. See `docs/change-notes.md`.

Left buttons / right offers are rows in `HudZonesConfig` (add a row + a screen). Offers read prices
from `MonetizationConfig`; a live id sends `PromptProduct` / `PromptPass`, an unpublished one opens
its screen. Owned passes / bought one-time packs disappear. Overlays that must avoid the HUD read
`Widgets/HudZones.rect("Left"|"Right"|"Top"|"Bottom")`.

**Menus hide the side columns (owner R79).** The left buttons, the offers, WHAT'S NEW and the
objective chip live in one full-canvas `HudRoot/MenuLayer` frame (same coordinates as HudRoot); the
currency stack and the admin chip stay in HudRoot. While `ScreenManager.anyModalOpen()` the layer
fades out (HudFocusConfig timings; instant while the HUD itself is hidden / fading), and back in when
the last window closes (`Hud.menuHidden()` for QA). `Widgets/GuiFade` now settles any running fade on
an ancestor / descendant root before starting one (`finish`), so the layer fade and focus mode's
whole-HUD fade can never snapshot each other's half-faded values.

**Roblox's player list keeps its corner (owner R123).** On desktop (`DeviceProfile` class Desktop,
PlayerList CoreGui on) Hud reserves the top-right area of Roblox's leaderboard, sized in points by
`HudZonesConfig.PlayerList` (≈ 252 pt wide; 60 pt top + 40 pt header + 41 pt per player, players in
the server capped at 8; re-laid out on PlayerAdded / PlayerRemoving) and passes it to
`HudPlacement.compute` as `playerList`. The admin chip + INVITE row moves LEFT of it on the same row
(`chipRect` / `inviteRect` with the `playerListRect`; below it when that would reach the currency
stack) and the offer column starts below it. Phones / tablets / console reserve nothing (the list
is collapsed there). tests/hud-cluster.luau "R123" proves 1 / 3 / 8 players on every device.

**Screens that hide the money counter (owner R127).** While a screen in
`HudFocusConfig.CurrencyHiddenScreens` (today: `LuckyWheel`, whose title sits where the stack is)
is open, `Hud.applyCurrencyLayer` fades the currency stack (gems / cash / rate / boost badge) out
with the R79 fade timings and back in when it closes; `Hud.currencyHidden()` reports it for QA.

**Bottom zone = the real chip (owner R79).** HudZones `"Bottom"` is the objective chip's drawn rect
(it grows upward for the progress bar / a second text line), at least the one-line
`UIStyleConfig.Hud.ObjectiveHeight`, re-published on the chip's own Size / Visible changes. The
gamepad hint bar, attack / knockdown chips, the World rejoin chip and the touch buttons stack above
it — a fixed 64 px had let the hint bar cover the chip's top.

**Window handoff (owner R79).** `ScreenManager.handoff(from, to, args)` opens modal `to` from the
open modal `from`: `from` stays in the modal stack but hides while `to` is open and returns
(selection re-applied to its `defaultSelection`) when `to` closes. Quests GO / Nuke Pass OPEN use it.
Plain `open` for non-modal / unregistered / already-open targets. `ScreenManager.handedOffTo(name)`
answers what a screen is waiting on.

## 7. Mobile, gamepad, accessibility rules

- Design at 1920×1080; `ScreenManager` scales (phone floor 0.62, height-led). Never measure
  `gui.AbsoluteSize` yourself: use `ScreenManager.canvasSize(gui)` / `safeTop()` and re-layout on
  `ScreenManager.LayoutChanged` (a disabled ScreenGui reports a stale size).
- Touch: interactive elements ≥ 44 pt (`TouchLayout.pointsToDesign`); the HUD keeps the bottom
  corners free for Roblox's thumbstick / jump button; windows shrink via `ModalShell`.
- Gamepad: every button is `Selectable`; give each modal a `defaultSelection`; B / keyboard X close
  the top modal (never while typing); D-pad left / right jump onto the HUD columns. With a modal
  open on a gamepad the character pauses so the stick drives the menu.
- Reduce Motion (Roblox setting or `profile.settings.reducedMotion`) and Low graphics park every
  animation (`Widgets/OfferFx`); the world blur behind windows is skipped on Low graphics.
- Unknown screen names open the `ComingSoon` window — never leave a dead button.

## 7b. Platform hooks (B16)

- Actions fire only through `InputController.pressAction(action)` / `releaseAction(action)`
  (called by `Platform/ActionMap` from its ContextActionService bindings and touch buttons);
  `InputController.ActionPressed` / `ActionReleased` listeners are unchanged.
- `ScreenManager.setSafeInsets({ left, top, right, bottom })` (device points) gives every screen a
  "SafeArea" UIPadding (TV-safe 5 % on consoles); a screen module with `safeArea = false` stays
  full-bleed. `canvasSize()` and `safeTop()` already subtract the insets.

## 7c. Press feedback (owner R22)

`UI/ButtonFeedback` (+ pure `ButtonFeedbackRules`, Lune test `tests/button-feedback.luau`) gives
EVERY GuiButton a sound and a pooled particle burst that orbits the button, then drops:
Create binds each button before its handlers (UIController installs the binder before any
screen builds); a PlayerGui DescendantAdded fallback binds the rest; billboard buttons work too.
Attributes: `FeedbackKind` (Stars / Studs / Coins), `FeedbackColor` (UIStyleConfig ColorName),
`FeedbackSound` (Sound key, "" = silent), `FeedbackLocked` (locked sound, no burst),
`FeedbackBig`, `FeedbackManual` (owner calls `ButtonFeedback.fire(button)`: billboard UPGRADE /
CLICK / pad price, so keys and gamepad get the same feedback). StudUI sets kind / colour / locked
automatically. Sounds: ui_click, ui_claim, ui_locked, ui_hover (mouse only, throttled),
ui_open / ui_close (modals). Pool of 36, merge gap 0.05 s, counts by FxQuality tier (Low 5 /
Mid 8 / High 12), Reduce Motion = sound only.

## 7d. Money flies into the counters (owner R46)

`UI/Hud/CurrencyFly` (+ pure `CurrencyFlyRules`, tunables `Shared/Config/CurrencyFlyConfig`, Lune
test `tests/currency-fly.luau`). Cash sprites (the rendered Cash icon; gems use the Gems icon, big
bursts mix in a few twinkling Star icons) burst from the money's source and swoop on a spinning,
shrinking cubic-bezier path into the HUD counter; each landing calls `HudCurrency.land(kind,
reduced)` (icon pops inside its fixed slot, a soft sparkle glints, the number flashes) and plays a
soft `cash_small` tick (gems: `sparkle`) whose pitch climbs during a streak (≥ 0.07 s apart).

| Source | Where from | Sprites (High tier) |
|--------|-----------|---------------------|
| `click` | a producer's pop point, payout right after the player's own click (`IncomePops` → `CurrencyFly.fromProducer`) | 2–4 |
| `tick` | a pop point of a managed / auto-clicker producer, at most one burst / 1.2 s | 1–2 |
| `reward` / `purchase` | HUD safe-area centre, when unexplained cash pairs with a reward toast / PurchaseGranted | 12–20 |
| `offline` | centre, when the WelcomeBack window closes (the claim) | 14–20 |
| gems | centre, on every profile gem increase | 12–20 |

Counts scale with log10(amount) (1 … 1e12), FxQuality Low = ⅓, Reduce Motion = ≤ 3 sprites
rising straight from just under the counter with a fade. World points fly only when on screen,
≤ 180 studs from the camera and no window is open. Attribution (`grantPart` / `onGrant` /
`onHint`): a cash increase is a reward only if it beats the expected income (HUD $/s × time +
recent producer payouts) and a reward toast / PurchaseGranted arrives within 1.5 s / 8 s (either
order). Pool of 40 ImageLabels built at start on the `CurrencyFly` ScreenGui (DisplayOrder 40:
over windows, under toasts; IgnoreGuiInset, no insets, everything `Active = false`), one PreRender
connection only while sprites fly. Other screens may call `CurrencyFly.fromGui(kind, amount,
source, button)` / `fromScreen(kind, amount, source, point?)`. Visual only — never changes values.

## 8. Stud texture notes

`PanelBackdrop` tiles `PanelTextureAssets.StudImage` (the RoBeasts tile, owned by the same user).
`PanelTextureAssets.LocalBitmap = false` by default: this experience has the **EditableImage API
disabled**, and Studio then renders the client bitmap as a magenta/green placeholder
(`docs/verification/ui/90-*.png`). To use the CDN-independent local copy, enable the API in
Experience Settings → Security and flip the flag (`StudTextureLocal` builds 256/128/64/32 mips).

## 9. Dev gallery

Studio only: **F6** in a playtest, or MCP `eval_client_runtime`
`require(game.Players.LocalPlayer.PlayerScripts.Client.UI.ScreenManager).open("UIGallery")`, or set
the player attribute `DevOpenScreen = "UIGallery"` from the server. Shows every component.

## 10. Worlds UI — W5 worlds-ui (owner R57 World 2 "Dino Valley", 2026-10-31)

Spec `docs/superpowers/specs/2026-10-31-world2-design.md` §4 / §9 / §14; plan §3.5. Display +
intents only: the server (WorldService / TravelRules / TycoonService) decides every trip, unlock,
price and payout.

**Boot:** `"Worlds/WorldClient"` in `init.client.luau` ORDERED_NAMES right after
`"Audio/SoundController"` (Start needs the HUD, the screens and the music controller; screens
require the module directly).

| Module | Role |
|---|---|
| `Client/Worlds/WorldClient` | `current()` (Player attr `CurrentWorld`, default `"main"`), `Changed(world, prev)`, `StateChanged()`, `Phase(event)`, `isUnlocked(id)`, `isEnabled(id)` (ReplicatedStorage attr `WorldEnabled_<id>`), `tabs()`, `travel(world, "spawn"\|"area"\|"plot", index?, "menu"\|"popup"\|"chip")` (TravelWorld intent, 1 / s throttle; locked → preview popup, never sent), `previewLocked(id)`. On a world change: Lighting preset (Atmosphere + client-only `WorldTint` ColorCorrection + Ambient; Nuke Town's look captured at boot; **ClockTime never touched**), music (`SoundController.setOverride`), the world's **ambience bed** (`WorldClientConfig.Music[key].bed`: Dino = `amb_jungle`, a soft 2D loop re-triggered every track length from `SoundAssets.LibrarySfx`, stopped on leaving), `Hud.setWorld`, objective chip. WorldTravel `out` opens the overlay + `PreloadList.world` preload; `in` warps in; `fail` toasts `FailText[reason]` (+ locked preview for `locked`). WORLD UNLOCKED popup + rejoin chip at a polite moment (WHAT'S NEW gate + WHAT'S NEW pending + no warp). Teleport NEW tag until the first visit. |
| `Client/Worlds/WorldClientLogic` | Pure: tab model / cycle, fail texts, unlock once-rule (`unlockedAt >= boot − JoinSlackSeconds`), lock hint, `formatAmount` ("4.5M Bones") / `formatRate` ("+1.25K/s Bones"), link lines (spec §6.5), music fallback, preset validation, rejoin rule, NEW dot, throttle. |
| `Client/Worlds/WorldObjectives` | Pure first-run 3-step objective (build → click → hire; arrow = next pad on the way to the manager); nil in Nuke Town / later runs. |
| `Client/Worlds/WorldTabBar` | Shared stud world-tab row (≥ 44 pt, short labels on phones, Lock / Clock corner badges, LB / RB via `GamepadNav.cycler`). Used by Teleport, Rebirth. |
| `Shared/Config/WorldClientConfig` | Lighting presets, Music map, Overlay timings, Tabs, FailText (every TravelReason), Unlock popup copy, Rejoin chip, HUD world-stack sizes, Objectives texts, world Offers. |
| `Screens/Teleport` | World tabs; each open world: spawn row (Hub / Base Camp), areas (locked = previous-area progress), players' plots (Teleporter pass). Nuke Town from inside Nuke Town keeps the legacy instant remotes; everything else = `WorldClient.travel`. Locked tab = hint + area-2 progress; kill switch = "Closed for a quick fix". |
| `Screens/Rebirth` | World tabs; Dino tab: requirement, Bones ×now → after, Amber reward, REBIRTH (`Rebirth("dino")`), Amber shop (`RebirthShopBuy(key, "dino")`), both link lines. |
| `Screens/WelcomeBack` | One row per world with a payout (Cash / Bones), DOUBLE IT doubles every row; Nuke-Town-only payout unchanged. |
| `Screens/Shop` | DINO VALLEY section (`ShopConfig.WorldSections`): Bones packs ×3 + Time Traveler Pack, live PriceBook prices, R39 `Shop_*` models (icon fallback), hidden until unlock / while closed, preselected in the Valley. |
| `Screens/WorldTravel/WorldTravelScreen` | Warp overlay: full-bleed stud cover, counter-rotating stud swirl, ticking clock, destination card; ≥ 1.2 s, safety close 6 s; hop mode for same-world trips; Reduce Motion = fade; modal (controls disabled), B never cancels. `warp_whoosh` (real recording, natural pitch) on open + on a world-change warp-in. |
| `Screens/WorldTravel/WorldRejoinScreen` | "Back to Dino Valley? [GO] [X]" chip above the objective chip for 20 s; gamepad Y = GO (CAS bound only while shown). |
| `Screens/WorldUnlocked/WorldUnlockedScreen` | WORLD UNLOCKED! popup (rotating Time Machine `Hub_TimeMachine`, GO NOW default, LATER) + locked-preview mode ("Reach BoomDash Delivery: 6 / 9 purchases" + OK). |

**HUD (owner R58: no new left buttons):** `Hud.setWorld(id)` — currency stack becomes Gems |
world currency primary (bone icon, cream number) | "+X/s Bones" (Player attr
`IncomePerSecond_<w>`) + a small Cash pill, inside the same Top zone (`tests/hud-cluster` §6);
Attack hides while `features.attack == false`; `WorldClientConfig.Offers[w]` (Time Traveler
Pack) join the offer rotation; the objective chip shows `Hud.setWorldObjective` instead of the
tutorial's. `Hud.setButtonNew(key, on)` = yellow NEW tag (Teleport).
**CurrencyFly:** kinds = "cash" | "gems" | any world currency key (`CurrencyFlyRules.isKind /
iconOf / sound`); `fromProducer(..., kind?)` — W10 passes the producer's currency; Bones grants
(packs) pair with PurchaseGranted like cash; a kind whose counter is hidden never spawns.

**Analytics (W12):** `WorldClientConfig.AnalyticsSource` maps every origin to an allowlisted
ClientFunnel source (menu → `hud`, popup, chip, portal, auto). WorldClient remembers its own last
travel intent for `IntentMatchSeconds`: an `out` / locked `fail` matching it reports that origin,
anything else is `portal` (the server started the trip). `WorldTravel` reports
`screenOpened("WorldTravel", source)`; `WorldUnlocked` reports `screenOpened` + `worldPopup(world,
"shown" | "lockedPreview" | "go" | "later")`.

**Studio check:** `STUDIO_LOCK_OWNER=W5b-ui python3 tools/qa/worlds_ui.py` (lock held; reuses W12's
`world2_check.luau` server half for snapshot / admin / restore + the W5 probe
`tools/qa/worlds_ui_client.luau`): locked Teleport tab, locked preview, auto WORLD UNLOCKED popup,
NEW tag, rejoin chip, Welcome Back rows, warp overlay, Valley HUD / lighting / music / bed,
Teleport / Rebirth / Shop in the Valley, home again; phone / tablet / console matrices + JSON under
`docs/verification/world2/ui/`.

**Tests:** `tests/world-client.luau` (objectives, tabs, presets, ambience beds, analytics origins, every fail reason incl.
`TravelRules.Reasons` when present, rules, config), `tests/currency-fly.luau` §6 (fly kinds),
`tests/hud-cluster.luau` §6 (world stack fits the Top zone).

## 11. HUD pass — owner R59 / R60 / R61 / R62 (W5b, 2026-10-31)

**R62 left stack (all devices):** `HudZonesConfig.Left` = Shop, Pets, Rewards, Rebirth, Teleport,
Attack (Nuke Town only, after the launcher) + Event while live. Daily / Time / Lucky Wheel / Codes /
Group live in H3-hub's Rewards hub (`Screens/RewardsHub`); the Rewards button opens it and wears
`UI/RewardsBadges.badgeText()` (pcall-required; `Changed` re-applies). `Hud.setButtonBadge /
setButtonVisible / setButtonNew` ignore keys that are not stack rows (the folded screens' calls are
harmless no-ops). Admin = `Hud/HudAdminChip`: an icon-only grey wrench square in the top-right
corner (`HudZonesConfig.AdminChip`, Size 64, >= 44 pt on touch), admins only (IsAdmin; an explicit
`Hud.setButtonVisible("Admin", on)` from AdminOverlay still wins), published as HudZones
`"TopRight"`, Down -> first offer; also in the menu wheel for admins (`Platform/MenuWheel`, whose
order follows `HudZonesConfig.Left`).

**R59 phones** (`ScreenManager.device.isPhone` on touch; tablets / desktop / console classic):
`HudPlacement.computePhone` packs the stack as a `Phone.Columns` (2) x 3 grid pinned to the
top-left corner right under the top bar, tiles exactly the 44 pt tap tall and
`Phone.TileWidthRatio` (1.35) wide, `Phone.Gap` (6) apart (`packFixed`); labels keep >= 14 pt
(`StudUI.hudButton.setLabelFloor`, `HudButtons.setLabelFloor`). Offers shrink to
`Phone.OfferScale` (0.63) x OfferSize (never under the tap, shrinking further only for a short
band); WHAT'S NEW becomes an icon-only star square with a red NEW dot (`HudWhatsNew.size(touch,
scale, true)`; press / unseen logic unchanged). The admin chip (`HudPlacement.chipRect`) pushes the
offer column below it on every device.

**R60 one money per world:** another world's HUD shows only its currency + gems (+ its "+X/s"):
the Cash pill is gone (`HudCurrency`, `WorldClientConfig.Hud`). Every world's own balance shows on
its Teleport tab (`WorldTabBar` `balances = true` + `setBalance(id, icon, text)`;
`WorldClientLogic.balanceText`), refreshed on cash / worldCash pushes while open; locked worlds
show none.

**R61 coins flew to the left HUD on UPGRADE:** root cause = `UI/ButtonFeedback` placed the billboard
UPGRADE's "Coins" burst at `button.AbsolutePosition`, which for a BillboardGui descendant is in the
billboard's own canvas (a few hundred px from 0, 0 = the top-left HUD tiles). New
`UI/Widgets/ScreenRect.of(object)` projects billboard descendants through the camera (pure
`ScreenRect.billboard` maths; ScreenGui objects unchanged; works whichever space the engine
reports); `ButtonFeedback.fire` and `CurrencyFly.fromGui` use it. CurrencyFly hardening: targets
come from `CurrencyFlyRules.counterFor(kind, worldCurrency)` (the current world's visible counter;
Cash has none outside Nuke Town) and must be really drawn (every ancestor visible, laid out);
`Rules.isIncrease` keeps spends and world swaps from ever flying.

**Tests:** `tests/hud-cluster.luau` §7 (phones: tile = the tap, grid at (Side, top bar), >= 2
columns, every tile >= 44 pt and at least as wide as tall, clear of thumbs, >= `Phone.FreeShare`
60 % of the screen free) + §8 (admin chip on screen, >= 44 pt on touch, never over grid / offers /
currency / WHAT'S NEW / thumbs) + §6 (no Cash pill config). Worst-case free screen on phones after:
SE 74 %, Android 360 75 %, iPhone 14 80 %, S22 / Pro Max 82 %, Fold 86 % (before ~70 %; the
iPhone 14 stack box went from 452 x 336 to 198 x 225 design px). `tests/currency-fly.luau` §7
(R61: counters per world, spends / swaps / NaN never fly, a reward after a swap still pairs, the
billboard projection incl. both engine conventions, behind-camera and SizeOffset).
**Studio:** `STUDIO_LOCK_OWNER=W5b-ui python3 tools/qa/worlds_ui.py --mode owner`.

## 12. Rewards hub — owner R62 (H3, 2026-10-31)

> "feel like we just have a lot of buttons on the left side"

Daily, Playtime (Time Rewards), Lucky Wheel, Group and Codes fold into ONE HUD **Rewards** button
(section 11, W5b) that opens `RewardsHub` and wears `RewardsBadges.badgeText()`. Nothing was
removed: each feature keeps its own screen, and deep links (Welcome Back, notifications, What's
New CTAs, tutorial) still open those screens directly.

| Piece | Where | What |
|---|---|---|
| Config | `Shared/Config/RewardsHubConfig` | Tile order (Daily, Time, LuckyWheel, Group, Codes, Friends — R78), label / icon / colour / screen / folded `hudKey`, status texts, window modes, tile metrics, badge cap, wake slack, group re-check interval |
| Badge model | `Client/UI/RewardsBadges` | Pure `evaluate(input) → Snapshot` (count / kind / readyAt / changeAt per feature, `total`, `wakeAt`), `statusText`, `formatBadge`, `isFoldedKey`. Runtime `start()` (idempotent), `total()`, `badgeText()`, `forFeature(id)`, `snapshot()`, `recheckGroup()`, signals `Changed(total)` / `Updated(snapshot)` |
| Screen | `Client/UI/Screens/RewardsHub/init` | ResponsiveModal stud window; one tile per feature = the HUD stud tile (`StudUI.hudButton`, own red badge) over a status pill. `lazy = false` only so the model starts at boot; tiles built on first open |
| Layout | `Client/UI/Screens/RewardsHub/HubLayout` | Pure geometry + gamepad links: `grid` (1080 x 740, 3 + 3 since R78) and `row` (1240 x 450, phones) |

**Counts** use the same profile fields + pure config rules as each feature's screen: Daily
`RetentionConfig.dailyStatus(...).canClaim`; Time = ready gifts of `PlaytimeConfig.status` with the
Time Rewards screen's extrapolation; Lucky Wheel = free + bonus spins (`LuckySpinConfig.status`;
bought spins never badge); Group = 1 only when configured, unclaimed and `IsInGroupAsync` says
member (display only, re-checked ≤ every 60 s / on open); Codes = 0 (no client signal).
**Timers**: "Next in 2h 14m" (Daily → UTC midnight, Playtime → the soonest gift else midnight),
"Spin in 14m 05s", or a fixed line ("Join for a gift!", "Claimed!", "Coming soon!", "Enter a
code!"). One wake timer re-evaluates at the soonest change; the open hub re-renders its countdowns
once a second (one loop, only while open).

**Flow / input**: tap / click / A on a tile → `ScreenManager.open(<screen>, { source = "hub" })`
stacked over the hub; the hub window hides while covered; B / X / the feature's close → back to the
hub with the cursor on that tile. Closing the hub (B, its X, or the HUD button again) also closes a
feature screen the hub opened. `ScreenManager.open("RewardsHub", { open = "<FeatureId>" })` opens
the hub with that feature already stacked (the tile's own path; unknown ids ignored). Default
gamepad selection = the first claimable tile, else Daily; top row Up → header X. Touch: tiles ≥ 44
pt, status text ≥ 14 pt (two-line pill). R78 (six tiles, R-social): the pills' UITextSizeConstraint
floor is `HubLayout.textLimits` — 14 rendered px on touch (= 14 pt; constraints count rendered px,
never design px) and the kit's 10 px otherwise, with two lines reserved at
`RewardsHubConfig.Layout.PillLineHeight` (1.35), so every status shows in full on phones
("CLAIM NOW!", "Coming soon!", "Next in 5h / 37m"); before / after captures
`docs/verification/r78-social/hub-6tiles-{before,after}-<device>.jpg`, QA `tools/qa/social_hub.py`
(text bounds vs box per simulated device).

**Analytics**: "open:Rewards" / "openFrom:Rewards:<source>"; each tile open is the feature's own
"openFrom:<Daily|Time|Wheel|Group|Codes>:hub". Tests: `tests/rewards-hub.luau`; Studio QA
`tools/qa/rewards_hub.py` (captures under `docs/verification/ui/rewards-hub/`).

## 13. Lucky Buttons edge arrow — owner R69 (H3, 2026-10-31)

`UI/Screens/LuckyButtons/LuckyArrowScreen` ("LuckyArrow", non-modal, auto-open, displayOrder 6)
points at the nearest Lucky Button (`Client/LuckyButtons/LuckyButtonClient.nearest()`): a round
stud chip in the kind's colour (`LuckyButtonConfig.Kinds[].ui`) with the `LuckyButton` icon
(fallback `Star`) and an orbiting `Arrow` glyph. Off screen / behind the camera → pinned to the
edge (pure `LuckyButtonLogic.arrow`: TV-safe, between the HUD's Left / Right columns, out of the
Top / TopRight HUD zones and, on touch, out of the thumbstick + jump zones); on screen but more
than `ArrowNearStuds` away → floating over the button pointing down; near / any modal / focus mode
→ hidden. One PreRender connection, only while a button is live; nothing selectable. Full system:
`docs/lucky-buttons.md`.

## 12. Player Titles — owner R73 / R74 (W5b, 2026-10-31)

> R73 "Can you give me a name tag whenever I'm in the game so people know I'm the developer?"
> R74: grow it into titles — DEVELOPER, FIRST PLAYER, EARLY PLAYER.

| Piece | Role |
|---|---|
| `Shared/Config/PlayerTitlesConfig` | Catalogue (key = SAVE DATA): `developer` DEVELOPER gold / wrench / `[DEV]` (priority 300, never grantable), `firstPlayer` FIRST PLAYER teal / star / `[FIRST PLAYER]` (200), `earlyPlayer` EARLY PLAYER green / star / `[EARLY]` (100). Permanent holders **by UserId only**: 1586034782 (owner, JusticeTTV1 / "JusticeDev") -> developer; 0 (<player> / "<player>", the first player) -> firstPlayer. 0 is an unrelated "JusticeDev" account: names are never keys. Attributes `Title` / `TitleHidden`, setting `showTitle`, tag tunables. |
| `Shared/Util/PlayerTitles` | Pure rules: `resolve(userId, granted)` (highest priority wins), `canGrant`, `grant` / `revoke` (validated, capped), `newState` / `reconcileState` (profile `titles`: well-formed keys, <= MaxGranted, a newer server's keys kept but never displayed), `shown(title, hidden)`, `chatPrefix(def, existing)`. |
| `ProfileLogic` | `titles { [key] = true }` (private, never in the snapshot) + the `showTitle` setting (allowlisted boolean, default ON). |
| `Server/Services/PlayerTitleService` | Feature service after SettingsService. Sets `Title` (key or "") on join (permanent titles before the profile loads), on every ProfileLoaded (join + New Player Mode swaps) and after grant / revoke; `TitleHidden` from `showTitle`. Registers the audited admin commands **TitleGrant / TitleRevoke** (Players tab, online target, enum of grantable titles; AdminService validates, the handler re-validates). No analytics (the admin audit log records grants). |
| `Client/Social/PlayerTitleClient` | Boot controller. One pooled BillboardGui per visible titled player (PlayerGui, `ResetOnSpawn = false`) on the Head, restyled per title: stud panel in the title colour, icon + label, sized in STUDS like a real name tag (5 x 1.15 studs + a 40 x 10 px floor: shrinks with distance, still >= 14 pt tall at 60 studs on a phone), `StudsOffset` 2.1 (just above Roblox's own name), `MaxDistance` 120, AlwaysOnTop off. The holder sees their OWN tag per title (`TitleDef.showOwn`, owner R77: FIRST / EARLY PLAYER yes; DEVELOPER no, it blocked the owner's view); everyone else always does. `PlayerTitleClient.preview(model, key)` draws a title on any rig (QA "second player" captures / showcase NPCs). Follows respawns, streaming (Head ChildAdded / AncestryChanged), world travel and NPM. Chat: the game's only `TextChatService.OnIncomingMessage` puts the title's coloured chat tag (constant rich text) in front of the speaker's already-escaped PrefixText. Event-driven only. |
| Admin panel | Players tab: Give Title / Remove Title (player picker + title dropdown, from the registered commands). Server tab: "MY TITLE TAG: ON / OFF" chip for a title holder (`SetSetting("showTitle", on)`). |

Tests: `tests/player-titles.luau`, `tests/profile-logic.luau`. Studio:
`STUDIO_LOCK_OWNER=W5b-ui python3 tools/qa/player_titles.py` (one solo playtest; captures in
`docs/verification/player-titles/`).

## 14. Nuke Pass track — owner R78 (P-pass, 2026-10-31)

Screen `NukePass` (`UI/Screens/NukePass/{init, TierStrip, PassView}`), a ResponsiveModal with
modes `wide` 1560×860 and `phone` 1320×620.

- **Top bar:** season and countdown, TIER badge, XP bar, CLAIM ALL (n), and PREMIUM with the live
  PriceBook price.
- **Track:** a horizontal **TierStrip**: the FREE row, tier chips on a stud progress line, the
  PREMIUM row, and a BONUS CHEST column. FREE / PREMIUM labels stay pinned on the left.
- **Footer:** the premium value line.
- **Cards** are StudUI cards (free sky, premium purple, every 5th tier yellow / rainbow) with
  StudUI buttons, in one of these states:
  - CLAIM
  - CLAIMED (veil + Check badge)
  - TIER N
  - UNLOCK (purple, prompts premium)
  - LOCKED! (Lock badge)
- **Gamepad:** the rows are a linked grid (Up → CLAIM ALL / PREMIUM), the strip follows the cursor
  (`GamepadNav.followScroll`), LB/RB page 5 tiers, and the cursor starts on the first claimable
  reward.
- **Juice:** pooled star bursts plus the milestone and coin_burst sounds and a Reward haptic.

The HUD right-column offer `Pass` (`openScreen = true`) opens this screen while a season runs and
premium is not owned. Full system: `docs/nuke-pass.md`.

## 14. HUD boost chips + Friends window — owner R78 (R-social, 2026-10-31)

`UI/Screens/BoostChips/BoostChipsScreen` ("BoostChips", non-modal, auto-open, displayOrder 6):
every active income boost as a stud pill under the currency stack (HudZones `Top`) —
`ROOKIE RUSH 2x 12:41`, `COMEBACK 2x 8:02`, `2x CASH 4:59`, `2x SPEED 1:00`, `SERVER 2x 12:00`,
`FRIENDS +20%`. Compact on phones (`2x 12:41`, the icon names the boost) and whenever a row would
overflow the room between the HUD columns; at most 2 rows. Pure rules: `Client/Social/
BoostChipLogic` (Lune). Publishes HudZones `Boosts`; `Hud/Toasts` starts its stack below it.
Hidden while a modal is open / in focus mode; never selectable; one 1 Hz label refresh only while
a timed chip shows. `UI/Screens/Friends` ("Friends", modal, 1040 x 600): Friend Boost card, INVITE
FRIENDS (gamepad default; SocialService prompt), invite rewards card (n / 10). Opened from the
Rewards hub tile `Friends` (handshake icon). Welcome Back gained the Comeback Rush banner and a
rush-only mode. Full system: `docs/social.md`.

## 15. HUD MORE flyout — owner R110 (U-hud, 2026-10-31)

Owner: "can we cut down on the cards on the left at all? there is just a bunch lol". The left stack
went from 8 tiles to **Shop, Pets, Quests, Rewards, Attack, MORE** — a 2 x 3 grid on every device
(5 tiles / 3 rows while Attack is hidden). **MORE** (blue, Star icon) toggles `Hud/HudMoreMenu`: a
compact slate stud panel beside the grid with **Teleport, Rebirth, Event (only while live),
Settings** — each the same `StudUI.hudButton` tile (stack size, >= 44 pt on touch) that opens its
screen exactly like the old tile (`ScreenManager.open(screen)`, no args: the screens keep their own
analytics ids / "hud" source).

- **Config** (`HudZonesConfig`): `Left` still lists every left destination in menu-wheel order (rows
  with `more = true` live in the flyout; MenuWheel / ComingSoon unchanged). Derived `Stack` (tiles,
  MORE appended last by HudButtons) and `MoreRows` (`more` rows + `MoreExtra` = Settings).
  `MoreTile`, `MoreFlyout` (Pad, PanelColor / PanelTop, PopSeconds / PopScale, analytics ids).
- **Placement** (`HudPlacement.flyout`, pure; `compute({ flyoutCount })` -> `layout.flyout`): right of
  the grid, first row level with MORE (the last stack tile), shapes 1 row -> 2 rows -> 1 column, the
  first that fits the band (under the top bar, above the thumbs / bottom margin) without covering
  the currency stack, offers, objective chip, WHAT'S NEW or the admin chip. HudZones `"Left"` = the
  smaller stack (the flyout is a transient popover, not a zone).
- **API unchanged for callers**: `Hud.setButtonVisible / setButtonBadge / setButtonNew` route moved
  keys (Teleport, Rebirth, Event, Settings) to the flyout items; their badges / NEW tags **roll up**
  onto MORE (`Hud/HudMoreLogic.rollup`: visible children only; one badge verbatim, numbers sum
  capped at 99, else "!"; NEW if any). Attack keeps its unlock + world rules on the stack.
  New: `Hud.setMoreOpen(on, focus?)`, `Hud.moreOpen()`; `Hud.focusButtons()` lands on the open
  flyout's first item, else Shop.
- **Behaviour**: popover, not a modal — a tap / click anywhere else closes it (BoostChips' InputBegan
  marker pattern); gamepad: MORE pressed with a pad selects the first item, the D-pad walks the
  tiles (Left of column 1 -> MORE, other edges stay), moving the cursor elsewhere closes it, **B**
  closes it and returns to MORE (CAS `SellNukes_HudMoreBack` at Priority.Ui + 50, bound only while
  open, sinks before the HUD Deselect). It lives in the R79 MenuLayer and closes when any menu
  opens or focus mode starts. Pop-in via one reused UIScale tween (skipped with Reduce Motion).
- **Analytics**: `open:More` / `openFrom:More:hud` (`AnalyticsConfig.ClientFunnel.Screens` + "More").
- **Tests**: `tests/hud-cluster.luau` §9 (2 x 3 stack + flyout geometry on all 15 devices: on screen,
  level with MORE, clear of every cluster and the thumbs, >= 44 pt / MinButtonSize, no overlaps);
  `tests/hud-more.luau` (config, key compatibility, roll-up, analytics, flyout edge cases).
- **Studio**: `STUDIO_LOCK_OWNER=U-hud python3 tools/qa/hud_more.py` (real clicks on MORE / an empty
  spot / Teleport, roll-up, gamepad + the real B binding, menu closes it; desktop + device matrix
  under `docs/verification/r110-hud-more/`).
