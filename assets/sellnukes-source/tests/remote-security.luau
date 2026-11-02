--!strict
--[[
	Remote-surface security regressions (pre-publish audit 2026-10-30, docs/security-audit.md). Run:
		lune run tests/remote-security

	Proves on the shipped modules:
	  1. Remotes.fromPresentPlayer (every server handler connects through Remotes.onServerEvent):
	     a player still in the game reaches the handler with every argument intact (incl. nil
	     holes); a player who already left (Parent ~= Players) never does, so a late packet can't
	     re-create per-player state after the PlayerRemoving cleanup.
	  2. ProfileLogic.restoreInPlace (MonetizationService's receipt rollback): a handler that
	     mutates and then fails leaves the profile EXACTLY as before — values, added / removed
	     keys, array lengths — while every sub-table keeps its identity (services hold references
	     to profile.tycoon / profile.pets); the snapshot stays reusable.
	  3. Malformed-argument fuzz over every pure validator / rule a remote handler feeds raw client
	     data into (Validate.*, CodesConfig.normalize, ProfileLogic.applySetting, Validate.configKey
	     on RebirthConfig.Shop, PetLogic.planHatch, CrateLogic.planOpen, WheelLogic.consume):
	     NaN, ±inf, huge / fractional / negative numbers, huge strings, control characters, invalid
	     UTF-8, tables (with metatables, cycles, huge arrays), booleans, nil — never throws, never
	     accepts junk, never mutates a profile on a refusal. Deterministic random fuzz on top.
	  4. Owner R57 World 2 remotes: TravelWorld(worldId, target, index?) through
	     Validate.travelRequest, Rebirth(worldId?) through Validate.worldIdOrMain and
	     RebirthShopBuy(key, worldId?) through Validate.rebirthShopBuy — hostile values in EVERY
	     argument position never throw, never pass, and a junk world is never read as "main";
	     world currency math refuses junk amounts without touching the profile.
]]

local Loader = require("./fixtures/RobloxLoader")
local Random = Loader.Random

-- A Players stub that is a real table identity the guard compares Parent against.
local PlayersStub = {
	GetPlayers = function()
		return {}
	end,
}
local loader = Loader.new({ Players = PlayersStub })
local Remotes = loader.load("src/shared/Net/Remotes")
local Validate = loader.load("src/shared/Net/Validate")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local CodesConfig = loader.load("src/shared/Config/CodesConfig")
local RebirthConfig = loader.load("src/shared/Config/RebirthConfig")
local PetLogic = loader.load("src/server/Pets/PetLogic")
local PetState = loader.load("src/server/Pets/PetState")
local CrateLogic = loader.load("src/server/Pets/CrateLogic")
local WheelLogic = loader.load("src/server/Retention/WheelLogic")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b or (a ~= a and b ~= b)
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- 1. Present-player guard ------------------------------------------------------------------------
do
	local calls: { { any } } = {}
	local guarded = Remotes.fromPresentPlayer(function(player: any, ...: any)
		table.insert(calls, { player, table.pack(...) })
	end)
	local present = { Name = "here", Parent = PlayersStub }
	local gone = { Name = "gone", Parent = nil }
	local elsewhere = { Name = "moved", Parent = {} }
	guarded(present :: any, 1, nil, "x")
	check(#calls == 1 and calls[1][1] == present, "present player reaches the handler")
	local args = calls[1][2]
	check(args.n == 3 and args[1] == 1 and args[2] == nil and args[3] == "x", "arguments (and nil holes) intact")
	guarded(gone :: any, "late packet")
	guarded(elsewhere :: any, "late packet")
	check(#calls == 1, "a departed player never reaches the handler")
	present.Parent = nil -- left between two packets
	guarded(present :: any)
	check(#calls == 1, "leaving mid-stream stops the next packet")
end

-- 2. Receipt rollback (takeSnapshot / restoreSnapshot) ----------------------------------------------------------
do
	local profile = ProfileLogic.defaultProfile() :: any
	PetState.pets(profile)
	profile.cash = 1234
	profile.spin.paid = 3
	table.insert(profile.pets.equipped, "1")
	profile.pets.owned["1"] = { id = "glow_slime" }
	local tycoonRef, petsRef, spinRef = profile.tycoon, profile.pets, profile.spin
	local before = ProfileLogic.deepCopy(profile)
	local snapshot = ProfileLogic.takeSnapshot(profile)

	-- A "handler" that mutates a lot, then fails half-way.
	local function badHandler(p: any)
		p.cash += 999
		p.gems = 77
		p.spin.paid += 10
		p.spin.bonus = 5
		p.pets.owned["2"] = { id = "atom_pup" }
		table.insert(p.pets.equipped, "2")
		p.pets.equipped[1] = nil -- hole
		p.newField = { nested = true }
		p.tycoon.area = 9
		p.tycoon = { replaced = true } -- even a replaced sub-table is put back by value
		error("handler blew up")
	end
	local ok = pcall(badHandler, profile)
	check(not ok, "handler failed")
	ProfileLogic.restoreSnapshot(snapshot)
	check(deepEqual(profile, before), "profile exactly as before")
	check(profile.pets == petsRef and profile.spin == spinRef, "sub-table identities kept")
	check(profile.tycoon == tycoonRef, "a REPLACED sub-table gets its original identity back")
	check(tycoonRef.area == before.tycoon.area, "the original tycoon table was restored too")
	check(profile.newField == nil and #profile.pets.equipped == 1, "added keys / array growth removed")
	-- The snapshot is reusable (restore copies in, never aliases).
	profile.cash = -1
	ProfileLogic.restoreSnapshot(snapshot)
	profile.spin.paid = 42
	check(snapshot.copy.spin.paid == 3, "snapshot never aliased into the live profile")
	ProfileLogic.restoreSnapshot(snapshot)
	check(deepEqual(profile, before), "second restore from the same snapshot")
end

-- 3. Malformed-argument fuzz ----------------------------------------------------------------------
local cyclic: any = {}
cyclic.self = cyclic
local huge: { number } = {}
for index = 1, 5000 do
	huge[index] = index
end
local JUNK: { any } = {
	0 / 0,
	math.huge,
	-math.huge,
	-1,
	1.5,
	2 ^ 53 + 2,
	1e308,
	"",
	" ",
	string.rep("A", 10_000),
	"\0\1\2",
	"bad\255utf8",
	"\u{202E}reversed",
	"<script>",
	"garage_egg\n",
	true,
	false,
	{},
	{ 1, 2, 3 },
	{ x = 1 },
	setmetatable({}, {
		__index = function()
			error("metatable touched")
		end,
	}),
	cyclic,
	huge,
	function() end,
}
-- `nil` is fuzzed separately (it can't live in an array).

-- Calls fn(junk) for every junk value and nil; asserts it never throws and `accepted` says no.
local function fuzz(label: string, fn: (any) -> any, accepted: (any) -> boolean)
	for index, value in JUNK do
		local ok, result = pcall(fn, value)
		check(ok, `{label}: junk #{index} threw: {result}`)
		check(not accepted(result), `{label}: junk #{index} accepted`)
	end
	local ok, result = pcall(fn, nil)
	check(ok and not accepted(result), `{label}: nil`)
end
local function notNil(result: any): boolean
	return result ~= nil
end

fuzz("Validate.integer", function(v)
	return Validate.integer(v, 0, 100)
end, notNil)
fuzz("Validate.number", function(v)
	return Validate.number(v, 0, 1e6)
end, function(r)
	return r ~= nil and (r ~= r or r == math.huge or r == -math.huge or r < 0 or r > 1e6)
end)
fuzz("Validate.requestId", Validate.requestId, function(r)
	return r ~= nil and (r % 1 ~= 0 or r < 1)
end)
fuzz("Validate.userId", Validate.userId, function(r)
	return r ~= nil and (r % 1 ~= 0 or r < 1)
end)
fuzz("Validate.boolean", Validate.boolean, function(r)
	return r ~= nil and type(r) ~= "boolean"
end)
fuzz("Validate.key", function(v)
	return Validate.key(v, 32)
end, function(r)
	return r ~= nil and (#r > 32 or not string.match(r, "^[%w_%-]+$"))
end)
fuzz("Validate.text", function(v)
	return Validate.text(v, 24)
end, function(r)
	return r ~= nil and (utf8.len(r) == nil or (utf8.len(r) :: number) > 24 or string.find(r, "%c") ~= nil)
end)
fuzz("Validate.stringArray", function(v)
	return Validate.stringArray(v, 100, 16)
end, function(r)
	if r == nil then
		return false
	end
	if #r > 100 then
		return true
	end
	for _, item in r do
		if type(item) ~= "string" or #item > 16 then
			return true
		end
	end
	return false
end)
fuzz("Validate.configKey(RebirthShop)", function(v)
	return (Validate.configKey(v, RebirthConfig.Shop, 32))
end, notNil)
fuzz("CodesConfig.normalize", CodesConfig.normalize, function(r)
	return r ~= nil and not string.match(r, "^[%w]+$")
end)
do
	local settings = ProfileLogic.defaultProfile().settings
	local before = ProfileLogic.deepCopy(settings)
	fuzz("ProfileLogic.applySetting(key)", function(v)
		return ProfileLogic.applySetting(settings, v, true)
	end, function(r)
		return r == true
	end)
	-- Values: booleans are the only legal values, so they are skipped here (anything else junk).
	fuzz("ProfileLogic.applySetting(value)", function(v)
		if type(v) == "boolean" then
			return false
		end
		return ProfileLogic.applySetting(settings, "music", v)
	end, function(r)
		return r == true
	end)
	check(deepEqual(settings, before), "settings never changed by junk")
end
do
	-- Rule functions fed raw client ids / counts: refusal codes, never a throw, never a change.
	local profile = ProfileLogic.defaultProfile() :: any
	PetState.pets(profile)
	PetState.crates(profile)
	PetState.trails(profile)
	profile.cash, profile.gems = 1e9, 1e6
	local before = ProfileLogic.deepCopy(profile)
	local ctx = {
		random = Random.new(1),
		now = 1_800_000_000,
		lucky = false,
		triple = true,
		slots = 3,
		atStand = true,
		restricted = false,
	}
	fuzz("PetLogic.planHatch(egg)", function(v)
		return (PetLogic.planHatch(profile, v, 1, ctx))
	end, notNil)
	fuzz("PetLogic.planHatch(count)", function(v)
		return (PetLogic.planHatch(profile, "garage_egg", v, ctx))
	end, notNil)
	fuzz("CrateLogic.planOpen(crate)", function(v)
		return (CrateLogic.planOpen(profile, v, { random = Random.new(2), now = 1_800_000_000, restricted = false }))
	end, notNil)
	fuzz("CrateLogic.equipTrail", function(v)
		return CrateLogic.equipTrail(profile, v)
	end, function(r)
		return r == "Ok"
	end)
	check(deepEqual(profile, before), "pets / crates / trails never changed by junk")
end
do
	-- Wheel banks corrupted to junk never spin and never go negative.
	for index, value in JUNK do
		if type(value) ~= "table" and type(value) ~= "function" then
			local spin = { free = 0, lastFreeAt = 1_800_000_000, paid = value, bonus = value }
			local ok, source = pcall(WheelLogic.consume, spin, 1_800_000_000, true)
			check(ok, `wheel junk #{index} threw`)
			if source ~= nil then
				check(type(value) == "number" and value >= 1 and value == value, `wheel junk #{index} spun`)
			end
		end
	end
end

-- 4. R57 World 2 remotes ------------------------------------------------------------------------
-- Extra world-shaped junk on top of JUNK: near-miss ids that must never pass.
local WORLD_JUNK: { any } = {
	"Dino",
	"DINO",
	"dino ",
	" dino",
	"dino\0",
	"dino\n",
	"di no",
	"dino/../main",
	"main.",
	"mai",
	"__index",
	"space",
	string.rep("d", 17),
	string.rep("d", 1_000_000),
}
for _, value in JUNK do
	table.insert(WORLD_JUNK, value)
end
local function fuzzWorld(label: string, fn: (any) -> any, accepted: (any) -> boolean)
	for index, value in WORLD_JUNK do
		local ok, result = pcall(fn, value)
		check(ok, `{label}: junk #{index} threw: {result}`)
		check(not accepted(result), `{label}: junk #{index} accepted`)
	end
end
fuzzWorld("Validate.worldId", Validate.worldId, notNil)
fuzz("Validate.worldId(nil)", Validate.worldId, notNil)
-- Rebirth(worldId?): nil is the ONLY way to mean main; junk is refused, never "main".
fuzzWorld("Validate.worldIdOrMain", Validate.worldIdOrMain, notNil)
check(Validate.worldIdOrMain(nil) == "main", "Rebirth() with no world = main")
-- TravelWorld(worldId, target, index?): junk in each position with the other two valid.
fuzzWorld("TravelWorld(worldId)", function(v)
	return Validate.travelRequest(v, "area", 1)
end, notNil)
fuzzWorld("TravelWorld(target)", function(v)
	return Validate.travelRequest("dino", v, 1)
end, notNil)
fuzzWorld("TravelWorld(index, area)", function(v)
	return Validate.travelRequest("dino", "area", v)
end, function(r)
	-- Only whole numbers inside 1..areaCount may pass (the junk list has none of those).
	return r ~= nil
end)
fuzzWorld("TravelWorld(index, plot)", function(v)
	return Validate.travelRequest("dino", "plot", v)
end, notNil)
fuzzWorld("TravelWorld(index, spawn)", function(v)
	return Validate.travelRequest("dino", "spawn", v)
end, notNil)
-- RebirthShopBuy(key, worldId?): junk key with each world, junk world with a real key.
for _, worldId in WorldsConfig.Order do
	fuzzWorld(`RebirthShopBuy(key, {worldId})`, function(v)
		return (Validate.rebirthShopBuy(v, worldId))
	end, notNil)
end
fuzzWorld("RebirthShopBuy(world)", function(v)
	return (Validate.rebirthShopBuy("clickPower", v))
end, notNil)
do
	-- World currency math: junk amounts never pass and never touch the profile.
	local profile = ProfileLogic.defaultProfile() :: any
	ProfileLogic.addWorldCash(profile, "dino", 100)
	ProfileLogic.addWorldTokens(profile, "dino", 5)
	local before = ProfileLogic.deepCopy(profile)
	for index, value in JUNK do
		if type(value) ~= "number" or value ~= value or value == math.huge or value <= 0 then
			local ok, added = pcall(ProfileLogic.addWorldCash, profile, "dino", value)
			check(ok and added == 0, `addWorldCash junk #{index}`)
			local ok2, spent = pcall(ProfileLogic.spendWorldCash, profile, "dino", value)
			check(ok2 and spent == false, `spendWorldCash junk #{index}`)
			local ok3, tokens = pcall(ProfileLogic.addWorldTokens, profile, "dino", value)
			check(ok3 and tokens == 0, `addWorldTokens junk #{index}`)
			local ok4, used = pcall(ProfileLogic.spendWorldTokens, profile, "dino", value)
			check(ok4 and used == false, `spendWorldTokens junk #{index}`)
		end
	end
	check(deepEqual(profile, before), "world wallets never changed by junk amounts")
end

-- Deterministic random fuzz: random junk tables / strings / numbers into the validators.
do
	local rng = Random.new(20261030)
	local function randomValue(depth: number): any
		local pick = rng:NextInteger(1, 8)
		if pick == 1 then
			return rng:NextNumber() * 2 ^ rng:NextInteger(0, 1100) * (if rng:NextInteger(0, 1) == 0 then 1 else -1)
		elseif pick == 2 then
			local bytes = {}
			for i = 1, rng:NextInteger(0, 40) do
				bytes[i] = string.char(rng:NextInteger(0, 255))
			end
			return table.concat(bytes)
		elseif pick == 3 then
			return rng:NextInteger(0, 1) == 1
		elseif pick == 4 and depth < 3 then
			local t = {}
			for _ = 1, rng:NextInteger(0, 6) do
				local key = randomValue(depth + 1)
				if key ~= nil and key == key then -- (nil / NaN can't be table keys)
					t[key] = randomValue(depth + 1)
				end
			end
			return t
		elseif pick == 5 then
			return 0 / 0
		elseif pick == 6 then
			return rng:NextInteger(-5, 5)
		end
		return nil
	end
	for _ = 1, 4000 do
		local value = randomValue(0)
		local ok = pcall(function()
			Validate.integer(value, 1, 3)
			Validate.key(value, 32)
			Validate.text(value, 24)
			Validate.stringArray(value, 100, 16)
			Validate.requestId(value)
			CodesConfig.normalize(value)
			-- R57 world arguments: no random value may pass as a world / travel / shop request.
			assert(Validate.worldId(value) == nil or value == "main" or value == "dino", "worldId")
			Validate.travelRequest(value, value, value)
			Validate.rebirthShopBuy(value, value)
		end)
		check(ok, "random fuzz never throws")
	end
end

print(`[remote-security] {checks} checks passed`)
