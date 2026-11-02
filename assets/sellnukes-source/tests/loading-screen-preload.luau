--!strict
--[[
	Loading screen preload split regressions (owner R122 "fast first minute", spec 2026-11-01
	§2.1). Run:
		lune run tests/loading-screen-preload

	Loads the REAL src/shared/World/PreloadList.luau (+ HubLayout, AreaLayouts, MeshAssets,
	TycoonConfig, TycoonLogic) through tests/fixtures/RobloxLoader and proves:
	  1. criticalKeys(nil): the plot frame, the locked slot, BuyPad and area 1's base ONLY (no hub
	     models, no builds) — what the bar waits for before the profile arrives.
	  2. criticalKeys(fresh): + the first next pad's build (the first purchase flies in without a
	     download); never another unbought build; criticalKeys(nil) is a subset.
	  3. a grown plot: every bought build is critical, the current next pads' builds are critical,
	     later unbought builds of the area are DEFERRED, and locked areas never become critical.
	  4. deferredKeys(t): disjoint from criticalKeys(t), carries every shared hub model + the lobby
	     decor, the rest of the unlocked areas and only the NEXT locked area's base; the union of
	     both = the legacy forClient list's keys (+ upcoming builds / next base), nothing is lost.
	     Upcoming purchases lead the deferred list (they are never instanced before purchase).
	  5. forClientCritical / forClientDeferred: valid uploaded ids, no duplicates, disjoint, every
	     legacy forClient id still preloaded; a new player's critical list is under half of the
	     legacy forClient(fresh) list.
]]

local Loader = require("./fixtures/RobloxLoader")

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(label, 2)
	end
	checks += 1
end

local loader = Loader.new()
local PreloadList = loader.load("src/shared/World/PreloadList")
local HubLayout = loader.load("src/shared/Config/HubLayout")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local TycoonLogic = loader.load("src/shared/Tycoon/TycoonLogic")

local function set(list: { string }): { [string]: boolean }
	local out = {}
	for _, key in list do
		out[key] = true
	end
	return out
end

local function noBuilds(): boolean
	return false
end

-- Keys of one build group of a Nuke Town area layout (same lookup as PreloadList).
local function buildKeysOf(area: number, buildKey: string): { string }
	return PreloadList.areaKeys(area, function(key: string): boolean
		return key == buildKey
	end)
end

-- The plot frame + locked slot + BuyPad keys (every plot shows them).
local frameKeys: { [string]: boolean } = { BuyPad = true }
for _, part in { HubLayout.plotFrame, HubLayout.lockedSlot } do
	for _, entry in if type(part) == "table" and type(part.models) == "table" then part.models else {} do
		if MeshAssets[entry.key] ~= nil then
			frameKeys[entry.key] = true
		end
	end
end
local area1Base = set(PreloadList.areaKeys(1, noBuilds))

-- 1. No profile yet: frame + locked slot + BuyPad + area 1 base only.
local criticalNil = PreloadList.criticalKeys(nil)
local criticalNilSet = set(criticalNil)
for _, key in criticalNil do
	ok(frameKeys[key] or area1Base[key], `criticalKeys(nil): only frame / BuyPad / area 1 base, got {key}`)
end
for key in frameKeys do
	ok(criticalNilSet[key], `criticalKeys(nil) includes {key}`)
end
for key in area1Base do
	ok(criticalNilSet[key], `criticalKeys(nil) includes area 1 base key {key}`)
end
local hubShared: { [string]: boolean } = {}
for _, key in PreloadList.hubKeys() do
	if not frameKeys[key] then
		hubShared[key] = true
		ok(not criticalNilSet[key] or area1Base[key], `shared hub model {key} is not critical`)
	end
end

-- 2. A fresh plot: + the first next pad's build, nothing else unbought.
local fresh = TycoonLogic.newState()
local firstPad = TycoonLogic.nextPads(fresh)[1]
ok(firstPad ~= nil and firstPad.id == TycoonConfig.AreaPads[1][1].id, "a fresh plot's next pad = area 1's first pad")
local criticalFresh = set(PreloadList.criticalKeys(fresh))
for key in criticalNilSet do
	ok(criticalFresh[key], `criticalKeys(nil) ⊆ criticalKeys(fresh): {key}`)
end
for _, key in buildKeysOf(1, firstPad.build) do
	ok(criticalFresh[key], `the first pad's build {key} is critical`)
end
local firstBuild = set(buildKeysOf(1, firstPad.build))
for key in criticalFresh do
	ok(frameKeys[key] or area1Base[key] or firstBuild[key], `fresh critical key {key} is frame / base / next build`)
end

