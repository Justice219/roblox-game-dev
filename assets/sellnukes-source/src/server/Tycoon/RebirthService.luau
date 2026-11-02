--!strict
--[[
	RebirthService — Rebirth and the Rebirth Token shop (spec §2.5; RebirthConfig, docs/economy.md).

	Rebirth (remote "Rebirth", no arguments)
		Allowed only after the finale pad (TycoonLogic.canRebirth) and only in a saving session
		(PlayerDataService.canMutate: a reset that could not be saved would be a nasty surprise).
		Atomically, without yielding: tokens = rebirthReward(tycoon, rebirths); rebirths += 1;
		rebirthTokens += tokens; the tycoon resets (TycoonLogic.newState, keeping the filtered stand
		name and the finished tutorial); cash resets to the Rebirth shop's starting cash. Pets, gems,
		passes, cosmetics and everything outside `tycoon` / `cash` are kept. Saved soon, then the plot
		is rebuilt (TycoonService.resetRun) and the client told (Notify).

	RebirthShopBuy(upgradeKey)
		upgradeKey must be a RebirthConfig.Shop key (allowlist); price = rebirthShopCost(key, level);
		tokens are spent and the level raised atomically; modifiers recompute (Power Production,
		Speedy Managers, Golden Atoms take effect at once).

	Worlds (owner R57, spec §6.4 / §11; remotes Rebirth(worldId?) / RebirthShopBuy(key, worldId?))
		nil worldId = Nuke Town, exactly as above. Another world (Dino Valley) has its own track in
		profile.worlds.<w>: validated with Validate.worldIdOrMain (allowlist), the world must be
		UNLOCKED, `canRebirth` runs on that world's tycoon (own its finale pad, Golden T-Rex), the
		session must be saving, one rebirth at a time (shared busy lock). Atomically: that world's
		currency is emptied, tokens (Amber) = that world's rebirthReward, rebirths += 1, the world's
		tycoon resets to a fresh state and its wallet to the shop's starting amount (Bone Stash).
		Nothing outside profile.worlds.<w> changes (Nuke Town, pets, gems, passes). The shop key is
		allowlisted against THAT world's rebirth.Shop and paid with that world's tokens
		(PlayerDataService.trySpendWorldTokens). After any rebirth ModifierSources.invalidate
		recomputes every world (the cross-world link, linkCash, changed). WorldRebirthed fires for a
		non-main world; Rebirthed stays Nuke Town only.

	Usage: boot list after TycoonService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModifierSources = require(script.Parent.ModifierSources)
local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local RebirthConfig = require(ReplicatedStorage.Shared.Config.RebirthConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TycoonAnalytics = require(script.Parent.TycoonAnalytics)
local ProgressEvents = require(script.Parent.Parent.Progression.ProgressEvents)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonService = require(script.Parent.TycoonService)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local MAIN = WorldsConfig.MAIN

local RebirthService = {}

-- Fired after a successful rebirth with the new rebirth count (badges, leaderboards).
RebirthService.Rebirthed = Signal.new() :: Signal.Signal<Player, number>
-- R57: fired after a NON-main world's rebirth (worldId, new count). Rebirthed stays Nuke Town only.
RebirthService.WorldRebirthed = Signal.new() :: Signal.Signal<Player, string, number>

local rebirthLimiter = RateLimiter.new(2, 0.2)
local shopLimiter = RateLimiter.new(8, 4)
local busy: { [Player]: boolean } = {}

-- A non-main world's saved state on a profile (nil when absent / malformed).
local function worldStateOf(profile: any, worldId: string): any
	local worlds = if type(profile) == "table" then profile.worlds else nil
	local state = if type(worlds) == "table" then worlds[worldId] else nil
	return if type(state) == "table" then state else nil
end

--[[
	Applies a rebirth to a profile (pure state change, no yield). Exposed for the admin seam and the
	Studio tests.
	@param profile any — loaded profile
	@param worldId string? — R57: nil = Nuke Town (unchanged); another world rebirths only
	       profile.worlds.<w> (tycoon fresh, rebirths + 1, tokens added, stats.runSeconds = 0; the
	       caller resets the wallet)
	@return number — tokens granted (0 = not allowed: finale not owned / unknown world)
	Example: RebirthService.applyRebirth(profile, "dino") --> 12 (Amber)
]]
function RebirthService.applyRebirth(profile: any, worldId: string?): number
	if worldId ~= nil and worldId ~= MAIN then
		local def = WorldsConfig.get(worldId)
		local state: any = if def ~= nil then worldStateOf(profile, def.id) else nil
		if def == nil or state == nil then
			return 0
		end
		local logic = TycoonLogic.forWorld(def.id)
		if not logic.canRebirth(state.tycoon) then
			return 0
		end
		local tokens = logic.rebirthReward(state.tycoon, state.rebirths)
		state.tycoon = logic.newState()
		state.rebirths += 1
		state.rebirthTokens += tokens
		-- A new run: the run clock restarts (analytics pacing: worlds areaAt / areaB, W12).
		if type(state.stats) == "table" then
			state.stats.runSeconds = 0
		end
		return tokens
	end
	local tycoon = profile.tycoon
	if not TycoonLogic.canRebirth(tycoon) then
		return 0
	end
	local tokens = TycoonLogic.rebirthReward(tycoon, profile.rebirths)
	local fresh = TycoonLogic.newState()
	fresh.standName = tycoon.standName
	fresh.tutorialStep = tycoon.tutorialStep
	profile.tycoon = fresh
	profile.rebirths += 1
	profile.rebirthTokens += tokens
	return tokens
end

--[[
	A non-main world's rebirth (Rebirth(worldId) with an unlocked world): validate, empty the wallet,
	apply, start amount, save, analytics, rebuild that world only. The caller holds `busy`.
]]
local function rebirthWorld(player: Player, profile: any, def: WorldsConfig.WorldDef)
	local state: any = worldStateOf(profile, def.id)
	local logic = TycoonLogic.forWorld(def.id)
	if state == nil or state.unlocked ~= true or not logic.canRebirth(state.tycoon) then
		return
	end
	if not PlayerDataService.canMutate(player) then
		PlayerDataService.notify(player, "Your save is offline right now - rejoin to rebirth safely!", "error")
		return
	end
	busy[player] = true
	-- The wallet first (fires CurrencyChanged for the economy books), then the run state.
	local currency = def.currency.key
	if state.cash > 0 then
		PlayerDataService.trySpendCurrency(player, currency, state.cash, "rebirth")
	end
	local tokens = RebirthService.applyRebirth(profile, def.id)
	local startAmount = logic.startingCash(state.rebirthShop)
	if startAmount > 0 then
		PlayerDataService.grantCurrency(player, currency, startAmount, "rebirthStart")
	end
	PlayerDataService.markChanged(player, true, { "worlds", "worldCash" })
	local count = state.rebirths
	TycoonAnalytics.call("worldRebirthed", player, def.id, count, tokens)
	ProgressEvents.progress(player, "rebirth") -- R78 Quests / Pass: a rebirth (any world)
	task.defer(function()
		RebirthService.WorldRebirthed:Fire(player, def.id, count)
	end)
	-- Every world recomputes: this world's multiplier AND the other worlds' link changed.
	ModifierSources.invalidate(player)
	local multiplier = string.format("%.3g", logic.rebirthMultiplier(count, state.rebirthShop))
	PlayerDataService.notify(
		player,
		`{string.upper(def.name)} REBIRTH #{count}! +{tokens} {def.tokens.name}, x{multiplier} {def.currency.name} forever!`,
		"reward"
	)
	local ok, err = pcall(TycoonService.resetRun, player, false, def.id)
	busy[player] = nil
	if not ok then
		warn(`[RebirthService] {def.id} plot rebuild after rebirth failed: {err}`)
	end
end

-- Rebirth(worldId?): validate, apply, reset cash, save, rebuild.
local function onRebirth(player: Player, rawWorldId: unknown)
	if not rebirthLimiter:Allow(player) or busy[player] then
		return
	end
	local worldId = Validate.worldIdOrMain(rawWorldId)
	if worldId == nil then
		return
	end
	if worldId ~= MAIN then
		local def = WorldsConfig.get(worldId)
		local loaded = PlayerDataService.getProfile(player)
		if def ~= nil and loaded ~= nil then
			rebirthWorld(player, loaded, def)
		end
		return
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not TycoonLogic.canRebirth(profile.tycoon) then
		return
	end
	if not PlayerDataService.canMutate(player) then
		PlayerDataService.notify(player, "Your save is offline right now - rejoin to rebirth safely!", "error")
		return
	end
	busy[player] = true
	-- Cash first (fires CurrencyChanged for the economy books), then the run state.
	if profile.cash > 0 then
		PlayerDataService.trySpendCash(player, profile.cash, "rebirth")
	end
	local tokens = RebirthService.applyRebirth(profile)
	local startCash = TycoonLogic.startingCash(profile.rebirthShop)
	if startCash > 0 then
		PlayerDataService.grantCash(player, startCash, "rebirthStart")
	end
	PlayerDataService.markChanged(player, true, { "cash", "totalEarned", "rebirths", "rebirthTokens", "tycoon" })
	TycoonAnalytics.call("rebirthed", player, profile.rebirths, tokens)
	ProgressEvents.progress(player, "rebirth") -- R78 Quests / Pass: a Nuke Town rebirth
	local count = profile.rebirths
	task.defer(function()
		RebirthService.Rebirthed:Fire(player, count)
	end)
	ModifierSources.invalidate(player)
	local multiplier = string.format("%.3g", TycoonLogic.rebirthMultiplier(profile.rebirths, profile.rebirthShop))
	PlayerDataService.notify(
		player,
		`REBIRTH #{profile.rebirths}! +{tokens} Rebirth Tokens, x{multiplier} cash forever!`,
		"reward"
	)
	local ok, err = pcall(TycoonService.resetRun, player, false, nil)
	busy[player] = nil
	if not ok then
		warn(`[RebirthService] plot rebuild after rebirth failed: {err}`)
	end
end

--[[
	A non-main world's shop purchase: key allowlisted against THAT world's rebirth.Shop, the world
	unlocked, paid with that world's tokens (Amber).
]]
local function shopBuyWorld(player: Player, rawKey: unknown, def: WorldsConfig.WorldDef)
	local key = Validate.configKey(rawKey, def.rebirth.Shop :: { [string]: any }, 32)
	local profile = PlayerDataService.getProfile(player)
	local state: any = if profile ~= nil then worldStateOf(profile, def.id) else nil
	if key == nil or state == nil or state.unlocked ~= true then
		return
	end
	if not PlayerDataService.canMutate(player) then
		PlayerDataService.notify(player, "Your save is offline - try again in a moment!", "error")
		return
	end
	local level = state.rebirthShop[key] or 0
	local cost = TycoonLogic.forWorld(def.id).rebirthShopCost(key, level)
	if cost == math.huge then
		return -- maxed
	end
	if state.rebirthTokens < cost then
		PlayerDataService.notify(player, `Not enough {def.tokens.name}!`, "error")
		return
	end
	if not PlayerDataService.trySpendWorldTokens(player, def.id, cost, "rebirthShop") then
		return
	end
	state.rebirthShop[key] = level + 1
	PlayerDataService.markChanged(player, true, { "worlds" })
	ModifierSources.invalidate(player)
	TycoonAnalytics.call("worldRebirthShop", player, def.id, key)
end

-- RebirthShopBuy(upgradeKey, worldId?): spend tokens on the next level.
local function onShopBuy(player: Player, rawKey: unknown, rawWorldId: unknown)
	if not shopLimiter:Allow(player) then
		return
	end
	local worldId = Validate.worldIdOrMain(rawWorldId)
	if worldId == nil then
		return
	end
	if worldId ~= MAIN then
		local def = WorldsConfig.get(worldId)
		if def ~= nil then
			shopBuyWorld(player, rawKey, def)
		end
		return
	end
	local key = Validate.configKey(rawKey, RebirthConfig.Shop, 32)
	local profile = PlayerDataService.getProfile(player)
	if key == nil or profile == nil then
		return
	end
	-- A spend that cannot be saved would silently vanish on rejoin: refuse it (like Rebirth does).
	if not PlayerDataService.canMutate(player) then
		PlayerDataService.notify(player, "Your save is offline - try again in a moment!", "error")
		return
	end
	local level = profile.rebirthShop[key] or 0
	local cost = TycoonLogic.rebirthShopCost(key, level)
	if cost == math.huge then
		return -- maxed
	end
	if profile.rebirthTokens < cost then
		PlayerDataService.notify(player, "Not enough Rebirth Tokens!", "error")
		return
	end
	profile.rebirthTokens -= cost
	profile.rebirthShop[key] = level + 1
	PlayerDataService.markChanged(player, true, { "rebirthTokens", "rebirthShop" })
	ModifierSources.invalidate(player)
	TycoonAnalytics.call("tycoon", player, `rebirthShop:{key}`)
end

function RebirthService.Init() end

function RebirthService.Start()
	Remotes.onServerEvent("Rebirth", onRebirth)
	Remotes.onServerEvent("RebirthShopBuy", onShopBuy)
	Players.PlayerRemoving:Connect(function(player: Player)
		rebirthLimiter:Forget(player)
		shopLimiter:Forget(player)
		busy[player] = nil
	end)
end

return RebirthService
