--!strict
--[[
	EggConfig — the eggs (design spec §8): ten area eggs on the hub egg stands (one per area tier,
	priced in CASH from that area's economy), the Harvest Egg (Harvest Feast event, priced in
	ACORNS), the Lucky Egg (never sold: held eggs from the Lucky Wheel, crates and admin), the
	World 2 eggs (owner R57, world2 spec §8): the Dino Egg (Dino area 2) and the Volcano Egg (Dino
	area 5) on the two nest stands at Dino Valley's Base Camp, priced in BONES, and the World 3
	eggs (owner R70, r69 spec §2.5): the Moon Egg (Moon area 2) and the Comet Egg (Moon area 5) on
	the Moon hub's two stands, priced in MOON ROCKS.

	Worlds (world2 spec §18 "add a world = config + art"): every egg has a `world` (WorldsConfig
	id; "main" = Nuke Town). A world egg is priced in that world's currency key
	(WorldsConfig.get(world).currency.key, e.g. "bones"), unlocks with that world's progress
	(profile.worlds[world].unlocked AND worlds[world].tycoon.area >= egg.area — progressOf) and
	stands on that world's hub-layout anchor ("dino:EggStands1" = ValleyLayout.anchors.EggStands[1],
	WORLD-LOCAL, placed with WorldLayout.toWorld — parseStand). WorldDef.eggs lists the same ids;
	validate() keeps both sides in step. Adding World 3's eggs = rows in WORLD_EGGS + the currency's
	PaidRandomCurrencies class.

	Odds (the published odds ARE the rolled odds):
		Every egg has four SLOTS in rarity order, each one pet with a weight in basis points of
		TotalBp (100,000 = 100 %; 100 bp = 0.1 %). Roll = NextInteger(1, TotalBp) walked over the
		cumulative slot weights (Server/Pets/PetLogic.rollSlot).
		  Eggs 1–2  Common 65 % · Uncommon 27 % · Rare 7 %    · Epic 1 %
		  Eggs 3–5  Uncommon 65 % · Rare 27 % · Epic 7.5 %    · Legendary 0.5 %
		  Eggs 6–8  Rare 65 %     · Epic 27 % · Legendary 7.75 % · Mythic 0.25 %
		  Eggs 9–10 Epic 65 %     · Legendary 27 % · Mythic 7.9 % · Secret 0.1 %
	LUCKY EGGS pass (MonetizationConfig "LuckyEggs"): the weights of the egg's `luckySlots` (its two
	rarest) are multiplied by LuckMultiplier (×2) and slot 1 gives up the difference
	(oddsFor(egg, true)); validate() guarantees slot 1 stays positive. Both tables are shown on the
	stand billboard and in the EggHatch screen.
	PITY: `pity = { slot, hatches }` — the `hatches`-th hatch in a row of this egg without a pet of
	slot >= `slot` is re-rolled among those slots, proportional to their (lucky) odds. Counter:
	profile.pets.pity[eggId] (hatches since the last such pet).

	Prices: area egg N costs friendlyPrice(PriceUnits × that area's producer level-1 upgrade cost)
	— the producer's baseCost is 3 × the area's SCALE (a few seconds of arrival income,
	docs/economy.md), so an egg is ≈ 2–5 minutes of income when the area opens and a few seconds
	by its end, and the price follows every pacing retune automatically. Exception: the Garage
	Lab Workbench's first upgrade is pinned to $10 (owner R65), so the Garage Egg is $400 — right
	after the Garage Door, ~2.5 min into a first run. An area egg unlocks when
	the player reaches that area (profile.tycoon.area >= egg.area).

	Stands: `stand` names the HubLayout anchor (B8e): "EggStands1".."EggStands10" →
	HubLayout.EggStands[i], "HarvestEggStand" → HubLayout.HarvestEggStand. Buying at a stand needs
	the character within StandRange studs (server-checked). HELD eggs (profile.pets.eggs) hatch
	anywhere (Pets screen → Eggs tab) and are spent before any money.

	PAID RANDOM ITEMS (Roblox policy; PolicyService ArePaidRandomItemsRestricted = "the player can
	NOT interact with paid random item generators, either via in-experience currency bought with
	Robux or Robux directly"). An egg is a random item generator, so BUYING one with any currency a
	player can get for Robux is a paid random item. Which egg currencies are Robux-reachable
	(audited 2026-10-30 against MonetizationConfig; tests/pets-policy.luau pins every product kind):
		cash    YES  CashSmall/Medium/Large/Huge, StarterPack + SecretPack cash stacks, DoubleOffline,
		             ServerCash2x / Cash2x30 / the DoubleCash pass (income multipliers), SkipPad
		acorns  YES  AcornsSmall / AcornsLarge (+ TurkeyLure: 3x acorns per lured turkey)
		bones   YES  BonesSmall / BonesMedium / BonesLarge (kind WorldCash) + the Time Traveler
		             Pack's Bones (kind WorldStarter), owner R57 World 2
		moonrocks YES MoonRocksSmall / Medium / Large (WorldCash) + the Astronaut Pack (WorldStarter),
		             owner R70 World 3
		held    NO   a held egg was already GRANTED (daily / wheel / codes / group / crate rewards /
		             admin); hatching it costs nothing, so it is never a purchase. Every paid way to
		             obtain one (Robux crates, gem crates, Robux spins) is itself gated when bought.
	So PaidRandomCurrencies gates cash, acorns, bones AND moonrocks. The gate: PetService awaits
	PlayerDataService.resolvePaidRandomAsync (Economy/PolicyCache: FAILS CLOSED — unknown, failed
	or malformed answers count as restricted) on EVERY hatch request that must buy at least one
	egg (needsPolicy), then PetLogic.planHatch refuses "Restricted". Clients mirror it with
	policyState(profile.policy) (stand billboards + EggHatch say "not available in your region";
	odds stay visible everywhere). Held eggs keep hatching for everybody.

	Ids are SAVE DATA (pets.eggs / pets.pity keys). Never rename or reuse one. "lucky_egg" is
	referenced by B7 LuckySpinConfig; "harvest_egg" by B11.

	Connects to: Shared/Config/PetConfig (pets), Shared/Config/TycoonConfig (prices),
	Shared/Config/Worlds/WorldsConfig (world eggs: economy, currency, unlock, hub layout),
	Server/Pets/PetLogic (rolls, pity, luck), Server/Services/PetService (stands, range),
	Server/Pets/EggStands (billboards), Client/Pets/{StandClient, EggView}, UI/Screens/EggHatch,
	tests/pets-logic.luau, tests/pets-policy.luau.

	Example:
		local egg = EggConfig.get("garage_egg")
		print(egg.name, egg.price)                 --> Garage Egg 400
		print(table.concat(EggConfig.oddsFor(egg, true), " ")) --> 57000 27000 14000 2000
]]

