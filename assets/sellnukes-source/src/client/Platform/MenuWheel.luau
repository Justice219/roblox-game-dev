--!strict
--[[
	MenuWheel — the quick menu (spec §16 "Menu wheel = ButtonSelect"): every HUD screen as a ring
	of stud tiles inside a StudUI window, so a controller player reaches any menu with one button
	and the stick / D-pad. Also opens with M on a keyboard and works with a finger.

	Contents: the HUD's left-stack rows in their order (HudZonesConfig.Left, owner R62: Shop, Pets,
	Rewards, Rebirth, Teleport, Attack, Event; same labels / icons / colours as the HUD tiles), the
	admin chip's entry for admins (HudZonesConfig.AdminChip, IsAdmin attribute; the server
	re-authorises every admin action) plus PlatformConfig.MenuWheel.Extra (Settings) when that
	screen is registered.
	Rows the HUD hides follow the same rules: Attack only after the launcher is built
	(ActionMap context AttackUnlocked), Event only while EventLive is on; other hidden rows stay
	out. The ring is rebuilt on every open (cheap: ≤ 13 tiles), so it always matches the HUD.

	Controls: View / Select or M toggles (Platform/ActionMap "Menu"); the cursor starts on Shop;
	A / click / tap opens that screen (the wheel closes first); B / X / the red X close.
	Navigation is geometric around the ring (the engine picks the nearest tile in the pushed
	direction), trapped inside the window.

	Connects to: Platform/{ActionMap, LayoutLogic, GamepadNav}, Shared/Config/{PlatformConfig,
	HudZonesConfig, UIStyleConfig}, UI/{Kit/StudUI, ScreenManager}.

	Example: ScreenManager.toggle("MenuWheel")
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionMap = require(script.Parent.ActionMap)
local Create = require(script.Parent.Parent.UI.Create)
local GamepadNav = require(script.Parent.GamepadNav)
local HudZonesConfig = require(ReplicatedStorage.Shared.Config.HudZonesConfig)
local LayoutLogic = require(script.Parent.LayoutLogic)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Config = PlatformConfig.MenuWheel

export type Item = { key: string, label: string, icon: string, color: string, screen: string }

local MenuWheel = {}

MenuWheel.Name = "MenuWheel"

--[[
	The items the wheel shows right now (rules in the module header), in ring order.
	Example: MenuWheel.items()[1].key --> "Shop"
]]
function MenuWheel.items(): { Item }
	local items: { Item } = {}
	for _, row in HudZonesConfig.Left do
		local show = row.hidden ~= true
		if row.key == "Attack" then
			show = ActionMap.context("AttackUnlocked")
		elseif row.key == "Event" then
			show = ActionMap.context("EventLive")
		end
		if show then
			table.insert(
				items,
				{ key = row.key, label = row.label, icon = row.icon, color = row.color, screen = row.screen }
			)
		end
	end
	-- R62: Admin left the stack for the top-right chip; admins still reach it from the wheel.
	local admin = HudZonesConfig.AdminChip
	if Players.LocalPlayer ~= nil and Players.LocalPlayer:GetAttribute("IsAdmin") == true then
		table.insert(
			items,
			{ key = admin.key, label = admin.label, icon = admin.icon, color = admin.color, screen = admin.screen }
		)
	end
	for _, extra in Config.Extra do
		if ScreenManager.isRegistered(extra.screen) then
			table.insert(items, {
				key = extra.key,
				label = extra.label,
				icon = extra.icon,
				color = extra.color,
				screen = extra.screen,
			})
		end
	end
	return items
end

MenuWheel.screen = StudUI.modalScreen({
	name = MenuWheel.Name,
	title = "Menu",
	color = "teal",
	icon = "Star",
	size = Config.Size,
	build = function(window: StudUI.Window, _gui: ScreenGui): ScreenManager.ScreenHandle?
		-- The ring lives in a square frame centred in the body.
		local ring = Create.new("Frame", {
			Name = "Ring",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			Parent = window.body,
		}) :: Frame
		GamepadNav.trap(ring)
		StudUI.text({
			name = "Centre",
			text = "Pick a menu!",
			textSize = 40,
			anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.5),
			size = UDim2.fromOffset(320, 60),
			parent = ring,
		})
		local tiles: { StudUI.HudButton } = {}

		-- Rebuilds the tiles for the current items.
		local function rebuild()
			for _, tile in tiles do
				tile.Destroy()
			end
			table.clear(tiles)
			local items = MenuWheel.items()
			local side = LayoutLogic.ringTile(
				#items,
				Config.Radius,
				Config.TileGap,
				UIStyleConfig.Hud.MinButtonSize,
				Config.TileMax
			)
			for index, offset in LayoutLogic.ring(#items, Config.Radius) do
				local item = items[index]
				local tile = StudUI.hudButton({
					name = `Wheel_{item.key}`,
					label = item.label,
					icon = item.icon,
					color = item.color :: any,
					size = Vector2.new(side, side),
					layoutOrder = index,
					parent = ring,
					onActivated = function()
						ScreenManager.close(MenuWheel.Name)
						ScreenManager.open(item.screen)
					end,
				})
				tile.instance.AnchorPoint = Vector2.new(0.5, 0.5)
				tile.instance.Position = UDim2.new(0.5, offset.x, 0.5, offset.y)
				table.insert(tiles, tile)
			end
		end

		return {
			onOpen = function()
				rebuild()
				ScreenManager.refreshSelection()
			end,
			defaultSelection = function(): GuiObject?
				local first = tiles[1]
				return if first ~= nil then first.instance else nil
			end,
		}
	end,
})

return MenuWheel
