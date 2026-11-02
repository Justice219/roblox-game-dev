--!strict
--[[
	ScreenRect — where a GuiObject really is on the screen, for screen-space effects (owner R61:
	"when you upgrade, the coins like go on the left side of the screen").

	Why it exists:
		Effects drawn on a full-screen overlay (UI/ButtonFeedback particle bursts, UI/Hud/
		CurrencyFly origins) placed themselves at `button.AbsolutePosition`. That is right for a
		ScreenGui button, but a button inside a BillboardGui (the producer billboards' UPGRADE /
		click buttons) reports AbsolutePosition / AbsoluteSize in the BILLBOARD's own canvas (a few
		hundred px from 0, 0), so the burst landed around the top-left HUD tiles. `of(object)`
		projects billboard descendants through the camera instead; ScreenGui descendants keep
		their AbsolutePosition unchanged.

	Coordinates: GUI space, i.e. the same space ScreenGui AbsolutePosition uses (the viewport
	minus GuiService:GetGuiInset()), so callers keep subtracting their overlay's AbsolutePosition
	exactly as before.

	Math (pure, `billboard`, tests/currency-fly.luau): a stud-sized BillboardGui is drawn at the
	camera-space depth `z` of its adornee point with pixelsPerStud = viewportHeight /
	(2 * z * tan(fov / 2)); its on-screen size = Size.Scale * pixelsPerStud + Size.Offset, centred
	on the projected point shifted by SizeOffset (fractions of that size). A descendant maps
	through scale = onScreenSize / billboard.AbsoluteSize — which is ~1 when the engine already
	reports screen space, so both conventions land in the right place.
	Ignored: ExtentsOffset / ExtentsOffsetWorldSpace (no SellNukes billboard uses them).

	Connects to: UI/ButtonFeedback (press bursts), UI/Hud/CurrencyFly (fromGui origins),
	tests/currency-fly.luau (billboard math).

	Example:
		local position, size = ScreenRect.of(upgradeButton)
		if position ~= nil then burstAt(position - overlay.AbsolutePosition, size) end
]]

local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

export type BillboardInput = {
	point: Vector3, -- WorldToViewportPoint of the adornee point (X, Y viewport px; Z = depth)
	viewportY: number, -- camera ViewportSize.Y
	fov: number, -- camera FieldOfView (degrees, vertical)
	size: UDim2, -- BillboardGui.Size (Scale = studs, Offset = px)
	sizeOffset: Vector2, -- BillboardGui.SizeOffset (fractions of the on-screen size)
	guiPosition: Vector2, -- BillboardGui.AbsolutePosition
	guiSize: Vector2, -- BillboardGui.AbsoluteSize
	objectPosition: Vector2, -- the descendant's AbsolutePosition
	objectSize: Vector2, -- the descendant's AbsoluteSize
	inset: Vector2, -- GuiService:GetGuiInset() top-left (viewport -> GUI space)
}

local ScreenRect = {}

--[[
	The on-screen rect (GUI space) of a BillboardGui descendant from plain numbers.
	@return (position, size), or nil when the billboard is behind the camera / degenerate
	Example: ScreenRect.billboard({ point = Vector3.new(960, 540, 20), viewportY = 1080, fov = 70,
		size = UDim2.fromScale(8, 4), ... })
]]
function ScreenRect.billboard(input: BillboardInput): (Vector2?, Vector2?)
	local depth = input.point.Z
	if depth <= 0.05 or input.viewportY <= 0 or input.guiSize.X <= 0 or input.guiSize.Y <= 0 then
		return nil, nil
	end
	local pixelsPerStud = input.viewportY / (2 * depth * math.tan(math.rad(input.fov) / 2))
	local width = input.size.X.Scale * pixelsPerStud + input.size.X.Offset
	local height = input.size.Y.Scale * pixelsPerStud + input.size.Y.Offset
	if width <= 0 or height <= 0 then
		return nil, nil
	end
	-- Centre: the projected point, shifted by SizeOffset (Y up on screen = minus).
	local centreX = input.point.X + input.sizeOffset.X * width
	local centreY = input.point.Y - input.sizeOffset.Y * height
	local left = centreX - width / 2 - input.inset.X
	local top = centreY - height / 2 - input.inset.Y
	local scaleX = width / input.guiSize.X
	local scaleY = height / input.guiSize.Y
	local inGui = input.objectPosition - input.guiPosition
	return Vector2.new(left + inGui.X * scaleX, top + inGui.Y * scaleY),
		Vector2.new(input.objectSize.X * scaleX, input.objectSize.Y * scaleY)
end

-- The world point a BillboardGui hangs at (its adornee + StudsOffsetWorldSpace + camera-space
-- StudsOffset), or nil without a usable adornee.
local function anchorOf(gui: BillboardGui, camera: Camera): Vector3?
	local adornee: Instance? = gui.Adornee or gui.Parent
	local base: Vector3? = nil
	if adornee ~= nil then
		if adornee:IsA("Attachment") then
			base = adornee.WorldPosition
		elseif adornee:IsA("BasePart") then
			base = adornee.Position
		elseif adornee:IsA("Model") then
			base = adornee:GetPivot().Position
		end
	end
	if base == nil then
		return nil
	end
	return base + gui.StudsOffsetWorldSpace + camera.CFrame:VectorToWorldSpace(gui.StudsOffset)
end

--[[
	The on-screen rect of `object` in GUI space (see the module header): AbsolutePosition /
	AbsoluteSize for ScreenGui descendants, the projected rect for BillboardGui descendants
	(nil when that billboard is off screen / behind the camera / has no adornee). Objects in a
	SurfaceGui (no screen rect) return nil.
	Example: local position, size = ScreenRect.of(button)
]]
function ScreenRect.of(object: GuiObject): (Vector2?, Vector2?)
	local layer = object:FindFirstAncestorWhichIsA("LayerCollector")
	if layer == nil or layer:IsA("ScreenGui") then
		return object.AbsolutePosition, object.AbsoluteSize
	end
	if not layer:IsA("BillboardGui") then
		return nil, nil
	end
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return nil, nil
	end
	local anchor = anchorOf(layer, camera)
	if anchor == nil then
		return nil, nil
	end
	local point, onScreen = camera:WorldToViewportPoint(anchor)
	if not onScreen then
		return nil, nil
	end
	local inset = GuiService:GetGuiInset()
	return ScreenRect.billboard({
		point = point,
		viewportY = camera.ViewportSize.Y,
		fov = camera.FieldOfView,
		size = layer.Size,
		sizeOffset = layer.SizeOffset,
		guiPosition = layer.AbsolutePosition,
		guiSize = layer.AbsoluteSize,
		objectPosition = object.AbsolutePosition,
		objectSize = object.AbsoluteSize,
		inset = inset,
	})
end

return table.freeze(ScreenRect)
