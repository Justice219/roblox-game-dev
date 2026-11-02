--!nocheck
--[[
	defense_towers_server.luau — SERVER half of the owner R80 defence tower Studio QA
	(tools/qa/defense_towers.py, eval_server_runtime, ONE solo playtest; Studio profile store).
	Placeholders are filled with whitelisted values only:
		COMMAND  "prepare" | "state" | "focus" | "walk" | "cash" | "area" | "grant" | "engage" |
		         "testnuke" | "golden" | "restore"
		ARGS     numbers (see each command)

	prepare   waits for the tycoon runtime, backs up cash + profile.attack (shared.SN_R80_BACKUP),
	          raises the player to area 7 (TycoonAdmin.setArea: targetable, Area 7 pads NOT owned, so no
	          HQ tower), clears the tower slots, cash = 0.6 x slot 2's price (slot 1 affordable,
	          slot 2 not), reconciles; JSON state
	state     JSON: area, Targetable / Towers attributes, stored towers, cash, Attack folder children
	focus     { slot }: character on the road side of slot ARGS[1]'s spot, facing it
	walk      { slot }: character onto slot ARGS[1]'s BUY pad (the real walk-on Touched buy)
	cash      { slot, toLevel, factor }: cash = DefenseTowers.costTo(slot, toLevel) x factor
	area      { n }: TycoonAdmin.setArea(player, n)
	grant     { level }: DefenseService.setAllTowers(player, level) (admin path, build-in)
	engage    { nukes }: nukes from the opposite plot at each built area, through the LIVE
	          DefenseService.engage; JSON: intercepted count, volleys per tower, towers defending
	testnuke  AttackService.testFlight (the admin test nuke: every tower engages for real, drawn)
	golden    { count }: owner R85 — AttackService.giveGolden (stored golden revenge nukes; restore
	          puts the backed-up attack table back, golden included)
	restore   puts the backed-up cash + attack back, reconciles
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]]
}

local Server = game:GetService("ServerScriptService").Server
local AttackService = require(Server.Services.AttackService)
local DefenseService = require(Server.Services.DefenseService)
local PlayerDataService = require(Server.Services.PlayerDataService)
local PlotService = require(Server.Tycoon.PlotService)
local TycoonAdmin = require(Server.Tycoon.TycoonAdmin)
local TycoonService = require(Server.Tycoon.TycoonService)
local Knockdown = require(Server.Tycoon.Knockdown)
local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local AttackRng = require(ReplicatedStorage.Shared.Attack.AttackRng)
local DefenseTowers = require(ReplicatedStorage.Shared.Attack.DefenseTowers)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)

local player = Players:GetPlayers()[1]
if player == nil then
	return HttpService:JSONEncode({ error = "no player" })
end
local profile = PlayerDataService.getProfile(player)
if profile == nil then
	return HttpService:JSONEncode({ error = "no profile" })
end

-- A deep copy of a plain table.
local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in value do
		out[key] = copy(item)
	end
	return out
end

local function state()
	local plot = PlotService.getPlotIndex(player)
	local children = {}
	if plot ~= nil then
		local plots = Workspace:FindFirstChild("Plots")
		local model = plots and plots:FindFirstChild(`Plot{plot}`)
		local folder = model and model:FindFirstChild(AttackConfig.PlotFolder)
		if folder ~= nil then
			for _, child in folder:GetChildren() do
				table.insert(children, `{child.Name}{if child:GetAttribute("Level") then ":" .. tostring(child:GetAttribute("Level")) else ""}`)
			end
		end
	end
	table.sort(children)
	return {
		plot = plot or 0,
		area = profile.tycoon.area,
		targetable = player:GetAttribute(AttackConfig.Attr.Targetable),
		towersAttr = player:GetAttribute(AttackConfig.Attr.Towers),
		aaAttr = player:GetAttribute(AttackConfig.Attr.AALevel),
		stored = copy(profile.attack.towers),
		cash = profile.cash,
		objects = children,
		shopOn = DefenseService.towersEnabled(),
	}
end

local function teleport(cf)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil then
		return false
	end
	character:PivotTo(cf)
	return true
end

