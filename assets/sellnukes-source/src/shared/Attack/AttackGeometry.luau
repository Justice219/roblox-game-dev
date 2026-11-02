--!strict
--[[
	AttackGeometry — where things are in the world for Attack mode: silo launch points, impact
	points, the AA turret mount / muzzle, the Attack Console prompt and the shield dome, for any
	plot (WorldLayout frames) — and for the Rival Factory islands (owner R43).

	Target slots: every function that takes a TARGET takes a slot, where
		1..PlotCount                         a player plot (WorldLayout.plotOrigin)
		PlotCount + i (i = 1..#Rivals.List)  Rival Factory island i (rivalFrame(i), AttackConfig.Rivals)
	Launch points (silos) and the console / tower prompts exist on plots only. NukeFlight carries
	the slot in `toPlot`, so clients rebuild rival flights from the same indices.

	Source of truth:
		The Area 7 art layout (Shared/Config/AreaLayouts/Area07, B8c) may define, in SLOT-LOCAL space:
			launchPoints = { CFrame, CFrame, CFrame }   -- silo mouths (+Y up)
			aaTowerMount = CFrame                       -- levelled turret mount (+Y up)
			consolePrompt = Vector3                     -- Attack Console ProximityPrompt spot
		Anything missing or malformed falls back to AttackConfig.Geometry, so attack mode works
		before (and independent of) the art. Impact points are PLOT-LOCAL (AttackConfig).

	Shared on purpose: the server computes the flight from these points and the client recomputes
	the SAME points from (plot, silo, impact) indices in the NukeFlight payload, so no positions
	travel over the network and a client cannot be fed arbitrary coordinates.

	Performance: the layout is read once and cached; every function is a couple of CFrame
	multiplications.

	Connects to: Shared/Config/{WorldLayout, AttackConfig, AreaLayouts/Area07}, Shared/Attack/
	FlightMath, Server/Services/{AttackService, DefenseService}, Client/Attack/*.

	Example:
		local from = AttackGeometry.launchPoint(myPlot, 1)
		local to = AttackGeometry.impactPoint(theirPlot, 3)
		local muzzle = AttackGeometry.muzzle(theirPlot)
		local slotMuzzle = AttackGeometry.muzzle(theirPlot, 2) -- owner R80 defence tower slot 2
]]

local AttackConfig = require(script.Parent.Parent.Config.AttackConfig)
local FlightMath = require(script.Parent.FlightMath)
local WorldLayout = require(script.Parent.Parent.Config.WorldLayout)

local AttackGeometry = {}

local GEOMETRY = AttackConfig.Geometry
local AREA = AttackConfig.UnlockArea

export type Layout = {
	launchPoints: { CFrame },
	aaTowerMount: CFrame,
	consolePrompt: Vector3,
}

local cached: Layout? = nil

-- Reads the optional Area07 art module (pcall: missing / broken / non-Roblox test env → nil).
local function readArtLayout(): { [string]: any }?
	local ok, result = pcall(function(): any
		local config = script.Parent.Parent.Config
		local folder = config:FindFirstChild("AreaLayouts")
		local module = if folder ~= nil then folder:FindFirstChild(string.format("Area%02d", AREA)) else nil
		if module == nil or not module:IsA("ModuleScript") then
			return nil
		end
		return require(module) :: any
	end)
	return if ok and type(result) == "table" then result else nil
end

-- A CFrame whose position stays inside the slot budget, else nil.
local function slotCFrame(value: unknown): CFrame?
	if typeof(value) == "CFrame" and WorldLayout.inSlot(AREA, (value :: CFrame).Position, 4) then
		return value :: CFrame
	end
	return nil
end

--[[
	The resolved Area 7 attack layout (art fields with config fallbacks), cached.
	@return Layout
]]
function AttackGeometry.layout(): Layout
	local existing = cached
	if existing ~= nil then
		return existing
	end
	local art = readArtLayout()
	local launchPoints: { CFrame } = {}
	local authoredPoints: any = if art ~= nil then art.launchPoints else nil
	for index, fallback in GEOMETRY.LaunchPoints do
		local authored = if type(authoredPoints) == "table" then authoredPoints[index] else nil
		launchPoints[index] = slotCFrame(authored) or fallback
	end
	local mount = if art ~= nil then slotCFrame(art.aaTowerMount) else nil
	local prompt = if art ~= nil
			and typeof(art.consolePrompt) == "Vector3"
			and WorldLayout.inSlot(AREA, art.consolePrompt, 4)
		then art.consolePrompt :: Vector3
		else nil
	local layout: Layout = {
		launchPoints = launchPoints,
		aaTowerMount = mount or GEOMETRY.AATowerMount,
		consolePrompt = prompt or GEOMETRY.ConsolePrompt,
	}
	cached = layout
	return layout
end

-- A valid plot index (1..PlotCount), else nil.
local function plotIndex(plot: unknown): number?
	if type(plot) == "number" and plot % 1 == 0 and plot >= 1 and plot <= WorldLayout.PlotCount then
		return plot
	end
	return nil
end
AttackGeometry.validPlot = plotIndex

local RIVALS = AttackConfig.Rivals

--[[ Number of target slots: the player plots, then one per Rival Factory. ]]
function AttackGeometry.slotCount(): number
	return WorldLayout.PlotCount + #RIVALS.List
end

-- A valid target slot (1..slotCount()), else nil.
local function slotIndex(slot: unknown): number?
	if type(slot) == "number" and slot % 1 == 0 and slot >= 1 and slot <= AttackGeometry.slotCount() then
		return slot
	end
	return nil
end
AttackGeometry.validTarget = slotIndex

--[[ The target slot of Rival Factory `index` (PlotCount + index). ]]
function AttackGeometry.rivalSlot(index: number): number
	return WorldLayout.PlotCount + index
end

--[[ The rival index of a target slot, or nil for a player plot / invalid slot. ]]
function AttackGeometry.rivalOfSlot(slot: unknown): number?
	local s = slotIndex(slot)
	if s == nil or s <= WorldLayout.PlotCount then
		return nil
	end
	return s - WorldLayout.PlotCount
end

--[[
	World CFrame of Rival Factory island `index`'s island-local frame (AttackConfig.Rivals): front
	edge midpoint of its base, +Z away from the hub, the island centre Radius studs out on the
	rival's bearing.
	@param index number — 1..#Rivals.List
	@return CFrame
	Example: AttackGeometry.rivalFrame(1) * Vector3.new(0, 0, 35) -- island 1 centre
]]
function AttackGeometry.rivalFrame(index: number): CFrame
	local rival = assert(RIVALS.List[index], "AttackGeometry: bad rival")
	return CFrame.Angles(0, math.rad(rival.bearing), 0) * CFrame.new(0, RIVALS.BaseY, RIVALS.Radius - RIVALS.Centre.Z)
end

-- A silo index clamped to the authored list.
local function siloIndex(silo: unknown): number
	local count = #AttackGeometry.layout().launchPoints
	if type(silo) == "number" and silo == silo then
		return math.clamp(math.floor(silo), 1, count)
	end
	return 1
end

--[[
	World CFrame of a silo mouth on a plot (+Y up).
	@param plot number — 1..8
	@param silo number — 1..3 (clamped)
	@return CFrame
]]
function AttackGeometry.launchCFrame(plot: number, silo: number): CFrame
	local index = assert(plotIndex(plot), "AttackGeometry: bad plot")
	return WorldLayout.slotToWorld(index, AREA, AttackGeometry.layout().launchPoints[siloIndex(silo)])
end

-- World position of a silo mouth.
function AttackGeometry.launchPoint(plot: number, silo: number): Vector3
	return AttackGeometry.launchCFrame(plot, silo).Position
end

--[[
	Number of impact points of a target slot (the server picks 1..count per nuke).
	@param slot number? — target slot (nil / a plot = the plot list)
	@return number
]]
function AttackGeometry.impactCount(slot: number?): number
	if AttackGeometry.rivalOfSlot(slot) ~= nil then
		return #RIVALS.ImpactPoints
	end
	return #GEOMETRY.ImpactPoints
end

--[[
	World position of impact point `index` on a target slot (plot ground, or the rival's floor).
	@param slot number — 1..slotCount()
	@param index number — 1..impactCount(slot) (clamped)
	@return Vector3
]]
function AttackGeometry.impactPoint(slot: number, index: number): Vector3
	local s = assert(slotIndex(slot), "AttackGeometry: bad slot")
	local rivalIndex = AttackGeometry.rivalOfSlot(s)
	local points = if rivalIndex ~= nil then RIVALS.ImpactPoints else GEOMETRY.ImpactPoints
	local i = if type(index) == "number" and index == index then math.clamp(math.floor(index), 1, #points) else 1
	if rivalIndex ~= nil then
		local point = points[i]
		return AttackGeometry.rivalFrame(rivalIndex) * Vector3.new(point.X, RIVALS.List[rivalIndex].floor, point.Z)
	end
	return WorldLayout.plotOrigin(s) * points[i]
end

--[[
	Owner R50 aiming: how many aimable areas a target slot has (a plot's 10 areas, a Rival
	Factory's sections).
	@param slot number
	@return number
]]
function AttackGeometry.areaCount(slot: number): number
	if AttackGeometry.rivalOfSlot(slot) ~= nil then
		return #RIVALS.Sections
	end
	return WorldLayout.AreaCount
end

-- A finite number clamped to [-limit, limit] (0 for junk), for scatter offsets.
local function offset(value: unknown, limit: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return math.clamp(value, -limit, limit)
end

--[[
	World point of an AIMED impact: the area's centre + the scatter offset (sx, sz), clamped so it
	stays inside the aimed area. Plot areas: slot-local centre (0, 0, 35) of area `area`'s slot.
	Rival sections: the section centre on the rival's floor, offsets scaled by RivalScatterScale's
	clamp (the section half-extent minus 4 studs).
	@param slot number — target slot
	@param area number — 1..areaCount(slot) (clamped)
	@param sx number, sz number — scatter offset in studs (slot / island-local X and Z)
	@return Vector3
	Example: AttackGeometry.aimPoint(3, 5, 4, -6) -- plot 3, area 5, 4 studs right, 6 toward the road
]]
function AttackGeometry.aimPoint(slot: number, area: number, sx: number, sz: number): Vector3
	local s = assert(slotIndex(slot), "AttackGeometry: bad slot")
	local count = AttackGeometry.areaCount(s)
	local a = if type(area) == "number" and area == area then math.clamp(math.floor(area), 1, count) else 1
	local rivalIndex = AttackGeometry.rivalOfSlot(s)
	if rivalIndex ~= nil then
		local section = RIVALS.Sections[a]
		local x = offset(sx, math.max(section.half.X - 4, 0))
		local z = offset(sz, math.max(section.half.Z - 4, 0))
		return AttackGeometry.rivalFrame(rivalIndex)
			* Vector3.new(section.centre.X + x, RIVALS.List[rivalIndex].floor, section.centre.Z + z)
	end
	local aim = AttackConfig.Aim
	return WorldLayout.slotPointToWorld(s, a, Vector3.new(offset(sx, aim.ClampX), 0, 35 + offset(sz, aim.ClampZ)))
end

--[[
	The impact point a NukeFlight describes: the aimed point when `area` >= 1 (owner R50), else the
	legacy impact index (admin test nukes).
	@param slot number, impact number, area number?, sx number?, sz number?
	@return Vector3
]]
function AttackGeometry.targetPoint(slot: number, impact: number, area: number?, sx: number?, sz: number?): Vector3
	if type(area) == "number" and area >= 1 then
		return AttackGeometry.aimPoint(slot, area, sx or 0, sz or 0)
	end
	return AttackGeometry.impactPoint(slot, impact)
end

local TOWERS = AttackConfig.Towers

--[[
	A valid defence tower slot index (owner R80, 1..#AttackConfig.Towers.Slots), else nil. Tower 0
	is the Area 7 Feature pad's HQ tower (towerMount / muzzle without a tower argument).
]]
local function towerIndex(tower: unknown): number?
	if type(tower) == "number" and tower % 1 == 0 and tower >= 1 and tower <= #TOWERS.Slots then
		return tower
	end
	return nil
end
AttackGeometry.validTower = towerIndex

--[[
	World CFrame of defence tower slot `tower`'s ground centre on a plot (+Y up; plot-local `at` on
	the island ground just outside the plot's side curb; the tower's barrels face the hub at rest,
	the plot frame's -Z).
	@param plot number — 1..PlotCount
	@param tower number — 1..#AttackConfig.Towers.Slots
	@return CFrame
	Example: AttackGeometry.towerSlotCFrame(3, 1) -- plot 3's Silo Tower spot
]]
function AttackGeometry.towerSlotCFrame(plot: number, tower: number): CFrame
	local p = assert(plotIndex(plot), "AttackGeometry: bad plot")
	local index = assert(towerIndex(tower), "AttackGeometry: bad tower slot")
	return WorldLayout.plotToWorld(p, CFrame.new(TOWERS.Slots[index].at))
end

--[[
	World CFrame of an AA turret mount on a target slot (+Y up, turret default facing -Z): the
	Area 7 layout's mount on a plot (the HQ tower), the top of the rival's A7_AATower plinth on an
	island, or — with `tower` >= 1 on a PLOT — that defence tower slot's ground centre (owner R80).
	@param slot number — target slot
	@param tower number? — nil / 0 = the HQ tower; 1..#Towers.Slots = a defence slot (plots only;
	                       ignored on a rival island, which has one tower)
	@return CFrame
]]
function AttackGeometry.towerMount(slot: number, tower: number?): CFrame
	local s = assert(slotIndex(slot), "AttackGeometry: bad slot")
	local rivalIndex = AttackGeometry.rivalOfSlot(s)
	if rivalIndex ~= nil then
		local rivalTower = RIVALS.List[rivalIndex].tower
		return AttackGeometry.rivalFrame(rivalIndex) * CFrame.new(rivalTower + Vector3.new(0, RIVALS.TowerMountY, 0))
	end
	if towerIndex(tower) ~= nil then
		return AttackGeometry.towerSlotCFrame(s, tower :: number)
	end
	return WorldLayout.slotToWorld(s, AREA, AttackGeometry.layout().aaTowerMount)
end

--[[
	World position of a turret muzzle (interceptors start here; range is measured from here): the
	HQ / rival tower's MuzzleHeight above its mount, a defence slot tower's Towers.MuzzleHeight
	above its ground centre (no plinth under slot towers).
	@param slot number — target slot
	@param tower number? — as towerMount
	@return Vector3
]]
function AttackGeometry.muzzle(slot: number, tower: number?): Vector3
	local height = if towerIndex(tower) ~= nil and AttackGeometry.rivalOfSlot(slot) == nil
		then TOWERS.MuzzleHeight
		else GEOMETRY.MuzzleHeight
	return (AttackGeometry.towerMount(slot, tower) * CFrame.new(0, height, 0)).Position
end

-- World position of the Attack Console prompt on a plot.
function AttackGeometry.consolePrompt(plot: number): Vector3
	local p = assert(plotIndex(plot), "AttackGeometry: bad plot")
	return WorldLayout.slotPointToWorld(p, AREA, AttackGeometry.layout().consolePrompt)
end

--[[
	World position of the "Upgrade AA" prompt at the foot of the AA tower (ground + 3 studs under
	the turret mount, so it is reachable whatever the tower's height).
	@param plot number
	@return Vector3
]]
function AttackGeometry.towerPrompt(plot: number): Vector3
	local p = assert(plotIndex(plot), "AttackGeometry: bad plot")
	local mount = AttackGeometry.layout().aaTowerMount.Position
	return WorldLayout.slotPointToWorld(p, AREA, Vector3.new(mount.X, 3, mount.Z - 6))
end

--[[
	World CFrame (ground centre) + size of the shield dome over a whole plot / rival island.
	@param slot number
	@return (CFrame, Vector3)
]]
function AttackGeometry.shield(slot: number): (CFrame, Vector3)
	local s = assert(slotIndex(slot), "AttackGeometry: bad slot")
	local rivalIndex = AttackGeometry.rivalOfSlot(s)
	if rivalIndex ~= nil then
		local centre = RIVALS.ShieldCentre + Vector3.new(0, RIVALS.List[rivalIndex].floor, 0)
		return AttackGeometry.rivalFrame(rivalIndex) * CFrame.new(centre), RIVALS.ShieldSize
	end
	return WorldLayout.plotToWorld(s, CFrame.new(GEOMETRY.ShieldCentre)), GEOMETRY.ShieldSize
end

--[[
	World position of a target's centre (plot middle / island centre).
	@param slot number
	@return Vector3
]]
function AttackGeometry.plotCentre(slot: number): Vector3
	local s = assert(slotIndex(slot), "AttackGeometry: bad slot")
	local rivalIndex = AttackGeometry.rivalOfSlot(s)
	if rivalIndex ~= nil then
		return AttackGeometry.rivalFrame(rivalIndex) * RIVALS.Centre
	end
	return WorldLayout.plotOrigin(s) * Vector3.new(0, 0, WorldLayout.PlotLength * 0.5)
end

--[[
	World CFrame of a target's frame origin (+Z away from the hub on plots and islands alike), so
	`origin.LookVector` always points toward the hub.
	@param slot number
	@return CFrame
]]
function AttackGeometry.plotOrigin(slot: number): CFrame
	local s = assert(slotIndex(slot), "AttackGeometry: bad slot")
	local rivalIndex = AttackGeometry.rivalOfSlot(s)
	if rivalIndex ~= nil then
		return AttackGeometry.rivalFrame(rivalIndex)
	end
	return WorldLayout.plotOrigin(s)
end

--[[
	The legacy whole-plot picker view over a slot (owner R133: the picker camera itself now uses
	Shared/Attack/PickerFrame for plots; this stays the Rival island view and the default stream
	point when a plot's built areas are unknown). It looks at `focus` from `eye`, which sits `back` studs
	toward the hub and `height` studs up (plots: AttackConfig.Client.PickerFocus / PickerBack /
	PickerHeight; islands: the island centre and Rivals.PickerBack / PickerHeight, closer since an
	island is much smaller than a plot).
	@param slot number
	@return (Vector3, Vector3) — eye, focus (world)
	Example: local eye, focus = AttackGeometry.pickerView(9); camera.CFrame = CFrame.lookAt(eye, focus)
]]
function AttackGeometry.pickerView(slot: number): (Vector3, Vector3)
	local origin = AttackGeometry.plotOrigin(slot)
	local rivalIndex = AttackGeometry.rivalOfSlot(slot)
	local client = AttackConfig.Client
	local focus = if rivalIndex ~= nil then origin * RIVALS.Centre else origin * client.PickerFocus
	local back = if rivalIndex ~= nil then RIVALS.PickerBack else client.PickerBack
	local height = if rivalIndex ~= nil then RIVALS.PickerHeight else client.PickerHeight
	-- Toward the hub = frame-local -Z = origin.LookVector.
	return focus + origin.LookVector * back + Vector3.new(0, height, 0), focus
end

--[[
	The flight of one nuke from its indices (what NukeFlight carries): attacker plot + silo,
	target SLOT (a plot or a Rival island) + impact point. The server builds it at launch; clients
	rebuild it identically (passing the published duration so rounding can never desynchronise
	the arc).
	@param fromPlot number, silo number, toPlot number (target slot), impact number
	@param duration number? — the published flight seconds (clients)
	@return FlightMath.Flight
	Example: local flight = AttackGeometry.flight(1, 2, 5, 3)
]]
function AttackGeometry.flight(
	fromPlot: number,
	silo: number,
	toPlot: number,
	impact: number,
	duration: number?
): FlightMath.Flight
	return FlightMath.build(
		AttackGeometry.launchPoint(fromPlot, silo),
		AttackGeometry.impactPoint(toPlot, impact),
		duration
	)
end

export type FlightIndices = {
	fromPlot: number,
	silo: number,
	toPlot: number, -- target slot
	impact: number, -- legacy impact index (used when area < 1)
	area: number?, -- owner R50 aimed area / rival section (0 / nil = legacy impact)
	sx: number?, -- scatter offsets (studs)
	sz: number?,
	duration: number?, -- the published flight seconds (clients)
}

--[[
	The flight of one nuke from everything NukeFlight carries (aim-aware): the server builds it at
	launch, FlightRenderer / LaunchCam rebuild it identically.
	@param data FlightIndices
	@return FlightMath.Flight
	Example: local flight = AttackGeometry.flightOf({ fromPlot = 1, silo = 1, toPlot = 5, impact = 1, area = 4, sx = 3, sz = -2 })
]]
function AttackGeometry.flightOf(data: FlightIndices): FlightMath.Flight
	return FlightMath.build(
		AttackGeometry.launchPoint(data.fromPlot, data.silo),
		AttackGeometry.targetPoint(data.toPlot, data.impact, data.area, data.sx, data.sz),
		data.duration
	)
end

-- Clears the cached layout (tests / hot reload).
function AttackGeometry.resetCache()
	cached = nil
end

return AttackGeometry
