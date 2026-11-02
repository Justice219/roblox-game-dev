--!strict
--[[
	ReturnNotifyService — RETURN NOTIFICATIONS (owner R122 §2.3, docs/retention.md "Return
	notifications"): the game collected opt-ins but never sent a notification; Roblox ranks on play
	days per user (D1, D2-7, D8-28) and Creator Docs recommend experience notifications to bring
	lapsed players back. This service sends them.

	Lifecycle (one server):
		PlayerAdded        remember the join (unix time + UTC hour); cancel the player's pending
		                   entry and leave a "join" marker (queue.join), again after
		                   JoinRecheckSeconds while they are still here (a slow plan write from the
		                   server they just left)
		ProfileLoaded      (join, not New Player Mode) launch data "rn:<kind>" → analytics
		                   "rnotify:join:<kind>" once per session (Sessions counts "r<N>:notify" from
		                   AnalyticsConfig.NotifyLaunchData)
		ProfileReleasing   (not New Player Mode) build the leave facts from the live profile:
		                   automated income + offline cap (cashFull), profile.daily (streak), the
		                   usual start hour, the opt-in flag; plan ONE notification on its own
		                   thread (ReturnNotifyRunner.plan → ReturnNotifyQueue → MemoryStore)
		poll loop          every PollSeconds (+ jitter): ReturnNotifyRunner.pollOnce — claim due
		                   entries (exactly one server sends each), send through Open Cloud (or a
		                   dry run in Studio / without the secret)
		BindToClose        waits (bounded) for plan writes still in flight
	Switches: NotifyConfig.Enabled (code) + ReturnNotifyControl (universe kill switch + per-kind,
	admin). Admin commands: ReturnNotifyAdmin (Server tab).

	Usual start hour: profile.notify.hour (0..23, -1 = unknown; ProfileLogic reconciles it, the
	probe in Init keeps this safe against an older ProfileLogic); updated at leave (before the
	final save) by blending in this session's hour (ReturnNotifyLogic.usualHour). Unknown: this
	session's start hour.

	Security: every input is server-side (profile, server clocks, GetJoinData read on the server
	and matched exactly). The API key stays inside ReturnNotifySender. Nothing is sent to clients
	except the display attributes ReturnNotifyControl publishes.

	Performance: nothing per frame; per player one plan write at leave, one join write (+1 read)
	+ one recheck; one poll per minute per server; sends limited per server.

	Connects to: Server/Retention/{ReturnNotifyLogic, ReturnNotifyQueue, ReturnNotifySender,
	ReturnNotifyRunner, ReturnNotifyControl, ReturnNotifyAdmin, RewardGrant (analytics)},
	Server/Services/{PlayerDataService, MonetizationService (Offline Max pass)},
	Server/Economy/ProfileLogic (hour field probe), Shared/Tycoon/TycoonLogic, Shared/Config/
	NotifyConfig.

	Usage: FEATURE service "Retention/ReturnNotifyService" (server boot list; before AdminService).
]]

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local MonetizationService = require(ServerScriptService.Server.Services.MonetizationService)
local NotifyConfig = require(ReplicatedStorage.Shared.Config.NotifyConfig)
local PlayerDataService = require(ServerScriptService.Server.Services.PlayerDataService)
local ProfileLogic = require(ServerScriptService.Server.Economy.ProfileLogic)
local ReturnNotifyAdmin = require(script.Parent.ReturnNotifyAdmin)
local ReturnNotifyControl = require(script.Parent.ReturnNotifyControl)
local ReturnNotifyLogic = require(script.Parent.ReturnNotifyLogic)
local ReturnNotifyQueue = require(script.Parent.ReturnNotifyQueue)
local ReturnNotifyRunner = require(script.Parent.ReturnNotifyRunner)
local ReturnNotifySender = require(script.Parent.ReturnNotifySender)
local RewardGrant = require(script.Parent.RewardGrant)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)

type Profile = ProfileLogic.Profile

local ReturnNotifyService = {}

local Queue = NotifyConfig.Queue

