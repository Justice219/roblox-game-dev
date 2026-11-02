--!strict
--[[
	dino_client_check_client.luau — CLIENT half of the Dino Valley tycoon-client check (owner R57,
	W10b; run by tools/qa/dino_client_check.py through the Studio MCP `eval_client_runtime`, in a
	playtest the driver started while holding the Studio lock).

	The driver substitutes placeholders with whitelisted values only: COMMAND (one of the commands
	below), WORLD (a world id re-checked here), ARGS (a Luau table literal of numbers).

	Commands:
		view_at   ARGS[1] = view preset: JSON { at = world target } (the driver streams there first)
		view      ARGS[1] = view preset: Scriptable camera on that preset (our WORLD plot)
		nextpad   JSON { id, at }: the cheapest next pad of our WORLD run + its world position
		buy       fires the real PadBuy intent for the next pad (server re-checks reach / order / cost)
		view_area ARGS[1] = area: camera on that area's producer (layout click box) from the road
		          side — world-generic (no build keys), ARGS[2] = 1 returns only { at, target }
		probe     ARGS[1] = area: samples every WorldFx-tagged piece + every piece of a routed model
		          (VehicleRouteConfig.RoutedModels: couriers, carts) of that area of our WORLD plot
		          twice 0.6 s apart -> JSON per "Model.Piece": moved (studs), turned (deg), light on,
		          belt offsets changing
		gravity   R70: WorldGravity.stats(), then one real jump (the character must be unanchored):
		          JSON { before, after, apex (studs above the take-off), airTime (s), landings }
		stats     JSON: WorldFx / VehicleRoutes / ManagerController / KnockdownFx counters, our WORLD
		          producer billboards (world, family, amount text, icon), pad labels (icon + text),
		          YOU marker, CurrentWorld
		open_rebirth   R70 glue: opens the Rebirth screen on WORLD's tab
		open_welcome   R70 glue: opens Welcome Back with three rows (Nuke Town + Dino + WORLD;
		               display only — the server's claim never runs from this)
		reset     default follow camera
]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local COMMAND = "__COMMAND__"
local WORLD = "__WORLD__"
local ARGS: { number } = { --[[ARGS]]
}

local player = Players.LocalPlayer
local client = player:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Tycoon = client:WaitForChild("Tycoon")
local Remotes = (require :: any)(ReplicatedStorage.Shared.Net.Remotes)
local WorldLayout = (require :: any)(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldsConfig = (require :: any)(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
local WorldLookup = (require :: any)(Tycoon.WorldLookup)
local TycoonWorld = (require :: any)(Tycoon.TycoonWorld)
local WorldFxController = (require :: any)(Tycoon.Fx.WorldFxController)
local VehicleRoutes = (require :: any)(Tycoon.Fx.VehicleRoutes)
local ManagerController = (require :: any)(Tycoon.Npc.ManagerController)
local KnockdownFx = (require :: any)(Tycoon.BuildIn.KnockdownFx)
local VehicleRouteConfig = (require :: any)(ReplicatedStorage.Shared.Config.VehicleRouteConfig)
local WorldGravity = (require :: any)(client:WaitForChild("Worlds"):WaitForChild("WorldGravity"))
local FxQuality = (require :: any)(Tycoon.Fx.FxQuality)
local camera = workspace.CurrentCamera

if WorldsConfig.get(WORLD) == nil then
	return `ERROR unknown world {WORLD}`
end

--[[
	View presets (slot-local, our WORLD plot): `key` = a build key whose first layout model is the
	target (else `at`), `eye` = camera offset from the target in slot axes (-Z = toward the road),
	`look` = extra offset of the look point, `fov`.
]]
type View = { area: number, key: string?, at: Vector3?, eye: Vector3, look: Vector3?, fov: number? }
local VIEWS: { View } = {
	{ area = 1, key = "D1_StoneBench", eye = Vector3.new(14, 9, -24), look = Vector3.new(0, 3, 4) },
	{ area = 1, key = "D1_TorchWall", eye = Vector3.new(6, 4, -12), look = Vector3.new(0, 3, 0), fov = 55 },
	{ area = 2, key = "D2_MammothFan", eye = Vector3.new(-7, 6, -15), look = Vector3.new(0, 4, 0), fov = 55 },
	{ area = 3, key = "D3_NestTower", eye = Vector3.new(2, 9, -28), look = Vector3.new(2, 14, -6) },
	{ area = 3, key = "D3_WindSock", eye = Vector3.new(-12, 4, -16), look = Vector3.new(0, 8, 0), fov = 55 },
	{ area = 4, key = "D4_GeyserVent", eye = Vector3.new(-14, 10, -34), look = Vector3.new(4, 9, 8) },
	{ area = 4, key = "D4_WaterWheel", eye = Vector3.new(-16, 7, -14), look = Vector3.new(0, 6, 0), fov = 60 },
	{ area = 5, key = "D5_Incubators", eye = Vector3.new(4, 5, -10), look = Vector3.new(0, 2, 0), fov = 55 },
	{ area = 6, key = "D6_VolcanoCore", eye = Vector3.new(-24, 16, -40), look = Vector3.new(0, 14, -6) },
	{ area = 6, key = "D6_LavaFalls", eye = Vector3.new(2, 8, -20), look = Vector3.new(0, 8, 4), fov = 60 },
	{ area = 6, key = "D6_LavaChannel", eye = Vector3.new(10, 9, -14), look = Vector3.new(0, 1, 4), fov = 60 },
	{ area = 6, at = Vector3.new(0, 3, 14), eye = Vector3.new(5, 4, -26), look = Vector3.new(0, 1, 2), fov = 60 },
	{ area = 2, at = Vector3.new(0, 5, 38), eye = Vector3.new(2, 3, -22), look = Vector3.new(0, 1, 0), fov = 65 },
	{ area = 3, key = "D3_CaptainPtera", eye = Vector3.new(-5, 4, -11), look = Vector3.new(0, 3, 0), fov = 55 },
	{ area = 5, at = Vector3.new(0, 5, 38), eye = Vector3.new(2, 3, -22), look = Vector3.new(0, 1, 0), fov = 65 },
}

local function plotIndex(): number
	local value = player:GetAttribute("PlotIndex")
	return if type(value) == "number" then value else 0
end

-- The slot frame + slot-local target of a preset (layout first model of `key`, else `at`).
local function presetFrames(index: number): (CFrame?, Vector3?)
	local view = VIEWS[math.clamp(math.floor(index), 1, #VIEWS)]
	local plot = plotIndex()
	if plot < 1 then
		return nil, nil
	end
	local slot: CFrame = WorldLayout.slotOrigin(plot, view.area, WORLD)
	local at = view.at
	if view.key ~= nil then
		local layout = WorldLookup.layout(WORLD, view.area)
		local group = if layout ~= nil and type(layout.builds) == "table" then layout.builds[view.key] else nil
		local first = if type(group) == "table" and type(group.models) == "table" then group.models[1] else nil
		if type(first) == "table" and typeof(first.cf) == "CFrame" then
			at = (first.cf :: CFrame).Position
		end
	end
	return slot, at
end

-- Our WORLD plot's area model AreaNN, or nil.
local function areaModel(area: number): Instance?
	local plot = TycoonWorld.myPlot(WORLD)
	return if plot ~= nil then plot:FindFirstChild(string.format("Area%02d", area)) else nil
end

local function vec(v: Vector3): { number }
	return { math.floor(v.X * 100) / 100, math.floor(v.Y * 100) / 100, math.floor(v.Z * 100) / 100 }
end

if COMMAND == "view_at" or COMMAND == "view" then
	local slot, at = presetFrames(ARGS[1] or 1)
	if slot == nil or at == nil then
		return "ERROR no plot / preset target"
	end
	local view = VIEWS[math.clamp(math.floor(ARGS[1] or 1), 1, #VIEWS)]
	local target = slot * (at + (view.look or Vector3.zero))
	local eye = slot * (at + view.eye)
	if COMMAND == "view_at" then
		-- The driver stands the character on the ground under the camera (out of frame) and
		-- streams around it; the target is within the streaming radius of that spot.
		local ground = slot * Vector3.new((at + view.eye).X, 0.5, (at + view.eye).Z)
		return HttpService:JSONEncode({ at = vec(ground), target = vec(slot * at) })
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = view.fov or 70
	camera.CFrame = CFrame.lookAt(eye, target)
	return HttpService:JSONEncode({ eye = vec(eye), target = vec(target) })
elseif COMMAND == "nextpad" or COMMAND == "buy" then
	local state = WorldLookup.tycoon(WORLD)
	if state == nil then
		return "ERROR no world state"
	end
	local nextPads = WorldLookup.logic(WORLD).nextPads(state)
	local pad = nextPads[1]
	if pad == nil then
		return HttpService:JSONEncode({ id = "" })
	end
	if COMMAND == "buy" then
		Remotes.event("PadBuy"):FireServer(pad.id)
		return HttpService:JSONEncode({ id = pad.id, bought = true })
	end
	local trigger = TycoonWorld.myPad(pad.id)
	local at = if trigger ~= nil then trigger.Position else nil
	if at == nil then
		-- Not streamed yet: the pad's area slot centre on the pad strip (the driver streams there).
		local slot: CFrame = WorldLayout.slotOrigin(plotIndex(), pad.area or 1, WORLD)
		at = (slot * CFrame.new(0, 0, 9)).Position
	end
	return HttpService:JSONEncode({ id = pad.id, at = vec(at :: Vector3), streamed = trigger ~= nil })
elseif COMMAND == "probe" then
	local area = areaModel(math.floor(ARGS[1] or 1))
	if area == nil then
		return "ERROR area not streamed"
	end
	-- Every WorldFx-tagged piece + every routed courier piece (VehicleRoutes moves those).
	local parts: { BasePart } = {}
	for _, instance in CollectionService:GetTagged("WorldFx") do
		if instance:IsA("BasePart") and instance:IsDescendantOf(area) then
			table.insert(parts, instance)
		end
	end
	for _, model in area:GetDescendants() do
		local key = if model:IsA("Model") then model:GetAttribute("MeshKey") else nil
		if type(key) == "string" and VehicleRouteConfig.RoutedModels[key] then
			for _, part in model:GetChildren() do
				if part:IsA("BasePart") then
					table.insert(parts, part)
				end
			end
		end
	end
	local before: { CFrame } = {}
	local offsets: { { number } } = {}
	for i, part in parts do
		before[i] = part.CFrame
		local list = {}
		for _, child in part:GetChildren() do
			if child:IsA("Texture") and child.Name == "SN_FxBelt" then
				table.insert(list, child.OffsetStudsV)
			end
		end
		offsets[i] = list
	end
	task.wait(0.6)
	local out: { [string]: any } = {}
	for i, part in parts do
		local model = part.Parent
		local key = `{if model ~= nil then model:GetAttribute("MeshKey") or model.Name else "?"}.{part.Name}`
		local delta = before[i]:Inverse() * part.CFrame
		local _, angle = delta:ToAxisAngle()
		local light = part:FindFirstChild("SN_FxLight")
		local belts = 0
		local beltMoving = false
		for _, child in part:GetChildren() do
			if child:IsA("Texture") and child.Name == "SN_FxBelt" then
				belts += 1
				local was = offsets[i][belts]
				if was ~= nil and math.abs(child.OffsetStudsV - was) > 1e-3 then
					beltMoving = true
				end
			end
		end
		local row = out[key] or { n = 0, moved = 0, turned = 0, lightOn = false, belts = 0, beltMoving = false }
		row.n += 1
		row.moved = math.max(row.moved, math.floor(delta.Position.Magnitude * 1000) / 1000)
		row.turned = math.max(row.turned, math.floor(math.deg(angle) * 10) / 10)
		row.lightOn = row.lightOn or (light ~= nil and light:IsA("PointLight") and light.Enabled)
		row.belts = math.max(row.belts, belts)
		row.beltMoving = row.beltMoving or beltMoving
		out[key] = row
	end
	return HttpService:JSONEncode({ pieces = #parts, rows = out })
elseif COMMAND == "stats" then
	-- Currency icons inside one billboard (amount + upgrade cost on icon worlds).
	local function iconCount(root: Instance): number
		local n = 0
		for _, descendant in root:GetDescendants() do
			if descendant.Name == "CurrencyIcon" then
				n += 1
			end
		end
		return n
	end
	local billboards = {}
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if gui ~= nil then
		for _, child in gui:GetChildren() do
			-- This world's producers / pads: ids carry the world's prefix (dp1_ / d1_, mp1_ / m1_).
			local prefix = WorldsConfig.get(WORLD).idPrefix or ""
			if child:IsA("BillboardGui") and string.match(child.Name, `^ProducerBillboard_{prefix}p%d`) then
				local amount = child:FindFirstChild("Amount")
				local cost = child:FindFirstChild("Cost", true)
				table.insert(billboards, {
					name = child.Name,
					amount = if amount ~= nil and amount:IsA("TextLabel") then amount.Text else "?",
					cost = if cost ~= nil and cost:IsA("TextLabel") then cost.Text else "",
					icons = iconCount(child),
				})
			elseif child:IsA("BillboardGui") and string.match(child.Name, `^PadBillboard_{prefix}%d`) then
				local text = child:FindFirstChild("Amount", true)
				local icon = child:FindFirstChild("CurrencyIcon", true)
				table.insert(billboards, {
					name = child.Name,
					amount = if text ~= nil and text:IsA("TextLabel") then text.Text else "?",
					icons = if icon ~= nil then 1 else 0,
					width = if text ~= nil and text:IsA("TextLabel") then text.Size.X.Scale else -1,
				})
			end
		end
	end
	local marker = if gui ~= nil then gui:FindFirstChild("YouMarker") else nil
	local myPlot = TycoonWorld.myPlot(WORLD)
	return HttpService:JSONEncode({
		currentWorld = player:GetAttribute("CurrentWorld"),
		areas = WorldLayout.areaCount(WORLD),
		tier = FxQuality.tier(),
		worldFx = WorldFxController.stats(),
		routes = VehicleRoutes.stats(),
		clocks = VehicleRoutes.clocks(),
		managers = ManagerController.stats(),
		knockdown = KnockdownFx.stats(),
		gravity = WorldGravity.stats(),
		plot = if myPlot ~= nil then myPlot:GetFullName() else "",
		youMarker = marker ~= nil and marker:IsA("BillboardGui") and marker.Enabled,
		billboards = billboards,
	})
elseif COMMAND == "view_area" then
	local plot = plotIndex()
	local area = math.floor(ARGS[1] or 1)
	local layout = WorldLookup.layout(WORLD, area)
	local click = if layout ~= nil and type(layout.producer) == "table" then layout.producer.click else nil
	if plot < 1 or click == nil then
		return "ERROR no plot / layout producer"
	end
	local slot: CFrame = WorldLayout.slotOrigin(plot, area, WORLD)
	local at: Vector3 = (click.cf :: CFrame).Position
	-- Straight down the area's path from the road side (open air: the arch opening, the walkway).
	local eye = slot * (at + Vector3.new(3, 9, -27))
	local target = slot * (at + Vector3.new(0, 4, 0))
	if (ARGS[2] or 0) == 1 then
		local ground = slot * Vector3.new(at.X + 3, 0.5, at.Z - 27)
		return HttpService:JSONEncode({ at = vec(ground), target = vec(target) })
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 65
	camera.CFrame = CFrame.lookAt(eye, target)
	return HttpService:JSONEncode({ eye = vec(eye), target = vec(target) })
elseif COMMAND == "gravity" then
	-- Starts one real jump in its own thread (returns at once, so the driver can capture the
	-- touchdown dust puff); `gravity_result` reads the measurement afterwards.
	local before = WorldGravity.stats()
	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if humanoid == nil or root == nil or not root:IsA("BasePart") or root.Anchored then
		return "ERROR no free character (unanchor first)"
	end
	local shared: any = _G
	shared.__W10bGravity = { pending = true }
	task.spawn(function()
		local y0 = root.Position.Y
		local peak = y0
		local t0 = os.clock()
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		local airTime = -1
		local hold: CFrame? = shared.__W10bCam
		while os.clock() - t0 < 4 do
			task.wait()
			if hold ~= nil then
				camera.CameraType = Enum.CameraType.Scriptable
				camera.CFrame = hold
			end
			peak = math.max(peak, root.Position.Y)
			if os.clock() - t0 > 0.25 and humanoid.FloorMaterial ~= Enum.Material.Air then
				airTime = os.clock() - t0
				break
			end
		end
		-- Freeze the touchdown dust where it is (TimeScale 0) so the driver's screenshot shows it
		-- whatever the MCP latency; `gravity_result` lets it play out again.
		task.wait(0.12)
		local dust = workspace.Terrain:FindFirstChild("SN_MoonDustPoint")
		local emitter = if dust ~= nil then dust:FindFirstChild("SN_MoonDust") else nil
		if emitter ~= nil and emitter:IsA("ParticleEmitter") then
			emitter.TimeScale = 0
		end
		task.wait(0.2)
		local after = WorldGravity.stats()
		shared.__W10bGravity = {
			pending = false,
			before = before,
			after = after,
			apex = math.floor((peak - y0) * 100) / 100,
			airTime = math.floor(airTime * 100) / 100,
			landings = after.landings - before.landings,
		}
	end)
	return "jumping"
elseif COMMAND == "view_char" then
	-- Camera on our own character (the jump + touchdown puff): ~12 studs away, a little above.
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return "ERROR no character"
	end
	local feet = root.Position - Vector3.new(0, 2.5, 0)
	-- Wide and to the side, framing the ground AND the ~22-stud apex (the jump + the dust ring).
	-- Stored for the gravity thread, which re-applies it every frame (other camera code — e.g. the
	-- juice camera punch — may hand the camera back to Custom mid-jump).
	-- In front of the character (along its facing: the open path it walks), so arch posts / props
	-- beside the plot entrance never block the view.
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local shot = CFrame.lookAt(feet + flat * 24 + Vector3.new(0, 7, 0), feet + Vector3.new(0, 10, 0))
	local shared: any = _G
	shared.__W10bCam = shot
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 62
	camera.CFrame = shot
	return "framed"
elseif COMMAND == "dust_test" then
	-- Diagnostic: the game's own dust emitter, moved 12 studs in front of the camera, 20 particles,
	-- frozen (TimeScale 0) — proves the emitter renders at all; gravity_result un-freezes it.
	local dust = workspace.Terrain:FindFirstChild("SN_MoonDustPoint")
	local emitter = if dust ~= nil then dust:FindFirstChild("SN_MoonDust") else nil
	if dust == nil or emitter == nil or not dust:IsA("Attachment") or not emitter:IsA("ParticleEmitter") then
		return "ERROR no dust emitter yet (land once first)"
	end
	dust.WorldPosition = (camera.CFrame * CFrame.new(0, -2, -12)).Position
	emitter.TimeScale = 1
	emitter:Emit(20)
	task.wait(0.15)
	emitter.TimeScale = 0
	return HttpService:JSONEncode({
		at = vec(dust.WorldPosition),
		texture = emitter.Texture,
		enabled = emitter.Enabled,
		transparency = emitter.Transparency.Keypoints[1].Value,
		size = emitter.Size.Keypoints[1].Value,
		lifetime = { emitter.Lifetime.Min, emitter.Lifetime.Max },
		lightInfluence = emitter.LightInfluence,
		brightness = emitter.Brightness,
	})
elseif COMMAND == "rebirth_links" then
	-- Scrolls the open Rebirth pane so its cross-world link well (WorldLinks) is in view.
	local gui = player:FindFirstChildOfClass("PlayerGui")
	local links: GuiObject? = nil
	if gui ~= nil then
		for _, item in gui:GetDescendants() do
			if item.Name == "WorldLinks" and item:IsA("GuiObject") and item.Visible and item.AbsoluteSize.Y > 0 then
				links = item
				break
			end
		end
	end
	if links == nil then
		return "ERROR no visible WorldLinks"
	end
	local scroller = links:FindFirstAncestorWhichIsA("ScrollingFrame")
	local rows = 0
	for _, row in links:GetChildren() do
		if row:IsA("Frame") and row.Visible then
			rows += 1
		end
	end
	if scroller ~= nil then
		local offset = links.AbsolutePosition.Y - scroller.AbsolutePosition.Y + scroller.CanvasPosition.Y
		scroller.CanvasPosition = Vector2.new(0, math.max(0, offset - 120))
	end
	return HttpService:JSONEncode({ rows = rows, scrolled = scroller ~= nil })
elseif COMMAND == "gravity_result" then
	local shared: any = _G
	local dust = workspace.Terrain:FindFirstChild("SN_MoonDustPoint")
	local emitter = if dust ~= nil then dust:FindFirstChild("SN_MoonDust") else nil
	if emitter ~= nil and emitter:IsA("ParticleEmitter") then
		emitter.TimeScale = 1 -- un-freeze the QA capture (the game never freezes it)
	end
	return HttpService:JSONEncode(shared.__W10bGravity or { missing = true })
elseif COMMAND == "open_rebirth" or COMMAND == "open_welcome" then
	local ScreenManager = (require :: any)(client.UI.ScreenManager)
	local ok, err
	if COMMAND == "open_rebirth" then
		ok, err = pcall(ScreenManager.open, "Rebirth", { world = WORLD, source = "other" })
	else
		local rows = {}
		for _, def in WorldsConfig.extra() do
			table.insert(rows, { id = def.id, amount = if def.id == WORLD then 2.5e5 else 4.5e6 })
		end
		ok, err = pcall(ScreenManager.open, "WelcomeBack", { amount = 1.2e12, seconds = 28800, worlds = rows })
	end
	return if ok then `opened {COMMAND}` else `ERROR {err}`
elseif COMMAND == "reset" then
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	return "reset"
end
return `ERROR unknown command {COMMAND}`
