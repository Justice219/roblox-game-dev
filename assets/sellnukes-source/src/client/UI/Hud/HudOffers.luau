--!strict
--[[
	HudOffers — the HUD's right column of rotating starburst Robux offers (x2 Cash, Starter Pack,
	VIP, x5 Spins, Teleporter, Secret Pack).

	Purpose:
		Builds one StudUI.starburst per HudZonesConfig.Offers row, priced LIVE from UI/PriceBook
		(the managed Robux price Roblox will charge this player; "..." until known / unknown key). Offers the player can no longer buy
		are hidden (an owned pass in profile.passes, a bought Starter / Secret Pack, a PAID RANDOM
		product — x5 Spins — where the region restricts paid random items:
		EggConfig.policyState(profile.policy) == "restricted"). When the
		screen fits fewer slots than there are offers, the first (slots - 1) stay and the LAST slot
		cycles through the rest every UIStyleConfig.Hud.OfferRotateSeconds (one task, only while
		rotation is needed; a soft pop when it swaps).

	Worlds (owner R57 World 2): WorldClientConfig.Offers[worldId] rows (the Time Traveler Pack)
	join the offers while the player is in that world (`setWorld`), as the LAST offers, so they
	take the rotating slot on small screens; a one-time world pack disappears once
	profile.worlds.<world>.starter.bought. Nuke Town shows exactly the original offers.

	Nuke Pass (owner R78): the "Pass" row shows only while a season runs and the player has not
	bought its premium (PassConfig.offerVisible on the pass clock) and, being an `openScreen` row,
	opens the NukePass track screen (the premium CTA lives there) instead of prompting directly.

	Pocket Rocket (owner R89 gift ladder wave §3): the daily impulse developer product sits SECOND
	in the column (after x2 Cash). Its label is the LIVE amount the server would grant now —
	"+$42.4K" = GiftsConfig.rocketReward() (income seconds, at least the floor) previewed with the
	same rule as the grant (DailyRewards/RewardPreview.cash on the player's own snapshot). It shows
	only in Nuke Town (it pays Nuke Town cash), only once its dashboard id is live, and hides once
	profile.gifts.rocketDay == today (back after UTC midnight: one timer). HudOffers listens to
	ClientState itself for gifts / tycoon / rebirths / rebirthShop (Hud.luau forwards only the
	ownership fields), so the label follows the income without any per-frame work.

	Buying (owner R122, spec §2.4: no accidental purchase prompts — DoubleCash chip taps prompted
	at once: 17 + 14 prompts in two days, mostly closed in under 2 s on phones / tablets): pressing
	an offer whose product / pass id is live (MonetizationConfig.isConfigured) opens its small
	non-modal DEAL card beside the chip (UI/Screens/DealCard: art, name, line, live price, BUY +
	CLOSE; never auto-focused, closes itself after a few seconds). Only the card's BUY sends the
	PromptProduct / PromptPass INTENT with source "offer" (the server prompts and grants; the client
	never grants anything), and the press that opened the card can never buy (UI/PurchaseGuard).
	Pressing the chip again closes its card; the rotating slot holds still while a card is open.
	An offer whose id is still 0 opens its screen instead (Shop / Lucky Wheel, or the "Coming soon"
	fallback), so nothing is ever a dead button.

	Connects to: Shared/Config/{HudZonesConfig, MonetizationConfig, UIStyleConfig},
	UI/Screens/DealCard (the card a chip opens; its BUY sends PromptProduct / PromptPass),
	Kit/StudUI.starburst (productKey → UI/PriceBook), UI/ScreenManager, UI/Hud/Hud (owner: layout +
	profile updates).

	Example:
		local offers = HudOffers.new(container)
		offers.setProfile(ClientState.profile)
		offers.apply(layout.right)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- R89 Pocket Rocket: the live amount follows the player's own snapshot (ClientState).
local ClientState = require(script.Parent.Parent.Parent.ClientState)
-- EggConfig.policyState: the shared reader of profile.policy (allowed / restricted / checking).
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
-- R89 Pocket Rocket: product key, reward shape, "bought today" rule and HUD icon.
local GiftsConfig = require(ReplicatedStorage.Shared.Config.GiftsConfig)
local HudPlacement = require(script.Parent.Parent.Widgets.HudPlacement)
local HudZonesConfig = require(ReplicatedStorage.Shared.Config.HudZonesConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
-- R78 Nuke Pass offer visibility (season running + premium not owned, on the pass clock).
local PassConfig = require(ReplicatedStorage.Shared.Config.PassConfig)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
-- R89: the shared client preview of a RetentionConfig.Reward (same rule as RewardLogic.cashFor).
local RewardPreview = require(script.Parent.Parent.Screens.DailyRewards.RewardPreview)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
-- Owner R122: the DEAL card a chip tap opens (by name; its open card id is the DealId attribute).
local DEAL_SCREEN = "DealCard"
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldClientConfig = require(ReplicatedStorage.Shared.Config.WorldClientConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

export type HudOffers = {
	apply: (layout: HudPlacement.RightLayout) -> (),
	setProfile: (profile: any) -> (),
	count: () -> number, -- offers still available (HudPlacement input)
	first: () -> GuiObject?,
	-- Links the visible offers vertically (wrapping) and their left exit into the HUD grid. With
	-- `downExit` (the bottom-right WHAT'S NEW chip, owner R58) Down from the last offer goes there
	-- (and the chip's Up comes back to that offer) instead of wrapping to the first.
	linkNav: (leftExit: GuiObject?, downExit: GuiObject?) -> (),
	onChanged: (callback: () -> ()) -> (),
	-- R57: the world the player is in (world offers join / leave the column).
	setWorld: (worldId: string) -> (),
}

type Item = {
	row: HudZonesConfig.OfferRow,
	handle: StudUI.Starburst,
	available: boolean,
	world: string?, -- R57: only offered while in this world (nil = every world)
	starter: boolean, -- R57: one-time world pack (hidden once worlds.<world>.starter.bought)
	rocket: boolean, -- R89: the Pocket Rocket (live amount label, Nuke Town only, once per day)
}

-- Profile fields that change the Pocket Rocket's amount or availability (R89).
local ROCKET_FIELDS = { "gifts", "tycoon", "rebirths", "rebirthShop" }

local HudOffers = {}

-- The dashboard id of an offer row (0 = unknown key / unpublished: not purchasable yet).
local function liveId(row: HudZonesConfig.OfferRow): number
	local group: { [string]: any } = if row.kind == "pass"
		then MonetizationConfig.Passes :: any
		else MonetizationConfig.Products :: any
	local def = group[row.product]
	return if def ~= nil then def.id else 0
end

--[[
	R89: true when the Pocket Rocket can be offered now — its dashboard id is live, the profile has
	arrived and today's rocket was not used yet (server clock UTC day). Hidden before the first
	push, so it never flashes for someone who already bought it.
]]
local function rocketAvailable(profile: any): boolean
	local product = GiftsConfig.rocketProduct()
	if
		not GiftsConfig.RocketEnabled
		or product == nil
		or not MonetizationConfig.isConfigured(product.id)
		or type(profile) ~= "table"
	then
		return false
	end
	local today = RetentionConfig.utcDay(Workspace:GetServerTimeNow())
	return not GiftsConfig.rocketBoughtToday(profile.gifts, today)
end

--[[
	R89: the Pocket Rocket's label — the cash the server would grant right now ("+$42.4K"), or the
	plain name before the first profile push.
	Example: rocketLabel(ClientState.profile) --> "+$42.4K"
]]
local function rocketLabel(profile: any): string
	local cash = if type(profile) == "table" then RewardPreview.cash(GiftsConfig.rocketReward(), profile) else 0
	return if cash > 0 then `+{NumberFormat.money(cash)}` else GiftsConfig.Rocket.Label
end

-- True when the player can still buy this offer (owned passes / one-time packs disappear).
local function availableFor(row: HudZonesConfig.OfferRow, profile: any): boolean
	-- R89 Pocket Rocket: live id + not used today (decided even before the first push: hidden).
	if row.product == GiftsConfig.Rocket.Product then
		return rocketAvailable(profile)
	end
	-- R78 Nuke Pass: only while a season runs and its premium is not owned (pass clock); decided
	-- even before the first profile push, so it never flashes outside a season.
	if row.product == PassConfig.PremiumProduct then
		local pass = if type(profile) == "table" then profile.pass else nil
		return PassConfig.offerVisible(pass, PassConfig.clockNow(Workspace:GetServerTimeNow()))
	end
	if type(profile) ~= "table" then
		return true
	end
	if row.kind == "pass" then
		local passes = profile.passes
		return not (type(passes) == "table" and passes[row.product] == true)
	end
	if row.product == "StarterPack" then
		return not (type(profile.starter) == "table" and profile.starter.bought == true)
	end
	if row.product == "SecretPack" then
		return not (type(profile.secretPack) == "table" and profile.secretPack.bought == true)
	end
	-- Paid random products are never advertised where the region restricts them.
	local product = MonetizationConfig.getProduct(row.product)
	if product ~= nil and product.paidRandom and EggConfig.policyState(profile.policy) == "restricted" then
		return false
	end
	return true
end

--[[
	Builds every offer under `container` (positions are absolute design px).
	@param container parent frame
	@return HudOffers handle
]]
function HudOffers.new(container: Frame): HudOffers
	local items: { Item } = {}
	local changed: (() -> ())? = nil
	local layout: HudPlacement.RightLayout? = nil
	local rotation = 0 -- index into the rotating pool
	local rotateThread: thread? = nil
	local currentWorld = WorldsConfig.MAIN
	local lastProfile: any = nil

	-- Every offer row: the shared column, then each non-main world's rows (R57) in world order.
	local rows: { { row: HudZonesConfig.OfferRow, world: string?, starter: boolean, rocket: boolean } } = {}
	for _, row in HudZonesConfig.Offers do
		table.insert(rows, { row = row, world = nil, starter = false, rocket = false })
	end
	-- R89 Pocket Rocket: second in the column (after x2 Cash); its picture falls back to the
	-- cartoon rocket while the dedicated icon is not uploaded.
	local rocketRow: HudZonesConfig.OfferRow = {
		key = GiftsConfig.Rocket.OfferKey,
		label = GiftsConfig.Rocket.Label,
		icon = if StudUI.hasIcon(GiftsConfig.Rocket.Icon)
			then GiftsConfig.Rocket.Icon
			else GiftsConfig.Rocket.FallbackIcon,
		product = GiftsConfig.Rocket.Product,
		kind = "product",
		screen = "Shop",
	}
	table.insert(rows, math.min(2, #rows + 1), { row = rocketRow, world = nil, starter = false, rocket = true })
	for _, def in WorldsConfig.extra() do
		for _, offer in WorldClientConfig.Offers[def.id] or {} do
			local row: HudZonesConfig.OfferRow = {
				key = offer.key,
				label = offer.label,
				icon = offer.icon,
				product = offer.product,
				kind = offer.kind,
				screen = offer.screen,
			} :: any
			table.insert(rows, { row = row, world = def.id, starter = offer.starter, rocket = false })
		end
	end

	-- Owner R122: the DealCard id of an offer row's card.
	local function dealIdOf(row: HudZonesConfig.OfferRow): string
		return `offer:{row.key}`
	end

	-- The id of the DEAL card on screen (nil = none).
	local function openDealId(): string?
		if not ScreenManager.isOpen(DEAL_SCREEN) then
			return nil
		end
		local gui = ScreenManager.getGui(DEAL_SCREEN)
		local id = if gui ~= nil then gui:GetAttribute("DealId") else nil
		return if type(id) == "string" then id else nil
	end

	-- True while one of THESE offers' cards is open (the rotation holds still meanwhile).
	local function offerCardOpen(): boolean
		local id = openDealId()
		return id ~= nil and string.sub(id, 1, 6) == "offer:"
	end

	--[[
		Owner R122: a chip press opens (or, pressed again, closes) the offer's DEAL card beside the
		chip — the chip's rect in design px from the current layout (the card's screen shares the
		HUD's canvas + safe area). Only the card's BUY sends the prompt intent.
	]]
	local function toggleCard(row: HudZonesConfig.OfferRow, root: GuiObject, live: string?)
		local id = dealIdOf(row)
		if openDealId() == id then
			ScreenManager.close(DEAL_SCREEN)
			return
		end
		local current = layout
		local anchor = if current ~= nil
			then {
				x = root.Position.X.Offset - current.slot / 2,
				y = root.Position.Y.Offset,
				w = current.slot,
				h = current.slot,
			}
			else nil
		ScreenManager.open(DEAL_SCREEN, {
			id = id,
			source = "offer",
			key = row.product,
			kind = row.kind,
			promptSource = "offer",
			-- The Pocket Rocket says its live amount ("+$42.4K") like its chip does.
			line = live,
			anchor = anchor,
		})
	end

	for index, entry in rows do
		local row = entry.row
		local handle = StudUI.starburst({
			label = row.label,
			-- Live managed price (UI/PriceBook); "..." while unknown.
			productKey = row.product,
			icon = row.icon,
			layoutOrder = index,
			name = `Offer_{row.key}`,
			onActivated = function()
				if row.openScreen == true then
					-- R78: offers that sell from their own screen (the Nuke Pass track) open it.
					ScreenManager.open(row.screen, { source = "offer" })
				elseif MonetizationConfig.isConfigured(liveId(row)) then
					-- R122: the card first; its BUY sends the intent (the server prompts).
					local root = items[index].handle.instance
					local live = if entry.rocket
						then `{rocketLabel(lastProfile or ClientState.profile)} cash right now!`
						else nil
					toggleCard(row, root, live)
				else
					ScreenManager.open(row.screen, { focus = row.product })
				end
			end,
		})
		handle.instance.Visible = false
		handle.instance.Parent = container
		table.insert(items, {
			row = row,
			handle = handle,
			-- The rocket starts hidden until its availability is known (no flash).
			available = entry.world == nil and not entry.rocket,
			world = entry.world,
			starter = entry.starter,
			rocket = entry.rocket,
		})
	end

	--[[
		R57: true when a world offer can show now — the player is in its world and (one-time
		packs) has not bought it yet (profile.worlds.<world>.starter.bought).
	]]
	local function worldAllows(item: Item, profile: any): boolean
		-- R89: the Pocket Rocket pays Nuke Town cash, so it is offered only there.
		if item.rocket then
			return currentWorld == WorldsConfig.MAIN
		end
		local world = item.world
		if world == nil then
			return true
		end
		if world ~= currentWorld then
			return false
		end
		if item.starter and type(profile) == "table" and type(profile.worlds) == "table" then
			local data = profile.worlds[world]
			local starter = if type(data) == "table" then data.starter else nil
			if type(starter) == "table" and starter.bought == true then
				return false
			end
		end
		return true
	end

	-- Re-evaluates every offer's availability; true when any changed.
	local function refreshAvailability(profile: any): boolean
		local any = false
		for _, item in items do
			local available = availableFor(item.row, profile) and worldAllows(item, profile)
			if available ~= item.available then
				item.available = available
				any = true
			end
		end
		return any
	end

	local function availableItems(): { Item }
		local list: { Item } = {}
		for _, item in items do
			if item.available then
				table.insert(list, item)
			end
		end
		return list
	end

	-- Links the visible offers vertically (wrapping) and their left exit into the HUD grid.
	local navLeft: GuiObject? = nil
	-- Optional exit below the last offer (the WHAT'S NEW chip, owner R58); nil = wrap to the first.
	local navDown: GuiObject? = nil
	local function relink()
		local shown: { TextButton } = {}
		for _, item in items do
			if item.handle.instance.Visible then
				table.insert(shown, item.handle.instance)
			end
		end
		table.sort(shown, function(a: TextButton, b: TextButton): boolean
			return a.Position.Y.Offset < b.Position.Y.Offset
		end)
		for index, shownButton in shown do
			-- `any` view: nil NextSelection* (engine default) is valid but typed non-optional.
			local button: any = shownButton
			button.NextSelectionUp = shown[if index == 1 then #shown else index - 1]
			button.NextSelectionDown = if index == #shown and navDown ~= nil
				then navDown
				else shown[if index == #shown then 1 else index + 1]
			button.NextSelectionLeft = navLeft
			button.NextSelectionRight = nil
		end
		-- The exit below leads back up to whichever offer is last right now (rotation included).
		local exit: any = navDown
		if exit ~= nil and #shown > 0 then
			exit.NextSelectionUp = shown[#shown]
		end
	end

	-- Shows the right offers in the right slots for the current layout + rotation index.
	local function render(pop: boolean)
		local current = layout
		for _, item in items do
			item.handle.instance.Visible = false
		end
		if current == nil then
			return
		end
		local list = availableItems()
		local slots = math.min(current.slots, #list)
		for slot = 1, slots do
			local item: Item
			if slot < slots or #list <= current.slots then
				item = list[slot]
			else
				-- The last slot cycles through every offer that did not get a fixed slot.
				local pool = #list - (slots - 1)
				item = list[slots + (rotation % pool)]
			end
			local root = item.handle.instance
			root.AnchorPoint = Vector2.new(0.5, 0)
			root.Position = UDim2.fromOffset(current.x, current.y + (slot - 1) * (current.slot + current.gap))
			item.handle.setSize(current.slot)
			root.Visible = true
			if pop and slot == slots then
				item.handle.pop()
			end
		end
		-- The rotating slot may have swapped offers: keep the D-pad links current.
		relink()
		-- R122: an offer that just left the column (bought / owned / another world) takes its
		-- DEAL card with it.
		local openId = openDealId()
		if openId ~= nil and string.sub(openId, 1, 6) == "offer:" then
			local still = false
			for _, item in items do
				if item.handle.instance.Visible and dealIdOf(item.row) == openId then
					still = true
					break
				end
			end
			if not still then
				ScreenManager.close(DEAL_SCREEN)
			end
		end
	end

	-- Starts / stops the single rotation task depending on whether offers overflow the slots.
	local function refreshRotation()
		local current = layout
		local needs = current ~= nil and #availableItems() > current.slots
		if needs and rotateThread == nil then
			rotateThread = task.spawn(function()
				while true do
					task.wait(UIStyleConfig.Hud.OfferRotateSeconds)
					-- R122: hold still while an offer's DEAL card is open (it points at its chip).
					if not offerCardOpen() then
						rotation += 1
						render(true)
					end
				end
			end)
		elseif not needs and rotateThread ~= nil then
			task.cancel(rotateThread)
			rotateThread = nil
			rotation = 0
		end
	end

	-- R89 Pocket Rocket: the live amount label (only written when it changes).
	local rocketText: string? = nil
	local function refreshRocketLabel(profile: any)
		local text = rocketLabel(profile)
		if text == rocketText then
			return
		end
		rocketText = text
		for _, item in items do
			if item.rocket then
				item.handle.setLabel(text)
			end
		end
	end

	-- Re-evaluates availability and asks the Hud for a re-layout when anything changed.
	local function reevaluate()
		if refreshAvailability(lastProfile) then
			local callback = changed
			if callback ~= nil then
				callback()
			end
		end
	end

	-- R89: the rocket's own profile listener (amount + "bought today"); Hud.luau forwards only
	-- the ownership fields to setProfile.
	local profileConnection = ClientState.ProfileChanged:Connect(function(profile: any, fields: { string }?)
		local touched = fields == nil
		if fields ~= nil then
			for _, field in ROCKET_FIELDS do
				if table.find(fields, field) ~= nil then
					touched = true
					break
				end
			end
		end
		if not touched then
			return
		end
		lastProfile = profile
		refreshRocketLabel(profile)
		reevaluate()
	end)
	-- R89: today's rocket comes back after UTC midnight (one timer, rescheduled each midnight).
	local midnightThread: thread? = nil
	local function scheduleMidnight()
		local wait = RetentionConfig.secondsToNextDay(Workspace:GetServerTimeNow()) + 1
		midnightThread = task.delay(wait, function()
			midnightThread = nil
			reevaluate()
			scheduleMidnight()
		end)
	end
	scheduleMidnight()

	container.Destroying:Once(function()
		if rotateThread ~= nil then
			task.cancel(rotateThread)
			rotateThread = nil
		end
		profileConnection:Disconnect()
		local midnight = midnightThread
		if midnight ~= nil then
			midnightThread = nil
			task.cancel(midnight)
		end
	end)

	return {
		apply = function(newLayout: HudPlacement.RightLayout)
			layout = newLayout
			render(false)
			refreshRotation()
		end,
		setProfile = function(profile: any)
			lastProfile = profile
			refreshRocketLabel(profile)
			if refreshAvailability(profile) then
				local callback = changed
				if callback ~= nil then
					callback() -- Hud re-lays out (the slot count may change), then apply() renders
				end
			end
		end,
		setWorld = function(worldId: string)
			if worldId == currentWorld then
				return
			end
			currentWorld = worldId
			if refreshAvailability(lastProfile) then
				local callback = changed
				if callback ~= nil then
					callback()
				end
			end
		end,
		count = function(): number
			return #availableItems()
		end,
		first = function(): GuiObject?
			for _, item in items do
				if item.handle.instance.Visible then
					return item.handle.instance
				end
			end
			return nil
		end,
		linkNav = function(leftExit: GuiObject?, downExit: GuiObject?)
			navLeft = leftExit
			navDown = downExit
			relink()
		end,
		onChanged = function(callback: () -> ())
			changed = callback
		end,
	}
end

return table.freeze(HudOffers)
