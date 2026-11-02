--!strict
--[[
	JuiceBanner — the centre celebration banner + the soft rebirth flash (owner R71 juice).

	Banner ("JuiceBanner", non-modal screen above the HUD, below windows): a stud card (owner rule
	2) with a small producer line, a big shout ("LEVEL 50!") and the reward line ("x2 SPEED!").
	It pops in with a springy scale, holds JuiceConfig.Milestone.BannerSeconds and pops out.
	WHEN + WHERE (owner R102): every show asks UI/Widgets/PopupQueue's centre lane for a slot —
	kind "juice" (milestones) or "happyHour" (the Happy Hours start banner; owner R120 removed the
	centre Lucky Nuke shout — Lucky Nukes are bottom-left feed pills now) — so it never overlaps
	the reveal card or another banner: it waits its turn (or
	expires), a newer milestone still replaces it after the 0.5 s BannerCooldown, a more important
	popup pre-empts it (it comes back with its full hold). It sits at the top of the queue's free
	band (just under the currency stack, measured), so it never covers the cash counter, the
	objective chip or the hint bar. Display only: never Active, never Selectable, so gamepad / touch
	input is untouched.

	Flash ("JuiceFlash", full-bleed, safeArea = false): a warm white overlay that fades in fast and
	out softly on a rebirth (peak opacity JuiceConfig.Rebirth.FlashPeak, owner R19 — never a hard
	white frame). Reduce Motion: no flash, and the banner appears without the scale punch.

	Everything is built once by ScreenManager (design px, AutoScale, TV-safe padding); the four
	tweens are created once and replayed.

	Connects to: UI/{ScreenManager, Kit/StudUI, Widgets/PopupQueue, Widgets/OfferFx},
	Shared/Config/{JuiceConfig, PopupQueueConfig, UIStyleConfig}, callers JuiceController /
	ProducerJuice / HappyHour/HappyHourClient.

	Example:
		JuiceBanner.register(playerGui)
		JuiceBanner.show("Pocket Nuke Workbench", "LEVEL 50!", "x2 SPEED!", "cyan")
		JuiceBanner.show("NUKEY'S HAPPY HOUR", "CONFETTI STORM!", "Grab the coins!", "pink", 5, "happyHour")
		JuiceBanner.flash()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local JuiceConfig = require(ReplicatedStorage.Shared.Config.JuiceConfig)
local PopupQueueConfig = require(ReplicatedStorage.Shared.Config.PopupQueueConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local Create = require(script.Parent.Parent.Parent.UI.Create)
local OfferFx = require(script.Parent.Parent.Parent.UI.Widgets.OfferFx)
local PopupQueue = require(script.Parent.Parent.Parent.UI.Widgets.PopupQueue)
local ScreenManager = require(script.Parent.Parent.Parent.UI.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.UI.Kit.StudUI)

local JuiceBanner = {}

local BANNER = "JuiceBanner"
local FLASH = "JuiceFlash"
local CARD_SIZE = Vector2.new(760, 196)
local MIN_Y = 150 -- design px from the top before the first placement
-- PopupQueue kinds this card presents (anything else is a milestone).
local KINDS: { [string]: boolean } = { juice = true, happyHour = true }
local QueueKinds = PopupQueueConfig.Kinds :: { [string]: PopupQueueConfig.KindDef }

type Parts = {
	card: StudUI.Card,
	scale: UIScale,
	producer: TextLabel,
	title: TextLabel,
	reward: TextLabel,
	popIn: Tween,
	popOut: Tween,
}

local parts: Parts? = nil
local flashFrame: Frame? = nil
local flashIn: Tween? = nil
local flashOut: Tween? = nil

-- Places the card in its PopupQueue slot (the top of the free band under the currency stack).
local function place(card: Frame, slot: PopupQueue.Slot)
	card.Position = UDim2.new(0.5, 0, 0, slot.top(CARD_SIZE.Y) + CARD_SIZE.Y / 2)
end

-- Pops the card out (instantly with Reduce Motion); the slot's hide callback.
local function hideCard()
	local p = parts
	if p == nil then
		return
	end
	if OfferFx.reducedMotion() then
		p.popIn:Cancel()
		p.popOut:Cancel()
		p.card.frame.Visible = false
	else
		p.popOut:Play()
	end
end

local bannerScreen: ScreenManager.ScreenModule = {
	name = BANNER,
	modal = false,
	autoOpen = true,
	displayOrder = 16,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		local card = StudUI.card({
			name = "Banner",
			color = "yellow",
			sunburst = true,
			size = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
			anchor = Vector2.new(0.5, 0.5),
			position = UDim2.new(0.5, 0, 0, MIN_Y + CARD_SIZE.Y / 2),
			parent = gui,
		})
		card.frame.Visible = false
		card.frame.Active = false
		local scale = Create.new("UIScale", { Name = "Punch", Scale = 1, Parent = card.frame }) :: UIScale
		local producer = StudUI.text({
			name = "Producer",
			text = "",
			textSize = 30,
			size = UDim2.new(1, -40, 0, 38),
			position = UDim2.fromOffset(20, 8),
			color = UIStyleConfig.Neutral.Text,
			zIndex = 4,
			parent = card.content,
		})
		local title = StudUI.text({
			name = "Title",
			text = "",
			textSize = 76,
			font = "shout",
			size = UDim2.new(1, -40, 0, 86),
			position = UDim2.fromOffset(20, 42),
			scaled = true,
			zIndex = 4,
			parent = card.content,
		})
		local reward = StudUI.text({
			name = "Reward",
			text = "",
			textSize = 50,
			font = "shout",
			size = UDim2.new(1, -40, 0, 58),
			position = UDim2.fromOffset(20, 128),
			color = UIStyleConfig.Neutral.CashGreen,
			scaled = true,
			zIndex = 4,
			parent = card.content,
		})
		local popIn = TweenService:Create(
			scale,
			TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }
		)
		local popOut = TweenService:Create(
			scale,
			TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Scale = 0.01 }
		)
		popOut.Completed:Connect(function(state: Enum.PlaybackState)
			if state == Enum.PlaybackState.Completed then
				card.frame.Visible = false
			end
		end)
		parts = {
			card = card,
			scale = scale,
			producer = producer,
			title = title,
			reward = reward,
			popIn = popIn,
			popOut = popOut,
		}
		return {}
	end,
}

local flashScreen: ScreenManager.ScreenModule = {
	name = FLASH,
	modal = false,
	autoOpen = true,
	displayOrder = 38,
	safeArea = false,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		local frame = Create.new("Frame", {
			Name = "Flash",
			BackgroundColor3 = Color3.fromRGB(255, 250, 236),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Active = false,
			Visible = false,
			Parent = gui,
		}) :: Frame
		flashFrame = frame
		local peak = 1 - JuiceConfig.Rebirth.FlashPeak
		flashIn = TweenService:Create(
			frame,
			TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = peak }
		)
		local out = TweenService:Create(
			frame,
			TweenInfo.new(JuiceConfig.Rebirth.FlashSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		)
		out.Completed:Connect(function(state: Enum.PlaybackState)
			if state == Enum.PlaybackState.Completed then
				frame.Visible = false
			end
		end)
		flashOut = out
		return {}
	end,
}

--[[
	Registers the two screens (once; JuiceController.Start).
	@param playerGui the local PlayerGui
]]
function JuiceBanner.register(playerGui: Instance)
	if not ScreenManager.isRegistered(BANNER) then
		ScreenManager.register(bannerScreen, playerGui)
	end
	if not ScreenManager.isRegistered(FLASH) then
		ScreenManager.register(flashScreen, playerGui)
	end
end

--[[
	Shows the banner through PopupQueue's centre lane (see the header: it may wait its turn).
	@param producer small top line (e.g. the producer's name; "" hides it)
	@param title    big shout ("LEVEL 50!")
	@param reward   reward line ("x2 SPEED!")
	@param color    card colour (UIStyleConfig ColorName)
	@param seconds  how long it holds (default JuiceConfig.Milestone.BannerSeconds; QA captures
	                pass a longer hold so the device matrix sees it on every device)
	@param kind     PopupQueue kind: "juice" (default, milestones) | "happyHour"
	@return true when shown or queued (false: not built yet / refused)
	Example: JuiceBanner.show("Garage Reactor", "LEVEL 25!", "x2 CASH!", "green")
]]
function JuiceBanner.show(
	producer: string,
	title: string,
	reward: string,
	color: UIStyleConfig.ColorName,
	seconds: number?,
	kind: string?
): boolean
	if parts == nil then
		return false
	end
	local popupKind = if kind ~= nil and KINDS[kind] == true and QueueKinds[kind] ~= nil then kind else "juice"
	local hold = if seconds ~= nil
			and seconds == seconds
			and seconds > 0
		then math.min(seconds, 60)
		else JuiceConfig.Milestone.BannerSeconds
	local handle = PopupQueue.request({
		kind = popupKind,
		seconds = hold,
		height = CARD_SIZE.Y,
		show = function(slot: PopupQueue.Slot): boolean
			local p = parts
			if p == nil then
				return false
			end
			place(p.card.frame, slot)
			p.card.setColor(color)
			p.producer.Text = producer
			p.producer.Visible = producer ~= ""
			p.title.Text = title
			p.reward.Text = reward
			p.popOut:Cancel()
			p.card.frame.Visible = true
			if OfferFx.reducedMotion() then
				p.popIn:Cancel()
				p.scale.Scale = 1
			else
				p.scale.Scale = 0.55
				p.popIn:Play()
			end
			return true
		end,
		hide = function(_reason: string)
			hideCard()
		end,
		place = function(slot: PopupQueue.Slot)
			local p = parts
			if p ~= nil then
				place(p.card.frame, slot)
			end
		end,
	})
	return handle ~= nil
end

--[[ The soft white rebirth flash (no-op with Reduce Motion). ]]
function JuiceBanner.flash()
	local frame, fadeIn, fadeOut = flashFrame, flashIn, flashOut
	if frame == nil or fadeIn == nil or fadeOut == nil or OfferFx.reducedMotion() then
		return
	end
	fadeOut:Cancel()
	frame.BackgroundTransparency = 1
	frame.Visible = true
	fadeIn:Play()
	task.delay(0.09, function()
		fadeOut:Play()
	end)
end

--[[ True while the banner is up (Studio probes). ]]
function JuiceBanner.isShowing(): boolean
	local p = parts
	return p ~= nil and p.card.frame.Visible
end

return JuiceBanner
