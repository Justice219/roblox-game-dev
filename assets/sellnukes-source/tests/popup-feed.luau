--!strict
--[[
	Bottom-left FEED regressions (owner R108: "can they just take up the bottom left?"; owner R111:
	"collecting goals blocks up the ui. should be a toast on the bottom left"). Run:
		lune run tests/popup-feed

	Proves on the shipped modules (Shared/Config/PopupQueueConfig.Feed, Client/UI/Widgets/FeedLogic)
	with the REAL HUD layout (Client/UI/Widgets/HudPlacement) on 15 devices:
	  1. Config: sane sizes; MaxVisible 4 (R111), BigPopMax 3 + ~5 s (R108); colours / icons by kind.
	  2. Desktop numbers: the column sits under the left grid, from the bottom margin up, and stops
	     short of the objective chip / hint bar; a very wide hint bar sends the bottom above it.
	  3. Every device (HudPlacement layouts, default + all rows): the column is inside the canvas,
	     never over the left grid, the objective chip, the hint bar, the touch thumbstick / jump
	     reserve; MinRows pills always fit; the reveal card fits at >= Card.MinFit; phone pill text
	     is >= 14 pt.
	  4. Windows (R111 screenshot: goal toasts over the Quests header): the column uses the gutter
	     left of a window, else the strip under it, else has no room — never over the window.
	  5. A centre popup is an obstacle (phones: the beside-grid column ends above a banner).
	  6. Pill sizes: one line → wraps to two → capped; never wider than the column.
	  7. Visibility: newest first, within the room and MaxVisible.
	  8. Merging: "Goal claimed! +10 Gems" x3 → "Goal claimed! x3 +30 Gems"; units / plurals /
	     commas; money or other rewards fall back to "<latest> x2"; merge keys.
	  9. Lucky Nukes (owner R120, Client/Tycoon/FlavorFeedLogic): the reveal card only for a first
	     find per world, at most once per 5 min (a first find inside it: nothing — the discovery
	     toast is its pill); repeats are pills; Sprinkle / Glitter get nothing after their first
	     find; pill words "GALAXY nukes x20 +$31.8M" / merged "GALAXY x3 +$95M"; other players'
	     Big Pops: one pill per 30 s, the rest coalesced (rarest kept, "+N" counted).
]]

local roblox = require("@lune/roblox")
local Vector2 = roblox.Vector2

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local Config = loader.load("src/shared/Config/PopupQueueConfig")
local FeedLogic = loader.load("src/client/UI/Widgets/FeedLogic")
local FlavorFeedLogic = loader.load("src/client/Tycoon/FlavorFeedLogic")
local FlavorConfig = loader.load("src/shared/Config/FlavorConfig")
local HudPlacement = loader.load("src/client/UI/Widgets/HudPlacement")
local LayoutLogic = loader.load("src/client/Platform/LayoutLogic")
local DeviceProfile = loader.load("src/shared/Util/DeviceProfile")
local PlatformConfig = loader.load("src/shared/Config/PlatformConfig")
local HudZonesConfig = loader.load("src/shared/Config/HudZonesConfig")
local TouchUIConfig = loader.load("src/shared/Config/TouchUIConfig")
local TouchLayout = loader.load("src/shared/Util/TouchLayout")
local UIStyleConfig = loader.load("src/shared/Config/UIStyleConfig")

type Rect = { x: number, y: number, w: number, h: number }

local checks = 0
local function ok(condition: boolean, label: string)
	checks += 1
	if not condition then
		error(label, 2)
	end
end

local EPS = 1e-6
local Feed = Config.Feed

local function overlaps(a: Rect, b: Rect): boolean
	if a.w <= EPS or a.h <= EPS or b.w <= EPS or b.h <= EPS then
		return false -- an empty column covers nothing
	end
	return a.x < b.x + b.w - EPS and b.x < a.x + a.w - EPS and a.y < b.y + b.h - EPS and b.y < a.y + a.h - EPS
end

local function areaRect(area: any): Rect
	return { x = area.x, y = area.top, w = area.width, h = area.bottom - area.top }
end