if COMMAND == "prepare" then
	local started = os.clock()
	while not TycoonService.isReady(player) and os.clock() - started < 60 do
		task.wait(0.25)
	end
	if shared.SN_R80_BACKUP == nil then
		shared.SN_R80_BACKUP = { cash = profile.cash, attack = copy(profile.attack), area = profile.tycoon.area }
	end
	local areaOk, areaMessage = true, "kept"
	if profile.tycoon.area < AttackConfig.UnlockArea then
		areaOk, areaMessage = TycoonAdmin.setArea(player, AttackConfig.UnlockArea)
	end
	DefenseService.setAllTowers(player, 0)
	profile.cash = DefenseTowers.buyCost(2) * 0.6
	PlayerDataService.markChanged(player, true, { "cash", "attack" })
	Knockdown.clearImmunity(player)
	task.wait(1.2)
	DefenseService.reconcile(player)
	local result = state()
	result.areaOk = areaOk
	result.areaMessage = areaMessage
	result.backupArea = shared.SN_R80_BACKUP.area
	return HttpService:JSONEncode(result)
elseif COMMAND == "state" then
	return HttpService:JSONEncode(state())
elseif COMMAND == "focus" or COMMAND == "walk" then
	local plot = PlotService.getPlotIndex(player)
	if plot == nil then
		return HttpService:JSONEncode({ error = "no plot" })
	end
	local spot = AttackGeometry.towerSlotCFrame(plot, ARGS[1])
	local cf
	if COMMAND == "walk" then
		cf = spot * CFrame.new(0, 3.2, 0)
	else
		-- 9 studs hubward of the spot: inside the tower's Interact reach (Towers.TowerReach 12).
		local stand = (spot * CFrame.new(0, 3.2, -9)).Position
		cf = CFrame.lookAt(stand, spot.Position + Vector3.new(0, 3.2, 0))
	end
	return HttpService:JSONEncode({ ok = teleport(cf), spot = { spot.X, spot.Y, spot.Z } })
elseif COMMAND == "cash" then
	profile.cash = DefenseTowers.costTo(ARGS[1], ARGS[2]) * ARGS[3]
	PlayerDataService.markChanged(player, true, { "cash" })
	return HttpService:JSONEncode(state())
elseif COMMAND == "area" then
	local ok, message = TycoonAdmin.setArea(player, ARGS[1])
	task.wait(1)
	DefenseService.reconcile(player)
	local result = state()
	result.ok = ok
	result.message = message
	return HttpService:JSONEncode(result)
elseif COMMAND == "grant" then
	local ok = DefenseService.setAllTowers(player, ARGS[1])
	local result = state()
	result.ok = ok
	return HttpService:JSONEncode(result)
elseif COMMAND == "engage" then
	local plot = PlotService.getPlotIndex(player)
	local fromPlot = ((plot + WorldLayout.PlotCount // 2 - 1) % WorldLayout.PlotCount) + 1
	local built = Knockdown.builtAreas(player)
	local perTower = {}
	local intercepted, towersSeen, shots = 0, 0, 0
	local t0 = Workspace:GetServerTimeNow() + 30
	for nuke = 1, ARGS[1] do
		local area = built[(nuke - 1) % #built + 1]
		local flight = AttackGeometry.flightOf({ fromPlot = fromPlot, silo = 1, toPlot = plot, impact = 1, area = area, sx = 0, sz = 0 })
		local engagement = DefenseService.engage(player, flight, 0, t0 + nuke * 4, AttackRng.new(7000 + nuke))
		towersSeen = engagement.towers
		shots += engagement.shots
		if engagement.intercepted then
			intercepted += 1
		end
		for _, volley in engagement.volleys do
			local key = tostring(volley.tower)
			perTower[key] = (perTower[key] or 0) + volley.shots
		end
	end
	return HttpService:JSONEncode({
		nukes = ARGS[1],
		intercepted = intercepted,
		shots = shots,
		towers = towersSeen,
		shotsByTower = perTower,
	})
elseif COMMAND == "golden" then
	local total = AttackService.giveGolden(player, ARGS[1])
	local result = state()
	result.golden = total
	return HttpService:JSONEncode(result)
elseif COMMAND == "testnuke" then
	return tostring(AttackService.testFlight(player))
elseif COMMAND == "restore" then
	local backup = shared.SN_R80_BACKUP
	if backup == nil then
		return HttpService:JSONEncode({ restored = false, reason = "no backup" })
	end
	profile.cash = backup.cash
	for key, value in backup.attack do
		profile.attack[key] = copy(value)
	end
	PlayerDataService.markChanged(player, true, { "cash", "attack" })
	shared.SN_R80_BACKUP = nil
	DefenseService.reconcile(player)
	local result = state()
	result.restored = true
	return HttpService:JSONEncode(result)
end
return "unknown command"
