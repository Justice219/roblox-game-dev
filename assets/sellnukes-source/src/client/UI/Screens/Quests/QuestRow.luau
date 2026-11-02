--!strict
--[[
	QuestRow — one row of the Quests screen (a goal, a mission, the Daily Chest or a trophy): a
	stud surface with the quest icon on the left, the title, the reward line and a progress bar +
	"3/5" counter in the middle, and the action button (CLAIM / GO / CLAIMED / LOCKED!) on the
	right; mission rows also get a small SWAP button (today's free reroll) left of it.

	Rows are built ONCE per tab when the screen first opens and only re-filled (`set`) on a
	`quests` push, so a push never rebuilds UI. `layout(metrics)` re-sizes for the device: on touch
	every button is at least the 44 pt tap and text at least 14 pt (ResponsiveModal metrics).

	Lives inside Screens/Quests (a ModuleScript folder): UIController never registers it as a screen.

	Connects to: Kit/StudUI (text, icon, button, progressBar), Widgets/StudWindow (surface, edge),
	UI/Create; used by Screens/Quests/init.

	Example:
		local row = QuestRow.new(list, 3, true)
		row.layout({ height = 104, buttonWidth = 210, buttonHeight = 64, title = 32, detail = 24, icon = 72, minText = 10 })
		row.set({ icon = "Egg", title = "Hatch an egg", detail = "20 Gems  +50 XP", progress = 1,
			progressText = "1/1", color = "green", action = { text = "CLAIM", color = "green", state = "normal" } })
		row.button.setCallback(function() QuestClient.claim("starter", 8) end)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Parent.Create)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type Action = {
	text: string,
	color: StudUI.ColorName,
	state: StudUI.ButtonState,
}

export type Data = {
	icon: string,
	title: string,
	detail: string,
	progress: number?, -- 0..1 (nil hides the bar + counter)
	progressText: string?,
	color: StudUI.ColorName, -- the row surface
	action: Action,
	swap: boolean?, -- mission rows: show the SWAP (free reroll) button
	dim: boolean?, -- locked / finished rows read quieter
}

export type Metrics = {
	height: number, -- row height (design px)
	buttonWidth: number,
	buttonHeight: number,
	title: number, -- max title text size
	detail: number, -- max detail text size
	icon: number, -- icon slot size
	minText: number, -- smallest text the scaled labels may shrink to (14 pt on touch, else 10)
	compact: boolean?, -- phones: two lines (title; reward | bar | counter) instead of three
	-- The scaled labels' floor in RENDERED px (a UITextSizeConstraint counts AbsoluteSize units =
	-- device points on touch, not design px): 14 on touch (14 pt), else the kit's 10.
	textFloor: number?,
}

export type Row = {
	frame: Frame,
	button: StudUI.Button,
	swapButton: StudUI.Button?,
	set: (data: Data) -> (),
	layout: (metrics: Metrics) -> (),
	setVisible: (visible: boolean) -> (),
}

local QuestRow = {}

local PAD = 14 -- inner padding (design px)
local GAP = 12 -- gap between the icon / text column / buttons
local SWAP_WIDTH = 150 -- the SWAP button's width (design px)

--[[
	Builds a row inside `parent` (a list with a UIListLayout).
	@param parent  the list frame
	@param order   LayoutOrder
	@param hasSwap mission rows: build the SWAP button too
	@return Row
]]
--[[
	The stacked line heights of a row's text column (design px): title, reward line, progress bar.
	@return titleHeight, detailHeight, barHeight
]]
function QuestRow.lineHeights(metrics: Metrics): (number, number, number)
	local titleHeight = math.ceil(metrics.title * 1.2)
	local detailHeight = math.ceil(metrics.detail * 1.2)
	local barHeight = math.max(12, math.floor(metrics.detail * 0.6))
	return titleHeight, detailHeight, barHeight
end

--[[
	The row height that fits the text column (title + reward line + bar / counter + padding) and
	the buttons, so text never overlaps on a device with a big text floor (phones: 14 pt).
	Example: QuestRow.heightFor({ ..., title = 30, detail = 22, buttonHeight = 64 }) --> 104
]]
function QuestRow.heightFor(metrics: Metrics): number
	local titleHeight, detailHeight, barHeight = QuestRow.lineHeights(metrics)
	if metrics.compact == true then
		-- Two lines: the title, then reward | bar | counter side by side; the button sets the floor.
		local column = titleHeight + math.max(detailHeight, metrics.detail + 4) + 2
		return math.max(metrics.buttonHeight + 8, column + (PAD - 4) * 2)
	end
	local column = titleHeight + detailHeight + math.max(barHeight, metrics.detail + 4) + 4
	return math.max(104, metrics.buttonHeight + 28, column + (PAD - 4) * 2)
end

function QuestRow.new(parent: Instance, order: number, hasSwap: boolean): Row
	local frame = Create.new("Frame", {
		Name = `Row{order}`,
		Size = UDim2.new(1, -8, 0, 104),
		BackgroundColor3 = UIStyleConfig.Neutral.Body,
		LayoutOrder = order,
		Parent = parent,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 12) }) },
	}) :: Frame
	StudWindow.edge(frame, 3)
	local surface = StudWindow.surface(frame, "sky", {
		tile = UIStyleConfig.StudTile.Button,
		studTransparency = 0.82,
		corner = 12,
		highlight = false,
	})

	local iconSlot = Create.new("Frame", {
		Name = "IconSlot",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, PAD, 0.5, 0),
		Size = UDim2.fromOffset(72, 72),
		ZIndex = 3,
		Parent = frame,
	}) :: Frame
	local icon: Frame? = nil
	local iconKey = ""

	local column = Create.new("Frame", {
		Name = "Text",
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = frame,
	}) :: Frame
	local title = StudUI.text({
		name = "Title",
		text = "",
		textSize = 32,
		scaled = true,
		align = Enum.TextXAlignment.Left,
		size = UDim2.fromScale(1, 0.42),
		zIndex = 4,
		parent = column,
	})
	local detail = StudUI.text({
		name = "Detail",
		text = "",
		textSize = 24,
		scaled = true,
		align = Enum.TextXAlignment.Left,
		color = UIStyleConfig.Neutral.TextDim,
		size = UDim2.fromScale(1, 0.28),
		position = UDim2.fromScale(0, 0.42),
		zIndex = 4,
		parent = column,
	})
	local bar = StudUI.progressBar({ color = "green", parent = column })
	bar.frame.AnchorPoint = Vector2.new(0, 1)
	bar.frame.Position = UDim2.fromScale(0, 1)
	bar.frame.ZIndex = 4
	local counter = StudUI.text({
		name = "Counter",
		text = "",
		textSize = 24,
		font = "number",
		scaled = true,
		align = Enum.TextXAlignment.Right,
		anchor = Vector2.new(1, 1),
		position = UDim2.fromScale(1, 1),
		zIndex = 4,
		parent = column,
	})

	local button = StudUI.button({
		text = "CLAIM",
		color = "green",
		size = UDim2.fromOffset(210, 64),
		textSize = 30,
		anchor = Vector2.new(1, 0.5),
		position = UDim2.new(1, -PAD, 0.5, 0),
		name = "Action",
		parent = frame,
	})
	button.instance.ZIndex = 5

	local swapButton: StudUI.Button? = nil
	if hasSwap then
		local swap = StudUI.button({
			text = "SWAP",
			color = "blue",
			size = UDim2.fromOffset(SWAP_WIDTH, 64),
			textSize = 26,
			anchor = Vector2.new(1, 0.5),
			position = UDim2.new(1, -PAD - 210 - GAP, 0.5, 0),
			name = "Swap",
			parent = frame,
		})
		swap.instance.ZIndex = 5
		swap.instance.Visible = false
		swapButton = swap
	end

	local metrics: Metrics =
		{ height = 104, buttonWidth = 210, buttonHeight = 64, title = 32, detail = 24, icon = 72, minText = 10 }
	local showSwap = false

	-- Places the column between the icon and the visible buttons, and the bar + counter in it.
	local function place()
		frame.Size = UDim2.new(1, -8, 0, metrics.height)
		iconSlot.Size = UDim2.fromOffset(metrics.icon, metrics.icon)
		button.instance.Size = UDim2.fromOffset(metrics.buttonWidth, metrics.buttonHeight)
		local buttonsWidth = metrics.buttonWidth + GAP
		local swap = swapButton
		if swap ~= nil then
			swap.instance.Size = UDim2.fromOffset(SWAP_WIDTH, metrics.buttonHeight)
			swap.instance.Position = UDim2.new(1, -PAD - metrics.buttonWidth - GAP, 0.5, 0)
			swap.instance.Visible = showSwap
			if showSwap then
				buttonsWidth += SWAP_WIDTH + GAP
			end
		end
		local left = PAD + metrics.icon + GAP
		column.Position = UDim2.fromOffset(left, PAD - 4)
		column.Size = UDim2.new(1, -(left + buttonsWidth + PAD), 1, -(PAD - 4) * 2)
		title.TextSize = metrics.title
		detail.TextSize = metrics.detail
		counter.TextSize = metrics.detail
		-- Stacked in design px (never overlapping, whatever the device's text floor): title, the
		-- reward line under it, the bar + counter at the bottom. QuestRow.heightFor sizes the row.
		local titleHeight, detailHeight, barHeight = QuestRow.lineHeights(metrics)
		title.Size = UDim2.new(1, 0, 0, titleHeight)
		-- "400/400" fits at the detail size (≈ 0.62 em per glyph, 7 glyphs + slack); one line only
		-- (a scaled label would rather wrap "400/" over "400" than shrink).
		local counterWidth = math.ceil(metrics.detail * 5)
		counter.TextWrapped = false
		if metrics.compact == true then
			-- Phones: line 2 = reward (left 44 %) | bar | counter, all centred on one line.
			local lineHeight = math.max(detailHeight, metrics.detail + 4)
			local middle = titleHeight + lineHeight / 2
			-- Both lines centred vertically in the row.
			column.Position =
				UDim2.fromOffset(left, math.max(4, math.floor((metrics.height - titleHeight - lineHeight) / 2)))
			detail.Position = UDim2.fromOffset(0, titleHeight)
			detail.Size = UDim2.new(0.44, 0, 0, lineHeight)
			bar.frame.AnchorPoint = Vector2.new(0, 0.5)
			bar.frame.Position = UDim2.new(0.44, 10, 0, middle)
			bar.frame.Size = UDim2.new(0.56, -(counterWidth + 22), 0, barHeight)
			counter.AnchorPoint = Vector2.new(1, 0.5)
			counter.Position = UDim2.new(1, 0, 0, middle)
			counter.Size = UDim2.fromOffset(counterWidth, lineHeight)
		else
			detail.Position = UDim2.fromOffset(0, titleHeight)
			detail.Size = UDim2.new(1, 0, 0, detailHeight)
			bar.frame.AnchorPoint = Vector2.new(0, 1)
			bar.frame.Position = UDim2.fromScale(0, 1)
			bar.frame.Size = UDim2.new(1, -(counterWidth + 12), 0, barHeight)
			counter.AnchorPoint = Vector2.new(1, 1)
			counter.Position = UDim2.fromScale(1, 1)
			counter.Size = UDim2.fromOffset(counterWidth, metrics.detail + 4)
		end
		-- Scaled labels: max = the authored size, min = the device floor in rendered px (never above
		-- the max). The design-px boxes above already fit 14 pt text, so the box sets the size.
		for _, pair in { { title, metrics.title }, { detail, metrics.detail }, { counter, metrics.detail } } do
			local label = pair[1] :: TextLabel
			local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
			if constraint ~= nil then
				constraint.MaxTextSize = pair[2] :: number
				constraint.MinTextSize = math.min(metrics.textFloor or 10, pair[2] :: number)
			end
		end
	end
	place()

	return {
		frame = frame,
		button = button,
		swapButton = swapButton,
		set = function(data: Data)
			if data.icon ~= iconKey then
				iconKey = data.icon
				if icon ~= nil then
					icon:Destroy()
				end
				local created = StudUI.icon(if StudUI.hasIcon(data.icon) then data.icon else "Star", 72, 4)
				created.Size = UDim2.fromScale(1, 1)
				created.Parent = iconSlot
				icon = created
			end
			title.Text = data.title
			detail.Text = data.detail
			local hasBar = data.progress ~= nil
			bar.frame.Visible = hasBar
			counter.Visible = hasBar and data.progressText ~= nil
			if hasBar then
				bar.setProgress(data.progress :: number)
				counter.Text = data.progressText or ""
			end
			if surface.color() ~= data.color then
				surface.setColor(data.color)
			end
			frame.BackgroundTransparency = if data.dim then 0.25 else 0
			title.TextTransparency = if data.dim then 0.3 else 0
			button.setColor(data.action.color)
			-- Only a real CLAIM bursts coins with the claim sound (GO / KEEP GOING are plain presses;
			-- ButtonFeedback reads the attribute at press time).
			button.instance:SetAttribute("FeedbackKind", if data.action.text == "CLAIM" then "Coins" else "Stars")
			button.setState(data.action.state, data.action.text)
			if data.action.state == "normal" then
				button.setText(data.action.text)
			end
			local wantSwap = data.swap == true and swapButton ~= nil
			if wantSwap ~= showSwap then
				showSwap = wantSwap
				place()
			end
		end,
		layout = function(next_: Metrics)
			metrics = next_
			place()
		end,
		setVisible = function(visible: boolean)
			frame.Visible = visible
		end,
	}
end

return table.freeze(QuestRow)
