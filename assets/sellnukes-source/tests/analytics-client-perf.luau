--!strict
--[[
	Client performance telemetry regressions (lune run tests/analytics-client-perf). Real
	ClientPerfLogic (shared by ClientPerfReporter and ClientPerfIngest) + the server ingest.

	Proves:
	  1. encode → decode round trip (frames, window, device class, memory, ping, boot, plot ready).
	  2. Hostile payloads are rejected: non-buffers, wrong size, NaN / inf in any slot, a wrong
	     version, an unknown class, fractional / negative frames, a histogram that does not add up,
	     more frames than MaxFps × seconds; claims are clamped to the time since the previous report.
	  3. counters(): a bounded "cp:<Class>:*" key set (every key documented under health "cp:<Class>:*").
	  4. ClientPerfIngest: requires a live analytics session, rate limits, records "health" counters
	     (+ the R57 per-world split "perfW:<world>:*" from the server-set CurrentWorld attribute),
	     refuses junk (ops:clientRefused:ClientPerf).
	  5. R122 boot steps (wire v4): setBoot sanitises the loader's step block, encode → decode keeps
	     it, decode refuses a malformed / contradictory block (step above the boot, negative,
	     fractional or unknown reason index, "ready" without every step, steps without a boot or
	     a reason) while keeping the report; counters bootStep:<step>:<bucket> / bootStepS /
	     bootEnd / bootDrop are documented and bounded; reset(keepBoot) keeps an unsent boot;
	     the ingest counts the boot once per session (a repeat is stripped + bootDrop); rows show
	     the boot p50 and bootRows the per-step averages + hand-off shares.
]]

local Loader = require("./analytics-fixtures/Loader")
local env = Loader.new()
local check, done = Loader.checker()
env.setClock(5000)

local ClientPerfConfig = env.load("src/shared/Analytics/ClientPerfConfig")
local ClientPerfLogic = env.load("src/shared/Analytics/ClientPerfLogic")
local AnalyticsReport = env.load("src/shared/Analytics/AnalyticsReport")
local Recorder = env.load("src/server/Analytics/Recorder")
local Runtime = env.load("src/server/Analytics/Runtime")
local Sessions = env.load("src/server/Analytics/Sessions")
local ClientPerfIngest = env.load("src/server/Analytics/ClientPerfIngest")

local SLOTS = 47

-- A valid 30 s window: 1,800 frames at 60 fps, one sample, boot 7 s, plot ready 3 s.
local function goodWindow(): any
	local window = ClientPerfLogic.newWindow(0)
	for _ = 1, 1800 do
		ClientPerfLogic.addFrame(window, 1 / 60)
	end
	ClientPerfLogic.addSample(window, 1100, 20, 90)
	ClientPerfLogic.setBoot(window, 7)
	ClientPerfLogic.addMapReady(window, 3)
	return window
end

-- 1. Round trip.
local wire = ClientPerfLogic.encode(goodWindow(), 1, 30, 4, 25)
check(buffer.len(wire) == SLOTS * 4 and ClientPerfLogic.WireBytes == SLOTS * 4, "188-byte wire")
local report = ClientPerfLogic.decode(wire, 60, 10)
check(report ~= nil, "valid report decodes")
check(report.frames == 1800 and math.abs(report.seconds - 30) < 0.01, "frames + window")
check(report.class == ClientPerfConfig.DeviceClasses[1], "device class")
check(math.abs(report.memoryMb - 1100) < 1 and math.abs(report.pingMs - 90) < 1, "memory + ping")
check(report.bootSeconds ~= nil and math.abs(report.bootSeconds - 7) < 0.01, "boot seconds")
check(report.mapCount == 1 and math.abs(report.mapSeconds - 3) < 0.01, "plot ready (map) seconds")

-- 2. Hostile payloads.
local function withSlot(slot: number, value: number): buffer
	local copy = buffer.create(SLOTS * 4)
	buffer.copy(copy, 0, wire, 0, SLOTS * 4)
	buffer.writef32(copy, (slot - 1) * 4, value)
	return copy
