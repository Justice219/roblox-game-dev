--!strict
--[[
	knockdown_check.luau — SERVER half of the knockdown Studio QA (owner R50,
	tools/qa/knockdown_check.py, eval_server_runtime). Placeholders filled with whitelisted values only:
		COMMAND  "setup" | "focus" | "knock" | "check" | "rebuild" | "reset"
		ARGS     numbers: focus = { area }, knock = { area, seconds }, check = { area }

	setup    waits for the tycoon runtime, owns every pad of areas 1..3 (TycoonAdmin.setArea 4, with
	         build-in), switches knockdowns on with the default timers; JSON { ready, builtAreas }
	focus    walks the character to the road in front of the area (streams it in)
	knock    clears the plot's immunity, then Knockdown.adminKnock(area, seconds) (the admin test path)
	check    JSON: area down + until, the producer anchor's PausedAt, cash earned by that producer's
	         area in 1 s (must be 0 while down), immune flag
	rebuild  Knockdown.forceRebuild (admin "Rebuild knocked areas")
	reset    clears immunity (next knock allowed)
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local COMMAND = "__COMMAND__"
local ARGS: { number } = { --[[ARGS]]
}

local Server = game:GetService("ServerScriptService").Server
local Knockdown = (require :: any)(Server.Tycoon.Knockdown)
local TycoonAdmin = (require :: any)(Server.Tycoon.TycoonAdmin)
local TycoonService = (require :: any)(Server.Tycoon.TycoonService)
local PlotService = (require :: any)(Server.Tycoon.PlotService)
local PlotBuilder = (require :: any)(Server.World.PlotBuilder)
local TycoonConfig = (require :: any)(ReplicatedStorage.Shared.Config.TycoonConfig)
local WorldLayout = (require :: any)(ReplicatedStorage.Shared.Config.WorldLayout)

local player = Players:GetPlayers()[1]
if player == nil then
	return "no player"
end

if COMMAND == "setup" then
	local started = os.clock()
	while not TycoonService.isReady(player) and os.clock() - started < 60 do
		task.wait(0.25)
	end
	Knockdown.setEnabled(true)
	Knockdown.setDurationOverride(0)
	Knockdown.setImmunitySeconds(180)
	local ok, message = TycoonAdmin.setArea(player, 4)
	return HttpService:JSONEncode({
		ready = TycoonService.isReady(player),
		ok = ok,
		message = message,
		builtAreas = Knockdown.builtAreas(player),
	})
elseif COMMAND == "focus" then
	local index = PlotService.getPlotIndex(player)
	if index == nil then
		return "no plot"
	end
	local slot = WorldLayout.slotOrigin(index, ARGS[1])
	return tostring(PlotService.teleport(player, slot * CFrame.new(0, 4, -8)))
elseif COMMAND == "knock" then
	Knockdown.clearImmunity(player)
	local ok, reason = Knockdown.adminKnock(player, ARGS[1], ARGS[2])
	return HttpService:JSONEncode({ ok = ok, reason = reason or "" })
elseif COMMAND == "check" then
	local area = ARGS[1]
	local index = PlotService.getPlotIndex(player)
	local producer = TycoonConfig.Areas[area].producer.id
	local anchor = if index ~= nil then PlotBuilder.getProducerAnchor(index, producer) else nil
	local down, untilTime = Knockdown.isDown(player, area)
	local before = TycoonService.areaIncome(player, area)
	return HttpService:JSONEncode({
		down = down,
		remaining = if untilTime ~= nil then untilTime - workspace:GetServerTimeNow() else 0,
		pausedAt = if anchor ~= nil then anchor:GetAttribute("PausedAt") or 0 else -1,
		cycleStart = if anchor ~= nil then anchor:GetAttribute("CycleStart") or 0 else -1,
		areaIncome = before,
		immune = Knockdown.isImmune(player),
		stats = Knockdown.stats(),
	})
elseif COMMAND == "rebuild" then
	return tostring(Knockdown.forceRebuild(player))
elseif COMMAND == "reset" then
	return tostring(Knockdown.clearImmunity(player))
end
return "unknown"
