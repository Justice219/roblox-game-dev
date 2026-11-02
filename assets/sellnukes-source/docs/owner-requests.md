# Owner requests log

Every instruction the owner gives, in order, with the date. Owner rule (2026-10-30): **"Just
document everything I say."** Append a new entry for every owner message (quote the key words,
then the concrete requirements it creates and where they are implemented). Never delete entries;
mark superseded ones instead.

---

## 2026-10-30 — Session 1 (project kickoff)

### R1. Build SellNukes
> "I want you to build a game called SellNukes. It's going to be a Roblox Tycoon game."

- A Rojo project already synced to Studio; an MCP server connected to Studio.
- **Use the RoBeasts project** ("Robust"/"Ruby" in voice transcription = RoBeasts) as the example:
  "use all of the documentation, stuff like that, same development framework". The only difference
  is that this is a tycoon.
- **8 players** per server.
- **Same stud-texture UI as RoBeasts**, for the **entire game**.
- **Use Blender to model the entire tycoon**, so it doesn't look grey/primitive. Reuse the RoBeasts
  import-to-Roblox framework.
- **Linear tycoon:** step on buttons to upgrade, little billboards, "selling nukes": a nuke factory
  that starts as a little garage with a nuclear reactor and grows into a massive nuclear facility.
- **Money-per-second game**, starting with clicking something (like Sell Lemons, where you click
  the lemon stand), then upgrading, eventually automating.
- **Very kid-friendly.**
- **The tutorial is built into the first part:** clicking to build, then buying things.
- **Monetization and game passes, "as much as possible":** 2x boosts, money buying, etc.
- **Eggs/pets system and crate system** for depth.
- **Daily rewards** and similar.
- Follow the attached **example UI** (daily rewards, shop, lucky wheel, time rewards, codes, group
  rewards, "Welcome back" offline earnings): a beautiful, animated, multi-coloured stud UI, and the
  terrain should match.
- **"Everything needs to be modeled in Blender though"** and imported.
- Come up with the development plan, use the exact same framework as RoBeasts, start building,
  "do everything as much as possible right now".
- **At least 8 hours of gameplay** → lots of areas.
- **Start a Thanksgiving event** (Halloween will be over by launch).
- Sell Lemons references: **offline earnings**; **each phase is a new thing** (lemonade stand →
  "Lemon Dash" delivery (DoorDash parody) → factory, ...).
- **Build-in animation for every area and every button:** when you buy walls or areas, all the
  pieces float in and build in front of you, like the LEGO games' master builders. Parts come in
  translucent, fade in, and assemble.

→ Spec: `docs/superpowers/specs/2026-10-30-sellnukes-design.md`; plan:
`docs/superpowers/plans/2026-10-30-sellnukes-build.md`.

### R2. Save the reference photos
> "you save these photos so you can reference them? Save them somewhere in the project."

→ `docs/reference/` (ui-style, sell-lemons, missiles-vs-cities, tooling) + annotated `README.md`.

### R3. Missiles vs Cities reference: nuke models + attack side mode
> "a really good example of like the nuke models from a different game called Missiles vs. Cities"

- In it you build a base for money per second, buy nukes, upgrade them, and blow people up for
  money: an AFK nuke system. **Add that too**: eventually you can nuke people "just for fun", and
  put up **AA towers** and upgrade them. **Not the primary point of the game; a side thing.**
- Use its **stud-textured nuke models** as the style reference. Save these photos too.

→ Spec §9 (Attack mode, kid-friendly: the target never loses anything); images in
`docs/reference/missiles-vs-cities/`.

### R4. Use the correct MCP
> "You're using MCP, look at this. It's a different MCP than the one I think you're trying to use.
> Make sure you note that down."

- The Studio MCP is **`@chrrxs/robloxstudio-mcp` v3.2.1** (the "MCP Server" plugin, `localhost:58741`),
  not the old port-3001 bridge.

→ `scripts/studio_mcp.py`, `CLAUDE.md` §"Roblox Studio MCP", memory `reference-robloxstudio-mcp`.

### R5. Full autonomy
> "I want you to be completely autonomous developers, so whenever I give you input, you use it,
> you don't ask me any other questions, you get it done, remember that."

→ `CLAUDE.md` hard rule 1; memory `feedback-full-autonomy`.

### R6. Analytics + admin panel
> "we also need a fully in-depth analytics system to track as much data as possible. So look at how
> [RoBeasts] does it. We also need an admin panel built in that I have access to as the owner of
> the experience."

- In-depth analytics modelled on RoBeasts' analytics (track as much as possible).
- An in-game **admin panel**, accessible to the experience owner (user 1586034782).

→ Spec §13 (analytics) and §14 (admin panel); plan wave assignments.

### R7. Subagents
> "you can use as many subagents as you need as well."

→ No cap on builder count; parallelise wherever file ownership allows.

### R8. Document everything
> "make sure you document, put that in your notes as well. Just document everything I fucking say."

→ This file (append every owner message), plus memory `feedback-document-everything`.

### R9. 3D-looking rendered icons (like RoBeasts)
> "make sure we do like the 3D icons kind of. If you look at how [RoBeasts] has the icons, they're
> kind of like rendered instead of like flat. They're not exactly 3D rendered icons, they're just
> like kind of, they look 3D."

- Every UI icon (HUD buttons, currencies, offers, rewards, shop items, pets/eggs/crates, event) is
  a **rendered, 3D-looking icon** (chunky shaded cartoon objects with outline + highlights, like the
  reference UI and RoBeasts' Blender-rendered HUD icons), never a flat glyph.
- Pipeline = RoBeasts `tools/blender/ui_icons/render_hud_icons.py` + `tools/ui/hud_icons.py`
  (render → upload → sync to `IconAssets.luau`).

→ Builder B15 (icons); spec §6 note; `docs/icons.md`.

### R10. Continue after the account switch
> "continue" (after `/login` to a different account, because every builder hit the weekly usage
> limit at 18:20 UTC on the first account)

- Resume every interrupted builder from where it stopped; no work is discarded.
- Serena MCP became available in this session: use it for file/symbol operations where possible
  (owner global rule "MANDATORY: must use Serena for any file operations if at all possible").

### R11. Console + mobile first
> "The game is optimized for console and mobile. So like, we need to make sure we have a controller
> handler and on mobile the UI doesn't look too bad."

- **Console (gamepad) and mobile (touch) are the primary platforms**; keyboard + mouse still works.
- A real **controller handler**: every action has a gamepad binding (produce, upgrade, buy, open
  every menu, navigate HUD, close/back, teleport, hatch, launch), every screen is fully navigable
  with `GuiService.SelectedObject`, on-screen button hints show the right glyphs, TV-safe margins,
  haptics on key moments.
- **Mobile UI must look good**: phone + tablet layouts, ≥ 44 pt tap targets, readable text at
  phone scale, nothing covered by the thumbstick/jump button, landscape safe insets.
- Every screen is verified with the Studio MCP `capture_device_matrix` (phone, tablet, console)
  before it is reported done.

→ `CLAUDE.md` hard rule 11; spec §16; builder B16 (platform: controller handler + device QA);
broadcast to every UI builder.

### R12. Show finished art by opening the image files
> "any of the modeling agents finish their art, please show me. Whenever they do, so I can see it.
> Like, have them just open images. Open the files, though. Don't just [only list paths]"

- Whenever a modeling/art agent finishes (or produces a notable preview/contact sheet/Studio
  screenshot), **open the image files on the owner's Mac** (`open <file>` → Preview) so the owner
  sees them immediately, in addition to listing the paths.
- Applies to every art builder (areas, hub, pets, icons, build-in captures) and to the lead when
  relaying their reports.

### R13. Lobby + random plot selection
> "since we're going to have 8 people, we need a lobby. Like, in the lobby, it's just like a ...
> random selected plot system between 8 different plots."

- The central **Hub is the lobby**: every player spawns there.
- On join the server assigns a **random free plot** (uniform among the free plots, not
  first-free); returning players also get a random free plot in the new server (plots are per
  server; their saved tycoon is rebuilt on whichever plot they get).
- Short reveal: "Your plot is #N!" banner + camera swoop to the plot, then the player is
  teleported to their plot entrance (skippable; gamepad/tap). Hub pads teleport back to your plot.

→ Spec §4 updated; B5 (`B3-tycoon`) PlotService, B6 (`B2-ui`) reveal UI, B8e hub spawn.

### R14. HUD icons a little smaller
> "that icon should be a little bit smaller. They're a little bit too big. Some of them kind of come
> out of the boxes on the left." (screenshot of the live HUD in Studio)

- Left HUD button icons are scaled down so they sit inside their stud tiles (only a slight,
  intentional overflow at the top), matching the reference daily/shop screenshots.

### R15. (Repeat of R12) Show the art
> "any of the modeling agents finish their art, please show me... have them just open images. Open
> the files, though."

- Re-stated by the owner; R12 stands. Lead opened every in-progress render available at the time
  (pets lineup, eggs, attack props, crates/event items, areas 1–3, 9, 10 contact sheets) and will
  keep opening each builder's best shots as they finish.

### R16. Loading screen before the plot reveal (models loaded slowly)
> "make sure there's a loading screen into the game, because ... I loaded into the game and like all
> the models took forever to load in. So make sure there's a loading screen before that little like
> your plot is shows."

- A branded loading screen covers the join until the world is genuinely ready: client booted,
  profile synced, the lobby + the player's own plot built and their meshes downloaded (staged
  progress bar, tips, safe skip after a long timeout).
- Only after it fades does the "Your plot is #N!" reveal play; the server waits for the client's
  `PlotRevealDone` (with a generous fallback) before teleporting.
- Model loading itself gets faster: server MeshLibrary loads the lobby, plot frame and area-1
  templates first with higher bounded concurrency, publishes `WorldReady` / per-plot `PlotReady`,
  and the client preloads those mesh assets during the loading screen.

→ B15 (loading screen, `src/first`), B4 (MeshLibrary load order/concurrency + readiness signals
+ client preload list), B2 (reveal waits for loading), B3 (server reveal fallback).

### R17. Backward text on the Garage Lab arch
> "text in front of the garage lab is backward." (screenshot: the A1 entry arch reads "BAJ 3ƎAЯAƎ"
> from the road)

- Every sign/text built into a model must read correctly from where players actually look at it:
  entry-arch signs are **double-sided** (correct on both faces) and every text mesh is checked in
  a preview rendered from the player's viewpoint (road side). Applies to all areas, the hub and any
  future text geometry.

→ B8a (Area01–03 signs), B8b/B8c/B8d audit their signs, B4 World-QA checks text orientation.

### R18. Prevent z-fighting (use the RoBeasts technique)
> "use the z-clipping thing that [RoBeasts] has to prevent z-clipping, because I just sent you a
> screenshot of some z-clipping." (screenshot: Garage Lab interior/floor surfaces flickering)

- Port RoBeasts' z-fighting prevention to SellNukes and apply it to every world builder
  (PlotBuilder, HubBuilder, MeshLibrary spawns, Blender models): no two visible surfaces may be
  coplanar; stacked floor layers get deterministic small offsets; tests catch regressions.

### R19. Glowing things must not be overly bright
> "this glow lamp upgrade that I got is like super bright. Make sure that when you do like anything
> glowing, we make sure it's not overly bright." (screenshot: the scene washed out by glow/bloom)

- Global rule: glows are soft accents. Neon only on small accent pieces; PointLights dim and short;
  bloom/exposure tuned so nothing blows out; a lint/test caps light brightness/range and Neon area.

### R20. A button to open the admin panel
> "not sure if the admin panel was built yet. If it wasn't, that's fine, but make sure there's a
> button for me somewhere on the screen to open it."

- The owner (and admins) always see an ADMIN button on the HUD that opens the panel (F2 / D-pad
  down also work).

### R18b. More z-fighting on the roads
> "more examples of zclipping on the roads." (screenshots: crosswalk stripes / road pieces where
> the plot road meets the ring road at the plot entrance)

→ added to B8e's z-fight audit + fix scope (plot frame, ring road, crosswalks, road dashes).

### R21. Faster running + wind effect
> "make the player run faster. They feel a little too slow and add like a wind effect on the screen."

- Higher base WalkSpeed (server-set, config-driven), still stacking with the Fast Walk pass and
  speed boosts.
- A screen wind effect while running (speed lines / wind streaks + soft whoosh, scaled by speed),
  cheap on mobile/console, respects reduced motion.

→ B13 (MovementService + WindController).

### R22. Particles + sound on everything
> "make sure as well that everything has particle and sound effects... whenever you click like the
> upgrade button and stuff, you hear a sound effect and you see particles. Particles that like spin
> around the button. Or like drop down from the button would be good."

- Every interactive element (every StudUI button, HUD tile, offer, claim/buy/upgrade, billboard
  UPGRADE/CLICK, pads, tabs, toggles) plays a sound (`Client.Audio.Sound`) and a particle burst:
  stars/studs/coins that orbit around the button or drop down from it, colour-matched, pooled,
  reduced-motion aware. Port RoBeasts' `ButtonFeedback` (+Rules) for UI; world buttons get 3D/
  billboard bursts.

→ B2 (UI + billboards; ButtonFeedback port), B4 (world/pad FX already: confetti + ka-ching).

Lead also noticed in the same screenshot: Rojo cannot live-swap `Lighting` when
`default.project.json` changes ("Could not swap instances Lighting"), so the R19 lighting values
were applied directly in Studio edit mode as well (matching the project file).

### R23. Thumbnails + icon via ForgeGUI, trendy style, bacon-hair avatar
> "use the [ForgeGUI] API key that we have in the [RoBeasts] project to make the thumbnails
> instead, because it actually knows how to make the thumbnails. And then go on the Roblox webpage
> and actually use like trendy thumbnails and a trendy game icon. I would prefer that you use like
> the bacon skin as well, like the default bacon model for like the guy on the thing. Make sure we
> use like the +1 second or like +999 a second, you know, trendy vibe."

- Supersedes the Blender-rendered thumbnails/icon from B15's brand pass (keep the in-game logo).
- Generate the experience icon + store thumbnails with **ForgeGUI** using the RoBeasts project's
  ForgeGUI key (never printed/committed).
- Research what's trending on roblox.com (top/trending tycoons & simulators) and match that style.
- Feature the classic default "bacon hair" Roblox avatar; trendy "+1/sec", "+999/s" money-number
  vibe; kid-friendly cartoon nukes; SELL NUKES title.

→ B15 (brand).

### R24. Hedge going through the garage
> "There's like a hedge or something that's like going through the garage." (screenshot: a green
> hedge/bush block intersecting the Garage Lab wall/driveway)

- Remove/relocate the intersecting hedge; add an intersection check (visible pieces of different
  builds/base/plot-frame/scenery may not interpenetrate) to the static layout audit.

→ B8a (Area01 layout) + B8e (plot-frame scenery / plotDecor), audit in B8e's ZFight/overlap test.

### R25. Rocket on the car doesn't move with the car
> "this little like rocket on top of the car in the garage when you buy it does not like go up and
> down with the [car] for some reason." (screenshot: A1_NukeMobile in the Garage Lab)

