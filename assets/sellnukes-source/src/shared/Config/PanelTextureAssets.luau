--!strict
--[[
	PanelTextureAssets — the uploaded copy of the RoBeasts embossed stud tile.

	Purpose:
		Every SellNukes UI surface (windows, cards, buttons, HUD tiles) is "stud-textured" with the
		exact RoBeasts tile (owner rule 2: "the same stud texture UI from RoBeasts"). The PRIMARY
		source is the client-built EditableImage (Config/PanelStudPixels + Widgets/StudTextureLocal);
		this uploaded image is the FALLBACK used when EditableImage is unavailable (budget / policy).
		The asset is owned by the same Roblox user as the SellNukes place, so it loads here.

	Facts:
		One 256px tile is a 2x2 two-tone checker (light studs on the diagonal, dark studs off it).
		`TileSize` is the RoBeasts default draw size (128 design px = 64 px per stud cell); StudUI
		draws smaller tiles on small surfaces (UIStyleConfig.StudTile) so buttons still show
		several studs per row, like the reference images.

	LocalBitmap (owner switch): the client-built EditableImage copy is used ONLY when this is true.
	The SellNukes experience currently has the EditableImage API disabled (Experience Settings >
	Security), and in that state Studio still lets the client create the bitmap but RENDERS a
	magenta / green placeholder checker (verified 2026-10-30 in the iPhone 14 simulator) — script
	cannot detect it (a pixel read-back succeeds). So the uploaded, engine-mipmapped image is the
	default. To use the CDN-independent local copy: enable the EditableImage API for the
	experience, then set LocalBitmap = true (StudTextureLocal builds 256/128/64/32 mip levels).

	Connects to: Widgets/StudTexture (fallback loader), Widgets/PanelBackdrop, Kit/StudUI.

	Example:
		image.Image = PanelTextureAssets.StudImage
		image.ScaleType = Enum.ScaleType.Tile
		image.TileSize = UDim2.fromOffset(PanelTextureAssets.TileSize, PanelTextureAssets.TileSize)
]]
return table.freeze({
	AssetId = 99905873366381,
	StudImage = "rbxassetid://99905873366381",
	TileSize = 128,
	-- See the header: true only after the experience's EditableImage API is enabled.
	LocalBitmap = false,
})
