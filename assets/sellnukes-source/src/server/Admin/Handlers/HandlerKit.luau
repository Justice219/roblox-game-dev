--!strict
--[[
	HandlerKit — shared helpers for the built-in admin command handlers (Server/Admin/Handlers/*).

	What is here:
		- the handler types re-exported from AdminRegistry (Context, Handler, Probe),
		- `Env`: what AdminService hands every handler module at install time (protection checks,
		  the online-admin verdict),
		- typed accessors for VALIDATED args (`num`, `str`),
		- `filterBroadcastAsync`: TextService filtering for text shown to everyone (fails closed:
		  nil means "drop it", never "show it unfiltered"),
		- seam probes: `serviceProbe(service, fn, provider)` / `tycoonProbe(fn)` return a Probe
		  that reports "needs <provider>" while the function does not exist,
		- `loadedProfile(player)`, `label(player)`, `money(n)`.

	Connects to: Server/Admin/AdminRegistry (types), Server/Admin/Seams, Server/Services/
	PlayerDataService (profiles), TextService.

	Example:
		local Kit = require(script.Parent.HandlerKit)
		registry.setBuiltin("GrantSpins", grantSpins,
			Kit.serviceProbe("LuckySpinService", "grantSpins", Kit.RETENTION))
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local AdminRegistry = require(script.Parent.Parent.AdminRegistry)
local PlayerDataService = require(script.Parent.Parent.Parent.Services.PlayerDataService)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Seams = require(script.Parent.Parent.Seams)

export type Context = AdminRegistry.Context
export type Handler = AdminRegistry.Handler
export type Probe = AdminRegistry.Probe
export type Registry = AdminRegistry.Registry

--[[ What AdminService passes to every handler module's install(registry, env). ]]
export type Env = {
	-- True if `userId` must not be kicked / banned (owner, allowlist, group admins, online admins).
	isProtectedAsync: (userId: number) -> boolean,
	-- The cached admin verdict of an online player (never yields).
	isAdmin: (player: Player) -> boolean,
}

local HandlerKit = {}

-- Provider names shown on greyed buttons (match AdminConfig's providers).
HandlerKit.TYCOON = "needs Tycoon (B5 TycoonAdmin)"
HandlerKit.RETENTION = "needs Retention (B7)"
HandlerKit.SANDBOX = "needs PlayerDataService sandbox (B1)"
HandlerKit.ANALYTICS = "needs Analytics (B13)"

--[[ A validated numeric arg (the schema already checked it; nil when absent / optional). ]]
function HandlerKit.num(ctx: Context, key: string): number?
	local value = ctx.args[key]
	return if type(value) == "number" then value else nil
end

--[[ A validated string arg (nil when absent / optional). ]]
function HandlerKit.str(ctx: Context, key: string): string?
	local value = ctx.args[key]
	return if type(value) == "string" then value else nil
end

--[[ The target player of a Player-target command (the pipeline guarantees it is online). ]]
function HandlerKit.targetPlayer(ctx: Context): Player
	local player = ctx.target.player
	assert(player ~= nil, "Player-target commands always resolve to an online player")
	return player
end

--[[ "Name (123)" for logs and messages. ]]
function HandlerKit.label(player: Player): string
	return `{player.Name} ({player.UserId})`
end

--[[ "$1.25K" (NumberFormat.money). ]]
function HandlerKit.money(n: number): string
	return NumberFormat.money(n)
end

--[[ "1.25K" (NumberFormat.short). ]]
function HandlerKit.short(n: number): string
	return NumberFormat.short(n)
end

--[[
	Filters `text` for display to everyone (TextService, from `fromUserId`). Returns nil when
	filtering fails on a live server — callers must then drop or replace the text, never show it
	unfiltered. (Studio-only fallback: see the comment in the body.) Yields.
	Example: local shown = HandlerKit.filterBroadcastAsync("Hello!", caller.userId)
]]
function HandlerKit.filterBroadcastAsync(text: string, fromUserId: number): string?
	local ok, result = pcall(function(): string
		local filterResult = TextService:FilterStringAsync(text, fromUserId, Enum.TextFilterContext.PublicChat)
		return filterResult:GetNonChatStringForBroadcastAsync()
	end)
	if ok and type(result) == "string" then
		return result
	end
	if not ok then
		warn(`[AdminService] text filtering failed: {result}`)
	end
	-- Studio only: local test servers give players negative UserIds, which TextService refuses.
	-- A Studio server is never live (only the developer sees it), so the admin's own text is
	-- shown there so announcements / reasons can be verified. Live servers always fail closed.
	if RunService:IsStudio() then
		return text
	end
	return nil
end

--[[
	A probe for a function on a server service: nil while it exists, else `provider` text.
	Example: Kit.serviceProbe("BoostService", "grant", Kit.RETENTION)
]]
function HandlerKit.serviceProbe(serviceName: string, fnName: string, provider: string): Probe
	return function(): string?
		return if Seams.has(Seams.service(serviceName), fnName) then nil else provider
	end
end

--[[ A probe for a TycoonAdmin function (B5 seam). ]]
function HandlerKit.tycoonProbe(fnName: string): Probe
	return function(): string?
		return if Seams.has(Seams.tycoonAdmin(), fnName) then nil else HandlerKit.TYCOON
	end
end

--[[
	Calls a seam function that follows the `(ok: boolean, message: string?)` convention and turns
	its answer into a handler result. Missing function → (false, provider text).
	@param fallback message used when the seam returns no message
	Example: return Kit.seamResult(Seams.tycoonAdmin(), "setArea", Kit.TYCOON, "Area set", player, 3)
]]
function HandlerKit.seamResult(
	module: any,
	fnName: string,
	provider: string,
	fallback: string,
	...: any
): (boolean, string)
	local found, ok, message = Seams.call(module, fnName, ...)
	if not found then
		return false, provider
	end
	local text = if type(message) == "string" and message ~= "" then message else nil
	if ok == true then
		return true, text or fallback
	end
	return false, text or `{fallback}: refused`
end

--[[ The player's loaded profile through PlayerDataService (nil until loaded / after leaving). ]]
function HandlerKit.loadedProfile(player: Player): any
	return PlayerDataService.getProfile(player)
end

return table.freeze(HandlerKit)