- Animated pieces must move as a unit with everything attached to them: world FX animates a
  piece's attached group (e.g. the NukeMobile body + its roof rocket bob together), never one piece
  of an assembly alone.

→ B4 (WorldFx grouping rule) + B8a (A1_NukeMobile piece naming).

### R26. Nuke Stand toy nukes: caps offset from bodies
> "this SellNukes stand, the little models that go up and down, are like not a part... those little
> caps... they're like offset" (screenshot: Area 2 Nuke Stand counter; white cone caps float beside
> the coloured bodies)

- Same root cause as R17 (the 180° import yaw: each piece spun in place, so caps land off their
  bodies) plus R25 (pieces of one assembly bobbing separately). Fixed by B4's MeshLibrary yaw fix +
  WorldFx motion groups; B8a verifies the stand nukes read as one toy each.

### R27. Tutorial guide: arrows instead of a line
> "Instead of having a line draw to like where the player needs to go, make like a little arrow
> effect instead of just like a [line/beam]"

- Replace the tutorial guide beam with a trail of animated chevron arrows on the ground flowing
  from the player toward the target (pooled, path-aware where possible, fades near the target),
  plus the existing bouncing arrow over the target. Respects reduced motion (static arrows).

→ B2 (Tutorial.luau guide beam).

### R28. Thumbnails are great — make 5 more
> "you fucking cooked on the thumbnails... they look really good. Let's make some more. I want like
> 5 more... Those thumbnails look trendy as fuck."

- Owner approves the ForgeGUI style (bacon hair, "+$/s", "+1", NOOB/PRO). Make 5 more in the same
  style, each a TRUE game feature: SECRET pet hatch, DAY 1 vs DAY 100, launch toy nukes at friends
  (confetti, AA towers), "watch it build itself" (LEGO build-in), the Space Port / Mega Facility.
  (Plus the Harvest Feast seasonal one already generating.)

### R29. 10 ad creatives
> "Also need you to make 10 ad thumbnails as well that are gonna be run for the ads. So we have the
> experience ones now, but I need 10 for the ads."

- 10 paid-ad creatives (separate from the experience-page thumbnails), in Roblox Ads Manager's
  required sizes/specs, same trendy ForgeGUI style (bacon hair, "+$/s", "+1"), each with a clear
  hook + call to action, true to the game, kid-friendly. Delivered in
  `assets/marketing/2026-10-30-ads/` with a manifest.

### R30. Hired managers must be alive (animated NPCs)
> "I do want like the little NPCs that you hire to like automate things like this Uncle [Atom] guy.
> To actually like move around and be animated and not just a still prop."

- Every Manager (Uncle Atom, Cashier Bot, Dispatcher, Foreman, Head Scientist, Factory Boss, Launch
  Director, Store Manager, Flight Director, Chief Engineer) is an animated NPC: idles, walks a short
  work loop between its producer and nearby stations, does a "working" action at the producer each
  cycle, waves/turns toward the owner when near. Client-side, culled, pooled.

### R31. Nuke Stand upgrade billboard clips into the awning
> "the upgrade GUI for the nukestand also clips"

### R32. Glow Rock Mine billboard too high to see
> "the Glowrock Mine GUI as well is really hard to see just because of how high it is."

- Rule for every producer billboard: anchored in clear space in FRONT of the producer (toward the
  road), at a readable eye-level height (clamped), never inside geometry; income pops must not
  overlap the billboard text.
- → Implemented 2026-10-30 (N2): `Tycoon/BillboardPlacement` solver + generated
  `Shared/Config/BillboardSpots`, audited for all 10 areas by `tests/billboard-clearance.luau`
  (never covers the producer or its manager from the player stands, never inside geometry incl.
  the A2 awning, readable height); see `docs/tycoon-client.md` §3a.

### R33. Never open new Studio places
> "some of the subagents keep opening different places in Roblox. We are connected to MCP. They do
> not need to be opening new places from the build file."

- Agents must ONLY use the already-open, MCP-connected place ("Sell Nukes [🎃]", placeId
  132667741281890) through `scripts/studio_mcp.py`. Never `open`/launch a `.rbxl/.rbxlx` from
  `rojo build`, never `manage_instance` action=launch, never start another Studio process.
  `rojo build` is allowed only as an offline check (never opened). → CLAUDE.md hard rule 12.

### R34. Configure the Creator Dashboard and upload store artwork (2026-10-30)
> "use @Chrome to setup all the information for our sell nukes tycoon on the creator dashboard. upload the iamges from - Store page thumbnails and icon: SellNukes/assets/marketing/2026-10-30-forgegui/final/. It has icon.png (512×512), thumb-1 through thumb-9 (1920×1080), and the alternates."

- Use Chrome to configure the existing SellNukes experience (universe 10773845696, start place
  132667741281890), using the approved game design and current config for truthful listing copy.
- Upload the primary icon and nine numbered thumbnails from the requested folder; preserve
  alternate artwork for deliberate alternate slots/testing rather than replacing the primary icon.
- Track draft copy, upload order, verified dashboard changes and any blocker in
  `docs/creator-dashboard.md`; no dashboard action is complete until read back from Chrome.

### Creator Dashboard follow-ups (2026-10-30)
> "try again @Chrome"; "try @Chrome now"; "try @Chrome now"

- Retry the authorized Creator Dashboard setup after the owner reconnects Chrome.

> "the title should just be Sell Nukes"

- Set the experience title to exactly **Sell Nukes**, with no suffix or emoji. This supersedes
  the initially prepared and saved `Sell Nukes Tycoon ☢️` title. Keep the rest of R34 in scope.

> "you can fill out all of the questionaires for me as well. I dont need you to ask me"

- Complete and submit the content maturity and regional compliance questionnaire using the
  actual implemented systems. Report any resulting restrictions and code gaps accurately.

### R35. Rojo is enabled
> "rojo is enabled"

- Owner (re)connected Rojo, so the `ReplicatedFirst → src/first` mapping (loading screen) should now
  sync into the open place. Lead verifies ReplicatedFirst contents via MCP.

### R36. "Did you actually re-run all the agents?"
> "Are you sure that you actually ran all of the agents that were running earlier? Because I feel
> like there were more."

- Owner is right that there were more (~19 named builders). Lead audits every previous builder's
  unfinished work against the round-3 team and covers every gap (see plan "Live assignments —
  round 3" + the audit table added there).

### R37. Use Serena if it saves tokens
> "I'm not sure if you are using Serena or not, or even if it's a good idea to use it, but if it
> saves on tokens, you probably should."

- Verify Serena works on SellNukes' Luau (luau-lsp backend); if it does, make symbol-level
  navigation/edits the default for every agent (get_symbols_overview / find_symbol /
  replace_symbol_body instead of reading whole files).

### R38. Text logo in the Sell Lemons style, via ForgeGUI, on the loading screen
> "can you make a text logo for the game as well using sell lemons one as an example, I dont like
> the $ but I do like the font style and whatnot. use forgegui, and then replace the one in the
> loading screen" (screenshot: Roblox search results showing the "Sell Lemons" logo — chunky
> two-tone stacked title, "SELL" over "Lemons", glossy bevel, thick dark outline)

- Generate a "SELL NUKES" text logo with ForgeGUI in that style (chunky stacked two-line title,
  glossy bevelled letters, thick dark outline, playful kid-friendly) WITHOUT the "$" letterform
  (an original logo — style reference only, never copy their artwork). Transparent background.
- Replace the logo on the loading screen (and keep `BrandAssets` as the single source).

### R39. Real 3D models in the shop
> "in the shop we should use real 3d models" (screenshot: Shop → LIMITED TIME Starter/Secret packs
> showing flat icons for cash, gems, spins, 2x boost, Golden pet)

- Shop items (pack contents, gamepasses, cash/gem packs, crates, boosts) render the actual 3D game
  models in rotating, lit ViewportFrames (pets/eggs/crates/nukes from MeshAssets; new small Blender
  props where none exist: cash stack, gem, spin token, boost potion, money bag, VIP crown…),
  pooled and paused when off-screen, with the 2D icon only as the loading fallback.

Lead also spotted in the same screenshot: client error spam `TycoonWorld:197 onAdded` (x9) via
`Util/Signal:99` → sent to Q1-qa.

### R40. ForgeGUI connected
> "i conntected forgegui"

- Owner reconnected the ForgeGUI connector on the current account. Lead runs the R38 text logo
  (+ ad 9) as soon as the tools appear in the session.

### R41. Area 5 centrifuge spinners broken
> "this spinner was a bit jacked up" (screenshot: Enrichment Lab centrifuge row — the yellow
> rotor arms float above/beside the glass domes instead of spinning inside them)

- Each centrifuge rotor must spin inside its own dome around the dome's vertical axis.
  Suspects: rotor piece pivot/offset after the 180° yaw fix and/or WorldFx spinning around the
  wrong pivot. → A1-art (A5_CentrifugeRow geometry, rotor-per-dome pieces + pivots) and W1-fx
  (spin pivot = the piece's own centre on +Y). Also still visible: the ×9 `TycoonWorld:197`
  error (N1 fixing).

### R42. "did you make the logo?"
- Not yet: ForgeGUI shows "Connected" in `claude mcp list`, but its tools are not loaded in the
  running session (loaded at session start). Needs `/mcp` → claude.ai ForgeGUI → Reconnect (or a
  session restart). Brief + swap steps ready in `assets/marketing/2026-10-30-text-logo/README.md`.

### R43. "I have the silos but I cannot attack anyone"
> "i have the silos But i cannot attack anyone" (Studio screenshot at the Launch Silos Attack
> Console, "Launch Nukes!" prompt)

- Cause: only other players at area ≥ 7 are targetable (new-player protection), so solo / early
  servers have no targets and the feature looks broken.
- Decision (lead): attack mode is ALWAYS usable. Add **Rival Factory** NPC targets — cartoon toy
  factories on islands off the map edge (built from existing Blender sets via MeshLibrary), with
  their own AA towers/shields and level scaling — that you can launch at any time for a smaller
  minted reward; real players appear in the picker when eligible (protected players listed but
  greyed with the reason). The picker never shows an empty state without an explanation.
→ Q1-qa (AttackService/DefenseService/Attack client + picker).

### R44. All pets animated
> "make sure all of the pets have animations and stuff too"

- Every pet (all 29 + event/group/secret pets) animates while following: idle bob/breathe, walk
  waddle or hop (by body type), flyers flap wings, swimmers/floaters drift, tails wag, ears/
  antennae wiggle, happy spin when the owner buys/hatches, sleep pose when the owner is AFK; the
  same in the hatch reveal + pets inventory viewport. Uses split pieces (Body/Head/Wing/Tail/Glow).

### R45. Continue after the second session limit — respawn the agents
> "continue please youll have to spin agents back up again"

- All round-3 teammates (W1, P1, N1, Q1, A1, PA1) ended at the session limit (~22:08 UTC). Lead
  re-audits their half-finished work and respawns a team; ForgeGUI tools are back, so the lead
  makes the R38 text logo + ad 9 directly.
- Respawned 2026-10-30 ~22:38 UTC: N2-billboards (R31/R32 solver + TycoonWorld:197), Q2-attack
  (R43 Rival Factories, AFK removal, security findings), A2-props + W1b-shop (R39 3D shop + World-QA
  re-tour), PA2-petanim (R44), P2-prices (managed-pricing live prices + perf pass). Lead stopped dead
  P1's orphaned playtest after its lock went stale (rule documented in CLAUDE.md).

### R46. Money particles fly into the top cash counter
> "add particles on screen going into the money on the top"

- Whenever cash is earned (producer click, income tick, offline claim, pack purchase, rewards),
  screen-space particles (stud coins / cash bills + sparkles) burst from the source — the clicked
  producer's screen position, or screen centre for rewards — and fly on a curved path into the
  top-centre cash counter; the counter bumps + glints as each lands, with a soft coin tick sound.
  Gems do the same into the gem counter. Pooled (no per-frame Instance.new), capped particle
  count, scales with amount, FxQuality-aware (Low = few), reduced-motion respected, never blocks
  input, safe on phone/console (TV-safe). → H1-cashfx (HUD currency fly-to-counter FX).
  Implemented: `UI/Hud/CurrencyFly` + `CurrencyFlyRules`, `Config/CurrencyFlyConfig`, counter
  pop/glint in `UI/Hud/HudCurrency.land`, hooks in `Hud` (attach) + `Tycoon/IncomePops`
  (`fromProducer`), test `tests/currency-fly.luau`; doc `docs/ui.md` §7d.

### R47. Loading-screen Nukey looks washed out
> "the nuke model on the loading screen is very light colored and has like a white overlay effect on it for some reason?"

- Nukey on the loading screen must show its true candy colours (deep pink cap, yellow body, mint
  band) with no white haze; the green halo stays behind him. Also seen in the same Output: a
  `rbxassetid://203785492` "Asset type does not match requested type" warning — find + fix.
  → lead.

### R48. Mega Nuclear Facility billboard is blocked
> "the nuclear facility area gui is blocked a bit, needs to be moved"

- Screenshot (owner, 17:47, Area 10 entrance view): the Mega Reactor producer billboard
  ("Mega Reactor $51.1Qi x8" + progress bar) sits low in front of the dome, its bar is cut by the
  reactor cage, and it crowds the "E" prompt + manager. Move it clear (above the reactor with
  headroom, or beside it), readable from the Area 10 entrance and the road. Re-check every
  Area 10 producer billboard. → N2-billboards (R31/R32 solver audit must include Area 10).
- → Implemented 2026-10-30 (N2): A10 audited like every area (desktop + device); solver ignores
  walk-through frames for sight lines and weighs them harder, so the Mega Reactor board sits
  beside the dome (away from the Chief Engineer), raised clear of the reactor ring / FusionCore;
  `Shared/Config/BillboardSpots` regenerated. Capture: docs/verification/billboards/a10_*.

### R49. Real animated egg opening
> "actually animate the egg opening animation, it's really bad right now"

- Full hatch sequence on the real 3D egg (Blender model in a viewport, not a flat icon): anticipation
  wobble that builds in strength, cracks spreading, rarity-coloured light leaking through the cracks
  and rays behind, squash, flash, shell halves + shards flying apart, the pet popping out with a
  bounce + its idle animation (R44), rarity banner + name + "NEW!" tag, confetti/sparkles scaled by
  rarity, rarity sound stingers; Secret/Mythic get a longer, darker build-up. Triple hatch shows
  three eggs in a row. Tap / A / click to skip ahead; fast-hatch setting. Smooth on phone + console,
  pooled, FxQuality + reduced motion aware. → EH1-hatch (EggHatch screen + egg shell pieces),
  pet idle in the reveal from PA2-petanim.

### R50. Attack mode must DO something: money + temporary area knockdown
> "attack mode should actually do something, like give you money and temporarily knockdown peoples areas depending on where it hits"

- Owner overrides the old "target never loses anything" rule (hard rule 7 updated): a hit may
  TEMPORARILY knock down the area it lands in. Nothing is ever permanently removed (cash, pads,
  producers, levels, pets, gems untouched).
- Decisions (lead): the attacker aims at one of the target's built areas in the picker (markers on
  the top-down view); the server resolves the impact point (scatter shrinks with launcher level,
  AA can intercept, shields block). The area containing the impact gets **knocked down**: its
  stud buildings topple apart like toy bricks with confetti (no gore, no fire), that area's
  producers + clicks pause for 45 s (+3 s per launcher level, max 90 s), then it auto-rebuilds with
  the master-builder fly-in (rule 4). The owner of the area can tap "REBUILD!" to speed it up.
  Barrage can spill into the neighbouring area. Anti-grief: a plot knocked down gets 180 s knockdown
  immunity (hits still pay a reduced reward + confetti, no knockdown); shields block all; area ≥ 7
  rule stays. Attacker reward = minted cash scaled by the knocked area's income, bounded by the
  attacker's own income (no alt farming). Rival Factories knock down + rebuild the same way.
  Target sees a toast + HUD chip ("Your LAB got knocked down! Rebuilding 0:45 — TAP TO REBUILD")
  + Revenge. Admin: knockdown on/off, durations, force-rebuild; analytics on every step.
  → Q2-attack (aim, impact, reward, picker) + Q3-knockdown (knockdown state, production pause,
  topple/rebuild FX, target UI). Contract: `src/server/Tycoon/Knockdown.luau` (below, docs/attack.md).
