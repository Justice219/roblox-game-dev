--!strict
--[[
	Interaction — every tycoon input path: tap / click on the 3D producer, keyboard, gamepad and
	B16's on-screen touch buttons (owner rule R11: console + mobile first).

	Paths (all end in server-validated INTENTS through ProducerBillboards / PadBillboards):
		Tap / click the producer   UserInputService.TouchTapInWorld (a tap, never a camera drag)
		                           and left-click: one raycast (Include list = the local player's
		                           own ClickBoxes). When the box carries the server's ClickDetector
		                           the engine already sent the press, so only the bar starts;
		                           otherwise ProducerClick is sent.
		Produce   F / R2 / touch   nearest own MANUAL producer in ProducerRange
		Interact  E / X / touch    nearest own pad in PadRange -> PadBuy, else the nearest extra
		                           interactable (owner R80: a defence BUY pad / own AA tower from
		                           Attack/DefenseWorld → DefenseTower), else upgrade the nearest
		                           own producer by the current x1 / x10 / MAX amount
		Buy       A (gamepad)      the pad you stand on — a tycoon pad, else a defence BUY pad
		                           (out-prioritises jump only while the "Pad" context is on;
		                           Platform/ActionMap owns the binding)
		UpgradeMode Q / Y / touch  cycle x1 -> x10 -> MAX
	Extra interactables (owner R80): Interaction.addProvider(fn) lets another system join these
	paths without this module knowing it — fn(root) returns the nearest thing it offers in its own
	reach ({ distance, context = "Pad" | "Tower", hint, act }) or nil.
	Contexts for B16's hint bar + touch buttons: a provider (polled by Platform/ActionMap at 5 Hz)
	reports Producer / ManualProducer / Pad / Tower around the character and sets the hint texts
	("Buy $1.2K", "Buy 1.2K Bones" for a Dino pad (owner R57: Tycoon/WorldLookup.label, the pad
	id names its world), "Upgrade x10"). Every action is ignored while a menu blocks gameplay
	(InputController / ActionMap handle that).

	Performance: input events only + the 5 Hz provider (two short registry scans). The raycast
	runs once per tap / click against a small Include list rebuilt on producer stream in / out.

	Connects to: Controllers/InputController, Platform/ActionMap (B16, optional: pcall-required),
	Tycoon/{ProducerBillboards, PadBillboards, TycoonWorld, UpgradeMode, WorldLookup},
	Shared/Config/TycoonClientConfig.

	Example: Interaction.start()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local InputController = require(script.Parent.Parent.Controllers.InputController)
local PadBillboards = require(script.Parent.PadBillboards)
local ProducerBillboards = require(script.Parent.ProducerBillboards)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local TycoonWorld = require(script.Parent.TycoonWorld)
local UpgradeMode = require(script.Parent.UpgradeMode)
local WorldLookup = require(script.Parent.WorldLookup)

local Range = TycoonClientConfig.Interact

local Interaction = {}

--[[
	Something another system offers at the character's position (owner R80: Attack/DefenseWorld's
	defence BUY pads and the owner's AA towers).
]]
export type Interactable = {
	distance: number, -- studs from the character root (only offered within the provider's reach)
	context: "Pad" | "Tower", -- the PlatformConfig context it turns on
	hint: string, -- hint bar / touch button text ("Buy $1.2K", "Upgrade $3.4M")
	act: () -> (), -- sends the intent (the server decides)
}
export type Provider = (root: Vector3) -> Interactable?

local providers: { Provider } = {}

-- Longest tap / click raycast (studs).
local RAY_LENGTH = 300

local started = false
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Include
-- Own ClickBox -> its producer anchor (the raycast Include list).
local clickBoxes: { [BasePart]: BasePart } = {}

-- The local character's root position, or nil (dead / not spawned).
local function rootPosition(): Vector3?
	local character = Players.LocalPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root.Position else nil
end

--[[
	Registers an extra interactable provider (owner R80). Providers are polled on input and by the
	5 Hz context provider; they must be cheap and never yield.
	@param provider Provider
	Example: Interaction.addProvider(function(root) return DefenseWorld.nearest(root) end)
]]
function Interaction.addProvider(provider: Provider)
	table.insert(providers, provider)
end

-- The closest extra interactable of every provider (nil when none; a failing provider is skipped).
local function nearestExtra(position: Vector3): Interactable?
	local best: Interactable? = nil
	for _, provider in providers do
		local ok, found = pcall(provider, position)
		if ok and type(found) == "table" and (best == nil or found.distance < best.distance) then
			best = found
		end
	end
	return best
end

-- Buys the nearest own pad in reach; true when one was found.
local function buyNearestPad(position: Vector3): boolean
	local trigger, padId = PadBillboards.nearest(position, Range.PadRange)
	if trigger == nil then
		return false
	end
	PadBillboards.buy(padId)
	return true
end

local function onAction(action: string)
	if action == "UpgradeMode" then
		UpgradeMode.cycle()
		return
	end
	local position = rootPosition()
	if position == nil then
		return
	end
	if action == "Produce" then
		local record = ProducerBillboards.nearestOwn(position, Range.ProducerRange)
		if record ~= nil then
			ProducerBillboards.click(record)
		end
	elseif action == "Buy" then
		if not buyNearestPad(position) then
			local extra = nearestExtra(position)
			if extra ~= nil and extra.context == "Pad" then
				extra.act()
			end
		end
	elseif action == "Interact" then
		if buyNearestPad(position) then
			return
		end
		local extra = nearestExtra(position)
		if extra ~= nil then
			extra.act()
			return
		end
		local record = ProducerBillboards.nearestOwn(position, Range.ProducerRange)
		if record ~= nil then
			ProducerBillboards.upgrade(record)
		end
	end
end

-- Rebuilds the raycast Include list from the own ClickBoxes.
local function refreshRayList()
	local list: { Instance } = {}
	for box in clickBoxes do
		table.insert(list, box)
	end
	raycastParams.FilterDescendantsInstances = list
end

local function onProducerAdded(anchor: BasePart)
	if not TycoonWorld.isMine(anchor) then
		return
	end
	local box = TycoonWorld.clickBox(anchor)
	clickBoxes[box] = anchor
	refreshRayList()
end

local function onProducerRemoved(anchor: BasePart)
	for box, owner in clickBoxes do
		if owner == anchor then
			clickBoxes[box] = nil
		end
	end
	refreshRayList()
end

--[[
	Runs one cycle of the own producer under a screen point (tap / click), if any.
	@param screenPosition point in GUI-inset space (InputObject.Position / TouchTapInWorld)
	@return true when a producer was hit
]]
function Interaction.tapAt(screenPosition: Vector2): boolean
	local camera = Workspace.CurrentCamera
	if camera == nil or next(clickBoxes) == nil or not InputController.isGameplayEnabled() then
		return false
	end
	local ray = camera:ScreenPointToRay(screenPosition.X, screenPosition.Y)
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, raycastParams)
	local box = if hit ~= nil then hit.Instance else nil
	local anchor = if box ~= nil and box:IsA("BasePart") then clickBoxes[box] else nil
	local record = if anchor ~= nil then ProducerBillboards.byAnchor(anchor) else nil
	if record == nil then
		return false
	end
	-- With a server ClickDetector on the box the engine already delivered this press to the
	-- server: only start the bar here (never a second ProducerClick).
	ProducerBillboards.click(record, box ~= nil and box:FindFirstChildOfClass("ClickDetector") == nil)
	return true
end

-- Feeds B16's ActionMap (contexts + hint texts), when that layer is present.
local function hookActionMap()
	local module = script.Parent.Parent:FindFirstChild("Platform")
	local actionMapModule = if module ~= nil then module:FindFirstChild("ActionMap") else nil
	if actionMapModule == nil or not actionMapModule:IsA("ModuleScript") then
		return
	end
	local ok, loaded = pcall(require, actionMapModule)
	if not ok or type(loaded) ~= "table" then
		warn(`[Interaction] Platform/ActionMap unavailable: {loaded}`)
		return
	end
	-- Untyped on purpose (optional layer): every call is guarded by the pcall below.
	local ActionMap: any = loaded
	local hasHints = ActionMap.setHintText ~= nil
	local provider = function(root: Vector3): { [string]: boolean }?
		local record = ProducerBillboards.nearestOwn(root, Range.ProducerRange)
		local pad, padId, cost = PadBillboards.nearest(root, Range.PadRange)
		local extra = if pad == nil then nearestExtra(root) else nil
		if hasHints then
			if pad ~= nil then
				-- The pad's own currency: "Buy $1.2K" (Nuke Town) / "Buy 1.2K Bones" (Dino).
				local price = `Buy {WorldLookup.label(WorldLookup.pad(padId), cost)}`
				ActionMap.setHintText("Interact", price)
				ActionMap.setHintText("Buy", price)
			elseif extra ~= nil then
				ActionMap.setHintText("Interact", extra.hint)
				ActionMap.setHintText("Buy", if extra.context == "Pad" then extra.hint else nil)
			elseif record ~= nil then
				ActionMap.setHintText("Interact", `Upgrade {UpgradeMode.label()}`)
			else
				ActionMap.setHintText("Interact", nil)
			end
		end
		return {
			Producer = record ~= nil,
			ManualProducer = record ~= nil and not record.automated,
			Pad = pad ~= nil or (extra ~= nil and extra.context == "Pad"),
			Tower = extra ~= nil and extra.context == "Tower",
		}
	end
	local hooked, err = pcall(function()
		ActionMap.addContextProvider(provider)
	end)
	if not hooked then
		warn(`[Interaction] ActionMap context provider not installed: {err}`)
	end
end

--[[ Starts listening (once; TycoonClient calls it after the billboards started). ]]
function Interaction.start()
	if started then
		return
	end
	started = true
	InputController.ActionPressed:Connect(onAction)
	TycoonWorld.ProducerAdded:Connect(function(anchor: BasePart)
		onProducerAdded(anchor)
		-- The ClickBox may stream in right after its anchor: register it again next frame.
		task.defer(onProducerAdded, anchor)
	end)
	TycoonWorld.ProducerRemoved:Connect(onProducerRemoved)
	-- Any world's plot changing hands (owner R57: Dino plots too) re-derives the own click boxes.
	TycoonWorld.MyWorldPlotChanged:Connect(function()
		table.clear(clickBoxes)
		for _, anchor in TycoonWorld.producers() do
			onProducerAdded(anchor)
		end
		refreshRayList()
	end)
	for _, anchor in TycoonWorld.producers() do
		onProducerAdded(anchor)
	end
	-- A TAP in the 3D world (never a camera drag) on touch devices.
	UserInputService.TouchTapInWorld:Connect(function(position: Vector2, processedByUI: boolean)
		if not processedByUI then
			Interaction.tapAt(position)
		end
	end)
	-- Left click with a mouse.
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not gameProcessed and input.UserInputType == Enum.UserInputType.MouseButton1 then
			Interaction.tapAt(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)
	hookActionMap()
end

return Interaction