-- 3. A grown plot (half of area 1 bought): bought + next builds critical, the rest deferred.
local grown = TycoonLogic.newState()
local area1Pads = TycoonConfig.AreaPads[1]
local half = math.max(1, math.floor(#area1Pads / 2))
for index = 1, half do
	TycoonLogic.applyPad(grown, area1Pads[index].id)
end
local criticalGrown = set(PreloadList.criticalKeys(grown))
local deferredGrown = PreloadList.deferredKeys(grown)
local deferredGrownSet = set(deferredGrown)
for index = 1, half do
	for _, key in buildKeysOf(1, area1Pads[index].build) do
		ok(criticalGrown[key], `bought build {key} is critical`)
	end
end
local nextBuilds: { [string]: boolean } = {}
for _, pad in TycoonLogic.nextPads(grown) do
	for _, key in buildKeysOf(pad.area, pad.build) do
		nextBuilds[key] = true
		ok(criticalGrown[key], `next pad build {key} is critical`)
	end
end
local upcoming = 0
for index = half + 1, #area1Pads do
	for _, key in buildKeysOf(1, area1Pads[index].build) do
		if not criticalGrown[key] then
			upcoming += 1
			ok(deferredGrownSet[key], `upcoming build {key} is deferred`)
		end
	end
end
ok(upcoming > 0, "a half-bought area has upcoming deferred builds")
-- Upcoming purchases lead the deferred list (never instanced before they are bought, so only the
-- warm-up makes their fly-in download-free); the replicated hub follows.
local upcomingKeys: { [string]: boolean } = {}
for index = half + 1, #area1Pads do
	for _, key in buildKeysOf(1, area1Pads[index].build) do
		if not criticalGrown[key] and not area1Base[key] then
			upcomingKeys[key] = true
		end
	end
end
ok(upcomingKeys[deferredGrown[1]] == true, `the deferred list starts with an upcoming build ({deferredGrown[1]})`)
for area = 2, #TycoonConfig.Areas do
	for _, key in PreloadList.areaKeys(area, nil) do
		if not area1Base[key] and not frameKeys[key] and not set(PreloadList.areaKeys(1, nil))[key] then
			ok(not criticalGrown[key], `locked area {area} key {key} is never critical`)
		end
	end
end

-- 4. deferredKeys: disjoint, hub + decor + upcoming + next locked base only.
for _, tycoon in { nil, fresh, grown } :: { any } do
	local critical = set(PreloadList.criticalKeys(tycoon))
	local deferred = PreloadList.deferredKeys(tycoon)
	local seenKeys: { [string]: boolean } = {}
	for _, key in deferred do
		ok(not critical[key], `deferred key {key} is not critical`)
		ok(not seenKeys[key], `deferred key {key} appears once`)
		seenKeys[key] = true
		ok(MeshAssets[key] ~= nil, `deferred key {key} is a MeshAssets model`)
	end
	for key in hubShared do
		ok(critical[key] or seenKeys[key], `shared hub model {key} is preloaded (critical or deferred)`)
	end
	for _, key in PreloadList.deferredHubKeys() do
		ok(critical[key] or seenKeys[key], `lobby decor {key} is deferred`)
	end
	-- Nothing the legacy single list preloaded is lost.
	for _, key in PreloadList.hubKeys() do
		ok(critical[key] or seenKeys[key], `legacy hub key {key} still preloaded`)
	end
	if tycoon ~= nil then
		for _, key in PreloadList.plotKeys(tycoon) do
			ok(critical[key], `plot key {key} is critical`)
		end
	end
end
-- The grown plot (area 2 locked) defers area 2's base and nothing of areas 3+.
local area2Base = set(PreloadList.areaKeys(2, noBuilds))
for key in area2Base do
	ok(deferredGrownSet[key] or criticalGrown[key] or hubShared[key], `next locked area base {key} is deferred`)
end
local earlier: { [string]: boolean } = {}
for _, key in PreloadList.hubKeys() do
	earlier[key] = true
end
for _, key in PreloadList.deferredHubKeys() do
	earlier[key] = true
end
for _, key in PreloadList.areaKeys(1, nil) do
	earlier[key] = true
end
for key in area2Base do
	earlier[key] = true
end
for _, key in deferredGrown do
	ok(earlier[key], `deferred key {key} is hub / decor / area 1 / area 2 base (nothing from areas 3+)`)
end

-- 5. Content ids: valid, deduped, disjoint, and the new player's critical list is small.
for _, tycoon in { nil, fresh, grown } :: { any } do
	local criticalIds = PreloadList.forClientCritical(tycoon)
	local deferredIds = PreloadList.forClientDeferred(tycoon)
	local seenIds: { [string]: string } = {}
	for _, id in criticalIds do
		ok(string.match(id, "^rbxassetid://%d+$") ~= nil and id ~= "rbxassetid://0", `critical content id {id}`)
		ok(seenIds[id] == nil, `critical id {id} once`)
		seenIds[id] = "critical"
	end
	for _, id in deferredIds do
		ok(string.match(id, "^rbxassetid://%d+$") ~= nil and id ~= "rbxassetid://0", `deferred content id {id}`)
		ok(seenIds[id] == nil, `deferred id {id} not critical / not repeated ({seenIds[id]})`)
		seenIds[id] = "deferred"
	end
	-- Every id of the legacy list is still preloaded by one of the two parts.
	for _, id in PreloadList.forClient(tycoon) do
		ok(seenIds[id] ~= nil, `legacy forClient id {id} is still preloaded`)
	end
end
-- The legacy single list for a new player (profile known) = the whole hub + area 1's base.
local legacyNew = #PreloadList.forClient(fresh)
local criticalNew = #PreloadList.forClientCritical(fresh)
ok(criticalNew > 0, "a new player has a critical list")
ok(
	criticalNew * 2 < legacyNew,
	`a new player's critical list ({criticalNew}) is under half the legacy list ({legacyNew})`
)

print(
	`[loading-screen-preload] {checks} checks passed (new player: {criticalNew} critical / {#PreloadList.forClientDeferred(
		fresh
	)} deferred ids; legacy forClient(fresh) {legacyNew})`
)
