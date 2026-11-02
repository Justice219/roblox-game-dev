--!strict
--[[
	InviteMoment — the once-per-session "PLAY WITH FRIENDS!" card (owner R122, spec §2.4: co-play;
	tunables InviteConfig.Moment; scheduling Client/Social/InviteClient).

		┌──── blue stud card ──────────────────────────────┐
		│ [handshake]  PLAY WITH FRIENDS!                   │
		│              Every friend here gives you +10% cash!│
		│              [B] LATER          [X] INVITE         │
		└───────────────────────────────────────────────────┘

	When: InviteClient asks PopupQueue's centre lane (kind "inviteMoment", low priority) after area
	2 is unlocked — never over a menu or a cinematic, never during the tutorial, never while a
	friend is already in the server, never when invites are unavailable, at most once per session.
	Where: the bottom of the bottom-left FEED column (Widgets/PopupQueue.placeFeedCard: clear of the
	left grid, the objective chip, the hint bar and the touch thumbstick / jump reserve), like the
	Lucky Nuke reveal card (owner R108 / R120: small, non-modal, never centre-screen).

	Input (owner R11): INVITE = tap / click, gamepad X or keyboard E (bound BELOW every gameplay
	action, so a pad / producer press on the same key always wins); LATER = tap / click, gamepad B
	or keyboard X / Backspace (High priority, only while the card shows). Nothing is Selectable:
	the gamepad cursor is never stolen. It closes itself after Moment.ShowSeconds (no answer).
	A press that began before the card appeared never answers it (UI/PurchaseGuard arm rule).

	Analytics (via InviteClient → FriendInvite → FriendService): friends:moment:shown (InviteClient,
	when it opens), friends:moment:invite, friends:moment:later. A timeout counts neither.

	Payload: { percent = the live Friend Boost percent per friend (0 = off) }.

	Connects to: UI/{ScreenManager, PurchaseGuard, Widgets/{ActionCard, FeedCardMetrics,
	PopupQueue}}, Client/Social/InviteClient, Shared/Config/{InviteConfig, InputConfig},
	Shared/Util/TouchLayout, TouchUIConfig.

	Example: ScreenManager.open("InviteMoment", { percent = 10 }) -- normally only InviteClient
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionCard = require(script.Parent.Parent.Widgets.ActionCard)
local Create = require(script.Parent.Parent.Create)
local FeedCardMetrics = require(script.Parent.Parent.Widgets.FeedCardMetrics)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local InviteClient = require(script.Parent.Parent.Parent.Social.InviteClient)
local InviteConfig = require(ReplicatedStorage.Shared.Config.InviteConfig)
local PopupQueue = require(script.Parent.Parent.Widgets.PopupQueue)
local PurchaseGuard = require(script.Parent.Parent.PurchaseGuard)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)

local NAME = "InviteMoment"
local INVITE_ACTION = "SellNukesInviteMomentInvite"
local LATER_ACTION = "SellNukesInviteMomentLater"
local Moment = InviteConfig.Moment
local Text = Moment.Text
local Hud = InviteConfig.Hud

-- The card's design sizes at fit 1 (Widgets/FeedCardMetrics).
local SPEC: FeedCardMetrics.Spec = {
	width = Moment.Width,
	artSize = Moment.ArtSize,
	titleSize = Moment.TitleSize,
	lineSize = Moment.LineSize,
	lineRows = Moment.LineRows,
	buttonHeight = Moment.ButtonHeight,
	pad = Moment.Pad,
	gap = Moment.Gap,
}

local screen: ScreenManager.ScreenModule = {
	name = NAME,
	modal = false,
	autoOpen = false,
	displayOrder = 17, -- above the HUD + banners, below every window (20+)
	lazy = true,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		local root = Create.new("Frame", {
			Name = "Root",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Active = false,
			Parent = gui,
		}) :: Frame

		local open = false
		local token = 0
		local percent = 0
		local bandConnection: Signal.Connection? = nil
		local answer: (choice: "invite" | "later") -> ()

		local view = ActionCard.new(root, {
			primaryWidth = Moment.InviteWidth,
			secondaryWidth = Moment.LaterWidth,
			glyphHeight = Moment.GlyphHeight,
			primaryKey = Moment.InviteKey,
			primaryPad = Moment.InvitePad,
			secondaryKey = InputConfig.CloseKey,
			secondaryPad = InputConfig.BackButton,
			onPrimary = function()
				-- A tap that began before the card appeared never answers it.
				if PurchaseGuard.allow(NAME) then
					answer("invite")
				end
			end,
			onSecondary = function()
				if PurchaseGuard.allow(NAME) then
					answer("later")
				end
			end,
		})

		-- Design-px floors on this device: 14 pt text and the 44 pt tap (touch screens only).
		local function floors(): FeedCardMetrics.Floors
			if not ScreenManager.touchTargets() then
				return { text = 0, tap = 0 }
			end
			local scale = ScreenManager.pointScale()
			return {
				text = TouchLayout.pointsToDesign(14, scale),
				tap = TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, scale),
			}
		end

		-- Places the card at the bottom of the feed column at the largest fit that keeps the floors.
		local function place()
			local f = floors()
			local base = FeedCardMetrics.compute(SPEC, 1, f)
			local area = PopupQueue.feedArea(base.height)
			local metrics = FeedCardMetrics.fit(SPEC, area.width, math.max(0, area.bottom - area.top), Moment.MinFit, f)
			local x, y, fit = PopupQueue.placeFeedCard(metrics.width, metrics.height, metrics.fit)
			view.holder.Position = UDim2.fromOffset(x, y)
			view.fitScale.Scale = fit
			view.apply(metrics)
		end

		-- Binds INVITE (X / E, below gameplay) + LATER (B / X / Backspace, high) while open.
		local function bind()
			ContextActionService:BindActionAtPriority(
				INVITE_ACTION,
				function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
					if state ~= Enum.UserInputState.Begin or not open or ScreenManager.anyModalOpen() then
						return Enum.ContextActionResult.Pass
					end
					if not PurchaseGuard.allow(NAME, os.clock()) then
						return Enum.ContextActionResult.Pass
					end
					answer("invite")
					return Enum.ContextActionResult.Sink
				end,
				false,
				Moment.InvitePriority,
				Moment.InviteKey,
				Moment.InvitePad
			)
			ContextActionService:BindActionAtPriority(
				LATER_ACTION,
				function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
					if state ~= Enum.UserInputState.Begin or not open or ScreenManager.anyModalOpen() then
						return Enum.ContextActionResult.Pass
					end
					answer("later")
					return Enum.ContextActionResult.Sink
				end,
				false,
				Moment.LaterPriority,
				InputConfig.BackButton,
				table.unpack(InputConfig.CloseKeys)
			)
		end

		answer = function(choice: "invite" | "later")
			if not open then
				return
			end
			if choice == "invite" then
				InviteClient.invite("moment")
			else
				InviteClient.report("moment:later")
			end
			ScreenManager.close(NAME)
		end

		return {
			onOpen = function(args: any?)
				local data: any = if type(args) == "table" then args else {}
				percent = if type(data.percent) == "number" and data.percent == data.percent
					then math.clamp(math.floor(data.percent), 0, 100)
					else 0
				open = true
				token += 1
				local mine = token
				view.setContent({
					color = Moment.Color,
					icon = if StudUI.hasIcon(Hud.Icon) then Hud.Icon else Hud.IconFallback,
					title = Text.Title,
					line = if percent > 0 then string.format(Text.Line, percent) else Text.LineNoBoost,
					primaryText = Text.Invite,
					primaryColor = "green",
					secondaryText = Text.Later,
				})
				place()
				PurchaseGuard.opened(NAME)
				view.pop(0.6, 0.22)
				if bandConnection == nil then
					bandConnection = PopupQueue.Changed:Connect(function(what: string)
						if what == "band" and open then
							place()
						end
					end)
				end
				bind()
				task.delay(Moment.ShowSeconds, function()
					if token == mine and open then
						ScreenManager.close(NAME)
					end
				end)
			end,
			onClose = function()
				open = false
				token += 1
				ContextActionService:UnbindAction(INVITE_ACTION)
				ContextActionService:UnbindAction(LATER_ACTION)
				local connection = bandConnection
				if connection ~= nil then
					connection:Disconnect()
					bandConnection = nil
				end
				PopupQueue.clearFeedCard()
				InviteClient.momentClosed()
			end,
		}
	end,
}

return screen
