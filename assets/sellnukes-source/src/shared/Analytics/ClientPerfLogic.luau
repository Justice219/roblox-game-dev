--!strict
--[[
	ClientPerfLogic — pure math for client performance telemetry (perf audit 2026-10-15 row 1).

	Purpose:
		One module for both ends of the ClientPerf remote, so the wire layout can never drift:
			CLIENT  newWindow / addFrame / addSample / addTagSample / setBoot / addMapReady /
			        encode / reset, reportClass, tagGroupIndex (ClientPerfReporter: one
			        per-frame accumulator, zero allocation per frame)
			SERVER  decode (validation + clamping of an untrusted buffer), counters (bucketed
			        "health" family analytics counters), rows / memoryRows / bootRows (the report
			        tables per device class)
		No Roblox services, no requires beyond the config: `lune run tests/client-perf.luau`
		exercises every function, including hostile payloads.

	Wire v4 (one fixed-size buffer of SLOT_COUNT = 47 little-endian float32 slots, 188 bytes):
		 1 version (ClientPerfConfig.Version)    13-14 (frame histogram, continued)
		 2 device class index (1-5)              15 Stats samples taken in the window
		 3 window seconds                        16 memory average (MB)   17 memory max (MB)
		 4 rendered frames                       18 receive average (Stats.DataReceiveKbps)
		 5-14 frame-time histogram (10 buckets)  19 ping average (ms)     20 ping max (ms)
		 21 boot seconds (-1 = none in this report: boot is reported once per session)
		 22 maps measured   23 their seconds summed   24 the slowest one (s)
		 -- added in v2 (perf investigation 2026-10-20) --
		 25 Stats samples whose DataReceiveKbps read 0 (the "recv n/a" rule)
		 26 Stats.MemoryTrackingEnabled at the memory-tag reads (1 / 0)
		 27 memory-tag reads in the window (every MemoryTags.IntervalSeconds, on a Stats sample)
		 28 total memory average at those reads (MB)
		 29-37 memory-tag group averages (MB), MemoryTags.Groups order: Texture, Mesh, Render, Gui,
		       Lua, Instances, Physics, Sound, Other
		 38 Stats.InstanceCount average at those reads
		 39 session minutes (client clock since ClientPerfReporter started)
		 -- [WS-B begin] added in v3 (money push 2026-10-21, client memory) --
		 40 client FX instances at report time: descendants of Workspace.ClientFX + Workspace.
		    Terrain (where client effects and their attachments live); a steady climb with
		    session age is an un-pooled / never-destroyed client effect
		 -- [WS-B end] --
		 -- added in v4 (owner R122, fast first minute) --
		 41-46 boot-step completion seconds since the loader start, ClientPerfConfig.BootSteps
		       order: Loaded, Client, Profile, World, Plot, Assets (-1 = not finished by the
		       hand-off, or no boot in this report)
		 47 hand-off reason index into ClientPerfConfig.BootEndReasons (ready, budget, tap, auto;
		    0 = none). The block rides the report carrying the boot time (slot 21), once per
		    session; the server drops a block that is malformed, contradicts the boot time, or
		    repeats a boot already counted this session (cp:<Class>:bootDrop).
		A buffer, not a table: fixed length, no nesting, nothing to walk, so the server's whole
		validation is one length check plus 47 finite / range checks.

	Analytics counters (family "health", key prefix ClientPerfConfig.KeyPrefix):
		cp:<Class>:reports / seconds / frames      sums (avg fps = frames / seconds)
		cp:<Class>:ft:<bucket>                     frames per frame-time bucket (p50 / p95, <30 fps)
		cp:<Class>:sampled                         reports that carried Stats samples
		cp:<Class>:memMb, pingMs, recvKbps         sums of the per-report averages (÷ sampled)
		cp:<Class>:mem:<b> / ping:<b> / recv:<b>   reports per bucket of their average
		cp:<Class>:boots / bootS / boot:<b>        sessions with a boot time, their sum, buckets
		cp:<Class>:maps / mapS / map:<b>           maps measured, their seconds, per-map buckets
		-- v2 --
		cp:<Class>:recvN / recvZero                Stats samples / those whose receive read 0
		cp:<Class>:age:<b> / ageMb:<b>             reports per session-age bucket, their memory sum
		cp:<Class>:instN / inst                    reports with tag reads, Stats.InstanceCount sum
		cp:<Class>:mgN / mgTotMb / mg:<Group>      reports with a valid tag block, their total
		                                           memory sum and per-group MB sums (÷ mgN)
		cp:<Class>:mgOff / mgDrop                  tag blocks absent (tracking off) / dropped
		                                           (failed the sum check or a malformed flag)
		-- [WS-B] v3 --
		cp:<Class>:fxN / fx                        reports with a client FX count, their sum
		-- v4 (owner R122) --
		cp:<Class>:bootStep:<step>:<b>             sessions whose loading step finished in
		                                           BootSeconds bucket <b> (count per step = the
		                                           sum over its buckets; p50 per step)
		cp:<Class>:bootStepS:<step>                those completion seconds summed (÷ count = avg)
		cp:<Class>:bootEnd:<ready|budget|tap|auto> sessions per hand-off reason
		cp:<Class>:bootDrop                        boot-step blocks refused (malformed / duplicate)
		Bounded: 5 classes × ~130 keys (v4: 6 steps × 7 buckets + 6 sums + 4 reasons + 1). Buckets
		merge across servers and days by addition.

	Bucket helpers use the same rules (and labels) as Server/Analytics/ServerHealthLogic
	(bucketIndex / bucketLabel / percentileIndex), re-implemented here because ServerHealthLogic
	is server-only and the client needs bucketIndex every frame.

	Example:
		-- client, every frame:
		ClientPerfLogic.addFrame(window, dt)
		-- client, once a minute:
		remote:FireServer(ClientPerfLogic.encode(window, classIndex, os.clock() - window.startedAt))
		-- server:
		local report = ClientPerfLogic.decode(raw, secondsSinceLastReport)
		if report ~= nil then
			for key, amount in ClientPerfLogic.counters(report) do record("health", key, amount) end
		end
]]

local ClientPerfConfig = require(script.Parent.ClientPerfConfig)

