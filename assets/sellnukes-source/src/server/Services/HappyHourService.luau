--!strict
--[[
	HappyHourService — NUKEY'S HAPPY HOURS on the server (owner R89 §2, docs/happy-hours.md).

	Purpose:
		- The schedule is pure UTC maths (Shared/Events/HappyHourLogic): nothing to store, every
		  server agrees. This service runs the EFFECTIVE state = schedule + the admin override.
		- Override (force / stop / skip / kill switch) lives in Server/HappyHour/
		  HappyHourOverrideStore (DataStore + MessagingService → every server); the version this
		  server runs is installed into HappyHourLogic (so FlavorLogic's `flavorLuckAt(now)` and
		  every other reader honour it) and published as ReplicatedStorage attributes
		  (HappyHourConfig.Attributes) so every client computes the same live / next events.
		- ONE 1 Hz loop: detects event starts / ends (HappyHourLogic.signature), counts analytics,
		  refreshes income modifiers when Double Pops starts / ends, publishes the live event id
		  attribute, and ticks the pickups (Server/HappyHour/HappyHourPickups: Confetti Storm
		  coins, Egg Stampede eggs, Low-Gravity moon rocks).
		- Double Pops: the "happyHour" income modifier ({ eventCash = cashMultiplier }, until the
		  event ends; offline = false) through Retention/ModifierHook → Tycoon/ModifierSources.
		- Sprinkle Surge: nothing to run here — Tycoon/FlavorLogic reads HappyHourLogic.flavorLuckAt.
		- Low-Gravity Hour: client gravity (Client/Worlds/WorldGravity.setEvent) + moon-rock pickups.

	Remotes: HappyHourCollect (C→S pickup id), HappyHour (S→C pickup wire; HappyHourPickups).
	Analytics (event family, Server/Analytics/KeySpec allowlist): hh:start:<id> (server-level, once
	per event instance), hh:seen:<id> (players present at the start or arriving during it, once per
	player per instance), hh:spawn / hh:pickup / hh:golden :<id>, hh:gems, hh:admin:<action>.
	Admin (Server tab, Lazy.registerAdmin, audited): HappyHourForce, HappyHourStop, HappyHourSkip,
	HappyHourToggle (kill switch), HappyHourStatus; Players tab HappyHourSpawn (QA pickup).

	Public API:
		HappyHourService.live() -> Live?           effective live event now
		HappyHourService.nextEvent() -> Live?      next effective event
		HappyHourService.force(id, seconds?) / stop() / skip() / setEnabled(on)   (yield: store)
		HappyHourService.status() -> string        admin status line
		HappyHourService.Changed: Signal<Live?>    fired on every effective start / end

	Example:
		local live = HappyHourService.live()
		if live and live.id == "doublePops" then ... end
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local HappyHourConfig = require(ReplicatedStorage.Shared.Config.HappyHourConfig)
local HappyHourLogic = require(ReplicatedStorage.Shared.Events.HappyHourLogic)
local HappyHourOverrideStore = require(ServerScriptService.Server.HappyHour.HappyHourOverrideStore)
local HappyHourPickups = require(ServerScriptService.Server.HappyHour.HappyHourPickups)
local Lazy = require(ServerScriptService.Server.Event.Lazy)
local ModifierHook = require(ServerScriptService.Server.Retention.ModifierHook)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

type Live = HappyHourLogic.Live
type Override = HappyHourLogic.Override

local HappyHourService = {}

HappyHourService.Changed = Signal.new() :: Signal.Signal<Live?>

local started = false
local activeSignature = ""
local activeLive: Live? = nil
-- Players already counted as "seen" for the running event instance.
local seen: { [Player]: boolean } = {}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- Counts an event-family analytics key (never errors / yields).
local function track(player: Player?, key: string, amount: number?)
	Lazy.analytics("event", player, key, amount)
end

-- Publishes the override (and the live id) as ReplicatedStorage attributes.
local function publishOverride(override: Override)
	for name, value in HappyHourLogic.toAttributes(override) do
		ReplicatedStorage:SetAttribute(name, value)
	end
end

-- Publishes the effective live event id ("" = none).
local function publishLive(live: Live?)
	ReplicatedStorage:SetAttribute(HappyHourConfig.Attributes.Live, if live ~= nil then live.id else "")
end

-- Counts "seen" once per player per event instance.
local function markSeen(player: Player, live: Live)
	if seen[player] then
		return
	end
	seen[player] = true
	track(player, `hh:seen:{live.id}`)
end

--[[
	Re-evaluates the effective live event; on a change: analytics, modifier refresh (Double Pops
	starts / ends), the Live attribute, Changed. Never yields.
]]
local function refresh(now: number)
	local live = HappyHourLogic.liveAt(now)
	local signature = HappyHourLogic.signature(live)
	if signature == activeSignature then
		return
	end
	local previous = activeLive
	activeSignature = signature
	activeLive = live
	table.clear(seen)
	publishLive(live)
	if live ~= nil then
		track(nil, `hh:start:{live.id}`)
		for _, player in Players:GetPlayers() do
			markSeen(player, live)
		end
	end
	-- Income modifiers cache their answer until `validUntil`; any change of a cash event (or a
	-- forced / stopped one) refreshes every player's modifiers now.
	local before = if previous ~= nil then HappyHourConfig.get(previous.id) else nil
	local after = if live ~= nil then HappyHourConfig.get(live.id) else nil
	if (before ~= nil and before.cashMultiplier ~= nil) or (after ~= nil and after.cashMultiplier ~= nil) then
		ModifierHook.invalidateAll()
	end
	HappyHourService.Changed:Fire(live)
end

-- A newer override arrived (boot / poll / message / admin): install, publish, react.
local function onOverride(override: Override, _source: string)
	HappyHourLogic.setOverride(override)
	publishOverride(HappyHourLogic.currentOverride())
	local now = serverNow()
	refresh(now)
	if HappyHourLogic.liveAt(now) == nil then
		HappyHourPickups.clearAll()
	end
end

-- The 1 Hz loop body.
local function step()
	local now = serverNow()
	refresh(now)
	HappyHourPickups.tick(now, activeLive)
end

-- ── Public API ───────────────────────────────────────────────────────────────────────────────

--[[ The effective live event right now (nil between events / kill switch on). ]]
function HappyHourService.live(): Live?
	return HappyHourLogic.liveAt(serverNow())
end

--[[ The next effective event (nil with the kill switch on). ]]
function HappyHourService.nextEvent(): Live?
	return HappyHourLogic.nextAt(serverNow())
end

--[[
	Forces an event live now on EVERY server for `seconds` (nil = its normal headline length).
	Yields (DataStore + MessagingService).
	@return (ok, message)
	Example: HappyHourService.force("confetti", 300)
]]
function HappyHourService.force(id: string, seconds: number?): (boolean, string)
	local def = HappyHourConfig.get(id)
	if def == nil then
		return false, "unknown event"
	end
	local now = os.time()
	local _, persisted = HappyHourOverrideStore.apply(function(base: Override, version: number): Override?
		return HappyHourLogic.withForce(base, id, now, seconds, version)
	end, now)
	local live = HappyHourService.live()
	track(nil, "hh:admin:force")
	return live ~= nil and live.id == def.id,
		`{def.name} forced{if persisted then " on every server" else " (this server only: store unavailable)"}`
end

--[[ Stops the live event on every server. Yields. @return (ok, message) ]]
function HappyHourService.stop(): (boolean, string)
	local now = os.time()
	local stopped: string? = nil
	local _, persisted = HappyHourOverrideStore.apply(function(base: Override, version: number): Override?
		local edited, id = HappyHourLogic.withStop(base, now, version)
		stopped = id
		return if id ~= nil then edited else nil
	end, now)
	if stopped == nil then
		return false, "nothing is live"
	end
	HappyHourPickups.clearAll()
	track(nil, "hh:admin:stop")
	return true, `Stopped {stopped}{if persisted then " on every server" else " (this server only)"}`
end

--[[ Skips the next scheduled event on every server. Yields. @return (ok, message) ]]
function HappyHourService.skip(): (boolean, string)
	local now = os.time()
	local skipped: HappyHourLogic.Slot? = nil
	local _, persisted = HappyHourOverrideStore.apply(function(base: Override, version: number): Override?
		local edited, slot = HappyHourLogic.withSkipNext(base, now, version)
		skipped = slot
		return if slot ~= nil then edited else nil
	end, now)
	local slot = skipped
	if slot == nil then
		return false, "no upcoming event found"
	end
	track(nil, "hh:admin:skip")
	return true,
		`Skipped {slot.id} at {os.date("!%H:%M", slot.startsAt)} UTC{if persisted
			then " on every server"
			else " (this server only)"}`
end

--[[ The kill switch: false = no Happy Hours anywhere (on every server). Yields. ]]
function HappyHourService.setEnabled(on: boolean): (boolean, string)
	local now = os.time()
	local _, persisted = HappyHourOverrideStore.apply(function(base: Override, version: number): Override?
		return HappyHourLogic.withKill(base, not on, now, version)
	end, now)
	if not on then
		HappyHourPickups.clearAll()
	end
	track(nil, if on then "hh:admin:on" else "hh:admin:off")
	return true,
		`Happy Hours {if on then "ON" else "OFF"}{if persisted then " on every server" else " (this server only)"}`
end

--[[ One-line admin status: live / next, override, store health, pickup counters. ]]
function HappyHourService.status(): string
	local now = serverNow()
	local live = HappyHourLogic.liveAt(now)
	local nextLive = HappyHourLogic.nextAt(now)
	local override = HappyHourLogic.currentOverride()
	local store = HappyHourOverrideStore.status()
	local pickups = HappyHourPickups.status()
	local liveText = if live ~= nil
		then `LIVE {live.id}{if live.forced then " (forced)" else ""} {math.max(0, math.floor(live.endsAt - now))}s left`
		else "nothing live"
	local nextText = if nextLive ~= nil
		then `next {nextLive.id} at {os.date("!%H:%M", math.floor(nextLive.startsAt))} UTC`
		else "no next (kill switch?)"
	return `{if override.kill then "OFF" else "ON"} · {liveText} · {nextText} · skips {#override.skips} · v{override.v} · store {store.store} (w{store.writes}/e{store.writeErrors}) · msg {if store.subscribed
		then "sub"
		else "no"} (p{store.published}/r{store.received}) · pickups live {pickups.live} spawned {pickups.spawned} caught {pickups.collected} golden {pickups.golden} refused {pickups.refused}`
end

-- ── Admin ────────────────────────────────────────────────────────────────────────────────────

-- Event enum labels in rotation order (admin panel).
local function eventLabels(): { string }
	local labels: { string } = {}
	for _, id in HappyHourConfig.EventIds do
		table.insert(labels, HappyHourConfig.Events[id].name)
	end
	return labels
end

local function registerAdmin()
	Lazy.registerAdmin({
		name = "HappyHourForce",
		tab = "Server",
		label = "Force Happy Hour",
		description = "Starts the chosen Happy Hour NOW on every server (DataStore + MessagingService) for the chosen minutes.",
		target = "None",
		args = {
			event = {
				kind = "enum",
				values = HappyHourConfig.EventIds,
				labels = eventLabels(),
				label = "Event",
			},
			minutes = {
				kind = "number",
				min = HappyHourConfig.Override.ForceMinSeconds / 60,
				max = HappyHourConfig.Override.ForceMaxSeconds / 60,
				presets = { 1, 3, 5, 10 },
				label = "Minutes",
				default = 5,
			},
		},
		argOrder = { "event", "minutes" },
		cooldown = 3,
		audited = true,
		confirm = false,
		color = "purple",
		order = 80,
	}, function(ctx: any): (boolean, string)
		return HappyHourService.force(ctx.args.event, ctx.args.minutes * 60)
	end)
	Lazy.registerAdmin({
		name = "HappyHourStop",
		tab = "Server",
		label = "Stop Happy Hour",
		description = "Stops the live Happy Hour on every server (the schedule carries on with the next one).",
		target = "None",
		args = {},
		cooldown = 3,
		audited = true,
		confirm = false,
		color = "purple",
		order = 81,
	}, function(_ctx: any): (boolean, string)
		return HappyHourService.stop()
	end)
	Lazy.registerAdmin({
		name = "HappyHourSkip",
		tab = "Server",
		label = "Skip Next Happy Hour",
		description = "Skips the next scheduled Happy Hour on every server.",
		target = "None",
		args = {},
		cooldown = 3,
		audited = true,
		confirm = false,
		color = "purple",
		order = 82,
	}, function(_ctx: any): (boolean, string)
		return HappyHourService.skip()
	end)
	Lazy.registerAdmin({
		name = "HappyHourToggle",
		tab = "Server",
		label = "Happy Hours On/Off",
		description = "Kill switch: OFF stops every Happy Hour (live and scheduled) on every server until turned back ON.",
		target = "None",
		args = { mode = { kind = "enum", values = { "on", "off" }, labels = { "ON", "OFF" }, label = "Mode" } },
		argOrder = { "mode" },
		cooldown = 3,
		audited = true,
		confirm = true,
		color = "purple",
		order = 83,
	}, function(ctx: any): (boolean, string)
		return HappyHourService.setEnabled(ctx.args.mode == "on")
	end)
	Lazy.registerAdmin({
		name = "HappyHourStatus",
		tab = "Server",
		label = "Happy Hours Status",
		description = "Live / next event, kill switch, override version, cross-server store health and pickup counters.",
		target = "None",
		args = {},
		cooldown = 1,
		audited = false,
		confirm = false,
		color = "purple",
		order = 84,
	}, function(_ctx: any): (boolean, string)
		return true, HappyHourService.status()
	end)
	Lazy.registerAdmin({
		name = "HappyHourSpawn",
		tab = "Players",
		label = "Spawn Happy Hour Pickup",
		description = "Drops one pickup of the live Happy Hour next to the player now (coins / eggs / moon rocks; caps apply).",
		target = "Player",
		args = {
			golden = { kind = "enum", values = { "normal", "golden" }, labels = { "NORMAL", "GOLDEN" }, label = "Kind" },
		},
		argOrder = { "golden" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "purple",
		order = 85,
	}, function(ctx: any): (boolean, string)
		local target = ctx.target
		local player = if target ~= nil then target.player else nil
		if player == nil then
			return false, "Player not in this server"
		end
		local ok, result = HappyHourPickups.spawnFor(player, HappyHourService.live(), ctx.args.golden == "golden")
		return ok, if ok then `Spawned {result} for {player.Name}` else `Not spawned: {result}`
	end)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────────────────────

function HappyHourService.Init()
	Remotes.onServerEvent("HappyHourCollect", HappyHourPickups.onCollect)
	Players.PlayerRemoving:Connect(function(player: Player)
		seen[player] = nil
		HappyHourPickups.forget(player)
	end)
	-- Late joiners during a live event count as "seen" for it.
	Players.PlayerAdded:Connect(function(player: Player)
		local live = activeLive
		if live ~= nil then
			markSeen(player, live)
		end
	end)
end

function HappyHourService.Start()
	if started then
		return
	end
	started = true
	publishOverride(HappyHourLogic.currentOverride())
	refresh(serverNow())
	-- Double Pops income: { eventCash } while live; otherwise valid until the next event starts.
	ModifierHook.register("happyHour", function(_player: Player, _profile: any): ({ [string]: number }?, number?)
		local now = serverNow()
		local multiplier = HappyHourLogic.cashMultiplierAt(now)
		if multiplier > 1 then
			local live = HappyHourLogic.liveAt(now)
			return { eventCash = multiplier }, if live ~= nil then live.endsAt else now + 60
		end
		local nextLive = HappyHourLogic.nextAt(now)
		return nil, if nextLive ~= nil then nextLive.startsAt else now + 300
	end)
	HappyHourOverrideStore.start(onOverride)
	registerAdmin()
	task.spawn(function()
		while true do
			local ok, err = pcall(step)
			if not ok then
				warn(`[HappyHour] tick failed: {err}`)
			end
			task.wait(1)
		end
	end)
end

return HappyHourService
