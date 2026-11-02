--!strict
--[[
	LuckyButtonLogic — the PURE rules of the Lucky Buttons (owner R69; spec
	docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md §1). No Instances, no
	services, no clocks: callers pass the time, the random numbers and the player facts in, so the
	server (Server/Services/LuckyButtonService), the client (Client/LuckyButtons/LuckyButtonClient)
	and Lune (tests/lucky-buttons.luau) all run the same code.

	What lives here:
		allowed / eligible / roll   which kinds may spawn right now and the weighted pick
		                            (first button of the session free, caps, New Player Mode, owned
		                            passes, products that are not live, world pack, next pad)
		productOf / packFor         the MonetizationConfig key a paid kind prompts (per world)
		delay                       the spawn schedule (first 45–75 s, then 120–240 s, x multiplier)
		cashAmount                  the free cash burst (income x seconds, floored, never NaN)
		box / point / distance /    placement clearance in slot-local XZ (pads, producers,
		isClear / candidate         buildings, billboards, other buttons are oriented rectangles)
		slab / classify /           the REAL surface check from layout data (plot colliders are
		meshBounds / slotGeometry / CanQuery = false, so rays see nothing): walkable support under
		inside / spotOk             the button + clearance from every solid
		canClaim                    the server's claim check (world, expiry, distance, height;
		                            owner R122: an optional `radius` for the DEAL card's BUY)
		newDeal / dealStep /        owner R122: the paid button's DEAL card on the client (show on
		dealClosed                  walk-in, keep within KeepRadius, stay away after CLOSE / BUY)
		isAfk / blinking / label    small shared helpers
		readWire                    the client's validation of a server spawn payload
		arrow                       the on-screen edge arrow placement (safe area, touch zones)

	Security: the server decides everything (kinds, amounts, positions, claims); the client only
	validates what it is told before drawing it.

	Example:
		local kind = LuckyButtonLogic.roll(ctx, rng:NextNumber())
		local ok = LuckyButtonLogic.canClaim(button, { world = "main", now = t, root = rootPos })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LuckyButtonConfig = require(ReplicatedStorage.Shared.Config.LuckyButtonConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)

type Kind = LuckyButtonConfig.Kind
type KindId = LuckyButtonConfig.KindId

export type PromptType = "product" | "pass"

-- The facts a spawn roll needs (the server fills them from its services).
export type RollContext = {
	firstOfSession: boolean, -- no button spawned for this player this session yet
	live: number, -- live buttons of the player
	livePaid: number, -- live PAID buttons of the player
	newPlayerMode: boolean, -- New Player Mode (Robux off): free kinds only
	owns: (passKey: string) -> boolean, -- the player owns this game pass
	available: (key: string, kind: PromptType) -> boolean, -- the product / pass is live (id set, on sale)
	packKey: string?, -- that world's Large pack product key (nil = none)
	hasNextPad: boolean, -- the player has a next pad in this world (Skip Pad makes sense)
}

-- A spawn payload as the client receives it (LuckyButtons "spawn").
export type Wire = {
	id: string,
	kind: KindId,
	world: string,
	position: Vector3, -- ground point under the button (world space)
	born: number, -- server unix time
	expires: number, -- server unix time
	amount: number?, -- `cash`: the amount the claim grants (label)
	product: string?, -- paid: MonetizationConfig key (live price via PriceBook)
	productType: PromptType?,
}

-- An oriented rectangle in slot-local XZ: centre, half extents, cos / sin of its yaw.
export type Obstacle = { x: number, z: number, hx: number, hz: number, c: number, s: number }

-- What canClaim checks about a live button.
export type ClaimButton = { world: string, expires: number, position: Vector3 }
-- What canClaim checks about the claimer. `radius` (owner R122: the DEAL card's BUY) replaces
-- ClaimRadius as the horizontal reach, at most Deal.KeepRadius (ClaimSlack is still added).
export type ClaimAt = { world: string, now: number, root: Vector3?, radius: number? }

-- Owner R122: one paid button's DEAL card state on the client (dealStep / dealClosed).
export type DealState = {
	showing: boolean, -- the card is requested / on screen for this button
	dismissed: boolean, -- closed / bought: stays away until the player walks out of KeepRadius
}
export type DealAction = "show" | "hide"
-- Why a DEAL card ended (UI/Screens/DealCard reasons + the presenter's own "away" / "expired").
export type DealEnd = "buy" | "close" | "timeout" | "replaced" | "modal" | "hidden" | "away" | "expired"

-- A screen rectangle (design px).
export type Rect = { x: number, y: number, width: number, height: number }
-- Edge arrow input: the target's screen point (design px), whether it is in front of the camera,
-- the canvas size, the safe insets, the inset from the safe edge, rectangles to stay out of.
export type ArrowInput = {
	point: Vector2,
	inFront: boolean,
	canvas: Vector2,
	safe: { left: number, top: number, right: number, bottom: number },
	inset: number,
	avoid: { Rect },
	clearance: number,
}
-- Edge arrow result: the arrow centre (design px) and its rotation (degrees; 0 = pointing right).
export type ArrowPlace = { position: Vector2, rotation: number }

local LuckyButtonLogic = {}

-- `value` when it is a finite number, else nil.
local function finite(value: unknown): number?
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

-- A uniform in [0, 1) from any input (NaN / out of range clamp).
local function unit(r: number): number
	local value = finite(r) or 0
	return math.clamp(value, 0, 0.999999)
end

-- ── Kinds ────────────────────────────────────────────────────────────────────────────────────

--[[
	The MonetizationConfig key a kind prompts and whether it is a product or a pass (nil for free
	kinds, or for "pack" when the world has no Large pack).
	@param kind    a Kind
	@param packKey that world's Large pack key (RollContext.packKey)
	@return (key?, promptType?)
	Example: LuckyButtonLogic.productOf(LuckyButtonConfig.byId("pass2x"), nil) --> "DoubleCash", "pass"
]]
function LuckyButtonLogic.productOf(kind: Kind, packKey: string?): (string?, PromptType?)
	if not kind.paid then
		return nil, nil
	end
	if kind.pass ~= nil then
		return kind.pass, "pass"
	end
	if kind.rule == "worldPack" then
		if packKey == nil then
			return nil, nil
		end
		return packKey, "product"
	end
	if kind.product ~= nil then
		return kind.product, "product"
	end
	return nil, nil
end

--[[
	True when `kind` may spawn for the context (see the module header for every rule).
	@param kind a Kind
	@param ctx  RollContext
	@return boolean
	Example: LuckyButtonLogic.allowed(LuckyButtonConfig.byId("cash"), ctx) --> true (caps allowing)
]]
function LuckyButtonLogic.allowed(kind: Kind, ctx: RollContext): boolean
	if ctx.live >= LuckyButtonConfig.MaxLive or kind.weight <= 0 then
		return false
	end
	if not kind.paid then
		return true
	end
	-- Paid: never the session's first button, never in New Player Mode, one at a time.
	if ctx.firstOfSession or ctx.newPlayerMode or ctx.livePaid >= LuckyButtonConfig.MaxPaidLive then
		return false
	end
	local key, promptType = LuckyButtonLogic.productOf(kind, ctx.packKey)
	if key == nil or promptType == nil or not ctx.available(key, promptType) then
		return false -- COMING SOON / off sale / no pack in this world
	end
	if kind.rule == "notOwned" and ctx.owns(key) then
		return false
	end
	if kind.rule == "nextPad" and not ctx.hasNextPad then
		return false
	end
	return true
end

--[[
	Every kind allowed right now, in config order.
	@param ctx RollContext
	@return { Kind }
]]
function LuckyButtonLogic.eligible(ctx: RollContext): { Kind }
	local list: { Kind } = {}
	for _, kind in LuckyButtonConfig.Kinds do
		if LuckyButtonLogic.allowed(kind, ctx) then
			table.insert(list, kind)
		end
	end
	return list
end

--[[
	Weighted pick from `kinds` with one uniform number.
	@param kinds candidate kinds (positive weights)
	@param r     uniform in [0, 1) (clamped; NaN reads 0)
	@return Kind? (nil when `kinds` is empty)
	Example: LuckyButtonLogic.pick({ cash, boost2x }, 0.99) --> boost2x (the last band)
]]
function LuckyButtonLogic.pick(kinds: { Kind }, r: number): Kind?
	local total = 0
	for _, kind in kinds do
		total += math.max(0, kind.weight)
	end
	if total <= 0 then
		return nil
	end
	local target = unit(r) * total
	local running = 0
	for _, kind in kinds do
		running += math.max(0, kind.weight)
		if target < running then
			return kind
		end
	end
	return kinds[#kinds]
end

--[[
	Rolls the kind of the next button (nil = nothing may spawn now).
	@param ctx RollContext
	@param r   uniform in [0, 1)
	@return Kind?
]]
function LuckyButtonLogic.roll(ctx: RollContext, r: number): Kind?
	return LuckyButtonLogic.pick(LuckyButtonLogic.eligible(ctx), r)
end

--[[
	That world's Large cash pack: among the world's pack products (Nuke Town = kind "Cash" without
	a world; other worlds = kind "WorldCash" with `world == worldId`), the one whose key ends in
	"Large", else the one with the most incomeSeconds (ties → the smaller key). nil = none.
	@param worldId   the world
	@param products  MonetizationConfig.Products (key → def)
	@param mainWorld WorldsConfig.MAIN
	@return string?
	Example: LuckyButtonLogic.packFor("dino", MonetizationConfig.Products, "main") --> "BonesLarge"
]]
function LuckyButtonLogic.packFor(worldId: string, products: { [string]: any }, mainWorld: string): string?
	local best: string? = nil
	local bestScore = -math.huge
	for key, def in products do
		if type(key) ~= "string" or type(def) ~= "table" then
			continue
		end
		local ofWorld = if worldId == mainWorld
			then def.kind == "Cash" and def.world == nil
			else def.kind == "WorldCash" and def.world == worldId
		if not ofWorld then
			continue
		end
		-- A "...Large" key always wins; otherwise the biggest pack.
		local score = (if string.sub(key, -5) == "Large" then 1e12 else 0) + (finite(def.incomeSeconds) or 0)
		if score > bestScore or (score == bestScore and best ~= nil and key < best) then
			best = key
			bestScore = score
		end
	end
	return best
end

-- ── Schedule / rewards ───────────────────────────────────────────────────────────────────────

--[[
	Seconds until the next roll: FirstDelay* for the first button in a world, Delay* after one
	ended; times the admin interval multiplier (clamped to its bounds).
	@param r          uniform in [0, 1)
	@param first      the first button since the player arrived on this plot
	@param multiplier admin interval multiplier (NaN / out of range → clamped, default 1)
	@return number seconds (> 0)
	Example: LuckyButtonLogic.delay(0.5, false, 1) --> 180
]]
function LuckyButtonLogic.delay(r: number, first: boolean, multiplier: number?): number
	local lo = if first then LuckyButtonConfig.FirstDelayMin else LuckyButtonConfig.DelayMin
	local hi = if first then LuckyButtonConfig.FirstDelayMax else LuckyButtonConfig.DelayMax
	local mult = math.clamp(finite(multiplier) or 1, LuckyButtonConfig.IntervalMin, LuckyButtonConfig.IntervalMax)
	return (lo + (hi - lo) * unit(r)) * mult
end

--[[
	The free cash burst: `seconds` of income per second, never under `floor` (the area's first pad
	cost) or 1; whole units; 0-safe and NaN-safe.
	@param incomePerSecond the world's income per second (automated + manual estimate)
	@param seconds         Kind.income (60)
	@param floor           minimum grant
	@return number (whole, ≥ 1)
	Example: LuckyButtonLogic.cashAmount(20, 60, 500) --> 1200
]]
function LuckyButtonLogic.cashAmount(incomePerSecond: number, seconds: number, floor: number): number
	local ips = math.max(0, finite(incomePerSecond) or 0)
	local secs = math.max(0, finite(seconds) or 0)
	local minimum = math.max(1, finite(floor) or 1)
	-- Cap far below 1e308 so a corrupt income never makes an unprintable grant.
	return math.floor(math.min(math.max(ips * secs, minimum), 1e300))
end

--[[
	True when the player has been inactive for AfkSeconds or more.
	Example: LuckyButtonLogic.isAfk(100, 400) --> true
]]
function LuckyButtonLogic.isAfk(lastActive: number, now: number): boolean
	local last, clock = finite(lastActive), finite(now)
	if last == nil or clock == nil then
		return true
	end
	return clock - last >= LuckyButtonConfig.AfkSeconds
end

--[[
	True while a button is in its last BlinkSeconds (and not yet expired).
	Example: LuckyButtonLogic.blinking(103, 108) --> true (5 s left)
]]
function LuckyButtonLogic.blinking(now: number, expires: number): boolean
	local clock, ends = finite(now), finite(expires)
	if clock == nil or ends == nil then
		return false
	end
	local left = ends - clock
	return left > 0 and left <= LuckyButtonConfig.BlinkSeconds
end

--[[
	The billboard label of a button: `cash` shows its amount in the world's currency
	("+$1.2K!" / "+1.2K Bones!"), every other kind its config label.
	@param kind     the Kind
	@param amount   `cash` amount (nil → the config label)
	@param currency the world's currency def ({ style = "money" | "count", name })
	@return string
	Example: LuckyButtonLogic.label(cashKind, 1200, { style = "money", name = "Cash" }) --> "+$1.2K!"
]]
function LuckyButtonLogic.label(
	kind: Kind,
	amount: number?,
	currency: { read style: string, read name: string }?
): string
	local value = finite(amount)
	if kind.id ~= "cash" or value == nil or value <= 0 then
		return kind.label
	end
	if currency == nil or currency.style == "money" then
		return `+{NumberFormat.money(value)}!`
	end
	return `+{NumberFormat.short(value)} {currency.name}!`
end

-- ── Placement ────────────────────────────────────────────────────────────────────────────────

--[[
	An oriented rectangle obstacle (slot-local XZ).
	@param x, z   centre
	@param hx, hz half extents along its own axes
	@param yaw    rotation about +Y (radians)
	@return Obstacle
]]
function LuckyButtonLogic.box(x: number, z: number, hx: number, hz: number, yaw: number): Obstacle
	return { x = x, z = z, hx = math.max(0, hx), hz = math.max(0, hz), c = math.cos(yaw), s = math.sin(yaw) }
end

--[[ A square obstacle around a point (half size `half`, axis aligned). ]]
function LuckyButtonLogic.point(x: number, z: number, half: number): Obstacle
	return LuckyButtonLogic.box(x, z, half, half, 0)
end

--[[
	Distance (studs, XZ) from a point to an obstacle's rectangle (0 when inside).
	Example: LuckyButtonLogic.distance(LuckyButtonLogic.point(0, 0, 1), 4, 0) --> 3
]]
function LuckyButtonLogic.distance(o: Obstacle, x: number, z: number): number
	-- Into the rectangle's frame: rotate the offset by -yaw (Roblox yaw: +X → (c, -s) in XZ).
	local dx, dz = x - o.x, z - o.z
	local lx = dx * o.c - dz * o.s
	local lz = dx * o.s + dz * o.c
	local ox = math.max(0, math.abs(lx) - o.hx)
	local oz = math.max(0, math.abs(lz) - o.hz)
	return math.sqrt(ox * ox + oz * oz)
end

--[[
	True when (x, z) keeps at least `clearance` studs from every obstacle.
	Example: LuckyButtonLogic.isClear(0, 30, { LuckyButtonLogic.point(0, 9, 3.5) }, 7) --> true
]]
function LuckyButtonLogic.isClear(x: number, z: number, obstacles: { Obstacle }, clearance: number): boolean
	for _, o in obstacles do
		if LuckyButtonLogic.distance(o, x, z) < clearance then
			return false
		end
	end
	return true
end

--[[
	A slot-local candidate point from two uniforms, `margin` inside the slot edges
	(x ∈ [-halfWidth + m, halfWidth - m], z ∈ [m, depth - m]).
	@return (x, z)
	Example: LuckyButtonLogic.candidate(0.5, 0.5, 6, 52, 70) --> 0, 35
]]
function LuckyButtonLogic.candidate(
	rx: number,
	rz: number,
	margin: number,
	halfWidth: number,
	depth: number
): (number, number)
	local m = math.max(0, finite(margin) or 0)
	local xSpan = math.max(0, halfWidth - m)
	local zLo, zHi = m, math.max(m, depth - m)
	return -xSpan + 2 * xSpan * unit(rx), zLo + (zHi - zLo) * unit(rz)
end

-- ── Slot geometry (the REAL surface check, from layout data) ────────────────────────────────
--[[
	Why data and not rays: every plot surface is CanQuery = false by design — MeshLibrary visual
	pieces are inert, and PlotBuilder's invisible colliders (the frame's Plot_Ground slab whose top
	is y = 0, building walls, props) are "never touched / queried by game code". So
	Workspace:Raycast / GetPartBoundsInRadius on a built plot see NOTHING. The colliders and props
	themselves are layout DATA (Tycoon/AreaLayouts + the world hub layout's plotFrame + MeshAssets
	bounds), so placement reads that data: a spot needs a walkable collider at ground level under it
	(support) and keeps Clearance from every solid (wall, prop, pad, producer, billboard, button).
]]

export type Geometry = {
	supports: { Obstacle }, -- walkable colliders whose top is at the ground plane (slot-local XZ)
	keepouts: { Obstacle }, -- pads / producer / billboards: Clearance (7 studs, spec §1.1)
	solids: { Obstacle }, -- walls, buildings, props standing on / above the ground: PropClearance
}

export type GeometryInput = {
	layout: any?, -- the area layout (Tycoon/AreaLayouts.get shape; slot-local)
	spots: any?, -- BillboardSpots entry of the area ({ desktop, device }, slot-local)
	frame: any?, -- the world's plot frame ({ collision, models }, PLOT-local) or nil
	toSlot: CFrame, -- plot-local → slot-local transform for this plot + area
	plotHalfWidth: number, -- the no-frame fallback ground (WorldLayout.PlotHalfWidth)
	plotLength: number, -- the no-frame fallback ground (WorldLayout.plotLength(world))
	meshes: { [string]: any }, -- MeshAssets (prop bounds by key)
	-- Extra slot-local keep-out boxes from other plot systems (added for the R90 Order Window, which
	-- owner R128 removed; no caller passes any today). Optional.
	keepouts: { { cf: CFrame, size: Vector3 } }?,
}

--[[
	A box's footprint and height range: an oriented XZ rectangle (exact for yaw-only boxes, the
	corners' axis-aligned bounds for tilted ones) plus its top / bottom Y.
	@param cf   box centre CFrame
	@param size box size
	@return (Obstacle, top, bottom)
]]
function LuckyButtonLogic.slab(cf: CFrame, size: Vector3): (Obstacle, number, number)
	local half = size / 2
	local top: number, bottom: number = -math.huge, math.huge
	local minX: number, maxX: number = math.huge, -math.huge
	local minZ: number, maxZ: number = math.huge, -math.huge
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local p: Vector3 = cf * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)
				local px: number, py: number, pz: number = p.X, p.Y, p.Z
				top = math.max(top, py)
				bottom = math.min(bottom, py)
				minX = math.min(minX, px)
				maxX = math.max(maxX, px)
				minZ = math.min(minZ, pz)
				maxZ = math.max(maxZ, pz)
			end
		end
	end
	if math.abs(cf.UpVector.Y) > 0.999 then
		-- Yaw only: the exact oriented rectangle (yaw from the right vector, Roblox Y rotation).
		local right = cf.RightVector
		local yaw = math.atan2(-right.Z, right.X)
		return LuckyButtonLogic.box(cf.Position.X, cf.Position.Z, half.X, half.Z, yaw), top, bottom
	end
	local cx: number = (minX + maxX) / 2
	local cz: number = (minZ + maxZ) / 2
	local hx: number = (maxX - minX) / 2
	local hz: number = (maxZ - minZ) / 2
	return LuckyButtonLogic.box(cx, cz, hx, hz, 0), top, bottom
end

--[[
	What a box is to a button: "support" (its top lies on the ground plane: walkable ground when it
	is a collider), "solid" (stands on / above the ground below HeadRoom: a wall, prop, building),
	or "ignore" (buried under the ground, or high overhead like an arch beam).
	@param top / bottom slot-local Y range
	Example: LuckyButtonLogic.classify(0, -4) --> "support"; classify(12, 0) --> "solid"
]]
function LuckyButtonLogic.classify(top: number, bottom: number): "support" | "solid" | "ignore"
	local tol = LuckyButtonConfig.GroundTolerance
	if top <= tol then
		return if top >= -tol then "support" else "ignore"
	end
	if bottom >= LuckyButtonConfig.HeadRoom then
		return "ignore"
	end
	return "solid"
end

--[[
	The bounding box of a MeshAssets model in its pivot frame (pieces: size + offset), or nil.
	@return (centre, size)?
]]
function LuckyButtonLogic.meshBounds(entry: any): (Vector3?, Vector3?)
	if type(entry) ~= "table" or type(entry.pieces) ~= "table" then
		return nil, nil
	end
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = -lo
	local any = false
	for _, piece in entry.pieces do
		if type(piece) == "table" and typeof(piece.size) == "Vector3" then
			local offset = if typeof(piece.offset) == "Vector3" then piece.offset else Vector3.zero
			lo = lo:Min(offset - piece.size / 2)
			hi = hi:Max(offset + piece.size / 2)
			any = true
		end
	end
	if not any then
		return nil, nil
	end
	return (lo + hi) / 2, hi - lo
end

--[[
	Builds an area slot's placement geometry from layout data (see the section header).
	Supports: colliders whose top is at the ground plane (the frame's ground slab, flat lots); the
	no-frame fallback is the whole plot ground. Solids: pads (PadHalf, also when unbought), the
	producer (anchor + click box), every collider / boxed prop / MeshAssets piece of the area
	(bought or not: nothing ever builds in on top of a button), billboard spots, the frame's
	colliders (fences, walls).
	@param input GeometryInput
	@return Geometry
]]
function LuckyButtonLogic.slotGeometry(input: GeometryInput): Geometry
	local supports: { Obstacle } = {}
	local keepouts: { Obstacle } = {}
	local solids: { Obstacle } = {}
	-- A collider (walkable support or solid) / a visual prop (solid only), slot-local.
	local function addBox(cf: CFrame, size: Vector3, collider: boolean)
		local rect, top, bottom = LuckyButtonLogic.slab(cf, size)
		local class = LuckyButtonLogic.classify(top, bottom)
		if class == "support" and collider then
			table.insert(supports, rect)
		elseif class == "solid" then
			table.insert(solids, rect)
		end
	end
	-- A prop model entry: its explicit box, else EACH MeshAssets piece's own box (a whole-model
	-- bounding box would swallow a building's yard; per piece keeps walls, roofs and props tight
	-- while flat ground / lot pieces classify as "ignore").
	local function addModel(model: any)
		if type(model) ~= "table" or typeof(model.cf) ~= "CFrame" then
			return
		end
		local cf: CFrame = model.cf
		if typeof(model.box) == "Vector3" then
			addBox(cf, model.box, false)
			return
		end
		local entry = input.meshes[model.key or ""]
		if type(entry) ~= "table" or type(entry.pieces) ~= "table" then
			return
		end
		for _, piece in entry.pieces do
			if type(piece) == "table" and typeof(piece.size) == "Vector3" then
				local offset = if typeof(piece.offset) == "Vector3" then piece.offset else Vector3.zero
				addBox(cf * CFrame.new(offset), piece.size, false)
			end
		end
	end
	local function addBuild(build: any)
		if type(build) ~= "table" then
			return
		end
		for _, collision in build.collision or {} do
			if typeof(collision.cf) == "CFrame" and typeof(collision.size) == "Vector3" then
				addBox(collision.cf, collision.size, true)
			end
		end
		for _, model in build.models or {} do
			addModel(model)
		end
	end
	local layout = input.layout
	if type(layout) == "table" then
		for _, pad in layout.pads or {} do
			if typeof(pad) == "Vector3" then
				table.insert(keepouts, LuckyButtonLogic.point(pad.X, pad.Z, LuckyButtonConfig.PadHalf))
			end
		end
		local producer = layout.producer
		if type(producer) == "table" then
			if typeof(producer.anchor) == "Vector3" then
				table.insert(keepouts, LuckyButtonLogic.point(producer.anchor.X, producer.anchor.Z, 2))
			end
			local click = producer.click
			if type(click) == "table" and typeof(click.cf) == "CFrame" and typeof(click.size) == "Vector3" then
				table.insert(keepouts, (LuckyButtonLogic.slab(click.cf, click.size)))
			end
		end
		addBuild(layout.base)
		for _, build in layout.builds or {} do
			addBuild(build)
		end
	end
	-- Other systems' footprints (input.keepouts; none today): Clearance-kept like pads / producers.
	for _, box in input.keepouts or {} do
		if typeof(box.cf) == "CFrame" and typeof(box.size) == "Vector3" then
			table.insert(keepouts, (LuckyButtonLogic.slab(box.cf, box.size)))
		end
	end
	local spots = input.spots
	if type(spots) == "table" then
		for _, spot in { spots.desktop, spots.device } do
			if type(spot) == "table" and typeof(spot.position) == "Vector3" then
				table.insert(
					keepouts,
					LuckyButtonLogic.point(spot.position.X, spot.position.Z, LuckyButtonConfig.BillboardHalf)
				)
			end
		end
	end
	local frame = input.frame
	if type(frame) == "table" and type(frame.collision) == "table" then
		-- The plot frame's COLLIDERS only: its ground slab (support) and fences / walls (solids).
		-- Its visual pieces are the ground plates, borders and backdrop around the whole plot (one
		-- border piece's box spans the plot), and every frame prop that blocks has a collider.
		for _, collision in frame.collision do
			if typeof(collision.cf) == "CFrame" and typeof(collision.size) == "Vector3" then
				addBox(input.toSlot * collision.cf, collision.size, true)
			end
		end
	else
		-- No frame art: the primitive plot ground (PlotBuilder fallback: top y = 0, 4 thick).
		addBox(
			input.toSlot * CFrame.new(0, -2, input.plotLength / 2),
			Vector3.new(input.plotHalfWidth * 2, 4, input.plotLength),
			true
		)
	end
	return { supports = supports, keepouts = keepouts, solids = solids }
end

--[[
	True when (x, z) lies at least `margin` inside the rectangle (the button's whole base on it).
	Example: LuckyButtonLogic.inside(LuckyButtonLogic.point(0, 0, 10), 7, 0, 2.7) --> true
]]
function LuckyButtonLogic.inside(o: Obstacle, x: number, z: number, margin: number): boolean
	local dx, dz = x - o.x, z - o.z
	local lx = dx * o.c - dz * o.s
	local lz = dx * o.s + dz * o.c
	return math.abs(lx) <= o.hx - margin and math.abs(lz) <= o.hz - margin
end

--[[
	The placement verdict of a slot-local point: a walkable support under the whole button
	(ButtonRadius inside one support), Clearance from every keep-out (pads / producer / billboards)
	and from `extra` (the player's other buttons), PropClearance from every solid (no overlap with
	a wall / building / prop, plus a little air).
	@return (ok, reason?) — reason "gap" (no ground under it) | "blocked" (too close to something)
	Example: LuckyButtonLogic.spotOk(0, 35, geometry, {}) --> true
]]
function LuckyButtonLogic.spotOk(x: number, z: number, geometry: Geometry, extra: { Obstacle }?): (boolean, string?)
	local supported = false
	for _, support in geometry.supports do
		if LuckyButtonLogic.inside(support, x, z, LuckyButtonConfig.ButtonRadius) then
			supported = true
			break
		end
	end
	if not supported then
		return false, "gap"
	end
	if not LuckyButtonLogic.isClear(x, z, geometry.keepouts, LuckyButtonConfig.Clearance) then
		return false, "blocked"
	end
	if not LuckyButtonLogic.isClear(x, z, geometry.solids, LuckyButtonConfig.PropClearance) then
		return false, "blocked"
	end
	if extra ~= nil and not LuckyButtonLogic.isClear(x, z, extra, LuckyButtonConfig.Clearance) then
		return false, "blocked"
	end
	return true, nil
end

--[[
	Every valid spot of a slot on a `step`-stud grid (SlotMargin inside the slot edges), slot-local
	(the server caches this per slot, so a roll always succeeds while any free ground exists).
	@param geometry  the slot's Geometry
	@param step      grid step in studs (LuckyButtonConfig.GridStep)
	@param halfWidth / depth  the slot extent (WorldLayout.SlotHalfWidth / SlotDepth)
	@return { Vector2 } (x, z)
	Example: #LuckyButtonLogic.validSpots(geometry, 4, 52, 70) --> 37
]]
function LuckyButtonLogic.validSpots(geometry: Geometry, step: number, halfWidth: number, depth: number): { Vector2 }
	local list: { Vector2 } = {}
	local margin = LuckyButtonConfig.SlotMargin
	local stride = math.max(1, step)
	local x = -halfWidth + margin
	while x <= halfWidth - margin + 1e-9 do
		local z = margin
		while z <= depth - margin + 1e-9 do
			if LuckyButtonLogic.spotOk(x, z, geometry, nil) then
				table.insert(list, Vector2.new(x, z))
			end
			z += stride
		end
		x += stride
	end
	return list
end

-- ── Claims ───────────────────────────────────────────────────────────────────────────────────

--[[
	The server's claim check: same world, not expired, the character root within ClaimRadius +
	ClaimSlack studs horizontally and not far above / below.
	@param button ClaimButton
	@param at     ClaimAt (root = the character's HumanoidRootPart position, nil = no character)
	@return (ok, reason?) — reason "world" | "expired" | "character" | "far"
	Example: LuckyButtonLogic.canClaim(b, { world = "main", now = b.expires - 1, root = b.position }) --> true
]]
function LuckyButtonLogic.canClaim(button: ClaimButton, at: ClaimAt): (boolean, string?)
	if at.world ~= button.world then
		return false, "world"
	end
	local now, expires = finite(at.now), finite(button.expires)
	if now == nil or expires == nil or now >= expires then
		return false, "expired"
	end
	local root = at.root
	if root == nil then
		return false, "character"
	end
	local offset = root - button.position
	local flat = math.sqrt(offset.X * offset.X + offset.Z * offset.Z)
	-- Owner R122: the DEAL card's BUY reaches as far as the card stays up (never further).
	local reach = at.radius
	if type(reach) ~= "number" or reach ~= reach or reach <= 0 or reach > LuckyButtonConfig.Deal.KeepRadius then
		reach = LuckyButtonConfig.ClaimRadius
	end
	if flat ~= flat or flat > (reach :: number) + LuckyButtonConfig.ClaimSlack then
		return false, "far"
	end
	if offset.Y < -4 or offset.Y > LuckyButtonConfig.ClaimHeight then
		return false, "far"
	end
	return true, nil
end

-- ── DEAL card (owner R122) ────────────────────────────────────────────────────────────────────

--[[ A fresh DEAL card state for a newly drawn paid button. ]]
function LuckyButtonLogic.newDeal(): DealState
	return { showing = false, dismissed = false }
end

--[[
	One client step of a paid button's DEAL card (LuckyButtonConfig.Deal): show on walking into
	ClaimRadius, keep while within KeepRadius, hide past it; after a close / buy, stay away until
	the player has walked out of KeepRadius (then a walk-in shows it again).
	@param state the button's DealState (mutated)
	@param flat  the character's horizontal distance to the button (studs); nil = no character or
	             outside the claim height band (treated as far)
	@return "show" | "hide" | nil (what the presenter must do now)
	Example: LuckyButtonLogic.dealStep({ showing = false, dismissed = false }, 2) --> "show"
]]
function LuckyButtonLogic.dealStep(state: DealState, flat: number?): DealAction?
	local distance = if type(flat) == "number" and flat == flat then flat else math.huge
	local near = distance <= LuckyButtonConfig.Deal.KeepRadius
	if state.showing then
		if not near then
			state.showing = false
			return "hide"
		end
		return nil
	end
	if state.dismissed then
		if not near then
			state.dismissed = false
		end
		return nil
	end
	if distance <= LuckyButtonConfig.ClaimRadius then
		state.showing = true
		return "show"
	end
	return nil
end

--[[
	The DEAL card ended. The player's own choices (BUY, CLOSE) and anything that took the card away
	while they still stood there (a menu, another card) keep it away until they walk out and back
	in; walking away ("away") or a busy popup lane ("expired") does not.
	@param state  the button's DealState (mutated)
	@param reason why it ended
	Example: LuckyButtonLogic.dealClosed(state, "close") -- state.dismissed == true
]]
function LuckyButtonLogic.dealClosed(state: DealState, reason: DealEnd)
	state.showing = false
	state.dismissed = reason ~= "away" and reason ~= "expired"
end

-- ── Client wire validation ───────────────────────────────────────────────────────────────────

-- True for a finite Vector3.
local function finiteVector(value: unknown): Vector3?
	if typeof(value) ~= "Vector3" then
		return nil
	end
	local v = value :: Vector3
	if finite(v.X) == nil or finite(v.Y) == nil or finite(v.Z) == nil then
		return nil
	end
	return v
end

--[[
	True for a button id the server makes ("L" + digits, ≤ IdMaxLength).
	Example: LuckyButtonLogic.validId("L42") --> true
]]
function LuckyButtonLogic.validId(value: unknown): boolean
	if type(value) ~= "string" or #value > LuckyButtonConfig.IdMaxLength then
		return false
	end
	return string.match(value, `^{LuckyButtonConfig.IdPrefix}%d+$`) ~= nil
end

--[[
	Validates a "spawn" payload's button (client side: the server is trusted, but a malformed
	payload must never error or draw garbage).
	@param raw the `button` field of a LuckyButtons "spawn" message
	@return Wire? (nil when anything is malformed)
]]
function LuckyButtonLogic.readWire(raw: unknown): Wire?
	if type(raw) ~= "table" then
		return nil
	end
	local data = raw :: { [string]: unknown }
	local kind = LuckyButtonConfig.byId(data.kind)
	local position = finiteVector(data.position)
	local born, expires = finite(data.born), finite(data.expires)
	local world = data.world
	if
		not LuckyButtonLogic.validId(data.id)
		or kind == nil
		or position == nil
		or born == nil
		or expires == nil
		or expires <= born
		or type(world) ~= "string"
		or #world > 16
		or string.match(world, "^%w+$") == nil
	then
		return nil
	end
	local amount = finite(data.amount)
	if data.amount ~= nil and (amount == nil or amount < 0) then
		return nil
	end
	local product: string? = nil
	local productType: PromptType? = nil
	if data.product ~= nil then
		local key = data.product
		if type(key) ~= "string" or #key > 32 or string.match(key, "^[%w_]+$") == nil then
			return nil
		end
		if data.productType ~= "product" and data.productType ~= "pass" then
			return nil
		end
		product = key
		productType = data.productType :: PromptType
	end
	return {
		id = data.id :: string,
		kind = kind.id,
		world = world :: string,
		position = position,
		born = born,
		expires = expires,
		amount = amount,
		product = product,
		productType = productType,
	}
end

-- ── Edge arrow ───────────────────────────────────────────────────────────────────────────────

--[[
	Places the off-screen arrow: from the canvas centre toward the target (mirrored when it is
	behind the camera), clamped onto the safe rectangle shrunk by `inset`, then moved out of any
	`avoid` rectangle (+ clearance) toward the canvas centre (touch thumbstick / jump zones lift it,
	the top HUD stack pushes it down). Rotation points at the target (0° = right, 90° = down).
	@param input ArrowInput (design px)
	@return ArrowPlace
	Example: LuckyButtonLogic.arrow({ point = Vector2.new(5000, 500), inFront = true, ... })
		--> on the right edge, rotation ≈ 0
]]
function LuckyButtonLogic.arrow(input: ArrowInput): ArrowPlace
	local canvas = input.canvas
	local safe = input.safe
	local inset = math.max(0, input.inset)
	local left = safe.left + inset
	local top = safe.top + inset
	local right = math.max(left, canvas.X - safe.right - inset)
	local bottom = math.max(top, canvas.Y - safe.bottom - inset)
	local centre = Vector2.new((left + right) / 2, (top + bottom) / 2)
	local px = finite(input.point.X) or centre.X
	local py = finite(input.point.Y) or centre.Y
	local dir = Vector2.new(px, py) - centre
	if not input.inFront then
		dir = -dir -- a point behind the camera projects mirrored
	end
	if dir.Magnitude < 1e-3 then
		dir = Vector2.new(0, 1) -- straight behind: point down (turn around)
	end
	-- Scale the direction so it touches the rectangle's border.
	local halfW, halfH = (right - left) / 2, (bottom - top) / 2
	local scale = math.huge
	if math.abs(dir.X) > 1e-6 then
		scale = math.min(scale, halfW / math.abs(dir.X))
	end
	if math.abs(dir.Y) > 1e-6 then
		scale = math.min(scale, halfH / math.abs(dir.Y))
	end
	if scale == math.huge then
		scale = 0
	end
	local position = centre + dir * scale
	-- Out of the avoid zones: move vertically toward the canvas centre past the rectangle (a
	-- bottom touch zone lifts the arrow up, a top HUD zone pushes it down), staying in bounds.
	local clearance = math.max(0, input.clearance)
	for _ = 1, #input.avoid + 1 do
		local moved = false
		for _, rect in input.avoid do
			local inside = position.X >= rect.x - clearance
				and position.X <= rect.x + rect.width + clearance
				and position.Y >= rect.y - clearance
				and position.Y <= rect.y + rect.height + clearance
			if inside then
				local below = rect.y + rect.height / 2 >= centre.Y
				local y = if below then rect.y - clearance - 1 else rect.y + rect.height + clearance + 1
				position = Vector2.new(position.X, math.clamp(y, top, bottom))
				moved = true
			end
		end
		if not moved then
			break
		end
	end
	local rotation = math.deg(math.atan2(dir.Y, dir.X))
	return { position = position, rotation = rotation }
end

return table.freeze(LuckyButtonLogic)
