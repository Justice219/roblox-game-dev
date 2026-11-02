--!strict
--[[
	AdminRegistry — the command allowlist + handlers of the admin system (spec §14; owner rule 9
	"every system is controllable from the owner-only admin panel").

	Three ways a command gets a handler:
		1. Built-in (AdminService's own Handlers/*): `setBuiltin(name, handler, probe?)` for every
		   AdminConfig command. `probe()` returns a reason string while the seam it drives is
		   missing (e.g. "needs Tycoon (B5 TycoonAdmin)"); the command is then refused and the
		   panel shows it greyed with that reason.
		2. Provided: `registerHandler(name, handler)` — another system supplies the handler of an
		   AdminConfig command that declares a `provider` (overrides any built-in pull handler).
		3. Registered: `registerCommand(def, handler)` — a NEW command declared by a later system
		   (pets, attack, event). The def is validated (AdminValidate.validateDef) and stored as a
		   deep-frozen normalised copy; a name clash errors. Allowed any time (the catalogue
		   version bumps and admins receive the new command on their next push).

	The allowlist is exactly the AdminConfig commands + the registered ones: `isKnown(name)` is
	checked with rawget on string names only, so no client value can ever reach a handler that is
	not declared here.

	Pure (AdminConfig + AdminValidate only): tests/admin-pipeline.luau drives it under Lune.

	Connects to: Server/Admin/AdminPipeline (get / isKnown / availability), Server/Admin/
	AdminStatePush (catalog / version), Server/Admin/Handlers/* (setBuiltin),
	Server/Services/AdminService (registerCommand / registerHandler facade).

	Example:
		local registry = AdminRegistry.new()
		registry.setBuiltin("GrantGems", grantGems)
		registry.registerCommand({ name = "GivePet", tab = "Players", ... }, givePet)
		print(registry.availability("GivePet", true)) --> ""
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local AdminValidate = require(script.Parent.AdminValidate)

type CommandDef = AdminConfig.CommandDef
type CommandInfo = AdminConfig.CommandInfo

export type Caller = { userId: number, name: string, player: Player? }
export type Target = { userId: number?, player: Player?, label: string }
export type Context = {
	caller: Caller,
	args: AdminValidate.ValidatedArgs,
	target: Target,
}
-- A handler returns (ok, human message). It may yield; errors are caught by the pipeline.
export type Handler = (ctx: Context) -> (boolean, string)
-- Returns nil when the command can run, else the reason it cannot (shown on the greyed button).
export type Probe = () -> string?

type Entry = {
	def: CommandDef,
	builtin: Handler?,
	probe: Probe?,
	provided: Handler?,
	registered: boolean,
}

export type Registry = {
	setBuiltin: (name: string, handler: Handler, probe: Probe?) -> (),
	registerHandler: (name: string, handler: Handler) -> (),
	registerCommand: (def: unknown, handler: Handler) -> CommandDef,
	isKnown: (name: unknown) -> boolean,
	get: (name: string) -> (CommandDef?, Handler?),
	availability: (name: string, isStudio: boolean) -> string,
	catalog: (isStudio: boolean) -> { CommandInfo },
	names: () -> { string },
	version: () -> number,
	missingBuiltins: () -> { string },
}

local AdminRegistry = {}

-- Default button colour per tab (AdminConfig.Tabs).
local TAB_COLORS: { [string]: string } = {}
for _, tab in AdminConfig.Tabs do
	TAB_COLORS[tab.key] = tab.color
end

-- The argument display order of a def (argOrder, else sorted keys).
local function orderOf(def: CommandDef): { string }
	if def.argOrder ~= nil then
		return def.argOrder
	end
	local keys: { string } = {}
	for key in def.args do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

--[[
	Creates a registry seeded with every AdminConfig command (no handlers yet).
	@return the Registry API (see the type)
]]
function AdminRegistry.new(): Registry
	local entries: { [string]: Entry } = {}
	local order: { string } = {}
	local catalogVersion = 0

	for _, name in AdminConfig.CommandNames do
		entries[name] = {
			def = AdminConfig.Commands[name],
			builtin = nil,
			probe = nil,
			provided = nil,
			registered = false,
		}
		table.insert(order, name)
	end

	local registry = {} :: Registry

	--[[ Installs the built-in handler (and optional seam probe) of an AdminConfig command. ]]
	function registry.setBuiltin(name: string, handler: Handler, probe: Probe?)
		local entry = entries[name]
		if entry == nil or entry.registered then
			error(`[AdminRegistry] setBuiltin: {name} is not an AdminConfig command`, 2)
		end
		if type(handler) ~= "function" then
			error(`[AdminRegistry] setBuiltin: {name} needs a handler function`, 2)
		end
		entry.builtin = handler
		entry.probe = probe
		catalogVersion += 1
	end

	--[[
		Supplies the handler of an AdminConfig command that declares a `provider` (a system owns
		it). Overrides the built-in pull handler / probe.
		Example: AdminService.registerHandler("GrantSpins", function(ctx) ... end)
	]]
	function registry.registerHandler(name: string, handler: Handler)
		local entry = if type(name) == "string" then entries[name] else nil
		if entry == nil or entry.registered or entry.def.provider == nil then
			error(`[AdminRegistry] registerHandler: {tostring(name)} is not a provider command in AdminConfig`, 2)
		end
		if type(handler) ~= "function" then
			error(`[AdminRegistry] registerHandler: {name} needs a handler function`, 2)
		end
		entry.provided = handler
		catalogVersion += 1
	end

	--[[
		Adds a NEW command from another system. Validates the def (AdminValidate.validateDef) and
		errors with the reason if it is malformed or the name is taken.
		@return the normalised, frozen def that is now live
	]]
	function registry.registerCommand(rawDef: unknown, handler: Handler): CommandDef
		local def, err = AdminValidate.validateDef(rawDef)
		if def == nil then
			error(`[AdminRegistry] registerCommand rejected: {err}`, 2)
		end
		if type(handler) ~= "function" then
			error(`[AdminRegistry] registerCommand: {def.name} needs a handler function`, 2)
		end
		if entries[def.name] ~= nil then
			error(`[AdminRegistry] registerCommand: {def.name} already exists`, 2)
		end
		entries[def.name] = { def = def, builtin = handler, probe = nil, provided = nil, registered = true }
		table.insert(order, def.name)
		catalogVersion += 1
		return def
	end

	--[[ True only for a declared command name (string, rawget: no metatable tricks). ]]
	function registry.isKnown(name: unknown): boolean
		return type(name) == "string" and rawget(entries :: any, name) ~= nil
	end

	--[[ The def and its effective handler (provided > built-in), or nil. ]]
	function registry.get(name: string): (CommandDef?, Handler?)
		local entry = rawget(entries :: any, name) :: Entry?
		if entry == nil then
			return nil, nil
		end
		return entry.def, entry.provided or entry.builtin
	end

	--[[
		"" when the command can run now, else the reason: "Studio only", the probe's reason,
		"needs <provider>" or "not available".
	]]
	function registry.availability(name: string, isStudio: boolean): string
		local entry = rawget(entries :: any, name) :: Entry?
		if entry == nil then
			return "unknown command"
		end
		if entry.def.studioOnly == true and not isStudio then
			return "Studio only"
		end
		if entry.provided ~= nil then
			return ""
		end
		if entry.builtin ~= nil then
			local probe = entry.probe
			if probe ~= nil then
				local ok, reason = pcall(probe)
				if not ok then
					return "unavailable (seam check failed)"
				end
				if type(reason) == "string" and reason ~= "" then
					return reason
				end
			end
			return ""
		end
		local provider = entry.def.provider
		return if provider ~= nil then `needs {provider}` else "not available"
	end

	--[[
		The panel catalogue: every visible command (no Meta, no studioOnly outside Studio) as
		CommandInfo, in registration order (the panel sorts per tab).
	]]
	function registry.catalog(isStudio: boolean): { CommandInfo }
		local list: { CommandInfo } = {}
		for _, name in order do
			local entry = entries[name]
			local def = entry.def
			if def.tab == "Meta" or (def.studioOnly == true and not isStudio) then
				continue
			end
			table.insert(list, {
				name = def.name,
				tab = def.tab,
				label = def.label,
				description = def.description or "",
				target = def.target,
				args = def.args,
				argOrder = orderOf(def),
				confirm = def.confirm,
				color = def.color or TAB_COLORS[def.tab] or "blue",
				order = def.order or 100,
				registered = entry.registered,
			})
		end
		return list
	end

	--[[ Every allowlisted command name (AdminConfig + registered), in registration order. ]]
	function registry.names(): { string }
		return table.clone(order)
	end

	--[[ Bumps on every handler / registration change (the state push resends the catalogue). ]]
	function registry.version(): number
		return catalogVersion
	end

	--[[ AdminConfig commands with no handler and no provider (a config / handler drift bug). ]]
	function registry.missingBuiltins(): { string }
		local missing: { string } = {}
		for _, name in order do
			local entry = entries[name]
			if
				not entry.registered
				and entry.builtin == nil
				and entry.provided == nil
				and entry.def.provider == nil
			then
				table.insert(missing, name)
			end
		end
		return missing
	end

	return registry
end

return table.freeze(AdminRegistry)
