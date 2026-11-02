--!strict
--[[
	HappyHourChipLogic — pure layout + copy rules of the Happy Hours HUD pill, the schedule panel
	and the start banner (owner R89 §2; UI/Screens/HappyHour). No Instances, no services:
	tests/happy-hours.luau runs it.

	The pill (owner R92 Studio pass: "far too big ... on phone it lands in the middle"):
		[star]  LIVE: CONFETTI 3:12        live (event colour)
		[star]  SPRINKLES IN 15:40         next within the hour (blue)
		[star]  STAMPEDE AT 4:00 PM        next later (blue, player-local clock)
		[star]  0:13                        phone, live (owner R138: the full line took a third of
		                                    an iPhone screen; the event colour + the start banner
		                                    name it, a tap opens the schedule)
	One short line (event `short` names). ~52 design px tall on desktop / tablet / console; on a
	PHONE only the LIVE countdown shows (NEXT would sit over the character), 72 design px tall so
	the tap target stays >= 44 pt and the text >= 14 pt, one fixed width (`size`).

	Placement (`place`): clear of every HUD zone (HudZones Top / Left / Right / Bottom / TopRight)
	and every measured obstacle the caller passes (the Roblox top-bar buttons from
	GuiService.TopbarInset, the R82 boost badge, the admin wrench chip):
		desktop / tablet / console  "topLeft" (above the left grid, under the top bar), then
		                            "topRight" (under the admin chip), then "underTop"
		phone                       "rightOfTop" / "leftOfTop" (beside the currency stack in the
		                            top band, R138), then "underTopRight" (below the INVITE row),
		                            and "underTop" (above the character's head) only as a last resort
	A corner / side spot slides down under an obstacle in its way (e.g. the top-bar buttons inside a
	TV-safe console frame). First fit wins; when nothing fits cleanly the result is nil and the
	pill stays hidden (the start banner still announces the event). Never shrunk below its
	readable size.

	Banner (`shouldAnnounce`, `bannerText`): one banner per event INSTANCE (signature), forced
	events included; deferred (not dropped) while the loading screen / guided tutorial is up.

	Example:
		local text = HappyHourChipLogic.chipText(live, nextLive, now, false, localTime)
		local rect, which = HappyHourChipLogic.place({ canvas = canvas, safeTop = 58, size = size,
			gap = 14, zones = zones, obstacles = {}, phone = false })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HappyHourConfig = require(ReplicatedStorage.Shared.Config.HappyHourConfig)
local HappyHourLogic = require(ReplicatedStorage.Shared.Events.HappyHourLogic)

type Live = HappyHourLogic.Live

export type Rect = { x: number, y: number, w: number, h: number }

export type PlaceInput = {
	canvas: Vector2, -- usable canvas (design px, TV-safe)
	safeTop: number, -- design px below the Roblox top bar (ScreenManager.safeTop(0))
	size: Vector2, -- pill size (design px)
	gap: number, -- clearance from every zone / obstacle and the screen edges
	zones: { [string]: Rect? }, -- HudZones by name
	obstacles: { Rect }, -- measured extra rects (top-bar buttons, boost badge, admin chip)
	phone: boolean, -- phones: beside the currency stack, under INVITE, then under the stack (R138)
}

export type ChipText = {
	text: string, -- the one line ("LIVE: CONFETTI 3:12")
	color: string, -- StudUI colour preset
	icon: string, -- IconAssets key
	live: boolean,
}

local Client = HappyHourConfig.Client

local HappyHourChipLogic = {}

--[[ True when two rects overlap once `a` is grown by `gap` on every side. ]]
function HappyHourChipLogic.overlaps(a: Rect, b: Rect, gap: number): boolean
	return a.x - gap < b.x + b.w and b.x < a.x + a.w + gap and a.y - gap < b.y + b.h and b.y < a.y + a.h + gap
end

-- True when `rect` is inside the canvas (below safeTop) and clear of every zone / obstacle.
local function fits(rect: Rect, input: PlaceInput): boolean
	local gap = input.gap
	if rect.x < 0 or rect.y < input.safeTop or rect.x + rect.w > input.canvas.X or rect.y + rect.h > input.canvas.Y then
		return false
	end
	for _, zone in input.zones do
		if zone ~= nil and HappyHourChipLogic.overlaps(rect, zone, gap) then
			return false
		end
	end
	for _, obstacle in input.obstacles do
		if HappyHourChipLogic.overlaps(rect, obstacle, gap) then
			return false
		end
	end
	return true
end

-- The candidate rects in preference order (see the header).
local function candidates(input: PlaceInput): { { name: string, rect: Rect } }
	local gap = input.gap
	local canvas = input.canvas
	local w, h = input.size.X, input.size.Y
	local zones = input.zones
	local top = zones.Top
	local left = zones.Left
	local topRight = zones.TopRight
	local list: { { name: string, rect: Rect } } = {}
	-- Under the currency stack, centred (the last resort on phones).
	local topBottom = if top ~= nil then top.y + top.h else input.safeTop
	local centreX = if top ~= nil then top.x + top.w / 2 else canvas.X / 2
	local underTop = { name = "underTop", rect = { x = centreX - w / 2, y = topBottom + gap, w = w, h = h } }
	if input.phone then
		-- R138: beside the currency stack in the top band (sky, not the world in front of the
		-- character): right of it first (the Roblox buttons sit top-left), then left of it; a boost
		-- badge or top-bar button in the way pushes the spot down (place). A measured iPhone 14 has
		-- only the left gap free (tests/happy-hours.luau), and only for the narrow phone chip.
		if top ~= nil then
			local sideY = math.max(input.safeTop + gap, top.y)
			table.insert(list, { name = "rightOfTop", rect = { x = top.x + top.w + gap, y = sideY, w = w, h = h } })
			table.insert(list, { name = "leftOfTop", rect = { x = top.x - gap - w, y = sideY, w = w, h = h } })
		end
		-- Narrower phones: under the INVITE row, left of the right column, still off the character.
		if topRight ~= nil then
			local right = zones.Right
			local edge = topRight.x + topRight.w
			if right ~= nil then
				edge = math.min(edge, right.x - gap)
			end
			local rect = { x = edge - w, y = topRight.y + topRight.h + gap, w = w, h = h }
			table.insert(list, { name = "underTopRight", rect = rect })
		end
		-- The last resort sits right above the character's head (the owner's R138 complaint).
		table.insert(list, underTop)
		return list
	end
	-- Top-left corner (aligned with the left grid's edge when there is one).
	local leftX = if left ~= nil then math.max(gap, left.x) else gap
	table.insert(list, { name = "topLeft", rect = { x = leftX, y = input.safeTop + gap, w = w, h = h } })
	-- Top-right, under the admin chip (or the top bar).
	local rightY = if topRight ~= nil then topRight.y + topRight.h + gap else input.safeTop + gap
	table.insert(list, { name = "topRight", rect = { x = canvas.X - gap - w, y = rightY, w = w, h = h } })
	table.insert(list, underTop)
	return list
end

--[[
	Picks the pill rect (see the header).
	@return (rect in design px, candidate name) or (nil, "none") when nothing fits cleanly
]]
function HappyHourChipLogic.place(input: PlaceInput): (Rect?, string)
	for _, candidate in candidates(input) do
		local rect = candidate.rect
		-- A corner / side spot slides DOWN under a measured obstacle in its way (the Roblox top-bar
		-- buttons on a TV-safe console, the admin chip, a phone's boost badge), a few steps at most.
		if candidate.name ~= "underTop" then
			for _ = 1, 3 do
				local blocker: Rect? = nil
				for _, obstacle in input.obstacles do
					if HappyHourChipLogic.overlaps(rect, obstacle, input.gap) then
						blocker = obstacle
						break
					end
				end
				if blocker == nil then
					break
				end
				rect = { x = rect.x, y = blocker.y + blocker.h + input.gap, w = rect.w, h = rect.h }
			end
		end
		if fits(rect, input) then
			return rect, candidate.name
		end
	end
	return nil, "none"
end

--[[
	The pill size for a line of text: height by device (phone = a >= 44 pt tap target), width =
	icon + padding + an upper-case Fredoka estimate (the label is TextScaled, so a slightly wide
	estimate never overflows).
	@return Vector2 design px
	Example: HappyHourChipLogic.size("SPRINKLES IN 15:40", false) --> (~370, 52)
]]
function HappyHourChipLogic.size(text: string, phone: boolean): Vector2
	local height = if phone then Client.PillHeightPhone else Client.PillHeight
	local textSize = if phone then Client.PillTextSizePhone else Client.PillTextSize
	local icon = height * Client.PillIconFill
	-- R138: the phone pill holds only the countdown at one fixed width, so it never re-places while
	-- ticking; the label is TextScaled, so a rare longer clock ("10:00", a forced event) just shrinks.
	local chars = if phone then Client.PillCompactChars else #text
	local width = Client.PillPadding * 3 + icon + chars * textSize * Client.PillCharWidth
	return Vector2.new(math.ceil(width), height)
end

--[[
	"3:12" (< 1 h), "1:02:03" (≥ 1 h); negative / junk = "0:00".
	Example: HappyHourChipLogic.clock(192) --> "3:12"
]]
function HappyHourChipLogic.clock(seconds: number): string
	local s = if seconds == seconds and seconds > 0 and seconds < math.huge then math.floor(seconds) else 0
	local hours = s // 3600
	local minutes = (s % 3600) // 60
	local rest = s % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, rest)
	end
	return string.format("%d:%02d", minutes, rest)
end

--[[ True when the pill shows a ticking countdown (live, or the next event within the hour). ]]
function HappyHourChipLogic.countdownVisible(live: Live?, nextLive: Live?, now: number): boolean
	if live ~= nil then
		return true
	end
	return nextLive ~= nil and nextLive.startsAt - now <= Client.CountdownWithin
end

--[[
	The pill copy (see the header).
	@param live      the live event or nil
	@param nextLive  the next event or nil
	@param now       server unix time
	@param phone     phones show the LIVE state only
	@param localTime formats a unix time as the player's local clock ("4:00 PM")
	@return ChipText, or nil when there is nothing to show (kill switch / off / phone between events)
]]
function HappyHourChipLogic.chipText(
	live: Live?,
	nextLive: Live?,
	now: number,
	phone: boolean,
	localTime: (unix: number) -> string
): ChipText?
	if live ~= nil then
		local def = HappyHourConfig.get(live.id)
		if def == nil then
			return nil
		end
		local clock = HappyHourChipLogic.clock(live.endsAt - now)
		return {
			-- R138: a phone shows only "★ 0:13" in the event's colour (the full line was a third of
			-- an iPhone screen); the start banner names the event and a tap opens the schedule.
			text = if phone then clock else `LIVE: {def.short} {clock}`,
			color = def.color,
			icon = Client.PillIcon,
			live = true,
		}
	end
	if phone or nextLive == nil then
		return nil
	end
	local def = HappyHourConfig.get(nextLive.id)
	if def == nil then
		return nil
	end
	local startsIn = nextLive.startsAt - now
	local when = if startsIn <= Client.CountdownWithin
		then `IN {HappyHourChipLogic.clock(startsIn)}`
		else `AT {string.upper(localTime(nextLive.startsAt))}`
	return { text = `{def.short} {when}`, color = "blue", icon = Client.PillIcon, live = false }
end

--[[
	One schedule-panel row's right-hand text: "LIVE 3:12" / "in 12:40" (< 1 h) / "4:00 PM".
	Example: HappyHourChipLogic.rowTime(row, now, formatter) --> "in 12:40"
]]
function HappyHourChipLogic.rowTime(row: Live, now: number, localTime: (unix: number) -> string): string
	if row.startsAt <= now then
		return `LIVE {HappyHourChipLogic.clock(row.endsAt - now)}`
	end
	local startsIn = row.startsAt - now
	if startsIn <= Client.CountdownWithin then
		return `in {HappyHourChipLogic.clock(startsIn)}`
	end
	return localTime(row.startsAt)
end

--[[
	Whether the start banner should show now: a live event whose instance (signature) was not
	announced yet, once the loading screen is gone and no guided tutorial step is running (the
	caller retries later while it is blocked — a deferred banner, never a dropped one).
	@param announced the signature of the last instance announced ("" = none)
	@return (show now, signature to remember once shown)
	Example: HappyHourChipLogic.shouldAnnounce("", live, true, false) --> true, "confetti@1793487600"
]]
function HappyHourChipLogic.shouldAnnounce(
	announced: string,
	live: Live?,
	loadingDone: boolean,
	guided: boolean
): (boolean, string)
	local signature = HappyHourLogic.signature(live)
	if signature == "" or signature == announced then
		return false, announced
	end
	if not loadingDone or guided then
		return false, announced
	end
	return true, signature
end

--[[
	The start banner lines: (title, line) — "CONFETTI STORM!" + the event banner line; the mini
	surge its own line; a world event happening elsewhere names that world.
	@param worldName display name of the event's world ("" for global events)
]]
function HappyHourChipLogic.bannerText(live: Live, inWorld: boolean, worldName: string): (string, string)
	local def = HappyHourConfig.get(live.id)
	if def == nil then
		return "", ""
	end
	local line = if live.mini then Client.MiniTagline else def.banner
	if live.world ~= nil and not inWorld and worldName ~= "" then
		line = `Now in {worldName}! Hop over to join!`
	end
	return `{def.name}!`, line
end

return table.freeze(HappyHourChipLogic)
