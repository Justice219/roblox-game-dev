--!strict
--[[
	PlayerTitleService — Player Titles (owner R73: "give me a name tag whenever I'm in the game so
	people know I'm the developer"; R74: a small titles system — DEVELOPER, FIRST PLAYER,
	EARLY PLAYER).

	What it does (server-authoritative; display only, a title never grants anything):
		- Decides each player's ONE displayed title (Shared/Util/PlayerTitles.resolve): the
		  highest-priority catalogue title among their permanent UserId titles
		  (PlayerTitlesConfig.Holders — UserIds only, never names) and the titles the owner granted
		  them (profile.titles). Sets the replicated Player attribute `Title` (key, "" = none):
		  on join (permanent titles show before the profile loads), on every ProfileLoaded (join
		  and the New Player Mode swaps, so the developer keeps the tag in the sandbox) and after
		  every grant / revoke. Clients cannot set replicated Player attributes, so nobody can fake
		  a title; clients only render it (Client/Social/PlayerTitleClient).
		- `TitleHidden` mirrors the player's own `showTitle` setting (the admin panel's
		  "MY TITLE TAG: ON / OFF" chip sends the ordinary SetSetting intent; SettingsService's
		  allowlist validates it).
		- Admin (owner panel, Players tab, audited like every admin command; AdminService validates
		  the target + the enum BEFORE the handler, which re-validates against the catalogue):
		      TitleGrant  { title }   gives a grantable title to an online player (saved soon)
		      TitleRevoke { title }   removes a granted title
		  DEVELOPER is never grantable (PlayerTitlesConfig: grantable = false); permanent UserId
		  titles are config, so a revoke never touches them.

	Analytics: none (no natural counter; the admin audit log records every grant / revoke).

	Connects to: Shared/Config/PlayerTitlesConfig, Shared/Util/PlayerTitles,
	Services/{PlayerDataService (getProfile, markChanged, ProfileLoaded), SettingsService (get,
	Changed)}, Services/AdminService (guarded lazy registerCommand, the ChangeNotesAdmin pattern).
	Boot: a feature service after SettingsService (init.server.luau FEATURE_SERVICES).

	Example:
		PlayerTitleService.titleOf(player) --> "developer"
		PlayerTitleService.grant(player, "earlyPlayer") --> true, "Gave EARLY PLAYER to ..."
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerDataService = require(script.Parent.PlayerDataService)
local PlayerTitles = require(ReplicatedStorage.Shared.Util.PlayerTitles)
local PlayerTitlesConfig = require(ReplicatedStorage.Shared.Config.PlayerTitlesConfig)
local SettingsService = require(script.Parent.SettingsService)

local PlayerTitleService = {}

-- Admin panel order (after the What's New commands, 380+).
local ADMIN_ORDER = 390

type Ctx = { args: { [string]: any }, target: { player: Player?, label: string }? }

--[[ The title `player` displays right now (catalogue key) or nil. ]]
function PlayerTitleService.titleOf(player: Player): string?
	local profile = PlayerDataService.getProfile(player)
	return PlayerTitles.resolve(player.UserId, if profile ~= nil then (profile :: any).titles else nil)
end

-- Re-sets the Title / TitleHidden attributes from the UserId, the profile and the setting.
local function apply(player: Player)
	if player.Parent ~= Players then
		return
	end
	player:SetAttribute(PlayerTitlesConfig.Attr, PlayerTitleService.titleOf(player) or "")
	local show = SettingsService.get(player, PlayerTitlesConfig.SettingKey :: any)
	player:SetAttribute(PlayerTitlesConfig.HiddenAttr, PlayerTitles.hiddenFromSetting(show))
end

-- The editable granted set of a loaded profile, else nil.
local function grantedOf(player: Player): PlayerTitles.State?
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return nil
	end
	local raw: any = profile
	if type(raw.titles) ~= "table" then
		raw.titles = PlayerTitles.newState()
	end
	return raw.titles
end

--[[
	Gives a grantable title to `player` (validated against the catalogue; saved soon).
	@return (ok, message) for the admin panel
]]
function PlayerTitleService.grant(player: Player, key: unknown): (boolean, string)
	local granted = grantedOf(player)
	if granted == nil then
		return false, "Their profile is not loaded yet"
	end
	local changed, problem = PlayerTitles.grant(granted, key)
	local entry = PlayerTitles.def(key)
	local label = if entry ~= nil then entry.label else "that title"
	if not changed then
		return false, `Can't give {label}: {problem or "refused"}`
	end
	PlayerDataService.markChanged(player, true, {}) -- private field: save soon, nothing to push
	apply(player)
	return true, `Gave {label} to {player.DisplayName} (@{player.Name})`
end

--[[
	Removes a granted title from `player` (validated; saved soon). Permanent UserId titles are
	config and never removed here.
	@return (ok, message)
]]
function PlayerTitleService.revoke(player: Player, key: unknown): (boolean, string)
	local granted = grantedOf(player)
	if granted == nil then
		return false, "Their profile is not loaded yet"
	end
	local changed, problem = PlayerTitles.revoke(granted, key)
	local entry = PlayerTitles.def(key)
	local label = if entry ~= nil then entry.label else "that title"
	if not changed then
		return false, `Can't remove {label}: {problem or "refused"}`
	end
	PlayerDataService.markChanged(player, true, {})
	apply(player)
	return true, `Removed {label} from {player.DisplayName} (@{player.Name})`
end

-- Registers TitleGrant / TitleRevoke with AdminService (guarded: a missing admin never errors).
local function installAdmin()
	local module = ServerScriptService.Server.Services:FindFirstChild("AdminService")
	if module == nil or not module:IsA("ModuleScript") then
		return
	end
	local ok, AdminService = pcall(require, module)
	if not ok or type(AdminService) ~= "table" or type((AdminService :: any).registerCommand) ~= "function" then
		warn("[PlayerTitleService] AdminService could not be loaded; title admin commands not registered")
		return
	end
	local register = (AdminService :: any).registerCommand
	local values, labels = PlayerTitles.grantChoices()
	local function add(def: any, handler: (ctx: Ctx) -> (boolean, string))
		local registered, err = pcall(register, def, handler)
		if not registered then
			warn(`[PlayerTitleService] {def.name} not registered: {err}`)
		end
	end
	local function target(ctx: Ctx): Player?
		local picked = ctx.target
		return if picked ~= nil then picked.player else nil
	end
	add({
		name = "TitleGrant",
		tab = "Players",
		label = "Give Title",
		description = "Gives them a title tag over their head + a chat tag (saved on their profile).",
		target = "Player",
		args = { title = { kind = "enum", values = values, labels = labels, label = "Title" } },
		argOrder = { "title" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "yellow",
		order = ADMIN_ORDER,
	}, function(ctx: Ctx): (boolean, string)
		local player = target(ctx)
		if player == nil then
			return false, "Pick an online player first"
		end
		return PlayerTitleService.grant(player, ctx.args.title)
	end)
	add({
		name = "TitleRevoke",
		tab = "Players",
		label = "Remove Title",
		description = "Removes a title you gave them (permanent titles like DEVELOPER stay).",
		target = "Player",
		args = { title = { kind = "enum", values = values, labels = labels, label = "Title" } },
		argOrder = { "title" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "grey",
		order = ADMIN_ORDER + 1,
	}, function(ctx: Ctx): (boolean, string)
		local player = target(ctx)
		if player == nil then
			return false, "Pick an online player first"
		end
		return PlayerTitleService.revoke(player, ctx.args.title)
	end)
end

function PlayerTitleService.Init() end

function PlayerTitleService.Start()
	Players.PlayerAdded:Connect(apply)
	for _, player in Players:GetPlayers() do
		task.spawn(apply, player)
	end
	-- Join + New Player Mode swaps: the (possibly sandbox) profile's granted titles + setting.
	PlayerDataService.ProfileLoaded:Connect(function(player: Player)
		apply(player)
	end)
	SettingsService.Changed:Connect(function(player: Player, key: string)
		if key == PlayerTitlesConfig.SettingKey then
			apply(player)
		end
	end)
	installAdmin()
end

return PlayerTitleService
