--!strict
--[[
	AttackHandlers — built-in handlers of the admin panel's ATTACK tab (owner R51: "i need to be able
	to test attacks in dev mode so add like a bot button in the admin panel"). Catalogue entries:
	AdminConfig "Attack: test bots + my attack helpers" block.

	Commands (all target None — they act on the CALLING admin and their bots):
		AttackBotSpawn   { area, aa, shield }       a test bot on a free plot, built to `area`
		AttackBotAttack  { bot, kind, area }        TestBot N launches at you (area 0 = auto aim)
		AttackBotAuto    { bot, every, kind, area } TestBot N attacks you every N s (0 = stop)
		AttackBotShield  { bot, on }                TestBot N's shield bubble on / off
		AttackBotRemove  { bot }                    remove TestBot N (0 = every bot)
		AttackMeReset    {}                         your launcher + barrage are ready now
		AttackMeBarrage  { count }                  + stored Barrage nukes
		AttackMeLevels   { launcher, aa }           your stored Launcher / AA levels

	Security: AdminService authorises (AdminAuth) and audits every call BEFORE these run, and
	validates every argument against the catalogue schema. Bots are never persisted and never real
	Players (Server/Attack/TestBots). The attack services are required lazily (they boot before
	AdminService; a missing one greys nothing — the handler just reports it).

	Connects to: Server/Admin/HandlerKit, Server/Attack/TestBots, Services/{AttackService,
	DefenseService} (lazy), Shared/Config/AttackConfig.

	Example:
		AttackHandlers.install(registry, env)
]]

local HandlerKit = require(script.Parent.HandlerKit)

type Context = HandlerKit.Context

local AttackHandlers = {}

local Kit = HandlerKit

-- Lazily required attack modules (nil + reason when unavailable).
local function attackModules(): (any, any, any, string?)
	local ok, result = pcall(function(): any
		local server = script.Parent.Parent.Parent
		return {
			bots = require(server.Attack.TestBots) :: any,
			attack = require(server.Services.AttackService) :: any,
			defense = require(server.Services.DefenseService) :: any,
		}
	end)
	if not ok or type(result) ~= "table" then
		return nil, nil, nil, "Attack mode is not available"
	end
	return result.bots, result.attack, result.defense, nil
end

-- The calling admin (in-game; the panel only exists in a server).
local function caller(ctx: Context): Player?
	return ctx.caller.player
end

-- TestBot N from ctx.args.bot, or nil + message.
local function botOf(ctx: Context): (any, string?)
	local bots = attackModules()
	if bots == nil then
		return nil, "Attack mode is not available"
	end
	local id = Kit.num(ctx, "bot") or 0
	local bot = bots.get(id)
	if bot == nil then
		return nil, `TestBot {id} is not spawned`
	end
	local player = caller(ctx)
	if player == nil or bot.owner ~= player then
		return nil, `TestBot {id} belongs to another admin`
	end
	return bot, nil
end

local function spawnBot(ctx: Context): (boolean, string)
	local bots = attackModules()
	local player = caller(ctx)
	if bots == nil or player == nil then
		return false, "Attack mode is not available"
	end
	local bot, message = bots.spawn(player, {
		area = Kit.num(ctx, "area") or 7,
		aa = Kit.num(ctx, "aa") or 1,
		shield = ctx.args.shield == true,
	})
	return bot ~= nil, message
end

local function botAttack(ctx: Context): (boolean, string)
	local bot, problem = botOf(ctx)
	if bot == nil then
		return false, problem or "No bot"
	end
	local bots = attackModules()
	local kind = Kit.str(ctx, "kind") or "normal"
	return bots.attack(bot, if kind == "barrage" then "barrage" else "normal", Kit.num(ctx, "area") or 0)
end

local function botAuto(ctx: Context): (boolean, string)
	local bot, problem = botOf(ctx)
	if bot == nil then
		return false, problem or "No bot"
	end
	local bots = attackModules()
	local every = Kit.num(ctx, "every") or 0
	local kind = Kit.str(ctx, "kind") or "normal"
	bots.setAuto(bot, every, if kind == "barrage" then "barrage" else "normal", Kit.num(ctx, "area") or 0)
	if every <= 0 then
		return true, `{bot.name} stopped auto-attacking`
	end
	return true, `{bot.name} attacks you every {bot.autoEvery} s`
end

local function botShield(ctx: Context): (boolean, string)
	local bot, problem = botOf(ctx)
	if bot == nil then
		return false, problem or "No bot"
	end
	local bots = attackModules()
	local on = ctx.args.on == true
	bots.setShield(bot, on)
	return true, `{bot.name} shield {if on then "ON" else "OFF"}`
end

local function botRemove(ctx: Context): (boolean, string)
	local bots = attackModules()
	local player = caller(ctx)
	if bots == nil or player == nil then
		return false, "Attack mode is not available"
	end
	local id = Kit.num(ctx, "bot") or 0
	if id == 0 then
		local removed = 0
		for _, bot in bots.all() do
			if bot.owner == player then
				bots.remove(bot)
				removed += 1
			end
		end
		return true, `Removed {removed} test bot(s)`
	end
	local bot, problem = botOf(ctx)
	if bot == nil then
		return false, problem or "No bot"
	end
	bots.remove(bot)
	return true, `Removed {bot.name}`
end

local function meReset(ctx: Context): (boolean, string)
	local _, attack = attackModules()
	local player = caller(ctx)
	if attack == nil or player == nil then
		return false, "Attack mode is not available"
	end
	return attack.resetCooldown(player), "Your launcher and barrage are ready"
end

local function meBarrage(ctx: Context): (boolean, string)
	local _, attack = attackModules()
	local player = caller(ctx)
	if attack == nil or player == nil then
		return false, "Attack mode is not available"
	end
	local total = attack.giveBarrage(player, Kit.num(ctx, "count") or 20)
	return total > 0, `You now have {total} Barrage nukes`
end

local function meLevels(ctx: Context): (boolean, string)
	local _, _, defense = attackModules()
	local player = caller(ctx)
	if defense == nil or player == nil then
		return false, "Attack mode is not available"
	end
	local launcher = Kit.num(ctx, "launcher") or 5
	local aa = Kit.num(ctx, "aa") or 5
	defense.setLevels(player, aa, launcher)
	return true, `Launcher {launcher}, AA {aa} (they count while the Area 7 pads are owned)`
end

--[[ Installs every Attack-tab handler into the registry. ]]
function AttackHandlers.install(registry: HandlerKit.Registry, _env: HandlerKit.Env)
	registry.setBuiltin("AttackBotSpawn", spawnBot)
	registry.setBuiltin("AttackBotAttack", botAttack)
	registry.setBuiltin("AttackBotAuto", botAuto)
	registry.setBuiltin("AttackBotShield", botShield)
	registry.setBuiltin("AttackBotRemove", botRemove)
	registry.setBuiltin("AttackMeReset", meReset)
	registry.setBuiltin("AttackMeBarrage", meBarrage)
	registry.setBuiltin("AttackMeLevels", meLevels)
end

return table.freeze(AttackHandlers)
