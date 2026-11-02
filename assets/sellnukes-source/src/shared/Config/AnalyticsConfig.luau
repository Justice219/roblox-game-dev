--!strict
--[[
	AnalyticsConfig — every tunable, allowlist and metric definition of the SellNukes analytics layer
	(spec §13, owner R6 "a fully in-depth analytics system to track as much data as possible";
	modelled on RoBeasts' AnalyticsConfig).

	Purpose:
		The server (Server/Services/AnalyticsService) counts what players do from its OWN trusted
		events: sessions, retention, Robux, the cash / gem economy, the tycoon run (pads, producers,
		areas, managers, rebirths, offline payouts), the extra worlds (owner R57: unlock, travel,
		visitors, time in world, area pacing, rebirths per world), retention systems (daily / time / wheel / codes
		/ group / notify), pets, crates, attack mode, the Harvest Feast event, server population and
		server / client health. Counts are AGGREGATES per UTC day and family (no per-player event
		stream, no names, no user ids) flushed to the DataStore `StoreName` every FlushInterval s.
		The admin panel's Analytics tab and the COPY FOR AI / COPY RAW DATA exports read them back.

	How the numbers flow:
		gameplay hook → AnalyticsService.<recorder>() → in-memory delta (per day, per family)
		→ every FlushInterval s: UpdateAsync merge into "d:<yyyy-mm-dd>:<family>:<shard>"
		→ admin asks (AnalyticsRequest) → AnalyticsStore loads + caches + compacts old days
		→ AnalyticsLogic.summarize (+ ReportSections) → AnalyticsReport payload → Analytics tab.

	Metric keys:
		Each family is a flat { [metricKey] = number } map. Keys are built ONLY from server config
		ids (pad ids, producer ids, product keys, egg ids ...) joined with ":", sanitized and length
		capped (AnalyticsLogic.key). `Metrics` documents every key pattern; for the RECORDER families
		(`RecorderFamilies`) the same patterns are also the ALLOWLIST the generic recorders validate
		against (Server/Analytics/KeySpec), so a later system can only ever add documented keys.

	Pattern grammar (shared by the docs, KeySpec validation and AnalyticsReport.presentPatterns):
		literal       "hatch"              the part must equal it
		<a|b|c>       "<free|paid>"        one of the listed literals
		<lo-hi>       "<1-7>"              a whole number in lo..hi
		<kind>        "<padId>"            an id of that kind (KeySpec.Kinds: config lookups or ids a
		                                   system registered with AnalyticsService.registerIds)
		Parts are separated by ":". Only core / revenue / economy / health use free-form patterns
		(those keys are written by the analytics modules themselves, never by other systems).

	How a NEW system adds keys (docs/analytics.md "Adding metrics"):
		1. add `["myThing:<eggId>"] = "meaning"` under its family in `Metrics` below (recorder
		   families only: tycoon, worlds, retention, pets, crates, attack, event, social, kinetic);
		2. if it uses a new <kind>, register the ids once at Start:
		   AnalyticsService.registerIds("eggId", function(id) return EggConfig.Eggs[id] ~= nil end);
		3. call AnalyticsService.pets(player, `myThing:{eggId}`) from the server success path.
		An undocumented key is refused (counted as core "ops:badKey:<family>"), never stored.

	Example:
		local families = AnalyticsConfig.Families          -- { "core", "revenue", ... }
		local seconds = AnalyticsConfig.FlushInterval      -- 60
		local doc = AnalyticsConfig.Metrics.tycoon["pad:<padId>"]
]]

export type Family =
	"core"
	| "revenue"
	| "economy"
	| "tycoon"
	| "worlds"
	| "retention"
	| "pets"
	| "crates"
	| "attack"
	| "event"
	| "social"
	-- Owner R90 Mega Lever + Tip Jar (Server/Kinetic, K-kinetic).
	| "kinetic"
	-- RETIRED (owner R128, 0.8.1): the R90 Order Window was removed; the family stays so old days'
	-- stored counters still render (no recorder writes it any more).
	| "orders"
	| "health"
export type Range = "today" | "7d" | "30d" | "all"

local PurchasePromptConfig = require(script.Parent.PurchasePromptConfig)
local WorldsConfig = require(script.Parent.Worlds.WorldsConfig)

local AnalyticsConfig = {}

-- Families, in report order. One DataStore key per family per day keeps each write small and
-- spreads concurrent servers over several keys (DataStore per-key throughput limits). 13 families
-- = at most 13 UpdateAsync per server per minute, far under 60 + 10 × players.
AnalyticsConfig.Families = table.freeze({
	"core",
	"revenue",
	"economy",
	"tycoon",
	"worlds",
	"retention",
	"pets",
	"crates",
	"attack",
	"event",
	"social",
	"kinetic", -- owner R90 Mega Lever + Tip Jar
	"orders", -- RETIRED (owner R128, 0.8.1): old days still render; nothing records it any more
	"health",
} :: { Family })

-- Families other systems may write through the generic allowlisted recorders
-- (AnalyticsService.tycoon / worlds / retention / pets / crates / attack / event / social).
AnalyticsConfig.RecorderFamilies = table.freeze({
	"tycoon",
	"worlds",
	"retention",
	"pets",
	"crates",
	"attack",
	"event",
	"social",
	"kinetic", -- owner R90 Mega Lever + Tip Jar (Server/Kinetic → AnalyticsService.record)
	-- (orders: RETIRED by owner R128, 0.8.1 — no longer a recorder family, so any stray write is
	-- refused as a bad key; its Metrics stay below for old days.)
} :: { Family })

-- Admin panel ranges. `RangeDays` = number of UTC days ending today (nil = everything recorded).
AnalyticsConfig.Ranges = table.freeze({ "today", "7d", "30d", "all" } :: { Range })
AnalyticsConfig.RangeDays = table.freeze({ today = 1, ["7d"] = 7, ["30d"] = 30 } :: { [string]: number })
AnalyticsConfig.RangeLabels = table.freeze({
	today = "TODAY",
	["7d"] = "7 DAYS",
	["30d"] = "30 DAYS",
	all = "ALL TIME",
} :: { [string]: string })

-- Storage --------------------------------------------------------------------------------------

AnalyticsConfig.StoreName = "SellNukesAnalytics_v1"
-- Seconds between flushes of this server's deltas (each flush = one UpdateAsync per family that
-- changed). 60 s keeps a busy server at ≤ 11 writes/min.
AnalyticsConfig.FlushInterval = 60
-- Write shards per family-day key. Each server writes shard (hash(JobId) % ShardCount). Raise it
-- only when ~100+ servers run at once (per-key write throughput); reads multiply by it for the
-- two newest days only (older days are compacted into one key).
AnalyticsConfig.ShardCount = 1
-- Days older than this many days are final: the first reader merges their family keys into one
-- compact key "c:<day>" (and ended months into "m:<yyyy-mm>"). 2 days covers any retry.
AnalyticsConfig.CompactAfterDays = 2
-- Undelivered deltas are retried on every flush, then dropped (with a warning) after this long.
AnalyticsConfig.MaxRetrySeconds = 1800
-- Request budget left for everything else (profile saves first) before analytics waits its turn.
AnalyticsConfig.UpdateBudgetReserve = 20
AnalyticsConfig.GetBudgetReserve = 8
-- Studio playtests never write live analytics (tests and admin bots would pollute real data).
-- Reading is allowed, so the owner can review live numbers from Studio.
AnalyticsConfig.WriteInStudio = false
-- BindToClose: how long the final flush may run (profile saves share the 30 s budget).
AnalyticsConfig.CloseFlushSeconds = 12
-- Bounds: distinct keys per family per day (extra keys fold into "_other") and key length.
AnalyticsConfig.MaxKeysPerFamily = 2500
AnalyticsConfig.MaxKeyLength = 72
AnalyticsConfig.MaxKeyPart = 32
-- Largest single counter value kept (sums of late-game cash can approach the double range; a
-- sum that would overflow to inf is clamped here instead of being lost).
AnalyticsConfig.MaxCounterValue = 1e300

-- Admin requests ---------------------------------------------------------------------------------

-- Loaded ranges are shared by every admin for this long (and live keys re-read no sooner).
AnalyticsConfig.CacheSeconds = 30
-- Per-admin token bucket for AnalyticsRequest (requests, refill per second).
AnalyticsConfig.RequestBurst = 4
AnalyticsConfig.RequestPerSecond = 0.2
-- Compacted (immutable) keys kept in memory per server.
AnalyticsConfig.MaxCachedKeys = 240
-- Rows per ranked table sent to the panel, and the COPY FOR AI size cap (characters).
AnalyticsConfig.TableRows = 25
AnalyticsConfig.ReportMaxChars = 130000
-- Report sections the parser and the admin tab accept (bounded payload / pooled UI).
AnalyticsConfig.ReportMaxTables = 80

-- Retention and sessions -------------------------------------------------------------------------

-- DN retention: % of a day's new players who came back exactly N days later.
AnalyticsConfig.RetentionDays = table.freeze({ 1, 3, 7, 14, 30 })
-- Session-length histogram bucket upper bounds, in minutes (the last bucket is open-ended).
AnalyticsConfig.SessionBuckets = table.freeze({ 2, 5, 15, 30, 60, 120 })
-- Lifetime session number buckets, labelled by their lowest count (AnalyticsLogic.countBucket):
-- "sessNo:<label>" with labels 1, 2, 3, 4-5, 6-10, 11-20, 21+.
AnalyticsConfig.SessionNumberBuckets = table.freeze({ 1, 2, 3, 4, 6, 11, 21 })

--[[
	Roblox-aligned signals (owner R122; Server/Analytics/Sessions records, ReportSections'
	"algorithm" table reads; docs/analytics.md "Roblox signals"). Roblox's Recommended for You
	ranking averages these per user over Day 1 / Days 2-7 / Days 8-28 (spec §0):
		BounceSeconds      a session that ends within this many seconds is "lt60" (first-play bounce)
		QualifiedSeconds   longer than this is a qualified session ("qualified" / bounceDev "stay");
		                   BounceSeconds < length <= QualifiedSeconds is the "60to180" bucket
		PlayCapSeconds     rbx:playSec credits at most this per player per UTC day (Roblox's 60 min cap;
		                   persisted in profile.analytics.rbxDay / rbxSec, so the cap holds across
		                   sessions and servers)
		MaxCreditGapSeconds  one credit step never spans more than this (bounds the per-day split loop
		                   if flushes stalled; the cap makes anything longer irrelevant anyway)
		PlayDayMax         rbx:day:<2..PlayDayMax> (play days per user D2-7 and D8-28); the report plan
		                   loads cohort sizes for every N up to it
		MinCoverage        share of a range's sessions recorded by R122+ servers (Σ rbx:session:* /
		                   sessions) below which every rbx-derived row says PARTIAL DATA
		Targets            per scorecard row: good / watch thresholds (lowerIsBetter flips the test).
		                   Starting targets for an idle tycoon (Roblox publishes no thresholds; compare
		                   with Creator Hub benchmarks and adjust here)
]]
AnalyticsConfig.Algorithm = table.freeze({
	BounceSeconds = 60,
	QualifiedSeconds = 180,
	PlayCapSeconds = 3600,
	MaxCreditGapSeconds = 2 * 86400,
	PlayDayMax = 28,
	MinCoverage = 0.98,
	Targets = table.freeze({
		bounceLt60 = table.freeze({ good = 0.15, watch = 0.25, lowerIsBetter = true }),
		bounce60to180 = table.freeze({ good = 0.15, watch = 0.25, lowerIsBetter = true }),
		playDaysD1 = table.freeze({ good = 0.15, watch = 0.08 }),
		playDaysD2to7 = table.freeze({ good = 0.5, watch = 0.25 }),
		playDaysD8to28 = table.freeze({ good = 0.8, watch = 0.4 }),
		playtimeMinutes = table.freeze({ good = 20, watch = 10 }),
		qualifiedSessions = table.freeze({ good = 1, watch = 0.6 }),
		coplayDays = table.freeze({ good = 0.1, watch = 0.04 }),
		spendDays = table.freeze({ good = 0.01, watch = 0.003 }),
		robuxPerUser = table.freeze({ good = 0.5, watch = 0.1 }),
	} :: { [string]: { good: number, watch: number, lowerIsBetter: boolean? } }),
})

