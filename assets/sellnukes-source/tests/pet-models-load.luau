--!strict
--[[
	PetModels template loading (src/client/Pets/PetModels.luau; EH1 hatch QA: the first hatch of a
	session showed missing shards because the 13 EggShards pieces loaded one after another). Run:
		lune run tests/pet-models-load

	Loads the REAL PetModels (and the real MeshAssets) with a fake AssetService whose
	CreateMeshPartAsync parks the calling thread until the test finishes that MeshId, so the
	number of downloads in flight and their start order are observable. Proves:
	  1. Bounded parallelism: prefetch never yields, queues every unique id of a key and starts at
	     most maxInFlight downloads at once; finishing one starts the next.
	  2. One shared load per key: re-requesting / re-prefetching / waitReady never fetch an id twice;
	     concurrent waitReady callers all resume on the same load; Ready(key) fires exactly once.
	  3. Priority: a request for a model shown now starts before queued prefetches.
	  4. Ids shared between keys are fetched once; a key whose ids are all cached settles at once
	     (ready, no Ready event, no fetch).
	  5. Failure: a failed id makes its key "failed" (waiters get false, no Ready) and is not
	     re-fetched within the retry window; unknown / not-uploaded keys queue nothing.
	  6. waitReady with a timeout returns false on time and the load still completes afterwards.
]]

local Loader = require("./fixtures/RobloxLoader")
local task = require("@lune/task")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- Fake AssetService: every CreateMeshPartAsync parks until finish(id, ok).
local started: { number } = {}
local parked: { [number]: thread } = {}
local fetchCount: { [number]: number } = {}
local AssetService = {
	CreateMeshPartAsync = function(_self: any, content: any, _options: any): any
		local id = tonumber(string.match(tostring(content), "rbxassetid://(%d+)")) :: number
		table.insert(started, id)
		fetchCount[id] = (fetchCount[id] or 0) + 1
		parked[id] = coroutine.running()
		local result = coroutine.yield()
		if result == nil then
			error("asset failed")
		end
		return result
	end,
}

-- Completes the parked request of `id` (ok = false → it errors).
local function finish(id: number, ok: boolean?)
	local thread = parked[id]
	assert(thread ~= nil, `mesh {id} is not in flight`)
	parked[id] = nil
	task.spawn(thread, if ok == false then nil else { Name = `Mesh{id}` })
end

local function inFlightIds(): { number }
	local out: { number } = {}
	for id in parked do
		table.insert(out, id)
	end
	table.sort(out)
	return out
end

local loader = Loader.new({ AssetService = AssetService })
local PetModels = loader.load("src/client/Pets/PetModels")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")

local readyCount: { [string]: number } = {}
PetModels.Ready:Connect(function(key: string)
	readyCount[key] = (readyCount[key] or 0) + 1
end)

-- Unique uploaded ids of a key.
local function idsOf(key: string): { number }
	local seen: { [number]: boolean } = {}
	local out: { number } = {}
	for _, piece in MeshAssets[key].pieces do
		if not seen[piece.id] then
			seen[piece.id] = true
			table.insert(out, piece.id)
		end
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
	coroutine.resume(thread)
	return returned
end

local MAX = PetModels.loadStats().maxInFlight
check(MAX >= 4 and MAX <= 16, `bounded concurrency ({MAX})`)

