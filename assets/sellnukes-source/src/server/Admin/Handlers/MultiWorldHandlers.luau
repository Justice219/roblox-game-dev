--!strict
--[[
	MultiWorldHandlers — built-in handlers of the admin panel's World* commands (owner R57 World 2
	"Dino Valley", spec §13; hard rule 9 "every system is controllable from the admin panel").
	The commands are declared in Shared/Config/AdminConfig.Commands (provider "Worlds (W4
	MultiWorldHandlers)"); AdminService validates every argument against those schemas, re-checks
	the caller's admin rights and writes the audit log BEFORE / AFTER a handler runs. `world` is
	always an enum of the extra world ids, so a handler only ever sees a registry world.

	Commands (Players tab, target = an online player; Server tab: WorldEnabled)
		WorldUnlock        { world }                 WorldService.unlock(p, w, "admin") (sticky)
		WorldRelock        { world }                 WorldService.relock (re-test the popup flow)
		WorldSetArea       { world, area }           TycoonAdmin.worldSetArea (area <= that world's count)
		WorldUnlockAll     { world }                 TycoonAdmin.worldUnlockAll
		WorldResetRun      { world }                 TycoonAdmin.worldResetRun (tycoon + currency)
		WorldWipe          { world }                 TycoonAdmin.worldWipe (+ rebirths, tokens, shop)
		WorldGrantCash     { world, amount }         PlayerDataService.grantCurrency(world currency)
		WorldSetCash       { world, amount }         that world's balance := amount (not "earned")
		WorldSetRebirths   { world, rebirths }       TycoonAdmin.worldSetRebirths
		WorldGrantTokens   { world, amount }         PlayerDataService.grantWorldTokens
		WorldSend          { world (+ main), to }    WorldService.adminSend (spawn / own plot; warp)
		WorldRebuildPlot   { world, replay }         TycoonAdmin.worldRebuildPlot
		WorldOfflinePreview { hours }                TycoonAdmin.offlinePreview (read-only)
		WorldEnabled       { world, on }             WorldService.setEnabled (kill switch)

	Every seam is reached lazily through Admin/Seams (WorldService, TycoonAdmin), so the panel never
	requires gameplay code at load time; while a function is missing its button is greyed with the
	"needs ..." reason (probe) and the server refuses it. Destructive commands confirm in the panel.

	Connects to: Admin/Handlers/HandlerKit, Admin/Seams, Server/Tycoon/WorldService (W4),
	Server/Tycoon/TycoonAdmin (W3 per-world seam), Server/Services/PlayerDataService,
	Server/Economy/ProfileLogic, Shared/Config/Worlds/WorldsConfig, NumberFormat.

	Example:
		MultiWorldHandlers.install(registry, env)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HandlerKit = require(script.Parent.HandlerKit)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PlayerDataService = require(script.Parent.Parent.Parent.Services.PlayerDataService)
local ProfileLogic = require(script.Parent.Parent.Parent.Economy.ProfileLogic)
local Seams = require(script.Parent.Parent.Seams)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type Context = HandlerKit.Context
type WorldDef = WorldsConfig.WorldDef

local MultiWorldHandlers = {}

local Kit = HandlerKit
-- Greyed-button reasons while a seam is missing.
MultiWorldHandlers.NEEDS_WORLDS = "needs Worlds (R57 Server/Tycoon/WorldService)"
MultiWorldHandlers.NEEDS_TYCOON = "needs Tycoon world seam (W3 TycoonAdmin)"
-- Cash cap of WorldSetCash (= ProfileLogic.Limits.MaxCash).
local MAX_CASH = ProfileLogic.Limits.MaxCash
-- Friendly failure texts for WorldService travel reasons (admin WorldSend).
local SEND_FAIL: { [string]: string } = {
	unknownWorld = "unknown world",
	badTarget = "bad destination",
	disabled = "that world is switched off",
	locked = "they haven't unlocked it (use Unlock World first)",
	noPlot = "they have no plot yet",
	revealPending = "their plot reveal is still playing",
	dead = "their character isn't alive",
	busy = "they are already travelling",
	cooldown = "travel cooldown",
	areaLocked = "that area is locked",
	plotEmpty = "nobody owns that plot",
	noPass = "Teleporter pass needed",
}

-- The world of a command's validated `world` arg (the schema guarantees a registry id).
local function worldOf(ctx: Context): WorldDef?
	return WorldsConfig.get(Kit.str(ctx, "world"))
end

-- WorldService, or nil while it is missing / broken.
local function worldService(): any
	local module = Seams.worldService()
	return if type(module) == "table" then module else nil
end

-- Probe: nil while WorldService has `fnName`, else the greyed reason.
local function worldProbe(fnName: string): HandlerKit.Probe
	return function(): string?
		return if Seams.has(Seams.worldService(), fnName) then nil else MultiWorldHandlers.NEEDS_WORLDS
	end
end

-- Probe: nil while TycoonAdmin has the per-world `fnName`, else the greyed reason.
local function tycoonProbe(fnName: string): HandlerKit.Probe
	return function(): string?
		return if Seams.has(Seams.tycoonAdmin(), fnName) then nil else MultiWorldHandlers.NEEDS_TYCOON
	end
end

-- "1.2K Bones" / "$1.2K" for a world's currency.
local function amountText(def: WorldDef, amount: number): string
	if def.currency.style == "money" then
		return NumberFormat.money(amount)
	end
	return `{NumberFormat.short(amount)} {def.currency.name}`
end

-- Calls a TycoonAdmin per-world function: (player, worldId, ...) → handler result.
local function tycoonWorld(ctx: Context, fnName: string, done: string, ...: any): (boolean, string)
	local def = worldOf(ctx)
	if def == nil then
		return false, "unknown world"
	end
	local player = Kit.targetPlayer(ctx)
	return Kit.seamResult(
		Seams.tycoonAdmin(),
		fnName,
		MultiWorldHandlers.NEEDS_TYCOON,
		`{done} ({def.name}) for {Kit.label(player)}`,
		player,
		def.id,
		...
	)
end

-- WorldUnlock
local function unlock(ctx: Context): (boolean, string)
	local service, def = worldService(), worldOf(ctx)
	if service == nil then
		return false, MultiWorldHandlers.NEEDS_WORLDS
	end
	if def == nil then
		return false, "unknown world"
	end
	local player = Kit.targetPlayer(ctx)
	if service.isUnlocked(player, def.id) then
		return true, `{def.name} is already unlocked for {Kit.label(player)}`
	end
	if not service.unlock(player, def.id, "admin") then
		return false, "profile not loaded"
	end
	return true, `{def.name} unlocked for {Kit.label(player)}`
end

-- WorldRelock
local function relock(ctx: Context): (boolean, string)
	local service, def = worldService(), worldOf(ctx)
	if service == nil then
		return false, MultiWorldHandlers.NEEDS_WORLDS
	end
	if def == nil then
		return false, "unknown world"
	end
	local player = Kit.targetPlayer(ctx)
	if not service.relock(player, def.id) then
		return false, `{def.name} is not unlocked for {Kit.label(player)}`
	end
	return true, `{def.name} re-locked for {Kit.label(player)} (progress kept)`
end

-- WorldSetArea (area re-checked against THAT world's count; the schema allows the largest world's).
local function setArea(ctx: Context): (boolean, string)
	local def = worldOf(ctx)
	local area = Kit.num(ctx, "area") or 1
	if def ~= nil and area > def.geometry.areaCount then
		return false, `{def.name} has {def.geometry.areaCount} areas`
	end
	return tycoonWorld(ctx, "worldSetArea", `area {area} reached`, area)
end

-- WorldGrantCash
local function grantCash(ctx: Context): (boolean, string)
	local def = worldOf(ctx)
	if def == nil then
		return false, "unknown world"
	end
	local player = Kit.targetPlayer(ctx)
	if PlayerDataService.getProfile(player) == nil then
		return false, "profile not loaded"
	end
	local amount = Kit.num(ctx, "amount") or 0
	local added = PlayerDataService.grantCurrency(player, def.currency.key, amount, "admin")
	if added <= 0 then
		return false, `nothing added (balance at the cap?)`
	end
	return true, `gave {amountText(def, added)} to {Kit.label(player)}`
end

-- WorldSetCash: the world's balance := amount (not counted as earned), pushed to the client.
local function setCash(ctx: Context): (boolean, string)
	local def = worldOf(ctx)
	if def == nil then
		return false, "unknown world"
	end
	local player = Kit.targetPlayer(ctx)
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false, "profile not loaded"
	end
	local amount = Kit.num(ctx, "amount") or 0
	if amount ~= amount or amount < 0 or amount > MAX_CASH then
		return false, "amount must be finite and >= 0"
	end
	ProfileLogic.worldState(profile, def.id).cash = amount
	PlayerDataService.markChanged(player, true, { "worldCash" })
	return true, `{def.name} balance set to {amountText(def, amount)} for {Kit.label(player)}`
end

-- WorldGrantTokens
local function grantTokens(ctx: Context): (boolean, string)
	local def = worldOf(ctx)
	if def == nil then
		return false, "unknown world"
	end
	local player = Kit.targetPlayer(ctx)
	if PlayerDataService.getProfile(player) == nil then
		return false, "profile not loaded"
	end
	local amount = Kit.num(ctx, "amount") or 0
	local added = PlayerDataService.grantWorldTokens(player, def.id, amount, "admin")
	if added <= 0 then
		return false, "nothing added (cap reached?)"
	end
	return true, `gave {NumberFormat.short(added)} {def.tokens.name} to {Kit.label(player)}`
end

-- WorldSend (the world enum includes Nuke Town here: send them home).
local function send(ctx: Context): (boolean, string)
	local service = worldService()
	if service == nil then
		return false, MultiWorldHandlers.NEEDS_WORLDS
	end
	local def = WorldsConfig.get(Kit.str(ctx, "world"))
	if def == nil then
		return false, "unknown world"
	end
	local to = if Kit.str(ctx, "to") == "plot" then "plot" else "spawn"
	local player = Kit.targetPlayer(ctx)
	local ok, reason = service.adminSend(player, def.id, to)
	if not ok then
		local why = if type(reason) == "string" then SEND_FAIL[reason] or reason else "refused"
		return false, `can't send {Kit.label(player)}: {why}`
	end
	return true, `sent {Kit.label(player)} to {def.name} ({if to == "plot" then "their plot" else "spawn"})`
end

-- WorldOfflinePreview: read-only payout per world.
local function offlinePreview(ctx: Context): (boolean, string)
	local admin = Seams.tycoonAdmin()
	if not Seams.has(admin, "offlinePreview") then
		return false, MultiWorldHandlers.NEEDS_TYCOON
	end
	local player = Kit.targetPlayer(ctx)
	local hours = Kit.num(ctx, "hours") or 1
	local ok, result = admin.offlinePreview(player, hours)
	if ok ~= true or type(result) ~= "table" then
		return false, if type(result) == "string" then result else "preview unavailable"
	end
	local parts: { string } = {}
	for _, worldId in WorldsConfig.Order do
		local def = WorldsConfig.get(worldId)
		local amount = result[worldId]
		if def ~= nil and type(amount) == "number" and amount == amount then
			table.insert(parts, `{def.name} {amountText(def, amount)}`)
		end
	end
	if #parts == 0 then
		return true, `{hours} h offline: nothing to pay`
	end
	return true, `{hours} h offline for {Kit.label(player)}: {table.concat(parts, " · ")}`
end

-- WorldEnabled: the kill switch.
local function enabled(ctx: Context): (boolean, string)
	local service, def = worldService(), worldOf(ctx)
	if service == nil then
		return false, MultiWorldHandlers.NEEDS_WORLDS
	end
	if def == nil then
		return false, "unknown world"
	end
	local on = ctx.args.on == true
	local inside = #service.playersIn(def.id)
	if not service.setEnabled(def.id, on) then
		return false, "that world can't be switched"
	end
	if on then
		return true, `{def.name} is OPEN`
	end
	return true, `{def.name} is CLOSED on this server ({inside} player(s) sent home; they keep earning)`
end

--[[ Installs every World* handler into the registry (AdminService.Init). ]]
function MultiWorldHandlers.install(registry: HandlerKit.Registry, _env: HandlerKit.Env)
	registry.setBuiltin("WorldUnlock", unlock, worldProbe("unlock"))
	registry.setBuiltin("WorldRelock", relock, worldProbe("relock"))
	registry.setBuiltin("WorldSetArea", setArea, tycoonProbe("worldSetArea"))
	registry.setBuiltin("WorldUnlockAll", function(ctx: Context): (boolean, string)
		return tycoonWorld(ctx, "worldUnlockAll", "every pad added")
	end, tycoonProbe("worldUnlockAll"))
	registry.setBuiltin("WorldResetRun", function(ctx: Context): (boolean, string)
		return tycoonWorld(ctx, "worldResetRun", "run reset")
	end, tycoonProbe("worldResetRun"))
	registry.setBuiltin("WorldWipe", function(ctx: Context): (boolean, string)
		return tycoonWorld(ctx, "worldWipe", "world wiped")
	end, tycoonProbe("worldWipe"))
	registry.setBuiltin("WorldGrantCash", grantCash)
	registry.setBuiltin("WorldSetCash", setCash)
	registry.setBuiltin("WorldSetRebirths", function(ctx: Context): (boolean, string)
		local rebirths = Kit.num(ctx, "rebirths") or 0
		return tycoonWorld(ctx, "worldSetRebirths", `rebirths set to {rebirths}`, rebirths)
	end, tycoonProbe("worldSetRebirths"))
	registry.setBuiltin("WorldGrantTokens", grantTokens)
	registry.setBuiltin("WorldSend", send, worldProbe("adminSend"))
	registry.setBuiltin("WorldRebuildPlot", function(ctx: Context): (boolean, string)
		local replay = ctx.args.replay == true
		return tycoonWorld(ctx, "worldRebuildPlot", if replay then "replaying build-in" else "plot rebuilt", replay)
	end, tycoonProbe("worldRebuildPlot"))
	registry.setBuiltin("WorldOfflinePreview", offlinePreview, tycoonProbe("offlinePreview"))
	registry.setBuiltin("WorldEnabled", enabled, worldProbe("setEnabled"))
end

return table.freeze(MultiWorldHandlers)
