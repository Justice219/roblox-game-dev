--!strict
--[[
	LauncherStuds — adds the stud material to a Components.button face (ported from RoBeasts).

	Purpose:
		Plain Components.button faces (framework-level buttons such as the touch CLOSE button or
		screens that do not use StudUI.button) get the same quiet stud emboss as every other
		surface. One full-size ImageLabel sibling follows the face through layout and the hover /
		press scale; it is inert (not Active / Selectable) and fades with Components.setButtonDimmed.

	Connects to: Widgets/StudTexture, Shared/Config/PanelTextureAssets, UI/ScreenManager (touch
	close), any screen with a raw Components.button.

	Example: LauncherStuds.attach(Components.button({ text = "OK" }))
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Config.PanelTextureAssets)
local Create = require(script.Parent.Parent.Create)
local StudTexture = require(script.Parent.StudTexture)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local LauncherStuds = {}

-- Stud opacity on a launcher face (the label must stay readable through it).
local TRANSPARENCY = UIStyleConfig.StudTransparency.Button

--[[
	Attaches the stud overlay to a Components.button (idempotent).
	@param button a Components.button (must have its "Face" child)
	@param tileSize optional tile size in design px (default UIStyleConfig.StudTile.Button)
]]
function LauncherStuds.attach(button: TextButton, tileSize: number?)
	if button:FindFirstChild("LauncherStudAccent") ~= nil then
		return
	end
	local face = button:FindFirstChild("Face")
	if face == nil or not face:IsA("TextLabel") then
		warn("[LauncherStuds] attach() needs a Components.button with a Face child")
		return
	end
	local corner = face:FindFirstChildOfClass("UICorner")
	local tile = tileSize or UIStyleConfig.StudTile.Button
	local image = Create.new("ImageLabel", {
		Name = "LauncherStudAccent",
		Image = Assets.StudImage,
		ImageColor3 = Color3.new(1, 1, 1),
		ImageTransparency = TRANSPARENCY,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromOffset(tile, tile),
		Active = false,
		Selectable = false,
		ZIndex = face.ZIndex + 1,
		Parent = button,
		Children = {
			Create.new("UICorner", { CornerRadius = if corner ~= nil then corner.CornerRadius else UDim.new(0, 8) }),
		},
	}) :: ImageLabel
	image:SetAttribute("Decorative", true)
	local release = StudTexture.bind(image)
	-- Follow the face's disabled fade (Components.setButtonDimmed).
	local function refresh()
		image.ImageTransparency = 1 - (1 - TRANSPARENCY) * (1 - face.BackgroundTransparency)
	end
	local dimmed = face:GetPropertyChangedSignal("BackgroundTransparency"):Connect(refresh)
	image.Destroying:Once(function()
		release()
		dimmed:Disconnect()
	end)
	refresh()
end

return table.freeze(LauncherStuds)
