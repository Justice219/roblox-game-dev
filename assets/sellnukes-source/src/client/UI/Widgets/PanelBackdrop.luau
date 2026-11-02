--!strict
--[[
	PanelBackdrop — lays the RoBeasts embossed stud material over an existing panel (ported from
	RoBeasts; glints dropped, tile size made per-surface for SellNukes).

	Purpose:
		The ONE way a surface gets its studs. The texture is a tiled (never stretched) ImageLabel
		bound through Widgets/StudTexture (shared local bitmap, uploaded fallback), rounded like
		its parent and drawn under the panel's own content (ZIndex 0 by default). Nothing here is
		Active or Selectable: input, gamepad selection and layout are untouched.

		scroll = true (window headers / topbars) slides the studs sideways forever through ONE
		OfferFx registration (the shared visibility-gated PreRender step: a hidden / closed /
		off-screen header costs nothing). The texture is one tile period wider than its clip lane
		and wraps by exactly one tile, so the loop is seamless. Reduce Motion and Low graphics
		park it (the studs simply stop). ClipsDescendants clips to the rectangle, not the UICorner
		arc, so the lane stops `corner` px short of each side: sliding studs never poke out of a
		rounded corner.

	Layout rule: the backdrop is an ordinary full-size child of the panel, so a UIListLayout /
	UIGridLayout that is ALSO a direct child of that panel would lay the backdrop out as a list
	item. A panel with a layout keeps the layout and its content in an inner transparent
	"Content" frame instead (StudUI cards / windows do this). Studio warns about violations.

	Connects to: Widgets/StudTexture, Widgets/OfferFx, Shared/Config/PanelTextureAssets,
	Shared/Config/OfferFxConfig, Kit/StudUI (every stud surface).

	Example:
		local studs = PanelBackdrop.new(card, { tileSize = 84, textureTransparency = 0.5 })
		local header = PanelBackdrop.new(plate, { scroll = true, tileSize = 96 })
		-- teardown: destroying the panel releases everything (or call studs.Destroy())
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Assets = require(ReplicatedStorage.Shared.Config.PanelTextureAssets)
local Config = require(script.Parent.PanelBackdropConfig)
local Create = require(script.Parent.Parent.Create)
local OfferFx = require(script.Parent.OfferFx)
local OfferFxConfig = require(ReplicatedStorage.Shared.Config.OfferFxConfig)
local StudTexture = require(script.Parent.StudTexture)

export type Options = {
	tint: Color3?, -- ImageColor3 of the studs (default white: light studs lighten, dark darken)
	zIndex: number?, -- default 0 (under the panel's Z1+ content)
	textureTransparency: number?, -- default Config.TextureTransparency
	tileSize: number?, -- design px per two-stud tile (default Config.TileSize)
	scroll: boolean?, -- slide sideways (headers only; see the module header)
	cornerRadius: number?, -- rendered px; default: the parent's UICorner, else Config default
}

export type Handle = {
	frame: Frame, -- the decoration root (named "PanelBackdrop")
	refresh: () -> (), -- re-read the parent's corner / re-arm the fallback loader
	setTransparency: (transparency: number) -> (),
	Destroy: () -> (),
}

local PanelBackdrop = {}

-- Name of the decoration frame new() adds (audit() looks for it).
local BACKDROP_NAME = "PanelBackdrop"

--[[ The layout child (UIListLayout / UIGridLayout / ...) that would misplace a backdrop. ]]
local function layoutChild(parent: Instance): Instance?
	for _, child in parent:GetChildren() do
		if child:IsA("UIGridStyleLayout") then
			return child
		end
	end
	return nil
end

--[[
	Studio audit of the layout rule: full names of every studded panel under `root` that also
	has a direct layout child. Walks the tree once; never call it per frame.
	@return offending panels (empty when clean)
	Example: assert(#PanelBackdrop.audit(gui) == 0)
]]
function PanelBackdrop.audit(root: Instance): { string }
	local bad: { string } = {}
	for _, node in root:GetDescendants() do
		if node.Name == BACKDROP_NAME and node:GetAttribute("Decorative") == true then
			local panel = node.Parent
			if panel ~= nil and layoutChild(panel) ~= nil then
				table.insert(bad, panel:GetFullName())
			end
		end
	end
	return bad
end

-- Sanitises a caller number (NaN / out of range -> fallback).
local function number01(value: number?, fallback: number): number
	if value == nil or value ~= value then
		return fallback
	end
	return math.clamp(value, 0, 1)
end

--[[
	Decorates `parent` with the stud material (see the module header).
	@param parent  the panel / plate / button face
	@param options tint, z, opacity, tile size, scroll, corner
	@return Handle (Destroy is idempotent and also runs when the panel is destroyed)
]]
function PanelBackdrop.new(parent: GuiObject, options: Options?): Handle
	local opts: Options = options or {}
	local zIndex = opts.zIndex or 0
	local tile = opts.tileSize or Config.TileSize
	if tile ~= tile or tile <= 0 then
		tile = Config.TileSize
	end
	local transparency = number01(opts.textureTransparency, Config.TextureTransparency)
	local inset = Config.Inset
	local root = Create.new("Frame", {
		Name = BACKDROP_NAME,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(inset, inset),
		Size = UDim2.new(1, -2 * inset, 1, -2 * inset),
		ClipsDescendants = true,
		Active = false,
		Selectable = false,
		ZIndex = zIndex,
		Parent = parent,
	}) :: Frame
	root:SetAttribute("Decorative", true)
	local corner = Create.new("UICorner", { Name = "BackdropCorner", Parent = root }) :: UICorner
	local scroll = opts.scroll == true
	-- Scrolling surfaces clip the sliding texture in a lane kept clear of the corner arcs.
	local lane: Frame? = if scroll
		then Create.new("Frame", {
			Name = "StudScroll",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ClipsDescendants = true,
			Active = false,
			Selectable = false,
			ZIndex = zIndex,
			Parent = root,
		}) :: Frame
		else nil
	local texture = Create.new("ImageLabel", {
		Name = "StudTexture",
		Image = Assets.StudImage,
		ImageColor3 = opts.tint or Color3.new(1, 1, 1),
		ImageTransparency = transparency,
		ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromOffset(tile, tile),
		-- A scrolling texture carries one extra tile period so the wrap never shows an edge.
		Size = if scroll then UDim2.new(1, tile, 1, 0) else UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Active = false,
		Selectable = false,
		ZIndex = zIndex,
		Parent = lane or root,
	}) :: ImageLabel
	local releaseTexture = StudTexture.bind(texture)
	-- Round the ImageLabel itself (parent clipping alone does not round images in every
	-- renderer). A sliding texture cannot carry the corner (it would travel); its lane avoids it.
	local textureCorner: UICorner? = if scroll
		then nil
		else Create.new("UICorner", { Name = "StudCorner", Parent = texture }) :: UICorner
	local slide: OfferFx.Handle? = nil
	if scroll then
		local speed = OfferFxConfig.TopbarDrift.PixelsPerSecond
		slide = OfferFx.register({
			root = lane :: Frame,
			rates = OfferFxConfig.TopbarDrift.Hz,
			step = function(_dt: number, elapsed: number)
				texture.Position = UDim2.fromOffset(-((elapsed * speed) % tile), 0)
			end,
		})
	end
	local dead = false
	-- Re-reads the parent's corner (rendered radius) and re-arms the fallback loader.
	local function refresh()
		if dead then
			return
		end
		StudTexture.refresh()
		local radius: UDim
		if opts.cornerRadius ~= nil then
			radius = UDim.new(0, opts.cornerRadius)
		else
			local parentCorner = parent:FindFirstChildOfClass("UICorner")
			radius = if parentCorner ~= nil then parentCorner.CornerRadius else UDim.new(0, Config.DefaultCornerRadius)
		end
		local insetRadius = UDim.new(radius.Scale, math.max(0, radius.Offset - inset))
		corner.CornerRadius = insetRadius
		if textureCorner ~= nil then
			textureCorner.CornerRadius = insetRadius
		end
		if lane ~= nil then
			lane.Position = UDim2.fromOffset(insetRadius.Offset, 0)
			lane.Size = UDim2.new(1, -2 * insetRadius.Offset, 1, 0)
		end
		local sliding = slide
		if sliding ~= nil then
			sliding.refresh()
		end
	end
	local destroying: RBXScriptConnection? = nil
	-- Unregister before removing Instances so a teardown never leaves a live step writing a
	-- destroyed texture. Explicit and parent-driven cleanup share one guard.
	local function cleanup(destroyRoot: boolean)
		if dead then
			return
		end
		dead = true
		releaseTexture()
		if slide ~= nil then
			slide.destroy()
			slide = nil
		end
		if destroying ~= nil then
			destroying:Disconnect()
			destroying = nil
		end
		if destroyRoot then
			root:Destroy()
		end
	end
	destroying = root.Destroying:Connect(function()
		cleanup(false)
	end)
	-- Studio guard for the layout rule (module header): warn now and once after the build.
	if RunService:IsStudio() then
		local function check()
			if dead or root.Parent ~= parent then
				return
			end
			local layout = layoutChild(parent)
			if layout ~= nil then
				warn(
					`[PanelBackdrop] {parent:GetFullName()} has a {layout.ClassName}: the backdrop becomes a list item. `
						.. "Move the layout and content into an inner transparent Content frame."
				)
			end
		end
		check()
		task.defer(check)
	end
	refresh()
	return {
		frame = root,
		refresh = refresh,
		setTransparency = function(value: number)
			texture.ImageTransparency = number01(value, transparency)
		end,
		Destroy = function()
			cleanup(true)
		end,
	}
end

return PanelBackdrop
