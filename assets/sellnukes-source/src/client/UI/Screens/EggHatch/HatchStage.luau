--!strict
--[[
	HatchStage — ONE egg slot of the hatch cinematic (owner R49): the real 3D egg in a
	ViewportFrame with the generic EggShards overlay (crack stages + shell chips), the pet that
	pops out (idled by PetModels.animator / PetAnim, owner R44), the soft light show behind it (halo discs + rays)
	and over it (flash), and the stud rarity banner underneath.

	Everything is posed from the PURE timeline (Client/Pets/HatchAnim) as a function of t, so the
	screen can skip anywhere and a model can be rebuilt mid-animation (a mesh finished loading)
	without losing its place.

	Pooled (owner R11 / performance rules):
		* The slot UI (viewport, halo, rays, flash, banner) is built ONCE with the screen and
		  reused for every hatch.
		* The egg + EggShards models are cached per slot and reused while the egg id stays the
		  same (a new hatch only resets poses / colours); the pet model is built once per hatch at
		  `prepare` (before the animation runs), never per frame.
		* `apply(t, dt)` only writes properties: CFrames of the moving pieces, Size only while the
		  squash / intro scale is off rest, transparency / colours only when they changed past a
		  small step. Hidden pieces cost nothing.
		* Low FX quality flies fewer shards (HatchAnimConfig.Tiers); the pet's idle handle
		  (PetModels.animator) steps at the per-tier viewport rate (PetAnimConfig.Tiers.ViewportHz),
		  Simple detail on Low.

	Piece contract (B8f art contract + tools/blender/models/egg_shards.py):
		egg       "ShellTop*" = the cap (flies off), every other piece = the cup (drops away)
		EggShards "Shard<n>" chips (tinted the egg's ShellTop colour), "Crack<k>" ink + "Crack<k>Glow"
		          Neon cores (tinted the pet's rarity colour) for stages k = 1..3
	Both models share the egg's pivot (ground point under the egg, front -Z).

	Connects to: Client/Pets/{HatchAnim, PetModels (egg / pet / fromKey / animator)}, Shared/Config/{HatchAnimConfig,
	PetAnimConfig, PetConfig, EggConfig, MeshAssets}, UI/{Create, Kit/StudUI, Widgets/StudWindow},
	Tycoon/Fx/FxQuality, UI/Screens/EggHatch/HatchRevealScreen (the only owner).

	Example:
		local stage = HatchStage.new(row, 1)
		stage.prepare({ eggId = "garage_egg", row = petRow, timeline = tl, tier = tier, lucky = false })
		stage.apply(t, dt)  -- every frame while the reveal plays
		stage.release()     -- the screen closed
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Parent.Create)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local FxQuality = require(script.Parent.Parent.Parent.Parent.Tycoon.Fx.FxQuality)
local HatchAnim = require(script.Parent.Parent.Parent.Parent.Pets.HatchAnim)
local HatchAnimConfig = require(ReplicatedStorage.Shared.Config.HatchAnimConfig)
local MeshAssets = require(ReplicatedStorage.Shared.Config.MeshAssets)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PetAnimConfig = require(ReplicatedStorage.Shared.Config.PetAnimConfig)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetModels = require(script.Parent.Parent.Parent.Parent.Pets.PetModels)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)

local Light = HatchAnimConfig.Light

-- Slot layout (design px). The egg's centre sits at EGG_CENTER inside the SLOT; the viewport is
-- much bigger than the slot so flying shell pieces travel before they reach its edge.
local SLOT = Vector2.new(420, 610)
local EGG_CENTER = Vector2.new(210, 228)
local VIEWPORT = 640
local HALO_SIZES = { 400, 310, 225, 150 }
local FLASH_SIZES = { 330, 230, 140 }
local RAY_SIZE = 470
local BANNER = Vector2.new(396, 170)
local BANNER_TOP = 428

-- Camera: looks at the egg's middle from the front (-Z), a little above, FIELD_OF_VIEW vertical.
local FIELD_OF_VIEW = 30
local LOOK_AT = Vector3.new(0, 1.45, 0)
local CAMERA_DISTANCE = 12.8
local CAMERA_PITCH = math.rad(8)

local AMBIENT = Color3.fromRGB(190, 190, 205)
local LIGHT = Color3.fromRGB(255, 250, 240)
local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)
local TAG_GOLD = Color3.fromRGB(255, 230, 90)

-- Property writes are skipped below these changes (no per-frame churn on a still screen).
local FADE_STEP = 0.01
local LIGHT_STEP = 0.015

local EGG_YAW = CFrame.Angles(0, math.rad(HatchAnimConfig.Egg.RestYaw), 0)
local PET_YAW = CFrame.Angles(0, math.rad(HatchAnimConfig.Pet.RestYaw), 0)

export type Row = {
	uid: string?,
	petId: string,
	rarity: string,
	slot: number?,
	pityForced: boolean?,
	isNew: boolean?,
	equipped: boolean?,
}

export type PrepareOptions = {
	eggId: string?, -- nil for a server grant (no egg)
	row: Row,
	timeline: HatchAnim.Timeline,
	tier: HatchAnimConfig.Tier,
	lucky: boolean, -- LuckyEggs pass (the odds the banner's "1 in N" uses)
	seed: number, -- PetAnim rhythm seed
}

export type Stage = {
	frame: Frame,
	center: () -> Vector2, -- egg centre in the slot, design px (confetti / sparkle origin)
	setScale: (scale: number) -> (), -- whole-slot UIScale (the single-hatch hero size)
	prepare: (options: PrepareOptions) -> (),
	apply: (t: number, dt: number) -> (),
	happy: () -> (),
	meshReady: (key: string) -> (),
	release: () -> (),
	Destroy: () -> (),
}

-- One posed piece: its rest CFrame relative to the model pivot (origin), rest size + transparency.
type Piece = {
	part: BasePart,
	rest: CFrame,
	size: Vector3,
	transparency: number,
	fade: number, -- the last fade written (0 = as authored, 1 = hidden)
}

type Shard = Piece & { outward: Vector3, center: Vector3 }

type EggRig = {
	model: Model,
	eggId: string,
	top: { Piece },
	bottom: { Piece },
	capPivot: Vector3,
	cupPivot: Vector3,
	meshes: boolean, -- built from loaded meshes (false = stud-box fallback: rebuild once loaded)
	topScale: Vector3, -- the last size scale written to the cap pieces
	bottomScale: Vector3, -- ... and to the cup pieces
}

type ShardRig = {
	model: Model,
	eggId: string,
	shards: { Shard },
	ink: { { Piece } }, -- per stage
	glow: { { Piece } }, -- per stage
	glowColor: Color3?, -- the last crack-glow colour written
	crackScale: Vector3, -- the last squash scale written to the crack pieces
}

type PetRig = {
	model: Model,
	petId: string,
	key: string,
	restScale: number,
	scale: number, -- the last ScaleTo written
	fade: number, -- the last cross-fade written (reduced motion)
	pieces: { Piece }, -- rest transparencies for the cross-fade
	-- PetModels.animator handle (PA2's self-stepped idle + happy spin), made once the pop settles.
	anim: PetModels.Animator?,
	settled: boolean,
	accum: number, -- seconds since the idle's last step (per-tier viewport rate)
}

local HatchStage = {}

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

-- A filled circle Frame (halo / flash disc), centred at `center`.
local function disc(name: string, size: number, center: Vector2, zIndex: number, parent: Instance): Frame
	return Create.new("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(center.X, center.Y),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Active = false,
		Selectable = false,
		ZIndex = zIndex,
		Parent = parent,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
	}) :: Frame
end

-- Records every BasePart of `model` (Root excluded) as a Piece at its current (rest) placement.
local function piecesOf(model: Model): { Piece }
	local list: { Piece } = {}
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") and item ~= model.PrimaryPart then
			table.insert(list, {
				part = item,
				rest = item.CFrame,
				size = item.Size,
				transparency = item.Transparency,
				fade = 0,
			})
		end
	end
	return list
end

-- Writes a piece's fade (0 = as authored .. 1 = hidden) when it changed past FADE_STEP.
local function setFade(piece: Piece, fade: number)
	local value = math.clamp(fade, 0, 1)
	if math.abs(value - piece.fade) < FADE_STEP and value ~= 0 and value ~= 1 then
		return
	end
	if value == piece.fade then
		return
	end
	piece.fade = value
	piece.part.Transparency = piece.transparency + (1 - piece.transparency) * value
end

-- Average rest position of a piece list (pivot of the cap's / a shard's spin).
local function centroid(list: { Piece }, fallback: Vector3): Vector3
	if #list == 0 then
		return fallback
	end
	local sum = Vector3.zero
	for _, piece in list do
		sum += piece.rest.Position
	end
	return sum / #list
end

-- The egg's ShellTop colour (what its broken chips look like): EggConfig override, else the mesh.
local function shellColor(egg: EggConfig.EggDef): Color3
	local override = if egg.colors ~= nil then egg.colors.ShellTop else nil
	if override ~= nil then
		return override
	end
	local entry = (MeshAssets :: any)[egg.model]
	local top = if type(entry) == "table" and type(entry.pieces) == "table" then entry.pieces.ShellTop else nil
	if type(top) == "table" and typeof(top.color) == "Color3" then
		return top.color
	end
	return egg.shell
end

-- "1 in 1,250" for a basis-point weight (nil when unknown).
local function oneIn(bp: number?): string?
	if bp == nil or bp <= 0 then
		return nil
	end
	local n = EggConfig.TotalBp / bp
	return `1 in {NumberFormat.commas(math.max(1, math.floor(n + 0.5)))}`
end

--------------------------------------------------------------------------------------------------
-- Stage
--------------------------------------------------------------------------------------------------

--[[
	Builds one slot (once per screen; pooled).
	@param parent      the slots row
	@param layoutOrder slot position (1..3, left to right)
	@return Stage handle
]]
function HatchStage.new(parent: Instance, layoutOrder: number): Stage
	local frame = Create.new("Frame", {
		Name = `Slot{layoutOrder}`,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(SLOT.X, SLOT.Y),
		LayoutOrder = layoutOrder,
		Visible = false,
		Parent = parent,
	}) :: Frame
	local slotScale = Create.new("UIScale", { Scale = 1, Parent = frame }) :: UIScale
	-- Everything that jitters (camera-shake look) lives in `shake`; the banner does not.
	local shake = Create.new("Frame", {
		Name = "Shake",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	}) :: Frame

	local halo: { Frame } = {}
	for index, size in HALO_SIZES do
		table.insert(halo, disc(`Halo{index}`, size, EGG_CENTER, 1, shake))
	end
	local rays = StudWindow.sunburst(shake, { size = UDim2.fromOffset(RAY_SIZE, RAY_SIZE), spin = false, zIndex = 2 })
	rays.Position = UDim2.fromOffset(EGG_CENTER.X, EGG_CENTER.Y)
	local rayBars: { Frame } = {}
	for _, child in rays:GetChildren() do
		if child:IsA("Frame") then
			child.ZIndex = 2
			table.insert(rayBars, child)
		end
	end

	local viewport = Create.new("ViewportFrame", {
		Name = "EggView",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(EGG_CENTER.X, EGG_CENTER.Y),
		Size = UDim2.fromOffset(VIEWPORT, VIEWPORT),
		BackgroundTransparency = 1,
		Ambient = AMBIENT,
		LightColor = LIGHT,
		LightDirection = Vector3.new(-0.4, -1, 0.6),
		Active = false,
		Selectable = false,
		ZIndex = 3,
		Parent = shake,
	}) :: ViewportFrame
	local camera = Instance.new("Camera")
	camera.FieldOfView = FIELD_OF_VIEW
	camera.CFrame = CFrame.lookAt(
		LOOK_AT + Vector3.new(0, math.sin(CAMERA_PITCH), -math.cos(CAMERA_PITCH)) * CAMERA_DISTANCE,
		LOOK_AT
	)
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local flash: { Frame } = {}
	for index, size in FLASH_SIZES do
		table.insert(flash, disc(`Flash{index}`, size, EGG_CENTER, 5, shake))
	end

	-- Rarity banner (stud panel) under the pet.
	local banner = Create.new("Frame", {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromOffset(SLOT.X / 2, BANNER_TOP),
		Size = UDim2.fromOffset(BANNER.X, BANNER.Y),
		Visible = false,
		ZIndex = 6,
		Parent = frame,
	}) :: Frame
	local bannerScale = Create.new("UIScale", { Scale = 1, Parent = banner }) :: UIScale
	local surface = StudWindow.surface(banner, "grey", { edge = 4, tile = 72, zIndex = 6 })
	local nameLabel = StudUI.text({
		text = "",
		textSize = 42,
		font = "title",
		scaled = true,
		size = UDim2.fromOffset(BANNER.X - 24, 52),
		position = UDim2.fromOffset(12, 10),
		zIndex = 7,
		parent = banner,
	})
	local rarityLabel = StudUI.text({
		text = "",
		textSize = 32,
		font = "shout",
		scaled = true,
		size = UDim2.fromOffset(BANNER.X - 24, 40),
		position = UDim2.fromOffset(12, 64),
		zIndex = 7,
		parent = banner,
	})
	local infoLabel = StudUI.text({
		text = "",
		textSize = 28,
		font = "number",
		scaled = true,
		size = UDim2.fromOffset(BANNER.X - 24, 38),
		position = UDim2.fromOffset(12, 110),
		zIndex = 7,
		parent = banner,
	})
	-- "NEW!" sticker on the banner's top-right corner (first discovery).
	local newTag = Create.new("Frame", {
		Name = "NewTag",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(BANNER.X - 38, -8),
		Size = UDim2.fromOffset(118, 48),
		Rotation = 9,
		Visible = false,
		ZIndex = 8,
		Parent = banner,
	}) :: Frame
	StudWindow.surface(newTag, "yellow", { edge = 3, tile = 48, zIndex = 8, highlight = false })
	StudUI.text({
		text = "NEW!",
		textSize = 32,
		font = "shout",
		size = UDim2.fromScale(1, 1),
		zIndex = 9,
		parent = newTag,
	})

	-- Per-hatch state.
	local timeline: HatchAnim.Timeline? = nil
	local tier: HatchAnimConfig.Tier = HatchAnimConfig.Tiers.High
	local rarityColor = WHITE
	local rarityDark = WHITE
	local egg: EggRig? = nil
	local overlay: ShardRig? = nil
	local pet: PetRig? = nil
	local currentEgg: EggConfig.EggDef? = nil
	local seed = layoutOrder
	local happyPending = false
	-- Last written light values (write-on-change).
	local last = {
		halo = -1,
		rayOpacity = -1,
		rayScale = -1,
		flash = -1,
		ambient = -1,
		jx = 0,
		jy = 0,
		banner = -1,
	}

	-- (Re)builds the egg model of `def` at the origin (cached while the egg id stays the same).
	local function buildEgg(def: EggConfig.EggDef)
		if egg ~= nil then
			egg.model:Destroy()
		end
		local model = PetModels.egg(def.id)
		model:PivotTo(CFrame.new())
		local top: { Piece } = {}
		local bottom: { Piece } = {}
		for _, piece in piecesOf(model) do
			if string.sub(piece.part.Name, 1, 8) == "ShellTop" then
				table.insert(top, piece)
			else
				table.insert(bottom, piece)
			end
		end
		egg = {
			model = model,
			eggId = def.id,
			top = top,
			bottom = bottom,
			capPivot = centroid(top, Vector3.new(0, 2.1, 0)),
			-- The cup tips about its base, a little above the ground.
			cupPivot = Vector3.new(0, 0.4, 0),
			meshes = PetModels.isMeshReady(def.model),
			topScale = Vector3.one,
			bottomScale = Vector3.one,
		}
		model.Parent = viewport
	end

	-- (Re)builds the EggShards overlay tinted for `def` (nil when the key is unknown / unbuilt).
	local function buildOverlay(def: EggConfig.EggDef)
		if overlay ~= nil then
			overlay.model:Destroy()
			overlay = nil
		end
		-- Only real meshes: the box fallback of curved shards / crack ribbons would be big boxes.
		PetModels.request(HatchAnimConfig.ShardsKey)
		if not PetModels.isMeshReady(HatchAnimConfig.ShardsKey) then
			return
		end
		local chip = shellColor(def)
		local colors: { [string]: Color3 } = {}
		for index = 1, HatchAnimConfig.ShardCount do
			colors[`Shard{index}`] = chip
		end
		local model = PetModels.fromKey(HatchAnimConfig.ShardsKey, colors)
		if model == nil then
			return
		end
		model:PivotTo(CFrame.new())
		local rig: ShardRig = {
			model = model,
			eggId = def.id,
			shards = {},
			ink = {},
			glow = {},
			glowColor = nil,
			crackScale = Vector3.one,
		}
		for stage = 1, HatchAnimConfig.CrackStages do
			rig.ink[stage] = {}
			rig.glow[stage] = {}
		end
		for _, piece in piecesOf(model) do
			local name = piece.part.Name
			local shardIndex = tonumber(string.match(name, "^Shard(%d+)$"))
			local crackStage = tonumber(string.match(name, "^Crack(%d+)$"))
			local glowStage = tonumber(string.match(name, "^Crack(%d+)Glow$"))
			if shardIndex ~= nil then
				local center = piece.rest.Position
				local shard: Shard = {
					part = piece.part,
					rest = piece.rest,
					size = piece.size,
					transparency = piece.transparency,
					fade = piece.fade,
					center = center,
					-- Flies straight out from the egg's vertical axis.
					outward = Vector3.new(center.X, 0, center.Z),
				}
				rig.shards[shardIndex] = shard
			elseif crackStage ~= nil and rig.ink[crackStage] ~= nil then
				table.insert(rig.ink[crackStage], piece)
			elseif glowStage ~= nil and rig.glow[glowStage] ~= nil then
				table.insert(rig.glow[glowStage], piece)
			end
		end
		overlay = rig
		model.Parent = viewport
	end

	-- Drops a pet rig: its idle handle first (it rests the pieces), then the model.
	local function dropPet(rig: PetRig)
		local anim = rig.anim
		if anim ~= nil then
			anim.Destroy()
			rig.anim = nil
		end
		rig.model:Destroy()
	end

	-- (Re)builds the pet model (hidden until the burst).
	local function buildPet(petId: string)
		local keep = pet
		if keep ~= nil then
			dropPet(keep)
		end
		local model = PetModels.pet(petId)
		model:PivotTo(PET_YAW)
		local scale = model:GetScale()
		pet = {
			model = model,
			petId = petId,
			key = PetModels.keyOf("pet", petId),
			restScale = scale,
			scale = scale,
			fade = 0,
			pieces = piecesOf(model),
			anim = nil,
			settled = false,
			accum = 0,
		}
		-- Parented at the burst (apply), so it never peeks through the shell.
		model.Parent = nil
	end

	-- Applies the egg (whole) pose: rocking about the egg's base with squash / stretch.
	local function poseWholeEgg(rig: EggRig, pose: HatchAnim.EggPose, base: CFrame): Vector3
		if not pose.visible then
			-- Not on stage yet (triple stagger) / gone: hide only, no CFrame or Size writes.
			for _, list in { rig.top, rig.bottom } do
				for _, piece in list do
					setFade(piece, 1)
				end
			end
			return Vector3.one
		end
		local s = Vector3.new(pose.sxz * pose.scale, pose.sy * pose.scale, pose.sxz * pose.scale)
		local resizeTop = (s - rig.topScale).Magnitude > 1e-4
		local resizeBottom = (s - rig.bottomScale).Magnitude > 1e-4
		rig.topScale, rig.bottomScale = s, s
		local fade = pose.fade
		for _, piece in rig.top do
			piece.part.CFrame = base * CFrame.new(piece.rest.Position * s) * piece.rest.Rotation
			if resizeTop then
				piece.part.Size = piece.size * s
			end
			setFade(piece, fade)
		end
		for _, piece in rig.bottom do
			piece.part.CFrame = base * CFrame.new(piece.rest.Position * s) * piece.rest.Rotation
			if resizeBottom then
				piece.part.Size = piece.size * s
			end
			setFade(piece, fade)
		end
		return s
	end

	-- After the burst: the cap flies (about its own centre), the cup sinks + tips + shrinks.
	local function poseOpenedEgg(rig: EggRig, tl: HatchAnim.Timeline, t: number, visible: boolean)
		local cap = HatchAnim.cap(tl, t)
		local capMove = EGG_YAW
			* CFrame.new(rig.capPivot + cap.offset)
			* CFrame.Angles(cap.rx, cap.ry, cap.rz)
			* CFrame.new(-rig.capPivot)
		local cup = HatchAnim.cup(tl, t)
		local cupMove = EGG_YAW * CFrame.new(rig.cupPivot + cup.offset) * CFrame.Angles(cup.rx, 0, 0)
		local resizeTop = (rig.topScale - Vector3.one).Magnitude > 1e-4
		local cupScale = Vector3.one * cup.scale
		local resizeBottom = (rig.bottomScale - cupScale).Magnitude > 1e-4
		rig.topScale, rig.bottomScale = Vector3.one, cupScale
		local capFade = if visible then cap.fade else 1
		for _, piece in rig.top do
			if capFade < 1 then
				piece.part.CFrame = capMove * piece.rest
			end
			if resizeTop then
				piece.part.Size = piece.size
			end
			setFade(piece, capFade)
		end
		local cupFade = if visible then cup.fade else 1
		for _, piece in rig.bottom do
			if cupFade < 1 then
				piece.part.CFrame = cupMove
					* CFrame.new((piece.rest.Position - rig.cupPivot) * cup.scale)
					* piece.rest.Rotation
			end
			if resizeBottom then
				piece.part.Size = piece.size * cup.scale
			end
			setFade(piece, cupFade)
		end
	end

	-- Cracks follow the whole egg; shards stay hidden until the burst, then fly.
	local function poseOverlay(tl: HatchAnim.Timeline, t: number, pose: HatchAnim.EggPose, base: CFrame, s: Vector3)
		local rig = overlay
		if rig == nil then
			return
		end
		-- The cracks squash / stretch with the shell (Size too, or they would poke out of it).
		local resize = (s - rig.crackScale).Magnitude > 1e-4
		rig.crackScale = s
		for stage = 1, HatchAnimConfig.CrackStages do
			local opacity = if pose.visible and not pose.opened then HatchAnim.crack(tl, t, stage) else 0
			for _, list in { rig.ink[stage], rig.glow[stage] } do
				for _, piece in list do
					if opacity > 0 then
						piece.part.CFrame = base * CFrame.new(piece.rest.Position * s) * piece.rest.Rotation
					end
					if resize then
						piece.part.Size = piece.size * s
					end
					setFade(piece, 1 - opacity)
				end
			end
		end
		-- The light leaking through: the Neon cores pulse between the rarity's dark and bright
		-- colour (quantised so a steady glow writes nothing).
		local glow = HatchAnim.crackGlow(tl, t)
		local color = rarityDark:Lerp(rarityColor, math.floor(glow * 20 + 0.5) / 20)
		if rig.glowColor ~= color then
			rig.glowColor = color
			for _, list in rig.glow do
				for _, piece in list do
					piece.part.Color = color
				end
			end
		end
		for index, shard in rig.shards do
			if index > tier.shards or not pose.opened then
				setFade(shard, 1)
			else
				local m = HatchAnim.shard(tl, t, index, shard.outward)
				if m.fade < 1 then
					shard.part.CFrame = EGG_YAW
						* CFrame.new(shard.center + m.offset)
						* CFrame.Angles(m.rx, m.ry, m.rz)
						* CFrame.new(-shard.center)
						* shard.rest
				end
				setFade(shard, if pose.visible then m.fade else 1)
			end
		end
	end

	-- The pet: spring pop out of the cup, then the PetAnim idle loop (+ happy spin).
	local function posePet(tl: HatchAnim.Timeline, t: number, dt: number)
		local rig = pet
		if rig == nil then
			return
		end
		local pose = HatchAnim.pet(tl, t)
		if not pose.visible then
			if rig.model.Parent ~= nil then
				rig.model.Parent = nil
			end
			return
		end
		if rig.model.Parent ~= viewport then
			rig.model.Parent = viewport
		end
		if tl.reduced then
			-- Cross-fade in place (no bounce, gentle idle only once fully shown).
			if rig.fade ~= pose.fade then
				rig.fade = pose.fade
				for _, piece in rig.pieces do
					setFade(piece, pose.fade)
				end
			end
			if pose.fade > 0 then
				return
			end
		elseif t < tl.popEnd then
			local scale = rig.restScale * pose.scale
			if math.abs(scale - rig.scale) > 1e-3 then
				rig.scale = scale
				rig.model:ScaleTo(scale)
			end
			rig.model:PivotTo(PET_YAW * CFrame.new(0, pose.y, 0))
			return
		end
		-- Settled: exact rest scale + pose, then the shared idle handle (PetModels.animator poses
		-- every piece relative to the Root and follows Model:GetScale()).
		local tierName = FxQuality.tier()
		if not rig.settled then
			rig.settled = true
			if rig.scale ~= rig.restScale then
				rig.scale = rig.restScale
				rig.model:ScaleTo(rig.restScale)
			end
			rig.model:PivotTo(PET_YAW)
			rig.anim = PetModels.animator(rig.model, { reduced = tl.reduced, simple = tierName == "Low", seed = seed })
			rig.accum = 0
			local anim = rig.anim
			if happyPending and anim ~= nil then
				happyPending = false
				anim.happy(0)
			end
		end
		local anim = rig.anim
		if anim == nil then
			return
		end
		-- Step at the device tier's viewport rate (an animated viewport re-renders every step).
		local petTier = PetAnimConfig.Tiers[tierName] or PetAnimConfig.Tiers.Mid
		rig.accum += dt
		if rig.accum < 1 / math.max(petTier.ViewportHz, 1) then
			return
		end
		anim.step(rig.accum)
		rig.accum = 0
	end

	-- Halo, rays, flash, viewport light, jitter, banner.
	local function poseLight(tl: HatchAnim.Timeline, t: number)
		local haloStrength = math.floor(HatchAnim.halo(tl, t) * 50 + 0.5) / 50
		if haloStrength ~= last.halo then
			last.halo = haloStrength
			for _, ring in halo do
				ring.BackgroundTransparency = 1 - haloStrength * Light.HaloDiscOpacity
			end
		end
		local opacity, scale, rotation = HatchAnim.rays(tl, t)
		opacity = math.floor(opacity * 50 + 0.5) / 50
		if rays.Visible ~= (opacity > 0) then
			rays.Visible = opacity > 0
		end
		if opacity > 0 then
			rays.Rotation = rotation
			if math.abs(scale - last.rayScale) > 0.002 then
				last.rayScale = scale
				rays.Size = UDim2.fromOffset(RAY_SIZE * scale, RAY_SIZE * scale)
			end
		end
		if opacity ~= last.rayOpacity then
			last.rayOpacity = opacity
			for _, bar in rayBars do
				bar.BackgroundTransparency = 1 - opacity
			end
		end
		local flashOpacity = math.floor(HatchAnim.flash(tl, t) * 50 + 0.5) / 50
		if flashOpacity ~= last.flash then
			last.flash = flashOpacity
			for index, ring in flash do
				-- Inner discs stack brighter: a soft radial flash, never a white-out (R19).
				ring.BackgroundTransparency = 1 - flashOpacity * (0.45 + 0.2 * index) / 1.05
			end
		end
		local ambient = HatchAnim.ambient(tl, t)
		if math.abs(ambient - last.ambient) >= LIGHT_STEP or (ambient == 1 and last.ambient ~= 1) then
			last.ambient = ambient
			viewport.Ambient = BLACK:Lerp(AMBIENT, ambient)
			viewport.LightColor = BLACK:Lerp(LIGHT, 0.55 + 0.45 * ambient)
		end
		local dx, dy = 0, 0
		if tier.jitter then
			local jx: number, jy: number = HatchAnim.jitter(tl, t)
			dx = math.floor(jx + 0.5)
			dy = math.floor(jy + 0.5)
		end
		if dx ~= last.jx or dy ~= last.jy then
			last.jx, last.jy = dx, dy
			shake.Position = UDim2.fromOffset(dx, dy)
		end
		local pose = HatchAnim.banner(tl, t)
		if banner.Visible ~= pose.visible then
			banner.Visible = pose.visible
		end
		if pose.visible and pose.scale ~= last.banner then
			last.banner = pose.scale
			bannerScale.Scale = pose.scale
		end
	end

	-- Fills the banner for a pet row (`lucky`: the LuckyEggs odds the "1 in N" uses).
	local function fillBanner(row: Row, lucky: boolean, rarity: PetConfig.RarityDef?, timelineRank: number)
		local def = PetConfig.get(row.petId)
		nameLabel.Text = if def ~= nil then def.name else row.petId
		surface.setColor(if rarity ~= nil then rarity.ui :: any else "grey")
		local parts: { string } = { string.upper(row.rarity) }
		local beat = HatchAnimConfig.Rarity[timelineRank]
		local eggDef = currentEgg
		if beat ~= nil and beat.chance and eggDef ~= nil and type(row.slot) == "number" then
			local odds = EggConfig.oddsFor(eggDef, lucky)
			local chance = oneIn(odds[row.slot :: number])
			if chance ~= nil then
				table.insert(parts, chance)
			end
		end
		rarityLabel.Text = table.concat(parts, "  ·  ")
		local info: { string } = { `{PetConfig.formatBonus(if def ~= nil then def.cash else 0)} cash` }
		if row.pityForced then
			table.insert(info, "PITY!")
		end
		if row.equipped then
			table.insert(info, "EQUIPPED")
		end
		infoLabel.Text = table.concat(info, "  ")
		infoLabel.TextColor3 = if row.pityForced or row.equipped then TAG_GOLD else WHITE
		newTag.Visible = row.isNew == true
	end

	local handle: Stage
	handle = {
		frame = frame,
		center = function(): Vector2
			return EGG_CENTER * slotScale.Scale
		end,
		setScale = function(scale: number)
			slotScale.Scale = scale
		end,
		prepare = function(options: PrepareOptions)
			local tl = options.timeline
			timeline = tl
			tier = options.tier
			seed = options.seed
			happyPending = false
			local rarity = PetConfig.rarity(options.row.rarity)
			rarityColor = if rarity ~= nil then rarity.color else WHITE
			rarityDark = if rarity ~= nil then rarity.dark:Lerp(rarity.color, 0.35) else WHITE
			for _, ring in halo do
				ring.BackgroundColor3 = rarityColor
			end
			local flashTint = if tl.rank >= 3 then WHITE:Lerp(rarityColor, Light.FlashTint) else WHITE
			if tl.beat.gold then
				flashTint = WHITE:Lerp(HatchAnimConfig.Confetti.Gold[1], Light.FlashTint)
			end
			for _, ring in flash do
				ring.BackgroundColor3 = flashTint
			end
			local rayColor = if tl.beat.gold then HatchAnimConfig.Confetti.Gold[2] else rarityColor:Lerp(WHITE, 0.35)
			for _, bar in rayBars do
				bar.BackgroundColor3 = rayColor
			end
			-- Egg + overlay (cached per egg id; a grant shows no egg).
			local def = if options.eggId ~= nil then EggConfig.get(options.eggId) else nil
			currentEgg = def
			if def == nil or tl.granted then
				if egg ~= nil then
					egg.model.Parent = nil
				end
				if overlay ~= nil then
					overlay.model.Parent = nil
				end
			else
				-- Cached per egg id; a box-fallback egg whose meshes loaded meanwhile is rebuilt.
				local cached = egg
				if
					cached == nil
					or cached.eggId ~= def.id
					or (not cached.meshes and PetModels.isMeshReady(def.model))
				then
					buildEgg(def)
				end
				local rig = egg :: EggRig
				rig.model.Parent = viewport
				local current = overlay
				if current == nil or current.eggId ~= def.id then
					buildOverlay(def)
				else
					current.model.Parent = viewport
				end
			end
			buildPet(options.row.petId)
			fillBanner(options.row, options.lucky, rarity, tl.rank)
			-- Reset the write-on-change memory so the first apply writes everything.
			last.halo, last.rayOpacity, last.rayScale, last.flash, last.ambient, last.banner = -1, -1, -1, -1, -1, -1
			last.jx, last.jy = 0, 0
			shake.Position = UDim2.new()
			bannerScale.Scale = HatchAnimConfig.Banner.From
			banner.Visible = false
			frame.Visible = true
		end,
		apply = function(t: number, dt: number)
			local tl = timeline
			if tl == nil then
				return
			end
			local pose = HatchAnim.eggPose(tl, t)
			local base = EGG_YAW * CFrame.new(0, pose.y, 0) * CFrame.Angles(pose.lean, 0, pose.roll)
			local s = Vector3.one
			local rig = egg
			if rig ~= nil and rig.model.Parent ~= nil then
				if pose.opened then
					poseOpenedEgg(rig, tl, t, pose.visible)
				else
					s = poseWholeEgg(rig, pose, base)
				end
			end
			if overlay ~= nil and overlay.model.Parent ~= nil then
				poseOverlay(tl, t, pose, base, s)
			end
			posePet(tl, t, dt)
			poseLight(tl, t)
		end,
		happy = function()
			local rig = pet
			local anim = if rig ~= nil then rig.anim else nil
			if anim ~= nil then
				anim.happy(0)
			else
				happyPending = true
			end
		end,
		meshReady = function(key: string)
			local tl = timeline
			if tl == nil or not frame.Visible then
				return
			end
			local def = currentEgg
			if def ~= nil and not tl.granted and key == def.model then
				buildEgg(def)
				-- The overlay is posed relative to the egg; rebuild order keeps it on top.
			elseif def ~= nil and not tl.granted and key == HatchAnimConfig.ShardsKey then
				buildOverlay(def)
			else
				local current = pet
				if current ~= nil and key == current.key then
					-- A fresh model needs a fresh idle handle (made again when it settles).
					buildPet(current.petId)
				end
			end
		end,
		release = function()
			frame.Visible = false
			local current = pet
			if current ~= nil then
				dropPet(current)
				pet = nil
			end
			timeline = nil
		end,
		Destroy = function()
			if egg ~= nil then
				egg.model:Destroy()
				egg = nil
			end
			if overlay ~= nil then
				overlay.model:Destroy()
				overlay = nil
			end
			local current = pet
			if current ~= nil then
				dropPet(current)
				pet = nil
			end
			frame:Destroy()
		end,
	}
	return handle
end

HatchStage.Slot = SLOT
HatchStage.EggCenter = EGG_CENTER

return HatchStage
