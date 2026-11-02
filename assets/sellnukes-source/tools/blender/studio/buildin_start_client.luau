--!strict
--[[
	buildin_start_client.luau — makes sure BuildInController + WorldFxController are started in a
	playtest client (the client boot starts them; Start() is idempotent) and slows build-ins for
	frame captures.
]]
local Players = game:GetService("Players")
local client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local tycoon = client:WaitForChild("Tycoon")
local BuildIn = (require :: any)(tycoon.BuildIn.BuildInController)
local WorldFx = (require :: any)(tycoon.Fx.WorldFxController)
BuildIn.Init()
WorldFx.Init()
BuildIn.Start()
WorldFx.Start()
BuildIn.setTimeScale(0.3)
return "started"
