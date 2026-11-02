--!strict
--[[
	ShopConfig — the Shop screen layout, the contents of the two packs and the Secret Pack's
	global limited stock (design spec §6 / §11, reference docs/reference/ui-style/02-shop-limited-
	time.png: a "- LIMITED TIME -" section with the red Starter Pack and the silver Secret Pack
	("Limited Stock"), then the other sections).

	Prices, names, descriptions and ids come from MonetizationConfig (never duplicated here);
	this module only says WHERE each item shows and WHAT the packs contain.

	Secret Pack stock (ShopService): a cross-server DataStore counter
	(Stock.StoreName / Stock.Key, "<name>_Studio" in Studio) incremented once per PurchaseId
	(idempotent), refreshed every Stock.RefreshSeconds and after each local sale, and replicated
	as ReplicatedStorage attributes SecretPackSold / SecretPackLimit / SecretPackAt (0 = not read
	yet: the card shows "Stock updating..."). The prompt is refused when sold out; a receipt that
	still arrives is always granted (the player paid).

	Paid random items: the packs' Lucky Spins are paid random items. Where the region restricts
	them — or the policy is still unknown at the receipt (fail closed) — the server pays each spin
	as LuckySpinConfig.GemsPerSpin gems instead (Server/Retention/RewardLogic.robuxReward), and
	the pack card shows packLines(pack, true): the spins tile reads "<n> Gems".

	World sections (owner R57 World 2, spec §9 / §14): `WorldSections` are Shop sections that
	belong to a non-main world (Dino Valley's "Pile / Sack / Crate of Bones" + the one-time
	"Time Traveler Pack"; Moon Base's "Bag / Sack / Crate of Moon Rocks" + the "Astronaut Pack"). They are kept OUT of `Sections` on purpose: `Sections` is the fixed list
	ChangeNotesConfig.ShopTabs mirrors (tests/change-notes.luau) and every one of its items is
	always shown, while a world section is:
		* hidden until that world is unlocked for the player AND not closed by the admin kill
		  switch (Client/Worlds/WorldClient.isUnlocked / isEnabled; the server refuses the prompt
		  for a locked world anyway),
		* built lazily the first time it shows (its 3D models never load for players without the
		  world),
		* placed right after the `Sections` entry named by `after`,
		* headed by the world's TAB style (WorldClientConfig.Tabs[world]: label, icon, colour),
		* preselected when the Shop opens while the player is in that world.
	Each item row names the IconAssets fallback icon and the R39 shop-prop mesh (MeshAssets key,
	Shop/ShopModels maps it); a missing mesh keeps the icon. A one-time world bundle
	("WorldStarter") disappears once bought (profile.worlds.<world>.starter.bought).

	Example:
		for _, section in ShopConfig.Sections do print(section.title, #section.items) end
		for _, section in ShopConfig.WorldSections do print(section.id, section.world, section.after) end
]]

local LuckySpinConfig = require(script.Parent.LuckySpinConfig)
local RetentionConfig = require(script.Parent.RetentionConfig)

export type ItemRef = { kind: "product" | "pass", key: string }
export type Section = {
	id: string,
	title: string,
	color: string, -- StudUI colour preset of the section's cards
	items: { ItemRef },
}

-- One developer product of a world section (R57): the product key (MonetizationConfig), its
-- IconAssets fallback icon (shown while the 3D model loads / when the mesh is missing) and the
-- R39 shop-prop mesh (MeshAssets key, rendered by Widgets/ModelViewport through Shop/ShopModels).
export type WorldItemRef = { kind: "product", key: string, icon: string, model: string }

-- A world's Shop section (R57; see the module header). Title / icon / colour come from the
-- world's tab style (WorldClientConfig.Tabs[world]), so every world surface reads alike.
export type WorldSection = {
	id: string, -- section id (Shop open args { section = id }, the LB / RB stop)
	world: string, -- WorldsConfig id: shown only while unlocked + enabled for the player
	after: string, -- the `Sections` id this section follows (unknown -> after the last one)
	items: { WorldItemRef },
}

local ShopConfig = {}

local function product(key: string): ItemRef
	return table.freeze({ kind = "product" :: "product", key = key }) :: any
end
local function pass(key: string): ItemRef
	return table.freeze({ kind = "pass" :: "pass", key = key }) :: any
end

local SECTIONS: { Section } = {
	{
		id = "limited",
		title = "- LIMITED TIME -",
		color = "red",
		items = { product("StarterPack"), product("SecretPack") },
	},
	{
		id = "passes",
		title = "GAMEPASSES",
		color = "purple",
		items = {
			pass("VIP"),
			pass("DoubleCash"),
			pass("AutoClicker"),
			pass("OfflineMax"),
			pass("FastWalk"),
			pass("Teleporter"),
			pass("LuckyEggs"),
			pass("PetSlots"),
			pass("TripleHatch"),
			pass("AutoHatch"),
			pass("MegaLauncher"),
		},
	},
	{
		id = "cash",
		title = "CASH",
		color = "green",
		items = { product("CashSmall"), product("CashMedium"), product("CashLarge"), product("CashHuge") },
	},
	{
		id = "gems",
		title = "GEMS",
		color = "blue",
		items = { product("GemsSmall"), product("GemsMedium"), product("GemsLarge") },
	},
	{
		id = "spins",
		title = "LUCKY SPINS",
		color = "rainbow",
		items = { product("Spins2"), product("Spins5"), product("Spins10") },
	},
	{
		id = "boosts",
		title = "BOOSTS",
		color = "orange",
		items = { product("Cash2x30"), product("ServerCash2x"), product("SkipPad") },
	},
}
for _, section in SECTIONS do
	table.freeze(section.items)
	table.freeze(section)
end
ShopConfig.Sections = table.freeze(SECTIONS)

--[[
	A frozen world-section item row (see WorldItemRef).
	@param key   MonetizationConfig product key (a product with `world` set)
	@param icon  IconAssets key of the fallback icon
	@param model MeshAssets key of the R39 shop prop
	Example: worldProduct("BonesSmall", "BonesPackSmall", "Shop_BonesSmall")
]]
local function worldProduct(key: string, icon: string, model: string): WorldItemRef
	return table.freeze({ kind = "product" :: "product", key = key, icon = icon, model = model }) :: any
end

-- R57 world sections (spec §9 / §14), in display order. Dino Valley follows LIMITED TIME so a
-- player who just unlocked the Valley sees it near the top; in the Valley the Shop opens on it.
local WORLD_SECTIONS: { WorldSection } = {
	{
		id = "dino",
		world = "dino",
		after = "limited",
		items = {
			-- Bones packs (kind "WorldCash"): Pile / Sack / Crate of Bones, bigger heaps per tier.
			worldProduct("BonesSmall", "BonesPackSmall", "Shop_BonesSmall"),
			worldProduct("BonesMedium", "BonesPack", "Shop_BonesMedium"),
			worldProduct("BonesLarge", "BonesPackLarge", "Shop_BonesLarge"),
			-- One-time bundle (kind "WorldStarter"): hidden once worlds.dino.starter.bought.
			worldProduct("TimeTravelerPack", "TimeTravelerPack", "Shop_TimeTravelerPack"),
		},
	},
	-- R70 World 3 MOON BASE (R69–R71 spec §2.6): also anchored after LIMITED TIME, so it sits right
	-- under DINO VALLEY (world sections sharing an anchor keep this list's order); in Moon Base the
	-- Shop opens on it. Props Shop_MoonRocks* / Shop_AstronautPack are W1b's Blender models (the
	-- icon shows until a model is in MeshAssets).
	{
		id = "moon",
		world = "moon",
		after = "limited",
		items = {
			-- Moon Rocks packs (kind "WorldCash"): Bag / Sack / Crate of Moon Rocks.
			worldProduct("MoonRocksSmall", "MoonRocksPackSmall", "Shop_MoonRocksSmall"),
			worldProduct("MoonRocksMedium", "MoonRocksPack", "Shop_MoonRocksMedium"),
			worldProduct("MoonRocksLarge", "MoonRocksPackLarge", "Shop_MoonRocksLarge"),
			-- One-time bundle (kind "WorldStarter"): hidden once worlds.moon.starter.bought.
			worldProduct("AstronautPack", "AstronautPack", "Shop_AstronautPack"),
		},
	},
}
for _, section in WORLD_SECTIONS do
	table.freeze(section.items)
	table.freeze(section)
end
ShopConfig.WorldSections = table.freeze(WORLD_SECTIONS)

-- Starter Pack contents (one time per player; profile.starter.bought).
ShopConfig.StarterPack = table.freeze({
	reward = table.freeze({
		cashSeconds = 3_600,
		cashFloor = 50_000,
		gems = 100,
		spins = 5,
		boost = table.freeze({ key = "cash2x", seconds = 1_800 }),
		pet = "starter_atom_pup",
		fallbackGems = 40,
	}) :: RetentionConfig.Reward,
	-- Card lines (the reference shows two item tiles).
	lines = table.freeze({ "Big cash stack", "100 Gems", "5 Lucky Spins", "30 min 2x Cash", "Golden Atom Pup pet" }),
	spinLine = 3, -- the lines entry that shows the spins (swapped for gems where restricted)
})

-- Secret Pack contents (one time per player; profile.secretPack.bought) + global stock.
ShopConfig.SecretPack = table.freeze({
	reward = table.freeze({
		cashSeconds = 7_200,
		cashFloor = 250_000,
		gems = 500,
		spins = 10,
		boost = table.freeze({ key = "cash2x", seconds = 3_600 }),
		pet = "secret_golden_nuke",
		fallbackGems = 150,
	}) :: RetentionConfig.Reward,
	lines = table.freeze({ "Huge cash stack", "500 Gems", "10 Lucky Spins", "1 h 2x Cash", "Golden Nuke pet" }),
	spinLine = 3, -- the lines entry that shows the spins (swapped for gems where restricted)
})

ShopConfig.Stock = table.freeze({
	Limit = 500, -- Secret Packs sold across ALL servers, ever
	StoreName = "SellNukesStock_v1",
	Key = "SecretPack",
	RefreshSeconds = 60,
	-- Attribute names on ReplicatedStorage.
	SoldAttribute = "SecretPackSold",
	LimitAttribute = "SecretPackLimit",
	AtAttribute = "SecretPackAt",
})

-- HUD right-side starburst offers (spec §6), in rotation order.
ShopConfig.Offers = table.freeze({
	product("StarterPack"),
	pass("DoubleCash"),
	pass("VIP"),
	product("Spins5"),
	pass("Teleporter"),
	product("SecretPack"),
})

--[[
	The item lines a pack card shows. With `spinsAsGems` (the region restricts paid random items, or
	the policy is still unknown — exactly when the server pays the spins as gems) the spins line
	becomes "<spins × GemsPerSpin> Gems"; otherwise the configured lines.
	Example: ShopConfig.packLines(ShopConfig.StarterPack, true)[3] --> "200 Gems"
]]
function ShopConfig.packLines(
	pack: { reward: RetentionConfig.Reward, lines: { string }, spinLine: number? },
	spinsAsGems: boolean
): { string }
	local lines = table.clone(pack.lines)
	local spins = pack.reward.spins
	if spinsAsGems and pack.spinLine ~= nil and spins ~= nil and spins > 0 then
		lines[pack.spinLine] = `{math.floor(spins) * LuckySpinConfig.GemsPerSpin} Gems`
	end
	return lines
end

return table.freeze(ShopConfig)
