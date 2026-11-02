--!strict
--[[
	BuildPlan — pure maths for the build-in animation (no Instances; unit-tested by
	tests/build-in-plan.luau under lune).

	schedule(count, cfg)   -> stagger, flight : spacing between piece launches so the whole build
	                          takes MinTotal..MaxTotal seconds whatever the piece count.
	easeOutBack / easeOutCubic / easeInOutSine : the flight curves (a tiny overshoot = "snap" in).
	clackPitch(progress)   -> pitch rising across the build (satisfying ascending clacks).
	isClack(landed, every) -> true on every N-th landed piece and on the last one.

	Example:
		local stagger, flight = BuildPlan.schedule(12, BuildInConfig)
		-- piece i launches at (i - 1) * stagger and lands flight seconds later
]]

export type ScheduleConfig = {
	Flight: number,
	MinStagger: number,
	MaxStagger: number,
	MinTotal: number,
	MaxTotal: number,
}

local BuildPlan = {}

--[[
	Launch spacing + per-piece flight time for `count` pieces.
	Total = (count - 1) * stagger + flight is pushed toward MinTotal for small builds (so even a
	2-piece purchase reads as a build) and never exceeds MaxTotal for big ones (flight shrinks to
	at most half of MaxTotal if a huge build needs it).
	@return stagger seconds, flight seconds
]]
function BuildPlan.schedule(count: number, cfg: ScheduleConfig): (number, number)
	local flight = cfg.Flight
	if count <= 1 then
		return 0, math.max(flight, cfg.MinTotal * 0.6)
	end
	local gaps = count - 1
	local stagger = math.clamp((cfg.MinTotal - flight) / gaps, cfg.MinStagger, cfg.MaxStagger)
	if gaps * stagger + flight > cfg.MaxTotal then
		flight = math.min(flight, cfg.MaxTotal * 0.5)
		stagger = math.max((cfg.MaxTotal - flight) / gaps, 0)
	end
	return stagger, flight
end

-- Overshoots ~6 % then settles: pieces "snap" into place.
function BuildPlan.easeOutBack(t: number): number
	local c1 = 1.2
	local c3 = c1 + 1
	local u = t - 1
	return 1 + c3 * u * u * u + c1 * u * u
end

function BuildPlan.easeOutCubic(t: number): number
	local u = 1 - t
	return 1 - u * u * u
end

function BuildPlan.easeInOutSine(t: number): number
	return -(math.cos(math.pi * t) - 1) / 2
end

-- Pitch for a clack at build progress 0..1 (low -> high = rising satisfaction).
function BuildPlan.clackPitch(progress: number, low: number, high: number): number
	return low + (high - low) * math.clamp(progress, 0, 1)
end

-- Clack on every `every`-th landing and always on the final piece.
function BuildPlan.isClack(landed: number, total: number, every: number): boolean
	return landed == total or (every > 0 and landed % every == 0)
end

--[[
	Sort key comparator: bottom-to-top (bottom Y rounded to 0.25 stud so tiny offsets don't fight
	the authored order), then BuildOrder, then name for determinism.
]]
function BuildPlan.before(
	aBottom: number,
	aOrder: number,
	aName: string,
	bBottom: number,
	bOrder: number,
	bName: string
): boolean
	local ka = math.floor(aBottom * 4 + 0.5)
	local kb = math.floor(bBottom * 4 + 0.5)
	if ka ~= kb then
		return ka < kb
	end
	if aOrder ~= bOrder then
		return aOrder < bOrder
	end
	return aName < bName
end

return BuildPlan
