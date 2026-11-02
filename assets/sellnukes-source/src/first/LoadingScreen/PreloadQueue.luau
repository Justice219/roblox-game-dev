--!strict
--[[
	PreloadQueue — the loading screen's ordered, deduplicated download list (owner R122: fast first
	minute). Pure bookkeeping (no Instances, no services, no yields; tests/loading-screen.luau).

	Purpose:
		The Loader preloads in two parts (spec 2026-11-01 §2.1):
			CRITICAL  brand art, hot UI icons, this player's plot frame + owned builds + the current
			          next pads — the progress bar waits for these (within Readiness.ASSET_BUDGET);
			DEFERRED  every other hub / area mesh — downloaded after the critical list in ONE
			          low-priority background thread that keeps running after the hand-off.
		This queue holds both parts in one FIFO: critical entries first (`add(..., true)` before
		`seal()`), deferred after. `take` hands out batches that never mix the two parts, so the
		critical fraction shown on the bar is exact, and `settle` marks a returned batch loaded.

	Safety: only "rbxassetid://<digits>" ids are accepted (never a client-built path or URL, never
	id 0 = not uploaded), each id at most once across both parts. `release` drops every string so
	nothing lingers once the background preload is finished or stopped.

	Example:
		local queue = PreloadQueue.new()
		queue:add("image", "rbxassetid://123", true)
		queue:seal()
		queue:add("mesh", "rbxassetid://456", false)
		local ids, kinds = {}, {}
		local count, critical = queue:take(8, ids, kinds) --> 1, true
		-- ContentProvider:PreloadAsync(holders built from ids / kinds) ...
		queue:settle()
		print(queue:criticalDone()) --> true
]]

-- What kind of holder the Loader builds for an id (ImageLabel.Image / SpecialMesh.MeshId).
export type Kind = "image" | "mesh"

local PreloadQueue = {}
PreloadQueue.__index = PreloadQueue

export type Queue = typeof(setmetatable(
	{} :: {
		ids: { string },
		kinds: { Kind },
		seen: { [string]: boolean },
		head: number, -- index of the next entry to hand out
		criticalCount: number, -- entries 1..criticalCount are CRITICAL
		criticalLoaded: number, -- critical entries whose PreloadAsync returned / reported
		sealed: boolean, -- the critical part is complete; later adds are deferred
	},
	PreloadQueue
))

--[[
	True for a preloadable content id: "rbxassetid://" followed by a positive whole number.
	Example: PreloadQueue.validId("rbxassetid://0") --> false
]]
function PreloadQueue.validId(id: unknown): boolean
	if type(id) ~= "string" then
		return false
	end
	local digits = string.match(id, "^rbxassetid://(%d+)$")
	return digits ~= nil and #digits <= 20 and tonumber(digits) ~= nil and (tonumber(digits) :: number) > 0
end

--[[ An empty queue (critical part open). ]]
function PreloadQueue.new(): Queue
	return setmetatable({
		ids = {},
		kinds = {},
		seen = {},
		head = 1,
		criticalCount = 0,
		criticalLoaded = 0,
		sealed = false,
	}, PreloadQueue)
end

--[[
	Appends one id (skipped when invalid or already queued in either part).
	@param kind "image" | "mesh"
	@param id content id
	@param critical true = part of the critical list; ignored (deferred) once the queue is sealed
	@return true when the id was queued
]]
function PreloadQueue.add(self: Queue, kind: Kind, id: string, critical: boolean): boolean
	if not PreloadQueue.validId(id) or self.seen[id] then
		return false
	end
	if critical and not self.sealed and #self.ids > self.criticalCount then
		-- A critical id after deferred ones were queued cannot happen while the Loader seals before
		-- adding deferred ids; queue it as deferred rather than reorder the FIFO.
		critical = false
	end
	self.seen[id] = true
	table.insert(self.ids, id)
	table.insert(self.kinds, kind)
	if critical and not self.sealed then
		self.criticalCount = #self.ids
	end
	return true
end

--[[ Appends a list of ids of one kind (see add). @return how many were queued ]]
function PreloadQueue.addAll(self: Queue, kind: Kind, ids: { string }, critical: boolean): number
	local added = 0
	for _, id in ids do
		if self:add(kind, id, critical) then
			added += 1
		end
	end
	return added
end

--[[ Closes the critical part: every later add is deferred. Idempotent. ]]
function PreloadQueue.seal(self: Queue)
	self.sealed = true
end

--[[
	Hands out the next batch (at most `max` entries; a batch never mixes critical and deferred).
	@param max batch size (>= 1)
	@param outIds reused array, cleared and filled with the batch's ids
	@param outKinds reused array, cleared and filled with their kinds
	@return (count, critical) — 0 when nothing is left; critical = the batch is critical entries
]]
function PreloadQueue.take(self: Queue, max: number, outIds: { string }, outKinds: { Kind }): (number, boolean)
	table.clear(outIds)
	table.clear(outKinds)
	local first = self.head
	local total = #self.ids
	if first > total then
		return 0, false
	end
	local critical = first <= self.criticalCount
	local last = math.min(first + math.max(math.floor(max), 1) - 1, if critical then self.criticalCount else total)
	for index = first, last do
		table.insert(outIds, self.ids[index])
		table.insert(outKinds, self.kinds[index])
	end
	self.head = last + 1
	return last - first + 1, critical
end

--[[
	One asset of the current critical batch finished (PreloadAsync's per-asset callback): moves the
	bar between batches. Never counts past the handed-out critical entries.
]]
function PreloadQueue.markLoaded(self: Queue)
	self.criticalLoaded = math.min(self.criticalLoaded + 1, self.head - 1, self.criticalCount)
end

--[[ The handed-out batch returned: every handed-out critical entry counts as loaded. ]]
function PreloadQueue.settle(self: Queue)
	self.criticalLoaded = math.min(self.head - 1, self.criticalCount)
end

--[[
	Loaded share of the critical part for the progress bar, 0..1 (1 when sealed and empty). Before
	`seal` (the plot's own list is not known yet, so more critical entries will join) the share
	is halved: the bar keeps moving when the plot part is added instead of sitting at "done".
	Example: 3 of 4 critical loaded, unsealed --> 0.375; sealed --> 0.75
]]
function PreloadQueue.criticalFraction(self: Queue): number
	local share = if self.criticalCount > 0 then math.clamp(self.criticalLoaded / self.criticalCount, 0, 1) else 1
	return if self.sealed then share else share * 0.5
end

--[[ True once the critical part is sealed and every critical entry was loaded. ]]
function PreloadQueue.criticalDone(self: Queue): boolean
	return self.sealed and self.criticalLoaded >= self.criticalCount
end

--[[ Entries not handed out yet (both parts). ]]
function PreloadQueue.remaining(self: Queue): number
	return #self.ids - self.head + 1
end

--[[ Entry counts (diagnostics / tests): total, critical. ]]
function PreloadQueue.counts(self: Queue): (number, number)
	return #self.ids, self.criticalCount
end

--[[ Drops every queued id (the background preload finished or stopped). Idempotent. ]]
function PreloadQueue.release(self: Queue)
	table.clear(self.ids)
	table.clear(self.kinds)
	table.clear(self.seen)
	self.head = 1
	self.criticalCount = 0
	self.criticalLoaded = 0
	self.sealed = true
end

return PreloadQueue
