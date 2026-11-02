--!strict
--[[
	vehicle_check_client.luau — CLIENT half of the R56 vehicle capture run (eval_client_runtime,
	driven by tools/qa/vehicle_check.py while V1 holds the Studio lock).

		COMMAND  "start" | "world" | "frame" | "seek" | "stats" | "scale" | "clean"
		ARGS     numbers only (the driver whitelists the command and formats the numbers):
		  start                      require + Start Client/Tycoon/Fx/VehicleRoutes (idempotent)
		  world  area, x, y, z       slot-local point of MY plot -> world "x,y,z" (server focus)
		  frame  area, ex, ey, ez, tx, ty, tz, fov
		                             Scriptable camera from a slot-local eye to a slot-local target
		  seek   route, segment, f   route = index into VehicleRouteConfig.Routes; jumps the route's
		                             clock to `f` (0..1) through timeline segment `segment`
		  stats                      VehicleRoutes.stats() + FxQuality tier + clocks (JSON)
		  scale  s                   VehicleRoutes.setTimeScale(s)
		  clean                      disables post blur / depth of field (modal panels) for captures
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local COMMAND = "__COMMAND__"
local ARGS: { number } = { --[[ARGS]]
}

local Client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Fx = Client:WaitForChild("Tycoon"):WaitForChild("Fx")
local VehicleRoutes = (require :: any)(Fx:WaitForChild("VehicleRoutes"))
local FxQuality = (require :: any)(Fx:WaitForChild("FxQuality"))
local VehicleRouteConfig = (require :: any)(ReplicatedStorage.Shared.Config.VehicleRouteConfig)
local WorldLayout = (require :: any)(ReplicatedStorage.Shared.Config.WorldLayout)

local function myPlot(): number
	local index = Players.LocalPlayer:GetAttribute("PlotIndex")
	return if type(index) == "number" then index else 0
end

local function slotPoint(area: number, x: number, y: number, z: number): Vector3
	return WorldLayout.slotOrigin(myPlot(), area) * Vector3.new(x, y, z)
end

if COMMAND == "start" then
	VehicleRoutes.Start()
	return HttpService:JSONEncode(VehicleRoutes.stats())
elseif COMMAND == "world" then
	local p = slotPoint(ARGS[1], ARGS[2], ARGS[3], ARGS[4])
	return string.format("%.2f,%.2f,%.2f", p.X, p.Y, p.Z)
elseif COMMAND == "frame" then
	local camera = workspace.CurrentCamera
	local eye = slotPoint(ARGS[1], ARGS[2], ARGS[3], ARGS[4])
	local target = slotPoint(ARGS[1], ARGS[5], ARGS[6], ARGS[7])
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = ARGS[8] or 60
	camera.CFrame = CFrame.lookAt(eye, target)
	camera.Focus = CFrame.new(target)
	return "framed"
elseif COMMAND == "seek" then
	local route = VehicleRouteConfig.Routes[ARGS[1]]
	if route == nil then
		return "ERROR bad route"
	end
	local timeline = VehicleRoutes.timeline(route.id)
	if timeline == nil then
		return `ERROR {route.id} not streamed in`
	end
	local seg = timeline.segs[ARGS[2]]
	if seg == nil then
		return "ERROR bad segment"
	end
	local t = seg.t0 + (seg.t1 - seg.t0) * math.clamp(ARGS[3], 0, 1)
	VehicleRoutes.seek(route.id, t)
	return `seek {route.id} {string.format("%.2f", t)} / {string.format("%.1f", timeline.period)}`
elseif COMMAND == "stats" then
	local stats = VehicleRoutes.stats()
	return HttpService:JSONEncode({
		stats = stats,
		tier = FxQuality.tier(),
		clocks = VehicleRoutes.clocks(),
	})
elseif COMMAND == "clean" then
	-- Modal panels (Welcome Back / What's New) blur the world behind them: switch every post blur /
	-- depth-of-field off for the capture (playtest DataModel only; the playtest is stopped after).
	local count = 0
	for _, root in { game:GetService("Lighting"), workspace.CurrentCamera } do
		for _, effect in root:GetDescendants() do
			if effect:IsA("BlurEffect") or effect:IsA("DepthOfFieldEffect") then
				(effect :: any).Enabled = false
				count += 1
			end
		end
	end
	return `cleaned {count}`
elseif COMMAND == "scale" then
	VehicleRoutes.setTimeScale(ARGS[1])
	return "scaled"
end
return `ERROR unknown command {COMMAND}`
