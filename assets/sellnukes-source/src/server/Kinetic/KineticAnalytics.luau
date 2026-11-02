--!strict
--[[
	KineticAnalytics — the one door from the Mega Lever + Tip Jar (owner R90, docs/kinetic.md) into
	the analytics layer: the "kinetic" recorder family (AnalyticsConfig.Metrics.kinetic documents
	and KeySpec allowlists every key). Goes through AnalyticsService.record lazily (Server/Event/
	Lazy), so the Kinetic modules never require the analytics service at load and a missing /
	failing analytics layer is simply skipped. Never yields, never throws.

	Example:
		KineticAnalytics.record(player, "pull:main")
		KineticAnalytics.record(player, "pullPaid:main", 12500)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)
local Lazy = require(script.Parent.Parent.Event.Lazy)

local KineticAnalytics = {}

--[[
	Counts one kinetic key (amount defaults to 1 in the recorder).
	@param player Player? — nil for server-level keys
	@param key string — a documented AnalyticsConfig.Metrics.kinetic pattern instance
	@param amount number? — a currency amount / count
]]
function KineticAnalytics.record(player: Player?, key: string, amount: number?)
	local record = Lazy.fn("AnalyticsService", "record")
	if record ~= nil then
		pcall(record, KineticConfig.AnalyticsFamily, player, key, amount)
	end
end

return KineticAnalytics
