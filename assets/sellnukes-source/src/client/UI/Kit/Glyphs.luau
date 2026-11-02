--!strict
--[[
	Glyphs — clean frame-drawn FALLBACK icons for every icon key (StudUI.IconKeys + the shop's
	MonetizationConfig icon names, through ALIASES).

	Purpose:
		Real icons are rendered 3D icons uploaded by the icon pipeline (B15, Shared/Config/
		IconAssets). Only while a key's image is "" does StudUI.icon draw the matching glyph here, so the UI never shows a broken or
		empty image. Each glyph is a short recipe of flat shapes (boxes, circles, rings, text)
		on a 1x1 canvas, each with a chunky dark outline, which reads as a simple cartoon icon in
		the same style as the references. Built once per icon instance (no per-frame work).

	Recipe shape fields (all positions / sizes are fractions of the icon side, centre-based):
		kind    "box" | "circle" | "ring" | "text"
		x, y    centre
		w, h    size
		color   fill (Color3) or "rainbow" (UIStyleConfig.Rainbow gradient)
		rot     degrees (optional)
		corner  corner radius as a fraction of the shorter side (box; optional)
		thick   ring thickness as a fraction of the icon side (ring)
		text    the text (text shapes); `size` = text height fraction
		edge    false = no dark outline (small details)

	Connects to: Kit/StudUI.icon (the only caller), Shared/Config/IconAssets (keys),
	Shared/Config/UIStyleConfig (outline + rainbow).

	Example:
		local icon = Glyphs.build("Gems", 96)
		icon.Parent = tile
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Create)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

type Shape = {
	kind: "box" | "circle" | "ring" | "text",
	x: number,
	y: number,
	w: number,
	h: number,
	color: Color3 | "rainbow",
	rot: number?,
	corner: number?,
	thick: number?,
	text: string?,
	size: number?,
	edge: boolean?,
}

local Glyphs = {}

local rgb = Color3.fromRGB
-- Palette shared by the recipes.
local C = {
	green = rgb(104, 210, 72),
	greenDark = rgb(48, 140, 44),
	greenLight = rgb(170, 240, 120),
	yellow = rgb(255, 210, 56),
	gold = rgb(255, 190, 40),
	orange = rgb(250, 140, 40),
	red = rgb(232, 60, 80),
	redDark = rgb(168, 30, 52),
	pink = rgb(250, 120, 170),
	purple = rgb(176, 96, 246),
	purpleLight = rgb(226, 180, 255),
	blue = rgb(60, 130, 246),
	sky = rgb(120, 200, 252),
	teal = rgb(60, 210, 200),
	tealLight = rgb(180, 255, 248),
	white = rgb(250, 250, 252),
	grey = rgb(150, 156, 168),
	dark = rgb(34, 38, 54),
	brown = rgb(170, 104, 54),
	navy = rgb(36, 44, 88),
}

-- Shape constructors (keep recipes short and readable).
local function box(
	x: number,
	y: number,
	w: number,
	h: number,
	color: Color3 | "rainbow",
	rot: number?,
	corner: number?
): Shape
	return { kind = "box", x = x, y = y, w = w, h = h, color = color, rot = rot, corner = corner }
end
local function circle(x: number, y: number, w: number, h: number, color: Color3 | "rainbow"): Shape
	return { kind = "circle", x = x, y = y, w = w, h = h, color = color }
end
local function ring(x: number, y: number, w: number, h: number, color: Color3, thick: number): Shape
	return { kind = "ring", x = x, y = y, w = w, h = h, color = color, thick = thick }
end
local function text(x: number, y: number, value: string, size: number, color: Color3): Shape
	return { kind = "text", x = x, y = y, w = 1, h = size, color = color, text = value, size = size }
end
-- Same shape without the dark outline (small inner details).
local function plain(shape: Shape): Shape
	shape.edge = false
	return shape
end

local wheel: { Shape } = {
	circle(0.5, 0.5, 0.86, 0.86, "rainbow"),
	plain(ring(0.5, 0.5, 0.86, 0.86, C.white, 0.05)),
	circle(0.5, 0.5, 0.2, 0.2, C.dark),
	box(0.5, 0.1, 0.16, 0.16, C.white, 45, 0.1),
}

local cash: { Shape } = {
	box(0.5, 0.6, 0.86, 0.46, C.greenDark, -10, 0.14),
	box(0.5, 0.48, 0.86, 0.46, C.green, -10, 0.14),
	plain(box(0.5, 0.48, 0.2, 0.47, C.yellow, -10)),
	plain(circle(0.5, 0.48, 0.2, 0.2, C.greenLight)),
}

local teleport: { Shape } = {
	circle(0.5, 0.52, 0.78, 0.86, C.teal),
	plain(circle(0.5, 0.52, 0.56, 0.64, C.tealLight)),
	plain(circle(0.5, 0.52, 0.3, 0.38, C.white)),
}

local gift = function(body: Color3, ribbon: Color3): { Shape }
	return {
		circle(0.36, 0.22, 0.24, 0.2, ribbon),
		circle(0.64, 0.22, 0.24, 0.2, ribbon),
		box(0.5, 0.64, 0.72, 0.5, body, 0, 0.08),
		box(0.5, 0.38, 0.84, 0.18, body, 0, 0.08),
		plain(box(0.5, 0.58, 0.16, 0.66, ribbon)),
	}
end

-- One recipe per IconAssets key (unknown keys fall back to `Star`).
local RECIPES: { [string]: { Shape } } = {
	Cash = cash,
	x2Cash = {
		box(0.46, 0.56, 0.8, 0.42, C.greenDark, -10, 0.14),
		box(0.46, 0.46, 0.8, 0.42, C.green, -10, 0.14),
		plain(box(0.46, 0.46, 0.18, 0.43, C.yellow, -10)),
		text(0.74, 0.78, "x2", 0.42, C.white),
	},
	Gems = {
		box(0.5, 0.52, 0.6, 0.6, C.purple, 45, 0.12),
		plain(box(0.5, 0.42, 0.3, 0.3, C.purpleLight, 45, 0.1)),
	},
	Robux = {
		box(0.5, 0.5, 0.74, 0.74, C.green, 0, 0.3),
		plain(box(0.5, 0.5, 0.46, 0.46, C.greenDark, 0, 0.22)),
		plain(box(0.5, 0.5, 0.22, 0.22, C.greenLight, 0, 0.2)),
	},
	Shop = {
		ring(0.5, 0.36, 0.5, 0.5, C.grey, 0.08),
		box(0.5, 0.64, 0.8, 0.48, C.red, 0, 0.14),
		box(0.5, 0.42, 0.92, 0.14, C.redDark, 0, 0.2),
		plain(box(0.34, 0.66, 0.08, 0.3, C.pink)),
		plain(box(0.5, 0.66, 0.08, 0.3, C.pink)),
		plain(box(0.66, 0.66, 0.08, 0.3, C.pink)),
	},
	Rewards = gift(C.red, C.yellow),
	Gift = gift(C.orange, C.red),
	Daily = {
		box(0.5, 0.56, 0.78, 0.72, C.white, 0, 0.14),
		box(0.5, 0.3, 0.78, 0.2, C.red, 0, 0.14),
		box(0.34, 0.2, 0.08, 0.18, C.grey, 0, 0.4),
		box(0.66, 0.2, 0.08, 0.18, C.grey, 0, 0.4),
		text(0.5, 0.64, "31", 0.42, C.navy),
	},
	Codes = {
		box(0.5, 0.5, 0.72, 0.72, C.blue, -10, 0.16),
		box(0.4, 0.56, 0.1, 0.3, C.white, -45, 0.3),
		box(0.58, 0.47, 0.1, 0.52, C.white, 38, 0.3),
	},
	LuckyWheel = wheel,
	Spins = wheel,
	Time = {
		circle(0.5, 0.52, 0.84, 0.84, C.red),
		plain(circle(0.5, 0.52, 0.6, 0.6, C.white)),
		plain(box(0.5, 0.42, 0.08, 0.22, C.dark, 0, 0.4)),
		plain(box(0.58, 0.52, 0.2, 0.08, C.dark, 0, 0.4)),
		plain(circle(0.5, 0.52, 0.1, 0.1, C.red)),
	},
	Clock = {
		circle(0.5, 0.5, 0.84, 0.84, C.white),
		plain(box(0.5, 0.4, 0.08, 0.24, C.dark, 0, 0.4)),
		plain(box(0.6, 0.5, 0.22, 0.08, C.dark, 0, 0.4)),
	},
	Pets = {
		circle(0.5, 0.64, 0.46, 0.4, C.pink),
		circle(0.24, 0.4, 0.17, 0.2, C.pink),
		circle(0.4, 0.26, 0.17, 0.2, C.pink),
		circle(0.6, 0.26, 0.17, 0.2, C.pink),
		circle(0.76, 0.4, 0.17, 0.2, C.pink),
	},
	Rebirth = {
		ring(0.5, 0.52, 0.72, 0.72, C.teal, 0.13),
		box(0.78, 0.3, 0.24, 0.24, C.teal, 45, 0.1),
		plain(circle(0.5, 0.52, 0.2, 0.2, C.yellow)),
	},
	Teleport = teleport,
	Teleporter = {
		box(0.5, 0.6, 0.5, 0.56, C.sky, 0, 0.3),
		plain(box(0.5, 0.6, 0.32, 0.38, C.white, 0, 0.3)),
		circle(0.5, 0.26, 0.22, 0.22, C.red),
	},
	Attack = {
		circle(0.3, 0.72, 0.24, 0.24, C.orange),
		box(0.52, 0.48, 0.32, 0.7, C.white, 40, 0.45),
		plain(box(0.52, 0.48, 0.33, 0.12, C.red, 40)),
		plain(circle(0.6, 0.38, 0.14, 0.14, C.sky)),
	},
	Nuke = {
		box(0.74, 0.22, 0.08, 0.22, C.brown, 40, 0.3),
		circle(0.82, 0.12, 0.14, 0.14, C.yellow),
		circle(0.46, 0.58, 0.72, 0.72, C.green),
		plain(circle(0.46, 0.58, 0.28, 0.28, C.yellow)),
		plain(circle(0.46, 0.58, 0.1, 0.1, C.dark)),
	},
	Event = {
		circle(0.28, 0.36, 0.28, 0.3, C.orange),
		circle(0.5, 0.26, 0.28, 0.3, C.yellow),
		circle(0.72, 0.36, 0.28, 0.3, C.red),
		circle(0.5, 0.6, 0.6, 0.58, C.brown),
		circle(0.5, 0.42, 0.24, 0.24, C.brown),
		plain(box(0.5, 0.5, 0.08, 0.1, C.orange, 45)),
	},
	VIP = {
		box(0.26, 0.44, 0.24, 0.24, C.gold, 45, 0.1),
		box(0.5, 0.36, 0.26, 0.26, C.gold, 45, 0.1),
		box(0.74, 0.44, 0.24, 0.24, C.gold, 45, 0.1),
		box(0.5, 0.64, 0.8, 0.32, C.gold, 0, 0.12),
		plain(circle(0.5, 0.64, 0.14, 0.14, C.red)),
		plain(circle(0.28, 0.64, 0.1, 0.1, C.sky)),
		plain(circle(0.72, 0.64, 0.1, 0.1, C.sky)),
	},
	StarterPack = {
		box(0.5, 0.64, 0.8, 0.46, C.orange, 0, 0.12),
		box(0.5, 0.38, 0.8, 0.24, C.redDark, 0, 0.4),
		plain(box(0.5, 0.64, 0.8, 0.08, C.brown)),
		box(0.5, 0.52, 0.16, 0.2, C.yellow, 0, 0.2),
	},
	SecretPack = {
		box(0.5, 0.15, 0.28, 0.1, C.orange, 0, 0.2),
		box(0.5, 0.28, 0.22, 0.2, C.sky, 0, 0.1),
		circle(0.5, 0.62, 0.66, 0.6, C.purple),
		text(0.5, 0.63, "?", 0.42, C.white),
	},
	Lock = {
		ring(0.5, 0.36, 0.42, 0.46, C.grey, 0.09),
		box(0.5, 0.64, 0.64, 0.48, C.gold, 0, 0.14),
		plain(circle(0.5, 0.6, 0.14, 0.14, C.dark)),
		plain(box(0.5, 0.7, 0.06, 0.14, C.dark)),
	},
	Check = {
		box(0.5, 0.5, 0.74, 0.74, C.green, 0, 0.2),
		box(0.4, 0.56, 0.1, 0.3, C.white, -45, 0.3),
		box(0.58, 0.47, 0.1, 0.5, C.white, 38, 0.3),
	},
	Settings = {
		box(0.5, 0.5, 0.86, 0.2, C.grey, 0, 0.2),
		box(0.5, 0.5, 0.86, 0.2, C.grey, 45, 0.2),
		box(0.5, 0.5, 0.86, 0.2, C.grey, 90, 0.2),
		box(0.5, 0.5, 0.86, 0.2, C.grey, 135, 0.2),
		circle(0.5, 0.5, 0.62, 0.62, C.grey),
		circle(0.5, 0.5, 0.26, 0.26, C.dark),
	},
	Arrow = {
		box(0.5, 0.62, 0.48, 0.48, C.yellow, 45, 0.1),
		box(0.5, 0.32, 0.28, 0.5, C.yellow, 0, 0.1),
		plain(box(0.5, 0.38, 0.2, 0.5, C.yellow)),
	},
	Star = {
		box(0.5, 0.52, 0.62, 0.62, C.yellow, 0, 0.1),
		box(0.5, 0.52, 0.62, 0.62, C.yellow, 45, 0.1),
		plain(circle(0.5, 0.52, 0.34, 0.34, rgb(255, 238, 140))),
	},
	Close = {
		box(0.5, 0.5, 0.8, 0.8, C.red, 0, 0.18),
		box(0.5, 0.5, 0.16, 0.62, C.white, 45, 0.3),
		box(0.5, 0.5, 0.16, 0.62, C.white, -45, 0.3),
	},
	-- Shop / product icons (MonetizationConfig icon names) without a HUD twin.
	Egg = {
		circle(0.5, 0.54, 0.58, 0.74, C.white),
		plain(circle(0.4, 0.42, 0.12, 0.12, C.sky)),
		plain(circle(0.6, 0.62, 0.14, 0.14, C.pink)),
		plain(circle(0.46, 0.74, 0.1, 0.1, C.yellow)),
	},
	Shield = {
		box(0.5, 0.44, 0.66, 0.5, C.sky, 0, 0.12),
		box(0.5, 0.62, 0.48, 0.48, C.sky, 45, 0.1),
		plain(box(0.5, 0.5, 0.12, 0.5, C.white)),
	},
	Lightning = {
		box(0.56, 0.3, 0.2, 0.46, C.yellow, 25, 0.05),
		box(0.5, 0.5, 0.42, 0.14, C.yellow, -20, 0.05),
		box(0.44, 0.7, 0.2, 0.46, C.yellow, 25, 0.05),
	},
	Moon = {
		circle(0.5, 0.5, 0.74, 0.74, rgb(255, 230, 120)),
		plain(circle(0.38, 0.4, 0.16, 0.16, rgb(236, 200, 90))),
		plain(circle(0.62, 0.62, 0.12, 0.12, rgb(236, 200, 90))),
	},
	Acorn = {
		circle(0.5, 0.62, 0.52, 0.6, rgb(206, 140, 70)),
		box(0.5, 0.36, 0.66, 0.24, C.brown, 0, 0.45),
		box(0.5, 0.18, 0.08, 0.16, C.brown, 0, 0.3),
	},
	Boot = {
		box(0.42, 0.42, 0.34, 0.56, C.red, 0, 0.14),
		box(0.54, 0.7, 0.66, 0.26, C.red, 0, 0.14),
		plain(box(0.54, 0.82, 0.66, 0.08, C.white)),
	},
	Cursor = {
		box(0.46, 0.44, 0.44, 0.44, C.white, 45, 0.08),
		box(0.6, 0.66, 0.14, 0.36, C.white, -35, 0.2),
	},
	Crate = {
		box(0.5, 0.58, 0.78, 0.6, C.brown, 0, 0.1),
		box(0.5, 0.32, 0.86, 0.16, rgb(206, 140, 70), 0, 0.12),
		plain(box(0.5, 0.58, 0.78, 0.08, rgb(120, 70, 30))),
		plain(box(0.5, 0.58, 0.12, 0.6, rgb(120, 70, 30))),
		box(0.5, 0.46, 0.18, 0.16, C.yellow, 0, 0.2),
	},
	Skip = {
		text(0.5, 0.52, ">>", 0.6, C.green),
	},
}

-- Other names that draw an existing recipe: the original key spellings, and
-- MonetizationConfig's lowercase product icon names (shop cards built by later screens).
local ALIASES: { [string]: string } = {
	Gem = "Gems",
	Admin = "Settings",
	X2Cash = "x2Cash",
	cash = "Cash",
	gem = "Gems",
	spin = "Spins",
	gift = "Gift",
	star = "Star",
	clock = "Clock",
	teleport = "Teleporter",
	crown = "VIP",
	rocket = "Attack",
	pet = "Pets",
	turkey = "Event",
	egg = "Egg",
	shield = "Shield",
	lightning = "Lightning",
	moon = "Moon",
	acorn = "Acorn",
	boot = "Boot",
	cursor = "Cursor",
	skip = "Skip",
	crate = "Crate",
}

-- The recipe for a key (direct, then alias, then the per-area icons Area01..Area10), or nil.
local function recipeFor(key: string): { Shape }?
	local direct = RECIPES[key] or (if ALIASES[key] ~= nil then RECIPES[ALIASES[key]] else nil)
	if direct == nil and string.match(key, "^Area%d%d$") ~= nil then
		return RECIPES.Teleporter
	end
	return direct
end

--[[ True when a recipe exists for `key`. ]]
function Glyphs.has(key: string): boolean
	return recipeFor(key) ~= nil
end

-- Outline thickness for an icon of `size` px (chunky but never thicker than 4 px).
local function edgeFor(size: number): number
	return math.clamp(size * 0.035, 1.5, 4)
end

-- Builds one shape under `root`.
local function draw(root: Frame, shape: Shape, size: number, order: number)
	local fill = shape.color
	local edge = edgeFor(size)
	local outlined = shape.edge ~= false
	local position = UDim2.fromScale(shape.x, shape.y)
	local dims = UDim2.fromScale(shape.w, shape.h)
	if shape.kind == "text" then
		local label = Create.new("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = position,
			Size = UDim2.fromScale(1, shape.size or 0.4),
			BackgroundTransparency = 1,
			Text = shape.text or "",
			TextScaled = true,
			FontFace = UIStyleConfig.Fonts.Title,
			TextColor3 = if typeof(fill) == "Color3" then fill else Color3.new(1, 1, 1),
			ZIndex = order,
			Parent = root,
		}) :: TextLabel
		Create.new("UIStroke", {
			Color = UIStyleConfig.Neutral.TextStroke,
			Thickness = edge,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
			Parent = label,
		})
		return
	end
	local frame = Create.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = dims,
		Rotation = shape.rot or 0,
		BorderSizePixel = 0,
		BackgroundColor3 = if typeof(fill) == "Color3" then fill else Color3.new(1, 1, 1),
		BackgroundTransparency = if shape.kind == "ring" then 1 else 0,
		ZIndex = order,
		Parent = root,
	}) :: Frame
	if shape.kind == "circle" or shape.kind == "ring" then
		Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = frame })
	elseif shape.corner ~= nil then
		local short = math.min(shape.w, shape.h) * size
		Create.new("UICorner", { CornerRadius = UDim.new(0, math.floor(short * shape.corner)), Parent = frame })
	end
	if fill == "rainbow" then
		Create.new("UIGradient", { Color = UIStyleConfig.Rainbow, Rotation = 35, Parent = frame })
	end
	if shape.kind == "ring" then
		-- A ring = a thick coloured stroke with a thinner dark outline stroke on a second frame.
		local thick = math.max(2, (shape.thick or 0.1) * size)
		local outline = frame:Clone()
		outline.ZIndex = order
		outline.Parent = root
		Create.new("UIStroke", {
			Color = UIStyleConfig.Neutral.Edge,
			Thickness = thick + edge * 2,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = outline,
		})
		-- The coloured ring draws one ZIndex above its outline.
		frame.ZIndex = order + 1
		Create.new("UIStroke", {
			Color = if typeof(fill) == "Color3" then fill else Color3.new(1, 1, 1),
			Thickness = thick,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = frame,
		})
		return
	end
	if outlined then
		Create.new("UIStroke", {
			Color = UIStyleConfig.Neutral.Edge,
			Thickness = edge,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			LineJoinMode = Enum.LineJoinMode.Round,
			Parent = frame,
		})
	end
end

--[[
	Builds the fallback glyph for `key` (unknown keys draw `Star`).
	@param key  IconAssets key
	@param size icon side in design px (used for outline thickness and corner radii)
	@param zIndex base ZIndex of the shapes (default 2)
	@return a transparent square Frame holding the shapes (Size = size x size)
	Example: Glyphs.build("Shop", 96).Parent = tile
]]
function Glyphs.build(key: string, size: number, zIndex: number?): Frame
	local recipe = recipeFor(key) or RECIPES.Star
	local root = Create.new("Frame", {
		Name = `Glyph_{key}`,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Active = false,
		Selectable = false,
		ZIndex = zIndex or 2,
	}) :: Frame
	root:SetAttribute("Decorative", true)
	-- Two ZIndex slots per shape (a ring needs its outline below it); later shapes draw on top.
	local base = zIndex or 2
	for index, shape in recipe do
		draw(root, shape, size, base + (index - 1) * 2)
	end
	return root
end

return table.freeze(Glyphs)
