--!strict
--[[
	BoostChipsScreen — the HUD boost BADGE on the cash counter (owner R82: "the two x cash UI can
	kind of be like a corner piece for the cash instead of it being like its own little pill on
	the bottom"). It replaced the R78 chip row under the currency stack; the module keeps its R78
	name ("BoostChips") so screen ids, QA tools and docs stay stable.

	Look: a small, slightly tilted stud sticker pinned to the top-right corner of the visible
	primary counter (Nuke Town's Cash, or the shown world's currency: boosts multiply every
	world's income). Big: the combined multiplier ("2x", "4x", "2.4x"; a Friend Boost alone reads
	"+20%"). Small: the timer of the boost that ends first ("1:25"), or "FRIENDS" when nothing is
	timed. Two or more boosts: a second sticker in the next boost's colour peeks out behind it.
	The rules (which boosts, combined number, timer pick, size, gap) are the pure
	Client/Social/BoostChipLogic (Lune-tested).

	Where it lives: the badge is parented into UI/Hud/HudCurrency's "BoostCorner" anchor, a
	zero-size frame on the number's top-right corner positioned by SCALE, so the engine keeps the
	badge on the digits' right end at any width ("608.05Sx", "1.23Dc") with no script work, and
	its left edge starts BoostChipLogic.cornerGap px right of the number's box (outline + edge +
	tilted corner), so it never covers a digit. Because it is inside the HUD's ScreenGui it is
	visible exactly when the counter is (loading, hatch, launch cinematic and every other focus
	moment hide it with the HUD; another world swaps the anchor to that world's counter).

	Breakdown: tapping / clicking the badge, or selecting it with a gamepad, opens a compact stud
	card under it (this screen's own ScreenGui, above the HUD): "BOOSTS  TOTAL 4x" and one row per
	boost with its icon, name and time left. It never takes input (Active = false everywhere: no
	invisible full-screen catcher over the thumbstick); a tap anywhere else, the badge again,
	gamepad B (drops the selection), a modal opening or BreakdownCloseSeconds close it. Opening it
	reports `open:Boosts` (ClientAnalytics, source "hud").

	Console / mobile (owner R11): the badge's hit area is >= 44 pt (TouchUIConfig.MinTapPoints)
	and extends only right / down of the sticker; on phones / tablets every text has a device-point
	floor (SocialConfig.Client BadgeSmallPoints / BreakdownPoints = 14 pt). Gamepad: the badge
	joins the HUD D-pad graph through HudCurrency.navExits() (Hud.relayout -> currency.linkNav):
	Up from the left grid's top-right button reaches it; from the badge Left goes back there,
	Right / Down to the first offer. While a modal is open it is not selectable.

	HudZones: the R78 "Boosts" zone is no longer published (the badge sits inside the "Top"
	zone's height band, so Toasts and the tutorial card keep their Top-based positions).

	Performance: event-driven refresh (profile / social / attribute / screen / HudCurrency
	signals, coalesced per frame); ONE 1 Hz tick only while a timed boost is active (badge timer,
	open breakdown's timers, its position); every Instance and Tween is built once, rows are
	pooled. No per-frame work.

	Non-modal, auto-open, discovered by UIController (a "...Screen" module in a Screens folder).

	Connects to: Client/Social/{SocialClient, BoostChipLogic}, Client/ClientState,
	Client/Analytics/ClientAnalytics, UI/{Create, ScreenManager, Kit/StudUI, Hud/HudCurrency,
	Widgets/{StudWindow, OfferFx}}, Shared/Config/{SocialConfig, BoostConfig, TouchUIConfig,
	UIStyleConfig}, Shared/Util/TouchLayout.

	Example: (automatic) a 2x Cash boost starts -> a green "2x / 14:59" sticker pops onto the
	cash counter's corner; tap it -> "BOOSTS TOTAL 2x" + "2x CASH 14:59".
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local BoostChipLogic = require(script.Parent.Parent.Parent.Parent.Social.BoostChipLogic)
local BoostConfig = require(ReplicatedStorage.Shared.Config.BoostConfig)
local ClientAnalytics = require(script.Parent.Parent.Parent.Parent.Analytics.ClientAnalytics)
local ClientState = require(script.Parent.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Parent.Create)
local HudCurrency = require(script.Parent.Parent.Parent.Hud.HudCurrency)
local OfferFx = require(script.Parent.Parent.Parent.Widgets.OfferFx)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local SocialClient = require(script.Parent.Parent.Parent.Parent.Social.SocialClient)
local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local NAME = "BoostChips"
local CLIENT = SocialConfig.Client
local TEXT = SocialConfig.Text
-- Icon shown while a boost's own icon is not uploaded yet.
local ICON_FALLBACK = "Star"
-- ClientAnalytics screen id of the breakdown (AnalyticsConfig.ClientFunnel.Screens).
local ANALYTICS_SCREEN = "Boosts"

-- One pooled breakdown row.
type Row = {
	frame: Frame,
	icon: Frame?,
	iconKey: string,
	name: TextLabel,
	time: TextLabel,
}

-- The device-dependent sizes of one refresh (design px).
type Sizes = {
	big: number, -- badge multiplier text
	small: number, -- badge timer text
	tap: number, -- minimum hit side (44 pt)
	rowText: number, -- breakdown row text
	titleText: number, -- breakdown title text
	k: number, -- breakdown growth factor (rowText / BreakdownText)
}

--[[
	Sets a scaled label's maximum text size (StudUI.text adds the UITextSizeConstraint once).
	@param label the label
	@param size  design px
]]
local function setMaxText(label: TextLabel, size: number)
	local limit = label:FindFirstChildOfClass("UITextSizeConstraint")
	if limit ~= nil and limit.MaxTextSize ~= size then
		limit.MaxTextSize = size
	end
	label.TextSize = size
end

--[[ The light accent colour of a preset (text on the dark rows), white for unknown names. ]]
local function accent(color: string): Color3
	local preset = (UIStyleConfig.Colors :: any)[color]
	return if preset ~= nil then preset.accent else UIStyleConfig.Neutral.Text
end

return {
	name = NAME,
	modal = false,
	autoOpen = true,
	displayOrder = 6,
	--[[
		Builds the badge (parked until a boost is active) and the breakdown card, and wires every
		refresh trigger.
		@param gui the screen's ScreenGui (hosts the breakdown; the badge lives in the HUD)
		@return ScreenHandle (empty: nothing to select inside this gui)
	]]
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		local root = Create.new("Frame", {
			Name = "BoostChipsRoot",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Active = false,
			Parent = gui,
		}) :: Frame

		-- ── Badge (built once; parented into HudCurrency's corner anchor while a boost is on) ──
		local badge = Create.new("TextButton", {
			Name = "BoostBadge",
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			Selectable = true,
			Visible = false,
			Size = UDim2.fromOffset(CLIENT.BadgeMinWidth, CLIENT.BadgeMinWidth),
			-- Invisible engine selection image: the Ring frame is the gamepad highlight.
			SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }),
		}) :: TextButton
		badge:SetAttribute("FeedbackKind", "Stars")
		-- Pop / hover scale. The badge is anchored top-left, so growing never moves its left edge
		-- towards the digits.
		local popScale = Create.new("UIScale", { Name = "PressScale", Scale = 1, Parent = badge }) :: UIScale
		local popUp = TweenService:Create(
			popScale,
			TweenInfo.new(CLIENT.BadgePopSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = CLIENT.BadgePopScale }
		)
		local popBack = TweenService:Create(
			popScale,
			TweenInfo.new(CLIENT.BadgePopSeconds * 2.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }
		)
		popUp.Completed:Connect(function(state: Enum.PlaybackState)
			if state == Enum.PlaybackState.Completed then
				popBack:Play()
			end
		end)
		-- 2+ boosts: the stacked sticker behind (next boost's colour, opposite tilt).
		local back = Create.new("Frame", {
			Name = "Back",
			Rotation = CLIENT.BadgeBackTilt,
			Active = false,
			Visible = false,
			ZIndex = 1,
			Parent = badge,
		}) :: Frame
		local backSurface = StudWindow.surface(back, "blue", {
			edge = CLIENT.BadgeEdge,
			corner = CLIENT.BadgeCorner,
			highlight = false,
			zIndex = 1,
		})
		local sticker = Create.new("Frame", {
			Name = "Sticker",
			Rotation = CLIENT.BadgeTilt,
			Active = false,
			ZIndex = 2,
			Parent = badge,
		}) :: Frame
		local stickerSurface = StudWindow.surface(sticker, "green", {
			edge = CLIENT.BadgeEdge,
			corner = CLIENT.BadgeCorner,
			highlight = true,
			zIndex = 2,
		})
		-- Gamepad selection ring: a white rounded outline just outside the sticker (tilts with it).
		local ring = Create.new("Frame", {
			Name = "Ring",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, CLIENT.BadgeRingThickness * 2 + 4, 1, CLIENT.BadgeRingThickness * 2 + 4),
			Active = false,
			Visible = false,
			ZIndex = 6,
			Parent = sticker,
			Children = {
				Create.new("UICorner", { CornerRadius = UDim.new(0, CLIENT.BadgeCorner + 4) }),
				Create.new("UIStroke", {
					Color = Color3.new(1, 1, 1),
					Thickness = CLIENT.BadgeRingThickness,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				}),
			},
		}) :: Frame
		local bigLabel = StudUI.text({
			name = "Multiplier",
			text = "",
			textSize = CLIENT.BadgeBigText,
			font = "shout",
			scaled = true,
			zIndex = 4,
			parent = sticker,
		})
		local smallLabel = StudUI.text({
			name = "Timer",
			text = "",
			textSize = CLIENT.BadgeSmallText,
			font = "number",
			scaled = true,
			zIndex = 4,
			parent = sticker,
		})

		-- ── Breakdown card (this gui; display only) ──
		local panel = Create.new("Frame", {
			Name = "Breakdown",
			Size = UDim2.fromOffset(CLIENT.BreakdownWidth, 120),
			Active = false,
			Visible = false,
			ZIndex = 2,
			Parent = root,
		}) :: Frame
		StudWindow.surface(panel, "blue", { edge = 4, corner = 12, highlight = true, zIndex = 2 })
		local title = StudUI.text({
			name = "Title",
			text = TEXT.BreakdownTitle,
			textSize = CLIENT.BreakdownTitleText,
			scaled = true,
			align = Enum.TextXAlignment.Left,
			zIndex = 5,
			parent = panel,
		})
		local total = StudUI.text({
			name = "Total",
			text = "",
			textSize = CLIENT.BreakdownTitleText,
			font = "number",
			scaled = true,
			align = Enum.TextXAlignment.Right,
			zIndex = 5,
			parent = panel,
		})
		local rows: { Row } = {}

		local shown: { BoostChipLogic.Chip } = {}
		local current: BoostChipLogic.Badge? = nil
		local sizes: Sizes? = nil
		local interactive = false
		local panelOpen = false
		local openToken = 0
		local tickToken = 0
		local refreshQueued = false
		local lastBadgeInput: InputObject? = nil
		-- The HUD button whose NextSelectionUp points at the badge, and the value it had before.
		local entry: GuiObject? = nil
		local entrySaved: GuiObject? = nil

		-- The active boosts right now (BoostChipLogic.chips over the live state).
		local function currentChips(now: number): { BoostChipLogic.Chip }
			local rush = SocialClient.rush()
			local live = SocialClient.live()
			local profile = ClientState.profile
			local serverEnds = ReplicatedStorage:GetAttribute(BoostConfig.Server.EndsAtAttribute)
			return BoostChipLogic.chips({
				now = now,
				rushOn = live.rushOn,
				friendsOn = live.friendsOn,
				rookieEndsAt = rush.rookieEndsAt,
				comebackEndsAt = rush.comebackEndsAt,
				rookieMultiplier = rush.rookieMultiplier,
				comebackMultiplier = rush.comebackMultiplier,
				friendPercent = SocialClient.friends().percent,
				boosts = if profile ~= nil then profile.boosts else nil,
				serverEndsAt = if type(serverEnds) == "number" then serverEnds else nil,
			})
		end

		-- This refresh's design-px sizes: config sizes, never under the device-point floors.
		local function measure(): Sizes
			local scale = ScreenManager.pointScale()
			local function floor(points: number): number
				return math.ceil(TouchLayout.pointsToDesign(points, scale))
			end
			local rowText = math.max(CLIENT.BreakdownText, floor(CLIENT.BreakdownPoints))
			local k = rowText / CLIENT.BreakdownText
			return {
				big = math.max(CLIENT.BadgeBigText, floor(CLIENT.BadgeBigPoints)),
				small = math.max(CLIENT.BadgeSmallText, floor(CLIENT.BadgeSmallPoints)),
				tap = floor(TouchUIConfig.MinTapPoints),
				rowText = rowText,
				titleText = math.max(CLIENT.BreakdownTitleText, math.ceil(CLIENT.BreakdownTitleText * k)),
				k = k,
			}
		end

		-- Puts icon `key` (or the fallback until it is uploaded) on a row.
		local function setIcon(row: Row, key: string, side: number)
			local wanted = if StudUI.hasIcon(key) then key else ICON_FALLBACK
			local existing = row.icon
			if row.iconKey == wanted and existing ~= nil then
				existing.Size = UDim2.fromOffset(side, side)
				return
			end
			if existing ~= nil then
				existing:Destroy()
			end
			local icon = StudUI.icon(wanted, side, 7)
			icon.AnchorPoint = Vector2.new(0, 0.5)
			icon.Position = UDim2.new(0, 6, 0.5, 0)
			icon.Parent = row.frame
			row.icon = icon
			row.iconKey = wanted
		end

		-- The pooled breakdown row #index (built on first use).
		local function rowAt(index: number): Row
			local existing = rows[index]
			if existing ~= nil then
				return existing
			end
			local frame = Create.new("Frame", {
				Name = `Row{index}`,
				BackgroundColor3 = UIStyleConfig.Neutral.Well,
				BackgroundTransparency = 0.2,
				BorderSizePixel = 0,
				Active = false,
				ZIndex = 5,
				Parent = panel,
				Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }) },
			}) :: Frame
			local name = StudUI.text({
				name = "Name",
				text = "",
				textSize = CLIENT.BreakdownText,
				scaled = true,
				align = Enum.TextXAlignment.Left,
				zIndex = 7,
				parent = frame,
			})
			local time = StudUI.text({
				name = "Time",
				text = "",
				textSize = CLIENT.BreakdownText,
				font = "number",
				scaled = true,
				align = Enum.TextXAlignment.Right,
				zIndex = 7,
				parent = frame,
			})
			local row: Row = { frame = frame, icon = nil, iconKey = "", name = name, time = time }
			rows[index] = row
			return row
		end

		-- Moves the breakdown under the badge's sticker, kept inside the canvas.
		local function placePanel()
			local scale = math.max(ScreenManager.pointScale(), 0.01)
			local canvas = ScreenManager.canvasSize(gui)
			local origin = root.AbsolutePosition
			local x = (sticker.AbsolutePosition.X - origin.X) / scale
			local y = (sticker.AbsolutePosition.Y + sticker.AbsoluteSize.Y - origin.Y) / scale + CLIENT.BreakdownGap
			local size = panel.Size
			local margin = CLIENT.BreakdownMargin
			x = math.clamp(x, margin, math.max(margin, canvas.X - size.X.Offset - margin))
			y = math.clamp(y, margin, math.max(margin, canvas.Y - size.Y.Offset - margin))
			panel.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
		end

		-- Fills / sizes the breakdown for the current boosts (texts at `now`).
		local function renderPanel(now: number)
			local info, s = current, sizes
			if info == nil or s == nil then
				return
			end
			local pad = math.ceil(CLIENT.BreakdownPad * s.k)
			local gap = math.ceil(CLIENT.BreakdownRowGap * s.k)
			local width = math.ceil(CLIENT.BreakdownWidth * s.k)
			local titleH = math.ceil(s.titleText * 1.35)
			local rowH = math.ceil(s.rowText * 1.6)
			local iconSide = rowH - 8
			-- The time column fits "23:59:59" (personal boosts stack up to 24 h).
			local timeW = math.ceil(s.rowText * 0.62 * 8)
			title.Position = UDim2.fromOffset(pad + 4, pad)
			title.Size = UDim2.fromOffset(math.floor((width - pad * 2) * 0.45), titleH)
			setMaxText(title, s.titleText)
			total.Position = UDim2.fromOffset(math.floor(width / 2), pad)
			total.Size = UDim2.fromOffset(math.floor(width / 2) - pad - 4, titleH)
			total.Text = string.format(TEXT.BreakdownTotal, info.text)
			total.TextColor3 = accent("yellow")
			setMaxText(total, s.titleText)
			for index, chip in shown do
				local row = rowAt(index)
				row.frame.Visible = true
				row.frame.Position = UDim2.fromOffset(pad, pad + titleH + gap + (index - 1) * (rowH + gap))
				row.frame.Size = UDim2.fromOffset(width - pad * 2, rowH)
				setIcon(row, chip.icon, iconSide)
				row.name.Position = UDim2.fromOffset(6 + iconSide + 8, 0)
				row.name.Size = UDim2.new(1, -(6 + iconSide + 8 + timeW + 10), 1, 0)
				row.name.Text = chip.text
				setMaxText(row.name, s.rowText)
				row.time.Position = UDim2.new(1, -(timeW + 10), 0, 0)
				row.time.Size = UDim2.new(0, timeW, 1, 0)
				row.time.Text = BoostChipLogic.rowTime(chip, now)
				row.time.TextColor3 = accent(chip.color)
				setMaxText(row.time, s.rowText)
			end
			for index = #shown + 1, #rows do
				rows[index].frame.Visible = false
			end
			local height = pad * 2 + titleH + gap + #shown * (rowH + gap) - gap
			panel.Size = UDim2.fromOffset(width, height)
			placePanel()
		end

		-- Closes the breakdown (no-op when closed).
		local function closePanel()
			if not panelOpen then
				return
			end
			panelOpen = false
			openToken += 1
			panel.Visible = false
		end

		-- Opens the breakdown under the badge (only while the badge is interactive).
		local function openPanel()
			if panelOpen or not interactive or current == nil then
				return
			end
			panelOpen = true
			openToken += 1
			local token = openToken
			renderPanel(Workspace:GetServerTimeNow())
			panel.Visible = true
			ClientAnalytics.screenOpened(ANALYTICS_SCREEN, "hud")
			task.delay(CLIENT.BreakdownCloseSeconds, function()
				-- A gamepad player still on the badge is reading it: keep it open until they move.
				if token == openToken and GuiService.SelectedObject ~= badge then
					closePanel()
				end
			end)
		end

		-- Puts the badge into / takes it out of the HUD D-pad graph (HudCurrency.navExits).
		local function applyNav()
			local left, right = HudCurrency.navExits()
			local on = badge.Visible and interactive
			local previous = entry
			if previous ~= nil and (previous ~= left or not on) then
				-- Give the HUD button its own Up link back (only if it still points at us).
				local view: any = previous
				if view.NextSelectionUp == badge then
					view.NextSelectionUp = entrySaved
				end
				entry, entrySaved = nil, nil
			end
			-- `any` view: nil NextSelection* (engine default) is valid but typed non-optional.
			local button: any = badge
			if not on then
				button.NextSelectionLeft = nil
				button.NextSelectionRight = nil
				button.NextSelectionDown = nil
				return
			end
			button.NextSelectionLeft = left
			button.NextSelectionRight = right
			button.NextSelectionDown = right or left
			if left ~= nil then
				local view: any = left
				if view.NextSelectionUp ~= badge then
					entrySaved = view.NextSelectionUp
					view.NextSelectionUp = badge
				end
				entry = left
			end
		end

		local refresh: () -> ()
		local hudWatch: RBXScriptConnection? = nil

		-- True while the HUD screen is shown (its gui is enabled); watches it once it exists.
		local function hudShown(): boolean
			local hud = ScreenManager.getGui("Hud")
			if hud == nil then
				return false
			end
			if hudWatch == nil then
				hudWatch = hud:GetPropertyChangedSignal("Enabled"):Connect(function()
					refresh()
				end)
			end
			return hud.Enabled
		end

		-- 1 Hz while a timed boost is active: badge timer, the open breakdown; a boost that ran
		-- out re-evaluates everything.
		local function tick(token: number)
			while token == tickToken do
				local now = Workspace:GetServerTimeNow()
				for _, chip in shown do
					local ends = chip.endsAt
					if ends ~= nil and ends <= now then
						refresh()
						return
					end
				end
				local info = current
				if info ~= nil then
					smallLabel.Text = BoostChipLogic.badgeSmall(info, now)
				end
				if panelOpen then
					for index, chip in shown do
						local row = rows[index]
						if row ~= nil then
							row.time.Text = BoostChipLogic.rowTime(chip, now)
						end
					end
					placePanel()
				end
				task.wait(1)
			end
		end

		-- Hides the badge (and everything that hangs off it).
		local function hideBadge()
			shown, current = {}, nil
			interactive = false
			badge.Visible = false
			closePanel()
			applyNav()
		end

		-- Full evaluation + layout (event-driven; coalesced per frame by requestRefresh).
		refresh = function()
			tickToken += 1
			local anchor = HudCurrency.corner()
			local covered = false
			for _, name in CLIENT.HiddenWhileOpen do
				if ScreenManager.isOpen(name) then
					covered = true
					break
				end
			end
			local now = Workspace:GetServerTimeNow()
			local chips = if anchor ~= nil and not covered then currentChips(now) else {}
			local info = BoostChipLogic.badge(chips)
			if anchor == nil or info == nil then
				hideBadge()
				return
			end
			local wasHidden = not badge.Visible
			local previousText = if current ~= nil then current.text else nil
			shown, current = chips, info
			local s = measure()
			sizes = s
			if badge.Parent ~= anchor then
				badge.Parent = anchor
			end
			-- Sticker size from its two lines; the gap keeps the tilted corner off the digits.
			local small = BoostChipLogic.badgeSmall(info, now)
			local width, height = BoostChipLogic.badgeSize({
				big = info.text,
				small = small,
				bigSize = s.big,
				smallSize = s.small,
				padX = CLIENT.BadgePadX,
				padY = CLIENT.BadgePadY,
				charRatio = CLIENT.BadgeCharRatio,
				minWidth = CLIENT.BadgeMinWidth,
			})
			-- Both strokes (the number's outline, the sticker's edge) at their widest possible size
			-- (design px; a stroke the engine does not scale is wider than its design value on a
			-- small UI scale), plus air; cornerGap adds the tilted corner on top.
			local outline = anchor.Parent and anchor.Parent:FindFirstChild("TextOutline")
			local outlineWidth = if outline ~= nil and outline:IsA("UIStroke") then outline.Thickness else 6
			local strokes = (outlineWidth + CLIENT.BadgeEdge)
				* math.max(1, 1 / math.max(ScreenManager.pointScale(), 0.01))
			local gap = BoostChipLogic.cornerGap(width, height, CLIENT.BadgeTilt, CLIENT.BadgeAir + strokes)
			badge.Position = UDim2.fromOffset(gap, -CLIENT.BadgeRaise)
			badge.Size = UDim2.fromOffset(math.max(width, s.tap), math.max(height, s.tap))
			sticker.Size = UDim2.fromOffset(width, height)
			back.Size = UDim2.fromOffset(width, height)
			back.Position = UDim2.fromOffset(CLIENT.BadgeBackOffset, CLIENT.BadgeBackOffset)
			bigLabel.Position = UDim2.fromOffset(CLIENT.BadgePadX / 2, CLIENT.BadgePadY)
			bigLabel.Size = UDim2.new(1, -CLIENT.BadgePadX, 0, s.big)
			setMaxText(bigLabel, s.big)
			smallLabel.Position = UDim2.fromOffset(CLIENT.BadgePadX / 2, CLIENT.BadgePadY + s.big)
			smallLabel.Size = UDim2.new(1, -CLIENT.BadgePadX, 0, s.small)
			setMaxText(smallLabel, s.small)
			bigLabel.Text = info.text
			smallLabel.Text = small
			if stickerSurface.color() ~= info.color then
				stickerSurface.setColor(info.color :: any)
			end
			badge:SetAttribute("FeedbackColor", info.color)
			local second = info.second
			back.Visible = second ~= nil
			if second ~= nil and backSurface.color() ~= second.color then
				backSurface.setColor(second.color :: any)
			end
			badge.Visible = true
			-- Interactive only while the HUD shows and no modal window is open.
			interactive = hudShown() and not ScreenManager.anyModalOpen()
			badge.Selectable = interactive
			if not interactive then
				closePanel()
			end
			applyNav()
			if panelOpen then
				renderPanel(now)
			end
			-- Pop on appear / when the number changes (Reduce Motion: none).
			if (wasHidden or previousText ~= info.text) and not OfferFx.reducedMotion() then
				popBack:Cancel()
				popScale.Scale = 1
				popUp:Play()
			end
			if BoostChipLogic.nextChange(chips) ~= nil then
				task.spawn(tick, tickToken)
			end
		end

		-- Coalesces every trigger in a frame into ONE refresh.
		local function requestRefresh()
			if refreshQueued then
				return
			end
			refreshQueued = true
			task.defer(function()
				refreshQueued = false
				refresh()
			end)
		end

		-- ── Input ──
		badge.Activated:Connect(function()
			if not interactive then
				return
			end
			if panelOpen then
				closePanel()
			else
				openPanel()
			end
		end)
		badge.SelectionGained:Connect(function()
			ring.Visible = true
			openPanel()
		end)
		badge.SelectionLost:Connect(function()
			ring.Visible = false
			closePanel()
		end)
		badge.MouseEnter:Connect(function()
			if interactive and popUp.PlaybackState ~= Enum.PlaybackState.Playing then
				popBack:Cancel()
				popScale.Scale = 1.06
			end
		end)
		badge.MouseLeave:Connect(function()
			if popUp.PlaybackState ~= Enum.PlaybackState.Playing then
				popScale.Scale = 1
			end
		end)
		-- Remember the press that landed on the badge, so the "tap elsewhere" check below can
		-- tell it apart (the badge's own Activated toggles the card on release).
		badge.InputBegan:Connect(function(input: InputObject)
			lastBadgeInput = input
		end)
		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if not panelOpen then
				return
			end
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then
				return
			end
			if not processed then
				-- The press went to the world (no GUI took it): certainly not the badge.
				lastBadgeInput = nil
				closePanel()
				return
			end
			-- A GUI press: deferred, so the badge's own InputBegan for the same press has run.
			-- The marker is cleared after every check (Roblox reuses mouse InputObjects).
			task.defer(function()
				local onBadge = lastBadgeInput == input
				lastBadgeInput = nil
				if not onBadge then
					closePanel()
				end
			end)
		end)

		-- ── Refresh triggers ──
		SocialClient.Changed:Connect(requestRefresh)
		ClientState.ProfileChanged:Connect(function(_profile: ClientState.Profile, fields: { string }?)
			if fields == nil or table.find(fields, "boosts") ~= nil or table.find(fields, "rush") ~= nil then
				requestRefresh()
			end
		end)
		ReplicatedStorage:GetAttributeChangedSignal(BoostConfig.Server.EndsAtAttribute):Connect(requestRefresh)
		HudCurrency.Changed:Connect(function()
			-- The anchor appeared / moved worlds (needs a refresh), or Hud.relayout re-linked the
			-- HUD buttons (only the D-pad links need re-applying: cheap, immediate).
			if badge.Parent ~= HudCurrency.corner() then
				requestRefresh()
			else
				applyNav()
			end
		end)
		ScreenManager.Opened:Connect(requestRefresh)
		ScreenManager.Closed:Connect(requestRefresh)
		ScreenManager.FocusChanged:Connect(requestRefresh)
		ScreenManager.LayoutChanged:Connect(requestRefresh)
		ScreenManager.SafeAreaChanged:Connect(requestRefresh)
		requestRefresh()
		return {}
	end,
} :: ScreenManager.ScreenModule
