--!strict
--[[
	Lobby fixtures + visitors regressions (owner R99 / R100 / R101, L-lobby). Run:
		lune run tests/lobby

	Loads the REAL src/shared/Config/{HubLayout, LobbyConfig, LobbyNpcConfig} and
	src/client/Lobby/{LobbyLogic, LobbyNpcLogic} through tests/fixtures/RobloxLoader and proves:
	  1. LobbyConfig: every fixture names a real HubLayout anchor (with its model / prompt CFrames),
	     a screen that exists under src/client/UI/Screens, a sign piece the art model's mesh has
	     (MeshAssets), unique ids; the Lucky Wheel fixture has the walk-on box + spin.
	  2. The Lucky Wheel walk-on box (R99): inside the stage footprint in front of the wheel, a root
	     standing on the stage top is inside, a root on the bed in front of the steps / behind the
	     wheel frame is not, the prompt point is in reach of the platform.
	  3. Walk-on rule: entry opens once; standing / closing on the platform never re-opens; a quick
	     step-off-on (< RearmSeconds) does not re-open; a later entry after Cooldown does; a blocked
	     entry is consumed. wheelAngle eases 0 → delta monotonically; nearestFixture picks in reach.
	  4. LobbyNpcConfig (R100): 12 unique presets with positive integer asset ids (shirts / pants /
	     faces / accessories), tiers Low < Mid < High within the preset count, rbxassetid clips,
	     unique kid-safe lines <= Bubble.MaxChars with no banned words.
	  5. HubLayout.lobbyWalk: symmetric links, one connected graph, finite positions on the walk
	     surface, district 6 (Harvest square) skipped, 2 seats per bench (46), every seat's approach
	     in front of its bench; EVERY walked segment (links + node → seat approach) keeps >= 1.25
	     studs + the endpoints' jitter from every hub / event collider a body could touch.
	  6. LobbyNpcLogic over 10 simulated minutes (12 visitors): finite poses always on the graph,
	     seats exclusive and consistent, turn speed bounded, most nodes visited, sits / idles /
	     emotes happen; waves at a nearby player respect the cooldown; reduced motion freezes; a
	     5-second hitch moves at most 1 s of walking; pickSpeaker avoids recent lines + busy
	     visitors and needs a nearby player.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Loader = require("./fixtures/RobloxLoader")

local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(label, 2)
	end
	checks += 1
end

local loader = Loader.new()
local HubLayout = loader.load("src/shared/Config/HubLayout")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local LobbyConfig = loader.load("src/shared/Config/LobbyConfig")
local LobbyNpcConfig = loader.load("src/shared/Config/LobbyNpcConfig")
local LobbyLogic = loader.load("src/client/Lobby/LobbyLogic")
local LobbyNpcLogic = loader.load("src/client/Lobby/LobbyNpcLogic")

-- Deterministic 0..1 source.
local function lcg(seed: number): () -> number
	local state = seed
	return function(): number
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
end

local function finite(x: number): boolean
	return x == x and x > -math.huge and x < math.huge
end

-- The mesh key of a HubLayout placement name ("<key>_<index>" or an explicit name).
local function keyOfModel(name: string): string?
	for index, entry in HubLayout.models do
		local placed = entry.name or `{entry.key}_{index}`
		if placed == name then
			return entry.key
		end
	end
	return nil
end

-- ─── 1. LobbyConfig fixtures ─────────────────────────────────────────────────────────────────

local seenIds: { [string]: boolean } = {}
for _, fixture in LobbyConfig.Fixtures do
	ok(not seenIds[fixture.id], `fixture id {fixture.id} unique`)
	seenIds[fixture.id] = true
	local anchor = HubLayout.anchors[fixture.anchor]
	ok(type(anchor) == "table" and typeof(anchor.cf) == "CFrame", `{fixture.id}: anchor {fixture.anchor} exists`)
	local key = keyOfModel(anchor.model)
	ok(key ~= nil, `{fixture.id}: anchor model {anchor.model} is a HubLayout placement`)
	if fixture.screen ~= nil then
		ok(fs.isDir(`src/client/UI/Screens/{fixture.screen}`), `{fixture.id}: screen {fixture.screen} exists`)
		ok(fixture.prompt ~= nil and typeof(anchor.prompt) == "CFrame", `{fixture.id}: prompt texts + anchor point`)
		ok(type(fixture.hint) == "string" and #fixture.hint <= 32, `{fixture.id}: hint fits the hint bar`)
	end
	if fixture.sign ~= nil then
		local piece = fixture.sign.piece or "Sign"
		local mesh = MeshAssets[key :: string]
		ok(mesh ~= nil and mesh.pieces[piece] ~= nil, `{fixture.id}: {key} has a {piece} piece for the sign`)
		ok(#fixture.sign.title > 0 and #fixture.sign.title <= 16, `{fixture.id}: sign title short`)
	end
end
ok(LobbyConfig.byId.LuckyWheel ~= nil and LobbyConfig.byId.LuckyWheel.screen == "LuckyWheel", "wheel fixture")
ok(LobbyConfig.byId.LuckyWheel.walkOn ~= nil and LobbyConfig.byId.LuckyWheel.spin == true, "wheel walk-on + spin")
ok(LobbyConfig.byId.CrateStall.sign.title == "SUPPLY CRATES", "crate stall caption on its own board")
ok(LobbyConfig.Sign.PadX > 0 and LobbyConfig.Sign.PadY > 0, "sign text is padded inside the board")
-- R101: the crate stall's Sign board sits ABOVE the awning (the old billboard sat inside it).
do
	local stall = MeshAssets.Hub_CrateStall.pieces
	local signBottom = stall.Sign.offset.Y - stall.Sign.size.Y / 2
	local awningTop = stall.AwningA.offset.Y + stall.AwningA.size.Y / 2
	ok(signBottom > awningTop, `crate Sign board (bottom {signBottom}) clears the awning (top {awningTop})`)
end

-- ─── 2. Wheel walk-on geometry ───────────────────────────────────────────────────────────────

do
	local anchor = HubLayout.anchors.LuckyWheelStage
	local walkOn = LobbyConfig.byId.LuckyWheel.walkOn
	local boxCf = anchor.cf * walkOn.offset
	ok(walkOn.octagon ~= nil and walkOn.octagon <= 10, "walk-on clipped to the stage octagon (apothem 10)")
	ok(walkOn.offset.Position.Z + walkOn.size.Z / 2 <= -1.2, "walk-on box stays in front of the wheel frame")
	local function inside(x: number, y: number, z: number): boolean
		return LobbyLogic.insideWalkOn(anchor.cf, walkOn, (anchor.cf * CFrame.new(x, y, z)).Position)
	end
	local stageTop = 0.1 + 1.8 -- BED_TOP + StageTop
	for _, rootUp in { stageTop + 2.7, stageTop + 3.2, stageTop + 4.5 } do -- small / R15 / tall avatar roots
		ok(inside(0, rootUp, -5), "root on the stage in front of the wheel")
		ok(inside(6, rootUp, -6) and inside(-6, rootUp, -3), "root on the stage's sides")
		ok(inside(0, rootUp, -9.5), "root on the stage's front edge")
		ok(not inside(0, rootUp, 3), "behind the wheel is outside")
	end
	-- Beside / in front of the stage at ground level, ANY avatar height: outside (the octagon is solid).
	for _, rootUp in { 0.1 + 2.7, 0.1 + 4.6 } do
		ok(not inside(0, rootUp, -14), "on the bed in front of the steps")
		ok(not inside(11, rootUp, -5) and not inside(-11, rootUp, -5), "beside the stage")
		ok(not inside(8.2, rootUp, -8.2), "beside the stage's front corner (diagonal face)")
	end
	ok(
		(anchor.prompt.Position - boxCf.Position).Magnitude <= LobbyConfig.PromptDistance,
		"prompt reachable from the platform"
	)
end

-- ─── 3. Walk-on rule + wheel easing + nearest fixture ───────────────────────────────────────

do
	local W = LobbyConfig.WalkOn
	local s = LobbyLogic.newWalkOn()
	ok(LobbyLogic.walkOnStep(s, false, 0, false) == false, "outside: nothing")
	ok(LobbyLogic.walkOnStep(s, true, 1, false) == true, "first entry opens")
	ok(LobbyLogic.walkOnStep(s, true, 1.1, false) == false, "standing on it: no re-open")
	ok(LobbyLogic.walkOnStep(s, true, 30, false) == false, "closing while on it: no re-open")
	ok(LobbyLogic.walkOnStep(s, false, 31, false) == false, "step off")
	ok(LobbyLogic.walkOnStep(s, true, 31 + W.RearmSeconds * 0.5, false) == false, "quick step back: no re-open")
	ok(LobbyLogic.walkOnStep(s, false, 33, false) == false, "off again")
	ok(LobbyLogic.walkOnStep(s, true, 33 + W.RearmSeconds + 0.01, false) == true, "real re-entry opens")
	ok(LobbyLogic.walkOnStep(s, false, 34, false) == false, "off")
	ok(LobbyLogic.walkOnStep(s, true, 33 + W.RearmSeconds + 0.01 + W.Cooldown * 0.5, false) == false, "cooldown holds")
	local b = LobbyLogic.newWalkOn()
	ok(LobbyLogic.walkOnStep(b, true, 5, true) == false, "blocked entry does not open")
	ok(LobbyLogic.walkOnStep(b, true, 6, false) == false, "blocked entry is consumed (no ambush on close)")
	ok(
		LobbyLogic.walkOnStep(b, false, 7, false) == false and LobbyLogic.walkOnStep(b, true, 8, false),
		"re-entry opens"
	)

	ok(LobbyLogic.wheelAngle(0, 4, 10) == 0 and LobbyLogic.wheelAngle(4, 4, 10) == 10, "wheel angle endpoints")
	ok(LobbyLogic.wheelAngle(9, 4, 10) == 10 and LobbyLogic.wheelAngle(1, 0, 10) == 10, "wheel angle clamps")
	local last = 0
	for i = 1, 40 do
		local a = LobbyLogic.wheelAngle(i * 0.1, 4, 25)
		ok(a >= last and finite(a), "wheel angle monotonic")
		last = a
	end
	ok(LobbyLogic.wheelAngle(2, 4, 10) > 5, "ease-out: past half way at half time")

	local points = { Vector3.new(0, 0, 20), false, Vector3.new(0, 0, 8) }
	ok(LobbyLogic.nearestFixture(points, Vector3.zero, 12) == 3, "nearest fixture in reach")
	ok(LobbyLogic.nearestFixture(points, Vector3.new(0, 0, -30), 12) == nil, "none in reach")
	ok(LobbyLogic.insideBox(CFrame.new(), Vector3.new(2, 2, 2), Vector3.new(0.9, -0.9, 0.9)), "insideBox basic")
	ok(
		not LobbyLogic.insideBox(CFrame.Angles(0, math.rad(45), 0), Vector3.new(2, 2, 2), Vector3.new(0.95, 0, 0.95)),
		"rotated box"
	)
end

-- ─── 4. LobbyNpcConfig ───────────────────────────────────────────────────────────────────────

do
	local ids: { [string]: boolean } = {}
	local function assetOk(id: number): boolean
		return type(id) == "number" and id >= 0 and id % 1 == 0
	end
	ok(#LobbyNpcConfig.Presets == 12, "12 presets (High tier count)")
	for _, preset in LobbyNpcConfig.Presets do
		ok(not ids[preset.id] and string.match(preset.id, "^[%a]+$") ~= nil, `preset id {preset.id} unique + plain`)
		ids[preset.id] = true
		ok(typeof(preset.skin) == "Color3", `{preset.id} skin`)
		ok(
			assetOk(preset.shirt) and assetOk(preset.pants) and assetOk(preset.face) and preset.face > 0,
			`{preset.id} ids`
		)
		for _, list in { preset.hair, preset.hats, preset.faceAccessories } do
			for _, id in list do
				ok(assetOk(id) and id > 0, `{preset.id} accessory id`)
			end
		end
	end
	local low, mid, high = LobbyNpcConfig.Tiers.Low, LobbyNpcConfig.Tiers.Mid, LobbyNpcConfig.Tiers.High
	ok(low.Count < mid.Count and mid.Count < high.Count and high.Count <= #LobbyNpcConfig.Presets, "tier counts")
	ok(low.Count >= 6 and low.Range < mid.Range and mid.Range < high.Range, "tier ranges")
	ok(low.Bubbles >= 1 and high.Bubbles <= 3, "bubble caps")
	for name, id in LobbyNpcConfig.Animations do
		ok(string.match(id, "^rbxassetid://%d+$") ~= nil, `animation {name} id`)
	end
	local banned = { "kill", "gun", "dead", "die", "blood", "hate", "stupid", "weapon", "bomb", "shoot" }
	local seenLines: { [string]: boolean } = {}
	ok(#LobbyNpcConfig.Lines >= 20, "enough lines")
	for _, line in LobbyNpcConfig.Lines do
		ok(#line > 0 and #line <= LobbyNpcConfig.Bubble.MaxChars, `line fits: {line}`)
		ok(not seenLines[line], `line unique: {line}`)
		seenLines[line] = true
		local lower = string.lower(line)
		for _, word in banned do
			ok(string.find(lower, "%f[%a]" .. word .. "%f[%A]") == nil, `kid-safe line: {line}`)
		end
	end
end

-- ─── 5. Walk graph ───────────────────────────────────────────────────────────────────────────

local walk = HubLayout.lobbyWalk
do
	local nodes, links, seats = walk.nodes, walk.links, walk.seats
	ok(#nodes >= 50 and #links == #nodes, `walk graph size {#nodes}`)
	for i, node in nodes do
		ok(finite(node.pos.X) and finite(node.pos.Z) and math.abs(node.pos.Y - 0.1) < 1e-6, `node {i} on the surface`)
		ok(node.jitter >= 0 and node.jitter <= 3 and node.idle >= 0 and node.idle <= 1, `node {i} tunables`)
		local r = math.sqrt(node.pos.X ^ 2 + node.pos.Z ^ 2)
		ok(r >= 30 and r <= 212, `node {i} inside the plaza (r {r})`)
		for _, j in links[i] do
			ok(j ~= i and table.find(links[j], i) ~= nil, `link {i}-{j} symmetric`)
		end
		-- District 6 (Harvest square, yaw 270-315 beyond r 92) never has a walker node.
		local yawDeg = math.deg(math.atan2(node.pos.X, node.pos.Z)) % 360
		ok(not (r > 92 and yawDeg > 272 and yawDeg < 313), `node {i} off the Harvest square`)
	end
	-- Connected.
	local seen = { [1] = true }
	local queue = { 1 }
	while #queue > 0 do
		local at = table.remove(queue) :: number
		for _, j in links[at] do
			if not seen[j] then
				seen[j] = true
				table.insert(queue, j)
			end
		end
	end
	local reached = 0
	for _ in seen do
		reached += 1
	end
	ok(reached == #nodes, `graph connected ({reached}/{#nodes})`)
	ok(#seats == 46, `46 seats (got {#seats})`)
	for s, seat in seats do
		ok(nodes[seat.node] ~= nil, `seat {s} node`)
		local d = Vector3.new(seat.approach.X - seat.cf.Position.X, 0, seat.approach.Z - seat.cf.Position.Z)
		ok(d.Magnitude > 1.5 and d.Magnitude < 3.2, `seat {s} approach just in front`)
		-- In front = along the seat's facing.
		ok(d.Unit:Dot(seat.cf.LookVector) > 0.95, `seat {s} approach in front of the bench`)
	end
end

-- Obstacles a walking body (feet 0.1, head ~5.6) could touch: hub + Harvest colliders whose top is
-- above ankle height and bottom below head height.
local obstacles: { { cf: any, half: any, x: number, z: number, reach: number } } = {}
local function addObstacles(list: { any }?)
	for _, box in list or {} do
		local top = box.cf.Position.Y + box.size.Y / 2
		local bottom = box.cf.Position.Y - box.size.Y / 2
		if top > 0.45 and bottom < 5.6 and box.size.X < 400 and box.size.Z < 400 then
			local half = box.size / 2
			table.insert(obstacles, {
				cf = box.cf,
				half = half,
				x = box.cf.Position.X,
				z = box.cf.Position.Z,
				-- bounding radius on the walk plane (any yaw / tilt)
				reach = half.Magnitude,
			})
		end
	end
end
addObstacles(HubLayout.collision)
addObstacles(HubLayout.event and HubLayout.event.collision or nil)

-- Distance from a body column at `p` (feet level) to an obstacle box.
local function clearance(p: any, box: { cf: any, half: any }): number
	local y = math.clamp(box.cf.Position.Y, 0.6, 5.4)
	local lp = box.cf:PointToObjectSpace(Vector3.new(p.X, y, p.Z))
	local dx = math.max(math.abs(lp.X) - box.half.X, 0)
	local dy = math.max(math.abs(lp.Y) - box.half.Y, 0)
	local dz = math.max(math.abs(lp.Z) - box.half.Z, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local BODY = 1.25
local worst = math.huge
local failures: { string } = {}
local function checkSegment(a: any, b: any, ja: number, jb: number, label: string)
	local length = (b - a).Magnitude
	local samples = math.max(2, math.ceil(length / 0.5))
	-- Only boxes that can come within reach of this segment (cheap circle test first).
	local mx, mz = (a.X + b.X) / 2, (a.Z + b.Z) / 2
	local near: { any } = {}
	for _, box in obstacles do
		local limit = box.reach + length / 2 + BODY + math.max(ja, jb) + 1
		if (box.x - mx) ^ 2 + (box.z - mz) ^ 2 <= limit * limit then
			table.insert(near, box)
		end
	end
	for i = 0, samples do
		local t = i / samples
		local p = a:Lerp(b, t)
		local need = BODY + ja + (jb - ja) * t
		for _, box in near do
			local c = clearance(p, box)
			if c - need < worst then
				worst = c - need
			end
			if c < need then
				table.insert(
					failures,
					string.format("%s t=%.2f at (%.1f, %.1f): %.2f < %.2f", label, t, p.X, p.Z, c, need)
				)
				return
			end
		end
	end
end
for i, list in walk.links do
	for _, j in list do
		if i < j then
			local a, b = walk.nodes[i], walk.nodes[j]
			checkSegment(a.pos, b.pos, a.jitter, b.jitter, `link {i}({a.kind})-{j}({b.kind})`)
		end
	end
end
for s, seat in walk.seats do
	local node = walk.nodes[seat.node]
	checkSegment(node.pos, Vector3.new(seat.approach.X, node.pos.Y, seat.approach.Z), node.jitter, 0, `seat {s}`)
end
if #failures > 0 then
	print(table.concat(failures, "\n"))
end
ok(#failures == 0, `{#failures} walk segments touch a collider (worst margin {worst})`)

-- ─── 6. LobbyNpcLogic simulation ─────────────────────────────────────────────────────────────

-- Distance from p to segment ab on XZ.
local function segDist(p: any, a: any, b: any): number
	local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local ap = Vector3.new(p.X - a.X, 0, p.Z - a.Z)
	local len2 = ab.X * ab.X + ab.Z * ab.Z
	local t = if len2 > 0 then math.clamp((ap.X * ab.X + ap.Z * ab.Z) / len2, 0, 1) else 0
	return Vector3.new(ap.X - ab.X * t, 0, ap.Z - ab.Z * t).Magnitude
end

-- Max jitter anywhere (a walker may aim at node + jitter): its distance from the graph is bounded.
local maxJitter = 0
for _, node in walk.nodes do
	maxJitter = math.max(maxJitter, node.jitter)
end
local function offGraph(p: any): number
	local best = math.huge
	for i, list in walk.links do
		for _, j in list do
			if i < j then
				best = math.min(best, segDist(p, walk.nodes[i].pos, walk.nodes[j].pos))
			end
		end
	end
	for _, seat in walk.seats do
		best = math.min(best, segDist(p, walk.nodes[seat.node].pos, seat.approach))
		best = math.min(best, segDist(p, seat.approach, seat.cf.Position))
	end
	return best
end

do
	local Brain = LobbyNpcConfig.Brain
	local rand = lcg(4242)
	local crowd = LobbyNpcLogic.newCrowd(walk, 12, rand)
	ok(#crowd.npcs == 12, "crowd of 12")
	local visited: { [number]: boolean } = {}
	local sits, idles, emotes = 0, 0, 0
	local lastMode: { [number]: string } = {}
	local dt = 1 / 30
	local steps = 10 * 60 * 30
	local maxTurn = math.rad(Brain.TurnSpeed) * dt * 3 + 1e-6 -- the seat turn runs at 3x
	for step = 1, steps do
		local before: { [number]: number } = {}
		for _, npc in crowd.npcs do
			before[npc.id] = npc.yaw
		end
		LobbyNpcLogic.step(crowd, dt, nil, false, rand)
		for _, npc in crowd.npcs do
			visited[npc.node] = true
			if npc.emote ~= nil then
				emotes += 1
				npc.emote = nil
			end
			if lastMode[npc.id] ~= npc.mode then
				if npc.mode == "sit" then
					sits += 1
				elseif npc.mode == "idle" then
					idles += 1
				end
				lastMode[npc.id] = npc.mode
			elseif npc.mode ~= "sit" then
				local turned = math.abs(LobbyNpcLogic.angleDelta(before[npc.id], npc.yaw))
				ok(turned <= maxTurn, `turn speed bounded ({turned})`)
			end
		end
		if step % 150 == 0 then
			local taken: { [number]: number } = {}
			for _, npc in crowd.npcs do
				local pos, yaw, blend = LobbyNpcLogic.pose(crowd, npc)
				ok(finite(pos.X) and finite(pos.Y) and finite(pos.Z) and finite(yaw), "finite pose")
				ok(blend >= 0 and blend <= 1, "blend range")
				ok(offGraph(npc.pos) <= maxJitter + 0.05, `npc {npc.id} on the graph ({offGraph(npc.pos)})`)
				if npc.seat ~= nil then
					ok(taken[npc.seat] == nil, "a seat holds one visitor")
					taken[npc.seat] = npc.id
					ok(crowd.taken[npc.seat] == npc.id, "taken map agrees")
				end
			end
			for seat, id in crowd.taken do
				ok(taken[seat] == id, "no stale seat reservation")
			end
		end
	end
	local count = 0
	for _ in visited do
		count += 1
	end
	ok(count >= math.floor(#walk.nodes * 0.6), `visitors roam ({count}/{#walk.nodes} nodes)`)
	ok(sits >= 5 and idles >= 20 and emotes >= 5, `life happens (sits {sits}, idles {idles}, emotes {emotes})`)

	-- Waves: a player standing next to an idle visitor.
	local waveRand = lcg(99)
	local waveCrowd = LobbyNpcLogic.newCrowd(walk, 1, waveRand)
	local npc = waveCrowd.npcs[1]
	npc.waveCooldown = 0
	npc.mode = "idle"
	npc.timer = 1e9
	local waves = 0
	for _ = 1, 200 do
		local far = Vector3.new(npc.pos.X + 40, npc.pos.Y, npc.pos.Z)
		LobbyNpcLogic.step(waveCrowd, 0.05, far, false, waveRand)
		LobbyNpcLogic.step(waveCrowd, 0.05, npc.pos + Vector3.new(3, 0, 0), false, waveRand)
		if npc.emote == "wave" then
			waves += 1
			npc.emote = nil
		end
	end
	-- 200 approaches over 20 s with a 25 s cooldown: exactly one wave possible.
	ok(waves == 1, `wave once per cooldown ({waves})`)

	-- Reduced motion: nothing moves.
	local stillCrowd = LobbyNpcLogic.newCrowd(walk, 6, lcg(7))
	for _ = 1, 30 do
		LobbyNpcLogic.step(stillCrowd, 0.2, nil, false, lcg(8)) -- get some walking going
	end
	local frozen: { [number]: any } = {}
	for _, n in stillCrowd.npcs do
		frozen[n.id] = n.pos
	end
	for _ = 1, 100 do
		LobbyNpcLogic.step(stillCrowd, 1 / 30, Vector3.zero, true, lcg(9))
	end
	for _, n in stillCrowd.npcs do
		ok(n.pos == frozen[n.id] and n.emote == nil, "reduced motion: frozen, no emotes")
		ok(n.mode == "idle" or n.mode == "sit" or n.seat ~= nil, "reduced motion: holding a pose")
	end

	-- Hitch: a 5 s frame moves at most 1 s of walking.
	local hitch = LobbyNpcLogic.newCrowd(walk, 1, lcg(11))
	local h = hitch.npcs[1]
	h.mode = "walk"
	h.sitCooldown = 1e9
	h.target = walk.links[h.node][1]
	h.goal = walk.nodes[h.target].pos
	local start = h.pos
	LobbyNpcLogic.step(hitch, 5, nil, false, lcg(12))
	ok(
		(h.pos - start).Magnitude <= h.speed * 1 + 1e-3, -- Vector3 is float32
		`hitch clamps to 1 s ({(h.pos - start).Magnitude} > {h.speed}, mode {h.mode})`
	)
	LobbyNpcLogic.step(hitch, 0 / 0, nil, false, lcg(13))
	ok(finite(h.pos.X), "NaN dt ignored")

	-- pickSpeaker.
	local talk = LobbyNpcLogic.newCrowd(walk, 4, lcg(21))
	local state = { recent = {} }
	local nearPos = talk.npcs[1].pos
	local recentCap = LobbyNpcConfig.Bubble.RecentLines
	local history: { number } = {}
	local speakRand = lcg(22)
	for _ = 1, 60 do
		local index, line = LobbyNpcLogic.pickSpeaker(talk, nearPos, {}, state, #LobbyNpcConfig.Lines, speakRand)
		ok(index ~= nil and line ~= nil, "a nearby visitor speaks")
		for k = math.max(1, #history - recentCap + 1), #history do
			ok(history[k] ~= line, "no line repeats within the recent window")
		end
		table.insert(history, line :: number)
	end
	local busy = { [talk.npcs[1].id] = true }
	for _ = 1, 20 do
		local index = LobbyNpcLogic.pickSpeaker(talk, nearPos, busy, state, #LobbyNpcConfig.Lines, speakRand)
		ok(index == nil or talk.npcs[index].id ~= talk.npcs[1].id, "a busy visitor is skipped")
	end
	local farAway = Vector3.new(5000, 0, 5000)
	ok(LobbyNpcLogic.pickSpeaker(talk, farAway, {}, state, #LobbyNpcConfig.Lines, speakRand) == nil, "nobody near")
end

print(
	`[lobby] {checks} checks passed (walk graph: {#walk.nodes} nodes, {#walk.seats} seats, worst margin {string.format(
		"%.2f",
		worst
	)})`
)
