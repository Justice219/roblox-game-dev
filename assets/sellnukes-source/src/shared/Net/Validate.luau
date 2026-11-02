--!strict
--[[
	Validate — boundary validators for untrusted remote arguments.

	Purpose:
		Every server RemoteEvent handler receives `unknown` arguments from a potentially malicious
		client. These helpers narrow them safely: correct type, finite, in range, from an
		allowlist, bounded size. They return the narrowed value or nil, so handlers read naturally:

			local producerId = Validate.key(rawId, 32)
			local mode = Validate.oneOf(rawMode, { "1", "10", "max" })
			if producerId == nil or mode == nil then return end
			if TycoonConfig.Producers[producerId] == nil then return end -- then the config check

		Copied from RoBeasts (number / integer / boolean / string / oneOf / vector3 /
		basePartInWorkspace / flatTable) and extended for SellNukes with `key`, `configKey`,
		`requestId`, `userId`, `text` and `stringArray`, plus the R57 World 2 world arguments:
			worldId(raw)                       a KNOWN world id ("main", "dino", ...)
			worldIdOrMain(raw)                 nil → "main" (old clients), else worldId
			travelRequest(world, target, index)  TravelWorld's three arguments, parsed together
			rebirthShopBuy(key, world)         RebirthShopBuy: key from THAT world's shop

	Rules every helper follows:
		- wrong type → nil (never coerces "5" to 5, never accepts a table with a metatable);
		- numbers must be finite (NaN / ±inf rejected) and inside the given range;
		- strings and arrays have hard length caps so a client can never make the server walk or
		  store an unbounded value.

	Pure logic (no Instance access except `basePartInWorkspace`); tests/validate.luau runs the
	real module under Lune.

	Connects to: every server remote handler (PlayerDataService ProfileDeltaAck, MonetizationService
	PromptProduct / PromptPass, and every later service), MathUtil.isFinite, Shared/Config/Worlds/
	WorldsConfig (the world allowlist + each world's area count and rebirth shop), WorldLayout
	(PlotCount).
]]

local Workspace = game:GetService("Workspace")

local MathUtil = require(script.Parent.Parent.Util.MathUtil)
local WorldLayout = require(script.Parent.Parent.Config.WorldLayout)
local WorldsConfig = require(script.Parent.Parent.Config.Worlds.WorldsConfig)

-- R57: a TravelWorld target and the parsed TravelWorld request.
export type TravelTarget = "spawn" | "area" | "plot"
export type TravelRequest = { worldId: string, target: TravelTarget, index: number? }

local Validate = {}

-- Largest whole number a double holds exactly (2^53); ids and counters never exceed it.
local MAX_SAFE_INTEGER = 9007199254740992

-- R57: a world id is 1..MaxIdLength (16) bytes of IdPattern (^[a-z][a-z0-9]*$) — the registry's
-- own id rules, which are also ProfileLogic's profile.worlds key format.
local MAX_WORLD_ID_LENGTH = WorldsConfig.MaxIdLength
local WORLD_ID_PATTERN = WorldsConfig.IdPattern

-- R57: TravelWorld targets (allowlist; order is irrelevant).
local TRAVEL_TARGETS: { TravelTarget } = { "spawn", "area", "plot" }
Validate.TravelTargets = table.freeze(table.clone(TRAVEL_TARGETS))

-- Byte cap of a rebirth shop key (every world's shop keys are short camelCase ids).
local MAX_SHOP_KEY_LENGTH = 32

--[[
	A finite number within [min, max].
	Example: Validate.number(0.5, 0, 1) --> 0.5 ; Validate.number(0 / 0, 0, 1) --> nil
]]
function Validate.number(value: unknown, min: number, max: number): number?
	if type(value) ~= "number" or not MathUtil.isFinite(value) then
		return nil
	end
	if value < min or value > max then
		return nil
	end
	return value
end

--[[
	An integer within [min, max].
	Example: Validate.integer(3, 1, 10) --> 3 ; Validate.integer(3.5, 1, 10) --> nil
]]
function Validate.integer(value: unknown, min: number, max: number): number?
	local n = Validate.number(value, min, max)
	if n == nil or n % 1 ~= 0 then
		return nil
	end
	return n
end

--[[ A boolean. ]]
function Validate.boolean(value: unknown): boolean?
	if type(value) == "boolean" then
		return value
	end
	return nil
end

--[[
	A string with length in [minLength, maxLength] (bytes).
	Example: Validate.string("abc", 1, 8) --> "abc"
]]
function Validate.string(value: unknown, minLength: number, maxLength: number): string?
	if type(value) ~= "string" then
		return nil
	end
	local length = #value
	if length < minLength or length > maxLength then
		return nil
	end
	return value
end

--[[
	One of an allowlist of strings (exact match).
	Example: Validate.oneOf("max", { "1", "10", "max" }) --> "max"
]]
function Validate.oneOf<T>(value: unknown, allowed: { T }): T?
	if type(value) ~= "string" then
		return nil
	end
	for _, option in allowed do
		if (option :: any) == value then
			return option
		end
	end
	return nil
end

--[[
	A config-style identifier: 1..maxLength bytes of ASCII letters, digits, "_" or "-". Use it for
	every id a client names (producer, pad, product key, pass key, egg, crate, upgrade): the strict
	charset means the value can never smuggle control characters, separators or path syntax, and
	it is always safe to log or to use as a table key.
	Example: Validate.key("garage_bench", 32) --> "garage_bench" ; Validate.key("a b", 32) --> nil
]]
function Validate.key(value: unknown, maxLength: number): string?
	local text = Validate.string(value, 1, maxLength)
	if text == nil or string.find(text, "^[%w_%-]+$") == nil then
		return nil
	end
	return text
end

--[[
	A key that exists in a server config map (the allowlist IS the config). Uses `rawget`, so a
	table with an __index metamethod can never make an unknown key look valid.
	@param value     the untrusted value
	@param map       e.g. MonetizationConfig.Products
	@param maxLength byte cap checked before the lookup (default 64)
	@return the key and its config entry, or nil
	Example: local key, product = Validate.configKey(raw, MonetizationConfig.Products)
]]
function Validate.configKey<V>(value: unknown, map: { [string]: V }, maxLength: number?): (string?, V?)
	local key = Validate.key(value, maxLength or 64)
	if key == nil then
		return nil, nil
	end
	local entry = rawget(map :: any, key)
	if entry == nil then
		return nil, nil
	end
	return key, entry
end

--[[
	A client request id (whole number 1..2^31-1). Clients number their requests (SpinWheel,
	HatchEgg, OpenCrate) so the server can answer exactly once per request.
	Example: Validate.requestId(17) --> 17 ; Validate.requestId(-1) --> nil
]]
function Validate.requestId(value: unknown): number?
	return Validate.integer(value, 1, 2_147_483_647)
end

--[[
	A Roblox UserId (whole number 1..2^53). Existence / presence in the server is the caller's
	check (Players:GetPlayerByUserId).
]]
function Validate.userId(value: unknown): number?
	return Validate.integer(value, 1, MAX_SAFE_INTEGER)
end

--[[
	Player-typed text (e.g. RenameStand): valid UTF-8, 1..maxChars characters after trimming
	surrounding whitespace, no control characters (newlines / tabs / NUL / DEL / C1), and at most
	maxChars * 4 bytes before any work is done. The result STILL has to go through
	TextService:FilterStringAsync before anyone else sees it.
	@return the trimmed text, or nil
	Example: Validate.text("  Nuke Shack ", 24) --> "Nuke Shack"
]]
function Validate.text(value: unknown, maxChars: number): string?
	-- Byte pre-check first: a 1 MB string is rejected without being scanned.
	local raw = Validate.string(value, 1, maxChars * 4)
	if raw == nil then
		return nil
	end
	local trimmed = string.match(raw, "^%s*(.-)%s*$") :: string
	local length = utf8.len(trimmed)
	if length == nil or length < 1 or length > maxChars then
		return nil
	end
	-- ASCII control characters (0-31, 127) are never valid in a sign name.
	if string.find(trimmed, "[%c]") ~= nil then
		return nil
	end
	-- C1 control characters (U+0080..U+009F) arrive as UTF-8 bytes C2 80..C2 9F.
	if string.find(trimmed, "\194[\128-\159]") ~= nil then
		return nil
	end
	return trimmed
end

--[[
	A plain array of 1..maxCount distinct `Validate.key` strings (each ≤ maxLength bytes), e.g. the
	pet uids of DeletePets. Rejects metatables, holes, non-array keys and duplicates.
	@return a NEW array (the client's table is never kept), or nil
	Example: Validate.stringArray({ "12", "15" }, 50, 16) --> { "12", "15" }
]]
function Validate.stringArray(value: unknown, maxCount: number, maxLength: number): { string }?
	if type(value) ~= "table" or getmetatable(value :: any) ~= nil then
		return nil
	end
	local source = value :: { [unknown]: unknown }
	local count = 0
	for _ in source do
		count += 1
		if count > maxCount then
			return nil
		end
	end
	if count == 0 then
		return nil
	end
	local result: { string } = table.create(count) :: { string }
	local seen: { [string]: boolean } = {}
	for index = 1, count do
		-- Every key 1..count must exist: together with the count this proves a dense array.
		local item = Validate.key(rawget(source :: any, index), maxLength)
		if item == nil or seen[item] then
			return nil
		end
		seen[item] = true
		result[index] = item
	end
	return result
end

--[[
	A finite Vector3 whose magnitude is at most maxMagnitude.
]]
function Validate.vector3(value: unknown, maxMagnitude: number): Vector3?
	if typeof(value) ~= "Vector3" then
		return nil
	end
	local v = value :: Vector3
	if not MathUtil.isFiniteVector3(v) or v.Magnitude > maxMagnitude then
		return nil
	end
	return v
end

--[[
	A BasePart that is currently a descendant of Workspace (rejects nil, destroyed parts,
	parts in other services, and non-part instances).
]]
function Validate.basePartInWorkspace(value: unknown): BasePart?
	if typeof(value) ~= "Instance" then
		return nil
	end
	local instance = value :: Instance
	if not instance:IsA("BasePart") or not instance:IsDescendantOf(Workspace) then
		return nil
	end
	return instance
end

--[[
	A flat table with at most `maxKeys` string keys whose values are primitive
	(string ≤ 200 bytes / finite number / boolean). Rejects nested tables, functions, instances
	and metatables. Returns a NEW table (the client's table is never kept).
	Example: Validate.flatTable({ fps = 60, device = "phone" }, 16)
]]
function Validate.flatTable(value: unknown, maxKeys: number): { [string]: string | number | boolean }?
	if type(value) ~= "table" or getmetatable(value :: any) ~= nil then
		return nil
	end
	local count = 0
	local result: { [string]: string | number | boolean } = {}
	for key, item in value :: { [unknown]: unknown } do
		count += 1
		if count > maxKeys or type(key) ~= "string" or #key > 64 then
			return nil
		end
		if type(item) == "string" then
			if #item > 200 then
				return nil
			end
			result[key] = item
		elseif type(item) == "number" then
			if not MathUtil.isFinite(item) then
				return nil
			end
			result[key] = item
		elseif type(item) == "boolean" then
			result[key] = item
		else
			return nil
		end
	end
	return result
end

--[[
	R57 World 2: a KNOWN world id ("main" included): a string of 1..16 bytes matching
	^[a-z][a-z0-9]*$ that the worlds registry knows (WorldsConfig.get). The cheap shape check runs
	first, so a huge or binary string never reaches the lookup.
	@return the registry's id, or nil
	Example: Validate.worldId("dino") --> "dino" ; Validate.worldId("Dino") --> nil
]]
function Validate.worldId(value: unknown): string?
	if
		type(value) ~= "string"
		or #value < 1
		or #value > MAX_WORLD_ID_LENGTH
		or string.find(value, WORLD_ID_PATTERN) == nil
	then
		return nil
	end
	local def = WorldsConfig.get(value)
	return if def ~= nil then def.id else nil
end

--[[
	R57: an OPTIONAL world argument (Rebirth / RebirthShopBuy): nil → "main" (old clients send
	nothing); any other value must be a known world id — junk is REJECTED (nil), never read as main.
	Example: Validate.worldIdOrMain(nil) --> "main" ; Validate.worldIdOrMain(5) --> nil
]]
function Validate.worldIdOrMain(value: unknown): string?
	if value == nil then
		return WorldsConfig.MAIN
	end
	return Validate.worldId(value)
end

--[[
	R57: parses TravelWorld(worldId, target, index?) as ONE request: a known world, an allowlisted
	target, and an index that fits the target — "spawn": nil; "area": a whole number in
	1..that world's area count; "plot": a whole number in 1..WorldLayout.PlotCount. Anything else
	→ nil (drop the packet). State checks (unlocked, enabled, alive, cooldown, owned plot, area
	unlocked) stay with the handler (WorldService / TravelRules).
	@return { worldId, target, index? } or nil
	Example: Validate.travelRequest("dino", "area", 2) --> { worldId = "dino", target = "area", index = 2 }
]]
function Validate.travelRequest(rawWorld: unknown, rawTarget: unknown, rawIndex: unknown): TravelRequest?
	local worldId = Validate.worldId(rawWorld)
	local target = Validate.oneOf(rawTarget, TRAVEL_TARGETS)
	local def = if worldId ~= nil then WorldsConfig.get(worldId) else nil
	if worldId == nil or target == nil or def == nil then
		return nil
	end
	if target == "spawn" then
		return if rawIndex == nil then { worldId = worldId, target = target, index = nil } else nil
	end
	local maxIndex = if target == "area" then def.geometry.areaCount else WorldLayout.PlotCount
	local index = Validate.integer(rawIndex, 1, maxIndex)
	if index == nil then
		return nil
	end
	return { worldId = worldId, target = target, index = index }
end

--[[
	R57: parses RebirthShopBuy(upgradeKey, worldId?): the world via worldIdOrMain, then the key
	against THAT world's rebirth shop only (Nuke Town keys never buy in Dino Valley's Amber shop and
	vice versa; rawget allowlist, metatable-proof).
	@return (upgradeKey, worldId), or (nil, nil)
	Example: Validate.rebirthShopBuy("clickPower", "dino") --> "clickPower", "dino"
]]
function Validate.rebirthShopBuy(rawKey: unknown, rawWorld: unknown): (string?, string?)
	local worldId = Validate.worldIdOrMain(rawWorld)
	local def = if worldId ~= nil then WorldsConfig.get(worldId) else nil
	if def == nil then
		return nil, nil
	end
	local key = Validate.configKey(rawKey, def.rebirth.Shop :: any, MAX_SHOP_KEY_LENGTH)
	if key == nil then
		return nil, nil
	end
	return key, def.id
end

return table.freeze(Validate)
