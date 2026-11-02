--!strict
--[[
	HudZonesConfig — the HUD's screen zones and the order of its buttons / offers.

	Purpose:
		The HUD is four zones around the play view (spec §6, reference shots):
			Left   column of square stud buttons (2 columns on desktop, re-flowed on phones)
			Right  column of rotating starburst Robux offers
			Top    centre currency stack (Gems, Cash, +$/s)
			Bottom centre objective chip (+ tutorial arrow) and toasts
		This file lists WHAT goes in each zone (keys, labels, icons, colours, target screens) and
		the zone margins; UI/Widgets/HudPlacement turns it into positions for the current canvas.
		Later builders add a HUD button by adding one row here (and its screen under UI/Screens).

	Row fields (Left):
		key      stable id (Hud.setButtonVisible(key, ...))
		label    text under the icon
		icon     IconAssets key
		color    UIStyleConfig ColorName of the tile
		screen   ScreenManager screen opened on press
		wide     spans both columns (Lucky Wheel)
		hidden   starts hidden (Attack until unlocked, Event unless the event is live)
		more     owner R110: lives in the MORE flyout (UI/Hud/HudMoreMenu) instead of on the stack
		         (Teleport, Rebirth, Event); its key keeps working with every Hud.setButton* call

	Owner R110 ("can we cut down on the cards on the left at all? there is just a bunch lol"):
		Left      every left-side destination, in menu-wheel order (Platform/MenuWheel and
		          Screens/ComingSoon read it; unchanged meaning)
		Stack     the tiles drawn on the stack: Left rows without `more` + the MORE tile (MoreTile)
		          last -> Shop, Pets, Quests, Rewards, Attack, MORE (a 2 x 3 grid on every device)
		MoreRows  the MORE flyout's rows: Left rows with `more` + MoreExtra (Settings)


	Offer fields (Right): key, label, icon, product (MonetizationConfig key, Products or Passes),
	kind ("product" | "pass"), screen (opened when the product id is not live yet).

	Connects to: UI/Hud/{HudButtons, HudMoreMenu, HudOffers}, UI/Widgets/{HudPlacement, HudZones},
	Platform/MenuWheel (Left order), UI/Screens/ComingSoon (labels).

	Example: for _, row in HudZonesConfig.Left do print(row.key) end
]]

local UIStyleConfig = require(script.Parent.UIStyleConfig)

export type LeftRow = {
	key: string,
	label: string,
	icon: string,
	color: UIStyleConfig.ColorName,
	screen: string,
	wide: boolean?,
	hidden: boolean?,
	more: boolean?,
}

-- Owner R110: the MORE tile at the end of the stack (opens the HudMoreMenu flyout, no screen).
export type MoreTile = {
	key: string,
	label: string,
	icon: string,
	color: UIStyleConfig.ColorName,
}

export type OfferRow = {
	key: string,
	label: string,
	icon: string,
	product: string,
	kind: "product" | "pass",
	screen: string,
	-- R78: always open `screen` instead of prompting (the Nuke Pass offer shows its track first;
	-- the purchase happens on that screen). nil / false = prompt when the id is live.
	openScreen: boolean?,
}

local HudZonesConfig = {}

