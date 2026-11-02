--!strict
--[[
	StudWindow — the drawing PARTS of the stud UI look (ported from RoBeasts' StudWindow and
	re-cut for the SellNukes references). Kit/StudUI assembles them into windows, cards,
	buttons, HUD tiles and offers; screens normally use StudUI, not these parts directly.

	Parts (all decoration: nothing here is Active or Selectable; no input / layout ownership):
		surface(frame, color, options)  turns a Frame into a coloured stud surface: a vertical
		                                gradient (preset top -> bottom; rainbow = diagonal
		                                multi-stop), a soft top highlight, the RoBeasts stud
		                                texture (PanelBackdrop, optionally drifting sideways)
		                                and an optional thick dark outline. setColor() re-tints.
		outline(label, thickness)       dark Contextual text outline (reuses an existing one)
		edge(frame, thickness)          dark Border outline (reuses an existing one)
		sunburst(parent, options)       light rays behind a reward icon (slow spin)
		starburst(parent, options)      dark tapered spikes behind a right-column Robux offer
		                                (slow spin)

	Performance: everything is built once. The only per-frame work is the shared OfferFx steps
	(texture Position, a burst's Rotation, a rainbow's gradient Offset): a handful of property
	writes, nothing while hidden / off screen / Reduce Motion / Low graphics.

	Connects to: Widgets/PanelBackdrop (studs), Widgets/OfferFx (driver), Widgets/StudWindowConfig,
	Shared/Config/UIStyleConfig (presets), Shared/Config/OfferFxConfig (rates), Kit/StudUI.

	Example:
		local plate = Instance.new("Frame")
		local surface = StudWindow.surface(plate, "yellow", { tile = 96, scroll = true, edge = 4 })
		surface.setColor("red")
		StudWindow.outline(titleLabel, 5)
		StudWindow.sunburst(card, { zIndex = 1 })
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(script.Parent.StudWindowConfig)
local Create = require(script.Parent.Parent.Create)
local OfferFx = require(script.Parent.OfferFx)
local OfferFxConfig = require(ReplicatedStorage.Shared.Config.OfferFxConfig)
local PanelBackdrop = require(script.Parent.PanelBackdrop)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type ColorName = UIStyleConfig.ColorName

export type SurfaceOptions = {
	tile: number?, -- stud tile size (design px); 0 / nil = UIStyleConfig.StudTile.Card
	studTransparency: number?, -- stud opacity (1 = no studs)
	scroll: boolean?, -- drift the studs sideways (headers)
	edge: number?, -- dark Border outline thickness (nil / 0 = none)
	corner: number?, -- rendered corner radius (px); default UIStyleConfig.Card.Corner
	highlight: boolean?, -- soft top highlight band (default true)
	zIndex: number?, -- decoration ZIndex inside `frame` (default 0)
}

export type Surface = {
	frame: GuiObject,
	gradient: UIGradient,
	setColor: (color: ColorName) -> (),
	color: () -> ColorName,
	Destroy: () -> (),
}

export type BurstOptions = {
	zIndex: number?,
	color: Color3?,
	spin: boolean?, -- default true
	size: UDim2?, -- default fills the parent (square, centred)
}

local StudWindow = {}

-- Applies preset `name` to a surface gradient (rainbow = diagonal multi-stop).
local function paint(gradient: UIGradient, name: ColorName)
	if name == "rainbow" then
		gradient.Color = UIStyleConfig.Rainbow
		gradient.Rotation = Config.RainbowRotation
	else
		local preset = UIStyleConfig.Colors[name] or UIStyleConfig.Colors.grey
		gradient.Color = ColorSequence.new(preset.top, preset.bottom)
		gradient.Rotation = 90
	end
end

--[[
	Turns `frame` into a coloured stud surface (see the module header).
	@param frame   the Frame / button face to decorate (its BackgroundColor3 becomes white so the
	               gradient alone defines the colour)
	@param color   UIStyleConfig ColorName
	@param options tile / studs / scroll / edge / corner / highlight / zIndex
	@return Surface handle (Destroy removes the decoration; destroying `frame` also cleans up)
]]
function StudWindow.surface(frame: GuiObject, color: ColorName, options: SurfaceOptions?): Surface
	local opts: SurfaceOptions = options or {}
	local zIndex = opts.zIndex or 0
	local cornerPx = opts.corner or UIStyleConfig.Card.Corner
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.BackgroundTransparency = 0
	frame.BorderSizePixel = 0
	local corner = frame:FindFirstChildOfClass("UICorner")
	if corner == nil then
		corner = Create.new("UICorner", { CornerRadius = UDim.new(0, cornerPx), Parent = frame }) :: UICorner
	end
	local gradient = Create.new("UIGradient", { Name = "SurfaceGradient", Parent = frame }) :: UIGradient
	local current: ColorName = color
	paint(gradient, color)
	if opts.edge ~= nil and opts.edge > 0 then
		StudWindow.edge(frame, opts.edge)
	end
	-- Soft top highlight: a white band fading out downward (reads as a glossy, rounded face).
	local highlight: Frame? = nil
	if opts.highlight ~= false then
		highlight = Create.new("Frame", {
			Name = "TopHighlight",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = Config.Highlight.Transparency,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, Config.Highlight.Height),
			Active = false,
			Selectable = false,
			ZIndex = zIndex,
			Parent = frame,
			Children = {
				Create.new("UICorner", { CornerRadius = UDim.new(0, cornerPx) }),
				Create.new("UIGradient", {
					Rotation = 90,
					Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0),
						NumberSequenceKeypoint.new(1, 1),
					}),
				}),
			},
		}) :: Frame
		highlight:SetAttribute("Decorative", true)
	end
	local studTransparency = opts.studTransparency or UIStyleConfig.StudTransparency.Card
	local studs: PanelBackdrop.Handle? = nil
	if studTransparency < 1 then
		studs = PanelBackdrop.new(frame, {
			zIndex = zIndex,
			textureTransparency = studTransparency,
			tileSize = if opts.tile ~= nil and opts.tile > 0 then opts.tile else UIStyleConfig.StudTile.Card,
			scroll = opts.scroll == true,
			cornerRadius = cornerPx,
		})
	end
	-- Rainbow surfaces shimmer: the gradient offset sways slowly (shared driver, parked when
	-- hidden / Reduce Motion / Low graphics).
	local shimmer: OfferFx.Handle? = nil
	local function refreshShimmer()
		if current == "rainbow" and shimmer == nil then
			local speed = math.rad(OfferFxConfig.Rainbow.DegreesPerSecond)
			shimmer = OfferFx.register({
				root = frame,
				rates = OfferFxConfig.Rainbow.Hz,
				step = function(_dt: number, elapsed: number)
					gradient.Offset = Vector2.new(math.sin(elapsed * speed) * 0.18, 0)
				end,
			})
		elseif current ~= "rainbow" and shimmer ~= nil then
			shimmer.destroy()
			shimmer = nil
			gradient.Offset = Vector2.zero
		end
	end
	refreshShimmer()
	local dead = false
	return {
		frame = frame,
		gradient = gradient,
		setColor = function(name: ColorName)
			if dead or name == current then
				return
			end
			current = name
			paint(gradient, name)
			refreshShimmer()
		end,
		color = function(): ColorName
			return current
		end,
		Destroy = function()
			if dead then
				return
			end
			dead = true
			if shimmer ~= nil then
				shimmer.destroy()
			end
			if studs ~= nil then
				studs.Destroy()
			end
			if highlight ~= nil then
				highlight:Destroy()
			end
			gradient:Destroy()
		end,
	}
