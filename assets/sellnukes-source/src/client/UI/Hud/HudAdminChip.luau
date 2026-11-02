--!strict
--[[
	HudAdminChip — the admin wrench chip in the HUD's top-right corner (owner R62, 2026-10-31: the
	left stack shrank to six buttons, so Admin left it for a small chip).

	Look: one small grey stud button with the Admin (wrench) icon, no label, right under the Roblox
	top bar at the side margin (Widgets/HudPlacement.chipRect; the offer column starts below it).
	Visible only while the server-set IsAdmin attribute is true (Hud drives `setVisible`); the
	press toggles the admin panel (HudZonesConfig.AdminChip.screen) like a left button does.
	Display only: every admin action is re-authorised on the server (AdminService).

	Console + mobile (owner R11): desktop / console = AdminChip.Size design px; touch devices grow it
	to the 44 pt tap. It is a regular StudUI stud button (gamepad-selectable, press feedback); Down
	goes to the first offer (Hud links it). Admins on a controller also reach the panel through the
	menu wheel (Platform/MenuWheel lists the chip for admins) and AdminConfig.OpenKeys.

	Performance: built once; rebuilt only when its size changes (device / rotation).

	Connects to: Kit/StudUI, UI/ScreenManager, Shared/Config/{HudZonesConfig, TouchUIConfig},
	Shared/Util/TouchLayout, UI/Hud/Hud (owner), Widgets/HudPlacement (chip rect).

	Example (Hud):
		local chip = HudAdminChip.new(frame)
		chip.setVisible(player:GetAttribute("IsAdmin") == true)
		local layout = HudPlacement.compute({ ..., chip = if chip.visible() then chip.size(touch, scale) else nil })
		chip.place(layout.chip)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HudPlacement = require(script.Parent.Parent.Widgets.HudPlacement)
local HudZonesConfig = require(ReplicatedStorage.Shared.Config.HudZonesConfig)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)

export type HudAdminChip = {
	-- The chip's design size on this device (touch: >= the 44 pt tap at `pointScale`).
	size: (touch: boolean, pointScale: number) -> Vector2,
	-- Places (rebuilding on a size change) or, with nil, hides the chip.
	place: (rect: HudPlacement.Rect?) -> (),
	setVisible: (on: boolean) -> (),
	visible: () -> boolean,
	-- The selectable button (nil before the first place / while hidden).
	button: () -> GuiObject?,
}

local Chip = HudZonesConfig.AdminChip

local HudAdminChip = {}

--[[
	Builds the chip holder under the HUD root (hidden until placed while visible).
	@param parent the HUD root frame
	@return HudAdminChip handle
]]
function HudAdminChip.new(parent: Frame): HudAdminChip
	local holder = Instance.new("Frame")
	holder.Name = "AdminChip"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(0, 0)
	holder.Visible = false
	holder.ZIndex = 4
	holder.Parent = parent
	local current: StudUI.Button? = nil
	local builtSize: Vector2? = nil
	local shown = false

	-- (Re)builds the icon-only stud button at `size` (rare: a size change).
	local function build(size: Vector2)
		local old = current
		if old ~= nil then
			old.Destroy()
		end
		current = StudUI.button({
			name = `Hud_{Chip.key}`,
			text = "",
			icon = Chip.icon,
			color = Chip.color,
			size = UDim2.fromOffset(size.X, size.Y),
			parent = holder,
			onActivated = function()
				-- Same as a left button: toggles its screen, replacing any open window.
				if ScreenManager.isOpen(Chip.screen) then
					ScreenManager.close(Chip.screen)
				else
					ScreenManager.closeAllModals()
					ScreenManager.open(Chip.screen)
				end
			end,
		})
		builtSize = size
	end

	return {
		size = function(touch: boolean, pointScale: number): Vector2
			local minTap = if touch
				then TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, math.max(pointScale, 0.01))
				else 0
			local side = math.ceil(math.max(Chip.Size, minTap))
			return Vector2.new(side, side)
		end,
		place = function(rect: HudPlacement.Rect?)
			if rect == nil or not shown then
				holder.Visible = false
				return
			end
			local size = Vector2.new(rect.w, rect.h)
			if current == nil or builtSize ~= size then
				build(size)
			end
			holder.Position = UDim2.fromOffset(rect.x, rect.y)
			holder.Size = UDim2.fromOffset(rect.w, rect.h)
			holder.Visible = true
		end,
		setVisible = function(on: boolean)
			shown = on
			if not on then
				holder.Visible = false
			end
		end,
		visible = function(): boolean
			return shown
		end,
		button = function(): GuiObject?
			local button = current
			return if button ~= nil and holder.Visible then button.instance else nil
		end,
	}
end

return table.freeze(HudAdminChip)
