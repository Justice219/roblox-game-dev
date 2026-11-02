--!strict
--[[
	NukePass — the Nuke Pass window (owner R78 retention pack, spec docs/superpowers/specs/2026-10-31-
	r78-retention-pack-design.md §2; docs/nuke-pass.md). ScreenManager name "NukePass": opened by
	the HUD right-column "Pass" offer (HudZonesConfig.Offers) and by the NUKE PASS banner on Q's
	Quests screen (ScreenManager.open("NukePass", { source = "quests" })).

	Layout (orange stud window, the "NukePass" icon — golden ticket + cartoon nuke):
		top bar   SEASON 1 · HARVEST SEASON + "Ends in 29d 04:11:12"  |  TIER badge  |  XP bar
		          "120 / 400 XP" + play XP today  |  CLAIM ALL (n)  |  PREMIUM + live price
		track     Screens/NukePass/TierStrip: FREE row / tier chips on the progress line / PREMIUM
		          row, 30 tiers + the BONUS CHEST column, horizontally scrollable, auto-scrolled to
		          the current tier (or the first claimable reward) on open
		footer    the premium value line ("730 Gems · 18 Spins · 9 Eggs · Golden Nukey · ...") while
		          premium is not owned, else how XP is earned
	Before Season 1 / between seasons a card over the track reads "SEASON 1 STARTS IN ..." /
	"SEASON 2 IS COMING SOON!" and the track is a read-only preview of the last / next season.

	Server truth only: every number comes from ClientState.profile.pass through PassConfig.status
	(the same rule the server's claims use) at the pass clock (PassConfig.clockNow on the synced
	server time; the Studio test offset included). Buttons send INTENTS only — PassClaim(track,
	tier), PassClaim("overflow", 0), PassClaimAll(), PromptProduct(NukePassPremium, "pass") — and
	the server answers with a profile push + a reward toast. A pressed CLAIM shows "..." until the
	push (or CLAIM_PENDING_SECONDS).

	Juice: when a push shows newly claimed rewards while the window is open, those cards pop and
	burst stars (TierStrip.burst, at most MAX_BURSTS), "milestone" + "coin_burst" play and a Reward
	haptic fires; gems / cash fly into the HUD counters by themselves (UI/Hud/CurrencyFly).

	Console + mobile (owner R11): ResponsiveModal modes "wide" (desktop / console / tablet) and
	"phone" (a shorter window that fits a landscape phone unshrunk); buttons ≥ 44 pt and captions
	≥ 14 pt from the layout's tap / minText. Gamepad: the two card rows are a linked grid (Up from
	the top row → CLAIM ALL / PREMIUM), the strip follows the cursor (GamepadNav.followScroll),
	LB / RB (Q / E) page five tiers, B closes; owner R122: the cursor never starts on PREMIUM or a
	locked premium cell (tagged Robux BUYs, UI/PurchaseGuard); it starts on the first claimable reward,
	else the current tier — never the close X.

	Connects to: Screens/NukePass/{TierStrip, PassView}, Screens/DailyRewards/ResponsiveModal,
	Kit/StudUI, Platform/GamepadNav, Client/ClientState, Analytics/ClientAnalytics ("NukePass"),
	Audio/Sound, Pets/PetUI (haptic), Shared/Config/{PassConfig, MonetizationConfig, EggConfig
	(policyState), CrateConfig (trail swatch)}, Shared/Net/Remotes. Server: Services/PassService.

	Example:
		ScreenManager.open("NukePass")                          -- analytics source "hud"
		ScreenManager.open("NukePass", { source = "quests" })   -- the Quests screen banner
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Create)
local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local PassConfig = require(ReplicatedStorage.Shared.Config.PassConfig)
local PassView = require(script.PassView)
local PetUI = require(script.Parent.Parent.Parent.Pets.PetUI)
-- Owner R122 purchase-focus hygiene (opening-press guard, BUY tags, safe default selection).
local PurchaseGuard = require(script.Parent.Parent.PurchaseGuard)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ResponsiveModal = require(script.Parent.DailyRewards.ResponsiveModal)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local Sound = require(script.Parent.Parent.Parent.Audio.Sound)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local TierStrip = require(script.TierStrip)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local NAME = "NukePass"
local ANALYTICS_ID = "NukePass"
-- A pressed CLAIM stays "..." this long unless the server's push arrives first.
local CLAIM_PENDING_SECONDS = 3
-- Most cards that burst for one push (CLAIM ALL can claim 60 rewards at once).
local MAX_BURSTS = 6
-- Profile fields the open window shows (pass + policy + the income the cash previews scale with).
local VIEW_FIELDS = { "pass", "policy", "tycoon", "rebirths", "rebirthShop" }

