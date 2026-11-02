# SellNukes owner admin panel (B14)

Spec §14 / owner R6: *"an admin panel built in that I have access to as the owner of the
experience"*. Ported from RoBeasts' AdminService / AdminPanel and rebuilt on the SellNukes stud kit.
The server re-authorises **every** command; the client only sends intents.

## 1. Who is an admin (server only — `Server/Admin/AdminAuth`)

`decideAdmin(userId, env, groupRank?)` is a pure function (Lune truth table: `tests/admin-auth.luau`):

| Rule | Admin? |
|------|--------|
| Studio (any player) | yes |
| userId ≤ 0 (live) | no |
| `AdminConfig.AdminUserIds` (owner **1586034782** is listed, so a group move keeps them in) | yes |
| user-owned experience and `userId == game.CreatorId` | yes |
| group-owned experience and highest rank ≥ `GroupAdminRank` (254) | yes |

Group ranks: `GroupService:GetRolesInGroupAsync` (pcall), cached 120 s, retried after 15 s, a stale
rank older than 600 s denies; concurrent lookups share one web call. The periodic push loop re-checks
admins whose cache expired, so a demoted member loses the panel without rejoining (`{ isAdmin =
false }` push + New Player Mode ended). The `IsAdmin` player attribute is a **display hint** only;
the server never reads it back. Kick / Ban refuse protected users (live rules: creator, allowlist,
group admins, online admins; unknown group rank counts as protected).

## 2. Command pipeline (`AdminService.submit` → `AdminPipeline.dispatchAsync`)

One remote, `AdminCommand(name, args)`:

1. **token bucket** per user (10 burst, 3/s) — synchronous, so spam never spawns work;
2. **re-authorisation** (`AdminAuth.isAuthorizedAsync`) — a failure or error denies; non-admin
   calls are dropped silently and audited at most once per 10 s per user;
3. **allowlist** (`AdminRegistry.isKnown`, `rawget`, strings only);
4. **availability** (Studio-only commands outside Studio, a missing seam → "needs …");
5. **per-admin per-command cooldown**;
6. **strict schema** (`AdminValidate.validateArgs`: plain table, no metatable, ≤ 8 string keys,
   unknown / extra / missing keys rejected, every value type- and range-checked, NaN / inf refused,
   text UTF-8 without control characters, byte pre-check before any UTF-8 work);
