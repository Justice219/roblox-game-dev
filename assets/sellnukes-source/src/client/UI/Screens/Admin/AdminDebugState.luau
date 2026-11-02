--!strict
--[[
	AdminDebugState — the admin's LOCAL "debug overlay" switch (World tab toggle → AdminOverlay
	perf HUD). Client-only: nothing is sent to the server and nothing is authorised by it, because
	the overlay only shows numbers this client already has (its own FPS / ping / memory) plus the
	server stats the admin panel already receives.

	Why a module: the World tab (ActionsTab) flips it and the overlay screen (AdminOverlayScreen)
	draws it; both are built at different times, so they meet here instead of referencing each
	other's ScreenModules.

	Example:
		AdminDebugState.Changed:Connect(function(on) perfFrame.Visible = on end)
		AdminDebugState.set(not AdminDebugState.isOn())
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local AdminDebugState = {}

-- Fires (on: boolean) after every change.
AdminDebugState.Changed = Signal.new() :: Signal.Signal<boolean>

local on = false

--[[ True while the debug overlay is switched on. ]]
function AdminDebugState.isOn(): boolean
	return on
end

--[[ Switches the debug overlay (no-op when unchanged). ]]
function AdminDebugState.set(value: boolean)
	if value == on then
		return
	end
	on = value
	AdminDebugState.Changed:Fire(on)
end

return AdminDebugState