local EventConfig = require(script.Parent.EventConfig)
local PetConfig = require(script.Parent.PetConfig)
local TycoonConfig = require(script.Parent.TycoonConfig)
local WorldsConfig = require(script.Parent.Worlds.WorldsConfig)

--[[
	What an egg is paid with: "cash" (Nuke Town), "acorns" (Harvest Feast), "held" (never sold), or
	a world's currency key (WorldsConfig: "bones" for Dino Valley). A plain string so World 3 is a
	config row (spec §18); validate() pins every egg's currency to a known, policy-classified key.
]]
export type Currency = string

export type Slot = { pet: string, bp: number }

export type PityRule = { slot: number, hatches: number }

export type EggDef = {
	id: string,
	name: string,
	order: number,
	world: string, -- WorldsConfig id whose hub sells it and whose progress unlocks it ("main" = Nuke Town)
	area: number, -- `world`'s tycoon area needed (0 = none)
	currency: Currency,
	price: number, -- per egg in `currency` (0 for held-only eggs)
	stand: string?, -- hub-layout anchor name, "<world>:" prefixed outside Nuke Town (nil = held only)
	shell: Color3, -- egg shell colour
	spots: Color3, -- shell spots / glow colour
	model: string, -- MeshAssets key of the egg mesh (B8f eggs.py; pieces ShellTop* / ShellBottom*)
	colors: { [string]: Color3 }?, -- piece colour overrides (nil = the mesh's own colours)
	slots: { Slot }, -- four pets, rarity order (rarest last)
	luckySlots: { number }, -- slot indices the LuckyEggs pass multiplies
	pity: PityRule?,
	window: { starts: number, ends: number }?, -- unix [starts, ends) the egg can be hatched
	blurb: string,
	card: string?, -- StudUI colour preset of its stand billboard (nil = by tier / currency)
}

local EggConfig = {}

-- Basis points of certainty (100,000 = 100 %).
EggConfig.TotalBp = 100_000
-- LuckyEggs pass: the egg's rare slots × this.
EggConfig.LuckMultiplier = 2
EggConfig.LuckPass = "LuckyEggs"
-- Area egg price = friendlyPrice(PriceUnits × area producer baseCost).
EggConfig.PriceUnits = 40
-- Server range check: the character's root must be this close to the stand anchor (studs).
EggConfig.StandRange = 18
-- Held eggs of one id saturate here (PetLogic grants; a stored count outside [0, MaxHeld] or not
-- whole is unusable — see needsPolicy).
EggConfig.MaxHeld = 1_000_000
-- Count rules: 1 always; 3 with the TripleHatch pass; auto-hatch with AutoHatch (client loop).
EggConfig.TriplePass = "TripleHatch"
EggConfig.AutoPass = "AutoHatch"
EggConfig.TripleCount = 3
-- Currencies whose eggs are PAID RANDOM ITEMS (PolicyService gate, fail closed; see the header's
-- audit). Cash, acorns, Bones and Moon Rocks can all be bought with Robux, directly or indirectly, so buying an
-- egg with any of them is gated. Held eggs were already granted: hatching one is never a purchase. Every
-- egg currency MUST appear here (validate() checks it): a missing entry would silently be ungated.
EggConfig.PaidRandomCurrencies = table.freeze({
	cash = true,
	acorns = true,
	bones = true, -- Dino Valley (BonesSmall / Medium / Large + Time Traveler Pack), R57
	moonrocks = true, -- Moon Base (MoonRocksSmall / Medium / Large + Astronaut Pack), R70
	held = false,
}) :: { [string]: boolean }

--[[
	Player-facing texts of the paid-random gate (stand billboards, EggHatch, server refusals), kept
	together so every surface says the same friendly thing.
]]
EggConfig.PolicyText = table.freeze({
	-- Stand billboard price line while the region restricts paid random items.
	Locked = "NOT IN YOUR REGION",
	-- Locked buy-button caption (short: the price line above explains why).
	Button = "UNAVAILABLE",
	-- One line under the price.
	Restricted = "Buying eggs isn't available in your region.",
	-- Encouragement: what still works.
	HeldStillHatch = "Eggs you win still hatch free!",
	-- While the server is still checking (fail closed: the server decides on press).
	Checking = "Checking if eggs are available for you...",
	-- Server refusal: the region restricts paid random items.
	RefusedRestricted = "Buying eggs isn't available in your region. Eggs you win still hatch free!",
	-- Server refusal: PolicyService has not answered yet (fail closed).
	RefusedUnknown = "We couldn't check if eggs are available for you yet. Try again in a moment!",
})
-- Harvest Feast window = B11's EventConfig.Season (2026-11-01 → 2026-12-01 UTC). At runtime the
-- server asks EventService.isActive() first (it includes the owner's admin force on / off).
EggConfig.HarvestStarts = EventConfig.Season.starts
EggConfig.HarvestEnds = EventConfig.Season.ends

-- Slot weights per tier group (see header). Each sums to TotalBp.
local ODDS_LOW = { 65_000, 27_000, 7_000, 1_000 }
local ODDS_MID = { 65_000, 27_000, 7_500, 500 }
local ODDS_HIGH = { 65_000, 27_000, 7_750, 250 }
local ODDS_TOP = { 65_000, 27_000, 7_900, 100 }

type AreaEggRow = {
	id: string,
	name: string,
	area: number,
	model: string, -- B8f egg mesh (MeshAssets)
	pets: { string },
	shell: Color3,
	spots: Color3,
	blurb: string,
}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- The ten area eggs, in area order (pets in slot order).
local AREA_EGGS: { AreaEggRow } = {
	{
		id = "garage_egg",
		name = "Garage Egg",
		area = 1,
		model = "GarageEgg",
		pets = { "glow_slime", "atom_pup", "fission_fox", "rad_raccoon" },
		shell = rgb(150, 220, 110),
		spots = rgb(255, 240, 120),
		blurb = "Warm from the Mini Reactor!",
	},
	{
		id = "stand_egg",
		name = "Nuke Stand Egg",
		area = 2,
		model = "StandEgg",
		pets = { "isotope_kitty", "quark_duck", "reactor_owl", "atomic_axolotl" },
		shell = rgb(255, 170, 200),
		spots = rgb(255, 255, 255),
		blurb = "Fresh from the stand!",
	},
	{
		id = "dash_egg",
		name = "BoomDash Egg",
		area = 3,
		model = "BoomDashEgg",
		pets = { "uranium_bunny", "proton_panda", "cosmic_corgi", "fusion_phoenix" },
		shell = rgb(255, 110, 90),
		spots = rgb(255, 230, 90),
		blurb = "Delivered in 30 seconds or less!",
	},
	{
		id = "mine_egg",
		name = "Glow Rock Egg",
		area = 4,
		model = "MineEgg",
		pets = { "mega_mole", "gamma_gator", "nuclear_narwhal", "meltdown_moose" },
		shell = rgb(90, 110, 100),
		spots = rgb(120, 255, 140),
		blurb = "Dug out of a glowing vein.",
	},
	{
		id = "lab_egg",
		name = "Lab Egg",
		area = 5,
		model = "LabEgg",
		pets = { "neutron_newt", "plasma_pig", "lab_axolotl", "reactor_rex" },
		shell = rgb(240, 248, 255),
		spots = rgb(90, 220, 255),
		blurb = "Science says: CUTE.",
	},
	{
		id = "factory_egg",
		name = "Rocket Factory Egg",
		area = 6,
		model = "FactoryEgg",
		pets = { "forge_fox", "bolt_raccoon", "mech_rex", "core_dragon" },
		shell = rgb(255, 160, 50),
		spots = rgb(70, 76, 90),
		blurb = "Fresh off the conveyor.",
	},
	{
		id = "silo_egg",
		name = "Launch Silo Egg",
		area = 7,
		model = "SiloEgg",
		pets = { "radar_owl", "hazard_corgi", "rocket_phoenix", "nova_unicorn" },
		shell = rgb(255, 214, 40),
		spots = rgb(40, 40, 50),
		blurb = "Handle with hazard stripes.",
	},
	{
		id = "mart_egg",
		name = "Megastore Egg",
		area = 8,
		model = "MegastoreEgg",
		pets = { "mascot_panda", "neon_narwhal", "mascot_moose", "ion_jelly" },
		shell = rgb(90, 160, 255),
		spots = rgb(255, 120, 200),
		blurb = "Today only: extra cute!",
	},
	{
		id = "space_egg",
		name = "Space Port Egg",
		area = 9,
		model = "SpaceEgg",
		pets = { "astro_corgi", "comet_phoenix", "star_unicorn", "void_cat" },
		shell = rgb(60, 50, 120),
		spots = rgb(255, 250, 170),
		blurb = "Hatched in zero gravity.",
	},
	{
		id = "reactor_egg",
		name = "Mega Reactor Egg",
		area = 10,
		model = "MegaEgg",
		pets = { "fusion_axolotl", "plasma_rex", "plasma_dragon", "quark_nukey" },
		shell = rgb(40, 230, 180),
		spots = rgb(255, 120, 230),
		blurb = "Fusion-powered and glowing!",
	},
}

-- Odds group + pity for area egg N.
local function areaOdds(area: number): ({ number }, number)
	if area <= 2 then
		return ODDS_LOW, 150
	elseif area <= 5 then
		return ODDS_MID, 300
	elseif area <= 8 then
		return ODDS_HIGH, 600
	end
	return ODDS_TOP, 1_500
end

-- Freezes a config record and keeps its declared (writable) type for the tables below; the new
-- type solver would otherwise narrow it to a read-only shape.
local function frozen<T>(value: T): T
	return table.freeze(value :: any) :: any
end

-- Builds the four slots of an egg from pet ids + weights.
local function slotsOf(pets: { string }, odds: { number }): { Slot }
	local slots: { Slot } = {}
	for index, petId in pets do
		local slot: Slot = { pet = petId, bp = odds[index] }
		table.insert(slots, frozen(slot))
	end
	return table.freeze(slots)
end

local EGGS: { [string]: EggDef } = {}
local ORDER: { string } = {}

local function add(def: EggDef)
	table.freeze(def.luckySlots)
	if def.pity ~= nil then
		table.freeze(def.pity)
	end
	if def.window ~= nil then
		table.freeze(def.window)
	end
	EGGS[def.id] = frozen(def)
	table.insert(ORDER, def.id)
end

for index, row in AREA_EGGS do
	local odds, pityHatches = areaOdds(row.area)
	local producer = TycoonConfig.Areas[row.area].producer
	add({
		id = row.id,
		name = row.name,
		order = index,
		world = WorldsConfig.MAIN,
		area = row.area,
		currency = "cash",
		price = TycoonConfig.friendlyPrice(EggConfig.PriceUnits * producer.baseCost),
		stand = `EggStands{row.area}`,
		shell = row.shell,
		spots = row.spots,
		model = row.model,
		colors = nil,
		slots = slotsOf(row.pets, odds),
		luckySlots = { 3, 4 },
		pity = { slot = 4, hatches = pityHatches },
		window = nil,
		blurb = row.blurb,
	})
end

add({
	id = "harvest_egg",
	name = "Harvest Egg",
	order = 11,
	world = WorldsConfig.MAIN,
	area = 0,
	currency = "acorns",
	price = 30,
	stand = "HarvestEggStand",
	shell = rgb(240, 140, 50),
	spots = rgb(255, 214, 90),
	model = "HarvestEgg",
	colors = nil,
	slots = slotsOf(
		{ "acorn_squirrel", "harvest_hedgehog", "cranberry_crab", "cornucopia_dragon" },
		{ 60_000, 30_000, 9_000, 1_000 }
	),
	luckySlots = { 3, 4 },
	pity = { slot = 4, hatches = 150 },
	window = { starts = EggConfig.HarvestStarts, ends = EggConfig.HarvestEnds },
	blurb = "Harvest Feast only! Paid with acorns.",
})

add({
	id = "lucky_egg",
	name = "Lucky Egg",
	order = 12,
	world = WorldsConfig.MAIN,
	area = 0,
	currency = "held",
	price = 0,
	stand = nil,
	shell = rgb(90, 220, 110),
	spots = rgb(255, 230, 90),
	-- No dedicated mesh: the Garage Egg recoloured lucky green.
	model = "GarageEgg",
	colors = table.freeze({ ShellBottom = rgb(90, 220, 110), ShellTop = rgb(90, 220, 110) }) :: { [string]: Color3 },
	slots = slotsOf({ "clover_slime", "lucky_bunny", "lucky_fox", "rainbow_jelly" }, { 70_000, 25_000, 4_500, 500 }),
	luckySlots = { 3, 4 },
	pity = { slot = 4, hatches = 100 },
	window = nil,
	blurb = "Won from the Lucky Wheel and crates. Hatch it anywhere!",
})

--[[
	World eggs (owner R57 World 2, world2 spec §8): sold on a world's own hub stands, priced in the
	world's currency from that world's economy, unlocked by that world's progress. `stand` is the
	1-based index into the world hub layout's anchors.EggStands (Dino: ValleyLayout, two nest
	stands). Odds groups follow the main eggs of the same tier band (Dino Egg = eggs 3–5,
	Volcano Egg = eggs 6–8).
]]
type WorldEggRow = {
	id: string,
	name: string,
	world: string,
	area: number,
	stand: number,
	model: string, -- W11 egg mesh (tools/blender/models/eggs_dino.py / eggs_moon.py)
	pets: { string },
	odds: { number },
	pity: number,
	shell: Color3,
	spots: Color3,
	blurb: string,
	card: string, -- stand billboard colour preset (StudUI)
}

local WORLD_EGGS: { WorldEggRow } = {
	{
		id = "dino_egg",
		name = "Dino Egg",
		world = "dino",
		area = 2,
		stand = 1,
		model = "DinoEgg",
		pets = { "atom_raptor", "glow_stego", "fission_trike", "pocket_bronto" },
		odds = ODDS_MID,
		pity = 300,
		shell = rgb(126, 228, 52),
		spots = rgb(255, 218, 52),
		blurb = "Still warm from the fern nest!",
		card = "green",
	},
	{
		id = "volcano_egg",
		name = "Volcano Egg",
		world = "dino",
		area = 5,
		stand = 2,
		model = "VolcanoEgg",
		pets = { "ember_ankylo", "magma_ptero", "lava_para", "supernova_spino" },
		odds = ODDS_HIGH,
		pity = 600,
		shell = rgb(242, 82, 36),
		spots = rgb(255, 204, 48),
		blurb = "Toasty from the jelly-lava volcano!",
		card = "red",
	},
	-- World 3 "Moon Base" (owner R70, spec r69 §2.5): Moon Egg = the Dino Egg's slot / odds tier at
	-- Moon area 2 (Cosmic Diner), Comet Egg = the Volcano Egg's at Moon area 5 (Star Lab).
	{
		id = "moon_egg",
		name = "Moon Egg",
		world = "moon",
		area = 2,
		stand = 1,
		model = "MoonEgg",
		pets = { "astro_pup", "moon_bunny", "orbit_owl", "cosmo_cat" },
		odds = ODDS_MID,
		pity = 300,
		shell = rgb(196, 170, 255),
		spots = rgb(255, 222, 56),
		blurb = "Found in a crater, still twinkling!",
		card = "purple",
	},
	{
		id = "comet_egg",
		name = "Comet Egg",
		world = "moon",
		area = 5,
		stand = 2,
		model = "CometEgg",
		pets = { "comet_fox", "saucer_octo", "galaxy_whale", "starlight_unicorn" },
		odds = ODDS_HIGH,
		pity = 600,
		shell = rgb(64, 110, 255),
		spots = rgb(100, 232, 255),
		blurb = "Caught by the Comet Catcher!",
		card = "blue",
	},
}

for _, row in WORLD_EGGS do
	local world = WorldsConfig.get(row.world)
	assert(world ~= nil, `EggConfig: {row.id} names unknown world {row.world}`)
	local areaDef = world.economy.Areas[row.area]
	assert(areaDef ~= nil, `EggConfig: {row.id} area {row.area} is not in {row.world}`)
	add({
		id = row.id,
		name = row.name,
		order = #ORDER + 1,
		world = row.world,
		area = row.area,
		currency = world.currency.key,
		price = TycoonConfig.friendlyPrice(EggConfig.PriceUnits * areaDef.producer.baseCost),
		stand = `{row.world}:EggStands{row.stand}`,
		shell = row.shell,
		spots = row.spots,
		model = row.model,
		colors = nil,
		slots = slotsOf(row.pets, row.odds),
		luckySlots = { 3, 4 },
		pity = { slot = 4, hatches = row.pity },
		window = nil,
		blurb = row.blurb,
		card = row.card,
	})
end

EggConfig.Eggs = table.freeze(EGGS)
EggConfig.Order = table.freeze(ORDER)

-- Stand anchor name → egg id (PetService / EggStands build one stand per entry).
local BY_STAND: { [string]: string } = {}
for _, id in ORDER do
	local stand = EGGS[id].stand
	if stand ~= nil then
		BY_STAND[stand] = id
	end
end
EggConfig.ByStand = table.freeze(BY_STAND)

--------------------------------------------------------------------------------------------------
-- Lookups and odds (pure)
--------------------------------------------------------------------------------------------------

--[[ The egg with id `id` (nil for unknown / non-string ids). ]]
function EggConfig.get(id: unknown): EggDef?
	if type(id) ~= "string" then
		return nil
	end
	return rawget(EGGS :: any, id)
end

--[[
	Splits a stand name into (worldId, anchor list, index). Nuke Town names carry no prefix; other
	worlds' stands are "<world>:<name>". A trailing number is the 1-based index into that list.
	Server EggStands and the tests use it to find the hub-layout anchor of a stand.
	Example:
		EggConfig.parseStand("EggStands3")       --> "main", "EggStands", 3
		EggConfig.parseStand("dino:EggStands1")  --> "dino", "EggStands", 1
		EggConfig.parseStand("HarvestEggStand")  --> "main", "HarvestEggStand", nil
]]
function EggConfig.parseStand(stand: unknown): (string?, string?, number?)
	if type(stand) ~= "string" or #stand == 0 or #stand > 64 then
		return nil, nil, nil
	end
	local worldId, name = string.match(stand, "^([%l][%l%d]*):(.+)$")
	if worldId == nil then
		worldId, name = WorldsConfig.MAIN, stand
	end
	local list, digits = string.match(name :: string, "^(%a+)(%d+)$")
	if list ~= nil then
		return worldId, list, tonumber(digits)
	end
	if string.match(name :: string, "^%a+$") == nil then
		return nil, nil, nil
	end
	return worldId, name, nil
end

--[[
	Where a player stands in the egg's world, read from a profile (the server's profile and the
	client's snapshot share this shape: Nuke Town = profile.tycoon, another world =
	profile.worlds[world] { unlocked, tycoon { area } }). Tolerates missing / malformed fields.
	@return worldOpen  Nuke Town always; another world only when its sticky unlock is true
	@return area       that world's highest unlocked tycoon area (1 when unknown; 0 when closed)
	Example:
		EggConfig.progressOf(profile, EggConfig.get("garage_egg")) --> true, profile.tycoon.area
		EggConfig.progressOf(profile, EggConfig.get("dino_egg"))   --> false, 0 (Dino still locked)
]]
function EggConfig.progressOf(profile: unknown, egg: EggDef): (boolean, number)
	local data: any = if type(profile) == "table" then profile else {}
	local tycoon: any
	if egg.world == WorldsConfig.MAIN then
		tycoon = data.tycoon
	else
		local worlds = data.worlds
		local world: any = if type(worlds) == "table" then rawget(worlds, egg.world) else nil
		if type(world) ~= "table" or world.unlocked ~= true then
			return false, 0
		end
		tycoon = world.tycoon
	end
	local area = if type(tycoon) == "table" then tycoon.area else nil
	if type(area) ~= "number" or area ~= area or area < 1 or area == math.huge then
		return true, 1
	end
	return true, math.floor(area)
