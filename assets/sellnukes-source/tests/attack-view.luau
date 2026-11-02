--!strict
--[[
	Attack view polish — owner R104 (picker streams the target in), R105 (defence billboards clear
	of producer billboards) and R106 (AA towers animate). Run:
		lune run tests/attack-view            (from the repo root)

	Proves on the shipped modules (Shared/Attack/{PickerStream, TowerAnimMath, AttackGeometry},
	Client/Attack/DefenseBoardPlacement, Shared/Config/{AttackConfig, MeshAssets, WorldLayout},
	Server/Analytics/KeySpec) and the shipped sources:
	  1. R104 root cause + rule: from a player's own plot every OTHER plot's picker focus and every
	     Rival island is beyond StreamingTargetRadius (default.project.json), so they are not
	     streamed without help; around the focus the whole target footprint IS within the radius
	     (one replication focus streams the whole base). readSlot refuses junk (NaN, inf,
	     fractions, negatives, out of range, strings, tables); the loading rule (parts / cap /
	     timeout, monotonic); containers name the real plot / island folders.
	  2. R104 camera: every target's footprint projects inside the picker's vertical FOV (16:9,
	     4:3 and a 19.5:9 phone) and the focus point is the screen centre.
	  3. R104 wiring: AttackPickerFocus is registered; PickerFocus validates with readSlot, rate
	     limits, adds / removes the replication focus, cleans up on leave, lingers on close;
	     AttackService starts it; the picker calls PickerView focus / keepAlive / release and no
	     longer fires a lone RequestStreamAroundAsync; analytics keys pass KeySpec.
	  4. R105: the base spot of the Silo slot's boards really clips the Launch Silos producer board
	     (the owner's screenshot), every solved spot on every plot / slot / kind / HQ level is clear
	     on desktop, tablet and console viewports, the phone solve never gets worse than the base
	     spot (the runtime declutter hides the rest), spots stay near their object and above the
	     ground; boards are a constant pixel size with >= 44 px taps; culling is shorter than before.
	  5. R106: piece classification, joints equal the Blender builders' notes in MeshAssets, every
	     tower level has yaw + pitch pieces (L3-L5 a dish), idle sweep / pitch bounds, recoil curve,
	     shortest-path frame-rate independent follow, aim maths, per-tower phases, FxQuality culls.
	  6. R106 wiring: one PreRender loop + one BulkMoveTo in TowerAnim, Instance.new only in the
	     flash pool, Reduce Motion respected; FlightRenderer hands aim / shots to TowerAnim and keeps
	     no turret rigs of its own.
	  7. R109 silo lift-off + reload: timeline maths (ignite rise, hand-off blend / scale ending
	     exactly on the flight arc at the flight nuke's length, reload time per kind, reload rise /
	     fade), the art agrees (each silo's rocket nose = its launch point, every launch build has a
	     rocket mesh), the ignite fits inside the flight lead-in; wiring: FlightRenderer waits for
	     the hand-off, SiloLaunch hides the server rocket (never moves it), one loop + one
	     BulkMoveTo, no Instance.new in the frame body, Reduce Motion / FxQuality / knockdown aware.
	  8. R118 picker layout: on phone / small phone / tablet / console / desktop canvases a clear band
	     for >= 44 pt chips always remains and the top / bottom buttons stay >= 44 pt; the aim chips
	     never overlap (randomised anchors, counts 1-12, clusters, the R118 single-row case, every
	     plot and Rival island projected through the real picker camera on every device), stay in
	     the band / canvas, fit their longest label, strip order follows the areas left to right;
	     the info / status / aim lines stack on one plate (UIListLayout) and the loading plate sits
	     below the top block.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")

local Loader = require("./fixtures/RobloxLoader")

local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
local Vector2 = roblox.Vector2

local loader = Loader.new()
local AttackConfig = loader.load("src/shared/Config/AttackConfig")
local AttackGeometry = loader.load("src/shared/Attack/AttackGeometry")
local PickerStream = loader.load("src/shared/Attack/PickerStream")
local PickerFrame = loader.load("src/shared/Attack/PickerFrame")
local TowerAnimMath = loader.load("src/shared/Attack/TowerAnimMath")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local KeySpec = loader.load("src/server/Analytics/KeySpec")
local Area07 = loader.load("src/shared/Config/AreaLayouts/Area07")
local FlightMath = loader.load("src/shared/Attack/FlightMath")
local SiloLaunchMath = loader.load("src/shared/Attack/SiloLaunchMath")
local PickerLayout = loader.load("src/client/UI/Screens/AttackTarget/PickerLayout")
local DeviceProfile = loader.load("src/shared/Util/DeviceProfile")
local KnockdownConfig = loader.load("src/shared/Config/KnockdownConfig")

-- Ship geometry: in Roblox AttackGeometry reads AreaLayouts/Area07 through FindFirstChild, which the
-- Lune path nodes lack (it would fall back to AttackConfig.Geometry). Pin the real art layout so
-- every audit below sees exactly what ships (HQ tower on the Area 7 plinth, silo nose tips).
local artLayout = {
	launchPoints = Area07.launchPoints,
	aaTowerMount = Area07.aaTowerMount,
	consolePrompt = Area07.consolePrompt,
}
AttackGeometry.layout = function()
	return artLayout
end
local Placement = loader.load("src/client/Attack/DefenseBoardPlacement")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local nan = 0 / 0
local STREAM = AttackConfig.Client.PickerStream
local RIVALS = AttackConfig.Rivals
local SLOTS = AttackGeometry.slotCount()

local function source(path: string): string
	return fs.readFile(path)
end

-- 1. R104 root cause + streaming rule ---------------------------------------------------------------
do
	local project = serde.decode("json", fs.readFile("default.project.json"))
	local workspace = project.tree.Workspace["$properties"]
	check(workspace.StreamingEnabled == true, "the place streams (the root cause's premise)")
	local radius = workspace.StreamingTargetRadius
	check(type(radius) == "number" and radius > 0, "StreamingTargetRadius set")
	check(workspace.StreamOutBehavior == "Opportunistic", "out-of-radius content streams back out")
	-- Root cause: from my plot's entrance, other plots' picker focus / the islands are out of reach.
	local unreachable = 0
	local pairs = 0
	for mine = 1, WorldLayout.PlotCount do
		local me = WorldLayout.entranceSpawn(mine).Position
		for slot = 1, SLOTS do
			if slot ~= mine then
				pairs += 1
				if (PickerStream.focusPoint(slot) - me).Magnitude > radius then
					unreachable += 1
				end
			end
		end
	end
	check(unreachable > pairs / 3, `most targets are outside the character's stream radius ({unreachable}/{pairs})`)
	for rival = 1, #RIVALS.List do
		local slot = AttackGeometry.rivalSlot(rival)
		for mine = 1, WorldLayout.PlotCount do
			local me = WorldLayout.entranceSpawn(mine).Position
			check(
				(PickerStream.focusPoint(slot) - me).Magnitude > radius,
				`rival {rival} is never streamed from plot {mine}`
			)
		end
	end
	-- Fix: one focus at the picker focus covers the whole footprint (plot corners, flank towers).
	for plot = 1, WorldLayout.PlotCount do
		local origin = WorldLayout.plotOrigin(plot)
		local focus = PickerStream.focusPoint(plot)
		for _, corner in
			{
				Vector3.new(-WorldLayout.PlotHalfWidth - 20, 0, 0),
				Vector3.new(WorldLayout.PlotHalfWidth + 20, 0, 0),
				Vector3.new(-WorldLayout.PlotHalfWidth - 20, 0, WorldLayout.PlotLength),
				Vector3.new(WorldLayout.PlotHalfWidth + 20, 0, WorldLayout.PlotLength),
			}
		do
			check(
				((origin * corner) - focus).Magnitude < radius,
				`plot {plot}: footprint corner inside the focus radius`
			)
		end
	end
	for rival = 1, #RIVALS.List do
		local slot = AttackGeometry.rivalSlot(rival)
		local frame = AttackGeometry.rivalFrame(rival)
		local half = RIVALS.ShieldSize / 2
		local centre = frame * RIVALS.ShieldCentre
		check(
			(centre - PickerStream.focusPoint(slot)).Magnitude + half.Magnitude < radius,
			`rival {rival}: island inside the focus radius`
		)
	end

	-- readSlot.
	check(PickerStream.readSlot(0) == 0, "0 clears")
	for slot = 1, SLOTS do
		check(PickerStream.readSlot(slot) == slot, `slot {slot} accepted`)
	end
	for _, junk in { nan, math.huge, -math.huge, -1, 1.5, SLOTS + 1, 1e300, -0.5, "1", true, {}, nil } :: { any } do
		check(PickerStream.readSlot(junk) == nil, `junk slot refused ({tostring(junk)})`)
	end

	-- Loading rule.
	local load = PickerStream.newLoad()
	check(not PickerStream.step(load, 0, STREAM.PollSeconds), "nothing yet: loading")
	check(not PickerStream.step(load, STREAM.MinParts + 5, STREAM.PollSeconds), "growing: loading")
	for _ = 1, STREAM.StableTicks - 1 do
		check(not PickerStream.step(load, STREAM.MinParts + 5, STREAM.PollSeconds), "settling: loading")
	end
	check(PickerStream.step(load, STREAM.MinParts + 5, STREAM.PollSeconds), "stable + enough: loaded")
	check(load.reason == "parts", "reason parts")
	check(PickerStream.step(load, 0, STREAM.PollSeconds), "stays loaded")
	local capped = PickerStream.newLoad()
	check(
		PickerStream.step(capped, STREAM.ProbeMax, STREAM.PollSeconds) and capped.reason == "cap",
		"cap loads at once"
	)
	local bare = PickerStream.newLoad()
	local polls = 0
	while not PickerStream.step(bare, 3, STREAM.PollSeconds) do
		polls += 1
		check(polls < 1000, "timeout terminates")
	end
	check(bare.reason == "timeout" and bare.elapsed >= STREAM.LoadTimeout, "a bare plot times out")
	check(bare.elapsed <= STREAM.LoadTimeout + STREAM.PollSeconds + 1e-6, "timeout is not late")
	local junk = PickerStream.newLoad()
	check(not PickerStream.step(junk, nan, nan), "junk count / dt never throws")
	check(junk.elapsed == 0 and junk.best == 0, "junk count / dt counts nothing")
	check(STREAM.FocusLinger < STREAM.FocusExpire and STREAM.KeepAlive < STREAM.FocusExpire, "keep-alive beats expiry")
	check(
		STREAM.FocusLinger >= AttackConfig.Flight.MaxSeconds + AttackConfig.Flight.LeadIn,
		"linger covers a launch cinematic"
	)

	-- Containers.
	for plot = 1, WorldLayout.PlotCount do
		local folder, name = PickerStream.container(plot)
		check(folder == "Plots" and name == `Plot{plot}`, `plot {plot} container`)
	end
	for rival = 1, #RIVALS.List do
		local folder, name = PickerStream.container(AttackGeometry.rivalSlot(rival))
		check(folder == RIVALS.Folder and name == RIVALS.List[rival].id, `rival {rival} container`)
	end
	check(
		string.find(source("src/server/World/PlotBuilder.luau"), "model.Name = `Plot{index}`", 1, true) ~= nil,
		"plots are named Plot<N>"
	)
	check(
		string.find(source("src/server/Attack/RivalIslands.luau"), "folder.Name = rival.id", 1, true) ~= nil,
		"islands are named by id"
	)
end

-- 2. R104 / R133 camera framing ------------------------------------------------------------------------
-- Owner R133 ("when attacking people all I see is this, not their base still"): the old whole-plot
-- view sat ~890 studs up and a live client drew nothing. Shared/Attack/PickerFrame frames the BUILT
-- areas as close as they fit inside the band between the UI blocks, never farther than MaxDistance;
-- a base too big for that keeps the AIMED area in view.
do
	local FRAME = AttackConfig.Client.PickerFrame
	local fov = math.rad(AttackConfig.Client.PickerFov)
	local tanV = math.tan(fov / 2)
	local radius = serde.decode("json", fs.readFile("default.project.json")).tree.Workspace["$properties"]
	local minRadius, targetRadius = radius.StreamingMinRadius, radius.StreamingTargetRadius
	check(type(minRadius) == "number" and minRadius > 0, "StreamingMinRadius set")

	-- Ground corners of an area's footprint (+ pad) in world space.
	local function areaCorners(slot: number, area: number, pad: number): { Vector3 }
		local rect = PickerFrame.footprint(area)
		local origin = AttackGeometry.plotOrigin(slot)
		local out = {}
		for _, x in { rect.minX - pad, rect.maxX + pad } do
			for _, z in { rect.minZ - pad, rect.maxZ + pad } do
				table.insert(out, origin * Vector3.new(x, 0, z))
			end
		end
		return out
	end
	-- Ground corners of the union of the areas' footprints, padded and kept on the plot (what
	-- PickerFrame fits).
	local function unionCorners(slot: number, set: { number }): { Vector3 }
		local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
		for _, area in set do
			local rect = PickerFrame.footprint(area)
			minX, maxX = math.min(minX, rect.minX), math.max(maxX, rect.maxX)
			minZ, maxZ = math.min(minZ, rect.minZ), math.max(maxZ, rect.maxZ)
		end
		minX, maxX =
			math.max(minX - FRAME.Pad, -WorldLayout.PlotHalfWidth),
			math.min(maxX + FRAME.Pad, WorldLayout.PlotHalfWidth)
		minZ, maxZ = math.max(minZ - FRAME.Pad, 0), math.min(maxZ + FRAME.Pad, WorldLayout.PlotLength)
		local origin = AttackGeometry.plotOrigin(slot)
		return {
			origin * Vector3.new(minX, 0, minZ),
			origin * Vector3.new(maxX, 0, minZ),
			origin * Vector3.new(minX, 0, maxZ),
			origin * Vector3.new(maxX, 0, maxZ),
		}
	end
	-- Every corner inside the fit window of a view (normalised like WorldToScreenPoint).
	local function inWindow(eye: Vector3, focus: Vector3, points: { Vector3 }, aspect: number): boolean
		local f = (focus - eye).Unit
		for _, point in points do
			local x, y, depth = PickerFrame.project(eye, f, point, tanV * aspect, tanV)
			if
				depth <= 0
				or math.abs(x) > FRAME.FitX + 1e-6
				or y > FRAME.FitTop + 1e-6
				or y < FRAME.FitBottom - 1e-6
			then
				return false
			end
		end
		return true
	end

	-- builtAreas: junk dropped, unique, ascending.
	local cleaned = PickerFrame.builtAreas({ 3, 1, 3, nan, 1.5, -2, 0, 99, "4", math.huge })
	check(#cleaned == 2 and cleaned[1] == 1 and cleaned[2] == 3, "builtAreas drops junk, sorts, dedups")
	check(#PickerFrame.builtAreas("1,2") == 0 and #PickerFrame.builtAreas(nil) == 0, "builtAreas: non-tables -> {}")

	-- Area sets: every prefix (a base growing in order) + sparse / odd sets.
	local sets: { { number } } = {}
	for n = 1, WorldLayout.AreaCount do
		local set = {}
		for area = 1, n do
			set[area] = area
		end
		table.insert(sets, set)
	end
	for _, extra in { { 2 }, { 10 }, { 1, 10 }, { 5, 6 }, { 1, 3, 7 }, { 9, 10 } } do
		table.insert(sets, extra)
	end
	local aspects = { 1.0, 4 / 3, 16 / 9, 19.5 / 9, 2.4 }
	local clampedViews, fitViews = 0, 0
	for slot = 1, WorldLayout.PlotCount do
		for _, set in sets do
			for _, aim in set do
				for _, aspect in aspects do
					local view = PickerFrame.view(slot, set, aim, aspect)
					local label = `slot {slot} areas [{table.concat(set, ",")}] aim {aim} aspect {aspect}`
					check(
						view.distance >= FRAME.MinDistance - 1e-6 and view.distance <= FRAME.MaxDistance + 1e-6,
						`{label}: distance within [Min, Max]`
					)
					check(
						math.abs((view.focus - view.eye).Magnitude - view.distance) < 1e-3,
						`{label}: distance is eye-focus`
					)
					check(view.eye.Y > 60, `{label}: camera well above the base`)
					-- The aimed area is ALWAYS fully in view, and close: every corner within 1.5 x Max.
					local aimed = areaCorners(slot, aim, 0)
					check(inWindow(view.eye, view.focus, aimed, aspect), `{label}: aimed area fully in view`)
					for _, corner in aimed do
						check((corner - view.eye).Magnitude < FRAME.MaxDistance * 1.5, `{label}: aimed area is close`)
					end
					if view.clamped then
						clampedViews += 1
						check(view.distance == FRAME.MaxDistance, `{label}: a clamped view sits at MaxDistance`)
					else
						fitViews += 1
						-- The whole built footprint in view ...
						for _, area in set do
							check(
								inWindow(view.eye, view.focus, areaCorners(slot, area, 0), aspect),
								`{label}: area {area} in view`
							)
						end
						-- ... and as close as that allows (2 studs closer breaks the fit, unless at Min).
						if view.distance > FRAME.MinDistance + 2 then
							local f = (view.focus - view.eye).Unit
							local closer = view.focus - f * (view.distance - 2)
							check(
								not inWindow(closer, view.focus, unionCorners(slot, set), aspect),
								`{label}: smallest fitting distance`
							)
						end
					end
				end
			end
		end
		-- A brand-new base (area 1 only): a close view, not ~890 studs.
		local fresh = PickerFrame.view(slot, { 1 }, 1, 16 / 9)
		check(not fresh.clamped and fresh.distance <= 260, `slot {slot}: a new player's garage is framed close up`)
		-- Empty / junk areas frame area 1; nil frames the whole plot (my own plot, no targets).
		local empty = PickerFrame.view(slot, {}, nil, 16 / 9)
		check((empty.focus - fresh.focus).Magnitude < 1e-6, `slot {slot}: no built areas -> area 1`)
		local whole = PickerFrame.view(slot, nil, nil, 16 / 9)
		check(whole.distance <= FRAME.MaxDistance, `slot {slot}: whole-plot view capped`)
		-- Stream focus: on the built base (area 1 inside StreamingMinRadius), plot inside the target radius.
		for _, set in sets do
			local point = PickerFrame.streamPoint(slot, set)
			check(
				(PickerStream.focusPoint(slot, set) - point).Magnitude < 1e-6,
				`slot {slot}: focusPoint = streamPoint`
			)
			for _, area in set do
				for _, corner in areaCorners(slot, area, 0) do
					check(
						(corner - point).Magnitude < targetRadius,
						`slot {slot}: area {area} inside the stream target radius`
					)
				end
			end
			local origin = WorldLayout.plotOrigin(slot)
			for _, x in { -WorldLayout.PlotHalfWidth, WorldLayout.PlotHalfWidth } do
				for _, z in { 0, WorldLayout.PlotLength } do
					check(
						((origin * Vector3.new(x, 0, z)) - point).Magnitude < targetRadius,
						`slot {slot}: whole plot streams`
					)
				end
			end
		end
		for _, corner in areaCorners(slot, 1, 0) do
			check(
				(corner - PickerFrame.streamPoint(slot, { 1 })).Magnitude < minRadius,
				`slot {slot}: a new garage is inside StreamingMinRadius`
			)
		end
	end
	check(clampedViews > 0 and fitViews > 0, `both framings exercised (fit {fitViews}, clamped {clampedViews})`)

	-- Rival islands keep their close island view.
	for rival = 1, #RIVALS.List do
		local slot = AttackGeometry.rivalSlot(rival)
		local eye, focus = AttackGeometry.pickerView(slot)
		local view = PickerFrame.view(slot, { 1, 2, 3 }, 2, 16 / 9)
		check(
			(view.eye - eye).Magnitude < 1e-6 and (view.focus - focus).Magnitude < 1e-6,
			`rival {rival}: island view kept`
		)
		check(view.distance <= FRAME.MaxDistance, `rival {rival}: island view is close`)
		local f = (focus - eye).Unit
		local half = RIVALS.ShieldSize / 2
		local frame = AttackGeometry.rivalFrame(rival)
		for _, aspect in { 16 / 9, 4 / 3, 19.5 / 9 } do
			for _, x in { -half.X, half.X } do
				for _, z in { -half.Z, half.Z } do
					local px, py, depth = PickerFrame.project(
						eye,
						f,
						frame * (RIVALS.ShieldCentre + Vector3.new(x, 0, z)),
						tanV * aspect,
						tanV
					)
					check(
						depth > 0 and math.abs(px) < 1 and math.abs(py) < 1,
						`rival {rival}: island corner in the FOV`
					)
				end
			end
		end
	end
	check(not pcall(PickerFrame.view, 0, nil, nil, 1), "view refuses a bad slot")
end

-- 3. R104 wiring --------------------------------------------------------------------------------------
do
	local remotes = source("src/shared/Net/Remotes.luau")
	check(select(2, string.gsub(remotes, '"AttackPickerFocus"', "")) >= 2, "AttackPickerFocus typed + registered")
	local server = source("src/server/Attack/PickerFocus.luau")
	for _, needle in
		{
			'Remotes.onServerEvent("AttackPickerFocus"',
			"PickerStream.readSlot(raw)",
			"limiter:Allow(player)",
			"AddReplicationFocus",
			"RemoveReplicationFocus",
			"PlayerRemoving",
			"limiter:Forget(player)",
			"STREAM.FocusLinger",
			"STREAM.FocusExpire",
			"part.CanCollide = false",
			"part.CanQuery = false",
			"part.CanTouch = false",
		}
	do
		check(string.find(server, needle, 1, true) ~= nil, `PickerFocus: {needle}`)
	end
	check(
		string.find(server, "UserId", 1, true) == nil or string.find(server, "SetAttribute", 1, true) == nil,
		"focus parts carry no player id"
	)
	check(
		string.find(source("src/server/Services/AttackService.luau"), "PickerFocus.start()", 1, true) ~= nil,
		"AttackService starts PickerFocus"
	)
	local screen = source("src/client/UI/Screens/AttackTarget/AttackScreen.luau")
	for _, needle in
		{
			"PickerView.focus(plot, areas)",
			"PickerFrame.view(plot, areas, aim, aspect)",
			"frameCameraOn(target.plot, target.areas, aimOf(target), false)",
			"PickerView.keepAlive()",
			"PickerView.release()",
			"PickerView.Changed:Connect",
			"camera.Focus = ",
		}
	do
		check(string.find(screen, needle, 1, true) ~= nil, `AttackScreen: {needle}`)
	end
	check(
		string.find(screen, ":RequestStreamAroundAsync(", 1, true) == nil,
		"the picker no longer relies on a lone RequestStreamAroundAsync"
	)
	local view = source("src/client/Attack/PickerView.luau")
	check(
		string.find(view, 'Remotes.event("AttackPickerFocus"):FireServer(slot)', 1, true) ~= nil,
		"PickerView sends the intent"
	)
	check(
		string.find(view, "RequestStreamAroundAsync(point, STREAM.RequestTimeout)", 1, true) ~= nil,
		"PickerView first push"
	)
	check(AttackConfig.RateLimits.PickerFocus.capacity >= 4, "rate limit allows < > cycling")
	for _, key in { "view:player", "view:rival", "view:refused:slot", "view:refused:rate" } do
		check(KeySpec.check("attack", key) == key, `analytics key {key} is allowlisted`)
	end
	check(KeySpec.check("attack", "view:other") == nil, "unknown view kind refused")
end

-- 4. R105 defence billboards clear of producer billboards ---------------------------------------------
do
	local BOARD = AttackConfig.Towers.Billboard
	check(BOARD.Pixels.Y >= 44 and BOARD.DesktopPixels.Y >= 44, "whole-board taps >= 44 px")
	check(
		BOARD.DesktopPixels.X <= BOARD.Pixels.X and BOARD.DesktopPixels.Y <= BOARD.Pixels.Y,
		"desktop boards no bigger"
	)
	check(BOARD.MaxDistance < 90 and BOARD.PadMaxDistance < 170, "culling shorter than before R105")
	local world = source("src/client/Attack/DefenseWorld.luau")
	check(
		string.find(world, "UDim2.fromOffset(math.floor(pixels.X), math.floor(pixels.Y))", 1, true) ~= nil,
		"boards are a constant pixel size"
	)
	check(string.find(world, "DefenseBoardPlacement.solve(", 1, true) ~= nil, "DefenseWorld uses the solver")
	check(
		string.find(world, "ProducerBillboards.ownRecords()", 1, true) ~= nil,
		"runtime declutter reads the live producer boards"
	)

	local desktop = Placement.view(false, 900, 70)
	-- The owner's screenshot: the Silo slot (3) pad board + the HQ board by the Launch Silos clip
	-- the Silo Launch producer board at their old spots.
	local silo = 3
	local padBase = Placement.solve(1, silo, "pad", 0, desktop)
	local hqBase = Placement.solve(1, 0, "hq", 3, desktop)
	-- (Whether the OLD spot clips depends on the producer boards' current spots, which their own
	-- solver owns — R117 moved some; the solved spots must be clear either way.)
	check(hqBase.clear and hqBase.overlap == 0, "the HQ board's solved spot is clear")
	check(padBase.clear, "the Silo pad board's solved spot is clear")

	local views = {
		{ name = "desktop", view = desktop, strict = true },
		{ name = "tablet", view = Placement.view(true, 800, 70), strict = true },
		{ name = "console", view = Placement.view(true, 1080, 70), strict = true },
		{ name = "phone", view = Placement.view(true, 390, 70), strict = false },
	}
	local maxCost = 0
	for _, PLACE in { BOARD.Placement } do
		maxCost = PLACE.Lifts[#PLACE.Lifts] * PLACE.LiftCost
			+ math.max(table.unpack(PLACE.Alongs)) * PLACE.AlongCost
			+ PLACE.Outs[#PLACE.Outs] * PLACE.OutCost
	end
	for _, entry in views do
		local reducedSum, baseSum = 0, 0
		local function audit(plot: number, tower: number, kind: string, level: number)
			local spot = Placement.solve(plot, tower, kind, level, entry.view)
			local label = `{entry.name} plot {plot} tower {tower} {kind} L{level}`
			if entry.strict then
				check(spot.clear and spot.overlap == 0, `{label}: clear`)
			end
			local before = Placement.score(plot, tower, kind, level, entry.view, spot.base)
			local after = Placement.score(plot, tower, kind, level, entry.view, spot.position)
			check(after <= before + 1e-9, `{label}: never worse than the base spot`)
			baseSum += before
			reducedSum += after
			check(spot.cost <= maxCost + 1e-9, `{label}: stays near its object`)
			local _, object = Placement.base(plot, tower, kind, level)
			check(spot.position.Y >= object.Y + 3, `{label}: above the ground`)
			check((spot.position - spot.base).Magnitude <= 25, `{label}: bounded move`)
		end
		for plot = 1, WorldLayout.PlotCount do
			for tower = 1, #AttackConfig.Towers.Slots do
				audit(plot, tower, "pad", 0)
				audit(plot, tower, "slot", 1)
			end
			for level = 1, AttackConfig.MaxLevel do
				audit(plot, 0, "hq", level)
			end
		end
		if baseSum > 0 then
			check(
				reducedSum < baseSum * 0.35,
				`{entry.name}: the solve removes most of the overlap ({reducedSum} vs {baseSum})`
			)
		end
	end
	-- Junk view inputs fall back to sane values.
	local junkView = Placement.view(true, nan, math.huge)
	check(junkView.viewportY == BOARD.Placement.PhoneViewport and junkView.fov == 70, "junk view falls back")
end

-- 5. R106 tower animation maths -------------------------------------------------------------------------
do
	local ANIM = AttackConfig.TowerAnim
	local expect = {
		Turret = "yaw",
		TurretTrim = "yaw",
		TurretGlow = "yaw",
		Pip = "yaw",
		TurretDish = "dish",
		Barrel = "pitch",
		BarrelTip = "pitch",
		Base = nil,
		Tower = nil,
		TowerTrim = nil,
		Glow = nil,
		HazardBlack = nil,
	} :: { [string]: string? }
	for name, group in expect do
		check(TowerAnimMath.classify(name) == group, `classify {name}`)
	end
	check(TowerAnimMath.classify("Base") == nil and TowerAnimMath.classify("Glow") == nil, "static pieces stay")

	-- Joints = the Blender builders' notes in MeshAssets.
	local function vec(text: string): Vector3
		local x, y, z = string.match(text, "%(([%-%d%.]+),%s*([%-%d%.]+),%s*([%-%d%.]+)%)")
		return Vector3.new(tonumber(x) :: number, tonumber(y) :: number, tonumber(z) :: number)
	end
	for level, key in AttackConfig.Models.Towers do
		local entry = MeshAssets[key]
		check(type(entry) == "table" and type(entry.pivot) == "string", `{key} has pivot notes`)
		local turretText = string.match(entry.pivot, "Turret@(%b())")
		local barrelText = string.match(entry.pivot, "Barrel@(%b())")
		check(turretText ~= nil and barrelText ~= nil, `{key}: joint notes present`)
		local turret, barrel = TowerAnimMath.joints(level)
		check((turret - vec(turretText :: string)).Magnitude < 1e-6, `{key}: turret joint matches`)
		check((barrel - vec(barrelText :: string)).Magnitude < 1e-6, `{key}: barrel joint matches`)
		local groups: { [string]: number } = {}
		for _, piece in entry.order do
			local group = TowerAnimMath.classify(piece)
			if group ~= nil then
				groups[group] = (groups[group] or 0) + 1
			end
		end
		check((groups.yaw or 0) >= 1 and (groups.pitch or 0) >= 1, `{key}: yaw + pitch pieces`)
		if level >= 3 then
			check((groups.dish or 0) == 1, `{key}: a radar dish`)
		end
	end
	local t1, b1 = TowerAnimMath.joints(0)
	local t5, b5 = TowerAnimMath.joints(99)
	check(
		t1 == ANIM.Joints[1].turret and b5 == ANIM.Joints[#ANIM.Joints].barrel and t5 ~= nil and b1 ~= nil,
		"joint levels clamp"
	)
	check(TowerAnimMath.joints(nan) == ANIM.Joints[1].turret, "junk level clamps")

	-- Idle bounds over a long run.
	local sweepMax = math.rad(ANIM.SweepDegrees) * (1 + ANIM.Wobble) + 1e-9
	local yawMin, yawMax = math.huge, -math.huge
	for step = 0, 4000 do
		local t = step * 0.05
		for _, phase in { 0, 1.3, 4.4 } do
			local yaw = TowerAnimMath.idleYaw(t, phase)
			local pitch = TowerAnimMath.idlePitch(t, phase)
			check(math.abs(yaw) <= sweepMax, "idle yaw within the sweep")
			check(pitch >= math.rad(ANIM.PitchRestDegrees) - 1e-9, "idle pitch above rest")
			check(pitch <= math.rad(ANIM.PitchRestDegrees + ANIM.PitchBobDegrees) + 1e-9, "idle pitch within the bob")
			yawMin, yawMax = math.min(yawMin, yaw), math.max(yawMax, yaw)
		end
	end
	check(yawMax - yawMin > math.rad(ANIM.SweepDegrees), "the idle scan really sweeps")

	-- Recoil.
	check(TowerAnimMath.recoil(0) == 1, "full recoil at the shot")
	local previous = 1
	for step = 1, 29 do
		local value = TowerAnimMath.recoil(step * ANIM.RecoilSeconds / 30)
		check(value < previous and value > 0, "recoil eases home monotonically")
		previous = value
	end
	check(TowerAnimMath.recoil(ANIM.RecoilSeconds) == 0, "settled after RecoilSeconds")
	check(TowerAnimMath.recoil(-1) == 0 and TowerAnimMath.recoil(nan) == 0, "no recoil before a shot / on junk")

	-- Follow: shortest way round, converges, frame-rate independent.
	local across = TowerAnimMath.follow(math.rad(170), math.rad(-170), 1000, 0.1)
	check(math.abs(TowerAnimMath.wrap(across - math.rad(-170))) < 1e-3, "follow converges")
	local halfway = TowerAnimMath.follow(math.rad(170), math.rad(-170), 1, 0.05)
	check(halfway > math.rad(170), "follow crosses the ±180° seam the short way")
	local one = TowerAnimMath.follow(0, 1, 5, 0.1)
	local two = TowerAnimMath.follow(TowerAnimMath.follow(0, 1, 5, 0.05), 1, 5, 0.05)
	check(math.abs(one - two) < 1e-9, "follow is frame-rate independent")
	check(TowerAnimMath.follow(0.5, 1, 5, 0) == 0.5, "zero dt does not move")

	-- Aim maths.
	local yaw, pitch = TowerAnimMath.aim(Vector3.new(0, 0, -10))
	check(math.abs(yaw) < 1e-9 and math.abs(pitch) < 1e-9, "straight ahead = rest")
	local yawUp, pitchUp = TowerAnimMath.aim(Vector3.new(0, 10, -10))
	check(math.abs(yawUp) < 1e-9 and math.abs(pitchUp - math.pi / 4) < 1e-9, "45° up")
	local yawRight = TowerAnimMath.aim(Vector3.new(10, 0, 0))
	check(math.abs(yawRight + math.pi / 2) < 1e-9, "a target on the right turns -90° (CFrame yaw)")

	-- Phases differ between neighbouring towers; culls.
	local seen: { [number]: boolean } = {}
	for plot = 1, SLOTS do
		for tower = 0, #AttackConfig.Towers.Slots do
			local phase = TowerAnimMath.phase(plot, tower)
			check(phase >= 0 and phase < 2 * math.pi, "phase in range")
			seen[math.floor(phase * 1000)] = true
		end
	end
	local distinct = 0
	for _ in seen do
		distinct += 1
	end
	check(distinct >= SLOTS * 3, "towers rarely share a phase")
	check(TowerAnimMath.cullDistance("Low") == 0, "Low tier: idle off")
	check(TowerAnimMath.cullDistance("High") > TowerAnimMath.cullDistance("Mid"), "High animates further")
	check(TowerAnimMath.cullDistance("junk") == ANIM.Cull.Mid, "unknown tier = Mid")
end

-- 6. R106 wiring ----------------------------------------------------------------------------------------
do
	local anim = source("src/client/Attack/TowerAnim.luau")
	local _, preRenders = string.gsub(anim, "RunService.PreRender:Connect%(step%)", "")
	check(preRenders >= 1, "TowerAnim drives one PreRender step")
	local _, bulk = string.gsub(anim, "Workspace:BulkMoveTo%(", "")
	check(bulk == 1, "one BulkMoveTo per frame")
	-- Instance.new only inside the flash pool builder.
	local poolStart = string.find(anim, "local function flashPool", 1, true) :: number
	local poolEnd = string.find(anim, "-- Shows a muzzle flash", 1, true) :: number
	local before = string.sub(anim, 1, poolStart)
	local after = string.sub(anim, poolEnd)
	check(
		string.find(before, "Instance.new(", 1, true) == nil and string.find(after, "Instance.new(", 1, true) == nil,
		"no Instance.new outside the flash pool"
	)
	check(string.find(anim, "OfferFx.reducedMotion()", 1, true) ~= nil, "Reduce Motion respected")
	check(string.find(anim, "FxQuality.tier()", 1, true) ~= nil, "FxQuality culls")
	check(string.find(anim, "BuildInConfig.TimeAttribute", 1, true) ~= nil, "fresh fly-ins hold still")
	local flight = source("src/client/Attack/FlightRenderer.luau")
	check(
		string.find(flight, "TowerAnim.aim(data.toPlot, tower, position)", 1, true) ~= nil,
		"FlightRenderer aims through TowerAnim"
	)
	check(string.find(flight, "TowerAnim.fire(data.toPlot, shot.tower)", 1, true) ~= nil, "shots recoil + flash")
	check(
		string.find(flight, "TurretRig", 1, true) == nil and string.find(flight, "addTurret", 1, true) == nil,
		"no second turret rig owner"
	)
	check(string.find(flight, "TowerAnim.start()", 1, true) ~= nil, "FlightRenderer.start starts TowerAnim")
end

-- 7. R109 silo rockets lift off + reload ---------------------------------------------------------------
do
	local FX = AttackConfig.SiloFx
	-- Timeline phases.
	check(SiloLaunchMath.phase(-FX.IgniteLead - 0.01) == "before", "before the ignite")
	check(SiloLaunchMath.phase(-FX.IgniteLead) == "ignite" and SiloLaunchMath.phase(-0.01) == "ignite", "ignite window")
	check(
		SiloLaunchMath.phase(0) == "handoff" and SiloLaunchMath.phase(FX.HandOff - 0.01) == "handoff",
		"hand-off window"
	)
	check(SiloLaunchMath.phase(FX.HandOff) == "gone", "gone after the hand-off")
	check(SiloLaunchMath.phase(nan) == "before", "junk time = nothing")
	-- Ignite rise: 0 at ignition → SlowRise at t0, monotonic.
	check(SiloLaunchMath.rise(-FX.IgniteLead) == 0, "no rise at ignition")
	check(math.abs(SiloLaunchMath.rise(0) - FX.SlowRise) < 1e-9, "SlowRise by t0")
	local last = -1
	for step = 0, 20 do
		local value = SiloLaunchMath.rise(-FX.IgniteLead + step * FX.IgniteLead / 20)
		check(value >= last, "rise is monotonic")
		last = value
	end
	-- Hand-off: blend 0 → 1 (smooth, monotonic), climb accelerates, scale ends at the flight length.
	check(SiloLaunchMath.blend(0) == 0 and SiloLaunchMath.blend(FX.HandOff) == 1, "blend ends")
	local previousBlend, previousClimb, previousStep = -1, -1, -1
	for step = 0, 40 do
		local rel = step * FX.HandOff / 40
		local b = SiloLaunchMath.blend(rel)
		check(b >= previousBlend - 1e-12 and b >= 0 and b <= 1, "blend monotonic in [0, 1]")
		previousBlend = b
		local climb = SiloLaunchMath.climb(rel)
		check(climb >= previousClimb, "climb monotonic")
		if step > 0 then
			check(climb - previousClimb >= previousStep - 1e-9, "climb accelerates")
			previousStep = climb - previousClimb
		end
		previousClimb = climb
	end
	check(math.abs(SiloLaunchMath.climb(0) - FX.SlowRise) < 1e-9, "the climb starts where the ignite ended")
	for tier = 1, AttackConfig.MaxLevel do
		local length = ({ 9, 10, 11, 12, 13.5 })[tier]
		check(SiloLaunchMath.scale(0, length) == 1, "full size at t0")
		check(
			math.abs(SiloLaunchMath.scale(FX.HandOff, length) * FX.SiloLength - length) < 1e-9,
			`tier {tier}: ends at the flight nuke's length`
		)
	end
	check(
		math.abs(SiloLaunchMath.scale(FX.HandOff, nan) * FX.SiloLength - FX.FlightLength) < 1e-9,
		"junk length falls back"
	)
	check(
		math.abs(SiloLaunchMath.scale(FX.HandOff, -3) * FX.SiloLength - FX.FlightLength) < 1e-9,
		"negative length falls back"
	)
	-- The hand-off ends exactly on the flight arc: the clone's tail = the arc point, so the flight
	-- nuke (pivot = its tail) takes over without a jump.
	local flight = FlightMath.build(Vector3.new(0, 25.7, 0), Vector3.new(900, 0, 300))
	local b = SiloLaunchMath.blend(FX.HandOff)
	local own = Vector3.new(0, 25.7, 0) + Vector3.new(0, SiloLaunchMath.climb(FX.HandOff), 0)
	local tail = own:Lerp(FlightMath.position(flight, FX.HandOff), b)
	check((tail - FlightMath.position(flight, FX.HandOff)).Magnitude < 1e-6, "hand-off lands on the arc")
	-- Reload time per kind.
	for level, launcher in AttackConfig.Launcher do
		check(
			SiloLaunchMath.reloadSeconds("normal", level) == math.max(launcher.cooldown, FX.MinReload),
			`normal L{level}: the launcher cooldown`
		)
	end
	for _, kind in { "revenge", "golden", "barrage" } do
		check(SiloLaunchMath.reloadSeconds(kind, 3) == math.max(FX.QuickReload, FX.MinReload), `{kind}: quick reload`)
	end
	check(SiloLaunchMath.reloadSeconds("normal", nan) == AttackConfig.Launcher[1].cooldown, "junk tier clamps")
	check(
		SiloLaunchMath.reloadSeconds("normal", 99) == AttackConfig.Launcher[#AttackConfig.Launcher].cooldown,
		"high tier clamps"
	)
	-- Reload rise / fade.
	check(SiloLaunchMath.progress(5, 0, 10) == 0.5 and SiloLaunchMath.progress(-1, 0, 10) == 0, "progress")
	check(
		SiloLaunchMath.progress(20, 0, 10) == 1 and SiloLaunchMath.progress(1, 5, 5) == 1,
		"progress clamps / empty span"
	)
	check(
		SiloLaunchMath.reloadOffset(0) == -FX.ReloadDepth and SiloLaunchMath.reloadOffset(1) == 0,
		"reload rises from ReloadDepth"
	)
	check(
		math.abs(SiloLaunchMath.reloadFade(0) - FX.ReloadFade) < 1e-9 and SiloLaunchMath.reloadFade(1) == 0,
		"reload fades in"
	)
	local previousOffset = -math.huge
	for step = 0, 20 do
		local offset = SiloLaunchMath.reloadOffset(step / 20)
		check(offset >= previousOffset, "reload rise monotonic")
		previousOffset = offset
	end
	-- Timing fits the flight lead-in (the client has the NukeFlight before the ignite starts).
	check(FX.IgniteLead < AttackConfig.Flight.LeadIn - 1, "ignite fits inside the lead-in with network slack")
	check(FX.HandOff < AttackConfig.Flight.MinSeconds / 2, "hand-off is a small part of the shortest flight")

	-- The art agrees: every launch build has a rocket animation with a mesh; its nose = the launch point.
	check(#Area07.launchBuilds == #Area07.launchPoints, "one launch build per silo")
	for silo, build in Area07.launchBuilds do
		local animation = nil
		for _, entry in Area07.animations do
			if entry.kind == "launch" and entry.build == build then
				animation = entry
			end
		end
		check(animation ~= nil, `silo {silo}: a launch animation for {build}`)
		check(MeshAssets[animation.model] ~= nil, `silo {silo}: rocket mesh {animation.model}`)
		local found = false
		for _, model in Area07.builds[build].models do
			if model.key == animation.model then
				found = true
				check(
					(model.cf.Position - animation.pivot.Position).Magnitude < 1e-4,
					`silo {silo}: rocket pivot = animation pivot`
				)
			end
		end
		check(found, `silo {silo}: the rocket is part of its build`)
		local nose = animation.pivot.Position + Vector3.new(0, FX.SiloLength, 0)
		check((nose - Area07.launchPoints[silo].Position).Magnitude < 1e-4, `silo {silo}: nose tip = launch point`)
		local plot = 1
		local worldNose = WorldLayout.slotToWorld(plot, 7, CFrame.new(nose)).Position
		check(
			(worldNose - AttackGeometry.launchPoint(plot, silo)).Magnitude < 1e-3,
			`silo {silo}: the flight starts at the rocket's nose`
		)
	end
	check(
		string.find(MeshAssets.A7_SiloNuke_Red.pivot, "tip at y = 24", 1, true) ~= nil,
		"rocket length = SiloLength (mesh notes)"
	)

	-- Wiring.
	local silo = source("src/client/Attack/SiloLaunch.luau")
	local flightSource = source("src/client/Attack/FlightRenderer.luau")
	check(
		string.find(flightSource, "pcall(SiloLaunch.launch, data, flight)", 1, true) ~= nil,
		"every flight asks for a silo hand-off"
	)
	check(string.find(flightSource, "rel >= entry.handOff", 1, true) ~= nil, "the flight nuke waits for the hand-off")
	check(string.find(silo, "LocalTransparencyModifier", 1, true) ~= nil, "the server rocket is hidden locally")
	check(
		string.find(silo, "real:PivotTo", 1, true) == nil and string.find(silo, "real.CFrame", 1, true) == nil,
		"the server rocket is never moved"
	)
	local _, bulk = string.gsub(silo, "Workspace:BulkMoveTo%(", "")
	check(bulk == 1, "one BulkMoveTo per frame")
	check(string.find(silo, "RunService.PreRender:Connect(step)", 1, true) ~= nil, "one PreRender loop")
	for _, needle in
		{
			"OfferFx.reducedMotion()",
			"FxQuality.tier()",
			"KnockdownConfig.Attr.Until",
			"FX.CullDistance",
			"FX.ReloadDistance",
		}
	do
		check(string.find(silo, needle, 1, true) ~= nil, `SiloLaunch: {needle}`)
	end
	-- No Instance.new / Create.new in the frame body (stepLaunch / stepReload / step).
	local bodyStart = string.find(silo, "-- One silo's lift-off frame.", 1, true) :: number
	local bodyEnd = string.find(silo, "-- The flight nuke's length for a tier", 1, true) :: number
	local body = string.sub(silo, bodyStart, bodyEnd)
	check(
		string.find(body, "Instance.new(", 1, true) == nil and string.find(body, "Create.new(", 1, true) == nil,
		"no allocation in the frame body"
	)
end

-- 8. R118 picker layout ---------------------------------------------------------------------------------
do
	local CFG = AttackConfig.Client.PickerLayout
	-- Vector2 is float32 (Roblox and Lune): ~1e-4 px at canvas magnitudes; 0.01 px is invisible.
	local EPS = 0.01
	-- Picker block sizes (AttackScreen): top 1120 x 250, bottom 1286 x 190 + 60 margin.
	local TOP_W, TOP_H, BOTTOM_W, BOTTOM_H, BOTTOM_MARGIN = 1120, 250, 1286, 190, 60
	local devices = {
		{ name = "phone", x = 844, y = 390, class = "Phone", topbar = 58 },
		{ name = "small phone", x = 667, y = 375, class = "Phone", topbar = 58 },
		{ name = "tablet", x = 1180, y = 820, class = "Tablet", topbar = 58 },
		{ name = "console", x = 1920, y = 1080, class = "Console", topbar = 72 },
		{ name = "desktop", x = 1920, y = 1080, class = "Desktop", topbar = 58 },
		{ name = "laptop", x = 1366, y = 768, class = "Desktop", topbar = 58 },
	}
	-- No two chips overlap (+ gap).
	local function noOverlap(centres: { Vector2 }, chip: Vector2, label: string)
		for i = 1, #centres do
			for j = i + 1, #centres do
				local a, b = centres[i], centres[j]
				local apart = math.abs(a.X - b.X) >= chip.X + CFG.Gap - EPS
					or math.abs(a.Y - b.Y) >= chip.Y + CFG.Gap - EPS
				check(apart, `{label}: chips {i} / {j} do not overlap`)
			end
		end
	end
	local function audit(
		layout: any,
		count: number,
		canvasX: number,
		bandTop: number,
		bandBottom: number,
		chip: Vector2,
		label: string
	)
		check(#layout.centres == count and #layout.order == count, `{label}: one chip per area`)
		local seen = {}
		for _, index in layout.order do
			check(seen[index] == nil and index >= 1 and index <= count, `{label}: order is a permutation`)
			seen[index] = true
		end
		noOverlap(layout.centres, chip, label)
		local half = chip / 2
		for index, centre in layout.centres do
			if layout.mode == "pinned" then
				check(
					centre.Y - half.Y >= bandTop - EPS and centre.Y + half.Y <= bandBottom + EPS,
					`{label}: chip {index} inside the band`
				)
				check(
					centre.X - half.X >= CFG.Margin - EPS and centre.X + half.X <= canvasX - CFG.Margin + EPS,
					`{label}: chip {index} inside the canvas`
				)
			elseif layout.scroll then
				check(
					centre.X - half.X >= -EPS and centre.X + half.X <= layout.stripWidth + EPS,
					`{label}: chip {index} inside the strip`
				)
			else
				check(
					centre.X - half.X >= CFG.Margin - EPS and centre.X + half.X <= canvasX - CFG.Margin + EPS,
					`{label}: chip {index} inside the canvas row`
				)
				check(math.abs(centre.Y - layout.stripY) < EPS, `{label}: one tidy row`)
			end
		end
		if layout.mode == "strip" then
			for slot = 2, #layout.order do
				check(
					layout.spots[layout.order[slot - 1]].X <= layout.spots[layout.order[slot]].X + EPS,
					`{label}: strip follows the areas left to right`
				)
			end
		end
	end

	-- Blocks + band per device.
	local deviceBlocks = {}
	for _, device in devices do
		local scale = DeviceProfile.uiScale(device.x, device.y, device.class)
		local canvas = Vector2.new(device.x / scale, device.y / scale)
		local safeTop = device.topbar / scale + 16
		local blocks = PickerLayout.blocks(canvas, safeTop, scale, TOP_H, BOTTOM_H, BOTTOM_W, BOTTOM_MARGIN, TOP_W)
		deviceBlocks[device.name] = { blocks = blocks, canvas = canvas, scale = scale }
		check(blocks.chip.Y * scale >= CFG.MinTapPoints - EPS, `{device.name}: chips >= 44 pt`)
		check(112 * blocks.topScale * scale >= CFG.MinTapPoints - EPS, `{device.name}: < > buttons >= 44 pt`)
		check(116 * blocks.bottomScale * scale >= CFG.MinTapPoints - EPS, `{device.name}: action buttons >= 44 pt`)
		check(
			blocks.bandBottom - blocks.bandTop >= blocks.chip.Y + EPS,
			`{device.name}: a band for one chip row ({blocks.bandBottom - blocks.bandTop} px)`
		)
		check(TOP_W * blocks.topScale <= canvas.X - 2 * CFG.Margin + EPS, `{device.name}: the top block fits the width`)
		check(
			BOTTOM_W * blocks.bottomScale <= canvas.X - 2 * CFG.Margin + EPS,
			`{device.name}: the bottom row fits the width`
		)
	end

	-- The R118 screenshot case: four labels on (nearly) one line, closer than a chip is wide.
	do
		local d = deviceBlocks.phone
		local blocks = d.blocks
		local labels = { "BIG MACHINE", "WAREHOUSE", "WORKSHOP", "TOY SHOP" }
		local chip = PickerLayout.chipFor(labels, blocks.chip.Y)
		for _, text in labels do
			check(chip.X >= #text * PickerLayout.CHIP_TEXT * 0.6 + 20, `chip fits "{text}"`)
		end
		local y = (blocks.bandTop + blocks.bandBottom) / 2
		local anchors = {}
		for i = 1, 4 do
			anchors[i] = Vector2.new(d.canvas.X / 2 - 120 + (i - 1) * 80, y)
		end
		local layout = PickerLayout.markers(anchors, nil, blocks.bandTop, blocks.bandBottom, d.canvas.X, chip)
		audit(layout, 4, d.canvas.X, blocks.bandTop, blocks.bandBottom, chip, "R118 row")
		-- All anchors on ONE point / below the band / off-canvas junk.
		local same = PickerLayout.markers(
			{ anchors[1], anchors[1], anchors[1] },
			nil,
			blocks.bandTop,
			blocks.bandBottom,
			d.canvas.X,
			chip
		)
		audit(same, 3, d.canvas.X, blocks.bandTop, blocks.bandBottom, chip, "one point")
		local junk = PickerLayout.markers(
			{ Vector2.new(nan, nan), Vector2.new(math.huge, -math.huge), Vector2.new(-1e9, 1e9) },
			{ nan, 99, -5 },
			blocks.bandTop,
			blocks.bandBottom,
			d.canvas.X,
			chip
		)
		audit(junk, 3, d.canvas.X, blocks.bandTop, blocks.bandBottom, chip, "junk anchors")
		local empty = PickerLayout.markers({}, nil, blocks.bandTop, blocks.bandBottom, d.canvas.X, chip)
		check(#empty.centres == 0, "no areas, no chips")
	end

	-- Randomised: counts 1..12, scattered / clustered anchors, every device band.
	local rng = Loader.Random.new(118)
	for _, device in devices do
		local d = deviceBlocks[device.name]
		local blocks = d.blocks
		for trial = 1, 120 do
			local count = 1 + (trial % 12)
			local anchors, sides = {}, {}
			local cluster = Vector2.new(rng:NextNumber(0, d.canvas.X), rng:NextNumber(0, d.canvas.Y))
			for i = 1, count do
				if trial % 3 == 0 then
					anchors[i] = cluster + Vector2.new(rng:NextNumber(-60, 60), rng:NextNumber(-30, 30))
				else
					anchors[i] =
						Vector2.new(rng:NextNumber(-100, d.canvas.X + 100), rng:NextNumber(-100, d.canvas.Y + 100))
				end
				sides[i] = rng:NextInteger(-1, 1)
			end
			local labels = {}
			for i = 1, count do
				labels[i] = string.rep("W", rng:NextInteger(3, 18))
			end
			local chip = PickerLayout.chipFor(labels, blocks.chip.Y)
			local layout = PickerLayout.markers(anchors, sides, blocks.bandTop, blocks.bandBottom, d.canvas.X, chip)
			audit(layout, count, d.canvas.X, blocks.bandTop, blocks.bandBottom, chip, `{device.name} trial {trial}`)
		end
	end

	-- Every target through the REAL picker camera on every device (projected like WorldToScreenPoint).
	local fov = math.rad(AttackConfig.Client.PickerFov)
	for _, device in devices do
		local d = deviceBlocks[device.name]
		local blocks = d.blocks
		local W, H = d.canvas.X, d.canvas.Y
		local tanV = math.tan(fov / 2)
		local tanH = tanV * W / H
		local pinnedCount, stripCount = 0, 0
		for slot = 1, SLOTS do
			-- Owner R133: the real picker camera (PickerFrame) on a fully built base, aimed at its top area.
			local view = PickerFrame.view(slot, nil, AttackGeometry.areaCount(slot), W / H)
			local eye, focus = view.eye, view.focus
			local f = (focus - eye).Unit
			local r = f:Cross(Vector3.new(0, 1, 0)).Unit
			local u = r:Cross(f)
			local areas = AttackGeometry.areaCount(slot)
			local anchors, sides, labels = {}, {}, {}
			for area = 1, areas do
				local world = AttackGeometry.aimPoint(slot, area, 0, 0)
				local dvec = world - eye
				local depth = dvec:Dot(f)
				anchors[area] =
					Vector2.new(W / 2 * (1 + dvec:Dot(r) / depth / tanH), H / 2 * (1 - dvec:Dot(u) / depth / tanV))
				local rival = AttackGeometry.rivalOfSlot(slot)
				if rival ~= nil then
					sides[area] = 0
					labels[area] = RIVALS.Sections[area].label .. " - DOWN"
				else
					local origin = AttackGeometry.plotOrigin(slot)
					sides[area] = if origin:PointToObjectSpace(world).X < 0 then -1 else 1
					labels[area] = KnockdownConfig.areaLabel(area) .. " - DOWN"
				end
			end
			local chip = PickerLayout.chipFor(labels, blocks.chip.Y)
			local layout = PickerLayout.markers(anchors, sides, blocks.bandTop, blocks.bandBottom, W, chip)
			audit(layout, areas, W, blocks.bandTop, blocks.bandBottom, chip, `{device.name} slot {slot}`)
			if layout.mode == "pinned" then
				pinnedCount += 1
			else
				stripCount += 1
			end
		end
		check(pinnedCount + stripCount == SLOTS, `{device.name}: every target laid out`)
	end

	-- Screen wiring: the stacked info plate, the layout module, the loading plate under the top block.
	local screen = source("src/client/UI/Screens/AttackTarget/AttackScreen.luau")
	for _, needle in
		{
			"PickerLayout.markers(",
			"PickerLayout.blocks(",
			"PickerLayout.chipFor(",
			'Create.new("UIListLayout"',
			'Name = "Content"',
			"parent = infoContent",
			"fitInfo()",
			"setLine(statusLabel, statusText)",
			'Name = "AimLeader"',
			'Name = "AimStrip"',
			"NextSelectionLeft",
			'root:SetAttribute("ChipH"',
		}
	do
		check(string.find(screen, needle, 1, true) ~= nil, `AttackScreen: {needle}`)
	end
	check(string.find(screen, "position = UDim2.fromOffset(0, 162)", 1, true) == nil, "no fixed-y status line any more")
	-- Owner R133: the studded info plate never holds the list layout itself (Widgets/PanelBackdrop
	-- "Layout rule": the layout would stack the surface's TopHighlight + PanelBackdrop as items) and
	-- never auto-sizes around them (that grew it into a ~550 px grey wall over the target's base).
	local plateStart = string.find(screen, 'local infoPlate = Create.new("Frame"', 1, true)
	local plateEnd = string.find(screen, "StudWindow.surface(infoPlate", 1, true)
	check(plateStart ~= nil and plateEnd ~= nil and plateEnd > plateStart, "info plate found")
	if plateStart ~= nil and plateEnd ~= nil then
		local plateBlock = string.sub(screen, plateStart, plateEnd)
		check(
			string.find(plateBlock, "UIListLayout", 1, true) == nil,
			"no UIListLayout directly on the studded info plate"
		)
		check(string.find(plateBlock, "AutomaticSize", 1, true) == nil, "the studded info plate is not auto-sized")
	end
	check(
		string.find(screen, "AutomaticSize = ", 1, true) == nil,
		"no AutomaticSize property in the picker (explicit sizes only)"
	)
	-- The plate's explicit height for all three lines fits under the top block.
	local function constant(name: string): number
		local value = string.match(screen, `local {name} = (%d+)`)
		return assert(tonumber(value), `constant {name}`)
	end
	local threeLines = 2 * constant("INFO_PAD_Y") + (32 + 6) + (36 + 6) + (30 + 6) + 2 * constant("INFO_GAP")
	check(120 + threeLines <= constant("TOP_HEIGHT"), `info plate (3 lines, {threeLines} px) fits the top block`)
end

print(`[attack-view] {checks} checks passed`)
