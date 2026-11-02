--!strict
--[[
	MonetizationConfig — the FULL SellNukes Robux catalogue (design spec §11): every game pass and
	developer product with a stable string key, its kind, intended Robux price, display name,
	description, icon key and the kind-specific grant numbers.

	Purpose:
		One auditable list of everything a player can buy with Robux. Server code (MonetizationService
		and the services that register product handlers) and client code (shop screens, starburst
		offers, welcome-back DOUBLE IT!) read the same definitions, so a price or a name is never
		duplicated.

	Shape (build plan contract):
		MonetizationConfig.Passes[key]   = PassDef    { key, id, price, name, description, icon, perks, order }
		MonetizationConfig.Products[key] = ProductDef { key, kind, id, price, name, description, icon,
		                                                category, order, oneTime, paidRandom, ... }
		Ids come from Shared/Config/PublishedProductIds. id 0 = NOT CREATED YET: the server never
		prompts it, never looks its ownership up and never matches a receipt to it; the UI shows
		COMING SOON (`isProductAvailable` / `isPassAvailable` are false).
		`price` is the Robux price B12 set on the Creator Dashboard. All items except the fixed-price
		PocketRocket use Roblox MANAGED PRICING, so the client UI shows the LIVE price instead (Client/UI/PriceBook:
		MarketplaceService:GetProductInfoAsync, "..." until known); this value is only its
		fallback after every fetch failed, and the server never charges or grants by it.

	Product kinds and who grants them:
		"Gems"          built in: MonetizationService adds `gems` (fixed amount).
		Every other kind is HANDLER-ROUTED: the owning service calls
		MonetizationService.registerProductHandler(kind, handler) in its Init. Until a handler is
		registered the product is refused at the prompt ("coming soon") and a receipt that still
		arrives stays NotProcessedYet (Roblox retries) — Robux is never taken for nothing.
			"Cash"          B7 shop: `incomeSeconds` of the buyer's current income, at least `cashFloor`
			"Spins"         B7 wheel: +`spins` paid Lucky Wheel spins (PAID RANDOM)
			"StarterPack"   B7 shop: one-time bundle (profile.starter.bought)
			"SecretPack"    B7 shop: one-time, global limited stock (profile.secretPack.bought)
			"DoubleOffline" B5 offline: doubles the pending offline payout
			"ServerBoost"   B7/B5: whole-server x`multiplier` cash for `durationSeconds`
			"Boost"         B7/B5: personal boost `boostKey` for `durationSeconds`
			"SkipPad"       B5 tycoon: buys the next available pad instantly (builds in)
			"Barrage"       B10 attack: +`nukes` launches
			"Shield"        B10 attack: shield for `durationSeconds`
			"RevengeNuke"   R85 attack: +`nukes` stored GOLDEN revenge nukes, fired at once at the
			                newest attacker who hit the buyer when they are still here and unshielded,
			                else kept for the target picker (Server/Services/AttackService; the prompt
			                is refused while nobody can be struck back at)
			"Acorns"        B11 event: +`acorns` (sale window = the Harvest Feast event)
			"TurkeyLure"    B11 event: spawns a Golden Turkey on the buyer's plot (event window;
			                PAID RANDOM: a lured turkey always rolls a Feast Sticker)
			"Crate"         B9 crates: +`crates` HELD crates of CrateConfig.ByProduct[product.key]
			                (opened free with OpenCrate; PAID RANDOM)
			"WorldCash"     R57 World 2: `incomeSeconds` of the buyer's idle income IN `world`, at
			                least `cashFloor`, paid in that world's currency (Dino Valley: Bones)
			                into profile.worlds.<world>.cash (W3 TycoonService handler)
			"WorldStarter"  R57 World 2: one-time world bundle (profile.worlds.<world>.starter.bought):
			                `incomeSeconds` of world income (floor `cashFloor`) + the FIXED pet `pet`
			                + an optional `boostKey` boost for `boostSeconds` (W3 handler)
			"PassPremium"   R78 Nuke Pass: premium track of the ACTIVE season (Server/Services/
			                PassService; prompt refused outside a season / when already owned; a
			                late receipt unlocks the season that ended ≤ PassConfig.PremiumGraceSeconds
			                ago, else pays PassConfig.PremiumFallbackGems — never Robux for nothing)
			"PocketRocket"  R89 gift ladder wave: `incomeSeconds` of the buyer's automated income (at
			                least `cashFloor`) through the shared reward path, ONCE PER UTC DAY (prompt
			                refused once profile.gifts.rocketDay == today; a late receipt is always
			                granted). validate() keeps its value per Robux at or below every "Cash"
			                pack's (Server/Retention/PocketRocket, Shared/Config/GiftsConfig)

	World products (`world` set, R57): the prompt is refused while that world is LOCKED for the
	buyer (MonetizationService; the UI hides them anyway). A receipt that still arrives is always
	granted into that world's wallet, so Robux are never taken for nothing. World currencies become
	Robux-reachable through them (robuxWorldCurrencies), so anything RANDOM bought with such a
	currency (Dino eggs with Bones) is a paid random item (EggConfig.PaidRandomCurrencies.bones;
	tests/validate.luau cross-checks every egg).

	Flags:
		oneTime     the owning handler refuses a second grant; MonetizationService refuses the
		            prompt when the profile flag says bought (StarterPack / SecretPack /
		            WorldStarter = worlds.<world>.starter.bought); validate() allows oneTime only
		            on those kinds, so a flag can never go unenforced
		paidRandom  a random reward bought with Robux; refused for players whose region restricts
		            paid random items (PolicyService, fail closed) — Lucky Spins, crates, the
		            Turkey Lure. (Starter / Secret Pack are NOT flagged: they stay on sale for
		            everyone and pay their spins as gems where paid random items are restricted —
		            Server/Retention/RewardLogic.robuxReward.)
		saleStarts / saleEnds  unix window [start, end): never prompted outside it; a receipt that
		            still arrives is always granted (the player already paid)

	Icon keys (B2 maps them to stud-style icons): see MonetizationConfig.IconKeys.

	Connects to: Shared/Config/PublishedProductIds (ids), Server/Services/MonetizationService
	(prompts, receipts, pass ownership), B7 shop screens + starburst offers, tests/validate.luau
	(runs `validate()`).

	Example:
		local product = MonetizationConfig.getProduct("GemsSmall")
		print(product and product.name, product and product.price) --> "Pile of Gems" 49
		print(MonetizationConfig.isProductAvailable("GemsSmall", os.time())) --> false (id 0)
]]

