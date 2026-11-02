--!strict
--[[
	ManagerController — brings every hired manager to life (owner R30: "the little NPCs that you
	hire to automate things ... actually move around and be animated and not just a still prop").

	What the player sees (client-side only; the server meshes + collision never change):
		* idle breathing / sway, head following the plot owner when they are close
		* a short work loop between its producer and nearby stations (ManagerNpcConfig.Rigs
		  waypoints), walking with leg + arm swing, turning smoothly
		* a "work" action (Tap / Hammer / Press) synced to the producer cycle
		  (anchor CycleStart / CycleTime), with a small sparkle + clack
		* turns and waves when the plot owner arrives within ~14 studs
		* a happy hop when anything new is bought on its plot (BuildInController.BuildFinished)
		* dazed while its area is knocked down (owner R50, KnockdownFx → setAreaDazed): sits where
		  it stands, sways with a lolling head, three stars orbit its head (one pooled BillboardGui
		  per manager); the brain waits and resumes exactly when the area is rebuilt
		* a nametag over its head (owner R87: "in sell lemons the managers/automaters all have
		  nametags"): a role chip, a friendly name and "runs <producer>" (Npc/ManagerTags visuals,
		  Npc/ManagerTagLogic + Config/ManagerTagConfig rules). Every manager in range gets one
		  (own: MaxDistanceOwn, others: MaxDistanceOther); it hides during the build-in, while the
		  model is streamed out / beyond range; when it would cover the producer's own billboard
		  on screen it slides sideways (eased) until clear, hiding only if a slide within 45% of its
		  width cannot clear it; it lifts above the dazed stars during a knockdown.
		* now and then a short speech bubble ("Efficiency... yes!") over ONE of the local player's
		  managers per plot, only while the owner is near, every 20-40 s, never while dazed;
		  other players' managers never speak (less clutter).
	Behaviour lives in the pure NpcBrain (state machine) + NpcPose (angles); this module owns the
	Instances: discovery, rest-pose capture, culling, CFrames, sound, sparkles, tag / bubble state.

	Rig: each manager mesh is split by tools/blender/models/_npc_rig.py into pieces named
	`<Group><Colour>` (TorsoCoat, ArmLSkin, LegRShoes...). Pieces whose name starts with a group
	(ManagerNpcConfig.groupOf) are animated about that group's joint; everything else (desks,
	podiums, consoles in the same model) stays put. Each animated piece's rest offset from the
	figure root is captured once from its server CFrame (so the FBX import yaw, MeshPlacement rule 1,
	is already baked in), then per frame:
		piece.CFrame = modelPivot * root(x, y, z, yaw) * group(joint rotation) * rest
	Assemblies move as one (owner R25): a held nuke / clipboard / basket is part of its arm group.

	Discovery: DescendantAdded on EVERY world's plots folder (Tycoon/PlotFolders: Workspace.Plots
	for Nuke Town, Workspace.Worlds.<id>.Plots for Dino Valley and later worlds), filtered to Models
	named like a manager build (ManagerNpcConfig.ownsModel, one string compare + one table look-up
	per streamed Model) with a MeshKey attribute in ManagerNpcConfig.Rigs. Streaming out / plot
	clears unregister through AncestryChanged. A fresh hire waits for its LEGO build-in
	(BuildFinished, or BuildHoldSeconds).

	Worlds (owner R57, W10): nothing here is world-specific — a manager animates from its own
	model pivot + rig, its producer is the anchor of the same plot Model + area (each world's plots
	are distinct Models, so Nuke Town Plot3 and Dino Plot3 never mix), and the owner is that plot's
	OwnerUserId. Each record remembers its world (TycoonWorld.worldOf) for stats / verification.
	The only world-specific behaviour is the hop voice (ManagerNpcConfig.Fx.WorldHopVoice keyed by
	the rig's `world`): Dino managers celebrate with a sparse happy roar instead of the pop.
	Only one world streams at a time (worlds sit 6000 studs apart), so the camera ranking already
	keeps the other world's managers idle. Knockdown dazing is Nuke Town only (spec §7).

	Performance (owner R11, console + mobile first):
		* ONE Heartbeat connection (only while a manager exists); every RefreshInterval the managers
		  are ranked by camera distance: only the nearest Tier.MaxActive within Tier.Range animate
		  (FxQuality Low / Mid / High). Others are settled into their rest pose once and cost nothing.
		  Active managers beyond HalfRateBeyond update every other frame; an active manager outside
		  the camera cone (Shared/Util/ViewCone) keeps thinking but its pieces are not moved.
		* One BulkMoveTo per frame; no Instance.new, tables or closures per frame (brain / pose /
		  input tables and scratch arrays are reused).
		* Reduced motion (Roblox setting or profile.settings.reducedMotion): managers stand at home,
		  idle breathing only.
		* Tags + bubbles (owner R87) cost nothing per frame: they are adorned to the head piece (the
		  engine moves them with the NPC) and their state is decided in the same RefreshInterval
		  pass (range, build-in hold, board overlap test for near tags only, bubble scheduler).
		  Tags are pooled billboards acquired when a manager comes in range and released when it
		  leaves far behind or streams out.

	Boot: controller contract Init() / Start(), listed after Tycoon/Fx/WorldFxController in
	src/client/init.client.luau as "Tycoon/Npc/ManagerController".

	Example (Studio console, client):
		local mc = require(game.Players.LocalPlayer.PlayerScripts.Client.Tycoon.Npc.ManagerController)
		print(mc.stats()) --> { managers = 3, active = 2, worlds = { main = 3 }, tags = 3, bubbles = 0 }
		print(mc.tagStats().list[1].name) --> "Captain Kaboom"
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local IconAssets = require(ReplicatedStorage.Shared.Config.IconAssets)
local KnockdownConfig = require(ReplicatedStorage.Shared.Config.KnockdownConfig)
local ManagerNpcConfig = require(ReplicatedStorage.Shared.Config.ManagerNpcConfig)
local ManagerTagConfig = require(ReplicatedStorage.Shared.Config.ManagerTagConfig)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Sound = require(script.Parent.Parent.Parent.Audio.Sound)
local ScreenManager = require(script.Parent.Parent.Parent.UI.ScreenManager)
local BuildInController = require(script.Parent.Parent.BuildIn.BuildInController)
local Confetti = require(script.Parent.Parent.Fx.Confetti)
local FxQuality = require(script.Parent.Parent.Fx.FxQuality)
local ProducerBillboards = require(script.Parent.Parent.ProducerBillboards)
local TycoonContract = require(script.Parent.Parent.TycoonContract)
local TycoonWorld = require(script.Parent.Parent.TycoonWorld)
local PlotFolders = require(script.Parent.Parent.PlotFolders)
local WorldLookup = require(script.Parent.Parent.WorldLookup)
local ManagerTagLogic = require(script.Parent.ManagerTagLogic)
local ManagerTags = require(script.Parent.ManagerTags)
local NpcBrain = require(script.Parent.NpcBrain)
local NpcPose = require(script.Parent.NpcPose)
local ViewCone = require(ReplicatedStorage.Shared.Util.ViewCone)

local Attr = TycoonContract.Attr
local Motion = ManagerNpcConfig.Motion
local Fx = ManagerNpcConfig.Fx
local TagCfg = ManagerTagConfig.Tag
local BubbleCfg = ManagerTagConfig.Bubble
-- A tag that falls this many times its range behind goes back to the pool (bounded live count).
local TAG_RELEASE_FACTOR = 1.5
-- A showing bubble survives the owner stepping a little past NearRange (no flicker at the edge).
local BUBBLE_KEEP_FACTOR = 1.25

-- Group slots (ManagerNpcConfig.Groups order).
local TORSO, HEAD, ARM_L, ARM_R, LEG_L, LEG_R = 1, 2, 3, 4, 5, 6
local GROUP_SLOT: { [string]: number } = {}
for index, group in ManagerNpcConfig.Groups do
	GROUP_SLOT[group] = index
end
-- Hand offset below the shoulder joint (figure-local), used for the work sparkle / sound.
local HAND_DROP = Vector3.new(0, -1.9, -0.2)

-- Producer anchor state, cached from attribute-change events (never read per frame).
type AnchorInfo = {
	anchor: BasePart,
	plot: Model?,
	area: number,
	cycleTime: number,
	cycleStart: number,
	automated: boolean,
	connection: RBXScriptConnection,
}

type Record = {
	model: Model,
	container: Instance?, -- the Builds/<BuildKey> Model (BuildIn tag / BuildFinished identity)
	key: string,
	rig: ManagerNpcConfig.Rig,
	plot: Model?,
	worldId: string, -- owner R57: the world of its plot ("main", "dino", ...)
	areaIndex: number,
	pivot: CFrame, -- model WorldPivot (server placement)
	home: Vector3, -- world position of the figure's rest root (ranking)
	parts: { BasePart }, -- animated pieces
	rels: { CFrame }, -- rest offset of each piece from the figure root
	slots: { number }, -- group slot of each piece
	hasGroup: { boolean }, -- group slot -> any piece in it
	jointPos: { CFrame }, -- figure-local joint translation per slot
	jointNeg: { CFrame }, -- its inverse
	hands: { Vector3 }, -- figure-local hand points for ArmL / ArmR slots
	groupCF: { CFrame }, -- world CFrame per slot this frame (reused)
	brain: NpcBrain.Brain,
	pose: NpcPose.Pose,
	input: NpcBrain.Input,
	anchorInfo: AnchorInfo?,
	lastCycle: number?,
	ownerRoot: BasePart?,
	holdUntil: number, -- os.clock(): the build-in owns the pieces until then
	active: boolean,
	wantActive: boolean,
	halfRate: boolean,
	slot: number, -- frame-parity offset for half-rate updates
	accum: number, -- seconds not yet simulated (half-rate)
	distance: number,
	connections: { RBXScriptConnection },
	-- Knockdown (owner R50): its area is down → it sits dazed with orbiting stars.
	dazed: boolean,
	sitDrop: number, -- studs the root sinks when sitting (hip height minus a little)
	stars: BillboardGui?, -- created the first time it is dazed, then only toggled
	starLabels: { ImageLabel },
	-- Nametag + speech bubble (owner R87).
	mine: boolean, -- its plot belongs to the local player (longer tag range, may speak)
	tagInfo: ManagerTagLogic.Tag?, -- role / name / runs (resolved once at registration)
	tagAdornee: BasePart?, -- the head piece the tag rides on (torso when the rig has no head)
	tagOffset: number, -- studs from the adornee's centre to the tag's bottom edge (rest pose)
	tag: ManagerTags.TagVisual?, -- pooled billboard (acquired once in range)
	tagShown: boolean,
	tagYield: boolean, -- hidden: no sideways nudge within the cap clears its producer billboard
	tagClear: number, -- consecutive clear refreshes while yielded (hysteresis)
	tagWidth: number, -- share of the full tag width its text needs (ManagerTagLogic.widthScale)
	nudgeTarget: number, -- studs the tag should slide sideways (clear of its producer board)
	nudgeShown: number, -- studs it is slid right now (eases toward nudgeTarget)
	lines: { string }, -- what it may say (shared list per world / robot)
}

-- One plot's speech-bubble state (owner R87: one bubble per plot at a time, owner only).
type PlotBubble = {
	scheduler: ManagerTagLogic.Scheduler, -- seeded by the local player + plot (never lock-step)
	rec: Record?, -- the manager speaking right now
	visual: ManagerTags.BubbleVisual?,
	line: string, -- what it is saying (its length sizes the bubble's overlap test)
}

local ManagerController = {}

local started = false
local records: { [Model]: Record } = {}
local recordList: { Record } = {}
-- Knockdown daze (owner R50): plot → area → dazed, set by Tycoon/BuildIn/KnockdownFx.
local dazedAreas: { [Model]: { [number]: boolean } } = {}
-- How far a Hover rig sags when dazed (studs).
local DAZED_HOVER_SAG = 0.7
-- Forward declarations (defined in the "Knockdown daze" section below).
local orbitStars: (rec: Record, clock: number) -> ()
local setRecordDazed: (rec: Record, on: boolean) -> ()
local isAreaDazed: (plot: Model, areaIndex: number) -> boolean
-- Forward declaration (defined in the "Nametags + speech bubbles" section below).
local hideBubbleOf: (rec: Record) -> ()
local activeList: { Record } = {}
local ranked: { Record } = {}
local anchorsByPlot: { [Instance]: { [number]: AnchorInfo } } = {}
local anchorInfos: { [BasePart]: AnchorInfo } = {}
local heartbeat: RBXScriptConnection? = nil
local refreshClock = 0
local frameCount = 0
local viewCos = -1 -- ViewCone limit for the current camera (-1 = everything visible)
local seedCounter = 0
local reduced = false
local sparkleTier = true
local tierNow = "Mid" -- FxQuality tier at the last refresh (world hop voices are tier-gated)
local voiceNext: { [string]: number } = {} -- world id -> os.clock() its hop voice may play again
-- Scratch arrays for the one BulkMoveTo per frame (cleared, never reallocated).
local movedParts: { BasePart } = {}
local movedFrames: { CFrame } = {}
local movedCount = 0
local soundBudget = 0
local sparkleBudget = 0
-- Nametags + bubbles (owner R87).
local tagDevice = false -- phone / tablet / console sizing at the last refresh
local plotBubbles: { [Model]: PlotBubble } = {}
local linesCache: { [string]: { string } } = {} -- "<world>|<robot>" -> shared line list
-- Scratch lists for the bubble pass (cleared, never reallocated).
local speakerRecs: { Record } = {}
local speakerKeys: { string } = {}
local minePlots: { [Model]: boolean } = {}
-- Tags easing toward a new sideways nudge (usually empty; stepped by the Heartbeat).
local easingList: { Record } = {}

-- Finite number attribute, else nil (attributes are display input from the server).
local function numberAttr(instance: Instance, name: string): number?
	local value = instance:GetAttribute(name)
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- Reduced motion: the Roblox accessibility setting or SellNukes' own setting.
local function isReduced(): boolean
	if GuiService.ReducedMotionEnabled then
		return true
	end
	local profile = ClientState.profile
	local settings = profile and (profile :: any).settings
	return type(settings) == "table" and settings.reducedMotion == true
end

-- Comparator at module level (no per-refresh closure).
local function nearerFirst(a: Record, b: Record): boolean
	return a.distance < b.distance
end

---------------------------------------------------------------------------------------------------
-- Producer anchors (cycle sync)
---------------------------------------------------------------------------------------------------

-- Re-reads the cycle attributes of one anchor (on change only).
local function readAnchor(info: AnchorInfo)
	local anchor = info.anchor
	info.cycleTime = numberAttr(anchor, Attr.CycleTime) or 0
	info.cycleStart = numberAttr(anchor, Attr.CycleStart) or 0
	info.automated = anchor:GetAttribute(Attr.Automated) == true
end

local function onProducerAdded(anchor: BasePart)
	if anchorInfos[anchor] ~= nil then
		return
	end
	local plot = TycoonWorld.plotOf(anchor)
	local area = numberAttr(anchor, "Area")
	if plot == nil or area == nil then
		return
	end
	local info: AnchorInfo = {
		anchor = anchor,
		plot = plot,
		area = area,
		cycleTime = 0,
		cycleStart = 0,
		automated = false,
		connection = anchor.AttributeChanged:Connect(function(name: string)
			if name == Attr.CycleTime or name == Attr.CycleStart or name == Attr.Automated then
				local current = anchorInfos[anchor]
				if current ~= nil then
					readAnchor(current)
				end
			end
		end),
	}
	readAnchor(info)
	anchorInfos[anchor] = info
	local byArea = anchorsByPlot[plot]
	if byArea == nil then
		byArea = {}
		anchorsByPlot[plot] = byArea
	end
	byArea[area] = info
end

local function onProducerRemoved(anchor: BasePart)
	local info = anchorInfos[anchor]
	if info == nil then
		return
	end
	info.connection:Disconnect()
	anchorInfos[anchor] = nil
	local byArea = if info.plot ~= nil then anchorsByPlot[info.plot] else nil
	if byArea ~= nil and byArea[info.area] == info then
		byArea[info.area] = nil
	end
	for _, record in recordList do
		if record.anchorInfo == info then
			record.anchorInfo = nil
			record.lastCycle = nil
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Pose -> CFrames
---------------------------------------------------------------------------------------------------

--[[
	Computes this frame's group CFrames from rec.pose and, when `queue`, appends every animated
	piece to the BulkMoveTo scratch arrays (false: off screen — the group CFrames still update for
	hit / hop effects, nothing moves).
]]
local function writePose(rec: Record, queue: boolean)
	local pose = rec.pose
	local jp, jn, g = rec.jointPos, rec.jointNeg, rec.groupCF
	local figure = rec.pivot * CFrame.new(pose.x, pose.y, pose.z) * CFrame.Angles(0, pose.yaw, 0)
	local torso = figure
		* CFrame.new(0, pose.torsoLift, 0)
		* jp[TORSO]
		* CFrame.Angles(pose.torsoPitch, pose.torsoYaw, pose.torsoRoll)
		* jn[TORSO]
	g[TORSO] = torso
	local has = rec.hasGroup
	if has[HEAD] then
		g[HEAD] = torso * jp[HEAD] * CFrame.Angles(pose.headPitch, pose.headYaw, 0) * jn[HEAD]
	end
	if has[ARM_L] then
		g[ARM_L] = torso * jp[ARM_L] * CFrame.Angles(pose.armLPitch, 0, pose.armLRoll) * jn[ARM_L]
	end
	if has[ARM_R] then
		g[ARM_R] = torso * jp[ARM_R] * CFrame.Angles(pose.armRPitch, 0, pose.armRRoll) * jn[ARM_R]
	end
	if has[LEG_L] then
		g[LEG_L] = figure * jp[LEG_L] * CFrame.Angles(pose.legLPitch, 0, 0) * jn[LEG_L]
	end
	if has[LEG_R] then
		g[LEG_R] = figure * jp[LEG_R] * CFrame.Angles(pose.legRPitch, 0, 0) * jn[LEG_R]
	end
	if not queue then
		return
	end
	local parts, rels, slots = rec.parts, rec.rels, rec.slots
	for i = 1, #parts do
		movedCount += 1
		movedParts[movedCount] = parts[i]
		movedFrames[movedCount] = g[slots[i]] * rels[i]
	end
end

-- Sends the scratch arrays in one BulkMoveTo and resets them.
local function flush()
	if movedCount > 0 then
		Workspace:BulkMoveTo(movedParts, movedFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	table.clear(movedParts)
	table.clear(movedFrames)
	movedCount = 0
end

---------------------------------------------------------------------------------------------------
-- Events: work hit + hop
---------------------------------------------------------------------------------------------------

-- A work action landed: clack + small sparkle at the working hand (nearest managers only).
local function onHit(rec: Record)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local armSlot = if rec.rig.workArm == "ArmL" then ARM_L else ARM_R
	if not rec.hasGroup[armSlot] then
		armSlot = TORSO
	end
	local hand = rec.groupCF[armSlot] * rec.hands[armSlot]
	local distance = (hand - camera.CFrame.Position).Magnitude
	local action = rec.rig.workAction
	if soundBudget > 0 and distance <= Fx.SoundRange then
		soundBudget -= 1
		Sound.play(Fx.WorkSound, { position = hand, volume = Fx.WorkVolume, pitch = Fx.WorkPitch[action] })
	end
	if sparkleTier and sparkleBudget > 0 and Fx.SparkleCount > 0 and distance <= Fx.SparkleRange then
		sparkleBudget -= 1
		Confetti.burst(hand, 0, Fx.SparkleCount)
	end
end

--[[
	A hop started: soft pop (one per frame at most, nearby only). A world with a hop voice
	(Fx.WorldHopVoice, owner R57: Dino managers roar happily) uses it instead, at most once per
	its cooldown and only on its tiers; the hops in between keep the pop (sparse, never a chorus).
]]
local function onHop(rec: Record)
	local camera = Workspace.CurrentCamera
	if camera == nil or soundBudget <= 0 then
		return
	end
	local position = rec.groupCF[TORSO].Position
	if (position - camera.CFrame.Position).Magnitude > Fx.SoundRange then
		return
	end
	soundBudget -= 1
	local worldId = rec.rig.world
	local voice = if worldId ~= nil then Fx.WorldHopVoice[worldId] else nil
	local now = os.clock()
	if voice ~= nil and voice.tiers[tierNow] == true and now >= (voiceNext[worldId :: string] or 0) then
		voiceNext[worldId :: string] = now + voice.cooldown
		Sound.play(voice.key, { position = position, volume = voice.volume })
	else
		Sound.play(Fx.HopSound, { position = position, volume = Fx.HopVolume })
	end
end

---------------------------------------------------------------------------------------------------
-- Per-frame animation
---------------------------------------------------------------------------------------------------

-- Steps one active manager by `dt` seconds and queues its pieces (only when `visible`).
local function animate(rec: Record, dt: number, now: number, visible: boolean)
	if rec.dazed then
		-- Knocked-down area (owner R50): sit + sway + stars; the brain waits (resumes intact).
		local clock = os.clock()
		NpcPose.dazed(rec.brain, rec.pose, if reduced then 0 else clock, rec.sitDrop)
		writePose(rec, visible)
		if visible and not reduced then
			orbitStars(rec, clock)
		end
		return
	end
	local input = rec.input
	input.dt = dt
	input.reduced = reduced
	local root = rec.ownerRoot
	if root ~= nil and root.Parent ~= nil then
		local p = rec.pivot:PointToObjectSpace(root.Position)
		input.ownerValid = true
		input.ownerX = p.X
		input.ownerZ = p.Z
	else
		input.ownerValid = false
	end
	local info = rec.anchorInfo
	if info ~= nil and info.automated and info.cycleTime > 0 then
		local index = math.floor((now - info.cycleStart) / info.cycleTime)
		input.synced = true
		input.cycleWrapped = rec.lastCycle ~= nil and index ~= rec.lastCycle
		rec.lastCycle = index
	else
		input.synced = false
		input.cycleWrapped = false
		rec.lastCycle = nil
	end
	local brain = rec.brain
	NpcBrain.step(brain, input)
	NpcPose.compute(brain, rec.pose)
	writePose(rec, visible)
	if brain.hit then
		onHit(rec)
	end
	if brain.hopped then
		onHop(rec)
	end
end

--------------------------------------------------------------------------------------------------
-- Knockdown daze (owner R50: "managers sit dazed with stars"; KnockdownFx drives it)
--------------------------------------------------------------------------------------------------

-- Places a record's stars on their orbit at `clock` (an ellipse over the head: reads as a ring).
function orbitStars(rec: Record, clock: number)
	local labels = rec.starLabels
	local count = #labels
	local spin = math.rad(KnockdownConfig.Client.DazedStarSpin) * clock
	for i, label in labels do
		local angle = spin + (i - 1) * (2 * math.pi / count)
		local depth = math.sin(angle) -- > 0: in front of the head
		label.Position = UDim2.fromScale(0.5 + 0.4 * math.cos(angle), 0.5 + 0.2 * depth)
		label.ZIndex = if depth > 0 then 3 else 1
		local size = 0.26 + 0.06 * depth
		label.Size = UDim2.fromScale(size, size * 2.3)
	end
end

-- The record's star billboard (built once, on its head piece; then only Enabled is toggled).
local function ensureStars(rec: Record): BillboardGui?
	if rec.stars ~= nil then
		return rec.stars
	end
	local adornee: BasePart? = nil
	for i, part in rec.parts do
		if rec.slots[i] == HEAD then
			adornee = part
			break
		end
	end
	adornee = adornee or rec.parts[1]
	if adornee == nil then
		return nil
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "DazedStars"
	gui.Size = UDim2.fromScale(3.2, 1.4)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 1.7, 0)
	gui.LightInfluence = 0
	gui.MaxDistance = 140
	gui.Enabled = false
	gui.Adornee = adornee
	local image = IconAssets.image("Star") or ""
	for _ = 1, KnockdownConfig.Client.DazedStars do
		local label = Instance.new("ImageLabel")
		label.Name = "Star"
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Image = image
		label.ImageColor3 = Color3.fromRGB(255, 226, 92)
		label.Parent = gui
		table.insert(rec.starLabels, label)
	end
	orbitStars(rec, 0)
	gui.Parent = adornee
	rec.stars = gui
	return gui
end

-- Is (plot, area) currently dazed?
function isAreaDazed(plot: Model, areaIndex: number): boolean
	local byArea = dazedAreas[plot]
	return byArea ~= nil and byArea[areaIndex] == true
end

-- Settles a manager leaving the animated set into its rest pose where it stands (queued).
local function settle(rec: Record)
	if rec.dazed then
		NpcPose.dazed(rec.brain, rec.pose, os.clock(), rec.sitDrop)
	else
		NpcPose.rest(rec.brain, rec.pose)
	end
	writePose(rec, true)
end

-- Dazes / revives one manager: stars on / off and its pose settled at once (even when far).
function setRecordDazed(rec: Record, on: boolean)
	if rec.dazed == on then
		return
	end
	rec.dazed = on
	local stars = if on then ensureStars(rec) else rec.stars
	if stars ~= nil then
		stars.Enabled = on
	end
	-- Owner R87: the nametag rises clear of the orbiting stars; a dazed manager never speaks.
	if rec.tag ~= nil then
		ManagerTags.setLift(rec.tag, if on then TagCfg.DazedLift else 0)
	end
	if on then
		hideBubbleOf(rec)
	end
	if not on then
		rec.accum = 0
	end
	settle(rec)
	flush()
end

-- The plot owner's character root (nil when absent / not streamed).
local function ownerRootOf(plot: Model?): BasePart?
	if plot == nil then
		return nil
	end
	local userId = numberAttr(plot, Attr.OwnerUserId)
	if userId == nil or userId <= 0 then
		return nil
	end
	local player = Players:GetPlayerByUserId(userId)
	local character = player and player.Character
	if character == nil then
		return nil
	end
	local part = character:FindFirstChild("HumanoidRootPart")
	return if part ~= nil and part:IsA("BasePart") then part else nil
end

---------------------------------------------------------------------------------------------------
-- Nametags + speech bubbles (owner R87: "in sell lemons the managers/automaters all have nametags")
---------------------------------------------------------------------------------------------------

-- Line length assumed when testing whether a bubble would fit before its line is picked.
local TYPICAL_LINE_CHARS = 20

-- The local player's character root (nil while absent / not streamed).
local function localRoot(): BasePart?
	local player = Players.LocalPlayer
	local character = if player ~= nil then player.Character else nil
	local part = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if part ~= nil and part:IsA("BasePart") then part else nil
end

-- What a manager may say: general + its world's lines (+ robot lines); one shared list per kind.
local function linesOf(worldId: string, robot: boolean): { string }
	local key = if robot then `{worldId}|robot` else worldId
	local cached = linesCache[key]
	if cached == nil then
		cached = ManagerTagLogic.linesFor(ManagerTagConfig.Lines, worldId, robot)
		linesCache[key] = cached
	end
	return cached :: { string }
end

--[[
	What a manager's tag says: its Manager pad (found by build key in the world's economy config)
	gives the role / canon name and the producer it runs (`pad.target`); pooled names are seeded by
	`ownerSeed` (the plot owner: stable across rejoins, servers and plot slots). nil when the key
	is not a Manager pad's build (nothing to say).
	Example: describeTag("A4_Foreman", "main", 12345) --> { role = "Foreman", name = "...", runs = "Glow Rock Drill" }
]]
local function describeTag(key: string, worldId: string, ownerSeed: number): ManagerTagLogic.Tag?
	local economy = WorldLookup.def(worldId).economy
	local padId = economy.BuildKeys[key]
	local pad = if padId ~= nil then economy.PadsById[padId] else nil
	if pad == nil or pad.kind ~= "Manager" then
		return nil
	end
	local producer = if pad.target ~= nil then economy.ProducersById[pad.target] else nil
	return ManagerTagLogic.describe(
		key,
		pad.name,
		if producer ~= nil then producer.name else "",
		ManagerNpcConfig.managerKeysOf(worldId),
		ManagerTagConfig.Managers,
		ManagerTagConfig.NamePools,
		function(pool: string): number
			return ManagerTagLogic.seedOf(ownerSeed, worldId, pool)
		end,
		ManagerTagConfig.DefaultRole
	)
end

-- The width share a tag's text needs (1 when there is nothing to say).
local function tagWidthOf(info: ManagerTagLogic.Tag?): number
	if info == nil then
		return 1
	end
	local runsText = if info.runs ~= "" then `{TagCfg.RunsPrefix} {info.runs}` else ""
	return ManagerTagLogic.widthScale(
		info.name,
		runsText,
		string.upper(info.role),
		TagCfg,
		TagCfg.FullWidthChars,
		TagCfg.MinWidthScale
	)
end

--[[
	Where a manager's tag rides (rest pose, at registration): its first head piece, the tag's bottom
	edge HeadGap above the top of the highest head piece (hats included). A rig without a head rides
	on its torso, above the highest torso piece.
	@return adornee (nil: no piece of that group), offset in studs above the adornee's centre
]]
local function tagAnchorOf(parts: { BasePart }, slots: { number }, hasHead: boolean): (BasePart?, number)
	local wanted = if hasHead then HEAD else TORSO
	local adornee: BasePart? = nil
	local top = -math.huge
	for i, part in parts do
		if slots[i] == wanted then
			local cf = part.CFrame
			local half = part.Size * 0.5
			-- Half the world height of the (possibly rotated) piece box.
			local extent = math.abs(cf.RightVector.Y) * half.X
				+ math.abs(cf.UpVector.Y) * half.Y
				+ math.abs(cf.LookVector.Y) * half.Z
			top = math.max(top, cf.Position.Y + extent)
			if adornee == nil then
				adornee = part
			end
		end
	end
	if adornee == nil then
		return nil, 0
	end
	return adornee, top - adornee.Position.Y + TagCfg.HeadGap
end

--[[
	The manager's producer billboard on screen (ProducerBillboards, same plot + area): centre and
	size in px, from the board's own studs size at its depth (no AbsoluteSize reads). nil when the
	board is missing, hidden, beyond its MaxDistance or behind the camera.
	@return (cx, cy, w, h)?
]]
local function boardRect(rec: Record, camera: Camera, focal: number): (number?, number, number, number)
	local info = rec.anchorInfo
	local board = if info ~= nil then ProducerBillboards.byAnchor(info.anchor) else nil
	if board == nil then
		return nil, 0, 0, 0
	end
	local gui = board.gui
	if not gui.Enabled or gui.Parent == nil then
		return nil, 0, 0, 0
	end
	local position = board.point.WorldPosition
	if (position - camera.CFrame.Position).Magnitude > gui.MaxDistance then
		return nil, 0, 0, 0
	end
	local screen = camera:WorldToViewportPoint(position)
	if screen.Z <= 0.1 then
		return nil, 0, 0, 0
	end
	local size = gui.Size
	local perStud = focal / screen.Z
	return screen.X, screen.Y, size.X.Scale * perStud + size.X.Offset, size.Y.Scale * perStud + size.Y.Offset
end

-- Points a tag's sideways nudge at `target` studs: eased by the Heartbeat (snapped when reduced
-- motion is on or the tag is hidden), so it glides instead of jumping between refreshes.
local function aimNudge(rec: Record, target: number, snap: boolean)
	rec.nudgeTarget = target
	if snap or reduced or rec.tag == nil then
		rec.nudgeShown = target
		if rec.tag ~= nil then
			ManagerTags.setNudge(rec.tag, target)
		end
		local index = table.find(easingList, rec)
		if index ~= nil then
			table.remove(easingList, index)
		end
	elseif rec.nudgeShown ~= target and table.find(easingList, rec) == nil then
		table.insert(easingList, rec)
	end
end

--[[
	Tag pass (every RefreshInterval): a manager shows its tag when it is described, its head piece
	is present, its build-in finished and it is within range (own MaxDistanceOwn / others
	MaxDistanceOther). A near tag that would cover its producer's billboard on screen slides
	sideways (ManagerTagLogic.nudge: smallest shift, keeps its side, <= NudgeMaxFraction of its
	width); only when no such shift clears it does it hide (yield; back after YieldClearRefreshes
	clear passes). Tags are acquired in range and pooled again once far behind.
]]
local function updateTags(clock: number, camera: Camera?, focal: number)
	local device = ScreenManager.device.class ~= "Desktop"
	local deviceChanged = device ~= tagDevice
	tagDevice = device
	for _, rec in recordList do
		local adornee = rec.tagAdornee
		local info = rec.tagInfo
		local range = if rec.mine then TagCfg.MaxDistanceOwn else TagCfg.MaxDistanceOther
		local want = info ~= nil
			and adornee ~= nil
			and adornee.Parent ~= nil
			and clock >= rec.holdUntil
			and rec.distance <= range
		local target = 0
		if want and camera ~= nil and adornee ~= nil and rec.distance <= TagCfg.YieldCheckRange then
			if rec.anchorInfo == nil and rec.plot ~= nil then
				local byArea = anchorsByPlot[rec.plot]
				rec.anchorInfo = if byArea ~= nil then byArea[rec.areaIndex] else nil
			end
			-- The un-nudged tag's bottom-centre on screen; it extends `h` px upward from there.
			local lift = if rec.dazed then TagCfg.DazedLift else 0
			local screen = camera:WorldToViewportPoint(adornee.Position + Vector3.new(0, rec.tagOffset + lift, 0))
			local blocked = false
			if screen.Z > 0.1 then
				local bx, by, bw, bh = boardRect(rec, camera, focal)
				if bx ~= nil then
					local w, h = ManagerTags.tagPixels(focal, screen.Z, device, rec.tagWidth)
					local prefer = if rec.nudgeTarget > 0 then 1 elseif rec.nudgeTarget < 0 then -1 else 0
					local shift, clear = ManagerTagLogic.nudge(
						screen.X,
						screen.Y - h / 2,
						w,
						h,
						bx,
						by,
						bw,
						bh,
						TagCfg.YieldMargin,
						w * TagCfg.NudgeMaxFraction,
						prefer
					)
					blocked = not clear
					-- px -> studs at the tag's depth (StudsOffset X slides it in camera space).
					target = if clear then shift * screen.Z / focal else 0
				end
			end
			if blocked then
				rec.tagYield = true
				rec.tagClear = 0
			elseif rec.tagYield then
				rec.tagClear += 1
				rec.tagYield = rec.tagClear < TagCfg.YieldClearRefreshes
			end
			want = not rec.tagYield
		end
		local tag = rec.tag
		if want and tag == nil and info ~= nil and adornee ~= nil then
			tag = ManagerTags.acquire()
			if tag ~= nil then
				ManagerTags.style(tag, info, rec.worldId, rec.mine, device)
				ManagerTags.place(tag, adornee, rec.tagOffset)
				ManagerTags.setLift(tag, if rec.dazed then TagCfg.DazedLift else 0)
				rec.tag = tag
				aimNudge(rec, target, true) -- a fresh tag starts where it belongs
			end
		elseif tag ~= nil and not want and rec.distance > range * TAG_RELEASE_FACTOR then
			hideBubbleOf(rec)
			ManagerTags.release(tag)
			rec.tag = nil
			tag = nil
		end
		if tag ~= nil then
			if deviceChanged then
				ManagerTags.setDevice(tag, device)
			end
			if not want then
				if rec.nudgeTarget ~= 0 or rec.nudgeShown ~= 0 then
					aimNudge(rec, 0, true) -- hidden: no glide needed
				end
			elseif
				math.abs(target - rec.nudgeTarget) > TagCfg.NudgeEpsilon or (target == 0 and rec.nudgeTarget ~= 0)
			then
				aimNudge(rec, target, false)
			end
			ManagerTags.setShown(tag, want)
		end
		rec.tagShown = want and tag ~= nil
	end
end

--[[ Ends the bubble `rec` is saying, if any (dazed, streamed out, tag hidden, time up). ]]
function hideBubbleOf(rec: Record)
	local plot = rec.plot
	local state = if plot ~= nil then plotBubbles[plot] else nil
	if state == nil or state.rec ~= rec then
		return
	end
	local visual = state.visual
	if visual ~= nil then
		ManagerTags.releaseBubble(visual)
		state.visual = nil
	end
	state.rec = nil
	ManagerTagLogic.ended(state.scheduler, os.clock())
end

--[[
	Heartbeat part of the nudge: eases every gliding tag (and the bubble riding on it) toward its
	target. Only tags whose target just changed are in `easingList`, so this is usually empty.
]]
local function stepNudges(dt: number)
	local alpha = math.min(1, dt * TagCfg.NudgeRate)
	for index = #easingList, 1, -1 do
		local rec = easingList[index]
		local tag = rec.tag
		local shown = rec.nudgeShown + (rec.nudgeTarget - rec.nudgeShown) * alpha
		if tag == nil or math.abs(rec.nudgeTarget - shown) < 0.02 then
			shown = rec.nudgeTarget
			table.remove(easingList, index)
		end
		rec.nudgeShown = shown
		if tag ~= nil then
			ManagerTags.setNudge(tag, shown)
			local state = if rec.plot ~= nil then plotBubbles[rec.plot] else nil
			if state ~= nil and state.rec == rec and state.visual ~= nil then
				ManagerTags.nudgeBubble(state.visual, shown)
			end
		end
	end
end

--[[
	Can `rec` speak now? Own manager, tag up, not dazed, the owner within `range` studs of it, and
	a `chars`-long bubble above its (nudged) tag would not cover its producer's billboard on screen.
]]
local function canSpeak(
	rec: Record,
	root: BasePart?,
	range: number,
	camera: Camera?,
	focal: number,
	chars: number
): boolean
	local adornee = rec.tagAdornee
	if not rec.mine or not rec.tagShown or rec.dazed or rec.tag == nil or root == nil or adornee == nil then
		return false
	end
	if (root.Position - rec.home).Magnitude > range then
		return false
	end
	if camera == nil then
		return true
	end
	local screen = camera:WorldToViewportPoint(adornee.Position + Vector3.new(0, rec.tagOffset, 0))
	if screen.Z <= 0.1 then
		return false -- behind the camera: nobody would see it
	end
	local bx, by, bw, bh = boardRect(rec, camera, focal)
	if bx == nil then
		return true
	end
	local _, tagHeight = ManagerTags.tagPixels(focal, screen.Z, tagDevice, rec.tagWidth)
	local w, h = ManagerTags.bubblePixels(focal, screen.Z, tagDevice, chars)
	local centreX = screen.X + rec.nudgeTarget * focal / screen.Z
	local centreY = screen.Y - tagHeight - h * BubbleCfg.Gap - h / 2
	return not ManagerTagLogic.overlaps(centreX, centreY, w, h, bx, by, bw, bh, TagCfg.YieldMargin)
end

--[[
	Bubble pass (every RefreshInterval): for each plot of the local player, end the current bubble
	when its time is up or its manager can no longer speak, else, when the plot's scheduler is due,
	let one eligible manager say a line (ManagerTagLogic picks who + what). Other players'
	managers never speak.
]]
local function updateBubbles(clock: number, camera: Camera?, focal: number)
	local root = localRoot()
	table.clear(minePlots)
	for _, rec in recordList do
		local plot = rec.plot
		if rec.mine and plot ~= nil then
			minePlots[plot] = true
		end
	end
	for plot in minePlots do
		local current = plotBubbles[plot]
		if current == nil then
			-- Seeded by the local player + plot, so plots never speak in lock-step.
			local seed = ManagerTagLogic.hash(`{Players.LocalPlayer.UserId}|{plot.Name}|bubble`)
			local fresh: PlotBubble = {
				scheduler = ManagerTagLogic.newScheduler(seed, clock, BubbleCfg),
				rec = nil,
				visual = nil,
				line = "",
			}
			plotBubbles[plot] = fresh
			current = fresh
		end
		local scheduler = current.scheduler
		local speaking = current.rec
		if speaking ~= nil then
			local keepRange = BubbleCfg.NearRange * BUBBLE_KEEP_FACTOR
			if
				not ManagerTagLogic.showing(scheduler, clock)
				or not canSpeak(speaking, root, keepRange, camera, focal, #current.line)
			then
				hideBubbleOf(speaking)
			end
		elseif ManagerTagLogic.due(scheduler, clock) and root ~= nil then
			table.clear(speakerRecs)
			table.clear(speakerKeys)
			for _, rec in recordList do
				if rec.plot == plot and canSpeak(rec, root, BubbleCfg.NearRange, camera, focal, TYPICAL_LINE_CHARS) then
					table.insert(speakerRecs, rec)
					table.insert(speakerKeys, rec.key)
				end
			end
			local rec = speakerRecs[ManagerTagLogic.choose(scheduler, speakerKeys)]
			local tag = if rec ~= nil then rec.tag else nil
			if rec ~= nil and tag ~= nil then
				local line = ManagerTagLogic.chooseLine(scheduler, rec.lines)
				local visual = if line ~= "" then ManagerTags.acquireBubble() else nil
				if visual ~= nil then
					ManagerTags.showBubble(visual, tag, line, reduced)
					current.rec = rec
					current.visual = visual
					current.line = line
					ManagerTagLogic.started(scheduler, clock, BubbleCfg, rec.key, line)
				end
			end
		end
	end
end

--[[
	Every RefreshInterval: reduced-motion + tier, camera ranking, active set, owner + producer links.
	Managers leaving the active set settle into their rest pose (one BulkMoveTo).
]]
local function refresh()
	reduced = isReduced()
	local tierName = FxQuality.tier()
	local tier = ManagerNpcConfig.Tiers[tierName] or ManagerNpcConfig.Tiers.Mid
	sparkleTier = Fx.SparkleTiers[tierName] == true
	tierNow = tierName
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera ~= nil then camera.CFrame.Position else Vector3.zero
	viewCos = -1
	if camera ~= nil and camera.ViewportSize.Y > 0 then
		local viewport = camera.ViewportSize
		viewCos = ViewCone.cosLimit(camera.FieldOfView, viewport.X / viewport.Y, ManagerNpcConfig.ViewMarginDeg)
	end
	local clock = os.clock()
	table.clear(ranked)
	for _, rec in recordList do
		rec.wantActive = false
		rec.distance = (rec.home - cameraPosition).Magnitude
		if rec.distance <= tier.Range and clock >= rec.holdUntil then
			table.insert(ranked, rec)
		end
	end
	table.sort(ranked, nearerFirst)
	for index = 1, math.min(#ranked, tier.MaxActive) do
		local rec = ranked[index]
		rec.wantActive = true
		rec.halfRate = rec.distance > tier.HalfRateBeyond
	end
	table.clear(activeList)
	for _, rec in recordList do
		if rec.wantActive then
			if not rec.active then
				rec.active = true
				rec.accum = 0
			end
			table.insert(activeList, rec)
			rec.ownerRoot = ownerRootOf(rec.plot)
			if rec.anchorInfo == nil and rec.plot ~= nil then
				local byArea = anchorsByPlot[rec.plot]
				rec.anchorInfo = if byArea ~= nil then byArea[rec.areaIndex] else nil
			end
			local info = rec.anchorInfo
			if info ~= nil and info.anchor.Parent ~= nil then
				local p = rec.pivot:PointToObjectSpace(info.anchor.Position)
				rec.input.producerValid = true
				rec.input.producerX = p.X
				rec.input.producerZ = p.Z
			else
				rec.input.producerValid = false
			end
		elseif rec.active then
			rec.active = false
			settle(rec)
		end
	end
	flush()
	-- Owner R87: nametags + speech bubbles ride the same pass (never per frame).
	local focal = 0
	if camera ~= nil and camera.ViewportSize.Y > 0 then
		focal = camera.ViewportSize.Y / (2 * math.tan(math.rad(camera.FieldOfView) / 2))
	end
	local tagCamera = if focal > 0 then camera else nil
	updateTags(clock, tagCamera, focal)
	updateBubbles(clock, tagCamera, focal)
end

local function onHeartbeat(dt: number)
	refreshClock += dt
	if refreshClock >= ManagerNpcConfig.RefreshInterval then
		refreshClock = 0
		refresh()
	end
	if #easingList > 0 then
		stepNudges(dt)
	end
	if #activeList == 0 then
		return
	end
	frameCount += 1
	soundBudget = 1
	sparkleBudget = 1
	local now = Workspace:GetServerTimeNow()
	local camera = Workspace.CurrentCamera
	local cameraFrame = if camera ~= nil then camera.CFrame else CFrame.identity
	local cameraAt, look = cameraFrame.Position, cameraFrame.LookVector
	for _, rec in activeList do
		rec.accum += dt
		if not rec.halfRate or (frameCount + rec.slot) % 2 == 0 then
			local visible = ViewCone.visible(rec.home - cameraAt, look, viewCos, ManagerNpcConfig.AlwaysMoveWithin)
			animate(rec, rec.accum, now, visible)
			rec.accum = 0
		end
	end
	flush()
end

-- Connects / disconnects the single Heartbeat as managers come and go.
local function updateHeartbeat()
	if #recordList > 0 and heartbeat == nil then
		refreshClock = ManagerNpcConfig.RefreshInterval -- refresh on the first frame
		heartbeat = RunService.Heartbeat:Connect(onHeartbeat)
	elseif #recordList == 0 and heartbeat ~= nil then
		heartbeat:Disconnect()
		heartbeat = nil
		table.clear(activeList)
	end
end

---------------------------------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------------------------------

local function unregister(model: Model)
	local rec = records[model]
	if rec == nil then
		return
	end
	records[model] = nil
	for _, connection in rec.connections do
		connection:Disconnect()
	end
	if rec.stars ~= nil then
		rec.stars:Destroy()
		rec.stars = nil
	end
	-- Owner R87: its bubble ends and its tag goes back to the pool (never kept on a dead part).
	hideBubbleOf(rec)
	local easing = table.find(easingList, rec)
	if easing ~= nil then
		table.remove(easingList, easing)
	end
	if rec.tag ~= nil then
		ManagerTags.release(rec.tag)
		rec.tag = nil
		rec.tagShown = false
	end
	local index = table.find(recordList, rec)
	if index ~= nil then
		recordList[index] = recordList[#recordList]
		recordList[#recordList] = nil
	end
	local activeIndex = table.find(activeList, rec)
	if activeIndex ~= nil then
		table.remove(activeList, activeIndex)
	end
	updateHeartbeat()
end

local register: (model: Model) -> ()

-- Builds the record of one spawned manager mesh model (parts at their server rest CFrames).
function register(model: Model)
	if records[model] ~= nil or not model:IsDescendantOf(Workspace) then
		return
	end
	local key = model:GetAttribute("MeshKey")
	if type(key) ~= "string" then
		return
	end
	local rig = ManagerNpcConfig.Rigs[key]
	if rig == nil or #rig.waypoints == 0 then
		return
	end
	local pivot = model.WorldPivot
	local figureRest = CFrame.new(rig.figure.base) * CFrame.Angles(0, math.rad(rig.figure.yaw), 0)
	local figureWorld = pivot * figureRest
	local parts: { BasePart } = {}
	local rels: { CFrame } = {}
	local slots: { number } = {}
	local hasGroup: { boolean } = { false, false, false, false, false, false }
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") then
			local group = ManagerNpcConfig.groupOf(child.Name)
			local slot = if group ~= nil then GROUP_SLOT[group] else nil
			if slot ~= nil then
				local rest: CFrame = figureWorld:ToObjectSpace(child.CFrame)
				table.insert(parts, child)
				table.insert(rels, rest)
				table.insert(slots, slot)
				hasGroup[slot] = true
			end
		end
	end
	if #parts == 0 then
		return -- an un-rigged (pre-R30) mesh: nothing to animate
	end
	local jointPos: { CFrame } = {}
	local jointNeg: { CFrame } = {}
	local hands: { Vector3 } = {}
	local groupCF: { CFrame } = {}
	for slot, group in ManagerNpcConfig.Groups do
		local joint = rig.joints[group]
		local localJoint = if joint ~= nil then figureRest:PointToObjectSpace(joint) else Vector3.zero
		jointPos[slot] = CFrame.new(localJoint)
		jointNeg[slot] = CFrame.new(-localJoint)
		hands[slot] = localJoint + HAND_DROP
		groupCF[slot] = figureWorld
	end
	hands[TORSO] = (jointPos[TORSO] * Vector3.new(0, 1.2, -0.9)) -- chest front (rigs without arms)
	local container = model.Parent
	local areaIndex = if container ~= nil then numberAttr(container, Attr.AreaIndex) else nil
	local holdUntil = 0
	local stamp = if container ~= nil then numberAttr(container, "BuildIn") else nil
	if stamp ~= nil then
		local age = Workspace:GetServerTimeNow() - stamp
		if age >= 0 and age < Motion.BuildHoldSeconds then
			holdUntil = os.clock() + (Motion.BuildHoldSeconds - age)
		end
	end
	seedCounter += 1
	-- Owner R87 nametag: owner, what it says, where it rides.
	local plot = TycoonWorld.plotOf(model)
	local ownerId = if plot ~= nil then numberAttr(plot, Attr.OwnerUserId) else nil
	local localPlayer = Players.LocalPlayer
	local mine = ownerId ~= nil and ownerId ~= 0 and localPlayer ~= nil and ownerId == localPlayer.UserId
	-- Name seed: the owner (Studio test players have negative ids); the plot slot when unowned.
	local plotIndex = if plot ~= nil then numberAttr(plot, Attr.PlotIndex) else nil
	local ownerSeed = if ownerId ~= nil and ownerId ~= 0 then ownerId else plotIndex or 0
	local keyWorld = WorldLookup.worldOfBuildKey(key)
	local tagRow = ManagerTagConfig.Managers[key]
	local tagAdornee, tagOffset = tagAnchorOf(parts, slots, hasGroup[HEAD])
	local tagInfo = describeTag(key, keyWorld, ownerSeed)
	local rec: Record = {
		model = model,
		container = container,
		key = key,
		rig = rig,
		plot = plot,
		worldId = TycoonWorld.worldOf(model),
		areaIndex = areaIndex or 0,
		pivot = pivot,
		home = figureWorld.Position,
		parts = parts,
		rels = rels,
		slots = slots,
		hasGroup = hasGroup,
		jointPos = jointPos,
		jointNeg = jointNeg,
		hands = hands,
		groupCF = groupCF,
		brain = NpcBrain.new(rig, Motion, seedCounter * 7919 + (areaIndex or 0) * 31),
		pose = NpcPose.new(),
		input = NpcBrain.newInput(),
		anchorInfo = nil,
		lastCycle = nil,
		ownerRoot = nil,
		holdUntil = holdUntil,
		active = false,
		wantActive = false,
		halfRate = false,
		slot = seedCounter % 2,
		accum = 0,
		distance = math.huge,
		connections = {},
		dazed = false,
		-- Sitting: the hips (LegL joint height above the figure base) drop to just off the floor.
		sitDrop = if rig.style == "Hover"
			then DAZED_HOVER_SAG
			else math.max(((rig.joints.LegL or rig.joints.Torso or Vector3.zero).Y - rig.figure.base.Y) - 0.45, 0),
		stars = nil,
		starLabels = {},
		mine = mine,
		tagInfo = tagInfo,
		tagAdornee = tagAdornee,
		tagOffset = tagOffset,
		tag = nil,
		tagShown = false,
		tagYield = false,
		tagClear = 0,
		tagWidth = tagWidthOf(tagInfo),
		nudgeTarget = 0,
		nudgeShown = 0,
		-- Robots (robot-named hires) and the Moon crew add the beep-boop lines.
		lines = linesOf(keyWorld, (tagRow ~= nil and tagRow.pool == "robot") or keyWorld == "moon"),
	}
	records[model] = rec
	table.insert(recordList, rec)
	if rec.plot ~= nil and isAreaDazed(rec.plot :: Model, rec.areaIndex) then
		setRecordDazed(rec, true) -- streamed in / hired while its area is knocked down
	end
	table.insert(
		rec.connections,
		model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(Workspace) then
				unregister(model)
			end
		end)
	)
	-- A late-replicating rig piece rebuilds the record (rest offsets must cover every piece).
	table.insert(
		rec.connections,
		model.ChildAdded:Connect(function(child: Instance)
			if child:IsA("BasePart") and ManagerNpcConfig.groupOf(child.Name) ~= nil then
				unregister(model)
				task.defer(register, model)
			end
		end)
	)
	updateHeartbeat()
end

-- Cheap filter for every streamed descendant of any world's plots folder.
local function onDescendantAdded(instance: Instance)
	if instance.ClassName ~= "Model" or not ManagerNpcConfig.ownsModel(instance.Name) then
		return
	end
	-- Defer one frame: the rest of the Atomic model replicates in the same batch.
	task.defer(register, instance :: Model)
end

--[[
	A purchase finished building on some plot: its managers hop (staggered); a manager's own
	build-in finishing releases its hold so it starts moving at once.
]]
local function onBuildFinished(model: Model, info: any)
	local age = if type(info) == "table" and type(info.age) == "number" then info.age else math.huge
	local plot = TycoonWorld.plotOf(model)
	if plot == nil then
		return
	end
	local order = 0
	for _, rec in recordList do
		if rec.plot == plot then
			if rec.container == model then
				rec.holdUntil = 0
			end
			if age <= Motion.HopWindow and (rec.active or rec.container == model) then
				NpcBrain.requestHop(rec.brain, order * Motion.HopStagger)
				order += 1
			end
		end
	end
end

-- Hooks one world's plots folder (PlotFolders hands each folder over exactly once).
local function watchPlots(folder: Instance, _worldId: string)
	folder.DescendantAdded:Connect(onDescendantAdded)
	for _, descendant in folder:GetDescendants() do
		onDescendantAdded(descendant)
	end
end

function ManagerController.Init() end

--[[
	Knockdown (owner R50, Tycoon/BuildIn/KnockdownFx): every manager of `plot`'s area `areaIndex`
	sits dazed with orbiting stars (on) or gets back to work where it left off (off). Managers that
	stream in / are hired while the area is down start dazed.
	Example: ManagerController.setAreaDazed(plotModel, 3, true)
]]
function ManagerController.setAreaDazed(plot: Model, areaIndex: number, on: boolean)
	local byArea = dazedAreas[plot]
	if on then
		if byArea == nil then
			byArea = {}
			dazedAreas[plot] = byArea
		end
		(byArea :: { [number]: boolean })[areaIndex] = true
	elseif byArea ~= nil then
		byArea[areaIndex] = nil
		if next(byArea) == nil then
			dazedAreas[plot] = nil
		end
	end
	for _, rec in recordList do
		if rec.plot == plot and rec.areaIndex == areaIndex then
			setRecordDazed(rec, on)
		end
	end
end

-- Starts discovery + producer sync (idempotent).
function ManagerController.Start()
	if started then
		return
	end
	started = true
	TycoonWorld.ProducerAdded:Connect(onProducerAdded)
	TycoonWorld.ProducerRemoved:Connect(onProducerRemoved)
	TycoonWorld.start()
	for _, anchor in TycoonWorld.producers() do
		onProducerAdded(anchor)
	end
	BuildInController.BuildFinished:Connect(onBuildFinished)
	-- Every world's plots folder, now and later (Nuke Town + Dino Valley + any future world).
	PlotFolders.watch(watchPlots)
end

--[[
	Debug / verification snapshot (Studio playtests, admin overlay): registered + animating
	managers, and registered managers per world.
	Example: ManagerController.stats() --> { managers = 5, active = 3, worlds = { dino = 4, main = 1 }, tags = 4, bubbles = 1 }
]]
function ManagerController.stats(): {
	managers: number,
	active: number,
	worlds: { [string]: number },
	tags: number,
	bubbles: number,
}
	local worlds: { [string]: number } = {}
	local tags = 0
	for _, rec in recordList do
		worlds[rec.worldId] = (worlds[rec.worldId] or 0) + 1
		if rec.tagShown then
			tags += 1
		end
	end
	local bubbles = 0
	for _, state in plotBubbles do
		if state.rec ~= nil then
			bubbles += 1
		end
	end
	return { managers = #recordList, active = #activeList, worlds = worlds, tags = tags, bubbles = bubbles }
end

-- One manager's tag in a tagStats() snapshot.
type TagSnapshot = {
	key: string,
	world: string,
	role: string,
	name: string,
	runs: string,
	shown: boolean,
	yielded: boolean,
	dazed: boolean,
	mine: boolean,
	distance: number,
	nudge: number, -- studs slid sideways clear of the producer board (target)
}
-- One bubble up in a tagStats() snapshot.
type BubbleSnapshot = { plot: string, key: string, line: string }

--[[
	Owner R87 verification snapshot (Studio playtests, tools/qa/manager_tags.py): every registered
	manager's tag (texts, shown / yielded, own) and the bubbles up right now.
	Example: ManagerController.tagStats().list[1] --> { key = "A4_Foreman", role = "Foreman",
		name = "Captain Kaboom", runs = "Glow Rock Drill", shown = true, yielded = false, mine = true, distance = 31 }
]]
function ManagerController.tagStats(): { list: { TagSnapshot }, bubbles: { BubbleSnapshot } }
	local list: { TagSnapshot } = {}
	for _, rec in recordList do
		local info = rec.tagInfo
		table.insert(list, {
			key = rec.key,
			world = rec.worldId,
			role = if info ~= nil then info.role else "",
			name = if info ~= nil then info.name else "",
			runs = if info ~= nil then info.runs else "",
			shown = rec.tagShown,
			yielded = rec.tagYield,
			dazed = rec.dazed,
			mine = rec.mine,
			distance = math.floor(rec.distance),
			nudge = math.floor(rec.nudgeTarget * 100 + 0.5) / 100,
		})
	end
	local bubbles: { BubbleSnapshot } = {}
	for plot, state in plotBubbles do
		local speaking = state.rec
		if speaking ~= nil then
			table.insert(bubbles, { plot = plot.Name, key = speaking.key, line = state.line })
		end
	end
	return { list = list, bubbles = bubbles }
end

--[[
	QA only (Studio captures): makes every own plot's bubble due now, so the next refresh lets an
	eligible manager speak; with `holdSeconds` (<= 60) a bubble already up stays that long instead
	(a device-matrix capture outlasts ShowSeconds). The normal 20-40 s rhythm resumes after it.
	Example: ManagerController.debugBubbleNow() ; task.wait(0.6) ; ManagerController.debugBubbleNow(25)
]]
function ManagerController.debugBubbleNow(holdSeconds: number?)
	local now = os.clock()
	for _, state in plotBubbles do
		if state.rec == nil then
			state.scheduler.nextAt = 0
		elseif holdSeconds ~= nil and holdSeconds == holdSeconds then
			state.scheduler.untilAt = now + math.clamp(holdSeconds, 0, 60)
		end
	end
	refreshClock = ManagerNpcConfig.RefreshInterval
end

-- Debug: the brain state of the nearest registered manager with this key (verification only).
function ManagerController.debugBrain(key: string): NpcBrain.Brain?
	for _, rec in recordList do
		if rec.key == key then
			return rec.brain
		end
	end
	return nil
end

return ManagerController
