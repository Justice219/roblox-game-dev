--!strict
--[[
	RewardGrant — the live boundary around RewardLogic for every B7 service: applies a reward to a
	player's profile, marks exactly the touched fields, reports currency to analytics and owns two
	extension seams.

	grant(player, reward, reason, opts?)   claim paths (daily, time, wheel, codes, group, notify):
	                                        profile loaded → RewardLogic.apply → markChanged(fields ∪
	                                        opts.extraFields, opts.saveSoon) → announce. No yield.
	applyInReceipt(player, profile, reward, reason, options?)
	                                        product handlers: RewardLogic.apply only (the receipt
	                                        path saves + pushes); announce() is deferred so nothing
	                                        it triggers can yield inside the grant step. Robux
	                                        rewards pass { paidSpins = true } so their spins land
	                                        in the gated paid bank (RewardLogic header).
	announce(player, profile, summary, reason)  fires PlayerDataService.CurrencyChanged for the cash /
	                                        gems a reward paid, DEFERRED (task.defer) — the shared
	                                        analytics hook sees reward income like any other grant.
	registerItemGranter(kind, fn)           the pets system (B9) registers "pet" / "egg" granters;
	                                        until then items pay their fallback gems.
	track(player, key, amount?)             AnalyticsService.retention via a guarded lazy require
	                                        (never errors, never yields; a missing analytics
	                                        service is simply skipped).

	Example:
		local summary = RewardGrant.grant(player, day.reward, "daily", { saveSoon = true, extraFields = { "daily" } })
		if summary then PlayerDataService.notify(player, RewardLogic.describe(summary), "reward") end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerDataService = require(ServerScriptService.Server.Services.PlayerDataService)
local ProfileLogic = require(ServerScriptService.Server.Economy.ProfileLogic)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local ModifierHook = require(script.Parent.ModifierHook)
local RewardLogic = require(script.Parent.RewardLogic)

type Profile = ProfileLogic.Profile

export type GrantOptions = {
	saveSoon: boolean?, -- ask for a save within seconds (one-time claims)
	extraFields: { string }?, -- snapshot fields the caller changed besides the reward ("daily", ...)
}

local RewardGrant = {}

local granters: RewardLogic.Granters = {}

--[[
	Registers the item granter of a kind ("pet" | "egg"); B9 calls this in its Init. The granter
	must not yield and must return true only when it really added the item. Errors on a second
	registration (exactly one owner per kind).
	Example: RewardGrant.registerItemGranter("pet", function(profile, petId) return PetLogic.add(profile, petId) end)
]]
function RewardGrant.registerItemGranter(kind: "pet" | "egg", granter: RewardLogic.ItemGranter)
	local existing = if kind == "pet" then granters.pet else granters.egg
	if existing ~= nil then
		error(`[RewardGrant] a {kind} granter is already registered`)
	end
	if kind == "pet" then
		granters.pet = granter
	else
		granters.egg = granter
	end
end

--[[ The registered granters (read-only use: RewardLogic.apply). ]]
function RewardGrant.granters(): RewardLogic.Granters
	return granters
end

-- AnalyticsService, required lazily and guarded (it may not exist / may fail to load).
local analyticsService: any = nil
local analyticsResolved = false
local function analytics(): any
	if not analyticsResolved then
		analyticsResolved = true
		local module = ServerScriptService.Server.Services:FindFirstChild("AnalyticsService")
		if module ~= nil and module:IsA("ModuleScript") then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				analyticsService = result
			end
		end
	end
	return analyticsService
end

--[[
	Counts a retention analytics key (AnalyticsConfig "retention" family, e.g. "daily:claim:3").
	Never errors or yields.
]]
function RewardGrant.track(player: Player?, key: string, amount: number?)
	local service = analytics()
	if service ~= nil and type(service.retention) == "function" then
		pcall(service.retention, player, key, amount)
	end
end

--[[ Registers an analytics id kind (e.g. "sliceId", "codeId"); guarded. ]]
function RewardGrant.registerIds(kind: string, isValid: (id: string) -> boolean)
	local service = analytics()
	if service ~= nil and type(service.registerIds) == "function" then
		pcall(service.registerIds, kind, isValid)
	end
end

--[[
	Reports the currency a reward paid through PlayerDataService.CurrencyChanged, deferred so no
	listener can ever run (or yield) inside the caller's grant step.
]]
function RewardGrant.announce(player: Player, profile: Profile, summary: RewardLogic.Summary, reason: string)
	if summary.cash <= 0 and summary.gems <= 0 then
		return
	end
	task.defer(function()
		if summary.cash > 0 then
			PlayerDataService.CurrencyChanged:Fire(player, "cash", summary.cash, reason, profile.cash)
		end
		if summary.gems > 0 then
			PlayerDataService.CurrencyChanged:Fire(player, "gems", summary.gems, reason, profile.gems)
		end
	end)
end

--[[
	Applies a reward inside a product handler (no markChanged: the receipt path commits + pushes).
	@param options RewardLogic.ApplyOptions (paidSpins for Robux-bought spins)
	@return the summary
]]
function RewardGrant.applyInReceipt(
	player: Player,
	profile: Profile,
	reward: RetentionConfig.Reward,
	reason: string,
	options: RewardLogic.ApplyOptions?
): RewardLogic.Summary
	local summary = RewardLogic.apply(profile, reward, os.time(), granters, nil, options)
	RewardGrant.announce(player, profile, summary, reason)
	if summary.boost ~= nil then
		task.defer(ModifierHook.invalidate, player) -- never inside the grant step
	end
	return summary
end

--[[
	Grants a reward on a claim path (see the header). The caller has already checked canMutate
	and recorded the claim in the SAME step (no yield in between).
	@return the summary, or nil when the profile is not loaded
]]
function RewardGrant.grant(
	player: Player,
	reward: RetentionConfig.Reward,
	reason: string,
	options: GrantOptions?
): RewardLogic.Summary?
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return nil
	end
	local summary = RewardLogic.apply(profile, reward, os.time(), granters)
	local fields = table.clone(summary.fields)
	if options ~= nil and options.extraFields ~= nil then
		for _, field in options.extraFields do
			if not table.find(fields, field) then
				table.insert(fields, field)
			end
		end
	end
	PlayerDataService.markChanged(player, options ~= nil and options.saveSoon == true, fields)
	RewardGrant.announce(player, profile, summary, reason)
	if summary.boost ~= nil then
		ModifierHook.invalidate(player)
	end
	return summary
end

return table.freeze(RewardGrant)