- Implemented (Q3, 2026-10-30): `Server/Tycoon/Knockdown` (state, rules, loop, KnockdownTap, toasts,
  analytics, bot subjects for R51), `Shared/Config/KnockdownConfig`, `Shared/Tycoon/KnockdownLogic`,
  the TycoonService production pause, `Client/Tycoon/BuildIn/KnockdownFx` (topple / scattered /
  rebuild fly-in, dazed managers, frozen props), `UI/Screens/Knockdown/KnockdownHudScreen` (chip +
  TAP TO REBUILD), `Server/Admin/Handlers/KnockdownHandlers` (Attack tab, R51), `tests/knockdown-logic.luau`,
  `tools/qa/knockdown_check.py`; docs/attack.md §13. Decisions: Launcher 1 = 45 s (+3 s per level
  above 1), immunity counts from the LAST area coming back up, barrage spill = same attacker,
  1 extra area within 6 s.

### R51. Test bots for attacks (admin panel)
> "i need to be able to test attacks in dev mode so add like a bot button in the admin panel"

- New admin tab **Attack** (owner/admin only, works in Studio AND live servers for admins):
  **Spawn Test Bot** (pick bot area level 1–10, AA level, shield on/off) — claims a free plot slot,
  builds it through the normal pipeline (so knockdown/rebuild shows on real buildings), shows up in
  the attack picker with a BOT tag; **Bot attacks me** (normal / barrage, pick aim area) and an
  auto-attack toggle (every N s) to test AA / shields / knockdown / target UI on your own plot;
  **Remove bots**; **Reset my cooldowns / give barrage nukes / max launcher + AA** helpers.
- Safety: bots are never persisted and never real Players; only admins can target them (no farming
  by normal players); bot-hit rewards are paid (so the money path is testable) but tagged `test`
  and excluded from economy analytics; refused when no free plot; auto-removed when the spawning
  admin leaves, after 30 min, or on shutdown. Every action goes through AdminAuth + audit log.
  → Q2-attack (bots + Attack tab), Q3-knockdown (its knockdown admin commands go in the same tab;
  Knockdown API accepts bot subjects).

### R52. Game icon without the "+1"
> "using Forge GUI, can you get rid of the +1 that's on the icon? I like the icon a lot, I just don't like the +1."

- Keep the approved store icon exactly as it is (composition, avatar, nukes, colours, style) and
  only remove the "+1" text; regenerate/edit with ForgeGUI, save as the new
  `assets/marketing/2026-10-30-forgegui/final/icon.png` (old kept as history), open it for the
  owner. Owner re-uploads it on the Creator Dashboard (or the lead does via Chrome if asked). → lead.
- Done 2026-10-30: ForgeGUI edit job `bc98f372-f403-4fe1-adc0-1607c75781df` (reference = the
  approved icon, pixel-identical check), variant 2 picked; `final/icon.png` (512) + `icon-1024.png`
  replaced, old in `history/`. Dashboard still shows the "+1" icon until it is re-uploaded.

### R53. Ads = trendy thumbnails: no "PLAY NOW", hardly any text
> "they really need to remove the play now ... whenever Roblox thumbnails, they're just ads ... people just put the thumbnails for their game in their ads. So I think you should just remove the play now and stuff from them. Make them trendy like they are. Don't add too much text"

- All 10 ad creatives redone as front-page-style thumbnails: same trendy scenes, NO "PLAY NOW"
  button / CTA, no sub-captions; at most one short punchy hook (1–3 words, e.g. "SECRET PET!",
  "x2 CASH!") plus in-scene money pops. Rule for all future ads/thumbnails: no CTA buttons, minimal
  text. ForgeGUI edits of the current finals; old versions kept in history. → lead.
- Follow-up (owner): "don't even need text for a lot of them ... noob versus pro, obviously you'd
  have text ... some of them are like, plus 9999 second ... but like, most of them don't have text."
  → Text kept ONLY where it is the hook: ad01 "+$999,999,999/s" sign, ad07 "1 vs 100!" (versus),
  ad09 one "+$999K/s" pop (before → after). ad02/03/04/05/06/08/10 get NO text at all (scene only;
  in-object marks like the trophy's "#1" may stay). Thumbnails rule: mostly no text; text only for
  "+$X/s" money hooks and versus / noob-vs-pro comparisons.

### R54. Launch cinematic: follow the missile + animated 3-2-1 + voiceover
> "when you launch an attack on somebody that you follow the missile as well with like an animated 3, 2, 1. And a voiceover. Please. That would help it look a lot better."

- On launch (normal / revenge / barrage / rival): a big animated stud-style "3 … 2 … 1 … LAUNCH!"
  countdown with a cartoon announcer voiceover + rumble, then the camera chases the toy nuke along
  its arc (smooth follow, slight shake on lift-off, slow-mo on the hit), shows the AA intercept or
  the confetti hit + knockdown, then eases back to the player. Skippable (tap / B), never locks
  the player for long, works with gamepad / touch, reduced-motion = no shake/short cut. The
  server timing stays authoritative (the countdown is part of the existing flight lead-in; no
  extra delay that changes outcomes). Barrage follows the first nuke only.
  → Q4-launchcam (camera + countdown), voice lines by the lead (ForgeGUI audio → Roblox upload).
- Implemented (Q4, 2026-10-30): `Client/Attack/LaunchCam` (director, one RenderStepped),
  `Shared/Attack/LaunchCamMath` (pure camera / countdown maths), `Shared/Config/LaunchCamConfig`,
  `UI/Screens/LaunchCountdown/{LaunchCountdownScreen, CountdownOverlay}` (stud 3-2-1 badge + brick
  burst, LAUNCH! + confetti, DIRECT HIT! / INTERCEPTED! / KNOCKDOWN! shouts, letterbox, SKIP),
  `tests/launch-cam.luau`; docs/attack.md §15. Decisions: countdown = 3 × 1 s beats inside the
  server lead-in (`AttackConfig.Flight.LeadIn` 3.4 s = 3 s + 0.4 s network slack, same for every
  launch, so outcomes and hit times stay server-decided); voice keys `vo_three/two/one/launch/
  direct_hit/intercepted/knockdown` play when present in AudioConfig (silent until uploaded);
  skip = tap / click / SKIP (A) / B / X / Backspace / Esc after a 0.4 s grace; the picker closes
  when the cinematic starts; kill switch ReplicatedStorage `SN_LaunchCamOff`.

### R55. Make the lobby centre look great
> "Also improve the look of the lobby center. I think the center lobby looks like shit. No offense."

- Redesign the hub centre (spawn plaza) as a premium, readable, stud-toy plaza: a hero centrepiece
  (giant Nukey statue / toy-nuke fountain with soft animated water + gentle glow), layered stud
  tiles + borders, planters, lamp posts, benches, banners, clear paths to all 8 plots, the egg
  stands / shop / leaderboards framed around it, ambient motion (fountain, flags, spinning
  signs, floating coins). All Blender (rule 3), soft glows (R19), z-fight 0, performant
  (streaming, merged meshes). → L1-lobby.
- Implemented (L1-lobby, 2026-10-30): `tools/blender/models/hub_plaza.py` (11 models: centre
  floor, 8 plot-coloured paths, 7 garden beds, toy-nuke fountain with 8 spraying spouts, giant
  waving Nukey statue + coin halo, signpost teleport pads, spawn pad, banners, lamp-post bunting
  gateways, floating coins), warm district paving + lime kerbs (`hub.py`), `HubLayout.luau`
  "Lobby centre" block, `HubAmbientConfig.luau` + `HubBuilder` (fountain spray / splash, coin
  sparkles), `WorldFxConfig` rows (Ripple, Wave, Streamer, Pennant, Twirl, Whirl, Carousel).
  District fixtures (egg stands, crate stall, chest, wheel, boards, codes) moved in from r 150 to
  r 132-140 so they frame the centre (same behaviour, anchors follow); the spawn is unchanged.
  Map + numbers: docs/areas-art.md "Lobby centre (R55)"; QA: `tools/qa/hub_lobby_check.py`.

### R56. Animate more of the map (trucks drive in and out etc.)
> "animate more of the places in the map too, like, I feel like the delivery truck should drive in and out, semi-truck should drive in and out, you know, stuff like that."

- Every vehicle and machine that could move does: delivery trucks / semi-trucks drive in on the
  road, stop at their dock, get loaded (crates pop in), drive out and loop; forklifts shuttle,
  carts roll, cranes swing, conveyors carry boxes, doors open/close, etc. Client-side, one loop,
  pooled, distance/FxQuality culled, streaming-aware, never blocking players (no collisions on
  moving props). Assemblies move as one unit (R25). → V1-vehicles.
- Implemented (V1, 2026-10-31): `Client/Tycoon/Fx/VehicleRoutes` + pure `Client/Tycoon/Fx/RouteMath`,
  `Shared/Config/VehicleRouteConfig` (7 routes), `tests/vehicle-routes.luau`, `tools/qa/vehicle_check.py`;
  Blender `A6_DeliveryTruck` (semi, flatbed) + `A8_ShopperCar` split out, van / forklift / mine cart
  re-pieced (per-axle wheels, brake + indicator lights, cargo pieces), A8 garage barrier lifts;
  docs/build-in.md §4b has the per-area audit table. Decisions: the A6 box truck became a cab-over
  semi with a flatbed so the crates popping on are visible from anywhere; the van's parcels pop onto
  its roof; horn = `vehicle_honk`, reversing = `vehicle_beep` once per reverse leg; vehicles fade out
  on the road at |x| 74 and loop back in; areas 1/2/5/7/9/10 have no vehicles yet (future candidates
  listed in the table: Sunday drive, fuel tanker, crane / drone); hub motion is L1-lobby's.

### R57. (After the main game) a separate area reachable by teleporter, with its own rebirth
> "Once you're completely done with like the main game, like once all your agents are done, you should like separate area that the teleporter can use that you can do anytime and also rebirth that. Just an idea. That way people, you know, we have a lot of content on launch and we can add stuff later."

- QUEUED until every current agent has landed. Then: a second, self-contained tycoon area (its own
  theme, pads, producers, managers, billboards, build-ins, Blender art) that any player can reach
  from the Teleport menu at any time, with its own currency/progression + its own Rebirth track
  (separate multiplier), saved alongside the main run; designed so more areas can be added later
  (data-driven world list). Spec + plan first (lead), then builders. → lead (after the current wave).

### R58. Updates changelog / "What's New" (RoBeasts system), returning players only
> "add an updates changelog system that we have ... add the changelog system that we have in the Robeast project. That way it can all be like hooked up together. The what's new but only show like the what's new whenever like returning players join. You can put it in like the bottom right or something like that too. Don't clog up the left UI too much more than it already is."

- Port the RoBeasts changelog / What's New system (same data shape + pipeline so both games'
  release notes are authored the same way), wired to SellNukes' VersionConfig + ChangeNotesConfig.
- Auto-open ONLY for returning players who have not seen the current version (never for brand-new
  players on their first session); the "seen version" is saved in the profile, server-side.
- Entry point: a small bottom-right button/chip (with a "NEW" dot when unseen), not on the left
  HUD stack. Full stud UI, console/mobile navigation, B closes. Admin + analytics hooks.
  → U1-changelog.
- Implemented (U1, 2026-10-31): `docs/change-notes.md` (same schema + workflow as RoBeasts);
  `Shared/Config/ChangeNotesConfig` + `Shared/Util/ChangeNotesLogic` (no-context = new profile or
  tutorial unfinished → newest marked seen on load), `profile.notes` in `Server/Economy/ProfileLogic`,
  `Server/Services/ChangeNotesService` + `Server/Admin/ChangeNotesAdmin` (WhatsNewReset /
  WhatsNewPreview), `Client/ChangeNotes/ChangeNotesClient` (once-per-join polite auto-open),
  `UI/Screens/WhatsNew`, bottom-right chip `UI/Hud/HudWhatsNew` (HudPlacement `corner`; nothing added
  to the left stack), analytics retention `notes:*` (shown auto/menu, closed, seen, cta, time open),
  version 0.3.0 + note, `tests/change-notes.luau`.
- Owner status note: "I'm headed out though, but you got this." (2026-10-30 ~23:45 UTC) — lead
  continues autonomously.
- 2026-10-31 ~01:35 UTC: spec `docs/superpowers/specs/2026-10-31-world2-design.md` + plan
  `docs/superpowers/plans/2026-10-31-world2-build.md` (S1). Decisions: "Dino Valley" (6 areas,
  ~2.5 h first run), own currency Bones + own Rebirth (Amber), small two-way link bonus with the
  main game, unlock at main area 3 or 1 rebirth then usable any time via Teleport world tabs +
  a lobby Time Machine, same place (separate region; sub-place rejected per R33 + session-lock
  risk), save schema v2 (`profile.worlds`). Wave A dispatched: W1-logic, W2-core, W6/W7/W8 art,
  W9-valley, W11-pets.
- 2026-10-31 ~03:20 UTC: W5/W9/W10 hit the session limit mid-task. Lead checkpointed the green
  tree (`ea4b974`, 67 suites) and respawned W5b-ui, W10b-client, W9b-valley to finish; the dead
  W5's orphaned playtest is stopped by the lead once its lock is stale (CLAUDE.md exception).

### R59. Phone HUD: the button grid covers too much of the screen
> "smaller devices, like in this image, I feel like the cards are just kind of covering the whole screen. Maybe we can divide them around. I don't know if there's more room to put them up to the left more, make them smaller ... I just feel like it's kind of hard to see."

