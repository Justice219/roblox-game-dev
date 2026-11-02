--!strict
--[[
	Boundary + catalogue regressions. Run:
		lune run tests/validate

	Proves on the shipped modules:
	  1. Validate (src/shared/Net/Validate): number / integer / boolean / string / oneOf / key /
	     configKey (rawget allowlist, metatable-proof) / requestId / userId / text (UTF-8, control
	     characters, trimming, byte pre-check) / stringArray (dense, distinct, bounded, metatable-
	     proof, returns a copy) / flatTable — every helper rejects NaN, inf, wrong types and
	     oversized input.
	  2. RateLimiter: burst, refill over (injected) time, cost, Forget.
	  3. TextUtil: character and byte cuts never split a character; invalid UTF-8 → "".
	  4. MonetizationConfig.validate() is clean; every spec §11 pass and product exists with the
	     right kind; unpublished ids are unavailable and never match by id.
	  5. Remotes: every remote of the build plan is declared exactly once.
	  6. R57 World 2: Validate.worldId / worldIdOrMain / travelRequest / rebirthShopBuy (known
	     worlds only, per-world area counts and shop allowlists, junk never read as "main"); the
	     Dino products (kinds, worlds, numbers, one-time, NOT paid random); every egg bought with a
	     Robux-reachable world currency (Bones) is a gated paid random item.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local Validate = loader.load("src/shared/Net/Validate")
local RateLimiter = loader.load("src/shared/Util/RateLimiter")
local TextUtil = loader.load("src/shared/Util/TextUtil")
local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")
local Remotes = loader.load("src/shared/Net/Remotes")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
local RebirthConfig = loader.load("src/shared/Config/RebirthConfig")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local EggConfig = loader.load("src/shared/Config/EggConfig")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local nan = 0 / 0

-- 1. Validate
check(Validate.number(0.5, 0, 1) == 0.5, "number in range")
check(Validate.number(nan, 0, 1) == nil and Validate.number(math.huge, 0, math.huge) == nil, "number rejects NaN / inf")
check(Validate.number("1", 0, 1) == nil and Validate.number(2, 0, 1) == nil, "number type + range")
check(Validate.integer(3, 1, 10) == 3 and Validate.integer(3.5, 1, 10) == nil, "integer")
check(Validate.boolean(false) == false and Validate.boolean(0) == nil, "boolean")
check(Validate.string("abc", 1, 3) == "abc" and Validate.string("abcd", 1, 3) == nil, "string length")
check(Validate.oneOf("max", { "1", "10", "max" }) == "max" and Validate.oneOf("MAX", { "max" }) == nil, "oneOf")
check(Validate.key("garage_bench-2", 32) == "garage_bench-2", "key ok")
check(Validate.key("a b", 32) == nil and Validate.key("a/b", 32) == nil and Validate.key("", 32) == nil, "key charset")
check(Validate.key("abc\0", 32) == nil and Validate.key(string.rep("a", 33), 32) == nil, "key NUL / length")
local catalogue = { VIP = 1 }
local key, entry = Validate.configKey("VIP", catalogue)
check(key == "VIP" and entry == 1, "configKey hit")
check(Validate.configKey("Nope", catalogue) == nil, "configKey miss")
local tricky = setmetatable({}, {
	__index = function()
		return "fake"
	end,
})
check(Validate.configKey("Anything", tricky) == nil, "configKey ignores __index")
check(Validate.requestId(17) == 17 and Validate.requestId(0) == nil and Validate.requestId(2 ^ 31) == nil, "requestId")
check(Validate.userId(1) == 1 and Validate.userId(-1) == nil and Validate.userId(1.5) == nil, "userId")
check(Validate.text("  Nuke Shack ", 24) == "Nuke Shack", "text trimmed")
check(
	Validate.text("Ünïcödé", 7) == "Ünïcödé" and Validate.text("Ünïcödé", 6) == nil,
	"text counts characters"
)
check(Validate.text("bad\nline", 24) == nil and Validate.text("tab\there", 24) == nil, "text control chars")
check(Validate.text("c1\194\133x", 24) == nil, "text C1 control chars")
check(Validate.text("\255\254", 24) == nil, "text invalid UTF-8")
check(Validate.text("   ", 24) == nil and Validate.text(string.rep("a", 200), 24) == nil, "text empty / oversized")
local uids = { "12", "15" }
local array = Validate.stringArray(uids, 50, 16)
check(array ~= nil and array ~= uids and array[2] == "15", "stringArray copy")
check(Validate.stringArray({ "1", "1" }, 50, 16) == nil, "stringArray duplicates")
check(Validate.stringArray({ [1] = "1", [3] = "3" }, 50, 16) == nil, "stringArray holes")
check(Validate.stringArray({ a = "1" }, 50, 16) == nil, "stringArray hash keys")
check(Validate.stringArray({}, 50, 16) == nil, "stringArray empty")
local big = {}
for index = 1, 51 do
	big[index] = tostring(index)
end
check(Validate.stringArray(big, 50, 16) == nil, "stringArray too long")
check(Validate.stringArray(setmetatable({ "1" }, {}), 50, 16) == nil, "stringArray metatable")
local flat = Validate.flatTable({ fps = 60, device = "phone", touch = true }, 8)
check(flat ~= nil and flat.fps == 60, "flatTable ok")
check(Validate.flatTable({ nested = {} }, 8) == nil and Validate.flatTable({ x = nan }, 8) == nil, "flatTable rejects")

-- 2. RateLimiter (injected clock)
local now = 0
local limiter = RateLimiter.new(3, 1, function()
	return now
end)
check(limiter:Allow("p") and limiter:Allow("p") and limiter:Allow("p"), "burst of 3")
check(not limiter:Allow("p"), "4th refused")
now = 1
check(limiter:Allow("p") and not limiter:Allow("p"), "refills 1/s")
check(limiter:Allow("q", 3) and not limiter:Allow("q", 1), "cost")
limiter:Forget("q")
check(limiter:Allow("q", 3), "Forget resets the bucket")
local ok = pcall(function()
	RateLimiter.new(0, 1)
end)
check(not ok, "invalid limiter config errors")

-- 3. TextUtil
check(TextUtil.cutChars("Zoë the Brave", 3) == "Zoë", "cutChars")
check(TextUtil.cutBytes("Zoë", 3) == "Zo", "cutBytes never splits")
check(TextUtil.cutChars("\255bad", 10) == "", "invalid UTF-8 dropped")

-- 4. MonetizationConfig
local problems = MonetizationConfig.validate()
check(#problems == 0, "MonetizationConfig.validate: " .. table.concat(problems, "; "))
local SPEC_PASSES = {
	"VIP",
	"DoubleCash",
	"AutoClicker",
	"FastWalk",
	"Teleporter",
	"LuckyEggs",
	"PetSlots",
	"TripleHatch",
	"AutoHatch",
	"OfflineMax",
	"MegaLauncher",
}
for _, passKey in SPEC_PASSES do
	check(MonetizationConfig.getPass(passKey) ~= nil, `spec pass {passKey}`)
end
local SPEC_PRODUCTS: { [string]: string } = {
	CashSmall = "Cash",
	CashMedium = "Cash",
	CashLarge = "Cash",
	CashHuge = "Cash",
	GemsSmall = "Gems",
	GemsMedium = "Gems",
	GemsLarge = "Gems",
	Spins2 = "Spins",
	Spins5 = "Spins",
	Spins10 = "Spins",
	StarterPack = "StarterPack",
	SecretPack = "SecretPack",
	DoubleOffline = "DoubleOffline",
	ServerCash2x = "ServerBoost",
	Cash2x30 = "Boost",
	Barrage = "Barrage",
	Shield1h = "Shield",
	SkipPad = "SkipPad",
	AcornsSmall = "Acorns",
	AcornsLarge = "Acorns",
	TurkeyLure = "TurkeyLure",
	-- B9 Robux crates (2026-10-30 request)
	CrateSupply = "Crate",
	CrateMega = "Crate",
	CrateGolden = "Crate",
	-- R57 World 2 "Dino Valley" (spec §9)
	BonesSmall = "WorldCash",
	BonesMedium = "WorldCash",
	BonesLarge = "WorldCash",
	TimeTravelerPack = "WorldStarter",
	-- R70 World 3 "Moon Base" (R69–R71 spec §2.6)
	MoonRocksSmall = "WorldCash",
	MoonRocksMedium = "WorldCash",
	MoonRocksLarge = "WorldCash",
	AstronautPack = "WorldStarter",
	-- R78 Nuke Pass (spec §2): one season's premium track
	NukePassPremium = "PassPremium",
	-- R89 Pocket Rocket (gift ladder wave §3): a few minutes of income, once per UTC day
	PocketRocket = "PocketRocket",
	RevengeNuke = "RevengeNuke", -- R85 golden revenge nuke (D-defense)
}
for productKey, kind in SPEC_PRODUCTS do
	local product = MonetizationConfig.getProduct(productKey)
	check(product ~= nil and product.kind == kind, `spec product {productKey} ({kind})`)
end
check(#MonetizationConfig.PassOrder == #SPEC_PASSES, "no extra passes")
local productCount = 0
for _ in MonetizationConfig.Products do
	productCount += 1
end
-- Counted against SPEC_PRODUCTS (not a literal) so parallel builders each only add their row.
local specCount = 0
for _ in SPEC_PRODUCTS do
	specCount += 1
end
check(productCount == specCount and #MonetizationConfig.ProductOrder == specCount, "no extra products")
for _, crateKey in { "CrateSupply", "CrateMega", "CrateGolden" } do
	local crate = MonetizationConfig.Products[crateKey]
	check(crate.paidRandom and not crate.oneTime, `{crateKey} is a repeatable paid random item`)
	check(crate.category == "crates" and crate.crates == 1, `{crateKey} grants one held crate`)
end
check(
	MonetizationConfig.Products.CrateSupply.price < MonetizationConfig.Products.CrateMega.price
		and MonetizationConfig.Products.CrateMega.price < MonetizationConfig.Products.CrateGolden.price,
	"crate prices ascend"
)
check(
	MonetizationConfig.Products.Spins5.paidRandom and not MonetizationConfig.Products.GemsSmall.paidRandom,
	"paidRandom"
)
check(MonetizationConfig.Products.StarterPack.oneTime and MonetizationConfig.Products.SecretPack.oneTime, "oneTime")
-- Availability == "published" (+ sale window for products). Id-agnostic so it holds both before
-- and after tools/monetization/publish.py fills PublishedProductIds (GemsSmall has no window).
check(
	MonetizationConfig.isProductAvailable("GemsSmall", 0)
		== MonetizationConfig.isConfigured(MonetizationConfig.Products.GemsSmall.id),
	"product available iff published"
)
check(
	MonetizationConfig.isPassAvailable("VIP") == MonetizationConfig.isConfigured(MonetizationConfig.Passes.VIP.id),
	"pass available iff published"
)
check(MonetizationConfig.getProductById(0) == nil and MonetizationConfig.getPassById(0) == nil, "id 0 never matches")
-- The availability guard on synthetic unpublished copies (every catalogue product is live now).
for _, badId in { 0, -1, 1.5, nan, math.huge } do
	local copy = table.clone(MonetizationConfig.Products.GemsSmall)
	copy.id = badId
	check(not MonetizationConfig.isAvailable(copy, 0), `unpublished copy (id {badId}) unavailable`)
end
check(
	MonetizationConfig.isAvailable(MonetizationConfig.Products.GemsSmall, 0)
		== MonetizationConfig.isConfigured(MonetizationConfig.Products.GemsSmall.id),
	"availability follows the id"
)
-- Unpublished / malformed ids are never "configured" (so never prompted, looked up or matched).
for _, badId in { 0, -5, 1.5, nan, math.huge } do
	check(not MonetizationConfig.isConfigured(badId), `id {badId} is not configured`)
end
-- Every published id routes back to exactly its own definition (ProcessReceipt / pass events).
for key, def in MonetizationConfig.Products do
	if MonetizationConfig.isConfigured(def.id) then
		check(MonetizationConfig.getProductById(def.id) == def, `product {key} routes by id`)
	else
		check(not MonetizationConfig.isProductAvailable(key, 0), `unpublished product {key} unavailable`)
	end
end
for key, def in MonetizationConfig.Passes do
	if MonetizationConfig.isConfigured(def.id) then
		check(MonetizationConfig.getPassById(def.id) == def, `pass {key} routes by id`)
	else
		check(not MonetizationConfig.isPassAvailable(key), `unpublished pass {key} unavailable`)
	end
end
check(MonetizationConfig.getProduct("Nope") == nil and MonetizationConfig.getPass("__index") == nil, "unknown keys")
local acorns = MonetizationConfig.Products.AcornsSmall
check(MonetizationConfig.saleState(acorns, 1_793_491_199) == "NotStarted", "event sale not started")
check(MonetizationConfig.saleState(acorns, 1_793_491_200) == "OnSale", "event sale starts")
check(MonetizationConfig.saleState(acorns, 1_796_083_200) == "Ended", "event sale ends (exclusive)")
check(table.isfrozen(MonetizationConfig.Products) and table.isfrozen(acorns), "catalogue frozen")

-- 5. Remotes: the build plan's full list, each declared once.
local PLAN_EVENTS = {
	"ProfileUpdate",
	"ProfileDelta",
	"ProfileDeltaAck",
	"ProfileResync",
	"Notify",
	"PromptProduct",
	"PromptPass",
	"PurchaseGranted",
	"SetSetting",
	"ProducerClick",
	"ProducerUpgrade",
	"ProducerGemUpgrade", -- owner R86 flat-price gem upgrade (T-tutorial)
	"PadBuy",
	"RenameStand",
	"RenamePlot", -- owner R88 (plot name on the entrance sign)
	"TeleportArea",
	"TeleportHub",
	"TeleportPlot", -- B5 (2026-10-30 request)
	"Rebirth",
	"RebirthShopBuy",
	"OfflineEarnings",
	"TutorialState",
	"PlotRevealDone", -- B5 (2026-10-30 request)
	"TravelWorld", -- owner R57 World 2: travel intent (C→S)
	"WorldTravel", -- owner R57 World 2: travel phase / failure (S→C, cosmetic)
	"ClaimDaily",
	"ClaimTimeReward",
	"ClaimTimeRewardsAll", -- owner R89 gift ladder CLAIM ALL (C→S)
	"FavoriteMoment", -- owner R89 favorite prompt moment (S→C)
	"FavoriteReport", -- owner R89 favorite prompt shown / answered (C→S)
	"SpinWheel",
	"SpinResult",
	"RedeemCode",
	"CodeResult",
	"ClaimGroupReward",
	"GroupRewardResult",
	"ClaimNotifyReward",
	"HatchEgg",
	"HatchResult",
	"EquipPet",
	"DeletePets",
	"EquipBest",
	"OpenCrate",
	"CrateResult",
	"LockPets", -- B9 (2026-10-30 request)
	"EquipTrail", -- B9 (2026-10-30 request)
	"PetIndexClaim", -- R78 Pet Index milestone claim (A-pets)
	"AttackLaunch",
	"NukeFlight",
	"DefenseUpgrade",
	"DefenseTower", -- owner R80 defence tower slot buy / upgrade (C→S)
	"ShieldActivate",
	"AttackPickerFocus", -- R104 picker streaming: the framed target slot (C→S; 0 = closed)
	"KnockdownTap", -- owner R50 knockdown: "TAP TO REBUILD!" (C→S)
	"KnockdownState", -- owner R50 knockdown: the owner's knocked areas + immunity (S→C)
	"ChangeNotesAction", -- owner R58 WHAT'S NEW: seen / shown / cta / closed (C→S)
	"ChangeNotesAdmin", -- owner R58 WHAT'S NEW: admin preview / replay (S→C, admins' commands only)
	"EventCollect",
	"EventRedeemSheet",
	"EventState",
	"EventShopBuy", -- B11 (2026-10-30 request)
	"LuckyButtons", -- R69 Lucky Buttons (S→C)
	"LuckyButtonClaim", -- R69 Lucky Buttons (C→S)
	"QuestClaim", -- R78 Quests: claim a goal / mission / chest / trophy tier (C→S)
	"QuestReroll", -- R78 Quests: today's free mission reroll (C→S)
	"PassClaim", -- R78 Nuke Pass: claim one tier (C→S)
	"PassClaimAll", -- R78 Nuke Pass: CLAIM ALL (C→S)
	"Social", -- R78 Rush + Friends: Friend Boost state / Comeback Rush announcement (S→C)
	"FriendInvite", -- R78 Friends: invite prompt outcome, analytics only (C→S)
	"HappyHour", -- R89 Happy Hours: the player's own event pickups (S→C)
	"HappyHourCollect", -- R89 Happy Hours: walked into an own pickup (C→S)
	"KineticAction", -- R90 Mega Lever + Tip Jar: pull / collect intent (C→S)
	"Kinetic", -- R90 Mega Lever + Tip Jar: Mega Batch / tips paid / tip dropped in (S→C, owner)
	"FlavorClaim", -- R89 Flavour Book: claim a discovery reward / all ready ones (C→S)
	"FlavorTipSeen", -- R112 Lucky Nukes: the one-time tip card was dismissed (C→S)
	"FlavorHighlight", -- R89 Surprise Batches: the owner's Galaxy+ reveal (S→C)
	"BigPop", -- R89 Big Pop: the server-wide broadcast (S→C all)
	"FunnelStep",
	"OffersSeen",
	"ClientDevice",
	"ClientPerf",
	"AnalyticsRequest",
	"AnalyticsReport",
	"AnalyticsRawRequest",
	"AnalyticsRawPage",
	"AdminCommand",
	"AdminResult",
	"AdminState",
}
local declared: { [string]: number } = {}
for _, name in Remotes.EventNames do
	declared[name] = (declared[name] or 0) + 1
end
for _, name in Remotes.UnreliableNames do
	declared[name] = (declared[name] or 0) + 1
end
for _, name in PLAN_EVENTS do
	check(declared[name] == 1, `remote {name} declared once`)
end
check(declared.IncomePop == 1 and Remotes.UnreliableNames[1] == "IncomePop", "IncomePop is unreliable")
check(#Remotes.EventNames == #PLAN_EVENTS, "no undocumented reliable remotes")

-- 6. R57 World 2 ------------------------------------------------------------------------------------
-- The save format and the registry agree (ProfileLogic reads WorldGeometry only, by design).
check(
	ProfileLogic.Limits.MaxWorlds == WorldsConfig.MaxWorlds
		and ProfileLogic.Limits.MaxWorldKeyLength == WorldsConfig.MaxIdLength,
	"profile world limits match the registry"
)
check(#ProfileLogic.KnownWorlds == #WorldsConfig.extra(), "every extra world is a known profile world")
for _, def in WorldsConfig.extra() do
	check(
		table.find(ProfileLogic.KnownWorlds, def.id) ~= nil and ProfileLogic.isWorldKey(def.id),
		`profile knows world {def.id}`
	)
end
-- Validate.worldId: known worlds only, strict shape before the lookup.
check(Validate.worldId("main") == "main" and Validate.worldId("dino") == "dino", "worldId known worlds")
for _, bad in { "Dino", "space", "", " dino", "dino ", "di-no", string.rep("a", 17), "1dino", "__index" } do
	check(Validate.worldId(bad) == nil, `worldId rejects {bad}`)
end
for _, bad in
	{ 5, true, {}, nan, setmetatable({}, {
		__tostring = function()
			return "dino"
		end,
	}) }
do
	check(Validate.worldId(bad) == nil, "worldId rejects non-strings")
end
check(Validate.worldIdOrMain(nil) == "main" and Validate.worldIdOrMain("dino") == "dino", "worldIdOrMain")
check(Validate.worldIdOrMain(false) == nil and Validate.worldIdOrMain("x") == nil, "junk is never read as main")
-- Validate.travelRequest: per-target index rules; the area range is the WORLD's area count.
local dinoDef = WorldsConfig.get("dino")
local dinoAreas = dinoDef.geometry.areaCount
local mainAreas = WorldsConfig.get("main").geometry.areaCount
check(dinoAreas == #dinoDef.economy.Areas and dinoAreas >= 1, "dino area count")
local request = Validate.travelRequest("dino", "spawn", nil)
check(request ~= nil and request.worldId == "dino" and request.target == "spawn" and request.index == nil, "spawn")
check(Validate.travelRequest("dino", "spawn", 1) == nil, "spawn takes no index")
request = Validate.travelRequest("dino", "area", dinoAreas)
check(request ~= nil and request.index == dinoAreas, "last dino area")
check(Validate.travelRequest("dino", "area", dinoAreas + 1) == nil, "past the dino area count")
check(
	Validate.travelRequest("main", "area", mainAreas) ~= nil
		and Validate.travelRequest("main", "area", mainAreas + 1) == nil,
	"main area range"
)
check(
	Validate.travelRequest("dino", "area", 0) == nil and Validate.travelRequest("dino", "area", 1.5) == nil,
	"area index"
)
check(Validate.travelRequest("dino", "area", nil) == nil, "area needs an index")
check(Validate.travelRequest("dino", "plot", WorldLayout.PlotCount) ~= nil, "last plot")
check(Validate.travelRequest("dino", "plot", WorldLayout.PlotCount + 1) == nil, "past the last plot")
check(
	Validate.travelRequest("dino", "teleport", 1) == nil and Validate.travelRequest("dino", "AREA", 1) == nil,
	"target"
)
check(Validate.travelRequest("nope", "spawn", nil) == nil, "unknown world")
check(table.isfrozen(Validate.TravelTargets) and #Validate.TravelTargets == 3, "travel targets frozen")
-- Validate.rebirthShopBuy: the key must be in THAT world's shop.
for shopKey in RebirthConfig.Shop do
	local k, w = Validate.rebirthShopBuy(shopKey, nil)
	check(k == shopKey and w == "main", `main shop key {shopKey} (nil world)`)
	k, w = Validate.rebirthShopBuy(shopKey, "main")
	check(k == shopKey and w == "main", `main shop key {shopKey}`)
	if dinoDef.rebirth.Shop[shopKey] == nil then
		check(Validate.rebirthShopBuy(shopKey, "dino") == nil, `main-only key {shopKey} refused in dino`)
	end
end
for shopKey in dinoDef.rebirth.Shop do
	local k, w = Validate.rebirthShopBuy(shopKey, "dino")
	check(k == shopKey and w == "dino", `dino shop key {shopKey}`)
end
check(Validate.rebirthShopBuy("clickPower", "Dino") == nil, "bad world refuses the buy")
check(Validate.rebirthShopBuy("nope", "dino") == nil and Validate.rebirthShopBuy(nil, "dino") == nil, "bad key")

-- Dino products (spec §9): kinds, world, numbers, one-time, NOT paid random.
local BONES = { BonesSmall = { 23, 600, 500 }, BonesMedium = { 63, 1800, 5000 }, BonesLarge = { 159, 7200, 50000 } }
for productKey, numbers in BONES do
	local product = MonetizationConfig.Products[productKey]
	check(product.kind == "WorldCash" and product.world == "dino" and product.category == "dino", `{productKey} shape`)
	check(
		product.price == numbers[1] and product.incomeSeconds == numbers[2] and product.cashFloor == numbers[3],
		`{productKey} spec numbers`
	)
	check(not product.paidRandom and not product.oneTime, `{productKey} is a repeatable fixed grant`)
end
local pack = MonetizationConfig.Products.TimeTravelerPack
check(pack.kind == "WorldStarter" and pack.world == "dino" and pack.oneTime and not pack.paidRandom, "pack flags")
check(pack.price == 79 and pack.incomeSeconds == 1200 and pack.cashFloor == 2000, "pack numbers")
check(pack.pet == "time_ptero" and pack.boostKey == "cash2x" and pack.boostSeconds == 1800, "pack grant")
-- Robux makes Bones reachable, so every egg priced in such a currency must be gated (paid random).
local robuxWorld = MonetizationConfig.robuxWorldCurrencies()
check(robuxWorld.bones == true and robuxWorld.cash == nil, "Bones are Robux-reachable")
for _, eggId in EggConfig.Order do
	local egg = EggConfig.Eggs[eggId]
	if robuxWorld[egg.currency] then
		check(EggConfig.PaidRandomCurrencies[egg.currency] == true, `egg {eggId} ({egg.currency}) is gated`)
	end
end

print(`[validate] {checks} checks passed`)
