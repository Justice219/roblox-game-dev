--!strict
--[[
	FtueLogic — the pure rules behind the finer first-minute funnel steps (owner R78 §6):
	`firstMove`, `tutorialSeen`, `firstScreenClosed` (plus the existing `loadingDone` /
	`hudShown`). Shared so the client tracker, the server validation and the lune tests agree.

	Purpose:
		CLIENT (Tycoon/FtueTracker):
			- a MOVE TRACKER: the character must get FtueConfig.Track.MoveStuds (horizontal) away
			  from the point where the player gained control on their plot, by walking: a sample
			  step longer than a walk could cover is a teleport (respawn, portal, the server's
			  walk-home) and re-anchors instead of counting;
			- `hintVisible(facts)`: the tutorial hint is genuinely on screen (loading screen gone,
			  no plot-reveal camera, no window over it, HUD not hidden, a tutorial step with text).
		SERVER (Server/Analytics/Sessions):
			- `claimPlausible(step, facts)`: a client claim is only COUNTED when the server's own
			  state agrees it can be true (the plot reveal finished; a tutorial is running or done;
			  the server-side character really is away from the entrance spawn). A refused claim is
			  never marked, so a later honest one still counts. Nothing is ever granted from these.

	Connects to: Shared/Config/FtueConfig, Tycoon/FtueTracker, Server/Analytics/Sessions,
	tests/ftue-logic.luau.

	Example:
		local move = FtueLogic.newMove()
		FtueLogic.sampleMove(move, 0, 0, 0.25, 16, true)   --> false (anchored)
		FtueLogic.sampleMove(move, 3, 0, 0.25, 16, true)   --> false (3 studs)
		...
		FtueLogic.claimPlausible("firstMove", { plotRevealed = true, tutorialStep = 1, entranceStuds = 14 }) --> true
]]

local FtueConfig = require(script.Parent.Parent.Config.FtueConfig)

local Track = FtueConfig.Track

local FtueLogic = {}

-- Move tracker -------------------------------------------------------------------------------------

export type MoveState = {
	anchored: boolean,
	anchorX: number,
	anchorZ: number,
	lastX: number,
	lastZ: number,
	reached: boolean,
}

--[[ A fresh move tracker (no anchor yet: the first sample anchors it). ]]
function FtueLogic.newMove(): MoveState
	return { anchored = false, anchorX = 0, anchorZ = 0, lastX = 0, lastZ = 0, reached = false }
end

--[[ Re-anchors at (x, z) (a teleport / respawn / walk-home: that spot is the new start). ]]
function FtueLogic.anchor(state: MoveState, x: number, z: number)
	state.anchored = true
	state.anchorX, state.anchorZ = x, z
	state.lastX, state.lastZ = x, z
end

-- True for a finite number (NaN / inf positions are ignored).
local function finite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

--[[
	Feeds one position sample. Returns true ONCE, on the sample that first takes the character
	MoveStuds away from the anchor while the player is steering (`moving`).
	@param state     from newMove
	@param x, z      horizontal root position (studs)
	@param dt        seconds since the previous sample (> 0)
	@param walkSpeed the humanoid's WalkSpeed (bounds a real walk step)
	@param moving    the player is steering (Humanoid.MoveDirection is non-zero)
	@return true the first time the threshold is crossed
	Example: see the module header.
]]
function FtueLogic.sampleMove(
	state: MoveState,
	x: number,
	z: number,
	dt: number,
	walkSpeed: number,
	moving: boolean
): boolean
	if state.reached or not finite(x) or not finite(z) then
		return false
	end
	if not state.anchored then
		FtueLogic.anchor(state, x, z)
		return false
	end
	local step = math.sqrt((x - state.lastX) ^ 2 + (z - state.lastZ) ^ 2)
	local speed = if finite(walkSpeed) and walkSpeed > 0 then walkSpeed else 16
	local span = if finite(dt) and dt > 0 then dt else Track.SampleSeconds
	-- Farther than a walk could go in this sample: a teleport, not a move.
	if step > speed * span * Track.TeleportFactor + Track.MoveSlackStuds then
		FtueLogic.anchor(state, x, z)
		return false
	end
	state.lastX, state.lastZ = x, z
	if not moving then
		return false
	end
	local away = math.sqrt((x - state.anchorX) ^ 2 + (z - state.anchorZ) ^ 2)
	if away >= Track.MoveStuds then
		state.reached = true
		return true
	end
	return false
