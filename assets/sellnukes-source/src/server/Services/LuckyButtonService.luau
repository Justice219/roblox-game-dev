--!strict
--[[
	LuckyButtonService — the server side of the Lucky Buttons (owner R69: "some buttons that are
	like 2x cash that just appear randomly throughout your plot"; spec
	docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md §1).

	Purpose:
		Per player, while they stand on their OWN plot (any world) and are not AFK, a button pops up
		at a random free spot of an unlocked, standing area — walkable ground under the whole button
		and ≥ Clearance from every pad / producer / building / prop / billboard / other button, read
		from the layout data the plot is built from (LuckyButtonLogic.slotGeometry): first 45–75 s after arriving on
		the plot, then 120–240 s after the previous one ended (x the admin interval multiplier). It
		lives 45 s. Walking into it claims it:
			free  cash burst (60 s of that world's income, floor = the current area's first pad) /
			      2 min 2x Cash / 2 min 2x Speed (BoostService)
			paid  owner R122: walking in opens the client's small DEAL card (never a prompt by
			      itself); its BUY sends LuckyButtonClaim(id, "buy") and only then the purchase
			      prompt goes through MonetizationService (source "lucky": New Player Mode,
			      Robux-off, "coming soon" and paid-random policy refusals all apply there), at most
			      once per button per PromptCooldown; the button stays until it expires or is bought
		Rules (LuckyButtonLogic): ≤ MaxLive per player, ≤ MaxPaidLive paid, the first button of a
		session is free, owned passes are never offered, products that are not live are never
		rolled, pack = that world's Large pack, skip = only with a next pad, New Player Mode = free.

	No server Instances (the Harvest turkey pattern, Server/Event/TurkeySpawner): the server keeps
	the buttons in tables and tells ONLY the owner (Remotes.fireClient "LuckyButtons"); the client
	draws pooled models (Client/LuckyButtons/LuckyButtonClient).

	Wire (S→C "LuckyButtons"):
		{ kind = "spawn",   button = LuckyButtonLogic.Wire }
		{ kind = "claimed", id, button = kindId, amount?, currency? }  free grant or a purchase
		{ kind = "expired", id }
		{ kind = "clear" }                                             world change / admin / off
	Claim (C→S "LuckyButtonClaim"): (id: string, action: string?) → RateLimiter, Validate.key, the
	player's own live button, LuckyButtonLogic.canClaim (same world, alive, character within
	ClaimRadius + ClaimSlack). No action = a walk-in (free kinds claim; paid kinds: nothing — the
	client shows the DEAL card). Owner R122 actions (paid kinds only, LuckyButtonConfig.Deal):
	"shown" / "close" = analytics (luckyDeal:<action>:<kind>, capped per button), "buy" = the
	prompt (canClaim with radius Deal.KeepRadius: the card stays up that far).

	Performance: ONE 1 Hz loop for every player (no per-button threads, no per-frame work); the
	placement geometry of a slot is built once per (world, plot, area) from layout data and cached;
	a roll tries at most MaxPicks pure point checks (no raycasts: plot colliders are CanQuery =
	false by design, see LuckyButtonLogic's slot-geometry section).

	Security: the client sends only the id of a button it walked into. Ownership, world, expiry,
	distance (server-side character position), amounts, kinds and products are all server-side.
	Purchases go through MonetizationService's normal prompt path and ProcessReceipt.

	Analytics (retention family): luckySpawned / luckyClaimed / luckyPrompted / luckyPurchased /
	luckyExpired :<kind>, owner R122 luckyDeal:<shown|buy|close>:<kind>. Admin (Server tab, Lazy.registerAdmin): LuckyToggle (kill switch
	attribute ReplicatedStorage.LuckyButtonsEnabled), LuckySpawn (a kind on a player now),
	LuckyInterval (spawn-interval multiplier attribute), LuckyClear, LuckyStatus (live counts).

	Connects to: Shared/Config/{LuckyButtonConfig, WorldLayout, BillboardSpots, MonetizationConfig,
	Worlds/WorldsConfig}, Shared/Tycoon/{LuckyButtonLogic, TycoonLogic}, Shared/Net/{Remotes,
	Validate}, Shared/Util/RateLimiter, Server/Services/{PlayerDataService, MonetizationService,
	BoostService}, Server/Tycoon/{TycoonService, WorldService, PlotService, Knockdown, AreaLayouts},
	Server/Economy/ProfileLogic, Server/Event/Lazy (analytics + admin).

	Example (admin / tests):
		LuckyButtonService.spawnFor(player, "boost2x") --> true, "L7"
		LuckyButtonService.clearAll()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local AreaLayouts = require(ServerScriptService.Server.Tycoon.AreaLayouts)
local BillboardSpots = require(ReplicatedStorage.Shared.Config.BillboardSpots)
local BoostService = require(script.Parent.BoostService)
local FtueConfig = require(ReplicatedStorage.Shared.Config.FtueConfig)
local Knockdown = require(ServerScriptService.Server.Tycoon.Knockdown)
local Lazy = require(ServerScriptService.Server.Event.Lazy)
local ProgressEvents = require(ServerScriptService.Server.Progression.ProgressEvents)
local LuckyButtonConfig = require(ReplicatedStorage.Shared.Config.LuckyButtonConfig)
local LuckyButtonLogic = require(ReplicatedStorage.Shared.Tycoon.LuckyButtonLogic)
local MeshAssets = require(ReplicatedStorage.Shared.Config.MeshAssets)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local MonetizationService = require(script.Parent.MonetizationService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local PlotService = require(ServerScriptService.Server.Tycoon.PlotService)
local ProfileLogic = require(ServerScriptService.Server.Economy.ProfileLogic)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonService = require(ServerScriptService.Server.Tycoon.TycoonService)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldService = require(ServerScriptService.Server.Tycoon.WorldService)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type Kind = LuckyButtonConfig.Kind
type KindId = LuckyButtonConfig.KindId

-- One live button (server truth; the wire is derived from it).
type Button = {
	id: string,
	kind: Kind,
	world: string,
	area: number,
	slotX: number, -- slot-local XZ (clearance against the player's other buttons)
	slotZ: number,
	position: Vector3, -- world-space ground point
	born: number, -- server unix time
	expires: number,
	amount: number?, -- `cash`: the grant (fixed at spawn, shown on the label)
	currency: string?, -- `cash`: the world's currency key
	product: string?, -- paid: MonetizationConfig key
	productType: LuckyButtonLogic.PromptType?,
	natural: boolean, -- spawned by the schedule (admin spawns never move the schedule)
	lastPromptAt: number,
	-- Owner R122: DEAL card reports counted for this button (luckyDeal:<action>, capped).
	dealReports: { [string]: number },
}

-- Per-player state (session only; nothing is saved).
type State = {
	buttons: { [string]: Button },
	world: string, -- the world the buttons / schedule belong to
	nextAt: number?, -- server time of the next roll (nil = arm on the next tick on the plot)
	spawned: number, -- buttons spawned this session (the first one is always free)
	lastActive: number, -- server time of the last activity (movement, claim, pad bought)
	lastRoot: Vector3?,
	-- Lucky prompts by MonetizationConfig key (luckyPurchased attribution window).
	prompts: { [string]: { at: number, kind: KindId } },
}

-- Server-wide counters for LuckyStatus.
-- Owner R122: deals = DEAL cards shown / BUY presses accepted / closed by the player.
type Counters = {
	spawned: number,
	claimed: number,
	prompted: number,
	purchased: number,
	expired: number,
	dealShown: number,
	dealBuy: number,
	dealClose: number,
}

local LuckyButtonService = {}

local states: { [Player]: State } = {}
local counters: Counters = {
	spawned = 0,
	claimed = 0,
	prompted = 0,
	purchased = 0,
	expired = 0,
	dealShown = 0,
	dealBuy = 0,
	dealClose = 0,
}
-- Placement diagnostics for LuckyStatus / QA: spot draws, areas with no valid spot at all ("gap":
-- packed / no ground), draws refused because the player's other button is too close ("blocked"),
-- placed, and rolls that had no standing unlocked area.
local placement = { picks = 0, gap = 0, blocked = 0, ok = 0, noAreas = 0 }
local nextId = 0
local rng = Random.new()
local claimLimiter = RateLimiter.new(LuckyButtonConfig.ClaimBurst, LuckyButtonConfig.ClaimPerSecond)
-- "world:plot:area" → slot-local placement geometry (static layout data, built once per slot) and
-- its valid grid spots (LuckyButtonLogic.validSpots, built on the slot's first roll).
local geometryCache: { [string]: LuckyButtonLogic.Geometry } = {}
local spotCache: { [string]: { Vector2 } } = {}
local started = false

-- ── Small helpers ────────────────────────────────────────────────────────────────────────────

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- The kill switch (admin): nil / true = on.
local function enabled(): boolean
	return ReplicatedStorage:GetAttribute(LuckyButtonConfig.EnabledAttribute) ~= false
end

-- The admin spawn-interval multiplier (attribute; clamped by LuckyButtonLogic.delay).
local function intervalMultiplier(): number
	local value = ReplicatedStorage:GetAttribute(LuckyButtonConfig.IntervalAttribute)
	return if type(value) == "number" then value else 1
end

-- Counts a retention analytics key (never errors / yields).
local function track(player: Player, family: string, kind: KindId)
	Lazy.analytics("retention", player, `{family}:{kind}`)
end

-- The character root position, or nil.
local function rootOf(player: Player): Vector3?
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root.Position else nil
end

--[[
	True while the player is on a guided first-minute tutorial step (owner R78 §6: build the
	Workbench, make the first nukes, buy the first upgrade). No button is armed meanwhile, so the
	first one's FirstDelay clock starts only after the first upgrade: nothing competes with the
	tutorial's one arrow.
]]
local function inGuidedTutorial(player: Player): boolean
	local profile: any = PlayerDataService.getProfile(player)
	local tycoon = if profile ~= nil then profile.tycoon else nil
	return type(tycoon) == "table" and FtueConfig.isGuided(tycoon.tutorialStep)
end

-- The player's tycoon state in a world (nil when not loaded / the world has no state yet).
local function tycoonOf(player: Player, world: string): any
	local profile: any = PlayerDataService.getProfile(player)
	if profile == nil then
		return nil
	end
	if world == WorldsConfig.MAIN then
		return profile.tycoon
	end
	local state: any = ProfileLogic.peekWorld(profile, world)
	return if state ~= nil then state.tycoon else nil
end

-- The wire of a button (what the owner's client draws).
local function wireOf(button: Button): LuckyButtonLogic.Wire
	return {
		id = button.id,
		kind = button.kind.id,
		world = button.world,
		position = button.position,
		born = button.born,
		expires = button.expires,
		amount = button.amount,
		product = button.product,
		productType = button.productType,
	}
end

-- Live / live-paid counts of a state.
local function counts(state: State): (number, number)
	local live, paid = 0, 0
	for _, button in state.buttons do
		live += 1
		if button.kind.paid then
			paid += 1
		end
	end
	return live, paid
end

-- A fresh per-player state.
local function newState(player: Player): State
	return {
		buttons = {},
		world = WorldService.currentWorld(player),
		nextAt = nil,
		spawned = 0,
		lastActive = serverNow(),
		lastRoot = nil,
		prompts = {},
	}
end

-- The state of a player (created on demand; nil for a player who left).
local function stateOf(player: Player): State?
	if player.Parent ~= Players then
		return nil
	end
	local state = states[player]
	if state == nil then
		state = newState(player)
		states[player] = state
	end
	return state
end

-- Removes a button; a natural one re-arms the schedule from now (spec: "after the previous ended").
local function endButton(state: State, button: Button, now: number)
	if state.buttons[button.id] == nil then
		return
	end
	state.buttons[button.id] = nil
	if button.natural then
		state.nextAt = now + LuckyButtonLogic.delay(rng:NextNumber(), false, intervalMultiplier())
	end
end

-- Clears every button of a player (and tells the client); the schedule re-arms on the plot.
local function clearPlayer(player: Player, state: State)
	local had = next(state.buttons) ~= nil
	table.clear(state.buttons)
	state.nextAt = nil
	if had then
		Remotes.fireClient("LuckyButtons", player, { kind = "clear" })
	end
end

-- ── Placement ────────────────────────────────────────────────────────────────────────────────

-- The plot frame of a world's hub layout (plot-local colliders + props), or nil (primitive plot).
local function frameOf(world: string): any
	local hub: any = if world == WorldsConfig.MAIN then Lazy.hubLayout() else AreaLayouts.worldHub(world)
	local frame = if type(hub) == "table" then hub.plotFrame else nil
	return if type(frame) == "table" then frame else nil
end

--[[
	The placement geometry of one area slot of one plot (cached): supports + solids from the area
	layout, its billboard spots, MeshAssets prop bounds and the world's plot frame, all in slot-local
	space (LuckyButtonLogic.slotGeometry; why layout data and not rays: see its section header —
	every plot collider / mesh is CanQuery = false, so world queries see nothing).
]]
local function geometryOf(world: string, plot: number, area: number): LuckyButtonLogic.Geometry
	local key = `{world}:{plot}:{area}`
	local cached = geometryCache[key]
	if cached ~= nil then
		return cached
	end
	local okLayout, layout = pcall(AreaLayouts.get, area, world)
	local spots: any = if world == WorldsConfig.MAIN
		then (BillboardSpots :: any)[area]
		else ((BillboardSpots :: any).worlds[world] or {})[area]
	local toSlot = WorldLayout.slotOrigin(plot, area, world):Inverse() * WorldLayout.plotOrigin(plot, world)
	local geometry = LuckyButtonLogic.slotGeometry({
		layout = if okLayout then layout else nil,
		spots = spots,
		frame = frameOf(world),
		toSlot = toSlot,
		plotHalfWidth = WorldLayout.PlotHalfWidth,
		plotLength = WorldLayout.plotLength(world),
		meshes = MeshAssets :: any,
	})
	geometryCache[key] = geometry
	return geometry
end

-- Unlocked areas of the player's run in a world that are not knocked down (Knockdown is a Nuke
-- Town system: other worlds have no knockdowns).
local function standingAreas(player: Player, world: string, tycoon: any): { number }
	local logic = TycoonLogic.forWorld(world)
	local list: { number } = {}
	for area = 1, WorldLayout.areaCount(world) do
		if logic.areaUnlocked(tycoon, area) then
			local down = world == WorldsConfig.MAIN and (Knockdown.isDown(player, area))
			if not down then
				table.insert(list, area)
			end
		end
	end
	return list
end

-- The valid grid spots of a slot (cached; empty for a packed slot such as a finale).
local function spotsOf(world: string, plot: number, area: number): { Vector2 }
	local key = `{world}:{plot}:{area}`
	local cached = spotCache[key]
	if cached ~= nil then
		return cached
	end
	local list = LuckyButtonLogic.validSpots(
		geometryOf(world, plot, area),
		LuckyButtonConfig.GridStep,
		WorldLayout.SlotHalfWidth,
		WorldLayout.SlotDepth
	)
	spotCache[key] = list
	return list
end

--[[
	Picks a spot: the standing areas in random order; in each, up to MaxPicks draws from its valid
	grid spots, jittered by ±Jitter (re-verified, else the grid point itself), that also keep
	Clearance from the player's other buttons. A roll fails only when no standing area has room.
	@return (area, slotX, slotZ, worldPosition) or nil
]]
local function pickSpot(
	state: State,
	world: string,
	plot: number,
	areas: { number }
): (number?, number, number, Vector3?)
	if #areas == 0 then
		placement.noAreas += 1
		return nil, 0, 0, nil
	end
	local order = table.clone(areas)
	for index = #order, 2, -1 do
		local swap = rng:NextInteger(1, index)
		order[index], order[swap] = order[swap], order[index]
	end
	for _, area in order do
		local spots = spotsOf(world, plot, area)
		if #spots == 0 then
			placement.gap += 1
			continue
		end
		local geometry = geometryOf(world, plot, area)
		-- The player's other buttons in that area keep Clearance too.
		local others: { LuckyButtonLogic.Obstacle } = {}
		for _, other in state.buttons do
			if other.area == area then
				table.insert(others, LuckyButtonLogic.point(other.slotX, other.slotZ, 0))
			end
		end
		for _ = 1, LuckyButtonConfig.MaxPicks do
			placement.picks += 1
			local spot = spots[rng:NextInteger(1, #spots)]
			local jitter = LuckyButtonConfig.Jitter
			local x = spot.X + rng:NextNumber(-jitter, jitter)
			local z = spot.Y + rng:NextNumber(-jitter, jitter)
			if not LuckyButtonLogic.spotOk(x, z, geometry, others) then
				x, z = spot.X, spot.Y
				if not LuckyButtonLogic.spotOk(x, z, geometry, others) then
					placement.blocked += 1
					continue
				end
			end
			placement.ok += 1
			-- On the ground plane (y = 0 in every slot) of THIS plot's slot in THIS world.
			return area, x, z, WorldLayout.slotPointToWorld(plot, area, Vector3.new(x, 0, z), world)
		end
	end
	return nil, 0, 0, nil
end

-- ── Spawning ─────────────────────────────────────────────────────────────────────────────────

-- The world's income per second: automated producers + the best manual producer's click rate.
local function incomeEstimate(player: Player, world: string, tycoon: any): number
	local auto = TycoonService.incomePerSecond(player, world)
	local mods = TycoonService.getModifiers(player, world)
	local logic = TycoonLogic.forWorld(world)
	local manual = 0
	for _, cfg in logic.index.Producers do
		local stats = logic.producerStats(tycoon, cfg.id, mods)
		if stats ~= nil and stats.built and not stats.automated and stats.cycle > 0 then
			manual = math.max(manual, stats.clickPayout / stats.cycle)
		end
	end
	return auto + manual
end

-- The free cash floor: the first pad cost of the player's current area in that world.
local function cashFloor(world: string, tycoon: any): number
	local logic = TycoonLogic.forWorld(world)
	local pads = logic.index.AreaPads[math.max(1, tycoon.area or 1)]
	local first = if pads ~= nil then pads[1] else nil
	return if first ~= nil and type(first.cost) == "number" then first.cost else 1
end

-- The roll context for a player (LuckyButtonLogic.RollContext).
local function rollContext(player: Player, state: State, world: string): LuckyButtonLogic.RollContext
	local live, paid = counts(state)
	local now = os.time()
	return {
		firstOfSession = state.spawned == 0,
		live = live,
		livePaid = paid,
		newPlayerMode = PlayerDataService.isNewPlayerMode(player),
		owns = function(passKey: string): boolean
			return MonetizationService.ownsPass(player, passKey)
		end,
		available = function(key: string, promptType: LuckyButtonLogic.PromptType): boolean
			-- id 0 = COMING SOON (never rolled); products must also be on sale right now.
			if promptType == "pass" then
				return MonetizationConfig.isPassAvailable(key)
			end
			return MonetizationConfig.isProductAvailable(key, now)
		end,
		packKey = LuckyButtonLogic.packFor(world, MonetizationConfig.Products, WorldsConfig.MAIN),
		hasNextPad = TycoonService.nextPad(player, world) ~= nil,
	}
end

--[[
	Spawns one button for a player now (schedule rolls and admin spawns).
	@param player Player
	@param state  the player's State
	@param forced an admin kind (skips the roll rules but still keeps the live cap), or nil
	@param natural true for a schedule spawn (moves the schedule)
	@return (ok, id or reason)
]]
local function spawn(player: Player, state: State, forced: Kind?, natural: boolean): (boolean, string)
	local world = state.world
	local plot = PlotService.getPlotIndex(player)
	local tycoon = tycoonOf(player, world)
	if plot == nil or tycoon == nil then
		return false, "no plot / run in this world"
	end
	local live = counts(state)
	if live >= LuckyButtonConfig.MaxLive then
		return false, "already at the live cap"
	end
	local kind = forced or LuckyButtonLogic.roll(rollContext(player, state, world), rng:NextNumber())
	if kind == nil then
		return false, "no kind allowed now"
	end
	local area, x, z, position = pickSpot(state, world, plot, standingAreas(player, world, tycoon))
	if area == nil or position == nil then
		return false, "no free ground spot"
	end
	local now = serverNow()
	nextId += 1
	local button: Button = {
		id = `{LuckyButtonConfig.IdPrefix}{nextId}`,
		kind = kind,
		world = world,
		area = area,
		slotX = x,
		slotZ = z,
		position = position,
		born = now,
		expires = now + LuckyButtonConfig.Lifetime,
		amount = nil,
		currency = nil,
		product = nil,
		productType = nil,
		natural = natural,
		lastPromptAt = -math.huge,
		dealReports = {},
	}
	if kind.income ~= nil then
		local def = WorldsConfig.get(world)
		button.currency = if def ~= nil then def.currency.key else "cash"
		button.amount =
			LuckyButtonLogic.cashAmount(incomeEstimate(player, world, tycoon), kind.income, cashFloor(world, tycoon))
	end
	if kind.paid then
		local packKey = LuckyButtonLogic.packFor(world, MonetizationConfig.Products, WorldsConfig.MAIN)
		local key, promptType = LuckyButtonLogic.productOf(kind, packKey)
		if key == nil then
			return false, "this world has no product for that kind"
		end
		button.product = key
		button.productType = promptType
	end
	state.buttons[button.id] = button
	state.spawned += 1
	if natural then
		state.nextAt = math.huge -- re-armed when this one ends
	end
	counters.spawned += 1
	Remotes.fireClient("LuckyButtons", player, { kind = "spawn", button = wireOf(button) })
	track(player, "luckySpawned", kind.id)
	return true, button.id
end

-- ── Loop ─────────────────────────────────────────────────────────────────────────────────────

-- One player's tick: world change, expiry, activity, schedule.
local function tickPlayer(player: Player, state: State, now: number, on: boolean)
	local world = WorldService.currentWorld(player)
	if world ~= state.world then
		clearPlayer(player, state)
		state.world = world
		state.lastActive = now
	end
	-- Expiry (silent: the client fades it out).
	for id, button in state.buttons do
		if now >= button.expires then
			endButton(state, button, now)
			counters.expired += 1
			Remotes.fireClient("LuckyButtons", player, { kind = "expired", id = id })
			track(player, "luckyExpired", button.kind.id)
		end
	end
	-- Activity: the character moved (claims and pad purchases also count, see Start).
	local root = rootOf(player)
	local last = state.lastRoot
	if root ~= nil and (last == nil or (root - last).Magnitude >= LuckyButtonConfig.ActivityMoveStuds) then
		state.lastActive = now
		state.lastRoot = root
	end
	if not on or root == nil then
		return
	end
	-- Spawns need the player on their own plot in this world, active, with a ready run.
	local plot = PlotService.getPlotIndex(player)
	if
		plot == nil
		or WorldLayout.worldAt(root) ~= world
		or WorldLayout.plotAt(root, world) ~= plot
		or LuckyButtonLogic.isAfk(state.lastActive, now)
		or inGuidedTutorial(player)
	then
		return
	end
	local nextAt = state.nextAt
	if nextAt == nil then
		state.nextAt = now + LuckyButtonLogic.delay(rng:NextNumber(), true, intervalMultiplier())
		return
	end
	if now < nextAt then
		return
	end
	local ok = spawn(player, state, nil, true)
	if not ok then
		-- Skipped roll (no spot / nothing allowed): try again after a normal delay.
		state.nextAt = now + LuckyButtonLogic.delay(rng:NextNumber(), false, intervalMultiplier())
	end
end

-- The 1 Hz loop body (every player; one player's error never stops the others).
local function step()
	local now = serverNow()
	local on = enabled()
	for _, player in Players:GetPlayers() do
		local state = stateOf(player)
		if state ~= nil then
			local ok, err = pcall(tickPlayer, player, state, now, on)
			if not ok then
				warn(`[LuckyButtonService] tick {player.UserId}: {err}`)
			end
		end
	end
end

-- ── Claims + purchases ───────────────────────────────────────────────────────────────────────

--[[
	Owner R122: counts one DEAL card report for `button` (at most Deal.MaxReportsPerButton per
	action per button, so a forged client can only add a few counts).
	@return true when it counted
]]
local function countDeal(player: Player, button: Button, action: string): boolean
	local reports = button.dealReports
	local count = reports[action] or 0
	if count >= LuckyButtonConfig.Deal.MaxReportsPerButton then
		return false
	end
	reports[action] = count + 1
	track(player, `luckyDeal:{action}`, button.kind.id)
	if action == "shown" then
		counters.dealShown += 1
	elseif action == "buy" then
		counters.dealBuy += 1
	else
		counters.dealClose += 1
	end
	return true
end

--[[
	Owner R122: a paid button's DEAL card action (the client's card; LuckyButtonConfig.Deal).
		shown / close  analytics only (capped per button)
		buy            the purchase prompt — the character must still be within Deal.KeepRadius
		               (+ ClaimSlack), one prompt per button per PromptCooldown
	@param action an allowlisted action (validated by the caller)
]]
local function onDeal(player: Player, state: State, button: Button, action: string, now: number)
	if action ~= "buy" then
		if action == "shown" then
			-- The card shows on a walk-in: the player must really be there.
			local near = LuckyButtonLogic.canClaim(button, {
				world = WorldService.currentWorld(player),
				now = now,
				root = rootOf(player),
				radius = LuckyButtonConfig.Deal.KeepRadius,
			})
			if not near then
				return
			end
			state.lastActive = now
		end
		countDeal(player, button, action)
		return
	end
	local ok = LuckyButtonLogic.canClaim(button, {
		world = WorldService.currentWorld(player),
		now = now,
		root = rootOf(player),
		radius = LuckyButtonConfig.Deal.KeepRadius,
	})
	if not ok then
		return
	end
	state.lastActive = now
	-- One prompt per button per PromptCooldown; the button stays until bought / expired.
	local key, promptType = button.product, button.productType
	if key == nil or now - button.lastPromptAt < LuckyButtonConfig.PromptCooldown then
		return
	end
	button.lastPromptAt = now
	countDeal(player, button, "buy")
	local shown = if promptType == "pass"
		then MonetizationService.promptPass(player, key, LuckyButtonConfig.PromptSource)
		else MonetizationService.promptProduct(player, key, LuckyButtonConfig.PromptSource)
	if shown then
		state.prompts[key] = { at = now, kind = button.kind.id }
		counters.prompted += 1
		track(player, "luckyPrompted", button.kind.id)
	end
end

--[[
	LuckyButtonClaim handler: the player walked into button `rawId` (no action), or — owner R122 —
	acted on a paid button's DEAL card (`rawAction` "shown" / "buy" / "close").
	@param player    the caller
	@param rawId     untrusted: must be one of the caller's own live button ids
	@param rawAction untrusted: nil, or one of LuckyButtonConfig.Deal.Actions (paid kinds only)
]]
local function onClaim(player: Player, rawId: unknown, rawAction: unknown)
	if not claimLimiter:Allow(player) then
		return
	end
	local id = Validate.key(rawId, LuckyButtonConfig.IdMaxLength)
	if id == nil or not LuckyButtonLogic.validId(id) then
		return
	end
	local state = states[player]
	local button = if state ~= nil then state.buttons[id] else nil
	if state == nil or button == nil or not enabled() then
		return
	end
	local now = serverNow()
	local kind = button.kind
	if rawAction ~= nil then
		local action = Validate.oneOf(rawAction, LuckyButtonConfig.Deal.Actions)
		if action ~= nil and kind.paid then
			onDeal(player, state, button, action, now)
		end
		return
	end
	local ok = LuckyButtonLogic.canClaim(button, {
		world = WorldService.currentWorld(player),
		now = now,
		root = rootOf(player),
	})
	if not ok then
		return
	end
	state.lastActive = now
	if kind.paid then
		-- Owner R122: walking in never prompts; the client shows the DEAL card (only BUY prompts).
		return
	end
	-- Free: grant first; only a successful grant consumes the button.
	local granted = 0
	if kind.income ~= nil then
		granted = PlayerDataService.grantCurrency(
			player,
			button.currency or "cash",
			button.amount or 0,
			LuckyButtonConfig.GrantReason
		)
	elseif kind.boost ~= nil and kind.seconds ~= nil then
		granted = BoostService.grant(player, kind.boost, kind.seconds) or 0
	end
	if granted <= 0 then
		return
	end
	endButton(state, button, now)
	counters.claimed += 1
	Remotes.fireClient("LuckyButtons", player, {
		kind = "claimed",
		id = button.id,
		button = kind.id,
		amount = if kind.income ~= nil then granted else nil,
		currency = button.currency,
	})
	track(player, "luckyClaimed", kind.id)
	ProgressEvents.progress(player, "lucky") -- R78 Quests / Pass: a free Lucky Button claimed
end

-- A product / pass was bought: attribute it to a recent lucky prompt and retire that button.
local function onPurchase(player: Player, key: string)
	local state = states[player]
	if state == nil then
		return
	end
	local now = serverNow()
	local prompt = state.prompts[key]
	if prompt ~= nil then
		state.prompts[key] = nil
		if now - prompt.at <= LuckyButtonConfig.PurchaseWindow then
			counters.purchased += 1
			track(player, "luckyPurchased", prompt.kind)
		end
	end
	-- A live paid button for that product is done (bought here or anywhere else).
	for _, button in state.buttons do
		if button.product == key then
			endButton(state, button, now)
			Remotes.fireClient("LuckyButtons", player, { kind = "claimed", id = button.id, button = button.kind.id })
		end
	end
end

-- ── Public API (admin / QA) ──────────────────────────────────────────────────────────────────

--[[
	Spawns a button of kind `kindId` for `player` right now (admin / QA). The player needs a plot
	and a run in their current world; the live cap still applies.
	@return (ok, id or reason)
	Example: LuckyButtonService.spawnFor(player, "cash") --> true, "L3"
]]
function LuckyButtonService.spawnFor(player: Player, kindId: string): (boolean, string)
	local kind = LuckyButtonConfig.byId(kindId)
	local state = stateOf(player)
	if kind == nil or state == nil then
		return false, "unknown kind / player"
	end
	state.world = WorldService.currentWorld(player)
	return spawn(player, state, kind, false)
end

--[[ Clears every live button on the server (admin / kill switch). ]]
function LuckyButtonService.clearAll()
	for player, state in states do
		clearPlayer(player, state)
	end
end

--[[
	Live counts + this server's counters (admin LuckyStatus, QA).
	@return { enabled, interval, players, live, paid, spawned, claimed, prompted, purchased, expired,
		dealShown, dealBuy, dealClose (owner R122 DEAL cards), placement = { picks, gap, blocked, ok,
		noAreas } }
]]
function LuckyButtonService.status(): { [string]: any }
	local live, paid, players = 0, 0, 0
	for _, state in states do
		local l, p = counts(state)
		live += l
		paid += p
		if l > 0 then
			players += 1
		end
	end
	return {
		enabled = enabled(),
		interval = intervalMultiplier(),
		players = players,
		live = live,
		paid = paid,
		spawned = counters.spawned,
		claimed = counters.claimed,
		prompted = counters.prompted,
		purchased = counters.purchased,
		expired = counters.expired,
		dealShown = counters.dealShown,
		dealBuy = counters.dealBuy,
		dealClose = counters.dealClose,
		placement = table.clone(placement),
	}
end

--[[ The live buttons of a player as wires (QA / admin inspection). ]]
function LuckyButtonService.buttonsOf(player: Player): { LuckyButtonLogic.Wire }
	local list: { LuckyButtonLogic.Wire } = {}
	local state = states[player]
	if state ~= nil then
		for _, button in state.buttons do
			table.insert(list, wireOf(button))
		end
	end
	return list
end

-- ── Shared placement / cash helpers (owner R89 Happy Hours; additive) ─────────────────────────

--[[
	A free GROUND point on the player's own plot in `world`, found with the Lucky Button placement
	rules (a standing unlocked area, walkable ground, Clearance from pads / producers / props /
	billboards and from the player's live Lucky Buttons) and at least `minSpacing` studs from every
	point in `avoid` (the caller's own pickups). Used by Server/HappyHour/HappyHourPickups so
	Confetti Storm coins / Low-Gravity moon rocks never land inside a building. Lucky Button
	placement diagnostics (LuckyStatus) are left untouched.
	@param player      the plot owner
	@param world       the world id the player is in
	@param avoid       world points to keep `minSpacing` from (may be empty)
	@param minSpacing  studs
	@param near        optional world point (the character): only the two area slots closest to it
	@param maxDistance optional studs from `near` a spot may be
	@return the world-space ground point (y = the slot's ground), or nil when no spot is free
	Example: local point = LuckyButtonService.pickGroundSpot(player, "main", {}, 7, root.Position, 45)
]]
function LuckyButtonService.pickGroundSpot(
	player: Player,
	world: string,
	avoid: { Vector3 },
	minSpacing: number,
	near: Vector3?,
	maxDistance: number?
): Vector3?
	local plot = PlotService.getPlotIndex(player)
	local tycoon = tycoonOf(player, world)
	local state = stateOf(player)
	if plot == nil or tycoon == nil or state == nil then
		return nil
	end
	local areas = standingAreas(player, world, tycoon)
	-- Near a point: only the two standing area slots closest to it (the ones either side of the
	-- road where the player stands), so a drop never lands at the far end of a long plot.
	if near ~= nil and #areas > 2 then
		local distances: { [number]: number } = {}
		for _, area in areas do
			distances[area] = (WorldLayout.slotOrigin(plot, area, world).Position - near).Magnitude
		end
		table.sort(areas, function(a: number, b: number): boolean
			return distances[a] < distances[b]
		end)
		areas = { areas[1], areas[2] }
	end
	local limit = if near ~= nil and maxDistance ~= nil and maxDistance > 0 then maxDistance else math.huge
	local saved = table.clone(placement)
	local found: Vector3? = nil
	-- Twice the Lucky Button draws: the distance filter refuses some valid spots.
	for _ = 1, LuckyButtonConfig.MaxPicks * 2 do
		local _, _, _, position = pickSpot(state, world, plot, areas)
		if position == nil then
			break
		end
		local clear = near == nil or (position - (near :: Vector3)).Magnitude <= limit
		for _, other in avoid do
			local dx, dz = position.X - other.X, position.Z - other.Z
			if dx * dx + dz * dz < minSpacing * minSpacing then
				clear = false
				break
			end
		end
		if clear then
			found = position
			break
		end
	end
	-- Keep LuckyStatus about Lucky Buttons only.
	placement.picks, placement.gap, placement.blocked = saved.picks, saved.gap, saved.blocked
	placement.ok, placement.noAreas = saved.ok, saved.noAreas
	return found
end

--[[
	A cash burst of `seconds` of the player's income in `world` (automated producers + the best
	manual click rate), with a floor of `floorScale` x the first pad of their current area — the
	Lucky Button "cash" kind maths (LuckyButtonLogic.cashAmount), shared with the Happy Hour
	pickups.
	@return (amount, currency key of that world) — (0, "cash") when the player has no run there
	Example: local amount, currency = LuckyButtonService.cashBurst(player, "dino", 10, 0.25)
]]
function LuckyButtonService.cashBurst(
	player: Player,
	world: string,
	seconds: number,
	floorScale: number
): (number, string)
	local tycoon = tycoonOf(player, world)
	if tycoon == nil then
		return 0, "cash"
	end
	local def = WorldsConfig.get(world)
	local currency = if def ~= nil then def.currency.key else "cash"
	local scale = if floorScale == floorScale and floorScale > 0 then math.min(floorScale, 1) else 1
	local floor = math.max(1, math.floor(cashFloor(world, tycoon) * scale))
	return LuckyButtonLogic.cashAmount(incomeEstimate(player, world, tycoon), seconds, floor), currency
end

-- ── Admin ────────────────────────────────────────────────────────────────────────────────────

-- Registers the owner-panel commands (Server tab, order 70+).
local function registerAdmin()
	Lazy.registerAdmin({
		name = "LuckyToggle",
		tab = "Server",
		label = "Lucky Buttons On/Off",
		description = "Kill switch: OFF clears every Lucky Button and stops new spawns on this server.",
		target = "None",
		args = { mode = { kind = "enum", values = { "on", "off" }, labels = { "ON", "OFF" }, label = "Mode" } },
		argOrder = { "mode" },
		cooldown = 2,
		audited = true,
		confirm = false,
		color = "yellow",
		order = 70,
	}, function(ctx: any): (boolean, string)
		local on = ctx.args.mode == "on"
		ReplicatedStorage:SetAttribute(LuckyButtonConfig.EnabledAttribute, on)
		if not on then
			LuckyButtonService.clearAll()
		end
		return true, `Lucky Buttons: {if on then "ON" else "OFF (cleared)"}`
	end)
	Lazy.registerAdmin({
		name = "LuckySpawn",
		tab = "Server",
		label = "Spawn Lucky Button",
		description = "Pops a Lucky Button of the chosen kind on the player's plot now (live cap applies).",
		target = "Player",
		args = { kind = { kind = "enum", values = LuckyButtonConfig.KindIds, label = "Kind" } },
		argOrder = { "kind" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "yellow",
		order = 71,
	}, function(ctx: any): (boolean, string)
		local target = ctx.target
		local player = if target ~= nil then target.player else nil
		if player == nil then
			return false, "Player not in this server"
		end
		local ok, result = LuckyButtonService.spawnFor(player, ctx.args.kind)
		return ok, if ok then `Spawned {ctx.args.kind} ({result}) for {player.Name}` else `Not spawned: {result}`
	end)
	Lazy.registerAdmin({
		name = "LuckyInterval",
		tab = "Server",
		label = "Lucky Interval x",
		description = "Multiplies the Lucky Button spawn delays (0.25 = 4x as often, 2 = half as often).",
		target = "None",
		args = {
			multiplier = {
				kind = "number",
				min = LuckyButtonConfig.IntervalMin,
				max = LuckyButtonConfig.IntervalMax,
				presets = { 0.25, 0.5, 1, 2, 5 },
				label = "Multiplier",
				default = 1,
			},
		},
		argOrder = { "multiplier" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "yellow",
		order = 72,
	}, function(ctx: any): (boolean, string)
		local value = math.clamp(ctx.args.multiplier, LuckyButtonConfig.IntervalMin, LuckyButtonConfig.IntervalMax)
		ReplicatedStorage:SetAttribute(LuckyButtonConfig.IntervalAttribute, value)
		return true, `Lucky Button interval x{value}`
	end)
	Lazy.registerAdmin({
		name = "LuckyClear",
		tab = "Server",
		label = "Clear Lucky Buttons",
		description = "Removes every live Lucky Button on this server (spawning continues).",
		target = "None",
		args = {},
		cooldown = 2,
		audited = true,
		confirm = false,
		color = "yellow",
		order = 73,
	}, function(_ctx: any): (boolean, string)
		local before = LuckyButtonService.status().live
		LuckyButtonService.clearAll()
		return true, `Cleared {before} Lucky Button(s)`
	end)
	Lazy.registerAdmin({
		name = "LuckyStatus",
		tab = "Server",
		label = "Lucky Buttons Status",
		description = "Live Lucky Buttons and this server's spawned / claimed / prompted / bought / expired counts + R122 DEAL cards (shown / BUY / closed).",
		target = "None",
		args = {},
		cooldown = 1,
		audited = false,
		confirm = false,
		color = "yellow",
		order = 74,
	}, function(_ctx: any): (boolean, string)
		local s = LuckyButtonService.status()
		return true,
			`{if s.enabled then "ON" else "OFF"} · interval x{s.interval} · live {s.live} (paid {s.paid}) on {s.players} player(s) · spawned {s.spawned} · claimed {s.claimed} · prompted {s.prompted} · bought {s.purchased} · expired {s.expired} · deals {s.dealShown} shown / {s.dealBuy} BUY / {s.dealClose} closed · spots {s.placement.ok}/{s.placement.picks} (gap {s.placement.gap}, blocked {s.placement.blocked})`
	end)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────────────────────

--[[ Feature-service Init (nothing to prepare before Start). ]]
function LuckyButtonService.Init() end

--[[
	Starts the claim remote, purchase / activity hooks, admin commands and the ONE 1 Hz loop.
	Idempotent.
]]
function LuckyButtonService.Start()
	if started then
		return
	end
	started = true
	if ReplicatedStorage:GetAttribute(LuckyButtonConfig.EnabledAttribute) == nil then
		ReplicatedStorage:SetAttribute(LuckyButtonConfig.EnabledAttribute, true)
	end
	if ReplicatedStorage:GetAttribute(LuckyButtonConfig.IntervalAttribute) == nil then
		ReplicatedStorage:SetAttribute(LuckyButtonConfig.IntervalAttribute, 1)
	end
	Remotes.onServerEvent("LuckyButtonClaim", onClaim)
	MonetizationService.ProductGranted:Connect(function(player: Player, key: string)
		onPurchase(player, key)
	end)
	MonetizationService.PassPurchased:Connect(function(player: Player, key: string)
		onPurchase(player, key)
	end)
	-- Buying a pad is activity too (a player can build without walking far).
	TycoonService.PadBought:Connect(function(player: Player)
		local state = states[player]
		if state ~= nil then
			state.lastActive = serverNow()
		end
	end)
	TycoonService.WorldPadBought:Connect(function(player: Player)
		local state = states[player]
		if state ~= nil then
			state.lastActive = serverNow()
		end
	end)
	PlotService.PlotReleased:Connect(function(player: Player)
		local state = states[player]
		if state ~= nil then
			clearPlayer(player, state)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		states[player] = nil
		claimLimiter:Forget(player)
	end)
	-- The kill switch also clears when flipped by anything other than the admin command.
	ReplicatedStorage:GetAttributeChangedSignal(LuckyButtonConfig.EnabledAttribute):Connect(function()
		if not enabled() then
			LuckyButtonService.clearAll()
		end
	end)
	registerAdmin()
	task.spawn(function()
		while true do
			task.wait(LuckyButtonConfig.TickSeconds)
			local ok, err = pcall(step)
			if not ok then
				warn(`[LuckyButtonService] step: {err}`)
			end
		end
	end)
end

return LuckyButtonService
