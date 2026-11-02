--!strict
--[[
	HudWhatsNew — the HUD's bottom-right WHAT'S NEW chip (owner R58: "You can put it in like the
	bottom right ... Don't clog up the left UI too much more than it already is").

	Look: one purple stud button "[star] WHAT'S NEW" with a red "NEW" badge on its top-right corner
	while a change note is unseen (ChangeNotes/ChangeNotesClient.hasUnseen). Pressing it opens the
	WHAT'S NEW panel (ChangeNotesClient.openMenu → Screens/WhatsNew, source "menu").

	Placement: Hud.relayout asks `size(touch, pointScale)` for the chip's design size, passes it
	to Widgets/HudPlacement.compute as `corner` (the offer column's band shrinks for it) and then
	calls `place(rect)` with the returned `layout.corner`: right-aligned at the side margin, its
	bottom on the bottom margin (desktop / console: inside the TV-safe area, which the HUD canvas
	already excludes) or just above the jump-button / thumbstick reserve on touch devices. Hud
	grows the published "Right" HudZones rect over it, so TouchButtons / HintBar / overlays avoid it.

	Phones (owner R59: the HUD covered too much of small screens): `size(touch, pointScale, true)`
	makes it an icon-only square star button at the 44 pt tap, and the "NEW" pill becomes a small
	red dot; the press, the unseen logic and the gamepad link are exactly the same.

	Console + mobile (owner R11): touch height ≥ the 44 pt tap and text ≥ 14 pt (both from the
	device's points per design px); the button is a regular StudUI stud button (gamepad-selectable, hover / press
	feedback, the kit's selection ring). Gamepad reach: Hud passes `button()` to
	HudOffers.linkNav as its `downExit` (D-pad Down from the last offer lands here, Up goes back).

	Performance: the button is rebuilt only when its size class changes (device / rotation); the
	badge toggles on ChangeNotesClient.Changed (event-driven, no polling).

	Connects to: Kit/StudUI, UI/Widgets/StudWindow (badge outline), ChangeNotes/ChangeNotesClient,
	Shared/Util/TouchLayout + Shared/Config/TouchUIConfig (tap / text minimums),
	Hud (owner), Widgets/HudPlacement (corner rect).

	Example (Hud.build / relayout):
		local whatsNew = HudWhatsNew.new(frame)
		local layout = HudPlacement.compute({ ..., corner = whatsNew.size(touch, ScreenManager.pointScale()) })
		whatsNew.place(layout.corner)
]]

local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ChangeNotesClient = require(script.Parent.Parent.Parent.ChangeNotes.ChangeNotesClient)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)
local Create = require(script.Parent.Parent.Create)
local HudPlacement = require(script.Parent.Parent.Widgets.HudPlacement)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type HudWhatsNew = {
	-- The chip's design size for this device (touch: ≥ 44 pt tall, text ≥ 14 pt at `pointScale`
	-- device points per design px). `compact` (phones, owner R59) = the icon-only square.
	size: (touch: boolean, pointScale: number, compact: boolean?) -> Vector2,
	-- Places (and if its size changed, rebuilds) the chip; nil hides it.
	place: (rect: HudPlacement.Rect?) -> (),
	-- The selectable button (nil before the first place): HudOffers.linkNav's `downExit`.
	button: () -> GuiObject?,
}

local HudWhatsNew = {}

local LABEL = "WHAT'S NEW"
local ICON = "Star"
-- Authored chip height / text size (desktop / console, design px).
local HEIGHT = 60
local TEXT_SIZE = 30
-- Room besides the label: icon (Style.IconFill.Button of the height) + list padding + side padding.
local ICON_FILL = UIStyleConfig.IconFill.Button
local CONTENT_GAP = 8
local SIDE_PAD = 10
-- Smallest readable text on phones / tablets (owner R11 / docs/platform.md §7).
local MIN_TEXT_POINTS = 14
-- The NEW badge: text size (≥ 14 pt on phones after the HUD scale) and its padding.
local BADGE_TEXT = 24
local BADGE_PAD = Vector2.new(20, 12)
-- Phones (R59): the NEW dot's side as a share of the square button (never under DOT_MIN px).
local DOT_SHARE = 0.32
local DOT_MIN = 20

--[[
	Builds the chip (hidden until the first place). One per HUD.
	@param parent the HUD root frame
	@return HudWhatsNew handle
]]
function HudWhatsNew.new(parent: Frame): HudWhatsNew
	local holder = Create.new("Frame", {
		Name = "WhatsNewChip",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 0),
		Visible = false,
		ZIndex = 4,
		Parent = parent,
	}) :: Frame
	local current: StudUI.Button? = nil
	local builtSize: Vector2? = nil
	local builtText = 0
	local builtCompact = false
	-- The text size the last size() call chose for this device (place() builds with it).
	local wantedText = TEXT_SIZE
	-- Whether the last size() call asked for the phone icon-only square (R59).
	local wantedCompact = false

	-- The NEW badge (outlined red pill over the chip's top-right corner).
	local badgeSize = Vector2.new(0, 0)
	local badge = Create.new("Frame", {
		Name = "NewBadge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = UIStyleConfig.Colors.red.bottom,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 9,
		Parent = holder,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
	}) :: Frame
	StudWindow.edge(badge, 3)
	local badgeLabel = StudUI.text({
		name = "BadgeText",
		text = "NEW",
		textSize = BADGE_TEXT,
		size = UDim2.fromScale(1, 1),
		zIndex = 10,
		parent = badge,
	})

	-- Shows the badge while a note is unseen.
	local function refreshBadge()
		badge.Visible = ChangeNotesClient.hasUnseen()
	end

	-- (Re)builds the stud button at `size` with `textSize` (rare: a size class change);
	-- `compact` = the phone icon-only square with the NEW dot.
	local function build(size: Vector2, textSize: number, compact: boolean)
		local old = current
		if old ~= nil then
			old.Destroy()
		end
		local button = StudUI.button({
			name = "WhatsNewButton",
			text = if compact then "" else LABEL,
			icon = ICON,
			color = "purple",
			textSize = textSize,
			size = UDim2.fromOffset(size.X, size.Y),
			parent = holder,
			onActivated = function()
				ChangeNotesClient.openMenu()
			end,
		})
		current = button
		builtSize = size
		builtText = textSize
		builtCompact = compact
		if compact then
			-- The NEW dot: a plain outlined red circle on the top-right corner (no text).
			local side = math.max(DOT_MIN, math.floor(size.Y * DOT_SHARE))
			badgeLabel.Visible = false
			badgeSize = Vector2.new(side, side)
			badge.Size = UDim2.fromOffset(side, side)
			badge.Position = UDim2.new(1, -side * 0.25, 0, side * 0.25)
			return
		end
		badgeLabel.Visible = true
		-- The badge sits on the button's top-right corner, scaled with the text.
		local text = math.max(BADGE_TEXT, math.floor(textSize * 0.8))
		badgeLabel.TextSize = text
		local bounds = TextService:GetTextSize("NEW", text, Enum.Font.FredokaOne, Vector2.new(1000, 1000))
		badgeSize = Vector2.new(math.ceil(bounds.X) + BADGE_PAD.X, math.ceil(bounds.Y) + BADGE_PAD.Y)
		badge.Size = UDim2.fromOffset(badgeSize.X, badgeSize.Y)
		badge.Position = UDim2.new(1, -badgeSize.X * 0.3, 0, 2)
	end

	local handle: HudWhatsNew = {
		size = function(touch: boolean, pointScale: number, compact: boolean?): Vector2
			local points = math.max(pointScale, 0.01)
			local minTap = if touch then TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, points) else 0
			local minText = if touch then TouchLayout.pointsToDesign(MIN_TEXT_POINTS, points) else 0
			wantedCompact = compact == true
			if wantedCompact then
				-- Phones: the icon-only square at the 44 pt tap (never under the authored height).
				local side = math.ceil(math.max(minTap, HEIGHT))
				return Vector2.new(side, side)
			end
			local height = math.max(HEIGHT, minTap)
			local textSize = math.max(TEXT_SIZE, math.ceil(minText))
			local bounds = TextService:GetTextSize(LABEL, textSize, Enum.Font.FredokaOne, Vector2.new(2000, 1000))
			local icon = math.floor(height * ICON_FILL)
			-- Label + icon + the list gap + both side paddings + a little slack for the text outline.
			local width = math.ceil(bounds.X) + icon + CONTENT_GAP + 2 * SIDE_PAD + 16
			wantedText = textSize
			return Vector2.new(width, height)
		end,
		place = function(rect: HudPlacement.Rect?)
			if rect == nil then
				holder.Visible = false
				return
			end
			local size = Vector2.new(rect.w, rect.h)
			if current == nil or builtSize ~= size or builtText ~= wantedText or builtCompact ~= wantedCompact then
				build(size, wantedText, wantedCompact)
			end
			holder.Position = UDim2.fromOffset(rect.x, rect.y)
			holder.Size = UDim2.fromOffset(rect.w, rect.h)
			holder.Visible = true
			refreshBadge()
		end,
		button = function(): GuiObject?
			local button = current
			return if button ~= nil then button.instance else nil
		end,
	}
	ChangeNotesClient.Changed:Connect(refreshBadge)
	-- Idempotent: the boot controller normally started it already (a reader may start it too).
	ChangeNotesClient.start()
	return handle
end

return table.freeze(HudWhatsNew)
