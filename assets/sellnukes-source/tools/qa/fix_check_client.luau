--!strict
--[[
	fix_check_client.luau — PLAY-MODE checks for the R17/R25/R26 yaw + motion-group fixes and the
	R19 glow caps (eval_client_runtime; tools/qa/fix_check.py fills COMMAND).
		ready       waits for the join loading screen (LoadingDone) and the "Your plot is #N!"
		            camera swoop (Tycoon/PlotReveal) to finish, so no scripted camera fights ours
		measure     numeric proof: for each animated model, the offsets between pieces of one
		            motion group stay constant over 1.5 s (no cap drifting off a body); NukeMobile
		            wheels stay still; mesh pieces carry MeshYaw and face their model's front.
		cam_arch    camera on the Garage Lab entry arch from the road (sign text must read)
		cam_stand   camera on the Nuke Stand counter (nearby billboards hidden for the shot)
		cam_lamp    camera on a Glow Lamp inside the garage
		lights_old  sets every FX light to the pre-R19 values (for the "before" capture)
		lights_new  restores the capped values
		rotors      owner R41 numeric proof (areas 1-5 built): every A5_CentrifugeRotor model's
		            Rotor piece stays on its own drum axis (horizontal drift from the model pivot)
		            while it turns (yaw swept over 1.5 s), and each rotor pivot sits on one of
		            the Centrifuge Row's drum tops (row-local (-6.5 / 0 / 6.5, 3.7, 0)); the
		            single A5_Centrifuge machines' Rotor pieces are checked the same way
		cam_rotors  camera on the Centrifuge Row (rotors inside their glass domes)
]]
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local COMMAND = "__COMMAND__"
local camera = workspace.CurrentCamera
local player = Players.LocalPlayer

-- Every model in the plots built from `key` (MeshAttribute MeshKey).
local function findModels(key: string): { Model }
	local found: { Model } = {}
	local plots = workspace:FindFirstChild("Plots")
	if plots == nil then
		return found
	end
	for _, item in plots:GetDescendants() do
		if item:IsA("Model") and item:GetAttribute("MeshKey") == key then
			table.insert(found, item)
		end
	end
	return found
end

local function findModel(key: string): Model?
	local plots = workspace:FindFirstChild("Plots")
	if plots == nil then
		return nil
	end
	for _, item in plots:GetDescendants() do
		if item:IsA("Model") and item:GetAttribute("MeshKey") == key then
			return item
		end
	end
	return nil
end

local function hideHud()
	for _, gui in player.PlayerGui:GetChildren() do
		if gui:IsA("ScreenGui") then
			gui.Enabled = false
		end
	end
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
	end)
	local character = player.Character
	if character then
		for _, p in character:GetDescendants() do
			if p:IsA("BasePart") or p:IsA("Decal") then
				p.LocalTransparencyModifier = 1
			end
		end
	end
end

local function look(model: Model?, eyeLocal: Vector3, targetLocal: Vector3): string
	if model == nil then
		return "model missing"
	end
	hideHud()
	local pivot = model:GetPivot()
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 60
	camera.CFrame = CFrame.lookAt((pivot * CFrame.new(eyeLocal)).Position, (pivot * CFrame.new(targetLocal)).Position)
	return "camera on " .. model.Name
end

if COMMAND == "ready" then
	-- Short polls (the MCP request times out near 30 s): the driver repeats until "ready".
	local reveal = (require :: any)(player:WaitForChild("PlayerScripts"):WaitForChild("Client").Tycoon.PlotReveal)
	local t0 = os.clock()
	while os.clock() - t0 < 20 and (player:GetAttribute("LoadingDone") ~= true or reveal.isPlaying()) do
		task.wait(0.25)
	end
	if player:GetAttribute("LoadingDone") ~= true or reveal.isPlaying() then
		return "waiting"
	end
	task.wait(1)
	return "ready"
elseif COMMAND == "measure" then
	local out = {}
	local function spread(model: Model?, a: string, b: string): string
		if model == nil then
			return "missing"
		end
		local pa, pb = model:FindFirstChild(a), model:FindFirstChild(b)
		if pa == nil or pb == nil or not pa:IsA("BasePart") or not pb:IsA("BasePart") then
			return "pieces missing"
		end
		local lo, hi, minA, maxA = math.huge, -math.huge, math.huge, -math.huge
		local t0 = os.clock()
		while os.clock() - t0 < 1.5 do
			local d = (pa :: BasePart).Position.Y - (pb :: BasePart).Position.Y
			lo, hi = math.min(lo, d), math.max(hi, d)
			minA, maxA = math.min(minA, (pa :: BasePart).Position.Y), math.max(maxA, (pa :: BasePart).Position.Y)
			task.wait()
		end
		return string.format("%s-%s offset spread %.4f (motion range %.3f)", a, b, hi - lo, maxA - minA)
	end
	local stand = findModel("A2_StandCounter")
	table.insert(out, "StandCounter " .. spread(stand, "NukeNoses", "NukeRed"))
	local car = findModel("A1_NukeMobile")
	table.insert(out, "NukeMobile " .. spread(car, "NukeBody", "Roof"))
	table.insert(out, "NukeMobile wheels " .. spread(car, "Tyres", "Hubs"))
	local bench = findModel("Workbench")
	if bench then
		local cabinet = bench:FindFirstChild("Cabinet") :: BasePart
		table.insert(
			out,
			string.format(
				"Workbench Cabinet MeshYaw=%s look·pivotLook=%.2f",
				tostring(cabinet:GetAttribute("MeshYaw")),
				cabinet.CFrame.LookVector:Dot(bench:GetPivot().LookVector)
			)
		)
	end
	return table.concat(out, "\n")
