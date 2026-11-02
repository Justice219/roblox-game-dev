--!strict
--[[
	FtueConfig — tunables of the FIRST MINUTE (owner R78 §6: "first-minute fix" for console,
	phone and tablet; live data 2026-10-31: 6 of 20 new players left right after getting a plot
	without stepping on the free Workbench pad, 3 of them on a console).

	Purpose:
		One place for the numbers the first-minute systems share:
			- GUIDED steps: while the server tutorial step is below GuidedUntilStep (build the
			  Workbench, make the first nukes, buy the first upgrade) nothing else may ask for the
			  player's attention: no join pop-up queue item below Essential priority
			  (Platform/JoinFlow), no Lucky Button edge arrow (Screens/LuckyButtons/LuckyArrowScreen)
			  and no Lucky Button spawn (Server/Services/LuckyButtonService), no notification
			  prompt (Screens/NotifyPrompt).
			- the join pop-up queue (Platform/JoinFlow): priorities and the breathing gap between
			  two pop-ups,
			- the tutorial coach card (Screens/TycoonTutorial): how long it stays,
			- the finer FTUE funnel steps (Tycoon/FtueTracker → FunnelStep → Server/Analytics/
			  Sessions, plausibility in Shared/Analytics/FtueLogic): firstMove distance and the
			  server's plausibility thresholds.
		Display / pacing numbers only: nothing here is a price, a reward or a server-trusted
		timer except the analytics plausibility thresholds (which only decide whether a claim is
		COUNTED; nothing is ever granted from it).

	Connects to: Platform/{JoinFlow, JoinFlowLogic}, Tycoon/{Tutorial, FtueTracker},
	Screens/{TycoonTutorial, LuckyButtons/LuckyArrowScreen, NotifyPrompt},
	Server/Services/LuckyButtonService, Server/Analytics/Sessions, Shared/Analytics/FtueLogic.

	Example:
		if step >= 1 and step < FtueConfig.GuidedUntilStep then -- the guided first minute
]]

local FtueConfig = {}

--[[
	Server tutorial steps (Server/Tycoon/TutorialLogic) BELOW this number are the guided first
	minute: 1 = walk onto the free Workbench pad, 2 = make the first nukes, 3 = buy the first
	upgrade. Step 4 (the Tool Wall) is regular building: the rest of the game may speak again.
	Example: FtueConfig.isGuided(2) --> true; FtueConfig.isGuided(4) --> false
]]
FtueConfig.GuidedUntilStep = 4

--[[ True while a server tutorial step is one of the guided first-minute steps. ]]
function FtueConfig.isGuided(step: number?): boolean
	return type(step) == "number" and step == step and step >= 1 and step < FtueConfig.GuidedUntilStep
end

-- Join pop-up queue (Platform/JoinFlow) ------------------------------------------------------------

FtueConfig.Join = table.freeze({
	-- Higher opens first. Essential items may open during the guided steps (a returning player's
	-- offline cash must never be held back); everything else waits until they are done.
	Priority = table.freeze({
		WelcomeBack = 100,
		TutorialCoach = 95, -- the tutorial's own coach card (non-blocking)
		Essential = 90, -- items at or above this ignore the guided-step hold
		WorldRejoin = 60,
		WhatsNew = 50,
		Notify = 10,
	}),
	-- Seconds of calm (no window, no reveal) after one pop-up closed before the next may open.
	GapSeconds = 1.5,
	-- How often the queue re-checks while something is pending (one loop, only while pending).
	CheckSeconds = 0.25,
	-- A queued pop-up that never found a calm moment is dropped after this long (never stale).
	MaxWaitSeconds = 600,
})

-- Tutorial coach card (Screens/TycoonTutorial) -----------------------------------------------------

FtueConfig.Coach = table.freeze({
	-- The card stays at least this long (seconds) once shown ...
	MinSeconds = 4,
	-- ... and leaves this long after the player's first real move (they got it) ...
	AfterMoveSeconds = 3,
	-- ... and at the latest after this long (never lingers over the play area).
	MaxSeconds = 14,
})

-- Finer FTUE funnel steps (Tycoon/FtueTracker) ------------------------------------------------------

FtueConfig.Track = table.freeze({
	-- firstMove: horizontal studs the character must get from where the player gained control
	-- on their plot (the plot-reveal walk home), by their own input.
	MoveStuds = 12,
	-- One sample every this many seconds (one loop for every tracked step; stops when all sent).
	SampleSeconds = 0.25,
	-- A single sample step longer than WalkSpeed x dt x this + MoveSlackStuds is a teleport
	-- (respawn, portal, server walk-home): the anchor moves there instead of counting it.
	TeleportFactor = 2.5,
	MoveSlackStuds = 6,
	-- The tracker gives up after this long in a session (a player who never moves or never sees
	-- the hint is already visible in the funnel as "did not reach").
	MaxSeconds = 30 * 60,
})

-- Server plausibility of the client FTUE claims (Server/Analytics/Sessions) ------------------------

FtueConfig.Claims = table.freeze({
	-- firstMove: the server-side character must stand at least this far (horizontal studs) from
	-- the plot entrance spawn the reveal walked it to (client MoveStuds minus replication lag).
	ServerMoveStuds = 8,
})

return table.freeze(FtueConfig)
