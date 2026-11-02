--!strict
--[[
	LobbyNpcService — the server half of the lobby visitors (owner R100): builds the R15 TEMPLATE
	rigs the clients clone, and the owner-admin on / off switch (hard rule 9).

	Templates: Players:CreateHumanoidModelFromDescriptionAsync is a server-side API, so the server
	builds one rig per LobbyNpcConfig.Presets row ONCE at boot (in a background thread; each build
	yields while Roblox loads the catalog assets) from a HumanoidDescription made ONLY of the preset's
	config values — never from client input and never from a real player's avatar. Each rig is
	stripped of scripts, its parts made non-colliding / non-queryable / non-touching and massless,
	its root anchored, its Humanoid quieted (no name / health display, no state machine), then
	parented as "LobbyNpc_<presetId>" under ReplicatedStorage.LobbyNpcTemplates (inert there: not in
	Workspace, never simulated). The folder's "Ready" attribute turns true when the pass ends (failed
	presets are skipped with one warning each; clients use what exists).

	Admin: "LobbyNpcs" (Server tab, { on }) sets ReplicatedStorage attribute LobbyNpcsEnabled for THIS
	server; clients remove / respawn their visitors on their next refresh. Registered through a
	GUARDED lazy require of AdminService (PlotNameAdmin pattern): a missing AdminService only skips
	the command. AdminService authorises, validates, rate-limits and audits before the handler runs.

	Security: no remotes; the client only reads replicated templates + one boolean attribute.
	Performance: <= 12 small rigs built once; nothing runs after boot.

	Boot: feature service "World/LobbyNpcService" in src/server/init.server.luau (Init / Start).

	Connects to: Shared/Config/LobbyNpcConfig, Server/Services/AdminService (lazy), clients:
	Client/Lobby/LobbyNpcs.

	Example (Studio command bar, server):
		require(game.ServerScriptService.Server.World.LobbyNpcService).stats()
		--> { built = 12, failed = 0, ready = true, enabled = true }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local LobbyNpcConfig = require(ReplicatedStorage.Shared.Config.LobbyNpcConfig)

local LobbyNpcService = {}

-- Attempts per preset (a catalog load can fail transiently) and the pause between them.
local BUILD_ATTEMPTS = 2
local RETRY_SECONDS = 3
-- Admin panel order on the Server tab (after the world switches at 50-72).
local ADMIN_ORDER = 95

local folder: Folder? = nil
local built = 0
local failed = 0
local started = false

-- Comma-separated asset id list for a HumanoidDescription accessory field (positive integers only).
local function idList(ids: { number }): string
	local parts: { string } = {}
	for _, id in ids do
		if type(id) == "number" and id > 0 and id % 1 == 0 then
			table.insert(parts, tostring(id))
		end
	end
	return table.concat(parts, ",")
end

-- A positive integer asset id, else 0 (none).
local function assetId(id: unknown): number
	return if type(id) == "number" and id > 0 and id % 1 == 0 then id else 0
end

--[[
	The HumanoidDescription of one preset (config values only).
	@return HumanoidDescription
]]
local function describe(preset: LobbyNpcConfig.Preset): HumanoidDescription
	local description = Instance.new("HumanoidDescription")
	description.Shirt = assetId(preset.shirt)
	description.Pants = assetId(preset.pants)
	description.Face = assetId(preset.face)
	description.HairAccessory = idList(preset.hair)
	description.HatAccessory = idList(preset.hats)
	description.FaceAccessory = idList(preset.faceAccessories)
	local skin = preset.skin
	local torso = preset.torsoColor or skin
	local legs = preset.legColor or skin
	description.HeadColor = skin
	description.LeftArmColor = skin
	description.RightArmColor = skin
	description.TorsoColor = torso
	description.LeftLegColor = legs
	description.RightLegColor = legs
	return description
end

-- Makes a built rig inert + client-ready (see header).
local function sanitize(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
			descendant.Anchored = false
		elseif descendant:IsA("LuaSourceContainer") then
			descendant:Destroy()
		end
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		root.Anchored = true
		model.PrimaryPart = root
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		humanoid.BreakJointsOnDeath = false
		humanoid.RequiresNeck = false
		humanoid.EvaluateStateMachine = false
	end
end

-- Builds one preset's rig (retries once); nil when Roblox could not build it.
local function buildOne(preset: LobbyNpcConfig.Preset): Model?
	local lastError: string = "unknown"
	for attempt = 1, BUILD_ATTEMPTS do
		local description = describe(preset)
		local ok, result = pcall(function()
			return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R15)
		end)
		description:Destroy()
		if ok and typeof(result) == "Instance" and result:IsA("Model") then
			return result
		end
		lastError = tostring(result)
		if attempt < BUILD_ATTEMPTS then
			task.wait(RETRY_SECONDS)
		end
	end
	warn(`[LobbyNpcService] preset {preset.id} not built: {string.sub(lastError, 1, 160)}`)
	return nil
end

-- The template pass (background thread).
local function buildAll(parent: Folder)
	for _, preset in LobbyNpcConfig.Presets do
		local model = buildOne(preset)
		if model ~= nil then
			sanitize(model)
			model.Name = `LobbyNpc_{preset.id}`
			model.Parent = parent
			built += 1
		else
			failed += 1
		end
	end
	parent:SetAttribute(LobbyNpcConfig.ReadyAttribute, true)
end

-- Registers the "LobbyNpcs" admin switch (guarded; see header).
local function installAdmin()
	local server = ServerScriptService:FindFirstChild("Server")
	local services = if server ~= nil then server:FindFirstChild("Services") else nil
	local module = if services ~= nil then services:FindFirstChild("AdminService") else nil
	if module == nil or not module:IsA("ModuleScript") then
		return
	end
	local ok, AdminService = pcall(require, module)
	if not ok or type(AdminService) ~= "table" or type((AdminService :: any).registerCommand) ~= "function" then
		warn("[LobbyNpcService] AdminService could not be loaded; LobbyNpcs admin command not registered")
		return
	end
	local registered, err = pcall((AdminService :: any).registerCommand, {
		name = "LobbyNpcs",
		tab = "Server",
		label = "Lobby Visitors On/Off",
		description = "Shows or removes the walking R15 lobby visitors on THIS server (cosmetic; clients update within a second).",
		target = "None",
		args = {
			on = { kind = "boolean", label = "Visitors on", default = true },
		},
		argOrder = { "on" },
		cooldown = 2,
		audited = true,
		confirm = false,
		color = "grey",
		order = ADMIN_ORDER,
	}, function(ctx: any): (boolean, string)
		local on = type(ctx) == "table" and type(ctx.args) == "table" and ctx.args.on == true
		ReplicatedStorage:SetAttribute(LobbyNpcConfig.EnabledAttribute, on)
		return true, if on then "Lobby visitors on (this server)" else "Lobby visitors off (this server)"
	end)
	if not registered then
		warn(`[LobbyNpcService] LobbyNpcs not registered: {err}`)
	end
end

--[[ Creates the template folder (empty, not ready) and the enabled flag. ]]
function LobbyNpcService.Init()
	local existing = ReplicatedStorage:FindFirstChild(LobbyNpcConfig.TemplateFolder)
	if existing ~= nil then
		existing:Destroy()
	end
	local created = Instance.new("Folder")
	created.Name = LobbyNpcConfig.TemplateFolder
	created:SetAttribute(LobbyNpcConfig.ReadyAttribute, false)
	created.Parent = ReplicatedStorage
	folder = created
	if ReplicatedStorage:GetAttribute(LobbyNpcConfig.EnabledAttribute) == nil then
		ReplicatedStorage:SetAttribute(LobbyNpcConfig.EnabledAttribute, true)
	end
end

--[[ Builds the templates in the background and registers the admin switch (idempotent). ]]
function LobbyNpcService.Start()
	if started then
		return
	end
	started = true
	local parent = folder
	if parent ~= nil then
		task.spawn(buildAll, parent)
	end
	installAdmin()
end

--[[ Debug snapshot. ]]
function LobbyNpcService.stats(): { [string]: any }
	local parent = folder
	return {
		built = built,
		failed = failed,
		ready = parent ~= nil and parent:GetAttribute(LobbyNpcConfig.ReadyAttribute) == true,
		enabled = ReplicatedStorage:GetAttribute(LobbyNpcConfig.EnabledAttribute) ~= false,
	}
end

return LobbyNpcService