--[[
	The left-side destinations (owner R62, 2026-10-31: "we just have a lot of buttons on the left
	side"; owner R110, 2026-10-31: "can we cut down on the cards on the left at all?").
	The stack shows five tiles + MORE: Shop, Pets, Quests (R78), Rewards, Attack (Attack only in
	Nuke Town once the launcher is built) and the MORE tile. Teleport, Rebirth and the Thanksgiving
	Event (only while that event is live) moved into the MORE flyout (`more = true`), next to
	Settings (MoreExtra). Daily / Time / Lucky Wheel / Codes / Group live inside the Rewards hub
	(H3-hub's Screens/RewardsHub; its red badge = UI/RewardsBadges.total()). Admin is the small
	wrench chip in the top-right corner (HudZonesConfig.AdminChip). The gamepad menu wheel lists
	every row here in this order (flyout rows included).
]]
HudZonesConfig.Left = table.freeze({
	table.freeze({ key = "Shop", label = "Shop", icon = "Shop", color = "yellow", screen = "Shop" }) :: LeftRow,
	table.freeze({ key = "Pets", label = "Pets", icon = "Pets", color = "purple", screen = "Pets" }) :: LeftRow,
	-- R78 Quests: starter goals / daily missions / trophies + the Nuke Pass banner (UI/Screens/
	-- Quests); red badge = claimable quests + claimable pass tiers (Client/Quests/QuestClient).
	table.freeze({ key = "Quests", label = "Quests", icon = "Trophy", color = "orange", screen = "Quests" }) :: LeftRow,
	table.freeze({
		key = "Rewards",
		label = "Rewards",
		icon = "Rewards",
		color = "green",
		screen = "RewardsHub",
	}) :: LeftRow,
	table.freeze({
		key = "Attack",
		label = "Attack",
		icon = "Attack",
		color = "orange",
		screen = "Attack",
		hidden = true,
	}) :: LeftRow,
	-- R110: the MORE flyout rows (Teleport's NEW tag / Event's "!" roll up onto the MORE tile).
	table.freeze({
		key = "Teleport",
		label = "Teleport",
		icon = "Teleport",
		color = "sky",
		screen = "Teleport",
		more = true,
	}) :: LeftRow,
	table.freeze({
		key = "Rebirth",
		label = "Rebirth",
		icon = "Rebirth",
		color = "teal",
		screen = "Rebirth",
		more = true,
	}) :: LeftRow,
	table.freeze({
		key = "Event",
		label = "Event",
		icon = "Event",
		color = "orange",
		screen = "HarvestFeast",
		hidden = true,
		more = true,
	}) :: LeftRow,
}) :: { LeftRow }

--[[
	Owner R110: flyout-only rows that are not left-side destinations elsewhere (Settings; the menu
	wheel lists it from PlatformConfig.MenuWheel.Extra, so it is not a Left row).
]]
HudZonesConfig.MoreExtra = table.freeze({
	table.freeze({
		key = "Settings",
		label = "Settings",
		icon = "Settings",
		color = "grey",
		screen = "Settings",
		more = true,
	}) :: LeftRow,
}) :: { LeftRow }

-- Owner R110: the MORE tile (always the LAST stack tile; HudPlacement anchors the flyout on it).
HudZonesConfig.MoreTile = table.freeze({
	key = "More",
	label = "More",
	icon = "Star",
	color = "blue",
} :: MoreTile)

--[[
	Owner R110: the MORE flyout (UI/Hud/HudMoreMenu; placement = HudPlacement.flyout).
		Pad              design px of stud panel around the tiles (the tiles keep the stack's size
		                 and gap, so they stay >= the 44 pt tap on touch)
		PanelColor       stud preset of the panel; PanelTop overrides its gradient top so the panel
		                 reads as the same quiet slate as the objective chip (coloured tiles pop)
		PopSeconds       open pop-in (UIScale PopScale -> 1; skipped with Reduce Motion)
		PopScale         the pop's starting scale
		AnalyticsScreen  AnalyticsConfig.ClientFunnel.Screens id reported on open ("open:More")
		AnalyticsSource  its source ("openFrom:More:hud"); the children keep their own ids / sources
]]
HudZonesConfig.MoreFlyout = table.freeze({
	Pad = 10,
	PanelColor = "grey" :: UIStyleConfig.ColorName,
	PanelTop = Color3.fromRGB(96, 110, 136),
	PopSeconds = 0.14,
	PopScale = 0.86,
	AnalyticsScreen = "More",
	AnalyticsSource = "hud",
})

-- Owner R110: the stack tiles' rows (Left rows without `more`, in order; MoreTile follows them).
local stack: { LeftRow } = {}
-- Owner R110: the MORE flyout's rows (Left rows with `more`, then MoreExtra), in order.
local moreRows: { LeftRow } = {}
for _, row in HudZonesConfig.Left do
	table.insert(if row.more == true then moreRows else stack, row)
end
for _, row in HudZonesConfig.MoreExtra do
	table.insert(moreRows, row)
end
HudZonesConfig.Stack = table.freeze(stack)
HudZonesConfig.MoreRows = table.freeze(moreRows)

--[[
	The admin wrench chip (owner R62): admins only (the server-set IsAdmin attribute; every admin
	action is re-authorised by AdminService), a small square in the top-right corner under the
	Roblox top bar, above the offer column. `Size` = its design px on desktop / console; touch
	devices grow it to the 44 pt tap. Also in the gamepad menu wheel (Platform/MenuWheel) for admins.
]]
export type AdminChip = {
	key: string,
	label: string,
	icon: string,
	color: UIStyleConfig.ColorName,
	screen: string,
	Size: number,
}
HudZonesConfig.AdminChip = table.freeze({
	key = "Admin",
	label = "Admin",
	icon = "Admin",
	color = "grey",
	screen = "AdminPanel",
	Size = 64,
} :: AdminChip)

-- Right column, in priority order (the first ones stay; the rest rotate when space is short).
HudZonesConfig.Offers = table.freeze({
	table.freeze({
		key = "X2Cash",
		label = "x2 Cash",
		icon = "x2Cash",
		product = "DoubleCash",
		kind = "pass",
		screen = "Shop",
	}) :: OfferRow,
	table.freeze({
		key = "StarterPack",
		label = "Starter Pack",
		icon = "StarterPack",
		product = "StarterPack",
		kind = "product",
		screen = "Shop",
	}) :: OfferRow,
	-- R78 Nuke Pass: shown only while a season runs and its premium is not owned
	-- (PassConfig.offerVisible, UI/Hud/HudOffers); opens the NukePass track screen.
	table.freeze({
		key = "Pass",
		label = "Nuke Pass",
		icon = "NukePass",
		product = "NukePassPremium",
		kind = "product",
		screen = "NukePass",
		openScreen = true,
	}) :: OfferRow,
	table.freeze({ key = "VIP", label = "VIP", icon = "VIP", product = "VIP", kind = "pass", screen = "Shop" }) :: OfferRow,
	table.freeze({
		key = "Spins",
		label = "x5 Spins",
		icon = "Spins",
		product = "Spins5",
		kind = "product",
		screen = "LuckyWheel",
	}) :: OfferRow,
	table.freeze({
		key = "Teleporter",
		label = "Teleporter",
		icon = "Teleporter",
		product = "Teleporter",
		kind = "pass",
		screen = "Shop",
	}) :: OfferRow,
	table.freeze({
		key = "SecretPack",
		label = "Secret Pack",
		icon = "SecretPack",
		product = "SecretPack",
		kind = "product",
		screen = "Shop",
	}) :: OfferRow,
}) :: { OfferRow }

-- Zone margins (design px). TopReserve is added below the Roblox top bar (ScreenManager.safeTop).
HudZonesConfig.Margins = table.freeze({
	Side = 16,
	TopReserve = 10,
	-- Space the left column keeps clear at the bottom (objective chip lives centre-bottom, so
	-- the columns may run lower than it).
	Bottom = 16,
	-- The left column starts at least this far down (the top-left corner holds Roblox's buttons).
	LeftTop = 150,
	RightTop = 120,
})

--[[
	Owner R123 ("leaderboard covers the invite ui"): the top-right area Roblox's player list
	(leaderboard) takes where it shows by default (desktop, PlayerList CoreGui on), in POINTS
	(Hud converts with TouchLayout.pointsToDesign). Measured from the owner's 2026-11-01 Mac
	screenshot (People / Cash list, 3 players): ~242 pt wide, its top ~60 pt below the screen top,
	a ~40 pt header and ~41 pt per player row. Rows = players in the server (capped at MaxRows =
	the server size); Pad adds a little air. HudPlacement keeps the admin chip / INVITE row left of
	it and starts the offer column below it. Phones / tablets / console never reserve it (the list
	is collapsed there by default).
]]
HudZonesConfig.PlayerList = table.freeze({
	WidthPoints = 252,
	TopPoints = 60,
	HeaderPoints = 40,
	RowPoints = 41,
	PadPoints = 8,
	MaxRows = 8,
})

--[[
	Phone layout (owner R59: "the cards are just kind of covering the whole screen ... put them up
	to the left more, make them smaller"; R110: five tiles + MORE). Phones only (DeviceProfile class
	"Phone"); tablets, desktop and console keep the classic layout.
		- Left stack: a compact `Columns` (2) x 3 grid pinned to the top-left corner right under
		  the Roblox top bar, tiles exactly the 44 pt tap tall (TouchUIConfig.MinTapPoints in
		  design px) and `TileWidthRatio` x that wide so every label stays >= `LabelPoints` pt,
		  `Gap` apart. Nothing reaches the thumbstick / jump-button zones.
		- Offers: `OfferScale` x UIStyleConfig.Hud.OfferSize (never under the 44 pt tap).
		- WHAT'S NEW: an icon-only star square with a NEW dot (HudWhatsNew compact).
	tests/hud-cluster.luau proves the phone layouts (on screen, no overlaps, 44 pt taps, clear of
	the thumbstick / jump button, >= FreeShare of the screen free of HUD).
]]
HudZonesConfig.Phone = table.freeze({
	Gap = 6,
	Columns = 2,
	TileWidthRatio = 1.35,
	OfferScale = 0.63,
	LabelPoints = 14,
	FreeShare = 0.6,
})

return table.freeze(HudZonesConfig)