end
for _, junk in { nil, "x", 5, {}, buffer.create(10), buffer.create(SLOTS * 4 + 4) } :: { any } do
	check(ClientPerfLogic.decode(junk, 60) == nil, `rejects {typeof(junk)} / wrong size`)
end
for slot = 1, SLOTS do
	check(ClientPerfLogic.decode(withSlot(slot, 0 / 0), 60, 10) == nil, `NaN in slot {slot} rejected`)
	check(ClientPerfLogic.decode(withSlot(slot, math.huge), 60, 10) == nil, `inf in slot {slot} rejected`)
end
check(ClientPerfLogic.decode(withSlot(1, ClientPerfConfig.Version + 1), 60, 10) == nil, "wrong version")
check(
	ClientPerfLogic.decode(withSlot(2, 0), 60, 10) == nil and ClientPerfLogic.decode(withSlot(2, 9), 60, 10) == nil,
	"unknown class"
)
check(ClientPerfLogic.decode(withSlot(4, 1800.5), 60, 10) == nil, "fractional frames")
check(ClientPerfLogic.decode(withSlot(4, -1), 60, 10) == nil, "negative frames")
check(ClientPerfLogic.decode(withSlot(4, 1801), 60, 10) == nil, "histogram must add up to frames")
local fast = ClientPerfLogic.newWindow(0)
for _ = 1, 600 do
	ClientPerfLogic.addFrame(fast, 1 / 1000)
end
check(ClientPerfLogic.decode(ClientPerfLogic.encode(fast, 3, 1, 1), 60) == nil, "more frames than MaxFps × seconds")
local clamped = ClientPerfLogic.decode(wire, 10, 10)
check(clamped == nil or clamped.seconds <= 10 + 1e-6, "window clamped to the time since the previous report")

