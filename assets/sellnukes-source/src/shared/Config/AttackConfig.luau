--!strict
--[[
	AttackConfig — every tunable of the side Attack mode (spec §9, owner R3: "you can eventually
	start nuking people just for fun, and put up AA towers and upgrade them ... not the primary
	point, a side thing"). Numbers only; the maths lives in Shared/Attack/{AttackLogic, FlightMath}.

	Owner R85 (2026-10-31: "I think we should just allow people to be able to blow people up"):
	attack is OPEN TO EVERYONE. Every player has a starter launcher (StarterLauncher = L1) from the
	start; the Area 7 Attack Console pad now grants Launcher L2 at once (ConsoleLauncher) and unlocks
	the L3..L5 upgrades. Targets are protected only while brand new (NewPlayer: tutorial not done,
	or less than GraceSeconds of play; admin-adjustable live) and under a shield. Until a player
	owns a silo, their nukes rise from the Launch Silos lot (silo 1's spot). Owner R85 also adds
	the paid GOLDEN REVENGE NUKE (31 R$ product "RevengeNuke", AttackConfig.Golden).

	Kid-friendly contract (CLAUDE.md hard rule 7, spec §1/§9):
		* The TARGET NEVER LOSES ANYTHING. A hit MINTS a bonus for the attacker (N seconds of the
		  target's income, clamped to the attacker's own income band) and gives the target a free
		  Revenge launch. Explosions are confetti mushroom clouds.
		* Brand-new players (NewPlayer protection) and shielded players cannot be targeted. AFK
		  players CAN be (owner R43: "AFK nuke system"; they lose nothing).
		* Rival Factories (owner R43) are NPC targets on islands off the map edge, always in the
		  picker, paying a smaller minted reward (a fraction of the attacker's OWN income).

	Progression:
		* The Area 7 Feature pads switch the mode on: "AATower" (a7_aa_tower) gives AA level 1,
		  "AttackConsole" (a7_attack_console) gives Launcher level 1 (HUD Attack button appears).
		* DefenseUpgrade("aa" | "launcher") buys levels 2..MaxLevel with cash. Prices are multiples
		  of the feature pad's own price (TycoonConfig), so they follow the economy tuner.
		* Levels persist through Rebirth but only count while the feature pad is owned again
		  (TycoonLogic.hasFeature), so a rebirthed player gets them back on re-buying the pad.
		* Defence towers (owner R80, AttackConfig.Towers + Shared/Attack/DefenseTowers): the moment
		  a player becomes targetable (area >= UnlockArea) their plot shows blue defence BUY pads;
		  each slot is bought with cash (the first one cheaper than any Area 7 pad) and upgraded
		  L1 -> L5 in the world (UPGRADE billboard by the tower) or in the Defense window
		  (DefenseTower(slot, toLevel)). Every owned tower (the Feature pad's + the slots) fires at
		  every incoming nuke from its own spot on its own schedule (FlightMath.engageMany).

	Time base: every timer (cooldownUntil, shieldUntil, flight t0) is in SERVER time
	(Workspace:GetServerTimeNow(), unix seconds), which clients can read too.

	Connects to: Shared/Attack/* (pure logic), Server/Services/{AttackService, DefenseService},
	Server/Attack/*, Client/Attack/*, Client/UI/Screens/{AttackTarget, Defense}, tests/attack-*.luau,
	MonetizationConfig (Barrage, Shield1h, MegaLauncher), AnalyticsConfig.Metrics.attack.

	Example:
		local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
		print(AttackConfig.Launcher[1].cooldown) --> 30
		print(AttackConfig.AA[5].range)          --> 300
]]

local AttackConfig = {}

--------------------------------------------------------------------------------------------------
-- Unlock + eligibility
--------------------------------------------------------------------------------------------------

-- The Launch Silos area: silos, the Attack Console, the HQ AA Tower pad and every launch point
-- live in this area's slot (AttackGeometry). Since owner R85 it no longer gates who may attack or
-- be attacked (see NewPlayer / StarterLauncher below).
AttackConfig.UnlockArea = 7

--[[ Owner R85 new-player protection: a player can be targeted once BOTH hold — the tutorial is
     finished (profile.tycoon.tutorialStep reached TutorialLogic.DoneStep) when RequireTutorial,
     and they have played GraceSeconds (profile.stats.playSeconds, the lifetime play clock).
     The owner admin changes GraceSeconds live per server (AttackGrace command). ]]
AttackConfig.NewPlayer = table.freeze({
	RequireTutorial = true,
	GraceSeconds = 300,
	MaxGraceSeconds = 86_400, -- admin bound
})

-- Owner R85: every player's launcher level without the Attack Console, and the level the Console
-- pad grants at once (upgrades L3..MaxLevel need the Console: DefenseUpgrade "launcher").
AttackConfig.StarterLauncher = 1
AttackConfig.ConsoleLauncher = 2
-- The TycoonConfig feature keys of the two Area 7 Feature pads (TycoonConfig.FeaturePadOf).
AttackConfig.FeatureAA = "AATower"
AttackConfig.FeatureConsole = "AttackConsole"
-- Highest AA / Launcher level (models AATower1..5, Nuke1..5).
AttackConfig.MaxLevel = 5

--[[ No AFK protection (owner R43, 2026-10-30): the owner's brief is an "AFK nuke system" and a
     target never loses anything, so an away player stays targetable. Only the area >= UnlockArea
     rule and shield bubbles protect a player. ]]

--------------------------------------------------------------------------------------------------
-- Levels
--------------------------------------------------------------------------------------------------

export type LauncherLevel = {
	cooldown: number, -- seconds between normal launches
	rewardSeconds: number, -- seconds of (clamped) target income minted per hit
	armor: number, -- 0..1: multiplies the defender's intercept chance by (1 - armor)
	tier: number, -- nuke model tier (Nuke1..Nuke5)
}

-- Launcher (Attack Console) levels: faster reloads, bigger rewards, tougher nukes.
-- Balance (a SIDE mode, owner R3): reward / cooldown ≈ 0.27x .. 0.67x of the attacker's own income
-- against an equal-income target before interceptions — a fun bonus, never better than the tycoon.
-- Every number only improves with level (owner rule: no purchase lowers a shown number).
AttackConfig.Launcher = table.freeze({
	table.freeze({ cooldown = 30, rewardSeconds = 8, armor = 0, tier = 1 }),
	table.freeze({ cooldown = 27, rewardSeconds = 9, armor = 0.08, tier = 2 }),
	table.freeze({ cooldown = 24, rewardSeconds = 10, armor = 0.16, tier = 3 }),
	table.freeze({ cooldown = 21, rewardSeconds = 11, armor = 0.24, tier = 4 }),
	table.freeze({ cooldown = 18, rewardSeconds = 12, armor = 0.32, tier = 5 }),
} :: { LauncherLevel })

export type AALevel = {
	range: number, -- studs from the turret muzzle within which interceptors can meet a nuke
	reload: number, -- seconds between two interceptor shots
	chance: number, -- 0..1 chance that one interceptor stops a nuke (before armor)
}

-- AA tower levels: range / fire rate / intercept chance (spec §9).
AttackConfig.AA = table.freeze({
	table.freeze({ range = 260, reload = 1.5, chance = 0.22 }),
	table.freeze({ range = 300, reload = 1.25, chance = 0.25 }),
	table.freeze({ range = 340, reload = 1.05, chance = 0.28 }),
	table.freeze({ range = 380, reload = 0.9, chance = 0.31 }),
	table.freeze({ range = 430, reload = 0.75, chance = 0.34 }),
} :: { AALevel })

export type UpgradeKind = "aa" | "launcher"
-- Every DefenseUpgrade kind (the remote's allowlist; also the analytics <aaKind> ids).
AttackConfig.UpgradeKinds = table.freeze({ "aa", "launcher" } :: { UpgradeKind })

--[[
	Upgrade prices: level L costs `pad price x CostMultiplier[L]` (L = 2..MaxLevel), where the pad
	is the kind's Area 7 Feature pad (a7_aa_tower / a7_attack_console). With the tuned economy
	(docs/economy.md) L2 is a few minutes of late-area-7 income, L5 lands in area 9-10.
]]
AttackConfig.CostMultiplier = table.freeze({ [2] = 4, [3] = 40, [4] = 400, [5] = 4000 } :: { [number]: number })

--------------------------------------------------------------------------------------------------
-- Defence towers (owner R80, 2026-10-31: "there are no buttons to like buy AA towers or anything
-- like that for your island. Or your plot. So people can just nuke you. Without having any
-- defense system. And they need to be upgradable.")
--
-- Extra AA tower SLOTS on every plot, on top of the Area 7 "AA Tower" Feature pad's tower (the
-- "HQ" tower, still levelled by DefenseUpgrade("aa")). Pure rules: Shared/Attack/DefenseTowers;
-- server: DefenseService (pads, towers, engagement, DefenseTower remote); world objects:
-- Server/Attack/AttackWorld; client: Client/Attack/DefenseWorld (in-world BUY / UPGRADE
-- billboards) + Screens/Defense (one card per slot). docs/attack.md §18.
--------------------------------------------------------------------------------------------------

export type TowerSlot = {
	id: string, -- stable id (analytics / admin labels); SAVE DATA is the slot's INDEX, never reorder
	name: string, -- billboard + Defense card name
	where: string, -- Defense card location line ("Left side, by Launch Silos")
	unlockArea: number, -- the pad appears once the player's highest area reaches this (>= UnlockArea)
	at: Vector3, -- PLOT-local ground centre of the tower base (y = the island ground top)
	pricePad: string, -- TycoonConfig pad id whose price x priceFactor is the BUY price
	priceFactor: number,
}

--[[
	Placement — a defence PERIMETER on the open island ground just outside the plot's side curbs
	(plot-local x = ±95; the plot is x ∈ [-80, 80], its border curb at ±81 is a 1.5-stud step).
	Decision (Studio QA, 2026-10-31): spots inside the area slots were either under a building's
	roof (Area 6's factory hall) or hidden behind area buildings, and most areas have no free
	12 x 12 floor at all; the flanks are always open sky, readable as "my base's AA perimeter", never
	inside a locked area's placeholder and independent of any area art. tests/attack-defense.luau
	proves from the shipped HubLayout (world space) on ALL 8 plots: walkable island ground under
	the whole L5 footprint (FootprintHalf), no hub collider / model piece (trees, hills, posts,
	ponds) within 0.5 studs, and never on another plot (the wedge between two plots is >= 90 studs
	wide from z 70). Spread over the plot's length so every area is within L1 range of at least two
	slot towers. The HQ tower (Area 7 Feature pad) stays at plot (-32, 402).

	Prices (economy tuner aware: each is a multiple of a real pad's price, so retuning an area's
	SCALE moves them with it; TycoonConfig.friendlyPrice rounds to 2 significant digits). Since
	owner R85 a player is targetable right after the tutorial + a short grace (area 1-2), so the
	ladder starts there and spreads over the run:
		front  1 x a2_counter      the FIRST tower: the first pad of area 2 (owner R80: "people can
		                           just nuke you" — affordable the moment protection ends)
		mid    1 x a3_hq_shell     unlocks at area 3 (its first pad)
		silo   1 x a5_lab_shell    unlocks at area 5
		back   1 x a8_storefront   unlocks at area 8
	Level L (2..MaxLevel) of a slot costs its BUY price x CostMultiplier[L] (the HQ ladder above).
	A slot shows (pad or tower) only while the player is targetable AND their area >= unlockArea.

	Persistence: profile.attack.towers = dense list of stored levels (index = slot, 0 = not bought).
	Never removed by gameplay: a Rebirth keeps every level; towers (and pads) are simply hidden while
	the player's area is below the slot's unlockArea (not targetable then anyway) and build back in
	at their saved level the moment the area reopens.
]]
AttackConfig.Towers = table.freeze({
	Slots = table.freeze({
		table.freeze({
			id = "front",
			name = "Front Tower",
			where = "Left side, near the entrance",
			unlockArea = 1,
			at = Vector3.new(-95, -0.4, 145),
			pricePad = "a2_counter",
			priceFactor = 1,
		}),
		table.freeze({
			id = "mid",
			name = "Middle Tower",
			where = "Right side, middle of your plot",
			unlockArea = 3,
			at = Vector3.new(95, -0.4, 240),
			pricePad = "a3_hq_shell",
			priceFactor = 1,
		}),
		table.freeze({
			id = "silo",
			name = "Silo Tower",
			where = "Left side, next to Launch Silos",
			unlockArea = 5,
			at = Vector3.new(-95, -0.4, 335),
			pricePad = "a5_lab_shell",
			priceFactor = 1,
		}),
		table.freeze({
			id = "back",
			name = "Back Tower",
			where = "Right side, at the back",
			unlockArea = 8,
			at = Vector3.new(95, -0.4, 445),
			pricePad = "a8_storefront",
			priceFactor = 1,
		}),
	} :: { TowerSlot }),
	-- Half-extent (studs) of a slot's square: the L5 tower base (12 x 12) + 0.5 air (tests check it
	-- is clear on every plot).
	FootprintHalf = 6.5,
	-- Interceptor muzzle height above a slot tower's ground centre (studs; range is measured from
	-- it). Slot towers stand on the ground (no plinth), so it is lower than the HQ's MuzzleHeight.
	MuzzleHeight = 8,
	-- Walk-on buy (server Touched on the pad): seconds between two attempts per player, and between
	-- two "Need $X" toasts (Touched fires many times while standing on it).
	TouchDebounce = 0.4,
	NoticeSeconds = 2.5,
	-- Defence BUY pad top colour (the BuyPad mesh's tinted Top): shield blue, unlike any tycoon pad.
	PadColor = Color3.fromRGB(70, 160, 255),
	-- Client: interact reach (studs, horizontal) for E / X / the touch button, per object kind.
	PadReach = 9,
	TowerReach = 12,
	-- Client billboards (Client/Attack/DefenseWorld). Owner R105 ("the site launch gui is clipping":
	-- the Silo Launch producer board overlapped the AA TOWER / SILO TOWER boards): boards are a
	-- constant, smaller pixel size (the old studs part ballooned them up close), the WHOLE board is
	-- the tap target (>= 44 pt on phones), culling distances are shorter, and each board's spot is
	-- solved clear of every producer billboard and of the other defence boards from where players
	-- stand (Client/Attack/DefenseBoardPlacement: the producer boards' own spots + size law,
	-- Tycoon/BillboardPlacement.heightAt; audited by tests/attack-view.luau).
	Billboard = table.freeze({
		Pixels = Vector2.new(150, 84), -- phone / tablet / console board (px; whole board = tap target)
		DesktopPixels = Vector2.new(118, 66), -- desktop board (mouse precision, less clutter)
		-- Base spots (before the clearance solve): above the pad / above the HQ tower's mesh.
		PadOffset = Vector3.new(0, 4.5, 0),
		TowerGap = 2.5,
		-- Slot towers: the board stands like a sign on the PLOT side of the tower (InwardStuds toward
		-- the plot's centre line, SideHeight up) instead of on top — on top it sat in the top-centre
		-- HUD (cash) whenever the camera was close (Studio QA). The HQ tower keeps TowerGap above it.
		InwardStuds = 8,
		SideHeight = 6.5,
		-- Culling (studs; R105: was 90 / 170): towers are read up close, pads from the plot road.
		MaxDistance = 70,
		PadMaxDistance = 120,
		--[[ Clearance solve (Client/Attack/DefenseBoardPlacement). Candidate spots = the base spot
		     moved Lift up, Along the plot's length and Out (away from the plot's centre line), tried
		     cheapest first (Lift x LiftCost + |Along| x AlongCost + Out x OutCost); the first one whose
		     on-screen rectangle (+ MarginPixels) overlaps no producer board within ProducerRadius and
		     no other defence board from ANY eye wins (else the least overlap). Eyes = where players
		     look from, EyeHeight above the ground (Roblox default camera, like
		     TycoonClientConfig.Placement.CameraUp): EyeInward studs toward the road and EyeOutward
		     studs beyond the object, at each EyeAlong offset. A board farther from an eye than its
		     MaxDistance is not drawn there, so it cannot clip. ]]
		Placement = table.freeze({
			Lifts = table.freeze({ 0, 2, 4, 6, 8, 10 } :: { number }),
			Alongs = table.freeze({ 0, 5, -5, 10, -10, 15, -15 } :: { number }),
			Outs = table.freeze({ 0, 5, 10 } :: { number }),
			LiftCost = 1,
			AlongCost = 1.2,
			OutCost = 1,
			EyeHeight = 8,
			EyeInward = table.freeze({ 14, 36 } :: { number }),
			EyeOutward = 12,
			EyeAlong = table.freeze({ -20, 0, 20 } :: { number }),
			MarginPixels = 8,
			ProducerRadius = 150,
			-- Viewport heights (px) assumed when the live camera is not known (tests: the phone is
			-- the worst case — the same board covers the largest share of the screen).
			PhoneViewport = 390,
			DesktopViewport = 900,
		}),
	}),
})

--------------------------------------------------------------------------------------------------
-- Rewards
--------------------------------------------------------------------------------------------------

AttackConfig.Reward = table.freeze({
	--[[ A hit pays rewardSeconds x clamp(targetIncome, attackerIncome x MinRatio, attackerIncome x
	     MaxRatio): rich targets pay more, but never more than MaxRatio x the attacker's own income
	     (so a high-income alt cannot farm a main) and never less than MinRatio of it (hitting a
	     smaller player is still worth it). ]]
	MinRatio = 0.25,
	MaxRatio = 2,
	-- Per-kind reward factor. Barrage nukes are paid (Robux) so each pays double: a full 20-nuke
	-- volley ≈ 160..480 s of income at equal targets (Cash packs: 600 s for 23 R$, 1800 s for 63 R$),
	-- so the Barrage sells the spectacle, never a better cash deal than the shop. The owner R85
	-- golden revenge nuke pays the revenge factor (it sells the strike-back, not cash).
	Factor = table.freeze({ normal = 1, revenge = 1, barrage = 2, golden = 1 }),
	-- Mega Launcher game pass multiplier (MonetizationConfig.Passes.MegaLauncher).
	MegaLauncherPass = "MegaLauncher",
	MegaLauncherMultiplier = 2,
	--[[ Owner R50: a hit that lands but knocks nothing down (the plot is knockdown-immune, the area
	     was already down / rebuilt, a shield went up mid-flight) still pays this fraction of the
	     hit's reward, with the confetti. ]]
	BlockedFactor = 0.35,
})

--------------------------------------------------------------------------------------------------
-- Aiming (owner R50): the attacker picks one of the target's BUILT areas (a Rival Factory section);
-- the server resolves the impact = area centre + seeded scatter that shrinks with launcher level.
--------------------------------------------------------------------------------------------------

AttackConfig.Aim = table.freeze({
	-- Scatter radius (studs) around the aimed area centre per launcher level (L1..L5).
	Scatter = table.freeze({ 24, 20, 16, 12, 8 } :: { number }),
	-- Rival sections are smaller than an area slot: their scatter is scaled by this.
	RivalScatterScale = 0.5,
	-- Slot-local clamp of the scattered point around the area centre (slot x ∈ [-52, 52], centre
	-- z = 35 of [0, 70]): the impact always stays inside the aimed area.
	ClampX = 44,
	ClampZ = 30,
	-- Barrage (owner R50 "may spill into ONE neighbouring area"): each nuke of a volley lands on the
	-- volley's one spill neighbour (a built area next to the aim) with this chance. Knockdown allows
	-- the same attacker at most VolleyMaxAreas areas per volley anyway.
	BarrageSpillChance = 0.3,
})

--------------------------------------------------------------------------------------------------
-- Revenge, Barrage, shields
--------------------------------------------------------------------------------------------------

-- A hit target may launch ONE free Revenge nuke at that attacker within this window (seconds).
-- Revenge ignores the launcher cooldown and the attacker's shield ("you started it"). A REVENGE hit
-- never grants a counter-Revenge token (no endless cooldown-free ping-pong between two friends).
AttackConfig.RevengeSeconds = 180
-- At most this many pending Revenge tokens per player (newest attackers win).
AttackConfig.MaxRevengeTokens = 4

--[[
	Owner R85 GOLDEN REVENGE NUKE ("If you get nuked, add like a 39 ... revenge nuke button that you
	can pay for with Robux"): developer product `Product` (MonetizationConfig "RevengeNuke", 31 R$).
		* The HUD shows a GOLDEN REVENGE button beside the free REVENGE chip while the player who
		  hit you is in the server and hittable (no shield, has a plot); the prompt is refused
		  otherwise (AttackService.refuseGolden).
		* A receipt ALWAYS stores one charge first (profile.attack.golden; idempotent through the
		  per-profile receipt ledger; never yields), then — deferred — fires it at the newest
		  attacker who hit you if they are still here and unshielded. Otherwise the charge stays
		  stored and the player launches it later from the target picker (GOLDEN xN) at anyone
		  targetable: a paid purchase is never lost.
		* A golden nuke: no cooldown, launcher armor + ArmorBonus (capped MaxArmor) vs AA, the gold
		  nuke model (Tier), the revenge reward factor, a big confetti blast (ExplosionScale); its
		  hit never grants a counter-Revenge token (no paid ping-pong).
	Enabled is the kill switch (false hides the button and refuses the prompt; stored charges stay).
]]
AttackConfig.Golden = table.freeze({
	Enabled = true,
	Product = "RevengeNuke",
	ArmorBonus = 0.35,
	MaxArmor = 0.8,
	Tier = 5,
	ExplosionScale = 1.8,
	-- The prompt is refused while this many charges are already stored (receipts never clamp).
	MaxStored = 50,
})

-- Nukes per Barrage launch (stored nukes come from the Barrage product, MonetizationConfig.nukes).
AttackConfig.BarrageSize = 20
-- Seconds between two nukes of a barrage (staggered volley).
AttackConfig.BarrageStagger = 0.2
--[[ Stored Barrage nukes (security audit, Q2 2026-10-30: paid value is never silently lost):
     * the Barrage PROMPT is refused when the pack would not fit under MaxStoredBarrage, so the
       player is told before paying (AttackService.refuseBarrage);
     * a granted RECEIPT is never clamped: it always adds the whole pack (receipts processed back to
       back, or re-delivered after a rejoin, may land above MaxStoredBarrage);
     * BarrageStorageLimit is only the storage bound (= ProfileLogic LIMITS.MaxItemCount, which
       reconciles the saved value). A receipt that would pass it is NOT granted (NotProcessedYet,
       so Roblox never completes a purchase whose nukes could not be stored). ]]
AttackConfig.MaxStoredBarrage = 2000
AttackConfig.BarrageStorageLimit = 1e6

-- Hits taken (since the last free shield) that earn a free shield (ShieldActivate turns it on).
AttackConfig.FreeShieldHits = 3
-- Seconds of the free shield.
AttackConfig.FreeShieldSeconds = 600
-- Total shield time a player may hold (prompting more Shield products is refused above it).
AttackConfig.MaxShieldSeconds = 48 * 3600

--------------------------------------------------------------------------------------------------
-- Flight timeline (Shared/Attack/FlightMath)
--------------------------------------------------------------------------------------------------

AttackConfig.Flight = table.freeze({
	-- t0 is set this far in the future so every client receives the flight before it starts AND the
	-- launch cinematic's "3 … 2 … 1 … LAUNCH!" fits inside it (owner R54): 3 × 1 s beats
	-- (LaunchCamConfig.Countdown) + 0.4 s network slack; "LAUNCH!" lands exactly on t0. Uniform for
	-- every launch kind (normal / revenge / barrage / rival / admin test / bots), so the server and
	-- every client agree; tests/launch-cam.luau fails if the countdown ever stops fitting.
	LeadIn = 3.4,
	-- Flight seconds = clamp(Base + distance / StudsPerSecond, Min, Max).
	BaseSeconds = 3.4,
	StudsPerSecond = 190,
	MinSeconds = 5,
	MaxSeconds = 10,
	-- Arc apex height above the straight line = clamp(distance x ApexPerStud, ApexMin, ApexMax).
	ApexPerStud = 0.42,
	ApexMin = 150,
	ApexMax = 340,
	-- Samples used to find where a flight enters a tower's range (then refined by bisection).
	RangeSamples = 96,
	RangeRefineSteps = 12,
	-- An interceptor flies this long from the muzzle to the meeting point (cartoon, constant time).
	InterceptorSeconds = 0.9,
	-- An interception must happen at least this long before impact (so it reads on screen).
	ImpactMargin = 0.35,
	-- Upper bound of interceptor shots one tower may fire at a single nuke (safety bound).
	MaxShotsPerNuke = 16,
})

--------------------------------------------------------------------------------------------------
-- Geometry (Shared/Attack/AttackGeometry). Fallbacks used until Area07's art layout provides
-- `launchPoints`, `aaTowerMount`, `consolePrompt` (all SLOT-LOCAL, area 7 slot, WorldLayout).
--------------------------------------------------------------------------------------------------

AttackConfig.Geometry = table.freeze({
	-- Silo mouths (slot-local): nukes rise from here. Silo 1 is the Silo Pad, 2 and 3 their pads.
	LaunchPoints = table.freeze({
		CFrame.new(-26, 18, 40),
		CFrame.new(-6, 18, 46),
		CFrame.new(14, 18, 40),
	} :: { CFrame }),
	-- The pads that build silo 1 / 2 / 3 (a silo is only used once its pad is owned).
	SiloPads = table.freeze({ "a7_silo_pad", "a7_silo_2", "a7_silo_3" } :: { string }),
	-- AA turret mount (slot-local; +Y up, turret default facing -Z).
	AATowerMount = CFrame.new(38, 0, 22),
	-- Height of the turret muzzle above the mount (studs); interceptors spawn here.
	MuzzleHeight = 16,
	-- Attack Console ProximityPrompt position (slot-local).
	ConsolePrompt = Vector3.new(-38, 3, 26),
	--[[ Impact points (PLOT-LOCAL, ground level): nukes land in the middle of the base, near
	     the AA tower (area-7 slot, rows 3-5), so the tower can always engage the descent. The
	     point for a nuke is chosen deterministically from its id. ]]
	ImpactPoints = table.freeze({
		Vector3.new(0, 0, 280),
		Vector3.new(0, 0, 340),
		Vector3.new(0, 0, 400),
		Vector3.new(0, 0, 450),
		Vector3.new(-34, 0, 300),
		Vector3.new(34, 0, 326),
		Vector3.new(34, 0, 420),
		Vector3.new(-34, 0, 442),
	} :: { Vector3 }),
	-- Shield dome: centre (plot-local) and size (studs) covering the whole plot.
	ShieldCentre = Vector3.new(0, 0, 260),
	ShieldSize = Vector3.new(190, 150, 560),
})

--------------------------------------------------------------------------------------------------
-- Models (MeshAssets keys, B8f art). Missing keys fall back to code-built primitives.
--------------------------------------------------------------------------------------------------

AttackConfig.Models = table.freeze({
	Nukes = table.freeze({ "Nuke1", "Nuke2", "Nuke3", "Nuke4", "Nuke5" } :: { string }),
	Interceptor = "Interceptor",
	Towers = table.freeze({ "AATower1", "AATower2", "AATower3", "AATower4", "AATower5" } :: { string }),
	ShieldDome = "ShieldDome",
	Puff = "NukePuff",
	-- Piece names inside a tower model that the client aims (yaw / pitch).
	TurretPiece = "Turret",
	BarrelPiece = "Barrel",
})

--[[ Owner R106 "the AA towers should aniamte around": the client-side tower rig animation
     (Client/Attack/TowerAnim, pure maths Shared/Attack/TowerAnimMath). Every AA tower (any plot,
     Rival islands, bots) idles — the turret sweeps / scans, the radar dish spins, the barrels bob —
     and while it engages a nuke it slews onto it (FlightRenderer aims), every shot kicks the
     barrels back with a muzzle flash. One PreRender loop for all towers, culled by distance per
     FxQuality tier, Reduce Motion = no idle sweep / dish / recoil (engagement aim stays: gameplay
     readability). Angles in degrees, speeds in radians / second. ]]
AttackConfig.TowerAnim = table.freeze({
	-- Joints per tower level, mount space (pivot = ground centre, turret faces -Z at rest): from
	-- the Blender builders' notes in MeshAssets.AATower1..5 "joints Turret@(..) Barrel@(..)"
	-- (tests/attack-view.luau keeps them equal). Turret* pieces yaw about the vertical axis through
	-- `turret`, Barrel* pieces pitch about +X through `barrel`.
	Joints = table.freeze({
		table.freeze({ turret = Vector3.new(0, 3.4, 0), barrel = Vector3.new(0, 4.15, -0.6) }),
		table.freeze({ turret = Vector3.new(0, 4.8, 0), barrel = Vector3.new(0, 5.35, -0.8) }),
		table.freeze({ turret = Vector3.new(0, 6.95, 0), barrel = Vector3.new(0, 7.9, -0.9) }),
		table.freeze({ turret = Vector3.new(0, 6.7, 0), barrel = Vector3.new(0, 7.8, -1.1) }),
		table.freeze({ turret = Vector3.new(0, 9.6, 0), barrel = Vector3.new(0, 11, -1.4) }),
	}),
	-- Idle scan: yaw = Sweep x sin(SweepSpeed t + phase) + Sweep x Wobble x sin(2.3 SweepSpeed t).
	SweepDegrees = 55,
	SweepSpeed = 0.42,
	Wobble = 0.22,
	-- Idle barrel elevation (absolute; mesh barrels rest level) bobbing by PitchBobDegrees.
	PitchRestDegrees = 20,
	PitchBobDegrees = 8,
	PitchBobSpeed = 0.7,
	-- Radar dish spin (idle / while engaging).
	DishSpeed = 2.4,
	DishEngagedSpeed = 6,
	-- Smoothing rates (1 / s) toward the idle pose / the engagement aim (exponential follow).
	IdleFollow = 2.5,
	AimFollow = 16,
	-- Seconds one FlightRenderer aim keeps a tower engaged (it aims every frame while it does).
	EngageHold = 0.35,
	-- Recoil per shot: barrels slide back RecoilStuds (x level scale) and kick up, easing home.
	RecoilSeconds = 0.3,
	RecoilStuds = 0.7,
	RecoilKickDegrees = 6,
	-- Muzzle flash: pooled neon balls + lights (no per-shot Instance.new).
	FlashSeconds = 0.1,
	FlashPool = 6,
	FlashSize = 1.6,
	FlashColor = Color3.fromRGB(255, 214, 120),
	-- Idle animation distance (studs) per FxQuality tier; 0 = idle off on that tier (engagements
	-- and shots still animate).
	Cull = table.freeze({ Low = 0, Mid = 200, High = 340 }),
	-- Engaging towers and shots are animated out to this distance (studs).
	AimDistance = 900,
	-- Idle towers beyond this many studs update every other frame.
	HalfRateBeyond = 110,
	-- Seconds after a BuildIn stamp before a freshly bought tower starts to idle (its fly-in).
	BuildInHold = 6,
})

--[[ Owner R109 "make sure when you launch rockets the rockets actually leave the base and recharge
     load back": the Launch Silos' standing rockets (Area07 A7_SiloNuke_*) lift off on every launch
     and reload (Client/Attack/SiloLaunch, pure maths Shared/Attack/SiloLaunchMath). Driven by the
     NukeFlight broadcast every client already gets (fromPlot, silo, t0, kind, tier): everyone sees
     it. The server's rocket is never moved — it is hidden locally (LocalTransparencyModifier) and a
     pooled client clone flies / reloads in its place.
     Timeline (server time, t0 = the flight start):
       t0 - IgniteLead .. t0    ignite: flame + smoke, the rocket shakes and rises SlowRise studs
       t0 .. t0 + HandOff       lift-off: it climbs fast and blends onto the flight arc, shrinking
                                to the flight nuke's length; FlightRenderer draws the flight nuke
                                from t0 + HandOff (a smoke puff covers the swap)
       t0 + HandOff .. + reload the gantry stands empty while a fresh rocket rises ReloadDepth
                                studs back into it, fading from ReloadFade to solid, with a pulsing
                                "RELOADING" glow + stud board; reload = the launcher cooldown
                                (normal), QuickReload for revenge / golden / barrage. ]]
AttackConfig.SiloFx = table.freeze({
	IgniteLead = 1.3,
	SlowRise = 3,
	ShakeStuds = 0.18,
	HandOff = 0.8,
	-- Extra climb during the hand-off before the blend takes over: Climb x t + ClimbAccel x t².
	Climb = 25,
	ClimbAccel = 70,
	-- Standing rocket length (Area07 NUKE_LEN): its pivot is the tail, the nose = the launch point.
	SiloLength = 24,
	-- Flight nuke length when the template carries no Length attribute (AttackWorld NUKE_LENGTH).
	FlightLength = 10,
	ReloadDepth = 10,
	ReloadFade = 0.65,
	QuickReload = 8,
	MinReload = 3,
	-- Reduce Motion: no flight / rise — the rocket fades out at t0 and back in when reloaded.
	ReducedFade = 0.35,
	-- Culling (studs from the camera): launches (own launches always), reload clones / boards.
	CullDistance = 700,
	ReloadDistance = 350,
	-- Pools: clones per rocket art key, RELOADING highlights (Roblox caps live Highlights), boards.
	ClonesPerKey = 6,
	MaxHighlights = 6,
	MaxBoards = 6,
	GlowColor = Color3.fromRGB(255, 170, 40),
	BoardPixels = Vector2.new(150, 48),
	BoardLift = 5,
	BoardMaxDistance = 160,
	-- Smoke particles per second while igniting / lifting off, per FxQuality tier.
	Smoke = table.freeze({ Low = 10, Mid = 22, High = 36 }),
})

-- Name of the ReplicatedStorage folder the server fills with client templates (Nuke1..5, ...).
AttackConfig.TemplateFolder = "AttackTemplates"
-- Name of the per-plot folder (Workspace.Plots.PlotN.<name>) holding the turret + dome.
AttackConfig.PlotFolder = "Attack"
-- CollectionService tags the client watches.
AttackConfig.Tags = table.freeze({
	Turret = "SN_AATurret",
	Dome = "SN_ShieldDome",
	Console = "SN_AttackConsole", -- prompt parts (attrs OwnerUserId, Opens = "Attack" | "Defense")
	-- Owner R80 defence BUY pads (Models: attrs OwnerUserId, Plot, Tower, Cost; child Trigger).
	DefensePad = "SN_DefensePad",
})

--------------------------------------------------------------------------------------------------
-- Rival Factories (owner R43 "i have the silos but i cannot attack anyone"): NPC targets so Attack
-- mode is ALWAYS usable, solo and in early servers. Shared/Attack/{AttackLogic, AttackGeometry},
-- Server/Attack/RivalIslands (world), DefenseService (towers + shield domes), AttackService.
--------------------------------------------------------------------------------------------------

export type RivalShield = {
	every: number, -- seconds between two shield bubbles (0 = this rival never shields)
	lasts: number, -- seconds each bubble stays up (< every)
	offset: number, -- phase in seconds, so the rivals never all shield at the same moment
}

export type RivalDef = {
	id: string, -- wire id (AttackLaunch target) and analytics <rivalId>
	name: string, -- picker name plate + the island's entrance sign
	aa: number, -- AA tower level 1..MaxLevel (the difficulty ladder)
	rewardRatio: number, -- hit reward = rewardSeconds x ATTACKER income x rewardRatio x factor(kind)
	bearing: number, -- degrees around the hub (WorldLayout plot i sits at (i - 1) x 45)
	area: number, -- AreaLayouts/AreaNN whose fully built set dresses the island base
	floor: number, -- that layout's floor top (island-local y): plinth + impacts stand on it
	tower: Vector3, -- A7_AATower plinth ground centre (island-local; turret mounts on its top)
	color: Color3, -- entrance sign accent tint + picker accent
	shield: RivalShield,
}

export type RivalDressing = { key: string, cf: CFrame }

--[[
	Island-local frame (AttackGeometry.rivalFrame): the WorldLayout slot convention — origin = the
	base's front edge midpoint, +Z AWAY from the hub, +Y up, base x ∈ [-52, 52], z ∈ [0, 70]
	(exactly one area slot, so an AreaLayouts module drops in unchanged); island centre (0, 0, 35).
	World = CFrame.Angles(0, bearing, 0) * CFrame.new(0, BaseY, Radius - 35): the centre sits Radius
	studs from the hub on that bearing, and model fronts (-Z) face the hub (the picker camera and
	every player look at the factory fronts).

	Placement (tests/attack-rivals.luau): the main island's beach ends at r 874 (HubLayout WALL_R 880
	is the invisible boundary ring) and the sea runs to r 2000 (Scenery_Water). Islands sit on the
	plot bisectors 22.5° + 90° k at r 1080: their dressing reaches ~62 studs from the centre, so
	every island is > 130 studs of open sea outside the boundary ring, never overlaps a plot, the
	hub or another island, and is a short hop from two neighbouring plots.

	Rewards: rewardRatio <= MaxRewardRatio (0.5) < 1, so a Rival hit always pays LESS than hitting
	an equal-income player (the R43 "smaller minted reward"), and it scales with the attacker's
	own income, so it can never be farmed past the tycoon. Harder rivals (higher AA, more shields)
	pay more per hit but stop more nukes.
]]
AttackConfig.Rivals = table.freeze({
	-- Workspace folder holding one Folder per rival island (Server/Attack/RivalIslands).
	Folder = "AttackRivals",
	-- Island centre distance from the hub centre (studs) and the island-local frame height (the
	-- base floor tops sit ~0.3 studs above the Scenery_Water surface at y = -2.4).
	Radius = 1080,
	BaseY = -2.5,
	Centre = Vector3.new(0, 0, 35),
	-- Height of the A7_AATower plinth top above its pivot (AATower1..5 stand there).
	TowerMountY = 1,
	-- Impact points (island-local x / z on the base floor; y = the rival's floor).
	ImpactPoints = table.freeze({
		Vector3.new(-24, 0, 22),
		Vector3.new(0, 0, 30),
		Vector3.new(24, 0, 22),
		Vector3.new(-36, 0, 46),
		Vector3.new(0, 0, 52),
		Vector3.new(36, 0, 46),
		Vector3.new(-14, 0, 62),
		Vector3.new(14, 0, 62),
	} :: { Vector3 }),
	-- Shield dome over the whole island (centre island-local on the floor; size in studs).
	ShieldCentre = Vector3.new(0, 0, 38),
	ShieldSize = Vector3.new(160, 96, 124),
	-- Picker camera over an island (closer than over a 520-stud plot): height / distance toward
	-- the hub from the island centre.
	PickerHeight = 170,
	PickerBack = 130,
	-- Upper bound of every rewardRatio (tests): always below an equal-income player hit (1).
	MaxRewardRatio = 0.5,
	--[[ Owner R50: each base has 4 sections the attacker aims at: four strips across the 104 x 70
	     base (island-local x, left to right as seen from the hub side), so every area set fills every
	     section (tests/attack-aim). A hit knocks the section down (Knockdown.knockInstance: topple +
	     rebuild FX) for SectionDownSeconds. A base model belongs to the strip of its pivot; floors
	     (KeepKeys), the sign arch, the AA plinth and the dressing never topple. ]]
	Sections = table.freeze({
		table.freeze({ label = "TOY SHOP", centre = Vector3.new(-39, 0, 35), half = Vector3.new(13, 0, 35) }),
		table.freeze({ label = "WORKSHOP", centre = Vector3.new(-13, 0, 35), half = Vector3.new(13, 0, 35) }),
		table.freeze({ label = "WAREHOUSE", centre = Vector3.new(13, 0, 35), half = Vector3.new(13, 0, 35) }),
		table.freeze({ label = "BIG MACHINE", centre = Vector3.new(39, 0, 35), half = Vector3.new(13, 0, 35) }),
	}),
	SectionDownSeconds = 30,
	-- Base model keys that never topple (floors / decks / plazas stay under the toppled builds).
	KeepKeys = table.freeze({
		A5_Floor = true,
		A5_CleanRoomFloor = true,
		A6_Floor = true,
		A7_Deck = true,
		A7_HazardFloor = true,
		A8_Plaza = true,
	} :: { [string]: boolean }),
	-- Entrance sign: the plot entrance arch mesh (its OwnerSign panels carry the rival's name).
	SignKey = "Plot_EntranceArch",
	SignPiece = "OwnerSign",
	SignZ = 5,
	-- Layout keys never built on an island: entry arches (the sign arch replaces them) and the AA
	-- plinth (placed at `tower` for every rival instead).
	SkipKeys = table.freeze({
		A5_EntryArch = true,
		A6_EntryArch = true,
		A7_EntryArch = true,
		A8_EntryArch = true,
		A7_AATower = true,
	} :: { [string]: boolean }),
	-- Island dressing (existing Blender scenery, island-local; the sea surface is y = +0.1 here):
	-- sunk hills behind and beside the base, rocks along the shore, pines on the hill tops.
	Dressing = table.freeze({
		{ key = "Scenery_Hill", cf = CFrame.new(-46, -5, 84) * CFrame.Angles(0, math.rad(20), 0) },
		{ key = "Scenery_Hill", cf = CFrame.new(0, -6, 90) * CFrame.Angles(0, math.rad(-10), 0) },
		{ key = "Scenery_Hill", cf = CFrame.new(46, -5, 84) * CFrame.Angles(0, math.rad(200), 0) },
		{ key = "Scenery_HillSmall", cf = CFrame.new(-64, -2, 20) * CFrame.Angles(0, math.rad(60), 0) },
		{ key = "Scenery_HillSmall", cf = CFrame.new(-66, -2, 54) },
		{ key = "Scenery_HillSmall", cf = CFrame.new(64, -2, 28) * CFrame.Angles(0, math.rad(-30), 0) },
		{ key = "Scenery_HillSmall", cf = CFrame.new(66, -2, 58) * CFrame.Angles(0, math.rad(90), 0) },
		{ key = "Scenery_Rock", cf = CFrame.new(-50, 0, -6) },
		{ key = "Scenery_Rock", cf = CFrame.new(-30, 0, -9) * CFrame.Angles(0, math.rad(70), 0) },
		{ key = "Scenery_Rock", cf = CFrame.new(28, 0, -8) * CFrame.Angles(0, math.rad(140), 0) },
		{ key = "Scenery_Rock", cf = CFrame.new(52, 0, -5) * CFrame.Angles(0, math.rad(200), 0) },
		{ key = "Scenery_Rock", cf = CFrame.new(-60, 0, 74) * CFrame.Angles(0, math.rad(30), 0) },
		{ key = "Scenery_Rock", cf = CFrame.new(60, 0, 76) * CFrame.Angles(0, math.rad(260), 0) },
		{ key = "Scenery_TreePine", cf = CFrame.new(-46, 7, 84) },
		{ key = "Scenery_TreePine", cf = CFrame.new(2, 6, 90) },
		{ key = "Scenery_TreePine", cf = CFrame.new(44, 7, 84) },
		{ key = "Hub_Tree", cf = CFrame.new(-66, 4, 54) * CFrame.Angles(0, math.rad(40), 0) },
		{ key = "Hub_Tree", cf = CFrame.new(66, 4, 58) * CFrame.Angles(0, math.rad(160), 0) },
	} :: { RivalDressing }),
	-- The rivals, easiest first (picker order). Bearings: plot bisectors 22.5° + 90° k.
	List = table.freeze({
		table.freeze({
			id = "toy_factory",
			name = "Rival Toy Factory",
			aa = 1,
			rewardRatio = 0.2,
			bearing = 22.5,
			area = 6,
			floor = 0.4,
			tower = Vector3.new(42, 0.4, 9),
			color = Color3.fromRGB(255, 170, 60),
			shield = table.freeze({ every = 0, lasts = 0, offset = 0 }),
		}),
		table.freeze({
			id = "grumpy_gus",
			name = "Grumpy Gus's Nukes",
			aa = 2,
			rewardRatio = 0.3,
			bearing = 112.5,
			area = 7,
			floor = 0.5,
			tower = Vector3.new(43.5, 0.5, 60),
			color = Color3.fromRGB(120, 200, 90),
			shield = table.freeze({ every = 240, lasts = 30, offset = 0 }),
		}),
		table.freeze({
			id = "professor_fizz",
			name = "Professor Fizz's Lab",
			aa = 3,
			rewardRatio = 0.4,
			bearing = 202.5,
			area = 5,
			floor = 0.4,
			tower = Vector3.new(42, 0.4, 9),
			color = Color3.fromRGB(110, 190, 255),
			shield = table.freeze({ every = 240, lasts = 45, offset = 80 }),
		}),
		table.freeze({
			id = "mega_meltdown",
			name = "Mega Meltdown Mart",
			aa = 5,
			rewardRatio = 0.5,
			bearing = 292.5,
			area = 8,
			floor = 0.5,
			tower = Vector3.new(42, 0.5, 9),
			color = Color3.fromRGB(190, 110, 255),
			shield = table.freeze({ every = 300, lasts = 60, offset = 160 }),
		}),
	} :: { RivalDef }),
})

--------------------------------------------------------------------------------------------------
-- Public per-player state (server-set Player attributes, replicated to every client)
--------------------------------------------------------------------------------------------------

AttackConfig.Attr = table.freeze({
	-- true while the player may be picked as a target (loaded, has a plot, not brand new: R85).
	Targetable = "SN_AttackTargetable",
	-- Server time the player's shield ends (0 = none).
	ShieldUntil = "SN_ShieldUntil",
	-- Effective AA level (0 = no tower) — target picker info.
	AALevel = "SN_AALevel",
	-- Effective launcher level (0 = no console) — nuke tier shown to others.
	LauncherLevel = "SN_LauncherLevel",
	-- Plot index of the player (0 = none), mirrored from the plot model's OwnerUserId.
	Plot = "SN_AttackPlot",
	-- ReplicatedStorage attribute: false while the owner admin switched Rival Factories off on
	-- this server (AttackRivals command); missing / true = on.
	RivalsOn = "SN_AttackRivalsOn",
	-- Owner R50: the player's BUILT areas (Knockdown.builtAreas), comma separated ("1,2,3"): the
	-- picker draws one aim marker per entry.
	Areas = "SN_AttackAreas",
	-- Owner R80: active AA towers defending the player (the HQ Feature tower + built defence slots),
	-- shown in the target picker ("3 AA towers").
	Towers = "SN_AttackTowers",
})

--------------------------------------------------------------------------------------------------
-- Admin attack test bots (owner R51; Server/Attack/TestBots, Admin "Attack" tab)
--------------------------------------------------------------------------------------------------

AttackConfig.Bots = table.freeze({
	-- Live bots per server (each holds a free plot; a joining player always evicts one).
	Max = 6,
	-- A bot removes itself this long after it was spawned (seconds).
	LifetimeSeconds = 30 * 60,
	-- Fastest auto-attack interval (seconds).
	MinAutoSeconds = 5,
	-- Shield length when an admin turns a bot's shield on (seconds).
	ShieldSeconds = 3600,
	-- The bot's launcher level when it attacks (nuke tier, knockdown duration).
	LauncherLevel = 3,
	-- ReplicatedStorage folder of the bots' public mirrors (Configuration per bot) for the picker.
	Folder = "AttackBots",
	-- Wire prefix of a bot target id ("bot:3").
	KeyPrefix = "bot:",
})

--------------------------------------------------------------------------------------------------
-- Server limits
--------------------------------------------------------------------------------------------------

AttackConfig.RateLimits = table.freeze({
	-- AttackLaunch requests per player: burst / refill per second.
	Launch = table.freeze({ capacity = 4, refill = 0.5 }),
	DefenseUpgrade = table.freeze({ capacity = 6, refill = 1 }),
	-- Owner R80 DefenseTower(slot, toLevel) intents (Defense window, billboards, E / X, walk-on).
	DefenseTower = table.freeze({ capacity = 6, refill = 1 }),
	ShieldActivate = table.freeze({ capacity = 3, refill = 0.2 }),
	-- Owner R104 AttackPickerFocus(slot) intents (picker open / < > cycling / keep-alive / close).
	PickerFocus = table.freeze({ capacity = 10, refill = 4 }),
})
-- Nukes in flight server-wide (a hard bound on the impact queue; barrages share it).
AttackConfig.MaxNukesInFlight = 240
-- One attacker's share of it (3 full barrages), so one player can never saturate the server cap
-- and starve everyone else's launches (security audit, low).
AttackConfig.MaxNukesInFlightPerAttacker = 60
-- Seconds the server coalesces hit / intercept toasts into one summary per player.
AttackConfig.ToastCoalesceSeconds = 0.8
AttackConfig.ToastMaxDelaySeconds = 3

--------------------------------------------------------------------------------------------------
-- Client presentation
--------------------------------------------------------------------------------------------------

AttackConfig.Client = table.freeze({
	-- Studs from the camera beyond which flights are not rendered (only the toast shows).
	RenderDistance = 1600,
	-- Pool sizes (nukes, interceptors, explosion rigs).
	NukePool = 24,
	InterceptorPool = 16,
	ExplosionPool = 8,
	-- Legacy whole-plot view: height above / distance toward the hub from PickerFocus (studs). Owner
	-- R50 put all ten areas in view from ~890 studs; owner R133 showed that a live client draws
	-- NOTHING from that far (empty blue sky), so the camera now uses PickerFrame below.
	-- AttackGeometry.pickerView still uses these for the default stream focus point.
	PickerHeight = 880,
	PickerBack = 110,
	-- Picker camera field of view (degrees). Owner R133: 52 -> 66 so the close-up framing still
	-- shows a whole row of areas (both sides of the road) inside the band between the UI blocks.
	PickerFov = 66,
	--[[ Owner R133 ("when attacking people all I see is this, not their base still"): the picker
	     frames the target's BUILT areas from close up (Shared/Attack/PickerFrame). The camera looks
	     away from the hub at `Pitch` degrees below the horizon, as close as fits the built footprint
	     (+ `Pad`) inside the band between the name plate and the button row (`FitX`, `FitTop`,
	     `FitBottom`: shares of the half-FOV, screen centre = 0, up = +), and never farther than
	     `MaxDistance` — beyond that the view slides along the plot to keep the AIMED area in view
	     (LB / RB / the chips pan the camera). `Aspect` bounds the viewport aspect the maths uses. ]]
	PickerFrame = table.freeze({
		Pitch = 66,
		MinDistance = 110,
		MaxDistance = 320,
		Pad = 10,
		FitX = 0.92,
		FitTop = 0.55,
		FitBottom = -0.6,
		Aspect = table.freeze({ Min = 1.0, Max = 2.4, Default = 16 / 9 }),
		-- Binary-search steps for the distance / slide (each halves the error; 20 => < 0.001 stud).
		Steps = 20,
	}),
	-- Seconds a "REVENGE!" chip stays (bounded by the server's RevengeSeconds).
	RevengeChipSeconds = 180,
	-- Building wobble on a hit: radius (studs), seconds, max tilt (degrees).
	WobbleRadius = 70,
	WobbleSeconds = 0.9,
	WobbleDegrees = 5,
	MaxWobbleModels = 12,
	-- Picker camera tween between targets (seconds) and the plot-local point it looks at.
	PickerTween = 0.45,
	PickerFocus = Vector3.new(0, 0, 300),
	-- Studs the client asks the engine to stream in around a picked target plot.
	PickerStreamRadius = 260,
	--[[ Owner R104 "you cant see peoples bases in the attack menu": streaming the picked target in.
	     Root cause of the empty-sky picker: Workspace.StreamingEnabled with StreamOutBehavior
	     Opportunistic, a StreamingTargetRadius (768) around the CHARACTER only, and other plots /
	     Rival islands 900-1300 studs away. A RequestStreamAroundAsync alone is temporary, so the
	     target never arrived (or streamed straight back out). Now the server keeps a replication
	     focus at the picker focus while the picker is open (Server/Attack/PickerFocus,
	     Player:AddReplicationFocus), the client still sends RequestStreamAroundAsync as the first
	     push, and the picker shows "LOADING BASE..." until the target's parts are there
	     (Client/Attack/PickerView, rule in Shared/Attack/PickerStream). ]]
	--[[ Owner R118 "all of these clip": the picker's aim buttons (BIG MACHINE / WAREHOUSE / ...)
	     collapsed into one overlapping row — on phones the top block + bottom row left no band
	     between them, so every projected marker was clamped onto the same line. Now (pure layout:
	     Client/UI/Screens/AttackTarget/PickerLayout, tests/attack-view.luau):
	       * the top block and the bottom row scale down on short canvases (TopShare / BottomShare
	         of the canvas height, never below the MinTapPoints tap size), so a band always exists;
	       * chips are pinned near their area, de-collided cheapest-first (up / down by whole chip
	         rows, then sideways), with a leader line to a dot on the area when moved;
	       * if any chip cannot be pinned clear, ALL become one tidy row of chips just above the
	         action buttons (scrolls sideways when wider than the canvas), ordered left to right
	         like their areas, with leader lines while the row fits;
	       * chips are >= MinTapPoints tall on every device; the info / status / aim lines stack
	         on one backing plate (never overlapping, nothing shows through). ]]
	PickerLayout = table.freeze({
		TopShare = 0.26,
		BottomShare = 0.26,
		MinTapPoints = 44,
		Chip = Vector2.new(200, 60), -- design px (grows to the tap minimum, keeping its aspect)
		Gap = 12, -- px between chips
		Margin = 24, -- px kept from the canvas sides
		BandPad = 14, -- px kept from the top block / bottom row
		MaxShiftRows = 2, -- a pinned chip may move this many chip rows up / down ...
		MaxShiftX = 0.6, -- ... and this share of its width sideways
		LeaderMin = 18, -- px: a chip moved further than this from its spot gets a leader line
		MaxChipWidth = 420, -- px at the base chip height (long labels shrink their text past it)
	}),
	PickerStream = table.freeze({
		RequestTimeout = 6, -- seconds the client's RequestStreamAroundAsync may try
		SendGap = 0.15, -- client: min seconds between two focus intents (fast < > cycling coalesces)
		KeepAlive = 40, -- client: re-send the open picker's focus this often (< FocusExpire)
		FocusExpire = 120, -- server: a focus not refreshed for this long is dropped
		FocusLinger = 22, -- server: kept after the picker closes (the launch cinematic flies there)
		PollSeconds = 0.2, -- client: loading probe interval (only while loading)
		MinParts = 16, -- client: BaseParts in the target container that count as "there" ...
		StableTicks = 3, -- ... once the count stopped growing for this many polls
		ProbeMax = 600, -- client: the probe stops counting here (already plenty: loaded)
		LoadTimeout = 9, -- client: the shimmer never stays longer than this (seconds)
	}),
	-- Seconds the client waits between two launch intents (the server rate-limits anyway).
	LaunchDebounce = 0.4,
	-- Picker / HUD chip refresh (seconds) while visible.
	RefreshSeconds = 0.5,
	--[[ Bindings (ContextActionService, bound only while the owning UI is visible). They are chosen
	     around B16's platform action map (PlatformConfig.Actions): G / D-pad Down already opens the
	     picker ("Attack"), T / D-pad Up teleports, Q / E + LB / RB cycle targets through
	     GamepadNav.cycler while the picker is open, A activates the selected button (LAUNCH is the
	     default selection), D-pad / stick move the selection, B / keyboard X close. The picker adds
	     the arrow keys for targets and the buttons below; the HUD chips add keyboard shortcuts
	     (gamepad players reach them through the HUD Attack button → picker, which preselects the
	     newest Revenge target). ]]
	Keys = table.freeze({
		PrevTarget = table.freeze({
			keys = table.freeze({ Enum.KeyCode.Left }),
			pads = table.freeze({} :: { Enum.KeyCode }),
		}),
		NextTarget = table.freeze({
			keys = table.freeze({ Enum.KeyCode.Right }),
			pads = table.freeze({} :: { Enum.KeyCode }),
		}),
		-- Fallback when the platform layer (GamepadNav.cycler) is missing.
		CyclePrev = table.freeze({
			keys = table.freeze({ Enum.KeyCode.Q }),
			pads = table.freeze({ Enum.KeyCode.ButtonL1 }),
		}),
		CycleNext = table.freeze({
			keys = table.freeze({ Enum.KeyCode.E }),
			pads = table.freeze({ Enum.KeyCode.ButtonR1 }),
		}),
		Launch = table.freeze({
			keys = table.freeze({ Enum.KeyCode.Return, Enum.KeyCode.Space }),
			pads = table.freeze({} :: { Enum.KeyCode }),
		}),
		Barrage = table.freeze({
			keys = table.freeze({ Enum.KeyCode.B }),
			pads = table.freeze({ Enum.KeyCode.ButtonY }),
		}),
		Revenge = table.freeze({
			keys = table.freeze({ Enum.KeyCode.R }),
			pads = table.freeze({ Enum.KeyCode.ButtonX }),
		}),
		-- Owner R50 aim: previous / next built area (gamepad: RT cycles, or D-pad onto a marker + A;
		-- touch / mouse: tap a marker).
		AimPrev = table.freeze({
			keys = table.freeze({ Enum.KeyCode.Up }),
			pads = table.freeze({} :: { Enum.KeyCode }),
		}),
		AimNext = table.freeze({
			keys = table.freeze({ Enum.KeyCode.Down }),
			pads = table.freeze({ Enum.KeyCode.ButtonR2 }),
		}),
		Defense = table.freeze({
			keys = table.freeze({ Enum.KeyCode.V }),
			pads = table.freeze({ Enum.KeyCode.ButtonL2 }),
		}),
		-- HUD chips (no modal open): the newest Revenge and the free shield.
		HudRevenge = table.freeze({
			keys = table.freeze({ Enum.KeyCode.R }),
			pads = table.freeze({} :: { Enum.KeyCode }),
		}),
		HudShield = table.freeze({
			keys = table.freeze({ Enum.KeyCode.G }),
			pads = table.freeze({ Enum.KeyCode.DPadDown }),
		}),
		-- Owner R85: the GOLDEN REVENGE chip (paid revenge nuke) — keyboard J, gamepad R3 (right
		-- stick click: free on every pad layout; the D-pad left / right focus the HUD columns).
		HudGolden = table.freeze({
			keys = table.freeze({ Enum.KeyCode.J }),
			pads = table.freeze({ Enum.KeyCode.ButtonR3 }),
		}),
		-- Owner R85: launch a stored golden nuke from the picker (keyboard N, gamepad R3).
		Golden = table.freeze({
			keys = table.freeze({ Enum.KeyCode.N }),
			pads = table.freeze({ Enum.KeyCode.ButtonR3 }),
		}),
	}),
})

return table.freeze(AttackConfig)
