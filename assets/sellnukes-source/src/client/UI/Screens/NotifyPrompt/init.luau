--!strict
--[[
	NotifyPrompt — the small "Get notified!" window (design spec §7): "Turn on notifications and
	get a free reward!", the reward preview (RetentionConfig.Notify.Reward), a green TURN ON and
	a grey LATER button, and a status line.

	TURN ON (Roblox's opt-in dialog is client-only and never says what the player picked, so the
	server accepts honest reports under its own rules — see Server/Services/NotifyRewardService):
		CanPromptOptInAsync() == true  → ClaimNotifyReward("shown") → PromptOptIn() → wait for
		                                 OptInPromptClosed (once) → CanPromptOptInAsync() again:
		                                 false = they turned it on → "accepted",
		                                 true  = still off          → "declined"
		CanPromptOptInAsync() == false → already on: "shown" then "accepted", "You're all set!"
	PromptOptIn is called at most ONCE per session. The server pays once (profile.notify.claimed)
	and toasts the reward; this window closes itself when the snapshot says claimed.

	Auto-suggest (owner R122 §2.3 "Opt-in reach"; lazy = false so it can run from boot; boot work
	is one small window): ONCE per session, at a strong moment (PromptMoments):
		manager  right after the player hires their FIRST manager this session
		area2    else when they reach area 2 this session
		other    else (a returning player who had both at join) FallbackDelaySeconds after the
		         profile loads; any other session LateFallbackSeconds after it loads when no
		         moment showed the card (the pre-R122 8-minute suggestion as a floor)
	Each moment waits MomentDelaySeconds, then asks Roblox CanPromptOptInAsync (false = already
	opted in / under 13 / asked in the last 30 days: nothing to gain, no card), then goes THROUGH
	THE POPUP QUEUE (UI/Widgets/PopupQueue kind NotifyConfig.Prompt.QueueKind, owner R102): it
	opens only when the centre lane is free, no window / cinematic is up, the join queue is quiet
	(Platform/JoinFlow.isQuiet: nothing queued ahead, not the guided first-minute steps, no
	purchase flow = never over a purchase prompt) and Roblox's menu is closed; it waits at most
	MaxWaitSeconds. Without that queue kind (older PopupQueueConfig) the same gates + "no centre
	popup" are polled every CheckSeconds (CalmChecks calm checks in a row). Opening it any other
	way (Settings → GET NOTIFIED) counts as the session's suggestion too. Every open reports
	ClaimNotifyReward("card", moment) → analytics "rnotify:promptAt:<manager|area2|other>".
	Reward semantics are unchanged (one-time reward, server rules below).

	Console / mobile (owner R11, docs/platform.md §7): the gamepad cursor starts on TURN ON
	(never the X); TURN ON <-> LATER across, up to the header X; after Roblox's dialog closes
	the cursor returns to TURN ON. B / Back closes through ScreenManager. Taps ≥ 44 pt and text
	≥ 14 pt after the phone scale; the centred buttons stay clear of the thumbstick / jump
	corners.

	Security: the client only reports what Roblox's dialog did ("shown" / "accepted" /
	"declined"); the server arms, rate-limits, pays once and ignores anything else.

	Connects to: Kit/StudUI, UI/{Create, ScreenManager}, UI/Widgets/PopupQueue, Client/ClientState,
	Platform/{GamepadNav, JoinFlow}, Screens/DailyRewards/RewardPreview, Screens/NotifyPrompt/
	PromptMoments, Shared/Config/{NotifyConfig, PopupQueueConfig, RetentionConfig, TycoonConfig,
	UIStyleConfig}, Shared/Net/Remotes (ClaimNotifyReward), ExperienceNotificationService, GuiService.

	Example: ScreenManager.open("NotifyPrompt")
]]

