--!strict
--[[
	StudTextureLocal — the client-built stud tile with a software MIP CHAIN (ported from RoBeasts,
	mip levels added for SellNukes 2026-10-30).

	Purpose:
		One client-owned bitmap holds the exact RoBeasts embossed stud tile (Config/PanelStudPixels),
		so the stud material never depends on the CDN. EditableImages have NO engine mipmaps:
		drawing the 256px tile at a ~40px on-screen tile size (phone HUD buttons) aliases into a
		pink / cyan noise (seen in the iPhone 14 simulator). So the 256px level is box-filtered
		ONCE into 128 / 64 / 32 px levels (alpha-weighted, so transparent stud gaps never darken
		the colours), and every label shows the smallest level that is at least
		MIP_ACCEPT x its on-screen tile size (≤ 1.25x minification: crisp, never noisy).

	Level choice: on-screen tile px = label.TileSize.X.Offset * the UI scale. UIController /
	ScreenManager feed the scale through setScale(); every label applied here is tracked
	(strong keys, removed on Destroying) and re-leveled when the scale changes (event-driven,
	rare). Extra UIScales (window fit, press bounce) are small and ignored.

	Budget: 256² + 128² + 64² + 32² RGBA = ~348 KiB of EditableImage memory, created once per
	client. Allocation or access can be denied (Experience Settings > Security > EditableImage
	API off — then creation may "succeed" but render a magenta / green placeholder, so each level
	is verified with a 1-pixel read-back — or a device's editable budget): the outcome is cached
	and StudTexture falls back to the uploaded (engine-mipmapped) image.

	Connects to: Shared/Config/PanelStudPixels (pixels), Widgets/StudTexture (the only caller of
	apply), UI/ScreenManager (setScale).

	Example:
		if not StudTextureLocal.apply(tile) then -- use the uploaded image end
		StudTextureLocal.setScale(0.62) -- phone
]]
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pixels = require(ReplicatedStorage.Shared.Config.PanelStudPixels)

local StudTextureLocal = {}

-- A level is accepted while it is at least this fraction of the on-screen tile size.
local MIP_ACCEPT = 0.8
-- Smallest level built.
local MIN_LEVEL = 32

type Level = { size: number, image: EditableImage, content: Content }

local attempted = false
local levels: { Level } = {} -- largest first (256, 128, 64, 32)
local uiScale = 1
-- Labels showing a local level -> true (strong keys; cleared on Destroying).
local tracked: { [ImageLabel]: RBXScriptConnection } = {}

--[[
	Box-filters an RGBA `source` of `size` x `size` into a (size/2)² buffer. Alpha-weighted:
	each output colour is the average of the four inputs weighted by their alpha, so a half
	transparent stud edge keeps its true colour instead of fading towards black.
]]
local function downsample(source: buffer, size: number): buffer
	local half = size // 2
	local out = buffer.create(half * half * 4)
	local row = size * 4
	-- Accumulators for the current 2x2 block (shared upvalues: no per-pixel allocation).
	local r, g, b, a = 0, 0, 0, 0
	local function add(offset: number)
		local alpha = buffer.readu8(source, offset + 3)
		r += buffer.readu8(source, offset) * alpha
		g += buffer.readu8(source, offset + 1) * alpha
		b += buffer.readu8(source, offset + 2) * alpha
		a += alpha
	end
	for y = 0, half - 1 do
		for x = 0, half - 1 do
			local base = (y * 2) * row + (x * 2) * 4
			r, g, b, a = 0, 0, 0, 0
			add(base)
			add(base + 4)
			add(base + row)
			add(base + row + 4)
			local target = (y * half + x) * 4
			if a > 0 then
				buffer.writeu8(out, target, math.floor(r / a + 0.5))
				buffer.writeu8(out, target + 1, math.floor(g / a + 0.5))
				buffer.writeu8(out, target + 2, math.floor(b / a + 0.5))
			end
			buffer.writeu8(out, target + 3, math.floor(a / 4 + 0.5))
		end
	end
	return out
end

-- Creates one EditableImage level from RGBA pixels (nil when allocation is denied).
local function makeLevel(pixels: buffer, size: number): Level?
	local created: EditableImage? = nil
	local ok, result = pcall(function(): Content?
		local dims = Vector2.new(size, size)
		local bitmap = AssetService:CreateEditableImage({ Size = dims })
		if bitmap == nil then
			return nil
		end
		created = bitmap
		bitmap:WritePixelsBuffer(Vector2.zero, dims, pixels)
		-- Access check: with the experience's EditableImage API disabled (Experience Settings >
		-- Security) creation can still succeed while the engine renders a magenta / green
		-- placeholder instead of our pixels. Reading one pixel back raises in that case, so the
		-- level is rejected and StudTexture uses the uploaded image.
		bitmap:ReadPixelsBuffer(Vector2.zero, Vector2.one)
		return Content.fromObject(bitmap)
	end)
	local image = created
	if ok and result ~= nil and image ~= nil then
		return { size = size, image = image, content = result }
	end
	if image ~= nil then
		image:Destroy()
	end
	return nil
