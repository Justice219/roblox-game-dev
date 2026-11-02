# SellNukes — visual reference images

Owner-supplied references (2026-10-30). **Inspiration only:** we copy the *feel*, layout language
and the systems they show, never their art, names, or exact layouts. SellNukes is its own
game (a kid-friendly cartoon "nuke factory" tycoon), not a recreation of any other game.

## `ui-style/` — the stud-texture UI every SellNukes screen must follow

| File | What it shows | Take from it |
|------|---------------|--------------|
| `01-daily-rewards.png` | 7-day grid, Day 7 big rainbow card | Coloured stud-tile header bar, red square **X**, dark slate body, tile cards with a stud pattern, CLAIMED / CLAIM / LOCKED! pill buttons, live countdown on the next day |
| `02-shop-limited-time.png` | Shop with Starter Pack / Secret Pack | Yellow header, "- LIMITED TIME -" section label, wide stud-pattern offer cards with sunburst behind the item icons, green Robux price button, "Limited Stock" red label |
| `03-lucky-wheel.png` | 5-slice wheel | Each slice its own colour with a stud pattern, arrow pointer at top, "Next FREE spin in mm:ss", SPIN (xN) green + red X, 3 yellow paid-spin bundles |
| `04-time-rewards.png` | Playtime gifts | Orange stud cards with countdowns, rainbow final card, LOCKED! buttons |
| `05-codes.png` | Codes panel | Blue header, big outlined text, dark text box + green Redeem button |
| `06-group-rewards.png` | Join-group rewards | Orange header, reward icons on a dark card with sunburst, coloured keywords |
| `07-offline-earnings-welcome-back.png` | "Welcome back" offline earnings | Green stud-border frame, huge green money number, OKAY (grey) + DOUBLE IT! (green, Robux) buttons |

Common HUD elements in every shot: left column of square stud buttons (Shop, Rewards, Daily, Codes,
wide Lucky Wheel, Time), right column of "starburst" Robux offers (x2 Speed, x5 Spins,
Teleporter, Starter Pack, VIP) with a green Robux price tag, big cash counter bottom-left
(money-stack icon + chunky green outlined number).

## `sell-lemons/` — tycoon gameplay references

| File | What it shows | Take from it |
|------|---------------|--------------|
| `08-stand-upgrade-overview.png` | Producer with billboard | Per-producer billboard: name, $ per cycle, xN multiplier badge, stud progress bar with cycle time, cyan UPGRADE pill (E key) with cost + level |
| `09-stand-closeup-billboards.png` | Same, close | Small floating "upgrade button" billboards above floor pads: name, effect ("x4 Lemon Stand cash"), price |
| `10-sign-rename-dialog.png` | Rename your shop sign | Text box + red CANCEL / green CONFIRM (filtered with TextService) |
| `11-fence-buy-button.png` | Round buy pad | Chunky tyre-ring pad with a coloured top; colour = category (red = decoration, yellow = multiplier, grey = locked/too expensive) |
| `12-lemondash-tips-billboards.png` | Phase 2 producer | Each phase is a new themed business with its own upgrades |
| `13-lemondash-upgrade.png` | Interior producer | Indoor phase with its own walls/floor that "build in" |
| `14-halloween-sticker-sheet.png` | Seasonal event | Event collection sheet (20 stickers → exclusive reward) — our Thanksgiving event mirrors this idea |
| `15-lemon-depot-manager.png` | CLICK bar + Manager pad | Click-to-produce before automation; "Manager — automates X" pad; teleport + down-arrow nav buttons |
| `16-teleport-menu.png` | Teleport list | Unlocked areas show a teleport button; locked areas show "7 / 8 purchases" progress |
| `17-depot-buy-buttons.png` | Two pads side by side | "x3 Depot cash" multiplier vs decoration pad; "YOU" marker over your plot |
| `18-crypto-mine-cave.png` | Late-game area | Themed sub-area with collectibles on the floor |

Build-in animation (owner description): when a pad is bought, every part of the purchase flies in
from around the player, starts translucent, fades to solid and snaps into place one after another
(LEGO "master builder" style). This applies to **every** purchase.

## `missiles-vs-cities/` — stud-textured nuke models + the side "attack" mode

| File | What it shows | Take from it |
|------|---------------|--------------|
| `19-stud-nuke-silos-launch-panel.png` | Three chunky rockets in gantry frames | Nukes built from **stud-textured blocky pieces** (red/black, mint/black, white/gold tiers); small "Rocket 25 · Lv 75" panel with Launch / +100% DMG upgrade (cash) / gem price |
| `21-silos-hud-wide.png` | Silo pad + HUD | Hazard-stripe (yellow/black) floor tiles, stud roads; HUD with big square icon buttons (Gift, Rewards, Rebirth, Shop, Attack, Allies, Naval, Settings), "2X CASH 15 R$" / "5X DAMAGE 60 R$" quick-buy buttons, gems + cash + $/s at top centre, "Get notified! TURN ON" prompt |
| `22-attack-target-select-island.png` | Choosing a target | Top-down view of an enemy base with ◀ name ▶ selector and CANCEL; target reticle |
| `23-island-base-rocket-launch.png` | Whole base | Island plot with roads, farms, houses, airfield; tall rocket launching with smoke trail; floating "+1.6M" income pops |
| `24-aa-tower-intercept-sky.png` | Defence | AA towers shoot interceptor trails at incoming missiles |
| `25-island-overview-in-combat-barrage.png` | Under attack | Hex **shield dome**, "IN COMBAT — leave now = lose 50% cash" warning, "Send 20 missiles — BARRAGE 45 R$" Robux prompt |
| `26-nuke-reactor-tower-shield-dome.png` | Reactor tower | Grey stud reactor tower with radiation trefoil and hazard ring, hex shield bubble over the base, player name tags |

SellNukes uses this as the **side mode only**: once players own a launch silo they can send cartoon
nukes at other plots for bonus cash; defenders buy and upgrade AA towers and shields. It never
destroys anyone's tycoon progress (kid-friendly: hits pop "boom" FX and steal a small, capped
slice of *uncollected* cash; shields and new-player protection apply).

## `tooling/`

| File | What it shows |
|------|---------------|
| `20-studio-robloxstudio-mcp-v3.2.1.png` | The Studio MCP we actually use: plugin "MCP Server v3.2.1 · github Chrrxs/robloxstudio-mcp" on `http://localhost:58741` (not the old port-3001 MCPBridge). Drive it with `scripts/studio_mcp.py`. Rojo 7.7.1 is connected to "SellNukes localhost:34872". |
