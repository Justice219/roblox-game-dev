--!strict
--[[
	NewPlayerQuick — the pure rules of the two quick "New Player Mode" controls (owner R67: "I also
	need a button in the admin panel that lets me play as a new player"; the mode itself is B14,
	Shared/Util/NewPlayerMode):
		* the big header button of the admin panel, on every tab: PLAY AS NEW PLAYER (yellow) while
		  the mode is off, EXIT NEW PLAYER MODE (green) while it is on. It sends the EXISTING admin
		  commands "NewPlayerMode" / "ExitNewPlayerMode" through the normal pipeline (in-panel
		  confirm, then AdminCommand → server re-auth, cooldown, audit). No new server path.
		* the small top-right chip "NEW PLAYER MODE · EXIT" the admin overlay shows while the mode
		  is on (admins only: only they can enter it), next to the HUD's admin wrench chip.
	No Roblox APIs and no requires: Lune tests run it directly (tests/admin-new-player-quick.luau).

	headerAction(active, unavailable)   which command / text / colour the header button shows and
	                                    whether it can be pressed (the server's availability map)
	chipRect(input)                     where the chip goes (design px), clear of the HUD zones

	Placement (chipRect): on the wrench chip's row, directly LEFT of it (same height, `gap` apart).
	The wrench rect is HudZones "TopRight" (W5b: exactly the admin chip, every device; R62 removed
	the R59 phone row). When the row spot overlaps the top currency stack (narrow screens), the chip
	first SHRINKS into the gap between the stack and the wrench (down to `minWidth`, phones: keeps
	the playfield clear — Studio QA 2026-10-31), and only when even that does not fit it drops BELOW
	the wrench (and below the currency stack if it reaches that low), right-aligned with
	the wrench; if the right offer column is there, it moves left of that column. Never left of the
	side margin. Without a wrench chip (it is hidden) the same rules start from the top-right corner
	under the Roblox top bar.

	Connects to: Screens/Admin/AdminPanelScreen (header button), Screens/Admin/AdminOverlayScreen
	(chip), Shared/Util/NewPlayerMode (the mode + copy), Shared/Config/AdminConfig (the commands).

	Example:
		local action = NewPlayerQuick.headerAction(false, AdminClient.unavailable)
		--> { command = "NewPlayerMode", text = "PLAY AS NEW PLAYER", color = "yellow", enabled = true }
]]

export type Rect = { x: number, y: number, w: number, h: number }

export type HeaderAction = {
	command: string, -- AdminConfig command name to send
	text: string, -- button text
	color: string, -- UIStyleConfig colour name
	enabled: boolean, -- false while the server marks the command unavailable
	reason: string?, -- why it is unavailable (shown in the panel's status line)
}

export type ChipInput = {
	canvas: Vector2, -- HUD canvas (design px)
	safeTop: number, -- first free y under the Roblox top bar (design px)
	margin: number, -- side / top margin (design px)
	gap: number, -- spacing to the wrench chip and the HUD zones (design px)
	size: Vector2, -- the chip's size (design px)
	minWidth: number?, -- narrowest the chip may shrink to on the wrench's row (default: no shrink)
	adminChip: Rect?, -- the wrench chip = HudZones "TopRight", when shown
	top: Rect?, -- HudZones "Top" (currency stack)
	right: Rect?, -- HudZones "Right" (offer column)
}

local NewPlayerQuick = {}

-- The admin commands (AdminConfig.Commands keys; tests check they exist).
NewPlayerQuick.Enter = "NewPlayerMode"
NewPlayerQuick.Exit = "ExitNewPlayerMode"

-- Header button copy (the commands' labels, shouted).
NewPlayerQuick.Copy = table.freeze({
	Enter = "PLAY AS NEW PLAYER",
	Exit = "EXIT NEW PLAYER MODE",
})

--[[
	The header button's state.
	@param active      the local player is in New Player Mode (server-set attribute)
	@param unavailable the panel's availability lookup (AdminClient.unavailable): nil = usable,
	                   else the server's reason
	@return HeaderAction
	Example: headerAction(true, function() return nil end).command --> "ExitNewPlayerMode"
]]
function NewPlayerQuick.headerAction(active: boolean, unavailable: (name: string) -> string?): HeaderAction
	local command = if active then NewPlayerQuick.Exit else NewPlayerQuick.Enter
	local ok, reason = pcall(unavailable, command)
	local blocked = if ok and type(reason) == "string" and reason ~= "" then reason else nil
	return {
		command = command,
		text = if active then NewPlayerQuick.Copy.Exit else NewPlayerQuick.Copy.Enter,
		color = if active then "green" else "yellow",
		enabled = blocked == nil,
		reason = blocked,
	}
end

-- True when two rects intersect with a positive area.
local function overlaps(a: Rect, b: Rect?): boolean
	if b == nil then
		return false
	end
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end
NewPlayerQuick.overlaps = overlaps

--[[
	Where the chip goes (design px), see the header.
	@param input ChipInput
	@return Rect (always on the canvas, never left of the margin)
	Example: chipRect({ canvas = Vector2.new(1920, 1080), safeTop = 58, margin = 16, gap = 10,
		size = Vector2.new(300, 64), adminChip = { x = 1840, y = 70, w = 64, h = 64 } })
		--> { x = 1530, y = 70, w = 300, h = 64 }
]]
function NewPlayerQuick.chipRect(input: ChipInput): Rect
	local w, h = input.size.X, input.size.Y
	local anchorRight: number
	local rowTop: number
	local rowBottom: number
	local wrench = input.adminChip
	if wrench ~= nil then
		anchorRight = wrench.x - input.gap
		rowTop = wrench.y + math.floor((wrench.h - h) / 2)
		rowBottom = wrench.y + wrench.h
	else
		anchorRight = input.canvas.X - input.margin
		rowTop = input.safeTop + input.margin
		rowBottom = rowTop
	end
	-- A: on the wrench's row, left of it.
	local rect: Rect = { x = anchorRight - w, y = rowTop, w = w, h = h }
	if rect.x >= input.margin and not overlaps(rect, input.top) then
		return rect
	end
	-- A': shrink into the gap between the currency stack and the wrench, still on the row.
	local top = input.top
	local minWidth = input.minWidth
	if minWidth ~= nil and top ~= nil then
		local left = math.max(input.margin, top.x + top.w + input.gap)
		local width = math.min(w, anchorRight - left)
		local shrunk: Rect = { x = anchorRight - width, y = rowTop, w = width, h = h }
		if width >= minWidth and not overlaps(shrunk, top) then
			return shrunk
		end
	end
	-- B: below the wrench, right-aligned with it.
	local below = rowBottom
	local right = if wrench ~= nil then wrench.x + wrench.w else input.canvas.X - input.margin
	rect = { x = right - w, y = below + input.gap, w = w, h = h }
	-- A currency stack reaching that low (narrow screens): go under it too.
	if top ~= nil and overlaps(rect, top) then
		rect.y = top.y + top.h + input.gap
	end
	-- The offer column below the wrench: step left of it.
	local column = input.right
	if column ~= nil and overlaps(rect, column) then
		rect.x = column.x - input.gap - w
	end
	rect.x = math.max(input.margin, rect.x)
	rect.y = math.clamp(rect.y, 0, math.max(0, input.canvas.Y - h))
	return rect
end

return table.freeze(NewPlayerQuick)
