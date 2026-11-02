--!strict
--[[
	WHAT'S NEW change notes + version regressions (owner R58 port of RoBeasts' system;
	docs/change-notes.md). Run:
		lune run tests/change-notes

	Proves (the real production modules, loaded unchanged through tests/fixtures/RobloxLoader):
	  1. VersionConfig: strict semver parsing (no "v", no leading zeros, no suffixes, bounded),
	     numeric ordering ("1.9.0" < "1.10.0"), sameMinor, label / menuText (build suffix only for
	     a real place version), and Current is valid.
	  2. ChangeNotesConfig.validate() is clean on the shipped notes; validateNotes catches every
	     rule on candidate lists (ids, the SellNukes 32-char analytics id cap, UTC dates, ascending
	     dates, versions, caps, tags / icons / hero kinds / CTA screens + Shop tabs, ShowFrom), and
	     the shared-schema mirrors still agree (ShopTabs = ShopConfig section ids, every CTA screen
	     is a real screen module).
	  3. TRUTH: every number the shipped notes claim still matches config (10 areas, 29 pets,
	     8 plots).
	  4. ChangeNotesLogic: seen position, forward-only marking, the admin reset, no-context players
	     (new profile / tutorial not finished), THE "should auto-show" rule (new vs returning;
	     seen older / equal / newer; malformed data), action parsing (+ the clamped seconds of
	     "closed"), metric keys (accepted by the analytics KeySpec), the time-open buckets, the
	     client helpers (readSeen / autoNote).
	  5. ShowFrom over candidate lists: visible prefix, next reveal, displayed version, the
	     VisibleVersion rules.
	  6. The profile record: ProfileLogic default / reconcile (missing, malformed, newer-server
	     id, timestamp clamp) / snapshot (seen only) / toSave round trip.
	  7. HudPlacement's bottom-right WHAT'S NEW corner: inside the canvas, under the offer column
	     (never overlapping it), above the touch reserve; no corner = the old layout exactly.
	  8. Notes are deep-frozen (no runtime code can edit them).
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local VersionConfig = loader.load("src/shared/Config/VersionConfig")
local ChangeNotesConfig = loader.load("src/shared/Config/ChangeNotesConfig")
local ChangeNotesLogic = loader.load("src/shared/Util/ChangeNotesLogic")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local ShopConfig = loader.load("src/shared/Config/ShopConfig")
local PetConfig = loader.load("src/shared/Config/PetConfig")
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local KeySpec = loader.load("src/server/Analytics/KeySpec")
local HudPlacement = loader.load("src/client/UI/Widgets/HudPlacement")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- True when `problems` has an entry containing `needle` (plain find).
local function mentions(problems: { string }, needle: string): boolean
	for _, problem in problems do
		if string.find(problem, needle, 1, true) ~= nil then
			return true
		end
	end
	return false
end

local NOTES = ChangeNotesConfig.Notes
local COUNT = #NOTES
local FIRST = NOTES[1]
local NEWEST = NOTES[COUNT]
-- A time after every shipped note's date (no shipped note has a ShowFrom today).
local NOW = ChangeNotesConfig.unixDate(2030, 1, 1)

---------------------------------------------------------------------------------------------------
-- 1. VersionConfig
---------------------------------------------------------------------------------------------------
check(VersionConfig.isValid(VersionConfig.Current), "Current is valid semver")
-- Current only moves forward (bumped per player-facing change; validate() pins it to the newest note).
check(VersionConfig.compare(VersionConfig.Current, "0.3.0") >= 0, "Current is at least 0.3.0 (R58)")
local parsed = VersionConfig.parse("1.12.3")
check(parsed ~= nil and parsed.major == 1 and parsed.minor == 12 and parsed.patch == 3, "parse")
for _, bad in { "v1.2.0", "1.02.0", "1.2", "1.2.3.4", "1.2.3-beta", "", " 1.2.3", "01.1.1", string.rep("9", 30) } do
	check(VersionConfig.parse(bad) == nil, `rejects {bad}`)
end
check(VersionConfig.parse(123) == nil, "rejects non-strings")
check(VersionConfig.compare("1.9.0", "1.10.0") == -1, "numeric order")
check(VersionConfig.compare("2.0.0", "1.99.99") == 1, "major outranks")
check(VersionConfig.compare("0.1.0", "0.1.0") == 0, "equal")
check(VersionConfig.sameMinor("0.1.4", "0.1.0") and not VersionConfig.sameMinor("0.2.0", "0.1.0"), "sameMinor")
local cur = VersionConfig.Current
check(VersionConfig.label() == "v" .. cur and VersionConfig.label("1.2.0") == "v1.2.0", "label")
check(VersionConfig.menuText(431) == `v{cur} · build 431`, "menuText with build")
check(VersionConfig.menuText(0) == "v" .. cur and VersionConfig.menuText(0 / 0) == "v" .. cur, "menuText without build")
check(ChangeNotesConfig.menuText(431, NOW) == VersionConfig.menuText(431), "menuText while every note is visible")

---------------------------------------------------------------------------------------------------
-- 2. Config validation
---------------------------------------------------------------------------------------------------
local problems = ChangeNotesConfig.validate()
check(#problems == 0, "ChangeNotesConfig.validate: " .. table.concat(problems, "; "))
check(FIRST.Id == "2026-10-30-sellnukes-born" and FIRST.Version == "0.1.0", "first note is SellNukes is born")
-- Later feature releases append notes; the R58 note must remain addressable for saved seen ids.
local whatsNewNote = ChangeNotesConfig.get("2026-10-31-whats-new")
check(whatsNewNote ~= nil and whatsNewNote.Version == "0.3.0", "0.3.0 note remains in the append-only catalog (R58)")
check(ChangeNotesConfig.newest() == NEWEST, "newest is the last note")
check(ChangeNotesConfig.indexOf(FIRST.Id) == 1 and ChangeNotesConfig.get(NEWEST.Id) == NEWEST, "indexOf / get")
check(ChangeNotesConfig.indexOf("nope") == nil and ChangeNotesConfig.indexOf(42) == nil, "indexOf unknown / untrusted")
check(ChangeNotesConfig.get({}) == nil and ChangeNotesConfig.get(nil) == nil, "get untrusted")
for _, note in NOTES do
	check(#note.Id <= ChangeNotesConfig.AnalyticsIdLength, `{note.Id} fits an analytics key part`)
end

-- A valid candidate note (deep copy of a template) for the rule checks below.
local function candidate(overrides: { [string]: any }?): { [string]: any }
	local note: { [string]: any } = {
		Id = "2026-11-02-candidate",
		Version = "0.3.0",
		Date = ChangeNotesConfig.unixDate(2026, 11, 2),
		Title = "A TITLE",
		Tagline = "A tagline.",
		Hero = { Kind = "Icon", Icon = "star" },
		Sections = { { Heading = "NEW", Items = { { Text = "One line." } } } },
	}
	for key, value in overrides or {} do
		note[key] = value
	end
	return note
end
check(#ChangeNotesConfig.validateNotes({ candidate() } :: any, "0.3.0") == 0, "the candidate template is valid")
local function problemsOf(overrides: { [string]: any }): { string }
	return ChangeNotesConfig.validateNotes({ candidate(overrides) } :: any, nil)
end
check(mentions(problemsOf({ Id = "Bad Id" }), ".Id must look like"), "id shape")
check(
	mentions(problemsOf({ Id = "2026-11-02-" .. string.rep("a", 30) }), "analytics key part"),
	"SellNukes id cap (32)"
)
check(mentions(problemsOf({ Id = "2026-11-03-candidate" }), "date part"), "id date = UTC Date")
check(mentions(problemsOf({ Date = 1.5 }), "whole unix seconds"), "whole Date")
check(mentions(problemsOf({ Version = "v1" }), "semver"), "version format")
check(mentions(problemsOf({ Title = string.rep("T", 41) }), ".Title must be 1..40"), "title cap")
check(mentions(problemsOf({ Tagline = " padded" }), "leading / trailing"), "no padding")
check(mentions(problemsOf({ Hero = { Kind = "Pet", PetId = "nope" } }), "is not a pet"), "hero pet id")
check(#problemsOf({ Hero = { Kind = "Pet", PetId = PetConfig.Order[1] } }) == 0, "hero pet ok")
check(#problemsOf({ Hero = { Kind = "Image", Image = "rbxassetid://123" } }) == 0, "hero image ok")
check(mentions(problemsOf({ Hero = { Kind = "Image", Image = "http://x" } }), "rbxassetid"), "hero image id")
check(mentions(problemsOf({ Hero = { Kind = "Video" } }), "Hero.Kind"), "hero kind")
check(mentions(problemsOf({ Sections = {} }), "sections"), "needs sections")
check(
	mentions(problemsOf({ Sections = { { Heading = "X", Items = { { Text = "a", Tag = "HOT" } } } } }), "not a tag"),
	"item tag"
)
check(
	mentions(problemsOf({ Sections = { { Heading = "X", Items = { { Text = "a", Icon = "bomb" } } } } }), "not an icon"),
	"item icon"
)
check(
	mentions(problemsOf({ Sections = { { Heading = "X", Items = { { Text = string.rep("a", 73) } } } } }), "1..72"),
	"item cap"
)
check(mentions(problemsOf({ Cta = { Label = "GO", Screen = "Nowhere" } }), "CTA screen"), "cta screen")
check(
	mentions(problemsOf({ Cta = { Label = "GO", Screen = "Pets", Tab = "gems" } }), "Shop tab"),
	"cta tab only on Shop"
)
check(#problemsOf({ Cta = { Label = "GET GEMS", Screen = "Shop", Tab = "gems" } }) == 0, "cta shop tab ok")
-- Lists: duplicates, order, versions, current.
local a = candidate()
local b = candidate({ Id = "2026-11-03-second", Date = ChangeNotesConfig.unixDate(2026, 11, 3), Version = "0.2.0" })
local listProblems = ChangeNotesConfig.validateNotes({ a, b } :: any, "0.3.0")
check(mentions(listProblems, "older than the previous note"), "versions never go down")
check(mentions(ChangeNotesConfig.validateNotes({ a, a } :: any, nil), "duplicate"), "duplicate ids")
local early = candidate({ Id = "2026-11-01-early", Date = ChangeNotesConfig.unixDate(2026, 11, 1) })
check(mentions(ChangeNotesConfig.validateNotes({ a, early } :: any, nil), "later than the previous"), "ascending dates")
check(mentions(ChangeNotesConfig.validateNotes({ a } :: any, "0.2.9"), "older than the newest"), "current >= newest")
check(mentions(ChangeNotesConfig.validateNotes({ a } :: any, "0.4.0"), "has no note"), "minor bump needs a note")
check(#ChangeNotesConfig.validateNotes({ a } :: any, "0.3.7") == 0, "patch bump is fine")
-- ShowFrom rules.
local hiddenOk = candidate({ ShowFrom = ChangeNotesConfig.unixDate(2026, 11, 5) })
check(#ChangeNotesConfig.validateNotes({ hiddenOk } :: any, nil) == 0, "ShowFrom ok")
check(
	mentions(
		ChangeNotesConfig.validateNotes(
			{ candidate({ ShowFrom = ChangeNotesConfig.unixDate(2026, 11, 1) }) } :: any,
			nil
		),
		"before its Date"
	),
	"ShowFrom >= Date"
)
local afterHidden = candidate({ Id = "2026-11-06-after", Date = ChangeNotesConfig.unixDate(2026, 11, 6) })
check(
	mentions(ChangeNotesConfig.validateNotes({ hiddenOk, afterHidden } :: any, nil), "needs a ShowFrom"),
	"every note after a ShowFrom needs one"
)

-- Shared-schema mirrors.
local shopIds: { [string]: boolean } = {}
for _, section in ShopConfig.Sections do
	shopIds[section.id] = true
end
for _, tab in ChangeNotesConfig.ShopTabs do
	check(shopIds[tab] == true, `Shop tab {tab} exists in ShopConfig.Sections`)
end
for id in shopIds do
	check(ChangeNotesConfig.ShopTabSet[id] == true, `ShopConfig section {id} is a CTA tab`)
end
-- Every CTA screen is a registered screen name somewhere under src/client/UI/Screens.
local screenNames: { [string]: boolean } = {}
local function scan(dir: string)
	for _, entry in fs.readDir(dir) do
		local path = `{dir}/{entry}`
		if fs.isDir(path) then
			scan(path)
		elseif string.sub(entry, -5) == ".luau" then
			local source = fs.readFile(path)
			for name in string.gmatch(source, '\n%s*name = "([%a]+)",') do
				screenNames[name] = true
			end
			for name in string.gmatch(source, 'local NAME = "([%a]+)"') do
				screenNames[name] = true
			end
		end
	end
end
scan("src/client/UI/Screens")
for _, screen in ChangeNotesConfig.CtaScreens do
	check(screenNames[screen] == true, `CTA screen {screen} is a real screen`)
end
check(screenNames[ChangeNotesConfig.Screen] == true, "the WhatsNew screen exists")

---------------------------------------------------------------------------------------------------
-- 3. Truth checks (the shipped notes only claim what the config really does)
---------------------------------------------------------------------------------------------------
check(#TycoonConfig.Areas == 10, "0.2.0 note: 10 areas")
check(PetConfig.Count >= 29, "0.2.0 note: 29 pets at launch (the roster only grows)")
check(WorldLayout.PlotCount == 8, "0.2.0 note: 8 players per server")

---------------------------------------------------------------------------------------------------
-- 4. ChangeNotesLogic
---------------------------------------------------------------------------------------------------
check(ChangeNotesLogic.seenIndex("") == 0 and ChangeNotesLogic.seenIndex(nil) == 0, "nothing seen")
check(ChangeNotesLogic.seenIndex(FIRST.Id) == 1, "known id position")
check(ChangeNotesLogic.seenIndex("2099-01-01-from-a-newer-server") == COUNT, "newer server's id = all seen")
check(ChangeNotesLogic.seenIndex("junk id") == 0 and ChangeNotesLogic.seenIndex({}) == 0, "junk = nothing seen")
check(ChangeNotesLogic.hasUnseen("", NOW) and ChangeNotesLogic.unseenCount("", NOW) == COUNT, "all unseen")
check(not ChangeNotesLogic.hasUnseen(NEWEST.Id, NOW), "up to date after the newest")
check(
	ChangeNotesLogic.isUnseenIndex(FIRST.Id, 2) and not ChangeNotesLogic.isUnseenIndex(FIRST.Id, 1),
	"NEW ribbon rule"
)

local state = ChangeNotesConfig.newState()
check(ChangeNotesLogic.markSeen(state, "nope", 10) == "Unknown" and state.seen == "", "unknown id refused")
check(ChangeNotesLogic.markSeen(state, 42, 10) == "Unknown", "non-string refused")
check(ChangeNotesLogic.markSeen(state, NEWEST.Id, 1234.7) == "Ok" and state.at == 1234, "forward mark ok (whole time)")
check(ChangeNotesLogic.markSeen(state, NEWEST.Id, 99) == "NotForward" and state.at == 1234, "same id is not forward")
check(ChangeNotesLogic.markSeen(state, FIRST.Id, 99) == "NotForward" and state.seen == NEWEST.Id, "never moves back")
local newerServer = { seen = "2099-01-01-from-a-newer-server", at = 5 }
check(ChangeNotesLogic.markSeen(newerServer, NEWEST.Id, 6) == "NotForward", "never moves back from a newer server's id")
-- Admin reset (the only way back).
check(ChangeNotesLogic.resetSeen(state, "", 50) and state.seen == "" and state.at == 50, "admin reset to nothing")
check(ChangeNotesLogic.resetSeen(state, FIRST.Id, 51) and state.seen == FIRST.Id, "admin reset to a note")
check(
	not ChangeNotesLogic.resetSeen(state, "2099-01-01-unknown", 52) and state.seen == FIRST.Id,
	"reset: known ids only"
)
check(not ChangeNotesLogic.resetSeen(state, 7, 52), "reset: strings only")

-- No-context players (server, on load).
check(ChangeNotesLogic.isNoContextPlayer("new", true), "brand-new profile = no context")
check(ChangeNotesLogic.isNoContextPlayer("current", false), "tutorial not finished = no context")
check(not ChangeNotesLogic.isNoContextPlayer("migrated", true), "returning player = context")
local fresh = ChangeNotesConfig.newState()
check(ChangeNotesLogic.onProfileLoaded(fresh, "new", false, 500) and fresh.seen == NEWEST.Id, "new: newest marked")
check(not ChangeNotesLogic.onProfileLoaded(fresh, "new", false, 600) and fresh.at == 500, "idempotent")
local veteran = { seen = FIRST.Id, at = 1 }
check(
	not ChangeNotesLogic.onProfileLoaded(veteran, "current", true, 500) and veteran.seen == FIRST.Id,
	"returning player untouched"
)
local learner = { seen = "", at = 0 }
check(
	ChangeNotesLogic.onProfileLoaded(learner, "current", false, 7) and learner.seen == NEWEST.Id,
	"mid-tutorial: marked"
)

-- THE "should auto-show" rule: new vs returning, older / equal / newer, malformed.
local function shows(seen: unknown, migration: string, done: boolean): boolean
	return ChangeNotesLogic.shouldAutoShow(seen, migration, done, NOW)
end
check(not shows("", "new", true), "new profile: never auto-shows (first session)")
check(not shows("", "new", false), "new profile mid-tutorial: never")
check(not shows(FIRST.Id, "current", false), "returning but tutorial unfinished: never")
check(shows(FIRST.Id, "current", true), "returning, seen OLDER note: auto-shows")
check(shows(NOTES[COUNT - 1].Id, "migrated", true), "returning, one version behind: auto-shows")
check(not shows(NEWEST.Id, "current", true), "returning, seen EQUAL (newest): no")
check(not shows("2099-12-31-newer-than-this-build", "current", true), "returning, seen NEWER (newer server): no")
check(shows("", "current", true), "returning with nothing seen (pre-R58 save): auto-shows once")
for _, junk in { 42, true, {}, "junk id", "2026-10-30-UPPER", string.rep("a", 5000), 0 / 0 } :: { any } do
	check(shows(junk, "current", true), `malformed seen {tostring(junk)} = nothing seen → shows`)
end
check(not shows(nil, "new", true), "malformed + new: still never")

-- Actions (C→S).
local shown = ChangeNotesLogic.parseAction("shown", NEWEST.Id, "auto", NOW)
check(shown ~= nil and shown.source == "auto", "shown auto")
check(ChangeNotesLogic.parseAction("shown", NEWEST.Id, "menu", NOW) ~= nil, "shown menu")
check(ChangeNotesLogic.parseAction("shown", NEWEST.Id, nil, NOW) == nil, "shown needs a source")
check(ChangeNotesLogic.parseAction("shown", NEWEST.Id, "preview", NOW) == nil, "preview is never reported")
check(ChangeNotesLogic.parseAction("seen", NEWEST.Id, "anything", NOW).source == nil, "seen ignores arg")
local closed = ChangeNotesLogic.parseAction("closed", NEWEST.Id, 12.9, NOW)
check(closed ~= nil and closed.seconds == 12, "closed seconds floored")
check(ChangeNotesLogic.parseAction("closed", NEWEST.Id, 1e9, NOW).seconds == 600, "closed seconds clamped high")
check(ChangeNotesLogic.parseAction("closed", NEWEST.Id, -5, NOW).seconds == 0, "closed seconds clamped low")
check(ChangeNotesLogic.parseAction("closed", NEWEST.Id, 0 / 0, NOW).seconds == nil, "closed NaN ignored")
check(ChangeNotesLogic.parseAction("closed", NEWEST.Id, math.huge, NOW).seconds == nil, "closed inf ignored")
check(ChangeNotesLogic.parseAction("closed", NEWEST.Id, "12", NOW).seconds == nil, "closed string ignored")
check(ChangeNotesLogic.parseAction("cta", NEWEST.Id, nil, NOW) ~= nil, "cta")
check(ChangeNotesLogic.parseAction("grant", NEWEST.Id, nil, NOW) == nil, "unknown verb")
check(ChangeNotesLogic.parseAction("seen", "2099-01-01-unknown", nil, NOW) == nil, "unknown id")
check(ChangeNotesLogic.parseAction("seen", string.rep("a", 5000), nil, NOW) == nil, "oversized id")
check(
	ChangeNotesLogic.parseAction(nil, nil, nil, NOW) == nil and ChangeNotesLogic.parseAction({}, {}, {}, NOW) == nil,
	"junk payload"
)

-- Metric keys: the documented retention patterns accept every shipped note's keys.
KeySpec.register("noteId", function(id: string): boolean
	return ChangeNotesConfig.get(id) ~= nil
end)
for _, note in NOTES do
	for _, verb in { "seen", "cta", "closed" } do
		local action = ChangeNotesLogic.parseAction(verb, note.Id, nil, NOW)
		local key = ChangeNotesLogic.metricKey(action)
		check(key == `notes:{verb}:{note.Id}`, `{verb} key shape`)
		check(KeySpec.check("retention", key) == key, `KeySpec accepts {key}`)
	end
	for _, source in ChangeNotesConfig.Sources do
		local key = ChangeNotesLogic.metricKey(ChangeNotesLogic.parseAction("shown", note.Id, source, NOW))
		check(KeySpec.check("retention", key) == key, `KeySpec accepts {key}`)
	end
	check(KeySpec.check("retention", `notes:openSec:{note.Id}`) ~= nil, "openSec key documented")
end
for _, label in ChangeNotesConfig.OpenBucketLabels do
	check(KeySpec.check("retention", `notes:openLen:{label}`) ~= nil, `openLen:{label} documented`)
end
check(KeySpec.check("retention", "notes:shown:2099-01-01-nope:auto") == nil, "unknown note ids refused")
check(
	ChangeNotesLogic.openBucket(0) == "lt5"
		and ChangeNotesLogic.openBucket(5) == "5to15"
		and ChangeNotesLogic.openBucket(59) == "15to60"
		and ChangeNotesLogic.openBucket(600) == "gt60",
	"time-open buckets"
)

-- Client helpers.
check(ChangeNotesLogic.readSeen({ seen = FIRST.Id }) == FIRST.Id, "readSeen")
check(ChangeNotesLogic.readSeen(nil) == "" and ChangeNotesLogic.readSeen({ seen = 5 }) == "", "readSeen defaults")
check(ChangeNotesLogic.autoNote("", false, NOW) == NEWEST, "returning player: auto-open the newest")
check(ChangeNotesLogic.autoNote("", true, NOW) == nil, "once per session")
check(ChangeNotesLogic.autoNote(NEWEST.Id, false, NOW) == nil, "nothing unseen: no pop-up")

---------------------------------------------------------------------------------------------------
-- 5. ShowFrom over candidate lists
---------------------------------------------------------------------------------------------------
local v1 = candidate({ Id = "2026-11-02-one", Version = "0.4.0" })
local v2 = candidate({
	Id = "2026-11-03-two",
	Version = "0.5.0",
	Date = ChangeNotesConfig.unixDate(2026, 11, 3),
	ShowFrom = ChangeNotesConfig.unixDate(2026, 11, 4),
})
local list = { v1, v2 } :: any
local reveal = ChangeNotesConfig.unixDate(2026, 11, 4)
check(ChangeNotesConfig.visibleCountIn(list, reveal - 1) == 1, "hidden before ShowFrom")
check(ChangeNotesConfig.visibleCountIn(list, reveal) == 2, "visible at ShowFrom")
check(ChangeNotesConfig.nextShowFromIn(list, reveal - 1) == reveal, "next reveal")
check(ChangeNotesConfig.nextShowFromIn(list, reveal) == nil, "no reveal left")
check(ChangeNotesConfig.displayVersionIn(list, "0.5.0", reveal - 1) == "0.4.0", "label keeps the visible version")
check(ChangeNotesConfig.displayVersionIn(list, "0.5.0", reveal - 1, "0.4.2") == "0.4.2", "VisibleVersion while hidden")
check(ChangeNotesConfig.displayVersionIn(list, "0.5.0", reveal, "0.4.2") == "0.5.0", "after the reveal: Current")
check(#ChangeNotesConfig.validateVisibleVersion(list, "0.5.0", "0.4.2") == 0, "VisibleVersion ok")
check(#ChangeNotesConfig.validateVisibleVersion(list, "0.5.0", "0.5.0") > 0, "VisibleVersion must be older")
check(#ChangeNotesConfig.validateVisibleVersion(list, "0.5.0", "0.3.9") > 0, "VisibleVersion needs its note")
check(#ChangeNotesConfig.validateVisibleVersion(list, "0.5.0", nil) == 0, "nil VisibleVersion")
check(ChangeNotesConfig.visibleCount(NOW) == COUNT, "every shipped note is visible")

---------------------------------------------------------------------------------------------------
-- 6. Profile record (ProfileLogic)
---------------------------------------------------------------------------------------------------
local profile = ProfileLogic.defaultProfile()
check(profile.notes.seen == "" and profile.notes.at == 0, "default: nothing seen")
local reconciled = ProfileLogic.reconcile({})
check(reconciled.notes.seen == "" and reconciled.notes.at == 0, "pre-R58 save: nothing seen")
check(ProfileLogic.reconcile({ notes = { seen = 5, at = "x" } }).notes.seen == "", "malformed seen → ''")
check(ProfileLogic.reconcile({ notes = "junk" }).notes.at == 0, "malformed record → default")
check(
	ProfileLogic.reconcile({ notes = { seen = "2099-01-01-newer", at = 77 } }).notes.seen == "2099-01-01-newer",
	"newer server's id kept"
)
check(ProfileLogic.reconcile({ notes = { seen = NEWEST.Id, at = 1e20 } }).notes.at == 0, "absurd time → 0")
check(ProfileLogic.reconcile({ notes = { seen = NEWEST.Id, at = 12.5 } }).notes.at == 0, "fractional time → 0")
local migrated, status = ProfileLogic.migrate({ schemaVersion = 1, cash = 3 })
-- Schema v2 (owner R57 worlds): a v1 save migrates forward and the WHAT'S NEW record defaults.
check(
	status == "migrated" and migrated.schemaVersion == 2 and migrated.notes.seen == "",
	"v1 save migrates to v2 cleanly (notes default)"
)
profile.notes.seen = NEWEST.Id
profile.notes.at = 99
local snapshot = ProfileLogic.snapshot(profile, { saveStatus = "ok", paidRandomRestricted = true, policyKnown = true })
check(snapshot.notes.seen == NEWEST.Id and snapshot.notes.at == nil, "snapshot: seen only")
check(snapshot.notes ~= profile.notes, "snapshot copies")
local saved = ProfileLogic.toSave(profile)
check(
	ProfileLogic.reconcile(saved).notes.seen == NEWEST.Id and ProfileLogic.reconcile(saved).notes.at == 99,
	"round trip"
)

---------------------------------------------------------------------------------------------------
-- 7. HudPlacement: the bottom-right WHAT'S NEW corner
---------------------------------------------------------------------------------------------------
local Vector2 = roblox.Vector2
local function overlap(r1: any, r2: any): boolean
	return r1.x < r2.x + r2.w and r2.x < r1.x + r1.w and r1.y < r2.y + r2.h and r2.y < r1.y + r1.h
end
for _, case in
	{
		{ canvas = Vector2.new(1920, 1080), touch = false, safeTop = 58 },
		{ canvas = Vector2.new(1728, 972), touch = false, safeTop = 30 }, -- console, TV-safe canvas
		{ canvas = Vector2.new(1360, 630), touch = true, safeTop = 60, touchReserve = 190 }, -- phone
		{ canvas = Vector2.new(1440, 1080), touch = true, safeTop = 58, touchReserve = 230 }, -- tablet
	} :: { any }
do
	local base = {
		canvas = case.canvas,
		safeTop = case.safeTop,
		wides = { false, false, false, false, true, false, false, false, false },
		offerCount = 6,
		touch = case.touch,
		touchReserve = case.touchReserve,
		minTap = if case.touch then 71 else nil,
	}
	local plain = HudPlacement.compute(base)
	check(plain.corner == nil, "no chip: no corner")
	local withChip = table.clone(base)
	withChip.corner = Vector2.new(260, if case.touch then 71 else 60)
	local layout = HudPlacement.compute(withChip)
	local corner = layout.corner
	check(corner ~= nil, "corner placed")
	local canvas = case.canvas
	check(corner.x + corner.w <= canvas.X and corner.x >= 0 and corner.y >= 0, `corner inside canvas {canvas}`)
	check(corner.y + corner.h <= canvas.Y - 16 + 0.001, "corner above the bottom margin")
	local right = layout.right
	local stack = right.slots * right.slot + math.max(0, right.slots - 1) * right.gap
	local offers = { x = right.x - right.slot / 2, y = right.y, w = right.slot, h = stack }
	check(not overlap(corner, offers), `corner never overlaps the offers ({canvas})`)
	check(right.slots >= 1, "at least one offer slot stays")
	if case.touch then
		check(corner.y + corner.h <= canvas.Y - case.touchReserve + 0.001, "corner above the jump-button reserve")
	end
	-- Everything else is unchanged by the chip.
	check(layout.left.x == plain.left.x and layout.left.cell == plain.left.cell, "left grid unchanged")
	check(layout.topY == plain.topY and layout.bottomMaxWidth == plain.bottomMaxWidth, "top / bottom unchanged")
end

---------------------------------------------------------------------------------------------------
-- 8. Frozen
---------------------------------------------------------------------------------------------------
check(table.isfrozen(NOTES) and table.isfrozen(FIRST) and table.isfrozen(FIRST.Hero), "notes frozen")
check(table.isfrozen(FIRST.Sections[1].Items[1]), "items frozen")

print(`change-notes: {checks} checks passed`)