-- The client's accumulator for one report window (reused across windows: reset, never rebuilt).
export type Window = {
	startedAt: number, -- os.clock() when the window began
	frames: number,
	frameBuckets: { number }, -- #Buckets.FrameMs + 1 counts
	samples: number,
	memorySum: number,
	memoryMax: number,
	receiveSum: number,
	pingSum: number,
	pingMax: number,
	bootSeconds: number, -- -1 = nothing to report
	bootSteps: { number }, -- wire v4: per ClientPerfConfig.BootSteps, seconds or -1 (reused table)
	bootEnd: number, -- wire v4: ClientPerfConfig.BootEndReasons index, 0 = none
	mapCount: number,
	mapSum: number,
	mapMax: number,
	-- Wire v2 (perf investigation 2026-10-20).
	receiveZero: number, -- Stats samples whose receive rate read 0
	tracking: number, -- 1 = Stats.MemoryTrackingEnabled at every tag read so far, else 0
	tagSamples: number, -- memory-tag reads in this window
	tagTotalSum: number, -- total memory (MB) at those reads, summed
	groupSums: { number }, -- per MemoryTags.Groups entry, MB summed over the reads (reused table)
	instanceSum: number, -- Stats.InstanceCount at those reads, summed
}

-- One validated, clamped report (server side).
export type Report = {
	class: string,
	seconds: number,
	frames: number,
	frameBuckets: { number },
	samples: number,
	memoryMb: number,
	memoryMaxMb: number,
	receiveKbps: number,
	pingMs: number,
	pingMaxMs: number,
	bootSeconds: number?,
	-- Wire v4 (owner R122): the boot-step block, only with a boot time and only when valid.
	bootSteps: { number }?, -- per ClientPerfConfig.BootSteps: seconds (<= bootSeconds) or -1
	bootEnd: string?, -- a ClientPerfConfig.BootEndReasons entry
	bootDropped: boolean, -- a boot-step block was refused (malformed, or a repeat boot)
	mapCount: number,
	mapSeconds: number,
	mapMaxSeconds: number,
	-- Wire v2 (perf investigation 2026-10-20).
	receiveZeroSamples: number, -- 0..samples
	sessionMinutes: number, -- capped by the server's own minutes since join
	tagSamples: number, -- 0 = no tag block in this report
	tagTotalMb: number, -- total memory at the tag reads (<= memoryMaxMb)
	instances: number, -- Stats.InstanceCount average (0 without tag reads)
	memoryGroups: { number }?, -- MemoryTags.Groups averages (MB); nil = absent or dropped
	trackingOff: boolean, -- tag reads happened but Stats.MemoryTrackingEnabled was false
	groupsDropped: boolean, -- a tag block failed validation (sum check / malformed flag)
	-- [WS-B begin] wire v3
	clientFx: number, -- client FX instances at report time (0..ClientPerfConfig.MaxClientFx)
	-- [WS-B end]
}

-- One analytics report row (the AnalyticsReport.Row fields AnalyticsLogic copies, share aside).
export type Row = { id: string, label: string, value: number, display: string, extra: string }

local ClientPerfLogic = {}

local Buckets = ClientPerfConfig.Buckets
local Limits = ClientPerfConfig.Limits
local FRAME_BUCKETS = #Buckets.FrameMs + 1
local MemoryTags = ClientPerfConfig.MemoryTags
local GROUP_COUNT = #MemoryTags.Groups
-- Group index of every MemoryTags.Groups name (tag → group resolution, see tagGroupIndex).
local GROUP_INDEX: { [string]: number } = {}
for index, group in MemoryTags.Groups do
	GROUP_INDEX[group] = index
end
local UNKNOWN_GROUP = GROUP_INDEX[MemoryTags.UnknownGroup] or GROUP_COUNT
local BOOT_STEPS = ClientPerfConfig.BootSteps
local BOOT_STEP_COUNT = #BOOT_STEPS
local BOOT_END_REASONS = ClientPerfConfig.BootEndReasons
-- Frames in buckets above this index are slower than ClientPerfConfig.SlowFrameMs (< 30 fps).
local SLOW_FRAME_BUCKET = table.find(Buckets.FrameMs, ClientPerfConfig.SlowFrameMs) or #Buckets.FrameMs

-- Wire slot numbers (1-based, see the header).
local SLOT = table.freeze({
	version = 1,
	class = 2,
	seconds = 3,
	frames = 4,
	histogram = 5, -- 5 .. 4 + FRAME_BUCKETS
	samples = 5 + FRAME_BUCKETS,
	memoryAvg = 6 + FRAME_BUCKETS,
	memoryMax = 7 + FRAME_BUCKETS,
	receiveAvg = 8 + FRAME_BUCKETS,
	pingAvg = 9 + FRAME_BUCKETS,
	pingMax = 10 + FRAME_BUCKETS,
	boot = 11 + FRAME_BUCKETS,
	mapCount = 12 + FRAME_BUCKETS,
	mapSum = 13 + FRAME_BUCKETS,
	mapMax = 14 + FRAME_BUCKETS,
	-- Wire v2 (perf investigation 2026-10-20).
	receiveZero = 15 + FRAME_BUCKETS,
	tracking = 16 + FRAME_BUCKETS,
	tagSamples = 17 + FRAME_BUCKETS,
	tagTotal = 18 + FRAME_BUCKETS,
	groups = 19 + FRAME_BUCKETS, -- .. 18 + FRAME_BUCKETS + GROUP_COUNT
	instances = 19 + FRAME_BUCKETS + GROUP_COUNT,
	sessionMinutes = 20 + FRAME_BUCKETS + GROUP_COUNT,
	-- [WS-B begin] wire v3 (money push 2026-10-21): the client FX count
	clientFx = 21 + FRAME_BUCKETS + GROUP_COUNT,
	-- [WS-B end]
	-- Wire v4 (owner R122): the boot-step block is the last BOOT_STEP_COUNT + 1 slots.
	bootSteps = 22 + FRAME_BUCKETS + GROUP_COUNT, -- .. 21 + FRAME_BUCKETS + GROUP_COUNT + BOOT_STEP_COUNT
	bootEnd = 22 + FRAME_BUCKETS + GROUP_COUNT + BOOT_STEP_COUNT,
})
local SLOT_COUNT = SLOT.bootEnd
ClientPerfLogic.SlotCount = SLOT_COUNT
ClientPerfLogic.WireBytes = SLOT_COUNT * 4

-- Report note shown under the "Client performance by device" table (AnalyticsReport keeps at
-- most 400 characters; tests/client-perf asserts the length).
ClientPerfLogic.ReportNote = "Client-measured frame time, memory, ping, receive rate, boot and map-load "
	.. "times per device class (~1 report a minute per player; clamped claims). fps = frames ÷ seconds; "
	.. "percentiles are bucket ranges. mem = OS process memory (engine baseline incl.; GPU memory too "
	.. "on consoles / Apple). recv n/a = ≥ 90 % of samples read 0 (unset on clients). "
	.. "TouchLaptop = touch screen + keyboard."

