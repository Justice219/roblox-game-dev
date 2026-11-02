--!strict
--[[
	Analytics recorder regressions (lune run tests/analytics-recorders). Drives the REAL Runtime,
	Sessions, Recorders, Revenue and KeySpec modules with fake players / profiles and a controllable
	clock (only the player-data boundary is faked, through Runtime.setDeps).

	Proves:
	  1. KeySpec: every documented recorder pattern compiles; every <kind> is built in or one the
	     owning system will register; valid keys pass, undocumented / wrong-id keys are refused,
	     unregistered kinds fold into "other" past their cap, registered kinds are exact.
	  2. A brand-new player's first session: new / dau / cohort:all, the funnel (buffered client step
	     + every tycoon step), first-day milestones, uniques, time-to-pad / time-to-area on the first
	     run, the Unlock pad opening area 2, level marks, income share, economy reasons, Roblox
	     forwarding (onboarding order, progression, custom events, batched income).
	  3. Generic recorders: allowlisted keys count (+ unique / first-day hooks), bad keys are refused
	     and counted as ops:badKey:<family>, bad amounts refused.
	  4. Revenue: prompt → closed (dwell), accounting hooks (onGrant parks a finalized record in the
	     outbox, onDurable counts it once in Studio and clears it), pass purchase, offers seen.
	  5. Client reports: FunnelStep allowlists / once / caps, ClientDevice allowlist.
	  6. Rebirth (run clock reset), offline payout, tutorial steps once per session.
	  7. Session end: length / device / cohort device / first-session funnel at leave / leave area.
	  8. Retention: the D1 return (r1, r1:<milestone>, sessNo:2, devR1), a midnight carry-over
	     (r1:carry + the marker) and its genuine rejoin (r1:carryRejoin).
	  9. New Player Mode diversion and staff profiles.
	 10. Every recorded key is documented in AnalyticsConfig.Metrics (COPY FOR AI can explain it).
	 11. Worlds (R57): the worlds family + currencies + visit surfaces per extra world; KeySpec world
	     kinds (world-scoped areas / upgrades / steps, any world's pad / producer ids); a Dino player
	     end to end (unlock, capped popup claims, travel, visitor / first visit, time per world, routed
	     pads / clicks / income / upgrades, world first run, funnel + progression forwarding, rebirth,
	     Amber shop, offline, refusals, locked portal throttle, Bones batching, attribute fallback).
]]

local Loader = require("./analytics-fixtures/Loader")
local env = Loader.new()
local check, done = Loader.checker()

local DAY = 20756 -- 2026-10-30
env.setTime(DAY * 86400 + 10 * 3600)
env.setClock(1000)

local AnalyticsConfig = env.load("src/shared/Config/AnalyticsConfig")
local AnalyticsMarks = env.load("src/shared/Config/AnalyticsMarks")
local TycoonConfig = env.load("src/shared/Config/TycoonConfig")
local MonetizationConfig = env.load("src/shared/Config/MonetizationConfig")
local AnalyticsReport = env.load("src/shared/Analytics/AnalyticsReport")
local Recorder = env.load("src/server/Analytics/Recorder")
local Runtime = env.load("src/server/Analytics/Runtime")
local Sessions = env.load("src/server/Analytics/Sessions")
local Recorders = env.load("src/server/Analytics/Recorders")
local Revenue = env.load("src/server/Analytics/Revenue")
local KeySpec = env.load("src/server/Analytics/KeySpec")

-- Fake player-data boundary.
local profiles: { [any]: any } = {}
local saves = 0
Runtime.setDeps({
	getProfile = function(player: any): any
		return profiles[player]
	end,
	canMutate = function(player: any): boolean
		return profiles[player] ~= nil
	end,
	markSaved = function()
		saves += 1
	end,
	isAdmin = function(): boolean
		return false
	end,
})

local function newProfile(): any
	return {
		analytics = AnalyticsMarks.newAnalytics(),
		tycoon = { area = 1, pads = {} },
		rebirths = 0,
		totalEarned = 0,
		cash = 0,
		gems = 0,
		pets = { owned = { a = {}, b = {} }, equipped = { "a" } },
	}
end

-- Today's counters of a family (unsaved deltas).
local function today(family: string): { [string]: number }
	local copy = Recorder.unsavedCopy()
	local days = copy[Recorder.today()]
	return if days ~= nil then days[family] or {} else {}
end
local function value(family: string, key: string): number
	return today(family)[key] or 0
end

