--!strict
--[[
	FlavorAdmin — the owner-admin controls of owner R89's Surprise Batches / Flavour Book / Big Pop
	(hard rule 9: every system is controllable from the admin panel), registered at runtime with
	AdminService.registerCommand through a GUARDED lazy require (the PlotNameAdmin /
	GemUpgradeSettings pattern): when Services/AdminService is missing nothing is registered and
	nothing errors. AdminService authorises, validates, rate limits and audits before a handler runs.

	Commands
		FlavorSettings   Economy tab, target None: { enabled, odds 0..10, bigPop } — this server's
		                 kill switch (off = every batch Plain; the Book + claims keep working), the
		                 odds multiplier on every special flavour (x1 = normal; it multiplies the
		                 Happy Hour luck, clamped to FlavorConfig.MaxLuck) and the Big Pop switch.
		FlavorGrant      Players tab, target Player: { flavor } — their NEXT finished batch in the
		                 world they are in becomes that flavour (QA of the whole pipeline: bonus,
		                 pop, glow, reveal, Big Pop, discovery toast).
		FlavorBookReset  Players tab, Studio only, confirm: clears their Flavour Book (found +
		                 claimed) — re-claimable gems, so never live.

	Connects to: Server/Services/AdminService (registerCommand), Server/Tycoon/FlavorService (passed
	in: settings / setSettings / adminForce / adminReset), Shared/Config/FlavorConfig (enums).

	Usage: FlavorService.Start → FlavorAdmin.install(FlavorService)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)

local FlavorAdmin = {}

type Ctx = { args: { [string]: any }?, target: { player: Player?, label: string }? }
type Handler = (ctx: Ctx) -> (boolean, string)

-- Panel order: Economy after the gem upgrade (30); Players after the plot-name reset (390).
local ECONOMY_ORDER = 40
local PLAYERS_ORDER = 395

local installed = false

-- The command's target player (nil when not aimed at an online player).
local function targetOf(ctx: Ctx): Player?
	local target = ctx.target
	return if target ~= nil then target.player else nil
end

-- The command's validated args (an empty table when missing).
local function argsOf(ctx: Ctx): { [string]: any }
	local args = ctx.args
	return if type(args) == "table" then args else {}
end

--[[
	Registers the three commands (idempotent).
	@param Service any — Server/Tycoon/FlavorService
	@return boolean — true when AdminService accepted them
]]
function FlavorAdmin.install(Service: any): boolean
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
		warn("[FlavorAdmin] AdminService could not be loaded; flavour admin commands not registered")
		return false
	end
	installed = true
	local register = (AdminService :: any).registerCommand

	local settings: Handler = function(ctx: Ctx): (boolean, string)
		local args = argsOf(ctx)
		local odds = args.odds
		if type(odds) ~= "number" then
			return false, "Pick an odds multiplier"
		end
		return Service.setSettings(args.enabled ~= false, odds, args.bigPop ~= false)
	end
	local grant: Handler = function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		return Service.adminForce(player, argsOf(ctx).flavor)
	end
	local reset: Handler = function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		return Service.adminReset(player)
	end

	local all = true
	for _, entry in
		{
			{
				def = {
					name = "FlavorSettings",
					tab = "Economy",
					label = "Surprise Batches",
					description = "Flavours on/off, odds multiplier on every special flavour (x1 = normal) and the Big Pop broadcast, this server.",
					target = "None",
					args = {
						enabled = { kind = "boolean", label = "Flavours on", default = true },
						odds = {
							kind = "number",
							min = FlavorConfig.MinLuck,
							max = FlavorConfig.MaxLuck,
							label = "Odds x",
							presets = { 0, 1, 2, 5, 10 },
							default = 1,
						},
						bigPop = { kind = "boolean", label = "Big Pop on", default = true },
					},
					argOrder = { "enabled", "odds", "bigPop" },
					cooldown = 1,
					audited = true,
					confirm = false,
					color = "purple",
					order = ECONOMY_ORDER,
				},
				handler = settings,
			},
			{
				def = {
					name = "FlavorGrant",
					tab = "Players",
					label = "Grant Flavour Batch",
					description = "Their NEXT batch in the world they are in becomes this flavour (QA: pop, glow, reveal, Big Pop, Book).",
					target = "Player",
					args = {
						flavor = {
							kind = "enum",
							values = FlavorConfig.SpecialIds,
							labels = FlavorConfig.SpecialNames,
							label = "Flavour",
							default = "galaxy",
						},
					},
					argOrder = { "flavor" },
					cooldown = 1,
					audited = true,
					confirm = false,
					color = "purple",
					order = PLAYERS_ORDER,
				},
				handler = grant,
			},
			{
				def = {
					name = "FlavorBookReset",
					tab = "Players",
					label = "Reset Flavour Book",
					description = "Clears their Flavour Book (found + claimed). Studio only (rewards become claimable again).",
					target = "Player",
					args = {},
					cooldown = 1,
					audited = true,
					confirm = true,
					color = "red",
					studioOnly = true,
					order = PLAYERS_ORDER + 1,
				},
				handler = reset,
			},
		}
	do
		local registered, err = pcall(register, entry.def, entry.handler)
		if not registered then
			all = false
			warn(`[FlavorAdmin] {entry.def.name} not registered: {err}`)
		end
	end
	return all
end

return FlavorAdmin
