--!strict
--[[
	EconomyIndex — builds, validates and freezes ONE world's tycoon economy (World 2 plan §3.1).

	Purpose
		Every world (Nuke Town, Dino Valley, World 3 ...) is the same kind of linear button tycoon:
		areas with one producer each and a single chain of pads. This module turns a world's raw
		area modules (`EconomySpec`) into the read-only lookup tables the logic and every system
		use (`EconomyIndex`) — exactly the fields `TycoonConfig` has always exposed, so the Nuke Town
		economy built here is bit-identical to the one that shipped (tests/economy-index.luau).

	What `build` produces (all frozen):
		Areas            {AreaConfig}                 areas 1..N in order
		PadOrder         {PadConfig}                  every pad of the world in its one linear chain
		PadsById         {[padId]: PadConfig}
		PadIndex         {[padId]: number}            position in PadOrder (1-based)
		Producers        {ProducerConfig}             one per area, in area order
		ProducersById    {[producerId]: ProducerConfig}
		PadsByTarget     {[producerId]: {PadConfig}}  Build / Multiplier / Speed / Manager pads per producer
		ManagerPadOf     {[producerId]: padId}        the pad that automates each producer
		ProducerBuiltBy  {[padId]: producerId}        the pad that builds (level 1) each producer
		AreaPads         {[area]: {PadConfig}}
		FeaturePadOf     {[FeatureKey]: padId}        which pad unlocks StandRename / AATower / ...
		FinalePadId      string                       the pad whose feature is "Rebirth"
		BuildKeys        {[buildKey]: padId}          every pad's build key (unique in the world)
		WorldId, IdPrefix, PadPrefix, ProducerPrefix, BuildPrefix, Pacing, AllowedFeatures
		+ the shared tunables (MilestoneEvery, MilestoneFactor, CycleFloor, MaxLevel, MaxBulkLevels,
		  Offline, Modifiers) — the SAME table refs as TycoonConfig's.

	Validation (errors loudly in Studio and in the lune tests, never silently):
		* unique pad / producer / build-key ids; the `requires` chain is exactly the linear order;
		* every producer has exactly one builder pad (its area's first pad) and one Manager pad;
		* numeric fields finite and in range; kinds carry the fields they need;
		* id rules (spec §6.2) — with p = the pad prefix ("a" for Nuke Town's legacy ids, else the
		  world's one-letter idPrefix) and P = upper(p):
		    pads       ^p<area>_[a-z0-9_]+$          ("d3_wind_sock")
		    producers  ^<idPrefix>p<area>_[a-z0-9_]+$ ("dp3_ptero_express"; Nuke Town "p3_boomdash")
		    build keys ^P<area>_%u%w*$                ("D3_WindSock"); an Unlock pad builds the NEXT
		               area's "P<area+1>_EntryArch"
		* features: only the world's `allowedFeatures`; the finale (last area's Unlock) is "Rebirth";
		* the spec's areas are not frozen yet (a second build of the same area tables would mean two
		  worlds share records — a config bug).

	Friendly prices: every pad cost and producer baseCost is rounded at build to 2 significant
	digits (`friendlyPrice`), so billboards read "$73M", not "$72,913,402".

	Connections
		* Types: `Shared/Tycoon/TycoonTypes` (EconomySpec, EconomyIndex, EconomyTunables).
		* Built by `Shared/Config/TycoonConfig` (Nuke Town, worldId "main", idPrefix "") and by each
		  `Shared/Config/Worlds/<Name>/<Name>World` (Dino: worldId "dino", idPrefix "d").
		* Consumed by `Shared/Tycoon/TycoonLogic.bind` (one Logic per world) and every system through
		  `WorldsConfig.Worlds[id].economy`.

	Usage
		local EconomyIndex = require(ReplicatedStorage.Shared.Tycoon.EconomyIndex)
		local index = EconomyIndex.build({
			worldId = "dino", idPrefix = "d", areas = { Area01, Area02 },
			pacing = { TargetMinutes = { 10, 18 }, Tolerance = 0.2 },
			allowedFeatures = { Rebirth = true }, tunables = TycoonConfig.Tunables,
		})
		print(index.PadsById.d1_torch_wall.cost)
]]

local TycoonTypes = require(script.Parent.TycoonTypes)

type AreaConfig = TycoonTypes.AreaConfig
type PadConfig = TycoonTypes.PadConfig
type ProducerConfig = TycoonTypes.ProducerConfig

export type EconomySpec = TycoonTypes.EconomySpec
export type EconomyIndex = TycoonTypes.EconomyIndex
export type EconomyTunables = TycoonTypes.EconomyTunables

