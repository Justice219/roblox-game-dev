# Lucky Buttons (owner R69)

> "some buttons that are like 2x cash that just appear randomly throughout your plot, stuff like
> that, just simple things to make monetization better. Nothing too crazy."

Design spec: `docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md` §1. Owner of
every file below: H3.

## What the player sees

Every few minutes a chunky toy **arcade button** pops up out of the ground at a random free spot
on the player's OWN plot, in whatever world they are in (Nuke Town, Dino Valley, Moon Base, or any
world added later). It has a coloured cap, a light beam to the sky, sparkles, a floating label, and
a "LUCKY BUTTON!" toast. When it is off screen, an edge arrow points to it. Walking into a FREE
button claims it, with any input device; walking into a PAID one opens its small DEAL card (owner
R122, see *DEAL card* below — a walk-in never opens a Robux prompt by itself):

| Kind | Free / Robux | Label | What it does | Weight | Extra rule |
|---|---|---|---|---:|---|
| `cash` | free | "+$1.2K!" / "+1.2K Bones!" | 60 s of that world's income, never less than the current area's first pad cost | 38 | — |
| `boost2x` | free | "2x CASH 2 MIN!" | BoostService `cash2x` +120 s | 14 | — |
| `speed2x` | free | "2x SPEED 2 MIN!" | BoostService `speed2x` +120 s | 8 | — |
| `boost30` | Robux | "2x CASH 30 MIN" + price | DEAL card → BUY prompts product `Cash2x30` | 14 | product live |
| `pass2x` | Robux | "2x CASH FOREVER!" + price | DEAL card → BUY prompts pass `DoubleCash` | 9 | pass not owned |
| `autoclick` | Robux | "AUTO CLICKER!" + price | DEAL card → BUY prompts pass `AutoClicker` | 4 | pass not owned |
| `pack` | Robux | "CASH CRATE!" + price | DEAL card → BUY prompts that world's Large pack (`CashLarge`, `BonesLarge`, ...) | 8 | the world has a live Large pack |
| `skip` | Robux | "SKIP PAD!" + price | DEAL card → BUY prompts `SkipPad` | 5 | the player has a next pad |

Each button lives 45 s and blinks for the last 8 s. A paid button stays until it expires or is
bought. Its DEAL card's BUY prompts at most once every 6 s per button (`PromptCooldown`).

"Nothing too crazy" rules (`LuckyButtonLogic.allowed`):
- At most 2 live buttons per player, and at most 1 of them paid.
- The first button of every session is free.
- No paid buttons in New Player Mode (Robux off).
- A pass the player owns is never offered.
- A product whose id is 0 (coming soon) or that is off sale is never rolled.

## Timing

- **First button:** 45–75 s after the player first stands on their plot in a world.
- **Later buttons:** 120–240 s after the previous button ended (claimed, expired or bought). The
  admin interval multiplier scales both delays.
- **When spawns pause:** never while the player is off their plot (hub, another plot, travelling)
  or has been inactive for 4 min. Activity means the character moved at least 1.5 studs, or the
  player claimed a button or bought a pad.
- **Skipped rolls:** if no kind is allowed or no free spot is found after 12 picks, the roll is
  skipped and the next one comes after a normal delay.

## Placement (server)

**Root cause of the first Studio failure ("no free ground spot" on every roll).** The first
version raycast down onto the plot, but on a frame-built plot nothing is queryable, by design:

- PlotBuilder's invisible colliders are `CanQuery = false` ("never touched / queried by game
  code"). That includes the frame's `Plot_Ground` slab (160 × 4 × 533, top y = 0), walls and props.
- MeshLibrary's visual pieces are inert (`CanQuery = false`).

So every ray missed, and `GetPartBoundsInRadius`-style overlap queries see nothing either. The
world offsets were not the problem: slot frames come from `WorldLayout.slotOrigin(plot, area,
world)`.

