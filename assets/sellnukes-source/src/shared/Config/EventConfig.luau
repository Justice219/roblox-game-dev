--!strict
--[[
	EventConfig — HARVEST FEAST, the SellNukes Thanksgiving event (spec §10, owner R1 "start
	building like a Thanksgiving event as well"). One require-free home for every Harvest Feast
	number AND the pure maths built on them, shared by the server (EventService + Event/*), the
	client (EventController, the sticker sheet + shop screens) and the Lune tests. Pattern: RoBeasts
	HauntConfig (season window, currency, shop, pure helpers).

	What lives here:
		- The season window [Season.starts, Season.ends) = 2026-11-01 → 2026-12-01 UTC (the same
		  instants as MonetizationConfig's HARVEST window for the Acorn packs / Turkey Lure; pinned by
		  tests/event-logic.luau). `isInWindow` / `resolveActive` (admin force on/off wins).
		- GOLDEN TURKEYS: spawn caps + intervals (hub and plots), lifetime, walking speed, ranges,
		  and the deterministic wander path maths (`compilePath` / `pose`) that the server uses to
		  validate a catch and every client uses to animate the same turkey at the same spot.
		- REWARDS: acorns per turkey, the Feast Sticker chance, dupe protection (owned stickers weigh
		  `DupeWeightFactor` of an unowned one), the dupe consolation, Turkey Lure multipliers.
		- The 20 FEAST STICKERS (rarity weights) and the sheet reward (the Gobble Bomb pet, B9);
		  the 3 free STARTER stickers every player gets once per season (owner R97).
		- GROUND PLACEMENT maths (owner R96): `groundFrame` (a model's real feet from its parts'
		  boxes) and `groundSnapY` (the client's walkable-surface follow between waypoints).
		- The EVENT SHOP: acorn-priced plot decorations (built on the owner's plot with the LEGO
		  build-in) and personal boosts; the Harvest Egg row points at B9's EggConfig egg.
		- Replication names (ReplicatedStorage attributes + the asset folder) and the EventState
		  wire format with its client-side validator (`parseTurkey`).

	Time: every `now` is unix seconds (UTC). The server passes os.time() (window) or
	Workspace:GetServerTimeNow() (turkey paths); clients pass Workspace:GetServerTimeNow().

	Connects to: Server/Services/EventService, Server/Event/{EventLogic,TurkeySpawner,EventDecor},
	Client/Event/{EventController,TurkeyRenderer,EventView}, UI/Screens/{StickerSheet,EventShop},
	MonetizationConfig (Acorns / TurkeyLure products), B9 EggConfig ("harvest_egg") + PetService
	("gobble_bomb"), tests/event-logic.luau. Docs: docs/event.md.

	Example:
		local now = os.time()
		if EventConfig.resolveActive(now, nil) then print("Harvest Feast is on!") end
		local def = EventConfig.Stickers[20] --> { key = "Sticker20", name = "Golden Drumstick", rarity = "Legendary" }
		local compiled = EventConfig.compilePath(wire)
		local pose = EventConfig.pose(compiled, workspace:GetServerTimeNow())
		print(pose.position, pose.pecking)
]]

export type Rarity = "Common" | "Rare" | "Epic" | "Legendary"

-- One Feast Sticker. `index` is its slot on the sheet (1..20) and its key in profile.event.stickers.
export type StickerDef = { index: number, key: string, name: string, rarity: Rarity, icon: string }

-- An acorn-priced plot decoration (bought once, kept forever, shown on the owner's plot).
export type DecorDef = {
	key: string,
	name: string,
	description: string,
	price: number, -- acorns
	model: string, -- MeshAssets key (B8e Harvest_*); primitive fallback in Event/EventDecor until it exists
	slot: string, -- EventConfig.DecorSlots key (HubLayout.plotDecor[slot] overrides when the art defines it)
	collide: boolean, -- gets an invisible collision box (false for overhead pieces)
	icon: string, -- IconAssets key
	order: number,
}

-- An acorn-priced personal boost (BoostService / BoostConfig key).
export type BoostItemDef = {
	key: string,
	name: string,
	description: string,
	price: number, -- acorns
	boostKey: string, -- BoostConfig.Boosts key
	seconds: number,
	icon: string,
	order: number,
}

export type ShopKind = "decor" | "boost"

-- One row of the EVENT SHOP (decorations + boosts; the Harvest Egg is B9's HatchEgg flow).
export type ShopItem = {
	key: string,
	kind: ShopKind,
	name: string,
	description: string,
	price: number,
	icon: string,
	order: number,
	decor: DecorDef?,
	boost: BoostItemDef?,
}

export type Zone = "hub" | "plot"

--[[
	A Golden Turkey as sent to clients (EventState "spawn" / "sync"). The path is a closed loop of
	ground points; the turkey stands (pecks) `pause` seconds at each point, then walks to the next
	one at `speed` studs/s, from `t0` (server clock) until `t0 + life`.
]]
export type TurkeyWire = {
	id: string,
	zone: Zone,
	points: { Vector3 },
	t0: number,
	speed: number,
	pause: number,
	life: number,
	owner: number, -- 0 = anyone may catch it; otherwise the only UserId that may (Turkey Lure)
	lure: boolean,
}

-- One leg of a compiled path: stand at `from` for `pause`, then walk to `to` in `walk` seconds.
type Leg = { from: Vector3, to: Vector3, dir: Vector3, walk: number, starts: number }

-- A path pre-processed for cheap per-frame posing (server validation + client animation).
export type CompiledPath = {
	wire: TurkeyWire,
	legs: { Leg },
	cycle: number, -- seconds for one full loop
	ends: number, -- t0 + life
}

-- Where a turkey is at a moment.
export type Pose = {
	position: Vector3, -- ground point under the turkey's feet
	facing: Vector3, -- unit XZ direction it looks at
	pecking: boolean, -- standing at a waypoint (peck animation)
	moving: boolean,
	alive: boolean, -- false once t >= ends (or before t0)
	phase: number, -- 0..1 progress inside the current stand/walk step (animation)
}

-- One visual part's box for `groundFrame` (a BasePart's CFrame + Size, or any oriented box).
export type GroundBox = { cframe: CFrame, size: Vector3 }

local EventConfig = {}

-- ─── Season window ────────────────────────────────────────────────────────────────────────────

--[[
	The current season. `id` is stored in profile.event.season: a profile whose season differs is
	reset (acorns, stickers, redeemed) the first time the event touches it while this season is on,
	so next year's Harvest Feast starts clean. Decorations (event.decor) are kept forever.
	2026-11-01T00:00:00Z → 2026-12-01T00:00:00Z (= MonetizationConfig HARVEST_STARTS / _ENDS).
]]
EventConfig.Season = table.freeze({
	id = "harvest2026",
	name = "Harvest Feast",
	starts = 1_793_491_200,
	ends = 1_796_083_200,
})

-- After the end a COMPLETED sheet can still be redeemed for this long (kid-friendly: a sheet
-- finished on the last evening is never lost). Turkeys, the shop and the decor stop at the end.
EventConfig.RedeemGraceSeconds = 3 * 24 * 3600

-- Admin force modes (EventService.setForced): "on" / "off" override the window; nil = by date.
export type ForceMode = "on" | "off"

--[[ True when `now` (unix seconds) is inside the season window [starts, ends). ]]
function EventConfig.isInWindow(now: number): boolean
	return now >= EventConfig.Season.starts and now < EventConfig.Season.ends
end

--[[
	Whether the event runs right now: the admin force wins, otherwise the date window.
	Example: EventConfig.resolveActive(os.time(), "on") --> true (even in October)
]]
function EventConfig.resolveActive(now: number, forced: ForceMode?): boolean
	if forced == "on" then
		return true
	elseif forced == "off" then
		return false
	end
	return EventConfig.isInWindow(now)
end

--[[ Unix time until which a completed sheet may still be redeemed (end + grace). ]]
function EventConfig.redeemUntil(): number
	return EventConfig.Season.ends + EventConfig.RedeemGraceSeconds
end

-- ─── Replication ──────────────────────────────────────────────────────────────────────────────

-- ReplicatedStorage attributes the server keeps current (clients read them; B9's egg stand too).
EventConfig.Attributes = table.freeze({
	Active = "HarvestFeastActive", -- boolean: the event runs (window or admin force)
	StartsAt = "HarvestFeastStartsAt", -- unix
	EndsAt = "HarvestFeastEndsAt", -- unix (the season end; a forced event shows it too)
	RedeemUntil = "HarvestFeastRedeemUntil", -- unix: last moment to redeem a completed sheet
	Forced = "HarvestFeastForced", -- "on" | "off" | "" (admin override, display only)
})

-- ReplicatedStorage folder with the client-cloned turkey template (server-built: Blender mesh via
-- MeshLibrary, or the primitive fallback).
EventConfig.AssetFolder = "HarvestFeast"
EventConfig.TurkeyTemplate = "GoldenTurkey"

-- MeshAssets keys of the event items (B8f). Missing keys use the primitive fallbacks.
EventConfig.Models = table.freeze({
	Turkey = "GoldenTurkey",
})

-- ─── Golden Turkeys ───────────────────────────────────────────────────────────────────────────

EventConfig.Turkey = table.freeze({
	Speed = 5, -- walking speed (studs/s)
	ModelScale = 1.6, -- the GoldenTurkey mesh is ~2.5 studs tall; scaled up so kids spot it
	PauseSeconds = 1.8, -- pecking at each waypoint
	LifeSeconds = 80, -- a natural turkey wanders this long, then runs off
	LureLifeSeconds = 900, -- a lured turkey waits 15 min (it is re-lured next session if missed)
	Waypoints = 5, -- points per wander loop
	-- Ranges (studs). Clients offer click / tap / prompt within TapRange and auto-catch by walking
	-- into the turkey within CatchRadius. The server accepts up to TapRange + ServerSlack from the
	-- character root (its copy lags the client by the ping) to the turkey's server-side pose.
	TapRange = 22,
	PromptRange = 14,
	CatchRadius = 6,
	ServerSlack = 10,
	-- The server checks the distance to the turkey now and at these many seconds ago (latency).
	LagSamples = table.freeze({ 0, 0.4, 0.8 }),
	CollectCooldown = 0.6, -- seconds between two catches by one player
	-- Caps: natural turkeys alive server-wide; lures may go up to MaxAliveWithLures.
	MaxAlive = 14,
	MaxAliveWithLures = 22,
	Hub = table.freeze({
		Max = 3, -- natural turkeys alive in the hub at once
		IntervalMin = 35, -- seconds between hub spawns (random in [min, max])
		IntervalMax = 70,
		WanderRadius = 38, -- fallback wander circle around the event square
		AnchorWander = 12, -- a hub turkey loops within this radius of one HubLayout spawn point
		FirstDelay = 8, -- first hub spawn after the event turns on
	}),
	Plot = table.freeze({
		Max = 1, -- natural turkeys alive per player's plot
		IntervalMin = 90,
		IntervalMax = 170,
		FirstDelay = 25, -- after the player's profile loads / the event turns on
		RoadHalfWidth = 6, -- plot-local |x| of wander points (the road is |x| <= 8)
		StartZ = 12, -- plot-local z of the first wander point (past the entrance arch)
		Spread = 28, -- wander points stay within +-Spread studs of a centre along the road
	}),
	-- Ground probe for every wander point: ray from point + RayUp down RayDepth studs. The server
	-- probe hits WALKABLE surfaces only (RaycastParams.RespectCanCollide), so a turkey stands where
	-- a character's feet would, never on an invisible trigger / hitbox (owner R96).
	RayUp = 10,
	RayDepth = 40,
	-- Client ground follow (owner R96): between two server-snapped waypoints the straight walk can
	-- cross a curb or a flower-bed edge. Each visible turkey re-probes the walkable surface under
	-- it GroundHz times a second (one ray from GroundUp above the path point down to GroundDown
	-- below it) and keeps its feet on it: it climbs at most GroundUp (a curb / bed edge, never a
	-- bench, a car roof or a character) and sinks at most GroundDown; the rendered height eases
	-- toward the probe at GroundEase per second so a curb step never pops.
	GroundHz = 8,
	GroundUp = 1.6,
	GroundDown = 2.5,
	GroundEase = 14,
	-- The Catch! prompt floats this many studs above the top of the turkey's hitbox (its head), so
	-- it is never at ground level and never hidden inside the bird (owner R96).
	PromptLift = 0.6,
	-- Clients: turkeys farther than RenderDistance from the camera are parked (no instances in the
	-- world, no animation); beyond SlowDistance they update at SlowHz instead of every frame.
	RenderDistance = 320,
	SlowDistance = 120,
	SlowHz = 10,
	MaxPoints = 12, -- wire bound (parseTurkey)
})

-- ─── Rewards ──────────────────────────────────────────────────────────────────────────────────

EventConfig.Rewards = table.freeze({
	AcornsMin = 4, -- acorns per natural turkey, uniform whole number in [min, max]
	AcornsMax = 9,
	LureMultiplier = 3, -- a lured turkey pays 3x acorns
	-- Chance a natural turkey drops a Feast Sticker roll. Tuned with tests/event-logic.luau's
	-- simulation: ~130 natural turkeys complete the sheet (~4 h of play at ~30-35 turkeys / h).
	StickerChance = 0.25,
	LureStickerChance = 1, -- a lured turkey always rolls a sticker (a PAID RANDOM item: see below)
	-- Dupe protection: an OWNED sticker weighs this fraction of its base weight, so the sheet fills
	-- steadily but a dupe is still possible (it pays DupeAcorns instead).
	DupeWeightFactor = 0.08,
	DupeAcorns = 12,
	MaxAcorns = 1e12, -- balance cap (ProfileLogic MaxCounter is far above)
})

-- Turkey Lure where paid random items are restricted (MonetizationConfig TurkeyLure is paidRandom;
-- the prompt is refused and a lure that still arrives pays the fixed reward: Rewards.AcornsMax ×
-- LureMultiplier acorns, no sticker). Shown by the EventShop card and the server refusal.
EventConfig.LurePolicyText = "The Turkey Lure isn't available in your region. Golden Turkeys still visit for free!"

-- Base roll weight per rarity (before dupe protection).
EventConfig.RarityWeight = table.freeze({
	Common = 10,
	Rare = 6,
	Epic = 3,
	Legendary = 1.5,
} :: { [Rarity]: number })

-- Sticker card colours per rarity (UIStyleConfig ColorName; "rainbow" shimmers).
EventConfig.RarityColor = table.freeze({
	Common = "sky",
	Rare = "blue",
	Epic = "purple",
	Legendary = "rainbow",
} :: { [Rarity]: string })

-- ─── Feast Stickers ───────────────────────────────────────────────────────────────────────────

local STICKER_ROWS: { { string | Rarity } } = {
	{ "Roast Turkey", "Common" },
	{ "Pumpkin Pie", "Common" },
	{ "Corn Cob", "Common" },
	{ "Acorn Buddy", "Common" },
	{ "Maple Leaf", "Common" },
	{ "Cranberry Jar", "Common" },
	{ "Apple Pie", "Common" },
	{ "Hay Bale", "Common" },
	{ "Scarecrow", "Rare" },
	{ "Cornucopia", "Rare" },
	{ "Sweet Potato", "Common" },
	{ "Gravy Boat", "Rare" },
	{ "Dinner Roll", "Common" },
	{ "Leaf Pile", "Rare" },
	{ "Harvest Moon", "Epic" },
	{ "Cozy Mug", "Rare" },
	{ "Squash Pal", "Rare" },
	{ "Pecan Pie", "Epic" },
	{ "Wishbone", "Epic" },
	{ "Golden Drumstick", "Legendary" },
}

-- The sheet, in slot order (index = sheet slot = profile.event.stickers key).
EventConfig.Stickers = (function(): { StickerDef }
	local list: { StickerDef } = {}
	for index, row in STICKER_ROWS do
		local key = string.format("Sticker%02d", index)
		local def: StickerDef = {
			index = index,
			key = key,
			name = row[1] :: string,
			rarity = row[2] :: Rarity,
			icon = key,
		}
		table.insert(list, def)
	end
	for _, def in list do
		table.freeze(def)
	end
	return table.freeze(list)
end)()

EventConfig.StickerCount = #EventConfig.Stickers

--[[
	Owner R97 ("start people off with like 3-4 filled in"): every player gets StarterCount FREE
	starter stickers once per season (EventLogic.grantStarters, server-side, idempotent through
	profile.event.starterSeason). They are the commonest stickers on the sheet: highest
	RarityWeight first, ties broken by the lowest sheet slot (today: Roast Turkey, Pumpkin Pie,
	Corn Cob). The Gobble Bomb still needs all StickerCount stickers.
]]
EventConfig.Starter = table.freeze({
	Count = 3,
})

-- The starter sticker indices in grant order (frozen; derived from the sheet + RarityWeight).
EventConfig.StarterStickers = (function(): { number }
	local order: { StickerDef } = table.clone(EventConfig.Stickers)
	table.sort(order, function(a: StickerDef, b: StickerDef): boolean
		local wa, wb = EventConfig.RarityWeight[a.rarity], EventConfig.RarityWeight[b.rarity]
		if wa ~= wb then
			return wa > wb
		end
		return a.index < b.index
	end)
	local list: { number } = {}
	for index = 1, math.min(EventConfig.Starter.Count, #order) do
		table.insert(list, order[index].index)
	end
	return table.freeze(list)
end)()

-- The sheet reward: B9's pet id (PetService.grantPet(player, RewardPetId, "event_sheet")).
EventConfig.RewardPetId = "gobble_bomb"
EventConfig.RewardPetName = "Gobble Bomb"
EventConfig.RewardIcon = "GobbleBomb"

-- B9's acorn-priced egg (EggConfig.Eggs[HarvestEggId]; hatched through the HatchEgg remote).
EventConfig.HarvestEggId = "harvest_egg"

-- ─── Event shop ───────────────────────────────────────────────────────────────────────────────

-- Plot decorations (owner keeps them forever; built on the plot with the LEGO build-in).
local DECOR: { DecorDef } = {
	{
		key = "HayBales",
		name = "Hay Bale Stack",
		description = "Cozy hay bales by your entrance.",
		price = 150,
		model = "Harvest_HayBale",
		slot = "GroundL1",
		collide = true,
		icon = "DecorHayBales",
		order = 1,
	},
	{
		key = "PumpkinPile",
		name = "Pumpkin Pile",
		description = "A happy heap of pumpkins.",
		price = 250,
		model = "Harvest_PumpkinPile",
		slot = "GroundR1",
		collide = true,
		icon = "DecorPumpkinPile",
		order = 2,
	},
	{
		key = "Scarecrow",
		name = "Friendly Scarecrow",
		description = "He waves at every visitor.",
		price = 400,
		model = "Harvest_Scarecrow",
		slot = "GroundL2",
		collide = true,
		icon = "DecorScarecrow",
		order = 3,
	},
	{
		key = "Cornucopia",
		name = "Giant Cornucopia",
		description = "Overflowing with harvest goodies.",
		price = 650,
		model = "Harvest_CornucopiaSmall",
		slot = "GroundR2",
		collide = true,
		icon = "DecorCornucopia",
		order = 4,
	},
	{
		key = "Garland",
		name = "Harvest Garland",
		description = "Leaves and lights across your arch.",
		price = 900,
		model = "Harvest_Garland",
		slot = "Arch",
		collide = false,
		icon = "DecorGarland",
		order = 5,
	},
	{
		key = "TurkeyStatue",
		name = "Golden Turkey Statue",
		description = "The shiniest bird in town.",
		price = 1500,
		model = "Harvest_TurkeyStatue",
		slot = "GroundL3",
		collide = true,
		icon = "DecorTurkeyStatue",
		order = 6,
	},
}
for _, def in DECOR do
	table.freeze(def)
end
EventConfig.Decor = table.freeze(DECOR)

-- Acorn boosts (BoostService personal boosts; time stacks like every other boost).
local BOOSTS: { BoostItemDef } = {
	{
		key = "HarvestRush",
		name = "Harvest Rush",
		description = "2x cash for 10 minutes.",
		price = 120,
		boostKey = "cash2x",
		seconds = 600,
		icon = "X2Cash",
		order = 1,
	},
	{
		key = "FeastSpeed",
		name = "Feast Speed",
		description = "2x production speed for 10 minutes.",
		price = 100,
		boostKey = "speed2x",
		seconds = 600,
		icon = "Clock",
		order = 2,
	},
}
for _, def in BOOSTS do
	table.freeze(def)
end
EventConfig.Boosts = table.freeze(BOOSTS)

--[[
	Where bought decorations stand on the owner's plot. The hub art (B8e) defines plot-local
	anchors in HubLayout.plotDecor[slot] — GroundL1/L2/L3/R1/R2 on the island ground just outside
	the plot's front corners, Arch = the garland's road-centre pivot past the entrance — and those
	win. The
	entries below are the FALLBACK for any slot the art does not define (yet). `area` = the frame of
	the CFrame: 1 = area 1's slot-local frame (WorldLayout.slotToWorld; area 1 is built at plot
	claim, so these always stand on its front lawn: between the pad row (z_s 10) and the garage
	(z_s 32), clear of the driveway (|x_s| <= 8.5), the lamps (+-11.5, 26) and the yard trees);
	0 = plot-local (WorldLayout.plotToWorld). Front (-Z) faces the road / the hub. Ground items
	snap to the ground with a raycast; the garland's pivot is placed exactly at its slot.
]]
EventConfig.DecorSlots = table.freeze({
	GroundL1 = table.freeze({ area = 1, cf = CFrame.new(-34, 0, 19) }),
	GroundR1 = table.freeze({ area = 1, cf = CFrame.new(-24, 0, 21) * CFrame.Angles(0, math.rad(20), 0) }),
	GroundL2 = table.freeze({ area = 1, cf = CFrame.new(-48, 0, 19) }),
	GroundR2 = table.freeze({ area = 1, cf = CFrame.new(24, 0, 20) * CFrame.Angles(0, math.rad(-20), 0) }),
	GroundL3 = table.freeze({ area = 1, cf = CFrame.new(34, 0, 19) }),
	-- The garland's pivot: the road centre just past the entrance arch (plot-local, ground level;
	-- its poles stand on the curbs and the swag hangs ~12.5 up, above heads).
	Arch = table.freeze({ area = 0, cf = CFrame.new(0, 0, 12) }),
} :: { [string]: { area: number, cf: CFrame } })

-- Fallback hub event square (world space) until HubLayout.event.square exists.
EventConfig.FallbackSquare = CFrame.new(0, 0, -150)

-- Every shop row (decor first, then boosts), and a key -> row index for remote validation.
EventConfig.Shop = (function(): { ShopItem }
	local rows: { ShopItem } = {}
	for _, def in DECOR do
		local row: ShopItem = {
			key = def.key,
			kind = "decor",
			name = def.name,
			description = def.description,
			price = def.price,
			icon = def.icon,
			order = def.order,
			decor = def,
			boost = nil,
		}
		table.insert(rows, row)
	end
	for _, def in BOOSTS do
		local row: ShopItem = {
			key = def.key,
			kind = "boost",
			name = def.name,
			description = def.description,
			price = def.price,
			icon = def.icon,
			order = 100 + def.order,
			decor = nil,
			boost = def,
		}
		table.insert(rows, row)
	end
	for _, row in rows do
		table.freeze(row)
	end
	return table.freeze(rows)
end)()

EventConfig.ShopByKey = (function(): { [string]: ShopItem }
	local byKey: { [string]: ShopItem } = {}
	for _, item in EventConfig.Shop do
		assert(byKey[item.key] == nil, `duplicate event shop key {item.key}`)
		byKey[item.key] = item
	end
	return table.freeze(byKey)
end)()

-- Longest shop key (remote validation bound).
EventConfig.MaxShopKeyLength = 24

-- ─── Remote limits (server) ───────────────────────────────────────────────────────────────────

EventConfig.Limits = table.freeze({
	CollectBurst = 6, -- EventCollect token bucket
	CollectPerSecond = 3,
	ActionBurst = 3, -- EventRedeemSheet / EventShopBuy token bucket
	ActionPerSecond = 1,
	MaxTurkeyIdLength = 16,
})

-- ─── Path maths (pure; server + client) ───────────────────────────────────────────────────────

-- True for a finite number.
local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--[[
	Pre-processes a turkey's wander loop into legs (point i → point i+1, the last back to the
	first) with their start times inside one cycle. Zero-length legs (duplicate points) keep their
	pause and walk 0 s.
	@param wire a validated TurkeyWire (server-built or parseTurkey'd)
	@return CompiledPath for `pose`
]]
function EventConfig.compilePath(wire: TurkeyWire): CompiledPath
	local legs: { Leg } = {}
	local points = wire.points
	local count = #points
	local clock = 0
	local speed = math.max(wire.speed, 0.1)
	for index = 1, count do
		local from = points[index]
		local to = points[(index % count) + 1]
		local delta = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
		local distance = delta.Magnitude
		local dir = if distance > 1e-3 then delta / distance else Vector3.new(0, 0, -1)
		local walk = if count > 1 then (to - from).Magnitude / speed else 0
		table.insert(legs, { from = from, to = to, dir = dir, walk = walk, starts = clock })
		clock += wire.pause + walk
	end
	return {
		wire = wire,
		legs = legs,
		cycle = math.max(clock, 1e-3),
		ends = wire.t0 + wire.life,
	}
end

--[[
	Where a compiled turkey is at time `t` (same server clock as `wire.t0`). Deterministic: the
	server validating a catch and every client animating the turkey get the same answer.
	@return Pose (alive = false before t0 / at or after t0 + life)
	Example: local pose = EventConfig.pose(compiled, now); if pose.alive then ... end
]]
function EventConfig.pose(compiled: CompiledPath, t: number): Pose
	local wire = compiled.wire
	local legs = compiled.legs
	local first = legs[1]
	if first == nil then
		return {
			position = Vector3.zero,
			facing = Vector3.new(0, 0, -1),
			pecking = false,
			moving = false,
			alive = false,
			phase = 0,
		}
	end
	local alive = t >= wire.t0 and t < compiled.ends
	local elapsed = math.max(0, t - wire.t0) % compiled.cycle
	-- Find the leg (few legs: a linear scan beats any index structure here).
	local leg = first
	for index = #legs, 1, -1 do
		if elapsed >= legs[index].starts then
			leg = legs[index]
			break
		end
	end
	local into = elapsed - leg.starts
	if into < wire.pause or leg.walk <= 0 then
		return {
			position = leg.from,
			facing = leg.dir,
			pecking = true,
			moving = false,
			alive = alive,
			phase = if wire.pause > 0 then math.clamp(into / wire.pause, 0, 1) else 1,
		}
	end
	local alpha = math.clamp((into - wire.pause) / leg.walk, 0, 1)
	return {
		position = leg.from:Lerp(leg.to, alpha),
		facing = leg.dir,
		pecking = false,
		moving = true,
		alive = alive,
		phase = alpha,
	}
end

--[[
	Validates a turkey received over the network (defence in depth: even server data is checked).
	@return a clean TurkeyWire, or nil when anything is malformed / out of bounds
	Example: local wire = EventConfig.parseTurkey(payload.turkey)
]]
function EventConfig.parseTurkey(raw: unknown): TurkeyWire?
	if type(raw) ~= "table" then
		return nil
	end
	local data = raw :: { [string]: unknown }
	local id = data.id
	if
		type(id) ~= "string"
		or #id < 1
		or #id > EventConfig.Limits.MaxTurkeyIdLength
		or string.match(id, "^[%w_-]+$") == nil
	then
		return nil
	end
	local zone = data.zone
	if zone ~= "hub" and zone ~= "plot" then
		return nil
	end
	local points: { Vector3 } = {}
	local rawPoints = data.points
	if type(rawPoints) ~= "table" then
		return nil
	end
	for _, point in rawPoints :: { unknown } do
		if typeof(point) ~= "Vector3" then
			return nil
		end
		local v = point :: Vector3
		if not (finite(v.X) and finite(v.Y) and finite(v.Z)) or v.Magnitude > 1e5 then
			return nil
		end
		table.insert(points, v)
		if #points > EventConfig.Turkey.MaxPoints then
			return nil
		end
	end
	if #points < 1 then
		return nil
	end
	local t0, speed, pause, life, owner = data.t0, data.speed, data.pause, data.life, data.owner
	if not (finite(t0) and finite(speed) and finite(pause) and finite(life) and finite(owner)) then
		return nil
	end
	local speedN, pauseN, lifeN, ownerN = speed :: number, pause :: number, life :: number, owner :: number
	if speedN <= 0 or speedN > 50 or pauseN < 0 or pauseN > 30 or lifeN <= 0 or lifeN > 7200 then
		return nil
	end
	if ownerN < 0 or ownerN % 1 ~= 0 then
		return nil
	end
	return {
		id = id,
		zone = zone,
		points = points,
		t0 = t0 :: number,
		speed = speedN,
		pause = pauseN,
		life = lifeN,
		owner = ownerN,
		lure = data.lure == true,
	}
end

-- ─── Ground placement (pure; server template + client renderer) ──────────────────────────────

--[[
	The FEET frame of a model: the pivot's rotation, moved along the pivot's up axis down (or up)
	to the lowest point of `boxes`. Placing this frame on a ground point puts the model's REAL
	bounding-box bottom on the ground, whatever its pivot is. Owner R96: the turkey template's
	PrimaryPart (the Hitbox) made the model pivot the bird's MIDDLE, so turkeys walked half
	underground with their Catch! prompt at ground level. The pivot's x / z are kept, so the bird
	stays centred on its path.

	Each box reaches down from its centre by |axis.Y| x half-size summed over its three axes
	(expressed in the pivot's frame), so rotated parts are measured exactly, not by their centre.

	@param pivot the model's pivot (Model:GetPivot())
	@param boxes the VISUAL parts' { cframe, size } (leave invisible helpers such as Hitbox out)
	@return the feet CFrame; `pivot` itself when there are no (finite) boxes
	Example:
		local feet = EventConfig.groundFrame(model:GetPivot(), { { cframe = body.CFrame, size = body.Size } })
		local offset = feet:ToObjectSpace(body.CFrame) -- place with groundCf * offset
]]
function EventConfig.groundFrame(pivot: CFrame, boxes: { GroundBox }): CFrame
	local lowest = math.huge
	for _, box in boxes do
		local cf = box.cframe
		local half = box.size / 2
		local centre = pivot:PointToObjectSpace(cf.Position)
		local right = pivot:VectorToObjectSpace(cf.RightVector)
		local up = pivot:VectorToObjectSpace(cf.UpVector)
		local back = pivot:VectorToObjectSpace(-cf.LookVector)
		local reach = math.abs(right.Y) * math.abs(half.X)
			+ math.abs(up.Y) * math.abs(half.Y)
			+ math.abs(back.Y) * math.abs(half.Z)
		local bottom = centre.Y - reach
		if bottom == bottom and bottom > -math.huge and bottom < lowest then
			lowest = bottom
		end
	end
	if lowest == math.huge then
		return pivot
	end
	return pivot * CFrame.new(0, lowest, 0)
end

--[[
	The height a turkey's feet should use at a path point: the probed walkable surface when the
	probe hit lies between `down` studs below and `up` studs above the path's (server-snapped)
	height, else the path height. Keeps the bird on curbs / bed edges between waypoints without
	ever jumping onto a car roof, a bench or a character, or dropping into a hole.
	@param pathY the path point's y (server ground-probed at each waypoint)
	@param hitY the client probe's hit y (nil = no hit)
	@param up the highest step accepted above pathY (EventConfig.Turkey.GroundUp)
	@param down the deepest step accepted below pathY (EventConfig.Turkey.GroundDown)
	@return the feet y
	Example: EventConfig.groundSnapY(0, 0.8, 1.6, 2.5) --> 0.8; EventConfig.groundSnapY(0, 5, 1.6, 2.5) --> 0
]]
function EventConfig.groundSnapY(pathY: number, hitY: number?, up: number, down: number): number
	if hitY == nil or hitY ~= hitY or hitY > pathY + up or hitY < pathY - down then
		return pathY
	end
	return hitY
end

-- ─── Small helpers ────────────────────────────────────────────────────────────────────────────

--[[
	Number of stickers in a sticker set ({ [index]: true } server-side, or the snapshot array
	{ 1, 4, ... } client-side). Only valid sheet indices count.
]]
function EventConfig.countStickers(stickers: unknown): number
	if type(stickers) ~= "table" then
		return 0
	end
	local seen: { [number]: boolean } = {}
	local count = 0
	for key, value in stickers :: { [unknown]: unknown } do
		-- Set form: [index] = true. Array form: [n] = index.
		local index = if value == true then key else value
		if
			type(index) == "number"
			and index % 1 == 0
			and index >= 1
			and index <= EventConfig.StickerCount
			and not seen[index]
		then
			seen[index] = true
			count += 1
		end
	end
	return count
end

--[[
	Converts the snapshot's sticker array (or a set) into a set { [index] = true } of valid indices.
	Example: EventConfig.stickerSet({ 1, 4 }) --> { [1] = true, [4] = true }
]]
function EventConfig.stickerSet(stickers: unknown): { [number]: boolean }
	local set: { [number]: boolean } = {}
	if type(stickers) ~= "table" then
		return set
	end
	for key, value in stickers :: { [unknown]: unknown } do
		local index = if value == true then key else value
		if type(index) == "number" and index % 1 == 0 and index >= 1 and index <= EventConfig.StickerCount then
			set[index] = true
		end
	end
	return set
end

return table.freeze(EventConfig)
