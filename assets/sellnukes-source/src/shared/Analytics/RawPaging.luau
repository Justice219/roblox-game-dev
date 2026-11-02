--!strict
--[[
	RawPaging — what one page press does in the COPY RAW DATA dialog (pure decision, no UI).

	Purpose (2026-10-23 analytics fix list W1.12, review fix round):
		The COPY RAW DATA dialog (client/UI/Screens/AnalyticsExport) pages through the server's
		RAW snapshot one page at a time. A page request can fail (RateLimited, Timeout, a server
		Error, or a snapshot that is gone: Expired / NotAuthorized / BadRequest). The first
		version retried the failed page on EVERY press, so after a failure the admin could not
		go back to the pages already fetched, and an Expired snapshot re-asked the server on
		every press. This module holds the press rules so they are testable without a Studio
		client (tests/report-truncation.luau §9):
			- a press while a page is in flight does nothing (the loading page stays on screen);
			- a fetched page shows at once (no request), also from a page that failed: PREV / LB
			  always goes back to the pages already copied;
			- NEXT / RB on a page that failed with a RETRYABLE code (RateLimited, Timeout, Error)
			  retries that page instead of skipping it (every page is needed for the complete
			  data); never once the snapshot is dead (it would only fail again);
			- a page not fetched yet is requested, or, on a dead snapshot, shown with the
			  snapshot's failure and no request.
		The dialog still applies its own request spacing (MIN_PAGE_GAP) to "retry" / "request".

	How it connects:
		AnalyticsExport.turnPage → RawPaging.decide(state facts) → show / retry / request /
		deadPage / none; AnalyticsExport.fail → RawPaging.retryable(code) marks a snapshot dead.

	Example:
		local action, target = RawPaging.decide({
			page = 3, pages = 5, delta = -1, pending = false, shown = false,
			targetCached = true, errorCode = "RateLimited", dead = false,
		})
		-- action == "show", target == 2 (PREV from a failed page goes back to page 2)
]]

--[[
	The facts of the dialog a press depends on:
		page          the page on screen (1-based)
		pages         pages in the snapshot (0 = not known yet: page 1 never arrived)
		delta         -1 (PREV / LB) or +1 (NEXT / RB)
		pending       a page request is in flight
		shown         the page on screen was fetched (false = loading or failed)
		targetCached  page + delta was fetched before
		errorCode     the failure of the page on screen (nil = none)
		dead          the snapshot answered a non-retryable code: no more requests for it
]]
export type Input = {
	page: number,
	pages: number,
	delta: number,
	pending: boolean,
	shown: boolean,
	targetCached: boolean,
	errorCode: string?,
	dead: boolean,
}

--[[
	What the press does:
		"none"      nothing (in flight, out of range, or a retry that would only fail again)
		"show"      put the fetched target page on screen (no request)
		"retry"     ask the server for the failed page on screen again
		"request"   go to the target page and ask the server for it
		"deadPage"  go to the target page and show the snapshot's failure (no request)
]]
export type Action = "none" | "show" | "retry" | "request" | "deadPage"

local RawPaging = {}

-- Failure codes a press may retry; every other code (Expired, NotAuthorized, BadRequest, ...)
-- would fail again for the same snapshot.
local RETRYABLE: { [string]: boolean } =
	table.freeze({ RateLimited = true, Error = true, Timeout = true } :: { [string]: boolean })

--[[
	Whether a failed page request may be retried.
	@param code  the failure code (server code, "Timeout" or "Error"); nil = no failure
	@return true for RateLimited / Error / Timeout
	Example: RawPaging.retryable("Timeout") --> true · RawPaging.retryable("Expired") --> false
]]
function RawPaging.retryable(code: string?): boolean
	return code ~= nil and RETRYABLE[code] == true
end

--[[
	Decides one page press (rules in the module header).
	@param input  the dialog's facts (see Input)
	@return the action and the page it applies to (the page on screen for "none" / "retry")
	Example: decide({ page = 1, pages = 0, delta = 1, pending = false, shown = false,
	                  targetCached = false, errorCode = "Timeout", dead = false }) --> "retry", 1
]]
function RawPaging.decide(input: Input): (Action, number)
	local page = input.page
	if input.pending then
		return "none", page
	end
	local target = page + input.delta
	local inRange = target >= 1 and (input.pages == 0 or target <= input.pages)
	local cached = inRange and input.targetCached
	-- NEXT / RB on a failed page (and nothing fetched ahead of it): retry it, never skip it.
	if input.delta > 0 and not cached and not input.shown then
		if input.dead or not RawPaging.retryable(input.errorCode) then
			return "none", page
		end
		return "retry", page
	end
	if not inRange then
		return "none", page
	end
	if cached then
		return "show", target
	end
	if input.dead then
		return "deadPage", target
	end
	return "request", target
end

return table.freeze(RawPaging)
