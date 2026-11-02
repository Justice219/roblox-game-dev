--!strict
--[[
	AttackService — the attacking half of Attack mode (spec §9, owner R3): server-authoritative
	nuke launches, the deterministic flight timeline, impacts, minted rewards, Revenge and Barrage.

	Flow of one launch
		1. Client intent `AttackLaunch(target, kind?)`, target = a player's userId (number) OR a
		   Rival Factory id (string, AttackLogic.RivalIds allowlist — owner R43 NPC targets), kind
		   = "normal" (default) | "revenge" | "barrage". Validated (userId / rival allowlist, kind
		   allowlist), rate-limited, and checked by AttackLogic.canLaunch against server state only:
		   the attacker's console / cooldown / stored barrage, the target's plot / area >= 7 /
		   shield (a rival's deterministic shield cycle), a live Revenge token (never vs a rival).
		   No AFK protection (owner R43: "AFK nuke system"; the target loses nothing).
		2. The server decides EVERYTHING up front: per nuke a silo (owned silos round-robin), an
		   impact point (seeded AttackRng), the flight (AttackGeometry.flight → FlightMath), the
		   target tower's interception (DefenseService.engage: shot schedule + seeded rolls) and
		   the reward (AttackLogic.reward at launch incomes; AttackLogic.rivalReward — a fraction of
		   the attacker's OWN income — for a Rival Factory, whose tower is DefenseService.engageRival).
		3. ONE `NukeFlight` per nuke to every client (Remotes.fireAllClients):
		     { id, fromUserId, toUserId, t0, flight, intercepted, interceptAt,      -- plan contract
		       kind, fromPlot, toPlot, silo, impact, tier, shots, firstShot, reload, -- render data
		       volleys = { { t = tower, n = shots, f = firstShot, r = reload, h = hit } } }
		     (owner R80: one volley per defending tower that fired — tower 0 = the HQ / rival / bot
		     turret, 1.. = a defence slot; `shots / firstShot / reload` stay as the totals)
		   t0 is server time (Workspace:GetServerTimeNow) LeadIn seconds ahead; flight = seconds to
		   impact; interceptAt / firstShot are seconds after t0. Clients rebuild the identical arc
		   from the indices and render it locally (no physics, pooled), so nothing travels per
		   frame and no client can affect an outcome.
		4. At the outcome time (impact, or the interception) a TimeQueue event resolves it:
		     hit         attacker gets the reward MINTED (grantCash "attack_hit"), stats.hits;
		                 the target LOSES NOTHING: it gets a Revenge token against the attacker
		                 (RevengeSeconds; not for revenge hits) and one hit toward the free shield
		                 (a Rival Factory has no side to resolve)
		     intercepted nothing is paid; both sides get a toast
		   Toasts are coalesced per player (one "BOOM! x14 +$X" instead of 14 toasts).

	Products: "Barrage" (+`nukes` stored barrage nukes; launched 20 at a time, staggered, with no
	cooldown, kind "barrage" pays Reward.Factor.barrage per hit). Prompt refused without a console
	or when the pack would not fit under MaxStoredBarrage (told BEFORE paying); a granted receipt
	is never clamped (AttackProfile.addBarrage: the whole pack or NotProcessedYet), so paid nukes
	are never silently lost.
	Pass: MegaLauncher (x2 rewards), read from MonetizationService.ownsPass at launch.

	Security: intents only; the server never reads a position, amount, time or outcome from a
	client. Every argument typed + validated, per-player token bucket, a global cap on nukes in
	flight plus a per-attacker share of it (one player cannot starve the server), ownership +
	state checks (console owned, target eligible, rivals switched on), receipt handlers never
	yield, AttackLaunch connects through Remotes.onServerEvent (late events from departed players
	are dropped: no limiter bucket re-created). Outcomes are seeded from a per-server secret
	(Random.new()) mixed with the nuke id.

	Performance: one Heartbeat connection that returns immediately unless the queue head or a
	pending toast is due; TimeQueue is O(log n); NukeFlight payloads are ~150 bytes, once.

	Connects to: Shared/Attack/{AttackLogic, AttackGeometry, AttackRng}, Shared/Config/AttackConfig,
	Server/Attack/{TycoonBridge, AttackProfile, AttackAnalytics, TimeQueue, AttackAdmin},
	Services/{DefenseService, PlayerDataService, MonetizationService}, Client/Attack/* (NukeFlight).

	Boot: after DefenseService.

	Example (client):
		Remotes.event("AttackLaunch"):FireServer(targetUserId)              -- normal
		Remotes.event("AttackLaunch"):FireServer(targetUserId, "barrage")   -- send a barrage
		Remotes.event("AttackLaunch"):FireServer("grumpy_gus")              -- a Rival Factory
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AttackAdmin = require(script.Parent.Parent.Attack.AttackAdmin)
local AttackAnalytics = require(script.Parent.Parent.Attack.AttackAnalytics)
local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local AttackLogic = require(ReplicatedStorage.Shared.Attack.AttackLogic)
local AttackProfile = require(script.Parent.Parent.Attack.AttackProfile)
-- Owner R104: the picker streams its target in through a server replication focus.
local PickerFocus = require(script.Parent.Parent.Attack.PickerFocus)
local AttackRng = require(ReplicatedStorage.Shared.Attack.AttackRng)
local DefenseService = require(script.Parent.DefenseService)
local Knockdown = require(script.Parent.Parent.Tycoon.Knockdown)
local KnockdownConfig = require(ReplicatedStorage.Shared.Config.KnockdownConfig)
local MonetizationService = require(script.Parent.MonetizationService)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local RivalIslands = require(script.Parent.Parent.Attack.RivalIslands)
local TestBots = require(script.Parent.Parent.Attack.TestBots)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TimeQueue = require(script.Parent.Parent.Attack.TimeQueue)
local TycoonBridge = require(script.Parent.Parent.Attack.TycoonBridge)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)

local AttackService = {}

type LaunchKind = AttackLogic.LaunchKind

-- Who a launch is aimed at: a player, a Rival Factory (owner R43) or an admin test bot (R51).
type TargetRef = {
	player: Player?, -- a real player
	rival: number?, -- rival index (AttackConfig.Rivals.List)
	bot: TestBots.Bot?, -- an admin test bot
	key: number | string, -- revenge / identity key: the userId, or the bot key ("bot:3"); 0 = rival
	userId: number, -- NukeFlight toUserId (0 for rivals and bots)
	slot: number, -- AttackGeometry target slot (plot, or PlotCount + rival)
	name: string, -- display name (toasts)
	built: { number }, -- aimable areas (built areas / rival sections)
}

-- Who launched: a player, or an admin test bot (owner R51).
type AttackerRef = {
	player: Player?,
	bot: TestBots.Bot?,
	key: number | string, -- userId or bot key (Revenge tokens are keyed by it)
	name: string,
	plot: number, -- launching plot (silos)
}

-- One nuke in flight (server bookkeeping until its outcome event).
type Nuke = {
	id: number,
	kind: LaunchKind,
	attacker: AttackerRef,
	target: TargetRef,
	area: number, -- owner R50: aimed area / rival section that gets knocked down (0 = none: test)
	point: Vector3, -- the world impact point (knockdown topple direction)
	launcherLevel: number,
	reward: number, -- minted on a hit (computed at launch; BlockedFactor when nothing was knocked)
	intercepted: boolean,
	hitTower: number, -- owner R80: the defending tower that intercepted (0 HQ, 1.. slot; -1 none)
	test: boolean, -- admin test flight: no reward, no hit counted
}

-- Coalesced toast state of one player (flushed by the Heartbeat loop).
type Pending = {
	hits: number,
	cash: number,
	missed: number, -- my nukes stopped by AA
	nuked: number, -- nukes that hit me
	blocked: number, -- nukes my AA stopped
	byName: string?, -- last attacker that hit me
	knocked: string?, -- owner R50: what my last hit knocked down ("Ana's LAB"), toast text
	protectedName: string?, -- my last hit landed on a protected target: reduced reward, no knockdown
	shieldReady: boolean,
	firstAt: number,
	lastAt: number,
}

local FLIGHT = AttackConfig.Flight
local KINDS: { string } = { "normal", "revenge", "barrage", "golden" }
local GOLDEN = AttackConfig.Golden

local launchLimiter = RateLimiter.new(AttackConfig.RateLimits.Launch.capacity, AttackConfig.RateLimits.Launch.refill)
local queue = TimeQueue.new() :: TimeQueue.TimeQueue<Nuke>
-- revenge[victim][attackerUserId] = expiry server time
-- (attacker key = a userId, or an admin test bot's key "bot:3")
local revenge: { [Player]: { [number | string]: number } } = {}
local barrageBusyUntil: { [Player]: number } = {}
-- Nukes each attacker has in flight (their share of MaxNukesInFlight; nil = none).
local inFlight: { [Player]: number } = {}
local pending: { [Player]: Pending } = {}
local pendingCount = 0
local nextId = 0
-- Per-server secret seed: outcomes cannot be predicted from the (public) nuke ids.
local serverSeed = Random.new():NextInteger(1, 2 ^ 31 - 2)

local function now(): number
	return Workspace:GetServerTimeNow()
end

--------------------------------------------------------------------------------------------------
-- Toasts (coalesced per player)
--------------------------------------------------------------------------------------------------

-- The pending toast record of a player (created on first event).
local function pendingOf(player: Player): Pending
	local entry = pending[player]
	local t = os.clock()
	if entry == nil then
		local created: Pending = {
			hits = 0,
			cash = 0,
			missed = 0,
			nuked = 0,
			blocked = 0,
			byName = nil,
			knocked = nil,
			protectedName = nil,
			shieldReady = false,
			firstAt = t,
			lastAt = t,
		}
		pending[player] = created
		pendingCount += 1
		return created
	end
	entry.lastAt = t
	return entry
end

-- Sends a player's coalesced toasts.
local function flushToasts(player: Player, entry: Pending)
	if player.Parent ~= Players then
		return
	end
	if entry.hits > 0 then
		-- Owner R50: "BOOM! You knocked down X's LAB! +$Y".
		local text = if entry.hits == 1 then "BOOM!" else `BOOM! x{entry.hits} hits!`
		if entry.knocked ~= nil then
			text ..= ` You knocked down {entry.knocked}!`
		elseif entry.protectedName ~= nil then
			text ..= ` {entry.protectedName} is protected - no knockdown.`
		else
			text ..= " Direct hit!"
		end
		if entry.cash > 0 then
			text ..= ` +{NumberFormat.money(entry.cash)}`
		end
		PlayerDataService.notify(player, text, "reward", "Attack")
	end
	if entry.missed > 0 then
		local text = if entry.missed == 1
			then "An AA tower stopped your nuke!"
			else `AA towers stopped {entry.missed} nukes!`
		PlayerDataService.notify(player, text, "info", "Attack")
	end
	if entry.nuked > 0 then
		local who = entry.byName or "someone"
		local text = if entry.nuked == 1
			then `You got nuked by {who}! Free REVENGE ready!`
			else `You got nuked x{entry.nuked}! Free REVENGE ready!`
		PlayerDataService.notify(player, text, "info", "Attack")
	end
	if entry.blocked > 0 then
		local text = if entry.blocked == 1
			then "Your AA tower stopped a nuke!"
			else `Your AA tower stopped {entry.blocked} nukes!`
		PlayerDataService.notify(player, text, "success", "Shield")
	end
	if entry.shieldReady then
		PlayerDataService.notify(player, "FREE SHIELD ready! Tap SHIELD to turn it on.", "reward", "Shield")
	end
end

--------------------------------------------------------------------------------------------------
-- Revenge tokens
--------------------------------------------------------------------------------------------------

-- True when `holder` has a live Revenge token against `targetKey` (a userId or a bot key).
local function hasRevenge(holder: Player, targetKey: number | string, t: number): boolean
	local tokens = revenge[holder]
	local expires = if tokens ~= nil then tokens[targetKey] else nil
	return expires ~= nil and expires > t
end

-- Gives `victim` a token against `attackerUserId` (bounded; the oldest token is dropped).
local function grantRevenge(victim: Player, attackerKey: number | string, t: number)
	local tokens = revenge[victim]
	if tokens == nil then
		tokens = {}
		revenge[victim] = tokens
	end
	local live = tokens :: { [number | string]: number }
	live[attackerKey] = t + AttackConfig.RevengeSeconds
	local count, oldestId, oldest = 0, nil :: (number | string)?, math.huge
	for userId, expires in live do
		if expires <= t then
			live[userId] = nil
		else
			count += 1
			if expires < oldest then
				oldest, oldestId = expires, userId
			end
		end
	end
	if count > AttackConfig.MaxRevengeTokens and oldestId ~= nil then
		live[oldestId] = nil
	end
end

--------------------------------------------------------------------------------------------------
-- Launching
--------------------------------------------------------------------------------------------------

-- Number of players any attacker could pick right now (analytics "targets:<n>").
local function targetableCount(exclude: Player): number
	local count = 0
	for _, player in Players:GetPlayers() do
		if player ~= exclude and player:GetAttribute(AttackConfig.Attr.Targetable) == true then
			count += 1
		end
	end
	return math.min(count, 8)
end

-- Builds, decides, publishes and schedules ONE nuke.
local function launchOne(
	attacker: AttackerRef,
	target: TargetRef,
	kind: LaunchKind,
	silo: number,
	launcherLevel: number,
	reward: number,
	t0: number,
	test: boolean,
	area: number
)
	nextId += 1
	local id = nextId
	local rng = AttackRng.new(AttackRng.mix(serverSeed, id))
	local impact = rng:integer(1, AttackGeometry.impactCount(target.slot))
	-- Owner R50: an aimed nuke lands at the area / section centre + seeded scatter (smaller with a
	-- better launcher); area 0 = an admin test nuke on the legacy impact points.
	local sx, sz = 0, 0
	if area >= 1 then
		sx, sz = AttackLogic.scatter(launcherLevel, rng:next(), rng:next(), target.rival ~= nil)
	end
	local flight = AttackGeometry.flightOf({
		fromPlot = attacker.plot,
		silo = silo,
		toPlot = target.slot,
		impact = impact,
		area = area,
		sx = sx,
		sz = sz,
	})
	local stats = AttackLogic.launcherStats(launcherLevel) or AttackConfig.Launcher[1]
	-- Owner R85: a golden revenge nuke carries extra armor vs AA and the gold nuke model.
	local armor = if kind == "golden" then AttackLogic.goldenArmor(launcherLevel) else stats.armor
	local tier = if kind == "golden" then GOLDEN.Tier else stats.tier
	-- The target's own tower engages (a rival's / a bot's tower exactly like a player's).
	local targetBot = target.bot
	local targetPlayer = target.player
	local engagement = if target.rival ~= nil
		then DefenseService.engageRival(target.rival, flight, armor, t0, rng)
		elseif targetBot ~= nil then DefenseService.engageBot(targetBot, flight, armor, t0, rng)
		elseif targetPlayer ~= nil then DefenseService.engage(targetPlayer, flight, armor, t0, rng)
		else nil
	local intercepted = engagement ~= nil and engagement.intercepted
	local outcomeAt = t0 + (if engagement ~= nil and intercepted then engagement.interceptAt else flight.duration)
	queue:push(outcomeAt, {
		id = id,
		kind = kind,
		attacker = attacker,
		target = target,
		area = area,
		point = flight.to,
		launcherLevel = launcherLevel,
		reward = reward,
		intercepted = intercepted,
		hitTower = if engagement ~= nil then engagement.hitTower else -1,
		test = test,
	})
	-- Owner R80: how many AA towers defended a PLAYER target when a real nuke came in (how often
	-- players are defenceless; admin test traffic excluded).
	if targetPlayer ~= nil and not test and attacker.bot == nil and engagement ~= nil then
		AttackAnalytics.record(targetPlayer, `defTowers:{math.clamp(engagement.towers, 0, 9)}`)
	end
	-- Every tower that fired (owner R80): clients draw each volley from that tower's muzzle.
	local volleys: { { t: number, n: number, f: number, r: number, h: boolean } } = {}
	if engagement ~= nil then
		for _, volley in engagement.volleys do
			table.insert(volleys, {
				t = volley.tower,
				n = volley.shots,
				f = volley.firstShotAt,
				r = volley.reload,
				h = volley.hit,
			})
		end
	end
	local attackerPlayer = attacker.player
	if attackerPlayer ~= nil then
		inFlight[attackerPlayer] = (inFlight[attackerPlayer] or 0) + 1
	end
	local attackerBot = attacker.bot
	Remotes.fireAllClients("NukeFlight", {
		id = id,
		fromUserId = if test or attackerPlayer == nil then 0 else attackerPlayer.UserId,
		fromBot = if attackerBot ~= nil then attackerBot.key else nil,
		toUserId = target.userId,
		toBot = if targetBot ~= nil then targetBot.key else nil,
		t0 = t0,
		flight = flight.duration,
		intercepted = intercepted,
		interceptAt = if engagement ~= nil then engagement.interceptAt else 0,
		kind = kind,
		fromPlot = attacker.plot,
		toPlot = target.slot,
		silo = silo,
		impact = impact,
		area = area,
		sx = sx,
		sz = sz,
		tier = tier,
		shots = if engagement ~= nil then engagement.shots else 0,
		firstShot = if engagement ~= nil then engagement.firstShotAt else 0,
		reload = if engagement ~= nil then engagement.reload else 0,
		volleys = volleys,
	})
end

-- Refuses a launch: toast + analytics.
local function refuse(player: Player, reason: string)
	AttackAnalytics.record(player, `refused:{AttackLogic.analyticsReason(reason)}`)
	PlayerDataService.notify(player, AttackLogic.reasonText(reason), "error")
end

-- Cached AdminService (lazy: AdminService boots last and requires the handlers that use us).
local adminService: any = nil
-- True when `player` is an owner admin (AdminService's cached verdict; false when unavailable).
local function isAdmin(player: Player): boolean
	if adminService == nil then
		local ok, module = pcall(function(): any
			return require(script.Parent.AdminService) :: any
		end)
		adminService = if ok then module else false
	end
	if adminService == false then
		return false
	end
	local ok, result = pcall(adminService.isAdmin, player)
	return ok and result == true
end

-- A subject's built areas (Knockdown's server truth; empty on failure).
local function builtOf(subject: Player | TestBots.Bot): { number }
	local ok, built = pcall(Knockdown.builtAreas, subject :: any)
	return if ok and type(built) == "table" then built else {}
end

-- A subject's area income ($/s of that area's producers; 0 on failure).
local function areaIncomeOf(subject: Player | TestBots.Bot, area: number): number
	local ok, income = pcall(Knockdown.areaIncome, subject :: any, area)
	return if ok and type(income) == "number" then income else 0
end

-- Every Rival section index (aimable "areas" of a Rival Factory).
local RIVAL_SECTIONS: { number } = {}
for index in AttackConfig.Rivals.Sections do
	table.insert(RIVAL_SECTIONS, index)
end

--[[
	Resolves the AttackLaunch target argument: a rival id (string, exact allowlist) → that Rival
	Factory; a bot key ("bot:N") → that admin test bot; a userId (number) → the online player.
	Unknown → nil.
	@param raw unknown — the client's target argument
	@param t number — server time
	@return (TargetRef?, AttackLogic.Actor?) — the target and the rules' view of it
]]
local function targetOf(raw: unknown, t: number): (TargetRef?, AttackLogic.Actor?)
	local rivalIndex = AttackLogic.rivalIndex(raw)
	if rivalIndex ~= nil then
		local slot = AttackGeometry.rivalSlot(rivalIndex)
		local ref: TargetRef = {
			player = nil,
			rival = rivalIndex,
			bot = nil,
			key = 0,
			userId = 0,
			slot = slot,
			name = AttackConfig.Rivals.List[rivalIndex].name,
			built = RIVAL_SECTIONS,
		}
		return ref, AttackLogic.rivalActor(rivalIndex, slot, t)
	end
	local bot = TestBots.byKey(raw)
	if bot ~= nil then
		local ref: TargetRef = {
			player = nil,
			rival = nil,
			bot = bot,
			key = bot.key,
			userId = 0,
			slot = bot.plotIndex,
			name = bot.name,
			built = builtOf(bot),
		}
		return ref, TestBots.actor(bot)
	end
	local userId = Validate.userId(raw)
	local player = if userId ~= nil then Players:GetPlayerByUserId(userId) else nil
	if player == nil then
		return nil, nil
	end
	local actor = DefenseService.actorOf(player, t)
	local ref: TargetRef = {
		player = player,
		rival = nil,
		bot = nil,
		key = player.UserId,
		userId = player.UserId,
		slot = actor.plot,
		name = player.DisplayName,
		built = builtOf(player),
	}
	return ref, actor
end

--[[
	The minted reward of one hit on `area` (owner R50): a player / bot target pays rewardSeconds x
	the KNOCKED AREA's income, clamped to [MinRatio, MaxRatio] x the attacker's own income (no alt
	farming); a Rival Factory pays its fraction of the attacker's own income.
]]
local function rewardFor(
	kind: LaunchKind,
	launcherLevel: number,
	target: TargetRef,
	area: number,
	myIncome: number,
	mega: boolean
): number
	if target.rival ~= nil then
		return AttackLogic.rivalReward(kind, launcherLevel, target.rival, myIncome, mega)
	end
	local subject: (Player | TestBots.Bot)? = target.player or target.bot
	if subject == nil then
		return 0
	end
	return AttackLogic.reward(kind, launcherLevel, areaIncomeOf(subject, area), myIncome, mega)
end

--[[
	AttackLaunch(target, kind?, area?) handler (see the header). Never trusts anything but the
	target id (a userId, a Rival Factory id or an admin test bot key), the kind label and the aimed
	area index (owner R50; validated against the target's BUILT areas — nil / 0 = the default aim).
	Connected through Remotes.onServerEvent, so a late event from a departed player never re-creates
	the limiter bucket.
]]
local function onLaunch(attacker: Player, rawTarget: unknown, rawKind: unknown, rawArea: unknown)
	if not launchLimiter:Allow(attacker) then
		-- Counted, but no toast: a spamming client must not turn into outgoing traffic.
		AttackAnalytics.record(attacker, "refused:rate")
		return
	end
	local kind = (if rawKind == nil then "normal" else Validate.oneOf(rawKind, KINDS)) :: LaunchKind?
	local requestedArea = if rawArea == nil then 0 else Validate.integer(rawArea, 0, 99)
	-- Malformed packets are dropped silently (only a well-formed target id gets a refusal toast).
	if
		kind == nil
		or requestedArea == nil
		or (
			AttackLogic.rivalIndex(rawTarget) == nil
			and TestBots.byKey(rawTarget) == nil
			and Validate.userId(rawTarget) == nil
		)
	then
		return
	end
	local profile = PlayerDataService.getProfile(attacker)
	if profile == nil then
		return
	end
	local t = now()
	local target, them = targetOf(rawTarget, t)
	-- Admin kill switch: Rival Factories switched off on this server.
	if target ~= nil and target.rival ~= nil and not DefenseService.rivalsEnabled() then
		refuse(attacker, "target")
		return
	end
	-- Owner R51: only admins may target test bots (nobody can farm them).
	if target ~= nil and target.bot ~= nil and not isAdmin(attacker) then
		refuse(attacker, "target")
		return
	end
	local me = DefenseService.actorOf(attacker, t)
	local revengeReady = target ~= nil and target.rival == nil and hasRevenge(attacker, target.key, t)
	-- Owner R85: a golden nuke at someone who just hit you ignores their new-player protection
	-- (they started it); their shield still blocks it, like any golden launch.
	if kind == "golden" and revengeReady and them ~= nil then
		them = table.clone(them)
		them.newbie = false
	end
	local ok, reason = AttackLogic.canLaunch(me, them, kind, t, revengeReady)
	if not ok or target == nil then
		refuse(attacker, reason or "target")
		return
	end
	-- Owner R50: the aimed area must be built (rivals: a section index); 0 = the default aim.
	local aim = AttackLogic.resolveAim(target.built, if requestedArea == 0 then nil else requestedArea)
	if aim == nil then
		refuse(attacker, "aim")
		return
	end
	if kind == "barrage" and (barrageBusyUntil[attacker] or 0) > t then
		refuse(attacker, "rate")
		return
	end
	local count = if kind == "barrage" then math.min(AttackProfile.barrage(profile), AttackConfig.BarrageSize) else 1
	if kind == "golden" and not GOLDEN.Enabled then
		refuse(attacker, "locked")
		return
	end
	-- Server-wide cap, and a per-attacker share of it so one player's barrages never starve
	-- everyone else's launches.
	if
		queue:count() + count > AttackConfig.MaxNukesInFlight
		or (inFlight[attacker] or 0) + count > AttackConfig.MaxNukesInFlightPerAttacker
	then
		refuse(attacker, "rate")
		return
	end

	-- Commit the attacker's side first (cooldown / token / stored nukes), then publish.
	local launcherLevel = math.max(me.launcher, 1)
	if kind == "normal" then
		AttackProfile.set(profile, "cooldownUntil", AttackLogic.cooldownAfter(t, launcherLevel))
	elseif kind == "revenge" then
		local tokens = revenge[attacker]
		if tokens ~= nil then
			tokens[target.key] = nil
		end
	elseif kind == "golden" then
		AttackProfile.setGolden(profile, AttackProfile.golden(profile) - 1)
	else
		AttackProfile.setBarrage(profile, AttackProfile.barrage(profile) - count)
		barrageBusyUntil[attacker] = t + count * AttackConfig.BarrageStagger + FLIGHT.LeadIn
	end
	profile.stats.launches += count
	PlayerDataService.markChanged(attacker, kind == "barrage" or kind == "golden", { "attack", "stats" })

	-- Rewards are computed per knocked area at launch (owner R50); a barrage may spill into ONE
	-- built neighbour (chance per nuke, the neighbour picked once per volley).
	local myIncome = TycoonBridge.incomePerSecond(attacker, profile)
	local mega = MonetizationService.ownsPass(attacker, AttackConfig.Reward.MegaLauncherPass)
	local volley = AttackRng.new(AttackRng.mix(serverSeed, -(nextId + 1)))
	local spill = if kind == "barrage" and target.rival == nil
		then AttackLogic.spillNeighbour(target.built, aim, volley:next())
		else nil
	local rewards: { [number]: number } = {}
	local ref: AttackerRef = {
		player = attacker,
		bot = nil,
		key = attacker.UserId,
		name = attacker.DisplayName,
		plot = me.plot,
	}
	local silos = AttackLogic.silos(profile.tycoon.pads)
	for index = 1, count do
		local area = if spill ~= nil and volley:next() < AttackConfig.Aim.BarrageSpillChance then spill else aim
		local reward = rewards[area]
		if reward == nil then
			reward = rewardFor(kind, launcherLevel, target, area, myIncome, mega)
			rewards[area] = reward
		end
		local t0 = t + FLIGHT.LeadIn + (index - 1) * AttackConfig.BarrageStagger
		local silo = silos[((index - 1) % #silos) + 1]
		launchOne(ref, target, kind, silo, launcherLevel, reward :: number, t0, false, area)
	end
	-- Bot targets are admin tests: kept out of the attack analytics (owner R51).
	if target.bot == nil then
		AttackAnalytics.record(attacker, `launch:{kind}`, count)
		AttackAnalytics.record(attacker, `targets:{targetableCount(attacker)}`)
		if target.rival ~= nil then
			AttackAnalytics.record(attacker, `rival:{target.rival}`, count)
		end
	end
end

--[[
	Owner R51: an admin test bot launches at a player (its owner) — the same flight, AA, shield,
	knockdown and Revenge path as a real attack; the bot pays / earns nothing.
	@param bot TestBots.Bot
	@param target Player — the admin the bot attacks
	@param kind "normal" | "barrage"
	@param area number — aim (0 = the target's default aim)
	@return (boolean, string) — sent?, message for the admin
]]
function AttackService.botLaunch(
	bot: TestBots.Bot,
	target: Player,
	kind: TestBots.Kind,
	area: number
): (boolean, string)
	local t = now()
	if TestBots.byKey(bot.key) ~= bot then
		return false, "That bot is gone"
	end
	local them = DefenseService.actorOf(target, t)
	if not them.loaded or them.plot < 1 then
		return false, `{target.DisplayName} has no plot yet`
	end
	if AttackLogic.shieldActive(them.shieldUntil, t) then
		return false, "Your shield bubble is up - the bot's nukes would bounce (turn it off to test hits)"
	end
	local built = builtOf(target)
	local aim = AttackLogic.resolveAim(built, if area == 0 then nil else area)
	if aim == nil then
		return false, `Area {area} is not built on your plot`
	end
	local count = if kind == "barrage" then AttackConfig.BarrageSize else 1
	if queue:count() + count > AttackConfig.MaxNukesInFlight then
		return false, "Too many nukes in the air - try again in a moment"
	end
	local ref: TargetRef = {
		player = target,
		rival = nil,
		bot = nil,
		key = target.UserId,
		userId = target.UserId,
		slot = them.plot,
		name = target.DisplayName,
		built = built,
	}
	local attacker: AttackerRef = {
		player = nil,
		bot = bot,
		key = bot.key,
		name = bot.name,
		plot = bot.plotIndex,
	}
	local volley = AttackRng.new(AttackRng.mix(serverSeed, -(nextId + 1)))
	local spill = if kind == "barrage" then AttackLogic.spillNeighbour(built, aim, volley:next()) else nil
	local silos = if bot.area >= AttackConfig.UnlockArea then { 1, 2, 3 } else { 1 }
	for index = 1, count do
		local nukeArea = if spill ~= nil and volley:next() < AttackConfig.Aim.BarrageSpillChance then spill else aim
		local t0 = t + FLIGHT.LeadIn + (index - 1) * AttackConfig.BarrageStagger
		launchOne(attacker, ref, kind, silos[((index - 1) % #silos) + 1], bot.launcher, 0, t0, false, nukeArea)
	end
	return true, `{bot.name} launched {if count > 1 then `{count} nukes` else "a nuke"} at your area {aim}`
end

--------------------------------------------------------------------------------------------------
-- Outcomes
--------------------------------------------------------------------------------------------------

-- Resolves one nuke at its outcome time.
local function resolve(nuke: Nuke)
	local attacker, target = nuke.attacker, nuke.target
	local attackerPlayer = attacker.player
	local attackerHere = attackerPlayer ~= nil and attackerPlayer.Parent == Players
	local attackerBot = attacker.bot
	local botAlive = attackerBot ~= nil and TestBots.byKey(attackerBot.key) == attackerBot
	local targetPlayer = target.player
	local targetHere = targetPlayer ~= nil and targetPlayer.Parent == Players
	local targetBot = target.bot
	-- Admin test traffic (owner R51) stays out of the attack analytics.
	local testTraffic = attackerBot ~= nil or targetBot ~= nil
	if attackerPlayer ~= nil then
		local flying = (inFlight[attackerPlayer] or 1) - 1
		inFlight[attackerPlayer] = if flying > 0 and attackerHere then flying else nil
	end
	if nuke.test then
		return
	end
	if nuke.intercepted then
		if not testTraffic then
			AttackAnalytics.record(if attackerHere then attackerPlayer else nil, "intercept")
			-- Owner R80: which tower stopped it (0 = the HQ Feature tower, 1.. = defence slot),
			-- recorded for the defending player.
			if targetHere and targetPlayer ~= nil and nuke.hitTower >= 0 then
				AttackAnalytics.record(targetPlayer, `interceptBy:{math.clamp(nuke.hitTower, 0, 9)}`)
			end
		end
		if attackerHere and attackerPlayer ~= nil then
			pendingOf(attackerPlayer).missed += 1
		end
		if targetHere and targetPlayer ~= nil then
			pendingOf(targetPlayer).blocked += 1
		end
		return
	end

	-- A hit. Owner R50: knock down the area it landed in (temporary; nothing is ever lost), then
	-- pay the attacker MINTED cash — the full reward, or BlockedFactor of it when nothing went down.
	local knocked = false
	local label: string? = nil
	if nuke.area >= 1 then
		if target.rival ~= nil then
			local section = RivalIslands.section(target.rival, nuke.area)
			local ok, result = pcall(function(): boolean
				return section ~= nil
					and Knockdown.knockInstance(section, AttackConfig.Rivals.SectionDownSeconds, nuke.point)
			end)
			knocked = ok and result == true
			label = `the {AttackConfig.Rivals.Sections[nuke.area].label} at {target.name}`
		else
			local subject: (Player | TestBots.Bot)? = if targetHere then targetPlayer else targetBot
			if subject ~= nil then
				local attackerUserId = if attackerPlayer ~= nil
					then attackerPlayer.UserId
					elseif attackerBot ~= nil then -(1_000_000 + attackerBot.id) -- never a real userId
					else nil
				local opts: Knockdown.ApplyOptions = {
					durationSeconds = KnockdownConfig.duration(nuke.launcherLevel),
					attackerUserId = attackerUserId,
					source = if testTraffic then "test" else nuke.kind,
					center = nuke.point,
				}
				local ok, applied = pcall(Knockdown.apply, subject :: any, nuke.area, opts)
				knocked = ok and applied == true
			end
			label = `{target.name}'s {KnockdownConfig.areaLabel(nuke.area)}`
		end
	end
	if not testTraffic then
		AttackAnalytics.record(if attackerHere then attackerPlayer else nil, "hit")
	end
	if attackerHere and attackerPlayer ~= nil then
		local amount = if knocked or nuke.area < 1 then nuke.reward else nuke.reward * AttackConfig.Reward.BlockedFactor
		-- Hitting a test bot pays (so the money path is testable) under its own "test" reason.
		local paid = PlayerDataService.grantCash(
			attackerPlayer,
			amount,
			if targetBot ~= nil then "attack_test" else "attack_hit"
		)
		local profile = PlayerDataService.getProfile(attackerPlayer)
		if profile ~= nil then
			profile.stats.hits += 1
			PlayerDataService.markChanged(attackerPlayer, false, { "stats" })
		end
		if paid > 0 and not testTraffic then
			AttackAnalytics.record(attackerPlayer, "hitCash", paid)
		end
		local entry = pendingOf(attackerPlayer)
		if knocked then
			entry.knocked = label
			entry.protectedName = nil
		elseif nuke.area >= 1 and entry.knocked == nil then
			entry.protectedName = target.name
		end
		entry.hits += 1
		entry.cash += paid
	end
	if targetHere and targetPlayer ~= nil then
		local t = now()
		local entry = pendingOf(targetPlayer)
		entry.nuked += 1
		entry.byName = attacker.name
		-- Normal / barrage hits give the target a Revenge token against the attacker (a player, or a
		-- live test bot); a revenge or golden revenge hit does not (no endless ping-pong).
		if (attackerHere or botAlive) and nuke.kind ~= "revenge" and nuke.kind ~= "golden" then
			grantRevenge(targetPlayer, attacker.key, t)
		end
		if DefenseService.recordHit(targetPlayer) then
			entry.shieldReady = true
		end
	end
end

-- The one Heartbeat step: due outcomes, then due toasts. O(1) when idle.
local function step()
	local t = now()
	while queue:peekTime() <= t do
		local _, nuke = queue:pop()
		if nuke ~= nil then
			local ok, err = pcall(resolve, nuke)
			if not ok then
				warn(`[AttackService] resolve failed: {err}`)
			end
		end
	end
	if pendingCount > 0 then
		local clock = os.clock()
		for player, entry in pending do
			if
				clock - entry.lastAt >= AttackConfig.ToastCoalesceSeconds
				or clock - entry.firstAt >= AttackConfig.ToastMaxDelaySeconds
			then
				pending[player] = nil
				pendingCount -= 1
				flushToasts(player, entry)
			end
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Products
--------------------------------------------------------------------------------------------------

--[[
	"Barrage" product: + `nukes` stored barrage nukes (durable; sent later at a chosen target).
	The WHOLE pack is always added (never clamped — security audit, Q2 2026-10-30), even above
	MaxStoredBarrage (receipts landing back to back / re-delivered after a rejoin); only a pack
	that would pass the storage bound is not granted (false → NotProcessedYet: Roblox never
	completes a purchase whose nukes could not be stored). Never yields.
]]
local function grantBarrage(player: Player, profile: any, product: any, _receipt: any): boolean
	local nukes = product.nukes
	if type(nukes) ~= "number" or nukes < 1 or nukes % 1 ~= 0 then
		return false
	end
	local added, total = AttackProfile.addBarrage(profile, nukes)
	if not added then
		warn(`[AttackService] Barrage receipt for {player.UserId} not granted: storage limit`)
		return false
	end
	task.defer(function()
		if player.Parent == Players then
			PlayerDataService.markChanged(player, true, { "attack" })
			PlayerDataService.notify(
				player,
				`+{nukes} Barrage nukes! You have {total}. Pick a target and hit BARRAGE!`,
				"reward",
				"Attack"
			)
		end
	end)
	return true
end

--[[
	Prompt refusal (shown BEFORE paying): Barrage needs the Attack Console (the nukes would be
	unusable), and the pack must fit under MaxStoredBarrage (QA 2026-10-30: checking only
	">= cap" let a player at 1,981-1,999 pay for 20 and receive 1-19).
]]
local function refuseBarrage(player: Player, product: any): string?
	local profile = PlayerDataService.getProfile(player)
	-- Owner R85: every player has a launcher, so only a missing profile refuses.
	if profile == nil then
		return AttackLogic.reasonText("locked")
	end
	local nukes = if type(product) == "table" then product.nukes else nil
	if not AttackLogic.barrageFits(AttackProfile.barrage(profile), nukes) then
		return `You already have {AttackProfile.barrage(profile)} Barrage nukes - send some first!`
	end
	return nil
end

--------------------------------------------------------------------------------------------------
-- Golden revenge nuke (owner R85: "a 39 ... revenge nuke button that you can pay for with Robux")
--------------------------------------------------------------------------------------------------

--[[
	The player who hit `victim` most recently and can take a golden nuke right now: a live
	Revenge token (newest first), still in the server, with a plot and no shield. Test bots are
	never golden targets (admin traffic stays free).
	@param victim Player
	@param t number — server time
	@return Player?
]]
local function goldenTarget(victim: Player, t: number): Player?
	local tokens = revenge[victim]
	if tokens == nil then
		return nil
	end
	local best: Player? = nil
	local bestExpiry = -math.huge
	for key, expires in tokens do
		if type(key) == "number" and expires > t and expires > bestExpiry then
			local attacker = Players:GetPlayerByUserId(key)
			if attacker ~= nil then
				local actor = DefenseService.actorOf(attacker, t)
				if actor.loaded and actor.plot >= 1 and not AttackLogic.shieldActive(actor.shieldUntil, t) then
					best, bestExpiry = attacker, expires
				end
			end
		end
	end
	return best
end

--[[
	Fires one stored golden charge of `player` at their newest hittable attacker through the normal
	launch path (onLaunch: every rule re-checked; the charge is consumed there). Returns false and
	keeps the charge when nobody can take it.
	@param player Player
	@return boolean — launched?
]]
local function fireGolden(player: Player): boolean
	if player.Parent ~= Players or not GOLDEN.Enabled then
		return false
	end
	local profile = PlayerDataService.getProfile(player)
	local target = goldenTarget(player, now())
	if profile == nil or target == nil or AttackProfile.golden(profile) < 1 then
		return false
	end
	local before = AttackProfile.golden(profile)
	onLaunch(player, target.UserId, "golden", nil)
	return AttackProfile.golden(profile) < before
end

--[[
	"RevengeNuke" receipt (owner R85): ALWAYS stores the charge first (all or nothing; past the
	storage bound → NotProcessedYet, Roblox retries), never yields; then, deferred, fires it at the
	newest hittable attacker. If they left / shielded up, the charge stays for the picker.
]]
local function grantGolden(player: Player, profile: any, product: any, _receipt: any): boolean
	local count = if type(product) == "table" and type(product.nukes) == "number" then product.nukes else 1
	local added, total = AttackProfile.addGolden(profile, count)
	if not added then
		warn(`[AttackService] RevengeNuke receipt for {player.UserId} not granted: storage limit`)
		return false
	end
	AttackAnalytics.record(player, "golden:buy")
	task.defer(function()
		if player.Parent ~= Players then
			return
		end
		PlayerDataService.markChanged(player, true, { "attack" })
		if fireGolden(player) then
			AttackAnalytics.record(player, "golden:auto")
			PlayerDataService.notify(player, "GOLDEN REVENGE NUKE away! Payback time!", "reward", "Attack")
		else
			AttackAnalytics.record(player, "golden:stored")
			PlayerDataService.notify(
				player,
				`Golden Nuke saved ({total}). Launch it from the Attack window at anyone!`,
				"reward",
				"Attack"
			)
		end
	end)
	return true
end

--[[
	Prompt refusal (shown BEFORE paying): the golden nuke is sold only while the player who hit you
	is here and hittable (owner R85), the kill switch is on, and storage has room.
]]
local function refuseGolden(player: Player, _product: any): string?
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not GOLDEN.Enabled then
		return "Golden revenge nukes are not available right now."
	end
	if AttackProfile.golden(profile) >= GOLDEN.MaxStored then
		return `You already have {AttackProfile.golden(profile)} Golden Nukes - launch some first!`
	end
	if goldenTarget(player, now()) == nil then
		return "Nobody to strike back at right now (they left or their shield is up)."
	end
	return nil
end

--[[
	Admin / QA (AttackGolden command): grants stored golden charges.
	@return number — the new stored total (0 when not loaded)
]]
function AttackService.giveGolden(player: Player, count: number): number
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return 0
	end
	local added, total = AttackProfile.addGolden(profile, count)
	if added then
		PlayerDataService.markChanged(player, true, { "attack" })
	end
	return total
end

--------------------------------------------------------------------------------------------------
-- Admin / test API
--------------------------------------------------------------------------------------------------

--[[
	Sends a TEST nuke at `target`'s plot from the opposite plot's silo (no attacker, no reward, no
	hit counted; the target's AA tower engages for real). For one-player verification.
	@param target Player
	@return boolean — false when the target has no plot
]]
function AttackService.testFlight(target: Player): boolean
	local toPlot = TycoonBridge.plotIndex(target)
	if toPlot == nil then
		return false
	end
	local fromPlot = ((toPlot + WorldLayout.PlotCount // 2 - 1) % WorldLayout.PlotCount) + 1
	local t = now()
	local _, launcher = DefenseService.levels(target)
	local ref: TargetRef = {
		player = target,
		rival = nil,
		bot = nil,
		key = target.UserId,
		userId = target.UserId,
		slot = toPlot,
		name = target.DisplayName,
		built = {},
	}
	local from: AttackerRef = { player = target, bot = nil, key = target.UserId, name = "Test", plot = fromPlot }
	launchOne(from, ref, "normal", 1, math.max(launcher, 1), 0, t + FLIGHT.LeadIn, true, 0)
	return true
end

--[[ Clears a player's launch cooldown (admin). ]]
function AttackService.resetCooldown(player: Player): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false
	end
	AttackProfile.set(profile, "cooldownUntil", 0)
	barrageBusyUntil[player] = nil
	PlayerDataService.markChanged(player, true, { "attack" })
	return true
end

--[[ Adds stored barrage nukes (admin). @return the new total ]]
function AttackService.giveBarrage(player: Player, count: number): number
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return 0
	end
	AttackProfile.setBarrage(profile, AttackProfile.barrage(profile) + count)
	PlayerDataService.markChanged(player, true, { "attack" })
	return AttackProfile.barrage(profile)
end

--[[ Resets the free-shield hit counter (admin). ]]
function AttackService.resetHits(player: Player): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false
	end
	AttackProfile.set(profile, "hitsTaken", 0)
	PlayerDataService.markChanged(player, true, { "attack" })
	return true
end

--[[ Live numbers for the admin panel / tests. ]]
function AttackService.stats(): { inFlight: number, pendingToasts: number, launched: number }
	return { inFlight = queue:count(), pendingToasts = pendingCount, launched = nextId }
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

function AttackService.Init()
	MonetizationService.registerProductHandler("Barrage", grantBarrage)
	MonetizationService.registerPromptRefusal("Barrage", refuseBarrage)
	-- Owner R85 golden revenge nuke (product kind "RevengeNuke").
	MonetizationService.registerProductHandler("RevengeNuke", grantGolden)
	MonetizationService.registerPromptRefusal("RevengeNuke", refuseGolden)
end

function AttackService.Start()
	-- onServerEvent drops late events from departed players (no limiter bucket re-created).
	Remotes.onServerEvent("AttackLaunch", onLaunch)
	-- Owner R51 admin test bots: their launches go through the same path (botLaunch).
	TestBots.setLauncher(AttackService.botLaunch)
	TestBots.start()
	-- Owner R104: AttackPickerFocus (picker target streaming focus, linger, expiry, leave cleanup).
	PickerFocus.start()
	RunService.Heartbeat:Connect(step)
	Players.PlayerRemoving:Connect(function(player: Player)
		launchLimiter:Forget(player)
		revenge[player] = nil
		barrageBusyUntil[player] = nil
		-- Their nukes still resolve (and treat a missing count as 0); drop the Player reference.
		inFlight[player] = nil
		if pending[player] ~= nil then
			pending[player] = nil
			pendingCount -= 1
		end
		-- Tokens other players hold against the leaver are useless now.
		for _, tokens in revenge do
			tokens[player.UserId] = nil
		end
	end)
	-- Owner admin commands (guarded: skipped when AdminService is missing). Deferred so the
	-- AdminService (booted last) has run its Init before commands are registered.
	task.defer(function()
		local ok, err = pcall(AttackAdmin.install, AttackService, DefenseService)
		if not ok then
			warn(`[AttackService] admin commands not installed: {err}`)
		end
	end)
end

return AttackService