local ExperienceNotificationService = game:GetService("ExperienceNotificationService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Create)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local JoinFlow = require(script.Parent.Parent.Parent.Platform.JoinFlow)
local NotifyConfig = require(ReplicatedStorage.Shared.Config.NotifyConfig)
local PopupQueue = require(script.Parent.Parent.Widgets.PopupQueue)
local PopupQueueConfig = require(ReplicatedStorage.Shared.Config.PopupQueueConfig)
local PromptMoments = require(script.PromptMoments)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local RewardPreview = require(script.Parent.DailyRewards.RewardPreview)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local NAME = "NotifyPrompt"
local Prompt = NotifyConfig.Prompt
-- True when PopupQueueConfig declares the card's queue kind (the lead adds it with R122).
local QUEUE_READY = (PopupQueueConfig.Kinds :: any)[Prompt.QueueKind] ~= nil
-- Longest wait for Roblox's dialog to close (it always should; this only frees the button).
-- Shorter than RetentionConfig.Notify.ArmWindowSeconds so an "accepted" stays inside the arm.
local PROMPT_WAIT_SECONDS = math.min(120, RetentionConfig.Notify.ArmWindowSeconds - 30)
-- Seconds "You're all set!" stays before the window closes after the claim.
local CLOSE_AFTER_CLAIM = 1.5

local Neutral = UIStyleConfig.Neutral
local OK_COLOR = UIStyleConfig.Colors.green.accent
local ERROR_COLOR = Neutral.Danger

type Report = "shown" | "accepted" | "declined"
type Moment = PromptMoments.Moment

-- True when the snapshot says the notify reward was already paid.
local function isClaimed(profile: ClientState.Profile?): boolean
	local notify = if profile ~= nil then profile.notify else nil
	return type(notify) == "table" and notify.claimed == true
end

-- Sends one report to the server (intent only).
local function report(status: Report)
	Remotes.event("ClaimNotifyReward"):FireServer(status)
end

-- Tells the server the card opened at `moment` (analytics "rnotify:promptAt:<moment>").
local function reportCard(moment: Moment)
	Remotes.event("ClaimNotifyReward"):FireServer("card", moment)
end

--[[
	True when the card may open over the screen right now: the join queue is quiet (nothing
	queued ahead, no window / cinematic / plot reveal, not a guided tutorial step, no purchase
	flow) and Roblox's own menu is closed.
]]
local function calmMoment(): boolean
	return JoinFlow.isQuiet() and not GuiService.MenuIsOpen
end

-- CanPromptOptInAsync, guarded: (call succeeded, can prompt).
local function canPrompt(): (boolean, boolean)
	local ok, can = pcall(function(): boolean
		return ExperienceNotificationService:CanPromptOptInAsync()
	end)
	return ok, ok and can == true
end

--[[
	Opens Roblox's opt-in dialog and yields until OptInPromptClosed fires once (or
	PROMPT_WAIT_SECONDS pass). The listener is connected BEFORE the prompt so a fast close is
	never missed.
	@return true when the dialog was opened
]]
local function promptAndWait(): boolean
	local closed = false
	local wake = Instance.new("BindableEvent")
	local connection = ExperienceNotificationService.OptInPromptClosed:Once(function()
		closed = true
		wake:Fire()
	end)
	local timer = task.delay(PROMPT_WAIT_SECONDS, function()
		closed = true
		wake:Fire()
	end)
	local opened = pcall(function()
		ExperienceNotificationService:PromptOptIn()
	end)
	if opened and not closed then
		wake.Event:Wait()
	end
	connection:Disconnect()
	if coroutine.status(timer) == "suspended" then
		task.cancel(timer)
	end
	wake:Destroy()
	return opened
end