elseif COMMAND == "rotors" then
	-- Horizontal distance of a part's centre from a vertical axis through `axis`.
	local function drift(part: BasePart, axis: Vector3): number
		local d = part.Position - axis
		return Vector3.new(d.X, 0, d.Z).Magnitude
	end
	-- Samples a Rotor piece for 1.5 s: max axis drift and total yaw swept (degrees).
	local function sample(rotor: BasePart, axis: Vector3): (number, number)
		local maxDrift, swept = 0, 0
		local last = rotor.CFrame.LookVector
		local t0 = os.clock()
		while os.clock() - t0 < 1.5 do
			maxDrift = math.max(maxDrift, drift(rotor, axis))
			local now = rotor.CFrame.LookVector
			local flatA = Vector3.new(last.X, 0, last.Z)
			local flatB = Vector3.new(now.X, 0, now.Z)
			if flatA.Magnitude > 1e-3 and flatB.Magnitude > 1e-3 then
				swept += math.deg(math.acos(math.clamp(flatA.Unit:Dot(flatB.Unit), -1, 1)))
			end
			last = now
			task.wait()
		end
		return maxDrift, swept
	end
	local out = {}
	local rows = findModels("A5_CentrifugeRow")
	local tops: { Vector3 } = {}
	for _, row in rows do
		for _, x in { -6.5, 0, 6.5 } do
			table.insert(tops, (row:GetPivot() * CFrame.new(x, 3.7, 0)).Position)
		end
	end
	local rotors = findModels("A5_CentrifugeRotor")
	table.insert(out, `rows {#rows}, row rotors {#rotors} (expected {#rows * 3})`)
	for index, model in rotors do
		local rotor = model:FindFirstChild("Rotor")
		if rotor == nil or not rotor:IsA("BasePart") then
			table.insert(out, `rotor {index}: Rotor piece missing`)
			continue
		end
		local pivot = model:GetPivot().Position
		local nearest = math.huge
		for _, top in tops do
			nearest = math.min(nearest, (top - pivot).Magnitude)
		end
		local maxDrift, swept = sample(rotor :: BasePart, pivot)
		local pass = maxDrift < 0.1 and swept > 20 and nearest < 0.05
		table.insert(
			out,
			string.format(
				"rotor %d: drift %.3f studs, swept %.0f deg / 1.5 s, pivot->drum top %.3f -> %s",
				index,
				maxDrift,
				swept,
				nearest,
				if pass then "PASS" else "FAIL"
			)
		)
	end
	for index, model in findModels("A5_Centrifuge") do
		local rotor = model:FindFirstChild("Rotor")
		if rotor ~= nil and rotor:IsA("BasePart") then
			local maxDrift, swept = sample(rotor, model:GetPivot().Position)
			local pass = maxDrift < 0.1 and swept > 20
			table.insert(
				out,
				string.format(
					"single centrifuge %d: drift %.3f, swept %.0f deg -> %s",
					index,
					maxDrift,
					swept,
					if pass then "PASS" else "FAIL"
				)
			)
		end
	end
	return table.concat(out, "\n")
elseif COMMAND == "cam_rotors" then
	return look(findModel("A5_CentrifugeRow"), Vector3.new(5, 11, -15), Vector3.new(0, 4.5, 0))
elseif COMMAND == "cam_arch" then
	return look(findModel("A1_EntryArch"), Vector3.new(0, 9, -22), Vector3.new(0, 8, 0))
elseif COMMAND == "cam_stand" then
	-- The producer billboard hangs right in front of the counter (2026-10-30 capture was fully
	-- blocked): hide billboards within 30 studs for this close-up only; cam_lamp restores them.
	-- (ProducerBillboards parents its guis to PlayerGui, adorned to an Attachment in Terrain.)
	local stand = findModel("A2_StandCounter")
	if stand ~= nil then
		local centre = stand:GetPivot().Position
		for _, root in { workspace, player.PlayerGui } :: { Instance } do
			for _, gui in root:GetDescendants() do
				if gui:IsA("BillboardGui") and gui.Enabled then
					local adornee = gui.Adornee or gui.Parent
					local at = if adornee == nil
						then nil
						elseif adornee:IsA("BasePart") then adornee.Position
						elseif adornee:IsA("Attachment") then adornee.WorldPosition
						else nil
					if at ~= nil and (at - centre).Magnitude < 30 then
						gui:SetAttribute("QaHidden", true)
						gui.Enabled = false
					end
				end
			end
		end
	end
	return look(stand, Vector3.new(4, 7, -12), Vector3.new(0, 3, 0))
elseif COMMAND == "cam_lamp" then
	for _, root in { workspace, player.PlayerGui } :: { Instance } do
		for _, gui in root:GetDescendants() do
			if gui:IsA("BillboardGui") and gui:GetAttribute("QaHidden") then
				gui:SetAttribute("QaHidden", nil)
				gui.Enabled = true
			end
		end
	end
	return look(findModel("GlowLamp"), Vector3.new(-9, 9, -14), Vector3.new(0, 4, 2))
elseif COMMAND == "lights_old" or COMMAND == "lights_new" then
	local old = COMMAND == "lights_old"
	local n = 0
	for _, light in workspace:GetDescendants() do
		if light:IsA("PointLight") and light.Name == "SN_FxLight" then
			if old then
				light:SetAttribute("QaRange", light.Range)
				light.Range, light.Brightness = 16, 1.5
				light.Color = (light.Parent :: BasePart).Color
			else
				light.Range = light:GetAttribute("QaRange") or light.Range
				light.Brightness = 0.6
			end
			n += 1
		end
	end
	return `{COMMAND} on {n} lights`
end
return "ERROR unknown command"
