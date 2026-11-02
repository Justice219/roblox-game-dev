--!strict
--[[
	PanelBackdropConfig — numbers of Widgets/PanelBackdrop, the stud material laid over a panel
	(ported from RoBeasts; the edge-glint particles were dropped for SellNukes).

	Example: PanelBackdropConfig.TextureTransparency --> 0.6
]]
return table.freeze({
	-- Design px the material is inset from the panel edge (keeps it inside thick outlines).
	Inset = 0,
	-- Rendered corner radius used when the parent has no UICorner.
	DefaultCornerRadius = 6,
	-- Default stud opacity (1 = invisible).
	TextureTransparency = 0.6,
	-- Default tile draw size (design px per two-stud tile); callers usually pass UIStyleConfig.StudTile.
	TileSize = 96,
})
