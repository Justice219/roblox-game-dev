--!strict
--[[
	PetsScreen ("Pets", the HUD Pets button) — the pet inventory, held eggs, the Pet Index and
	trails, in one stud window with four tabs:

		PETS    paged grid (5 × 3) of owned pets, equipped first then best first; the side panel
		        shows the selected pet spinning with its rarity and cash bonus and EQUIP / UNEQUIP,
		        LOCK / UNLOCK, DELETE (press twice). EQUIP BEST fills every slot with the best pets.
		        DELETE MODE: tap pets to pick them (locked pets can't be picked), then DELETE (n).
		        Header: pets owned / backpack cap, equipped / slots, total cash bonus.
		EGGS    held eggs (Lucky Wheel, crates, admin) — HATCH opens the EggHatch window, where
		        held eggs hatch for free anywhere.
		INDEX   every pet in the game: discovered ones in colour, the rest as "?"; the side panel
		        says how to get it. Completion count "Discovered n / Total" (Total = the
		        non-exclusive pets, PetIndexConfig). Owner R78: the side card also carries the
		        Index REWARDS panel (IndexRewards: milestone pips, progress bar, next reward, CLAIM
		        with juice) and the INDEX tab wears a red "!" while a milestone is ready.
		        Deep link: ScreenManager.open("Pets", { tab = "index", select = "golden_nukey" })
		        opens the Index on that pet's page with its side panel shown.
		TRAILS  the cosmetic trails: equip / unequip owned ones; locked ones come from crates.
		+ FLAVOURS (owner R89): not a tab — a rainbow button after the tabs that hands off to the
		        Flavour Book (Screens/FlavorBook, EntryButton) and wears a red "!" while a flavour
		        discovery reward is ready. LB / RB still cycle only the four tabs.

	Every action is an INTENT (EquipPet, EquipBest, DeletePets, LockPets, EquipTrail); the screen
	re-renders from the server's profile push (ClientState.ProfileChanged) — it never edits its
	own copy of the data. Paging (◀ ▶) keeps at most 15 viewports alive.

	Console + mobile (owner R11): cards are linked as a grid (B16 GamepadNav.linkGrid, exits to the
	tab bar / pager / side panel), LB / RB (Q / E) cycle the tabs, X / Y on a selected pet card
	equip / lock it (glyph hints in the side panel in gamepad mode), A opens it, B leaves delete
	mode or closes; the gamepad starts on the first card (on INDEX with a ready milestone: CLAIM;
	the grid's right exit is CLAIM there, its left exit the grid). Every tap target is ≥ 72 design px
	(≥ 44 pt at the phone scale). Window scales via ModalShell.

	Connects to: UI/Screens/Pets/{PetCard, IndexRewards}, Client/Pets/PetViewport, Client/ClientState,
	Shared/Config/{PetConfig, PetIndexConfig, EggConfig, CrateConfig}, Shared/Net/Remotes, UI/Kit/StudUI,
	UI/ScreenManager (opens EggHatch).
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Parent.Create)
local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
-- Owner R89: the FLAVOURS button (the Flavour Book's HUD route; no new left-stack button).
local FlavorBookEntry = require(script.Parent.Parent.FlavorBook.EntryButton)
local GamepadNav = require(script.Parent.Parent.Parent.Parent.Platform.GamepadNav)
local InputController = require(script.Parent.Parent.Parent.Parent.Controllers.InputController)
local IndexRewards = require(script.Parent.IndexRewards)
local InputGlyph = require(script.Parent.Parent.Parent.Widgets.InputGlyph)
local PetCard = require(script.Parent.PetCard)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetIndexConfig = require(ReplicatedStorage.Shared.Config.PetIndexConfig)
local PetUI = require(script.Parent.Parent.Parent.Parent.Pets.PetUI)
local PetViewport = require(script.Parent.Parent.Parent.Parent.Pets.PetViewport)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Neutral = UIStyleConfig.Neutral

type Tab = "pets" | "eggs" | "index" | "trails"

-- One grid entry (what a card shows + what selecting it means).
type Item = { key: string, content: PetCard.Content }

local COLUMNS = 5
local ROWS = 3
local PAGE_SIZE = COLUMNS * ROWS
local CELL = Vector2.new(156, 136)

-- How to get each pet source (Index panel).
local SOURCE_TEXT: { [string]: string } = {
	group = "Join our group: Rewards button!",
	starter = "Comes in the Starter Pack.",
	secret = "Comes in the Secret Pack.",
	wheel = "Spin the Lucky Wheel!",
	event = "Fill the Harvest Feast sticker sheet!",
	crate = "Find it in Supply Crates!",
	lucky = "Hatch it from a Lucky Egg!",
	-- R57: a fixed pet inside a one-time pack (the Time Ptero comes in the Time Traveler Pack).
	-- Other pack pets override the line with PetConfig `how` (Rocket Corgi: Astronaut Pack).
	pack = "Comes in the Time Traveler Pack (Shop)!",
	-- R78: a Nuke Pass reward (Golden Nukey: PetConfig `how` names the season + tier).
	pass = "Earn it on the Nuke Pass!",
}

-- Side viewport height: normal, and on INDEX (smaller, so the rewards panel fits the card).
local SIDE_VIEW_H = 150
local SIDE_VIEW_INDEX_H = 110

-- The egg a pet hatches from (nil for specials).
local EGG_OF: { [string]: string } = {}
for _, eggId in EggConfig.Order do
	for _, slot in EggConfig.Eggs[eggId].slots do
		EGG_OF[slot.pet] = EGG_OF[slot.pet] or eggId
	end
end

-- The StudUI colour preset of a rarity.
local function rarityColor(rarity: string): string
	local def = PetConfig.rarity(rarity)
	return if def ~= nil then def.ui else "grey"
end

-- A transparent layout frame.
local function box(name: string, size: UDim2, parent: Instance, order: number?): Frame
	return Create.new(
		"Frame",
		{ Name = name, BackgroundTransparency = 1, Size = size, LayoutOrder = order or 0, Parent = parent }
	) :: Frame
end

local function list(parent: Instance, horizontal: boolean, padding: number)
	Create.new("UIListLayout", {
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, padding),
		Parent = parent,
	})
end

return StudUI.modalScreen({
	name = "Pets",
	title = "Pets",
	color = "purple",
	icon = "Pets",
	size = Vector2.new(1280, 760),
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		local tab: Tab = "pets"
		local pages: { [Tab]: number } = { pets = 1, eggs = 1, index = 1, trails = 1 }
		local selected: { [Tab]: string? } = { pets = nil, eggs = nil, index = nil, trails = nil }
		local deleteMode = false
		local deletePicks: { [string]: boolean } = {}
		local confirmDelete = false
		local items: { Item } = {}

		list(window.body, false, 8)

		-- Top bar: tabs + header stats.
		local topBar = box("TopBar", UDim2.new(1, 0, 0, 70), window.body, 1)
		list(topBar, true, 12)
		local tabButtons: { [Tab]: StudUI.Button } = {}
		local refresh: () -> ()
		for order, entry in { { "pets", "PETS" }, { "eggs", "EGGS" }, { "index", "INDEX" }, { "trails", "TRAILS" } } do
			local id = entry[1] :: Tab
			tabButtons[id] = StudUI.button({
				text = entry[2],
				color = "grey",
				size = UDim2.fromOffset(170, 72),
				textSize = 30,
				layoutOrder = order,
				parent = topBar,
				onActivated = function()
					tab = id
					deleteMode = false
					table.clear(deletePicks)
					confirmDelete = false
					refresh()
				end,
			})
		end
		-- R78: red "!" on INDEX while a Pet Index milestone is ready to claim.
		local indexBadge = IndexRewards.tabBadge(tabButtons.index.instance)
		-- Owner R89: FLAVOURS → the Flavour Book (handoff; B comes back here), "!" while a reward is ready.
		FlavorBookEntry.attach(topBar, 5, "Pets", UDim2.fromOffset(200, 72))
		local stats = StudUI.text({
			text = "",
			textSize = 28,
			font = "number",
			scaled = true,
			size = UDim2.fromOffset(300, 50),
			layoutOrder = 9,
			parent = topBar,
		})

		-- Main: grid + pager on the left, side panel on the right.
		local main = box("Main", UDim2.new(1, 0, 1, -80), window.body, 2)
		list(main, true, 16)
		local left = box("Left", UDim2.new(0, COLUMNS * CELL.X + (COLUMNS - 1) * 10, 1, 0), main, 1)
		list(left, false, 8)
		-- The grid sits in a layout-free holder so the empty-state label can overlay the whole grid
		-- area (a child of the UIGridLayout frame itself would be laid out as one small cell).
		local gridArea = box(
			"GridArea",
			UDim2.fromOffset(COLUMNS * CELL.X + (COLUMNS - 1) * 10, ROWS * CELL.Y + (ROWS - 1) * 10),
			left,
			1
		)
		local grid = box("Grid", UDim2.fromScale(1, 1), gridArea, 1)
		Create.new("UIGridLayout", {
			CellSize = UDim2.fromOffset(CELL.X, CELL.Y),
			CellPadding = UDim2.fromOffset(10, 10),
			SortOrder = Enum.SortOrder.LayoutOrder,
			FillDirectionMaxCells = COLUMNS,
			Parent = grid,
		})
		-- Empty state ("No pets yet! ..."): centred across the whole grid area.
		local empty = StudUI.text({
			text = "",
			textSize = 40,
			font = "title",
			scaled = true,
			wrap = true,
			size = UDim2.fromScale(0.86, 0.32),
			position = UDim2.fromScale(0.5, 0.45),
			anchor = Vector2.new(0.5, 0.5),
			zIndex = 3,
			parent = gridArea,
		})
		empty.Visible = false
		local pager = box("Pager", UDim2.new(1, 0, 0, 76), left, 2)
		list(pager, true, 14)
		local function turn(delta: number)
			local pageCount = math.max(1, math.ceil(#items / PAGE_SIZE))
			pages[tab] = math.clamp(pages[tab] + delta, 1, pageCount)
			refresh()
		end
		local prev = StudUI.button({
			text = "<",
			color = "blue",
			size = UDim2.fromOffset(90, 72),
			textSize = 36,
			layoutOrder = 1,
			parent = pager,
			onActivated = function()
				turn(-1)
			end,
		})
		local pageLabel = StudUI.text({
			text = "1 / 1",
			textSize = 30,
			font = "number",
			size = UDim2.fromOffset(120, 60),
			layoutOrder = 2,
			parent = pager,
		})
		local nextButton = StudUI.button({
			text = ">",
			color = "blue",
			size = UDim2.fromOffset(90, 72),
			textSize = 36,
			layoutOrder = 3,
			parent = pager,
			onActivated = function()
				turn(1)
			end,
		})

		-- The detail panel is a stud card (owner rule 2: every UI surface is a stud panel), so its
		-- title / blurb never float bare on the window body (empty states included).
		local sideCard = StudUI.card({
			name = "SideCard",
			color = "purple",
			size = UDim2.new(1, -(COLUMNS * CELL.X + (COLUMNS - 1) * 10) - 16, 1, -8),
			layoutOrder = 2,
			parent = main,
		})
		local side = sideCard.content
		list(side, false, 6)
		local sideView =
			PetViewport.new({ size = UDim2.new(1, 0, 0, SIDE_VIEW_H), spin = true, layoutOrder = 1, parent = side })
		local sideTitle = StudUI.text({
			text = "",
			textSize = 36,
			font = "title",
			scaled = true,
			size = UDim2.new(1, 0, 0, 44),
			layoutOrder = 2,
			parent = side,
		})
		local sideLine1 = StudUI.text({
			text = "",
			textSize = 28,
			font = "number",
			scaled = true,
			size = UDim2.new(1, 0, 0, 34),
			layoutOrder = 3,
			parent = side,
		})
		local sideLine2 = StudUI.text({
			text = "",
			textSize = 22,
			font = "body",
			scaled = true,
			wrap = true,
			size = UDim2.new(1, 0, 0, 48),
			layoutOrder = 4,
			parent = side,
		})
		-- (White on the purple card: TextDim would be too faint there.)
		sideLine2.TextColor3 = Neutral.Text
		local sideButtons: { StudUI.Button } = {}
		for index = 1, 3 do
			table.insert(
				sideButtons,
				StudUI.button({
					text = "",
					color = "green",
					size = UDim2.new(0.92, 0, 0, 72),
					textSize = 28,
					layoutOrder = 4 + index,
					parent = side,
				})
			)
		end

		-- R78 Pet Index rewards panel (INDEX tab only; between the hidden side buttons and hints).
		local rewards = IndexRewards.new({ parent = side, layoutOrder = 8 })
		rewards.frame.Visible = false

		-- Gamepad hints for the card shortcuts (X equip, Y lock), shown in gamepad mode on PETS.
		local hints = Create.new("Frame", {
			Name = "PadHints",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 40),
			LayoutOrder = 9,
			Parent = side,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 8),
				}),
			},
		}) :: Frame
		for order, hint in { { Enum.KeyCode.ButtonX, "Equip" }, { Enum.KeyCode.ButtonY, "Lock" } } do
			local glyph = InputGlyph.dynamic(nil, hint[1] :: Enum.KeyCode, 30)
			glyph.LayoutOrder = order * 2 - 1
			glyph.Parent = hints
			StudUI.text({
				text = hint[2] :: string,
				textSize = 24,
				font = "title",
				autoWidth = true,
				size = UDim2.fromOffset(0, 32),
				layoutOrder = order * 2,
				parent = hints,
			})
		end

		-- Grid cards (pooled).
		local cards: { PetCard.Card } = {}
		local function press(slotIndex: number)
			local item = items[(pages[tab] - 1) * PAGE_SIZE + slotIndex]
			if item == nil then
				return
			end
			if tab == "pets" and deleteMode then
				local profile: any = ClientState.profile or {}
				local owned = if type(profile.pets) == "table" and type(profile.pets.owned) == "table"
					then profile.pets.owned
					else {}
				local entry = owned[item.key]
				if type(entry) == "table" and entry.locked ~= true then
					deletePicks[item.key] = if deletePicks[item.key] then nil else true
				end
			else
				selected[tab] = item.key
				confirmDelete = false
			end
			refresh()
		end
		for index = 1, PAGE_SIZE do
			table.insert(
				cards,
				PetCard.new(grid, index, function()
					press(index)
				end)
			)
		end

		-- Builds the item list of the current tab from the profile.
		local function buildItems(profile: any)
			table.clear(items)
			local pets = if type(profile.pets) == "table" then profile.pets else {}
			local owned = if type(pets.owned) == "table" then pets.owned else {}
			local equipped = if type(pets.equipped) == "table" then pets.equipped else {}
			if tab == "pets" then
				local uids: { string } = {}
				for uid, entry in owned do
					if type(entry) == "table" and PetConfig.get(entry.id) ~= nil then
						table.insert(uids, uid)
					end
				end
				local rank: { [string]: number } = {}
				for index, uid in equipped do
					rank[uid] = index
				end
				table.sort(uids, function(a: string, b: string): boolean
					local ea, eb = rank[a], rank[b]
					if (ea ~= nil) ~= (eb ~= nil) then
						return ea ~= nil
					elseif ea ~= nil and eb ~= nil then
						return ea < eb
					end
					local da, db =
						PetConfig.get(owned[a].id) :: PetConfig.PetDef, PetConfig.get(owned[b].id) :: PetConfig.PetDef
					if da.id ~= db.id then
						return PetConfig.better(da, db)
					end
					return (tonumber(a) or 0) < (tonumber(b) or 0)
				end)
				for _, uid in uids do
					local entry = owned[uid]
					local def = PetConfig.get(entry.id) :: PetConfig.PetDef
					local isEquipped = rank[uid] ~= nil
					table.insert(items, {
						key = uid,
						content = {
							kind = "pet" :: PetViewport.Kind,
							id = def.id,
							color = rarityColor(def.rarity),
							caption = PetConfig.formatBonus(def.cash),
							captionColor = Neutral.CashGreen,
							badge = if entry.locked == true then "LOCK" else nil,
							check = if deleteMode and deletePicks[uid] then "X" elseif isEquipped then "ON" else nil,
							checkColor = if deleteMode and deletePicks[uid] then Neutral.Danger else Neutral.CashGreen,
							highlight = selected.pets == uid,
						},
					})
				end
			elseif tab == "eggs" then
				local eggs = if type(pets.eggs) == "table" then pets.eggs else {}
				for _, eggId in EggConfig.Order do
					local count = tonumber(eggs[eggId]) or 0
					if count > 0 then
						table.insert(items, {
							key = eggId,
							content = {
								kind = "egg" :: PetViewport.Kind,
								id = eggId,
								color = "purple",
								caption = EggConfig.Eggs[eggId].name,
								badge = `x{count}`,
								highlight = selected.eggs == eggId,
							},
						})
					end
				end
			elseif tab == "index" then
				local index = if type(pets.index) == "table" then pets.index else {}
				for _, petId in PetConfig.Order do
					local def = PetConfig.Pets[petId]
					local found = index[petId] == true
					table.insert(items, {
						key = petId,
						content = {
							kind = if found then "pet" :: PetViewport.Kind else nil,
							id = if found then petId else nil,
							color = if found then rarityColor(def.rarity) else "grey",
							caption = if found then def.name else "???",
							mystery = if found then nil else "?",
							highlight = selected.index == petId,
						},
					})
				end
			else
				local trails = if type(profile.trails) == "table" then profile.trails else {}
				local ownedTrails = if type(trails.owned) == "table" then trails.owned else {}
				for _, trailId in CrateConfig.TrailOrder do
					local def = CrateConfig.Trails[trailId]
					local has = ownedTrails[trailId] == true
					table.insert(items, {
						key = trailId,
						content = {
							color = if has then rarityColor(def.rarity) else "grey",
							caption = def.name,
							swatch = def.colors,
							badge = if has then nil else "LOCK",
							check = if trails.equipped == trailId then "ON" else nil,
							highlight = selected.trails == trailId,
						},
					})
				end
			end
		end

		-- Sets a side button (nil text hides it).
		local function sideButton(index: number, text: string?, color: string?, callback: (() -> ())?, state: string?)
			local button = sideButtons[index]
			button.instance.Visible = text ~= nil
			if text ~= nil then
				button.setColor((color or "green") :: any)
				PetUI.setButton(button, state or "normal", text)
				button.setCallback(callback)
			end
		end

		-- Fills the side panel for the current tab / selection.
		local function paintSide(profile: any, slots: number)
			local pets = if type(profile.pets) == "table" then profile.pets else {}
			local owned = if type(pets.owned) == "table" then pets.owned else {}
			local equipped = if type(pets.equipped) == "table" then pets.equipped else {}
			for index = 1, 3 do
				sideButton(index, nil)
			end
			sideView.frame.Visible = false
			sideTitle.Text, sideLine1.Text, sideLine2.Text = "", "", ""
			if tab == "pets" then
				local uid = selected.pets
				local entry = if uid ~= nil then owned[uid] else nil
				if deleteMode then
					local picked = 0
					for _ in deletePicks do
						picked += 1
					end
					sideTitle.Text = "DELETE MODE"
					sideLine2.Text = "Tap pets to pick them. Locked pets are safe."
					sideButton(1, `DELETE ({picked})`, "red", function()
						local uids: { string } = {}
						for pick in deletePicks do
							table.insert(uids, pick)
						end
						if #uids > 0 then
							Remotes.event("DeletePets"):FireServer(uids)
						end
						deleteMode = false
						table.clear(deletePicks)
						refresh()
					end, if picked > 0 then "normal" else "disabled")
					sideButton(2, "CANCEL", "grey", function()
						deleteMode = false
						table.clear(deletePicks)
						refresh()
					end)
					return
				end
				if type(entry) == "table" and PetConfig.get(entry.id) ~= nil then
					local def = PetConfig.get(entry.id) :: PetConfig.PetDef
					local rarity = PetConfig.rarity(def.rarity)
					local isEquipped = table.find(equipped, uid) ~= nil
					sideView.frame.Visible = true
					sideView.set("pet", def.id)
					sideTitle.Text = def.name
					sideTitle.TextColor3 = if rarity ~= nil then rarity.color else Neutral.Text
					sideLine1.Text = `{def.rarity} - {PetConfig.formatBonus(def.cash)} cash`
					sideLine2.Text = if entry.locked == true then "Locked: safe from deleting." else ""
					sideButton(
						1,
						if isEquipped then "UNEQUIP" else "EQUIP",
						if isEquipped then "yellow" else "green",
						function()
							Remotes.event("EquipPet"):FireServer(uid, not isEquipped)
						end,
						if not isEquipped and #equipped >= slots then "disabled" else "normal"
					)
					sideButton(2, if entry.locked == true then "UNLOCK" else "LOCK", "blue", function()
						Remotes.event("LockPets"):FireServer({ uid }, entry.locked ~= true)
					end)
					sideButton(3, if confirmDelete then "SURE?" else "DELETE", "red", function()
						if confirmDelete then
							confirmDelete = false
							Remotes.event("DeletePets"):FireServer({ uid })
							selected.pets = nil
						else
							confirmDelete = true
						end
						refresh()
					end, if entry.locked == true then "disabled" else "normal")
				else
					sideTitle.Text = "Your Pets"
					sideLine2.Text = "Pets give you extra cash while they follow you. Hatch eggs at the hub!"
				end
			elseif tab == "eggs" then
				local eggId = selected.eggs
				local egg = if eggId ~= nil then EggConfig.get(eggId) else nil
				if egg ~= nil then
					sideView.frame.Visible = true
					sideView.set("egg", egg.id)
					sideTitle.Text = egg.name
					local count = if type(pets.eggs) == "table" then tonumber(pets.eggs[egg.id]) or 0 else 0
					sideLine1.Text = `You have {count}`
					sideLine2.Text = "Held eggs hatch for free, anywhere!"
					sideButton(1, "HATCH", "green", function()
						ScreenManager.close("Pets")
						ScreenManager.open("EggHatch", { eggId = egg.id })
					end)
				else
					sideTitle.Text = "Held Eggs"
					sideLine2.Text = if #items == 0
						then "Win eggs from the Lucky Wheel and Supply Crates!"
						else "Pick an egg to hatch it."
				end
			elseif tab == "index" then
				local petId = selected.index
				local def = if petId ~= nil then PetConfig.get(petId) else nil
				local index = if type(pets.index) == "table" then pets.index else {}
				if def ~= nil then
					local found = index[def.id] == true
					local rarity = PetConfig.rarity(def.rarity)
					sideView.frame.Visible = found
					if found then
						sideView.set("pet", def.id)
					end
					sideTitle.Text = if found then def.name else "???"
					sideTitle.TextColor3 = if rarity ~= nil then rarity.color else Neutral.Text
					sideLine1.Text = `{def.rarity} - {PetConfig.formatBonus(def.cash)} cash`
					local eggId = EGG_OF[def.id]
					local fromEgg = if eggId ~= nil then EggConfig.Eggs[eggId] else nil
					sideLine2.Text = if fromEgg ~= nil
							and def.source == "egg"
							and fromEgg.world ~= "main"
						then `Hatch it from the {fromEgg.name} in {EggConfig.worldName(fromEgg)}!`
						elseif fromEgg ~= nil and def.source == "egg" then `Hatch it from the {fromEgg.name}!`
						else def.how or SOURCE_TEXT[def.source] or "A mystery pet!"
				else
					sideTitle.Text = "Pet Index"
					sideLine2.Text = "Discover every pet in the game!"
				end
			else
				local trailId = selected.trails
				local def = if trailId ~= nil then CrateConfig.getTrail(trailId) else nil
				local trails = if type(profile.trails) == "table" then profile.trails else {}
				local ownedTrails = if type(trails.owned) == "table" then trails.owned else {}
				if def ~= nil then
					local has = ownedTrails[def.id] == true
					local isOn = trails.equipped == def.id
					sideTitle.Text = def.name
					sideLine1.Text = def.rarity
					sideLine2.Text = if has then "A glowing trail behind you!" else "Find it in Supply Crates!"
					if has then
						sideButton(
							1,
							if isOn then "UNEQUIP" else "EQUIP",
							if isOn then "yellow" else "green",
							function()
								Remotes.event("EquipTrail"):FireServer(if isOn then "" else def.id)
							end
						)
					end
				else
					sideTitle.Text = "Trails"
					sideLine2.Text = "Equip a trail to leave a glow wherever you go!"
				end
				sideButton(2, "CRATES", "yellow", function()
					ScreenManager.close("Pets")
					ScreenManager.open("CrateShop")
				end)
			end
		end

		-- EQUIP BEST + DELETE MODE ride on the pager row (always reachable, ≥ 44 pt).
		local equipBest = StudUI.button({
			text = "EQUIP BEST",
			color = "green",
			size = UDim2.fromOffset(200, 72),
			textSize = 24,
			layoutOrder = 4,
			parent = pager,
			onActivated = function()
				Remotes.event("EquipBest"):FireServer()
			end,
		})
		local deleteToggle = StudUI.button({
			text = "DELETE MODE",
			color = "red",
			size = UDim2.fromOffset(200, 72),
			textSize = 24,
			layoutOrder = 5,
			parent = pager,
			onActivated = function()
				deleteMode = not deleteMode
				table.clear(deletePicks)
				confirmDelete = false
				refresh()
			end,
		})

		refresh = function()
			local profile: any = ClientState.profile or {}
			local passes = if type(profile.passes) == "table" then profile.passes else {}
			local shop = if type(profile.rebirthShop) == "table"
				then profile.rebirthShop[PetConfig.Slots.ShopKey]
				else 0
			local slots = PetConfig.slotsFor(passes[PetConfig.Slots.PassKey] == true, shop)
			local pets = if type(profile.pets) == "table" then profile.pets else {}
			local owned = if type(pets.owned) == "table" then pets.owned else {}
			local equipped = if type(pets.equipped) == "table" then pets.equipped else {}

			-- Header stats.
			local ownedCount, bonus = 0, 0
			for _ in owned do
				ownedCount += 1
			end
			for _, uid in equipped do
				local entry = owned[uid]
				local def = if type(entry) == "table" then PetConfig.get(entry.id) else nil
				if def ~= nil then
					bonus += def.cash
				end
			end
			if tab == "index" then
				-- Exclusive pets count when owned; the total is the non-exclusive pets (R78).
				stats.Text = `Discovered {PetIndexConfig.discovered(pets.index)} / {PetIndexConfig.Total}`
			else
				stats.Text =
					`{ownedCount}/{PetConfig.InventoryCap}   Equipped {#equipped}/{slots}   {PetConfig.formatBonus(
						bonus
					)} cash`
			end
			for id, button in tabButtons do
				button.setColor(if id == tab then "purple" else "grey")
			end
			deleteToggle.instance.Visible = tab == "pets"
			equipBest.instance.Visible = tab == "pets"
			deleteToggle.setColor(if deleteMode then "grey" else "red")
			deleteToggle.setText(if deleteMode then "DONE" else "DELETE MODE")

			buildItems(profile)
			local pageCount = math.max(1, math.ceil(#items / PAGE_SIZE))
			pages[tab] = math.clamp(pages[tab], 1, pageCount)
			pageLabel.Text = `{pages[tab]} / {pageCount}`
			prev.setState(if pages[tab] > 1 then "normal" else "disabled")
			nextButton.setState(if pages[tab] < pageCount then "normal" else "disabled")
			local first = (pages[tab] - 1) * PAGE_SIZE
			for index, card in cards do
				local item = items[first + index]
				if item ~= nil then
					card.show(item.content)
				else
					card.hide()
				end
			end
			empty.Visible = #items == 0
			empty.Text = if tab == "pets"
				then "No pets yet! Hatch an egg at the hub."
				elseif tab == "eggs" then "No held eggs."
				else ""
			paintSide(profile, slots)
			-- R78 Index rewards: panel on INDEX (smaller viewport there), badge on the INDEX tab.
			rewards.frame.Visible = tab == "index"
			sideView.frame.Size = UDim2.new(1, 0, 0, if tab == "index" then SIDE_VIEW_INDEX_H else SIDE_VIEW_H)
			rewards.update(profile)
			indexBadge(#PetIndexConfig.claimable(pets) > 0)
			hints.Visible = tab == "pets" and not deleteMode and InputController.mode == "Gamepad"
			-- Gamepad: link the visible cards as a grid; exits to the tab bar, the pager and the side.
			local visible: { GuiObject } = {}
			for _, card in cards do
				if card.button.Visible then
					table.insert(visible, card.button)
				end
			end
			local firstSide: GuiObject? = nil
			for _, button in sideButtons do
				if button.instance.Visible then
					firstSide = button.instance
					break
				end
			end
			if tab == "index" then
				-- CLAIM is the side's only control on INDEX: grid → right → CLAIM → left → grid.
				local claimButton = rewards.claimButton
				firstSide = claimButton
				claimButton.NextSelectionLeft = visible[1]
				claimButton.NextSelectionUp = tabButtons[tab].instance
				claimButton.NextSelectionDown = prev.instance
			end
			GamepadNav.linkGrid(
				visible,
				COLUMNS,
				{ up = tabButtons[tab].instance, down = prev.instance, right = firstSide }
			)
		end

		-- LB / RB (Q / E) cycle the tabs (B16 GamepadNav cycler, "Tabs" hint in the hint bar).
		local TAB_ORDER: { Tab } = { "pets", "eggs", "index", "trails" }
		local function cycleTab(delta: number)
			local index = table.find(TAB_ORDER, tab) or 1
			tab = TAB_ORDER[(index - 1 + delta) % #TAB_ORDER + 1]
			deleteMode = false
			table.clear(deletePicks)
			confirmDelete = false
			refresh()
		end
		local tabCycler = GamepadNav.cycler(function()
			cycleTab(-1)
		end, function()
			cycleTab(1)
		end)

		-- Gamepad X / Y on a selected pet card: equip toggle / lock toggle (intents).
		local function cardShortcut(
			_name: string,
			state: Enum.UserInputState,
			input: InputObject
		): Enum.ContextActionResult
			if state ~= Enum.UserInputState.Begin or tab ~= "pets" or deleteMode then
				return Enum.ContextActionResult.Pass
			end
			local selectedObject = GuiService.SelectedObject
			for index, card in cards do
				if card.button == selectedObject then
					local item = items[(pages[tab] - 1) * PAGE_SIZE + index]
					if item == nil then
						return Enum.ContextActionResult.Pass
					end
					local profile: any = ClientState.profile or {}
					local pets = if type(profile.pets) == "table" then profile.pets else {}
					local entry = if type(pets.owned) == "table" then pets.owned[item.key] else nil
					if type(entry) ~= "table" then
						return Enum.ContextActionResult.Pass
					end
					selected.pets = item.key
					if input.KeyCode == Enum.KeyCode.ButtonX then
						local equipped = if type(pets.equipped) == "table" then pets.equipped else {}
						Remotes.event("EquipPet"):FireServer(item.key, table.find(equipped, item.key) == nil)
					else
						Remotes.event("LockPets"):FireServer({ item.key }, entry.locked ~= true)
					end
					refresh()
					return Enum.ContextActionResult.Sink
				end
			end
			return Enum.ContextActionResult.Pass
		end
		local modeConnection = InputController.ModeChanged:Connect(function()
			hints.Visible = tab == "pets" and not deleteMode and InputController.mode == "Gamepad"
		end)
		window.frame.Destroying:Connect(function()
			modeConnection:Disconnect()
			tabCycler.Destroy()
		end)

		local connection: any = nil
		return {
			onOpen = function(args: any?)
				if
					type(args) == "table"
					and (args.tab == "pets" or args.tab == "eggs" or args.tab == "index" or args.tab == "trails")
				then
					tab = args.tab
				end
				-- R78 deep link: { tab = "index", select = petId } opens the Index on that pet's page
				-- with it selected (e.g. a Nuke Pass "see the Golden Nukey" button). Unknown ids are
				-- ignored (the args come from local UI code, never from the network).
				if type(args) == "table" and tab == "index" then
					local def = PetConfig.get(args.select)
					if def ~= nil then
						selected.index = def.id
						pages.index = math.floor((def.order - 1) / PAGE_SIZE) + 1
					end
				end
				refresh()
				-- onOpen also runs when the screen is re-opened while open: never stack listeners.
				if connection == nil then
					connection = ClientState.ProfileChanged:Connect(function()
						refresh()
					end)
				end
				tabCycler.enable()
				ContextActionService:BindActionAtPriority(
					"SNPetsCardShortcut",
					cardShortcut,
					false,
					Enum.ContextActionPriority.High.Value + 50,
					Enum.KeyCode.ButtonX,
					Enum.KeyCode.ButtonY
				)
			end,
			onClose = function()
				if connection ~= nil then
					connection:Disconnect()
					connection = nil
				end
				ContextActionService:UnbindAction("SNPetsCardShortcut")
				tabCycler.disable()
				deleteMode = false
				table.clear(deletePicks)
				-- Hidden panel: update() stops the CLAIM breathing tween while the window is shut.
				rewards.frame.Visible = false
				rewards.update(ClientState.profile)
			end,
			onBack = function(): boolean
				if deleteMode then
					deleteMode = false
					table.clear(deletePicks)
					refresh()
					return true
				end
				return false
			end,
			defaultSelection = function(): GuiObject?
				local profile: any = ClientState.profile or {}
				local ready = tab == "index" and #PetIndexConfig.claimable(profile.pets) > 0
				return GamepadNav.defaultSelection(
					window.body,
					if ready
						then rewards.claimButton
						elseif cards[1].button.Visible then cards[1].button
						else tabButtons[tab].instance
				)()
			end,
		}
	end,
})
