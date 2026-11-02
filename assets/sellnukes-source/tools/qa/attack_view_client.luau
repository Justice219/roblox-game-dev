--!nocheck
--[[
	attack_view_client.luau — CLIENT half of the owner R104 / R105 / R106 Studio QA
	(tools/qa/attack_view.py, eval_client_runtime, ONE solo playtest).

		COMMAND  "diag"          HUD + profile + PickerView / TowerAnim / DefenseWorld stats
		         "close_all"     closes every modal
		         "picker_open"   opens the target picker; returns picker_state
		         "picker_state"  PickerView.stats(), the LOADING plate, name plate, BaseParts in the
		                         framed target's container, camera position / focus
		         "picker_wait"   ARGS[1] = timeout s: waits until PickerView stops loading; elapsed
		         "hostile_focus" junk AttackPickerFocus arguments (the server must ignore them)
		         "camera_at"     ARGS = { eye x, y, z, look x, y, z } PLOT-LOCAL on my plot: Scriptable
		         "camera_reset"  Custom camera again
		         "boards"        DefenseWorld.boards() + a LIVE screen audit: visible defence boards vs
		                         visible producer boards (ProducerBillboards) — overlapping pairs
		         "anim"          TowerAnim.stats() + the pose of every tower on my plot
		         "anim_delta"    ARGS[1] = seconds: yaw / pitch / dish change of my towers over it
		         "reduced"       ARGS[1] = 1 / 0: OfferFx.setReducedMotion (restored by the runner)
		         "watch_fire"    ARGS[1] = seconds: max engaged towers / live muzzle flashes seen
		         "silo_launch"   owner R109: a REAL normal launch at the first Rival Factory through
		                         AttackClient.launch (the server decides; cooldown applies)
		         "silo_state"    SiloLaunch.stats() + my plot's three silo rockets (hidden? clone
		                         names in Workspace.SN_SiloFx)
		         "silo_watch"    ARGS[1] = seconds: max launching / reloading / clones / boards seen
		         "picker_audit"  owner R118: the open picker's LIVE layout — every visible aim chip's
		                         screen rect (pairwise overlaps, label fits its chip), strip / pinned
		                         mode, the info / status / aim lines (pairwise overlaps), the target
	Presentation only: nothing here touches the economy or any server state but the stream focus.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]]
}

local LOCAL = Players.LocalPlayer
local client = LOCAL:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ClientState = require(client.ClientState)
local ScreenManager = require(client.UI.ScreenManager)
local OfferFx = require(client.UI.Widgets.OfferFx)
local DefenseWorld = require(client.Attack.DefenseWorld)
local PickerView = require(client.Attack.PickerView)
local TowerAnim = require(client.Attack.TowerAnim)
local SiloLaunch = require(client.Attack.SiloLaunch)
local AttackClient = require(client.Attack.AttackClient)
local ProducerBillboards = require(client.Tycoon.ProducerBillboards)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local PickerStream = require(ReplicatedStorage.Shared.Attack.PickerStream)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)

local function v3(v: Vector3?)
	return if v ~= nil then { math.floor(v.X * 10) / 10, math.floor(v.Y * 10) / 10, math.floor(v.Z * 10) / 10 } else nil
end

local function myPlot(): number
	return math.floor(LOCAL:GetAttribute(AttackConfig.Attr.Plot) or 0)
end

local function partsIn(slot: number): number
	if slot < 1 then
		return 0
	end
	local folderName, childName = PickerStream.container(slot)
	local folder = Workspace:FindFirstChild(folderName)
	local container = folder and folder:FindFirstChild(childName)
	if container == nil then
		return 0
	end
	local count = 0
	for _, node in container:GetDescendants() do
		if node:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

