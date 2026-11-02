--!strict
--[[
	ServerHealthLogic — pure math of the server health telemetry (adapted from RoBeasts'
	ServerHealthLogic, trimmed to what a tycoon server needs). No services, no yields.

	Purpose:
		ServerHealth keeps RUNNING TOTALS since start (frames, frame-time histogram, Stats samples,
		pings, per-system Luau time, remote sends). A measurement window is the difference of two
		snapshots (`diff`); `counters` turns a window into "health" family analytics counters that
		merge across servers and days by plain addition (sums + histograms, never averages);
		`rows` turns stored counters back into report rows (ReportSections "Server health").

	Histogram buckets: ascending upper bounds; a value <= bound falls in that bucket, above the last
	bound in the open-ended overflow bucket. Labels: "<18", "18-20", ..., "100+".

	Example:
		local before = ServerHealth.snapshot()
		task.wait(60)
		local window = ServerHealthLogic.diff(ServerHealth.snapshot(), before)
		for key, amount in ServerHealthLogic.counters(window, AnalyticsConfig.Health) do ... end
]]

export type Totals = {
	seconds: number, -- summed Heartbeat dt
	frames: number,
	frameMsSum: number,
	frameBuckets: { number },
	hbN: number, -- 2 Hz Stats samples
	hbSum: number,
	hbBuckets: { number },
	physSum: number,
	sendSum: number,
	recvSum: number,
	plrSum: number,
	memSum: number,
	memBuckets: { number },
	pingN: number,
	pingSum: number,
	pingBuckets: { number },
	systems: { [string]: number }, -- system id → Luau seconds
	remoteFires: { [string]: number }, -- remote name → fires × recipients
	remoteBytes: { [string]: number }, -- remote name → bytes × recipients
}

-- The AnalyticsConfig.Health fields this module reads (read-only: the config table is frozen).
export type HealthConfig = {
	read FrameBucketsMs: { number },
	read HeartbeatBucketsMs: { number },
	read PingBucketsMs: { number },
	read MemoryBucketsMb: { number },
	read LaggyFrameMs: number,
}

export type Row = { id: string, label: string, value: number, display: string, extra: string }

local ServerHealthLogic = {}

