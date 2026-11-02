--!strict
--[[
	PurchaseGuard — the client runtime of the owner R122 purchase-focus hygiene (spec §2.4: "no
	accidental purchase prompts"). Field data (2026-10-31 / 11-01): 0 purchases from ~190 Robux
	prompts, most closed in under 2 s — the Shop opened on console with the gamepad cursor already
	on the Starter Pack BUY button, and one press could both open a screen and buy inside it.

	Three tools every prompt source uses:
		1. The opening-press guard. PurchaseGuard.allow(surface) / gate(surface, fn) let a Robux BUY
		   through only when the press that caused it BEGAN after the surface opened (+ a few
		   frames) and the surface has been up PurchaseFocusConfig.Guard.ArmSeconds. A tap, click,
		   gamepad A or Enter that OPENED a screen / card can never also buy something in it (incl.
		   the engine activating a newly selected button when A is released). Rules:
		   PurchaseGuardLogic.allows (pure, Lune-tested).
		   Surfaces: every ScreenManager screen is tracked automatically (Opened); cards that are
		   re-shown while already open call PurchaseGuard.opened(surface) themselves.
		   Presses: ONE UserInputService.InputBegan connection records the begin time of every
		   activating input (MouseButton1, Touch, gamepad A, Return / KeypadEnter). A
		   ContextActionService-bound BUY (the DEAL card's X / E) passes its own press time.
		2. Safe default selection. markBuy(button) tags Robux BUY buttons; safeDefault(list) returns
		   the first usable candidate that is NOT one, so no screen opens with GuiService
		   selection on a BUY button (PurchaseGuardLogic.pickDefault).
		3. Landings. landing(object) makes a non-buy GuiObject (e.g. a Shop section heading) a
		   gamepad stop with the white selection ring: the cursor's starting point on a screen whose
		   other controls are all BUY buttons. Pressing A on it does nothing.

	Security: presentation only. The server still validates every prompt (MonetizationService);
	this only stops the CLIENT from asking for a prompt the player did not mean.

	Performance: one InputBegan connection (a table write per press), one ScreenManager.Opened
	connection; allow() is a few comparisons. No per-frame work. Surface times are capped
	(Guard.MaxSurfaces, oldest dropped).

	Connects to: UI/{PurchaseGuardLogic, ScreenManager, Create}, Shared/Config/PurchaseFocusConfig,
	Controllers/InputController (gamepad mode for select), every prompt-source screen (Shop, Lucky
	Wheel, egg hatch, Teleport, attack / defense screens, Event / Crate shops, Nuke Pass, Welcome
	Back), UI/Screens/DealCard, UI/Hud/HudOffers.

	Example:
		local buy = StudUI.button({ text = "", productKey = "VIP", onActivated = PurchaseGuard.gate("Shop", function()
			Remotes.event("PromptPass"):FireServer("VIP", "shop")
		end) })
		PurchaseGuard.markBuy(buy.instance)
		defaultSelection = function() return PurchaseGuard.safeDefault({ preferred, heading }) end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Create = require(script.Parent.Create)
local PurchaseFocusConfig = require(ReplicatedStorage.Shared.Config.PurchaseFocusConfig)
local PurchaseGuardLogic = require(script.Parent.PurchaseGuardLogic)
local ScreenManager = require(script.Parent.ScreenManager)

local Guard = PurchaseFocusConfig.Guard
local BUY_ATTRIBUTE = PurchaseFocusConfig.BuyAttribute
local LANDING_ATTRIBUTE = PurchaseFocusConfig.LandingAttribute
local Ring = PurchaseFocusConfig.LandingRing

local PurchaseGuard = {}

-- Inputs that can activate a GuiButton (their InputBegan time is "the press").
local ACTIVATING_TYPES: { [Enum.UserInputType]: boolean } = {
	[Enum.UserInputType.MouseButton1] = true,
	[Enum.UserInputType.Touch] = true,
}
local ACTIVATING_KEYS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.ButtonA] = true,
	[Enum.KeyCode.Return] = true,
	[Enum.KeyCode.KeypadEnter] = true,
}

-- Newest begin time (os.clock) per activating input name.
local pressTimes: { [string]: number } = {}
-- Surface name → when it last opened (os.clock), + insertion order for the MaxSurfaces cap.
local openedAt: { [string]: number } = {}
local openOrder: { string } = {}
local started = false
-- Session counters (QA / support: PurchaseGuard.stats()).
local counters: { [string]: number } = { allowed = 0, arming = 0, openingPress = 0, noPress = 0, opened = 0 }

-- Records one surface open (newest last in openOrder; the oldest is forgotten past the cap).
local function record(surface: string)
	if openedAt[surface] ~= nil then
		local index = table.find(openOrder, surface)
		if index ~= nil then
			table.remove(openOrder, index)
		end
	end
	openedAt[surface] = os.clock()
	table.insert(openOrder, surface)
	while #openOrder > Guard.MaxSurfaces do
		local oldest = table.remove(openOrder, 1)
		if oldest ~= nil then
			openedAt[oldest] = nil
		end
	end
	counters.opened += 1
end

--[[
	Starts the press listener + the screen-open tracking (idempotent; every API calls it, so the
	guard is live from the first screen that requires it — before any purchase screen exists).
]]
function PurchaseGuard.start()
	if started then
		return
	end
	started = true
	UserInputService.InputBegan:Connect(function(input: InputObject)
		local inputType = input.UserInputType
		if ACTIVATING_TYPES[inputType] then
			pressTimes[inputType.Name] = os.clock()
		elseif ACTIVATING_KEYS[input.KeyCode] then
			pressTimes[input.KeyCode.Name] = os.clock()
		end
	end)
	ScreenManager.Opened:Connect(record)
end

--[[
	Marks `surface` as opened NOW (a card re-shown while its screen stays open, a popover). Screen
	opens through ScreenManager are recorded automatically.
	Example: PurchaseGuard.opened("DealCard")
]]
function PurchaseGuard.opened(surface: string)
	PurchaseGuard.start()
	record(surface)
end

--[[
	May a Robux BUY on `surface` go through right now? Refusals are silent (the button just does
	nothing for that press); the next deliberate press works.
	@param surface the screen name / card id the BUY belongs to
	@param pressAt the press begin time (os.clock) when the caller knows it (a ContextActionService
	               Begin: pass os.clock()); nil = the newest activating press seen
	@return true = send the prompt intent
	Example: if PurchaseGuard.allow("Teleport") then Remotes.event("PromptPass"):FireServer(...) end
]]
function PurchaseGuard.allow(surface: string, pressAt: number?): boolean
	PurchaseGuard.start()
	local press = pressAt or PurchaseGuardLogic.latestPress(pressTimes)
	local ok, refusal = PurchaseGuardLogic.allows(openedAt[surface], press, os.clock())
	if ok then
		counters.allowed += 1
	elseif refusal ~= nil then
		counters[refusal] += 1
	end
	return ok
end

--[[
	Wraps a BUY callback with allow(surface): the returned function runs `callback` only when the
	guard allows it (drop-in for StudUI `onActivated`).
	Example: onActivated = PurchaseGuard.gate("Shop", function() promptPass("VIP") end)
]]
function PurchaseGuard.gate(surface: string, callback: () -> ()): () -> ()
	return function()
		if PurchaseGuard.allow(surface) then
			callback()
		end
	end
end

--[[
	Tags `button` as a Robux BUY button (never a default selection; PurchaseGuard.isBuy).
	Example: PurchaseGuard.markBuy(buy.instance)
]]
function PurchaseGuard.markBuy(button: GuiObject)
	button:SetAttribute(BUY_ATTRIBUTE, true)
end

--[[
	Tags (on = true) or untags (false) `button` as a Robux BUY button — for a button whose role
	changes with state (a free HATCH that becomes a Robux TRIPLE HATCH, a locked premium cell).
	Example: PurchaseGuard.setBuy(hatchThree.instance, not ownsTriple)
]]
function PurchaseGuard.setBuy(button: GuiObject, on: boolean)
	button:SetAttribute(BUY_ATTRIBUTE, if on then true else nil)
end

--[[ True for a GuiObject tagged by markBuy. ]]
function PurchaseGuard.isBuy(object: GuiObject): boolean
	return object:GetAttribute(BUY_ATTRIBUTE) == true
end

-- True when `object` can take the gamepad selection now (selectable, parented, whole chain shown).
local function usable(object: GuiObject): boolean
	if not object.Selectable or not object.Visible or object.Parent == nil then
		return false
	end
	local ancestor = object.Parent
	while ancestor ~= nil and not ancestor:IsA("LayerCollector") do
		if ancestor:IsA("GuiObject") and not ancestor.Visible then
			return false
		end
		ancestor = ancestor.Parent
	end
	return ancestor ~= nil
end

--[[
	The first usable candidate that is not a Robux BUY button (see PurchaseGuardLogic.pickDefault).
	@param candidates ordered preferences (nil entries skipped)
	@return the pick or nil
	Example: defaultSelection = function() return PurchaseGuard.safeDefault({ okay, tabs[1] }) end
]]
function PurchaseGuard.safeDefault(candidates: { [number]: GuiObject? }): GuiObject?
	return PurchaseGuardLogic.pickDefault(candidates, PurchaseGuard.isBuy, usable)
end

--[[
	Makes `object` a gamepad landing: Selectable, an invisible engine selection image and a white
	ring that shows while it holds the cursor. A press on it does nothing. Idempotent.
	@param gui the GuiObject (a heading / info card) — never a BUY button
	@return the same GuiObject
	Example: PurchaseGuard.landing(sectionLabel).NextSelectionDown = firstBuyButton
]]
function PurchaseGuard.landing(gui: GuiObject): GuiObject
	if gui:GetAttribute(LANDING_ATTRIBUTE) == true then
		return gui
	end
	gui:SetAttribute(LANDING_ATTRIBUTE, true)
	gui.Selectable = true
	gui.SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }) :: Frame
	local ring = Create.new("Frame", {
		Name = "LandingRing",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, Ring.Pad * 2, 1, Ring.Pad * 2),
		Active = false,
		Visible = false,
		ZIndex = gui.ZIndex + 1,
		Parent = gui,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0, Ring.Corner) }),
			Create.new("UIStroke", {
				Color = Color3.new(1, 1, 1),
				Thickness = Ring.Thickness,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}),
		},
	}) :: Frame
	gui.SelectionGained:Connect(function()
		ring.Visible = true
	end)
	gui.SelectionLost:Connect(function()
		ring.Visible = false
	end)
	return gui
end

--[[ A copy of this session's counters (QA): allowed, arming, openingPress, noPress, opened. ]]
function PurchaseGuard.stats(): { [string]: number }
	return table.clone(counters)
end

return PurchaseGuard