local IS_STUDIO = RunService:IsStudio()
-- The kind table this server runs (Studio: placeholder ids so the dry run covers every kind).
local KINDS = NotifyConfig.kindsFor(IS_STUDIO)

local runner: ReturnNotifyRunner.Runner? = nil
local started = false
-- Per player: when (unix) and at which UTC hour this session started.
local joins: { [Player]: { at: number, hour: number } } = {}
-- Players whose "rnotify:join:<kind>" was counted this session.
local joinCounted: { [Player]: boolean } = {}
-- Plan writes in flight (BindToClose waits for them).
local pendingPlans = 0
-- Whether ProfileLogic keeps profile.notify.hour (probed once in Init).
local hourField = false

-- The UTC hour (0..23) of a unix time.
local function utcHour(t: number): number
	return (t % 86400) // 3600
end

-- Analytics (retention family; guarded, never yields).
local function track(player: Player?, key: string)
	RewardGrant.track(player, key)
end

-- Remembers a join and cancels the player's pending entry (plus one recheck).
local function onPlayerAdded(player: Player)
	local now = os.time()
	joins[player] = { at = now, hour = utcHour(now) }
	local live = runner
	if live == nil then
		return
	end
	local userId = player.UserId
	task.spawn(function()
		live.join(player, userId, now)
	end)
	task.delay(Queue.JoinRecheckSeconds, function()
		if player.Parent == Players then
			live.join(player, userId, now)
		end
	end)
end

-- Counts a notification join once per session (real joins only, never a New Player Mode swap).
local function onProfileLoaded(player: Player)
	if joinCounted[player] or PlayerDataService.getLoadReason(player) ~= "join" then
		return
	end
	joinCounted[player] = true
	local ok, data = pcall(function(): any
		return player:GetJoinData()
	end)
	if not ok or type(data) ~= "table" then
		return
	end
	local kind = NotifyConfig.kindFromLaunchData(data.LaunchData)
	if kind ~= nil then
		track(player, `rnotify:join:{kind}`)
	end
end

-- The stored usual hour (profile.notify.hour when ProfileLogic keeps it), else nil.
local function storedHour(profile: Profile): number?
	if not hourField then
		return nil
	end
	local hour = profile.notify.hour
	if type(hour) == "number" and hour % 1 == 0 and hour >= 0 and hour <= 23 then
		return hour
	end
	return nil
end

--[[
	Builds the leave facts from the live profile (never yields; every read guarded).
	@return Facts
]]
local function factsOf(player: Player, profile: Profile, leaveAt: number): ReturnNotifyLogic.Facts
	local join = joins[player]
	local sessionHour = if join ~= nil then join.hour else utcHour(leaveAt)
	local income = 0
	local okIncome, value = pcall(TycoonLogic.incomePerSecond, profile.tycoon, nil)
	if okIncome and type(value) == "number" then
		income = value
	end
	local cap = 0
	local okCap, capSeconds = pcall(function(): number
		local seconds =
			TycoonLogic.offlineLimits(profile.rebirthShop, MonetizationService.ownsPass(player, "OfflineMax"))
		return seconds
	end)
	if okCap and type(capSeconds) == "number" then
		cap = capSeconds
	end
	return {
		userId = player.UserId,
		leaveAt = leaveAt,
		sessionSeconds = if join ~= nil then leaveAt - join.at else 0,
		usualHour = ReturnNotifyLogic.usualHour(storedHour(profile), sessionHour),
		automatedIncome = income,
		offlineCapSeconds = cap,
		daily = { streak = profile.daily.streak, lastDay = profile.daily.lastDay },
		optedIn = profile.notify.claimed == true,
	}
end

-- A profile is about to be saved for the last time: plan this player's notification.
local function onProfileReleasing(player: Player, profile: Profile)
	if not NotifyConfig.Enabled or PlayerDataService.isNewPlayerMode(player) then
		return
	end
	local leaveAt = os.time()
	local facts = factsOf(player, profile, leaveAt)
	if hourField then
		-- Lands in the final save (ProfileReleasing fires before it).
		profile.notify.hour = facts.usualHour
	end
	local live = runner
	if live == nil or player.UserId <= 0 then
		return
	end
	pendingPlans += 1
	task.spawn(function()
		local ok, err = pcall(live.plan, player, facts)
		if not ok then
			warn(`[ReturnNotify] plan failed: {err}`)
		end
		pendingPlans -= 1
	end)