local EconomyIndex = {}

-- Every FeatureKey the game knows (TycoonTypes.FeatureKey); a world allows a subset.
EconomyIndex.FeatureKeys = table.freeze({
	StandRename = true,
	AATower = true,
	AttackConsole = true,
	Rebirth = true,
}) :: { [string]: boolean }

-- Letters a non-main world may NOT use as its idPrefix: Nuke Town's legacy pad ("a") and
-- producer ("p") letters, so a bare id always names exactly one world.
EconomyIndex.ReservedPrefixes = table.freeze({ a = true, p = true }) :: { [string]: boolean }

-- Kinds that act on a producer and therefore need `target`.
local TARGETED_KINDS = { Build = true, Multiplier = true, Speed = true, Manager = true }

--[[
	Rounds a price to 2 significant digits (rounding half up), keeping 0 at 0.
	Why: costs are written as SCALE multiples tuned by the simulator; rounding at load gives
	friendly billboard prices without hand-editing every tuned number.
	@param x number — raw price (>= 0)
	@return number — the friendly price
	Example: EconomyIndex.friendlyPrice(72913402) --> 73000000; friendlyPrice(4) --> 4
]]
function EconomyIndex.friendlyPrice(x: number): number
	if x <= 0 then
		return 0
	end
	-- Keep 2 significant digits: scale so the value sits in [10, 100), round, scale back.
	local magnitude = 10 ^ (math.floor(math.log10(x)) - 1)
	local rounded = math.floor(x / magnitude + 0.5) * magnitude
	-- Values under 100 are already whole-number friendly at 2 digits; avoid 4.0000000001 noise.
	if rounded >= 1 then
		rounded = math.floor(rounded + 0.5)
	end
	return rounded
end

--[[
	The id prefixes of a world: pad letter, producer prefix and build-key letter.
	@param idPrefix string — "" (Nuke Town legacy) or one lowercase letter
	@return string, string, string — pad prefix ("a" / "d"), producer prefix ("p" / "dp"),
	        build prefix ("A" / "D")
	Example: EconomyIndex.prefixes("d") --> "d", "dp", "D"
]]
function EconomyIndex.prefixes(idPrefix: string): (string, string, string)
	local padPrefix = if idPrefix == "" then "a" else idPrefix
	return padPrefix, idPrefix .. "p", string.upper(padPrefix)
end

