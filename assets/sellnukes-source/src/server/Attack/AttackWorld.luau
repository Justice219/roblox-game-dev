--!strict
--[[
	AttackWorld — the server-built world objects of Attack mode:
		* client TEMPLATES in ReplicatedStorage.AttackTemplates (Nuke1..Nuke5, Interceptor, Puff):
		  built once at boot; clients clone them into pools to render flights locally;
		* the levelled AA TURRET on a defender's plot (on top of the A7_AATower build), swapped on
		  upgrade with the LEGO build-in (BuildIn tag + attributes, B6 BuildInController);
		* owner R80 DEFENCE TOWERS (one per AttackConfig.Towers slot, same AATower1..5 meshes, same
		  build-in) and the blue defence BUY PADS (tycoon BuyPad mesh + a walk-on Trigger) on the
		  free slots of a targetable plot;
		* the SHIELD DOME over a shielded plot;
		* the Attack Console PROXIMITY PROMPT on an attacker's plot (the client opens the target
		  picker when its owner triggers it; other players' clients disable it locally).

	Everything lives in Workspace.Plots.PlotN.Attack (Folder) — PlotBuilder.clear() only removes
	area Models, so this folder is managed here alone (clearPlot on release). `plot` arguments are
	AttackGeometry TARGET SLOTS: a slot past the plots is a Rival Factory island (owner R43), whose
	turret and dome live in Workspace.<Rivals.Folder>.<id>.Attack (RivalIslands creates the island
	folder; DefenseService drives the turret level and the shield cycle).

	Art: models come from MeshAssets via MeshLibrary (Blender meshes, primitive fallback while not
	uploaded). Keys that do not exist yet (B8f's Nuke1..5 / AATower1..5 / Interceptor / ShieldDome /
	NukePuff) fall back to the Area 7 silo nukes (A7_SiloNuke_*) where sensible, else to small
	stud-material primitives built here, so Attack mode is complete before every upload lands.
	Every visual piece is Anchored, CanCollide / CanQuery / CanTouch = false (zero physics cost).

	Connects to: World/{MeshLibrary, WorldMaterials, PlotBuilder}, Shared/Config/{AttackConfig,
	MeshAssets, BuildInConfig}, Shared/Attack/AttackGeometry, Server/Services/{AttackService,
	DefenseService}, Client/Attack/* (templates, tags).

	Example:
		AttackWorld.publishTemplates()                 -- once at Start (async)
		AttackWorld.setTurret(3, 2, buyer)             -- plot 3 shows an AA level 2 turret
		AttackWorld.setDome(3, true)
		AttackWorld.setConsolePrompt(3, player.UserId) -- or nil to remove
		AttackWorld.setTowerPrompt(3, player.UserId)   -- "Upgrade AA" → Defense screen
		AttackWorld.setTower(3, 1, 2, buyer)           -- owner R80: defence slot 1 at level 2
		AttackWorld.setDefensePad(3, 2, player.UserId, cost, onTouched)
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local BuildInConfig = require(ReplicatedStorage.Shared.Config.BuildInConfig)
local MeshAssets = require(ReplicatedStorage.Shared.Config.MeshAssets)
local MeshLibrary = require(script.Parent.Parent.World.MeshLibrary)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)
local WorldMaterials = require(script.Parent.Parent.World.WorldMaterials)

local AttackWorld = {}

local MODELS = AttackConfig.Models

-- Flight model length (studs, nose to tail) every nuke template is scaled to, per tier.
local NUKE_LENGTH = { 9, 10, 11, 12, 13.5 }
-- Candy body colour per nuke tier (fallback primitives + tint for tinted meshes).
local NUKE_COLORS = {
	Color3.fromRGB(232, 64, 56), -- red
	Color3.fromRGB(98, 214, 170), -- mint
	Color3.fromRGB(246, 246, 250), -- white
	Color3.fromRGB(150, 96, 220), -- purple
	Color3.fromRGB(255, 196, 36), -- gold
}
-- Area 7 silo nuke art reused as flight models until B8f's Nuke1..5 exist (tier → key).
local SILO_NUKES = { "A7_SiloNuke_Red", "A7_SiloNuke_Mint", "A7_SiloNuke_Gold", "A7_SiloNuke_Red", "A7_SiloNuke_Gold" }
local CORE_GREEN = Color3.fromRGB(110, 255, 90)
local SHIELD_COLOR = Color3.fromRGB(110, 200, 255)

local templateFolder: Folder? = nil

--------------------------------------------------------------------------------------------------
-- Primitive helpers
--------------------------------------------------------------------------------------------------

-- An anchored, physics-free visual Part with the stud material.
local function visualPart(name: string, size: Vector3, cf: CFrame, color: Color3, material: string?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.EnableFluidForces = false
	part.CastShadow = false
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	WorldMaterials.apply(part, material or "Studs")
	return part
end

-- A cylinder Part whose axis runs along +Y of `cf` (Roblox cylinders run along X).
local function cylinderY(
	name: string,
	diameter: number,
	height: number,
	cf: CFrame,
	color: Color3,
	material: string?
): Part
	local part = visualPart(
		name,
		Vector3.new(height, diameter, diameter),
		cf * CFrame.Angles(0, 0, math.pi / 2),
		color,
		material
	)
	part.Shape = Enum.PartType.Cylinder
	return part
end

-- Makes every BasePart under a model visual-only (no physics, no queries, no shadows).
local function visualOnly(model: Model)
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") then
			item.Anchored = true
			item.CanCollide = false
			item.CanQuery = false
			item.CanTouch = false
			item.CastShadow = false
		end
	end
end

-- Uniformly scales a model about its pivot so its height (Y extent) becomes `length`.
local function scaleToLength(model: Model, length: number)
	local _, size = model:GetBoundingBox()
	if size.Y > 0 then
		model:ScaleTo(model:GetScale() * (length / size.Y))
	end
end

--------------------------------------------------------------------------------------------------
-- Fallback models (code-built, stud material)
--------------------------------------------------------------------------------------------------

-- A cartoon nuke: pivot at the tail centre, nose along +Y, `length` studs long.
local function fallbackNuke(tier: number, length: number): Model
	local model = Instance.new("Model")
	local body = NUKE_COLORS[tier] or NUKE_COLORS[1]
	local width = length * 0.3
	local base = CFrame.new()
	cylinderY("Body", width, length * 0.62, base * CFrame.new(0, length * 0.4, 0), body).Parent = model
	cylinderY("Core", width * 1.06, length * 0.12, base * CFrame.new(0, length * 0.42, 0), CORE_GREEN, "Neon").Parent =
		model
	local nose = visualPart("Nose", Vector3.new(width, width, width), base * CFrame.new(0, length * 0.76, 0), body)
	nose.Shape = Enum.PartType.Ball
	nose.Parent = model
	for index = 0, 3 do
		local fin = visualPart(
			"Fin",
			Vector3.new(0.35, length * 0.26, width * 0.9),
			base * CFrame.Angles(0, index * math.pi / 2, 0) * CFrame.new(0, length * 0.14, width * 0.62),
			Color3.fromRGB(40, 42, 52)
		)
		fin.Parent = model
	end
	cylinderY("Tail", width * 0.62, length * 0.06, base * CFrame.new(0, length * 0.05, 0), Color3.fromRGB(40, 42, 52)).Parent =
		model
	model.WorldPivot = base
	return model
end

-- A small AA interceptor: pivot tail centre, nose +Y.
local function fallbackInterceptor(): Model
	local model = Instance.new("Model")
	cylinderY("Body", 0.7, 3, CFrame.new(0, 1.5, 0), Color3.fromRGB(246, 246, 250)).Parent = model
	local tip =
		visualPart("Tip", Vector3.new(0.7, 0.7, 0.7), CFrame.new(0, 3.1, 0), Color3.fromRGB(232, 64, 56), "Neon")
	tip.Shape = Enum.PartType.Ball
	tip.Parent = model
	model.WorldPivot = CFrame.new()
	return model
end

-- The confetti mushroom-cloud puff: stem + cap balls (the client scales / fades it).
local function fallbackPuff(): Model
	local model = Instance.new("Model")
	local green = Color3.fromRGB(150, 240, 110)
	local yellow = Color3.fromRGB(255, 226, 92)
	cylinderY("Stem", 6, 14, CFrame.new(0, 7, 0), yellow, "Smooth").Parent = model
	for index, offset in
		{ Vector3.new(0, 16, 0), Vector3.new(6, 14, 2), Vector3.new(-6, 14, -2), Vector3.new(2, 14, -6) }
	do
		local ball = visualPart(`Cap{index}`, Vector3.new(14, 11, 14), CFrame.new(offset), green, "Smooth")
		ball.Shape = Enum.PartType.Ball
		ball.Parent = model
	end
	model.WorldPivot = CFrame.new()
	return model
end

-- An AA turret of `level`: pivot at the mount (deck top), pieces Base / Turret / Barrel.
local function fallbackTurret(level: number): Model
	local model = Instance.new("Model")
	local scale = 1 + (level - 1) * 0.12
	local grey = Color3.fromRGB(92, 98, 112)
	local accent = NUKE_COLORS[level] or NUKE_COLORS[1]
	cylinderY("Base", 5 * scale, 1.6, CFrame.new(0, 0.8, 0), grey).Parent = model
	visualPart("Turret", Vector3.new(4.4, 3.2, 4.4) * scale, CFrame.new(0, 3.2 * scale, 0), accent).Parent = model
	-- Barrel: two tubes pointing up-forward (-Z) from the turret's hinge.
	local barrel = visualPart(
		"Barrel",
		Vector3.new(2.4 * scale, 1.2 * scale, 6 * scale),
		CFrame.new(0, 4.4 * scale, -2.6 * scale) * CFrame.Angles(math.rad(35), 0, 0),
		Color3.fromRGB(40, 42, 52)
	)
	barrel.Parent = model
	for index = 1, math.clamp(level, 1, 5) do
		-- One neon pip per level on the turret's back (readable from afar).
		visualPart(
			"Pip",
			Vector3.new(0.5, 0.5, 0.2),
			CFrame.new((index - 3) * 0.7 * scale, 3.4 * scale, 2.25 * scale),
			CORE_GREEN,
			"Neon"
		).Parent =
			model
	end
	model.WorldPivot = CFrame.new()
	-- The client aims the barrel relative to this resting elevation (degrees).
	model:SetAttribute("BarrelPitch", 35)
	return model
end

--------------------------------------------------------------------------------------------------
-- Templates (ReplicatedStorage.AttackTemplates)
--------------------------------------------------------------------------------------------------

-- A spawned MeshLibrary model if `key` exists, else nil (never errors on missing keys).
-- `deferred` (W1b boot order, owner R16): Background priority and never on WorldReady — for the
-- effect templates and the turrets / domes of Rival islands and admin test bots, never for a
-- player's own plot.
local function trySpawn(key: string, pivot: CFrame, tint: Color3?, deferred: boolean?): Model?
	if MeshAssets[key] == nil then
		return nil
	end
	local ok, model = pcall(function(): Model
		return MeshLibrary.spawn(key, nil, pivot, { tint = tint, castShadow = false, deferred = deferred == true })
	end)
	if ok then
		return model
	end
	warn(`[AttackWorld] {key} failed to spawn: {model}`)
	return nil
end

-- Builds one nuke template for `tier`: B8f art > Area 7 silo nuke art > primitive.
local function nukeTemplate(tier: number): Model
	local length = NUKE_LENGTH[tier] or NUKE_LENGTH[1]
	local model = trySpawn(MODELS.Nukes[tier], CFrame.new(), NUKE_COLORS[tier], true)
		or trySpawn(SILO_NUKES[tier], CFrame.new(), NUKE_COLORS[tier], true)
	if model ~= nil then
		scaleToLength(model, length)
	else
		model = fallbackNuke(tier, length)
	end
	local result = model :: Model
	result.Name = `Nuke{tier}`
	result:SetAttribute("Length", length)
	return result
end

--[[
	Builds every client template once (async: MeshLibrary yields while meshes load). The folder
	exists immediately; each model appears in it when ready (clients wait per name).
]]
function AttackWorld.publishTemplates()
	if templateFolder ~= nil then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = AttackConfig.TemplateFolder
	folder.Parent = ReplicatedStorage
	templateFolder = folder
	task.spawn(function()
		for tier = 1, AttackConfig.MaxLevel do
			local model = nukeTemplate(tier)
			visualOnly(model)
			model.Parent = folder
		end
		local interceptor = trySpawn(MODELS.Interceptor, CFrame.new(), nil, true) or fallbackInterceptor()
		interceptor.Name = "Interceptor"
		visualOnly(interceptor)
		interceptor.Parent = folder
		local puff = trySpawn(MODELS.Puff, CFrame.new(), nil, true) or fallbackPuff()
		puff.Name = "Puff"
		visualOnly(puff)
		puff.Parent = folder
	end)
end

--------------------------------------------------------------------------------------------------
-- Plot objects
--------------------------------------------------------------------------------------------------

-- The plot's Attack folder (created on demand), or nil for a bad plot index.
local function plotFolder(plot: number): Folder?
	-- A Rival Factory slot: Workspace.<Rivals.Folder>.<id>.Attack (the island folder is created by
	-- RivalIslands.start before DefenseService shows the rival's turret / dome).
	local rivalIndex = AttackGeometry.rivalOfSlot(plot)
	if rivalIndex ~= nil then
		local root = Workspace:FindFirstChild(AttackConfig.Rivals.Folder)
		local island = if root ~= nil then root:FindFirstChild(AttackConfig.Rivals.List[rivalIndex].id) else nil
		if island == nil then
			return nil
		end
		local existing = island:FindFirstChild(AttackConfig.PlotFolder)
		if existing ~= nil and existing:IsA("Folder") then
			return existing
		end
		local folder = Instance.new("Folder")
		folder.Name = AttackConfig.PlotFolder
		folder.Parent = island
		return folder
	end
	if AttackGeometry.validPlot(plot) == nil then
		return nil
	end
	local ok, model = pcall(PlotBuilder.getPlot, plot)
	if not ok or model == nil then
		return nil
	end
	local existing = model:FindFirstChild(AttackConfig.PlotFolder)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = AttackConfig.PlotFolder
	folder.Parent = model
	return folder
end

-- Async-build guard per plot + object: a newer request supersedes an older in-flight spawn.
local generations: { [string]: number } = {}
local function nextGeneration(key: string): number
	local value = (generations[key] or 0) + 1
	generations[key] = value
	return value
end

-- The folder child name of tower `tower` (0 = the HQ / rival turret, i = defence slot i).
local function towerName(tower: number): string
	return if tower >= 1 then `DefenseTower{tower}` else "AATurret"
end

--[[
	Shows AA tower `tower` of `level` on a target slot (0 removes it): tower 0 is the HQ turret on
	the Area 7 plinth (or a rival island's / test bot's turret), towers 1..#AttackConfig.Towers.Slots
	are the owner R80 defence slots on a plot. A `buyer` makes it build in with the LEGO fly-in
	(translucent → solid: purchase / upgrade / coming back after a Rebirth); without one it simply
	appears (restore / join). Async (mesh loading); a newer call for the same tower wins.
	Every tower model carries attributes Plot, Tower, Level and the Turret tag (the client aims
	it while it fires and puts the UPGRADE billboard on the owner's own towers).
	@param plot number — target slot
	@param tower number — 0 = HQ / rival turret; 1.. = defence slot (plots only)
	@param level number — 0..MaxLevel
	@param buyer Player?
	@param deferred boolean? — Background mesh priority (rival islands / test bots)
	Example: AttackWorld.setTower(3, 2, 4, buyer) -- plot 3's Gate Tower builds in at level 4
]]
function AttackWorld.setTower(plot: number, tower: number, level: number, buyer: Player?, deferred: boolean?)
	local index = if tower >= 1 and AttackGeometry.validTower(tower) ~= nil then tower else 0
	if index >= 1 and AttackGeometry.validPlot(plot) == nil then
		return -- defence slots exist on player plots only
	end
	local folder = plotFolder(plot)
	if folder == nil then
		return
	end
	local name = towerName(index)
	local key = if index >= 1 then `tower{plot}:{index}` else `turret{plot}`
	local generation = nextGeneration(key)
	local old = folder:FindFirstChild(name)
	if level < 1 then
		if old ~= nil then
			old:Destroy()
		end
		return
	end
	task.spawn(function()
		local mount = AttackGeometry.towerMount(plot, if index >= 1 then index else nil)
		-- Rival islands / test bots: deferred (boot order); a player's own turret: default priority.
		local scenery = deferred == true or AttackGeometry.rivalOfSlot(plot) ~= nil
		local model = trySpawn(MODELS.Towers[level] or "", mount, NUKE_COLORS[level], scenery)
		if model == nil then
			model = fallbackTurret(level);
			(model :: Model):PivotTo(mount)
		end
		local turret = model :: Model
		if generations[key] ~= generation or folder.Parent == nil then
			turret:Destroy()
			return
		end
		turret.Name = name
		turret.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
		visualOnly(turret)
		turret:SetAttribute("Plot", plot)
		turret:SetAttribute("Tower", index)
		turret:SetAttribute("Level", level)
		CollectionService:AddTag(turret, AttackConfig.Tags.Turret)
		if buyer ~= nil then
			turret:SetAttribute(BuildInConfig.TimeAttribute, Workspace:GetServerTimeNow())
			turret:SetAttribute(BuildInConfig.BuyerAttribute, buyer.UserId)
			CollectionService:AddTag(turret, BuildInConfig.Tag)
		end
		local current = folder:FindFirstChild(name)
		if current ~= nil then
			current:Destroy()
		end
		turret.Parent = folder
	end)
end

--[[
	Shows the HQ AA turret of `level` on a target slot (0 removes it) — setTower(plot, 0, ...),
	kept for rival islands and admin test bots.
	@param plot number
	@param level number — 0..MaxLevel
	@param buyer Player?
]]
function AttackWorld.setTurret(plot: number, level: number, buyer: Player?, deferred: boolean?)
	AttackWorld.setTower(plot, 0, level, buyer, deferred)
end

-- Size of a defence pad's invisible walk-on trigger (studs): the BuyPad tyre + a little reach.
local PAD_TRIGGER = Vector3.new(7, 4, 7)

--[[
	Owner R80: creates / updates / removes the blue defence BUY pad of slot `tower` on a plot (the
	tycoon BuyPad mesh, tinted AttackConfig.Towers.PadColor, on the tower's spot). The model carries
	OwnerUserId / Plot / Tower / Cost / Name attributes (the owner's client draws its billboard and
	enables the Interact buy; other clients just see a pad) and an invisible Trigger whose server
	Touched calls `onTouched(hit)` (walk-on buy, exactly like a tycoon pad; the caller validates
	the character and everything else).
	@param plot number — 1..PlotCount
	@param tower number — 1..#Towers.Slots
	@param ownerUserId number? — nil removes the pad
	@param cost number — the server price shown on the billboard (display only; re-checked)
	@param onTouched ((hit: BasePart) -> ())? — server walk-on handler (only used on creation)
	Example: AttackWorld.setDefensePad(3, 1, player.UserId, 1.3e11, function(hit) ... end)
]]
function AttackWorld.setDefensePad(
	plot: number,
	tower: number,
	ownerUserId: number?,
	cost: number,
	onTouched: ((hit: BasePart) -> ())?
)
	if AttackGeometry.validPlot(plot) == nil or AttackGeometry.validTower(tower) == nil then
		return
	end
	local folder = plotFolder(plot)
	if folder == nil then
		return
	end
	local name = `DefensePad{tower}`
	local existing = folder:FindFirstChild(name)
	if ownerUserId == nil then
		if existing ~= nil then
			existing:Destroy()
		end
		return
	end
	if existing ~= nil then
		existing:SetAttribute("OwnerUserId", ownerUserId)
		existing:SetAttribute("Cost", cost)
		return
	end
	local def = AttackConfig.Towers.Slots[tower]
	local cf = AttackGeometry.towerSlotCFrame(plot, tower)
	local model = Instance.new("Model")
	model.Name = name
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model:SetAttribute("OwnerUserId", ownerUserId)
	model:SetAttribute("Plot", plot)
	model:SetAttribute("Tower", tower)
	model:SetAttribute("Cost", cost)
	model:SetAttribute("Name", def.name)
	local trigger = Instance.new("Part")
	trigger.Name = "Trigger"
	trigger.Anchored = true
	trigger.CanCollide = false
	trigger.CanQuery = false
	trigger.CanTouch = true
	trigger.Transparency = 1
	trigger.CastShadow = false
	trigger.Size = PAD_TRIGGER
	trigger.CFrame = cf * CFrame.new(0, PAD_TRIGGER.Y / 2, 0)
	if onTouched ~= nil then
		trigger.Touched:Connect(onTouched)
	end
	trigger.Parent = model
	model.PrimaryPart = trigger
	model.WorldPivot = cf
	CollectionService:AddTag(model, AttackConfig.Tags.DefensePad)
	model.Parent = folder
	-- Visual: the tycoon BuyPad mesh (async), or a stud slab while it is not loaded / uploaded.
	task.spawn(function()
		local visual = trySpawn("BuyPad", cf, AttackConfig.Towers.PadColor, false)
		if model.Parent == nil then
			if visual ~= nil then
				visual:Destroy()
			end
			return
		end
		if visual ~= nil then
			visual.Name = "Visual"
			visualOnly(visual)
			visual.Parent = model
		else
			visualPart("Top", Vector3.new(6, 1, 6), cf * CFrame.new(0, 0.5, 0), AttackConfig.Towers.PadColor).Parent =
				model
		end
	end)
end

--[[
	Shows / hides the shield dome over a plot (one dome per plot). The client pops it in.
	@param plot number
	@param on boolean
	@param untilTime number? — server time the shield ends (attribute for the client countdown)
]]
function AttackWorld.setDome(plot: number, on: boolean, untilTime: number?, deferred: boolean?)
	local folder = plotFolder(plot)
	if folder == nil then
		return
	end
	local existing = folder:FindFirstChild("ShieldDome")
	if not on then
		if existing ~= nil then
			existing:Destroy()
		end
		return
	end
	if existing ~= nil then
		existing:SetAttribute("Until", untilTime or 0)
		return
	end
	local centre, size = AttackGeometry.shield(plot)
	local dome = Instance.new("Model")
	dome.Name = "ShieldDome"
	dome.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	local part: BasePart
	local art = trySpawn(MODELS.ShieldDome, centre, nil, deferred == true or AttackGeometry.rivalOfSlot(plot) ~= nil)
	if art ~= nil and #art:GetChildren() == 1 and art:GetChildren()[1]:IsA("BasePart") then
		-- One-piece art dome: stretch it over the plot (MeshParts scale non-uniformly).
		part = art:GetChildren()[1] :: BasePart
		part.Size = size
		part.CFrame = centre
		part.Parent = dome
		art:Destroy()
	else
		if art ~= nil then
			art:Destroy()
		end
		local ball = visualPart("Dome", Vector3.one, centre, SHIELD_COLOR)
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Scale = size
		mesh.Parent = ball
		part = ball
		part.Parent = dome
	end
	part.Name = "Dome"
	part.Material = Enum.Material.ForceField
	part.MaterialVariant = ""
	part.Color = SHIELD_COLOR
	part.Transparency = 0
	part.CastShadow = false
	visualOnly(dome)
	dome.WorldPivot = centre
	dome:SetAttribute("Plot", plot)
	dome:SetAttribute("Until", untilTime or 0)
	CollectionService:AddTag(dome, AttackConfig.Tags.Dome)
	dome.Parent = folder
end

-- Creates / updates / removes one owner-only ProximityPrompt part in a plot's Attack folder.
local function setPrompt(
	plot: number,
	name: string,
	position: Vector3,
	actionText: string,
	objectText: string,
	opens: string,
	ownerUserId: number?
)
	local folder = plotFolder(plot)
	if folder == nil then
		return
	end
	local existing = folder:FindFirstChild(name)
	if ownerUserId == nil then
		if existing ~= nil then
			existing:Destroy()
		end
		return
	end
	if existing ~= nil then
		existing:SetAttribute("OwnerUserId", ownerUserId)
		return
	end
	local anchor = visualPart(name, Vector3.new(1, 1, 1), CFrame.new(position), SHIELD_COLOR)
	anchor.Transparency = 1
	anchor:SetAttribute("OwnerUserId", ownerUserId)
	anchor:SetAttribute("Plot", plot)
	anchor:SetAttribute("Opens", opens)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Prompt"
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Parent = anchor
	CollectionService:AddTag(anchor, AttackConfig.Tags.Console)
	anchor.Parent = folder
end

--[[
	Creates / removes the Attack Console ProximityPrompt on a plot ("Launch Nukes!" → the target
	picker). The prompt carries the owner's UserId; clients enable it only on their own plot.
	@param plot number
	@param ownerUserId number? — nil removes the prompt
]]
function AttackWorld.setConsolePrompt(plot: number, ownerUserId: number?)
	setPrompt(
		plot,
		"ConsolePrompt",
		AttackGeometry.consolePrompt(plot),
		"Launch Nukes!",
		"Attack Console",
		"Attack",
		ownerUserId
	)
end

--[[
	Creates / removes the "Upgrade AA" prompt at the foot of the AA tower (→ the Defense screen).
	@param plot number
	@param ownerUserId number? — nil removes the prompt
]]
function AttackWorld.setTowerPrompt(plot: number, ownerUserId: number?)
	setPrompt(plot, "TowerPrompt", AttackGeometry.towerPrompt(plot), "Upgrade", "AA Tower", "Defense", ownerUserId)
end

--[[ Removes every attack object of a plot (plot released / owner left). ]]
function AttackWorld.clearPlot(plot: number)
	if AttackGeometry.validPlot(plot) == nil then
		return
	end
	nextGeneration(`turret{plot}`)
	for tower = 1, #AttackConfig.Towers.Slots do
		nextGeneration(`tower{plot}:{tower}`)
	end
	local ok, model = pcall(PlotBuilder.getPlot, plot)
	if ok and model ~= nil then
		local folder = model:FindFirstChild(AttackConfig.PlotFolder)
		if folder ~= nil then
			folder:Destroy()
		end
	end
end

return AttackWorld
