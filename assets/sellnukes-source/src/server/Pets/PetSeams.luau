--!strict
--[[
	PetSeams — guarded, cached, lazy access to OTHER builders' modules from the pets / eggs / crates
	services (same idea as B11's Server/Event/Lazy).

	Why: those modules are built in parallel and some require pets back (EventService →
	PetService.grantPet), so requiring them at top level could break the boot or form a require
	cycle. Every call site asks through here at CALL time; a missing / broken module yields nil
	(warned once) and the pets feature keeps working without that hook.

	Seams:
		analytics(family, player, key, amount?)   AnalyticsService.<family> (pets / crates)
		eggHatched(player, eggId, results, auto)  AnalyticsService.eggHatched
		crateOpened(player, crateId, pay, rewards) AnalyticsService.crateOpened
		registerIds(kind, isValid)                AnalyticsService.registerIds (exact key checks)
		registerAdmin(def, handler) -> boolean    AdminService.registerCommand (B14)
		registerAdminCommands(entries, n, dt)     the same, retrying refused ones (boot order)
		registerModifier(name, provider)          Tycoon/ModifierSources.register (B5)
		invalidateModifiers(player)               Tycoon/ModifierSources.invalidate
		registerItemGranter(kind, fn)             Retention/RewardGrant.registerItemGranter (B7)
		rewardGrant() -> grant?                   Retention/RewardGrant.grant (B7; R78 Index claims)
		eventActive() -> boolean?                 EventService.isActive (B11; nil = unknown)
		onEventChanged(callback) -> boolean       EventService.ActiveChanged (B11)
		acornsOf(player) / spendAcorns(...)       EventService.getAcorns / trySpendAcorns (B11)
		hubAnchors() -> anchors?                  Shared/Config/HubLayout.anchors (B8e)
		worldHubAnchors(worldId) -> anchors?      a world's hub layout anchors (R57: Dino Valley =
		                                          Worlds/Dino/ValleyLayout, W9; WORLD-LOCAL)
		meshLibrary() -> module?                  World/MeshLibrary (B4)

	Never errors, never yields (except meshLibrary().spawn, which the caller runs in a task).

	Connects to: Server/Services/{PetService, CrateService}, Server/Pets/{EggStands, TrailRenderer}.

	Example:
		PetSeams.analytics("pets", player, "equipBest")
		PetSeams.invalidateModifiers(player)
		local stand = PetSeams.hubAnchors().EggStands[3]
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Shared config only (no builder module): safe to require at load.
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local PetSeams = {}

-- path → resolved module, or false when missing / failed (never retried; warned once).
local cache: { [string]: any } = {}

-- Requires `root.<a>.<b>...` lazily (nil when any step is missing or the require fails).
local function lazy(root: Instance, path: { string }): any
	local key = `{root.Name}/{table.concat(path, "/")}`
	local cached = cache[key]
	if cached ~= nil then
		return if cached == false then nil else cached
	end
	local node: Instance? = root
	for _, name in path do
		node = if node ~= nil then node:FindFirstChild(name) else nil
	end
	if node == nil or not node:IsA("ModuleScript") then
		-- Not there yet (another builder's file): try again later, quietly.
		return nil
	end
	local ok, result = pcall(require, node)
	if not ok or type(result) ~= "table" then
		warn(`[PetSeams] {key} could not be loaded ({result}); its pets hook is off`)
		cache[key] = false
		return nil
	end
	cache[key] = result
	return result
end

-- The server root folder (ServerScriptService.Server).
local function server(): Instance?
	return ServerScriptService:FindFirstChild("Server")
end

-- A function field of a lazily required server module, or nil.
local function serverFn(path: { string }, field: string): any
	local root = server()
	if root == nil then
		return nil
	end
	local module = lazy(root, path)
	if module == nil then
		return nil
	end
	local value = module[field]
	return if type(value) == "function" then value else nil
end

--------------------------------------------------------------------------------------------------
-- Analytics (B13)
--------------------------------------------------------------------------------------------------

--[[ Counts `key` in an analytics family (pets / crates). Never errors or yields. ]]
function PetSeams.analytics(family: string, player: Player?, key: string, amount: number?)
	local recorder = serverFn({ "Services", "AnalyticsService" }, family)
	if recorder ~= nil then
		pcall(recorder, player, key, amount)
	end
end

--[[ AnalyticsService.eggHatched(player, eggId, results, auto). ]]
function PetSeams.eggHatched(
	player: Player,
	eggId: string,
	results: { { petId: string, rarity: string } },
	auto: boolean
)
	local recorder = serverFn({ "Services", "AnalyticsService" }, "eggHatched")
	if recorder ~= nil then
		pcall(recorder, player, eggId, results, auto)
	end
end

--[[ AnalyticsService.crateOpened(player, crateId, payWith, rewards). ]]
function PetSeams.crateOpened(
	player: Player,
	crateId: string,
	payWith: string,
	rewards: { { kind: string, rarity: string? } }
)
	local recorder = serverFn({ "Services", "AnalyticsService" }, "crateOpened")
	if recorder ~= nil then
		pcall(recorder, player, crateId, payWith, rewards)
	end
end

--[[ AnalyticsService.registerIds(kind, isValid) — exact validation of "<kind>" key parts. ]]
function PetSeams.registerIds(kind: string, isValid: (id: string) -> boolean)
	local register = serverFn({ "Services", "AnalyticsService" }, "registerIds")
	if register ~= nil then
		pcall(register, kind, isValid)
	end
end

--------------------------------------------------------------------------------------------------
-- Admin (B14), modifiers (B5), rewards + boosts (B7), event (B11)
--------------------------------------------------------------------------------------------------

--[[
	Registers an owner-admin command (AdminConfig.CommandDef shape; handler(ctx) -> (ok, message)).
	@return true when AdminService accepted it
]]
function PetSeams.registerAdmin(def: { [string]: any }, handler: (ctx: any) -> (boolean, string)): boolean
	local register = serverFn({ "Services", "AdminService" }, "registerCommand")
	if register == nil then
		return false
	end
	local ok, err = pcall(register, def, handler)
	if not ok then
		warn(`[PetSeams] admin command {def.name} not registered: {err}`)
	end
	return ok
end

export type AdminEntry = { def: { [string]: any }, handler: (ctx: any) -> (boolean, string) }

--[[
	Registers several admin commands, retrying the ones AdminService did not accept yet (it may boot
	after the pets services) up to `attempts` times, `interval` seconds apart. Never yields.
	Example: PetSeams.registerAdminCommands({ { def = giveDef, handler = give } }, 6, 5)
]]
function PetSeams.registerAdminCommands(entries: { AdminEntry }, attempts: number, interval: number)
	local remaining: { AdminEntry } = {}
	for _, entry in entries do
		if not PetSeams.registerAdmin(entry.def, entry.handler) then
			table.insert(remaining, entry)
		end
	end
	if #remaining > 0 and attempts > 1 then
		task.delay(interval, PetSeams.registerAdminCommands, remaining, attempts - 1, interval)
	elseif #remaining > 0 then
		warn(`[PetSeams] {#remaining} admin command(s) never registered (AdminService missing?)`)
	end
end

--[[ Registers a tycoon modifier provider (ModifierSources.register). @return true when registered ]]
function PetSeams.registerModifier(name: string, provider: (player: Player, profile: any) -> (any, number?)): boolean
	local register = serverFn({ "Tycoon", "ModifierSources" }, "register")
	if register == nil then
		return false
	end
	local ok, err = pcall(register, name, provider)
	if not ok then
		warn(`[PetSeams] modifier source {name} not registered: {err}`)
	end
	return ok
end

--[[ Tells the tycoon a player's modifiers changed (equip, boost reward). ]]
function PetSeams.invalidateModifiers(player: Player)
	local invalidate = serverFn({ "Tycoon", "ModifierSources" }, "invalidate")
	if invalidate ~= nil then
		pcall(invalidate, player)
	end
end

--[[ Registers a B7 reward item granter ("pet" | "egg"). @return true when registered ]]
function PetSeams.registerItemGranter(kind: string, granter: (profile: any, id: string) -> boolean): boolean
	local register = serverFn({ "Retention", "RewardGrant" }, "registerItemGranter")
	if register == nil then
		return false
	end
	local ok, err = pcall(register, kind, granter)
	if not ok then
		warn(`[PetSeams] {kind} granter not registered: {err}`)
	end
	return ok
end

-- RewardGrant.grant's shape (B7, Server/Retention/RewardGrant): applies a reward + marks fields.
export type RewardGrantFn = (player: Player, reward: any, reason: string, options: any?) -> any

--[[
	B7's live reward granter RewardGrant.grant (R78 Pet Index claims pay their gems through it, so
	analytics see the gems like every other reward), or nil while that module is missing. Never
	yields; the CALLER invokes the returned function inside its own no-yield claim step.
	Example: local grant = PetSeams.rewardGrant(); if grant then grant(player, { gems = 25 }, "petIndex", opts) end
]]
function PetSeams.rewardGrant(): RewardGrantFn?
	return serverFn({ "Retention", "RewardGrant" }, "grant")
end

--[[ Whether the Harvest Feast runs right now (EventService.isActive), nil when unknown. ]]
function PetSeams.eventActive(): boolean?
	local isActive = serverFn({ "Services", "EventService" }, "isActive")
	if isActive == nil then
		return nil
	end
	local ok, active = pcall(isActive)
	if ok and type(active) == "boolean" then
		return active
	end
	return nil
end

--------------------------------------------------------------------------------------------------
-- World (B8e hub layout, B4 MeshLibrary)
--------------------------------------------------------------------------------------------------

--[[
	HubLayout.anchors (B8e, Shared/Config/HubLayout) or nil while the hub layout is not there.
	Shape used by the pets: EggStands[1..10] / HarvestEggStand = { area, model, cf, egg, prompt,
	tint } (egg = the egg's bottom-centre pivot on the cradle, prompt = the interaction point),
	CrateStall = { model, cf, display, prompt }.
]]
function PetSeams.hubAnchors(): any
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local layout: any = if shared ~= nil then lazy(shared, { "Config", "HubLayout" }) else nil
	if type(layout) ~= "table" or type(layout.anchors) ~= "table" then
		return nil
	end
	return layout.anchors
end

--[[
	The anchors of a world's hub layout (WorldsConfig.get(worldId).hubLayout, a path under
	Shared/Config): Nuke Town = HubLayout (WORLD space), every other world's layout is
	WORLD-LOCAL (callers place it with WorldLayout.toWorld). nil while the module is not there yet
	(W9 authors ValleyLayout) or has no anchors. Never errors.
	Example: PetSeams.worldHubAnchors("dino").EggStands[1].egg --> world-local CFrame
]]
function PetSeams.worldHubAnchors(worldId: string): any
	local def = WorldsConfig.get(worldId)
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local config = if shared ~= nil then shared:FindFirstChild("Config") else nil
	if def == nil or config == nil then
		return nil
	end
	local layout: any = lazy(config, def.hubLayout)
	if type(layout) ~= "table" or type(layout.anchors) ~= "table" then
		return nil
	end
	return layout.anchors
end

--[[
	This season's acorn balance (EventService.getAcorns: a previous season's balance counts as 0),
	or nil while EventService is not available.
]]
function PetSeams.acornsOf(player: Player): number?
	local getAcorns = serverFn({ "Services", "EventService" }, "getAcorns")
	if getAcorns == nil then
		return nil
	end
	local ok, value = pcall(getAcorns, player)
	return if ok and type(value) == "number" then value else nil
end

--[[
	Spends acorns through EventService.trySpendAcorns (atomic, never yields, season-safe, marks
	"event", analytics). @return true / false, or nil while EventService is not available
]]
function PetSeams.spendAcorns(player: Player, amount: number, reason: string): boolean?
	local trySpend = serverFn({ "Services", "EventService" }, "trySpendAcorns")
	if trySpend == nil then
		return nil
	end
	local ok, spent = pcall(trySpend, player, amount, reason)
	return ok and spent == true
end

--[[
	Calls `callback(active)` whenever the Harvest Feast turns on / off (EventService.ActiveChanged,
	B11). @return true when connected (false while EventService is not available)
]]
function PetSeams.onEventChanged(callback: (active: boolean) -> ()): boolean
	local root = server()
	local service = if root ~= nil then lazy(root, { "Services", "EventService" }) else nil
	local signal = if type(service) == "table" then service.ActiveChanged else nil
	if type(signal) ~= "table" or type(signal.Connect) ~= "function" then
		return false
	end
	local ok = pcall(function()
		signal:Connect(callback)
	end)
	return ok
end

--[[ World/MeshLibrary (B4) or nil. ]]
function PetSeams.meshLibrary(): any
	local root = server()
	return if root ~= nil then lazy(root, { "World", "MeshLibrary" }) else nil
end

return table.freeze(PetSeams)
