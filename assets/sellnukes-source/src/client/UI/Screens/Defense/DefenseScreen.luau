--!strict
--[[
	DefenseScreen ("Defense") — Attack mode's upgrade + defence window (spec §9 "AA towers
	(upgradeable range / fire rate / intercept chance) and Shields", §11 Barrage / Shield /
	Mega Launcher).

	Top line (owner R80): how many AA towers defend the plot right now, or a red "you can be nuked
	and have NO AA tower" call to action.

	Cards (stud window, scrolls on small screens):
		AA TOWER        the Area 7 Feature pad's HQ tower: level n / 5, range / reload / chance now →
		                next, [UPGRADE $X] (DefenseUpgrade "aa", toLevel)
		MIDDLE / GATE / SILO YARD / BACK LOT TOWER (owner R80, one card per AttackConfig.Towers
		                slot): LOCKED (reach area N), [BUILD $X] (DefenseTower slot, 1), level n / 5
		                with stats now → next and [UPGRADE $X] (DefenseTower slot, n + 1), or MAX
		LAUNCHER        level n / 5, reload / reward seconds / armor now → next, [UPGRADE $X]
		                (DefenseUpgrade "launcher")
		SHIELD          bubble countdown or "No shield", free-shield progress (hits n / 3) with
		                [TURN ON FREE SHIELD] (ShieldActivate), and [1 HOUR R$] (Shield1h product)
		BARRAGE         stored nukes, [+20 NUKES R$] (Barrage product); sent from the target picker
		                (owner R85: the launcher card shows the starter L1 for everyone; the Attack
		                Console gives L2 and unlocks the upgrades)
		MEGA LAUNCHER   x2 attack rewards game pass, [R$] or OWNED
	A footer reminds everyone that nobody loses anything (kid-friendly rule).

	Display only: levels / prices come from the shared AttackLogic + TycoonConfig maths on the
	synced profile and the server-set attributes; buttons send intents (AttackClient) and the
	server re-checks everything (prices, cash, features, max level, shields).

	Input: gamepad selection starts on the first affordable tower BUILD / UPGRADE button (else the
	first tower card's button); every button is a selectable stud button (D-pad / stick move
	between them, the scrolling body follows the cursor); B / X / the red X close. Touch: >= 44 pt
	buttons. Owner R122: the Robux offers (Barrage, Mega Launcher, Shield 1 HOUR) are tagged BUY
	buttons behind UI/PurchaseGuard — never the default cursor, and the press that opened the
	window never buys.

	Connects to: Client/Attack/AttackClient, Shared/Attack/{AttackLogic, DefenseTowers},
	Shared/Config/{AttackConfig, TycoonConfig, MonetizationConfig}, Client/ClientState,
	UI/{Create, Kit/StudUI}.

	Example: ScreenManager.open("Defense")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttackClient = require(script.Parent.Parent.Parent.Parent.Attack.AttackClient)
local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackLogic = require(ReplicatedStorage.Shared.Attack.AttackLogic)
local ClientState = require(script.Parent.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Parent.Create)
local DefenseTowers = require(ReplicatedStorage.Shared.Attack.DefenseTowers)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
-- Owner R122 purchase-focus hygiene (opening-press guard, BUY tags, safe default selection).
local PurchaseGuard = require(script.Parent.Parent.Parent.PurchaseGuard)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)

local NAME = "Defense"
local CARD_SIZE = Vector2.new(600, 330)

