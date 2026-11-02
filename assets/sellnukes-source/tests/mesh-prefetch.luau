--!strict
--[[
	MeshLibrary.prefetch queueing regressions (owner R16: fast model loading). Run:
		lune run tests/mesh-prefetch

	Loads the REAL src/server/World/MeshLibrary.luau with a fake AssetService whose
	CreateMeshPartAsync parks the calling thread until the test "finishes" that mesh, so the exact
	order in which template requests START is observable. Fake MeshAssets: single-piece models
	K1..K(3N) with MeshId = index, where N = MeshLibrary.stats().maxConcurrent (so the test follows
	any MAX_CONCURRENT tuning). Proves:
	  1. prefetch never yields, returns the number of newly queued requests, starts at most N at once
	     and skips unknown / not-uploaded keys.
	  2. Queue order = PlotBuilder.restore's plan: area 1 (Hub) first, then the current area (Hub),
	     then the areas in between (Plot); a later, more urgent request (Now) jumps the queue.
	  3. Dedupe: re-prefetching queued / in-flight / cached ids requests nothing again; ids shared
	     between models are requested once.
	  4. preload() after prefetch waits on the queued requests instead of duplicating them and
	     returns once its own ids are loaded.
	  5. LEGACY benchmark mode: prefetch is a no-op.
	  6. Player-first load order: Plot / Hub prefetches before WorldReady mark first-view keys
	     (Background ones do not); holdWorldReady counts per reason and each release is idempotent.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(label, 2)
	end
	checks += 1
end

-- Priorities (mirrors MeshLibrary.Priority; read back from the module below).
local MODEL_COUNT = 200

-- Fake MeshAssets: K<i> = one piece with MeshId i. "Shared" reuses K1's id; "Pending" has id 0.
local fakeAssets: { [string]: any } = {}
for i = 1, MODEL_COUNT do
	fakeAssets[`K{i}`] = { order = { "P" }, pieces = { P = { id = i } } }
end
fakeAssets.Shared = { order = { "A", "B" }, pieces = { A = { id = 1 }, B = { id = 2 } } }
fakeAssets.Pending = { order = { "P" }, pieces = { P = { id = 0 } } }

--[[
	Loads a fresh MeshLibrary (own queue + caches) against the fake services.
	@return library, started (MeshIds in request-start order), finish(id) (completes one request)
]]
local function loadLibrary(legacy: boolean): (any, { number }, (number) -> ())
	local started: { number } = {}
	local parked: { [number]: thread } = {}
	local AssetService = {
		CreateMeshPartAsync = function(_self: any, content: any, _options: any): any
			table.insert(started, content)
			parked[content] = coroutine.running()
			-- Parks this request until finish(id); the resumed value is the "MeshPart".
			return coroutine.yield()
		end,
	}
	local function finish(id: number)
		local thread = parked[id]
		assert(thread ~= nil, `mesh {id} is not in flight`)
		parked[id] = nil
		task.spawn(thread, { Name = `Mesh{id}` })
	end
	local modules: { [string]: any } = {
		MeshAssets = fakeAssets,
		WorldFxConfig = {},
		MeshPlacement = {},
		PreloadList = {},
		WorldMaterials = {
			ensure = function() end,
		},
	}
	local services: { [string]: any } = {
		AssetService = AssetService,
		CollectionService = {},
		ReplicatedStorage = {
			Shared = {
				Config = { MeshAssets = "MeshAssets", WorldFxConfig = "WorldFxConfig" },
				World = { MeshPlacement = "MeshPlacement", PreloadList = "PreloadList" },
			},
		},
		-- Not a running server: the boot warm-up must not start (this test drives the queue alone).
		RunService = {
			IsServer = function()
				return true
			end,
			IsRunning = function()
				return false
			end,
		},
		Workspace = {},
	}
	local env: { [string]: any } = table.clone(roblox) :: any
	env.game = {
		GetService = function(_self: any, name: string): any
			return assert(services[name], `no stub for service {name}`)
		end,
	}
	env.script = {
		Parent = { WorldMaterials = "WorldMaterials" },
		GetAttribute = function(_self: any, name: string): any
			return if name == "LegacyLoading" then legacy else nil
		end,
	}
	env.require = function(target: any): any
		return assert(modules[target], `unexpected require {tostring(target)}`)
	end
	env.Content = {
		fromAssetId = function(id: number): number
			return id
		end,
	}
	env.task = task
	env.warn = function() end
	local chunk = luau.load(fs.readFile("src/server/World/MeshLibrary.luau"), {
		debugName = "MeshLibrary",
		environment = env,
		injectGlobals = true,
	})
	return chunk(), started, finish
end

-- Keys K<from>..K<to>.
local function keys(from: number, to: number): { string }
	local out: { string } = {}
	for i = from, to do
		table.insert(out, `K{i}`)
	end
	return out
end

-- Runs `fn` in a coroutine; true when it returned without yielding.
local function returnsWithoutYield(fn: () -> ()): boolean
	local returned = false
	local thread = coroutine.create(function()
		fn()
		returned = true
	end)
	local resumed, message = coroutine.resume(thread)
	assert(resumed, message)
	return returned
end

-- 1-2. Restore plan: area 1 (Hub), current area (Hub), areas in between (Plot).
local MeshLibrary, started, finish = loadLibrary(false)
local Priority = MeshLibrary.Priority
local N = MeshLibrary.stats().maxConcurrent
ok(N >= 1 and 3 * N + 1 <= MODEL_COUNT, "fake model count covers three full slot batches")
local areaOne = keys(1, N) -- K1..KN
local between = keys(N + 1, 2 * N) -- K(N+1)..K(2N)
local current = keys(2 * N + 1, 3 * N) -- K(2N+1)..K(3N)
local queuedCounts: { number } = {}
ok(
	returnsWithoutYield(function()
		queuedCounts[1] = MeshLibrary.prefetch(areaOne, Priority.Hub)
		queuedCounts[2] = MeshLibrary.prefetch(current, Priority.Hub)
		queuedCounts[3] = MeshLibrary.prefetch(between, Priority.Plot)
	end),
	"prefetch never yields the caller"
)
ok(queuedCounts[1] == N and queuedCounts[2] == N and queuedCounts[3] == N, "prefetch returns newly queued requests")
ok(#started == N, `only MAX_CONCURRENT requests start at once ({#started} of {N})`)
for i = 1, N do
	ok(started[i] == i, "area 1 requests start first, in key order")
end
local stats = MeshLibrary.stats()
ok(stats.inFlight == N and stats.queued == 2 * N, "the rest wait in the slot queue")

-- 3. Dedupe: in flight, queued, shared ids, unknown and not-uploaded keys request nothing new.
ok(MeshLibrary.prefetch(areaOne, Priority.Hub) == 0, "in-flight ids are not requested again")
ok(MeshLibrary.prefetch(between, Priority.Plot) == 0, "queued ids are not requested again")
ok(MeshLibrary.prefetch({ "Shared", "Pending", "Nope" }, Priority.Plot) == 0, "shared / pending / unknown keys skipped")
ok(MeshLibrary.stats().queued == 2 * N and #started == N, "no duplicate requests were queued or started")

-- A more urgent caller (a spawn someone waits on) promotes a queued id past both Hub groups.
local promoted = 2 * N -- last key of the "between" group (Plot)
ok(MeshLibrary.prefetch({ `K{promoted}` }, Priority.Now) == 0, "promoting is not a new request")

-- 4. preload() of the current area while its requests are queued: waits, requests nothing new.
local preloadReady, preloadFailed = -1, -1
local preloadThread = coroutine.create(function()
	preloadReady, preloadFailed = MeshLibrary.preload(current, Priority.Plot)
end)
coroutine.resume(preloadThread)
ok(coroutine.status(preloadThread) == "suspended", "preload waits for the queued current-area meshes")
ok(#started == N and MeshLibrary.stats().queued == 2 * N, "preload reuses the prefetched requests")

-- Finish requests in start order; every finish hands its slot to the most urgent waiter.
local cursor = 1
while cursor <= #started do
	finish(started[cursor])
	cursor += 1
end
ok(#started == 3 * N, `every queued request ran exactly once ({#started})`)
ok(started[N + 1] == promoted, "the promoted (Now) request runs before the remaining Hub work")
for i = 1, N do
	ok(started[N + 1 + i] == 2 * N + i, "then the current area (Hub), in key order")
end
for i = 1, N - 1 do
	ok(started[2 * N + 1 + i] == N + i, "then the areas in between (Plot), in key order")
end
ok(preloadReady == N and preloadFailed == 0, "preload returned once its meshes loaded")
stats = MeshLibrary.stats()
ok(stats.templates == 3 * N and stats.inFlight == 0 and stats.queued == 0, "queue drained, every template cached")
ok(MeshLibrary.prefetch(keys(1, 3 * N), Priority.Hub) == 0 and #started == 3 * N, "cached ids are never re-requested")
ok(MeshLibrary.prefetch({ "Shared" }, Priority.Hub) == 0, "shared ids resolve to cached templates")

-- 5. LEGACY benchmark mode (pre-R16 loader): no prefetch at all.
local Legacy, legacyStarted = loadLibrary(true)
ok(Legacy.stats().legacy == true, "legacy loader loaded")
ok(Legacy.prefetch(keys(1, 10), Legacy.Priority.Hub) == 0 and #legacyStarted == 0, "legacy prefetch is a no-op")

-- 6. Player-first load order (owner R16 follow-up): first-view registration + WorldReady holds.
do
	local Fresh = loadLibrary(false)
	local P = Fresh.Priority
	Fresh.prefetch(keys(1, 4), P.Background)
	ok(Fresh.stats().firstViewKeys == 0, "background prefetch is not first-view content")
	Fresh.prefetch(keys(5, 8), P.Plot)
	ok(Fresh.stats().firstViewKeys == 4, "a Plot-priority prefetch before WorldReady marks first-view keys")
	Fresh.prefetch(keys(9, 10), P.Hub)
	ok(Fresh.stats().firstViewKeys == 6, "Hub-priority keys are first view too")
	ok(Fresh.stats().worldReady == false, "boot phase until WorldReady is published")
	local releaseA = Fresh.holdWorldReady(Fresh.HubHold)
	local releaseB = Fresh.holdWorldReady(Fresh.HubHold)
	ok(Fresh.stats().holds[Fresh.HubHold] == 2, "holds count per reason")
	releaseA()
	releaseA() -- idempotent
	ok(Fresh.stats().holds[Fresh.HubHold] == 1, "a release frees exactly its own hold")
	releaseB()
	ok(next(Fresh.stats().holds) == nil, "every hold released")
	ok(type(Fresh.stats().retries) == "number" and type(Fresh.stats().slowest) == "table", "diagnostics present")
end

print(`[mesh-prefetch] {checks} checks passed (N = {N} slots)`)
