--!strict
--[[
	World FX audit for Dino Valley (owner R57, W10b): every Dino piece the art builders named for
	motion resolves to the row they asked for (docs/areas-art.md "For W10"), attached pieces move
	as ONE group about the right centre (R25 / R26), the new rows stay inside the R19 glow caps,
	sounds are real SFX keys and FxQuality-budgeted, and Nuke Town's pieces are untouched by every
	new Dino row (main unchanged).

	Checks (all from config, nothing in Studio):
		1. Rows: Flame (light only, flicker, R19 caps), Ears / Sock (oscillate Y), LavaFlow /
		   LavaFall (scroll; faces valid NormalId names), Wobble (bob), Geyser (assembly-only bob
		   with its whoosh), WaterWheel (assembly-only slow spin).
		2. Resolution per Dino model piece (MeshAssets): torches / fire pit / arch torches glow;
		   the mammoth ears, wind sock (+ stripes), incubator eggs (+ speckles), geyser jets
		   (+ foam) and water wheel (+ trim) each form ONE group; lava cracks / streaks and the
		   Valley backdrop's Lava stay still; the routed ptero courier and the six Dino managers
		   are never moved by WorldFx.
		3. Pivots: a rotating group's pieces share the rotation centre (box centres on the axis),
		   so nothing orbits (ears / sock on the vertical axis through the head / pole, wheel and
		   trim on the axle).
		4. Main unchanged: no non-Dino piece resolves to a new Dino row, and Nuke Town's static
		   Column pieces (A6 shells, A9 space elevator) are not geysers.
		5. Sounds: row sounds + model ambience use AudioConfig.Sfx keys, ambience models exist and
		   have an FX group to carry them, MaxSounds rises with the device tier (Low <= 1).

	Run: lune run tests/world-fx.luau
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local WorldFxConfig = loader.load("src/shared/Config/WorldFxConfig")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local AudioConfig = loader.load("src/shared/Config/AudioConfig")
local ManagerNpcConfig = loader.load("src/shared/Config/ManagerNpcConfig")

local checks = 0
local failures: { string } = {}
-- Records one check (keeps going so a run lists every problem).
local function ok(condition: any, label: string)
	checks += 1
	if not condition then
		table.insert(failures, label)
	end
end

local Pieces = WorldFxConfig.Pieces
local Caps = WorldFxConfig.LightCaps

-- The rows this audit introduces (none may reach a non-Dino piece).
local DINO_ROWS = { "Flame", "Ears", "Sock", "LavaFlow", "LavaFall", "Wobble", "Geyser", "WaterWheel", "TimeSwirl" }

-- The piece table of a model (fails the check when the model or piece is missing).
local function piece(modelKey: string, name: string): any
	local asset = MeshAssets[modelKey]
	local found = if asset ~= nil then asset.pieces[name] else nil
	ok(found ~= nil, `MeshAssets.{modelKey}.{name} exists`)
	return found
end

-- 1. Rows ----------------------------------------------------------------------------------------
do
	local flame = Pieces.Flame
	ok(flame ~= nil and flame.motion == "none", "Flame: light only, nothing moves")
	ok(flame ~= nil and flame.light ~= nil and flame.light.flicker == true, "Flame: noisy flicker")
	if flame ~= nil and flame.light ~= nil then
		ok(flame.light.brightness <= Caps.Brightness, "Flame: brightness within R19 cap")
		ok(flame.light.range <= Caps.Range, "Flame: range within R19 cap")
		ok((flame.light.pulse or 0) <= Caps.Pulse, "Flame: pulse within R19 cap")
	end
	for _, name in { "Ears", "Sock" } do
		local row = Pieces[name]
		ok(row ~= nil and row.motion == "oscillate" and row.axis == "Y", `{name}: oscillates about Y`)
		ok(row ~= nil and (row.amplitude or 0) > 0 and (row.period or 0) > 0, `{name}: amplitude + period`)
	end
	for _, name in { "LavaFlow", "LavaFall" } do
		local row = Pieces[name]
		ok(row ~= nil and row.motion == "scroll" and (row.speed or 0) > 0, `{name}: scrolls`)
	end
	ok(Pieces.Lava == nil, "no generic Lava row (cracks / streaks / backdrop lava stay still)")
	local normals = { Top = true, Bottom = true, Front = true, Back = true, Left = true, Right = true }
	for name, row in Pieces do
		if row.faces ~= nil then
			ok(row.motion == "scroll", `{name}: faces only on a scroll row`)
			for _, face in row.faces do
				ok(normals[face] == true, `{name}: face {face} is an Enum.NormalId name`)
			end
		end
	end
	ok(Pieces.Wobble ~= nil and Pieces.Wobble.motion == "bob", "Wobble: eggs bob")
	local geyser = Pieces.Geyser
	ok(geyser ~= nil and geyser.motion == "bob" and geyser.period == 6, "Geyser: bob on a 6 s cycle")
	-- W7: the jets start inside their mounds, so a bob <= 1.5 studs never shows a gap.
	ok(geyser ~= nil and (geyser.amplitude or 0) > 0 and (geyser.amplitude or 0) <= 1.5, "Geyser: amplitude <= 1.5")
	ok(Pieces.WaterWheel ~= nil and Pieces.WaterWheel.motion == "spin", "WaterWheel: spins")
	ok(
		Pieces.WaterWheel ~= nil and (Pieces.WaterWheel.speed or 0) < (Pieces.Wheel.speed or 0),
		"WaterWheel: slower than Nuke Town's Wheel row"
	)
end

-- 2. Resolution per Dino model piece ----------------------------------------------------------------
-- Expect (modelKey, piece) -> canonical row name (via groupFor's row).
local function rowNameOf(modelKey: string, name: string): (string?, string?)
	local group, row = WorldFxConfig.groupFor(modelKey, name)
	if row == nil then
		return group, nil
	end
	for rowName, candidate in Pieces do
		if candidate == row then
			return group, rowName
		end
	end
	return group, "none"
end

local function expectRow(modelKey: string, name: string, wanted: string)
	piece(modelKey, name)
	local _, rowName = rowNameOf(modelKey, name)
	ok(rowName == wanted, `{modelKey}.{name} -> {wanted} (got {rowName})`)
end

local function expectStill(modelKey: string, name: string)
	piece(modelKey, name)
	local group = WorldFxConfig.groupFor(modelKey, name)
	ok(group == nil, `{modelKey}.{name} stays still (got group {group})`)
end

local function expectSameGroup(modelKey: string, names: { string }, wanted: string)
	local first = nil
	for _, name in names do
		piece(modelKey, name)
		local group, rowName = rowNameOf(modelKey, name)
		ok(rowName == wanted, `{modelKey}.{name} -> {wanted} (got {rowName})`)
		first = first or group
		ok(group ~= nil and group == first, `{modelKey}.{name} moves in ONE group with {names[1]}`)
	end
end

for _, name in { "FlameA", "FlameB", "FlameC" } do
	expectRow("D1_TorchWall", name, "Flame")
end
expectRow("D1_FirePit", "FlameOuter", "Flame")
expectRow("D1_FirePit", "FlameInner", "Flame")
expectRow("D5_EntryArch", "Flame", "Flame")
expectRow("D6_EntryArch", "Flame", "Flame")
expectRow("D2_MammothFan", "Ears", "Ears")
expectSameGroup("D3_WindSock", { "Sock", "SockStripes" }, "Sock")
expectRow("D6_LavaChannel", "LavaFlow", "LavaFlow")
expectRow("D6_LavaFalls", "LavaFall", "LavaFall")
expectStill("D6_Floor", "LavaCracks")
expectStill("D6_VolcanoBase", "LavaStreaks")
expectStill("D6_VolcanoTop", "LavaStreaks")
expectStill("Valley_VolcanoBackdrop", "Lava")
expectStill("D5_Skeleton", "Sockets") -- "Sockets" must not read as the wind-sock row
expectSameGroup(
	"D5_Incubators",
	{ "WobbleEggCream", "WobbleEggMint", "WobbleEggSky", "WobbleSpots", "WobbleSpotsAmber" },
	"Wobble"
)
expectSameGroup("D4_GeyserVent", { "Column", "ColumnFoam" }, "Geyser")
expectSameGroup("D4_MegaGeyser", { "Column", "ColumnFoam" }, "Geyser")
expectSameGroup("D4_WaterWheel", { "Wheel", "WheelTrim" }, "WaterWheel")
expectSameGroup("D6_StoneTurbines", { "WheelStone", "WheelHub" }, "Wheel")
-- The Time Machine portal swirl spins (lobby + Base Camp); the shop Teleporter's Swirl stays still.
expectRow("Hub_TimeMachine", "Swirl", "TimeSwirl")
expectStill("Shop_Teleporter", "Swirl")
expectStill("Hub_TimeMachine", "Portal")
-- Routed (VehicleRoutes flaps the wings, R25) and managers (ManagerController, R30).
for _, name in { "Body", "WingL", "WingR", "Parcel" } do
	expectStill("D3_PteroCourier", name)
end
for _, key in ManagerNpcConfig.managerKeysOf("dino") do
	ok(WorldFxConfig.isManager(key), `{key} is a manager (WorldFx keeps off its limbs)`)
	local asset = MeshAssets[key]
	ok(asset ~= nil, `MeshAssets.{key} exists`)
	if asset ~= nil then
		for name in asset.pieces do
			local _, row = WorldFxConfig.groupFor(key, name)
			ok(row == nil or row.motion == "none", `{key}.{name}: never moved by WorldFx`)
		end
	end
end

-- 3. Pivots: rotating groups turn about one shared centre -----------------------------------------
local function centre(modelKey: string, name: string): Vector3?
	local p = piece(modelKey, name)
	return if p ~= nil then p.offset else nil
end
do
	local ears = centre("D2_MammothFan", "Ears")
	ok(ears ~= nil and math.abs(ears.X) < 0.05, "Ears: box centre on the head's vertical axis (x ~ 0)")
	for _, name in { "Sock", "SockStripes" } do
		local c = centre("D3_WindSock", name)
		ok(c ~= nil and math.abs(c.X) < 0.1 and math.abs(c.Z) < 0.1, `{name}: box centre on the pole axis`)
	end
	local wheel, trim = centre("D4_WaterWheel", "Wheel"), centre("D4_WaterWheel", "WheelTrim")
	ok(
		wheel ~= nil and trim ~= nil and math.abs(wheel.Y - trim.Y) < 0.05 and math.abs(wheel.Z - trim.Z) < 0.05,
		"water wheel + trim share the axle (spin about X)"
	)
	local swirl = centre("Hub_TimeMachine", "Swirl")
	ok(
		swirl ~= nil and math.abs(swirl.X) < 0.05 and math.abs(swirl.Y - 10) < 0.05,
		"Time Machine swirl: box centred on the ring centre (0, 10) -> spins about local Z in place"
	)
	local stone, hub = centre("D6_StoneTurbines", "WheelStone"), centre("D6_StoneTurbines", "WheelHub")
	ok(
		stone ~= nil and hub ~= nil and math.abs(stone.Y - hub.Y) < 0.05 and math.abs(stone.Z - hub.Z) < 0.05,
		"stone turbine wheel + hub share the axle"
	)
end

-- 4. Main unchanged ------------------------------------------------------------------------------------
do
	local dinoRow: { [any]: string } = {}
	for _, name in DINO_ROWS do
		if Pieces[name] ~= nil then
			dinoRow[Pieces[name]] = name
		end
	end
	local scanned = 0
	for modelKey, asset in MeshAssets do
		-- Dino Valley art: the D1..D6 areas and the Valley hub scenery.
		local dino = string.match(modelKey, "^D%d_") ~= nil
			or string.match(modelKey, "^Valley_") ~= nil
			or modelKey == "Hub_TimeMachine"
		if not dino then
			for name in asset.pieces do
				scanned += 1
				local _, row = WorldFxConfig.groupFor(modelKey, name)
				if row ~= nil and dinoRow[row] ~= nil then
					ok(false, `{modelKey}.{name} (not Dino) resolves to the Dino row {dinoRow[row]}`)
				end
			end
		end
	end
	ok(scanned > 500, `main scan covered the Nuke Town / hub models ({scanned} pieces)`)
	for _, key in { "A6_ShellBack", "A6_ShellSide", "A9_SpaceElevator" } do
		local _, rowName = rowNameOf(key, "Column")
		ok(rowName ~= "Geyser", `{key}.Column is not a geyser (got {rowName})`)
	end
end

-- 5. Sounds ------------------------------------------------------------------------------------------
do
	for name, row in Pieces do
		local sound = row.sound
		if sound ~= nil then
			ok(AudioConfig.Sfx[sound.key] ~= nil, `{name}: sound {sound.key} is an AudioConfig.Sfx key`)
			ok(row.motion == "bob" or row.motion == "oscillate", `{name}: sound needs a periodic motion`)
			ok(sound.at >= 0 and sound.at < 1, `{name}: sound.at in [0, 1)`)
			ok(sound.range > 0 and sound.range <= 200, `{name}: sound range sane`)
		end
	end
	local ambienceCount = 0
	for modelKey, ambience in WorldFxConfig.Ambience do
		ambienceCount += 1
		ok(AudioConfig.Sfx[ambience.key] ~= nil, `{modelKey}: ambience {ambience.key} is an AudioConfig.Sfx key`)
		ok(ambience.interval >= 8, `{modelKey}: ambience is sparse (interval >= 8 s)`)
		ok(ambience.jitter >= 0 and ambience.jitter < ambience.interval, `{modelKey}: jitter < interval`)
		local asset = MeshAssets[modelKey]
		ok(asset ~= nil, `{modelKey}: ambience model exists`)
		local grouped = false
		if asset ~= nil then
			for name in asset.pieces do
				if WorldFxConfig.groupFor(modelKey, name) ~= nil then
					grouped = true
				end
			end
		end
		ok(grouped, `{modelKey}: has an FX group to carry its ambience`)
	end
	ok(ambienceCount >= 1, "the volcano has its rumble")
	ok(Pieces.Geyser ~= nil and Pieces.Geyser.sound ~= nil, "geysers whoosh")
	local tiers = WorldFxConfig.Tiers
	ok(tiers.Low.MaxSounds <= 1, "Low tier: at most one world-FX sound source")
	ok(tiers.Low.MaxSounds <= tiers.Mid.MaxSounds and tiers.Mid.MaxSounds <= tiers.High.MaxSounds, "sounds rise with tier")
	-- Dino managers' happy roar (ManagerNpcConfig.Fx.WorldHopVoice) is sparse + tier-gated.
	local voice = ManagerNpcConfig.Fx.WorldHopVoice.dino
	ok(voice ~= nil and AudioConfig.Sfx[voice.key] ~= nil, "Dino hop voice is a real SFX key")
	ok(voice ~= nil and voice.cooldown >= 2, "Dino hop voice has a cooldown (never a chorus)")
	ok(voice ~= nil and voice.tiers.Low ~= true, "Dino hop voice is off on the Low tier")
end

if #failures > 0 then
	for _, failure in failures do
		print(`[world-fx] FAIL {failure}`)
	end
	error(`[world-fx] {#failures} of {checks} checks failed`)
end
print(`[world-fx] {checks} checks passed`)
