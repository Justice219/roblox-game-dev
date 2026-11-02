--!strict
--[[
	ReturnNotifyAdmin — the owner admin panel's RETURN NOTIFICATIONS commands (owner R122 §2.3:
	"kill switch, per-kind on/off, queue size, last results, send test to me (owner only, dry-run
	in Studio)"). The commands are declared in Shared/Config/AdminConfig (Server tab, provider
	"Return notifications (R122 ReturnNotifyService)"); this module supplies their handlers with
	AdminService.registerHandler through a GUARDED lazy require (no AdminService = nothing
	registered, nothing errors). AdminService re-authorises, validates, rate-limits and audits
	every call before a handler runs.

	Commands:
		NotifyToggle     { mode = on | off }        universe kill switch (ReturnNotifyControl.apply)
		NotifyKind       { kind, mode = on | off }   one kind on / off everywhere
		NotifyStatus     {}                          mode, switches, queue size + due now, this
		                                             server's counters + last result (read-only)
		NotifyTest       { kind }                    one REAL notification to the caller: live =
		                                             OWNER ONLY (AdminConfig.OwnerUserId / the
		                                             creator); Studio = dry run for any admin
		NotifyQueueTest  { kind, seconds }           Studio only: queues an entry for the caller due
		                                             in `seconds` (0 = poll now) through the REAL
		                                             queue + claim + dry send
	The panel's Server tab shows the live switch state (Client/UI/Screens/Admin/NotifySection,
	from the ReplicatedStorage attributes ReturnNotifyControl publishes) above these forms.

	Connects to: Server/Services/AdminService (registerHandler), Server/Retention/
	{ReturnNotifyControl, ReturnNotifyLogic, ReturnNotifyRunner, ReturnNotifyQueue,
	ReturnNotifySender}, Server/Services/PlayerDataService (the caller's daily day for the streak
	test), Shared/Config/{AdminConfig, NotifyConfig, RetentionConfig}.

	Example (ReturnNotifyService.Start):
		ReturnNotifyAdmin.install({ runner = runner, queue = queue, sender = sender,
			isStudio = RunService:IsStudio(), kinds = kinds, pollNow = function() runner.pollOnce() end })
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local NotifyConfig = require(ReplicatedStorage.Shared.Config.NotifyConfig)
local PlayerDataService = require(ServerScriptService.Server.Services.PlayerDataService)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local ReturnNotifyControl = require(script.Parent.ReturnNotifyControl)
local ReturnNotifyLogic = require(script.Parent.ReturnNotifyLogic)
local ReturnNotifyQueue = require(script.Parent.ReturnNotifyQueue)
local ReturnNotifyRunner = require(script.Parent.ReturnNotifyRunner)
local ReturnNotifySender = require(script.Parent.ReturnNotifySender)

type Kind = NotifyConfig.Kind

export type Deps = {
	runner: ReturnNotifyRunner.Runner?, -- nil when the queue could not be created
	queue: ReturnNotifyQueue.Queue?,
	sender: ReturnNotifySender.Sender,
	isStudio: boolean,
	kinds: ReturnNotifyLogic.Kinds, -- NotifyConfig.kindsFor(isStudio)
	pollNow: () -> (),
}

-- AdminService's validated command context (AdminRegistry.Context).
type Ctx = {
	caller: { userId: number, name: string, player: Player? },
	args: { [string]: any },
	target: { userId: number?, player: Player?, label: string },
}

local ReturnNotifyAdmin = {}

local installed = false

--[[
	True when `userId` is the experience owner (AdminConfig.OwnerUserId, or the creator of a
	user-owned experience). Group admins and the allowlist are NOT owners.
]]
function ReturnNotifyAdmin.isOwner(userId: number): boolean
	if userId == AdminConfig.OwnerUserId then
		return true
	end
	return game.CreatorType == Enum.CreatorType.User and userId == game.CreatorId and userId > 0
end

-- The test parameters of a kind for `player` (streak: the Daily card they would see next).
local function testParams(kind: Kind, player: Player?): { [string]: string }?
	if kind ~= "streak" then
		return nil
	end
	local day = 1
	local profile = if player ~= nil then PlayerDataService.getProfile(player) else nil
	if profile ~= nil then
		local today = RetentionConfig.utcDay(os.time())
		local daily = profile.daily
		day = if daily.lastDay == today
			then RetentionConfig.dailyStatus(daily, today + 1).nextIndex
			else RetentionConfig.dailyStatus(daily, today).nextIndex
	end
	return { day = tostring(day) }
end

-- "on" / "off" → boolean.
local function isOn(mode: unknown): boolean
	return mode == "on"
end

