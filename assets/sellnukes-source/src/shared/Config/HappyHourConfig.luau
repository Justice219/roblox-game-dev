--!strict
--[[
	HappyHourConfig — tunables of NUKEY'S HAPPY HOURS, the scheduled server mini-events (owner R89,
	spec docs/superpowers/specs/2026-10-31-r89-competitive-wave-design.md §2, docs/happy-hours.md).

	Purpose:
		Every UTC hour a 5-minute HEADLINE event starts at :00, rotating through five events; every
		:30 a 3-minute MINI Sprinkle Surge runs. The schedule is pure maths on unix time
		(Shared/Events/HappyHourLogic), so every server and every client agrees with no DataStore
		and no network message. The owner can still FORCE / STOP / SKIP an event or flip the KILL
		SWITCH from the admin panel; that override reaches every server (Server/HappyHour/
		HappyHourOverrideStore: DataStore + MessagingService) and every client (the ReplicatedStorage
		attributes below).

	Events (`Events[id]`, kid-friendly copy; all rewards computed on the server):
		confetti    CONFETTI STORM     coins + gems rain from cartoon clouds, walk into them (any world)
		sprinkle    SPRINKLE SURGE     rarer Surprise Batch flavours (FlavorLogic reads `luck`)
		doublePops  DOUBLE POPS        every payout pops twice: +25 % cash (eventCash modifier)
		stampede    EGG STAMPEDE       running dino eggs to catch in Dino Valley
		lowGravity  LOW-GRAVITY HOUR   floatier jumps + floating moon rocks in Moon Base

	Event fields:
		id / name / short / blurb / banner   ids + copy (chip, start banner)
		tagline           <= 31 characters: the schedule row line (>= 14 pt on a phone)
		icon / color / sound                 IconAssets key, StudUI colour preset, AudioConfig.Sfx key
		world             world id the event happens in (nil = every world)
		luck / miniLuck   flavour luck while live (headline / the :30 mini surge); 1 = none
		cashMultiplier    eventCash income multiplier while live (Tycoon ModifierSources)
		gravityMultiplier extra Workspace.Gravity factor on top of the world's own scale (client)
		glideFallSpeed    studs/s cap on falling speed while live (a feather-fall glide, client)
		pickup            PickupDef: server-spawned, owner-only pickups (see below)

	PickupDef fields (Server/HappyHour/HappyHourPickups spawns, Client/HappyHour/
	HappyHourPickupsClient draws; Shared/Events/HappyHourPickupLogic holds the shared maths):
		style             "fall" (drops from a cloud), "float" (hangs in the air), "run" (runs a loop
		                  along the ground: the Golden Turkey path maths, EventConfig.compilePath)
		meshKey / goldenMeshKey   MeshAssets keys (existing Blender meshes; stud boxes until loaded)
		goldenTint        colour every part of a golden pickup takes (nil = the mesh's own colours)
		scale             model scale
		maxLive           pickups alive per player at once
		maxPerEvent       pickups spawned per player per event (bounds the total reward)
		intervalMin / Max seconds between two spawns for a player (random in [min, max])
		batch             pickups per spawn (a stampede herd)
		life              seconds a pickup lives
		incomeSeconds     cash reward = this many seconds of the player's income in that world
		                  (floor = the first pad of their current area: LuckyButtonService.cashBurst)
		goldenChance      chance a spawned pickup is golden ...
		goldenGems        ... it pays these gems on top of its cash ...
		maxGoldenPerEvent ... at most this many golden pickups per player per event
		dropHeight / fallSeconds   fall: starts this high above its ground point, lands after this
		floatMin / floatMax        float: height above the ground (low-gravity jump reach)
		runSpeed / runSpread / runPause   run: studs/s, half-length of the loop, pause per waypoint

	Security: shared, read-only data. Clients use it to DRAW; the server computes every reward,
	every spawn and every collection check from it.

	Connects to: Shared/Events/{HappyHourLogic, HappyHourPickupLogic}, Server/Services/
	HappyHourService, Server/HappyHour/*, Client/HappyHour/*, UI/Screens/HappyHour/*,
	Tycoon/FlavorLogic (luck), tests/happy-hours.luau.

	Example:
		local def = HappyHourConfig.Events.doublePops
		print(def.name, def.cashMultiplier) --> "DOUBLE POPS"  1.25
]]

export type EventId = "confetti" | "sprinkle" | "doublePops" | "stampede" | "lowGravity"
export type PickupStyle = "fall" | "float" | "run"

export type PickupDef = {
	style: PickupStyle,
	meshKey: string,
	goldenMeshKey: string,
	goldenTint: Color3?,
	scale: number,
	maxLive: number,
	maxPerEvent: number,
	intervalMin: number,
	intervalMax: number,
	batch: number,
	life: number,
	incomeSeconds: number,
	goldenChance: number,
	goldenGems: number,
	maxGoldenPerEvent: number,
	dropHeight: number?,
	fallSeconds: number?,
	floatMin: number?,
	floatMax: number?,
	runSpeed: number?,
	runSpread: number?,
	runPause: number?,
}

export type EventDef = {
	id: EventId,
	name: string,
	short: string,
	blurb: string,
	tagline: string,
	banner: string,
	icon: string,
	color: string,
	sound: string,
	world: string?,
	luck: number?,
	miniLuck: number?,
	cashMultiplier: number?,
	gravityMultiplier: number?,
	glideFallSpeed: number?,
	pickup: PickupDef?,
}

local HappyHourConfig = {}

-- ─── Schedule (UTC, pure maths: Shared/Events/HappyHourLogic) ─────────────────────────────────

HappyHourConfig.Schedule = table.freeze({
	-- One slot every half hour: even slots start on the hour (headline), odd ones at :30 (mini).
	SlotSeconds = 1800,
	HeadlineSeconds = 300, -- 5-minute headline event at :00
	MiniSeconds = 180, -- 3-minute mini Sprinkle Surge at :30
	MiniEvent = "sprinkle" :: EventId,
	-- Headline rotation by UTC hour index (floor(t / 3600) + RotationOffset) % #Rotation. 24 % 5 = 4,
	-- so every event visits every hour of the day over five days (fair to every time zone).
	Rotation = table.freeze({ "confetti", "sprinkle", "doublePops", "stampede", "lowGravity" } :: { EventId }),
	RotationOffset = 0,
	-- Rows in the schedule panel (the live event first, then the next headline events).
	PanelRows = 4,
	-- Slots scanned when looking for the next non-skipped event (bounded loop).
	MaxScan = 64,
})

-- Flavour luck is clamped to [1, MaxLuck] whatever the config / override says.
HappyHourConfig.MaxLuck = 3

-- Shipped default (owner, R89 parked for the publish): false = Happy Hours are OFF on a fresh
-- server — no live / next event, so no chip, banner, pickups, gravity change or cash bonus, and
-- flavorLuckAt = 1 — until an admin override exists (HappyHourToggle ON, or any Force / Stop /
-- Skip, which writes a versioned override). true = the schedule runs with no override.
HappyHourConfig.DefaultEnabled = true

-- ─── Events ───────────────────────────────────────────────────────────────────────────────────

local GOLD = Color3.fromRGB(255, 205, 60)

HappyHourConfig.Events = table.freeze({
	confetti = table.freeze({
		id = "confetti",
		name = "CONFETTI STORM",
		short = "CONFETTI",
		blurb = "Coins rain from the clouds. Walk into them!",
		tagline = "Coins rain from the clouds!",
		banner = "Coins are raining from the clouds!",
		icon = "GiftBox",
		color = "purple",
		sound = "fanfare",
		world = nil,
		pickup = table.freeze({
			style = "fall",
			meshKey = "Hub_Coin",
			goldenMeshKey = "Shop_GemCluster",
			goldenTint = nil,
			scale = 0.55,
			maxLive = 4,
			maxPerEvent = 30,
			intervalMin = 6,
			intervalMax = 10,
			batch = 1,
			life = 22,
			incomeSeconds = 8,
			goldenChance = 0.1,
			goldenGems = 2,
			maxGoldenPerEvent = 2,
			dropHeight = 40,
			fallSeconds = 1.8,
		}) :: PickupDef,
	}) :: EventDef,
	sprinkle = table.freeze({
		id = "sprinkle",
		name = "SPRINKLE SURGE",
		short = "SPRINKLES",
		blurb = "Rare Surprise Batch flavours pop more often!",
		tagline = "Rare flavours pop 2x as often!",
		banner = "Rare flavours are 2x as likely!",
		icon = "Star",
		color = "cyan",
		sound = "fanfare",
		world = nil,
		luck = 2,
		miniLuck = 1.5,
	}) :: EventDef,
	doublePops = table.freeze({
		id = "doublePops",
		name = "DOUBLE POPS",
		short = "DOUBLE POPS",
		blurb = "Every payout pops twice: +25% cash!",
		tagline = "Every payout pops twice: +25%!",
		banner = "Every payout pops twice: +25% cash!",
		icon = "x2Cash",
		color = "green",
		sound = "fanfare",
		world = nil,
		cashMultiplier = 1.25,
	}) :: EventDef,
	stampede = table.freeze({
		id = "stampede",
		name = "EGG STAMPEDE",
		short = "STAMPEDE",
		blurb = "Dino eggs are running wild in Dino Valley. Catch them!",
		tagline = "Catch the running dino eggs!",
		banner = "Catch the running dino eggs!",
		icon = "Egg",
		color = "orange",
		sound = "dino_happy_roar",
		world = "dino",
		pickup = table.freeze({
			style = "run",
			meshKey = "DinoEgg",
			goldenMeshKey = "DinoEgg",
			goldenTint = GOLD,
			scale = 1.1,
			maxLive = 6,
			maxPerEvent = 24,
			intervalMin = 12,
			intervalMax = 18,
			batch = 3,
			life = 16,
			incomeSeconds = 10,
			goldenChance = 0.1,
			goldenGems = 2,
			maxGoldenPerEvent = 2,
			runSpeed = 8,
			runSpread = 16,
			runPause = 0.6,
		}) :: PickupDef,
	}) :: EventDef,
	lowGravity = table.freeze({
		id = "lowGravity",
		name = "LOW-GRAVITY HOUR",
		short = "LOW GRAVITY",
		blurb = "Float sky-high on Moon Base and grab the moon rocks!",
		tagline = "Floaty jumps + moon rocks!",
		banner = "Big floaty jumps! Grab the floating moon rocks!",
		icon = "WorldMoon",
		color = "sky",
		sound = "star_chime",
		world = "moon",
		-- x0.9 on top of Moon Base's 0.4: apex stays inside every server reach check
		-- (tests/happy-hours.luau proves it against TycoonService.PadReachVertical), and the glide
		-- makes the fall feather-soft without raising the apex.
		gravityMultiplier = 0.9,
		glideFallSpeed = 18,
		pickup = table.freeze({
			style = "float",
			meshKey = "Shop_MoonRocksSmall",
			goldenMeshKey = "Shop_GemCluster",
			goldenTint = nil,
			scale = 0.7,
			maxLive = 5,
			maxPerEvent = 24,
			intervalMin = 5,
			intervalMax = 8,
			batch = 1,
			life = 25,
			incomeSeconds = 8,
			goldenChance = 0.1,
			goldenGems = 2,
			maxGoldenPerEvent = 2,
			floatMin = 10,
			floatMax = 16,
		}) :: PickupDef,
	}) :: EventDef,
} :: { [EventId]: EventDef })

-- Every event id (admin enum, analytics, tests), in rotation order.
HappyHourConfig.EventIds =
	table.freeze({ "confetti", "sprinkle", "doublePops", "stampede", "lowGravity" } :: { EventId })

--[[
	The event definition of an id, or nil for anything that is not a known event id.
	Example: HappyHourConfig.get("stampede").world --> "dino"
]]
function HappyHourConfig.get(id: unknown): EventDef?
	if type(id) ~= "string" then
		return nil
	end
	return (HappyHourConfig.Events :: any)[id]
end

-- ─── Admin override (Server/HappyHour/HappyHourOverrideStore) ─────────────────────────────────

HappyHourConfig.Override = table.freeze({
	-- Skipped / stopped slot starts kept (oldest dropped first).
	MaxSkips = 16,
	-- Forced event length bounds (seconds); the admin default is the event's normal length.
	ForceMinSeconds = 30,
	ForceMaxSeconds = 1800,
	-- A forced start may be scheduled at most this far ahead (seconds) — now, in practice.
	ForceMaxLead = 3600,
	-- Skips older than this (seconds) are pruned.
	SkipKeepSeconds = 3600,
	-- Cross-server persistence + fan-out (both optional: Studio without API access = this server).
	StoreName = "SellNukesHappyHour_v1",
	StoreKey = "override",
	Topic = "SellNukesHappyHour_v1",
	-- Seconds between DataStore polls (safety net for a missed MessagingService message).
	PollSeconds = 90,
	-- Largest encoded override accepted from the store / a message (bytes).
	MaxWireBytes = 1200,
})

-- Server → client override + live state (ReplicatedStorage attributes; clients rebuild the
-- override from them with HappyHourLogic.overrideFromAttributes).
HappyHourConfig.Attributes = table.freeze({
	Version = "HappyHourVersion", -- number: override version (bumps on every admin change)
	Kill = "HappyHourKill", -- boolean: kill switch (no events at all)
	ForceId = "HappyHourForceId", -- string: forced event id ("" = none)
	ForceStart = "HappyHourForceStart", -- number: unix start of the forced event
	ForceEnd = "HappyHourForceEnd", -- number: unix end of the forced event
	Skips = "HappyHourSkips", -- string: comma-separated skipped slot starts
	Live = "HappyHourLive", -- string: the server's effective live event id ("" = none; QA / admin)
})

-- ─── Pickups (shared server / client rules) ───────────────────────────────────────────────────

HappyHourConfig.Pickups = table.freeze({
	IdPrefix = "H",
	IdMaxLength = 12,
	-- Client: walking within CatchRadius (studs, root to pickup) sends the collect intent; it
	-- retries every RetrySeconds while still inside until the server answers.
	CatchRadius = 5,
	RetrySeconds = 0.5,
	-- Server: accepted distance = CatchRadius + ServerSlack (the server's copy of the character
	-- trails the client by the ping), checked now and LagSamples seconds ago (moving pickups).
	ServerSlack = 8,
	LagSamples = table.freeze({ 0, 0.4, 0.8 }),
	-- Height difference (studs) ignored before it counts toward the distance (root vs pickup);
	-- floating pickups use the tight one, so a moon rock really takes a (floaty) jump.
	VerticalTolerance = 4,
	FloatVerticalTolerance = 1,
	-- Seconds between two collections by one player.
	CollectCooldown = 0.15,
	CollectBurst = 8, -- HappyHourCollect token bucket
	CollectPerSecond = 4,
	-- Placement around a player who is NOT on their own plot (hub / another plot): a ring of
	-- RingMin..RingMax studs round the character, dropped onto the ground with one ray
	-- (accepted only within GroundTolerance studs of the character's feet).
	RingMin = 8,
	RingMax = 22,
	GroundTolerance = 8,
	RayUp = 12,
	RayDepth = 40,
	-- Two pickups of one player keep at least this distance (studs).
	MinSpacing = 7,
	-- On the player's own plot a drop lands at most this far from the character (studs; the two
	-- area slots beside them, LuckyButtonService.pickGroundSpot).
	NearRadius = 45,
	-- Cash floor of one pickup = FloorScale x the first pad of the player's current area (a quarter
	-- of a Lucky Button's floor: a storm drops up to 30 of them).
	FloorScale = 0.25,
	-- A fallen coin rests this high above its ground point (studs; centre of the model).
	RestLift = 1.8,
	-- Spawn attempts per spawn (bounded work).
	MaxPicks = 4,
	-- Wire bounds (HappyHourPickupLogic.readWire).
	MaxPoints = 6,
	MaxLife = 120,
	GrantReason = "happyHour",
	-- Client: pickups farther than RenderDistance from the camera are parked.
	RenderDistance = 260,
	-- Client: seconds after t0 + life a pickup whose end message was lost is dropped.
	ExpiryGrace = 2,
})

-- ─── Client presentation ──────────────────────────────────────────────────────────────────────

HappyHourConfig.Client = table.freeze({
	-- HUD pill (UI/Screens/HappyHour/HappyHourChipScreen), design px. Phone: taller so the tap
	-- target is >= 44 pt (UI scale >= 0.62) and the text >= 14 pt; LIVE state only there.
	PillHeight = 52,
	PillHeightPhone = 72,
	PillTextSize = 28,
	PillTextSizePhone = 30,
	PillIconFill = 0.78, -- icon size / pill height
	PillPadding = 10,
	PillCharWidth = 0.6, -- upper-case Fredoka width / text size (width estimate; label is TextScaled)
	-- R138: the phone pill shows only the live countdown ("0:13") at the width of this many
	-- characters. 4 keeps it inside the 162 design px gap beside a measured iPhone 14's cash stack.
	PillCompactChars = 4,
	PillIcon = "Star",
	ChipGap = 14,
	ChipIcon = "Clock", -- schedule panel header icon
	-- Show the NEXT countdown only within this many seconds of the start (else "NEXT: X at 4:00 PM").
	CountdownWithin = 3600,
	-- Start banner (Tycoon/Fx/JuiceBanner) header line, hold (seconds; longer than a milestone's
	-- 2.4 s so nobody misses it) and retry gap while the banner is busy / not built yet.
	BannerHeader = "NUKEY'S HAPPY HOUR",
	BannerSeconds = 5,
	BannerRetrySeconds = 1.5,
	BannerRetries = 4,
	-- Schedule panel copy.
	PanelTitle = "Happy Hours",
	PanelSubtitle = "Every hour on the hour, plus a mini Sprinkle Surge at :30!",
	MiniTagline = "Mini surge: rare flavours x1.5!",
	TravelText = "GO",
	-- Double Pops: a producer's bonus pop waits at least this long after its previous one (seconds).
	BonusPopGap = 0.6,
	-- Confetti Storm sky: clouds (Scenery_Cloud mesh) round the camera + confetti rain emitter.
	CloudKey = "Scenery_Cloud",
	CloudCount = 5,
	CloudHeight = 46,
	CloudRadius = 55,
	CloudScale = 1.6,
	ConfettiRate = 60, -- particles / s (halved on the Low FX tier, none with Reduce Motion)
	-- Claim feedback sounds (AudioConfig.Sfx keys; skipped when a key is missing).
	ClaimSound = "coin_burst",
	GoldenSound = "sparkle",
})

return table.freeze(HappyHourConfig)
