--!strict
-- buildin_stats_client.luau — prints live counters of both controllers (playtest client).
local Players = game:GetService("Players")
local tycoon = Players.LocalPlayer.PlayerScripts.Client.Tycoon
local BuildIn = (require :: any)(tycoon.BuildIn.BuildInController)
local WorldFx = (require :: any)(tycoon.Fx.WorldFxController)
local b, w = BuildIn.stats(), WorldFx.stats()
local ghosts = workspace:FindFirstChild("SN_BuildGhosts")
return string.format(
	"builds=%d ghosts=%d pooled=%d ghostFolder=%d | fxTagged=%d fxActive=%d squishing=%d",
	b.builds,
	b.ghosts,
	b.pooled,
	ghosts and #ghosts:GetChildren() or 0,
	w.tagged,
	w.active,
	w.squishing
)