end

--[[
	True when the player may hatch / buy `egg` as far as world + area progress go (the server's
	"Locked" refusal; the UI's lock state). Windows, money and policy are checked elsewhere.
	Example: EggConfig.isUnlocked(profile, EggConfig.get("volcano_egg")) --> false until Dino area 5
]]
function EggConfig.isUnlocked(profile: unknown, egg: EggDef): boolean
	local open, area = EggConfig.progressOf(profile, egg)
	return open and (egg.area <= 0 or area >= egg.area)
end

--[[
	Display name of the area an egg needs, in the egg's own world ("Fern Market", "BoomDash
	Delivery"); "Area N" when unknown.
	Example: EggConfig.areaName(EggConfig.get("volcano_egg")) --> "Fossil Lab"
]]
function EggConfig.areaName(egg: EggDef): string
	local world = WorldsConfig.get(egg.world)
	local def = if world ~= nil then world.economy.Areas[egg.area] else nil
	return if def ~= nil then def.name else `Area {egg.area}`
end

--[[ The egg's world display name ("Nuke Town", "Dino Valley"). ]]
function EggConfig.worldName(egg: EggDef): string
	local world = WorldsConfig.get(egg.world)
	return if world ~= nil then world.name else egg.world
end

--[[
	Player-facing name of an egg's currency ("Cash", "Acorns", "Bones"; "" for held-only eggs).
	Example: EggConfig.currencyName(EggConfig.get("dino_egg")) --> "Bones"
]]
function EggConfig.currencyName(egg: EggDef): string
	if egg.currency == "cash" then
		return "Cash"
	elseif egg.currency == "acorns" then
		return "Acorns"
	elseif egg.currency == "held" then
		return ""
	end
	local worldId = WorldsConfig.worldOfCurrency(egg.currency)
	local world = if worldId ~= nil then WorldsConfig.get(worldId) else nil
	return if world ~= nil and world.currency.key == egg.currency then world.currency.name else egg.currency
end

--[[
	The slot weights (bp) of `egg`, with the LuckyEggs boost when `lucky`.
	Example: EggConfig.oddsFor(EggConfig.get("garage_egg"), false) --> { 65000, 27000, 7000, 1000 }
]]
function EggConfig.oddsFor(egg: EggDef, lucky: boolean): { number }
	local odds: { number } = {}
	local boosted = 0
	for index, slot in egg.slots do
		local bp = slot.bp
		if lucky and table.find(egg.luckySlots, index) ~= nil then
			local extra = bp * (EggConfig.LuckMultiplier - 1)
			bp += extra
			boosted += extra
		end
		odds[index] = bp
	end
	-- Slot 1 gives up exactly what the lucky slots gained (validate keeps it > 0).
	odds[1] -= boosted
	return odds
end

--[[
	"65%", "0.25%", "0.1%" — a basis-point weight as a short percentage.
	Example: EggConfig.formatChance(250) --> "0.25%"
]]
function EggConfig.formatChance(bp: number): string
	local percent = bp / EggConfig.TotalBp * 100
	if percent >= 10 then
		return `{math.floor(percent * 10 + 0.5) / 10}%`
	elseif percent >= 1 then
		return `{math.floor(percent * 100 + 0.5) / 100}%`
	end
	return `{math.floor(percent * 1000 + 0.5) / 1000}%`
end

--[[
	True when hatching `count` of `egg` while holding `held` of them must BUY at least one egg with
	a gated currency (PaidRandomCurrencies) — i.e. the request is a paid random item and the
	player's PolicyService answer decides. Held eggs pay first (PetLogic.planHatch), so a hatch
	fully covered by held eggs never needs the policy. A held count that is not a whole number in
	[0, MaxHeld] counts as "nothing held" — exactly the rule planHatch uses, so the server's
	"must I check the policy?" answer can never disagree with what the hatch then buys (fail
	closed). Shared by the server (PetService: whether to await the policy; PetLogic: the refusal)
	and the client (whether to show the region state).
	Example:
		EggConfig.needsPolicy(EggConfig.get("garage_egg"), 0, 1) --> true  (cash egg, bought)
		EggConfig.needsPolicy(EggConfig.get("garage_egg"), 3, 3) --> false (all held)
		EggConfig.needsPolicy(EggConfig.get("lucky_egg"), 0, 1)  --> false (held-only egg)
]]
function EggConfig.needsPolicy(egg: EggDef, held: number, count: number): boolean
	if EggConfig.PaidRandomCurrencies[egg.currency] ~= true then
		return false
	end
	-- NaN / fractions / negatives / > MaxHeld / non-numbers are unusable: treated as no held eggs.
	local usable = if type(held) == "number"
			and held == held
			and held % 1 == 0
			and held >= 0
			and held <= EggConfig.MaxHeld
		then held
		else 0
	return count > usable
end

export type PolicyState = "allowed" | "restricted" | "checking"

--[[
	Reads the profile snapshot's `policy = { paidRandomRestricted, known }` (PlayerDataService) into
	a UI state. Only an explicit KNOWN + unrestricted answer is "allowed"; a known restriction is
	"restricted"; anything else (missing, malformed, not known yet, lookup failed) is "checking".
	The client never decides — the server re-checks every request and fails closed — but the UI
	uses this to lock buttons ("restricted") or to say it is still checking.
	Example:
		EggConfig.policyState({ known = true, paidRandomRestricted = false }) --> "allowed"
		EggConfig.policyState({ known = true, paidRandomRestricted = true })  --> "restricted"
		EggConfig.policyState(nil)                                            --> "checking"
]]
function EggConfig.policyState(policy: unknown): PolicyState
	if type(policy) ~= "table" then
		return "checking"
	end
	local info = policy :: { [string]: unknown }
	if info.known ~= true then
		return "checking"
	end
	if info.paidRandomRestricted == false then
		return "allowed"
	end
	-- Known but anything other than an explicit false (true, or a malformed value) is restricted.
	return "restricted"
end

--[[ True when `egg` can be hatched at unix time `now` (its window, if any). ]]
function EggConfig.isOpen(egg: EggDef, now: number): boolean
	local window = egg.window
	if window == nil then
		return true
	end
	return now >= window.starts and now < window.ends
end

--[[
	Hatches left until the pity guarantee after `counter` hatches without it (nil = no rule).
	Example: EggConfig.pityLeft(garage, 149) --> 1 (the next hatch is guaranteed)
]]
function EggConfig.pityLeft(egg: EggDef, counter: number): number?
	local rule = egg.pity
	if rule == nil then
		return nil
	end
	return math.max(1, rule.hatches - math.max(0, counter))
end

--[[
	Checks every egg: four known pets in non-decreasing rarity, weights positive and summing to
	TotalBp, lucky odds keep slot 1 positive, pity slots valid, prices positive for sold eggs,
	stands unique. @return problems (empty = valid)
]]
function EggConfig.validate(): { string }
	local problems: { string } = {}
	for _, id in ORDER do
		local egg = EGGS[id]
		if not string.match(id, "^[a-z][a-z0-9_]*$") then
			table.insert(problems, `egg {id}: id must be snake_case`)
		end
		if #egg.slots ~= 4 then
			table.insert(problems, `egg {id}: needs exactly 4 slots`)
		end
		local total = 0
		local lastRank = 0
		local lastCash = 0
		for index, slot in egg.slots do
			local pet = PetConfig.get(slot.pet)
			if pet == nil then
				table.insert(problems, `egg {id}: slot {index} unknown pet {slot.pet}`)
			else
				local rank = PetConfig.rank(pet.rarity)
				if rank < lastRank then
					table.insert(problems, `egg {id}: slot {index} rarity goes down`)
				end
				if pet.cash <= lastCash then
					table.insert(problems, `egg {id}: slot {index} bonus must beat slot {index - 1}`)
				end
				lastRank, lastCash = rank, pet.cash
			end
			if slot.bp <= 0 or slot.bp % 1 ~= 0 then
				table.insert(problems, `egg {id}: slot {index} weight must be a positive whole bp`)
			end
			total += slot.bp
		end
		if total ~= EggConfig.TotalBp then
			table.insert(problems, `egg {id}: weights sum to {total}, not {EggConfig.TotalBp}`)
		end
		local lucky = EggConfig.oddsFor(egg, true)
		local luckyTotal = 0
		for _, bp in lucky do
			luckyTotal += bp
		end
		if lucky[1] <= 0 or luckyTotal ~= EggConfig.TotalBp then
			table.insert(problems, `egg {id}: lucky odds invalid (slot 1 {lucky[1]}, total {luckyTotal})`)
		end
		if egg.pity ~= nil and (egg.pity.slot < 2 or egg.pity.slot > #egg.slots or egg.pity.hatches < 2) then
			table.insert(problems, `egg {id}: bad pity rule`)
		end
		if egg.currency ~= "held" and not (egg.price > 0) then
			table.insert(problems, `egg {id}: sold eggs need a positive price`)
		end
		if egg.currency == "cash" and (egg.area < 1 or egg.area > #TycoonConfig.Areas) then
			table.insert(problems, `egg {id}: cash eggs need a valid area`)
		end
		if egg.currency ~= "held" and egg.stand == nil then
			table.insert(problems, `egg {id}: sold eggs need a stand`)
		end
		-- Worlds (spec §18): the egg's world exists, its area is inside that world's economy, a
		-- world egg pays in that world's own currency, and its stand names that world.
		local world = WorldsConfig.get(egg.world)
		if world == nil then
			table.insert(problems, `egg {id}: unknown world {egg.world}`)
		else
			if egg.area < 0 or egg.area % 1 ~= 0 or egg.area > #world.economy.Areas then
				table.insert(problems, `egg {id}: area {egg.area} is not an area of {egg.world}`)
			end
			if egg.world ~= WorldsConfig.MAIN then
				if egg.currency ~= world.currency.key and egg.currency ~= "held" then
					table.insert(problems, `egg {id}: a {egg.world} egg must cost {world.currency.key}`)
				end
				if egg.area < 1 then
					table.insert(problems, `egg {id}: world eggs need an area of their world`)
				end
				if table.find(world.eggs, id) == nil then
					table.insert(problems, `egg {id}: missing from WorldsConfig {egg.world}.eggs`)
				end
			elseif WorldsConfig.worldOfCurrency(egg.currency) ~= nil and egg.currency ~= "cash" then
				table.insert(problems, `egg {id}: a Nuke Town egg cannot cost another world's currency`)
			end
			if egg.stand ~= nil then
				local standWorld, list = EggConfig.parseStand(egg.stand)
				if standWorld ~= egg.world or list == nil then
					table.insert(problems, `egg {id}: stand {egg.stand} must name a {egg.world} anchor`)
				end
			end
		end
		-- Every currency must be classified for the paid-random gate (a gap = an ungated egg).
		if type(EggConfig.PaidRandomCurrencies[egg.currency]) ~= "boolean" then
			table.insert(problems, `egg {id}: currency {egg.currency} missing from PaidRandomCurrencies`)
		end
	end
	-- The other direction: every egg a WorldDef sells exists here and belongs to that world.
	for _, worldId in WorldsConfig.Order do
		local world = WorldsConfig.get(worldId)
		for _, eggId in if world ~= nil then world.eggs else {} do
			local egg = EGGS[eggId]
			if egg == nil then
				table.insert(problems, `world {worldId}: sells unknown egg {eggId}`)
			elseif egg.world ~= worldId then
				table.insert(problems, `world {worldId}: egg {eggId} belongs to {egg.world}`)
			end
		end
	end
	-- One egg per stand anchor (ByStand would silently drop a duplicate).
	local seenStands: { [string]: string } = {}
	for _, id in ORDER do
		local stand = EGGS[id].stand
		if stand ~= nil then
			if seenStands[stand] ~= nil then
				table.insert(problems, `egg {id}: stand {stand} also used by {seenStands[stand]}`)
			end
			seenStands[stand] = id
		end
	end
	return problems
end

return table.freeze(EggConfig)
