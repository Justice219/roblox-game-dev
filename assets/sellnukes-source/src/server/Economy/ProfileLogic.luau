--!strict
--[[
	ProfileLogic — the SellNukes player profile: schema v2, defaults, repair (reconcile),
	migrations, currency math (incl. per-world currencies), the receipt ledger, save serialization
	and the client snapshot.

	Purpose:
		Pure functions over plain tables (no services, no yields), so every rule that touches
		saved data lives in one tested place (tests/profile-logic.luau runs it under Lune):
			defaultProfile()          a fresh v2 profile (the build plan's schema, exactly)
			migrate(raw)              stored data → current schema ("new" | "current" | "migrated" | "newer")
			reconcile(raw)            repairs ANY stored table into a valid profile: wrong types →
			                          defaults, numbers finite + clamped, strings capped (UTF-8 safe),
			                          maps / lists bounded, dangling references dropped
			addCash / spendCash       cash math (grants also add to totalEarned), clamped to MaxCash
			addGems / spendGems       whole gems, clamped to MaxGems
			worldState / peekWorld    a non-main world's state (R57 World 2; created on demand /
			                          read-only lookup)
			addWorldCash / spendWorldCash, addWorldTokens / spendWorldTokens
			                          a world's currency (Bones) and rebirth tokens (Amber)
			hasReceipt / recordReceipt  idempotent developer-product receipts (newest 64 kept)
			applySetting              one settings toggle from the client (allowlisted keys, booleans)
			toSave(profile)           the DataStore payload (numeric sets → arrays, non-finite → 0)
			snapshot(profile, ctx, fields?)  the owner's ProfileUpdate payload (no private data)

	Schema v1 (build plan "Profile schema v1"; every field always present after reconcile):
		schemaVersion, cash, gems, totalEarned, rebirths, rebirthTokens, rebirthShop {[key]=level},
		tycoon { pads {[padId]=true}, producers {[producerId]=level}, area, standName, lastSaveAt,
		         tutorialStep },
		stats { playSeconds, clicks, padsBought, launches, hits, hatched },
		passes {[passKey]=true}            cache of confirmed pass ownership (truth: PassOwnership)
		receipts {[purchaseId]=os.time()}  newest 64 kept
		pets { owned {[uid]={id, locked?}}, equipped {uid}, nextUid,
		       eggs {[eggId]=held count}, pity {[eggId]=hatches}, index {[petId]=true},
		       indexClaimed {[milestoneId]=true} (R78 Pet Index rewards, PetIndexConfig) }   (B9)
		crates { held {[crateId]=count}, pity {[crateId]=opens}, opened }               (B9)
		trails { owned {[trailId]=true}, equipped = trailId | "" }                       (B9)
		boosts {[boostKey]=expiresAt}, daily { streak, lastDay }, timeRewards { day, seconds,
		claimed {[index]=true}, ladder (R89 PlaytimeConfig.LadderVersion) }, spin { free, lastFreeAt, paid, bonus }, codes {[code]=true},
		group { claimed }, notify { claimed, hour (R122 usual UTC start hour, -1 = unknown) },
		offline { lastSeenAt }, starter { bought },
		secretPack { bought }, attack { aa, launcher, shieldUntil, cooldownUntil, hitsTaken,
		barrage (stored Barrage nukes, B10), towers {level} (owner R80 defence tower slots: dense list,
		index = AttackConfig.Towers slot, 0 = not bought; older saves → {}), golden (owner R85 stored
		golden revenge nuke charges) },
		event { season, acorns, stickers {[index]=true}, redeemed,
		        decor {[decorKey]=true}, turkeys, lures,                                 (B11)
		        starterSeason (owner R97: season id whose 3 free starter stickers were granted,
		        "" = never; server-only, not in the snapshot) }
		settings { music, sfx, reducedMotion, hideOtherPets, haptics (B16, default true), showTitle (R73/R74),
		           fastHatch (owner R49 hatch cinematic: short version, default false),
		           autoClicker (owner R64: the AutoClicker pass clicks while ON; default true,
		           meaningless without the pass — TycoonRules.autoClickerOn) },
		analytics { first, last, payFirst, payLast, marks, robux, seenDay, seen, ftue, runAt, play,
		            carry, sessions, rbxDay, rbxSec (owner R122 capped playtime), staff,
		            payDays {["<block>"]=32-bit mask},
		            outbox {[purchaseId]=flat record} }
		            (semantics owned by B13 analytics / Shared/Config/AnalyticsMarks; reconcile only
		            keeps every value finite and bounded; never sent to the client)
		titles { [titleKey] = true }   owner-granted Player Titles (R74; Shared/Util/PlayerTitles
		        reconcileState: well-formed keys only, <= MaxGranted; private, never in the snapshot)
		notes { seen = newest WHAT'S NEW note id seen ("" = none), at = unix seconds }   (owner R58;
		        Shared/Config/ChangeNotesConfig.newState / reconcileState own the shape — the same
		        record as RoBeasts' profile.notes; snapshot field `notes = { seen }`)
		pass { season, xp, dayXp, day, claimedFree {[tier]=true}, claimedPremium {[tier]=true},
		       premium {[seasonId]=true}, overflow }   (R78 Nuke Pass; Shared/Config/PassConfig
		       newState / reconcileState / toSave own the shape; tier sets are saved + sent as
		       sorted arrays; snapshot field `pass` = PassConfig.toWire)
		rush { rookieLeft = Rookie Rush seconds left (counts down only while online),
		       comebackUntil = unix end of the Comeback Rush }                       (owner R78;
		       Shared/Config/SocialConfig newRush / reconcileRush; missing in pre-0.6.0 saves → 0,
		       so old profiles never get a Rookie Rush; snapshot field `rush`)
		referral { by = inviter UserId (0 = none), paid = inviter rewards received, seen = {
		           newcomer UserIds paid} }   (owner R78; SocialConfig newReferral /
		           reconcileReferral; snapshot field `referral = { paid, invited }`, ids private)
		quests { starter { step, base {[stat]=n}, claimed {bool x 12} }, daily { day, picks {
		         {stat, target, progress, claimed} }, chest, rerolled }, life {[stat]=n},
		         trophies {[trophyId]=tiers claimed} }   (owner R78 Quests; Shared/Config/
		         QuestConfig newState / reconcileState / snapshot own the shape; snapshot `quests`)

	Schema v2 (owner R57 World 2 "Dino Valley", spec §10 — ADDITIVE: every v1 field above is
	unchanged, so the main world ("Nuke Town") keeps living in the top-level fields):
		lastWorld  the world the last session ended in (WorldService writes it on travel and on
		           ProfileReleasing; rejoin chip). Any well-formed world key is kept (a newer
		           server's world too); anything else → "main".
		worlds {[worldId] = WorldState}   NON-main worlds only. Keys match ^[a-z][a-z0-9]{0,15}$,
		           never "main", at most MaxWorlds (8). Every KNOWN world (Shared/Config/Worlds/
		           WorldGeometry.Order) is always present after reconcile / in a default profile, so
		           services can index profile.worlds.dino directly. WorldState:
		             unlocked, unlockedAt          sticky unlock (server unix seconds)
		             cash, totalEarned             the world's currency (Bones), [0, MaxCash]
		             tycoon { pads, producers, area, standName, lastSaveAt, tutorialStep }
		                                           the main Tycoon shape; area clamped to the
		                                           world's area count (unknown world: MaxArea)
		             rebirths, rebirthTokens       the world's rebirth track + tokens (Amber)
		             rebirthShop {[key]=level}     the world's token shop
		             stats { playSeconds, runSeconds, visits, padsBought, clicks, lastVisitDay }
		             starter { bought }            the world's one-time WorldStarter pack (W2
		                                           decision: mirrors profile.starter.bought, so a
		                                           one-time pack is refused at the prompt)
		           Future-proofing: reconcile KEEPS unknown well-formed world keys (bounded, finite,
		           generic world reconciler), so an older server never destroys a newer world's
		           data; known worlds take the cap's slots first.
		Why a schema bump: a v1 server reconciles unknown fields away. With v2 stored, a v1
		server sees "newer" and opens the save read-only instead of saving over `worlds`.

	Additive v2 fields (no schema bump: missing → default, like the R78 blocks):
		plotName   owner R88: the owner-chosen plot name on every world's entrance sign ("" = the
		           default "<DisplayName>'s Nukes"); filtered before it was saved, capped at
		           MaxPlotNameChars; top-level so a Rebirth (which replaces `tycoon`) keeps it.
		           Snapshot field `plotName` (the owner's own copy, pre-fills the naming window).
		gifts      owner R89 gift ladder wave (Shared/Config/GiftsConfig owns newState /
		           reconcileState / toWire): { rocketDay (UTC day of the last Pocket Rocket, -1),
		           favorite (0 never shown / 1 shown / 2 answered), favoriteAsks }. Snapshot field
		           `gifts` = { rocketDay, favorite }.
		timeRewards.ladder  owner R89: the gift ladder the `claimed` indices refer to (missing = 1,
		           the old 7-gift ladder); reconcile maps old claims onto the current ladder with
		           PlaytimeConfig.migrateClaimed, so the 10-gift ladder never re-pays a gift.
		flavors    owner R89 Surprise Batches — the Flavour Book (Shared/Tycoon/FlavorLogic owns
		           newState / reconcileState / toWire): { found {["<world>:<flavor>"] = lifetime
		           batches}, claimed {["<world>:<flavor>"] = true} }. Missing in pre-R89 saves →
		           empty. Snapshot field `flavors` (same shape; Server/Tycoon/FlavorService pushes
		           it at once on a discovery / claim, else at most every FlavorConfig.PushSeconds).
		kinetic    owner R90 Mega Lever + Tip Jar (Shared/Tycoon/KineticLogic owns newState /
		           reconcileState): { worlds = { [worldId] = { readyAt (unix s the lever is ready
		           again, 0 = ready), jar (passive tip coins of that world's currency), tips (bonus
		           coins from TipJar.addCoins; no source since owner R128 removed the Order
		           Window, old values still pay out) } } }. Missing in pre-R90 saves → { worlds = {} }. NOT in the
		           snapshot (server bookkeeping; clients read the props' attributes). Top-level so a
		           Rebirth keeps the lever cooldown (Server/Kinetic empties that world's jar itself).
		(orders    RETIRED — owner R128 "bro honestly just remove the orders system entirely" removed
		           the R90 Order Window. Old saves' `orders` field is dropped by reconcile (it is
		           built from defaults: unknown top-level fields are never copied), nothing else is
		           touched; it is no snapshot field any more.)

	DataStore notes:
		- Sets keyed by NUMBERS (timeRewards.claimed, event.stickers) are sparse tables, which JSON
		  (DataStores) and remote events mangle. toSave() and snapshot() write them as sorted
		  arrays of numbers ({ 1, 3 }); reconcile() reads either form back into the set.
		- A non-finite number makes the DataStore write fail forever (JSON has no NaN / inf);
		  toSave() replaces any it finds with 0 and warns with the path, so one bug elsewhere can
		  never stop a profile from saving.

	Connects to: Server/Economy/ProfileStore (migrate / toSave on load / save),
	Server/Services/PlayerDataService (currency API, snapshot pushes), MonetizationService
	(receipts), Shared/Util/TextUtil (UTF-8 safe caps), Shared/Config/Worlds/WorldGeometry (the
	known world ids + area counts), tests/profile-logic.luau.

	Example:
		local profile = ProfileLogic.defaultProfile()
		ProfileLogic.addCash(profile, 250)                 --> 250 (also totalEarned = 250)
		print(ProfileLogic.spendCash(profile, 100), profile.cash) --> true 150
		ProfileLogic.recordReceipt(profile, "receipt-1", os.time()) --> true (false on a repeat)
		ProfileLogic.addWorldCash(profile, "dino", 40)     --> 40 (worlds.dino.cash + totalEarned)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TextUtil = require(ReplicatedStorage.Shared.Util.TextUtil)
-- WHAT'S NEW (owner R58): ChangeNotesConfig owns newState / reconcileState of profile.notes.
local ChangeNotesConfig = require(ReplicatedStorage.Shared.Config.ChangeNotesConfig)
-- Player Titles (owner R74): PlayerTitles owns newState / reconcileState of profile.titles.
local PlayerTitles = require(ReplicatedStorage.Shared.Util.PlayerTitles)
-- R78 Nuke Pass: PassConfig owns newState / reconcileState / toSave / toWire of profile.pass.
local PassConfig = require(ReplicatedStorage.Shared.Config.PassConfig)
-- R78 social (Rush + referrals): SocialConfig owns newRush / reconcileRush / newReferral /
-- reconcileReferral of profile.rush and profile.referral.
local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)
-- R78 Quests: QuestConfig owns newState / reconcileState / snapshot of profile.quests.
local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)
-- R57 worlds: the pure geometry registry (no requires) lists every known world + its area count.
local WorldGeometry = require(ReplicatedStorage.Shared.Config.Worlds.WorldGeometry)
-- Owner R88 plot names: the cap of profile.plotName (a frozen table, no requires).
local PlotNameConfig = require(ReplicatedStorage.Shared.Config.PlotNameConfig)
-- Owner R89 gift ladder: PlaytimeConfig maps saved claims onto the current ladder (migrateClaimed);
-- GiftsConfig owns newState / reconcileState / toWire of profile.gifts (Pocket Rocket + favorite).
local PlaytimeConfig = require(ReplicatedStorage.Shared.Config.PlaytimeConfig)
local GiftsConfig = require(ReplicatedStorage.Shared.Config.GiftsConfig)
-- Owner R89 Surprise Batches: FlavorLogic owns newState / reconcileState / toWire of
-- profile.flavors (pure; requires only FlavorConfig → UIStyleConfig + WorldGeometry).
local FlavorLogic = require(ReplicatedStorage.Shared.Tycoon.FlavorLogic)
-- Owner R90 Mega Lever + Tip Jar: KineticLogic owns newState / reconcileState of profile.kinetic
-- (pure; requires KineticConfig, FlavorConfig and WorldLayout → WorldGeometry only).
local KineticLogic = require(ReplicatedStorage.Shared.Tycoon.KineticLogic)

-- Types -----------------------------------------------------------------------------------------

export type Settings = {
	music: boolean,
	sfx: boolean,
	reducedMotion: boolean,
	hideOtherPets: boolean,
	haptics: boolean, -- B16 controller / phone vibration (2026-10-30 request)
	fastHatch: boolean, -- R49: the short egg hatch cinematic (UI/Screens/EggHatch/HatchRevealScreen)
	-- R64: the AutoClicker pass's "Toggle it any time" (server: TycoonService via SettingsService.Changed)
	autoClicker: boolean,
	-- R73 / R74: the player's own title tag ON / OFF (admin panel chip; only matters for players
	-- holding a title: PlayerTitleService mirrors it into the TitleHidden attribute). Default ON.
	showTitle: boolean,
}

export type SettingKey =
	"music"
	| "sfx"
	| "reducedMotion"
	| "hideOtherPets"
	| "haptics"
	| "fastHatch"
	| "autoClicker"
	| "showTitle"

export type Tycoon = {
	pads: { [string]: true }, -- bought pad ids
	producers: { [string]: number }, -- producerId -> level
	area: number, -- highest unlocked area (1-based)
	standName: string, -- stand sign text (already filtered when set)
	lastSaveAt: number, -- unix time of the last save (stamped by PlayerDataService)
	tutorialStep: number,
}

export type Stats = {
	playSeconds: number,
	clicks: number,
	padsBought: number,
	launches: number,
	hits: number,
	hatched: number,
}

export type PetEntry = { id: string, locked: boolean? }

export type Pets = {
	owned: { [string]: PetEntry }, -- uid -> pet
	equipped: { string }, -- uids
	nextUid: number,
	-- B9 pets (2026-10-30 request; semantics in Server/Pets/PetLogic + Shared/Config/EggConfig):
	eggs: { [string]: number }, -- eggId -> HELD eggs (hatch for free; zero counts are dropped)
	pity: { [string]: number }, -- eggId -> hatches in a row without the egg's pity-tier pet
	index: { [string]: true }, -- petId -> discovered (Pet Index)
	-- R78 Pet Index rewards (Shared/Config/PetIndexConfig ids "5" … "60" | "all"; Server/Pets/PetIndexLogic).
	indexClaimed: { [string]: true }, -- milestoneId -> claimed (gems paid + permanent Index Bonus)
}

-- B9 crates (Server/Pets/CrateLogic + Shared/Config/CrateConfig). Ids are save data.
export type Crates = {
	held: { [string]: number }, -- crateId -> HELD crates (Robux receipts, rewards; zero dropped)
	pity: { [string]: number }, -- crateId -> opens in a row without the crate's pity-rank reward
	opened: number, -- lifetime crates opened
}

-- B9 cosmetic trails (CrateConfig.Trails). `equipped` is "" (none) or an OWNED trail id.
export type Trails = {
	owned: { [string]: true },
	equipped: string,
}

--[[
	Analytics bookkeeping (B13 owns the meaning: Server/Analytics + Shared/Config/AnalyticsMarks).
	ProfileLogic only guarantees the shape: every number finite, ≥ 0 and bounded (whole numbers
	except `play`), `staff` boolean, `outbox` bounded. Clamps are deliberately semantics-neutral
	(a day number and a unix time both survive) so analytics-owned values are never altered.
]]
export type Analytics = {
	first: number, -- first session marker
	last: number, -- last active marker (UTC day)
	payFirst: number, -- first Robux purchase marker (0 = never)
	payLast: number, -- latest Robux purchase marker
	marks: number, -- bit flags of one-time analytics marks
	robux: number, -- lifetime Robux spent
	seenDay: number, -- UTC day of the last "seen" mark
	seen: number, -- seen counter / flags
	ftue: number, -- first-time-user-experience funnel flags
	runAt: number, -- run / rebirth timing marker
	play: number, -- lifetime play seconds as analytics counts them (fractions kept)
	carry: number, -- UTC-day carry marker
	sessions: number, -- lifetime sessions
	rbxDay: number, -- owner R122: UTC day of rbxSec (Roblox-aligned capped playtime)
	rbxSec: number, -- owner R122: seconds credited to core "rbx:playSec" on rbxDay (≤ 3,600)
	staff: boolean, -- staff / admin account (excluded from player metrics)
	-- Sparse payer-day bitmap (B13 ReceiptAccounting): "<utcDay // 32>" ("0".."1562") → a 32-bit
	-- mask whose bit (day % 32) is set when the player paid Robux that day. ≤ 1563 entries.
	payDays: { [string]: number },
	outbox: { [string]: { [string]: string | number | boolean } }, -- pending receipt accounting
}

-- R57 (schema v2): per-world counters. `runSeconds` = seconds in the current rebirth run.
export type WorldStats = {
	playSeconds: number,
	runSeconds: number,
	visits: number,
	padsBought: number,
	clicks: number,
	lastVisitDay: number, -- UTC day of the last visit (-1 = never)
}

-- R57 (schema v2): one non-main world's state (profile.worlds[worldId]; see the header).
export type WorldState = {
	unlocked: boolean, -- sticky: once true it never goes back (WorldService.unlock)
	unlockedAt: number, -- server unix seconds (0 = locked)
	cash: number, -- the world's currency (Dino Valley: Bones)
	totalEarned: number, -- lifetime currency earned in this world
	tycoon: Tycoon, -- the world's run (same shape as the main tycoon)
	rebirths: number, -- the world's own rebirth count
	rebirthTokens: number, -- the world's tokens (Dino Valley: Amber)
	rebirthShop: { [string]: number }, -- the world's token shop levels
	stats: WorldStats,
	starter: { bought: boolean }, -- the world's one-time WorldStarter pack was bought
}

export type Profile = {
	schemaVersion: number,
	cash: number,
	gems: number,
	totalEarned: number,
	rebirths: number,
	rebirthTokens: number,
	rebirthShop: { [string]: number },
	tycoon: Tycoon,
	stats: Stats,
	passes: { [string]: true },
	receipts: { [string]: number },
	pets: Pets,
	crates: Crates,
	trails: Trails,
	boosts: { [string]: number },
	daily: { streak: number, lastDay: number },
	-- ladder: owner R89, the gift ladder version `claimed` refers to (PlaytimeConfig.LadderVersion)
	timeRewards: { day: number, seconds: number, claimed: { [number]: true }, ladder: number },
	-- Lucky Wheel spins (B7 + paid-random compliance 2026-10-30, Server/Retention/WheelLogic):
	-- free = timer spins (0..MaxFree), bonus = spins from FREE rewards (daily / codes / notify /
	-- admin; never paid random), paid = ROBUX-sourced spins (Spins products, packs; spending one
	-- re-checks PolicyService). Saves from before `bonus` existed keep every paid spin as paid.
	spin: { free: number, lastFreeAt: number, paid: number, bonus: number },
	codes: { [string]: true },
	group: { claimed: boolean },
	-- hour (owner R122): the player's usual UTC start hour 0..23 (-1 = unknown), blended at each
	-- leave by Retention/ReturnNotifyService; times the "streak" return notification.
	notify: { claimed: boolean, hour: number },
	offline: { lastSeenAt: number },
	starter: { bought: boolean },
	secretPack: { bought: boolean },
	-- barrage: stored Barrage nukes (B10: +product.nukes per receipt, -1 per barrage launch)
	attack: {
		aa: number,
		launcher: number,
		shieldUntil: number,
		cooldownUntil: number,
		hitsTaken: number,
		barrage: number,
		-- Owner R80: stored level per defence tower slot (dense; index = slot; 0 = not bought).
		towers: { number },
		-- Owner R85: stored golden revenge nuke charges (31 R$ "RevengeNuke"; never clamped by a receipt).
		golden: number,
	},
	event: {
		season: string,
		acorns: number,
		stickers: { [number]: true },
		redeemed: boolean,
		-- B11 Harvest Feast (2026-10-30 request; EventLogic.ensureSeason resets acorns / stickers /
		-- redeemed / turkeys each season, KEEPS decor + lures):
		decor: { [string]: true }, -- owned plot decorations (EventConfig.Decor keys)
		turkeys: number, -- Golden Turkeys caught this season
		lures: number, -- Turkey Lures bought and not yet caught
		-- Owner R97: the season id whose free starter stickers were granted ("" = never). Compared
		-- with the current season (EventLogic.grantStarters), so a rollover needs no reset.
		starterSeason: string,
	},
	settings: Settings,
	analytics: Analytics,
	-- WHAT'S NEW (owner R58): the newest change note this player has seen (ChangeNotesConfig.State).
	notes: ChangeNotesConfig.State,
	-- Player Titles (owner R73 / R74): titles the owner GRANTED this player (catalogue keys; the
	-- permanent UserId titles are config, never saved). Shared/Util/PlayerTitles owns the shape.
	titles: PlayerTitles.State,
	-- R78 Nuke Pass: this season's XP / claims + premium seasons (Shared/Config/PassConfig.State).
	pass: PassConfig.State,
	-- R78 Rush boosts: Rookie Rush seconds left (online time only) + Comeback Rush end (unix).
	rush: SocialConfig.RushState,
	-- R78 referrals: inviter UserId (0 = none), inviter rewards received, newcomer ids paid.
	referral: SocialConfig.ReferralState,
	-- R78 Quests: starter chain, today's missions, lifetime counters, trophy tiers (QuestConfig.State).
	quests: QuestConfig.State,
	-- R57 schema v2: non-main worlds (keys ^[a-z][a-z0-9]{0,15}$, never "main", ≤ MaxWorlds).
	worlds: { [string]: WorldState },
	lastWorld: string, -- world id the last session ended in ("main" by default)
	-- Owner R88: the owner-chosen plot name on the entrance sign of EVERY world's plot ("" = the
	-- default "<DisplayName>'s Nukes"). Already TextService-filtered when saved; re-filtered once
	-- per session before it is shown again (Server/Tycoon/PlotNames). Top-level on purpose: Rebirth
	-- replaces profile.tycoon, the plot name survives it.
	plotName: string,
	-- Owner R89: Pocket Rocket day + the one-time favorite prompt record (GiftsConfig.State).
	gifts: GiftsConfig.State,
	-- Owner R89 Surprise Batches: the Flavour Book (found counts + claimed discovery rewards).
	flavors: FlavorLogic.State,
	-- Owner R90: per-world Mega Lever cooldown + Tip Jar coins (KineticLogic.State; server-only).
	kinetic: KineticLogic.State,
}

