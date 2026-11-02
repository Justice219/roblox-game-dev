--!strict
--[[
	AdminPipeline — the ordered, fail-closed admin command pipeline (spec §14):

		AdminCommand(name, args)
		  → [token bucket: AdminService.submit, before any work is spawned]
		  1. re-authorisation (EVERY call; non-admins are dropped silently + audited, throttled)
		  2. allowlist (the command name must be declared: AdminConfig or registered)
		  3. availability (Studio-only commands outside Studio, missing seams → refused)
		  4. per-admin per-command cooldown
		  5. strict argument schema (AdminValidate.validateArgs: unknown / extra args rejected)
		  6. target resolution (user ids are lookup keys → a real Player in this server)
		  7. handler, pcall'd (a throw becomes "internal error: ..." + a server warning)
		  8. audit log (audited commands + every failure) → result to the caller (AdminResult +
		     toast) → CommandExecuted

	Every refusal returns `{ ok = false, message }`; nothing past a failed step runs. The pipeline
	is PURE: authorisation, clocks, target resolution and delivery are injected, so
	tests/admin-pipeline.luau proves the order and every refusal path under Lune with fakes.

	Connects to: Server/Admin/AdminRegistry (allowlist + handlers), Server/Admin/AdminValidate,
	Server/Admin/AdminAudit, Server/Services/AdminService (builds the live deps).

	Example:
		local pipeline = AdminPipeline.new({ registry = registry, audit = audit,
			authorize = function(caller) return AdminAuth.isAuthorizedAsync(caller.userId) end,
			isStudio = function() return RunService:IsStudio() end, now = os.clock,
			resolveTarget = resolveTarget, deliver = deliver })
		local result = pipeline.dispatchAsync(caller, "GrantGems", { userId = 2, amount = 10 })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local AdminAudit = require(script.Parent.AdminAudit)
local AdminRegistry = require(script.Parent.AdminRegistry)
local AdminValidate = require(script.Parent.AdminValidate)

type CommandDef = AdminConfig.CommandDef
type ResultPayload = AdminConfig.ResultPayload
type Caller = AdminRegistry.Caller
type Target = AdminRegistry.Target

export type CommandResult = { ok: boolean, message: string }

export type Deps = {
	registry: AdminRegistry.Registry,
	audit: AdminAudit.Audit,
	-- Full authorisation check (may yield). NEVER the client's IsAdmin attribute.
	authorize: (caller: Caller) -> boolean,
	isStudio: () -> boolean,
	-- Monotonic seconds (cooldowns).
	now: () -> number,
	-- Validated args → a real target (or the reason it cannot be resolved).
	resolveTarget: (def: CommandDef, args: AdminValidate.ValidatedArgs) -> (Target?, string?),
	-- Sends the result to the caller (AdminResult remote + toast). Never called for denied calls.
	deliver: (caller: Caller, result: ResultPayload) -> (),
	onExecuted: ((caller: Caller, name: string, ok: boolean, message: string) -> ())?,
	-- Server warning sink (default `warn`).
	warn: ((message: string) -> ())?,
}

export type Pipeline = {
	dispatchAsync: (caller: Caller, rawName: unknown, rawArgs: unknown) -> CommandResult,
	forget: (userId: number) -> (),
}

local AdminPipeline = {}

-- Max characters of a message returned to the caller / written to the log.
local MESSAGE_MAX = 160
-- The message of a dropped non-admin call (audit only; the caller is told nothing).
local DENIED_RESULT = "DENIED: not an admin (call dropped)"

--[[
	Builds a pipeline over injected dependencies (see Deps).
	@return the Pipeline API
]]
function AdminPipeline.new(deps: Deps): Pipeline
	local registry = deps.registry
	local audit = deps.audit
	local warnSink = deps.warn or warn
	-- Per admin, per command: the clock time of the last accepted use (cooldowns).
	local lastUse: { [number]: { [string]: number } } = {}
	local resultSeq = 0

	-- Sanitised, bounded message.
	local function clean(message: unknown): string
		return AdminValidate.sanitizeForLog(message, MESSAGE_MAX)
	end

	-- Delivers a result to the caller (never throws into the pipeline).
	local function reply(caller: Caller, name: string, ok: boolean, message: string)
		resultSeq += 1
		local payload: ResultPayload = { seq = resultSeq, ok = ok, name = name, text = message }
		local okCall, err = pcall(deps.deliver, caller, payload)
		if not okCall then
			warnSink(`[AdminPipeline] deliver failed: {err}`)
		end
	end

	-- A refusal: optional audit, reply, result.
	local function refuse(caller: Caller, name: string, message: string, auditArgs: string?): CommandResult
		if auditArgs ~= nil then
			audit.append(caller, name, auditArgs, false, message)
		end
		reply(caller, name, false, message)
		return { ok = false, message = message }
	end

	local pipeline = {} :: Pipeline

	--[[
		Runs one command through every step (see the header). Yields (authorisation lookups,
		handlers). Never throws.
		@return { ok, message }
	]]
	function pipeline.dispatchAsync(caller: Caller, rawName: unknown, rawArgs: unknown): CommandResult
		-- 1. Re-authorisation on EVERY call. A failing check (even an error) denies.
		local okAuth, authorized = pcall(deps.authorize, caller)
		if not okAuth or authorized ~= true then
			if audit.allowLog(caller.userId, "denied") then
				local known = registry.isKnown(rawName)
				local shown = if known then rawName :: string else "<unknown>"
				audit.append(caller, shown, "", false, DENIED_RESULT)
			end
			return { ok = false, message = "Not authorized" }
		end

		-- 2. Allowlisted command name.
		if not registry.isKnown(rawName) then
			local shown = `<{AdminValidate.sanitizeForLog(rawName, 24)}>`
			return refuse(caller, shown, "Unknown command", if audit.allowLog(caller.userId, "reject") then "" else nil)
		end
		local name = rawName :: string
		local def, handler = registry.get(name)
		assert(def ~= nil, "isKnown guarantees a def")

		-- 3. Availability (Studio-only outside Studio, a missing seam, no handler).
		local unavailable = registry.availability(name, deps.isStudio())
		if unavailable ~= "" or handler == nil then
			local reason = if unavailable ~= "" then unavailable else "not available"
			return refuse(
				caller,
				name,
				clean(`{def.label}: {reason}`),
				if def.audited and audit.allowLog(caller.userId, "reject") then "" else nil
			)
		end

		-- 4. Per-admin cooldown for this command (no audit: a double tap is not an incident).
		local now = deps.now()
		local uses = lastUse[caller.userId]
		if uses == nil then
			uses = {}
			lastUse[caller.userId] = uses
		end
		local last = uses[name]
		if last ~= nil and now - last < def.cooldown then
			return refuse(caller, name, clean(`{def.label}: please wait a moment`), nil)
		end
		uses[name] = now

		-- 5. Strict argument schema.
		local args, argError = AdminValidate.validateArgs(def, rawArgs)
		if args == nil then
			return refuse(
				caller,
				name,
				clean(`{def.label}: {argError or "invalid arguments"}`),
				if audit.allowLog(caller.userId, "reject") then "<rejected>" else nil
			)
		end
		local summary = AdminValidate.summarizeArgs(args)

		-- 6. Target resolution.
		local okTarget, target, targetError = pcall(deps.resolveTarget, def, args)
		if not okTarget or target == nil then
			local reason = if okTarget then targetError or "invalid target" else "target lookup failed"
			return refuse(caller, name, clean(`{def.label}: {reason}`), if def.audited then summary else nil)
		end

		-- 7. Execute (a handler error never escapes and is reported like any other failure).
		local okCall, outcome, message = pcall(handler :: AdminRegistry.Handler, {
			caller = caller,
			args = args,
			target = target :: Target,
		})
		local ok: boolean
		local text: string
		if not okCall then
			ok = false
			text = clean(`internal error: {outcome}`)
			warnSink(`[AdminService] {name} handler error: {outcome}`)
		elseif type(outcome) ~= "boolean" then
			ok = false
			text = clean(`{def.label}: the handler returned no result`)
			warnSink(`[AdminService] {name} handler returned {typeof(outcome)} instead of (boolean, string)`)
		else
			ok = outcome
			text =
				clean(if type(message) == "string" and message ~= "" then message elseif ok then "Done" else "Failed")
		end

		-- 8. Audit + feedback.
		if def.audited or not ok then
			audit.append(caller, name, summary, ok, text)
		end
		reply(caller, name, ok, text)
		local onExecuted = deps.onExecuted
		if onExecuted ~= nil then
			local okSignal, err = pcall(onExecuted, caller, name, ok, text)
			if not okSignal then
				warnSink(`[AdminPipeline] onExecuted failed: {err}`)
			end
		end
		return { ok = ok, message = text }
	end

	--[[ Drops the cooldown state of a user who left. ]]
	function pipeline.forget(userId: number)
		lastUse[userId] = nil
	end

	return pipeline
end

return table.freeze(AdminPipeline)
