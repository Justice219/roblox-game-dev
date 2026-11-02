--!strict
--[[
	IndexRewards — the Pet Index milestone panel of the Pets screen's INDEX tab (owner R78, spec
	2026-10-31-r78 §5; numbers + counting in Shared/Config/PetIndexConfig).

	What it shows (inside the INDEX tab's stud side card, under the selected pet):
		INDEX REWARDS                 +4% cash    ← the permanent Index Bonus already earned
		[5][10][20][30][45][60][ALL]              ← milestone pips: green = claimed, yellow =
		                                             ready to claim, grey = not reached yet
		[=========-------]  12 / 20               ← progress toward the next milestone not reached yet
		Next: 60 Gems + 3% cash                   ← what the next milestone pays ("Ready: …" = CLAIM's)
		[ CLAIM +25 GEMS ]                        ← claims the first READY milestone; "FIND 8 MORE"
		                                             (locked) while none is ready; "ALL CLAIMED!"
	Every value is re-read from the server's profile push (ClientState.ProfileChanged → the Pets
	screen's refresh → update(profile)); the CLAIM button only sends the INTENT
	PetIndexClaim(position) — the server decides (PetService.handleIndexClaim) and pays.

	Juice (the claim is a little moment, never silent): when a push shows a newly claimed
	milestone, the button pops, the claimed pip bounces, 8 pooled stars burst from the button,
	"+25 GEMS  +2% CASH" floats up and fades, the "milestone" + "coin_burst" sounds play, a Reward
	haptic fires; the gems themselves fly into the HUD counter (UI/Hud/CurrencyFly, every gem
	increase) and the server's reward toast reads out the prize. While a milestone is ready the
	CLAIM button breathes (one looped UIScale tween, stopped when nothing is ready). Reduce Motion
	(OfferFx.reducedMotion) keeps only the sounds, the text and a colour flash.

	Console + mobile (owner R11): the CLAIM button is a normal selectable stud button (≥ 72 design
	px tall = ≥ 44 pt at phone scale); the Pets screen links it to the card grid (right exit of the
	grid, left back into it) and selects it by default when a milestone is ready. Pips, bar and
	labels are not selectable (Active = false) so they never trap the gamepad.

	Performance: built once per Pets window; update() only writes changed properties; the star
	pool is created at build time (no Instance.new per claim); tweens only run during a burst or
	while a milestone is ready.

	Connects to: Shared/Config/PetIndexConfig, Shared/Net/Remotes (PetIndexClaim), UI/Kit/StudUI,
	UI/Widgets/{StudWindow, OfferFx}, Client/Audio/Sound, Client/Pets/PetUI (haptics),
	UI/Screens/Pets/PetsScreen (owner), Server/Services/PetService (the claim handler).

	Example (PetsScreen):
		local rewards = IndexRewards.new({ parent = side, layoutOrder = 8 })
		rewards.update(ClientState.profile)        -- on every refresh while the INDEX tab shows
		rewards.frame.Visible = tab == "index"
		local badge = IndexRewards.tabBadge(tabButtons.index.instance)
		badge(#PetIndexConfig.claimable(profile.pets) > 0)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Create = require(script.Parent.Parent.Parent.Create)
local OfferFx = require(script.Parent.Parent.Parent.Widgets.OfferFx)
local PetIndexConfig = require(ReplicatedStorage.Shared.Config.PetIndexConfig)
local PetUI = require(script.Parent.Parent.Parent.Parent.Pets.PetUI)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Sound = require(script.Parent.Parent.Parent.Parent.Audio.Sound)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Neutral = UIStyleConfig.Neutral

-- Panel geometry (design px; the window scales as a whole through ModalShell).
local HEADER_H = 30
local PIPS_H = 42
local BAR_H = 28
local NEXT_H = 30
local BUTTON_H = 72
local GAP = 6
local PANEL_H = HEADER_H + PIPS_H + BAR_H + NEXT_H + BUTTON_H + GAP * 4

-- Burst: pooled star sprites and their flight.
local STAR_COUNT = 8
local STAR_SIZE = 30
local STAR_DISTANCE = 110 -- px from the button centre
local BURST_TIME = 0.6
local FLOAT_TIME = 1.1
local POP_IN = TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP_OUT = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local BREATHE = TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

export type Options = {
	parent: Instance,
	layoutOrder: number?,
}

export type Handle = {
	frame: Frame,
	claimButton: TextButton,
	update: (profile: any) -> (),
	Destroy: () -> (),
}

-- Pip state → StudUI colour preset.
local PIP_COLOR: { [string]: StudWindow.ColorName } = {
	claimed = "green",
	ready = "yellow",
	locked = "grey",
}

local IndexRewards = {}

--[[
	A red "!" badge on a tab button (the INDEX tab while a milestone is ready).
	@return setter(visible)
	Example: local badge = IndexRewards.tabBadge(button.instance); badge(true)
]]
function IndexRewards.tabBadge(parent: GuiObject): (visible: boolean) -> ()
	local badge = Create.new("Frame", {
		Name = "IndexBadge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -8, 0, 8),
		Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = UIStyleConfig.Colors.red.bottom,
		Active = false,
		Visible = false,
		ZIndex = 8,
		Parent = parent,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
	}) :: Frame
	StudWindow.edge(badge, 3)
	StudUI.text({ name = "Mark", text = "!", textSize = 24, size = UDim2.fromScale(1, 1), zIndex = 9, parent = badge })
	return function(visible: boolean)
		if badge.Visible ~= visible then
			badge.Visible = visible
		end
	end
end

--[[
	Builds the panel (see the header). Call update(profile) whenever the profile changes.
	@param options parent + layout order
	@return Handle
]]
function IndexRewards.new(options: Options): Handle
	local frame = Create.new("Frame", {
		Name = "IndexRewards",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, PANEL_H),
		LayoutOrder = options.layoutOrder or 0,
		Parent = options.parent,
	}) :: Frame
	local content = Create.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, GAP),
			}),
		},
	}) :: Frame

	-- Header: title + the bonus already earned.
	local header = Create.new("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(0.94, 0, 0, HEADER_H),
		LayoutOrder = 1,
		Parent = content,
	}) :: Frame
	StudUI.text({
		name = "Title",
		text = "INDEX REWARDS",
		textSize = 24,
		font = "title",
		scaled = true,
		align = Enum.TextXAlignment.Left,
		size = UDim2.fromScale(0.6, 1),
		parent = header,
	})
	local bonusLabel = StudUI.text({
		name = "Bonus",
		text = "+0% cash",
		textSize = 24,
		font = "number",
		scaled = true,
		color = Neutral.CashGreen,
		align = Enum.TextXAlignment.Right,
		size = UDim2.fromScale(0.4, 1),
		position = UDim2.fromScale(0.6, 0),
		parent = header,
	})

	-- Milestone pips.
	local pipRow = Create.new("Frame", {
		Name = "Pips",
		BackgroundTransparency = 1,
		Size = UDim2.new(0.94, 0, 0, PIPS_H),
		LayoutOrder = 2,
		Parent = content,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
		},
	}) :: Frame
	type Pip = { frame: Frame, surface: StudWindow.Surface, scale: UIScale, state: string }
	local pips: { Pip } = {}
	local pipWidth = 1 / PetIndexConfig.Count
	for position, milestone in PetIndexConfig.Milestones do
		local pipFrame = Create.new("Frame", {
			Name = `Pip{milestone.id}`,
			Size = UDim2.new(pipWidth, -4, 1, 0),
			Active = false,
			LayoutOrder = position,
			Parent = pipRow,
		}) :: Frame
		local surface = StudWindow.surface(pipFrame, "grey", { edge = 2, corner = 8 })
		local scale = Create.new("UIScale", { Scale = 1, Parent = pipFrame }) :: UIScale
		StudUI.text({
			name = "Label",
			text = milestone.label,
			textSize = 20,
			font = "number",
			scaled = true,
			size = UDim2.fromScale(0.9, 0.8),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
			zIndex = 3,
			parent = pipFrame,
		})
		table.insert(pips, { frame = pipFrame, surface = surface, scale = scale, state = "locked" })
	end

	-- Progress bar toward the next unclaimed milestone + "n / need" on top.
	local barHolder = Create.new("Frame", {
		Name = "Bar",
		BackgroundTransparency = 1,
		Size = UDim2.new(0.94, 0, 0, BAR_H),
		LayoutOrder = 3,
		Parent = content,
	}) :: Frame
	local bar = StudUI.progressBar({ color = "green", size = UDim2.fromScale(1, 1), parent = barHolder })
	local barText = StudUI.text({
		name = "Count",
		text = "0 / 0",
		textSize = 22,
		font = "number",
		scaled = true,
		size = UDim2.fromScale(1, 0.9),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		zIndex = 5,
		parent = barHolder,
	})

	local nextLabel = StudUI.text({
		name = "Next",
		text = "",
		textSize = 26,
		font = "body",
		scaled = true,
		size = UDim2.new(0.94, 0, 0, NEXT_H),
		layoutOrder = 4,
		parent = content,
	})
	nextLabel.TextColor3 = Neutral.Text

	-- The first ready milestone (what CLAIM pays); nil when none is ready.
	local readyNow: PetIndexConfig.Milestone? = nil
	local claim = StudUI.button({
		name = "IndexClaim",
		text = "CLAIM",
		color = "green",
		size = UDim2.new(0.92, 0, 0, BUTTON_H),
		textSize = 28,
		layoutOrder = 5,
		parent = content,
		onActivated = function()
			local milestone = readyNow
			if milestone ~= nil then
				Sound.play("ui_claim")
				Remotes.event("PetIndexClaim"):FireServer(milestone.position)
			end
		end,
	})
	local claimScale = Create.new("UIScale", { Scale = 1, Parent = claim.instance }) :: UIScale
	local breathing: Tween? = nil

	-- Juice layer: pooled stars + the floating prize text, over the whole panel (not laid out).
	local fx = Create.new("Frame", {
		Name = "Fx",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Active = false,
		ZIndex = 20,
		Parent = frame,
	}) :: Frame
	local starImage = StudUI.iconImage("Star")
	local stars: { GuiObject } = {}
	for index = 1, STAR_COUNT do
		local star: GuiObject
		if starImage ~= nil then
			star = Create.new("ImageLabel", {
				Name = `Star{index}`,
				BackgroundTransparency = 1,
				Image = starImage,
				ScaleType = Enum.ScaleType.Fit,
			}) :: ImageLabel
		else
			-- No icon uploaded yet: a round gold dot stands in (same flight).
			star = Create.new("Frame", {
				Name = `Star{index}`,
				BackgroundColor3 = UIStyleConfig.Colors.yellow.top,
				Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
			}) :: Frame
		end
		star.AnchorPoint = Vector2.new(0.5, 0.5)
		star.Size = UDim2.fromOffset(STAR_SIZE, STAR_SIZE)
		star.Active = false
		star.Visible = false
		star.ZIndex = 21
		star.Parent = fx
		table.insert(stars, star)
	end
	local floatText = StudUI.text({
		name = "Prize",
		text = "",
		textSize = 30,
		font = "shout",
		size = UDim2.new(1, 0, 0, 40),
		anchor = Vector2.new(0.5, 1),
		zIndex = 22,
		parent = fx,
	})
	floatText.TextColor3 = UIStyleConfig.Colors.yellow.top
	floatText.Visible = false

	-- Claimed ids seen in the last update (nil until the first one: no juice for old claims).
	local lastClaimed: { [string]: boolean }? = nil

	-- Pops a GuiObject's UIScale (press-and-release feel).
	local function pop(scale: UIScale, peak: number)
		TweenService:Create(scale, POP_IN, { Scale = peak }):Play()
		task.delay(POP_IN.Time, function()
			if scale.Parent ~= nil then
				TweenService:Create(scale, POP_OUT, { Scale = 1 }):Play()
			end
		end)
	end

	-- The celebration for a milestone that just turned claimed (see the header).
	local function celebrate(milestone: PetIndexConfig.Milestone)
		Sound.play("milestone")
		Sound.play("coin_burst")
		PetUI.haptic("Reward")
		local reduced = OfferFx.reducedMotion()
		local origin = UDim2.new(0.5, 0, 1, -BUTTON_H / 2)
		floatText.Text = `+{milestone.gems} GEMS  +{milestone.bonusPct}% CASH`
		floatText.Position = UDim2.new(0.5, 0, 1, -BUTTON_H - 4)
		floatText.TextTransparency = 0
		floatText.Visible = true
		local floatGoal = if reduced
			then { TextTransparency = 1 }
			else { TextTransparency = 1, Position = UDim2.new(0.5, 0, 1, -BUTTON_H - 64) }
		TweenService
			:Create(floatText, TweenInfo.new(FLOAT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), floatGoal)
			:Play()
		task.delay(FLOAT_TIME, function()
			if floatText.Parent ~= nil and floatText.TextTransparency >= 1 then
				floatText.Visible = false
			end
		end)
		local pip = pips[milestone.position]
		if reduced then
			return
		end
		pop(claimScale, 1.12)
		if pip ~= nil then
			pop(pip.scale, 1.3)
		end
		for index, star in stars do
			local angle = (index - 1) / STAR_COUNT * math.pi * 2 + math.random() * 0.4
			local distance = STAR_DISTANCE * (0.7 + math.random() * 0.4)
			star.Position = origin
			star.Rotation = 0
			star.Size = UDim2.fromOffset(STAR_SIZE, STAR_SIZE)
			star.Visible = true
			if star:IsA("ImageLabel") then
				star.ImageTransparency = 0
			else
				star.BackgroundTransparency = 0
			end
			local goal: { [string]: any } = {
				Position = origin + UDim2.fromOffset(math.cos(angle) * distance, math.sin(angle) * distance * 0.7),
				Rotation = 180,
				Size = UDim2.fromOffset(STAR_SIZE * 0.4, STAR_SIZE * 0.4),
			}
			if star:IsA("ImageLabel") then
				goal.ImageTransparency = 1
			else
				goal.BackgroundTransparency = 1
			end
			TweenService:Create(star, TweenInfo.new(BURST_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
				:Play()
		end
		task.delay(BURST_TIME, function()
			for _, star in stars do
				star.Visible = false
			end
		end)
	end

	-- Starts / stops the CLAIM button's breathing while a milestone is ready.
	local function setBreathing(on: boolean)
		local current = breathing
		if on and current == nil and not OfferFx.reducedMotion() then
			claimScale.Scale = 1
			local tween = TweenService:Create(claimScale, BREATHE, { Scale = 1.05 })
			breathing = tween
			tween:Play()
		elseif not on and current ~= nil then
			current:Cancel()
			breathing = nil
			claimScale.Scale = 1
		end
	end

	-- Re-renders from the profile (server push / client copy). Never yields.
	local function update(profile: any)
		local pets = if type(profile) == "table" and type(profile.pets) == "table" then profile.pets else {}
		local index = if type(pets.index) == "table" then pets.index else {}
		local claimedSet = if type(pets.indexClaimed) == "table" then pets.indexClaimed else {}
		local found = PetIndexConfig.discovered(index)
		local ready = PetIndexConfig.claimable(pets)
		readyNow = ready[1]

		-- Juice for milestones that turned claimed since the last update.
		local seen: { [string]: boolean } = {}
		for _, milestone in PetIndexConfig.Milestones do
			if PetIndexConfig.isClaimed(claimedSet, milestone) then
				seen[milestone.id] = true
				local previous = lastClaimed
				if previous ~= nil and not previous[milestone.id] and frame.Visible then
					celebrate(milestone)
				end
			end
		end
		lastClaimed = seen

		bonusLabel.Text = `{PetIndexConfig.formatBonus(PetIndexConfig.bonus(claimedSet))} cash`
		for position, milestone in PetIndexConfig.Milestones do
			local state = if seen[milestone.id] then "claimed" elseif found >= milestone.need then "ready" else "locked"
			local pip = pips[position]
			if pip.state ~= state then
				pip.state = state
				pip.surface.setColor(PIP_COLOR[state])
			end
		end

		-- The bar always tracks the next milestone NOT REACHED yet (a ready one is the button's
		-- job), so it never reads "29 / 5"; once every milestone is reached it shows found / Total.
		local ahead: PetIndexConfig.Milestone? = nil
		for _, milestone in PetIndexConfig.Milestones do
			if found < milestone.need and not seen[milestone.id] then
				ahead = milestone
				break
			end
		end
		local goal = PetIndexConfig.nextGoal(pets)
		if ahead ~= nil then
			bar.setProgress(found / math.max(ahead.need, 1))
			barText.Text = `{found} / {ahead.need}`
		else
			bar.setProgress(1)
			barText.Text = `{found} / {PetIndexConfig.Total}`
		end
		if goal == nil then
			nextLabel.Text = "Every Index reward claimed!"
			PetUI.setButton(claim, "claimed", "ALL CLAIMED!")
		elseif readyNow ~= nil then
			nextLabel.Text = `Ready: {readyNow.gems} Gems + {readyNow.bonusPct}% cash`
			PetUI.setButton(claim, "normal", `CLAIM +{readyNow.gems} GEMS`)
		else
			nextLabel.Text = `Next: {goal.gems} Gems + {goal.bonusPct}% cash`
			PetUI.setButton(claim, "locked", `FIND {math.max(0, goal.need - found)} MORE`)
		end
		setBreathing(readyNow ~= nil and frame.Visible)
	end

	return {
		frame = frame,
		claimButton = claim.instance,
		update = update,
		Destroy = function()
			setBreathing(false)
			frame:Destroy()
		end,
	}
end

return table.freeze(IndexRewards)