end

--[[
	Gives `label` a dark Contextual text outline of `thickness` px (reuses an existing one).
	Example: StudWindow.outline(title, 5)
]]
function StudWindow.outline(label: TextLabel | TextButton | TextBox, thickness: number)
	for _, child in label:GetChildren() do
		if child:IsA("UIStroke") and child.ApplyStrokeMode == Enum.ApplyStrokeMode.Contextual then
			child.Color = UIStyleConfig.Neutral.TextStroke
			child.Thickness = thickness
			return
		end
	end
	Create.new("UIStroke", {
		Name = "TextOutline",
		Color = UIStyleConfig.Neutral.TextStroke,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		LineJoinMode = Enum.LineJoinMode.Round,
		Parent = label,
	})
end

--[[
	Gives `frame` a dark Border outline of `thickness` px (reuses an existing Border stroke).
	Example: StudWindow.edge(card, 4)
]]
function StudWindow.edge(frame: GuiObject, thickness: number): UIStroke
	for _, child in frame:GetChildren() do
		if child:IsA("UIStroke") and child.ApplyStrokeMode == Enum.ApplyStrokeMode.Border then
			child.Color = UIStyleConfig.Neutral.Edge
			child.Thickness = thickness
			return child
		end
	end
	return Create.new("UIStroke", {
		Name = "Edge",
		Color = UIStyleConfig.Neutral.Edge,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round,
		Parent = frame,
	}) :: UIStroke