local function pickerState()
	local stats = PickerView.stats()
	local gui = ScreenManager.getGui("Attack")
	local plate = gui and gui:FindFirstChild("Loading", true)
	local name = ""
	if gui ~= nil then
		local top = gui:FindFirstChild("Top", true)
		local plateFrame = top and top:FindFirstChild("Plate")
		local label = plateFrame and plateFrame:FindFirstChildWhichIsA("TextLabel", true)
		name = label and label.Text or ""
	end
	local camera = Workspace.CurrentCamera
	return {
		open = ScreenManager.isOpen("Attack"),
		slot = stats.slot,
		loading = stats.loading,
		plateVisible = plate ~= nil and plate.Visible,
		parts = stats.parts,
		partsNow = partsIn(stats.slot),
		reason = stats.reason,
		elapsed = stats.elapsed,
		intents = stats.intents,
		name = name,
		camera = v3(camera.CFrame.Position),
		focus = v3(camera.Focus.Position),
		cameraType = tostring(camera.CameraType),
	}
end

local function rect(x: number, y: number, hx: number, hy: number)
	return { x = x, y = y, hx = hx, hy = hy }
end

local function overlaps(a, b): boolean
	return math.abs(a.x - b.x) < a.hx + b.hx and math.abs(a.y - b.y) < a.hy + b.hy
end

if COMMAND == "diag" then
	local hud = ScreenManager.getGui("Hud")
	return HttpService:JSONEncode({
		hud = hud ~= nil and hud.Enabled,
		profile = type(ClientState.profile) == "table" and type(ClientState.profile.attack) == "table",
		plot = myPlot(),
		picker = PickerView.stats(),
		anim = TowerAnim.stats(),
		boards = DefenseWorld.count(),
	})
elseif COMMAND == "close_all" then
	ScreenManager.closeAllModals()
	return "closed"
elseif COMMAND == "picker_open" then
	ScreenManager.open("Attack", { source = "other" })
	task.wait(0.3)
	return HttpService:JSONEncode(pickerState())
elseif COMMAND == "picker_state" then
	return HttpService:JSONEncode(pickerState())
elseif COMMAND == "picker_wait" then
	local started = os.clock()
	local timeout = ARGS[1] or 10
	while PickerView.loading() and os.clock() - started < timeout do
		task.wait(0.1)
	end
	local state = pickerState()
	state.waited = os.clock() - started
	return HttpService:JSONEncode(state)
elseif COMMAND == "hostile_focus" then
	local event = Remotes.event("AttackPickerFocus")
	for _, junk in { 0 / 0, math.huge, -math.huge, -1, 1.5, 99, 1e300, "1", true, {} } do
		event:FireServer(junk)
	end
	event:FireServer()
	return "sent junk"
elseif COMMAND == "camera_at" then
	local plot = myPlot()
	if plot < 1 then
		return "no plot"
	end
	local origin = WorldLayout.plotOrigin(plot)
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 70
	local eye = origin * Vector3.new(ARGS[1], ARGS[2], ARGS[3])
	local look = origin * Vector3.new(ARGS[4], ARGS[5], ARGS[6])
	camera.CFrame = CFrame.lookAt(eye, look)
	camera.Focus = CFrame.new(look)
	return "ok"
