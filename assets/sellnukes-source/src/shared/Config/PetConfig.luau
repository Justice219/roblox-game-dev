--!strict
--[[
	PetConfig — every SellNukes pet (design spec §8): the seven rarities, the roster (57 cute
	radioactive critters + 9 World 2 Dino Valley dinos + 9 World 3 Moon Base space pets + the R78
	Golden Nukey = 76), each pet's cash bonus, its model,
	equip-slot rules, the inventory cap and the client follow / server tunables.

	Exclusive pets (owner R78, spec 2026-10-31-r78 §5; the Pet Index rewards, PetIndexConfig):
		`exclusive = true` marks a pet that free, always-available play can NOT reach — Robux packs
		(Starter / Secret / Time Traveler / Astronaut), the Nuke Pass (Golden Nukey) and limited
		events (Harvest Feast egg + sticker sheet). The Index "all discovered" milestone counts only
		the NON-exclusive pets (PetIndexConfig.Total); an exclusive pet the player has owned still
		adds to the discovered count (a bonus toward "all"), so nobody has to pay or to have played
		during an event to finish the Index. validate() keeps every pass / pack / starter / secret /
		event pet exclusive, so a later paid pet can never make "all" pay-gated.
	`how` (optional) overrides the Index "how to get it" line of a single pet (else the source's
	line in UI/Screens/Pets/PetsScreen SOURCE_TEXT): Golden Nukey "Nuke Pass Season 1 - Premium
	tier 30!", Rocket Corgi "Astronaut Pack" (the "pack" line names the Time Traveler Pack).

	Purpose:
		One frozen table that the server (Pets/PetLogic, PetService, CrateLogic, PetGrants) and the
		client (Pets/PetController, PetModels, Screens/Pets, Screens/EggHatch, Screens/CrateOpen)
		read, so a pet's name, rarity and bonus are never duplicated.

	Pets and bonuses:
		Every pet gives `cash` = a fraction added to the player's cash multiplier while EQUIPPED
		(0.12 = +12 %). Equipped bonuses are summed into TycoonTypes.Modifiers.petCash, which the
		tycoon resolves as `(1 + petCash)` (Shared/Tycoon/Modifiers). A pet's bonus is derived from
		its rarity and its tier (1..10 ≈ the area egg it hatches from):
			cash = round(RarityBase[rarity] × TierGrowth^(tier - 1), whole percent)
		so later eggs give stronger pets and, inside one egg, rarer is always stronger
		(validate() checks both). Pets are kept through rebirth (spec §2.5), which makes the next
		run faster — the rebirth power fantasy.

	Models:
		`model` is one of B8f's 29 species meshes (tools/blender/models/pets.py → MeshAssets) or one of
		W11's 9 Dino Valley meshes (tools/blender/models/pets_dino.py; owner R57 World 2) or 9 Moon Base
		meshes (tools/blender/models/pets_moon.py; owner R70 World 3) or the R78 Golden Nukey's
		SparkleNukey (tools/blender/models/pet_golden_nukey.py). Each
		species appears once in its own Blender colours (its "home" egg); the other pets of that
		species are recolours (`colors` overrides its Body / Head / Glow pieces). `hover` is the
		species' flying height from the art catalogue (0 = it hops along the ground). While a mesh
		is not uploaded the client shows the manifest's piece boxes; if a key were missing it builds
		a cute primitive stand-in from `palette` (Client/Pets/PetModels).

	Ids are SAVE DATA (profile.pets.owned[uid].id, pets.index). Never rename or reuse an id.
	Several ids are referenced by other systems' configs (B7 ShopConfig / GroupConfig /
	LuckySpinConfig, B11 event, W2 MonetizationConfig): group_glow_kitty, starter_atom_pup,
	secret_golden_nuke, lucky_atom, gobble_bomb, time_ptero (Time Traveler Pack), rocket_corgi
	(Astronaut Pack), golden_nukey (R78 Nuke Pass Season 1 premium tier 30, PassConfig).

	Equip slots: Slots.Base (3) + Slots.PassBonus (2, PetSlots game pass) + the Rebirth shop
	"petSlots" level (RebirthConfig.Shop.petSlots, max 2) → 7 at most (ProfileLogic MaxEquipped
	16 is the hard bound).

	Inventory: hatching and crate pets stop at InventoryCap (soft cap, the player deletes pets to
	make room). Reward grants (group pet, packs, event, admin) may exceed it up to HardCap (the
	profile's MaxPets) so a paid or one-time reward is never lost.

	Connects to: Shared/Config/EggConfig (pools), Shared/Config/CrateConfig (crate pets),
	Shared/Config/RebirthConfig (petSlots), Server/Pets/*, Server/Services/{PetService,
	CrateService}, Client/Pets/*, UI/Screens/{Pets,EggHatch,CrateOpen,CrateShop}, tests/pets-*.luau.

	Example:
		local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
		local pet = PetConfig.get("rad_raccoon")
		print(pet.name, pet.rarity, PetConfig.formatBonus(pet.cash)) --> Rad Raccoon Epic +20%
		print(PetConfig.slotsFor(true, 1)) --> 6 (3 base + 2 pass + 1 rebirth)
]]

export type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic" | "Secret"

export type RarityDef = {
	id: Rarity,
	rank: number, -- 1 (Common) .. 7 (Secret)
	color: Color3, -- card / glow / billboard colour
	dark: Color3, -- darker edge of the same colour
	base: number, -- cash bonus of a tier-1 pet of this rarity (fraction)
	scale: number, -- follow-model scale (rarer pets are a little bigger)
	ui: string, -- StudUI colour preset for buttons / cards of this rarity
}

-- Where a pet comes from (UI "How to get" line + analytics; never a gate by itself).
-- "pack" = a fixed pet inside a one-time Robux pack (Time Traveler Pack: Time Ptero).
-- "pass" = a Nuke Pass reward (R78: Golden Nukey, Season 1 premium tier 30; granted by PassService
-- through the RewardLogic "pet" item granter, Server/Pets/PetGrants).
export type Source = "egg" | "group" | "starter" | "secret" | "wheel" | "event" | "crate" | "lucky" | "pack" | "pass"

export type PetDef = {
	id: string,
	name: string,
	rarity: Rarity,
	tier: number, -- 1..10 bonus tier (≈ area egg)
	cash: number, -- derived: cash bonus fraction while equipped
	model: string, -- MeshAssets key (B8f species mesh)
	colors: { [string]: Color3 }, -- piece colour overrides (Body, Head, Glow); empty = native
	palette: { body: Color3, glow: Color3 }, -- stand-in look colours (mesh key missing)
	hover: number, -- flying height in studs (0 = hops on the ground)
	flying: boolean, -- hover > 0
	source: Source,
	order: number, -- display / index order
	-- R78: not reachable by free, always-available play (packs / pass / limited events). The Index
	-- "all" milestone does not need it; owning one still counts (PetIndexConfig).
	exclusive: boolean,
	how: string?, -- Index "how to get it" override (nil = the source's line)
}

local PetConfig = {}

--------------------------------------------------------------------------------------------------
-- Rarities
--------------------------------------------------------------------------------------------------

-- Rarity ladder, Common → Secret. `base` × TierGrowth^(tier-1) = a pet's bonus.
local RARITIES: { RarityDef } = {
	{
		id = "Common",
		rank = 1,
		color = Color3.fromRGB(200, 206, 214),
		dark = Color3.fromRGB(120, 128, 140),
		base = 0.04,
		scale = 1,
		ui = "grey",
	},
	{
		id = "Uncommon",
		rank = 2,
		color = Color3.fromRGB(98, 214, 82),
		dark = Color3.fromRGB(48, 140, 44),
		base = 0.07,
		scale = 1.04,
		ui = "green",
	},
	{
		id = "Rare",
		rank = 3,
		color = Color3.fromRGB(64, 160, 255),
		dark = Color3.fromRGB(30, 94, 196),
		base = 0.12,
		scale = 1.08,
		ui = "blue",
	},
	{
		id = "Epic",
		rank = 4,
		color = Color3.fromRGB(176, 92, 255),
		dark = Color3.fromRGB(110, 46, 190),
		base = 0.2,
		scale = 1.12,
		ui = "purple",
	},
	{
		id = "Legendary",
		rank = 5,
		color = Color3.fromRGB(255, 196, 46),
		dark = Color3.fromRGB(204, 132, 20),
		base = 0.35,
		scale = 1.18,
		ui = "yellow",
	},
	{
		id = "Mythic",
		rank = 6,
		color = Color3.fromRGB(255, 72, 96),
		dark = Color3.fromRGB(176, 30, 52),
		base = 0.6,
		scale = 1.24,
		ui = "red",
	},
	{
		id = "Secret",
		rank = 7,
		color = Color3.fromRGB(40, 240, 200),
		dark = Color3.fromRGB(16, 140, 120),
		base = 1,
		scale = 1.3,
		ui = "rainbow",
	},
}
for _, def in RARITIES do
	table.freeze(def)
end
PetConfig.Rarities = table.freeze(RARITIES)

local RARITY_BY_ID: { [string]: RarityDef } = {}
for _, def in RARITIES do
	RARITY_BY_ID[def.id] = def
end

-- Bonus growth per tier (tier 10 = ×7.45 a tier-1 pet of the same rarity).
PetConfig.TierGrowth = 1.25

--------------------------------------------------------------------------------------------------
-- Slots, inventory, attributes
--------------------------------------------------------------------------------------------------

PetConfig.Slots = table.freeze({
	Base = 3, -- everyone
	PassKey = "PetSlots", -- MonetizationConfig pass
	PassBonus = 2,
	ShopKey = "petSlots", -- RebirthConfig.Shop key (+1 per level, max 2)
	Max = 7, -- Base + PassBonus + the shop's max level (validated)
})

-- Hatches and crate pets stop here (soft cap). Reward grants may go up to HardCap.
PetConfig.InventoryCap = 250
-- = ProfileLogic.Limits.MaxPets (the profile's hard bound; tests/pets-logic.luau keeps them equal).
PetConfig.HardCap = 1_000

-- Replicated Player attribute: comma-separated pet ids of the equipped pets (≤ Slots.Max ids,
-- ≤ ~200 bytes). Every client renders other players' pets from it (no per-pet remote traffic).
PetConfig.Attribute = "SNPets"

--------------------------------------------------------------------------------------------------
-- Server tunables (PetService)
--------------------------------------------------------------------------------------------------

PetConfig.Server = table.freeze({
	-- Hatch requests: token bucket per player (a triple hatch is ONE request).
	HatchBurst = 3,
	HatchPerSecond = 1.25,
	-- Equip / lock / delete / equip-best requests.
	ActionBurst = 12,
	ActionPerSecond = 6,
	-- Remembered replies per player (request-id idempotency).
	RecentRequests = 32,
	-- Client request ids are 1..MaxRequestId (0 is reserved for server-initiated reveals).
	MaxRequestId = 2 ^ 31,
	-- Bounded list sizes of DeletePets / LockPets.
	MaxBatch = 100,
	-- Max hatch count per request (single = 1, TripleHatch pass = 3).
	MaxCount = 3,
})

--------------------------------------------------------------------------------------------------
-- Client follow animation (Pets/PetController)
--------------------------------------------------------------------------------------------------

PetConfig.Follow = table.freeze({
	-- Pets trail the owner in an arc behind them.
	Distance = 5.5, -- studs behind the HumanoidRootPart
	Spacing = 3.4, -- studs between neighbours along the arc
	RowSize = 4, -- pets per arc row before a second row starts
	RowGap = 3.6, -- extra studs behind for the next row
	HopHeight = 0.9, -- ground pets hop this high while moving
	HopRate = 7, -- hops per second while moving
	BobRate = 2.2, -- idle bob cycles per second
	BobHeight = 0.25,
	FollowSharpness = 9, -- exponential smoothing rate (higher = snappier)
	TurnSharpness = 10,
	TeleportDistance = 60, -- further than this from the slot → snap (teleports, respawns)
	-- Distance culling: other players' pets beyond this are not rendered at all.
	CullDistance = 160,
	-- Hard cap of other players' rendered pets (nearest first) — 8 players × 7 pets max is 56.
	MaxOtherPets = 40,
	-- Ground raycast every N frames per pet (cached in between).
	GroundRayEvery = 6,
})

--------------------------------------------------------------------------------------------------
-- Roster
--------------------------------------------------------------------------------------------------

-- Short colour helper for the table below.
local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

--[[
	Species = B8f's Blender pet meshes (tools/blender/models/pets.py, MeshAssets keys). HOVER is each
	species' flying height in studs from the art catalogue (0 = walks / hops on the ground).
]]
local HOVER: { [string]: number } = {
	ReactorOwl = 0.8,
	NuclearNarwhal = 1.0,
	AtomicAxolotl = 0.4,
	FusionPhoenix = 1.0,
	CoreDragon = 0.9,
	IonJelly = 1.0,
	VoidCat = 0.3,
	-- Dino Valley flyers (pets_dino.py): PetAnim derives Fly from hover + WingL / WingR.
	MagmaPtero = 0.9,
	TimePtero = 1.0,
	-- Moon Base flyers / floaters (pets_moon.py): owl + unicorn Fly (wings), octo + corgi Float,
	-- the whale Swims (PetAnimConfig override).
	OrbitOwl = 0.8,
	SaucerOcto = 0.6,
	GalaxyWhale = 1.0,
	StarlightUnicorn = 0.6,
	RocketCorgi = 0.5,
}

-- A recolour: the species' Body + Head become `body`, its Glow pieces `glow`.
type Tint = { body: Color3, glow: Color3 }

type RosterRow = {
	id: string,
	name: string,
	rarity: Rarity,
	tier: number,
	model: string,
	tint: Tint?, -- nil = the species' own Blender colours (its "home" egg)
	source: Source,
	exclusive: boolean?, -- R78 (header "Exclusive pets"); nil = false
	how: string?, -- Index "how to get it" override
}

local function tint(body: Color3, glow: Color3): Tint
	return { body = body, glow = glow }
end

-- One row per pet: id (SAVE DATA), name, rarity, tier, species mesh, optional recolour, source.
-- Area eggs: 1-2 Common/Uncommon/Rare/Epic, 3-5 Uncommon..Legendary, 6-8 Rare..Mythic,
-- 9-10 Epic..Secret (EggConfig owns the odds). Every species appears in its native colours once.
local ROSTER: { RosterRow } = {
	-- Egg 1 - Garage Egg
	{ id = "glow_slime", name = "Glow Slime", rarity = "Common", tier = 1, model = "GlowSlime", source = "egg" },
	{ id = "atom_pup", name = "Atom Pup", rarity = "Uncommon", tier = 1, model = "AtomPup", source = "egg" },
	{ id = "fission_fox", name = "Fission Fox", rarity = "Rare", tier = 1, model = "FissionFox", source = "egg" },
	{ id = "rad_raccoon", name = "Rad Raccoon", rarity = "Epic", tier = 1, model = "RadRaccoon", source = "egg" },
	-- Egg 2 - Nuke Stand Egg
	{
		id = "isotope_kitty",
		name = "Isotope Kitty",
		rarity = "Common",
		tier = 2,
		model = "IsotopeKitty",
		source = "egg",
	},
	{ id = "quark_duck", name = "Quark Duck", rarity = "Uncommon", tier = 2, model = "QuarkDuck", source = "egg" },
	{ id = "reactor_owl", name = "Reactor Owl", rarity = "Rare", tier = 2, model = "ReactorOwl", source = "egg" },
	{
		id = "atomic_axolotl",
		name = "Atomic Axolotl",
		rarity = "Epic",
		tier = 2,
		model = "AtomicAxolotl",
		source = "egg",
	},
	-- Egg 3 - BoomDash Egg
	{
		id = "uranium_bunny",
		name = "Uranium Bunny",
		rarity = "Uncommon",
		tier = 3,
		model = "UraniumBunny",
		source = "egg",
	},
	{ id = "proton_panda", name = "Proton Panda", rarity = "Rare", tier = 3, model = "ProtonPanda", source = "egg" },
	{ id = "cosmic_corgi", name = "Cosmic Corgi", rarity = "Epic", tier = 3, model = "CosmicCorgi", source = "egg" },
	{
		id = "fusion_phoenix",
		name = "Fusion Phoenix",
		rarity = "Legendary",
		tier = 3,
		model = "FusionPhoenix",
		source = "egg",
	},
	-- Egg 4 - Glow Rock Egg
	{ id = "mega_mole", name = "Mega Mole", rarity = "Uncommon", tier = 4, model = "MegaMole", source = "egg" },
	{ id = "gamma_gator", name = "Gamma Gator", rarity = "Rare", tier = 4, model = "GammaGator", source = "egg" },
	{
		id = "nuclear_narwhal",
		name = "Nuclear Narwhal",
		rarity = "Epic",
		tier = 4,
		model = "NuclearNarwhal",
		source = "egg",
	},
	{
		id = "meltdown_moose",
		name = "Meltdown Moose",
		rarity = "Legendary",
		tier = 4,
		model = "MeltdownMoose",
		source = "egg",
	},
	-- Egg 5 - Lab Egg
	{
		id = "neutron_newt",
		name = "Neutron Newt",
		rarity = "Uncommon",
		tier = 5,
		model = "NeutronNewt",
		source = "egg",
	},
	{ id = "plasma_pig", name = "Plasma Pig", rarity = "Rare", tier = 5, model = "PlasmaPig", source = "egg" },
	{
		id = "lab_axolotl",
		name = "Lab Axolotl",
		rarity = "Epic",
		tier = 5,
		model = "AtomicAxolotl",
		tint = tint(rgb(240, 246, 255), rgb(90, 220, 255)),
		source = "egg",
	},
	{ id = "reactor_rex", name = "Reactor Rex", rarity = "Legendary", tier = 5, model = "ReactorRex", source = "egg" },
	-- Egg 6 - Rocket Factory Egg
	{
		id = "forge_fox",
		name = "Forge Fox",
		rarity = "Rare",
		tier = 6,
		model = "FissionFox",
		tint = tint(rgb(255, 190, 60), rgb(255, 90, 40)),
		source = "egg",
	},
	{
		id = "bolt_raccoon",
		name = "Bolt Raccoon",
		rarity = "Epic",
		tier = 6,
		model = "RadRaccoon",
		tint = tint(rgb(255, 150, 40), rgb(90, 220, 255)),
		source = "egg",
	},
	{
		id = "mech_rex",
		name = "Mech Rex",
		rarity = "Legendary",
		tier = 6,
		model = "ReactorRex",
		tint = tint(rgb(200, 208, 222), rgb(255, 80, 80)),
		source = "egg",
	},
	{ id = "core_dragon", name = "Core Dragon", rarity = "Mythic", tier = 6, model = "CoreDragon", source = "egg" },
	-- Egg 7 - Launch Silo Egg
	{
		id = "radar_owl",
		name = "Radar Owl",
		rarity = "Rare",
		tier = 7,
		model = "ReactorOwl",
		tint = tint(rgb(50, 70, 140), rgb(90, 255, 160)),
		source = "egg",
	},
	{
		id = "hazard_corgi",
		name = "Hazard Corgi",
		rarity = "Epic",
		tier = 7,
		model = "CosmicCorgi",
		tint = tint(rgb(255, 214, 40), rgb(255, 120, 40)),
		source = "egg",
	},
	{
		id = "rocket_phoenix",
		name = "Rocket Phoenix",
		rarity = "Legendary",
		tier = 7,
		model = "FusionPhoenix",
		tint = tint(rgb(235, 60, 60), rgb(255, 230, 90)),
		source = "egg",
	},
	{ id = "nova_unicorn", name = "Nova Unicorn", rarity = "Mythic", tier = 7, model = "NovaUnicorn", source = "egg" },
	-- Egg 8 - Megastore Egg
	{
		id = "mascot_panda",
		name = "Mascot Panda",
		rarity = "Rare",
		tier = 8,
		model = "ProtonPanda",
		tint = tint(rgb(70, 150, 255), rgb(255, 230, 90)),
		source = "egg",
	},
	{
		id = "neon_narwhal",
		name = "Neon Narwhal",
		rarity = "Epic",
		tier = 8,
		model = "NuclearNarwhal",
		tint = tint(rgb(230, 70, 230), rgb(90, 255, 255)),
		source = "egg",
	},
	{
		id = "mascot_moose",
		name = "Mascot Moose",
		rarity = "Legendary",
		tier = 8,
		model = "MeltdownMoose",
		tint = tint(rgb(90, 210, 110), rgb(255, 255, 255)),
		source = "egg",
	},
	{ id = "ion_jelly", name = "Ion Jelly", rarity = "Mythic", tier = 8, model = "IonJelly", source = "egg" },
	-- Egg 9 - Space Port Egg
	{
		id = "astro_corgi",
		name = "Astro Corgi",
		rarity = "Epic",
		tier = 9,
		model = "CosmicCorgi",
		tint = tint(rgb(240, 244, 255), rgb(90, 160, 255)),
		source = "egg",
	},
	{
		id = "comet_phoenix",
		name = "Comet Phoenix",
		rarity = "Legendary",
		tier = 9,
		model = "FusionPhoenix",
		tint = tint(rgb(150, 220, 255), rgb(255, 255, 255)),
		source = "egg",
	},
	{
		id = "star_unicorn",
		name = "Star Unicorn",
		rarity = "Mythic",
		tier = 9,
		model = "NovaUnicorn",
		tint = tint(rgb(190, 150, 255), rgb(255, 250, 160)),
		source = "egg",
	},
	{ id = "void_cat", name = "Void Cat", rarity = "Secret", tier = 9, model = "VoidCat", source = "egg" },
	-- Egg 10 - Mega Reactor Egg
	{
		id = "fusion_axolotl",
		name = "Fusion Axolotl",
		rarity = "Epic",
		tier = 10,
		model = "AtomicAxolotl",
		tint = tint(rgb(255, 200, 60), rgb(120, 255, 120)),
		source = "egg",
	},
	{
		id = "plasma_rex",
		name = "Plasma Rex",
		rarity = "Legendary",
		tier = 10,
		model = "ReactorRex",
		tint = tint(rgb(255, 70, 190), rgb(120, 230, 255)),
		source = "egg",
	},
	{
		id = "plasma_dragon",
		name = "Plasma Dragon",
		rarity = "Mythic",
		tier = 10,
		model = "CoreDragon",
		tint = tint(rgb(255, 110, 210), rgb(90, 255, 255)),
		source = "egg",
	},
	{
		id = "quark_nukey",
		name = "Quark Nukey",
		rarity = "Secret",
		tier = 10,
		model = "GoldenNukey",
		tint = tint(rgb(40, 240, 200), rgb(255, 120, 230)),
		source = "egg",
	},
	-- Harvest Egg (Harvest Feast event, acorns)
	{
		id = "acorn_squirrel",
		name = "Acorn Squirrel",
		rarity = "Rare",
		tier = 5,
		model = "AcornSquirrel",
		source = "egg",
		exclusive = true, -- Harvest Feast window only
	},
	{
		id = "harvest_hedgehog",
		name = "Harvest Hedgehog",
		rarity = "Epic",
		tier = 5,
		model = "HarvestHedgehog",
		source = "egg",
		exclusive = true, -- Harvest Feast window only
	},
	{
		id = "cranberry_crab",
		name = "Cranberry Crab",
		rarity = "Legendary",
		tier = 5,
		model = "CranberryCrab",
		source = "egg",
		exclusive = true, -- Harvest Feast window only
	},
	{
		id = "cornucopia_dragon",
		name = "Cornucopia Dragon",
		rarity = "Mythic",
		tier = 5,
		model = "CoreDragon",
		tint = tint(rgb(240, 130, 40), rgb(255, 214, 90)),
		source = "egg",
		exclusive = true, -- Harvest Feast window only
	},
	-- Lucky Egg (held only: Lucky Wheel, crates, admin)
	{
		id = "clover_slime",
		name = "Clover Slime",
		rarity = "Rare",
		tier = 4,
		model = "GlowSlime",
		tint = tint(rgb(60, 200, 90), rgb(255, 230, 90)),
		source = "lucky",
	},
	{
		id = "lucky_bunny",
		name = "Lucky Bunny",
		rarity = "Epic",
		tier = 4,
		model = "UraniumBunny",
		tint = tint(rgb(150, 240, 170), rgb(255, 220, 60)),
		source = "lucky",
	},
	{
		id = "lucky_fox",
		name = "Lucky Fox",
		rarity = "Legendary",
		tier = 4,
		model = "FissionFox",
		tint = tint(rgb(80, 210, 110), rgb(255, 230, 90)),
		source = "lucky",
	},
	{
		id = "rainbow_jelly",
		name = "Rainbow Jelly",
		rarity = "Mythic",
		tier = 4,
		model = "IonJelly",
		tint = tint(rgb(255, 120, 220), rgb(120, 255, 240)),
		source = "lucky",
	},
	-- Specials (never hatched; granted by other systems). NOTE: "group_glow_kitty" is the save id
	-- B7's GroupConfig grants; it is the Builder Beaver, B8f's group-exclusive mesh.
	{
		id = "group_glow_kitty",
		name = "Builder Beaver",
		rarity = "Epic",
		tier = 3,
		model = "BuilderBeaver",
		source = "group",
	},
	{
		id = "starter_atom_pup",
		name = "Golden Atom Pup",
		rarity = "Legendary",
		tier = 3,
		model = "AtomPup",
		tint = tint(rgb(255, 200, 60), rgb(120, 255, 140)),
		source = "starter",
		exclusive = true, -- Starter Pack (Robux)
	},
	{
		id = "secret_golden_nuke",
		name = "Golden Nuke",
		rarity = "Secret",
		tier = 4,
		model = "GoldenNukey",
		source = "secret",
		exclusive = true, -- Secret Pack (Robux)
	},
	{
		id = "lucky_atom",
		name = "Lucky Duck",
		rarity = "Legendary",
		tier = 4,
		model = "QuarkDuck",
		tint = tint(rgb(255, 214, 60), rgb(120, 255, 120)),
		source = "wheel",
	},
	{
		id = "gobble_bomb",
		name = "Gobble Bomb",
		rarity = "Mythic",
		tier = 6,
		model = "GobbleBomb",
		source = "event",
		exclusive = true, -- Harvest Feast sticker sheet (event window)
	},
	-- Crate pets (Supply / Mega / Golden crates)
	{
		id = "crate_supply_mole",
		name = "Supply Mole",
		rarity = "Epic",
		tier = 5,
		model = "MegaMole",
		tint = tint(rgb(90, 220, 255), rgb(255, 255, 255)),
		source = "crate",
	},
	{
		id = "crate_storm_phoenix",
		name = "Storm Phoenix",
		rarity = "Legendary",
		tier = 6,
		model = "FusionPhoenix",
		tint = tint(rgb(40, 52, 110), rgb(120, 230, 255)),
		source = "crate",
	},
	{
		id = "crate_golden_dragon",
		name = "Golden Dragon",
		rarity = "Mythic",
		tier = 8,
		model = "CoreDragon",
		tint = tint(rgb(255, 196, 46), rgb(255, 255, 220)),
		source = "crate",
	},
	{
		id = "crate_cosmic_unicorn",
		name = "Cosmic Unicorn",
		rarity = "Secret",
		tier = 10,
		model = "NovaUnicorn",
		tint = tint(rgb(60, 40, 120), rgb(90, 255, 230)),
		source = "crate",
	},
	-- World 2 "Dino Valley" (owner R57, spec §8; W11 Blender meshes tools/blender/models/pets_dino.py).
	-- Dino Egg (Dino area 2, Bones): bonus tier 4 — Uncommon / Rare / Epic / Legendary.
	{ id = "atom_raptor", name = "Atom Raptor", rarity = "Uncommon", tier = 4, model = "AtomRaptor", source = "egg" },
	{ id = "glow_stego", name = "Glow Stego", rarity = "Rare", tier = 4, model = "GlowStego", source = "egg" },
	{
		id = "fission_trike",
		name = "Fission Trike",
		rarity = "Epic",
		tier = 4,
		model = "FissionTrike",
		source = "egg",
	},
	{
		id = "pocket_bronto",
		name = "Pocket Bronto",
		rarity = "Legendary",
		tier = 4,
		model = "PocketBronto",
		source = "egg",
	},
	-- Volcano Egg (Dino area 5, Bones): bonus tier 7 — Rare / Epic / Legendary / Mythic.
	{ id = "ember_ankylo", name = "Ember Ankylo", rarity = "Rare", tier = 7, model = "EmberAnkylo", source = "egg" },
	{ id = "magma_ptero", name = "Magma Ptero", rarity = "Epic", tier = 7, model = "MagmaPtero", source = "egg" },
	{ id = "lava_para", name = "Lava Para", rarity = "Legendary", tier = 7, model = "LavaPara", source = "egg" },
	{
		id = "supernova_spino",
		name = "Supernova Spino",
		rarity = "Mythic",
		tier = 7,
		model = "SupernovaSpino",
		source = "egg",
	},
	-- Time Traveler Pack (MonetizationConfig "TimeTravelerPack", kind WorldStarter): a FIXED grant
	-- (never random, so the pack is not a paid random item) through PetGrants.grantFixed.
	{
		id = "time_ptero",
		name = "Time Ptero",
		rarity = "Epic",
		tier = 5,
		model = "TimePtero",
		source = "pack",
		exclusive = true, -- Time Traveler Pack (Robux)
	},
	-- World 3 "Moon Base" (owner R70, r69 spec §2.5; W11 Blender meshes tools/blender/models/pets_moon.py).
	-- Moon Egg (Moon area 2, Moon Rocks): bonus tier 4 — Uncommon / Rare / Epic / Legendary.
	{ id = "astro_pup", name = "Astro Pup", rarity = "Uncommon", tier = 4, model = "AstroPup", source = "egg" },
	{ id = "moon_bunny", name = "Moon Bunny", rarity = "Rare", tier = 4, model = "MoonBunny", source = "egg" },
	{ id = "orbit_owl", name = "Orbit Owl", rarity = "Epic", tier = 4, model = "OrbitOwl", source = "egg" },
	{ id = "cosmo_cat", name = "Cosmo Cat", rarity = "Legendary", tier = 4, model = "CosmoCat", source = "egg" },
	-- Comet Egg (Moon area 5, Moon Rocks): bonus tier 7 — Rare / Epic / Legendary / Mythic.
	{ id = "comet_fox", name = "Comet Fox", rarity = "Rare", tier = 7, model = "CometFox", source = "egg" },
	{ id = "saucer_octo", name = "Saucer Octo", rarity = "Epic", tier = 7, model = "SaucerOcto", source = "egg" },
	{
		id = "galaxy_whale",
		name = "Galaxy Whale",
		rarity = "Legendary",
		tier = 7,
		model = "GalaxyWhale",
		source = "egg",
	},
	{
		id = "starlight_unicorn",
		name = "Starlight Unicorn",
		rarity = "Mythic",
		tier = 7,
		model = "StarlightUnicorn",
		source = "egg",
	},
	-- Astronaut Pack (MonetizationConfig "AstronautPack", kind WorldStarter): a FIXED grant through
	-- PetGrants.grantFixed (never random, so the pack is not a paid random item).
	{
		id = "rocket_corgi",
		name = "Rocket Corgi",
		rarity = "Epic",
		tier = 5,
		model = "RocketCorgi",
		source = "pack",
		exclusive = true, -- Astronaut Pack (Robux)
		how = "Comes in the Astronaut Pack (Shop)!",
	},
	-- R78 Nuke Pass Season 1 (spec 2026-10-31-r78 §2 / §5): premium tier 30, granted by PassService
	-- through the RewardLogic "pet" item granter (PetGrants.pet). In NO egg pool; strength = the best
	-- Nuke Town Mythic (Plasma Dragon, Mythic tier 10). Mesh: tools/blender/models/pet_golden_nukey.py
	-- (a golden, sparkly chibi of the lobby's Nukey mascot statue).
	{
		id = "golden_nukey",
		name = "Golden Nukey",
		rarity = "Mythic",
		tier = 10,
		model = "SparkleNukey",
		source = "pass",
		exclusive = true, -- Nuke Pass Season 1 premium track
		how = "Nuke Pass Season 1 - Premium tier 30!",
	},
}

--[[
	The cash bonus of a pet of `rarity` at `tier` (fraction, rounded to a whole percent).
	Example: PetConfig.bonusFor("Epic", 1) --> 0.2 ; PetConfig.bonusFor("Secret", 10) --> 7.45
]]
function PetConfig.bonusFor(rarity: Rarity, tier: number): number
	local def = RARITY_BY_ID[rarity]
	if def == nil then
		return 0
	end
	local raw = def.base * PetConfig.TierGrowth ^ (math.clamp(tier, 1, 10) - 1)
	return math.floor(raw * 100 + 0.5) / 100
end

-- Freezes a config record and keeps its declared (writable) type for the tables below; the new
-- type solver would otherwise narrow it to a read-only shape.
local function frozen<T>(value: T): T
	return table.freeze(value :: any) :: any
end

local PETS: { [string]: PetDef } = {}
local ORDER: { string } = {}
for index, row in ROSTER do
	local rarity = RARITY_BY_ID[row.rarity]
	local recolour = row.tint
	local def: PetDef = {
		id = row.id,
		name = row.name,
		rarity = row.rarity,
		tier = row.tier,
		cash = PetConfig.bonusFor(row.rarity, row.tier),
		model = row.model,
		-- Mesh piece overrides (empty = the species' own Blender colours).
		colors = table.freeze(
			if recolour ~= nil then { Body = recolour.body, Head = recolour.body, Glow = recolour.glow } else {}
		) :: { [string]: Color3 },
		-- Stand-in look colours (only while a mesh key is missing from MeshAssets).
		palette = frozen({
			body = if recolour ~= nil then recolour.body elseif rarity ~= nil then rarity.color else Color3.new(1, 1, 1),
			glow = if recolour ~= nil then recolour.glow else Color3.fromRGB(120, 255, 120),
		}),
		hover = HOVER[row.model] or 0,
		flying = (HOVER[row.model] or 0) > 0,
		source = row.source,
		order = index,
		exclusive = row.exclusive == true,
		how = row.how,
	}
	PETS[def.id] = frozen(def)
	table.insert(ORDER, def.id)
end
PetConfig.Pets = table.freeze(PETS)
PetConfig.Order = table.freeze(ORDER)
PetConfig.Count = #ORDER

-- Every species mesh key the roster uses (client preload / art checklist).
local SPECIES: { string } = {}
do
	local seen: { [string]: boolean } = {}
	for _, id in ORDER do
		local model = PETS[id].model
		if not seen[model] then
			seen[model] = true
			table.insert(SPECIES, model)
		end
	end
end
PetConfig.Species = table.freeze(SPECIES)

--------------------------------------------------------------------------------------------------
-- Lookups and helpers (pure; safe on hostile input)
--------------------------------------------------------------------------------------------------

--[[
	The pet with id `id` (rawget on the frozen table: unknown / non-string ids → nil).
	Example: PetConfig.get("glow_slime").name --> "Glow Slime"
]]
function PetConfig.get(id: unknown): PetDef?
	if type(id) ~= "string" then
		return nil
	end
	return rawget(PETS :: any, id)
end

--[[ The rarity definition (nil for unknown names). ]]
function PetConfig.rarity(id: unknown): RarityDef?
	if type(id) ~= "string" then
		return nil
	end
	return RARITY_BY_ID[id]
end

--[[ Rank 1..7 of a rarity (0 for unknown). ]]
function PetConfig.rank(id: unknown): number
	local def = PetConfig.rarity(id)
	return if def ~= nil then def.rank else 0
end

--[[
	Equip slots for a player.
	@param hasPass   owns the PetSlots game pass
	@param shopLevel profile.rebirthShop.petSlots (clamped 0..2)
	@return 3..Slots.Max
	Example: PetConfig.slotsFor(false, 0) --> 3
]]
function PetConfig.slotsFor(hasPass: boolean, shopLevel: unknown): number
	local level = 0
	if type(shopLevel) == "number" and shopLevel == shopLevel then
		level =
			math.clamp(math.floor(shopLevel), 0, PetConfig.Slots.Max - PetConfig.Slots.Base - PetConfig.Slots.PassBonus)
	end
	local slots = PetConfig.Slots.Base + (if hasPass then PetConfig.Slots.PassBonus else 0) + level
	return math.min(slots, PetConfig.Slots.Max)
end

--[[
	"+12%" / "+745%" — a cash bonus fraction as the UI shows it.
	Example: PetConfig.formatBonus(0.2) --> "+20%"
]]
function PetConfig.formatBonus(fraction: number): string
	if type(fraction) ~= "number" or fraction ~= fraction or fraction < 0 then
		return "+0%"
	end
	local percent = math.floor(fraction * 100 + 0.5)
	if percent >= 10_000 then
		return `+{math.floor(percent / 100 + 0.5)}x`
	end
	return `+{percent}%`
end

--[[
	Sort comparator "best first": higher cash, then rarer, then later tier, then roster order.
	Used by Equip Best (server) and the inventory sort (client) so both agree exactly.
	Example: table.sort(defs, PetConfig.better)
]]
function PetConfig.better(a: PetDef, b: PetDef): boolean
	if a.cash ~= b.cash then
		return a.cash > b.cash
	end
	local ra, rb = PetConfig.rank(a.rarity), PetConfig.rank(b.rarity)
	if ra ~= rb then
		return ra > rb
	end
	if a.tier ~= b.tier then
		return a.tier > b.tier
	end
	return a.order < b.order
end

--[[
	Encodes equipped pet ids for the replicated attribute ("glow_slime,atom_pup").
	Example: PetConfig.encodeEquipped({ "glow_slime" }) --> "glow_slime"
]]
function PetConfig.encodeEquipped(petIds: { string }): string
	return table.concat(petIds, ",", 1, math.min(#petIds, PetConfig.Slots.Max))
end

--[[
	Decodes the replicated attribute back into KNOWN pet ids (untrusted text: unknown ids and
	extra entries are dropped).
	Example: PetConfig.decodeEquipped("glow_slime,bad id,atom_pup") --> { "glow_slime", "atom_pup" }
]]
function PetConfig.decodeEquipped(raw: unknown): { string }
	local out: { string } = {}
	if type(raw) ~= "string" or #raw > 512 then
		return out
	end
	for id in string.gmatch(raw, "[^,]+") do
		if PetConfig.get(id) ~= nil then
			table.insert(out, id)
			if #out >= PetConfig.Slots.Max then
				break
			end
		end
	end
	return out
end

-- Sources only Robux / the Nuke Pass / a limited event can give: such a pet MUST be exclusive
-- (header "Exclusive pets"), so the Index "all" milestone never needs a purchase or an event.
local EXCLUSIVE_SOURCES: { [string]: boolean } = {
	starter = true,
	secret = true,
	pack = true,
	pass = true,
	event = true,
}

--[[
	Checks the roster: ids are save-safe keys, names fit, rarities known, tiers 1..10, bonuses
	positive, pass / pack / starter / secret / event pets exclusive, `how` lines short.
	@return problems (empty = valid); tests/pets-logic.luau asserts it is empty.
]]
function PetConfig.validate(): { string }
	local problems: { string } = {}
	local names: { [string]: string } = {}
	for _, id in ORDER do
		local def = PETS[id]
		if not string.match(id, "^[a-z][a-z0-9_]*$") or #id > 32 then
			table.insert(problems, `pet {id}: id must be snake_case ≤ 32 chars`)
		end
		if #def.name == 0 or #def.name > 24 then
			table.insert(problems, `pet {id}: name length`)
		end
		if names[def.name] ~= nil then
			table.insert(problems, `pet {id}: name also used by {names[def.name]}`)
		end
		names[def.name] = id
		if RARITY_BY_ID[def.rarity] == nil then
			table.insert(problems, `pet {id}: unknown rarity`)
		end
		if def.tier < 1 or def.tier > 10 or def.tier % 1 ~= 0 then
			table.insert(problems, `pet {id}: tier must be 1..10`)
		end
		if not (def.cash > 0) then
			table.insert(problems, `pet {id}: bonus must be positive`)
		end
		if EXCLUSIVE_SOURCES[def.source] and not def.exclusive then
			table.insert(problems, `pet {id}: a {def.source} pet must be exclusive (Index "all" stays free)`)
		end
		local how = def.how
		if how ~= nil and (#how == 0 or #how > 60) then
			table.insert(problems, `pet {id}: how line must be 1..60 chars`)
		end
	end
	if PetConfig.Slots.Base + PetConfig.Slots.PassBonus + 2 ~= PetConfig.Slots.Max then
		table.insert(problems, "Slots.Max must equal Base + PassBonus + the rebirth shop max (2)")
	end
	return problems
end

return table.freeze(PetConfig)