export type MigrationStatus = "new" | "current" | "migrated" | "newer"

-- What the snapshot needs beyond the profile (all decided by the server).
export type SnapshotContext = {
	saveStatus: string, -- ProfileStore.SaveStatus ("ok" | "disabled" | "readOnly" | "lost")
	paidRandomRestricted: boolean, -- PolicyService paid-random verdict (true while unknown: fail closed)
	policyKnown: boolean, -- PolicyService answered for this player
}

local ProfileLogic = {}

-- v2 (owner R57 World 2): + worlds, lastWorld (additive; see the header).
ProfileLogic.SCHEMA_VERSION = 2

-- Hard bounds for stored data (reconcile clamps to them; mutations respect them).
local LIMITS = table.freeze({
	MaxCash = 1e300, -- keeps cash finite through any multiplier chain
	MaxGems = 1e12,
	MaxCounter = 1e15, -- stats, tokens, acorns, robux
	MaxTimestamp = 4_102_444_800, -- 2100-01-01T00:00:00Z
	MaxDay = 50_000, -- UTC day numbers (2106)
	MaxKeyLength = 64, -- every stored map key / id string
	MaxReceipts = 64,
	MaxPads = 1_024,
	MaxProducers = 64,
	MaxLevel = 1e6, -- producer / rebirth shop / defense levels
	MaxTowerSlots = 16, -- attack.towers entries (owner R80; AttackConfig.Towers has 4 slots)
	MaxArea = 64,
	MaxTutorialStep = 1_000,
	MaxStandNameChars = 24,
	MaxPlotNameChars = PlotNameConfig.MaxChars, -- owner R88 profile.plotName (24)
	MaxPets = 1_000,
	MaxEquipped = 16,
	MaxBoosts = 64,
	MaxRebirthShop = 64,
	MaxCodes = 512,
	MaxTimeRewardIndex = 32,
	MaxStickers = 64,
	MaxSeasonChars = 32,
	MaxDecor = 32, -- event.decor keys
	MaxDecorKeyLength = 24, -- an event.decor key: [%w_-], 1..24 bytes (EventConfig.Decor keys)
	MaxStreak = 10_000,
	MaxSpins = 1_000_000,
	MaxOutbox = 32,
	MaxOutboxFields = 32,
	MaxOutboxString = 128,
	MaxAnalyticsNumber = 2 ^ 53, -- largest exact whole double: holds day numbers, unix times, bit flags
	MaxItemCount = 1e6, -- held eggs / crates, stored barrage nukes, pity counters (storage bound)
	MaxEggKinds = 64, -- pets.eggs / pets.pity keys
	MaxPetIndex = 1_000, -- pets.index keys (every pet id ever discovered)
	MaxIndexMilestones = 32, -- pets.indexClaimed keys (R78; PetIndexConfig has 7)
	MaxCrateKinds = 32, -- crates.held / crates.pity keys
	MaxTrails = 256, -- trails.owned keys
	MaxPayDayBlock = 1_562, -- analytics.payDays block keys "0".."1562" (MaxDay 50,000 // 32)
	MaxPayDayMask = 0xFFFFFFFF, -- a payDays block is one unsigned 32-bit mask
	MaxWorlds = 8, -- profile.worlds entries (non-main worlds; known worlds take slots first)
	MaxWorldKeyLength = 16, -- a world id: ^[a-z][a-z0-9]{0,15}$
	MaxWorldCandidates = 64, -- unknown world keys examined by reconcile (bounds its sort)
})
ProfileLogic.Limits = LIMITS

-- The client-settable settings (applySetting allowlist) and their defaults.
local SETTING_DEFAULTS: Settings = table.freeze({
	music = true,
	sfx = true,
	reducedMotion = false,
	hideOtherPets = false,
	haptics = true,
	fastHatch = false,
	-- R64: ON so a fresh AutoClicker purchase works at once; only pass owners see the toggle.
	autoClicker = true,
	-- R73 / R74: a title tag shows until its holder turns it off (title holders only).
	showTitle = true,
}) :: any
ProfileLogic.SettingKeys = table.freeze({
	"music",
	"sfx",
	"reducedMotion",
	"hideOtherPets",
	"haptics",
	"fastHatch",
	"autoClicker",
	"showTitle",
})
-- O(1) allowlist of setting keys (applySetting).
local SETTING_KEY_SET: { [string]: boolean } = {}
for _, key in ProfileLogic.SettingKeys do
	SETTING_KEY_SET[key] = true
end

-- Whole-number analytics fields (reconcile walks this list; `play` keeps fractions).
local ANALYTICS_WHOLE_KEYS = table.freeze({
	"first",
	"last",
	"payFirst",
	"payLast",
	"marks",
	"robux",
	"seenDay",
	"seen",
	"ftue",
	"runAt",
	"carry",
	"sessions",
	"rbxDay", -- owner R122 (AnalyticsMarks clamps rbxSec to the daily cap on its own reconcile)
	"rbxSec",
})

-- Every stats counter (reconcile walks this list; the Stats type has no indexer).
local STAT_KEYS = table.freeze({ "playSeconds", "clicks", "padsBought", "launches", "hits", "hatched" })

-- Every whole WorldStats counter (reconcile walks this list; lastVisitDay is a day, handled apart).
local WORLD_STAT_KEYS = table.freeze({ "playSeconds", "runSeconds", "visits", "padsBought", "clicks" })

-- The main world's id. Its data is the top-level v1 fields; it never appears in profile.worlds.
local MAIN_WORLD = "main"

-- Helpers ---------------------------------------------------------------------------------------

-- True for a finite number (rejects non-numbers, NaN and ±inf).
local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
ProfileLogic.isFinite = isFinite

-- A finite number clamped into [0, max], or `fallback` for anything else (fractions kept).
local function amount(value: unknown, max: number, fallback: number): number
	if not isFinite(value) then
		return fallback
	end
	return math.clamp(value :: number, 0, max)
end

-- A finite whole number clamped into [min, max], or `fallback` for anything else.
local function whole(value: unknown, min: number, max: number, fallback: number): number
	if not isFinite(value) then
		return fallback
	end
	return math.clamp(math.floor(value :: number), min, max)
end

-- A boolean, or `fallback`.
local function bool(value: unknown, fallback: boolean): boolean
	if type(value) == "boolean" then
		return value
	end
	return fallback
end

-- A stored key / id: a non-empty string of at most MaxKeyLength bytes that is valid UTF-8.
local function validKey(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= LIMITS.MaxKeyLength and utf8.len(value) ~= nil
end

-- A table (not a metatable'd object), else nil.
local function plainTable(value: unknown): { [any]: any }?
	if type(value) == "table" and getmetatable(value :: any) == nil then
		return value :: any
	end
	return nil
end

-- Shared read-only empty map for missing sub-tables (reconcile only READS from it).
local EMPTY: { [any]: any } = table.freeze({}) :: any

-- The fields of a stored sub-table, or EMPTY when it is missing / not a plain table.
local function fieldsOf(value: unknown): { [any]: any }
	return plainTable(value) or EMPTY
end

--[[
	True for a well-formed world id: 1..MaxWorldKeyLength bytes matching ^[a-z][a-z0-9]*$ (the key
	format of profile.worlds and of lastWorld; the same rule as WorldsConfig.IdPattern /
	MaxIdLength — inlined so profiles never load the economy, tests/validate.luau checks they
	agree). "main" is well-formed (lastWorld uses it); callers that need a NON-main world also
	compare against "main".
	Example: ProfileLogic.isWorldKey("dino") --> true ; ProfileLogic.isWorldKey("Dino") --> false
]]
local function isWorldKey(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= LIMITS.MaxWorldKeyLength
		and string.find(value, "^[a-z][a-z0-9]*$") ~= nil
end
ProfileLogic.isWorldKey = isWorldKey

-- The known non-main worlds (WorldGeometry.Order without "main", in order) and their area counts,
-- checked once at load: a malformed registry fails loudly at boot, never inside a save.
local KNOWN_WORLDS: { string } = {}
local KNOWN_AREA_COUNT: { [string]: number } = {}
for _, worldId in WorldGeometry.Order do
	if worldId ~= MAIN_WORLD then
		local geometry = WorldGeometry.get(worldId)
		if not isWorldKey(worldId) or geometry == nil or KNOWN_AREA_COUNT[worldId] ~= nil then
			error(`[ProfileLogic] WorldGeometry world {tostring(worldId)} is malformed, unknown or repeated`)
		end
		local areaCount = geometry.areaCount
		if not isFinite(areaCount) or areaCount < 1 or areaCount % 1 ~= 0 or areaCount > LIMITS.MaxArea then
			error(`[ProfileLogic] WorldGeometry world {worldId} has a bad areaCount {tostring(areaCount)}`)
		end
		table.insert(KNOWN_WORLDS, worldId)
		KNOWN_AREA_COUNT[worldId] = areaCount
	end
end
if #KNOWN_WORLDS > LIMITS.MaxWorlds then
	error(`[ProfileLogic] {#KNOWN_WORLDS} known worlds exceed MaxWorlds ({LIMITS.MaxWorlds})`)
end
-- Every known non-main world id, in WorldGeometry order (tests / docs / snapshot builders).
ProfileLogic.KnownWorlds = table.freeze(KNOWN_WORLDS)

--[[
	Deep-copies plain data (tables, strings, numbers, booleans). Cycles are not supported
	(profiles never contain any).
]]
function ProfileLogic.deepCopy<T>(value: T): T
	local source: any = value
	if type(source) ~= "table" then
		return source
	end
	local copy = {}
	for key, item in source do
		copy[key] = ProfileLogic.deepCopy(item)
	end
	return copy :: any
end

export type Snapshot = {
	copy: { [any]: any }, -- deep copy of the value at snapshot time
	refs: { [any]: { [any]: any } }, -- copy table → the ORIGINAL table it was copied from
}

--[[
	Takes a rollback snapshot of a profile (or any plain tree of tables): a deep copy plus, for
	every copied table, the original table it came from. restoreSnapshot puts the profile back
	EXACTLY — values, removed / added keys, array lengths — and every table back to its ORIGINAL
	identity, even one a failed step replaced (services hold references to profile.tycoon /
	profile.pets / ...). Metatables are ignored (profiles are plain data).
	Why: MonetizationService snapshots before a product handler and restores when the handler
	errors, yields or refuses, so a half-applied grant never stays in memory (it would be
	autosaved and then granted AGAIN when Roblox re-delivers the receipt).
	Example:
		local before = ProfileLogic.takeSnapshot(profile)
		if not grant(profile) then ProfileLogic.restoreSnapshot(before) end
]]
function ProfileLogic.takeSnapshot(value: { [any]: any }): Snapshot
	local refs: { [any]: { [any]: any } } = {}
	local function copyOf(original: { [any]: any }): { [any]: any }
		local copy = {}
		refs[copy] = original
		for key, item in original do
			copy[key] = if type(item) == "table" then copyOf(item) else item
		end
		return copy
	end
	return { copy = copyOf(value), refs = refs }
end

--[[
	Restores a snapshot from takeSnapshot in place (see there). Reusable: restoring the same
	snapshot again gives the same result (the copy is never aliased into the live tables).
]]
function ProfileLogic.restoreSnapshot(snapshot: Snapshot)
	local function restore(copy: { [any]: any }): { [any]: any }
		local original = snapshot.refs[copy]
		for key in original do
			if copy[key] == nil then
				original[key] = nil
			end
		end
		for key, item in copy do
			original[key] = if type(item) == "table" then restore(item) else item
		end
		return original
	end
	restore(snapshot.copy)
end

--[[ The UTC day number of a unix time (days since 1970-01-01). Daily rewards / analytics. ]]
function ProfileLogic.dayNumber(unixTime: number): number
	return unixTime // 86400
end

-- Defaults --------------------------------------------------------------------------------------

--[[
	A fresh default world state (spec §10: locked, empty run, no rebirths). Every call returns
	brand-new tables.
	Example: ProfileLogic.newWorldState().tycoon.area --> 1
]]
function ProfileLogic.newWorldState(): WorldState
	return {
		unlocked = false,
		unlockedAt = 0,
		cash = 0,
		totalEarned = 0,
		tycoon = { pads = {}, producers = {}, area = 1, standName = "", lastSaveAt = 0, tutorialStep = 0 },
		rebirths = 0,
		rebirthTokens = 0,
		rebirthShop = {},
		stats = { playSeconds = 0, runSeconds = 0, visits = 0, padsBought = 0, clicks = 0, lastVisitDay = -1 },
		starter = { bought = false },
	}
end

-- A default entry for every known non-main world (a fresh profile / the reconcile baseline).
local function defaultWorlds(): { [string]: WorldState }
	local worlds: { [string]: WorldState } = {}
	for _, worldId in KNOWN_WORLDS do
		worlds[worldId] = ProfileLogic.newWorldState()
	end
	return worlds
end

--[[
	A fresh default profile at the current schema version (the build plan's schema, exactly).
	Every call returns brand-new tables.
]]
function ProfileLogic.defaultProfile(): Profile
	return {
		schemaVersion = ProfileLogic.SCHEMA_VERSION,
		cash = 0,
		gems = 0,
		totalEarned = 0,
		rebirths = 0,
		rebirthTokens = 0,
		rebirthShop = {},
		tycoon = { pads = {}, producers = {}, area = 1, standName = "", lastSaveAt = 0, tutorialStep = 0 },
		stats = { playSeconds = 0, clicks = 0, padsBought = 0, launches = 0, hits = 0, hatched = 0 },
		passes = {},
		receipts = {},
		pets = { owned = {}, equipped = {}, nextUid = 1, eggs = {}, pity = {}, index = {}, indexClaimed = {} },
		crates = { held = {}, pity = {}, opened = 0 },
		trails = { owned = {}, equipped = "" },
		boosts = {},
		daily = { streak = 0, lastDay = -1 },
		timeRewards = { day = -1, seconds = 0, claimed = {}, ladder = PlaytimeConfig.LadderVersion },
		spin = { free = 1, lastFreeAt = 0, paid = 0, bonus = 0 },
		codes = {},
		group = { claimed = false },
		notify = { claimed = false, hour = -1 },
		offline = { lastSeenAt = 0 },
		starter = { bought = false },
		secretPack = { bought = false },
		attack = {
			aa = 0,
			launcher = 0,
			shieldUntil = 0,
			cooldownUntil = 0,
			hitsTaken = 0,
			barrage = 0,
			towers = {}, -- owner R80 defence tower slot levels (dense list, see the schema)
			golden = 0, -- owner R85 stored golden revenge nuke charges
		},
		event = {
			season = "",
			acorns = 0,
			stickers = {},
			redeemed = false,
			decor = {},
			turkeys = 0,
			lures = 0,
			starterSeason = "", -- owner R97 free starter stickers: never granted
		},
		settings = table.clone(SETTING_DEFAULTS) :: any,
		analytics = {
			first = 0,
			last = 0,
			payFirst = 0,
			payLast = 0,
			marks = 0,
			robux = 0,
			seenDay = 0,
			seen = 0,
			ftue = 0,
			runAt = 0,
			play = 0,
			carry = 0,
			sessions = 0,
			rbxDay = 0, -- owner R122: no capped playtime credited yet
			rbxSec = 0,
			staff = false,
			payDays = {},
			outbox = {},
		},
		notes = ChangeNotesConfig.newState(), -- WHAT'S NEW (R58): no change note seen yet
		titles = PlayerTitles.newState(), -- Player Titles (R74): nothing granted
		pass = PassConfig.newState(), -- R78 Nuke Pass: no season played yet
		-- R78: no rush (RushService grants the Rookie Rush on the FIRST load of a new profile).
		rush = SocialConfig.newRush(),
		referral = SocialConfig.newReferral(), -- R78: not referred, nothing paid
		quests = QuestConfig.newState(), -- R78 Quests: chain at goal 1, no missions seeded yet
		worlds = defaultWorlds(), -- R57 v2: every known non-main world, locked
		lastWorld = MAIN_WORLD,
		plotName = "", -- owner R88: no custom plot name → "<DisplayName>'s Nukes"
		gifts = GiftsConfig.newState(), -- owner R89: no Pocket Rocket yet, favorite never prompted
		flavors = FlavorLogic.newState(), -- owner R89: empty Flavour Book
		kinetic = KineticLogic.newState(), -- owner R90: no lever pulled, no jar filled yet
	}
end

-- Reconcile -------------------------------------------------------------------------------------

-- Copies a stored string set, keeping valid keys mapped to `true` (at most maxEntries).
local function reconcileStringSet(raw: unknown, maxEntries: number): { [string]: true }
	local out: { [string]: true } = {}
	local source = plainTable(raw)
	if source == nil then
		return out
	end
	local count = 0
	for key, value in source do
		if value == true and validKey(key) then
			count += 1
			if count > maxEntries then
				break
			end
			out[key :: string] = true
		end
	end
	return out
end

--[[
	Copies a stored number set {[n] = true} — or its saved array form { n1, n2 } — keeping whole
	numbers in [1, maxIndex].
]]
local function reconcileNumberSet(raw: unknown, maxIndex: number): { [number]: true }
	local out: { [number]: true } = {}
	local source = plainTable(raw)
	if source == nil then
		return out
	end
	for key, value in source do
		-- Map form: index → true. Array form (toSave / snapshot): position → index.
		local index = if value == true then key elseif type(key) == "number" then value else nil
		if
			isFinite(index)
			and (index :: number) % 1 == 0
			and (index :: number) >= 1
			and (index :: number) <= maxIndex
		then
			out[index :: number] = true
		end
	end
	return out
end

--[[
	Copies a stored {[key] = number} map: valid keys, finite values clamped into [0, max] (floored
	with `wholeValues`). With `dropZero`, entries whose kept value is 0 are left out (count maps
	where "absent" means none, e.g. held eggs) and do not use up the entry budget.
]]
local function reconcileNumberMap(
	raw: unknown,
	maxEntries: number,
	max: number,
	wholeValues: boolean,
	dropZero: boolean?
): { [string]: number }
	local out: { [string]: number } = {}
	local source = plainTable(raw)
	if source == nil then
		return out
	end
	local count = 0
	for key, value in source do
		if validKey(key) and isFinite(value) then
			local clamped = math.clamp(value :: number, 0, max)
			local kept = if wholeValues then math.floor(clamped) else clamped
			if not (dropZero and kept == 0) then
				count += 1
				if count > maxEntries then
					break
				end
				out[key :: string] = kept
			end
		end
	end
	return out
end

-- Keeps the newest `limit` receipts (oldest evicted; ties broken by id for determinism).
local function trimReceipts(receipts: { [string]: number }, limit: number)
	local count = 0
	for _ in receipts do
		count += 1
	end
	while count > limit do
		local oldestId: string? = nil
		local oldestTime = math.huge
		for id, time in receipts do
			if time < oldestTime or (time == oldestTime and oldestId ~= nil and id < oldestId) then
				oldestId, oldestTime = id, time
			end
		end
		if oldestId == nil then
			break
		end
		receipts[oldestId] = nil
		count -= 1
	end
end

-- Repairs the pets block: valid uids / pet ids, equipped ⊆ owned (deduped, capped), nextUid sane.
local function reconcilePets(raw: unknown): Pets
	local source = fieldsOf(raw)
	local owned: { [string]: PetEntry } = {}
	local count = 0
	local highestNumericUid = 0
	local ownedSource = plainTable(source.owned)
	if ownedSource ~= nil then
		for uid, entry in ownedSource do
			local pet = plainTable(entry)
			if validKey(uid) and pet ~= nil and validKey(pet.id) then
				count += 1
				if count > LIMITS.MaxPets then
					break
				end
				local copy: PetEntry = { id = pet.id :: string }
				if pet.locked == true then
					copy.locked = true
				end
				owned[uid :: string] = copy
				local numeric = tonumber(uid)
				if numeric ~= nil and numeric == numeric and numeric > highestNumericUid then
					highestNumericUid = math.floor(numeric)
				end
			end
		end
	end
	local equipped: { string } = {}
	local seen: { [string]: boolean } = {}
	local equippedSource = plainTable(source.equipped)
	if equippedSource ~= nil then
		for _, uid in ipairs(equippedSource) do
			if #equipped >= LIMITS.MaxEquipped then
				break
			end
			if type(uid) == "string" and owned[uid] ~= nil and not seen[uid] then
				seen[uid] = true
				table.insert(equipped, uid)
			end
		end
	end
	-- nextUid must never hand out a uid that is already owned.
	local nextUid = whole(source.nextUid, 1, LIMITS.MaxCounter, 1)
	nextUid = math.max(nextUid, highestNumericUid + 1)
	return {
		owned = owned,
		equipped = equipped,
		nextUid = nextUid,
		eggs = reconcileNumberMap(source.eggs, LIMITS.MaxEggKinds, LIMITS.MaxItemCount, true, true),
		pity = reconcileNumberMap(source.pity, LIMITS.MaxEggKinds, LIMITS.MaxItemCount, true, true),
		index = reconcileStringSet(source.index, LIMITS.MaxPetIndex),
		indexClaimed = reconcileStringSet(source.indexClaimed, LIMITS.MaxIndexMilestones),
	}
end

-- Repairs the crates block (B9): bounded count maps (zero dropped), whole lifetime counter.
local function reconcileCrates(raw: unknown): Crates
	local source = fieldsOf(raw)
	return {
		held = reconcileNumberMap(source.held, LIMITS.MaxCrateKinds, LIMITS.MaxItemCount, true, true),
		pity = reconcileNumberMap(source.pity, LIMITS.MaxCrateKinds, LIMITS.MaxItemCount, true, true),
		opened = whole(source.opened, 0, LIMITS.MaxCounter, 0),
	}
end

-- Repairs the trails block (B9): bounded owned set; equipped is "" or an owned trail id.
local function reconcileTrails(raw: unknown): Trails
	local source = fieldsOf(raw)
	local owned = reconcileStringSet(source.owned, LIMITS.MaxTrails)
	local equipped = source.equipped
	return {
		owned = owned,
		equipped = if type(equipped) == "string" and owned[equipped] == true then equipped else "",
	}
end

-- Repairs the analytics outbox: bounded, flat records of primitives keyed by purchase id.
local function reconcileOutbox(raw: unknown): { [string]: { [string]: string | number | boolean } }
	local out: { [string]: { [string]: string | number | boolean } } = {}
	local source = plainTable(raw)
	if source == nil then
		return out
	end
	local count = 0
	for id, record in source do
		local fields = plainTable(record)
		if validKey(id) and fields ~= nil then
			count += 1
			if count > LIMITS.MaxOutbox then
				break
			end
			local copy: { [string]: string | number | boolean } = {}
			local fieldCount = 0
			for name, value in fields do
				if validKey(name) and fieldCount < LIMITS.MaxOutboxFields then
					if type(value) == "boolean" or isFinite(value) then
						fieldCount += 1
						copy[name :: string] = value :: any
					elseif type(value) == "string" and #value <= LIMITS.MaxOutboxString and utf8.len(value) ~= nil then
						fieldCount += 1
						copy[name :: string] = value
					end
				end
			end
			out[id :: string] = copy
		end
	end
	return out
end

--[[
	Repairs analytics.payDays, the sparse payer-day bitmap (B13 Server/Analytics/ReceiptAccounting
	writes it; mirrors Shared/Config/AnalyticsMarks.reconcileAnalytics, inlined so profile loading
	never depends on analytics code). Kept: canonical decimal block keys "0".."1562" (no "01",
	"1.0", "-0", " 1" — digits only and `tostring(n) == key`, so two keys can never name one
	block) mapped to whole masks in [0, 2^32 - 1]. At most MaxPayDayBlock + 1 entries
	by construction (one per block).
	Example: reconcilePayDays({ ["0"] = 5, ["01"] = 1, ["9999"] = 1, ["3"] = -1 }) --> { ["0"] = 5 }
]]
local function reconcilePayDays(raw: unknown): { [string]: number }
	local out: { [string]: number } = {}
	local source = plainTable(raw)
	if source == nil then
		return out
	end
	for block, mask in source do
		-- 1–4 ASCII digits only (no sign: "-0" would otherwise alias block 0); the tostring check
		-- below then rejects leading zeros ("01").
		local index = if type(block) == "string" and string.find(block, "^%d%d?%d?%d?$") ~= nil
			then tonumber(block)
			else nil
		if
			index ~= nil
			and index % 1 == 0
			and index >= 0
			and index <= LIMITS.MaxPayDayBlock
			and tostring(index) == block
			and isFinite(mask)
			and (mask :: number) % 1 == 0
			and (mask :: number) >= 0
			and (mask :: number) <= LIMITS.MaxPayDayMask
		then
			out[block :: string] = mask :: number
		end
	end
	return out
end
ProfileLogic.reconcilePayDays = reconcilePayDays

--[[
	Repairs event.decor (B11): a set of owned decoration keys, each [%w_-] and 1..MaxDecorKeyLength
	bytes (the EventConfig.Decor key format), at most MaxDecor entries. Unknown-but-well-formed keys
	are kept (a decoration removed from the config must not silently vanish from saves).
	Example: reconcileDecor({ scarecrow = true, ["bad key"] = true }) --> { scarecrow = true }
]]
local function reconcileDecor(raw: unknown): { [string]: true }
	local out: { [string]: true } = {}
	local source = plainTable(raw)
	if source == nil then
		return out
	end
	local count = 0
	for key, value in source do
		if
			value == true
			and type(key) == "string"
			and #key >= 1
			and #key <= LIMITS.MaxDecorKeyLength
			and string.find(key, "^[%w_%-]+$") ~= nil
		then
			count += 1
			if count > LIMITS.MaxDecor then
				break
			end
			out[key] = true
		end
	end
	return out
end

-- A unix timestamp in [0, MaxTimestamp].
local function timestamp(value: unknown): number
	return whole(value, 0, LIMITS.MaxTimestamp, 0)
end

--[[
	Repairs a tycoon block (the main run and every world's run share this shape): bounded pad set,
	bounded whole producer levels, area clamped to [1, maxArea], capped stand name, timestamps.
	@param maxArea the world's area count (main and unknown worlds: LIMITS.MaxArea)
]]
local function reconcileTycoon(raw: unknown, maxArea: number): Tycoon
	local tycoon = fieldsOf(raw)
	return {
		pads = reconcileStringSet(tycoon.pads, LIMITS.MaxPads),
		producers = reconcileNumberMap(tycoon.producers, LIMITS.MaxProducers, LIMITS.MaxLevel, true),
		area = whole(tycoon.area, 1, maxArea, 1),
		standName = if type(tycoon.standName) == "string"
			then TextUtil.cutChars(tycoon.standName, LIMITS.MaxStandNameChars)
			else "",
		lastSaveAt = timestamp(tycoon.lastSaveAt),
		tutorialStep = whole(tycoon.tutorialStep, 0, LIMITS.MaxTutorialStep, 0),
	}
end

--[[
	Repairs one world's state (R57; the GENERIC reconciler used for known and unknown worlds):
	every number finite and clamped like its main-world twin, sets / maps bounded.
	@param maxArea the world's area count (unknown world: LIMITS.MaxArea)
	Example: reconcileWorldState({ cash = 0 / 0, tycoon = { area = 99 } }, 6) --> cash 0, area 6
]]
local function reconcileWorldState(raw: unknown, maxArea: number): WorldState
	local source = fieldsOf(raw)
	local world = ProfileLogic.newWorldState()
	world.unlocked = bool(source.unlocked, false)
	world.unlockedAt = timestamp(source.unlockedAt)
	world.cash = amount(source.cash, LIMITS.MaxCash, 0)
	world.totalEarned = amount(source.totalEarned, LIMITS.MaxCash, 0)
	world.tycoon = reconcileTycoon(source.tycoon, maxArea)
	world.rebirths = whole(source.rebirths, 0, LIMITS.MaxCounter, 0)
	world.rebirthTokens = whole(source.rebirthTokens, 0, LIMITS.MaxCounter, 0)
	world.rebirthShop = reconcileNumberMap(source.rebirthShop, LIMITS.MaxRebirthShop, LIMITS.MaxLevel, true)
	local stats = fieldsOf(source.stats)
	for _, key in WORLD_STAT_KEYS do
		(world.stats :: any)[key] = whole(stats[key], 0, LIMITS.MaxCounter, 0)
	end
	world.stats.lastVisitDay = whole(stats.lastVisitDay, -1, LIMITS.MaxDay, -1)
	world.starter.bought = bool(fieldsOf(source.starter).bought, false)
	return world
end

--[[
	Repairs profile.worlds (R57). Every KNOWN world is always present (repaired, or a default
	entry) with its area clamped to the world's area count. Unknown well-formed keys (a newer
	server's World 3) are KEPT through the same generic reconciler (area ≤ MaxArea) so this server
	never destroys their data; they fill the slots left under MaxWorlds in key order (at most
	MaxWorldCandidates are examined, so a hostile save can't make the sort expensive).
	Dropped: "main", malformed keys, non-table values, anything past MaxWorlds.
]]
local function reconcileWorlds(raw: unknown): { [string]: WorldState }
	local source = fieldsOf(raw)
	local out: { [string]: WorldState } = {}
	for _, worldId in KNOWN_WORLDS do
		out[worldId] = reconcileWorldState(source[worldId], KNOWN_AREA_COUNT[worldId])
	end
	local free = LIMITS.MaxWorlds - #KNOWN_WORLDS
	if free <= 0 then
		return out
	end
	local candidates: { string } = {}
	for key, value in source do
		if isWorldKey(key) and key ~= MAIN_WORLD and out[key :: string] == nil and plainTable(value) ~= nil then
			table.insert(candidates, key :: string)
			if #candidates >= LIMITS.MaxWorldCandidates then
				break
			end
		end
	end
	table.sort(candidates)
	for index = 1, math.min(free, #candidates) do
		local worldId = candidates[index]
		out[worldId] = reconcileWorldState(source[worldId], LIMITS.MaxArea)
	end
	return out
end

--[[
	Builds a valid profile from ANY stored table: missing / wrong-typed fields get defaults,
	numbers are finite and clamped, strings capped on character boundaries, maps and lists
	bounded, references (equipped pets) checked. Unknown top-level fields are dropped (the
	schema here is the single source of truth). Never errors.
	@param raw stored data (already migrated to the current schema)
	@return a fresh profile (shares no tables with `raw`)
]]
function ProfileLogic.reconcile(raw: { [string]: unknown }): Profile
	local profile = ProfileLogic.defaultProfile()
	profile.cash = amount(raw.cash, LIMITS.MaxCash, 0)
	profile.gems = whole(raw.gems, 0, LIMITS.MaxGems, 0)
	profile.totalEarned = amount(raw.totalEarned, LIMITS.MaxCash, 0)
	profile.rebirths = whole(raw.rebirths, 0, LIMITS.MaxCounter, 0)
	profile.rebirthTokens = whole(raw.rebirthTokens, 0, LIMITS.MaxCounter, 0)
	profile.rebirthShop = reconcileNumberMap(raw.rebirthShop, LIMITS.MaxRebirthShop, LIMITS.MaxLevel, true)

	-- The main run keeps its v1 clamps exactly (area ≤ MaxArea).
	profile.tycoon = reconcileTycoon(raw.tycoon, LIMITS.MaxArea)

	local stats = fieldsOf(raw.stats)
	for _, key in STAT_KEYS do
		(profile.stats :: any)[key] = whole(stats[key], 0, LIMITS.MaxCounter, 0)
	end

	profile.passes = reconcileStringSet(raw.passes, 64)
	profile.receipts = reconcileNumberMap(raw.receipts, LIMITS.MaxReceipts * 4, LIMITS.MaxTimestamp, true)
	trimReceipts(profile.receipts, LIMITS.MaxReceipts)
	profile.pets = reconcilePets(raw.pets)
	profile.crates = reconcileCrates(raw.crates)
	profile.trails = reconcileTrails(raw.trails)
	profile.boosts = reconcileNumberMap(raw.boosts, LIMITS.MaxBoosts, LIMITS.MaxTimestamp, true)

	local daily = fieldsOf(raw.daily)
	profile.daily.streak = whole(daily.streak, 0, LIMITS.MaxStreak, 0)
	profile.daily.lastDay = whole(daily.lastDay, -1, LIMITS.MaxDay, -1)

	local timeRewards = fieldsOf(raw.timeRewards)
	profile.timeRewards.day = whole(timeRewards.day, -1, LIMITS.MaxDay, -1)
	profile.timeRewards.seconds = whole(timeRewards.seconds, 0, 86_400 * 2, 0)
	-- Owner R89: claims of an older ladder (missing `ladder` = 1, the 7-gift ladder) are mapped onto
	-- the current ladder so no gift is paid twice on the update day (PlaytimeConfig.migrateClaimed).
	profile.timeRewards.claimed = PlaytimeConfig.migrateClaimed(
		whole(timeRewards.ladder, 0, 1_000, 1),
		reconcileNumberSet(timeRewards.claimed, LIMITS.MaxTimeRewardIndex),
		profile.timeRewards.seconds
	)
	profile.timeRewards.ladder = PlaytimeConfig.LadderVersion

	local spin = fieldsOf(raw.spin)
	profile.spin.free = whole(spin.free, 0, LIMITS.MaxSpins, 1)
	profile.spin.lastFreeAt = timestamp(spin.lastFreeAt)
	profile.spin.paid = whole(spin.paid, 0, LIMITS.MaxSpins, 0)
	-- Missing in older saves → 0 (their spins stay in `paid`: treated as Robux-sourced, fail closed).
	profile.spin.bonus = whole(spin.bonus, 0, LIMITS.MaxSpins, 0)

	profile.codes = reconcileStringSet(raw.codes, LIMITS.MaxCodes)
	profile.group.claimed = bool(fieldsOf(raw.group).claimed, false)
	profile.notify.claimed = bool(fieldsOf(raw.notify).claimed, false)
	-- Owner R122: usual start hour 0..23; missing / junk (older saves) → -1 (unknown).
	profile.notify.hour = whole(fieldsOf(raw.notify).hour, -1, 23, -1)
	profile.offline.lastSeenAt = timestamp(fieldsOf(raw.offline).lastSeenAt)
	profile.starter.bought = bool(fieldsOf(raw.starter).bought, false)
	profile.secretPack.bought = bool(fieldsOf(raw.secretPack).bought, false)

	local attack = fieldsOf(raw.attack)
	profile.attack.aa = whole(attack.aa, 0, LIMITS.MaxLevel, 0)
	profile.attack.launcher = whole(attack.launcher, 0, LIMITS.MaxLevel, 0)
	profile.attack.shieldUntil = timestamp(attack.shieldUntil)
	profile.attack.cooldownUntil = timestamp(attack.cooldownUntil)
	profile.attack.hitsTaken = whole(attack.hitsTaken, 0, LIMITS.MaxCounter, 0)
	profile.attack.barrage = whole(attack.barrage, 0, LIMITS.MaxItemCount, 0)
	-- Owner R80 defence tower slots: a DENSE list (never holes: DataStore arrays), whole levels,
	-- at most MaxTowerSlots entries; anything else (older saves, junk) → {} (nothing bought yet).
	local towers: { number } = {}
	local storedTowers = plainTable(attack.towers)
	if storedTowers ~= nil then
		for index = 1, LIMITS.MaxTowerSlots do
			local value = storedTowers[index]
			if value == nil then
				break
			end
			towers[index] = whole(value, 0, LIMITS.MaxLevel, 0)
		end
	end
	profile.attack.towers = towers
	-- Owner R85: stored golden revenge nukes (whole; the same storage bound as Barrage nukes).
	profile.attack.golden = whole(attack.golden, 0, LIMITS.MaxItemCount, 0)

	local event = fieldsOf(raw.event)
	profile.event.season = if type(event.season) == "string"
		then TextUtil.cutChars(event.season, LIMITS.MaxSeasonChars)
		else ""
	profile.event.acorns = whole(event.acorns, 0, LIMITS.MaxCounter, 0)
	profile.event.stickers = reconcileNumberSet(event.stickers, LIMITS.MaxStickers)
	profile.event.redeemed = bool(event.redeemed, false)
	profile.event.decor = reconcileDecor(event.decor)
	profile.event.turkeys = whole(event.turkeys, 0, LIMITS.MaxCounter, 0)
	profile.event.lures = whole(event.lures, 0, LIMITS.MaxItemCount, 0)
	-- Owner R97: additive (older saves have none → "" = not granted yet; the grant tops up).
	profile.event.starterSeason = if type(event.starterSeason) == "string"
		then TextUtil.cutChars(event.starterSeason, LIMITS.MaxSeasonChars)
		else ""

	local settings = fieldsOf(raw.settings)
	for _, key in ProfileLogic.SettingKeys do
		(profile.settings :: any)[key] = bool(settings[key], (SETTING_DEFAULTS :: any)[key])
	end

	local analytics = fieldsOf(raw.analytics)
	for _, key in ANALYTICS_WHOLE_KEYS do
		(profile.analytics :: any)[key] = whole(analytics[key], 0, LIMITS.MaxAnalyticsNumber, 0)
	end
	profile.analytics.play = amount(analytics.play, LIMITS.MaxAnalyticsNumber, 0)
	profile.analytics.staff = bool(analytics.staff, false)
	profile.analytics.payDays = reconcilePayDays(analytics.payDays)
	profile.analytics.outbox = reconcileOutbox(analytics.outbox)
	-- WHAT'S NEW (R58): missing in older saves → nothing seen (a returning player gets the newest
	-- note once); a malformed id → ""; a well-formed id from a newer server is kept.
	profile.notes = ChangeNotesConfig.reconcileState(raw.notes)
	-- Player Titles (R74): missing in older saves → none granted; junk dropped; capped.
	profile.titles = PlayerTitles.reconcileState(raw.titles)
	-- R78 Nuke Pass: missing in pre-0.6.0 saves → no season yet; tier sets read in map or array
	-- form; numbers whole + clamped; premium seasons bounded.
	profile.pass = PassConfig.reconcileState(raw.pass)
	-- R78: missing in every pre-0.6.0 save → no rush (old profiles never get a Rookie Rush) and
	-- not referred; junk repaired / bounded.
	profile.rush = SocialConfig.reconcileRush(raw.rush)
	profile.referral = SocialConfig.reconcileReferral(raw.referral)
	-- R78 Quests: missing in pre-0.6.0 saves → a fresh record; junk repaired, numbers clamped,
	-- picks deduplicated, maps bounded (QuestConfig.reconcileState).
	profile.quests = QuestConfig.reconcileState(raw.quests)
	-- R57 v2: worlds (known ones always present) + the last session's world.
	profile.worlds = reconcileWorlds(raw.worlds)
	profile.lastWorld = if isWorldKey(raw.lastWorld) then raw.lastWorld :: string else MAIN_WORLD
	-- Owner R88: missing in every pre-R88 save → "" (the default sign); a non-string → ""; capped on
	-- characters (UTF-8 safe; invalid UTF-8 → ""). Shown only after a fresh TextService filter.
	profile.plotName = if type(raw.plotName) == "string"
		then TextUtil.cutChars(raw.plotName :: string, LIMITS.MaxPlotNameChars)
		else ""
	-- Owner R89: missing in every pre-R89 save → GiftsConfig.newState() (nothing bought / prompted).
	profile.gifts = GiftsConfig.reconcileState(raw.gifts)
	-- Owner R89 Flavour Book: missing in every pre-R89 save → empty; keys must parse, counts whole +
	-- capped, claimed only `true`, maps bounded (a newer server's world key is kept).
	profile.flavors = FlavorLogic.reconcileState(raw.flavors)
	-- Owner R90 Mega Lever + Tip Jar: missing in every pre-R90 save → fresh; world keys checked,
	-- numbers finite + clamped, entries bounded (KineticLogic.reconcileState).
	profile.kinetic = KineticLogic.reconcileState(raw.kinetic)
	-- Owner R128: the retired Order Window's `orders` field is NOT read: building from the defaults
	-- drops it from the next save (no other field is affected).
	return profile
end

-- Migrations ------------------------------------------------------------------------------------

--[[
	MIGRATIONS[n] upgrades stored data IN PLACE from schema n to n + 1 (raw tables, before
	reconcile). To add v(n+1): write MIGRATIONS[n] = function(data) ... end, bump SCHEMA_VERSION,
	extend defaultProfile / reconcile / snapshot, and add a test case.
]]
local MIGRATIONS: { [number]: (data: { [string]: any }) -> () } = {}

--[[
	v1 → v2 (owner R57 World 2): purely additive, so nothing is rewritten. reconcile() then adds
	`worlds` (a default entry per known world) and `lastWorld = "main"`. Every v1 value is carried
	over untouched (tests/profile-logic.luau proves a v1 save round-trips field for field). World
	unlocks of legacy players (main area ≥ 3 or a rebirth) are granted by WorldService at join
	("legacy" source), not here, so the rule lives in one place.
]]
MIGRATIONS[1] = function(_data: { [string]: any }) end

--[[
	Loads stored data into the current schema.
	@return the profile and its status:
		"new"      nothing stored (or not a table): a fresh default profile
		"current"  stored at the current version (reconciled)
		"migrated" upgraded through MIGRATIONS (reconciled)
		"newer"    saved by a NEWER game version: reconciled for display only — ProfileStore
		           opens it read-only so this older server never overwrites newer data
	Example: local profile, status = ProfileLogic.migrate(storedValue)
]]
function ProfileLogic.migrate(raw: unknown): (Profile, MigrationStatus)
	if type(raw) ~= "table" then
		return ProfileLogic.defaultProfile(), "new"
	end
	local data = ProfileLogic.deepCopy(raw :: { [string]: any })
	local version = if isFinite(data.schemaVersion) then math.floor(data.schemaVersion) else 1
	if version > ProfileLogic.SCHEMA_VERSION then
		local newer = ProfileLogic.reconcile(data)
		newer.schemaVersion = version -- shown as-is; the session is read-only anyway
		return newer, "newer"
	end
	local status: MigrationStatus = "current"
	version = math.max(version, 1)
	while version < ProfileLogic.SCHEMA_VERSION do
		local step = MIGRATIONS[version]
		if step ~= nil then
			step(data)
		end
		version += 1
		status = "migrated"
	end
	data.schemaVersion = ProfileLogic.SCHEMA_VERSION
	return ProfileLogic.reconcile(data), status
end

-- Currency --------------------------------------------------------------------------------------

--[[
	Adds cash (a positive, finite amount) and the same amount to totalEarned (lifetime cash for
	leaderboards). Clamped to MaxCash.
	@return the amount actually added (0 for an invalid amount or a full balance)
	Example: ProfileLogic.addCash(profile, 25) --> 25
]]
function ProfileLogic.addCash(profile: Profile, value: number): number
	if not isFinite(value) or value <= 0 then
		return 0
	end
	local before = profile.cash
	profile.cash = math.min(before + value, LIMITS.MaxCash)
	local added = profile.cash - before
	profile.totalEarned = math.min(profile.totalEarned + added, LIMITS.MaxCash)
	return added
end

--[[
	Spends cash atomically: deducts only when the balance covers it.
	@return true when deducted; false for an invalid amount or not enough cash
]]
function ProfileLogic.spendCash(profile: Profile, value: number): boolean
	if not isFinite(value) or value <= 0 or profile.cash < value then
		return false
	end
	-- Clamp at 0: float subtraction of an equal amount must never leave a negative dust balance.
	profile.cash = math.max(0, profile.cash - value)
	return true
end

--[[
	Adds whole gems (positive integer). Clamped to MaxGems.
	@return gems actually added (0 for an invalid amount)
]]
function ProfileLogic.addGems(profile: Profile, value: number): number
	if not isFinite(value) or value <= 0 or value % 1 ~= 0 then
		return 0
	end
	local before = profile.gems
	profile.gems = math.min(before + value, LIMITS.MaxGems)
	return profile.gems - before
end

--[[
	Spends whole gems atomically.
	@return true when deducted; false for an invalid amount or not enough gems
]]
function ProfileLogic.spendGems(profile: Profile, value: number): boolean
	if not isFinite(value) or value <= 0 or value % 1 ~= 0 or profile.gems < value then
		return false
	end
	profile.gems -= value
	return true
end

-- Worlds (R57, schema v2) ------------------------------------------------------------------------

--[[
	A non-main world's state, or nil when this profile has none. Read-only: never creates an
	entry (prompt checks, balance reads, snapshot helpers).
	Example: local dino = ProfileLogic.peekWorld(profile, "dino") --> WorldState (known worlds)
]]
function ProfileLogic.peekWorld(profile: Profile, worldId: string): WorldState?
	if worldId == MAIN_WORLD or not isWorldKey(worldId) then
		return nil
	end
	return profile.worlds[worldId]
end

--[[
	A non-main world's state, created (default, locked) when missing. Known worlds always exist
	after reconcile / defaultProfile, so creation only happens for hand-built tables (tests, a
	world added to the registry mid-session). Errors for "main", a malformed id, or a NEW id past
	MaxWorlds: callers only ever pass registry world ids, so each is a programming error, never
	player input (remote handlers validate with Validate.worldId first).
	Example: ProfileLogic.worldState(profile, "dino").stats.visits += 1
]]
function ProfileLogic.worldState(profile: Profile, worldId: string): WorldState
	local existing = ProfileLogic.peekWorld(profile, worldId)
	if existing ~= nil then
		return existing
	end
	if worldId == MAIN_WORLD or not isWorldKey(worldId) then
		error(`[ProfileLogic] worldState: {tostring(worldId)} is not a non-main world id`)
	end
	local count = 0
	for _ in profile.worlds do
		count += 1
	end
	if count >= LIMITS.MaxWorlds then
		error(`[ProfileLogic] worldState: no room for world {worldId} (MaxWorlds {LIMITS.MaxWorlds})`)
	end
	local created = ProfileLogic.newWorldState()
	profile.worlds[worldId] = created
	return created
end

--[[
	Adds a world's currency (a positive, finite amount; Dino Valley: Bones) and the same amount to
	that world's totalEarned. Clamped to MaxCash. Mirrors addCash.
	@return the amount actually added (0 for an invalid amount or a full balance)
	Example: ProfileLogic.addWorldCash(profile, "dino", 25) --> 25
]]
function ProfileLogic.addWorldCash(profile: Profile, worldId: string, value: number): number
	if not isFinite(value) or value <= 0 then
		return 0
	end
	local world = ProfileLogic.worldState(profile, worldId)
	local before = world.cash
	world.cash = math.min(before + value, LIMITS.MaxCash)
	local added = world.cash - before
	world.totalEarned = math.min(world.totalEarned + added, LIMITS.MaxCash)
	return added
end

--[[
	Spends a world's currency atomically: deducts only when that world's balance covers it.
	Currencies never mix: Bones can only pay for Bones prices.
	@return true when deducted; false for an invalid amount or not enough
]]
function ProfileLogic.spendWorldCash(profile: Profile, worldId: string, value: number): boolean
	if not isFinite(value) or value <= 0 then
		return false
	end
	local world = ProfileLogic.worldState(profile, worldId)
	if world.cash < value then
		return false
	end
	-- Clamp at 0: float subtraction of an equal amount must never leave a negative dust balance.
	world.cash = math.max(0, world.cash - value)
	return true
end

--[[
	Adds whole rebirth tokens of a world (Dino Valley: Amber). Clamped to MaxCounter.
	@return tokens actually added (0 for an invalid amount)
	Example: ProfileLogic.addWorldTokens(profile, "dino", 12) --> 12
]]
function ProfileLogic.addWorldTokens(profile: Profile, worldId: string, value: number): number
	if not isFinite(value) or value <= 0 or value % 1 ~= 0 then
		return 0
	end
	local world = ProfileLogic.worldState(profile, worldId)
	local before = world.rebirthTokens
	world.rebirthTokens = math.min(before + value, LIMITS.MaxCounter)
	return world.rebirthTokens - before
end

--[[
	Spends whole rebirth tokens of a world atomically.
	@return true when deducted; false for an invalid amount or not enough tokens
]]
function ProfileLogic.spendWorldTokens(profile: Profile, worldId: string, value: number): boolean
	if not isFinite(value) or value <= 0 or value % 1 ~= 0 then
		return false
	end
	local world = ProfileLogic.worldState(profile, worldId)
	if world.rebirthTokens < value then
		return false
	end
	world.rebirthTokens -= value
	return true
end

-- Receipts --------------------------------------------------------------------------------------

--[[ True if a developer-product receipt (PurchaseId) was already granted to this profile. ]]
function ProfileLogic.hasReceipt(profile: Profile, purchaseId: string): boolean
	return profile.receipts[purchaseId] ~= nil
end

--[[
	Records a developer-product receipt (PurchaseId) in the bounded ledger (newest MaxReceipts
	kept; the oldest is evicted first, so the receipt being recorded is never the one evicted).
	MonetizationService grants ONLY when this returns true, in the same non-yielding step —
	that is what makes ProcessReceipt idempotent. An evicted receipt is safe: it was only recorded
	after its grant, and PurchaseGranted is only returned once that grant was saved, so Roblox
	never redelivers it.
	@return true if newly recorded, false if this PurchaseId was already granted
]]
function ProfileLogic.recordReceipt(profile: Profile, purchaseId: string, now: number): boolean
	if ProfileLogic.hasReceipt(profile, purchaseId) then
		return false
	end
	trimReceipts(profile.receipts, LIMITS.MaxReceipts - 1)
	profile.receipts[purchaseId] = if isFinite(now) then math.floor(now) else 0
	return true
end

-- Settings --------------------------------------------------------------------------------------

--[[
	Applies one client settings toggle (SetSetting remote). Only the allowlisted keys (SettingKeys) with a
	boolean value are accepted.
	@return true when the stored value changed
	Example: ProfileLogic.applySetting(profile.settings, "music", false) --> true
]]
function ProfileLogic.applySetting(settings: Settings, key: unknown, value: unknown): boolean
	if type(value) ~= "boolean" or type(key) ~= "string" then
		return false
	end
	if not SETTING_KEY_SET[key :: string] then
		return false
	end
	local current = (settings :: any)[key]
	if current == value then
		return false
	end
	(settings :: any)[key] = value
	return true
end

-- Save payload ----------------------------------------------------------------------------------

-- A number set as a sorted array of its members ({ [3] = true, [1] = true } → { 1, 3 }).
local function setToList(set: { [number]: true }): { number }
	local list: { number } = {}
	for index in set do
		table.insert(list, index)
	end
	table.sort(list)
	return list
end
ProfileLogic.setToList = setToList

-- Replaces non-finite numbers in a fresh copy with 0 (DataStores cannot encode them).
local function scrubNonFinite(value: any, path: string)
	for key, item in value do
		if type(item) == "number" and not isFinite(item) then
			warn(`[ProfileLogic] non-finite number at {path}.{tostring(key)}; saved as 0`)
			value[key] = 0
		elseif type(item) == "table" then
			scrubNonFinite(item, `{path}.{tostring(key)}`)
		end
	end
end

--[[
	The DataStore payload for a profile: a deep copy with the numeric sets written as arrays and
	any non-finite number replaced by 0 (see the header). The live profile is never touched.
	Example: ProfileLogic.toSave(profile).timeRewards.claimed --> { 1, 2 }
]]
function ProfileLogic.toSave(profile: Profile): { [string]: any }
	local copy: any = ProfileLogic.deepCopy(profile)
	copy.timeRewards.claimed = setToList(profile.timeRewards.claimed)
	copy.event.stickers = setToList(profile.event.stickers)
	copy.pass = PassConfig.toSave(profile.pass) -- R78: tier sets → sorted arrays
	scrubNonFinite(copy, "profile")
	return copy
end

-- Client snapshot -------------------------------------------------------------------------------

type Builder = (profile: Profile, context: SnapshotContext) -> any

--[[
	One builder per top-level snapshot field. Each returns a FRESH value (never a live profile
	table), so later in-place mutations can never change what was already sent. Not in the
	snapshot (private bookkeeping): receipts, codes, offline, analytics, tycoon.lastSaveAt,
	pets.nextUid, worlds.*.{stats except visits, tycoon.lastSaveAt / standName / tutorialStep},
	kinetic (owner R90: lever cooldowns + jar coins; the props' attributes show them).
]]
local BUILDERS: { [string]: Builder } = {
	schemaVersion = function(profile)
		return profile.schemaVersion
	end,
	cash = function(profile)
		return profile.cash
	end,
	gems = function(profile)
		return profile.gems
	end,
	totalEarned = function(profile)
		return profile.totalEarned
	end,
	rebirths = function(profile)
		return profile.rebirths
	end,
	rebirthTokens = function(profile)
		return profile.rebirthTokens
	end,
	rebirthShop = function(profile)
		return table.clone(profile.rebirthShop)
	end,
	tycoon = function(profile)
		local tycoon = profile.tycoon
		return {
			pads = table.clone(tycoon.pads),
			producers = table.clone(tycoon.producers),
			area = tycoon.area,
			standName = tycoon.standName,
			tutorialStep = tycoon.tutorialStep,
		}
	end,
	stats = function(profile)
		return table.clone(profile.stats)
	end,
	passes = function(profile)
		return table.clone(profile.passes)
	end,
	pets = function(profile)
		local pets = profile.pets
		return {
			owned = ProfileLogic.deepCopy(pets.owned),
			equipped = table.clone(pets.equipped),
			eggs = table.clone(pets.eggs),
			pity = table.clone(pets.pity),
			index = table.clone(pets.index),
			indexClaimed = table.clone(pets.indexClaimed),
		}
	end,
	crates = function(profile)
		local crates = profile.crates
		return { held = table.clone(crates.held), pity = table.clone(crates.pity), opened = crates.opened }
	end,
	trails = function(profile)
		return { owned = table.clone(profile.trails.owned), equipped = profile.trails.equipped }
	end,
	boosts = function(profile)
		return table.clone(profile.boosts)
	end,
	daily = function(profile)
		return table.clone(profile.daily)
	end,
	timeRewards = function(profile)
		local rewards = profile.timeRewards
		return { day = rewards.day, seconds = rewards.seconds, claimed = setToList(rewards.claimed) }
	end,
	spin = function(profile)
		return table.clone(profile.spin)
	end,
	group = function(profile)
		return table.clone(profile.group)
	end,
	notify = function(profile)
		return table.clone(profile.notify)
	end,
	starter = function(profile)
		return table.clone(profile.starter)
	end,
	secretPack = function(profile)
		return table.clone(profile.secretPack)
	end,
	attack = function(profile)
		local attack = table.clone(profile.attack)
		-- Owner R80: its own copy of the tower list (the snapshot never shares a live sub-table).
		attack.towers = table.clone(profile.attack.towers)
		return attack
	end,
	event = function(profile)
		local event = profile.event
		return {
			season = event.season,
			acorns = event.acorns,
			stickers = setToList(event.stickers),
			redeemed = event.redeemed,
			decor = table.clone(event.decor), -- string key set (remote-safe)
			turkeys = event.turkeys,
			lures = event.lures,
		}
	end,
	settings = function(profile)
		return table.clone(profile.settings)
	end,
	-- R78 Nuke Pass: the whole (small) pass state with tier sets as sorted arrays (remote-safe);
	-- pushed only when PassService declares "pass" changed (XP, claims, premium, rollover).
	pass = function(profile)
		return PassConfig.toWire(profile.pass)
	end,
	-- WHAT'S NEW (R58): only the seen id (the HUD dot + the one auto pop-up read it through
	-- ChangeNotesLogic.readSeen); `at` stays server-side.
	notes = function(profile)
		return { seen = profile.notes.seen }
	end,
	-- R78 Quests: the whole (small) record — QuestService throttles progress-only pushes to one
	-- per QuestConfig.PushSeconds; completions / claims / new days push at once.
	quests = function(profile)
		return QuestConfig.snapshot(profile.quests)
	end,
	-- R78 Rush (RushService pushes it on grant / expiry and every Rush.SyncSeconds while a Rookie
	-- Rush runs; the client counts down locally between pushes for the HUD chip).
	rush = function(profile)
		return { rookieLeft = profile.rush.rookieLeft, comebackUntil = profile.rush.comebackUntil }
	end,
	-- R78 referrals: progress only (the Friends screen's n / 10). Other players' UserIds (by, seen)
	-- stay server-side; `invited` says whether this player joined through a friend's invite.
	referral = function(profile)
		return { paid = profile.referral.paid, invited = profile.referral.by > 0 }
	end,
	-- R57 v2: world STRUCTURE (pushed when a world's run / unlock / rebirth / shop changes).
	-- Known worlds only (an unknown world kept for a newer server means nothing to this client);
	-- private bookkeeping (playSeconds, runSeconds, lastSaveAt, standName, tutorialStep) stays out.
	worlds = function(profile)
		local out: { [string]: any } = {}
		for _, worldId in KNOWN_WORLDS do
			local world = profile.worlds[worldId]
			if world ~= nil then
				out[worldId] = {
					unlocked = world.unlocked,
					unlockedAt = world.unlockedAt,
					tycoon = {
						pads = table.clone(world.tycoon.pads),
						producers = table.clone(world.tycoon.producers),
						area = world.tycoon.area,
					},
					rebirths = world.rebirths,
					rebirthTokens = world.rebirthTokens,
					rebirthShop = table.clone(world.rebirthShop),
					stats = { visits = world.stats.visits },
					starter = { bought = world.starter.bought },
				}
			end
		end
		return out
	end,
	-- R57 v2: the balance of every known world the player has STARTED (unlocked, or ever held /
	-- earned any of its currency), kept apart from `worlds` so a Bones tick is a tiny delta
	-- (PlayerDataService marks only { "worldCash" } on world currency grants / spends).
	-- R70 framework fix: a locked world with a zero balance is left out — the whole worldCash
	-- table rides every currency tick, so its size must grow with the worlds a player plays, not
	-- with the worlds registered (World 3 made every tick +30 B for players who never saw it).
	-- Clients read a missing entry as 0 / 0 (ClientState.worldCash, EggView.balance). The set only
	-- grows: unlocks are sticky and totalEarned never decreases.
	worldCash = function(profile)
		local out: { [string]: { cash: number, totalEarned: number } } = {}
		for _, worldId in KNOWN_WORLDS do
			local world = profile.worlds[worldId]
			if world ~= nil and (world.unlocked or world.cash > 0 or world.totalEarned > 0) then
				out[worldId] = { cash = world.cash, totalEarned = world.totalEarned }
			end
		end
		return out
	end,
	lastWorld = function(profile)
		return profile.lastWorld
	end,
	-- Owner R88: the owner's own saved plot name (the naming window pre-fills it; "" = default).
	-- Pushed when PlotNames declares "plotName" changed (rename / reset / admin clear).
	plotName = function(profile)
		return profile.plotName
	end,
	-- Owner R89: { rocketDay, favorite } — the HUD Pocket Rocket offer hides once rocketDay == today.
	gifts = function(profile)
		return GiftsConfig.toWire(profile.gifts)
	end,
	-- Owner R89 Flavour Book: { found, claimed } copies (string keys; 15 entries today).
	flavors = function(profile)
		return FlavorLogic.toWire(profile.flavors)
	end,
	saveStatus = function(_profile, context)
		return context.saveStatus
	end,
	policy = function(_profile, context)
		return { paidRandomRestricted = context.paidRandomRestricted, known = context.policyKnown }
	end,
}

-- Every snapshot field name, sorted (docs / tests / ClientState consumers).
local SNAPSHOT_FIELDS: { string } = {}
for field in BUILDERS do
	table.insert(SNAPSHOT_FIELDS, field)
end
table.sort(SNAPSHOT_FIELDS)
ProfileLogic.SnapshotFields = table.freeze(SNAPSHOT_FIELDS)

--[[
	The owner's ProfileUpdate payload. Numeric sets arrive as sorted arrays (timeRewards.claimed,
	event.stickers). With `fields`, only those top-level fields are built (delta pushes; unknown
	names are ignored) — see ProfileSyncState.partialFields.
	Shape (full): { schemaVersion, cash, gems, totalEarned, rebirths, rebirthTokens, rebirthShop,
	  tycoon = { pads, producers, area, standName, tutorialStep }, stats, passes,
	  pets = { owned, equipped, eggs, pity, index, indexClaimed }, crates = { held, pity, opened },
	  trails = { owned, equipped }, boosts, daily, timeRewards = { day, seconds, claimed = {n} },
	  spin, group, notify, starter, secretPack, attack (incl. barrage), event = { season, acorns, stickers = {n}, decor, turkeys, lures,
	  redeemed }, settings, notes = { seen }, rush = { rookieLeft, comebackUntil },
	  referral = { paid, invited }, saveStatus, policy = { paidRandomRestricted, known },
	  worlds = { [worldId] = { unlocked, unlockedAt, tycoon = { pads, producers, area }, rebirths,
	    rebirthTokens, rebirthShop, stats = { visits }, starter = { bought } } },
	  worldCash = { [worldId] = { cash, totalEarned } }, lastWorld, plotName }   (R57 v2; known
	  worlds only; worldCash lists only worlds that are unlocked or hold / ever earned currency —
	  R70; plotName = owner R88's saved plot name, "" = default; gifts = owner R89's
	  { rocketDay, favorite }; flavors = owner R89's Flavour Book { found, claimed })
	@return a fresh table (safe to send and to keep as the last-sent copy)
	Example: ProfileLogic.snapshot(profile, context, { "cash", "totalEarned" })
]]
function ProfileLogic.snapshot(profile: Profile, context: SnapshotContext, fields: { string }?): { [string]: any }
	local out: { [string]: any } = {}
	if fields == nil then
		for field, build in BUILDERS do
			out[field] = build(profile, context)
		end
	else
		for _, field in fields do
			local build = BUILDERS[field]
			if build ~= nil then
				out[field] = build(profile, context)
			end
		end
	end
	return out
end

return table.freeze(ProfileLogic)
