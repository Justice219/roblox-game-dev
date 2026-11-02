--!strict
--[[
	ModalStudSurfaces — retrofits the stud look onto a hand-built modal panel (ported from
	RoBeasts, re-coloured for SellNukes).

	Purpose:
		New screens use Kit/StudUI.window, which already draws the full look. A screen that builds
		its own panel (custom layouts, ported RoBeasts screens) calls this once to get the same
		surfaces: a faint stud emboss on the slate body and a coloured, drifting stud header plate
		behind its title label. Existing colours, buttons and content are untouched; the plates
		sit at ZIndex 0 under the panel's own content.

	Connects to: Widgets/StudWindow (surfaces), Shared/Config/UIStyleConfig, Kit/StudUI (same look).

	Example:
		local surfaces = ModalStudSurfaces.new(panel, titleLabel, "blue")
		-- panel teardown releases everything (or surfaces.Destroy())
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Create)
local PanelBackdrop = require(script.Parent.PanelBackdrop)
local StudWindow = require(script.Parent.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type Handle = { Destroy: () -> () }

local ModalStudSurfaces = {}

--[[
	Adds the body emboss and a header plate sized to reach just below `title`.
	@param panel the modal's main panel
	@param title the title label (the plate follows its position / size)
	@param color header ColorName (default "blue")
	@return Handle
]]
function ModalStudSurfaces.new(panel: Frame, title: TextLabel, color: UIStyleConfig.ColorName?): Handle
	local body = PanelBackdrop.new(panel, {
		zIndex = 0,
		textureTransparency = UIStyleConfig.StudTransparency.Body,
		tileSize = UIStyleConfig.StudTile.Window,
	})
	local header = Create.new("Frame", {
		Name = "ModalStudHeader",
		Position = UDim2.fromOffset(0, 0),
		Active = false,
		Selectable = false,
		ZIndex = 0,
		Parent = panel,
	}) :: Frame
	header:SetAttribute("Decorative", true)
	local surface = StudWindow.surface(header, color or "blue", {
		tile = UIStyleConfig.StudTile.Window,
		studTransparency = UIStyleConfig.StudTransparency.Header,
		scroll = true,
		corner = UIStyleConfig.Window.Corner,
	})
	local function layout()
		if header.Parent == nil then
			return
		end
		header.Size = UDim2.new(1, 0, 0, title.Position.Y.Offset + title.Size.Y.Offset + 16)
	end
	local connections = {
		title:GetPropertyChangedSignal("Size"):Connect(layout),
		title:GetPropertyChangedSignal("Position"):Connect(layout),
	}
	local dead = false
	local function destroy()
		if dead then
			return
		end
		dead = true
		for _, connection in connections do
			connection:Disconnect()
		end
		surface.Destroy()
		body.Destroy()
		header:Destroy()
	end
	panel.Destroying:Once(destroy)
	layout()
	return { Destroy = destroy }
end

return table.freeze(ModalStudSurfaces)
