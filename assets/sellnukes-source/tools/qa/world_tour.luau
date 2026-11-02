--!strict
--[[
	world_tour.luau — SERVER half of the World-QA camera tour (run by tools/qa/world_tour.py
	through the Studio MCP `eval_server_runtime`, in a solo playtest, holding the B4 Studio lock).

	The driver substitutes the two placeholders below with whitelisted values only:
		COMMAND  one of "prepare" | "partial" | "full" | "plan" | "focus" | "zfight" | "restore"
		ARGS     a Luau table literal of numbers built by the driver (focus x/y/z)

	Commands (all through the REAL game code):
		prepare  waits for the player's profile + plot, ensures the hub (HubBuilder.build, idempotent),
		         snapshots owned pads + cash for restore, returns the plot index
		partial  TycoonAdmin.resetPlot -> setArea(4) (areas 1-3 complete) -> rebuildPlot(false),
		         waits until the plot stops changing
		full     TycoonAdmin.unlockAll (every pad of all 10 areas) -> rebuildPlot(false), waits
		plan     returns the shot list (JSON): hub x2, entrance, each area x2 (road + high), aerial,
		         and the partial-build views; positions from WorldLayout so they track the layout
		focus    anchors the character at ARGS (camera-side ground point) and streams around it
		zfight   live ZFight box audit (owner R18) over the hub + built plot: count + offenders
		restore  resetPlot, re-grants the snapshotted pads (no build-in) and cash, un-anchors

	Everything is server-authoritative admin seam usage (src/server/Tycoon/TycoonAdmin.luau); the
	Studio DataStore is separate from production, and `restore` puts the test profile back.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local COMMAND = "__COMMAND__"
local ARGS: { number } = { --[[ARGS]]
}

local Server = ServerScriptService:WaitForChild("Server")
local TycoonAdmin = (require :: any)(Server.Tycoon.TycoonAdmin)
local TycoonService = (require :: any)(Server.Tycoon.TycoonService)
local PlotService = (require :: any)(Server.Tycoon.PlotService)
local PlayerDataService = (require :: any)(Server.Services.PlayerDataService)
local HubBuilder = (require :: any)(Server.World.HubBuilder)
local WorldLayout = (require :: any)(ReplicatedStorage.Shared.Config.WorldLayout)

local player = Players:GetPlayers()[1]
if player == nil then
	return "ERROR no player"
end

local function plotModel(): Model?
	local index = PlotService.getPlotIndex(player)
	local plots = workspace:FindFirstChild("Plots")
	return if index ~= nil and plots ~= nil then plots:FindFirstChild(`Plot{index}`) :: Model? else nil
end

-- Waits until the plot's descendant count is unchanged for `settle` seconds (or `limit` passes).
local function waitStable(settle: number, limit: number): number
	local model = plotModel()
	if model == nil then
		return -1
	end
	local last, stableSince, started = -1, os.clock(), os.clock()
	while os.clock() - started < limit do
		local count = #model:GetDescendants()
		if count ~= last then
			last, stableSince = count, os.clock()
		elseif os.clock() - stableSince >= settle then
			break
		end
		task.wait(0.25)
	end
	return last
end

local function v3(v: Vector3): { number }
	return { math.round(v.X * 100) / 100, math.round(v.Y * 100) / 100, math.round(v.Z * 100) / 100 }
end

if COMMAND == "prepare" then
	local started = os.clock()
	while
		(PlotService.getPlotIndex(player) == nil or not TycoonService.isReady(player)) and os.clock() - started < 60
	do
		task.wait(0.25)
	end
	HubBuilder.build()
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return "ERROR profile not loaded"
	end
	local pads: { string } = {}
	for key, value in profile.tycoon.pads do
		table.insert(pads, if type(key) == "string" then key else tostring(value))
	end
	player:SetAttribute("QaPads", HttpService:JSONEncode(pads))
	player:SetAttribute("QaCash", profile.cash)
	return `ready plot={PlotService.getPlotIndex(player)} pads={#pads}`
elseif COMMAND == "partial" then
	TycoonAdmin.resetPlot(player)
	local ok, message = TycoonAdmin.setArea(player, 4)
	TycoonAdmin.rebuildPlot(player, false)
	return `partial {ok} {message} descendants={waitStable(3, 90)}`
elseif COMMAND == "full" then
	local ok, message = TycoonAdmin.unlockAll(player)
	TycoonAdmin.rebuildPlot(player, false)
	return `full {ok} {message} descendants={waitStable(3, 150)}`
elseif COMMAND == "plan" then
	local index = PlotService.getPlotIndex(player) :: number
	local entrance = WorldLayout.plotOrigin(index)
	local shots = {}
	local function add(name: string, eye: Vector3, target: Vector3, focus: Vector3, fov: number?)
		table.insert(shots, { name = name, eye = v3(eye), target = v3(target), focus = v3(focus), fov = fov or 70 })
	end
	-- Hub (plaza radius 230): overview from the far side + a ground view near the spawn.
	local away = -entrance.Position.Unit * 1
	add("hub_overview", away * 200 + Vector3.new(0, 115, 0), Vector3.new(0, 0, 0), Vector3.new(0, 3, 0))
	-- Ground view from 80 studs at head-over-props height: at 10 studs (2026-10-30 tour) the eye sat
	-- behind a plaza prop and the frame was half filled by it.
	add("hub_ground", away * 80 + Vector3.new(0, 22, 0), Vector3.new(0, 10, 0), Vector3.new(0, 3, 0))
	-- Plot entrance (plot-local: +Z away from the hub).
	add(
		"plot_entrance",
		(entrance * CFrame.new(0, 16, -34)).Position,
		(entrance * CFrame.new(0, 6, 60)).Position,
		(entrance * CFrame.new(0, 3, 8)).Position
	)
	-- Every area: road view (low, left) + high three-quarter (right), slot-local frames.
	for area = 1, WorldLayout.AreaCount do
		local slot = WorldLayout.slotOrigin(index, area)
		local tall = if area == WorldLayout.AreaCount then 1.8 else 1
		add(
			string.format("area%02d_road", area),
			(slot * CFrame.new(-28, 16 * tall, -24)).Position,
			(slot * CFrame.new(0, 8 * tall, 32)).Position,
			(slot * CFrame.new(0, 3, -6)).Position
		)
		add(
			string.format("area%02d_high", area),
			(slot * CFrame.new(42, 50 * tall, -34)).Position,
			(slot * CFrame.new(0, 6 * tall, 32)).Position,
			(slot * CFrame.new(0, 3, -6)).Position
		)
	end
	-- Whole plot from above, then the 8-plot ring.
	add(
		"plot_aerial",
		(entrance * CFrame.new(-240, 260, 120)).Position,
		(entrance * CFrame.new(0, 0, 260)).Position,
		(entrance * CFrame.new(0, 3, 260)).Position
	)
	add(
		"ring_aerial",
		Vector3.new(0, 1150, 0) - entrance.Position.Unit * 620,
		Vector3.new(0, 0, 0),
		Vector3.new(0, 3, 0),
		70
	)
	-- Partial-build views (used after `partial`).
	add(
		"partial_overview",
		(entrance * CFrame.new(-120, 110, 40)).Position,
		(entrance * CFrame.new(0, 0, 150)).Position,
		(entrance * CFrame.new(0, 3, 100)).Position
	)
	add(
		"partial_road",
		(entrance * CFrame.new(-6, 12, 150)).Position,
		(entrance * CFrame.new(0, 6, 100)).Position,
		(entrance * CFrame.new(0, 3, 150)).Position
	)
	return HttpService:JSONEncode(shots)
elseif COMMAND == "focus" then
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return "ERROR no character"
	end
	local at = Vector3.new(ARGS[1], ARGS[2], ARGS[3])
	root.Anchored = true
	root.CFrame = CFrame.new(at)
	pcall(function()
		player:RequestStreamAroundAsync(at, 8)
	end)
	return "focused"
elseif COMMAND == "zfight" then
	-- Live z-fight audit (owner R18): ZFight box pass. The plot is audited in its own plot frame
	-- (its 90° slot yaws stay exact, per B8e); the hub in world space (pieces at 22.5° / 45° steps
	-- are skipped as "rotated" — tests/zfight-audit.luau covers them exactly). Offender centres
	-- and plane normals are returned in WORLD space for the close-up camera.
	local ZFight = (require :: any)(ReplicatedStorage.Shared.World.ZFight)
	local index = PlotService.getPlotIndex(player) :: number
	local result = { count = 0, parts = 0, boxes = 0, skippedRotated = 0, offenders = {} }
	local AXIS = { X = Vector3.xAxis, Y = Vector3.yAxis, Z = Vector3.zAxis }
	for _, pass in
		{
			{ root = plotModel(), frame = WorldLayout.plotOrigin(index), label = "plot" },
			{ root = workspace:FindFirstChild("Hub"), frame = CFrame.identity, label = "hub" },
		}
	do
		if pass.root ~= nil then
			local boxes = {}
			for _, part in (pass.root :: Instance):GetDescendants() do
				if part:IsA("BasePart") and part.Transparency < 1 then
					result.parts += 1
					local box = ZFight.boxFromPart(part, pass.frame)
					if box ~= nil then
						table.insert(boxes, box)
					else
						result.skippedRotated += 1
					end
				end
			end
			result.boxes += #boxes
			local offenders = ZFight.pairs(boxes)
			result.count += #offenders
			for _, o in offenders do
				if #result.offenders >= 120 then
					break
				end
				local c = {}
				for k = 1, 3 do
					c[k] = (math.max(o.a.min[k], o.b.min[k]) + math.min(o.a.max[k], o.b.max[k])) / 2
				end
				local centre = pass.frame:PointToWorldSpace(Vector3.new(c[1], c[2], c[3]))
				local normal = pass.frame:VectorToWorldSpace(AXIS[o.axis] * (if o.sign == "+" then 1 else -1))
				table.insert(result.offenders, {
					pass = pass.label,
					text = ZFight.describe(o),
					centre = v3(centre),
					normal = v3(normal),
				})
			end
		end
	end
	return HttpService:JSONEncode(result)
elseif COMMAND == "restore" then
	local raw = player:GetAttribute("QaPads")
	local pads = if type(raw) == "string" then HttpService:JSONDecode(raw) else {}
	TycoonAdmin.resetPlot(player)
	local granted = TycoonService.grantPads(player, pads, false)
	local cash = player:GetAttribute("QaCash")
	if type(cash) == "number" then
		TycoonAdmin.setCash(player, cash)
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		root.Anchored = false
	end
	return `restored pads={granted} cash={cash}`
end
return `ERROR unknown command {COMMAND}`
