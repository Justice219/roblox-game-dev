--!strict
--[[
	EntryButton — the Flavour Book's way in from an existing window (owner R89; owner rule: no new
	left-stack HUD button). A rainbow stud "FLAVOURS" button with a red "!" while a discovery reward
	is ready; pressing it hands off to the Flavour Book (ScreenManager.handoff: the host window hides
	while the Book is open and comes back — selection restored — when it closes).

	Lives inside Screens/FlavorBook (a ModuleScript folder), so UIController never registers it as a
	screen. Used by Screens/Pets/PetsScreen (top bar, next to the tabs).

	The badge re-evaluates only on profile pushes that touch `flavors` (no polling).

	Connects to: UI/{ScreenManager, Create, Kit/StudUI}, Client/ClientState, Shared/Config/FlavorConfig,
	Shared/Tycoon/FlavorLogic.

	Example: FlavorBookEntry.attach(topBar, 5, "Pets", UDim2.fromOffset(200, 72))
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Parent.Create)
local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local FlavorLogic = require(ReplicatedStorage.Shared.Tycoon.FlavorLogic)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)

local EntryButton = {}

--[[
	Adds the FLAVOURS button to `parent`.
	@param parent Instance — the host's bar (a layout frame)
	@param layoutOrder number
	@param host string — the host screen's ScreenManager name (handoff source)
	@param size UDim2 — the button size (>= 44 pt on phones: the host's tab size)
	@return StudUI.Button
]]
function EntryButton.attach(parent: Instance, layoutOrder: number, host: string, size: UDim2): StudUI.Button
	local button = StudUI.button({
		name = "FlavorBook",
		text = FlavorConfig.Text.BookButton,
		color = "rainbow",
		size = size,
		textSize = 28,
		layoutOrder = layoutOrder,
		parent = parent,
		onActivated = function()
			ScreenManager.handoff(host, FlavorConfig.BookScreen, { source = string.lower(host) })
		end,
	})
	-- Red "!" badge (top-right corner) while a discovery reward is ready.
	local badge = Create.new("Frame", {
		Name = "Badge",
		BackgroundColor3 = Color3.fromRGB(232, 52, 52),
		Size = UDim2.fromOffset(34, 34),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -6, 0, 6),
		ZIndex = 20,
		Visible = false,
		Parent = button.instance,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			Create.new("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2 }),
		},
	}) :: Frame
	StudUI.text({
		text = "!",
		textSize = 26,
		font = "shout",
		size = UDim2.fromScale(1, 1),
		zIndex = 21,
		parent = badge,
	})
	-- Visible only while Surprise Batches are on (FlavorConfig.isEnabled: the server's attribute,
	-- else the ship default) — switched off, the Pets window looks exactly as before R89.
	local function refresh()
		local on = FlavorConfig.isEnabled()
		button.instance.Visible = on
		local profile: any = ClientState.profile
		badge.Visible = on and FlavorLogic.claimableCount(if type(profile) == "table" then profile.flavors else nil) > 0
	end
	ClientState.ProfileChanged:Connect(function(_profile: any, fields: { string }?)
		if fields == nil or table.find(fields, "flavors") ~= nil then
			refresh()
		end
	end)
	ReplicatedStorage:GetAttributeChangedSignal(FlavorConfig.Attr.Enabled):Connect(refresh)
	refresh()
	return button
end

return EntryButton
