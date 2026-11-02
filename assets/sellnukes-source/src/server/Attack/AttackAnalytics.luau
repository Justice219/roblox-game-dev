--!strict
--[[
	AttackAnalytics — Attack mode's link to the analytics layer (spec §13 "attack" family; keys are
	allowlisted in AnalyticsConfig.Metrics.attack).

	Guarded lazy require: AnalyticsService is required on first use under pcall, so Attack mode
	boots and plays even if analytics is missing or broken (analytics must never break gameplay).
	Every call is fire-and-forget and never yields or throws.

	Keys recorded (AnalyticsConfig.Metrics.attack):
		console                         Attack Console unlocked (launcher level 0 → 1)
		launch:<normal|revenge|barrage|golden> nukes launched by kind (amount = nukes)
		golden:<buy|auto|stored>        owner R85 golden revenge nukes: receipt / fired at once / stored
		intercept                       nukes intercepted by AA towers
		hit / hitCash                   nukes that hit / minted cash paid for them
		refused:<reason>                refused launches (cooldown|protected|shield|target|rate|locked|other)
		shield:<free|product>           shields activated
		aa:<aa|launcher>:<level>        upgrades bought by kind and new level (registered kind aaKind)
		targets:<0-8>                   eligible targets at each accepted launch request
		rival:<1-8>                     nukes launched at Rival Factory i (owner R43; i = its index in
		                                AttackConfig.Rivals.List; amount = nukes)
		Defence towers (owner R80; recorded for the DEFENDING player):
		tower:buy:<slot> / tower:up:<slot>:<level>   slots bought / upgraded
		tower:src:<walk|remote>         how a slot was bought (stepped on the pad / any button)
		tower:refused:<reason>          cash | locked | level (stale / repeated) | max | rate | off | other
		tower:warned / tower:admin      "you can be nuked" toast shown / admin set levels
		interceptBy:<0-9>               intercepts by tower (0 = HQ Feature tower, 1.. = slot)
		defTowers:<0-9>                 real nukes at players by the number of towers defending

	Example:
		AttackAnalytics.record(player, "launch:normal")
		AttackAnalytics.record(player, "hitCash", 12500)
]]

local ServerScriptService = game:GetService("ServerScriptService")

local AttackConfig = require(game:GetService("ReplicatedStorage").Shared.Config.AttackConfig)

local AttackAnalytics = {}

type Analytics = {
	attack: (player: Player?, key: string, amount: number?) -> (),
	registerIds: (kind: string, isValid: (id: string) -> boolean) -> boolean,
}

local service: Analytics? = nil
local resolved = false

-- The AnalyticsService module, required once (nil when missing / broken).
local function analytics(): Analytics?
	if resolved then
		return service
	end
	resolved = true
	local ok, result = pcall(function(): any
		local module = ServerScriptService.Server.Services:FindFirstChild("AnalyticsService")
		return if module ~= nil and module:IsA("ModuleScript") then require(module) :: any else nil
	end)
	if ok and type(result) == "table" and type(result.attack) == "function" then
		service = result :: any
	elseif not ok then
		warn(`[AttackAnalytics] AnalyticsService unavailable: {result}`)
	end
	return service
end

--[[
	Records one attack-family key (never throws, never yields).
	@param player Player? — the acting player (nil = server-wide)
	@param key string — an allowlisted key (see the header)
	@param amount number? — default 1
]]
function AttackAnalytics.record(player: Player?, key: string, amount: number?)
	local api = analytics()
	if api ~= nil then
		pcall(api.attack, player, key, amount)
	end
end

--[[ Registers the "aaKind" ids (upgrade kinds) once at Start. ]]
function AttackAnalytics.registerKinds()
	local api = analytics()
	if api == nil or type(api.registerIds) ~= "function" then
		return
	end
	local allowed: { [string]: boolean } = {}
	for _, kind in AttackConfig.UpgradeKinds do
		allowed[kind] = true
	end
	pcall(api.registerIds, "aaKind", function(id: string): boolean
		return allowed[id] == true
	end)
end

return AttackAnalytics
