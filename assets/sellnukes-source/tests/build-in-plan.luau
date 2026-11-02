--!strict
--[[
	Build-in + world FX regressions (B4). Run:
		lune run tests/build-in-plan

	Loads the REAL modules (src/client/Tycoon/BuildIn/BuildPlan.luau, src/shared/Config/
	BuildInConfig.luau, src/shared/Config/WorldFxConfig.luau) with Roblox datatypes injected from
	@lune/roblox, and proves:
	  1. schedule(): every build of 1..400 pieces lasts within [~MinTotal, MaxTotal], staggers are
	     non-negative, and small builds still read as a build (>= MinTotal).
	  2. Easing curves start at 0, end at 1; easeOutBack overshoots (the "snap").
	  3. Clacks land on every ClackEvery-th piece and on the last one; pitch rises monotonically.
	  4. Ordering is bottom-to-top, then BuildOrder, then name.
	  5. WorldFxConfig.resolve: exact names, aliases, leading-word matches ("Rotor_Left",
	     "Belt2"), non-matches; every row has a valid motion / axis.
	  6. Device tiers (R11): FxQuality.compute (phones capped at Mid, Automatic by device class),
	     budgets rise Low <= Mid <= High, at most 60 simultaneous ghosts.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(label, 2)
	end
	checks += 1
end

local function load(path: string): any
	local env = {
		Vector3 = roblox.Vector3,
		Color3 = roblox.Color3,
		Enum = roblox.Enum,
		NumberRange = roblox.NumberRange,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		string = string,
		table = table,
		math = math,
		type = type,
	}
	return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

local BuildPlan = load("src/client/Tycoon/BuildIn/BuildPlan.luau")
local BuildInConfig = load("src/shared/Config/BuildInConfig.luau")
local WorldFxConfig = load("src/shared/Config/WorldFxConfig.luau")

-- 1. schedule
for count = 1, 400 do
	local stagger, flight = BuildPlan.schedule(count, BuildInConfig)
	local total = (count - 1) * stagger + flight
	ok(stagger >= 0 and flight > 0, `schedule({count}) gave negative timing`)
	ok(total <= BuildInConfig.MaxTotal + 1e-9, `schedule({count}) total {total} > MaxTotal`)
	if count >= 2 then
		ok(
			total >= BuildInConfig.MinTotal - 1e-9 or stagger >= BuildInConfig.MaxStagger - 1e-9,
			`schedule({count}) too short: {total}`
		)
	end
end

-- 2. easing
for _, name in { "easeOutBack", "easeOutCubic", "easeInOutSine" } do
	local fn = BuildPlan[name]
	ok(math.abs(fn(0)) < 1e-9 and math.abs(fn(1) - 1) < 1e-9, `{name} endpoints`)
end
local peak = 0
for i = 0, 100 do
	peak = math.max(peak, BuildPlan.easeOutBack(i / 100))
end
ok(peak > 1.02 and peak < 1.15, `easeOutBack overshoot {peak}`)

-- 3. clacks + pitch
local clacks = 0
for landed = 1, 10 do
	if BuildPlan.isClack(landed, 10, 3) then
		clacks += 1
	end
end
ok(clacks == 4, "clacks on 3, 6, 9 and the final 10th piece")
local previous = -math.huge
for i = 0, 10 do
	local pitch = BuildPlan.clackPitch(i / 10, BuildInConfig.ClackPitch.Min, BuildInConfig.ClackPitch.Max)
	ok(pitch >= previous, "pitch rises with progress")
	previous = pitch
end

-- 4. ordering
ok(BuildPlan.before(0, 5, "B", 1, 1, "A"), "lower bottom first")
ok(BuildPlan.before(1.01, 1, "Z", 1.0, 2, "A"), "same rounded bottom -> BuildOrder")
ok(BuildPlan.before(1, 1, "A", 1, 1, "B"), "tie -> name")
ok(not BuildPlan.before(2, 1, "A", 1, 9, "Z"), "higher bottom later")

-- 5. WorldFxConfig
ok(WorldFxConfig.resolve("Rotor") == WorldFxConfig.Pieces.Rotor, "exact")
ok(WorldFxConfig.resolve("Rotor_Left") == WorldFxConfig.Pieces.Rotor, "leading word + suffix")
ok(WorldFxConfig.resolve("Belt2") == WorldFxConfig.Pieces.Belt, "leading word + digit")
ok(WorldFxConfig.resolve("Conveyor") == WorldFxConfig.Pieces.Belt, "alias")
ok(WorldFxConfig.resolve("Liquid") ~= nil and WorldFxConfig.resolve("Bubbles") ~= nil, "MiniReactor pieces animate")
ok(WorldFxConfig.resolve("Wall") == nil and WorldFxConfig.resolve("Trim") == nil, "static pieces stay static")
ok(WorldFxConfig.resolve("HazardYellow") == nil, "no accidental prefix match")
-- `swing` (owner R75): keyframed loop (pickaxe miners); its keys / impacts are validated in depth by
-- tests/world-fx-swing.luau, here only the row shape.
local motions = { spin = true, oscillate = true, bob = true, scroll = true, swing = true, none = true }
for name, row in WorldFxConfig.Pieces do
	ok(motions[row.motion], `{name}: motion`)
	ok(row.axis == nil or row.axis == "X" or row.axis == "Y" or row.axis == "Z", `{name}: axis`)
	if row.motion == "oscillate" or row.motion == "bob" then
		ok((row.period or 0) > 0 and (row.amplitude or 0) > 0, `{name}: period/amplitude`)
	end
	if row.motion == "swing" then
		ok((row.period or 0) > 0 and type(row.keys) == "table" and #row.keys >= 2, `{name}: period/keys`)
	end
	if row.light ~= nil then
		ok(row.light.range > 0 and row.light.brightness > 0, `{name}: light`)
	end
end
-- World FX sounds moved to the game audio system (SoundAssets / AudioConfig; tests/audio.luau).

-- 5b. Motion groups (owner R25 / R26): attached pieces move together
local carGroup, carRow = WorldFxConfig.groupFor("A1_NukeMobile", "Roof")
ok(carGroup == "@Car" and carRow == WorldFxConfig.Pieces.CarIdle, "NukeMobile roof rides the Car assembly")
ok(WorldFxConfig.groupFor("A1_NukeMobile", "NukeBody") == "@Car", "roof rocket is in the same assembly")
ok(WorldFxConfig.groupFor("A1_NukeMobile", "Tyres") == nil, "wheels stay planted")
local capGroup = WorldFxConfig.groupFor("A2_StandCounter", "NukeNoses")
ok(
	capGroup ~= nil and capGroup == WorldFxConfig.groupFor("A2_StandCounter", "NukeRed"),
	"stand nuke caps share their bodies' group"
)
ok(WorldFxConfig.groupFor("A2_StandCounter", "Wood") == nil, "the counter itself stays still")
ok(WorldFxConfig.groupFor(nil, "Wall") == nil, "plain pieces never animate")
local _, stopsRow = WorldFxConfig.groupFor("A3_ParkingLot", "WheelStops")
ok(stopsRow ~= nil and stopsRow.motion == "none", "parking-lot wheel stops never spin")
local _, ringRow = WorldFxConfig.groupFor("A3_GPSBeacon", "GlowRing")
ok(ringRow == WorldFxConfig.Pieces.Core, "GPS ring glows without floating")
-- Owner R56: the van DRIVES (Client/Tycoon/Fx/VehicleRoutes moves it as one unit); WorldFx keeps off.
ok(WorldFxConfig.groupFor("A3_DeliveryVan", "White") == nil, "routed van pieces are never WorldFx-animated")
ok(WorldFxConfig.groupFor("A4_MineCart", "Glow") == "@Routed", "routed cart glow keeps its light, frozen")
ok(WorldFxConfig.groupFor("A9_Rocket", "Body") == "@Rocket", "the whole Space Port rocket hovers together")
ok(WorldFxConfig.groupFor("A2_CashierBot", "Body") == nil, "manager NPCs are moved by ManagerController, not WorldFx")
ok(WorldFxConfig.groupFor("A4_Foreman", "ArmL") == nil, "manager limbs never oscillate")
local npcGroup, npcRow = WorldFxConfig.groupFor("A2_CashierBot", "FaceGlow")
ok(npcGroup == "@NpcStill" and npcRow ~= nil and npcRow.motion == "none", "manager lights stay, without motion")
ok(WorldFxConfig.groupFor("A2_CashierBot", "Hover") == nil, "the cashier bot's hover ring is not a WorldFx bob")
local bulbGroup = WorldFxConfig.groupFor("A7_LaunchDirector", "Bulb")
ok(bulbGroup == "@NpcStill", "launch director's bulb keeps its light, frozen")
-- The fallback manager list matches every `kind = "Manager"` build key in TycoonAreas exactly.
local areaManagers: { [string]: boolean } = {}
for _, fileName in fs.readDir("src/shared/Config/TycoonAreas") do
	local source = fs.readFile(`src/shared/Config/TycoonAreas/{fileName}`)
	for block in string.gmatch(source, 'kind = "Manager",(.-)}') do
		local key = string.match(block, 'build = "([%w_]+)"')
		ok(key ~= nil, `{fileName}: manager pad has a build key`)
		areaManagers[key :: string] = true
	end
end
local managerCount = 0
for key in areaManagers do
	managerCount += 1
	ok(WorldFxConfig.FallbackManagers[key] == true, `fallback manager list has {key}`)
	ok(WorldFxConfig.isManager(key), `{key} is a manager`)
end
for key in WorldFxConfig.FallbackManagers do
	ok(areaManagers[key] == true, `fallback manager {key} is a TycoonAreas manager build`)
end
ok(managerCount == 10, "ten manager models (one per area)")
-- N1's rig pieces are named <Group><Colour> ("ArmLCoat" -> leading word "Arm" = an oscillate
-- row): on a manager model none of them may be tagged or moved by WorldFx.
for _, piece in { "ArmLCoat", "ArmRSkin", "TorsoCoat", "HeadHair", "LegLShoes", "Hover", "NukeBody", "Wheel" } do
	for key in areaManagers do
		ok(WorldFxConfig.groupFor(key, piece) == nil, `{key}.{piece} is left to ManagerController`)
	end
end
ok(WorldFxConfig.groupFor("A1_Workbench", "ArmLCoat") ~= nil, "the same name still animates on a prop")
-- N1's ManagerNpcConfig (the runtime source of truth) agrees with the fallback list.
if fs.isFile("src/shared/Config/ManagerNpcConfig.luau") then
	local npcConfig = load("src/shared/Config/ManagerNpcConfig.luau")
	ok(#npcConfig.ManagerKeys == managerCount, "ManagerNpcConfig lists every manager")
	for _, key in npcConfig.ManagerKeys do
		ok(WorldFxConfig.FallbackManagers[key] == true, `ManagerNpcConfig key {key} is in the fallback list`)
		ok(npcConfig.ownsModel(key), `ManagerNpcConfig owns {key}`)
	end
end
ok(not WorldFxConfig.isManager("A1_NukeMobile"), "props are not managers")
-- With a ManagerNpcConfig sibling present, its ownsModel() is the source of truth (guarded).
local function loadWithManagerConfig(managerModule: any): any
	-- A path-node style sibling (like tests/fixtures/RobloxLoader): indexing finds the module.
	local fakeModule = { __module = "ManagerNpcConfig" }
	local env = {
		Vector3 = roblox.Vector3,
		Color3 = roblox.Color3,
		NumberRange = roblox.NumberRange,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		script = {
			Parent = { ManagerNpcConfig = fakeModule },
		},
		require = function(module: any): any
			assert(module == fakeModule, "only the ManagerNpcConfig sibling is required")
			if managerModule == "error" then
				error("ManagerNpcConfig failed to load")
			end
			return managerModule
		end,
	}
	local source = fs.readFile("src/shared/Config/WorldFxConfig.luau")
	return luau.load(source, { debugName = "WorldFxConfig+npc", environment = env })()
end
local withNpc = loadWithManagerConfig({
	ownsModel = function(modelKey: string): boolean
		return modelKey == "A1_NukeMobile"
	end,
})
ok(withNpc.groupFor("A1_NukeMobile", "Roof") == nil, "ManagerNpcConfig.ownsModel overrides the fallback")
ok(withNpc.groupFor("A2_CashierBot", "Hover") == "Hover", "models it does not own use the normal rules")
ok(withNpc.groupFor("A4_Foreman", "Glow") == "Glow", "models ManagerNpcConfig does not own animate normally")
-- Through tests/fixtures/RobloxLoader (path-node `script`, the real ManagerNpcConfig sibling):
-- the lookup resolves the real module instead of erroring on node method calls.
local RobloxLoader = require("./fixtures/RobloxLoader")
local viaLoader = RobloxLoader.new().load("src/shared/Config/WorldFxConfig")
ok(viaLoader.isManager("A1_UncleAtom") and not viaLoader.isManager("A1_NukeMobile"), "loader: real ManagerNpcConfig")
ok(viaLoader.groupFor("A2_CashierBot", "ArmLCoat") == nil, "loader: manager rig arms untouched")
local broken = loadWithManagerConfig("error")
ok(broken.groupFor("A2_CashierBot", "Body") == nil, "a failing ManagerNpcConfig falls back to the list")
ok(broken.groupFor("A1_NukeMobile", "Roof") == "@Car", "fallback keeps props animated")
local _, climber = WorldFxConfig.groupFor("A9_SpaceElevator", "Climber")
ok(climber ~= nil and climber.motion == "bob" and climber.amplitude == 14, "space elevator pod rides its column")
for modelKey, assemblies in WorldFxConfig.Assemblies do
	for name, assembly in assemblies do
		ok(assembly.fx == "none" or WorldFxConfig.Pieces[assembly.fx] ~= nil, `{modelKey}.{name}: fx row exists`)
		ok((assembly.members == nil) ~= (assembly.exclude == nil), `{modelKey}.{name}: members XOR exclude`)
	end
end

-- 6. Device tiers (owner R11): pure FxQuality.compute + monotonic budgets
local FxQuality = luau.load(fs.readFile("src/client/Tycoon/Fx/FxQuality.luau"), {
	debugName = "FxQuality",
	environment = {
		-- Stubs: compute() is pure; the module only touches these at load / in tier().
		game = {
			GetService = function()
				return { Shared = { Util = { DeviceProfile = {} } } }
			end,
		},
		require = function()
			return {}
		end,
		math = math,
		string = string,
	},
})()
ok(FxQuality.compute("Phone", nil) == "Low", "phone automatic -> Low")
ok(FxQuality.compute("Phone", 10) == "Mid", "phone capped at Mid")
ok(FxQuality.compute("Console", 0) == "Mid", "console automatic -> Mid")
ok(FxQuality.compute("Desktop", nil) == "High", "desktop automatic -> High")
ok(FxQuality.compute("Desktop", 2) == "Low" and FxQuality.compute("Tablet", 5) == "Mid", "manual levels")
-- Owner R103: the tier is cached only once the viewport is a real screen (a pre-viewport touch read
-- classifies as "Phone" and must not pin a tablet to Low for the session).
ok(not FxQuality.viewportReady(0, 0) and not FxQuality.viewportReady(1, 1), "no viewport yet -> not cached")
ok(
	not FxQuality.viewportReady(0 / 0, 768) and not FxQuality.viewportReady(1024, math.huge),
	"junk viewport -> not cached"
)
ok(FxQuality.viewportReady(1024, 768) and FxQuality.viewportReady(844, 390), "real viewport -> cached")
local order = { "Low", "Mid", "High" }
for i = 2, 3 do
	local lo, hi = BuildInConfig.Tiers[order[i - 1]], BuildInConfig.Tiers[order[i]]
	ok(lo.MaxGhosts <= hi.MaxGhosts and lo.MaxFlownPerBuild <= hi.MaxFlownPerBuild, "build budgets rise with tier")
	ok(lo.LightRange <= hi.LightRange and lo.ConfettiScale <= hi.ConfettiScale, "build ranges rise with tier")
	local flo, fhi = WorldFxConfig.Tiers[order[i - 1]], WorldFxConfig.Tiers[order[i]]
	ok(flo.Range <= fhi.Range and flo.MaxMoving <= fhi.MaxMoving, "fx budgets rise with tier")
	ok(flo.MaxLights <= fhi.MaxLights and flo.MaxEmitters <= fhi.MaxEmitters, "fx lights rise with tier")
	ok(flo.HalfRateBeyond <= fhi.HalfRateBeyond and fhi.HalfRateBeyond < fhi.Range, "fx full-rate radius rises with tier")
end
ok(BuildInConfig.Tiers.High.MaxGhosts <= 60, "R11: at most ~60 simultaneous ghosts")

print(`[build-in-plan] {checks} checks passed`)
