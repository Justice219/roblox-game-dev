--!strict
--[[
	PassBridge — the Quests side of the contract with the Nuke Pass (R78 §2, builder P-pass): what
	the Quests screen's NUKE PASS banner and the HUD Quests badge need, read through a GUARDED
	require of Shared/Config/PassConfig so Quests works before / after the pass ships (and never
	errors if PassConfig fails to load).

	Contract used (PassConfig, shared): activeSeason(now) -> SeasonDef? { id, name, endsAt, ... },
	progress(xp) -> (tier, xpIntoTier, xpPerTier), claimableCount(passState, now) -> number, and the
	optional clockNow(baseNow) (the pass's Studio test clock), nextSeason(now) / lastEndedSeason(now)
	(the between-seasons line). Every call is type-checked + pcall'd.

	Display only: the server (PassService) owns every XP / tier / claim decision.

	Example:
		local info = PassBridge.info(ClientState.profile, Workspace:GetServerTimeNow())
		if info.season then print(info.name, info.tier, info.xpInto, info.xpPer) end
		local badge = PassBridge.claimable(ClientState.profile, Workspace:GetServerTimeNow())
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

export type Info = {
	available: boolean, -- PassConfig loaded
	season: boolean, -- a season runs now
	name: string, -- "Harvest Season" ("" without a season)
	number: number?, -- season number (1, 2, ...)
	tier: number, -- tier reached this season (0 when the pass state is from another season)
	xpInto: number, -- XP into the next step
	xpPer: number, -- XP of that step
	endsAt: number?, -- season end (server unix seconds; the pass test clock offset removed)
	startsAt: number?, -- between seasons: the next season's start (server unix seconds)
	claimable: number, -- reached, unclaimed pass rewards
}

local PassBridge = {}

-- PassConfig, required once (false = missing / failed; retried at most every RETRY seconds).
local passConfig: any = nil
local failedAt = -math.huge
local RETRY = 10

-- The PassConfig module table, or nil while it does not exist / fails to load.
local function config(): any
	if passConfig ~= nil then
		return passConfig
	end
	if os.clock() - failedAt < RETRY then
		return nil
	end
	local folder = ReplicatedStorage:FindFirstChild("Shared")
	local configs = if folder ~= nil then folder:FindFirstChild("Config") else nil
	local module = if configs ~= nil then configs:FindFirstChild("PassConfig") else nil
	if module == nil or not module:IsA("ModuleScript") then
		failedAt = os.clock()
		return nil
	end
	local ok, result = pcall(require, module)
	if not ok or type(result) ~= "table" then
		failedAt = os.clock()
		return nil
	end
	passConfig = result
	return result
end

-- A finite number, else `default`.
local function finite(value: unknown, default: number): number
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return default
end

-- The pass clock for `now` (PassConfig.clockNow when it exists: the Studio test offset).
local function clock(pass: any, now: number): number
	if type(pass.clockNow) == "function" then
		local ok, value = pcall(pass.clockNow, now)
		if ok then
			return finite(value, now)
		end
	end
	return now
end

--[[
	How many pass rewards are waiting to be claimed (0 without a pass / season / profile).
	@param profile ClientState.profile (may be nil)
	@param now     server unix seconds (Workspace:GetServerTimeNow())
]]
function PassBridge.claimable(profile: { [string]: any }?, now: number): number
	local pass = config()
	if pass == nil or profile == nil or type(pass.claimableCount) ~= "function" then
		return 0
	end
	local ok, count = pcall(pass.claimableCount, profile.pass, clock(pass, now))
	return if ok then math.max(0, math.floor(finite(count, 0))) else 0
end

--[[
	What the NUKE PASS banner shows.
	@return Info (season = false: "Season 2 is coming soon" / no pass yet)
]]
function PassBridge.info(profile: { [string]: any }?, now: number): Info
	local info: Info = {
		available = false,
		season = false,
		name = "",
		number = nil,
		tier = 0,
		xpInto = 0,
		xpPer = 1,
		endsAt = nil,
		startsAt = nil,
		claimable = 0,
	}
	local pass = config()
	if pass == nil or type(pass.activeSeason) ~= "function" then
		return info
	end
	info.available = true
	local passNow = clock(pass, now)
	-- Season instants are on the pass clock; countdowns run on the server clock.
	local offset = passNow - now
	local okSeason, season = pcall(pass.activeSeason, passNow)
	if not okSeason or type(season) ~= "table" then
		-- Between seasons: the next scheduled one ("Starts in ..."), else the number after the
		-- last ended one ("Season 2 is coming soon!").
		local nextSeason = if type(pass.nextSeason) == "function"
			then select(2, pcall(pass.nextSeason, passNow))
			else nil
		if type(nextSeason) == "table" then
			info.name = if type(nextSeason.name) == "string" then nextSeason.name else "Nuke Pass"
			info.number = if type(nextSeason.number) == "number" then nextSeason.number else nil
			info.startsAt = if type(nextSeason.startsAt) == "number" then nextSeason.startsAt - offset else nil
			return info
		end
		local last = if type(pass.lastEndedSeason) == "function"
			then select(2, pcall(pass.lastEndedSeason, passNow))
			else nil
		if type(last) == "table" and type(last.number) == "number" then
			info.number = last.number + 1
		end
		return info
	end
	info.season = true
	info.name = if type(season.name) == "string" then season.name else "Nuke Pass"
	info.number = if type(season.number) == "number" then season.number else nil
	info.endsAt = if type(season.endsAt) == "number" then season.endsAt - offset else nil
	local state: any = if profile ~= nil then profile.pass else nil
	-- XP only counts when the pass state belongs to THIS season (else the server rolls it over).
	local xp = if type(state) == "table" and state.season == season.id then state.xp else 0
	if type(pass.progress) == "function" then
		local ok, tier, into, per = pcall(pass.progress, xp)
		if ok then
			info.tier = math.max(0, math.floor(finite(tier, 0)))
			info.xpInto = math.max(0, finite(into, 0))
			info.xpPer = math.max(1, finite(per, 1))
		end
	end
	info.claimable = PassBridge.claimable(profile, now)
	return info
end

return table.freeze(PassBridge)
