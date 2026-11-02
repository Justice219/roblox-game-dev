--!strict
--[[
	PopupQueueConfig — tunables of the client popup priority queue (owner R102: "sometimes UI will
	clip like this when it pops up, need a priority queue").

	Purpose:
		Every transient centre popup (reveals, banners), the centre-top chips and the toast stack go
		through UI/Widgets/PopupQueue. This file says, per popup KIND, which channel it uses, how
		important it is, how long it may wait for its turn, what happens when something more
		important cuts in, and where it sits. Numbers only; presentation never affects game state.

	Channels:
		center  the ATTENTION lane: one big moment at a time, highest priority first (plot reveal >
		        flavour reveal > Happy Hour > juice); lower ones wait (maxWait) or
		        are pre-empted (preempt). Most sit in the top band under the currency stack; the
		        flavour reveal (anchor "feed", owner R108) plays as a card in the bottom-left FEED.
		chip    persistent centre-top chips (the Lucky Button arrow, the Happy Hours pill): hidden
		        while a centre popup is up, never over the HUD's reserved bottom strip.
		feed    the bottom-left column (owner R108 + R111, `Feed` below): every toast and the Big Pop
		        pills (UI/Hud/Toasts, newest at the bottom) + the reveal card under them.

	Kind fields:
		channel        "center" | "chip"
		priority       higher wins; equal priorities are first-come
		maxWait        seconds a queued popup may wait for its turn before it expires (0 = never waits)
		preempt        "resume" (back in the queue with a fresh maxWait; replays its FULL hold, so a
		               popup is never shorter than before R102) | "drop"
		replaceActive  a newer popup of the same kind replaces the one on screen (after minShow)
		minShow        seconds the shown popup stays before a newer one of its kind may replace it
		waitForModal   waits while a menu window is open (else it would draw under / around it)
		waitForFocus   waits while a cinematic (focus mode: hatch, launch cam, loading) is up
		anchor         "top" (just under the currency stack) | "bottom" (just above the objective
		               chip / hint bar) | "fill" (full-screen: owns the whole band) | "feed" (a card
		               at the bottom of the bottom-left feed column)

	Connects to: Shared/Config/{FlavorConfig (reveal wait), JuiceConfig (milestone replace cooldown)},
	UI/Widgets/{PopupQueue, PopupQueueLogic, FeedLogic}, presenters Tycoon/Fx/{BigPopBanner,
	JuiceBanner}, Tycoon/{FlavorController, PlotReveal}, HappyHour/HappyHourClient, UI/Hud/Toasts,
	UI/Screens/{FlavorReveal, LuckyButtons/LuckyArrowScreen, HappyHour/HappyHourChipScreen},
	tests/{popup-queue, popup-feed}.luau.

	Example: PopupQueueConfig.Kinds.happyHour.priority --> 70
	Example: PopupQueueConfig.Feed.Flavor.CardCooldown --> 300
]]

local FlavorConfig = require(script.Parent.FlavorConfig)
local JuiceConfig = require(script.Parent.JuiceConfig)

export type Channel = "center" | "chip"
export type Preempt = "resume" | "drop"
export type Anchor = "top" | "bottom" | "fill" | "feed"

export type KindDef = {
	channel: Channel,
	priority: number,
	maxWait: number,
	preempt: Preempt,
	replaceActive: boolean,
	minShow: number,
	waitForModal: boolean,
	waitForFocus: boolean,
	anchor: Anchor,
}

local PopupQueueConfig = {}

-- Owner R102 order: plot reveal (join cinematic) > flavour reveal > Happy Hour start > juice
-- milestone; chips: Lucky arrow > Happy pill. Big Pop left the lane in R108 (a feed pill); the
-- centre flavour shout was removed in R120 ("these popups are real annoying"): no Lucky Nuke ever
-- shows centre-screen — they are feed pills (Feed.Flavor) or the first-find reveal card. Owner R122
-- adds the Lucky DEAL card (above juice: the player just walked into the button), the notification
-- opt-in card and the invite moment (below juice: never urgent).
PopupQueueConfig.Kinds = table.freeze({
	-- "Your plot is #N!" join fly-over: claims the centre lane while the camera swoops (a hold).
	plotReveal = table.freeze({
		channel = "center",
		priority = 100,
		maxWait = 0,
		preempt = "drop",
		replaceActive = true,
		minShow = 0,
		waitForModal = false,
		waitForFocus = false,
		anchor = "top",
	}) :: KindDef,
	-- The owner's Lucky Nuke reveal card (R108: bottom-left feed card, no letterbox / HUD fade;
	-- R120: only a FIRST find of a flavour per world, at most every Feed.Flavor.CardCooldown).
	-- Scheduled in the attention lane so banners still wait for it; FlavorController keeps its own
	-- Reveal.HoldSeconds wait chain.
	flavorReveal = table.freeze({
		channel = "center",
		priority = 90,
		maxWait = FlavorConfig.Reveal.HoldSeconds,
		preempt = "drop",
		replaceActive = false,
		minShow = 0,
		waitForModal = true,
		waitForFocus = true,
		anchor = "feed",
	}) :: KindDef,
	-- NUKEY'S HAPPY HOUR start banner (once per event instance; HappyHourClient also retries).
	happyHour = table.freeze({
		channel = "center",
		priority = 70,
		maxWait = 30,
		preempt = "resume",
		replaceActive = false,
		minShow = 0,
		waitForModal = true,
		waitForFocus = true,
		anchor = "top",
	}) :: KindDef,
	-- Owner R122 (spec §2.4): a paid Lucky Button's small DEAL card (UI/Screens/DealCard, bottom-left
	-- feed card) shown when the player walks into it — only its BUY opens the Robux prompt. The
	-- player is standing at the button, so it waits only briefly; a more important popup drops it
	-- (walking in again shows it again). Presenter-driven (the card ends it).
	luckyDeal = table.freeze({
		channel = "center",
		priority = 60,
		maxWait = 4,
		preempt = "drop",
		replaceActive = true,
		minShow = 0,
		waitForModal = true,
		waitForFocus = true,
		anchor = "feed",
	}) :: KindDef,
	-- Producer milestone "LEVEL 50!" (a newer milestone replaces it after JuiceConfig's 0.5 s
	-- BannerCooldown, exactly as before R102).
	juice = table.freeze({
		channel = "center",
		priority = 50,
		maxWait = 5,
		preempt = "resume",
		replaceActive = true,
		minShow = JuiceConfig.Milestone.BannerCooldown,
		waitForModal = true,
		waitForFocus = true,
		anchor = "top",
	}) :: KindDef,
	-- Owner R122 (spec §2.3): the notification opt-in card (UI/Screens/NotifyPrompt, a modal window)
	-- at its moment: first manager hire, else area 2, else the fallback timer (NotifyConfig.Prompt).
	-- Above the invite moment (both can follow area 2), below juice. Presenter-driven: the card ends
	-- its slot when it closes; only a cinematic that must cut in (plot reveal) closes it.
	notifyPrompt = table.freeze({
		channel = "center",
		priority = 40,
		maxWait = 90, -- = NotifyConfig.Prompt.MaxWaitSeconds (tests/return-notify-prompt checks)
		preempt = "drop",
		replaceActive = false,
		minShow = 0,
		waitForModal = true,
		waitForFocus = true,
		anchor = "fill",
	}) :: KindDef,
	-- Owner R122 (spec §2.4): the once-per-session invite moment (UI/Screens/InviteMoment: a small
	-- non-modal feed card, INVITE / LATER) after area 2 is unlocked. Low priority: it waits behind
	-- every other moment (Client/Social/InviteClient retries later when it expires); a more
	-- important moment that cuts in ends it (once shown, it never comes back that session).
	inviteMoment = table.freeze({
		channel = "center",
		priority = 30,
		maxWait = 60,
		preempt = "drop",
		replaceActive = false,
		minShow = 0,
		waitForModal = true,
		waitForFocus = true,
		anchor = "feed",
	}) :: KindDef,
	-- Persistent chips (no queue: they only yield; see the chip rules in PopupQueueLogic).
	luckyArrow = table.freeze({
		channel = "chip",
		priority = 20,
		maxWait = 0,
		preempt = "drop",
		replaceActive = false,
		minShow = 0,
		waitForModal = false,
		waitForFocus = false,
		anchor = "top",
	}) :: KindDef,
	happyHourChip = table.freeze({
		channel = "chip",
		priority = 10,
		maxWait = 0,
		preempt = "drop",
		replaceActive = false,
		minShow = 0,
		waitForModal = false,
		waitForFocus = false,
		anchor = "top",
	}) :: KindDef,
})

