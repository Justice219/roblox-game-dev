--!strict
--[[
	ManagerTagConfig — tunables, name pools and speech lines for the manager NPC nametags + speech
	bubbles (owner R87: "in sell lemons the managers/automaters all have nametags"; the reference
	is inspiration only — SellNukes draws its own stud-styled tag).

	What a tag shows (three lines over the manager's head, client-only, Tycoon/Npc/ManagerTags):
		[ FOREMAN ]          role chip: a small coloured stud pill (ChipColors by world)
		 Captain Kaboom      the manager's NAME: big white outlined text
		 runs Glow Rock Drill     "runs <producer display name>" (the pad's target producer, from config)

	Where the NAME + ROLE come from (decided for R87, documented in docs/managers.md):
		* `Managers[key].pool` set (Nuke Town's job-title hires: "Foreman", "Cashier Bot" ...):
		  the chip reads the pad's job title and the name is picked from `NamePools[pool]` —
		  deterministic per plot OWNER + producer (ManagerTagLogic.pickName: a seeded shuffle of the
		  pool by OwnerUserId + world + pool, indexed by the manager's ordinal), so a player's
		  Foreman keeps the same name across rejoins, servers and plot slots, and no two managers of
		  one plot share a name.
		* no pool (Uncle Atom, every Dino Valley / Moon Base manager): the pad already names the
		  character ("Hire Rocky Raptor"), so the tag shows that canon name and the chip reads
		  `Managers[key].role` or `DefaultRole` ("Manager"). Kids see the name they hired.

	Kid-safe rules for the pools + lines: original names only (science / nuke-toy puns), no real
	people, brands or franchise characters, no weapons words; lines are short, upbeat, <= 26 chars.
	tests/manager-tags.luau checks every listed manager has a row, pools are big enough, names are
	unique and short, and every line fits.

	Who reads it:
		- client `Tycoon/Npc/ManagerTags` (builds + places the billboards)
		- client `Tycoon/Npc/ManagerTagLogic` (pure: name pick, bubble scheduling, overlap test)
		- `tests/manager-tags.luau` (lune)

	Usage:
		local ManagerTagConfig = require(ReplicatedStorage.Shared.Config.ManagerTagConfig)
		local row = ManagerTagConfig.Managers.A4_Foreman --> { pool = "crew" }
		local lines = ManagerTagConfig.Lines.general
]]

export type ManagerRow = {
	pool: string?, -- NamePools key: the name is picked per owner (chip = the pad's job title)
	role: string?, -- chip text for canon-named managers (nil = DefaultRole)
}

export type TagTunables = {
	StudsWidth: number, -- billboard width in studs (shrinks with distance like the world) ...
	PixelWidth: number, -- ... plus a pixel floor so it stays readable far away (phones, TVs)
	StudsHeight: number,
	PixelHeight: number,
	DeviceScale: number, -- phones / tablets / consoles: a little bigger (both components)
	HeadGap: number, -- studs between the top of the head (hat) and the tag's bottom edge
	DazedLift: number, -- extra studs while dazed (the knockdown stars orbit right above the head)
	MaxDistanceOwn: number, -- engine cull distance of the local player's managers' tags
	MaxDistanceOther: number, -- other players' managers (less clutter)
	ChipHeight: number, -- row heights as fractions of the tag height (top to bottom)
	NameHeight: number,
	RunsHeight: number,
	ChipMinWidth: number, -- chip width = clamp(ChipBase + ChipPerChar * #text, min, max) of the tag width
	ChipMaxWidth: number,
	ChipBase: number,
	ChipPerChar: number,
	ChipTextSize: number, -- MaxTextSize caps (TextScaled fills the row up to these)
	NameTextSize: number,
	RunsTextSize: number,
	RunsPrefix: string,
	RunsColor: Color3,
	YieldCheckRange: number, -- studs: only nearer tags run the producer-board overlap test
	YieldMargin: number, -- px of clear space kept between a tag and a producer board on screen
	YieldClearRefreshes: number, -- consecutive clear refreshes before a yielded tag comes back
	NudgeMaxFraction: number, -- a tag slides sideways at most this share of its own width
	NudgeRate: number, -- 1/s: how fast a tag eases to its new sideways offset
	NudgeEpsilon: number, -- studs: smaller target changes are ignored (no shimmer)
	FullWidthChars: number, -- characters of a "runs" line the full tag width holds
	MinWidthScale: number, -- narrowest tag (share of the full width)
}

export type BubbleTunables = {
	StudsWidthBase: number, -- bubble width = base + perChar * #line (studs + pixel floor alike)
	StudsWidthPerChar: number,
	PixelWidthBase: number,
	PixelWidthPerChar: number,
	HeightRatio: number, -- bubble height as a fraction of the TAG height (same studs : px mix)
	Gap: number, -- gap above the tag, in bubble heights
	TextSize: number,
	IntervalMin: number, -- seconds between two bubbles of one plot (uniform in [min, max])
	IntervalMax: number,
	FirstDelayMin: number, -- the first bubble after the plot's managers appear
	FirstDelayMax: number,
	ShowSeconds: number, -- how long one bubble stays up
	NearRange: number, -- studs: the owner must be this close to the speaking manager
	PopSeconds: number, -- pop-in tween (skipped with reduced motion)
}

local ManagerTagConfig = {}

-- Chip text of canon-named managers (pad name = the character's name).
ManagerTagConfig.DefaultRole = "Manager"

--[[
	Every world's managers (ManagerNpcConfig.WorldManagerKeys). Nuke Town's job-title hires draw a
	name; Uncle Atom and the Dino / Moon characters keep the name their pad gives them.
	A2 Cashier Bot and A8 Store Manager are hover robots (ManagerNpcConfig rig style "Hover"),
	so they draw robot names.
]]
ManagerTagConfig.Managers = {
	-- Nuke Town (main)
	A1_UncleAtom = {},
	A2_CashierBot = { pool = "robot" },
	A3_Dispatcher = { pool = "crew" },
	A4_Foreman = { pool = "crew" },
	A5_HeadScientist = { pool = "crew" },
	A6_FactoryBoss = { pool = "crew" },
	A7_LaunchDirector = { pool = "crew" },
	A8_StoreManager = { pool = "robot" },
	A9_FlightDirector = { pool = "crew" },
	A10_ChiefEngineer = { pool = "crew" },
	-- Dino Valley (dino): canon names from the pads
	D1_RockyRaptor = {},
	D2_StegoSally = {},
	D3_CaptainPtera = {},
	D4_ParaPete = {},
	D5_DrTrike = {},
	D6_ChiefTyra = {},
	-- Moon Base (moon): canon names from the pads
	M1_BleepBot = {},
	M2_ZipZorp = {},
	M3_CaptainGlorp = {},
	M4_Drillbert = {},
	M5_DrNova = {},
	M6_CommanderLux = {},
} :: { [string]: ManagerRow }

--[[
	Name pools (original, kid-safe; nuke-toy / science puns). A pool must hold at least as many
	names as one world has managers drawing from it (tests/manager-tags.luau), so a plot never
	repeats a name. Names stay <= 16 characters so they fit the tag at the floor size.
]]
ManagerTagConfig.NamePools = {
	crew = {
		"Professor Fizz",
		"Atom Andy",
		"Dottie Dynamo",
		"Captain Kaboom",
		"Sparky Sue",
		"Penny Proton",
		"Gus Gizmo",
		"Millie Megawatt",
		"Ziggy Zap",
		"Benny Boom",
		"Rosie Rocket",
		"Doc Fusion",
		"Wally Watt",
		"Ida Isotope",
		"Fizzy Fran",
		"Polly Plasma",
		"Max Molecule",
		"Nina Nucleus",
		"Ollie Orbit",
		"Chuck Charge",
		"Gigi Glow",
		"Sunny Spark",
		"Mabel Magnet",
		"Rocco Reactor",
	},
	robot = {
		"Beep-O",
		"Bolt-7",
		"Sir Sprocket",
		"Gizmo-9",
		"Widget",
		"Clanky",
		"Zappy-3",
		"Coggy",
		"Whirr-12",
		"Rivet",
		"Blinky-5",
		"Dynamo-1",
	},
} :: { [string]: { string } }

--[[
	Speech-bubble lines (<= 26 characters). A manager speaks from `general` + its world's list
	(+ `robot` when it draws a robot name or lives on the Moon). Picked by ManagerTagLogic.chooseLine
	(never the same line twice in a row on one plot).
]]
ManagerTagConfig.Lines = {
	general = {
		"Efficiency... yes!",
		"Nukes for everyone!",
		"Another one done!",
		"Right on schedule!",
		"Teamwork makes it work!",
		"Best boss ever!",
		"I love this job!",
		"Smooth as candy!",
		"Zero mistakes today!",
		"Look at that shine!",
	},
	main = {
		"Fresh pocket nukes!",
		"Sprinkles on top!",
		"Boom-tastic work!",
		"Confetti is ready!",
	},
	dino = {
		"Rawr-some work!",
		"Stomp, stomp, done!",
		"Dino-mite job!",
		"Fresh from the valley!",
	},
	moon = {
		"Out of this world!",
		"Moon power, go!",
		"Zero gravity, full speed!",
		"Shiny as a star!",
	},
	robot = {
		"Beep boop, all good!",
		"Systems: happy!",
		"Calculating... awesome!",
	},
} :: { [string]: { string } }

-- Chip colour per world (UIStyleConfig ColorName); unknown worlds use DefaultChipColor.
ManagerTagConfig.ChipColors = {
	main = "yellow",
	dino = "green",
	moon = "purple",
} :: { [string]: string }
ManagerTagConfig.DefaultChipColor = "yellow"

--[[
	Tag size: studs (scales with the world) + a pixel floor (readable far away); the WIDTH then
	shrinks to what the tag's own text needs (ManagerTagLogic.widthScale, >= MinWidthScale). When
	the tag would cover its producer's billboard on screen it slides sideways (<= NudgeMaxFraction
	of its width, eased at NudgeRate) and only hides when that cannot clear it. Tags are
	depth-tested like the player title tags (walls / awnings can hide them): an always-on-top
	variant was tried in Studio QA (R87) and those billboards did not render in captures, so it was
	dropped rather than shipped unverified. At a normal
	camera distance (~25 studs) on a phone (~11 pt per stud at FOV 70) the tag is ~67 x 220 pt:
	the name row renders ~24 pt, the "runs" row ~15 pt even for the longest producer name
	("runs Pocket Nuke Workbench"), the chip ~13 pt (owner R11: >= 14 pt main text on phones;
	tests/manager-tags.luau re-checks this). Up close on a 1080p desktop (10 studs) it is ~130 px
	tall, never a wall.
]]
ManagerTagConfig.Tag = {
	StudsWidth = 3.8,
	PixelWidth = 150,
	StudsHeight = 1.1,
	PixelHeight = 46,
	DeviceScale = 1.15,
	HeadGap = 0.3,
	DazedLift = 1.5,
	MaxDistanceOwn = 85,
	MaxDistanceOther = 55,
	ChipHeight = 0.28,
	NameHeight = 0.42,
	RunsHeight = 0.26,
	ChipMinWidth = 0.42,
	ChipMaxWidth = 0.9,
	ChipBase = 0.12,
	ChipPerChar = 0.04,
	ChipTextSize = 22,
	NameTextSize = 40,
	RunsTextSize = 26,
	RunsPrefix = "runs",
	RunsColor = Color3.fromRGB(255, 232, 128),
	YieldCheckRange = 90,
	YieldMargin = 6,
	YieldClearRefreshes = 3,
	NudgeMaxFraction = 0.45,
	NudgeRate = 10,
	NudgeEpsilon = 0.15,
	FullWidthChars = 26,
	MinWidthScale = 0.5,
} :: TagTunables

-- Speech bubbles (owner-only, one per plot at a time, only while the owner is near).
ManagerTagConfig.Bubble = {
	StudsWidthBase = 0.5,
	StudsWidthPerChar = 0.13,
	PixelWidthBase = 26,
	PixelWidthPerChar = 6.2,
	HeightRatio = 0.52,
	Gap = 0.18,
	TextSize = 30,
	IntervalMin = 20,
	IntervalMax = 40,
	FirstDelayMin = 6,
	FirstDelayMax = 12,
	ShowSeconds = 4.5,
	NearRange = 34,
	PopSeconds = 0.2,
} :: BubbleTunables

return ManagerTagConfig
