--!strict
--[[
	ClientPerfConfig — tunables for client performance telemetry (perf audit 2026-10-15 row 1).

	Purpose:
		Phones and consoles are invisible from the server: Studio frame times are meaningless
		(a capped, unfocused desktop window) and the Creator Hub dashboard has no per-system split.
		So every client measures itself (Client/Analytics/ClientPerfReporter): a frame-time
		histogram from ONE per-frame accumulator, a low-rate sample of memory / receive bandwidth /
		ping, the boot time and how long the player's own plot takes to stream in ("map ready"). It sends one compact
		report (a fixed-size buffer, `Wire`) about once a minute on the ClientPerf remote. The
		server (Server/Analytics/ClientPerfIngest) treats every number as an untrusted claim:
		fixed layout, finite checks, clamps, a token bucket, and it buckets the values itself
		(Shared/Analytics/ClientPerfLogic) into "health" family analytics counters per device
		class. The admin analytics report shows them as "Client performance by device".
		Analytics ONLY: nothing here changes gameplay, matchmaking, rewards or quality tiers.

	Bucket bounds are upper edges (a value <= bound falls in that bucket; above the last bound is
	the open-ended overflow bucket), shared with ServerHealthLogic.bucketIndex / bucketLabel.

	Connects to: ClientPerfLogic (window math, wire encode / decode, counters, report rows),
	ClientPerfReporter (client), ClientPerfIngest (server), AnalyticsService (records the
	counters), DeviceConfig (the device classes).

	Example:
		local ClientPerfConfig = require(ReplicatedStorage.Shared.Analytics.ClientPerfConfig)
		print(ClientPerfConfig.ReportIntervalSeconds) --> 60
]]

local ClientPerfConfig = {}

