--!strict
--[[
	UpgradeMode — the player's current upgrade amount (x1 / x10 / MAX) shared by every producer
	billboard, the Interact key and the billboard toggle.

	Purpose:
		The server's ProducerUpgrade intent takes a mode string ("1" | "10" | "max"); the
		client only chooses it. The choice is session-local UI state (not saved), cycled by the
		billboard toggle, Q on a keyboard or Y on a gamepad.

	Connects to: Tycoon/{ProducerBillboards, Interaction}.

	Example:
		UpgradeMode.cycle()
		print(UpgradeMode.get()) --> "10"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type Mode = "1" | "10" | "max"

local UpgradeMode = {}

-- Fires (mode) after the mode changed.
UpgradeMode.Changed = Signal.new() :: Signal.Signal<Mode>

local ORDER: { Mode } = { "1", "10", "max" }
local LABELS: { [Mode]: string } = { ["1"] = "x1", ["10"] = "x10", max = "MAX" }
local current: Mode = "1"

--[[ The current mode. ]]
function UpgradeMode.get(): Mode
	return current
end

--[[ The short label of a mode ("x1", "x10", "MAX"). ]]
function UpgradeMode.label(mode: Mode?): string
	return LABELS[mode or current]
end

--[[ Advances x1 -> x10 -> MAX -> x1. ]]
function UpgradeMode.cycle()
	local index = table.find(ORDER, current) or 1
	current = ORDER[index % #ORDER + 1]
	UpgradeMode.Changed:Fire(current)
end

return UpgradeMode
