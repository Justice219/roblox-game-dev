--!strict
--[[
	BillboardProps — PLOT-local boxes of the props other systems place in / beside a plot, for the
	producer billboard solver (owner R117: "watch the new nearby props when choosing beside-spots").
	Pure: config in, boxes out (no Instances), so the client (ProducerBillboards.sourcesOf), the
	audit (tests/billboard-clearance.luau via tests/fixtures/BillboardSources) and the spot
	generator (tools/billboards/generate-spots.luau) all see the same obstacles.

	Props (each read from its owner's config, so a move there moves the obstacle too):
		AA tower slots AttackConfig.Towers.Slots `at` (plot-local ground centre): the L5 tower's
		               square (FootprintHalf) up to MuzzleHeight + TowerHeadroom
		Mega Lever,    KineticConfig.Placement Lever / Jar (plot-local) with their model-local
		Tip Jar        footprint boxes (centre offset + size), standing on the ground
	Props far from a producer are dropped by the solver's ObstacleRadius anyway. (The R90 Order
	Window was a prop here until owner R128 removed the order system.)

	Connects to: Tycoon/BillboardPlacement (Box, Sources.props), Shared/Config/{AttackConfig,
	KineticConfig}, Tycoon/ProducerBillboards, tests/fixtures/BillboardSources.

	Example:
		local props = BillboardProps.boxes("main", WorldLayout.slotLocal, MeshAssets, 0.25)
		sources.props = props
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local BillboardPlacement = require(script.Parent.BillboardPlacement)
local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)

local BillboardProps = {}

-- Studs a slot tower reaches above its muzzle (the interceptor head / dish).
local TOWER_HEADROOM = 4

--[[
	Every prop box of one world, in PLOT space.
	@param worldId    WorldsConfig id ("main", "dino", ...) — every world shares the same props today
	@param slotLocal  the world's slot frame in plot space
	@param meshAssets Shared/Config/MeshAssets
	@param seeThrough Placement.SeeThrough
	(worldId / slotLocal / meshAssets / seeThrough only fed the per-world, slot-placed Order Window
	that owner R128 removed; the signature is kept so ProducerBillboards, the audit fixture and the
	spot generator stay unchanged and a future per-world prop can use them again.)
	@return { BillboardPlacement.Box } (a fresh list)
]]
function BillboardProps.boxes(
	_worldId: string,
	_slotLocal: (area: number) -> CFrame,
	_meshAssets: any,
	_seeThrough: number
): { BillboardPlacement.Box }
	local boxes: { BillboardPlacement.Box } = {}
	-- AA tower slots: the tower's square, standing on the ground at `at`.
	local towers = AttackConfig.Towers
	local towerHeight = towers.MuzzleHeight + TOWER_HEADROOM
	for _, slot in towers.Slots do
		table.insert(boxes, {
			cf = CFrame.new(slot.at + Vector3.new(0, towerHeight / 2, 0)),
			size = Vector3.new(towers.FootprintHalf * 2, towerHeight, towers.FootprintHalf * 2),
			label = `AATower.{slot.id}`,
		})
	end
	-- Mega Lever + Tip Jar: model-local footprint boxes, standing on the ground.
	local placement = KineticConfig.Placement
	local function footprint(at: CFrame, box: typeof(placement.LeverFootprint), label: string)
		table.insert(boxes, {
			cf = at * CFrame.new(box.center.X, box.size.Y / 2, box.center.Z),
			size = box.size,
			label = label,
		})
	end
	footprint(placement.Lever, placement.LeverFootprint, "Kinetic.MegaLever")
	footprint(placement.Jar, placement.JarFootprint, "Kinetic.TipJar")
	return boxes
end

return table.freeze(BillboardProps)
