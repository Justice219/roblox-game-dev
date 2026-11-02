--!strict
--[[
	HUD MORE flyout regression (owner R110, 2026-10-31: "can we cut down on the cards on the left
	at all? there is just a bunch lol"). Run:
		lune run tests/hud-more

	Proves, on the SHIPPED modules (geometry on the real device matrix lives in hud-cluster §9):
	  1. Config: the stack is Shop, Pets, Quests, Rewards, Attack (+ the MORE tile = 6 tiles); the
	     flyout is Teleport, Rebirth, Event (hidden until live), Settings; every key is unique and
	     every pre-R110 left key (Shop, Pets, Rewards, Quests, Rebirth, Teleport, Attack, Event)
	     is still a routable row, so Hud.setButtonVisible / setButtonBadge / setButtonNew callers
	     keep working; Left still lists every left destination for the menu wheel; icons exist.
	  2. HudMoreLogic.rollup: only visible children count; one badge verbatim; several numbers
	     sum (capped); anything non-numeric -> "!"; NEW rolls up from any visible child.
	  3. Analytics: "More" is an allowlisted ClientFunnel screen and its source is allowlisted, so
	     "open:More" / "openFrom:More:hud" are counted (AnalyticsLogic.screenOpen).
	  4. HudPlacement.flyout edge cases: no items -> nil; a short band falls back to two rows /
	     one column; a rect in the way slides the panel to the nearest clear spot; the panel
	     never leaves the band; impossible input still returns a clamped on-canvas panel.
]]

local roblox = require("@lune/roblox")
local Vector2 = roblox.Vector2

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local HudZonesConfig = loader.load("src/shared/Config/HudZonesConfig")
local HudPlacement = loader.load("src/client/UI/Widgets/HudPlacement")
local HudMoreLogic = loader.load("src/client/UI/Hud/HudMoreLogic")
local AnalyticsConfig = loader.load("src/shared/Config/AnalyticsConfig")
local AnalyticsLogic = loader.load("src/server/Analytics/AnalyticsLogic")
local IconAssets = loader.load("src/shared/Config/IconAssets")
local UIStyleConfig = loader.load("src/shared/Config/UIStyleConfig")

local checks = 0
local function ok(value: any, label: string)
	if not value then
		error(`{label}: expected truthy, got {tostring(value)}`, 2)
	end
	checks += 1
end

local function keysOf(rows: { any }): string
	local keys: { string } = {}
	for _, row in rows do
		table.insert(keys, row.key)
	end
	return table.concat(keys, ",")
end

-- 1. Config ---------------------------------------------------------------------------------------
ok(keysOf(HudZonesConfig.Stack) == "Shop,Pets,Quests,Rewards,Attack", `stack rows ({keysOf(HudZonesConfig.Stack)})`)
ok(#HudZonesConfig.Stack + 1 == 6, "stack + MORE = 6 tiles")
ok(
	keysOf(HudZonesConfig.MoreRows) == "Teleport,Rebirth,Event,Settings",
	`flyout rows ({keysOf(HudZonesConfig.MoreRows)})`
)
local seen: { [string]: boolean } = {}
for _, rows in { HudZonesConfig.Left, HudZonesConfig.MoreExtra, { HudZonesConfig.MoreTile } } do
	for _, row in rows do
		ok(not seen[row.key], `key {row.key} is unique`)
		seen[row.key] = true
		ok(IconAssets.get(row.icon).image ~= "", `{row.key}: icon {row.icon} is uploaded`)
		ok(UIStyleConfig.Colors[row.color] ~= nil, `{row.key}: colour {row.color} is a preset`)
	end
end
for _, key in { "Shop", "Pets", "Rewards", "Quests", "Rebirth", "Teleport", "Attack", "Event" } do
	local found = false
	for _, row in HudZonesConfig.Left do
		found = found or row.key == key
	end
	ok(found, `pre-R110 key {key} still a Left row (callers + menu wheel keep working)`)
end
for _, row in HudZonesConfig.MoreRows do
	ok(row.more == true, `{row.key} is marked as a MORE row`)
	ok(type(row.screen) == "string" and row.screen ~= "", `{row.key} opens a screen`)
	ok(row.wide ~= true, `{row.key}: flyout tiles are never wide`)
end
for _, row in HudZonesConfig.Stack do
	ok(row.more ~= true, `{row.key} stays on the stack`)
end
-- Event shows only while live; Attack only once unlocked (both start hidden); MORE always shows.
for _, row in HudZonesConfig.Left do
	if row.key == "Event" or row.key == "Attack" then
		ok(row.hidden == true, `{row.key} starts hidden`)
	end
end
ok(HudZonesConfig.MoreFlyout.Pad > 0 and HudZonesConfig.MoreFlyout.PopScale < 1, "flyout tunables sane")

-- 2. Roll-up ----------------------------------------------------------------------------------------
local function child(visible: boolean, badge: string?, new: boolean): any
	return { visible = visible, badge = badge, new = new }
end
local badge, isNew = HudMoreLogic.rollup({})
ok(badge == nil and isNew == false, "no children: nothing")
badge, isNew = HudMoreLogic.rollup({ child(true, nil, false), child(true, nil, false) })
ok(badge == nil and isNew == false, "no badges / NEW: nothing")
badge, isNew = HudMoreLogic.rollup({ child(true, nil, true), child(true, "!", false) })
ok(badge == "!" and isNew == true, "Teleport NEW + Event ! -> ! + NEW")
badge = HudMoreLogic.rollup({ child(true, "3", false) })
ok(badge == "3", "one badge verbatim")
badge = HudMoreLogic.rollup({ child(true, "2", false), child(true, "3", false) })
ok(badge == "5", "numbers sum")
badge = HudMoreLogic.rollup({ child(true, "60", false), child(true, "70", false) })
ok(badge == tostring(HudMoreLogic.BADGE_CAP), "sum capped")
badge = HudMoreLogic.rollup({ child(true, "2", false), child(true, "!", false) })
ok(badge == "!", "number + ! -> !")
badge = HudMoreLogic.rollup({ child(true, "2", false), child(true, "1.5", false) })
ok(badge == "!", "non-integer text -> !")
badge, isNew = HudMoreLogic.rollup({ child(false, "!", true), child(true, nil, false) })
ok(badge == nil and isNew == false, "a hidden child (Event off) never badges MORE")
badge = HudMoreLogic.rollup({ child(true, "", false) })
ok(badge == nil, "empty text is no badge")

-- 3. Analytics ------------------------------------------------------------------------------------
local flyoutConfig = HudZonesConfig.MoreFlyout
ok(table.find(AnalyticsConfig.ClientFunnel.Screens, flyoutConfig.AnalyticsScreen) ~= nil, "More screen allowlisted")
ok(table.find(AnalyticsConfig.ClientFunnel.Sources, flyoutConfig.AnalyticsSource) ~= nil, "More source allowlisted")
local keys = AnalyticsLogic.screenOpen(flyoutConfig.AnalyticsScreen, flyoutConfig.AnalyticsSource)
ok(keys ~= nil and keys[1] == "open:More" and keys[2] == "openFrom:More:hud", "open:More counted")
for _, row in HudZonesConfig.MoreRows do
	-- The children keep reporting their own screen ids (unchanged: the screens report on open).
	ok(row.screen ~= flyoutConfig.AnalyticsScreen, `{row.key} is not reported as More`)
end

-- 4. HudPlacement.flyout edge cases ---------------------------------------------------------------
local canvas = Vector2.new(1920, 1080)
local grid = { x = 16, y = 400, w = 276, h = 420 }
local anchor = { x = 160, y = 688, w = 132, h = 132 }
local function place(overrides: { [string]: any }): any
	local input: { [string]: any } = {
		canvas = canvas,
		grid = grid,
		anchor = anchor,
		count = 4,
		gap = 12,
		pad = 10,
		top = 68,
		bottom = 1064,
		right = 1904,
		avoid = {},
	}
	for key, value in overrides do
		input[key] = value
	end
	return HudPlacement.flyout(input)
end
ok(place({ count = 0 }) == nil, "no items: no flyout")
local wide = place({})
ok(wide.columns == 4 and wide.rows == 1, "room: one row")
ok(wide.x == grid.x + grid.w + 12 and wide.y == anchor.y - 10, "beside the grid, level with MORE")
ok(wide.w == 4 * 132 + 3 * 12 + 20 and wide.h == 132 + 20, "panel = tiles + gaps + pad")
local twoRows = place({ right = 292 + 12 + 2 * 132 + 12 + 20 })
ok(twoRows.columns == 2 and twoRows.rows == 2, "narrow: two rows")
local column = place({ right = 292 + 12 + 132 + 20 })
ok(column.columns == 1 and column.rows == 4, "very narrow: one column")
ok(column.y >= 68 and column.y + column.h <= 1064, "one column stays in the band")
-- A rect in the way (an objective chip right of the grid on MORE's row) slides the panel off it.
local blocker = { x = 300, y = 650, w = 800, h = 200 }
local slid = place({ avoid = { blocker } })
local overlap = slid.x < blocker.x + blocker.w
	and blocker.x < slid.x + slid.w
	and slid.y < blocker.y + blocker.h
	and blocker.y < slid.y + slid.h
ok(not overlap, "slides clear of a rect in the way")
ok(slid.y + slid.h <= 1064 and slid.y >= 68, "slid panel stays in the band")
ok(slid.y == blocker.y - 12 - slid.h or slid.y == blocker.y + blocker.h + 12, "slid to the nearest clear spot")
-- Low MORE tile near the bottom limit: clamped up into the band.
local low = place({ anchor = { x = 160, y = 1000, w = 132, h = 132 } })
ok(low.y + low.h <= 1064, "clamped above the bottom limit")
-- Impossible (band shorter than one tile): still a panel on the canvas (transient popover).
local cramped = place({ top = 500, bottom = 520 })
ok(cramped ~= nil and cramped.x >= 0 and cramped.x + cramped.w <= canvas.X, "impossible band: clamped on canvas")
ok(cramped.y >= 0 and cramped.y + cramped.h <= canvas.Y, "impossible band: clamped vertically on canvas")

print(`[hud-more] {checks} checks passed`)
