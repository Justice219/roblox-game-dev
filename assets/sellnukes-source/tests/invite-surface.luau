--!strict
--[[
	Co-play surface regressions (owner R122, spec 2026-11-01-r122-algorithm-pack-design.md §2.4:
	the HUD INVITE button + one invite moment per session). Run:
		lune run tests/invite-surface

	Field data: 252 of 266 sessions had no friend in the server; the Friends window was opened once
	in two days; Friend Boost found 0 friends in 144 of 145 joins. Proves on the shipped modules
	(Shared/Config/InviteConfig, Client/Social/InviteLogic):
	  1. Config: sane timings, the report allowlist = exactly the AnalyticsConfig social keys
	     friends:hud:<shown|tap> / friends:moment:<shown|invite|later>, caps (shown once per session),
	     the HUD key / pad never collide with a gameplay action (PlatformConfig.Actions), the card's
	     INVITE is never gamepad A and sits below gameplay priority, the moment is a low-priority
	     non-modal feed card (PopupQueueConfig).
	  2. Availability: only an explicit "yes" from Roblox shows the button (unknown / no = hidden).
	  3. The "+10%" sticker reads the LIVE Friend Boost settings (admin percent; hidden while off;
	     hostile values never show junk).
	  4. The moment: once per session; never before MinSessionSeconds; AfterUnlockSeconds after an
	     unlock during the session; at once (after the session minimum) when already unlocked at
	     join; never while a friend is here, during the tutorial or with invites unavailable;
	     progress is latched (a later "locked" read never re-arms it).
	  5. Report caps (InviteConfig.reportAllowed): unknown reports refused, per-session caps hold
	     over a forged flood.
]]

local roblox = require("@lune/roblox")
local Enum = (roblox :: any).Enum

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local InviteConfig = loader.load("src/shared/Config/InviteConfig")
local InviteLogic = loader.load("src/client/Social/InviteLogic")
local AnalyticsConfig = loader.load("src/shared/Config/AnalyticsConfig")
local PlatformConfig = loader.load("src/shared/Config/PlatformConfig")
local PopupQueueConfig = loader.load("src/shared/Config/PopupQueueConfig")
local SocialConfig = loader.load("src/shared/Config/SocialConfig")

local checks = 0
local function ok(condition: boolean, label: string)
	checks += 1
	if not condition then
		error(label, 2)
	end
end

