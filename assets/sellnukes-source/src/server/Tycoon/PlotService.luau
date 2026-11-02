--!strict
--[[
	PlotService — who owns which plot, and everything about a plot that is not the tycoon itself:
	claiming / releasing, the owner sign, the filtered stand name, respawning at the plot,
	TeleportHub and TeleportPlot.

	Lifecycle (owner rule R13: the hub is the lobby)
		Start      builds the hub (HubBuilder) and the 8 empty plots (PlotBuilder), connects remotes.
		Spawn      characters spawn in the hub (HubBuilder's SpawnLocation at HubLayout.spawn).
		Profile    PlayerDataService.ProfileLoaded → claim a RANDOM free plot (uniform over the free
		           plots, server Random; queue when all 8 are taken — never errors), set the owner
		           sign, publish Player attributes PlotIndex, PlotAssignedAt (server
		           time) and PlotRevealSeconds, fire PlotAssigned (TycoonService restores the saved
		           tycoon on whatever plot it is; the plot model's PlotReady attribute turns true
		           once the bought builds are placed). Owner rule R16: the loading screen covers the
		           join, then the client plays its reveal and fires PlotRevealDone (rate limited,
		           only during a pending reveal) — the character is walked to the plot entrance and
		           PlotRevealed = true. Fallback: RevealFallbackSeconds (60) after the assignment.
		           Respawns after that go to the entrance.
		           A SECOND ProfileLoaded for the same player (New Player Mode sandbox swap) releases
		           and re-claims, so the plot is torn down and rebuilt from the new profile.
		Leave      PlayerRemoving / ProfileUnloading → fire PlotReleased, clear the plot, free it,
		           hand it to the next queued player.

	Remotes
		RenameStand(text)  needs the StandRename feature (Nuke Stand's Neon Sign); UTF-8 checked,
		                   ≤ 24 chars, rate limited, filtered with TextService (broadcast context)
		                   BEFORE it is saved or shown; the unfiltered text is never stored; the
		                   feature is re-checked after the filter yield. A saved name is RE-filtered
		                   (once per session) before it is shown again (applyStandName).
		RenamePlot(text)   owner R88: the plot name on the entrance sign of every world (no unlock;
		                   "" = reset to "<DisplayName>'s Nukes"). Handled by Tycoon/PlotNames
		                   (validate + normalize, rate limit, broadcast filter, censored names
		                   refused, re-checks after the yield, saved as profile.plotName — survives
		                   Rebirth); claim re-applies the saved name (re-filtered once per session).
		TeleportHub()      to the hub spawn (rate limited).
		PlotRevealDone()   ends the caller's pending plot reveal (walk home).
		TeleportPlot(i)    to plot i's entrance: own plot free, others need the Teleporter pass;
		                   rate limited + 5 s cooldown.
		Hub plot pads      none since owner R134 (2026-11-01, "can we remove these little
		                   teleports"): no hub in any world has plot teleport pads. Players walk to
		                   a plot or use the Teleport menu (TeleportHub / TeleportArea / TeleportPlot,
		                   WorldService travel); the plot reveal still walks a new player home.
		TeleportHub / TeleportPlot from another world are routed through WorldService.travel (the
		warp, streaming and CurrentWorld stay correct); in Nuke Town they work exactly as before.

	Worlds (owner R57, spec §5)
		One plot index per player for EVERY world: claim / release set + clear plot i in Nuke Town
		and in each WorldsConfig.extra() world (owner sign). Start builds every extra
		world's hub (HubBuilder.buildWorld) and its 8 empty plot frames (PlotBuilder.createWorldPlots).
		WorldService installs setWorldHooks in its Init (it requires this module, so this module never
		requires it): respawnCFrame (a respawn in Dino Valley lands on the Valley plot, streamed
		first), route (TeleportHub / TeleportPlot / TeleportArea from another world), currentWorld.

	API (other services)
		getPlotIndex(player): number?        getOwner(index): Player?
		reserveBotPlot(key, label) / releaseBotPlot(index) / botAt(index) / setBotEvictor(fn)
		                                     admin attack test bots (owner R51; players always win)
		PlotAssigned: Signal(player, index)  PlotReleased: Signal(player, index)
		teleport(player, cf): boolean        entrance(index): CFrame
		applyStandName(player)               re-shows the saved name (after a rebuild)
		setWorldHooks(hooks)                 WorldService only (Init)
		routeTravel(player, worldId, target, index?): boolean   true when WorldService took the
		                                     teleport (the player is in another world); false =
		                                     run the caller's own same-world teleport

	Usage
		PlotService.PlotAssigned:Connect(function(player, index) ... end)
		local index = PlotService.getPlotIndex(player)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local HubBuilder = require(script.Parent.Parent.World.HubBuilder)
local MonetizationService = require(script.Parent.Parent.Services.MonetizationService)
local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)
-- Owner R88: the owner-chosen plot name on every world's entrance sign (RenamePlot remote).
local PlotNames = require(script.Parent.PlotNames)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TravelRules = require(script.Parent.TravelRules)
local TycoonAnalytics = require(script.Parent.TycoonAnalytics)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

--[[
	What WorldService plugs in (setWorldHooks). Every hook is called guarded (pcall); without
	hooks PlotService behaves exactly like the single-world game.
		respawnCFrame(player)   ground CFrame of the respawn in the player's CURRENT world, nil = Nuke Town
		route(player, worldId, target, index?)   true = WorldService travels the player (another world)
		currentWorld(player)    "main" | "dino" | ...
	(The R57 `visit` hook went with the hub plot pads, owner R134: a visitor's Teleport-menu trip
	builds the visited owner's world plot inside WorldService.travel.)
]]
export type WorldHooks = {
	respawnCFrame: (player: Player) -> CFrame?,
	route: (player: Player, worldId: string, target: string, index: number?) -> boolean,
	currentWorld: (player: Player) -> string,
}

local PlotService = {}

PlotService.PlotAssigned = Signal.new() :: Signal.Signal<Player, number>
PlotService.PlotReleased = Signal.new() :: Signal.Signal<Player, number>

-- Stand name length cap (matches ProfileLogic's MaxStandNameChars).
PlotService.MaxStandNameChars = 24

local owners: { [number]: Player } = {}
local plotOf: { [Player]: number } = {}
-- Plots held by owner-admin attack TEST BOTS (owner R51; Server/Attack/TestBots): index → bot key.
-- Never a Player, never saved. A real player who needs a plot always wins (evictBot).
local botPlots: { [number]: string } = {}
-- Called with (botKey, index) when a joining player needs a bot's plot (TestBots removes the bot).
local botEvictor: ((key: string, index: number) -> ())? = nil
local queue: { Player } = {}
local renaming: { [Player]: boolean } = {}

-- Length of the client's plot reveal animation (published as PlotRevealSeconds; a hint only).
PlotService.RevealSeconds = 3
-- Owner rule R16: the loading screen covers the join, the reveal plays after it, and the CLIENT
-- ends the reveal (PlotRevealDone). This server fallback walks the player home anyway if no
-- PlotRevealDone arrives within this many seconds of the assignment (nobody stays stranded).
PlotService.RevealFallbackSeconds = 60
-- Seconds between successful TeleportPlot teleports (per player).
PlotService.TeleportPlotCooldown = 5

local rng = Random.new()
local revealed: { [Player]: boolean } = {}
local revealTokens: { [Player]: number } = {}

local renameLimiter = RateLimiter.new(2, 1 / 15) -- 2 renames, then one per 15 s
-- Stand names re-filtered for display this session: player → { source = saved text, shown = the
-- re-filtered text on the sign }. Saved names are re-filtered before other players see them again
-- (security audit 2026-10-30: stored text is filtered on display, not trusted from an old session).
local displayed: { [Player]: { source: string, shown: string } } = {}
-- Bumped per apply so a slow filter call can never overwrite a newer name.
local displayToken: { [Player]: number } = {}
local revealLimiter = RateLimiter.new(3, 1)
local teleportPlotLimiter = RateLimiter.new(3, 0.5)
local teleportPlotAt: { [Player]: number } = {}
local teleportLimiter = RateLimiter.new(3, 0.5)
-- WorldService's hooks (nil until its Init ran / when the worlds service is missing).
local worldHooks: WorldHooks? = nil

--[[ The plot a player owns, or nil. ]]
function PlotService.getPlotIndex(player: Player): number?
	return plotOf[player]
end

--[[ The owner of a plot, or nil. ]]
function PlotService.getOwner(index: number): Player?
	return owners[index]
end

--[[ World CFrame of a plot's respawn point (ground level; HubLayout's plot-frame entrance). ]]
function PlotService.entrance(index: number): CFrame
	return PlotBuilder.entrance(index)
end

--[[
	Moves a player's character to a ground-level CFrame (lifted by its hip height so it lands on
	its feet). Returns false when the character is not ready.
	@param player Player
	@param cf CFrame — ground-level target
	@return boolean
]]
function PlotService.teleport(player: Player, cf: CFrame): boolean
	local character = player.Character
	if character == nil then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") or humanoid.Health <= 0 then
		return false
	end
	local lift = humanoid.HipHeight + root.Size.Y / 2 + 0.25
	character:PivotTo(cf * CFrame.new(0, lift, 0))
	return true
end

--[[
	WorldService installs its hooks here (in its Init). PlotService never requires WorldService
	(WorldService requires PlotService), so the worlds reach plots through these.
	@param hooks WorldHooks? — nil removes them (tests / Studio hot reload)
]]
function PlotService.setWorldHooks(hooks: WorldHooks?)
	worldHooks = hooks
end

-- The world a player is in ("main" when WorldService is missing or its hook fails).
local function currentWorldOf(player: Player): string
	local hooks = worldHooks
	if hooks == nil then
		return WorldsConfig.MAIN
	end
	local ok, worldId = pcall(hooks.currentWorld, player)
	return if ok and type(worldId) == "string" then worldId else WorldsConfig.MAIN
end

--[[
	Hands a teleport to WorldService when the player is in ANOTHER world than `worldId` (the trip
	needs the warp, streaming and the CurrentWorld switch). Same world → false: the caller runs its
	own teleport exactly as before. TycoonService's TeleportArea uses it too.
	@param worldId string — destination world ("main" for every legacy teleport remote)
	@param target "spawn" | "area" | "plot"
	@param index number? — area / plot index (validated by the caller and again by WorldService)
	@return boolean — true when WorldService took it
	Example: if PlotService.routeTravel(player, "main", "area", 4) then return end
]]
function PlotService.routeTravel(player: Player, worldId: string, target: string, index: number?): boolean
	local hooks = worldHooks
	if hooks == nil or currentWorldOf(player) == worldId then
		return false
	end
	local ok, taken = pcall(hooks.route, player, worldId, target, index)
	return ok and taken == true
end

--[[
	A world's plot builder, or nil when it is missing / broken (guarded: a world's plot code can
	never break Nuke Town's claim / release).
]]
local function worldBuilder(worldId: string): any
	local ok, builder = pcall(PlotBuilder.world, worldId)
	return if ok and type(builder) == "table" then builder else nil
end

-- Calls builder[fnName](...) of an extra world's plot builder, guarded + warned.
local function worldCall(worldId: string, fnName: string, ...: any)
	local builder = worldBuilder(worldId)
	local fn = if builder ~= nil then builder[fnName] else nil
	if type(fn) ~= "function" then
		return
	end
	local ok, problem = pcall(fn, ...)
	if not ok then
		warn(`[PlotService] {worldId} plot {fnName} failed: {problem}`)
	end
end

--[[
	Plot `index` changes hands in every EXTRA world (spec §5: one index per player everywhere):
	the owner sign there. `owner` nil = free (also clears the plot there).
	Nuke Town's own plot is handled by claim / release as before.
]]
local function setWorldOwners(index: number, owner: Player?)
	for _, def in WorldsConfig.extra() do
		if owner == nil then
			worldCall(def.id, "clear", index)
		end
		worldCall(def.id, "setOwner", index, owner)
	end
end

--[[
	Respawns: in the hub until the plot reveal finished, then at the owned plot's entrance — in the
	world the player is in (WorldService.respawnCFrame: Dino Valley respawns stay in the Valley,
	streamed around the landing spot first so the character never falls through unstreamed ground).
]]
local function onCharacterAdded(player: Player, character: Model)
	task.defer(function()
		local root = character:WaitForChild("HumanoidRootPart", 10)
		local index = plotOf[player]
		if root == nil or index == nil or not revealed[player] or player.Character ~= character then
			return
		end
		local hooks = worldHooks
		if hooks ~= nil then
			local ok, worldCf = pcall(hooks.respawnCFrame, player)
			if ok and typeof(worldCf) == "CFrame" then
				local target: CFrame = worldCf
				pcall(function()
					player:RequestStreamAroundAsync(target.Position, TravelRules.StreamTimeout)
				end)
				if player.Character == character and plotOf[player] == index then
					PlotService.teleport(player, target)
				end
				return
			end
		end
		PlotService.teleport(player, PlotService.entrance(index))
	end)
end

-- A uniformly random free plot index, or nil when all are taken.
local function freePlot(): number?
	local free: { number } = {}
	for index = 1, WorldLayout.PlotCount do
		if owners[index] == nil and botPlots[index] == nil then
			table.insert(free, index)
		end
	end
	if #free == 0 then
		return nil
	end
	return free[rng:NextInteger(1, #free)]
end

--[[
	Ends a player's plot reveal (once): walk the character to the plot entrance, PlotRevealed = true.
	`token` must match the pending reveal (a stale timer from a previous claim does nothing).
]]
local function finishReveal(player: Player, token: number?)
	if revealed[player] or plotOf[player] == nil then
		return
	end
	if token ~= nil and revealTokens[player] ~= token then
		return
	end
	revealed[player] = true
	if player.Parent == Players then
		player:SetAttribute("PlotRevealed", true)
		PlotService.teleport(player, PlotService.entrance(plotOf[player] :: number))
	end
end

-- Claims a free plot for a player with a loaded profile (queues when the server is full).
local function claim(player: Player)
	if plotOf[player] ~= nil or player.Parent ~= Players then
		return
	end
	local index = freePlot()
	if index == nil then
		-- Owner R51: test bots never keep a real player out — evict one and take its plot.
		local botIndex = next(botPlots)
		if botIndex ~= nil then
			local key = botPlots[botIndex]
			botPlots[botIndex] = nil
			if botEvictor ~= nil then
				pcall(botEvictor, key, botIndex)
			end
			PlotBuilder.clear(botIndex)
			PlotBuilder.setOwner(botIndex, nil)
			index = botIndex
		end
	end
	if index == nil then
		if not table.find(queue, player) then
			table.insert(queue, player)
			PlayerDataService.notify(player, "All plots are busy - you'll get one as soon as it frees up!", "info")
		end
		return
	end
	owners[index] = player
	plotOf[player] = index
	revealed[player] = false
	local token = (revealTokens[player] or 0) + 1
	revealTokens[player] = token
	PlotBuilder.setOwner(index, player)
	-- The same index is theirs in every other world (the owner signs there).
	setWorldOwners(index, player)
	-- Owner R88: their saved plot name back on the sign in every world (re-filtered once per session).
	PlotNames.apply(player)
	-- Reveal: the client sees the assignment through these attributes (PlotIndex last).
	player:SetAttribute("PlotRevealed", false)
	player:SetAttribute("PlotRevealSeconds", PlotService.RevealSeconds)
	player:SetAttribute("PlotAssignedAt", Workspace:GetServerTimeNow())
	player:SetAttribute("PlotIndex", index)
	TycoonAnalytics.call("plotAssigned", player, index)
	PlotService.PlotAssigned:Fire(player, index)
	task.delay(PlotService.RevealFallbackSeconds, finishReveal, player, token)
end

-- Releases a player's plot (leave / profile swap) and serves the queue.
local function release(player: Player)
	local queued = table.find(queue, player)
	if queued ~= nil then
		table.remove(queue, queued)
	end
	local index = plotOf[player]
	if index == nil then
		return
	end
	PlotService.PlotReleased:Fire(player, index)
	plotOf[player] = nil
	owners[index] = nil
	revealed[player] = nil
	if player.Parent == Players then
		player:SetAttribute("PlotIndex", 0)
		player:SetAttribute("PlotRevealed", false)
	end
	PlotBuilder.clear(index)
	PlotBuilder.setOwner(index, nil)
	-- Spec §5 "Leave": PlotReleased clears that index in every world.
	setWorldOwners(index, nil)
	-- Hand the plot to the longest-waiting player whose profile is loaded.
	while #queue > 0 do
		local nextPlayer = table.remove(queue, 1) :: Player
		if nextPlayer.Parent == Players and PlayerDataService.getProfile(nextPlayer) ~= nil then
			claim(nextPlayer)
			break
		end
	end
end

--[[
	Owner R51 (admin attack test bots, Server/Attack/TestBots): reserves a FREE plot for a bot.
	Never takes a player's plot; nil when none is free. The plot sign shows `label`.
	@param key string — the bot's unique key ("bot:3")
	@param label string — sign text ("TestBot 3 (BOT)")
	@return number? — the plot index
]]
function PlotService.reserveBotPlot(key: string, label: string): number?
	local index = freePlot()
	if index == nil then
		return nil
	end
	botPlots[index] = key
	PlotBuilder.setOwner(index, nil)
	PlotBuilder.setSignLabel(index, label)
	return index
end

--[[ Frees a bot's plot (clears it, resets the sign) and serves the join queue. ]]
function PlotService.releaseBotPlot(index: number)
	if botPlots[index] == nil then
		return
	end
	botPlots[index] = nil
	PlotBuilder.clear(index)
	PlotBuilder.setOwner(index, nil)
	while #queue > 0 do
		local nextPlayer = table.remove(queue, 1) :: Player
		if nextPlayer.Parent == Players and PlayerDataService.getProfile(nextPlayer) ~= nil then
			claim(nextPlayer)
			break
		end
	end
end

--[[ The bot key holding plot `index` (nil = none). ]]
function PlotService.botAt(index: number): string?
	return botPlots[index]
end

--[[ TestBots registers how an evicted bot is torn down (a joining player needed its plot). ]]
function PlotService.setBotEvictor(fn: (key: string, index: number) -> ())
	botEvictor = fn
end

-- Filters `text` from `player` for everyone to see (yields). nil when the filter fails (fail closed).
local function filterForBroadcast(player: Player, text: string): string?
	local ok, filtered = pcall(function(): string
		local result = TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat)
		return result:GetNonChatStringForBroadcastAsync()
	end)
	return if ok and type(filtered) == "string" then filtered else nil
end

--[[
	Re-shows a player's saved stand name on their plot (after a claim / rebuild / rebirth). A name
	saved in an earlier session is RE-FILTERED (TextService, owner's UserId) before other players
	see it again — once per session per saved text, cached in `displayed`; until the filter
	answers (or if it fails: fail closed) the sign shows the default name. Never yields (the
	filter runs in its own thread).
]]
function PlotService.applyStandName(player: Player)
	local index = plotOf[player]
	local profile = PlayerDataService.getProfile(player)
	if index == nil or profile == nil then
		return
	end
	local saved = profile.tycoon.standName
	if type(saved) ~= "string" or saved == "" then
		PlotBuilder.setStandName(index, "")
		return
	end
	local cached = displayed[player]
	if cached ~= nil and cached.source == saved then
		PlotBuilder.setStandName(index, cached.shown)
		return
	end
	PlotBuilder.setStandName(index, "") -- default name while the saved one is re-checked
	local token = (displayToken[player] or 0) + 1
	displayToken[player] = token
	task.spawn(function()
		local filtered = filterForBroadcast(player, saved)
		-- Still the same player, plot, profile, saved name and newest request?
		if
			player.Parent ~= Players
			or displayToken[player] ~= token
			or plotOf[player] ~= index
			or PlayerDataService.getProfile(player) ~= profile
			or profile.tycoon.standName ~= saved
		then
			return
		end
		local shown = filtered or ""
		displayed[player] = { source = saved, shown = shown }
		PlotBuilder.setStandName(index, shown)
	end)
end

-- RenameStand(text): validate, require the feature, filter for broadcast, save, show. The silent
-- checks (malformed text, no plot / profile) run BEFORE the rate limiter, so a typo never costs a
-- rename token; anything that answers with a toast stays behind the limiter (no toast spam).
local function onRename(player: Player, rawText: unknown)
	if renaming[player] then
		return
	end
	local text = Validate.text(rawText, PlotService.MaxStandNameChars)
	local profile = PlayerDataService.getProfile(player)
	local index = plotOf[player]
	if text == nil or text == "" or profile == nil or index == nil then
		return
	end
	if not renameLimiter:Allow(player) then
		return
	end
	if not TycoonLogic.hasFeature(profile.tycoon, "StandRename") then
		PlayerDataService.notify(player, "Buy the Neon Sign at your Nuke Stand to rename it!", "error")
		return
	end
	renaming[player] = true
	local filtered = filterForBroadcast(player, text)
	renaming[player] = nil
	-- The filter yields: re-check the player, plot, profile AND the feature (a Rebirth during the
	-- filter call replaces profile.tycoon).
	if
		player.Parent ~= Players
		or plotOf[player] ~= index
		or PlayerDataService.getProfile(player) ~= profile
		or not TycoonLogic.hasFeature(profile.tycoon, "StandRename")
	then
		return
	end
	if filtered == nil then
		PlayerDataService.notify(player, "Couldn't check that name right now - try again!", "error")
		return
	end
	-- A fresh rename is shown at once and cached, so applyStandName never re-filters it this session.
	displayed[player] = { source = filtered, shown = filtered }
	displayToken[player] = (displayToken[player] or 0) + 1
	profile.tycoon.standName = filtered
	PlayerDataService.markChanged(player, true, { "tycoon" })
	PlotBuilder.setStandName(index, filtered)
	TycoonAnalytics.call("tycoon", player, "rename")
	PlayerDataService.notify(player, "Your stand has a new name!", "success")
end

-- TeleportHub(): to the hub spawn (from another world: WorldService's trip to the lobby).
local function onTeleportHub(player: Player)
	if not teleportLimiter:Allow(player) then
		return
	end
	if PlotService.routeTravel(player, WorldsConfig.MAIN, "spawn", nil) then
		return
	end
	if PlotService.teleport(player, HubBuilder.spawnCFrame()) then
		TycoonAnalytics.call("tycoon", player, "teleportHub")
	end
end

--[[
	TeleportPlot(plotIndex): to a plot's entrance. Your own plot is free; any OTHER player's plot
	needs the Teleporter game pass (lead rule 2026-10-30). Validated integer, the plot must be
	owned, rate limited, and a TeleportPlotCooldown between successful teleports.
]]
local function onTeleportPlot(player: Player, rawIndex: unknown)
	if not teleportPlotLimiter:Allow(player) then
		return
	end
	local index = Validate.integer(rawIndex, 1, WorldLayout.PlotCount)
	if index == nil or owners[index] == nil then
		return
	end
	-- From another world: WorldService's trip (same pass + cooldown rules, TravelRules).
	if PlotService.routeTravel(player, WorldsConfig.MAIN, "plot", index) then
		return
	end
	if owners[index] ~= player and not MonetizationService.ownsPass(player, "Teleporter") then
		PlayerDataService.notify(player, "Get the Teleporter pass to visit other plots!", "info")
		return
	end
	local now = os.clock()
	if now - (teleportPlotAt[player] or -math.huge) < PlotService.TeleportPlotCooldown then
		return
	end
	if PlotService.teleport(player, PlotService.entrance(index)) then
		teleportPlotAt[player] = now
		TycoonAnalytics.call("tycoon", player, if owners[index] == player then "teleportHome" else "teleportPlot")
	end
end

function PlotService.Init() end

function PlotService.Start()
	-- Owner R88 plot names first: a claim below (Studio hot start) already re-applies saved names.
	PlotNames.start({ getPlotIndex = PlotService.getPlotIndex, filter = filterForBroadcast })
	-- The lobby + the 8 Nuke Town plots. Owner R134: hubs have no plot teleport pads to connect.
	HubBuilder.build()
	PlotBuilder.createPlots()
	-- Every extra world (spec §5): its hub (Base Camp) + 8 empty plot frames, built at boot like
	-- Nuke Town's (static + streamed). Guarded: a broken world never stops Nuke Town from booting.
	for _, def in WorldsConfig.extra() do
		local worldId = def.id
		local built, problem = pcall(HubBuilder.buildWorld, worldId)
		if not built then
			warn(`[PlotService] {worldId} hub failed to build: {problem}`)
		end
		local framed, frameProblem = pcall(PlotBuilder.createWorldPlots, worldId)
		if not framed then
			warn(`[PlotService] {worldId} plot frames failed to build: {frameProblem}`)
		end
	end

	PlayerDataService.ProfileLoaded:Connect(function(player: Player)
		if plotOf[player] ~= nil then
			-- Same player, new profile (New Player Mode sandbox swap): tear down and rebuild.
			release(player)
		end
		claim(player)
	end)
	local unloading = (PlayerDataService :: any).ProfileUnloading
	if unloading ~= nil then
		unloading:Connect(function(player: Player)
			release(player)
		end)
	end

	local function onPlayer(player: Player)
		player:SetAttribute("PlotIndex", 0)
		player.CharacterAdded:Connect(function(character: Model)
			onCharacterAdded(player, character)
		end)
		if PlayerDataService.getProfile(player) ~= nil then
			claim(player) -- profile already loaded before this service started (Studio hot start)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		release(player)
		revealTokens[player] = nil
		teleportPlotAt[player] = nil
		revealLimiter:Forget(player)
		teleportPlotLimiter:Forget(player)
		renameLimiter:Forget(player)
		teleportLimiter:Forget(player)
		renaming[player] = nil
		displayed[player] = nil
		displayToken[player] = nil
		PlotNames.forget(player)
	end)

	Remotes.onServerEvent("RenameStand", onRename)
	Remotes.onServerEvent("TeleportHub", onTeleportHub)

	-- PlotRevealDone (C→S, no arguments): the client's loading screen + plot reveal finished or was
	-- skipped. Ends only the caller's PENDING reveal (rate limited).
	Remotes.onServerEvent("PlotRevealDone", function(player: Player)
		if revealLimiter:Allow(player) and revealed[player] == false then
			finishReveal(player, nil)
		end
	end)

	-- TeleportPlot(plotIndex) (C→S, declared by B17-core): own plot free, others need the pass.
	Remotes.onServerEvent("TeleportPlot", onTeleportPlot)
end

return PlotService