- Phone (small-screen) HUD layout pass. Decisions (lead): left tiles shrink to the 44 pt minimum
  tap size and pack tight into the TOP-LEFT corner (below the Roblox top bar, above the thumbstick
  zone, 2–3 columns); the less-used buttons (Rebirth, Teleport, Time, Attack, Admin) move to a
  compact row along the top-right edge (or a "More" fold if they don't fit); the What's New chip
  becomes an icon-only star with NEW dot on phones; right-side offers shrink so the centre of the
  screen stays clear. Target: ≥ 60 % of the phone viewport free of HUD in the play area; all taps
  ≥ 44 pt; nothing under the thumbstick / jump zones; gamepad navigation order preserved;
  tablet / desktop / console unchanged or only tightened. Verified with capture_device_matrix in
  both worlds. → W5b-ui (owns the HUD files) after its current re-check.

### R60. Each world keeps its own money
> "Make sure the money in each area doesn't transfer either. Like if I go into Dino Valley from the main map, it doesn't have the same money."

- Already the design (spec: Dino Valley's currency is **Bones**, never converted to/from Cash) and
  tested at profile + pets level (Bones never touch main cash; main cash never pays a Bones price;
  Dino eggs spend only the Dino wallet; W3 verified in Studio a Dino pad leaves Nuke Town cash
  untouched). Decisions: (1) the Dino HUD shows ONLY Bones (+ gems) — the small Nuke Town cash
  chip under the Bones counter is removed there so it never reads as "the same money"; each world's
  balance is shown on its Teleport world tab instead (W5b, with R59). (2) Gems stay account-wide
  (premium currency, like every Roblox sim). (3) A dedicated isolation suite + Studio check: pad /
  click / upgrade / manager / offline / products / rebirth in one world never change the other
  world's balance; the cross-world rebirth link only changes income multipliers, never balances
  (W12-analytics QA).

### R61. Coins fly to the left side after an upgrade (Dino Valley)
> "reason, when you upgrade, the coins like go on the left side of the screen. I don't know why."

- Screenshot (owner, 23:54 local, Dino D1 "Pebble Nuke Bench", UPGRADE pressed): a ring of coin
  sprites piles up around the left HUD tiles (Shop / Rewards / Daily / Codes) instead of flying
  into the top Bones counter. Expected: income / rewards fly from their source into the counter of
  the world's currency (Bones in Dino, Cash in Nuke Town); spending (upgrade / pad buy) never
  spawns fly-in coins (at most a small "-X" pop at the counter). Root-cause the target resolution
  for the `bones` kind (world counter swap, R60 HUD changes) and the spend path; lune test that the
  target is the visible counter in both worlds and that spends never fly in. → W5b-ui (owns
  CurrencyFly + HUD).

### R62. Too many buttons on the left side
> "feel like we just have a lot of buttons on the left side. Not really sure what we can do"

- Decision (lead): consolidate, all devices. The left stack goes from 11 buttons to 6:
  **Shop, Pets, Rewards, Rebirth, Teleport, Attack** (Attack main world only).
  * **Rewards hub**: Daily, Time (playtime gifts), Lucky Wheel, Codes and Group rewards fold
    into ONE "Rewards" button whose red badge = total claimable; it opens a stud-panel hub with a
    tile per feature (each with its own badge / timer) that opens the existing screen. Nothing is
    removed; the Lucky Wheel keeps its "x5 Spins" offer on the right.
  * **Admin**: leaves the stack; a small wrench chip in the top-right, admins only (R20 keeps an
    on-screen way in).
  * Gamepad: menu-wheel + D-pad order updated; B closes the hub; every deep link (Welcome Back,
    notifications, What's New CTAs, tutorial) still opens the right screen directly.
  * Combined with R59 (phone layout) and R60/R61. → H3-hub (new Rewards hub screen + badge
    aggregation API) + W5b-ui (HUD stack / layout / Admin chip).

### R63. "did you redo the thumbnails?"
> "did you redo the thumbnails?"

- The 10 ADS were redone for R53 (no PLAY NOW, mostly no text). The 10 STORE thumbnails never had
  a CTA; 4 use the hook styles the owner named (+$999,999/s, NOOB vs PRO ×2, DAY 1 vs DAY 100) and
  stay. Applying the R53 rule ("most of them don't have text") to the other 6 (+1 NUKE EVERY
  SECOND, HARVEST FEAST, SECRET PET, SEND NUKES TO FRIENDS, IT BUILDS ITSELF, BUILD THE BIGGEST
  NUKE FACTORY): text-free ForgeGUI edits of the exact approved variants (in-scene money pops
  kept), old versions in history/ for A/B. → lead.


## 2026-10-31 — Refresh unpublished ad creatives

> "claude redid the ad creatives can you fix them"

Replace the ten older images in the existing unpublished Sell Nukes Ads Manager campaign with
Claude's R53 revisions from `assets/marketing/2026-10-30-ads/final/`. Preserve the campaign's
Engagement objective, $20 lifetime budget, three-day duration, and November 1 start. Leave the
final Publish action to the owner as previously requested. Record verification in
`docs/creator-dashboard.md`; do not alter the revised source artwork.

### R64. First producer must start manual (click to make nukes)
> "when someone starts the game for the first time and buys the first little like button, it already is automatic and you don't need to click to start before you upgrade. There's no like initial, you have to click 14 times."

- Expected (spec §2, Sell Lemons style): a fresh player's first producer is MANUAL — each cycle
  starts only when the player clicks it (the early game is ~a dozen+ clicks of hands-on making)
  until its manager is hired, which is what makes it automatic. Investigate why the first producer
  auto-runs for a brand-new profile (manager pre-granted? tutorial step? auto-click pass/boost
  default? New Player Mode?) and fix at the source; nothing else automates without a manager / the
  auto-clicker pass. Verify as a genuinely new player (New Player Mode) in Studio.
  → E1-economy.

### R65. First upgrade should cost $10
> "Gene's probably a lot though. I'd make like the first upgrade $10."

- The first producer's first upgrade costs $10 (owner number). Re-tune the early curve around it,
  keep the invariant "no purchase lowers a number", re-run the economy simulator (run 1 ≈ 8:00
  target, run 2 ≈ 3:39) and update tests / docs/economy.md. → E1-economy.

### R66. Put the SellNukes logo on the ad creatives
> "add creatives, put the SellNukes logo on them real quick."

- Stamp the in-game ForgeGUI title (`assets/brand/logo-text.png`, R38) onto all 10 ads with a
  deterministic script (`tools/ui/brand/stamp_ads.py`): ~30 % width, soft drop shadow, corner
  chosen per ad so it never covers a face or the hook text. Un-logo'd versions kept in
  `history/no-logo/`. → lead.

### R67. Admin button to play as a new player
> "I also need a button in the admin panel that lets me play as a new player."

- Already exists (admin tab "New Player" → "Play as New Player" / "Exit New Player Mode"; real
  profile parked + saved, throw-away sandbox, nothing saved, Robux off). Owner couldn't find it →
  make it prominent: a big "PLAY AS NEW PLAYER" quick button in the admin panel header (every
  tab), and while the mode is on a persistent small on-screen chip "NEW PLAYER MODE · EXIT"
  (admins only, gamepad reachable). Re-verify end to end after R57: fresh plot rebuilt from
  scratch, tutorial starts, Dino Valley locked, no world data leaks in, exit restores the real
  profile incl. Dino progress + plot. → W12-analytics (owns the admin client screens).


## 2026-10-31 — Refresh ad creatives with Sell Nukes logo

> "updated them one more time with the sell nukes logo"

Replace the ten campaign attachments again with the latest logo-stamped PNGs in
`assets/marketing/2026-10-30-ads/final/`. Keep the campaign settings unchanged and leave Publish
to the owner. Verify all ten branded images and update the existing dashboard handoff record.

### R68. A couple more ad creatives
> "a couple more ad creatives as well."

- 3 new ads in the R53 style (trendy front-page thumbnails, no CTA, mostly no text) + the R66 logo
  stamp, aimed at the newest hooks: ad11 Dino Valley (Time Machine into the jungle + golden T-Rex
  volcano, no text), ad12 Knockdown (candy toy nuke knocks a rival's toy-brick factory into flying
  bricks + confetti, kid-friendly, no text), ad13 NOOB vs PRO Dino edition (cave workshop vs
  Volcano Reactor; versus text allowed). References: our own Studio captures uploaded to ForgeGUI.
  → lead.


## 2026-10-31 — Add three more campaign creatives

> "add these threee as well"

Add the three PNGs shown in the owner's screenshot—`ad11-dino-valley.png`,
`ad12-knockdown.png`, and `ad13-noob-vs-pro-dino.png`—from the existing final ad folder to the
unpublished campaign. Preserve the ten branded creatives and campaign settings, verify 13
attachments, and leave Publish to the owner.


## 2026-10-31 — Verify public access and supported devices

> "make sure the game is public now and has mobile and console also enabled"

Verify the existing Sell Nukes experience is Public and that phone, tablet, and console are
supported. Enable missing requested device settings if needed and verify saved dashboard state.
This request concerns the existing published experience, not a new runtime build or ad budget.
- Implemented (checkpoint 2026-10-31 ~05:40 UTC): R59/R60/R61/R62 by W5b-ui (6-button stack,
  phone 2×3 @ 44 pt, Admin wrench chip, Dino HUD Bones-only, ScreenRect fix for billboard-button
  coin bursts) + H3-hub (Rewards hub); R64/R65 by E1-economy (creator owns AutoClicker → new
  `settings.autoClicker` toggle for pass owners; first upgrade $10, Garage Lab re-tuned, run 1
  8:00 / run 2 3:40, Garage Egg $400); R67 by W12 (header button + NPM exit chip; Studio check
  pending); R60 isolation suite (336 checks) by W12.


## 2026-10-31 — Create and connect the first five Roblox badges

> "can you please make the first 5 badges for the game as well and upload them to the creator dashboard. hook them up as well"

Create the first five entries in the existing append-only BadgeConfig catalog: Welcome, Area2,
Area3, Area4, and Area5. Create consistent studded toy-style badge icons, upload/create the five
badges for universe 10773845696, and connect the verified IDs to the existing server-authoritative
award system and badge UI. Preserve catalog order and other contributors' changes. Verify,
document, update applicable change notes/version, and commit this task's changes.

Implemented: all five created free and verified Active; artwork in
`assets/marketing/2026-10-31-badges/`, IDs in `BadgeConfig`, progression regression coverage,
version 0.4.0 and WHAT'S NEW entry. Details and full isolated verification in
`docs/leaderboards.md` and `docs/creator-dashboard.md`. The owner must publish the synced place
once to activate the IDs in live servers (CLAUDE.md hard product rule 1).


## 2026-10-31 — More monetization, a space world, more juice

> "Can you please add more monetization on places that you think it's due? Like, you know, some
> buttons that are like 2x cash that just appear randomly throughout your plot, stuff like that,
> just simple things to make monetization better. Nothing too crazy. Also, can you add another
> area . You know how you have Dino Valley? I would add like a fucking space or some shit. That'd
> be cool. Yeah, just make the game more fun too. Just like not necessarily change the first
> valley or anything like that. Just like better sound effects, more visual effects, stuff like
> that, you know? Just wanna make retention max."

Spec: `docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md`.

### R69. Lucky Buttons + simple monetization where it is due
- "buttons that are like 2x cash that just appear randomly throughout your plot" → **Lucky
  Buttons**: glowing Blender-built arcade buttons that pop up at random spots on the player's OWN
  plot (any world), live ~45 s, only the owner sees / claims them. Mix of FREE (cash burst, short
  2x Cash) and Robux (2x Cash 30 min, 2x Cash pass, Auto Clicker, cash / world-currency packs,
  Skip Pad) buttons. Server-authoritative (spawn, position, claim range, reward), full UI (beam,
  label, toast, claim FX), console + touch + KB/M, admin controls, analytics. "Nothing too crazy":
  at most 2 live, first one each session is free, paid ones never stack.
- New products only where due: the space world's currency packs ×3 + a one-time starter pack.
- → H3 (Lucky Buttons), W1 (products).

### R70. A space world ("like Dino Valley … a space")
- **Moon Base** — World 3 on the worlds framework (spec §18: config + art): own currency, own
  rebirth track, 6 areas, managers, billboards, build-ins, Blender art, pets + eggs, products,
  hub reached from the lobby + Teleport tabs. Space twist: **low gravity** while you are on the
  Moon. Kid-friendly (cute aliens + robots, nothing scary).
- → W1 (economy/registry/products), W6/W7/W8 (area art), W9 (Moon hub, lobby rocket portal,
  lighting, music), W10b (low gravity + client world glue), W11 (pets/eggs), W13 (icons + shop props).

### R71. More fun: better sound effects + more visual effects (do not change Nuke Town's content)
- "not necessarily change the first valley" → Nuke Town's areas, pads and pacing stay as they are.
- Juice pass across every world: better (ForgeGUI) sound effects, click combo feedback, purchase /
  milestone / unlock / rebirth celebrations, camera punch (Reduce Motion respected), richer
  particles. Retention focus. → H1 (juice).

### R72. No multiplayer playtests
> "stop runing multiplayer playtests"

- Context: W12's `world2_check.py multi` (8 players) at ~05:29 UTC got
  `multiplayer_start_not_detected`, exited without `end`, but the test HAD started; it ran ~7 h,
  exhausted memory (load ~55), hung the Studio MCP and blocked every builder.
- Rule (permanent): agents never start `multiplayer_playtest` (or `world2_check.py multi`); solo
  playtests only. Enforced in `scripts/studio_mcp.py` (`guard_tool`: only `status` / `end` /
  `stop` pass, so a stray one can still be stopped). Added to CLAUDE.md Studio rules. All running
  agents told. → lead.

### R73. Developer name tag
> "Can you give me a name tag whenever I'm in the game so people know I'm the developer?"

- Whenever the owner (AdminConfig.OwnerUserId 1586034782) is in a server, everyone sees a
  stud-styled **DEVELOPER** tag above their head (kid-friendly, readable on phone / console,
  distance-limited) and a coloured **[DEV]** prefix on their chat messages.
- Server-authoritative: only the server decides who is the developer (UserId check) and sets a
  Player attribute; clients only render it. Owner can hide / show it from the admin panel; it
  survives respawns, world travel and New Player Mode. → W5b-ui.

### R74. "First Player" title for <player>
> "add a early player title for this random player … actually, first player since he was the
> first player"

- Screenshots: live server chat — <player> asked the owner (display "JusticeDev", user JusticeTTV1
  1586034782) for a player title; owner: "yes whenever I add them you are first on my list".
- <player> = display name of user **0** (username <player>), found on the live
  Playtime + Cash leaderboards (3 players total at the time). Titles key on UserId, never names.
- R73's developer tag becomes a small **Player Titles** system: overhead stud tag + chat prefix,
  catalogue `DEVELOPER` (owner), `FIRST PLAYER` (0, permanent in config),
  `EARLY PLAYER` (for later grants). Owner grants / revokes titles to online players from the
  admin panel (saved in their profile). → W5b-ui.

### R75. Animate the Glow Rock miners
> "You animate the miners in the Glowrock area. They don't actually do anything."

- Nuke Town area 4 (Glow Rock Mine), pad `a4_pickaxe_crew` → `A4_PickaxeCrew` places 3 ×
  `A4_Miner`. The Blender builder (`tools/blender/models/area04.py` `build_miner`) makes a STATIC
  figure (pieces grouped by colour, arm + pick not separable), so nothing can move.
- Required: the miners visibly mine — pickaxe swing loop (wind-up, strike), rock chips / sparkle
  burst + soft "clink" on each strike (3D, short range), slight body lean, de-synced per miner, one
  shared controller (WorldFx / one Heartbeat), view-cone culling, FxQuality + Reduce Motion
  respected. Rebuild the mesh with a hinged arm + pick piece (shoulder pivot); same key, same
  placements, same economy (cosmetic only, R71 untouched otherwise). Also sweep Nuke Town for other
  static toy_figure workers and give them the same treatment where it fits. → W7-art34.

### R76. More codes to post in Discord
> "Can you also add some codes and tell me what they are and what they do I can post in discord"

- Added to `CodesConfig` (ids are save data; one claim per player; case-insensitive):
  `MOONBASE` (30 gems + 2 Lucky Spins), `BLASTOFF` (2x Cash 20 min), `ZOOMZOOM` (2x Speed 15 min),
  `DISCORD` (10 min of cash, min $5K, + 15 gems), `THANKYOU` (50 gems + 3 spins, until
  2026-11-08 00:00 UTC). Existing live: `NUKES`, `BOOM`, `RELEASE`; `HARVEST` from Nov 1.
  The 0.5.0 What's New mentions MOONBASE. Codes go live when the owner publishes 0.5.0. → lead.


## 2026-10-31 — Reduce gamepass prices by roughly 30%

> "make the gamepasses slightly cheaper, like 30%"

Read current live Sell Nukes gamepass prices, reduce each base price by 30% rounded to the
nearest whole Robux, preserve managed pricing, and verify the saved values. Align any local
fallback prices with the verified dashboard amounts, document the result, and run the required
checks before committing only this task's changes.

Implemented through Chrome: all eleven prices saved and read back with Managed Pricing Enabled.
`MonetizationConfig` and the generated catalogue match; v0.5.1 adds the price reduction to
WHAT'S NEW. Full before/after table and evidence are in `docs/creator-dashboard.md`.

### R77. The first player must see his own name tag
> "make sure the player can see his nametag … the first player one"

- Per-title `TitleDef.showOwn` (PlayerTitlesConfig): FIRST PLAYER + EARLY PLAYER holders see their
  own overhead tag; DEVELOPER stays hidden on the owner's own screen (lead review: it blocked his
  view). Replaces the global `Tag.ShowOwn`. Client: `PlayerTitleClient.refresh`. Test:
  tests/player-titles.luau. → lead.

## 2026-10-31 — Retention pack (0.6.0)

### R78. "More improvements … more retentive and fun"
> "come up with a bunch of more improvements to the game … I don't know if you have access to the
> data store analytics or not, but there is an open cloud key in Roby's project … just add a bunch
> of stuff … to make the game more retentive and fun"

- Open Cloud: the RoBeasts key (`~/.config/robeasts/open-cloud.env`) is scoped to Messaging /
  assets only — DataStore read on universe 10773845696 returns 403 INSUFFICIENT_SCOPE. The live
  analytics were read instead, read-only, through the connected Studio place
  (`SellNukesAnalytics_v1`, `d:2026-10-31:*`). No key was printed or copied.
- Day-1 data (20 new players, 26 sessions): 11 sessions < 2 min; funnel joined 20 → first pad 14
  → first upgrade 10 → pad 5 = 4 → area 2 = 1; 6 left right after the plot loaded (3 of 7 console
  players); 22 of 26 leaves in area 1; 28 of 29 sessions with no friend in the server; the
  Rewards hub / Wheel / Time / Daily menus are the most-opened screens.
- Decision (autonomous, rule 1): ship a data-driven retention pack — Quests (starter goals, daily
  missions, trophies), the Nuke Pass season (free + premium track, exclusive pet / trail /
  title), Rookie + Comeback Rush boosts, Friend Boost + invites + referral rewards, Pet Index
  milestone rewards, and a first-minute fix pass for console / mobile with finer FTUE analytics.
  Spec: `docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md`. → lead + W-R78 builders.

## 2026-10-31 — Menu focus, defences, wheel juice, boost badge (0.6.1)

### R79. Quests GO → Lucky Wheel handoff + clean menus + hint bar
> "from quests, when you open the spin the lucky wheel, it should close the quest menu and then
> reopen once you close the lucky wheel … when you're in menus, you should hide the like cards on
> the left side of the screen and like the offers on the right … the controller menu that's like on
> the bottom of the screen, kind of blocks the spin the lucky wheel"

- Every screen a Quests GO / Nuke Pass OPEN button opens hides the Quests window while it is up and
  brings Quests back (same tab, gamepad on the pressed button) when it closes — a generic
  ScreenManager handoff, not a Wheel special case.
- While any menu (modal) is open the HUD keeps only the currency stack: the left button grid,
  the right offers, WHAT'S NEW and the bottom objective chip fade out and fade back on close.
- The gamepad hint bar never overlaps the objective chip (placed clear of the chip's rect).
  → lead.

### R80. Buyable + upgradable AA defences on every plot
> "there are no buttons to like buy AA towers or anything like that for your island. Or your plot.
> So people can just nuke you. Without having any defense system. And they need to be upgradable."

- Plots get visible, in-world defence buy buttons (build-in fly-in) and in-world upgrade buttons,
  plus a HUD route to the Defense window; levels are upgradable with server-priced cash; analytics
  + admin. → W-R80 defence builder.

### R81. Lucky Wheel spin juice
> "spin needs like a ticker effect and more effects. It's just kind of boring."

- A pointer flapper that ticks over every slice peg (click sound, pitch rising with speed), rim
  light chase, anticipation wind-up, slow-down suspense, win glow + confetti + pop; settles on
  the server's result (display only). → W-R81 wheel builder.

### R82. 2x CASH boost as a corner badge
> "the two x cache UI can kind of be like a corner piece for the cache instead of it being like its
> own little pill on the bottom."

- Active cash boosts render as a small corner badge on the cash counter (timer inside) instead of
  a pill under the currency stack. → W-R82 HUD badge builder.

### R83. Click quests with the Auto Clicker
> "this quest, you need to add a check if the player has auto clicker, because they won't be able
> to click anything if they have auto clicker."

- While the AutoClicker pass is clicking for a player (TycoonRules.autoClickerOn), the cycles it
  starts count toward "click" missions / the Clicker trophy line, credited at a human-like rate
  (QuestConfig.AutoClickCreditPerSecond) so a pass never maxes trophies in seconds; only the world
  the player is in counts (like a real click). The Quests row says the Auto Clicker counts. → lead.

### R84. Tutorial: point at the button you must press, highlight it
> "in the tutorial, on the first part where it tells you to press the button and then you buy the
> bench inside of the garage, it doesn't actually point to the GUI. It kind of points towards the
> bench instead of where you're supposed to go … Maybe highlighting the button that needs to be
> clicked on the GUI so people know, because it wasn't very clear to me that X is what you were
> supposed to do to upgrade first."

- Each tutorial step's arrow points at the exact thing to press (the producer's in-world UPGRADE /
  make button on its billboard, the pad's buy button), not the model; that button gets a pulsing
  highlight ring + the device's glyph (X / Square on gamepad, E / click on KB+M, tap on touch),
  and the objective chip names the same control. → W-R84 tutorial builder.
- Implemented (T-tutorial, 2026-10-31): `Tycoon/TutorialHighlight` + pure `TutorialFocusLogic`
  (step → pointed control / rings / glyph per device), `UI/Hud/HudObjective` GuiObject targets +
  callout badge, pure `UI/Hud/PointerLogic` (arrow beside the button, never over it), new lines in
  `TutorialText` ("Press X to UPGRADE your Workbench!"). Docs: `docs/tycoon-client.md` §4c.
  Tests: `tests/ftue-logic.luau` §8–§9.

### R85. Paid Revenge Nuke (39 R$) + attack open to everyone
> "If you get nuked, add like a 39 like revenge nuke button that like you can pay for with Robux.
> Like nuke somebody back. If they hit you. Also, I know that we have attack mode disabled for
> people that are like not level, like don't have the attack mode, but like I think we should just
> allow people to be able to blow people up. Either way."

- Getting hit shows a REVENGE NUKE button (developer product, 39 R$): an instant golden nuke back at
  the player who hit you (no cooldown, extra armor vs AA, revenge reward). Idempotent receipt; if
  the attacker left or shielded before the receipt lands, the charge is stored and usable later.
- Decision (autonomous, rule 1): attacking no longer needs the Area 7 Attack Console — every
  player has a starter launcher from the start (the console / upgrades still level it up).
  Targets stay protected only while brand new (tutorial + a short config grace), and the R80
  defence buy buttons appear the moment a player becomes targetable. Kid-friendly contract
  unchanged (nothing is ever permanently taken). → W-R80 defence builder (owns attack + defence).

### R86. Buy the next upgrade with gems (flat price)
> "add a button on like the GUI to also just buy for gems, like just buy the next upgrade with
> gems, but it stays at the same price for everything. It doesn't change … probably like 1,000
> gems. I don't know. Whatever you think is reasonable … another thing, way to spend gems."

- Every producer billboard gets a gem button that buys exactly ONE level for a flat gem price
  (same for every producer, level and world; `TycoonConfig.GemUpgradePrice`, admin-adjustable).
- Decision (autonomous, owner said "whatever you think is reasonable"): 25 gems, not 1,000. Gem
  packs sell 100 gems for 49 R$ and 1,000 for 399 R$, and free play earns roughly 70–100 gems a
  day (missions + chest + wheel), so 1,000 gems would make one level cost about 399 R$ and nobody
  would press it. At 25, a free player can buy a few gem levels a day and a level costs about
  12 R$ of gems, close to what a cash pack buys early on. A quick confirm guards against
  accidental gem spends (kid-friendly). → W-R84 tutorial builder (owns ProducerBillboards).
- Update after the pacing simulator: 25 let 3,000 gems finish Garage Lab in 0.6 min (erasing an
  80-min area), so the shipped price is **75 gems** (halves an area at most); table in
  `docs/economy.md`. Bindings: C / LB / a GEMS touch button; confirm = arm, then buy within 3 s.
- Implemented (T-tutorial, 2026-10-31). **Price raised to 75 gems** after the pacing check the lead
  asked for: with the real simulator, 25 gems let 3,000 gems (120 levels) finish Garage Lab in
  0.6 min and erase a whole 80-minute late area; at 75, 3,000 gems = 40 levels (areas halved,
  never skipped), a 1,000-gem pack = 13 levels, free play ≈ one gem level a day (table:
  `docs/economy.md` "Gem upgrade"). Confirm: first press arms "SURE?", second press within 3 s
  buys, presses within 6 s of the last gem buy go straight through. Bindings C / LB / GEMS touch
  button (hint shown while the producer in reach can take a gem level). Server
  `ProducerGemUpgrade` (TycoonService), admin "Gem upgrade price" (Economy tab, per server).

### R87. Manager nametags
> "in sell lemons the managers/automaters all have nametags" (screenshot of another game: a small
> billboard over each manager NPC — a role line, its name, and what it runs)

- Inspiration only (SellNukes stays original): every manager NPC on a plot gets a small stud-style
  nametag over its head — a "MANAGER" role chip, a friendly kid-safe name, and "runs <producer>" —
  plus an occasional short speech bubble from a kid-friendly line pool. One pooled BillboardGui per
  manager, MaxDistance-culled, event-driven. → W-R87 manager builder.
- Implemented (M-managers, 2026-10-31): `Tycoon/Npc/ManagerTags` (billboards) +
  `Npc/ManagerTagLogic` (pure) + `Config/ManagerTagConfig`, driven from `ManagerController`'s existing
  refresh pass (no new loop). Decision: job-title hires (Nuke Town A2-A10) show the job title in the
  chip ("FOREMAN") and a pooled kid-safe name ("Captain Kaboom"; robots get robot names), stable per
  OWNER + producer (rejoins, servers, plot slots); managers the pads already name (Uncle Atom, every
  Dino / Moon character) show that canon name under a "MANAGER" chip. Bubbles: owner only, near only,
  one per plot every 20-40 s, quiet while dazed. The tag gives way to its producer's
  billboard on screen (slides sideways, eased; hides only if it cannot clear) and lifts above the
  dazed stars. `hideOtherPets` is pets-only, so not reused
  (others' tags: shorter range, no bubbles). Details: `docs/managers.md` "R87";
  tests `tests/manager-tags.luau`; captures `docs/verification/r87-manager-tags/`.

### R88. Name your plot from its front sign
> "allow players to name there plots bly clicking on it and on controller being near the sign in
> the front"

- The plot's entrance sign ("<Name>'s Nukes") becomes renamable by its owner from the start (no
  unlock): click / tap the sign (ClickDetector), or walk up to it with a controller / keyboard
  (ProximityPrompt "Name your plot"). Opens a naming window (gamepad + on-screen keyboard
  friendly); the server validates, rate-limits, filters the text for everyone
  (TextService broadcast filter), saves it outside profile.tycoon (survives Rebirth) and shows it
  on the sign in every world. Default stays "<DisplayName>'s Nukes". → W-R88 plot-name builder.
- **Implemented (N-plotname, 2026-10-31)** — `docs/plots.md`. Server `Tycoon/PlotNames` (remote
  `RenamePlot`, "" = reset; parse + normalize, 3-then-1/10 s limit, broadcast filter, censored
  names refused, re-filtered once per session on display) + `Tycoon/PlotNameAdmin` (admin
  "Reset Plot Name"); `PlotBuilder.setPlotName` on every world's builder, sign part tagged
  `SNPlotSign`, plot attribute `PlotName`; `profile.plotName` (top-level, survives Rebirth,
  snapshot field); client `Tycoon/PlotSign` (ClickDetector + hover outline + walk-up prompt
  E / X / tap) → `Screens/RenameStand` plot mode (RESET button). Analytics
  `renamePlot:<set|reset|admin>`. Decision: the stand keeps its own "Fresh Nukes!" default.
  Tests `tests/plot-name.luau`, `tests/profile-logic.luau` §13; QA `tools/qa/r88_plot_name.py`.

### R89. Learn from other sell / tycoon games (owner recording)
> "I recoreded some stuff from a couple other sell/tycoon games, /Users/jamesbayless/Movies/2026-10-31
> 17-52-32.mov can you use any of the video to make our game super unique and competitive?"

- The 14-min recording is studied frame by frame (research agent V-video): per-game mechanics, UI,
  juice, retention, social and monetization patterns, a gap list against SellNukes, and ORIGINAL
  SellNukes-themed twists (inspiration only — no cloned content, names, art or layouts). The top
  gaps become the next build wave after 0.6.1. → lead + V-video.
- Wave 1 §3 (G-gifts): Early Gift Ladder (10 playtime gifts at 1–120 min, deterministic, kept all
  UTC day, CLAIM ALL; old saves migrated), Pocket Rocket (19 R$ daily impulse product = 5 min of own
  income, never better value per R$ than a Cash pack; live "+$" HUD offer) and the one-time,
  never-rewarded favorite prompt (10-min gift / rebirth). → `docs/gifts.md`.
- Wave 1 §2 (E-events): Nukey's Happy Hours — deterministic UTC schedule (5-min headline at :00
  rotating Confetti Storm / Sprinkle Surge / Double Pops / Egg Stampede / Low-Gravity Hour, 3-min
  mini Sprinkle Surge at :30; pure `HappyHourLogic`, `flavorLuckAt` feeds Surprise Batches), server
  pickups (coins / dino eggs / moon rocks, walk-in, server-validated), +25 % eventCash, event gravity
  + glide, HUD chip + schedule panel + start banner, admin force / stop / skip / kill switch on every
  server (DataStore + MessagingService). → `docs/happy-hours.md`.
- Wave 1 §1 (F-flavors): Surprise Batches — every finished batch rolls a flavour on the SERVER
  (Sprinkle 1/20 x1.5, Glitter 1/100 x3, Rainbow 1/500 x5 + producer glow, Galaxy 1/2,500 x20 and
  Mystery Pop 1/25,000 x100 + a ≤ 3 s owner reveal), aggregate + bounded per tick, +7.1 % average lift
  inside the pacing sim; Flavour Book (Pets window FLAVOURS button, 3 worlds × 5 flavours, gems
  claimed once); Big Pop broadcast (Galaxy+ batch / Mythic+ hatch / rebirth: banner + system chat
  line + toy fireworks, throttled + coalesced); quest stat + daily mission `flavor`; admin settings /
  grant / Book reset. → `docs/flavors.md`, `docs/economy.md` "Surprise Batches".

### R90. 3D hands-on interactions, not just clicking

> **Order Window part superseded by R128 (2026-11-01): removed. Mega Lever + Tip Jar stay.**
> "I think also the two games I showed have 3d interaction elemnets as well instead of just
> strictly clicking"

- Decision (autonomous, rule 1; original SellNukes versions, inspiration only): add a hands-on 3D
  layer to the core loop — (1) the Order Window: toy customers (robots / aliens / dinos per world,
  Blender-built) walk up with an order bubble ("3 Sprinkle nukes!"), the player picks finished
  nukes off a producer's output tray, carries them in their hands and hands them over for a tip +
  1–3 stars; (2) the Mega Lever: a giant lever at the plot you pull (hold) every few minutes to run
  a Mega Batch down a 3D conveyor; (3) the Tip Jar: a glass jar that fills with coins while you
  play and pays out when you walk into it. All one-button (ProximityPrompt / Interact) on every
  device, server-authoritative, never required (passive income untouched). Spec:
  `docs/superpowers/specs/2026-10-31-r90-hands-on-design.md`. → W-R90 builders.

### R91. Finish and publish before building more
> "before you build that though finish the other stuff so I can publish"

- R90 (hands-on interactions) paused before any code (builder stopped). R89 (flavours, Happy
  Hours, gifts) parked behind config flags defaulting OFF (zero player-visible change) so the
  in-flight R79–R88 work ships as 0.6.1 first; R89 / R90 resume after the publish. → lead.


## 2026-10-31 — Fill existing servers before creating more

> "can you make sure the servers fill before another server gets started with server maganement. I dont know if you can do that in the dashboard or not"

Inspect the supported Creator Dashboard server-fill and matchmaking controls. Configure the
closest supported fill-first behavior while retaining the existing eight-player limit, verify
it after saving, and document any Roblox platform limits rather than promising a strict global
server-allocation guarantee. Preserve unrelated settings and active player sessions.

Implemented in Creator Dashboard: Social Slots changed from Roblox optimized to Disable;
maximum stays 8, both verified after reload. Details and evidence: `docs/creator-dashboard.md`
§ Server fill preference. No server restart or runtime change.

### R92. "just finish em"
> "bro just finish em it just feels like they are oging in circles"

- Builders resume and FINISH their features (R85, R87, R89 back ON by default — not parked), code +
  Lune tests + check.sh only, no Studio; the lead runs one consolidated Studio pass, then commits
  the release for the owner to publish. → lead + builders.


## 2026-10-31 — Harvest Feast page event and another price reduction

> "setup the harvest feast event on the page as well. Also cut developer products down 20% and gamepasses another 30%"

Create/publish the Harvest Feast listing on the experience page using the existing gameplay
window (2026-11-01 00:00 UTC through 2026-12-01 00:00 UTC), accurate event rewards, and existing
Harvest artwork. Read CURRENT live prices before reducing developer products by 20% and passes
by another 30%, rounded to whole Robux; keep managed pricing. Verify all saves and align the
local fallback catalogue, change notes/version, and documentation without staging unrelated work.

Implemented: public Harvest Feast listing and live game-page event card; 35 products and 11 passes
reduced and read back. Details and complete audit: `docs/creator-dashboard.md`.

### R93. Start the 3D hands-on interactions
> "okay now start working on the other stuff you were going too. I think it was like the 3d elemetns"

- R90 resumes after the 0.7.x publish: Order Window (H-orders) and Mega Lever + Tip Jar
  (K-kinetic), per `docs/superpowers/specs/2026-10-31-r90-hands-on-design.md`. Builders code + Lune
  tests only (no Studio playtests, per the R92 lesson); the lead runs one Studio pass at the end.

### R94. Harvest Shop button clips
> "also juste some things to fix, the harvest shop clips off" (screenshot: "HARVEST SHOP" text and
> the acorn spill past the yellow button in the Feast Sticker Sheet)

- StickerSheet's HARVEST SHOP button widened to 330 px with 32 px text, and StudUI.button now
  shrinks any label that would overflow its button (event-driven, ≥ 60 % of the size) so no stud
  button anywhere spills text past its edges. → lead.

### R95. Fewer offers on screen
> "I also thing there is a lot of UI on the screen. I think maybe 1-2 offers at a time?"

- The right offer column shows at most `UIStyleConfig.Hud.MaxOfferSlots = 2` offers at once; the
  rest rotate through the second slot every `OfferRotateSeconds` (HudPlacement.rightColumn cap,
  HudOffers' existing rotation). → lead.

### R96. Golden Turkey sunk into the ground
> "the turkey i in the ground" (screenshot: a Golden Turkey half below the road, its Catch prompt
> floating at ground level)

- Turkey spawns snap to the ground surface with the model's real height (bounding-box bottom on the
  raycast hit), on plots and in the hub. → W-R96 feast builder.

### R97. Start the Feast Sticker Sheet with a few stickers
> "start people off with like 3-4 filled in" (screenshot: Feast Sticker Sheet 0/20)

- Decision: every player gets 3 free starter stickers (the commonest ones, server-granted once per
  season, idempotent flag) — new players on their first event join, existing players topped up to 3
  on their next join; a toast says so. The Gobble Bomb still needs all 20. → W-R96 feast builder.

### R98. Shop items animated + readable
> "the item in the shop should be animated. also they are hard to see with the stud background."

- Shop pack / offer item icons get a gentle idle animation (bob + sparkle, reduced-motion aware) and
  a soft backing plate / glow so they read against the stud surface. → W-R98 shop builder.

### R99. Lobby Lucky Spin doesn't work
> "the lobby lucky spin doesnt work." (screenshot: standing on the hub wheel's platform, nothing
> happens; objective "Spin the Lucky Wheel 0/1")

- The hub's physical Lucky Wheel opens / spins the Lucky Wheel (prompt + walk-on, every device).
  → W-R99 lobby builder.

### R100. Living lobby
> "The lobby feels a little dead, maybe have some random roblox npcs like r15 rigs just walk around
> and talk and stuff."

- Client-side R15 visitor NPCs (kid-safe outfits, no real people) stroll the hub paths, sit on
  benches, wave, and show short kid-friendly chat bubbles; pooled, culled, one loop. → W-R99 lobby
  builder.

### R101. Lobby stall nametags clip
> "the stall nametags clip in loby." (screenshot: the Supply Crates stall's sign text cut off)

- Hub stall signs fit their text (auto-size / shrink, clear of the awning). → W-R99 lobby builder.

### R102. Popup priority queue
> "sometimes UI will clip like this when it pops up, need a priority queue." (screenshot: the LUCKY
> BUTTON chip over the GALAXY reveal; elsewhere the Big Pop banner under the hint bar and a NEW
> FLAVOUR toast)

- One central popup / banner priority queue: centre banners and reveals show one at a time by
  priority (reveal > Big Pop > Happy Hour > juice > lucky chip), lower ones wait or expire, and
  nothing overlaps the hint bar / objective chip. → W-R102 queue builder.

### R103. Vehicles stopped animating
> "none of the vehciles are animating like they uised too" (screenshot: plot scooters + delivery van
> parked still on their loop roads)

- Regression hunt: VehicleRoutes itself is unchanged since R57, so suspect boot order (a newly added
  client controller whose Init yields blocks every controller after it), FxQuality, or streaming.
  → W-R103 vehicles builder.

### R104. Attack picker shows no base
> "you cant see peoples bases in the attack menu" (screenshot: the target picker camera over empty
> blue sky; only the area buttons + crosshair)

- The picker must stream the target plot in (RequestStreamAroundAsync / a server-side stream request)
  before the camera flies there, with a loading shimmer until it is there. → W-R104 attack builder.

### R105. Silo Launch billboard clipping
> "the site launch gui is clipping" (screenshot: the Silo Launch producer billboard overlapping the
> AA TOWER / SILO TOWER pad billboards)

- Defence tower pad / upgrade billboards stay clear of producer billboards (shared placement rules,
  shorter range). → W-R104 attack builder.

### R106. AA towers animate
> "the AA towers should aniamte around" (screenshot: Back Tower Lv 4/5 standing still)

- Idle animation for every owned AA tower: the turret sweeps / scans, the radar dish spins, barrels
  recoil when it fires; client-side, one loop, culled. → W-R104 attack builder.

### R107. "what is the galaxy batch for?" / "where are the flavours at??"
- Answered in chat (Surprise Batches: rare batch flavours paying x1.5–x100; Galaxy = 1 in 2,500,
  x20 + reveal + Big Pop; the Flavour Book lives in Pets → FLAVOURS). Consider a first-time tip
  pointing to the Flavour Book. → lead.

### R108. Batch pops take too much screen
> "I think the popping batches are a bit absurd with the UI they take. can they just take up the
> bottom left?"

- Big Pop announcements become a compact bottom-left feed (small stud pills, max 3 stacked, ~5 s,
  clear of the left grid / thumbstick / hint bar); the owner's own Galaxy+ reveal drops the
  letterbox + HUD fade and plays as a larger card in the same bottom-left corner. → W-R102 queue
  builder (owns those presenters now).

### R109. Silo rockets really launch and reload
> "make sure when you launch rockets the rockets actually leave the base and recharge load back"
> (screenshot: the Launch Silos with three rockets standing in their gantries)

- On every launch (normal / revenge / golden / barrage) a silo rocket on the launching plot lifts off
  out of its gantry (smoke + flame, the same flight the attack system draws), the gantry stands
  empty, and a fresh rocket rises back in over the launcher cooldown (build-in style), visible to
  everyone; barrages cycle through the silos. Client-side, pooled. → W-R104 attack builder.

### R110. Fewer cards on the left
> "can we cut down on the cards on the left at all? there is just a bunch lol" (screenshot: 8 tiles —
> Shop, Pets, Rewards, Quests, Rebirth, Teleport, Attack, Event)

- Decision: the left stack becomes 6 tiles — Shop, Pets, Quests, Rewards, Attack and a new MORE
  tile. MORE opens a compact stud flyout beside the grid with Teleport, Rebirth, Event (while live)
  and Settings; child badges / NEW tags roll up onto MORE. Phone grid becomes 2 x 3. Fully
  controller-navigable (D-pad into the flyout, B closes). → W-R110 HUD builder.

### R111. Claim toasts block the UI
> "collecting goals blocks up the ui. should be a toast on the bottom left" (screenshot: three
> "Goal claimed! +N Gems" toasts stacked over the Quests window's header / Nuke Pass banner)

- Decision: every toast (claims, rewards, notices, errors) moves to one compact bottom-left stack
  shared with the R108 feed (newest at the bottom, max 4, merges repeats like "Goal claimed! x3"),
  never over an open window's content; clear of the left grid / thumbstick / hint bar. → W-R102
  queue builder.

### R112. "so what is the point of a batch?? it's real confusing"
> screenshot: the reveal card "Pocket Nuke Workbench / GALAXY! / BATCH X20!"

- Decision: plain words everywhere. Players see "LUCKY NUKES" (not "batch"): the reveal reads
  "LUCKY NUKES! Your Workbench made GALAXY nukes — sold for x20: +$31.8M"; income pops read
  "GALAXY x20"; Big Pop reads "<name> got GALAXY nukes! (1 in 2,500)". The first lucky nuke a
  player ever gets shows a one-time tip card ("Sometimes your machines make rare flavoured nukes
  that sell for more! Collect them all in Pets → FLAVOURS for gems."). WHAT'S NEW / docs updated.
  → W-R89 flavours builder (copy + tip), presenters' placement stays with W-R102.

### R113. Hide the top UI while the wheel spins
> "in spin hide the ui on the top as well" (screenshot: currency stack, boost badge, LUCKY BUTTON
> chip and a "You won +5 Gems!" toast over the spinning wheel)

- While the disc spins, the LuckyWheel screen holds focus reason "LuckyWheelSpin" fading the Hud
  (currency stack), BoostChips, LuckyArrow, HappyHourChip and BigPopBanner; released on landing and
  on close (gems stay visible while idle, since 2x/5x/10x spins cost gems). Toasts move bottom-left
  with R111. → lead.

### R114. "how do the orders work?"

> **Superseded by R128 (2026-11-01): the Order Window system was removed.**
> screenshot: the ORDERS window with three toy robots and bubbles "x1", "x1", "SPRINKLE!"

- Answered in chat. Decision: the Order Window must explain itself — bubbles say "Bring me 1 nuke!"
  / "Bring me 1 SPRINKLE nuke!"; while carrying nothing, a ground arrow leads from the window to the
  nearest machine tray (and back once carrying); a one-time tip card the first time customers
  appear; the window sign shows "Pick up nukes at your machines → bring them here". → W-R90 orders
  builder.

### R115. Cashier Bot automates orders

> **Superseded by R128 (2026-11-01): the Order Window system was removed.**
> "when you have the cashier bot shouldnt it be automated?"

- Decision: owning the Cashier Bot (the stand's manager hire) makes the Order Window serve itself —
  the bot hands customers their nukes on a steady timer with a small animation, paying a reduced tip
  (config, e.g. 40 % of a hand delivery, no stars) so serving by hand still pays more; the window
  sign says "AUTO: Cashier Bot". Stays inside the pacing headroom. → W-R90 orders builder.

### R116. Mega Lever + Tip Jar sit outside the plot
> "hese things are out of the plot" (screenshot: the Mega Lever and the Tip Jar on the open grass
> beyond the plot's white fence)

- Move both inside the plot boundary, by the Nuke Stand / front yard, on walkable plot ground, clear
  of pads, producers, the Order Window, walk lanes and the fence; same spot rule in every world.
  → W-R90 kinetic builder.

### R117. Orbital Launches upgrade board too high
> "oribtal launches uphrade ui is too high up" (screenshot: the Space Port's Orbital Launches
> producer board floating near the top of the tall rocket, far above the player)

- Producer boards for very tall producers (the orbital rocket, silos, towers) sit beside the
  producer at eye height instead of above its top; the readability limits (max elevation from the
  stands) are tightened and audited for every producer in tests/billboard-clearance. → T-tutorial.
- Implemented (T-tutorial, 2026-11-01): BillboardPlacement `MaxCentre` 10 (board centre ≤ 10 studs
  over the producer's floor) + `TallBody` 9 (taller producers: no "above" board), MaxElevation
  16 → 13, NearElevation 30 → 24. Orbital Launches: board was ~19 studs up over the 36-stud gantry,
  now beside it 8.5 studs up. Other systems' props are solver obstacles (Tycoon/BillboardProps).
  BillboardSpots regenerated; tests/billboard-clearance §11–13.

### R118. Attack picker aim buttons overlap
> "all of these clip" (screenshot: the picker over Mega Meltdown Mart — the base now loads (R104),
> but the aim buttons BIG MACHINE / WAREHOUSE / WORKSHOP / TOY SHOP sit on top of each other,
> cutting each other's labels; "READY TO NUKE!" also overlaps text behind it)

- Aim buttons never overlap: projected anchors are de-collided (pushed apart with leader lines to
  their area), or fall back to a tidy row of chips when the areas crowd on screen; labels always
  fully visible; status lines don't overlap. → A-attack2.

### R119. Silo Launch board clips the gantry frame
> "silo launch is clipping in the frame in the photo" (screenshot: the Silo Launch producer board
> drawn through the steel gantry beams, partly hidden behind them)

- Same fix family as R117: the Silo Launch board moves to a clear spot beside the gantry at eye
  height (never inside / behind the frame's beams), and the clearance audit includes the gantry
  frame pieces. → T-tutorial.
- Implemented (T-tutorial, 2026-11-01). Cause: the gantry WAS in the geometry (A7_SiloBase Frame +
  Beams), but the solver tested the board only as a front-facing panel; a BillboardGui faces the
  camera, so from the side stands it swung back into the frame. Now every candidate is tested
  front-facing AND facing each viewpoint's camera (pitch included). Silo Launch moved forward
  (z 40.8 → 39.3), clear of the frame from every stand; every frame / truss / gantry producer
  (A4, A6, A7, A9, Moon M5 / M6, ...) is audited (tests/billboard-clearance §13, with a regression
  proof that the old spot is caught). Bearings 45 / 50 → 46 / 51 (still on a 16:9 screen) so the
  Megastore's camera-facing device board stays low outside its glass shell.

### R120. Lucky Nuke popups are annoying
> "these popups are real annoying bro ngl" (screenshot: the big centre "Pocket Nuke Workbench /
> GALAXY! / SOLD FOR X20!" shout card covering the middle of the screen)

- Decision: no centre-screen flavour popups at all. The centre "shout" is removed; every Lucky Nuke
  shows only as (a) the tinted income pop over the machine and (b) one small bottom-left feed pill
  ("GALAXY nukes x20 +$31.8M"). The bigger bottom-left reveal card is kept only for a player's
  FIRST find of each flavour (with the Flavour Book claim), and at most once per 5 minutes; repeats
  merge ("GALAXY x3"). Big Pops of other players stay small pills. → W-R102 queue builder.

### R121. Garbled text stack above the Order Window
> "ui bug on the top of the order stand" (screenshot: a pile of overlapping black-outlined text
> ghosts — "+$…", stars, "(…)" — stacked above the ORDERS sign)

- Likely the tip / star pop labels: they fade the fill but leave TextStroke (outlines) behind and
  are never pooled-back / destroyed, so every delivery adds another ghost at the same spot. Fix:
  fade fill + stroke + images together, return to the pool when done, stagger repeated pops, and
  cap live pops. → H-orders2 (cc K-kinetic for the shared pop billboard).

## 2026-11-01 — Analytics review against the Roblox discovery algorithm (0.8.0)

### R122. "Maximize the game … the standards of the Roblox algorithm pool"
> "analyze the game's current small set of analytics, and working towards improving, come up with
> whatever you can in order to maximize the game. And the standards of like Roblox algorithm pool."

- Read-only live data (`SellNukesAnalytics_v1`, `d:2026-10-31` closed + `d:2026-11-01` to 07 UTC,
  via the connected Studio place; no key printed): 382 new players, 447 sessions, builds 0.5.1
  (10-31) and 0.7.1 (11-01).
- Roblox "Recommended for You" ranking (Creator Docs `discovery`, DevForum 2026-06-15): MOST
  important = play-through rate, first-play bounce (< 60 s, 61–180 s; negative), play days per
  user (D1, D2–7, D8–28), playtime per user (capped 60 min/day); IMPORTANT = intentional co-play
  days, qualified play sessions, spend days, Robux spent. Only users who joined organically from
  Recommended for You count.
- Where SellNukes stands: ~43 % of first sessions < 2 min; 20 % leave right after the plot loads
  (console 25 %); boot (loading screen) 1.5 s on 0.5.1 → 26 s avg on phones on 0.7.1 (45 of 71
  phone boots 30–45 s = the 30 s asset budget); playtime 6–7.6 min per DAU; tutorial step 6 → 7
  (Glow Lamp → Uncle Atom, the first manager at ~11 min of hand clicking) loses 74 %; D1 ≈ 2–3 %;
  95 % of sessions with no friend; Friends screen opened once; 0 purchases from ~150 prompts, most
  closed < 2 s (walk-in Lucky Button prompts, console shop); notification opt-ins collected but no
  notification is ever sent.
- Decision (autonomous, rule 1): ship the 0.8.0 "Algorithm pack" — fast first minute (loading
  hand-off ≤ ~8 s, background preload, boot-step analytics), automation by minute ~4 (Uncle Atom
  moved to pad 4, area 1 re-paced), return notifications (one useful, personal notification per
  opted-in player per day, sent by game servers through Open Cloud), co-play surfacing (HUD invite +
  Friend Boost chip + invite moments), no accidental purchase prompts (paid Lucky Buttons confirm,
  console focus never lands on BUY), and Roblox-aligned analytics + an admin "Algorithm" scorecard.
  Spec: `docs/superpowers/specs/2026-11-01-r122-algorithm-pack-design.md`. → lead + W-R122 builders.
- Implemented (lead + W-R122-boot / econ / notify / social / analytics, 2026-11-01): loading hand-off
  (critical 87 vs 222 meshes, 6 s asset budget, tap 20 s / auto 30 s, boot-step telemetry); Uncle
  Atom pad 4 (sim hire 1.9 min, was 5.9; longest gap 83 s; area 8.0 min; old saves safe); return
  notifications (dry-run until the owner adds the secret + message ids); HUD INVITE + invite moment,
  paid Lucky Button DEAL card, PurchaseGuard (7 accidental-prompt causes fixed); `rbx:*` analytics +
  admin "Roblox algorithm scorecard". check.sh ALL PASSED (108 suites); Studio pass in
  `docs/verification/r122/README.md`. Version 0.8.0 + WHAT'S NEW note "FASTER START!".

### R123. Leaderboard covers the INVITE button
> "do it" + "leaderboard covers the invite ui" (screenshot, Mac desktop: Roblox's player list —
> People / Cash, 3 players — drawn over the new top-right INVITE "+10%" button and the admin wrench)

- "do it": finish the two open R122 checks (HUD offer chip opens its card first; console L3 free of a
  Roblox default) in the next Studio pass.
- Roblox shows its player list top-right by default on desktop (keyboard / mouse); the HUD's top-right
  row (INVITE + admin chip) must never sit under it: on devices where the player list shows, the row
  moves left of the reserved player-list area; phones / tablets / console keep today's corner.
  → lead (HudPlacement / Hud), tests/hud-cluster.

### R124. Orders need a big on-screen button

> **Superseded by R128 (2026-11-01): the Order Window system was removed.**
> "when you do orders there needs to be on screen UI the R i shard to see. I like the on screen
> button you need to press clicking like we have in the tutorail" (screenshot: at the Order Window
> the only cue is "R Fame stars" in the bottom hint bar)

- At an order tray and at the Order Window the action shows as a BIG on-screen stud button in the
  R84 tutorial-focus style (pulsing ring + the device's glyph: R / R1 / tap), captioned GRAB / GIVE /
  FAME, clickable / tappable, controller-pressable; the hint bar keeps its entry. → W-R124 orders
  builder.

### R125. Order trays on every machine

> **Superseded by R128 (2026-11-01): the Order Window system was removed.**
> "all of the plots have the order nukes????" (screenshot: a "Fresh nukes (0/6) Pick up" tray with
> nukes on a mine machine; every built producer shows an order tray all the time)

- Owner follow-up: "only order tray is supposed to be on the second area."
- Decision: order trays exist ONLY on the producer(s) of the Order Window's own area (Nuke Town:
  area 2, the Nuke Stand; Dino / Moon: their window's area); no tray on any other machine. Shared
  pure `OrderLogic.trayProducers` drives the client trays / prompts / R124 button / guide arrow and
  the server (OrderPickup refuses any other producer: `notTray`).
  → W-R124 orders builder.

### R126. Order arrow never leaves; Cashier Bot doesn't finish orders

> **Superseded by R128 (2026-11-01): the Order Window system was removed.**
> "this blue arrow for the order system never goes away even if i give multiple orders out. Also II
> have the automated bot for the stand but the orders arent comnplted automatically?" (screenshot:
> the cyan chevron trail on the road; Cashier Bot owned, two customers waiting, one leaving "BYE!")

- Guide arrow: only for the first `OrderConfig.Guide.MaxServed` (3) hand-served orders ever, never
  while the window is automated, gone for the session after a hand-served order.
- Cashier Bot: with the window area's manager owned, every customer is served automatically ~4 s
  after reaching the counter (front first, takeout-box animation); no customer leaves unserved while
  automated; R115 reward rules kept; hand delivery still pays full. → W-R124 orders builder.

### R127. Hide the money counter in the Lucky Wheel
> "in the spin UI hide the money counter UI on the top since it clips" (screenshot: the gems / cash
> stack + 2x badge drawn into the wheel's "FREE SPINS READY: 3" title)

- While the Lucky Wheel is open the HUD currency stack (gems, cash, rate, boost badge) fades out and
  fades back when it closes; the list of screens that hide it is config
  (`HudFocusConfig.CurrencyHiddenScreens`). → lead (Hud).

### R128. Remove the orders system
> "bro hoineslty just remove the orders system entirely/"

- Supersedes R124 / R125 / R126. The Order Window system (R90 / R114 / R115: windows, customers,
  carrying, trays, Customer Fame, guide arrow, tip card) is removed from server, client, config,
  remotes, controls, quests and admin; old saves drop the `orders` field safely; an `order` daily
  mission in progress is silently replaced; the `orders` analytics family stays documented as
  retired so past days still render; Tip Jar + Cashier Bot keep working without orders.
  → W-R124 builder (re-scoped to the removal).

## 2026-11-01 — Next five Roblox badges

> "can you make 5 more badges now as well since the time has reset"

Create the next five planned area badges (Area6 through Area10), matching the first batch's art
style, using today's free dashboard allowance. Upload and enable each badge, wire verified IDs
into the existing server-authoritative award system without changing ownership bit order, test,
document, and commit only this task's changes. Do not spend Robux or publish the Studio place.

## 2026-11-01 — Configure notification IDs

> "can you setup the notification ids as well"

Create/configure the notification templates required by the current return-notification system
in Creator Dashboard, record their verified IDs in the existing config, validate copy against
actual gameplay triggers, and test/document the integration. This extends the next-five-badges
task; preserve current consent, eligibility, rate limits, and existing templates.

## 2026-11-01 — Private servers and notification secret page

> "setup private servers as well. also ere is the secrets page for you as well https://create.roblox.com/dashboard/creations/experiences/10773845696/secrets?annotation=Benchmark"

Enable free private servers (no price requested, so friends can host without a charge), retain the
existing player capacity, and verify the saved dashboard setting. Use the supplied Secrets URL
to inspect the notification secret setup; do not expose key values. Continue the badges and
notification-ID work.

Follow-up approval: **"yes do it"** — create the notification-only key for this universe, store
it as `SellNukesNotifyKey` for `apis.roblox.com`, and enable server HTTP requests. Completed:
all five badges Active and wired, three notification strings wired, scoped key Active, secret
created, Rojo HTTP enabled, and free private servers saved/reloaded. No live notification or
Studio place publication was performed. Runtime changes still require the owner's publish.

### R129. "why are people leaving so early"
> "why are people leaving so early" (pasted: analytics report TODAY, 2026-11-01 00:00–14:16 UTC —
> 355 new players, 407 sessions, avg 5:13, median 3:30, 38.6 % of first sessions < 2 min, D1 2.2 %)

- Read the report against the code. 99 % of the day ran on 0.7.1 / 0.5.1 servers; 0.8.0 (R122)
  shows only 4 new players (4 / 4 hired Uncle Atom, 2 / 4 opened area 2) — the R122 fixes are not
  measured yet.
- Where first sessions end (server-recorded): 16 % never step on the free first pad (loading, boot
  avg 28 s on phones, p50 30–45 s on 0.7.1; 0.8.0 boot steps finish ~7 s); 42 % stop between the
  first payout and pad 5 (minutes 1–4 of hand clicking); 20 % stop at pad 5 → Paint Station
  (142 → 82 buyers, 7× price jump, 2:50 wait) before the first manager at 6.8 min. R122 already
  targets all three (6 s asset budget, Uncle Atom pad 4 → manager at ~1.9 min, PurchaseGuard).
- Not fixed by R122: (a) Dino Valley unlocks at area 3 (~minute 14) and its WORLD UNLOCKED popup
  auto-opens — 19 of 41 pressed GO NOW, avg 2.3 min in Dino, 13 first pads, 1 manager; only 26 of
  41 bought area 3's first pad (R57 asked for the world "once you're completely done with the
  main game"); (b) area 3: Mobile App costs 8.3× GPS, the Dispatcher manager is pad 8 of 9 (6:20
  gap) → 41 reached area 3, 4 reached area 4; (c) return notifications still off (all three
  `NotifyConfig` messageIds empty; 37 opt-ins collected); (d) analytics bug below.
- Fixed (lead): the leave snapshot read the JOIN-time state when Analytics' PlayerRemoving ran
  before PlayerDataService's (and on shutdown) → "395 of 407 sessions end in area 1" and "401 own
  0 pets" were wrong. `Sessions.endSession` refreshes it from the live profile;
  `snapshot` reads the profile it is handed (`Runtime.areaFromProfile` / `rebirthsFromProfile`);
  regression test `tests/analytics-recorders.luau` §9b (fails on the old code).
- Proposed next (not shipped; owner "do it" ships 0.8.1): no auto WORLD UNLOCKED popup before main
  area 4 / the area-3 manager (chip + portal stay), Dino unlock at main area 4; area 3 re-paced
  like R122 area 1 (Dispatcher to pad 4, smooth the Mobile App jump) via
  `tests/economy-sim.luau --tune`.

### R130. Fix the Dino Valley pull-away + area 3's late manager
> "fix these two I guess?" — (1) "Dino Valley pulls players away at minute 14 … the WORLD UNLOCKED
> popup opens on its own. 19 of the 41 … pressed GO NOW … Back home, 15 of those 41 never bought
> area 3's first pad"; (2) "Area 3 has the old Paint Station problem. Mobile App costs 8.3× the pad
> before it, and the area's manager (Dispatcher) is the 8th of 9 pads … 41 reached area 3; 4
> reached area 4."

- (1) The WORLD UNLOCKED popup no longer opens by itself in the middle of a fresh area: it waits
  until the player has settled (rule + numbers in the implementation note below); the world
  stays unlocked and reachable through its chip, the Teleport menu and the portal.
- (2) Area 3 re-paced like R122's area 1: the Dispatcher (BoomDash manager) moves early in the
  area, the Mobile App price jump is smoothed, area length kept; old saves safe.
  → lead.
- Implemented (lead, 2026-11-01; ships in 0.9.0 — "BoomDash Delivery: hire the Dispatcher much sooner!"):
  (1) `WorldClientLogic.unlockPopupOwed` / `popupArea` + `WorldClientConfig.Unlock.PopupAreasAfterUnlock = 1`:
  the popup opens by itself only from Nuke Town area 4 (Dino) / 6 (Moon) or after a rebirth — also when
  the world was unlocked in an earlier session and the player crosses that area now without having
  visited; once per session at a polite moment; unlock rule, chip, Teleport tab, NEW dot and portal
  unchanged (docs/worlds.md). (2) Area 3: Dispatcher = pad 4, multiples 10 / 12 / 45 / 70 / 340 / 650 /
  2000 / 6000 / 18000, SCALE 22,100 -> 25,000 (sim: Dispatcher 1.7 min after the area opens, was 18.2;
  longest wait ~4.4 min, was 6.7; largest price step 4.9x, was 8.3x; area 22.2 min, unchanged), pad row
  re-spotted, `OPENING_CHECKS` area 3 (<= 3 min, <= 300 s), snapshot refreshed (95 area-3 values),
  `tests/boomdash-order.luau` (old-order saves). docs/economy.md + docs/tycoon-server.md "BoomDash order".
  Code checks only (owner R132: no Studio playtests).

### R131. Upgrade board buttons ignore keyboard + controller
> "none of the buttons on the upgrade guis are working. Keyboard and controller dont work the only
> thing that works is clicking them" (Studio screenshot: a producer board — x1 / UPGRADE [E] /
> 75 gems [C] — at the Nuke Stand)

- E / C / Q (keyboard) and their gamepad buttons must work on the nearest producer board again;
  find the regression, fix it, add a regression test. → lead.
- Resolved (owner: "also the buttons are working now"): a transient state while R124 / R128 were
  mid-edit (Rojo syncs every save into Studio; the Carry action / OrderClient were half removed).
  No code change needed: ActionMap already ignores unknown contexts and catches provider errors.

### R132. No Studio playtests for these changes
> "skip any studio playets for your changes, just code checks thats it"

- The lead's R122–R128 / R131 changes are verified with code checks only (`./scripts/check.sh`: format,
  lint, strict types, compile, Lune suites); no Studio playtest is started for them.

### R133. Attack picker still shows no base
> "when attacking people all I see is this, not their base still" (live-client screenshot: target
> <player> — a big grey stud panel fills the middle of the picker over empty blue sky; status
> "Area 1 · No AA tower · +$576/s", "STILL NEW – PROTECTED FOR A FEW MINUTES", "AIM: GARAGE";
> crosshair + GARAGE area button below; DEFEND! / PROTECTED / BARRAGE / CANCEL)

- R104's fix did not hold: the target's base must actually be visible in the picker. Find the root
  cause (streaming / camera target / the loading veil never clearing), fix it, regression test.
  Code checks only (R132). → lead.
- Done (lead, docs/attack.md §21). Two root causes: (1) the grey panel is the R118 info plate, whose
  UIListLayout sat directly on the studded plate and stacked its stud backdrop + highlight as list
  items (AutomaticSize grew it to ~550 px) — lines now live in an inner Content frame with an
  explicit height; (2) the camera looked from ~890 studs, which a live client does not draw (both
  streaming fixes left the sky empty) — `Shared/Attack/PickerFrame` frames the BUILT areas close
  up (new garage 156 studs, max 320; a big base keeps the aimed area in view and pans with the
  aim), and the stream focus sits on the built base. tests/attack-view.luau §2 / §8.

### R134. Remove the little teleports
> "can we remove these little teleports" (live-client screenshot: the Nuke Town lobby, standing on
> plot 8's pink avenue in front of the "PLOT 8 / JusticeDev" signpost teleport pad and its round
> pad ring)

- The hub's plot teleport pads (HubLayout `PlotTeleportPads`, ring r 62 around the spawn; signpost
  + pad ring + touch trigger) go away. Players still reach plots by walking the avenues and through
  the Teleport menu. → lead (after R133).
- Done (W-R134-pads): pads, digits, labels, triggers and the portal fallback are removed from every
  hub (Nuke Town, Dino Base Camp, Moon Landing Plaza); plot gates at r 222 stay; owner names live on
  each plot's entrance sign; the Teleport menu (hub / own areas free, other plots with the Teleporter
  pass) and the join reveal remain. Test `tests/hub-no-teleport-pads.luau`. Shipped in 0.9.1.

## 2026-11-01 — Analytics check-in (report TODAY to 17:33 UTC)

### R135. "any news on analytics?"
> "any news on analytics?" (pasted: analytics report TODAY, 2026-11-01 00:00–17:33 UTC — 489 new
> players, 569 sessions, avg 5:13, D1 2.2 %, manager 27 %, area 2 22.3 %, R$ 79 from 1 purchase,
> scorecard: bounce < 60 s 5.9 %, 61-180 s 9.6 %, playtime 1.6 min, R122 coverage 28.5 %)

- Answer the report's nine questions from its numbers, split by build (0.9.0 vs 0.7.1) where the
  report allows it; check suspicious numbers against the code; fix measurement bugs found;
  propose (not ship) design changes, as in R129. → lead.
- Findings (lead; the window was still open, so everything is provisional). R122/R130 work on 0.9.0
  (p292, 103 new) vs 0.7.1 (323 new): loading done 95 % vs 90 %, first upgrade 83 % vs 73 %,
  manager 50 % vs 20 %, area 2 30 % vs 20 %, area 3 14 % vs 12 %; playtime 6.6 vs 5.9 min per
  player-day. Still 21 % of first sessions end < 60 s and 35 % at 61–180 s (R122+ servers,
  136 first sessions). Next walls: Tool Wall ($42 after ~1 min of $1 clicks; 419 → 319 buyers)
  and area 2, whose manager (Cashier Bot) is pad 8 of 10 behind 5.8x / 4x price jumps (109 opened
  area 2 → 73 Cashier Bot → 57 area 3). D1 2.2 % = 5 of 232 (10-31 cohort, old builds); the first
  0.9.0 D1 reads 11-02. 1 purchase (Barrage R$ 79). Full answer in the session.
- Fixed (lead, measurement only, no player-facing change): (1) scorecard bounce divided R122-only
  numerators by every joined player (read 5.9 % / 9.6 %, really 21 % / 35 %), and playtime /
  qualified / co-play divided by all player-days (1.6 min / 0.14 / 2 %, really 5.9 min / 0.51 / 7 %):
  `ReportSections` now uses Σ `rbx:bounceDev:*` and the R122+ builds' `build:*:dau` with a SAMPLE note
  (`tests/analytics-algorithm.luau` §4 / §4b incl. the live numbers); (2) `tutorialSeen` /
  `firstScreenClosed` were sent during the plot reveal, refused by the server and never re-sent
  (148 vs 429 hint arrows): `FtueLogic.claimReady` + `FtueTracker` wait for PlotRevealed
  (`tests/ftue-logic.luau` §4b). docs/analytics.md, docs/analytics-scorecard.md.
- Proposed next (not shipped; owner "do it"): area 2 re-pace like R122 / R130 (Cashier Bot to
  pad 3–4, smooth the Neon Sign and Cashier Bot jumps); a quicker first two minutes (Tool Wall /
  Glow Lamp waits ~20–40 s); record offer BUY presses (`Revenue.offerClicked` has no caller, so
  every "click 0 %" is missing data); re-check accidental prompts on a full 0.9.x day.

### R136. "a little more time has passed today"
> "a little more time has passed today." (pasted: analytics report TODAY to 22:27 UTC — 614 new
> players, 711 sessions, avg 5:27, D1 3 %, manager 31.4 %, area 2 24.4 %, R$ 79; build 0.9.1:p305
> live with 116 new players; offline payouts 84.4 % of all cash; rnotify results ok 21 / rejected 59)

- Re-read the update against the earlier R135 answer: what changed, the new 0.9.1 build, the
  corrected scorecard numbers, and anything new that needs a fix. → lead.
- Findings (lead): 0.9.1:p305 (116 new) — loading done 100 %, manager 47 %, area 2 33 %, area 3
  20 % (best yet; 0.9.0 14 %, 0.7.1 12 %), 7.2 min per player-day. Old builds took no new players
  after 17:33. Corrected scorecard (R122+ servers, 259 first sessions / 265 player-days): bounce
  21 % < 60 s, 32 % 61–180 s, playtime 6.6 min, qualified 0.52, co-play 7 %. R135's fixes are not
  live (the report still divides by 614 joined; 0.9.1 still reads tutorialSeen 40 of 116) → the
  owner must publish. Return notifications are live: 21 ok, 59 rejected — every send so far is
  cashFull (streak / missions wait for tomorrow), the key works (21 ok), so the rejections are
  per-player 4xx: Roblox only delivers to opted-in players 13+ and answers 400 otherwise.
  Offline = 84 % of cash: one late-game player (areas 7–10), 50 % × 3 h as designed — no bug.
- Fixed (lead): `rnotify:status:<kind>:<400|401|403|404|429|4xx|5xx>` (ReturnNotifyLogic.statusBucket
  + ReturnNotifyRunner.noteStatus) so the report shows WHY a send failed; tests/return-notify.luau.

### R137. "do whatever you want and fix"
> "Once you figure it out, do whatever you want and fix."

- Ship the R135 / R136 proposals: area 2 re-pace (Cashier Bot early, smooth the price jumps), a
  quicker first two minutes in area 1, record offer BUY presses (`Revenue.offerClicked` has no
  caller). Code checks only (R132). → lead + builders.
- Done (lead + W-R137-econ / W-R137-offers, 0.9.2): area 1 Tool Wall $11 / Glow Lamp $19 (sim 0.48 /
  0.64 min, Uncle Atom 1.22, was 1.10 / 1.61 / 1.93; area 7.0 min, later areas unchanged); area 2
  Cashier Bot pad 4 (0.85 min after opening, was 6.5; longest wait 132 s, largest step 4.3x; old
  saves safe, tests/stand-order.luau); offer BUY presses counted server-side from the PromptProduct /
  PromptPass request (offer surfaces only, capped, no new remote), report shows "click n/a" for
  older days. WHAT'S NEW: two IMPROVED lines. SELLNUKES_CLAUDE_DOCUMENTATION.md 0.9.2 + R137 entries.

### R138. Happy Hour chip too big on iPhone
> "the sprinkles UI takes up a lot of the screen on my iphone., big issue" (live-client iPhone
> landscape screenshot: a wide studded "★ LIVE: SPRINKLES 0:13" banner sits top-centre under the
> cash counter, ~1/3 of the screen wide, over the Nuke Stand billboard; HUD buttons left, INVITE /
> admin right, "Hatch an egg 0/1" quest bar bottom-centre)

- Make the Happy Hour chip small on phones (and sane everywhere): it must not dominate the view or
  cover world billboards; keep it readable (≥ 44 pt tap target) and controller-navigable. Code
  checks only (R132). → lead.
- Follow-up: "show me an ss when you do it" — the owner asks for a screenshot of the fix, so this
  change gets a solo Studio check in the open place (an explicit exception to R132; studio-lock).
- Done (lead, fe1ded0 + this fix; 0.9.2): phones show `[star] 0:13` at 99 x 45 pt (13 % of an iPhone 14's
  width, was about a third), beside the cash (right, then left), else under INVITE; above the
  character's head only as a last resort. The Studio check caught what the tests missed: the first
  fix (177 px) fit neither side gap and sat above the head. Now 159 px, new `underTopRight` spot,
  tests use measured iPhone 14 zones. Captures + README: docs/verification/r138/.

### R139. Package the whole SellNukes workflow as a Roblox game-development skill on GitHub
> "can you save everything specific about developing this game into a roblox game development
> skill. everything from the specific screenshots that I used for you to reference the UI to how
> the UI is made to how I have you make all the art in Blender and show me screenshots and how you
> show me screenshots of all the in-game stuff, all the testing infrastructure, all the analytics
> and ambient [admin] panel structure that you have. And anything ... you have documented, make it
> into a Roblox skill and put it on GitHub for me."

- A Claude Code skill (SKILL.md + references + scripts + the owner's reference screenshots) that
  captures every documented practice: owner rules, toolchain, UI framework + stud panels,
  reference images, Blender → Roblox art pipeline, Studio MCP screenshots / device matrix, testing
  (Lune, economy sim, check.sh), analytics + reports, the admin panel, server security,
  economy / monetization / retention patterns, docs + owner-request workflow. No secrets.
  Published as a private GitHub repo for the owner. → lead + writer subagents.
- Done (lead + 7 writers, 2026-11-01): https://github.com/Justice219/roblox-game-dev (private; 54
  files, 9.2 MB): SKILL.md, 12 references (~7,000 lines), scripts, config templates, all 26 reference
  screenshots compressed (59 MB -> 8.7 MB). "ambient panel" read as the admin panel. Secret / email /
  name scan clean. Three writers hit the account's weekly limit before reporting, so the lead checked
  their files (coverage, links, code fences, sampled facts against the repo). No formal skill evals
  were run (rule 1: no owner review loop). Also fixed docs/core.md (HttpEnabled is true since b1e3a40).

### R140. "finish it fully"
> "finish it fully" (after the R139 skill report listed its limits: documentation without the code,
> a partial review, no fresh-session test, no refresh path, not installed; plus the R138 screenshot
> still pending)

- Close those limits: bundle the real source, verify every reference against the repo, add a
  refresh script, test the skill in a fresh session, install it locally, retry the R138 screenshot.
  Publishing the game stays the owner's. → lead.