local DESKTOP_PILL =
	{ height = Feed.PillHeight, textSize = Feed.TextSize, iconSize = 37, padX = Feed.PadX, maxLines = Feed.MaxLines }
local function rowsNeed(height: number, rows: number): number
	return rows * height + (rows - 1) * Feed.RowGap
end

--------------------------------------------------------------------------------------------------
-- 1. Config
--------------------------------------------------------------------------------------------------

do
	ok(Feed.MaxVisible == 4, "R111: max 4 visible")
	ok(Feed.BigPopMax == 3, "R108: max 3 Big Pop pills")
	ok(Feed.BigPopSeconds >= 4 and Feed.BigPopSeconds <= 6, "R108: about 5 s each")
	ok(Feed.MergeSeconds > 0 and Feed.MergeSeconds <= 8, "merge window")
	ok(Feed.MinWidth >= 200 and Feed.MinWidth < Feed.PhoneMaxWidth and Feed.PhoneMaxWidth <= Feed.MaxWidth, "widths")
	ok(Feed.PhoneTextPoints >= 14, "R111: phone text >= 14 pt")
	ok(Feed.Card.MinFit > 0.5 and Feed.Card.MinFit <= 1, "card fit floor")
	ok(Feed.Card.SkipHeight >= TouchUIConfig.MinTapPoints, "SKIP >= 44 at 1:1")
	for _, kind in { "info", "success", "error", "reward", "purchase" } do
		ok(UIStyleConfig.Colors[Feed.KindColors[kind]] ~= nil, `colour for {kind}`)
		ok(type(Feed.KindIcons[kind]) == "string", `icon for {kind}`)
	end
	ok(
		Feed.KindColors.error == "red" and Feed.KindColors.success == "green" and Feed.KindColors.info == "blue",
		"colours by kind"
	)
end

--------------------------------------------------------------------------------------------------
-- 2. Desktop numbers
--------------------------------------------------------------------------------------------------

local DESK_LEFT: Rect = { x = 16, y = 397, w = 276, h = 420 }
local DESK_OBJECTIVE: Rect = { x = 580, y = 1000, w = 760, h = 64 }
local DESK_HINTS: Rect = { x = 710, y = 928, w = 500, h = 62 }

do
	local area = FeedLogic.area({
		canvasW = 1920,
		canvasH = 1080,
		bandTop = 188,
		left = DESK_LEFT,
		obstacles = { DESK_OBJECTIVE, DESK_HINTS },
		need = rowsNeed(Feed.PillHeight, Feed.MinRows),
		phone = false,
	})
	ok(area.spot == "below" and area.fits, "desktop: under the grid")
	ok(area.x == Feed.Margin, "left margin")
	ok(math.abs(area.top - (817 + Feed.Gap)) < EPS, "starts under the grid")
	ok(math.abs(area.bottom - (1080 - Feed.Margin)) < EPS, "bottom margin")
	ok(math.abs(area.width - (580 - Feed.Gap - Feed.Margin)) < EPS, "stops short of the objective chip")
	ok(area.bottom - area.top >= rowsNeed(Feed.PillHeight, Feed.MaxVisible), "4 pills fit on desktop")
	-- A very wide hint bar (gamepad, 4 long hints): the column ends above it instead.
	local wide = FeedLogic.area({
		canvasW = 1920,
		canvasH = 1080,
		bandTop = 188,
		left = DESK_LEFT,
		obstacles = { DESK_OBJECTIVE, { x = 210, y = 928, w = 1500, h = 62 } },
		need = rowsNeed(Feed.PillHeight, Feed.MinRows),
		phone = false,
	})
	ok(not overlaps(areaRect(wide), { x = 210, y = 928, w = 1500, h = 62 }), "never over a wide hint bar")
	ok(wide.bottom <= 928 - Feed.Gap + EPS or wide.spot == "beside", "climbs above it / moves")
	-- No grid known (HUD not laid out yet): margin column from the band top.
	local bare =
		FeedLogic.area({ canvasW = 1920, canvasH = 1080, bandTop = 188, obstacles = {}, need = 100, phone = false })
	ok(bare.x == Feed.Margin and bare.top == 188 and bare.fits, "no grid: plain corner column")
end