-- 1. Bounded parallel prefetch of the 13-piece EggShards set.
local shards = idsOf("EggShards")
check(#shards == 13, "EggShards has 13 uploaded pieces")
local queued = 0
check(returnsWithoutYield(function()
	queued = PetModels.prefetch({ "EggShards" })
end), "prefetch never yields")
check(queued == #shards, `prefetch queued every unique id ({queued})`)
check(#started == MAX, `exactly maxInFlight downloads start at once ({#started})`)
check(PetModels.loadStats().inFlight == MAX, "stats: in flight")
check(PetModels.loadStats().queued == #shards - MAX, "stats: queued")
check(not PetModels.isMeshReady("EggShards"), "not ready while loading")

-- 2. Joining: no duplicate fetches; two concurrent waiters on the same load.
check(PetModels.prefetch({ "EggShards", "EggShards" }) == 0, "re-prefetch queues nothing")
PetModels.request("EggShards")
check(#started == MAX, "request joins the in-flight load")
local results: { boolean } = {}
for index = 1, 2 do
	task.spawn(function()
		results[index] = PetModels.waitReady("EggShards")
	end)
end
check(results[1] == nil and results[2] == nil, "waiters yield while loading")
-- Finishing one starts the next queued id (still at most MAX in flight).
local first = inFlightIds()[1]
finish(first)
check(#started == MAX + 1, "a finished download starts the next queued one")
check(#inFlightIds() == MAX, "still at most maxInFlight in flight")
-- Finish the rest in waves.
while #inFlightIds() > 0 do
	for _, id in inFlightIds() do
		finish(id)
	end
end
check(#started == #shards, "every id fetched exactly once")
for _, id in shards do
	check(fetchCount[id] == 1, `id {id} fetched once`)
end
check(results[1] == true and results[2] == true, "both waiters resumed with true")
check(readyCount.EggShards == 1, "Ready fired exactly once")
check(PetModels.isMeshReady("EggShards"), "ready")
check(PetModels.waitReady("EggShards") == true, "waitReady on a loaded key returns at once")
check(PetModels.prefetch({ "EggShards" }) == 0 and #started == #shards, "loaded key never refetches")
check(PetModels.loadStats().cached >= #shards, "templates cached")

-- 3. Priority: a request shown now starts before queued prefetches.
local before = #started
local slowKeys = { "FusionPhoenix", "CoreDragon", "NovaUnicorn" }
local prefetched = PetModels.prefetch(slowKeys)
check(prefetched > MAX, `several keys queued ({prefetched})`)
check(#started - before == MAX, "prefetch fills the slots")
PetModels.request("IonJelly")
local jelly = idsOf("IonJelly")
local jellySet: { [number]: boolean } = {}
for _, id in jelly do
	jellySet[id] = true
end
-- Free the slots one at a time: the next starts must be the jelly's ids.
for _ = 1, #jelly do
	finish(inFlightIds()[1])
	check(jellySet[started[#started]] == true, "urgent request jumps the prefetch queue")
end
local jellyReady = false
task.spawn(function()
	jellyReady = PetModels.waitReady("IonJelly")
end)
while #inFlightIds() > 0 do
	for _, id in inFlightIds() do
		finish(id)
	end
end
check(jellyReady and PetModels.isMeshReady("IonJelly"), "urgent key loaded")
for _, key in slowKeys do
	check(PetModels.isMeshReady(key) and readyCount[key] == 1, `{key} loaded once`)
end

-- 4. A key whose ids are all cached settles at once: no fetch, no Ready event.
do
	local fake = "PetModelsTestAlias"
	MeshAssets[fake] = { pivot = "", pieces = { A = { id = shards[1] }, B = { id = shards[2] } } }
	local count = #started
	PetModels.request(fake)
	check(#started == count and PetModels.isMeshReady(fake), "cached ids: ready at once, nothing fetched")
	check(readyCount[fake] == nil, "no Ready for a key that was ready on first ask")
	MeshAssets[fake] = nil
end

-- 5. Failure + unknown / not uploaded keys.
do
	local count = #started
	check(PetModels.prefetch({ "NoSuchKey" }) == 0 and #started == count, "unknown key queues nothing")
	MeshAssets.PetModelsTestPending = { pivot = "", pieces = { P = { id = 0 } } }
	check(PetModels.prefetch({ "PetModelsTestPending" }) == 0, "not-uploaded key queues nothing")
	MeshAssets.PetModelsTestPending = nil
	local glow = idsOf("GlowSlime")
	PetModels.request("GlowSlime")
	local verdict: boolean? = nil
	task.spawn(function()
		verdict = PetModels.waitReady("GlowSlime")
	end)
	finish(glow[1], false)
	while #inFlightIds() > 0 do
		for _, id in inFlightIds() do
			finish(id)
		end
	end
	check(verdict == false, "a failed piece fails the key's waiters")
	check(not PetModels.isMeshReady("GlowSlime") and readyCount.GlowSlime == nil, "failed key: no Ready")
	local count2 = #started
	PetModels.request("GlowSlime")
	check(#started == count2, "no refetch inside the retry window")
	check(#loader.warnings >= 1, "the failure is warned once")
end

-- 6. waitReady timeout: false on time, the load still completes later.
do
	local fox = idsOf("FissionFox")
	local verdict: boolean? = nil
	task.spawn(function()
		verdict = PetModels.waitReady("FissionFox", 0.05)
	end)
	check(verdict == nil, "waiting")
	task.wait(0.1)
	check(verdict == false, "timed out → false")
	while #inFlightIds() > 0 do
		for _, id in inFlightIds() do
			finish(id)
		end
	end
	check(PetModels.isMeshReady("FissionFox") and readyCount.FissionFox == 1, "load completed after the timeout")
	check(#fox > 0, "fox has pieces")
end

print(`[pet-models-load] {checks} checks passed (max {MAX} in flight)`)
