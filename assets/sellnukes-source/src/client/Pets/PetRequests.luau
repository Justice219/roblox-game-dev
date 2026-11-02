--!strict
--[[
	PetRequests — the client side of the HatchEgg / OpenCrate request protocol.

	Each press sends an INTENT with a fresh request id (1, 2, 3 ... per session; the server
	remembers the last 32 replies per player, so a resend of the same id is answered with the same
	result and never charged twice). One request of each kind is in flight at a time; a reply that
	never comes is timed out after TIMEOUT seconds (the UI unlocks; the server's reply, if it
	arrives later, is still delivered — screens ignore ids they are not waiting for).

	Signals (every reply, including server-initiated ones with request id 0 — pet grants):
		PetRequests.HatchResult(requestId, payload)   PetService.HatchPayload shape
		PetRequests.CrateResult(requestId, payload)   CrateService.CratePayload shape
	Payloads are sanity-checked (tables with an `ok` boolean) before they are fired.

	Connects to: Shared/Net/Remotes (HatchEgg, HatchResult, OpenCrate, CrateResult),
	UI/Screens/{EggHatch, Pets, CrateShop, CrateOpen}, Client/Pets/PetController (start).

	Example:
		local id = PetRequests.hatch("garage_egg", 1, false)
		PetRequests.HatchResult:Connect(function(requestId, payload) if requestId == id then ... end end)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local PetRequests = {}

PetRequests.HatchResult = Signal.new() :: Signal.Signal<number, any>
PetRequests.CrateResult = Signal.new() :: Signal.Signal<number, any>

-- Seconds before an unanswered request unlocks the UI.
local TIMEOUT = 10

local nextId = 0
local pendingHatch: number? = nil
local pendingCrate: number? = nil
local started = false

-- A fresh request id (never 0: 0 is reserved for server-initiated replies).
local function newId(): number
	nextId += 1
	if nextId >= 2 ^ 31 then
		nextId = 1
	end
	return nextId
end

-- True for a reply payload worth delivering.
local function valid(payload: unknown): boolean
	return type(payload) == "table" and type((payload :: any).ok) == "boolean"
end

--[[
	Sends a hatch intent. @return the request id, or nil while another hatch is pending
	@param auto true when the auto-hatch loop sent it (analytics only)
]]
function PetRequests.hatch(eggId: string, count: number, auto: boolean): number?
	if pendingHatch ~= nil then
		return nil
	end
	local id = newId()
	pendingHatch = id
	Remotes.event("HatchEgg"):FireServer(eggId, count, id, auto)
	task.delay(TIMEOUT, function()
		if pendingHatch == id then
			pendingHatch = nil
			PetRequests.HatchResult:Fire(
				id,
				{ ok = false, code = "Timeout", message = "No answer from the server - try again!" }
			)
		end
	end)
	return id
end

--[[ Sends an open-crate intent. @return the request id, or nil while another open is pending ]]
function PetRequests.openCrate(crateId: string): number?
	if pendingCrate ~= nil then
		return nil
	end
	local id = newId()
	pendingCrate = id
	Remotes.event("OpenCrate"):FireServer(crateId, id)
	task.delay(TIMEOUT, function()
		if pendingCrate == id then
			pendingCrate = nil
			PetRequests.CrateResult:Fire(
				id,
				{ ok = false, code = "Timeout", message = "No answer from the server - try again!" }
			)
		end
	end)
	return id
end

--[[ True while a hatch request waits for its reply. ]]
function PetRequests.hatchPending(): boolean
	return pendingHatch ~= nil
end

--[[ True while a crate request waits for its reply. ]]
function PetRequests.cratePending(): boolean
	return pendingCrate ~= nil
end

--[[ Connects the reply remotes once (PetController.Start). ]]
function PetRequests.start()
	if started then
		return
	end
	started = true
	Remotes.event("HatchResult").OnClientEvent:Connect(function(requestId: unknown, payload: unknown)
		if type(requestId) ~= "number" or not valid(payload) then
			return
		end
		if requestId == pendingHatch then
			pendingHatch = nil
		end
		PetRequests.HatchResult:Fire(requestId, payload)
	end)
	Remotes.event("CrateResult").OnClientEvent:Connect(function(requestId: unknown, payload: unknown)
		if type(requestId) ~= "number" or not valid(payload) then
			return
		end
		if requestId == pendingCrate then
			pendingCrate = nil
		end
		PetRequests.CrateResult:Fire(requestId, payload)
	end)
end

return PetRequests
