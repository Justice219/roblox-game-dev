--!strict
--[[
	PassBanner — the wide NUKE PASS banner at the top of the Quests screen (owner R78 spec §1 + §2):
	a stud strip with the pass icon, "NUKE PASS · SEASON 1", the tier reached, the XP bar with
	"120 / 400 XP", the season name + "Ends in 12d 03:04:05", and an OPEN button (red badge = pass
	rewards waiting) that opens screen "NukePass" as a handoff (owner R79: Quests hides while the
	pass is up and comes back when it closes; B returns to Quests).

	Between seasons: the next season's name + "Starts in ..." when one is scheduled (OPEN still
	opens the pass screen, which shows the coming season), else "Season N is coming soon!" (or
	"Nuke Pass coming soon!" before the pass ships) with OPEN locked.

	Compact layout (phones, ResponsiveModal mode "wide"; the screen moves the banner to the top of
	its left rail): one big pass button ("PASS · T3" / "NUKE PASS" / "SOON", >= 44 pt, red badge) on
	the purple card, so every row of the list keeps the full window height. The XP bar, season name
	and countdowns live on the NukePass screen it opens.

	Display only (Client/Quests/PassBridge reads PassConfig). Lives inside Screens/Quests (a
	ModuleScript folder): never registered as a screen.

	Connects to: Kit/StudUI (text, icon, button, progressBar, countdown), Widgets/StudWindow,
	UI/Create, UI/ScreenManager (open "NukePass"), Client/Quests/PassBridge (Info). Used by
	Screens/Quests/init.

	Example:
		local banner = PassBanner.new(window.body, 1)
		banner.layout(130, 64, 10, false, 10)
		banner.set(QuestClient.view().pass)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Parent.Create)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PassBridge = require(script.Parent.Parent.Parent.Parent.Quests.PassBridge)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type Banner = {
	frame: Frame,
	open: StudUI.Button,
	set: (info: PassBridge.Info) -> (),
	-- textFloor: the scaled labels' floor in RENDERED px (14 on touch, else 10).
	layout: (height: number, buttonHeight: number, minText: number, compact: boolean, textFloor: number) -> (),
}

local PassBanner = {}

local PAD = 16
local OPEN_WIDTH = 200
-- The pass icon: P-pass's own key when it ships, else a star.
local ICON_KEYS = { "NukePass", "Star" }