-- Window modes (ResponsiveModal): the full track first, the phone-friendly shorter one second.
local MODES: { ResponsiveModal.Mode } = {
	{ name = "wide", size = Vector2.new(1560, 860) },
	{ name = "phone", size = Vector2.new(1320, 620) },
}

-- Claimed sets of the last push (juice: what turned claimed since).
type Claimed = { free: { [number]: true }, premium: { [number]: true }, overflow: number }

--[[ True when a ProfileChanged push touches any of `watched` (`fields` nil = a full snapshot). ]]
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
	title = "Nuke Pass",
	color = "orange",
	icon = "NukePass", -- the pass's own icon (golden ticket + cartoon nuke, IconAssets)
	modes = MODES,
	build = function(
		window: StudUI.Window,
		_gui: ScreenGui,
		layout: ResponsiveModal.Controller
	): ScreenManager.ScreenHandle?
		local body = window.body
		local isOpen = false
		local refreshQueued = false
		-- Pending CLAIM presses: "<track>:<tier>" → server time until which the button shows "...".
		local pending: { [string]: number } = {}
		local claimAllPendingUntil = 0
		local lastClaimed: Claimed? = nil
		-- What the gamepad should start on / the strip should centre (set by refresh).
		local focusTrack: "free" | "premium" | "chest" = "free"
		local focusTier = 1
		-- Phone layout (set by place()): shorter header texts.
		local compact = false

		local refresh: () -> ()
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

		------------------------------------------------------------------------------------------
		-- Build (once; sizes come from place())
		------------------------------------------------------------------------------------------

		local top = Create.new("Frame", { Name = "TopBar", BackgroundTransparency = 1, Parent = body }) :: Frame
		local seasonTitle = StudUI.text({
			text = "NUKE PASS",
			textSize = 32,
			align = Enum.TextXAlignment.Left,
			scaled = true,
			name = "SeasonTitle",
			parent = top,
		})
		local endsCountdown = StudUI.countdown({
			endsAt = 0,
			format = "auto",
			prefix = "Ends in ",
			doneText = "Season over!",
			textSize = 26,
			parent = top,
			onFinished = requestRefresh,
		})
		endsCountdown.label.TextXAlignment = Enum.TextXAlignment.Left
		local startsCountdown = StudUI.countdown({
			endsAt = 0,
			format = "auto",
			prefix = "Starts in ",
			doneText = "Starting!",
			textSize = 26,
			parent = top,
			onFinished = requestRefresh,
		})
		startsCountdown.label.TextXAlignment = Enum.TextXAlignment.Left
		local phaseNote = StudUI.text({
			text = "",
			textSize = 26,
			align = Enum.TextXAlignment.Left,
			scaled = true,
			name = "PhaseNote",
			parent = top,
		})

		local tierCard = StudUI.card({ color = "yellow", name = "TierBadge", parent = top })
		local tierCaption = StudUI.text({
			text = "TIER",
			textSize = 24,
			size = UDim2.fromScale(1, 0.34),
			scaled = true,
			zIndex = 4,
			parent = tierCard.content,
		})
		tierCaption.Active = false
		local tierNumber = StudUI.text({
			text = "0",
			textSize = 64,
			font = "number",
			size = UDim2.fromScale(1, 0.66),
			position = UDim2.fromScale(0, 0.34),
			scaled = true,
			zIndex = 4,
			parent = tierCard.content,
		})
		tierNumber.Active = false

		local xpBlock = Create.new("Frame", { Name = "XpBlock", BackgroundTransparency = 1, Parent = top }) :: Frame
		local xpText = StudUI.text({
			text = "",
			textSize = 26,
			align = Enum.TextXAlignment.Left,
			scaled = true,
			name = "XpText",
			parent = xpBlock,
		})
		local xpBar = StudUI.progressBar({ color = "green", parent = xpBlock })
		local playText = StudUI.text({
			text = "",
			textSize = 20,
			align = Enum.TextXAlignment.Left,
			scaled = true,
			name = "PlayText",
			parent = xpBlock,
		})

		local claimAll: StudUI.Button
		local buy: StudUI.Button
		local strip: TierStrip.Strip

		-- Sends the premium purchase INTENT (the server re-checks the season + ownership). Owner
		-- R122: PREMIUM and the locked premium cells ("unlock") prompt only for a press that began
		-- after the window opened (PurchaseGuard) — the HUD offer / Quests banner press that opened
		-- the Nuke Pass never buys.
		local function buyPremium()
			if not PurchaseGuard.allow(NAME) then
				return
			end
			local product = MonetizationConfig.getProduct(PassConfig.PremiumProduct)
			if product ~= nil and MonetizationConfig.isConfigured(product.id) then
				Remotes.event("PromptProduct"):FireServer(PassConfig.PremiumProduct, "pass")
			else
				ScreenManager.open("ComingSoon", { focus = PassConfig.PremiumProduct })
			end
		end

		-- Sends one claim INTENT; the button shows "..." until the push / the pending window ends.
		local function claim(track: "free" | "premium", tier: number)
			pending[`{track}:{tier}`] = Workspace:GetServerTimeNow() + CLAIM_PENDING_SECONDS
			Remotes.event("PassClaim"):FireServer(track, tier)
			Sound.play("ui_claim")
			requestRefresh()
			task.delay(CLAIM_PENDING_SECONDS + 0.05, requestRefresh)
		end

		local function claimChest()
			pending["chest:0"] = Workspace:GetServerTimeNow() + CLAIM_PENDING_SECONDS
			Remotes.event("PassClaim"):FireServer("overflow", 0)
			Sound.play("ui_claim")
			requestRefresh()
			task.delay(CLAIM_PENDING_SECONDS + 0.05, requestRefresh)
		end

		claimAll = StudUI.button({
			text = "CLAIM ALL",
			color = "green",
			textSize = 28,
			name = "ClaimAll",
			parent = top,
			onActivated = function()
				claimAllPendingUntil = Workspace:GetServerTimeNow() + CLAIM_PENDING_SECONDS
				Remotes.event("PassClaimAll"):FireServer()
				Sound.play("ui_claim")
				requestRefresh()
				task.delay(CLAIM_PENDING_SECONDS + 0.05, requestRefresh)
			end,
		})

		local premiumBox = Create.new("Frame", { Name = "Premium", BackgroundTransparency = 1, Parent = top }) :: Frame
		local premiumTitle = StudUI.text({
			text = "PREMIUM",
			textSize = 28,
			scaled = true,
			name = "PremiumTitle",
			parent = premiumBox,
		})
		premiumTitle.TextColor3 = UIStyleConfig.Colors.purple.accent
		-- Empty text + productKey: the LIVE managed price (UI/PriceBook) is the button's label.
		buy = StudUI.button({
			text = "",
			productKey = PassConfig.PremiumProduct,
			color = "purple",
			name = "BuyPremium",
			parent = premiumBox,
			onActivated = buyPremium,
		})
		PurchaseGuard.markBuy(buy.instance) -- R122: never the default cursor
		local owned = StudUI.text({
			text = "PREMIUM OWNED",
			textSize = 26,
			scaled = true,
			name = "PremiumOwned",
			parent = premiumBox,
		})
		owned.TextColor3 = UIStyleConfig.Colors.green.accent
		owned.Visible = false

		local stripHolder =
			Create.new("Frame", { Name = "StripHolder", BackgroundTransparency = 1, Parent = body }) :: Frame
		strip = TierStrip.new({
			parent = stripHolder,
			count = PassConfig.TierCount,
			onClaim = claim,
			onUnlock = buyPremium,
			onChest = claimChest,
		})

		-- The between-seasons / before-the-season card over the track (not selectable).
		local overlay = StudUI.card({ color = "orange", sunburst = true, name = "SeasonOverlay", parent = stripHolder })
		overlay.frame.ZIndex = 20
		overlay.frame.AnchorPoint = Vector2.new(0.5, 0.5)
		overlay.frame.Position = UDim2.fromScale(0.5, 0.5)
		local overlayText = StudUI.text({
			text = "",
			textSize = 40,
			size = UDim2.fromScale(1, 1),
			wrap = true,
			scaled = true,
			zIndex = 22,
			parent = overlay.content,
		})
		overlayText.Active = false
		overlay.frame.Visible = false

		local footer = StudUI.text({
			text = "",
			textSize = 22,
			wrap = true,
			scaled = true,
			name = "Footer",
			parent = body,
		})

		-- Gamepad: the two card rows as one grid (Up → CLAIM ALL), header buttons linked.
		local topRow, bottomRow = strip.buttons()
		local grid: { GuiObject } = table.clone(topRow)
		for _, button in bottomRow do
			table.insert(grid, button)
		end
		GamepadNav.linkGrid(grid, #topRow, { up = claimAll.instance })
		GamepadNav.linkList({ claimAll.instance, buy.instance }, false, { down = topRow[1] })
		GamepadNav.followScroll(strip.scroller)
		local cycler = GamepadNav.cycler(function()
			strip.page(-1)
		end, function()
			strip.page(1)
		end)

		------------------------------------------------------------------------------------------
		-- Layout (per window mode / device)
		------------------------------------------------------------------------------------------

		-- Lays the window out for a ResponsiveModal layout. Phone ("compact"): no PREMIUM label over
		-- the buy button (the PREMIUM row label says it), a one-row top bar of 44 pt buttons, a
		-- thinner chip row and no footer, so both card rows keep a readable icon.
		local function place(current: ResponsiveModal.Layout)
			local area = current.area
			local phone = current.mode == "phone"
			compact = phone
			local gap = if phone then 6 else 12
			local depth = UIStyleConfig.Button.Lip + UIStyleConfig.Button.Edge
			local buttonH = math.max(if phone then 60 else 64, current.tap)
			local textMin = current.minText
			local premiumLabelH = if phone then 0 else math.max(34, textMin)
			local topH = if phone
				then math.max(92, buttonH + depth + 4)
				else math.max(124, buttonH + premiumLabelH + 12)
			local buttonY = if phone then math.floor((topH - buttonH - depth) / 2) else topH - buttonH - depth
			local footerH = if phone then 0 else 40
			top.Size = UDim2.fromOffset(area.X, topH)
			top.Position = UDim2.fromOffset(0, 0)

			local premiumW = if phone then 210 else 260
			local claimW = if phone then 230 else 250
			local seasonW = math.floor(area.X * (if phone then 0.2 else 0.28))
			local badge = topH
			local xpX = seasonW + gap + badge + gap
			local xpW = math.max(160, area.X - xpX - claimW - premiumW - 3 * gap)

			seasonTitle.Size = UDim2.fromOffset(seasonW, math.floor(topH * 0.46))
			seasonTitle.Position = UDim2.fromOffset(0, 0)
			seasonTitle.TextSize = math.max(if phone then 24 else 32, textMin)
			for _, label in { endsCountdown.label, startsCountdown.label, phaseNote } do
				label.Size = UDim2.fromOffset(seasonW, math.floor(topH * 0.42))
				label.Position = UDim2.fromOffset(0, math.floor(topH * 0.52))
				label.TextSize = math.max(if phone then 20 else 26, textMin)
			end

			tierCard.frame.Size = UDim2.fromOffset(badge, badge)
			tierCard.frame.Position = UDim2.fromOffset(seasonW + gap, 0)

			xpBlock.Size = UDim2.fromOffset(xpW, topH)
			xpBlock.Position = UDim2.fromOffset(xpX, 0)
			local xpTextH = math.max(if phone then 26 else 34, textMin + 4)
			local barH = if phone then 24 else 32
			xpText.Size = UDim2.fromOffset(xpW, xpTextH)
			xpText.TextSize = math.max(if phone then 22 else 28, textMin)
			xpBar.frame.Size = UDim2.fromOffset(xpW, barH)
			xpBar.frame.Position = UDim2.fromOffset(0, xpTextH + 6)
			playText.Visible = not phone
			playText.Size = UDim2.fromOffset(xpW, 28)
			playText.Position = UDim2.fromOffset(0, xpTextH + 6 + barH + 8)

			claimAll.instance.Size = UDim2.fromOffset(claimW, buttonH)
			claimAll.instance.Position = UDim2.fromOffset(area.X - premiumW - gap - claimW, buttonY)

			premiumBox.Size = UDim2.fromOffset(premiumW, topH)
			premiumBox.Position = UDim2.fromOffset(area.X - premiumW, 0)
			premiumTitle.Visible = not phone
			premiumTitle.Size = UDim2.fromOffset(premiumW, premiumLabelH)
			premiumTitle.TextSize = math.max(28, textMin)
			buy.instance.Size = UDim2.fromOffset(premiumW, buttonH)
			buy.instance.Position = UDim2.fromOffset(0, buttonY)
			owned.Size = UDim2.fromOffset(premiumW, buttonH)
			owned.Position = UDim2.fromOffset(0, buttonY)

			local stripY = topH + gap
			local stripH = area.Y - stripY - (if footerH > 0 then footerH + gap else 0)
			stripHolder.Position = UDim2.fromOffset(0, stripY)
			stripHolder.Size = UDim2.fromOffset(area.X, stripH)
			local chipH = if phone then 26 else 44
			strip.layout({
				size = Vector2.new(area.X, stripH),
				labelW = if phone then 104 else 150,
				colW = if phone then 168 else 184,
				gap = gap,
				rowH = math.floor((stripH - chipH - 2 * gap) / 2),
				chipH = chipH,
				buttonH = math.max(if phone then 60 else 52, current.tap),
				textSize = math.max(if phone then 20 else 21, textMin),
				compact = phone,
			})
			overlay.frame.Size = UDim2.fromOffset(math.min(820, area.X * 0.62), math.min(240, stripH * 0.62))

			footer.Visible = footerH > 0
			footer.Size = UDim2.fromOffset(area.X, footerH)
			footer.Position = UDim2.fromOffset(0, area.Y - footerH)
			footer.TextSize = 22
			requestRefresh() -- the season title is shorter in the compact layout
		end
		layout.onChanged(function(current: ResponsiveModal.Layout)
			place(current)
		end)
		-- CanvasPosition is in absolute px: whenever the strip's on-screen size changes (device /
		-- rotation / window mode), re-centre the focus tier once the new size is known.
		strip.scroller:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(function()
			if isOpen then
				strip.scrollToTier(focusTier, true)
			end
		end)
		place(layout.current())

		------------------------------------------------------------------------------------------
		-- Refresh (server truth → every label / card)
		------------------------------------------------------------------------------------------

		-- Plays the claim juice for rewards that turned claimed since the last push.
		local function celebrate(state: PassConfig.State)
			local previous = lastClaimed
			local claimed: Claimed = {
				free = table.clone(state.claimedFree),
				premium = table.clone(state.claimedPremium),
				overflow = state.overflow,
			}
			lastClaimed = claimed
			if previous == nil or not isOpen then
				return
			end
			local bursts = 0
			for tier = 1, PassConfig.TierCount do
				for _, track in { "free", "premium" } do
					local isClaimed = if track == "free" then claimed.free[tier] else claimed.premium[tier]
					local wasClaimed = if track == "free" then previous.free[tier] else previous.premium[tier]
					if isClaimed == true and wasClaimed ~= true and bursts < MAX_BURSTS then
						bursts += 1
						strip.burst(track :: any, tier)
					end
				end
			end
			if claimed.overflow > previous.overflow and bursts < MAX_BURSTS then
				bursts += 1
				strip.burst("chest", PassConfig.TierCount + 1)
			end
			if bursts > 0 then
				Sound.play("milestone")
				Sound.play("coin_burst")
				PetUI.haptic("Reward")
			end
		end

		refresh = function()
			local profile = ClientState.profile
			local raw: any = if profile ~= nil then profile.pass else nil
			local serverNow = Workspace:GetServerTimeNow()
			local now = PassConfig.clockNow(serverNow)
			local state = PassConfig.readState(raw)
			local status = PassConfig.status(state, now)
			local phase = PassView.phase(now)
			local policy: any = if profile ~= nil then profile.policy else nil
			local restricted = EggConfig.policyState(policy) == "restricted"
			local firstId = PassConfig.SeasonOrder[1]
			local season = status.season or phase.season or PassConfig.Seasons[firstId]

			-- Expire pending presses.
			for key, untilAt in pending do
				if serverNow >= untilAt then
					pending[key] = nil
				end
			end

			-- Header: season + countdown / phase note.
			seasonTitle.Text = if compact
				then `SEASON {season.number}`
				else `SEASON {season.number} · {string.upper(season.name)}`
			endsCountdown.label.Visible = phase.kind == "active"
			startsCountdown.label.Visible = phase.kind == "before"
			phaseNote.Visible = phase.kind == "after"
			if phase.kind == "active" and phase.at ~= nil then
				endsCountdown.setEndsAt(PassView.toServerTime(phase.at, serverNow))
			elseif phase.kind == "before" and phase.at ~= nil then
				startsCountdown.setEndsAt(PassView.toServerTime(phase.at, serverNow))
			else
				phaseNote.Text = `Season {season.number + 1} is coming soon!`
			end

			-- Tier + XP.
			-- Between seasons the player's FINAL tier of the ended season stays on the badge.
			local finished = phase.kind == "after" and state.season == season.id
			local shownTier = if finished then PassConfig.tierOf(state.xp) else status.tier
			tierNumber.Text = tostring(shownTier)
			xpBar.setProgress(if status.xpPer > 0 then status.xpInto / status.xpPer else 0)
			xpText.Text = if status.season == nil
				then "Earn XP from Quests + playing!"
				elseif status.tier >= PassConfig.TierCount then `{status.xpInto} / {status.xpPer} XP to a BONUS CHEST`
				else `{status.xpInto} / {status.xpPer} XP to tier {status.tier + 1}`
			local today = PassConfig.utcDay(now)
			local dayXp = if state.day == today then state.dayXp else 0
			playText.Text =
				`Play XP today: {dayXp} / {PassConfig.PlayXp.DailyCap} ({PassConfig.PlayXp.Amount} XP every {PassConfig.PlayXp.EveryMinutes} min)`

			-- CLAIM ALL.
			local claimable = PassConfig.claimableCount(state, now)
			if serverNow < claimAllPendingUntil then
				TierStrip.setButton(claimAll, "disabled", "...")
			elseif claimable > 0 then
				TierStrip.setButton(claimAll, "normal", `CLAIM ALL ({claimable})`)
			else
				TierStrip.setButton(claimAll, "locked", "CLAIM ALL")
			end

			-- Premium.
			local active = phase.kind == "active"
			premiumBox.Visible = active
			buy.instance.Visible = active and not status.premium
			owned.Visible = active and status.premium
			premiumTitle.Text = if status.premium then "NUKE PASS" else "PREMIUM"

			-- Cards.
			for tier = 1, PassConfig.TierCount do
				local def = season.tiers[tier]
				if def == nil then
					continue
				end
				for _, track in { "free", "premium" } do
					local reward = if track == "free" then def.free else def.premium
					local lines = PassView.lines(reward, track, profile, restricted)
					local cellState = PassView.cellState(status, state, track, tier)
					-- The ended season's preview keeps what the player claimed (or was auto-granted).
					local claimedSet = if track == "free" then state.claimedFree else state.claimedPremium
					if finished and cellState == "preview" and claimedSet[tier] == true then
						cellState = "claimed"
					end
					local trail = if reward.trail ~= nil then CrateConfig.getTrail(reward.trail) else nil
					local isPending = (pending[`{track}:{tier}`] or 0) > serverNow
					strip.setCell(track :: any, tier, {
						icon = PassView.iconOf(lines),
						-- Phones show the headline part only (one short line beside the icon).
						caption = if compact
							then (if lines[1] ~= nil then lines[1].short or lines[1].text else "")
							else PassView.headline(reward, track, profile, restricted),
						state = if isPending and cellState == "claimable" then "locked" else cellState,
						milestone = def.milestone,
						swatch = if trail ~= nil then trail.colors else nil,
						pet = reward.pet,
						buttonText = if isPending and cellState == "claimable" then "..." else nil,
						tier = tier,
					})
					-- R122: a locked premium cell ("unlock") sells PREMIUM — a tagged Robux BUY.
					local cellButton = strip.focusButton(track :: any, tier)
					if cellButton ~= nil then
						PurchaseGuard.setBuy(cellButton, cellState == "unlock")
					end
				end
			end

			-- Bonus chest column.
			local chestPending = (pending["chest:0"] or 0) > serverNow
			local chestState: PassView.CellState
			local chestText: string? = nil
			if status.season == nil then
				chestState = "preview"
				chestText = "TIER 30"
			elseif status.overflowClaimable > 0 and not chestPending then
				chestState = "claimable"
				chestText = if status.overflowClaimable > 1 then `CLAIM x{status.overflowClaimable}` else nil
			elseif chestPending then
				chestState = "locked"
				chestText = "..."
			else
				chestState = "locked"
				chestText = if status.tier < PassConfig.TierCount then "TIER 30" else `{status.xpInto}/{status.xpPer}`
			end
			strip.setChest({
				icon = "Chest",
				caption = if compact
					then `+{PassConfig.OverflowReward.gems}`
					else `Bonus Chest: {PassConfig.OverflowReward.gems} Gems / {PassConfig.OverflowXp} XP`,
				state = chestState,
				milestone = true,
				buttonText = chestText,
				tier = PassConfig.TierCount + 1,
			})

			strip.setProgress(shownTier, if status.xpPer > 0 then status.xpInto / status.xpPer else 0)
			strip.setPremiumOwned(status.premium)

			-- Season overlay.
			overlay.frame.Visible = phase.kind ~= "active"
			overlayText.Text = if phase.kind == "before"
				then `SEASON {season.number} STARTS SOON!\nPreview the rewards below.`
				elseif
					phase.kind == "after"
				then `SEASON {season.number + 1} IS COMING SOON!\nUnclaimed rewards were added automatically.`
				else ""

			-- Footer: premium value while it can still be bought, else how XP is earned.
			footer.Text = if active and not status.premium
				then `PREMIUM: {PassView.valueLine(season, restricted)}`
				else "Earn XP from Quests (Goals, Daily, Trophies) and by playing!"

			-- Focus: the first claimable reward, else the tier being earned.
			if #status.freeClaimable > 0 then
				focusTrack, focusTier = "free", status.freeClaimable[1]
			elseif #status.premiumClaimable > 0 then
				focusTrack, focusTier = "premium", status.premiumClaimable[1]
			elseif status.overflowClaimable > 0 then
				focusTrack, focusTier = "chest", PassConfig.TierCount + 1
			else
				focusTrack, focusTier = "free", math.clamp(status.tier + 1, 1, PassConfig.TierCount)
			end

			celebrate(state)
		end

		ClientState.ProfileChanged:Connect(function(_profile: any, fields: { string }?)
			if not isOpen then
				return
			end
			if touches(fields, { "pass" }) then
				-- The server answered (or resynced): drop the "..." of every press.
				table.clear(pending)
				claimAllPendingUntil = 0
			end
			if touches(fields, VIEW_FIELDS) then
				requestRefresh()
			end
		end)

		return {
			onOpen = function(args: any?)
				isOpen = true
				-- New baseline: claims made while the window was closed never burst on open.
				lastClaimed = nil
				refresh()
				-- Centre the reward the cursor starts on (after the layout settled this frame).
				task.defer(function()
					strip.scrollToTier(focusTier, true)
				end)
				cycler.enable()
				ClientAnalytics.screenOpened(ANALYTICS_ID, sourceOf(args))
			end,
			onClose = function()
				isOpen = false
				cycler.disable()
			end,
			-- The first claimable reward / the tier being earned; never PREMIUM or a locked premium
			-- cell (R122 PurchaseGuard filters Robux BUYs; CLAIM ALL is the safe fallback).
			defaultSelection = function(): GuiObject?
				local preferred = strip.focusButton(focusTrack, focusTier)
				return PurchaseGuard.safeDefault({
					preferred,
					GamepadNav.defaultSelection(body, nil)(),
					claimAll.instance,
				})
			end,
		}
	end,
})
