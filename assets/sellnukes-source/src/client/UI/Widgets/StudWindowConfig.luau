--!strict
--[[
	StudWindowConfig — numbers of the stud-surface drawing parts (Widgets/StudWindow): the
	surface gradient, the 3D lip, the light sunburst behind reward icons and the dark spiky
	starburst behind right-column Robux offers. Presentation only.

	Example: StudWindowConfig.Sunburst.Rays --> 12
]]
return table.freeze({
	-- Surface gradient: the preset's `top` colour at the top fading to `bottom` (rotation 90).
	-- Rainbow surfaces rotate their gradient diagonally instead.
	RainbowRotation = 35,
	-- A soft top highlight band on surfaces (white, mostly transparent).
	Highlight = table.freeze({ Height = 0.42, Transparency = 0.82 }),
	-- Light sunburst (behind card / offer icons): ray pairs through the centre.
	Sunburst = table.freeze({
		Rays = 12, -- frames; each draws two opposite rays
		Width = 0.12, -- ray width as a fraction of the burst size
		Transparency = 0.55, -- at the brightest point
		Color = Color3.fromRGB(255, 255, 255),
	}),
	-- Dark spiky starburst (behind right-column offers): tapered spikes from stacked bars.
	Starburst = table.freeze({
		Spikes = 9, -- frames per layer; each draws two opposite spikes (18 spikes)
		-- Stacked bar layers (width fraction, length fraction): long narrow -> short wide = taper.
		Layers = table.freeze({
			table.freeze({ width = 0.05, length = 1.0 }),
			table.freeze({ width = 0.1, length = 0.74 }),
			table.freeze({ width = 0.16, length = 0.5 }),
		}),
		Transparency = 0.62, -- per layer (overlaps darken the centre: a radial falloff for free)
		Color = Color3.fromRGB(28, 30, 40),
	}),
})
