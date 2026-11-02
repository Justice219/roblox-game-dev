--!strict
--[[
	AttackClient — the client side of Attack mode (spec §9): flight intake, Revenge tracking,
	target lists, intents, the HUD Attack button, console prompts and shield domes.

	What it does
		* NukeFlight (server → every client, once per nuke): validated defensively, then handed to
		  FlightRenderer, which draws the arc / trail / interceptors / explosion locally.
		* Revenge: a nuke that HITS the local player (toUserId = me, not intercepted, a real
		  attacker) gives a free Revenge launch against that attacker from impact time for
		  RevengeSeconds — the same rule the server applies, so the REVENGE chip matches the token
		  the server holds (the server re-checks; a stale chip is simply refused).
		* Targets: other players' public attack attributes (AttackConfig.Attr, set by DefenseService)
		  + B3's TycoonArea / IncomePerSecond attributes, plus the Rival Factories (owner R43; their
		  shield cycle is computed locally from the shared clock, AttackLogic.rivalShieldUntil) →
		  the target picker list: eligible players, then ineligible players greyed with a reason,
		  then the rivals — never empty while the rivals are on.
		* Intents: launch(id, kind) → AttackLaunch (id = userId or rival id); upgrade(kind, toLevel?) →
		  DefenseUpgrade; buildTower(slot, toLevel) → DefenseTower (owner R80 defence slots);
		  activateShield() → ShieldActivate; buy(productKey) → PromptProduct. A Barrage bought
		  from the picker is sent automatically when its PurchaseGranted arrives.
		* HUD: the Attack button is visible while the player can be nuked (owner R80: the route to
		  the Defense window — the picker's DEFEND button), owns the Attack Console / an AA tower or
		  holds a Revenge token; its badge shows "!" for Revenge / a ready free shield / being
		  targetable with no AA tower at all.
		* World: the Attack Console prompt ("Launch Nukes!" → picker) is enabled only on the local
		  player's own plot; Client/Attack/DefenseWorld (started here) draws the in-world defence
		  BUY pads' prices and the towers' UPGRADE billboards (owner R80); shield domes pop in
		  (skipped with Reduce Motion).

	Trust: every server value is type-checked and clamped; nothing here decides an outcome.
	Performance: event-driven; no per-frame work here (FlightRenderer owns the one render loop).

	Boot: AttackClient.start() — idempotent; called by the AttackHud screen (auto-open, discovered
	by UIController) and safe to call from a controller list too.

	Connects to: Shared/Config/AttackConfig, Shared/Attack/AttackLogic, Shared/Net/Remotes,
	Client/ClientState, Client/Attack/{FlightRenderer, AttackFx}, UI/{ScreenManager, Hud/Hud},
	Screens/AttackTarget/*, Screens/Defense/*.

	Example:
		AttackClient.start()
		for _, target in AttackClient.targets() do print(target.name, target.status) end
		AttackClient.launch(target.id, "normal")   -- a userId, or a rival id like "toy_factory"
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local AttackLogic = require(ReplicatedStorage.Shared.Attack.AttackLogic)
local ClientState = require(script.Parent.Parent.ClientState)
local DefenseTowers = require(ReplicatedStorage.Shared.Attack.DefenseTowers)
local DefenseWorld = require(script.Parent.DefenseWorld)
local FlightRenderer = require(script.Parent.FlightRenderer)
local LaunchCam = require(script.Parent.LaunchCam)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local AttackClient = {}

local ATTR = AttackConfig.Attr
local LOCAL = Players.LocalPlayer
-- Purchase prompt source of every attack offer (PurchasePromptConfig.Sources; owner R122: the
-- attack prompts were unattributed before).
local PROMPT_SOURCE = "attack"

export type Status = "ready" | "shield" | "protected" | "revenge"

--[[
	One picker entry: another player, or a Rival Factory (owner R43 NPC target). `key` is the
	stable selection key ("p<userId>" / "r<rivalId>"); `id` is what AttackLaunch carries.
]]
export type Target = {
	key: string,
	id: number | string, -- the player's userId, or the rival id
	player: Player?, -- nil for a Rival Factory
	rival: number?, -- rival index (AttackConfig.Rivals.List), nil for a player
	bot: string?, -- owner R51: an admin test bot's key ("bot:3"); listed for admins only
	areas: { number }, -- owner R50: the aimable areas (built areas / rival sections), ascending
	userId: number, -- 0 for a rival
	name: string,
	plot: number, -- AttackGeometry target slot (a plot, or the rival's island slot)
	area: number,
	aa: number,
	towers: number, -- owner R80: AA towers defending it (HQ + defence slots; rivals / bots: 1 if aa > 0)
	launcher: number,
	income: number, -- the player's $/s (0 for a rival)
	reward: number, -- a rival: what one normal hit pays me right now (display); 0 for players
	shieldUntil: number,
	targetable: boolean,
	revengeUntil: number, -- server time the local Revenge token expires (0 = none)
	status: Status,
	reason: string?, -- why a player is greyed out (protected), nil otherwise
}

export type MyState = {
	console: boolean,
	launcher: number, -- effective
	aa: number, -- effective
	storedAA: number,
	storedLauncher: number,
	cooldownUntil: number,
	shieldUntil: number,
	hitsTaken: number,
	barrage: number,
	plot: number,
	-- Owner R80 defence towers:
	towers: { number }, -- stored level per defence slot (dense, DefenseTowers.count() entries)
	towerCount: number, -- active towers defending me (HQ + built slots; server attribute)
	targetable: boolean, -- other players can nuke me right now (server attribute)
	area: number, -- my highest unlocked Nuke Town area (slot unlocks)
	golden: number, -- owner R85: stored golden revenge nukes
}

-- Fires when Revenge tokens change (gained / used / expired).
AttackClient.RevengeChanged = Signal.new() :: Signal.Signal<>
-- Fires when anything the attack UI shows may have changed (profile, attributes, tokens).
AttackClient.Changed = Signal.new() :: Signal.Signal<>

-- revenge[attackerUserId] = { from = server time usable, until = server time expiry }
-- (keyed by the attacker's userId, or an admin test bot's key "bot:3")
local revenge: { [number | string]: { from: number, untilTime: number } } = {}
local started = false
local lastLaunch = 0
local pendingBarrageTarget: (number | string)? = nil
local pendingBarrageArea = 0
local changedQueued = false

-- A finite number, else `fallback`.
local function num(value: unknown, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- Coalesces Changed to once per frame.
local function queueChanged()
	if changedQueued then
		return
	end
	changedQueued = true
	task.defer(function()
		changedQueued = false
		AttackClient.Changed:Fire()
	end)
end

--------------------------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------------------------

--[[
	The local player's attack state (profile + own attributes). Display only.
	@return MyState
]]
function AttackClient.myState(): MyState
	local profile: any = ClientState.profile
	local attack = if type(profile) == "table" and type(profile.attack) == "table" then profile.attack else {}
	return {
		console = num(LOCAL:GetAttribute(ATTR.LauncherLevel), 0) > 0,
		launcher = math.floor(num(LOCAL:GetAttribute(ATTR.LauncherLevel), 0)),
		aa = math.floor(num(LOCAL:GetAttribute(ATTR.AALevel), 0)),
		storedAA = math.floor(num(attack.aa, 0)),
		storedLauncher = math.floor(num(attack.launcher, 0)),
		cooldownUntil = num(attack.cooldownUntil, 0),
		shieldUntil = num(attack.shieldUntil, 0),
		hitsTaken = math.floor(num(attack.hitsTaken, 0)),
		barrage = math.max(math.floor(num(attack.barrage, 0)), 0),
		plot = math.floor(num(LOCAL:GetAttribute(ATTR.Plot), 0)),
		towers = DefenseTowers.normalize(attack.towers),
		towerCount = math.floor(num(LOCAL:GetAttribute(ATTR.Towers), 0)),
		targetable = LOCAL:GetAttribute(ATTR.Targetable) == true,
		area = AttackClient.myArea(),
		golden = math.max(math.floor(num(attack.golden, 0)), 0),
	}
end

--[[
	My highest unlocked Nuke Town area: the synced profile's tycoon.area, else B3's TycoonArea
	attribute (0 before either arrives). Display only (defence slot unlocks).
]]
function AttackClient.myArea(): number
	local profile: any = ClientState.profile
	local tycoon = if type(profile) == "table" then profile.tycoon else nil
	local fromProfile = if type(tycoon) == "table" then num(tycoon.area, 0) else 0
	return math.floor(math.max(fromProfile, num(LOCAL:GetAttribute("TycoonArea"), 0)))
end

--[[
	Owner R80: true when I can be nuked and an AA tower would help right now — no tower at all, or
	an unlocked defence slot not bought yet that I can afford (HUD "!" badge, the picker's DEFEND
	button). Display only.
]]
function AttackClient.defenceAlert(): boolean
	local me = AttackClient.myState()
	if not me.targetable then
		return false
	end
	if me.towerCount == 0 then
		return true
	end
	local profile: any = ClientState.profile
	local wallet = if type(profile) == "table" then num(profile.cash, 0) else 0
	local slot, cost = DefenseTowers.cheapestOpen(me.towers, DefenseTowers.areaFor(me.area, me.targetable))
	return slot ~= nil and wallet >= cost
end

--[[
	The live Revenge expiry against an attacker (0 when none usable now).
	@param key number | string — the attacker's userId, or a test bot's key
	@return number — server time
]]
function AttackClient.revengeUntil(key: number | string): number
	local token = revenge[key]
	local t = serverNow()
	if token == nil or token.untilTime <= t or token.from > t then
		return 0
	end
	return token.untilTime
end

--[[
	The newest usable Revenge token: (attacker Player, expiry) or nil.
	@return (Player?, number)
]]
function AttackClient.latestRevenge(): (Player?, number)
	local bestPlayer: Player? = nil
	local bestUntil = 0
	for key in revenge do
		-- Players only (the HUD chip); test-bot tokens are used from the picker.
		local userId = if type(key) == "number" then key else nil
		local untilTime = if userId ~= nil then AttackClient.revengeUntil(userId) else 0
		if userId ~= nil and untilTime > bestUntil then
			local player = Players:GetPlayerByUserId(userId)
			if player ~= nil then
				bestPlayer, bestUntil = player, untilTime
			end
		end
	end
	return bestPlayer, bestUntil
end

-- The picker key of a player ("p<userId>"); REVENGE chips open the picker with it.
function AttackClient.playerKey(userId: number): string
	return `p{userId}`
end

-- True while the server offers Rival Factories (admin kill switch attribute; missing = on).
function AttackClient.rivalsOn(): boolean
	return ReplicatedStorage:GetAttribute(ATTR.RivalsOn) ~= false
end

-- True when the local player owns a game pass (profile cache; display only).
local function ownsPass(key: string): boolean
	local profile: any = ClientState.profile
	return type(profile) == "table" and type(profile.passes) == "table" and profile.passes[key] == true
end

-- Builds the picker view of one other player (greyed with a reason when not targetable).
local function targetOf(player: Player): Target
	local t = serverNow()
	local shieldUntil = num(player:GetAttribute(ATTR.ShieldUntil), 0)
	local targetable = player:GetAttribute(ATTR.Targetable) == true
	local revengeUntil = AttackClient.revengeUntil(player.UserId)
	local area = math.floor(num(player:GetAttribute("TycoonArea"), 0))
	local status: Status = if revengeUntil > 0
		then "revenge"
		elseif not targetable then "protected"
		elseif shieldUntil > t then "shield"
		else "ready"
	local reason: string? = nil
	if status == "protected" then
		-- Owner R85: only brand-new players are protected (tutorial + a short grace).
		reason = "Still new - protected for a few minutes"
	end
	return {
		key = AttackClient.playerKey(player.UserId),
		id = player.UserId,
		player = player,
		rival = nil,
		bot = nil,
		areas = AttackLogic.decodeAreas(player:GetAttribute(ATTR.Areas)),
		userId = player.UserId,
		name = player.DisplayName,
		plot = math.floor(num(player:GetAttribute(ATTR.Plot), 0)),
		area = area,
		aa = math.floor(num(player:GetAttribute(ATTR.AALevel), 0)),
		towers = math.floor(num(player:GetAttribute(ATTR.Towers), 0)),
		launcher = math.floor(num(player:GetAttribute(ATTR.LauncherLevel), 0)),
		income = math.max(num(player:GetAttribute("IncomePerSecond"), 0), 0),
		reward = 0,
		shieldUntil = shieldUntil,
		targetable = targetable,
		revengeUntil = revengeUntil,
		status = status,
		reason = reason,
	}
end

-- Every Rival section index (a Rival Factory's aimable "areas", owner R50).
local RIVAL_SECTIONS: { number } = {}
for index in AttackConfig.Rivals.Sections do
	table.insert(RIVAL_SECTIONS, index)
end

-- True when the local player is an owner admin (the server-set IsAdmin mirror; the server re-checks).
local function localIsAdmin(): boolean
	return LOCAL:GetAttribute("IsAdmin") == true
end

-- The public mirror folder of the admin test bots (owner R51), or nil.
local function botFolder(): Instance?
	return ReplicatedStorage:FindFirstChild(AttackConfig.Bots.Folder)
end

-- Builds the picker view of an admin test bot from its mirror (nil when malformed).
local function botTarget(mirror: Instance): Target?
	local key = mirror:GetAttribute("Key")
	local plot = mirror:GetAttribute("Plot")
	if type(key) ~= "string" or #key > 16 or type(plot) ~= "number" then
		return nil
	end
	local t = serverNow()
	local shieldUntil = num(mirror:GetAttribute("ShieldUntil"), 0)
	local revengeUntil = AttackClient.revengeUntil(key)
	local name = mirror:GetAttribute("Name")
	return {
		key = `b{key}`,
		id = key,
		player = nil,
		rival = nil,
		bot = key,
		areas = AttackLogic.decodeAreas(mirror:GetAttribute("Areas")),
		userId = 0,
		name = if type(name) == "string" then string.sub(name, 1, 32) else "TestBot",
		plot = math.floor(plot),
		area = math.floor(num(mirror:GetAttribute("Area"), 0)),
		aa = math.floor(num(mirror:GetAttribute("AA"), 0)),
		towers = if num(mirror:GetAttribute("AA"), 0) > 0 then 1 else 0,
		launcher = 0,
		income = 0,
		reward = 0,
		shieldUntil = shieldUntil,
		targetable = true,
		revengeUntil = revengeUntil,
		status = if revengeUntil > 0 then "revenge" elseif shieldUntil > t then "shield" else "ready",
		reason = nil,
	}
end

-- Builds the picker view of Rival Factory `index` (always targetable; shielded per its cycle).
local function rivalTarget(index: number): Target
	local rival = AttackConfig.Rivals.List[index]
	local t = serverNow()
	local shieldUntil = AttackLogic.rivalShieldUntil(index, t)
	local myLauncher = math.max(math.floor(num(LOCAL:GetAttribute(ATTR.LauncherLevel), 0)), 1)
	local myIncome = math.max(num(LOCAL:GetAttribute("IncomePerSecond"), 0), 0)
	return {
		key = `r{rival.id}`,
		id = rival.id,
		player = nil,
		rival = index,
		bot = nil,
		areas = RIVAL_SECTIONS,
		userId = 0,
		name = rival.name,
		plot = AttackGeometry.rivalSlot(index),
		area = AttackConfig.UnlockArea,
		aa = rival.aa,
		towers = if rival.aa > 0 then 1 else 0,
		launcher = 0,
		income = 0,
		reward = AttackLogic.rivalReward(
			"normal",
			myLauncher,
			index,
			myIncome,
			ownsPass(AttackConfig.Reward.MegaLauncherPass)
		),
		shieldUntil = shieldUntil,
		targetable = true,
		revengeUntil = 0,
		status = if shieldUntil > t then "shield" else "ready",
		reason = nil,
	}
end

--[[
	Every picker entry, never empty while Rival Factories are on (owner R43): every other player
	with a plot — eligible ones first (Revenge, then ready), then the ineligible ones greyed with
	their reason (shielded, protected) — then the Rival Factories, easiest first
	(AttackLogic.pickerRank); ties by name.
	@return { Target }
]]
function AttackClient.targets(): { Target }
	local list: { Target } = {}
	for _, player in Players:GetPlayers() do
		if player ~= LOCAL then
			local target = targetOf(player)
			if target.plot >= 1 then
				table.insert(list, target)
			end
		end
	end
	-- Owner R51: admin test bots, for admins only (the server refuses anyone else).
	local folder = botFolder()
	if folder ~= nil and localIsAdmin() then
		for _, mirror in folder:GetChildren() do
			local bot = botTarget(mirror)
			if bot ~= nil then
				table.insert(list, bot)
			end
		end
	end
	if AttackClient.rivalsOn() then
		for index in AttackConfig.Rivals.List do
			table.insert(list, rivalTarget(index))
		end
	end
	table.sort(list, function(a: Target, b: Target): boolean
		local ra, rb = AttackLogic.pickerRank(a.rival, a.status), AttackLogic.pickerRank(b.rival, b.status)
		if ra ~= rb then
			return ra < rb
		end
		return a.name < b.name
	end)
	return list
end

--[[
	The picker view of one entry by key ("p<userId>" / "r<rivalId>"); nil when the player left,
	the key is unknown or Rival Factories are switched off.
	@param key string
	@return Target?
]]
function AttackClient.target(key: string): Target?
	if type(key) ~= "string" or #key < 2 then
		return nil
	end
	local prefix, rest = string.sub(key, 1, 1), string.sub(key, 2)
	if prefix == "b" then
		local folder = botFolder()
		if folder == nil or not localIsAdmin() then
			return nil
		end
		for _, mirror in folder:GetChildren() do
			if mirror:GetAttribute("Key") == rest then
				return botTarget(mirror)
			end
		end
		return nil
	elseif prefix == "r" then
		local index = AttackLogic.rivalIndex(rest)
		if index == nil or not AttackClient.rivalsOn() then
			return nil
		end
		return rivalTarget(index)
	elseif prefix == "p" then
		local userId = tonumber(rest)
		local player = if userId ~= nil then Players:GetPlayerByUserId(userId) else nil
		if player == nil or player == LOCAL then
			return nil
		end
		return targetOf(player)
	end
	return nil
end

--[[
	What a LAUNCH press would do against `target` right now, from the local view (the server
	re-checks): ok + the kind to send, or the refusal reason.
	@param target Target
	@return (boolean, AttackLogic.LaunchKind, string?)
]]
function AttackClient.launchPlan(target: Target): (boolean, AttackLogic.LaunchKind, string?)
	local me = AttackClient.myState()
	local t = serverNow()
	if target.revengeUntil > t then
		return true, "revenge", nil
	end
	-- Owner R85: every player has a launcher (no Attack Console needed).
	if me.launcher < 1 then
		return false, "normal", "locked"
	end
	if not target.targetable then
		return false, "normal", "protected"
	end
	if target.shieldUntil > t then
		return false, "normal", "shield"
	end
	if me.cooldownUntil > t then
		return false, "normal", "cooldown"
	end
	return true, "normal", nil
end

--------------------------------------------------------------------------------------------------
-- Intents
--------------------------------------------------------------------------------------------------

--[[
	Sends a launch intent (debounced locally; the server decides everything).
	@param id number | string — a player's userId, a Rival Factory id or a test bot key (Target.id)
	@param kind LaunchKind
	@param area number? — owner R50 aim: one of the target's built areas / rival sections
	       (nil / 0 = the server's default aim: their highest built area)
	@return boolean — false when debounced
]]
function AttackClient.launch(id: number | string, kind: AttackLogic.LaunchKind, area: number?): boolean
	local clock = os.clock()
	if clock - lastLaunch < AttackConfig.Client.LaunchDebounce then
		return false
	end
	lastLaunch = clock
	Remotes.event("AttackLaunch"):FireServer(id, kind, area or 0)
	return true
end

--[[
	Barrage at a target: sends stored nukes, or prompts the Barrage product and sends the volley
	automatically once the purchase is granted.
	@param id number | string — Target.id (userId, rival id or bot key)
	@param area number? — the aim (owner R50)
]]
function AttackClient.barrage(id: number | string, area: number?)
	if AttackClient.myState().barrage > 0 then
		AttackClient.launch(id, "barrage", area)
		return
	end
	pendingBarrageTarget = id
	pendingBarrageArea = area or 0
	-- Owner R122: attributed to the "attack" prompt source (was unattributed). Callers gate the
	-- press with UI/PurchaseGuard (AttackScreen) before reaching this.
	Remotes.event("PromptProduct"):FireServer("Barrage", PROMPT_SOURCE)
end

--[[
	DefenseUpgrade("aa" | "launcher", toLevel?). `toLevel` = the level the player saw on the button
	(the server refuses it unless it is the stored level + 1, so a double tap never buys twice).
]]
function AttackClient.upgrade(kind: string, toLevel: number?)
	Remotes.event("DefenseUpgrade"):FireServer(kind, toLevel)
end

--[[
	Owner R85: the player who hit me most recently whose Revenge token is live and who can take a
	golden nuke right now (in the server, has a plot, no shield) — the HUD's GOLDEN REVENGE button.
	Display only: the server picks the same newest attacker at receipt time and re-checks it.
	@return Player?
]]
function AttackClient.goldenTarget(): Player?
	local t = serverNow()
	local best: Player? = nil
	local bestUntil = -math.huge
	for key, token in revenge do
		if type(key) == "number" and token.untilTime > t and token.from <= t and token.untilTime > bestUntil then
			local player = Players:GetPlayerByUserId(key)
			if
				player ~= nil
				and num(player:GetAttribute(ATTR.Plot), 0) >= 1
				and num(player:GetAttribute(ATTR.ShieldUntil), 0) <= t
			then
				best, bestUntil = player, token.untilTime
			end
		end
	end
	return best
end

--[[
	Owner R80: DefenseTower(slot, toLevel) — buy (toLevel 1) or upgrade a defence tower slot. The
	server prices it, checks the slot is unlocked and that toLevel is the stored level + 1.
	Example: AttackClient.buildTower(1, 1) -- buy the Middle Tower
]]
function AttackClient.buildTower(slot: number, toLevel: number)
	Remotes.event("DefenseTower"):FireServer(slot, toLevel)
end

--[[ ShieldActivate() — turns on the earned free shield. ]]
function AttackClient.activateShield()
	Remotes.event("ShieldActivate"):FireServer()
end

--[[
	PromptProduct / PromptPass for an attack offer ("Barrage", "Shield1h", "RevengeNuke", pass
	"MegaLauncher"), attributed to the "attack" prompt source (owner R122; PurchasePromptConfig).
	An intent only: the server validates and prompts. Callers (AttackScreen, DefenseScreen, the
	AttackHud GOLDEN deal card) gate the press with UI/PurchaseGuard first.
	Example: AttackClient.buy("Shield1h")
]]
function AttackClient.buy(key: string, isPass: boolean?)
	Remotes.event(if isPass then "PromptPass" else "PromptProduct"):FireServer(key, PROMPT_SOURCE)
end

local analyticsModule: any = nil
--[[
	Reports a screen open to the client analytics funnel (guarded; analytics never breaks play).
	@param screen string — "Attack" / "Defense"
	@param source string? — AnalyticsConfig.ClientFunnel.Sources label (default "other")
]]
function AttackClient.reportOpen(screen: string, source: unknown)
	if analyticsModule == nil then
		local ok, module = pcall(function(): any
			return require(script.Parent.Parent.Analytics.ClientAnalytics) :: any
		end)
		analyticsModule = if ok then module else false
	end
	if analyticsModule ~= false then
		pcall(analyticsModule.screenOpened, screen, if type(source) == "string" then source else "other")
	end
end

--------------------------------------------------------------------------------------------------
-- NukeFlight intake
--------------------------------------------------------------------------------------------------

-- Validates a NukeFlight payload into a FlightRenderer.Flight (nil when malformed).
local function parseFlight(raw: unknown): FlightRenderer.FlightData?
	if type(raw) ~= "table" then
		return nil
	end
	local data = raw :: { [string]: any }
	local function int(key: string, min: number, max: number): number?
		local value = data[key]
		if type(value) ~= "number" or value ~= value or value % 1 ~= 0 or value < min or value > max then
			return nil
		end
		return value
	end
	local function real(key: string, min: number, max: number): number?
		local value = data[key]
		if type(value) ~= "number" or value ~= value or value < min or value > max then
			return nil
		end
		return value
	end
	local id = int("id", 1, 2 ^ 53)
	local fromUserId = int("fromUserId", 0, 2 ^ 53)
	-- toUserId 0 = a Rival Factory (owner R43); toPlot is a target SLOT (plots, then the islands).
	local toUserId = int("toUserId", 0, 2 ^ 53)
	local t0 = real("t0", 0, 1e11)
	local flight = real("flight", 0.5, 60)
	local fromPlot = int("fromPlot", 1, 8)
	local toPlot = int("toPlot", 1, AttackGeometry.slotCount())
	local silo = int("silo", 1, 8)
	local impact = int("impact", 1, 64)
	local tier = int("tier", 1, AttackConfig.MaxLevel)
	-- Total shots of every defending tower (owner R80: up to MaxShotsPerNuke per tower).
	local shots = int("shots", 0, AttackConfig.Flight.MaxShotsPerNuke * (1 + DefenseTowers.count())) or 0
	local interceptAt = real("interceptAt", 0, 60) or 0
	local firstShot = real("firstShot", 0, 60) or 0
	local reload = real("reload", 0, 10) or 0
	-- Owner R50 aim (0 = legacy impact index) + scatter; owner R51 test bot keys.
	local area = int("area", 0, 64) or 0
	local sx = real("sx", -64, 64) or 0
	local sz = real("sz", -64, 64) or 0
	local function botKey(field: string): string?
		local value = data[field]
		return if type(value) == "string" and #value <= 16 then value else nil
	end
	-- Owner R80: one volley per defending tower that fired ({ t, n, f, r, h }), validated
	-- entry by entry (a malformed entry is dropped, never trusted).
	local volleys: { FlightRenderer.Volley } = {}
	local rawVolleys = data.volleys
	if type(rawVolleys) == "table" then
		for index = 1, math.min(#rawVolleys, 1 + DefenseTowers.count()) do
			local entry = rawVolleys[index]
			if type(entry) ~= "table" then
				continue
			end
			local t, n, f, r = entry.t, entry.n, entry.f, entry.r
			if
				type(t) == "number"
				and t % 1 == 0
				and t >= 0
				and t <= DefenseTowers.count()
				and type(n) == "number"
				and n % 1 == 0
				and n >= 1
				and n <= AttackConfig.Flight.MaxShotsPerNuke
				and type(f) == "number"
				and f == f
				and f >= 0
				and f <= 60
				and type(r) == "number"
				and r == r
				and r > 0
				and r <= 10
			then
				table.insert(volleys, { tower = t, shots = n, firstShot = f, reload = r, hit = entry.h == true })
			end
		end
	end
	local kind = data.kind
	if
		id == nil
		or fromUserId == nil
		or toUserId == nil
		or t0 == nil
		or flight == nil
		or fromPlot == nil
		or toPlot == nil
		or silo == nil
		or impact == nil
		or tier == nil
		or type(data.intercepted) ~= "boolean"
		or (kind ~= "normal" and kind ~= "revenge" and kind ~= "barrage" and kind ~= "golden")
	then
		return nil
	end
	return {
		id = id,
		fromUserId = fromUserId,
		toUserId = toUserId,
		t0 = t0,
		duration = flight,
		intercepted = data.intercepted == true,
		interceptAt = interceptAt,
		kind = kind,
		fromPlot = fromPlot,
		toPlot = toPlot,
		silo = silo,
		impact = impact,
		tier = tier,
		shots = shots,
		firstShot = firstShot,
		reload = reload,
		volleys = volleys,
		area = area,
		sx = sx,
		sz = sz,
		fromBot = botKey("fromBot"),
		toBot = botKey("toBot"),
	}
end

local function onFlight(raw: unknown)
	local flight = parseFlight(raw)
	if flight == nil then
		return
	end
	FlightRenderer.add(flight, LOCAL.UserId)
	-- My own launch (owner R54): countdown + follow-the-missile cinematic (first nuke of a volley).
	if flight.fromUserId == LOCAL.UserId then
		LaunchCam.play(flight)
	end
	-- My Revenge was accepted by the server: the token is spent (a player's, or a test bot's).
	local spentKey: (number | string)? = flight.toBot or flight.toUserId
	if
		flight.fromUserId == LOCAL.UserId
		and flight.kind == "revenge"
		and spentKey ~= nil
		and revenge[spentKey] ~= nil
	then
		revenge[spentKey] = nil
		AttackClient.RevengeChanged:Fire()
		queueChanged()
	end
	-- A real hit on me → a Revenge token against the attacker (a player, or an admin test bot) from
	-- impact time (the server grants none for revenge hits).
	local attackerKey: (number | string)? = if flight.fromBot ~= nil
		then flight.fromBot
		elseif flight.fromUserId ~= 0 then flight.fromUserId
		else nil
	if
		flight.toUserId == LOCAL.UserId
		and not flight.intercepted
		and attackerKey ~= nil
		and flight.kind ~= "revenge"
	then
		local impactAt = flight.t0 + flight.duration
		revenge[attackerKey :: number | string] = {
			from = impactAt,
			-- 2 s early so the chip never outlives the server's token.
			untilTime = impactAt + AttackConfig.RevengeSeconds - 2,
		}
		task.delay(math.max(impactAt - serverNow(), 0) + 0.05, function()
			AttackClient.RevengeChanged:Fire()
			queueChanged()
		end)
	end
end

--------------------------------------------------------------------------------------------------
-- HUD button, console prompts, domes
--------------------------------------------------------------------------------------------------

local hudModule: any = nil
-- The HUD façade (lazy, guarded: the HUD may not exist in a test harness).
local function hud(): any
	if hudModule == nil then
		local ok, module = pcall(function(): any
			return require(script.Parent.Parent.UI.Hud.Hud) :: any
		end)
		hudModule = if ok then module else false
	end
	return if hudModule ~= false then hudModule else nil
end

-- Attack HUD button visibility + badge.
local function refreshHud()
	local api = hud()
	if api == nil then
		return
	end
	local me = AttackClient.myState()
	local revengePlayer = AttackClient.latestRevenge()
	-- Owner R85: attack is open to everyone, so the Attack button always shows (the HUD still hides
	-- it in worlds without attack); its picker's DEFEND button is the route to the Defense window.
	api.setButtonVisible("Attack", true)
	local badge = revengePlayer ~= nil or AttackLogic.freeShieldReady(me.hitsTaken) or AttackClient.defenceAlert()
	api.setButtonBadge("Attack", if badge then "!" else nil)
end

-- Enables a console prompt only on the local player's plot.
local function setupPrompt(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local prompt = instance:FindFirstChildOfClass("ProximityPrompt") or instance:WaitForChild("Prompt", 5)
	if prompt == nil or not prompt:IsA("ProximityPrompt") then
		return
	end
	local function apply()
		prompt.Enabled = instance:GetAttribute("OwnerUserId") == LOCAL.UserId
	end
	apply()
	instance:GetAttributeChangedSignal("OwnerUserId"):Connect(apply)
	prompt.Triggered:Connect(function()
		if instance:GetAttribute("OwnerUserId") ~= LOCAL.UserId then
			return
		end
		-- Only our two screens may be opened from a prompt attribute (allowlist).
		local opens = if instance:GetAttribute("Opens") == "Defense" then "Defense" else "Attack"
		local ok, ScreenManager = pcall(function(): any
			return require(script.Parent.Parent.UI.ScreenManager) :: any
		end)
		if ok then
			ScreenManager.open(opens, { source = "prompt" })
		end
	end)
end

-- Pops a shield dome in (local size tween; Reduce Motion shows it at once).
local function popDome(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local profile: any = ClientState.profile
	if type(profile) == "table" and type(profile.settings) == "table" and profile.settings.reducedMotion == true then
		return
	end
	local part = instance:FindFirstChild("Dome")
	if part == nil or not part:IsA("BasePart") then
		return
	end
	local mesh = part:FindFirstChildOfClass("SpecialMesh")
	local info = TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	if mesh ~= nil then
		local target = mesh.Scale
		mesh.Scale = target * 0.2
		TweenService:Create(mesh, info, { Scale = target }):Play()
	else
		local target = part.Size
		part.Size = target * 0.2
		TweenService:Create(part, info, { Size = target }):Play()
	end
end

-- Calls `fn` for every current and future instance with a tag.
local function onTag(tag: string, fn: (Instance) -> ())
	CollectionService:GetInstanceAddedSignal(tag):Connect(fn)
	for _, instance in CollectionService:GetTagged(tag) do
		task.spawn(fn, instance)
	end
end

--------------------------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------------------------

--[[ Starts the attack client (idempotent). ]]
function AttackClient.start()
	if started then
		return
	end
	started = true
	FlightRenderer.start()
	Remotes.event("NukeFlight").OnClientEvent:Connect(onFlight)

	ClientState.ProfileChanged:Connect(function(_profile, fields)
		if fields == nil or table.find(fields, "attack") ~= nil or table.find(fields, "cash") ~= nil then
			refreshHud()
			queueChanged()
		end
	end)
	ClientState.PurchaseGranted:Connect(function(payload)
		if payload.key == "Barrage" and pendingBarrageTarget ~= nil then
			local targetId = pendingBarrageTarget
			local targetArea = pendingBarrageArea
			pendingBarrageTarget = nil
			-- The stored nukes arrive with the profile delta; give it a moment, then send.
			task.delay(0.6, function()
				AttackClient.launch(targetId, "barrage", targetArea)
			end)
		end
	end)
	AttackClient.RevengeChanged:Connect(refreshHud)
	-- The owner-admin Rival Factory switch changes the picker list.
	ReplicatedStorage:GetAttributeChangedSignal(ATTR.RivalsOn):Connect(queueChanged)

	-- Attribute changes of any player (targets, own levels) refresh the UI.
	local watched = { ATTR.Targetable, ATTR.ShieldUntil, ATTR.AALevel, ATTR.LauncherLevel, ATTR.Plot, ATTR.Towers }
	local function watch(player: Player)
		for _, name in watched do
			player:GetAttributeChangedSignal(name):Connect(function()
				if player == LOCAL then
					refreshHud()
				end
				queueChanged()
			end)
		end
	end
	Players.PlayerAdded:Connect(function(player: Player)
		watch(player)
		queueChanged()
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		if revenge[player.UserId] ~= nil then
			revenge[player.UserId] = nil
			AttackClient.RevengeChanged:Fire()
		end
		if pendingBarrageTarget == player.UserId then
			pendingBarrageTarget = nil
		end
		queueChanged()
	end)
	for _, player in Players:GetPlayers() do
		watch(player)
	end

	onTag(AttackConfig.Tags.Console, setupPrompt)
	CollectionService:GetInstanceAddedSignal(AttackConfig.Tags.Dome):Connect(popDome)
	-- Owner R80: the in-world defence BUY pad prices + tower UPGRADE billboards (own plot).
	local defenseOk, defenseErr = pcall(DefenseWorld.start)
	if not defenseOk then
		warn(`[AttackClient] DefenseWorld failed to start: {defenseErr}`)
	end

	-- Expire Revenge tokens (one cheap pass every 2 s).
	task.spawn(function()
		while true do
			task.wait(2)
			local t = serverNow()
			local changed = false
			for userId, token in revenge do
				if token.untilTime <= t then
					revenge[userId] = nil
					changed = true
				end
			end
			if changed then
				AttackClient.RevengeChanged:Fire()
				queueChanged()
			end
		end
	end)
	refreshHud()
end

-- Controller contract (Init / Start), so the client boot list may load it directly.
function AttackClient.Init() end
function AttackClient.Start()
	AttackClient.start()
end

return AttackClient
