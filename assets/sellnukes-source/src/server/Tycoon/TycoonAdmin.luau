--!strict
--[[
	TycoonAdmin — the admin panel's seam into the tycoon (B14 AdminService requires it lazily).

	Every function takes an online Player whose profile is loaded (B14 validates and clamps the
	arguments first), may yield, does its own state checks, and returns (ok, message?). Nothing
	here is reachable from a client remote directly: AdminService authorises the caller.

		setCash(player, amount)          absolute cash (finite >= 0); does NOT add to totalEarned
		setArea(player, area)            owns every pad before area `area` (build-in plays)
		unlockAll(player)                owns every pad of every area (build-in plays)
		resetPlot(player)                fresh tycoon state + cash 0, plot rebuilt
		setRebirths(player, rebirths)    integer >= 0; modifiers recompute
		rebuildPlot(player, animate)     instant rebuild from the profile, or replay every build-in

	R57 per-world seam (W4 MultiWorldHandlers; `worldId` = a NON-main WorldsConfig id, validated
	here again; the economy runtime / plot of that world is rebuilt through TycoonService):
		worldSetArea(player, worldId, area)        owns every pad before `area` (build-in when built)
		worldUnlockAll(player, worldId)            owns every pad of the world
		worldResetRun(player, worldId)             fresh tycoon + wallet 0 (rebirths / tokens / shop kept)
		worldWipe(player, worldId)                 resetRun + rebirths, tokens, shop = 0, stats.runSeconds
		                                           = 0 (unlock, unlockedAt, visits / other stats and the
		                                           bought WorldStarter flag are kept)
		worldSetCash(player, worldId, amount)      absolute world currency (not counted as earned)
		worldGrantCash(player, worldId, amount)    adds world currency (counts as earned, "admin")
		worldSetRebirths(player, worldId, n)       integer >= 0; every world recomputes (linkCash)
		worldGrantTokens(player, worldId, n)       adds whole rebirth tokens (Amber)
		worldRebuildPlot(player, worldId, animate) rebuild that world's plot (only if built this session)
		worldOfflinePreview(player, hours)         read-only: what N hours offline pays per world (rows)
		offlinePreview(player, hours)              the same as (true, { [worldId] = amount }) (W4 seam)

	Usage (B14):
		local ok, TycoonAdmin = pcall(require, ServerScriptService.Server.Tycoon.TycoonAdmin)
		local done, message = TycoonAdmin.setArea(player, 4)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModifierSources = require(script.Parent.ModifierSources)
local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService)
local PlotService = require(script.Parent.PlotService)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local OfflineService = require(script.Parent.OfflineService)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonService = require(script.Parent.TycoonService)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local TycoonAdmin = {}

-- Cash cap for admin edits (ProfileLogic clamps at 1e300 too).
local MAX_CASH = 1e300

-- Common preconditions: loaded profile and a claimed, ready plot.
local function check(player: Player, needPlot: boolean): (any, string?)
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return nil, "profile not loaded"
	end
	if needPlot and (PlotService.getPlotIndex(player) == nil or not TycoonService.isReady(player)) then
		return nil, "plot not claimed / still loading"
	end
	return profile, nil
end

--[[ Sets absolute cash (not counted as earned). ]]
function TycoonAdmin.setCash(player: Player, amount: number): (boolean, string?)
	local profile, problem = check(player, false)
	if profile == nil then
		return false, problem
	end
	if type(amount) ~= "number" or amount ~= amount or amount < 0 or amount > MAX_CASH then
		return false, "amount must be finite and >= 0"
	end
	profile.cash = amount
	PlayerDataService.markChanged(player, true, { "cash" })
	return true, `cash set to {amount}`
end

--[[ Owns every pad before area `area` starts (its Unlock pad included), with build-in. ]]
function TycoonAdmin.setArea(player: Player, area: number): (boolean, string?)
	local profile, problem = check(player, true)
	if profile == nil then
		return false, problem
	end
	if type(area) ~= "number" or area % 1 ~= 0 or area < 1 or area > #TycoonConfig.Areas then
		return false, `area must be 1..{#TycoonConfig.Areas}`
	end
	local ids: { string } = {}
	for _, pad in TycoonConfig.PadOrder do
		if pad.area < area then
			table.insert(ids, pad.id)
		end
	end
	local count = TycoonService.grantPads(player, ids, true)
	return true, `area {area} reached ({count} pads added)`
end

--[[ Owns every pad of the game, with build-in. ]]
function TycoonAdmin.unlockAll(player: Player): (boolean, string?)
	local profile, problem = check(player, true)
	if profile == nil then
		return false, problem
	end
	local ids: { string } = {}
	for _, pad in TycoonConfig.PadOrder do
		table.insert(ids, pad.id)
	end
	local count = TycoonService.grantPads(player, ids, true)
	return true, `{count} pads added`
end

--[[ Fresh tycoon (pads, producers, area 1), cash 0, plot rebuilt. Keeps the stand name. ]]
function TycoonAdmin.resetPlot(player: Player): (boolean, string?)
	local profile, problem = check(player, false)
	if profile == nil then
		return false, problem
	end
	local fresh = TycoonLogic.newState()
	fresh.standName = profile.tycoon.standName
	fresh.tutorialStep = profile.tycoon.tutorialStep
	profile.tycoon = fresh
	profile.cash = 0
	PlayerDataService.markChanged(player, true, { "tycoon", "cash" })
	TycoonService.resetRun(player, false)
	return true, "plot reset"
end

--[[ Sets the rebirth count (modifiers recompute at once). ]]
function TycoonAdmin.setRebirths(player: Player, rebirths: number): (boolean, string?)
	local profile, problem = check(player, false)
	if profile == nil then
		return false, problem
	end
	if type(rebirths) ~= "number" or rebirths % 1 ~= 0 or rebirths < 0 or rebirths > 1e6 then
		return false, "rebirths must be an integer >= 0"
	end
	profile.rebirths = rebirths
	PlayerDataService.markChanged(player, true, { "rebirths" })
	ModifierSources.invalidate(player)
	return true, `rebirths set to {rebirths}`
end

--[[ Rebuilds the plot from the profile; `animate` replays every build-in in chain order. ]]
function TycoonAdmin.rebuildPlot(player: Player, animate: boolean): (boolean, string?)
	local profile, problem = check(player, false)
	if profile == nil then
		return false, problem
	end
	if PlotService.getPlotIndex(player) == nil then
		return false, "no plot claimed"
	end
	TycoonService.resetRun(player, animate == true)
	return true, if animate then "replaying build-in" else "plot rebuilt"
end

--------------------------------------------------------------------------------------------------
-- R57: per-world commands (non-main worlds)
--------------------------------------------------------------------------------------------------

-- A NON-main world's definition + the player's state in it (or a problem message).
local function worldCheck(player: Player, worldId: unknown): (any, any, string?)
	local profile, problem = check(player, false)
	if profile == nil then
		return nil, nil, problem
	end
	local def = WorldsConfig.get(worldId)
	if def == nil or def.id == WorldsConfig.MAIN then
		return nil, nil, "unknown world"
	end
	local worlds = profile.worlds
	local state = if type(worlds) == "table" then worlds[def.id] else nil
	if type(state) ~= "table" then
		return nil, nil, `no {def.id} save data`
	end
	return def, state, nil
end

-- Owns `pads` (in chain order) in a world: with build-in when its plot is built, else state only.
local function grantWorldPads(player: Player, def: any, pads: { string }): number
	if not TycoonService.ensureWorld(player, def.id, false) then
		return 0
	end
	return TycoonService.grantPads(player, pads, TycoonService.isWorldBuilt(player, def.id))
end

--[[ Owns every pad of a world before area `area` starts (its Unlock pad included). ]]
function TycoonAdmin.worldSetArea(player: Player, worldId: string, area: number): (boolean, string?)
	local def, _state, problem = worldCheck(player, worldId)
	if def == nil then
		return false, problem
	end
	local count = #def.economy.Areas
	if type(area) ~= "number" or area % 1 ~= 0 or area < 1 or area > count then
		return false, `area must be 1..{count}`
	end
	local ids: { string } = {}
	for _, pad in def.economy.PadOrder do
		if pad.area < area then
			table.insert(ids, pad.id)
		end
	end
	local added = grantWorldPads(player, def, ids)
	return true, `{def.name} area {area} reached ({added} pads added)`
end

--[[ Owns every pad of a world. ]]
function TycoonAdmin.worldUnlockAll(player: Player, worldId: string): (boolean, string?)
	local def, _state, problem = worldCheck(player, worldId)
	if def == nil then
		return false, problem
	end
	local ids: { string } = {}
	for _, pad in def.economy.PadOrder do
		table.insert(ids, pad.id)
	end
	local added = grantWorldPads(player, def, ids)
	return true, `{def.name}: {added} pads added`
end

--[[ Fresh tycoon + wallet 0 in a world (rebirths, tokens, shop kept); its plot rebuilt. ]]
function TycoonAdmin.worldResetRun(player: Player, worldId: string): (boolean, string?)
	local def, state, problem = worldCheck(player, worldId)
	if def == nil then
		return false, problem
	end
	state.tycoon = TycoonLogic.forWorld(def.id).newState()
	state.cash = 0
	PlayerDataService.markChanged(player, true, { "worlds", "worldCash" })
	TycoonService.resetRun(player, false, def.id)
	return true, `{def.name} run reset`
end

--[[ resetRun + rebirths / tokens / shop wiped. Unlock, stats and the bought pack flag are kept. ]]
function TycoonAdmin.worldWipe(player: Player, worldId: string): (boolean, string?)
	local def, state, problem = worldCheck(player, worldId)
	if def == nil then
		return false, problem
	end
	state.tycoon = TycoonLogic.forWorld(def.id).newState()
	state.cash = 0
	state.rebirths = 0
	state.rebirthTokens = 0
	state.rebirthShop = {}
	if type(state.stats) == "table" then
		state.stats.runSeconds = 0
	end
	PlayerDataService.markChanged(player, true, { "worlds", "worldCash" })
	ModifierSources.invalidate(player)
	TycoonService.resetRun(player, false, def.id)
	return true, `{def.name} wiped`
end

--[[ Sets a world's currency (not counted as earned). ]]
function TycoonAdmin.worldSetCash(player: Player, worldId: string, amount: number): (boolean, string?)
	local def, state, problem = worldCheck(player, worldId)
	if def == nil then
		return false, problem
	end
	if type(amount) ~= "number" or amount ~= amount or amount < 0 or amount > MAX_CASH then
		return false, "amount must be finite and >= 0"
	end
	state.cash = amount
	PlayerDataService.markChanged(player, true, { "worldCash" })
	return true, `{def.currency.name} set to {amount}`
end

--[[ Adds a world's currency (counted as earned, reason "admin"). ]]
function TycoonAdmin.worldGrantCash(player: Player, worldId: string, amount: number): (boolean, string?)
	local def, _state, problem = worldCheck(player, worldId)
	if def == nil then
		return false, problem
	end
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount > MAX_CASH then
		return false, "amount must be finite and > 0"
	end
	local added = PlayerDataService.grantCurrency(player, def.currency.key, amount, "admin")
	return added > 0, `+{added} {def.currency.name}`
end

--[[ Sets a world's rebirth count (every world recomputes: multiplier + cross-world link). ]]
function TycoonAdmin.worldSetRebirths(player: Player, worldId: string, rebirths: number): (boolean, string?)
	local def, state, problem = worldCheck(player, worldId)
	if def == nil then
		return false, problem
	end
	if type(rebirths) ~= "number" or rebirths % 1 ~= 0 or rebirths < 0 or rebirths > 1e6 then
		return false, "rebirths must be an integer >= 0"
	end
	state.rebirths = rebirths
	PlayerDataService.markChanged(player, true, { "worlds" })
	ModifierSources.invalidate(player)
	return true, `{def.name} rebirths set to {rebirths}`
end

--[[ Adds whole rebirth tokens of a world (Amber). ]]
function TycoonAdmin.worldGrantTokens(player: Player, worldId: string, tokens: number): (boolean, string?)
	local def, _state, problem = worldCheck(player, worldId)
	if def == nil then
		return false, problem
	end
	if type(tokens) ~= "number" or tokens % 1 ~= 0 or tokens <= 0 or tokens > 1e9 then
		return false, "tokens must be a whole number > 0"
	end
	local added = PlayerDataService.grantWorldTokens(player, def.id, tokens, "admin")
	return added > 0, `+{added} {def.tokens.name}`
end

--[[ Rebuilds a world's plot from the profile (only when it was built this session). ]]
function TycoonAdmin.worldRebuildPlot(player: Player, worldId: string, animate: boolean): (boolean, string?)
	local def, _state, problem = worldCheck(player, worldId)
	if def == nil then
		return false, problem
	end
	if PlotService.getPlotIndex(player) == nil then
		return false, "no plot claimed"
	end
	if not TycoonService.isWorldBuilt(player, def.id) then
		return false, `{def.name} plot is not built this session (travel there first)`
	end
	TycoonService.resetRun(player, animate == true, def.id)
	return true, if animate then "replaying build-in" else `{def.name} plot rebuilt`
end

--[[
	Read-only: what `hours` offline would pay per world right now (OfflineService.preview).
	@return ok, message ("main 1.2e+12 · dino 4.5e+06"), rows
]]
function TycoonAdmin.worldOfflinePreview(
	player: Player,
	hours: number
): (boolean, string?, { { id: string, amount: number } }?)
	local profile, problem = check(player, false)
	if profile == nil then
		return false, problem, nil
	end
	if type(hours) ~= "number" or hours ~= hours or hours < 0 or hours > 1000 then
		return false, "hours must be 0..1000", nil
	end
	local rows = OfflineService.preview(player, hours * 3600)
	local parts: { string } = {}
	for _, row in rows do
		table.insert(parts, `{row.id} {string.format("%.4g", row.amount)}`)
	end
	return true, table.concat(parts, " · "), rows
end

--[[
	W4 MultiWorldHandlers seam: what `hours` offline would pay per world right now, keyed by world id
	(Nuke Town included; read-only, same caps / rates / modifiers as the join payout).
	@return ok, { [worldId]: amount } | problem message
	Example: TycoonAdmin.offlinePreview(player, 8) --> true, { main = 1.2e12, dino = 4.5e6 }
]]
function TycoonAdmin.offlinePreview(player: Player, hours: number): (boolean, any)
	local ok, message, rows = TycoonAdmin.worldOfflinePreview(player, hours)
	if not ok or rows == nil then
		return false, message
	end
	local byWorld: { [string]: number } = {}
	for _, row in rows do
		byWorld[row.id] = row.amount
	end
	return true, byWorld
end

return TycoonAdmin
