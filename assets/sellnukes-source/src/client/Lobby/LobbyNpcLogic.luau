--!strict
--[[
	LobbyNpcLogic — the PURE brain of the lobby visitors (owner R100). No Instances: positions are
	Vector3s on HubLayout.lobbyWalk, randomness comes from an injected `rand()` (0..1), so
	tests/lobby.luau simulates whole crowds under Lune and Client/Lobby/LobbyNpcs only renders.

	One visitor's life (mode):
		"walk"      toward `goal` (the target node + a jitter offset) at its own speed, turning
		            smoothly (Brain.TurnSpeed); on arrival it decides (see `arrive`)
		"idle"      stands `timer` seconds facing `lookYaw` (the node's look target, e.g. the egg
		            stands); may cheer / point / laugh once (Brain.EmoteChance)
		"toSeat"    walks node → seat approach point, then slides onto the seat (Brain.SitBlend)
		"sit"       sits `timer` seconds (seat occupancy is exclusive: `crowd.taken`)
		"fromSeat"  slides off to the approach point, walks back to the seat's node, decides again
	Next node: a random neighbour, never straight back where it came from unless it is a dead end.
	Waves: when the local player passes within Brain.WaveRange it may wave once (Brain.WaveChance,
	Brain.WaveCooldown) and an idle visitor turns toward the player.
	Reduced motion: nobody walks or emotes; everyone holds their pose (idle / sit).
	Frame hitches: `step` integrates in slices of at most Brain.MaxStep seconds.

	Speech: `pickSpeaker` chooses ONE nearby visitor + a line (never a line from the last
	Bubble.RecentLines picks) for LobbyBubbles.

	Connects to: Shared/Config/{LobbyNpcConfig, HubLayout (lobbyWalk type)}; used by
	Client/Lobby/LobbyNpcs and tests/lobby.luau.

	Example:
		local crowd = LobbyNpcLogic.newCrowd(HubLayout.lobbyWalk, 9, rand)
		LobbyNpcLogic.step(crowd, dt, playerPos, false, rand)
		for _, npc in crowd.npcs do print(npc.mode, npc.pos, npc.yaw) end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LobbyNpcConfig = require(ReplicatedStorage.Shared.Config.LobbyNpcConfig)

local Brain = LobbyNpcConfig.Brain

export type Mode = "walk" | "idle" | "toSeat" | "sit" | "fromSeat"
export type Emote = "wave" | "cheer" | "point" | "laugh"
export type Rand = () -> number

export type WalkNode = { pos: Vector3, jitter: number, idle: number, look: Vector3?, kind: string }
export type WalkSeat = { cf: CFrame, approach: Vector3, node: number }
export type Graph = { nodes: { WalkNode }, links: { { number } }, seats: { WalkSeat } }

export type Npc = {
	id: number,
	mode: Mode,
	node: number, -- the node it stands at / walked from
	target: number, -- the node it walks to ("walk")
	prev: number, -- the node before `node` (no straight backtracking)
	pos: Vector3, -- feet position on the walk surface
	yaw: number, -- facing (radians; Roblox yaw: 0 = +Z... see yawToward)
	goal: Vector3, -- the point it walks to
	speed: number,
	timer: number, -- seconds left idle / sitting / blending
	seat: number?, -- seat index while toSeat / sit / fromSeat
	seatPhase: number, -- 0..1 blend between approach (0) and seat (1)
	lookYaw: number?, -- desired yaw while idle
	emote: Emote?, -- one-shot request for the renderer (it clears it)
	waveCooldown: number,
	sitCooldown: number,
	nearPlayer: boolean, -- inside WaveRange last step (a wave is rolled once per approach)
}

export type Crowd = {
	graph: Graph,
	npcs: { Npc },
	taken: { [number]: number }, -- seat index → npc id
}

export type SpeakState = { recent: { number } }

local LobbyNpcLogic = {}

local TWO_PI = math.pi * 2
local TURN = math.rad(Brain.TurnSpeed)
local ARRIVE = 0.05

-- Uniform number in [lo, hi].
local function between(rand: Rand, lo: number, hi: number): number
	return lo + (hi - lo) * rand()
end

--[[
	Yaw (radians) that makes CFrame.Angles(0, yaw, 0) look from `from` toward `to` on the XZ plane
	(a Roblox character faces -Z, so the look direction d needs yaw = atan2(-d.X, -d.Z)).
	@return number? — nil when the points coincide (keep the current yaw)
	Example: LobbyNpcLogic.yawToward(Vector3.zero, Vector3.new(0, 0, -5)) --> 0
]]
function LobbyNpcLogic.yawToward(from: Vector3, to: Vector3): number?
	local dx, dz = to.X - from.X, to.Z - from.Z
	if dx * dx + dz * dz < 1e-6 then
		return nil
	end
	return math.atan2(-dx, -dz)
end

-- Shortest signed difference b - a in (-pi, pi].
local function angleDelta(a: number, b: number): number
	local d = (b - a) % TWO_PI
	if d > math.pi then
		d -= TWO_PI
	end
	return d
end
LobbyNpcLogic.angleDelta = angleDelta

-- Turns `npc.yaw` toward `want` by at most TurnSpeed * dt.
local function turnToward(npc: Npc, want: number?, dt: number)
	if want == nil then
		return
	end
	local d = angleDelta(npc.yaw, want)
	local maxTurn = TURN * dt
	if math.abs(d) <= maxTurn then
		npc.yaw = want
	else
		npc.yaw += if d > 0 then maxTurn else -maxTurn
	end
	npc.yaw %= TWO_PI
end

-- A random point within `radius` of `centre` on the walk plane.
local function jittered(centre: Vector3, radius: number, rand: Rand): Vector3
	if radius <= 0 then
		return centre
	end
	local angle = rand() * TWO_PI
	local r = radius * math.sqrt(rand())
	return Vector3.new(centre.X + math.cos(angle) * r, centre.Y, centre.Z + math.sin(angle) * r)
end

-- Starts walking from npc.node to `target`.
local function walkTo(crowd: Crowd, npc: Npc, target: number, rand: Rand)
	local node = crowd.graph.nodes[target]
	npc.prev = npc.node
	npc.target = target
	npc.goal = jittered(node.pos, node.jitter, rand)
	npc.mode = "walk"
	npc.lookYaw = nil
end

--[[
	The next node from `npc.node`: a random neighbour, not `npc.prev` unless it is the only way.
	@return number — a node index (npc.node itself only for an isolated node)
]]
function LobbyNpcLogic.nextNode(crowd: Crowd, npc: Npc, rand: Rand): number
	local links = crowd.graph.links[npc.node]
	if links == nil or #links == 0 then
		return npc.node
	end
	if #links == 1 then
		return links[1]
	end
	-- Pick among the links except prev: index into the list skipping prev (no allocation).
	local count = #links
	local hasPrev = table.find(links, npc.prev) ~= nil
	local choices = if hasPrev then count - 1 else count
	local pick = math.min(choices, math.floor(rand() * choices) + 1)
	for _, link in links do
		if not (hasPrev and link == npc.prev) then
			pick -= 1
			if pick == 0 then
				return link
			end
		end
	end
	return links[1]
end

-- A free seat attached to `node` (random among the free ones), or nil.
local function freeSeat(crowd: Crowd, node: number, rand: Rand): number?
	local found: number? = nil
	local seen = 0
	for index, seat in crowd.graph.seats do
		if seat.node == node and crowd.taken[index] == nil then
			seen += 1
			-- Reservoir sampling: each free seat equally likely, no temporary list.
			if rand() * seen < 1 then
				found = index
			end
		end
	end
	return found
end

--[[
	Decides what a visitor does at the node it just reached: sit (free seat, SitChance, not on its
	sit cooldown) → idle (the node's idle chance; faces the look target; may emote) → walk on.
]]
local function arrive(crowd: Crowd, npc: Npc, rand: Rand)
	local node = crowd.graph.nodes[npc.node]
	if npc.sitCooldown <= 0 and rand() < Brain.SitChance then
		local seat = freeSeat(crowd, npc.node, rand)
		if seat ~= nil then
			crowd.taken[seat] = npc.id
			npc.seat = seat
			npc.seatPhase = 0
			npc.mode = "toSeat"
			npc.goal = crowd.graph.seats[seat].approach
			npc.lookYaw = nil
			return
		end
	end
	if rand() < node.idle then
		npc.mode = "idle"
		npc.timer = between(rand, Brain.IdleMin, Brain.IdleMax)
		local look = node.look
		npc.lookYaw = if look ~= nil then LobbyNpcLogic.yawToward(npc.pos, look) else npc.yaw + between(rand, -1, 1)
		if look ~= nil and rand() < Brain.EmoteChance then
			local r = rand()
			npc.emote = if r < 0.45 then "cheer" elseif r < 0.8 then "point" else "laugh"
		end
		return
	end
	walkTo(crowd, npc, LobbyNpcLogic.nextNode(crowd, npc, rand), rand)
end

--[[
	A new visitor standing at `node` (idle a moment, so a fresh crowd does not march in step).
	@param id      unique id (1..n)
	@param node    starting node index
]]
function LobbyNpcLogic.newNpc(crowd: Crowd, id: number, node: number, rand: Rand): Npc
	local graph = crowd.graph
	local start = jittered(graph.nodes[node].pos, graph.nodes[node].jitter, rand)
	local npc: Npc = {
		id = id,
		mode = "idle",
		node = node,
		target = node,
		prev = node,
		pos = start,
		yaw = rand() * TWO_PI,
		goal = start,
		speed = between(rand, Brain.WalkSpeedMin, Brain.WalkSpeedMax),
		timer = between(rand, 0.5, Brain.IdleMax),
		seat = nil,
		seatPhase = 0,
		lookYaw = nil,
		emote = nil,
		waveCooldown = between(rand, 0, Brain.WaveCooldown),
		sitCooldown = between(rand, 0, Brain.SitCooldown * 0.5),
		nearPlayer = false,
	}
	return npc
end

--[[
	A crowd of `count` visitors on distinct random nodes (repeats only when count > #nodes).
	@return Crowd
	Example: LobbyNpcLogic.newCrowd(HubLayout.lobbyWalk, 9, rand)
]]
function LobbyNpcLogic.newCrowd(graph: Graph, count: number, rand: Rand): Crowd
	local crowd: Crowd = { graph = graph, npcs = {}, taken = {} }
	local order: { number } = {}
	for index in graph.nodes do
		table.insert(order, index)
	end
	-- Fisher-Yates shuffle with the injected rand (deterministic in tests).
	for i = #order, 2, -1 do
		local j = math.min(i, math.floor(rand() * i) + 1)
		order[i], order[j] = order[j], order[i]
	end
	for id = 1, math.max(0, math.floor(count)) do
		local node = order[(id - 1) % #order + 1]
		table.insert(crowd.npcs, LobbyNpcLogic.newNpc(crowd, id, node, rand))
	end
	return crowd
end

-- Moves `npc.pos` toward `npc.goal`; true on arrival.
local function moveToGoal(npc: Npc, dt: number): boolean
	local dx, dz = npc.goal.X - npc.pos.X, npc.goal.Z - npc.pos.Z
	local dist = math.sqrt(dx * dx + dz * dz)
	if dist <= ARRIVE then
		npc.pos = npc.goal
		return true
	end
	local stepLen = npc.speed * dt
	turnToward(npc, math.atan2(-dx, -dz), dt)
	if stepLen >= dist then
		npc.pos = npc.goal
		return true
	end
	npc.pos = Vector3.new(npc.pos.X + dx / dist * stepLen, npc.goal.Y, npc.pos.Z + dz / dist * stepLen)
	return false
end

-- One integration slice (dt <= Brain.MaxStep).
local function stepOne(crowd: Crowd, npc: Npc, dt: number, rand: Rand)
	npc.waveCooldown = math.max(0, npc.waveCooldown - dt)
	npc.sitCooldown = math.max(0, npc.sitCooldown - dt)
	local mode = npc.mode
	if mode == "walk" then
		if moveToGoal(npc, dt) then
			npc.node = npc.target
			arrive(crowd, npc, rand)
		end
	elseif mode == "idle" then
		turnToward(npc, npc.lookYaw, dt)
		npc.timer -= dt
		if npc.timer <= 0 then
			walkTo(crowd, npc, LobbyNpcLogic.nextNode(crowd, npc, rand), rand)
		end
	elseif mode == "toSeat" then
		local seat = crowd.graph.seats[npc.seat :: number]
		if npc.seatPhase <= 0 then
			-- Walking to the approach point; on arrival the slide starts next slice (one turn per slice).
			if moveToGoal(npc, dt) then
				npc.seatPhase = 1e-6
			end
			return
		end
		-- At the approach point: slide onto the seat, turning to its facing.
		npc.seatPhase = math.min(1, npc.seatPhase + dt / Brain.SitBlend)
		turnToward(npc, LobbyNpcLogic.yawToward(Vector3.zero, seat.cf.LookVector), dt * 3)
		if npc.seatPhase >= 1 then
			npc.mode = "sit"
			npc.timer = between(rand, Brain.SitMin, Brain.SitMax)
			npc.yaw = LobbyNpcLogic.yawToward(Vector3.zero, seat.cf.LookVector) or npc.yaw
		end
	elseif mode == "sit" then
		npc.timer -= dt
		if npc.timer <= 0 then
			npc.mode = "fromSeat"
		end
	elseif mode == "fromSeat" then
		local seatIndex = npc.seat :: number
		local seat = crowd.graph.seats[seatIndex]
		if npc.seatPhase > 0 then
			npc.seatPhase = math.max(0, npc.seatPhase - dt / Brain.SitBlend)
			npc.pos = seat.approach
			if npc.seatPhase <= 0 then
				-- Stood up at the approach point: free the seat, walk back to the seat's node.
				crowd.taken[seatIndex] = nil
				npc.seat = nil
				npc.sitCooldown = Brain.SitCooldown
				local node = crowd.graph.nodes[npc.node]
				npc.goal = jittered(node.pos, node.jitter, rand)
				npc.target = npc.node
			end
			return
		end
		if moveToGoal(npc, dt) then
			npc.mode = "walk"
			walkTo(crowd, npc, LobbyNpcLogic.nextNode(crowd, npc, rand), rand)
		end
	end
end

--[[
	Advances every visitor by `dt` seconds.
	@param playerPos  the local player's root position (nil = no character): wave checks
	@param still      reduced motion: hold poses, no walking / emotes
	@param rand       0..1 random source
]]
function LobbyNpcLogic.step(crowd: Crowd, dt: number, playerPos: Vector3?, still: boolean, rand: Rand)
	if not (dt > 0) or dt ~= dt then
		return
	end
	if still then
		-- Seated visitors stay seated, everyone else stands where they are.
		for _, npc in crowd.npcs do
			if npc.mode == "walk" or npc.mode == "toSeat" or npc.mode == "fromSeat" then
				if npc.seat ~= nil and npc.seatPhase >= 1 then
					npc.mode = "sit"
				elseif npc.seat == nil then
					npc.mode = "idle"
					npc.timer = math.huge
					npc.lookYaw = nil
				end
			elseif npc.mode == "idle" and npc.timer ~= math.huge then
				npc.timer = math.huge
			end
			npc.emote = nil
		end
		return
	end
	local remaining = math.min(dt, 1)
	while remaining > 0 do
		local slice = math.min(remaining, Brain.MaxStep)
		remaining -= slice
		for _, npc in crowd.npcs do
			if npc.mode == "idle" and npc.timer == math.huge then
				npc.timer = between(rand, Brain.IdleMin, Brain.IdleMax) -- reduced motion turned off
			end
			stepOne(crowd, npc, slice, rand)
		end
	end
	if playerPos == nil then
		return
	end
	local range2 = Brain.WaveRange * Brain.WaveRange
	for _, npc in crowd.npcs do
		local dx, dz = playerPos.X - npc.pos.X, playerPos.Z - npc.pos.Z
		local near = dx * dx + dz * dz <= range2 and math.abs(playerPos.Y - npc.pos.Y) < 12
		if near and not npc.nearPlayer and npc.waveCooldown <= 0 and npc.mode ~= "sit" then
			if rand() < Brain.WaveChance then
				npc.emote = "wave"
				npc.waveCooldown = Brain.WaveCooldown
				if npc.mode == "idle" then
					npc.lookYaw = LobbyNpcLogic.yawToward(npc.pos, playerPos)
				end
			end
		end
		npc.nearPlayer = near
	end
end

--[[
	The CFrame-ready pose of a visitor: feet position + yaw, or (sitting / blending) the lerp
	between the approach point and the seat. The renderer adds the root height.
	@return Vector3 feetOrSeat, number yaw, number sitBlend (0 = standing, 1 = seated)
]]
function LobbyNpcLogic.pose(crowd: Crowd, npc: Npc): (Vector3, number, number)
	local seatIndex = npc.seat
	if seatIndex ~= nil and npc.seatPhase > 0 then
		local seat = crowd.graph.seats[seatIndex]
		local t = npc.seatPhase
		local eased = t * t * (3 - 2 * t)
		return seat.approach:Lerp(seat.cf.Position, eased), npc.yaw, eased
	end
	return npc.pos, npc.yaw, 0
end

--[[
	Picks who speaks next: a random visitor within Bubble.NearRange of `playerPos` that is not
	already speaking, and a line not among the last Bubble.RecentLines picks.
	@param busy  npc id → true while its bubble shows
	@return (npc index, line index) or nil
]]
function LobbyNpcLogic.pickSpeaker(
	crowd: Crowd,
	playerPos: Vector3,
	busy: { [number]: boolean },
	state: SpeakState,
	lineCount: number,
	rand: Rand
): (number?, number?)
	if lineCount <= 0 then
		return nil, nil
	end
	local range2 = LobbyNpcConfig.Bubble.NearRange * LobbyNpcConfig.Bubble.NearRange
	local chosen: number? = nil
	local seen = 0
	for index, npc in crowd.npcs do
		local dx, dz = playerPos.X - npc.pos.X, playerPos.Z - npc.pos.Z
		if not busy[npc.id] and dx * dx + dz * dz <= range2 then
			seen += 1
			if rand() * seen < 1 then
				chosen = index
			end
		end
	end
	if chosen == nil then
		return nil, nil
	end
	local recentCap = math.min(LobbyNpcConfig.Bubble.RecentLines, lineCount - 1)
	local line = math.min(lineCount, math.floor(rand() * lineCount) + 1)
	-- Walk forward from the random start to the first line not said recently.
	for _ = 1, lineCount do
		if table.find(state.recent, line) == nil then
			break
		end
		line = line % lineCount + 1
	end
	table.insert(state.recent, line)
	while #state.recent > recentCap do
		table.remove(state.recent, 1)
	end
	return chosen, line
end

return table.freeze(LobbyNpcLogic)
