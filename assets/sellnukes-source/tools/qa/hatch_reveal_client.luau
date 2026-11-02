--!nocheck
--[[
	hatch_reveal_client.luau — client-VM probe for the egg hatch cinematic (owner R49,
	UI/Screens/EggHatch/HatchRevealScreen), run by tools/qa/hatch_reveal.py through
	eval_client_runtime during ONE solo playtest.

		COMMAND  "diag"     loading / HUD / top modal / reveal open + the fast / reduced flags
		         "close"    closes every modal (WelcomeBack, EggHatch, the reveal)
		         "real"     hatches ONE held Garage Egg through the real path (HatchFlow.hatch ->
		                    HatchEgg intent -> server roll -> HatchResult -> reveal); ARGS[1] = the
		                    clock second to freeze at (DebugHoldAt, Studio only)
		         "common" / "rare" / "triple" / "mythic"
		                    opens the reveal with fixed rows (presentation of a server result:
		                    pets from the egg's own slots) and freezes the clock mid-crack;
		                    returns the beat times (cracks, bursts, total) as JSON
		         "hold"     moves the freeze to ARGS[1] seconds ("release" clears it)
		         "settings_open"   opens the Settings window (its Fast Hatch row is the R49 addition)
		         "settings_probe"  JSON: Fast Hatch toggle size (points), Selectable + gamepad links,
		                           every visible row inside the window, the window inside the screen
		         "settings_back"   the Back action is bound to ButtonB while Settings is open, and the
		                           Back path (ScreenManager.closeTopModal, what B runs) closes it
	Presentation only: the only intent sent is the normal HatchEgg of "real".
]]

local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ClientState = require(client.ClientState)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local HatchAnim = require(client.Pets.HatchAnim)
local HatchFlow = require(client.UI.Screens.EggHatch.HatchFlow)
local OfferFx = require(client.UI.Widgets.OfferFx)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local ScreenManager = require(client.UI.ScreenManager)

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local function revealGui(): ScreenGui?
	return playerGui:FindFirstChild("HatchReveal")
end

local function setHold(seconds: number?)
	local gui = revealGui()
	if gui ~= nil then
		gui:SetAttribute("DebugHoldAt", seconds)
	end
end

local function fast(): boolean
	local settings = ClientState.profile and ClientState.profile.settings
	return type(settings) == "table" and settings.fastHatch == true
end

-- Rows for an egg: slot index → { petId, rarity, slot } straight from EggConfig.
local function rowFor(eggId: string, slot: number, isNew: boolean, extra: { [string]: any }?)
	local egg = EggConfig.get(eggId)
	local petId = egg.slots[slot].pet
	local def = PetConfig.get(petId)
	local row = { uid = "qa" .. slot, petId = petId, rarity = def.rarity, slot = slot, isNew = isNew }
	for key, value in extra or {} do
		row[key] = value
	end
	return row
end

-- Opens the reveal for `eggId` + rows with the clock frozen at the last egg's 3rd crack.
local function present(eggId: string, rows: { any }): string
	ScreenManager.closeAllModals()
	local ranks = {}
	for index, row in rows do
		ranks[index] = PetConfig.rarity(row.rarity).rank
	end
	local timelines = HatchAnim.schedule(ranks, { fast = fast(), reduced = OfferFx.reducedMotion(), granted = false })
	local last = HatchAnim.revealOrder(ranks)[#ranks]
	local tl = timelines[last]
	local midCrack = (tl.cracks[3] or tl.burst - 0.3) + 0.06
	-- The gui exists from registration (lazy build happens on the first open): set the hold first.
	ScreenManager.open("HatchReveal", { eggId = eggId, pets = rows })
	setHold(midCrack)
	local pets = {}
	for index, row in rows do
		pets[index] = `{row.petId} ({row.rarity})`
	end
	return HttpService:JSONEncode({
		midCrack = midCrack,
		lastBurst = HatchAnim.lastBurst(timelines),
		total = HatchAnim.total(timelines),
		pets = pets,
		fast = fast(),
		reduced = OfferFx.reducedMotion(),
	})
end

if COMMAND == "diag" then
	return HttpService:JSONEncode({
		modal = ScreenManager.topModalName() or "",
		loadingDone = Players.LocalPlayer:GetAttribute("LoadingDone") == true,
		hud = ScreenManager.getGui("Hud") ~= nil and ScreenManager.getGui("Hud").Enabled,
		reveal = ScreenManager.isOpen("HatchReveal"),
		busy = HatchFlow.isBusy(),
		held = ClientState.profile and ClientState.profile.pets and ClientState.profile.pets.eggs,
		fast = fast(),
		reduced = OfferFx.reducedMotion(),
	})
elseif COMMAND == "close" then
	setHold(nil)
	ScreenManager.closeAllModals()
	return tostring(ScreenManager.anyModalOpen())
elseif COMMAND == "real" then
	ScreenManager.closeAllModals()
	local opened = false
	local connection
	connection = ScreenManager.Opened:Connect(function(name)
		if name == "HatchReveal" then
			opened = true
			setHold(ARGS[1])
			connection:Disconnect()
		end
	end)
	local sent = HatchFlow.hatch("garage_egg", 1)
	local waited = 0
	while not opened and waited < 8 do
		waited += task.wait(0.05)
	end
	if not opened then
		connection:Disconnect()
	end
	return HttpService:JSONEncode({ sent = sent, opened = opened })
elseif COMMAND == "common" then
	return present("garage_egg", { rowFor("garage_egg", 1, true) })
elseif COMMAND == "rare" then
	return present("garage_egg", { rowFor("garage_egg", 3, true) })
elseif COMMAND == "mythic" then
	return present("reactor_egg", { rowFor("reactor_egg", 3, true) })
elseif COMMAND == "triple" then
	return present("reactor_egg", {
		rowFor("reactor_egg", 1, false, { equipped = true }),
		rowFor("reactor_egg", 4, true),
		rowFor("reactor_egg", 2, true, { pityForced = true }),
	})
elseif COMMAND == "settings_open" then
	setHold(nil)
	ScreenManager.closeAllModals()
	ScreenManager.open("Settings")
	return tostring(ScreenManager.isOpen("Settings"))
elseif COMMAND == "settings_probe" then
	local gui = playerGui:FindFirstChild("Settings")
	if gui == nil then
		return "{}"
	end
	-- Inside `outer` (absolute rects), with a 1 px tolerance.
	local function inside(inner: GuiObject, outer: GuiObject): boolean
		local a, b = inner.AbsolutePosition, inner.AbsolutePosition + inner.AbsoluteSize
		local c, d = outer.AbsolutePosition, outer.AbsolutePosition + outer.AbsoluteSize
		return a.X >= c.X - 1 and a.Y >= c.Y - 1 and b.X <= d.X + 1 and b.Y <= d.Y + 1
	end
	local holder = gui:FindFirstChild("FitHolder", true)
	local toggle, card = nil, nil
	for _, item in gui:GetDescendants() do
		if item:IsA("TextLabel") and item.Text == "Fast Hatch" and item.Visible then
			-- Walk up to the row card, then find its toggle button.
			local node = item.Parent
			while node ~= nil and node ~= gui do
				local button = node:FindFirstChildWhichIsA("GuiButton", true)
				if button ~= nil then
					toggle, card = button, node
					break
				end
				node = node.Parent
			end
		end
	end
	-- Really shown: the object and every GuiObject ancestor visible (a hidden row's toggle keeps
	-- Visible = true but sits inside an invisible card, e.g. Vibration without a gamepad).
	local function shown(item: GuiObject): boolean
		local node: Instance? = item
		while node ~= nil and node ~= gui do
			if node:IsA("GuiObject") and not node.Visible then
				return false
			end
			node = node.Parent
		end
		return true
	end
	local rowsInside, rowsChecked = true, 0
	if holder ~= nil then
		for _, item in gui:GetDescendants() do
			if item:IsA("GuiButton") and item.Selectable and shown(item) then
				rowsChecked += 1
				if not inside(item, holder) then
					rowsInside = false
				end
			end
		end
	end
	local screen = gui.AbsoluteSize
	return HttpService:JSONEncode({
		screen = { screen.X, screen.Y },
		window = holder and { holder.AbsolutePosition.X, holder.AbsolutePosition.Y, holder.AbsoluteSize.X, holder.AbsoluteSize.Y },
		windowOnScreen = holder ~= nil
			and holder.AbsolutePosition.X >= -1
			and holder.AbsolutePosition.Y >= -1
			and holder.AbsolutePosition.X + holder.AbsoluteSize.X <= screen.X + 1
			and holder.AbsolutePosition.Y + holder.AbsoluteSize.Y <= screen.Y + 1,
		buttonsInsideWindow = rowsInside,
		buttonsChecked = rowsChecked,
		fastHatch = toggle and {
			size = { toggle.AbsoluteSize.X, toggle.AbsoluteSize.Y },
			selectable = toggle.Selectable,
			linkedUp = toggle.NextSelectionUp ~= nil,
			linkedDown = toggle.NextSelectionDown ~= nil,
			insideCard = card ~= nil and inside(toggle, card),
		},
		touch = ScreenManager.touchTargets(),
	})
elseif COMMAND == "settings_back" then
	local info = ContextActionService:GetBoundActionInfo("SellNukesUIBack")
	local boundB = false
	for _, input in (info and info.inputTypes) or {} do
		if input == Enum.KeyCode.ButtonB then
			boundB = true
		end
	end
	local wasOpen = ScreenManager.isOpen("Settings")
	ScreenManager.closeTopModal()
	return HttpService:JSONEncode({ boundB = boundB, wasOpen = wasOpen, closed = not ScreenManager.isOpen("Settings") })
elseif COMMAND == "hold" then
	setHold(ARGS[1])
	return "held"
elseif COMMAND == "release" then
	setHold(nil)
	return "released"
end
return "unknown command"
