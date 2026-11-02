--!strict
--[[
	PromptMoments — the PURE rules for WHEN the notification opt-in card suggests itself (owner
	R122 §2.3 "Opt-in reach": only ~10 % of new players ever saw the card when it waited 8
	minutes; now it comes at a strong moment in the first minutes).

	Moments (once per session; the first that happens wins):
		manager   the player hires their FIRST manager this session (owned Manager pads 0 → 1+;
		          the moment they stop clicking by hand — "he makes nukes for you, even while
		          you're away", exactly what a "your factory is full" notification is about)
		area2     else: the player reaches area 2 this session (area < 2 → >= 2)
		other     else: a returning player who already had both at join gets the card after
		          NotifyConfig.Prompt.FallbackDelaySeconds (nothing above can happen this session);
		          any other session after LateFallbackSeconds when no moment showed it
	A snapshot is { managers = owned Manager pads, area = tycoon area } of the MAIN world
	(ClientState.profile.tycoon; display data only — the server decides every reward).

	Connects to: Shared/Config/{TycoonConfig (PadsById kinds), NotifyConfig (PromptMoments)}; used by
	Screens/NotifyPrompt (init); tests/return-notify-prompt.luau.

	Example:
		local start = PromptMoments.snapshot(profile, TycoonConfig.PadsById)
		local moment = PromptMoments.momentFor(start, previous, current) --> "manager" | "area2" | nil
]]

export type Moment = "manager" | "area2" | "other"
export type Snapshot = { managers: number, area: number }

local PromptMoments = {}

--[[
	Owned pads of kind "Manager" in a pad set ({ [padId] = true }; unknown ids ignored).
	@param pads unknown — profile.tycoon.pads (server snapshot)
	@param padsById { [string]: { kind: string } } — TycoonConfig.PadsById
	@return number
]]
function PromptMoments.managerCount(pads: unknown, padsById: { [string]: any }): number
	if type(pads) ~= "table" then
		return 0
	end
	local count = 0
	for padId, owned in pads :: { [any]: any } do
		if owned == true and type(padId) == "string" then
			local def = padsById[padId]
			if def ~= nil and def.kind == "Manager" then
				count += 1
			end
		end
	end
	return count
end

--[[
	The moment-relevant snapshot of a profile, or nil when it has no main-world tycoon yet.
	@param profile unknown — ClientState.profile
	@param padsById { [string]: any } — TycoonConfig.PadsById
	@return Snapshot?
]]
function PromptMoments.snapshot(profile: unknown, padsById: { [string]: any }): Snapshot?
	if type(profile) ~= "table" then
		return nil
	end
	local tycoon = (profile :: any).tycoon
	if type(tycoon) ~= "table" then
		return nil
	end
	local area = tycoon.area
	if type(area) ~= "number" or area ~= area then
		area = 1
	end
	return { managers = PromptMoments.managerCount(tycoon.pads, padsById), area = area }
end

--[[
	The moment a change from `previous` to `current` triggers, given how the session started.
	@param start Snapshot — at the session's first profile
	@param previous Snapshot — before this change
	@param current Snapshot — after it
	@return Moment? — "manager" (first manager this session), "area2" (reached area 2 this
	        session), or nil
	Example: momentFor({managers=0,area=1}, {managers=0,area=1}, {managers=1,area=1}) --> "manager"
]]
function PromptMoments.momentFor(start: Snapshot, previous: Snapshot, current: Snapshot): Moment?
	if start.managers == 0 and previous.managers == 0 and current.managers >= 1 then
		return "manager"
	end
	if start.area < 2 and previous.area < 2 and current.area >= 2 then
		return "area2"
	end
	return nil
end

--[[
	True when no moment can happen this session (manager AND area 2 were done at join): the
	card then uses the returning-player fallback timer ("other").
]]
function PromptMoments.needsFallback(start: Snapshot): boolean
	return start.managers >= 1 and start.area >= 2
end

--[[
	The analytics moment of an open's source ("rnotify:promptAt:<moment>"): the two moments by
	name, everything else (fallback timer, Settings button, other screens) = "other".
	Example: PromptMoments.momentOfSource("settings") --> "other"
]]
function PromptMoments.momentOfSource(source: unknown): Moment
	if source == "manager" or source == "area2" then
		return source :: Moment
	end
	return "other"
end

return table.freeze(PromptMoments)
