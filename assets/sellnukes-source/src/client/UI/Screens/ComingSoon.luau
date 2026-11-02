--!strict
--[[
	ComingSoon — the tidy stud "Coming soon" window shown for any screen that is not built yet.

	Purpose:
		HUD buttons and offers open screens by name (ScreenManager.open("Pets")). Screens are
		added by later builders; until a screen exists, ScreenManager's fallback opens THIS
		window with `{ requested = "Pets" }`, so a press never does nothing. It names the
		feature ("Pets"), says it is on its way, and has a green OKAY button (X / B close too).
		When the real screen module lands under UI/Screens, the fallback simply stops being used.

	Connects to: Kit/StudUI.modalScreen, UI/ScreenManager (setFallback, by UIController),
	Shared/Config/HudZonesConfig (friendly names / icons of HUD rows).

	Example: ScreenManager.open("Pets") -- shows "Pets — Coming soon!" until Screens/Pets exists
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Create)
local HudZonesConfig = require(ReplicatedStorage.Shared.Config.HudZonesConfig)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)

local NAME = "ComingSoon"

-- Friendly label for a requested screen: the HUD row label when one opens it, else the screen
-- name split at capitals ("GroupRewards" -> "Group Rewards"). Only known characters are kept.
local function friendlyName(requested: string): string
	for _, row in HudZonesConfig.Left do
		if row.screen == requested then
			return row.label
		end
	end
	local spaced = string.gsub(requested, "(%l)(%u)", "%1 %2")
	local clean = string.gsub(spaced, "[^%w ]", "")
	return if clean ~= "" then string.sub(clean, 1, 32) else "This feature"
end

return StudUI.modalScreen({
	name = NAME,
	title = "Coming Soon",
	color = "blue",
	icon = "Star",
	size = Vector2.new(860, 470),
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		local body = window.body
		Create.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 14),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = body,
		})
		local headline = StudUI.text({
			name = "Headline",
			text = "Coming soon!",
			textSize = 72,
			font = "shout",
			color = Color3.fromRGB(255, 226, 80),
			size = UDim2.new(1, 0, 0, 84),
			layoutOrder = 1,
			parent = body,
		})
		local detail = StudUI.text({
			name = "Detail",
			text = "",
			textSize = 34,
			wrap = true,
			size = UDim2.new(1, -40, 0, 90),
			layoutOrder = 2,
			parent = body,
		})
		local okay = StudUI.button({
			text = "OKAY",
			color = "green",
			size = UDim2.fromOffset(280, 72),
			layoutOrder = 3,
			parent = body,
			onActivated = function()
				ScreenManager.close(NAME)
			end,
		})
		return {
			onOpen = function(args: any?)
				local requested = if type(args) == "table" and type(args.requested) == "string"
					then args.requested
					else ""
				local label = friendlyName(requested)
				window.setTitle(label)
				headline.Text = "Coming soon!"
				detail.Text = `{label} is being built right now. Check back soon!`
			end,
			defaultSelection = function(): GuiObject?
				return okay.instance
			end,
		}
	end,
})