return StudUI.modalScreen({
	name = NAME,
	title = "Get notified!",
	color = "blue",
	icon = "Star",
	size = Vector2.new(820, 540),
	lazy = false,
	--[[
		Fills the window and starts the once-per-session auto-suggest.
		@param window the StudUI window
		@return ScreenHandle (gamepad starts on TURN ON)
	]]
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		local body = window.body
		Create.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 12),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = body,
		})
		StudUI.text({
			name = "Pitch",
			text = "Turn on notifications and get a free reward!",
			textSize = 44,
			wrap = true,
			size = UDim2.new(1, -20, 0, 110),
			layoutOrder = 1,
			parent = body,
		})

		-- Reward preview: icon + "+25 Gems" chips in one centred row.
		local rewardRow = Create.new("Frame", {
			Name = "Reward",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 84),
			LayoutOrder = 2,
			Parent = body,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, 30),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame
		local rewardRendered = false

		-- Builds the reward chips once (the notify reward has no income-scaled part to refresh).
		local function renderReward()
			if rewardRendered then
				return
			end
			rewardRendered = true
			for index, line in RewardPreview.lines(RetentionConfig.Notify.Reward, ClientState.profile) do
				local chip = Create.new("Frame", {
					Name = `Chip{index}`,
					BackgroundTransparency = 1,
					Size = UDim2.fromOffset(0, 84),
					AutomaticSize = Enum.AutomaticSize.X,
					LayoutOrder = index,
					Parent = rewardRow,
					Children = {
						Create.new("UIListLayout", {
							FillDirection = Enum.FillDirection.Horizontal,
							VerticalAlignment = Enum.VerticalAlignment.Center,
							Padding = UDim.new(0, 8),
							SortOrder = Enum.SortOrder.LayoutOrder,
						}),
					},
				}) :: Frame
				local icon = StudUI.icon(line.icon, 76, 2)
				icon.LayoutOrder = 1
				icon.Parent = chip
				StudUI.text({
					name = "Amount",
					text = `+{line.text}`,
					textSize = 44,
					font = "number",
					color = UIStyleConfig.Colors.yellow.accent,
					size = UDim2.fromOffset(0, 84),
					autoWidth = true,
					layoutOrder = 2,
					parent = chip,
				})
			end
		end

		local buttonRow = Create.new("Frame", {
			Name = "Buttons",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 96),
			LayoutOrder = 3,
			Parent = body,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Top,
					Padding = UDim.new(0, 18),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame
		local status = StudUI.text({
			name = "Status",
			text = "",
			textSize = 30,
			wrap = true,
			size = UDim2.new(1, -20, 0, 44),
			layoutOrder = 4,
			parent = body,
		})

		-- Shows `text` in the status line.
		local function setStatus(text: string, color: Color3)
			status.Text = text
			status.TextColor3 = color
		end

		local busy = false -- a TURN ON flow is running
		local prompted = false -- PromptOptIn already used this session (never twice)
		local suggested = false -- the session's one suggestion happened (auto or manual open)
		local turnOn: StudUI.Button

		-- TURN ON state: disabled while a flow runs, CLAIMED once paid.
		local function renderButton()
			if isClaimed(ClientState.profile) then
				turnOn.setState("claimed")
			else
				turnOn.setState(if busy then "disabled" else "normal")
			end
		end

		-- The TURN ON flow (see the module header); runs on its own thread (yields).
		local function runTurnOn()
			local ok, can = canPrompt()
			if not ok then
				setStatus("Notifications aren't available right now. Try again later!", ERROR_COLOR)
				return
			end
			if not can then
				-- Nothing to ask: notifications are already on for this experience.
				report("shown")
				report("accepted")
				setStatus("You're all set!", OK_COLOR)
				return
			end
			if prompted then
				setStatus("You can turn them on any time in your Roblox settings!", Neutral.TextDim)
				return
			end
			prompted = true
			report("shown")
			if not promptAndWait() then
				report("declined")
				setStatus("Couldn't open the notification prompt. Try again later!", ERROR_COLOR)
				return
			end
			local okAfter, stillCan = canPrompt()
			if okAfter and not stillCan then
				report("accepted")
				setStatus("You're all set!", OK_COLOR)
			else
				report("declined")
				setStatus("No problem! You can turn them on later.", Neutral.TextDim)
			end
		end

		turnOn = StudUI.button({
			text = "TURN ON",
			color = "green",
			textSize = 46,
			size = UDim2.fromOffset(290, 88),
			name = "TurnOn",
			layoutOrder = 1,
			parent = buttonRow,
			onActivated = function()
				if busy or isClaimed(ClientState.profile) then
					return
				end
				busy = true
				renderButton()
				setStatus("Checking...", Neutral.TextDim)
				task.spawn(function()
					local ok, err = pcall(runTurnOn)
					if not ok then
						warn(`[NotifyPrompt] turn on failed: {err}`)
						setStatus("Something went wrong. Try again later!", ERROR_COLOR)
					end
					busy = false
					renderButton()
					-- Roblox's dialog may drop the gamepad cursor: back onto TURN ON.
					if ScreenManager.isOpen(NAME) then
						GamepadNav.select(turnOn.instance)
					end
				end)
			end,
		})
		local later = StudUI.button({
			text = "LATER",
			color = "grey",
			textSize = 46,
			size = UDim2.fromOffset(230, 88),
			name = "Later",
			layoutOrder = 2,
			parent = buttonRow,
			onActivated = function()
				ScreenManager.close(NAME)
			end,
		})

		-- Gamepad: TURN ON <-> LATER across, up to the header X; the cursor starts on TURN ON.
		GamepadNav.linkList({ turnOn.instance, later.instance }, false, { up = window.closeButton })
		local selectDefault = GamepadNav.defaultSelection(body, turnOn.instance)

		-- Closes the window once the server has paid (after "You're all set!" had a moment).
		ClientState.ProfileChanged:Connect(function(profile: ClientState.Profile, fields: { string }?)
			if fields ~= nil and table.find(fields, "notify") == nil then
				return
			end
			renderButton()
			if isClaimed(profile) and ScreenManager.isOpen(NAME) then
				task.delay(CLOSE_AFTER_CLAIM, function()
					if ScreenManager.isOpen(NAME) and isClaimed(ClientState.profile) then
						ScreenManager.close(NAME)
					end
				end)
			end
		end)

		-- Auto-suggest at a strong moment (owner R122; see the module header) --------------------
		local asking = false -- a moment is waiting for its turn (one at a time)
		local cardReported = false -- the session's "card" report was sent
		local queueHandle: PopupQueue.Handle? = nil -- the popup-queue slot while the card is up
		local startSnap: PromptMoments.Snapshot? = nil
		local lastSnap: PromptMoments.Snapshot? = nil

		-- True when nothing more should be suggested this session.
		local function finished(): boolean
			return suggested or isClaimed(ClientState.profile)
		end

		-- Frees the popup-queue slot (the card closed / was never shown).
		local function releaseSlot()
			local handle = queueHandle
			queueHandle = nil
			if handle ~= nil then
				handle.done()
			end
		end

		-- Opens the card for `moment` (the gates already passed). @return true when it opened
		local function openFor(moment: Moment): boolean
			if finished() then
				return false
			end
			ScreenManager.open(NAME, { source = moment })
			return ScreenManager.isOpen(NAME)
		end

		-- Fallback without the queue kind: polls the same gates + "no centre popup" (bounded).
		local function waitPolitely(moment: Moment)
			local calm, waited = 0, 0
			while waited < Prompt.MaxWaitSeconds and not finished() do
				if calmMoment() and not PopupQueue.centerActive() then
					calm += 1
					if calm >= Prompt.CalmChecks then
						openFor(moment)
						return
					end
				else
					calm = 0
				end
				task.wait(Prompt.CheckSeconds)
				waited += Prompt.CheckSeconds
			end
		end

		-- Asks for the card's turn at `moment` (yields until shown / expired). Runs on its own thread.
		local function suggest(moment: Moment)
			task.wait(Prompt.MomentDelaySeconds)
			if finished() then
				return
			end
			-- Nothing to gain when Roblox would not show its dialog (already opted in, under 13,
			-- asked in the last 30 days): no card.
			local ok, can = canPrompt()
			if not ok or not can then
				return
			end
			if not QUEUE_READY then
				waitPolitely(moment)
				return
			end
			local resolved = false
			local wake = Instance.new("BindableEvent")
			local function resolve()
				if not resolved then
					resolved = true
					wake:Fire()
				end
			end
			local handle = PopupQueue.request({
				kind = Prompt.QueueKind,
				maxShow = Prompt.MaxShowSeconds, -- the player reads at their own pace; done() on close
				canShow = function(): boolean
					return calmMoment() and not finished()
				end,
				show = function(): boolean
					local opened = openFor(moment)
					resolve()
					return opened
				end,
				hide = function(reason: string)
					-- Only a cinematic that must cut in (pre-emption) closes the card.
					if reason == "preempted" and ScreenManager.isOpen(NAME) then
						ScreenManager.close(NAME)
					end
					queueHandle = nil
				end,
				onExpire = resolve,
			})
			if handle == nil then
				wake:Destroy()
				waitPolitely(moment)
				return
			end
			queueHandle = handle
			if not resolved then
				task.delay(Prompt.MaxWaitSeconds + Prompt.WaitSlackSeconds, resolve) -- never wait forever
				wake.Event:Wait()
			end
			wake:Destroy()
			if not handle.showing() then
				handle.cancel()
				if queueHandle == handle then
					queueHandle = nil
				end
			end
		end

		-- Starts a moment's suggestion unless one is already waiting / the session is done.
		local function consider(moment: Moment?)
			if moment == nil or asking or finished() then
				return
			end
			asking = true
			task.spawn(function()
				local ok, err = pcall(suggest, moment)
				if not ok then
					warn(`[NotifyPrompt] suggest failed: {err}`)
				end
				asking = false
			end)
		end

		-- Watches the main-world tycoon for the manager / area 2 moments.
		ClientState.ProfileChanged:Connect(function(profile: ClientState.Profile, fields: { string }?)
			if fields ~= nil and table.find(fields, "tycoon") == nil then
				return
			end
			local current = PromptMoments.snapshot(profile, TycoonConfig.PadsById)
			if current == nil then
				return
			end
			local start, previous = startSnap, lastSnap
			lastSnap = current
			if start == nil or previous == nil then
				return -- the session's first snapshot is handled by the boot thread below
			end
			consider(PromptMoments.momentFor(start, previous, current))
		end)

		-- Boot: the session's starting snapshot; a returning player with nothing left to happen
		-- gets the fallback timer ("other").
		task.spawn(function()
			local profile = ClientState.waitForProfile()
			if profile == nil then
				return
			end
			local snap = PromptMoments.snapshot(ClientState.profile or profile, TycoonConfig.PadsById)
				or { managers = 0, area = 1 }
			startSnap = snap
			lastSnap = lastSnap or snap
			-- Nothing can happen this session → the short fallback; otherwise a late floor in case
			-- no moment came (a returning player who stays in area 1).
			task.wait(
				if PromptMoments.needsFallback(snap) then Prompt.FallbackDelaySeconds else Prompt.LateFallbackSeconds
			)
			consider("other")
		end)

		return {
			onOpen = function(args: any?)
				suggested = true
				if isClaimed(ClientState.profile) then
					-- Nothing left to offer: never show a stale prompt.
					task.defer(ScreenManager.close, NAME)
					return
				end
				if not cardReported then
					-- One "rnotify:promptAt" per session: the moment that showed the card first
					-- (keeps the shared ClaimNotifyReward rate limit free for TURN ON).
					cardReported = true
					local source = if type(args) == "table" then args.source else nil
					reportCard(PromptMoments.momentOfSource(source))
				end
				renderReward()
				renderButton()
				if not busy then
					setStatus("", Neutral.TextDim)
				end
			end,
			onClose = function()
				releaseSlot()
			end,
			defaultSelection = selectDefault,
		}
	end,
})
