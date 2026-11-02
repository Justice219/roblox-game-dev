--!strict
--[[
	AdminAuth — WHO is an admin. The single authorisation decision of the admin system (spec §14
	"Authorisation (server, re-checked on every command)"). Ported from RoBeasts AdminService
	(decideAdmin / groupRankAsync / isProtectedAsync).

	Rules (decideAdmin, pure):
		1. Studio → every player (play-testing is easy; Studio is never a live server),
		2. a non-positive UserId → never,
		3. AdminConfig.AdminUserIds (the owner, user 1586034782, is listed explicitly),
		4. user-owned experience → the place creator (game.CreatorId),
		5. group-owned experience → highest role rank in the owning group ≥ AdminConfig.GroupAdminRank
		   (254). Ranks come from GroupService:GetRolesInGroupAsync (pcall'd), cached for
		   GroupRankCacheSeconds; concurrent lookups for one user share one web call; a failed
		   refresh keeps the previous rank until it is GroupRankMaxStaleSeconds old, then the user
		   is DENIED until a lookup succeeds again (fail closed).
	The `IsAdmin` player attribute mirrors the verdict for the client UI only; the server never
	reads it back for authorisation.

	Connects to: Shared/Config/AdminConfig (allowlist, rank, cache timings), Server/Services/
	AdminService (isAuthorizedAsync on every command and on join; isProtectedAsync for kick / ban),
	tests/admin-auth.luau (decideAdmin truth table).

	Example:
		if AdminAuth.isAuthorizedAsync(player.UserId) then ... end
		print(AdminAuth.decideAdmin(1586034782, AdminAuth.currentEnvironment(), nil))
]]

local GroupService = game:GetService("GroupService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)

--[[ Everything authorisation depends on, injectable so the decision is a pure function. ]]
export type AuthEnvironment = {
	isStudio: boolean,
	creatorType: "User" | "Group",
	creatorId: number,
	allowlist: { number },
	groupAdminRank: number,
}

type RankCacheEntry = {
	rank: number?,
	fetchedAt: number,
	expires: number,
	fetching: boolean,
}

local AdminAuth = {}

-- Longest a caller waits for another thread's in-flight rank lookup (seconds).
local SHARED_LOOKUP_WAIT = 10

local environmentOverride: AuthEnvironment? = nil
local rankCache: { [number]: RankCacheEntry? } = {}

--[[
	PURE authorisation decision.
	@param userId     the caller's UserId (authentic: read from a real Player)
	@param env        the environment (live or test)
	@param groupRank  the caller's highest rank in the owning group (group games), nil if unknown
	@return true if the user is an admin
	Why pure: it is the security-critical core, so tests/admin-auth.luau exercises every branch
	without real players, groups or a published place.
	Example: AdminAuth.decideAdmin(5, { isStudio = false, creatorType = "User", creatorId = 5,
		allowlist = {}, groupAdminRank = 254 }, nil) --> true
]]
function AdminAuth.decideAdmin(userId: number, env: AuthEnvironment, groupRank: number?): boolean
	if env.isStudio then
		return true
	end
	if type(userId) ~= "number" or userId ~= userId or userId <= 0 then
		return false
	end
	if table.find(env.allowlist, userId) ~= nil then
		return true
	end
	if env.creatorType == "User" then
		return env.creatorId > 0 and userId == env.creatorId
	end
	return groupRank ~= nil and groupRank >= env.groupAdminRank
end

--[[ The live authorisation environment (or the Studio-only test override). ]]
function AdminAuth.currentEnvironment(): AuthEnvironment
	local override = environmentOverride
	if override ~= nil then
		return override
	end
	return {
		isStudio = RunService:IsStudio(),
		creatorType = if game.CreatorType == Enum.CreatorType.Group then "Group" else "User",
		creatorId = game.CreatorId,
		allowlist = AdminConfig.AdminUserIds,
		groupAdminRank = AdminConfig.GroupAdminRank,
	}
end

--[[
	Studio-only test hook: replaces the authorisation environment (nil restores the live one).
	Errors outside Studio, so a live server can never be switched into a test environment.
	Example: AdminAuth.setEnvironmentOverrideForTests({ isStudio = false, ... })
]]
function AdminAuth.setEnvironmentOverrideForTests(env: AuthEnvironment?)
	if not RunService:IsStudio() then
		error("[AdminAuth] authorization overrides are Studio-only")
	end
	environmentOverride = env
	table.clear(rankCache)
end

--[[
	Fetches a user's highest role rank in a group (0 if not a member) with the modern
	GroupService:GetRolesInGroupAsync (Player:GetRankInGroup is deprecated). Works for offline
	users too. Returns nil if the web call fails. Yields.
]]
local function fetchGroupRankAsync(userId: number, groupId: number): number?
	local ok, result = pcall(function(): any
		return (GroupService :: any):GetRolesInGroupAsync(userId, groupId)
	end)
	if not ok or type(result) ~= "table" then
		if not ok then
			warn(`[AdminAuth] group rank lookup failed for {userId}: {result}`)
		end
		return nil
	end
	local info = result :: { [string]: unknown }
	if info.IsMember ~= true then
		return 0
	end
	local best = 0
	local roles = info.Roles
	if type(roles) == "table" then
		for _, role in roles :: { unknown } do
			if type(role) == "table" then
				local rank = (role :: { [string]: unknown }).Rank
				if type(rank) == "number" and rank > best then
					best = rank
				end
			end
		end
	end
	return best
end

--[[
	The caller's group rank with caching (see the header). Yields only when a lookup is needed.
	@return the rank, or nil when unknown (deny)
]]
local function groupRankAsync(userId: number, groupId: number): number?
	local now = os.clock()
	local entry = rankCache[userId]
	if entry ~= nil and now < entry.expires then
		return entry.rank
	end
	if entry ~= nil and entry.fetching then
		-- Another thread is already asking Roblox: share its answer.
		local deadline = now + SHARED_LOOKUP_WAIT
		while entry.fetching and os.clock() < deadline do
			task.wait(0.1)
		end
		return entry.rank
	end
	local current: RankCacheEntry = entry or { rank = nil, fetchedAt = 0, expires = 0, fetching = false }
	rankCache[userId] = current
	current.fetching = true
	local rank = fetchGroupRankAsync(userId, groupId)
	current.fetching = false
	local after = os.clock()
	if rank ~= nil then
		current.rank = rank
		current.fetchedAt = after
		current.expires = after + AdminConfig.GroupRankCacheSeconds
	else
		current.expires = after + AdminConfig.GroupRankRetrySeconds
		if current.rank ~= nil and after - current.fetchedAt > AdminConfig.GroupRankMaxStaleSeconds then
			current.rank = nil -- too stale to trust: deny until a lookup succeeds again
		end
	end
	return current.rank
end

--[[
	Full authorisation check for a UserId (cache-backed; yields only when a group rank must be
	fetched). AdminService calls it on EVERY command.
	Example: if AdminAuth.isAuthorizedAsync(caller.userId) then ... end
]]
function AdminAuth.isAuthorizedAsync(userId: number): boolean
	local env = AdminAuth.currentEnvironment()
	if AdminAuth.decideAdmin(userId, env, nil) then
		return true
	end
	if env.creatorType ~= "Group" or env.isStudio or type(userId) ~= "number" or userId <= 0 then
		return false
	end
	local rank = groupRankAsync(userId, env.creatorId)
	return AdminAuth.decideAdmin(userId, env, rank)
end

--[[
	True if `userId` must not be kicked / banned through the panel: the creator, allowlisted ids,
	group admins and anyone currently holding admin rights in this server (`onlineAdmin`). Uses
	the LIVE rules (not "everyone is admin in Studio"), so Studio testers can still moderate each
	other. An unknown group rank (lookup failed) counts as protected: refusing a ban is the safe
	side. Yields for group members.
]]
function AdminAuth.isProtectedAsync(userId: number, onlineAdmin: boolean): boolean
	if onlineAdmin and not RunService:IsStudio() then
		return true
	end
	local env = table.clone(AdminAuth.currentEnvironment())
	env.isStudio = false
	if AdminAuth.decideAdmin(userId, env, nil) then
		return true
	end
	if env.creatorType == "Group" and userId > 0 then
		local rank = fetchGroupRankAsync(userId, env.creatorId)
		return rank == nil or rank >= env.groupAdminRank
	end
	return false
end

--[[ True when the cached group rank of `userId` has expired (AdminService re-checks then). ]]
function AdminAuth.rankExpired(userId: number): boolean
	local entry = rankCache[userId]
	return entry ~= nil and os.clock() >= entry.expires and not entry.fetching
end

--[[ Drops the cached rank of a user who left (Players.PlayerRemoving). ]]
function AdminAuth.forget(userId: number)
	rankCache[userId] = nil
end

return table.freeze(AdminAuth)
