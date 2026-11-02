--!strict
--[[
	PadBillboards — the floating label over each of the local player's buy pads (references 09 /
	11 / 15 / 17): pad name, a one-line blurb ("x3 Workbench cash", "automates Workbench") and
	the price, coloured by pad kind (Build red, Multiplier / Speed yellow, Manager cyan, Unlock
	green, Feature purple) and greyed while the player cannot afford it.

	Buying: stepping on the pad buys it (server Touched). The price is also a button: a tap (touch)
	or the Interact key / X button near the pad (Tycoon/Interaction) sends the PadBuy INTENT; the
	server re-checks distance, order and cash.

	Worlds (owner R57): a pad's world comes from its globally unique id (Tycoon/WorldLookup.pad:
	"d3_wind_sock" is Dino Valley's). The price is written in that world's currency and greyed
	against that world's wallet: Nuke Town "$1.2K" (unchanged), Dino a centred bone icon +
	"1.2K" (Tycoon/CurrencyText). Each world's labels rebuild when the player's plot THERE
	changes (TycoonWorld.MyWorldPlotChanged).

	Performance: event-driven. Labels are built when a pad streams in, re-coloured on wallet
	changes only (ClientState.ProfileChanged with the "cash" / "worldCash" fields), destroyed when
	it streams out; BillboardGui.MaxDistance culls rendering.

	Connects to: Tycoon/{TycoonWorld, TycoonContract, Interaction, WorldLookup, CurrencyText},
	Client/ClientState, Shared/Config/{TycoonClientConfig, UIStyleConfig}, Shared/Net/Remotes.

	Example:
		PadBillboards.start()
		PadBillboards.buy(padId)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ButtonFeedback = require(script.Parent.Parent.UI.ButtonFeedback)
local ClientState = require(script.Parent.Parent.ClientState)
local Contract = require(script.Parent.TycoonContract)
local Create = require(script.Parent.Parent.UI.Create)
local CurrencyText = require(script.Parent.CurrencyText)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local TycoonWorld = require(script.Parent.TycoonWorld)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldLookup = require(script.Parent.WorldLookup)

local Attr = Contract.Attr
local Config = TycoonClientConfig.Pad
local Neutral = UIStyleConfig.Neutral

type Record = {
	trigger: BasePart,
	id: string,
	worldId: string, -- owner R57: the pad's world (its wallet + currency)
	cost: number,
	color: Color3,
	gui: BillboardGui,
	price: TextButton, -- the tap target (its own text in Nuke Town)
	amount: CurrencyText.Handle?, -- icon worlds: the centred [icon] amount inside `price`
	affordable: boolean?,
}

local PadBillboards = {}

local records: { [BasePart]: Record } = {}
local lastBuy = -math.huge
local started = false

-- Seconds between PadBuy intents from this client (the server rate-limits too).
local BUY_DEBOUNCE = 0.3

-- An outlined scaled label.
local function label(
	parent: Instance,
	name: string,
	text: string,
	size: UDim2,
	position: UDim2,
	color: Color3,
	font: Font
): TextLabel
	return Create.new("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		TextScaled = true,
		FontFace = font,
		TextColor3 = color,
		Text = text,
		Size = size,
		Position = position,
		Parent = parent,
		Children = {
			Create.new("UIStroke", {
				Color = Neutral.TextStroke,
				Thickness = 2,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
				LineJoinMode = Enum.LineJoinMode.Round,
			}),
		},
	}) :: TextLabel
end

-- The accent colour of a pad kind (TycoonClientConfig.PadKindColor -> UIStyleConfig preset).
local function kindColor(kind: string): Color3
	local name = TycoonClientConfig.PadKindColor[kind] or "green"
	local preset = (UIStyleConfig.Colors :: any)[name]
	return if preset ~= nil then preset.accent else Neutral.CashGreen
end