7. **target resolution** (user ids are lookup keys only: `Players:GetPlayerByUserId`);
8. **handler** under `pcall` (errors become a failure result, never escape);
9. **audit** (ring buffer of 200, printed to server output, pushed to every admin's Log tab) +
   **result** (`AdminResult { seq, ok, name, text }` to the caller + a `Notify` toast).

Malformed calls (unknown command / rejected args) are audited throttled (a tampered client cannot
flood the log). Lune: `tests/admin-pipeline.luau` (order, cooldowns, throttles, Studio-only,
unavailable, handler throws, ring cap, registered commands end to end) and
`tests/admin-validate.luau` (fuzz of every built-in command + `validateDef`).

## 3. Commands (`Shared/Config/AdminConfig.Commands`)

| Tab | Commands | Handler / seam |
|-----|----------|----------------|
| Players | GrantCash, TakeCash (never below 0), SetCash, GrantGems, TakeGems | `PlayerDataService` (SetCash prefers `TycoonAdmin.setCash`) |
| Players | SetArea, UnlockAll, ResetPlot, SetRebirths | `Server/Tycoon/TycoonAdmin` (B5) |
| Players | GiveBoost, GrantSpins, ResetDaily, AddPlaytime, ResetClaims | `BoostService.grant`, `LuckySpinService.grantSpins`, `RetentionService.resetDaily` + `PlaytimeService.resetToday`, `PlaytimeService.addSeconds`, `GroupRewardService` / `NotifyRewardService.resetClaim` |
| Players | TeleportTo, Bring, Kick, Ban, Unban | built in (`Players:BanAsync` / `UnbanAsync`, universe-wide, filtered display reason, raw private reason) |
| Economy | ServerBoost, ServerBoostOff, TestReceipt (Studio only) | `ServerBoostService.start/stop`, `MonetizationService.simulateReceiptAsync` |
| Server | Announce, SetTimeOfDay, AddCode, FlushAnalytics, Shutdown, CancelShutdown | built in / `CodesService.addCode` / `AnalyticsService.flushNow` |
| World | RebuildPlot, ReplayBuildIn | `TycoonAdmin.rebuildPlot(player, animate)` |
| World | VehiclesToggle ("Vehicles on/off", owner R56) | built in (`WorldHandlers`): sets ReplicatedStorage `VehiclesEnabled`; every client's `Tycoon/Fx/VehicleRoutes` parks / resumes the map vehicles live (this server, not saved) |
| New Player | NewPlayerMode, ExitNewPlayerMode | `PlayerDataService.enterNewPlayerModeAsync / exitNewPlayerMode` (B1 sandbox) |

Seams are looked up lazily (`Server/Admin/Seams`, pcall'd, retried every 10 s while missing). A
missing seam greys the button with its reason (`"needs Tycoon (B5 TycoonAdmin)"`) and the server
refuses the command. `TycoonAdmin` contract (B5): `setCash(p, n)`, `setArea(p, area)`,
`unlockAll(p)`, `resetPlot(p)`, `setRebirths(p, n)`, `rebuildPlot(p, animate)` → `(ok, message?)`.

## 4. Adding commands from another system (pets, attack, event, …)

```lua
local ok, AdminService = pcall(require, ServerScriptService.Server.Services.AdminService)
if ok then
	AdminService.registerCommand({
		name = "GivePet", tab = "Players", label = "Give Pet", target = "Player",
		args = {
			petId = { kind = "enum", values = PET_IDS, labels = PET_NAMES, label = "Pet" },
			count = { kind = "integer", min = 1, max = 50, presets = { 1, 5, 10 }, format = "count" },
		},
		argOrder = { "petId", "count" }, cooldown = 1, audited = true, confirm = false,
		color = "purple", order = 60, -- optional: description, studioOnly
	}, function(ctx) -- ctx.caller { userId, name, player? }; ctx.target { userId?, player?, label }; ctx.args
		return true, `Gave {ctx.args.count} pets to {ctx.target.label}` -- (ok, message)
	end)
end
```

WHAT'S NEW (`Server/Admin/ChangeNotesAdmin`, owner R58; Players tab): WhatsNewReset { seenUpTo =
"none" | note id } sets the player's seen note back and replays their returning-player pop-up;
WhatsNewPreview opens the panel on their screen in preview mode (hidden notes too, nothing marked).
Both saved / audited; see `docs/change-notes.md`.

Pet Index rewards (`Server/Services/PetService`, owner R78; Players tab; `docs/pets.md`):
PetIndexView (read-only: pets discovered / Total, milestones claimed + ready, Index Bonus);
PetIndexGrant { milestone = "5" … "60" | "all" } marks it claimed AND pays its gems + bonus
(ignores the pets needed; refused when already claimed; audited); PetIndexClear { milestone }
(confirm, red) un-claims it — the Index Bonus goes, gems already paid stay (audited).

Registered this way today: Attack (`Server/Attack/AttackAdmin`); Nuke Pass (owner R78, `Services/PassService`: PassGrantXp, PassSetTier, PassPremium, PassStatus, PassReset (Studio), and on the Server tab PassClock (Studio test clock); see `docs/nuke-pass.md`). Gift ladder (owner R89, `Services/PlaytimeService`: GiftLadderStatus, GiftLadderReset { ladder / rocket / favorite / all }, GiftLadderStep { step, unlock / claim }, FavoriteMomentTest (Studio); see `docs/gifts.md`). The knockdown commands (owner R50)
are built-in catalogue entries on the **Attack** tab (owner R51): KnockdownArea { area, seconds, bot },
KnockdownRebuild { bot }, KnockdownImmunityOff { bot }, KnockdownToggle { on }, KnockdownTuning
{ durationSeconds, immunitySeconds }, KnockdownStats (`Server/Admin/Handlers/KnockdownHandlers`,
`Seams.knockdown()`; `bot` 1..8 = TestBot N, 0 = your own plot). All live on this server, never saved.

* `tab`: Players | Economy | Server | World | NewPlayer. `target`: None | Player (online; the
  player is guaranteed) | AnyUser. Arg kinds: integer, number, text, enum (dropdown), boolean,
  banDuration, code; `optional = true` on any.
* The def is validated (`AdminValidate.validateDef`: name `^[%a][%w_]*$` ≤ 32, sane ranges, ≤ 400
  enum values, no `userId` arg) and frozen; a name clash errors. Register any time (Init/Start is
  ideal; AdminService boots last and has no gameplay requires, so `pcall(require)` never cycles).
* `AdminService.registerHandler(name, handler)` overrides the built-in seam call of an
  AdminConfig command that declares a `provider`.
* The panel shows registered commands on their tab automatically (Players: "More" group).

## 5. AdminState (server → admins only; `Server/Admin/AdminStatePush`)

`{ isAdmin = true, serverTime, isStudio, stats, players, recentBans, logVersion, log?,
catalogVersion, catalog?, availability? }` — exact shapes in `AdminConfig` (wire types) and
`Client/UI/Screens/Admin/AdminClient`. Pushed on change (coalesced, ≤ 4 Hz) and every 3 s while an
admin is online; nothing is built when no admin is online; the shared part is built once per push;
`log` / `catalog` are only attached when that admin has not seen the version. The push's Luau time
is reported as analytics health system `"Admin"`. Live stats come from
`AnalyticsService.liveHealth()` (fps, heartbeat, ping, per-system ms/s) + `Stats`.

## 6. Client (`src/client/UI/Screens/Admin/`)

| Module | Job |
|--------|-----|
| `AdminClient` | store: AdminState merge, catalogue, `send`, `Result`, `unavailable(name)` |
| `AdminPanelScreen` ("AdminPanel") | stud window, 8 tabs (LB / RB), status line, in-panel confirm (CANCEL pre-selected), "ADMINS ONLY" for others |
| `PlayersTab` | player list (cash, gems, area, rebirths, ping, save status, ADMIN / NPM badges) + per-player commands grouped (Currency / Tycoon / Rewards / Move / Moderation / More), offline-user ban box, recent bans quick UNBAN |
| `ActionsTab` | Economy / Server / World / New Player pages from the catalogue; announce presets, restart countdown, server boost remaining, local debug overlay toggle |
| `LiveTab` / `LogTab` | live server cards + per-system ms bars / audit log with All / Failed / Mine filters |
| `AnalyticsTab` + `AnalyticsExportScreen` | §13 report (headline cards, sections, ranked rows), COPY FOR AI / COPY RAW DATA (selectable text: Roblox cannot write the clipboard) |
| `CommandForm` | schema-driven controls (steppers + preset chips, "1.5M" typed amounts, enum pickers, text, toggles), greyed reasons, confirm |
| `AdminOverlayScreen` ("AdminOverlay") | for everyone: announcement banner + restart countdown; NPM badge with EXIT (above the objective chip **and** the hint-bar row so it never covers "E Buy"; centred between the Left/Right HUD zones, shrinks to ≥ 0.7 on phones; hidden while a menu is open); for admins: HUD "Admin" button, F2 / D-pad down binding (`AdminConfig.OpenKeys/OpenButtons`, bound only while `IsAdmin`), debug perf overlay |

Open with **F2**, gamepad **D-pad down**, the admin-only HUD **Admin** button
(`HudZonesConfig` row, B2), or `ScreenManager.open("AdminPanel", { tab = "Log" })`.

## 7. Server-wide banners (replicated attributes on ReplicatedStorage)

`AdminAnnounceText` then `AdminAnnounceAt` (server time) — banner for `AnnounceSeconds`;
`AdminShutdownAt` (server time, 0 = none) + `AdminShutdownReason` — countdown banner. Text is
filtered (`TextService` broadcast) before it is published; a live filter failure drops the text.
(Studio only: local test players have negative ids that TextService refuses, so the admin's own
text is shown there for testing.) At the deadline every player is kicked with
`AdminConfig.ShutdownKickMessage` (profiles release-save on leave) and late joiners are refused.

## 8. New Player Mode

`Shared/Util/NewPlayerMode` holds the predicate (`NewPlayerMode` attribute, equal to
`AnalyticsConfig.NewPlayerModeAttribute`) and the pure rules (save decision, purchase gate, receipt
deferral, enter / exit refusals; Lune: `tests/admin-new-player-mode.luau`). B1's PlayerDataService
parks the real profile (saved first), swaps in a never-saved sandbox (`ProfileUnloading` →
`ProfileLoaded(sandbox, true)`), refuses Robux prompts and defers receipts; analytics (B13) diverts
every event of the player to `core npm:<recorder>`. Exit swaps the real profile back; leaving ends
the mode; losing admin rights ends it.

**Where the owner finds it (owner R67):** a big yellow **PLAY AS NEW PLAYER** button in the admin
panel HEADER on every tab (green **EXIT NEW PLAYER MODE** while the mode is on). It asks through the
in-panel confirm with the command's description and sends the existing `NewPlayerMode` /
`ExitNewPlayerMode` commands (re-auth, cooldown, audit; no new server path); the New Player tab
keeps its buttons. While the mode is on, a small yellow **NEW PLAYER MODE · EXIT** chip sits in the
top-right corner, directly left of the HUD's admin wrench chip (HudZones "TopRight"; on phones it
first shrinks into the gap left of the wrench, else drops below it; hidden while a menu is open). EXIT arms on the first tap ("TAP AGAIN") and exits
on the second; gamepad: Left from the wrench chip, and the panel opens straight onto its EXIT
button. Rules: `Client/UI/Screens/Admin/NewPlayerQuick` (Lune: `tests/admin-new-player-quick.luau`).

