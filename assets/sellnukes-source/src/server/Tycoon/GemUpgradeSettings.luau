--!strict
--[[
	GemUpgradeSettings — the live, admin-adjustable settings of the owner R86 gem upgrade (hard rule
	9: "every system is controllable from the owner-only admin panel where that makes sense").

	Purpose:
		Holds this server's flat gem price (default TycoonConfig.GemUpgradePrice) and the on/off
		switch, and replicates both as ReplicatedStorage attributes (TycoonConfig.GemUpgrade
		.PriceAttribute / EnabledAttribute) so every billboard shows the live price. Only this module
		writes them; clients read them through Shared/Tycoon/GemUpgradeRules (sanitised) and the
		server never trusts anything a client says about the price.
		Admin: one command registered at runtime with AdminService.registerCommand (the
		ChangeNotesAdmin pattern: guarded lazy require, nothing errors when the admin system is
		missing), Economy tab:
			GemUpgradeSettings  { price 1..10000 gems, enabled }   this server only (a new server
			                                                      starts from the config default;
			                                                      a permanent change = edit
			                                                      TycoonConfig.GemUpgradePrice)
		Audited; the panel validates the range before the handler runs.

	Connects to: Server/Tycoon/TycoonService (start + price() / enabled() in the handler),
	Server/Services/AdminService (registerCommand), Shared/Config/TycoonConfig,
	Shared/Tycoon/GemUpgradeRules.

	Example:
		GemUpgradeSettings.start()
		print(GemUpgradeSettings.price()) --> 75
		GemUpgradeSettings.set(100, true)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GemUpgradeRules = require(ReplicatedStorage.Shared.Tycoon.GemUpgradeRules)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)

local Gem = TycoonConfig.GemUpgrade

local GemUpgradeSettings = {}

-- Panel order on the Economy tab (after the server boost 10/11 and test receipts 20).
local ORDER = 30

local livePrice = TycoonConfig.GemUpgradePrice
local liveEnabled = true
local started = false
local adminInstalled = false

-- Writes the replicated attributes (the only writer). Only a real DataModel carries attributes:
-- the Lune test harness stubs ReplicatedStorage with a plain table, which is skipped.
local function publish()
	if typeof(ReplicatedStorage) ~= "Instance" then
		return
	end
	ReplicatedStorage:SetAttribute(Gem.PriceAttribute, livePrice)
	ReplicatedStorage:SetAttribute(Gem.EnabledAttribute, liveEnabled)
end

--[[ This server's flat gem price for one level. ]]
function GemUpgradeSettings.price(): number
	return livePrice
end

--[[ True while the gem button sells (admin switch). ]]
function GemUpgradeSettings.enabled(): boolean
	return liveEnabled
end

--[[
	Sets this server's price + switch (admin). The price is clamped to MinPrice..MaxPrice through
	GemUpgradeRules.price (malformed = the config default).
	@return (ok, message) for the admin panel
]]
function GemUpgradeSettings.set(price: number, enabled: boolean): (boolean, string)
	livePrice = GemUpgradeRules.price(price)
	liveEnabled = enabled == true
	publish()
	local state = if liveEnabled then "ON" else "OFF"
	return true, `Gem upgrade {state}: {livePrice} gems per level (this server)`
end

-- Registers the admin command (idempotent; false while AdminService is unavailable).
local function installAdmin(): boolean
	if adminInstalled then
		return true
	end
	local services = ServerScriptService:FindFirstChild("Server")
	local folder = if services ~= nil then services:FindFirstChild("Services") else nil
	local module = if folder ~= nil then folder:FindFirstChild("AdminService") else nil
	if module == nil or not module:IsA("ModuleScript") then
		return false
	end
	local ok, AdminService = pcall(require, module)
	if not ok or type(AdminService) ~= "table" or type((AdminService :: any).registerCommand) ~= "function" then
		warn("[GemUpgradeSettings] AdminService could not be loaded; gem upgrade admin command not registered")
		return false
	end
	adminInstalled = true
	local registered, err = pcall((AdminService :: any).registerCommand, {
		name = "GemUpgradeSettings",
		tab = "Economy",
		label = "Gem upgrade price",
		description = `Flat gems for ONE producer level (owner R86) + on/off, this server. Default {TycoonConfig.GemUpgradePrice}.`,
		target = "None",
		args = {
			price = {
				kind = "integer",
				min = Gem.MinPrice,
				max = Gem.MaxPrice,
				label = "Gems per level",
				presets = { 25, 50, 75, 100, 250 },
				default = TycoonConfig.GemUpgradePrice,
			},
			enabled = { kind = "boolean", label = "Gem button on", default = true },
		},
		argOrder = { "price", "enabled" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "purple",
		order = ORDER,
	}, function(ctx: any): (boolean, string)
		local args = if type(ctx) == "table" and type(ctx.args) == "table" then ctx.args else {}
		local price = args.price
		if type(price) ~= "number" then
			return false, "Pick a price"
		end
		return GemUpgradeSettings.set(price, args.enabled ~= false)
	end)
	if not registered then
		warn(`[GemUpgradeSettings] admin command not registered: {err}`)
	end
	return registered
end

--[[ Publishes the defaults and registers the admin command (once; TycoonService.Start). ]]
function GemUpgradeSettings.start()
	if started then
		return
	end
	started = true
	publish()
	installAdmin()
end

return GemUpgradeSettings
