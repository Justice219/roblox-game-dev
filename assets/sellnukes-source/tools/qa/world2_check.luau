--!strict
--[[
	world2_check.luau — SERVER half of the World 2 QA tour (owner R57, W12; run by
	tools/qa/world2_check.py through the Studio MCP `eval_server_runtime`, in a playtest the driver
	started while holding the Studio lock).

	The driver substitutes three placeholders with whitelisted values only:
		COMMAND  one of the commands below (a fixed set; anything else returns an error)
		WORLD    a world id matching ^[a-z][a-z0-9]{0,15}$ (re-checked here with WorldsConfig.get)
		ARGS     a Luau table literal of numbers built by the driver

	Commands (everything goes through the REAL game code: AdminService.dispatchAsync runs the
	owner-admin pipeline — re-auth, schema validation, audit — exactly like the admin panel):
		prepare        waits for player 1's profile + plot; snapshots profile.worlds[WORLD] +
		               lastWorld for `restore` (kept in _G.__W2QA for this server VM); JSON state
		admin          runs one admin command by code ARGS[1] (table ADMIN below; ARGS[2] = number arg)
		               on player ARGS[3] (default 1); returns { ok, message }
		where          JSON: each player's CurrentWorld attribute, the world their character
		               stands in (WorldLayout.worldAt), plot index, profile world summary
		portal         moves player 1 into the Time Machine trigger (ARGS[1]: 1 = the lobby side
		               toward WORLD, 2 = WORLD's return portal) so the real touch volume travels them
		analytics      JSON: today's unsaved counters of the worlds family + the economy keys of
		               WORLD's currencies + core uniq:w_<WORLD> (AnalyticsService.snapshotUnsaved)
		perf           JSON: heartbeat ms / fps (Stats + AnalyticsService.liveHealth), Workspace
		               instance count, server memory, built plots per world, players per world
		fill           perf setup: every FREE plot slot 2..8 of WORLD gets that world's full pad set
		               (PlotBuilder.world(WORLD).restore — no profile, no player), and for "main" the
		               R51 TestBots at area 10; returns how many were built
		unfill         clears what `fill` built (plots of WORLD with no owner, bots removed)
		visitor_touch  multiplayer: pivots player 2 onto player 1's next WORLD pad (the real Touched
		               path) and reports both players' pad counts before / after (must not change)
		focus          streams the area around ARGS (x, y, z) for player ARGS[4] (default 1) and
		               anchors their character there (camera-side ground point for screenshots)
		unanchor       releases the character anchored by `focus`
		restore        puts player 1's profile.worlds[WORLD] + lastWorld back from the snapshot,
		               rebuilds their WORLD plot (WorldRebuildPlot) and sends them home (main spawn)
		money          (owner R60) JSON: cash / totalEarned / WORLD currency / its totalEarned / the
		               tokens of both, each world's income per second, the server clock
		next_pad       JSON: player 1's next WORLD pad id, its position and the plot entrance (camera)
		buy_next       buys that pad through the REAL TycoonService.purchasePad (paid from the WORLD
		               wallet); JSON { pad, ok, why, cost, position }
		until_finale   buys (free, admin-style) every WORLD pad before the finale, so the finale pad
		               stands next on the path; JSON like next_pad
		portal_view    JSON: world-space centres of the lobby Time Machine trigger and WORLD's return
		               portal trigger (camera framing for the portal shots)
		npm_producer   (owner R67 / R64) buys Nuke Town's first pad and samples the first producer
		               6 x 1 s with no click (Automated, CycleStart, CycleTime, cash)
		npm_state      (owner R67) JSON: New Player Mode attribute + PlayerDataService verdict, the
		               live profile's cash / pads / tutorial step / rebirths, profile.worlds[WORLD]
		               (unlocked, cash, area, pads, rebirths), WorldService.isUnlocked, the Nuke
		               Town plot's descendant count and the first producer's Automated /
		               CycleStart attributes sampled 3 s apart (does it run without a click?)

	Studio DataStores are separate from production and `restore` puts the test profile back.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Stats = game:GetService("Stats")

local COMMAND = "__COMMAND__"
local WORLD = "__WORLD__"
local ARGS: { number } = { --[[ARGS]]
}

local Server = ServerScriptService:WaitForChild("Server")
local WorldsConfig = (require :: any)(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
local WorldLayout = (require :: any)(ReplicatedStorage.Shared.Config.WorldLayout)
local AdminConfig = (require :: any)(ReplicatedStorage.Shared.Config.AdminConfig)
local PlayerDataService = (require :: any)(Server.Services.PlayerDataService)
local AdminService = (require :: any)(Server.Services.AdminService)
local AnalyticsService = (require :: any)(Server.Services.AnalyticsService)
local PlotService = (require :: any)(Server.Tycoon.PlotService)
local PlotBuilder = (require :: any)(Server.World.PlotBuilder)

local def = WorldsConfig.get(WORLD)
if def == nil then
	return `ERROR unknown world {WORLD}`
end

-- Admin commands by code (the driver only ever sends a number).
local ADMIN: { [number]: { name: string, args: (n: number) -> { [string]: any } } } = {
	[1] = { name = "WorldRelock", args = function() return { world = WORLD } end },
	[2] = { name = "WorldUnlock", args = function() return { world = WORLD } end },
	[3] = { name = "WorldSetArea", args = function(n) return { world = WORLD, area = n } end },
	[4] = { name = "WorldUnlockAll", args = function() return { world = WORLD } end },
	[5] = { name = "WorldResetRun", args = function() return { world = WORLD } end },
	[6] = { name = "WorldSetRebirths", args = function(n) return { world = WORLD, rebirths = n } end },
	[7] = { name = "WorldSend", args = function() return { world = WORLD, to = "spawn" } end },
	[8] = { name = "WorldSend", args = function() return { world = WORLD, to = "plot" } end },
	[9] = { name = "WorldOfflinePreview", args = function(n) return { hours = n } end },
	[10] = { name = "WorldGrantCash", args = function(n) return { world = WORLD, amount = n } end },
	[11] = { name = "WorldRebuildPlot", args = function() return { world = WORLD, replay = false } end },
	[12] = { name = "WorldSend", args = function() return { world = "main", to = "spawn" } end },
	[13] = { name = "WorldEnabled", args = function(n) return { world = WORLD, on = n ~= 0 } end },
	[14] = { name = "WorldWipe", args = function() return { world = WORLD } end },
	[15] = { name = "GrantCash", args = function(n) return { amount = n } end },
	[16] = { name = "GrantGems", args = function(n) return { amount = n } end },
	[17] = { name = "SetArea", args = function(n) return { area = n } end },
	[18] = { name = "WorldRebuildPlot", args = function() return { world = WORLD, replay = true } end },
}

local function playerAt(index: number?): Player?
	return Players:GetPlayers()[math.clamp(math.floor(index or 1), 1, 8)]
end

local player = playerAt(1)
if player == nil then
	return "ERROR no player"
end

-- Plain JSON-able deep copy (profile tables hold only primitives / tables).
local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in value do
		out[key] = deepCopy(item)
	end
	return out
end

-- Count of keys of a table (pads sets).
local function count(value: any): number
	local n = 0
	if type(value) == "table" then
		for _ in value do
			n += 1
		end
	end
	return n
end

local function worldSummary(target: Player): { [string]: any }
	local profile = PlayerDataService.getProfile(target)
	local state = if profile ~= nil and type(profile.worlds) == "table" then profile.worlds[WORLD] else nil
	if type(state) ~= "table" then
		return { loaded = profile ~= nil }
	end
	return {
		loaded = true,
		unlocked = state.unlocked == true,
		cash = state.cash,
		area = if type(state.tycoon) == "table" then state.tycoon.area else 0,
		pads = if type(state.tycoon) == "table" then count(state.tycoon.pads) else 0,
		rebirths = state.rebirths,
		tokens = state.rebirthTokens,
		visits = if type(state.stats) == "table" then state.stats.visits else 0,
		lastWorld = profile.lastWorld,
	}
end

local function dispatch(target: Player, code: number, n: number): { ok: boolean, message: string }
	local entry = ADMIN[code]
	if entry == nil then
		return { ok = false, message = `unknown admin code {code}` }
	end
	local args = entry.args(n)
	local caller = { userId = player.UserId, name = player.Name, player = player }
	-- Targeted commands carry the target's user id (a lookup key the pipeline re-resolves).
	local command = AdminConfig.Commands[entry.name]
	if command ~= nil and command.target == "Player" then
		args.userId = target.UserId
	end
	local result = AdminService.dispatchAsync(caller, entry.name, args)
	return { ok = result.ok == true, message = tostring(result.message) }
end

local state = (_G :: any).__W2QA
if state == nil then
	state = {}
	;(_G :: any).__W2QA = state
end

-- Player 1's next pad in WORLD (nil when every pad is owned) and the plot index.
local function nextPadOf(target: Player): (string?, number?)
	local profile = PlayerDataService.getProfile(target)
	local state = if profile ~= nil and type(profile.worlds) == "table" then profile.worlds[WORLD] else nil
	local pads = if type(state) == "table" and type(state.tycoon) == "table" then state.tycoon.pads else {}
	for _, pad in def.economy.PadOrder do
		if pads[pad.id] == nil then
			return pad.id, PlotService.getPlotIndex(target)
		end
	end
	return nil, PlotService.getPlotIndex(target)
end

-- JSON-ready view of one pad on the plot (position + entrance for the camera).
local function padView(padId: string?, plotIndex: number?): { [string]: any }
	if padId == nil or plotIndex == nil then
		return { pad = padId, plot = plotIndex }
	end
	local builder = PlotBuilder.world(WORLD)
	local okPos, position = pcall(builder.padPosition, plotIndex, padId)
	local okEntrance, entrance = pcall(builder.entrance, plotIndex)
	local v3 = function(v: any): { number }?
		return if typeof(v) == "Vector3" then { v.X, v.Y, v.Z } else nil
	end
	return {
		pad = padId,
		plot = plotIndex,
		cost = def.economy.PadsById[padId].cost,
		position = if okPos then v3(position) else nil,
		entrance = if okEntrance and typeof(entrance) == "CFrame" then v3(entrance.Position) else nil,
	}
end

if COMMAND == "prepare" then
	local started = os.clock()
	while
		(PlayerDataService.getProfile(player) == nil or PlotService.getPlotIndex(player) == nil)
		and os.clock() - started < 60
	do
		task.wait(0.5)
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return "ERROR profile not loaded"
	end
	if state.snapshot == nil then
		state.snapshot = {
			world = deepCopy(if type(profile.worlds) == "table" then profile.worlds[WORLD] else nil),
			lastWorld = profile.lastWorld,
		}
	end
	return HttpService:JSONEncode({
		plot = PlotService.getPlotIndex(player),
		userId = player.UserId,
		summary = worldSummary(player),
	})
elseif COMMAND == "admin" then
	local target = playerAt(ARGS[3]) or player
	return HttpService:JSONEncode(dispatch(target, math.floor(ARGS[1] or 0), ARGS[2] or 0))
elseif COMMAND == "where" then
	local rows = {}
	for index, each in Players:GetPlayers() do
		local character = each.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
		local position = if root ~= nil then (root :: BasePart).Position else nil
		table.insert(rows, {
			index = index,
			currentWorld = each:GetAttribute("CurrentWorld") or "main",
			standingIn = if position ~= nil then (WorldLayout.worldAt(position) or "none") else "no character",
			plot = PlotService.getPlotIndex(each),
			summary = worldSummary(each),
		})
	end
	return HttpService:JSONEncode(rows)
elseif COMMAND == "portal" then
	local HubBuilder = (require :: any)(Server.World.HubBuilder)
	local side = if (ARGS[1] or 1) == 2 then "world" else "main"
	local portal = if type(HubBuilder.getWorldPortal) == "function" then HubBuilder.getWorldPortal(WORLD, side) else nil
	if portal == nil or portal.trigger == nil then
		return `ERROR no {side} portal for {WORLD}`
	end
	local character = player.Character
	if character == nil then
		return "ERROR no character"
	end
	character:PivotTo(portal.trigger.CFrame * CFrame.new(0, 1, 0))
	return `touched {side} portal`
elseif COMMAND == "analytics" then
	local unsaved = AnalyticsService.snapshotUnsaved()
	local out: { [string]: { [string]: number } } = { worlds = {}, economy = {}, core = {}, tycoon = {} }
	for _, families in unsaved do
		for family, counters in families do
			for key, value in counters do
				local keep = (family == "worlds")
					or (family == "economy" and (string.find(key, def.currency.key, 1, true) ~= nil or string.find(
						key,
						def.tokens.key,
						1,
						true
					) ~= nil))
					or (family == "core" and (key == `uniq:w_{WORLD}` or string.sub(key, 1, 10) == "ops:badKey"))
					or (family == "tycoon" and string.find(key, `:{def.idPrefix}`, 1, true) ~= nil)
				if keep and out[family] ~= nil then
					out[family][key] = (out[family][key] or 0) + value
				end
			end
		end
	end
	return HttpService:JSONEncode(out)
elseif COMMAND == "perf" then
	local health = if type(AnalyticsService.liveHealth) == "function" then AnalyticsService.liveHealth() else {}
	local perWorld: { [string]: number } = {}
	for _, each in Players:GetPlayers() do
		local id = each:GetAttribute("CurrentWorld") or "main"
		perWorld[id] = (perWorld[id] or 0) + 1
	end
	local built: { [string]: number } = {}
	for _, worldId in WorldsConfig.Order do
		local builder = PlotBuilder.world(worldId)
		local n = 0
		for index = 1, 8 do
			local ok, plot = pcall(builder.getPlot, index)
			if ok and plot ~= nil then
				n += #plot:GetDescendants()
			end
		end
		built[worldId] = n
	end
	return HttpService:JSONEncode({
		heartbeatMs = Stats.HeartbeatTimeMs,
		fps = health.fps,
		heartbeatAvgMs = health.heartbeatMs,
		instances = Stats.InstanceCount,
		workspaceDescendants = #workspace:GetDescendants(),
		memoryMb = math.floor(Stats:GetTotalMemoryUsageMb()),
		plotDescendantsPerWorld = built,
		playersPerWorld = perWorld,
	})
elseif COMMAND == "fill" then
	local builder = PlotBuilder.world(WORLD)
	local owned: { [number]: boolean } = {}
	for _, each in Players:GetPlayers() do
		local index = PlotService.getPlotIndex(each)
		if index ~= nil then
			owned[index] = true
		end
	end
	local pads: { [string]: true } = {}
	for _, pad in def.economy.PadOrder do
		pads[pad.id] = true
	end
	local producers: { [string]: number } = {}
	for _, producer in def.economy.Producers do
		producers[producer.id] = 50
	end
	local filled = {}
	state.filled = state.filled or {}
	if WORLD == "main" then
		local TestBots = (require :: any)(Server.Attack.TestBots)
		for _ = 1, 7 do
			local bot = TestBots.spawn(player, { area = 10, aa = 1, shield = false })
			if bot ~= nil then
				table.insert(filled, bot.plotIndex)
			end
		end
	else
		for index = 1, 8 do
			if not owned[index] then
				local tycoon = { pads = table.clone(pads), producers = table.clone(producers), area = #def.economy.Areas }
				local ok = pcall(builder.restore, index, tycoon)
				if ok then
					table.insert(filled, index)
					state.filled[`{WORLD}:{index}`] = true
				end
			end
		end
	end
	return HttpService:JSONEncode({ world = WORLD, filled = filled })
elseif COMMAND == "unfill" then
	local cleared = 0
	if WORLD == "main" then
		local TestBots = (require :: any)(Server.Attack.TestBots)
		cleared = TestBots.removeAll()
	else
		local builder = PlotBuilder.world(WORLD)
		for key in state.filled or {} do
			local worldId, index = string.match(key, "^(%w+):(%d+)$")
			if worldId == WORLD and index ~= nil then
				pcall(builder.clear, tonumber(index))
				state.filled[key] = nil
				cleared += 1
			end
		end
	end
	return `cleared {cleared}`
elseif COMMAND == "visitor_touch" then
	local visitor = playerAt(2)
	if visitor == nil or visitor == player then
		return "ERROR needs two players"
	end
	local ownerIndex = PlotService.getPlotIndex(player)
	local before = { owner = worldSummary(player).pads, visitor = worldSummary(visitor).pads }
	local builder = PlotBuilder.world(WORLD)
	local profile = PlayerDataService.getProfile(player)
	local ownerPads = if profile ~= nil and type(profile.worlds) == "table" and profile.worlds[WORLD] ~= nil
		then profile.worlds[WORLD].tycoon.pads
		else {}
	local nextPad: string? = nil
	for _, pad in def.economy.PadOrder do
		if ownerPads[pad.id] == nil then
			nextPad = pad.id
			break
		end
	end
	if ownerIndex == nil or nextPad == nil or visitor.Character == nil then
		return "ERROR no owner plot / next pad / visitor character"
	end
	local ok, position = pcall(builder.padPosition, ownerIndex, nextPad)
	if not ok or typeof(position) ~= "Vector3" then
		return `ERROR pad {nextPad} not built on plot {ownerIndex}`
	end
	visitor.Character:PivotTo(CFrame.new(position + Vector3.new(0, 3, 0)))
	task.wait(3)
	local after = { owner = worldSummary(player).pads, visitor = worldSummary(visitor).pads }
	return HttpService:JSONEncode({
		pad = nextPad,
		plot = ownerIndex,
		before = before,
		after = after,
		refused = before.owner == after.owner and before.visitor == after.visitor,
	})
elseif COMMAND == "focus" then
	local target = playerAt(ARGS[4]) or player
	local position = Vector3.new(ARGS[1] or 0, ARGS[2] or 0, ARGS[3] or 0)
	pcall(function()
		target:RequestStreamAroundAsync(position, 5)
	end)
	local character = target.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	if character ~= nil and root ~= nil then
		character:PivotTo(CFrame.new(position + Vector3.new(0, 4, 0)))
		root.Anchored = true
	end
	return "focused"
elseif COMMAND == "unanchor" then
	for _, each in Players:GetPlayers() do
		local character = each.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
		if root ~= nil then
			root.Anchored = false
		end
	end
	return "unanchored"
elseif COMMAND == "money" then
	local TycoonService = (require :: any)(Server.Tycoon.TycoonService)
	local profile = PlayerDataService.getProfile(player)
	local state = if profile ~= nil and type(profile.worlds) == "table" then profile.worlds[WORLD] else nil
	if profile == nil or type(state) ~= "table" then
		return "ERROR no profile / world state"
	end
	return HttpService:JSONEncode({
		cash = profile.cash,
		totalEarned = profile.totalEarned,
		tokens = profile.rebirthTokens,
		worldCash = state.cash,
		worldEarned = state.totalEarned,
		worldTokens = state.rebirthTokens,
		gems = profile.gems,
		mainRate = TycoonService.incomePerSecond(player),
		worldRate = TycoonService.incomePerSecond(player, WORLD),
		clock = os.clock(),
	})
elseif COMMAND == "next_pad" then
	return HttpService:JSONEncode(padView(nextPadOf(player)))
elseif COMMAND == "buy_next" then
	-- ARGS[1] = delay seconds (> 0: the purchase is scheduled and this returns at once, so the
	-- driver's screenshot lands while the build-in is still flying; capture latency ~1 s).
	local TycoonService = (require :: any)(Server.Tycoon.TycoonService)
	local padId, plotIndex = nextPadOf(player)
	local view = padView(padId, plotIndex)
	local delay = math.clamp(ARGS[1] or 0, 0, 5)
	if padId ~= nil and delay > 0 then
		task.delay(delay, function()
			TycoonService.purchasePad(player, padId)
		end)
		view.scheduled = delay
	elseif padId ~= nil then
		local ok, why = TycoonService.purchasePad(player, padId)
		view.ok = ok
		view.why = why
	end
	return HttpService:JSONEncode(view)
elseif COMMAND == "main_buy_to" then
	-- Nuke Town pads bought (free) in order until area ARGS[1] is open: the REAL purchasePad path,
	-- so TycoonService.AreaReached fires and WorldService's unlock rule runs (a natural unlock).
	local TycoonService = (require :: any)(Server.Tycoon.TycoonService)
	local TycoonConfig = (require :: any)(ReplicatedStorage.Shared.Config.TycoonConfig)
	local profile = PlayerDataService.getProfile(player)
	local target = math.floor(ARGS[1] or 3)
	local bought = 0
	for _, pad in TycoonConfig.PadOrder do
		if profile == nil or profile.tycoon.area >= target then
			break
		end
		if profile.tycoon.pads[pad.id] == nil then
			local ok = TycoonService.purchasePad(player, pad.id, { free = true })
			if ok then
				bought += 1
			end
		end
	end
	task.wait(1)
	return HttpService:JSONEncode({ bought = bought, area = if profile ~= nil then profile.tycoon.area else -1 })
elseif COMMAND == "producer_view" then
	-- WORLD's first producer anchor (camera framing for the R61 upgrade shot) + the plot entrance.
	local plotIndex = PlotService.getPlotIndex(player)
	local builder = PlotBuilder.world(WORLD)
	local producerId = def.economy.Producers[1].id
	local okAnchor, anchor = pcall(builder.getProducerAnchor, plotIndex, producerId)
	local okEntrance, entrance = pcall(builder.entrance, plotIndex)
	local position = if okAnchor and anchor ~= nil then (anchor :: BasePart).Position else nil
	return HttpService:JSONEncode({
		producer = producerId,
		position = if position ~= nil then { position.X, position.Y, position.Z } else nil,
		entrance = if okEntrance and typeof(entrance) == "CFrame"
			then { entrance.Position.X, entrance.Position.Y, entrance.Position.Z }
			else nil,
	})
elseif COMMAND == "until_finale" then
	local TycoonService = (require :: any)(Server.Tycoon.TycoonService)
	local bought = 0
	for _ = 1, #def.economy.PadOrder do
		local padId = nextPadOf(player)
		if padId == nil or padId == def.economy.FinalePadId then
			break
		end
		local ok = TycoonService.purchasePad(player, padId, { free = true })
		if not ok then
			break
		end
		bought += 1
	end
	local view = padView(nextPadOf(player))
	view.bought = bought
	return HttpService:JSONEncode(view)
elseif COMMAND == "portal_view" then
	local HubBuilder = (require :: any)(Server.World.HubBuilder)
	local out = {}
	for _, side in { "main", "world" } do
		local portal = HubBuilder.getWorldPortal(WORLD, side)
		if portal ~= nil and portal.trigger ~= nil then
			local cf: CFrame = portal.trigger.CFrame
			out[side] = {
				centre = { cf.Position.X, cf.Position.Y, cf.Position.Z },
				look = { cf.LookVector.X, cf.LookVector.Y, cf.LookVector.Z },
			}
		end
	end
	return HttpService:JSONEncode(out)
elseif COMMAND == "npm_state" then
	local WorldService = (require :: any)(Server.Tycoon.WorldService)
	local TycoonConfig = (require :: any)(ReplicatedStorage.Shared.Config.TycoonConfig)
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return "ERROR no profile"
	end
	local plotIndex = PlotService.getPlotIndex(player)
	local plots = workspace:FindFirstChild("Plots")
	local plot = if plots ~= nil and plotIndex ~= nil then plots:FindFirstChild(`Plot{plotIndex}`) else nil
	local firstProducer = TycoonConfig.Producers[1].id
	local anchorPart: Instance? = nil
	if plot ~= nil then
		for _, item in plot:GetDescendants() do
			if item:GetAttribute("ProducerId") == firstProducer and item:GetAttribute("CycleTime") ~= nil then
				anchorPart = item
				break
			end
		end
	end
	local function sample(): { [string]: any }
		local part = anchorPart
		return {
			automated = if part ~= nil then part:GetAttribute("Automated") else nil,
			cycleStart = if part ~= nil then part:GetAttribute("CycleStart") else nil,
			cash = profile.cash,
		}
	end
	local first = sample()
	task.wait(3)
	local second = sample()
	local state = if type(profile.worlds) == "table" then profile.worlds[WORLD] else nil
	return HttpService:JSONEncode({
		attribute = player:GetAttribute("NewPlayerMode") == true,
		sandbox = PlayerDataService.isNewPlayerMode(player),
		cash = profile.cash,
		gems = profile.gems,
		rebirths = profile.rebirths,
		pads = count(profile.tycoon.pads),
		area = profile.tycoon.area,
		tutorialStep = profile.tycoon.tutorialStep,
		world = if type(state) == "table"
			then {
				unlocked = state.unlocked,
				cash = state.cash,
				area = state.tycoon.area,
				pads = count(state.tycoon.pads),
				rebirths = state.rebirths,
				visits = state.stats.visits,
			}
			else nil,
		worldUnlocked = WorldService.isUnlocked(player, WORLD),
		plotDescendants = if plot ~= nil then #plot:GetDescendants() else -1,
		producer = { id = firstProducer, found = anchorPart ~= nil, before = first, after = second },
	})
elseif COMMAND == "npm_producer" then
	-- New Player Mode: buy Nuke Town's first pad (the first producer) and watch it 5 s with no
	-- click: does a cycle start / pay by itself (owner R64 asks a true new player to click)?
	local TycoonService = (require :: any)(Server.Tycoon.TycoonService)
	local TycoonConfig = (require :: any)(ReplicatedStorage.Shared.Config.TycoonConfig)
	local profile = PlayerDataService.getProfile(player)
	local pad = TycoonConfig.PadOrder[1]
	local ok, why = TycoonService.purchasePad(player, pad.id)
	task.wait(2)
	local plotIndex = PlotService.getPlotIndex(player)
	local plots = workspace:FindFirstChild("Plots")
	local plot = if plots ~= nil and plotIndex ~= nil then plots:FindFirstChild(`Plot{plotIndex}`) else nil
	local anchorPart: Instance? = nil
	if plot ~= nil then
		for _, item in plot:GetDescendants() do
			if item:GetAttribute("ProducerId") == pad.target and item:GetAttribute("CycleTime") ~= nil then
				anchorPart = item
				break
			end
		end
	end
	local samples = {}
	for _ = 1, 6 do
		table.insert(samples, {
			automated = if anchorPart ~= nil then anchorPart:GetAttribute("Automated") else nil,
			cycleStart = if anchorPart ~= nil then anchorPart:GetAttribute("CycleStart") else nil,
			cycleTime = if anchorPart ~= nil then anchorPart:GetAttribute("CycleTime") else nil,
			cash = if profile ~= nil then profile.cash else nil,
		})
		task.wait(1)
	end
	return HttpService:JSONEncode({ pad = pad.id, ok = ok, why = why, found = anchorPart ~= nil, samples = samples })
elseif COMMAND == "restore" then
	local profile = PlayerDataService.getProfile(player)
	local snapshot = state.snapshot
	if profile == nil or snapshot == nil then
		return "ERROR nothing to restore"
	end
	if snapshot.world ~= nil and type(profile.worlds) == "table" then
		profile.worlds[WORLD] = deepCopy(snapshot.world)
	end
	profile.lastWorld = snapshot.lastWorld or "main"
	PlayerDataService.markChanged(player, true, { "worlds", "worldCash", "lastWorld" })
	local rebuilt = dispatch(player, 11, 0)
	local home = dispatch(player, 12, 0)
	state.snapshot = nil
	return HttpService:JSONEncode({ rebuilt = rebuilt, home = home, summary = worldSummary(player) })
end
return `ERROR unknown command {COMMAND}`
