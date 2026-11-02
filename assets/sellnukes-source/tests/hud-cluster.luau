--!strict
--[[
	HUD cluster regression (live layout geometry; inherited from B16's platform pass). Run:
		lune run tests/hud-cluster

	Runs the SHIPPED layout math — UI/Widgets/HudPlacement.compute fed exactly like UI/Hud/Hud
	feeds it (DeviceProfile.uiScale for the scale, Platform/LayoutLogic.jumpRect for the touch
	reserve, LayoutLogic.tvInsets for the console safe area) — on a matrix of real phone, tablet,
	desktop and console viewports (points), with the default HUD rows and with every optional
	row shown (Attack + Event + Admin), and with 6 or 1 offers. For every case it proves:

	  1. Everything is on screen: each left button, each visible offer slot and the objective
	     chip lie inside the canvas and below the Roblox top bar.
	  2. The clusters never overlap each other: left grid, offer column, objective chip and the
	     top currency stack (the "Top" zone Hud publishes: HudPlacement.TopZoneWidth/Height).
	  3. Touch devices: no left button, offer slot or the chip touches Roblox's jump button or
	     the thumbstick ring (the jump geometry mirrored into the bottom-left corner, which is
	     where Roblox draws the ring at the same height — the same model Hud's reserve uses).
	  4. Touch devices: every tap target is at least 44 pt on BOTH sides (Apple / Android
	     minimum), i.e. min(w, h) x scale >= 44 — including the short wide Lucky Wheel row.
	  5. Desktop / console: buttons never fall under UIStyleConfig.Hud.MinButtonSize design px.
	  7. PHONES (owner R59 + R62's six buttons): a compact Phone.Columns-wide grid of tiles
	     exactly the 44 pt tap tall in the top-left corner (x = Side, y = right under the top
	     bar), smaller offers, the icon-only WHAT'S NEW square; nothing overlaps, every tap
	     >= 44 pt, clear of the jump button / thumbstick, and >= HudZonesConfig.Phone.FreeShare
	     of the screen free of HUD (tiles, offers, corner + admin chips, currency stack,
	     objective chip).
	  8. The admin wrench chip (owner R62; "all rows" = an admin): top-right under the top bar,
	     on screen, >= 44 pt on touch, never over the grid, offers, currency stack, WHAT'S NEW
	     or the thumbs.
	 10. The INVITE button (owner R122; every case runs with and without it, sized exactly like
	     Hud/HudInvite.size): top-right under the top bar, on screen, >= 44 pt on touch, never over
	     the grid, offers, currency stack, objective chip, WHAT'S NEW, the admin chip, the MORE
	     flyout or the thumbs; the offer column starts below it.
	  9. The R110 stack + MORE flyout (owner: "can we cut down on the cards on the left at all?"):
	     the stack is HudZonesConfig.Stack + the MORE tile = a 2 x 3 grid on EVERY device with
	     every row shown (Shop, Pets, Quests, Rewards, Attack, MORE; 5 tiles = 3 rows by default),
	     and the MORE flyout (HudPlacement.flyout, 3 items or 4 with the live Event) is on screen
	     under the top bar, right of the grid, level with or near the MORE tile, inside its own
	     panel, never over the grid, offers, currency stack, objective chip, WHAT'S NEW, the admin
	     chip or the thumbs, every item the stack's tile size (>= 44 pt on touch, >= MinButtonSize
	     elsewhere) and no two items overlapping.
	  6. Worlds (owner R57 World 2): in a non-main world the currency stack (Gems | the world's
	     currency as primary | "+X/s Bones"; owner R60: no Cash there) stays inside the same Top zone
	     (height exactly; width for the widest realistic strings at a conservative glyph width),
	     so every layout above holds in Dino Valley too; the world rows' text stays >= the
	     readable floor; Nuke Town's own stack is unchanged.

	Rects are design px on the canvas (the UIScale'd ScreenGui space Hud lays out in).
]]

local roblox = require("@lune/roblox")
local Vector2 = roblox.Vector2

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local HudPlacement = loader.load("src/client/UI/Widgets/HudPlacement")
local LayoutLogic = loader.load("src/client/Platform/LayoutLogic")
local DeviceProfile = loader.load("src/shared/Util/DeviceProfile")
local PlatformConfig = loader.load("src/shared/Config/PlatformConfig")
local HudZonesConfig = loader.load("src/shared/Config/HudZonesConfig")
local UIStyleConfig = loader.load("src/shared/Config/UIStyleConfig")
local TouchUIConfig = loader.load("src/shared/Config/TouchUIConfig")
local InviteConfig = loader.load("src/shared/Config/InviteConfig")
local TouchLayout = loader.load("src/shared/Util/TouchLayout")

type Rect = { x: number, y: number, w: number, h: number }

local checks = 0
local function truthy(value: any, label: string)
	if not value then
		error(`{label}: expected truthy, got {tostring(value)}`, 2)
	end
	checks += 1
end

-- Apple HIG / Material minimum tap target (points).
local MIN_TAP_PT = TouchUIConfig.MinTapPoints
-- Roblox top bar height in points (GuiService.TopbarInset on the 2024+ top bar).
local TOP_BAR_PT = 58
-- Objective chip height (design px) — the "Bottom" zone Hud publishes.
local CHIP_HEIGHT = 64
-- Float tolerance for edge comparisons (design px).
local EPS = 1e-6

local function overlaps(a: Rect, b: Rect): boolean
	return a.x < b.x + b.w - EPS and b.x < a.x + a.w - EPS and a.y < b.y + b.h - EPS and b.y < a.y + a.h - EPS
end

local function inside(r: Rect, minX: number, minY: number, maxX: number, maxY: number): boolean
	return r.x >= minX - EPS and r.y >= minY - EPS and r.x + r.w <= maxX + EPS and r.y + r.h <= maxY + EPS
end

local function show(r: Rect): string
	return string.format("(%.0f,%.0f %.0fx%.0f)", r.x, r.y, r.w, r.h)
end

-- Visible stack tiles exactly as HudButtons builds them (R110): HudZonesConfig.Stack rows (the
-- defaults with hidden rows off, or every row with Attack on) + the MORE tile last.
local function widesFor(all: boolean): { boolean }
	local wides: { boolean } = {}
	for _, row in HudZonesConfig.Stack do
		if all or row.hidden ~= true then
			table.insert(wides, row.wide == true)
		end
	end
	table.insert(wides, false) -- MORE (always shown)
	return wides
end

-- R110: visible MORE flyout items (HudZonesConfig.MoreRows; `all` = the Event is live).
local function flyoutCountFor(all: boolean): number
	local count = 0
	for _, row in HudZonesConfig.MoreRows do
		if all or row.hidden ~= true then
			count += 1
		end
	end
	return count
end

type Device = { name: string, x: number, y: number, class: string }

-- Landscape viewports in points (the sizes Studio's device simulator / real devices report).
local DEVICES: { Device } = {
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

local cases = 0
-- R59: the worst free-screen share per phone (printed for the docs / report).
local phoneFree: { [string]: number } = {}
-- R110: the flyout shapes chosen per device ("iPhone SE 4x1"; printed for the docs / report).
local flyoutShapes: { [string]: boolean } = {}
for _, device in DEVICES do
	local touch = device.class == "Phone" or device.class == "Tablet"
	local scale = DeviceProfile.uiScale(device.x, device.y, device.class)
	-- Console: ScreenManager.canvasSize subtracts the TV-safe insets (points → design px).
	local insets = if device.class == "Console"
		then LayoutLogic.tvInsets(device.x, device.y, PlatformConfig.SafeArea.TvFraction)
		else { left = 0, top = 0, right = 0, bottom = 0 }
	local canvas =
		Vector2.new((device.x - insets.left - insets.right) / scale, (device.y - insets.top - insets.bottom) / scale)
	local safeTop = math.max(0, TOP_BAR_PT - insets.top) / scale
	-- Touch: Roblox's jump button in points, mirrored for the thumbstick ring, in design px.
	local jumpPt = LayoutLogic.jumpRect(device.x, device.y, PlatformConfig.Touch.DefaultJump)
	local jump: Rect = { x = jumpPt.x / scale, y = jumpPt.y / scale, w = jumpPt.w / scale, h = jumpPt.h / scale }
	local stick: Rect = { x = canvas.X - jump.x - jump.w, y = jump.y, w = jump.w, h = jump.h }
	local touchReserve = if touch then (device.y - jumpPt.y + 12) / scale else nil

	local isPhone = device.class == "Phone"
	local minTap = if touch then TouchLayout.pointsToDesign(MIN_TAP_PT, scale) else nil
	for _, all in { false, true } do
		for _, combo in { { #HudZonesConfig.Offers, true }, { 1, true }, { #HudZonesConfig.Offers, false } } do
			local offerCount: number, inviteOn: boolean = combo[1], combo[2]
			cases += 1
			local label = `{device.name} ({if all then "all rows" else "default rows"}, {offerCount} offers{if inviteOn
				then ", invite"
				else ""})`
			-- R122: the INVITE button exactly as HudInvite.size returns it.
			local inviteH = math.ceil(math.max(InviteConfig.Hud.Height, minTap or 0))
			local inviteW = math.ceil(
				(if isPhone then InviteConfig.Hud.PhoneWidth else InviteConfig.Hud.Width)
					* inviteH
					/ InviteConfig.Hud.Height
			)
			local wides = widesFor(all)
			-- The WHAT'S NEW corner exactly as Hud asks HudWhatsNew for it: phones the icon-only
			-- square at the 44 pt tap (R59); others a 260 x max(60, tap) chip.
			local cornerSize = if isPhone
				then Vector2.new(math.ceil(math.max(minTap or 0, 60)), math.ceil(math.max(minTap or 0, 60)))
				else Vector2.new(260, math.max(60, minTap or 0))
			-- The admin chip exactly as HudAdminChip.size returns it ("all rows" = an admin).
			local chipSide = math.ceil(math.max(HudZonesConfig.AdminChip.Size, minTap or 0))
			local layout = HudPlacement.compute({
				canvas = canvas,
				safeTop = safeTop,
				wides = wides,
				chip = if all then Vector2.new(chipSide, chipSide) else nil,
				invite = if inviteOn then Vector2.new(inviteW, inviteH) else nil,
				offerCount = offerCount,
				touch = touch,
				touchReserve = touchReserve,
				phone = isPhone,
				minTap = minTap,
				corner = cornerSize,
				flyoutCount = flyoutCountFor(all),
			})

			-- The cluster rects on the canvas.
			local buttons: { Rect } = {}
			for _, r in layout.left.rects do
				table.insert(buttons, { x = layout.left.x + r.x, y = layout.left.y + r.y, w = r.w, h = r.h })
			end
			local grid: Rect = { x = layout.left.x, y = layout.left.y, w = layout.left.width, h = layout.left.height }
			local right = layout.right
			local slots: { Rect } = {}
			for i = 0, right.slots - 1 do
				table.insert(slots, {
					x = right.x - right.slot / 2,
					y = right.y + i * (right.slot + right.gap),
					w = right.slot,
					h = right.slot,
				})
			end
			local column: Rect = if #slots > 0
				then { x = slots[1].x, y = slots[1].y, w = right.slot, h = slots[#slots].y + right.slot - slots[1].y }
				else { x = canvas.X, y = 0, w = 0, h = 0 }
			local chip: Rect = {
				x = canvas.X / 2 - layout.bottomMaxWidth / 2,
				y = layout.bottomY - CHIP_HEIGHT,
				w = layout.bottomMaxWidth,
				h = CHIP_HEIGHT,
			}
			local top: Rect = {
				x = canvas.X / 2 - HudPlacement.TopZoneWidth / 2,
				y = layout.topY,
				w = HudPlacement.TopZoneWidth,
				h = HudPlacement.TopZoneHeight,
			}

			-- 1. On screen, below the top bar.
			for index, b in buttons do
				truthy(inside(b, 0, safeTop, canvas.X, canvas.Y), `{label}: button {index} {show(b)} on screen`)
			end
			for index, s in slots do
				truthy(inside(s, 0, safeTop, canvas.X, canvas.Y), `{label}: offer {index} {show(s)} on screen`)
			end
			truthy(inside(chip, 0, 0, canvas.X, canvas.Y), `{label}: chip {show(chip)} on screen`)
			truthy(#slots >= 1, `{label}: at least one offer slot`)

			-- 2. Clusters never overlap each other.
			truthy(not overlaps(grid, column), `{label}: grid {show(grid)} vs offers {show(column)}`)
			truthy(not overlaps(grid, chip), `{label}: grid {show(grid)} vs chip {show(chip)}`)
			truthy(not overlaps(column, chip), `{label}: offers {show(column)} vs chip {show(chip)}`)
			truthy(not overlaps(grid, top), `{label}: grid {show(grid)} vs currency {show(top)}`)
			truthy(not overlaps(column, top), `{label}: offers {show(column)} vs currency {show(top)}`)

			if touch then
				-- 3. Clear of the jump button and the thumbstick ring.
				for index, b in buttons do
					truthy(not overlaps(b, jump), `{label}: button {index} {show(b)} vs jump {show(jump)}`)
					truthy(not overlaps(b, stick), `{label}: button {index} {show(b)} vs thumbstick {show(stick)}`)
				end
				for index, s in slots do
					truthy(not overlaps(s, jump), `{label}: offer {index} {show(s)} vs jump {show(jump)}`)
					truthy(not overlaps(s, stick), `{label}: offer {index} {show(s)} vs thumbstick {show(stick)}`)
				end
				truthy(not overlaps(chip, jump), `{label}: chip {show(chip)} vs jump {show(jump)}`)
				truthy(not overlaps(chip, stick), `{label}: chip {show(chip)} vs thumbstick {show(stick)}`)

				-- 4. >= 44 pt taps on both sides.
				for index, b in buttons do
					truthy(
						math.min(b.w, b.h) * scale >= MIN_TAP_PT - EPS,
						`{label}: button {index} {show(b)} is {string.format("%.1f", math.min(b.w, b.h) * scale)} pt`
					)
				end
				truthy(
					right.slot * scale >= MIN_TAP_PT - EPS,
					`{label}: offer slot {string.format("%.1f", right.slot * scale)} pt`
				)
			else
				-- 5. Ten-foot / desktop readability floor.
				truthy(
					layout.left.cell >= UIStyleConfig.Hud.MinButtonSize,
					`{label}: cell {layout.left.cell} >= MinButtonSize`
				)
			end

			-- The WHAT'S NEW corner (every device): on screen, clear of the clusters and thumbs.
			local corner = layout.corner
			truthy(corner ~= nil, `{label}: corner chip placed`)
			if corner ~= nil then
				truthy(inside(corner, 0, safeTop, canvas.X, canvas.Y), `{label}: corner {show(corner)} on screen`)
				truthy(not overlaps(corner, column), `{label}: corner {show(corner)} vs offers {show(column)}`)
				truthy(not overlaps(corner, grid), `{label}: corner {show(corner)} vs grid`)
				if touch then
					truthy(not overlaps(corner, jump), `{label}: corner {show(corner)} vs jump`)
				end
			end

			-- 8. The admin chip (R62).
			local adminChip = layout.chip
			truthy((adminChip ~= nil) == all, `{label}: admin chip only for admins`)
			if adminChip ~= nil then
				truthy(
					inside(adminChip, 0, safeTop, canvas.X, canvas.Y),
					`{label}: admin chip {show(adminChip)} on screen`
				)
				truthy(not overlaps(adminChip, grid), `{label}: admin chip vs grid`)
				truthy(
					not overlaps(adminChip, column),
					`{label}: admin chip {show(adminChip)} vs offers {show(column)}`
				)
				truthy(not overlaps(adminChip, top), `{label}: admin chip vs currency`)
				truthy(not overlaps(adminChip, chip), `{label}: admin chip vs objective chip`)
				if corner ~= nil then
					truthy(not overlaps(adminChip, corner), `{label}: admin chip vs WHAT'S NEW`)
				end
				if touch then
					truthy(adminChip.w * scale >= MIN_TAP_PT - EPS, `{label}: admin chip >= 44 pt`)
					truthy(
						not overlaps(adminChip, jump) and not overlaps(adminChip, stick),
						`{label}: admin chip vs thumbs`
					)
				end
			end

			-- 10. R122: the INVITE button.
			local invite = layout.invite
			truthy((invite ~= nil) == inviteOn, `{label}: invite placed only when asked`)
			if invite ~= nil then
				truthy(inside(invite, 0, safeTop, canvas.X, canvas.Y), `{label}: invite {show(invite)} on screen`)
				truthy(not overlaps(invite, grid), `{label}: invite {show(invite)} vs grid`)
				truthy(not overlaps(invite, column), `{label}: invite {show(invite)} vs offers {show(column)}`)
				truthy(not overlaps(invite, top), `{label}: invite {show(invite)} vs currency {show(top)}`)
				truthy(not overlaps(invite, chip), `{label}: invite vs objective chip`)
				truthy(column.y >= invite.y + invite.h - EPS, `{label}: offers start below the invite`)
				if corner ~= nil then
					truthy(not overlaps(invite, corner), `{label}: invite vs WHAT'S NEW`)
				end
				if adminChip ~= nil then
					truthy(not overlaps(invite, adminChip), `{label}: invite {show(invite)} vs admin chip`)
				end
				if layout.flyout ~= nil then
					local f = layout.flyout
					truthy(
						not overlaps(invite, { x = f.x, y = f.y, w = f.w, h = f.h }),
						`{label}: invite vs MORE flyout`
					)
				end
				if touch then
					truthy(
						math.min(invite.w, invite.h) * scale >= MIN_TAP_PT - EPS,
						`{label}: invite {string.format("%.1f", math.min(invite.w, invite.h) * scale)} pt`
					)
					truthy(not overlaps(invite, jump) and not overlaps(invite, stick), `{label}: invite vs thumbs`)
				end
			end

			-- 9. R110: the stack is a 2 x 3 grid; the MORE flyout keeps clear of everything.
			truthy(#buttons == (if all then 6 else 5), `{label}: stack = {#buttons} tiles (5 + Attack)`)
			truthy(layout.left.columns == 2, `{label}: stack in 2 columns ({layout.left.columns})`)
			local rowTops: { [number]: boolean } = {}
			local rowCount = 0
			for _, b in buttons do
				if not rowTops[b.y] then
					rowTops[b.y] = true
					rowCount += 1
				end
			end
			truthy(rowCount == 3, `{label}: stack in 3 rows ({rowCount})`)
			local flyout = layout.flyout
			truthy(flyout ~= nil, `{label}: MORE flyout placed`)
			if flyout ~= nil then
				local panel: Rect = { x = flyout.x, y = flyout.y, w = flyout.w, h = flyout.h }
				local more = buttons[#buttons]
				truthy(#flyout.rects == flyoutCountFor(all), `{label}: flyout has one rect per item`)
				truthy(
					inside(panel, 0, safeTop, canvas.X, canvas.Y),
					`{label}: flyout {show(panel)} on screen under the top bar`
				)
				truthy(panel.x >= grid.x + grid.w - EPS, `{label}: flyout {show(panel)} right of the grid`)
				truthy(not overlaps(panel, grid), `{label}: flyout vs grid`)
				truthy(not overlaps(panel, column), `{label}: flyout {show(panel)} vs offers {show(column)}`)
				truthy(not overlaps(panel, top), `{label}: flyout {show(panel)} vs currency {show(top)}`)
				truthy(not overlaps(panel, chip), `{label}: flyout {show(panel)} vs objective {show(chip)}`)
				if corner ~= nil then
					truthy(not overlaps(panel, corner), `{label}: flyout vs WHAT'S NEW`)
				end
				if layout.chip ~= nil then
					truthy(not overlaps(panel, layout.chip), `{label}: flyout vs admin chip`)
				end
				-- Level with the MORE tile on every device of the matrix (its first row on MORE's row).
				truthy(
					math.abs(panel.y + HudZonesConfig.MoreFlyout.Pad - more.y) < EPS,
					`{label}: flyout {show(panel)} level with MORE {show(more)}`
				)
				local itemRects: { Rect } = {}
				for _, r in flyout.rects do
					local item: Rect = { x = panel.x + r.x, y = panel.y + r.y, w = r.w, h = r.h }
					table.insert(itemRects, item)
					truthy(
						inside(item, panel.x, panel.y, panel.x + panel.w, panel.y + panel.h),
						`{label}: item in panel`
					)
					truthy(
						math.abs(r.w - more.w) < EPS and math.abs(r.h - more.h) < EPS,
						`{label}: flyout item = the MORE tile size`
					)
					if touch then
						truthy(
							math.min(r.w, r.h) * scale >= MIN_TAP_PT - EPS,
							`{label}: flyout item {string.format("%.1f", math.min(r.w, r.h) * scale)} pt`
						)
						truthy(not overlaps(item, jump), `{label}: flyout item {show(item)} vs jump`)
						truthy(not overlaps(item, stick), `{label}: flyout item {show(item)} vs thumbstick`)
					else
						truthy(
							math.min(r.w, r.h) >= UIStyleConfig.Hud.MinButtonSize,
							`{label}: flyout item >= MinButtonSize`
						)
					end
				end
				for i = 1, #itemRects do
					for j = i + 1, #itemRects do
						truthy(not overlaps(itemRects[i], itemRects[j]), `{label}: flyout items {i} / {j} overlap`)
					end
				end
				flyoutShapes[`{device.name} {flyout.columns}x{flyout.rows}`] = true
			end

			if isPhone then
				-- 7. R59 phone layout (R62: six buttons; R110: five tiles + MORE).
				local margins = HudZonesConfig.Margins
				local phoneCfg = HudZonesConfig.Phone
				local tap = math.ceil(minTap :: number)
				truthy(layout.left.cell == tap, `{label}: tiles are exactly the 44 pt tap tall`)
				truthy(math.abs(layout.left.x - margins.Side) < EPS, `{label}: grid hugs the left edge`)
				truthy(
					math.abs(layout.left.y - (safeTop + margins.TopReserve)) < EPS,
					`{label}: grid starts right under the top bar ({layout.left.y})`
				)
				truthy(layout.left.columns >= phoneCfg.Columns, `{label}: grid >= {phoneCfg.Columns} columns`)
				if not all then
					truthy(
						-- R110 default rows: Shop, Pets, Quests, Rewards + MORE (Attack hidden).
						layout.left.columns == phoneCfg.Columns and #buttons == 5,
						`{label}: default stack = 5 tiles in {phoneCfg.Columns} columns`
					)
				end
				for index, b in buttons do
					truthy(b.w >= b.h - EPS, `{label}: tile {index} is at least as wide as tall (labels)`)
				end
				local hudArea = 0
				for _, b in buttons do
					hudArea += b.w * b.h
				end
				for _, slotRect in slots do
					hudArea += slotRect.w * slotRect.h
				end
				if corner ~= nil then
					hudArea += corner.w * corner.h
				end
				if adminChip ~= nil then
					hudArea += adminChip.w * adminChip.h
				end
				if invite ~= nil then
					hudArea += invite.w * invite.h
				end
				hudArea += top.w * top.h + chip.w * chip.h
				local free = 1 - hudArea / (canvas.X * canvas.Y)
				truthy(
					free >= phoneCfg.FreeShare,
					`{label}: {string.format("%.0f", free * 100)} % of the screen free of HUD (>= {phoneCfg.FreeShare * 100} %)`
				)
				phoneFree[device.name] = math.min(phoneFree[device.name] or 1, free)
			end
		end
	end
end
for name, free in phoneFree do
	print(string.format("[hud-cluster] %s: worst %.0f %% of the screen free of HUD", name, free * 100))
end
local shapeNames: { string } = {}
for name in flyoutShapes do
	table.insert(shapeNames, name)
end
table.sort(shapeNames)
print(`[hud-cluster] MORE flyout shapes: {table.concat(shapeNames, ", ")}`)

-- 6. Worlds: the Dino currency stack fits the Top zone every layout above reserved.
local WorldClientConfig = loader.load("src/shared/Config/WorldClientConfig")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
local hudStyle = UIStyleConfig.Hud
local sizes = WorldClientConfig.Hud
-- Row heights as StudUI.moneyLabel builds them: textSize + 10.
local mainHeight = (hudStyle.GemTextSize + 10) + (hudStyle.CashTextSize + 10) + (hudStyle.RateTextSize + 10)
truthy(mainHeight <= HudPlacement.TopZoneHeight, `Nuke Town stack {mainHeight} <= Top zone height`)
local worldHeight = (hudStyle.GemTextSize + 10) + (sizes.PrimaryTextSize + 10) + sizes.BottomRowHeight
truthy(worldHeight <= HudPlacement.TopZoneHeight, `world stack {worldHeight} <= Top zone height`)
truthy(sizes.RateTextSize + 10 <= sizes.BottomRowHeight, "world rate fits its row")
-- Width: Luckiest Guy / Fredoka glyphs average under 0.62 em; widest realistic strings use the
-- compact formats (3 significant digits + a two-letter suffix).
local EM = 0.62
for _, def in WorldsConfig.extra() do
	local rateText = `+999Qi/s {def.currency.name}`
	local row = #rateText * sizes.RateTextSize * EM
	truthy(row <= HudPlacement.TopZoneWidth, `{def.id}: bottom row {math.floor(row)} <= Top zone width`)
	local primaryWidth = hudStyle.CashTextSize * UIStyleConfig.IconFill.Money + #"999.99Qi" * sizes.PrimaryTextSize * EM
	truthy(primaryWidth <= HudPlacement.TopZoneWidth, `{def.id}: primary {math.floor(primaryWidth)} <= Top zone width`)
end
truthy(sizes.RateTextSize >= 20, "world rate row stays readable (>= 20 design px)")
-- R60: another world shows only its own currency (no Cash pill config left to build one).
truthy((sizes :: any).PillTextSize == nil, "no Cash pill in another world (owner R60)")

-- Owner R123 ("leaderboard covers the invite ui"): on desktop Roblox's player list owns the
-- top-right corner. With it reserved (1 / 3 / 8 players, exactly as Hud sizes it from
-- HudZonesConfig.PlayerList), the admin chip + INVITE row and every offer slot keep clear of it,
-- stay on screen, never reach the currency stack and never overlap each other; touch and console
-- ignore the reserve (their layout is unchanged).
local LIST = HudZonesConfig.PlayerList
for _, device in DEVICES do
	local scale = DeviceProfile.uiScale(device.x, device.y, device.class)
	local insets = if device.class == "Console"
		then LayoutLogic.tvInsets(device.x, device.y, PlatformConfig.SafeArea.TvFraction)
		else { left = 0, top = 0, right = 0, bottom = 0 }
	local canvas =
		Vector2.new((device.x - insets.left - insets.right) / scale, (device.y - insets.top - insets.bottom) / scale)
	local safeTop = math.max(0, TOP_BAR_PT - insets.top) / scale
	local touch = device.class == "Phone" or device.class == "Tablet"
	local minTap = if touch then TouchLayout.pointsToDesign(MIN_TAP_PT, scale) else nil
	local inviteH = math.ceil(math.max(InviteConfig.Hud.Height, minTap or 0))
	local inviteW = math.ceil(
		(if device.class == "Phone" then InviteConfig.Hud.PhoneWidth else InviteConfig.Hud.Width)
			* inviteH
			/ InviteConfig.Hud.Height
	)
	local chipSide = math.ceil(math.max(HudZonesConfig.AdminChip.Size, minTap or 0))
	for _, rows in { 1, 3, LIST.MaxRows } do
		local heightPoints = LIST.TopPoints + LIST.HeaderPoints + rows * LIST.RowPoints + LIST.PadPoints
		local reserve = Vector2.new(
			TouchLayout.pointsToDesign(LIST.WidthPoints, scale),
			TouchLayout.pointsToDesign(heightPoints, scale)
		)
		for _, admin in { false, true } do
			local label = `R123 {device.name} ({rows} players{if admin then ", admin" else ""})`
			local layout = HudPlacement.compute({
				canvas = canvas,
				safeTop = safeTop,
				wides = widesFor(admin),
				chip = if admin then Vector2.new(chipSide, chipSide) else nil,
				invite = Vector2.new(inviteW, inviteH),
				offerCount = #HudZonesConfig.Offers,
				touch = touch,
				touchReserve = if touch then 170 else nil,
				phone = device.class == "Phone",
				minTap = minTap,
				corner = Vector2.new(260, math.max(60, minTap or 0)),
				flyoutCount = flyoutCountFor(admin),
				playerList = reserve,
			})
			if touch then
				truthy(layout.playerList == nil, `{label}: touch ignores the player list reserve`)
				continue
			end
			local list = layout.playerList
			truthy(list ~= nil, `{label}: player list reserved`)
			if list == nil then
				continue
			end
			local stack: Rect = {
				x = canvas.X / 2 - HudPlacement.TopZoneWidth / 2,
				y = 8,
				w = HudPlacement.TopZoneWidth,
				h = HudPlacement.TopZoneHeight,
			}
			local invite = layout.invite
			truthy(invite ~= nil, `{label}: INVITE placed`)
			if invite ~= nil then
				truthy(not overlaps(invite, list), `{label}: INVITE {show(invite)} vs player list {show(list)}`)
				truthy(inside(invite, 0, safeTop, canvas.X, canvas.Y), `{label}: INVITE {show(invite)} on screen`)
				truthy(not overlaps(invite, stack), `{label}: INVITE {show(invite)} vs currency stack`)
			end
			local chip = layout.chip
			truthy((chip ~= nil) == admin, `{label}: admin chip only for admins`)
			if chip ~= nil then
				truthy(not overlaps(chip, list), `{label}: chip {show(chip)} vs player list {show(list)}`)
				truthy(inside(chip, 0, safeTop, canvas.X, canvas.Y), `{label}: chip {show(chip)} on screen`)
				truthy(not overlaps(chip, stack), `{label}: chip {show(chip)} vs currency stack`)
				if invite ~= nil then
					truthy(not overlaps(chip, invite), `{label}: chip vs INVITE`)
				end
			end
			local right = layout.right
			for i = 0, right.slots - 1 do
				local slot: Rect = {
					x = right.x - right.slot / 2,
					y = right.y + i * (right.slot + right.gap),
					w = right.slot,
					h = right.slot,
				}
				truthy(not overlaps(slot, list), `{label}: offer slot {i + 1} {show(slot)} vs player list {show(list)}`)
				truthy(slot.y + slot.h <= canvas.Y, `{label}: offer slot {i + 1} on screen`)
			end
			truthy(right.slots >= 1, `{label}: at least one offer slot fits under the player list`)
		end
	end
end

print(`[hud-cluster] {checks} checks passed ({cases} layouts on {#DEVICES} devices)`)