-- 1. KeySpec ------------------------------------------------------------------------------------------
do
	check(#KeySpec.invalidPatterns() == 0, `invalid recorder patterns: {table.concat(KeySpec.invalidPatterns(), ", ")}`)
	-- Kinds a later system registers (AnalyticsService.registerIds); everything else is built in.
	local registrable = {
		eggId = true,
		petId = true,
		crateId = true,
		rewardKind = true,
		boostKey = true,
		codeId = true,
		sliceId = true,
		aaKind = true,
		decorId = true,
		eventItemId = true,
		noteId = true, -- WHAT'S NEW note ids (ChangeNotesService registers them exactly, owner R58)
		seasonId = true, -- Nuke Pass season ids (PassService registers PassConfig seasons, owner R78)
		flavorId = true, -- Surprise Batch flavours (FlavorService registers FlavorConfig.isSpecial, owner R89)
	}
	for _, kind in KeySpec.kindsInUse() do
		check(KeySpec.isKnownKind(kind) or registrable[kind] == true, `kind {kind} is built in or registrable`)
	end
	check(KeySpec.check("tycoon", "pad:a1_workbench") == "pad:a1_workbench", "pad id accepted")
	check(KeySpec.check("tycoon", "pad:nope") == nil, "unknown pad refused")
	check(KeySpec.check("tycoon", "area:2") == "area:2" and KeySpec.check("tycoon", "area:11") == nil, "area range")
	check(
		KeySpec.check("retention", "daily:claim:7") ~= nil and KeySpec.check("retention", "daily:claim:8") == nil,
		"range part"
	)
	check(
		KeySpec.check("retention", "wheel:spin:free") ~= nil and KeySpec.check("retention", "wheel:spin:cheat") == nil,
		"choice part"
	)
	check(KeySpec.check("tycoon", "upgradeMode:max") ~= nil, "literal choice with digits")
	-- Owner R64: the AutoClicker Settings toggle (TycoonService on SettingsService.Changed).
	check(KeySpec.check("tycoon", "autoClicker:on") == "autoClicker:on", "auto clicker on key")
	check(KeySpec.check("tycoon", "autoClicker:off") == "autoClicker:off", "auto clicker off key")
	check(KeySpec.check("tycoon", "autoClicker:maybe") == nil, "auto clicker key is bounded")
	check(KeySpec.check("tycoon", "areaB:3:<5m") ~= nil, "bucket label characters allowed")
	check(KeySpec.check("tycoon", "unknownKey") == nil, "undocumented key refused")
	check(KeySpec.check("event", "shop:HarvestRush") == "shop:HarvestRush", "event shop key (B11)")
	check(KeySpec.check("core", "dau") == nil, "core is not a recorder family")
	-- Owner R128: the retired Order Window family keeps its definitions (old days render) but is no
	-- recorder family any more: every write is refused.
	check(table.find(AnalyticsConfig.RecorderFamilies, "orders") == nil, "R128: orders is no recorder family")
	check(table.find(AnalyticsConfig.Families, "orders") ~= nil, "R128: orders still stored / rendered")
	check(AnalyticsConfig.Metrics.orders ~= nil, "R128: orders definitions kept for old days")
	check(KeySpec.check("orders", "served:main") == nil, "R128: an orders key is refused")
	check(AnalyticsConfig.KeyHooks.orders == nil, "R128: no orders unique hook")
	check(table.find(AnalyticsConfig.Unique.Surfaces, "orders") ~= nil, "R128: the append-only surface bit stays")
	check(KeySpec.check("pets", "hatch:Bad Egg") == nil, "free text refused")
	check(KeySpec.check("pets", 5 :: any) == nil, "non-string refused")
	for index = 1, AnalyticsConfig.KeySpec.FallbackKindCap do
		check(
			KeySpec.check("crates", `open:Crate{index}`) == `open:Crate{index}`,
			"fallback ids accepted up to the cap"
		)
	end
	check(KeySpec.check("crates", "open:OneTooMany") == "open:other", "past the cap → other")
	check(
		KeySpec.register("crateId", function(id: string): boolean
			return id == "SupplyCrate"
		end),
		"register"
	)
	check(KeySpec.check("crates", "open:SupplyCrate") == "open:SupplyCrate", "registered id exact")
	check(KeySpec.check("crates", "open:Crate1") == nil, "registered kind refuses unknown ids")
	check(not KeySpec.register("padId", function()
		return true
	end), "built-in kinds cannot be replaced")
	KeySpec.resetForTests()
end

local restoreBuffers = Recorder.swapForTests()

-- 2. A brand-new player's first session ----------------------------------------------------------------
local player = env.player(101)
Sessions.startSession(player)
check(Sessions.onFunnelStep(player, "loadingDone"), "client step accepted before the profile")
check(not Sessions.onFunnelStep(player, "loadingDone"), "client step once per session")
check(Sessions.onClientDevice(player, "phone", "touch"), "device claim")
check(not Sessions.onClientDevice(player, "toaster", "touch"), "device allowlist")
local profile = newProfile()
profiles[player] = profile
Sessions.onProfileLoaded(player, profile, true)
check(value("core", "new") == 1 and value("core", "dau") == 1, "new + dau")
check(value("core", "cohort:all") == 1 and value("core", "ftue:joined") == 1, "cohort + joined")
check(value("core", "ftue:loadingDone") == 1, "buffered client step applied at load")
check(value("core", "ftueS1:joined") == 1 and value("core", "sessNo:1") == 1, "first session")
check(profile.analytics.first == DAY and profile.analytics.sessions == 1, "profile markers")

Recorders.plotAssigned(player, 3)
check(value("tycoon", "plot:3") == 1 and value("core", "ftue:plotReady") == 1, "plot assigned")

env.advance(30)
for index, pad in TycoonConfig.AreaPads[1] do
	env.advance(20)
	Recorders.padBought(player, pad.id)
	if index == 1 then
		check(value("core", "ftue:firstPad") == 1, "first pad funnel step")
		Recorders.producerClick(player, "p1_workbench")
		Recorders.producerClick(player, "p1_workbench")
		Recorders.producerIncome(player, "p1_workbench", 10, false)
		Recorders.producerUpgraded(player, "p1_workbench", 1, 26, "max")
	end
end
check(value("tycoon", "pad:a1_workbench") == 1 and value("tycoon", "padN:a1_workbench") == 1, "pad counted")
check(value("tycoon", "padAt:a1_workbench") >= 50, "time-to-pad (run seconds)")
check(value("tycoon", "padKind:Manager") == 1 and value("tycoon", "manager:p1_workbench") == 1, "manager pad")
check(value("tycoon", "clicks") == 2 and value("tycoon", "click:p1_workbench") == 2, "clicks")
check(value("tycoon", "income:click") == 10 and value("tycoon", "incomeP:p1_workbench:click") == 10, "income share")
check(
	value("tycoon", "lvl:p1_workbench:10") == 1 and value("tycoon", "lvl:p1_workbench:25") == 1,
	"level marks crossed"
)
check(value("tycoon", "lvl:p1_workbench:50") == 0 and value("tycoon", "upgradeMode:max") == 1, "no mark past the level")
check(value("tycoon", "area:2") == 1 and value("tycoon", "areaN:2") == 1, "Unlock pad opened area 2")
check(value("tycoon", "areaAt:2") > 0, "time-to-area")
for _, step in { "firstClick", "firstCash", "firstUpgrade", "pad5", "manager", "area2" } do
	check(value("core", `ftue:{step}`) == 1, `funnel step {step}`)
end
for _, milestone in { "click", "pad5", "upgrade", "manager", "area2" } do
	check(value("core", `cohort:{milestone}`) == 1, `first-day milestone {milestone}`)
end
check(value("core", "uniq:click") == 1, "unique clicker today")
check(value("core", "ftueMin:firstPad") > 0, "minutes to step recorded")
Recorders.areaReached(player, 2)
check(value("tycoon", "area:2") == 1, "areaReached deduped within the run")
Recorders.padBought(player, "not_a_pad")
check(value("core", "ops:badKey:tycoon") == 1, "unknown pad refused")
local onboarding = {}
local progression, padEvents = 0, 0
for _, call in env.forwarded do
	if call.kind == "onboarding" then
		table.insert(onboarding, call.args[2])
	elseif call.kind == "progression" then
		progression += 1
	elseif call.kind == "custom" and call.args[2] == "PadBought" then
		padEvents += 1
	end
end
for index = 2, #onboarding do
	check(onboarding[index] > onboarding[index - 1], "onboarding steps forwarded in order")
end
check(#onboarding >= 8 and progression == 1 and padEvents == #TycoonConfig.AreaPads[1], "Roblox forwarding")

-- Economy.
Recorders.currencyChanged(player, "cash", 100, "Producer", 100)
Recorders.currencyChanged(player, "cash", -40, "PadBuy", 60)
Recorders.currencyChanged(player, "gems", 5, "Daily:streak", 5)
Recorders.currencyChanged(player, "cash", 0 / 0, "Producer", 0)
Recorders.currencyChanged(player, "bogus", 5, "Producer", 0)
check(value("economy", "earn:cash") == 100 and value("economy", "earn:cash:Producer") == 100, "cash source")
check(value("economy", "n:earn:cash:Producer") == 1, "event count")
check(value("economy", "spend:cash:PadBuy") == 40, "cash sink")
check(value("economy", "earn:gems:Daily") == 5, "reason id = leading letters")
check(Runtime.sessions[player].incomeBatch == 100, "unmapped cash income batched for Roblox")
local sinkForwarded = false
for _, call in env.forwarded do
	if call.kind == "economy" and call.args[6] == "Shop" then
		sinkForwarded = true
	end
end
check(sinkForwarded, "pad spend forwarded as a Shop sink")

-- 3. Generic recorders.
Recorders.pets(player, "hatch:BasicEgg")
Recorders.retention(player, "daily:claim:3")
Recorders.retention(player, "daily:claim:9")
Recorders.attack(player, "launch:normal", 0 / 0)
Recorders.record("core", player, "dau")
check(value("pets", "hatch:BasicEgg") == 1 and value("core", "uniq:hatch") == 1, "hatch + unique hook")
check(value("core", "cohort:hatch") == 1 and value("core", "cohort:daily") == 1, "first-day hooks")
check(value("retention", "daily:claim:3") == 1, "daily claim")
check(value("core", "ops:badKey:retention") == 1 and value("core", "ops:badKey:attack") == 1, "refusals counted")
check(value("core", "ops:badKey:family") == 1, "non-recorder family refused")
Recorders.eggHatched(player, "BasicEgg", {
	{ petId = "GlowSlime", rarity = "Common" },
	{ petId = "AtomPup", rarity = "Rare" },
	{ petId = "AtomPup", rarity = "Bogus" },
}, true)
check(value("pets", "hatch:BasicEgg") == 4 and value("pets", "hatchN:BasicEgg:3") == 1, "triple hatch")
check(
	value("pets", "rarity:Rare") == 1 and value("pets", "rarity:Bogus") == 0 and value("pets", "hatchAuto") == 1,
	"rarities"
)
Recorders.crateOpened(player, "SupplyCrate", "gems", { { kind = "boost", rarity = "Epic" } })
check(value("crates", "open:SupplyCrate") == 1 and value("crates", "reward:SupplyCrate:boost") == 1, "crate")
-- Paid-random policy refusals (2026-10-30): pets "refused:policy", crates "refused:<reason>",
-- the wheel / pack / lure keys — documented, so they count and are never ops:badKey.
local badBefore = value("core", "ops:badKey:pets") + value("core", "ops:badKey:crates")
Recorders.pets(player, "refused:policy")
Recorders.crates(player, "refused:policy")
Recorders.crates(player, "refused:gems")
Recorders.crates(player, "refused:busy")
check(value("pets", "refused:policy") == 1, "pets policy refusal counted")
check(value("crates", "refused:policy") == 1 and value("crates", "refused:gems") == 1, "crate refusals counted")
check(value("crates", "refused:busy") == 1, "crate busy refusal counted")
Recorders.crates(player, "refused:cheat")
check(value("crates", "refused:cheat") == 0, "undocumented crate reason refused")
check(
	value("core", "ops:badKey:pets") + value("core", "ops:badKey:crates") == badBefore + 1,
	"only the bad key refused"
)
for _, key in
	{ "wheel:spin:bonus", "wheel:refused:policy", "wheel:refused:empty", "wheel:receipt:gems", "pack:spins:gems" }
do
	check(KeySpec.check("retention", key) == key, `retention {key} documented`)
end
check(KeySpec.check("retention", "wheel:refused:cheat") == nil, "wheel refusal reasons are a closed set")
for _, key in { "lure:refused:policy", "lure:fixed", "starter:new", "starter:topup", "starter:reset" } do
	check(KeySpec.check("event", key) == key, `event {key} documented`)
end
check(KeySpec.check("event", "starter:cheat") == nil, "starter reasons are a closed set")

-- 4. Revenue.
env.advance(5)
Revenue.promptShown(player, "GemsSmall", "Gems", "shop")
env.advance(4)
Revenue.promptFinished(player, "GemsSmall", "Gems", false)
check(value("revenue", "prompt:GemsSmall:shop") == 1 and value("revenue", "funnel:GemsSmall:prompt") == 1, "prompt")
check(
	value("revenue", "promptClosed:GemsSmall:shop") == 1 and value("revenue", "promptDwell:shop:phone:2to10") == 1,
	"closed + dwell"
)
Revenue.promptShown(player, "GemsSmall", "Gems", "offer")
local hooks = Revenue.accountingHooks()
Revenue.setAccountingInstalled(true)
local product = MonetizationConfig.getProduct("GemsSmall")
local receipt = { PurchaseId = "PURCHASE-1", PlayerId = 101, ProductId = 555, CurrencySpent = 49 }
hooks.onGrant(player, profile, product, receipt)
check(
	profile.analytics.outbox["PURCHASE-1"] ~= nil and profile.analytics.outbox["PURCHASE-1"].ready == true,
	"outbox record parked"
)
check(profile.analytics.payFirst == DAY, "payer marked in the grant commit")
hooks.onGrant(player, profile, product, receipt)
hooks.onDurable(player, profile, product, receipt)
check(profile.analytics.outbox["PURCHASE-1"] == nil, "outbox cleared after accounting")
check(
	value("revenue", "robux") == 49 and value("revenue", "purchase:GemsSmall:offer") == 1,
	"sale credited to its prompt"
)
check(
	value("core", "payers") == 1 and value("core", "newPayers") == 1 and value("revenue", "firstBuy:GemsSmall") == 1,
	"payer"
)
check(value("core", "cohort:pay") == 1 and value("revenue", "robuxByArea:1") == 49, "pay milestone + area")
Revenue.productGranted(player, "GemsSmall", 49, receipt)
check(value("revenue", "robux") == 49, "ProductGranted does not double-count once accounting is installed")
Revenue.passPurchased(player, "VIP", 199)
check(value("revenue", "pass:VIP:count") == 1 and value("revenue", "robux") == 248, "pass purchase")
check(value("core", "payers") == 1, "same payer-day not counted twice")
check(Revenue.onOffersSeen(player, "starburst", { "VIP", "StarterPack", "Bogus" }, true) == 3, "offers seen")
check(value("revenue", "offers:card:VIP") == 1 and value("revenue", "funnel:VIP:shown") == 1, "offer impression")
check(value("core", "uniq:offers") == 1, "offers unique")
Revenue.offerClicked(player, "VIP")
Revenue.offerClicked(player, "NotAnOffer")
check(value("revenue", "offer:VIP:click") == 1 and value("revenue", "offer:NotAnOffer:click") == 0, "offer clicks")

-- 4b. Owner R137: BUY presses on offer surfaces (MonetizationService.PromptRequested → the
--     funnel's click step), observed server-side BEFORE any prompt refusal.
do
	local function clicks(id: string): number
		return value("revenue", `funnel:{id}:click`)
	end
	local function refused(reason: string): number
		return value("core", `ops:clientRefused:OfferClick:{reason}`)
	end
	env.advance(30) -- a full click bucket
	Revenue.promptRequested(player, "StarterPack", "StarterPack", "shop")
	check(
		clicks("StarterPack") == 1 and value("revenue", "offer:StarterPack:click") == 1,
		"R137 offer BUY press counts funnel + offer click"
	)
	check(value("revenue", "prompt:StarterPack") == 0, "a press is not a prompt (the prompt step stays its own)")
	env.advance(0.3)
	Revenue.promptRequested(player, "StarterPack", "StarterPack", "shop")
	check(clicks("StarterPack") == 1, "a double tap on the same offer within RepeatSeconds is one press")
	env.advance(AnalyticsConfig.OfferClicks.RepeatSeconds + 1)
	Revenue.promptRequested(player, "StarterPack", "StarterPack", "offer")
	Revenue.promptRequested(player, "VIP", "pass", "welcomeBack")
	check(clicks("StarterPack") == 2 and clicks("VIP") == 2, "every offer source counts (shop / offer / welcomeBack)")
	for _, source in { "pad", "wheel", "attack", "lucky", "pets", "other", "none" } do
		Revenue.promptRequested(player, "VIP", "pass", source)
	end
	Revenue.promptRequested(player, "VIP", "pass", nil)
	check(clicks("VIP") == 2, "non-offer prompt sources are never an offer click")
	check(value("core", "ops:clientRefused:OfferClick") == 0, "a non-offer source is not a refusal")
	env.advance(30)
	Revenue.promptRequested(player, "Bogus", "Bogus", "shop")
	Revenue.promptRequested(player, ({} :: any) :: string, "x", "shop")
	Revenue.promptRequested(player, (5 :: any) :: string, "x", "offer")
	Revenue.promptRequested(player, string.rep("V", 40), "x", "offer")
	check(refused("unknown") == 1 and refused("malformed") == 3, "unknown ids / wrong types / oversized refused")
	check(value("revenue", "funnel:Bogus:click") == 0, "an unknown id never becomes a key")
	-- Token bucket: Burst presses pass, the next one in the same instant is refused as "rate".
	env.advance(30)
	local burstKeys = { "CashSmall", "CashMedium", "CashLarge", "GemsSmall", "GemsMedium" }
	for _, id in burstKeys do
		check(MonetizationConfig.getProduct(id) ~= nil, `test product {id} exists`)
	end
	for index = 1, AnalyticsConfig.OfferClicks.Burst + 1 do
		Revenue.promptRequested(player, burstKeys[index], "Cash", "shop")
	end
	check(refused("rate") == 1, "presses past the token bucket are refused (rate)")
	check(clicks(burstKeys[AnalyticsConfig.OfferClicks.Burst + 1]) == 0, "the rate-limited press is not counted")
	-- Per-session cap: once MaxPerSession presses counted, more are refused (cap).
	local info = Runtime.sessions[player]
	info.offersSeen.clicks = AnalyticsConfig.OfferClicks.MaxPerSession
	env.advance(30)
	Revenue.promptRequested(player, "VIP", "pass", "shop")
	check(clicks("VIP") == 2 and refused("cap") == 1, "per-session click cap")
	check(
		value("core", "ops:clientRefused:OfferClick") == refused("unknown") + refused("malformed") + refused("rate") + refused("cap"),
		"every refusal counts the base key once"
	)
	info.offersSeen.clicks = 0
	-- (Staff / New Player Mode diversion: section 9.)
	-- No analytics session (left / not started): nothing counts, nothing throws.
	Revenue.promptRequested(env.player(606), "VIP", "pass", "shop")
	check(clicks("VIP") == 2, "no session, no click")
end

-- 5. Client reports.
check(Sessions.onFunnelStep(player, "open", "Shop", "hud"), "screen open")
check(value("retention", "open:Shop") == 1 and value("retention", "openFrom:Shop:hud") == 1, "screen keys")
check(value("core", "uniq:shop") == 1, "shop unique")
check(not Sessions.onFunnelStep(player, "open", "<script>", "hud"), "bad screen refused")
check(not Sessions.onFunnelStep(player, { "x" }), "bad step refused")
check(
	Sessions.onFunnelStep(player, "tutorial", 3) and not Sessions.onFunnelStep(player, "tutorial", 3),
	"tutorial arrow once"
)
check(not Sessions.onFunnelStep(player, "tutorial", 99), "tutorial range")
check(value("core", "ops:clientRefused:FunnelStep") >= 2, "client refusals counted")

-- 6. Rebirth / offline / tutorial.
env.advance(600)
local playBefore = Runtime.playSeconds(player)
Recorders.rebirthed(player, 1, 5)
check(
	value("tycoon", "rebirth") == 1 and value("tycoon", "rebirthN:1") == 1 and value("tycoon", "rebirthTokens") == 5,
	"rebirth"
)
check(value("tycoon", "rebirthSec") > 600 and value("core", "ftue:firstRebirth") == 1, "run length + funnel")
check(math.abs(profile.analytics.runAt - playBefore) <= 1, "new run clock")
profile.rebirths = 1
Recorders.padBought(player, "a1_workbench")
check(
	value("tycoon", "pad:a1_workbench") == 2 and value("tycoon", "padN:a1_workbench") == 1,
	"rebirth runs are not first-run pacing"
)
Recorders.offlinePaid(player, 7200, 1e6)
check(
	value("tycoon", "offline:pay") == 1
		and value("tycoon", "offlineB:1-3h") == 1
		and value("tycoon", "income:offline") == 1e6,
	"offline"
)
Recorders.tutorialStep(player, 1)
Recorders.tutorialStep(player, 1, true)
check(value("tycoon", "tut:1") == 1 and value("tycoon", "tutDone") == 1, "tutorial once per session")

-- 7. Session end.
Recorders.areaReached(player, 2)
profile.tycoon.area = 2
Sessions.onProfileReleasing(player, profile)
local playedAtRelease = profile.analytics.play
check(playedAtRelease > 600, "play clock folded at release")
Sessions.endSession(player)
check(Runtime.sessions[player] == nil, "session removed")
check(
	value("core", "sessions") == 1 and value("core", "device:phone") == 1 and value("core", "input:touch") == 1,
	"session counters"
)
check(value("core", "devNew:phone") == 1, "new player device attributed at leave")
check(
	value("core", "ftueLeft:firstRebirth") == 1 and value("core", "ftueDev:phone:firstRebirth") == 1,
	"first session furthest step"
)
check(
	value("tycoon", "leaveArea:2") == 1 and value("pets", "owned:1-2") == 1 and value("pets", "equipped:1") == 1,
	"leave snapshot"
)
local hourKey = `hour:{os.date("!%H", DAY * 86400 + 10 * 3600)}`
check(value("core", hourKey) == 1, "start hour")

-- 8. Retention: D1 return, carry-over, rejoin.
env.setTime((DAY + 1) * 86400 + 9 * 3600)
local back = env.player(101)
profiles[player] = nil
profiles[back] = profile
Sessions.startSession(back)
Sessions.onProfileLoaded(back, profile, false)
check(value("core", "r1") == 1 and value("core", "returning") == 1 and value("core", "dau") == 1, "D1 return")
check(
	value("core", "r1:all") == 1 and value("core", "r1:area2") == 1 and value("core", "r1:pay") == 1,
	"D1 by first-day milestone"
)
check(value("core", "sessNo:2") == 1 and value("core", "new") == 0, "second session")
Sessions.endSession(back)
check(
	value("core", "devR1:phone") == 0 and value("core", "devR1:unknown") == 1,
	"D1 join attributed to the session's device"
)

-- A different new player online across midnight.
env.setTime((DAY + 1) * 86400 + 23 * 3600 + 3000)
local owl = env.player(202)
local owlProfile = newProfile()
profiles[owl] = owlProfile
Sessions.startSession(owl)
Sessions.onProfileLoaded(owl, owlProfile, true)
env.setTime((DAY + 2) * 86400 + 600)
Sessions.flushActivity()
check(value("core", "r1:carry") == 1 and owlProfile.analytics.carry == DAY + 2, "midnight carry-over tagged + marked")
check(value("core", "r1:all") == 0, "carry-overs do not count D1 by milestone")
Sessions.endSession(owl)
env.setTime((DAY + 2) * 86400 + 5 * 3600)
local owlAgain = env.player(202)
profiles[owl] = nil
profiles[owlAgain] = owlProfile
Sessions.startSession(owlAgain)
Sessions.onProfileLoaded(owlAgain, owlProfile, false)
check(value("core", "r1:carryRejoin") == 1 and owlProfile.analytics.carry == 0, "genuine rejoin after a carry-over")
Sessions.endSession(owlAgain)

-- 9. New Player Mode + staff.
local admin = env.player(303)
admin:SetAttribute(AnalyticsConfig.NewPlayerModeAttribute, true)
local adminProfile = newProfile()
profiles[admin] = adminProfile
Sessions.startSession(admin)
local newBefore = value("core", "new")
Sessions.onProfileLoaded(admin, adminProfile, true)
Recorders.padBought(admin, "a1_workbench")
check(value("core", "new") == newBefore and value("core", "npm:padBought") == 1, "New Player Mode diverted")
check(not Sessions.onFunnelStep(admin, "hudShown"), "sandbox funnel diverted")
do
	-- R137: a sandbox BUY press on an offer surface is diverted by economyGuard, never a click.
	local vipClicks = value("revenue", "funnel:VIP:click")
	Revenue.promptRequested(admin, "VIP", "pass", "shop")
	check(
		value("revenue", "funnel:VIP:click") == vipClicks and value("core", "npm:promptRequested") == 1,
		"New Player Mode offer press diverted"
	)
end
Sessions.endSession(admin)
local staff = env.player(404)
local staffProfile = newProfile()
staffProfile.analytics.staff = true
profiles[staff] = staffProfile
Sessions.startSession(staff)
Sessions.onProfileLoaded(staff, staffProfile, false)
Recorders.currencyChanged(staff, "gems", 1000, "Admin", 1000)
check(
	value("core", "staff:currencyChanged") == 1 and value("economy", "earn:gems:Admin") == 0,
	"stamped staff diverted"
)
Revenue.promptRequested(staff, "VIP", "pass", "offer")
check(value("core", "staff:promptRequested") == 1, "R137: a staff offer press is diverted, never a click")
Sessions.endSession(staff)

-- 11. Worlds (owner R57 World 2: the worlds family, world-scoped kinds, routed tycoon ids, the
--     world funnel, time per world, world currencies).
do
	local WorldsConfig = env.load("src/shared/Config/Worlds/WorldsConfig")
	local WorldRecorders = env.load("src/server/Analytics/WorldRecorders")
	local worldsConfig = AnalyticsConfig.Worlds
	check(
		table.find(AnalyticsConfig.Families, "worlds") ~= nil
			and table.find(AnalyticsConfig.RecorderFamilies, "worlds") ~= nil
			and #AnalyticsConfig.Families == 14,
		"worlds family registered (14 families: + R90 kinetic + R90 orders, retired by R128 but stored)"
	)
	for _, def in WorldsConfig.extra() do
		check(table.find(AnalyticsConfig.Unique.Surfaces, `w_{def.id}`) ~= nil, `visit surface w_{def.id}`)
		check(worldsConfig.Funnels[def.id] ~= nil, `funnel of {def.id}`)
		check(#worldsConfig.Funnels[def.id].steps <= 30, `funnel of {def.id} fits a 30-bit mask`)
		for _, currency in { def.currency, def.tokens } do
			check(
				table.find(AnalyticsConfig.Economy.Currencies, currency.key) ~= nil
					and AnalyticsConfig.Economy.CurrencyNames[currency.key] == currency.name,
				`currency {currency.key} booked as {currency.name}`
			)
		end
	end
	local dinoFunnel = worldsConfig.Funnels.dino
	check(dinoFunnel.name == "DinoValley" and dinoFunnel.path == "Dino Valley", "Creator Dashboard names")
	check(
		dinoFunnel.steps[1] == "unlocked"
			and dinoFunnel.steps[5] == "area2"
			and dinoFunnel.steps[#dinoFunnel.steps] == "rebirth",
		"funnel order"
	)

	-- KeySpec: world ids, world-scoped kinds, any world's pad / producer ids.
	-- { family, key, expected canonical key or false = refused }
	local cases: { { any } } = {
		{ "worlds", "unlock:dino", "unlock:dino" },
		{ "worlds", "unlock:mars", false },
		{ "worlds", "unlockSrc:dino:legacy", "unlockSrc:dino:legacy" },
		{ "worlds", "unlockSrc:dino:cheat", false },
		{ "worlds", "area:dino:6", "area:dino:6" },
		{ "worlds", "area:dino:7", false },
		{ "worlds", "area:dino:06", false },
		{ "worlds", "area:main:10", "area:main:10" },
		{ "worlds", "areaB:dino:2:<5m", "areaB:dino:2:<5m" },
		{ "worlds", "rebirthShop:dino:startingCash", "rebirthShop:dino:startingCash" },
		{ "worlds", "rebirthShop:dino:nope", false },
		{ "worlds", "travel:dino:portal", "travel:dino:portal" },
		{ "worlds", "travel:dino:teleport", false },
		{ "worlds", "travelFail:dino:revealPending", "travelFail:dino:revealPending" },
		{ "worlds", "travelFail:unknown:unknownWorld", "travelFail:unknown:unknownWorld" },
		{ "worlds", "travelFail:dino:hacked", false },
		{ "worlds", "step:dino:area6", "step:dino:area6" },
		{ "worlds", "step:dino:area7", false },
		{ "worlds", "step:main:unlocked", false },
		{ "worlds", "popup:dino:lockedPreview", "popup:dino:lockedPreview" },
		{ "worlds", "popup:dino:dance", false },
		{ "worlds", "seconds:dino", "seconds:dino" },
		{ "worlds", "incomeW:dino:offline", "incomeW:dino:offline" },
		{ "tycoon", "pad:d1_stone_bench", "pad:d1_stone_bench" },
		{ "tycoon", "pad:d9_nope", false },
		{ "tycoon", "incomeP:dp1_pebble_bench:auto", "incomeP:dp1_pebble_bench:auto" },
		{ "tycoon", "lvl:dp6_volcano_core:1000", "lvl:dp6_volcano_core:1000" },
	}
	for _, case in cases do
		local expected = if case[3] == false then nil else case[3]
		check(KeySpec.check(case[1], case[2]) == expected, `KeySpec {case[1]} {case[2]}`)
	end
	check(not KeySpec.register("worldArea", function()
		return true
	end), "world-scoped kinds cannot be replaced")

	-- A Dino Valley player end to end.
	local dino = WorldsConfig.get("dino")
	local traveller = env.player(505)
	local tProfile = newProfile()
	tProfile.worlds = {
		dino = {
			unlocked = false,
			cash = 0,
			rebirths = 0,
			rebirthTokens = 0,
			tycoon = { pads = {}, area = 1 },
			stats = { runSeconds = 0, visits = 0 },
		},
	}
	profiles[traveller] = tProfile
	Sessions.startSession(traveller)
	Sessions.onProfileLoaded(traveller, tProfile, false)
	local badWorlds = value("core", "ops:badKey:worlds")
	local badTycoon = value("core", "ops:badKey:tycoon")
	local mainFirstPad = value("core", "ftue:firstPad")
	local mainPadArea1 = value("tycoon", "padArea:1")
	local mainClicks = value("tycoon", "clicks")
	local mainIncomeAuto = value("tycoon", "income:auto")

	WorldRecorders.unlocked(traveller, "dino", "area")
	WorldRecorders.unlocked(traveller, "main", "area")
	check(
		value("worlds", "unlock:dino") == 1
			and value("worlds", "unlockSrc:dino:area") == 1
			and value("worlds", "step:dino:unlocked") == 1,
		"unlock + source + funnel step"
	)
	check(value("core", "ops:badKey:worlds") == badWorlds + 1, "main cannot be unlocked")

	-- Popup claims: allowlisted, capped per session (the funnel limiter refills between claims).
	env.advance(3)
	check(Sessions.onFunnelStep(traveller, "worldPopup", "dino", "shown"), "popup shown claim")
	env.advance(3)
	check(not Sessions.onFunnelStep(traveller, "worldPopup", "main", "go"), "popup of main refused")
	env.advance(3)
	check(not Sessions.onFunnelStep(traveller, "worldPopup", "dino", "dance"), "unknown popup action refused")
	for _ = 1, worldsConfig.PopupSessionCap + 2 do
		env.advance(3)
		Sessions.onFunnelStep(traveller, "worldPopup", "dino", "later")
	end
	check(
		value("worlds", "popup:dino:shown") == 1 and value("worlds", "popup:dino:later") == worldsConfig.PopupSessionCap,
		"popup counts capped per session"
	)

	-- Travel: visitor once per day, first visit, funnel, time per world.
	env.advance(4)
	traveller:SetAttribute("CurrentWorld", "dino")
	WorldRecorders.travelled(traveller, "dino", "popup", true)
	WorldRecorders.travelled(traveller, "dino", "menu", false)
	WorldRecorders.travelled(traveller, "dino", "teleport", false)
	check(value("worlds", "travel:dino:popup") == 1 and value("worlds", "travel:dino:menu") == 1, "travel by source")
	check(value("core", "ops:badKey:worlds") == badWorlds + 2, "unknown travel source refused")
	check(value("worlds", "visitor:dino") == 1 and value("core", "uniq:w_dino") == 1, "visitor once per player per day")
	check(
		value("worlds", "firstVisit:dino") == 1 and value("worlds", "step:dino:firstTravel") == 1,
		"first visit + funnel step"
	)
	check(value("worlds", "seconds:main") >= 4, "time in Nuke Town folded at the trip")
	env.advance(30)
	Sessions.flushActivity()
	check(value("worlds", "seconds:dino") >= 30, "time in Dino Valley folded at flush")

	-- Pads of area 1 (routed by Recorders.padBought): world-scoped first run + funnel steps.
	tProfile.worlds.dino.stats.runSeconds = 120
	for _, pad in dino.economy.AreaPads[1] do
		tProfile.worlds.dino.tycoon.pads[pad.id] = true
		Recorders.padBought(traveller, pad.id)
	end
	check(
		value("tycoon", "pad:d1_stone_bench") == 1
			and value("tycoon", "padN:d1_stone_bench") == 1
			and value("tycoon", "padAt:d1_stone_bench") == 120,
		"Dino pad + first run time-to-pad (world run seconds)"
	)
	check(value("worlds", "padArea:dino:1") == #dino.economy.AreaPads[1], "pads per Dino area")
	check(
		value("worlds", "step:dino:firstPad") == 1
			and value("worlds", "step:dino:manager") == 1
			and value("tycoon", "manager:dp1_pebble_bench") == 1,
		"first pad + manager steps"
	)
	check(
		value("worlds", "area:dino:2") == 1
			and value("worlds", "areaN:dino:2") == 1
			and value("worlds", "areaAt:dino:2") == 120
			and value("worlds", "step:dino:area2") == 1,
		"Unlock pad opened Dino area 2 (pacing)"
	)
	check(
		value("core", "ftue:firstPad") == mainFirstPad and value("tycoon", "padArea:1") == mainPadArea1,
		"Dino pads never touch the Nuke Town funnel / pad areas"
	)
	Recorders.producerClick(traveller, "dp1_pebble_bench")
	Recorders.producerIncome(traveller, "dp1_pebble_bench", 50, true)
	Recorders.producerUpgraded(traveller, "dp1_pebble_bench", 1, 12, "10")
	check(
		value("tycoon", "click:dp1_pebble_bench") == 1 and value("tycoon", "clicks") == mainClicks,
		"Dino click per producer"
	)
	check(
		value("tycoon", "incomeP:dp1_pebble_bench:auto") == 50
			and value("worlds", "incomeW:dino:auto") == 50
			and value("tycoon", "income:auto") == mainIncomeAuto,
		"Dino income share"
	)
	check(
		value("tycoon", "upgrade:dp1_pebble_bench") == 1 and value("tycoon", "lvl:dp1_pebble_bench:10") == 1,
		"Dino upgrade + level mark"
	)
	check(value("core", "ops:badKey:tycoon") == badTycoon, "no Dino id refused")
	WorldRecorders.areaReached(traveller, "dino", 2)
	WorldRecorders.areaReached(traveller, "dino", 7)
	check(value("worlds", "area:dino:2") == 1, "world area deduped within the run")
	check(value("core", "ops:badKey:worlds") == badWorlds + 3, "area outside the world refused")
	tProfile.worlds.dino.tycoon.pads[dino.economy.FinalePadId] = true
	Recorders.padBought(traveller, dino.economy.FinalePadId)
	check(value("worlds", "step:dino:finale") == 1, "finale step")

	-- Rebirth, Amber shop, offline, refusals, locked portal.
	tProfile.worlds.dino.rebirths = 1
	WorldRecorders.rebirthed(traveller, "dino", 1, 14)
	check(
		value("worlds", "rebirth:dino") == 1
			and value("worlds", "rebirthN:dino:1") == 1
			and value("worlds", "tokens:dino") == 14
			and value("worlds", "step:dino:rebirth") == 1,
		"Dino rebirth"
	)
	WorldRecorders.areaReached(traveller, "dino", 2)
	check(
		value("worlds", "area:dino:2") == 2 and value("worlds", "areaN:dino:2") == 1,
		"new run reaches again; not a first run"
	)
	WorldRecorders.rebirthShop(traveller, "dino", "startingCash")
	WorldRecorders.rebirthShop(traveller, "dino", "nope")
	check(value("worlds", "rebirthShop:dino:startingCash") == 1, "Amber shop upgrade")
	WorldRecorders.offlinePaid(traveller, "dino", 7200, 500)
	WorldRecorders.offlineDoubled(traveller, "dino")
	check(
		value("worlds", "offline:dino:pay") == 1
			and value("worlds", "offlineSec:dino") == 7200
			and value("worlds", "incomeW:dino:offline") == 500
			and value("worlds", "offline:dino:double") == 1,
		"Dino offline payout"
	)
	WorldRecorders.travelFailed(traveller, "mars", "locked")
	WorldRecorders.travelFailed(traveller, "dino", "hacked")
	check(
		value("worlds", "travelFail:unknown:locked") == 1 and value("worlds", "travelFail:dino:other") == 1,
		"travel refusals fold unknown worlds / reasons"
	)
	WorldRecorders.portalLocked(traveller, "dino")
	WorldRecorders.portalLocked(traveller, "dino")
	env.advance(worldsConfig.PortalLockedCooldown + 1)
	WorldRecorders.portalLocked(traveller, "dino")
	check(value("worlds", "portalLocked:dino") == 2, "locked portal throttled")

	-- World currencies: booked, named for Roblox, producer income batched once per flush.
	Recorders.currencyChanged(traveller, "bones", 500, "producer", 500)
	Recorders.currencyChanged(traveller, "bones", -100, "pad", 400)
	Recorders.currencyChanged(traveller, "amber", 14, "rebirth", 14)
	check(
		value("economy", "earn:bones") == 500
			and value("economy", "spend:bones:pad") == 100
			and value("economy", "earn:amber") == 14,
		"bones / amber booked"
	)
	local before = #env.forwarded
	Sessions.flushActivity()
	local bonesBatch, bonesSink, funnelSteps, dinoProgression = false, false, {}, false
	for index, call in env.forwarded do
		-- LogEconomyEvent(player, flowType, currency, amount, balance, transactionType, sku)
		if call.kind == "economy" and call.args[3] == "Bones" then
			if index > before and call.args[7] == AnalyticsConfig.Economy.BatchedIncomeSku then
				bonesBatch = call.args[4] == 500 and call.args[6] == "Gameplay"
			elseif call.args[6] == "Shop" and call.args[4] == 100 then
				bonesSink = true
			end
		elseif call.kind == "funnel" and call.args[2] == "DinoValley" then
			check(call.args[3] == nil, "world funnel is a one-time funnel")
			funnelSteps[call.args[5]] = call.args[4]
		elseif call.kind == "progression" and call.args[2] == "Dino Valley" then
			dinoProgression = true
		end
	end
	check(bonesBatch and bonesSink, "Bones forwarded to Roblox (batched income + sink)")
	check(
		funnelSteps.unlocked == 1 and funnelSteps.firstTravel == 2 and funnelSteps.rebirth == #dinoFunnel.steps,
		"DinoValley funnel steps forwarded with their numbers"
	)
	check(dinoProgression, "Dino Valley progression path")

	-- Back to Nuke Town; a trip that skipped the hook is picked up from CurrentWorld.
	traveller:SetAttribute("CurrentWorld", "main")
	WorldRecorders.travelled(traveller, "main", "portal", false)
	check(
		value("worlds", "travel:main:portal") == 1 and value("worlds", "visitor:main") == 0,
		"return trip (no main visitor row)"
	)
	local dinoSeconds = value("worlds", "seconds:dino")
	traveller:SetAttribute("CurrentWorld", "dino")
	env.advance(2)
	WorldRecorders.fold(traveller)
	env.advance(10)
	Sessions.endSession(traveller)
	check(value("worlds", "seconds:dino") >= dinoSeconds + 10, "attribute fallback clocks the world")
end

-- 9b. R129: the leave snapshot is the state AT LEAVE whatever order the two PlayerRemoving
-- listeners (Analytics, PlayerDataService) run in, and on the shutdown path where the profile can
-- no longer be found by player when ProfileReleasing fires.
do
	-- (a) Analytics' PlayerRemoving first: the profile is still live, ProfileReleasing comes later.
	local early = env.player(606)
	local earlyProfile = newProfile()
	earlyProfile.pets = { owned = {}, equipped = {} }
	profiles[early] = earlyProfile
	Sessions.startSession(early)
	Sessions.onProfileLoaded(early, earlyProfile, false) -- join-time snapshot: area 1, 0 pets
	earlyProfile.tycoon.area = 3
	earlyProfile.pets = { owned = { a = {}, b = {}, c = {} }, equipped = { "a", "b" } }
	local area3, owned3, equipped2 =
		value("tycoon", "leaveArea:3"), value("pets", "owned:3-9"), value("pets", "equipped:2")
	Sessions.endSession(early)
	Sessions.onProfileReleasing(early, earlyProfile) -- too late: the session is gone (no-op)
	check(value("tycoon", "leaveArea:3") == area3 + 1, "leave area read at leave (analytics first)")
	check(
		value("pets", "owned:3-9") == owned3 + 1 and value("pets", "equipped:2") == equipped2 + 1,
		"pets read at leave (analytics first)"
	)
	profiles[early] = nil

	-- (b) Shutdown: PlayerDataService drops the session before ProfileReleasing fires, so the
	-- profile is only reachable through the event argument.
	local closing = env.player(707)
	local closingProfile = newProfile()
	profiles[closing] = closingProfile
	Sessions.startSession(closing)
	Sessions.onProfileLoaded(closing, closingProfile, false)
	closingProfile.tycoon.area = 4
	profiles[closing] = nil
	local area4 = value("tycoon", "leaveArea:4")
	Sessions.onProfileReleasing(closing, closingProfile)
	Sessions.endSession(closing)
	check(value("tycoon", "leaveArea:4") == area4 + 1, "leave area from the released profile (shutdown)")
end

-- 10. Every recorded key is documented.
do
	local all = Recorder.unsavedCopy()
	local undocumented: { string } = {}
	for _, families in all do
		for family, counters in families do
			for key in counters do
				if #AnalyticsReport.presentPatterns({ [family] = { [key] = 1 } }) == 0 then
					table.insert(undocumented, `{family}:{key}`)
				end
			end
		end
	end
	table.sort(undocumented)
	check(#undocumented == 0, `undocumented keys: {table.concat(undocumented, ", ")}`)
end

restoreBuffers()
check(saves > 0, "markers saved through markSaved")
done("analytics-recorders")