-- Re-colours one pad price for the player's balance in the pad's world (Cash / Bones).
local function paint(record: Record)
	local affordable = WorldLookup.wallet(record.worldId) >= record.cost
	if affordable == record.affordable then
		return
	end
	record.affordable = affordable
	local color = if affordable then record.color else Neutral.Placeholder
	local amount = record.amount
	if amount ~= nil then
		CurrencyText.setColor(amount, color)
	else
		record.price.TextColor3 = color
	end
end

--[[
	Sends the PadBuy intent for an own pad (debounced; the server decides).
	@param padId the pad's id
	@return true when sent
]]
function PadBillboards.buy(padId: string): boolean
	local now = os.clock()
	if padId == "" or now - lastBuy < BUY_DEBOUNCE then
		return false
	end
	lastBuy = now
	-- Press feedback (owner R22): coins + "purchase", or the locked sound when unaffordable.
	for _, record in records do
		if record.id == padId then
			record.price:SetAttribute("FeedbackLocked", record.affordable ~= true)
			ButtonFeedback.fire(record.price)
			break
		end
	end
	task.spawn(function()
		Remotes.event("PadBuy"):FireServer(padId)
	end)
	return true
end

local function add(trigger: BasePart)
	if records[trigger] ~= nil or not TycoonWorld.isMine(trigger) then
		return
	end
	local id = TycoonWorld.padId(trigger)
	if id == "" then
		return
	end
	local cost = Contract.num(TycoonWorld.padAttr(trigger, Attr.Cost), 0)
	-- The pad's world: its unique id names it (plot's world as the fallback for an unknown id).
	local idWorld = WorldLookup.pad(id)
	local worldId = idWorld or TycoonWorld.worldOf(trigger)
	local withIcon = WorldLookup.usesIcon(worldId)
	local priceText = WorldLookup.format(worldId, cost)
	local color = kindColor(Contract.str(TycoonWorld.padAttr(trigger, Attr.Kind), ""))
	-- Phones, tablets and ten-foot consoles get larger labels (readability, tap targets).
	local grow = if ScreenManager.device.class == "Desktop" then 1 else TycoonClientConfig.Billboard.DeviceScale
	local gui = Create.new("BillboardGui", {
		Name = `PadBillboard_{id}`,
		Adornee = trigger,
		Size = UDim2.fromScale(Config.SizeStuds.X * grow, Config.SizeStuds.Y * grow),
		StudsOffsetWorldSpace = Config.OffsetStuds,
		MaxDistance = Config.MaxDistance,
		LightInfluence = 0,
		ResetOnSpawn = false,
		Active = true,
		-- R84: the tutorial's highlight ring around the price button may reach past the label.
		ClipsDescendants = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}) :: BillboardGui
	label(
		gui,
		"Name",
		Contract.str(TycoonWorld.padAttr(trigger, Attr.Name), id),
		UDim2.fromScale(1, 0.3),
		UDim2.fromScale(0, 0),
		Neutral.Text,
		UIStyleConfig.Fonts.Number
	)
	local blurb = label(
		gui,
		"Blurb",
		Contract.str(TycoonWorld.padAttr(trigger, Attr.Blurb), ""),
		UDim2.fromScale(1, 0.2),
		UDim2.fromScale(0, 0.29),
		Neutral.TextDim,
		Font.fromEnum(Enum.Font.FredokaOne)
	)
	blurb.FontFace = Font.new(blurb.FontFace.Family, Enum.FontWeight.Regular, Enum.FontStyle.Italic)
	local price = Create.new("TextButton", {
		Name = "Price",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		TextScaled = true,
		FontFace = UIStyleConfig.Fonts.Number,
		TextColor3 = color,
		-- Icon worlds draw the amount through CurrencyText (centred [icon][text]) instead.
		Text = if withIcon then "" else priceText,
		Size = UDim2.fromScale(1, 0.46),
		Position = UDim2.fromScale(0, 0.52),
		Parent = gui,
		Children = {
			Create.new("UIStroke", {
				Color = Neutral.TextStroke,
				Thickness = 3,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
				LineJoinMode = Enum.LineJoinMode.Round,
			}),
		},
	}) :: TextButton
	price:SetAttribute("FeedbackManual", true)
	price:SetAttribute("FeedbackKind", "Coins")
	price:SetAttribute("FeedbackSound", "purchase")
	price:SetAttribute(
		"FeedbackColor",
		TycoonClientConfig.PadKindColor[Contract.str(TycoonWorld.padAttr(trigger, Attr.Kind), "")] or "green"
	)
	price.Activated:Connect(function()
		PadBillboards.buy(id)
	end)
	local amount: CurrencyText.Handle? = nil
	if withIcon then
		-- Holder = the price row: SizeStuds.X wide, 0.46 x SizeStuds.Y tall (device growth is uniform).
		local handle = CurrencyText.new(price, {
			aspect = Config.SizeStuds.X / (Config.SizeStuds.Y * 0.46),
			font = UIStyleConfig.Fonts.Number,
			color = color,
			stroke = 3,
			strokeColor = Neutral.TextStroke,
		})
		CurrencyText.set(handle, priceText, WorldLookup.currencyOf(worldId).icon)
		amount = handle
	end
	gui.Parent = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	-- Bought: the server stamps PressedAt and destroys the pad 0.6 s later; hide the label now.
	local model = TycoonWorld.padModel(trigger)
	if model ~= nil then
		local pressed = model:GetAttributeChangedSignal(Attr.PressedAt):Connect(function()
			gui.Enabled = false
		end)
		gui.Destroying:Once(function()
			pressed:Disconnect()
		end)
	end
	local record: Record = {
		trigger = trigger,
		id = id,
		worldId = worldId,
		cost = cost,
		color = color,
		gui = gui,
		price = price,
		amount = amount,
	}
	records[trigger] = record
	paint(record)
