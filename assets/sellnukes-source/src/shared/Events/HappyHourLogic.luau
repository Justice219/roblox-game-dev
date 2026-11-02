--!strict
--[[
	HappyHourLogic — the pure schedule + override maths of NUKEY'S HAPPY HOURS (owner R89, spec §2,
	docs/happy-hours.md). No services, no yields, no Instances: the server, every client and the
	Lune tests run exactly this code, so everybody agrees on what is live at unix time `t`.

	The schedule (HappyHourConfig.Schedule):
		slot index  k = floor(t / 1800)              (unix time is UTC with no DST and no leap
		                                              seconds: k * 1800 is always :00 or :30 UTC)
		even k      HEADLINE at :00, 5 min, event = Rotation[(floor(k / 2) + RotationOffset) % 5 + 1]
		odd k       MINI Sprinkle Surge at :30, 3 min (miniLuck)

	The override (admin; Server/HappyHour/HappyHourOverrideStore keeps it in step across servers):
		{ v = version, kill = boolean, force = { id, startsAt, endsAt }?, skips = { slotStart } }
		- kill       nothing is live and nothing is next (the kill switch)
		- force      that event is live during [startsAt, endsAt) and hides any scheduled one
		- skips      scheduled slots (by start time) that do not run (admin STOP / SKIP)
	Pure edit helpers (withForce / withStop / withSkipNext / withKill / prune) return NEW tables;
	sanitize / overrideFromAttributes turn untrusted data back into a valid override.

	Installed override: `HappyHourLogic.setOverride(o)` stores the override this VM uses when a
	query passes none (server: HappyHourService; client: HappyHourClient). That is how
	`flavorLuckAt(now)` (F-flavors' Surprise Batches) already honours the admin override without
	any service coupling.

	API (t = unix seconds; server Workspace:GetServerTimeNow() / os.time(), client
	Workspace:GetServerTimeNow()):
		slotIndex(t) / slot(k) / slotAt(t)      the half-hour slot maths
		headlineOf(hourIndex) -> EventId
		scheduledLiveAt(t) -> Slot?             schedule only (no override)
		liveAt(t, o?) -> Live?                  the effective live event
		nextAt(t, o?) -> Live?                  the next effective event starting after t
		upcoming(t, count, o?) -> { Live }      live (if any) then the next ones
		flavorLuckAt(t, o?) -> number           1 = none; Sprinkle Surge luck while live
		cashMultiplierAt(t, o?) -> number       1 = none; Double Pops' eventCash while live
		signature(live?) -> string              "id@startsAt" ("" = none): transition detection
		emptyOverride / setOverride / currentOverride
		withForce / withStop / withSkipNext / withKill / prune      admin edits (pure)
		sanitize(raw) -> Override?              validated copy of untrusted data
		encode(o) -> table                      JSON-safe plain table (store / MessagingService)
		toAttributes(o) / overrideFromAttributes(get)               ReplicatedStorage transport

	Example:
		local live = HappyHourLogic.liveAt(workspace:GetServerTimeNow())
		if live then print(live.id, live.endsAt) end
		print(HappyHourLogic.flavorLuckAt(os.time())) --> 1 (or 2 during a Sprinkle Surge)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HappyHourConfig = require(ReplicatedStorage.Shared.Config.HappyHourConfig)

type EventId = HappyHourConfig.EventId

-- One scheduled half-hour slot.
export type Slot = {
	index: number, -- floor(startsAt / SlotSeconds)
	startsAt: number,
	endsAt: number,
	id: EventId,
	mini: boolean, -- the :30 mini Sprinkle Surge
}

-- The effective event at a moment (schedule or forced).
export type Live = {
	id: EventId,
	startsAt: number,
	endsAt: number,
	mini: boolean,
	forced: boolean,
	world: string?, -- the world it happens in (nil = every world)
	luck: number, -- flavour luck while it runs (1 = none)
}

export type Force = { id: EventId, startsAt: number, endsAt: number }

export type Override = {
	v: number,
	kill: boolean,
	force: Force?,
	skips: { number },
}

local Schedule = HappyHourConfig.Schedule
local Limits = HappyHourConfig.Override
local SLOT = Schedule.SlotSeconds

local HappyHourLogic = {}

-- ─── Small helpers ────────────────────────────────────────────────────────────────────────────

-- True for a finite number.
local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- The luck of an event (headline or mini), clamped to [1, MaxLuck].
local function luckOf(id: EventId, mini: boolean): number
	local def = HappyHourConfig.get(id)
	if def == nil then
		return 1
	end
	local raw = if mini then def.miniLuck or def.luck else def.luck
	if not finite(raw) then
		return 1
	end
	return math.clamp(raw :: number, 1, HappyHourConfig.MaxLuck)
end

-- A Live record for an event id.
local function makeLive(id: EventId, startsAt: number, endsAt: number, mini: boolean, forced: boolean): Live
	local def = HappyHourConfig.get(id)
	return {
		id = id,
		startsAt = startsAt,
		endsAt = endsAt,
		mini = mini,
		forced = forced,
		world = if def ~= nil then def.world else nil,
		luck = luckOf(id, mini),
	}
end

-- ─── Schedule ─────────────────────────────────────────────────────────────────────────────────

--[[
	The slot index of unix time `t` (floor(t / 1800)).
	Example: HappyHourLogic.slotIndex(3600) --> 2
]]
function HappyHourLogic.slotIndex(t: number): number
	return math.floor(t / SLOT)
end

--[[
	The headline event of a UTC hour index (floor(t / 3600)).
	Example: HappyHourLogic.headlineOf(0) --> "confetti"
]]
function HappyHourLogic.headlineOf(hourIndex: number): EventId
	local rotation = Schedule.Rotation
	local count = #rotation
	local index = (math.floor(hourIndex) + Schedule.RotationOffset) % count
	return rotation[index + 1]
end

--[[
	The scheduled slot with index `k` (even = headline at :00, odd = mini at :30).
	Example: HappyHourLogic.slot(3) --> { startsAt = 5400, endsAt = 5580, id = "sprinkle", mini = true }
]]
function HappyHourLogic.slot(k: number): Slot
	local index = math.floor(k)
	local startsAt = index * SLOT
	if index % 2 == 0 then
		return {
			index = index,
			startsAt = startsAt,
			endsAt = startsAt + Schedule.HeadlineSeconds,
			id = HappyHourLogic.headlineOf(index // 2),
			mini = false,
		}
	end
	return {
		index = index,
		startsAt = startsAt,
		endsAt = startsAt + Schedule.MiniSeconds,
		id = Schedule.MiniEvent,
		mini = true,
	}
end

--[[ The slot whose half hour contains `t` (it may already have ended). ]]
function HappyHourLogic.slotAt(t: number): Slot
	return HappyHourLogic.slot(HappyHourLogic.slotIndex(t))
end

--[[
	The scheduled slot running at `t`, ignoring any override (nil between events).
	Example: HappyHourLogic.scheduledLiveAt(3600 + 10).id --> the headline of UTC hour 1
]]
function HappyHourLogic.scheduledLiveAt(t: number): Slot?
	if not finite(t) then
		return nil
	end
	local slot = HappyHourLogic.slotAt(t)
	if t >= slot.startsAt and t < slot.endsAt then
		return slot
	end
	return nil
end

-- ─── Override ─────────────────────────────────────────────────────────────────────────────────

--[[ A fresh override: nothing forced, nothing skipped, kill switch off. ]]
function HappyHourLogic.emptyOverride(): Override
	return { v = 0, kill = false, force = nil, skips = {} }
end

local installed: Override = HappyHourLogic.emptyOverride()

--[[
	Installs the override this VM uses when a query passes none (sanitized copy; a bad value
	installs the empty override).
	@return the installed override
]]
function HappyHourLogic.setOverride(override: unknown): Override
	installed = HappyHourLogic.sanitize(override) or HappyHourLogic.emptyOverride()
	return installed
end

--[[ The installed override (read-only by convention). ]]
function HappyHourLogic.currentOverride(): Override
	return installed
end

--[[
	True when nothing may run under `override`: the kill switch, or the shipped default OFF
	(HappyHourConfig.DefaultEnabled = false) while no admin override was ever written (v = 0).
]]
local function isOff(override: Override): boolean
	return override.kill or (override.v == 0 and not HappyHourConfig.DefaultEnabled)
end
HappyHourLogic.isOff = isOff

-- True when the slot starting at `startsAt` is skipped.
local function isSkipped(override: Override, startsAt: number): boolean
	return table.find(override.skips, startsAt) ~= nil
end
HappyHourLogic.isSkipped = isSkipped

-- ─── Effective state ──────────────────────────────────────────────────────────────────────────

--[[
	The effective live event at `t`: nil with the kill switch on; the forced event while it runs;
	else the scheduled slot unless it is skipped.
	@param o the override (nil = the installed one)
	@return Live or nil
]]
function HappyHourLogic.liveAt(t: number, o: Override?): Live?
	local override = o or installed
	if not finite(t) or isOff(override) then
		return nil
	end
	local force = override.force
	if force ~= nil and t >= force.startsAt and t < force.endsAt then
		return makeLive(force.id, force.startsAt, force.endsAt, false, true)
	end
	local slot = HappyHourLogic.scheduledLiveAt(t)
	if slot ~= nil and not isSkipped(override, slot.startsAt) then
		return makeLive(slot.id, slot.startsAt, slot.endsAt, slot.mini, false)
	end
	return nil
end

--[[
	The next effective event that STARTS after `t` (the live one is not "next"): the earliest of a
	future forced event and the first non-skipped scheduled slot (bounded scan). nil with the kill
	switch on.
	@param o the override (nil = the installed one)
]]
function HappyHourLogic.nextAt(t: number, o: Override?): Live?
	local override = o or installed
	if not finite(t) or isOff(override) then
		return nil
	end
	local best: Live? = nil
	local force = override.force
	if force ~= nil and force.startsAt > t then
		best = makeLive(force.id, force.startsAt, force.endsAt, false, true)
	end
	local k = HappyHourLogic.slotIndex(t)
	for _ = 1, Schedule.MaxScan do
		local slot = HappyHourLogic.slot(k)
		k += 1
		if slot.startsAt <= t or isSkipped(override, slot.startsAt) then
			continue
		end
		if best ~= nil and best.startsAt <= slot.startsAt then
			break
		end
		-- A scheduled slot that starts while the forced event still runs is hidden by it.
		if force ~= nil and slot.startsAt >= force.startsAt and slot.startsAt < force.endsAt then
			continue
		end
		best = makeLive(slot.id, slot.startsAt, slot.endsAt, slot.mini, false)
		break
	end
	return best
end

--[[
	The live event (if any) followed by the next events, at most `count` rows (schedule panel).
	Example: HappyHourLogic.upcoming(now, 8) --> { Live, Live, ... }
]]
function HappyHourLogic.upcoming(t: number, count: number, o: Override?): { Live }
	local override = o or installed
	local rows: { Live } = {}
	if not finite(t) or count <= 0 then
		return rows
	end
	local live = HappyHourLogic.liveAt(t, override)
	if live ~= nil then
		table.insert(rows, live)
	end
	local cursor = t
	while #rows < count do
		local nextLive = HappyHourLogic.nextAt(cursor, override)
		if nextLive == nil or nextLive.startsAt <= cursor then
			break
		end
		table.insert(rows, nextLive)
		cursor = nextLive.startsAt
	end
	return rows
end

--[[
	Surprise Batch flavour luck at `t` (F-flavors' FlavorLogic multiplies rare-flavour odds by it):
	1 = no luck event; Sprinkle Surge = its luck (miniLuck for the :30 mini). Never NaN, always in
	[1, HappyHourConfig.MaxLuck]. Honours the admin override (installed when `o` is nil).
	Example: HappyHourLogic.flavorLuckAt(os.time()) --> 1 | 1.5 | 2
]]
function HappyHourLogic.flavorLuckAt(t: number, o: Override?): number
	local live = HappyHourLogic.liveAt(t, o)
	return if live ~= nil then live.luck else 1
end

--[[
	The live-event income multiplier at `t` (Double Pops' eventCash): 1 when none.
	Example: HappyHourLogic.cashMultiplierAt(now) --> 1.25 during Double Pops
]]
function HappyHourLogic.cashMultiplierAt(t: number, o: Override?): number
	local live = HappyHourLogic.liveAt(t, o)
	if live == nil then
		return 1
	end
	local def = HappyHourConfig.get(live.id)
	local value = if def ~= nil then def.cashMultiplier else nil
	if not finite(value) or (value :: number) <= 1 then
		return 1
	end
	return math.min(value :: number, 3)
end

--[[
	A stable string for a live event ("" = none): two calls agree exactly when the same event
	instance runs, so a 1 Hz loop can detect starts / ends with one string compare.
	Example: HappyHourLogic.signature(live) --> "confetti@1793487600"
]]
function HappyHourLogic.signature(live: Live?): string
	if live == nil then
		return ""
	end
	return `{live.id}@{math.floor(live.startsAt)}`
end

-- ─── Override edits (pure; each returns a new override with version `v`) ──────────────────────

-- A deep copy (skips cloned, force copied).
local function copy(o: Override): Override
	local force = o.force
	return {
		v = o.v,
		kill = o.kill,
		force = if force ~= nil then { id = force.id, startsAt = force.startsAt, endsAt = force.endsAt } else nil,
		skips = table.clone(o.skips),
	}
end

-- Adds a skipped slot start (no duplicates; oldest dropped past MaxSkips).
local function addSkip(o: Override, startsAt: number)
	if table.find(o.skips, startsAt) == nil then
		table.insert(o.skips, startsAt)
		table.sort(o.skips)
	end
	while #o.skips > Limits.MaxSkips do
		table.remove(o.skips, 1)
	end
end

--[[
	Drops an ended forced event and skips older than SkipKeepSeconds (keeps the override small).
	@return a new override (same version)
]]
function HappyHourLogic.prune(o: Override, now: number): Override
	local out = copy(o)
	local force = out.force
	if force ~= nil and force.endsAt <= now then
		out.force = nil
	end
	local kept: { number } = {}
	for _, startsAt in out.skips do
		if startsAt >= now - Limits.SkipKeepSeconds then
			table.insert(kept, startsAt)
		end
	end
	out.skips = kept
	return out
end

--[[
	Forces event `id` live from `now` for `seconds` (clamped to the Override bounds; nil = the
	event's normal headline length). Replaces any earlier forced event.
	@return the new override, or nil for an unknown id / bad numbers
	Example: HappyHourLogic.withForce(o, "confetti", now, nil, version)
]]
function HappyHourLogic.withForce(o: Override, id: unknown, now: number, seconds: number?, v: number): Override?
	local def = HappyHourConfig.get(id)
	if def == nil or not finite(now) or not finite(v) then
		return nil
	end
	local length = if finite(seconds) then seconds :: number else Schedule.HeadlineSeconds
	length = math.clamp(math.floor(length), Limits.ForceMinSeconds, Limits.ForceMaxSeconds)
	local out = HappyHourLogic.prune(o, now)
	local startsAt = math.floor(now)
	out.force = { id = def.id, startsAt = startsAt, endsAt = startsAt + length }
	out.v = v
	return out
end

--[[
	Stops whatever runs at `now`: clears a live forced event and skips a live scheduled slot.
	@return (new override, the stopped event id or nil when nothing was live)
]]
function HappyHourLogic.withStop(o: Override, now: number, v: number): (Override, EventId?)
	local out = HappyHourLogic.prune(o, now)
	local stopped: EventId? = nil
	local force = out.force
	if force ~= nil and now >= force.startsAt and now < force.endsAt then
		stopped = force.id
		out.force = nil
	end
	local slot = HappyHourLogic.scheduledLiveAt(now)
	if slot ~= nil and not isSkipped(out, slot.startsAt) then
		stopped = stopped or slot.id
		addSkip(out, slot.startsAt)
	end
	out.v = v
	return out, stopped
end

--[[
	Skips the next scheduled slot that would run (the "NEXT" one on the chip).
	@return (new override, the skipped Slot or nil when none was found)
]]
function HappyHourLogic.withSkipNext(o: Override, now: number, v: number): (Override, Slot?)
	local out = HappyHourLogic.prune(o, now)
	local k = HappyHourLogic.slotIndex(now)
	local skipped: Slot? = nil
	for _ = 1, Schedule.MaxScan do
		local slot = HappyHourLogic.slot(k)
		k += 1
		if slot.startsAt > now and not isSkipped(out, slot.startsAt) then
			addSkip(out, slot.startsAt)
			skipped = slot
			break
		end
	end
	out.v = v
	return out, skipped
end

--[[
	Turns the kill switch on / off (off also forgets nothing else: skips and a force stay).
	@return the new override
]]
function HappyHourLogic.withKill(o: Override, on: boolean, now: number, v: number): Override
	local out = HappyHourLogic.prune(o, now)
	out.kill = on == true
	out.v = v
	return out
end

-- ─── Validation + transport ───────────────────────────────────────────────────────────────────

-- A valid skip value: a finite, whole multiple of the slot length.
local function validSkip(value: unknown): boolean
	return finite(value) and (value :: number) >= 0 and (value :: number) % SLOT == 0
end

--[[
	A validated copy of an override from ANY source (DataStore, MessagingService, attributes):
	known event ids only, finite numbers, a forced length within the bounds, at most MaxSkips
	whole-slot skips. Unknown fields are dropped.
	@return Override, or nil when `raw` is not an override at all
]]
function HappyHourLogic.sanitize(raw: unknown): Override?
	if type(raw) ~= "table" then
		return nil
	end
	local data = raw :: { [string]: unknown }
	local v = data.v
	if not finite(v) or (v :: number) < 0 then
		return nil
	end
	local out: Override = { v = math.floor(v :: number), kill = data.kill == true, force = nil, skips = {} }
	local force = data.force
	if type(force) == "table" then
		local f = force :: { [string]: unknown }
		local def = HappyHourConfig.get(f.id)
		local startsAt, endsAt = f.startsAt, f.endsAt
		if def ~= nil and finite(startsAt) and finite(endsAt) then
			local s, e = math.floor(startsAt :: number), math.floor(endsAt :: number)
			if e > s and e - s <= Limits.ForceMaxSeconds then
				out.force = { id = def.id, startsAt = s, endsAt = e }
			end
		end
	end
	local skips = data.skips
	if type(skips) == "table" then
		local count = 0
		for _, value in skips :: { unknown } do
			count += 1
			if count > Limits.MaxSkips * 4 then
				break -- hostile huge arrays: bounded work
			end
			if validSkip(value) and table.find(out.skips, value :: number) == nil then
				table.insert(out.skips, value :: number)
			end
		end
		table.sort(out.skips)
		while #out.skips > Limits.MaxSkips do
			table.remove(out.skips, 1)
		end
	end
	return out
end

--[[ A JSON-safe plain table of an override (DataStore value / MessagingService payload). ]]
function HappyHourLogic.encode(o: Override): { [string]: any }
	local force = o.force
	return {
		v = o.v,
		kill = o.kill,
		force = if force ~= nil then { id = force.id, startsAt = force.startsAt, endsAt = force.endsAt } else nil,
		skips = table.clone(o.skips),
	}
end

--[[
	The ReplicatedStorage attribute values of an override (HappyHourConfig.Attributes names).
	Example: for name, value in HappyHourLogic.toAttributes(o) do ReplicatedStorage:SetAttribute(name, value) end
]]
function HappyHourLogic.toAttributes(o: Override): { [string]: any }
	local names = HappyHourConfig.Attributes
	local force = o.force
	local parts: { string } = {}
	for _, startsAt in o.skips do
		table.insert(parts, string.format("%d", startsAt))
	end
	return {
		[names.Version] = o.v,
		[names.Kill] = o.kill,
		[names.ForceId] = if force ~= nil then force.id else "",
		[names.ForceStart] = if force ~= nil then force.startsAt else 0,
		[names.ForceEnd] = if force ~= nil then force.endsAt else 0,
		[names.Skips] = table.concat(parts, ","),
	}
end

--[[
	Rebuilds (and validates) an override from attribute values; `get(name)` returns the
	attribute (ReplicatedStorage:GetAttribute). Missing / junk values read as "no override".
	Example: local o = HappyHourLogic.overrideFromAttributes(function(n) return ReplicatedStorage:GetAttribute(n) end)
]]
function HappyHourLogic.overrideFromAttributes(get: (name: string) -> unknown): Override
	local names = HappyHourConfig.Attributes
	local skips: { number } = {}
	local raw = get(names.Skips)
	if type(raw) == "string" and #raw <= Limits.MaxSkips * 16 then
		for _, part in string.split(raw, ",") do
			local value = tonumber(part)
			if value ~= nil then
				table.insert(skips, value)
			end
		end
	end
	local forceId = get(names.ForceId)
	local version = get(names.Version)
	return HappyHourLogic.sanitize({
		v = if finite(version) then version else 0,
		kill = get(names.Kill) == true,
		force = if type(forceId) == "string" and forceId ~= ""
			then { id = forceId, startsAt = get(names.ForceStart), endsAt = get(names.ForceEnd) }
			else nil,
		skips = skips,
	}) or HappyHourLogic.emptyOverride()
end

return table.freeze(HappyHourLogic)
