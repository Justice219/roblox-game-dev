--!strict
--[[
	Pet follow-animation math (src/client/Pets/PetFollow.luau). Run:
		lune run tests/pets-follow

	Proves:
	  1. Formation: every team size 1..7 puts each pet behind the owner (z > 0), no two pets in
	     the same spot (≥ Spacing apart within a row), rows are symmetric around the owner and a
	     second row sits further back.
	  2. Smoothing is frame-rate independent: two half steps == one full step.
	  3. Lift: flyers hover around their species height, ground pets stay grounded while idle and never go
	     below the ground while hopping.
	  4. angleDelta takes the short way round.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local PetFollow = loader.load("src/client/Pets/PetFollow")
local PetConfig = loader.load("src/shared/Config/PetConfig")

local Follow = PetConfig.Follow

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- 1. Formation.
for count = 1, PetConfig.Slots.Max do
	local offsets = {}
	for index = 1, count do
		local offset = PetFollow.slotOffset(index, count)
		check(offset.Z > 0, `pet {index}/{count} behind the owner`)
		check(offset.Y == 0, "formation is flat")
		table.insert(offsets, offset)
	end
	for a = 1, count do
		for b = a + 1, count do
			check((offsets[a] - offsets[b]).Magnitude >= Follow.Spacing * 0.9, `pets {a} and {b} of {count} apart`)
		end
	end
	-- Row symmetry: the x offsets of a full first row sum to 0.
	local rowCount = math.min(count, Follow.RowSize)
	local sum = 0
	for index = 1, rowCount do
		sum += offsets[index].X
	end
	check(math.abs(sum) < 1e-9, `row symmetric ({count})`)
	if count > Follow.RowSize then
		check(offsets[Follow.RowSize + 1].Z > offsets[1].Z, "second row further back")
	end
end
check(PetFollow.slotOffset(1, 1).X == 0 and PetFollow.slotOffset(1, 1).Z == Follow.Distance, "single pet right behind")

-- 2. Smoothing.
local full = PetFollow.alpha(9, 1 / 30)
local half = PetFollow.alpha(9, 1 / 60)
check(math.abs((1 - (1 - half) ^ 2) - full) < 1e-12, "frame-rate independent")
check(PetFollow.alpha(9, 0) == 0 and PetFollow.alpha(9, -1) == 0, "no negative dt")
check(PetFollow.alpha(9, 100) > 0.999, "converges")

-- 3. Lift.
for t = 0, 3, 0.05 do
	local flyer = PetFollow.lift(1.0, true, t, 0.3)
	check(math.abs(flyer - 1.0) <= Follow.BobHeight + 1e-9, "flyer hovers around its height")
	local hop = PetFollow.lift(0, true, t, 0.3)
	check(hop >= 0 and hop <= Follow.HopHeight + 1e-9, "hop stays above ground")
	check(PetFollow.lift(0, false, t, 0.3) == 0, "idle ground pet stays down")
end

-- 4. angleDelta.
check(math.abs(PetFollow.angleDelta(math.rad(350), math.rad(10)) - math.rad(20)) < 1e-9, "wraps forward")
check(math.abs(PetFollow.angleDelta(math.rad(10), math.rad(350)) + math.rad(20)) < 1e-9, "wraps back")
check(math.abs(PetFollow.angleDelta(0, math.pi)) <= math.pi + 1e-9, "half turn")

print(`[pets-follow] {checks} checks passed`)