--[[ 1-based bucket index of `value` within ascending `bounds` (#bounds + 1 = overflow). ]]
function ServerHealthLogic.bucketIndex(value: number, bounds: { number }): number
	for index, bound in bounds do
		if value <= bound then
			return index
		end
	end
	return #bounds + 1
end

--[[ The label of bucket `index`: "<b1", "b1-b2", ..., "bn+". ]]
function ServerHealthLogic.bucketLabel(index: number, bounds: { number }): string
	if index <= 1 then
		return `<{bounds[1]}`
	elseif index > #bounds then
		return `{bounds[#bounds]}+`
	end
	return `{bounds[index - 1]}-{bounds[index]}`
end

--[[
	Index of the bucket holding the `fraction` percentile of a histogram (0 when empty).
	Example: percentileIndex({ 90, 5, 5 }, 0.95) --> 2
]]
function ServerHealthLogic.percentileIndex(counts: { number }, fraction: number): number
	local total = 0
	for _, n in counts do
		total += n
	end
	if total <= 0 then
		return 0
	end
	local target = total * fraction
	local running = 0
	for index, n in counts do
		running += n
		if running >= target then
			return index
		end
	end
	return #counts
end

local function zeros(n: number): { number }
	local out = table.create(n, 0)
	return out
end

--[[ Empty running totals for `cfg`'s bucket lists. ]]
function ServerHealthLogic.newTotals(cfg: HealthConfig): Totals
	return {
		seconds = 0,
		frames = 0,
		frameMsSum = 0,
		frameBuckets = zeros(#cfg.FrameBucketsMs + 1),
		hbN = 0,
		hbSum = 0,
		hbBuckets = zeros(#cfg.HeartbeatBucketsMs + 1),
		physSum = 0,
		sendSum = 0,
		recvSum = 0,
		plrSum = 0,
		memSum = 0,
		memBuckets = zeros(#cfg.MemoryBucketsMb + 1),
		pingN = 0,
		pingSum = 0,
		pingBuckets = zeros(#cfg.PingBucketsMs + 1),
		systems = {},
		remoteFires = {},
		remoteBytes = {},
	}
end

--[[ A deep copy (snapshot) of running totals. ]]
function ServerHealthLogic.copy(totals: Totals): Totals
	local out = table.clone(totals)
	out.frameBuckets = table.clone(totals.frameBuckets)
	out.hbBuckets = table.clone(totals.hbBuckets)
	out.memBuckets = table.clone(totals.memBuckets)
	out.pingBuckets = table.clone(totals.pingBuckets)
	out.systems = table.clone(totals.systems)
	out.remoteFires = table.clone(totals.remoteFires)
	out.remoteBytes = table.clone(totals.remoteBytes)
	return out
end

local function diffList(after: { number }, before: { number }): { number }
	local out: { number } = {}
	for index, value in after do
		out[index] = math.max(0, value - (before[index] or 0))
	end
	return out
end

local function diffMap(after: { [string]: number }, before: { [string]: number }): { [string]: number }
	local out: { [string]: number } = {}
	for key, value in after do
		local delta = value - (before[key] or 0)
		if delta > 0 then
			out[key] = delta
		end
	end
	return out
end

--[[ The window between two snapshots (after - before; never negative). ]]
function ServerHealthLogic.diff(after: Totals, before: Totals): Totals
	return {
		seconds = math.max(0, after.seconds - before.seconds),
		frames = math.max(0, after.frames - before.frames),
		frameMsSum = math.max(0, after.frameMsSum - before.frameMsSum),
		frameBuckets = diffList(after.frameBuckets, before.frameBuckets),
		hbN = math.max(0, after.hbN - before.hbN),
		hbSum = math.max(0, after.hbSum - before.hbSum),
		hbBuckets = diffList(after.hbBuckets, before.hbBuckets),
		physSum = math.max(0, after.physSum - before.physSum),
		sendSum = math.max(0, after.sendSum - before.sendSum),
		recvSum = math.max(0, after.recvSum - before.recvSum),
		plrSum = math.max(0, after.plrSum - before.plrSum),
		memSum = math.max(0, after.memSum - before.memSum),
		memBuckets = diffList(after.memBuckets, before.memBuckets),
		pingN = math.max(0, after.pingN - before.pingN),
		pingSum = math.max(0, after.pingSum - before.pingSum),
		pingBuckets = diffList(after.pingBuckets, before.pingBuckets),
		systems = diffMap(after.systems, before.systems),
		remoteFires = diffMap(after.remoteFires, before.remoteFires),
		remoteBytes = diffMap(after.remoteBytes, before.remoteBytes),
	}
end

-- Two decimals (keeps stored sums short).
local function round2(value: number): number
	return math.floor(value * 100 + 0.5) / 100
end

--[[
	A window as "health" family counters (see AnalyticsConfig.Metrics.health). Empty windows
	(no frames) return an empty map.
]]
function ServerHealthLogic.counters(window: Totals, cfg: HealthConfig): { [string]: number }
	local out: { [string]: number } = {}
	if window.frames <= 0 then
		return out
	end
	out.win = 1
	out.sec = round2(window.seconds)
	out.ftSum = round2(window.frameMsSum)
	for index, n in window.frameBuckets do
		if n > 0 then
			out[`ft:{ServerHealthLogic.bucketLabel(index, cfg.FrameBucketsMs)}`] = n
		end
	end
	local p95 = ServerHealthLogic.percentileIndex(window.frameBuckets, 0.95)
	local p95Lower = if p95 > 1 then cfg.FrameBucketsMs[p95 - 1] else 0
	if p95Lower >= cfg.LaggyFrameMs then
		out.laggy = 1
	end
	if window.hbN > 0 then
		out.hbN = window.hbN
		out.hbSum = round2(window.hbSum)
		out.physSum = round2(window.physSum)
		out.sendSum = round2(window.sendSum)
		out.recvSum = round2(window.recvSum)
		out.plrSum = window.plrSum
		out.memSum = round2(window.memSum)
		for index, n in window.hbBuckets do
			if n > 0 then
				out[`hb:{ServerHealthLogic.bucketLabel(index, cfg.HeartbeatBucketsMs)}`] = n
			end
		end
		for index, n in window.memBuckets do
			if n > 0 then
				out[`mem:{ServerHealthLogic.bucketLabel(index, cfg.MemoryBucketsMb)}`] = n
			end
		end
	end
	if window.pingN > 0 then
		out.pingN = window.pingN
		out.pingSum = round2(window.pingSum)
		for index, n in window.pingBuckets do
			if n > 0 then
				out[`ping:{ServerHealthLogic.bucketLabel(index, cfg.PingBucketsMs)}`] = n
			end
		end
	end
	for system, seconds in window.systems do
		out[`sys:{system}`] = round2(seconds * 1000)
	end
	for name, fires in window.remoteFires do
		out[`rx:{name}:n`] = fires
	end
	for name, bytes in window.remoteBytes do
		out[`rx:{name}:kb`] = round2(bytes / 1024)
	end
	return out
end

-- A stored histogram (prefix + labels) back as counts.
local function storedHistogram(counters: { [string]: number }, prefix: string, bounds: { number }): { number }
	local out: { number } = {}
	for index = 1, #bounds + 1 do
		out[index] = counters[`{prefix}{ServerHealthLogic.bucketLabel(index, bounds)}`] or 0
	end
	return out
end

local function fixed(value: number, decimals: number): string
	return string.format(`%.{decimals}f`, value)
end

-- "p50 x · p95 y" of a stored histogram (bucket upper bounds; "n/a" when empty).
local function percentiles(counts: { number }, bounds: { number }, unit: string): string
	local p50 = ServerHealthLogic.percentileIndex(counts, 0.5)
	local p95 = ServerHealthLogic.percentileIndex(counts, 0.95)
	if p50 == 0 then
		return "n/a"
	end
	return `p50 {ServerHealthLogic.bucketLabel(p50, bounds)}{unit} · p95 {ServerHealthLogic.bucketLabel(p95, bounds)}{unit}`
end

--[[
	Report rows of the stored "health" counters (summed over a range): frame time, heartbeat,
	memory, ping, players, laggy minutes. Empty when no window was recorded.
]]
function ServerHealthLogic.rows(counters: { [string]: number }, cfg: HealthConfig): { Row }
	local rows: { Row } = {}
	local windows = counters.win or 0
	if windows <= 0 then
		return rows
	end
	local frames = 0
	local frameCounts = storedHistogram(counters, "ft:", cfg.FrameBucketsMs)
	for _, n in frameCounts do
		frames += n
	end
	local seconds = counters.sec or 0
	local hbN = counters.hbN or 0
	local pingN = counters.pingN or 0
	table.insert(rows, {
		id = "windows",
		label = "Server minutes measured",
		value = windows,
		display = tostring(windows),
		extra = `{fixed(seconds / 3600, 1)} server-hours`,
	})
	table.insert(rows, {
		id = "fps",
		label = "Server FPS (avg)",
		value = if seconds > 0 then frames / seconds else 0,
		display = if seconds > 0 then fixed(frames / seconds, 1) else "n/a",
		extra = `frame {percentiles(frameCounts, cfg.FrameBucketsMs, " ms")} · avg {if frames > 0
			then fixed((counters.ftSum or 0) / frames, 1)
			else "n/a"} ms`,
	})
	table.insert(rows, {
		id = "laggy",
		label = "Laggy minutes (p95 frame ≥ " .. cfg.LaggyFrameMs .. " ms)",
		value = counters.laggy or 0,
		display = `{counters.laggy or 0}`,
		extra = if windows > 0 then `{fixed((counters.laggy or 0) / windows * 100, 1)}% of minutes` else "",
	})
	if hbN > 0 then
		local hbCounts = storedHistogram(counters, "hb:", cfg.HeartbeatBucketsMs)
		table.insert(rows, {
			id = "heartbeat",
			label = "Heartbeat time (avg ms)",
			value = (counters.hbSum or 0) / hbN,
			display = fixed((counters.hbSum or 0) / hbN, 2),
			extra = `{percentiles(hbCounts, cfg.HeartbeatBucketsMs, " ms")} · physics {fixed(
				(counters.physSum or 0) / hbN,
				2
			)} ms`,
		})
		local memCounts = storedHistogram(counters, "mem:", cfg.MemoryBucketsMb)
		table.insert(rows, {
			id = "memory",
			label = "Server memory (avg MB)",
			value = (counters.memSum or 0) / hbN,
			display = fixed((counters.memSum or 0) / hbN, 0),
			extra = percentiles(memCounts, cfg.MemoryBucketsMb, " MB"),
		})
		table.insert(rows, {
			id = "network",
			label = "Network send / receive (avg kbps)",
			value = (counters.sendSum or 0) / hbN,
			display = `{fixed((counters.sendSum or 0) / hbN, 1)} / {fixed((counters.recvSum or 0) / hbN, 1)}`,
			extra = `players avg {fixed((counters.plrSum or 0) / hbN, 2)}`,
		})
	end
	if pingN > 0 then
		local pingCounts = storedHistogram(counters, "ping:", cfg.PingBucketsMs)
		table.insert(rows, {
			id = "ping",
			label = "Player ping (avg ms)",
			value = (counters.pingSum or 0) / pingN,
			display = fixed((counters.pingSum or 0) / pingN, 0),
			extra = percentiles(pingCounts, cfg.PingBucketsMs, " ms"),
		})
	end
	return rows
end

--[[ Report rows of per-system Luau time ("sys:<id>" ms) and remote sends ("rx:<name>:n|kb"). ]]
function ServerHealthLogic.systemRows(counters: { [string]: number }): { Row }
	local rows: { Row } = {}
	local seconds = math.max(1, counters.sec or 0)
	for key, ms in counters do
		local system = string.match(key, "^sys:(.+)$")
		if system ~= nil then
			table.insert(rows, {
				id = system,
				label = `{system} (Luau)`,
				value = ms,
				display = `{fixed(ms / seconds, 2)} ms/s`,
				extra = `{fixed(ms / 1000, 1)} s total`,
			})
		end
	end
	for key, kb in counters do
		local name = string.match(key, "^rx:(.+):kb$")
		if name ~= nil then
			table.insert(rows, {
				id = `rx:{name}`,
				label = `{name} (remote)`,
				value = kb,
				display = `{fixed(kb / seconds, 2)} KB/s`,
				extra = `{counters[`rx:{name}:n`] or 0} sends`,
			})
		end
	end
	return rows
end

return table.freeze(ServerHealthLogic)