end

-- Registers a slow spin for a burst root (shared driver; parked when hidden / reduced).
local function spin(root: Frame, degreesPerSecond: number, rates: OfferFxConfig.PerTier)
	local base = root.Rotation
	OfferFx.register({
		root = root,
		rates = rates,
		step = function(_dt: number, elapsed: number)
			root.Rotation = (base + elapsed * degreesPerSecond) % 360
		end,
	})
end

-- A square, centred burst root that fills `parent` (or `size`).
local function burstRoot(parent: GuiObject, name: string, options: BurstOptions): Frame
	local root = Create.new("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = options.size or UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Active = false,
		Selectable = false,
		ZIndex = options.zIndex or 1,
		Parent = parent,
		Children = { Create.new("UIAspectRatioConstraint", { AspectRatio = 1 }) },
	}) :: Frame
	root:SetAttribute("Decorative", true)
	return root
end

--[[
	Light sunburst behind a reward icon: `Config.Sunburst.Rays` bars through the centre (two rays
	each), tips and centre faded by a gradient, slowly spinning.
	@param parent  the card / well (clip it if the rays must not reach past its edges)
	@param options zIndex / color / spin / size
	@return the burst Frame (destroy it to remove; its spin unregisters itself)
	Example: StudWindow.sunburst(card, { zIndex = 1, size = UDim2.fromScale(1.2, 1.2) })
]]
function StudWindow.sunburst(parent: GuiObject, options: BurstOptions?): Frame
	local opts: BurstOptions = options or {}
	local cfg = Config.Sunburst
	local root = burstRoot(parent, "Sunburst", opts)
	local fade = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.18, cfg.Transparency),
		NumberSequenceKeypoint.new(0.44, 0.75),
		NumberSequenceKeypoint.new(0.5, 0.9),
		NumberSequenceKeypoint.new(0.56, 0.75),
		NumberSequenceKeypoint.new(0.82, cfg.Transparency),
		NumberSequenceKeypoint.new(1, 1),
	})
	for index = 0, cfg.Rays - 1 do
		Create.new("Frame", {
			Name = `Ray{index}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(cfg.Width, 1),
			Rotation = index * 180 / cfg.Rays,
			BackgroundColor3 = opts.color or cfg.Color,
			BorderSizePixel = 0,
			Active = false,
			Selectable = false,
			ZIndex = opts.zIndex or 1,
			Parent = root,
			Children = { Create.new("UIGradient", { Rotation = 90, Transparency = fade }) },
		})
	end
	if opts.spin ~= false then
		spin(root, OfferFxConfig.Sunburst.DegreesPerSecond, OfferFxConfig.Sunburst.Hz)
	end
	return root
end

--[[
	Dark tapered starburst behind a right-column Robux offer: `Config.Starburst.Spikes` spike
	pairs, each built from stacked bars (long narrow -> short wide) so spikes taper and the
	overlapping centre darkens (a radial falloff without any image asset). Slowly spins.
	@param parent  the offer slot
	@param options zIndex / color / spin / size
	@return the burst Frame
	Example: StudWindow.starburst(slot, { zIndex = 1 })
]]
function StudWindow.starburst(parent: GuiObject, options: BurstOptions?): Frame
	local opts: BurstOptions = options or {}
	local cfg = Config.Starburst
	local root = burstRoot(parent, "Starburst", opts)
	local tips = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, cfg.Transparency),
		NumberSequenceKeypoint.new(0.7, cfg.Transparency),
		NumberSequenceKeypoint.new(1, 1),
	})
	for index = 0, cfg.Spikes - 1 do
		-- Alternate long / short spikes for a livelier silhouette.
		local reach = if index % 2 == 0 then 1 else 0.82
		for _, layer in cfg.Layers do
			Create.new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(layer.width, layer.length * reach),
				Rotation = index * 180 / cfg.Spikes,
				BackgroundColor3 = opts.color or cfg.Color,
				BackgroundTransparency = 0,
				BorderSizePixel = 0,
				Active = false,
				Selectable = false,
				ZIndex = opts.zIndex or 1,
				Parent = root,
				Children = { Create.new("UIGradient", { Rotation = 90, Transparency = tips }) },
			})
		end
	end
	if opts.spin ~= false then
		spin(root, OfferFxConfig.Starburst.DegreesPerSecond, OfferFxConfig.Starburst.Hz)
	end
	return root
end

return table.freeze(StudWindow)
