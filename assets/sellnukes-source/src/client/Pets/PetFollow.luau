--!strict
--[[
	PetFollow — pure follow-animation math for the pet renderer (no instances, no services), so
	the formation and the motion curves are unit-tested (tests/pets-follow.luau).

	Formation: pets walk in arcs BEHIND their owner. Row r (0-based) holds up to RowSize pets
	spread `Spacing` studs apart across the owner's back, `Distance + r × RowGap` studs behind,
	and the arc bends forward at its ends (|x| × Curve) so the team hugs the owner.
	Owner space: +X = owner's right, +Z = behind the owner (a character looks down -Z).

	Motion: exponential smoothing `alpha = 1 - e^(-sharpness × dt)` (frame-rate independent) of the
	follow BASE (ground + species hover). Since R44 the hops / bobs / waddles are PetAnim's pose on
	top of that base (so the smoothing never flattens them); `lift` stays as the reference hop /
	bob curve (tests/pets-follow.luau) and its BobRate / BobHeight drive PetAnim's airborne bob.

	Connects to: Shared/Config/PetConfig.Follow, Client/Pets/{PetController, PetAnim},
	tests/pets-follow.luau.

	Example:
		local offset = PetFollow.slotOffset(2, 5)   --> Vector3 (owner space)
		local a = PetFollow.alpha(9, 1/60)          --> 0.139...
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)

local Follow = PetConfig.Follow

local PetFollow = {}

-- How much the arc bends forward per stud of sideways offset.
PetFollow.Curve = 0.22

--[[
	The owner-space offset of pet `index` (1-based) in a team of `count`.
	Example: PetFollow.slotOffset(1, 1) --> (0, 0, Distance)
]]
function PetFollow.slotOffset(index: number, count: number): Vector3
	local perRow = Follow.RowSize
	local row = (index - 1) // perRow
	local inRow = (index - 1) % perRow
	local rowCount = math.min(perRow, count - row * perRow)
	local x = (inRow - (rowCount - 1) / 2) * Follow.Spacing
	local z = Follow.Distance + row * Follow.RowGap - math.abs(x) * PetFollow.Curve
	return Vector3.new(x, 0, z)
end

--[[ Frame-rate independent smoothing factor for `sharpness` over `dt` seconds (0..1). ]]
function PetFollow.alpha(sharpness: number, dt: number): number
	return 1 - math.exp(-sharpness * math.max(dt, 0))
end

--[[
	The vertical animation offset at time `t`.
	@param hover  the species' flying height in studs (PetConfig hover; 0 = a ground pet)
	@param moving the owner is walking (ground pets hop only then)
	@param phase  per-pet phase so a team never hops in lockstep
	Example: PetFollow.lift(1.0, false, t, 0.2) --> 1.0 ± BobHeight
]]
function PetFollow.lift(hover: number, moving: boolean, t: number, phase: number): number
	if hover > 0 then
		return hover + math.sin((t + phase) * Follow.BobRate * math.pi * 2) * Follow.BobHeight
	end
	if moving then
		return math.abs(math.sin((t + phase) * Follow.HopRate * math.pi)) * Follow.HopHeight
	end
	return 0
end

--[[
	Shortest signed angle from `from` to `to` (radians, in (-π, π]).
	Example: PetFollow.angleDelta(math.rad(350), math.rad(10)) --> math.rad(20)
]]
function PetFollow.angleDelta(from: number, to: number): number
	local delta = (to - from) % (math.pi * 2)
	if delta > math.pi then
		delta -= math.pi * 2
	end
	return delta
end

return table.freeze(PetFollow)