-- Devices (ClientDevice remote) --------------------------------------------------------------------

AnalyticsConfig.DeviceClasses = table.freeze({ "phone", "tablet", "desktop", "console" })
AnalyticsConfig.InputModes = table.freeze({ "touch", "kbm", "gamepad" })
-- Per-player token bucket: a real client reports at boot and on input change (1–4 per session).
AnalyticsConfig.DeviceReport = table.freeze({ Burst = 4, PerSecond = 0.1 })

-- New Player Mode seam (admin "play as a new player", spec §14). The admin builder sets this
-- server attribute on the Player; while it is true every per-player recorder is diverted to core
-- "npm:<recorder>" so a sandbox profile never looks like a real first-timer.
AnalyticsConfig.NewPlayerModeAttribute = "NewPlayerMode"

-- New-player (FTUE) funnel (Shared/Analytics/NewPlayerFunnel) ---------------------------------------

--[[
	Ordered FTUE steps of the tycoon. SAVE DATA: step i is bit (i - 1) of profile.analytics.ftue,
	so the list is APPEND ONLY (never reorder / remove). `client` steps arrive on the FunnelStep
	remote (validated: allowlist + once per player); every other step is observed on the server.
		joined         a brand-new profile loaded into a saving session (the funnel's 100 %)
		loadingDone    (client) the loading screen handed over to the game
		plotReady      the player was given a plot (PlotService)
		firstPad       first pad bought (the free Workbench = tutorial step 1)
		firstClick     first producer click
		firstCash      first production payout
		firstUpgrade   first producer upgrade
		pad5           fifth pad bought
		manager        first Manager hired (idle income starts)
		area2..area5   Nuke Stand / BoomDash / Glow Rock Mine / Enrichment Lab opened
		firstRebirth   first rebirth
		hudShown       (client) the HUD was visible after loading (Tycoon/FtueTracker)
	Appended R78 §6 (first-minute fix; client claims, plausibility-checked by the server through
	Shared/Analytics/FtueLogic.claimPlausible, sent by Tycoon/FtueTracker):
		firstScreenClosed  (client) the first window the player closed after loading (side step)
		tutorialSeen       (client) the tutorial hint was genuinely on screen (no loading screen,
		                   reveal camera or window over it)
		firstMove          (client) the character got FtueConfig.Track.MoveStuds from where the
		                   player gained control on their plot, by the player's own steering
	`Order` is the funnel's READING order (chronological main path; report rows, "previous step"
	ratios and the furthest step of a session follow it); `SideSteps` are reported after it and
	are never a session's furthest step. Every Steps id is in exactly one of the two lists
	(tests/ftue-logic.luau).
]]
AnalyticsConfig.Ftue = table.freeze({
	Steps = table.freeze({
		"joined",
		"loadingDone",
		"plotReady",
		"firstPad",
		"firstClick",
		"firstCash",
		"firstUpgrade",
		"pad5",
		"manager",
		"area2",
		"area3",
		"area4",
		"area5",
		"firstRebirth",
		"hudShown",
		-- R78 §6 (append only: bits 16..18).
		"firstScreenClosed",
		"tutorialSeen",
		"firstMove",
	}),
	ClientSteps = table.freeze({ "loadingDone", "hudShown", "firstScreenClosed", "tutorialSeen", "firstMove" }),
	-- Reading order of the main path (plotReady is assigned while the loading screen still shows).
	Order = table.freeze({
		"joined",
		"plotReady",
		"loadingDone",
		"tutorialSeen",
		"firstMove",
		"firstPad",
		"firstClick",
		"firstCash",
		"firstUpgrade",
		"pad5",
		"manager",
		"area2",
		"area3",
		"area4",
		"area5",
		"firstRebirth",
	}),
	-- Reported after the main path; never a session's furthest step.
	SideSteps = table.freeze({ "hudShown", "firstScreenClosed" }),
	-- Steps forwarded to Roblox's onboarding funnel (Creator Hub → Funnels → Onboarding), in order.
	OnboardingSteps = table.freeze({
		"joined",
		"loadingDone",
		"plotReady",
		"firstPad",
		"firstClick",
		"firstCash",
		"firstUpgrade",
		"pad5",
		"manager",
		"area2",
		"area3",
	}),
	-- Minutes-to-step histogram bounds (ftueAt:<step>:<label>).
	MinuteBuckets = table.freeze({ 1, 2, 5, 10, 20, 40, 60 }),
})

