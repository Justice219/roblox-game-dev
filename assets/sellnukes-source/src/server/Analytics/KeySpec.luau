--!strict
--[[
	KeySpec — validates every key the generic recorders receive against the documented patterns of
	AnalyticsConfig.Metrics (the RECORDER families: tycoon, worlds, retention, pets, crates, attack,
	event, social). Pure rules + a small memo; no services, never yields, never throws.

	Why it exists:
		Owner rule "track as much as possible" means many systems call the analytics layer. Each key
		they pass must be (a) documented, so the COPY FOR AI export can explain it, and (b) bounded,
		so one bug can never create thousands of DataStore keys. KeySpec enforces both: a key that
		matches no documented pattern is REFUSED (the recorder counts core "ops:badKey:<family>").

	Pattern grammar (see AnalyticsConfig header): parts split on ":"; each part is
		literal        exact match                      "hatch"
		<a|b|c>        one of the listed literals       "<free|paid>"
		<lo-hi>        a whole number lo..hi            "<1-7>"
		<kind>         an id of that kind (Kinds)       "<padId>"
	Kinds:
		BUILT-IN (config lookups / fixed label lists): padId, producerId (ANY world's ids, via
		  WorldsConfig), area (Nuke Town areas), feature, levelMark, areaBucket, runBucket,
		  offlineBucket, rebirthBucket, ownedBucket, friendBucket, rarity, screen, source,
		  upgradeKey (Nuke Town shop), world (a WorldsConfig id), travelReason.
		  WORLD-SCOPED (R57; checked against the world named by the key's earlier <world> part):
		  worldArea (1..that world's area count), worldUpgrade (that world's rebirth-shop key),
		  worldStep (that world's funnel step). Without a preceding <world> part they refuse.
		  A value that fails a built-in kind refuses the key (caller bug).
		REGISTERED (AnalyticsService.registerIds(kind, isValid) by the owning system): exact check;
		  a value that fails refuses the key.
		NOT REGISTERED YET (e.g. eggId before the pets system starts): the fallback rule — an
		  identifier `[%a][%w_]*` of ≤ MaxKeyPart characters — accepting at most FallbackKindCap
		  distinct values per kind per server; later values fold into "other" (totals still add up).

	Cost: a validated key is memoized (KeySpec.MemoCap entries, cleared when full), so hot recorders
	pay one table lookup per call after the first.

	Connects to: Server/Analytics/Recorders (generic family recorders), AnalyticsConfig.Metrics /
	KeySpec / Worlds, Shared/Config/TycoonConfig (+ RebirthConfig) and Shared/Config/Worlds/
	WorldsConfig for built-in kinds, tests/analytics-recorders.luau.

	Example:
		KeySpec.check("tycoon", "pad:a1_workbench")     --> "pad:a1_workbench"
		KeySpec.check("tycoon", "pad:not_a_pad")        --> nil, "kind"
		KeySpec.check("worlds", "area:dino:6")          --> "area:dino:6"
		KeySpec.check("worlds", "area:dino:7")          --> nil (Dino Valley has 6 areas)
		KeySpec.check("pets", "hatch:BasicEgg")         --> "hatch:BasicEgg" (fallback rule)
		KeySpec.register("eggId", function(id) return EggConfig.Eggs[id] ~= nil end)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local RebirthConfig = require(ReplicatedStorage.Shared.Config.RebirthConfig)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
local AnalyticsLogic = require(script.Parent.AnalyticsLogic)

-- One compiled pattern part.
type Part =
	{ tag: "literal", value: string }
	| { tag: "choice", set: { [string]: boolean } }
	| { tag: "range", lo: number, hi: number }
	| { tag: "kind", kind: string }

-- One compiled pattern: its parts (the pattern string is kept for diagnostics).
type Pattern = { pattern: string, parts: { Part } }

local KeySpec = {}

local MAX_PART = AnalyticsConfig.MaxKeyPart
local OTHER = "other"

-- Label list → set.
local function setOf(list: { string }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, value in list do
		set[value] = true
	end
	return set
end

-- Number list → set of their string spellings ({ 10, 25 } → { ["10"] = true, ["25"] = true }).
local function numberSetOf(list: { number }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, value in list do
		set[string.format("%d", value)] = true
	end
	return set
end

local tycoonConfig = AnalyticsConfig.Tycoon
local LEVEL_MARKS = numberSetOf(tycoonConfig.LevelMarks)
local AREA_BUCKETS = setOf(AnalyticsLogic.bucketLabels(tycoonConfig.AreaMinuteBuckets, "m"))
local RUN_BUCKETS = setOf(AnalyticsLogic.bucketLabels(tycoonConfig.RunMinuteBuckets, "m"))
local OFFLINE_BUCKETS = setOf(AnalyticsLogic.bucketLabels(tycoonConfig.OfflineHourBuckets, "h"))
local REBIRTH_BUCKETS = setOf(AnalyticsLogic.countBucketLabels(tycoonConfig.RebirthBuckets))
local OWNED_BUCKETS = setOf(AnalyticsLogic.countBucketLabels(AnalyticsConfig.Pets.OwnedBuckets))
local FRIEND_BUCKETS = setOf(AnalyticsLogic.countBucketLabels(AnalyticsConfig.Social.FriendBuckets))
local RARITIES = setOf(AnalyticsConfig.Pets.Rarities)
local SCREENS = setOf(AnalyticsConfig.ClientFunnel.Screens)
local SOURCES = setOf(AnalyticsConfig.ClientFunnel.Sources)
local AREA_COUNT = #TycoonConfig.Areas
local TRAVEL_REASONS = setOf(AnalyticsConfig.Worlds.TravelReasons)

-- Per world id: its funnel steps as a set (extra worlds only; AnalyticsConfig.Worlds.Funnels).
local WORLD_STEPS: { [string]: { [string]: boolean } } = {}
for worldId, funnel in AnalyticsConfig.Worlds.Funnels do
	WORLD_STEPS[worldId] = setOf(funnel.steps)
end

-- A whole-number string spelled canonically ("3", never "03" / "3.0"), or nil.
local function canonicalWhole(id: string): number?
	local n = tonumber(id)
	if n == nil or n % 1 ~= 0 or tostring(n) ~= id then
		return nil
	end
	return n
end

-- Built-in kinds: id → valid? (pure lookups into frozen config).
local BUILT_IN: { [string]: (id: string) -> boolean } = {
	-- Any world's pad / producer ids (globally unique and prefixed: a1_… / d3_…, p1_… / dp3_…).
	padId = function(id: string): boolean
		return WorldsConfig.worldOfPad(id) ~= nil
	end,
	producerId = function(id: string): boolean
		return WorldsConfig.worldOfProducer(id) ~= nil
	end,
	world = function(id: string): boolean
		return WorldsConfig.get(id) ~= nil
	end,
	travelReason = function(id: string): boolean
		return TRAVEL_REASONS[id] == true
	end,
	area = function(id: string): boolean
		local n = canonicalWhole(id)
		return n ~= nil and n >= 1 and n <= AREA_COUNT
	end,
	feature = function(id: string): boolean
		return TycoonConfig.FeaturePadOf[id] ~= nil
	end,
	upgradeKey = function(id: string): boolean
		return (RebirthConfig.Shop :: any)[id] ~= nil
	end,
	levelMark = function(id: string): boolean
		return LEVEL_MARKS[id] == true
	end,
	areaBucket = function(id: string): boolean
		return AREA_BUCKETS[id] == true
	end,
	runBucket = function(id: string): boolean
		return RUN_BUCKETS[id] == true
	end,
	offlineBucket = function(id: string): boolean
		return OFFLINE_BUCKETS[id] == true
	end,
	rebirthBucket = function(id: string): boolean
		return REBIRTH_BUCKETS[id] == true
	end,
	ownedBucket = function(id: string): boolean
		return OWNED_BUCKETS[id] == true
	end,
	friendBucket = function(id: string): boolean
		return FRIEND_BUCKETS[id] == true
	end,
	rarity = function(id: string): boolean
		return RARITIES[id] == true
	end,
	screen = function(id: string): boolean
		return SCREENS[id] == true
	end,
	source = function(id: string): boolean
		return SOURCES[id] == true
	end,
}

--[[
	World-scoped kinds: (id, worldId) → valid? `worldId` is the value of the key's earlier <world>
	part (already validated); nil when the pattern has none, which refuses.
]]
local WORLD_SCOPED: { [string]: (id: string, worldId: string?) -> boolean } = {
	worldArea = function(id: string, worldId: string?): boolean
		local def = WorldsConfig.get(worldId)
		local n = canonicalWhole(id)
		return def ~= nil and n ~= nil and n >= 1 and n <= #def.economy.Areas
	end,
	worldUpgrade = function(id: string, worldId: string?): boolean
		local def = WorldsConfig.get(worldId)
		return def ~= nil and def.rebirth.Shop[id] ~= nil
	end,
	worldStep = function(id: string, worldId: string?): boolean
		local steps = if worldId ~= nil then WORLD_STEPS[worldId] else nil
		return steps ~= nil and steps[id] == true
	end,
}

-- Kinds registered at runtime by their owning systems (AnalyticsService.registerIds).
local registered: { [string]: (id: string) -> boolean } = {}
-- Fallback-rule values accepted per unregistered kind (bounded by FallbackKindCap).
local fallbackSeen: { [string]: { [string]: boolean } } = {}
local fallbackCount: { [string]: number } = {}

-- family → head literal (or "*" when the first part is not a literal) → compiled patterns.
local compiled: { [string]: { [string]: { Pattern } } } = {}
-- Memo: family → key → canonical key (false = refused).
local memo: { [string]: { [string]: string | false } } = {}
local memoSize = 0

--[[
	Compiles one documented pattern. Returns nil for a pattern outside the grammar (a config bug:
	it simply never matches, and the config test catches it).
]]
local function compile(pattern: string): Pattern?
	local parts: { Part } = {}
	for _, text in string.split(pattern, ":") do
		if string.sub(text, 1, 1) == "<" and string.sub(text, -1) == ">" then
			local inner = string.sub(text, 2, -2)
			local lo, hi = string.match(inner, "^(%d+)%-(%d+)$")
			if lo ~= nil and hi ~= nil then
				local range: Part = { tag = "range", lo = tonumber(lo) :: number, hi = tonumber(hi) :: number }
				table.insert(parts, range)
			elseif string.find(inner, "|", 1, true) ~= nil then
				local choice: Part = { tag = "choice", set = setOf(string.split(inner, "|")) }
				table.insert(parts, choice)
			elseif string.match(inner, "^%a%w*$") ~= nil then
				local kindPart: Part = { tag = "kind", kind = inner }
				table.insert(parts, kindPart)
			else
				return nil
			end
		elseif string.find(text, "[<>|*]") ~= nil or text == "" then
			return nil
		else
			local literal: Part = { tag = "literal", value = text }
			table.insert(parts, literal)
		end
	end
	return { pattern = pattern, parts = parts }
end

-- Build the compiled index once for every recorder family.
for _, family in AnalyticsConfig.RecorderFamilies do
	local byHead: { [string]: { Pattern } } = {}
	for pattern in AnalyticsConfig.Metrics[family] or {} do
		local spec = compile(pattern)
		if spec ~= nil then
			local first = spec.parts[1]
			local head = if first.tag == "literal" then first.value else "*"
			local list = byHead[head]
			if list == nil then
				list = {}
				byHead[head] = list
			end
			table.insert(list, spec)
		end
	end
	compiled[family] = byHead
	memo[family] = {}
end

--[[
	Validates one value of an id kind and returns the part to store: the value itself, "other"
	(an unregistered kind past its fallback cap), or nil (refused).
]]
local function checkKind(kind: string, value: string, worldId: string?): string?
	local builtIn = BUILT_IN[kind]
	if builtIn ~= nil then
		return if builtIn(value) then value else nil
	end
	local scoped = WORLD_SCOPED[kind]
	if scoped ~= nil then
		return if scoped(value, worldId) then value else nil
	end
	local custom = registered[kind]
	if custom ~= nil then
		local ok, valid = pcall(custom, value)
		return if ok and valid == true then value else nil
	end
	-- Fallback rule for a kind no system registered yet: an identifier, bounded distinct values.
	if string.match(value, "^%a[%w_]*$") == nil then
		return nil
	end
	local seen = fallbackSeen[kind]
	if seen == nil then
		seen = {}
		fallbackSeen[kind] = seen
	end
	if seen[value] then
		return value
	end
	local n = fallbackCount[kind] or 0
	if n >= AnalyticsConfig.KeySpec.FallbackKindCap then
		return OTHER
	end
	seen[value] = true
	fallbackCount[kind] = n + 1
	return value
end

-- Matches `parts` (the key split on ":") against one pattern; returns the canonical key or nil.
local function matchPattern(spec: Pattern, parts: { string }): string?
	if #parts ~= #spec.parts then
		return nil
	end
	local out: { string }? = nil
	-- The value of the key's <world> part, for the world-scoped kinds after it.
	local worldId: string? = nil
	for index, part in spec.parts do
		local value = parts[index]
		if part.tag == "literal" then
			if value ~= part.value then
				return nil
			end
		elseif part.tag == "choice" then
			if not part.set[value] then
				return nil
			end
		elseif part.tag == "range" then
			local n = tonumber(value)
			if n == nil or n % 1 ~= 0 or n < part.lo or n > part.hi or string.format("%d", n) ~= value then
				return nil
			end
		else
			local kept = checkKind(part.kind, value, worldId)
			if kept == nil then
				return nil
			end
			if part.kind == "world" then
				worldId = kept
			end
			if kept ~= value then
				local copy = out or table.clone(parts)
				copy[index] = kept
				out = copy
			end
		end
	end
	return if out ~= nil then table.concat(out, ":") else table.concat(parts, ":")
end

--[[
	Validates `key` for a recorder family.
	@param family a RecorderFamilies id
	@param key    the caller's key (any value; only short strings of [%w_-:<+.] are considered)
	@return the canonical key to count (may contain "other" for an over-cap unregistered id), or
	        nil plus a reason: "family" (not a recorder family), "shape" (not a short clean string),
	        "pattern" (no documented pattern matches, or an id failed its kind)
	Example: KeySpec.check("retention", "daily:claim:3") --> "daily:claim:3"
	         KeySpec.check("retention", "daily:claim:9") --> nil, "pattern"
]]
function KeySpec.check(family: string, key: unknown): (string?, string?)
	local byHead = compiled[family]
	if byHead == nil then
		return nil, "family"
	end
	if type(key) ~= "string" or #key == 0 or #key > AnalyticsConfig.MaxKeyLength then
		return nil, "shape"
	end
	local cache = memo[family]
	local hit = cache[key]
	if type(hit) == "string" then
		return hit, nil
	elseif hit == false then
		return nil, "pattern"
	end
	-- Letters, digits, "_", "-", ":" plus the bucket-label characters "<", "+" and ".".
	if string.find(key, "[^%w_%-:<+%.]") ~= nil then
		return nil, "shape"
	end
	local parts = string.split(key, ":")
	for _, part in parts do
		if #part == 0 or #part > MAX_PART then
			return nil, "shape"
		end
	end
	local result: string? = nil
	for _, head in { parts[1], "*" } do
		for _, spec in byHead[head] or {} do
			result = matchPattern(spec, parts)
			if result ~= nil then
				break
			end
		end
		if result ~= nil then
			break
		end
	end
	if memoSize >= AnalyticsConfig.KeySpec.MemoCap then
		for name in memo do
			memo[name] = {}
		end
		memoSize = 0
		cache = memo[family]
	end
	memoSize += 1
	if result == nil then
		cache[key] = false
		return nil, "pattern"
	end
	local canonical = result :: string
	cache[key] = canonical
	return canonical, nil
end

--[[
	Registers the validator of an id kind (e.g. "eggId") so its keys are checked exactly. Called once
	at Start by the system that owns those ids. Built-in kinds cannot be replaced. Clears the memo
	(values accepted by the fallback rule are re-checked on their next use).
	@param kind    the <kind> name used in AnalyticsConfig.Metrics patterns
	@param isValid (id: string) -> boolean; must not yield (it runs inside recorders)
	@return true when registered
	Example: KeySpec.register("crateId", function(id) return CrateConfig.Crates[id] ~= nil end)
]]
function KeySpec.register(kind: string, isValid: (id: string) -> boolean): boolean
	if
		type(kind) ~= "string"
		or string.match(kind, "^%a%w*$") == nil
		or BUILT_IN[kind] ~= nil
		or WORLD_SCOPED[kind] ~= nil
	then
		return false
	end
	if type(isValid) ~= "function" then
		return false
	end
	registered[kind] = isValid
	for name in memo do
		memo[name] = {}
	end
	memoSize = 0
	return true
end

--[[ True when `kind` is built in or registered (tests / the report's coverage notes). ]]
function KeySpec.isKnownKind(kind: string): boolean
	return BUILT_IN[kind] ~= nil or WORLD_SCOPED[kind] ~= nil or registered[kind] ~= nil
end

--[[
	Every <kind> named by a recorder pattern (config test: each one is built in or expected to be
	registered by a later system).
]]
function KeySpec.kindsInUse(): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, byHead in compiled do
		for _, list in byHead do
			for _, spec in list do
				for _, part in spec.parts do
					if part.tag == "kind" and not seen[part.kind] then
						seen[part.kind] = true
						table.insert(out, part.kind)
					end
				end
			end
		end
	end
	table.sort(out)
	return out
end

--[[ The documented patterns that failed to compile (config test: must be empty). ]]
function KeySpec.invalidPatterns(): { string }
	local out: { string } = {}
	for _, family in AnalyticsConfig.RecorderFamilies do
		for pattern in AnalyticsConfig.Metrics[family] or {} do
			if compile(pattern) == nil then
				table.insert(out, `{family}:{pattern}`)
			end
		end
	end
	table.sort(out)
	return out
end

--[[ Clears the memo and fallback state (tests). Registrations stay. ]]
function KeySpec.resetForTests()
	for name in memo do
		memo[name] = {}
	end
	memoSize = 0
	table.clear(fallbackSeen)
	table.clear(fallbackCount)
end

return table.freeze(KeySpec)
