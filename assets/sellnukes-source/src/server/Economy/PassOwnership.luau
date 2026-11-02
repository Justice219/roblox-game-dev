--!strict
--[[
    PassOwnership — recoverable, session-scoped Roblox ownership lookups.
    One live lookup and one delayed retry per pass; the initial lookup gets one automatic
    recovery attempt, timed from failure completion. Manual retries respect the same cooldown
    and coalesce. Confirmed purchases are monotonic and cancel obsolete work.
    MonetizationService supplies the Roblox boundary; tests inject time and cancellable tasks.
    (Copied unchanged in behaviour from RoBeasts.)
    An unpublished pass id (0 / non-positive / fractional / NaN — PublishedProductIds has no entry
    yet) is never looked up: `request` publishes "unowned" immediately, so the pass counts as not
    owned and the storefront shows COMING SOON (MonetizationService never prompts it either).
    Statuses published through deps.changed: "checking" | "owned" | "unowned" | "error".
    Example:
        local tracker = PassOwnership.new(deps)
        tracker.request("VIP", 1234567890)   -- one UserOwnsGamePassAsync lookup, then "owned"/"unowned"
        tracker.request("AutoHatch", 0)      -- no lookup; status "unowned"
]]
local PassOwnership = {}

type Cancel = () -> ()
export type Dependencies = {
	lookup: (number) -> boolean,
	alive: () -> boolean,
	now: () -> number,
	spawn: (() -> ()) -> Cancel,
	delay: (number, () -> ()) -> Cancel,
	changed: (string, string) -> (),
}
export type Tracker = {
	request: (string, number) -> (),
	grant: (string) -> (),
	status: (string) -> string,
	destroy: () -> (),
}

-- Seconds between lookups of the same pass (failure recovery and manual retries share it).
local COOLDOWN = 15

-- True for a usable Creator Hub id (mirrors MonetizationConfig.isConfigured; kept local so this
-- pure module has no config dependency).
local function isPublishedId(id: number): boolean
	return id == id and id > 0 and id % 1 == 0 and id ~= math.huge
end

--[[ One tracker per Player. Only server-configured catalog keys reach request/grant. ]]
function PassOwnership.new(deps: Dependencies): Tracker
	local states: { [string]: string } = {}
	local pending: { [string]: boolean } = {}
	local retryAt: { [string]: number } = {}
	local attempts: { [string]: number } = {}
	local generations: { [string]: number } = {}
	local lookups: { [string]: Cancel } = {}
	local retries: { [string]: Cancel } = {}
	local closed = false

	-- A scheduler cancellation releases closures; generations also reject late API responses.
	local function cancelIn(jobs: { [string]: Cancel }, key: string)
		local cancel = jobs[key]
		jobs[key] = nil
		if cancel ~= nil then
			cancel()
		end
	end

	local function valid(key: string, generation: number): boolean
		return not closed and deps.alive() and generations[key] == generation and states[key] ~= "owned"
	end

	-- No publication after departure, and no late false/error can revoke a confirmed purchase.
	local function publish(key: string, state: string)
		if closed or not deps.alive() then
			return
		end
		states[key] = if states[key] == "owned" then "owned" else state
		deps.changed(key, states[key])
	end

	local request: (string, number) -> ()
	-- One queued retry retains a manual intent during cooldown without spawning one task per click.
	local function queueRetry(key: string, id: number)
		if retries[key] ~= nil then
			return
		end
		local generation = generations[key] or 0
		retries[key] = deps.delay(math.max(0, (retryAt[key] or 0) - deps.now()), function()
			if not valid(key, generation) then
				return
			end
			retries[key] = nil
			request(key, id)
		end)
	end

	request = function(key: string, id: number)
		if closed or not deps.alive() or states[key] == "owned" or pending[key] then
			return
		end
		if not isPublishedId(id) then
			-- Unpublished pass: never ask Roblox about id 0; it is simply not owned.
			publish(key, "unowned")
			return
		end
		if deps.now() < (retryAt[key] or 0) then
			queueRetry(key, id)
			return
		end
		cancelIn(retries, key)
		local generation = (generations[key] or 0) + 1
		generations[key] = generation
		pending[key] = true
		attempts[key] = (attempts[key] or 0) + 1
		publish(key, "checking")
		local cancel = deps.spawn(function()
			if not valid(key, generation) then
				return
			end
			local ok, owned = pcall(deps.lookup, id)
			if not valid(key, generation) then
				return
			end
			pending[key] = nil
			lookups[key] = nil
			retryAt[key] = deps.now() + COOLDOWN
			publish(key, if ok then (if owned then "owned" else "unowned") else "error")
			-- At most two automatic attempts total. A manual attempt that replaces the queued
			-- automatic attempt counts toward this bound; later manual attempts never auto-loop.
			if not ok and attempts[key] == 1 and valid(key, generation) then
				queueRetry(key, id)
			end
		end)
		-- task.spawn may finish synchronously (a cached Roblox result); never retain a dead job.
		if pending[key] and valid(key, generation) then
			lookups[key] = cancel
		end
	end

	return {
		status = function(key: string): string
			return states[key] or "checking"
		end,
		request = request,
		grant = function(key: string)
			if closed or not deps.alive() then
				return
			end
			generations[key] = (generations[key] or 0) + 1
			pending[key] = nil
			cancelIn(retries, key)
			cancelIn(lookups, key)
			publish(key, "owned")
		end,
		destroy = function()
			if closed then
				return
			end
			closed = true
			for key in retries do
				cancelIn(retries, key)
			end
			for key in lookups do
				cancelIn(lookups, key)
			end
			table.clear(states)
			table.clear(pending)
			table.clear(retryAt)
			table.clear(attempts)
			table.clear(generations)
		end,
	}
end

return table.freeze(PassOwnership)
