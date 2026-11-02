--!strict
--[[
	NewPlayerHandlers — the admin panel's NEW PLAYER MODE tab (spec §14 "play on a throw-away
	sandbox profile; purchases refused; analytics diverted"). Rules: Shared/Util/NewPlayerMode.

	Both commands act on the CALLER only (an admin can never put someone else into the mode):
		NewPlayerMode      → PlayerDataService.enterNewPlayerModeAsync(caller) (commits the real
		                     profile, parks it, swaps a never-saved sandbox in; yields)
		ExitNewPlayerMode  → PlayerDataService.exitNewPlayerMode(caller) (the real profile is back)
	The probe reports "needs PlayerDataService sandbox (B1)" while those functions are missing.
	Robux purchases in the mode are refused by MonetizationService (NewPlayerMode.purchaseGate)
	and analytics divert on the NewPlayerMode attribute (B13 Runtime.guard).

	Connects to: Server/Admin/HandlerKit, Server/Admin/Seams, Server/Services/PlayerDataService.

	Example:
		NewPlayerHandlers.install(registry, env)
]]

local HandlerKit = require(script.Parent.HandlerKit)
local Seams = require(script.Parent.Parent.Seams)

type Context = HandlerKit.Context

local NewPlayerHandlers = {}

local Kit = HandlerKit

-- PlayerDataService through Seams (so a build without the sandbox API still boots).
local function dataService(): any
	return Seams.service("PlayerDataService")
end

-- True when PlayerDataService has the whole sandbox API.
local function probe(): string?
	local service = dataService()
	if
		Seams.has(service, "enterNewPlayerModeAsync")
		and Seams.has(service, "exitNewPlayerMode")
		and Seams.has(service, "isNewPlayerMode")
	then
		return nil
	end
	return Kit.SANDBOX
end

-- Enter (caller only).
local function enter(ctx: Context): (boolean, string)
	local player = ctx.caller.player
	if player == nil then
		return false, "Only an in-game admin can play as a new player"
	end
	local found, ok, message = Seams.call(dataService(), "enterNewPlayerModeAsync", player)
	if not found then
		return false, Kit.SANDBOX
	end
	return ok == true, if type(message) == "string" then message elseif ok then "New Player Mode on" else "Refused"
end

-- Exit (caller only).
local function exit(ctx: Context): (boolean, string)
	local player = ctx.caller.player
	if player == nil then
		return false, "Only an in-game admin can exit New Player Mode"
	end
	local found, ok, message = Seams.call(dataService(), "exitNewPlayerMode", player)
	if not found then
		return false, Kit.SANDBOX
	end
	return ok == true, if type(message) == "string" then message elseif ok then "New Player Mode off" else "Refused"
end

--[[ Installs both New Player Mode handlers into the registry. ]]
function NewPlayerHandlers.install(registry: HandlerKit.Registry, _env: HandlerKit.Env)
	registry.setBuiltin("NewPlayerMode", enter, probe)
	registry.setBuiltin("ExitNewPlayerMode", exit, probe)
end

return table.freeze(NewPlayerHandlers)
