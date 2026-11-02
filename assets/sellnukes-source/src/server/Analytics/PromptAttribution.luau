--!strict
--[[
	PromptAttribution — which offer surface sold a purchase (ported from RoBeasts, money push WS-F).
	Pure rules only: no services, no yields, no clocks of its own (the caller passes `now`).

	Why it exists: the report counted purchase PROMPTS by source ("prompt:<key>:<source>") but
	not completed purchases, so nobody could tell which surface sold a pack. The server already
	knows the source of every prompt it opens (folded into AnalyticsConfig.PromptSources),
	so it remembers, per player and per product / pass key, the LATEST prompt's source; the
	receipt / pass purchase then takes it and counts "purchase:<key>:<source>" +
	"robuxBySource:<source>".

	Rules:
		- one Memory per player (AnalyticsService keeps a strong { [Player]: Memory } map and
		  drops the entry on PlayerRemoving), at most AnalyticsConfig.Sales.MaxPromptsPerPlayer
		  keys (the oldest prompt is evicted first), so a player spamming prompts cannot grow it;
		- an entry older than Sales.WindowSeconds is expired (forgotten on the next remember /
		  take): the purchase counts as "unknown";
		- `take` consumes the entry: one prompt credits at most one purchase, and a later purchase
		  without a fresh prompt (a re-delivered receipt) can never inherit an old source;
		- a prompt without a source remembers Sales.NoSource ("none") so a sourceless prompt
		  (an admin / system prompt) overrides an older sourced one for the same key;
		- 2026-10-23 prompt finish (`finish`): Roblox's PromptProductPurchaseFinished /
		  PromptGamePassPurchaseFinished closes the remembered prompt ONCE; a close without a
		  purchase returns its source ("closed without buying" by product / source / device),
		  a bought close returns nil and leaves the entry for the receipt's `take`. A finish for a
		  prompt this server never opened (LocalScripts can open Roblox prompts themselves) or a
		  second finish for the same prompt returns nil, so the counts are bounded by the
		  server's own validated, rate-limited prompts.
		- [clean-data W1.16] 2026-10-23: an entry also keeps how the BUY was pressed (`via`,
		  "shortcut" | "press", optional) and `finish` returns the prompt's dwell (seconds from
		  remember to the close) with it, for promptDwell / promptDwellVia.
	Sources are stored exactly as given: the caller passes an already normalized allowlisted id.

	Example:
		local memory = PromptAttribution.new()
		PromptAttribution.remember(memory, "StarterPack", "starburst", 100)
		PromptAttribution.take(memory, "StarterPack", 130)   --> "starburst" (and forgotten)
		PromptAttribution.take(memory, "StarterPack", 131)   --> "unknown"
		PromptAttribution.remember(memory, "VIP", "popup", 200)
		PromptAttribution.finish(memory, "VIP", false, 210)   --> "popup", 10, nil (closed without buying)
		PromptAttribution.finish(memory, "VIP", false, 211)   --> nil (already closed)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)

-- One remembered prompt: its normalized source, when it was opened (caller clock, seconds),
-- whether Roblox's prompt is still open (2026-10-23: `finish` closes it once) and [clean-data
-- W1.16] how its BUY was pressed (normalized "shortcut" | "press"; nil = the client did not say).
export type Entry = { source: string, at: number, open: boolean, via: string? }
-- One player's remembered prompts, key → entry, plus the entry count (kept to bound the map).
export type Memory = { entries: { [string]: Entry }, count: number }

local Sales = AnalyticsConfig.Sales

local PromptAttribution = {}

--[[ An empty memory for one player. ]]
function PromptAttribution.new(): Memory
	return { entries = {}, count = 0 }
end

-- True when `entry` is older than the attribution window at `now`.
local function expired(entry: Entry, now: number): boolean
	return now - entry.at > Sales.WindowSeconds
end

--[[
	Forgets every expired entry. Called by remember / take (O(MaxPromptsPerPlayer) at most).
	@param memory one player's memory
	@param now    the caller's clock (seconds; the same clock as remember's `now`)
]]
function PromptAttribution.prune(memory: Memory, now: number)
	for key, entry in memory.entries do
		if expired(entry, now) then
			memory.entries[key] = nil
			memory.count -= 1
		end
	end
end

--[[
	Remembers the latest prompt for `key` (replacing an older one for the same key). When the
	memory is full the oldest entry is evicted first.
	@param memory one player's memory
	@param key    the product / pass key (config id)
	@param source the normalized prompt source, or nil when the caller passed none (→ "none")
	@param now    the caller's clock in seconds
	@param via    [clean-data W1.16] optional normalized press path ("shortcut" | "press")
	Example: remember(memory, "GemsSmall", nil, 5) --> GemsSmall remembers "none"
]]
function PromptAttribution.remember(memory: Memory, key: string, source: string?, now: number, via: string?)
	PromptAttribution.prune(memory, now)
	local entries = memory.entries
	if entries[key] == nil then
		if memory.count >= Sales.MaxPromptsPerPlayer then
			local oldestKey: string? = nil
			local oldestAt = math.huge
			for candidate, entry in entries do
				if entry.at < oldestAt or (entry.at == oldestAt and (oldestKey == nil or candidate < oldestKey)) then
					oldestKey = candidate
					oldestAt = entry.at
				end
			end
			if oldestKey ~= nil then
				entries[oldestKey] = nil
				memory.count -= 1
			end
		end
		memory.count += 1
	end
	entries[key] = { source = source or Sales.NoSource, at = now, open = true, via = via }
end

--[[
	The source to credit a completed purchase of `key` with, consuming the remembered prompt.
	@return the remembered source ("none" for a sourceless prompt), or "unknown" when no prompt
	        within the window is remembered
	Example: take(memory, "VIP", 10) --> "shop" | "none" | "unknown"
]]
function PromptAttribution.take(memory: Memory, key: string, now: number): string
	PromptAttribution.prune(memory, now)
	local entry = memory.entries[key]
	if entry == nil then
		return Sales.Unknown
	end
	memory.entries[key] = nil
	memory.count -= 1
	return entry.source
end

--[[
	2026-10-23: Roblox closed the purchase prompt for `key` (bought or not). Closes the remembered
	prompt once (see the header) and says whether to count a "closed without buying".
	@param memory one player's memory
	@param key    the product / pass key (metric spelling, as remembered)
	@param bought Roblox's isPurchased / wasPurchased flag
	@param now    the caller's clock in seconds
	@return the prompt's source when it closed WITHOUT a purchase, else nil (bought, never opened
	        by this server, already closed, or expired); [clean-data W1.16] then the dwell (seconds
	        the prompt was open, never negative) and the remembered press path (nil = unknown)
	Example: finish(memory, "PocketPack", false, 140) --> "spectate", 1.5, "shortcut"
]]
function PromptAttribution.finish(
	memory: Memory,
	key: string,
	bought: boolean,
	now: number
): (string?, number?, string?)
	PromptAttribution.prune(memory, now)
	local entry = memory.entries[key]
	if entry == nil or not entry.open then
		return nil, nil, nil
	end
	entry.open = false
	if bought then
		return nil, nil, nil
	end
	return entry.source, math.max(0, now - entry.at), entry.via
end

return table.freeze(PromptAttribution)