--------------------------------------------------------------------------------------------------
-- 3. Every device (the real HUD layout)
--------------------------------------------------------------------------------------------------

local DEVICES = {
	{ name = "iPhone SE", x = 667, y = 375, class = "Phone" },
	{ name = "iPhone 14", x = 844, y = 390, class = "Phone" },
	{ name = "iPhone 16 Pro Max", x = 932, y = 430, class = "Phone" },
	{ name = "Android 360", x = 740, y = 360, class = "Phone" },
	{ name = "Galaxy S22 Ultra", x = 915, y = 412, class = "Phone" },
	{ name = "Fold (open)", x = 882, y = 540, class = "Phone" },
	{ name = "iPad 9th", x = 1080, y = 810, class = "Tablet" },
	{ name = "iPad 10th", x = 1180, y = 820, class = "Tablet" },
	{ name = "iPad mini", x = 1133, y = 744, class = "Tablet" },
	{ name = "iPad Pro 13", x = 1376, y = 1032, class = "Tablet" },
	{ name = "Galaxy Tab A8", x = 1280, y = 800, class = "Tablet" },
	{ name = "Laptop 1366", x = 1366, y = 768, class = "Desktop" },
	{ name = "Desktop 1080p", x = 1920, y = 1080, class = "Desktop" },
	{ name = "TV 1080p", x = 1920, y = 1080, class = "Console" },
	{ name = "TV 4K", x = 3840, y = 2160, class = "Console" },
}
local TOP_BAR_PT = 58

local function widesFor(all: boolean): { boolean }
	local wides: { boolean } = {}
	for _, row in HudZonesConfig.Left do
		if all or row.hidden ~= true then
			table.insert(wides, row.wide == true)
		end
	end
	table.insert(wides, false)
	return wides
end

do
	local phoneCount = 0
	for _, device in DEVICES do
		local touch = device.class == "Phone" or device.class == "Tablet"
		local phone = device.class == "Phone"
		local scale = DeviceProfile.uiScale(device.x, device.y, device.class)
		local insets = if device.class == "Console"
			then LayoutLogic.tvInsets(device.x, device.y, PlatformConfig.SafeArea.TvFraction)
			else { left = 0, top = 0, right = 0, bottom = 0 }
		local canvas = Vector2.new(
			(device.x - insets.left - insets.right) / scale,
			(device.y - insets.top - insets.bottom) / scale
		)
		local safeTop = math.max(0, TOP_BAR_PT - insets.top) / scale
		local jumpPt = LayoutLogic.jumpRect(device.x, device.y, PlatformConfig.Touch.DefaultJump)
		local touchReserve = if touch
			then math.max(HudPlacement.TouchBottomReserve, (device.y - jumpPt.y + 12) / scale)
			else nil
		local minTap = if touch then TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, scale) else nil
		-- Pill metrics exactly as PopupQueue.pillMetrics builds them.
		local textSize, pillHeight = Feed.TextSize, Feed.PillHeight
		if phone then
			textSize = math.ceil(TouchLayout.pointsToDesign(Feed.PhoneTextPoints, scale))
			pillHeight = math.ceil(textSize * Feed.PillHeightPerText)
			phoneCount += 1
			ok(textSize >= TouchLayout.pointsToDesign(14, scale) - EPS, `{device.name}: pill text >= 14 pt`)
		end
		for _, all in { false, true } do
			local layout = HudPlacement.compute({
				canvas = canvas,
				safeTop = safeTop,
				wides = widesFor(all),
				offerCount = #HudZonesConfig.Offers,
				touch = touch,
				touchReserve = touchReserve,
				phone = phone,
				minTap = minTap,
				corner = Vector2.new(260, 60),
				flyoutCount = 4,
			})
			local label = `{device.name} ({if all then "all rows" else "default rows"})`
			local grid: Rect = { x = layout.left.x, y = layout.left.y, w = layout.left.width, h = layout.left.height }
			local objective: Rect = {
				x = canvas.X / 2 - layout.bottomMaxWidth / 2,
				y = layout.bottomY - 64,
				w = layout.bottomMaxWidth,
				h = 64,
			}
			local obstacles = { objective }
			if not touch then
				-- The hint bar right above the objective chip (HintBar: Margin 10, 62 tall).
				table.insert(obstacles, { x = canvas.X / 2 - 450, y = objective.y - 10 - 62, w = 900, h = 62 })
			end
			local bandTop = 8 + HudPlacement.TopZoneHeight + Config.Band.TopGap
			local function area(need: number): any
				return FeedLogic.area({
					canvasW = canvas.X,
					canvasH = canvas.Y,
					bandTop = bandTop,
					left = grid,
					obstacles = obstacles,
					touchReserve = touchReserve,
					need = need,
					phone = phone,
				})
			end
			for _, need in { rowsNeed(pillHeight, Feed.MinRows), Feed.Card.Height } do
				local a = area(need)
				local r = areaRect(a)
				ok(
					r.x >= 0 and r.y >= 0 and r.x + r.w <= canvas.X + EPS and r.y + r.h <= canvas.Y + EPS,
					`{label}: inside`
				)
				ok(a.width >= Feed.MinWidth, `{label}: wide enough ({a.width})`)
				ok(not overlaps(r, grid), `{label}: clear of the left grid`)
				for _, obstacle in obstacles do
					ok(not overlaps(r, obstacle), `{label}: clear of the objective chip / hint bar`)
				end
				if touchReserve ~= nil then
					ok(a.bottom <= canvas.Y - touchReserve + EPS, `{label}: above the thumbstick / jump reserve`)
				end
				if need == Feed.Card.Height then
					local fit = math.min(a.width / Feed.Card.Width, (a.bottom - a.top) / Feed.Card.Height, 1)
					ok(fit >= Feed.Card.MinFit - EPS, `{label}: the reveal card fits ({fit})`)
				else
					ok(a.fits, `{label}: {Feed.MinRows} pills fit`)
				end
			end
		end
	end
	ok(phoneCount == 6, "six phones checked")
