--!strict
--[[
	AnalyticsAuth — who may read analytics (the admin panel's Analytics tab, COPY FOR AI, COPY RAW
	DATA) and who counts as staff. Server only.

	>>> ADMIN SEAM (B14 admin panel builder): when Server/Services/AdminService exists and exposes
	>>> `isAuthorizedAsync(player)` (full check, may yield) and `isAdmin(player)` (cached, never
	>>> yields), both are used automatically. Until then the LOCAL FALLBACK below applies:
	>>>   Studio → everyone (spec §14), otherwise only the experience owner
	>>>   (player.UserId == game.CreatorId for a user-owned game).
	>>> Replace nothing here: just ship AdminService with those two functions.

	Every analytics request re-runs isAuthorizedAsync (never trusts the client's IsAdmin attribute);
	replies are re-checked with isAdmin right before sending.

	Example:
		if AnalyticsAuth.isAuthorizedAsync(player) then ... end
		local staff = AnalyticsAuth.isAdmin(player)
]]

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local AnalyticsAuth = {}

-- AdminService's module once found (nil = not shipped yet / not found).
local adminModule: any = nil
local searchedAt = -math.huge
local SEARCH_EVERY = 10 -- seconds between lookups while AdminService is missing

-- Finds and requires Server/Services/AdminService lazily (never at load: AdminService may
-- itself require AnalyticsService). pcall'd: a broken admin module falls back to the seam.
local function adminService(): any
	if adminModule ~= nil then
		return adminModule
	end
	if os.clock() - searchedAt < SEARCH_EVERY then
		return nil
	end
	searchedAt = os.clock()
	local server = ServerScriptService:FindFirstChild("Server")
	local services = if server ~= nil then server:FindFirstChild("Services") else nil
	local module = if services ~= nil then services:FindFirstChild("AdminService") else nil
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, value = pcall(require, module)
	if ok and type(value) == "table" then
		adminModule = value
	end
	return adminModule
end

-- The local fallback (see header): Studio, or the user who owns the experience.
local function fallback(player: Player): boolean
	if RunService:IsStudio() then
		return true
	end
	return game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId
end

--[[
	Full authorization check for an analytics request (may yield inside AdminService).
	@return true only for an admin
]]
function AnalyticsAuth.isAuthorizedAsync(player: Player): boolean
	local admin = adminService()
	if admin ~= nil and type(admin.isAuthorizedAsync) == "function" then
		local ok, verdict = pcall(admin.isAuthorizedAsync, player)
		return ok and verdict == true
	end
	return fallback(player)
end

--[[ Cached, non-yielding admin verdict (reply re-checks and the staff rule). ]]
function AnalyticsAuth.isAdmin(player: Player): boolean
	local admin = adminService()
	if admin ~= nil and type(admin.isAdmin) == "function" then
		local ok, verdict = pcall(admin.isAdmin, player)
		return ok and verdict == true
	end
	return fallback(player)
end

return table.freeze(AnalyticsAuth)
