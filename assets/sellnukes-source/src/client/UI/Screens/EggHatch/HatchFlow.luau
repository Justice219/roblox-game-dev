--!strict
--[[
	HatchFlow — what happens after a HATCH press (client orchestration only; the server decides
	everything): send the intent → wait for HatchResult → close the EggHatch window → play the
	HatchReveal cinematic → then either reopen the stand window or, in AUTO mode, hatch again.

	The cinematic itself (owner R49) lives in HatchRevealScreen + HatchStage, timed by
	Client/Pets/HatchAnim; it also plays the short version when the player turned on Settings
	"Fast Hatch" (profile settings.fastHatch).

	Auto-hatch (AutoHatch game pass; the UI only offers it to owners): a loop of ordinary hatch
	requests with the fast cinematic. It stops on STOP AUTO / gamepad B, on any refusal (not
	enough cash, backpack full, region restriction, ...), when the player walks away from the
	stand (held eggs: when none are left), when the next round would have to BUY eggs in a region
	that restricts paid random items (profile.policy), or when the profile says the pass is gone.

	Server grants (group pet, Gobble Bomb, packs, admin) arrive as HatchResult id 0 and play the
	same reveal without an egg (playGrant).

	Signals: HatchFlow.Changed() fires when the auto state or the busy state changes (EggHatch
	screen refreshes its buttons).

	Connects to: Client/Pets/PetRequests, UI/ScreenManager, UI/Hud/Hud (toasts), Client/ClientState,
	UI/Screens/EggHatch/{EggHatchScreen, HatchRevealScreen}, Client/Pets/PetController (grants).

	Example:
		HatchFlow.hatch("garage_egg", 3)
		HatchFlow.setAuto("garage_egg", 1, true)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.Parent.Parent.Parent.ClientState)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local Hud = require(script.Parent.Parent.Parent.Hud.Hud)
local PetRequests = require(script.Parent.Parent.Parent.Parent.Pets.PetRequests)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local HatchFlow = {}

HatchFlow.Changed = Signal.new() :: Signal.Signal<>

type AutoState = { eggId: string, count: number }

local auto: AutoState? = nil
local busy = false
local LOCAL = Players.LocalPlayer

-- How close (studs) the player must stay to a stand for auto-hatch to keep buying.
local AUTO_RANGE = EggConfig.StandRange - 2

local function setBusy(value: boolean)
	if busy ~= value then
		busy = value
		HatchFlow.Changed:Fire()
	end
end

--[[ True while a hatch request or its cinematic is running. ]]
function HatchFlow.isBusy(): boolean
	return busy
end

--[[ The current auto-hatch target (nil when off). ]]
function HatchFlow.autoState(): AutoState?
	return auto
end

--[[ Stops auto-hatching (no-op when off). ]]
function HatchFlow.stopAuto(reason: string?)
	if auto == nil then
		return
	end
	auto = nil
	if reason ~= nil then
		Hud.notify("info", reason)
	end
	HatchFlow.Changed:Fire()
end

-- Held eggs of `eggId` in the latest profile.
local function heldCount(eggId: string): number
	local profile = ClientState.profile
	local pets = if type(profile) == "table" then profile.pets else nil
	local eggs = if type(pets) == "table" then pets.eggs else nil
	return if type(eggs) == "table" then tonumber(eggs[eggId]) or 0 else 0
end

-- True when the local character stands near the egg's stand.
local function nearStand(eggId: string): boolean
	local folder = Workspace:FindFirstChild("PetStands")
	local stand = if folder ~= nil then folder:FindFirstChild(`Stand_{eggId}`) else nil
	local character = LOCAL.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if stand == nil or not stand:IsA("Model") or root == nil or not root:IsA("BasePart") then
		return false
	end
	local pivot = stand:GetPivot().Position
	-- The stand pivot is its display egg; compare on the ground plane (+ a generous height).
	local offset = (root.Position - pivot) * Vector3.new(1, 0.25, 1)
	return offset.Magnitude <= AUTO_RANGE
end

-- Reopen the window only where it makes sense (still at the stand, or eggs held).
local function nearOrHeld(eggId: string): boolean
	return nearStand(eggId) or heldCount(eggId) > 0
end

-- After a reveal: keep auto going, or reopen the stand window.
local function afterReveal(eggId: string)
	setBusy(false)
	local state = auto
	if state ~= nil and state.eggId == eggId then
		local egg = EggConfig.get(eggId)
		local profile = ClientState.profile
		-- Buying again is only offered where paid random items are not restricted (the server
		-- re-checks every request and fails closed; this just avoids a pointless refusal).
		local regionBlocked = egg ~= nil
			and EggConfig.policyState(if type(profile) == "table" then profile.policy else nil) == "restricted"
			and EggConfig.needsPolicy(egg, heldCount(eggId), state.count)
		local canBuy = egg ~= nil and egg.currency ~= "held" and not regionBlocked and nearStand(eggId)
		if heldCount(eggId) >= state.count or canBuy then
			HatchFlow.hatch(eggId, state.count)
			return
		end
		HatchFlow.stopAuto(
			if egg ~= nil and egg.currency == "held"
				then "No more eggs to hatch!"
				elseif regionBlocked then "Auto hatch stopped - " .. EggConfig.PolicyText.Restricted
				else "Auto hatch stopped - you walked away from the stand."
		)
	end
	if nearOrHeld(eggId) then
		ScreenManager.open("EggHatch", { eggId = eggId })
	end
end

--[[
	Sends a hatch and plays its reveal. Refusals show the server's message (and stop auto).
	@return false when another hatch is still running
]]
function HatchFlow.hatch(eggId: string, count: number): boolean
	if busy then
		return false
	end
	local requestId = PetRequests.hatch(eggId, count, auto ~= nil)
	if requestId == nil then
		return false
	end
	setBusy(true)
	local connection: Signal.Connection
	connection = PetRequests.HatchResult:Connect(function(id: number, payload: any)
		if id ~= requestId then
			return
		end
		connection:Disconnect()
		if not payload.ok then
			setBusy(false)
			Hud.notify(
				"error",
				if type(payload.message) == "string" then payload.message else "That egg can't be hatched right now."
			)
			HatchFlow.stopAuto()
			return
		end
		local fast = auto ~= nil
		ScreenManager.close("EggHatch")
		ScreenManager.open("HatchReveal", {
			eggId = payload.egg,
			pets = payload.pets,
			fast = fast,
			auto = fast,
			onStopAuto = if fast
				then function()
					HatchFlow.stopAuto()
				end
				else nil,
			onDone = function()
				afterReveal(eggId)
			end,
		})
	end)
	return true
end

--[[
	Turns auto-hatch on (starts the first hatch) or off.
	Example: HatchFlow.setAuto("garage_egg", 3, true)
]]
function HatchFlow.setAuto(eggId: string, count: number, on: boolean)
	if not on then
		HatchFlow.stopAuto()
		return
	end
	auto = { eggId = eggId, count = count }
	HatchFlow.Changed:Fire()
	if not busy then
		HatchFlow.hatch(eggId, count)
	end
end

--[[ Plays the reveal of a server pet grant (HatchResult id 0, granted = true). ]]
function HatchFlow.playGrant(payload: any)
	if type(payload.pets) ~= "table" or #payload.pets == 0 then
		return
	end
	-- Wait for a running hatch reveal to finish first (never two reveals at once).
	task.spawn(function()
		local waited = 0
		while (busy or ScreenManager.isOpen("HatchReveal")) and waited < 30 do
			waited += task.wait(0.25)
		end
		ScreenManager.open("HatchReveal", { pets = payload.pets, granted = true })
	end)
end

return HatchFlow