end

--------------------------------------------------------------------------------------------------
-- 4. Windows (R111)
--------------------------------------------------------------------------------------------------

do
	local function withWindow(window: Rect): any
		return FeedLogic.area({
			canvasW = 1920,
			canvasH = 1080,
			bandTop = 188,
			left = DESK_LEFT,
			obstacles = { DESK_OBJECTIVE },
			window = window,
			need = rowsNeed(Feed.PillHeight, 1),
			phone = false,
		})
	end
	-- Quests-sized window: the gutter left of it.
	local quests: Rect = { x = 460, y = 150, w = 1000, h = 800 }
	local a = withWindow(quests)
	ok(not overlaps(areaRect(a), quests), "never over the window")
	ok(math.abs(a.width - (460 - Feed.Gap - Feed.Margin)) < EPS, "uses the gutter left of it")
	-- A wide window: the strip under it.
	local wide: Rect = { x = 100, y = 150, w = 1720, h = 760 }
	local b = withWindow(wide)
	ok(not overlaps(areaRect(b), wide), "never over a wide window")
	ok(math.abs(b.top - (910 + Feed.Gap)) < EPS or b.spot == "beside", "the strip under it")
	-- A window that leaves no room anywhere: height 0 (toasts wait).
	local full: Rect = { x = 0, y = 40, w = 1920, h = 1035 }
	local c = withWindow(full)
	ok(c.bottom - c.top <= EPS or not overlaps(areaRect(c), full), "no room: nothing over it")
	ok(not c.fits, "and it does not fit")
end

--------------------------------------------------------------------------------------------------
-- 5. A centre popup is an obstacle
--------------------------------------------------------------------------------------------------

