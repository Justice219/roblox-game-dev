--!strict
--[[
	FlavorFeedLogic — the PURE presentation rules of Lucky Nukes (owner R120: "these popups are
	real annoying bro ngl"). No Instances, no services, no clock: callers pass `now`;
	tests/popup-feed.luau runs it. The runtime is Tycoon/FlavorController.

	Every Lucky Nuke of the local player shows as the tinted income pop over the machine (Fx/
	FlavorPops, untouched) and, by these rules, at most ONE more thing — never centre-screen:
		decide(...)   "card"  the player's FIRST find of that flavour in that world AND no card in the
		                      last Feed.Flavor.CardCooldown (5 min): the bottom-left reveal card (with
		                      the Flavour Book claim line; the server's discovery toast is then
		                      dropped as a duplicate),
		              "none"  a first find inside the cooldown (the server's "New Lucky Nuke ... Claim
		                      N Gems" toast is its pill), or a QUIET flavour (Sprinkle / Glitter) after
		                      its first find (just the income pop),
		              "pill"  everything else: one small bottom-left pill ("GALAXY nukes x20 +$31.8M"),
		                      same-flavour pills inside Feed.Flavor.MergeSeconds merge ("GALAXY x3
		                      +$95M", UI/Hud/Toasts).
		pillText(...) the pill line for a count + optional payout text (FlavorConfig.Text keys
		              FeedPill / FeedPillMerged / FeedAmount when defined, else Feed.Flavor defaults).
		bigPop(...)   other players' Big Pops (Galaxy+ batches, hatches, rebirths): at most ONE pill
		              per Feed.Flavor.BigPopGap (30 s); entries arriving inside the gap coalesce
		              into one pending pill (the rarest kept, the rest counted as "+N"), released by
		              flushBigPop when the gap is over.

	Connects to: Shared/Config/{FlavorConfig, PopupQueueConfig (Feed.Flavor)}, caller
	Tycoon/FlavorController, tests/popup-feed.luau.

	Example:
		local state = FlavorFeedLogic.new()
		FlavorFeedLogic.decide(state, { flavorId = "galaxy", worldId = "main", found = false, now = 0 })
		--> "card"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local PopupQueueConfig = require(ReplicatedStorage.Shared.Config.PopupQueueConfig)

export type Decision = "card" | "pill" | "none"

-- One other player's Big Pop entry (FlavorController's validated wire entry, `oneIn` = rarity).
export type BigPopEntry = { name: string, kind: string, id: string, label: string, oneIn: number }

export type State = {
	lastCardAt: number,
	seen: { [string]: boolean }, -- "<world>:<flavour>" found this session (first-find guard)
	bigPopShownAt: number,
	pending: BigPopEntry?, -- the coalesced Big Pop waiting for the gap to end
	pendingMore: number, -- other Big Pops folded into it
}

export type DecideInput = {
	flavorId: string,
	worldId: string,
	found: boolean, -- the player's Flavour Book already lists this flavour in this world
	now: number,
}

local Rules = PopupQueueConfig.Feed.Flavor
local Quiet = Rules.QuietIds :: { [string]: boolean }

local FlavorFeedLogic = {}

--[[ A fresh session state (no card shown yet, nothing seen). ]]
function FlavorFeedLogic.new(): State
	return { lastCardAt = -math.huge, seen = {}, bigPopShownAt = -math.huge, pending = nil, pendingMore = 0 }
end

--[[ True for the common flavours that get no pill after their first find (Sprinkle, Glitter). ]]
function FlavorFeedLogic.isQuiet(flavorId: string): boolean
	return Quiet[flavorId] == true
end

--[[
	What one Lucky Nuke of the local player shows (see the header). A "card" answer does NOT start
	the cooldown — call cardShown when the card really appeared (it may still be refused / expire).
	@param state State
	@param input DecideInput
	@return Decision
]]
function FlavorFeedLogic.decide(state: State, input: DecideInput): Decision
	local key = `{input.worldId}:{input.flavorId}`
	local first = not input.found and not state.seen[key]
	state.seen[key] = true
	if first then
		return if input.now - state.lastCardAt >= Rules.CardCooldown then "card" else "none"
	end
	if FlavorFeedLogic.isQuiet(input.flavorId) then
		return "none"
	end
	return "pill"
end

--[[ Starts the card cooldown (the reveal card appeared at `now`). ]]
function FlavorFeedLogic.cardShown(state: State, now: number)
	state.lastCardAt = now
end

-- A FlavorConfig.Text key when F-flavors defined it, else the Feed.Flavor default.
local function word(key: string, default: string): string
	local value = (FlavorConfig.Text :: any)[key]
	return if type(value) == "string" and value ~= "" then value else default
end

--[[
	The pill line: "GALAXY nukes x20 +$31.8M" (count 1) / "GALAXY x3 +$95M" (merged).
	@param def FlavorConfig.FlavorDef
	@param count number — Lucky Nukes folded into the pill (>= 1)
	@param amountText string? — the formatted payout ("$31.8M"; nil / "" = unknown)
	@return string
]]
function FlavorFeedLogic.pillText(def: FlavorConfig.FlavorDef, count: number, amountText: string?): string
	local flavour = string.upper(def.name)
	local line = if count > 1
		then string.format(word("FeedPillMerged", Rules.PillMergedText), flavour, math.floor(count))
		else string.format(word("FeedPill", Rules.PillText), flavour, FlavorConfig.multText(def.mult))
	if amountText ~= nil and amountText ~= "" then
		line ..= string.format(word("FeedAmount", Rules.PillAmountText), amountText)
	end
	return line
end

--[[
	Other players' Big Pop entries of one broadcast (best first): the pill to show NOW, if any.
	Inside the gap they coalesce into one pending entry (the rarest by `oneIn`; ties: the newest).
	@param state State
	@param entries { BigPopEntry } — already filtered (not the local player; Galaxy+ batches)
	@param more number — Big Pops the server already folded into the broadcast
	@param now number
	@return (BigPopEntry?, number) — the entry to show + how many others it stands for
	Example: FlavorFeedLogic.bigPop(state, { alex }, 0, 0) --> alex, 0
]]
function FlavorFeedLogic.bigPop(
	state: State,
	entries: { BigPopEntry },
	more: number,
	now: number
): (BigPopEntry?, number)
	if #entries == 0 then
		return nil, 0
	end
	local folded = math.max(0, math.floor(more)) + #entries - 1
	if now - state.bigPopShownAt >= Rules.BigPopGap and state.pending == nil then
		state.bigPopShownAt = now
		return entries[1], folded
	end
	local best = entries[1]
	local pending = state.pending
	if pending == nil then
		state.pending = best
		state.pendingMore = folded
	elseif best.oneIn >= pending.oneIn then
		state.pending = best
		state.pendingMore += folded + 1
	else
		state.pendingMore += folded + 1
	end
	return nil, 0
end

--[[
	Releases the coalesced Big Pop when the gap is over (call it at `nextBigPopAt`).
	@return (BigPopEntry?, number)
]]
function FlavorFeedLogic.flushBigPop(state: State, now: number): (BigPopEntry?, number)
	local pending = state.pending
	if pending == nil or now - state.bigPopShownAt < Rules.BigPopGap then
		return nil, 0
	end
	local more = state.pendingMore
	state.pending = nil
	state.pendingMore = 0
	state.bigPopShownAt = now
	return pending, more
end

--[[ When the pending Big Pop may show (nil = nothing pending). ]]
function FlavorFeedLogic.nextBigPopAt(state: State): number?
	if state.pending == nil then
		return nil
	end
	return state.bigPopShownAt + Rules.BigPopGap
end

return table.freeze(FlavorFeedLogic)
