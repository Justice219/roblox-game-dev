--!strict
--[[
	TestBots — owner-admin attack TEST BOTS (owner R51: "i need to be able to test attacks in dev
	mode so add like a bot button in the admin panel"). A bot is a fake attack target / attacker
	on a FREE plot, so one admin can test aiming, AA, shields, knockdown + rebuild, rewards, the
	target UI and Revenge alone, in Studio AND on live servers.

	What a bot is
		* A record (never a Player, never saved) that is also Knockdown's BotSubject:
		  { key = "bot:N", plotIndex, tycoon, shieldUntil } + its own fields (name "TestBot N", area,
		  AA level, launcher level, tower schedule, owner, auto-attack settings).
		* A FREE plot (PlotService.reserveBotPlot — a joining player always evicts a bot), built to
		  the chosen area through the normal pipeline (TycoonLogic pads → PlotBuilder.restore +
		  syncLocked), so Q3's knockdown topples and rebuilds real buildings. Its AA turret / shield
		  dome are the normal AttackWorld objects.
		* A public mirror (ReplicatedStorage.<Bots.Folder>.botN, a Configuration with Key, Name,
		  Plot, Area, AA, ShieldUntil, OwnerUserId, Areas, Ready) — the admin's picker lists it with a
		  BOT tag (only admins see it; AttackService refuses non-admins server-side).

	Lifetime: removed by the admin (Attack tab), when the spawning admin leaves, LifetimeSeconds
	after spawning, at shutdown, or when a joining player needs the plot (PlotService evictor).

	Auto-attack: one 0.5 s loop for every bot; a due bot launches at its owner through the launcher
	AttackService installs (setLauncher), with the owner's chosen kind / aim.

	Security: server-only; created only by AdminService handlers (AdminAuth + audit log). Bots
	never touch a profile, never pay or receive anything themselves; rewards an admin earns by
	hitting a bot use the "attack_test" cash reason (AttackService).

	Connects to: Tycoon/PlotService, World/PlotBuilder, Tycoon/Knockdown (BotSubject), Attack/
	AttackWorld, Shared/{Tycoon/TycoonLogic, Config/TycoonConfig, Config/AttackConfig, Attack/
	AttackLogic}, Services/AttackService (launcher, targets), Admin/Handlers/AttackHandlers.

	Example (an admin handler):
		local bot, message = TestBots.spawn(admin, { area = 7, aa = 2, shield = false })
		TestBots.setAuto(bot, 20, "normal", 0)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackLogic = require(ReplicatedStorage.Shared.Attack.AttackLogic)
local AttackWorld = require(script.Parent.AttackWorld)
local Knockdown = require(script.Parent.Parent.Tycoon.Knockdown)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)
local PlotService = require(script.Parent.Parent.Tycoon.PlotService)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)

local TestBots = {}

local BOTS = AttackConfig.Bots

export type Kind = "normal" | "barrage"

export type Bot = {
	-- Knockdown.BotSubject fields
	key: string,
	plotIndex: number,
	tycoon: any,
	shieldUntil: number,
	-- TestBots fields
	id: number,
	name: string,
	area: number,
	aa: number,
	launcher: number,
	towerFreeAt: number, -- server time its AA tower may fire next (DefenseService.engageBot)
	built: { number }, -- built areas (aim markers / validation)
	owner: Player,
	spawnedAt: number, -- os.clock()
	ready: boolean, -- its plot finished building
	autoEvery: number, -- seconds between auto-attacks (0 = off)
	autoKind: Kind,
	autoArea: number, -- 0 = auto aim
	autoNextAt: number, -- server time
	mirror: Configuration?,
}

export type SpawnOptions = { area: number, aa: number, shield: boolean }

-- (bot, target, kind, area) → (ok, message): installed by AttackService.Start.
type Launcher = (bot: Bot, target: Player, kind: Kind, area: number) -> (boolean, string)

local bots: { [number]: Bot } = {}
local launcher: Launcher? = nil
local started = false

local function now(): number
	return Workspace:GetServerTimeNow()
end

-- The mirror folder (created on demand).
local function mirrorFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(BOTS.Folder)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = BOTS.Folder
	folder.Parent = ReplicatedStorage
	return folder
end

-- Writes the bot's public attributes (the picker's view).
local function publish(bot: Bot)
	local mirror = bot.mirror
	if mirror == nil then
		local created = Instance.new("Configuration")
		created.Name = `bot{bot.id}`
		created.Parent = mirrorFolder()
		bot.mirror = created
		mirror = created
	end
	local m = mirror :: Configuration
	m:SetAttribute("Key", bot.key)
	m:SetAttribute("Name", bot.name)
	m:SetAttribute("Plot", bot.plotIndex)
	m:SetAttribute("Area", bot.area)
	m:SetAttribute("AA", bot.aa)
	m:SetAttribute("ShieldUntil", bot.shieldUntil)
	m:SetAttribute("OwnerUserId", bot.owner.UserId)
	m:SetAttribute("Areas", AttackLogic.encodeAreas(bot.built))
	m:SetAttribute("Ready", bot.ready)
