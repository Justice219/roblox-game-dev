--!strict
--[[
	CurrencyText — a centred "[icon] 1.25K" amount for world-space billboards (owner R57: Dino
	Valley amounts show the bone icon instead of "$").

	Purpose:
		Roblox text cannot inline an image, and a scaled TextLabel does not report its glyph width
		without per-frame TextBounds reads (they change with camera distance). So the amount is a
		holder Frame with a centred horizontal UIListLayout: [icon][label], where the label's
		width is a SCALE computed once per text from per-character advance widths of the font
		(measured once per glyph with TextService:GetTextBoundsAsync in the background; a
		conservative estimate until then). The pair stays centred at any distance with zero
		per-frame work. Without an icon key the label simply fills the holder (Nuke Town "$1.25K"
		exactly as before).

	Used by: Tycoon/PadBillboards (pad price), Tycoon/IncomePops (pooled "+1.25K" pops).

	Performance: building = 1 Frame + 1 UIListLayout + 1 TextLabel (+ 1 icon on first icon use);
	`set` writes properties only when they change; width maths is a string walk over <= 12
	characters. Glyph widths are measured once per character for the whole session.

	Trust: display only (amounts are server values formatted by Tycoon/WorldLookup.format).

	Example:
		local amount = CurrencyText.new(gui, { aspect = 4.2, font = UIStyleConfig.Fonts.Number,
			color = Neutral.CashGreen, stroke = 3 })
		CurrencyText.set(amount, "1.25K", "Bones")   -- [bone] 1.25K, centred
		CurrencyText.set(amount, "$1.25K", nil)      -- plain centred text (Nuke Town)
]]

local TextService = game:GetService("TextService")

local Create = require(script.Parent.Parent.UI.Create)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)

export type Options = {
	aspect: number, -- the holder's width / height in pixels (fixed: billboards scale uniformly)
	font: Font,
	color: Color3,
	stroke: number, -- UIStroke thickness (0 = none)
	strokeColor: Color3?,
	iconHeight: number?, -- icon height as a fraction of the holder height (default 0.86)
	zIndex: number?,
}

export type Handle = {
	frame: Frame, -- the holder: size / position it like a label
	label: TextLabel,
	stroke: UIStroke?,
	icon: Frame?, -- created on the first `set` with an icon key
	iconKey: string?,
	options: Options,
	text: string,
}

local CurrencyText = {}

-- Fallback advance width (em) of an unmeasured character: a little WIDER than the display font's
-- digits, so an unmeasured string never overflows its box (TextScaled would shrink it).
local ESTIMATE_EM = 0.66
-- Slack added to the measured width (stroke + rounding) so TextScaled never shrinks the text.
local SLACK = 1.08
-- Gap between the icon and the text (fraction of the holder width).
local GAP = 0.015
-- Characters an amount can contain: digits, every letter (NumberFormat suffixes K, M, B, T, Qa,
-- Qi, Sx, Sp, Oc, No, Dc, Ud, ..., "MAX", "FREE") and the signs "$", "+", "-", ".", ",", "(", ")".
local GLYPHS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz$+-.,() "

-- font family|weight|style -> char -> em width (measured at 100 px; filled in the background).
local widthsByFont: { [string]: { [string]: number } } = {}

local function fontKey(font: Font): string
	return `{font.Family}|{font.Weight.Name}|{font.Style.Name}`
end

-- Measures every glyph of GLYPHS for `font` once (background thread; yields per glyph).
local function measureFont(font: Font)
	local key = fontKey(font)
	if widthsByFont[key] ~= nil then
		return
	end
	local widths: { [string]: number } = {}
	widthsByFont[key] = widths
	task.spawn(function()
		local seen: { [string]: boolean } = {}
		for _, code in utf8.codes(GLYPHS) do
			local char = utf8.char(code)
			if not seen[char] then
				seen[char] = true
				local params = Instance.new("GetTextBoundsParams")
				params.Text = char
				params.Font = font
				params.Size = 100
				params.Width = 10000
				local ok, bounds = pcall(TextService.GetTextBoundsAsync, TextService, params)
				if ok and typeof(bounds) == "Vector2" and bounds.X > 0 then
					widths[char] = bounds.X / 100
				end
			end
		end
	end)
end

