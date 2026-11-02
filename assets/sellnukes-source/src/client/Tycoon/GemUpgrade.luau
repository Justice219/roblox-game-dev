--!strict
--[[
	GemUpgrade — the client side of the owner R86 gem upgrade ("add a button on like the GUI to also
	just buy for gems, like just buy the next upgrade with gems, but it stays at the same price for
	everything").

	Purpose:
		- Paints every own producer billboard's gem button through ProducerBillboards.paintGem:
		  "[gem] 75" purple (can buy), "SURE?" yellow (armed), "NEED 75" grey (short of gems),
		  hidden at MaxLevel / while the admin switch is off / before the producer is built
		  (Shared/Tycoon/GemUpgradeRules, the same rules the server applies).
		- Runs the kid-friendly confirm (Tycoon/GemConfirmLogic): the first press arms ("SURE?"),
		  a second press within 3 s buys; presses within 6 s of the last gem buy go straight
		  through. An unaffordable press plays the locked sound and changes nothing.
		- Sends the INTENT only: ProducerGemUpgrade(producerId). The server decides everything
		  (live price, gems, level, switch; Server/Tycoon/TycoonService.onProducerGemUpgrade).
		- Input on every device (owner R11): the billboard button (touch / mouse), the GemUpgrade
		  action (C on a keyboard, LB on a gamepad, the GEMS touch button) on the nearest own
		  producer in reach. A context provider turns the "GemUpgrade" context on while that
		  producer can take a gem level and sets the hint / touch caption ("Gem upgrade (75)",
		  "Sure? 75 gems", "Need 75 gems").
		The live price / switch come from the server's ReplicatedStorage attributes
		(TycoonConfig.GemUpgrade.PriceAttribute / EnabledAttribute, sanitised by GemUpgradeRules).

	Performance: event-driven. Repaints on profile changes (gems / levels), on the price / switch
	attributes and when a board streams in; one deferred repaint when an arm expires; the context
	provider is ActionMap's shared 5 Hz poll (one nearest-producer scan). Nothing per frame.

	Connects to: Tycoon/{ProducerBillboards (paintGem, GemPressed, nearestOwn, level, ownRecords),
	GemConfirmLogic, WorldLookup}, Platform/ActionMap, Controllers/InputController, UI/ButtonFeedback,
	Client/ClientState, Shared/Tycoon/GemUpgradeRules, Shared/Net/Remotes,
	Shared/Config/{TycoonConfig, TycoonClientConfig}.

	Example:
		GemUpgrade.start()
		GemUpgrade.press(ProducerBillboards.byId("p1_workbench")) --> "arm", then "buy"
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ActionMap = require(script.Parent.Parent.Platform.ActionMap)
local ButtonFeedback = require(script.Parent.Parent.UI.ButtonFeedback)
local ClientState = require(script.Parent.Parent.ClientState)
local GemConfirmLogic = require(script.Parent.GemConfirmLogic)
local GemUpgradeRules = require(ReplicatedStorage.Shared.Tycoon.GemUpgradeRules)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local ProducerBillboards = require(script.Parent.ProducerBillboards)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local WorldLookup = require(script.Parent.WorldLookup)

type Record = ProducerBillboards.Record

local Gem = TycoonConfig.GemUpgrade
local Range = TycoonClientConfig.Interact

local GemUpgrade = {}

-- The confirm state machine (one per client: arming is per producer, the repeat window global).
local confirm = GemConfirmLogic.new()
local started = false
-- Bumped on every arm so only the newest arm's expiry repaints.
local disarmToken = 0

-- This server's live flat price (sanitised attribute; the config default until published).
local function price(): number
	return GemUpgradeRules.price(ReplicatedStorage:GetAttribute(Gem.PriceAttribute))
end

-- The live admin switch.
local function enabled(): boolean
	return GemUpgradeRules.enabled(ReplicatedStorage:GetAttribute(Gem.EnabledAttribute))
end

-- The player's gems from the server-synced profile (0 before the first snapshot).
local function gems(): number
	local profile = ClientState.profile
	local value = if profile ~= nil then profile.gems else nil
	return if type(value) == "number" and value == value then value else 0
end

-- The shared rules for one record right now.
local function check(record: Record): (boolean, GemUpgradeRules.Reason)
	return GemUpgradeRules.check({
		enabled = enabled(),
		level = ProducerBillboards.level(record),
		maxLevel = WorldLookup.def(record.worldId).economy.MaxLevel,
		gems = gems(),
		price = price(),
	})
end

-- True while `record`'s button is armed.
local function armed(record: Record): boolean
	return GemConfirmLogic.isArmed(confirm, record.id, os.clock(), Gem.ConfirmSeconds)
end

-- Paints one board's gem button (see the module header).
local function paint(record: Record)
	local _, reason = check(record)
	local cost = price()
	if reason ~= "ok" and reason ~= "gems" then
		ProducerBillboards.paintGem(record, false, "", "purple")
	elseif reason == "gems" then
		ProducerBillboards.paintGem(record, true, `NEED {cost}`, "grey")
	elseif armed(record) then
		ProducerBillboards.paintGem(record, true, "SURE?", "yellow")
	else
		ProducerBillboards.paintGem(record, true, tostring(cost), "purple")
	end
end

-- Repaints every own board.
local function paintAll()
	for _, record in ProducerBillboards.ownRecords() do
		paint(record)
	end
end

-- The hint / touch caption for the producer in reach (nil = no hint: it cannot take a level).
local function hintFor(record: Record): string?
	local ok, reason = check(record)
	local cost = price()
	if reason == "gems" then
		return `Need {cost} gems`
	elseif not ok then
		return nil
	elseif armed(record) then
		return `Sure? {cost} gems`
	end
	return `Gem upgrade ({cost})`
end

-- The local character's root position, or nil.
local function rootPosition(): Vector3?
	local character = Players.LocalPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root.Position else nil
end

-- Sets the press feedback flavour on the button before ButtonFeedback.fire reads it.
local function feedback(record: Record, kind: "arm" | "buy" | "locked")
	local button = record.gem
	button:SetAttribute("FeedbackLocked", kind == "locked")
	button:SetAttribute("FeedbackKind", if kind == "buy" then "Coins" else "Stars")
	button:SetAttribute("FeedbackSound", if kind == "buy" then "upgrade" else nil)
	button:SetAttribute("FeedbackBig", kind == "buy")
	ButtonFeedback.fire(button)
end

--[[
	One press of `record`'s gem upgrade (billboard button, C / LB, the GEMS touch button).
	@return "locked" (cannot buy: nothing changes), "arm" (shows SURE?) or "buy" (intent sent)
]]
function GemUpgrade.press(record: Record): string
	if not record.mine then
		return "locked"
	end
	local ok = check(record)
	if not ok then
		feedback(record, "locked")
		return "locked"
	end
	local action = GemConfirmLogic.press(confirm, record.id, os.clock(), Gem.ConfirmSeconds, Gem.RepeatSeconds)
	if action == "arm" then
		feedback(record, "arm")
		paintAll() -- a previous arm on another board clears
		disarmToken += 1
		local token = disarmToken
		task.delay(Gem.ConfirmSeconds + 0.05, function()
			if token == disarmToken then
				paintAll()
			end
		end)
	else
		feedback(record, "buy")
		local pop = record.gem:FindFirstChild("Pop")
		if pop ~= nil and pop:IsA("UIScale") then
			pop.Scale = 0.88
			TweenService:Create(pop, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
				:Play()
		end
		local producerId = record.id
		task.spawn(function()
			Remotes.event("ProducerGemUpgrade"):FireServer(producerId)
		end)
		paint(record)
	end
	ActionMap.setHintText("GemUpgrade", hintFor(record))
	return action
end

--[[ Starts the gem upgrade client (once; TycoonClient calls it after the billboards). ]]
function GemUpgrade.start()
	if started then
		return
	end
	started = true
	ProducerBillboards.GemPressed:Connect(function(record: Record)
		GemUpgrade.press(record)
	end)
	-- C / LB / the GEMS touch button: the nearest own producer in reach.
	InputController.ActionPressed:Connect(function(action: string)
		if action ~= "GemUpgrade" then
			return
		end
		local position = rootPosition()
		local record = if position ~= nil then ProducerBillboards.nearestOwn(position, Range.ProducerRange) else nil
		if record ~= nil then
			GemUpgrade.press(record)
		end
	end)
	-- The "GemUpgrade" context + hint for the producer in reach (ActionMap's shared 5 Hz poll).
	ActionMap.addContextProvider(function(root: Vector3): { [string]: boolean }?
		local record = ProducerBillboards.nearestOwn(root, Range.ProducerRange)
		local hint = if record ~= nil then hintFor(record) else nil
		ActionMap.setHintText("GemUpgrade", hint)
		return { GemUpgrade = hint ~= nil }
	end)
	-- Repaint on what changes the look: gems / levels, the live price / switch, a new board.
	ClientState.ProfileChanged:Connect(function(_profile, fields)
		if
			fields == nil
			or table.find(fields, "gems") ~= nil
			or table.find(fields, "tycoon") ~= nil
			or table.find(fields, "worlds") ~= nil
		then
			paintAll()
		end
	end)
	ReplicatedStorage:GetAttributeChangedSignal(Gem.PriceAttribute):Connect(paintAll)
	ReplicatedStorage:GetAttributeChangedSignal(Gem.EnabledAttribute):Connect(paintAll)
	ProducerBillboards.Changed:Connect(function()
		paintAll()
	end)
	paintAll()
end

return GemUpgrade
