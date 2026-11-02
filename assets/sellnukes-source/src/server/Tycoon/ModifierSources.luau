--!strict
--[[
	ModifierSources — the plug-in point for every income modifier (pets, passes, boosts, server
	boost, events). Builds the ONE Modifiers table TycoonLogic multiplies by.

	Purpose
		Income bonuses come from systems owned by different builders. Each registers a pure provider
		once; the tycoon caches the merged result per player and recomputes it only when told
		(invalidate) or when a provider's `validUntil` passes — never per tick.

	API
		ModifierSources.register(name, provider, options?)
			provider(player, profile) -> (partial Modifiers?, validUntil: number?)
			  partial    any subset of { petCash, cashPass, vip, boostCash, boostSpeed, serverCash,
			             eventCash, rushCash, friendCash } (TycoonTypes.Modifiers; the last two are
			             R78's RushService / FriendService, offline = false); merge rules in
			             TycoonRules.mergeModifiers
			             (petCash summed, booleans OR'd, multipliers multiplied)
			  validUntil os.time() seconds after which the result changes (a timed boost expiring);
			             the tycoon recomputes then automatically
			  MUST be pure and MUST NOT yield (it also runs inside product grants). Errors are caught
			  (warned once per source) and that source counts as neutral.
			options.offline = false  exclude from offline earnings (timed boosts); default true
		ModifierSources.unregister(name)
		ModifierSources.invalidate(player)       something changed (equip, boost bought, ...)
		ModifierSources.invalidateAll()          server-wide change (server boost, event start/end)
		ModifierSources.build(player, profile, offline?, worldId?) -> (Modifiers, validUntil?)
		ModifierSources.Changed: Signal(player?)  fired by invalidate (nil = everyone)
		rebirths / rebirthShop always come from the profile (no provider can set them).

	Worlds (owner R57, spec §6.1 / §6.5): providers are GLOBAL (pets, passes, boosts, server boost,
	events apply in every world). `build(..., worldId)` takes rebirths / rebirthShop from THAT
	world's track (Nuke Town: profile.rebirths / rebirthShop; Dino Valley: profile.worlds.dino
	.rebirths / .rebirthShop = the Amber shop) and sets `linkCash` = WorldsConfig.linkCash(worldId,
	rebirths of every world), so each world's rebirths boost the other. A rebirth in any world
	therefore invalidates the player (every world's runtime recomputes).

	Built in: "passes" (2x Cash → cashPass, VIP → vip) via MonetizationService.ownsPass;
	PassChanged invalidates automatically.

	Usage (B9 pets)
		ModifierSources.register("pets", function(player, profile)
			return { petCash = PetLogic.equippedBonus(profile) }
		end)
		ModifierSources.invalidate(player) -- after every equip change
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TycoonRules = require(script.Parent.TycoonRules)
local TycoonTypes = require(ReplicatedStorage.Shared.Tycoon.TycoonTypes)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type Modifiers = TycoonTypes.Modifiers
export type Provider = (player: Player, profile: any) -> (any, number?)
export type Options = { offline: boolean? }

type Source = { name: string, provider: Provider, offline: boolean, warned: boolean }

local ModifierSources = {}

ModifierSources.Changed = Signal.new() :: Signal.Signal<Player?>

local sources: { Source } = {}

--[[
	Registers (or replaces) a provider. See the header for the contract.
	@param name string — unique source name ("pets", "boosts", "serverBoost", "event")
	@param provider Provider
	@param options Options?
]]
function ModifierSources.register(name: string, provider: Provider, options: Options?)
	assert(type(name) == "string" and name ~= "", "ModifierSources.register: name required")
	assert(type(provider) == "function", "ModifierSources.register: provider must be a function")
	local offline = not (options ~= nil and options.offline == false)
	for _, source in sources do
		if source.name == name then
			source.provider = provider
			source.offline = offline
			source.warned = false
			ModifierSources.Changed:Fire(nil)
			return
		end
	end
	table.insert(sources, { name = name, provider = provider, offline = offline, warned = false })
	ModifierSources.Changed:Fire(nil)
end

--[[ Removes a provider (no-op when unknown). ]]
function ModifierSources.unregister(name: string)
	for index, source in sources do
		if source.name == name then
			table.remove(sources, index)
			ModifierSources.Changed:Fire(nil)
			return
		end
	end
end

--[[ A player's modifiers changed: the tycoon recomputes their cached stats on its next tick. ]]
function ModifierSources.invalidate(player: Player)
	ModifierSources.Changed:Fire(player)
end

--[[ Every player's modifiers changed (server-wide boost, event start / end). ]]
function ModifierSources.invalidateAll()
	ModifierSources.Changed:Fire(nil)
end

-- Runs one provider without letting it yield or throw; returns its (partial, validUntil).
local function runProvider(source: Source, player: Player, profile: any): (any, number?)
	local thread = coroutine.create(source.provider)
	local ok, partial, validUntil = coroutine.resume(thread, player, profile)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		ok, partial = false, "yielded (providers must not yield)"
	end
	if not ok then
		if not source.warned then
			source.warned = true
			warn(`[ModifierSources] provider "{source.name}" failed: {partial}`)
		end
		return nil, nil
	end
	local until_ = if type(validUntil) == "number" and validUntil == validUntil then validUntil else nil
	return partial, until_
end

-- A whole, finite, non-negative count (garbage counts as 0).
local function countOf(x: any): number
	if type(x) ~= "number" or x ~= x or x == math.huge or x < 0 then
		return 0
	end
	return math.floor(x)
end

--[[
	The rebirth counts of every world on a profile ({ main = 3, dino = 1 }) for WorldsConfig.linkCash.
	Missing / garbage entries count as 0.
]]
function ModifierSources.rebirthsByWorld(profile: any): { [string]: number }
	local counts: { [string]: number } = {}
	if type(profile) ~= "table" then
		return counts
	end
	counts[WorldsConfig.MAIN] = countOf(profile.rebirths)
	local worlds = profile.worlds
	if type(worlds) == "table" then
		for _, def in WorldsConfig.extra() do
			local state = worlds[def.id]
			counts[def.id] = if type(state) == "table" then countOf(state.rebirths) else 0
		end
	end
	return counts
end

--[[
	Builds a player's Modifiers from every registered provider + the profile's rebirth data.
	Never yields, never throws.
	@param player Player
	@param profile any — the loaded profile (rebirths, rebirthShop, worlds)
	@param offline boolean? — true: only providers registered with offline ~= false
	@param worldId string? — R57: whose rebirth track + link apply (nil = Nuke Town)
	@return Modifiers, number? — merged modifiers, earliest validUntil (os.time) of any provider
	Example: ModifierSources.build(player, profile, nil, "dino").linkCash --> 1.25 (5 Nuke Town rebirths)
]]
function ModifierSources.build(player: Player, profile: any, offline: boolean?, worldId: string?): (Modifiers, number?)
	local partials = {}
	local earliest: number? = nil
	for _, source in sources do
		if offline and not source.offline then
			continue
		end
		local partial, validUntil = runProvider(source, player, profile)
		table.insert(partials, partial)
		if validUntil ~= nil and (earliest == nil or validUntil < earliest) then
			earliest = validUntil
		end
	end
	local world = worldId or WorldsConfig.MAIN
	-- The rebirth track of the world: Nuke Town's is on the profile root, another world's under
	-- profile.worlds.<id> (missing / garbage = no rebirths, empty shop).
	local track: any = profile
	if world ~= WorldsConfig.MAIN then
		local worlds = if type(profile) == "table" then profile.worlds else nil
		track = if type(worlds) == "table" then worlds[world] else nil
	end
	local rebirths = if type(track) == "table" and type(track.rebirths) == "number" then track.rebirths else 0
	local shop = if type(track) == "table" and type(track.rebirthShop) == "table" then track.rebirthShop else {}
	local link = if WorldsConfig.get(world) ~= nil
		then WorldsConfig.linkCash(world, ModifierSources.rebirthsByWorld(profile))
		else 1
	return TycoonRules.mergeModifiers(partials, rebirths, shop, link), earliest
end

--[[
	Registers the built-in "passes" provider and the PassChanged hook. Called once by TycoonService
	in Init (kept here so the pass→modifier mapping lives with the other sources).
	@param MonetizationService any — the service (ownsPass, PassChanged)
]]
function ModifierSources.installPasses(MonetizationService: any)
	ModifierSources.register("passes", function(player: Player, _profile: any)
		return {
			cashPass = MonetizationService.ownsPass(player, "DoubleCash"),
			vip = MonetizationService.ownsPass(player, "VIP"),
		}
	end)
	MonetizationService.PassChanged:Connect(function(player: Player, passKey: string)
		if passKey == "DoubleCash" or passKey == "VIP" or passKey == "OfflineMax" or passKey == "AutoClicker" then
			ModifierSources.invalidate(player)
		end
	end)
end

return ModifierSources
