--!strict
--[[
	WorldHandlers — built-in handlers of the admin panel's WORLD tab (spec §14): rebuild a plot
	instantly, or replay every build-in animation (owner rule 4: every purchase builds in — this
	is the preview tool). Both forward to B5's TycoonAdmin.rebuildPlot(player, animate).
	"Vehicles on/off" (owner R56, rule 9) sets the ReplicatedStorage attribute
	VehicleRouteConfig.EnabledAttribute; every client's Tycoon/Fx/VehicleRoutes parks or resumes its
	map vehicles live (this server only, never saved; AdminService audits the change).

	(The "debug overlays" toggle of the World tab is client-local in the admin panel: it only
	changes what the admin's own screen draws, so there is nothing for the server to authorise.)

	Connects to: Server/Admin/HandlerKit, Server/Admin/Seams (TycoonAdmin),
	Shared/Config/VehicleRouteConfig (EnabledAttribute).

	Example:
		WorldHandlers.install(registry, env)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HandlerKit = require(script.Parent.HandlerKit)
local VehicleRouteConfig = require(ReplicatedStorage.Shared.Config.VehicleRouteConfig)
local Seams = require(script.Parent.Parent.Seams)

type Context = HandlerKit.Context

local WorldHandlers = {}

local Kit = HandlerKit

-- A rebuild handler (animate = replay every build-in).
local function rebuild(animate: boolean): HandlerKit.Handler
	return function(ctx: Context): (boolean, string)
		local player = Kit.targetPlayer(ctx)
		if Kit.loadedProfile(player) == nil then
			return false, `{Kit.label(player)}'s profile is not loaded`
		end
		local fallback = if animate
			then `Replaying the build-in of {Kit.label(player)}'s plot`
			else `Rebuilt {Kit.label(player)}'s plot`
		return Kit.seamResult(Seams.tycoonAdmin(), "rebuildPlot", Kit.TYCOON, fallback, player, animate)
	end
end

--[[
	VehiclesToggle { on }: map vehicles + machines on / off for this server. AdminService has
	already validated `on` against the AdminConfig schema (boolean).
	Example: vehicles({ args = { on = false }, ... }) --> true, "Map vehicles are OFF ..."
]]
local function vehicles(ctx: Context): (boolean, string)
	local on = ctx.args.on == true
	ReplicatedStorage:SetAttribute(VehicleRouteConfig.EnabledAttribute, on)
	return true, if on then "Map vehicles are ON" else "Map vehicles are OFF on this server (parked on their spots)"
end

--[[ Installs every World-tab handler into the registry. ]]
function WorldHandlers.install(registry: HandlerKit.Registry, _env: HandlerKit.Env)
	registry.setBuiltin("RebuildPlot", rebuild(false), Kit.tycoonProbe("rebuildPlot"))
	registry.setBuiltin("ReplayBuildIn", rebuild(true), Kit.tycoonProbe("rebuildPlot"))
	registry.setBuiltin("VehiclesToggle", vehicles)
end

return table.freeze(WorldHandlers)
