--!strict
--[[
	BadgeConfig — SellNukes' permanent Roblox badges (free milestones) and the pure qualification
	rules (docs/leaderboards.md § Badges). Pattern: RoBeasts BadgeConfig + BadgeAwardsQueue.

	Catalog (append-only: array position - 1 = the bit in the replicated ownership mask):
		Welcome         join the game
		Area2..Area10   reach each tycoon area (profile.tycoon.area >= N)
		FirstManager    hire your first manager (own any pad of kind "Manager")
		FirstRebirth    rebirth once (profile.rebirths >= 1)
		FirstHatch      hatch your first egg (profile.stats.hatched >= 1)
		FeastMaster     complete the Harvest Feast sticker sheet (20 stickers, or redeemed)
		TimeTraveler    (owner R57) first visit to Dino Valley (profile.worlds.dino.stats.visits >= 1)
		VolcanoTamer    (owner R57) first Dino finale: own the world's finale pad (d6_golden_trex) or
		                have rebirthed there (profile.worlds.dino.rebirths >= 1)
		MoonWalker      (owner R70) first visit to Moon Base (profile.worlds.moon.stats.visits >= 1)
		StarTamer       (owner R70) first Moon finale (m6_golden_astronaut or a Moon rebirth)
	World badges carry `World` (a WorldsConfig id); their progress reads profile.worlds[World] (the
	client snapshot's `worlds` carries pads, rebirths and stats.visits too).

	BadgeId = 0 means "not created on the Creator Dashboard yet": the server never calls Roblox for
	it, skips the award and logs it once per server (docs: how the owner creates badges and fills
	the ids in here). Ids must be positive whole numbers; duplicates fail the server boot.

	The server derives qualification from the authoritative profile only (`qualifies`); no client
	request exists. The client reads the confirmed-ownership mask attribute for display.

	Connects to: Server/Services/BadgeService + Server/Badges/BadgeAwardsQueue, Shared/Config/
	TycoonConfig (area names, manager pads), Shared/Config/EventConfig (sticker count),
	Shared/Config/Worlds/WorldsConfig (world badges: the world's finale pad id).

	Example:
		for index, def in BadgeConfig.Definitions do
			print(index, def.Id, BadgeConfig.qualifies(profile, def))
		end
]]

local EventConfig = require(script.Parent.EventConfig)
local TycoonConfig = require(script.Parent.TycoonConfig)
local WorldsConfig = require(script.Parent.Worlds.WorldsConfig)

export type Source =
	"Welcome"
	| "Area"
	| "Manager"
	| "Rebirth"
	| "Hatch"
	| "StickerSheet"
	| "WorldVisit" -- R57: profile.worlds[World].stats.visits >= 1
	| "WorldFinale" -- R57: own the world's finale pad, or worlds[World].rebirths >= 1

export type Definition = {
	Id: string, -- stable key (logs, admin, docs)
	Name: string, -- the badge name to create on the dashboard
	Description: string, -- the badge description to create on the dashboard
	Source: Source,
	Target: number, -- area number for "Area", else 1
	BadgeId: number, -- Roblox badge id (0 = not created yet: award skipped + logged)
	World: string?, -- R57 world badges: the WorldsConfig id they read (nil for Nuke Town badges)
}

local BadgeConfig = {}

-- Player attribute (server-set): bit (index - 1) set = Roblox confirmed the player owns badge index.
BadgeConfig.OwnedMaskAttribute = "EarnedBadgesMask"

-- CheckUserBadgesAsync accepts at most this many badge ids per call.
BadgeConfig.OwnershipBatch = 10
-- Present players are re-observed this often (cheap profile reads; signals make awards faster).
BadgeConfig.ObserveEverySeconds = 15

-- Award worker pacing (below Roblox's baseline limits; see docs).
BadgeConfig.Worker = table.freeze({
	OwnershipInterval = 6.1, -- seconds between CheckUserBadgesAsync calls (limit 10 + 5*players / min)
	AwardInterval = 1.25, -- seconds between AwardBadgeAsync calls (limit 50 + 35*players / min)
	MetadataTTL = 300, -- GetBadgeInfoAsync cache (incl. disabled answers)
	RetryBase = 5, -- failure backoff: 5 s doubling...
	RetryMaximum = 300, -- ...up to 5 min
	MinimumStep = 0.25,
})

-- Welcome + areas 2-5 were published in universe 10773845696 on 2026-10-31; areas 6-10 followed
-- on 2026-11-01. Keep area ids keyed by progression target so adding dashboard ids never changes
-- the append-only ownership-mask order. The eight non-area milestones below remain unconfigured.
local PUBLISHED_AREA_BADGE_IDS: { [number]: number } = table.freeze({
	[2] = 930439656495923,
	[3] = 2838896599280003,
	[4] = 1991745259308552,
	[5] = 3137687340600188,
	[6] = 2219908620256793,
	[7] = 1208252337094160,
	[8] = 1173136756556691,
	[9] = 1960543602511361,
	[10] = 4266422855011413,
})

-- Area display names for badge names / descriptions.
local function areaName(index: number): string
	local area = TycoonConfig.Areas[index]
	return if area ~= nil and type(area.name) == "string" then area.name else `Area {index}`
end

local DEFINITIONS: { Definition } = {
	{
		Id = "Welcome",
		Name = "Welcome to Sell Nukes!",
		Description = "Open your very own pocket nuke garage.",
		Source = "Welcome",
		Target = 1,
		BadgeId = 1262588763497037,
	},
}
for index = 2, 10 do
	local def: Definition = {
		Id = `Area{index}`,
		Name = areaName(index),
		Description = `Unlock area {index}: {areaName(index)}.`,
		Source = "Area",
		Target = index,
		BadgeId = PUBLISHED_AREA_BADGE_IDS[index] or 0,
	}
	table.insert(DEFINITIONS, def)
end
do
	local def: Definition = {
		Id = "FirstManager",
		Name = "Hired Help",
		Description = "Hire your first manager to make nukes for you.",
		Source = "Manager",
		Target = 1,
		BadgeId = 0,
	}
	table.insert(DEFINITIONS, def)
end
do
	local def: Definition = {
		Id = "FirstRebirth",
		Name = "Fresh Start",
		Description = "Rebirth for the first time.",
		Source = "Rebirth",
		Target = 1,
		BadgeId = 0,
	}
	table.insert(DEFINITIONS, def)
end
do
	local def: Definition = {
		Id = "FirstHatch",
		Name = "Hello, Little Glow!",
		Description = "Hatch your first pet egg.",
		Source = "Hatch",
		Target = 1,
		BadgeId = 0,
	}
	table.insert(DEFINITIONS, def)
end
do
	local def: Definition = {
		Id = "FeastMaster",
		Name = "Feast Master",
		Description = "Complete the Harvest Feast sticker sheet.",
		Source = "StickerSheet",
		Target = 1,
		BadgeId = 0,
	}
	table.insert(DEFINITIONS, def)
end
-- Owner R57 World 2 "Dino Valley" (spec §19: the owner creates them; ids stay 0 until then).
do
	local def: Definition = {
		Id = "TimeTraveler",
		Name = "Time Traveler",
		Description = "Ride the Time Machine to Dino Valley for the first time.",
		Source = "WorldVisit",
		Target = 1,
		BadgeId = 0,
		World = "dino",
	}
	table.insert(DEFINITIONS, def)
end
do
	local def: Definition = {
		Id = "VolcanoTamer",
		Name = "Volcano Tamer",
		Description = "Build the Golden T-Rex at the top of the Volcano Reactor in Dino Valley.",
		Source = "WorldFinale",
		Target = 1,
		BadgeId = 0,
		World = "dino",
	}
	table.insert(DEFINITIONS, def)
end
-- Owner R70 World 3 "Moon Base" (R69–R71 spec §5: the owner creates them; ids stay 0 until then).
-- Same generic world sources as Dino's: first visit, first finale (m6_golden_astronaut / a rebirth).
do
	local def: Definition = {
		Id = "MoonWalker",
		Name = "Moon Walker",
		Description = "Blast off in the Moon Rocket to Moon Base for the first time.",
		Source = "WorldVisit",
		Target = 1,
		BadgeId = 0,
		World = "moon",
	}
	table.insert(DEFINITIONS, def)
end
do
	local def: Definition = {
		Id = "StarTamer",
		Name = "Star Tamer",
		Description = "Build the Golden Astronaut at the top of the Star Reactor on Moon Base.",
		Source = "WorldFinale",
		Target = 1,
		BadgeId = 0,
		World = "moon",
	}
	table.insert(DEFINITIONS, def)
end
for _, def in DEFINITIONS do
	assert(def.World == nil or WorldsConfig.get(def.World) ~= nil, `BadgeConfig: {def.Id} names an unknown world`)
	table.freeze(def)
end

-- Stable order: array position - 1 = mask bit. APPEND ONLY.
BadgeConfig.Definitions = table.freeze(DEFINITIONS)

-- Id -> index.
BadgeConfig.IndexById = (function(): { [string]: number }
	local byId: { [string]: number } = {}
	for index, def in DEFINITIONS do
		assert(byId[def.Id] == nil, `duplicate badge key {def.Id}`)
		byId[def.Id] = index
	end
	return table.freeze(byId)
end)()

-- True for a finite number.
local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- True when a pads table owns `padId`: set form { [padId] = true } (server) or array { padId }.
local function ownsPad(pads: unknown, padId: string): boolean
	if type(pads) ~= "table" then
		return false
	end
	local set = pads :: { [any]: any }
	if set[padId] == true then
		return true
	end
	for _, owned in set do
		if owned == padId then
			return true
		end
	end
	return false
end

--[[ True for a usable Roblox badge id (positive whole number < 2^53). ]]
function BadgeConfig.isConfigured(id: number): boolean
	return finite(id) and id > 0 and id < 2 ^ 53 and id % 1 == 0
end

--[[
	Progress toward a badge from a profile-like table (server profile or client snapshot), clamped
	to [0, Target]. Unknown / malformed fields count as 0.
]]
function BadgeConfig.progress(profile: unknown, def: Definition): number
	if type(profile) ~= "table" then
		return 0
	end
	local data = profile :: { [string]: any }
	local value = 0
	if def.Source == "Welcome" then
		value = 1
	elseif def.Source == "Area" then
		local tycoon = data.tycoon
		local area = if type(tycoon) == "table" then tycoon.area else nil
		value = if finite(area) then area else 0
	elseif def.Source == "Manager" then
		local tycoon = data.tycoon
		local pads = if type(tycoon) == "table" then tycoon.pads else nil
		if type(pads) == "table" then
			for key, owned in pads do
				-- Set form { [padId] = true } (server) or array form { padId } (snapshot).
				local padId = if owned == true then key else owned
				local pad = if type(padId) == "string" then TycoonConfig.PadsById[padId] else nil
				if pad ~= nil and pad.kind == "Manager" then
					value = 1
					break
				end
			end
		end
	elseif def.Source == "Rebirth" then
		value = if finite(data.rebirths) then data.rebirths else 0
	elseif def.Source == "Hatch" then
		local stats = data.stats
		local hatched = if type(stats) == "table" then stats.hatched else nil
		value = if finite(hatched) then hatched else 0
	elseif def.Source == "WorldVisit" or def.Source == "WorldFinale" then
		local worlds = data.worlds
		local world = if type(worlds) == "table" and def.World ~= nil then worlds[def.World] else nil
		if type(world) == "table" then
			if def.Source == "WorldVisit" then
				local stats = world.stats
				local visits = if type(stats) == "table" then stats.visits else nil
				value = if finite(visits) then visits else 0
			else
				local worldDef = WorldsConfig.get(def.World)
				local tycoon = world.tycoon
				local finaleOwned = worldDef ~= nil
					and type(tycoon) == "table"
					and ownsPad(tycoon.pads, worldDef.economy.FinalePadId)
				value = if finaleOwned or (finite(world.rebirths) and world.rebirths >= 1) then 1 else 0
			end
		end
	elseif def.Source == "StickerSheet" then
		local event = data.event
		if type(event) == "table" then
			if event.redeemed == true or EventConfig.countStickers(event.stickers) >= EventConfig.StickerCount then
				value = 1
			end
		end
	end
	return math.clamp(math.floor(value), 0, def.Target)
end

--[[ True when the profile meets the badge's requirement. ]]
function BadgeConfig.qualifies(profile: unknown, def: Definition): boolean
	return BadgeConfig.progress(profile, def) >= def.Target
end

--[[ The qualification bit mask of a profile (bit index - 1 per definition). ]]
function BadgeConfig.qualifiedMask(profile: unknown): number
	local mask = 0
	for index, def in DEFINITIONS do
		if BadgeConfig.qualifies(profile, def) then
			mask = bit32.bor(mask, bit32.lshift(1, index - 1))
		end
	end
	return mask
end

assert(#DEFINITIONS <= 32, "BadgeConfig: the ownership mask holds at most 32 badges")

return table.freeze(BadgeConfig)
