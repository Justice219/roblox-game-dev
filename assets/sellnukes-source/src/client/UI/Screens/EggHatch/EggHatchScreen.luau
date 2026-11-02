--!strict
--[[
	EggHatchScreen ("EggHatch") — the egg stand window, opened by an egg stand's ProximityPrompt
	(E / ButtonX / tap) or from the Pets screen's Eggs tab:
		ScreenManager.open("EggHatch", { eggId = "garage_egg" })

	Shows the spinning egg, the four pets with their rarity, the EXACT odds the server rolls
	(EggConfig.oddsFor, with the Lucky Eggs boost when owned) and their cash bonus, the pity meter
	("Epic guaranteed in 37"), the price / balance / held eggs, and the actions:
		HATCH        1 egg (held eggs first, free)
		HATCH 3      TripleHatch pass; without it the button sells the pass (Robux prompt)
		AUTO         AutoHatch pass: loops hatches with the fast reveal; without it sells the pass
		Lucky Eggs   upsell chip while the pass is not owned
	Every button sends an INTENT (HatchFlow → HatchEgg / PromptPass); the server decides prices,
	odds, range and passes. Locked eggs (area not reached / event closed / world still locked)
	show why.

	Worlds (owner R57 World 2): Dino Valley's eggs (EggConfig world "dino") are priced in BONES and
	need Dino Valley unlocked + their Dino area: the price / balance lines and the lock caption
	come from Client/Pets/EggView ("24K Bones each", "You have 1.2K Bones", "UNLOCK DINO VALLEY" /
	"REACH FERN MARKET"), the same words as the stand billboard.

	Paid random items (EggConfig header): buying a cash / acorn / Bones egg is gated by the player's
	PolicyService answer (profile.policy, read with EggConfig.policyState). In a region that
	restricts them the window still shows the full odds, but the buy buttons say
	"UNAVAILABLE" (locked: nothing is sent, nothing is prompted) and the price line explains
	it; held eggs keep their HATCH FREE buttons. While the answer is still unknown the buttons stay
	usable and the balance line says it is checking — the server decides on press and fails closed.

	Console + mobile: every control is a StudUI button (Selectable, ≥ 44 pt on touch); gamepad
	starts on HATCH; B closes. The window scales with ModalShell.
	Owner R122 (no accidental purchase prompts): the pass sellers (Lucky Eggs, HATCH 3 / AUTO while
	their pass is not owned) are tagged Robux BUY buttons (UI/PurchaseGuard) — never the default
	cursor — and a pass prompt is sent only for a press that began after the window opened (the
	stand's E / X / tap that opened it can never also buy).

	Opening it also warms the hatch cinematic's meshes (the egg's pets via the odds rows, the
	EggShards crack / shard overlay + the egg via PetModels.prefetch) so the first HatchReveal is
	fully 3D; a background prefetch 25 s after boot covers hatches that skip the window.

	Connects to: UI/Screens/EggHatch/HatchFlow, Client/Pets/{PetViewport, PetModels, EggView},
	Client/ClientState, Shared/Config/{EggConfig, PetConfig, MonetizationConfig, HatchAnimConfig},
	Shared/Net/Remotes (PromptPass), UI/Kit/StudUI.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Parent.Create)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local EggView = require(script.Parent.Parent.Parent.Parent.Pets.EggView)
local HatchAnimConfig = require(ReplicatedStorage.Shared.Config.HatchAnimConfig)
local HatchFlow = require(script.Parent.HatchFlow)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetModels = require(script.Parent.Parent.Parent.Parent.Pets.PetModels)
local PetUI = require(script.Parent.Parent.Parent.Parent.Pets.PetUI)
local PetViewport = require(script.Parent.Parent.Parent.Parent.Pets.PetViewport)
-- Owner R122 purchase-focus hygiene (opening-press guard, BUY tags, safe default selection).
local PurchaseGuard = require(script.Parent.Parent.Parent.PurchaseGuard)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Neutral = UIStyleConfig.Neutral
-- The ScreenManager name (PurchaseGuard tracks its open time).
local NAME = "EggHatch"

-- Seconds after boot before the hatch cinematic's EggShards overlay meshes are warmed in the
-- background (13 small meshes at PetModels' prefetch priority, never ahead of anything on screen;
-- loaded once per session; the EggHatch window warms them again with its egg).
local SHARDS_WARM_DELAY = 25
task.delay(SHARDS_WARM_DELAY, PetModels.prefetch, { HatchAnimConfig.ShardsKey })

type OddsRow = {
	frame: Frame,
	view: PetViewport.Viewport,
	name: TextLabel,
	rarity: TextLabel,
	chance: TextLabel,
	bonus: TextLabel,
}

-- A transparent layout frame.
local function box(name: string, size: UDim2, parent: Instance, order: number?): Frame
	return Create.new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = size,
		LayoutOrder = order or 0,
		Parent = parent,
	}) :: Frame
