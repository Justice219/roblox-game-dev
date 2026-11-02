--!strict
--[[
	CrateOpenScreen ("CrateOpen") — opens a Supply Crate and plays its reveal:
		ScreenManager.open("CrateOpen", { crateId = "supply_crate" })            -- open now (gems / held)
		ScreenManager.open("CrateOpen", { crateId = "golden_crate", ready = true }) -- a Robux crate
		                                                                         -- arrived: OPEN! first
	Sequence: the crate bounces in → wobbles in three growing bursts → the LID flies off with a
	flash in the reward's rarity colour → a spinning rarity sunburst → the reward card pops up:
	the pet / egg model in 3D, a 2x Cash / 2x Speed / gems icon, or the trail's colour band, with
	its name, rarity and tags (NEW! / PITY! / DUPLICATE +N gems / EQUIPPED). Then AWESOME! closes
	and OPEN ANOTHER repeats while the player still has a held crate or enough gems.

	The request is an INTENT (PetRequests.openCrate → OpenCrate); the server picks the reward, so
	the animation only starts once CrateResult arrives (a short "Opening..." wobble covers the
	round trip). A refusal shows the server's message and closes.

	Paid random items: every open is one (CrateConfig.PaidRandomPay). Whenever the OPEN! / OPEN
	ANOTHER / AGAIN button is offered, the crate's odds per rarity are shown right under the title
	(CrateConfig.oddsSummary — the published = rolled weights), so a repeat purchase never happens
	without the odds on screen. Where the region restricts paid random items
	(EggConfig.policyState(profile.policy) == "restricted") the button is locked ("UNAVAILABLE");
	the server re-checks every request anyway and fails closed.

	Reduce Motion: no wobble / fly; a fade from crate to reward. One RenderStepped connection
	exists only while a reveal animates.
	Console + mobile: StudUI buttons, gamepad default = the main button, B closes when idle.

	Connects to: Client/Pets/{PetRequests, PetViewport, PetUI}, Client/ClientState, UI/Hud/Hud,
	Shared/Config/{CrateConfig, PetConfig, EggConfig, BoostConfig}, UI/Kit/StudUI,
	UI/Widgets/{ModalShell, StudWindow, OfferFx}.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local BoostConfig = require(ReplicatedStorage.Shared.Config.BoostConfig)
local ClientState = require(script.Parent.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Parent.Create)
local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local Hud = require(script.Parent.Parent.Parent.Hud.Hud)
local ModalShell = require(script.Parent.Parent.Parent.Widgets.ModalShell)
local OfferFx = require(script.Parent.Parent.Parent.Widgets.OfferFx)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetRequests = require(script.Parent.Parent.Parent.Parent.Pets.PetRequests)
local PetUI = require(script.Parent.Parent.Parent.Parent.Pets.PetUI)
local PetViewport = require(script.Parent.Parent.Parent.Parent.Pets.PetViewport)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Neutral = UIStyleConfig.Neutral

local NAME = "CrateOpen"
local DESIGN = Vector2.new(1200, 820)

local function tween(instance: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?): Tween
	local t = TweenService:Create(
		instance,
		TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		props
	)
	t:Play()
	return t
end

-- Icon key for a non-model reward.
local function rewardIcon(reward: CrateConfig.Reward): string
	if reward.kind == "gems" then
		return "Gems"
	elseif reward.kind == "boost" then
		return if reward.id == "speed2x" then "Time" else "x2Cash"
	end
	return "Gift"
end

local module: ScreenManager.ScreenModule = {
	name = NAME,
	modal = true,
	closeOnBack = false,
	lazy = true,
	displayOrder = 40,
	blur = true,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		Create.new("Frame", {
			Name = "Dim",
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.35,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 0,
			Parent = gui,
		})
		local stage = Create.new(
			"Frame",
			{ Name = "Stage", BackgroundTransparency = 1, Size = UDim2.fromOffset(DESIGN.X, DESIGN.Y) }
		) :: Frame
		local shell = ModalShell.new(gui, stage, DESIGN)
		local title = StudUI.text({
			text = "",
			textSize = 60,
			font = "shout",
			size = UDim2.fromOffset(DESIGN.X, 76),
			position = UDim2.fromOffset(0, 6),
			parent = stage,
		})
		-- The crate's odds per rarity, shown whenever a (repeat) purchase button is offered.
		local oddsLine = StudUI.text({
			text = "",
			textSize = 28,
			font = "body",
			scaled = true,
			size = UDim2.fromOffset(DESIGN.X - 120, 36),
			position = UDim2.fromOffset(60, 84),
			parent = stage,
		})
		oddsLine.ZIndex = 8
		oddsLine.Visible = false

		-- Centre piece: sunburst, crate / reward viewport, icon, swatch, flash.
		local center = Create.new("Frame", {
			Name = "Center",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(460, 420),
			Position = UDim2.fromOffset(DESIGN.X / 2, 330),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Parent = stage,
		}) :: Frame
		local centerScale = Create.new("UIScale", { Scale = 1, Parent = center }) :: UIScale
		local burst = StudWindow.sunburst(center, { size = UDim2.fromOffset(620, 620), spin = true, zIndex = 1 })
		burst.Visible = false
		local view = PetViewport.new({ size = UDim2.fromScale(1, 1), zIndex = 3, zoom = 1.05, parent = center })
		local iconHolder = Create.new("Frame", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(260, 260),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 3,
			Visible = false,
			Parent = center,
		}) :: Frame
		local swatch = Create.new("Frame", {
			Name = "Swatch",
			BackgroundColor3 = Color3.new(1, 1, 1),
			Size = UDim2.fromOffset(380, 110),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 3,
			Visible = false,
			Parent = center,
			Children = {
				Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
				Create.new("UIStroke", { Color = Neutral.Edge, Thickness = 5 }),
			},
		}) :: Frame
		local swatchGradient = Create.new("UIGradient", { Parent = swatch }) :: UIGradient
		local flash = Create.new("Frame", {
			Name = "Flash",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(560, 520),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 6,
			Parent = center,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
		}) :: Frame

		local rewardName = StudUI.text({
			text = "",
			textSize = 52,
			font = "title",
			size = UDim2.fromOffset(DESIGN.X, 62),
			position = UDim2.fromOffset(0, 548),
			parent = stage,
		})
		local rewardInfo = StudUI.text({
			text = "",
			textSize = 32,
			font = "number",
			size = UDim2.fromOffset(DESIGN.X, 42),
			position = UDim2.fromOffset(0, 610),
			parent = stage,
		})
		local rewardTags = StudUI.text({
			text = "",
			textSize = 30,
			font = "shout",
			size = UDim2.fromOffset(DESIGN.X, 40),
			position = UDim2.fromOffset(0, 652),
			parent = stage,
		})
		rewardTags.TextColor3 = Color3.fromRGB(255, 230, 90)

		local buttons = Create.new("Frame", {
			Name = "Buttons",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(DESIGN.X, 100),
			Position = UDim2.fromOffset(0, DESIGN.Y - 110),
			Parent = stage,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 24),
				}),
			},
		}) :: Frame

		local crateId = "supply_crate"
		local busy = false
		local animation: RBXScriptConnection? = nil
		local running: thread? = nil
		local startOpen: () -> ()

		local mainButton = StudUI.button({
			text = "OPEN!",
			color = "green",
			size = UDim2.fromOffset(320, 92),
			textSize = 40,
			layoutOrder = 1,
			parent = buttons,
			onActivated = function()
				startOpen()
			end,
		})
		local closeButton = StudUI.button({
			text = "AWESOME!",
			color = "blue",
			size = UDim2.fromOffset(300, 92),
			textSize = 36,
			layoutOrder = 2,
			parent = buttons,
			onActivated = function()
				ScreenManager.close(NAME)
			end,
		})

		-- True when the player's region restricts paid random items (every crate open is one).
		local function regionLocked(): boolean
			local profile: any = ClientState.profile or {}
			return EggConfig.policyState(profile.policy) == "restricted"
		end

		--[[
			Can the player open another one right now (held crate, or enough gems), and the button
			label. A restricted region locks both (the server would refuse; held crates stay safe).
			While the policy is still unknown the server decides (fail closed) on press.
		]]
		local function canOpenAgain(): (boolean, string)
			local crate = CrateConfig.Crates[crateId]
			local profile: any = ClientState.profile or {}
			if regionLocked() then
				return false, CrateConfig.PolicyText.Button
			end
			local crates = if type(profile.crates) == "table" then profile.crates else {}
			local held = if type(crates.held) == "table" then tonumber(crates.held[crateId]) or 0 else 0
			if held > 0 then
				return true, `OPEN ANOTHER ({held})`
			end
			return (tonumber(profile.gems) or 0) >= crate.gems, `AGAIN: {crate.gems} GEMS`
		end

		-- Shows the odds line of the current crate (whenever a purchase button is offered).
		local function showOdds(visible: boolean)
			oddsLine.Text = `ODDS:  {CrateConfig.oddsSummary(CrateConfig.Crates[crateId])}`
			oddsLine.Visible = visible
		end

		-- Resets the stage to the closed crate.
		local function showCrate()
			burst.Visible = false
			iconHolder.Visible = false
			iconHolder:ClearAllChildren()
			swatch.Visible = false
			view.frame.Visible = true
			view.setSpin(false)
			view.set("crate", crateId)
			rewardName.Text, rewardInfo.Text, rewardTags.Text = "", "", ""
			title.Text = CrateConfig.Crates[crateId].name:upper()
		end

		-- Wobbles the crate model (Reduce Motion: none) until `until()` is true or `maxSeconds`.
		local function wobble(seconds: number, degrees: number)
			if OfferFx.reducedMotion() then
				task.wait(seconds)
				return
			end
			local elapsed = 0
			animation = RunService.RenderStepped:Connect(function(dt: number)
				elapsed += dt
				local model = view.model()
				if model ~= nil then
					model:PivotTo(CFrame.Angles(0, math.rad(25), math.rad(math.sin(elapsed * 38) * degrees)))
				end
			end)
			task.wait(seconds)
			if animation ~= nil then
				animation:Disconnect()
				animation = nil
			end
		end

		-- Throws the lid (every "Lid*" piece: B8f art contract) up and away.
		local function popLid(seconds: number)
			local model = view.model()
			if model == nil or OfferFx.reducedMotion() then
				return
			end
			local lids: { { part: BasePart, from: CFrame } } = {}
			for _, item in model:GetDescendants() do
				if item:IsA("BasePart") and string.sub(item.Name, 1, 3) == "Lid" then
					table.insert(lids, { part = item, from = item.CFrame })
				end
			end
			if #lids == 0 then
				return
			end
			-- One shared pivot (the lid pieces' centre) so the whole lid flies off as one piece.
			local centre = Vector3.zero
			for _, entry in lids do
				centre += entry.from.Position
			end
			local pivot = CFrame.new(centre / #lids)
			local toLocal = pivot:Inverse()
			local elapsed = 0
			animation = RunService.RenderStepped:Connect(function(dt: number)
				elapsed = math.min(elapsed + dt, seconds)
				local t = elapsed / seconds
				local motion = pivot * CFrame.new(-t * 3, t * 7, 0) * CFrame.Angles(0, 0, t * 3) * toLocal
				for _, entry in lids do
					entry.part.CFrame = motion * entry.from
					entry.part.Transparency = t
				end
			end)
			task.wait(seconds)
			if animation ~= nil then
				animation:Disconnect()
				animation = nil
			end
		end

		-- Shows the reward of a successful payload.
		local function showReward(payload: any)
			local crate = CrateConfig.Crates[crateId]
			local reward = CrateConfig.reward(crate, payload.rewardKey)
			if reward == nil then
				return
			end
			local rarity = PetConfig.rarity(reward.rarity)
			local still = OfferFx.reducedMotion()
			flash.BackgroundColor3 = if rarity ~= nil and rarity.rank >= 3
				then rarity.color:Lerp(Color3.new(1, 1, 1), 0.4)
				else Color3.new(1, 1, 1)
			flash.BackgroundTransparency = 0
			tween(flash, 0.5, { BackgroundTransparency = 1 })
			burst.Visible = not still
			for _, ray in burst:GetChildren() do
				if ray:IsA("Frame") and rarity ~= nil then
					ray.BackgroundColor3 = rarity.color
				end
			end
			view.frame.Visible = false
			iconHolder.Visible = false
			swatch.Visible = false
			if payload.dup == true then
				iconHolder.Visible = true
				iconHolder:ClearAllChildren()
				StudUI.icon("Gems", 260, 4).Parent = iconHolder
			elseif reward.kind == "pet" or reward.kind == "egg" then
				view.frame.Visible = true
				view.set(reward.kind :: any, reward.id :: string)
				view.setSpin(true)
			elseif reward.kind == "trail" then
				local def = CrateConfig.getTrail(reward.id)
				if def ~= nil then
					local keypoints: { ColorSequenceKeypoint } = {}
					for index, color in def.colors do
						table.insert(
							keypoints,
							ColorSequenceKeypoint.new((index - 1) / math.max(1, #def.colors - 1), color)
						)
					end
					swatchGradient.Color = ColorSequence.new(keypoints)
				end
				swatch.Visible = true
			else
				iconHolder.Visible = true
				iconHolder:ClearAllChildren()
				StudUI.icon(rewardIcon(reward), 260, 4).Parent = iconHolder
			end
			if not still then
				centerScale.Scale = 0.5
				tween(centerScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
			end
			title.Text = if rarity ~= nil and rarity.rank >= 5 then "WOW!" else "YOU GOT"
			rewardName.Text = reward.label
			rewardName.TextColor3 = if rarity ~= nil then rarity.color else Neutral.Text
			local info = reward.rarity
			if reward.kind == "pet" then
				local def = PetConfig.get(reward.id)
				info = `{reward.rarity}  {PetConfig.formatBonus(if def ~= nil then def.cash else 0)} cash`
			elseif reward.kind == "boost" then
				local boost = BoostConfig.get(reward.id or "")
				info = `{if boost ~= nil then boost.name else "Boost"} for {math.floor(reward.seconds / 60)} min!`
			elseif reward.kind == "egg" then
				info = "Hatch it from your Pets menu (EGGS)!"
			end
			rewardInfo.Text = info
			local tags: { string } = {}
			if payload.dup == true then
				table.insert(tags, `DUPLICATE: +{payload.gems} GEMS`)
			elseif payload.isNew == true and (reward.kind == "pet" or reward.kind == "trail") then
				table.insert(tags, "NEW!")
			end
			if payload.pityForced == true then
				table.insert(tags, "PITY!")
			end
			rewardTags.Text = table.concat(tags, "  ")
		end

		-- Sends the open request and plays the whole reveal.
		local function sequence()
			busy = true
			mainButton.instance.Visible = false
			closeButton.instance.Visible = false
			showOdds(false)
			showCrate()
			title.Text = "OPENING..."
			local requestId = PetRequests.openCrate(crateId)
			if requestId == nil then
				busy = false
				ScreenManager.close(NAME)
				return
			end
			local result: any = nil
			local connection = PetRequests.CrateResult:Connect(function(id: number, payload: any)
				if id == requestId then
					result = payload
				end
			end)
			-- Anticipation wobble while the server answers (and at least the first burst).
			local burstIndex = 0
			while result == nil or burstIndex < 1 do
				burstIndex += 1
				wobble(0.35, 4 + math.min(burstIndex, 3) * 4)
				task.wait(0.12)
				if burstIndex > 60 then
					break
				end
			end
			connection:Disconnect()
			if result == nil or result.ok ~= true then
				busy = false
				Hud.notify(
					"error",
					if result ~= nil and type(result.message) == "string"
						then result.message
						else "That crate can't be opened right now."
				)
				ScreenManager.close(NAME)
				return
			end
			for extra = burstIndex + 1, 3 do
				wobble(0.3, 4 + extra * 4)
				task.wait(0.1)
			end
			popLid(0.22)
			showReward(result)
			PetUI.haptic("Reward")
			task.wait(0.5)
			busy = false
			local again, label = canOpenAgain()
			PetUI.setButton(
				mainButton,
				if again then "normal" elseif regionLocked() then "locked" else "disabled",
				label
			)
			mainButton.instance.Visible = true
			closeButton.instance.Visible = true
			showOdds(true)
		end

		startOpen = function()
			if busy then
				return
			end
			if running ~= nil and coroutine.status(running) ~= "dead" then
				return
			end
			running = task.spawn(sequence)
		end

		return {
			onOpen = function(args: any?)
				-- Re-opened while a reveal plays (e.g. a Robux crate arrived): let it finish.
				if busy then
					return
				end
				if type(args) == "table" and CrateConfig.get(args.crateId) ~= nil then
					crateId = args.crateId
				end
				shell.popIn()
				busy = false
				showCrate()
				if type(args) == "table" and args.ready == true then
					-- A Robux crate arrived: let the player press OPEN!
					title.Text = `{CrateConfig.Crates[crateId].name:upper()} READY!`
					if regionLocked() then
						PetUI.setButton(mainButton, "locked", CrateConfig.PolicyText.Button)
					else
						PetUI.setButton(mainButton, "normal", "OPEN!")
					end
					mainButton.instance.Visible = true
					closeButton.instance.Visible = true
					closeButton.setText("LATER")
					showOdds(true)
				else
					closeButton.setText("AWESOME!")
					startOpen()
				end
			end,
			onClose = function()
				showOdds(false)
				if animation ~= nil then
					animation:Disconnect()
					animation = nil
				end
				if running ~= nil and coroutine.status(running) ~= "dead" and coroutine.running() ~= running then
					pcall(task.cancel, running)
				end
				running = nil
				busy = false
			end,
			onBack = function(): boolean
				if not busy then
					ScreenManager.close(NAME)
				end
				return true
			end,
			defaultSelection = function(): GuiObject?
				return mainButton.instance
			end,
		}
	end,
}

return module
