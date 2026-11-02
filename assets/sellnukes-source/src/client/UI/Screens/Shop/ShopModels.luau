--!strict
--[[
	ShopModels — which REAL 3D model every Shop item shows (owner R39: "in the shop we should use
	real 3d models"). Cards and pack tiles render these specs in Widgets/ModelViewport (rotating,
	lit, paused off screen); the card's 2D icon is only the loading fallback.

	Rules:
		pets / eggs / crates  their own game models (PetConfig / EggConfig / CrateConfig ids, built
		                      by Pets/PetModels: the Starter Pack's "Golden Atom Pup" IS the gold
		                      AtomPup the player receives)
		nukes / pads          their world meshes (MegaLauncher: the gold silo nuke, Skip Pad: the
		                      buy pad)
		everything else       the small Blender shop props (tools/blender/models/shop_props.py,
		                      Shop_* keys); a prop that is not synced into MeshAssets yet simply
		                      keeps the icon (ModelViewport.canShow is false)
		bigger tiers          more copies (x2 / x5 / x10 Lucky Spins = 2 / 3 / 5 tokens, the
		                      Vault of Cash = three money bags), so tiers read at a glance

	Pack cards (Starter / Secret): one spec per ShopConfig.<Pack>.lines entry, in the same order
	as the Shop's PACK_ICONS (cash, gems, spins, 2x cash, pet); the pet line shows the pack's
	reward pet (ShopConfig.<Pack>.reward.pet) and is always the last line. Where paid random
	items are restricted the spins tile shows SpinsAsGems (the server pays gems instead).

	World sections (R57 World 2, R70 World 3): every ShopConfig.WorldSections item row names its
	own shop-prop mesh (Dino Valley: Shop_BonesSmall / Shop_BonesMedium / Shop_BonesLarge /
	Shop_TimeTravelerPack, W9's Blender props; Moon Base: Shop_MoonRocksSmall / Medium / Large /
	Shop_AstronautPack, W1b's shop_props_moon.py), so forProduct covers them (HUD offers too).
	They are NOT in allSpecs (the boot prefetch): a player without the world never loads them;
	worldSpecs(world) lists them for a prefetch once the world is unlocked.

	Pure data + lookups (configs only, no instances): unit-tested by tests/model-viewport.luau
	(every Shop item has a spec) and tests/shop-item-fx.luau (isRare: which items glint).

	Connects to: Shared/Config/{CrateConfig, MonetizationConfig, ShopConfig}. Used by Shop/init
	(cards, pack tiles, the idle prefetch) through Widgets/ModelViewport.

	Example:
		local spec = ShopModels.forProduct(MonetizationConfig.getProduct("Spins5"))
		--> { key = "Shop_SpinToken", copies = 3 }
		local tiles = ShopModels.packItems("StarterPack", ShopConfig.StarterPack, false)
		--> tiles[5] = { pet = "starter_atom_pup" }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)

-- Same shape as Widgets/ModelViewport.Spec (kept local so this module stays pure / testable).
export type Spec = {
	key: string?,
	pet: string?,
	egg: string?,
	crate: string?,
	copies: number?,
}

-- What packItems reads of a ShopConfig pack.
export type PackContents = {
	reward: { [string]: any },
	lines: { string },
	spinLine: number?,
}

local ShopModels = {}

-- A frozen spec (shared by every caller; the cast drops the frozen table's read-only view).
local function spec(value: Spec): Spec
	return table.freeze(value) :: any
end

-- Developer products by key (crates fall back to CrateConfig.ByProduct in forProduct).
local PRODUCTS: { [string]: Spec } = {
	-- Cash packs: Stack / Bag / Crate / Vault of Cash.
	CashSmall = spec({ key = "Shop_CashStack" }),
	CashMedium = spec({ key = "Shop_MoneyBag" }),
	CashLarge = spec({ key = "Shop_CashPile" }),
	CashHuge = spec({ key = "Shop_MoneyBag", copies = 3 }),
	-- Gem packs: Pile / Bag / Chest of Gems.
	GemsSmall = spec({ key = "Shop_GemCluster" }),
	GemsMedium = spec({ key = "Shop_GemCluster", copies = 2 }),
	GemsLarge = spec({ key = "Shop_GemChest" }),
	-- Lucky Spins: more tokens per tier.
	Spins2 = spec({ key = "Shop_SpinToken", copies = 2 }),
	Spins5 = spec({ key = "Shop_SpinToken", copies = 3 }),
	Spins10 = spec({ key = "Shop_SpinToken", copies = 5 }),
	-- Boosts.
	Cash2x30 = spec({ key = "Shop_BoostPotion" }),
	ServerCash2x = spec({ key = "Shop_ServerBoost" }),
	SkipPad = spec({ key = "BuyPad" }),
	DoubleOffline = spec({ key = "Shop_OfflineMoon" }),
	-- Attack / event products (shown by their own screens; same models if they show one).
	Barrage = spec({ key = "A7_SiloNuke_Red", copies = 3 }),
	Shield1h = spec({ key = "ShieldDome" }),
	AcornsSmall = spec({ key = "Acorn", copies = 2 }),
	AcornsLarge = spec({ key = "Acorn", copies = 5 }),
	TurkeyLure = spec({ key = "GoldenTurkey" }),
	-- A pack as ONE item (offers / receipts): its reward pet. The pack cards use packItems.
	StarterPack = spec({ pet = "starter_atom_pup" }),
	SecretPack = spec({ pet = "secret_golden_nuke" }),
}

-- R57 world-section products: their shop-prop mesh comes from the ShopConfig row (one source of
-- truth for the key; a later explicit PRODUCTS entry above would win).
for _, section in ShopConfig.WorldSections do
	for _, item in section.items do
		if PRODUCTS[item.key] == nil then
			PRODUCTS[item.key] = spec({ key = item.model })
		end
	end
end

-- Game passes by key.
local PASSES: { [string]: Spec } = {
	VIP = spec({ key = "Shop_VipCrown" }),
	DoubleCash = spec({ key = "Shop_CashStack", copies = 2 }),
	AutoClicker = spec({ key = "Shop_AutoClicker" }),
	OfflineMax = spec({ key = "Shop_OfflineMoon" }),
	FastWalk = spec({ key = "Shop_FastShoe" }),
	Teleporter = spec({ key = "Shop_Teleporter" }),
	LuckyEggs = spec({ egg = "lucky_egg" }),
	PetSlots = spec({ key = "Shop_PetSlots" }),
	TripleHatch = spec({ key = "Shop_TripleEgg" }),
	-- Auto Hatch: the factory egg (automation).
	AutoHatch = spec({ egg = "factory_egg" }),
	-- Mega Launcher: the gold silo nuke (nose up, reads well on a turntable).
	MegaLauncher = spec({ key = "A7_SiloNuke_Gold" }),
}

-- Pack card tiles in ShopConfig.<Pack>.lines order (cash, gems, spins, 2x cash); the last
-- line (the pet) comes from the pack's reward.
local PACK_ITEMS: { [string]: { Spec } } = {
	StarterPack = {
		spec({ key = "Shop_CashStack" }),
		spec({ key = "Shop_GemCluster" }),
		spec({ key = "Shop_SpinToken", copies = 3 }),
		spec({ key = "Shop_BoostPotion" }),
	},
	SecretPack = {
		spec({ key = "Shop_CashPile" }),
		spec({ key = "Shop_GemChest" }),
		spec({ key = "Shop_SpinToken", copies = 5 }),
		spec({ key = "Shop_BoostPotion", copies = 2 }),
	},
}

-- The spins tile where paid random items are restricted (the server pays gems instead).
ShopModels.SpinsAsGems = spec({ key = "Shop_GemCluster" })

-- Seconds after boot before the Shop's models start warming in the background.
ShopModels.PrefetchDelay = 20

--[[
	The model of a developer product card.
	@param def MonetizationConfig product (nil -> nil)
	@return Spec? (nil = icon only)
	Example: ShopModels.forProduct(MonetizationConfig.getProduct("CrateMega")) --> { crate = "mega_crate" }
]]
function ShopModels.forProduct(def: MonetizationConfig.ProductDef?): Spec?
	if def == nil then
		return nil
	end
	local mapped = PRODUCTS[def.key]
	if mapped ~= nil then
		return mapped
	end
	if def.kind == "Crate" then
		local crateId = CrateConfig.ByProduct[def.key]
		if crateId ~= nil then
			return spec({ crate = crateId })
		end
	end
	return nil
end

--[[
	The model of a game pass card.
	@param def MonetizationConfig pass (nil -> nil)
	@return Spec? (nil = icon only)
	Example: ShopModels.forPass(MonetizationConfig.getPass("VIP")) --> { key = "Shop_VipCrown" }
]]
function ShopModels.forPass(def: MonetizationConfig.PassDef?): Spec?
	if def == nil then
		return nil
	end
	return PASSES[def.key]
end

--[[
	The models of a pack card's item tiles, indexed like `pack.lines`.
	@param packKey     "StarterPack" | "SecretPack"
	@param pack        ShopConfig.<Pack> (reward + lines + spinLine)
	@param spinsAsGems the spins tile shows gems (paid random items restricted / not known yet)
	@return { [line]: Spec } (missing lines show their icon only)
	Example: ShopModels.packItems("SecretPack", ShopConfig.SecretPack, true)[3] --> SpinsAsGems
]]
function ShopModels.packItems(packKey: string, pack: PackContents, spinsAsGems: boolean): { [number]: Spec }
	local items: { [number]: Spec } = table.clone(PACK_ITEMS[packKey] or {})
	local spinLine = pack.spinLine
	if spinsAsGems and spinLine ~= nil then
		items[spinLine] = ShopModels.SpinsAsGems
	end
	local pet = pack.reward.pet
	if type(pet) == "string" and #pack.lines > 0 then
		items[#pack.lines] = spec({ pet = pet })
	end
	return items
end

--[[
	Every spec the Shop window can show (sections + both pack variants), de-duplicated — what
	the idle prefetch warms.
	@return { Spec }
	Example: ModelViewport.prefetch(ShopModels.allSpecs())
]]
function ShopModels.allSpecs(): { Spec }
	local result: { Spec } = {}
	local seen: { [string]: boolean } = {}
	local function add(item: Spec?)
		if item == nil then
			return
		end
		local id = `{item.key}|{item.pet}|{item.egg}|{item.crate}|{item.copies}`
		if not seen[id] then
			seen[id] = true
			table.insert(result, item)
		end
	end
	for _, section in ShopConfig.Sections do
		for _, ref in section.items do
			if ref.kind == "pass" then
				add(ShopModels.forPass(MonetizationConfig.getPass(ref.key)))
			else
				add(ShopModels.forProduct(MonetizationConfig.getProduct(ref.key)))
				local pack = (ShopConfig :: any)[ref.key]
				if PACK_ITEMS[ref.key] ~= nil and type(pack) == "table" then
					for _, item in ShopModels.packItems(ref.key, pack, false) do
						add(item)
					end
				end
			end
		end
	end
	add(ShopModels.SpinsAsGems)
	return result
end

--[[
	Every spec of the world sections of `worldId` (ShopConfig.WorldSections), de-duplicated —
	what the Shop warms once that world is unlocked (never part of the boot-time allSpecs, so a
	player who cannot see the section never downloads its meshes).
	@param worldId WorldsConfig id ("dino")
	@return { Spec } (empty for a world without a Shop section)
	Example: ModelViewport.prefetch(ShopModels.worldSpecs("dino"))
]]
function ShopModels.worldSpecs(worldId: string): { Spec }
	local result: { Spec } = {}
	local seen: { [Spec]: boolean } = {}
	for _, section in ShopConfig.WorldSections do
		if section.world == worldId then
			for _, item in section.items do
				local found = ShopModels.forProduct(MonetizationConfig.getProduct(item.key))
				if found ~= nil and not seen[found] then
					seen[found] = true
					table.insert(result, found)
				end
			end
		end
	end
	return result
end

--[[
	True for a RARE item (owner R98: rare items get an occasional sparkle glint in the Shop):
	creatures and gacha boxes — a pet (the packs' reward pets), an egg (Lucky Eggs / Auto Hatch)
	or a crate. Shop props, nukes and pads are not rare. Pure.
	@param model the item's spec (nil = icon only -> false)
	@return boolean
	Example: ShopModels.isRare({ pet = "starter_atom_pup" }) --> true
	         ShopModels.isRare({ key = "Shop_CashStack" })  --> false
]]
function ShopModels.isRare(model: Spec?): boolean
	return model ~= nil and (model.pet ~= nil or model.egg ~= nil or model.crate ~= nil)
end

return table.freeze(ShopModels)