elseif COMMAND == "camera_reset" then
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	return "ok"
elseif COMMAND == "boards" then
	task.wait(0.4) -- one declutter pass after the camera moved
	local camera = Workspace.CurrentCamera
	local viewportY = camera.ViewportSize.Y
	local tanHalf = math.tan(math.rad(camera.FieldOfView) / 2)
	local eye = camera.CFrame.Position
	local producers = {}
	for _, record in ProducerBillboards.ownRecords() do
		local gui = record.gui
		if gui.Enabled and record.visible and (record.point.WorldPosition - eye).Magnitude <= gui.MaxDistance then
			local screen, onScreen = camera:WorldToViewportPoint(record.point.WorldPosition)
			if onScreen and screen.Z > 0.5 then
				local h = record.height / (2 * screen.Z * tanHalf) * viewportY
				table.insert(producers, { id = record.id, r = rect(screen.X, screen.Y, h * TycoonClientConfig.Billboard.Aspect / 2, h / 2) })
			end
		end
	end
	local boards = {}
	local visible = {}
	for _, entry in DefenseWorld.boards() do
		local row = {
			kind = entry.kind,
			tower = entry.tower,
			level = entry.level,
			hidden = entry.hidden,
			position = v3(entry.position),
			size = { entry.size.X.Offset, entry.size.Y.Offset },
			maxDistance = entry.maxDistance,
		}
		if entry.position ~= nil and not entry.hidden and (entry.position - eye).Magnitude <= entry.maxDistance then
			local screen, onScreen = camera:WorldToViewportPoint(entry.position)
			if onScreen and screen.Z > 0.5 then
				row.screen = { math.floor(screen.X), math.floor(screen.Y) }
				table.insert(visible, { label = `{entry.kind}{entry.tower}`, r = rect(screen.X, screen.Y, entry.size.X.Offset / 2, entry.size.Y.Offset / 2) })
			end
		end
		table.insert(boards, row)
	end
	local clips = {}
	for index, board in visible do
		for _, producer in producers do
			if overlaps(board.r, producer.r) then
				table.insert(clips, `{board.label} x {producer.id}`)
			end
		end
		for other = index + 1, #visible do
			if overlaps(board.r, visible[other].r) then
				table.insert(clips, `{board.label} x {visible[other].label}`)
			end
		end
	end
	return HttpService:JSONEncode({ boards = boards, producersOnScreen = #producers, clips = clips })
elseif COMMAND == "anim" then
	local poses = {}
	local plot = myPlot()
	for tower = 0, #AttackConfig.Towers.Slots do
		local pose = TowerAnim.poseOf(plot, tower)
		if pose ~= nil then
			poses[tostring(tower)] = pose
		end
	end
	return HttpService:JSONEncode({ stats = TowerAnim.stats(), poses = poses })
elseif COMMAND == "anim_delta" then
	local plot = myPlot()
	local before = {}
	for tower = 0, #AttackConfig.Towers.Slots do
		before[tower] = TowerAnim.poseOf(plot, tower)
	end
	task.wait(ARGS[1] or 1.5)
	local deltas = {}
	for tower = 0, #AttackConfig.Towers.Slots do
		local a, b = before[tower], TowerAnim.poseOf(plot, tower)
		if a ~= nil and b ~= nil then
			deltas[tostring(tower)] = {
				yaw = math.abs(b.yaw - a.yaw),
				pitch = math.abs(b.pitch - a.pitch),
				dish = math.abs(b.dish - a.dish),
				parts = b.parts,
			}
		end
	end
	return HttpService:JSONEncode({ deltas = deltas, stats = TowerAnim.stats() })
elseif COMMAND == "reduced" then
	OfferFx.setReducedMotion(ARGS[1] == 1)
	return tostring(OfferFx.reducedMotion())
elseif COMMAND == "watch_fire" then
	local started = os.clock()
	local maxEngaged, maxFlashes = 0, 0
	while os.clock() - started < (ARGS[1] or 6) do
		local stats = TowerAnim.stats()
		maxEngaged = math.max(maxEngaged, stats.engaged)
		maxFlashes = math.max(maxFlashes, stats.flashes)
		task.wait(0.03)
	end
	return HttpService:JSONEncode({ maxEngaged = maxEngaged, maxFlashes = maxFlashes })
elseif COMMAND == "picker_audit" then
	local gui = ScreenManager.getGui("Attack")
	if gui == nil then
		return HttpService:JSONEncode({ open = false })
	end
	local function rectOf(node: GuiObject)
		return { x = node.AbsolutePosition.X, y = node.AbsolutePosition.Y, w = node.AbsoluteSize.X, h = node.AbsoluteSize.Y }
	end
	local function hit(a, b): boolean
		return a.x < b.x + b.w - 0.5 and b.x < a.x + a.w - 0.5 and a.y < b.y + b.h - 0.5 and b.y < a.y + a.h - 0.5
	end
	local chips = {}
	local strip = gui:FindFirstChild("AimStrip", true)
	for _, node in gui:GetDescendants() do
		if node:IsA("TextButton") and node.Name == "AimChip" and node.Visible then
			local label = node:FindFirstChildWhichIsA("TextLabel", true)
			table.insert(chips, {
				text = label and label.Text or "",
				fits = label == nil or label.TextFits,
				inStrip = strip ~= nil and node:IsDescendantOf(strip),
				rect = rectOf(node),
			})
		end
	end
	local chipClips = {}
	for i = 1, #chips do
		for j = i + 1, #chips do
			if hit(chips[i].rect, chips[j].rect) then
				table.insert(chipClips, `{chips[i].text} x {chips[j].text}`)
			end
		end
	end
	local lines = {}
	local info = gui:FindFirstChild("Info", true)
	if info ~= nil then
		for _, node in info:GetChildren() do
			if node:IsA("TextLabel") and node.Visible then
				table.insert(lines, { text = node.Text, fits = node.TextFits, rect = rectOf(node) })
			end
		end
	end
	local lineClips = {}
	for i = 1, #lines do
		for j = i + 1, #lines do
			if hit(lines[i].rect, lines[j].rect) then
				table.insert(lineClips, `{lines[i].text} x {lines[j].text}`)
			end
		end
	end
	local smallest = math.huge
	local scale = ScreenManager.pointScale()
	for _, chip in chips do
		smallest = math.min(smallest, chip.rect.h)
	end
	return HttpService:JSONEncode({
		open = ScreenManager.isOpen("Attack"),
		state = pickerState(),
		mode = if strip ~= nil and strip.Visible then "strip-scroll" else "pinned-or-row",
		chips = chips,
		chipClips = chipClips,
		lines = lines,
		lineClips = lineClips,
		smallestChipPx = if smallest < math.huge then smallest else 0,
		pointScale = scale,
	})
elseif COMMAND == "silo_launch" then
	local rival = AttackConfig.Rivals.List[1]
	local ok = AttackClient.launch(rival.id, "normal", 0)
	return HttpService:JSONEncode({ sent = ok, target = rival.id, serverTime = Workspace:GetServerTimeNow() })
elseif COMMAND == "silo_state" then
	local rockets = {}
	local plots = Workspace:FindFirstChild("Plots")
	local plot = plots and plots:FindFirstChild(`Plot{myPlot()}`)
	local builds = plot and plot:FindFirstChild("Area07") and plot.Area07:FindFirstChild("Builds")
	if builds ~= nil then
		for _, build in builds:GetChildren() do
			for _, model in build:GetChildren() do
				if model:IsA("Model") and string.find(model.Name, "A7_SiloNuke", 1, true) ~= nil then
					local part = model:FindFirstChildWhichIsA("BasePart", true)
					table.insert(rockets, { build = build.Name, model = model.Name, ltm = part and part.LocalTransparencyModifier })
				end
			end
		end
	end
	local clones = {}
	local fx = Workspace:FindFirstChild("SN_SiloFx")
	if fx ~= nil then
		for _, child in fx:GetChildren() do
			if child:IsA("Model") then
				table.insert(clones, { name = child.Name, pivot = v3(child:GetPivot().Position) })
			end
		end
	end
	return HttpService:JSONEncode({ stats = SiloLaunch.stats(), rockets = rockets, clones = clones })
elseif COMMAND == "silo_watch" then
	local started = os.clock()
	local best = { launching = 0, reloading = 0, clones = 0, boards = 0 }
	while os.clock() - started < (ARGS[1] or 6) do
		local stats = SiloLaunch.stats()
		best.launching = math.max(best.launching, stats.launching)
		best.reloading = math.max(best.reloading, stats.reloading)
		best.clones = math.max(best.clones, stats.clones)
		local boards = 0
		for _, silo in stats.silos do
			if silo.board then
				boards += 1
			end
		end
		best.boards = math.max(best.boards, boards)
		task.wait(0.05)
	end
	return HttpService:JSONEncode(best)
end
return "unknown command"
