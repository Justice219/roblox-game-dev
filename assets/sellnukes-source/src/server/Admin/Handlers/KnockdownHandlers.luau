--!strict
--[[
	KnockdownHandlers — built-in handlers of the admin panel's knockdown commands (owner R50; hard
	rule 9 "every system is controllable from the admin panel"; owner R51: they live on the
	"Attack" tab next to Q2's test-bot commands). The commands themselves are declared in
	Shared/Config/AdminConfig.Commands (tab "Attack"); AdminService validates every argument
	against those schemas BEFORE a handler runs.

	Commands (all live on this server, never saved):
		KnockdownArea         { area 1..10, seconds 0..600, bot 0..8 }  test knockdown of one area
		                      (0 s = the Launcher-1 45 s); bypasses the switch, shield and immunity
		                      (Knockdown.adminKnock)
		KnockdownRebuild      { bot 0..8 }  rebuilds every knocked area now
		KnockdownImmunityOff  { bot 0..8 }  the plot can be knocked down again at once
		`bot` 1..8 aims the command at Q2's TestBot N (owner R51, Server/Attack/TestBots); 0 = the
		calling admin's own plot (R51: test on your own plot).
		KnockdownToggle       { on }          master switch (off: hits still pay, nothing is knocked)
		KnockdownTuning       { durationSeconds 0..600 (0 = normal), immunitySeconds 0..3600 }
		KnockdownStats        —               areas down, immune plots, rivals down, totals

	The knockdown service is reached through Seams.knockdown() (lazy, pcall'd), so the admin panel
	never requires gameplay code at load time; while it is missing the buttons are greyed with
	HandlerKit.KNOCKDOWN.

	Connects to: Server/Admin/HandlerKit, Server/Admin/Seams, Server/Tycoon/Knockdown,
	Shared/Config/KnockdownConfig.

	Example:
		KnockdownHandlers.install(registry, env)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HandlerKit = require(script.Parent.HandlerKit)
local KnockdownConfig = require(ReplicatedStorage.Shared.Config.KnockdownConfig)
local Seams = require(script.Parent.Parent.Seams)

type Context = HandlerKit.Context

local KnockdownHandlers = {}

local Kit = HandlerKit
-- Greyed-button reason while Server/Tycoon/Knockdown is missing.
local NEEDS = "needs Knockdown (R50 Server/Tycoon/Knockdown)"

-- The knockdown service, or nil while it is missing / broken.
local function knockdown(): any
	local module = Seams.knockdown()
	return if type(module) == "table" then module else nil
end

-- Q2's Server/Attack/TestBots (owner R51), required lazily + guarded (nil while it is missing).
local testBotsModule: any = nil
local function testBots(): any
	if testBotsModule ~= nil then
		return testBotsModule
	end
	local server = ServerScriptService:FindFirstChild("Server")
	local folder = if server ~= nil then server:FindFirstChild("Attack") else nil
	local module = if folder ~= nil then folder:FindFirstChild("TestBots") else nil
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, value = pcall(require, module)
	if ok and type(value) == "table" then
		testBotsModule = value
	end
	return testBotsModule
end

--[[
	The knockdown subject of a command: TestBot N when the `bot` arg is 1..8 (owner R51), else the
	calling admin's own plot (bot 0).
	@return subject (Player | bot record), its label — or nil + the refusal text
]]
local function subjectOf(ctx: Context): (any, string)
	local botIndex = Kit.num(ctx, "bot") or 0
	if botIndex > 0 then
		local bots = testBots()
		local get: any = if bots ~= nil then bots.get else nil
		local bot = if type(get) == "function" then (get :: any)(botIndex) else nil
		if bot == nil then
			return nil, `TestBot {botIndex} is not spawned`
		end
		return bot, `TestBot {botIndex}`
	end
	local player = ctx.caller.player
	if player == nil then
		return nil, "You need to be in this server (bot 0 = your own plot)"
	end
	return player, "your"
end

-- Availability probe: nil when the service has every function the commands call.
local function probe(): string?
	local module = knockdown()
	for _, fnName in { "adminKnock", "forceRebuild", "clearImmunity", "setEnabled", "settings", "stats" } do
		if not Seams.has(module, fnName) then
			return NEEDS
		end
	end
	return nil
end

-- KnockdownArea: a test knockdown of one area of the target's plot.
local function knockArea(ctx: Context): (boolean, string)
	local service = knockdown()
	if service == nil then
		return false, NEEDS
	end
	local subject, who = subjectOf(ctx)
	if subject == nil then
		return false, who
	end
	local area = Kit.num(ctx, "area") or 1
	local seconds = Kit.num(ctx, "seconds") or 0
	local label = KnockdownConfig.areaLabel(area)
	local done, reason = service.adminKnock(subject, area, if seconds > 0 then seconds else nil)
	local owner = if who == "your" then "Your" else `{who}'s`
	if not done then
		return false, `{owner} {label} can't be knocked down ({reason or "?"}: no build there yet?)`
	end
	return true, `Knocked down: {owner} {label}`
end

-- KnockdownRebuild: every knocked area of the target back up now.
local function rebuild(ctx: Context): (boolean, string)
	local service = knockdown()
	if service == nil then
		return false, NEEDS
	end
	local subject, who = subjectOf(ctx)
	if subject == nil then
		return false, who
	end
	local count = service.forceRebuild(subject)
	return true, `Rebuilt {count} area(s) ({if who == "your" then "your plot" else who})`
end

-- KnockdownImmunityOff: the target's plot can be knocked down again.
local function immunityOff(ctx: Context): (boolean, string)
	local service = knockdown()
	if service == nil then
		return false, NEEDS
	end
	local subject, who = subjectOf(ctx)
	if subject == nil then
		return false, who
	end
	local had = service.clearImmunity(subject)
	local plot = if who == "your" then "your plot" else who
	return true, if had then `Knockdown immunity removed ({plot})` else `No immunity to remove ({plot})`
end

-- KnockdownToggle: the master switch.
local function toggle(ctx: Context): (boolean, string)
	local service = knockdown()
	if service == nil then
		return false, NEEDS
	end
	local on = ctx.args.on == true
	service.setEnabled(on)
	return true, if on then "Knockdowns are ON" else "Knockdowns are OFF on this server (hits still pay)"
end

-- KnockdownTuning: duration override + immunity seconds.
local function tuning(ctx: Context): (boolean, string)
	local service = knockdown()
	if
		service == nil
		or not Seams.has(service, "setDurationOverride")
		or not Seams.has(service, "setImmunitySeconds")
	then
		return false, NEEDS
	end
	service.setDurationOverride(Kit.num(ctx, "durationSeconds") or 0)
	service.setImmunitySeconds(Kit.num(ctx, "immunitySeconds") or KnockdownConfig.ImmunitySeconds)
	local live = service.settings()
	local duration = if live.durationOverride > 0
		then `{live.durationOverride} s`
		else "normal (45 s +3 s / launcher level)"
	return true, `Knockdown duration {duration} · immunity {live.immunitySeconds} s`
end

-- KnockdownStats: live counts on this server.
local function stats(_ctx: Context): (boolean, string)
	local service = knockdown()
	if service == nil then
		return false, NEEDS
	end
	local s = service.stats()
	local live = service.settings()
	return true,
		`{if live.enabled then "ON" else "OFF"} · down {s.down} · immune {s.immune} · rivals down {s.rivalsDown} · applied {s.applied} · blocked {s.blocked} · taps {s.taps}`
end

--[[ Installs every knockdown handler into the registry (AdminService.Init). ]]
function KnockdownHandlers.install(registry: HandlerKit.Registry, _env: HandlerKit.Env)
	registry.setBuiltin("KnockdownArea", knockArea, probe)
	registry.setBuiltin("KnockdownRebuild", rebuild, probe)
	registry.setBuiltin("KnockdownImmunityOff", immunityOff, probe)
	registry.setBuiltin("KnockdownToggle", toggle, probe)
	registry.setBuiltin("KnockdownTuning", tuning, probe)
	registry.setBuiltin("KnockdownStats", stats, probe)
end

return table.freeze(KnockdownHandlers)
