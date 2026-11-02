--!strict
--[[
	Shop — the Robux shop window (reference docs/reference/ui-style/02-shop-limited-time.png):
	a yellow "Shop" header (basket icon) over a scrolling slate body with one section per
	ShopConfig.Sections entry, in order, each under a "- TITLE -" section label:

		limited  the big RED sunburst STARTER PACK card and the WHITE / silver SECRET PACK card
		         (red "Limited Stock" + live "123 / 500 left" stock line)      -> Shop/PackCard
		passes   purple game pass cards (name, first two perks, price)         -> Shop/ShopCard
		cash     green cash packs with a live preview ("$12.5K": RewardPreview, the same rule the
		         server grants with, recomputed when income changes)
		gems     blue gem packs ("+350 Gems")
		spins    rainbow Lucky Spin packs ("+5 Spins"; UNAVAILABLE where paid random items are
		         not allowed: profile.policy.paidRandomRestricted)
		packs'   spins tile: "5 Lucky Spins", or "200 Gems" where paid random items are
		         restricted / not known yet (the server pays the spins as gems then:
		         ShopConfig.packLines, Server/Retention/RewardLogic.robuxReward)
		boosts   orange boosts; 2x Cash shows "ACTIVE 12:34" while profile.boosts.cash2x runs,
		         Server 2x Cash while ReplicatedStorage.ServerBoostEndsAt is in the future

	World sections (owner R57 World 2, spec §9 / §14; ShopConfig.WorldSections), placed right
	after the section their row names (`after`):
		dino     DINO VALLEY — "Pile / Sack / Crate of Bones" (kind WorldCash) + the one-time
		         "Time Traveler Pack" (kind WorldStarter), each with a live Bones preview
		         ("4.5M Bones": ShopLogic.worldCashAmount, the server's grant rule, formatted by
		         WorldClientLogic.formatAmount) and its R39 shop-prop model (Shop_Bones* /
		         Shop_TimeTravelerPack; icon fallback BonesPack* / TimeTravelerPack)
		moon     MOON BASE (R70 World 3) — "Bag / Sack / Crate of Moon Rocks" + the one-time
		         "Astronaut Pack", the same way (Shop_MoonRocks* / Shop_AstronautPack props, W1b;
		         icons MoonRocksPack* / AstronautPack). Every world works from config alone: this
		         module iterates ShopConfig.WorldSections and never names a world.
		- Header: the world's TAB style (WorldClientConfig.Tabs[world]: label + icon + colour on
		  a stud pill) instead of the "- TITLE -" label, so it reads like the Teleport / Rebirth
		  world tabs.
		- Hidden (takes no space, no LB / RB stop, no gamepad cell, no impressions) until the
		  world is unlocked (WorldClient.isUnlocked) and while the admin kill switch closes it
		  (WorldClient.isEnabled == false). A one-time pack (Time Traveler / Astronaut) leaves
		  once bought (profile.worlds.<world>.starter.bought, or a PurchaseGranted this session).
		- Lazy: its cards (and so their 3D models) are built the first time it shows; a player
		  who never unlocks the world never loads them. The boot prefetch adds its models only
		  for players who already have the world.
		- Live while open: WorldClient.StateChanged + ClientState.ProfileChanged("worlds")
		  (connected on open, disconnected on close, coalesced to one pass per frame) re-check
		  visibility, statuses and currency previews; the list re-lays out only when something
		  appeared / disappeared.
		- Opening the Shop while in that world (WorldClient.current()) with no target scrolls to
		  the section and puts the gamepad cursor on its first buyable card.

	Item plates + idle animation (owner R98 "the item in the shop should be animated. also they are
	hard to see with the stud background"): every card / pack item sits on a dark plate in its
	card's shade (glow ring, drop shadow) with its captions on dark name-plates, and bobs + pulses
	(staggered); rare items glint (Shop/ItemFx). Each card has ONE OfferFx animator (on screen
	only; Low graphics / Reduce Motion park it); this screen switches every group on when it
	opens and off when it closes (ItemFx.setEnabled: one batched visibility re-check).

	3D models (owner R39): every card and pack tile shows the item's REAL game model in a rotating,
	lit Widgets/ModelViewport (Shop/ShopModels picks it: pets / eggs / crates / nukes are their
	game models, everything else a Blender shop prop); the 2D icon is only the loading fallback.
	Slots spin only while on screen (paused when scrolled away or the Shop is closed), within the
	device's live budget. ShopModels.PrefetchDelay s after boot the models warm in the background
	so the first open is already 3D.

	Buttons: green Robux price -> PromptProduct(key, "shop") / PromptPass(key, "shop") intents.
	OWNED (claimed) for owned passes / bought one-time packs; SOON (locked, price still shown)
	for unpublished items; SOLD OUT (locked) when the Secret Pack's global stock is gone.

	Opening (ScreenManager.open("Shop", args)):
		args = nil                      top of the shop
		args = { section = "gems" }      scrolls that section into view, cursor on its heading
		                                 (Down: its first buyable card)
		args = { product = "Spins5" } / { pass = "VIP" } / { focus = "VIP" } (HUD offers)
		                                 scrolls the item's section (or the card itself) into view
		                                 and puts the gamepad cursor on its SECTION HEADING (R122;
		                                 Down from there reaches the card's button)
		args.source                      analytics source ("hud", "offer", ...)

	Console + mobile (owner R11, docs/platform.md §7):
		- Gamepad: every section's buy buttons are linked as a grid (GamepadNav.linkGrid) and the
		  sections chain top to bottom (up = the previous block's last row, down = the next
		  block's first cell); the body follows the cursor (GamepadNav.followScroll); LB / RB
		  (Q / E) jump to the previous / next section (GamepadNav.cycler, on while open).
		  Owner R122 (no accidental purchase prompts): the cursor NEVER starts on a BUY button.
		  Every section heading is a PurchaseGuard landing (a non-buy gamepad stop with the white
		  ring); an open lands on the heading of the section holding the preferred card (the
		  open's target, else the Starter Pack, else the first buyable card; inside a world with a
		  shown Shop section, that section) and Down from the heading goes straight to that card.
		  Every BUY is tagged (PurchaseGuard.markBuy) and every prompt intent passes
		  PurchaseGuard.allow("Shop"): the press that opened the Shop never buys. Hidden world
		  sections are no LB / RB stop and no gamepad cell. B / Back closes (ScreenManager).
		- Phones / tablets (Shop/ShopLayout, re-run on ScreenManager.LayoutChanged and when the
		  ScreenGui gets its real size): the content is scaled so card text stays >= 14 pt and buy
		  buttons >= 44 pt; columns drop (4 desktop, 3 tablet, 2-1 phones); phones get a window
		  that fills the screen below the top bar and short "wide" cards so whole cards fit; pack
		  cards stack their button under the tiles when narrow.

	Small screens (lead follow-up): auto-sized labels keep their size limits in DESIGN px
	(Shop/ShopText), so pack captions / pass perks wrap onto their second line at any window
	scale instead of losing it; text that can never fit ends in "...".

	Performance: every card is built ONCE on first open (lazy). Updates are event-driven and
	targeted: ProfileChanged re-applies only the cards whose fields changed (passes -> pass cards,
	starter / secretPack / policy -> product states, tycoon / rebirths -> cash previews, boosts ->
	the boost countdown); PurchaseGranted and the ReplicatedStorage stock / server-boost
	attributes do the same. While the window is closed nothing is touched; opening refreshes
	every card once. A re-layout only runs when the plan actually changed. Countdowns share
	StudUI's single 1 Hz ticker.

	Analytics: ClientAnalytics.screenOpened("Shop", source) once per open, and offerSeen(key,
	"shop") for each BUYABLE card once it is at least half on screen during a visit
	(impressions; owned / SOON / SOLD OUT cards are not offers).

	Security: the client only sends intents. Prices, names and amounts come from
	MonetizationConfig / ShopConfig / the server's profile snapshot; MonetizationService validates
	every prompt (published id, one-time flags, stock, policy) and grants server-side.

	Connects to: Kit/StudUI, UI/{Create, ScreenManager}, Widgets/{ModalShell, ModelViewport},
	Platform/GamepadNav, Shop/{ShopLogic, ShopLayout, ShopCard, PackCard, ShopModels, ItemFx},
	Screens/DailyRewards/RewardPreview, Client/ClientState, Analytics/ClientAnalytics,
	Client/Worlds/{WorldClient, WorldClientLogic} (R57 world sections),
	Shared/Config/{ShopConfig, MonetizationConfig, BoostConfig, TouchUIConfig, UIStyleConfig,
	WorldClientConfig, Worlds/WorldsConfig}, Shared/Util/{NumberFormat, Signal},
	Shared/Net/Remotes.
	Opened by the HUD Shop button and offers.

	Example:
		ScreenManager.open("Shop", { section = "passes", source = "hud" })
		ScreenManager.open("Shop", { focus = "StarterPack" })
		ScreenManager.open("Shop", { section = "dino" })              -- ignored while hidden
		ScreenManager.open("Shop", { product = "TimeTravelerPack" })  -- HUD offer in the Valley
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BoostConfig = require(ReplicatedStorage.Shared.Config.BoostConfig)
local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Create)
-- EggConfig.policyState: the shared reader of profile.policy (allowed / restricted / checking).
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local ItemFx = require(script.ItemFx)
local ModalShell = require(script.Parent.Parent.Widgets.ModalShell)
local ModelViewport = require(script.Parent.Parent.Widgets.ModelViewport)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PackCard = require(script.PackCard)
-- Owner R122 purchase-focus hygiene: the opening-press guard, BUY tags and the heading landings.
local PurchaseGuard = require(script.Parent.Parent.PurchaseGuard)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RewardPreview = require(script.Parent.DailyRewards.RewardPreview)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local ShopCard = require(script.ShopCard)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ShopLayout = require(script.ShopLayout)
local ShopLogic = require(script.ShopLogic)
local ShopModels = require(script.ShopModels)
local ShopText = require(script.ShopText)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
-- R57 worlds: unlock / kill switch / current world (display only) and the shared world styles.
local WorldClient = require(script.Parent.Parent.Parent.Worlds.WorldClient)
local WorldClientConfig = require(ReplicatedStorage.Shared.Config.WorldClientConfig)
local WorldClientLogic = require(script.Parent.Parent.Parent.Worlds.WorldClientLogic)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local NAME = "Shop"
-- Purchase prompt source (PurchasePromptConfig.Sources) and offer-impression surface.
local PROMPT_SOURCE = "shop"
local OFFER_SOURCE = "shop"
-- Vertical gap between section labels / pack cards / grids, and the section label size.
local LIST_GAP = 14
local SECTION_LABEL_SIZE = 44
-- StudUI.sectionLabel's height for SECTION_LABEL_SIZE.
local SECTION_LABEL_HEIGHT = SECTION_LABEL_SIZE + 10
-- Pack cards are this much narrower than the content (room for their outline).
local PACK_INSET = 8
-- Longest string accepted from onOpen args (keys / section ids / sources are short).
local MAX_ARG_LENGTH = 32
-- Frames to wait for the first layout pass before giving up on a scroll request.
local MAX_LAYOUT_WAITS = 10
-- Relayout anchor (topAnchor): an entry cut by the top edge with less than this share of the
-- visible height left is a sliver (padding / gap above the section the view sits on).
local ANCHOR_SLIVER = 0.25
-- A requested scroll is applied again once the pop-in (0.24 s) and any cursor-follow tween
-- (0.16 s) are over, so neither can leave it off by their scaling / easing.
local SCROLL_SETTLE_SECONDS = 0.3
-- A card counts as seen once this fraction of it is inside the visible area.
local SEEN_FRACTION = 0.5

-- R57 world section header (the world's tab look on a stud pill), design px: as tall as a world
-- tab button (>= 44 pt everywhere), at most this wide, its icon and its label's max text size.
local WORLD_HEADER_HEIGHT = WorldClientConfig.TabHeight
local WORLD_HEADER_MAX_WIDTH = 460
local WORLD_HEADER_ICON = 56
local WORLD_HEADER_TEXT = 40
-- Gap between the pill's left edge and its icon (and, mirrored, the label's right margin).
local WORLD_HEADER_PAD = 8

-- Icons of the pack item tiles, in ShopConfig.<Pack>.lines order (cash, gems, spins, 2x cash, pet).
local PACK_ICONS = { "Cash", "Gems", "Spins", "x2Cash", "Pets" }
-- Which pack line shows the live cash preview.
local PACK_CASH_LINE = 1

type PackLook = {
	title: string,
	color: StudUI.ColorName,
	sunburst: boolean,
	limited: boolean,
	rare: boolean, -- every item tile glints (owner R98); pet tiles glint on every pack
	contents: { reward: any, lines: { string } },
}

-- The two big limited-time cards, by product kind.
local PACK_LOOKS: { [string]: PackLook } = {
	StarterPack = {
		title = "STARTER PACK",
		color = "red",
		sunburst = true,
		limited = false,
		rare = false,
		contents = ShopConfig.StarterPack :: any,
	},
	SecretPack = {
		title = "SECRET PACK",
		color = "white",
		sunburst = false,
		limited = true,
		rare = true,
		contents = ShopConfig.SecretPack :: any,
	},
}

-- One product card (grid or pack) and how to re-apply its status.
type ProductEntry = {
	def: MonetizationConfig.ProductDef,
	setStatus: (status: ShopLogic.Status) -> (),
}

-- A pack with a cash preview line.
type PackEntry = {
	key: string, -- product key ("StarterPack" | "SecretPack")
	look: PackLook,
	pack: PackCard.Pack,
}

-- A card whose impression is reported once per visit.
type OfferFrame = { key: string, frame: GuiObject }

-- One entry of the content list, in display order (heights are recomputed on re-layout).
-- (pack set: a pack card; grid set: a card grid; neither: a section label / world header)
-- Entries whose frame is not Visible (a hidden world section) take no space.
type ListItem = {
	frame: GuiObject,
	pack: PackCard.Pack?,
	grid: UIGridLayout?,
	count: number, -- grid cells (world grids: the cards shown now)
	height: number?, -- fixed height of a header (nil: SECTION_LABEL_HEIGHT)
}

-- One gamepad navigation block: a pack (one button) or a grid of buttons (empty = skipped).
type NavBlock = { cells: { GuiObject }, grid: boolean }

-- One section for LB / RB: its heading (label or world header) and its buttons in display
-- order. Hidden sections (a world not unlocked yet) are skipped by LB / RB and open args.
-- `landing` (owner R122) = the section's non-buy gamepad stop (PurchaseGuard.landing): the
-- section label, or the world header's stud pill. Opens put the cursor here, never on a BUY.
type SectionEntry = { id: string, label: GuiObject, landing: GuiObject, keys: { string }, hidden: boolean }

-- A built world-section card and what its visibility toggles.
type WorldItem = { def: MonetizationConfig.ProductDef, frame: GuiObject, button: GuiObject }

-- A world product card with its live currency preview (Bones).
type WorldCard = {
	def: MonetizationConfig.ProductDef,
	card: ShopCard.Card,
	currency: WorldsConfig.CurrencyDef?,
}

-- One R57 world section (ShopConfig.WorldSections): its fixed list slots (header + grid, built
-- hidden at build time so the display order never shifts) and its lazily-built cards.
type WorldSectionState = {
	config: ShopConfig.WorldSection,
	color: StudUI.ColorName,
	header: Frame, -- full-width holder (the list item)
	pill: Frame, -- the stud tab pill inside it (width set per layout plan)
	grid: Frame,
	listGrid: ListItem,
	navBlock: NavBlock,
	section: SectionEntry,
	items: { WorldItem },
	built: boolean,
}

-- A string arg of sane length, else nil (onOpen args come from other client code).
local function shortString(value: unknown): string?
	if type(value) == "string" and #value >= 1 and #value <= MAX_ARG_LENGTH then
		return value
	end
	return nil
end

--[[
	Fires a developer product prompt intent (the server validates everything). Owner R122: only
	when PurchaseGuard allows it — the press that OPENED the Shop (a HUD tap, a gamepad A released
	over a card) can never also buy, and nothing buys in the first ArmSeconds of a visit.
	Example: promptProduct("CashLarge")
]]
local function promptProduct(key: string)
	if not PurchaseGuard.allow(NAME) then
		return
	end
	Remotes.event("PromptProduct"):FireServer(key, PROMPT_SOURCE)
end

--[[
	Fires a game pass prompt intent (the server validates everything); guarded like promptProduct.
	Example: promptPass("VIP")
]]
local function promptPass(key: string)
	if not PurchaseGuard.allow(NAME) then
		return
	end
	Remotes.event("PromptPass"):FireServer(key, PROMPT_SOURCE)
end

--[[
	A boost expiry from an untrusted table value: a finite number, else nil.
	Example: finiteNumber(profile.boosts.cash2x)
]]
local function finiteNumber(value: unknown): number?
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return nil
end

--[[
	The ShopLayout input for `gui` right now (the same numbers ModalShell fits with).
	Example: ShopLayout.plan(layoutInput(gui))
]]
local function layoutInput(gui: ScreenGui): ShopLayout.Input
	local canvas = ScreenManager.canvasSize(gui)
	local touch = ScreenManager.touchTargets()
	return {
		canvas = canvas,
		usableY = math.max(1, canvas.Y - ScreenManager.safeTop(0)),
		margin = if touch then TouchUIConfig.Modal.TouchMargin else TouchUIConfig.Modal.DesktopMargin,
		minFit = TouchUIConfig.Modal.MinFit,
		pointScale = ScreenManager.pointScale(),
		touch = touch,
	}
end

--[[
	Builds the Shop (first open): window + ModalShell, every card, the event wiring.
	@param gui the screen's ScreenGui (ScreenManager)
	@return ScreenHandle
]]
local function build(gui: ScreenGui): ScreenManager.ScreenHandle
	local window = StudUI.window({
		title = "Shop",
		color = "yellow",
		icon = "Shop",
		size = ShopLayout.DesktopSize,
		scroll = true,
		name = "ShopWindow",
		onClose = function()
			ScreenManager.close(NAME)
		end,
	})
	assert(window.body:IsA("ScrollingFrame"), "Shop needs a scrolling window body")
	local body = window.body :: ScrollingFrame
	-- The canvas is sized explicitly from the plan (the content frame carries its own UIScale).
	body.AutomaticCanvasSize = Enum.AutomaticSize.None
	local shellSize = ShopLayout.DesktopSize
	local shell = ModalShell.new(gui, window.frame, shellSize)

	-- Everything scrolls inside one content frame whose UIScale keeps text / taps readable.
	local contentScale = Create.new("UIScale", { Name = "ContentScale", Scale = 1 }) :: UIScale
	local content = Create.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		Parent = body,
		Children = {
			contentScale,
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, LIST_GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame

	-- ── State ────────────────────────────────────────────────────────────────────────────────
	local isOpen = false
	-- Keys granted this session (PurchaseGranted is durable server truth; the profile push that
	-- records it may land a moment later).
	local granted: { [string]: boolean } = {}
	local products: { ProductEntry } = {}
	local passCards: { [string]: ShopCard.Card } = {}
	local allCards: { ShopCard.Card } = {}
	local cashCards: { { def: MonetizationConfig.ProductDef, card: ShopCard.Card } } = {}
	local boostCards: { { def: MonetizationConfig.ProductDef, card: ShopCard.Card } } = {}
	local packs: { PackEntry } = {}
	local secretPack: PackCard.Pack? = nil
	local listItems: { ListItem } = {}
	local navBlocks: { NavBlock } = {}
	local sections: { SectionEntry } = {}
	local sectionIndex: { [string]: number } = {}
	local sectionOfKey: { [string]: string } = {}
	local cardOfKey: { [string]: GuiObject } = {}
	local buttonOfKey: { [string]: GuiObject } = {}
	local keyOfButton: { [GuiObject]: string } = {}
	local orderedKeys: { string } = {}
	local offerFrames: { OfferFrame } = {}
	-- The status each card shows now (default selection + impressions use it).
	local statusOfKey: { [string]: ShopLogic.Status } = {}
	local focusButton: GuiObject? = nil
	local plan: ShopLayout.Plan? = nil
	-- R57 world sections: their state (display order), the world product cards (live Bones
	-- previews), the card keys hidden right now (locked world / bought bundle) and the
	-- open-only world signal connections.
	local worldStates: { WorldSectionState } = {}
	local worldCards: { WorldCard } = {}
	local hiddenKeys: { [string]: boolean } = {}
	local worldConnections: { Signal.Connection } = {}
	-- Owner R98: every card's item animation group (switched with open / close) and the running
	-- seed that staggers the grid cards against each other.
	local itemFx: { ItemFx.Group } = {}
	local fxSeed = 0

	-- Next animation seed for a grid card (packs use their list LayoutOrder).
	local function nextSeed(): number
		fxSeed += 1
		return fxSeed
	end

	local order = 0
	-- Next LayoutOrder in the content list.
	local function nextOrder(): number
		order += 1
		return order
	end

	-- Remembers a card for focus / scroll / impressions / LB-RB. Every Shop card button is a Robux
	-- BUY (owner R122: tagged, so no default selection ever lands on one).
	local function registerCard(key: string, section: SectionEntry, frame: GuiObject, button: GuiObject)
		PurchaseGuard.markBuy(button)
		sectionOfKey[key] = section.id
		cardOfKey[key] = frame
		buttonOfKey[key] = button
		keyOfButton[button] = key
		table.insert(section.keys, key)
		table.insert(orderedKeys, key)
		table.insert(offerFrames, { key = key, frame = frame })
	end

	-- ── Card builders ────────────────────────────────────────────────────────────────────────

	-- True when the packs' spins tile shows gems (paid random items restricted / not known yet).
	local function spinsAsGems(profile: { [string]: any }?): boolean
		return EggConfig.policyState(if profile ~= nil then profile.policy else nil) ~= "allowed"
	end

	-- One big limited-time pack card (Starter / Secret).
	local function buildPack(def: MonetizationConfig.ProductDef, look: PackLook, section: SectionEntry)
		local pack = PackCard.new({
			key = def.key,
			title = look.title,
			color = look.color,
			sunburst = look.sunburst,
			lines = look.contents.lines,
			icons = PACK_ICONS,
			-- The tiles' 3D models (the spins tile already as gems where that is what is paid).
			models = ShopModels.packItems(def.key, look.contents :: any, spinsAsGems(ClientState.profile)),
			cashLine = PACK_CASH_LINE,
			price = def.price,
			limited = look.limited,
			rare = look.rare,
			layoutOrder = nextOrder(),
			parent = content,
			onBuy = function()
				promptProduct(def.key)
			end,
		})
		table.insert(products, { def = def, setStatus = pack.setStatus })
		table.insert(packs, { key = def.key, look = look, pack = pack })
		table.insert(itemFx, pack.fx)
		if look.limited then
			secretPack = pack
		end
		table.insert(listItems, { frame = pack.frame, pack = pack, count = 1 })
		table.insert(navBlocks, { cells = { pack.button.instance :: GuiObject }, grid = false })
		registerCard(def.key, section, pack.frame, pack.button.instance)
	end

	--[[
		One grid card for a developer product.
		@param def     product definition (MonetizationConfig)
		@param color   the section's card colour
		@param grid    the section's grid holder
		@param index   LayoutOrder inside the grid
		@param section the section entry (focus / LB-RB / impressions)
		@param icon    optional IconAssets key that wins over the product's own (R57 world rows:
		               ShopConfig.WorldSections[..].items[..].icon); unknown keys fall back
		@return the card (its button is the gamepad cell)
	]]
	local function buildProductCard(
		def: MonetizationConfig.ProductDef,
		color: StudUI.ColorName,
		grid: Instance,
		index: number,
		section: SectionEntry,
		icon: string?
	): ShopCard.Card
		local isBoost = def.kind == "Boost" or def.kind == "ServerBoost"
		local card = ShopCard.new({
			key = def.key,
			name = def.name,
			icon = if icon ~= nil then ShopLogic.iconFor(icon, def.icon) else ShopLogic.iconFor(def.key, def.icon),
			model = ShopModels.forProduct(def),
			price = def.price,
			lines = { def.description },
			badge = def.badge,
			color = color,
			countdown = isBoost,
			seed = nextSeed(),
			layoutOrder = index,
			parent = grid,
			onBuy = function()
				promptProduct(def.key)
			end,
		})
		-- Static previews come straight from the catalogue (the amounts the server grants).
		if def.kind == "Gems" and def.gems ~= nil then
			card.setPreview(`+{NumberFormat.commas(def.gems)} Gems`, UIStyleConfig.Neutral.GemPurple)
		elseif def.kind == "Spins" and def.spins ~= nil then
			card.setPreview(`+{def.spins} Spin{if def.spins == 1 then "" else "s"}`, UIStyleConfig.Neutral.Text)
		elseif def.kind == "Cash" then
			table.insert(cashCards, { def = def, card = card })
		elseif (def.kind == "WorldCash" or def.kind == "WorldStarter") and def.world ~= nil then
			-- R57: a live preview in that world's currency ("4.5M Bones"), like the Cash packs.
			local world = WorldsConfig.get(def.world)
			table.insert(worldCards, {
				def = def,
				card = card,
				currency = if world ~= nil then world.currency else nil,
			})
		end
		if isBoost then
			table.insert(boostCards, { def = def, card = card })
		end
		table.insert(products, { def = def, setStatus = card.setStatus })
		table.insert(allCards, card)
		table.insert(itemFx, card.fx)
		registerCard(def.key, section, card.frame, card.button.instance)
		return card
	end

	-- One grid card for a game pass (first two perks under the name).
	local function buildPassCard(
		def: MonetizationConfig.PassDef,
		grid: Instance,
		index: number,
		section: SectionEntry
	): GuiObject
		local perks: { string } = {}
		for perkIndex = 1, math.min(2, #def.perks) do
			table.insert(perks, def.perks[perkIndex])
		end
		local card = ShopCard.new({
			key = def.key,
			name = def.name,
			icon = ShopLogic.iconFor(def.key, def.icon),
			model = ShopModels.forPass(def),
			price = def.price,
			lines = perks,
			color = "purple",
			seed = nextSeed(),
			layoutOrder = index,
			parent = grid,
			onBuy = function()
				promptPass(def.key)
			end,
		})
		passCards[def.key] = card
		table.insert(allCards, card)
		table.insert(itemFx, card.fx)
		registerCard(def.key, section, card.frame, card.button.instance)
		return card.button.instance
	end

	-- A transparent grid holder (sized by the layout plan; explicit heights, no AutomaticSize
	-- feedback with the stud surfaces inside).
	local function buildGrid(sectionId: string, count: number): (Frame, UIGridLayout)
		local layout = Create.new("UIGridLayout", {
			CellSize = UDim2.fromOffset(ShopCard.Width, ShopCard.Height),
			CellPadding = UDim2.fromOffset(ShopCard.Gap, ShopCard.Gap),
			FillDirection = Enum.FillDirection.Horizontal,
			FillDirectionMaxCells = 4,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}) :: UIGridLayout
		local frame = Create.new("Frame", {
			Name = `Grid_{sectionId}`,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, ShopCard.Height),
			LayoutOrder = nextOrder(),
			Parent = content,
			Children = { layout },
		}) :: Frame
		table.insert(listItems, { frame = frame, grid = layout, count = count })
		return frame, layout
	end

	--[[
		R57: a world section's heading in the world's TAB look (WorldClientConfig.Tabs[world]):
		a centred stud pill in the tab colour with the world icon at its left and the tab label
		centred ("DINO VALLEY"). Decorative only (nothing Selectable). Built hidden; the pill's
		width follows the layout plan (applyPlan) so it never overflows a narrow phone list.
		@param sectionId ShopConfig world section id (names the instances)
		@param style     the world's tab style (WorldClientLogic.style)
		@param color     the pill colour (the tab colour as a StudUI preset)
		@return (holder: the full-width list item, pill: the stud pill)
	]]
	local function buildWorldHeader(
		sectionId: string,
		style: WorldClientConfig.TabStyle,
		color: StudUI.ColorName
	): (Frame, Frame)
		local holder = Create.new("Frame", {
			Name = `WorldHeader_{sectionId}`,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, WORLD_HEADER_HEIGHT),
			LayoutOrder = nextOrder(),
			Visible = false,
			Parent = content,
		}) :: Frame
		local pill = StudUI.card({
			color = color,
			name = "WorldTab",
			size = UDim2.new(0, WORLD_HEADER_MAX_WIDTH, 1, 0),
			position = UDim2.fromScale(0.5, 0),
			anchor = Vector2.new(0.5, 0),
			parent = holder,
		})
		local icon = StudUI.icon(style.icon, WORLD_HEADER_ICON, 3)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0, WORLD_HEADER_PAD, 0.5, 0)
		icon.Parent = pill.content
		-- The label spans the pill minus the icon lane on BOTH sides, so the text sits centred
		-- in the pill (tab look); it shrinks (never below the cards' readability floor) when
		-- the pill is narrow. Offset height so Shop/ShopText keeps its limits per scale.
		local inset = WORLD_HEADER_ICON + 2 * WORLD_HEADER_PAD
		local label = StudUI.text({
			name = "Label",
			text = style.label,
			textSize = WORLD_HEADER_TEXT,
			scaled = true,
			size = UDim2.new(1, -2 * inset, 0, WORLD_HEADER_TEXT + 8),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
			zIndex = 3,
			parent = pill.content,
		})
		local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
		if constraint ~= nil then
			constraint.MinTextSize = ShopCard.MinTextSize
		end
		return holder, pill.frame
	end

	--[[
		R57: reserves a world section's place in the list (ShopConfig.WorldSections row): its tab
		header, an empty hidden grid, a gamepad block and a (hidden) LB / RB section, all in display
		order. The cards themselves are built lazily by ensureWorldCards the first time the world
		is open for the player.
		@param config the world section row
	]]
	local function reserveWorldSection(config: ShopConfig.WorldSection)
		local style = WorldClientLogic.style(config.world)
		local color = ShopLogic.colorName(style.color, "green")
		local header, pill = buildWorldHeader(config.id, style, color)
		table.insert(listItems, { frame = header, count = 0, height = WORLD_HEADER_HEIGHT })
		-- R122: the stud pill is the world section's gamepad landing (the cursor's start on an open
		-- that targets this section; Down enters its cards).
		local section: SectionEntry =
			{ id = config.id, label = header, landing = PurchaseGuard.landing(pill), keys = {}, hidden = true }
		table.insert(sections, section)
		sectionIndex[config.id] = #sections
		local grid = buildGrid(config.id, 0)
		grid.Visible = false
		local navBlock: NavBlock = { cells = {}, grid = true }
		table.insert(navBlocks, navBlock)
		local state: WorldSectionState = {
			config = config,
			color = color,
			header = header,
			pill = pill,
			grid = grid,
			listGrid = listItems[#listItems],
			navBlock = navBlock,
			section = section,
			items = {},
			built = false,
		}
		table.insert(worldStates, state)
	end

	-- The world sections that follow `sectionId` (ShopConfig.WorldSections `after`).
	local function reserveWorldSectionsAfter(sectionId: string)
		for _, config in ShopConfig.WorldSections do
			if config.after == sectionId then
				reserveWorldSection(config)
			end
		end
	end

	-- ── Build every section once ─────────────────────────────────────────────────────────────
	local knownSectionIds: { [string]: boolean } = {}
	for _, config in ShopConfig.Sections do
		knownSectionIds[config.id] = true
		local label = StudUI.sectionLabel(ShopLogic.cleanTitle(config.title), SECTION_LABEL_SIZE)
		label.LayoutOrder = nextOrder()
		label.Parent = content
		table.insert(listItems, { frame = label, count = 0 })
		-- R122: the label is the section's gamepad landing (never a BUY button on open).
		local section: SectionEntry =
			{ id = config.id, label = label, landing = PurchaseGuard.landing(label), keys = {}, hidden = false }
		table.insert(sections, section)
		sectionIndex[config.id] = #sections
		local color = ShopLogic.colorName(config.color, "sky")
		-- Packs render as big cards in place; everything else goes into the section's grid.
		local gridItems: { ShopConfig.ItemRef } = {}
		for _, item in config.items do
			if item.kind == "product" then
				local def = MonetizationConfig.getProduct(item.key)
				local look = if def ~= nil then PACK_LOOKS[def.kind] else nil
				if def ~= nil and look ~= nil then
					buildPack(def, look, section)
				elseif def ~= nil then
					table.insert(gridItems, item)
				end
			elseif MonetizationConfig.getPass(item.key) ~= nil then
				table.insert(gridItems, item)
			end
		end
		if #gridItems > 0 then
			local grid = buildGrid(config.id, #gridItems)
			local cells: { GuiObject } = {}
			for index, item in gridItems do
				if item.kind == "product" then
					local def = MonetizationConfig.getProduct(item.key)
					if def ~= nil then
						local card = buildProductCard(def, color, grid, index, section)
						table.insert(cells, card.button.instance :: GuiObject)
					end
				else
					local def = MonetizationConfig.getPass(item.key)
					if def ~= nil then
						table.insert(cells, buildPassCard(def, grid, index, section))
					end
				end
			end
			table.insert(navBlocks, { cells = cells, grid = true })
		end
		if #section.keys == 0 then
			-- A section with nothing to buy is not a LB / RB stop.
			table.remove(sections)
			sectionIndex[config.id] = nil
		end
		-- R57 world sections anchored after this one (hidden until their world opens).
		reserveWorldSectionsAfter(config.id)
	end
	-- World sections whose anchor is not a known section go last (a config typo never hides one).
	for _, config in ShopConfig.WorldSections do
		if not knownSectionIds[config.after] then
			reserveWorldSection(config)
		end
	end

	-- ── Readable auto-sized text at every scale (Shop/ShopText) ─────────────────────────────
	-- Every TextScaled label's size limits follow its real on-screen scale, re-applied once a
	-- layout change has settled (the pop-in / cursor tweens are over), never per frame.
	local textConstraints: { UITextSizeConstraint } = {}
	ShopText.collect(content, textConstraints)
	local textToken = 0
	local function scheduleTextScale()
		textToken += 1
		local token = textToken
		task.delay(SCROLL_SETTLE_SECONDS, function()
			if token == textToken and isOpen then
				ShopText.apply(textConstraints)
			end
		end)
	end
	content:GetPropertyChangedSignal("AbsoluteSize"):Connect(scheduleTextScale)

	-- ── Gamepad navigation ───────────────────────────────────────────────────────────────────

	--[[
		Links every block's buttons (packs: one column; grids: the plan's columns) and chains the
		blocks top to bottom: up from a block's first row goes to the previous block's last row,
		down from its last row to the next block's first cell. Re-run when the columns change and
		when a world section / card appears or disappears (empty blocks are skipped, so a hidden
		world section is never a dead end).
	]]
	local function linkNavigation(columns: number)
		local active: { NavBlock } = {}
		for _, block in navBlocks do
			if #block.cells > 0 then
				table.insert(active, block)
			end
		end
		for index, block in active do
			local cols = if block.grid then columns else 1
			local up: GuiObject? = nil
			local previous = active[index - 1]
			if previous ~= nil then
				local previousCols = if previous.grid then columns else 1
				local rows = math.ceil(#previous.cells / previousCols)
				up = previous.cells[(rows - 1) * previousCols + 1]
			end
			local following = active[index + 1]
			GamepadNav.linkGrid(block.cells, cols, {
				up = up,
				down = if following ~= nil then following.cells[1] else nil,
			})
		end
	end
	GamepadNav.followScroll(body)

	-- ── Responsive layout (Shop/ShopLayout) ──────────────────────────────────────────────────

	--[[
		Applies a layout plan: window size (a new ModalShell when it changes), content scale,
		card layout, grid cells / columns, pack + world header widths, list + canvas heights,
		gamepad links. Hidden list entries (a world section not open yet) take no space, exactly
		like UIListLayout skips them.
		@param newPlan the plan (ShopLayout.plan)
		@param relink  true: re-link gamepad navigation even when the columns did not change (a
		               world section / card appeared or disappeared)
	]]
	local function applyPlan(newPlan: ShopLayout.Plan, relink: boolean?)
		local previous = plan
		plan = newPlan
		if newPlan.windowSize ~= shellSize then
			-- A new shell for the new design size re-parents the window; the old one is dropped.
			local old = shell
			shell = ModalShell.new(gui, window.frame, newPlan.windowSize)
			shellSize = newPlan.windowSize
			old.Destroy()
		end
		contentScale.Scale = newPlan.scale
		if previous == nil or previous.cardLayout ~= newPlan.cardLayout then
			for _, card in allCards do
				card.setLayout(newPlan.cardLayout)
			end
		end
		-- World tab pills: their max width, never wider than the content (narrow phones).
		local pillWidth = math.max(1, math.min(WORLD_HEADER_MAX_WIDTH, newPlan.contentWidth - PACK_INSET))
		for _, state in worldStates do
			state.pill.Size = UDim2.new(0, pillWidth, 1, 0)
		end
		local cell = newPlan.cellSize
		local total = 0
		local first = true
		for _, item in listItems do
			if not item.frame.Visible then
				continue
			end
			local height = item.height or SECTION_LABEL_HEIGHT
			local pack = item.pack
			local grid = item.grid
			if pack ~= nil then
				height = pack.setWidth(newPlan.contentWidth - PACK_INSET)
			elseif grid ~= nil then
				local rows = math.max(1, math.ceil(item.count / newPlan.columns))
				height = rows * cell.Y + (rows - 1) * ShopCard.Gap
				grid.CellSize = UDim2.fromOffset(cell.X, cell.Y)
				grid.FillDirectionMaxCells = newPlan.columns
				item.frame.Size = UDim2.new(1, 0, 0, height)
			end
			total += height + (if first then 0 else LIST_GAP)
			first = false
		end
		-- The content is `scale` times larger on screen: its width shrinks by 1 / scale so it
		-- still spans the body, and the canvas holds its scaled height + the body padding.
		content.Size = UDim2.new(1 / newPlan.scale, 0, 0, total)
		local padding = UIStyleConfig.Window.BodyPadding
		body.CanvasSize = UDim2.fromOffset(0, math.ceil(total * newPlan.scale + 2 * padding))
		if relink == true or previous == nil or previous.columns ~= newPlan.columns then
			linkNavigation(newPlan.columns)
		end
	end

	--[[
		The list entry at the top of the visible area (+ how far into it the view starts, as a
		share of its height), or nil when the shop is closed / not laid out. A relayout (phone
		rotation, device / Touch-mode change, a new shell) rescales the content and would leave
		the view somewhere else; keepAnchor puts the same entry back at the top afterwards
		(owner R11: rotating a phone never loses the player's place).
	]]
	local function topAnchor(): (GuiObject?, number)
		if not isOpen or body.AbsoluteWindowSize.Y <= 0 then
			return nil, 0
		end
		-- The entry cut by the top edge ("under") and the first entry starting below it ("below").
		-- When only a sliver of "under" remains (the padding / gap above a section the view was
		-- scrolled to), the section below is the real anchor.
		local viewTop = body.AbsolutePosition.Y
		local under: GuiObject? = nil
		local below: GuiObject? = nil
		local belowTop = math.huge
		for _, item in listItems do
			local frame = item.frame
			if frame.Visible and frame.AbsoluteSize.Y > 0 then
				local top = frame.AbsolutePosition.Y
				if top < viewTop - 1 and top + frame.AbsoluteSize.Y > viewTop then
					under = frame
				elseif top >= viewTop - 1 and top < belowTop then
					below = frame
					belowTop = top
				end
			end
		end
		local best = under
		if
			best ~= nil
			and below ~= nil
			and best.AbsolutePosition.Y + best.AbsoluteSize.Y - viewTop < body.AbsoluteWindowSize.Y * ANCHOR_SLIVER
		then
			best = nil
		end
		if best == nil then
			return below, 0
		end
		local share = (viewTop - best.AbsolutePosition.Y) / math.max(1, best.AbsoluteSize.Y)
		return best, math.clamp(share, 0, 1)
	end

	-- Scrolls so `anchor` (+ `share` of its height) is at the top again, once the new layout
	-- measured (next Heartbeat; bounded retries while the gui is still sizing).
	local function keepAnchor(anchor: GuiObject, share: number)
		local tries = 0
		local function apply()
			if not isOpen then
				return
			end
			local canvasHeight = body.AbsoluteCanvasSize.Y
			local windowHeight = body.AbsoluteWindowSize.Y
			if canvasHeight <= 0 or windowHeight <= 0 or anchor.AbsoluteSize.Y <= 0 then
				tries += 1
				if tries <= MAX_LAYOUT_WAITS then
					RunService.Heartbeat:Once(apply)
				end
				return
			end
			local wanted = anchor.AbsolutePosition.Y - content.AbsolutePosition.Y + share * anchor.AbsoluteSize.Y
			body.CanvasPosition = Vector2.new(0, math.clamp(wanted, 0, math.max(0, canvasHeight - windowHeight)))
		end
		RunService.Heartbeat:Once(apply)
	end

	-- Re-plans for the current screen; applies only when something changed (keeping the view on
	-- the same list entry while open).
	local function relayout()
		local newPlan = ShopLayout.plan(layoutInput(gui))
		if not ShopLayout.same(plan, newPlan) then
			local anchor, share = topAnchor()
			applyPlan(newPlan)
			if anchor ~= nil then
				keepAnchor(anchor, share)
			end
			-- Card layouts (tall / wide) resize labels without resizing the content frame.
			scheduleTextScale()
		end
	end
	-- First plan at build (a disabled gui measures from another enabled ScreenGui).
	relayout()
	-- Device / viewport / top bar / Touch-mode changes, and the gui's real size after enabling.
	ScreenManager.LayoutChanged:Connect(relayout)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if gui.Enabled then
			relayout()
		end
	end)

	-- ── Refreshers (each touches only its own cards) ─────────────────────────────────────────

	-- Everything a status check needs, read now.
	local function context(): ShopLogic.Context
		return {
			profile = ClientState.profile,
			granted = granted,
			now = Workspace:GetServerTimeNow(),
			stock = ShopLogic.readStock(),
		}
	end

	-- The packs' spins tile: "5 Lucky Spins" where paid random items are allowed, else the fixed
	-- gem equivalent the server pays instead (restricted OR still unknown — the receipt rule).
	local function refreshPackItems(profile: { [string]: any }?)
		local asGems = spinsAsGems(profile)
		for _, entry in packs do
			local contents = entry.look.contents :: any
			local line = contents.spinLine
			if type(line) == "number" then
				local lines = ShopConfig.packLines(contents, asGems)
				local models = ShopModels.packItems(entry.key, contents, asGems)
				entry.pack.setItem(
					line,
					lines[line],
					if asGems then "Gems" else PACK_ICONS[line] or "Spins",
					models[line]
				)
			end
		end
	end

	-- Buy / OWNED / SOON / SOLD OUT / UNAVAILABLE of every product card + the stock line.
	local function refreshProducts(ctx: ShopLogic.Context)
		refreshPackItems(ctx.profile)
		for _, entry in products do
			local status = ShopLogic.productStatus(entry.def, ctx)
			statusOfKey[entry.def.key] = status
			entry.setStatus(status)
		end
		local secret = secretPack
		if secret ~= nil then
			secret.setStock(ShopLogic.stockText(ctx.stock))
		end
	end

	-- Buy / OWNED / SOON of every pass card.
	local function refreshPasses(ctx: ShopLogic.Context)
		for key, card in passCards do
			local status = ShopLogic.passStatus(key, ctx)
			statusOfKey[key] = status
			card.setStatus(status)
		end
	end

	-- Cash previews (cash packs + the packs' cash tile): the server's own rule, max(floor,
	-- seconds x income), so the number matches the grant.
	local function refreshCash(profile: { [string]: any }?)
		for _, entry in cashCards do
			local amount = RewardPreview.cash({
				cashSeconds = entry.def.incomeSeconds,
				cashFloor = entry.def.cashFloor,
			}, profile)
			entry.card.setPreview(
				if amount > 0 then NumberFormat.money(amount) else nil,
				UIStyleConfig.Neutral.CashGreen
			)
		end
		for _, entry in packs do
			local amount = RewardPreview.cash(entry.look.contents.reward, profile)
			entry.pack.setCashPreview(if amount > 0 then NumberFormat.money(amount) else nil)
		end
	end

	--[[
		R57 world product previews ("4.5M Bones"): the server's grant rule, max(floor, seconds x
		that world's idle income) read from the snapshot (ShopLogic.worldCashAmount), formatted
		in the world's currency (WorldClientLogic.formatAmount) and tinted its colour. Display
		only; cards not built yet (world locked) are simply not in the list.
	]]
	local function refreshWorldCash(profile: { [string]: any }?)
		for _, entry in worldCards do
			local currency = entry.currency
			local amount = ShopLogic.worldCashAmount(entry.def, profile)
			if currency ~= nil and amount > 0 then
				entry.card.setPreview(WorldClientLogic.formatAmount(currency, amount), currency.color)
			else
				entry.card.setPreview(nil)
			end
		end
	end

	-- R57: Buy / OWNED / SOON of the world product cards only (the targeted world pass).
	local function refreshWorldStatus(ctx: ShopLogic.Context)
		for _, entry in worldCards do
			local status = ShopLogic.productStatus(entry.def, ctx)
			statusOfKey[entry.def.key] = status
			entry.card.setStatus(status)
		end
	end

	-- "ACTIVE 12:34" on boost cards: personal boosts from profile.boosts, the server boost from
	-- the ReplicatedStorage attribute.
	local function refreshBoosts(profile: { [string]: any }?, now: number)
		local boosts: { [string]: number } = if profile ~= nil and type(profile.boosts) == "table"
			then profile.boosts :: any
			else {}
		for _, entry in boostCards do
			local endsAt: number? = nil
			if entry.def.kind == "Boost" and entry.def.boostKey ~= nil then
				local key = entry.def.boostKey :: string
				if BoostConfig.secondsLeft(boosts, key, now) > 0 then
					endsAt = finiteNumber(boosts[key])
				end
			elseif entry.def.kind == "ServerBoost" then
				local serverEnds = finiteNumber(ReplicatedStorage:GetAttribute(BoostConfig.Server.EndsAtAttribute))
				if serverEnds ~= nil and serverEnds > now then
					endsAt = serverEnds
				end
			end
			entry.card.setActiveUntil(endsAt)
		end
	end

	-- Every card (on open / after a full snapshot).
	local function refreshAll()
		local ctx = context()
		refreshProducts(ctx)
		refreshPasses(ctx)
		refreshCash(ctx.profile)
		refreshWorldCash(ctx.profile)
		refreshBoosts(ctx.profile, ctx.now)
	end

	-- ── Live updates (ignored while closed: opening refreshes everything) ────────────────────

	-- R57: the world pass (visibility + statuses + Bones previews of the world sections). It is
	-- assigned further down (it needs the selection helpers; a no-op until then). Every trigger
	-- goes through the coalescing queue below, so a "worlds" push (ProfileChanged AND
	-- WorldClient.StateChanged for the same snapshot) runs it once, on the next resumption cycle.
	local worldPass: () -> () = function() end
	local worldQueued = false
	local function queueWorldRefresh()
		if not isOpen or worldQueued then
			return
		end
		worldQueued = true
		task.defer(function()
			worldQueued = false
			if isOpen then
				worldPass()
			end
		end)
	end

	ClientState.ProfileChanged:Connect(function(profile: ClientState.Profile, fields: { string }?)
		if not isOpen then
			return
		end
		if fields == nil then
			refreshAll()
			return
		end
		local changed: { [string]: boolean } = {}
		for _, field in fields do
			changed[field] = true
		end
		if changed.passes then
			refreshPasses(context())
		end
		if changed.starter or changed.secretPack or changed.policy then
			refreshProducts(context())
		end
		if changed.tycoon or changed.rebirths or changed.rebirthShop then
			refreshCash(profile)
		end
		if changed.boosts then
			refreshBoosts(profile, Workspace:GetServerTimeNow())
		end
	end)

	ClientState.PurchaseGranted:Connect(function(payload: ClientState.GrantPayload)
		local key = payload.key
		if payload.kind == "pass" then
			if MonetizationConfig.getPass(key) ~= nil then
				granted[key] = true
			end
			if isOpen then
				refreshPasses(context())
			end
			return
		end
		local def = MonetizationConfig.getProduct(key)
		if def == nil then
			return
		end
		if def.oneTime then
			granted[key] = true
		end
		if isOpen then
			local ctx = context()
			refreshProducts(ctx)
			if def.kind == "Boost" or def.kind == "ServerBoost" then
				refreshBoosts(ctx.profile, ctx.now)
			end
			-- R57: a bought world bundle leaves its section (and the section if it was the last).
			if def.world ~= nil then
				queueWorldRefresh()
			end
		end
	end)

	-- Stock attributes arrive in bursts of three (sold / limit / at): coalesce to one pass.
	local stockQueued = false
	local function onStockChanged()
		if not isOpen or stockQueued then
			return
		end
		stockQueued = true
		task.defer(function()
			stockQueued = false
			if isOpen then
				refreshProducts(context())
			end
		end)
	end
	for _, attribute in
		{ ShopConfig.Stock.SoldAttribute, ShopConfig.Stock.LimitAttribute, ShopConfig.Stock.AtAttribute }
	do
		ReplicatedStorage:GetAttributeChangedSignal(attribute):Connect(onStockChanged)
	end
	ReplicatedStorage:GetAttributeChangedSignal(BoostConfig.Server.EndsAtAttribute):Connect(function()
		if isOpen then
			refreshBoosts(ClientState.profile, Workspace:GetServerTimeNow())
		end
	end)

	-- ── Impressions (offerSeen once per card per visit, when half of it is on screen) ────────
	local reported: { [string]: boolean } = {}
	local remaining = 0
	local newVisit = false

	local function reportVisibleOffers()
		if not isOpen or remaining <= 0 then
			return
		end
		local top = body.AbsolutePosition.Y
		local bottom = top + body.AbsoluteSize.Y
		if bottom <= top then
			return -- not laid out yet
		end
		for _, offer in offerFrames do
			-- Hidden cards (locked world, bought bundle) are not on screen, whatever their stale
			-- absolute position says.
			if not reported[offer.key] and not hiddenKeys[offer.key] then
				local y0 = offer.frame.AbsolutePosition.Y
				local height = offer.frame.AbsoluteSize.Y
				-- Overlap of [y0, y0 + height] with the visible band [top, bottom].
				local inside = math.min(y0 + height, bottom) - math.max(y0, top)
				if height > 0 and inside >= height * SEEN_FRACTION then
					reported[offer.key] = true
					remaining -= 1
					-- Owned / SOON / SOLD OUT cards are not offers: seen, but not reported.
					if statusOfKey[offer.key] == "buy" then
						ClientAnalytics.offerSeen(offer.key, OFFER_SOURCE, newVisit)
						newVisit = false
					end
				end
			end
		end
	end
	body:GetPropertyChangedSignal("CanvasPosition"):Connect(reportVisibleOffers)

	-- Starts a new impression visit (fresh open).
	local function startVisit()
		table.clear(reported)
		remaining = #offerFrames
		newVisit = true
	end

	-- ── Scrolling to a section / card ────────────────────────────────────────────────────────

	--[[
		The CanvasPosition.Y (absolute px, like GamepadNav's verified follow) that puts `target`
		at the top of the visible area; when the `focus` card would then be cut off at the
		bottom, the card itself goes to the top instead. Nil before the first layout pass.
		Math: the body's top padding equals the content's top offset in the canvas, so a target
		sits at the top when CanvasPosition = target.top - content.top (scroll-independent).
	]]
	local function scrollTargetFor(target: GuiObject, focus: GuiObject?): number?
		local canvasHeight = body.AbsoluteCanvasSize.Y
		local windowHeight = body.AbsoluteWindowSize.Y
		if canvasHeight <= 0 or windowHeight <= 0 or content.AbsoluteSize.Y <= 0 then
			return nil
		end
		local contentTop = content.AbsolutePosition.Y
		local wanted = target.AbsolutePosition.Y - contentTop
		if focus ~= nil then
			-- Visible band = window minus the padding above and below.
			local padding = contentTop - body.AbsolutePosition.Y + body.CanvasPosition.Y
			local focusTop = focus.AbsolutePosition.Y - contentTop
			if focusTop + focus.AbsoluteSize.Y - wanted > windowHeight - 2 * padding then
				wanted = focusTop
			end
		end
		return math.clamp(wanted, 0, math.max(0, canvasHeight - windowHeight))
	end

	local scrollToken = 0
	--[[
		Scrolls to `target` (nil = top) once the window is laid out, and once more after the
		pop-in / cursor-follow settle (SCROLL_SETTLE_SECONDS). A newer request or closing cancels.
		@param target section label, or nil for the top of the shop
		@param focus  optional card to keep fully visible
	]]
	local function scrollTo(target: GuiObject?, focus: GuiObject?)
		scrollToken += 1
		local token = scrollToken
		local waits = 0
		local function apply(settle: boolean)
			if token ~= scrollToken or not isOpen then
				return
			end
			if target == nil then
				body.CanvasPosition = Vector2.zero
				reportVisibleOffers()
				return
			end
			local wanted = scrollTargetFor(target, focus)
			if wanted == nil then
				waits += 1
				if waits <= MAX_LAYOUT_WAITS then
					RunService.Heartbeat:Once(function()
						apply(settle)
					end)
				end
				return
			end
			body.CanvasPosition = Vector2.new(0, wanted)
			reportVisibleOffers()
			if not settle then
				task.delay(SCROLL_SETTLE_SECONDS, apply, true)
			end
		end
		task.defer(apply, false)
	end

	-- ── Selection helpers + LB / RB sections ─────────────────────────────────────────────────

	-- The first key among `keys` whose card is shown (R57: world cards can be hidden), else nil.
	local function firstShownKey(keys: { string }): string?
		for _, key in keys do
			if not hiddenKeys[key] then
				return key
			end
		end
		return nil
	end

	-- True when section `id` exists and is shown (R57: a world section can be hidden).
	local function sectionShown(id: string): boolean
		local index = sectionIndex[id]
		return index ~= nil and not sections[index].hidden
	end

	-- The first buyable shown card's button among `keys`, else the first shown card's button.
	local function preferredIn(keys: { string }): GuiObject?
		for _, key in keys do
			if statusOfKey[key] == "buy" and not hiddenKeys[key] then
				return buttonOfKey[key]
			end
		end
		local first = firstShownKey(keys)
		return if first ~= nil then buttonOfKey[first] else nil
	end

	-- The card an open aims at: the open's target, else the Starter Pack, else the first buyable
	-- card. (A target that has been hidden since — a world bundle just bought — no longer counts.)
	-- Owner R122: never selected directly on open — preferredLanding() lands on its heading.
	local function preferredButton(): GuiObject?
		local target = focusButton
		if target ~= nil then
			local key = keyOfButton[target]
			if key == nil or not hiddenKeys[key] then
				return target
			end
		end
		local starter = buttonOfKey.StarterPack
		if starter ~= nil and statusOfKey.StarterPack == "buy" then
			return starter
		end
		return preferredIn(orderedKeys)
	end

	--[[
		Owner R122 (no accidental purchase prompts; field data: 14 Starter Pack console prompts
		closed in < 2 s because the Shop opened with the cursor ON that BUY button): the gamepad
		cursor's start = the HEADING of the section holding the preferred card (PurchaseGuard
		landing), never a BUY button. Down from the heading goes straight to that card, so the
		targeted item is one deliberate press away. Falls back to the first shown section's heading.
		@return the landing, or nil when no section is shown
	]]
	local function preferredLanding(): GuiObject?
		local button = preferredButton()
		local key = if button ~= nil then keyOfButton[button] else nil
		local id = if key ~= nil then sectionOfKey[key] else nil
		local index = if id ~= nil then sectionIndex[id] else nil
		local section = if index ~= nil then sections[index] else nil
		if section ~= nil and not section.hidden then
			section.landing.NextSelectionDown = button :: any
			return section.landing
		end
		for _, entry in sections do
			if not entry.hidden then
				local first = firstShownKey(entry.keys)
				entry.landing.NextSelectionDown = (if first ~= nil then buttonOfKey[first] else nil) :: any
				return entry.landing
			end
		end
		return nil
	end

	-- The section the player is in: the selected card's, else the last shown heading at / above
	-- the top (hidden world sections never count).
	local function currentSection(): number
		local selected = GuiService.SelectedObject
		if selected ~= nil then
			local key = keyOfButton[selected]
			local id = if key ~= nil then sectionOfKey[key] else nil
			local index = if id ~= nil then sectionIndex[id] else nil
			if index ~= nil and not sections[index].hidden then
				return index
			end
			-- R122: the cursor on a section heading (landing) is in that section.
			for headingIndex, section in sections do
				if section.landing == selected and not section.hidden then
					return headingIndex
				end
			end
		end
		local top = body.AbsolutePosition.Y + body.AbsoluteSize.Y * 0.25
		local current = 1
		for index, section in sections do
			if not section.hidden and section.label.AbsolutePosition.Y <= top then
				current = index
			end
		end
		return current
	end

	--[[
		LB / RB (Q / E): jumps to the previous / next SHOWN section — scrolls its heading to the
		top (synchronously, so the cursor-follow sees the card already visible and does not fight
		it) and puts the gamepad cursor on its first buyable card. At either end it stays on the
		current section (re-aligned), exactly like the clamp it replaces; hidden world sections
		are stepped over.
	]]
	local function jumpSection(delta: number)
		if #sections == 0 then
			return
		end
		local index = currentSection()
		local step = if delta < 0 then -1 else 1
		local probe = index + step
		while sections[probe] ~= nil do
			if not sections[probe].hidden then
				index = probe
				break
			end
			probe += step
		end
		local section = sections[index]
		local button = preferredIn(section.keys)
		local firstKey = firstShownKey(section.keys)
		local card = if firstKey ~= nil then cardOfKey[firstKey] else nil
		scrollToken += 1 -- a pending open scroll must not pull the view back
		local wanted = scrollTargetFor(section.label, card)
		if wanted ~= nil then
			body.CanvasPosition = Vector2.new(0, wanted)
		end
		GamepadNav.select(button)
	end
	local sectionCycler = GamepadNav.cycler(function()
		jumpSection(-1)
	end, function()
		jumpSection(1)
	end)

	-- ── R57 world sections (lazy build, visibility, live pass) ──────────────────────────────

	-- Display order of every card key, rebuilt from the sections (lazily built world cards would
	-- otherwise land at the end and skew "the first buyable card").
	local function rebuildOrderedKeys()
		table.clear(orderedKeys)
		for _, section in sections do
			for _, key in section.keys do
				table.insert(orderedKeys, key)
			end
		end
	end

	--[[
		Builds a world section's cards ONCE, the first time its world is open for the player:
		one ShopCard per ShopConfig row whose product belongs to that world (a mis-filed row
		never shows in the wrong world), with the row's icon fallback and R39 model. New cards
		take the current card layout, join Shop/ShopText's scaled labels and this visit's
		impression count.
		@param state the world section
		@return true when it built now (false: already built)
	]]
	local function ensureWorldCards(state: WorldSectionState): boolean
		if state.built then
			return false
		end
		state.built = true
		local firstCard = #allCards + 1
		local index = 0
		for _, item in state.config.items do
			local def = MonetizationConfig.getProduct(item.key)
			if def ~= nil and def.world == state.config.world then
				index += 1
				local card = buildProductCard(def, state.color, state.grid, index, state.section, item.icon)
				-- Hidden until applyWorldVisibility decides (no one-frame flash of a bought pack).
				card.frame.Visible = false
				table.insert(state.items, { def = def, frame = card.frame, button = card.button.instance :: GuiObject })
			end
		end
		local current = plan
		if current ~= nil then
			for cardIndex = firstCard, #allCards do
				allCards[cardIndex].setLayout(current.cardLayout)
			end
		end
		ShopText.collect(state.grid, textConstraints)
		rebuildOrderedKeys()
		remaining += #state.items
		return true
	end

	--[[
		Shows / hides every world section and card for the player's state now:
			section shown  world unlocked (WorldClient.isUnlocked) AND not closed by the kill
			               switch (WorldClient.isEnabled) AND at least one card left to show
			card hidden    ShopLogic.worldItemHidden (the one-time bundle once bought)
		Builds the cards lazily the first time a world opens. Updates hiddenKeys, the section's
		LB / RB flag, its grid's cell count and its gamepad block.
		@return (changed: something appeared / disappeared, built: cards were built now)
	]]
	local function applyWorldVisibility(): (boolean, boolean)
		local ctx = context()
		local changed = false
		local built = false
		for _, state in worldStates do
			local world = state.config.world
			local open = WorldClient.isUnlocked(world) and WorldClient.isEnabled(world)
			if open and ensureWorldCards(state) then
				built = true
			end
			local cells: { GuiObject } = {}
			for _, item in state.items do
				local show = open and not ShopLogic.worldItemHidden(item.def, ctx)
				if item.frame.Visible ~= show then
					item.frame.Visible = show
					changed = true
				end
				if show then
					hiddenKeys[item.def.key] = nil
					table.insert(cells, item.button)
				else
					hiddenKeys[item.def.key] = true
				end
			end
			local shown = #cells > 0
			if state.header.Visible ~= shown then
				state.header.Visible = shown
				state.grid.Visible = shown
				changed = true
			end
			state.section.hidden = not shown
			state.listGrid.count = #cells
			state.navBlock.cells = cells
		end
		return changed, built
	end

	-- Re-applies the current plan after world sections / cards appeared or disappeared (list +
	-- canvas heights, header widths, a full gamepad re-link) and re-measures scaled labels.
	local function restructure()
		local current = plan
		if current ~= nil then
			applyPlan(current, true)
		end
		scheduleTextScale()
	end

	--[[
		The live world pass (queued by WorldClient.StateChanged, ProfileChanged "worlds" and a
		world PurchaseGranted while open): visibility, then the world cards' statuses and Bones
		previews. Re-lays out only when something appeared / disappeared; a gamepad cursor that
		sat on a card that just left moves to the preferred card.
	]]
	local function refreshWorld()
		local selected = GuiService.SelectedObject
		local changed, built = applyWorldVisibility()
		local ctx = context()
		refreshWorldStatus(ctx)
		refreshWorldCash(ctx.profile)
		if changed or built then
			restructure()
			-- Cards that just appeared in view count once the list has laid them out.
			task.delay(SCROLL_SETTLE_SECONDS, reportVisibleOffers)
		end
		local selectedKey = if selected ~= nil then keyOfButton[selected] else nil
		if selectedKey ~= nil and hiddenKeys[selectedKey] then
			-- R122: a cursor whose card vanished goes to a heading, never onto another BUY.
			GamepadNav.select(preferredLanding())
		end
	end
	worldPass = refreshWorld

	-- The world section of `worldId` that is shown now, else nil (the open preselect).
	local function shownWorldSection(worldId: string): WorldSectionState?
		for _, state in worldStates do
			if state.config.world == worldId and not state.section.hidden then
				return state
			end
		end
		return nil
	end

	-- Connects the open-only world signals (disconnected on close: a closed Shop does no work).
	local function connectWorldSignals()
		if #worldConnections > 0 or #worldStates == 0 then
			return
		end
		table.insert(worldConnections, WorldClient.StateChanged:Connect(queueWorldRefresh))
		table.insert(
			worldConnections,
			ClientState.ProfileChanged:Connect(function(_profile: ClientState.Profile, fields: { string }?)
				if fields == nil or table.find(fields, "worlds") ~= nil then
					queueWorldRefresh()
				end
			end)
		)
	end

	-- Drops the world signal connections (Shop closed).
	local function disconnectWorldSignals()
		for _, connection in worldConnections do
			connection:Disconnect()
		end
		table.clear(worldConnections)
	end

	-- ── Screen handle ────────────────────────────────────────────────────────────────────────
	return {
		onOpen = function(args: any?)
			local wasOpen = isOpen
			isOpen = true
			if not wasOpen then
				relayout() -- the gui is enabled now: measure the real canvas (may swap the shell)
				-- R57 world sections: show / hide (building a newly opened world's cards) before
				-- the full refresh, so their statuses + previews are applied in the same pass.
				local worldChanged, worldBuilt = applyWorldVisibility()
				if worldChanged or worldBuilt then
					restructure()
				end
				refreshAll()
				startVisit()
				-- Owner R98: item idle animation on (each card still steps only while on screen).
				ItemFx.setEnabled(itemFx, true)
				sectionCycler.enable()
				connectWorldSignals()
				scheduleTextScale() -- labels measure their real scale once the pop-in settles
			end
			shell.popIn()
			-- Where to go: an item key (product / pass / HUD offer focus) or a section id. Hidden
			-- world sections / cards are not targets (the server would refuse the prompt anyway).
			local sectionId: string? = nil
			local key: string? = nil
			local source: string? = nil
			if type(args) == "table" then
				source = shortString(args.source)
				local wantedSection = shortString(args.section)
				if wantedSection ~= nil and sectionShown(wantedSection) then
					sectionId = wantedSection
				end
				local wantedKey = shortString(args.product) or shortString(args.pass) or shortString(args.focus)
				local wantedId = if wantedKey ~= nil then sectionOfKey[wantedKey] else nil
				if wantedKey ~= nil and wantedId ~= nil and not hiddenKeys[wantedKey] and sectionShown(wantedId) then
					key = wantedKey
					sectionId = wantedId
					-- HUD offers pass only the item: credit them as "offer".
					source = source or "offer"
				end
			end
			-- R57: a fresh open with no target inside a world that has a shown Shop section (Dino
			-- Valley) lands on that section, cursor on its first buyable card.
			if not wasOpen and sectionId == nil then
				local here = shownWorldSection(WorldClient.current())
				if here ~= nil then
					sectionId = here.section.id
				end
			end
			focusButton = nil
			if key ~= nil then
				focusButton = buttonOfKey[key]
			elseif sectionId ~= nil then
				focusButton = preferredIn(sections[sectionIndex[sectionId]].keys)
			end
			if not wasOpen then
				ClientAnalytics.screenOpened("Shop", source)
			end
			if sectionId ~= nil then
				local index = sectionIndex[sectionId]
				local focusKey = key or firstShownKey(sections[index].keys)
				scrollTo(sections[index].label, if focusKey ~= nil then cardOfKey[focusKey] else nil)
			elseif not wasOpen then
				scrollTo(nil, nil)
			end
			-- Re-opened in place with a new target: move the gamepad cursor to that card's section
			-- heading (owner R122: never straight onto its BUY; Down reaches the card).
			if wasOpen and focusButton ~= nil then
				GamepadNav.select(preferredLanding())
			end
		end,
		onClose = function()
			isOpen = false
			focusButton = nil
			scrollToken += 1 -- cancels a pending scroll
			sectionCycler.disable()
			ItemFx.setEnabled(itemFx, false) -- R98: items rest, no animator steps while closed
			disconnectWorldSignals() -- R57: a closed Shop listens to nothing world-related
		end,
		-- Owner R122: a section heading (landing), never a Robux BUY button (PurchaseGuard).
		defaultSelection = function(): GuiObject?
			return PurchaseGuard.safeDefault({ preferredLanding(), GamepadNav.firstSelectable(body) })
		end,
	}
end

-- Warm the Shop's 3D models in the background a little after boot (low priority: never ahead of
-- anything on screen), so the first open shows models instead of icons. R57 world sections'
-- models join only for worlds the player already has open (a locked world's props are never
-- downloaded; a world unlocked later loads them when its section first shows).
task.delay(ShopModels.PrefetchDelay, function()
	local specs = ShopModels.allSpecs()
	local warmed: { [string]: boolean } = {}
	for _, section in ShopConfig.WorldSections do
		local world = section.world
		if not warmed[world] and WorldClient.isUnlocked(world) and WorldClient.isEnabled(world) then
			warmed[world] = true
			for _, spec in ShopModels.worldSpecs(world) do
				table.insert(specs, spec)
			end
		end
	end
	ModelViewport.prefetch(specs)
end)

return {
	name = NAME,
	modal = true,
	closeOnBack = true,
	lazy = true,
	build = build,
} :: ScreenManager.ScreenModule