-- 3. Counters bounded + documented.
local counters = ClientPerfLogic.counters(report)
local n = 0
for key in counters do
	n += 1
	check(string.sub(key, 1, #ClientPerfConfig.KeyPrefix + 1) == ClientPerfConfig.KeyPrefix .. ":", `prefix {key}`)
	check(#AnalyticsReport.presentPatterns({ health = { [key] = 1 } }) > 0, `documented {key}`)
end
check(n > 5 and n < 120, `bounded key set ({n})`)

-- 4. Server ingest.
local restore = Recorder.swapForTests()
local player = env.player(7)
check(not ClientPerfIngest.handleReport(player, wire), "no analytics session → refused")
Sessions.startSession(player)
env.advance(40)
-- R57: the server-set CurrentWorld attribute splits the report per world ("perfW:<world>:*").
player:SetAttribute("CurrentWorld", "dino")
check(ClientPerfIngest.handleReport(player, ClientPerfLogic.encode(goodWindow(), 1, 30, 0.5, 0)), "accepted after 40 s")
local day = Recorder.unsavedCopy()[Recorder.today()]
check(
	day ~= nil and day.health ~= nil and (day.health[`cp:{ClientPerfConfig.DeviceClasses[1]}:reports`] or 0) == 1,
	"health counters recorded"
)
check(
	day.health["perfW:dino:reports"] == 1
		and (day.health["perfW:dino:frames"] or 0) > 0
		and day.health["perfW:main:reports"] == nil,
	"client perf split by the server-known world"
)
local worldKeys = 0
for key in day.health do
	if string.sub(key, 1, 6) == "perfW:" then
		worldKeys += 1
		check(#AnalyticsReport.presentPatterns({ health = { [key] = 1 } }) > 0, `documented {key}`)
	end
end
check(worldKeys >= 3 and worldKeys <= 20, `bounded per-world perf keys ({worldKeys})`)
env.advance(1)
check(
	not ClientPerfIngest.handleReport(player, ClientPerfLogic.encode(goodWindow(), 1, 30, 1, 0)),
	"a 30 s claim 1 s later is refused"
)
check(not ClientPerfIngest.handleReport(player, "junk"), "junk refused")
local refused = Recorder.unsavedCopy()[Recorder.today()].core["ops:clientRefused:ClientPerf"] or 0
check(refused >= 2, "refusals counted")
local stats = ClientPerfIngest.stats()
check(stats.accepted == 1 and stats.rejected >= 3, "ingest stats")

-- 5. R122 boot steps (wire v4).
local BOOT_STEP_SLOT = 41
local BOOT_END_SLOT = 47
local STEPS = { Loaded = 0.4, Client = 1.25, Profile = 2, World = 2.5, Plot = 3.75, Assets = 6.5 }
local function bootWindow(reason: string?, steps: { [string]: any }?, boot: number?): any
	local window = ClientPerfLogic.newWindow(0)
	for _ = 1, 1800 do
		ClientPerfLogic.addFrame(window, 1 / 60)
	end
	ClientPerfLogic.addSample(window, 1100, 20, 90)
	ClientPerfLogic.setBoot(window, boot or 7, steps or STEPS, reason or "budget")
	return window
end
check(ClientPerfConfig.Version == 4, "wire v4")
local stepWire = ClientPerfLogic.encode(bootWindow(), 1, 30, 4, 25)
local stepReport = ClientPerfLogic.decode(stepWire, 60, 10)
check(stepReport ~= nil and not stepReport.bootDropped, "a boot-step report decodes")
check(stepReport.bootEnd == "budget", "hand-off reason kept")
for index, step in ClientPerfConfig.BootSteps do
	check(math.abs(stepReport.bootSteps[index] - STEPS[step]) < 0.01, `step {step} seconds kept`)
end
-- Reports without a boot carry an empty block (boot is sent once per session).
local plainWire = ClientPerfLogic.encode(ClientPerfLogic.newWindow(0), 1, 30)
for slot = BOOT_STEP_SLOT, BOOT_STEP_SLOT + 5 do
	check(buffer.readf32(plainWire, (slot - 1) * 4) == -1, `no boot: step slot {slot} is -1`)
end
check(buffer.readf32(plainWire, (BOOT_END_SLOT - 1) * 4) == 0, "no boot: reason slot is 0")
-- The time() fallback boot: no steps, no reason — valid, no block.
local fallback = ClientPerfLogic.newWindow(0)
for _ = 1, 1800 do
	ClientPerfLogic.addFrame(fallback, 1 / 60)
end
ClientPerfLogic.setBoot(fallback, 3)
local fallbackReport = ClientPerfLogic.decode(ClientPerfLogic.encode(fallback, 1, 30), 60, 10)
check(
	fallbackReport ~= nil
		and fallbackReport.bootSeconds ~= nil
		and fallbackReport.bootSteps == nil
		and fallbackReport.bootEnd == nil
		and not fallbackReport.bootDropped,
	"a fallback boot carries no block"
)
-- setBoot sanitises: hostile step values become "not finished", unknown reasons none.
local sanitised = ClientPerfLogic.newWindow(0)
ClientPerfLogic.setBoot(
	sanitised,
	5,
	{ Loaded = 0 / 0, Client = -2, Profile = math.huge, World = "x", Plot = 1 },
	"nope"
)
check(
	sanitised.bootSteps[1] == -1
		and sanitised.bootSteps[2] == -1
		and sanitised.bootSteps[3] == -1
		and sanitised.bootSteps[4] == -1
		and sanitised.bootSteps[5] == 1
		and sanitised.bootSteps[6] == -1
		and sanitised.bootEnd == 0,
	"setBoot sanitises steps + reason"
)
ClientPerfLogic.setBoot(sanitised, 0 / 0, STEPS, "ready")
check(sanitised.bootSeconds == 5, "a NaN boot is ignored with its block")
-- reset(keepBoot) keeps an unsent boot + block; reset() clears it.
local kept = bootWindow("tap")
ClientPerfLogic.reset(kept, 1, true)
check(kept.bootSeconds == 7 and kept.bootSteps[6] == 6.5 and kept.bootEnd == 3, "reset(keepBoot) keeps the boot")
ClientPerfLogic.reset(kept, 2)
check(kept.bootSeconds == -1 and kept.bootSteps[1] == -1 and kept.bootEnd == 0, "reset clears the boot")

-- Hostile / contradictory blocks are dropped; the report (and its boot time) is kept.
local function withSlots(base: buffer, edits: { [number]: number }): buffer
	local copy = buffer.create(SLOTS * 4)
	buffer.copy(copy, 0, base, 0, SLOTS * 4)
	for slot, value in edits do
		buffer.writef32(copy, (slot - 1) * 4, value)
	end
	return copy
end
local function expectDropped(raw: buffer, label: string)
	local decoded = ClientPerfLogic.decode(raw, 60, 10)
	check(decoded ~= nil, `{label}: report kept`)
	check(decoded.bootDropped and decoded.bootSteps == nil and decoded.bootEnd == nil, `{label}: block dropped`)
	return decoded
end
local above = expectDropped(withSlots(stepWire, { [BOOT_STEP_SLOT + 5] = 7.5 }), "step above the boot")
check(above.bootSeconds ~= nil and math.abs(above.bootSeconds - 7) < 0.01, "the boot time survives a dropped block")
expectDropped(withSlots(stepWire, { [BOOT_STEP_SLOT] = -0.5 }), "negative step")
expectDropped(withSlots(stepWire, { [BOOT_END_SLOT] = 5 }), "unknown reason index")
expectDropped(withSlots(stepWire, { [BOOT_END_SLOT] = 1.5 }), "fractional reason index")
expectDropped(withSlots(stepWire, { [BOOT_END_SLOT] = -1 }), "negative reason index")
expectDropped(withSlots(stepWire, { [BOOT_END_SLOT] = 0 }), "steps without a reason")
expectDropped(withSlots(stepWire, { [BOOT_END_SLOT] = 1, [BOOT_STEP_SLOT + 4] = -1 }), "ready without every step")
expectDropped(withSlots(stepWire, { [21] = -1 }), "steps without a boot")
expectDropped(withSlots(plainWire, { [BOOT_END_SLOT] = 4 }), "a reason without a boot")
local huge = ClientPerfLogic.decode(
	withSlots(stepWire, { [21] = 5000, [BOOT_STEP_SLOT + 5] = 4000, [BOOT_END_SLOT] = 4 }),
	60,
	10
)
check(
	huge ~= nil
		and huge.bootSeconds == ClientPerfConfig.Limits.MaxBootSeconds
		and huge.bootSteps ~= nil
		and huge.bootSteps[6] <= ClientPerfConfig.Limits.MaxBootSeconds,
	"steps are clamped to the clamped boot"
)
-- "tap" / "auto" may carry any subset of steps.
local partial =
	ClientPerfLogic.decode(ClientPerfLogic.encode(bootWindow("auto", { Loaded = 0.5, Client = 2 }, 30), 1, 30), 60, 10)
check(
	partial ~= nil
		and partial.bootEnd == "auto"
		and partial.bootSteps ~= nil
		and partial.bootSteps[3] == -1
		and not partial.bootDropped,
	"auto with a stuck step is valid"
)

-- Counters: documented, bounded, the spec's key shapes.
local stepCounters = ClientPerfLogic.counters(stepReport)
local class1 = ClientPerfConfig.DeviceClasses[1]
check(stepCounters[`cp:{class1}:bootStep:Assets:5-10`] == 1, "bootStep:<step>:<bucket> (BootSeconds buckets)")
check(stepCounters[`cp:{class1}:bootStep:Loaded:<5`] == 1, "the first step lands in <5")
check(math.abs((stepCounters[`cp:{class1}:bootStepS:Plot`] or 0) - 3.75) < 0.01, "bootStepS:<step> sums seconds")
check(stepCounters[`cp:{class1}:bootEnd:budget`] == 1, "bootEnd:<reason>")
check(stepCounters[`cp:{class1}:bootDrop`] == nil, "no drop on a valid block")
check(ClientPerfLogic.counters(above)[`cp:{class1}:bootDrop`] == 1, "bootDrop on a refused block")
local stepKeys = 0
for key in stepCounters do
	stepKeys += 1
	check(#AnalyticsReport.presentPatterns({ health = { [key] = 1 } }) > 0, `documented {key}`)
	local step = string.match(key, ":bootStepS?:([^:]+)")
	if step ~= nil then
		check(table.find(ClientPerfConfig.BootSteps, step) ~= nil, `known step id in {key}`)
	end
	local why = string.match(key, ":bootEnd:(.+)$")
	if why ~= nil then
		check(table.find(ClientPerfConfig.BootEndReasons, why) ~= nil, `known reason in {key}`)
	end
end
check(stepKeys < 120, `bounded boot-step key set ({stepKeys})`)

-- Ingest: the boot counts once per session; a repeat claim is stripped (bootDrop), report kept.
local stepPlayer = env.player(8)
Sessions.startSession(stepPlayer)
env.advance(40)
check(
	ClientPerfIngest.handleReport(stepPlayer, ClientPerfLogic.encode(bootWindow("ready"), 2, 30, 0.6, 0)),
	"boot report accepted"
)
env.advance(40)
check(
	ClientPerfIngest.handleReport(stepPlayer, ClientPerfLogic.encode(bootWindow("tap"), 2, 30, 1.3, 0)),
	"a repeat boot report is still accepted (frames count)"
)
local class2 = ClientPerfConfig.DeviceClasses[2]
local health = Recorder.unsavedCopy()[Recorder.today()].health
check(health[`cp:{class2}:boots`] == 1, "the boot counts once per session")
check(
	health[`cp:{class2}:bootEnd:ready`] == 1 and health[`cp:{class2}:bootEnd:tap`] == nil,
	"only the first block counts"
)
check(health[`cp:{class2}:bootDrop`] == 1, "the repeat is counted as a dropped block")
check(health[`cp:{class2}:reports`] == 2, "both reports' frames count")
Sessions.endSession(stepPlayer)
-- A new session may report its own boot again.
Sessions.startSession(stepPlayer)
env.advance(40)
check(
	ClientPerfIngest.handleReport(stepPlayer, ClientPerfLogic.encode(bootWindow("auto"), 2, 30, 0.6, 0)),
	"new session"
)
health = Recorder.unsavedCopy()[Recorder.today()].health
check(health[`cp:{class2}:boots`] == 2 and health[`cp:{class2}:bootEnd:auto`] == 1, "a new session counts its boot")
Sessions.endSession(stepPlayer)

-- Report rows: boot p50 in the main table, per-step averages + hand-off shares in bootRows.
local stored: { [string]: number } = {}
for _ = 1, 3 do
	for key, amount in ClientPerfLogic.counters(stepReport) do
		stored[key] = (stored[key] or 0) + amount
	end
end
for key, amount in ClientPerfLogic.counters(partial :: any) do
	stored[key] = (stored[key] or 0) + amount
end
local perfRows = ClientPerfLogic.rows(stored)
check(#perfRows == 1 and string.find(perfRows[1].extra, "boot ", 1, true) ~= nil, "main row shows the boot")
check(string.find(perfRows[1].extra, "p50 5-10 s", 1, true) ~= nil, `main row shows the boot p50 ({perfRows[1].extra})`)
local bootRows = ClientPerfLogic.bootRows(stored)
check(#bootRows == 1 and bootRows[1].label == class1, "one boot row per class with data")
local bootExtra = bootRows[1].extra
for _, step in ClientPerfConfig.BootSteps do
	check(string.find(bootExtra, step .. " ", 1, true) ~= nil, `boot row lists {step}`)
end
check(string.find(bootExtra, "Assets 6.5 s (p50 5-10)", 1, true) ~= nil, `per-step average + p50 ({bootExtra})`)
check(string.find(bootExtra, "budget 75 %", 1, true) ~= nil, "hand-off shares")
check(string.find(bootExtra, "auto 25 %", 1, true) ~= nil, "auto share")
check(#bootExtra <= 400 and #ClientPerfLogic.BootNote <= 400, "row text + note fit the report limit")
check(math.abs(bootRows[1].value - (7 * 3 + 30) / 4) < 0.1, "value = average boot seconds")
check(#ClientPerfLogic.bootRows({}) == 0, "no rows without data")
check(#ClientPerfLogic.ReportNote <= 400 and #ClientPerfLogic.MemoryNote <= 400, "notes fit")

Sessions.endSession(player)
check(Runtime.sessions[player] == nil, "session ended")
restore()

done("analytics-client-perf")