end

local function remove(trigger: BasePart)
	local record = records[trigger]
	if record ~= nil then
		records[trigger] = nil
		record.gui:Destroy()
	end
end

--[[
	The nearest own pad trigger within `range` studs of `position`, with its id and cost, or nil.
	Example: local trigger, padId, cost = PadBillboards.nearest(root.Position, 9)
]]
function PadBillboards.nearest(position: Vector3, range: number): (BasePart?, string, number)
	local best: Record? = nil
	local bestDistance = range
	for trigger, record in records do
		local distance = (trigger.Position - position).Magnitude
		if distance <= bestDistance then
			best, bestDistance = record, distance
		end
	end
	return if best ~= nil then best.trigger else nil,
		if best ~= nil then best.id else "",
		if best ~= nil then best.cost else 0
end

--[[
	The price button of the local player's pad `padId` while its label exists, else nil (owner
	R84: the tutorial rings the pad's buy button on pad steps). Read-only use: callers may parent
	a decoration under it (destroyed with the label) but must not change it.
	Example: local price = PadBillboards.priceButton("a1_workbench")
]]
function PadBillboards.priceButton(padId: string): GuiObject?
	for _, record in records do
		if record.id == padId and record.gui.Parent ~= nil then
			return record.price
		end
	end
	return nil
end

--[[ Starts the pad billboards (once; TycoonClient calls it after TycoonWorld.start). ]]
function PadBillboards.start()
	if started then
		return
	end
	started = true
	TycoonWorld.PadAdded:Connect(add)
	TycoonWorld.PadRemoved:Connect(remove)
	for _, trigger in TycoonWorld.pads() do
		add(trigger)
	end
	-- The player's plot in one world changed: rebuild that world's labels (others untouched).
	TycoonWorld.MyWorldPlotChanged:Connect(function(worldId: string)
		for trigger, record in records do
			if record.worldId == worldId then
				remove(trigger)
			end
		end
		for _, trigger in TycoonWorld.pads() do
			add(trigger) -- skips pads already labelled and pads that are not mine
		end
	end)
	-- Nuke Town Cash rides the "cash" field, every other world's balance "worldCash".
	ClientState.ProfileChanged:Connect(function(_profile, fields)
		if fields == nil or table.find(fields, "cash") ~= nil or table.find(fields, "worldCash") ~= nil then
			for _, record in records do
				paint(record)
			end
		end
	end)
end

return PadBillboards
