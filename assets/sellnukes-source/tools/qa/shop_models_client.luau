--!strict
--[[
	shop_models_client.luau — CLIENT half of the Shop 3D-model check (owner R39; eval_client_runtime,
	driven by tools/qa/shop_models.py, which fills COMMAND and ARGS with whitelisted values only).

	Commands:
		ready      waits (up to ARGS[1] s) until the loading screen is done (LocalPlayer attribute
		           LoadingDone), the "Your plot is #N!" swoop (Tycoon/PlotReveal) and the fade are over
		open       ScreenManager.open("Shop") scrolled to section ARGS[1] of ShopConfig.Sections (0 = top)
		wait       polls Widgets/ModelViewport.stats() until no template request is in flight or
		           queued (or ARGS[1] seconds pass) and returns the stats JSON + seconds waited
		slots      every model slot in the Shop: its card / tile and "3d" (model shown) or "icon"
		           (fallback), plus ModelViewport + OfferFx counters (running spins, budget)
		frametime  samples ARGS[1] seconds of frames: mean / p95 / max frame time (ms)
		captions   every pack tile caption: text, TextFits, TextBounds vs AbsoluteSize (readability)
		open_world ScreenManager.open("Shop") on world section ARGS[1] of ShopConfig.WorldSections
		world_cards the cards of world section ARGS[1]: shown, 3D vs icon, button text, Selectable,
		           the gamepad links (NextSelection*), AbsoluteSize (tap size), the preview line
		close      ScreenManager.close("Shop")

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
local ShopConfig = (require :: any)(ReplicatedStorage.Shared.Config.ShopConfig)

-- The card / tile a model slot belongs to ("Card_VIP", "Pack_StarterPack/Item5").
local function ownerName(slot: Instance): string
	local node: Instance? = slot.Parent
	local tile: string? = nil
	while node ~= nil do
		local name = node.Name
		if string.sub(name, 1, 4) == "Item" and tile == nil then
			tile = name
		elseif string.sub(name, 1, 5) == "Card_" then
			return name
		elseif string.sub(name, 1, 5) == "Pack_" then
			return if tile ~= nil then `{name}/{tile}` else name
		end
		node = node.Parent
	end
	return slot:GetFullName()
end

if COMMAND == "ready" then
	-- Short polls (the MCP request times out near 30 s): the driver repeats until "ready".
	local limit = ARGS[1] or 20
	local reveal = (require :: any)(client.Tycoon.PlotReveal)
	local t0 = os.clock()
	while (player:GetAttribute("LoadingDone") ~= true or reveal.isPlaying()) and os.clock() - t0 < limit do
		task.wait(0.25)
	end
	if player:GetAttribute("LoadingDone") ~= true or reveal.isPlaying() then
		return "waiting"
	end
	task.wait(1.5) -- the loading screen's fade-out
	return "ready"
elseif COMMAND == "open" then
	local index = math.floor(ARGS[1] or 0)
	local section = ShopConfig.Sections[index]
	if not ScreenManager.isOpen("Shop") then
		-- Another modal (an attack picker, a daily popup) would hide or close the Shop.
		ScreenManager.closeAllModals()
	end
	ScreenManager.open("Shop", if section ~= nil then { section = section.id, source = "qa" } else { source = "qa" })
	return `opened {if section ~= nil then section.id else "top"}`
elseif COMMAND == "wait" then
	local limit = ARGS[1] or 20
	local t0 = os.clock()
	local quiet = 0
	while os.clock() - t0 < limit do
		local stats = ModelViewport.stats()
		if stats.inFlight == 0 and stats.queued == 0 then
			quiet += 1
			if quiet >= 4 then
				break
			end
		else
			quiet = 0
		end
		task.wait(0.25)
	end
	local stats = ModelViewport.stats()
	stats.waited = math.floor((os.clock() - t0) * 100) / 100
	return HttpService:JSONEncode(stats)
elseif COMMAND == "slots" then
	local gui = player.PlayerGui:FindFirstChild("Shop")
	local slots = {}
	if gui ~= nil then
		for _, item in gui:GetDescendants() do
			if item:IsA("Frame") and item.Name == "Model" and item:GetAttribute("Decorative") == true then
				local viewport = item:FindFirstChild("Viewport")
				local shown = viewport ~= nil and viewport:IsA("ViewportFrame") and viewport.Visible
				slots[ownerName(item)] = if shown then "3d" else "icon"
			end
		end
	end
	return HttpService:JSONEncode({
		slots = slots,
		viewport = ModelViewport.stats(),
		offerFx = OfferFx.stats(),
		reducedMotion = OfferFx.reducedMotion(),
	})
elseif COMMAND == "frametime" then
	local seconds = ARGS[1] or 3
	local samples: { number } = {}
	local t0 = os.clock()
	while os.clock() - t0 < seconds do
		table.insert(samples, RunService.PreRender:Wait())
	end
	table.sort(samples)
	local sum = 0
	for _, dt in samples do
		sum += dt
	end
	local count = math.max(#samples, 1)
	return HttpService:JSONEncode({
		frames = #samples,
		meanMs = math.floor(sum / count * 100000) / 100,
		p95Ms = math.floor((samples[math.max(1, math.ceil(count * 0.95))] or 0) * 100000) / 100,
		maxMs = math.floor((samples[#samples] or 0) * 100000) / 100,
	})
elseif COMMAND == "captions" then
	local gui = player.PlayerGui:FindFirstChild("Shop")
	local rows = {}
	if gui ~= nil then
		for _, item in gui:GetDescendants() do
			if item:IsA("TextLabel") and item.Name == "Caption" then
				table.insert(rows, {
					owner = ownerName(item),
					text = item.Text,
					fits = item.TextFits,
					bounds = { item.TextBounds.X, item.TextBounds.Y },
					size = { item.AbsoluteSize.X, item.AbsoluteSize.Y },
					textSize = item.TextSize,
				})
			end
		end
	end
	return HttpService:JSONEncode(rows)
elseif COMMAND == "open_world" then
	local section = ShopConfig.WorldSections[math.floor(ARGS[1] or 1)]
	if section == nil then
		return "ERROR no such world section"
	end
	if not ScreenManager.isOpen("Shop") then
		ScreenManager.closeAllModals()
	end
	ScreenManager.open("Shop", { section = section.id, source = "qa" })
	return `opened {section.id}`
elseif COMMAND == "world_cards" then
	local section = ShopConfig.WorldSections[math.floor(ARGS[1] or 1)]
	local gui = player.PlayerGui:FindFirstChild("Shop")
	if section == nil or gui == nil then
		return "ERROR no section / shop"
	end
	-- A GuiObject's short path (for the gamepad links).
	local function short(object: Instance?): string?
		if object == nil then
			return nil
		end
		local card = object:FindFirstAncestorWhichIsA("Frame")
		while card ~= nil and string.sub(card.Name, 1, 5) ~= "Card_" do
			card = card:FindFirstAncestorWhichIsA("Frame")
		end
		return if card ~= nil then card.Name else object.Name
	end
	local rows = {}
	for _, item in section.items do
		local card = gui:FindFirstChild(`Card_{item.key}`, true)
		local row: { [string]: any } = { key = item.key, found = card ~= nil }
		if card ~= nil and card:IsA("GuiObject") then
			row.visible = card.Visible and card.AbsoluteSize.X > 0
			local model = card:FindFirstChild("Model", true)
			local viewport = model and model:FindFirstChild("Viewport")
			row.model = if viewport ~= nil and viewport:IsA("ViewportFrame") and viewport.Visible then "3d" else "icon"
			local button = card:FindFirstChild("Buy", true)
			if button ~= nil and button:IsA("GuiObject") then
				row.selectable = button.Selectable
				row.buttonSize = { math.floor(button.AbsoluteSize.X), math.floor(button.AbsoluteSize.Y) }
				row.up = short(button.NextSelectionUp)
				row.down = short(button.NextSelectionDown)
				row.left = short(button.NextSelectionLeft)
				row.right = short(button.NextSelectionRight)
				local label = button:FindFirstChildWhichIsA("TextLabel", true)
				row.buttonText = if label ~= nil then label.Text else nil
			end
			local preview = card:FindFirstChild("Preview", true)
			row.preview = if preview ~= nil and preview:IsA("TextLabel") and preview.Visible then preview.Text else nil
		end
		table.insert(rows, row)
	end
	local selected = game:GetService("GuiService").SelectedObject
	return HttpService:JSONEncode({ cards = rows, selected = short(selected) })
elseif COMMAND == "close" then
	ScreenManager.close("Shop")
	return "closed"
end
return "ERROR unknown command"
