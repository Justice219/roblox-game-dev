--!strict
--[[
	EconomyHandlers — built-in handlers of the admin panel's ECONOMY tab (spec §14): the
	server-wide 2x cash boost (B7 ServerBoostService seam) and Studio-only test receipts.

	TestReceipt runs a fake receipt for the CALLER through the REAL receipt path
	(MonetizationService.simulateReceiptAsync: handlers, idempotent ledger, analytics). It is
	refused outside Studio twice: the command is `studioOnly` (the pipeline refuses it live) and
	simulateReceiptAsync itself errors outside Studio — no live code path can mint purchases.

	Connects to: Server/Admin/HandlerKit, Server/Admin/Seams (ServerBoostService),
	Server/Services/MonetizationService.

	Example:
		EconomyHandlers.install(registry, env)
]]

local RunService = game:GetService("RunService")

local HandlerKit = require(script.Parent.HandlerKit)
local MonetizationService = require(script.Parent.Parent.Parent.Services.MonetizationService)
local Seams = require(script.Parent.Parent.Seams)

type Context = HandlerKit.Context

local EconomyHandlers = {}

local Kit = HandlerKit

-- ServerBoost: ServerBoostService.start(seconds, byName) -> new end time or nil.
local function serverBoost(ctx: Context): (boolean, string)
	local minutes = Kit.num(ctx, "minutes") :: number
	local found, endsAt = Seams.call(Seams.service("ServerBoostService"), "start", minutes * 60, ctx.caller.name)
	if not found then
		return false, Kit.RETENTION
	end
	if type(endsAt) ~= "number" then
		return false, "Could not start the server boost"
	end
	local left = math.max(0, endsAt - os.time())
	return true, `Server 2x cash on: {math.floor(left / 60 + 0.5)} min left`
end

-- ServerBoostOff: ServerBoostService.stop().
local function serverBoostOff(_ctx: Context): (boolean, string)
	local service = Seams.service("ServerBoostService")
	if not Seams.has(service, "stop") then
		return false, Kit.RETENTION
	end
	if Seams.has(service, "isActive") and service.isActive() ~= true then
		return false, "The server boost is not running"
	end
	service.stop()
	return true, "Server 2x cash stopped"
end

-- TestReceipt (Studio only): a fake receipt for the caller through the real receipt path.
local function testReceipt(ctx: Context): (boolean, string)
	if not RunService:IsStudio() then
		return false, "Test receipts are Studio-only"
	end
	local player = ctx.caller.player
	if player == nil then
		return false, "Only an in-game admin can run a test receipt"
	end
	local product = Kit.str(ctx, "product") :: string
	local decision = MonetizationService.simulateReceiptAsync(player, product)
	local granted = decision == Enum.ProductPurchaseDecision.PurchaseGranted
	return granted, `Test receipt {product}: {decision.Name}`
end

--[[ Installs every Economy-tab handler into the registry. ]]
function EconomyHandlers.install(registry: HandlerKit.Registry, _env: HandlerKit.Env)
	registry.setBuiltin("ServerBoost", serverBoost, Kit.serviceProbe("ServerBoostService", "start", Kit.RETENTION))
	registry.setBuiltin("ServerBoostOff", serverBoostOff, Kit.serviceProbe("ServerBoostService", "stop", Kit.RETENTION))
	registry.setBuiltin("TestReceipt", testReceipt)
end

return table.freeze(EconomyHandlers)