do
	-- iPhone 14 numbers: grid 16..214 x 103..328, reserve 170, a juice banner under the stack.
	local banner: Rect = { x = 300, y = 188, w = 760, h = 196 }
	local a = FeedLogic.area({
		canvasW = 1361,
		canvasH = 629,
		bandTop = 188,
		left = { x = 16, y = 103, w = 198, h = 225 },
		obstacles = { { x = 420, y = 549, w = 520, h = 64 }, banner },
		touchReserve = 170,
		need = Feed.Card.Height,
		phone = true,
	})
	ok(not overlaps(areaRect(a), banner), "never over a centre banner")
	-- Pills under a banner on a phone: the column starts under it (one pill still fits).
	local pills = FeedLogic.area({
		canvasW = 1361,
		canvasH = 629,
		bandTop = 188,
		left = { x = 16, y = 103, w = 198, h = 225 },
		obstacles = { { x = 420, y = 549, w = 520, h = 64 }, banner },
		touchReserve = 170,
		need = 45,
		phone = true,
	})
	ok(not overlaps(areaRect(pills), banner) and pills.fits, "a pill fits under the banner")
	ok(pills.top >= banner.y + banner.h + Feed.Gap - EPS, "starts under it")
end

--------------------------------------------------------------------------------------------------
-- 6. Pill sizes
--------------------------------------------------------------------------------------------------

do
	local chrome = DESKTOP_PILL.padX * 3 + DESKTOP_PILL.iconSize
	local w1, h1, l1 = FeedLogic.pillSize(200, 552, DESKTOP_PILL)
	ok(l1 == 1 and h1 == Feed.PillHeight and w1 == math.ceil(chrome + 200 + 4), "short: one line, hugs its text")
	local w2, h2, l2 = FeedLogic.pillSize(700, 552, DESKTOP_PILL)
	ok(l2 == 2 and h2 > Feed.PillHeight and w2 <= 552, "long: wraps to two lines, column wide")
	local w3, _, l3 = FeedLogic.pillSize(5000, 552, DESKTOP_PILL)
	ok(l3 == Feed.MaxLines and w3 <= 552, "very long: capped lines")
	local w4 = FeedLogic.pillSize(200, 150, DESKTOP_PILL)
	ok(w4 <= 150, "never wider than the column")
end

--------------------------------------------------------------------------------------------------
-- 7. Visibility
--------------------------------------------------------------------------------------------------

do
	local function flags(list: { boolean }): string
		local out = {}
		for _, v in list do
			table.insert(out, if v then "1" else "0")
		end
		return table.concat(out)
	end
	ok(flags(FeedLogic.visible({ 48, 48, 48 }, 1000, 4)) == "111", "all fit")
	ok(flags(FeedLogic.visible({ 48, 48, 48, 48, 48 }, 1000, 4)) == "01111", "MaxVisible keeps the newest")
	ok(flags(FeedLogic.visible({ 48, 48, 48 }, 48 * 2 + Feed.RowGap, 4)) == "011", "room keeps the newest")
	ok(flags(FeedLogic.visible({ 48, 48 }, 40, 4)) == "00", "no room: none")
	ok(flags(FeedLogic.visible({ 48, 90, 48 }, 48 + 90 + Feed.RowGap, 4)) == "011", "mixed heights")
end

--------------------------------------------------------------------------------------------------
-- 8. Merging
--------------------------------------------------------------------------------------------------

do
	local key = FeedLogic.mergeKey
	ok(key("reward", "Goal claimed! +10 Gems") == key("reward", "Goal claimed! +20 Gems"), "numbers merge")
	ok(key("reward", "Goal claimed! +10 Gems") ~= key("reward", "Mission claimed! +10 Gems"), "labels differ")
	ok(key("reward", "Goal claimed! +10 Gems") ~= key("success", "Goal claimed! +10 Gems"), "kinds differ")
	ok(key("reward", "Goal claimed! +1,000 Gems") == key("reward", "Goal claimed! +5 Gems"), "commas")

	local m = FeedLogic.merge(nil, "Goal claimed! +10 Gems")
	ok(m.text == "Goal claimed! +10 Gems" and m.count == 1, "first one is unchanged")
	m = FeedLogic.merge(m, "Goal claimed! +10 Gems")
	m = FeedLogic.merge(m, "Goal claimed! +40 Gems")
	ok(m.text == "Goal claimed! x3 +60 Gems", `R111 example: {m.text}`)
	local s = FeedLogic.merge(FeedLogic.merge(nil, "Goal claimed! +1 Spin"), "Goal claimed! +1 Spin")
	ok(s.text == "Goal claimed! x2 +2 Spins", `plural: {s.text}`)
	local both =
		FeedLogic.merge(FeedLogic.merge(nil, "Mission claimed! +10 Gems, +1 Spin"), "Mission claimed! +5 Gems, +1 Spin")
	ok(both.text == "Mission claimed! x2 +15 Gems, +2 Spins", `two units: {both.text}`)
	local big = FeedLogic.merge(FeedLogic.merge(nil, "Daily Chest opened! +900 Gems"), "Daily Chest opened! +600 Gems")
	ok(big.text == "Daily Chest opened! x2 +1,500 Gems", `commas: {big.text}`)
	local money = FeedLogic.merge(FeedLogic.merge(nil, "Goal claimed! +$1.2K"), "Goal claimed! +$3.4K")
	ok(money.text == "Goal claimed! +$3.4K x2", `money falls back: {money.text}`)
	local plain =
		FeedLogic.merge(FeedLogic.merge(FeedLogic.merge(nil, "Code redeemed!"), "Code redeemed!"), "Code redeemed!")
	ok(plain.text == "Code redeemed! x3", `no rewards: {plain.text}`)
	local mixed = FeedLogic.merge(FeedLogic.merge(nil, "Goal claimed! +10 Gems"), "Goal claimed! +10 Gems, a new pet")
	ok(mixed.count == 2 and string.find(mixed.text, "x2", 1, true) ~= nil, "other rewards still count")
