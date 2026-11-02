--!strict
--[[
	First-minute (FTUE) logic regression — owner R78 §6 "first-minute fix". Run:
		lune run tests/ftue-logic

	Loads the SHIPPED pure modules and proves:
	  1. FtueConfig.isGuided: steps 1..3 are the guided first minute; 0, 4+, NaN are not.
	  2. FtueLogic move tracker (firstMove): the first sample anchors; a 12-stud walk while steering
	     counts exactly once; idle drift (not steering) never counts; a teleport-sized jump
	     re-anchors instead of counting; NaN / inf samples are ignored; a walk that comes back to
	     the anchor never counts.
	  3. FtueLogic.hintVisible: every blocker (loading, reveal, window, focus, hidden HUD, no step,
	     no text) hides the hint.
	  4. FtueLogic.claimPlausible / checksClaim (server): tutorialSeen needs the reveal done and a
	     tutorial; firstMove needs the reveal done and the server-side character ≥ ServerMoveStuds
	     from the entrance spawn; firstScreenClosed needs the reveal; older steps unchanged.
	 4b. R135 FtueLogic.claimReady (client): a checked step waits for the reveal, an unchecked one
	     never waits, and no claim the client deems ready is refused for the reveal alone.
	  5. JoinFlowLogic: blockers in order, the calm gap, highest priority first (oldest on a tie),
	     the guided hold (only Essential items), expiry.
	  6. TutorialText: device-correct objective lines (no "Click" on a gamepad / touch screen),
	     the step-1 pad line, server text kept for later pads, coach tiles in the order the
	     tutorial runs (pads first), the producer's short name.
	  7. Analytics funnel config: Order + SideSteps cover Ftue.Steps exactly once; every client
	     step is a step; furthestStep follows the reading order (plotReady < loadingDone <
	     tutorialSeen < firstMove < firstPad) and ignores side steps; NewPlayerFunnel.rows follow
	     the reading order with side steps last.
	  8. Owner R84 tutorial focus (TutorialFocusLogic): every step -> what the arrow points at
	     (the billboard UPGRADE pill / make bar, the TAP! touch button, the pad), what is ringed
	     and which glyph shows, per device; the fallbacks while a board has not streamed in;
	     words and glyph agree (every objective line names the glyph's control).
	  9. Owner R84 pointer placement (PointerLogic): the arrow sits beside the button, NEVER over
	     it or its board, across a grid of screen positions and every side; side preference,
	     stickiness, blocked HUD zones, the badge behind the tail, the clamped fallback, and the
	     reused `out` table.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local FtueConfig = loader.load("src/shared/Config/FtueConfig")
local FtueLogic = loader.load("src/shared/Analytics/FtueLogic")
local JoinFlowLogic = loader.load("src/client/Platform/JoinFlowLogic")
local TutorialText = loader.load("src/client/Tycoon/TutorialText")
local TutorialFocusLogic = loader.load("src/client/Tycoon/TutorialFocusLogic")
local PointerLogic = loader.load("src/client/UI/Hud/PointerLogic")
local AnalyticsConfig = loader.load("src/shared/Config/AnalyticsConfig")
local AnalyticsMarks = loader.load("src/shared/Config/AnalyticsMarks")
local NewPlayerFunnel = loader.load("src/shared/Analytics/NewPlayerFunnel")

local checks = 0
local function check(condition: any, label: string)
	if not condition then
		error(`FAIL: {label}`, 2)
	end
	checks += 1
end
local function eq(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(`FAIL: {label}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
	checks += 1
end

-- 1. Guided steps -------------------------------------------------------------------------------
check(FtueConfig.isGuided(1) and FtueConfig.isGuided(2) and FtueConfig.isGuided(3), "steps 1..3 guided")
check(
	not FtueConfig.isGuided(0) and not FtueConfig.isGuided(4) and not FtueConfig.isGuided(8),
	"0 / 4 / done not guided"
)
check(not FtueConfig.isGuided(0 / 0) and not FtueConfig.isGuided(nil), "NaN / nil not guided")

-- 2. Move tracker -------------------------------------------------------------------------------
local MOVE = FtueConfig.Track.MoveStuds
local DT = FtueConfig.Track.SampleSeconds
do
	local move = FtueLogic.newMove()
	eq(FtueLogic.sampleMove(move, 100, 50, DT, 16, true), false, "first sample anchors")
	-- Walk +4 studs per sample (16 studs/s at 4 Hz) along x.
	local fired = 0
	local x = 100
	for _ = 1, 6 do
		x += 4
		if FtueLogic.sampleMove(move, x, 50, DT, 16, true) then
			fired += 1
		end
	end
	eq(fired, 1, "a 24-stud walk fires once")
	check(move.reached, "reached flag")
	eq(FtueLogic.sampleMove(move, x + 4, 50, DT, 16, true), false, "never again after reaching")
end
do
	local move = FtueLogic.newMove()
	FtueLogic.sampleMove(move, 0, 0, DT, 16, true)
	local fired = false
	local x = 0
	for _ = 1, 8 do
		x += 3
		fired = fired or FtueLogic.sampleMove(move, x, 0, DT, 16, false)
	end
	check(not fired, "drift without steering never counts")
	-- Now steering: already 24 studs out, the next steering sample counts.
	check(FtueLogic.sampleMove(move, x + 1, 0, DT, 16, true), "steering sample past the threshold counts")
end
do
	local move = FtueLogic.newMove()
	FtueLogic.sampleMove(move, 0, 0, DT, 16, true)
	-- A 200-stud jump (respawn / walk home) re-anchors.
	eq(FtueLogic.sampleMove(move, 200, 0, DT, 16, true), false, "teleport does not count")
	eq(move.anchorX, 200, "teleport re-anchors")
	eq(FtueLogic.sampleMove(move, 204, 0, DT, 16, true), false, "4 studs after the teleport")
	eq(FtueLogic.sampleMove(move, 208, 0, DT, 16, true), false, "8 studs after the teleport")
	eq(FtueLogic.sampleMove(move, 212, 0, DT, 16, true), true, "12 studs after the teleport counts")
end
do
	local move = FtueLogic.newMove()
	FtueLogic.sampleMove(move, 0, 0, DT, 16, true)
	eq(FtueLogic.sampleMove(move, 0 / 0, 0, DT, 16, true), false, "NaN ignored")
	eq(FtueLogic.sampleMove(move, math.huge, 0, DT, 16, true), false, "inf ignored")
	eq(move.anchorX, 0, "anchor untouched by bad samples")
	-- Walk out 8 and back: never 12 away.
	local fired = false
	for _, x in { 4, 8, 4, 0, -4, -8, -4, 0 } do
		fired = fired or FtueLogic.sampleMove(move, x, 0, DT, 16, true)
	end
	check(not fired, "pacing within 8 studs never counts")
	-- A fast character (WalkSpeed 40) moving 10 studs per sample is a walk, not a teleport.
	local fast = FtueLogic.newMove()
	FtueLogic.sampleMove(fast, 0, 0, DT, 40, true)
	eq(FtueLogic.sampleMove(fast, 10, 0, DT, 40, true), false, "fast walk 10")
	eq(FtueLogic.sampleMove(fast, 20, 0, DT, 40, true), true, "fast walk 20 counts")
end
check(MOVE == 12, "spec: firstMove = 12 studs")

-- 3. Hint visibility ------------------------------------------------------------------------------
local function hint(over: { [string]: any }?): any
	local facts: { [string]: any } = {
		loadingDone = true,
		revealPlaying = false,
		modalOpen = false,
		focusMode = false,
		hudShown = true,
		step = 1,
		hasText = true,
	}
	for key, value in over or {} do
		facts[key] = value
	end
	return facts
end
check(FtueLogic.hintVisible(hint()), "hint visible")
check(not FtueLogic.hintVisible(hint({ loadingDone = false })), "loading hides")
check(not FtueLogic.hintVisible(hint({ revealPlaying = true })), "reveal hides")
check(not FtueLogic.hintVisible(hint({ modalOpen = true })), "window hides")
check(not FtueLogic.hintVisible(hint({ focusMode = true })), "focus hides")
check(not FtueLogic.hintVisible(hint({ hudShown = false })), "hidden HUD hides")
check(not FtueLogic.hintVisible(hint({ step = 0 })), "no step")
check(not FtueLogic.hintVisible(hint({ hasText = false })), "no text")

-- 4. Server plausibility --------------------------------------------------------------------------
local SERVER_MOVE = FtueConfig.Claims.ServerMoveStuds
check(FtueLogic.checksClaim("firstMove") and FtueLogic.checksClaim("tutorialSeen"), "R78 steps checked")
check(FtueLogic.checksClaim("firstScreenClosed"), "firstScreenClosed checked")
check(not FtueLogic.checksClaim("loadingDone") and not FtueLogic.checksClaim("hudShown"), "old steps unchanged")
check(FtueLogic.claimPlausible("tutorialSeen", { plotRevealed = true, tutorialStep = 1 }), "tutorialSeen ok")
check(not FtueLogic.claimPlausible("tutorialSeen", { plotRevealed = false, tutorialStep = 1 }), "before reveal")
check(not FtueLogic.claimPlausible("tutorialSeen", { plotRevealed = true, tutorialStep = 0 }), "no tutorial")
check(
	FtueLogic.claimPlausible("firstMove", { plotRevealed = true, tutorialStep = 1, entranceStuds = SERVER_MOVE + 1 }),
	"firstMove away from the entrance"
)
check(
	not FtueLogic.claimPlausible(
		"firstMove",
		{ plotRevealed = true, tutorialStep = 1, entranceStuds = SERVER_MOVE - 1 }
	),
	"firstMove still at the entrance"
)
check(not FtueLogic.claimPlausible("firstMove", { plotRevealed = true, tutorialStep = 1 }), "no character")
check(
	not FtueLogic.claimPlausible("firstMove", { plotRevealed = true, tutorialStep = 1, entranceStuds = 0 / 0 }),
	"NaN distance"
)
check(
	not FtueLogic.claimPlausible("firstMove", { plotRevealed = false, tutorialStep = 1, entranceStuds = 50 }),
	"firstMove before the reveal"
)
check(FtueLogic.claimPlausible("firstScreenClosed", { plotRevealed = true, tutorialStep = 0 }), "window closed ok")
check(
	not FtueLogic.claimPlausible("firstScreenClosed", { plotRevealed = false, tutorialStep = 0 }),
	"window before plot"
)
check(FtueLogic.claimPlausible("loadingDone", { plotRevealed = false, tutorialStep = 0 }), "loadingDone unchanged")

-- 4b. Client readiness (R135) ----------------------------------------------------------------------
for _, step in { "tutorialSeen", "firstScreenClosed", "firstMove" } do
	check(not FtueLogic.claimReady(step, false), `{step} waits for the reveal`)
	check(FtueLogic.claimReady(step, true), `{step} ready after the reveal`)
end
for _, step in { "loadingDone", "hudShown" } do
	check(FtueLogic.claimReady(step, false), `{step} never waits`)
end
-- Alignment: every client step the server checks is refused before the reveal whatever the other
-- facts, so claimReady must hold it back; a ready claim is never refused for the reveal alone.
local allFacts = { plotRevealed = false, tutorialStep = 5, entranceStuds = SERVER_MOVE + 10 }
for _, step in AnalyticsConfig.Ftue.ClientSteps do
	local refusedBeforeReveal = not FtueLogic.claimPlausible(step, allFacts)
	check(
		FtueLogic.claimReady(step, false) == not refusedBeforeReveal,
		`{step}: client readiness matches the server's reveal rule`
	)
end

-- 5. Join queue -----------------------------------------------------------------------------------
local P = FtueConfig.Join.Priority
local GAP = FtueConfig.Join.GapSeconds
local function facts(over: { [string]: any }?): any
	local value: { [string]: any } = {
		now = 100,
		loadingDone = true,
		revealPlaying = false,
		modalOpen = false,
		focusMode = false,
		purchaseFlow = false,
		guided = false,
		calmSince = 100 - GAP - 0.1,
	}
	for key, v in over or {} do
		value[key] = v
	end
	return value
end
local function item(key: string, priority: number, order: number): any
	return { key = key, priority = priority, queuedAt = 50, order = order }
end
do
	local _, why = JoinFlowLogic.pick({}, facts())
	eq(why, "empty", "empty queue")
	local items = { item("WhatsNew", P.WhatsNew, 1), item("WelcomeBack", P.WelcomeBack, 2) }
	eq(select(2, JoinFlowLogic.pick(items, facts({ loadingDone = false }))), "loading", "loading blocks")
	eq(select(2, JoinFlowLogic.pick(items, facts({ revealPlaying = true }))), "reveal", "reveal blocks")
	eq(select(2, JoinFlowLogic.pick(items, facts({ modalOpen = true }))), "modal", "window blocks")
	eq(select(2, JoinFlowLogic.pick(items, facts({ focusMode = true }))), "focus", "focus blocks")
	eq(select(2, JoinFlowLogic.pick(items, facts({ purchaseFlow = true }))), "purchase", "purchase blocks")
	eq(select(2, JoinFlowLogic.pick(items, facts({ calmSince = 100 - GAP + 0.5 }))), "gap", "gap after calm")
	local uncalm = facts()
	uncalm.calmSince = nil
	eq(select(2, JoinFlowLogic.pick(items, uncalm)), "gap", "no calm clock yet")
	eq(JoinFlowLogic.pick(items, facts()).key, "WelcomeBack", "highest priority first")
	local tie = { item("B", 50, 7), item("A", 50, 3) }
	eq(JoinFlowLogic.pick(tie, facts()).key, "A", "oldest request on a tie")
	-- Guided: only Essential (Welcome Back, the coach card) may open.
	local guidedItems = { item("Notify", P.Notify, 1), item("WhatsNew", P.WhatsNew, 2) }
	eq(select(2, JoinFlowLogic.pick(guidedItems, facts({ guided = true }))), "guided", "guided holds the rest")
	table.insert(guidedItems, item("TutorialCoach", P.TutorialCoach, 3))
	eq(JoinFlowLogic.pick(guidedItems, facts({ guided = true })).key, "TutorialCoach", "coach during guided")
	check(JoinFlowLogic.allowedWhileGuided(P.WelcomeBack), "Welcome Back is essential")
	check(not JoinFlowLogic.allowedWhileGuided(P.WhatsNew), "What's New waits")
	check(P.WelcomeBack > P.TutorialCoach and P.TutorialCoach >= P.Essential, "priorities ordered")
	check(JoinFlowLogic.settled(facts()) and not JoinFlowLogic.settled(facts({ modalOpen = true })), "settled")
	local old = item("Old", 10, 1)
	check(JoinFlowLogic.expired(old, 50 + FtueConfig.Join.MaxWaitSeconds + 1), "expired")
	check(not JoinFlowLogic.expired(old, 51), "fresh")
end

-- 6. Tutorial text ----------------------------------------------------------------------------------
local keys = {
	produceKey = "F",
	producePad = "RT",
	produceTouch = "TAP!",
	interactKey = "E",
	interactPad = "X",
	interactTouch = "UPGRADE",
}
do
	local pad1 = TutorialText.objective("pad", "Workbench", 1, "Step on the glowing pad!", "Gamepad", keys)
	eq(pad1, "Walk onto the glowing pad to build your Workbench!", "step-1 pad line")
	eq(
		TutorialText.objective("pad", "Tool Wall", 4, "Buy the Tool Wall!", "Touch", keys),
		"Buy the Tool Wall!",
		"later pad keeps server text"
	)
	eq(
		TutorialText.objective("pad", "Tool Wall", 4, nil, "Touch", keys),
		"Walk onto the Tool Wall pad to buy it!",
		"pad fallback"
	)
	local pad = TutorialText.objective("click", "Workbench", 2, "Click your Workbench!", "Gamepad", keys)
	eq(pad, "Press RT at your Workbench to make nukes!", "gamepad click line")
	local touch = TutorialText.objective("click", "Workbench", 2, nil, "Touch", keys)
	eq(touch, "Tap TAP! at your Workbench to make nukes!", "touch click line")
	local kbm = TutorialText.objective("click", "Workbench", 2, nil, "KeyboardMouse", keys)
	eq(kbm, "Press F or click your Workbench to make nukes!", "keyboard click line")
	check(not string.find(pad, "Click") and not string.find(touch, "Click"), "no 'Click' off the mouse")
	-- Owner R84: the upgrade line names the button AND the UPGRADE pill it presses.
	eq(
		TutorialText.objective("upgrade", "Workbench", 3, nil, "Gamepad", keys),
		"Press X to UPGRADE your Workbench!",
		"gamepad upgrade"
	)
	eq(
		TutorialText.objective("upgrade", "Workbench", 3, nil, "Touch", keys),
		"Tap UPGRADE on your Workbench!",
		"touch upgrade"
	)
	eq(
		TutorialText.objective("upgrade", "Workbench", 3, nil, "weird", keys),
		"Press E or click UPGRADE on your Workbench!",
		"unknown mode = keyboard"
	)
	eq(
		TutorialText.objective("mystery", "x", 9, "Server line", "Touch", keys),
		"Server line",
		"unknown kind keeps server text"
	)
	-- Coach tiles: pads first (the tutorial's real order).
	eq(TutorialText.coach(1, "Gamepad", keys), "Walk onto glowing pads", "coach tile 1 = pads")
	eq(TutorialText.coach(2, "KeyboardMouse", keys), "Click or press F for nukes", "coach tile 2 keyboard")
	eq(TutorialText.coach(2, "Gamepad", keys), "Press RT to make nukes", "coach tile 2 gamepad")
	eq(TutorialText.coach(2, "Touch", keys), "Tap TAP! to make nukes", "coach tile 2 touch")
	eq(TutorialText.coach(3, "Touch", keys), "Upgrade & hire managers", "coach tile 3")
	eq(TutorialText.coach(4, "Touch", keys), "", "coach unknown tile")
	eq(TutorialText.shortName("Pocket Nuke Workbench", "Workbench"), "Workbench", "short name from builder pad")
	eq(TutorialText.shortName("Pocket Nuke Workbench", nil), "Pocket Nuke Workbench", "short name fallback")
end

-- 7. Analytics funnel config -------------------------------------------------------------------------
local Ftue = AnalyticsConfig.Ftue
do
	local seen: { [string]: number } = {}
	for _, step in Ftue.Order do
		seen[step] = (seen[step] or 0) + 1
	end
	for _, step in Ftue.SideSteps do
		seen[step] = (seen[step] or 0) + 1
	end
	for _, step in Ftue.Steps do
		eq(seen[step], 1, `step {step} in exactly one of Order / SideSteps`)
		seen[step] = nil
	end
	eq(next(seen), nil, "Order / SideSteps hold no unknown ids")
	for _, step in Ftue.ClientSteps do
		check(table.find(Ftue.Steps, step) ~= nil, `client step {step} is a step`)
	end
	for _, step in { "firstScreenClosed", "tutorialSeen", "firstMove" } do
		check(table.find(Ftue.ClientSteps, step) ~= nil, `{step} is a client step`)
	end
	-- Save data is append-only: the original 15 bits keep their positions.
	eq(Ftue.Steps[1], "joined", "bit 0")
	eq(Ftue.Steps[4], "firstPad", "bit 3")
	eq(Ftue.Steps[15], "hudShown", "bit 14")
	eq(Ftue.Steps[18], "firstMove", "bit 17")
end
eq(
	AnalyticsMarks.furthestStep({ joined = true, plotReady = true, loadingDone = true }),
	"loadingDone",
	"loading after plot"
)
eq(
	AnalyticsMarks.furthestStep({ joined = true, plotReady = true, loadingDone = true, tutorialSeen = true }),
	"tutorialSeen",
	"saw the hint"
)
eq(
	AnalyticsMarks.furthestStep({
		plotReady = true,
		tutorialSeen = true,
		firstMove = true,
		hudShown = true,
		firstScreenClosed = true,
	}),
	"firstMove",
	"moved; side steps ignored"
)
eq(AnalyticsMarks.furthestStep({ firstMove = true, firstPad = true }), "firstPad", "pad beats move")
eq(AnalyticsMarks.furthestStep({ hudShown = true }), "none", "side step alone is no progress")
do
	local core = { ["ftue:joined"] = 10, ["ftue:plotReady"] = 10, ["ftue:loadingDone"] = 8, ["ftue:hudShown"] = 8 }
	local rows = NewPlayerFunnel.rows(core, function(f: number): string
		return `{math.floor(f * 100)}%`
	end)
	eq(rows[1].id, "joined", "rows start at joined")
	eq(rows[2].id, "plotReady", "plot second")
	eq(rows[3].id, "loadingDone", "loading third")
	eq(rows[4].id, "tutorialSeen", "hint fourth")
	eq(rows[5].id, "firstMove", "move fifth")
	eq(rows[6].id, "firstPad", "pad sixth")
	eq(rows[#rows].id, "firstScreenClosed", "side steps last")
	eq(rows[#rows - 1].id, "hudShown", "hudShown side step")
	check(string.find(rows[3].extra, "80% of previous step", 1, true) ~= nil, "loading ratio vs plot")
	check(string.find(rows[#rows - 1].extra, "previous step", 1, true) == nil, "side step has no previous ratio")
	eq(#rows, #Ftue.Steps, "one row per step")
end

-- 8. Owner R84 tutorial focus -------------------------------------------------------------------------
do
	local function facts(over: { [string]: boolean }?): any
		local base = { billboard = true, touchProduce = false, touchInteract = false, padLabel = true }
		for key, value in over or {} do
			(base :: any)[key] = value
		end
		return base
	end
	-- Upgrade: the arrow points at the billboard's UPGRADE pill on every device.
	for _, mode in { "Gamepad", "KeyboardMouse", "Touch" } do
		local focus = TutorialFocusLogic.focus("upgrade", mode, facts())
		eq(focus.point, "upgrade", `upgrade points at the UPGRADE pill ({mode})`)
		eq(focus.rings[1], "upgrade", `upgrade rings the pill ({mode})`)
		eq(focus.sides[1], "below", `upgrade arrow comes from under the board ({mode})`)
	end
	eq(TutorialFocusLogic.focus("upgrade", "Gamepad", facts()).glyph, "interact", "gamepad upgrade glyph = X")
	eq(TutorialFocusLogic.focus("upgrade", "KeyboardMouse", facts()).glyph, "interact", "keyboard upgrade glyph = E")
	eq(TutorialFocusLogic.focus("upgrade", "Touch", facts()).glyph, "tap", "touch upgrade glyph = tap hand")
	-- Touch: the on-screen UPGRADE button is ringed too (only while it is shown).
	local touchUp = TutorialFocusLogic.focus("upgrade", "Touch", facts({ touchInteract = true }))
	eq(#touchUp.rings, 2, "touch upgrade rings pill + touch button")
	eq(touchUp.rings[2], "touchInteract", "touch UPGRADE button ringed")
	eq(#TutorialFocusLogic.focus("upgrade", "Gamepad", facts({ touchInteract = true })).rings, 1, "no touch ring off touch")
	-- No board yet: the old behaviour (arrow over the producer), nothing ringed, no glyph.
	local noBoard = TutorialFocusLogic.focus("upgrade", "Gamepad", facts({ billboard = false }))
	eq(noBoard.point, "world", "upgrade without a board points at the producer")
	eq(#noBoard.rings, 0, "nothing ringed without a board")
	eq(noBoard.glyph, nil, "no glyph without a board")
	-- Click: the make bar (CLICK) on gamepad / keyboard; the TAP! button on touch once shown.
	local padClick = TutorialFocusLogic.focus("click", "Gamepad", facts())
	eq(padClick.point, "make", "gamepad click points at the make bar")
	eq(padClick.glyph, "produce", "gamepad click glyph = RT")
	eq(padClick.sides[1], "left", "make bar arrow comes from the side (never through UPGRADE)")
	check(padClick.sides[1] ~= "below", "make bar never pointed at from below")
	eq(TutorialFocusLogic.focus("click", "KeyboardMouse", facts()).glyph, "produce", "keyboard click glyph = F")
	-- Touch with TAP! shown: TAP! is ringed; the arrow + tap hand go to the board's make bar (the
	-- thumb cluster is drawn above the HUD, so an arrow beside TAP! would be hidden: Studio QA).
	local tapClick = TutorialFocusLogic.focus("click", "Touch", facts({ touchProduce = true }))
	eq(tapClick.point, "make", "touch click arrow at the make bar (visible above the 3D view)")
	eq(tapClick.glyph, "tap", "touch click glyph = tap hand")
	eq(tapClick.sides[1], "left", "make bar arrow from the side")
	eq(tapClick.rings[1], "touchProduce", "TAP! ringed")
	eq(tapClick.rings[2], "make", "make bar ringed too on touch")
	local tapOnly = TutorialFocusLogic.focus("click", "Touch", facts({ touchProduce = true, billboard = false }))
	eq(tapOnly.point, "touchProduce", "no board yet: the arrow falls back to TAP!")
	eq(tapOnly.sides[1], "above", "touch button arrow comes from above (thumb corner)")
	local farTouch = TutorialFocusLogic.focus("click", "Touch", facts())
	eq(farTouch.point, "make", "touch far away: the make bar (tappable) until TAP! shows")
	eq(TutorialFocusLogic.focus("click", "Gamepad", facts({ touchProduce = true })).point, "make", "TAP! only on touch")
	eq(TutorialFocusLogic.focus("click", "Gamepad", facts({ billboard = false })).point, "world", "click fallback")
	-- Pads: the arrow stays on the pad (walk onto it), its price button is ringed, no glyph.
	local pad = TutorialFocusLogic.focus("pad", "Gamepad", facts())
	eq(pad.point, "world", "pad points at the pad")
	eq(pad.rings[1], "padPrice", "pad price ringed")
	eq(pad.glyph, nil, "pad steps show no button glyph (the line says walk)")
	eq(#TutorialFocusLogic.focus("pad", "Touch", facts({ padLabel = false })).rings, 0, "no label, no ring")
	eq(TutorialFocusLogic.focus("mystery", "Touch", facts()).point, "world", "unknown kind = the part")
	eq(#TutorialFocusLogic.focus("mystery", "Touch", facts()).rings, 0, "unknown kind rings nothing")
	-- Touch helpers.
	check(TutorialFocusLogic.isTouchControl("touchProduce"), "TAP! is a touch control")
	check(not TutorialFocusLogic.isTouchControl("upgrade"), "UPGRADE pill is a billboard control")
	eq(TutorialFocusLogic.touchAction("touchProduce"), "Produce", "TAP! = Produce")
	eq(TutorialFocusLogic.touchAction("touchInteract"), "Interact", "UPGRADE button = Interact")
	eq(TutorialFocusLogic.touchAction("make"), nil, "make bar has no touch action")
	-- Glyph captions per device.
	eq(TutorialFocusLogic.glyphLabel("interact", "Gamepad", keys), "X", "X on a gamepad")
	eq(TutorialFocusLogic.glyphLabel("interact", "KeyboardMouse", keys), "E", "E on a keyboard")
	eq(TutorialFocusLogic.glyphLabel("produce", "Gamepad", keys), "RT", "RT on a gamepad")
	eq(TutorialFocusLogic.glyphLabel("produce", "weird", keys), "F", "unknown mode = keyboard F")
	eq(TutorialFocusLogic.glyphLabel("tap", "Touch", keys), "TAP", "tap hand caption")
	local psKeys = table.clone(keys)
	psKeys.interactPad = "Square"
	eq(TutorialFocusLogic.glyphLabel("interact", "Gamepad", psKeys), "Square", "Square on a PlayStation")
	-- Words and glyph never disagree: every line names the glyph's control (owner R84 §3).
	for _, kind in { "click", "upgrade" } do
		for _, mode in { "Gamepad", "KeyboardMouse" } do
			for _, set in { keys, psKeys } do
				local focus = TutorialFocusLogic.focus(kind, mode, facts())
				local label = TutorialFocusLogic.glyphLabel(focus.glyph :: any, mode, set)
				local line = TutorialText.objective(kind, "Workbench", 3, nil, mode, set)
				check(string.find(line, label, 1, true) ~= nil, `{kind}/{mode}: "{line}" names {label}`)
			end
		end
	end
	-- Touch: the line names the ringed / pointed touch control's caption.
	check(
		string.find(TutorialText.objective("click", "Workbench", 2, nil, "Touch", keys), keys.produceTouch, 1, true)
			~= nil,
		"touch click line names TAP!"
	)
	check(
		string.find(TutorialText.objective("upgrade", "Workbench", 3, nil, "Touch", keys), keys.interactTouch, 1, true)
			~= nil,
		"touch upgrade line names UPGRADE"
	)
	check(
		string.find(TutorialText.objective("upgrade", "Workbench", 3, nil, "KeyboardMouse", keys), "UPGRADE", 1, true)
			~= nil,
		"keyboard upgrade line names the UPGRADE pill"
	)
end

-- 9. Owner R84 pointer placement -----------------------------------------------------------------------
do
	local ARROW, GAP, BOB, BADGE = 84, 10, 10, 62
	local bounds = { x0 = 35, y0 = 35, x1 = 1885, y1 = 1045 }
	-- A billboard 200 x 160 px whose UPGRADE pill is its bottom row, centred at (cx, cy).
	local function board(cx: number, cy: number): (any, any)
		local avoid = { x0 = cx - 100, y0 = cy - 80, x1 = cx + 100, y1 = cy + 80 }
		local target = { x0 = cx - 64, y0 = cy + 30, x1 = cx + 68, y1 = cy + 74 }
		return target, avoid
	end
	local function input(target: any, avoid: any, over: { [string]: any }?): any
		local base = {
			target = target,
			avoid = avoid,
			arrow = ARROW,
			gap = GAP,
			bob = BOB,
			badgeW = BADGE,
			badgeH = BADGE,
			bounds = bounds,
			blocked = {},
			order = { "below", "left", "right", "above" },
			previous = nil,
		}
		for key, value in over or {} do
			base[key] = value
		end
		return base
	end
	-- Centre of the screen: under the board, pointing up, tip just under the board.
	local target, avoid = board(960, 500)
	local placed = PointerLogic.place(input(target, avoid))
	eq(placed.side, "below", "free screen: under the board")
	eq(placed.rotation, -180, "pointing up")
	eq(placed.y - ARROW / 2, avoid.y1 + GAP, "arrow tip a gap under the board")
	eq(placed.x, (target.x0 + target.x1) / 2, "arrow centred on the button")
	check(placed.badgeY > placed.y, "badge behind the arrow's tail")
	check(placed.fits, "fits")
	-- Never over the button or its board: a grid of board positions x every preference order.
	local orders = {
		{ "below", "left", "right", "above" },
		{ "left", "right", "above", "below" },
		{ "above", "left", "right", "below" },
	}
	local overlapsFound = 0
	for x = 150, 1800, 75 do
		for y = 120, 980, 70 do
			local t, a = board(x, y)
			for _, order in orders do
				local result = PointerLogic.place(input(t, a, { order = order }))
				if result.fits then
					local arrowBox = PointerLogic.arrowBox(result, ARROW)
					if PointerLogic.overlaps(arrowBox, a) or PointerLogic.overlaps(arrowBox, t) then
						overlapsFound += 1
					end
					local half = BADGE / 2
					local badgeBox = {
						x0 = result.badgeX - half,
						y0 = result.badgeY - half,
						x1 = result.badgeX + half,
						y1 = result.badgeY + half,
					}
					if PointerLogic.overlaps(badgeBox, a) then
						overlapsFound += 1
					end
				end
			end
		end
	end
	eq(overlapsFound, 0, "a fitted arrow / badge never covers the button or its board")
	-- Near the bottom edge: "below" does not fit -> the next side.
	local lowT, lowA = board(960, 880)
	local low = PointerLogic.place(input(lowT, lowA))
	eq(low.side, "left", "bottom edge: from the left")
	eq(low.rotation, -90, "pointing right")
	eq(low.x + ARROW / 2, lowA.x0 - GAP, "tip a gap left of the board")
	check(low.badgeX < low.x, "badge left of the arrow")
	-- Sticky: the previous side is kept while it fits (no flip-flop).
	local sticky = PointerLogic.place(input(target, avoid, { previous = "right" }))
	eq(sticky.side, "right", "previous side kept while it fits")
	eq(sticky.rotation, 90, "pointing left")
	local bogus = PointerLogic.place(input(target, avoid, { previous = "diagonal" }))
	eq(bogus.side, "below", "unknown previous side ignored")
	-- A blocked HUD zone under the board pushes the arrow to another side.
	local blockedBelow = PointerLogic.place(input(target, avoid, {
		blocked = { { x0 = 700, y0 = avoid.y1 + 20, x1 = 1200, y1 = avoid.y1 + 300 } },
	}))
	eq(blockedBelow.side, "left", "objective chip under the board: from the left")
	-- Touch button in the thumb corner: from above first.
	local touchT = { x0 = 1700, y0 = 860, x1 = 1800, y1 = 960 }
	local touch = PointerLogic.place(input(touchT, touchT, { order = { "above", "left", "right", "below" } }))
	eq(touch.side, "above", "touch button: from above")
	eq(touch.rotation, 0, "pointing down")
	eq(touch.y + ARROW / 2, touchT.y0 - GAP, "tip a gap above the touch button")
	-- No badge: the box is just the arrow (+ bob).
	local noBadge = PointerLogic.place(input(lowT, lowA, { badgeW = 0, badgeH = 0 }))
	check(noBadge.fits, "no badge still places")
	-- Nothing fits (tiny bounds): first preference, clamped into the bounds, fits = false.
	local tiny = { x0 = 900, y0 = 400, x1 = 1020, y1 = 640 }
	local clamped = PointerLogic.place(input(target, avoid, { bounds = tiny }))
	check(not clamped.fits, "nothing fits -> fits = false")
	eq(clamped.side, "below", "fallback = first preference")
	check(clamped.y + ARROW / 2 <= tiny.y1 + 0.001, "fallback clamped into the bounds")
	-- `out` is reused (HudObjective passes one table every frame).
	local out = PointerLogic.place(input(target, avoid))
	local again = PointerLogic.place(input(lowT, lowA), out)
	check(again == out, "place fills the given table")
	eq(out.side, "left", "reused table carries the new result")
	-- Rotation helper: the down-pointing glyph.
	eq(PointerLogic.rotationFor(0, 1), 0, "down = 0")
	eq(PointerLogic.rotationFor(1, 0), -90, "right = -90")
	eq(PointerLogic.rotationFor(-1, 0), 90, "left = 90")
	check(PointerLogic.overlaps({ x0 = 0, y0 = 0, x1 = 10, y1 = 10 }, { x0 = 5, y0 = 5, x1 = 15, y1 = 15 }), "overlap")
	check(
		not PointerLogic.overlaps({ x0 = 0, y0 = 0, x1 = 10, y1 = 10 }, { x0 = 10, y0 = 0, x1 = 20, y1 = 10 }),
		"touching edges do not overlap"
	)
end

print(`[ftue-logic] {checks} checks passed`)
