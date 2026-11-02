--!strict
--[[
	Admin authorisation regressions (spec §14). Run:
		lune run tests/admin-auth

	Proves on the shipped Server/Admin/AdminAuth:
	  1. decideAdmin full truth table: Studio / live × user / group owned × allowlist × creator ×
	     group rank nil / 0 / 253 / 254 / 255 × userId 0 / -1 / NaN / normal, against an
	     independent oracle written here.
	  2. setEnvironmentOverrideForTests errors on a live server (it can never be switched into a
	     test environment there).
	  3. isAuthorizedAsync for a group game: ranks are fetched through GroupService, cached (one
	     web call for repeated checks), a failed lookup denies a user with no cached rank, and
	     non-members (IsMember = false) are denied.
	  4. isProtectedAsync uses the LIVE rules even in Studio (owner / allowlist protected, a random
	     user is not; an online admin is protected on a live server).
]]

local Loader = require("./fixtures/RobloxLoader")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- GroupService stub: ranks by user id; counts calls; `failing` makes every call throw.
local groupCalls = 0
local groupRanks: { [number]: number } = {}
local groupFailing = false
local GroupServiceStub = {
	GetRolesInGroupAsync = function(_self: any, userId: number, _groupId: number): any
		groupCalls += 1
		if groupFailing then
			error("HTTP 500")
		end
		local rank = groupRanks[userId]
		if rank == nil then
			return { IsMember = false, Roles = {} }
		end
		return { IsMember = true, Roles = { { Rank = 1 }, { Rank = rank } } }
	end,
}

local loader = Loader.new({ GroupService = GroupServiceStub })
local AdminAuth = loader.load("src/server/Admin/AdminAuth")
local AdminConfig = loader.load("src/shared/Config/AdminConfig")

-- 0. The owner is in the allowlist (survives a move to a group).
check(table.find(AdminConfig.AdminUserIds, 1586034782) ~= nil, "owner 1586034782 is allowlisted")
check(AdminConfig.OwnerUserId == 1586034782, "OwnerUserId")

-- 1. Truth table against an independent oracle.
local function oracle(
	userId: number,
	isStudio: boolean,
	creatorType: string,
	creatorId: number,
	allow: { number },
	rank: number?
): boolean
	if isStudio then
		return true
	end
	if userId ~= userId or userId <= 0 then
		return false
	end
	for _, id in allow do
		if id == userId then
			return true
		end
	end
	if creatorType == "User" then
		return creatorId > 0 and userId == creatorId
	end
	return rank ~= nil and rank >= 254
end

local users = { 0, -1, -7, 0 / 0, 5, 7, 9, 1586034782 }
local ranks: { number? } = { nil, 0, 253, 254, 255 }
local allowlists = { {}, { 7 }, { 7, 1586034782 } }
local creators = { 0, 5 }
local cases = 0
for _, isStudio in { true, false } do
	for _, creatorType in { "User", "Group" } do
		for _, creatorId in creators do
			for _, allow in allowlists do
				local env = {
					isStudio = isStudio,
					creatorType = creatorType,
					creatorId = creatorId,
					allowlist = allow,
					groupAdminRank = 254,
				}
				for _, userId in users do
					for rankIndex = 1, 5 do
						local rank = ranks[rankIndex]
						local expected = oracle(userId, isStudio, creatorType, creatorId, allow, rank)
						local got = AdminAuth.decideAdmin(userId, env :: any, rank)
						check(
							got == expected,
							`decideAdmin studio={isStudio} {creatorType} creator={creatorId} allow={#allow} user={userId} rank={rank} → {got}`
						)
						cases += 1
					end
				end
			end
		end
	end
end
check(cases == 2 * 2 * 2 * 3 * #users * 5, "every truth-table row ran")

-- Spot checks that read like the spec.
local live = { isStudio = false, creatorType = "User", creatorId = 1586034782, allowlist = {}, groupAdminRank = 254 }
check(AdminAuth.decideAdmin(1586034782, live :: any, nil), "the owner is admin on a live user-owned game")
check(not AdminAuth.decideAdmin(42, live :: any, 255), "a group rank means nothing for a user-owned game")
local group = { isStudio = false, creatorType = "Group", creatorId = 999, allowlist = {}, groupAdminRank = 254 }
check(not AdminAuth.decideAdmin(42, group :: any, 253), "rank 253 is not admin")
check(AdminAuth.decideAdmin(42, group :: any, 254), "rank 254 is admin")
check(not AdminAuth.decideAdmin(999, group :: any, nil), "the group id is not a user id")

-- 2. Overrides are Studio-only.
local liveLoader = Loader.new({
	GroupService = GroupServiceStub,
	RunService = {
		IsStudio = function()
			return false
		end,
		IsServer = function()
			return true
		end,
		IsClient = function()
			return false
		end,
	},
})
local LiveAuth = liveLoader.load("src/server/Admin/AdminAuth")
check(not pcall(LiveAuth.setEnvironmentOverrideForTests, group), "override errors on a live server")

-- 3. Group games: fetch, cache, fail closed.
AdminAuth.setEnvironmentOverrideForTests(group :: any)
groupRanks[100] = 254
groupRanks[101] = 200
groupCalls = 0
check(AdminAuth.isAuthorizedAsync(100), "rank 254 member authorised")
check(groupCalls == 1, "one web call")
check(AdminAuth.isAuthorizedAsync(100), "cached verdict")
check(groupCalls == 1, "cache hit: no second web call")
check(not AdminAuth.isAuthorizedAsync(101), "rank 200 member denied")
check(not AdminAuth.isAuthorizedAsync(102), "non-member denied")
check(
	not AdminAuth.isAuthorizedAsync(0) and not AdminAuth.isAuthorizedAsync(-5),
	"non-positive ids denied without lookups"
)
groupFailing = true
check(not AdminAuth.isAuthorizedAsync(103), "failed lookup with no cached rank denies")
check(AdminAuth.isAuthorizedAsync(100), "a fresh cached rank survives a failing web")
groupFailing = false
AdminAuth.forget(100)
check(AdminAuth.isAuthorizedAsync(100), "forget → fetched again")
check(not AdminAuth.rankExpired(100), "fresh rank not expired")

-- 4. Protection uses live rules even in Studio.
AdminAuth.setEnvironmentOverrideForTests({
	isStudio = true,
	creatorType = "User",
	creatorId = 5,
	allowlist = { 7 },
	groupAdminRank = 254,
} :: any)
check(AdminAuth.isProtectedAsync(5, false), "creator protected")
check(AdminAuth.isProtectedAsync(7, false), "allowlisted protected")
check(not AdminAuth.isProtectedAsync(9, false), "random user not protected in Studio")
check(not AdminAuth.isProtectedAsync(9, true), "Studio: an 'online admin' (everyone) is not protected")
check(LiveAuth.isProtectedAsync(9, true), "live: an online admin is protected")
AdminAuth.setEnvironmentOverrideForTests(nil)

print(`[admin-auth] {checks} checks passed ({cases} truth-table rows)`)