-- 1. Config -------------------------------------------------------------------------------------------
do
	ok(table.isfrozen(InviteConfig), "InviteConfig frozen")
	local moment = InviteConfig.Moment
	ok(moment.MinArea == 2, "the moment follows area 2 (spec)")
	ok(moment.MinSessionSeconds >= 60, "never in the first minute of a session")
	ok(moment.AfterUnlockSeconds >= 10, "the unlock plays out first")
	ok(moment.ShowSeconds >= 8 and moment.ShowSeconds <= 30, "the card closes itself")
	ok(moment.RetrySeconds >= 10, "retries are spaced")
	ok(moment.InvitePad ~= Enum.KeyCode.ButtonA, "INVITE never on A (jump)")
	ok(moment.InvitePriority < PlatformConfig.Priority.Gameplay, "INVITE below gameplay priority")
	local kind = PopupQueueConfig.Kinds.inviteMoment
	ok(kind ~= nil and kind.channel == "center" and kind.anchor == "feed", "moment = a feed card in the lane")
	ok(kind.priority < PopupQueueConfig.Kinds.juice.priority, "moment is low priority")
	ok(kind.waitForModal and kind.waitForFocus, "never over a menu / cinematic")
	-- Report allowlist = the AnalyticsConfig social keys.
	local social = AnalyticsConfig.Metrics.social
	ok(social["friends:hud:<shown|tap>"] ~= nil, "friends:hud key documented")
	ok(social["friends:moment:<shown|invite|later>"] ~= nil, "friends:moment key documented")
	local expected = { "hud:shown", "hud:tap", "moment:shown", "moment:invite", "moment:later" }
	ok(#InviteConfig.Reports == #expected, "exactly five reports")
	for _, action in expected do
		ok(table.find(InviteConfig.Reports, action) ~= nil, `report {action}`)
		ok(type(InviteConfig.ReportCaps[action]) == "number", `cap for {action}`)
		-- Never collides with the R78 invite outcome allowlist (one remote carries both).
		ok(table.find(SocialConfig.Invite.Actions, action) == nil, `{action} is not an invite outcome`)
	end
	for action, cap in InviteConfig.ReportCaps do
		ok(table.find(InviteConfig.Reports, action) ~= nil, `cap {action} is a report`)
		if string.sub(action, -6) == ":shown" then
			ok(cap == 1, `{action}: once per session`)
		end
		ok(cap >= 1 and cap <= 50, `{action}: sane cap`)
	end
	ok(InviteConfig.ReportBurst >= 2 and InviteConfig.ReportPerSecond > 0, "report rate limit")
	-- The HUD binding never collides with a gameplay action.
	local hud = InviteConfig.Hud
	ok(hud.Pad ~= Enum.KeyCode.ButtonA and hud.Pad ~= Enum.KeyCode.ButtonB, "HUD INVITE never on A / B")
	for name, binding in PlatformConfig.Actions do
		for _, key in binding.keys do
			ok(key ~= hud.Key, `HUD INVITE key {hud.Key.Name} is free (used by {name})`)
		end
		for _, button in binding.buttons do
			ok(button ~= hud.Pad, `HUD INVITE pad {hud.Pad.Name} is free (used by {name})`)
		end
	end
	-- Roblox's default camera zoom keys (I / O) are never taken.
	ok(hud.Key ~= Enum.KeyCode.I and hud.Key ~= Enum.KeyCode.O, "camera zoom keys stay Roblox's")
	ok(hud.Height >= 44 and hud.Width >= hud.Height and hud.PhoneWidth >= hud.Height, "HUD button sizes")
	ok(string.format(hud.BadgeFormat, 10) == "+10%", "sticker format")
end

-- 2. Availability -------------------------------------------------------------------------------------
do
	ok(InviteLogic.available(true), "Roblox said yes → shown")
	ok(not InviteLogic.available(false), "Roblox said no → hidden")
	ok(not InviteLogic.available(nil), "unknown (asking / failed) → hidden")
end

-- 3. Sticker -----------------------------------------------------------------------------------------
do
	ok(
		InviteLogic.badgeText({ friendsOn = true, friendPercent = SocialConfig.Friends.PercentPerFriend }) == "+10%",
		"default +10%"
	)
	ok(InviteLogic.badgeText({ friendsOn = true, friendPercent = 25 }) == "+25%", "admin percent")
	ok(InviteLogic.badgeText({ friendsOn = false, friendPercent = 10 }) == nil, "boost off → no sticker")
	ok(InviteLogic.badgeText({ friendsOn = true, friendPercent = 0 }) == nil, "0 % → no sticker")
	ok(InviteLogic.badgeText({ friendsOn = true, friendPercent = 0 / 0 }) == nil, "NaN → no sticker")
	ok(InviteLogic.badgeText({ friendsOn = true, friendPercent = -5 }) == nil, "negative → no sticker")
	ok(InviteLogic.badgeText({ friendsOn = true, friendPercent = 9.6 }) == "+10%", "rounded")
	-- The real live() path (no attributes = config defaults).
	local live = SocialConfig.live(nil)
	ok(
		InviteLogic.badgeText({ friendsOn = live.friendsOn, friendPercent = live.friendPercent }) == "+10%",
		"live defaults"
	)
end

-- 4. The moment ---------------------------------------------------------------------------------------
do
	local cfg = { MinSessionSeconds = 180, AfterUnlockSeconds = 90 }
	local open = { available = true, friendsHere = 0, tutorial = false }
	-- Not eligible: no due time.
	local state = InviteLogic.newMoment(100)
	ok(InviteLogic.momentDueAt(state, cfg) == nil, "not unlocked: never due")
	InviteLogic.noteProgress(state, false, 150, true)
	ok(InviteLogic.momentDueAt(state, cfg) == nil, "still locked: never due")
	-- Unlocked during the session at t = 400: due 90 s later.
	InviteLogic.noteProgress(state, true, 400, false)
	ok(state.unlockedHere, "unlock during the session")
	ok(InviteLogic.momentDueAt(state, cfg) == 490, "due AfterUnlockSeconds after the unlock")
	-- A later locked read (rebirth to area 1) never re-arms or moves it.
	InviteLogic.noteProgress(state, false, 500, false)
	InviteLogic.noteProgress(state, true, 600, false)
	ok(InviteLogic.momentDueAt(state, cfg) == 490, "progress is latched")
	-- An early unlock still waits for the session minimum.
	local early = InviteLogic.newMoment(0)
	InviteLogic.noteProgress(early, true, 20, false)
	ok(InviteLogic.momentDueAt(early, cfg) == 180, "never before MinSessionSeconds")
	-- Already unlocked at join: right after the session minimum.
	local joined = InviteLogic.newMoment(1000)
	InviteLogic.noteProgress(joined, true, 1000.5, true)
	ok(not joined.unlockedHere, "at join")
	ok(InviteLogic.momentDueAt(joined, cfg) == 1180, "returning player: after MinSessionSeconds")
	-- Default config.
	ok(InviteLogic.momentDueAt(joined) == 1000 + InviteConfig.Moment.MinSessionSeconds, "default config")
	-- Gate.
	ok(InviteLogic.momentGate(joined, open), "gate open")
	local okF, whyF = InviteLogic.momentGate(joined, { available = true, friendsHere = 1, tutorial = false })
	ok(not okF and whyF == "friends", "a friend is here → no card")
	local okU, whyU = InviteLogic.momentGate(joined, { available = false, friendsHere = 0, tutorial = false })
	ok(not okU and whyU == "unavailable", "invites unavailable → no card")
	local okT, whyT = InviteLogic.momentGate(joined, { available = true, friendsHere = 0, tutorial = true })
	ok(not okT and whyT == "tutorial", "tutorial → no card")
	-- Once per session.
	InviteLogic.markShown(joined)
	local okS, whyS = InviteLogic.momentGate(joined, open)
	ok(not okS and whyS == "shown", "shown → never again")
	ok(InviteLogic.momentDueAt(joined, cfg) == nil, "shown → no due time")
	InviteLogic.noteProgress(joined, true, 5000, false)
	ok(InviteLogic.momentDueAt(joined, cfg) == nil, "shown stays shown")
end

-- 5. Report caps -------------------------------------------------------------------------------------
do
	ok(not InviteConfig.reportAllowed({}, "prompted"), "an invite outcome is not a surface report")
	ok(not InviteConfig.reportAllowed({}, "hud:junk"), "unknown report refused")
	ok(InviteConfig.reportAllowed({}, "hud:shown"), "first shown counts")
	ok(not InviteConfig.reportAllowed({ ["hud:shown"] = 1 }, "hud:shown"), "second shown refused")
	-- A forged flood: the server counts at most the cap of each report per session.
	local counts: { [string]: number } = {}
	local counted: { [string]: number } = {}
	for round = 1, 500 do
		local action = InviteConfig.Reports[(round % #InviteConfig.Reports) + 1]
		if InviteConfig.reportAllowed(counts, action) then
			counts[action] = (counts[action] or 0) + 1
			counted[action] = (counted[action] or 0) + 1
		end
	end
	for action, cap in InviteConfig.ReportCaps do
		ok((counted[action] or 0) == cap, `{action}: flood counted exactly the cap ({counted[action]} / {cap})`)
	end
end

print(`[invite-surface] {checks} checks passed`)
