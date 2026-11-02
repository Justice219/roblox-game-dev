--!strict
--[[
	shop_item_fx_client.luau — CLIENT half of the R98 Shop item check (plates + idle animation;
	eval_client_runtime, driven by tools/qa/shop_item_fx.py, which fills COMMAND and ARGS with
	whitelisted values only).

	Commands:
		ready    waits (up to ARGS[1] s) until the loading screen + plot reveal are over
		open     ScreenManager.open("Shop") scrolled to section ARGS[1] of ShopConfig.Sections
		         (0 = top)
		probe    every item slot (Screens/Shop/ItemFx: "Slot" holders): its card / tile, plate +
		         glow ring + halo + shadow present, rare (has a Glint), the Float pose now, plus
		         caption name-plates (background, outline thickness, TextFits), InfoPlates, and
		         the OfferFx / ModelViewport counters + reduced motion / graphics tier
		motion   samples ARGS[1] s of frames: per on-screen slot the bob range (px) and pulse range
		         (scale) — proves the items move, and how much
		glints   samples ARGS[1] s: which slots showed their sparkle glint (and the most at once)
		reduce   OfferFx.setReducedMotion(ARGS[1] == 1) (1 = on, 0 = back to the profile's value)
		close    ScreenManager.close("Shop")

	Everything goes through the live client modules (same require cache as the game).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local COMMAND = "__COMMAND__"
local ARGS: { number } = { --[[ARGS]]
}

local player = Players.LocalPlayer
local client = player:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ui = client:WaitForChild("UI")
local ScreenManager = (require :: any)(ui.ScreenManager)
local ModelViewport = (require :: any)(ui.Widgets.ModelViewport)
local OfferFx = (require :: any)(ui.Widgets.OfferFx)
local ClientState = (require :: any)(client.ClientState)
local ShopConfig = (require :: any)(ReplicatedStorage.Shared.Config.ShopConfig)

-- The card / tile a slot belongs to ("Card_VIP", "Pack_SecretPack/Item5").
local function ownerName(node0: Instance): string
	local node: Instance? = node0.Parent
	local tile: string? = nil
	while node ~= nil do
		local name = node.Name
		if string.match(name, "^Item%d+$") and tile == nil then
			tile = name
		elseif string.sub(name, 1, 5) == "Card_" then
			return name
		elseif string.sub(name, 1, 5) == "Pack_" then
			return if tile ~= nil then `{name}/{tile}` else name
		end
		node = node.Parent
	end
	return node0:GetFullName()
end

local function shopGui(): Instance?
	return player.PlayerGui:FindFirstChild("Shop")
end

-- Every ItemFx slot holder in the Shop.
local function slots(): { Frame }
	local list: { Frame } = {}
	local gui = shopGui()
	if gui == nil then
		return list
	end
	for _, item in gui:GetDescendants() do
		if item:IsA("Frame") and item.Name == "Slot" and item:FindFirstChild("Float") ~= nil then
			table.insert(list, item)
		end
	end
	return list
end

-- True when a GuiObject is inside the Shop body's visible band (on screen right now).
local function onScreen(frame: GuiObject): boolean
	local body = frame:FindFirstAncestorWhichIsA("ScrollingFrame")
	if body == nil or not frame.Visible then
		return false
	end
	local top, bottom = body.AbsolutePosition.Y, body.AbsolutePosition.Y + body.AbsoluteSize.Y
	local y0, y1 = frame.AbsolutePosition.Y, frame.AbsolutePosition.Y + frame.AbsoluteSize.Y
	return y1 > top and y0 < bottom
end

local function round(value: number, places: number): number
	local k = 10 ^ places
	return math.floor(value * k + 0.5) / k
end

if COMMAND == "ready" then
	local limit = ARGS[1] or 20
	local reveal = (require :: any)(client.Tycoon.PlotReveal)
	local t0 = os.clock()
	while (player:GetAttribute("LoadingDone") ~= true or reveal.isPlaying()) and os.clock() - t0 < limit do
		task.wait(0.25)
	end
	if player:GetAttribute("LoadingDone") ~= true or reveal.isPlaying() then
		return "waiting"
	end
	task.wait(1.5)
	return "ready"
elseif COMMAND == "open" then
	local index = math.floor(ARGS[1] or 0)
	local section = ShopConfig.Sections[index]
	if not ScreenManager.isOpen("Shop") then
		ScreenManager.closeAllModals()
	end
	ScreenManager.open("Shop", if section ~= nil then { section = section.id, source = "qa" } else { source = "qa" })
	return `opened {if section ~= nil then section.id else "top"}`
elseif COMMAND == "probe" then
	local rows = {}
	for _, slot in slots() do
		local float = slot:FindFirstChild("Float") :: Frame
		local plate = slot:FindFirstChild("Plate")
		local pulse = float:FindFirstChildOfClass("UIScale")
		local glint = float:FindFirstChild("Glint")
		table.insert(rows, {
			owner = ownerName(slot),
			onScreen = onScreen(slot),
			plate = plate ~= nil and plate:FindFirstChild("GlowRing") ~= nil,
			halo = slot:FindFirstChild("Halo") ~= nil,
			shadow = slot:FindFirstChild("Shadow") ~= nil,
			rare = glint ~= nil,
			glintVisible = glint ~= nil and (glint :: GuiObject).Visible,
			y = round(float.Position.Y.Offset, 2),
			scale = if pulse ~= nil then round(pulse.Scale, 4) else nil,
			size = { math.floor(slot.AbsoluteSize.X), math.floor(slot.AbsoluteSize.Y) },
		})
	end
	local captions = {}
	local infoPlates = 0
	local gui = shopGui()
	if gui ~= nil then
		for _, item in gui:GetDescendants() do
			if item:IsA("TextLabel") and (item.Name == "Caption" or item.Name == "Value") and item.Visible then
				local stroke = 0
				for _, child in item:GetChildren() do
					if child:IsA("UIStroke") and child.ApplyStrokeMode == Enum.ApplyStrokeMode.Contextual then
						stroke = child.Thickness
					end
				end
				table.insert(captions, {
					owner = ownerName(item),
					name = item.Name,
					text = item.Text,
					fits = item.TextFits,
					plated = item.BackgroundTransparency < 1 and item:FindFirstChild("PlateCorner") ~= nil,
					stroke = stroke,
					textSize = item.TextSize,
				})
			elseif item:IsA("Frame") and item.Name == "InfoPlate" then
				infoPlates += 1
			end
		end
	end
	local profile = ClientState.profile
	local settings = if type(profile) == "table" then profile.settings else nil
	return HttpService:JSONEncode({
		slots = rows,
		captions = captions,
		infoPlates = infoPlates,
		offerFx = OfferFx.stats(),
		viewport = ModelViewport.stats(),
		tier = OfferFx.tier(),
		reducedMotion = OfferFx.reducedMotion(),
		profileReducedMotion = type(settings) == "table" and settings.reducedMotion == true,
	})
elseif COMMAND == "motion" then
	local seconds = ARGS[1] or 2
	type Range = { owner: string, minY: number, maxY: number, minS: number, maxS: number }
	local tracked: { { float: Frame, pulse: UIScale?, range: Range } } = {}
	for _, slot in slots() do
		if onScreen(slot) then
			local float = slot:FindFirstChild("Float") :: Frame
			table.insert(tracked, {
				float = float,
				pulse = float:FindFirstChildOfClass("UIScale"),
				range = { owner = ownerName(slot), minY = math.huge, maxY = -math.huge, minS = math.huge, maxS = -math.huge },
			})
		end
	end
	local t0 = os.clock()
	local frames = 0
	while os.clock() - t0 < seconds do
		RunService.PreRender:Wait()
		frames += 1
		for _, entry in tracked do
			local y = entry.float.Position.Y.Offset
			local s = if entry.pulse ~= nil then entry.pulse.Scale else 1
			local r = entry.range
			r.minY, r.maxY = math.min(r.minY, y), math.max(r.maxY, y)
			r.minS, r.maxS = math.min(r.minS, s), math.max(r.maxS, s)
		end
	end
	local rows = {}
	local moving = 0
	for _, entry in tracked do
		local r = entry.range
		local bob = r.maxY - r.minY
		if bob > 0.5 then
			moving += 1
		end
		table.insert(rows, { owner = r.owner, bobPx = round(bob, 2), pulse = round(r.maxS - r.minS, 4) })
	end
	return HttpService:JSONEncode({ frames = frames, onScreen = #tracked, moving = moving, slots = rows })
elseif COMMAND == "glints" then
	local seconds = ARGS[1] or 4
	local seen: { [string]: boolean } = {}
	local mostAtOnce = 0
	local rare = {}
	for _, slot in slots() do
		local glint = (slot:FindFirstChild("Float") :: Frame):FindFirstChild("Glint")
		if glint ~= nil and onScreen(slot) then
			table.insert(rare, { owner = ownerName(slot), glint = glint :: GuiObject })
		end
	end
	local t0 = os.clock()
	while os.clock() - t0 < seconds do
		RunService.PreRender:Wait()
		local lit = 0
		for _, entry in rare do
			if entry.glint.Visible then
				lit += 1
				seen[entry.owner] = true
			end
		end
		mostAtOnce = math.max(mostAtOnce, lit)
	end
	local glinted = {}
	for owner in seen do
		table.insert(glinted, owner)
	end
	table.sort(glinted)
	return HttpService:JSONEncode({ rareOnScreen = #rare, glinted = glinted, mostAtOnce = mostAtOnce })
elseif COMMAND == "reduce" then
	local on = (ARGS[1] or 0) == 1
	if on then
		OfferFx.setReducedMotion(true)
	else
		-- Back to what UIController feeds from the profile (never leave QA's value behind).
		local profile = ClientState.profile
		local settings = if type(profile) == "table" then profile.settings else nil
		OfferFx.setReducedMotion(type(settings) == "table" and settings.reducedMotion == true)
	end
	return `reducedMotion {OfferFx.reducedMotion()}`
elseif COMMAND == "close" then
	ScreenManager.close("Shop")
	return "closed"
end
return "ERROR unknown command"
