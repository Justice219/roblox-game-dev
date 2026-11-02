--!strict
--[[
	ShopText — keeps the Shop's auto-sized (TextScaled) labels whole at EVERY window scale: pack
	tile captions ("Golden Atom Pup pet"), pass perks, card names / previews / descriptions.

	Why (lead follow-up, owner R11 small screens): a UITextSizeConstraint's Min/MaxTextSize are
	ABSOLUTE pixels — the UI scale chain (ScreenManager AutoScale x ModalShell fit x the Shop's
	content UIScale) shrinks the label box but not the constraint. On a small window (scale ~0.5)
	the 18 px "readability floor" became 36 design px, so a 56 design px caption box only fit one
	line and the second line silently disappeared ("Golden" instead of "Golden Atom Pup pet").

	Rule: every recorded constraint keeps its DESIGN min / max (attributes) and is re-applied as
	design x the label's measured scale (AbsoluteSize.Y / its design offset height). A caption
	sized for two lines at its design minimum therefore always fits two lines; on touch screens
	ShopLayout's content scale already keeps that minimum >= 14 pt on the device. Labels also get
	TextTruncate.AtEnd, so text that can never fit ends in "..." instead of losing words unseen.

	Performance: collect() once after the Shop is built; apply() only after a layout change has
	settled (Shop/init debounces it), touching ~150 constraints and writing only changed values.

	Connects to: Shop/init (collect + apply), Shop/ShopCard + Shop/PackCard (their scaled labels
	carry StudUI.text's UITextSizeConstraint), tests/model-viewport.luau (scaled()).

	Example:
		local constraints = {}
		ShopText.collect(content, constraints)   -- after every card is built
		ShopText.apply(constraints)              -- after each settled re-layout
]]

local ShopText = {}

-- Attributes holding a constraint's design sizes (recorded once by collect).
ShopText.MinAttribute = "DesignMinText"
ShopText.MaxAttribute = "DesignMaxText"

--[[
	Absolute (min, max) text sizes for design sizes at an effective scale. Pure.
	@param designMin number  design-px minimum
	@param designMax number  design-px maximum
	@param factor number     absolute px per design px (non-finite / <= 0 -> 1)
	@return (min, max) whole pixels, min >= 1, max >= min
	Example: ShopText.scaled(18, 28, 0.5) --> 9, 14
]]
function ShopText.scaled(designMin: number, designMax: number, factor: number): (number, number)
	local f = if factor == factor and factor > 0 and factor < math.huge then factor else 1
	local min = math.max(1, math.floor(designMin * f + 0.5))
	local max = math.max(min, math.floor(designMax * f + 0.5))
	return min, max
end

--[[
	Records every UITextSizeConstraint under `root` (design sizes = their values now, i.e. before
	any apply) into `into`, and gives its label TextTruncate.AtEnd. Idempotent per constraint.
	@param root Instance
	@param into { UITextSizeConstraint }
]]
function ShopText.collect(root: Instance, into: { UITextSizeConstraint })
	for _, item in root:GetDescendants() do
		if item:IsA("UITextSizeConstraint") and item:GetAttribute(ShopText.MinAttribute) == nil then
			item:SetAttribute(ShopText.MinAttribute, item.MinTextSize)
			item:SetAttribute(ShopText.MaxAttribute, item.MaxTextSize)
			local label = item.Parent
			if label ~= nil and label:IsA("TextLabel") then
				label.TextTruncate = Enum.TextTruncate.AtEnd
			end
			table.insert(into, item)
		end
	end
end

--[[
	Re-applies every recorded constraint at its label's measured scale. Labels sized by scale
	(no design offset height) or not laid out yet (AbsoluteSize 0) are left as they are.
	@param constraints { UITextSizeConstraint } (from collect)
]]
function ShopText.apply(constraints: { UITextSizeConstraint })
	for _, constraint in constraints do
		local label = constraint.Parent
		if label == nil or not label:IsA("GuiObject") then
			continue
		end
		local size = (label :: GuiObject).Size.Y
		local absolute = (label :: GuiObject).AbsoluteSize.Y
		local designMin = constraint:GetAttribute(ShopText.MinAttribute)
		local designMax = constraint:GetAttribute(ShopText.MaxAttribute)
		if size.Scale ~= 0 or size.Offset <= 0 or absolute <= 0 then
			continue
		end
		if type(designMin) ~= "number" or type(designMax) ~= "number" then
			continue
		end
		local min, max = ShopText.scaled(designMin, designMax, absolute / size.Offset)
		-- Max first when growing, min first when shrinking (Min may never exceed Max).
		if min > constraint.MaxTextSize then
			constraint.MaxTextSize = max
			constraint.MinTextSize = min
		else
			if constraint.MinTextSize ~= min then
				constraint.MinTextSize = min
			end
			if constraint.MaxTextSize ~= max then
				constraint.MaxTextSize = max
			end
		end
	end
end

return table.freeze(ShopText)
