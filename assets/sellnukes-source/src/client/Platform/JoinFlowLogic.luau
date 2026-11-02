--!strict
--[[
	JoinFlowLogic — the pure rules of the join pop-up queue (Platform/JoinFlow, owner R78 §6:
	"one join-time popup queue so only one thing asks for attention at a time and nothing
	auto-opens over the tutorial's first steps"). No Instances; tests/ftue-logic.luau.

	Rules:
		CALM  = the loading screen handed over, no plot-reveal camera, no window open, the HUD is
		        not in focus mode, no Roblox purchase prompt. Pop-ups open only in a calm moment
		        that lasted FtueConfig.Join.GapSeconds (one thing at a time, with a breath between).
		ORDER = highest priority first (FtueConfig.Join.Priority), then the oldest request.
		HOLD  = during the guided first-minute tutorial steps (FtueConfig.isGuided) only items at
		        or above Priority.Essential may open (Welcome Back's offline cash, the tutorial's
		        own coach card); the rest waits until the player bought their first upgrade.
		EXPIRY= an item that found no moment within MaxWaitSeconds is dropped (never stale).

	Connects to: Platform/JoinFlow (runtime), Shared/Config/FtueConfig.

	Example:
		local item, why = JoinFlowLogic.pick(items, facts)
		if item then open(item.key) else print(why) end -- "loading" / "reveal" / "modal" / "gap" / "guided"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FtueConfig = require(ReplicatedStorage.Shared.Config.FtueConfig)

local Join = FtueConfig.Join

export type Item = {
	key: string,
	priority: number,
	queuedAt: number, -- os.clock() of the (latest) request
	order: number, -- request counter (stable tie-break inside one clock tick)
}

export type Facts = {
	now: number,
	loadingDone: boolean,
	revealPlaying: boolean,
	modalOpen: boolean,
	focusMode: boolean,
	purchaseFlow: boolean,
	guided: boolean, -- the tutorial is on a guided first-minute step
	calmSince: number?, -- os.clock() since when the moment has been calm (nil = not calm)
}

local JoinFlowLogic = {}

--[[
	Why the moment is NOT calm (first blocker), or nil when it is.
	@return "loading" | "reveal" | "modal" | "focus" | "purchase" | nil
]]
function JoinFlowLogic.blocker(facts: Facts): string?
	if not facts.loadingDone then
		return "loading"
	elseif facts.revealPlaying then
		return "reveal"
	elseif facts.modalOpen then
		return "modal"
	elseif facts.focusMode then
		return "focus"
	elseif facts.purchaseFlow then
		return "purchase"
	end
	return nil
end

--[[ True when an item of `priority` may open during the guided tutorial steps. ]]
function JoinFlowLogic.allowedWhileGuided(priority: number): boolean
	return priority >= Join.Priority.Essential
end

--[[
	True when the calm moment has lasted long enough for a pop-up (blocker nil + the gap).
	@param facts current facts (calmSince maintained by the caller)
]]
function JoinFlowLogic.settled(facts: Facts): boolean
	local since = facts.calmSince
	return JoinFlowLogic.blocker(facts) == nil and since ~= nil and facts.now - since >= Join.GapSeconds
end

--[[
	The item to open now, or nil plus the reason nothing may open.
	@param items pending items (any order)
	@param facts current facts
	@return (item?, reason?) — reason: a blocker, "gap", "guided" or "empty"
]]
function JoinFlowLogic.pick(items: { Item }, facts: Facts): (Item?, string?)
	if #items == 0 then
		return nil, "empty"
	end
	local blocked = JoinFlowLogic.blocker(facts)
	if blocked ~= nil then
		return nil, blocked
	end
	if not JoinFlowLogic.settled(facts) then
		return nil, "gap"
	end
	local best: Item? = nil
	for _, item in items do
		if not facts.guided or JoinFlowLogic.allowedWhileGuided(item.priority) then
			local current = best
			if
				current == nil
				or item.priority > current.priority
				or (item.priority == current.priority and item.order < current.order)
			then
				best = item
			end
		end
	end
	if best == nil then
		return nil, "guided"
	end
	return best, nil
end

--[[ True when a pending item waited longer than FtueConfig.Join.MaxWaitSeconds. ]]
function JoinFlowLogic.expired(item: Item, now: number): boolean
	return now - item.queuedAt > Join.MaxWaitSeconds
end

return table.freeze(JoinFlowLogic)