end

-- Tutorial hint visibility ---------------------------------------------------------------------------

export type HintFacts = {
	loadingDone: boolean, -- the join loading screen handed over
	revealPlaying: boolean, -- the "Your plot is #N!" camera is running / queued
	modalOpen: boolean, -- any window is open (it covers the hint)
	focusMode: boolean, -- the HUD is faded out (egg hatch, attack cinematic, ...)
	hudShown: boolean, -- the HUD screen is enabled
	step: number, -- current tutorial step (0 = none / finished)
	hasText: boolean, -- the objective line has text
}

--[[ True when the tutorial hint (objective chip + arrows) is genuinely visible to the player. ]]
function FtueLogic.hintVisible(facts: HintFacts): boolean
	return facts.loadingDone
		and not facts.revealPlaying
		and not facts.modalOpen
		and not facts.focusMode
		and facts.hudShown
		and facts.step >= 1
		and facts.hasText
end

-- Server plausibility ---------------------------------------------------------------------------------

export type ClaimFacts = {
	plotRevealed: boolean, -- server: the plot reveal finished (player attribute PlotRevealed)
	tutorialStep: number, -- server: profile.tycoon.tutorialStep (0 = never started)
	entranceStuds: number?, -- server: horizontal studs from the root to the plot entrance spawn
}

-- The client steps the server re-checks against its own state (the R78 first-minute steps).
local CHECKED: { [string]: boolean } = { tutorialSeen = true, firstMove = true, firstScreenClosed = true }

--[[ True when `step` needs claimPlausible (the caller only gathers server facts then). ]]
function FtueLogic.checksClaim(step: string): boolean
	return CHECKED[step] == true
end

--[[
	Whether the server should COUNT a client FTUE claim. Steps without a rule (loadingDone,
	hudShown) stay accepted as before (allowlist + once per player).
	@param step  an AnalyticsConfig.Ftue.ClientSteps id (already allowlisted by the caller)
	@param facts the server's own view (never values from the client)
	@return true to count it
	Example: FtueLogic.claimPlausible("tutorialSeen", { plotRevealed = false, tutorialStep = 1 }) --> false
]]
function FtueLogic.claimPlausible(step: string, facts: ClaimFacts): boolean
	if step == "tutorialSeen" then
		return facts.plotRevealed and facts.tutorialStep >= 1
	elseif step == "firstMove" then
		local studs = facts.entranceStuds
		return facts.plotRevealed and studs ~= nil and finite(studs) and studs >= FtueConfig.Claims.ServerMoveStuds
	elseif step == "firstScreenClosed" then
		-- Windows only exist after the loading screen, which ends after the plot was assigned.
		return facts.plotRevealed
	end
	return true
end

--[[
	R135: whether the CLIENT may send a checked first-minute claim yet. Every checked step needs
	the plot reveal finished on the server (claimPlausible: plotRevealed) and the client sends each
	step once per session, so a claim sent while the reveal was still playing was refused and never
	re-sent: 148 "saw the tutorial hint" for 429 first-step hint arrows (report 2026-11-01). The
	client waits for the replicated PlotRevealed attribute (the server's own fact) instead.
	Unchecked steps (loadingDone, hudShown) are always ready.
	@param step         an AnalyticsConfig.Ftue.ClientSteps id
	@param plotRevealed the local player's PlotRevealed attribute is true
	@return true when sending now can be counted
	Example: FtueLogic.claimReady("tutorialSeen", false) --> false
]]
function FtueLogic.claimReady(step: string, plotRevealed: boolean): boolean
	return plotRevealed or not CHECKED[step]
end

return table.freeze(FtueLogic)