**The fix reads the same layout data the plot is built from.** `LuckyButtonLogic.slotGeometry`
works in slot-local space and is pure and Lune-tested. It sorts every box with `slab` and
`classify`:

- **Supports:** colliders whose top lies within 1.25 studs of the ground plane (the frame's ground
  slab, flat lots). Without frame art, the plot ground rectangle is the support.
- **Keep-outs (7 studs, spec):** pads (7×7, even unbought), the producer anchor and click box, and
  both billboard spots.
- **Solids (3.7 studs: the base radius plus air, so never overlapping):** every area collider,
  boxed prop and MeshAssets piece (per piece, bought or not, so nothing ever builds in on top of a
  button), and the frame's colliders (fences, walls). Roofs over a yard count as solids. Boxes
  whose bottom is at least 20 studs up (arch beams) are ignored.

`spotOk` requires the whole button base (2.7 studs) to sit on one support, plus both clearances
and 7 studs from the player's other buttons. `validSpots` pre-computes each slot's valid points on
a 4-stud grid, and the server caches them per (world, plot, area). A roll shuffles the standing
unlocked areas, skipping Nuke Town areas that are knocked down. It takes up to 12 draws per area,
jittered ±1.5 studs and re-verified. The button sits at slot y = 0 of that plot's slot in that
world, so a roll only fails when no standing area has room.

**Real layouts** (tests/lucky-buttons §9) leave room in every non-finale area of Nuke Town, Dino
Valley and Moon Base. The three finale slots are packed and get no buttons. `LuckyStatus` and
`status().placement` report draws, packed areas (`gap`), blocked draws and successes.

## Files

