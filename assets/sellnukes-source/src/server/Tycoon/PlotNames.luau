--!strict
--[[
	PlotNames — the owner-chosen PLOT NAME on a plot's entrance sign (owner R88: "allow players to
	name there plots by clicking on it and on controller being near the sign in the front").

	Purpose:
		Every player can name their plot from the start (no unlock). The name replaces the default
		"<DisplayName>'s Nukes" on the entrance sign of the player's plot in EVERY world ("<Name>'s
		Dino Valley" etc. become the same custom name), is saved in profile.plotName (top-level, so
		a Rebirth — which replaces profile.tycoon — keeps it) and reaches the owner's client in the
		`plotName` snapshot field (the naming window pre-fills it).

	Remote
		RenamePlot(text)  C→S. PlotNameLogic.parse: a string ≤ MaxChars*4 bytes; all-space / "" =
		                  RESET TO DEFAULT, else Validate.text (UTF-8, no control characters,
		                  1..MaxChars characters) + normalize (invisible characters dropped, spaces
		                  collapsed). Junk is dropped silently (no toast amplification). Then:
		                  one request in flight per player, a token-bucket rate limit
		                  (PlotNameConfig.Rename; a refused request answers with at most one "slow
		                  down" toast per ToastSeconds), the player must own a plot. A new name goes
		                  through TextService (broadcast context) BEFORE it is saved or shown; the
		                  unfiltered text is never stored. A name the filter censors (any change) is
		                  REFUSED with a friendly toast instead of putting "####" on a kid's sign.
		                  After the filter yield the player, plot and profile are re-checked.

	Display (apply)
		After every plot (re)assignment (PlotService.claim) the saved name is shown again: re-parsed
		and RE-FILTERED once per session (security audit 2026-10-30: stored text is filtered on
		display, never trusted from an old session) — the default sign shows while the check runs;
		a failed filter or a name the filter now censors keeps the default (fail closed). A token
		per player discards a slow filter answer that a newer rename / reset / plot change replaced.
		Rebuilds never touch the sign (PlotBuilder.restore leaves it), so nothing else re-applies.

	Admin (hard rule 9; PlotNameAdmin): ResetPlotName clears a player's name for moderation.

	Analytics (tycoon family): renamePlot:set | renamePlot:reset | renamePlot:admin.

	Connects to: Tycoon/PlotService (start + apply + forget; passes getPlotIndex and its broadcast
	filter), World/PlotBuilder (setPlotName on every world's builder), Services/PlayerDataService
	(profile, markChanged "plotName", notify), Tycoon/TycoonAnalytics, Tycoon/PlotNameAdmin,
	Shared/Tycoon/PlotNameLogic, Shared/Config/PlotNameConfig, Shared/Net/Remotes ("RenamePlot").

	Usage (PlotService only):
		PlotNames.start({ getPlotIndex = PlotService.getPlotIndex, filter = filterForBroadcast })
		PlotNames.apply(player)      -- after the plot is claimed
		PlotNames.forget(player)     -- PlayerRemoving
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService)
local ProfileLogic = require(script.Parent.Parent.Economy.ProfileLogic)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)
local PlotNameAdmin = require(script.Parent.PlotNameAdmin)
local PlotNameConfig = require(ReplicatedStorage.Shared.Config.PlotNameConfig)
local PlotNameLogic = require(ReplicatedStorage.Shared.Tycoon.PlotNameLogic)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TycoonAnalytics = require(script.Parent.TycoonAnalytics)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local PlotNames = {}

type Profile = ProfileLogic.Profile

-- What PlotService passes in (PlotNames never requires PlotService: PlotService requires it).
export type Deps = {
	getPlotIndex: (player: Player) -> number?,
	-- Filters `text` from `player` for everyone to see (yields); nil when the filter failed.
	filter: (player: Player, text: string) -> string?,
}

local Copy = PlotNameConfig.Copy
local MAX_CHARS = PlotNameConfig.MaxChars

local deps: Deps? = nil
local started = false
local limiter = RateLimiter.new(PlotNameConfig.Rename.Burst, PlotNameConfig.Rename.RefillPerSecond)
-- At most one "slow down" toast per ToastSeconds per player (refusals never spam the client).
local toastLimiter = RateLimiter.new(1, 1 / PlotNameConfig.Rename.ToastSeconds)
-- A rename whose filter call is still running (one in flight per player).
local busy: { [Player]: boolean } = {}
-- Names re-filtered for display this session: player → { source = saved, shown = on the sign }.
local displayed: { [Player]: { source: string, shown: string } } = {}
-- Bumped by every apply / rename / reset so a slow filter answer never overwrites a newer state.
local tokens: { [Player]: number } = {}

-- Starts a new display generation for `player` (cancels any filter answer still in flight).
local function bump(player: Player): number
	local token = (tokens[player] or 0) + 1
	tokens[player] = token
	return token
end

--[[
	Writes plot `index`'s sign in EVERY world: Nuke Town, then each extra world whose plots exist
	(guarded: a broken world's builder can never break Nuke Town's sign).
	@param text string — filtered custom name, "" = the default "<DisplayName>'s <suffix>"
]]
local function showEverywhere(index: number, text: string)
	PlotBuilder.setPlotName(index, text)
	for _, def in WorldsConfig.extra() do
		local ok, problem = pcall(function()
			local builder = PlotBuilder.world(def.id)
			if builder.hasPlots() then
				builder.setPlotName(index, text)
			end
		end)
		if not ok then
			warn(`[PlotNames] {def.id} sign update failed: {problem}`)
		end
	end
end

--[[
	Shows a player's SAVED plot name on their plot in every world (after a claim / profile swap).
	Re-filters once per session (cached by saved text); the default shows meanwhile. Never yields.
	@param player Player
	Example: PlotNames.apply(player)
]]
function PlotNames.apply(player: Player)
	local d = deps
	if d == nil then
		return
	end
	local index = d.getPlotIndex(player)
	local profile = PlayerDataService.getProfile(player)
	if index == nil or profile == nil then
		return
	end
	local saved = profile.plotName
	local intent = PlotNameLogic.parse(saved, MAX_CHARS)
	if intent == nil or intent.kind ~= "set" then
		bump(player)
		showEverywhere(index, "")
		return
	end
	local cached = displayed[player]
	if cached ~= nil and cached.source == saved then
		showEverywhere(index, cached.shown)
		return
	end
	showEverywhere(index, "") -- the default while the saved name is re-checked
	local name = intent.text
	local token = bump(player)
	task.spawn(function()
		local filtered = d.filter(player, name)
		-- Still the same player, plot, profile, saved name and newest request?
		if
			player.Parent ~= Players
			or tokens[player] ~= token
			or d.getPlotIndex(player) ~= index
			or PlayerDataService.getProfile(player) ~= profile
			or profile.plotName ~= saved
		then
			return
		end
		-- Fail closed: a failed filter, or a name the filter now changes, keeps the default sign.
		local shown = if filtered == name then name else ""
		displayed[player] = { source = saved, shown = shown }
		showEverywhere(index, shown)
	end)
end

--[[
	Saves + shows a new plot name ("" = reset to the default), pushes the owner's snapshot field,
	records analytics and toasts.
	@param how "set" | "reset" — the analytics suffix
]]
local function commit(player: Player, profile: Profile, index: number, name: string, how: string)
	bump(player)
	displayed[player] = if name ~= "" then { source = name, shown = name } else nil
	profile.plotName = name
	PlayerDataService.markChanged(player, true, { "plotName" })
	showEverywhere(index, name)
	TycoonAnalytics.call("tycoon", player, `renamePlot:{how}`)
	PlayerDataService.notify(player, if name ~= "" then Copy.Saved else Copy.Reset, "success")
end

--[[
	RenamePlot(text) handler (see the header for every check, in order).
	@param player Player — a present player (Remotes.onServerEvent guard)
	@param raw unknown — the client's text ("" = reset to default)
]]
local function onRename(player: Player, raw: unknown)
	local d = deps
	if d == nil or busy[player] then
		return
	end
	local intent = PlotNameLogic.parse(raw, MAX_CHARS)
	local profile = PlayerDataService.getProfile(player)
	if intent == nil or profile == nil then
		return
	end
	if not limiter:Allow(player) then
		if toastLimiter:Allow(player) then
			PlayerDataService.notify(player, Copy.TooFast, "info")
		end
		return
	end
	local index = d.getPlotIndex(player)
	if index == nil then
		PlayerDataService.notify(player, Copy.NoPlot, "info")
		return
	end
	if intent.kind == "reset" then
		if profile.plotName == "" then
			PlayerDataService.notify(player, Copy.HintAlreadyDefault, "info")
			return
		end
		commit(player, profile, index, "", "reset")
		return
	end
	local name = intent.text
	if name == profile.plotName then
		PlayerDataService.notify(player, Copy.Same, "info")
		return
	end
	busy[player] = true
	-- Any apply / reset / admin clear during the filter call bumps the token: that newer state wins.
	local token = tokens[player] or 0
	local filtered = d.filter(player, name)
	busy[player] = nil
	-- The filter yields: re-check the player, plot, profile (a profile swap or leave can land) and
	-- that no moderator reset / plot change happened meanwhile.
	if
		player.Parent ~= Players
		or (tokens[player] or 0) ~= token
		or d.getPlotIndex(player) ~= index
		or PlayerDataService.getProfile(player) ~= profile
	then
		return
	end
	if filtered == nil then
		PlayerDataService.notify(player, Copy.FilterFailed, "error")
		return
	end
	if filtered ~= name then
		-- The filter censored part of it: refuse instead of showing "####" on the sign.
		PlayerDataService.notify(player, Copy.Censored, "error")
		return
	end
	commit(player, profile, index, name, "set")
end

--[[
	Admin moderation (PlotNameAdmin "ResetPlotName"): clears a player's plot name back to the
	default, saves, pushes, re-signs every world and tells the player kindly.
	@param player Player — online, profile loaded (AdminService validated the target)
	@return (ok, message) — the message names the cleared (filtered) name for the audit log
	Example: PlotNames.adminReset(player) --> true, 'Reset Sam's plot name (was "Sparkle Base")'
]]
function PlotNames.adminReset(player: Player): (boolean, string)
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false, "profile not loaded"
	end
	local previous = profile.plotName
	if previous == "" then
		return true, `{player.Name} already uses the default plot name`
	end
	bump(player)
	displayed[player] = nil
	profile.plotName = ""
	PlayerDataService.markChanged(player, true, { "plotName" })
	local d = deps
	local index = if d ~= nil then d.getPlotIndex(player) else nil
	if index ~= nil then
		showEverywhere(index, "")
	end
	TycoonAnalytics.call("tycoon", player, "renamePlot:admin")
	PlayerDataService.notify(player, Copy.AdminReset, "info")
	return true, `Reset {player.Name}'s plot name (was "{previous}")`
end

--[[ Drops a leaving player's state (PlotService's PlayerRemoving). ]]
function PlotNames.forget(player: Player)
	busy[player] = nil
	displayed[player] = nil
	tokens[player] = nil
	limiter:Forget(player)
	toastLimiter:Forget(player)
end

--[[
	Wires the feature (once; PlotService.Start, BEFORE any plot is claimed): stores the deps,
	connects RenamePlot and registers the admin command.
	@param newDeps Deps
]]
function PlotNames.start(newDeps: Deps)
	deps = newDeps
	if started then
		return
	end
	started = true
	Remotes.onServerEvent("RenamePlot", onRename)
	PlotNameAdmin.install(PlotNames)
end

return PlotNames
