--!strict
--[[
	ClientBootConfig — time budgets of the client bootstrap (owner R103: "none of the vehicles are
	animating like they used to").

	The bootstrap (Client/init.client.luau) runs every controller's Init, then every Start, in
	ORDERED order through Client/BootRunner. A phase that returns without yielding behaves exactly
	like a plain call. A phase that YIELDS is waited for (still in order) for at most its budget;
	after that the boot carries on with the controllers behind it and the phase finishes in its own
	thread (warnings name it). Before R103 one yielding phase held every later controller —
	Tycoon/Fx/VehicleRoutes included — and the ClientBooted loading-screen hand-off.

	Init is wiring only, so it gets a short budget; Start may wait for an instance that is about to
	replicate (PlayerGui, the Remotes folder), so it gets a little more. Worst case the boot waits
	(#controllers that yield) x budget, never forever.

	Connects to: Client/init.client.luau (reads it), Client/BootRunner (enforces it),
	tests/boot-runner.luau.

	Example:
		local options = { budget = ClientBootConfig.StartBudgetSeconds, warn = warn }
]]

local ClientBootConfig = {}

-- Seconds the boot waits for a controller Init that yields before moving on.
ClientBootConfig.InitBudgetSeconds = 2

-- Seconds the boot waits for a controller Start that yields before moving on.
ClientBootConfig.StartBudgetSeconds = 3

return table.freeze(ClientBootConfig)
