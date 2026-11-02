--!strict
--[[
	AttackHudScreen ("AttackHud") — Attack mode's always-on HUD chips (non-modal, auto-open) and
	the boot point of the attack client.

	Chips (bottom centre, stacked above the HUD's objective chip — HudZones "Bottom"):
		REVENGE   orange: "<name> nuked you!" + countdown + [REVENGE!] — launches the free Revenge
		          nuke straight away (no picker needed; the server checks the token).
		          Keyboard R · gamepad D-pad Up · tap.
		GOLDEN    owner R85, gold: "Strike back at <name> with a GOLDEN NUKE!" + [GOLDEN 31 R$] — the
		          paid golden revenge nuke (PromptProduct "RevengeNuke", source "attack"; live price
		          from PriceBook) while the player who hit you is here and hittable
		          (AttackClient.goldenTarget) and AttackConfig.Golden.Enabled; the server re-checks
		          before the prompt and at receipt. Keyboard J · gamepad R3 · tap.
		          Owner R122 (no accidental purchase prompts): the chip / J / R3 no longer prompt in
		          one press — they open the small non-modal DEAL card (UI/Screens/DealCard) beside
		          the chip; only the card's BUY (tap, or its own X / E binding) prompts. The card
		          closes when the chip goes away.
		SHIELD    blue: "FREE SHIELD ready!" (after AttackConfig.FreeShieldHits hits) + [TURN ON] →
		          ShieldActivate. Keyboard G · gamepad D-pad Down · tap.
	Each chip shows its device-following button glyph (InputGlyph.dynamic). Bindings are active only
	while that chip is visible and no modal window is open. The picker hides this screen through
	its focus reason (no overlap with the picker's bottom row).

	Boot: build() calls AttackClient.start() (idempotent) — UIController discovers this screen, so
	Attack mode's client starts without editing the client boot list.

	Connects to: Client/Attack/AttackClient, Shared/Config/AttackConfig, Shared/Attack/AttackLogic,
	UI/{ScreenManager, Create, Kit/StudUI, Widgets/{HudZones, InputGlyph, StudWindow}}.

	Example: (auto-open) — chips appear on their own when a Revenge / free shield is available.
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttackClient = require(script.Parent.Parent.Parent.Parent.Attack.AttackClient)
local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackLogic = require(ReplicatedStorage.Shared.Attack.AttackLogic)
local Create = require(script.Parent.Parent.Parent.Create)
local HudZones = require(script.Parent.Parent.Parent.Widgets.HudZones)
local InputGlyph = require(script.Parent.Parent.Parent.Widgets.InputGlyph)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
-- Owner R122: the GOLDEN chip's button is a tagged Robux entry (never a default selection).
local PurchaseGuard = require(script.Parent.Parent.Parent.PurchaseGuard)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)

local NAME = "AttackHud"
-- Owner R122: the shared non-modal DEAL card screen (UI/Screens/DealCard) and this chip's card id.
local DEAL_SCREEN = "DealCard"
local GOLDEN_DEAL_ID = "golden"
local KEYS = AttackConfig.Client.Keys

-- One AttackConfig.Client.Keys entry (frozen config tables are read-only).
type Binding = typeof(KEYS.HudRevenge)
local CHIP_SIZE = Vector2.new(720, 104)
local CHIP_GAP = 14
-- Design px above the bottom zone (or the canvas bottom when the HUD has no bottom chip).
local BOTTOM_MARGIN = 150

type Chip = {
	frame: Frame,
	title: TextLabel,
	button: StudUI.Button,
	glyph: Frame,
	action: string,
	bound: boolean,
	press: () -> (),
}

local module: ScreenManager.ScreenModule = {
	name = NAME,
	modal = false,
	autoOpen = true,
	displayOrder = 6,
	lazy = false,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		AttackClient.start()

		local root = Create.new("Frame", {
			Name = "AttackHudRoot",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(1920, 1080),
			Parent = gui,
		}) :: Frame

		-- One chip: stud plate + title + action button + input glyph.
		local function makeChip(
			name: string,
			color: StudUI.ColorName,
			buttonText: string,
			buttonColor: StudUI.ColorName,
			action: string,
			binding: Binding,
			onPress: () -> ()
		): Chip
			local frame = Create.new("Frame", {
				Name = name,
				AnchorPoint = Vector2.new(0.5, 1),
				Size = UDim2.fromOffset(CHIP_SIZE.X, CHIP_SIZE.Y),
				Visible = false,
				Parent = root,
			}) :: Frame
			StudWindow.surface(frame, color, { edge = 4, tile = 0 })
			local title = StudUI.text({
				text = "",
				textSize = 32,
				align = Enum.TextXAlignment.Left,
				scaled = true,
				position = UDim2.fromOffset(22, 12),
				size = UDim2.new(1, -330, 1, -24),
				zIndex = 4,
				parent = frame,
			})
			local button = StudUI.button({
				text = buttonText,
				color = buttonColor,
				size = UDim2.fromOffset(230, 80),
				anchor = Vector2.new(1, 0.5),
				position = UDim2.new(1, -66, 0.5, -2),
				parent = frame,
				onActivated = onPress,
			})
			local glyph = InputGlyph.dynamic(binding.keys[1], binding.pads[1], 40)
			glyph.AnchorPoint = Vector2.new(1, 0.5)
			glyph.Position = UDim2.new(1, -14, 0.5, 0)
			glyph.ZIndex = 5
			glyph.Parent = frame
			return {
				frame = frame,
				title = title,
				button = button,
				glyph = glyph,
				action = action,
				bound = false,
				press = onPress,
			}
		end

		local revengeTarget: number? = nil
		local revengeChip = makeChip(
			"RevengeChip",
			"orange",
			"REVENGE!",
			"red",
			"SN_AttackHud_Revenge",
			KEYS.HudRevenge,
			function()
				if revengeTarget ~= nil then
					AttackClient.launch(revengeTarget, "revenge")
				end
			end
		)
		-- Owner R85 golden revenge nuke (paid): only when the product is published on Roblox.
		local goldenProduct = MonetizationConfig.getProduct(AttackConfig.Golden.Product)
		local goldenLive = goldenProduct ~= nil and MonetizationConfig.isConfigured(goldenProduct.id)
		-- R122: true while THIS chip's deal card is the one on screen (cleared by its onClosed).
		local goldenDealOpen = false
		local goldenChip: Chip
		--[[
			Owner R122: the GOLDEN chip / J / R3 open the DEAL card beside the chip instead of
			prompting in one press (field data: one-press Robux prompts closed in < 2 s). The card's
			BUY sends the same intent (AttackClient.buy, source "attack"); the server re-checks the
			target before the prompt and at receipt.
		]]
		local function openGoldenDeal()
			local position = goldenChip.frame.Position
			goldenDealOpen = true
			ScreenManager.open(DEAL_SCREEN, {
				source = "attack",
				key = AttackConfig.Golden.Product,
				kind = "product",
				promptSource = "attack",
				-- The chip's rect on the HUD canvas (design px): bottom-centre anchored frame.
				anchor = {
					x = position.X.Offset - CHIP_SIZE.X / 2,
					y = position.Y.Offset - CHIP_SIZE.Y,
					w = CHIP_SIZE.X,
					h = CHIP_SIZE.Y,
				},
				id = GOLDEN_DEAL_ID,
				onBuy = function()
					AttackClient.buy(AttackConfig.Golden.Product)
				end,
				onClosed = function()
					goldenDealOpen = false
				end,
			})
		end
		goldenChip =
			makeChip("GoldenChip", "yellow", "GOLDEN", "purple", "SN_AttackHud_Golden", KEYS.HudGolden, openGoldenDeal)
		goldenChip.button.setProductKey(if goldenProduct ~= nil then goldenProduct.key else nil)
		PurchaseGuard.markBuy(goldenChip.button.instance)
		local shieldChip = makeChip(
			"ShieldChip",
			"blue",
			"TURN ON",
			"green",
			"SN_AttackHud_Shield",
			KEYS.HudShield,
			function()
				AttackClient.activateShield()
			end
		)

		-- Binds / unbinds a chip's keys with its visibility (only when no modal is open).
		local function setBound(chip: Chip, binding: Binding, on: boolean)
			if chip.bound == on then
				return
			end
			chip.bound = on
			if not on then
				ContextActionService:UnbindAction(chip.action)
				return
			end
			local inputs: { Enum.KeyCode } = {}
			for _, key in binding.keys do
				table.insert(inputs, key)
			end
			for _, key in binding.pads do
				table.insert(inputs, key)
			end
			ContextActionService:BindAction(
				chip.action,
				function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
					if state ~= Enum.UserInputState.Begin or ScreenManager.anyModalOpen() or not chip.frame.Visible then
						return Enum.ContextActionResult.Pass
					end
					-- Same action as a tap (AttackClient debounces launches).
					chip.press()
					return Enum.ContextActionResult.Sink
				end,
				false,
				table.unpack(inputs)
			)
		end

		-- Stacks the visible chips above the HUD's bottom zone.
		local function layout()
			local canvas = ScreenManager.canvasSize(gui)
			if canvas.X <= 0 or canvas.Y <= 0 then
				return
			end
			root.Size = UDim2.fromOffset(canvas.X, canvas.Y)
			local bottomZone = HudZones.rect("Bottom")
			local baseY = if bottomZone ~= nil then bottomZone.y - CHIP_GAP else canvas.Y - BOTTOM_MARGIN
			local y = baseY
			for _, chip in { revengeChip, goldenChip, shieldChip } do
				if chip.frame.Visible then
					chip.frame.Position = UDim2.fromOffset(canvas.X / 2, y)
					y -= CHIP_SIZE.Y + CHIP_GAP
				end
			end
		end

		-- Re-reads the attack state into the chips.
		local function refresh()
			local player, untilTime = AttackClient.latestRevenge()
			local t = Workspace:GetServerTimeNow()
			local revengeOn = player ~= nil and untilTime > t
			revengeTarget = if player ~= nil then player.UserId else nil
			if player ~= nil then
				revengeChip.title.Text =
					`{player.DisplayName} nuked you! Free revenge · {math.max(math.ceil(untilTime - t), 0)}s`
			end
			revengeChip.frame.Visible = revengeOn
			setBound(revengeChip, KEYS.HudRevenge, revengeOn)

			-- Owner R85: the paid golden strike-back while the attacker is here and hittable.
			local goldenTarget = if goldenLive and AttackConfig.Golden.Enabled then AttackClient.goldenTarget() else nil
			local goldenOn = goldenTarget ~= nil
			if goldenTarget ~= nil then
				goldenChip.title.Text = `Strike back at {goldenTarget.DisplayName} with a GOLDEN NUKE!`
			end
			goldenChip.frame.Visible = goldenOn
			setBound(goldenChip, KEYS.HudGolden, goldenOn)
			-- R122: the chip went away (attacker left / shielded): its deal card goes with it.
			if not goldenOn and goldenDealOpen then
				goldenDealOpen = false
				if ScreenManager.isOpen(DEAL_SCREEN) then
					ScreenManager.close(DEAL_SCREEN)
				end
			end

			local me = AttackClient.myState()
			local shieldOn = AttackLogic.freeShieldReady(me.hitsTaken) and me.shieldUntil <= t
			shieldChip.title.Text = "FREE SHIELD ready! Block nukes for 10 minutes."
			shieldChip.frame.Visible = shieldOn
			setBound(shieldChip, KEYS.HudShield, shieldOn)
			layout()
		end

		AttackClient.Changed:Connect(refresh)
		AttackClient.RevengeChanged:Connect(refresh)
		HudZones.Changed:Connect(layout)
		ScreenManager.LayoutChanged:Connect(layout)
		-- The Revenge countdown ticks once a second, only while a chip is up.
		task.spawn(function()
			while true do
				task.wait(1)
				if revengeChip.frame.Visible or goldenChip.frame.Visible or shieldChip.frame.Visible then
					refresh()
				end
			end
		end)
		task.defer(refresh)
		return {
			onOpen = function()
				task.defer(refresh)
			end,
		}
	end,
}

return module