end

--------------------------------------------------------------------------------------------------
-- 9. Lucky Nukes (owner R120)
--------------------------------------------------------------------------------------------------

do
	local Rules = Config.Feed.Flavor
	ok(Rules.CardCooldown == 300, "R120: card at most once per 5 minutes")
	ok(Rules.BigPopGap == 30, "R120: one Big Pop pill per 30 s")
	ok(Rules.QuietIds.sprinkle == true and Rules.QuietIds.glitter == true, "R120: Sprinkle + Glitter are quiet")
	ok(Rules.QuietIds.galaxy == nil and Rules.QuietIds.rainbow == nil, "rarer flavours keep their pill")
	ok(Rules.MergeSeconds > 0 and Rules.MergeSeconds <= 10, "short merge window")

	local state = FlavorFeedLogic.new()
	local function decide(flavorId: string, worldId: string, found: boolean, now: number): string
		return FlavorFeedLogic.decide(state, { flavorId = flavorId, worldId = worldId, found = found, now = now })
	end
	-- First find → card; the card shows → cooldown starts.
	ok(decide("galaxy", "main", false, 0) == "card", "first Galaxy in Nuke Town: the card")
	FlavorFeedLogic.cardShown(state, 0)
	-- The same flavour again (the Book now lists it, or the session saw it) → a pill.
	ok(decide("galaxy", "main", false, 5) == "pill", "second Galaxy (Book not synced yet): a pill, no 2nd card")
	ok(decide("galaxy", "main", true, 6) == "pill", "repeat: a pill")
	-- Another first find inside the 5 minutes → nothing (the server discovery toast is its pill).
	ok(decide("mystery", "main", false, 60) == "none", "a first find inside the cooldown: no card, no pill")
	ok(decide("mystery", "main", false, 61) == "pill", "then its repeats are pills")
	-- A first find in ANOTHER world after the cooldown → a card again.
	ok(decide("galaxy", "dino", false, 301) == "card", "first Galaxy in Dino Valley after 5 min: the card")
	-- A "card" answer alone does not start the cooldown (the card may be refused / expire).
	ok(decide("rainbow", "dino", false, 302) == "card", "no cardShown yet → still allowed")
	FlavorFeedLogic.cardShown(state, 302)
	ok(decide("glitter", "dino", false, 303) == "none", "first Glitter inside the cooldown: nothing")
	-- Quiet commons: nothing at all after the first find (just the income pop).
	ok(decide("sprinkle", "main", true, 400) == "none", "Sprinkle after its first find: nothing")
	ok(decide("glitter", "dino", true, 401) == "none", "Glitter after its first find: nothing")
	ok(decide("rainbow", "main", true, 402) == "pill", "Rainbow repeats keep a pill")
	-- A quiet first find still gets the card when allowed.
	local fresh = FlavorFeedLogic.new()
	ok(
		FlavorFeedLogic.decide(fresh, { flavorId = "sprinkle", worldId = "main", found = false, now = 0 }) == "card",
		"first Sprinkle ever: the card"
	)
	ok(FlavorFeedLogic.isQuiet("sprinkle") and not FlavorFeedLogic.isQuiet("galaxy"), "isQuiet")

	-- Pill words (FlavorConfig.Text keys win when F-flavors defines them; defaults otherwise).
	local galaxy = FlavorConfig.byId("galaxy")
	local single = FlavorFeedLogic.pillText(galaxy, 1, "$31.8M")
	local merged = FlavorFeedLogic.pillText(galaxy, 3, "$95M")
	local Text = FlavorConfig.Text :: any
	local pillFmt = Text.FeedPill or Rules.PillText
	local mergedFmt = Text.FeedPillMerged or Rules.PillMergedText
	local amountFmt = Text.FeedAmount or Rules.PillAmountText
	ok(single == string.format(pillFmt, "GALAXY", "x20") .. string.format(amountFmt, "$31.8M"), `single pill: {single}`)
	ok(merged == string.format(mergedFmt, "GALAXY", 3) .. string.format(amountFmt, "$95M"), `merged pill: {merged}`)
	if Text.FeedPill == nil then
		ok(single == "GALAXY nukes x20 +$31.8M" and merged == "GALAXY x3 +$95M", "owner R120 examples")
	end
	ok(
		FlavorFeedLogic.pillText(galaxy, 1, nil) == string.format(pillFmt, "GALAXY", "x20"),
		"no payout known: no amount"
	)
	ok(not string.find(string.lower(single), "batch", 1, true), "R112: never 'batch'")

	-- Other players' Big Pops: one pill per 30 s, coalesced.
	local bp = FlavorFeedLogic.new()
	local function entry(name: string, oneIn: number): any
		return { name = name, kind = "batch", id = "galaxy", label = "GALAXY", oneIn = oneIn }
	end
	local shown, more = FlavorFeedLogic.bigPop(bp, { entry("Alex", 2500) }, 0, 0)
	ok(shown ~= nil and shown.name == "Alex" and more == 0, "first Big Pop shows")
	shown = FlavorFeedLogic.bigPop(bp, { entry("Sam", 2500) }, 0, 10)
	ok(shown == nil, "inside 30 s: held")
	shown = FlavorFeedLogic.bigPop(bp, { entry("Kim", 50000), entry("Lee", 2500) }, 2, 20)
	ok(shown == nil, "still held")
	ok(FlavorFeedLogic.nextBigPopAt(bp) == 30, "released at the end of the gap")
	ok((FlavorFeedLogic.flushBigPop(bp, 29)) == nil, "not before the gap")
	local released, folded = FlavorFeedLogic.flushBigPop(bp, 30)
	ok(released ~= nil and released.name == "Kim", "the rarest is kept")
	ok(folded == 4, `everything else is counted: {folded}`) -- Sam + Lee + 2 server-folded
	ok(FlavorFeedLogic.nextBigPopAt(bp) == nil, "nothing pending after the release")
	shown = FlavorFeedLogic.bigPop(bp, { entry("Max", 2500) }, 0, 45)
	ok(shown == nil, "the gap restarts from the release")
	released = FlavorFeedLogic.flushBigPop(bp, 60)
	ok(released ~= nil and released.name == "Max", "and releases again 30 s later")
	ok((FlavorFeedLogic.bigPop(bp, {}, 0, 200)) == nil, "no entries: nothing")
	-- Soak: never two pills inside 30 s.
	local soak = FlavorFeedLogic.new()
	local last = -math.huge
	local t = 0
	for index = 1, 500 do
		t += (index % 7) * 1.3
		local a = FlavorFeedLogic.bigPop(soak, { entry(`P{index}`, index) }, 0, t)
		local b = FlavorFeedLogic.flushBigPop(soak, t)
		for _, pillShown in { a, b } do
			if pillShown ~= nil then
				ok(t - last >= Rules.BigPopGap - 1e-9, "never two Big Pop pills inside the gap")
				last = t
			end
		end
	end
end

print(`[popup-feed] {checks} checks passed`)
