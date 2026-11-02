--!strict
--[[
	AdminAudit — the admin audit log (spec §14 "audit log (ring buffer, printed to output)").

	Purpose:
		Every executed admin command (and every refused / failed one) becomes one entry: time,
		admin name + UserId, command, a sanitised summary of the VALIDATED arguments, ok, result.
		Entries live in a ring buffer of AdminConfig.AuditLogSize (oldest dropped first), are
		printed to the server output (print for OK, warn for FAILED — visible in the Creator Hub's
		server logs) and pushed to every admin's panel (Log tab) through `onAppend` listeners.

	Flood protection:
		Denied (non-admin) calls and malformed calls (unknown command / rejected arguments) point at
		a tampered client. The first one per user is always logged; repeats are throttled with
		`allowLog(userId, kind)` (once per DeniedLogIntervalSeconds per user per kind), so an
		exploiter can neither spam the output nor push genuine entries out of the ring buffer.

	Pure (no Roblox services; the clock is injectable): Lune tests drive it (tests/admin-pipeline).

	Connects to: Server/Admin/AdminPipeline (append, allowLog), Server/Admin/AdminStatePush (tail,
	version, onAppend → schedule a push), Server/Services/AdminService (getAuditLog).

	Example:
		local audit = AdminAudit.new()
		audit.append({ userId = 1, name = "Owner" }, "GrantGems", "amount=5 userId=2", true, "Gave 5 gems")
		print(#audit.tail(10)) --> 1
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local AdminValidate = require(script.Parent.AdminValidate)

export type AuditEntry = AdminConfig.AuditEntry

-- Who issued a command (built from the authentic remote Player, or a fake caller in tests).
export type Caller = { userId: number, name: string, player: Player? }

export type ThrottleKind = "denied" | "reject"

export type Options = {
	size: number?, -- ring buffer size (default AdminConfig.AuditLogSize)
	clock: (() -> number)?, -- monotonic seconds for the throttle (default os.clock)
	time: (() -> number)?, -- wall clock for entry timestamps (default os.time)
	quiet: boolean?, -- true = never print (tests)
}

export type Audit = {
	append: (caller: Caller, command: string, args: string, ok: boolean, result: string) -> AuditEntry,
	tail: (count: number?) -> { AuditEntry },
	version: () -> number,
	onAppend: (callback: (entry: AuditEntry) -> ()) -> (),
	allowLog: (userId: number, kind: ThrottleKind) -> boolean,
	forget: (userId: number) -> (),
	size: () -> number,
}

local AdminAudit = {}

-- Max characters kept of an entry's result / admin name.
local RESULT_MAX = 160
local NAME_MAX = 32
local COMMAND_MAX = 40
local ARGS_MAX = 300

--[[
	Creates an audit log (AdminService keeps one per server; tests make their own).
	@param options optional size / clocks / quiet
	@return the Audit API (see the type)
]]
function AdminAudit.new(options: Options?): Audit
	local opts: Options = options or {}
	local capacity = opts.size or AdminConfig.AuditLogSize
	local clock = opts.clock or os.clock
	local wallTime = opts.time or os.time
	local quiet = opts.quiet == true

	local entries: { AuditEntry } = {} -- oldest first
	local seq = 0
	local logVersion = 0
	local listeners: { (entry: AuditEntry) -> () } = {}
	local lastLogged: { [string]: number } = {} -- "<kind>:<userId>" → clock()

	local audit = {} :: Audit

	--[[ Appends an entry (cut to the ring size), prints it and notifies listeners. ]]
	function audit.append(caller: Caller, command: string, args: string, ok: boolean, result: string): AuditEntry
		seq += 1
		local entry: AuditEntry = {
			id = seq,
			time = wallTime(),
			adminName = AdminValidate.sanitizeForLog(caller.name, NAME_MAX),
			adminUserId = caller.userId,
			command = AdminValidate.sanitizeForLog(command, COMMAND_MAX),
			args = AdminValidate.sanitizeForLog(args, ARGS_MAX),
			ok = ok,
			result = AdminValidate.sanitizeForLog(result, RESULT_MAX),
		}
		table.insert(entries, entry)
		while #entries > capacity do
			table.remove(entries, 1)
		end
		logVersion += 1
		if not quiet then
			local line = `[Admin] #{entry.id} {entry.adminName} ({entry.adminUserId}) {entry.command}`
				.. (if entry.args ~= "" then ` {entry.args}` else "")
				.. ` -> {if ok then "OK" else "FAILED"}: {entry.result}`
			if ok then
				print(line)
			else
				warn(line)
			end
		end
		for _, listener in listeners do
			local okCall, err = pcall(listener, entry)
			if not okCall then
				warn(`[AdminAudit] listener failed: {err}`)
			end
		end
		return entry
	end

	--[[ The most recent `count` entries (default: all), oldest first, as a new array. ]]
	function audit.tail(count: number?): { AuditEntry }
		local n = math.min(count or #entries, #entries)
		local list: { AuditEntry } = {}
		for index = #entries - n + 1, #entries do
			table.insert(list, entries[index])
		end
		return list
	end

	--[[ Increments on every append (the state push sends the log only when it changed). ]]
	function audit.version(): number
		return logVersion
	end

	--[[ Registers a listener called after every append (never yields; pcall'd). ]]
	function audit.onAppend(callback: (entry: AuditEntry) -> ())
		table.insert(listeners, callback)
	end

	--[[
		Flood throttle: true when a `kind` entry for this user may be written now (the first one
		always; then at most once per AdminConfig.DeniedLogIntervalSeconds).
	]]
	function audit.allowLog(userId: number, kind: ThrottleKind): boolean
		local key = `{kind}:{userId}`
		local now = clock()
		local last = lastLogged[key]
		if last ~= nil and now - last < AdminConfig.DeniedLogIntervalSeconds then
			return false
		end
		lastLogged[key] = now
		return true
	end

	--[[ Drops the throttle state of a user who left. ]]
	function audit.forget(userId: number)
		lastLogged[`denied:{userId}`] = nil
		lastLogged[`reject:{userId}`] = nil
	end

	--[[ Current number of entries in the ring buffer. ]]
	function audit.size(): number
		return #entries
	end

	return audit
end

return table.freeze(AdminAudit)