-- The free band the centre lane and the toast stack live in (design px on the HUD canvas).
PopupQueueConfig.Band = table.freeze({
	TopGap = 14, -- under the currency stack (Top / TopRight / Boosts zones + the measured stack)
	BottomGap = 14, -- above the objective chip (Bottom zone) and the hint bar (measured live)
	MinTop = 150, -- the band never starts higher than this (no HUD zone known yet)
	EdgeMargin = 10, -- kept from the canvas bottom when no bottom zone is known
	-- The centre lane is this wide (centred); TopRight only lowers the band when it reaches into it.
	LaneWidth = 860,
})

-- The bottom-left FEED (owner R108 Big Pop + reveal, owner R111 every toast). Design px on the HUD
-- canvas unless noted; pure rules in UI/Widgets/FeedLogic, the stack in UI/Hud/Toasts.
PopupQueueConfig.Feed = table.freeze({
	Margin = 16, -- from the canvas left / bottom edges (no touch reserve)
	Gap = 12, -- from the left grid, objective chip, hint bar, a centre popup, an open window
	RowGap = 8, -- between stacked pills
	MaxWidth = 560, -- column / pill width cap (desktop, tablet, console)
	PhoneMaxWidth = 460, -- phones: the smaller pill (owner R108)
	MinWidth = 300, -- a narrower gap moves the column (above the obstacle / beside the grid)
	MinRows = 2, -- the column wants room for this many pills before it moves beside the grid
	-- One-line pill (desktop design px); phones size the text from points (>= 14 pt, owner R111).
	PillHeight = 48,
	TextSize = 24,
	PhoneTextPoints = 15,
	PillHeightPerText = 1.8, -- phone pill height = text size x this (2 pills fit above an iPhone 14 reserve)
	MaxLines = 2, -- a long toast wraps to two lines, then its text scales down
	IconFill = 0.78, -- icon side = pill height x this
	PadX = 10,
	-- Stack rules.
	MaxVisible = 4, -- owner R111: at most 4; a 5th makes the oldest fade early
	BigPopMax = 3, -- owner R108: at most 3 Big Pop pills (the oldest fades early)
	BigPopSeconds = 5, -- owner R108: each Big Pop pill about 5 s
	MergeSeconds = 4, -- owner R111: same-kind toasts this close merge into one "x3" pill
	MaxWait = 20, -- a toast that cannot show yet (a window leaves no gutter) waits at most this long
	MaxPending = 6, -- waiting toasts kept (oldest dropped first)
	ResumeFloor = 1, -- a paused pill that comes back keeps at least this much screen time
	FadeIn = 0.16,
	FadeOut = 0.25,
	-- Colours / icons by toast kind (the same as StudUI.toast's, owner R111 "keep colours by kind").
	KindColors = table.freeze({
		info = "blue",
		success = "green",
		error = "red",
		reward = "yellow",
		purchase = "purple",
	}),
	KindIcons = table.freeze({
		info = "Star",
		success = "Check",
		error = "Lock",
		reward = "Gift",
		purchase = "Robux",
	}),
	-- The owner's reveal card (UI/Screens/FlavorReveal) at the bottom of the column (R120: with the
	-- Flavour Book claim line, so it is a little taller).
	Card = table.freeze({
		Width = 540,
		Height = 300,
		MinFit = 0.7, -- shrinks to fit the column, never below this (phones: never under 14 pt text)
		SkipWidth = 150,
		SkipHeight = 60, -- >= 44 pt everywhere (raised on small scales)
	}),
	-- Lucky Nukes in the feed (owner R120: "these popups are real annoying bro ngl"; rules in
	-- Client/Tycoon/FlavorFeedLogic, routing in Tycoon/FlavorController).
	Flavor = table.freeze({
		CardCooldown = 300, -- the reveal card (first finds only) at most once per 5 minutes
		MergeSeconds = 6, -- same-flavour pills inside this window merge ("GALAXY x3 +$95M")
		PillSeconds = 3.5,
		-- The common flavours: no pill at all after their first find (just the income pop).
		QuietIds = table.freeze({ sprinkle = true, glitter = true }),
		BigPopGap = 30, -- other players' Big Pops: at most one pill per 30 s, the rest coalesced
		DiscoverySuppress = 8, -- the server's "New Lucky Nuke" toast is dropped this long after its card
		-- Pill words until FlavorConfig.Text defines FeedPill / FeedPillMerged / FeedAmount (owner
		-- R112: every Lucky Nuke word lives there; those keys win when present).
		PillText = "%s nukes %s", -- "GALAXY nukes x20"
		PillMergedText = "%s x%d", -- "GALAXY x3"
		PillAmountText = " +%s", -- " +$31.8M"
	}),
})

-- Runtime pacing.
PopupQueueConfig.PollSeconds = 0.5 -- re-check gates this often ONLY while a popup waits on one
PopupQueueConfig.MaxShowSeconds = 30 -- safety cap for presenter-driven popups that never report done
-- Chips hide while a centre popup is on screen (owner R102: they never overlap).
PopupQueueConfig.HideChipsDuringCenter = true
-- YOU marker (Tycoon/YouMarker): hidden while its projected box covers the currency stack.
PopupQueueConfig.YouMarker = table.freeze({
	CheckSeconds = 0.15, -- throttled projection check (only while the marker is wanted)
	Margin = 6, -- design px of hysteresis around the stack (no flicker on the edge)
})

return table.freeze(PopupQueueConfig)
