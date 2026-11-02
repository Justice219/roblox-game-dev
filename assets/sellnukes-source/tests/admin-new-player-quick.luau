--!strict
--[[
	Admin "PLAY AS NEW PLAYER" quick controls (owner R67). Run:
		lune run tests/admin-new-player-quick

	Proves on the shipped modules (src/client/UI/Screens/Admin/NewPlayerQuick,
	src/shared/Config/AdminConfig, src/shared/Util/NewPlayerMode):
	  1. The header button sends the EXISTING commands (NewPlayerMode / ExitNewPlayerMode exist,
	     are confirmed + audited + cooled down, target nobody) — no new server path.
	  2. headerAction: off → yellow PLAY AS NEW PLAYER; on → green EXIT NEW PLAYER MODE; a server
	     availability reason disables it (and is passed through); a throwing lookup never breaks it.
	  3. chipRect: left of the wrench chip (HudZones "TopRight") on its row; below the wrench when
	     the currency stack takes the row spot; left of the offer column; never off-canvas or left of the margin; the
	     corner fallback without a wrench chip.
]]

local Loader = require("./fixtures/RobloxLoader")
local roblox = require("@lune/roblox")

local loader = Loader.new()
local AdminConfig = loader.load("src/shared/Config/AdminConfig")
local NewPlayerMode = loader.load("src/shared/Util/NewPlayerMode")
local NewPlayerQuick = loader.load("src/client/UI/Screens/Admin/NewPlayerQuick")

local Vector2 = roblox.Vector2

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- 1. The existing commands ---------------------------------------------------------------------------
for _, name in { NewPlayerQuick.Enter, NewPlayerQuick.Exit } do
	local def = AdminConfig.Commands[name]
	check(def ~= nil, `{name} is an AdminConfig command`)
	check(def.confirm == true and def.audited == true and (def.cooldown or 0) > 0, `{name}: confirm + audit + cooldown`)
	check(def.target == "None" and next(def.args) == nil, `{name}: no target, no args`)
end
check(
	string.upper(AdminConfig.Commands[NewPlayerQuick.Enter].label) == NewPlayerQuick.Copy.Enter
		and string.upper(AdminConfig.Commands[NewPlayerQuick.Exit].label) == NewPlayerQuick.Copy.Exit,
	"button text = the commands' labels"
)
check(NewPlayerMode.Attribute == "NewPlayerMode", "the mode attribute")

-- 2. headerAction ------------------------------------------------------------------------------------
do
	local free = function(): string?
		return nil
	end
	local off = NewPlayerQuick.headerAction(false, free)
	check(off.command == "NewPlayerMode" and off.color == "yellow" and off.enabled, "off: yellow PLAY AS NEW PLAYER")
	check(off.text == "PLAY AS NEW PLAYER", "off text")
	local on = NewPlayerQuick.headerAction(true, free)
	check(on.command == "ExitNewPlayerMode" and on.color == "green" and on.enabled, "on: green EXIT")
	local asked: string? = nil
	local blocked = NewPlayerQuick.headerAction(false, function(name: string): string?
		asked = name
		return "waiting for the server"
	end)
	check(asked == "NewPlayerMode", "availability is asked for the command it would send")
	check(not blocked.enabled and blocked.reason == "waiting for the server", "unavailable: disabled + reason")
	local empty = NewPlayerQuick.headerAction(false, function(): string?
		return ""
	end)
	check(empty.enabled, "an empty reason means available")
	local broken = NewPlayerQuick.headerAction(true, function(): string?
		error("boom")
	end)
	check(broken.enabled and broken.command == "ExitNewPlayerMode", "a throwing lookup never blocks EXIT")
end

