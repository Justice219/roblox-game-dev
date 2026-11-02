--!strict
--[[
	GroupConfig — the "Join our ROBLOX Group" reward (design spec §7: cash + an exclusive pet;
	`Player:IsInGroupAsync`, re-checked on claim).

	GroupId = 0 means the owner has not created / given the group yet: the Rewards screen shows
	"Group coming soon!" and the server refuses every claim without a web call. Setting GroupId
	(and GroupName) is the ONLY change needed to switch the feature on.

	Example:
		if GroupConfig.isEnabled() then print(GroupConfig.GroupName) end
]]

local RetentionConfig = require(script.Parent.RetentionConfig)

local GroupConfig = {}

-- OWNER: set to the Roblox group id once the group exists (0 = feature off).
GroupConfig.GroupId = 0
GroupConfig.GroupName = ""

-- One-time reward: income-scaled cash + gems + the exclusive group pet (B9 pet id; gems until
-- the pets system registers a granter).
GroupConfig.Reward = table.freeze({
	cashSeconds = 600,
	cashFloor = 10_000,
	gems = 25,
	pet = "group_glow_kitty",
	fallbackGems = 25,
}) :: RetentionConfig.Reward

-- ClaimGroupReward token bucket per player (each claim may make a web call).
GroupConfig.Limit = table.freeze({ Burst = 2, PerSecond = 0.2 })

--[[ True when a group is configured (a positive whole id). ]]
function GroupConfig.isEnabled(): boolean
	local id = GroupConfig.GroupId
	return id > 0 and id % 1 == 0 and id == id
end

return table.freeze(GroupConfig)
