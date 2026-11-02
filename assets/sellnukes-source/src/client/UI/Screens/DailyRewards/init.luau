--!strict
--[[
	DailyRewards — the "Daily Rewards" window (reference docs/reference/ui-style/01-daily-rewards.png,
	design spec §7): a red header with the calendar icon, six sky-blue stud cards (Day 1..6) in a
	3 x 2 grid and the big RAINBOW Day 7 card spanning both rows on the right.

	Each card shows (Screens/DailyRewards/CardGrid draws it):
		title    "Day N" — or, for the NEXT card once today's reward is claimed, a live countdown
		         to the next UTC midnight ("11:48:16"); at 0 the window re-renders
		icon     the reward's first icon (RewardPreview.lines)
		caption  the day's word ("One" .. "Seven") + the reward headline, small
		button   CLAIMED (cards 1..claimedUpTo) / green CLAIM (the next card when a claim is open)
		         / LOCKED! (everything else)

	The status comes from the SAME pure rule the server's claim uses:
		RetentionConfig.dailyStatus(profile.daily, RetentionConfig.utcDay(serverNow))
	so the window and the server always agree. CLAIM only sends the intent
	(Remotes ClaimDaily); the server answers with a profile push + a toast. Reward amounts are
	previews (RewardPreview mirrors the server's cash rule); the server grants the real ones.

	Boot (lazy = false): the screen listens from boot so the HUD "Daily" button carries a "!"
	badge whenever a claim is open — recomputed on every `daily` profile change and at UTC
	midnight (one cancellable timer). Boot work stays tiny: the cards themselves are built on
	first open.

	Console + mobile (owner R11): the window is a ResponsiveModal with CardGrid.Modes — the
	reference 3 x 2 + big card ("grid") on desktop / console / tablet, one row of seven cards
	("row") on a landscape phone so buttons reach 44 pt and text 14 pt; the grid re-lays out on
	every layout change. Gamepad: the cards' buttons are linked (CardGrid), the cursor starts on
	CLAIM when a claim is open, else on the first card (never the close X); B closes.

	Performance: event-driven only (profile pushes, the midnight timer, one countdown); while the
	window is closed only the badge is recomputed. Cards are built once and updated by setters.

	Connects to: Kit/StudUI, Screens/DailyRewards/{CardGrid, ResponsiveModal, RewardPreview},
	Platform/GamepadNav, Client/ClientState,
	Hud/Hud (badge), Analytics/ClientAnalytics (screenOpened "Daily"), Shared/Config/
	RetentionConfig, Shared/Net/Remotes (ClaimDaily). Opened by the HUD "Daily" button
	(HudZonesConfig.Left) and by name: ScreenManager.open("DailyRewards", { source = "welcomeBack" }).

	Example:
		ScreenManager.open("DailyRewards")                         -- analytics source "hud"
		ScreenManager.open("DailyRewards", { source = "welcomeBack" })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CardGrid = require(script.CardGrid)
local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local Hud = require(script.Parent.Parent.Hud.Hud)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ResponsiveModal = require(script.ResponsiveModal)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local RewardPreview = require(script.RewardPreview)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)

local NAME = "DailyRewards"
-- HUD button key for the "!" badge and the analytics screen id.
local HUD_KEY = "Daily"
local ANALYTICS_ID = "Daily"
-- After CLAIM, the button stays "sending" this long unless the server's push arrives first
-- (a rejected claim gets no push; the button comes back by itself).
local CLAIM_PENDING_SECONDS = 3
-- Profile fields that change the badge, and the ones that change what the open window shows
-- (the streak, plus the income the cash previews scale with).
local BADGE_FIELDS = { "daily" }
local VIEW_FIELDS = { "daily", "tycoon", "rebirths", "rebirthShop" }

-- The status shown while no profile has arrived yet: nothing claimable, nothing counting down.
local EMPTY_STATUS: RetentionConfig.DailyStatus = table.freeze({
	canClaim = false,
	nextIndex = 0,
	claimedUpTo = 0,
	resetting = false,
}) :: any -- frozen = read-only at runtime; cast because freeze yields read-only property types

-- profile.daily, validated (nil when missing or malformed).
type Daily = { streak: number, lastDay: number }

--[[
	Reads profile.daily defensively (server truth, but a broken push must never error the UI).
	@param profile the ClientState snapshot (may be nil early)
	@return { streak, lastDay } or nil
]]
local function readDaily(profile: ClientState.Profile?): Daily?
	-- Read through an `any` local: a `type(...) == "table"` refinement on the profile path would
	-- narrow it to a key-less `table`.
	local raw: any = if profile ~= nil then profile.daily else nil
	if type(raw) ~= "table" then
		return nil
	end
	local streak, lastDay = raw.streak, raw.lastDay
	if type(streak) ~= "number" or type(lastDay) ~= "number" or streak ~= streak or lastDay ~= lastDay then
		return nil
	end
	return { streak = streak, lastDay = lastDay }
end

--[[
	True when a ProfileChanged push touches any of `watched` (`fields` nil = a full snapshot).
	Example: touches({ "cash" }, { "daily" }) --> false
]]
local function touches(fields: { string }?, watched: { string }): boolean
	if fields == nil then
		return true
	end
	for _, field in watched do
		if table.find(fields, field) ~= nil then
			return true
		end
	end
	return false
end

--[[ The analytics source from ScreenManager.open's args ({ source = "..." }), default "hud". ]]
local function sourceOf(args: any?): string
	if type(args) == "table" and type(args.source) == "string" then
		return args.source
	end
	return "hud"
end

return ResponsiveModal.screen({
	name = NAME,
	title = "Daily Rewards",
	color = "red",
	icon = "Daily",
	-- Reference grid (≈ 910 x 605 in the shot; a little taller for the headlines) + phone row.
	modes = CardGrid.Modes,
	lazy = false, -- listens from boot for the HUD badge (cards are built on first open)
	build = function(
		window: StudUI.Window,
		_gui: ScreenGui,
		layout: ResponsiveModal.Controller
	): ScreenManager.ScreenHandle?
		local grid: CardGrid.Grid? = nil
		local isOpen = false
		local refreshQueued = false
		local lastBadge: string? = nil
		local status: RetentionConfig.DailyStatus = EMPTY_STATUS
		-- Server time until which the just-pressed CLAIM shows as "sending" (0 = none).
		local claimPendingUntil = 0

		local refresh: () -> ()

		-- Coalesces every trigger in a frame into ONE refresh (also keeps countdown callbacks,
		-- which run on StudUI's ticker thread, from building UI inside the ticker loop).
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

		-- One wake-up at the next UTC midnight (a claim opens / a missed day resets the streak).
		local midnight = CardGrid.wakeTimer(requestRefresh)

		-- Sends the claim intent for the card that shows CLAIM (the server re-checks it).
		local function claim(index: number)
			if not status.canClaim or index ~= status.nextIndex then
				return
			end
			claimPendingUntil = RewardPreview.serverNow() + CLAIM_PENDING_SECONDS
			local currentGrid = grid
			if currentGrid ~= nil then
				currentGrid.cells[index].button.setState("disabled")
			end
			Remotes.event("ClaimDaily"):FireServer()
			-- No push (rejected / rate-limited)? Re-enable the button after the pending window.
			task.delay(CLAIM_PENDING_SECONDS + 0.05, requestRefresh)
		end

		-- Builds the card grid once (first open), keeping boot work to the window + listeners.
		local function ensureGrid(): CardGrid.Grid
			local current = grid
			if current ~= nil then
				return current
			end
			local created = CardGrid.new({
				parent = window.body,
				color = "sky",
				bigColor = "rainbow",
				captions = true,
				onClaim = claim,
			})
			created.layout(layout.current())
			grid = created
			return created
		end

		-- Phone rotation / device switch: re-place the cards (built ones only; no rebuild).
		layout.onChanged(function(current: ResponsiveModal.Layout)
			local cards = grid
			if cards ~= nil then
				cards.layout(current)
			end
		end)

		-- Writes every card from `status` (see the module header for the per-card rules).
		local function renderCards(now: number, profile: ClientState.Profile?)
			local cards = ensureGrid()
			local claimPending = now < claimPendingUntil
			for index, day in RetentionConfig.Days do
				local cell = cards.cells[index]
				if cell == nil then
					continue -- more days in config than cards: never index past the grid
				end
				local lines = RewardPreview.lines(day.reward, profile)
				cell.setIcon(if lines[1] ~= nil then lines[1].icon else day.icon)
				cell.setCaption(day.label)
				cell.setDetail(RewardPreview.headline(day.reward, profile))
				local isNext = index == status.nextIndex
				if isNext and not status.canClaim then
					-- Claimed today: the next card counts down to UTC midnight, then re-renders.
					cell.setCountdown(now + RetentionConfig.secondsToNextDay(now), "hms", requestRefresh)
				else
					cell.setTitle(`Day {index}`)
				end
				if index <= status.claimedUpTo then
					cell.button.setState("claimed")
				elseif isNext and status.canClaim then
					cell.button.setState(if claimPending then "disabled" else "normal")
				else
					cell.button.setState("locked")
				end
			end
		end

		-- Recomputes the status + badge + midnight timer; redraws the cards while open.
		refresh = function()
			local profile = ClientState.profile
			local now = RewardPreview.serverNow()
			local daily = readDaily(profile)
			status = if daily ~= nil
				then RetentionConfig.dailyStatus(daily, RetentionConfig.utcDay(now))
				else EMPTY_STATUS
			local badge = if status.canClaim then "!" else nil
			if badge ~= lastBadge then
				lastBadge = badge
				Hud.setButtonBadge(HUD_KEY, badge)
			end
			midnight.schedule(RetentionConfig.secondsToNextDay(now))
			if isOpen then
				renderCards(now, profile)
			end
		end

		ClientState.ProfileChanged:Connect(function(_profile: ClientState.Profile, fields: { string }?)
			if touches(fields, BADGE_FIELDS) then
				claimPendingUntil = 0 -- the server answered (or resynced): show its truth
			end
			if touches(fields, if isOpen then VIEW_FIELDS else BADGE_FIELDS) then
				requestRefresh()
			end
		end)
		-- Initial badge (the profile may already be here at boot).
		requestRefresh()

		return {
			onOpen = function(args: any?)
				isOpen = true
				refresh()
				ClientAnalytics.screenOpened(ANALYTICS_ID, sourceOf(args))
			end,
			onClose = function()
				isOpen = false
			end,
			-- Gamepad starts on CLAIM when a claim is open, else on the first card (never the X).
			defaultSelection = function(): GuiObject?
				local cards = grid
				if cards == nil then
					return nil
				end
				local claimCell = if status.canClaim then cards.cells[status.nextIndex] else nil
				local preferred = if claimCell ~= nil then claimCell else cards.cells[1]
				return GamepadNav.defaultSelection(window.body, preferred.button.instance)()
			end,
		}
	end,
})