## 9. Boot + verification

Add `{ name = "AdminService", module = require(Services.AdminService) :: Service }` **last** in
`src/server/init.server.luau` (lead). B13's `AnalyticsAuth` finds `AdminService.isAuthorizedAsync`
/ `isAdmin` automatically. Studio verification screenshots: `docs/verification/admin/`.

## 10. World commands (W4 worlds-travel, owner R57 World 2 — spec §13)

Declared in `AdminConfig.Commands` (provider `"Worlds (W4 MultiWorldHandlers)"`), handled by
`Server/Admin/Handlers/MultiWorldHandlers` (installed by `AdminService.Init`). Every one is
**audited**; destructive ones confirm in the panel (red: ResetRun, Wipe). The `world` argument is an
`enum` built from `WorldsConfig.Order` minus `"main"` (labels = world names), so a handler only ever
sees a registry world; `WorldSend` alone also offers Nuke Town (send them home). Area bounds follow
the largest extra world and are re-checked per world in the handler.

| Tab | Command | Args | Seam |
|-----|---------|------|------|
| Players | WorldUnlock | world | `WorldService.unlock(p, w, "admin")` — sticky, popup shows |
| Players | WorldRelock (confirm) | world | `WorldService.relock` — sends them home first, progress kept; the rule re-unlocks on the next area / rebirth / load event |
| Players | WorldSetArea (confirm) | world, area | `TycoonAdmin.worldSetArea(p, w, area)` |
| Players | WorldUnlockAll (confirm) | world | `TycoonAdmin.worldUnlockAll(p, w)` |
| Players | WorldResetRun (confirm, red) | world | `TycoonAdmin.worldResetRun(p, w)` — tycoon + currency |
| Players | WorldWipe (confirm, red) | world | `TycoonAdmin.worldWipe(p, w)` — + rebirths, tokens, shop |
| Players | WorldGrantCash | world, amount | `PlayerDataService.grantCurrency(p, def.currency.key, n, "admin")` |
| Players | WorldSetCash (confirm) | world, amount | built in: `worlds[w].cash = n` (not counted as earned), `markChanged {"worldCash"}` |
| Players | WorldSetRebirths (confirm) | world, rebirths | `TycoonAdmin.worldSetRebirths(p, w, n)` (linkCash recomputes) |
| Players | WorldGrantTokens | world, amount | `PlayerDataService.grantWorldTokens(p, w, n, "admin")` |
| Players | WorldSend | world (+ main), to = spawn / plot | `WorldService.adminSend` — the real warp; cooldown skipped, every other travel rule applies |
| Players | WorldRebuildPlot | world, replay | `TycoonAdmin.worldRebuildPlot(p, w, animate)` |
| Players | WorldOfflinePreview | hours 1..72 | `TycoonAdmin.offlinePreview(p, hours)` → `{ [worldId]: amount }` (read-only) |
| Server | WorldEnabled (confirm) | world, on | `WorldService.setEnabled` — kill switch: ReplicatedStorage `WorldEnabled_<id>`; off refuses travel and sends everyone inside home with a toast (runtimes keep earning) |