-- Width of `text` in ems of `font` (measured glyphs; estimate for the rest).
local function emWidth(text: string, font: Font): number
	local widths = widthsByFont[fontKey(font)]
	local total = 0
	for _, code in utf8.codes(text) do
		local width = if widths ~= nil then widths[utf8.char(code)] else nil
		total += width or ESTIMATE_EM
	end
	return total
end

--[[
	Builds an amount holder in `parent` (transparent, full size of its slot; reposition / resize
	`handle.frame` like any label).
	@param parent  GuiObject / BillboardGui the holder goes in
	@param options see Options (aspect = holder px width / px height)
	@return Handle
]]
function CurrencyText.new(parent: Instance, options: Options): Handle
	measureFont(options.font)
	local zIndex = options.zIndex or 3
	local frame = Create.new("Frame", {
		Name = "CurrencyText",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex,
		Parent = parent,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(GAP, 0),
			}),
		},
	}) :: Frame
	local stroke: UIStroke? = nil
	if options.stroke > 0 then
		stroke = Create.new("UIStroke", {
			Color = options.strokeColor or Color3.new(0, 0, 0),
			Thickness = options.stroke,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
			LineJoinMode = Enum.LineJoinMode.Round,
		}) :: UIStroke
	end
	local label = Create.new("TextLabel", {
		Name = "Amount",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		TextScaled = true,
		FontFace = options.font,
		TextColor3 = options.color,
		Text = "",
		LayoutOrder = 2,
		ZIndex = zIndex,
		Parent = frame,
		Children = if stroke ~= nil then { stroke } else nil,
	}) :: TextLabel
	return {
		frame = frame,
		label = label,
		stroke = stroke,
		icon = nil,
		iconKey = nil,
		options = options,
		text = "",
	}
end

--[[
	Shows `text`, led by the `iconKey` icon when given (nil = plain text filling the holder).
	Writes only what changed. Example: CurrencyText.set(handle, "+1.2K", "Bones")
]]
function CurrencyText.set(handle: Handle, text: string, iconKey: string?)
	local options = handle.options
	if iconKey ~= nil and handle.iconKey ~= iconKey then
		-- (Re)build the icon for a new key (pooled pops may switch worlds).
		local old = handle.icon
		if old ~= nil then
			old:Destroy()
		end
		local zIndex = options.zIndex or 3
		local icon = StudUI.icon(iconKey, 64, zIndex)
		icon.Name = "CurrencyIcon"
		icon.LayoutOrder = 1
		icon.Size = UDim2.fromScale(1, options.iconHeight or 0.86)
		Create.new("UIAspectRatioConstraint", {
			AspectRatio = 1,
			DominantAxis = Enum.DominantAxis.Height,
			Parent = icon,
		})
		icon.Parent = handle.frame
		handle.icon = icon
		handle.iconKey = iconKey
	end
	local icon = handle.icon
	if icon ~= nil then
		local show = iconKey ~= nil
		if icon.Visible ~= show then
			icon.Visible = show
		end
	end
	if handle.text ~= text or handle.label.Text ~= text then
		handle.text = text
		handle.label.Text = text
	end
	-- Label width: the full holder for plain text; the text's own width beside an icon, so the
	-- [icon][text] pair is centred (holder aspect converts ems to a width scale).
	local width = 1
	if iconKey ~= nil then
		local iconWidth = (options.iconHeight or 0.86) / options.aspect
		width = math.min(emWidth(text, options.font) * SLACK / options.aspect, 1 - iconWidth - GAP)
	end
	local size = UDim2.fromScale(width, 1)
	if handle.label.Size ~= size then
		handle.label.Size = size
	end
end

--[[ Re-colours the amount text (e.g. affordable / not). ]]
function CurrencyText.setColor(handle: Handle, color: Color3)
	if handle.label.TextColor3 ~= color then
		handle.label.TextColor3 = color
	end
end

--[[
	The ImageLabel of the current icon (uploaded image), or nil (no icon / glyph fallback): pops
	tween its ImageTransparency with the text.
]]
function CurrencyText.iconImage(handle: Handle): ImageLabel?
	local icon = handle.icon
	local image = if icon ~= nil then icon:FindFirstChild("Image") else nil
	return if image ~= nil and image:IsA("ImageLabel") then image else nil
end

return CurrencyText
