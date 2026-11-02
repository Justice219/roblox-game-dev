--!strict
--[[
	KineticAdmin — owner-admin commands of the Mega Lever + Tip Jar (owner rule 9; docs/kinetic.md),
	registered through Server/Event/Lazy.registerAdmin (AdminService validates + audits them).

	Commands
		KineticSwitch      Server tab, target None: { lever, jar } — this server's kill switches
		                   (ReplicatedStorage attributes KineticLeverOn / KineticJarOn). Off = the
		                   prompt hides, intents are refused, the jar stops filling; nothing is
		                   removed (saved cooldowns + coins stay).
		KineticLeverReset  Players tab, target Player — the lever of the world they stand in is
		                   ready again (QA, or a support fix).
		KineticJarFill     Players tab, target Player — fills the jar of the world they stand in to
		                   its passive cap (QA of the payout + FX).
		KineticStatus      Server tab, target None — props placed / pending + pulls / payouts /
		                   tips and the currency paid since this server booted.

	Usage: KineticService.Start → KineticAdmin.install(MegaLever, TipJar, KineticWorld)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KineticAnalytics = require(script.Parent.KineticAnalytics)
local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)
local Lazy = require(script.Parent.Parent.Event.Lazy)

local ATTR = KineticConfig.Attr

-- Panel order: the Server tab after the Lucky Button commands (70..74); the Players tab after the
-- flavour commands (395).
local SERVER_ORDER = 76
local PLAYERS_ORDER = 397

local KineticAdmin = {}

local installed = false

type Ctx = { args: { [string]: any }?, target: { player: Player?, label: string }? }

-- The command's target player (nil when not aimed at an online player).
local function targetOf(ctx: Ctx): Player?
	local target = ctx.target
	return if target ~= nil then target.player else nil
end

--[[
	Registers the four commands (idempotent).
	@param MegaLever any — Server/Kinetic/MegaLever (adminReset, stats)
	@param TipJar any — Server/Kinetic/TipJar (adminFill, stats)
	@param KineticWorld any — Server/Kinetic/KineticWorld (counts)
]]
function KineticAdmin.install(MegaLever: any, TipJar: any, KineticWorld: any)
	if installed then
		return
	end
	installed = true
	Lazy.registerAdmin({
		name = "KineticSwitch",
		tab = "Server",
		label = "Mega Lever + Tip Jar",
		description = "This server's switches: OFF hides the prompt and refuses pulls / payouts (the jar stops filling). Saved cooldowns and coins are kept.",
		target = "None",
		args = {
			lever = { kind = "boolean", label = "Mega Lever on", default = true },
			jar = { kind = "boolean", label = "Tip Jar on", default = true },
		},
		argOrder = { "lever", "jar" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = SERVER_ORDER,
	}, function(ctx: any): (boolean, string)
		local args = if type(ctx.args) == "table" then ctx.args else {}
		local leverOn, jarOn = args.lever ~= false, args.jar ~= false
		ReplicatedStorage:SetAttribute(ATTR.LeverOn, leverOn)
		ReplicatedStorage:SetAttribute(ATTR.JarOn, jarOn)
		KineticAnalytics.record(nil, "admin:switch")
		return true, `Mega Lever {if leverOn then "ON" else "OFF"} · Tip Jar {if jarOn then "ON" else "OFF"}`
	end)
	Lazy.registerAdmin({
		name = "KineticLeverReset",
		tab = "Players",
		label = "Reset Mega Lever",
		description = "The Mega Lever of the world the player stands in is ready to pull again.",
		target = "Player",
		args = {},
		argOrder = {},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = PLAYERS_ORDER,
	}, function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		KineticAnalytics.record(nil, "admin:lever")
		return MegaLever.adminReset(player)
	end)
	Lazy.registerAdmin({
		name = "KineticJarFill",
		tab = "Players",
		label = "Fill Tip Jar",
		description = "Fills the Tip Jar of the world the player stands in to its cap (they still walk in to collect).",
		target = "Player",
		args = {},
		argOrder = {},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = PLAYERS_ORDER + 1,
	}, function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		KineticAnalytics.record(nil, "admin:fill")
		return TipJar.adminFill(player)
	end)
	Lazy.registerAdmin({
		name = "KineticStatus",
		tab = "Server",
		label = "Lever + Jar Status",
		description = "Props placed on this server and pulls / payouts / tips since it booted.",
		target = "None",
		args = {},
		argOrder = {},
		cooldown = 1,
		audited = false,
		confirm = false,
		color = "orange",
		order = SERVER_ORDER + 1,
	}, function(_ctx: any): (boolean, string)
		local props = KineticWorld.counts()
		local lever = MegaLever.stats()
		local jar = TipJar.stats()
		KineticAnalytics.record(nil, "admin:status")
		return true,
			string.format(
				"Props %d placed / %d loading · Lever %s, %d pulls (paid %.3g) · Jar %s, %d payouts (paid %.3g), %d tips",
				props.placed,
				props.pending,
				if ReplicatedStorage:GetAttribute(ATTR.LeverOn) ~= false then "ON" else "OFF",
				lever.pulls,
				lever.paid,
				if ReplicatedStorage:GetAttribute(ATTR.JarOn) ~= false then "ON" else "OFF",
				jar.collects,
				jar.paid,
				jar.tips
			)
	end)
end

return KineticAdmin