-- 3. chipRect ------------------------------------------------------------------------------------------
do
	local canvas = Vector2.new(1920, 1080)
	local wrench = { x = 1840, y = 70, w = 64, h = 64 }
	local base = {
		canvas = canvas,
		safeTop = 58,
		margin = 12,
		gap = 10,
		size = Vector2.new(400, 66),
		adminChip = wrench,
	}
	local rect = NewPlayerQuick.chipRect(base :: any)
	check(rect.x == wrench.x - 10 - 400 and rect.y == wrench.y - 1, `desktop: left of the wrench ({rect.x}, {rect.y})`)
	check(not NewPlayerQuick.overlaps(rect, wrench), "never on the wrench")

	-- Phone: a wide currency stack reaches the wrench's row → below the wrench, right-aligned.
	local phone = table.clone(base) :: any
	phone.canvas = Vector2.new(1300, 600)
	phone.adminChip = { x = 1220, y = 50, w = 70, h = 70 }
	phone.top = { x = 500, y = 40, w = 700, h = 60 }
	phone.size = Vector2.new(400, 70)
	rect = NewPlayerQuick.chipRect(phone)
	check(rect.y >= 50 + 70 + 10, `phone: below the wrench (y {rect.y})`)
	check(rect.x + rect.w == 1220 + 70, "phone: right-aligned with the wrench")
	check(
		not NewPlayerQuick.overlaps(rect, phone.top) and not NewPlayerQuick.overlaps(rect, phone.adminChip),
		"phone: clear of the currency stack and the wrench"
	)

	-- Phone with minWidth: a stack ending at x = 900 leaves 300 px left of the wrench (gap 10) →
	-- the chip shrinks onto the row instead of dropping onto the playfield.
	local shrink = table.clone(phone) :: any
	shrink.top = { x = 400, y = 40, w = 500, h = 60 }
	shrink.minWidth = 280
	rect = NewPlayerQuick.chipRect(shrink)
	check(rect.y == 50 and rect.x == 910 and rect.w == 300, `shrinks on the row ({rect.x}, {rect.y}, {rect.w})`)
	check(not NewPlayerQuick.overlaps(rect, shrink.top), "shrunk chip clear of the stack")
	local tooNarrow = table.clone(shrink) :: any
	tooNarrow.minWidth = 320
	rect = NewPlayerQuick.chipRect(tooNarrow)
	check(rect.y >= 50 + 70 + 10, "no room even shrunk: below the wrench")

	-- The offer column right under the wrench: step left of it.
	local offers = table.clone(phone) :: any
	offers.right = { x = 1100, y = 130, w = 190, h = 400 }
	rect = NewPlayerQuick.chipRect(offers)
	check(not NewPlayerQuick.overlaps(rect, offers.right), "clear of the offer column")
	check(rect.x + rect.w <= 1100 - 10 + 1e-9, "left of the offer column")

	-- The currency stack in the way on the row (a narrow screen).
	local narrow = table.clone(base) :: any
	narrow.top = { x = 1200, y = 60, w = 600, h = 90 }
	rect = NewPlayerQuick.chipRect(narrow)
	check(not NewPlayerQuick.overlaps(rect, narrow.top), "clear of the currency stack")

	-- No wrench chip: the top-right corner under the top bar.
	local corner = table.clone(base) :: any
	corner.adminChip = nil
	rect = NewPlayerQuick.chipRect(corner)
	check(rect.x + rect.w == 1920 - 12 and rect.y == 58 + 12, "corner fallback")

	-- Tiny canvas: never left of the margin, never off the bottom.
	local tiny = table.clone(phone) :: any
	tiny.canvas = Vector2.new(420, 150)
	tiny.adminChip = { x = 340, y = 20, w = 70, h = 70 }
	tiny.top = { x = 0, y = 10, w = 330, h = 90 }
	rect = NewPlayerQuick.chipRect(tiny)
	check(rect.x >= 12 and rect.y + rect.h <= 150, `tiny canvas clamps ({rect.x}, {rect.y})`)
end

print(`[admin-new-player-quick] {checks} checks passed`)
