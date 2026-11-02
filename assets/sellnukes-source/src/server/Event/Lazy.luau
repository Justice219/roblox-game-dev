--!strict
--[[
	Lazy — guarded, cached, lazy requires of OTHER builders' server services for the Harvest Feast,
	leaderboard and badge services (B11).

	Why: those services are built in parallel (pets B9, tycoon B3/B5, admin B14, analytics B13) and
	may be missing, half-written or fail to load. Requiring them at module top level could also form
	require cycles (PetService ↔ EventService). Every call site therefore asks through here at CALL
	time: a missing / broken module yields nil (warned once) and the feature degrades gracefully
	("coming soon") instead of breaking the boot.

	API:
		Lazy.service(name)                    -> table? (Server/Services/<name> or "Tycoon/PlotService", cached)
		Lazy.fn(name, field)                  -> function? (service[field] when it is a function)
		Lazy.analytics(family, player, key, amount?)  AnalyticsService.<family>(...) — never errors,
		                                      never yields (a missing analytics service is skipped)
		Lazy.registerIds(kind, isValid)       AnalyticsService.registerIds (guarded)
		Lazy.registerAdmin(def, handler)      AdminService.registerCommand (guarded) -> boolean
		Lazy.hubLayout()                      Shared/Config/HubLayout (B8e) or {} (cached once loaded)

	Example:
		local grantPet = Lazy.fn("PetService", "grantPet")
		if grantPet == nil then return "comingSoon" end
		Lazy.analytics("event", player, "turkey:collect")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Lazy = {}

-- name -> resolved module table, or false when it is missing / failed (not retried).
local cache: { [string]: any } = {}

--[[
	The service module or nil (missing, not a ModuleScript, failed to load, not a table). A bare
	name lives in Server/Services ("PetService"); a slash path resolves from Server, like the boot
	list's feature paths ("Tycoon/PlotService"). Cached either way; a failure is warned once.
]]
function Lazy.service(name: string): any
	local cached = cache[name]
	if cached ~= nil then
		return if cached == false then nil else cached
	end
	local root = ServerScriptService:FindFirstChild("Server")
	local module: Instance? = nil
	if root ~= nil then
		if string.find(name, "/", 1, true) == nil then
			local services = root:FindFirstChild("Services")
			module = if services ~= nil then services:FindFirstChild(name) else nil
		else
			module = root
			for _, segment in string.split(name, "/") do
				module = if module ~= nil then module:FindFirstChild(segment) else nil
			end
		end
	end
	if module == nil or not module:IsA("ModuleScript") then
		cache[name] = false
		return nil
	end
	local ok, result = pcall(require, module)
	if not ok or type(result) ~= "table" then
		warn(`[Lazy] {name} could not be loaded ({result}); its Harvest Feast / leaderboard hooks are off`)
		cache[name] = false
		return nil
	end
	cache[name] = result
	return result
end

--[[ `Services/<name>.<field>` when it exists and is a function, else nil. ]]
function Lazy.fn(name: string, field: string): any
	local service = Lazy.service(name)
	if service == nil then
		return nil
	end
	local value = service[field]
	return if type(value) == "function" then value else nil
end

--[[
	Counts an analytics key in a family (AnalyticsConfig.RecorderKeys), e.g.
	Lazy.analytics("event", player, "sticker:7"). Never errors or yields.
]]
function Lazy.analytics(family: string, player: Player?, key: string, amount: number?)
	local recorder = Lazy.fn("AnalyticsService", family)
	if recorder ~= nil then
		pcall(recorder, player, key, amount)
	end
end

--[[ Registers an analytics id kind (exact key validation for "<kind>" placeholders). ]]
function Lazy.registerIds(kind: string, isValid: (id: string) -> boolean)
	local register = Lazy.fn("AnalyticsService", "registerIds")
	if register ~= nil then
		pcall(register, kind, isValid)
	end
end

--[[
	Registers an owner-admin command with B14's AdminService (spec §14). The def follows
	AdminConfig.CommandDef; the handler gets ctx { player, target = { player }?, args } and returns
	(ok, message).
	@return true when AdminService accepted it
]]
function Lazy.registerAdmin(def: { [string]: any }, handler: (ctx: any) -> (boolean, string)): boolean
	local register = Lazy.fn("AdminService", "registerCommand")
	if register == nil then
		return false
	end
	local ok, err = pcall(register, def, handler)
	if not ok then
		warn(`[Lazy] admin command {def.name} not registered: {err}`)
	end
	return ok
end

local hubLayoutCache: { [string]: any }? = nil
local hubLayoutFailedAt = -math.huge
-- A HubLayout that failed to load is retried at most this often (no warn spam from 1 Hz loops).
local HUB_LAYOUT_RETRY_SECONDS = 60

--[[
	The hub art builder's layout table (Shared/Config/HubLayout, B8e) or {} while it does not exist
	or fails to load (retried at most every HUB_LAYOUT_RETRY_SECONDS). Cached once loaded.
]]
function Lazy.hubLayout(): { [string]: any }
	if hubLayoutCache ~= nil then
		return hubLayoutCache
	end
	if os.clock() - hubLayoutFailedAt < HUB_LAYOUT_RETRY_SECONDS then
		return {}
	end
	local module = ReplicatedStorage.Shared.Config:FindFirstChild("HubLayout")
	if module ~= nil and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then
			hubLayoutCache = result
			return result
		end
		warn(`[Lazy] HubLayout failed to load: {result}`)
	end
	hubLayoutFailedAt = os.clock()
	return {}
end

return Lazy