| File | Role |
|---|---|
| `src/shared/Config/LuckyButtonConfig.luau` | Kinds (weights, labels, colours, grants, products, rules), timings, placement, claim, admin attribute names, client look / feel |
| `src/shared/Tycoon/LuckyButtonLogic.luau` | PURE rules: `allowed / eligible / pick / roll`, `productOf`, `packFor`, `delay`, `cashAmount`, `isAfk`, `blinking`, `label`, `box / point / distance / isClear / candidate`, `canClaim`, `validId / readWire`, `arrow` |
| `src/server/Services/LuckyButtonService.luau` | One 1 Hz loop for every player; spawns, expiry, claims, prompts, purchase attribution, admin commands. FEATURE service (boot list, before AdminService) |
| `src/client/LuckyButtons/LuckyButtonClient.luau` | Pooled `Lucky_Button` models, label + Robux price (PriceBook), beam, sparkles; pop / bob / spin / blink in ONE Heartbeat + ONE BulkMoveTo; walk-in claims; claim FX (confetti + coins to the HUD + sound); toast |
| `src/client/UI/Screens/LuckyButtons/LuckyArrowScreen.luau` | Non-modal edge arrow (stud chip in the kind's colour + icon + pointer); PreRender only while a button is live |
| `tools/blender/models/lucky_button.py` | Blender builder `Lucky_Button` (pieces Base / Ring / Cap, 840 tris, uploaded, in `MeshAssets`) |
| `tests/lucky-buttons.luau` | Lune: config vs spec, rules, packs per world, schedule, rewards, placement maths, claims, hostile wires, arrow placement |
| `tools/qa/lucky_buttons.py` (+ `_server.luau` / `_client.luau`) | Studio QA: natural spawn → captures → edge arrow → walk-in free claim → paid prompt |

## Remotes

| Remote | Direction | Payload | Checks |
|---|---|---|---|
| `LuckyButtons` | S→C (owner only, `Remotes.fireClient`) | `{ kind = "spawn", button = Wire }`, `{ kind = "claimed", id, button = kindId, amount?, currency? }`, `{ kind = "expired", id }`, `{ kind = "clear" }` | Client: `LuckyButtonLogic.readWire` (id pattern `L%d+` ≤ 24, kind, finite Vector3, born < expires, world `%w+`, optional amount ≥ 0, product key `[%w_]+` + productType) |
| `LuckyButtonClaim` | C→S | `(id: string, action: string?)` | `RateLimiter` (4 burst, 2/s), `Validate.key(id, 24)` + `validId`, the caller's OWN live button, kill switch. No action = a walk-in: `canClaim` (same world, not expired, server-side character root within 4.5 + 4 studs horizontally and −4..+30 vertically — a Moon 0.4 g jump apex still claims); free kinds grant, **paid kinds do nothing** (R122). Owner R122 `action` (paid kinds only, `Validate.oneOf` against `Deal.Actions`): `"shown"` (canClaim within `Deal.KeepRadius`) / `"close"` = analytics, each capped at `Deal.MaxReportsPerButton` per button; `"buy"` = canClaim within `KeepRadius` + slack, `PromptCooldown`, then the prompt |

Wire = `{ id, kind, world, position, born, expires, amount?, product?, productType? }`. The server
fixes the `cash` amount at spawn and grants exactly that amount on claim.

## Purchases

Paid buttons prompt ONLY from the DEAL card's BUY (`LuckyButtonClaim(id, "buy")`, owner R122). That
prompt goes through `MonetizationService.promptProduct / promptPass(player, key, "lucky")`.
That path applies New Player Mode, the one-open-prompt hold, coming soon, sale windows,
world-locked products, registered refusals (SkipPad) and paid-random policy. `"lucky"` is in
`PurchasePromptConfig.Sources`, so revenue analytics count `prompt:<key>:lucky` and
`purchase:<key>:lucky`. `ProductGranted` and `PassPurchased` retire a live paid button for that
key. If that player's lucky prompt for the same key was within 120 s, the purchase also counts
as `luckyPurchased:<kind>`.

## Analytics (retention family)

`luckySpawned:<kind>`, `luckyClaimed:<kind>`, `luckyPrompted:<kind>`, `luckyPurchased:<kind>`,
`luckyExpired:<kind>` (kinds `cash|boost2x|speed2x|boost30|pass2x|autoclick|pack|skip`), owner R122
`luckyDeal:<shown|buy|close>:<pass2x|autoclick|boost30|pack|skip>` (DEAL card shown on a walk-in /
BUY accepted / closed by the player; walking away or the button ending counts neither). Funnel:
`luckySpawned → luckyDeal:shown → luckyDeal:buy → luckyPrompted → luckyPurchased`. Free
cash grants also count in the economy family as `earn:<currency>:luckyButton`, through
PlayerDataService's grant reason.

## Admin (owner panel, Server tab)

Registered from `LuckyButtonService.Start` with `Lazy.registerAdmin`. ActionsTab renders them;
no UI file changes were needed.

| Command | What |
|---|---|
| Lucky Buttons On/Off (`LuckyToggle`) | Kill switch: `ReplicatedStorage.LuckyButtonsEnabled`. OFF clears every button and stops spawns. Flipping the attribute by any other route also clears |
| Spawn Lucky Button (`LuckySpawn`) | Spawns a kind on a player now. Skips the roll rules but keeps the live cap |
| Lucky Interval x (`LuckyInterval`) | `ReplicatedStorage.LuckyButtonsInterval`, 0.25–10 (presets 0.25 / 0.5 / 1 / 2 / 5) |
| Clear Lucky Buttons (`LuckyClear`) | Removes every live button; spawning continues |
| Lucky Buttons Status (`LuckyStatus`) | Read-only, not audited: on/off, interval, live (paid) / players, and this server's spawned / claimed / prompted / bought / expired counts + R122 DEAL cards (shown / BUY / closed) |

## Client feel, console and mobile

- **Claiming:** walk in with any input. Free kinds retry every 1 s while inside the claim radius.
  Paid kinds show the DEAL card (owner R122) — see below.
- **Reduce Motion:** freezes pop, bob, spin and flashing; the blink becomes a steady glow and
  sparkles are halved.
- **FxQuality Low:** no sparkles, a thinner beam, a third of the confetti.
- **Culling:** buttons beyond `RenderDistance` (450) are unparented, and off-camera buttons skip
  their motion (`ViewCone`). Labels have `MaxDistance` 160.
- **Edge arrow:** stays inside the TV-safe area (SafeArea padding) and between the HUD's left and
  right columns (`HudZones`). It moves out of the top HUD stacks and, on touch, out of Roblox's
  thumbstick and jump zones. Its placement is the pure `LuckyButtonLogic.arrow`, Lune-tested.
  It hides while a modal is open, in HUD focus mode, and when the button is on screen within
  24 studs.
- **Sounds:** `lucky_spawn`, `lucky_claim` and `lucky_blink` come from H1. Until they exist the
  client falls back to `sparkle`, `ui_claim` and `pop`; keys are checked in `AudioConfig` first,
  so there is no warning.
- **Icon:** the toast and arrow use `LuckyButton` from W1b, falling back to `Star` until it ships.
  The arrow swaps the icon in live.

## DEAL card (owner R122)

> Spec `docs/superpowers/specs/2026-11-01-r122-algorithm-pack-design.md` §2.4 ("no accidental
> purchase prompts"). Field data: 0 purchases from ~190 Robux prompts; 10-31 had 30 lucky prompts,
> 20 of them closed in under 2 s — walking into a paid button prompted at once.

- **What it is.** A small non-blocking card at the bottom of the bottom-left feed
  (`UI/Screens/DealCard`, purple): the product art, the button's label as the title (`2x CASH
  FOREVER!`), the product description, a green **BUY** showing the live Robux price and a grey
  **CLOSE**. Only BUY opens the Robux prompt; free kinds are unchanged.
- **When.** Walking into `ClaimRadius` asks PopupQueue's centre lane for kind `luckyDeal` (priority
  60: above the juice banner, below reveals / Happy Hour; waits ≤ 4 s; never over a menu or a
  cinematic; a more important moment ends it and the next walk-in step asks again). It stays while
  the character is within `Deal.KeepRadius` (9 studs: hysteresis, no flicker) and hides past it.
  After CLOSE or BUY (or a menu / another card taking it away) it stays away until the player walks
  out of `KeepRadius` and back in. The button ending (bought, expired, cleared, world change) takes
  the card with it. Pure rules: `LuckyButtonLogic.newDeal / dealStep / dealClosed`.
- **Input (owner R11).** Never auto-focused: nothing on it is Selectable, the gamepad cursor stays
  where it was. BUY = tap / click, gamepad **X** or keyboard **E**, bound **below** every gameplay
  action (`PurchaseFocusConfig.DealKeys.BuyPriority`), so a pad / producer press on the same key
  always wins and **A (jump while running) never buys**. CLOSE = tap / click, gamepad **B**, keyboard
  **X / Backspace** (High priority, only while a card shows). The press that made the card appear
  can never buy (`UI/PurchaseGuard`: a BUY press must begin after the card appeared and ≥ 0.3 s
  later). Phones / tablets: text ≥ 14 pt and buttons ≥ 44 pt at the drawn fit
  (`Widgets/FeedCardMetrics`), clear of the thumbstick / jump zones (the feed area).
- **Server.** A walk-in of a paid button grants / prompts nothing. `"buy"` must come from within
  `KeepRadius` + `ClaimSlack` of the button (the card is still up there), then the usual path:
  `PromptCooldown`, `MonetizationService.promptPass / promptProduct(…, "lucky")`, `luckyPrompted`,
  the 120 s `luckyPurchased` attribution and the retire-on-purchase all unchanged.

## Purchase-focus hygiene (owner R122)

The same spec bullet audits every Robux prompt source so that **no screen opens with the gamepad
cursor on a BUY / Robux button**, **the press that opens a screen can never also buy inside it**,
and **a HUD offer chip tap opens its card first**.

| Piece | What it does |
|---|---|
| `src/client/UI/PurchaseGuard.luau` (+ pure `PurchaseGuardLogic.luau`) | `allow(surface, pressAt?)` / `gate(surface, fn)`: a BUY passes only when the activating press (tap, click, gamepad A, Enter — one `InputBegan` listener) BEGAN ≥ `PressAfterOpen` (0.08 s) after its surface opened and the surface has been up ≥ `ArmSeconds` (0.3 s). Every ScreenManager screen is tracked on `Opened`; cards call `opened(surface)`. `markBuy / setBuy / isBuy` tag Robux buttons (attribute `RobuxBuy`); `safeDefault(list)` never returns one; `landing(obj)` makes a non-buy gamepad stop with the white ring |
| `src/shared/Config/PurchaseFocusConfig.luau` | Guard timings, attributes, the DEAL card look, its keys / priorities |
| `src/client/UI/Screens/DealCard/init.luau` | The shared DEAL card (Lucky Buttons, HUD offers, the golden revenge chip). Args contract in its header; the open card's id is the ScreenGui attribute `DealId` |
| `src/client/UI/Widgets/{ActionCard, FeedCardMetrics}.luau` | The card view + its pure sizing (shared with the invite moment) |
| HUD offers (`UI/Hud/HudOffers`) | A chip press opens the offer's DEAL card beside the chip (pressing it again closes it; it closes itself after 10 s; the rotating slot holds still meanwhile; it closes when the offer leaves the column). Only the card's BUY sends `PromptPass / PromptProduct(key, "offer")`. Counts `open:Offers` (source `hud`) + the offer impression (`popup`) |
| Prompt-source screens | Every Robux intent gated (`PurchaseGuard.gate / allow`), every BUY tagged, every `defaultSelection` through `safeDefault`: Shop (section headings are landings; an open lands on the heading of the target / Starter Pack section, Down enters that card), Lucky Wheel, Teleport, egg hatch (Triple Hatch / Auto), Event shop, Crate shop, Nuke Pass, Welcome Back, attack picker (Barrage), Defense, the attack HUD's GOLDEN chip (now opens the DEAL card) |

**Accidental-prompt causes confirmed in code (2026-11-01):** walk-in Lucky prompts
(`LuckyButtonClient` sent a claim on entry → the server prompted); the Shop's default selection was
the Starter Pack BUY (`preferredButton`) and focus / re-target opens selected a BUY; one tap on a HUD
offer chip fired `PromptPass` (`HudOffers`); the Event shop fell back to its first Robux pack; the
GOLDEN revenge chip / J / R3 prompted in one press; the attack picker's BARRAGE key prompted
unguarded; attack prompts carried no source (now `"attack"`).

**Tests.** `tests/purchase-focus.luau` (config, the guard's rules incl. a randomised soak, default
selection, card sizing floors at real phone scales, source checks of the audited screens),
`tests/lucky-buttons.luau` §10 (DEAL config, `canClaim` radius, the state machine + a randomised
walk, walk-ins never prompt), `tests/popup-queue.luau` (the new kinds in the owner order).

**Studio (lead's pass).** Spawn a paid button (`LuckySpawn pass2x`), walk in: the card shows
(no prompt), X / E / tap BUY prompts, B closes, walking away hides it. Tap the x2 Cash HUD chip:
the card beside the chip, BUY prompts. Console: open the Shop from the HUD with A — the cursor
lands on a section heading, never a BUY. `capture_device_matrix` for the card on phone / tablet /
console.

## Next steps

- Swap the fallback sounds and icon automatically once H1 and W1b land them; no code change is
  needed.
- Tune the weights and intervals from the `lucky*` analytics. The `LuckyInterval` admin command
  allows live A/B on one server.
