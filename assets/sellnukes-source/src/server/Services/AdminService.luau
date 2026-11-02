--!strict
--[[
	AdminService — the owner admin panel's server (spec §14; owner R6 "an admin panel built in that
	I have access to as the owner of the experience"; rule 9 "every system is controllable from the
	owner-only admin panel"). Ported from RoBeasts' AdminService and split into Server/Admin/*.

	Who is an admin (AdminAuth, re-checked on EVERY command):
		Studio → everyone; AdminConfig.AdminUserIds (the owner 1586034782 is listed); the place
		creator for a user-owned game (game.CreatorId); group rank ≥ 254 for a group-owned game
		(GroupService, 120 s cache, fail closed). The `IsAdmin` player attribute mirrors the verdict
		for the client UI only — the server never reads it back.

	Command pipeline (one remote: AdminCommand(name, args)):
		submit: per-user token bucket (AdminConfig.RateLimit, BEFORE any work is spawned)
		→ AdminPipeline: re-auth → allowlist → availability → per-command cooldown → strict arg
		  schema → target resolution → pcall handler → audit log (ring buffer, printed) → result to
		  the caller (AdminResult remote + Notify toast) → CommandExecuted.

	Commands:
		Built-ins (AdminConfig.Commands) live in Server/Admin/Handlers/* (Players, Economy, Server,
		World, New Player). Commands whose seam is missing (B5 TycoonAdmin, B7 retention services,
		the B1 sandbox) are refused and shown greyed "needs <provider>" until the seam exists.
		Later systems add their own commands:

			local ok, AdminService = pcall(require, ServerScriptService.Server.Services.AdminService)
			if ok then
				AdminService.registerCommand({
					name = "GivePet", tab = "Players", label = "Give Pet", target = "Player",
					args = { petId = { kind = "enum", values = PET_IDS, labels = PET_NAMES } },
					cooldown = 1, audited = true, confirm = false,
				}, function(ctx) -- ctx.caller / ctx.target.player / ctx.args (validated)
					return true, `Gave {ctx.args.petId} to {ctx.target.label}`
				end)
			end

		Registration is allowed any time (AdminService boots last; Init/Start of other services is
		ideal). The def is validated (AdminValidate.validateDef) and frozen; a malformed def or a
		name clash errors loudly. Admins get the new command on their next state push.

	AdminState pushes: Server/Admin/AdminStatePush (players, live stats, audit log, catalogue).

	Seams used by other builders:
		- B13 analytics (Server/Analytics/AnalyticsAuth) calls isAuthorizedAsync(player) /
		  isAdmin(player) automatically.
		- B9 / B10 / B11 call registerCommand / registerHandler.

	Dependency rule (no cycles): this module requires ONLY PlayerDataService +
	MonetizationService (through the handlers) and shared modules at load time. Gameplay services
	and AnalyticsService are looked up lazily (Server/Admin/Seams).

	Boot: LAST in Server/init.server.luau's ORDERED list.

	Example (server code / Studio tests):
		local result = AdminService.dispatchAsync(
			{ userId = player.UserId, name = player.Name, player = player }, "GrantGems", { userId = 123, amount = 50 })
		print(result.ok, result.message)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Admin = script.Parent.Parent.Admin
local AdminAudit = require(Admin.AdminAudit)
local AdminAuth = require(Admin.AdminAuth)
local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local AdminPipeline = require(Admin.AdminPipeline)
local AdminRegistry = require(Admin.AdminRegistry)
local AdminStatePush = require(Admin.AdminStatePush)
local AdminValidate = require(Admin.AdminValidate)
local AttackHandlers = require(Admin.Handlers.AttackHandlers)
local KnockdownHandlers = require(Admin.Handlers.KnockdownHandlers)
local MultiWorldHandlers = require(Admin.Handlers.MultiWorldHandlers)
local EconomyHandlers = require(Admin.Handlers.EconomyHandlers)
local HandlerKit = require(Admin.Handlers.HandlerKit)
local NewPlayerHandlers = require(Admin.Handlers.NewPlayerHandlers)
local PlayerDataService = require(script.Parent.PlayerDataService)
local PlayerHandlers = require(Admin.Handlers.PlayerHandlers)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ServerHandlers = require(Admin.Handlers.ServerHandlers)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local WorldHandlers = require(Admin.Handlers.WorldHandlers)

export type Caller = AdminRegistry.Caller
export type Context = AdminRegistry.Context
export type Handler = AdminRegistry.Handler
export type CommandResult = AdminPipeline.CommandResult
export type AuthEnvironment = AdminAuth.AuthEnvironment

local AdminService = {}

--[[ Fires after every executed (non-refused-at-auth) command: (caller, name, ok, message). ]]
AdminService.CommandExecuted = Signal.new() :: Signal.Signal<Caller, string, boolean, string>

-- State ------------------------------------------------------------------------------------------

local registry = AdminRegistry.new()
local audit = AdminAudit.new()
local adminStatus: { [Player]: boolean } = {}
local commandLimiter = RateLimiter.new(AdminConfig.RateLimit.Capacity, AdminConfig.RateLimit.RefillPerSecond)
local initialized = false
local started = false

-- Online players holding admin rights right now.
local function adminsOnline(): { Player }
	local list: { Player } = {}
	for player, isAdmin in adminStatus do
		if isAdmin and player.Parent == Players then
			table.insert(list, player)
		end
	end
	return list
end

local statePush = AdminStatePush.new({
	registry = registry,
	audit = audit,
	admins = adminsOnline,
	isAdmin = function(player: Player): boolean
		return adminStatus[player] == true
	end,
	recentBans = PlayerHandlers.recentBans,
	shutdownAt = ServerHandlers.shutdownAt,
})

-- Every audit append refreshes the admins' Log tab (coalesced).
audit.onAppend(function()
	statePush.schedule()
end)

--[[
	Resolves the command target from VALIDATED ids. User ids are only lookup keys: a Player target
	must be a real Player in this server (Players:GetPlayerByUserId).
]]
local function resolveTarget(
	def: AdminConfig.CommandDef,
	args: AdminValidate.ValidatedArgs
): (AdminRegistry.Target?, string?)
	if def.target == "None" then
		return { label = "" }, nil
	end
	local userId = args.userId
	if type(userId) ~= "number" then
		return nil, "missing target"
	end
	local online = Players:GetPlayerByUserId(userId)
	if def.target == "AnyUser" then
		return {
			userId = userId,
			player = online,
			label = if online ~= nil then `{online.Name} ({userId})` else `user {userId}`,
		},
			nil
	end
	if online == nil then
		return nil, "that player is not in this server"
	end
	return { userId = userId, player = online, label = `{online.Name} ({userId})` }, nil
end

-- Sends a command result to the caller: AdminResult + a toast (no toast for RequestState).
local function deliver(caller: Caller, result: AdminConfig.ResultPayload)
	local player = caller.player
	if player == nil or player.Parent ~= Players then
		return
	end
	Remotes.fireClient("AdminResult", player, result)
	if result.name ~= "RequestState" then
		PlayerDataService.notify(player, result.text, if result.ok then "success" else "error")
	end
end

local pipeline = AdminPipeline.new({
	registry = registry,
	audit = audit,
	authorize = function(caller: Caller): boolean
		return AdminAuth.isAuthorizedAsync(caller.userId)
	end,
	isStudio = function(): boolean
		return RunService:IsStudio()
	end,
	now = os.clock,
	resolveTarget = resolveTarget,
	deliver = deliver,
	onExecuted = function(caller: Caller, name: string, ok: boolean, message: string)
		AdminService.CommandExecuted:Fire(caller, name, ok, message)
		statePush.schedule()
	end,
})

-- Public API: authorisation ------------------------------------------------------------------------

--[[ PURE authorisation decision (re-export of AdminAuth.decideAdmin; tests). ]]
AdminService.decideAdmin = AdminAuth.decideAdmin

--[[
	Full authorisation check (may yield for group ranks). Accepts a Player (B13's AnalyticsAuth
	seam) or a Caller table.
	Example: if AdminService.isAuthorizedAsync(player) then ... end
]]
function AdminService.isAuthorizedAsync(who: Player | Caller): boolean
	local userId: number? = nil
	if typeof(who) == "Instance" then
		if (who :: Instance):IsA("Player") then
			userId = (who :: Player).UserId
		end
	elseif type(who) == "table" then
		local candidate = (who :: Caller).userId
		userId = if type(candidate) == "number" then candidate else nil
	end
	if userId == nil then
		return false
	end
	return AdminAuth.isAuthorizedAsync(userId)
end

--[[ True if the player currently holds admin rights (server cache of the last check; never yields). ]]
function AdminService.isAdmin(player: Player): boolean
	return adminStatus[player] == true
end

--[[ Studio-only: replace the authorisation environment (nil restores the live one). ]]
function AdminService.setEnvironmentOverrideForTests(env: AuthEnvironment?)
	AdminAuth.setEnvironmentOverrideForTests(env)
end

-- Public API: commands -------------------------------------------------------------------------------

--[[
	Adds a NEW admin command from another system (see the header for the def shape).
	Errors when the def is malformed or the name is taken.
	@return the normalised, frozen def now live
]]
function AdminService.registerCommand(def: { [string]: any }, handler: Handler): AdminConfig.CommandDef
	local live = registry.registerCommand(def, handler)
	statePush.schedule()
	return live
end

--[[
	Supplies the handler of an AdminConfig command that declares a `provider` (overrides the
	built-in seam call). Errors for any other name.
	Example: AdminService.registerHandler("GrantSpins", function(ctx) return true, "Done" end)
]]
function AdminService.registerHandler(name: string, handler: Handler)
	registry.registerHandler(name, handler)
	statePush.schedule()
end

--[[
	Validates raw args for a command name (tests / tooling). Never yields.
	@return (validated args, nil) or (nil, error)
]]
function AdminService.validateArgs(commandName: string, raw: unknown): (AdminValidate.ValidatedArgs?, string?)
	if not registry.isKnown(commandName) then
		return nil, "unknown command"
	end
	local def = registry.get(commandName)
	assert(def ~= nil, "isKnown guarantees a def")
	return AdminValidate.validateArgs(def, raw)
end

--[[
	Runs one command through the full pipeline (re-auth → ... → audit). Does NOT apply the
	per-user token bucket (see `submit`). Yields. Never throws.
	@return { ok, message }
]]
function AdminService.dispatchAsync(caller: Caller, rawName: unknown, rawArgs: unknown): CommandResult
	return pipeline.dispatchAsync(caller, rawName, rawArgs)
end

--[[
	Entry point for the remote: applies the per-user token bucket synchronously (spam never spawns
	work), then runs the pipeline on its own thread.
	@return false if the call was rate-limited
]]
function AdminService.submit(caller: Caller, rawName: unknown, rawArgs: unknown): boolean
	if not commandLimiter:Allow(caller.userId) then
		return false
	end
	task.spawn(pipeline.dispatchAsync, caller, rawName, rawArgs)
	return true
end

--[[ Most recent audit entries, oldest first (copy). ]]
function AdminService.getAuditLog(count: number?): { AdminConfig.AuditEntry }
	return audit.tail(count)
end

-- Admin status ---------------------------------------------------------------------------------------

local function callerOf(player: Player): Caller
	return { userId = player.UserId, name = player.Name, player = player }
end

--[[ Re-evaluates a player's admin status, mirrors IsAdmin, pushes / revokes. Yields. ]]
local function refreshAdminStatusAsync(player: Player)
	local isAdmin = AdminAuth.isAuthorizedAsync(player.UserId)
	if player.Parent ~= Players then
		return
	end
	local was = adminStatus[player] == true
	adminStatus[player] = isAdmin
	if player:GetAttribute("IsAdmin") ~= isAdmin then
		player:SetAttribute("IsAdmin", isAdmin)
	end
	if isAdmin and not was then
		statePush.pushTo(player, true)
		statePush.schedule() -- other admins see the new admin badge
	elseif was and not isAdmin then
		statePush.revoke(player)
		statePush.schedule()
		-- Rights revoked while playing as a new player: end the mode (the panel's EXIT is gone).
		if PlayerDataService.isNewPlayerMode(player) then
			local okExit, _, message = pcall(PlayerDataService.exitNewPlayerMode, player)
			if okExit and type(message) == "string" then
				PlayerDataService.notify(player, message, "info")
			end
		end
	end
end

-- Lifecycle ------------------------------------------------------------------------------------------

--[[ Installs every built-in handler; errors when an AdminConfig command has no handler. ]]
function AdminService.Init()
	if initialized then
		return
	end
	initialized = true
	local env: HandlerKit.Env = {
		isProtectedAsync = function(userId: number): boolean
			local online = Players:GetPlayerByUserId(userId)
			return AdminAuth.isProtectedAsync(userId, online ~= nil and adminStatus[online] == true)
		end,
		isAdmin = function(player: Player): boolean
			return adminStatus[player] == true
		end,
	}
	registry.setBuiltin("RequestState", function(ctx: Context): (boolean, string)
		local player = ctx.caller.player
		if player ~= nil then
			statePush.markFull(player) -- the next push carries the whole log + catalogue
		end
		return true, "State refreshed"
	end)
	PlayerHandlers.install(registry, env)
	EconomyHandlers.install(registry, env)
	ServerHandlers.install(registry, env)
	WorldHandlers.install(registry, env)
	AttackHandlers.install(registry, env)
	KnockdownHandlers.install(registry, env) -- owner R50 knockdown commands (Attack tab)
	MultiWorldHandlers.install(registry, env) -- owner R57 World* commands (Players + Server tabs)
	NewPlayerHandlers.install(registry, env)
	local missing = registry.missingBuiltins()
	if #missing > 0 then
		error(`[AdminService] no handler for command(s): {table.concat(missing, ", ")}`)
	end
end

--[[ Connects the remote and player events, starts the state pushes. ]]
function AdminService.Start()
	if started then
		return
	end
	started = true
	Remotes.onServerEvent("AdminCommand", function(player: Player, rawName: unknown, rawArgs: unknown)
		AdminService.submit(callerOf(player), rawName, rawArgs)
	end)

	local function onPlayerAdded(player: Player)
		player:SetAttribute("IsAdmin", false)
		statePush.noteJoin(player)
		task.spawn(refreshAdminStatusAsync, player)
		statePush.schedule()
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		adminStatus[player] = nil
		statePush.forget(player)
		AdminAuth.forget(player.UserId)
		audit.forget(player.UserId)
		pipeline.forget(player.UserId)
		commandLimiter:Forget(player.UserId)
		statePush.schedule()
	end)

	-- Profile swaps / loads change the player rows (cash, area, NEW PLAYER MODE flag).
	PlayerDataService.ProfileLoaded:Connect(function()
		statePush.schedule()
	end)
	PlayerDataService.NewPlayerModeChanged:Connect(function()
		statePush.schedule()
	end)

	-- Periodic: re-check admins whose group rank cache expired (a demoted group member loses the
	-- panel without rejoining), then push the live stats.
	statePush.start(function()
		for _, player in Players:GetPlayers() do
			if AdminAuth.rankExpired(player.UserId) then
				task.spawn(refreshAdminStatusAsync, player)
			end
		end
	end)
end

return AdminService
