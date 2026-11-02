--!strict
--[[
	ChangeNotesConfig — the WHAT'S NEW change notes. A port of RoBeasts' ChangeNotesConfig (owner
	R58, 2026-10-30: "add the changelog system that we have in the Robeast project. That way it can
	all be like hooked up together"): the SAME note schema, the same rules, the same authoring
	workflow (docs/change-notes.md), so release notes for both games are written one way. Only the
	game-specific vocabulary differs (icons, CTA screens, Shop tabs, the "no context" rule).

	What lives here:
		- NOTES (`Notes`): an ORDERED, APPEND-ONLY list, oldest first. A note's `Id` is SAVE DATA
		  (profile.notes.seen holds the newest id a player has seen), so ids are never renamed,
		  reordered or removed. The newest note is the last entry.
		- The note shape (`Note`, identical to RoBeasts): Id ("YYYY-MM-DD-slug", the date part =
		  the note's UTC `Date`), Version (the semver "X.Y.Z" of the update, VersionConfig policy;
		  a pill on the card), Date (unix seconds, strictly ascending), Title, Tagline, Hero (a live
		  3D pet, a big kit icon, or — SellNukes addition — an uploaded image), up to 3 Sections of
		  short one-line items (icon + text + tag pill) and an optional Cta that deep-links to an
		  existing screen (Shop section, Pets, Lucky Wheel, ...), plus the optional ShowFrom reveal.
		- Every text cap, the allowed tags / icons / CTA screens / Shop tabs, the remote's verbs and
		  sources, the server's rate limit, the client's auto-open pacing and the purchase-flow hint.
		- The saved record `profile.notes` (`State`) with its default (`newState`) and repair
		  (`reconcileState`).
		- `validate()`: every rule above at once (unique ids, id format + date match, ascending
		  dates, versions (format, never going down, VersionConfig.Current ≥ the newest note's with
		  the same MAJOR.MINOR), caps, valid tags / icons / pets / images / screens, ShowFrom).
		  tests/change-notes.luau runs it on every ./scripts/check.sh; Server/Tests/CoreTests runs it
		  in the engine too.

	Writing a note (docs/change-notes.md): append a table to NOTES, keep it SHORT (≤ 3 sections,
	≤ 6 items per section, one line each) and TRUE (every number checked against config), player
	wording only (no internal names, no analytics, no admin features), kid-friendly, then run
	./scripts/check.sh. Versions (docs/change-notes.md "Versioning", Shared/Config/VersionConfig):
	a feature update bumps MINOR in VersionConfig.Current and appends a note with that Version; a
	fix / tuning update bumps PATCH and appends items to the newest note (its Version stays).

	Rules (Shared/Util/ChangeNotesLogic, used by the server and the client):
		- brand-new players (a fresh profile) and players who have not finished the tutorial yet
		  have no context for "what changed": the server marks the newest note seen on load, so they
		  never get the pop-up (RoBeasts' equivalent rule is "no finished match");
		- returning players with an unseen note get it auto-opened ONCE per join at a polite moment
		  (after the loading screen, no window / cinematic / purchase prompt up; client
		  ChangeNotes/ChangeNotesClient); closing it marks it seen (server);
		- the HUD's bottom-right WHAT'S NEW chip (with a NEW dot while a note is unseen) and
		  Settings → WHAT'S NEW always open the panel (every visible note, newest first).

	ShowFrom (RoBeasts W3.1, so an update can be PUBLISHED early and REVEALED on time):
		A note may carry `ShowFrom` (unix seconds). Until then it does not exist for players: not
		counted as unseen, never auto-opened, not listed, cannot be marked seen or reported (the
		server refuses it), and the version label keeps the newest VISIBLE note's version
		(`menuText` / `displayVersion`). Visibility is always a PREFIX of the list (validate:
		ShowFrom ≥ the note's Date, and once a note has a ShowFrom every later note has one that is
		not earlier), so `visibleCount(now)` is "the first N notes". The client and the server each
		arm ONE task.delay to the next ShowFrom. While a note is hidden the label reads
		`VisibleVersion` when set (see docs/change-notes.md "Patches while a note is hidden").
		The admin preview (ChangeNotesAdmin) shows hidden notes too, labelled with their reveal.

	SellNukes-only rule: a note id is at most `AnalyticsIdLength` (32) characters, because it is a
	part of the analytics keys (AnalyticsConfig.MaxKeyPart). validate() checks it.

	Connects to: PetConfig (hero pet ids), VersionConfig (Note.Version rules, Current),
	Shared/Util/ChangeNotesLogic, Server/Economy/ProfileLogic (profile.notes),
	Server/Services/ChangeNotesService (remote + analytics + admin), Client/ChangeNotes/
	ChangeNotesClient, Client/UI/Screens/WhatsNew, Client/UI/Hud/HudWhatsNew, Screens/Settings.

	Example:
		local newest = ChangeNotesConfig.newest() :: ChangeNotesConfig.Note
		print(newest.Title)                                   --> "WHAT'S NEW IS HERE!"
		print(ChangeNotesConfig.indexOf(newest.Id))           --> 3
		assert(#ChangeNotesConfig.validate() == 0)
]]

local PetConfig = require(script.Parent.PetConfig)
local VersionConfig = require(script.Parent.VersionConfig)

export type Tag = "NEW" | "IMPROVED" | "FIXED" | "LIMITED"
-- Item / hero icons (SellNukes vocabulary): drawn from the kit's IconAssets by Screens/WhatsNew.
export type Icon =
	"nuke"
	| "cash"
	| "gem"
	| "star"
	| "gift"
	| "clock"
	| "pet"
	| "egg"
	| "rocket"
	| "turkey"
	| "trophy"
	| "check"
-- Screens a note's CTA may open (registered ScreenManager names; Screens/WhatsNew opens them).
export type CtaScreen =
	"Shop"
	| "Pets"
	| "LuckyWheel"
	| "DailyRewards"
	| "TimeRewards"
	| "Codes"
	| "Rebirth"
	| "Teleport"
	| "CrateShop"
	| "HarvestFeast"
	| "Attack"
	| "GroupRewards"
	| "Settings"
	| "Quests"

export type Item = {
	Text: string, -- one short line (≤ Limits.MaxItemText characters)
	Icon: Icon?, -- defaults to the tag's icon in the UI
	Tag: Tag?, -- the pill on the right (NEW / IMPROVED / FIXED / LIMITED)
}
export type Section = {
	Heading: string, -- e.g. "NEW", "IMPROVED", "FIXED" (≤ Limits.MaxHeading)
	Items: { Item },
}
--[[
	The header art: a live 3D pet (PetConfig id), a big kit icon, or (SellNukes addition, owner
	R58 "optional image") an uploaded image "rbxassetid://<id>" — a note that uses Kind "Image"
	is the one shape RoBeasts does not know yet (docs/change-notes.md "Shared schema").
]]
export type Hero = {
	Kind: "Pet" | "Icon" | "Image",
	PetId: string?, -- Kind "Pet": a PetConfig pet id
	Icon: Icon?, -- Kind "Icon"
	Image: string?, -- Kind "Image": "rbxassetid://<digits>"
	Color: Color3?, -- the glow ring / icon disc colour (defaults to the pet's rarity colour or yellow)
}
export type Cta = {
	Label: string, -- button text (≤ Limits.MaxCtaLabel), e.g. "OPEN THE SHOP"
	Screen: CtaScreen,
	Tab: string?, -- Screen "Shop" only: a Shop section id (ShopTabs)
}
export type Note = {
	Id: string, -- "YYYY-MM-DD-slug" (save data: never rename / reorder / remove)
	-- Semver "X.Y.Z" of the update this note ships with (VersionConfig policy: a MINOR bump adds a
	-- note; PATCH bumps append items to the newest note and leave its Version alone).
	Version: string,
	Date: number, -- unix seconds; the id's date part is this instant's UTC day
	Title: string,
	Tagline: string,
	Hero: Hero,
	Sections: { Section },
	Cta: Cta?,
	-- Optional reveal time (unix seconds, see the module header "ShowFrom"). Must be ≥ Date, and
	-- never earlier than the ShowFrom of the note before it; every note after one with a ShowFrom
	-- needs one too.
	ShowFrom: number?,
}

-- profile.notes: the newest note id this player has seen ("" = none) and when it was marked (unix
-- seconds, 0 = never). Unknown but well-formed ids are KEPT (a newer server may know a newer note;
-- ChangeNotesLogic treats them as "all seen").
export type State = { seen: string, at: number }

-- The remote's verbs (C→S ChangeNotesAction(verb, noteId, arg?)) and the shown sources.
export type Action = "seen" | "shown" | "cta" | "closed"
export type Source = "auto" | "menu"

local ChangeNotesConfig = {}

-- The UI screen (UI/Screens/WhatsNew `name`).
ChangeNotesConfig.Screen = "WhatsNew"

-- Text caps (characters, utf8.len) and list caps — the same numbers as RoBeasts, so a note
-- written for one game fits the other. Short on purpose: readable at a glance on a phone.
ChangeNotesConfig.Limits = table.freeze({
	MaxIdLength = 48,
	MaxTitle = 40,
	MaxTagline = 90,
	MaxHeading = 20,
	MaxItemText = 72,
	MaxCtaLabel = 18,
	MaxSections = 3,
	MaxItemsPerSection = 6,
})
-- SellNukes: a note id is one part of an analytics key (AnalyticsConfig.MaxKeyPart = 32).
ChangeNotesConfig.AnalyticsIdLength = 32

ChangeNotesConfig.Tags = table.freeze({ "NEW", "IMPROVED", "FIXED", "LIMITED" } :: { Tag })
ChangeNotesConfig.Icons = table.freeze({
	"nuke",
	"cash",
	"gem",
	"star",
	"gift",
	"clock",
	"pet",
	"egg",
	"rocket",
	"turkey",
	"trophy",
	"check",
} :: { Icon })
ChangeNotesConfig.CtaScreens = table.freeze({
	"Shop",
	"Pets",
	"LuckyWheel",
	"DailyRewards",
	"TimeRewards",
	"Codes",
	"Rebirth",
	"Teleport",
	"CrateShop",
	"HarvestFeast",
	"Attack",
	"GroupRewards",
	"Settings",
	"Quests", -- R78 Quests screen (missions, trophies, Nuke Pass banner)
} :: { CtaScreen })
-- The Shop section ids a CTA may name (mirrors Shared/Config/ShopConfig.Sections ids;
-- tests/change-notes.luau checks they still agree). The Shop opens with { section = Tab }.
ChangeNotesConfig.ShopTabs = table.freeze({ "limited", "passes", "cash", "gems", "spins", "boosts" })
ChangeNotesConfig.Actions = table.freeze({ "seen", "shown", "cta", "closed" } :: { Action })
ChangeNotesConfig.Sources = table.freeze({ "auto", "menu" } :: { Source })

--[[
	Server (Server/Services/ChangeNotesService): per-player token bucket for ChangeNotesAction, the
	per-session cap of analytics reports per (verb, note, source) key (a looping client can never
	inflate the report), and the clamp on the client-measured "time open" of a "closed" report.
]]
ChangeNotesConfig.Server = table.freeze({
	ActionBurst = 8,
	ActionPerSecond = 1,
	MaxReportsPerKey = 4,
	MaxOpenSeconds = 600,
})

--[[
	"Time open" buckets for the analytics histogram (retention "notes:openLen:<label>"): upper
	bounds in seconds; the last label is open-ended.
]]
ChangeNotesConfig.OpenBuckets = table.freeze({ 5, 15, 60 })
ChangeNotesConfig.OpenBucketLabels = table.freeze({ "lt5", "5to15", "15to60", "gt60" })

--[[
	Client auto-open pacing (ChangeNotes/ChangeNotesClient):
		FirstCheckDelay  seconds after the profile + loading screen are ready before the first
		                 check (the Welcome Back window and the plot reveal open first)
		CheckSeconds     how often a polite moment is re-checked (plus instantly on a window close)
		PoliteChecks     consecutive polite checks needed
		WaitSeconds      how long (loading-screen time excluded) the auto-open waits for a polite
		                 moment before giving up for this session (the HUD chip's NEW dot stays on)
		RevealLagSeconds the client treats a ShowFrom note as visible this many seconds AFTER the
		                 server does (its clock is Workspace:GetServerTimeNow(), which can run a
		                 little ahead), so a "seen" sent at the reveal is never refused as hidden
]]
ChangeNotesConfig.Auto = table.freeze({
	FirstCheckDelay = 2.5,
	CheckSeconds = 1,
	PoliteChecks = 2,
	WaitSeconds = 180,
	RevealLagSeconds = 2,
})

--[[
	Purchase-flow hint: the server sets this replicated Player attribute (unix seconds) when the
	player asks for a Roblox purchase prompt (PromptProduct / PromptPass) and clears it when Roblox
	reports the prompt finished, or after HoldSeconds. The change note never auto-opens while it is
	set. UI-only: nothing is granted or refused by it.
]]
ChangeNotesConfig.PurchaseFlow = table.freeze({
	Attr = "PurchaseFlowAt",
	HoldSeconds = 60,
})

local DAY = 86400

-- Unix seconds of a UTC calendar date (days-from-civil, proleptic Gregorian; no os.date needed,
-- so Lune and Studio agree). Example: unixDate(2026, 10, 31) --> 1793404800
local function unixDate(year: number, month: number, day: number): number
	local y = if month <= 2 then year - 1 else year
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (month + 9) % 12
	local doy = (153 * mp + 2) // 5 + day - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return (era * 146097 + doe - 719468) * DAY
end
ChangeNotesConfig.unixDate = unixDate

--[[
	The notes, OLDEST FIRST, APPEND ONLY (see the module header). Every claim is checked against
	config by tests/change-notes.luau ("truth" checks: area count, pet roster, plot count), so a
	later change that makes a note untrue fails the check.
]]
local NOTES: { Note } = {
	{
		Id = "2026-10-30-sellnukes-born",
		Version = "0.1.0",
		Date = unixDate(2026, 10, 30), -- 2026-10-30T00:00:00Z
		Title = "SELLNUKES IS BORN!",
		Tagline = "Welcome to the garage! Build cartoon nukes, sell them and grow your business.",
		Hero = { Kind = "Icon", Icon = "nuke" },
		Sections = {
			{
				Heading = "WHAT'S HERE",
				Items = {
					{
						Text = "Your progress saves automatically, every few minutes and when you leave.",
						Tag = "NEW",
						Icon = "check",
					},
					{ Text = "Cash and gems update live as you earn them.", Tag = "NEW", Icon = "cash" },
					{ Text = "Big numbers read easily: 1.25K, 448B, 6.29Sx and beyond!", Tag = "NEW", Icon = "star" },
				},
			},
		},
	},
	{
		-- 0.2.0: the whole tycoon + every side system (owner requests R1–R37, 2026-10-30).
		Id = "2026-10-30-nuke-empire",
		Version = "0.2.0",
		Date = unixDate(2026, 10, 30) + 12 * 3600, -- 2026-10-30T12:00:00Z (after note 1's 00:00Z)
		Title = "BUILD YOUR NUKE EMPIRE!",
		Tagline = "Ten areas from a garage to a Mega Nuclear Facility, plus pets, events and more!",
		Hero = { Kind = "Icon", Icon = "rocket" },
		Sections = {
			{
				Heading = "TYCOON",
				Items = {
					{
						Text = "10 areas: Garage Lab to the Mega Nuclear Facility, then Rebirth!",
						Tag = "NEW",
						Icon = "nuke",
					},
					{
						Text = "Step on a pad and watch your purchase build itself in front of you.",
						Tag = "NEW",
						Icon = "star",
					},
					{
						Text = "Hire managers who walk, work and wave while they earn for you.",
						Tag = "NEW",
						Icon = "cash",
					},
					{
						Text = "Earn cash while you're offline, then double it when you're back.",
						Tag = "NEW",
						Icon = "clock",
					},
					{
						Text = "Spawn in the lobby and get a random plot, 8 players per server.",
						Tag = "NEW",
						Icon = "check",
					},
					{ Text = "Faster running with a whoosh of wind!", Tag = "IMPROVED", Icon = "rocket" },
				},
			},
			{
				Heading = "REWARDS + PETS",
				Items = {
					{
						Text = "Daily rewards, playtime gifts, the Lucky Wheel, codes and a shop.",
						Tag = "NEW",
						Icon = "gift",
					},
					{
						Text = "Hatch 29 cute radioactive pets from eggs; open supply crates.",
						Tag = "NEW",
						Icon = "pet",
					},
					{
						Text = "Send toy nukes to friends for bonus cash; build AA towers!",
						Tag = "NEW",
						Icon = "rocket",
					},
				},
			},
			{
				Heading = "EVENT",
				Items = {
					{
						Text = "Harvest Feast: catch Golden Turkeys and fill your sticker sheet!",
						Tag = "LIMITED",
						Icon = "turkey",
					},
				},
			},
		},
	},
	{
		-- 0.3.0 (owner R58 + the money FX / live prices waves of 2026-10-30): the WHAT'S NEW
		-- system itself, cash + gem sprites flying into the counters (R46), live Robux prices.
		Id = "2026-10-31-whats-new",
		Version = "0.3.0",
		Date = unixDate(2026, 10, 31), -- 2026-10-31T00:00:00Z
		Title = "KNOCKDOWNS, PETS & MORE!",
		Tagline = "Aim your nukes, knock down areas and watch your pets come alive!",
		Hero = { Kind = "Icon", Icon = "rocket" },
		Sections = {
			{
				Heading = "NEW",
				Items = {
					{ Text = "Aim at an area and KNOCK IT DOWN for a bit. It rebuilds itself!", Icon = "nuke" },
					{ Text = "Rival Factories: always someone to launch at, even solo!", Icon = "rocket" },
					{ Text = "3, 2, 1, LAUNCH! Fly along with your nuke to the target.", Icon = "rocket" },
					{ Text = "Every pet is animated: hops, flaps, wags, naps and happy spins!", Icon = "pet" },
					{ Text = "A brand-new egg hatch: wobble, crack and POP!", Icon = "egg" },
					{ Text = "What's New: tap the button in the bottom right to see updates!", Icon = "star" },
				},
			},
			{
				Heading = "IMPROVED",
				Items = {
					{ Text = "A brand-new lobby with a giant Nukey fountain!", Icon = "star" },
					{ Text = "Trucks, carts and forklifts now drive around your factory.", Icon = "check" },
					{ Text = "Real 3D models in the shop.", Icon = "gift" },
					{ Text = "Cash and gems fly into your counters when you earn them!", Icon = "cash" },
					{ Text = "Robux prices in every shop always show the latest price.", Icon = "gem" },
					{ Text = "Faster loading: your plot shows up much sooner.", Icon = "clock" },
				},
			},
			{
				Heading = "FIXED",
				Items = {
					{ Text = "Billboards no longer hide your machines or managers.", Icon = "check" },
				},
			},
		},
		Cta = { Label = "TRY ATTACKING!", Screen = "Attack" },
	},
	{
		-- The first five permanent Roblox badges now have enabled dashboard ids.
		Id = "2026-10-31-first-badges",
		Version = "0.4.0",
		Date = unixDate(2026, 10, 31) + 6 * 60 * 60, -- 2026-10-31T06:00:00Z, after the 0.3.0 note
		Title = "YOUR FIRST FIVE BADGES!",
		Tagline = "Start your collection as your pocket nuke business grows.",
		Hero = { Kind = "Icon", Icon = "trophy" },
		Sections = {
			{
				Heading = "NEW BADGES",
				Items = {
					{ Text = "Join Sell Nukes to earn your Welcome badge.", Icon = "star", Tag = "NEW" },
					{ Text = "Unlock areas 2 through 5 to earn four more badges.", Icon = "trophy", Tag = "NEW" },
					{ Text = "Already there? Join again to collect the badges you qualify for.", Icon = "check" },
				},
			},
		},
	},
	{
		-- 0.5.0 (owner R69–R75, 2026-10-31): World 3 Moon Base (low gravity, space pets, Moon Rocks),
		-- Lucky Buttons on your plot, the juice pass (click combos, fireworks, new sounds), player
		-- titles (DEVELOPER / FIRST PLAYER) and the Glow Rock miners swinging their pickaxes.
		Id = "2026-10-31-moon-base",
		Version = "0.5.0",
		Date = unixDate(2026, 10, 31) + 16 * 60 * 60, -- 2026-10-31T16:00:00Z, after the 0.4.0 note
		Title = "BLAST OFF TO MOON BASE!",
		Tagline = "A whole new world with low gravity, space pets and Lucky Buttons!",
		Hero = { Kind = "Icon", Icon = "rocket" },
		Sections = {
			{
				Heading = "NEW",
				Items = {
					{ Text = "MOON BASE: a brand-new world where you jump super high!", Icon = "rocket", Tag = "NEW" },
					{ Text = "Build 6 space areas run by cute aliens and robots.", Icon = "star" },
					{ Text = "Hatch the Moon Egg and Comet Egg: 8 new space pets!", Icon = "egg" },
					{
						Text = "Lucky Buttons pop up on your plot. Run over them for prizes!",
						Icon = "gift",
						Tag = "NEW",
					},
					{ Text = "Player titles: look out for the DEVELOPER and the FIRST PLAYER!", Icon = "trophy" },
					{ Text = "New code: type MOONBASE in Codes for free gems and spins!", Icon = "gem" },
				},
			},
			{
				Heading = "IMPROVED",
				Items = {
					{ Text = "Click fast for COMBOS, coin bursts and fireworks!", Icon = "cash" },
					{ Text = "Big banners when your machines reach a new level.", Icon = "star" },
					{ Text = "Brand-new sound effects all over the game.", Icon = "check" },
					{ Text = "The Glow Rock miners now swing their pickaxes!", Icon = "check" },
					{ Text = "Gamepass base prices are now about 30% lower!", Icon = "cash", Tag = "IMPROVED" },
				},
			},
		},
		Cta = { Label = "GO TO THE MOON!", Screen = "Teleport" },
	},
	{
		-- 0.6.0 (owner R78, 2026-10-31): the retention pack — Quests (starter goals, daily missions,
		-- trophies), the Nuke Pass Season 1 (free + premium track, Golden Nukey pet), Rookie and
		-- Comeback Rush, Friend Boost + invite rewards, Pet Index rewards, a smoother first minute.
		Id = "2026-10-31-quests-pass",
		Version = "0.6.0",
		Date = unixDate(2026, 10, 31) + 22 * 60 * 60, -- 2026-10-31T22:00:00Z, after the 0.5.0 note
		Title = "QUESTS + THE NUKE PASS!",
		Tagline = "Daily missions, a 30-tier season pass and boosts for playing with friends!",
		Hero = { Kind = "Icon", Icon = "trophy" },
		Sections = {
			{
				Heading = "NEW",
				Items = {
					{
						Text = "QUESTS: starter goals, 3 daily missions and trophies to earn!",
						Icon = "trophy",
						Tag = "NEW",
					},
					{
						Text = "NUKE PASS: 30 tiers of prizes. Premium tier 30 is the Golden Nukey pet!",
						Icon = "star",
						Tag = "NEW",
					},
					{ Text = "Play with friends: +10% cash for every friend in your server!", Icon = "gift" },
					{ Text = "Invite a friend who is new to the game and you both get gems!", Icon = "gem" },
					{ Text = "Fill your Pet Index to earn gems and a permanent cash bonus!", Icon = "pet" },
					{ Text = "New code: type QUESTS in Codes for free gems and a spin!", Icon = "gem" },
				},
			},
			{
				Heading = "IMPROVED",
				Items = {
					{ Text = "New players get ROOKIE RUSH: 2x cash for your first 15 minutes!", Icon = "cash" },
					{ Text = "Been away a while? COMEBACK RUSH gives you 2x cash for 10 minutes!", Icon = "clock" },
					{ Text = "A smoother first minute on console, phone and tablet.", Icon = "check" },
				},
			},
		},
		Cta = { Label = "OPEN QUESTS!", Screen = "Quests" },
	},
	{
		Id = "2026-11-01-surprise-batches",
		Version = "0.7.0",
		Date = unixDate(2026, 11, 1) + 60 * 60, -- 2026-11-01T01:00:00Z, after the 0.6.0 note
		Title = "SURPRISE BATCHES!",
		Tagline = "Rare nuke flavours, hourly Happy Hours, AA towers and gifts from minute one!",
		Hero = { Kind = "Icon", Icon = "nuke" },
		Sections = {
			{
				Heading = "NEW",
				Items = {
					{
						Text = "SURPRISE BATCHES: every batch can pop a rare flavour worth up to x100!",
						Icon = "nuke",
						Tag = "NEW",
					},
					{
						Text = "NUKEY'S HAPPY HOURS: a surprise event at the top of every hour!",
						Icon = "clock",
						Tag = "NEW",
					},
					{
						Text = "AA TOWERS: buy and upgrade defence towers to stop incoming nukes!",
						Icon = "rocket",
						Tag = "NEW",
					},
					{ Text = "Playtime gifts now start at 1 minute: 10 gifts and CLAIM ALL!", Icon = "gift" },
					{ Text = "Collect every flavour in the new Flavour Book (in Pets)!", Icon = "trophy" },
					{ Text = "Name your plot! Click your front sign (or walk up to it).", Icon = "star" },
				},
			},
			{
				Heading = "MORE NEW",
				Items = {
					{ Text = "Gem upgrades: buy one machine level for 75 gems!", Icon = "gem" },
					{ Text = "Managers now wear name tags and chat while they work!", Icon = "pet" },
					{ Text = "POCKET ROCKET: a once-a-day cash boost in the offers!", Icon = "cash" },
					{ Text = "Everyone can launch nukes now. No unlock needed!", Icon = "nuke" },
					{ Text = "Got nuked? Strike back with a GOLDEN REVENGE NUKE!", Icon = "rocket" },
					{
						Text = "Lower shop prices: products about 20% off, passes another 30% off!",
						Tag = "IMPROVED",
						Icon = "gift",
					},
				},
			},
			{
				Heading = "IMPROVED",
				Items = {
					{ Text = "The Lucky Wheel got juicier: ticking pegs, rim lights, confetti wins!", Icon = "star" },
					{ Text = "Boosts now sit as a sticker on your cash. Tap it to see every boost!", Icon = "cash" },
					{ Text = "Cleaner menus: the side buttons hide while a window is open.", Icon = "check" },
					{ Text = "Quests GO buttons open the window, then bring you back to Quests.", Icon = "trophy" },
					{ Text = "The tutorial points right at the button to press and makes it glow.", Icon = "check" },
					{ Text = "Your Auto Clicker now counts toward click quests!", Icon = "clock" },
				},
			},
		},
		Cta = { Label = "SEE FLAVOURS!", Screen = "Pets" },
	},
	-- Owner R122 (0.8.0 "Algorithm pack"): faster first minutes, automation sooner, friends and
	-- notifications one tap away, no surprise purchase prompts.
	{
		Id = "2026-11-01-faster-start",
		Version = "0.8.0",
		Date = unixDate(2026, 11, 1) + 8 * 60 * 60, -- 2026-11-01T08:00:00Z, after the 0.7.0 note
		Title = "FASTER START!",
		Tagline = "Uncle Atom joins sooner, loading is quicker and friends are one tap away!",
		Hero = { Kind = "Icon", Icon = "rocket" },
		Sections = {
			{
				Heading = "NEW",
				Items = {
					{
						Text = "Uncle Atom now joins after your 3rd build and makes nukes for you!",
						Icon = "pet",
						Tag = "NEW",
					},
					{ Text = "New INVITE button: every friend in your server gives +10% cash!", Icon = "star" },
					{ Text = "Turn on notifications to hear when your factory is full!", Icon = "clock" },
				},
			},
			{
				Heading = "IMPROVED",
				Items = {
					{ Text = "Faster loading: jump into your plot in seconds.", Icon = "rocket" },
					{ Text = "Lucky deal buttons now show a deal card. No surprise pop-ups!", Icon = "gift" },
					{ Text = "Shop and offer buttons never buy by accident on console or touch.", Icon = "check" },
				},
			},
		},
	},
	-- Five additional Nuke Town milestones use the existing server badge awards and native toast.
	{
		Id = "2026-11-01-more-badges",
		Version = "0.9.0",
		Date = unixDate(2026, 11, 1) + 14 * 60 * 60,
		Title = "FIVE MORE BADGES!",
		Tagline = "Keep building your Nuke Town factory and collect five more Roblox badges!",
		Hero = { Kind = "Icon", Icon = "trophy" },
		Sections = {
			{
				Heading = "NEW",
				Items = {
					{
						Text = "Earn badges for Rocket Factory, Launch Silos and Nuke Megastore!",
						Icon = "trophy",
						Tag = "NEW",
					},
					{ Text = "Reach Space Port and Mega Nuclear Facility for two more badges!", Icon = "rocket" },
					{ Text = "Free private servers are here! Build with friends in your own server.", Icon = "star" },
				},
			},
			-- Shipped in the same 0.9.0 publish as the badges (0.8.0 is already live, and a seen
			-- note never re-opens, so these lines go here rather than onto the 0.8.0 note).
			{
				Heading = "IMPROVED",
				Items = {
					-- Owner R128: the Order Window system was removed.
					{ Text = "No more Order Window chores: your Nuke Stand sells all by itself!", Icon = "cash" },
					-- Owner R130: BoomDash Delivery's Dispatcher (manager) is pad 4 instead of pad 8.
					{ Text = "BoomDash Delivery: hire the Dispatcher much sooner!", Icon = "rocket" },
					-- 0.9.1, owner R133: the attack picker frames the target's built base close up.
					{ Text = "Attack view now shows your target's base up close!", Icon = "nuke" },
					-- 0.9.1, owner R134: the hub plot teleport pads were removed.
					{ Text = "Tidier lobby: no more plot teleport pads. Walk or use Teleport!", Icon = "check" },
					-- 0.9.2, owner R137: Tool Wall / Glow Lamp / Uncle Atom much sooner (sim 0.5 / 0.6 / 1.2 min).
					{ Text = "Garage Lab: your first builds and Uncle Atom come much faster!", Icon = "rocket" },
					-- 0.9.2, owner R137: the Cashier Bot (Nuke Stand manager) is pad 4 instead of pad 8.
					{ Text = "Nuke Stand: hire the Cashier Bot right after your 3rd build!", Icon = "cash" },
				},
			},
		},
	},
}

-- Deep-freeze the notes so no runtime code can edit them.
for _, note in NOTES do
	for _, section in note.Sections do
		for _, item in section.Items do
			table.freeze(item)
		end
		table.freeze(section.Items)
		table.freeze(section)
	end
	table.freeze(note.Sections)
	table.freeze(note.Hero)
	if note.Cta ~= nil then
		table.freeze(note.Cta)
	end
	table.freeze(note)
end
ChangeNotesConfig.Notes = table.freeze(NOTES)

-- id → index (1 = oldest), built once.
local INDEX: { [string]: number } = {}
for index, note in NOTES do
	INDEX[note.Id] = index
end

--[[ The note with id `id` (nil for anything else, any type). ]]
function ChangeNotesConfig.get(id: unknown): Note?
	local index = if type(id) == "string" then INDEX[id] else nil
	return if index ~= nil then NOTES[index] else nil
end

--[[
	The note's position in Notes (1 = oldest), nil for unknown ids / non-strings (safe on
	untrusted input). Example: ChangeNotesConfig.indexOf("2026-10-30-sellnukes-born") --> 1
]]
function ChangeNotesConfig.indexOf(id: unknown): number?
	return if type(id) == "string" then INDEX[id] else nil
end

--[[
	The newest note (the last entry, hidden by a future ShowFrom or not), nil while the list is
	empty. Config / validation / test use; everything players see reads newestVisible(now).
]]
function ChangeNotesConfig.newest(): Note?
	return NOTES[#NOTES]
end

-- ShowFrom: time-gated notes (see the module header "ShowFrom") ----------------------------------

--[[
	True when `note` is visible to players at `now` (unix seconds): it has no ShowFrom, or ShowFrom
	has passed. Example: isVisible({ ShowFrom = 100, ... }, 99) --> false; (…, 100) --> true
]]
function ChangeNotesConfig.isVisible(note: Note, now: number): boolean
	local showFrom = note.ShowFrom
	return showFrom == nil or now >= showFrom
end

--[[
	How many notes of `notes` (oldest first) are visible at `now`: the visible PREFIX. The scan
	stops at the first hidden note, so even an unvalidated candidate list can never show a later
	note before an earlier one. O(#notes) (a handful), no allocation.
	Example: visibleCountIn({ a, b, c with ShowFrom = 500 }, 499) --> 2
]]
function ChangeNotesConfig.visibleCountIn(notes: { Note }, now: number): number
	for index, note in notes do
		if not ChangeNotesConfig.isVisible(note, now) then
			return index - 1
		end
	end
	return #notes
end

--[[ How many shipped notes players can see at `now` (the first N of Notes). ]]
function ChangeNotesConfig.visibleCount(now: number): number
	return ChangeNotesConfig.visibleCountIn(NOTES, now)
end

--[[ The newest note players can see at `now`, nil when none is visible yet. ]]
function ChangeNotesConfig.newestVisible(now: number): Note?
	local count = ChangeNotesConfig.visibleCount(now)
	return if count > 0 then NOTES[count] else nil
end

--[[
	The next reveal after `now`: the ShowFrom of the first hidden note of `notes`, nil when every
	note is visible. Client and server each arm ONE task.delay to it.
	Example: nextShowFromIn({ a, b with ShowFrom = 500 }, 10) --> 500
]]
function ChangeNotesConfig.nextShowFromIn(notes: { Note }, now: number): number?
	local upcoming = notes[ChangeNotesConfig.visibleCountIn(notes, now) + 1]
	return if upcoming ~= nil then upcoming.ShowFrom else nil
end

--[[ nextShowFromIn over the shipped notes. ]]
function ChangeNotesConfig.nextShowFrom(now: number): number?
	return ChangeNotesConfig.nextShowFromIn(NOTES, now)
end

--[[
	The version label players read WHILE a note is hidden by ShowFrom. nil = the newest visible
	note's own Version. Set it in the build that publishes a note early, to the last version
	players saw (e.g. "0.4.2"), and bump its PATCH with Current's when a PATCH inside the hidden
	window fixes something players can see now. Checked by validateVisibleVersion.
	Example: ChangeNotesConfig.VisibleVersion = "0.4.2" -- Current "0.5.0", the 0.5.0 note hidden
]]
ChangeNotesConfig.VisibleVersion = nil :: string?

--[[
	The version players should read at `now`: `current` while every note is visible; while a note
	is still hidden, `visibleVersion` when it is valid, shares MAJOR.MINOR with the newest VISIBLE
	note, is not older than that note's Version and not newer than `current`; otherwise that
	note's Version, so the label never announces an update players cannot see yet. Falls back to
	`current` when no note is visible or that Version is invalid / newer than `current`.
	Example: displayVersionIn({ 0.4.0 note, 0.5.0 note with ShowFrom = 500 }, "0.5.0", 499) --> "0.4.0"
]]
function ChangeNotesConfig.displayVersionIn(
	notes: { Note },
	current: string,
	now: number,
	visibleVersion: string?
): string
	local count = ChangeNotesConfig.visibleCountIn(notes, now)
	if count >= #notes then
		return current
	end
	local visible = notes[count]
	if
		visible ~= nil
		and VersionConfig.isValid(visible.Version)
		and VersionConfig.isValid(current)
		and VersionConfig.compare(visible.Version, current) <= 0
	then
		if
			visibleVersion ~= nil
			and VersionConfig.isValid(visibleVersion)
			and VersionConfig.sameMinor(visibleVersion, visible.Version)
			and VersionConfig.compare(visibleVersion, visible.Version) >= 0
			and VersionConfig.compare(visibleVersion, current) <= 0
		then
			return visibleVersion
		end
		return visible.Version
	end
	return current
end

--[[ displayVersionIn over the shipped notes, VersionConfig.Current and VisibleVersion. ]]
function ChangeNotesConfig.displayVersion(now: number): string
	return ChangeNotesConfig.displayVersionIn(NOTES, VersionConfig.Current, now, ChangeNotesConfig.VisibleVersion)
end

--[[
	Checks a VisibleVersion against a note list (static: no clock), so a typo fails
	./scripts/check.sh instead of reaching the label. nil is always fine. Otherwise it must be a
	valid version, strictly older than `current`, and share MAJOR.MINOR with a note that is
	FOLLOWED by a note carrying a ShowFrom (the visible note of an early publish), not older than
	that note's Version.
	@return problems (empty = valid)
]]
function ChangeNotesConfig.validateVisibleVersion(notes: { Note }, current: string, visible: unknown): { string }
	local problems: { string } = {}
	if visible == nil then
		return problems
	end
	if type(visible) ~= "string" or not VersionConfig.isValid(visible) then
		table.insert(problems, `VisibleVersion {tostring(visible)} is not a MAJOR.MINOR.PATCH version`)
		return problems
	end
	local version = visible :: string
	if VersionConfig.isValid(current) and VersionConfig.compare(version, current) >= 0 then
		table.insert(problems, `VisibleVersion {version} must be older than the current version {current}`)
	end
	local anchor: Note? = nil
	for index = #notes - 1, 1, -1 do
		local note = notes[index]
		if VersionConfig.isValid(note.Version) and VersionConfig.sameMinor(note.Version, version) then
			if notes[index + 1].ShowFrom ~= nil then
				anchor = note
			end
			break
		end
	end
	if anchor == nil then
		table.insert(
			problems,
			`VisibleVersion {version} needs a note with its MAJOR.MINOR followed by a ShowFrom note (an early publish)`
		)
	elseif VersionConfig.compare(version, anchor.Version) < 0 then
		table.insert(problems, `VisibleVersion {version} is older than its note's {anchor.Version}`)
	end
	return problems
end

--[[
	The version label text at `now`: VersionConfig.menuText (label + "· build N" when published)
	with the label swapped for displayVersion(now) while a note is still hidden.
	@param placeVersion game.PlaceVersion (any value)
	Example: menuText(431, now) --> "v0.3.0 · build 431"
]]
function ChangeNotesConfig.menuText(placeVersion: unknown, now: number): string
	local full = VersionConfig.menuText(placeVersion)
	local version = ChangeNotesConfig.displayVersion(now)
	if version == VersionConfig.Current then
		return full
	end
	return VersionConfig.label(version) .. string.sub(full, #VersionConfig.label() + 1)
end

-- Save data ------------------------------------------------------------------------------------

--[[
	True when `value` LOOKS like a note id ("YYYY-MM-DD-slug", lowercase letters / digits /
	dashes, ≤ MaxIdLength), known or not. Used to keep ids written by a newer server.
]]
function ChangeNotesConfig.isIdShape(value: unknown): boolean
	return type(value) == "string"
		and #value <= ChangeNotesConfig.Limits.MaxIdLength
		and string.match(value, "^%d%d%d%d%-%d%d%-%d%d%-[a-z0-9%-]+$") ~= nil
end

--[[ A fresh profile.notes record: nothing seen yet. ]]
function ChangeNotesConfig.newState(): State
	return { seen = "", at = 0 }
end

-- Largest unix time accepted from a save (year ~2286).
local MAX_TIME = 9_999_999_999

--[[
	Repairs a stored profile.notes (any shape, untrusted) into a valid State. A malformed seen id
	becomes "" (the player simply sees the newest note again); a well-formed unknown id is kept.
	Example: reconcileState({ seen = 5 }) --> { seen = "", at = 0 }
]]
function ChangeNotesConfig.reconcileState(raw: unknown): State
	if type(raw) ~= "table" then
		return ChangeNotesConfig.newState()
	end
	local data = raw :: { [string]: unknown }
	local seen = if ChangeNotesConfig.isIdShape(data.seen) then data.seen :: string else ""
	local at = data.at
	local time = if type(at) == "number" and at == at and at % 1 == 0 and at >= 0 and at <= MAX_TIME then at else 0
	return { seen = seen, at = time }
end

-- Validation -----------------------------------------------------------------------------------

-- Membership sets for validate / the logic module.
local function setOf(list: { string }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, value in list do
		set[value] = true
	end
	return table.freeze(set)
end
ChangeNotesConfig.TagSet = setOf(ChangeNotesConfig.Tags :: { any })
ChangeNotesConfig.IconSet = setOf(ChangeNotesConfig.Icons :: { any })
ChangeNotesConfig.CtaScreenSet = setOf(ChangeNotesConfig.CtaScreens :: { any })
ChangeNotesConfig.ShopTabSet = setOf(ChangeNotesConfig.ShopTabs)
ChangeNotesConfig.ActionSet = setOf(ChangeNotesConfig.Actions :: { any })
ChangeNotesConfig.SourceSet = setOf(ChangeNotesConfig.Sources :: { any })

-- "YYYY-MM-DD" of a unix time's UTC day (civil-from-days, the inverse of unixDate).
local function utcDateText(unix: number): string
	local z = unix // DAY + 719468
	local era = (if z >= 0 then z else z - 146096) // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local day = doy - (153 * mp + 2) // 5 + 1
	local month = if mp < 10 then mp + 3 else mp - 9
	local year = yoe + era * 400 + (if month <= 2 then 1 else 0)
	return string.format("%04d-%02d-%02d", year, month, day)
end
ChangeNotesConfig.utcDateText = utcDateText

--[[
	Checks a list of notes (the shipped NOTES, or a candidate list in tests): unique ids in the
	"YYYY-MM-DD-slug" shape (≤ AnalyticsIdLength in SellNukes) whose date part is the note's UTC
	Date, strictly ascending dates, semver Versions that never go down in list order, text caps
	(UTF-8, no leading / trailing spaces), section / item counts, known tags / icons / hero pets /
	image ids, CTA screens and Shop tabs, and ShowFrom: whole seconds, ≥ Date, never earlier than
	the previous note's ShowFrom, required on every note after the first one that has it.
	With `current` (the game's version) it also checks that `current` is valid, not older than the
	newest note's Version, and in the same MAJOR.MINOR.
	@param notes    the notes, oldest first
	@param current  the game's version to check against the newest note (optional)
	@return problems (empty = valid)
	Example: ChangeNotesConfig.validateNotes(ChangeNotesConfig.Notes, "0.3.0") --> {}
]]
function ChangeNotesConfig.validateNotes(notes: { Note }, current: string?): { string }
	local problems: { string } = {}
	local limits = ChangeNotesConfig.Limits
	local function text(where: string, value: unknown, cap: number)
		if type(value) ~= "string" then
			table.insert(problems, `{where} must be a string`)
			return
		end
		local length = utf8.len(value)
		if length == nil then
			table.insert(problems, `{where} is not valid UTF-8`)
		elseif length == 0 or length > cap then
			table.insert(problems, `{where} must be 1..{cap} characters (has {length})`)
		elseif string.match(value, "^%s") ~= nil or string.match(value, "%s$") ~= nil then
			table.insert(problems, `{where} has leading / trailing spaces`)
		end
	end
	local seen: { [string]: boolean } = {}
	local lastDate = -math.huge
	local lastVersion: string? = nil -- the previous VALID note version (order check)
	local lastShowFrom: number? = nil -- the previous VALID ShowFrom (order check)
	local hadShowFrom = false -- an earlier note carried a ShowFrom (later ones need one)
	for index, note in notes do
		local where = `Notes[{index}]`
		if not ChangeNotesConfig.isIdShape(note.Id) then
			table.insert(problems, `{where}.Id must look like "YYYY-MM-DD-slug" (≤ {limits.MaxIdLength})`)
		elseif seen[note.Id] then
			table.insert(problems, `{where}.Id {note.Id} is a duplicate`)
		elseif #note.Id > ChangeNotesConfig.AnalyticsIdLength then
			table.insert(
				problems,
				`{where}.Id {note.Id} is longer than {ChangeNotesConfig.AnalyticsIdLength} (an analytics key part)`
			)
		end
		seen[note.Id] = true
		if type(note.Date) ~= "number" or note.Date ~= note.Date or note.Date % 1 ~= 0 or note.Date <= 0 then
			table.insert(problems, `{where}.Date must be whole unix seconds`)
		else
			if note.Date <= lastDate then
				table.insert(problems, `{where}.Date must be later than the previous note's`)
			end
			lastDate = note.Date
			if type(note.Id) == "string" and string.sub(note.Id, 1, 10) ~= utcDateText(note.Date) then
				table.insert(problems, `{where}.Id date part must be {utcDateText(note.Date)} (its Date)`)
			end
		end
		if not VersionConfig.isValid(note.Version) then
			table.insert(problems, `{where}.Version {tostring(note.Version)} must be semver "X.Y.Z"`)
		else
			local previous = lastVersion
			if previous ~= nil and VersionConfig.compare(note.Version, previous) < 0 then
				table.insert(problems, `{where}.Version {note.Version} is older than the previous note's {previous}`)
			end
			lastVersion = note.Version
		end
		-- ShowFrom: whole unix seconds, not before the note's own Date, never earlier than the
		-- previous note's, and once any note has one every later note needs one (visibility must
		-- stay a prefix of the list; see the module header "ShowFrom").
		local showFrom: unknown = note.ShowFrom
		if showFrom ~= nil then
			hadShowFrom = true
			if
				type(showFrom) ~= "number"
				or showFrom ~= showFrom
				or showFrom % 1 ~= 0
				or showFrom <= 0
				or showFrom > MAX_TIME
			then
				table.insert(problems, `{where}.ShowFrom must be whole unix seconds`)
			else
				if type(note.Date) == "number" and showFrom < note.Date then
					table.insert(problems, `{where}.ShowFrom must not be before its Date`)
				end
				local previousShow = lastShowFrom
				if previousShow ~= nil and showFrom < previousShow then
					table.insert(problems, `{where}.ShowFrom must not be earlier than the previous note's ShowFrom`)
				end
				lastShowFrom = showFrom
			end
		elseif hadShowFrom then
			table.insert(
				problems,
				`{where} needs a ShowFrom: an earlier note has one, so this note would show before it`
			)
		end
		text(`{where}.Title`, note.Title, limits.MaxTitle)
		text(`{where}.Tagline`, note.Tagline, limits.MaxTagline)
		local hero = note.Hero
		if type(hero) ~= "table" then
			table.insert(problems, `{where}.Hero must be a table`)
		elseif hero.Kind == "Pet" then
			if PetConfig.get(hero.PetId) == nil then
				table.insert(problems, `{where}.Hero.PetId {tostring(hero.PetId)} is not a pet`)
			end
		elseif hero.Kind == "Icon" then
			if hero.Icon == nil or not ChangeNotesConfig.IconSet[hero.Icon] then
				table.insert(problems, `{where}.Hero.Icon must be one of Icons`)
			end
		elseif hero.Kind == "Image" then
			local image = hero.Image
			if type(image) ~= "string" or #image > 40 or string.match(image, "^rbxassetid://%d+$") == nil then
				table.insert(problems, `{where}.Hero.Image must be "rbxassetid://<digits>"`)
			end
		else
			table.insert(problems, `{where}.Hero.Kind must be "Pet", "Icon" or "Image"`)
		end
		if type(note.Sections) ~= "table" or #note.Sections == 0 or #note.Sections > limits.MaxSections then
			table.insert(problems, `{where} needs 1..{limits.MaxSections} sections`)
		else
			for sectionIndex, section in note.Sections do
				local at = `{where}.Sections[{sectionIndex}]`
				text(`{at}.Heading`, section.Heading, limits.MaxHeading)
				if
					type(section.Items) ~= "table"
					or #section.Items == 0
					or #section.Items > limits.MaxItemsPerSection
				then
					table.insert(problems, `{at} needs 1..{limits.MaxItemsPerSection} items`)
				else
					for itemIndex, item in section.Items do
						local it = `{at}.Items[{itemIndex}]`
						text(`{it}.Text`, item.Text, limits.MaxItemText)
						if item.Tag ~= nil and not ChangeNotesConfig.TagSet[item.Tag] then
							table.insert(problems, `{it}.Tag {tostring(item.Tag)} is not a tag`)
						end
						if item.Icon ~= nil and not ChangeNotesConfig.IconSet[item.Icon] then
							table.insert(problems, `{it}.Icon {tostring(item.Icon)} is not an icon`)
						end
					end
				end
			end
		end
		local cta = note.Cta
		if cta ~= nil then
			text(`{where}.Cta.Label`, cta.Label, limits.MaxCtaLabel)
			if not ChangeNotesConfig.CtaScreenSet[cta.Screen] then
				table.insert(problems, `{where}.Cta.Screen {tostring(cta.Screen)} is not a CTA screen`)
			end
			if cta.Tab ~= nil and (cta.Screen ~= "Shop" or not ChangeNotesConfig.ShopTabSet[cta.Tab]) then
				table.insert(problems, `{where}.Cta.Tab is only for Screen "Shop" and must be a Shop tab`)
			end
		end
	end
	if current ~= nil then
		local newest = notes[#notes]
		if not VersionConfig.isValid(current) then
			table.insert(problems, `current version {tostring(current)} must be semver "X.Y.Z"`)
		elseif newest ~= nil and VersionConfig.isValid(newest.Version) then
			if VersionConfig.compare(current, newest.Version) < 0 then
				table.insert(problems, `current version {current} is older than the newest note's {newest.Version}`)
			elseif not VersionConfig.sameMinor(current, newest.Version) then
				table.insert(
					problems,
					`current version {current} has no note: a MINOR / MAJOR bump appends a note with that Version`
				)
			end
		end
	end
	return problems
end

--[[
	Checks every shipped note (validateNotes, against VersionConfig.Current), VersionConfig's own
	data and every tunable (see the module header).
	@return problems (empty = valid)
	Example: assert(#ChangeNotesConfig.validate() == 0, table.concat(ChangeNotesConfig.validate(), "\n"))
]]
function ChangeNotesConfig.validate(): { string }
	local problems = ChangeNotesConfig.validateNotes(NOTES, VersionConfig.Current)
	if #NOTES == 0 then
		table.insert(problems, "there must be at least one note")
	end
	for _, problem in VersionConfig.validate() do
		table.insert(problems, problem)
	end
	local function positive(name: string, value: number)
		if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
			table.insert(problems, `{name} must be a positive finite number`)
		end
	end
	positive("Server.ActionBurst", ChangeNotesConfig.Server.ActionBurst)
	positive("Server.ActionPerSecond", ChangeNotesConfig.Server.ActionPerSecond)
	positive("Server.MaxReportsPerKey", ChangeNotesConfig.Server.MaxReportsPerKey)
	positive("Server.MaxOpenSeconds", ChangeNotesConfig.Server.MaxOpenSeconds)
	positive("Auto.FirstCheckDelay", ChangeNotesConfig.Auto.FirstCheckDelay)
	positive("Auto.CheckSeconds", ChangeNotesConfig.Auto.CheckSeconds)
	positive("Auto.PoliteChecks", ChangeNotesConfig.Auto.PoliteChecks)
	positive("Auto.WaitSeconds", ChangeNotesConfig.Auto.WaitSeconds)
	positive("Auto.RevealLagSeconds", ChangeNotesConfig.Auto.RevealLagSeconds)
	if ChangeNotesConfig.Auto.RevealLagSeconds > 60 then
		table.insert(problems, "Auto.RevealLagSeconds must be at most 60 (a reveal is never held a minute)")
	end
	positive("PurchaseFlow.HoldSeconds", ChangeNotesConfig.PurchaseFlow.HoldSeconds)
	-- Time-open buckets: ascending positive bounds, one more label than bounds.
	local previous = 0
	for _, bound in ChangeNotesConfig.OpenBuckets do
		if bound <= previous then
			table.insert(problems, "OpenBuckets must be ascending positive seconds")
		end
		previous = bound
	end
	if #ChangeNotesConfig.OpenBucketLabels ~= #ChangeNotesConfig.OpenBuckets + 1 then
		table.insert(problems, "OpenBucketLabels needs one label more than OpenBuckets")
	end
	for _, problem in
		ChangeNotesConfig.validateVisibleVersion(NOTES, VersionConfig.Current, ChangeNotesConfig.VisibleVersion)
	do
		table.insert(problems, problem)
	end
	return problems
end

return table.freeze(ChangeNotesConfig)