--[[
	Client FunnelStep remote (C→S). Accepted shapes, each validated against exact allowlists:
		(Ftue.ClientSteps id)              an FTUE client step, once per player per session
		                                   (loadingDone | hudShown | firstScreenClosed |
		                                   tutorialSeen | firstMove; the R78 ones also need the
		                                   server's plausibility check, FtueLogic.claimPlausible)
		("open", screen, source?)          a screen opened: retention / social "open:<screen>",
		                                   "openFrom:<screen>:<source>" (counted, capped per session)
		("tutorial", stepNumber)           the client tutorial arrow moved to step N (client view of
		                                   tutorial pacing; the server counts its own tut:<N> too)
	Counts only: nothing is granted, unlocked or shown from these.
]]
AnalyticsConfig.ClientFunnel = table.freeze({
	Burst = 8,
	PerSecond = 0.5,
	-- Screen-open reports counted per session (beyond it they are ignored).
	SessionCap = 120,
	Screens = table.freeze({
		"Shop",
		"Daily",
		"Time",
		"Wheel",
		"Codes",
		"Group",
		"Pets",
		"Rebirth",
		"Teleport",
		"Attack",
		"Event",
		"Settings",
		"Welcome",
		"Crates",
		"Eggs",
		"Index",
		"Admin",
		"Notify",
		"Offers",
		"Defense", -- B10 attack mode: AA towers / shields screen (the target picker reports "Attack")
		"Launch", -- owner R54: one launch cinematic played (Client/Attack/LaunchCam, source "auto")
		"WorldUnlocked", -- owner R57: the WORLD UNLOCKED popup (Client/Worlds; source "auto" / "portal")
		"WorldTravel", -- owner R57: the warp overlay of one world trip (source = the travel source)
		"Rewards", -- owner R62: the Rewards hub (UI/Screens/RewardsHub; its tiles open the screens above)
		"NukePass", -- owner R78: the Nuke Pass track (UI/Screens/NukePass; HUD offer / Quests banner)
		"Quests", -- owner R78: the Quests screen (UI/Screens/Quests; HUD button / objective chip)
		"Friends", -- owner R78: the Friends screen (UI/Screens/Friends; Rewards hub tile)
		"Boosts", -- owner R82: the cash corner boost badge's breakdown card (UI/Screens/BoostChips)
		"HappyHours", -- owner R89: the Happy Hours schedule panel (UI/Screens/HappyHour; HUD chip, source "chip")
		"FlavorBook", -- owner R89: the Flavour Book (UI/Screens/FlavorBook; Pets window button, source "pets")
		"More", -- owner R110: the HUD MORE flyout (UI/Hud/HudMoreMenu, source "hud"; its items report their own ids)
	}),
	Sources = table.freeze({
		"hud",
		"offer",
		"pad",
		"prompt",
		"auto",
		"npc",
		"popup",
		"keybind",
		"portal", -- R57: a Time Machine portal (ProximityPrompt / touch volume)
		"chip", -- R57: the rejoin "Back to Dino Valley?" chip
		"hub", -- R62: a Rewards hub tile (Daily / Time / Wheel / Group / Codes opened from the hub)
		"quests", -- R78: the NUKE PASS banner on the Quests screen
		"pets", -- R89: the FLAVOURS button in the Pets window (opens the Flavour Book)
		"other",
	}),
	MaxTutorialStep = 40,
})

--[[
	Why a FunnelStep report was refused (owner R122): core "ops:clientRefused:FunnelStep:<reason>"
	beside the unchanged "ops:clientRefused:FunnelStep" (Server/Analytics/Sessions.onFunnelStep).
		rate         the per-player token bucket was empty
		malformed    not a short string step, or a screen open whose screen / source is not allowlisted
		implausible  an R78 first-minute claim the server's own state contradicts (FtueLogic)
		cap          a screen open past ClientFunnel.SessionCap (reason key only: the base key never
		             counted it, so it stays comparable with the pre-R122 baseline)
		unknown      a step id that is not a client step / "open" / "tutorial" / "worldPopup"
		popup        a malformed WORLD UNLOCKED popup claim (non-string world / action not allowlisted)
	Bounded set: the key is built only from this list.
]]
AnalyticsConfig.ClientRefusalReasons = table.freeze({ "rate", "malformed", "implausible", "cap", "unknown", "popup" })

-- Offers (OffersSeen remote + server offer hooks) ----------------------------------------------------

--[[
	OffersSeen (C→S): the offers a surface actually RENDERED (the impression denominator of the
	shown → click → prompt → bought funnel). (source, offerIds, newVisit):
		newVisit = true opens a new visit (revenue "offers:open:<source>", ≤ MaxOpens per session)
		offerIds = up to MaxCards ids, each an offer id (KeySpec kind "offerId"); each counts
		           "offers:card:<id>" at most once per counted visit.
]]
AnalyticsConfig.OffersSeen = table.freeze({
	Burst = 6,
	PerSecond = 0.5,
	MaxOpens = 60,
	MaxCards = 12,
	Sources = table.freeze({ "starburst", "shop", "popup", "welcome", "pad", "hud", "other" }),
})

--[[
	Offer BUY presses (owner R137): the "click" step of the shown → click → prompt → bought funnel.
	Observed SERVER-side, never claimed by the client: MonetizationService fires
	PromptRequested(player, key, kind, source) for every PromptProduct / PromptPass request that
	passed its prompt rate limit and its catalogue-key check, BEFORE any prompt refusal (a prompt
	already open, owned, coming soon, still loading, ...). Revenue.promptRequested then counts
	revenue "offer:<id>:click" + "funnel:<id>:click" when the source is an offer surface.
		Sources        prompt sources (PurchasePromptConfig.Sources) whose surfaces render offer cards
		               and report their impressions (OffersSeen):
		                 "shop"        Shop + Crate shop BUY buttons      (impressions "shop")
		                 "offer"       HUD offer chip → DEAL card BUY     (impressions "popup")
		                 "welcomeBack" Welcome Back card BUY              (impressions "welcome")
		               Pad, wheel, attack, pets, teleport, event, pass and lucky prompts are not offer
		               cards (Lucky DEAL cards keep their own luckyDeal:* funnel): never a click.
		MaxPerSession  counted presses per analytics session; more → core
		               "ops:clientRefused:OfferClick:cap" (bounds what one exploiting client can add)
		RepeatSeconds  a second press on the SAME offer within this window is the same press (a
		               double tap / mash before the Roblox prompt appears), counted once
		Burst / PerSecond  Revenue's own token bucket: looser than PurchasePromptConfig's prompt
		               bucket (3, 0.5 / s), so it only bites if a future caller skips that limiter
	A press UI/PurchaseGuard drops on the client (the press that opened the surface, or one inside
	its arming window) never reaches the server: it was not a deliberate BUY and is not a click.
]]
AnalyticsConfig.OfferClicks = table.freeze({
	Sources = table.freeze({ "shop", "offer", "welcomeBack" }),
	MaxPerSession = 60,
	RepeatSeconds = 1,
	Burst = 4,
	PerSecond = 0.5,
})
-- Longest client-sent id / source string read at all (cheap pre-check before any lookup).
AnalyticsConfig.ClientSourceMaxLength = 32

-- Purchases by source (Server/Analytics/PromptAttribution) ------------------------------------------

AnalyticsConfig.Sales = table.freeze({
	-- A real purchase completes within seconds of its prompt; buying Robux first can take a few
	-- minutes. 30 minutes covers both without crediting a long-forgotten prompt.
	WindowSeconds = 1800,
	-- Products remembered per player (a player has one prompt open at a time; 8 is generous).
	MaxPromptsPerPlayer = 8,
	NoSource = "none",
	Unknown = "unknown",
})
-- Prompt sources: exactly MonetizationService's own allowlist (PurchasePromptConfig.Sources), so a
-- prompt source key can never hold anything MonetizationService did not accept ("other" otherwise).
AnalyticsConfig.PromptSources = PurchasePromptConfig.Sources
-- Roblox purchase-prompt dwell (opened → closed without buying), seconds.
AnalyticsConfig.DwellBounds = table.freeze({ 2, 10 })
AnalyticsConfig.DwellLabels = table.freeze({ "lt2", "2to10", "gt10" })

-- Unique players per UTC day per surface (Config/AnalyticsMarks) -------------------------------------

--[[
	core "uniq:<surface>" counts a player at most once per UTC day per surface, across servers,
	via profile.analytics.seenDay / seen (bit i - 1 = Surfaces[i]). SAVE DATA: APPEND ONLY.
]]
AnalyticsConfig.Unique = table.freeze({
	Surfaces = table.freeze({
		"shop",
		"daily",
		"time",
		"wheel",
		"codes",
		"pets",
		"hatch",
		"crate",
		"rebirth",
		"attack",
		"event",
		"offers",
		"group",
		"click",
		-- R57: a visit to an extra world ("w_<worldId>"; Server/Analytics/WorldRecorders also counts
		-- worlds "visitor:<world>" off this bit). World 3 appends its own "w_<id>" here
		-- (tests/analytics-recorders checks every extra world has one).
		"w_dino",
		"w_moon", -- R70 World 3 Moon Base
		-- RETIRED (owner R128, 0.8.1): the removed Order Window's "served a customer" bit. Kept: this
		-- list is append-only save data (bit positions), so the slot is never reused.
		"orders",
		-- owner R122: intentionally co-played that day (Server/Analytics/Sessions counts core
		-- "rbx:coplay" off this bit instead of "uniq:coplay": Roblox's co-play days signal).
		"coplay",
	}),
})

--[[
	D1 / D7 by first-day outcome: on the player's first UTC day each milestone sets one bit of
	profile.analytics.marks and counts core "cohort:<milestone>" once; on their D1 / D7 return the
	service counts "r1:<milestone>" / "r7:<milestone>" for every set bit. Bit 0 ("all") marks a
	profile created after analytics shipped. SAVE DATA: Milestones is APPEND ONLY.
]]
AnalyticsConfig.FirstDay = table.freeze({
	Milestones = table.freeze({
		"click",
		"pad5",
		"upgrade",
		"manager",
		"area2",
		"area3",
		"area4",
		"area5",
		"hatch",
		"crate",
		"wheel",
		"daily",
		"pay",
		"attack",
		"event",
		"rebirth",
	}),
	BaseId = "all",
})

-- Notification joins (Server/Analytics/ReturnTags "r<N>:notify"): LaunchData values the
-- notification sender (retention builder) attaches to its notifications. Exact match only.
AnalyticsConfig.NotifyLaunchData = table.freeze({
	"notify_daily",
	"notify_offline",
	"notify_event",
	"notify_wheel",
	-- Owner R122 return notifications (Shared/Config/NotifyConfig.launchData: "rn:<kind>").
	"rn:cashFull",
	"rn:streak",
	"rn:missions",
})

-- Tycoon ---------------------------------------------------------------------------------------------

AnalyticsConfig.Tycoon = table.freeze({
	-- Producer level marks counted once per crossing ("lvl:<producerId>:<mark>").
	LevelMarks = table.freeze({ 10, 25, 50, 75, 100, 150, 200, 300, 400, 500, 750, 1000 }),
	-- Minutes-into-run histogram for areas reached on the FIRST run ("areaB:<area>:<label>").
	AreaMinuteBuckets = table.freeze({ 5, 10, 20, 40, 60, 90, 120, 180, 240, 360, 480 }),
	-- Run length (rebirth) histogram, minutes ("runB:<label>").
	RunMinuteBuckets = table.freeze({ 30, 60, 120, 240, 360, 480, 720 }),
	-- Rebirth count buckets by lowest count ("rebirthN:<label>": 0, 1, 2, 3, 4-5, 6-10, 11-20, 21+).
	RebirthBuckets = table.freeze({ 1, 2, 3, 4, 6, 11, 21 }),
	-- Offline absence histogram, hours ("offlineB:<label>").
	OfflineHourBuckets = table.freeze({ 1, 3, 6, 12, 24, 48 }),
	-- "gem" = owner R86's flat-price gem upgrade (one level; TycoonService.onProducerGemUpgrade).
	UpgradeModes = table.freeze({ "1", "10", "max", "gem" }),
	PadKinds = table.freeze({ "Build", "Multiplier", "Speed", "Manager", "Unlock", "Feature" }),
	MaxTutorialStep = 40,
})

-- Worlds (owner R57 World 2, spec §12) ---------------------------------------------------------------

--[[
	The `worlds` family: per-world rows keyed by world id (WorldsConfig.Order: "main" = Nuke Town,
	"dino" = Dino Valley, ...). Nuke Town's own tycoon run stays in the `tycoon` family (unchanged);
	the worlds family carries what is new: unlocks, the WORLD UNLOCKED popup, portal / menu travel,
	visitors, time spent per world, and each extra world's area pacing, pads per area, rebirths,
	Amber shop, offline payouts and income share.

	Who writes it:
		Server/Analytics/WorldRecorders — typed helpers (AnalyticsService.worldUnlocked /
		  worldTravelled / worldTravelFailed / worldPortalLocked / worldAreaReached / worldRebirthed /
		  worldRebirthShop / worldOfflinePaid / worldOfflineDoubled) called by WorldService (W4),
		  TycoonService / RebirthService / OfflineService (W3); the typed tycoon helpers
		  (padBought / producerClick / producerIncome / producerUpgraded) route an extra world's ids
		  here by themselves. Time per world ("seconds:<world>") is measured by analytics itself
		  from the travel hook + the server-set Player attribute CurrentWorld.
		Client/Analytics/ClientAnalytics.worldPopup — popup claims through FunnelStep
		  ("worldPopup", worldId, action), allowlisted + capped per session.
		AnalyticsService.worlds(player, key, amount?) — the generic allowlisted recorder.

	Funnels: each extra world gets a Roblox one-time funnel named after the world ("Dino Valley" →
	"DinoValley") whose steps run unlocked → firstTravel → firstPad → manager → area2 … areaN →
	finale → rebirth; each step is also counted once per player as worlds "step:<world>:<step>".
	Progression path = the world name ("Dino Valley", level = area) and "<name> Rebirth".
]]

-- Roblox funnel name of a world: its display name without spaces / punctuation.
local function funnelNameOf(name: string): string
	return (string.gsub(name, "[^%w]", ""))
end

-- Fixed world funnel steps (area steps "area2" .. "areaN" sit between `manager` and `finale`).
local WORLD_STEPS_BEFORE: { string } = { "unlocked", "firstTravel", "firstPad", "manager" }
local WORLD_STEPS_AFTER: { string } = { "finale", "rebirth" }

-- One extra world's Roblox funnel / progression naming.
export type WorldFunnel = { name: string, path: string, steps: { string } }

local WORLD_FUNNELS: { [string]: WorldFunnel } = {}
for _, def in WorldsConfig.extra() do
	local steps: { string } = table.clone(WORLD_STEPS_BEFORE)
	for area = 2, #def.economy.Areas do
		table.insert(steps, `area{area}`)
	end
	for _, step in WORLD_STEPS_AFTER do
		table.insert(steps, step)
	end
	table.freeze(steps)
	WORLD_FUNNELS[def.id] = { name = funnelNameOf(def.name), path = def.name, steps = steps }
end
-- Frozen in a second pass (freezing while building trips the strict solver's indexer check).
for _, funnel in WORLD_FUNNELS do
	table.freeze(funnel)
end

AnalyticsConfig.Worlds = table.freeze({
	-- What unlocked a world (WorldService.unlock source; legacy = qualified before the update).
	UnlockSources = table.freeze({ "area", "rebirth", "legacy", "admin" }),
	-- WORLD UNLOCKED popup actions the client reports (lockedPreview = the locked-portal version).
	PopupActions = table.freeze({ "shown", "go", "later", "lockedPreview" }),
	-- Popup claims counted per player session, per world and action (more are ignored).
	PopupSessionCap = 6,
	-- Travel sources (WorldService.travel `source`; respawn = a respawn that crossed worlds).
	TravelSources = table.freeze({ "portal", "menu", "popup", "chip", "admin", "respawn" }),
	-- Travel refusals: TravelRules.TravelReason, plus "other" for anything a caller passes that is
	-- not listed (folded, never refused, so a new reason can never lose the count).
	TravelReasons = table.freeze({
		"unknownWorld",
		"badTarget",
		"disabled",
		"locked",
		"noPlot",
		"revealPending",
		"dead",
		"busy",
		"cooldown",
		"areaLocked",
		"plotEmpty",
		"noPass",
		"other",
	}),
	-- The world part of "travelFail" when the requested world is not a known id.
	UnknownWorld = "unknown",
	-- Seconds between counted "portalLocked" touches per player and world (the touch volume fires
	-- many times a second; the toast is throttled the same way).
	PortalLockedCooldown = 10,
	-- Most "seconds:<world>" one fold may add (a fold runs every flush, so this only clips a
	-- broken clock).
	MaxFoldSeconds = 3600,
	-- Per extra world: { name = Roblox funnel name, path = progression path, steps = funnel steps }.
	Funnels = table.freeze(WORLD_FUNNELS),
})

-- Economy ------------------------------------------------------------------------------------------

--[[
	Every currency the economy family books ("earn|spend:<currency>"), and the name Roblox's
	Creator Dashboard shows for it (LogEconomyEvent currency): Nuke Town's cash + Rebirth Tokens,
	gems, the event's acorns, then EACH extra world's currency + rebirth tokens straight from
	WorldsConfig (Dino Valley: "bones" = "Bones", "amber" = "Amber"), so World 3 needs no edit here.
]]
local ECONOMY_CURRENCIES: { string } = { "cash", "gems", "acorns", "tokens" }
local CURRENCY_NAMES: { [string]: string } = { cash = "Cash", gems = "Gems", acorns = "Acorns", tokens = "Tokens" }
for _, def in WorldsConfig.extra() do
	for _, currency in { def.currency, def.tokens } do
		if CURRENCY_NAMES[currency.key] == nil then
			table.insert(ECONOMY_CURRENCIES, currency.key)
			CURRENCY_NAMES[currency.key] = currency.name
		end
	end
end

AnalyticsConfig.Economy = table.freeze({
	Currencies = table.freeze(ECONOMY_CURRENCIES),
	-- currency key → Creator Dashboard currency name ("bones" → "Bones").
	CurrencyNames = table.freeze(CURRENCY_NAMES),
	-- Distinct reason ids kept per currency and direction per server life; further reasons fold
	-- into "other" (a bug can never grow the key set without bound).
	MaxReasons = 64,
	-- Roblox economy transaction types per reason id (Enum.AnalyticsEconomyTransactionType names:
	-- IAP, Shop, Gameplay, ContextualPurchase, TimedReward, Onboarding). Looked up by the full
	-- reason id, then by its leading capitalised word ("PadBuy" → "Pad"). Reasons not listed are
	-- not forwarded one by one; their cash EARNINGS are batched into one event per player per flush.
	TransactionTypes = table.freeze({
		Purchase = "IAP",
		Robux = "IAP",
		Product = "IAP",
		Pad = "Shop",
		Upgrade = "Shop",
		Egg = "Shop",
		Crate = "Shop",
		Shop = "Shop",
		Daily = "TimedReward",
		Time = "TimedReward",
		Wheel = "Gameplay",
		Code = "Gameplay",
		Group = "Gameplay",
		Offline = "TimedReward",
		Rebirth = "Gameplay",
		Attack = "Gameplay",
		Event = "Gameplay",
		Admin = "Gameplay",
		petIndex = "Gameplay", -- R78 Pet Index milestone gems (PetIndexConfig.Reason)
		pocketRocket = "IAP", -- owner R89 Pocket Rocket developer product (cash = income seconds)
		quest = "Gameplay", -- R78 Quests rewards (QuestService grant reason)
		pass = "Gameplay", -- R78 Nuke Pass tier rewards (PassService grant reason)
		referral = "Gameplay", -- R78 referral gems (FriendService: newcomer + inviter rewards)
		GemUpgrade = "Shop", -- owner R86 gem sink: one producer level for the flat gem price
		GemUpgradeRefund = "Shop", -- R86 refund (only if a paid level could not be applied)
	} :: { [string]: string }),
	-- Producer income is forwarded to Roblox as ONE Source event per player per flush
	-- (transaction type Gameplay, sku "Production") instead of one per cycle.
	BatchedIncomeSku = "Production",
})

-- Pets -----------------------------------------------------------------------------------------------

AnalyticsConfig.Pets = table.freeze({
	Rarities = table.freeze({ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret" }),
	-- Pets owned at session end, buckets by lowest count ("owned:<label>": 0, 1-2, 3-9, 10-24,
	-- 25-49, 50-99, 100+).
	OwnedBuckets = table.freeze({ 1, 3, 10, 25, 50, 100 }),
	MaxEquipped = 12,
	HatchCounts = table.freeze({ 1, 3 }),
})

-- Social / server population --------------------------------------------------------------------------

AnalyticsConfig.Social = table.freeze({
	-- Players per server are sampled once per health window ("players:<n>", n = 0..MaxPlayers).
	MaxPlayers = 8,
	-- Friends already in the server at join ("friendsIn:<label>": 0, 1, 2, 3+).
	FriendBuckets = table.freeze({ 1, 2, 3 }),
	-- IsFriendsWith calls per join (bounded; each yields once).
	MaxFriendChecks = 8,
})

-- Key validation (Server/Analytics/KeySpec) ---------------------------------------------------------------

AnalyticsConfig.KeySpec = table.freeze({
	-- Distinct values kept per <kind> that no system registered yet (fallback rule: an identifier
	-- `[%a][%w_]*`); later values fold into "other".
	FallbackKindCap = 64,
	-- Validated keys memoized per server (hot recorders then cost one table lookup).
	MemoCap = 4096,
})

-- Roblox Creator Dashboard forwarding (Server/Analytics/RobloxForwarder) ---------------------------

AnalyticsConfig.Forward = table.freeze({
	Enabled = true,
	Burst = 60,
	BasePerMinute = 90,
	PerPlayerPerMinute = 15,
	-- The fixed custom event names (Roblox limits distinct names; fields carry config ids only).
	CustomEvents = table.freeze({
		"PadBought",
		"ManagerHired",
		"EggHatched",
		"CrateOpened",
		"WheelSpun",
		"NukeLaunched",
		"StickerFound",
		"CodeRedeemed",
	}),
})

-- Server health (Server/Analytics/ServerHealth + ServerHealthLogic) -----------------------------------------

AnalyticsConfig.Health = table.freeze({
	-- Seconds per recorded window. Matches FlushInterval so each flush carries one full window.
	WindowSeconds = 60,
	-- Seconds between Stats / ping samples (engine values are already smoothed; 2 Hz is plenty).
	SampleInterval = 0.5,
	-- Server frame time (Heartbeat dt) upper bounds in ms (16.7 = full speed; 18 absorbs jitter).
	FrameBucketsMs = table.freeze({ 18, 20, 25, 33, 50, 100 }),
	-- Stats.HeartbeatTimeMs upper bounds in ms (engine + script work inside one heartbeat).
	HeartbeatBucketsMs = table.freeze({ 2, 4, 8, 12, 16, 33 }),
	-- Human network latency upper bounds in ms (Player:GetNetworkPing × 1000).
	PingBucketsMs = table.freeze({ 50, 100, 150, 250, 400 }),
	-- Server memory (Stats:GetTotalMemoryUsageMb) upper bounds in MB.
	MemoryBucketsMb = table.freeze({ 1000, 1500, 2000, 3000, 4000, 6000 }),
	-- A window whose p95 frame time lands above this many ms counts as a "laggy minute".
	LaggyFrameMs = 33,
	-- Server loop owners that report their Luau time (ServerHealth.addTime). Anything else → Other.
	Systems = table.freeze({
		"Producers",
		"Tycoon",
		"BuildIn",
		"Plots",
		"Pets",
		"Attack",
		"Event",
		"Retention",
		"Data",
		"Monetization",
		"Analytics",
		"World",
		"Admin",
		"Other",
	}),
	-- Distinct remote names tracked for bandwidth (Remotes send observer); others fold into "other".
	MaxRemoteKeys = 96,
})

-- Report payload / COPY FOR AI ---------------------------------------------------------------------------

-- Keys that survive every trim of the payload and the COPY FOR AI JSON (the numbers every read
-- starts from): retention, sessions, funnels, revenue totals, uniques, refusals and failures.
AnalyticsConfig.ReportPinnedPrefixes = table.freeze({
	"dau",
	"new",
	"returning",
	"sessions",
	"sessionSeconds",
	"payers",
	"newPayers",
	"r1",
	"r3",
	"r7",
	"r14",
	"r30",
	"ftue",
	"cohort:",
	"uniq:",
	"devNew:",
	"devR1",
	"ops:",
	"purchases",
	"robux",
	"product:",
	"pass:",
	"area:",
	"areaAt:",
	"areaN:",
	"rebirth",
	"tut:",
	-- R57 worlds family (area / rebirth keys are pinned by the prefixes above).
	"unlock",
	"popup:",
	"travel",
	"visitor:",
	"firstVisit:",
	"seconds:",
	"step:",
	-- owner R122 Roblox-aligned signals (≤ ~55 bounded keys: bounce, sessions, playSec, coplay, days).
	"rbx:",
})
AnalyticsConfig.ReportPinnedContains = table.freeze({ "refused", "failed", "badkey" })
-- Most pinned keys kept regardless of the budget (bounds the payload if a recorder pins too many).
AnalyticsConfig.ReportPinnedMax = 800
-- Raw counters in the summary payload: one key budget for ALL families (pinned first, then a
-- greedy fill across families).
AnalyticsConfig.ReportSummaryKeys = 3000
-- toText safety margin (characters) under ReportMaxChars for numbers known only after encoding.
AnalyticsConfig.ReportMarginChars = 400
-- toText characters reserved for the definitions of the pinned keys' patterns.
AnalyticsConfig.ReportDefinitionsFloorChars = 4000
-- Where the reader finds every key pattern's meaning (printed under the definitions).
AnalyticsConfig.ReportDocsPointer =
	'docs/analytics.md ("Metrics") and AnalyticsConfig.Metrics (src/shared/Config/AnalyticsConfig.luau)'

--[[
	COPY RAW DATA (Server/Analytics/AnalyticsRaw; remotes AnalyticsRawRequest / AnalyticsRawPage):
	the server keeps the UNCAPPED totals behind each summary and hands them to admins page by page.
		PageChars / MaxPages / MaxKeysPerPage   page size bounds
		KeepSeconds / KeepPerRange / MaxSnapshots   snapshot lifetime and count
		Burst / PerSecond                       per-admin token bucket for page requests
]]
AnalyticsConfig.Raw = table.freeze({
	PageChars = 60000,
	MaxPages = 40,
	KeepSeconds = 900,
	KeepPerRange = 2,
	MaxSnapshots = 8,
	Burst = 8,
	PerSecond = 1,
	MaxKeysPerPage = 6000,
})

AnalyticsConfig.FamilyTitles = table.freeze({
	core = "Players, sessions & funnel",
	revenue = "Robux revenue & offers",
	economy = "Cash & gems economy",
	tycoon = "Tycoon run (pads, producers, areas, rebirth)",
	worlds = "Worlds (Dino Valley: unlock, travel, visitors, time, areas, rebirths)",
	retention = "Retention systems (daily, time, wheel, codes, group, notify)",
	pets = "Pets & eggs",
	crates = "Supply crates & boosts",
	attack = "Attack mode",
	event = "Live events (Harvest Feast + Happy Hours)",
	social = "Server population & social",
	kinetic = "Mega Lever + Tip Jar (hands-on plot props)",
	orders = "Order Window — retired (owner R128, 0.8.1; old days only)",
	health = "Server & client health",
} :: { [string]: string })

-- Metric definitions --------------------------------------------------------------------------------------

-- Key patterns per family: `pattern = meaning`. For RecorderFamilies these patterns are ALSO the
-- allowlist (see the header grammar).
AnalyticsConfig.Metrics = table.freeze({
	core = table.freeze({
		sessions = "sessions that ended (player left the server)",
		sessionSeconds = "total seconds of those sessions",
		["len:<bucket>"] = "sessions by length bucket (minutes: <2, 2-5, 5-15, 15-30, 30-60, 60-120, 120+)",
		["sessNo:<bucket>"] = "sessions started by the player's lifetime session number (1, 2, 3, 4-5, 6-10, 11-20, 21+)",
		dau = "unique players active that UTC day (once per player per day, across servers)",
		new = "players whose first ever day this was (the retention cohort size)",
		returning = "active players who were not new that day",
		legacy = "active players with no cohort (profile predates analytics)",
		["r<N>"] = "players active that day whose first day was exactly N days earlier (D-N returners)",
		["r<N>:carry"] = "subset of r<N> counted because the player stayed online across 00:00 UTC (not a real return)",
		["r<N>:notify"] = "subset of r<N> whose join came from one of our notifications (LaunchData)",
		["r<N>:carryRejoin"] = "carry-overs who genuinely rejoined later the same day (D1 excl. carry = r1 - r1:carry + r1:carryRejoin)",
		payers = "unique players who spent Robux that day",
		newPayers = "players whose first ever Robux purchase happened that day",
		["hour:<HH>"] = "sessions by UTC start hour (counted at session end)",
		["device:<class>"] = "ended sessions by the client's last device claim (phone/tablet/desktop/console/unknown)",
		["input:<mode>"] = "ended sessions by last input mode (touch/kbm/gamepad/unknown)",
		["devSeconds:<class>"] = "session seconds by device class",
		["devNew:<class>"] = "new players by device class (cohort for devR1)",
		["devR1:<class>"] = "D1 returners by device class (joins only)",
		["devR1carry:<class>"] = "D1 carry-overs by device class (online across midnight)",
		["ftue:<step>"] = "new-player funnel: tracked new players who reached the step (once per player, any session; steps in AnalyticsConfig.Ftue.Steps)",
		["ftueS1:<step>"] = "same step reached within the player's FIRST session",
		["ftueMin:<step>"] = "sum of lifetime play minutes at the moment the step was reached (avg = ftueMin / ftue)",
		["ftueAt:<step>:<bucket>"] = "players reaching the step by play-minutes bucket (<1, 1-2, 2-5, 5-10, 10-20, 20-40, 40-60, 60+)",
		["ftueLen:<bucket>"] = "first sessions by length bucket",
		["ftueLeft:<step>"] = "first sessions by the furthest funnel step reached when the player left",
		["ftueDev:<class>:<step>"] = "first sessions by device class and furthest step",
		["cohort:<milestone>"] = "first-day milestone reached on the player's first UTC day (cohort:all = tracked new players)",
		["r1:<milestone>"] = "D1 returners who had reached that milestone on day one (D1 by first-day outcome)",
		["r7:<milestone>"] = "D7 returners who had reached that milestone on day one",
		["uniq:<surface>"] = "unique players per UTC day who used the surface (once per player per day)",
		["followed"] = "sessions that joined by following a friend (Player.FollowUserId)",
		["build:<release>:p<place>:<metric>"] = "producer slice: the same counter tagged with the server's release and published place version",
		["build:<release>:p<place>:ftue:<step>"] = "producer slice of a new-player funnel step (Server/Analytics/BuildMetrics)",
		["build:<release>:p<place>:rbx:<signal>"] = "producer slice of an R122 Roblox signal (rbx:playSec, rbx:coplay)",
		["build:<release>:p<place>:rbx:<signal>:<bucket>"] = "producer slice of an R122 Roblox bucket (rbx:bounce:lt60 / 60to180, rbx:session:qualified)",
		["build:<release>:p<place>:tut:<n>"] = "producer slice of tutorial steps 6 / 7 (the R122 first-manager wall)",
		["ops:leftBeforeProfile"] = "sessions that ended before the profile loaded",
		["ops:badKey:<family>"] = "recorder calls refused because the key is not documented in AnalyticsConfig.Metrics (a caller bug)",
		["ops:clientRefused:<remote>"] = "client analytics reports refused (malformed / over cap / rate limited)",
		["ops:flushDropped:<family>"] = "counter batches dropped after MaxRetrySeconds of DataStore failures",
		["npm:<recorder>"] = "events of admins in New Player Mode (diverted; never counted as real players)",
		["staff:<recorder>"] = "events of staff (admins on live servers; diverted from player metrics)",
		-- Roblox-aligned signals (owner R122, Server/Analytics/Sessions; Roblox's Recommended for You
		-- ranking: first-play bounce < 60 s / 61-180 s, playtime capped at 60 min per user per day,
		-- qualified sessions, intentional co-play days). docs/analytics.md "Roblox signals".
		["rbx:bounce:<lt60|60to180>"] = "first sessions (tracked new players) that ended within 60 s / within 61-180 s (Roblox first-play bounce)",
		["rbx:bounceDev:<class>:<lt60|60to180|stay>"] = "first sessions by device class and Roblox bounce bucket (stay = longer than 180 s)",
		["rbx:session:<lt60|60to180|qualified>"] = "every ended session by Roblox bucket (qualified = longer than 180 s)",
		["rbx:playSec"] = "session seconds credited up to 3,600 per player per UTC day (Roblox's playtime cap; avg minutes per user = rbx:playSec / 60 / dau)",
		["rbx:coplay"] = "unique players per UTC day who intentionally co-played (joined by following a friend, from an invite / referral launch, or a friend followed them in)",
		["rbx:coplayVia:<follow|invite|host|private>"] = "rbx:coplay by the path that counted it: followed a friend in / joined from a friend's invite / a friend followed or was invited in to them / a private server with company",
		["rbx:day:<2-28>"] = "players active that day whose first day was exactly N days earlier, N = 2..28 (Roblox play days per user: D2-7 = Σ rbx:day:2..7 / cohort, D8-28 likewise; D1 = r1)",
		["ops:clientRefused:<remote>:<reason>"] = "client analytics reports refused, by reason (rate / malformed / implausible / cap / unknown / popup)",
	}),
	revenue = table.freeze({
		purchases = "completed Robux purchases (developer products + game passes bought in-game)",
		robux = "gross Robux estimate: product receipt amounts + game-pass list prices",
		["product:<key>:count|robux"] = "developer product purchases and their Robux",
		["pass:<key>:count|robux"] = "game pass purchases and their list-price Robux",
		["kind:<kind>:robux"] = "Robux by product kind (MonetizationConfig kind; GamePass for passes)",
		["prompt:<key>"] = "purchase prompts the server opened for that product / pass",
		["prompt:<key>:<source>"] = "prompts by the surface that opened them (AnalyticsConfig.PromptSources)",
		["promptDevice:<key>:<class>"] = "prompts by device class",
		["promptClosed:<key>"] = "prompts closed WITHOUT buying",
		["promptClosed:<key>:<source>"] = "abandoned prompts by source",
		["promptClosedDevice:<key>:<class>"] = "abandoned prompts by device class",
		["promptDwell:<source>:<class>:<bucket>"] = "abandoned prompts by how long they stayed open (lt2 / 2to10 / gt10 s)",
		["purchase:<key>:<source>"] = "completed purchases credited to the latest prompt's source (unknown = no prompt seen)",
		["robuxBySource:<source>"] = "Robux by prompt source",
		["purchaseDevice:<key>:<class>"] = "purchases by device class",
		["robuxByDevice:<class>"] = "Robux by device class",
		["robuxByArea:<area>"] = "Robux by the buyer's tycoon area at purchase time",
		["buyArea:<area>"] = "purchases by the buyer's tycoon area",
		["robuxByRebirth:<bucket>"] = "Robux by the buyer's rebirth count bucket (0, 1, 2, 3, 4-5, 6-10, 11-20, 21+)",
		["firstBuy:<key>"] = "the product / pass that was a player's FIRST ever purchase",
		["offer:<id>:shown|click"] = "server-side offer impressions / BUY presses on an offer surface (R137: Shop, offer DEAL card, Welcome Back; seen server-side on the prompt request; none in range = n/a, not 0)",
		["offers:open:<source>"] = "offer surfaces opened (OffersSeen, capped per session)",
		["offers:card:<id>"] = "offer cards actually rendered (impressions; once per visit)",
		["funnel:<key>:<step>"] = "purchase funnel per product: shown → click (BUY pressed on an offer surface, R137) → prompt (any surface) → bought",
		["staff:<recorder>"] = "staff purchases (diverted: never counted as revenue)",
	}),
	economy = table.freeze({
		["earn:<currency>"] = "currency granted (cash / gems / acorns / tokens), all reasons",
		["earn:<currency>:<reason>"] = "currency granted by reason (PlayerDataService reason id, leading letters only)",
		["spend:<currency>"] = "currency spent, all categories",
		["spend:<currency>:<reason>"] = "currency spent by reason",
		["n:earn:<currency>:<reason>"] = "number of grant events by reason",
		["n:spend:<currency>:<reason>"] = "number of spend events by reason",
		["earn:gems:robux:<key>"] = "gems that came from a Robux product",
		["staff:<recorder>"] = "staff economy events (diverted from player metrics)",
	}),
	tycoon = table.freeze({
		clicks = "producer clicks (manual cycles started)",
		["click:<producerId>"] = "producer clicks per producer (any world's producer; `clicks` counts Nuke Town only)",
		["income:<click|auto|offline>"] = "cash produced by clicked cycles, automated (managed) cycles and offline payouts (income share)",
		["incomeP:<producerId>:<click|auto>"] = "currency produced per producer, clicked vs automated (cash; Bones for Dino `dp*` producers)",
		["pad:<padId>"] = "pad purchases (all runs; any world's pad ids, e.g. d3_wind_sock)",
		["padN:<padId>"] = "FIRST-run purchases of the pad (time-to-pad denominator; first run of the pad's world)",
		["padAt:<padId>"] = "sum of first-run play seconds at the pad purchase (avg time-to-pad = padAt / padN; Dino pads use that world's run seconds)",
		["padKind:<Build|Multiplier|Speed|Manager|Unlock|Feature>"] = "pad purchases by kind",
		["padArea:<area>"] = "Nuke Town pad purchases by area (other worlds: worlds padArea:<world>:<area>)",
		["padSkip:<padId>"] = "pads bought instantly with the Skip Pad product",
		["upgrade:<producerId>"] = "producer upgrade purchases",
		["levels:<producerId>"] = "producer levels bought",
		["upgradeMode:<1|10|max|gem>"] = "upgrade purchases by bulk mode (gem = R86 one level for gems)",
		["lvl:<producerId>:<levelMark>"] = "producers that crossed a level mark (AnalyticsConfig.Tycoon.LevelMarks)",
		["manager:<producerId>"] = "Manager pads bought (automation) per producer (any world)",
		["autoClicker:<on|off>"] = "AutoClicker pass toggled in Settings (owner R64): turned on / off (off = clicks by hand)",
		["area:<area>"] = "areas reached (all runs)",
		["areaN:<area>"] = "areas reached on the FIRST run (time-to-area denominator)",
		["areaAt:<area>"] = "sum of first-run play seconds when the area opened (avg = areaAt / areaN; target = TycoonConfig.Pacing)",
		["areaB:<area>:<areaBucket>"] = "first-run area reaches by minutes-into-run bucket (AnalyticsConfig.Tycoon.AreaMinuteBuckets)",
		["tut:<1-40>"] = "tutorial steps reached (server; once per player per session)",
		["tutClient:<1-40>"] = "tutorial arrow steps shown (client claim)",
		tutDone = "tutorial completed",
		["feature:<feature>"] = "feature pads bought (StandRename / AATower / AttackConsole / Rebirth)",
		rebirth = "rebirths",
		["rebirthN:<rebirthBucket>"] = "rebirths by the player's rebirth count after the rebirth",
		rebirthSec = "sum of run lengths (play seconds) ended by a rebirth (avg = rebirthSec / rebirth)",
		["runB:<runBucket>"] = "rebirth runs by length bucket (minutes, AnalyticsConfig.Tycoon.RunMinuteBuckets)",
		rebirthTokens = "rebirth tokens granted",
		["rebirthShop:<upgradeKey>"] = "rebirth-shop upgrades bought",
		["offline:<pay|double>"] = "offline payouts / payouts doubled with the product",
		offlineSec = "offline seconds credited",
		offlineCash = "offline cash paid",
		["offlineB:<offlineBucket>"] = "offline payouts by absence length (hours)",
		rename = "stand sign renames applied (after filtering)",
		["renamePlot:<set|reset|admin>"] = "owner R88 plot (entrance sign) names: set = a new name saved (after filtering), reset = the owner went back to the default, admin = cleared by a moderator",
		["teleport:<area>"] = "teleports used, by destination area",
		teleportHub = "teleports to the hub",
		["leaveArea:<area>"] = "sessions by the player's area at leave (where players stop)",
		["plot:<1-8>"] = "plots assigned by plot index",
		-- Owner R89 Surprise Batches + Flavour Book + Big Pop (Server/Tycoon/FlavorService; <flavorId> =
		-- a SPECIAL FlavorConfig id: sprinkle / glitter / rainbow / galaxy / mystery; batched per player
		-- every FlavorConfig.AnalyticsFlushSeconds).
		["flavor:<flavorId>:<world>"] = "flavoured batches rolled on the server, by flavour and the producer's world (aggregate rolls; any producer, clicked or automated)",
		["flavorBonus:<world>"] = "extra world currency paid by flavour multipliers (cash in main, Bones / Moon currency elsewhere)",
		["flavorFind:<flavorId>:<world>"] = "Flavour Book discoveries (first time a player popped that flavour in that world)",
		["flavorClaim:<flavorId>:<world>"] = "Flavour Book discovery rewards claimed",
		flavorGems = "gems paid by Flavour Book rewards",
		["flavorRefused:<rate|bad|save|locked|claimed|none|off>"] = "refused FlavorClaim intents by reason (none = CLAIM ALL with nothing ready, off = feature switched off)",
		flavorTip = "players who dismissed the one-time Lucky Nukes tip card (owner R112)",
		flavorReveal = "Galaxy+ batches revealed to their owner (FlavorHighlight sent; the client may skip / throttle the cinematic)",
		["bigPop:<batch|hatch|rebirth>"] = "Big Pop broadcast entries queued by trigger (Galaxy+ batch, Mythic+ hatch, rebirth; after the per-player cooldown)",
		["flavorAdmin:<settings|grant|reset>"] = "admin flavour commands used (settings = kill switch / odds / Big Pop switch)",
	}),
	-- R57 worlds family (Server/Analytics/WorldRecorders). <world> = a WorldsConfig id; <worldArea>
	-- = an area of THAT world (1..its area count); <worldUpgrade> = a key of THAT world's rebirth
	-- shop; <worldStep> = a step of THAT world's funnel (AnalyticsConfig.Worlds.Funnels).
	worlds = table.freeze({
		["unlock:<world>"] = "worlds unlocked (sticky; once per player per world)",
		["unlockSrc:<world>:<area|rebirth|legacy|admin>"] = "unlocks by what unlocked the world (legacy = already qualified when the update shipped)",
		["popup:<world>:<shown|go|later|lockedPreview>"] = "WORLD UNLOCKED popup funnel (client claims, capped per session): shown, GO NOW, LATER, the locked-portal preview",
		["portalLocked:<world>"] = "locked Time Machine portal uses (throttled per player: AnalyticsConfig.Worlds.PortalLockedCooldown)",
		["travel:<world>:<portal|menu|popup|chip|admin|respawn>"] = "successful travels INTO the world by source (main = trips back to Nuke Town)",
		["travelFail:<world>:<travelReason>"] = "refused travels by destination world and TravelRules reason",
		["travelFail:unknown:<travelReason>"] = "refused travels whose destination was not a known world id",
		["visitor:<world>"] = "unique visitors per UTC day (once per player per world per day, across servers)",
		["firstVisit:<world>"] = "players who entered the world for the first time ever",
		["seconds:<world>"] = "seconds players spent in the world (avg minutes per visitor-day = seconds / 60 / visitor)",
		["step:<world>:<worldStep>"] = "world funnel: players reaching the step (once per player; unlocked → firstTravel → firstPad → manager → area2 … → finale → rebirth)",
		["area:<world>:<worldArea>"] = "world areas reached (all runs)",
		["areaN:<world>:<worldArea>"] = "world areas reached on the world's FIRST run (time-to-area denominator)",
		["areaAt:<world>:<worldArea>"] = "sum of first-run world-play seconds when the area opened (avg = areaAt / areaN; target = that world's Pacing)",
		["areaB:<world>:<worldArea>:<areaBucket>"] = "first-run world area reaches by minutes-into-run bucket (AnalyticsConfig.Tycoon.AreaMinuteBuckets)",
		["padArea:<world>:<worldArea>"] = "world pad purchases by area",
		["rebirth:<world>"] = "rebirths in the world (Dino rebirth)",
		["rebirthN:<world>:<rebirthBucket>"] = "world rebirths by the player's world rebirth count after the rebirth",
		["rebirthShop:<world>:<worldUpgrade>"] = "world rebirth-shop upgrades bought (Dino: the Amber shop)",
		["tokens:<world>"] = "world rebirth tokens granted (Dino: Amber)",
		["offline:<world>:<pay|double>"] = "world offline payouts / payouts doubled with the product",
		["offlineSec:<world>"] = "offline seconds credited to the world",
		["incomeW:<world>:<click|auto|offline>"] = "world currency produced by clicked cycles, automated cycles and offline payouts (income share)",
	}),
	retention = table.freeze({
		["daily:claim:<1-7>"] = "daily reward claims by streak day",
		["daily:reset"] = "streaks reset after a missed day",
		["time:claim:<1-10>"] = "gift ladder claims by gift index (owner R89: 1 / 3 / 5 / 10 / 15 / 25 / 40 / 60 / 90 / 120 online minutes)",
		["time:claimAll:<2-10>"] = "gift ladder CLAIM ALL presses, by the number of gifts opened at once",
		["time:crate:<crate|gems>"] = "the 40-min gift's Supply Crate paid as a held crate, or as its fallback gems (paid random items restricted / policy unknown)",
		["time:admin:<reset|unlock|claim>"] = "owner-admin gift ladder QA commands (GiftLadderReset / GiftLadderStep)",
		-- Owner R89 Pocket Rocket (Server/Retention/PocketRocket; prompts / purchases are in revenue).
		["rocket:grant"] = "Pocket Rocket grants (durable receipts)",
		["rocket:cash"] = "cash paid by Pocket Rockets (sum; average = rocket:cash / rocket:grant)",
		["rocket:late"] = "Pocket Rocket receipts granted although that day's rocket was already used (bought before UTC midnight / retries)",
		["rocket:refused"] = "Pocket Rocket prompts refused because today's rocket already launched",
		-- Owner R89 one-time experience favorite prompt (Server/Retention/FavoritePrompt; never rewarded).
		["favorite:moment:<gift|rebirth>"] = "favorite-prompt happy moments announced to the client (10-minute gift claim / a rebirth)",
		["favorite:<shown|success|denied|failed>"] = "favorite dialogs shown, and their results (success = favorited, denied = dismissed, failed = error)",
		["wheel:spin:<free|bonus|paid>"] = "lucky wheel spins by bank (timer / free reward / Robux)",
		["wheel:refused:<policy|empty>"] = "refused spins: paid spins blocked by PolicyService (region / unknown, fail closed) or no spins left",
		["wheel:receipt:<spins|gems>"] = "Spins product receipts paid as spins, or as gems for a known restricted buyer",
		["pack:spins:<spins|gems>"] = "Starter / Secret Pack spin component paid as spins (policy allows) or as gems (restricted / unknown)",
		["wheel:slice:<sliceId>"] = "wheel results by slice id",
		["code:ok:<codeId>"] = "codes redeemed",
		["code:fail:<invalid|expired|used|limit>"] = "refused code redeems by reason",
		["group:<claim|notMember>"] = "group reward claims / refusals (not in the group)",
		["notify:<shown|accepted|declined|claim>"] = "notification opt-in prompt and reward",
		-- Return notifications (owner R122, Server/Retention/ReturnNotify*; kinds = NotifyConfig.Kinds;
		-- Roblox delivers to opted-in 13+ players, at most one per player per day).
		["rnotify:plan:<cashFull|streak|missions>"] = "return notifications queued when a player left, by kind",
		["rnotify:sent:<cashFull|streak|missions>"] = "return notifications sent through Open Cloud (claimed by exactly one server), by kind",
		["rnotify:result:<ok|throttled|rejected|http|nokey|off|dry>"] = "Open Cloud send results (dry = Studio / no secret: queued + counted, no request)",
		["rnotify:status:<cashFull|streak|missions>:<400|401|403|404|429|4xx|5xx>"] = "send errors by Roblox's HTTP status (400 = notifications off / under 13, 429 = one-per-day cap or rate limit, 401 / 403 = key or scope, 404 = unknown message id)",
		["rnotify:drop:<late|rejoined|replaced>"] = "queued notifications dropped: too late to be useful, the player came back first, replaced by a better one",
		["rnotify:join:<cashFull|streak|missions>"] = "joins that came from a return notification (launch data rn:<kind>)",
		["rnotify:promptAt:<manager|area2|other>"] = "notification opt-in card shown, by the moment that triggered it",
		["welcome:<okay|double>"] = "Welcome Back popup choices",
		-- WHAT'S NEW change notes (owner R58, Server/Services/ChangeNotesService; <noteId> = a
		-- ChangeNotesConfig note id, registered exactly; each key capped per player session).
		["notes:shown:<noteId>:<auto|menu>"] = "What's New panel shown (newest note at open) by source: returning-player auto pop-up or the HUD chip / Settings",
		["notes:<seen|cta|closed>:<noteId>"] = "What's New: note marked seen (server), call-to-action pressed, panel closed by the player",
		["notes:openSec:<noteId>"] = "What's New: summed seconds the panel stayed open (divide by notes:closed for the average)",
		["notes:openLen:<lt5|5to15|15to60|gt60>"] = "What's New closes by seconds open (<5, 5-15, 15-60, 60+)",
		["open:<screen>"] = "screens opened (client claim, capped per session)",
		["openFrom:<screen>:<source>"] = "screens opened by source",
		-- Lucky Buttons (owner R69, Server/Services/LuckyButtonService; kinds = LuckyButtonConfig.KindIds).
		["luckySpawned:<cash|boost2x|speed2x|boost30|pass2x|autoclick|pack|skip>"] = "Lucky Buttons spawned on a player's plot, by kind",
		["luckyClaimed:<cash|boost2x|speed2x|boost30|pass2x|autoclick|pack|skip>"] = "FREE Lucky Buttons claimed (walked into: cash burst / 2 min 2x Cash / 2 min 2x Speed)",
		["luckyPrompted:<cash|boost2x|speed2x|boost30|pass2x|autoclick|pack|skip>"] = 'PAID Lucky Buttons that opened a purchase prompt (source "lucky")',
		["luckyPurchased:<cash|boost2x|speed2x|boost30|pass2x|autoclick|pack|skip>"] = "purchases within 120 s of that player's lucky prompt for the same product / pass",
		["luckyExpired:<cash|boost2x|speed2x|boost30|pass2x|autoclick|pack|skip>"] = "Lucky Buttons that expired unclaimed / unbought",
		["luckyDeal:<shown|buy|close>:<pass2x|autoclick|boost30|pack|skip>"] = "PAID Lucky Button DEAL card (owner R122: walking in shows the card; only BUY opens the Robux prompt): shown / BUY pressed / closed",
		-- Rush boosts (owner R78, Server/Services/RushService; docs/social.md).
		["rush:grant:<rookie|comeback>"] = "Rush boosts granted: Rookie Rush (brand-new profile) / Comeback Rush (away 48 h+)",
		["rush:sec:<rookie|comeback>"] = "Rush seconds actually played with the 2x (per session; avg minutes = sec / 60 / grant)",
		["rush:done:<rookie|comeback>"] = "Rush boosts that ran out while the player was playing (rookie = all 15 online minutes used)",
		["rush:awayDays:<2-31>"] = "Comeback Rush grants by whole days away (31 = 31 or more)",
		-- Quests (owner R78, Server/Services/QuestService; stats = QuestConfig.MissionStats, trophies =
		-- QuestConfig.TrophyIds; tests/quest-logic.luau checks every key QuestConfig.Keys builds).
		-- `order` is RETIRED (owner R128, 0.8.1: the Order Window mission was removed); it stays in the
		-- stat choices only so old days' keys still render — no new key ever uses it.
		["quest:goalDone:<1-12>"] = "Quests starter goals completed (the chain reached the goal), by goal number",
		["quest:goalClaim:<1-12>"] = "Quests starter goal rewards claimed, by goal number",
		["quest:dailyPick:<click|pad|upgrade|hatch|spin|gift|playMinute|lucky|turkey|flavor|lever|tipjar|order>"] = "daily missions handed out (3 per player per UTC day, + the rerolled-in one), by stat",
		["quest:dailyDone:<click|pad|upgrade|hatch|spin|gift|playMinute|lucky|turkey|flavor|lever|tipjar|order>"] = "daily missions finished, by stat",
		["quest:dailyClaim:<click|pad|upgrade|hatch|spin|gift|playMinute|lucky|turkey|flavor|lever|tipjar|order>"] = "daily mission rewards claimed (or carried over at the day roll), by stat",
		["quest:chest"] = "Daily Chests claimed (all three missions finished)",
		["quest:reroll:<click|pad|upgrade|hatch|spin|gift|playMinute|lucky|turkey|flavor|lever|tipjar|order>"] = "daily mission free rerolls, by the stat swapped away",
		["quest:trophy:<clicker|builder|upgrader|hatcher|collector|explorer|reborn|loyal|traveller>:<1-5>"] = "trophy tiers claimed, by trophy and tier",
		-- Nuke Pass (owner R78, Server/Services/PassService; <seasonId> = a PassConfig season id).
		["pass:xp:<starter|daily|chest|trophy|play|admin|other>"] = "Nuke Pass XP added by source (amount = XP; play = 10 per 5 online min, capped per UTC day)",
		["pass:tier:<1-30>"] = "Nuke Pass tiers reached (one count per player per tier per season)",
		["pass:claims:<free|premium|overflow>"] = "Nuke Pass rewards claimed by track (amount = rewards; overflow = bonus chests after tier 30)",
		["pass:claim:<free|premium>:<1-30>"] = "Nuke Pass rewards claimed by track and tier",
		["pass:claimAll"] = "CLAIM ALL presses that paid at least one reward",
		["pass:auto:<free|premium|overflow>"] = "rewards auto-granted when a season ended unclaimed (amount = rewards)",
		["pass:premium:<granted|grace|fallback|admin>"] = "premium receipts: unlocked the active season / the season that just ended (grace) / paid fallback gems (no season or already owned); admin toggles",
		["pass:premiumTier:<0-30>"] = "premium purchases by the tier the buyer had reached (late buyers unlock every reached tier)",
		["pass:policyGems"] = "premium spins / eggs paid as gems (paid random items restricted or unknown)",
		["pass:season:<seasonId>"] = "players who started a season's pass (first XP / join in the season)",
		["pass:refused:<wait|recheck>"] = "claim taps refused while a season-end settle waits for the region policy (the player gets a 'try again' toast)",
	}),
	pets = table.freeze({
		["hatch:<eggId>"] = "eggs hatched (pets rolled) per egg",
		["hatchN:<eggId>:<1|3>"] = "hatch requests by count (single / triple)",
		["hatchAuto"] = "hatches started by auto-hatch",
		["rarity:<rarity>"] = "hatched pets by rarity",
		["eggRarity:<eggId>:<rarity>"] = "hatched pets by egg and rarity",
		["pet:<petId>"] = "hatched pets by pet id",
		["equip"] = "pets equipped",
		["equipBest"] = "Equip Best presses",
		["delete"] = "pets deleted",
		["owned:<ownedBucket>"] = "sessions by pets owned at leave (0, 1-2, 3-9, 10-24, 25-49, 50-99, 100+)",
		["equipped:<0-12>"] = "sessions by pets equipped at leave",
		["refused:<cash|gems|slots|rate|locked|policy|other>"] = "refused hatches by reason (policy = paid random items restricted / unknown)",
		-- Pet Index milestone rewards (owner R78, PetService; ids = PetIndexConfig milestone ids).
		["index:claim:<5|10|20|30|45|60|all>"] = "Pet Index milestones claimed (gems + permanent Index Bonus)",
		["index:refused:<claimed|locked|rate|bad|save|other>"] = "refused Pet Index claims by reason (already claimed / not enough pets / rate limit / bad milestone / save not writable / reward system missing)",
		["index:gems"] = "gems paid by Pet Index milestone claims",
	}),
	crates = table.freeze({
		["open:<crateId>"] = "crates opened",
		["openPay:<crateId>:<gems|robux|free>"] = "crates opened by payment",
		["reward:<crateId>:<rewardKind>"] = "crate rewards by kind (boost / gems / egg / pet / trail / cash)",
		["rarity:<rarity>"] = "crate rewards by rarity",
		["boost:<boostKey>"] = "timed boosts activated",
		["boostSec:<boostKey>"] = "boost seconds granted",
		["refused:<gems|policy|rate|busy|other>"] = "refused crate opens by reason (policy = paid random items restricted / unknown)",
	}),
	attack = table.freeze({
		["console"] = "Attack Consoles unlocked",
		["launch:<normal|revenge|barrage|golden>"] = "nukes launched by kind (amount = nukes in the launch; golden = owner R85 paid revenge nuke)",
		["golden:<buy|auto|stored>"] = "owner R85 golden revenge nukes: receipts granted / fired at the attacker at once / stored for the picker",
		intercept = "nukes intercepted by AA towers",
		hit = "nukes that hit (target loses nothing; attacker paid minted cash)",
		hitCash = "minted cash paid for hits",
		["refused:<cooldown|protected|shield|target|rate|locked|other>"] = "refused launches by reason",
		["shield:<free|product>"] = "shields activated",
		["aa:<aaKind>:<1-50>"] = "AA tower upgrades by kind and new level",
		["targets:<0-8>"] = "ACCEPTED launch requests by the number of targetable players at that moment (attacker excluded; recorded server-side)",
		["rival:<1-8>"] = "nukes launched at Rival Factory NPC targets by rival (1 Toy Factory, 2 Grumpy Gus, 3 Professor Fizz, 4 Mega Meltdown; amount = nukes)",
		-- Defence towers (owner R80, Server/Services/DefenseService; recorded for the DEFENDING player).
		["tower:buy:<1-8>"] = "defence tower slots bought, by slot (1 Middle, 2 Gate, 3 Silo Yard, 4 Back Lot)",
		["tower:up:<1-8>:<2-5>"] = "defence tower upgrades by slot and new level",
		["tower:src:<walk|remote>"] = "defence tower buys by input (walk = stepped on the blue pad; remote = Defense window / billboard / E / X / touch button)",
		["tower:refused:<cash|locked|level|max|rate|off|other>"] = "refused defence tower buys / upgrades by reason (level = stale or repeated intent, off = admin kill switch)",
		["tower:warned"] = "players told they can be nuked while owning no AA tower (once per session)",
		["tower:admin"] = "defence tower levels set by an owner admin (QA)",
		["interceptBy:<0-9>"] = "nukes intercepted, by the tower that hit (0 = the Area 7 AA Tower pad's HQ tower, 1.. = defence slot)",
		["defTowers:<0-9>"] = "real nukes fired at players, by how many AA towers defended them (0 = defenceless)",
		-- Target picker streaming (owner R104, Server/Attack/PickerFocus).
		["view:<player|rival>"] = "target picker views streamed in by a server replication focus, by target kind (each newly framed target)",
		["view:refused:<slot|rate>"] = "refused AttackPickerFocus intents (slot = junk / unknown slot, rate = over the per-player limit)",
		-- Area knockdown (owner R50, Server/Tycoon/Knockdown; recorded for the KNOCKED player).
		["knock:<1-10>"] = "areas knocked down, by area index (temporary: production pauses, then it rebuilds)",
		["knockSrc:<normal|revenge|barrage|admin|test|rival|other>"] = "knockdowns by source (rival = Rival Factory sections, server-wide)",
		["knockBlocked:<immune|shielded|not_built|disabled>"] = "knockdowns refused by reason (immune = 180 s anti-grief window or already down)",
		knockTap = "accepted TAP TO REBUILD presses (amount = taps; recorded when the area comes back up)",
		knockSec = "seconds areas spent knocked down (amount; recorded when the area comes back up)",
		["knockEnd:<timer|admin|reset>"] = "knockdowns ended by reason (timer incl. taps, admin force-rebuild, reset = rebirth / plot reset)",
	}),
	event = table.freeze({
		["turkey:<spawn|collect|lure>"] = "Golden Turkeys spawned / collected / lured",
		acorns = "acorns granted",
		["sticker:<1-20>"] = "stickers found by number",
		["stickerDup"] = "duplicate sticker rolls",
		["sheet:redeem"] = "completed sticker sheets redeemed (Gobble Bomb pet)",
		["egg:<eggId>"] = "event eggs hatched",
		["decor:<decorId>"] = "event decorations bought",
		["shop:<eventItemId>"] = "event shop boosts bought with acorns (ids registered by EventService as kind eventItemId)",
		["lure:refused:policy"] = "Turkey Lure prompts refused: paid random items restricted in the player's region",
		["lure:fixed"] = "lured turkeys caught by a restricted / unknown-policy player (fixed acorns, no sticker roll)",
		-- Owner R97 free starter stickers (EventService.grantStarters; amount = stickers granted).
		["starter:<new|topup|reset>"] = "free starter Feast Stickers: new = an empty sheet got them, topup = a sheet with 1-2 stickers was topped up to 3 (amount = stickers granted); reset = owner admin cleared the flag (QA)",
		-- R89 Nukey's Happy Hours (Server/Services/HappyHourService). The id choice = HappyHourConfig.EventIds
		-- (tests/happy-hours.luau fails when an event is added there but not here).
		["hh:start:<confetti|sprinkle|doublePops|stampede|lowGravity>"] = "Happy Hour event instances that started on a server (server-level, once per instance)",
		["hh:seen:<confetti|sprinkle|doublePops|stampede|lowGravity>"] = "players present when a Happy Hour started or arriving during it (once per player per instance)",
		["hh:spawn:<confetti|sprinkle|doublePops|stampede|lowGravity>"] = "Happy Hour pickups spawned (Confetti Storm coins / Egg Stampede eggs / Low-Gravity moon rocks)",
		["hh:pickup:<confetti|sprinkle|doublePops|stampede|lowGravity>"] = "Happy Hour pickups collected",
		["hh:golden:<confetti|sprinkle|doublePops|stampede|lowGravity>"] = "golden Happy Hour pickups collected (pay gems on top of cash)",
		["hh:gems"] = "gems granted by golden Happy Hour pickups",
		["hh:admin:<force|stop|skip|on|off>"] = "owner Happy Hour overrides (force / stop / skip / kill switch on-off; reach every server)",
	}),
	social = table.freeze({
		["players:<0-8>"] = "server minutes at each player count (sampled once per health window)",
		["plots:<0-8>"] = "server minutes at each number of owned plots",
		["friendsIn:<friendBucket>"] = "joins by friends already in the server (0, 1, 2, 3+)",
		["visit"] = "visits to another player's plot",
		["joinFollow"] = "joins by following a friend",
		-- Friend Boost + invites + referrals (owner R78, Server/Services/FriendService; docs/social.md).
		["friends:boost:<0-5>"] = "joins by Friend Boost size: Roblox friends found in the server (5 = 5+, the +50 % cap)",
		["friends:pair"] = "friend pairs found in a server (each pair once per server life)",
		["friends:checkFail"] = "IsFriendsWithAsync pairs that failed every retry (counted as not friends)",
		["friends:invite:<prompted|sent|closed|unavailable|failed>"] = "INVITE FRIENDS funnel (client report, rate-limited): prompt opened, invites sent, closed without sending, invites unavailable, prompt error",
		["friends:inviteTo"] = "friends invited (amount = recipients of the sent prompts)",
		-- Co-play surfacing (owner R122, HUD INVITE button + one invite moment per session).
		["friends:hud:<shown|tap>"] = "HUD INVITE button shown (once per session) / tapped",
		["friends:moment:<shown|invite|later>"] = "invite moment card (after area 2 unlocks, once per session): shown / INVITE / later",
		["friends:ref:<new|paid|queued|duplicate|full|capped|seen|self|notNew|queueFail|delivered>"] = "referrals: newcomer rewarded, inviter paid, queued for an offline inviter (duplicate / full refused), inviter at the 10 cap, already paid, self / existing-profile refusals, queue write failed, queued rewards delivered (amount)",
	}),
	-- Owner R90 Mega Lever + Tip Jar (Server/Kinetic; docs/kinetic.md). <world> = a WorldsConfig id;
	-- amounts are that world's currency (cash in main, Bones / Moon currency elsewhere).
	kinetic = table.freeze({
		["reveal:<world>"] = "Mega Lever + Tip Jar built in on a plot with the fly-in (the world's plot reached KineticConfig.UnlockArea this session)",
		["pull:<world>"] = "Mega Lever pulls (each paid a Mega Pull: one bonus cycle per built machine)",
		["pullPaid:<world>"] = "world currency paid by Mega Pulls, flavour bonuses included (amount)",
		["pullCycles:<world>"] = "bonus cycles run by Mega Pulls (amount = built producers that completed one)",
		["pullFlavor:<flavorId>"] = "Mega Pull bonus cycles that rolled a special flavour (FlavorService.batch)",
		["pullRefused:<cooldown|reach|locked|off|noProducers|notReady|rate>"] = "refused Mega Lever pulls by reason (locked = no lever on that plot yet; notReady = run / plot still loading)",
		["jar:<world>"] = "Tip Jar payouts",
		["jarTouch:<world>"] = "Tip Jar payouts triggered by walking into it (the rest used the Interact prompt)",
		["jarPaid:<world>"] = "world currency paid out by Tip Jars, bonus tips included (amount; Order Window tips until owner R128 removed it)",
		["jarFull:<world>"] = "times a Tip Jar reached its passive cap (it stops filling until emptied)",
		["jarRefused:<empty|reach|locked|off|noIncome|rate>"] = "refused Tip Jar payouts by reason (empty = below the minimum fill with no tips)",
		["tip:<world>"] = "bonus tips dropped into a Tip Jar (TipJar.addCoins; the Order Window's big tips until owner R128 removed it — no caller today)",
		["tipPaid:<world>"] = "world currency accepted into Tip Jars from bonus tips (amount)",
		["tipRefused:<bad|locked|full|noIncome>"] = "bonus tips the jar refused (the caller pays them directly)",
		["admin:<switch|lever|fill|status>"] = "owner admin Kinetic commands used",
	}),
	-- RETIRED (owner R128 "bro honestly just remove the orders system entirely", 0.8.1): the R90
	-- Order Window was removed and nothing records these any more. The definitions stay so the
	-- admin report still labels the counters stored on old days. <world> = a WorldsConfig id; tip
	-- amounts were that world's currency.
	orders = table.freeze({
		["unlock:<world>"] = "Order Windows built in with the fly-in (the world's first producer area was owned after the tutorial, this session)",
		["spawn:<world>"] = "customers that walked up to a player's Order Window",
		["served:<world>"] = "customer orders completed (every nuke handed over)",
		["stars:<1-3>"] = "completed orders by stars earned (speed: share of the patience used)",
		["flavor:<sprinkle|glitter|rainbow>"] = "completed orders that asked for a special flavour (bigger tip)",
		["expired:<world>"] = "customers whose patience ran out (they waved and left; no penalty)",
		["pickup:<world>"] = "nukes picked up from producer output trays",
		["handed:<world>"] = "nukes handed over at the window (amount; partial deliveries included)",
		["tip:<world>"] = "world currency paid as tips directly (amount)",
		["tipSeconds"] = "tip seconds of income granted (amount; avg per order = tipSeconds / served)",
		["jar:<world>"] = "world currency of big tips that went into the owner's Tip Jar instead (amount)",
		["fameClaim:<1-11>"] = "Customer Fame milestones claimed, by milestone index",
		fameGems = "gems paid by Customer Fame milestones (amount)",
		["auto:<world>"] = "customers served by the window area's manager by itself (owner R115: Cashier Bot / Rocky Raptor / Bleep Bot; no Fame stars)",
		["autoTip:<world>"] = "world currency paid by auto-served orders (amount; Auto.TipShare of a 1-star tip)",
		tipCard = 'the one-time "how orders work" tip card dismissed (owner R114; once per player)',
		["refused:<rate|off|state|bad|reach|full|none|enough|knocked|empty|locked|claimed|save>"] = "refused Order Window intents by reason (none = no customer waiting, enough = carrying all the nukes the queue wants, empty = hand-over with nothing carried)",
		["admin:<toggle|spawn|clear|status|reset>"] = "owner admin Order Window commands used",
	}),
	health = table.freeze({
		["win|sec"] = "server health windows recorded and their seconds",
		["ft:<bucket>|ftSum"] = "server frames per frame-time bucket (ms) and their summed ms",
		["hb:<bucket>|hbSum|hbN"] = "Stats.HeartbeatTimeMs samples per bucket, their sum and count",
		["physSum"] = "Stats.PhysicsStepTimeMs sum over hbN samples",
		["sendSum|recvSum"] = "server DataSendKbps / DataReceiveKbps sums over hbN samples",
		["mem:<bucket>|memSum"] = "server memory samples per bucket (MB) and their sum",
		["ping:<bucket>|pingSum|pingN"] = "player ping samples per bucket (ms), sum and count",
		["plrSum"] = "connected players summed over hbN samples",
		laggy = "windows whose p95 frame time exceeded LaggyFrameMs",
		["sys:<system>"] = "Luau milliseconds per server system (ServerHealth.addTime)",
		["rx:<remote>:n|kb"] = "server→client remote fires and kilobytes per remote",
		["cp:<Class>:*"] = "client performance by device class (Shared/Analytics/ClientPerfLogic counters)",
		["perfW:<world>:*"] = "client performance by the world the player was in (server-known Player attribute CurrentWorld): reports, seconds, frames, ft:<bucket>, sampled, memMb, pingMs, instN, inst",
	}),
} :: { [string]: { [string]: string } })

--[[
	Side effects of a recorder key's FIRST part (the part before the first ":"), per family:
		unique   counts core "uniq:<surface>" once per player per UTC day
		firstDay marks the first-day milestone (core "cohort:<milestone>", D1/D7 by outcome)
	Example: pets "hatch:<eggId>" → uniq:hatch once a day and cohort:hatch on day one.
]]
AnalyticsConfig.KeyHooks = table.freeze({
	retention = table.freeze({
		daily = table.freeze({ unique = "daily", firstDay = "daily" }),
		time = table.freeze({ unique = "time" }),
		wheel = table.freeze({ unique = "wheel", firstDay = "wheel" }),
		code = table.freeze({ unique = "codes" }),
		group = table.freeze({ unique = "group" }),
	}),
	pets = table.freeze({
		hatch = table.freeze({ unique = "hatch", firstDay = "hatch" }),
	}),
	crates = table.freeze({
		open = table.freeze({ unique = "crate", firstDay = "crate" }),
	}),
	attack = table.freeze({
		launch = table.freeze({ unique = "attack", firstDay = "attack" }),
	}),
	event = table.freeze({
		turkey = table.freeze({ unique = "event", firstDay = "event" }),
		sticker = table.freeze({ unique = "event", firstDay = "event" }),
	}),
} :: { [string]: { [string]: { unique: string?, firstDay: string? } } })

-- Headline definitions (panel tooltips and the AI report).
AnalyticsConfig.HeadlineDefinitions = table.freeze({
	dau = "Average daily active users over the range (unique players per UTC day)",
	peakDau = "Highest single-day DAU in the range",
	sessions = "Sessions that ended in the range",
	avgSessionMinutes = "sessionSeconds / sessions, in minutes",
	newPlayers = "Players whose first day falls in the range",
	retention = "DN = players back exactly N days after their first day, on days inside the range, "
		.. "divided by the new players of the matching cohort days. Windows including today are provisional; n/a means no matching cohort.",
	robux = "Gross Robux estimate: developer-product receipt amounts plus game-pass list-price estimates; not net earnings",
	payers = "Paying users: unique payers per day, summed over the range (payer-days)",
	newPayers = "Players who made their first ever Robux purchase in the range",
	arpdau = "Robux per daily active user (robux / player-days)",
	arppu = "Robux per paying user-day (robux / payers)",
	conversion = "Paying user-days / active user-days (payers / sum of DAU)",
	tutorialCompletion = "ftue:manager / ftue:joined (new players who automated their first producer)",
	area2Rate = "ftue:area2 / ftue:joined (new players who opened the second area)",
	padsBought = "Pad purchases in the range (all runs)",
	rebirths = "Rebirths in the range",
	medianSession = "Median session length (from the len:<bucket> histogram, bucket midpoint)",
} :: { [string]: string })

return table.freeze(AnalyticsConfig)
