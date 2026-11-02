--!strict
--[[
	ReplicatedFirst loading screen — entry point (a LocalScript; Rojo maps src/first to
	ReplicatedFirst, so this folder becomes ReplicatedFirst.LoadingScreen with its modules as
	children).

	Why ReplicatedFirst: its contents reach the client before anything else, so this script runs
	while the world is still streaming in. It removes Roblox's default loading screen, shows the
	branded SellNukes one on the very first frame, and keeps it up until the game is genuinely
	ready (Loader / Readiness), handing off once the client bootstrap sets ClientBooted.

	Everything it needs lives in this folder (BrandImages carries the uploaded image ids) because
	ReplicatedStorage.Shared has not replicated yet when it starts.
]]

require(script.Loader).run()