-- A finite number from an untyped value.
local function num(value: unknown, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

-- The cash price of a Feature pad (upgrade prices are multiples of it).
local function featurePrice(feature: string): number
	local padId = TycoonConfig.FeaturePadOf[feature]
	local pad = if padId ~= nil then TycoonConfig.PadsById[padId] else nil
	return if pad ~= nil then pad.cost else 0
end

-- "1.25 s" style seconds.
local function seconds(value: number): string
	local text = string.format("%.2f", value)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return `{text} s`
end

-- "24%" style percentage.
local function percent(value: number): string
	return `{math.floor(value * 100 + 0.5)}%`
end

type Row = { title: TextLabel, now: TextLabel, nextText: TextLabel, button: StudUI.Button }

return StudUI.modalScreen({
	name = NAME,
	title = "Defense & Launcher",
	color = "blue",
	icon = "Shield",
	size = Vector2.new(1300, 820),
	scroll = true,
	build = function(window: StudUI.Window): any
		local body = window.body
		Create.new("UIListLayout", {
			Padding = UDim.new(0, 14),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = body,
		})
		-- Owner R80: the plot's defence at a glance (count of active towers / call to action).
		local summary = StudUI.text({
			text = "",
			textSize = 30,
			font = "shout",
			wrap = true,
			size = UDim2.new(1, -40, 0, 48),
			layoutOrder = 0,
			parent = body,
		})
		-- HQ tower + one card per defence slot + launcher / shield / barrage / Mega Launcher, two
		-- per row.
		local cardCount = 5 + DefenseTowers.count()
		local rows = math.ceil(cardCount / 2)
		local grid = Create.new("Frame", {
			Name = "Cards",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -8, 0, CARD_SIZE.Y * rows + (rows - 1) * 18),
			LayoutOrder = 1,
			Parent = body,
			Children = {
				Create.new("UIGridLayout", {
					CellSize = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
					CellPadding = UDim2.fromOffset(18, 18),
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame

		-- One card with a big line, a "now" line, a "next" line and a button.
		local function card(
			order: number,
			color: StudUI.ColorName,
			title: string,
			icon: string,
			buttonColor: StudUI.ColorName,
			onPress: () -> ()
		): Row
			local c = StudUI.card({ color = color, title = title, titleSize = 40, layoutOrder = order, parent = grid })
			local iconFrame = StudUI.icon(icon, 84, 4)
			iconFrame.Position = UDim2.fromOffset(6, 52)
			iconFrame.Parent = c.content
			local big = StudUI.text({
				text = "",
				textSize = 40,
				font = "shout",
				align = Enum.TextXAlignment.Left,
				position = UDim2.fromOffset(104, 56),
				size = UDim2.new(1, -110, 0, 46),
				parent = c.content,
			})
			local now = StudUI.text({
				text = "",
				textSize = 26,
				wrap = true,
				align = Enum.TextXAlignment.Left,
				position = UDim2.fromOffset(104, 104),
				size = UDim2.new(1, -110, 0, 64),
				parent = c.content,
			})
			local nextText = StudUI.text({
				text = "",
				textSize = 24,
				wrap = true,
				align = Enum.TextXAlignment.Left,
				color = Color3.fromRGB(200, 255, 170),
				position = UDim2.fromOffset(12, 170),
				size = UDim2.new(1, -24, 0, 56),
				parent = c.content,
			})
			local button = StudUI.button({
				text = "",
				color = buttonColor,
				size = UDim2.fromOffset(400, 76),
				anchor = Vector2.new(0.5, 1),
				position = UDim2.new(0.5, 0, 1, -8),
				parent = c.content,
				onActivated = onPress,
			})
			return { title = big, now = now, nextText = nextText, button = button }
		end

		-- The level each upgrade button was rendered for (sent as toLevel: a double tap never buys
		-- two levels — the server refuses anything but stored + 1).
		local shownNext: { [string]: number } = {}
		local aaRow = card(1, "sky", "AA Tower", "AATower", "green", function()
			AttackClient.upgrade("aa", shownNext.aa)
		end)
		-- Owner R80: one card per defence tower slot (buy, then upgrade L1 → L5).
		local towerRows: { Row } = {}
		for index = 1, DefenseTowers.count() do
			local slot = DefenseTowers.slot(index)
			towerRows[index] = card(
				1 + index,
				"teal",
				if slot ~= nil then slot.name else "AA Tower",
				"AATower",
				"green",
				function()
					local toLevel = shownNext[`tower{index}`]
					if toLevel ~= nil then
						AttackClient.buildTower(index, toLevel)
					end
				end
			)
		end
		local order = 2 + DefenseTowers.count()
		local launcherRow = card(order, "orange", "Launcher", "Attack", "green", function()
			AttackClient.upgrade("launcher", shownNext.launcher)
		end)
		local shieldRow = card(order + 1, "blue", "Shield Bubble", "Shield", "green", function()
			AttackClient.activateShield()
		end)
		-- Robux offers (owner R122): guarded intents (the press that opened Defense never buys) on
		-- tagged BUY buttons (never the default cursor).
		local barrageRow = card(
			order + 2,
			"red",
			"Barrage",
			"Barrage",
			"green",
			PurchaseGuard.gate(NAME, function()
				AttackClient.buy("Barrage")
			end)
		)
		local megaRow = card(
			order + 3,
			"purple",
			"Mega Launcher",
			"MegaLauncher",
			"green",
			PurchaseGuard.gate(NAME, function()
				AttackClient.buy(AttackConfig.Reward.MegaLauncherPass, true)
			end)
		)
		PurchaseGuard.markBuy(barrageRow.button.instance)
		PurchaseGuard.markBuy(megaRow.button.instance)
		-- Shield card: second button (buy 1 hour) beside the free-shield one.
		local shieldProduct = MonetizationConfig.getProduct("Shield1h")
		shieldRow.button.instance.Size = UDim2.fromOffset(300, 76)
		shieldRow.button.instance.AnchorPoint = Vector2.new(0, 1)
		shieldRow.button.instance.Position = UDim2.new(0, 10, 1, -8)
		local buyShield = StudUI.button({
			text = "1 HOUR",
			color = "purple",
			productKey = if shieldProduct ~= nil then shieldProduct.key else nil, -- live price (PriceBook)
			size = UDim2.fromOffset(250, 76),
			anchor = Vector2.new(1, 1),
			position = UDim2.new(1, -10, 1, -8),
			parent = shieldRow.button.instance.Parent,
			onActivated = PurchaseGuard.gate(NAME, function()
				AttackClient.buy("Shield1h")
			end),
		})
		PurchaseGuard.markBuy(buyShield.instance)
		local shieldBar = StudUI.progressBar({ color = "green", size = UDim2.new(1, -24, 0, 22) })
		shieldBar.frame.Position = UDim2.fromOffset(12, 176)
		shieldBar.frame.Parent = shieldRow.button.instance.Parent
		local shieldCountdown = StudUI.countdown({
			endsAt = 0,
			format = "auto",
			prefix = "Shield ON: ",
			doneText = "No shield right now",
			textSize = 30,
			size = UDim2.new(1, -110, 0, 40),
		})
		shieldCountdown.label.Position = UDim2.fromOffset(104, 104)
		shieldCountdown.label.TextXAlignment = Enum.TextXAlignment.Left
		shieldCountdown.label.Parent = shieldRow.button.instance.Parent
		shieldRow.now.Visible = false

		StudUI.text({
			text = "Nobody ever loses anything! A hit gives the attacker bonus cash and YOU a free Revenge nuke.",
			textSize = 26,
			wrap = true,
			size = UDim2.new(1, -40, 0, 64),
			layoutOrder = 2,
			parent = body,
		})

		-- Gamepad: keep the selected button in view while the cursor walks the scrolling body
		-- (Platform/GamepadNav, guarded: the screen works without the platform layer).
		if body:IsA("ScrollingFrame") then
			pcall(function()
				local nav: any = require(script.Parent.Parent.Parent.Parent.Platform.GamepadNav)
				nav.followScroll(body)
			end)
		end

		local barrageProduct = MonetizationConfig.getProduct("Barrage")
		local megaPass = MonetizationConfig.getPass(AttackConfig.Reward.MegaLauncherPass)

		-- The AA stats lines of a tower level ("now" / "next"), shared by the HQ and slot cards.
		local function towerStats(row: Row, level: number)
			local stats = AttackConfig.AA[level]
			row.now.Text = if stats ~= nil
				then `Range {stats.range} · fires every {seconds(stats.reload)} · {percent(stats.chance)} per shot`
				else ""
			local nextStats = AttackConfig.AA[level + 1]
			row.nextText.Text = if nextStats ~= nil
				then `Next: range {nextStats.range} · {seconds(nextStats.reload)} · {percent(nextStats.chance)}`
				else "Fully upgraded!"
		end

		-- One defence tower slot card (owner R80): locked / build / upgrade / max.
		local function renderTower(row: Row, index: number, me: AttackClient.MyState, cash: number)
			local slot = DefenseTowers.slot(index)
			if slot == nil then
				return
			end
			local key = `tower{index}`
			local level = DefenseTowers.level(me.towers, index)
			-- Owner R85: nothing to defend while still protected as a brand-new player.
			if not me.targetable then
				shownNext[key] = nil
				row.title.Text = if level > 0 then `Level {level}` else "Not needed yet"
				row.now.Text = "You're still new - nobody can nuke you yet."
				row.nextText.Text = "Towers unlock the moment your protection ends."
				row.button.setState("locked", "SAFE")
				return
			end
			if not DefenseTowers.unlocked(index, DefenseTowers.areaFor(me.area, me.targetable)) then
				shownNext[key] = nil
				row.title.Text = if level > 0 then `Level {level} (packed away)` else "Locked"
				row.now.Text = `Unlocks when you reach area {slot.unlockArea}.`
				row.nextText.Text = if level > 0 then "It builds itself back in when you get there." else ""
				row.button.setState("locked", `AREA {slot.unlockArea}`)
				return
			end
			local toLevel, cost = DefenseTowers.nextStep(index, level)
			if level < 1 then
				row.title.Text = "Not built yet"
				local stats = AttackConfig.AA[1]
				row.now.Text = `{slot.where}. Shoots down incoming nukes!`
				row.nextText.Text =
					`Level 1: range {stats.range} · {seconds(stats.reload)} · {percent(stats.chance)} per shot`
			else
				row.title.Text = `Level {level} / {AttackConfig.MaxLevel}`
				towerStats(row, level)
			end
			if toLevel < 1 then
				shownNext[key] = nil
				row.button.setState("claimed", "MAX")
				return
			end
			shownNext[key] = toLevel
			row.button.setState(if cash >= cost then "normal" else "disabled")
			row.button.setText(`{if level < 1 then "BUILD" else "UPGRADE"} {NumberFormat.money(cost)}`)
		end

		-- One upgrade card (AA or Launcher).
		local function renderUpgrade(row: Row, kind: string, effective: number, has: boolean, cash: number)
			local feature = if kind == "aa" then AttackConfig.FeatureAA else AttackConfig.FeatureConsole
			if not has and kind == "launcher" then
				-- Owner R85: everyone launches with the starter launcher; the Console levels it up.
				shownNext[kind] = nil
				local stats = AttackConfig.Launcher[AttackConfig.StarterLauncher]
				row.title.Text = `Level {AttackConfig.StarterLauncher} / {AttackConfig.MaxLevel} (starter)`
				row.now.Text = `Reload {stats.cooldown} s · reward {stats.rewardSeconds} s of their $/s`
				row.nextText.Text =
					`The Attack Console pad (Launch Silos, area {AttackConfig.UnlockArea}) gives Level {AttackConfig.ConsoleLauncher}.`
				row.button.setState("locked", "CONSOLE")
				return
			end
			if not has then
				shownNext[kind] = nil
				row.title.Text = "Not built yet"
				row.now.Text = `Buy the AA Tower pad in Launch Silos (area {AttackConfig.UnlockArea}).`
				row.nextText.Text = ""
				row.button.setState("locked", "LOCKED!")
				return
			end
			row.title.Text = `Level {effective} / {AttackConfig.MaxLevel}`
			if kind == "aa" then
				towerStats(row, effective)
			else
				local stats = AttackConfig.Launcher[effective]
				row.now.Text =
					`Reload {stats.cooldown} s · reward {stats.rewardSeconds} s of their $/s · armor {percent(
						stats.armor
					)}`
				local nextStats = AttackConfig.Launcher[effective + 1]
				row.nextText.Text = if nextStats ~= nil
					then `Next: reload {nextStats.cooldown} s · {nextStats.rewardSeconds} s · armor {percent(
						nextStats.armor
					)}`
					else "Fully upgraded!"
			end
			local cost = AttackLogic.upgradeCost(effective, featurePrice(feature))
			if cost == math.huge then
				shownNext[kind] = nil
				row.button.setState("claimed", "MAX")
			else
				shownNext[kind] = effective + 1
				row.button.setState(if cash >= cost then "normal" else "disabled")
				row.button.setText(`UPGRADE {NumberFormat.money(cost)}`)
			end
		end

		local function render()
			local profile: any = ClientState.profile
			if type(profile) ~= "table" then
				return
			end
			local me = AttackClient.myState()
			local cash = num(profile.cash, 0)
			local t = Workspace:GetServerTimeNow()
			renderUpgrade(aaRow, "aa", me.aa, me.aa > 0, cash)
			for index, row in towerRows do
				renderTower(row, index, me, cash)
			end
			renderUpgrade(launcherRow, "launcher", me.launcher, me.console, cash)

			-- Owner R80 summary line: the plot's defence right now.
			if not me.targetable then
				summary.Text = "You're still new - nobody can nuke you yet. Towers unlock when that ends!"
				summary.TextColor3 = Color3.fromRGB(200, 205, 220)
			elseif me.towerCount == 0 then
				summary.Text = "You can be nuked and have NO AA tower! Build one below."
				summary.TextColor3 = Color3.fromRGB(255, 120, 100)
			else
				summary.Text = if me.towerCount == 1
					then "1 AA tower defends your plot. Build more: each one shoots at every nuke!"
					else `{me.towerCount} AA towers defend your plot - each one shoots at every nuke!`
				summary.TextColor3 = Color3.fromRGB(150, 235, 120)
			end

			-- Shield.
			shieldCountdown.setEndsAt(if me.shieldUntil > t then me.shieldUntil else 0)
			local hits = math.min(me.hitsTaken, AttackConfig.FreeShieldHits)
			shieldRow.title.Text = if me.shieldUntil > t then "Bubble is UP!" else "No bubble"
			shieldBar.setProgress(hits / AttackConfig.FreeShieldHits)
			shieldRow.nextText.Text = `Free shield: {hits} / {AttackConfig.FreeShieldHits} hits taken`
			shieldRow.nextText.Position = UDim2.fromOffset(12, 140)
			if AttackLogic.freeShieldReady(me.hitsTaken) then
				shieldRow.button.setState("normal")
				shieldRow.button.setText("FREE SHIELD!")
			else
				shieldRow.button.setState("locked", "FREE SHIELD")
			end
			buyShield.setState("normal")

			-- Barrage.
			barrageRow.title.Text = `{me.barrage} nukes stored`
			barrageRow.now.Text = `Send {AttackConfig.BarrageSize} nukes at once from the target picker - no reload!`
			-- Owner R85: everyone can launch, so Barrage (and stored golden nukes) need no Console.
			barrageRow.nextText.Text = if me.golden > 0 then `+ {me.golden} Golden Revenge Nukes stored` else ""
			barrageRow.button.setText(
				`+{if barrageProduct ~= nil and barrageProduct.nukes ~= nil
					then barrageProduct.nukes
					else AttackConfig.BarrageSize} NUKES`
			)
			barrageRow.button.setProductKey(if barrageProduct ~= nil then barrageProduct.key else nil)
			barrageRow.button.setState("normal")

			-- Mega Launcher pass.
			local owned = type(profile.passes) == "table"
				and profile.passes[AttackConfig.Reward.MegaLauncherPass] == true
			megaRow.title.Text = `x{AttackConfig.Reward.MegaLauncherMultiplier} attack rewards`
			megaRow.now.Text = "Every hit pays double, forever."
			megaRow.nextText.Text = ""
			if owned then
				megaRow.button.setRobux(nil)
				megaRow.button.setState("claimed", "OWNED")
			else
				megaRow.button.setText("")
				megaRow.button.setProductKey(if megaPass ~= nil then megaPass.key else nil)
				megaRow.button.setState("normal")
			end
		end

		local connections: { any } = {}
		return {
			onOpen = function(args: any?)
				AttackClient.reportOpen(NAME, if type(args) == "table" then args.source else nil)
				render()
				if #connections == 0 then
					table.insert(
						connections,
						ClientState.ProfileChanged:Connect(function()
							render()
						end)
					)
					table.insert(connections, AttackClient.Changed:Connect(render))
				end
			end,
			onClose = function()
				for _, connection in connections do
					connection:Disconnect()
				end
				table.clear(connections)
			end,
			defaultSelection = function(): GuiObject?
				-- The first affordable tower purchase (slots first: the cheap way to defend), else
				-- the HQ upgrade, else the first slot card's button.
				for _, row in towerRows do
					if row.button.state() == "normal" then
						return row.button.instance
					end
				end
				if aaRow.button.state() == "normal" then
					return aaRow.button.instance
				end
				local first = towerRows[1]
				-- R122: whatever the pick, never a Robux BUY (PurchaseGuard filters them out).
				return PurchaseGuard.safeDefault({
					if first ~= nil then first.button.instance else nil,
					launcherRow.button.instance,
				})
			end,
		}
	end,
})
