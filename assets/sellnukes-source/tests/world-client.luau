--!strict
--[[
	Worlds client regressions (owner R57 World 2, plan §5 "world-client"). Run:
		lune run tests/world-client

	Proves on the SHIPPED modules (Client/Worlds/{WorldObjectives, WorldClientLogic},
	Shared/Config/WorldClientConfig):
	  1. Objectives (spec §14): Dino's first run walks build -> click -> hire -> done with the
	     spec's texts and the right targets; later runs, Nuke Town and junk states show nothing.
	  2. Tab model: one tab per WorldsConfig.Order world with a style row; open / locked / closed
	     states (kill switch wins), the current-world flag, LB / RB cycling wraps both ways.
	  3. Presets: every world's ambience keys exist (lighting + music); every applied lighting
	     preset is valid (finite, in engine ranges); Nuke Town's is captured; music falls back;
	     ambience beds (the Dino jungle bed) are real SFX looped every track length (clamped).
	  4. Fail texts: every TravelRules reason has a friendly text (the plan §3.4 list, plus
	     TravelRules.Reasons once W4 exports it); unknown reasons fall back, raw text never shows.
	  5. Unlock once-rule, lock hint (BoomDash Delivery + area-2 progress), currency / rate
	     formats, link lines (spec §6.5 texts + caps), rejoin chip, Teleport NEW dot, throttle.
	  6. Config sanity: world offers point at real products; objective texts exist for every world;
	     every analytics origin maps to an allowlisted ClientFunnel source.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local Color3 = roblox.Color3

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local WorldObjectives = loader.load("src/client/Worlds/WorldObjectives")
local Logic = loader.load("src/client/Worlds/WorldClientLogic")
local Config = loader.load("src/shared/Config/WorldClientConfig")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")
local AudioConfig = loader.load("src/shared/Config/AudioConfig")
local SoundAssets = loader.load("src/shared/Config/SoundAssets")
local AnalyticsConfig = loader.load("src/shared/Config/AnalyticsConfig")

local checks = 0
local function ok(condition: any, label: string)
	checks += 1
	if not condition then
		error(`[world-client] FAILED: {label}`, 2)
	end
end

local dino = WorldsConfig.get("dino")
ok(dino ~= nil, "Dino Valley is registered")
local dinoIndex = dino.economy
local area1 = dinoIndex.Areas[1]
local builderId = area1.producer.builtBy
local managerId = dinoIndex.ManagerPadOf[area1.producer.id]
ok(builderId ~= nil and managerId ~= nil, "Dino area 1 has a builder pad and a manager pad")

-- A tycoon state owning `ids` (pads as the profile stores them).
local function stateWith(ids: { string }): any
	local pads = {}
	for _, id in ids do
		pads[id] = true
	end
	return { pads = pads, producers = {}, area = 1 }
end

-- 1. Objectives ---------------------------------------------------------------------------------
local s1 = WorldObjectives.next(stateWith({}), "dino")
ok(s1 ~= nil and s1.step == 1, "fresh Dino run: step 1")
ok(s1.text == "Step on the green pad to build your Stone Bench!", `step 1 text (got "{s1.text}")`)
ok(s1.padId == builderId, "step 1 points at the builder pad")
local s2 = WorldObjectives.next(stateWith({ builderId }), "dino")
ok(s2 ~= nil and s2.step == 2, "builder owned: step 2")
ok(s2.text == "Click the bench to carve Pebble Nukes!", `step 2 text (got "{s2.text}")`)
ok(s2.producerId == area1.producer.id and s2.padId == nil, "step 2 points at the producer")
-- Owning the builder + the next pad -> step 3 points at the NEXT pad on the way.
local second = area1.pads[2].id
local s3 = WorldObjectives.next(stateWith({ builderId, second }), "dino")
ok(s3 ~= nil and s3.step == 3, "two pads owned: step 3")
ok(s3.text == "Hire Rocky Raptor!", `step 3 text (got "{s3.text}")`)
ok(s3.padId == area1.pads[3].id, "step 3 points at the next pad on the way to the manager")
-- Every pad before the manager owned -> the arrow is on the manager itself.
local before: { string } = {}
for _, pad in area1.pads do
	if pad.id == managerId then
		break
	end
	table.insert(before, pad.id)
end
local s3b = WorldObjectives.next(stateWith(before), "dino")
ok(s3b ~= nil and s3b.step == 3 and s3b.padId == managerId, "manager next: the arrow is on the manager")
table.insert(before, managerId)
ok(WorldObjectives.next(stateWith(before), "dino") == nil, "manager owned: objectives done")
ok(WorldObjectives.next(stateWith({}), "dino", 1) == nil, "later runs show no objective")
ok(WorldObjectives.next(stateWith({}), "main") == nil, "Nuke Town keeps its server tutorial")
ok(WorldObjectives.next(nil, "dino") == nil, "no state: nothing")
ok(WorldObjectives.next({ pads = 5 }, "dino") == nil, "junk state: nothing")
ok(WorldObjectives.next(stateWith({}), "atlantis") == nil, "unknown world: nothing")

-- 2. Tab model ------------------------------------------------------------------------------------
local function yes(_id: string): boolean
	return true
end
local function no(_id: string): boolean
	return false
end
local tabs = Logic.tabs("main", function(id: string): boolean
	return id == "main"
end, yes)
ok(#tabs == #WorldsConfig.Order, "one tab per world")
for index, worldId in WorldsConfig.Order do
	ok(tabs[index].id == worldId, `tab {index} follows WorldsConfig.Order`)
	ok(Config.Tabs[worldId] ~= nil, `world {worldId} has a tab style row`)
	ok(#Config.Tabs[worldId].label > 0 and #Config.Tabs[worldId].short > 0, `{worldId} tab labels`)
end
ok(tabs[1].state == "open" and tabs[1].current, "Nuke Town: open + current")
ok(tabs[2].state == "locked" and not tabs[2].current, "Dino locked before the unlock")
ok(tabs[2].label == "DINO VALLEY" and tabs[1].label == "NUKE TOWN", "spec tab labels")
local closedTabs = Logic.tabs("main", yes, no)
ok(closedTabs[1].state == "open", "the kill switch never closes Nuke Town")
ok(closedTabs[2].state == "closed", "the kill switch closes Dino (wins over unlocked)")
local inDino = Logic.tabs("dino", yes, yes)
ok(inDino[2].current and inDino[2].state == "open", "in Dino: Dino tab current + open")
-- RB / LB walk WorldsConfig.Order in both directions and wrap at the ends, for ANY number of
-- worlds (R70: main -> dino -> moon -> main).
local order = WorldsConfig.Order
for index, worldId in order do
	local nextId = order[index % #order + 1]
	ok(Logic.cycle(tabs, worldId, 1) == nextId, `RB: {worldId} -> {nextId}`)
	local previousId = order[(index - 2) % #order + 1]
	ok(Logic.cycle(tabs, worldId, -1) == previousId, `LB: {worldId} -> {previousId}`)
end
ok(Logic.cycle(tabs, order[#order], 1) == "main", "RB wraps: the last world -> main")
ok(Logic.cycle(tabs, "main", -1) == WorldsConfig.Order[#WorldsConfig.Order], "LB wraps backwards")
ok(Logic.cycle({}, "main", 1) == "main", "no tabs: stays")
ok(Logic.style("atlantis").label == "ATLANTIS", "a world without a style row still gets a tab")

-- 3. Presets --------------------------------------------------------------------------------------
for _, worldId in WorldsConfig.Order do
	local def = WorldsConfig.get(worldId)
	local preset = Config.Lighting[def.ambience.lighting]
	ok(preset ~= nil, `{worldId}: lighting preset "{def.ambience.lighting}" exists`)
	local valid, problem = Logic.validatePreset(preset)
	ok(valid, `{worldId}: lighting preset valid ({problem})`)
	ok(Config.Music[def.ambience.music] ~= nil, `{worldId}: music key "{def.ambience.music}" mapped`)
end
ok(Config.Lighting.main.capture == true, "Nuke Town's look is captured from the place, never overwritten")
ok(Config.Lighting.dino.capture == false and Config.Lighting.dino.Atmosphere ~= nil, "Dino applies its haze")
ok(
	not Logic.validatePreset({ capture = false, Ambient = Color3.new(), OutdoorAmbient = Color3.new() }),
	"a preset without Atmosphere is rejected"
)
local badPreset = table.clone(Config.Lighting.dino)
local badAtmosphere = table.clone(Config.Lighting.dino.Atmosphere)
badAtmosphere.Density = 0 / 0
badPreset.Atmosphere = badAtmosphere
ok(not Logic.validatePreset(badPreset), "NaN density is rejected")
for key in Config.Lighting do
	local preset = Config.Lighting[key]
	ok(preset.ClockTime == nil, `{key}: never touches ClockTime (admin SetTimeOfDay)`)
end
local function has(...: string): (string) -> boolean
	local set = {}
	for _, name in { ... } do
		set[name] = true
	end
	return function(name: string): boolean
		return set[name] == true
	end
end
ok(Logic.musicContext("music_dino_valley", has("dino", "hub")) == "dino", "Dino plays its own playlist")
ok(Logic.musicContext("music_dino_valley", has("hub")) == "hub", "missing Dino playlist falls back to hub")
ok(Logic.musicContext("music_nuke_town", has("hub", "dino")) == nil, "Nuke Town = automatic contexts")
ok(Logic.musicContext("nope", has("hub")) == nil, "unknown music key = automatic")

-- Ambience beds (spec §14 "jungle ambience bed"): a real SFX, looped every track length.
local function lengths(map: { [string]: number }): (string) -> number?
	return function(key: string): number?
		return map[key]
	end
end
local bed, period = Logic.ambienceBed("music_dino_valley", has("amb_jungle"), lengths({ amb_jungle = 69 }))
ok(bed == "amb_jungle" and period == 69, "Dino loops the jungle bed every 69 s")
bed, period = Logic.ambienceBed("music_dino_valley", has("amb_jungle"), lengths({}))
ok(bed == "amb_jungle" and period == Config.BedFallbackSeconds, "unknown bed length -> fallback period")
bed, period = Logic.ambienceBed("music_dino_valley", has("amb_jungle"), lengths({ amb_jungle = 0.01 }))
ok(period == Config.BedMinSeconds, "a tiny bed length is clamped (never a tight loop)")
bed, period = Logic.ambienceBed("music_dino_valley", has("amb_jungle"), lengths({ amb_jungle = 0 / 0 }))
ok(period == Config.BedFallbackSeconds, "a NaN bed length uses the fallback")
bed = Logic.ambienceBed("music_dino_valley", has(), lengths({ amb_jungle = 69 }))
ok(bed == nil, "a bed that is not a known SFX never plays")
bed, period = Logic.ambienceBed("music_nuke_town", has("amb_jungle"), lengths({ amb_jungle = 69 }))
ok(bed == nil and period == 0, "Nuke Town has no bed")
ok(Logic.ambienceBed("nope", has("amb_jungle"), lengths({})) == nil, "unknown music key: no bed")
-- The SHIPPED beds resolve against the real audio tables (key + length).
for key, music in Config.Music do
	if music.bed ~= nil then
		ok(AudioConfig.Sfx[music.bed] ~= nil, `{key}: bed "{music.bed}" is an AudioConfig.Sfx key`)
		ok((SoundAssets.SfxIds[music.bed] or 0) > 0, `{key}: bed "{music.bed}" has an uploaded sound id`)
		local track = SoundAssets.LibrarySfx[music.bed]
		local realBed, realPeriod = Logic.ambienceBed(key, function(name: string): boolean
			return AudioConfig.Sfx[name] ~= nil
		end, function(name: string): number?
			local row = SoundAssets.LibrarySfx[name]
			return if row ~= nil then row.seconds else nil
		end)
		ok(realBed == music.bed, `{key}: the shipped bed resolves`)
		ok(track == nil or realPeriod == track.seconds, `{key}: loop period = the track length`)
	end
end
ok(AudioConfig.Sfx.warp_whoosh ~= nil and (SoundAssets.SfxIds.warp_whoosh or 0) > 0, "the warp whoosh is a real sound")

-- 4. Fail texts -----------------------------------------------------------------------------------
local PLAN_REASONS = {
	"unknownWorld",
	"badTarget",
	"disabled",
	"locked",
	"noPlot",
	"revealPending",
	"dead",
	"busy",
	"cooldown",
	"areaLocked",
	"plotEmpty",
	"noPass",
}
for _, reason in PLAN_REASONS do
	ok(type(Config.FailText[reason]) == "string" and #Config.FailText[reason] > 0, `fail text for "{reason}"`)
	ok(table.find(Config.TravelReasons, reason) ~= nil, `TravelReasons lists "{reason}"`)
	ok(Logic.failText(reason) == Config.FailText[reason], `failText("{reason}")`)
end
-- W4's TravelRules (server) once it exists: every reason it can return has a text.
if fs.isFile("src/server/Tycoon/TravelRules.luau") then
	local loaded, TravelRules = pcall(loader.load, "src/server/Tycoon/TravelRules")
	if loaded and type(TravelRules) == "table" and type(TravelRules.Reasons) == "table" then
		for _, reason in TravelRules.Reasons do
			ok(Config.FailText[reason] ~= nil, `TravelRules reason "{reason}" has a fail text`)
		end
	end
end
ok(Logic.failText("<b>hax</b>") == Config.FailFallback, "unknown reason: fallback text (raw text never shown)")
ok(Logic.failText(nil) == Config.FailFallback, "missing reason: fallback text")
ok(Logic.failText(42) == Config.FailFallback, "non-string reason: fallback text")

-- 5. Rules ----------------------------------------------------------------------------------------
local slack = Config.Unlock.JoinSlackSeconds
ok(Logic.shouldShowUnlock(1000, 1000, slack), "unlocked at boot: show")
ok(Logic.shouldShowUnlock(2000, 1000, slack), "unlocked during the session: show")
ok(Logic.shouldShowUnlock(1000 - slack + 1, 1000, slack), "legacy unlock while the profile loaded: show")
ok(not Logic.shouldShowUnlock(1000 - slack - 60, 1000, slack), "unlocked in an earlier session: never again")
ok(not Logic.shouldShowUnlock(0, 1000, slack), "locked (0): no popup")
ok(not Logic.shouldShowUnlock("x", 1000, slack), "junk: no popup")
ok(not Logic.shouldShowUnlock(0 / 0, 1000, slack), "NaN: no popup")
-- W12 QA: an unsynced client clock reads 0; an unknown anchor never makes an old unlock look new.
ok(not Logic.shouldShowUnlock(1000, 0, slack), "anchor 0 (clock not synced): no popup")
ok(not Logic.shouldShowUnlock(1000, nil, slack), "anchor unknown: no popup")
ok(not Logic.shouldShowUnlock(1000, 0 / 0, slack), "anchor NaN: no popup")
ok(Logic.sessionAnchor(1793418000.5, 1793418100) == 1793418000.5, "anchor = the server's PlotAssignedAt")
ok(Logic.sessionAnchor(nil, 1793418100) == 1793418100, "anchor falls back to the first synced reading")
ok(Logic.sessionAnchor(0, 0) == nil, "anchor: an unsynced 0 is never an anchor")
ok(Logic.sessionAnchor("x", 0 / 0) == nil, "anchor: junk is never an anchor")
-- The once-rule end to end with the fixed anchor: an old unlock (an earlier session) stays quiet,
-- a real unlock later this session shows.
local anchor = Logic.sessionAnchor(1793418000, nil)
ok(not Logic.shouldShowUnlock(1793400000, anchor, slack), "old unlock + a real anchor: no popup at join")
ok(Logic.shouldShowUnlock(1793418600, anchor, slack), "a real unlock later this session: popup")

-- Owner R130: the popup waits until the player is one Nuke Town area past the unlock area (or has
-- rebirthed); a world unlocked in an earlier session owes it when that area is crossed THIS session.
ok(Logic.popupArea(WorldsConfig.get("dino")) == 4, `Dino popup area 4 ({Logic.popupArea(WorldsConfig.get("dino"))})`)
ok(Logic.popupArea(WorldsConfig.get("moon")) == 6, `Moon popup area 6 ({Logic.popupArea(WorldsConfig.get("moon"))})`)
ok(Logic.popupArea(WorldsConfig.get("main")) == 1, "Nuke Town (always unlocked) is never gated")
local function facts(over: { [string]: any }): any
	local base: { [string]: any } = {
		unlocked = true,
		unlockedAt = 1793418600, -- unlocked during this session
		anchor = anchor,
		slack = slack,
		mainArea = 3,
		startArea = 1,
		rebirths = 0,
		visits = 0,
		popupArea = 4,
	}
	for key, value in over do
		base[key] = value
	end
	return base
end
ok(not Logic.unlockPopupOwed(facts({})), "unlocked at area 3 this session: NO popup yet (R130)")
ok(Logic.unlockPopupOwed(facts({ mainArea = 4 })), "same session, area 4 reached: popup")
ok(not Logic.unlockPopupOwed(facts({ unlocked = false, mainArea = 4 })), "locked world: never")
ok(
	Logic.unlockPopupOwed(facts({ unlockedAt = 1793400000, startArea = 3, mainArea = 4 })),
	"unlocked in an earlier session, crossed into area 4 this session, never visited: popup"
)
ok(
	not Logic.unlockPopupOwed(facts({ unlockedAt = 1793400000, startArea = 3, mainArea = 3 })),
	"unlocked earlier, still in area 3: no popup"
)
ok(
	not Logic.unlockPopupOwed(facts({ unlockedAt = 1793400000, startArea = 3, mainArea = 4, visits = 2 })),
	"unlocked earlier and already visited: no popup on the crossing"
)
ok(
	not Logic.unlockPopupOwed(facts({ unlockedAt = 1793400000, startArea = 5, mainArea = 5 })),
	"unlocked earlier, session started past the popup area: no popup (chip / NEW dot remain)"
)
do
	-- A nil field in a table literal is no key at all, so clear the default explicitly.
	local unsynced = facts({ unlockedAt = 1793400000, mainArea = 4 })
	unsynced.startArea = nil
	ok(not Logic.unlockPopupOwed(unsynced), "start area not synced yet: no crossing popup")
end
ok(Logic.unlockPopupOwed(facts({ mainArea = 1, rebirths = 1 })), "rebirthed player: the area gate is skipped")
ok(
	not Logic.unlockPopupOwed(facts({ unlockedAt = 1793400000, startArea = 10, mainArea = 1, rebirths = 1 })),
	"rebirth resets the area: an old unlock is not shown again"
)
ok(not Logic.unlockPopupOwed(facts({ mainArea = 0 / 0 })), "junk area counts as 0: no popup")
ok(
	not Logic.unlockPopupOwed(facts({ anchor = 0, mainArea = 4, startArea = 4 })),
	"unsynced anchor, no crossing: no popup"
)

local area3 = TycoonConfig.Areas[3].name
local hint, areaName, bought, total = Logic.lockHint("dino", nil)
ok(areaName == area3, `lock hint names Nuke Town area 3 ("{areaName}")`)
ok(hint == `Reach {area3} to unlock!`, `lock hint text ("{hint}")`)
ok(bought == 0 and total == 0, "no tycoon: no progress")
local mainPads = {}
local area2Pads = TycoonConfig.Index.AreaPads[2]
mainPads[area2Pads[1].id] = true
mainPads[area2Pads[2].id] = true
local _, _, b2, t2 = Logic.lockHint("dino", { pads = mainPads, producers = {}, area = 2 })
ok(b2 == 2 and t2 == #area2Pads, `lock progress = area-2 pads ({b2} / {t2})`)

ok(
	Logic.formatAmount(dino.currency, 4.5e6) == "4.5M Bones",
	`Bones amount ({Logic.formatAmount(dino.currency, 4.5e6)})`
)
ok(Logic.formatAmount(WorldsConfig.get("main").currency, 1.2e12) == "$1.2T", "Cash amount")
ok(Logic.formatAmount(dino.currency, 0 / 0) == "0 Bones", "NaN amount shows 0")
ok(Logic.formatRate(dino.currency, 1250) == "+1.25K/s Bones", `Bones rate ({Logic.formatRate(dino.currency, 1250)})`)
ok(Logic.formatRate(WorldsConfig.get("main").currency, 1259) == "+$1.25K/s", "Cash rate")

local lines = Logic.linkLines({ main = 5, dino = 3 })
-- Two lines per extra world (toMain + fromMain), in WorldsConfig.extra() order: Dino's come first.
ok(#lines == 2 * #WorldsConfig.extra(), "two link lines per non-main world")
ok(WorldsConfig.extra()[1].id == "dino", "Dino is the first extra world (its lines are [1] / [2])")
ok(lines[1].text == "Dino Bonus: +30% Nuke Town cash (3 Dino rebirths)", `toMain line ("{lines[1].text}")`)
ok(lines[2].text == "Nuke Town Bonus: +25% Bones", `fromMain line ("{lines[2].text}")`)
local capped = Logic.linkLines({ main = 99, dino = 99 })
ok(capped[1].percent == 200 and capped[2].percent == 50, "link lines cap at +200 % / +50 %")
local hostile = Logic.linkLines({ main = -4, dino = 0 / 0 })
ok(hostile[1].percent == 0 and hostile[2].percent == 0, "hostile counts read as 0")
ok(Logic.linkLines({ main = 0, dino = 1 })[1].text == "Dino Bonus: +10% Nuke Town cash (1 Dino rebirth)", "singular")

ok(Logic.rejoinOffer("dino", "main", true, true), "rejoin chip: last world Dino, now in Nuke Town")
ok(not Logic.rejoinOffer("main", "main", true, true), "rejoin chip: last world Nuke Town -> none")
ok(not Logic.rejoinOffer("dino", "dino", true, true), "rejoin chip: already in Dino -> none")
ok(not Logic.rejoinOffer("dino", "main", false, true), "rejoin chip: locked -> none")
ok(not Logic.rejoinOffer("dino", "main", true, false), "rejoin chip: closed -> none")
ok(not Logic.rejoinOffer("atlantis", "main", true, true), "rejoin chip: unknown world -> none")

-- Rejoin chip layout between the HUD zones (phones stack it instead of covering the left grid).
local wide = Logic.chipLayout(900, 720, 440)
ok(not wide.stacked and wide.width == 720 and wide.scale == 1, "chip: wide band -> one row")
local stacked = Logic.chipLayout(560, 720, 440)
ok(stacked.stacked and stacked.width == 560 and stacked.scale == 1, "chip: phone band -> two rows, full size")
local squeezed = Logic.chipLayout(330, 720, 440)
ok(squeezed.stacked and squeezed.width == 440 and math.abs(squeezed.scale - 0.75) < 1e-9, "chip: tiny band shrinks")
ok(Logic.chipLayout(10, 720, 440).scale == Config.Rejoin.MinScale, "chip: never below MinScale")
ok(not Logic.chipLayout(0 / 0, 720, 440).stacked, "chip: NaN band -> default one row")
ok(not Logic.chipLayout(-5, 720, 440).stacked, "chip: zones not laid out -> one row")

ok(Logic.isNewWorld({ unlocked = true, stats = { visits = 0 } }), "NEW dot: unlocked, never visited")
ok(Logic.isNewWorld({ unlocked = true }), "NEW dot: no stats yet = never visited")
ok(not Logic.isNewWorld({ unlocked = true, stats = { visits = 2 } }), "NEW dot off after a visit")
ok(not Logic.isNewWorld({ unlocked = false, stats = { visits = 0 } }), "NEW dot off while locked")
ok(not Logic.isNewWorld(nil), "NEW dot off without data")

ok(Logic.travelAllowed(10, 8.9, Config.TravelThrottleSeconds), "throttle: 1.1 s later allowed")
ok(not Logic.travelAllowed(10, 9.5, Config.TravelThrottleSeconds), "throttle: 0.5 s later refused")

-- 6. Config sanity --------------------------------------------------------------------------------
for worldId, offers in Config.Offers do
	ok(WorldsConfig.get(worldId) ~= nil, `offers for a known world ({worldId})`)
	for _, offer in offers do
		ok(MonetizationConfig.getProduct(offer.product) ~= nil, `offer {offer.key} -> product {offer.product}`)
	end
end
for _, def in WorldsConfig.extra() do
	local texts = Config.Objectives[def.id] or Config.Objectives.default
	ok(texts.build ~= nil and texts.click ~= nil and texts.hire ~= nil, `{def.id}: objective texts`)
end
ok(Config.Overlay.MinSeconds == 1.2, "warp overlay stays at least 1.2 s (spec §4.5)")
ok(Config.Overlay.MaxSeconds > 4, "the overlay's safety close is after the server's 4 s deadline")
ok(Config.RejoinChipSeconds == 20 and Config.Rejoin.Seconds == 20, "rejoin chip shows 20 s (spec §4.6)")
ok(Config.TabHeight >= 44, "tabs are tall enough for 44 pt taps")

-- Analytics origins (W12 ClientFunnel): every source the worlds UI reports is allowlisted, and the
-- two R57 screens are funnel screens (else the server folds them into "other" / drops them).
local funnel = AnalyticsConfig.ClientFunnel
for origin, source in Config.AnalyticsSource do
	ok(table.find(funnel.Sources, source) ~= nil, `analytics origin {origin} -> allowlisted source "{source}"`)
end
for _, origin in { "menu", "popup", "chip", "portal", "auto" } do
	ok(Config.AnalyticsSource[origin] ~= nil, `analytics origin "{origin}" is mapped`)
end
ok(table.find(funnel.Screens, "WorldUnlocked") ~= nil, "WorldUnlocked is a funnel screen")
ok(table.find(funnel.Screens, "WorldTravel") ~= nil, "WorldTravel is a funnel screen")
ok(Config.IntentMatchSeconds > Config.TravelThrottleSeconds, "an intent outlives the client throttle")

-- R70 (World 3, W10b): portals, night skies and every registered world's client rows.
do
	-- Portals: a world without a row falls back field by field to the shared Unlock model / icon.
	local fallback = Logic.portal("nowhere")
	ok(fallback.model == Config.Unlock.ModelKey and fallback.icon == Config.Unlock.ModelIcon, "portal fallback")
	ok(fallback.pets == "pets", "portal fallback pets word")
	local portals = (Config :: any).Portals
	if type(portals) == "table" then
		for worldId, row in portals do
			ok(WorldsConfig.get(worldId) ~= nil, `Portals.{worldId}: a registered world`)
			ok(type(row.model) == "string" and type(row.icon) == "string", `Portals.{worldId}: model + icon`)
			ok(Logic.portal(worldId).model == row.model, `Portals.{worldId}: read by WorldClientLogic.portal`)
		end
	end
	-- Night sky looks.
	local face = "rbxassetid://123"
	local sky = {
		SkyboxBk = face,
		SkyboxDn = face,
		SkyboxFt = face,
		SkyboxLf = face,
		SkyboxRt = "",
		SkyboxUp = face,
		StarCount = 3000,
		CelestialBodiesShown = false,
		SunAngularSize = 11,
	}
	ok(Logic.validateSky(sky), "a valid sky look passes (an empty face is allowed)")
	local broken = table.clone(sky)
	broken.SkyboxUp = "http://example.com/x.png"
	ok(not Logic.validateSky(broken), "a non-asset skybox face is refused")
	broken = table.clone(sky)
	broken.StarCount = 99999
	ok(not Logic.validateSky(broken), "StarCount out of range is refused")
	broken = table.clone(sky)
	broken.CelestialBodiesShown = nil
	ok(not Logic.validateSky(broken), "CelestialBodiesShown must be a boolean")
	ok(not Logic.validateSky("sky"), "a non-table sky is refused")
	for presetKey, preset in Config.Lighting do
		if (preset :: any).Sky ~= nil then
			ok(Logic.validateSky((preset :: any).Sky), `Lighting.{presetKey}: sky look valid`)
		end
	end
	-- Every registered world (3+): a tab model entry, a lighting preset that validates (or the main
	-- capture), a lock hint naming a real area, and objective texts.
	local main = { tycoon = { pads = {} } }
	local allTabs = Logic.tabs(WorldsConfig.MAIN, yes, yes)
	ok(#allTabs == #WorldsConfig.Order, "one tab per registered world")
	for _, tab in allTabs do
		ok(tab.state == "open", `{tab.id}: open when unlocked + enabled`)
	end
	for _, def in WorldsConfig.extra() do
		local preset = Config.Lighting[def.ambience.lighting]
		ok(preset ~= nil, `{def.id}: lighting preset "{def.ambience.lighting}" exists`)
		if preset ~= nil then
			ok(Logic.validatePreset(preset), `{def.id}: lighting preset validates`)
		end
		local hint, areaName = Logic.lockHint(def.id, main.tycoon)
		ok(type(hint) == "string" and #areaName > 0, `{def.id}: lock hint names an area`)
		ok(Logic.style(def.id).label ~= "", `{def.id}: tab style`)
	end
end

print(`[world-client] {checks} checks passed`)
