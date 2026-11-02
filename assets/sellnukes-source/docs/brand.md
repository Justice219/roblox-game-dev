# Brand package + loading screen

Owner brand package (lead, 2026-10-30): a kid-friendly "SELL NUKES" logo, the Nukey mascot, the
loading-screen key art and a branded loading screen.

**Store thumbnails + experience icon (owner R23):** made by the lead with ForgeGUI (bacon-hair
avatar, trendy "+$/s" / "+1" style) in **`assets/marketing/2026-10-30-forgegui/`**, with the
owner's upload steps there. The earlier Blender-rendered thumbnails and icon were retired and
deleted, so they can't be uploaded by mistake. Every picture uses the same look as the 3D
icon set (`docs/icons.md`): chunky, glossy, candy colours, thick dark outline (UIStyleConfig
TextStroke 20/20/28). Review: `python3 tools/ui/brand/brand.py open` (owner R12).

## Deliverables (`assets/brand/`)

| File | Size | What | Where it goes |
|------|------|------|---------------|
| `logo.png` | 2048 x 838 | Master logo: Nukey leaning in + studded candy "SELL / NUKES" + yellow trefoil badge | Marketing, socials, group |
| `logo-text.png` / `logo-text-1024.png` | 1435 / 1024 wide | Text-only title (no Nukey). Since owner R38 built by `brand.py title` from the ForgeGUI master `logo-forgegui.png` (trim + pad, never upscaled); without the master, from the Blender LogoText pass | Uploaded as `BrandAssets.Images.Logo` (in-game title) |
| `nukey-1024.png` | 876 x 1024 | Nukey mascot (B4's `A8_MascotNukey`, toon-shaded, no pedestal) | Uploaded as `BrandAssets.Images.Nukey` |
| `keyart-1024.png` | 1024 x 576 | Hub key art | Uploaded as `BrandAssets.Images.KeyArt` (loading backdrop) |

### Uploaded Image assets (creator user 1586034782)

| Key | Asset id | File |
|-----|----------|------|
| Logo | 74257284412017 (R38 ForgeGUI title; was 88803775551152) | logo-text-1024.png |
| Nukey | 94122797846575 | nukey-1024.png |
| KeyArt | 110200324437446 | keyart-1024.png |

Generated maps: `src/shared/Config/BrandAssets.luau` (game code) and
`src/first/LoadingScreen/BrandImages.luau` (the loading screen's own copy: ReplicatedFirst runs
before `ReplicatedStorage.Shared` replicates). Both also carry the UI kit's stud panel texture id
(from `PanelTextureAssets`).

## How it's made (reproducible)

```bash
python3 tools/ui/brand/brand.py render              # Blender raw passes -> assets/brand/raw/ (git-ignored)
python3 tools/ui/brand/brand.py compose             # outlines, sizes, key-art grade
python3 tools/ui/brand/brand.py upload --user-id 1586034782 [--replace Logo]   # then sync
python3 tools/ui/brand/brand.py moderation | sync | status | open
python3 tools/ui/brand/brand.py all                 # render + compose + open
```

- **Blender** (`tools/blender/ui_icons/render_brand.py`):
  - **Logo:** Luckiest Guy text extruded and bevelled, then welded and split into one mesh per
    letter, each in its own candy colour. The letters use the shared toon material plus an
    embossed-stud pattern (`render_icons.toon(studs=...)`). Nukey is B4's mascot model
    toon-shaded with its statue pedestal clipped off. The trefoil badge reuses the icon builder.
  - **Hub key art:** a lit EEVEE scene built from B4's real GLBs (`assets/blender/world/`),
    re-materialled with a procedural stud bump (studs on axis-aligned faces), a sky-gradient
    world and a warm sun.
- **Compose** (`tools/ui/brand/brand.py`, Pillow): the disc-dilation outline and premultiplied
  resizes come from the icon pipeline (`tools/ui/icons/icons.py`). The key art gets a toy-bright
  grade.
- **Font:** Luckiest Guy by Astigmatic, **Apache License 2.0**
  (`assets/brand/fonts/LICENSE-LuckiestGuy.txt`). It's pinned from
  github.com/google/fonts@9a936674760330d42e94ba85eec8cd15b8fb9766 and checked by sha256 before
  every render and compose. Roblox also ships it as `Enum.Font.LuckiestGuy`, so the in-game
  fallback title matches.
- **Uploads:** same journaled, idempotent Open Cloud flow as the icons. The key is never printed.
  Each receipt is bound to its sha256, so a changed file needs `--replace`.

## Loading screen (`src/first/LoadingScreen/` → ReplicatedFirst)

Ported from RoBeasts' ReplicatedFirst loading screen pattern, sized for SellNukes.

| Module | Role |
|--------|------|
| `init.client.luau` | Entry LocalScript: `require(script.Loader).run()` |
| `Loader.luau` | Builds the UI, preloads, animates, hands off, cleans up |
| `Readiness.luau` | Pure step / timing bookkeeping (Lune-tested) |
| `Composition.luau` | Pure HUD fit math + progress smoothing (Lune-tested) |
| `Tips.luau` | Kid-friendly tips worded for touch / mouse / gamepad |
| `BrandImages.luau` | GENERATED brand + stud texture ids |

- **Look:**
  - First frame: a sky gradient, then the hub key art fading in with a slow push-in, a tiled stud
    texture and a bottom scrim.
  - Nukey bobs over a pulsing reactor glow.
  - The "SELL NUKES" title pops in. It's an image, with a Luckiest Guy text fallback until it
    loads.
  - A rotating tip card.
  - A chunky stud progress bar with a caption per step and a percentage.
- **Gates the plot reveal (owner R16, "all the models took forever to load in. Make sure
  there's a loading screen before the 'your plot is' shows").** The bar is STAGED and finishes
  only when all of these are true:
  1. `game:IsLoaded()`
  2. `LocalPlayer.ClientBooted`
  3. the profile arrived (`LocalPlayer.ProfileReady`, or `ClientState.profile`, read only after
     ClientBooted)
  4. `Workspace.WorldReady == true` (B4, server)
  5. the player's plot has `PlotReady == true` (the `Workspace.Plots` child with
     `OwnerUserId == UserId`, or the LocalPlayer attribute) (B4)
  6. `ContentProvider:PreloadAsync`, with a real count, over
     `Shared.World.PreloadList.forClient(profile.tycoon)` (hub, plot frame and this player's
     bought builds, B4), plus the hot UI icons and the brand art. Every entry is an
     **instance**, never a bare content-id string (QA 2026-10-30, measured in Studio: strings
     report Failure even for valid images and fail every mesh with "Asset type does not match"):
     images as unparented `ImageLabel`s, meshes as unparented `SpecialMesh`es. The three brand
     labels on screen are preloaded themselves at first paint and fade in on `IsLoaded` **or**
     their Success callback; gated on `IsLoaded` alone they never appeared.

  Then it sets `LocalPlayer.LoadingDone = true` and fades. `UI/Widgets/LoadingGate` keeps the HUD
  hidden and `Tycoon/PlotReveal` waits for that flag.
- **Never stuck:**
  - Shows for at least 2.4 s.
  - After 45 s (= `HudFocusConfig.LoadingTimeoutSeconds`) the caption changes to "STILL
    LOADING... TAP TO CONTINUE". Tap or click anywhere, the big button, or A / Enter / Space
    continues. The button reads PRESS A on gamepads (and is selected), CLICK on desktop, TAP
    on phones.
  - After 60 s it continues by itself.
  - The preload holds the bar for at most 30 s; downloads continue in the background.
- **Safe on every device:**
  - Two ScreenGuis: a full-bleed backdrop, and the HUD with `ScreenInsets = DeviceSafeInsets`,
    so it's never under a notch, the home bar or the Roblox top bar.
  - On consoles and TVs, a 5 % title-safe margin is applied first.
  - One UIScale fits the 1280 x 720 design canvas, with a 0.5x floor on tiny phones.
  - Reduced motion: no bob, pulse, push-in or pop.
- **Talks to the game only through attributes:** it sets `LoadingScreenActive` (true, then
  false), `LoadingDone` and `BootSeconds` on the LocalPlayer. It reads `ClientBooted` /
  `ProfileReady` / `PlotReady` (LocalPlayer), `WorldReady` (Workspace) and the plots'
  `OwnerUserId` / `PlotReady`. No remotes, and no input sink until the TAP TO CONTINUE prompt.
- **Performance:**
  - One RenderStepped connection, disconnected at hand-off.
  - No per-frame Instance creation.
  - Both ScreenGuis fade (CanvasGroup) and are destroyed.
- **Tests:** `lune run tests/loading-screen` (33 checks: stage order, the World / Plot gates,
  the 45 s prompt, the 60 s auto-continue, fit math). Studio: after `rojo serve` picks up the
  `ReplicatedFirst → src/first` mapping, play solo; the screen shows until the HUD has booted.

## Nukey colours (owner R47)
The world model `A8_MascotNukey` uses pastel colours (tuned for Roblox's sunlit world) and the toon
light tone lifts colours 40 % toward white, so the 2D mascot read washed-out on the loading screen.
`render_brand.py` now toonifies Nukey with `NUKEY_PALETTE` (candy red cap, sunny yellow body, lime
band, toy-blue fins; keyed by glTF material name) and a 20 % highlight (`NUKEY_LIGHT_MIX`).
Re-render: `brand.py render --only Nukey && brand.py compose && brand.py upload --user-id 1586034782 --replace Nukey`.
Nukey Image asset `71098170132566` (was `94122797846575`). The loading screen draws Nukey at
ZIndex 2 so the reactor glow always stays behind him. (`logo.png`, the master with Nukey, still has
the old colours until `render --only Logo` is re-run; it is not used in game.)

