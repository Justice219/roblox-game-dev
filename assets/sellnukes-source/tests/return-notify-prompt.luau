--!strict
--[[
	Return-notification opt-in card + admin section regressions (owner R122 §2.3 "Opt-in reach",
	"Admin panel: notifications section"). Run:
		lune run tests/return-notify-prompt
	Proves on the shipped modules (Client/UI/Screens/NotifyPrompt/PromptMoments, Client/UI/Screens/
	Admin/NotifySectionLogic, Shared/Config/{NotifyConfig, TycoonConfig, PopupQueueConfig}):
	  1. Manager count over the REAL tycoon catalogue (only "Manager" pads count; junk ignored).
	  2. Snapshots from hostile / partial profiles.
	  3. Moments: the first manager hire this session → "manager"; else reaching area 2 → "area2";
	     never for a session that started with them; one change at a time; the fallback rule.
	  4. Open sources → analytics moments (settings / auto / anything else = "other").
	  5. Admin section texts: unknown / ON / OFF, kinds off, missing ids (live vs Studio), the
	     ready count, hostile attribute values.
	  6. Config: the prompt timings are sane (moment delay < fallback < late fallback, waits > 0)
	     and the queue kind name is a plain identifier; if PopupQueueConfig declares it, it is a
	     centre-lane kind that waits for windows and cinematics.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local PromptMoments = loader.load("src/client/UI/Screens/NotifyPrompt/PromptMoments")
local SectionLogic = loader.load("src/client/UI/Screens/Admin/NotifySectionLogic")
local NotifyConfig = loader.load("src/shared/Config/NotifyConfig")
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local PopupQueueConfig = loader.load("src/shared/Config/PopupQueueConfig")

local checks = 0
local function ok(condition: boolean, label: string)
	checks += 1
	assert(condition, label)
end
local function eq(actual: any, expected: any, label: string)
	ok(actual == expected, `{label}: got {tostring(actual)}, expected {tostring(expected)}`)
end

local PADS = TycoonConfig.PadsById

-- The real catalogue's manager pads (any area) and a non-manager pad.
local managers: { string } = {}
local other: string? = nil
for _, pad in TycoonConfig.PadOrder do
	if pad.kind == "Manager" then
		table.insert(managers, pad.id)
	elseif other == nil then
		other = pad.id
	end
end
ok(#managers >= 2, "the catalogue has manager pads")
ok(other ~= nil, "the catalogue has a non-manager pad")

------------------------------------------------------------------------------------------------
-- 1. Manager count
------------------------------------------------------------------------------------------------
do
	eq(PromptMoments.managerCount(nil, PADS), 0, "no pads")
	eq(PromptMoments.managerCount("pads", PADS), 0, "junk pads")
	eq(PromptMoments.managerCount({ [other :: string] = true }, PADS), 0, "a non-manager pad")
	eq(PromptMoments.managerCount({ [managers[1]] = true }, PADS), 1, "one manager")
	eq(PromptMoments.managerCount({ [managers[1]] = true, [managers[2]] = true }, PADS), 2, "two managers")
	eq(PromptMoments.managerCount({ [managers[1]] = false }, PADS), 0, "false is not owned")
	eq(PromptMoments.managerCount({ bogus_pad = true, [5] = true }, PADS), 0, "unknown ids ignored")
end

------------------------------------------------------------------------------------------------
-- 2. Snapshots
------------------------------------------------------------------------------------------------
do
	eq(PromptMoments.snapshot(nil, PADS), nil, "no profile")
	eq(PromptMoments.snapshot({}, PADS), nil, "no tycoon")
	eq(PromptMoments.snapshot({ tycoon = "x" }, PADS), nil, "junk tycoon")
	local snap = PromptMoments.snapshot({ tycoon = { pads = { [managers[1]] = true }, area = 3 } }, PADS)
	ok(snap ~= nil and snap.managers == 1 and snap.area == 3, "snapshot")
	local junkArea = PromptMoments.snapshot({ tycoon = { pads = {}, area = 0 / 0 } }, PADS)
	eq(junkArea.area, 1, "NaN area → 1")
end

------------------------------------------------------------------------------------------------
-- 3. Moments
------------------------------------------------------------------------------------------------
do
	local fresh = { managers = 0, area = 1 }
	local hired = { managers = 1, area = 1 }
	local area2 = { managers = 1, area = 2 }
	eq(PromptMoments.momentFor(fresh, fresh, hired), "manager", "first manager this session")
	eq(PromptMoments.momentFor(fresh, hired, { managers = 2, area = 1 }), nil, "second manager is not a moment")
	eq(PromptMoments.momentFor(fresh, hired, area2), "area2", "area 2 after the manager moment")
	eq(PromptMoments.momentFor(hired, hired, area2), "area2", "returning player with a manager: area 2")
	eq(PromptMoments.momentFor(hired, hired, { managers = 2, area = 1 }), nil, "had a manager at join")
	eq(PromptMoments.momentFor(area2, area2, { managers = 3, area = 3 }), nil, "both done at join")
	eq(PromptMoments.momentFor(fresh, fresh, { managers = 1, area = 2 }), "manager", "both at once → manager first")
	eq(PromptMoments.momentFor(fresh, fresh, fresh), nil, "no change")
	eq(
		PromptMoments.momentFor({ managers = 0, area = 2 }, { managers = 0, area = 2 }, { managers = 0, area = 3 }),
		nil,
		"area 3 is not area 2"
	)
	ok(PromptMoments.needsFallback(area2), "both done at join → fallback")
	ok(not PromptMoments.needsFallback(hired), "area 2 can still happen")
	ok(not PromptMoments.needsFallback(fresh), "new player waits for the moments")
end

------------------------------------------------------------------------------------------------
-- 4. Sources
------------------------------------------------------------------------------------------------
do
	eq(PromptMoments.momentOfSource("manager"), "manager", "manager source")
	eq(PromptMoments.momentOfSource("area2"), "area2", "area2 source")
	for _, source in { "other", "settings", "auto", nil, 5, "MANAGER" } do
		eq(PromptMoments.momentOfSource(source), "other", `source {tostring(source)}`)
	end
	for _, moment in NotifyConfig.PromptMoments do
		eq(PromptMoments.momentOfSource(moment), moment, `config moment {moment} maps to itself`)
	end
end

------------------------------------------------------------------------------------------------
-- 5. Admin section texts
------------------------------------------------------------------------------------------------
do
	local names = NotifyConfig.Attributes
	-- Fixed fixtures keep configured and empty-id admin states covered after templates go live.
	local withIds: { [string]: any } = {}
	local emptyIds: { [string]: any } = {}
	for kind, def in NotifyConfig.Kinds do
		local copy = table.clone(def)
		copy.messageId = "11111111-2222-3333-4444-555555555555"
		withIds[kind] = copy
		local empty = table.clone(def)
		empty.messageId = ""
		emptyIds[kind] = empty
	end
	local unknown = SectionLogic.describe({}, withIds, false)
	ok(string.find(unknown.line, "…", 1, true) ~= nil, "unknown switch shown as …")
	eq(unknown.ready, 0, "unknown switch: nothing counted ready")
	local on = SectionLogic.describe({ [names.On] = true, [names.KindsOff] = "" }, withIds, false)
	eq(on.ready, #NotifyConfig.KindOrder, "all kinds ready")
	ok(string.find(on.line, "Sending", 1, true) ~= nil and string.find(on.line, ">ON<", 1, true) ~= nil, "ON painted")
	local off = SectionLogic.describe({ [names.On] = false, [names.KindsOff] = "" }, withIds, false)
	eq(off.ready, 0, "kill switch: nothing ready")
	ok(string.find(off.note, "Kill switch is OFF", 1, true) ~= nil, "kill switch note")
	local streakOff = SectionLogic.describe({ [names.On] = true, [names.KindsOff] = "streak" }, withIds, false)
	eq(streakOff.ready, #NotifyConfig.KindOrder - 1, "one kind off")
	ok(
		string.find(streakOff.line, NotifyConfig.Kinds.streak.label .. ' <font color="#FF4646">OFF', 1, true) ~= nil,
		"kind OFF painted"
	)
	local noIds = SectionLogic.describe({ [names.On] = true, [names.KindsOff] = "" }, emptyIds, false)
	ok(string.find(noIds.note, "No message id yet", 1, true) ~= nil, "missing ids explained (live)")
	ok(string.find(noIds.line, "NO ID", 1, true) ~= nil, "NO ID painted (live)")
	local studio = SectionLogic.describe({ [names.On] = true, [names.KindsOff] = "" }, emptyIds, true)
	ok(string.find(studio.line, "DRY", 1, true) ~= nil, "Studio shows DRY for missing ids")
	ok(string.find(studio.note, "dry run", 1, true) ~= nil, "Studio note")
	local offSet = SectionLogic.offSet("streak,bogus,,cashFull")
	ok(offSet.streak and offSet.cashFull and offSet.bogus == nil, "offSet parses known kinds only")
	eq(next(SectionLogic.offSet(5)), nil, "offSet junk")
	eq(next(SectionLogic.offSet(string.rep("streak,", 50))), nil, "offSet oversized")
	local hostile = SectionLogic.describe({ [names.On] = "yes", [names.KindsOff] = { "streak" } }, withIds, false)
	eq(hostile.ready, 0, "hostile attributes never read as ON")
end

------------------------------------------------------------------------------------------------
-- 6. Config
------------------------------------------------------------------------------------------------
do
	local prompt = NotifyConfig.Prompt
	ok(prompt.MomentDelaySeconds < prompt.FallbackDelaySeconds, "moment delay < fallback")
	ok(prompt.FallbackDelaySeconds < prompt.LateFallbackSeconds, "fallback < late fallback")
	ok(prompt.MaxWaitSeconds > 0 and prompt.CheckSeconds > 0 and prompt.CalmChecks >= 1, "waits positive")
	ok(string.find(prompt.QueueKind, "^[%a][%w]*$") ~= nil, "queue kind is an identifier")
	local kind = (PopupQueueConfig.Kinds :: any)[prompt.QueueKind]
	if kind ~= nil then
		eq(kind.channel, "center", "queue kind uses the centre lane")
		ok(kind.waitForModal and kind.waitForFocus, "queue kind waits for windows and cinematics")
		ok(kind.priority < PopupQueueConfig.Kinds.plotReveal.priority, "the plot reveal outranks the card")
		ok(kind.maxWait > 0, "queue kind waits")
		eq(kind.maxWait, prompt.MaxWaitSeconds, "queue maxWait = the fallback loop's wait")
	else
		print("return-notify-prompt: PopupQueueConfig has no notifyPrompt kind yet (fallback polling path)")
	end
	eq(#NotifyConfig.PromptMoments, 3, "three analytics moments")
end

print(`return-notify-prompt: {checks} checks passed`)
