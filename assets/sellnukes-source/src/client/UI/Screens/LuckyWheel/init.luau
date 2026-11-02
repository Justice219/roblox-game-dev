--!strict
--[[
	LuckyWheel — the Lucky Wheel screen (design spec §7; reference
	docs/reference/ui-style/03-lucky-wheel.png): "Next FREE spin in 04:14" (or "FREE SPINS
	READY: n"), the big studded wheel with a white rim and a down-arrow pointer, a green
	"SPIN (xN)" button next to the red X, and the three yellow paid bundles (2x / 5x / 10x).

	Flow:
		SPIN → requestId += 1 → SpinWheel(requestId) → the button shows "SPINNING..." until the
		SpinResult with THAT id arrives (others are ignored; after RESULT_TIMEOUT s the button
		comes back, and a late answer for the same id is still shown). Meanwhile the wheel winds
		up (WheelFx: pulled back against the peg behind the flapper, trembling). ok → WheelFx
		launches the disc (a CanvasGroup) LuckyWheelFxConfig.Spin.Turns turns + the delta that
		puts the won slice's mid-angle under the pointer, ticking on every rim peg, and lands on
		it (instant with Reduce Motion or while closed); then the celebration sized to the slice
		(glow, rays, bulbs, confetti, shake, sting) with "You won <text>!" over the wheel and as a
		reward toast. Not ok / timeout → the wheel unwinds and the server's text shows in the
		message line. A press within QuickSpin.WindowSeconds of the last landing (spending a
		2x / 5x / 10x bundle) is a shorter, fewer-turn spin.
		Spin juice (owner R81) lives in Screens/LuckyWheel/WheelFx (+ SpinMotion maths, tuned in
		Shared/Config/LuckyWheelFxConfig); this screen only says what happened.
		Bundles → PromptProduct(Spins2 | Spins5 | Spins10, "wheel"); the server validates, prompts,
		and answers "Coming soon!" for products that are not published yet. Owner R122: bundles are
		tagged BUY buttons (UI/PurchaseGuard) — the gamepad cursor opens on SPIN (else the close X),
		never on a bundle, and a bundle press counts only when it began after the wheel opened.

	Paid random items (LuckySpinConfig header): spins are spent free → bonus → paid, and PAID
	(Robux-sourced) spins are paid random items. Where the region restricts them
	(EggConfig.policyState(profile.policy) == "restricted") the bundles are locked, SPIN counts only
	the free + bonus spins, and when only paid spins are left the button reads "UNAVAILABLE" with
	the reason in the message line (the paid spins are kept). The server re-checks every paid
	spin and fails closed; this is display only.

	Counters: free / bonus / paid / next-free come from LuckySpinConfig.status(spin, server now),
	where `spin` is the latest server word — the profile snapshot's `spin`, or a SpinResult's
	counters (converted back into the same { free, lastFreeAt, paid, bonus } shape). One timer
	re-evaluates when the next free spin lands, so the counters and the HUD badge stay right while
	closed.

	HUD badge: lazy = false so this module listens from boot and keeps Hud badge "LuckyWheel"
	= "!" whenever a free spin is ready. Boot work is tiny: the wheel, buttons and labels are
	built on the FIRST open (once), never per frame.

	Layout: the reference's vertical stack on desktop / tablet / console; on short landscape
	canvases (phones) the wheel moves left and the controls stack TOP-aligned on the right, so
	taps stay ≥ 44 pt, text ≥ 14 pt, and nothing interactive reaches the bottom corners
	(Roblox's thumbstick / jump button). On touch devices the layout with the bigger rendered
	tap targets wins. The choice re-runs on ScreenManager.LayoutChanged (event-driven).

	Gamepad (owner R11, docs/platform.md §7): the cursor starts on SPIN (never the X); SPIN ↔ X
	across, down to the (2x) / (5x) / (10x) row (linked left / right, up returns to the button
	above). B / Back closes through ScreenManager (no onBack override); no hover-only states.

	Security: display + intents only. The roll, the counters and the reward are server-side
	(LuckySpinService); cash captions are RewardPreview's display of the same income rule.

	Connects to: Screens/LuckyWheel/{WheelDrawing, WheelFx, SpinMotion}, Kit/StudUI,
	Widgets/{ModalShell, OfferFx},
	Platform/GamepadNav,
	UI/{Create, ScreenManager, Hud/Hud}, Client/{ClientState, Analytics/ClientAnalytics},
	Screens/DailyRewards/RewardPreview, Shared/Config/{LuckySpinConfig, MonetizationConfig,
	LuckyWheelFxConfig, TouchUIConfig, UIStyleConfig}, Shared/Util/{NumberFormat, TouchLayout},
	Shared/Net/Remotes
	(SpinWheel, SpinResult, PromptProduct).

	Example: ScreenManager.open("LuckyWheel")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Create)
-- EggConfig.policyState: the shared reader of profile.policy (allowed / restricted / checking).
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local Hud = require(script.Parent.Parent.Hud.Hud)
local LuckySpinConfig = require(ReplicatedStorage.Shared.Config.LuckySpinConfig)
local LuckyWheelFxConfig = require(ReplicatedStorage.Shared.Config.LuckyWheelFxConfig)
local ModalShell = require(script.Parent.Parent.Widgets.ModalShell)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local OfferFx = require(script.Parent.Parent.Widgets.OfferFx)
-- Owner R122 purchase-focus hygiene (opening-press guard, BUY tags, safe default selection).
local PurchaseGuard = require(script.Parent.Parent.PurchaseGuard)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RewardPreview = require(script.Parent.DailyRewards.RewardPreview)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local SpinMotion = require(script.SpinMotion)
local WheelDrawing = require(script.WheelDrawing)
local WheelFx = require(script.WheelFx)

local NAME = "LuckyWheel"
-- Owner R113 ("in spin hide the ui on the top as well"): the focus reason held while the disc
-- spins, and the NON-modal screens it fades (currency stack + HUD, boost badge, Lucky Button chip,
-- Happy Hour pill). The bottom-left Toasts feed (R111) stays: it shows the wheel's own win.
local SPIN_FOCUS = "LuckyWheelSpin"
local SPIN_FOCUS_HIDES = table.freeze({ "Hud", "BoostChips", "LuckyArrow", "HappyHourChip" })
local BADGE_KEY = "LuckyWheel" -- HudZonesConfig.Left key
local ANALYTICS_SCREEN = "Wheel" -- AnalyticsConfig.ClientFunnel.Screens id
local PROMPT_SOURCE = "wheel" -- PurchasePromptConfig.Sources id
-- Paid bundles, left to right (MonetizationConfig product keys).
local BUNDLES = { "Spins2", "Spins5", "Spins10" }

-- Coloured disc diameter (design px at 1080p).
local DISC_DIAMETER = 520
-- Seconds to wait for a SpinResult before the SPIN button comes back.
local RESULT_TIMEOUT = 8
-- Seconds a message (error / server text) stays before the hint line returns.
local MESSAGE_SECONDS = 4
-- Extra seconds after the computed free-spin moment before re-evaluating (clock jitter).
local REFRESH_SLACK = 0.25
-- Longest server text shown (defensive cap).
local MAX_SERVER_TEXT = 200
-- Keep the reference's vertical layout while it renders at least this big (fit factor).
local PREFER_VERTICAL_FIT = 0.85
-- Side layout: y of the control column's top (design px).
local SIDE_COLUMN_TOP = 24
-- Profile fields the income-scaled cash captions depend on.
local CASH_FIELDS = { "tycoon", "rebirths", "rebirthShop" }

-- Text sizes (design px).
local TITLE_TEXT = 54
-- 48: the Robux tag under each bundle is 0.6 × this = 28 px ≥ 14 pt on the narrowest phone.
local BUNDLE_TEXT = 48
local SPIN_TEXT = 40
local ROW_GAP = 16

local Neutral = UIStyleConfig.Neutral
local LIP = UIStyleConfig.Button.Lip
local EDGE = UIStyleConfig.Button.Edge

type SpinState = { free: number, lastFreeAt: number, paid: number, bonus: number }
type Mode = "vertical" | "side"
type Rect = { x: number, y: number, w: number, h: number }
type Layout = {
	size: Vector2,
	title: Rect,
	titleText: number,
	wheel: Vector2,
	message: Rect,
	messageText: number,
	spin: Rect,
	close: Rect,
	bundles: { Rect },
}
type Content = {
	countdown: StudUI.Countdown,
	ready: TextLabel,
	message: TextLabel,
	wheel: WheelDrawing.Wheel,
	spin: StudUI.Button,
	close: StudUI.Button,
	bundles: { StudUI.Button },
	fx: WheelFx.Fx, -- spin presentation (wind-up, ticks, landing, celebration, pop)
}

-- ── Pure helpers ─────────────────────────────────────────────────────────────────────────────

-- A finite number from an untyped value, else nil (NaN / inf / non-number rejected).
local function finite(value: unknown): number?
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- Server text that is safe to show (non-empty string, capped), else nil.
local function serverText(value: unknown): string?
	if type(value) == "string" and #value > 0 and #value <= MAX_SERVER_TEXT then
		return value
	end
	return nil
end

-- True when the changed-field list `fields` (nil = everything) contains any of `names`.
local function touches(fields: { string }?, names: { string }): boolean
	if fields == nil then
		return true
	end
	for _, name in names do
		if table.find(fields, name) ~= nil then
			return true
		end
	end
	return false
end

-- profile.spin as a typed SpinState (nil when missing / malformed).
local function readSpin(raw: unknown): SpinState?
	if type(raw) ~= "table" then
		return nil
	end
	local spin = raw :: { [string]: unknown }
	local free, lastFreeAt, paid = finite(spin.free), finite(spin.lastFreeAt), finite(spin.paid)
	if free == nil or lastFreeAt == nil or paid == nil then
		return nil
	end
	-- `bonus` is newer than the other counters: a snapshot without it reads 0.
	return { free = free, lastFreeAt = lastFreeAt, paid = paid, bonus = finite(spin.bonus) or 0 }
end

-- True when the player's region restricts paid random items (Robux spins can't be spun).
local function regionLocked(): boolean
	local profile = ClientState.profile
	return EggConfig.policyState(if profile ~= nil then profile.policy else nil) == "restricted"
end

-- Spins the player can use right now: free + bonus, plus paid unless the region restricts them.
local function usableSpins(status: LuckySpinConfig.Status?): number
	if status == nil then
		return 0
	end
	local paid = if regionLocked() then 0 else status.paid
	return math.max(0, math.floor(status.free + status.bonus + paid))
end

--[[
	The caption of every slice for `profile`: CASH slices show the income-scaled amount
	(RewardPreview.cash, same rule as the server) as "1.25K Cash"; the rest their config label.
]]
local function sliceLabels(profile: { [string]: any }?): { string }
	local labels: { string } = {}
	for index, slice in LuckySpinConfig.Slices do
		local cash = if slice.label == "CASH" then RewardPreview.cash(slice.reward, profile) else 0
		labels[index] = if cash > 0 then `{NumberFormat.short(cash)} Cash` else slice.label
	end
	return labels
end

-- Room a labelled button's Robux tag takes under it: lip + edge + gap + tag (text × 0.6 + 6).
local function tagRoom(textSize: number): number
	return LIP + EDGE + 4 + math.floor(textSize * 0.6) + 6
end

-- Evenly spaced bundle rects in a row of `count`, centred on `centreX`.
local function bundleRow(count: number, centreX: number, y: number, w: number, h: number, gap: number): { Rect }
	local x0 = math.floor(centreX - (count * w + (count - 1) * gap) / 2)
	local rects: { Rect } = {}
	for i = 1, count do
		rects[i] = { x = x0 + (i - 1) * (w + gap), y = y, w = w, h = h }
	end
	return rects
end

--[[
	The reference layout: title, wheel, message, SPIN + X, bundles — stacked and centred.
	@param m wheel metrics (WheelDrawing.metrics)
	@return Layout
]]
local function verticalLayout(m: WheelDrawing.Metrics): Layout
	local width = 1000
	local title: Rect = { x = 0, y = 0, w = width, h = 62 }
	local wheelY = title.h + m.overhang + 4
	local y = wheelY + m.side + 6
	local message: Rect = { x = 0, y = y, w = width, h = 38 }
	y += message.h + 8
	local spinW, spinH, closeSide = 300, 80, 85
	local rowX = math.floor((width - (spinW + ROW_GAP + closeSide)) / 2)
	local spin: Rect = { x = rowX, y = y, w = spinW, h = spinH }
	local close: Rect = { x = rowX + spinW + ROW_GAP, y = y, w = closeSide, h = closeSide - LIP }
	y += spinH + LIP + EDGE + 16
	local bundles = bundleRow(#BUNDLES, width / 2, y, 230, 72, 18)
	y += 72 + tagRoom(BUNDLE_TEXT)
	return {
		size = Vector2.new(width, y + 4),
		title = title,
		titleText = TITLE_TEXT,
		wheel = Vector2.new(math.floor((width - m.side) / 2), wheelY),
		message = message,
		messageText = 28,
		spin = spin,
		close = close,
		bundles = bundles,
	}
end

--[[
	The short-landscape (phone) layout: wheel on the left, controls stacked on the right with
	bigger buttons (≥ 44 pt after the phone scale and the window fit).
	@param m wheel metrics
	@return Layout
]]
local function sideLayout(m: WheelDrawing.Metrics): Layout
	local width = 1260
	local wheel = Vector2.new(16, m.overhang + 8)
	local colX = 16 + m.side + 36
	local colW = width - colX - 16
	local centreX = colX + colW / 2
	local spinW, spinH, closeSide = 340, 92, 97
	local bundleW, bundleH, bundleGap = 188, 90, 14
	local titleH, messageH = 56, 72
	local contentH = titleH + 10 + messageH + 14 + spinH + LIP + EDGE + 22 + bundleH + tagRoom(BUNDLE_TEXT)
	-- TOP-aligned column: on short phones the window's bottom edge sits near Roblox's jump
	-- button, so every control stays in the upper ~70 % (the wheel alone fills the bottom).
	local y = SIDE_COLUMN_TOP
	local height = math.max(wheel.Y + m.side + 12, y + contentH + 12)
	local title: Rect = { x = colX, y = y, w = colW, h = titleH }
	y += titleH + 10
	local message: Rect = { x = colX, y = y, w = colW, h = messageH }
	y += messageH + 14
	local rowX = math.floor(centreX - (spinW + ROW_GAP + closeSide) / 2)
	local spin: Rect = { x = rowX, y = y, w = spinW, h = spinH }
	local close: Rect = { x = rowX + spinW + ROW_GAP, y = y, w = closeSide, h = closeSide - LIP }
	y += spinH + LIP + EDGE + 22
	return {
		size = Vector2.new(width, height),
		title = title,
		titleText = 44,
		wheel = wheel,
		message = message,
		messageText = 28,
		spin = spin,
		close = close,
		bundles = bundleRow(#BUNDLES, centreX, y, bundleW, bundleH, bundleGap),
	}
end

-- Positions / sizes `object` on `rect` (design px, top-left anchored).
local function place(object: GuiObject, rect: Rect)
	object.AnchorPoint = Vector2.zero
	object.Position = UDim2.fromOffset(rect.x, rect.y)
	object.Size = UDim2.fromOffset(rect.w, rect.h)
end

-- The smallest tap target of a layout (design px: SPIN, X and bundle face heights).
local function minTap(layout: Layout): number
	local smallest = math.min(layout.spin.h, layout.close.h)
	for _, rect in layout.bundles do
		smallest = math.min(smallest, rect.h)
	end
	return smallest
end

-- True while animations should be skipped (Roblox Reduce Motion or the SellNukes setting).
local function reducedMotion(): boolean
	if OfferFx.reducedMotion() then
		return true
	end
	local profile = ClientState.profile
	local settings = if profile ~= nil then profile.settings else nil
	return type(settings) == "table" and settings.reducedMotion == true
end

-- ── Screen ───────────────────────────────────────────────────────────────────────────────────

local METRICS = WheelDrawing.metrics(DISC_DIAMETER)
local LAYOUTS: { [Mode]: Layout } = {
	vertical = verticalLayout(METRICS),
	side = sideLayout(METRICS),
}

--[[
	Builds the screen shell at boot (lazy = false): listeners, the badge timer and an empty
	ModalShell. The visible content is built on the first open.
	@param gui the screen's ScreenGui
	@return ScreenManager.ScreenHandle
]]
local function build(gui: ScreenGui): ScreenManager.ScreenHandle
	-- Transparent stage the ModalShell fits / pops; every element is placed on it in design px.
	local stage = Create.new("Frame", {
		Name = "LuckyWheelStage",
		BackgroundTransparency = 1,
		Active = true, -- swallow clicks on the wheel area
		Size = UDim2.fromOffset(LAYOUTS.vertical.size.X, LAYOUTS.vertical.size.Y),
	}) :: Frame
	local mode: Mode = "vertical"
	local shell: ModalShell.Shell = ModalShell.new(gui, stage, LAYOUTS.vertical.size)
	local content: Content? = nil

	-- Latest server word on the spin counters, the status derived from it, and UI bookkeeping.
	local spinState: SpinState? = nil
	local lastStatus: LuckySpinConfig.Status? = nil
	local badgeOn: boolean? = nil
	local refreshTimer: thread? = nil
	local countdownEndsAt = -math.huge
	local labelsDirty = true
	local messageUntil = 0

	-- Spin request / animation state.
	local lastSentId = 0 -- id of the latest SpinWheel request this session
	local handledId = 0 -- latest id whose SpinResult was handled (repeats are ignored)
	local awaiting = false -- a request is in flight (button shows SPINNING...)
	local timeoutThread: thread? = nil
	local spinning = false -- the disc animation is playing
	local spinFinish: ((quiet: boolean?) -> ())? = nil -- completes the running spin at once (close)
	-- The disc's resting rotation, kept in [0, 360): starts with slice 1's centre under the
	-- pointer (halfway between two rim pegs, like every landing).
	local rotation = WheelDrawing.targetRotation(0, 1, #LuckySpinConfig.Slices, 0) % 360
	-- os.clock() of the last landing, and whether the request in flight is a back-to-back
	-- (QuickSpin) spin.
	local lastLandedAt = -math.huge
	local quickSpin = false

	-- Forward declaration (refresh ↔ countdown onFinished / timer).
	local refresh: () -> ()
	-- Gamepad default (SPIN), created with the content.
	local selectDefault: (() -> GuiObject?)? = nil

	-- Shows / hides the HUD badge (only on change).
	local function setBadge(on: boolean)
		if badgeOn == on then
			return
		end
		badgeOn = on
		Hud.setButtonBadge(BADGE_KEY, if on then "!" else nil)
	end

	-- (Re)arms the one timer that re-evaluates when the next free spin lands.
	local function scheduleRefresh(status: LuckySpinConfig.Status?)
		local timer = refreshTimer
		if timer ~= nil then
			refreshTimer = nil
			task.cancel(timer)
		end
		if status == nil or status.free >= LuckySpinConfig.MaxFree or status.nextFreeIn <= 0 then
			return
		end
		refreshTimer = task.delay(status.nextFreeIn + REFRESH_SLACK, function()
			refreshTimer = nil
			refresh()
		end)
	end

	-- The persistent hint in the message line (unless a message is still showing).
	local function renderMessage()
		local c = content
		if c == nil or os.clock() < messageUntil then
			return
		end
		local status = lastStatus
		local total = usableSpins(status)
		if status ~= nil and total <= 0 and status.paid > 0 and regionLocked() and not awaiting and not spinning then
			-- Only Robux spins are left and the region restricts them (kept for later).
			c.message.Text = LuckySpinConfig.PolicyText.Restricted
		elseif status ~= nil and total <= 0 and not awaiting and not spinning then
			c.message.Text = "Out of spins! Get more below or wait for a free one."
		else
			c.message.Text = ""
		end
		c.message.TextColor3 = Neutral.TextDim
	end

	-- Shows `text` in the message line for MESSAGE_SECONDS, then the hint comes back.
	local function flashMessage(text: string, color: Color3)
		local c = content
		if c == nil then
			return
		end
		messageUntil = os.clock() + MESSAGE_SECONDS
		c.message.Text = text
		c.message.TextColor3 = color
		task.delay(MESSAGE_SECONDS + 0.05, renderMessage)
	end

	-- SPIN (xN) / SPINNING... and its state.
	local function renderSpinButton()
		local c = content
		if c == nil then
			return
		end
		if awaiting or spinning then
			c.spin.setText("SPINNING...")
			c.spin.setState("disabled")
			return
		end
		local status = lastStatus
		local total = usableSpins(status)
		if total <= 0 and status ~= nil and status.paid > 0 and regionLocked() then
			c.spin.setState("locked", LuckySpinConfig.PolicyText.Button)
			return
		end
		c.spin.setText(`SPIN (x{NumberFormat.commas(total)})`)
		c.spin.setState(if total > 0 then "normal" else "disabled")
	end

	-- Title (countdown vs "FREE SPINS READY: n"), SPIN button and hint from `status`.
	local function renderContent(status: LuckySpinConfig.Status?)
		local c = content
		if c == nil then
			return
		end
		if status == nil then
			c.countdown.label.Visible = false
			c.ready.Visible = true
			c.ready.Text = "Lucky Wheel"
		elseif status.free > 0 then
			c.countdown.label.Visible = false
			c.ready.Visible = true
			c.ready.Text = `FREE SPINS READY: {math.floor(status.free)}`
		else
			c.ready.Visible = false
			c.countdown.label.Visible = true
			local endsAt = RewardPreview.serverNow() + status.nextFreeIn
			-- Only move the countdown when the target really changed (a finished countdown that
			-- re-evaluates to the same moment must not restart itself).
			if math.abs(endsAt - countdownEndsAt) > 1 then
				countdownEndsAt = endsAt
				c.countdown.setEndsAt(endsAt)
			end
		end
		renderSpinButton()
		renderMessage()
	end

	-- Re-evaluates the counters: badge, next-free timer and (when built) the visible content.
	refresh = function()
		local state = spinState
		local status = if state ~= nil then LuckySpinConfig.status(state, RewardPreview.serverNow()) else nil
		lastStatus = status
		setBadge(status ~= nil and status.free > 0)
		scheduleRefresh(status)
		renderContent(status)
	end

	-- Updates the CASH captions from the current profile (cheap: label texts only).
	local function renderLabels()
		local c = content
		if c == nil then
			return
		end
		labelsDirty = false
		c.wheel.setLabels(sliceLabels(ClientState.profile))
	end

	-- Locks the paid bundles when the server says paid random items are restricted here.
	local function renderBundles()
		local c = content
		if c == nil then
			return
		end
		local restricted = regionLocked()
		for _, bundle in c.bundles do
			bundle.setState(if restricted then "locked" else "normal")
		end
	end

	--[[
		Sends the reward toast and, while the screen is open (and not closing), the celebration
		sized to the slice: glow, rays, bulbs, confetti, shake, sting and the "You won ...!" pop
		(WheelFx.win; a static version with Reduce Motion).
		@param quiet   true when the screen is closing (toast only)
		@param preview true for the Studio-only DebugPreview (no toast: nothing was won)
	]]
	local function showWin(text: string?, index: number, quiet: boolean?, preview: boolean?)
		local slice = LuckySpinConfig.Slices[index]
		local message = if text ~= nil
				and text ~= ""
				and text ~= "nothing"
			then `You won {text}!`
			else "Thanks for spinning!"
		if preview ~= true then
			Hud.notify("reward", message, slice.icon)
		end
		local c = content
		if c == nil or quiet == true or not ScreenManager.isOpen(NAME) then
			return
		end
		c.fx.win(index, message, reducedMotion())
	end

	--[[
		Spins the disc onto the server's slice `index`: Spin.Turns (QuickSpin.Turns back-to-back)
		whole turns + the landing delta, presented by WheelFx (wind-up → ticking spin → landing);
		instant with Reduce Motion or while closed. Then the win.
		@param preview true for the Studio-only DebugPreview (presentation only, no toast)
	]]
	local function startSpin(index: number, text: string?, preview: boolean?)
		local count = #LuckySpinConfig.Slices
		local turns = if quickSpin then LuckyWheelFxConfig.QuickSpin.Turns else LuckyWheelFxConfig.Spin.Turns
		local target = WheelDrawing.targetRotation(rotation, index, count, turns)
		spinning = true
		-- Owner R113: the top HUD (currency, boost badge, chips) fades out while the wheel spins.
		ScreenManager.setFocusReason(SPIN_FOCUS, true, SPIN_FOCUS_HIDES)
		renderSpinButton()
		-- quiet = true: the screen is closing (no celebration, the toast still shows).
		local function finish(quiet: boolean?)
			if not spinning then
				return
			end
			spinning = false
			spinFinish = nil
			ScreenManager.setFocusReason(SPIN_FOCUS, false) -- R113: the top HUD comes back
			-- Same picture as `target`; keeps the number small for the next spin.
			rotation = target % 360
			lastLandedAt = os.clock()
			renderSpinButton()
			renderMessage()
			showWin(text, index, quiet, preview)
		end
		local c = content
		if c == nil or reducedMotion() or not ScreenManager.isOpen(NAME) then
			if c ~= nil then
				c.fx.snap(target % 360)
			end
			finish()
			return
		end
		spinFinish = finish
		c.fx.spin(target, quickSpin, function()
			finish()
		end)
	end

	-- Eases a wound-up wheel back (the request failed or timed out).
	local function unwindWheel()
		local c = content
		if c ~= nil then
			c.fx.unwind()
		end
	end

	-- Turns a SpinResult's counters into the profile's { free, lastFreeAt, paid, bonus } shape.
	local function applyPayloadCounters(payload: { [string]: unknown })
		local free, paid, nextIn = finite(payload.free), finite(payload.paid), finite(payload.nextFreeIn)
		if free == nil or paid == nil or nextIn == nil then
			return
		end
		local now = RewardPreview.serverNow()
		local previous = spinState
		-- status() gives nextFreeIn = every − (elapsed % every), so the timer started at
		-- now + nextIn − every; when free is full the timer is idle and lastFreeAt is unused.
		local lastFreeAt = if free < LuckySpinConfig.MaxFree and nextIn > 0
			then now + nextIn - LuckySpinConfig.FreeEverySeconds
			elseif previous ~= nil then previous.lastFreeAt
			else now
		spinState = { free = free, lastFreeAt = lastFreeAt, paid = paid, bonus = finite(payload.bonus) or 0 }
	end

	-- SpinResult handler (validated; only the latest request id this session counts).
	local function onResult(raw: unknown)
		if type(raw) ~= "table" then
			return
		end
		local payload = raw :: { [string]: unknown }
		local id = finite(payload.requestId)
		if id == nil or id ~= lastSentId or id <= handledId then
			return
		end
		handledId = id
		awaiting = false
		local timer = timeoutThread
		if timer ~= nil then
			timeoutThread = nil
			task.cancel(timer)
		end
		applyPayloadCounters(payload)
		local index = finite(payload.index)
		local count = #LuckySpinConfig.Slices
		if payload.ok == true and index ~= nil and index % 1 == 0 and index >= 1 and index <= count then
			refresh()
			startSpin(index, serverText(payload.text))
		else
			unwindWheel()
			refresh()
			flashMessage(serverText(payload.text) or "The wheel couldn't spin. Try again!", Neutral.Danger)
		end
	end

	-- SPIN pressed: one request in flight at a time.
	local function onSpin()
		if awaiting or spinning then
			return
		end
		if usableSpins(lastStatus) <= 0 then
			return
		end
		lastSentId += 1
		local id = lastSentId
		awaiting = true
		quickSpin = SpinMotion.isQuick(os.clock(), lastLandedAt, LuckyWheelFxConfig.QuickSpin.WindowSeconds)
		renderSpinButton()
		renderMessage()
		Remotes.event("SpinWheel"):FireServer(id)
		-- Anticipation while the answer travels (presentation only; never with Reduce Motion).
		local c = content
		if c ~= nil and not reducedMotion() and ScreenManager.isOpen(NAME) then
			c.fx.windUp(quickSpin)
		end
		local previous = timeoutThread
		if previous ~= nil then
			task.cancel(previous)
		end
		timeoutThread = task.delay(RESULT_TIMEOUT, function()
			timeoutThread = nil
			if awaiting and lastSentId == id then
				awaiting = false
				unwindWheel()
				renderSpinButton()
				flashMessage("The wheel is busy right now. Try again!", Neutral.Danger)
			end
		end)
	end

	-- Applies `layout` to the built content.
	local function applyLayout(layout: Layout)
		local c = content
		if c == nil then
			return
		end
		place(c.countdown.label, layout.title)
		place(c.ready, layout.title)
		c.countdown.label.TextSize = layout.titleText
		c.ready.TextSize = layout.titleText
		place(c.message, layout.message)
		c.message.TextSize = layout.messageText
		c.wheel.root.Position = UDim2.fromOffset(layout.wheel.X, layout.wheel.Y)
		place(c.spin.instance, layout.spin)
		place(c.close.instance, layout.close)
		for index, bundle in c.bundles do
			local rect = layout.bundles[index]
			if rect ~= nil then
				place(bundle.instance, rect)
			end
		end
	end

	--[[
		The layout for this canvas. Vertical (the reference) while it renders at least
		PREFER_VERTICAL_FIT big; otherwise the one that renders bigger. On touch devices
		"bigger" means the rendered smallest tap target in points (design px × window fit ×
		UI scale), and vertical also needs ≥ TouchUIConfig.MinTapPoints.
	]]
	local function pickMode(): Mode
		local touch = ScreenManager.touchTargets()
		local canvas = ScreenManager.canvasSize(gui)
		local usableY = math.max(1, canvas.Y - ScreenManager.safeTop(0))
		local margin = if touch then TouchUIConfig.Modal.TouchMargin else TouchUIConfig.Modal.DesktopMargin
		local vertical, side = LAYOUTS.vertical, LAYOUTS.side
		local fitV = TouchLayout.windowFit(vertical.size.X, vertical.size.Y, canvas.X, usableY, margin, 0)
		local fitS = TouchLayout.windowFit(side.size.X, side.size.Y, canvas.X, usableY, margin, 0)
		if touch then
			local points = ScreenManager.pointScale()
			local tapV = minTap(vertical) * fitV * points
			local tapS = minTap(side) * fitS * points
			if fitV >= PREFER_VERTICAL_FIT and tapV >= TouchUIConfig.MinTapPoints then
				return "vertical"
			end
			return if tapS > tapV then "side" else "vertical"
		end
		return if fitV >= PREFER_VERTICAL_FIT or fitV >= fitS then "vertical" else "side"
	end

	-- Switches layouts: a new ModalShell for the new design size (it re-parents the stage),
	-- then the old shell is dropped. Rare (device rotation / window resize).
	local function applyMode(newMode: Mode, force: boolean?)
		if newMode == mode and not force then
			return
		end
		local layout = LAYOUTS[newMode]
		if newMode ~= mode then
			local old = shell
			shell = ModalShell.new(gui, stage, layout.size)
			old.Destroy()
			mode = newMode
		end
		applyLayout(layout)
	end

	-- Builds the visible content once (first open).
	local function ensureContent()
		if content ~= nil then
			return
		end
		local countdown = StudUI.countdown({
			endsAt = 0,
			prefix = "Next FREE spin in ",
			format = "auto",
			doneText = "00:00",
			textSize = TITLE_TEXT,
			parent = stage,
			onFinished = function()
				refresh()
			end,
		})
		countdown.label.Name = "NextFree"
		local ready = StudUI.text({
			name = "Ready",
			text = "Lucky Wheel",
			textSize = TITLE_TEXT,
			parent = stage,
		})
		local message = StudUI.text({
			name = "Message",
			text = "",
			textSize = 28,
			wrap = true,
			color = Neutral.TextDim,
			parent = stage,
		})
		local wheel = WheelDrawing.build({
			diameter = DISC_DIAMETER,
			slices = LuckySpinConfig.Slices,
			labels = sliceLabels(ClientState.profile),
		})
		-- ZIndex 0: the wheel and every FX layer under it (rays, confetti, the pop) draw BELOW the
		-- title, message, SPIN, X and bundle buttons, so no effect ever covers a control.
		wheel.root.ZIndex = 0
		wheel.root.Parent = stage
		wheel.canvas.Rotation = rotation
		labelsDirty = false
		local fx = WheelFx.new(wheel, LuckySpinConfig.Slices, rotation)
		local spin = StudUI.button({
			text = "SPIN (x0)",
			color = "green",
			textSize = SPIN_TEXT,
			size = UDim2.fromOffset(300, 80),
			name = "Spin",
			parent = stage,
			onActivated = onSpin,
		})
		local close = StudUI.closeButton({
			size = 85,
			parent = stage,
			onActivated = function()
				ScreenManager.close(NAME)
			end,
		})
		-- Robux spin bundles. Owner R122: every bundle is a tagged BUY (never the default cursor)
		-- and its intent passes PurchaseGuard.allow (the press that opened the wheel never buys).
		local bundles: { StudUI.Button } = {}
		for _, key in BUNDLES do
			local def = MonetizationConfig.getProduct(key)
			if def == nil then
				continue
			end
			local spins = def.spins or 0
			table.insert(
				bundles,
				StudUI.button({
					text = `({spins}x)`,
					color = "yellow",
					productKey = key, -- live managed price (PriceBook)
					textSize = BUNDLE_TEXT,
					size = UDim2.fromOffset(230, 72),
					name = `Bundle_{key}`,
					parent = stage,
					onActivated = PurchaseGuard.gate(NAME, function()
						-- Intent only: the server validates the product, policy and prompt.
						Remotes.event("PromptProduct"):FireServer(key, PROMPT_SOURCE)
					end),
				})
			)
			PurchaseGuard.markBuy(bundles[#bundles].instance)
		end
		-- Gamepad links: SPIN <-> X across; down to the bundle row (left / right); each bundle's
		-- up returns to the control above it (SPIN for the left ones, X for the last).
		local bundleCells: { GuiObject } = {}
		for _, bundle in bundles do
			table.insert(bundleCells, bundle.instance)
		end
		GamepadNav.linkList({ spin.instance, close.instance }, false)
		if #bundleCells > 0 then
			GamepadNav.linkList(bundleCells, false, { up = spin.instance })
			spin.instance.NextSelectionDown = bundleCells[math.ceil(#bundleCells / 2)]
			close.instance.NextSelectionDown = bundleCells[#bundleCells]
			bundleCells[#bundleCells].NextSelectionUp = close.instance
		end
		-- SPIN (free / bonus spins) first; the fallback scan can never pick a Robux bundle (R122).
		local scan = GamepadNav.defaultSelection(stage, spin.instance)
		selectDefault = function(): GuiObject?
			return PurchaseGuard.safeDefault({ scan(), spin.instance, close.instance })
		end
		content = {
			countdown = countdown,
			ready = ready,
			message = message,
			wheel = wheel,
			spin = spin,
			close = close,
			bundles = bundles,
			fx = fx,
		}
		renderBundles()
	end

	-- Profile pushes: counters (badge), cash captions, paid-random policy.
	ClientState.ProfileChanged:Connect(function(profile: ClientState.Profile, fields: { string }?)
		if touches(fields, { "spin" }) then
			local state = readSpin(profile.spin)
			if state ~= nil then
				spinState = state
			end
			refresh()
		end
		if touches(fields, CASH_FIELDS) then
			labelsDirty = true
			if ScreenManager.isOpen(NAME) then
				renderLabels()
			end
		end
		if touches(fields, { "policy" }) then
			renderBundles()
			-- The usable spin count / button state depends on the policy too.
			renderContent(lastStatus)
		end
	end)
	local initial = ClientState.profile
	if initial ~= nil then
		spinState = readSpin(initial.spin)
		refresh()
	end

	-- Results (connected off the build thread: Remotes.event may wait for replication).
	task.spawn(function()
		Remotes.event("SpinResult").OnClientEvent:Connect(onResult)
	end)

	--[[
		Studio-only verification hook (docs/verification/r81-*; never created in live servers):
		firing the "DebugPreview" BindableEvent under this ScreenGui with a slice index plays the
		REAL spin presentation onto that slice (wind-up, ticking spin, landing, celebration)
		WITHOUT any server call: no spin is spent, nothing is granted and no reward toast shows —
		the presentation of a fixed result, like the hatch screen's DebugHoldAt rows. Used to
		capture the RARE PET / EGG celebrations, which the 2 % / 6 % server roll rarely gives.
	]]
	if RunService:IsStudio() then
		local preview = Create.new("BindableEvent", { Name = "DebugPreview" }) :: BindableEvent
		preview.Event:Connect(function(raw: unknown)
			local index = finite(raw)
			local c = content
			local count = #LuckySpinConfig.Slices
			if c == nil or index == nil or index % 1 ~= 0 or index < 1 or index > count then
				return
			end
			if awaiting or spinning or not ScreenManager.isOpen(NAME) or reducedMotion() then
				return
			end
			quickSpin = false
			c.fx.windUp(false)
			startSpin(index, sliceLabels(ClientState.profile)[index], true)
		end)
		preview.Parent = gui
	end

	-- Re-pick the layout when the canvas changes while open (event-driven).
	local function relayout()
		if content ~= nil and ScreenManager.isOpen(NAME) then
			applyMode(pickMode())
		end
	end
	ScreenManager.LayoutChanged:Connect(relayout)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		task.defer(relayout)
	end)

	return {
		onOpen = function(args: any?)
			local firstBuild = content == nil
			ensureContent()
			applyMode(pickMode(), firstBuild)
			shell.popIn()
			if labelsDirty then
				renderLabels()
			end
			messageUntil = 0
			refresh()
			local source = if type(args) == "table" and type(args.source) == "string"
				then args.source
				elseif type(args) == "table" and args.focus ~= nil then "offer"
				else "hud"
			ClientAnalytics.screenOpened(ANALYTICS_SCREEN, source)
		end,
		onClose = function()
			-- Closing stops every animation at once: mid-spin the disc settles on the won slice
			-- (the reward toast still shows, no celebration); a wind-up returns to rest; a
			-- celebration, confetti and the pop are cleared.
			ScreenManager.setFocusReason(SPIN_FOCUS, false) -- R113: never leave the HUD hidden
			local c = content
			if c ~= nil then
				c.fx.settle()
			end
			local finish = spinFinish
			if finish ~= nil then
				finish(true)
			end
		end,
		defaultSelection = function(): GuiObject?
			local select = selectDefault
			return if select ~= nil then select() else nil
		end,
	}
end

return {
	name = NAME,
	modal = true,
	closeOnBack = true,
	lazy = false,
	build = build,
} :: ScreenManager.ScreenModule
