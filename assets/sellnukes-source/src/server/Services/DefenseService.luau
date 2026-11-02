--!strict
--[[
	DefenseService — the defending half of Attack mode (spec §9) and the per-player attack runtime:
	effective AA / Launcher levels, AA tower interception scheduling, shields, upgrades, the public
	attack attributes and every attack object on the plots (turret, dome, console prompt).

	Owns
		* Runtime per player: plot, effective levels (TycoonLogic.hasFeature-gated), the tower's next
		  free fire time (server time; shared by every nuke aimed at this plot, so a Barrage can
		  saturate a tower).
		* Reconcile (event-driven + a 1 Hz safety pass over <= 8 players): Feature pad newly owned →
		  stored level raised to 1 (HUD Attack button), turret / console prompt / dome follow the
		  plot and the levels, public Player attributes (AttackConfig.Attr) change only on change.
		* Remotes:
			DefenseUpgrade(kind: "aa" | "launcher", toLevel?)  buy the next level with cash (server
			                                          price); toLevel (optional) must be stored + 1
			DefenseTower(slot, toLevel)               owner R80: buy (toLevel 1) / upgrade a defence
			                                          tower slot (DefenseTowers.plan; idempotent per level)
			ShieldActivate()                          turn on the earned free 10-min shield
		* Owner R85: attack is open to everyone — effective launcher = AttackLogic.launcherLevel
		  (StarterLauncher without the Console, >= ConsoleLauncher with it); a player is targetable
		  once not a brand-new player (isNewbie: tutorial done + grace seconds of play, admin
		  setGraceSeconds) — the defence pads appear at that moment.
		* Defence towers (owner R80, AttackConfig.Towers): while a player is targetable each unlocked
		  slot shows either a blue BUY pad (walk on it / E / X / tap its price / the Defense window)
		  or the bought tower at its level with an UPGRADE billboard (client DefenseWorld). Bought
		  towers build in with the fly-in; levels persist through Rebirth (hidden below the slot's
		  unlockArea, rebuilt with the fly-in when the area reopens). Admin: setTowerLevel(s) and the
		  setTowersEnabled kill switch (buys / upgrades off; owned towers keep defending).
		* Products: "Shield" (Shield1h) adds `durationSeconds` of shield (stacks; prompt refused when
		  the total would pass MaxShieldSeconds).
		* engage(target, flight, armor, t0, rng): EVERY tower of the target (the HQ Feature tower +
		  each built defence slot, each from its own muzzle with its own level and fire schedule)
		  against one nuke (FlightMath.engageMany), advancing the schedules of the towers that fired.
		* recordHit(target): hit counter toward the free shield.
		* Rival Factories (owner R43): RivalIslands.start() builds the islands; one tower runtime per
		  rival (engageRival — the same FlightMath engagement, one fire schedule shared by every
		  attacker, so barrages saturate it too), the levelled turret, and the shield dome following
		  AttackLogic.rivalShieldUntil (deterministic cycle). setRivalsEnabled is the admin kill
		  switch (ReplicatedStorage attribute Attr.RivalsOn, read by the picker).

	Security: intents only (a kind string / a slot + target level, nothing else); Validate.oneOf /
	DefenseTowers.validSlot allowlists, per-player rate limits, profile-loaded + feature-owned /
	slot-unlocked + max-level + "toLevel is stored + 1" checks (a repeated or stale intent never
	buys twice), the price is computed on the server (AttackLogic.upgradeCost × the pad price /
	DefenseTowers.costTo) and spent atomically (trySpendCash). Walk-on buys only count the plot
	owner's own character (Players:GetPlayerFromCharacter + plot match), debounced per player. Receipt handlers
	never yield (world updates are deferred). Remote handlers connect through
	Remotes.onServerEvent, which drops events from players who already left (no limiter bucket
	re-created after PlayerRemoving). The free shield obeys the same MaxShieldSeconds cap as the
	paid one (AttackLogic.freeShieldFits). No AFK protection (owner R43): a player is protected
	only before Launch Silos or under a shield.

	Performance: one 1 Hz loop over <= 8 players + <= 4 rivals doing table reads; attributes and
	world objects only change on change; no per-frame work. An engagement costs one range-window
	search per active tower (<= 1 + #Towers.Slots), once per nuke.

	Connects to: Shared/Attack/{AttackLogic, FlightMath, AttackGeometry}, Shared/Config/AttackConfig,
	Server/Attack/{TycoonBridge, AttackWorld, AttackProfile, AttackAnalytics, RivalIslands},
	Services/{PlayerDataService, MonetizationService}, AttackService (engage / engageRival /
	recordHit / actorOf / rivalsEnabled).

	Boot: after TycoonService (needs PlotService / TycoonService), before AttackService.

	Example:
		local actor = DefenseService.actorOf(player, Workspace:GetServerTimeNow())
		local result = DefenseService.engage(target, flight, armor, t0, rng)
		local vsRival = DefenseService.engageRival(1, flight, armor, t0, rng)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttackAnalytics = require(script.Parent.Parent.Attack.AttackAnalytics)
local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local AttackLogic = require(ReplicatedStorage.Shared.Attack.AttackLogic)
local AttackProfile = require(script.Parent.Parent.Attack.AttackProfile)
local AttackRng = require(ReplicatedStorage.Shared.Attack.AttackRng)
local AttackWorld = require(script.Parent.Parent.Attack.AttackWorld)
local DefenseTowers = require(ReplicatedStorage.Shared.Attack.DefenseTowers)
local FlightMath = require(ReplicatedStorage.Shared.Attack.FlightMath)
local Knockdown = require(script.Parent.Parent.Tycoon.Knockdown)
local MonetizationService = require(script.Parent.MonetizationService)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RivalIslands = require(script.Parent.Parent.Attack.RivalIslands)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TutorialLogic = require(script.Parent.Parent.Tycoon.TutorialLogic)
local TycoonBridge = require(script.Parent.Parent.Attack.TycoonBridge)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)

local DefenseService = {}

local ATTR = AttackConfig.Attr
local ATTACK_FIELDS = { "attack" }

--[[ Fires (player) after a player's attack runtime changed (levels, plot, shield). ]]
DefenseService.Changed = Signal.new() :: Signal.Signal<Player>

type Runtime = {
	plot: number, -- 0 = none
	aa: number, -- effective AA level
	launcher: number, -- effective launcher level
	console: boolean, -- owns the Attack Console pad
	towerFreeAt: number, -- server time the tower may fire next
	shieldShown: boolean, -- dome currently shown
	shieldUntilShown: number, -- the dome's published end time
	turretShown: number, -- turret level currently shown on the plot (0 = none)
	promptShown: boolean, -- console prompt shown
	-- Owner R80 defence tower slots (index = AttackConfig.Towers slot):
	slots: { number }, -- effective level per slot (0 = not bought / not unlocked at this area)
	slotFreeAt: { number }, -- server time each slot's tower may fire next
	slotShown: { number }, -- what the plot shows per slot: -1 nothing, 0 the BUY pad, L the tower
	seeded: boolean, -- the plot's objects were placed once (later appearances build in)
	warned: boolean, -- the "you can be nuked now, build AA towers" toast was sent this session
	towerCount: number, -- active towers (HQ + slots), mirrored to Attr.Towers
}

local runtimes: { [Player]: Runtime } = {}

-- One Rival Factory's server state (owner R43): its tower fire schedule + what the world shows.
type RivalRuntime = {
	towerFreeAt: number, -- server time the rival's tower may fire next
	turretShown: number, -- turret level currently shown on the island (0 = none yet)
	shieldShown: boolean, -- dome currently shown
	shieldUntilShown: number, -- the dome's published end time
}
local rivalRuntimes: { RivalRuntime } = {}
for _ in AttackConfig.Rivals.List do
	table.insert(rivalRuntimes, {
		towerFreeAt = -math.huge,
		turretShown = 0,
		shieldShown = false,
		shieldUntilShown = 0,
	})
end
-- Admin kill switch (AttackRivals command): Rival Factories accept launches while true.
local rivalsOn = true
local upgradeLimiter =
	RateLimiter.new(AttackConfig.RateLimits.DefenseUpgrade.capacity, AttackConfig.RateLimits.DefenseUpgrade.refill)
local shieldLimiter =
	RateLimiter.new(AttackConfig.RateLimits.ShieldActivate.capacity, AttackConfig.RateLimits.ShieldActivate.refill)
local towerLimiter =
	RateLimiter.new(AttackConfig.RateLimits.DefenseTower.capacity, AttackConfig.RateLimits.DefenseTower.refill)
-- Owner R80 admin kill switch (AttackTowerShop command): defence tower buys / upgrades accepted
-- on this server while true. Owned towers always keep defending (nothing is ever taken away).
local towersOn = true
-- Walk-on buys: last attempt / last "Need $X" toast per player (os.clock), cleared on leave.
local touchAt: { [Player]: number } = {}
local noticeAt: { [Player]: number } = {}
local TOWERS = AttackConfig.Towers
-- Owner R85 new-player protection: seconds of lifetime play before a player can be targeted
-- (AttackConfig.NewPlayer.GraceSeconds; the AttackGrace admin command changes it live).
local graceSeconds = AttackConfig.NewPlayer.GraceSeconds

--[[
	Owner R85: true while a profile is still protected as a brand-new player — the tutorial is not
	finished (when NewPlayer.RequireTutorial) or it has fewer than the grace seconds of play.
	@param profile any — a loaded profile (nil → protected)
	@return boolean
]]
local function isNewbie(profile: any): boolean
	if type(profile) ~= "table" or type(profile.tycoon) ~= "table" or type(profile.stats) ~= "table" then
		return true
	end
	if AttackConfig.NewPlayer.RequireTutorial then
		local step = profile.tycoon.tutorialStep
		if type(step) ~= "number" or step < TutorialLogic.DoneStep then
			return true
		end
	end
	local played = profile.stats.playSeconds
	return type(played) ~= "number" or played < graceSeconds
end
DefenseService.isNewbie = isNewbie

-- Feature key of an upgrade kind.
local FEATURE_OF: { [string]: string } = { aa = AttackConfig.FeatureAA, launcher = AttackConfig.FeatureConsole }

local function now(): number
	return Workspace:GetServerTimeNow()
end

-- The runtime of a player (created on first use; plot 0 until reconciled).
local function runtimeOf(player: Player): Runtime
	local runtime = runtimes[player]
	if runtime == nil then
		runtime = {
			plot = 0,
			aa = 0,
			launcher = 0,
			console = false,
			towerFreeAt = -math.huge,
			shieldShown = false,
			shieldUntilShown = 0,
			turretShown = 0,
			promptShown = false,
			slots = table.create(DefenseTowers.count(), 0),
			slotFreeAt = table.create(DefenseTowers.count(), -math.huge),
			slotShown = table.create(DefenseTowers.count(), -1),
			seeded = false,
			warned = false,
			towerCount = 0,
		}
		runtimes[player] = runtime
	end
	return runtime
end

-- Sets a Player attribute only when it changed (each change replicates to every client).
local function setAttr(player: Player, name: string, value: any)
	if player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

--------------------------------------------------------------------------------------------------
-- Reconcile
--------------------------------------------------------------------------------------------------

-- Forward declaration: the walk-on pad handler buys through the same path as the remote
-- (assigned in the Remotes section below).
local tryTower: (player: Player, index: number, toLevel: number, source: string) -> ()

--[[
	Server walk-on handler of a defence BUY pad (owner R80): only the plot owner's own character
	buys, debounced per player (Touched fires many times while standing on the pad).
	@param plot number — the pad's plot
	@param index number — its tower slot
	@param hit BasePart — the touching part
]]
local function onPadTouched(plot: number, index: number, hit: BasePart)
	local character = hit:FindFirstAncestorOfClass("Model")
	local player = if character ~= nil then Players:GetPlayerFromCharacter(character) else nil
	local runtime = if player ~= nil then runtimes[player] else nil
	if player == nil or runtime == nil or runtime.plot ~= plot or player.Parent ~= Players then
		return -- only the owner's own character buys
	end
	local clock = os.clock()
	if clock - (touchAt[player] or -math.huge) < TOWERS.TouchDebounce then
		return
	end
	touchAt[player] = clock
	tryTower(player, index, 1, "walk")
end

--[[
	Brings one player's defence tower slots in line with the profile (owner R80): effective levels,
	and on the plot either nothing (slot not unlocked), the blue BUY pad (unlocked, not bought) or
	the tower at its level. Change-only; called from reconcile.
	@param player Player
	@param runtime Runtime
	@param profile any? — nil while not loaded (everything hidden)
	@param plot number — 0 = no plot
	@param flyIn boolean — a level change here comes from a purchase / admin grant (build-in)
	@param targetable boolean — the player can be nuked right now (owner R85: pads appear then)
]]
local function reconcileSlots(
	player: Player,
	runtime: Runtime,
	profile: any?,
	plot: number,
	flyIn: boolean,
	targetable: boolean
)
	-- Owner R85: slots exist only while the player can be nuked (0 = still protected).
	local area = if profile ~= nil then DefenseTowers.areaFor(TycoonBridge.area(profile), targetable) else 0
	local stored = if profile ~= nil then AttackProfile.towers(profile) else nil
	for index = 1, DefenseTowers.count() do
		local unlocked = profile ~= nil and plot > 0 and DefenseTowers.unlocked(index, area)
		local level = if unlocked then DefenseTowers.level(stored, index) else 0
		runtime.slots[index] = level
		if plot < 1 then
			continue
		end
		local wanted = if not unlocked then -1 elseif level < 1 then 0 else level
		local shown = runtime.slotShown[index]
		if shown == wanted then
			continue
		end
		if wanted >= 1 then
			-- A purchase / upgrade, or the tower coming back once its area reopens after a Rebirth
			-- (shown -1 after the plot was seeded): build in with the fly-in. On join: just appear.
			local build = flyIn or (runtime.seeded and shown == -1)
			AttackWorld.setDefensePad(plot, index, nil, 0, nil)
			AttackWorld.setTower(plot, index, wanted, if build then player else nil)
		elseif wanted == 0 then
			AttackWorld.setTower(plot, index, 0, nil)
			AttackWorld.setDefensePad(plot, index, player.UserId, DefenseTowers.buyCost(index), function(hit: BasePart)
				onPadTouched(plot, index, hit)
			end)
		else
			AttackWorld.setTower(plot, index, 0, nil)
			AttackWorld.setDefensePad(plot, index, nil, 0, nil)
		end
		runtime.slotShown[index] = wanted
	end
end

--[[
	Brings one player's runtime, profile levels, plot objects and public attributes in line with
	the authoritative state. Cheap and idempotent; called on every relevant event and once a
	second for everyone (safety net: rebirth, admin edits, plot swaps).
	@param player Player
	@param buyer boolean? — the turret / tower change comes from a purchase (build-in animation)
]]
local function reconcile(player: Player, buyer: boolean?)
	if player.Parent ~= Players then
		return
	end
	local runtime = runtimeOf(player)
	local profile = PlayerDataService.getProfile(player)
	local plot = TycoonBridge.plotIndex(player) or 0
	local t = now()

	-- Plot changed (assigned / released / moved): clear the old plot's objects.
	if runtime.plot ~= plot then
		if runtime.plot > 0 then
			AttackWorld.clearPlot(runtime.plot)
		end
		runtime.plot = plot
		runtime.shieldShown = false
		runtime.shieldUntilShown = 0
		runtime.turretShown = 0
		runtime.promptShown = false
		runtime.towerFreeAt = -math.huge
		for index = 1, DefenseTowers.count() do
			runtime.slotShown[index] = -1
			runtime.slotFreeAt[index] = -math.huge
		end
		runtime.seeded = false
	end

	local hasAA = profile ~= nil and TycoonBridge.hasFeature(profile, AttackConfig.FeatureAA)
	local hasConsole = profile ~= nil and TycoonBridge.hasFeature(profile, AttackConfig.FeatureConsole)
	local changed = false
	if profile ~= nil then
		-- A newly owned Feature pad is level 1 (stored), so the HUD Attack button appears.
		if hasAA and AttackProfile.get(profile, "aa") < 1 then
			AttackProfile.set(profile, "aa", 1)
			changed = true
		end
		if hasConsole and AttackProfile.get(profile, "launcher") < AttackConfig.ConsoleLauncher then
			-- Owner R85: the Console pad grants Launcher L2 at once (everyone starts at L1).
			AttackProfile.set(profile, "launcher", AttackConfig.ConsoleLauncher)
			changed = true
			AttackAnalytics.record(player, "console")
		end
		if changed then
			PlayerDataService.markChanged(player, true, ATTACK_FIELDS)
		end
	end
	runtime.aa = if profile ~= nil then AttackLogic.effectiveLevel(AttackProfile.get(profile, "aa"), hasAA) else 0
	-- Owner R85: everyone has the starter launcher; the Console raises it (AttackLogic.launcherLevel).
	runtime.launcher = if profile ~= nil
		then AttackLogic.launcherLevel(AttackProfile.get(profile, "launcher"), hasConsole)
		else 0
	runtime.console = hasConsole

	local shieldUntil = if profile ~= nil then AttackProfile.get(profile, "shieldUntil") else 0
	local shielded = AttackLogic.shieldActive(shieldUntil, t)

	-- World objects on the plot. The HQ tower's upgrade lives on its in-world UPGRADE billboard
	-- (client DefenseWorld, owner R80) — no separate ProximityPrompt (it shared E / X with Interact).
	if plot > 0 then
		if runtime.turretShown ~= runtime.aa then
			AttackWorld.setTurret(plot, runtime.aa, if buyer == true then player else nil)
			runtime.turretShown = runtime.aa
		end
		if runtime.promptShown ~= hasConsole then
			AttackWorld.setConsolePrompt(plot, if hasConsole then player.UserId else nil)
			runtime.promptShown = hasConsole
		end
		if runtime.shieldShown ~= shielded or (shielded and runtime.shieldUntilShown ~= shieldUntil) then
			AttackWorld.setDome(plot, shielded, shieldUntil)
			runtime.shieldShown = shielded
			runtime.shieldUntilShown = shieldUntil
		end
	end
	-- Public attributes (target picker, other clients' visuals).
	local actor = DefenseService.actorOf(player, t)
	local targetable = (AttackLogic.isTargetable(actor))
	reconcileSlots(player, runtime, profile, plot, buyer == true, targetable)
	if plot > 0 and profile ~= nil then
		runtime.seeded = true
	end
	setAttr(player, ATTR.Targetable, targetable)
	setAttr(player, ATTR.ShieldUntil, if shielded then shieldUntil else 0)
	setAttr(player, ATTR.AALevel, runtime.aa)
	setAttr(player, ATTR.LauncherLevel, runtime.launcher)
	setAttr(player, ATTR.Plot, plot)
	-- Active towers: the HQ Feature tower + every built, unlocked slot (runtime.slots is effective).
	local towerCount = if runtime.aa >= 1 then 1 else 0
	for _, level in runtime.slots do
		if level >= 1 then
			towerCount += 1
		end
	end
	runtime.towerCount = towerCount
	setAttr(player, ATTR.Towers, towerCount)
	-- Owner R50: the built areas the picker draws aim markers for (Knockdown's server truth).
	local builtOk, built = pcall(Knockdown.builtAreas, player)
	setAttr(player, ATTR.Areas, if builtOk and type(built) == "table" then AttackLogic.encodeAreas(built) else "")

	-- Owner R80: the first time this session a player can be nuked with NO tower at all, say how to
	-- defend (the blue pads on their plot). Once per session; never while shielded.
	if targetable and towerCount == 0 and not runtime.warned and not shielded then
		runtime.warned = true
		PlayerDataService.notify(
			player,
			"Other players can nuke you now! Step on the blue pads on your plot to build AA Towers.",
			"info",
			"Shield"
		)
		AttackAnalytics.record(player, "tower:warned")
	end
	DefenseService.Changed:Fire(player)
end
DefenseService.reconcile = reconcile

--------------------------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------------------------

--[[
	The rules' view of a player (AttackLogic.Actor), built from the profile + runtime.
	@param player Player
	@param t number — server time
	@return AttackLogic.Actor
]]
function DefenseService.actorOf(player: Player, _t: number): AttackLogic.Actor
	local profile = PlayerDataService.getProfile(player)
	local runtime = runtimes[player]
	local loaded = profile ~= nil and player.Parent == Players
	return {
		userId = player.UserId,
		loaded = loaded,
		plot = if runtime ~= nil then runtime.plot else 0,
		area = if profile ~= nil then TycoonBridge.area(profile) else 0,
		console = runtime ~= nil and runtime.console,
		launcher = if runtime ~= nil then runtime.launcher else 0,
		cooldownUntil = if profile ~= nil then AttackProfile.get(profile, "cooldownUntil") else 0,
		shieldUntil = if profile ~= nil then AttackProfile.get(profile, "shieldUntil") else 0,
		barrage = if profile ~= nil then AttackProfile.barrage(profile) else 0,
		newbie = isNewbie(profile),
		golden = if profile ~= nil then AttackProfile.golden(profile) else 0,
	}
end

-- Effective (aa, launcher) levels of a player (0, 0 when unknown).
function DefenseService.levels(player: Player): (number, number)
	local runtime = runtimes[player]
	if runtime == nil then
		return 0, 0
	end
	return runtime.aa, runtime.launcher
end

--[[ What one tower did against one nuke (NukeFlight `volleys`, so every client draws it). ]]
export type Volley = {
	tower: number, -- 0 = the HQ / rival / bot turret, 1.. = owner R80 defence slot
	shots: number, -- interceptors it fired
	firstShotAt: number, -- relative fire time of its first interceptor
	reload: number, -- seconds between its shots (its level at launch)
	hit: boolean, -- its LAST shot intercepted the nuke
}

export type Engagement = {
	intercepted: boolean,
	interceptAt: number, -- relative meeting time (0 = not intercepted)
	firstShotAt: number, -- relative fire time of the first interceptor (any tower)
	shots: number, -- interceptors fired at this nuke (every tower together)
	towerFreeAt: number, -- relative time the (single) tower may fire again (rival / bot callers)
	reload: number, -- seconds between shots of the first tower that fired (0 = no shot)
	aa: number, -- the best effective AA level among the towers at launch (0 = no tower)
	volleys: { Volley }, -- one per tower that fired (owner R80), in tower order
	hitTower: number, -- tower id whose shot intercepted (-1 = none)
	towers: number, -- towers that defended (could engage at all, in range or not)
}

-- One tower taking part in an engagement: id, level, muzzle, its next free server time.
type TowerRef = { tower: number, aa: number, muzzle: Vector3, freeAt: number }

-- An engagement where nothing fired.
local function emptyEngagement(aa: number, towers: number): Engagement
	return {
		intercepted = false,
		interceptAt = 0,
		firstShotAt = 0,
		shots = 0,
		towerFreeAt = 0,
		reload = 0,
		aa = aa,
		volleys = {},
		hitTower = -1,
		towers = towers,
	}
end

--[[
	Every listed tower against one nuke (deterministic for the rng): each tower's meeting window
	from its own muzzle and range (FlightMath.engageWindow), then the merged fire-time engagement
	(FlightMath.engageMany — one tower behaves exactly like the classic single-tower engage).
	@param towers { TowerRef }
	@return (Engagement, { [number]: number }) — the engagement and each input tower's new free
	        server time by input position (missing = it did not fire, keep its schedule)
]]
local function engageTowers(
	towers: { TowerRef },
	flight: FlightMath.Flight,
	armor: number,
	t0: number,
	rng: AttackRng.Rng
): (Engagement, { [number]: number })
	local best = 0
	local windows: { FlightMath.TowerWindow } = {}
	local stats: { AttackConfig.AALevel } = {}
	local refs: { TowerRef } = {}
	local positions: { number } = {} -- refs[i] is towers[positions[i]]
	for position, ref in towers do
		local level = AttackLogic.aaStats(ref.aa)
		if level == nil then
			continue
		end
		best = math.max(best, ref.aa)
		local from, to = FlightMath.engageWindow(flight, ref.muzzle, level.range)
		if from == nil or to == nil then
			continue -- this tower never gets the nuke in range (it still defended: `towers`)
		end
		table.insert(windows, {
			windowFrom = from,
			windowTo = to,
			reload = level.reload,
			chance = level.chance,
			towerFreeAt = ref.freeAt - t0,
		})
		table.insert(stats, level)
		table.insert(refs, ref)
		table.insert(positions, position)
	end
	local defended = 0
	for _, ref in towers do
		if AttackLogic.aaStats(ref.aa) ~= nil then
			defended += 1
		end
	end
	local freeAt: { [number]: number } = {}
	if #windows == 0 then
		return emptyEngagement(best, defended), freeAt
	end
	local result = FlightMath.engageMany(windows, armor, rng)
	local engagement = emptyEngagement(best, defended)
	engagement.intercepted = result.intercepted
	engagement.interceptAt = result.interceptAt
	engagement.shots = result.shots
	local first = math.huge
	for index, volley in result.volleys do
		if volley.shots < 1 then
			continue
		end
		local ref = refs[index]
		table.insert(engagement.volleys, {
			tower = ref.tower,
			shots = volley.shots,
			firstShotAt = volley.firstShotAt,
			reload = stats[index].reload,
			hit = result.hitIndex == index,
		})
		if volley.firstShotAt < first then
			first = volley.firstShotAt
			engagement.reload = stats[index].reload
			engagement.towerFreeAt = volley.towerFreeAt
		end
		if result.hitIndex == index then
			engagement.hitTower = ref.tower
		end
		freeAt[positions[index]] = t0 + volley.towerFreeAt
	end
	engagement.firstShotAt = if first == math.huge then 0 else first
	return engagement, freeAt
end

--[[
	One tower's engagement of one nuke (rival islands / admin test bots: one tower each).
	@param aa number — the tower's effective AA level (0 = no tower)
	@param slot number — the tower's target slot (AttackGeometry: plot or rival island)
	@param towerFreeAt number — server time the tower may fire next
	@return (Engagement, number?) — the engagement and the tower's new free time (nil = unchanged)
]]
local function engageTower(
	aa: number,
	slot: number,
	towerFreeAt: number,
	flight: FlightMath.Flight,
	armor: number,
	t0: number,
	rng: AttackRng.Rng
): (Engagement, number?)
	if AttackLogic.aaStats(aa) == nil or AttackGeometry.validTarget(slot) == nil then
		return emptyEngagement(0, 0), nil
	end
	local engagement, freeAt = engageTowers({
		{ tower = 0, aa = aa, muzzle = AttackGeometry.muzzle(slot), freeAt = towerFreeAt },
	}, flight, armor, t0, rng)
	return engagement, freeAt[1]
end

--[[
	Resolves EVERY tower of the target player against one nuke (owner R80): the HQ Feature tower
	(if owned) + each built, unlocked defence slot, each from its own muzzle with its own level and
	fire schedule (FlightMath.engageMany), and advances the schedules of the towers that fired.
	No tower / out of range → not intercepted, 0 shots.
	@param target Player
	@param flight FlightMath.Flight — the nuke's arc (world)
	@param armor number — the attacker's launcher armor
	@param t0 number — the nuke's launch server time
	@param rng AttackRng.Rng — the nuke's seeded generator
	@return Engagement
]]
function DefenseService.engage(
	target: Player,
	flight: FlightMath.Flight,
	armor: number,
	t0: number,
	rng: AttackRng.Rng
): Engagement
	local runtime = runtimes[target]
	if runtime == nil or runtime.plot < 1 then
		return emptyEngagement(0, 0)
	end
	local plot = runtime.plot
	local towers: { TowerRef } = {}
	if runtime.aa >= 1 then
		table.insert(
			towers,
			{ tower = 0, aa = runtime.aa, muzzle = AttackGeometry.muzzle(plot), freeAt = runtime.towerFreeAt }
		)
	end
	for index, level in runtime.slots do
		if level >= 1 then
			table.insert(towers, {
				tower = index,
				aa = level,
				muzzle = AttackGeometry.muzzle(plot, index),
				freeAt = runtime.slotFreeAt[index],
			})
		end
	end
	local engagement, freeAt = engageTowers(towers, flight, armor, t0, rng)
	for position, ref in towers do
		local value = freeAt[position]
		if value ~= nil then
			if ref.tower == 0 then
				runtime.towerFreeAt = value
			else
				runtime.slotFreeAt[ref.tower] = value
			end
		end
	end
	return engagement
end

--[[
	Resolves Rival Factory `index`'s AA tower (its config level) against one nuke and advances its
	fire schedule — one schedule shared by every attacker, exactly like a player's tower.
	@param index number — rival index (1..#Rivals.List)
	@return Engagement
	Example: DefenseService.engageRival(2, flight, armor, t0, rng).intercepted
]]
function DefenseService.engageRival(
	index: number,
	flight: FlightMath.Flight,
	armor: number,
	t0: number,
	rng: AttackRng.Rng
): Engagement
	local rival = AttackLogic.rival(index)
	local runtime = rivalRuntimes[index]
	local aa = if rival ~= nil and runtime ~= nil then rival.aa else 0
	local engagement, freeAt = engageTower(
		aa,
		AttackGeometry.rivalSlot(index),
		if runtime ~= nil then runtime.towerFreeAt else -math.huge,
		flight,
		armor,
		t0,
		rng
	)
	if runtime ~= nil and freeAt ~= nil then
		runtime.towerFreeAt = freeAt
	end
	return engagement
end

--[[
	Resolves an admin test bot's AA tower (owner R51; Server/Attack/TestBots) against one nuke, with
	the same engagement as a player tower, and advances the bot's fire schedule.
	@param bot { aa: number, plotIndex: number, towerFreeAt: number } — a TestBots.Bot
	@return Engagement
]]
function DefenseService.engageBot(
	bot: { aa: number, plotIndex: number, towerFreeAt: number },
	flight: FlightMath.Flight,
	armor: number,
	t0: number,
	rng: AttackRng.Rng
): Engagement
	local engagement, freeAt = engageTower(bot.aa, bot.plotIndex, bot.towerFreeAt, flight, armor, t0, rng)
	if freeAt ~= nil then
		bot.towerFreeAt = freeAt
	end
	return engagement
end

--[[
	Counts a hit on `target` toward the free shield (capped at FreeShieldHits).
	@param target Player
	@return boolean — true when this hit made the free shield ready
]]
function DefenseService.recordHit(target: Player): boolean
	local profile = PlayerDataService.getProfile(target)
	if profile == nil then
		return false
	end
	local before = AttackProfile.get(profile, "hitsTaken")
	if before >= AttackConfig.FreeShieldHits then
		return false
	end
	AttackProfile.set(profile, "hitsTaken", before + 1)
	PlayerDataService.markChanged(target, false, ATTACK_FIELDS)
	return before + 1 >= AttackConfig.FreeShieldHits
end

--[[
	Adds shield time (product, free shield, admin) and shows the dome. Never yields (the dome is
	built deferred), so receipt handlers may call it.
	@param player Player
	@param seconds number
	@param source "free" | "product" | "admin"
	@return number — the new shieldUntil (0 when the profile is not loaded)
]]
function DefenseService.addShield(player: Player, seconds: number, source: string): number
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return 0
	end
	local untilTime = AttackLogic.addShield(AttackProfile.get(profile, "shieldUntil"), now(), seconds)
	AttackProfile.set(profile, "shieldUntil", untilTime)
	PlayerDataService.markChanged(player, true, ATTACK_FIELDS)
	if source == "free" or source == "product" then
		AttackAnalytics.record(player, `shield:{source}`)
	end
	task.defer(function()
		reconcile(player)
	end)
	return untilTime
end

--[[ Removes a player's shield (admin). ]]
function DefenseService.clearShield(player: Player)
	local profile = PlayerDataService.getProfile(player)
	if profile ~= nil then
		AttackProfile.set(profile, "shieldUntil", 0)
		PlayerDataService.markChanged(player, true, ATTACK_FIELDS)
		task.defer(function()
			reconcile(player)
		end)
	end
end

--[[
	Admin / test: sets stored levels (clamped 0..MaxLevel) and re-applies them.
	@param player Player, aa number?, launcher number?
]]
function DefenseService.setLevels(player: Player, aa: number?, launcher: number?)
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return
	end
	if aa ~= nil then
		AttackProfile.set(profile, "aa", math.clamp(aa, 0, AttackConfig.MaxLevel))
	end
	if launcher ~= nil then
		AttackProfile.set(profile, "launcher", math.clamp(launcher, 0, AttackConfig.MaxLevel))
	end
	PlayerDataService.markChanged(player, true, ATTACK_FIELDS)
	reconcile(player, true)
end

--[[
	Admin / QA (owner R80): sets the stored level of one defence tower slot (clamped 0..MaxLevel;
	0 = not bought, so the BUY pad shows again — admin only, gameplay never lowers a level) and
	re-applies it with the build-in.
	@param player Player
	@param index number — 1..DefenseTowers.count()
	@param level number
	@return boolean — false when the profile is not loaded / the slot is invalid
	Example: DefenseService.setTowerLevel(player, 2, 5)
]]
function DefenseService.setTowerLevel(player: Player, index: number, level: number): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not AttackProfile.setTowerLevel(profile, index, level) then
		return false
	end
	PlayerDataService.markChanged(player, true, ATTACK_FIELDS)
	AttackAnalytics.record(player, "tower:admin")
	reconcile(player, true)
	return true
end

--[[
	Admin / QA (owner R80): sets EVERY defence tower slot to `level` (0..MaxLevel).
	@return boolean — false when the profile is not loaded
]]
function DefenseService.setAllTowers(player: Player, level: number): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false
	end
	for index = 1, DefenseTowers.count() do
		AttackProfile.setTowerLevel(profile, index, level)
	end
	PlayerDataService.markChanged(player, true, ATTACK_FIELDS)
	AttackAnalytics.record(player, "tower:admin")
	reconcile(player, true)
	return true
end

--[[ Owner R85: the new-player grace seconds on this server. ]]
function DefenseService.graceSeconds(): number
	return graceSeconds
end

--[[
	Owner R85 admin (AttackGrace command): the new-player grace seconds on this server, live
	(clamped 0..NewPlayer.MaxGraceSeconds); every player is re-evaluated at once.
	@param seconds number
]]
function DefenseService.setGraceSeconds(seconds: number)
	graceSeconds = math.clamp(math.floor(seconds), 0, AttackConfig.NewPlayer.MaxGraceSeconds)
	for _, player in Players:GetPlayers() do
		task.defer(function()
			reconcile(player)
		end)
	end
end

--[[ True while defence tower buys / upgrades are accepted on this server (owner R80 kill switch). ]]
function DefenseService.towersEnabled(): boolean
	return towersOn
end

--[[
	Admin kill switch (AttackTowerShop command, owner R80): defence tower buys / upgrades on / off
	on this server (e.g. while a price bug is fixed). Owned towers keep defending either way.
	@param on boolean
]]
function DefenseService.setTowersEnabled(on: boolean)
	towersOn = on == true
end

--[[
	Active towers defending a player (HQ + built slots; 0 when unknown) — analytics / admin.
	@param player Player
	@return number
]]
function DefenseService.towerCount(player: Player): number
	local runtime = runtimes[player]
	return if runtime ~= nil then runtime.towerCount else 0
end

--------------------------------------------------------------------------------------------------
-- Rival Factories (owner R43)
--------------------------------------------------------------------------------------------------

--[[ True while Rival Factories accept launches on this server (admin kill switch). ]]
function DefenseService.rivalsEnabled(): boolean
	return rivalsOn
end

--[[
	Brings the Rival Factory islands' world objects in line with their state: the levelled turret
	(once its island folder exists) and the shield dome of each rival's deterministic cycle (no
	dome while the admin switched rivals off). Cheap; change-only; called by the 1 Hz pass.
]]
local function reconcileRivals()
	local t = now()
	for index, rival in AttackConfig.Rivals.List do
		local runtime = rivalRuntimes[index]
		local slot = AttackGeometry.rivalSlot(index)
		if runtime.turretShown ~= rival.aa then
			AttackWorld.setTurret(slot, rival.aa, nil)
			runtime.turretShown = rival.aa
		end
		local shieldUntil = if rivalsOn then AttackLogic.rivalShieldUntil(index, t) else 0
		local shielded = shieldUntil > t
		if runtime.shieldShown ~= shielded or (shielded and runtime.shieldUntilShown ~= shieldUntil) then
			AttackWorld.setDome(slot, shielded, shieldUntil)
			runtime.shieldShown = shielded
			runtime.shieldUntilShown = shieldUntil
		end
	end
end

--[[
	Admin kill switch (AttackRivals command): turns Rival Factory targets on / off on this server.
	Off: launches at rivals are refused ("target"), the picker hides them (ReplicatedStorage
	attribute Attr.RivalsOn), their domes drop; the islands stay as scenery.
	@param on boolean
]]
function DefenseService.setRivalsEnabled(on: boolean)
	rivalsOn = on == true
	ReplicatedStorage:SetAttribute(ATTR.RivalsOn, rivalsOn)
	reconcileRivals()
end

--------------------------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------------------------

-- DefenseUpgrade(kind, toLevel?): buy the next AA / Launcher level with cash. `toLevel` (optional,
-- owner R80 idempotency: the in-world UPGRADE billboard sends it) must be the stored level + 1, so
-- a repeated tap never buys two levels. Connected through Remotes.onServerEvent, so a late event
-- from a departed player never re-creates a limiter bucket.
local function onUpgrade(player: Player, rawKind: unknown, rawToLevel: unknown)
	if not upgradeLimiter:Allow(player) then
		return
	end
	local kind = Validate.oneOf(rawKind, AttackConfig.UpgradeKinds :: { string })
	if kind == nil then
		return
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return
	end
	local feature = FEATURE_OF[kind]
	if not TycoonBridge.hasFeature(profile, feature) then
		local pad = if kind == "aa" then "AA Tower" else "Attack Console"
		PlayerDataService.notify(player, `Build the {pad} pad in Launch Silos first!`, "error")
		return
	end
	-- Owner R85: the launcher counts from ConsoleLauncher once the Console is owned.
	local current = if kind == "launcher"
		then AttackLogic.launcherLevel(AttackProfile.get(profile, kind), true)
		else AttackLogic.effectiveLevel(AttackProfile.get(profile, kind), true)
	if rawToLevel ~= nil and DefenseTowers.validLevel(rawToLevel) ~= current + 1 then
		-- A stale / repeated intent (already bought): show the truth instead of buying again.
		PlayerDataService.refresh(player, ATTACK_FIELDS)
		return
	end
	local cost = AttackLogic.upgradeCost(current, TycoonBridge.featurePrice(feature))
	if cost == math.huge then
		PlayerDataService.notify(player, "Already at max level!", "info")
		return
	end
	if not PlayerDataService.trySpendCash(player, cost, "attack_upgrade") then
		PlayerDataService.notify(player, `Need {NumberFormat.money(cost)} for the next level!`, "error")
		PlayerDataService.refresh(player, { "cash" })
		return
	end
	AttackProfile.set(profile, kind, current + 1)
	PlayerDataService.markChanged(player, true, ATTACK_FIELDS)
	AttackAnalytics.record(player, `aa:{kind}:{current + 1}`)
	local label = if kind == "aa" then "AA Tower" else "Launcher"
	PlayerDataService.notify(player, `{label} upgraded to level {current + 1}!`, "success")
	reconcile(player, true)
end

-- A refused DefenseTower intent's analytics label (AnalyticsConfig.Metrics.attack "tower:refused").
local REFUSED_LABEL: { [string]: string } = {
	slot = "other",
	locked = "locked",
	level = "level",
	max = "max",
	price = "other",
}

--[[
	Buys (toLevel 1) or upgrades defence tower slot `index` to `toLevel` for cash (owner R80). The
	one path of every source: the DefenseTower remote (Defense window, billboards, E / X, the touch
	button) and walking onto the BUY pad. DefenseTowers.plan decides (slot unlocked, not maxed,
	toLevel == stored + 1, server price), trySpendCash spends atomically, then the tower builds in.
	@param player Player
	@param index number — slot (already validated)
	@param toLevel number — already validated 1..MaxLevel
	@param source string — "remote" | "walk" (analytics + toast throttling). Rate limits are the
	                callers': the remote's token bucket, the pad's per-player TouchDebounce.
]]
tryTower = function(player: Player, index: number, toLevel: number, source: string)
	local profile = PlayerDataService.getProfile(player)
	local runtime = runtimes[player]
	if profile == nil or runtime == nil or runtime.plot < 1 then
		return
	end
	local slot = DefenseTowers.slot(index)
	if slot == nil then
		return
	end
	if not towersOn then
		PlayerDataService.notify(player, "Defence towers are switched off on this server for a moment.", "info")
		AttackAnalytics.record(player, "tower:refused:off")
		return
	end
	-- Owner R85: nothing to buy while the player is still protected (area 0 = no slot unlocked).
	local targetable = AttackLogic.isTargetable(DefenseService.actorOf(player, now()))
	local ok, cost, reason = DefenseTowers.plan(
		AttackProfile.towers(profile),
		DefenseTowers.areaFor(TycoonBridge.area(profile), targetable),
		index,
		toLevel
	)
	if not ok then
		AttackAnalytics.record(player, `tower:refused:{REFUSED_LABEL[reason or "slot"] or "other"}`)
		if reason == "locked" then
			local text = if targetable
				then `Reach area {slot.unlockArea} to build the {slot.name}!`
				else "You're still new - nobody can nuke you yet!"
			PlayerDataService.notify(player, text, "info")
		elseif reason == "max" then
			PlayerDataService.notify(player, `{slot.name} is already max level!`, "info")
		else
			-- A stale / repeated intent (the level was already bought): resync instead of buying twice.
			PlayerDataService.refresh(player, ATTACK_FIELDS)
		end
		return
	end
	if not PlayerDataService.trySpendCash(player, cost, "defense_tower") then
		AttackAnalytics.record(player, "tower:refused:cash")
		local clock = os.clock()
		-- Walking around on the pad fires Touched again and again: one toast per NoticeSeconds.
		if source ~= "walk" or clock - (noticeAt[player] or -math.huge) >= TOWERS.NoticeSeconds then
			noticeAt[player] = clock
			local verb = if toLevel == 1 then "build" else "upgrade"
			PlayerDataService.notify(player, `Need {NumberFormat.money(cost)} to {verb} the {slot.name}!`, "error")
		end
		PlayerDataService.refresh(player, { "cash" })
		return
	end
	AttackProfile.setTowerLevel(profile, index, toLevel)
	PlayerDataService.markChanged(player, true, ATTACK_FIELDS)
	if toLevel == 1 then
		AttackAnalytics.record(player, `tower:buy:{index}`)
		AttackAnalytics.record(player, `tower:src:{if source == "walk" then "walk" else "remote"}`)
		PlayerDataService.notify(player, `{slot.name} built! It shoots down incoming nukes.`, "success", "Shield")
	else
		AttackAnalytics.record(player, `tower:up:{index}:{toLevel}`)
		PlayerDataService.notify(player, `{slot.name} upgraded to level {toLevel}!`, "success", "Shield")
	end
	reconcile(player, true)
end

-- DefenseTower(slot, toLevel): owner R80 defence tower buy / upgrade intent. typeof + allowlist
-- validation here, everything else in tryTower. (Connected through Remotes.onServerEvent.)
local function onTower(player: Player, rawSlot: unknown, rawToLevel: unknown)
	if not towerLimiter:Allow(player) then
		AttackAnalytics.record(player, "tower:refused:rate")
		return
	end
	local index = DefenseTowers.validSlot(rawSlot)
	local toLevel = DefenseTowers.validLevel(rawToLevel)
	if index == nil or toLevel == nil then
		return
	end
	tryTower(player, index, toLevel, "remote")
end

-- ShieldActivate(): turn on the earned free shield (FreeShieldHits hits taken).
-- (Connected through Remotes.onServerEvent: late events from departed players are dropped.)
local function onShield(player: Player)
	if not shieldLimiter:Allow(player) then
		return
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return
	end
	if not AttackLogic.freeShieldReady(AttackProfile.get(profile, "hitsTaken")) then
		PlayerDataService.notify(player, `Get hit {AttackConfig.FreeShieldHits} times to earn a free shield!`, "info")
		return
	end
	-- Same 48 h cap as the paid shield (refuseShield); the earned hits are kept for later.
	if not AttackLogic.freeShieldFits(AttackProfile.get(profile, "shieldUntil"), now()) then
		PlayerDataService.notify(player, "Your shield is already full! Save the free one for later.", "info")
		return
	end
	AttackProfile.set(profile, "hitsTaken", 0)
	DefenseService.addShield(player, AttackConfig.FreeShieldSeconds, "free")
	-- Revenge strikes ignore shields by design (AttackLogic.canLaunch), so say so.
	PlayerDataService.notify(
		player,
		`Shield bubble ON for {math.floor(AttackConfig.FreeShieldSeconds / 60)} minutes! Nukes bounce off (Revenge strikes still land).`,
		"success",
		"Shield"
	)
end

--------------------------------------------------------------------------------------------------
-- Products
--------------------------------------------------------------------------------------------------

-- "Shield" product (Shield1h): adds durationSeconds. Never yields.
local function grantShield(player: Player, profile: any, product: any, _receipt: any): boolean
	local seconds = product.durationSeconds
	if type(seconds) ~= "number" or seconds <= 0 then
		return false
	end
	local untilTime = AttackLogic.addShield(AttackProfile.get(profile, "shieldUntil"), now(), seconds)
	AttackProfile.set(profile, "shieldUntil", untilTime)
	AttackAnalytics.record(player, "shield:product")
	task.defer(function()
		if player.Parent == Players then
			PlayerDataService.markChanged(player, true, ATTACK_FIELDS)
			reconcile(player)
		end
	end)
	return true
end

-- Prompt refusal: the shield would pass MaxShieldSeconds.
local function refuseShield(player: Player, product: any): string?
	local profile = PlayerDataService.getProfile(player)
	local seconds = if type(product.durationSeconds) == "number" then product.durationSeconds else 0
	if profile ~= nil then
		local remaining = AttackLogic.shieldRemaining(AttackProfile.get(profile, "shieldUntil"), now())
		if remaining + seconds > AttackConfig.MaxShieldSeconds then
			return "Your shield is already full!"
		end
	end
	return nil
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

function DefenseService.Init()
	MonetizationService.registerProductHandler("Shield", grantShield)
	MonetizationService.registerPromptRefusal("Shield", refuseShield)
end

function DefenseService.Start()
	AttackWorld.publishTemplates()
	AttackAnalytics.registerKinds()
	-- Rival Factory islands (owner R43): folders now, meshes in the background (Idle priority).
	ReplicatedStorage:SetAttribute(ATTR.RivalsOn, rivalsOn)
	RivalIslands.start()
	reconcileRivals()

	-- onServerEvent drops late events from departed players (security audit: no limiter bucket or
	-- runtime is re-created after PlayerRemoving).
	Remotes.onServerEvent("DefenseUpgrade", onUpgrade)
	Remotes.onServerEvent("DefenseTower", onTower)
	Remotes.onServerEvent("ShieldActivate", onShield)

	PlayerDataService.ProfileLoaded:Connect(function(player: Player)
		reconcile(player)
	end)
	TycoonBridge.PlotAssigned:Connect(function(player: Player)
		reconcile(player)
	end)
	TycoonBridge.PlotReleased:Connect(function(player: Player, index: number)
		AttackWorld.clearPlot(index)
		local runtime = runtimes[player]
		if runtime ~= nil then
			runtime.plot = 0
			runtime.turretShown = 0
			runtime.promptShown = false
			runtime.shieldShown = false
			runtime.shieldUntilShown = 0
			for slot = 1, DefenseTowers.count() do
				runtime.slotShown[slot] = -1
			end
			runtime.seeded = false
		end
	end)
	TycoonBridge.PadBought:Connect(function(player: Player, padId: string)
		if
			padId == TycoonBridge.featurePad(AttackConfig.FeatureAA)
			or padId == TycoonBridge.featurePad(AttackConfig.FeatureConsole)
		then
			reconcile(player, true)
		else
			-- Owner R80: an Unlock pad may open a tower slot's area — show its BUY pad at once (not
			-- up to a second later). Change-only and cheap; no build-in flag (pads just appear).
			reconcile(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		local runtime = runtimes[player]
		if runtime ~= nil and runtime.plot > 0 then
			AttackWorld.clearPlot(runtime.plot)
		end
		runtimes[player] = nil
		upgradeLimiter:Forget(player)
		shieldLimiter:Forget(player)
		towerLimiter:Forget(player)
		touchAt[player] = nil
		noticeAt[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			reconcile(player)
		end)
	end

	-- 1 Hz safety pass: shield expiry, rebirth / admin edits, the rivals' shield cycles.
	task.spawn(function()
		while true do
			task.wait(1)
			local rivalsOk, rivalsErr = pcall(reconcileRivals)
			if not rivalsOk then
				warn(`[DefenseService] rival reconcile failed: {rivalsErr}`)
			end
			for _, player in Players:GetPlayers() do
				if PlayerDataService.getProfile(player) ~= nil then
					local ok, err = pcall(function()
						reconcile(player)
					end)
					if not ok then
						warn(`[DefenseService] reconcile failed for {player.UserId}: {err}`)
					end
				end
			end
		end
	end)
end

return DefenseService
