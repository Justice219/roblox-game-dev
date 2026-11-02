--!strict
--[[
	DealCard — the small non-modal DEAL card (owner R122, spec §2.4: "no accidental purchase
	prompts"; tunables PurchaseFocusConfig.DealCard / DealKeys).

	Why: of ~190 Robux prompts in two days, 0 were bought and most closed in under 2 s. Walking into
	a paid Lucky Button prompted at once (10-31: 30 lucky prompts, 20 closed < 2 s) and one tap on a
	HUD offer chip prompted at once (x2 Cash: 17 + 14, mostly < 2 s on phones / tablets). Now those
	sources open THIS card first; only its BUY opens the Robux prompt.

		┌──── stud card (purple lucky / blue offer / orange attack) ──┐
		│ [art]  2x CASH FOREVER                                       │
		│        Every nuke you sell is worth double. Forever!         │
		│        [B] CLOSE                [X] ⏣ 199                     │
		└──────────────────────────────────────────────────────────────┘

	Open: ScreenManager.open("DealCard", args)
		args = {
			id = string?,              -- caller id; re-opening the SAME id while open refreshes
			                           -- the content (no re-arm / pop); another id replaces it
			source = "lucky" | "offer" | "attack",   -- colour + analytics
			key = string,              -- MonetizationConfig pass / product key (the art, name,
			                           -- description and LIVE price come from it)
			kind = "pass" | "product",
			promptSource = string?,    -- PurchasePromptConfig source of the default intent
			title = string?, line = string?, icon = string?,   -- overrides
			anchor = Rect?,            -- a HUD chip's rect (design px): the card sits beside it
			                           -- and closes itself after ChipAutoClose; nil = the bottom of
			                           -- the bottom-left feed (Widgets/PopupQueue, the Lucky card)
			onBuy = (() -> ())?,       -- replaces the default PromptPass / PromptProduct intent
			                           -- (Lucky: LuckyButtonClaim(id, "buy"); golden revenge)
			onClosed = ((reason) -> ())?, -- every close / replace: "buy" | "close" | "timeout" |
			                           -- "replaced" | "modal" | "hidden" (ScreenManager.close)
		}
	The open card's id is the ScreenGui attribute "DealId" (a chip toggles its own card).

	Input (owner R11): the card is never auto-focused (nothing Selectable; the gamepad cursor stays
	where it was). BUY = tap / click, gamepad X or keyboard E — bound BELOW every gameplay action
	(PurchaseFocusConfig.DealKeys), so a pad / producer / hatch press on the same key always wins
	and A (jump while running) never buys. CLOSE = tap / click, gamepad B, keyboard X / Backspace
	(High priority, only while the card shows). The press that opened the card can never also buy
	(UI/PurchaseGuard: the press must begin after the card appeared + ArmSeconds). Phones / tablets:
	text >= 14 pt and buttons >= 44 pt at the drawn fit (Widgets/FeedCardMetrics); clear of the
	thumbstick / jump zones (feed area / clamped above the touch reserve).

	Analytics: an offer card counts open:Offers (source "hud") and the offer impression
	(offerSeen(key, "popup")); BUY sends the intent with the caller's prompt source (offer → the
	usual prompt:<key>:offer). Lucky cards report luckyDeal:<shown|buy|close>:<kind> through their
	own onBuy / onClosed (Client/LuckyButtons/LuckyButtonClient → the server).

	Security: intents only — the server validates and prompts (MonetizationService).

	Connects to: UI/{ScreenManager, PurchaseGuard, Create, Widgets/{ActionCard, FeedCardMetrics,
	PopupQueue, HudZones}}, Analytics/ClientAnalytics, Shared/Config/{PurchaseFocusConfig,
	MonetizationConfig, InputConfig, TouchUIConfig}, Shared/Net/Remotes, Shared/Util/TouchLayout;
	opened by UI/Hud/HudOffers, Client/LuckyButtons/LuckyButtonClient,
	UI/Screens/AttackTarget/AttackHudScreen.

	Example: ScreenManager.open("DealCard", { id = "offer:DoubleCash", source = "offer",
		key = "DoubleCash", kind = "pass", promptSource = "offer", anchor = chipRect })
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionCard = require(script.Parent.Parent.Widgets.ActionCard)
local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local Create = require(script.Parent.Parent.Create)
local FeedCardMetrics = require(script.Parent.Parent.Widgets.FeedCardMetrics)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local PopupQueue = require(script.Parent.Parent.Widgets.PopupQueue)
local PurchaseFocusConfig = require(ReplicatedStorage.Shared.Config.PurchaseFocusConfig)
local PurchaseGuard = require(script.Parent.Parent.PurchaseGuard)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)

local NAME = "DealCard"
local BUY_ACTION = "SellNukesDealCardBuy"
local CLOSE_ACTION = "SellNukesDealCardClose"
local Card = PurchaseFocusConfig.DealCard
local Keys = PurchaseFocusConfig.DealKeys
-- Margin kept from the canvas edges when the card sits beside a chip (design px).
local EDGE = 16

export type Rect = { x: number, y: number, w: number, h: number }
export type CloseReason = "buy" | "close" | "timeout" | "replaced" | "modal" | "hidden"

-- The validated open request.
type Deal = {
	id: string,
	source: string,
	key: string,
	kind: "pass" | "product",
	promptSource: string?,
	title: string,
	line: string,
	icon: string,
	anchor: Rect?,
	onBuy: (() -> ())?,
	onClosed: ((reason: CloseReason) -> ())?,
}

-- The card's design sizes at fit 1 (Widgets/FeedCardMetrics).
local SPEC: FeedCardMetrics.Spec = {
	width = Card.Width,
	artSize = Card.ArtSize,
	titleSize = Card.TitleSize,
	lineSize = Card.LineSize,
	lineRows = Card.LineRows,
	buttonHeight = Card.ButtonHeight,
	pad = Card.Pad,
	gap = Card.Gap,
}

-- A short plain string (<= max bytes) or nil (caller args are code, but stay defensive).
local function shortString(value: unknown, max: number): string?
	if type(value) ~= "string" or #value == 0 or #value > max then
		return nil
	end
	return value
end

-- A finite rect or nil.
local function readRect(value: unknown): Rect?
	if type(value) ~= "table" then
		return nil
	end
	local raw = value :: { [string]: unknown }
	local x, y, w, h = raw.x, raw.y, raw.w, raw.h
	if type(x) ~= "number" or type(y) ~= "number" or type(w) ~= "number" or type(h) ~= "number" then
		return nil
	end
	if x ~= x or y ~= y or w ~= w or h ~= h or math.abs(x) > 1e5 or math.abs(y) > 1e5 or w < 0 or h < 0 then
		return nil
	end
	return { x = x, y = y, w = w, h = h }
end

-- Validates open args against MonetizationConfig (nil = nothing to show: unknown / unpublished).
local function readDeal(args: unknown): Deal?
	if type(args) ~= "table" then
		return nil
	end
	local raw = args :: { [string]: unknown }
	local key = shortString(raw.key, 40)
	local kind = raw.kind
	if key == nil or (kind ~= "pass" and kind ~= "product") then
		return nil
	end
	local def: any = if kind == "pass" then MonetizationConfig.getPass(key) else MonetizationConfig.getProduct(key)
	if def == nil or not MonetizationConfig.isConfigured(def.id) then
		return nil
	end
	local source = shortString(raw.source, 16) or "offer"
	local onBuy = raw.onBuy
	local onClosed = raw.onClosed
	return {
		id = shortString(raw.id, 64) or `{source}:{key}`,
		source = source,
		key = key,
		kind = (kind :: any) :: "pass" | "product",
		promptSource = shortString(raw.promptSource, 16),
		title = shortString(raw.title, 60) or string.upper(def.name),
		line = shortString(raw.line, 160) or def.description,
		icon = shortString(raw.icon, 40) or def.icon,
		anchor = readRect(raw.anchor),
		onBuy = if type(onBuy) == "function" then onBuy :: () -> () else nil,
		onClosed = if type(onClosed) == "function" then onClosed :: (CloseReason) -> () else nil,
	}
end

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

		local current: Deal? = nil
		local open = false
		local token = 0
		-- Why the card is closing (set before ScreenManager.close; anything else = "hidden").
		local closing: CloseReason? = nil
		local connections: { Signal.Connection } = {}
		local buy: () -> ()
		local dismiss: (reason: CloseReason) -> ()

		local view = ActionCard.new(root, {
			primaryWidth = Card.BuyWidth,
			secondaryWidth = Card.CloseWidth,
			glyphHeight = Card.GlyphHeight,
			primaryKey = Keys.BuyKey,
			primaryPad = Keys.BuyPad,
			secondaryKey = InputConfig.CloseKey,
			secondaryPad = InputConfig.BackButton,
			onPrimary = function()
				-- The press that opened the card never buys (it began before the card showed).
				if PurchaseGuard.allow(NAME) then
					buy()
				end
			end,
			onSecondary = function()
				dismiss("close")
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

		-- Places the card: beside its chip (left of it when there is room, else right), or at the
		-- bottom of the bottom-left feed column.
		local function place()
			local deal = current
			if deal == nil then
				return
			end
			local f = floors()
			local anchor = deal.anchor
			if anchor == nil then
				local base = FeedCardMetrics.compute(SPEC, 1, f)
				local area = PopupQueue.feedArea(base.height)
				local metrics =
					FeedCardMetrics.fit(SPEC, area.width, math.max(0, area.bottom - area.top), Card.MinFit, f)
				local x, y, fit = PopupQueue.placeFeedCard(metrics.width, metrics.height, metrics.fit)
				view.holder.Position = UDim2.fromOffset(x, y)
				view.fitScale.Scale = fit
				view.apply(metrics)
				return
			end
			local canvas = ScreenManager.canvasSize(gui)
			local top = ScreenManager.safeTop(0) + EDGE
			local bottom = canvas.Y - EDGE - (PopupQueue.touchReserve() or 0)
			local leftRoom = anchor.x - Card.ChipGap - EDGE
			local rightRoom = canvas.X - EDGE - (anchor.x + anchor.w + Card.ChipGap)
			local onLeft = leftRoom >= rightRoom
			local metrics =
				FeedCardMetrics.fit(SPEC, math.max(leftRoom, rightRoom), math.max(0, bottom - top), Card.MinFit, f)
			local fit = metrics.fit
			local w, h = metrics.width * fit, metrics.height * fit
			local x = if onLeft then anchor.x - Card.ChipGap - w else anchor.x + anchor.w + Card.ChipGap
			local y = math.clamp(anchor.y + anchor.h / 2 - h / 2, top, math.max(top, bottom - h))
			view.holder.Position = UDim2.fromOffset(math.max(EDGE, x), y)
			view.fitScale.Scale = fit
			view.apply(metrics)
		end

		-- Drops the per-open connections + bindings.
		local function disconnect()
			for _, connection in connections do
				connection:Disconnect()
			end
			table.clear(connections)
			ContextActionService:UnbindAction(BUY_ACTION)
			ContextActionService:UnbindAction(CLOSE_ACTION)
		end

		-- Tells the owner of `deal` why its card ended (pcall: a broken callback never jams).
		local function notify(deal: Deal, reason: CloseReason)
			local callback = deal.onClosed
			if callback ~= nil then
				local ok, err = pcall(callback, reason)
				if not ok then
					warn(`[DealCard] onClosed error: {err}`)
				end
			end
		end

		dismiss = function(reason: CloseReason)
			if not open then
				return
			end
			closing = reason
			ScreenManager.close(NAME)
		end

		buy = function()
			local deal = current
			if deal == nil or not open then
				return
			end
			local callback = deal.onBuy
			if callback ~= nil then
				local ok, err = pcall(callback)
				if not ok then
					warn(`[DealCard] onBuy error: {err}`)
				end
			else
				-- Intent only: the server validates the key and shows the Roblox prompt.
				Remotes.event(if deal.kind == "pass" then "PromptPass" else "PromptProduct")
					:FireServer(deal.key, deal.promptSource)
			end
			dismiss("buy")
		end

		-- Binds BUY (X / E, below gameplay) and CLOSE (B / X / Backspace, high) while open.
		local function bind()
			ContextActionService:BindActionAtPriority(
				BUY_ACTION,
				function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
					if state ~= Enum.UserInputState.Begin or not open or ScreenManager.anyModalOpen() then
						return Enum.ContextActionResult.Pass
					end
					if not PurchaseGuard.allow(NAME, os.clock()) then
						return Enum.ContextActionResult.Pass
					end
					buy()
					return Enum.ContextActionResult.Sink
				end,
				false,
				Keys.BuyPriority,
				Keys.BuyKey,
				Keys.BuyPad
			)
			ContextActionService:BindActionAtPriority(
				CLOSE_ACTION,
				function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
					if state ~= Enum.UserInputState.Begin or not open or ScreenManager.anyModalOpen() then
						return Enum.ContextActionResult.Pass
					end
					dismiss("close")
					return Enum.ContextActionResult.Sink
				end,
				false,
				Keys.ClosePriority,
				InputConfig.BackButton,
				table.unpack(InputConfig.CloseKeys)
			)
		end

		return {
			onOpen = function(args: any?)
				local deal = readDeal(args)
				if deal == nil then
					-- Nothing valid to show (unknown / unpublished product): never an empty card.
					if not open then
						task.defer(ScreenManager.close, NAME)
					end
					return
				end
				local previous = current
				if open and previous ~= nil and previous.id == deal.id then
					-- Same caller re-asking: refresh the content only (no re-arm, no pop).
					current = deal
				else
					if open and previous ~= nil then
						notify(previous, "replaced")
					end
					current = deal
					token += 1
					PurchaseGuard.opened(NAME)
					view.pop(Card.PopFrom, Card.PopSeconds)
					if deal.source == "offer" then
						ClientAnalytics.screenOpened("Offers", "hud")
						ClientAnalytics.offerSeen(deal.key, "popup", true)
					end
				end
				open = true
				closing = nil
				gui:SetAttribute("DealId", deal.id)
				view.setContent({
					color = Card.Colors[deal.source] or Card.Colors.offer,
					icon = deal.icon,
					title = deal.title,
					line = deal.line,
					primaryText = "",
					primaryProductKey = deal.key,
					primaryColor = "green",
					secondaryText = Card.Text.Close,
				})
				local primary = view.primaryButton()
				if primary ~= nil then
					PurchaseGuard.markBuy(primary)
				end
				place()
				if #connections == 0 then
					-- Re-place on HUD / layout changes; a menu opening closes the card (the HUD's
					-- columns hide behind menus too, owner R79).
					table.insert(
						connections,
						PopupQueue.Changed:Connect(function(what: string)
							if what == "band" and open then
								place()
							end
						end)
					)
					table.insert(
						connections,
						ScreenManager.Opened:Connect(function(name: string)
							if open and name ~= NAME and ScreenManager.isModal(name) then
								dismiss("modal")
							end
						end)
					)
					bind()
				end
				-- Chip cards are previews: they close themselves (the Lucky card stays while the
				-- player stands at the button; its presenter closes it).
				if deal.anchor ~= nil then
					local mine = token
					task.delay(Card.ChipAutoClose, function()
						if token == mine and open then
							dismiss("timeout")
						end
					end)
				end
			end,
			onClose = function()
				local deal = current
				local reason: CloseReason = closing or "hidden"
				open = false
				current = nil
				closing = nil
				token += 1
				gui:SetAttribute("DealId", nil)
				disconnect()
				if deal ~= nil and deal.anchor == nil then
					PopupQueue.clearFeedCard()
				end
				if deal ~= nil then
					notify(deal, reason)
				end
			end,
		}
	end,
}

return screen
