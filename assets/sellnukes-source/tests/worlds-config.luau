--!strict
--[[
	Worlds registry (World 2 plan §4 W1.6, §5 "worlds-config"): Shared/Config/Worlds/WorldsConfig.

	Proves
		* Registry invariants: Order (main first, == WorldGeometry.Order), get / extra, frozen data,
		  def.order / ids / prefixes, geometry.areaCount == #economy.Areas, save-key format, <= 8.
		* Ids unique across worlds, every id carries its world's prefix, and the O(1) reverse lookups
		  (worldOfPad / Producer / BuildKey / Currency / Egg) answer every id (and nil for garbage).
		* Dino Valley matches spec §6.2 EXACTLY: 6 areas, 59 pads in buy order with kind / value /
		  build key, producers + base cycles, pacing targets, only the "Rebirth" feature; and §6.4:
		  the Amber track (bonus, token formula, 4-upgrade shop, Bone Stash = the tuned Unlock prices).
		* Moon Base (R70, World 3) matches the R69–R71 spec §2.1 / §2.2: identity, currencies,
		  geometry, unlock (area 5), link, art paths, every pad id + build key, kinds / values / SCALE
		  multiples mirroring Dino pad-for-pad, the Star Shard track, Rock Stash = Unlock prices; and
		  the three-world link maths (Nuke Town sums every world's link, up to x5.0).
		* Unlock rule truth table (spec §4.1) and the link maths (spec §6.5: caps x3.0 / x1.5,
		  monotonic, hostile counts neutral).
		* Every world declares currencies (with icons) and eggs; Nuke Town's exist in IconAssets /
		  EggConfig today, other worlds' are checked against them as soon as their owners land them.

	Run: lune run tests/worlds-config.luau            (from the repo root)
]]

local Loader = require("./fixtures/RobloxLoader")
local roblox = require("@lune/roblox")

local Color3 = roblox.Color3
local Vector3 = roblox.Vector3

local loader = Loader.new()
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
local WorldGeometry = loader.load("src/shared/Config/Worlds/WorldGeometry")
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local RebirthConfig = loader.load("src/shared/Config/RebirthConfig")
local IconAssets = loader.load("src/shared/Config/IconAssets")
local EggConfig = loader.load("src/shared/Config/EggConfig")

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end
local function near(a: number, b: number): boolean
	return math.abs(a - b) <= 1e-9 * math.max(1, math.abs(a), math.abs(b))
end

local NAN = 0 / 0
local INF = math.huge
local pending: { string } = {}

--------------------------------------------------------------------------------------------------
-- Registry invariants
--------------------------------------------------------------------------------------------------
do
	local order = WorldsConfig.Order
	check(order[1] == "main" and WorldsConfig.MAIN == "main", "Nuke Town is first")
	check(#order >= 2 and #order <= WorldsConfig.MaxWorlds, "1 < worlds <= MaxWorlds")
	check(table.find(order, "dino") ~= nil, "Dino Valley is registered")
	check(order[2] == "dino" and order[3] == "moon", "R70: Moon Base is World 3")
	check(#order == #WorldGeometry.Order, "Order matches WorldGeometry.Order")
	local extra = WorldsConfig.extra()
	check(#extra == #order - 1 and table.isfrozen(extra), "extra() = every non-main world, frozen")
	for position, worldId in order do
		local def = WorldsConfig.get(worldId)
		check(def ~= nil and def.id == worldId and def.order == position, `{worldId} slot`)
		check(WorldGeometry.Order[position] == worldId, `{worldId} geometry order`)
		check(string.match(worldId, "^[a-z][a-z0-9]*$") ~= nil and #worldId <= 16, `{worldId} is a save key`)
		check(def.geometry == WorldGeometry.get(worldId), `{worldId} geometry row`)
		check(def.geometry.areaCount == #def.economy.Areas, `{worldId} one slot per area`)
		check(def.economy.WorldId == worldId and def.economy.IdPrefix == def.idPrefix, `{worldId} economy identity`)
		check(table.isfrozen(def) and table.isfrozen(def.currency) and table.isfrozen(def.eggs), `{worldId} frozen`)
		check(#def.name > 0 and #def.tagline > 0, `{worldId} name + tagline`)
		if position > 1 then
			check(extra[position - 1] == def, `extra()[{position - 1}] is {worldId}`)
		end
	end
	check(
		WorldsConfig.get(nil) == nil and WorldsConfig.get(5) == nil and WorldsConfig.get("nope") == nil,
		"get garbage"
	)
	check(WorldsConfig.get({}) == nil and WorldsConfig.get("MAIN") == nil, "get is exact")
	check(not pcall(function()
		(WorldsConfig.Worlds :: any).hack = {}
	end), "Worlds is frozen")
	check(not pcall(function()
		(WorldsConfig :: any).MAIN = "dino"
	end), "WorldsConfig is frozen")
	-- Nuke Town IS TycoonConfig / RebirthConfig (no second copy of the economy).
	local main = WorldsConfig.get("main")
	check(main.economy == TycoonConfig.Index and main.rebirth == RebirthConfig, "main wraps TycoonConfig")
	check(main.link == nil and main.unlock.kind == "always" and main.portalAnchor == nil, "main is always open")
	for _, key in { "tutorial", "knockdown", "standName", "attack", "leaderstats" } do
		check(main.features[key] == true, `main feature {key}`)
	end
end

--------------------------------------------------------------------------------------------------
-- Ids: unique across worlds, prefixed, reverse lookups
--------------------------------------------------------------------------------------------------
do
	local pads, producers, buildKeys, currencies, eggs, prefixes = {}, {}, {}, {}, {}, {}
	for _, worldId in WorldsConfig.Order do
		local def = WorldsConfig.get(worldId)
		local economy = def.economy
		check(prefixes[economy.BuildPrefix] == nil, `{worldId} prefix {economy.BuildPrefix} unique`)
		prefixes[economy.BuildPrefix] = worldId
		for _, pad in economy.PadOrder do
			check(pads[pad.id] == nil, `pad {pad.id} unique across worlds`)
			pads[pad.id] = worldId
			check(string.match(pad.id, `^{economy.PadPrefix}%d+_[a-z0-9_]+$`) ~= nil, `{pad.id} prefixed`)
			check(buildKeys[pad.build] == nil, `build key {pad.build} unique across worlds`)
			buildKeys[pad.build] = worldId
			check(string.match(pad.build, `^{economy.BuildPrefix}%d+_%u%w*$`) ~= nil, `{pad.build} prefixed`)
			check(WorldsConfig.worldOfPad(pad.id) == worldId, `worldOfPad({pad.id})`)
			check(WorldsConfig.worldOfBuildKey(pad.build) == worldId, `worldOfBuildKey({pad.build})`)
		end
		for _, producer in economy.Producers do
			check(producers[producer.id] == nil, `producer {producer.id} unique across worlds`)
			producers[producer.id] = worldId
			check(
				string.match(producer.id, `^{economy.ProducerPrefix}%d+_[a-z0-9_]+$`) ~= nil,
				`{producer.id} prefixed`
			)
			check(WorldsConfig.worldOfProducer(producer.id) == worldId, `worldOfProducer({producer.id})`)
		end
		for _, currency in { def.currency, def.tokens } do
			check(currencies[currency.key] == nil, `currency {currency.key} unique across worlds`)
			currencies[currency.key] = worldId
			check(WorldsConfig.worldOfCurrency(currency.key) == worldId, `worldOfCurrency({currency.key})`)
			check(not WorldsConfig.ReservedCurrencyKeys[currency.key], `{currency.key} is not a reserved key`)
			check(#currency.icon > 0 and #currency.name > 0, `{worldId} declares a {currency.key} icon`)
			if IconAssets.resolve(currency.icon) == nil then
				check(worldId ~= "main", `Nuke Town icon {currency.icon} exists`)
				table.insert(pending, `IconAssets "{currency.icon}" ({worldId} {currency.key}) not added yet`)
			end
		end
		check(#def.eggs >= 1, `{worldId} sells at least one egg`)
		for _, eggId in def.eggs do
			check(eggs[eggId] == nil, `egg {eggId} sold in one world only`)
			eggs[eggId] = worldId
			check(WorldsConfig.worldOfEgg(eggId) == worldId, `worldOfEgg({eggId})`)
			local egg = EggConfig.Eggs[eggId]
			if egg == nil then
				check(worldId ~= "main", `Nuke Town egg {eggId} exists in EggConfig`)
				table.insert(pending, `EggConfig "{eggId}" ({worldId}) not added yet`)
			elseif worldId ~= "main" and egg.currency ~= nil then
				check(egg.currency == def.currency.key, `{eggId} is priced in {def.currency.key}`)
			end
		end
	end
	check(currencies.cash == "main" and currencies.tokens == "main", "main currencies cash / tokens")
	check(currencies.bones == "dino" and currencies.amber == "dino", "dino currencies bones / amber")
	-- Layout-only build keys resolve by their prefix letter.
	check(
		WorldsConfig.worldOfBuildKey("D1_Base") == "dino" and WorldsConfig.worldOfBuildKey("A3_Base") == "main",
		"prefix"
	)
	for _, bad in { nil, 5, {}, "", "nope", "d1", "Z9_Thing", "d1_stone_bench " } do
		check(WorldsConfig.worldOfPad(bad) == nil, `worldOfPad garbage {tostring(bad)}`)
		check(WorldsConfig.worldOfProducer(bad) == nil, `worldOfProducer garbage {tostring(bad)}`)
		check(WorldsConfig.worldOfBuildKey(bad) == nil, `worldOfBuildKey garbage {tostring(bad)}`)
		check(WorldsConfig.worldOfCurrency(bad) == nil, `worldOfCurrency garbage {tostring(bad)}`)
		check(WorldsConfig.worldOfEgg(bad) == nil, `worldOfEgg garbage {tostring(bad)}`)
	end
	check(WorldsConfig.worldOfCurrency("gems") == nil, "gems belong to no world")
end

--------------------------------------------------------------------------------------------------
-- Dino Valley = spec §6.2 / §6.3 / §6.4
--------------------------------------------------------------------------------------------------
do
	local dino = WorldsConfig.get("dino")
	local economy = dino.economy
	check(dino.name == "Dino Valley" and dino.order == 2 and dino.idPrefix == "d", "Dino identity")
	check(dino.currency.key == "bones" and dino.currency.name == "Bones" and dino.currency.icon == "Bones", "Bones")
	check(dino.tokens.key == "amber" and dino.tokens.name == "Amber" and dino.tokens.icon == "Amber", "Amber")
	check(dino.portalAnchor == "dino" and dino.hubLayout[3] == "ValleyLayout", "Dino portal + Base Camp")
	check(dino.layoutFolder[1] == "Worlds" and dino.layoutFolder[3] == "Layouts", "Dino layouts folder")
	check(dino.ambience.lighting == "dino" and dino.ambience.music == "music_dino_valley", "Dino ambience")
	check(dino.eggs[1] == "dino_egg" and dino.eggs[2] == "volcano_egg" and #dino.eggs == 2, "Dino eggs")
	for _, key in { "tutorial", "knockdown", "standName", "attack", "leaderstats" } do
		check(dino.features[key] == false, `Dino has no {key}`)
	end
	local unlock = dino.unlock
	check(
		unlock.kind == "progress" and unlock.world == "main" and unlock.area == 3 and unlock.orRebirths == 1,
		"unlock"
	)
	local link = dino.link
	check(link.toMainPerRebirth == 0.1 and link.toMainMaxRebirths == 20, "link to main 10 % x 20")
	check(link.fromMainPerRebirth == 0.05 and link.fromMainMaxRebirths == 10, "link from main 5 % x 10")

	-- Areas, producers, cycles, pacing.
	local AREAS = {
		{ "cave_workshop", "Cave Workshop", "dp1_pebble_bench", 1 },
		{ "fern_market", "Fern Market", "dp2_fern_market", 1.5 },
		{ "ptero_post", "Ptero Post", "dp3_ptero_express", 2 },
		{ "geyser_springs", "Geyser Springs", "dp4_geyser_pump", 2.5 },
		{ "fossil_lab", "Fossil Lab", "dp5_fossil_lab", 3.5 },
		{ "volcano_reactor", "Volcano Reactor", "dp6_volcano_core", 5 },
	}
	check(#economy.Areas == 6 and #economy.Producers == 6, "6 areas, 6 producers")
	for index, row in AREAS do
		local area = economy.Areas[index]
		check(area.id == row[1] and area.name == row[2], `D{index} is {row[2]}`)
		check(area.producer.id == row[3] and area.producer.baseCycle == row[4], `D{index} producer {row[3]}`)
		check(area.producer.costGrowth == 1.2, `D{index} costGrowth 1.2`)
	end
	local targets = economy.Pacing.TargetMinutes
	local total = 0
	for index, minutes in { 10, 18, 24, 28, 32, 38 } do
		check(targets[index] == minutes, `D{index} target {minutes} min`)
		total += minutes
	end
	check(total == 150 and economy.Pacing.Tolerance == 0.2, "150 min first run, +/-20 %")

	-- Every pad in buy order: id, kind, value, build key (spec §6.2 table).
	local B, M, S, G, U = "Build", "Multiplier", "Speed", "Manager", "Unlock"
	local PADS: { { any } } = {
		{ "d1_stone_bench", B, 0, "D1_StoneBench" },
		{ "d1_torch_wall", B, 0.1, "D1_TorchWall" },
		{ "d1_bone_tools", M, 2, "D1_BoneTools" },
		{ "d1_cave_paintings", B, 0.1, "D1_CavePaintings" },
		{ "d1_fire_pit", M, 3, "D1_FirePit" },
		{ "d1_leaf_bellows", S, 2, "D1_LeafBellows" },
		{ "d1_rocky_raptor", G, nil, "D1_RockyRaptor" },
		{ "d1_log_fence", B, 0.1, "D1_LogFence" },
		{ "d1_open_market", U, nil, "D2_EntryArch" },
		{ "d2_shell_counter", B, 0, "D2_ShellCounter" },
		{ "d2_leaf_awning", B, 0.1, "D2_LeafAwning" },
		{ "d2_coconut_till", M, 2, "D2_CoconutTill" },
		{ "d2_berry_baskets", B, 0.1, "D2_BerryBaskets" },
		{ "d2_totem_sign", M, 3, "D2_TotemSign" },
		{ "d2_mammoth_fan", S, 2, "D2_MammothFan" },
		{ "d2_picnic_logs", B, 0.1, "D2_PicnicLogs" },
		{ "d2_stego_sally", G, nil, "D2_StegoSally" },
		{ "d2_bamboo_fence", B, 0.1, "D2_BambooFence" },
		{ "d2_hire_pteros", U, nil, "D3_EntryArch" },
		{ "d3_nest_tower", B, 0, "D3_NestTower" },
		{ "d3_rope_bridge", B, 0.1, "D3_RopeBridge" },
		{ "d3_parcel_baskets", M, 2, "D3_ParcelBaskets" },
		{ "d3_wind_sock", S, 2, "D3_WindSock" },
		{ "d3_ptero_flock", M, 3, "D3_PteroFlock" },
		{ "d3_treasure_map", M, 4, "D3_TreasureMap" },
		{ "d3_landing_pad", B, 0.1, "D3_LandingPad" },
		{ "d3_captain_ptera", G, nil, "D3_CaptainPtera" },
		{ "d3_tap_springs", U, nil, "D4_EntryArch" },
		{ "d4_geyser_vent", B, 0, "D4_GeyserVent" },
		{ "d4_bamboo_pipes", B, 0.1, "D4_BambooPipes" },
		{ "d4_water_wheel", M, 2, "D4_WaterWheel" },
		{ "d4_steam_whistles", B, 0.1, "D4_SteamWhistles" },
		{ "d4_hot_springs", M, 3, "D4_HotSprings" },
		{ "d4_pressure_valves", S, 2, "D4_PressureValves" },
		{ "d4_mega_geyser", M, 4, "D4_MegaGeyser" },
		{ "d4_para_pete", G, nil, "D4_ParaPete" },
		{ "d4_stone_steps", B, 0.1, "D4_StoneSteps" },
		{ "d4_build_lab", U, nil, "D5_EntryArch" },
		{ "d5_lab_hut", B, 0, "D5_LabHut" },
		{ "d5_amber_jars", B, 0.1, "D5_AmberJars" },
		{ "d5_microscope", M, 2, "D5_Microscope" },
		{ "d5_incubators", M, 2, "D5_Incubators" },
		{ "d5_dusting_brushes", S, 2, "D5_DustingBrushes" },
		{ "d5_skeleton", M, 3, "D5_Skeleton" },
		{ "d5_dig_site", B, 0.1, "D5_DigSite" },
		{ "d5_dr_trike", G, nil, "D5_DrTrike" },
		{ "d5_museum_banners", B, 0.1, "D5_MuseumBanners" },
		{ "d5_wake_volcano", U, nil, "D6_EntryArch" },
		{ "d6_volcano_core", B, 0, "D6_VolcanoCore" },
		{ "d6_lava_channel", B, 0.1, "D6_LavaChannel" },
		{ "d6_stone_turbines", M, 2, "D6_StoneTurbines" },
		{ "d6_steam_vents", B, 0.1, "D6_SteamVents" },
		{ "d6_magma_pumps", S, 2, "D6_MagmaPumps" },
		{ "d6_crystal_core", M, 3, "D6_CrystalCore" },
		{ "d6_lava_falls", M, 2, "D6_LavaFalls" },
		{ "d6_sky_bridge", B, 0.1, "D6_SkyBridge" },
		{ "d6_obsidian_crown", M, 5, "D6_ObsidianCrown" },
		{ "d6_chief_tyra", G, nil, "D6_ChiefTyra" },
		{ "d6_golden_trex", U, nil, "D6_GoldenTRex" },
	}
	check(#economy.PadOrder == 59 and #PADS == 59, "59 pads")
	local perArea = { 9, 10, 9, 10, 10, 11 }
	for index, count in perArea do
		check(#economy.AreaPads[index] == count, `D{index} has {count} pads`)
	end
	for position, row in PADS do
		local pad = economy.PadOrder[position]
		check(pad.id == row[1], `pad #{position} is {row[1]} (got {pad.id})`)
		check(pad.kind == row[2] and pad.value == row[3] and pad.build == row[4], `{row[1]} kind / value / build`)
	end
	check(economy.FinalePadId == "d6_golden_trex" and economy.FeaturePadOf.Rebirth == "d6_golden_trex", "finale")
	local features = 0
	for _ in economy.FeaturePadOf do
		features += 1
	end
	check(
		features == 1 and economy.AllowedFeatures.Rebirth == true and economy.AllowedFeatures.AATower == nil,
		"features"
	)
	check(economy.PadsById.d1_stone_bench.cost == 0, "the Stone Bench is free")
	for index = 2, 6 do
		local prevPads = economy.AreaPads[index - 1]
		check(economy.AreaPads[index][1].requires == prevPads[#prevPads].id, `D{index} chains from D{index - 1}`)
		check(prevPads[#prevPads].unlocks == index, `D{index - 1} Unlock opens D{index}`)
	end
	local managers = 0
	for _ in economy.ManagerPadOf do
		managers += 1
	end
	check(managers == 6, "6 managers")
	-- Prices strictly rise along every Dino area; costs live in the same structure as Nuke Town.
	for _, area in economy.Areas do
		-- Builder = 10 x SCALE and baseCost = 3 x SCALE, each rounded to 2 significant digits.
		local ratio = area.pads[1].cost / (area.producer.baseCost / 3)
		check(area.index == 1 or math.abs(ratio / 10 - 1) < 0.06, `D{area.index} builder 10 x SCALE ({ratio})`)
		for position = 2, #area.pads do
			check(area.pads[position].cost > area.pads[position - 1].cost, `{area.pads[position].id} price rises`)
		end
	end

	-- Amber track (spec §6.4).
	local rebirth = dino.rebirth
	check(rebirth.BonusPerRebirth == 0.5 and rebirth.MaxRebirths >= 1, "+50 % Bones per Dino rebirth")
	check(rebirth.Tokens.Base == 10 and rebirth.Tokens.LevelsPerToken == 25, "Amber = 10 + levels / 25")
	check(rebirth.Tokens.GrowthPerRebirth == 0.1, "Amber +10 % per previous Dino rebirth")
	local SHOP = {
		{ "clickPower", "Mighty Roar", 10, 3, 1.45 },
		{ "managerSpeed", "Speedy Raptors", 10, 3, 1.5 },
		{ "startingCash", "Bone Stash", 4, 4, 2.2 },
		{ "rebirthPower", "Golden Amber", 10, 5, 1.6 },
	}
	check(#rebirth.ShopOrder == 4, "4 Amber upgrades")
	for index, row in SHOP do
		local upgrade = rebirth.Shop[row[1]]
		check(rebirth.ShopOrder[index] == row[1], `ShopOrder[{index}] = {row[1]}`)
		check(upgrade.name == row[2] and upgrade.maxLevel == row[3], `{row[1]} name / max`)
		check(upgrade.baseCost == row[4] and upgrade.costGrowth == row[5], `{row[1]} cost curve`)
	end
	check(rebirth.Shop.clickPower.perLevel == 0.1 and rebirth.Shop.managerSpeed.perLevel == 0.1, "+10 % per level")
	check(rebirth.Shop.rebirthPower.perLevel == 0.05, "Golden Amber +5 %")
	-- Bone Stash = the (tuned) Unlock prices of D1..D4 — the Bones that open D2..D5.
	local stash = rebirth.Shop.startingCash.values
	for level = 1, 4 do
		local pads = economy.AreaPads[level]
		check(stash[level] == pads[#pads].cost, `Bone Stash {level} = the price that opens D{level + 1}`)
	end
	check(table.isfrozen(rebirth) and table.isfrozen(rebirth.Shop) and table.isfrozen(stash), "Amber track frozen")
end

--------------------------------------------------------------------------------------------------
-- Moon Base = R69–R71 spec §2.1 / §2.2 (World 3, added the §18 way: config + art only)
--------------------------------------------------------------------------------------------------
do
	local moon = WorldsConfig.get("moon")
	local dino = WorldsConfig.get("dino")
	local economy = moon.economy
	check(moon.name == "Moon Base" and moon.order == 3 and moon.idPrefix == "m", "Moon identity")
	check(moon.tagline == "Blast off and build a nuke empire on the Moon!", "Moon tagline")
	local rocks, shards = moon.currency, moon.tokens
	check(rocks.key == "moonrocks" and rocks.name == "Moon Rocks" and rocks.icon == "MoonRocks", "Moon Rocks")
	check(rocks.style == "count" and rocks.color == Color3.fromRGB(196, 180, 255), "Moon Rocks style + colour")
	check(shards.key == "starshards" and shards.name == "Star Shards" and shards.icon == "StarShards", "Star Shards")
	check(shards.color == Color3.fromRGB(120, 230, 255), "Star Shards colour")
	local geometry = moon.geometry
	check(geometry.origin.Position == Vector3.new(-6000, 0, 0) and geometry.areaCount == 6, "Moon origin + areas")
	check(geometry.plotLength == 312 and geometry.finaleArea == 6 and geometry.finaleHeight == 140, "Moon plot")
	check(geometry.boundaryRadius == 650 and geometry.sceneryRadius == 950, "Moon radii")
	check(WorldGeometry.gap(WorldGeometry.get("main"), geometry) == 3050, "Moon 3050 studs past Nuke Town's sea")
	local unlock = moon.unlock
	check(
		unlock.kind == "progress" and unlock.world == "main" and unlock.area == 5 and unlock.orRebirths == 1,
		"unlock"
	)
	local link = moon.link
	check(link.toMainPerRebirth == 0.1 and link.toMainMaxRebirths == 20, "Moon link to main 10 % x 20")
	check(link.fromMainPerRebirth == 0.05 and link.fromMainMaxRebirths == 10, "Moon link from main 5 % x 10")
	for _, key in { "tutorial", "knockdown", "standName", "attack", "leaderstats" } do
		check(moon.features[key] == false, `Moon has no {key}`)
	end
	check(
		moon.layoutFolder[1] == "Worlds" and moon.layoutFolder[2] == "Moon" and moon.layoutFolder[3] == "Layouts",
		"art"
	)
	check(moon.hubLayout[2] == "Moon" and moon.hubLayout[3] == "MoonHubLayout" and moon.portalAnchor == "moon", "hub")
	check(moon.ambience.lighting == "moon" and moon.ambience.music == "music_moon_base", "Moon ambience")
	check(#moon.eggs == 2 and moon.eggs[1] == "moon_egg" and moon.eggs[2] == "comet_egg", "Moon eggs")

	-- Areas, producers, cycles, pacing.
	local AREAS = {
		{ "crater_camp", "Crater Camp", "mp1_rock_bench", 1 },
		{ "cosmic_diner", "Cosmic Diner", "mp2_cosmic_diner", 1.5 },
		{ "ufo_delivery", "UFO Delivery", "mp3_ufo_express", 2 },
		{ "asteroid_mine", "Asteroid Mine", "mp4_asteroid_drill", 2.5 },
		{ "star_lab", "Star Lab", "mp5_star_lab", 3.5 },
		{ "star_reactor", "Star Reactor", "mp6_star_core", 5 },
	}
	for index, row in AREAS do
		local area = economy.Areas[index]
		check(area.id == row[1] and area.name == row[2], `M{index} is {row[2]}`)
		check(area.producer.id == row[3] and area.producer.baseCycle == row[4], `M{index} producer {row[3]}`)
	end
	local total = 0
	for index, minutes in { 10, 18, 24, 28, 32, 38 } do
		check(economy.Pacing.TargetMinutes[index] == minutes, `M{index} target {minutes} min`)
		total += minutes
	end
	check(total == 150 and economy.Pacing.Tolerance == 0.2, "Moon 150 min first run, +/-20 %")

	-- Every pad id + build key in buy order (spec §2.2 — fixed contracts the art is built to).
	local PADS: { { string } } = {
		{ "m1_capsule_bench", "M1_CapsuleBench" },
		{ "m1_crater_lamps", "M1_CraterLamps" },
		{ "m1_moon_tools", "M1_MoonTools" },
		{ "m1_flag_pole", "M1_FlagPole" },
		{ "m1_solar_panels", "M1_SolarPanels" },
		{ "m1_air_pump", "M1_AirPump" },
		{ "m1_bleep_bot", "M1_BleepBot" },
		{ "m1_crater_rail", "M1_CraterRail" },
		{ "m1_open_diner", "M2_EntryArch" },
		{ "m2_diner_counter", "M2_DinerCounter" },
		{ "m2_neon_sign", "M2_NeonSign" },
		{ "m2_star_register", "M2_StarRegister" },
		{ "m2_booth_seats", "M2_BoothSeats" },
		{ "m2_rocket_jukebox", "M2_RocketJukebox" },
		{ "m2_shake_machine", "M2_ShakeMachine" },
		{ "m2_crater_tables", "M2_CraterTables" },
		{ "m2_zip_zorp", "M2_ZipZorp" },
		{ "m2_landing_lights", "M2_LandingLights" },
		{ "m2_call_ufos", "M3_EntryArch" },
		{ "m3_saucer_dock", "M3_SaucerDock" },
		{ "m3_tractor_beam", "M3_TractorBeam" },
		{ "m3_parcel_pods", "M3_ParcelPods" },
		{ "m3_radar_dish", "M3_RadarDish" },
		{ "m3_ufo_fleet", "M3_UfoFleet" },
		{ "m3_star_map", "M3_StarMap" },
		{ "m3_launch_ring", "M3_LaunchRing" },
		{ "m3_captain_glorp", "M3_CaptainGlorp" },
		{ "m3_mine_asteroids", "M4_EntryArch" },
		{ "m4_drill_rig", "M4_DrillRig" },
		{ "m4_tether_cables", "M4_TetherCables" },
		{ "m4_ore_carts", "M4_OreCarts" },
		{ "m4_crystal_sorter", "M4_CrystalSorter" },
		{ "m4_gravity_magnets", "M4_GravityMagnets" },
		{ "m4_laser_drills", "M4_LaserDrills" },
		{ "m4_mega_asteroid", "M4_MegaAsteroid" },
		{ "m4_drillbert", "M4_Drillbert" },
		{ "m4_hover_steps", "M4_HoverSteps" },
		{ "m4_build_star_lab", "M5_EntryArch" },
		{ "m5_lab_dome", "M5_LabDome" },
		{ "m5_star_jars", "M5_StarJars" },
		{ "m5_big_telescope", "M5_BigTelescope" },
		{ "m5_planet_mobile", "M5_PlanetMobile" },
		{ "m5_comet_catcher", "M5_CometCatcher" },
		{ "m5_robot_arm", "M5_RobotArm" },
		{ "m5_moon_garden", "M5_MoonGarden" },
		{ "m5_dr_nova", "M5_DrNova" },
		{ "m5_mission_banners", "M5_MissionBanners" },
		{ "m5_light_star", "M6_EntryArch" },
		{ "m6_star_core", "M6_StarCore" },
		{ "m6_plasma_pipes", "M6_PlasmaPipes" },
		{ "m6_orbit_rings", "M6_OrbitRings" },
		{ "m6_beam_towers", "M6_BeamTowers" },
		{ "m6_coolant_pumps", "M6_CoolantPumps" },
		{ "m6_nebula_core", "M6_NebulaCore" },
		{ "m6_meteor_falls", "M6_MeteorFalls" },
		{ "m6_star_bridge", "M6_StarBridge" },
		{ "m6_galaxy_crown", "M6_GalaxyCrown" },
		{ "m6_commander_lux", "M6_CommanderLux" },
		{ "m6_golden_astronaut", "M6_GoldenAstronaut" },
	}
	check(#economy.PadOrder == 59 and #PADS == 59, "Moon has 59 pads")
	-- Pad kinds mirror Dino Valley pad-for-pad (spec §2.2), so the pricing structure is identical:
	-- same kinds, values, SCALE multiples (cost / baseCost) and Unlock targets at every position.
	for position, row in PADS do
		local pad = economy.PadOrder[position]
		local twin = dino.economy.PadOrder[position]
		check(pad.id == row[1] and pad.build == row[2], `Moon pad #{position} is {row[1]} / {row[2]}`)
		check(
			pad.kind == twin.kind and pad.value == twin.value and pad.unlocks == twin.unlocks,
			`{pad.id} mirrors {twin.id}`
		)
		check(pad.feature == twin.feature and pad.area == twin.area, `{pad.id} area / feature mirror {twin.id}`)
		check(#pad.blurb > 0 and #pad.blurb <= 40 and string.find(pad.blurb, "Bones") == nil, `{pad.id} Moon blurb`)
		local moonUnit = economy.Areas[pad.area].producer.baseCost
		local dinoUnit = dino.economy.Areas[twin.area].producer.baseCost
		check(near(pad.cost / moonUnit, twin.cost / dinoUnit), `{pad.id} costs the same SCALE multiple as {twin.id}`)
	end
	check(
		economy.FinalePadId == "m6_golden_astronaut" and economy.FeaturePadOf.Rebirth == economy.FinalePadId,
		"finale"
	)
	check(
		economy.AllowedFeatures.Rebirth == true and economy.AllowedFeatures.AATower == nil,
		"Moon only allows Rebirth"
	)
	for _, producer in economy.Producers do
		check(economy.ManagerPadOf[producer.id] ~= nil, `{producer.id} has a Manager`)
	end

	-- Star Shard track (spec §2.1): Dino's curves, Moon names.
	local rebirth = moon.rebirth
	check(rebirth ~= dino.rebirth and rebirth.BonusPerRebirth == 0.5, "+50 % Moon Rocks per Moon rebirth")
	check(
		rebirth.Tokens.Base == 10 and rebirth.Tokens.LevelsPerToken == 25 and rebirth.Tokens.GrowthPerRebirth == 0.1,
		"Star Shards formula"
	)
	local NAMES = {
		clickPower = "Rocket Fuel",
		managerSpeed = "Turbo Bots",
		startingCash = "Rock Stash",
		rebirthPower = "Supernova",
	}
	for index, key in rebirth.ShopOrder do
		local upgrade, twin = rebirth.Shop[key], dino.rebirth.Shop[key]
		check(
			key == dino.rebirth.ShopOrder[index] and upgrade.name == NAMES[key],
			`Star Shard shop {key} = {NAMES[key]}`
		)
		check(upgrade.maxLevel == twin.maxLevel and upgrade.baseCost == twin.baseCost, `{key} same curve as Dino`)
		check(upgrade.costGrowth == twin.costGrowth and upgrade.perLevel == twin.perLevel, `{key} same effect as Dino`)
	end
	local stash = rebirth.Shop.startingCash.values
	for level = 1, 4 do
		local pads = economy.AreaPads[level]
		check(stash[level] == pads[#pads].cost, `Rock Stash {level} = the price that opens M{level + 1}`)
	end
	check(table.isfrozen(rebirth) and table.isfrozen(rebirth.Shop) and table.isfrozen(stash), "Star Shard track frozen")
end

--------------------------------------------------------------------------------------------------
-- Unlock rule (spec §4.1) and link maths (spec §6.5)
--------------------------------------------------------------------------------------------------
do
	local main = WorldsConfig.get("main")
	local dino = WorldsConfig.get("dino")
	check(WorldsConfig.unlockPasses(main, {}) and WorldsConfig.unlockPasses(main, nil :: any), "main always open")
	local TRUTH: { { any } } = {
		{ { main = { area = 1, rebirths = 0 } }, false },
		{ { main = { area = 2, rebirths = 0 } }, false },
		{ { main = { area = 3, rebirths = 0 } }, true },
		{ { main = { area = 10, rebirths = 0 } }, true },
		{ { main = { area = 1, rebirths = 1 } }, true },
		{ { main = { area = 2.9, rebirths = 0.9 } }, false },
		{ { main = { area = NAN, rebirths = NAN } }, false },
		{ { main = { area = INF, rebirths = -INF } }, false },
		{ { main = { area = "3", rebirths = "1" } }, false },
		{ { main = "x" }, false },
		{ { dino = { area = 6, rebirths = 9 } }, false },
		{ {}, false },
	}
	for index, row in TRUTH do
		check(WorldsConfig.unlockPasses(dino, row[1]) == row[2], `unlock truth row {index}`)
	end
	check(
		not WorldsConfig.unlockPasses(dino, nil :: any) and not WorldsConfig.unlockPasses(dino, "x" :: any),
		"garbage"
	)

	-- Nuke Town: +10 % per Dino rebirth up to 20 (x3.0); Dino: +5 % per Nuke Town rebirth up to 10 (x1.5).
	local previousMain, previousDino = 1, 1
	for rebirths = 0, 40 do
		local toMain = WorldsConfig.linkCash("main", { dino = rebirths, main = 999 })
		local toDino = WorldsConfig.linkCash("dino", { main = rebirths, dino = 999 })
		check(near(toMain, 1 + 0.1 * math.min(rebirths, 20)), `main link at {rebirths} Dino rebirths`)
		check(near(toDino, 1 + 0.05 * math.min(rebirths, 10)), `dino link at {rebirths} main rebirths`)
		check(toMain >= previousMain and toDino >= previousDino and toMain >= 1 and toDino >= 1, "link monotonic")
		previousMain, previousDino = toMain, toDino
	end
	check(
		near(WorldsConfig.linkCash("main", { dino = 1e9 }), 3)
			and near(WorldsConfig.linkCash("dino", { main = 1e9 }), 1.5),
		"caps"
	)
	check(near(WorldsConfig.linkCash("main", { dino = 3 }), 1.3), "spec: 3 Dino rebirths = +30 % Nuke Town cash")
	check(near(WorldsConfig.linkCash("dino", { main = 5 }), 1.25), "spec: 5 Nuke Town rebirths = +25 % Bones")
	for _, bad in { NAN, INF, -INF, -3, "5", true, {} } do
		check(WorldsConfig.linkCash("main", { dino = bad :: any }) == 1, `main link hostile {tostring(bad)}`)
		check(WorldsConfig.linkCash("dino", { main = bad :: any }) == 1, `dino link hostile {tostring(bad)}`)
	end
	check(
		WorldsConfig.linkCash("main", nil :: any) == 1 and WorldsConfig.linkCash("dino", "x" :: any) == 1,
		"garbage map"
	)
	check(WorldsConfig.linkCash("nope", { main = 5 }) == 1, "unknown world link 1")
	check(near(WorldsConfig.linkCash("dino", { main = 2.7 }), 1.1), "fractional rebirths floor")

	-- R70 (three worlds): Moon Base opens at Nuke Town area 5 OR 1 rebirth.
	local moon = WorldsConfig.get("moon")
	local MOON_TRUTH: { { any } } = {
		{ { main = { area = 3, rebirths = 0 } }, false },
		{ { main = { area = 4, rebirths = 0 } }, false },
		{ { main = { area = 5, rebirths = 0 } }, true },
		{ { main = { area = 1, rebirths = 1 } }, true },
		{ { main = { area = 4.9, rebirths = 0 } }, false },
		{ { dino = { area = 6, rebirths = 5 } }, false },
		{ { moon = { area = 6, rebirths = 5 } }, false },
	}
	for index, row in MOON_TRUTH do
		check(WorldsConfig.unlockPasses(moon, row[1]) == row[2], `moon unlock truth row {index}`)
	end
	-- Nuke Town's link SUMS every world's link (spec §2.1): Dino + Moon, each capped at 20 rebirths,
	-- up to x5.0; each extra world's own link only counts Nuke Town's rebirths (never each other's).
	check(near(WorldsConfig.linkCash("main", { dino = 3, moon = 2 }), 1.5), "main link = 1 + 0.1 x (3 + 2)")
	check(near(WorldsConfig.linkCash("main", { dino = 1e9, moon = 1e9 }), 5), "main link caps at x5.0 with two worlds")
	check(near(WorldsConfig.linkCash("moon", { main = 4, dino = 50 }), 1.2), "moon link = Nuke Town rebirths only")
	check(near(WorldsConfig.linkCash("moon", { main = 1e9 }), 1.5), "moon link caps at x1.5")
	check(
		WorldsConfig.linkCash("dino", { main = 0, moon = 50 }) == 1
			and WorldsConfig.linkCash("moon", { dino = 50 }) == 1,
		"extra worlds never boost each other"
	)
	for dinoCount = 0, 22, 2 do
		local previous = 0
		for moonCount = 0, 22 do
			local value = WorldsConfig.linkCash("main", { dino = dinoCount, moon = moonCount })
			check(value >= previous and value >= 1, `main link monotonic ({dinoCount} Dino, {moonCount} Moon)`)
			previous = value
		end
	end
end

if #pending > 0 then
	print("worlds-config: waiting on other builders (not failures):\n  " .. table.concat(pending, "\n  "))
end
print(`worlds-config: {checks} checks passed`)
