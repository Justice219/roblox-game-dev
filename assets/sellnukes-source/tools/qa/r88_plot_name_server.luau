--!nocheck
--[[
	r88_plot_name_server.luau — server-VM probe for the owner R88 plot names (N-plotname), run by
	tools/qa/r88_plot_name.py through eval_server_runtime during ONE solo playtest.

	Placeholders filled by the runner with whitelisted values only (world_tour.render):
		COMMAND  "signs" | "admin" | "profile"
		ARGS     numbers (unused)

		"signs"    the first player's plot in EVERY world: the owner-sign label texts, the plot's
		           PlotName attribute and whether the sign part carries the SNPlotSign tag
		"admin"    PlotNames.adminReset(player) — the moderation path (ResetPlotName)
		"profile"  profile.plotName + whether profile.tycoon holds no plot name (outside the run)
]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }
local _ = ARGS

local Server = ServerScriptService.Server
local PlotBuilder = require(Server.World.PlotBuilder)
local PlotNames = require(Server.Tycoon.PlotNames)
local PlotService = require(Server.Tycoon.PlotService)
local PlayerDataService = require(Server.Services.PlayerDataService)
local PlotNameConfig = require(ReplicatedStorage.Shared.Config.PlotNameConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local player = Players:GetPlayers()[1]
if player == nil then
	return "no player"
end

local result: any
if COMMAND == "signs" then
	local index = PlotService.getPlotIndex(player)
	local worlds = { WorldsConfig.MAIN }
	for _, def in WorldsConfig.extra() do
		table.insert(worlds, def.id)
	end
	result = { index = index }
	for _, worldId in worlds do
		local ok, entry = pcall(function()
			local builder = PlotBuilder.world(worldId)
			if not builder.hasPlots() or index == nil then
				return { built = false }
			end
			local plot = builder.getPlot(index)
			local texts, tagged = {}, 0
			for _, item in plot:GetDescendants() do
				if item:IsA("BasePart") and CollectionService:HasTag(item, PlotNameConfig.SignTag) then
					tagged += 1
					for _, label in item:GetDescendants() do
						if label:IsA("TextLabel") then
							table.insert(texts, label.Text)
						end
					end
				end
			end
			return { plotName = plot:GetAttribute("PlotName"), tagged = tagged, labels = texts }
		end)
		result[worldId] = if ok then entry else tostring(entry)
	end
elseif COMMAND == "admin" then
	local ok, message = PlotNames.adminReset(player)
	result = { ok = ok, message = message }
elseif COMMAND == "profile" then
	local profile = PlayerDataService.getProfile(player)
	result = {
		plotName = if profile ~= nil then profile.plotName else nil,
		tycoonHasPlotName = if profile ~= nil then profile.tycoon.plotName ~= nil else nil,
	}
else
	result = { error = "unknown command" }
end

return HttpService:JSONEncode(result)