-- Wire format version (Wire slot 1). Bump when the layout changes; the server drops any other.
-- (A client always runs the code of the server it joined, so no older version is ever owed.)
-- 2 (2026-10-20): 24 → 39 slots — zero-receive samples, memory-tag groups, instance count,
-- session minutes (see ClientPerfLogic's header for the layout).
-- [WS-B begin] 3 (2026-10-21, money push client memory): 39 → 40 slots — the client FX instance
-- count (descendants of Workspace.ClientFX + Workspace.Terrain) rides every report.
-- [WS-B end]
-- 4 (2026-11-01, owner R122 fast first minute): 40 → 47 slots — the boot-step block (each loading
-- step's completion second + the hand-off reason) rides the report that carries the boot time.
ClientPerfConfig.Version = 4

-- Seconds between reports; the FIRST report goes out sooner so a short session (and its boot
-- time) is still counted. A report needs at least MinFrames rendered frames to be sent.
ClientPerfConfig.ReportIntervalSeconds = 60
ClientPerfConfig.FirstReportSeconds = 20
ClientPerfConfig.MinFrames = 30

-- Seconds between Stats / ping samples inside a window (reads are cheap but not free).
ClientPerfConfig.SampleIntervalSeconds = 5

-- LOCAL LocalPlayer attribute (number, seconds) the ReplicatedFirst Loader writes when it hands
-- off to the game: its own start → the lobby is uncovered. The Loader keeps a literal copy of
-- this name (ReplicatedFirst runs before ReplicatedStorage modules can be required).
ClientPerfConfig.BootAttribute = "BootSeconds"

--[[
	Boot steps (wire v4, owner R122). At its hand-off the Loader (src/first/LoadingScreen, Readiness)
	also sets, BEFORE BootSeconds:
		BootStep<step>  number: that loading step's completion second since the loader start (only
		                steps that finished before the hand-off)
		BootEnd         string: why the screen handed off — "ready" (everything loaded), "budget"
		                (the critical asset preload was cut by Readiness.ASSET_BUDGET), "tap" (the
		                player answered TAP TO CONTINUE), "auto" (AUTO_CONTINUE passed)
	ClientPerfReporter sends them once per session with the boot time. Orders here are the wire
	orders (slot per step, 1-based reason index) and mirror Readiness.stepIds / END_REASONS
	(tests/loading-screen.luau asserts it).
]]
ClientPerfConfig.BootSteps = table.freeze({ "Loaded", "Client", "Profile", "World", "Plot", "Assets" })
ClientPerfConfig.BootEndReasons = table.freeze({ "ready", "budget", "tap", "auto" })
ClientPerfConfig.BootStepAttributePrefix = "BootStep"
ClientPerfConfig.BootEndAttribute = "BootEnd"

-- Map-ready timing: a map counts as arrived once no new descendant replicated under its root for
-- SettleSeconds; a measurement still open after TimeoutSeconds is dropped (not reported).
ClientPerfConfig.MapReady = table.freeze({ SettleSeconds = 0.5, TimeoutSeconds = 60 })

-- Device classes in wire order (Wire slot 2 = index). The first four match
-- DeviceConfig.DeviceClass. "TouchLaptop" (index 5, wire v2) is ANALYTICS ONLY: a device the UI
-- treats as Phone / Tablet (touch preferred, DeviceProfile.hasTouchScreen) that also has a
-- hardware keyboard — Windows touch laptops / 2-in-1s and tablets with a keyboard cover. It keeps
-- their (desktop-class) memory and frame times out of the real-tablet rows. The UI never sees it:
-- only ClientPerfLogic.reportClass maps to it (ClientPerfReporter, at report time).
ClientPerfConfig.DeviceClasses = table.freeze({ "Phone", "Tablet", "Desktop", "Console", "TouchLaptop" })
ClientPerfConfig.TouchKeyboardClass = "TouchLaptop"

--[[
	Histogram / bucket bounds.
		FrameMs: rendered frame time; the edges sit just above common refresh steps so a steady
		  60 Hz frame (16.67 ms) lands in "11.2-16.8" and a steady 30 Hz one in "25.1-33.4":
		  ≥119 / ≥89 / ≥59.5 / ≥50 / ≥40 / ≥30 / ≥20 / ≥15 / ≥10 / <10 fps.
		MemoryMb: Stats:GetTotalMemoryUsageMb() window average (phones crash around 1.5-3 GB).
		  This is the OS PROCESS memory of the Roblox client: the engine's own baseline is
		  included, and on consoles and Apple devices (unified memory) GPU memory is too, so it
		  is not "memory SellNukes allocated" (MemoryTags below splits what the engine can name).
		PingMs:   Player:GetNetworkPing() × 1000, window average.
		ReceiveKbps: Stats.DataReceiveKbps window average (kilobits/s as the engine reports it;
		  usually left at 0 on clients, see Receive below).
		BootSeconds: loading screen start → hand-off to the game (ReplicatedFirst Loader); the
		  boot-step completion seconds (wire v4) use the same buckets.
		MapReadySeconds: the player's plot assigned → its build finished streaming to this client.
]]
-- Frames slower than this (ms; must be one of Buckets.FrameMs) count as "below 30 fps".
ClientPerfConfig.SlowFrameMs = 33.4

ClientPerfConfig.Buckets = table.freeze({
	FrameMs = table.freeze({ 8.4, 11.2, 16.8, 20.1, 25.1, 33.4, 50.1, 66.8, 100.1 }),
	MemoryMb = table.freeze({ 500, 750, 1000, 1500, 2000, 3000, 4000 }),
	PingMs = table.freeze({ 50, 100, 150, 200, 300, 500 }),
	ReceiveKbps = table.freeze({ 50, 100, 200, 400, 800 }),
	BootSeconds = table.freeze({ 5, 10, 15, 20, 30, 45 }),
	MapReadySeconds = table.freeze({ 1, 2, 4, 8, 15 }),
	-- Session age (minutes since the client started) at report time, for leak detection: memory
	-- per age bucket "<5" / "5-15" / "15-30" / "30+" should stay flat in a leak-free build.
	SessionMinutes = table.freeze({ 5, 15, 30 }),
})

--[[
	Sane ranges the SERVER clamps every claim into (anything outside is a lie or a broken client;
	clamping keeps one bad report from skewing an average by orders of magnitude).
	MaxFps bounds frames per claimed second (Roblox renders at most 240 fps uncapped).
	WindowSlackSeconds: a report may claim at most (seconds since this player's previous accepted
	report, or since join) + this many seconds.
]]
ClientPerfConfig.Limits = table.freeze({
	MaxFps = 240,
	MaxWindowSeconds = 120,
	WindowSlackSeconds = 5,
	MaxMemoryMb = 16384,
	MaxPingMs = 5000,
	MaxReceiveKbps = 100000,
	MaxBootSeconds = 600,
	-- Wire v4: a boot step may claim at most BootSeconds + this (both are rounded down to 0.01 s
	-- from the same origin, so an honest step is never above the boot; float32 rounding aside).
	BootStepSlackSeconds = 0.05,
	MaxMapReadySeconds = 300,
	MaxMapsPerReport = 20,
	-- Wire v2 (2026-10-20). Memory-tag groups are clamped to 0..MaxMemoryMb each, and their sum
	-- may be at most GroupSumSlack × the total memory read at the same moments (tags overlap a
	-- little and are read a few ms apart); a block failing that is dropped, the report is kept.
	GroupSumSlack = 1.5,
	MaxInstances = 10000000,
	-- A session-minutes claim is capped by the server's own minutes since join + this slack
	-- (the client clock starts a little earlier, while the place downloads), and by the max.
	SessionSlackMinutes = 2,
	MaxSessionMinutes = 1440,
})

-- [WS-B begin] Server clamp for the wire v3 client FX count (ClientFX + Terrain descendants):
-- a real client holds a few hundred; anything above this is a broken or lying client.
ClientPerfConfig.MaxClientFx = 1000000
-- [WS-B end]

-- Server token bucket per player: one report a minute, the early first one and a teleport flush
-- fit easily; anything faster is dropped silently.
ClientPerfConfig.RateLimit = table.freeze({ Burst = 3, PerSecond = 1 / 25 })

-- Analytics counter key prefix ("health" family): "cp:<class>:<metric>[:<bucket>]".
ClientPerfConfig.KeyPrefix = "cp"

-- Report rows are shown only for classes with at least this many accepted reports (one or two
-- reports from a lone tester are noise, not a device profile).
ClientPerfConfig.MinReportsForRow = 3

--[[
	Memory tags (wire v2, perf investigation 2026-10-20). The campaign showed desktop clients
	averaging 2.27 GB and consoles 1.9 GB, but the total alone cannot say WHAT holds the memory.
	Every IntervalSeconds the client (when Stats.MemoryTrackingEnabled) reads
	Stats:GetMemoryUsageMbForTag for every Enum.DeveloperMemoryTag item and sums them into the
	Groups below (wire order). Tags are resolved BY NAME once at start (Roblox renames tags, e.g.
	PhysicsParts → BaseParts, so both names are listed; a missing name is simply skipped) and an
	engine tag this table does not know yet counts under UnknownGroup, so "untracked"
	(total − every tag) never absorbs a new category. Short = the report labels, same order.
]]
ClientPerfConfig.MemoryTags = table.freeze({
	IntervalSeconds = 30,
	Groups = table.freeze({ "Texture", "Mesh", "Render", "Gui", "Lua", "Instances", "Physics", "Sound", "Other" }),
	Short = table.freeze({ "tex", "mesh", "render", "gui", "lua", "inst", "phys", "sound", "other" }),
	UnknownGroup = "Other",
	TagGroup = table.freeze({
		GraphicsTexture = "Texture",
		GraphicsTextureCharacter = "Texture",
		GraphicsMeshParts = "Mesh",
		GraphicsSolidModels = "Mesh",
		GraphicsSlimModels = "Mesh",
		GeometryCSG = "Mesh",
		GraphicsParts = "Render",
		GraphicsSpatialHash = "Render",
		GraphicsParticles = "Render",
		GraphicsTerrain = "Render",
		Gui = "Gui",
		LuaHeap = "Lua",
		Script = "Lua",
		Signals = "Lua",
		Instances = "Instances",
		PhysicsCollision = "Physics",
		BaseParts = "Physics",
		PhysicsParts = "Physics", -- the old name of BaseParts
		TerrainVoxels = "Physics",
		Sounds = "Sound",
		StreamingSounds = "Sound",
		Internal = "Other",
		HttpCache = "Other",
		Animation = "Other",
		Navigation = "Other",
	} :: { [string]: string }),
})

--[[
	Receive rate n/a rule (perf investigation 2026-10-20): the engine leaves Stats.DataReceiveKbps
	unpopulated (0) on most clients, so its average is meaningless. The report shows "recv n/a"
	when at least NaZeroShare of the samples read 0. Counters stored before wire v2 carry no
	zero-sample count; for them an average below LegacyFloorKbps (no live client receives that
	little while playing) is shown as n/a too.
]]
ClientPerfConfig.Receive = table.freeze({ NaZeroShare = 0.9, LegacyFloorKbps = 2 })

return table.freeze(ClientPerfConfig)
