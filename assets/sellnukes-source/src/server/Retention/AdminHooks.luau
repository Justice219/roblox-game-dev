--!strict
--[[
	AdminHooks — registers B7's owner-admin commands with B14's AdminService (spec §14), through a
	GUARDED lazy require: when Services/AdminService is missing or fails to load nothing is
	registered and nothing errors.

	Commands (names / argument schemas pre-declared by B14 and validated BEFORE these run;
	handler(ctx) → (ok, message), ctx.target.player = the chosen player, ctx.args = the args):
		GrantSpins     { count 1..100 }                  LuckySpinService.grantSpins
		ResetDaily     {}                                daily streak cleared + today's time rewards
		GiveBoost      { boost: BoostConfig key, minutes 1..1440 }   BoostService.grant
		ServerBoost    { minutes 1..180 }                ServerBoostService.start
		ServerBoostOff {}                                ServerBoostService.stop
		AddCode        { code, gems, spins, cashSeconds, hours }      CodesService.addCode (this
		                                                 server only, expires after `hours`)

	Called once from ShopService.Init (the last B7 service in the boot order); services are
	required inside `install` so no require cycle can form.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local AdminHooks = {}

local installed = false

-- B14's validated command context (caller = the admin who ran it).
type Ctx = { target: { player: Player }?, args: { [string]: any }, caller: Player?, player: Player? }

-- The target player of a command (nil when the command was not aimed at a player).
local function targetOf(ctx: Ctx): Player?
	local target = ctx.target
	return if target ~= nil then target.player else nil
end

--[[ Registers every B7 admin command (idempotent). @return true when AdminService took them ]]
function AdminHooks.install(): boolean
	if installed then
		return true
	end
	local Services = ServerScriptService.Server.Services
	local module = Services:FindFirstChild("AdminService")
	if module == nil or not module:IsA("ModuleScript") then
		return false
	end
	local ok, AdminService = pcall(require, module)
	if not ok or type(AdminService) ~= "table" or type((AdminService :: any).registerHandler) ~= "function" then
		warn("[AdminHooks] AdminService could not be loaded; retention admin commands not registered")
		return false
	end
	installed = true
	local LuckySpinService = require(Services.LuckySpinService) :: any
	local RetentionService = require(Services.RetentionService) :: any
	local PlaytimeService = require(Services.PlaytimeService) :: any
	local BoostService = require(Services.BoostService) :: any
	local ServerBoostService = require(Services.ServerBoostService) :: any
	local CodesService = require(Services.CodesService) :: any
	local register = (AdminService :: any).registerHandler

	local function guarded(name: string, handler: (ctx: Ctx) -> (boolean, string))
		local registered, err = pcall(register, name, handler)
		if not registered then
			warn(`[AdminHooks] {name} not registered: {err}`)
		end
	end

	guarded("GrantSpins", function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		local added = LuckySpinService.grantSpins(player, ctx.args.count)
		return added > 0, `Granted {added} spins to {player.Name}`
	end)
	guarded("ResetDaily", function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		local daily = RetentionService.resetDaily(player)
		local time = PlaytimeService.resetToday(player)
		return daily and time, `Daily + time rewards reset for {player.Name}`
	end)
	guarded("GiveBoost", function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		local expires = BoostService.grant(player, ctx.args.boost, ctx.args.minutes * 60)
		return expires ~= nil, `{ctx.args.boost} +{ctx.args.minutes} min for {player.Name}`
	end)
	guarded("ServerBoost", function(ctx: Ctx): (boolean, string)
		local caller = ctx.caller or ctx.player
		local by = if caller ~= nil then caller.DisplayName else "Admin"
		local ends = ServerBoostService.start(ctx.args.minutes * 60, by)
		return ends ~= nil, `Server 2x Cash on for {ctx.args.minutes} min`
	end)
	guarded("ServerBoostOff", function(_ctx: Ctx): (boolean, string)
		ServerBoostService.stop()
		return true, "Server 2x Cash off"
	end)
	guarded("AddCode", function(ctx: Ctx): (boolean, string)
		local args = ctx.args
		local reward: { [string]: any } = {}
		if type(args.gems) == "number" and args.gems > 0 then
			reward.gems = math.floor(args.gems)
		end
		if type(args.spins) == "number" and args.spins > 0 then
			reward.spins = math.floor(args.spins)
		end
		if type(args.cashSeconds) == "number" and args.cashSeconds > 0 then
			reward.cashSeconds = args.cashSeconds
			reward.cashFloor = 100
		end
		local code = string.upper(tostring(args.code))
		local added = CodesService.addCode({
			id = `admin_{string.lower(code)}`,
			code = code,
			reward = reward,
			expiresAt = os.time() + math.floor(args.hours * 3600),
		})
		return added,
			if added then `Code {code} live on this server for {args.hours} h` else "Code refused (duplicate / invalid)"
	end)
	return true
end

return AdminHooks
