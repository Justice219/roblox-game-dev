--!strict
--[[
	Seams — lazy, fail-safe lookups of the gameplay modules the admin commands drive.

	Why: AdminService must never require gameplay services at load time (B9 / B10 / B11 require
	AdminService from their own Start to register commands, so a top-level require back would be
	a cycle), and several seams may not exist yet while builders work in parallel (e.g. B5's
	Server/Tycoon/TycoonAdmin). Every lookup here:
		- runs only when a command executes / the panel asks for availability (after boot),
		- is pcall'd (a module that fails to load never breaks the admin panel),
		- is cached once found; a missing module is looked up again at most every RETRY seconds,
		  so a seam that ships later lights up without a server restart in Studio.

	Connects to: Server/Services/* (Retention, Playtime, LuckySpin, Boost, ServerBoost, Codes,
	GroupReward, NotifyReward, Analytics), Server/Tycoon/TycoonAdmin (B5), Server/Tycoon/WorldService
	(R57 worlds), Server/Admin/Handlers/*.

	Example:
		local found, added = Seams.call(Seams.service("LuckySpinService"), "grantSpins", player, 5)
		if not found then return false, "needs Retention (B7)" end
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Seams = {}

-- Seconds before a missing / broken module is looked up again.
local RETRY = 10

type CacheEntry = { value: any, checkedAt: number }

local cache: { [string]: CacheEntry } = {}

-- Requires ServerScriptService.Server.<folder>.<name> (pcall'd), or nil.
local function load(folder: string, name: string): any
	local server = ServerScriptService:FindFirstChild("Server")
	local parent = if server ~= nil then server:FindFirstChild(folder) else nil
	local module = if parent ~= nil then parent:FindFirstChild(name) else nil
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, value = pcall(require, module)
	if not ok then
		warn(`[Admin.Seams] {folder}.{name} failed to load: {value}`)
		return nil
	end
	return if type(value) == "table" then value else nil
end

-- Cached lookup with the retry rule (see the header).
local function lookup(folder: string, name: string): any
	local key = `{folder}/{name}`
	local entry = cache[key]
	if entry ~= nil and (entry.value ~= nil or os.clock() - entry.checkedAt < RETRY) then
		return entry.value
	end
	local value = load(folder, name)
	cache[key] = { value = value, checkedAt = os.clock() }
	return value
end

--[[
	A server service module by name (Server/Services/<name>), or nil when it does not exist /
	fails to load.
	Example: local ServerBoostService = Seams.service("ServerBoostService")
]]
function Seams.service(name: string): any
	return lookup("Services", name)
end

--[[ B5's Server/Tycoon/TycoonAdmin seam (setCash, setArea, unlockAll, resetPlot, setRebirths, rebuildPlot). ]]
function Seams.tycoonAdmin(): any
	return lookup("Tycoon", "TycoonAdmin")
end

--[[ R50's Server/Tycoon/Knockdown seam (adminKnock, forceRebuild, clearImmunity, setEnabled, ...). ]]
function Seams.knockdown(): any
	return lookup("Tycoon", "Knockdown")
end

--[[
	R57's Server/Tycoon/WorldService seam (worlds: unlock / relock, travel, kill switch, players per
	world) — the World* admin commands (Admin/Handlers/MultiWorldHandlers) drive it.
	Example: local found, ok = Seams.call(Seams.worldService(), "unlock", player, "dino", "admin")
]]
function Seams.worldService(): any
	return lookup("Tycoon", "WorldService")
end

--[[ True when `module` exists and has a function named `fnName`. ]]
function Seams.has(module: any, fnName: string): boolean
	return type(module) == "table" and type(module[fnName]) == "function"
end

--[[
	Calls module[fnName](...) when it exists.
	@return (true, ...results) when called, (false) when the function is missing
	Errors raised by the function propagate (the pipeline's pcall reports them as a failure).
	Example: local found, ok, msg = Seams.call(Seams.tycoonAdmin(), "setArea", player, 3)
]]
function Seams.call(module: any, fnName: string, ...: any): (boolean, ...any)
	if not Seams.has(module, fnName) then
		return false
	end
	return true, module[fnName](...)
end

--[[ Studio / tests: forget every cached lookup. ]]
function Seams.clearCache()
	table.clear(cache)
end

return table.freeze(Seams)
