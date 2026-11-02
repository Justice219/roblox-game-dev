--!strict
--[[
	HudZones — the live screen rectangles the HUD occupies (rebuilt for SellNukes from the
	RoBeasts HudZones idea).

	Purpose:
		Other client systems must not draw over the HUD: the tutorial arrow, world billboards that
		pin to screen edges, toasts and future pop-ups ask HudZones where the left button grid,
		the right offer column, the top currency stack and the bottom objective chip are, in
		design px on the HUD canvas. The HUD publishes its zones whenever it re-lays out
		(event-driven); readers either poll `rect(name)` when they lay out or listen to Changed.

	Connects to: UI/Hud/Hud (publishes Left / Right / Top / Bottom / TopRight), Platform/HintBar
	(publishes Hints), Widgets/HudPlacement (Rect type), any client overlay (UI/Widgets/PopupQueue).

	Example:
		local left = HudZones.rect("Left")
		if left ~= nil and HudZones.overlaps(myRect, "Left") then nudgeRight() end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)

-- "TopRight" = the top-right corner row: the admin wrench chip (owner R62) and the INVITE button
-- left of it (owner R122, Hud/HudInvite; only while invites are available) — the union of the
-- two; nil when neither shows. (Owner R59's phone row of less-used buttons left it in R62.)
-- "Boosts" = the R78 boost chips under the currency stack; the toast stack / tutorial card start
-- below it when set. Since owner R82 the boosts are a badge on the cash counter's corner (inside
-- the "Top" zone's height band), so nothing publishes it (always nil); kept so readers stay valid.
-- "Hints" = the platform hint bar (owner R102): Platform/HintBar publishes its pill while it shows
-- (nil while hidden: touch, focus mode, no hints), so popups / the feed / chips keep clear of it.
export type ZoneName = "Left" | "Right" | "Top" | "Bottom" | "TopRight" | "Boosts" | "Hints"
export type Rect = { x: number, y: number, w: number, h: number }

local HudZones = {}

-- Fires () after any zone changed.
HudZones.Changed = Signal.new() :: Signal.Signal<>

local zones: { [ZoneName]: Rect } = {}

--[[
	Publishes one zone's rect (design px; nil clears it). Fires Changed when it differs.
	@param name the zone
	@param rect the rect or nil
]]
function HudZones.set(name: ZoneName, rect: Rect?)
	local old = zones[name]
	if old ~= nil and rect ~= nil and old.x == rect.x and old.y == rect.y and old.w == rect.w and old.h == rect.h then
		return
	end
	if old == nil and rect == nil then
		return
	end
	-- Store a frozen copy so readers can never mutate the published rect.
	zones[name] = if rect ~= nil then (table.freeze(table.clone(rect)) :: any) :: Rect else nil
	HudZones.Changed:Fire()
end

--[[ The current rect of a zone, or nil when the HUD has not laid it out (or hides it). ]]
function HudZones.rect(name: ZoneName): Rect?
	return zones[name]
end

--[[
	True when `rect` intersects the named zone with a positive area.
	Example: HudZones.overlaps({ x = 10, y = 400, w = 80, h = 80 }, "Left")
]]
function HudZones.overlaps(rect: Rect, name: ZoneName): boolean
	local zone = zones[name]
	if zone == nil then
		return false
	end
	return rect.x < zone.x + zone.w
		and zone.x < rect.x + rect.w
		and rect.y < zone.y + zone.h
		and zone.y < rect.y + rect.h
end

return table.freeze(HudZones)
