--!strict
--[[
	PetIndexConfig — Pet Index milestone rewards (owner R78 retention pack, spec
	docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md §5): discover pets, claim gems
	and a PERMANENT Index Bonus (+cash %) at 5 / 10 / 20 / 30 / 45 / 60 / ALL pets discovered.

	Purpose:
		One frozen table + pure helpers that the server (Server/Pets/PetIndexLogic, PetService's
		claim handler and its "pets" modifier provider), the client (UI/Screens/Pets/IndexRewards,
		the Pets HUD badge in Client/Pets/PetController) and the Lune tests (tests/pet-index.luau)
		all read, so "how many pets count", "which milestone is ready" and "what the bonus is" are
		computed identically everywhere. Every helper is safe on hostile / missing input (a client
		copy of the profile, a corrupted save) and never yields.

	Counting (spec §5, PetConfig header "Exclusive pets"):
		discovered = every KNOWN pet id marked true in profile.pets.index (PetLogic.grantPet marks it
		             on every hatch / grant and never clears it). Exclusive pets (packs, Nuke Pass,
		             limited events) count too — their index mark means the player has owned one.
		Total      = the NON-exclusive pet count (what the bar shows as "n / Total"). The ALL
		             milestone needs discovered >= Total, so it never needs a purchase or an event;
		             an owned exclusive pet is a bonus toward it. discovered may exceed Total.

	Rewards (claimed explicitly with the CLAIM button, never silently):
		milestone   5    10   20   30   45   60   ALL
		gems        25   40   60   80   120  160  300
		Index Bonus +2   +2   +3   +3   +5   +5   +10   % cash   (cumulative +30 %)
	The Index Bonus is summed over CLAIMED milestones and added to TycoonTypes.Modifiers.petCash by
	PetService's "pets" ModifierSources provider (`(1 + petCash)` in Shared/Tycoon/Modifiers), so it
	is permanent (kept through rebirth, like pets) and applies wherever pet bonuses apply.

	Save data: profile.pets.indexClaimed = { [milestoneId] = true } with ids "5" … "60", "all"
	(string keys: a sparse number set would not survive the DataStore's JSON encoding; ProfileLogic
	reconciles it as a bounded string set). Ids are SAVE DATA — never rename or reuse one.
	The claim remote sends the milestone POSITION (1..#Milestones), never an id or an amount.

	Connects to: Shared/Config/PetConfig (roster + exclusive flags), Server/Pets/PetIndexLogic (the
	claim rule), Server/Services/PetService (PetIndexClaim remote, provider, admin, analytics),
	Server/Economy/ProfileLogic (pets.indexClaimed schema), UI/Screens/Pets/{PetsScreen,
	IndexRewards}, Client/Pets/PetController (HUD badge), tests/pet-index.luau, docs/pets.md.

	Example:
		local PetIndexConfig = require(ReplicatedStorage.Shared.Config.PetIndexConfig)
		local found = PetIndexConfig.discovered(profile.pets.index)       --> 12
		local ready = PetIndexConfig.claimable(profile.pets)              --> { milestone "5", "10" }
		print(PetIndexConfig.formatBonus(PetIndexConfig.bonus(profile.pets.indexClaimed))) --> "+4%"
]]

local PetConfig = require(script.Parent.PetConfig)

-- One milestone (frozen).
export type Milestone = {
	position: number, -- 1..#Milestones: the PetIndexClaim remote's argument and the UI order
	id: string, -- save key in pets.indexClaimed + analytics part ("5" … "60" | "all")
	need: number, -- discovered pets required (ALL = PetIndexConfig.Total)
	gems: number, -- whole gems paid once on claim
	bonusPct: number, -- whole percent of permanent cash bonus (2 = +2 %)
	label: string, -- pip / button text ("5" … "60" | "ALL")
}

local PetIndexConfig = {}

-- The NON-exclusive pet count: the bar's total and the ALL milestone's need.
local total = 0
for _, id in PetConfig.Order do
	if not PetConfig.Pets[id].exclusive then
		total += 1
	end
end
PetIndexConfig.Total = total

-- Milestone rows (spec §5). `need = nil` marks ALL (= Total, resolved below).
local ROWS: { { id: string, need: number?, gems: number, bonusPct: number } } = {
	{ id = "5", need = 5, gems = 25, bonusPct = 2 },
	{ id = "10", need = 10, gems = 40, bonusPct = 2 },
	{ id = "20", need = 20, gems = 60, bonusPct = 3 },
	{ id = "30", need = 30, gems = 80, bonusPct = 3 },
	{ id = "45", need = 45, gems = 120, bonusPct = 5 },
	{ id = "60", need = 60, gems = 160, bonusPct = 5 },
	{ id = "all", need = nil, gems = 300, bonusPct = 10 },
}

local MILESTONES: { Milestone } = {}
local BY_ID: { [string]: Milestone } = {}
local maxBonusPct = 0
for position, row in ROWS do
	local milestone: Milestone = {
		position = position,
		id = row.id,
		need = row.need or total,
		gems = row.gems,
		bonusPct = row.bonusPct,
		label = if row.need == nil then "ALL" else tostring(row.need),
	}
	-- Frozen in place (cast: the new solver would otherwise narrow it to a read-only shape).
	table.freeze(milestone :: any)
	table.insert(MILESTONES, milestone)
	BY_ID[milestone.id] = milestone
	maxBonusPct += row.bonusPct
end
PetIndexConfig.Milestones = table.freeze(MILESTONES)
PetIndexConfig.ById = table.freeze(BY_ID)
PetIndexConfig.Count = #MILESTONES
-- Every milestone claimed: +30 % (exact: summed as whole percents, divided once).
PetIndexConfig.MaxBonus = maxBonusPct / 100

-- Server tunables (PetService): claim requests per player (token bucket).
PetIndexConfig.Server = table.freeze({
	ClaimBurst = 4,
	ClaimPerSecond = 1,
})

-- Reward source tag (RewardGrant reason → analytics economy "gems by source").
PetIndexConfig.Reason = "petIndex"

--------------------------------------------------------------------------------------------------
-- Pure helpers (safe on hostile input; never yield)
--------------------------------------------------------------------------------------------------

--[[
	The milestone at `position` (1..Count); nil for anything else (NaN, fractions, strings, tables).
	Example: PetIndexConfig.get(1).id --> "5" ; PetIndexConfig.get(0) --> nil
]]
function PetIndexConfig.get(position: unknown): Milestone?
	if type(position) ~= "number" or position ~= position or position % 1 ~= 0 then
		return nil
	end
	return MILESTONES[position]
end

--[[
	Pets discovered in `index` (profile.pets.index): known pet ids marked `true`, exclusives
	included. Walks the ROSTER (76 lookups), not the input, so a huge hostile table costs nothing.
	Example: PetIndexConfig.discovered({ glow_slime = true, bogus = true }) --> 1
]]
function PetIndexConfig.discovered(index: unknown): number
	if type(index) ~= "table" then
		return 0
	end
	local map = index :: { [any]: any }
	local count = 0
	for _, id in PetConfig.Order do
		if rawget(map, id) == true then
			count += 1
		end
	end
	return count
end

--[[ True when milestone `milestone` is marked claimed in `claimed` (pets.indexClaimed). ]]
function PetIndexConfig.isClaimed(claimed: unknown, milestone: Milestone): boolean
	return type(claimed) == "table" and rawget(claimed :: any, milestone.id) == true
end

--[[
	The permanent Index Bonus (fraction) of the claimed milestones; unknown keys are ignored.
	Example: PetIndexConfig.bonus({ ["5"] = true, ["10"] = true }) --> 0.04
]]
function PetIndexConfig.bonus(claimed: unknown): number
	local percent = 0
	for _, milestone in MILESTONES do
		if PetIndexConfig.isClaimed(claimed, milestone) then
			percent += milestone.bonusPct
		end
	end
	return percent / 100
end

-- Reads pets.index / pets.indexClaimed from a (possibly partial / hostile) pets block.
local function fieldsOf(pets: unknown): (unknown, unknown)
	if type(pets) ~= "table" then
		return nil, nil
	end
	local map = pets :: { [any]: any }
	return rawget(map, "index"), rawget(map, "indexClaimed")
end

--[[
	Milestones reached and not yet claimed, in order (the CLAIM button pays the first one).
	@param pets profile.pets (server profile or the client's snapshot copy)
	Example: #PetIndexConfig.claimable(profile.pets) --> 2
]]
function PetIndexConfig.claimable(pets: unknown): { Milestone }
	local index, claimed = fieldsOf(pets)
	local found = PetIndexConfig.discovered(index)
	local out: { Milestone } = {}
	for _, milestone in MILESTONES do
		if found >= milestone.need and not PetIndexConfig.isClaimed(claimed, milestone) then
			table.insert(out, milestone)
		end
	end
	return out
end

--[[
	The first milestone not yet claimed (reached or not): what the bar works toward. nil once
	every milestone is claimed.
	Example: PetIndexConfig.nextGoal(profile.pets).need --> 20
]]
function PetIndexConfig.nextGoal(pets: unknown): Milestone?
	local _, claimed = fieldsOf(pets)
	for _, milestone in MILESTONES do
		if not PetIndexConfig.isClaimed(claimed, milestone) then
			return milestone
		end
	end
	return nil
end

--[[
	"+4%" — a bonus fraction as the UI shows it (whole percent).
	Example: PetIndexConfig.formatBonus(0.3) --> "+30%"
]]
function PetIndexConfig.formatBonus(fraction: number): string
	if type(fraction) ~= "number" or fraction ~= fraction or fraction < 0 then
		return "+0%"
	end
	return `+{math.floor(fraction * 100 + 0.5)}%`
end

--[[
	Checks the table: ids unique + save-safe, needs strictly rising and within 1..Total, ALL last
	and equal to Total, whole positive gems / percents, total bonus +30 % (spec).
	@return problems (empty = valid); tests/pet-index.luau asserts it is empty.
]]
function PetIndexConfig.validate(): { string }
	local problems: { string } = {}
	local previous = 0
	for position, milestone in MILESTONES do
		if not string.match(milestone.id, "^[a-z0-9]+$") or #milestone.id > 8 then
			table.insert(problems, `milestone {position}: id must be short [a-z0-9]`)
		end
		if milestone.need <= previous or milestone.need < 1 or milestone.need > total then
			table.insert(problems, `milestone {milestone.id}: need must rise within 1..{total}`)
		end
		previous = milestone.need
		if milestone.gems < 1 or milestone.gems % 1 ~= 0 then
			table.insert(problems, `milestone {milestone.id}: gems must be a whole number > 0`)
		end
		if milestone.bonusPct < 1 or milestone.bonusPct % 1 ~= 0 then
			table.insert(problems, `milestone {milestone.id}: bonus must be a whole percent > 0`)
		end
	end
	local last = MILESTONES[#MILESTONES]
	if last == nil or last.id ~= "all" or last.need ~= total then
		table.insert(problems, "the last milestone must be ALL (= Total)")
	end
	if maxBonusPct ~= 30 then
		table.insert(problems, `Index Bonus must total +30 % (got {maxBonusPct})`)
	end
	return problems
end

return table.freeze(PetIndexConfig)
