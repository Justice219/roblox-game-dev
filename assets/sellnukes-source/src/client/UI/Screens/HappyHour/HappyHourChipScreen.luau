--!strict
--[[
	HappyHourChipScreen — the Happy Hours HUD pill (owner R89 §2 + the R92 Studio pass,
	docs/happy-hours.md):

		[star] LIVE: CONFETTI 3:12        or        [star] SPRINKLES IN 15:40
		[star] 3:12                       phone (owner R138: the countdown only, event colour)

	Purpose:
		A separate NON-modal screen (the HUD file stays untouched): one compact stud pill that says
		what is on / next. Tap / click / gamepad-select opens the schedule panel
		(HappyHourScheduleScreen). Live = the event's colour, next = blue. Copy + size + placement
		are pure (HappyHour/HappyHourChipLogic).

	Size: ~52 design px tall on desktop / tablet / console; on a PHONE 72 (a >= 44 pt tap target,
	>= 14 pt text) and ONLY while an event is live — the NEXT state is hidden there (it would sit
	over the character) — showing just the countdown (R138: the full line was a third of an iPhone
	screen).

	Placement (HappyHourChipLogic.place): clear of every HudZones zone (Top / Left / Right /
	Bottom / TopRight), the Roblox top-bar buttons (GuiService.TopbarInset), the R82 boost badge
	(HudCurrency.corner()) and the admin wrench chip: top-left above the left grid on desktop /
	tablet / console (then top-right, then under the currency stack); on phones beside the currency
	stack in the top band (right, then left, R138), then under the INVITE row, then under the stack.
	The winning spot is published as the ScreenGui attribute HappyHourChipSpot (QA). When nothing fits cleanly the pill stays hidden (the start banner
	still announces the event). Re-placed on HudZones / layout / badge changes and every few
	seconds while visible (a boost badge can appear without a zone change).

	Visibility: hidden while ANY modal is open (ScreenManager.Opened / Closed + anyModalOpen, like
	the HUD's MenuLayer), during focus mode (egg hatch, loading), during the guided first-minute
	tutorial, while a centre popup is up (owner R102: UI/Widgets/PopupQueue's chip channel, kind
	"happyHourChip" — reason "popup") and when there is nothing to show (Happy Hours off / kill
	switch / a phone between events). The reason is published as the ScreenGui attribute
	HappyHourChipHidden (QA). While shown, the pill publishes its rect to PopupQueue so the moving
	Lucky Button arrow steers around it.

	Updates: redraws on HappyHourClient.Changed and once per second ONLY while a countdown is on
	screen (live, or the next event within the hour); no loop otherwise.

	Input (owner R11): a StudUI button — mouse click, touch tap and gamepad selection (reachable
	with the D-pad from the HUD; A opens) all open the schedule; no new key binding.

	Connects to: HappyHour/{HappyHourClient, HappyHourChipLogic}, UI/{ScreenManager, Kit/StudUI,
	Create, Hud/HudCurrency, Widgets/{HudZones, GuiFade, LoadingGate, PopupQueue}},
	Analytics/ClientAnalytics,
	Shared/Config/{HappyHourConfig, HudFocusConfig, FtueConfig}.

	Example: ScreenManager.isOpen("HappyHourChip") --> true (auto-open)
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ClientAnalytics = require(script.Parent.Parent.Parent.Parent.Analytics.ClientAnalytics)
local ClientState = require(script.Parent.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Parent.Create)
local FtueConfig = require(ReplicatedStorage.Shared.Config.FtueConfig)
local GuiFade = require(script.Parent.Parent.Parent.Widgets.GuiFade)
local HappyHourChipLogic = require(script.Parent.Parent.Parent.Parent.HappyHour.HappyHourChipLogic)
local HappyHourClient = require(script.Parent.Parent.Parent.Parent.HappyHour.HappyHourClient)
local HappyHourConfig = require(ReplicatedStorage.Shared.Config.HappyHourConfig)
local HudCurrency = require(script.Parent.Parent.Parent.Hud.HudCurrency)
local HudFocusConfig = require(ReplicatedStorage.Shared.Config.HudFocusConfig)
local HudZones = require(script.Parent.Parent.Parent.Widgets.HudZones)
local LoadingGate = require(script.Parent.Parent.Parent.Widgets.LoadingGate)
local PopupQueue = require(script.Parent.Parent.Parent.Widgets.PopupQueue)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)

local NAME = "HappyHourChip"
local SCHEDULE = "HappyHourSchedule"
local Client = HappyHourConfig.Client
-- Seconds between re-placements while visible (boost badge appearing / disappearing).
local REPLACE_SECONDS = 4
-- ScreenGui attribute naming why the pill is hidden ("" = shown; QA probe).
local HIDDEN_ATTRIBUTE = "HappyHourChipHidden"
-- This pill's PopupQueue kind (owner R102 chip channel).
local CHIP_KIND = "happyHourChip"

local localPlayer = Players.LocalPlayer

-- A player-local clock string ("4:00 PM") for a unix time.
local function localTime(unix: number): string
	local ok, text = pcall(function(): string
		return DateTime.fromUnixTimestamp(math.floor(unix)):FormatLocalTime("LT", "en-us")
	end)
	return if ok then text else os.date("%H:%M", math.floor(unix))
end

-- True while the player is on a guided first-minute tutorial step.
local function inGuidedTutorial(): boolean
	local profile: any = ClientState.profile
	local tycoon = if type(profile) == "table" then profile.tycoon else nil
	return type(tycoon) == "table" and FtueConfig.isGuided(tycoon.tutorialStep)
end

-- True on a phone (the NEXT state is hidden there; the pill is taller).
local function isPhone(): boolean
	local device: any = ScreenManager.device
	return type(device) == "table" and device.isPhone == true
end

-- An absolute-px rect in this gui's design px (through the full-canvas `canvas` frame).
local function toDesign(position: Vector2, size: Vector2, canvas: Frame, canvasSize: Vector2): HappyHourChipLogic.Rect?
	local absolute = canvas.AbsoluteSize
	if absolute.X <= 0 or size.X <= 0 or size.Y <= 0 then
		return nil
	end
	local k = canvasSize.X / absolute.X
	local origin = (position - canvas.AbsolutePosition) * k
	return { x = origin.X, y = origin.Y, w = size.X * k, h = size.Y * k }
end

-- The design-px rect of a visible GuiObject.
local function measure(object: GuiObject, canvas: Frame, canvasSize: Vector2): HappyHourChipLogic.Rect?
	if not object.Visible then
		return nil
	end
	return toDesign(object.AbsolutePosition, object.AbsoluteSize, canvas, canvasSize)
end

return {
	name = NAME,
	modal = false,
	autoOpen = true,
	displayOrder = 6,
	build = function(gui: ScreenGui): any
		-- Full-canvas, input-transparent frame: the measuring reference + the pill's parent.
		local canvas = Create.new("Frame", {
			Name = "HappyHourCanvas",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Active = false,
			Parent = gui,
		}) :: Frame
		local button = StudUI.button({
			text = "",
			color = "blue",
			name = "HappyHourChip",
			size = UDim2.fromOffset(300, Client.PillHeight),
			parent = canvas,
			onActivated = function()
				if not ScreenManager.isOpen(SCHEDULE) then
					ScreenManager.open(SCHEDULE, { source = "chip" })
					ClientAnalytics.screenOpened("HappyHours", "chip")
				end
			end,
		})
		local chip = button.instance
		chip.Visible = false
		local face = (chip:FindFirstChild("Face") :: GuiObject?) or chip
		-- The star, sized per device (Studio QA reads Title for the text).
		local icons: { [string]: Frame } = {}
		local iconKey = ""
		local iconSize = 0
		local function showIcon(key: string, size: number)
			if iconKey == key and iconSize == size then
				return
			end
			for _, frame in icons do
				frame:Destroy()
			end
			table.clear(icons)
			local icon = StudUI.icon(key, size, 5)
			icon.AnchorPoint = Vector2.new(0, 0.5)
			icon.Position = UDim2.new(0, Client.PillPadding, 0.5, 0)
			icon.Parent = face
			icons[key] = icon
			iconKey, iconSize = key, size
		end
		local title = StudUI.text({
			name = "Title",
			text = "",
			textSize = Client.PillTextSize,
			font = "shout",
			scaled = true,
			align = Enum.TextXAlignment.Left,
			zIndex = 5,
			parent = face,
		})

		local shown = false
		local hasContent = false
		local ticking = false
		local placedAt = 0
		local lastColor = ""
		local lastText = ""
		local lastPhone: boolean? = nil
		local wantedSize = Vector2.new(300, Client.PillHeight)
		-- The last placed rect (design px), published to PopupQueue while the pill shows.
		local placedRect: HappyHourChipLogic.Rect? = nil

		-- Measured obstacles: the Roblox top-bar buttons, the boost badge (R82) and the admin chip.
		local function obstacles(canvasSize: Vector2): { HappyHourChipLogic.Rect }
			local list: { HappyHourChipLogic.Rect } = {}
			-- GuiService.TopbarInset = the free top-bar band; Roblox's buttons sit left of Min.X and
			-- right of Max.X above Max.Y (screen px, the same space as AbsolutePosition here).
			local inset = GuiService.TopbarInset
			local camera = Workspace.CurrentCamera
			local screenX = if camera ~= nil then camera.ViewportSize.X else inset.Max.X
			if inset.Max.Y > 0 then
				local leftButtons =
					toDesign(Vector2.zero, Vector2.new(math.max(inset.Min.X, 1), inset.Max.Y), canvas, canvasSize)
				if leftButtons ~= nil then
					table.insert(list, leftButtons)
				end
				local rightButtons = toDesign(
					Vector2.new(inset.Max.X, 0),
					Vector2.new(math.max(screenX - inset.Max.X, 1), inset.Max.Y),
					canvas,
					canvasSize
				)
				if rightButtons ~= nil then
					table.insert(list, rightButtons)
				end
			end
			local corner = HudCurrency.corner()
			if corner ~= nil then
				for _, child in corner:GetChildren() do
					if child:IsA("GuiObject") then
						local rect = measure(child, canvas, canvasSize)
						if rect ~= nil then
							table.insert(list, rect)
						end
					end
				end
			end
			local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
			local admin = if playerGui ~= nil then playerGui:FindFirstChild("AdminChip", true) else nil
			if admin ~= nil and admin:IsA("GuiObject") then
				local holderGui = admin:FindFirstAncestorOfClass("ScreenGui")
				if holderGui == nil or holderGui.Enabled then
					local rect = measure(admin, canvas, canvasSize)
					if rect ~= nil then
						table.insert(list, rect)
					end
				end
			end
			return list
		end

		-- Places the pill; false when nothing fits cleanly (it then stays hidden).
		local function place(): boolean
			local canvasSize = ScreenManager.canvasSize(gui)
			local zones: { [string]: HappyHourChipLogic.Rect? } = {
				Top = HudZones.rect("Top"),
				Left = HudZones.rect("Left"),
				Right = HudZones.rect("Right"),
				Bottom = HudZones.rect("Bottom"),
				TopRight = HudZones.rect("TopRight"),
			}
			local rect, spot = HappyHourChipLogic.place({
				canvas = canvasSize,
				safeTop = ScreenManager.safeTop(0),
				size = wantedSize,
				gap = Client.ChipGap,
				zones = zones,
				obstacles = obstacles(canvasSize),
				phone = isPhone(),
			})
			placedAt = os.clock()
			placedRect = rect
			gui:SetAttribute("HappyHourChipSpot", spot) -- QA: which candidate won (R138)
			if rect == nil then
				return false
			end
			chip.AnchorPoint = Vector2.zero
			chip.Position = UDim2.fromOffset(rect.x, rect.y)
			if shown then
				PopupQueue.setChipRect(CHIP_KIND, rect)
			end
			return true
		end

		-- Shows / hides the pill (fade with the HUD focus timings).
		local function setShown(want: boolean)
			if want == shown and chip.Visible == want and not GuiFade.isFading(chip) then
				return
			end
			shown = want
			PopupQueue.setChipRect(CHIP_KIND, if want then placedRect else nil)
			if gui.Enabled then
				GuiFade.setShown(
					chip,
					want,
					if want then HudFocusConfig.FadeInSeconds else HudFocusConfig.FadeOutSeconds
				)
			else
				GuiFade.cancel(chip)
				chip.Visible = want
			end
		end

		-- Applies a line of copy: size by device, icon, text (only what changed).
		local function applyText(text: HappyHourChipLogic.ChipText, phone: boolean)
			if text.text ~= lastText or phone ~= lastPhone then
				lastText = text.text
				lastPhone = phone
				local size = HappyHourChipLogic.size(text.text, phone)
				if size ~= wantedSize then
					placedAt = 0 -- a new width / height re-places now
				end
				wantedSize = size
				chip.Size = UDim2.fromOffset(wantedSize.X, wantedSize.Y)
				local icon = math.floor(wantedSize.Y * Client.PillIconFill)
				showIcon(text.icon, icon)
				local left = Client.PillPadding * 2 + icon
				title.Position = UDim2.fromOffset(left, 0)
				title.Size = UDim2.new(1, -(left + Client.PillPadding), 1, 0)
				title.TextSize = if phone then Client.PillTextSizePhone else Client.PillTextSize
				title.Text = text.text
			end
			if text.color ~= lastColor then
				lastColor = text.color
				button.setColor(text.color :: any)
			end
		end

		local startTicker: () -> ()

		-- Redraws the copy and visibility; starts the 1 Hz ticker when a countdown shows.
		local function render()
			local now = HappyHourClient.now()
			local live = HappyHourClient.live()
			local nextLive = HappyHourClient.nextEvent()
			local phone = isPhone()
			local text = HappyHourChipLogic.chipText(live, nextLive, now, phone, localTime)
			hasContent = text ~= nil
			if text ~= nil then
				applyText(text, phone)
			end
			local reason = if not hasContent
				then "content"
				elseif ScreenManager.anyModalOpen() then "modal"
				elseif ScreenManager.isFocusMode() then "focus"
				elseif inGuidedTutorial() then "tutorial"
				elseif PopupQueue.chipsHidden() then "popup"
				else ""
			-- Placement last: a pill that cannot sit clear of the HUD stays hidden.
			if reason == "" and (not shown or os.clock() - placedAt >= REPLACE_SECONDS) and not place() then
				reason = "space"
			end
			gui:SetAttribute(HIDDEN_ATTRIBUTE, reason)
			setShown(reason == "")
			if reason == "" and HappyHourChipLogic.countdownVisible(live, nextLive, now) then
				startTicker()
			end
		end

		-- One 1 Hz thread, alive only while the pill shows a countdown.
		startTicker = function()
			if ticking then
				return
			end
			ticking = true
			task.spawn(function()
				while shown and hasContent do
					task.wait(1)
					if not shown then
						break
					end
					local now = HappyHourClient.now()
					if
						not HappyHourChipLogic.countdownVisible(
							HappyHourClient.live(),
							HappyHourClient.nextEvent(),
							now
						)
					then
						break
					end
					render()
				end
				ticking = false
			end)
		end

		-- A layout change re-places now (or hides when there is no clean spot any more).
		local function replace()
			placedAt = 0
			if shown then
				render()
			end
		end

		HappyHourClient.Changed:Connect(render)
		ScreenManager.Opened:Connect(render)
		ScreenManager.Closed:Connect(render)
		ScreenManager.FocusChanged:Connect(render)
		ScreenManager.LayoutChanged:Connect(function()
			placedAt = 0
			render()
		end)
		LoadingGate.onDone(render)
		ClientState.ProfileChanged:Connect(function(_profile, fields: { string }?)
			-- Only a fresh snapshot or a tycoon change can end the guided tutorial.
			if fields == nil or table.find(fields, "tycoon") ~= nil then
				render()
			end
		end)
		HudZones.Changed:Connect(replace)
		HudCurrency.Changed:Connect(replace)
		-- R102: a centre popup came / went (chips yield while one is up).
		PopupQueue.Changed:Connect(function(what: string)
			if what == "center" then
				render()
			end
		end)

		return {
			onOpen = function()
				render()
			end,
			onClose = function()
				setShown(false)
			end,
		}
	end,
}