end

-- Builds every level once per client (cached outcome; a denied allocation is never retried).
local function ensureLevels(): boolean
	if attempted then
		return #levels > 0
	end
	attempted = true
	local size = Pixels.Size
	local pixels = Pixels.createBuffer()
	assert(buffer.len(pixels) == size * size * 4, "stud tile requires complete RGBA pixels")
	local built: { Level } = {}
	while size >= MIN_LEVEL do
		local level = makeLevel(pixels, size)
		if level == nil then
			break
		end
		table.insert(built, level)
		if size // 2 < MIN_LEVEL then
			break
		end
		pixels = downsample(pixels, size)
		size //= 2
	end
	if #built == 0 then
		return false
	end
	levels = built
	return true
end

-- The level for an on-screen tile of `screenPx` px: the smallest one ≥ MIP_ACCEPT x screenPx.
local function levelFor(screenPx: number): Level
	local choice = levels[1]
	for _, level in levels do
		if level.size >= screenPx * MIP_ACCEPT then
			choice = level
		end
	end
	return choice
end

-- Points `image` at the right level for its tile size under the current scale.
local function assign(image: ImageLabel): boolean
	local tile = image.TileSize.X.Offset
	local screenPx = (if tile > 0 then tile else Pixels.Size) * uiScale
	local level = levelFor(screenPx)
	local ok = pcall(function()
		if image.ImageContent ~= level.content then
			image.ImageContent = level.content
		end
	end)
	return ok
end

--[[
	Points `image` at the shared local stud bitmap level that fits its tile size. Only the
	content source changes: callers keep their tint, opacity, tile size, geometry and layering.
	@param image an ImageLabel showing PanelTextureAssets.StudImage
	@return false when the local bitmap is unavailable (StudTexture then uses the uploaded image)
	Example: if not StudTextureLocal.apply(tile) then -- wait for the CDN copy end
]]
function StudTextureLocal.apply(image: ImageLabel): boolean
	if not ensureLevels() then
		return false
	end
	if not assign(image) then
		return false
	end
	if tracked[image] == nil then
		tracked[image] = image.Destroying:Connect(function()
			local connection = tracked[image]
			tracked[image] = nil
			if connection ~= nil then
				connection:Disconnect()
			end
		end)
	end
	return true
end

--[[
	Feeds the UI scale (design px -> screen px). Re-levels every tracked label when it changes.
	@param scale ScreenManager's resolution scale (0.4 .. 1.25)
	Example: StudTextureLocal.setScale(0.62)
]]
function StudTextureLocal.setScale(scale: number)
	if scale ~= scale or scale <= 0 or scale == uiScale then
		return
	end
	uiScale = scale
	if #levels == 0 then
		return
	end
	for image in tracked do
		assign(image)
	end
end

--[[ Built level sizes (diagnostics / Studio probes), largest first. ]]
function StudTextureLocal.levels(): { number }
	local sizes: { number } = {}
	for _, level in levels do
		table.insert(sizes, level.size)
	end
	return sizes
end

return table.freeze(StudTextureLocal)