-- A right-aligned, scaled countdown label with a fixed prefix (StudUI's shared 1 Hz ticker).
local function countdownLabel(parent: Instance, prefix: string, doneText: string): StudUI.Countdown
	local countdown = StudUI.countdown({
		endsAt = 0,
		format = "auto",
		prefix = prefix,
		doneText = doneText,
		textSize = 24,
		color = UIStyleConfig.Neutral.TextDim,
		size = UDim2.fromScale(0.42, 0.28),
		parent = parent,
	})
	local label = countdown.label
	label.AnchorPoint = Vector2.new(1, 0)
	label.Position = UDim2.fromScale(1, 0.4)
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.TextScaled = true
	label.ZIndex = 4
	label.Visible = false
	Create.new("UITextSizeConstraint", { MaxTextSize = 24, MinTextSize = 10, Parent = label })
	return countdown
end

--[[
	Builds the banner inside `parent` (a vertical list).
	@param parent the window body
	@param order  LayoutOrder
	@param onOpen optional: called with the OPEN button just before the Nuke Pass opens (Quests
	              remembers it so the gamepad lands on it again when the pass closes, owner R79)
	@return Banner
]]
function PassBanner.new(parent: Instance, order: number, onOpen: ((button: GuiObject) -> ())?): Banner
	local frame = Create.new("Frame", {
		Name = "PassBanner",
		Size = UDim2.new(1, 0, 0, 130),
		BackgroundColor3 = UIStyleConfig.Neutral.Body,
		LayoutOrder = order,
		Parent = parent,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 14) }) },
	}) :: Frame
	StudWindow.edge(frame, 4)
	StudWindow.surface(frame, "purple", { corner = 14, scroll = true })

	local iconKey = ICON_KEYS[#ICON_KEYS]
	for _, key in ICON_KEYS do
		if StudUI.hasIcon(key) then
			iconKey = key
			break
		end
	end
	local icon = StudUI.icon(iconKey, 96, 3)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.new(0, PAD, 0.5, 0)
	icon.Parent = frame

	local column = Create.new("Frame", {
		Name = "Text",
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = frame,
	}) :: Frame
	local title = StudUI.text({
		name = "Title",
		text = "NUKE PASS",
		textSize = 40,
		font = "shout",
		scaled = true,
		align = Enum.TextXAlignment.Left,
		size = UDim2.fromScale(0.62, 0.4),
		zIndex = 4,
		parent = column,
	})
	local tierLabel = StudUI.text({
		name = "Tier",
		text = "",
		textSize = 34,
		font = "number",
		scaled = true,
		align = Enum.TextXAlignment.Right,
		anchor = Vector2.new(1, 0),
		position = UDim2.fromScale(1, 0),
		size = UDim2.fromScale(0.36, 0.4),
		zIndex = 4,
		parent = column,
	})
	local subtitle = StudUI.text({
		name = "Subtitle",
		text = "",
		textSize = 24,
		scaled = true,
		align = Enum.TextXAlignment.Left,
		color = UIStyleConfig.Neutral.TextDim,
		position = UDim2.fromScale(0, 0.4),
		size = UDim2.fromScale(0.56, 0.28),
		zIndex = 4,
		parent = column,
	})
	local endsCountdown = countdownLabel(column, "Ends in ", "a moment")
	local startsCountdown = countdownLabel(column, "Starts in ", "a moment")
	local bar = StudUI.progressBar({ color = "yellow", parent = column })
	bar.frame.AnchorPoint = Vector2.new(0, 1)
	bar.frame.Position = UDim2.fromScale(0, 1)
	bar.frame.ZIndex = 4
	local xpLabel = StudUI.text({
		name = "Xp",
		text = "",
		textSize = 22,
		font = "number",
		scaled = true,
		anchor = Vector2.new(0.5, 1),
		position = UDim2.fromScale(0.5, 1),
		zIndex = 6,
		parent = column,
	})

	-- The OPEN button's instance (set right after it is built; read by its own press handler).
	local openInstance: GuiObject? = nil
	local open = StudUI.button({
		text = "OPEN",
		color = "yellow",
		size = UDim2.fromOffset(OPEN_WIDTH, 64),
		textSize = 32,
		anchor = Vector2.new(1, 0.5),
		position = UDim2.new(1, -PAD, 0.5, 0),
		name = "OpenPass",
		parent = frame,
		onActivated = function()
			local pressed = openInstance
			if onOpen ~= nil and pressed ~= nil then
				onOpen(pressed)
			end
			-- Owner R79: Quests hides while the Nuke Pass is up and comes back when it closes.
			ScreenManager.handoff("Quests", "NukePass", { source = "quests" })
		end,
	})
	open.instance.ZIndex = 5
	openInstance = open.instance
	local badge = Create.new("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(38, 38),
		BackgroundColor3 = UIStyleConfig.Colors.red.bottom,
		Visible = false,
		ZIndex = 8,
		Parent = open.instance,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
	}) :: Frame
	StudWindow.edge(badge, 3)
	local badgeText = StudUI.text({
		name = "BadgeText",
		text = "",
		textSize = 24,
		size = UDim2.fromScale(1, 1),
		zIndex = 9,
		parent = badge,
	})

	-- What the banner shows (set) and how it is laid out (layout); `refresh` applies both.
	local compact = false
	local inSeason = false
	local hasEnd = false
	local hasStart = false
	local endsAt: number? = nil
	local startsAt: number? = nil
	local lastInfo: PassBridge.Info? = nil
	local apply: (info: PassBridge.Info) -> ()

	-- Places + shows the lines for the current mode / state.
	local function refresh()
		local lineTop = if compact then 0.5 else 0.4
		title.Size = UDim2.fromScale(0.62, lineTop)
		tierLabel.Size = UDim2.fromScale(0.36, lineTop)
		bar.frame.Visible = inSeason
		xpLabel.Visible = inSeason
		-- Compact: the subtitle line only between seasons, in the bar's place, full width.
		subtitle.Visible = not compact or not inSeason
		local withCountdown = not compact and (hasEnd or hasStart)
		subtitle.Position = UDim2.fromScale(0, lineTop)
		subtitle.Size = UDim2.fromScale(if withCountdown then 0.56 else 1, if compact then 0.5 else 0.28)
		endsCountdown.label.Visible = not compact and inSeason and hasEnd
		startsCountdown.label.Visible = not compact and not inSeason and hasStart
	end

	-- Sizes everything for a banner height (design px) and the device's tap / text floors.
	local function place(height: number, buttonHeight: number, minText: number, isCompact: boolean, textFloor: number)
		compact = isCompact
		icon.Visible = not isCompact
		column.Visible = not isCompact
		if isCompact then
			-- A rail card: the pass button fills it (the rail sets the width).
			frame.Size = UDim2.new(1, -8, 0, buttonHeight + 12)
			open.instance.AnchorPoint = Vector2.new(0.5, 0.5)
			open.instance.Position = UDim2.fromScale(0.5, 0.5)
			open.instance.Size = UDim2.new(1, -12, 0, buttonHeight)
		else
			frame.Size = UDim2.new(1, 0, 0, height)
			open.instance.AnchorPoint = Vector2.new(1, 0.5)
			open.instance.Position = UDim2.new(1, -PAD, 0.5, 0)
			open.instance.Size = UDim2.fromOffset(OPEN_WIDTH, buttonHeight)
		end
		local iconSize = math.floor(height * 0.74)
		icon.Size = UDim2.fromOffset(iconSize, iconSize)
		local left = PAD + iconSize + 14
		local inset = if isCompact then 6 else 12
		column.Position = UDim2.fromOffset(left, inset)
		column.Size = UDim2.new(1, -(left + OPEN_WIDTH + PAD * 2), 1, -inset * 2)
		local barHeight = math.max(22, minText + 6)
		bar.frame.Size = UDim2.new(1, 0, 0, barHeight)
		xpLabel.Size = UDim2.new(1, 0, 0, barHeight)
		for _, label in { title, tierLabel, subtitle, xpLabel, endsCountdown.label, startsCountdown.label } do
			local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
			if constraint ~= nil then
				constraint.MinTextSize = math.min(textFloor, constraint.MaxTextSize)
			end
		end
		local info = lastInfo
		if info ~= nil then
			apply(info)
		else
			refresh()
		end
	end
	place(130, 64, 10, false, 10)

	-- Writes the texts / state for `info` (also re-run after a layout change: compact texts differ).
	apply = function(info: PassBridge.Info)
		inSeason = info.season
		hasEnd = info.season and info.endsAt ~= nil
		hasStart = not info.season and info.startsAt ~= nil
		if info.season then
			title.Text = if info.number ~= nil then `NUKE PASS · SEASON {info.number}` else "NUKE PASS"
			tierLabel.Text = `TIER {info.tier}`
			subtitle.Text = info.name
			bar.setProgress(info.xpInto / math.max(1, info.xpPer))
			xpLabel.Text = `{NumberFormat.commas(info.xpInto)} / {NumberFormat.commas(info.xpPer)} XP`
			open.setState("normal")
			open.setText(if compact then `PASS · T{info.tier}` else "OPEN")
			badge.Visible = info.claimable > 0
			badgeText.Text = if info.claimable > 9 then "9+" else tostring(info.claimable)
			local ends = info.endsAt
			if ends ~= nil and ends ~= endsAt then
				endsAt = ends
				endsCountdown.setEndsAt(ends)
			end
		else
			local starts = info.startsAt
			if starts ~= nil then
				-- The next season is scheduled: its name + a start countdown; OPEN previews it.
				title.Text = if info.number ~= nil then `NUKE PASS · SEASON {info.number}` else "NUKE PASS"
				tierLabel.Text = ""
				subtitle.Text = if compact then `{info.name} starts soon!` else info.name
				open.setState("normal")
				open.setText(if compact then "NUKE PASS" else "OPEN")
				if starts ~= startsAt then
					startsAt = starts
					startsCountdown.setEndsAt(starts)
				end
			else
				title.Text = "NUKE PASS"
				tierLabel.Text = ""
				subtitle.Text = if not info.available
					then "Nuke Pass coming soon!"
					elseif info.number ~= nil then `Season {info.number} is coming soon!`
					else "The next season is coming soon!"
				open.setState("locked", "SOON")
			end
			badge.Visible = false
		end
		refresh()
	end

	return {
		frame = frame,
		open = open,
		set = function(info: PassBridge.Info)
			lastInfo = info
			apply(info)
		end,
		layout = place,
	}
end

return table.freeze(PassBanner)
