--!nocheck
--[[
	kinetic_server.luau — SERVER half of the Mega Lever + Tip Jar Studio QA (owner R90, K-kinetic),
	run by tools/qa/kinetic.py through eval_server_runtime in ONE solo playtest (Studio lock held by
	the runner's owner). The driver substitutes COMMAND (whitelisted) and ARGS (numbers only).

		COMMAND  "setup"     switches ON; grants every Area 1 pad WITH the build animation so Area 2
		                     (KineticConfig.UnlockArea) opens LIVE → the props build in (reveal);
		                     returns player facts
		         "status"    KineticService.status(player) + props' attributes + MeshSource + cash
		         "to_lever"  stands the character in front of its own lever (prompt range), facing it
		         "to_jar"    stands the character ON its own jar's touch trigger (walk-in payout)
		         "near_jar"  stands the character ARGS[1] studs in front of the jar, facing it
		         "fill_jar"  TipJar.adminFill (the admin seam) → the jar is full
		         "tip"       TipJar.addCoins(player, ARGS[1] seconds of income) (the Order Window seam)
		         "pull"      KineticAction fallback: MegaLever.pull(player) directly (when the client's
		                     prompt hold could not be simulated)
		         "reset"     lever ready again (admin seam) + switches ON
	Everything goes through the real service code (admin seams, the real remote / prompt from the
	client, the real server Touched). Studio DataStores are separate from production.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local Server = ServerScriptService:WaitForChild("Server")
local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)
local KineticService = require(Server.Kinetic.KineticService)
local KineticWorld = require(Server.Kinetic.KineticWorld)
local MegaLever = require(Server.Kinetic.MegaLever)
local PlayerDataService = require(Server.Services.PlayerDataService)
local TipJar = require(Server.Kinetic.TipJar)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local TycoonService = require(Server.Tycoon.TycoonService)
local WorldService = require(Server.Tycoon.WorldService)

local ATTR = KineticConfig.Attr

local player = Players:GetPlayers()[1]
if player == nil then
	return "no player"
end

local function stand(position: Vector3, lookAt: Vector3)
	local character = player.Character
	if character == nil then
		return
	end
	local at = position + Vector3.new(0, 3, 0)
	character:PivotTo(CFrame.lookAt(at, Vector3.new(lookAt.X, at.Y, lookAt.Z)))
end

local function world(): string
	return WorldService.currentWorld(player)
end

local function attrs(model: Model?): { [string]: any }?
	if model == nil then
		return nil
	end
	local out = {}
	for key, value in model:GetAttributes() do
		if type(value) == "number" or type(value) == "boolean" or type(value) == "string" then
			out[key] = value
		end
	end
	return out
end

if COMMAND == "setup" then
	ReplicatedStorage:SetAttribute(ATTR.LeverOn, true)
	ReplicatedStorage:SetAttribute(ATTR.JarOn, true)
	local pads = {}
	for _, pad in TycoonConfig.AreaPads[1] or {} do
		table.insert(pads, pad.id)
	end
	local granted = TycoonService.grantPads(player, pads, true)
	task.wait(0.5)
	KineticService.reconcileNow(player)
	local profile = PlayerDataService.getProfile(player)
	return HttpService:JSONEncode({
		granted = granted,
		world = world(),
		area = profile and profile.tycoon.area or -1,
		cash = profile and profile.cash or -1,
		ready = TycoonService.isReady(player),
	})
elseif COMMAND == "status" then
	local w = world()
	local lever = KineticWorld.lever(player, w)
	local jar = KineticWorld.jar(player, w)
	local profile = PlayerDataService.getProfile(player)
	return HttpService:JSONEncode({
		world = w,
		status = KineticService.status(player),
		lever = attrs(lever),
		jar = attrs(jar),
		leverMesh = lever and lever:GetAttribute("MeshSource") or "",
		jarMesh = jar and jar:GetAttribute("MeshSource") or "",
		cash = profile and profile.cash or -1,
		now = os.time(),
		serverTime = Workspace:GetServerTimeNow(),
		leverStats = MegaLever.stats(),
		jarStats = TipJar.stats(),
	})
elseif COMMAND == "to_lever" then
	local lever = KineticWorld.lever(player, world())
	if lever == nil then
		return "none"
	end
	local front = lever:GetPivot() * Vector3.new(1.6, 0, -7)
	stand(front, lever:GetPivot().Position)
	return "ok"
elseif COMMAND == "to_jar" then
	local jar = KineticWorld.jar(player, world())
	if jar == nil then
		return "none"
	end
	-- Step from just outside onto the trigger so the server sees a real Touched.
	local pivot = jar:GetPivot()
	stand(pivot * Vector3.new(0, 0, -6), pivot.Position)
	task.wait(0.4)
	stand(pivot * Vector3.new(0, 0, -2.6), pivot.Position)
	return "ok"
elseif COMMAND == "near_jar" then
	local jar = KineticWorld.jar(player, world())
	if jar == nil then
		return "none"
	end
	local pivot = jar:GetPivot()
	stand(pivot * Vector3.new(0, 0, -(ARGS[1] or 7)), pivot.Position)
	return "ok"
elseif COMMAND == "fill_jar" then
	local ok, message = TipJar.adminFill(player)
	return HttpService:JSONEncode({ ok = ok, message = message })
elseif COMMAND == "tip" then
	local income = TycoonService.incomePerSecond(player, world())
	local accepted = TipJar.addCoins(player, income * (ARGS[1] or 30))
	return HttpService:JSONEncode({ income = income, accepted = accepted })
elseif COMMAND == "pull" then
	local ok, reason = MegaLever.pull(player)
	return HttpService:JSONEncode({ ok = ok, reason = reason })
elseif COMMAND == "reset" then
	ReplicatedStorage:SetAttribute(ATTR.LeverOn, true)
	ReplicatedStorage:SetAttribute(ATTR.JarOn, true)
	local ok, message = MegaLever.adminReset(player)
	return HttpService:JSONEncode({ ok = ok, message = message })
end
return "unknown"