local PublishedProductIds = require(script.Parent.PublishedProductIds)

export type PassKey =
	"VIP"
	| "DoubleCash"
	| "AutoClicker"
	| "FastWalk"
	| "Teleporter"
	| "LuckyEggs"
	| "PetSlots"
	| "TripleHatch"
	| "AutoHatch"
	| "OfflineMax"
	| "MegaLauncher"

export type ProductKey =
	"CashSmall"
	| "CashMedium"
	| "CashLarge"
	| "CashHuge"
	| "GemsSmall"
	| "GemsMedium"
	| "GemsLarge"
	| "Spins2"
	| "Spins5"
	| "Spins10"
	| "StarterPack"
	| "SecretPack"
	| "DoubleOffline"
	| "ServerCash2x"
	| "Cash2x30"
	| "Barrage"
	| "Shield1h"
	| "SkipPad"
	| "AcornsSmall"
	| "AcornsLarge"
	| "TurkeyLure"
	| "CrateSupply"
	| "CrateMega"
	| "CrateGolden"
	-- R57 World 2 "Dino Valley" (spec §9)
	| "BonesSmall"
	| "BonesMedium"
	| "BonesLarge"
	| "TimeTravelerPack"
	-- R70 World 3 "Moon Base" (R69–R71 spec §2.6)
	| "MoonRocksSmall"
	| "MoonRocksMedium"
	| "MoonRocksLarge"
	| "AstronautPack"
	-- R78 Nuke Pass (spec §2): the premium track of the active season
	| "NukePassPremium"
	-- R89 Pocket Rocket (gift ladder wave §3): a few minutes of income, once per UTC day
	| "PocketRocket"
	-- R85 golden revenge nuke (attack): strike back at whoever just nuked you
	| "RevengeNuke"

export type ProductKind =
	"Cash"
	| "Gems"
	| "Spins"
	| "StarterPack"
	| "SecretPack"
	| "DoubleOffline"
	| "ServerBoost"
	| "Boost"
	| "SkipPad"
	| "Barrage"
	| "Shield"
	| "Acorns"
	| "TurkeyLure"
	| "Crate"
	| "WorldCash"
	| "WorldStarter"
	| "PassPremium"
	| "PocketRocket"
	| "RevengeNuke"

-- Shop grouping (B7 tabs / sections; "crates" = B9's Robux crates; "dino" = R57 DINO VALLEY;
-- "moon" = R70 MOON BASE; "pass" = R78 Nuke Pass, sold from the NukePass screen / HUD offer).
export type Category =
	"cash"
	| "gems"
	| "spins"
	| "packs"
	| "boosts"
	| "attack"
	| "event"
	| "crates"
	| "dino"
	| "moon"
	| "pass"

export type PassDef = {
	key: PassKey,
	id: number, -- Creator Dashboard game pass id (0 = not created yet)
	price: number, -- Robux (the price set on the dashboard)
	name: string,
	description: string,
	icon: string, -- one of IconKeys
	perks: { string }, -- bullet points on the pass card
	order: number, -- display order (ascending)
}

export type ProductDef = {
	key: ProductKey,
	kind: ProductKind,
	id: number, -- Creator Dashboard developer product id (0 = not created yet)
	price: number, -- Robux
	name: string,
	description: string,
	icon: string, -- one of IconKeys
	category: Category,
	order: number, -- display order within the category (ascending)
	oneTime: boolean,
	paidRandom: boolean,
	badge: string?, -- optional ribbon ("BEST VALUE", "LIMITED")
	saleStarts: number?, -- unix seconds; nil = always
	saleEnds: number?, -- unix seconds (exclusive); nil = never ends
	-- Kind-specific grant numbers (nil when the kind does not use them):
	gems: number?, -- "Gems"
	spins: number?, -- "Spins"
	incomeSeconds: number?, -- "Cash" / "PocketRocket": seconds of the buyer's current income
	cashFloor: number?, -- "Cash" / "PocketRocket": minimum cash granted
	durationSeconds: number?, -- "ServerBoost" / "Boost" / "Shield"
	multiplier: number?, -- "ServerBoost" / "Boost"
	boostKey: string?, -- "Boost": profile.boosts key
	nukes: number?, -- "Barrage" / "RevengeNuke" (stored golden charges)
	acorns: number?, -- "Acorns"
	crates: number?, -- "Crate": held crates granted per receipt (crate id: CrateConfig.ByProduct)
	-- R57 world products ("WorldCash" / "WorldStarter"; `incomeSeconds` / `cashFloor` /
	-- `boostKey` are shared with the main kinds above):
	world: string?, -- the non-main world (WorldsConfig id) whose currency / unlock this uses
	pet: string?, -- "WorldStarter": the FIXED pet granted (PetConfig id; not a random item)
	boostSeconds: number?, -- "WorldStarter": duration of the `boostKey` boost
}

export type SaleState = "NotStarted" | "OnSale" | "Ended"

local MonetizationConfig = {}

-- Harvest Feast event window (spec §10): 2026-11-01T00:00:00Z → 2026-12-01T00:00:00Z.
local HARVEST_STARTS = 1_793_491_200
local HARVEST_ENDS = 1_796_083_200

