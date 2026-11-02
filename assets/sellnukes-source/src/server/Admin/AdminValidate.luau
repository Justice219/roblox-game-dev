--!strict
--[[
	AdminValidate — the PURE argument / definition validator of the admin command pipeline
	(spec §14 "strict arg schema"). Ported from RoBeasts AdminService.validateArgs / validateValue,
	extended for SellNukes' runtime-registered commands (validateDef).

	Purpose:
		Every AdminCommand(name, args) arrives from a client. Even an authorised admin's client may
		be tampered with, so the raw `args` table is treated as hostile:
			- it must be a plain table (no metatable), at most Limits.MaxArgs keys, string keys only,
			- every key must be declared by the command's schema (extra / unknown keys are REJECTED),
			- every required argument must be present,
			- every value is narrowed to its declared kind and range (NaN / ±inf / huge strings /
			  control characters / invalid UTF-8 never get through),
			- targeted commands get a `userId` key (integer 1..MaxUserId) that is only a LOOKUP KEY:
			  AdminService resolves it to a real Player afterwards.
		Commands registered at runtime by other systems (AdminService.registerCommand) are checked
		by `validateDef` before they are accepted, and stored as a deep-frozen normalised copy, so
		a buggy registration can never widen what the remote accepts.

	No Roblox services, no yields: Lune runs it directly (tests/admin-validate.luau).

	Connects to: Shared/Config/AdminConfig (schemas, limits), Shared/Net/Validate (primitive
	checks), Server/Admin/AdminRegistry (validateDef), Server/Admin/AdminPipeline (validateArgs,
	summarizeArgs, sanitizeForLog), Server/Admin/AdminAudit (sanitizeForLog).

	Example:
		local args, err = AdminValidate.validateArgs(AdminConfig.Commands.GrantGems, { userId = 1, amount = 50 })
		--> { userId = 1, amount = 50 }, nil
		local _, err2 = AdminValidate.validateArgs(AdminConfig.Commands.GrantGems, { userId = 1, amount = 0 / 0 })
		--> nil, "invalid 'amount': must be a whole number from 1 to 10000000"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)

type ArgSpec = AdminConfig.ArgSpec
type CommandDef = AdminConfig.CommandDef

export type ArgValue = string | number | boolean
export type ValidatedArgs = { [string]: ArgValue }

local Limits = AdminConfig.Limits

local AdminValidate = {}

-- Kinds the validator understands (registered defs may only use these).
local KINDS: { [string]: boolean } = {
	integer = true,
	number = true,
	text = true,
	enum = true,
	boolean = true,
	banDuration = true,
	code = true,
}
-- Targets a command may declare.
local TARGETS: { [string]: boolean } = { None = true, Player = true, AnyUser = true }
-- Tabs a REGISTERED command may live on (Live / Log / Analytics are read-only pages; Meta is
-- reserved for invisible built-ins such as RequestState).
local REGISTERABLE_TABS: { [string]: boolean } = {
	Players = true,
	Economy = true,
	Server = true,
	World = true,
	Attack = true, -- owner R51: attack test bots + knockdown tools
	NewPlayer = true,
}
-- Panel hint formats (anything else is dropped from a registered def).
local FORMATS: { [string]: boolean } = {
	money = true,
	gems = true,
	count = true,
	minutes = true,
	seconds = true,
	hour = true,
}
-- Default text cap when a spec leaves maxLength out.
local DEFAULT_TEXT_CHARS = 200
-- Longest enum value / label of a registered def (characters / bytes).
local MAX_ENUM_VALUE_LENGTH = 64
-- Most panel presets a registered argument may carry.
local MAX_PRESETS = 12
-- Smallest cooldown a registered command may declare (seconds).
local MIN_REGISTERED_COOLDOWN = 0.25
-- Longest cooldown any command may declare (seconds).
local MAX_COOLDOWN = 3600

--------------------------------------------------------------------------------------------------
-- Text helpers
--------------------------------------------------------------------------------------------------

--[[
	Makes any value safe and short for logs / UI: invalid UTF-8 is replaced, control characters
	become spaces, whitespace is collapsed, and the text is cut to `maxLength` characters ("…").
	@param value any value (tostring'd unless it is a string)
	@param maxLength characters kept
	Example: AdminValidate.sanitizeForLog("a\nb", 10) --> "a b"
]]
function AdminValidate.sanitizeForLog(value: unknown, maxLength: number): string
	local text = if type(value) == "string" then value else tostring(value)
	-- Byte guard first: a megabyte string is cut before any pattern work.
	if #text > maxLength * 4 + 4 then
		text = string.sub(text, 1, maxLength * 4 + 4)
		-- The byte cut may split a character: trim back to valid UTF-8.
		while #text > 0 and utf8.len(text) == nil do
			text = string.sub(text, 1, #text - 1)
		end
	end
	if utf8.len(text) == nil then
		return "<invalid text>"
	end
	text = string.gsub(text, "%c", " ")
	-- C1 control characters (U+0080..U+009F).
	text = string.gsub(text, "\194[\128-\159]", " ")
	text = string.gsub(text, "%s+", " ")
	if (utf8.len(text) or 0) > maxLength then
		local cut = utf8.offset(text, maxLength + 1)
		if cut ~= nil then
			text = string.sub(text, 1, cut - 1) .. "…"
		end
	end
	return text
end

--[[
	Validates admin-typed text: UTF-8, no control characters, trimmed, at most `maxLength`
	characters; empty only when the spec allows it.
	@return (trimmed text, nil) or (nil, reason)
]]
local function validateText(value: unknown, spec: ArgSpec): (string?, string?)
	local maxChars = spec.maxLength or DEFAULT_TEXT_CHARS
	-- Byte bound first (a UTF-8 character is at most 4 bytes) so huge strings are cheap to reject.
	local text = Validate.string(value, 0, maxChars * 4)
	if text == nil then
		return nil, "must be text"
	end
	if utf8.len(text) == nil then
		return nil, "invalid characters"
	end
	if string.find(text, "%c") ~= nil or string.find(text, "\194[\128-\159]") ~= nil then
		return nil, "control characters are not allowed"
	end
	local trimmed = string.match(text, "^%s*(.-)%s*$") or ""
	if #trimmed == 0 and spec.allowEmpty ~= true then
		return nil, "cannot be empty"
	end
	if (utf8.len(trimmed) or math.huge) > maxChars then
		return nil, `longer than {maxChars} characters`
	end
	return trimmed, nil
end

--[[
	Validates a redeem code (same rule as CodesConfig.normalize): trimmed, 1..maxLength ASCII
	letters / digits, returned upper-cased.
]]
local function validateCode(value: unknown, spec: ArgSpec): (string?, string?)
	local maxChars = spec.maxLength or Limits.CodeMaxLength
	local text = Validate.string(value, 1, maxChars * 4)
	if text == nil then
		return nil, `must be 1 to {maxChars} letters or digits`
	end
	local trimmed = string.match(text, "^%s*(.-)%s*$") or ""
	if #trimmed < 1 or #trimmed > maxChars or string.find(trimmed, "^%w+$") == nil then
		return nil, `must be 1 to {maxChars} letters or digits`
	end
	return string.upper(trimmed), nil
end

--[[
	Validates one argument value against its spec.
	@return (the narrowed value, nil) or (nil, human-readable reason)
	Example: AdminValidate.validateValue({ kind = "integer", min = 1, max = 5 }, 3) --> 3, nil
]]
function AdminValidate.validateValue(spec: ArgSpec, value: unknown): (ArgValue?, string?)
	local kind = spec.kind
	if kind == "integer" then
		local min = spec.min or -(2 ^ 53)
		local max = spec.max or 2 ^ 53
		local n = Validate.integer(value, min, max)
		if n == nil then
			return nil, `must be a whole number from {min} to {max}`
		end
		if spec.nonZero == true and n == 0 then
			return nil, "cannot be zero"
		end
		return n, nil
	elseif kind == "number" then
		local min = spec.min or -math.huge
		local max = spec.max or math.huge
		local n = Validate.number(value, min, max)
		if n == nil then
			return nil, `must be a number from {min} to {max}`
		end
		if spec.nonZero == true and n == 0 then
			return nil, "cannot be zero"
		end
		return n, nil
	elseif kind == "text" then
		return validateText(value, spec)
	elseif kind == "enum" then
		local option = Validate.oneOf(value, spec.values or {})
		if option == nil then
			return nil, "not an allowed value"
		end
		return option, nil
	elseif kind == "boolean" then
		local flag = Validate.boolean(value)
		if flag == nil then
			return nil, "must be true or false"
		end
		return flag, nil
	elseif kind == "banDuration" then
		local n = Validate.integer(value, -1, Limits.BanMaxSeconds)
		if n == nil then
			return nil, "invalid duration"
		end
		if n == -1 then
			if not AdminConfig.AllowPermanentBans then
				return nil, "permanent bans are disabled"
			end
			return n, nil
		end
		if n < Limits.BanMinSeconds then
			return nil, `must be at least {Limits.BanMinSeconds} seconds`
		end
		return n, nil
	elseif kind == "code" then
		return validateCode(value, spec)
	end
	return nil, "unsupported argument kind"
end

--------------------------------------------------------------------------------------------------
-- Argument tables
--------------------------------------------------------------------------------------------------

-- Target argument added to Player / AnyUser commands (a lookup key, resolved by AdminService).
local USER_ID_SPEC: ArgSpec = { kind = "integer", min = 1, max = Limits.MaxUserId }
table.freeze(USER_ID_SPEC :: any)

-- Per-def cache of the full accepted schema (own args + target key). Weak keys: a def that is
-- dropped (never, today) does not stay alive because of the cache.
local schemaCache: { [CommandDef]: { [string]: ArgSpec } } = setmetatable({}, { __mode = "k" }) :: any

-- The full accepted schema for a command: its own args plus the target key.
local function schemaFor(def: CommandDef): { [string]: ArgSpec }
	local cached = schemaCache[def]
	if cached ~= nil then
		return cached
	end
	local schema: { [string]: ArgSpec } = table.clone(def.args)
	if def.target == "Player" or def.target == "AnyUser" then
		schema.userId = USER_ID_SPEC
	end
	table.freeze(schema)
	schemaCache[def] = schema
	return schema
end

--[[
	Validates a command's raw (untrusted) argument table against its schema.
	Rejects: non-tables, tables with metatables, more than Limits.MaxArgs keys, non-string or
	unknown keys (extra args), missing required args, and every invalid value.
	@param def the command definition (AdminConfig.Commands entry or a registered def)
	@param raw the client's args (nil = no arguments)
	@return (validated args, nil) or (nil, human-readable error)
	Example: AdminValidate.validateArgs(def, { userId = 5, amount = 1e6 })
]]
function AdminValidate.validateArgs(def: CommandDef, raw: unknown): (ValidatedArgs?, string?)
	-- Remote calls with no arguments arrive as nil; treat that as an empty table.
	local input: unknown = if raw == nil then {} else raw
	if type(input) ~= "table" or getmetatable(input :: any) ~= nil then
		return nil, "arguments must be a plain table"
	end
	local rawTable = input :: { [unknown]: unknown }
	local schema = schemaFor(def)
	local count = 0
	for key in rawTable do
		count += 1
		if count > Limits.MaxArgs then
			return nil, "too many arguments"
		end
		if type(key) ~= "string" then
			return nil, "argument names must be text"
		end
		if rawget(schema, key) == nil then
			return nil, `unexpected argument '{AdminValidate.sanitizeForLog(key, 24)}'`
		end
	end
	local values = rawTable :: { [string]: unknown }
	local result: ValidatedArgs = {}
	for key, spec in schema do
		local value = rawget(values :: any, key)
		if value == nil then
			if spec.optional ~= true then
				return nil, `missing argument '{key}'`
			end
			continue
		end
		local parsed, err = AdminValidate.validateValue(spec, value)
		if parsed == nil then
			return nil, `invalid '{key}': {err or "invalid"}`
		end
		result[key] = parsed
	end
	return result, nil
end

--[[
	Serialises validated args for the audit log: sorted keys, sanitised values, each value cut to
	AdminConfig.AuditValueMaxLength characters.
	Example: summarizeArgs({ userId = 1, amount = 5 }) --> "amount=5 userId=1"
]]
function AdminValidate.summarizeArgs(args: ValidatedArgs): string
	local keys: { string } = {}
	for key in args do
		table.insert(keys, key)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, key in keys do
		table.insert(parts, `{key}={AdminValidate.sanitizeForLog(args[key], AdminConfig.AuditValueMaxLength)}`)
	end
	return table.concat(parts, " ")
end

--------------------------------------------------------------------------------------------------
-- Registered command definitions
--------------------------------------------------------------------------------------------------

-- A finite number (not NaN / ±inf).
local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- A non-empty string of at most `maxChars` characters without control characters.
local function shortText(value: unknown, maxChars: number): string?
	if type(value) ~= "string" or #value == 0 or #value > maxChars * 4 then
		return nil
	end
	local length = utf8.len(value)
	if length == nil or length > maxChars or string.find(value, "%c") ~= nil then
		return nil
	end
	return value
end

-- Validates + normalises one registered ArgSpec. Returns (frozen copy, nil) or (nil, reason).
local function normalizeSpec(key: string, raw: unknown): (ArgSpec?, string?)
	if type(raw) ~= "table" or getmetatable(raw :: any) ~= nil then
		return nil, `arg '{key}' must be a plain table`
	end
	local spec = raw :: { [string]: any }
	local kind = spec.kind
	if type(kind) ~= "string" or not KINDS[kind] then
		return nil, `arg '{key}' has an unknown kind`
	end
	local out: { [string]: any } = { kind = kind }
	if spec.optional ~= nil then
		if type(spec.optional) ~= "boolean" then
			return nil, `arg '{key}'.optional must be a boolean`
		end
		out.optional = spec.optional
	end
	if kind == "integer" or kind == "number" then
		if not finite(spec.min) or not finite(spec.max) or spec.min > spec.max then
			return nil, `arg '{key}' needs finite min <= max`
		end
		if kind == "integer" and (spec.min % 1 ~= 0 or spec.max % 1 ~= 0) then
			return nil, `arg '{key}' needs whole min / max`
		end
		out.min = spec.min
		out.max = spec.max
		if spec.nonZero ~= nil then
			if type(spec.nonZero) ~= "boolean" then
				return nil, `arg '{key}'.nonZero must be a boolean`
			end
			out.nonZero = spec.nonZero
		end
		if spec.presets ~= nil then
			if type(spec.presets) ~= "table" or #spec.presets > MAX_PRESETS then
				return nil, `arg '{key}'.presets must be a short list`
			end
			local presets: { number } = {}
			for _, preset in spec.presets do
				if not finite(preset) or preset < spec.min or preset > spec.max then
					return nil, `arg '{key}' has a preset outside [min, max]`
				end
				table.insert(presets, preset)
			end
			out.presets = table.freeze(presets)
		end
	elseif kind == "text" or kind == "code" then
		local maxLength = spec.maxLength
		local cap = if kind == "code" then Limits.CodeMaxLength else DEFAULT_TEXT_CHARS
		if maxLength ~= nil and (not finite(maxLength) or maxLength % 1 ~= 0 or maxLength < 1 or maxLength > cap) then
			return nil, `arg '{key}'.maxLength must be 1..{cap}`
		end
		out.maxLength = maxLength or cap
		if kind == "text" and spec.allowEmpty ~= nil then
			if type(spec.allowEmpty) ~= "boolean" then
				return nil, `arg '{key}'.allowEmpty must be a boolean`
			end
			out.allowEmpty = spec.allowEmpty
		end
	elseif kind == "enum" then
		local values = spec.values
		if type(values) ~= "table" or getmetatable(values) ~= nil then
			return nil, `arg '{key}' needs a values list`
		end
		local count = #values
		if count < 1 or count > Limits.MaxEnumValues then
			return nil, `arg '{key}' needs 1..{Limits.MaxEnumValues} values`
		end
		local seen: { [string]: boolean } = {}
		local copy: { string } = {}
		for index = 1, count do
			local value = shortText(values[index], MAX_ENUM_VALUE_LENGTH)
			if value == nil or seen[value] then
				return nil, `arg '{key}' has an invalid or duplicate value #{index}`
			end
			seen[value] = true
			copy[index] = value
		end
		out.values = table.freeze(copy)
		if spec.labels ~= nil then
			local labels = spec.labels
			if type(labels) ~= "table" or #labels ~= count then
				return nil, `arg '{key}'.labels must match values`
			end
			local labelCopy: { string } = {}
			for index = 1, count do
				local label = shortText(labels[index], MAX_ENUM_VALUE_LENGTH)
				if label == nil then
					return nil, `arg '{key}' has an invalid label #{index}`
				end
				labelCopy[index] = label
			end
			out.labels = table.freeze(labelCopy)
		end
	end
	-- Panel hints (ignored by the server; dropped when malformed).
	local label = shortText(spec.label, Limits.MaxLabelLength)
	if label ~= nil then
		out.label = label
	end
	if type(spec.format) == "string" and FORMATS[spec.format] then
		out.format = spec.format
	end
	if spec.default ~= nil then
		local default, _ = AdminValidate.validateValue(out :: any, spec.default)
		if default ~= nil then
			out.default = default
		end
	end
	return table.freeze(out) :: any, nil
end

--[[
	Validates a command definition passed to AdminService.registerCommand and returns a
	deep-frozen normalised copy (only known fields, sane values). Errors are human-readable so
	the registering builder sees exactly what to fix.
	Rules: name `^[%a][%w_]*$` ≤ MaxCommandNameLength; tab ∈ Players / Economy / Server / World /
	NewPlayer; target ∈ None / Player / AnyUser; label 1..MaxLabelLength chars; description ≤
	MaxDescriptionLength; cooldown finite in [0.25, 3600]; audited / confirm booleans; ≤ MaxArgs
	args with `[%a][%w_]*` keys and no `userId` key (reserved for the target); every spec sane.
	@return (frozen def, nil) or (nil, reason)
	Example: local def, err = AdminValidate.validateDef({ name = "GivePet", tab = "Players", ... })
]]
function AdminValidate.validateDef(raw: unknown): (CommandDef?, string?)
	if type(raw) ~= "table" or getmetatable(raw :: any) ~= nil then
		return nil, "definition must be a plain table"
	end
	local def = raw :: { [string]: any }
	local name = def.name
	if type(name) ~= "string" or #name > Limits.MaxCommandNameLength or string.find(name, "^[%a][%w_]*$") == nil then
		return nil, `name must match [A-Za-z][A-Za-z0-9_]* (<= {Limits.MaxCommandNameLength})`
	end
	if type(def.tab) ~= "string" or not REGISTERABLE_TABS[def.tab] then
		return nil, `{name}: tab must be Players, Economy, Server, World, Attack or NewPlayer`
	end
	if type(def.target) ~= "string" or not TARGETS[def.target] then
		return nil, `{name}: target must be None, Player or AnyUser`
	end
	local label = shortText(def.label, Limits.MaxLabelLength)
	if label == nil then
		return nil, `{name}: label must be 1..{Limits.MaxLabelLength} characters`
	end
	local description: string? = nil
	if def.description ~= nil then
		description = shortText(def.description, Limits.MaxDescriptionLength)
		if description == nil then
			return nil, `{name}: description must be <= {Limits.MaxDescriptionLength} characters`
		end
	end
	if not finite(def.cooldown) or def.cooldown < MIN_REGISTERED_COOLDOWN or def.cooldown > MAX_COOLDOWN then
		return nil, `{name}: cooldown must be {MIN_REGISTERED_COOLDOWN}..{MAX_COOLDOWN} seconds`
	end
	if type(def.audited) ~= "boolean" or type(def.confirm) ~= "boolean" then
		return nil, `{name}: audited and confirm must be booleans`
	end
	if def.studioOnly ~= nil and type(def.studioOnly) ~= "boolean" then
		return nil, `{name}: studioOnly must be a boolean`
	end
	if type(def.args) ~= "table" or getmetatable(def.args) ~= nil then
		return nil, `{name}: args must be a plain table`
	end
	local args: { [string]: ArgSpec } = {}
	local count = 0
	for key, spec in def.args :: { [unknown]: unknown } do
		count += 1
		if count > Limits.MaxArgs - 1 then -- one slot stays free for the target's userId
			return nil, `{name}: too many args`
		end
		if type(key) ~= "string" or #key > 32 or string.find(key, "^[%a][%w_]*$") == nil then
			return nil, `{name}: arg names must match [A-Za-z][A-Za-z0-9_]*`
		end
		if key == "userId" then
			return nil, `{name}: 'userId' is reserved for the target`
		end
		local normalized, err = normalizeSpec(key, spec)
		if normalized == nil then
			return nil, `{name}: {err}`
		end
		args[key] = normalized
	end
	local argOrder: { string }? = nil
	if def.argOrder ~= nil then
		if type(def.argOrder) ~= "table" then
			return nil, `{name}: argOrder must be a list`
		end
		local order: { string } = {}
		local seen: { [string]: boolean } = {}
		for _, key in def.argOrder do
			if type(key) ~= "string" or args[key] == nil or seen[key] then
				return nil, `{name}: argOrder must list each arg once`
			end
			seen[key] = true
			table.insert(order, key)
		end
		if #order ~= count then
			return nil, `{name}: argOrder must list every arg`
		end
		argOrder = table.freeze(order)
	end
	local color = if type(def.color) == "string"
			and #def.color <= 16
			and string.find(def.color, "^%a+$") ~= nil
		then def.color
		else nil
	local order = if finite(def.order) then def.order else 100
	local normalized: CommandDef = {
		name = name,
		tab = def.tab,
		label = label,
		description = description,
		target = def.target,
		args = table.freeze(args),
		argOrder = argOrder,
		cooldown = def.cooldown,
		audited = def.audited,
		confirm = def.confirm,
		color = color,
		studioOnly = def.studioOnly,
		provider = nil,
		order = order,
	}
	table.freeze(normalized :: any)
	return normalized, nil
end

return table.freeze(AdminValidate)