The per-world `TycoonAdmin` functions are DISTINCT names on purpose (never an optional trailing
`worldId`): an old main-only seam can then never act on Nuke Town by mistake — each button stays
greyed (`"needs Tycoon world seam (W3 TycoonAdmin)"`) until its function exists. WorldService is
found through `Seams.worldService()` (`Server/Tycoon/WorldService`). Tests: `tests/admin-validate`
§9 (enums = extra worlds, bounds) and `tests/admin-pipeline` §12 (admin-only, enum refusals before
the handler, audit, installs).

## 11. Rush boosts + Friends (owner R78, R-social — `docs/social.md`)

Registered at runtime from `RushService.Start` / `FriendService.Start` (`Lazy.registerAdmin`);
settings are ReplicatedStorage attributes (per server, not saved; clients read the same values).

| Tab | Command | Args | What |
|-----|---------|------|------|
| Server | RushToggle | on / off | `SocialRushEnabled`: OFF = neutral multiplier, Rookie clock paused (audited) |
| Server | RushMinutes | rookie / comeback, 1..120 | `SocialRookieMinutes` / `SocialComebackMinutes` for NEW grants (audited) |
| Players | RushGrant | rookie / comeback, 1..120 | `RushService.grant` — replaces that rush (audited) |
| Players | RushClear | — | `RushService.clear` (audited) |
| Players | RushStatus | — | read-only: multiplier, rookie left (running / paused), comeback left, server settings |
| Server | FriendBoostToggle | on / off | `SocialFriendsEnabled`; recomputes everyone (audited) |
| Server | FriendBoostPercent | 1..25 | `SocialFriendPercent` per friend (total capped at +50 %; audited) |
| Server | FriendStatus | — | read-only: pairs found and every boost |
| Players | ReferralStatus | — | read-only: inviter id, rewards n / 10, ledger size, last queue read |
| Players | ReferralTest (Studio only) | mode, otherId | newcomer of `otherId` / pay as inviter for `otherId` / read the queue (audited) |
