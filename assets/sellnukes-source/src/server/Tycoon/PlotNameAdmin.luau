--!strict
--[[
	PlotNameAdmin — the owner-admin moderation control of plot names (owner R88; hard rule 9 "every
	system is controllable from the admin panel"), registered at runtime with B14's
	AdminService.registerCommand(def, handler) through a GUARDED lazy require (the ChangeNotesAdmin
	pattern): when Services/AdminService is missing or fails to load nothing is registered and
	nothing errors. The panel lists it on the Players tab (Moderation group, PlayersTab GROUPS).

	Command (Players tab, target = an online player; AdminService authorises, validates, rate
	limits and audits BEFORE the handler runs; handler(ctx) -> (ok, message)):
		ResetPlotName  {}   clears their custom plot name: every world's sign shows the default
		                    "<DisplayName>'s Nukes" again, the profile saves + pushes, and the player
		                    gets a kind toast. The audit message names the cleared (filtered) name.

	Connects to: Server/Services/AdminService (B14), Server/Tycoon/PlotNames (passed in: adminReset).

	Usage: PlotNames.start → PlotNameAdmin.install(PlotNames)
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlotNameAdmin = {}

type Ctx = { args: { [string]: any }, target: { player: Player?, label: string }? }
type Handler = (ctx: Ctx) -> (boolean, string)

-- Panel order: next to the other per-player moderation helpers (after What's New at 380+).
local ORDER = 390

local installed = false

-- The command's target player (nil when not aimed at an online player).
local function targetOf(ctx: Ctx): Player?
	local target = ctx.target
	return if target ~= nil then target.player else nil
end

--[[
	Registers ResetPlotName (idempotent).
	@param Service any — Server/Tycoon/PlotNames (adminReset)
	@return boolean — true when AdminService accepted the command
]]
function PlotNameAdmin.install(Service: any): boolean
	if installed then
		return true
	end
	local server = ServerScriptService:FindFirstChild("Server")
	local services = if server ~= nil then server:FindFirstChild("Services") else nil
	local module = if services ~= nil then services:FindFirstChild("AdminService") else nil
	if module == nil or not module:IsA("ModuleScript") then
		return false
	end
	local ok, AdminService = pcall(require, module)
	if not ok or type(AdminService) ~= "table" or type((AdminService :: any).registerCommand) ~= "function" then
		warn("[PlotNameAdmin] AdminService could not be loaded; plot name admin command not registered")
		return false
	end
	installed = true
	local handler: Handler = function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		return Service.adminReset(player)
	end
	local registered, err = pcall((AdminService :: any).registerCommand, {
		name = "ResetPlotName",
		tab = "Players",
		label = "Reset Plot Name",
		description = "Clears their custom plot name; every sign shows the default name again.",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = true,
		confirm = true,
		color = "red",
		order = ORDER,
	}, handler)
	if not registered then
		warn(`[PlotNameAdmin] ResetPlotName not registered: {err}`)
		return false
	end
	return true
end

return PlotNameAdmin
