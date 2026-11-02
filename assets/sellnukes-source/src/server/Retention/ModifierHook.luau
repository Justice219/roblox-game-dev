--!strict
--[[
	ModifierHook — registers B7's income modifier sources (personal boosts, the server boost) with
	B5's `Server/Tycoon/ModifierSources` (docs/tycoon-server.md) through a GUARDED lazy require, so
	B7 boots and works even if B5's module is missing or fails to load.

	B5 contract (committed f0379f9):
		ModifierSources.register(name, provider, { offline = false })
			provider(player, profile) -> (partial TycoonTypes.Modifiers, validUntil?)
			  validUntil = unix time the answer stops being true (B5 re-asks then)
			offline = false: excluded from offline earnings (timed boosts must never inflate them)
		ModifierSources.invalidate(player) / invalidateAll() — drop B5's cached modifiers when a
		boost starts / ends.

	Registrations made before ModifierSources is available are queued and retried on every
	`flush` (BoostService retries for the first minute after Start).

	Example:
		ModifierHook.register("personalBoosts", function(player, profile) return { boostCash = 2 }, expiresAt end)
		ModifierHook.invalidate(player) -- after a boost was granted
]]

local ServerScriptService = game:GetService("ServerScriptService")

export type Provider = (player: Player, profile: any) -> ({ [string]: number }?, number?)

local ModifierHook = {}

local pending: { { name: string, provider: Provider } } = {}
local registered: { [string]: boolean } = {}
local warned = false

-- B5's module, or nil while it does not exist / fails to load.
local function sources(): any
	local tycoon = ServerScriptService.Server:FindFirstChild("Tycoon")
	local module = if tycoon ~= nil then tycoon:FindFirstChild("ModifierSources") else nil
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" and type(result.register) == "function" then
		return result
	end
	return nil
end

--[[ Hands every pending registration to ModifierSources if it is available now. ]]
function ModifierHook.flush(): boolean
	if #pending == 0 then
		return true
	end
	local target = sources()
	if target == nil then
		if not warned then
			warned = true
			warn("[ModifierHook] Tycoon/ModifierSources not available yet; boosts will apply once it loads")
		end
		return false
	end
	for _, entry in pending do
		if not registered[entry.name] then
			-- Timed boosts never count toward offline earnings.
			local ok, err = pcall(target.register, entry.name, entry.provider, { offline = false })
			if ok then
				registered[entry.name] = true
			else
				warn(`[ModifierHook] register {entry.name} failed: {err}`)
			end
		end
	end
	table.clear(pending)
	return true
end

--[[ Queues a modifier provider and tries to register it at once. ]]
function ModifierHook.register(name: string, provider: Provider)
	table.insert(pending, { name = name, provider = provider })
	ModifierHook.flush()
end

--[[ Tells B5 a player's modifiers changed (no-op while ModifierSources is unavailable). ]]
function ModifierHook.invalidate(player: Player)
	local target = sources()
	if target ~= nil and type(target.invalidate) == "function" then
		pcall(target.invalidate, player)
	end
end

--[[ Tells B5 every player's modifiers changed (the server boost). ]]
function ModifierHook.invalidateAll()
	local target = sources()
	if target ~= nil and type(target.invalidateAll) == "function" then
		pcall(target.invalidateAll)
	end
end

--[[ True once `name` reached ModifierSources (diagnostics / tests). ]]
function ModifierHook.isRegistered(name: string): boolean
	return registered[name] == true
end

return ModifierHook
