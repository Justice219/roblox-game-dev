--!strict
--[[
	PetIndexLogic — the pure server rules of the Pet Index milestone rewards (owner R78, spec
	2026-10-31-r78 §5; numbers + counting in Shared/Config/PetIndexConfig).

	claim(profile, rawPosition) -> (code, milestone?)
		Validates the untrusted milestone POSITION (1..PetIndexConfig.Count, whole number), then
		checks state: already claimed → "claimed" (idempotent: a double press / replayed packet
		pays nothing twice); fewer pets discovered than the milestone needs → "locked"; else marks
		pets.indexClaimed[id] = true and returns "ok" + the milestone. The CALLER pays the gems in
		the SAME non-yielding step (PetService: RewardGrant.grant(PetIndexLogic.rewardOf(m))) — the
		claim mark and the payment can never be split by a yield, a save or a second request.
	setClaimed(profile, milestoneId, on) -> changed
		Owner admin (PetService "PetIndexGrant" / "PetIndexClear"): marks / clears one milestone
		WITHOUT checking the discovered count (grant pays its gems in the service; clear removes the
		mark so it can be claimed again, and its Index Bonus with it).
	rewardOf(milestone) -> RetentionConfig.Reward   { gems = milestone.gems }
	status(profile) -> { found, total, claimed (count), bonus, ready (count) }   admin / analytics

	Never yields; touches only profile.pets (PetState creates missing sub-tables).

	Connects to: Shared/Config/PetIndexConfig, Server/Pets/PetState, Server/Services/PetService,
	Server/Retention/{RewardLogic, RewardGrant} (payment), tests/pet-index.luau.

	Example:
		local code, milestone = PetIndexLogic.claim(profile, 1)
		if code == "ok" then RewardGrant.grant(player, PetIndexLogic.rewardOf(milestone), "petIndex") end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PetIndexConfig = require(ReplicatedStorage.Shared.Config.PetIndexConfig)
local PetState = require(script.Parent.PetState)

export type Code = "ok" | "bad" | "claimed" | "locked"

-- What status() reports (admin "Pet Index" readout).
export type Status = {
	found: number, -- pets discovered (exclusives included)
	total: number, -- PetIndexConfig.Total (non-exclusive pets)
	claimed: number, -- milestones claimed
	ready: number, -- milestones reached and not claimed
	bonus: number, -- permanent Index Bonus fraction (0.04 = +4 %)
}

local PetIndexLogic = {}

--[[
	Claims milestone `rawPosition` (untrusted) for `profile`. See the header.
	@return code, the milestone when code == "ok"
	Example: PetIndexLogic.claim(profile, 1) --> "ok", { id = "5", gems = 25, ... }
]]
function PetIndexLogic.claim(profile: any, rawPosition: unknown): (Code, PetIndexConfig.Milestone?)
	local milestone = PetIndexConfig.get(rawPosition)
	if milestone == nil then
		return "bad", nil
	end
	local pets = PetState.pets(profile)
	if pets.indexClaimed[milestone.id] == true then
		return "claimed", nil
	end
	if PetIndexConfig.discovered(pets.index) < milestone.need then
		return "locked", nil
	end
	pets.indexClaimed[milestone.id] = true
	return "ok", milestone
end

--[[
	Admin: marks (`on`) or clears milestone `milestoneId` regardless of the discovered count.
	@return true when the mark changed (false for unknown ids / no change)
	Example: PetIndexLogic.setClaimed(profile, "all", true) --> true
]]
function PetIndexLogic.setClaimed(profile: any, milestoneId: unknown, on: boolean): boolean
	if type(milestoneId) ~= "string" then
		return false
	end
	local milestone = PetIndexConfig.ById[milestoneId]
	if milestone == nil then
		return false
	end
	local claimed = PetState.pets(profile).indexClaimed
	local was = claimed[milestone.id] == true
	if was == on then
		return false
	end
	claimed[milestone.id] = if on then true else nil
	return true
end

--[[
	The reward a milestone pays on claim (RetentionConfig.Reward shape: RewardLogic.apply).
	Example: PetIndexLogic.rewardOf(PetIndexConfig.get(7)) --> { gems = 300 }
]]
function PetIndexLogic.rewardOf(milestone: PetIndexConfig.Milestone): { gems: number }
	return { gems = milestone.gems }
end

--[[
	The player's Index standing (admin readout; also the provider's bonus input).
	Example: PetIndexLogic.status(profile).found --> 12
]]
function PetIndexLogic.status(profile: any): Status
	local pets = PetState.pets(profile)
	local claimedCount = 0
	for _, milestone in PetIndexConfig.Milestones do
		if pets.indexClaimed[milestone.id] == true then
			claimedCount += 1
		end
	end
	return {
		found = PetIndexConfig.discovered(pets.index),
		total = PetIndexConfig.Total,
		claimed = claimedCount,
		ready = #PetIndexConfig.claimable(pets),
		bonus = PetIndexConfig.bonus(pets.indexClaimed),
	}
end

--[[
	The permanent Index Bonus fraction of `profile` (claimed milestones only). Never yields; the
	"pets" modifier provider adds it to petCash.
	Example: PetIndexLogic.bonus(profile) --> 0.04
]]
function PetIndexLogic.bonus(profile: any): number
	return PetIndexConfig.bonus(PetState.pets(profile).indexClaimed)
end

return table.freeze(PetIndexLogic)
