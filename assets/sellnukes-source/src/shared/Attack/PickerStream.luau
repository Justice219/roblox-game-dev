--!strict
--[[
	PickerStream — the pure rules behind owner R104 ("you cant see peoples bases in the attack
	menu"): which target the picker may stream, where the stream focus goes, which container holds
	the target's parts, and when the "LOADING BASE..." shimmer may disappear.

	Why it exists: Workspace.StreamingEnabled (default.project.json: StreamOutBehavior Opportunistic,
	StreamingTargetRadius 768 around the replication focus = the CHARACTER) means another player's
	plot (900+ studs away across the hub) or a Rival island (1080 studs out at sea) is simply not on
	the client. The old picker only fired a one-shot client RequestStreamAroundAsync, which Roblox
	documents as temporary, so the camera flew over empty sky. Now:
		* the client sends AttackPickerFocus(slot) (`readSlot` validates it on the server),
		* the server keeps ONE invisible anchored focus part per player at `focusPoint(slot, areas)`
		  (owner R133: the middle of the target's built base, Shared/Attack/PickerFrame) and
		  calls Player:AddReplicationFocus on it while the picker is open (+ a short linger after it
		  closes so the launch cinematic still sees the target), Server/Attack/PickerFocus,
		* the client also asks RequestStreamAroundAsync (the fast first push) and counts the
		  target's BaseParts in `container(slot)` every PollSeconds; `step` says when it is loaded.

	No services, no Instances: lune-testable (tests/attack-view.luau).

	Connects to: Shared/Attack/AttackGeometry (slots, picker view), Shared/Attack/PickerFrame (focus
	point, owner R133), Shared/Config/{AttackConfig, WorldLayout}; used by Server/Attack/PickerFocus and Client/Attack/PickerView.

	Example:
		local slot = PickerStream.readSlot(raw)            -- 0 = clear, 1..12 = a target, nil = junk
		local focus = PickerStream.focusPoint(3)            -- world point the stream focus sits on
		local folder, name = PickerStream.container(3)      -- "Plots", "Plot3"
		local load = PickerStream.newLoad()
		local done = PickerStream.step(load, partsNow, 0.2) -- true once the base is there
]]

local AttackConfig = require(script.Parent.Parent.Config.AttackConfig)
local AttackGeometry = require(script.Parent.AttackGeometry)
local PickerFrame = require(script.Parent.PickerFrame)

local PickerStream = {}

local STREAM = AttackConfig.Client.PickerStream

-- The loading probe's running state (one per framed target).
export type Load = {
	best: number, -- highest part count seen so far
	stable: number, -- polls since the count last grew
	elapsed: number, -- seconds since the target was framed
	done: boolean,
	reason: string?, -- "parts" | "cap" | "timeout" once done (QA / analytics)
}

--[[
	Validates the wire argument of AttackPickerFocus: 0 (clear the focus) or a valid target slot
	(a player plot 1..PlotCount or a Rival island). NaN, infinities, fractions, negatives, strings,
	tables and out-of-range numbers are refused.
	@param raw unknown — the client's argument
	@return number? — the slot (0 = clear), nil = refuse
	Example: PickerStream.readSlot(9) --> 9 (Rival 1); PickerStream.readSlot(0/0) --> nil
]]
function PickerStream.readSlot(raw: unknown): number?
	if type(raw) ~= "number" or raw ~= raw then
		return nil
	end
	if raw == 0 then
		return 0
	end
	return AttackGeometry.validTarget(raw)
end

--[[
	The world point the server's replication focus (and the client's first RequestStreamAroundAsync)
	sits on for a target slot. Owner R133: the middle of the target's BUILT footprint
	(Shared/Attack/PickerFrame.streamPoint) instead of the middle of the whole plot, so a new
	player's single area is well inside StreamingMinRadius rather than ~200 studs from the focus;
	StreamingTargetRadius around it still covers the whole plot. Rival islands: the island centre.
	@param slot number — a valid target slot
	@param areas { number }? — the target's built areas (nil = the whole plot)
	@return Vector3
	Example: PickerStream.focusPoint(3, { 1 }) -- plot 3's garage
]]
function PickerStream.focusPoint(slot: number, areas: { number }?): Vector3
	return PickerFrame.streamPoint(slot, areas)
end

--[[
	Where the target's parts live on the client: (Workspace child name, child name inside it).
	Player plots: Workspace.Plots.Plot<N> (World/PlotBuilder; ModelStreamingMode Default, so its
	parts stream by region); Rival islands: Workspace.AttackRivals.<rival id> (Attack/RivalIslands).
	@param slot number — a valid target slot
	@return (string, string)
	Example: PickerStream.container(9) --> "AttackRivals", "toy_factory"
]]
function PickerStream.container(slot: number): (string, string)
	local rivalIndex = AttackGeometry.rivalOfSlot(slot)
	if rivalIndex ~= nil then
		return AttackConfig.Rivals.Folder, AttackConfig.Rivals.List[rivalIndex].id
	end
	return "Plots", `Plot{slot}`
end

--[[ A fresh loading probe state (call when a new target is framed). ]]
function PickerStream.newLoad(): Load
	return { best = 0, stable = 0, elapsed = 0, done = false, reason = nil }
end

--[[
	Advances the loading probe by one poll and says whether the target counts as loaded:
		* "cap"     the count reached ProbeMax (plenty of base is there),
		* "parts"   at least MinParts and the count stopped growing for StableTicks polls (streaming
		            has delivered what is coming; a small early-game base still qualifies),
		* "timeout" LoadTimeout seconds passed (the shimmer never sticks: a bare plot, a slow link).
	@param load Load — mutated
	@param count number — BaseParts counted in the target container this poll (junk = 0)
	@param dt number — seconds since the previous poll
	@return boolean — true once loaded (stays true)
	Example:
		local load = PickerStream.newLoad()
		PickerStream.step(load, 40, 0.2) --> false (still growing)
]]
function PickerStream.step(load: Load, count: number, dt: number): boolean
	if load.done then
		return true
	end
	local n = if type(count) == "number" and count == count and count >= 0 then math.floor(count) else 0
	local seconds = if type(dt) == "number" and dt == dt and dt > 0 and dt < math.huge then dt else 0
	load.elapsed += seconds
	if n > load.best then
		load.best = n
		load.stable = 0
	else
		load.stable += 1
	end
	if n >= STREAM.ProbeMax then
		load.done, load.reason = true, "cap"
	elseif load.best >= STREAM.MinParts and load.stable >= STREAM.StableTicks then
		load.done, load.reason = true, "parts"
	elseif load.elapsed >= STREAM.LoadTimeout then
		load.done, load.reason = true, "timeout"
	end
	return load.done
end

return PickerStream
