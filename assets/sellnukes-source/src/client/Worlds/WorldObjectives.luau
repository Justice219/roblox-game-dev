--!strict
--[[
	WorldObjectives — the first-run objective chip of a non-main world (owner R57, spec §14):
	a pure 3-step guide that replaces Nuke Town's server tutorial in Dino Valley.

	Steps (texts from WorldClientConfig.Objectives[worldId] or .default):
		1 build  "Step on the green pad to build your Stone Bench!"   target = the builder pad
		2 click  "Click the bench to carve Pebble Nukes!"              target = the first producer
		         (until the player owns a second area-1 pad: clicking earned the cash for it)
		3 hire   "Hire Rocky Raptor!"                                  target = the next pad on the
		         way to the manager (the manager pad itself once it is the next one)
		done     the area-1 manager is owned -> nil (the chip hides)
	Only the FIRST run shows it: any rebirth in that world (`runs` > 0) -> nil. Nuke Town -> nil
	(its server tutorial owns the chip).

	Pure: no Instances, no services. The caller (Client/Worlds/WorldClient) resolves the pad /
	producer id to a world part (Tycoon/TycoonWorld) and calls Hud.setWorldObjective.

	Connects to: Shared/Tycoon/TycoonLogic (forWorld: index, ownsPad, nextPads),
	Shared/Config/{WorldClientConfig, Worlds/WorldsConfig}, tests/world-client.luau.

	Example:
		local step = WorldObjectives.next(dino.tycoon, "dino", dino.rebirths)
		if step then Hud.setWorldObjective(step.text, TycoonWorld.myPad(step.padId)) end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local WorldClientConfig = require(ReplicatedStorage.Shared.Config.WorldClientConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

export type Step = {
	step: number, -- 1 build / 2 click / 3 hire
	text: string,
	padId: string?, -- arrow target: a pad of the player's plot in that world
	producerId: string?, -- arrow target: a producer of the player's plot in that world
}

local WorldObjectives = {}

-- "{key}" placeholders filled from `values`.
local function fill(template: string, values: { [string]: string }): string
	-- A table replacement keeps the original "{key}" text for keys it does not have.
	return (string.gsub(template, "{(%w+)}", values))
end

--[[
	The current objective of a world's first run, or nil (Nuke Town, a later run, done, no data).
	@param state   that world's tycoon state ({ pads, producers, area }) from the profile
	@param worldId the world ("dino")
	@param runs    rebirths done in that world (nil = 0)
	@return Step?
	Example: WorldObjectives.next({ pads = {}, producers = {}, area = 1 }, "dino") --> step 1 (Stone Bench)
]]
function WorldObjectives.next(state: any, worldId: string, runs: number?): Step?
	if worldId == WorldsConfig.MAIN or WorldsConfig.get(worldId) == nil then
		return nil
	end
	if type(runs) == "number" and runs > 0 then
		return nil
	end
	if type(state) ~= "table" or type(state.pads) ~= "table" then
		return nil
	end
	local def = WorldsConfig.get(worldId) :: WorldsConfig.WorldDef
	local logic = TycoonLogic.forWorld(worldId)
	local area = logic.index.Areas[1]
	if area == nil then
		return nil
	end
	local producer = area.producer
	local builderId = producer.builtBy
	local managerId = logic.index.ManagerPadOf[producer.id]
	local builder = logic.index.PadsById[builderId]
	local manager = if managerId ~= nil then logic.index.PadsById[managerId] else nil
	local texts = WorldClientConfig.Objectives[worldId] or WorldClientConfig.Objectives.default
	local values = {
		pad = if builder ~= nil then builder.name else "machine",
		producer = producer.name,
		manager = if manager ~= nil then manager.name else "a manager",
		currency = def.currency.name,
	}
	if not logic.ownsPad(state, builderId) then
		return { step = 1, text = fill(texts.build, values), padId = builderId }
	end
	if managerId == nil or logic.ownsPad(state, managerId) then
		return nil -- done (or a world without a manager: nothing more to teach)
	end
	-- Step 2 until a second area-1 pad is owned (the clicks paid for it).
	local owned = 0
	for _, pad in area.pads do
		if logic.ownsPad(state, pad.id) then
			owned += 1
		end
	end
	if owned < 2 then
		return { step = 2, text = fill(texts.click, values), producerId = producer.id }
	end
	-- Step 3: point at the next pad on the way to the manager (the manager itself when next).
	local target: string? = managerId
	local nextPads = logic.nextPads(state)
	local managerNext = false
	for _, pad in nextPads do
		if pad.id == managerId then
			managerNext = true
			break
		end
	end
	if #nextPads > 0 and not managerNext then
		target = nextPads[1].id
	end
	return { step = 3, text = fill(texts.hire, values), padId = target }
end

return table.freeze(WorldObjectives)
