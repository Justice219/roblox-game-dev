--!strict
--[[
	TimeRewards — the "Time Rewards" window, reworked as the owner R89 EARLY GIFT LADDER (spec
	2026-10-31-r89-competitive-wave-design §3): a green header with the clock icon, a toolbar
	(gifts opened today, "Playtime saved all day!", a progress bar to the last gift with the
	next-gift countdown, CLAIM ALL) and TEN orange stud gift cards — the last one rainbow. Gifts
	unlock with TODAY's online playtime (PlaytimeConfig.Gifts: 1, 3, 5, 10, 15, 25, 40, 60, 90,
	120 minutes); progress is kept across rejoins the same UTC day, a new UTC day starts a fresh
	ladder.

	Each card (Screens/TimeRewards/GiftGrid draws it):
		title    LOCKED: a live countdown of the playtime still needed ("00:41", "1:12:30");
		         READY: "Ready!" (+ a glowing ring); CLAIMED: the playtime it needed ("5 Min")
		icon     the gift's picture; under it the reward, one part per line ("$1.25K",
		         "10 Gems" / "2 Spins", "5 Gems" / "Supply Crate" — or the crate's fallback gems
		         folded in where paid random items are restricted, from profile.policy)
		button   LOCKED! / green CLAIM / CLAIMED
	CLAIM ALL opens every ready gift in one server step (ClaimTimeRewardsAll); it reads
	"CLAIM ALL (3)" when several are ready and is locked while none is.

	Playtime on the client: the server counts it (Server/Services/PlaytimeService) and pushes
	`timeRewards` every PlaytimeConfig.PushEverySeconds and on every claim / day rollover. Between
	pushes playtime advances at wall-clock rate, so the window extrapolates:
		extraSeconds = serverNow - (server time the last `timeRewards` push arrived)
		views = PlaytimeConfig.status(profile.timeRewards, today, extraSeconds)
	(a counter from an earlier day only counts from today's UTC midnight). A locked gift's
	countdown ends at serverNow + secondsLeft, the same instant on every refresh, so the clock
	never jumps between pushes. CLAIM / CLAIM ALL only send intents; the server re-checks the
	playtime and answers with a profile push + a toast.

	Join rules (owner R78 first-minute fix, kept): this window NEVER opens by itself — a ready gift
	only lights the Rewards hub badge (UI/RewardsBadges) and the legacy "Time" HUD key badge, so
	nothing competes with the guided tutorial or the JoinFlow queue.

	Boot (lazy = false): listens from boot for the badge — recomputed on every `timeRewards` push and
	by ONE cancellable timer at the next gift's unlock (or UTC midnight, whichever is first) — and
	starts FavoriteClient (the one-time favorite prompt, owner R89). Cards are built on first open.

	Performance: event-driven only (pushes, the one timer, StudUI's shared 1 Hz countdown ticker
	for visible countdowns); while closed only the badge is recomputed.

	Console + mobile (owner R11): ResponsiveModal with GiftGrid.Modes — "grid" (5 x 2) on desktop /
	console / tablet, a sideways-SCROLLING "row" on a landscape phone so buttons reach 44 pt and
	text 14 pt. Gamepad: the gift buttons are linked (GiftGrid; Up from the top row = CLAIM ALL);
	the cursor starts on CLAIM ALL when 2+ gifts are ready, else on the first READY gift's CLAIM,
	else on the first gift (never the close X); B closes.

	Connects to: Kit/StudUI, Screens/TimeRewards/{GiftGrid, FavoriteClient},
	Screens/DailyRewards/{CardGrid (wake timer), ResponsiveModal, RewardPreview}, Platform/GamepadNav,
	Client/ClientState, Hud/Hud (badge), Analytics/ClientAnalytics (screenOpened "Time"),
	Shared/Config/{PlaytimeConfig, RetentionConfig, CrateConfig, EggConfig (policyState)},
	Shared/Util/NumberFormat, Shared/Net/Remotes (ClaimTimeReward, ClaimTimeRewardsAll). Opened
	from the Rewards hub tile "Playtime" (RewardsHubConfig).

	Example:
		ScreenManager.open("TimeRewards")                    -- analytics source "hud"
		ScreenManager.open("TimeRewards", { source = "hub" })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoostConfig = require(ReplicatedStorage.Shared.Config.BoostConfig)
local CardGrid = require(script.Parent.DailyRewards.CardGrid)
local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local FavoriteClient = require(script.FavoriteClient)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local GiftGrid = require(script.GiftGrid)
local Hud = require(script.Parent.Parent.Hud.Hud)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PlaytimeConfig = require(ReplicatedStorage.Shared.Config.PlaytimeConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ResponsiveModal = require(script.Parent.DailyRewards.ResponsiveModal)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local RewardPreview = require(script.Parent.DailyRewards.RewardPreview)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)

local NAME = "TimeRewards"
-- HUD button key for the "!" badge and the analytics screen id.
local HUD_KEY = "Time"
local ANALYTICS_ID = "Time"
-- After CLAIM / CLAIM ALL, buttons stay "sending" this long unless the server's push arrives first.
local CLAIM_PENDING_SECONDS = 3
-- Profile fields that change the badge, and the ones that change what the open window shows.
local BADGE_FIELDS = { "timeRewards" }
local VIEW_FIELDS = { "timeRewards", "tycoon", "rebirths", "rebirthShop", "policy" }
-- The last gift's mark (the toolbar progress bar's 100%).
local LADDER_SECONDS = PlaytimeConfig.Gifts[#PlaytimeConfig.Gifts].minutes * 60

-- profile.timeRewards, validated (claimed: the snapshot's sorted index array).
type TimeState = { day: number, seconds: number, claimed: { [number]: any } }

--[[
	Reads profile.timeRewards defensively (server truth, but a broken push must never error the
	UI). An unreadable `claimed` reads as "nothing claimed" (the server still refuses repeats).
	@param profile the ClientState snapshot (may be nil early)
	@return the state, or nil when missing / malformed
]]
local function readState(profile: ClientState.Profile?): TimeState?
	-- Read through an `any` local: a `type(...) == "table"` refinement on the profile path would
	-- narrow it to a key-less `table`.
	local raw: any = if profile ~= nil then profile.timeRewards else nil
	if type(raw) ~= "table" then
		return nil
	end
	if
		type(raw.day) ~= "number"
		or type(raw.seconds) ~= "number"
		or raw.day ~= raw.day
		or raw.seconds ~= raw.seconds
	then
		return nil
	end
	local claimed: { [number]: any } = if type(raw.claimed) == "table" then raw.claimed :: any else {}
	return { day = raw.day, seconds = raw.seconds, claimed = claimed }
end

--[[
	Playtime earned since the last push (wall-clock rate while in game), never negative.
	A counter from an EARLIER day only counts from today's UTC midnight (the server starts a fresh
	ladder then); a counter from a LATER day (clock behind) never extrapolates.
	Example: extraSeconds({ day = 100, ... }, 100, 8_640_090, 8_640_060) --> 30
]]
local function extraSeconds(state: TimeState, today: number, now: number, receivedAt: number): number
	if state.day > today then
		return 0
	end
	local since = if state.day == today then receivedAt else math.max(receivedAt, today * RetentionConfig.SecondsPerDay)
	return math.max(0, now - since)
end

--[[
	Short playtime label for a claimed gift's title.
	Example: playLabel(5) --> "5 Min"; playLabel(60) --> "1 Hour"; playLabel(90) --> "1h 30m"
]]
local function playLabel(minutes: number): string
	if minutes < 60 then
		return `{minutes} Min`
	end
	if minutes % 60 == 0 then
		local hours = minutes // 60
		return `{hours} Hour{if hours == 1 then "" else "s"}`
	end
	return NumberFormat.duration(minutes * 60)
end

--[[
	The reward lines of a gift card for this profile, one part per line (GiftGrid shows up to three):
	the shared reward preview (cash with the server's own rule, gems, spins), boosts in a compact
	"2x Cash 15m", then the crate ("Supply Crate") — or, where paid random items are restricted,
	the crate's fallback gems folded into the gems line.
	Example: giftDetail(PlaytimeConfig.Gifts[7], profile) --> "5 Gems\nSupply Crate"
]]
local function giftDetail(gift: PlaytimeConfig.Gift, profile: ClientState.Profile?): string
	local reward = gift.reward
	local crate = gift.crate
	local policy = if profile ~= nil then profile.policy else nil
	local crateAsGems = crate ~= nil and EggConfig.policyState(policy) == "restricted"
	if crate ~= nil and crateAsGems then
		local shown = table.clone(reward)
		shown.gems = (shown.gems or 0) + crate.fallbackGems
		reward = shown
	end
	local lines: { string } = {}
	for _, line in RewardPreview.lines(reward, profile) do
		table.insert(lines, line.text)
	end
	-- Boosts: "2x Cash 15m" instead of the preview's "2x Cash 15m 00s" (fits a card line).
	local boost = reward.boost
	if boost ~= nil then
		local def = BoostConfig.get(boost.key)
		local minutes = boost.seconds / 60
		local compact = if minutes % 1 == 0 then `{minutes}m` else NumberFormat.duration(boost.seconds)
		-- RewardPreview.lines order is fixed: cash, gems, spins, boost, pet, egg.
		local boostIndex = #lines - (if reward.pet ~= nil then 1 else 0) - (if reward.egg ~= nil then 1 else 0)
		if boostIndex >= 1 then
			lines[boostIndex] = `{if def ~= nil then def.name else "Boost"} {compact}`
		end
	end
	if crate ~= nil and not crateAsGems then
		local def = CrateConfig.get(crate.id)
		table.insert(lines, if def ~= nil then def.name else "Crate")
	end
	return table.concat(lines, "\n")
end

--[[
	True when a ProfileChanged push touches any of `watched` (`fields` nil = a full snapshot).
	Example: touches({ "cash" }, { "timeRewards" }) --> false
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
	title = "Time Rewards",
	color = "green",
	icon = "Time",
	modes = GiftGrid.Modes,
	lazy = false, -- listens from boot for the badge + favorite moments (cards on first open)
	build = function(
		window: StudUI.Window,
		_gui: ScreenGui,
		layout: ResponsiveModal.Controller
	): ScreenManager.ScreenHandle?
		local grid: GiftGrid.Grid? = nil
		local isOpen = false
		local refreshQueued = false
		local lastBadge: string? = nil
		local views: { PlaytimeConfig.GiftView } = {}
		local readyCount = 0
		-- Server time the last `timeRewards` push arrived (the extrapolation base).
		local receivedAt = RewardPreview.serverNow()
		-- Per gift: server time until which its just-pressed CLAIM shows as "sending".
		local claimPendingUntil: { [number]: number } = {}
		-- Server time until which CLAIM ALL shows as "sending".
		local claimAllPendingUntil = 0

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

		-- One wake-up at the next gift unlock or UTC midnight (badge + cards stay current).
		local wake = CardGrid.wakeTimer(requestRefresh)

		-- Sends the claim intent for a READY gift (the server re-checks the playtime).
		local function claim(index: number)
			local view = views[index]
			if view == nil or view.state ~= "ready" then
				return
			end
			claimPendingUntil[index] = RewardPreview.serverNow() + CLAIM_PENDING_SECONDS
			local currentGrid = grid
			if currentGrid ~= nil then
				currentGrid.cells[index].button.setState("disabled")
			end
			Remotes.event("ClaimTimeReward"):FireServer(index)
			-- No push (rejected / rate-limited)? Re-enable the button after the pending window.
			task.delay(CLAIM_PENDING_SECONDS + 0.05, requestRefresh)
		end

		-- Sends the CLAIM ALL intent when anything is ready (the server opens what is ready).
		local function claimAll()
			if readyCount < PlaytimeConfig.ClaimAllMin then
				return
			end
			local now = RewardPreview.serverNow()
			claimAllPendingUntil = now + CLAIM_PENDING_SECONDS
			local currentGrid = grid
			for _, view in views do
				if view.state == "ready" then
					claimPendingUntil[view.index] = now + CLAIM_PENDING_SECONDS
					if currentGrid ~= nil then
						currentGrid.cells[view.index].button.setState("disabled")
					end
				end
			end
			if currentGrid ~= nil then
				currentGrid.claimAll.setState("disabled")
			end
			Remotes.event("ClaimTimeRewardsAll"):FireServer()
			task.delay(CLAIM_PENDING_SECONDS + 0.05, requestRefresh)
		end

		-- Builds the gift grid once (first open), keeping boot work to the window + listeners.
		local function ensureGrid(): GiftGrid.Grid
			local current = grid
			if current ~= nil then
				return current
			end
			local created = GiftGrid.new({
				parent = window.body,
				count = #PlaytimeConfig.Gifts,
				bigIndex = #PlaytimeConfig.Gifts,
				color = "orange",
				onClaim = claim,
				onClaimAll = claimAll,
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

		-- Writes every gift card + the toolbar from `views` (see the module header).
		local function renderCards(now: number, profile: ClientState.Profile?, state: TimeState?)
			local cards = ensureGrid()
			local claimedCount = 0
			local nextLocked: PlaytimeConfig.GiftView? = nil
			for index, gift in PlaytimeConfig.Gifts do
				local cell = cards.cells[index]
				if cell == nil then
					continue -- more gifts in config than cards: never index past the grid
				end
				cell.setIcon(gift.icon)
				cell.setDetail(giftDetail(gift, profile))
				local view = views[index]
				if view == nil then
					-- No profile yet: show the full requirement, locked.
					cell.setTitle(playLabel(gift.minutes))
					cell.button.setState("locked")
					cell.setReady(false)
				elseif view.state == "claimed" then
					claimedCount += 1
					cell.setTitle(playLabel(gift.minutes))
					cell.button.setState("claimed")
					cell.setReady(false)
				elseif view.state == "ready" then
					cell.setTitle("Ready!")
					local pending = now < (claimPendingUntil[index] or 0)
					cell.button.setState(if pending then "disabled" else "normal")
					cell.setReady(not pending)
				else
					-- Locked: count down the playtime still needed; at 0 the window re-renders.
					cell.setCountdown(now + view.secondsLeft, requestRefresh)
					cell.button.setState("locked")
					cell.setReady(false)
					if nextLocked == nil then
						nextLocked = view
					end
				end
			end
			-- Toolbar: opened count, progress to the last gift, the next gift / midnight countdown.
			cards.setOpened(claimedCount, #PlaytimeConfig.Gifts)
			local today = RetentionConfig.utcDay(now)
			local played = if state ~= nil
				then PlaytimeConfig.secondsToday(state, today) + extraSeconds(state, today, now, receivedAt)
				else 0
			cards.setProgress(played / LADDER_SECONDS)
			local locked = nextLocked
			if locked ~= nil then
				cards.setNext("Next gift in ", now + locked.secondsLeft, requestRefresh)
			elseif readyCount > 0 then
				cards.setNext("Your gifts are ready!", nil)
			else
				cards.setNext("New gifts in ", now + RetentionConfig.secondsToNextDay(now), requestRefresh)
			end
			if readyCount < PlaytimeConfig.ClaimAllMin then
				cards.claimAll.setState("locked", "CLAIM ALL")
			elseif now < claimAllPendingUntil then
				cards.claimAll.setState("disabled")
			else
				-- A "normal" stud button shows its base text (setState's text is for other states).
				cards.claimAll.setText(if readyCount > 1 then `CLAIM ALL ({readyCount})` else "CLAIM ALL")
				cards.claimAll.setState("normal")
			end
		end

		-- Recomputes the gift views + badge + wake timer; redraws the cards while open.
		refresh = function()
			local profile = ClientState.profile
			local now = RewardPreview.serverNow()
			local today = RetentionConfig.utcDay(now)
			local state = readState(profile)
			views = if state ~= nil
				then PlaytimeConfig.status(state, today, extraSeconds(state, today, now, receivedAt))
				else {}
			readyCount = 0
			-- Next wake: the soonest locked gift's unlock, or UTC midnight (fresh ladder).
			local nextWake = RetentionConfig.secondsToNextDay(now)
			for _, view in views do
				if view.state == "ready" then
					readyCount += 1
				elseif view.state == "locked" then
					nextWake = math.min(nextWake, view.secondsLeft)
				end
			end
			local badge = if readyCount > 0 then "!" else nil
			if badge ~= lastBadge then
				lastBadge = badge
				Hud.setButtonBadge(HUD_KEY, badge)
			end
			wake.schedule(nextWake)
			if isOpen then
				renderCards(now, profile, state)
			end
		end

		ClientState.ProfileChanged:Connect(function(_profile: ClientState.Profile, fields: { string }?)
			if touches(fields, BADGE_FIELDS) then
				-- Record the arrival time synchronously (the extrapolation base), and drop any
				-- "sending" claims: the server answered (or resynced), show its truth.
				receivedAt = RewardPreview.serverNow()
				table.clear(claimPendingUntil)
				claimAllPendingUntil = 0
			end
			if touches(fields, if isOpen then VIEW_FIELDS else BADGE_FIELDS) then
				requestRefresh()
			end
		end)
		-- Initial badge (the profile may already be here at boot).
		requestRefresh()
		-- Owner R89: the one-time favorite prompt listens from boot (off the build path: the remote
		-- lookup may wait for the server's remotes).
		task.spawn(FavoriteClient.start)

		return {
			onOpen = function(args: any?)
				isOpen = true
				refresh()
				ClientAnalytics.screenOpened(ANALYTICS_ID, sourceOf(args))
			end,
			onClose = function()
				isOpen = false
			end,
			-- Gamepad: CLAIM ALL with 2+ ready, else the first READY gift's CLAIM, else gift 1.
			defaultSelection = function(): GuiObject?
				local cards = grid
				if cards == nil then
					return nil
				end
				if readyCount >= 2 then
					return GamepadNav.defaultSelection(window.body, cards.claimAll.instance)()
				end
				local preferred = cards.cells[1]
				for index, view in views do
					local cell = cards.cells[index]
					if view.state == "ready" and cell ~= nil then
						preferred = cell
						break
					end
				end
				return GamepadNav.defaultSelection(window.body, preferred.button.instance)()
			end,
		}
	end,
})