--[[
	Builds every lookup table of one world, rounds prices, validates the whole economy and
	deep-freezes it. Runs once per world at require time; any error is a config bug and stops the
	game from booting with bad data.
	@param spec EconomySpec — the world's raw areas + id rules + shared tunables
	@return EconomyIndex
]]
function EconomyIndex.build(spec: EconomySpec): EconomyIndex
	local worldId = spec.worldId
	local tag = `EconomyIndex({worldId})`
	local tunables = spec.tunables

	-- Asserts a config number is finite and inside [lo, hi]; errors with a readable path otherwise.
	local function checkNumber(value: any, lo: number, hi: number, what: string)
		assert(type(value) == "number" and value == value, `{tag}: {what} must be a number`)
		assert(value >= lo and value <= hi, `{tag}: {what} = {value} outside [{lo}, {hi}]`)
	end

	-- World identity and id rules.
	assert(type(worldId) == "string" and string.match(worldId, "^[a-z][a-z0-9]*$") ~= nil, `{tag}: bad worldId`)
	local idPrefix = spec.idPrefix
	assert(
		idPrefix == "" or (string.match(idPrefix, "^[a-z]$") ~= nil and not EconomyIndex.ReservedPrefixes[idPrefix]),
		`{tag}: idPrefix must be "" (Nuke Town) or one lowercase letter other than a / p`
	)
	local padPrefix, producerPrefix, buildPrefix = EconomyIndex.prefixes(idPrefix)
	for feature, allowed in spec.allowedFeatures do
		assert(EconomyIndex.FeatureKeys[feature] == true and allowed == true, `{tag}: unknown feature {feature}`)
	end
	assert(spec.allowedFeatures.Rebirth == true, `{tag}: every world's finale unlocks "Rebirth"`)
	assert(#spec.areas >= 1, `{tag}: needs at least one area`)
	assert(#spec.pacing.TargetMinutes == #spec.areas, `{tag}: one pacing target per area`)
	for index, minutes in spec.pacing.TargetMinutes do
		checkNumber(minutes, 0.1, 10000, `Pacing.TargetMinutes[{index}]`)
	end
	checkNumber(spec.pacing.Tolerance, 0, 1, "Pacing.Tolerance")

	local index: EconomyIndex = {
		WorldId = worldId,
		IdPrefix = idPrefix,
		PadPrefix = padPrefix,
		ProducerPrefix = producerPrefix,
		BuildPrefix = buildPrefix,
		Areas = spec.areas,
		PadOrder = {},
		PadsById = {},
		PadIndex = {},
		Producers = {},
		ProducersById = {},
		PadsByTarget = {},
		ManagerPadOf = {},
		ProducerBuiltBy = {},
		AreaPads = {},
		FeaturePadOf = {},
		FinalePadId = "",
		Pacing = spec.pacing,
		AllowedFeatures = spec.allowedFeatures,
		BuildKeys = {},
		MilestoneEvery = tunables.MilestoneEvery,
		MilestoneFactor = tunables.MilestoneFactor,
		CycleFloor = tunables.CycleFloor,
		MaxLevel = tunables.MaxLevel,
		MaxBulkLevels = tunables.MaxBulkLevels,
		Offline = tunables.Offline,
		Modifiers = tunables.Modifiers,
	}

	local areaCount = #spec.areas
	local previousPadId: string? = nil
	for areaIndex, area in spec.areas do
		assert(not table.isfrozen(area), `{tag}: area {areaIndex} was already built (shared area tables?)`)
		assert(area.index == areaIndex, `{tag}: Areas[{areaIndex}] has index {area.index}`)
		local producer = area.producer
		assert(producer.area == areaIndex, `{tag}: producer {producer.id} area mismatch`)
		assert(index.ProducersById[producer.id] == nil, `{tag}: duplicate producer {producer.id}`)
		assert(
			string.match(producer.id, `^{producerPrefix}{areaIndex}_[a-z0-9_]+$`) ~= nil,
			`{tag}: producer id {producer.id} must match {producerPrefix}{areaIndex}_name`
		)
		producer.baseCost = EconomyIndex.friendlyPrice(producer.baseCost)
		checkNumber(producer.baseCost, 1e-9, 1e200, `{producer.id}.baseCost`)
		-- costGrowth in (1, 2]: > 1 so maxAffordable's closed form is defined; <= 2 keeps
		-- costGrowth^MaxLevel far inside double range.
		checkNumber(producer.costGrowth, 1.000001, 2, `{producer.id}.costGrowth`)
		checkNumber(producer.baseRevenue, 1e-9, 1e200, `{producer.id}.baseRevenue`)
		checkNumber(producer.baseCycle, tunables.CycleFloor, 3600, `{producer.id}.baseCycle`)
		table.insert(index.Producers, producer)
		index.ProducersById[producer.id] = producer
		index.PadsByTarget[producer.id] = {}

		local areaPads: { PadConfig } = {}
		index.AreaPads[areaIndex] = areaPads
		assert(#area.pads >= 2, `{tag}: area {areaIndex} needs at least a builder and an Unlock pad`)
		for padPosition, pad in area.pads do
			assert(index.PadsById[pad.id] == nil, `{tag}: duplicate pad id {pad.id}`)
			assert(pad.area == areaIndex, `{tag}: pad {pad.id} area {pad.area} ~= {areaIndex}`)
			assert(
				string.match(pad.id, `^{padPrefix}{areaIndex}_[a-z0-9_]+$`) ~= nil,
				`{tag}: pad id {pad.id} must match {padPrefix}{areaIndex}_name`
			)
			assert(pad.requires == previousPadId, `{tag}: pad {pad.id} must require {previousPadId}`)
			assert(type(pad.build) == "string" and #pad.build > 0, `{tag}: pad {pad.id} needs a build key`)
			assert(type(pad.blurb) == "string" and #pad.blurb > 0, `{tag}: pad {pad.id} needs a blurb`)
			assert(index.BuildKeys[pad.build] == nil, `{tag}: duplicate build key {pad.build}`)
			-- Build keys name the area they build in; an Unlock pad builds the NEXT area's entry arch.
			local isOpener = pad.kind == "Unlock" and areaIndex < areaCount
			local keyArea = if isOpener then areaIndex + 1 else areaIndex
			assert(
				string.match(pad.build, `^{buildPrefix}{keyArea}_%u%w*$`) ~= nil,
				`{tag}: build key {pad.build} of {pad.id} must match {buildPrefix}{keyArea}_Name`
			)
			if isOpener then
				assert(
					pad.build == `{buildPrefix}{keyArea}_EntryArch`,
					`{tag}: Unlock pad {pad.id} must build {buildPrefix}{keyArea}_EntryArch`
				)
			end
			pad.cost = EconomyIndex.friendlyPrice(pad.cost)
			checkNumber(pad.cost, 0, 1e200, `{pad.id}.cost`)

			if TARGETED_KINDS[pad.kind] then
				assert(pad.target == producer.id, `{tag}: pad {pad.id} must target {producer.id}`)
			end
			if pad.kind == "Build" then
				checkNumber(pad.value or -1, 0, 10, `{pad.id}.value`)
			elseif pad.kind == "Multiplier" or pad.kind == "Speed" then
				checkNumber(pad.value or -1, 1, 1000, `{pad.id}.value`)
			elseif pad.kind == "Manager" then
				assert(index.ManagerPadOf[producer.id] == nil, `{tag}: two Managers for {producer.id}`)
				index.ManagerPadOf[producer.id] = pad.id
			elseif pad.kind == "Unlock" then
				-- The last pad of every area opens the next one; the finale unlocks Rebirth instead.
				assert(padPosition == #area.pads, `{tag}: Unlock pad {pad.id} must be the area's last pad`)
				if areaIndex < areaCount then
					assert(pad.unlocks == areaIndex + 1, `{tag}: {pad.id} must unlock area {areaIndex + 1}`)
				else
					assert(pad.feature == "Rebirth", `{tag}: finale {pad.id} must carry feature "Rebirth"`)
					index.FinalePadId = pad.id
				end
			elseif pad.kind == "Feature" then
				assert(pad.feature ~= nil, `{tag}: Feature pad {pad.id} needs a feature key`)
			else
				error(`{tag}: pad {pad.id} has unknown kind {pad.kind}`)
			end
			if pad.feature ~= nil then
				assert(spec.allowedFeatures[pad.feature] == true, `{tag}: feature {pad.feature} not allowed here`)
				assert(index.FeaturePadOf[pad.feature] == nil, `{tag}: duplicate feature {pad.feature}`)
				index.FeaturePadOf[pad.feature] = pad.id
			end
			if pad.target ~= nil and TARGETED_KINDS[pad.kind] then
				table.insert(index.PadsByTarget[producer.id], pad)
			end

			table.insert(index.PadOrder, pad)
			table.insert(areaPads, pad)
			index.PadsById[pad.id] = pad
			index.PadIndex[pad.id] = #index.PadOrder
			index.BuildKeys[pad.build] = pad.id
			previousPadId = pad.id
		end

		-- The first pad of each area builds that area's producer.
		assert(producer.builtBy == area.pads[1].id, `{tag}: {producer.id} must be built by the first pad`)
		assert(area.pads[1].kind == "Build", `{tag}: {producer.builtBy} must be a Build pad`)
		index.ProducerBuiltBy[producer.builtBy] = producer.id
		assert(index.ManagerPadOf[producer.id] ~= nil, `{tag}: {producer.id} has no Manager pad`)
	end
	assert(index.FinalePadId ~= "", `{tag}: no finale pad`)

	-- Config is static data: deep-freeze every record and lookup so no system can mutate prices or
	-- chains at runtime by accident. (tests/economy-sim.luau --tune patches the area sources'
	-- SCALE before loading instead of mutating these tables.)
	for _, area in index.Areas do
		for _, pad in area.pads do
			table.freeze(pad)
		end
		table.freeze(area.pads)
		table.freeze(area.producer)
		table.freeze(area)
	end
	for _, list in index.PadsByTarget do
		table.freeze(list)
	end
	for _, list in index.AreaPads do
		table.freeze(list)
	end
	table.freeze(index.Areas)
	table.freeze(index.PadOrder)
	table.freeze(index.PadsById)
	table.freeze(index.PadIndex)
	table.freeze(index.Producers)
	table.freeze(index.ProducersById)
	table.freeze(index.PadsByTarget)
	table.freeze(index.ManagerPadOf)
	table.freeze(index.ProducerBuiltBy)
	table.freeze(index.AreaPads)
	table.freeze(index.FeaturePadOf)
	table.freeze(index.BuildKeys)
	if not table.isfrozen(index.AllowedFeatures) then
		table.freeze(index.AllowedFeatures)
	end
	if not table.isfrozen(index.Pacing.TargetMinutes) then
		table.freeze(index.Pacing.TargetMinutes)
	end
	if not table.isfrozen(index.Pacing) then
		table.freeze(index.Pacing)
	end
	return table.freeze(index)
end

return table.freeze(EconomyIndex)
