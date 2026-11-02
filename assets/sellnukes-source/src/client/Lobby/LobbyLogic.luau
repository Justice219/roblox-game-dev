--!strict
--[[
	LobbyLogic — pure rules of the lobby fixtures (owner R99 / R101): no Instances, Lune-tested
	(tests/lobby.luau). Client/Lobby/LobbyFixtures owns the Instances and calls these.

		insideBox(cf, size, point)        point inside an oriented box
		insideWalkOn(anchorCf, walkOn, p)  point inside a fixture's walk-on volume (box ∩ octagon)
		newWalkOn() / walkOnStep(...)      the Lucky Wheel platform's "step on → open once" rule
		wheelAngle(t, duration, delta)     the physical wheel's eased-out spin (cosmetic)
		nearestFixture(points, root, reach) which fixture prompt point is in reach (platform action)

	Walk-on rule (LobbyConfig.WalkOn): an ENTRY (outside → inside) opens the screen when the player
	was outside for at least RearmSeconds, Cooldown seconds passed since the last walk-on open and
	nothing blocks (a window is open, another world, no character). An entry that is blocked is
	consumed — the player steps off and on again — so closing the wheel while standing on the
	platform never re-opens it, and a player who walks on while a window is open is not ambushed
	the moment it closes.

	Example:
		local state = LobbyLogic.newWalkOn()
		if LobbyLogic.walkOnStep(state, inside, os.clock(), blocked) then open() end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LobbyConfig = require(ReplicatedStorage.Shared.Config.LobbyConfig)

local WalkOn = LobbyConfig.WalkOn

export type WalkOnState = {
	inside: boolean,
	outsideSince: number, -- clock time the player last left the volume (-inf = never inside yet)
	lastOpenAt: number,
}

local LobbyLogic = {}

--[[
	True when `point` lies inside the box of `size` centred on `cf` (any orientation).
	Example: LobbyLogic.insideBox(CFrame.new(), Vector3.new(2, 2, 2), Vector3.new(0.5, 0, 0)) --> true
]]
function LobbyLogic.insideBox(cf: CFrame, size: Vector3, point: Vector3): boolean
	local localPoint = cf:PointToObjectSpace(point)
	return math.abs(localPoint.X) <= size.X / 2
		and math.abs(localPoint.Y) <= size.Y / 2
		and math.abs(localPoint.Z) <= size.Z / 2
end

--[[
	True when `point` is inside a fixture's walk-on volume: the `walkOn.offset` / `walkOn.size` box in
	the anchor's frame and, with `walkOn.octagon`, the regular octagon of that apothem around the
	anchor (XZ) — the Lucky Wheel stage's footprint.
	Example: LobbyLogic.insideWalkOn(stageCf, { offset = CFrame.new(0, 4, -5), size = Vector3.new(18, 7, 9),
		octagon = 9.6 }, rootPosition) --> true while standing on the stage in front of the wheel
]]
function LobbyLogic.insideWalkOn(anchorCf: CFrame, walkOn: LobbyConfig.WalkOn, point: Vector3): boolean
	if not LobbyLogic.insideBox(anchorCf * walkOn.offset, walkOn.size, point) then
		return false
	end
	local apothem = walkOn.octagon
	if apothem == nil then
		return true
	end
	local p = anchorCf:PointToObjectSpace(point)
	local ax, az = math.abs(p.X), math.abs(p.Z)
	return ax <= apothem and az <= apothem and ax + az <= apothem * math.sqrt(2)
end

--[[ A fresh walk-on state (counts as "outside for ever", so the first entry can open). ]]
function LobbyLogic.newWalkOn(): WalkOnState
	return { inside = false, outsideSince = -math.huge, lastOpenAt = -math.huge }
end

--[[
	Advances the walk-on rule by one poll.
	@param inside   the player's root is inside the volume now
	@param now      clock seconds
	@param blocked  something forbids opening now (window open, other world, no character)
	@return boolean — true exactly when the screen should open on this poll
]]
function LobbyLogic.walkOnStep(state: WalkOnState, inside: boolean, now: number, blocked: boolean): boolean
	if not inside then
		if state.inside then
			state.outsideSince = now
		end
		state.inside = false
		return false
	end
	if state.inside then
		return false -- still standing on it: one open per entry
	end
	state.inside = true
	local rearmed = now - state.outsideSince >= WalkOn.RearmSeconds
	local cooled = now - state.lastOpenAt >= WalkOn.Cooldown
	if rearmed and cooled and not blocked then
		state.lastOpenAt = now
		return true
	end
	return false
end

--[[
	The physical wheel's extra angle `t` seconds into a spin of `delta` radians lasting `duration`
	(ease-out cubic: fast start, gentle landing; clamped to [0, delta]).
	Example: LobbyLogic.wheelAngle(4, 4, 10) --> 10
]]
function LobbyLogic.wheelAngle(t: number, duration: number, delta: number): number
	if not (duration > 0) or t >= duration then
		return delta
	end
	if t <= 0 then
		return 0
	end
	local u = 1 - t / duration
	return delta * (1 - u * u * u)
end

--[[
	The index of the nearest point within `reach` of `root` (nil when none is).
	@param points  { Vector3? } — a nil entry is skipped (fixture without a prompt)
	Example: LobbyLogic.nearestFixture({ Vector3.new(0, 0, 5) }, Vector3.zero, 12) --> 1
]]
function LobbyLogic.nearestFixture(points: { Vector3 | false }, root: Vector3, reach: number): number?
	local best: number? = nil
	local bestDistance = reach
	for index, point in points do
		if point ~= false then
			local distance = (point - root).Magnitude
			if distance <= bestDistance then
				best, bestDistance = index, distance
			end
		end
	end
	return best
end

return table.freeze(LobbyLogic)