end

-- A vertical / horizontal list layout.
local function list(parent: Instance, horizontal: boolean, padding: number, align: Enum.HorizontalAlignment?)
	Create.new("UIListLayout", {
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		HorizontalAlignment = align or Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, padding),
		Parent = parent,
	})
end

-- The pass key whose LIVE price (UI/PriceBook) the Robux tag shows (nil when not a pass).
local function passPriceKey(key: string): string?
	return if MonetizationConfig.getPass(key) ~= nil then key else nil
end

-- Asks the server to prompt a game pass (intent; source "pets" for analytics). Owner R122: only
-- when PurchaseGuard allows it (the press that opened the window never buys).
local function promptPass(key: string)
	if not PurchaseGuard.allow(NAME) then
		return
	end
	Remotes.event("PromptPass"):FireServer(key, "pets")
end

--[[
	Owner R122: tags / untags a button as a Robux BUY (HATCH 3 and AUTO sell their pass only while
	it is not owned; then they hatch / loop for in-game currency and are ordinary buttons again).
]]
local function setBuy(button: GuiObject, on: boolean)
	PurchaseGuard.setBuy(button, on)
end

return StudUI.modalScreen({
	name = NAME,
	title = "Egg",
	color = "purple",
	icon = "Pets",
	size = Vector2.new(1120, 680),
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		local eggId = "garage_egg"
		list(window.body, false, 10)
		local top = box("Top", UDim2.new(1, 0, 0.8, -10), window.body, 1)
		list(top, true, 18)
		local bar = box("Actions", UDim2.fromScale(1, 0.2), window.body, 2)
		list(bar, true, 18)

		-- Left: the egg, held eggs, pity, price.
		local left = box("Left", UDim2.fromScale(0.36, 1), top, 1)
		list(left, false, 6)
		local eggView = PetViewport.new({
			size = UDim2.fromScale(1, 0.56),
			spin = true,
			zoom = 0.95,
			layoutOrder = 1,
			parent = left,
		})
		local held = StudUI.text({
			text = "",
			textSize = 30,
			font = "title",
			scaled = true,
			size = UDim2.fromScale(1, 0.09),
			layoutOrder = 2,
			parent = left,
		})
		held.TextColor3 = Color3.fromRGB(255, 230, 90)
		local pityText = StudUI.text({
			text = "",
			textSize = 26,
			font = "body",
			scaled = true,
			size = UDim2.fromScale(1, 0.08),
			layoutOrder = 3,
			parent = left,
		})
		local pityBar =
			StudUI.progressBar({ color = "purple", size = UDim2.fromScale(0.9, 0.06), layoutOrder = 4, parent = left })
		local price = StudUI.text({
			text = "",
			textSize = 44,
			font = "number",
			scaled = true,
			size = UDim2.fromScale(1, 0.11),
			layoutOrder = 5,
			parent = left,
		})
		local balance = StudUI.text({
			text = "",
			textSize = 24,
			font = "body",
			scaled = true,
			size = UDim2.fromScale(1, 0.07),
			layoutOrder = 6,
			parent = left,
		})
		balance.TextColor3 = Neutral.TextDim

		-- Right: odds rows + the Lucky Eggs line.
		local right = box("Right", UDim2.fromScale(0.6, 1), top, 2)
		list(right, false, 8)
		local oddsTitle = StudUI.sectionLabel("- ODDS -", 30)
		oddsTitle.LayoutOrder = 0
		oddsTitle.Parent = right
		local rows: { OddsRow } = {}
		for index = 1, 4 do
			local frame = Create.new("Frame", {
				Name = `Odds{index}`,
				BackgroundColor3 = Neutral.Well,
				Size = UDim2.fromScale(1, 0.19),
				LayoutOrder = index,
				Parent = right,
				Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 12) }) },
			}) :: Frame
			Create.new("UIStroke", { Thickness = 3, Color = Neutral.Edge, Parent = frame })
			local view = PetViewport.new({ size = UDim2.fromScale(0.16, 1), zoom = 0.9, parent = frame })
			local name = StudUI.text({
				text = "",
				textSize = 30,
				font = "title",
				scaled = true,
				align = Enum.TextXAlignment.Left,
				size = UDim2.fromScale(0.44, 0.5),
				position = UDim2.fromScale(0.18, 0.06),
				parent = frame,
			})
			local rarity = StudUI.text({
				text = "",
				textSize = 22,
				font = "body",
				scaled = true,
				align = Enum.TextXAlignment.Left,
				size = UDim2.fromScale(0.44, 0.36),
				position = UDim2.fromScale(0.18, 0.56),
				parent = frame,
			})
			local chance = StudUI.text({
				text = "",
				textSize = 36,
				font = "number",
				scaled = true,
				align = Enum.TextXAlignment.Right,
				size = UDim2.fromScale(0.34, 0.52),
				position = UDim2.fromScale(0.63, 0.06),
				parent = frame,
			})
			local bonus = StudUI.text({
				text = "",
				textSize = 22,
				font = "body",
				scaled = true,
				align = Enum.TextXAlignment.Right,
				size = UDim2.fromScale(0.34, 0.36),
				position = UDim2.fromScale(0.63, 0.58),
				parent = frame,
			})
			bonus.TextColor3 = Neutral.CashGreen
			table.insert(
				rows,
				{ frame = frame, view = view, name = name, rarity = rarity, chance = chance, bonus = bonus }
			)
		end
		local luckyRow = box("Lucky", UDim2.fromScale(1, 0.13), right, 9)
		local luckyText = StudUI.text({
			text = "",
			textSize = 28,
			font = "title",
			scaled = true,
			size = UDim2.fromScale(1, 1),
			parent = luckyRow,
		})
		luckyText.TextColor3 = Color3.fromRGB(255, 230, 90)
		local luckyButton = StudUI.button({
			text = "Lucky Eggs: 2x rare odds",
			color = "purple",
			size = UDim2.fromScale(0.86, 1),
			textSize = 26,
			parent = luckyRow,
			onActivated = function()
				promptPass(EggConfig.LuckPass)
			end,
		})
		PurchaseGuard.markBuy(luckyButton.instance) -- R122: it only ever sells the Lucky Eggs pass
		luckyButton.instance.AnchorPoint = Vector2.new(0.5, 0)
		luckyButton.instance.Position = UDim2.fromScale(0.5, 0)

		-- Actions.
		local hatchOne = StudUI.button({
			text = "HATCH",
			color = "green",
			size = UDim2.fromOffset(300, 96),
			textSize = 40,
			layoutOrder = 1,
			parent = bar,
			onActivated = function()
				HatchFlow.stopAuto()
				HatchFlow.hatch(eggId, 1)
			end,
		})
		local hatchThree = StudUI.button({
			text = "HATCH 3",
			color = "green",
			size = UDim2.fromOffset(300, 96),
			textSize = 40,
			layoutOrder = 2,
			parent = bar,
		})
		local autoButton = StudUI.button({
			text = "AUTO",
			color = "yellow",
			size = UDim2.fromOffset(300, 96),
			textSize = 40,
			layoutOrder = 3,
			parent = bar,
		})

		-- Re-reads the profile into every label / button.
		local function refresh()
			local egg = EggConfig.get(eggId)
			if egg == nil then
				return
			end
			local profile: any = ClientState.profile or {}
			local passes = if type(profile.passes) == "table" then profile.passes else {}
			local lucky = passes[EggConfig.LuckPass] == true
			local triple = passes[EggConfig.TriplePass] == true
			local autoOwned = passes[EggConfig.AutoPass] == true
			local pets = if type(profile.pets) == "table" then profile.pets else {}
			local heldCount = if type(pets.eggs) == "table" then tonumber(pets.eggs[egg.id]) or 0 else 0
			-- The egg's own currency (cash / acorns / a world's Bones), read like the stand does.
			local balanceValue = EggView.balance(profile, egg)
			-- Paid-random gate (mirrors the server): which hatches would have to BUY a gated egg, and
			-- whether this region forbids that.
			local policy = EggConfig.policyState(profile.policy)
			local restrictedHere = policy == "restricted"
			local blockedOne = restrictedHere and EggConfig.needsPolicy(egg, heldCount, 1)
			local blockedThree = restrictedHere and EggConfig.needsPolicy(egg, heldCount, EggConfig.TripleCount)
			local checking = policy == "checking" and EggConfig.needsPolicy(egg, heldCount, 1)

			window.setTitle(egg.name)
			eggView.set("egg", egg.id)

			-- Odds.
			local odds = EggConfig.oddsFor(egg, lucky)
			for index, row in rows do
				local slot = egg.slots[index]
				local pet = PetConfig.get(slot.pet)
				local rarity = if pet ~= nil then PetConfig.rarity(pet.rarity) else nil
				row.view.set("pet", slot.pet)
				row.name.Text = if pet ~= nil then pet.name else slot.pet
				row.name.TextColor3 = if rarity ~= nil then rarity.color else Neutral.Text
				row.rarity.Text = if pet ~= nil then pet.rarity else ""
				local boosted = lucky and table.find(egg.luckySlots, index) ~= nil
				row.chance.Text = EggConfig.formatChance(odds[index])
				-- Lucky-boosted odds read in gold.
				row.chance.TextColor3 = if boosted then Color3.fromRGB(255, 220, 70) else Neutral.Text
				row.bonus.Text = `{PetConfig.formatBonus(if pet ~= nil then pet.cash else 0)} cash`
				local stroke = row.frame:FindFirstChildOfClass("UIStroke")
				if stroke ~= nil then
					stroke.Color = if rarity ~= nil then rarity.dark else Neutral.Edge
				end
			end
			luckyText.Visible = lucky
			luckyText.Text = "LUCKY EGGS ACTIVE: 2x rare odds!"
			luckyButton.instance.Visible = not lucky
			luckyButton.setProductKey(passPriceKey(EggConfig.LuckPass))

			-- Held / pity / price.
			held.Text = if heldCount > 0 then `You have {heldCount} - they hatch free!` else egg.blurb
			local rule = egg.pity
			if rule ~= nil then
				local counter = if type(pets.pity) == "table" then tonumber(pets.pity[egg.id]) or 0 else 0
				local topPet = PetConfig.get(egg.slots[rule.slot].pet)
				local hatchesLeft = EggConfig.pityLeft(egg, counter) or rule.hatches
				pityText.Text =
					`{if topPet ~= nil then topPet.rarity else "Top"} pet guaranteed in {hatchesLeft} hatches`
				pityBar.setProgress(math.clamp(counter / rule.hatches, 0, 1))
				pityBar.frame.Visible = true
			else
				pityText.Text = ""
				pityBar.frame.Visible = false
			end
			if egg.currency == "held" then
				price.Text = "WON FROM WHEEL + CRATES"
				price.TextColor3 = Neutral.TextDim
				balance.Text = ""
			elseif restrictedHere and EggConfig.PaidRandomCurrencies[egg.currency] == true then
				-- Friendly region state: odds stay visible above; nothing can be bought here.
				price.Text = EggConfig.PolicyText.Restricted
				price.TextColor3 = Neutral.TextDim
				balance.Text = EggConfig.PolicyText.HeldStillHatch
			elseif egg.currency == "acorns" then
				price.Text = `{EggView.formatAmount(egg, egg.price)} each`
				price.TextColor3 = if balanceValue >= egg.price then Neutral.CashGreen else Neutral.Danger
				balance.Text = EggView.balanceText(profile, egg)
			else
				-- Cash (Nuke Town) or a world's wallet (Dino Valley: Bones).
				price.Text = `{EggView.formatAmount(egg, egg.price)} each`
				price.TextColor3 = if balanceValue >= egg.price or heldCount > 0
					then Neutral.CashGreen
					else Neutral.Danger
				balance.Text = EggView.balanceText(profile, egg)
			end
			if checking then
				balance.Text = EggConfig.PolicyText.Checking
			end

			-- Buttons.
			local now = workspace:GetServerTimeNow()
			-- World + area progress of the egg's own world (Dino eggs: Dino Valley unlocked + area).
			local locked = not EggConfig.isUnlocked(profile, egg)
			-- The event's live state (server attribute, follows the admin force) wins over the dates.
			local live = ReplicatedStorage:GetAttribute("HarvestFeastActive")
			local closed = egg.window ~= nil
				and (if type(live) == "boolean" then not live else not EggConfig.isOpen(egg, now))
			local busy = HatchFlow.isBusy()
			local autoState = HatchFlow.autoState()
			if locked then
				PetUI.setButton(hatchOne, "locked", EggView.lockButton(profile, egg))
			elseif closed then
				PetUI.setButton(hatchOne, "locked", "EVENT OVER")
			elseif egg.currency == "held" and heldCount < 1 then
				PetUI.setButton(hatchOne, "disabled", "NO EGGS")
			elseif blockedOne then
				PetUI.setButton(hatchOne, "locked", EggConfig.PolicyText.Button)
			else
				PetUI.setButton(
					hatchOne,
					if busy then "disabled" else "normal",
					if heldCount > 0 then "HATCH FREE" else "HATCH"
				)
			end
			setBuy(hatchThree.instance, not triple)
			setBuy(autoButton.instance, not autoOwned)
			if not triple then
				hatchThree.setColor("purple")
				hatchThree.setProductKey(passPriceKey(EggConfig.TriplePass))
				PetUI.setButton(hatchThree, "normal", "HATCH 3")
				hatchThree.setCallback(function()
					promptPass(EggConfig.TriplePass)
				end)
			else
				hatchThree.setColor("green")
				hatchThree.setRobux(nil)
				if blockedThree and not (locked or closed) then
					PetUI.setButton(hatchThree, "locked", EggConfig.PolicyText.Button)
				else
					PetUI.setButton(hatchThree, if locked or closed or busy then "disabled" else "normal", "HATCH 3")
				end
				hatchThree.setCallback(function()
					HatchFlow.stopAuto()
					HatchFlow.hatch(eggId, EggConfig.TripleCount)
				end)
			end
			if not autoOwned then
				autoButton.setColor("purple")
				autoButton.setProductKey(passPriceKey(EggConfig.AutoPass))
				PetUI.setButton(autoButton, "normal", "AUTO")
				autoButton.setCallback(function()
					promptPass(EggConfig.AutoPass)
				end)
			else
				local running = autoState ~= nil and autoState.eggId == egg.id
				-- Auto keeps BUYING once held eggs run out, so it is locked whenever a restricted
				-- player would have to buy its first round (a running loop can always be stopped).
				local autoBlocked = restrictedHere
					and EggConfig.needsPolicy(egg, heldCount, if triple then EggConfig.TripleCount else 1)
				autoButton.setRobux(nil)
				autoButton.setColor(if running then "red" else "yellow")
				if autoBlocked and not running and not (locked or closed) then
					PetUI.setButton(autoButton, "locked", EggConfig.PolicyText.Button)
				else
					PetUI.setButton(
						autoButton,
						if locked or closed then "disabled" else "normal",
						if running then "STOP AUTO" else "AUTO"
					)
				end
				autoButton.setCallback(function()
					HatchFlow.setAuto(eggId, if triple then EggConfig.TripleCount else 1, not running)
				end)
			end
		end

		local connections: { any } = {}
		return {
			onOpen = function(args: any?)
				if type(args) == "table" and EggConfig.get(args.eggId) ~= nil then
					eggId = args.eggId
				end
				refresh()
				-- Warm the hatch cinematic's shard / crack overlay + this egg's mesh while the player
				-- reads the odds (the odds rows already load the pet meshes), so the first hatch is 3D.
				local shown = EggConfig.get(eggId)
				PetModels.prefetch({ HatchAnimConfig.ShardsKey, if shown ~= nil then shown.model else "" })
				-- onOpen also runs when the screen is re-opened while open: never stack listeners.
				if #connections == 0 then
					table.insert(
						connections,
						ClientState.ProfileChanged:Connect(function()
							refresh()
						end)
					)
					table.insert(connections, HatchFlow.Changed:Connect(refresh))
				end
			end,
			onClose = function()
				for _, connection in connections do
					connection:Disconnect()
				end
				table.clear(connections)
			end,
			-- HATCH (in-game currency / held eggs); never a pass seller (R122 PurchaseGuard).
			defaultSelection = function(): GuiObject?
				return PurchaseGuard.safeDefault({ hatchOne.instance })
			end,
		}
	end,
})
