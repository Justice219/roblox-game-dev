--!strict
--[[
	FxQuality — picks the build-in / world-FX budget tier ("Low" | "Mid" | "High") for this device
	(owner R11: console + mobile are primary; hold frame rate on a low-end phone).

	Rule (pure `compute`, unit-tested by tests/build-in-plan.luau):
		* The player's graphics quality: levels 1-3 -> Low, 4-7 -> Mid, 8-10 -> High.
		* "Automatic" quality uses the device class: Phone -> Low, Tablet / Console -> Mid,
		  Desktop -> High.
		* Phones are capped at Mid even at a high manual quality level (thermal / battery).
	The tier is cached and recomputed only when the quality setting changes (never per frame).
	Owner R103: a tier read before the camera has a real viewport is NOT cached — DeviceProfile
	classifies a touch device with no viewport yet as "Phone", which used to pin a tablet to "Low"
	for the whole session; such early reads are recomputed until the viewport is known.
	Budgets live in BuildInConfig.Tiers, WorldFxConfig.Tiers and VehicleRouteConfig.Tiers.

	Example:
		local budget = WorldFxConfig.Tiers[FxQuality.tier()]
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local DeviceProfile = require(ReplicatedStorage.Shared.Util.DeviceProfile)

export type Tier = "Low" | "Mid" | "High"

local FxQuality = {}

local RANK: { [Tier]: number } = { Low = 1, Mid = 2, High = 3 }
local BY_RANK: { Tier } = { "Low", "Mid", "High" }

local cached: Tier? = nil
local watching = false

--[[
	Pure tier rule.
	@param class string   DeviceProfile class ("Phone" | "Tablet" | "Desktop" | "Console")
	@param level number?  saved graphics quality 1..10, or nil / 0 for Automatic
]]
function FxQuality.compute(class: string, level: number?): Tier
	local tier: Tier
	if level == nil or level <= 0 then
		tier = if class == "Phone" then "Low" elseif class == "Desktop" then "High" else "Mid"
	elseif level <= 3 then
		tier = "Low"
	elseif level <= 7 then
		tier = "Mid"
	else
		tier = "High"
	end
	if class == "Phone" and RANK[tier] > RANK.Mid then
		tier = BY_RANK[RANK.Mid]
	end
	return tier
end

--[[
	Pure: true once a camera viewport is a real screen size (both sides > 1 point, finite), i.e.
	DeviceProfile's touch Phone / Tablet split can be trusted and the tier may be cached.
	Example: FxQuality.viewportReady(1, 1) --> false; FxQuality.viewportReady(1024, 768) --> true
]]
function FxQuality.viewportReady(x: number, y: number): boolean
	return x == x and y == y and x > 1 and y > 1 and x < math.huge and y < math.huge
end

-- Reads the live setting + device and caches the tier (once the viewport is known).
local function recompute(): Tier
	local level: number? = nil
	local ok, settings = pcall(function()
		return UserSettings():GetService("UserGameSettings")
	end)
	if ok and settings ~= nil then
		level = settings.SavedQualityLevel.Value -- 0 = Automatic, 1..10 manual
		if not watching then
			watching = true
			settings:GetPropertyChangedSignal("SavedQualityLevel"):Connect(function()
				cached = nil
			end)
		end
	end
	local class = DeviceProfile.current().class
	local tier = FxQuality.compute(class, level)
	-- Cache only once the device class is final (a real viewport); early reads recompute.
	local camera = Workspace.CurrentCamera
	local viewport = if camera ~= nil then camera.ViewportSize else nil
	cached = if viewport ~= nil and FxQuality.viewportReady(viewport.X, viewport.Y) then tier else nil
	return tier
end

-- The current tier (cached; recomputed after the player changes graphics quality).
function FxQuality.tier(): Tier
	return cached or recompute()
end

return FxQuality
