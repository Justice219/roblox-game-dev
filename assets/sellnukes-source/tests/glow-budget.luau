--!strict
--[[
	Glow budget regressions (owner R19: "when you do anything glowing, it's not overly bright").
	Run:
		lune run tests/glow-budget

	Guards so art builders can't regress the look:
	  1. WorldFxConfig.LightCaps are the owner's numbers (brightness <= 0.6, range <= 10,
	     pulse <= 0.2) and EVERY `light` row in WorldFxConfig.Pieces stays within them.
	  2. MeshPlacement's Neon rule: NeonMaxArea <= 6 studs²; resolveGlow turns every MeshAssets
	     Neon piece whose largest box face is over the limit into bright SmoothPlastic (never
	     Neon) and keeps small accents Neon; non-Neon pieces pass through untouched.
	  3. MeshLibrary renders through resolveGlow and WorldFxController builds soft lights
	     (warm-white colour pull, Shadows = false) — source checks.
	  4. Per-area glow budget over EVERY world's layouts (owner R57 worlds framework, W6 2026-10-31;
	     worlds from WorldsConfig.Order via tests/fixtures/ArtWorlds): in each fully built area (base +
	     every build) the pieces that still render as Neon after resolveGlow add up to at most
	     AREA_NEON_AREA studs² of largest box faces and AREA_NEON_PIECES pieces, and no primitive
	     layout block is Neon (blocks bypass resolveGlow). Ceiling = the brightest main area
	     (Glow Rock Mine, 30.3 studs² / 20 pieces, 2026-10-31) + a little headroom, so a new world
	     can glow as much as the main game's brightest area and no more.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local ArtWorlds = require("./fixtures/ArtWorlds")
local Loader = require("./fixtures/RobloxLoader")

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(label, 2)
	end
	checks += 1
end

local env = {
	CFrame = roblox.CFrame,
	Vector3 = roblox.Vector3,
	Color3 = roblox.Color3,
	Enum = roblox.Enum,
	NumberRange = roblox.NumberRange,
	NumberSequence = roblox.NumberSequence,
	NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
	math = math,
	string = string,
	table = table,
	type = type,
}
local function load(path: string): any
	return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

local WorldFxConfig = load("src/shared/Config/WorldFxConfig.luau")
local MeshPlacement = load("src/shared/World/MeshPlacement.luau")
local MeshAssets = load("src/shared/Config/MeshAssets.luau")

-- 1. light caps
local caps = WorldFxConfig.LightCaps
ok(caps.Brightness <= 0.6 and caps.Range <= 10 and caps.Pulse <= 0.2, "LightCaps are the owner's limits")
local lit = 0
for name, row in WorldFxConfig.Pieces do
	local light = row.light
	if light ~= nil then
		lit += 1
		ok(light.brightness > 0 and light.brightness <= caps.Brightness, `{name}: light brightness {light.brightness}`)
		ok(light.range > 0 and light.range <= caps.Range, `{name}: light range {light.range}`)
		ok((light.pulse or 0) <= caps.Pulse, `{name}: light pulse {light.pulse}`)
	end
end
ok(lit > 0, "some pieces are lit")

-- 2. Neon area rule over every shipped piece
ok(MeshPlacement.NeonMaxArea > 0 and MeshPlacement.NeonMaxArea <= 6, "NeonMaxArea <= 6 studs²")
local neon, downgraded = 0, 0
for key, asset in MeshAssets do
	for name, piece in asset.pieces do
		local material, color = MeshPlacement.resolveGlow(piece.material, piece.size, piece.color)
		if piece.material == "Neon" then
			neon += 1
			local big = MeshPlacement.glowArea(piece.size) > MeshPlacement.NeonMaxArea
			if big then
				downgraded += 1
				ok(material ~= "Neon", `{key}.{name}: big Neon must not render as Neon`)
				ok(color.R >= piece.color.R - 1e-6 and color.G >= piece.color.G - 1e-6, `{key}.{name}: brightened`)
			else
				ok(material == "Neon", `{key}.{name}: small accent stays Neon`)
			end
		else
			ok(material == piece.material and color == piece.color, `{key}.{name}: non-Neon untouched`)
		end
	end
end

-- 3. runtime wiring
local library = fs.readFile("src/server/World/MeshLibrary.luau")
ok(string.find(library, "MeshPlacement.resolveGlow(", 1, true) ~= nil, "MeshLibrary applies the glow budget")
local fx = fs.readFile("src/client/Tycoon/Fx/WorldFxController.luau")
ok(string.find(fx, "light.Shadows = false", 1, true) ~= nil, "FX lights never cast shadows")
ok(string.find(fx, ":Lerp(WARM_WHITE, LIGHT_WARMTH)", 1, true) ~= nil, "FX lights are pulled toward warm white")

-- 4. per-area glow budget, every world (see header)
local AREA_NEON_AREA = 32 -- studs² of rendered-Neon largest box faces per fully built area
local AREA_NEON_PIECES = 24 -- rendered-Neon piece placements per fully built area
local loader = Loader.new()
local areasChecked = 0
local brightest, brightestArea = "", 0
for _, world in ArtWorlds.list(loader) do
	for area = 1, world.areaCount do
		local layout, problems = ArtWorlds.areaLayout(loader, world, area)
		ok(#problems == 0, `{world.id} Area{area}: layout problems: {table.concat(problems, "; ")}`)
		if layout == nil then
			continue
		end
		areasChecked += 1
		local glowArea, glowPieces = 0, 0
		for _, placement in ArtWorlds.placements(layout) do
			local asset = if placement.key ~= nil then MeshAssets[placement.key] else nil
			if asset ~= nil then
				for _, piece in asset.pieces do
					local material = MeshPlacement.resolveGlow(piece.material, piece.size, piece.color)
					if material == "Neon" then
						glowArea += MeshPlacement.glowArea(piece.size)
						glowPieces += 1
					end
				end
			elseif placement.box ~= nil then
				ok(placement.material ~= "Neon", `{world.id} Area{area} {placement.group}: primitive block is Neon`)
			end
		end
		local label = `{world.id} Area{area}`
		ok(glowArea <= AREA_NEON_AREA, `{label}: {string.format("%.1f", glowArea)} studs² of Neon > {AREA_NEON_AREA}`)
		ok(glowPieces <= AREA_NEON_PIECES, `{label}: {glowPieces} Neon pieces > {AREA_NEON_PIECES}`)
		if glowArea > brightestArea then
			brightest, brightestArea = label, glowArea
		end
	end
end
ok(areasChecked > 0, "some areas checked")

print(
	`[glow-budget] {checks} checks passed ({neon} Neon pieces, {downgraded} rendered as soft bright plastic; `
		.. `{areasChecked} areas, brightest {brightest} {string.format("%.1f", brightestArea)} studs²)`
)