-- Icon keys the UI kit knows (B2 maps each to a stud-style icon).
MonetizationConfig.IconKeys = table.freeze({
	"cash",
	"gem",
	"spin",
	"gift",
	"crown",
	"star",
	"clock",
	"lightning",
	"cursor",
	"boot",
	"teleport",
	"egg",
	"pet",
	"rocket",
	"shield",
	"skip",
	"acorn",
	"turkey",
	"moon",
	"crate",
	-- R57 World 2 shop icons (Blender-rendered, IconAssets keys of the same name)
	"BonesPack",
	"TimeTravelerPack",
	-- R70 World 3 shop icons (W1b, Blender-rendered, IconAssets keys of the same name)
	"MoonRocksPack",
	"AstronautPack",
	-- R78 Nuke Pass icon (golden ticket + cartoon nuke; IconAssets key of the same name)
	"NukePass",
	-- R89 Pocket Rocket icon (rocket over a money stack; IconAssets key of the same name)
	"PocketRocket",
})

-- Text caps (UI layout budgets; validate() enforces them).
MonetizationConfig.MaxNameLength = 28
MonetizationConfig.MaxDescriptionLength = 120
MonetizationConfig.MaxPerkLength = 48

--[[ True when a Creator Dashboard id has been filled in (0 / negative / fractional / NaN = not). ]]
function MonetizationConfig.isConfigured(id: number): boolean
	return id == id and id > 0 and id % 1 == 0 and id ~= math.huge
end

-- The published id of a key in one PublishedProductIds group (0 when absent or not a number).
local function publishedId(group: { [string]: unknown }, key: string): number
	local id = group[key]
	return if type(id) == "number" then id else 0
end

-- Builds one frozen pass definition (fills `id` from PublishedProductIds).
local function pass(def: {
	key: PassKey,
	price: number,
	name: string,
	description: string,
	icon: string,
	perks: { string },
	order: number,
}): PassDef
	local built: PassDef = {
		key = def.key,
		id = publishedId(PublishedProductIds.Passes :: any, def.key),
		price = def.price,
		name = def.name,
		description = def.description,
		icon = def.icon,
		perks = table.freeze(def.perks),
		order = def.order,
	}
	-- Frozen at runtime; typed as the plain PassDef for readers.
	return table.freeze(built) :: any
end

-- Builds one frozen product definition (fills `id`; defaults oneTime / paidRandom to false).
local function product(def: { [string]: any }): ProductDef
	local built = table.clone(def)
	built.id = publishedId(PublishedProductIds.Products :: any, def.key)
	built.oneTime = def.oneTime == true
	built.paidRandom = def.paidRandom == true
	return table.freeze(built) :: any
end

-- Game passes (spec §11). Perk numbers are the spec's; the gameplay configs own the math.
-- 2026-10-31: live base prices reduced by another 30% (nearest whole Robux), verified in Creator Dashboard.
-- Managed pricing stays enabled; PriceBook fetches each player's live price before this fallback.
local passes: { [PassKey]: PassDef } = {
	VIP = pass({
		key = "VIP",
		price = 122,
		name = "VIP",
		description = "Earn more on everything, get a golden VIP chat tag and the comfy VIP lounge.",
		icon = "crown",
		perks = { "+50% cash forever", "Golden VIP chat tag", "VIP lounge access" },
		order = 1,
	}),
	DoubleCash = pass({
		key = "DoubleCash",
		price = 195,
		name = "2x Cash",
		description = "Every nuke you sell is worth double. Forever!",
		icon = "cash",
		perks = { "x2 cash from every producer", "Stacks with VIP and boosts" },
		order = 2,
	}),
	AutoClicker = pass({
		key = "AutoClicker",
		price = 73,
		name = "Auto Clicker",
		description = "Producers keep clicking for you, even before you hire a manager.",
		icon = "cursor",
		perks = { "Auto-clicks your producers", "Toggle it any time" },
		order = 3,
	}),
	FastWalk = pass({
		key = "FastWalk",
		price = 24,
		name = "Fast Walk",
		description = "Zoom around your plot and the hub at super speed.",
		icon = "boot",
		perks = { "Much faster walking", "Toggle it in Settings" },
		order = 4,
	}),
	Teleporter = pass({
		key = "Teleporter",
		price = 48,
		name = "Teleporter",
		description = "Teleport to any area you own or the hub with one tap.",
		icon = "teleport",
		perks = { "Teleport to any owned area", "Teleport to the hub" },
		order = 5,
	}),
	LuckyEggs = pass({
		key = "LuckyEggs",
		price = 97,
		name = "Lucky Eggs",
		description = "Better odds for rare pets from every egg you hatch.",
		icon = "egg",
		perks = { "Luckier egg hatches", "Works on every egg" },
		order = 6,
	}),
	PetSlots = pass({
		key = "PetSlots",
		price = 73,
		name = "+2 Pet Slots",
		description = "Equip two more pets for even more cash.",
		icon = "pet",
		perks = { "+2 equipped pets" },
		order = 7,
	}),
	TripleHatch = pass({
		key = "TripleHatch",
		price = 73,
		name = "Triple Hatch",
		description = "Hatch three eggs at once.",
		icon = "egg",
		perks = { "Hatch 3 eggs at a time" },
		order = 8,
	}),
	AutoHatch = pass({
		key = "AutoHatch",
		price = 122,
		name = "Auto Hatch",
		description = "Keep hatching eggs automatically while you stand at a stand.",
		icon = "egg",
		perks = { "Automatic hatching", "Stop any time" },
		order = 9,
	}),
	OfflineMax = pass({
		key = "OfflineMax",
		price = 97,
		name = "Offline Max",
		description = "Your business earns full cash for up to 24 hours while you are away.",
		icon = "moon",
		perks = { "Offline earnings up to 24 h", "100% offline rate" },
		order = 10,
	}),
	MegaLauncher = pass({
		key = "MegaLauncher",
		price = 73,
		name = "Mega Launcher",
		description = "Your cartoon nukes pay double rewards in Attack mode.",
		icon = "rocket",
		perks = { "x2 attack rewards" },
		order = 11,
	}),
}
MonetizationConfig.Passes = table.freeze(passes)

