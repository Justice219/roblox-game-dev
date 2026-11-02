--!strict
--[[
	ButtonFeedbackRules — pure maths of the press feedback (owner rule R22: "particles that spin
	around the button or drop down from it" + a sound on every press). Ported from RoBeasts'
	ButtonFeedbackRules and re-shaped for SellNukes.

	Purpose:
		No Instances, no services: Lune-testable decisions used by UI/ButtonFeedback.
			count(tier, reduced, big)   particles per press (0 with reduced motion = sound only)
			pose(seed, age, w, h)       one particle's offset / rotation / fade / scale at `age`:
			                            it ORBITS just outside the button (an ellipse around its
			                            rectangle) for the first ORBIT share of the life, then
			                            DROPS with gravity while fading
			soundFor(kind, locked, explicit)  which Sound key a press plays

	Kinds: "Stars" (default), "Studs" (HUD tiles), "Coins" (purchases, claims, upgrades: bigger).

	Connects to: UI/ButtonFeedback (the only caller), tests (pure).

	Example:
		local dx, dy, rot, fade, scale = Rules.pose(7, 0.3, 200, 60)
]]

export type Kind = "Stars" | "Studs" | "Coins"

local Rules = {}

-- Seconds a particle lives.
Rules.Duration = 0.85
-- Share of the life spent orbiting before the drop.
Rules.Orbit = 0.42
-- Most particles alive at once (pool size; console / phone budget).
Rules.Capacity = 36
-- Minimum seconds between two bursts (a held / spammed button never floods the pool).
Rules.MinGap = 0.05

local KINDS: { [string]: Kind } = { Stars = "Stars", Studs = "Studs", Coins = "Coins" }

--[[
	A valid kind from an untyped attribute, else "Stars".
	Example: Rules.kind("Coins") --> "Coins"; Rules.kind(42) --> "Stars"
]]
function Rules.kind(value: unknown): Kind
	return if type(value) == "string" and KINDS[value] ~= nil then KINDS[value] else "Stars"
end

--[[
	Particles per press for a graphics tier ("Low" | "Mid" | "High"). Reduced motion -> 0 (the
	press keeps its sound and the button's own squash). Big presses (purchases / claims /
	upgrades) get half as many again.
	Example: Rules.count("Low", false, false) --> 5
]]
function Rules.count(tier: string, reduced: boolean, big: boolean): number
	if reduced then
		return 0
	end
	local base = if tier == "High" then 12 elseif tier == "Low" then 5 else 8
	return if big then math.floor(base * 1.5) else base
end

--[[
	One particle's pose `age` seconds after the press, relative to the button centre.
	@param seed  per-particle seed (decorrelates particles + rapid presses, no randomness)
	@param age   seconds since the press
	@param w / h the button's on-screen size (px): the orbit hugs its outline
	@return dx, dy (px), rotation (deg), fade (0 = opaque .. 1 = gone), scale
]]
function Rules.pose(seed: number, age: number, w: number, h: number): (number, number, number, number, number)
	local t = math.clamp(age / Rules.Duration, 0, 1)
	local start = seed * 2.399963229728653 -- golden angle: even spacing around the button
	local spin = start + t * 5.5 -- just under one full turn while alive
	local grow = 0.55 + 0.45 * math.min(t / 0.15, 1) -- bursts out from the outline
	local rx, ry = w * 0.5 + 12, h * 0.5 + 12
	local x = math.cos(spin) * rx * grow
	local y = math.sin(spin) * ry * grow
	-- Drop: after the orbit share, gravity pulls the particle down and it drifts sideways.
	local fall = math.max(0, t - Rules.Orbit)
	y += fall * fall * 950
	x += fall * (if seed % 2 == 0 then 70 else -70)
	local fade = math.clamp((t - 0.6) / 0.4, 0, 1)
	local scale = (0.7 + 0.3 * math.min(t / 0.1, 1)) * (1 - 0.3 * t)
	local rotation = (seed % 2 * 2 - 1) * 260 * t
	return x, y, rotation, fade, scale
end

--[[
	The Sound key of a press: an explicit key wins ("" = silent), a locked / unaffordable button
	plays "ui_locked", Coins presses "ui_claim", everything else "ui_click".
	Example: Rules.soundFor("Studs", false, nil) --> "ui_click"
]]
function Rules.soundFor(kind: Kind, locked: boolean, explicit: unknown): string
	if locked then
		return "ui_locked"
	end
	if type(explicit) == "string" and #explicit <= 32 then
		return explicit
	end
	return if kind == "Coins" then "ui_claim" else "ui_click"
end

return table.freeze(Rules)
