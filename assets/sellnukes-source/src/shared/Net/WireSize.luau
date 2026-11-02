--!strict
--[[
	WireSize — a rough, allocation-free estimate of how many bytes a value costs on the wire when
	Roblox replicates it (a RemoteEvent argument or a replicated attribute value).

	Purpose:
		Copied from RoBeasts. The engine's Stats.DataSendKbps only gives a total; to NAME the
		source, a server telemetry layer can estimate the bytes behind every server→client remote
		fire (Remotes.setSendObserver) and every replicated attribute change, per remote /
		attribute name. tests/profile-sync.luau uses it to pin the bandwidth budget of the
		tycoon's hottest push (a cash-only ProfileDelta). This module is that estimate.
		It is MEASUREMENT ONLY: nothing in gameplay or networking depends on its numbers.

	Size model (approximate, Roblox-like; compare names against each other, not to the byte):
		every value = 1-byte type tag + payload, where the payload is
			nil 0 · boolean 1 · number 8 · string #s + 2 (length prefix) · buffer len + 2
			Vector3 12 · Vector2 8 · CFrame 24 (position + compressed rotation) · Color3 12
			EnumItem 4 · Instance 6 (a replication reference) · UDim2 16 · other userdata 8
			table 2 (entry count) + each entry: array entries (keys 1, 2, 3, ... in order) cost
			only their value; any other entry costs its key + its value.
		A remote fire adds `EventOverhead` (the remote's reference + argument count); an attribute
		change adds `AttributeOverhead` (the instance's reference + change header) + the name.

	Bounds (a payload can never make this loop unbounded or recurse forever):
		- tables nest at most `MaxDepth` (6) levels; deeper tables count as a header plus one byte
		  per array entry (rawlen, an O(log n) border search) without being walked;
		- at most `MaxNodes` (4096) values are MEASURED per top-level call. That covers every real
		  payload exactly (the largest, a late-game ProfileUpdate snapshot with a full pet
		  inventory, is well under 2 000 values);
		- past the measuring budget, the remaining entries of the table being walked are only
		  COUNTED (a bare `next` step, no recursion), at most `MaxCounted` (65 536) steps per call,
		  and extrapolated at the average size of that table's measured entries (or, when none was
		  measured, the average measured entry of the whole call). When even the counting budget
		  runs out, the array part is still covered through rawlen. So giant payloads are estimated,
		  not truncated, and the work stays bounded;
		- a table that references one of its own ancestors (a cycle, which a RemoteEvent would
		  refuse anyway) counts as its header only. The ancestor path lives in a module-level
		  array of at most MaxDepth slots, so no call allocates a table.

	Pure: no Roblox services, no requires. `typeof` only reports Roblox datatypes inside Roblox; in
	Lune they do not exist, so tests exercise the plain-Luau branches (`lune run tests/profile-sync.luau`).

	Example:
		WireSize.ofValue(true)                      --> 2  (tag + 1)
		WireSize.ofValue("hello")                   --> 8  (tag + 5 + 2)
		WireSize.ofArgs(7, Vector3.zero)            --> EventOverhead + 9 + 13
		WireSize.ofValue({ 1, 2 })                  --> 1 + 2 + 9 + 9 = 21
]]

local WireSize = {}

-- Per remote fire: the remote's replication reference (6) + argument count (2).
WireSize.EventOverhead = 8
-- Per replicated attribute change: the instance's replication reference (6) + change header (2).
-- The attribute's name travels too (ofAttribute adds #name).
WireSize.AttributeOverhead = 8
-- Deepest table nesting that is walked (a top-level table is depth 1).
WireSize.MaxDepth = 6
-- Values measured per top-level ofValue / ofArgs call before extrapolation takes over (covers
-- every real payload exactly: a veteran ProfileUpdate is ~1 550 values).
WireSize.MaxNodes = 4096
-- Entries merely COUNTED (no recursion) per call once MaxNodes is spent, for extrapolation.
WireSize.MaxCounted = 65536
-- Fallback bytes per entry when nothing at all was measured yet (a tag + a small scalar).
local FALLBACK_ENTRY = 10

-- Fixed payload bytes per Roblox datatype name (typeof result). Strings, buffers and tables are
-- measured separately; anything not listed here is "other userdata" (8).
local FIXED_PAYLOAD = table.freeze({
	["nil"] = 0,
	boolean = 1,
	number = 8,
	Vector3 = 12,
	vector = 12, -- Luau's native vector type (typeof in runtimes without the Roblox datatype)
	Vector2 = 8,
	CFrame = 24,
	Color3 = 12,
	EnumItem = 4,
	Instance = 6,
	UDim2 = 16,
	UDim = 8,
	Vector3int16 = 6,
	Vector2int16 = 4,
	NumberRange = 8,
	Rect = 16,
	BrickColor = 4,
} :: { [string]: number })
local OTHER_USERDATA = 8
local TAG = 1
local TABLE_HEADER = 2
local LENGTH_PREFIX = 2

-- Visit budget of the current top-level call (reset by ofValue / ofArgs; nothing yields inside).
local budget = 0
-- Counting budget for extrapolation past `budget` (reset per call).
local countBudget = 0
-- Every measured table entry of the current call (count + bytes): the extrapolation fallback
-- for a table whose own entries were never measured.
local callEntries = 0
local callEntryBytes = 0
-- Tables on the current recursion path (ancestor cycle guard); slots 1..depth are live.
local path: { unknown } = {}

-- Forward declaration: measure and measureTable recurse into each other.
local measure: (value: unknown, depth: number) -> number

--[[
	Bytes of table `t` found at nesting `depth` (1 = a top-level argument). Walks keys and values
	within the depth / node budgets described in the header; never allocates.
]]
local function measureTable(t: { [unknown]: unknown }, depth: number): number
	if depth > WireSize.MaxDepth then
		-- Too deep to walk: header + a 1-byte lower bound per array entry (rawlen: a border
		-- search, no walk).
		return TAG + TABLE_HEADER + rawlen(t)
	end
	-- Ancestor cycle guard (at most MaxDepth - 1 comparisons).
	for index = 1, depth - 1 do
		if rawequal(path[index], t) then
			return TAG + TABLE_HEADER
		end
	end
	path[depth] = t
	local bytes = TAG + TABLE_HEADER
	local seen = 0 -- entries measured so far
	local seenBytes = 0 -- their bytes (for extrapolation)
	local nextIndex = 1 -- the next key that continues the array part
	-- `next` (not generalized iteration) and rawlen: a metatable's __iter / __len never runs.
	for key, value in next, t do
		if budget <= 0 then
			-- Measuring budget spent: COUNT this entry and the rest (bare `next` steps from here,
			-- no recursion, at most MaxCounted per call) and extrapolate them at this table's
			-- average measured entry (else the call's). If counting runs out too, rawlen still
			-- covers the array part.
			local rest = 1
			for _ in next, t, key do
				if countBudget <= 0 then
					break
				end
				countBudget -= 1
				rest += 1
			end
			rest = math.max(rest, rawlen(t) - seen)
			local average = if seen > 0
				then seenBytes / seen
				elseif callEntries > 0 then callEntryBytes / callEntries
				else FALLBACK_ENTRY
			seenBytes += average * rest
			break
		end
		local entry = 0
		if key == nextIndex then
			nextIndex += 1 -- array entry: the position is implicit on the wire
		else
			entry += measure(key, depth)
		end
		entry += measure(value, depth)
		seen += 1
		seenBytes += entry
		callEntries += 1
		callEntryBytes += entry
	end
	path[depth] = nil
	return bytes + seenBytes
end

--[[ Bytes of one value at nesting `depth` (0 for a top-level value). Consumes one budget unit. ]]
function measure(value: unknown, depth: number): number
	budget -= 1
	local kind = typeof(value)
	local fixed = FIXED_PAYLOAD[kind]
	if fixed ~= nil then
		return TAG + fixed
	elseif kind == "string" then
		return TAG + #(value :: string) + LENGTH_PREFIX
	elseif kind == "table" then
		return measureTable(value :: { [unknown]: unknown }, depth + 1)
	elseif kind == "buffer" then
		return TAG + buffer.len(value :: buffer) + LENGTH_PREFIX
	end
	-- Other Roblox datatypes (or functions/threads, which a remote cannot carry).
	return TAG + OTHER_USERDATA
end

--[[
	Approximate wire bytes of ONE value (an attribute value, or one remote argument).
	@param value any Luau / Roblox value (untrusted shapes are fine: bounded and cycle-safe)
	@return number rounded estimate in bytes (>= 1)
]]
function WireSize.ofValue(value: unknown): number
	budget = WireSize.MaxNodes
	countBudget = WireSize.MaxCounted
	callEntries, callEntryBytes = 0, 0
	return math.floor(measure(value, 0) + 0.5)
end

--[[
	Approximate wire bytes of a remote fire's payload: EventOverhead + every argument. The node
	budget is shared by all arguments. Varargs are read with `select` (no table is packed), so a
	30 Hz caller allocates nothing here.
	@param ... the arguments exactly as passed to FireClient / FireAllClients (after the player)
	@return number rounded estimate in bytes (>= EventOverhead)
]]
function WireSize.ofArgs(...: unknown): number
	budget = WireSize.MaxNodes
	countBudget = WireSize.MaxCounted
	callEntries, callEntryBytes = 0, 0
	local bytes = WireSize.EventOverhead
	for index = 1, select("#", ...) do
		bytes += measure((select(index, ...)), 0)
	end
	return math.floor(bytes + 0.5)
end

--[[
	Approximate wire bytes of ONE replicated attribute change sent to ONE client:
	AttributeOverhead + the name's bytes + the new value (nil when the attribute was removed).
	@param name the attribute's name
	@param value its new value (instance:GetAttribute(name))
	@return number rounded estimate in bytes
	Example: WireSize.ofAttribute("Stamina", 0.5) --> 8 + 7 + 9 = 24
]]
function WireSize.ofAttribute(name: string, value: unknown): number
	return WireSize.AttributeOverhead + #name + WireSize.ofValue(value)
end

return table.freeze(WireSize)