-- Note under the "Client memory by device" table (wire v2, ClientPerfLogic.memoryRows).
ClientPerfLogic.MemoryNote = "Total = OS process memory at the tag reads (Stats:GetTotalMemoryUsageMb: "
	.. "engine baseline incl.; GPU memory too on consoles / Apple). Groups = Stats:GetMemoryUsageMbForTag "
	.. "sums every 30 s while Stats.MemoryTrackingEnabled (MB, averages); untracked = total − tags. "
	.. "Session-age buckets: memory rising with age = a leak."

-- Note under the "Client boot steps by device" table (ClientPerfLogic.bootRows).
ClientPerfLogic.BootNote = "Loading screen (R122): avg completion second of each step since the loader "
	.. "started, p50 = BootSeconds bucket. end = why it handed off: ready (all loaded), budget (critical "
	.. "preload cut at the asset budget, rest loads in the background), tap (TAP TO CONTINUE), auto "
	.. "(timer). value = avg boot."

--------------------------------------------------------------------------------------------------
-- Buckets (same rules as ServerHealthLogic)
--------------------------------------------------------------------------------------------------

--[[
	Index of the bucket for `value`: the first bound with value <= bound, else the open-ended
	overflow bucket (#bounds + 1). No allocation (called every frame on the client).
	Example: ClientPerfLogic.bucketIndex(16.7, Buckets.FrameMs) --> 3
]]
function ClientPerfLogic.bucketIndex(value: number, bounds: { number }): number
	for index, bound in bounds do
		if value <= bound then
			return index
		end
	end
	return #bounds + 1
end

--[[ Key-safe label of bucket `index` ("<8.4", "11.2-16.8", "100.1+"); never contains ":". ]]
function ClientPerfLogic.bucketLabel(index: number, bounds: { number }): string
	if index <= 1 then
		return `<{bounds[1]}`
	elseif index > #bounds then
		return `{bounds[#bounds]}+`
	end
	return `{bounds[index - 1]}-{bounds[index]}`
end

--[[ The bucket index holding the `fraction` percentile of a histogram (0 when empty). ]]
function ClientPerfLogic.percentileIndex(counts: { number }, fraction: number): number
	local total = 0
	for _, value in counts do
		total += value
	end
	if total <= 0 then
		return 0
	end
	local target = total * math.clamp(fraction, 0, 1)
	local running = 0
	for index, value in counts do
		running += value
		if running >= target then
			return index
		end
	end
	return #counts
end

--------------------------------------------------------------------------------------------------
-- Client: the window accumulator
--------------------------------------------------------------------------------------------------

-- A sample value made safe: finite and >= 0 (NaN / ±inf / negatives become 0).
local function finite(value: number): number
	return if value == value and math.abs(value) < math.huge then math.max(value, 0) else 0
end

--[[
	A fresh window starting at `now` (os.clock()). Create ONE per client and `reset` it after
	each report: the per-frame path never allocates.
]]
function ClientPerfLogic.newWindow(now: number): Window
	return {
		startedAt = now,
		frames = 0,
		frameBuckets = table.create(FRAME_BUCKETS, 0),
		samples = 0,
		memorySum = 0,
		memoryMax = 0,
		receiveSum = 0,
		pingSum = 0,
		pingMax = 0,
		bootSeconds = -1,
		bootSteps = table.create(BOOT_STEP_COUNT, -1),
		bootEnd = 0,
		mapCount = 0,
		mapSum = 0,
		mapMax = 0,
		receiveZero = 0,
		tracking = 0,
		tagSamples = 0,
		tagTotalSum = 0,
		groupSums = table.create(GROUP_COUNT, 0),
		instanceSum = 0,
	}
end

--[[
	Clears a window for the next report (keeps its histogram and boot-step tables) and starts it at
	`now`. The boot time and its step block are cleared too (they were just encoded, so they are
	reported exactly once per session) unless `keepBoot` is true: a window dropped unsent keeps
	its boot for the next one.
	Example: ClientPerfLogic.reset(window, os.clock(), true) -- drop the window, keep the boot
]]
function ClientPerfLogic.reset(window: Window, now: number, keepBoot: boolean?)
	window.startedAt = now
	window.frames = 0
	for index = 1, FRAME_BUCKETS do
		window.frameBuckets[index] = 0
	end
	window.samples = 0
	window.memorySum = 0
	window.memoryMax = 0
	window.receiveSum = 0
	window.pingSum = 0
	window.pingMax = 0
	if not keepBoot then
		window.bootSeconds = -1
		for index = 1, BOOT_STEP_COUNT do
			window.bootSteps[index] = -1
		end
		window.bootEnd = 0
	end
	window.mapCount = 0
	window.mapSum = 0
	window.mapMax = 0
	window.receiveZero = 0
	window.tracking = 0
	window.tagSamples = 0
	window.tagTotalSum = 0
	for index = 1, GROUP_COUNT do
		window.groupSums[index] = 0
	end
	window.instanceSum = 0
end

--[[
	Counts one rendered frame (`dt` seconds, RunService.PreRender's delta). Non-finite or
	non-positive deltas are ignored (a paused / first frame).
]]
function ClientPerfLogic.addFrame(window: Window, dt: number)
	if not (dt > 0 and dt < math.huge) then
		return
	end
	window.frames += 1
	local index = ClientPerfLogic.bucketIndex(dt * 1000, Buckets.FrameMs)
	window.frameBuckets[index] += 1
end

--[[
	Adds one low-rate sample: total client memory (MB), receive rate (Stats.DataReceiveKbps) and
	network ping (ms). Non-finite values count as 0 so one odd engine read cannot poison a window.
]]
function ClientPerfLogic.addSample(window: Window, memoryMb: number, receiveKbps: number, pingMs: number)
	local memory, receive, ping = finite(memoryMb), finite(receiveKbps), finite(pingMs)
	window.samples += 1
	window.memorySum += memory
	window.memoryMax = math.max(window.memoryMax, memory)
	window.receiveSum += receive
	-- Engine leaves DataReceiveKbps unpopulated (0) on most clients: count those reads so the
	-- report can say "n/a" instead of averaging zeros (ClientPerfConfig.Receive).
	if receive <= 0 then
		window.receiveZero += 1
	end
	window.pingSum += ping
	window.pingMax = math.max(window.pingMax, ping)
end

--[[
	Adds one memory-tag read (wire v2; every MemoryTags.IntervalSeconds, taken on the same tick as
	a Stats sample so the total below is one of that window's memory samples).
	@param window the accumulator
	@param tracking Stats.MemoryTrackingEnabled (false → the groups are ignored and the report
	       says "tracking off"; the engine fixes the flag for the whole client session)
	@param totalMb the Stats:GetTotalMemoryUsageMb() value of the same tick
	@param groups MB per MemoryTags.Groups entry (the caller's reused scratch table; read only)
	@param instances Stats.InstanceCount
	No allocation: sums into the window's own groupSums table. Non-finite values count as 0.
	Example: ClientPerfLogic.addTagSample(window, true, 1800, scratch, 95000)
]]
function ClientPerfLogic.addTagSample(
	window: Window,
	tracking: boolean,
	totalMb: number,
	groups: { number },
	instances: number
)
	-- The flag stays 1 only while every read in the window had tracking on.
	window.tracking = if tracking and (window.tagSamples == 0 or window.tracking == 1) then 1 else 0
	window.tagSamples += 1
	window.tagTotalSum += finite(totalMb)
	window.instanceSum += finite(instances)
	if tracking then
		for index = 1, GROUP_COUNT do
			window.groupSums[index] += finite(groups[index] or 0)
		end
	end
end

--[[
	The MemoryTags.Groups index a DeveloperMemoryTag NAME belongs to (resolved once per tag at
	client start). Unknown names (a tag Roblox added or renamed after MemoryTags.TagGroup was
	written) go to MemoryTags.UnknownGroup so "untracked" never absorbs a real category.
	Example: ClientPerfLogic.tagGroupIndex("GraphicsTexture") --> 1 (Texture)
]]
function ClientPerfLogic.tagGroupIndex(tagName: string): number
	local group = MemoryTags.TagGroup[tagName]
	return if group ~= nil then GROUP_INDEX[group] or UNKNOWN_GROUP else UNKNOWN_GROUP
end

--[[
	The ANALYTICS device class of a report (wire v2). A device the UI classifies as Phone / Tablet
	(DeviceProfile: a touch screen, touch preferred) that also has a hardware keyboard is a touch
	laptop / 2-in-1 (or a tablet with a keyboard cover): it reports as
	ClientPerfConfig.TouchKeyboardClass so its desktop-class numbers stay out of the tablet rows.
	The UI keeps using DeviceProfile's class unchanged; only the perf report uses this.
	@param profileClass DeviceProfile.current().class
	@param keyboardEnabled UserInputService.KeyboardEnabled
	Example: ClientPerfLogic.reportClass("Tablet", true) --> "TouchLaptop"
]]
function ClientPerfLogic.reportClass(profileClass: string, keyboardEnabled: boolean): string
	if keyboardEnabled and (profileClass == "Phone" or profileClass == "Tablet") then
		return ClientPerfConfig.TouchKeyboardClass
	end
	return profileClass
end

--[[
	Records the session's boot-to-game seconds (sent with the next report, once) and, wire v4, the
	loading screen's boot-step block.
	@param seconds BootSeconds (finite, >= 0; anything else is ignored with the whole block)
	@param steps optional step name → completion seconds (ClientPerfConfig.BootSteps names; a
	       missing, non-number, negative or non-finite value = not finished, -1)
	@param endReason optional hand-off reason (a ClientPerfConfig.BootEndReasons entry; unknown = none)
	Example: ClientPerfLogic.setBoot(window, 6.2, { Loaded = 0.4, Assets = 6.1 }, "budget")
]]
function ClientPerfLogic.setBoot(window: Window, seconds: number, steps: { [string]: unknown }?, endReason: unknown?)
	if not (seconds == seconds and seconds >= 0 and seconds < math.huge) then
		return
	end
	window.bootSeconds = seconds
	for index, step in BOOT_STEPS do
		local value = if steps ~= nil then steps[step] else nil
		window.bootSteps[index] = if type(value) == "number"
				and value == value
				and value >= 0
				and value < math.huge
			then value
			else -1
	end
	window.bootEnd = if type(endReason) == "string" then table.find(BOOT_END_REASONS, endReason) or 0 else 0
end

--[[ Records one map's Loading → fully-replicated seconds. ]]
function ClientPerfLogic.addMapReady(window: Window, seconds: number)
	if not (seconds == seconds and seconds >= 0 and seconds < math.huge) then
		return
	end
	window.mapCount += 1
	window.mapSum += seconds
	window.mapMax = math.max(window.mapMax, seconds)
end

--[[
	Encodes a window into its wire buffer (one allocation per report, never per frame).
	@param window the accumulator
	@param classIndex the device class's index in ClientPerfConfig.DeviceClasses
	@param seconds the window's length (now - window.startedAt)
	@param sessionMinutes minutes since the client started measuring (nil = 0)
	@param clientFx [WS-B] client FX instances right now (ClientFX + Terrain descendants; nil = 0)
	@return a ClientPerfLogic.WireBytes-byte buffer for the ClientPerf remote
]]
function ClientPerfLogic.encode(
	window: Window,
	classIndex: number,
	seconds: number,
	sessionMinutes: number?,
	clientFx: number?
): buffer
	local out = buffer.create(SLOT_COUNT * 4)
	local function put(slot: number, value: number)
		buffer.writef32(out, (slot - 1) * 4, value)
	end
	local samples = window.samples
	put(SLOT.version, ClientPerfConfig.Version)
	put(SLOT.class, classIndex)
	put(SLOT.seconds, seconds)
	put(SLOT.frames, window.frames)
	for index = 1, FRAME_BUCKETS do
		put(SLOT.histogram + index - 1, window.frameBuckets[index])
	end
	put(SLOT.samples, samples)
	put(SLOT.memoryAvg, if samples > 0 then window.memorySum / samples else 0)
	put(SLOT.memoryMax, window.memoryMax)
	put(SLOT.receiveAvg, if samples > 0 then window.receiveSum / samples else 0)
	put(SLOT.pingAvg, if samples > 0 then window.pingSum / samples else 0)
	put(SLOT.pingMax, window.pingMax)
	put(SLOT.boot, window.bootSeconds)
	put(SLOT.mapCount, window.mapCount)
	put(SLOT.mapSum, window.mapSum)
	put(SLOT.mapMax, window.mapMax)
	-- Wire v2: receive zeros, memory-tag block (averages over the tag reads), session minutes.
	local tags = window.tagSamples
	put(SLOT.receiveZero, window.receiveZero)
	put(SLOT.tracking, window.tracking)
	put(SLOT.tagSamples, tags)
	put(SLOT.tagTotal, if tags > 0 then window.tagTotalSum / tags else 0)
	for index = 1, GROUP_COUNT do
		put(SLOT.groups + index - 1, if tags > 0 then window.groupSums[index] / tags else 0)
	end
	put(SLOT.instances, if tags > 0 then window.instanceSum / tags else 0)
	put(SLOT.sessionMinutes, finite(sessionMinutes or 0))
	put(SLOT.clientFx, finite(clientFx or 0)) -- [WS-B] wire v3
	-- Wire v4: the boot-step block (-1 / 0 when no boot rides this report).
	local hasBoot = window.bootSeconds >= 0
	for index = 1, BOOT_STEP_COUNT do
		put(SLOT.bootSteps + index - 1, if hasBoot then window.bootSteps[index] else -1)
	end
	put(SLOT.bootEnd, if hasBoot then window.bootEnd else 0)
	return out
end

--------------------------------------------------------------------------------------------------
-- Server: validation, counters, report rows
--------------------------------------------------------------------------------------------------

-- A finite number from a float32 slot (nil for NaN / ±inf).
local function readSlot(raw: buffer, slot: number): number?
	local value = buffer.readf32(raw, (slot - 1) * 4)
	if value ~= value or math.abs(value) == math.huge then
		return nil
	end
	return value
end

--[[
	Validates the wire v4 boot-step block (slots bootSteps .. bootEnd) against the report's boot.
	Strict, because the block is a claim about the loading screen: every step slot is exactly -1
	(not finished) or a whole-report-consistent second (0 .. raw boot + BootStepSlackSeconds,
	then clamped to the clamped boot); the reason index is a whole number 0..#BootEndReasons;
	"no reason" (0) comes with no steps; "ready" / "budget" (every step finished) need all six
	steps ("tap" / "auto" may carry any subset). Without a boot time the block must be empty.
	@param values the finite slot values
	@param rawBoot slot 21 as sent (negative = no boot in this report)
	@param boot the clamped boot seconds, or nil
	@return (steps?, reason?, dropped): steps / reason only for a valid, non-empty block; dropped =
	        the block was present but refused
]]
local function decodeBootBlock(values: { number }, rawBoot: number, boot: number?): ({ number }?, string?, boolean)
	local endIndex = values[SLOT.bootEnd]
	local present = 0
	local malformed = false
	for index = 1, BOOT_STEP_COUNT do
		local value = values[SLOT.bootSteps + index - 1]
		if value ~= -1 then
			present += 1
			if value < 0 or boot == nil or value > rawBoot + Limits.BootStepSlackSeconds then
				malformed = true
			end
		end
	end
	if endIndex ~= math.floor(endIndex) or endIndex < 0 or endIndex > #BOOT_END_REASONS then
		malformed = true
	end
	if boot == nil then
		-- No boot time in this report: the block must be empty (it only ever rides the boot).
		return nil, nil, malformed or present > 0 or endIndex ~= 0
	end
	if malformed or (endIndex == 0 and present > 0) then
		return nil, nil, true -- steps without a hand-off reason: the Loader always sets both
	end
	if endIndex == 0 then
		return nil, nil, false -- a boot without a loading screen (the gate-time fallback)
	end
	local reason = BOOT_END_REASONS[endIndex]
	if (reason == "ready" or reason == "budget") and present ~= BOOT_STEP_COUNT then
		return nil, nil, true -- "everything finished" without every step: contradictory
	end
	local steps = table.create(BOOT_STEP_COUNT, -1)
	for index = 1, BOOT_STEP_COUNT do
		local value = values[SLOT.bootSteps + index - 1]
		steps[index] = if value >= 0 then math.min(value, boot) else -1
	end
	return steps, reason, false
end

--[[
	Validates and clamps one untrusted ClientPerf payload.
	@param raw whatever the client sent (must be a buffer of exactly WireBytes bytes)
	@param maxSeconds the longest window this player can honestly claim right now (seconds since
	       their previous accepted report or since they joined, plus WindowSlackSeconds)
	@param maxSessionMinutes the longest session this player can honestly claim (the server's own
	       minutes since join + Limits.SessionSlackMinutes; nil = Limits.MaxSessionMinutes)
	@return the clamped Report, or nil (wrong type / size / version / class, any non-finite slot,
	        a window under 1 s, more frames than MaxFps allows, or a histogram that does not add
	        up to the frame count). A memory-tag block that fails its own checks (groups summing
	        above GroupSumSlack × the total, a malformed tracking flag) is dropped, not the report;
	        so is a malformed wire v4 boot-step block (decodeBootBlock; bootDropped = true).
	Example: ClientPerfLogic.decode(buffer.create(3), 60) --> nil
]]
function ClientPerfLogic.decode(raw: unknown, maxSeconds: number, maxSessionMinutes: number?): Report?
	if typeof(raw) ~= "buffer" then
		return nil
	end
	local payload = raw :: buffer
	if buffer.len(payload) ~= SLOT_COUNT * 4 then
		return nil
	end
	local values = table.create(SLOT_COUNT, 0)
	for slot = 1, SLOT_COUNT do
		local value = readSlot(payload, slot)
		if value == nil then
			return nil
		end
		values[slot] = value
	end
	if values[SLOT.version] ~= ClientPerfConfig.Version then
		return nil
	end
	local classIndex = values[SLOT.class]
	local class = if classIndex == math.floor(classIndex) then ClientPerfConfig.DeviceClasses[classIndex] else nil
	if class == nil then
		return nil
	end
	-- Window length: at least a second, never longer than the player could have measured.
	local cap = math.min(Limits.MaxWindowSeconds, math.max(maxSeconds, 1))
	local seconds = values[SLOT.seconds]
	if seconds < 1 then
		return nil
	end
	seconds = math.min(seconds, cap)
	-- Frames: whole, non-negative, plausible for the window, and the histogram must add up.
	local frames = values[SLOT.frames]
	if frames < 0 or frames ~= math.floor(frames) or frames > seconds * Limits.MaxFps then
		return nil
	end
	local histogram = table.create(FRAME_BUCKETS, 0)
	local total = 0
	for index = 1, FRAME_BUCKETS do
		local count = values[SLOT.histogram + index - 1]
		if count < 0 or count ~= math.floor(count) then
			return nil
		end
		histogram[index] = count
		total += count
	end
	if total ~= frames then
		return nil
	end
	-- Samples: at most one per second of window (+1 for the edges); values clamped to sane ranges.
	local samples = math.clamp(math.floor(values[SLOT.samples]), 0, math.ceil(seconds) + 1)
	local memory = math.clamp(values[SLOT.memoryAvg], 0, Limits.MaxMemoryMb)
	local ping = math.clamp(values[SLOT.pingAvg], 0, Limits.MaxPingMs)
	local boot = values[SLOT.boot]
	local bootSeconds = if boot >= 0 then math.min(boot, Limits.MaxBootSeconds) else nil
	local bootSteps, bootEnd, bootDropped = decodeBootBlock(values, boot, bootSeconds)
	local mapCount = math.clamp(math.floor(values[SLOT.mapCount]), 0, Limits.MaxMapsPerReport)
	local mapMax = if mapCount > 0 then math.clamp(values[SLOT.mapMax], 0, Limits.MaxMapReadySeconds) else 0
	local memoryMax = if samples > 0 then math.clamp(values[SLOT.memoryMax], memory, Limits.MaxMemoryMb) else 0

	-- Wire v2 (perf investigation 2026-10-20). Zero-receive reads: whole, at most the samples.
	local receiveZero = math.clamp(math.floor(values[SLOT.receiveZero]), 0, samples)
	-- Session minutes: never more than the server itself has seen this player for.
	local sessionCap = math.min(Limits.MaxSessionMinutes, math.max(maxSessionMinutes or Limits.MaxSessionMinutes, 0))
	local sessionMinutes = math.clamp(values[SLOT.sessionMinutes], 0, sessionCap)
	-- Memory tags ride the Stats sample ticks (one read per IntervalSeconds), so a block needs
	-- samples, and its total is one of those memory samples: it can never exceed their max.
	local tagCap = math.min(samples, math.ceil(seconds / MemoryTags.IntervalSeconds) + 1)
	local tagSamples = math.clamp(math.floor(values[SLOT.tagSamples]), 0, tagCap)
	local tagTotal, instances = 0, 0
	local groups: { number }? = nil
	local trackingOff, groupsDropped = false, false
	if tagSamples > 0 then
		tagTotal = math.clamp(values[SLOT.tagTotal], 0, memoryMax)
		instances = math.clamp(math.floor(values[SLOT.instances]), 0, Limits.MaxInstances)
		local tracking = values[SLOT.tracking]
		if tracking == 1 then
			local block = table.create(GROUP_COUNT, 0)
			local sum = 0
			for index = 1, GROUP_COUNT do
				local value = math.clamp(values[SLOT.groups + index - 1], 0, Limits.MaxMemoryMb)
				block[index] = value
				sum += value
			end
			-- The tags describe parts of the process: their sum cannot be far above the total.
			if sum <= tagTotal * Limits.GroupSumSlack then
				groups = block
			else
				groupsDropped = true
			end
		elseif tracking == 0 then
			trackingOff = true
		else
			groupsDropped = true -- a flag that is neither 0 nor 1
		end
	end

	return {
		class = class,
		seconds = seconds,
		frames = frames,
		frameBuckets = histogram,
		samples = samples,
		memoryMb = if samples > 0 then memory else 0,
		memoryMaxMb = memoryMax,
		receiveKbps = if samples > 0 then math.clamp(values[SLOT.receiveAvg], 0, Limits.MaxReceiveKbps) else 0,
		pingMs = if samples > 0 then ping else 0,
		pingMaxMs = if samples > 0 then math.clamp(values[SLOT.pingMax], ping, Limits.MaxPingMs) else 0,
		bootSeconds = bootSeconds,
		bootSteps = bootSteps,
		bootEnd = bootEnd,
		bootDropped = bootDropped,
		mapCount = mapCount,
		-- The sum can never exceed count × the slowest map (both already clamped).
		mapSeconds = if mapCount > 0 then math.clamp(values[SLOT.mapSum], 0, mapCount * mapMax) else 0,
		mapMaxSeconds = mapMax,
		receiveZeroSamples = receiveZero,
		sessionMinutes = sessionMinutes,
		tagSamples = tagSamples,
		tagTotalMb = tagTotal,
		instances = instances,
		memoryGroups = groups,
		trackingOff = trackingOff,
		groupsDropped = groupsDropped,
		-- [WS-B] wire v3: a whole, bounded count (a claim, like everything else here)
		clientFx = math.clamp(math.floor(values[SLOT.clientFx]), 0, ClientPerfConfig.MaxClientFx),
	}
end

-- Two decimals (counters are summed across servers; sub-centisecond detail is noise).
local function round2(value: number): number
	return math.round(value * 100) / 100
end

--[[
	The "health" family analytics counter deltas for one accepted report (see the header).
	@return key → amount (every amount finite and >= 0)
]]
function ClientPerfLogic.counters(report: Report): { [string]: number }
	local prefix = `{ClientPerfConfig.KeyPrefix}:{report.class}:`
	local out: { [string]: number } = {}
	local function add(key: string, amount: number)
		if amount > 0 then
			out[prefix .. key] = (out[prefix .. key] or 0) + amount
		end
	end
	add("reports", 1)
	add("seconds", round2(report.seconds))
	add("frames", report.frames)
	for index, count in report.frameBuckets do
		add(`ft:{ClientPerfLogic.bucketLabel(index, Buckets.FrameMs)}`, count)
	end
	if report.samples > 0 then
		add("sampled", 1)
		add("memMb", round2(report.memoryMb))
		add("pingMs", round2(report.pingMs))
		add("recvKbps", round2(report.receiveKbps))
		add(
			`mem:{ClientPerfLogic.bucketLabel(
				ClientPerfLogic.bucketIndex(report.memoryMb, Buckets.MemoryMb),
				Buckets.MemoryMb
			)}`,
			1
		)
		add(
			`ping:{ClientPerfLogic.bucketLabel(
				ClientPerfLogic.bucketIndex(report.pingMs, Buckets.PingMs),
				Buckets.PingMs
			)}`,
			1
		)
		add(
			`recv:{ClientPerfLogic.bucketLabel(
				ClientPerfLogic.bucketIndex(report.receiveKbps, Buckets.ReceiveKbps),
				Buckets.ReceiveKbps
			)}`,
			1
		)
	end
	local boot = report.bootSeconds
	if boot ~= nil then
		add("boots", 1)
		add("bootS", round2(boot))
		add(
			`boot:{ClientPerfLogic.bucketLabel(
				ClientPerfLogic.bucketIndex(boot, Buckets.BootSeconds),
				Buckets.BootSeconds
			)}`,
			1
		)
	end
	-- Wire v4 (owner R122): which loading step finished when, and why the screen handed off.
	local bootSteps = report.bootSteps
	if bootSteps ~= nil then
		for index, step in BOOT_STEPS do
			local seconds = bootSteps[index]
			if seconds >= 0 then
				local bucket = ClientPerfLogic.bucketLabel(
					ClientPerfLogic.bucketIndex(seconds, Buckets.BootSeconds),
					Buckets.BootSeconds
				)
				add(`bootStep:{step}:{bucket}`, 1)
				add(`bootStepS:{step}`, round2(seconds))
			end
		end
	end
	if report.bootEnd ~= nil then
		add(`bootEnd:{report.bootEnd}`, 1)
	end
	if report.bootDropped then
		add("bootDrop", 1)
	end
	if report.mapCount > 0 then
		local average = report.mapSeconds / report.mapCount
		add("maps", report.mapCount)
		add("mapS", round2(report.mapSeconds))
		add(
			`map:{ClientPerfLogic.bucketLabel(
				ClientPerfLogic.bucketIndex(average, Buckets.MapReadySeconds),
				Buckets.MapReadySeconds
			)}`,
			report.mapCount
		)
	end
	-- Wire v2 (perf investigation 2026-10-20): receive zeros, memory by session age, memory tags.
	if report.samples > 0 then
		add("recvN", report.samples)
		add("recvZero", report.receiveZeroSamples)
		local age = ClientPerfLogic.bucketLabel(
			ClientPerfLogic.bucketIndex(report.sessionMinutes, Buckets.SessionMinutes),
			Buckets.SessionMinutes
		)
		add(`age:{age}`, 1)
		add(`ageMb:{age}`, round2(report.memoryMb))
	end
	if report.tagSamples > 0 then
		add("instN", 1)
		add("inst", math.round(report.instances))
		local groups = report.memoryGroups
		if groups ~= nil then
			add("mgN", 1)
			add("mgTotMb", round2(report.tagTotalMb))
			for index, group in MemoryTags.Groups do
				add(`mg:{group}`, round2(groups[index]))
			end
		elseif report.trackingOff then
			add("mgOff", 1)
		elseif report.groupsDropped then
			add("mgDrop", 1)
		end
	end
	-- [WS-B begin] wire v3: the client FX count (a report-time snapshot, sampled or not)
	if report.clientFx > 0 then
		add("fxN", 1)
		add("fx", report.clientFx)
	end
	-- [WS-B end]
	return out
end

-- Histogram counts read back from stored counters ("<prefix><metric>:<bucket>" keys).
local function storedHistogram(counters: { [string]: number }, prefix: string, bounds: { number }): { number }
	local counts = table.create(#bounds + 1, 0)
	for index = 1, #bounds + 1 do
		counts[index] = counters[`{prefix}:{ClientPerfLogic.bucketLabel(index, bounds)}`] or 0
	end
	return counts
end

-- "p95 25.1-33.4" style text for a stored histogram ("" when empty).
local function percentileText(
	counts: { number },
	bounds: { number },
	fraction: number,
	name: string,
	unit: string
): string
	local index = ClientPerfLogic.percentileIndex(counts, fraction)
	if index == 0 then
		return ""
	end
	return `{name} {ClientPerfLogic.bucketLabel(index, bounds)}{unit}`
end

--[[
	"recv 41 kbps", or "recv n/a" when the engine left Stats.DataReceiveKbps unpopulated
	(ClientPerfConfig.Receive): at least NaZeroShare of the v2 samples read 0, or — for counters
	stored before wire v2, which carry no zero count — an average under LegacyFloorKbps.
	Never prints a near-zero average as if it were a measurement.
	@param counters stored "health" counters
	@param prefix "cp:<Class>:"
	@param sampled the class's sampled-report count (> 0)
]]
local function receiveText(counters: { [string]: number }, prefix: string, sampled: number): string
	local average = (counters[prefix .. "recvKbps"] or 0) / sampled
	local reads = counters[prefix .. "recvN"] or 0
	local unset = if reads > 0
		then (counters[prefix .. "recvZero"] or 0) / reads >= ClientPerfConfig.Receive.NaZeroShare
		else average < ClientPerfConfig.Receive.LegacyFloorKbps
	if unset then
		return "recv n/a (unset on clients)"
	end
	return `recv {math.round(average)} kbps`
end

--[[
	The "Client performance by device" report rows from stored "health" counters: one row per
	device class with at least ClientPerfConfig.MinReportsForRow reports. value = average fps.
	@param counters the summed "health" family counters of the report range
	@return rows in DeviceClasses order (empty when no class has enough reports)
]]
function ClientPerfLogic.rows(counters: { [string]: number }): { Row }
	local rows: { Row } = {}
	for _, class in ClientPerfConfig.DeviceClasses do
		local prefix = `{ClientPerfConfig.KeyPrefix}:{class}:`
		local reports = counters[prefix .. "reports"] or 0
		local seconds = counters[prefix .. "seconds"] or 0
		if reports < ClientPerfConfig.MinReportsForRow or seconds <= 0 then
			continue
		end
		local fps = (counters[prefix .. "frames"] or 0) / seconds
		local frameCounts = storedHistogram(counters, prefix .. "ft", Buckets.FrameMs)
		-- Share of frames slower than SlowFrameMs (the buckets above the one ending at it).
		local totalFrames, slowFrames = 0, 0
		for index, count in frameCounts do
			totalFrames += count
			if index > SLOW_FRAME_BUCKET then
				slowFrames += count
			end
		end
		local parts: { string } = {}
		local function push(text: string)
			if text ~= "" then
				table.insert(parts, text)
			end
		end
		push(percentileText(frameCounts, Buckets.FrameMs, 0.5, "frame p50", " ms"))
		push(percentileText(frameCounts, Buckets.FrameMs, 0.95, "p95", " ms"))
		if totalFrames > 0 then
			push(`<30 fps {math.round(slowFrames / totalFrames * 100)} % of frames`)
		end
		local sampled = counters[prefix .. "sampled"] or 0
		if sampled > 0 then
			push(`mem {math.round((counters[prefix .. "memMb"] or 0) / sampled)} MB`)
			push(
				percentileText(
					storedHistogram(counters, prefix .. "mem", Buckets.MemoryMb),
					Buckets.MemoryMb,
					0.95,
					"p95",
					" MB"
				)
			)
			push(`ping {math.round((counters[prefix .. "pingMs"] or 0) / sampled)} ms`)
			push(receiveText(counters, prefix, sampled))
		end
		local boots = counters[prefix .. "boots"] or 0
		if boots > 0 then
			-- R122: the boot p50 (bucket range) is a primary metric of the fast-first-minute change.
			local bootP50 =
				ClientPerfLogic.percentileIndex(storedHistogram(counters, prefix .. "boot", Buckets.BootSeconds), 0.5)
			local average = (counters[prefix .. "bootS"] or 0) / boots
			push(
				if bootP50 > 0
					then string.format(
						"boot %.1f s (p50 %s s, n %d)",
						average,
						ClientPerfLogic.bucketLabel(bootP50, Buckets.BootSeconds),
						boots
					)
					else string.format("boot %.1f s (n %d)", average, boots)
			)
		end
		local maps = counters[prefix .. "maps"] or 0
		if maps > 0 then
			push(string.format("map ready %.1f s (n %d)", (counters[prefix .. "mapS"] or 0) / maps, maps))
		end
		push(`{math.round(reports)} reports`)
		table.insert(rows, {
			id = string.lower(class),
			label = class,
			value = math.round(fps * 10) / 10,
			display = string.format("%.0f fps", fps),
			extra = table.concat(parts, " · "),
		})
	end
	return rows
end

--[[
	The "Client memory by device" report rows (wire v2) from stored "health" counters: one row per
	device class with at least MinReportsForRow reports and any v2 memory data. value = average
	total memory (MB) at the tag reads; extra = the tag groups ("tex · mesh · render · gui · lua ·
	inst · phys · sound · other · untracked (total − tags)"), the average Stats.InstanceCount,
	memory per session-age bucket (leak check) and how many reports had no / a dropped tag block.
	@param counters the summed "health" family counters of the report range
	@return rows in DeviceClasses order (empty before any v2 report)
	Example extra: "tex 410 · mesh 180 · ... · untracked 900 · 98000 instances · age <5 min 1500 MB
	(n 40) · 5-15 min 1620 MB (n 80) · 52 tagged reports"
]]
function ClientPerfLogic.memoryRows(counters: { [string]: number }): { Row }
	local rows: { Row } = {}
	local ageBounds = Buckets.SessionMinutes
	for _, class in ClientPerfConfig.DeviceClasses do
		local prefix = `{ClientPerfConfig.KeyPrefix}:{class}:`
		if (counters[prefix .. "reports"] or 0) < ClientPerfConfig.MinReportsForRow then
			continue
		end
		local tagged = counters[prefix .. "mgN"] or 0
		local instReports = counters[prefix .. "instN"] or 0
		local parts: { string } = {}
		local value, display = 0, "tags n/a"
		if tagged > 0 then
			local total = (counters[prefix .. "mgTotMb"] or 0) / tagged
			local tagSum = 0
			for index, group in MemoryTags.Groups do
				local average = (counters[`{prefix}mg:{group}`] or 0) / tagged
				tagSum += average
				table.insert(parts, `{MemoryTags.Short[index]} {math.round(average)}`)
			end
			table.insert(parts, `untracked {math.round(math.max(0, total - tagSum))}`)
			value = math.round(total)
			display = `{value} MB`
		end
		if instReports > 0 then
			table.insert(parts, `{math.round((counters[prefix .. "inst"] or 0) / instReports)} instances`)
		end
		-- [WS-B begin] wire v3: average client FX instances (ClientFX + Terrain descendants)
		local fxReports = counters[prefix .. "fxN"] or 0
		if fxReports > 0 then
			table.insert(parts, `{math.round((counters[prefix .. "fx"] or 0) / fxReports)} client FX`)
		end
		-- [WS-B end]
		-- Memory by session age (same reports as the main table's "mem"), oldest last.
		local ageParts = 0
		for index = 1, #ageBounds + 1 do
			local label = ClientPerfLogic.bucketLabel(index, ageBounds)
			local n = counters[`{prefix}age:{label}`] or 0
			if n > 0 then
				local mb = math.round((counters[`{prefix}ageMb:{label}`] or 0) / n)
				table.insert(parts, `{if ageParts == 0 then "age " else ""}{label} min {mb} MB (n {math.round(n)})`)
				ageParts += 1
			end
		end
		if tagged == 0 and instReports == 0 and ageParts == 0 then
			continue -- only reports from before wire v2: nothing to show
		end
		local off = counters[prefix .. "mgOff"] or 0
		if off > 0 then
			table.insert(parts, `memory tracking off on {math.round(off)} reports`)
		end
		local dropped = counters[prefix .. "mgDrop"] or 0
		if dropped > 0 then
			table.insert(parts, `{math.round(dropped)} tag blocks dropped`)
		end
		table.insert(parts, `{math.round(tagged)} tagged reports`)
		table.insert(rows, {
			id = string.lower(class),
			label = class,
			value = value,
			display = display,
			extra = table.concat(parts, " · "),
		})
	end
	return rows
end

--[[
	R122: the "Client boot steps by device" report rows from stored "health" counters (wire v4):
	one row per device class with at least MinReportsForRow reports and any boot-step data.
	value = average boot seconds (slowest class first when sorted by value); extra = per loading
	step its average completion second and p50 bucket (in loading order — the step whose average
	jumps is the slow one), then the hand-off reasons as shares (ready = all loaded, budget = the
	critical preload was cut by the asset budget, tap / auto = the player / the timer skipped a
	stuck load) and refused blocks.
	@param counters the summed "health" family counters of the report range
	@return rows in DeviceClasses order (empty before any v4 report)
	Example extra: "Loaded 0.4 s (p50 <5) · Client 1.9 s (p50 <5) · ... · Assets 5.8 s (p50 5-10) ·
	end ready 71 % · budget 24 % · tap 3 % · auto 2 % · n 120"
]]
function ClientPerfLogic.bootRows(counters: { [string]: number }): { Row }
	local rows: { Row } = {}
	local bounds = Buckets.BootSeconds
	for _, class in ClientPerfConfig.DeviceClasses do
		local prefix = `{ClientPerfConfig.KeyPrefix}:{class}:`
		if (counters[prefix .. "reports"] or 0) < ClientPerfConfig.MinReportsForRow then
			continue
		end
		local parts: { string } = {}
		local stepData = false
		for _, step in BOOT_STEPS do
			local histogram = storedHistogram(counters, `{prefix}bootStep:{step}`, bounds)
			local n = 0
			for _, count in histogram do
				n += count
			end
			if n > 0 then
				stepData = true
				local average = (counters[`{prefix}bootStepS:{step}`] or 0) / n
				local p50 = ClientPerfLogic.percentileIndex(histogram, 0.5)
				table.insert(
					parts,
					string.format("%s %.1f s (p50 %s)", step, average, ClientPerfLogic.bucketLabel(p50, bounds))
				)
			end
		end
		local ends = 0
		for _, reason in BOOT_END_REASONS do
			ends += counters[`{prefix}bootEnd:{reason}`] or 0
		end
		if ends > 0 then
			local shares: { string } = {}
			for _, reason in BOOT_END_REASONS do
				local n = counters[`{prefix}bootEnd:{reason}`] or 0
				if n > 0 then
					table.insert(shares, `{reason} {math.round(n / ends * 100)} %`)
				end
			end
			table.insert(parts, "end " .. table.concat(shares, " · "))
		end
		local dropped = counters[prefix .. "bootDrop"] or 0
		if not stepData and ends <= 0 and dropped <= 0 then
			continue -- only boots from before wire v4: the main table's boot average covers them
		end
		if dropped > 0 then
			table.insert(parts, `{math.round(dropped)} blocks refused`)
		end
		local boots = counters[prefix .. "boots"] or 0
		local average = if boots > 0 then (counters[prefix .. "bootS"] or 0) / boots else 0
		table.insert(parts, `n {math.round(ends)}`)
		table.insert(rows, {
			id = string.lower(class),
			label = class,
			value = math.round(average * 10) / 10,
			display = string.format("%.1f s", average),
			extra = table.concat(parts, " · "),
		})
	end
	return rows
end

return table.freeze(ClientPerfLogic)