end

-- The poll loop: a random first wait (servers spread out), then every PollSeconds + jitter.
local function pollLoop()
	local random = Random.new()
	task.wait(random:NextNumber(0, Queue.PollSeconds))
	while true do
		local live = runner
		if live ~= nil and NotifyConfig.Enabled then
			local ok, err = pcall(live.pollOnce)
			if not ok then
				warn(`[ReturnNotify] poll error: {err}`)
			end
		end
		task.wait(Queue.PollSeconds + random:NextNumber(0, Queue.PollJitterSeconds))
	end
end

--[[ Service contract: probes the profile hour field (no yields, no remotes). ]]
function ReturnNotifyService.Init()
	local ok, profile = pcall(ProfileLogic.defaultProfile)
	hourField = ok and type(profile) == "table" and type(profile.notify.hour) == "number"
end

--[[ Service contract: control, queue, sender, runner, player hooks, poll loop, admin. ]]
function ReturnNotifyService.Start()
	if started then
		return
	end
	started = true
	ReturnNotifyControl.start()
	local queue: ReturnNotifyQueue.Queue? = nil
	local okMap, map = pcall(function(): any
		return MemoryStoreService:GetSortedMap(Queue.MapName)
	end)
	if okMap and map ~= nil then
		queue = ReturnNotifyQueue.new(map, KINDS)
	else
		warn(`[ReturnNotify] MemoryStore unavailable ({map}); return notifications are off on this server`)
	end
	local sender = ReturnNotifySender.new({
		isStudio = IS_STUDIO,
		getSecret = function(name: string): any
			return HttpService:GetSecret(name)
		end,
		request = function(options: { [string]: any }): any
			return HttpService:RequestAsync(options :: any)
		end,
		encode = function(value: any): string
			return HttpService:JSONEncode(value)
		end,
		decode = function(text: string): any
			return HttpService:JSONDecode(text)
		end,
		clock = os.clock,
		kinds = KINDS,
	})
	if queue ~= nil then
		runner = ReturnNotifyRunner.new({
			queue = queue,
			sender = sender,
			control = ReturnNotifyControl.current,
			now = function(): number
				return os.time()
			end,
			clock = os.clock,
			track = track,
			jobId = game.JobId,
			spawn = function(fn: () -> ())
				task.spawn(fn)
			end,
			delay = function(seconds: number, fn: () -> ())
				task.delay(seconds, fn)
			end,
		})
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		if joins[player] == nil then
			onPlayerAdded(player)
		end
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		-- Deferred: PlayerDataService's ProfileReleasing (fired from its own PlayerRemoving
		-- handler) still needs the join record.
		task.defer(function()
			joins[player] = nil
			joinCounted[player] = nil
		end)
	end)
	PlayerDataService.ProfileLoaded:Connect(function(player: Player)
		onProfileLoaded(player)
	end)
	for _, player in Players:GetPlayers() do
		if PlayerDataService.getProfile(player) ~= nil then
			onProfileLoaded(player)
		end
	end
	PlayerDataService.ProfileReleasing:Connect(onProfileReleasing)
	game:BindToClose(function()
		local deadline = os.clock() + Queue.CloseWaitSeconds
		while pendingPlans > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
	task.spawn(pollLoop)

	ReturnNotifyAdmin.install({
		runner = runner,
		queue = queue,
		sender = sender,
		isStudio = IS_STUDIO,
		kinds = KINDS,
		pollNow = function()
			local live = runner
			if live ~= nil then
				live.pollOnce()
			end
		end,
	})
end

--[[ This server's runner (admin / QA probes), or nil when the queue could not be created. ]]
function ReturnNotifyService.runner(): ReturnNotifyRunner.Runner?
	return runner
end

return ReturnNotifyService
