--!strict
--[[
	load_benchmark_server.luau — R16 load-time benchmark (eval_server_runtime right after a solo
	playtest starts; tools/qa/load_benchmark.py drives it). Times are game seconds since the
	server DataModel started (`time()`):
		hub    Workspace.Hub has meshes and its MeshPart count is stable for 1 s
		plot   the player's plot is ready (TycoonService.isReady) and stable for 1 s
		world  Workspace.WorldReady (new loader only)
	plus MeshLibrary.stats(): request count, latency avg / p50 / p90 / max, concurrency, milestones.
]]
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local Server = ServerScriptService:WaitForChild("Server")
local MeshLibrary = (require :: any)(Server.World.MeshLibrary)
local TycoonService = (require :: any)(Server.Tycoon.TycoonService)
local PlotService = (require :: any)(Server.Tycoon.PlotService)

local result: { [string]: any } = { startedAt = time() }
local function meshCount(root: Instance?): number
	if root == nil then
		return 0
	end
	local n = 0
	for _, item in root:GetDescendants() do
		if item:IsA("MeshPart") then
			n += 1
		end
	end
	return n
end
local hubLast, hubSince, plotLast, plotSince = -1, 0, -1, 0
local deadline = time() + 150
while time() < deadline and (result.hub == nil or result.plot == nil) do
	local hub = workspace:FindFirstChild("Hub")
	local hubMeshes = meshCount(hub)
	if hubMeshes ~= hubLast then
		hubLast, hubSince = hubMeshes, time()
	elseif result.hub == nil and hubMeshes > 0 and time() - hubSince >= 1 then
		result.hub = hubSince
		result.hubMeshes = hubMeshes
	end
	local player = Players:GetPlayers()[1]
	local index = player and PlotService.getPlotIndex(player)
	local plots = workspace:FindFirstChild("Plots")
	local plot = index and plots and plots:FindFirstChild(`Plot{index}`)
	if plot ~= nil and TycoonService.isReady(player) then
		local plotMeshes = meshCount(plot)
		if plotMeshes ~= plotLast then
			plotLast, plotSince = plotMeshes, time()
		elseif result.plot == nil and time() - plotSince >= 1 then
			result.plot = plotSince
			result.plotMeshes = plotMeshes
		end
	end
	task.wait(0.1)
end
result.worldReady = workspace:GetAttribute("WorldReady")
result.worldReadySeconds = workspace:GetAttribute("WorldReadySeconds")
local stats = MeshLibrary.stats()
result.stats = stats
return HttpService:JSONEncode(result)
