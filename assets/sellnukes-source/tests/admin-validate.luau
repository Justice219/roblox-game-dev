--!strict
--[[
	Admin argument / definition validation regressions (spec §14 "strict arg schema"). Run:
		lune run tests/admin-validate

	Proves on the shipped Server/Admin/AdminValidate + Shared/Config/AdminConfig:
	  1. Every built-in command accepts a well-formed argument table (incl. the target userId).
	  2. Per-key fuzz on every built-in: NaN, ±inf, wrong types, tables, huge strings, NUL /
	     control characters, invalid UTF-8, below-min / above-max, fractional integers, missing
	     required keys — all rejected; boundary values accepted.
	  3. Table shape: non-tables, metatables, extra / unknown keys, numeric keys, more than
	     Limits.MaxArgs keys — all rejected.
	  4. Random fuzz (deterministic seed, 4,000 tables): validateArgs never throws, and anything it
	     accepts has only schema keys whose values re-validate.
	  5. Kind specifics: text trimming / allowEmpty, code upper-casing, banDuration permanent /
	     minimum, enum allowlist exactness.
	  6. validateDef: a good registration is normalised + frozen; every malformed def is rejected
	     with a reason.
	  7. sanitizeForLog: control characters, invalid UTF-8, length caps.
	  8. AdminConfig integrity: every command has a valid shape, names sorted, defs frozen.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local AdminValidate = loader.load("src/server/Admin/AdminValidate")
local AdminConfig = loader.load("src/shared/Config/AdminConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local nan = 0 / 0
local inf = math.huge
local Limits = AdminConfig.Limits

-- A valid value for a spec.
local function goodValue(spec: any): any
	if spec.kind == "integer" or spec.kind == "number" then
		return spec.min
	elseif spec.kind == "text" then
		return "hello"
	elseif spec.kind == "enum" then
		return spec.values[1]
	elseif spec.kind == "boolean" then
		return true
	elseif spec.kind == "banDuration" then
		return 86400
	elseif spec.kind == "code" then
		return "abc123"
	end
	error("unknown kind " .. tostring(spec.kind))
end

-- A valid args table for a def (every arg, optional ones included, + the target key).
local function goodArgs(def: any): { [string]: any }
	local args: { [string]: any } = {}
	for key, spec in def.args do
		args[key] = goodValue(spec)
	end
	if def.target == "Player" or def.target == "AnyUser" then
		args.userId = 12345
	end
	return args
end

-- 1 + 2. Every built-in: good args accepted, per-key junk rejected.
local junk: { any } = {
	nan,
	inf,
	-inf,
	{},
	setmetatable({}, {}),
	function() end,
	string.rep("x", 100000),
	"a\0b",
	"\255\254",
	"bad\ncontrol",
	true,
	"12",
}
local defsChecked = 0
for _, name in AdminConfig.CommandNames do
	local def = AdminConfig.Commands[name]
	local args = goodArgs(def)
	local parsed, err = AdminValidate.validateArgs(def, args)
	check(parsed ~= nil, `{name}: good args accepted ({err})`)
	defsChecked += 1

	-- nil raw = {} (commands without required args only).
	local hasRequired = def.target ~= "None"
	for _, spec in def.args do
		if spec.optional ~= true then
			hasRequired = true
		end
	end
	local emptyOk = AdminValidate.validateArgs(def, nil) ~= nil
	check(emptyOk == not hasRequired, `{name}: nil args accepted only without required args`)

	local schemaKeys: { [string]: any } = table.clone(def.args)
	if def.target ~= "None" then
		schemaKeys.userId = { kind = "integer", min = 1, max = Limits.MaxUserId }
	end
	for key, spec in schemaKeys do
		for _, bad in junk do
			-- Some junk is valid for some kinds ("12" is fine text; true is a valid boolean).
			local okForKind = false
			if spec.kind == "text" and type(bad) == "string" then
				okForKind = AdminValidate.validateValue(spec, bad) ~= nil
			else
				okForKind = (spec.kind == "boolean" and type(bad) == "boolean") or (spec.kind == "code" and bad == "12")
			end
			local trial = table.clone(args)
			trial[key] = bad
			local result = AdminValidate.validateArgs(def, trial)
			check((result ~= nil) == okForKind, `{name}.{key}: junk {typeof(bad)} handled`)
		end
		-- Missing required key.
		if spec.optional ~= true then
			local trial = table.clone(args)
			trial[key] = nil
			check(AdminValidate.validateArgs(def, trial) == nil, `{name}.{key}: missing required rejected`)
		end
		-- Numeric boundaries.
		if spec.kind == "integer" or spec.kind == "number" then
			local trial = table.clone(args)
			trial[key] = spec.max
			check(AdminValidate.validateArgs(def, trial) ~= nil, `{name}.{key}: max accepted`)
			trial[key] = spec.max + math.max(1, math.abs(spec.max) * 1e-6)
			check(AdminValidate.validateArgs(def, trial) == nil, `{name}.{key}: above max rejected`)
			trial[key] = spec.min - 1
			check(AdminValidate.validateArgs(def, trial) == nil, `{name}.{key}: below min rejected`)
			if spec.kind == "integer" and spec.max - spec.min >= 1 then
				trial[key] = spec.min + 0.5
				check(AdminValidate.validateArgs(def, trial) == nil, `{name}.{key}: fraction rejected`)
			end
		end
	end

	-- 3. Shape attacks.
	local extra = table.clone(args)
	extra.sneaky = 1
	check(AdminValidate.validateArgs(def, extra) == nil, `{name}: extra key rejected`)
	local numeric = table.clone(args)
	numeric[1] = 1
	check(AdminValidate.validateArgs(def, numeric) == nil, `{name}: numeric key rejected`)
	check(AdminValidate.validateArgs(def, setmetatable(table.clone(args), {})) == nil, `{name}: metatable rejected`)
	check(AdminValidate.validateArgs(def, "args") == nil, `{name}: string args rejected`)
	check(AdminValidate.validateArgs(def, 5) == nil, `{name}: number args rejected`)
	local many = table.clone(args)
	for index = 1, Limits.MaxArgs + 1 do
		many[`k{index}`] = index
	end
	check(AdminValidate.validateArgs(def, many) == nil, `{name}: too many keys rejected`)
end
check(defsChecked == #AdminConfig.CommandNames, "every built-in checked")

-- 4. Random fuzz.
local rng = Loader.Random.new(20261030)
local function randomValue(depth: number): any
	local roll = rng:NextInteger(1, 12)
	if roll == 1 then
		return rng:NextNumber(-1e12, 1e12)
	elseif roll == 2 then
		return rng:NextInteger(-5, 200)
	elseif roll == 3 then
		return nan
	elseif roll == 4 then
		return if rng:NextNumber() < 0.5 then inf else -inf
	elseif roll == 5 then
		local chars = {}
		for index = 1, rng:NextInteger(0, 40) do
			chars[index] = string.char(rng:NextInteger(0, 255))
		end
		return table.concat(chars)
	elseif roll == 6 then
		return rng:NextNumber() < 0.5
	elseif roll == 7 and depth < 2 then
		return { randomValue(depth + 1) }
	elseif roll == 8 then
		return "Player"
	elseif roll == 9 then
		return 2 ^ 53
	elseif roll == 10 then
		return -1
	elseif roll == 11 then
		return 86400
	end
	return "cash2x"
end
local keyPool = {
	"userId",
	"amount",
	"area",
	"rebirths",
	"reason",
	"durationSeconds",
	"text",
	"hour",
	"boost",
	"minutes",
	"count",
	"code",
	"gems",
	"spins",
	"cashSeconds",
	"hours",
	"seconds",
	"product",
	"x",
	"",
}
local accepted = 0
for _ = 1, 4000 do
	local name = AdminConfig.CommandNames[rng:NextInteger(1, #AdminConfig.CommandNames)]
	local def = AdminConfig.Commands[name]
	local raw: { [any]: any } = {}
	for _ = 1, rng:NextInteger(0, 5) do
		raw[keyPool[rng:NextInteger(1, #keyPool)]] = randomValue(0)
	end
	local ok, parsed = pcall(AdminValidate.validateArgs, def, raw)
	check(ok, `fuzz: validateArgs never throws ({name})`)
	if parsed ~= nil then
		accepted += 1
		for key, value in parsed do
			local spec = def.args[key]
			if key == "userId" then
				check(type(value) == "number" and value >= 1 and value % 1 == 0, "fuzz: userId sane")
			else
				check(spec ~= nil, `fuzz: accepted key {key} is in the schema`)
				check(AdminValidate.validateValue(spec, value) ~= nil, `fuzz: accepted {key} re-validates`)
			end
		end
	end
end
check(accepted > 0, "fuzz accepted some well-formed tables")

-- 5. Kind specifics.
local textSpec = { kind = "text", maxLength = 5 }
check(AdminValidate.validateValue(textSpec, "  hey  ") == "hey", "text trimmed")
check(AdminValidate.validateValue(textSpec, "   ") == nil, "blank text rejected")
check(AdminValidate.validateValue({ kind = "text", maxLength = 5, allowEmpty = true }, "  ") == "", "allowEmpty")
check(AdminValidate.validateValue(textSpec, "123456") == nil, "text over maxLength")
check(AdminValidate.validateValue(textSpec, "héllo") == "héllo", "UTF-8 counted in characters")
check(AdminValidate.validateValue(textSpec, "a\194\133b") == nil, "C1 control rejected")
check(AdminValidate.validateValue({ kind = "code", maxLength = 20 }, " nukes1 ") == "NUKES1", "code upper-cased")
check(AdminValidate.validateValue({ kind = "code", maxLength = 20 }, "no-dash") == nil, "code alnum only")
local ban = { kind = "banDuration" }
check(
	AdminValidate.validateValue(ban, -1) == (if AdminConfig.AllowPermanentBans then -1 else nil),
	"permanent ban rule"
)
check(AdminValidate.validateValue(ban, 59) == nil, "ban below minimum")
check(AdminValidate.validateValue(ban, Limits.BanMaxSeconds) == Limits.BanMaxSeconds, "ban max")
check(AdminValidate.validateValue(ban, 0) == nil, "zero-length ban rejected")
check(AdminValidate.validateValue({ kind = "enum", values = { "a", "b" } }, "A") == nil, "enum exact")
check(AdminValidate.validateValue({ kind = "integer", min = -2, max = 2, nonZero = true }, 0) == nil, "nonZero")
check(AdminValidate.validateValue({ kind = "boolean" }, false) == false, "boolean false accepted")
check(AdminValidate.validateValue({ kind = "mystery" } :: any, 1) == nil, "unknown kind rejected")

-- 6. validateDef.
local function goodDef(): { [string]: any }
	return {
		name = "GivePet",
		tab = "Players",
		label = "Give Pet",
		description = "Gives a pet",
		target = "Player",
		args = {
			petId = { kind = "enum", values = { "Cat", "Dog" }, labels = { "Cat", "Dog" }, label = "Pet" },
			count = { kind = "integer", min = 1, max = 50, presets = { 1, 5 }, format = "count", default = 1 },
		},
		argOrder = { "petId", "count" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "purple",
		order = 60,
		junkField = "ignored",
	}
end
local def, defErr = AdminValidate.validateDef(goodDef())
check(def ~= nil, `good def accepted ({defErr})`)
check(table.isfrozen(def) and table.isfrozen(def.args) and table.isfrozen(def.args.petId), "def deep-frozen")
check(table.isfrozen(def.args.petId.values), "enum values frozen")
check((def :: any).junkField == nil, "unknown fields dropped")
check(def.args.count.default == 1, "valid default kept")
local registeredArgs, _ = AdminValidate.validateArgs(def, { userId = 9, petId = "Dog", count = 3 })
check(registeredArgs ~= nil and registeredArgs.petId == "Dog", "registered def validates args")

local function rejects(mutate: (d: { [string]: any }) -> (), label: string)
	local d = goodDef()
	mutate(d)
	local result, reason = AdminValidate.validateDef(d)
	check(result == nil and type(reason) == "string", `validateDef rejects: {label}`)
end
rejects(function(d)
	d.name = "1bad"
end, "name starting with a digit")
rejects(function(d)
	d.name = "bad name"
end, "name with a space")
rejects(function(d)
	d.name = string.rep("a", 33)
end, "long name")
rejects(function(d)
	d.tab = "Live"
end, "read-only tab")
rejects(function(d)
	d.tab = "Meta"
end, "Meta tab")
rejects(function(d)
	d.target = "Everyone"
end, "bad target")
rejects(function(d)
	d.label = ""
end, "empty label")
rejects(function(d)
	d.cooldown = 0.1
end, "tiny cooldown")
rejects(function(d)
	d.cooldown = nan
end, "NaN cooldown")
rejects(function(d)
	d.audited = "yes"
end, "non-boolean audited")
rejects(function(d)
	d.args.userId = { kind = "integer", min = 1, max = 2 }
end, "reserved userId arg")
rejects(function(d)
	d.args.petId.values = { "Cat", "Cat" }
	d.args.petId.labels = nil
end, "duplicate enum values")
rejects(function(d)
	local many = {}
	for index = 1, Limits.MaxEnumValues + 1 do
		many[index] = `v{index}`
	end
	d.args.petId.values = many
	d.args.petId.labels = nil
end, "too many enum values")
rejects(function(d)
	d.args.petId.labels = { "Cat" }
end, "labels length mismatch")
rejects(function(d)
	d.args.count.min = 10
	d.args.count.max = 1
end, "min > max")
rejects(function(d)
	d.args.count.max = inf
end, "infinite max")
rejects(function(d)
	d.args.count.presets = { 999 }
end, "preset outside range")
rejects(function(d)
	d.args.count.kind = "lua"
end, "unknown arg kind")
rejects(function(d)
	d.argOrder = { "petId" }
end, "argOrder missing an arg")
rejects(function(d)
	d.args = setmetatable({}, {})
end, "args with a metatable")
rejects(function(d)
	for index = 1, Limits.MaxArgs do
		d.args[`a{index}`] = { kind = "boolean" }
	end
	d.argOrder = nil
end, "too many args")
check(AdminValidate.validateDef("nope") == nil, "non-table def rejected")

-- 7. sanitizeForLog.
check(AdminValidate.sanitizeForLog("a\n\tb", 10) == "a b", "control chars collapsed")
check(AdminValidate.sanitizeForLog("\255", 10) == "<invalid text>", "invalid UTF-8 replaced")
check(AdminValidate.sanitizeForLog(string.rep("x", 50), 10) == string.rep("x", 10) .. "…", "cut with ellipsis")
check(#AdminValidate.sanitizeForLog(string.rep("é", 1e5), 20) < 100, "huge input cut cheaply")
check(AdminValidate.sanitizeForLog(42, 10) == "42", "numbers stringified")
check(AdminValidate.summarizeArgs({ b = 2, a = "x\ny" }) == "a=x y b=2", "summarizeArgs sorted + sanitised")

-- 8. AdminConfig integrity.
local tabs: { [string]: boolean } = { Meta = true }
for _, tab in AdminConfig.Tabs do
	tabs[tab.key] = true
end
for _, name in AdminConfig.CommandNames do
	local d = AdminConfig.Commands[name]
	check(d.name == name, `{name}: name matches key`)
	check(tabs[d.tab] == true, `{name}: tab exists`)
	check(d.cooldown >= 0 and d.cooldown == d.cooldown, `{name}: cooldown sane`)
	check(table.isfrozen(d) and table.isfrozen(d.args), `{name}: frozen`)
	local count = 0
	for key, spec in d.args do
		count += 1
		check(key ~= "userId", `{name}: no userId arg`)
		if spec.kind == "integer" or spec.kind == "number" then
			check(spec.min ~= nil and spec.max ~= nil and spec.min <= spec.max, `{name}.{key}: bounds`)
		end
		if spec.kind == "enum" then
			check(#spec.values >= 1, `{name}.{key}: enum values`)
		end
	end
	check(count < Limits.MaxArgs, `{name}: arg count`)
	if d.argOrder ~= nil then
		check(#d.argOrder == count, `{name}: argOrder complete`)
	end
end

-- 9. World* commands (owner R57 World 2, spec §13): the `world` enum is exactly the extra worlds
-- (WorldsConfig.Order minus "main", in order, labelled with their names); WorldSend alone adds
-- Nuke Town; area bounds follow the largest extra world.
do
	local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
	local extraIds: { string } = {}
	local maxAreas = 1
	for _, def in WorldsConfig.extra() do
		table.insert(extraIds, def.id)
		maxAreas = math.max(maxAreas, def.geometry.areaCount)
	end
	local worldCommands = 0
	for _, name in AdminConfig.CommandNames do
		if string.sub(name, 1, 5) ~= "World" then
			continue
		end
		worldCommands += 1
		local d = AdminConfig.Commands[name]
		local spec = d.args.world
		if name == "WorldOfflinePreview" then
			check(spec == nil, "WorldOfflinePreview covers every world (no world arg)")
			continue
		end
		check(spec ~= nil and spec.kind == "enum" and spec.optional ~= true, `{name}: required world enum`)
		local expected = if name == "WorldSend" then WorldsConfig.Order else extraIds
		check(#spec.values == #expected, `{name}: world count`)
		for index, worldId in expected do
			check(spec.values[index] == worldId, `{name}: world {index} = {worldId}`)
			check(spec.labels[index] == WorldsConfig.get(worldId).name, `{name}: label of {worldId}`)
		end
		if name ~= "WorldSend" then
			check(table.find(spec.values, "main") == nil, `{name}: never targets Nuke Town`)
		end
		check(table.isfrozen(spec.values) and table.isfrozen(spec.labels), `{name}: enum frozen`)
		-- validateArgs accepts every listed world and refuses anything else.
		local args = goodArgs(d)
		for _, worldId in spec.values do
			local trial = table.clone(args)
			trial.world = worldId
			check(AdminValidate.validateArgs(d, trial) ~= nil, `{name}: {worldId} accepted`)
		end
		for _, bad in { "nope", "MAIN", "dino ", 1 } :: { any } do
			local trial = table.clone(args)
			trial.world = bad
			check(AdminValidate.validateArgs(d, trial) == nil, `{name}: {tostring(bad)} refused`)
		end
	end
	check(worldCommands == 14, "14 World* commands (spec §13)")
	check(AdminConfig.Commands.WorldSetArea.args.area.max == maxAreas, "WorldSetArea max = largest extra world")
	check(AdminConfig.Commands.WorldSend.args.to.values[1] == "spawn", "WorldSend: spawn first")
	check(#AdminConfig.Commands.WorldSend.args.to.values == 2, "WorldSend: spawn / plot only")
end

print(`[admin-validate] {checks} checks passed ({defsChecked} commands, {accepted} fuzz tables accepted)`)
