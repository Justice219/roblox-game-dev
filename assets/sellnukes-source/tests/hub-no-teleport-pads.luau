--!strict
--[[
	No hub plot teleport pads (owner R134, 2026-11-01: "can we remove these little teleports").

	Until R134 the lobby had a ring of 8 plot teleport pads (Hub_TeleportPad + a plot-coloured
	Hub_Digit<i> on its signpost at r 62; touching one walked you to plot i), mirrored in every extra
	world's hub (Valley_TeleportPad, Moon_TeleportPad), and HubBuilder generated neon portals when a
	layout had none. R134 removed all of it. This suite proves, on the shipped sources:
	  1. Layouts: every registered world's hub layout (WorldsConfig.Order -> def.hubLayout) has no
	     `anchors.PlotTeleportPads`, no *_TeleportPad placement (world, event, plot frame, locked
	     slot) or surface, no leftover pad signpost collider, and no Hub_Digit except the lobby's
	     plot-gate digits (2 per gate, on the gate itself).
	  2. Builder: World/HubBuilder (comments stripped) never reads PlotTeleportPads and has no
	     generated portal fallback (PortalRadius, "Portal{index}" triggers, a "Portals" folder), no
	     pad labels (setPlotOwner / labelPadsIn) and no `portals` field on its HubBuild record.
	  3. Wiring: Tycoon/PlotService connects no hub triggers (no onPortalTouched, .portals,
	     worldPlotPortals, setPlotOwner, portal limiter, `visit` hook) and Tycoon/WorldService
	     installs no `visit` hook; no code anywhere in src/ reads `PlotTeleportPads`.
	  4. Nobody is stranded: the Teleport menu still sends TeleportHub / TeleportArea / TeleportPlot
	     and the server still handles all three (PlotService, TycoonService).
	The pad meshes (Hub_TeleportPad, Valley_TeleportPad, Moon_TeleportPad) stay in MeshAssets,
	unused (docs/areas-art.md "Owner R134").

	Run: lune run tests/hub-no-teleport-pads.luau
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Loader = require("./fixtures/RobloxLoader")

local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local loader = Loader.new()
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end

-- The R55 pad geometry (mirror of the removed HubLayout code): ring radius, the signpost collider
-- box (size + its offset in the pad's frame). Used to prove no pad collider was left behind.
local PAD_RING_R = 62
local SIGNPOST_SIZE = Vector3.new(8.8, 9.2, 1.0)
local SIGNPOST_OFFSET = Vector3.new(0, 4.6, 6.6)

--[[
	True when `key` names a teleport pad mesh (Hub_TeleportPad, Valley_TeleportPad, ...).
	Example: isPadKey("Moon_TeleportPad") --> true
]]
local function isPadKey(key: any): boolean
	return type(key) == "string" and string.find(key, "_TeleportPad$") ~= nil
end

--[=[
	A file's source with Luau comments removed (long `--[[ ]]` / `--[==[ ]==]` blocks first, then
	line comments), so the checks below look at code only — the R134 notes in the headers mention
	the removed names on purpose.
	Example: code("src/server/World/HubBuilder.luau")
]=]
local function code(path: string): string
	local source = fs.readFile(path)
	source = string.gsub(source, "%-%-%[(=*)%[.-%]%1%]", "")
	source = string.gsub(source, "%-%-[^\n]*", "")
	return source
end

-- True when `text` contains `needle` literally.
local function has(text: string, needle: string): boolean
	return string.find(text, needle, 1, true) ~= nil
end

-- Every .luau file under `dir` (recursive).
local function luauFiles(dir: string, out: { string }): { string }
	for _, name in fs.readDir(dir) do
		local path = `{dir}/{name}`
		if fs.isDir(path) then
			luauFiles(path, out)
		elseif string.sub(name, -5) == ".luau" then
			table.insert(out, path)
		end
	end
	return out
end

-- Horizontal (XZ) distance.
local function planarDistance(a: any, b: any): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- True when two sizes match in any axis order (a yawed box keeps its sizes).
local function sameSize(a: any, b: any): boolean
	local x = { a.X, a.Y, a.Z }
	local y = { b.X, b.Y, b.Z }
	table.sort(x)
	table.sort(y)
	for i = 1, 3 do
		if math.abs(x[i] - y[i]) > 0.05 then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------------------------------
-- 1. Layouts: no pads in any world's hub
--------------------------------------------------------------------------------------------------
local worlds = 0
for _, worldId in WorldsConfig.Order do
	local def = WorldsConfig.get(worldId)
	check(def ~= nil, `{worldId}: registered`)
	local path = "src/shared/Config/" .. table.concat(def.hubLayout, "/")
	local layout = loader.load(path)
	check(type(layout) == "table", `{worldId}: hub layout {path} loads`)
	worlds += 1

	-- No anchor list (HubBuilder would have nothing to read anyway).
	check(type(layout.anchors) == "table", `{worldId}: anchors`)
	check(layout.anchors.PlotTeleportPads == nil, `{worldId}: no anchors.PlotTeleportPads (owner R134)`)

	-- No pad placement in any model list the runtime builds.
	local lists: { [string]: any } = {
		models = layout.models,
		plotFrame = type(layout.plotFrame) == "table" and layout.plotFrame.models or nil,
		lockedSlot = type(layout.lockedSlot) == "table" and layout.lockedSlot.models or nil,
		event = type(layout.event) == "table" and type(layout.event.harvest) == "table" and layout.event.harvest.models
			or nil,
	}
	for where, list in lists do
		for index, entry in list do
			check(not isPadKey(entry.key), `{worldId}: {where}[{index}] {entry.key} is a teleport pad (owner R134)`)
		end
	end
	for key in layout.surfaces or {} do
		check(not isPadKey(key), `{worldId}: surfaces.{key} labels a teleport pad (owner R134)`)
	end

	-- Plot digits: only the lobby's plot gates carry them (2 per gate, on the gate); no world hub
	-- has a pad digit standing on a signpost any more.
	local gates = if worldId == WorldsConfig.MAIN then layout.anchors.PlotGates else {}
	local digits = 0
	for _, entry in layout.models do
		if string.sub(entry.key, 1, 9) == "Hub_Digit" then
			digits += 1
			local onGate = false
			for _, gate in gates do
				if entry.key == `Hub_Digit{gate.plot}` and planarDistance(entry.cf.Position, gate.cf.Position) < 2 then
					onGate = true
				end
			end
			check(onGate, `{worldId}: {entry.name} is a plot-gate digit (no pad digits, owner R134)`)
		end
	end
	check(digits == 2 * #gates, `{worldId}: {digits} plot digits = 2 per gate ({#gates} gates)`)

	-- No pad signpost collider left at the old ring (8.8 x 9.2 x 1.0 box, 6.6 behind each pad).
	for i = 1, 8 do
		local padCf = CFrame.Angles(0, math.rad((i - 1) * 45), 0) * CFrame.new(0, 0, PAD_RING_R)
		local signpost = padCf * SIGNPOST_OFFSET
		for _, box in layout.collision or {} do
			local stray = planarDistance(box.cf.Position, signpost) < 1 and sameSize(box.size, SIGNPOST_SIZE)
			check(not stray, `{worldId}: no pad {i} signpost collider (owner R134)`)
		end
	end
end
check(worlds == #WorldsConfig.Order and worlds >= 3, "every registered world's hub layout checked")

--------------------------------------------------------------------------------------------------
-- 2. Builder: no pad triggers, labels or generated portal fallback
--------------------------------------------------------------------------------------------------
do
	local builder = code("src/server/World/HubBuilder.luau")
	for _, needle in
		{
			"PlotTeleportPads",
			"PortalRadius",
			"worldPlotPortals",
			"setPlotOwner",
			"labelPadsIn",
			'"Portals"',
			"`Portal{",
			".portals",
		}
	do
		check(not has(builder, needle), `HubBuilder has no plot pad code: {needle} (owner R134)`)
	end
	local first, last = string.find(builder, "export type HubBuild = {", 1, true)
	check(first ~= nil and last ~= nil, "HubBuilder exports HubBuild")
	local close = string.find(builder, "}", (last :: number) + 1, true)
	local record = string.sub(builder, first :: number, close :: number)
	check(not has(record, "portals"), "HubBuild has no portals field (owner R134)")
	check(
		has(record, "model") and has(record, "spawn") and has(record, "source"),
		"HubBuild keeps model / spawn / source"
	)
end

--------------------------------------------------------------------------------------------------
-- 3. Wiring: nothing connects or reads hub plot pads
--------------------------------------------------------------------------------------------------
do
	local plotService = code("src/server/Tycoon/PlotService.luau")
	for _, needle in
		{ "onPortalTouched", ".portals", "worldPlotPortals", "setPlotOwner", "portalLimiter", ".visit", "visit:" }
	do
		check(not has(plotService, needle), `PlotService has no hub pad wiring: {needle} (owner R134)`)
	end
	local worldService = code("src/server/Tycoon/WorldService.luau")
	check(
		not has(worldService, "visitPlot") and not has(worldService, "visit ="),
		"WorldService installs no visit hook"
	)
	local readers: { string } = {}
	for _, path in luauFiles("src", {}) do
		-- Cheap raw test first; only files that mention the name get their comments stripped.
		if has(fs.readFile(path), "PlotTeleportPads") and has(code(path), "PlotTeleportPads") then
			table.insert(readers, path)
		end
	end
	check(#readers == 0, `no code reads PlotTeleportPads (owner R134): {table.concat(readers, ", ")}`)
end

--------------------------------------------------------------------------------------------------
-- 4. Nobody is stranded: the Teleport menu routes still exist on both sides
--------------------------------------------------------------------------------------------------
do
	local menu = code("src/client/UI/Screens/Teleport/init.luau")
	check(has(menu, 'Remotes.event("TeleportHub")'), "Teleport menu: hub route")
	check(has(menu, 'Remotes.event("TeleportArea")'), "Teleport menu: own plot area route (go home)")
	check(has(menu, '"TeleportPlot"'), "Teleport menu: plot route")
	check(has(menu, "WorldClient.travel"), "Teleport menu: other-world routes (WorldClient.travel)")
	local plotService = code("src/server/Tycoon/PlotService.luau")
	check(has(plotService, 'Remotes.onServerEvent("TeleportHub"'), "server handles TeleportHub")
	check(has(plotService, 'Remotes.onServerEvent("TeleportPlot"'), "server handles TeleportPlot")
	local tycoon = code("src/server/Tycoon/TycoonService.luau")
	check(has(tycoon, 'Remotes.onServerEvent("TeleportArea"'), "server handles TeleportArea")
end

print(`[hub-no-teleport-pads] {checks} checks passed ({worlds} world hubs, no plot teleport pads)`)