end

-- Tears a bot down; `plotGone` = PlotService already reassigned the plot (eviction).
local function teardown(bot: Bot, plotGone: boolean)
	if bots[bot.id] ~= bot then
		return
	end
	bots[bot.id] = nil
	bot.autoEvery = 0
	pcall(Knockdown.forgetBot, bot)
	AttackWorld.clearPlot(bot.plotIndex)
	if not plotGone then
		PlotService.releaseBotPlot(bot.plotIndex)
	end
	local mirror = bot.mirror
	if mirror ~= nil then
		mirror:Destroy()
		bot.mirror = nil
	end
end

--[[
	Installs the attack launcher (AttackService.Start): how a bot launches at a player.
	@param fn Launcher
]]
function TestBots.setLauncher(fn: Launcher)
	launcher = fn
end

--[[ The bot "TestBot N" (nil when not live). ]]
function TestBots.get(id: unknown): Bot?
	if type(id) ~= "number" then
		return nil
	end
	return bots[id]
end

--[[ The bot with wire key `key` ("bot:N"), or nil. Accepts any value (client input). ]]
function TestBots.byKey(key: unknown): Bot?
	if type(key) ~= "string" or #key > 16 or string.sub(key, 1, #BOTS.KeyPrefix) ~= BOTS.KeyPrefix then
		return nil
	end
	local id = tonumber(string.sub(key, #BOTS.KeyPrefix + 1))
	local bot = if id ~= nil then bots[id] else nil
	return if bot ~= nil and bot.key == key then bot else nil
end

--[[ Every live bot (id order). ]]
function TestBots.all(): { Bot }
	local list: { Bot } = {}
	for id = 1, 16 do
		local bot = bots[id]
		if bot ~= nil then
			table.insert(list, bot)
		end
	end
	return list
end

--[[
	Spawns a bot for `owner` (an admin): claims a free plot, builds it to `opts.area` in the
	background (all pads of areas 1..area), shows its AA turret / shield. Never yields.
	@param owner Player — the admin (bots attack them; removed when they leave)
	@param opts SpawnOptions — area 1..#Areas, aa 0..MaxLevel, shield
	@return (Bot?, string) — the bot or nil, and a message for the admin
]]
function TestBots.spawn(owner: Player, opts: SpawnOptions): (Bot?, string)
	local count = 0
	local id: number? = nil
	for candidate = 1, BOTS.Max do
		if bots[candidate] ~= nil then
			count += 1
		elseif id == nil then
			id = candidate
		end
	end
	if id == nil or count >= BOTS.Max then
		return nil, `At most {BOTS.Max} test bots - remove one first`
	end
	local botId = id :: number
	local area = math.clamp(math.floor(opts.area), 1, #TycoonConfig.Areas)
	local key = `{BOTS.KeyPrefix}{botId}`
	local name = `TestBot {botId}`
	local plotIndex = PlotService.reserveBotPlot(key, `{name} (BOT)`)
	if plotIndex == nil then
		return nil, "No free plot for a test bot - every plot is taken"
	end
	-- Its tycoon: every pad of areas 1..area, applied in chain order (the normal unlock path).
	local tycoon = TycoonLogic.newState()
	for _, pad in TycoonConfig.PadOrder do
		if pad.area <= area then
			TycoonLogic.applyPad(tycoon, pad.id)
		end
	end
	local t = now()
	local bot: Bot = {
		key = key,
		plotIndex = plotIndex,
		tycoon = tycoon,
		shieldUntil = if opts.shield then t + BOTS.ShieldSeconds else 0,
		id = botId,
		name = name,
		area = area,
		aa = math.clamp(math.floor(opts.aa), 0, AttackConfig.MaxLevel),
		launcher = BOTS.LauncherLevel,
		towerFreeAt = -math.huge,
		built = {},
		owner = owner,
		spawnedAt = os.clock(),
		ready = false,
		autoEvery = 0,
		autoKind = "normal",
		autoArea = 0,
		autoNextAt = 0,
		mirror = nil,
	}
	local ok, built = pcall(Knockdown.builtAreas, bot)
	bot.built = if ok and type(built) == "table" then built else {}
	bots[botId] = bot
	publish(bot)
	-- Test-bot art is deferred (never ahead of real players' meshes at boot).
	AttackWorld.setTurret(plotIndex, bot.aa, nil, true)
	if bot.shieldUntil > t then
		AttackWorld.setDome(plotIndex, true, bot.shieldUntil, true)
	end
	-- Build the plot through the normal pipeline (yields while meshes load).
	task.spawn(function()
		local restored = PlotBuilder.restore(plotIndex, tycoon)
		if restored and bots[botId] == bot then
			PlotBuilder.syncLocked(plotIndex, tycoon)
			bot.ready = true
			publish(bot)
		end
	end)
	return bot, `{name} is building on plot {plotIndex} (area {area}, AA {bot.aa})`
end

--[[ Removes one bot (frees its plot). ]]
function TestBots.remove(bot: Bot)
	teardown(bot, false)
end

--[[ Removes every bot; returns how many. ]]
function TestBots.removeAll(): number
	local list = TestBots.all()
	for _, bot in list do
		teardown(bot, false)
	end
	return #list
end

--[[ Turns a bot's shield bubble on (Bots.ShieldSeconds) or off. ]]
function TestBots.setShield(bot: Bot, on: boolean)
	local t = now()
	bot.shieldUntil = if on then t + BOTS.ShieldSeconds else 0
	AttackWorld.setDome(bot.plotIndex, on, bot.shieldUntil, true)
	publish(bot)
end

--[[
	Auto-attack: the bot launches at its owner every `every` seconds (0 = off; at least
	Bots.MinAutoSeconds), with `kind` and aim `area` (0 = auto).
]]
function TestBots.setAuto(bot: Bot, every: number, kind: Kind, area: number)
	bot.autoEvery = if every <= 0 then 0 else math.max(every, BOTS.MinAutoSeconds)
	bot.autoKind = kind
	bot.autoArea = math.max(math.floor(area), 0)
	bot.autoNextAt = now() + 1
end

--[[
	Launches bot → its owner now through the installed launcher.
	@return (boolean, string)
]]
function TestBots.attack(bot: Bot, kind: Kind, area: number): (boolean, string)
	local fn = launcher
	if fn == nil then
		return false, "Attack mode is not running"
	end
	if bot.owner.Parent ~= Players then
		return false, "The bot's owner left"
	end
	return fn(bot, bot.owner, kind, area)
end

--[[
	The bot as an AttackLogic.Actor (its own plot, its area, its shield; never loaded as a player:
	userId 0 so it is never "self").
]]
function TestBots.actor(bot: Bot): AttackLogic.Actor
	return {
		userId = 0,
		loaded = true,
		plot = bot.plotIndex,
		-- Admin test targets: any bot area is attackable (the area >= 7 rule protects new PLAYERS).
		area = math.max(bot.area, AttackConfig.UnlockArea),
		console = true,
		launcher = bot.launcher,
		cooldownUntil = 0,
		shieldUntil = bot.shieldUntil,
		barrage = 0,
	}
end

-- One pass: lifetime, shield expiry, due auto-attacks.
local function step()
	local t = now()
	local clock = os.clock()
	for _, bot in TestBots.all() do
		if bot.owner.Parent ~= Players or clock - bot.spawnedAt >= BOTS.LifetimeSeconds then
			teardown(bot, false)
			continue
		end
		if bot.shieldUntil > 0 and bot.shieldUntil <= t then
			bot.shieldUntil = 0
			AttackWorld.setDome(bot.plotIndex, false, 0)
			publish(bot)
		end
		if bot.autoEvery > 0 and t >= bot.autoNextAt then
			bot.autoNextAt = t + bot.autoEvery
			local ok, err = pcall(TestBots.attack, bot, bot.autoKind, bot.autoArea)
			if not ok then
				warn(`[TestBots] auto-attack failed: {err}`)
			end
		end
	end
end

--[[ Starts the loop and the cleanup hooks (idempotent; AttackService.Start). ]]
function TestBots.start()
	if started then
		return
	end
	started = true
	PlotService.setBotEvictor(function(key: string, _index: number)
		local bot = TestBots.byKey(key)
		if bot ~= nil then
			local owner = bot.owner
			teardown(bot, true)
			if owner.Parent == Players then
				pcall(function()
					local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService) :: any
					PlayerDataService.notify(owner, `{bot.name} left so a player could join`, "info")
				end)
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		for _, bot in TestBots.all() do
			if bot.owner == player then
				teardown(bot, false)
			end
		end
	end)
	game:BindToClose(function()
		TestBots.removeAll()
	end)
	task.spawn(function()
		while true do
			task.wait(0.5)
			if next(bots) ~= nil then
				local ok, err = pcall(step)
				if not ok then
					warn(`[TestBots] step failed: {err}`)
				end
			end
		end
	end)
end

return TestBots
