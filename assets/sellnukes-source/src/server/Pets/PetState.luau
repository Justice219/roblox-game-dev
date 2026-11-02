--!strict
--[[
	PetState — typed access to the profile fields the pets / eggs / crates systems own:

		profile.pets   = { owned {[uid]={id, locked?}}, equipped {uid}, nextUid,
		                   eggs {[eggId]=count}, pity {[eggId]=count}, index {[petId]=true},
		                   indexClaimed {[milestoneId]=true} (R78 Pet Index rewards,
		                   Shared/Config/PetIndexConfig) }
		profile.crates = { held {[crateId]=count}, pity {[crateId]=count}, opened }
		profile.trails = { owned {[trailId]=true}, equipped = "" }

	Why a module: `owned / equipped / nextUid` are schema v1 (ProfileLogic, B1); the rest was
	requested from B1 on 2026-10-30 (ProfileLogic reconcile + snapshot). These accessors create any
	missing sub-table in place (the shape reconcile produces), so every pets rule is written once
	against complete tables, and Lune tests can hand in a bare default profile. They never yield
	and never touch fields outside these three blocks.

	Connects to: Server/Pets/PetLogic, Server/Pets/CrateLogic, Server/Pets/PetGrants,
	Server/Economy/ProfileLogic (the schema), tests/pets-*.luau.

	Example:
		local pets = PetState.pets(profile)   -- pets.eggs / pets.pity / pets.index always exist
		pets.eggs.lucky_egg = (pets.eggs.lucky_egg or 0) + 1
]]

export type PetEntry = { id: string, locked: boolean? }

export type Pets = {
	owned: { [string]: PetEntry },
	equipped: { string },
	nextUid: number,
	eggs: { [string]: number },
	pity: { [string]: number },
	index: { [string]: boolean },
	indexClaimed: { [string]: boolean }, -- R78: claimed Index milestones (PetIndexConfig ids)
}

export type Crates = {
	held: { [string]: number },
	pity: { [string]: number },
	opened: number,
}

export type Trails = {
	owned: { [string]: boolean },
	equipped: string,
}

local PetState = {}

-- A plain table at t[key], created when missing / not a table.
local function tableAt(t: any, key: string): any
	local value = t[key]
	if type(value) ~= "table" then
		value = {}
		t[key] = value
	end
	return value
end

--[[ profile.pets with eggs / pity / index / indexClaimed guaranteed (created in place when missing). ]]
function PetState.pets(profile: any): Pets
	local pets = tableAt(profile, "pets")
	tableAt(pets, "owned")
	tableAt(pets, "equipped")
	tableAt(pets, "eggs")
	tableAt(pets, "pity")
	tableAt(pets, "index")
	tableAt(pets, "indexClaimed")
	if type(pets.nextUid) ~= "number" or pets.nextUid ~= pets.nextUid or pets.nextUid < 1 then
		pets.nextUid = 1
	end
	return pets :: Pets
end

--[[ profile.crates (created in place when missing). ]]
function PetState.crates(profile: any): Crates
	local crates = tableAt(profile, "crates")
	tableAt(crates, "held")
	tableAt(crates, "pity")
	if type(crates.opened) ~= "number" or crates.opened ~= crates.opened then
		crates.opened = 0
	end
	return crates :: Crates
end

--[[ profile.trails (created in place when missing). ]]
function PetState.trails(profile: any): Trails
	local trails = tableAt(profile, "trails")
	tableAt(trails, "owned")
	if type(trails.equipped) ~= "string" then
		trails.equipped = ""
	end
	return trails :: Trails
end

--[[ Number of pets owned (counts the map; ≤ PetConfig.HardCap entries). ]]
function PetState.ownedCount(profile: any): number
	local count = 0
	for _ in PetState.pets(profile).owned do
		count += 1
	end
	return count
end

return table.freeze(PetState)