--[[
	The NotifyStatus text (yields on two MemoryStore reads).
	@return string (<= 300 bytes)
]]
local function statusText(deps: Deps): string
	local runner = deps.runner
	local queue = deps.queue
	local stats = if runner ~= nil then runner.stats() else nil
	local mode: string = if not NotifyConfig.Enabled
		then "off"
		elseif runner == nil then "noqueue"
		else deps.sender.mode()
	local now = os.time()
	local size = if queue ~= nil then queue.size() else nil
	local due = if queue ~= nil and size ~= nil then queue.dueCount(now, NotifyConfig.Queue.StatusScan) else nil
	return ReturnNotifyLogic.statusText({
		mode = mode,
		control = ReturnNotifyControl.current(),
		queueSize = size,
		dueNow = due,
		planned = if stats ~= nil then stats.planned else {},
		sent = if stats ~= nil then stats.sent else {},
		results = if stats ~= nil then stats.results else {},
		drops = if stats ~= nil then stats.drops else {},
		recent = if stats ~= nil then stats.recent else {},
		backoffLeft = if stats ~= nil then stats.backoffLeft else 0,
		queueError = if queue ~= nil then queue.lastError() else "MemoryStore unavailable",
	}, deps.kinds)
end

--[[
	Registers the handlers with AdminService (idempotent; guarded).
	@return true when AdminService took them
]]
function ReturnNotifyAdmin.install(deps: Deps): boolean
	if installed then
		return true
	end
	local module = ServerScriptService.Server.Services:FindFirstChild("AdminService")
	if module == nil or not module:IsA("ModuleScript") then
		return false
	end
	local ok, AdminService = pcall(require, module)
	if not ok or type(AdminService) ~= "table" or type((AdminService :: any).registerHandler) ~= "function" then
		warn("[ReturnNotify] AdminService could not be loaded; notification admin commands not registered")
		return false
	end
	installed = true
	local register = (AdminService :: any).registerHandler

	local function guarded(name: string, handler: (ctx: Ctx) -> (boolean, string))
		local registered, err = pcall(register, name, handler)
		if not registered then
			warn(`[ReturnNotify] {name} not registered: {err}`)
		end
	end

	guarded("NotifyToggle", function(ctx: Ctx): (boolean, string)
		local on = isOn(ctx.args.mode)
		local control, persisted = ReturnNotifyControl.apply(function(base, version)
			return ReturnNotifyLogic.withOn(base, on, version)
		end)
		local scope = if persisted then "every server" else "THIS server only (store unavailable)"
		return control.on == on, `Return notifications {if on then "ON" else "OFF"} on {scope}`
	end)

	guarded("NotifyKind", function(ctx: Ctx): (boolean, string)
		local kind = ctx.args.kind
		if not NotifyConfig.isKind(kind) then
			return false, "Unknown kind"
		end
		local on = isOn(ctx.args.mode)
		local control, persisted = ReturnNotifyControl.apply(function(base, version)
			return ReturnNotifyLogic.withKind(base, kind :: Kind, on, version)
		end)
		local scope = if persisted then "every server" else "THIS server only (store unavailable)"
		local note = if NotifyConfig.isMessageId(deps.kinds[kind :: Kind].messageId)
			then ""
			else " (no message id yet: still off)"
		return (control.off[kind] ~= true) == on, `{kind} {if on then "ON" else "OFF"} on {scope}{note}`
	end)

	guarded("NotifyStatus", function(_ctx: Ctx): (boolean, string)
		return true, statusText(deps)
	end)

	guarded("NotifyTest", function(ctx: Ctx): (boolean, string)
		local kind = ctx.args.kind
		if not NotifyConfig.isKind(kind) then
			return false, "Unknown kind"
		end
		local userId = ctx.caller.userId
		if not deps.isStudio and not ReturnNotifyAdmin.isOwner(userId) then
			return false, "Only the experience owner can send a test notification"
		end
		local runner = deps.runner
		if runner == nil then
			return false, "Notifications are not running on this server (MemoryStore unavailable)"
		end
		local player = ctx.caller.player or Players:GetPlayerByUserId(userId)
		local result = runner.sendTest(player, userId, kind :: Kind, testParams(kind :: Kind, player))
		local detail = if result.detail ~= nil then ` ({result.detail})` else ""
		local good = result.result == "ok" or result.result == "dry"
		return good, `Test {kind}: {result.result}{detail}`
	end)

	guarded("NotifyQueueTest", function(ctx: Ctx): (boolean, string)
		if not deps.isStudio then
			return false, "Queue tests run in Studio only"
		end
		local kind = ctx.args.kind
		if not NotifyConfig.isKind(kind) then
			return false, "Unknown kind"
		end
		local runner = deps.runner
		if runner == nil then
			return false, "No queue on this server (MemoryStore unavailable)"
		end
		local seconds = math.clamp(math.floor(tonumber(ctx.args.seconds) or 0), 0, 300)
		local player = ctx.caller.player
		if not runner.queueTest(ctx.caller.userId, kind :: Kind, testParams(kind :: Kind, player), seconds) then
			return false, "Queue write failed (see NotifyStatus)"
		end
		if seconds == 0 then
			deps.pollNow()
			return true, `Queued {kind} for you and polled: see NotifyStatus`
		end
		return true, `Queued {kind} for you, due in {seconds} s (next poll sends it as a dry run)`
	end)

	return true
end

return ReturnNotifyAdmin
