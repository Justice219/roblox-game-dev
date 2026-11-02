--!strict
--[[
	QuestService — the live boundary of Quests (owner R78, spec §1): starter goals, daily missions,
	trophies. Pure rules live in Server/Quests/QuestLogic + Shared/Config/QuestConfig.

	Inputs (server truth only):
		ProgressEvents.Progress(player, stat, amount)   fired by every success path (TycoonService,
		                                                PetService, CrateService, LuckySpinService, ...)
		own loop (QuestConfig.LoopSeconds)              `playMinute` once per online minute per player
		                                                (fired through ProgressEvents, so the Nuke Pass
		                                                and anything else hears it too) + the UTC day
		                                                rollover for online players
		PlayerDataService.ProfileLoaded                 chain start, today's missions, veteran goals

	Remotes (C→S, intents only; Remotes.onServerEvent drops departed players):
		QuestClaim(kind, id)   kind "starter" (id 1..12) | "daily" (id 1..3) | "chest" | "trophy" (id =
		                       a QuestConfig trophy id). typeof / range / config-id checks
		                       (QuestLogic.readClaim), a per-player token bucket, canMutate, then the
		                       claim flag flips and RewardGrant pays in ONE non-yielding step, so a
		                       repeated / racing claim is refused ("claimed") — idempotent.
		QuestReroll(slot)      slot 1..3: today's one free reroll (QuestLogic.reroll).
	Results reach the client through the profile sync (`quests` field) + a toast; no result remote.

	Rewards: RewardGrant.grant (RewardLogic.apply: gems, wheel spins → the BONUS bank, cashSeconds
	+ cashFloor, boosts), reason "quest". Nuke Pass XP: ProgressEvents.xp(player, xp, source) with
	source "starter" | "daily" | "chest" | "trophy" (PassService listens).

	Sync budget: a progress-only change marks `quests` at most every QuestConfig.PushSeconds per
	player (clicks never flood ProfileDelta); completions, claims and new days push at once.

	Kid-friendly carry-over (design decision, docs/quests.md): finished but unclaimed missions and an
	earned Daily Chest from an earlier day are paid automatically when the day rolls (nothing earned
	is ever lost), with a toast.

	Analytics (retention family, AnalyticsConfig "quest:*"): goalDone / goalClaim:<1-12>,
	dailyPick / dailyDone / dailyClaim / reroll:<stat>, chest, trophy:<id>:<tier>.
	Admin (Players tab, audited): QuestCompleteGoal, QuestResetDaily, QuestSetTrophy; QuestStatus
	(read-only).

	Connects to: Server/Progression/ProgressEvents, Server/Quests/QuestLogic, Shared/Config/
	QuestConfig, Server/Services/PlayerDataService, Server/Retention/{RewardGrant, RewardLogic},
	Server/Event/Lazy (EventService.isActive, AdminService.registerCommand), Shared/Net/Remotes,
	Shared/Util/RateLimiter. Client: Client/Quests/QuestClient, UI/Screens/Quests.

	Example:
		QuestService.completeGoal(player)   -- admin: complete the current starter goal
		QuestService.resetDaily(player)     -- admin: fresh missions for today
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local Lazy = require(ServerScriptService.Server.Event.Lazy)
local PlayerDataService = require(script.Parent.PlayerDataService)
local ProgressEvents = require(ServerScriptService.Server.Progression.ProgressEvents)
local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)
local QuestLogic = require(ServerScriptService.Server.Quests.QuestLogic)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RewardGrant = require(ServerScriptService.Server.Retention.RewardGrant)
local RewardLogic = require(ServerScriptService.Server.Retention.RewardLogic)

type State = QuestConfig.State
type Facts = QuestConfig.Facts

-- Per-player session bookkeeping (never saved).
type Runtime = {
	nextMinute: number, -- os.clock() of the next `playMinute`
	pushDue: boolean, -- a progress-only change waits for the throttled push
	lastPush: number, -- os.clock() of the last `quests` push
	ready: { [string]: boolean }, -- trophies last known claimable (toast only on new ones)
}

local QuestService = {}

local claimLimiter = RateLimiter.new(QuestConfig.Limits.Claim.Burst, QuestConfig.Limits.Claim.PerSecond)
local rerollLimiter = RateLimiter.new(QuestConfig.Limits.Reroll.Burst, QuestConfig.Limits.Reroll.PerSecond)
local runtimes: { [Player]: Runtime } = {}
local started = false

-- Toast text per refusal code (QuestLogic.Code).
local REFUSALS: { [string]: string } = {
	locked = "Not finished yet - keep going!",
	claimed = "Already claimed!",
	stale = "New daily missions are here - take a look!",
	used = "You already used today's free reroll!",
	done = "Finished missions can't be rerolled - claim it instead!",
	empty = "No other missions to swap in right now!",
	unknown = "That quest is not available.",
}

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

-- The UTC day of the server clock (never the client's).
local function today(): number
	return QuestConfig.utcDay(os.time())
end

-- The loaded quests record of a player (nil before the profile loads). A profile written by an
-- older server gets a fresh record (ProfileLogic reconciles it on load; this is a last guard).
local function stateOf(player: Player): (any, State?)
	local profile: any = PlayerDataService.getProfile(player)
	if profile == nil then
		return nil, nil
	end
	if type(profile.quests) ~= "table" then
		profile.quests = QuestConfig.newState()
	end
	return profile, profile.quests :: State
end

-- Whether the Harvest Feast runs now (turkey missions): EventService's answer (admin force
-- included), else the date window.
local function eventLive(): boolean
	local isActive = Lazy.fn("EventService", "isActive")
	if isActive ~= nil then
		local ok, active = pcall(isActive)
		if ok and type(active) == "boolean" then
			return active
		end
	end
	return EventConfig.isInWindow(os.time())
end

-- Counts a retention analytics key (never errors / yields).
local function track(player: Player, key: string)
	RewardGrant.track(player, key)
end

local function runtimeOf(player: Player): Runtime
	local rt = runtimes[player]
	if rt == nil then
		rt = {
			nextMinute = os.clock() + QuestConfig.PlayMinuteSeconds,
			pushDue = false,
			lastPush = -math.huge,
			ready = {},
		}
		runtimes[player] = rt
	end
	return rt
end

-- Pushes the `quests` field now (urgent) or lets the loop push it within PushSeconds.
local function requestPush(player: Player, urgent: boolean)
	local rt = runtimeOf(player)
	if urgent then
		rt.pushDue = false
		rt.lastPush = os.clock()
		PlayerDataService.markChanged(player, false, { "quests" })
	else
		rt.pushDue = true
	end
end

-- The set of trophies whose next tier is claimable now.
local function readyTrophies(state: State, facts: Facts): { [string]: boolean }
	local ready: { [string]: boolean } = {}
	for _, view in QuestConfig.trophyViews(state, facts) do
		if view.state == "ready" then
			ready[view.trophy.id] = true
		end
	end
	return ready
end

-- Toasts trophies that became claimable since the last check (and remembers the new set).
local function announceTrophies(player: Player, state: State, facts: Facts): boolean
	local rt = runtimeOf(player)
	local ready = readyTrophies(state, facts)
	local any = false
	for id in ready do
		if not rt.ready[id] then
			any = true
			local trophy = QuestConfig.TrophyById[id]
			local tier = math.clamp((state.trophies[id] or 0) + 1, 1, #trophy.tiers)
			PlayerDataService.notify(
				player,
				`Trophy unlocked: {QuestConfig.tierName(trophy, tier)}! Claim it in Quests.`,
				"success",
				"Trophy"
			)
		end
	end
	rt.ready = ready
	return any
end

-- Completes every satisfied starter goal in order (analytics + toast). Returns true if any.
local function advanceGoals(player: Player, state: State, facts: Facts, quiet: boolean): boolean
	local completed = QuestLogic.advanceStarter(state, facts)
	for _, index in completed do
		track(player, QuestConfig.Keys.goalDone(index))
	end
	if #completed == 1 and not quiet then
		PlayerDataService.notify(
			player,
			`Goal complete: {QuestConfig.Goals[completed[1]].text}! Claim it in Quests.`,
			"success",
			"Trophy"
		)
	elseif #completed > 1 then
		PlayerDataService.notify(player, `{#completed} goals complete! Claim them in Quests.`, "success", "Trophy")
	end
	return #completed > 0
end

--[[
	Pays what an earlier day left unclaimed (finished missions + an earned chest), then seeds the
	new day's missions. Never yields. Returns true when the day changed.
]]
local function rollDay(player: Player, state: State, facts: Facts, day: number): boolean
	local daily = state.daily
	if daily.day >= day then
		return false
	end
	if daily.day >= 0 and PlayerDataService.canMutate(player) then
		local old = daily.day
		local gems, spins = 0, 0
		local function pay(reward: QuestConfig.Reward?, xp: number?, source: string)
			if reward == nil then
				return
			end
			local summary = RewardGrant.grant(player, reward, "quest", { saveSoon = true, extraFields = { "quests" } })
			if summary ~= nil then
				gems += summary.gems
				spins += summary.spins
			end
			if xp ~= nil then
				ProgressEvents.xp(player, xp, source)
			end
		end
		for slot in daily.picks do
			local ok, _, reward, xp, stat = QuestLogic.claimDaily(state, slot, old)
			if ok then
				pay(reward, xp, "daily")
				if stat ~= nil then
					track(player, QuestConfig.Keys.dailyClaim(stat))
				end
			end
		end
		local chestOk, _, chestReward, chestXp = QuestLogic.claimChest(state, old)
		if chestOk then
			pay(chestReward, chestXp, "chest")
			track(player, QuestConfig.Keys.chest())
		end
		if gems > 0 or spins > 0 then
			local parts = {}
			if gems > 0 then
				table.insert(parts, `+{gems} Gems`)
			end
			if spins > 0 then
				table.insert(parts, `+{spins} Spin{if spins == 1 then "" else "s"}`)
			end
			PlayerDataService.notify(
				player,
				`Yesterday's missions paid out: {table.concat(parts, ", ")}!`,
				"reward",
				"Trophy"
			)
		end
	end
	local seeded, stats = QuestLogic.rollDay(state, day, player.UserId, QuestConfig.tierOf(facts), eventLive())
	if seeded then
		for _, stat in stats do
			track(player, QuestConfig.Keys.dailyPick(stat))
		end
	end
	return seeded
end

--------------------------------------------------------------------------------------------------
-- Progress
--------------------------------------------------------------------------------------------------

-- ProgressEvents.Progress listener: counts, completes, toasts, pushes. Never yields.
local function onProgress(player: Player, stat: string, amount: number)
	local profile, state = stateOf(player)
	if profile == nil or state == nil then
		return
	end
	local day = today()
	local facts = QuestConfig.facts(profile)
	local rolled = rollDay(player, state, facts, day)
	local finished, changed = QuestLogic.applyProgress(state, stat, amount, day)
	for _, slot in finished do
		local pick = state.daily.picks[slot]
		track(player, QuestConfig.Keys.dailyDone(pick.stat))
		PlayerDataService.notify(
			player,
			`Mission complete: {QuestConfig.missionText(pick.stat, pick.target)}!`,
			"success",
			"Trophy"
		)
	end
	if #finished > 0 then
		local _, chest = QuestConfig.dailyViews(state, day)
		if chest == "ready" then
			PlayerDataService.notify(player, "All 3 missions done - open your Daily Chest!", "success", "Chest")
		end
	end
	local goals = advanceGoals(player, state, facts, false)
	local trophies = announceTrophies(player, state, facts)
	local urgent = rolled or #finished > 0 or goals or trophies
	if changed or urgent then
		requestPush(player, urgent)
	end
end

-- Profile loaded (join, or a New Player Mode swap): start the chain, roll the day, complete
-- what the profile already proves (veterans), push.
local function onProfileLoaded(player: Player, _profile: any, _isNew: boolean)
	local profile, state = stateOf(player)
	if profile == nil or state == nil then
		return
	end
	local rt = runtimeOf(player)
	local facts = QuestConfig.facts(profile)
	QuestLogic.startChain(state)
	rollDay(player, state, facts, today())
	advanceGoals(player, state, facts, true)
	-- Trophies already claimable at join are not "new": no toast storm on every join.
	rt.ready = readyTrophies(state, facts)
	requestPush(player, true)
end

-- The one loop: play minutes, UTC day rollover, throttled pushes.
local function tick()
	local clock = os.clock()
	local day = today()
	for player, rt in runtimes do
		if player.Parent ~= Players then
			continue
		end
		local profile, state = stateOf(player)
		if profile == nil or state == nil then
			continue
		end
		if clock >= rt.nextMinute then
			-- Far behind (a hitch / long yield)? Count one minute and resync, never a burst.
			rt.nextMinute = math.max(rt.nextMinute + QuestConfig.PlayMinuteSeconds, clock + 1)
			ProgressEvents.progress(player, "playMinute")
		end
		if state.daily.day < day then
			if rollDay(player, state, QuestConfig.facts(profile), day) then
				requestPush(player, true)
			end
		end
		if rt.pushDue and clock - rt.lastPush >= QuestConfig.PushSeconds then
			requestPush(player, true)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Claims + rerolls
--------------------------------------------------------------------------------------------------

-- Refuses with a toast and re-sends the player's quests (their view may be out of date).
local function refuse(player: Player, code: string)
	PlayerDataService.notify(player, REFUSALS[code] or REFUSALS.unknown, "info", "Trophy")
	PlayerDataService.refresh(player, { "quests" })
end

--[[
	Handles QuestClaim (also callable by tests / admin tooling).
	@return true when a reward was paid
]]
function QuestService.claim(player: Player, rawKind: unknown, rawId: unknown): boolean
	local request = QuestLogic.readClaim(rawKind, rawId)
	if request == nil then
		return false
	end
	local profile, state = stateOf(player)
	if profile == nil or state == nil or not PlayerDataService.canMutate(player) then
		PlayerDataService.notify(player, "Your save is still loading - try again in a moment.", "info")
		return false
	end
	local day = today()
	local facts = QuestConfig.facts(profile)
	rollDay(player, state, facts, day)

	local ok: boolean, code: string, reward: QuestConfig.Reward?, xp: number?
	local source: string
	local key: string
	local label: string
	if request.kind == "starter" then
		local index = request.index :: number
		-- Goals the profile proves but no event advanced yet (e.g. right after a rebirth) count.
		advanceGoals(player, state, facts, true)
		ok, code, reward, xp = QuestLogic.claimStarter(state, index)
		source, key, label = "starter", QuestConfig.Keys.goalClaim(index), "Goal claimed!"
	elseif request.kind == "daily" then
		local stat: string?
		ok, code, reward, xp, stat = QuestLogic.claimDaily(state, request.index :: number, day)
		source, key, label = "daily", QuestConfig.Keys.dailyClaim(stat or "click"), "Mission claimed!"
	elseif request.kind == "chest" then
		ok, code, reward, xp = QuestLogic.claimChest(state, day)
		source, key, label = "chest", QuestConfig.Keys.chest(), "Daily Chest opened!"
	else
		local id = request.trophy :: string
		local tier: number?
		ok, code, reward, xp, tier = QuestLogic.claimTrophy(state, id, facts)
		local trophy = QuestConfig.TrophyById[id]
		source = "trophy"
		key = QuestConfig.Keys.trophy(id, tier or 1)
		label = if trophy ~= nil and tier ~= nil
			then `{QuestConfig.tierName(trophy, tier)} claimed!`
			else "Trophy claimed!"
	end
	local granted: QuestConfig.Reward? = if ok then reward else nil
	if granted == nil then
		refuse(player, code)
		return false
	end
	-- The claim flag is already set (same step, no yield): pay, push, count.
	local summary = RewardGrant.grant(player, granted, "quest", { saveSoon = true, extraFields = { "quests" } })
	local rt = runtimeOf(player)
	rt.pushDue = false
	rt.lastPush = os.clock()
	rt.ready = readyTrophies(state, facts)
	if xp ~= nil then
		ProgressEvents.xp(player, xp, source)
	end
	track(player, key)
	if summary ~= nil then
		PlayerDataService.notify(player, `{label} {RewardLogic.describe(summary)}`, "reward", "Trophy")
	end
	return true
end

--[[
	Handles QuestReroll(slot) (also callable by tests).
	@return true when the mission was swapped
]]
function QuestService.reroll(player: Player, rawSlot: unknown): boolean
	local slot = QuestLogic.readSlot(rawSlot)
	if slot == nil then
		return false
	end
	local profile, state = stateOf(player)
	if profile == nil or state == nil or not PlayerDataService.canMutate(player) then
		PlayerDataService.notify(player, "Your save is still loading - try again in a moment.", "info")
		return false
	end
	local day = today()
	local facts = QuestConfig.facts(profile)
	rollDay(player, state, facts, day)
	local ok, code, old, new =
		QuestLogic.reroll(state, slot, day, player.UserId, QuestConfig.tierOf(facts), eventLive())
	if not ok or old == nil or new == nil then
		refuse(player, code)
		return false
	end
	PlayerDataService.markChanged(player, true, { "quests" })
	local rt = runtimeOf(player)
	rt.pushDue = false
	rt.lastPush = os.clock()
	track(player, QuestConfig.Keys.reroll(old))
	track(player, QuestConfig.Keys.dailyPick(new))
	PlayerDataService.notify(
		player,
		`New mission: {QuestConfig.missionText(new, state.daily.picks[slot].target)}!`,
		"success",
		"Trophy"
	)
	return true
end

--------------------------------------------------------------------------------------------------
-- Admin seams
--------------------------------------------------------------------------------------------------

--[[ Admin: completes the player's current starter goal. @return (ok, message) ]]
function QuestService.completeGoal(player: Player): (boolean, string)
	local profile, state = stateOf(player)
	if profile == nil or state == nil then
		return false, "Profile not loaded"
	end
	local index = QuestLogic.forceStep(state)
	if index == nil then
		return false, "Every starter goal is already complete"
	end
	track(player, QuestConfig.Keys.goalDone(index))
	PlayerDataService.markChanged(player, true, { "quests" })
	return true, `Completed goal {index}: {QuestConfig.Goals[index].text}`
end

--[[ Admin: fresh missions for today (progress 0, chest + reroll back). @return (ok, message) ]]
function QuestService.resetDaily(player: Player): (boolean, string)
	local profile, state = stateOf(player)
	if profile == nil or state == nil then
		return false, "Profile not loaded"
	end
	local facts = QuestConfig.facts(profile)
	local stats = QuestLogic.resetDay(state, today(), player.UserId, QuestConfig.tierOf(facts), eventLive())
	for _, stat in stats do
		track(player, QuestConfig.Keys.dailyPick(stat))
	end
	PlayerDataService.markChanged(player, true, { "quests" })
	return true, `New missions: {table.concat(stats, ", ")}`
end

--[[ Admin: sets a counter trophy's lifetime counter. @return (ok, message) ]]
function QuestService.setTrophyCounter(player: Player, trophyId: string, value: number): (boolean, string)
	local profile, state = stateOf(player)
	if profile == nil or state == nil then
		return false, "Profile not loaded"
	end
	if not QuestLogic.setCounter(state, trophyId, value) then
		return false, "Only counter trophies can be set (Collector / Explorer / Reborn read the profile)"
	end
	announceTrophies(player, state, QuestConfig.facts(profile))
	PlayerDataService.markChanged(player, true, { "quests" })
	return true, `{QuestConfig.TrophyById[trophyId].name} counter set to {math.floor(value)}`
end

--[[ Read-only summary for the admin panel / QA. ]]
function QuestService.status(player: Player): string?
	local profile, state = stateOf(player)
	if profile == nil or state == nil then
		return nil
	end
	local facts = QuestConfig.facts(profile)
	local day = today()
	local missions = {}
	local views, chest = QuestConfig.dailyViews(state, day)
	for _, view in views do
		table.insert(missions, `{view.stat} {view.progress}/{view.target} {view.state}`)
	end
	local trophies = {}
	for id, tier in state.trophies do
		table.insert(trophies, `{id}={tier}`)
	end
	table.sort(trophies)
	return `goals {state.starter.step}/{QuestConfig.GoalCount} | daily [{table.concat(missions, "; ")}] chest {chest}`
		.. ` reroll {if state.daily.rerolled then "used" else "free"} | trophies {table.concat(trophies, " ")}`
		.. ` | claimable {QuestConfig.claimableCount(state, facts, day)}`
end

-- Registers the owner-panel commands (Players tab, order 90+).
local function registerAdmin()
	local function targetOf(ctx: any): Player?
		local target = ctx.target
		return if target ~= nil then target.player else nil
	end
	Lazy.registerAdmin({
		name = "QuestCompleteGoal",
		tab = "Players",
		label = "Complete Starter Goal",
		description = "Completes the player's current Quests starter goal (they still press CLAIM).",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = 90,
	}, function(ctx: any): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Player not in this server"
		end
		return QuestService.completeGoal(player)
	end)
	Lazy.registerAdmin({
		name = "QuestResetDaily",
		tab = "Players",
		label = "Reset Daily Missions",
		description = "Gives the player three fresh daily missions for today (progress, chest and reroll reset).",
		target = "Player",
		args = {},
		cooldown = 2,
		audited = true,
		confirm = false,
		color = "orange",
		order = 91,
	}, function(ctx: any): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Player not in this server"
		end
		return QuestService.resetDaily(player)
	end)
	local counterIds: { string } = {}
	local counterNames: { string } = {}
	for _, trophy in QuestConfig.Trophies do
		if trophy.source == "counter" then
			table.insert(counterIds, trophy.id)
			table.insert(counterNames, trophy.name)
		end
	end
	Lazy.registerAdmin({
		name = "QuestSetTrophy",
		tab = "Players",
		label = "Set Trophy Counter",
		description = "Sets a counter trophy's lifetime count (claimed tiers are kept).",
		target = "Player",
		args = {
			trophy = { kind = "enum", values = counterIds, labels = counterNames, label = "Trophy" },
			value = {
				kind = "integer",
				min = 0,
				max = 10_000_000,
				presets = { 0, 100, 1_000, 10_000 },
				format = "count",
				label = "Count",
			},
		},
		argOrder = { "trophy", "value" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = 92,
	}, function(ctx: any): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Player not in this server"
		end
		return QuestService.setTrophyCounter(player, ctx.args.trophy, ctx.args.value)
	end)
	Lazy.registerAdmin({
		name = "QuestStatus",
		tab = "Players",
		label = "Quests Status",
		description = "Read-only: the player's goals, today's missions, chest, reroll and trophies.",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = false,
		confirm = false,
		color = "grey",
		order = 93,
	}, function(ctx: any): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Player not in this server"
		end
		local text = QuestService.status(player)
		return text ~= nil, text or "Profile not loaded"
	end)
end

--------------------------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------------------------

function QuestService.Init() end

function QuestService.Start()
	if started then
		return
	end
	started = true
	ProgressEvents.Progress:Connect(onProgress)
	PlayerDataService.ProfileLoaded:Connect(onProfileLoaded)
	-- Players whose profile loaded before Start (Studio quick joins) are picked up here.
	for _, player in Players:GetPlayers() do
		if PlayerDataService.getProfile(player) ~= nil then
			task.spawn(onProfileLoaded, player, PlayerDataService.getProfile(player), false)
		end
	end
	Remotes.onServerEvent("QuestClaim", function(player: Player, rawKind: unknown, rawId: unknown)
		if claimLimiter:Allow(player) then
			QuestService.claim(player, rawKind, rawId)
		end
	end)
	Remotes.onServerEvent("QuestReroll", function(player: Player, rawSlot: unknown)
		if rerollLimiter:Allow(player) then
			QuestService.reroll(player, rawSlot)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		runtimes[player] = nil
		claimLimiter:Forget(player)
		rerollLimiter:Forget(player)
	end)
	registerAdmin()
	task.spawn(function()
		while true do
			task.wait(QuestConfig.LoopSeconds)
			local ok, err = pcall(tick)
			if not ok then
				warn(`[QuestService] tick failed: {err}`)
			end
		end
	end)
end

return QuestService
