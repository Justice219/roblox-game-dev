--!strict
--[[
	RobloxForwarder — mirrors key analytics events to Roblox's built-in AnalyticsService so the
	Creator Dashboard (Analytics → Economy / Funnels / Progression / Custom) gets them too.

	Purpose:
		Our own aggregates (AnalyticsService → DataStore) are the source of truth for the admin
		panel; this is a best-effort copy. Every call is:
			- server-only and from trusted events (AnalyticsService calls it),
			- pcall'd (Roblox may refuse events, e.g. in Studio or over its limits),
			- token-bucketed under Roblox's per-server event cap (AnalyticsConfig.Forward):
			  Burst events at once, refilling BasePerMinute + PerPlayerPerMinute × players.
			  Events over budget are dropped here (our aggregates still count them).
		Event names are a FIXED set (Roblox limits distinct custom event names); variable data goes
		in the three custom fields, always config ids (never names or user ids).

	Example:
		local forwarder = RobloxForwarder.new({ enabled = true })
		forwarder.economy(player, "Sink", "Coins", 250, 1200, "Shop", "hats:TopHat")
		forwarder.funnel(player, "Training", runId, 2, "Grab")
]]

local AnalyticsServiceRoblox = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)

export type Flow = "Source" | "Sink"

export type Forwarder = {
	economy: (
		player: Player,
		flow: Flow,
		currency: string,
		amount: number,
		endingBalance: number,
		transactionType: string,
		sku: string?
	) -> (),
	funnel: (player: Player, funnelName: string, sessionId: string?, step: number, stepName: string) -> (),
	onboarding: (player: Player, step: number, stepName: string) -> (),
	progression: (player: Player, path: string, level: number) -> (),
	custom: (player: Player, eventName: string, value: number, field1: string?, field2: string?) -> (),
	stats: () -> { sent: number, dropped: number, failed: number },
}

export type Options = {
	enabled: boolean,
	clock: (() -> number)?,
	playerCount: (() -> number)?,
}

local RobloxForwarder = {}

-- Roblox's custom field keys (CustomField01..03), resolved once.
local FIELD_1 = Enum.AnalyticsCustomFieldKeys.CustomField01.Name
local FIELD_2 = Enum.AnalyticsCustomFieldKeys.CustomField02.Name

--[[ Creates a forwarder. With `enabled = false` every call is a no-op (counted as dropped). ]]
function RobloxForwarder.new(options: Options): Forwarder
	local clock = options.clock or os.clock
	local playerCount = options.playerCount or function(): number
		return #Players:GetPlayers()
	end
	local limits = AnalyticsConfig.Forward
	local tokens = limits.Burst
	local refilledAt = clock()
	local sent, dropped, failed = 0, 0, 0

	-- Takes one token if the budget allows (refill = per-minute rate scaled to elapsed time).
	local function take(player: Player): boolean
		if not options.enabled or player.Parent ~= Players then
			dropped += 1
			return false
		end
		local now = clock()
		local perSecond = (limits.BasePerMinute + limits.PerPlayerPerMinute * playerCount()) / 60
		tokens = math.min(limits.Burst, tokens + (now - refilledAt) * perSecond)
		refilledAt = now
		if tokens < 1 then
			dropped += 1
			return false
		end
		tokens -= 1
		return true
	end

	-- Runs a Roblox call safely (errors are counted, never raised).
	local function call(fn: () -> ())
		local ok = pcall(fn)
		if ok then
			sent += 1
		else
			failed += 1
		end
	end

	local forwarder = {} :: Forwarder

	--[[ LogEconomyEvent: a currency source (earned) or sink (spent). ]]
	function forwarder.economy(
		player: Player,
		flow: Flow,
		currency: string,
		amount: number,
		endingBalance: number,
		transactionType: string,
		sku: string?
	)
		if amount <= 0 or not take(player) then
			return
		end
		local flowType = if flow == "Source"
			then Enum.AnalyticsEconomyFlowType.Source
			else Enum.AnalyticsEconomyFlowType.Sink
		call(function()
			AnalyticsServiceRoblox:LogEconomyEvent(
				player,
				flowType,
				currency,
				amount,
				math.max(0, endingBalance),
				transactionType,
				sku
			)
		end)
	end

	--[[
		LogFunnelStepEvent: one step of a funnel. `sessionId` = one attempt of a RECURRING funnel
		(e.g. the training course run); nil for a ONE-TIME funnel (Roblox counts each player once
		per step, e.g. the R57 "DinoValley" world funnel).
	]]
	function forwarder.funnel(player: Player, funnelName: string, sessionId: string?, step: number, stepName: string)
		if not take(player) then
			return
		end
		call(function()
			AnalyticsServiceRoblox:LogFunnelStepEvent(player, funnelName, sessionId, step, stepName)
		end)
	end

	--[[ LogOnboardingFunnelStepEvent: a first-session milestone of a new player. ]]
	function forwarder.onboarding(player: Player, step: number, stepName: string)
		if not take(player) then
			return
		end
		call(function()
			AnalyticsServiceRoblox:LogOnboardingFunnelStepEvent(player, step, stepName)
		end)
	end

	--[[
		LogProgressionEvent (Complete): a level / tier reached on a progression path.
		levelName is always supplied: when it is omitted Roblox logs "Event field levelName is
		invalid. Because the field is empty." on every call (owner report, 2026-10-13).
		Example: forwarder.progression(player, "PlayerLevel", 12) --> levelName "PlayerLevel 12"
	]]
	function forwarder.progression(player: Player, path: string, level: number)
		if not take(player) then
			return
		end
		local levelName = `{path} {level}`
		call(function()
			AnalyticsServiceRoblox:LogProgressionEvent(
				player,
				path,
				Enum.AnalyticsProgressionType.Complete,
				level,
				levelName
			)
		end)
	end

	--[[ LogCustomEvent with up to two config-id fields. ]]
	function forwarder.custom(player: Player, eventName: string, value: number, field1: string?, field2: string?)
		if not take(player) then
			return
		end
		local fields: { [string]: any }? = nil
		if field1 ~= nil or field2 ~= nil then
			local built: { [string]: any } = {}
			if field1 ~= nil then
				built[FIELD_1] = field1
			end
			if field2 ~= nil then
				built[FIELD_2] = field2
			end
			fields = built
		end
		call(function()
			AnalyticsServiceRoblox:LogCustomEvent(player, eventName, value, fields)
		end)
	end

	--[[ Counters for tests / the admin report footnote. ]]
	function forwarder.stats(): { sent: number, dropped: number, failed: number }
		return { sent = sent, dropped = dropped, failed = failed }
	end

	return forwarder
end

return table.freeze(RobloxForwarder)
