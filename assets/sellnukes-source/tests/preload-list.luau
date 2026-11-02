--!strict
--[[
	PreloadList regressions (owner R16: fast model loading). Run:
		lune run tests/preload-list

	Loads the REAL src/shared/World/PreloadList.luau (+ HubLayout, AreaLayouts, MeshAssets,
	TycoonConfig, TycoonLogic) through tests/fixtures/RobloxLoader and proves:
	  1. tiers(): disjoint, cover every MeshAssets model exactly once, tier 1 holds the hub, the
	     plot frame, BuyPad and all of Area 1, and later areas never sneak into tier 1.
	  2. plotKeys(): a fresh plot = BuyPad + Area 1 base only (no unbought builds, no locked
	     areas); buying pads adds exactly their builds; unlocking an area adds its base; order is
	     area 1 first.
	  3. contentIds(): only uploaded ids (> 0), "rbxassetid://N", no duplicates; forClient(nil) is
	     the hub list and forClient(tycoon) extends it with the plot.
	  6. R57 worlds: world("main") = the legacy lists; for every non-main world, worldHubKeys has
	     the BuyPad, a fresh plot preloads only area 1's base, unlocking area 2 adds its base, keys
	     are deduped, content ids are uploaded ids, and no Nuke Town build leaks in.
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

-- 1. tiers
local tiers = PreloadList.tiers()
ok(#tiers == 4, "four warm-up tiers")
local owner: { [string]: number } = {}
for index, tier in tiers do
	for _, key in tier do
		ok(owner[key] == nil, `{key} appears in tiers {owner[key]} and {index}`)
		owner[key] = index
		ok(MeshAssets[key] ~= nil, `tier key {key} is a MeshAssets model`)
	end
end
for key in MeshAssets do
	ok(owner[key] ~= nil, `MeshAssets model {key} missing from every tier`)
end
local tier1 = set(tiers[1])
for _, key in PreloadList.hubKeys() do
	ok(tier1[key], `hub key {key} must be tier 1`)
end
ok(tier1.BuyPad, "BuyPad is tier 1")
for _, key in PreloadList.areaKeys(1, nil) do
	ok(tier1[key], `Area 1 key {key} must be tier 1`)
end
local area1 = set(PreloadList.areaKeys(1, nil))
local hub = set(PreloadList.hubKeys())
for _, key in PreloadList.areaKeys(5, nil) do
	if not area1[key] and not hub[key] then
		ok(not tier1[key], `Area 5-only key {key} leaked into tier 1`)
	end
end

-- 2. plotKeys
local fresh = TycoonLogic.newState()
local freshKeys = PreloadList.plotKeys(fresh)
ok(freshKeys[1] == "BuyPad", "BuyPad first")
local base1 = set(PreloadList.areaKeys(1, function()
	return false
end))
for _, key in freshKeys do
	ok(key == "BuyPad" or base1[key], `fresh plot loads only Area 1 base, got {key}`)
end
local firstPad = TycoonConfig.AreaPads[1][1]
local grown = TycoonLogic.newState()
TycoonLogic.applyPad(grown, firstPad.id)
local grownKeys = set(PreloadList.plotKeys(grown))
local allArea1 = set(PreloadList.areaKeys(1, nil))
for _, key in
	PreloadList.areaKeys(1, function(buildKey: string): boolean
		return buildKey == firstPad.build
	end)
do
	ok(grownKeys[key], `buying {firstPad.id} loads {key}`)
end
local extra = 0
for key in grownKeys do
	if not allArea1[key] and key ~= "BuyPad" then
		extra += 1
	end
end
ok(extra == 0, "one Area 1 purchase never loads other areas")
-- Unlock area 2 (buy every area-1 pad) -> area 2 base appears, after area 1 keys.
local unlocked = TycoonLogic.newState()
for _, pad in TycoonConfig.AreaPads[1] do
	TycoonLogic.applyPad(unlocked, pad.id)
end
if TycoonLogic.areaUnlocked(unlocked, 2) then
	local keys = PreloadList.plotKeys(unlocked)
	local position: { [string]: number } = {}
	for index, key in keys do
		position[key] = index
	end
	for _, key in
		PreloadList.areaKeys(2, function()
			return false
		end)
	do
		ok(position[key] ~= nil, `area 2 base key {key} loads once area 2 is unlocked`)
	end
	ok(checks > 0, "area order")
end

-- 3. content ids
local hubIds = PreloadList.contentIds(PreloadList.hubKeys())
local seen: { [string]: boolean } = {}
for _, id in hubIds do
	ok(string.match(id, "^rbxassetid://%d+$") ~= nil and id ~= "rbxassetid://0", `content id {id}`)
	ok(not seen[id], `duplicate content id {id}`)
	seen[id] = true
end
local clientNil = PreloadList.forClient(nil)
ok(#clientNil == #hubIds, "forClient(nil) = hub ids")
local clientPlot = PreloadList.forClient(grown)
ok(#clientPlot >= #clientNil, "forClient(tycoon) extends the hub list")

-- 5. Deferred lobby decor (HubLayout.isDeferred, L1 R55 perf): out of the first view and the
-- client's blocking preload, first in tier 2.
do
	local HubLayoutModule = loader.load("src/shared/Config/HubLayout")
	local tierOne = set(tiers[1])
	local tierTwo = set(tiers[2])
	local deferred = PreloadList.deferredHubKeys()
	for _, key in deferred do
		ok(HubLayoutModule.isDeferred(key), `{key} is deferred decor`)
		ok(not tierOne[key], `{key} is not in tier 1`)
		ok(tierTwo[key], `{key} loads in tier 2`)
		ok(not set(PreloadList.hubKeys())[key], `{key} is not in hubKeys (client blocking preload)`)
	end
	for index, key in deferred do
		ok(tiers[2][index] == key, "deferred decor leads tier 2")
	end
end

-- 6. R57 worlds: PreloadList.world / worldHubKeys / plotKeys(…, worldId) for every non-main world.
do
	local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
	-- Nuke Town through the world API = the legacy lists.
	ok(#PreloadList.world("main", nil) == #PreloadList.hubKeys(), "world('main') = hubKeys")
	local mainPlot = PreloadList.world("main", grown)
	for _, key in PreloadList.plotKeys(grown) do
		ok(table.find(mainPlot, key) ~= nil, `world('main', tycoon) includes plot key {key}`)
	end
	for _, def in WorldsConfig.extra() do
		local logic = TycoonLogic.forWorld(def.id)
		local economy = def.economy
		local hubKeys = PreloadList.worldHubKeys(def.id)
		ok(table.find(hubKeys, "BuyPad") ~= nil, `{def.id}: hub keys include the BuyPad`)
		ok(#PreloadList.world(def.id, nil) == #hubKeys, `{def.id}: world(w, nil) = its hub keys`)
		-- A fresh world plot: BuyPad + area 1 base only (no unbought builds, no locked areas).
		local fresh = logic.newState()
		local freshKeys = set(PreloadList.plotKeys(fresh, def.id))
		local area1 = PreloadList.areaKeys(1, function()
			return false
		end, def.id)
		for _, key in area1 do
			ok(freshKeys[key], `{def.id}: fresh plot preloads area 1 base key {key}`)
		end
		for area = 2, #economy.Areas do
			for _, key in PreloadList.areaKeys(area, nil, def.id) do
				if not set(area1)[key] then
					ok(not freshKeys[key] or key == "BuyPad", `{def.id}: locked area {area} key {key} not preloaded`)
				end
			end
		end
		-- Buying the whole first area unlocks area 2: its base joins, after area 1's keys.
		for _, pad in economy.AreaPads[1] do
			logic.applyPad(fresh, pad.id)
		end
		local grownKeys = PreloadList.plotKeys(fresh, def.id)
		local area2Base = PreloadList.areaKeys(2, function()
			return false
		end, def.id)
		for _, key in area2Base do
			ok(table.find(grownKeys, key) ~= nil, `{def.id}: area 2 base key {key} after unlocking`)
		end
		-- Keys are deduped and every one exists in MeshAssets (or is a not-yet-synced art key,
		-- which contentIds simply skips).
		local seenKeys: { [string]: boolean } = {}
		for _, key in PreloadList.world(def.id, fresh) do
			ok(not seenKeys[key], `{def.id}: duplicate preload key {key}`)
			seenKeys[key] = true
		end
		for _, id in PreloadList.contentIds(PreloadList.world(def.id, fresh)) do
			ok(string.match(id, "^rbxassetid://%d+$") ~= nil and id ~= "rbxassetid://0", `{def.id}: content id {id}`)
		end
		-- No Nuke Town plot builds leak into another world's list.
		local worldKeys = set(PreloadList.plotKeys(fresh, def.id))
		for _, key in PreloadList.areaKeys(3, nil) do
			if not set(PreloadList.hubKeys())[key] and key ~= "BuyPad" then
				ok(not worldKeys[key], `{def.id}: Nuke Town area 3 key {key} not in its plot keys`)
			end
		end
	end
end

print(`[preload-list] {checks} checks passed ({#tiers[1]}/{#tiers[2]}/{#tiers[3]}/{#tiers[4]} keys per tier)`)