-- Developer products (spec §11); verified live base prices reduced by 20% on 2026-10-31.
local products: { [ProductKey]: ProductDef } = {
	-- Cash packs: scaled to the buyer's current income, with a floor for brand-new players.
	CashSmall = product({
		key = "CashSmall",
		kind = "Cash",
		price = 23,
		name = "Stack of Cash",
		description = "10 minutes of your income, instantly.",
		icon = "cash",
		category = "cash",
		order = 1,
		incomeSeconds = 600,
		cashFloor = 1_000,
	}),
	CashMedium = product({
		key = "CashMedium",
		kind = "Cash",
		price = 63,
		name = "Bag of Cash",
		description = "30 minutes of your income, instantly.",
		icon = "cash",
		category = "cash",
		order = 2,
		incomeSeconds = 1_800,
		cashFloor = 10_000,
	}),
	CashLarge = product({
		key = "CashLarge",
		kind = "Cash",
		price = 159,
		name = "Crate of Cash",
		description = "2 hours of your income, instantly.",
		icon = "cash",
		category = "cash",
		order = 3,
		badge = "POPULAR",
		incomeSeconds = 7_200,
		cashFloor = 100_000,
	}),
	CashHuge = product({
		key = "CashHuge",
		kind = "Cash",
		price = 359,
		name = "Vault of Cash",
		description = "6 hours of your income, instantly.",
		icon = "cash",
		category = "cash",
		order = 4,
		badge = "BEST VALUE",
		incomeSeconds = 21_600,
		cashFloor = 1_000_000,
	}),
	-- Gem packs (built in: fixed amounts).
	GemsSmall = product({
		key = "GemsSmall",
		kind = "Gems",
		price = 39,
		name = "Pile of Gems",
		description = "100 gems for crates and goodies.",
		icon = "gem",
		category = "gems",
		order = 1,
		gems = 100,
	}),
	GemsMedium = product({
		key = "GemsMedium",
		kind = "Gems",
		price = 119,
		name = "Bag of Gems",
		description = "350 gems for crates and goodies.",
		icon = "gem",
		category = "gems",
		order = 2,
		badge = "POPULAR",
		gems = 350,
	}),
	GemsLarge = product({
		key = "GemsLarge",
		kind = "Gems",
		price = 319,
		name = "Chest of Gems",
		description = "1,000 gems for crates and goodies.",
		icon = "gem",
		category = "gems",
		order = 3,
		badge = "BEST VALUE",
		gems = 1_000,
	}),
	-- Lucky Wheel spins (paid random items).
	Spins2 = product({
		key = "Spins2",
		kind = "Spins",
		price = 39,
		name = "x2 Lucky Spins",
		description = "Two extra spins on the Lucky Wheel.",
		icon = "spin",
		category = "spins",
		order = 1,
		paidRandom = true,
		spins = 2,
	}),
	Spins5 = product({
		key = "Spins5",
		kind = "Spins",
		price = 79,
		name = "x5 Lucky Spins",
		description = "Five extra spins on the Lucky Wheel.",
		icon = "spin",
		category = "spins",
		order = 2,
		paidRandom = true,
		badge = "POPULAR",
		spins = 5,
	}),
	Spins10 = product({
		key = "Spins10",
		kind = "Spins",
		price = 143,
		name = "x10 Lucky Spins",
		description = "Ten extra spins on the Lucky Wheel.",
		icon = "spin",
		category = "spins",
		order = 3,
		paidRandom = true,
		badge = "BEST VALUE",
		spins = 10,
	}),
	-- One-time packs.
	StarterPack = product({
		key = "StarterPack",
		kind = "StarterPack",
		price = 79,
		name = "Starter Pack",
		description = "A big head start: cash, gems, spins and a starter pet. Once per player!",
		icon = "gift",
		category = "packs",
		order = 1,
		oneTime = true,
		badge = "ONE TIME",
	}),
	SecretPack = product({
		key = "SecretPack",
		kind = "SecretPack",
		price = 399,
		name = "Secret Pack",
		description = "A super rare secret bundle. Only a limited number exist in the whole game!",
		icon = "star",
		category = "packs",
		order = 2,
		oneTime = true,
		badge = "LIMITED",
	}),
	-- Boosts.
	DoubleOffline = product({
		key = "DoubleOffline",
		kind = "DoubleOffline",
		price = 31,
		name = "Double It!",
		description = "Double the cash your business made while you were away.",
		icon = "moon",
		category = "boosts",
		order = 1,
	}),
	ServerCash2x = product({
		key = "ServerCash2x",
		kind = "ServerBoost",
		price = 159,
		name = "Server 2x Cash",
		description = "Everyone in the server earns double cash for 15 minutes. Be a hero!",
		icon = "lightning",
		category = "boosts",
		order = 2,
		durationSeconds = 900,
		multiplier = 2,
	}),
	Cash2x30 = product({
		key = "Cash2x30",
		kind = "Boost",
		price = 79,
		name = "2x Cash (30 min)",
		description = "Double cash for 30 minutes of play.",
		icon = "clock",
		category = "boosts",
		order = 3,
		durationSeconds = 1_800,
		multiplier = 2,
		boostKey = "cash2x",
	}),
	SkipPad = product({
		key = "SkipPad",
		kind = "SkipPad",
		price = 20,
		name = "Skip Pad",
		description = "Buy your next pad instantly and watch it build in.",
		icon = "skip",
		category = "boosts",
		order = 4,
	}),
	-- Attack mode.
	Barrage = product({
		key = "Barrage",
		kind = "Barrage",
		price = 79,
		name = "Nuke Barrage",
		description = "20 extra cartoon nukes to send in Attack mode.",
		icon = "rocket",
		category = "attack",
		order = 1,
		nukes = 20,
	}),
	-- R85 golden revenge nuke (owner: "If you get nuked, add like a 39 ... revenge nuke button that
	-- you can pay for with Robux"): sold from the HUD's GOLDEN REVENGE button while the player who
	-- hit you is here and hittable; one stored golden charge (AttackConfig.Golden).
	RevengeNuke = product({
		key = "RevengeNuke",
		kind = "RevengeNuke",
		price = 31, -- owner R85 asked ~39; owner 2026-11-01: "31 robux is fine" (store-wide product cut)
		name = "Golden Revenge Nuke",
		description = "Strike back at whoever nuked you with a golden, extra-tough nuke - no reload!",
		icon = "rocket",
		category = "attack",
		order = 3,
		nukes = 1,
	}),
	Shield1h = product({
		key = "Shield1h",
		kind = "Shield",
		price = 39,
		name = "Shield (1 h)",
		description = "A bubble dome that blocks every incoming nuke for one hour.",
		icon = "shield",
		category = "attack",
		order = 2,
		durationSeconds = 3_600,
	}),
	-- Harvest Feast event (only on sale during the event).
	AcornsSmall = product({
		key = "AcornsSmall",
		kind = "Acorns",
		price = 39,
		name = "Acorn Basket",
		description = "100 acorns for Harvest Eggs and decorations.",
		icon = "acorn",
		category = "event",
		order = 1,
		saleStarts = HARVEST_STARTS,
		saleEnds = HARVEST_ENDS,
		acorns = 100,
	}),
	AcornsLarge = product({
		key = "AcornsLarge",
		kind = "Acorns",
		price = 119,
		name = "Acorn Wagon",
		description = "400 acorns for Harvest Eggs and decorations.",
		icon = "acorn",
		category = "event",
		order = 2,
		saleStarts = HARVEST_STARTS,
		saleEnds = HARVEST_ENDS,
		badge = "BEST VALUE",
		acorns = 400,
	}),
	TurkeyLure = product({
		key = "TurkeyLure",
		kind = "TurkeyLure",
		price = 63,
		name = "Golden Turkey Lure",
		description = "Call a Golden Turkey to your plot right now.",
		icon = "turkey",
		category = "event",
		order = 3,
		-- The lured turkey's guaranteed Feast Sticker is a random item bought with Robux.
		paidRandom = true,
		saleStarts = HARVEST_STARTS,
		saleEnds = HARVEST_ENDS,
	}),
	-- Robux crates (B9; PAID RANDOM items: refused where PolicyService restricts them). Each receipt
	-- adds a HELD crate the player opens with OpenCrate; prices track the gem price of the same
	-- crate (Supply 120 / Mega 350 / Golden 1,000 gems ≈ the Gems packs' Robux per gem).
	CrateSupply = product({
		key = "CrateSupply",
		kind = "Crate",
		price = 39,
		name = "Supply Crate",
		description = "One Supply Crate full of boosts, gems, eggs and pets!",
		icon = "crate",
		category = "crates",
		order = 1,
		paidRandom = true,
		crates = 1,
	}),
	CrateMega = product({
		key = "CrateMega",
		kind = "Crate",
		price = 119,
		name = "Mega Crate",
		description = "One Mega Crate with bigger rewards and rarer finds!",
		icon = "crate",
		category = "crates",
		order = 2,
		paidRandom = true,
		badge = "POPULAR",
		crates = 1,
	}),
	CrateGolden = product({
		key = "CrateGolden",
		kind = "Crate",
		price = 319,
		name = "Golden Crate",
		description = "One Golden Crate packed with the very best rewards!",
		icon = "crate",
		category = "crates",
		order = 3,
		paidRandom = true,
		badge = "BEST VALUE",
		crates = 1,
	}),
	-- R57 World 2 "Dino Valley" (spec §9). Bones = profile.worlds.dino.cash; refused at the prompt
	-- while Dino Valley is locked. NOT paid random (fixed amounts / a fixed pet), but they make
	-- Bones Robux-reachable, so Dino eggs bought with Bones ARE gated (see the header).
	BonesSmall = product({
		key = "BonesSmall",
		kind = "WorldCash",
		world = "dino",
		price = 23,
		name = "Pile of Bones",
		description = "10 minutes of your Dino Valley income in Bones, instantly.",
		icon = "BonesPack",
		category = "dino",
		order = 1,
		incomeSeconds = 600,
		cashFloor = 500,
	}),
	BonesMedium = product({
		key = "BonesMedium",
		kind = "WorldCash",
		world = "dino",
		price = 63,
		name = "Sack of Bones",
		description = "30 minutes of your Dino Valley income in Bones, instantly.",
		icon = "BonesPack",
		category = "dino",
		order = 2,
		badge = "POPULAR",
		incomeSeconds = 1_800,
		cashFloor = 5_000,
	}),
	BonesLarge = product({
		key = "BonesLarge",
		kind = "WorldCash",
		world = "dino",
		price = 159,
		name = "Crate of Bones",
		description = "2 hours of your Dino Valley income in Bones, instantly.",
		icon = "BonesPack",
		category = "dino",
		order = 3,
		badge = "BEST VALUE",
		incomeSeconds = 7_200,
		cashFloor = 50_000,
	}),
	TimeTravelerPack = product({
		key = "TimeTravelerPack",
		kind = "WorldStarter",
		world = "dino",
		price = 79,
		name = "Time Traveler Pack",
		description = "20 minutes of Dino Valley Bones, the Time Ptero pet and 30 minutes of 2x Cash. Once per player!",
		icon = "TimeTravelerPack",
		category = "dino",
		order = 4,
		oneTime = true,
		badge = "ONE TIME",
		incomeSeconds = 1_200,
		cashFloor = 2_000,
		pet = "time_ptero",
		boostKey = "cash2x",
		boostSeconds = 1_800,
	}),
	-- R70 World 3 "Moon Base" (R69–R71 spec §2.6): the same shape and prices as Dino Valley's
	-- (no new passes). Moon Rocks = profile.worlds.moon.cash; refused at the prompt while Moon Base
	-- is locked. NOT paid random (fixed amounts / a fixed pet), but they make Moon Rocks
	-- Robux-reachable, so Moon eggs bought with Moon Rocks ARE gated
	-- (EggConfig.PaidRandomCurrencies.moonrocks; robuxWorldCurrencies picks this up by itself).
	MoonRocksSmall = product({
		key = "MoonRocksSmall",
		kind = "WorldCash",
		world = "moon",
		price = 23,
		name = "Bag of Moon Rocks",
		description = "10 minutes of your Moon Base income in Moon Rocks, instantly.",
		icon = "MoonRocksPack",
		category = "moon",
		order = 1,
		incomeSeconds = 600,
		cashFloor = 500,
	}),
	MoonRocksMedium = product({
		key = "MoonRocksMedium",
		kind = "WorldCash",
		world = "moon",
		price = 63,
		name = "Sack of Moon Rocks",
		description = "30 minutes of your Moon Base income in Moon Rocks, instantly.",
		icon = "MoonRocksPack",
		category = "moon",
		order = 2,
		badge = "POPULAR",
		incomeSeconds = 1_800,
		cashFloor = 5_000,
	}),
	MoonRocksLarge = product({
		key = "MoonRocksLarge",
		kind = "WorldCash",
		world = "moon",
		price = 159,
		name = "Crate of Moon Rocks",
		description = "2 hours of your Moon Base income in Moon Rocks, instantly.",
		icon = "MoonRocksPack",
		category = "moon",
		order = 3,
		badge = "BEST VALUE",
		incomeSeconds = 7_200,
		cashFloor = 50_000,
	}),
	AstronautPack = product({
		key = "AstronautPack",
		kind = "WorldStarter",
		world = "moon",
		price = 79,
		name = "Astronaut Pack",
		description = "20 minutes of Moon Base Moon Rocks, the Rocket Corgi pet and 30 minutes of 2x Cash. Once per player!",
		icon = "AstronautPack",
		category = "moon",
		order = 4,
		oneTime = true,
		badge = "ONE TIME",
		incomeSeconds = 1_200,
		cashFloor = 2_000,
		pet = "rocket_corgi",
		boostKey = "cash2x",
		boostSeconds = 1_800,
	}),
	-- R78 Nuke Pass (spec §2): one season's premium track. Bought from the NukePass screen / the
	-- HUD "Pass" offer; the prompt is refused outside a season or when already owned (PassService
	-- registers the refusal). Deterministic rewards → NOT paid random (premium spins / eggs are
	-- paid as gems where paid random items are restricted: Server/Pass/PassLogic.premiumReward).
	NukePassPremium = product({
		key = "NukePassPremium",
		kind = "PassPremium",
		price = 159,
		name = "Nuke Pass Premium",
		description = "Unlock this season's premium Nuke Pass track: gems, spins, eggs, a trail, a title and a golden pet!",
		icon = "NukePass",
		category = "pass",
		order = 1,
		badge = "SEASON",
	}),
	-- R89 Pocket Rocket (gift ladder wave §3): the HUD's small daily impulse offer (UI/Hud/HudOffers
	-- shows the live "+$42.4K"). 300 s for 15 R$ = 20 s/R$, under the worst Cash pack (Stack of
	-- Cash 600 s / 23 R$ = 26.1 s/R$); floor 500 / 15 = 33.3 $/R$ under 1,000 / 23 = 43.5 $/R$ —
	-- validate() enforces both. Managed pricing stays OFF for it so the fixed 15 R$ keeps that rule.
	PocketRocket = product({
		key = "PocketRocket",
		kind = "PocketRocket",
		price = 15,
		name = "Pocket Rocket",
		description = "5 minutes of your own income, right now! One rocket per day.",
		icon = "PocketRocket",
		category = "boosts",
		order = 5,
		incomeSeconds = 300,
		cashFloor = 500,
	}),
}
MonetizationConfig.Products = table.freeze(products)

-- Reverse indexes: configured (non-zero) id → definition. Built once; O(1) receipt routing.
local productsById: { [number]: ProductDef } = {}
local passesById: { [number]: PassDef } = {}
for _, def in products do
	if MonetizationConfig.isConfigured(def.id) then
		productsById[def.id] = def
	end
end
for _, def in passes do
	if MonetizationConfig.isConfigured(def.id) then
		passesById[def.id] = def
	end
end

-- Display order lists (UI iterates these; a dictionary has no order).
local function sortedKeys<K, V>(map: { [K]: V }, orderOf: (V) -> number): { K }
	local keys: { K } = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys, function(a: K, b: K): boolean
		local oa, ob = orderOf(map[a]), orderOf(map[b])
		if oa ~= ob then
			return oa < ob
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end
MonetizationConfig.PassOrder = table.freeze(sortedKeys(passes, function(def: PassDef): number
	return def.order
end))
MonetizationConfig.ProductOrder = table.freeze(sortedKeys(products, function(def: ProductDef): number
	return def.order
end))

--[[
	A game pass by key (nil for unknown keys; rawget, so no metatable can fake one).
	Example: MonetizationConfig.getPass("VIP").name --> "VIP"
]]
function MonetizationConfig.getPass(key: string): PassDef?
	return rawget(passes :: any, key)
end

--[[ A developer product by key (nil for unknown keys). ]]
function MonetizationConfig.getProduct(key: string): ProductDef?
	return rawget(products :: any, key)
end

--[[
	A CONFIGURED game pass by its dashboard id (nil for 0 / unknown ids). Used by
	PromptGamePassPurchaseFinished, so an unpublished pass can never match.
]]
function MonetizationConfig.getPassById(id: number): PassDef?
	if not MonetizationConfig.isConfigured(id) then
		return nil
	end
	return passesById[id]
end

--[[
	A CONFIGURED developer product by its dashboard id (nil for 0 / unknown ids). Used by
	ProcessReceipt, so an unconfigured product can never match a real receipt.
]]
function MonetizationConfig.getProductById(id: number): ProductDef?
	if not MonetizationConfig.isConfigured(id) then
		return nil
	end
	return productsById[id]
end

--[[
	Where `now` sits in a product's sale window [saleStarts, saleEnds).
	Example: MonetizationConfig.saleState(MonetizationConfig.Products.AcornsSmall, 0) --> "NotStarted"
]]
function MonetizationConfig.saleState(def: ProductDef, now: number): SaleState
	if def.saleStarts ~= nil and now < def.saleStarts then
		return "NotStarted"
	end
	if def.saleEnds ~= nil and now >= def.saleEnds then
		return "Ended"
	end
	return "OnSale"
end

--[[
	True when a product can be offered at all right now: published (id ≠ 0) and on sale. The
	server adds its own checks on top (a registered handler, one-time flags, paid-random policy).
	UI: false → COMING SOON (unpublished) or hidden (outside its sale window).
]]
function MonetizationConfig.isProductAvailable(key: string, now: number): boolean
	local def = MonetizationConfig.getProduct(key)
	return def ~= nil and MonetizationConfig.isAvailable(def, now)
end

--[[
	The availability rule itself, on a product DEFINITION: published (configured id) and on sale.
	isProductAvailable is this on the catalogue entry; tests use it to prove the guard on
	synthetic unpublished copies now that every catalogue product has a live id.
	Example: MonetizationConfig.isAvailable(table.clone(def) with id = 0, now) --> false
]]
function MonetizationConfig.isAvailable(def: ProductDef, now: number): boolean
	return MonetizationConfig.isConfigured(def.id) and MonetizationConfig.saleState(def, now) == "OnSale"
end

--[[ True when a pass is published (id ≠ 0). UI: false → COMING SOON. ]]
function MonetizationConfig.isPassAvailable(key: string): boolean
	local def = MonetizationConfig.getPass(key)
	return def ~= nil and MonetizationConfig.isConfigured(def.id)
end

-- Kind-specific required fields (validate()).
local REQUIRED_FIELDS: { [string]: { string } } = {
	Cash = { "incomeSeconds", "cashFloor" },
	Gems = { "gems" },
	Spins = { "spins" },
	ServerBoost = { "durationSeconds", "multiplier" },
	Boost = { "durationSeconds", "multiplier", "boostKey" },
	Shield = { "durationSeconds" },
	Barrage = { "nukes" },
	Acorns = { "acorns" },
	Crate = { "crates" },
	WorldCash = { "world", "incomeSeconds", "cashFloor" },
	WorldStarter = { "world", "incomeSeconds", "cashFloor", "pet" },
	PocketRocket = { "incomeSeconds", "cashFloor" },
	RevengeNuke = { "nukes" },
}

-- Required fields that are non-empty strings (every other required field is a positive number).
local STRING_FIELDS: { [string]: boolean } = { boostKey = true, world = true, pet = true }

-- Kinds whose one-time flag MonetizationService can read from the profile (oneTime elsewhere would
-- go unenforced at the prompt, so validate() refuses it).
local ONE_TIME_KINDS: { [string]: boolean } = { StarterPack = true, SecretPack = true, WorldStarter = true }

local KINDS: { [string]: boolean } = {
	Cash = true,
	Gems = true,
	Spins = true,
	StarterPack = true,
	SecretPack = true,
	DoubleOffline = true,
	ServerBoost = true,
	Boost = true,
	SkipPad = true,
	Barrage = true,
	Shield = true,
	Acorns = true,
	TurkeyLure = true,
	Crate = true,
	WorldCash = true,
	WorldStarter = true,
	PassPremium = true,
	PocketRocket = true,
	RevengeNuke = true,
}

local CATEGORIES: { [string]: boolean } = {
	cash = true,
	gems = true,
	spins = true,
	packs = true,
	boosts = true,
	attack = true,
	event = true,
	crates = true,
	dino = true,
	moon = true,
	pass = true,
}

--[[
	R57: the world currency keys Robux can buy (directly or in a bundle): the currency of every
	product's `world` that grants world cash ("WorldCash" / "WorldStarter"). Anything RANDOM bought
	with one of these is a paid random item (EggConfig.PaidRandomCurrencies must say true for it;
	tests/validate.luau cross-checks every egg). Lazily requires the worlds registry (the catalogue
	itself stays dependency-free for the client UI).
	@return a fresh set, e.g. { bones = true }
	Example: MonetizationConfig.robuxWorldCurrencies().bones --> true
]]
function MonetizationConfig.robuxWorldCurrencies(): { [string]: boolean }
	local WorldsConfig = require(script.Parent.Worlds.WorldsConfig)
	local out: { [string]: boolean } = {}
	for _, def in MonetizationConfig.Products do
		if (def.kind == "WorldCash" or def.kind == "WorldStarter") and def.world ~= nil then
			local world = WorldsConfig.get(def.world)
			if world ~= nil then
				out[world.currency.key] = true
			end
		end
	end
	return out
end

--[[
	Checks the whole catalogue: keys match their table keys and PublishedProductIds (both ways),
	ids are whole numbers ≥ 0 and unique across passes + products, prices are whole Robux ≥ 1,
	kinds / categories / icons are known, kind-specific numbers are present and positive, sale
	windows are ordered, texts fit their caps, oneTime only on enforceable kinds, every `world`
	is a known non-main world (R57), a WorldStarter boost names both key and duration.
	@return problems (empty = valid); tests/validate.luau asserts it is empty
]]
function MonetizationConfig.validate(): { string }
	-- Lazy: only validation (tests, boot checks) needs the worlds registry.
	local WorldsConfig = require(script.Parent.Worlds.WorldsConfig)
	local problems: { string } = {}
	local icons: { [string]: boolean } = {}
	for _, icon in MonetizationConfig.IconKeys do
		icons[icon] = true
	end
	local seenIds: { [number]: string } = {}
	local function checkCommon(kind: string, key: string, def: any)
		if def.key ~= key then
			table.insert(problems, `{kind} {key}: key field {tostring(def.key)} differs`)
		end
		local id = def.id
		if type(id) ~= "number" or id < 0 or id % 1 ~= 0 then
			table.insert(problems, `{kind} {key}: bad id {tostring(id)}`)
		elseif id > 0 then
			if seenIds[id] ~= nil then
				table.insert(problems, `{kind} {key}: id {id} also used by {seenIds[id]}`)
			end
			seenIds[id] = key
		end
		if type(def.price) ~= "number" or def.price < 1 or def.price % 1 ~= 0 then
			table.insert(problems, `{kind} {key}: price must be whole Robux >= 1`)
		end
		if type(def.name) ~= "string" or #def.name == 0 or #def.name > MonetizationConfig.MaxNameLength then
			table.insert(problems, `{kind} {key}: name length`)
		end
		if
			type(def.description) ~= "string"
			or #def.description == 0
			or #def.description > MonetizationConfig.MaxDescriptionLength
		then
			table.insert(problems, `{kind} {key}: description length`)
		end
		if not icons[def.icon] then
			table.insert(problems, `{kind} {key}: unknown icon {tostring(def.icon)}`)
		end
		if type(def.order) ~= "number" then
			table.insert(problems, `{kind} {key}: missing order`)
		end
	end
	for key, def in passes do
		checkCommon("pass", key, def)
		for _, perk in def.perks do
			if #perk == 0 or #perk > MonetizationConfig.MaxPerkLength then
				table.insert(problems, `pass {key}: perk length`)
			end
		end
	end
	for key, def in products do
		checkCommon("product", key, def)
		if not KINDS[def.kind] then
			table.insert(problems, `product {key}: unknown kind {tostring(def.kind)}`)
		end
		if not CATEGORIES[def.category] then
			table.insert(problems, `product {key}: unknown category {tostring(def.category)}`)
		end
		for _, field in REQUIRED_FIELDS[def.kind] or {} do
			local value = (def :: any)[field]
			if STRING_FIELDS[field] then
				if type(value) ~= "string" or #value == 0 then
					table.insert(problems, `product {key}: missing {field}`)
				end
			elseif type(value) ~= "number" or value <= 0 or value ~= value then
				table.insert(problems, `product {key}: {field} must be a positive number`)
			end
		end
		if def.saleStarts ~= nil and def.saleEnds ~= nil and def.saleStarts >= def.saleEnds then
			table.insert(problems, `product {key}: saleStarts must be before saleEnds`)
		end
		if def.oneTime and not ONE_TIME_KINDS[def.kind] then
			table.insert(
				problems,
				`product {key}: oneTime is only enforced for StarterPack / SecretPack / WorldStarter`
			)
		end
		-- R57: a world product names a known NON-main world; a WorldStarter boost is all-or-nothing.
		if def.world ~= nil then
			local world = WorldsConfig.get(def.world)
			if world == nil or world.id == WorldsConfig.MAIN then
				table.insert(problems, `product {key}: world {tostring(def.world)} is not a known non-main world`)
			end
		end
		if def.kind == "WorldStarter" and (def.boostKey == nil) ~= (def.boostSeconds == nil) then
			table.insert(problems, `product {key}: boostKey and boostSeconds go together`)
		end
		if def.boostSeconds ~= nil and not (def.boostSeconds > 0 and def.boostSeconds < math.huge) then
			table.insert(problems, `product {key}: boostSeconds must be a positive number`)
		end
	end
	-- R89 price rule: a "PocketRocket" product never beats any "Cash" pack per Robux (income seconds
	-- per R$ and floor per R$; GiftsConfig.rocketBeatsCashPacks is the same rule for the UI / tests).
	for rocketKey, rocket in products do
		if rocket.kind == "PocketRocket" then
			for packKey, pack in products do
				if
					pack.kind == "Cash"
					and (
						(rocket.incomeSeconds or 0) / rocket.price > (pack.incomeSeconds or 0) / pack.price
						or (rocket.cashFloor or 0) / rocket.price > (pack.cashFloor or 0) / pack.price
					)
				then
					table.insert(problems, `product {rocketKey}: better value per Robux than Cash pack {packKey}`)
				end
			end
		end
	end
	-- PublishedProductIds and the catalogue must list exactly the same keys.
	for key in PublishedProductIds.Passes :: any do
		if passes[key] == nil then
			table.insert(problems, `PublishedProductIds.Passes.{key} has no pass definition`)
		end
	end
	for key in PublishedProductIds.Products :: any do
		if products[key] == nil then
			table.insert(problems, `PublishedProductIds.Products.{key} has no product definition`)
		end
	end
	for key in passes do
		if (PublishedProductIds.Passes :: any)[key] == nil then
			table.insert(problems, `pass {key} missing from PublishedProductIds.Passes`)
		end
	end
	for key in products do
		if (PublishedProductIds.Products :: any)[key] == nil then
			table.insert(problems, `product {key} missing from PublishedProductIds.Products`)
		end
	end
	return problems
end

return table.freeze(MonetizationConfig)
