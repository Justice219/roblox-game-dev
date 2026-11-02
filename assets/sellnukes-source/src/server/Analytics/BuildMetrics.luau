--!strict
--[[
	BuildMetrics — producer identity for bounded per-release analytics slices (ported from RoBeasts).

	Purpose:
		After an update ships, the owner needs to know whether the NEW build moved the numbers. A
		day mixes old and new servers, so the recorder mirrors a small fixed set of headline counters
		under "build:<release>:p<placeVersion>:<metric>" (core family) at their ORIGINAL recording
		moment. Neither reporting, flush retries nor compaction can manufacture tags for old data.

	Identity:
		<release>       Shared/Config/VersionConfig.Current when that module exists and the value is
		                a short "1.2.3"-style string, else "unknown"
		p<placeVersion> game.PlaceVersion of the published place ("punknown" in Studio / version 0)

	Connects to: Server/Analytics/Recorder.count (mirrors allowlisted metrics), ReportSections
	("Builds" table via BuildMetrics.parse), VersionConfig (B1, optional).

	Example:
		BuildMetrics.key("core", "dau") --> "build:1.0.3:p42:dau"
		BuildMetrics.key("tycoon", "pad:a1_workbench") --> nil (not a build metric)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BuildMetrics = {}

-- Only high-level denominators / outcomes get a build slice (no device / id Cartesian product).
local METRICS: { [string]: { [string]: boolean } } = {
	core = {
		dau = true,
		new = true,
		returning = true,
		sessions = true,
		sessionSeconds = true,
		r1 = true,
		r3 = true,
		r7 = true,
		r14 = true,
		r30 = true,
		["ftue:joined"] = true,
		["ftue:loadingDone"] = true,
		-- R78 §6 first-minute steps (compare builds before / after the first-minute fix).
		["ftue:tutorialSeen"] = true,
		["ftue:firstMove"] = true,
		["ftue:firstPad"] = true,
		["ftue:firstClick"] = true,
		["ftue:firstUpgrade"] = true,
		["ftue:manager"] = true,
		["ftue:area2"] = true,
		["ftue:area3"] = true,
		["ftue:area5"] = true,
		-- R122 Roblox-aligned headline signals (compare 0.8.0 against 0.7.1 on the same keys):
		-- first-play bounce, qualified sessions, capped playtime, co-play and spend days.
		["rbx:bounce:lt60"] = true,
		["rbx:bounce:60to180"] = true,
		["rbx:session:qualified"] = true,
		["rbx:playSec"] = true,
		["rbx:coplay"] = true,
		payers = true,
	},
	-- tut:6 / tut:7 = the R122 "first manager" wall (Glow Lamp -> Uncle Atom before 0.8.0).
	tycoon = { rebirth = true, ["tut:6"] = true, ["tut:7"] = true },
	revenue = { robux = true, purchases = true },
}

-- A release string we accept as a key part: "1.2.3" style, short, no ":".
local function validRelease(value: unknown): boolean
	return type(value) == "string" and #value <= 16 and string.match(value, "^%d+%.%d+%.?%d*$") ~= nil
end

--[[
	Strict server release + published place revision. Unknown includes Studio's zero revision.
	@param version      VersionConfig.Current (any value; validated)
	@param placeVersion game.PlaceVersion (any value; validated)
	@return "<release>:p<place>"
	Example: BuildMetrics.identity("1.0.3", 42) --> "1.0.3:p42"
]]
function BuildMetrics.identity(version: unknown, placeVersion: unknown): string
	local release = if validRelease(version) then version :: string else "unknown"
	local place = "unknown"
	if
		type(placeVersion) == "number"
		and placeVersion == placeVersion
		and placeVersion % 1 == 0
		and placeVersion >= 1
		and placeVersion <= 2_147_483_647
	then
		place = string.format("%d", placeVersion)
	end
	return `{release}:p{place}`
end

-- VersionConfig.Current when B1's module exists (optional dependency; read once).
local function currentVersion(): unknown
	local config = ReplicatedStorage:FindFirstChild("Shared")
	config = if config ~= nil then config:FindFirstChild("Config") else nil
	local module = if config ~= nil then config:FindFirstChild("VersionConfig") else nil
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, value = pcall(require, module)
	if ok and type(value) == "table" then
		return (value :: any).Current
	end
	return nil
end

-- Immutable for this running server, even if a later export is produced by another release.
BuildMetrics.Producer = BuildMetrics.identity(currentVersion(), game.PlaceVersion)

--[[
	One bounded producer key for an allowlisted original counter; the caller writes its delta into
	core beside the aggregate. nil (no allocation) for every other counter.
]]
function BuildMetrics.key(family: string, metric: string): string?
	local allowed = METRICS[family]
	if allowed == nil or allowed[metric] ~= true then
		return nil
	end
	return `build:{BuildMetrics.Producer}:{metric}`
end

--[[
	Splits a stored producer key into (identity, metric), or nil for anything that is not one of the
	fixed metrics (stored data is untrusted).
	Example: BuildMetrics.parse("build:1.0.3:p42:dau") --> "1.0.3:p42", "dau"
]]
function BuildMetrics.parse(key: string): (string?, string?)
	local release, place, metric = string.match(key, "^build:([^:]+):p([^:]+):(.+)$")
	if release == nil or place == nil or metric == nil then
		return nil, nil
	end
	if release ~= "unknown" and not validRelease(release) then
		return nil, nil
	end
	if place ~= "unknown" and BuildMetrics.identity(release, tonumber(place)) ~= `{release}:p{place}` then
		return nil, nil
	end
	for _, allowed in METRICS do
		if allowed[metric] == true then
			return `{release}:p{place}`, metric
		end
	end
	return nil, nil
end

return table.freeze(BuildMetrics)
