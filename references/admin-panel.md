# Admin panel — owner-only controls

The admin panel lets the owner run the live game without a code change. They can grant and fix
player state, flip kill switches, force events (Happy Hours, worlds, the Harvest Feast), drive
return notifications, read live server health and the full analytics report, and play as a brand
new player. This reference covers how owner-only access is enforced on the server, what every tab
controls, how a system exposes its own controls, and the security rules. Read it whenever you add a
system (owner rule 9: every system is controllable from the admin panel where that makes sense), add
a kill switch or forced event, or build the same panel for a new game. In SellNukes the source of
truth is `docs/admin.md`. The panel itself is a port of RoBeasts' AdminService / AdminPanel, rebuilt
on the SellNukes stud UI kit.

## Contents

1. [The rule and the general pattern](#1-the-rule-and-the-general-pattern)
2. [Who is an admin (server-side)](#2-who-is-an-admin-server-side)
3. [The command pipeline](#3-the-command-pipeline)
4. [Staff, New Player Mode and analytics](#4-staff-new-player-mode-and-analytics)
5. [Opening the panel and every tab](#5-opening-the-panel-and-every-tab)
6. [Kill switches and forced events](#6-kill-switches-and-forced-events)
7. [Exposing admin controls from a system](#7-exposing-admin-controls-from-a-system)
8. [Security checklist](#8-security-checklist)
9. [Porting to another game, and tests](#9-porting-to-another-game-and-tests)

---

## 1. The rule and the general pattern

The owner is not a programmer and plays on phone, tablet, console and desktop. Anything they may
want to change or check while the game is live must be one button in the panel. A missing control
means a code change and a publish.

The pattern carries over to any Roblox game:

- **One remote for intents.** `AdminCommand(name, args)` goes client → server. `AdminResult` goes
  server → caller, and `AdminState` goes server → admins only. The client sends a command *name*
  and *arguments*. It never sends amounts it computed, instance paths or user ids it "verified".
- **The server re-authorises every call.** It never reads the client's `IsAdmin` attribute back.
- **Commands are declared data** (`AdminConfig.Commands` or `registerCommand(def, handler)`). The
  panel renders forms from that catalogue, so a new command needs **no UI code**.
- **Seams are lazy.** AdminService never requires gameplay services at load time. A missing seam
  greys the button with a reason instead of erroring.
- **Every mutating command is audited.** Destructive ones confirm in the panel.

| Module | Job |
|---|---|
| `src/server/Services/AdminService.luau` | Facade: `isAuthorizedAsync`, `isAdmin`, `registerCommand`, `registerHandler`, `submit`, `dispatchAsync`, `getAuditLog`. Boots **last** in `init.server.luau`. |
| `src/server/Admin/AdminAuth.luau` | `decideAdmin` (pure), group rank cache, `isAuthorizedAsync`, `isProtectedAsync`. |
| `src/server/Admin/AdminPipeline.luau` | The ordered dispatch pipeline described in §3. |
| `src/server/Admin/AdminRegistry.luau` | The allowlist (`isKnown`), built-in / provided / registered handlers, availability reasons. |
| `src/server/Admin/AdminValidate.luau` | Strict argument schema (`validateArgs`), definition check (`validateDef`), log sanitising. |
| `src/server/Admin/AdminAudit.luau` | Ring buffer of 200 entries, server output, push to the Log tab. |
| `src/server/Admin/AdminStatePush.luau` | AdminState to admins only: coalesced to at most 4 Hz, plus every 3 s. |
| `src/server/Admin/Seams.luau`, `Handlers/*.luau` | Lazy, pcall'd lookups of gameplay modules. Built-in handlers per tab: Player, Economy, Server, World, MultiWorld, NewPlayer, Attack, Knockdown. |
| `src/shared/Config/AdminConfig.luau` | Tabs, command schemas, rate limits, open keys, wire types. |
| `src/client/UI/Screens/Admin/*` | AdminClient store, AdminPanelScreen, the tabs, CommandForm, AdminOverlayScreen, NewPlayerQuick, NotifySection. |
| `src/client/UI/Hud/HudAdminChip.luau` | The admin wrench chip at the top right of the HUD. |

## 2. Who is an admin (server-side)

`AdminAuth.decideAdmin(userId, env, groupRank?)` is a pure function with a Lune truth table in
`tests/admin-auth.luau`. The rules are applied in order:

| Rule | Admin? |
|---|---|
| Studio, any player | yes. Studio is never a live server, and this makes playtests easy. |
| `userId` ≤ 0 or not a number, live | no |
| listed in `AdminConfig.AdminUserIds` | yes. The owner's own id is listed, so moving the game to a group keeps them in. |
| user-owned experience and `userId == game.CreatorId` | yes |
| group-owned experience and highest group rank ≥ `GroupAdminRank` (254) | yes |

- **Group ranks** come from `GroupService:GetRolesInGroupAsync`, pcall'd and cached for 120 s.
  Concurrent lookups for one user share one web call. A failed refresh is retried after 15 s and
  keeps the old rank only until it is 600 s stale. After that the user is **denied (fail closed)**.
- **Demotion takes effect live.** The periodic push loop re-checks admins whose cache expired. A
  demoted member gets `{ isAdmin = false }`, loses the panel and leaves New Player Mode without
  rejoining.
- **The `IsAdmin` player attribute is a display hint only.** It shows the HUD chip and binds F2. The
  server never reads it for authorisation.
- **Protected users:** Kick and Ban refuse the creator, allowlisted users, group admins and online
  admins. An unknown group rank counts as protected.
- **Owner-only actions** are a stricter check than "admin". They cover anything that reaches outside
  the game for real, such as `NotifyTest` sending a real Roblox notification. On a live server they
  require `AdminConfig.OwnerUserId` or the creator (`ReturnNotifyAdmin.isOwner`). In Studio they
  run as a dry run for any admin.
- **Analytics reads** use the same verdict: `AnalyticsAuth` delegates to `AdminService` when it
  exists. Every analytics request is re-authorised, and every reply is re-checked with `isAdmin`.

`AdminConfig` lives in `src/shared`, so the client can read everything it lists. Put **ids only**
there, never secrets, keys or webhook URLs. Secrets belong in server-only storage or Roblox secrets.

## 3. The command pipeline

`AdminService.submit(caller, rawName, rawArgs)` → `AdminPipeline.dispatchAsync`:

1. **Token bucket** per user: 10 burst, 3 per s (`AdminConfig.RateLimit`). It runs synchronously
   before any thread is spawned, so spam never creates work.
2. **Re-authorisation** with `AdminAuth.isAuthorizedAsync`. An error denies. Non-admin calls are
   dropped silently and audited at most once per 10 s per user (`DeniedLogIntervalSeconds`).
3. **Allowlist:** `AdminRegistry.isKnown` checks string names with `rawget`. No client value reaches
   an undeclared handler.
4. **Availability:** a Studio-only command outside Studio is refused. So is a missing seam, with a
   reason such as `"needs Tycoon (B5 TycoonAdmin)"`.
5. **Per-admin, per-command cooldown** (the def's `cooldown`).
6. **Strict schema** (`AdminValidate.validateArgs`):
   - a plain table with no metatable and at most 8 string keys;
   - unknown, extra or missing keys are rejected;
   - every value is type- and range-checked, and NaN / inf are refused;
   - text must be UTF-8 without control characters, with a byte-length pre-check before any UTF-8
     work.
7. **Target resolution** on the server. User ids are lookup keys only (`Players:GetPlayerByUserId`).
   Target modes are `None`, `Player` (online, guaranteed present) and `AnyUser`.
8. **Handler under `pcall`.** It returns `(ok, message)`, and errors become a failure result.
9. **Audit and result.** The audit entry is
   `{ id, time, adminName, adminUserId, command, args (sanitised, validated), ok, result }`. It is
   printed to server output and pushed to every admin's Log tab. The caller receives
   `AdminResult { seq, ok, name, text }` and a toast.

Malformed calls are audited throttled, so a tampered client cannot flood the log or push real
entries out of the 200-entry ring.

## 4. Staff, New Player Mode and analytics

- **Staff diversion:** an admin on a **live** server is stamped `staff` in their profile. Their
  economy and revenue events count only `core staff:<recorder>`, so owner testing never inflates
  payers, Robux or currency flows. Sessions still count. See `analytics.md` §2.6.
- **New Player Mode** (`NewPlayerMode` / `ExitNewPlayerMode` commands; rules in
  `Shared/Util/NewPlayerMode`, tested in `tests/admin-new-player-mode.luau`):
  - PlayerDataService saves and parks the real profile, then swaps in a **never-saved sandbox**.
  - Robux prompts are refused and receipts are deferred.
  - Analytics diverts every event of the player to `core npm:<recorder>`.
  - Exit swaps the real profile back. Leaving the game or losing admin rights also ends the mode.
- **Where the owner finds it** (R67, because the owner could not find the tab):
  - a big yellow **PLAY AS NEW PLAYER** button in the panel header on every tab, which turns
    green **EXIT NEW PLAYER MODE** while the mode is on;
  - a yellow **NEW PLAYER MODE · EXIT** chip left of the wrench chip. The first tap arms it
    ("TAP AGAIN") and the second exits.

  Both send the existing commands, so there is no new server path. **Lesson:** put the control the
  owner needs where they look, not where it is tidy.

## 5. Opening the panel and every tab

The panel opens four ways:

- **F2** or gamepad **D-pad down** (`AdminConfig.OpenKeys / OpenButtons`). These are bound only
  while `IsAdmin` is set, so players never lose D-pad down.
- The **admin wrench chip** at the top right (`HudAdminChip`, R62). It is visible only to admins and
  grows to a 44 pt tap target on touch devices.
- The menu wheel on a controller.
- In code: `ScreenManager.open("AdminPanel", { tab = "Log" })`.

Non-admins who somehow open the panel see only "ADMINS ONLY", and the server sends them no state.
LB / RB switch tabs, B closes or cancels a confirm, and CANCEL is pre-selected in confirms.

| Tab | What it controls | Examples (command names) |
|---|---|---|
| **Players** | The player list: cash, gems, area, rebirths, ping, save status, ADMIN / NPM badges, current world. Per-player commands are grouped Currency / Tycoon / Rewards / Move / Moderation / More. | GrantCash, TakeCash (never below 0), SetCash, GrantGems, SetArea, UnlockAll, ResetPlot, SetRebirths, GiveBoost, GrantSpins, ResetDaily, AddPlaytime, TeleportTo, Bring, Kick, Ban / Unban (universe-wide), the World* commands, GivePet, GiveEgg, GiveCrate, PetIndex*, PassGrantXp / PassSetTier, Quest*, TitleGrant, WhatsNewReset / Preview, RushGrant, HappyHourSpawn |
| **Economy** | Server-wide economy levers | ServerBoost / ServerBoostOff, TestReceipt (Studio only, `simulateReceiptAsync`), GemUpgradeSettings, FlavorSettings |
| **Server** | Broadcasts, lifecycle, kill switches, forced events | Announce (TextService-filtered banner), SetTimeOfDay, AddCode, FlushAnalytics, Shutdown / CancelShutdown (countdown banner, then kick), HappyHour*, Notify*, Rush*, FriendBoost*, Lucky*, KineticSwitch, Harvest*, LeaderboardRefresh, WorldEnabled, PassClock (Studio) |
| **World** | Plots and the map | RebuildPlot, ReplayBuildIn (re-runs the fly-in), VehiclesToggle |
| **Attack** | Attack-mode test bots and knockdown tools (R51) | AttackBotSpawn / Attack / Shield / Remove, AttackMe*, KnockdownArea, KnockdownRebuild, KnockdownToggle, KnockdownTuning, KnockdownStats |
| **Live** | This server's health right now, from `AnalyticsService.liveHealth()` + `Stats` | Players, FPS, heartbeat, memory, uptime, bandwidth, ping, saving state, analytics forwarder sent / dropped / failed, players per world, per-system ms/s bars. Cards turn green / orange / red. |
| **Log** | The audit log | All / Failed / Mine filters |
| **Analytics** | The full report (`analytics.md` §8) | TODAY / 7 DAYS / 30 DAYS / ALL TIME, REFRESH, headline cards, sections with ranked rows, the Roblox algorithm scorecard (tone rows), **COPY FOR AI**, **COPY RAW DATA** |
| **New Player** | The sandbox | NewPlayerMode, ExitNewPlayerMode |

Rendering rules:

- **Commands render themselves.** `CommandForm` builds schema-driven controls: steppers with
  preset chips, typed amounts such as "1.5M", enum pickers, text and toggles. A greyed button shows
  its unavailability reason.
- **Pages are built lazily,** and only the visible page re-renders on a state push.
- **The overlay** (`AdminOverlayScreen`) is for everyone. It shows the announcement banner and the
  restart countdown, plus the debug perf overlay for admins.

## 6. Kill switches and forced events

Choose the scope deliberately. Write it in the command's description so the owner knows what a
press does.

| Scope | Mechanism | Used by |
|---|---|---|
| **This server, not saved** | A `ReplicatedStorage` attribute. The server checks it in every intent handler, and clients read it for display only. | VehiclesToggle (`VehiclesEnabled`), KineticSwitch (`KineticLeverOn / KineticJarOn`), RushToggle, FriendBoostToggle, LuckyToggle, KnockdownToggle, WorldEnabled (`WorldEnabled_<id>`) |
| **Every server, persisted** | An override record in a DataStore (see below) | HappyHourForce / Stop / Skip / Toggle (`Server/HappyHour/HappyHourOverrideStore`), NotifyToggle / NotifyKind (`Server/Retention/ReturnNotifyControl`) |

How the every-server override record works:

1. A DataStore holds the control. An admin edit runs **inside `UpdateAsync` on the newest stored
   value**, with `version = max(stored.v + 1, now in ms)`, so two admins on two servers never
   overwrite each other.
2. One `MessagingService:PublishAsync` per edit fans the change out at once.
3. Every server loads the record at boot and re-reads it every `PollSeconds`, so a missed message
   heals. A record is adopted only if its version is higher than the one the server runs.
4. Everything read back is size-checked and sanitised: known ids, finite numbers, bounded arrays.
5. Studio uses `<name>_Studio` for both the store and the topic, so a Studio test never switches
   live servers.

The cost is one GetAsync per poll per server and one UpdateAsync + PublishAsync per edit. Nothing
is per player.

Rules for every kill switch:

- **OFF never takes anything away.** Prompts hide, intents are refused (count a `…Refused:off`
  analytics key) and timers pause. Saved cooldowns and currency stay, as do worlds (WorldEnabled
  OFF sends players home with a toast while their runtimes keep earning).
- **Confirm before switching off** (`confirm = true`) and audit the press.
- **Pair every switch with a read-only `…Status` command:** live / next state, override version,
  store health, this server's counters. `audited = false` and `cooldown = 1`.

**Forced events:**

- **Happy Hours:** HappyHourForce takes an event (enum) and minutes (presets 1 / 3 / 5 / 10).
  HappyHourSpawn drops a pickup next to a player.
- **Harvest Feast:** HarvestForce, HarvestTurkeyHub / Plot.
- **Worlds:** WorldUnlock (source `admin`, the popup shows), WorldSend (the real warp: the cooldown
  is skipped and every other travel rule applies), WorldSetArea, WorldResetRun, WorldWipe. The
  last two are red and confirm.

Forced state is also how QA screenshots are set up. Call the same service APIs through
`execute_luau` on the server during a solo playtest.

**Return notifications** (`ReturnNotifyAdmin`, Server tab) are all registered through
`registerHandler` on AdminConfig-declared commands:

- NotifyToggle is the universe kill switch, and NotifyKind turns one kind on or off.
- NotifyStatus shows the mode (LIVE / DRY / NO KEY), queue size, due now, this server's results and
  the last result.
- NotifyTest sends one real notification to the caller: owner only on a live server, a dry run in
  Studio.
- NotifyQueueTest is Studio only.

`NotifySection` shows the live switch line above the forms, read from ReplicatedStorage attributes,
with a REFRESH chip that sends NotifyStatus.

## 7. Exposing admin controls from a system

There are three ways to give a command a handler (`AdminRegistry`):

1. **Built-in:** `setBuiltin(name, handler, probe?)` in `Server/Admin/Handlers/*`, for core
   AdminConfig commands. `probe()` returns a reason while the seam is missing.
2. **Provided:** an AdminConfig command declares `provider = "<system>"`, and that system calls
   `AdminService.registerHandler(name, handler)`. Example: ReturnNotifyAdmin.
3. **Registered:** the system declares a new command at runtime with
   `AdminService.registerCommand(def, handler)`. This is the default for new systems. The def is
   validated (`AdminValidate.validateDef`: name `^[%a][%w_]*$` up to 32 characters, sane ranges, at
   most 400 enum values, **no `userId` arg**), deep-frozen, and a name clash errors. The catalogue
   version bumps, and admins get the command on their next push.

Register through the guarded lazy helper `Lazy.registerAdmin(def, handler)` in `Server/Event/Lazy`.
If AdminService is missing or fails to load, nothing is registered and nothing errors. AdminService
has no gameplay requires, so there is no require cycle.

| Def field | Values |
|---|---|
| `tab` | Players, Economy, Server, World, Attack, NewPlayer |
| `target` | None, Player, AnyUser |
| arg `kind` | integer, number, text, enum, boolean, banDuration, code (any can be `optional`) |
| other fields | `cooldown`, `audited`, `confirm`, `color`, `order`, `description`, `studioOnly`, `presets`, `default`, `format` |

Skeleton for a hypothetical Treasure Chest system: a kill switch, a status line and a per-player
fix. The analytics side is in `analytics.md` §11.

```lua
--!strict
--[[
	ChestAdmin — owner admin commands of the Treasure Chest system (owner rule 9), registered
	through Server/Event/Lazy.registerAdmin. AdminService re-authorises, validates, rate-limits
	and audits every call before a handler runs; handlers only act on validated args.

	Commands
		ChestSwitch   Server tab, None: { mode = on | off } — this server's kill switch (attribute
		              ChestsEnabled). OFF hides chests and refuses opens; nothing is removed.
		ChestStatus   Server tab, None — read-only: switch, chests opened / gems paid since boot.
		ChestReset    Players tab, Player — clears the player's chest cooldown (support / QA).

	Usage: ChestService.Start → ChestAdmin.install(ChestService)
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChestConfig = require(ReplicatedStorage.Shared.Config.ChestConfig)
local Lazy = require(script.Parent.Parent.Event.Lazy)

local ChestAdmin = {}

--[[ Registers the commands once. @param service the ChestService facade (status / resetCooldown). ]]
function ChestAdmin.install(service: any)
	Lazy.registerAdmin({
		name = "ChestSwitch",
		tab = "Server",
		label = "Chests On/Off",
		description = "Kill switch (this server): OFF hides chests and refuses opens. Nothing is removed.",
		target = "None",
		args = { mode = { kind = "enum", values = { "on", "off" }, labels = { "ON", "OFF" }, label = "Mode" } },
		argOrder = { "mode" },
		cooldown = 3,
		audited = true,
		confirm = true,
		color = "orange",
		order = 90,
	}, function(ctx: any): (boolean, string)
		local on = ctx.args.mode == "on"
		ReplicatedStorage:SetAttribute(ChestConfig.EnabledAttribute, on) -- server reads it in every intent
		return true, `Chests {if on then "ON" else "OFF"} on this server`
	end)

	Lazy.registerAdmin({
		name = "ChestStatus",
		tab = "Server",
		label = "Chest Status",
		target = "None",
		args = {},
		cooldown = 1,
		audited = false, -- read-only
		confirm = false,
		order = 91,
	}, function(_ctx: any): (boolean, string)
		return true, service.status()
	end)

	Lazy.registerAdmin({
		name = "ChestReset",
		tab = "Players",
		label = "Reset Chest Cooldown",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = true,
		confirm = false,
		order = 400,
	}, function(ctx: any): (boolean, string)
		local player = if ctx.target ~= nil then ctx.target.player else nil
		if player == nil then
			return false, "Player not in this server"
		end
		return service.resetCooldown(player) -- (ok, message); saves through PlayerDataService
	end)
end

return ChestAdmin
```

In the system's intent handler, the server is authoritative:

```lua
if ReplicatedStorage:GetAttribute(ChestConfig.EnabledAttribute) ~= true then
	ChestAnalytics.record(player, "chest:refused:off")
	return
end
```

Checklist for a new system's admin side:

- [ ] A status command that prints the same numbers analytics records for this server.
- [ ] A kill switch with a deliberately chosen scope (§6).
- [ ] Grant / reset commands for support and QA, with destructive ones marked `confirm` and red.
- [ ] Studio-only test hooks marked `studioOnly`.
- [ ] Every handler returns a human message.
- [ ] Add a row to `docs/admin.md` and a `tests/admin-validate` case if you add enum or bounds
      logic.

## 8. Security checklist

Never trust client admin claims:

- The `IsAdmin` attribute, the AdminState push and the panel's greyed buttons are UX only.
- Every command, analytics report request and analytics reply is re-authorised on the server.
- In-panel confirms are UX, not protection.

Bound the remote:

- The token bucket runs before any work.
- Denied and malformed calls are logged throttled.
- Every command has its own per-admin cooldown.

Validate like an attacker wrote the args:

- Use the strict schema with no extra keys, no metatables, finite numbers only, and clamped
  ranges.
- Text must be clean UTF-8. Validate ids against config enums.
- Targets are resolved on the server, and defs may not declare a `userId` arg.

Audit everything that mutates:

- Write the who / what / sanitised args / result to the ring, the server output and the Log tab.
- Leave read-only status commands unaudited, so they do not drown the log.

Least privilege:

- Make actions that leave the game owner-only (real notifications) and Studio-only where they are
  test tools (TestReceipt, NotifyQueueTest, PassClock).
- Protect admins and the creator from Kick / Ban.
- Fail closed when a group rank cannot be confirmed.

Filter player-visible text:

- Announce and shutdown reasons go through `TextService` broadcast filtering. A live filter
  failure drops the text.
- A ban's display reason is filtered; its private reason stays raw and server-side.

Contain failures:

- Handlers run under `pcall`. Seams are pcall'd and retried every 10 s.
- A broken system greys its own buttons and never breaks the panel.

Stay cheap:

- No AdminState is built while no admin is online.
- Pushes are coalesced to at most 4 Hz, the shared part is built once per push, and the log and
  catalogue are sent only when an admin has not seen that version.
- The push's Luau time reports as analytics health system `"Admin"`.

Never put secrets in the panel or `AdminConfig`. API keys, notification secrets and webhook URLs
stay server-only. NotifyStatus reports "NO KEY", never the key.

## 9. Porting to another game, and tests

To port the panel:

1. Copy `Server/Admin/*`, `AdminService`, `AdminConfig` (tabs, limits, wire types),
   `Client/UI/Screens/Admin/*` and `HudAdminChip`. Restyle with the new game's UI kit.
2. Replace the built-in commands with the new game's core ones: currency, progression, plot or
   base, moderation, Announce / Shutdown, FlushAnalytics, New Player Mode. Every other system
   registers its own through `Lazy.registerAdmin`.
3. Set `AdminUserIds` to the owner's id (ids only) and `GroupAdminRank` if the game is
   group-owned. Keep Studio = admin.
4. Wire `AnalyticsAuth` to `AdminService` so the Analytics tab and analytics staff diversion use the
   same verdict.
5. Ship the Analytics, Live and Log tabs on day one: they are how the owner sees the game.

Tests (Lune, in `./scripts/check.sh`):

| Suite | Covers |
|---|---|
| `tests/admin-auth.luau` | `decideAdmin` truth table |
| `tests/admin-pipeline.luau` | step order, cooldowns, throttles, Studio-only, unavailable seams, handler throws, ring cap, registered commands end to end, world command enums |
| `tests/admin-validate.luau` | fuzz of every built-in command and `validateDef` |
| `tests/admin-new-player-mode.luau`, `tests/admin-new-player-quick.luau` | the sandbox rules and the header button / chip logic |

Verify the panel on phone, tablet and console with `capture_device_matrix`. File the screenshots
under `docs/verification/admin/`.
