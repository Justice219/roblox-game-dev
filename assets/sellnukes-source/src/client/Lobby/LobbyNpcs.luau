--!strict
--[[
	LobbyNpcs — renders the lobby visitors (owner R100 "The lobby feels a little dead, maybe have some
	random roblox npcs like r15 rigs just walk around and talk and stuff").

	What the player sees (client-side only; the server never simulates them):
		6-12 R15 visitors (LobbyNpcConfig.Tiers by FxQuality) in preset outfits stroll the lobby's
		walkways (HubLayout.lobbyWalk), stop at the egg stands / Lucky Wheel / boards to look (and
		cheer / point / laugh), sit on benches, wave at the local player walking past, and say short
		kid-friendly lines in stud speech bubbles (LobbyBubbles). Behaviour = Client/Lobby/
		LobbyNpcLogic (pure); this module owns the Instances.

	Rigs: clones of the server-built templates in ReplicatedStorage.LobbyNpcTemplates (Server/World/
	LobbyNpcService builds them once with Players:CreateHumanoidModelFromDescriptionAsync — that API
	is server-side). Each clone lives in the client-only Workspace.LobbyVisitors folder:
		* every part CanCollide / CanQuery / CanTouch false, Massless (never blocks a player, never hit
		  by raycasts: the attack aim, camera and click systems cannot target them), CastShadow per tier
		* the HumanoidRootPart is ANCHORED and moved with one Workspace:BulkMoveTo per frame for all
		  shown visitors; the Animator plays Roblox's default R15 clips (walk / idle / sit / emotes)
		* Humanoid: no name / health display, EvaluateStateMachine off (no physics state machine cost)

	Performance (owner R11, console + mobile first):
		* ONE step per frame from Client/Lobby/LobbyController's Heartbeat; a RefreshInterval pass
		  decides world / enable flag / tier / culling / bubbles.
		* Culling: a visitor farther than the tier Range (+ hysteresis) from the camera is parented to
		  nil (no render, no animation); outside Nuke Town every visitor is hidden and the brains
		  pause. No per-frame Instance.new; arrays for BulkMoveTo are reused.
		* Reduced motion: visitors hold still (idle / sitting), no emotes, bubbles appear without pop.
	Admin (owner rule 9): ReplicatedStorage attribute LobbyNpcsEnabled (the admin "LobbyNpcs" command,
	Server/World/LobbyNpcService) false → every visitor is removed on this server.

	Connects to: Shared/Config/{LobbyNpcConfig, HubLayout}, Client/Lobby/{LobbyNpcLogic, LobbyBubbles},
	Tycoon/Fx/FxQuality, Worlds/WorldClient, UI/ScreenManager (device class), ClientState.

	Example (Studio console, client):
		local npcs = require(game.Players.LocalPlayer.PlayerScripts.Client.Lobby.LobbyNpcs)
		print(npcs.stats()) --> { visitors = 9, shown = 6, bubbles = 1, tier = "Mid", ... }
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.Parent.ClientState)
local FxQuality = require(script.Parent.Parent.Tycoon.Fx.FxQuality)
local HubLayout = require(ReplicatedStorage.Shared.Config.HubLayout)
local LobbyBubbles = require(script.Parent.LobbyBubbles)
local LobbyNpcConfig = require(ReplicatedStorage.Shared.Config.LobbyNpcConfig)
local LobbyNpcLogic = require(script.Parent.LobbyNpcLogic)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local WorldClient = require(script.Parent.Parent.Worlds.WorldClient)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local LOCAL = Players.LocalPlayer
local Bubble = LobbyNpcConfig.Bubble

type Base = "walk" | "idle" | "sit"

-- One rendered visitor.
type Visitor = {
	npc: LobbyNpcLogic.Npc,
	model: Model,
	root: BasePart,
	head: BasePart?,
	standHeight: number, -- HipHeight + half the root's height: root centre above the floor
	tracks: { [string]: AnimationTrack },
	base: Base?,
	walkRate: number?,
	shown: boolean,
	bubble: LobbyBubbles.BubbleVisual?,
	bubbleUntil: number,
}

local LobbyNpcs = {}

local random = Random.new()
local function rand(): number
	return random:NextNumber()
end

local folder: Folder? = nil
local crowd: LobbyNpcLogic.Crowd? = nil
local visitors: { Visitor } = {}
local tierName: string = "Mid"
local refreshAccum = math.huge
local active = false -- in Nuke Town + enabled + templates ready + a crowd exists
local speakState: LobbyNpcLogic.SpeakState = { recent = {} }
local nextBubbleAt = 0
local busy: { [number]: boolean } = {}
local bubbleCount = 0

-- Reused BulkMoveTo arrays (no per-frame tables).
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

-- Reduced motion: the Roblox accessibility setting or SellNukes' own setting.
local function isReduced(): boolean
	if GuiService.ReducedMotionEnabled then
		return true
	end
	local profile = ClientState.profile
	local settings = profile and (profile :: any).settings
	return type(settings) == "table" and settings.reducedMotion == true
end

-- The local character's root position (nil while dead / loading).
local function playerPosition(): Vector3?
	local character = LOCAL.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root.Position else nil
end

-- The server-built template folder once it is complete (nil before).
local function templateFolder(): Instance?
	local templates = ReplicatedStorage:FindFirstChild(LobbyNpcConfig.TemplateFolder)
	if templates == nil or templates:GetAttribute(LobbyNpcConfig.ReadyAttribute) ~= true then
		return nil
	end
	return templates
end

-- True unless the admin switched the visitors off on this server.
local function enabled(): boolean
	return ReplicatedStorage:GetAttribute(LobbyNpcConfig.EnabledAttribute) ~= false
end

-- Hides / pools a visitor's bubble.
local function dropBubble(visitor: Visitor)
	local bubble = visitor.bubble
	if bubble ~= nil then
		visitor.bubble = nil
		busy[visitor.npc.id] = nil
		bubbleCount -= 1
		LobbyBubbles.release(bubble)
	end
end

-- Loads one looped / one-shot clip on the visitor's Animator.
local function loadTrack(
	animator: Animator,
	id: string,
	priority: Enum.AnimationPriority,
	looped: boolean
): AnimationTrack
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local track = animator:LoadAnimation(animation)
	track.Priority = priority
	track.Looped = looped
	return track
end

--[[
	Prepares a fresh clone: strips scripts, makes every part non-colliding / non-queryable, anchors
	the root, quiets the Humanoid. Returns nil when the rig is incomplete.
]]
local function prepare(model: Model, castShadow: boolean): (BasePart?, Humanoid?)
	local root = model:FindFirstChild("HumanoidRootPart")
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if root == nil or not root:IsA("BasePart") or humanoid == nil then
		return nil, nil
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
			descendant.CastShadow = castShadow
		elseif descendant:IsA("LuaSourceContainer") then
			descendant:Destroy()
		end
	end
	root.Anchored = true
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	humanoid.EvaluateStateMachine = false
	return root, humanoid
end

-- Removes every visitor (world change, admin off, tier change).
local function despawnAll()
	for _, visitor in visitors do
		dropBubble(visitor)
		visitor.model:Destroy()
	end
	table.clear(visitors)
	table.clear(busy)
	bubbleCount = 0
	crowd = nil
	active = false
end

--[[
	Builds the crowd: `count` visitors from the templates (preset order, so a small tier still gets a
	varied set). Clones are parented once so their Animators can load clips, then culled normally.
]]
local function spawnAll(templates: Instance, count: number)
	local parent = folder
	if parent == nil then
		return
	end
	local graph = (HubLayout :: any).lobbyWalk :: LobbyNpcLogic.Graph
	if type(graph) ~= "table" or #graph.nodes == 0 then
		return
	end
	local tier = LobbyNpcConfig.Tiers[tierName] or LobbyNpcConfig.Tiers.Mid
	local list: { Model } = {}
	for _, preset in LobbyNpcConfig.Presets do
		local template = templates:FindFirstChild(`LobbyNpc_{preset.id}`)
		if template ~= nil and template:IsA("Model") then
			table.insert(list, template)
		end
		if #list >= count then
			break
		end
	end
	local made = LobbyNpcLogic.newCrowd(graph, #list, rand)
	for index, template in list do
		local model = template:Clone()
		local root, humanoid = prepare(model, tier.CastShadow)
		local npc = made.npcs[index]
		if root == nil or humanoid == nil or npc == nil then
			model:Destroy()
			continue
		end
		model.Name = `Visitor_{index}`
		model.Parent = parent
		local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
		animator.Parent = humanoid
		local anims = LobbyNpcConfig.Animations
		local tracks: { [string]: AnimationTrack } = {
			walk = loadTrack(animator, anims.walk, Enum.AnimationPriority.Movement, true),
			idle = loadTrack(animator, anims.idle, Enum.AnimationPriority.Idle, true),
			look = loadTrack(animator, anims.look, Enum.AnimationPriority.Idle, true),
			sit = loadTrack(animator, anims.sit, Enum.AnimationPriority.Movement, true),
			wave = loadTrack(animator, anims.wave, Enum.AnimationPriority.Action, false),
			cheer = loadTrack(animator, anims.cheer, Enum.AnimationPriority.Action, false),
			point = loadTrack(animator, anims.point, Enum.AnimationPriority.Action, false),
			laugh = loadTrack(animator, anims.laugh, Enum.AnimationPriority.Action, false),
		}
		local head = model:FindFirstChild("Head")
		table.insert(visitors, {
			npc = npc,
			model = model,
			root = root,
			head = if head ~= nil and head:IsA("BasePart") then head else nil,
			standHeight = humanoid.HipHeight + root.Size.Y / 2,
			tracks = tracks,
			base = nil,
			walkRate = nil,
			shown = true,
			bubble = nil,
			bubbleUntil = 0,
		})
	end
	-- Keep only the npcs that got a rig (a failed clone leaves no ghost brain behind).
	local kept: { LobbyNpcLogic.Npc } = {}
	for _, visitor in visitors do
		table.insert(kept, visitor.npc)
	end
	made.npcs = kept
	crowd = made
	active = #visitors > 0
	nextBubbleAt = os.clock() + Bubble.FirstDelay
end

-- Which looping clip a visitor's state wants.
local function baseOf(npc: LobbyNpcLogic.Npc): Base
	if npc.seat ~= nil and npc.seatPhase >= 0.5 then
		return "sit"
	end
	local mode = npc.mode
	if mode == "walk" or ((mode == "toSeat" or mode == "fromSeat") and npc.seatPhase <= 0) then
		return "walk"
	end
	return "idle"
end

-- Switches the looping clip (and the walk rate) only on change.
local function applyBase(visitor: Visitor, base: Base)
	local npc = visitor.npc
	if visitor.base ~= base then
		local previous = visitor.base
		if previous == "walk" then
			visitor.tracks.walk:Stop(0.2)
		elseif previous == "sit" then
			visitor.tracks.sit:Stop(0.25)
		elseif previous == "idle" then
			visitor.tracks.idle:Stop(0.3)
			visitor.tracks.look:Stop(0.3)
		end
		visitor.base = base
		visitor.walkRate = nil
		if base == "idle" then
			-- Now and then the look-around idle instead of the plain one.
			local track = if random:NextNumber() < 0.3 then visitor.tracks.look else visitor.tracks.idle
			track:Play(0.3)
		elseif base == "sit" then
			visitor.tracks.sit:Play(0.25)
		else
			visitor.tracks.walk:Play(0.2)
		end
	end
	if base == "walk" and visitor.walkRate ~= npc.speed then
		visitor.walkRate = npc.speed
		visitor.tracks.walk:AdjustSpeed(npc.speed / LobbyNpcConfig.WalkAnimStudsPerSecond)
	end
end

-- Shows / hides one visitor (parent swap, only on change).
local function setShown(visitor: Visitor, shown: boolean)
	if visitor.shown == shown then
		return
	end
	visitor.shown = shown
	visitor.model.Parent = if shown then folder else nil
	if not shown then
		dropBubble(visitor)
	end
end

-- The bubble scheduler (in the refresh pass): expiries, then maybe one new line.
local function updateBubbles(now: number, playerPos: Vector3?)
	for _, visitor in visitors do
		if visitor.bubble ~= nil and now >= visitor.bubbleUntil then
			dropBubble(visitor)
		end
	end
	local current = crowd
	local tier = LobbyNpcConfig.Tiers[tierName] or LobbyNpcConfig.Tiers.Mid
	if current == nil or playerPos == nil or now < nextBubbleAt or bubbleCount >= tier.Bubbles then
		return
	end
	nextBubbleAt = now + Bubble.IntervalMin + random:NextNumber() * (Bubble.IntervalMax - Bubble.IntervalMin)
	local index, line = LobbyNpcLogic.pickSpeaker(current, playerPos, busy, speakState, #LobbyNpcConfig.Lines, rand)
	if index == nil or line == nil then
		return
	end
	local visitor = visitors[index]
	if visitor == nil or not visitor.shown or visitor.head == nil then
		return
	end
	local bubble = LobbyBubbles.acquire()
	if bubble == nil then
		return
	end
	visitor.bubble = bubble
	visitor.bubbleUntil = now + Bubble.ShowSeconds
	busy[visitor.npc.id] = true
	bubbleCount += 1
	local device = ScreenManager.device.class ~= "Desktop"
	LobbyBubbles.show(bubble, visitor.head :: BasePart, LobbyNpcConfig.Lines[line], device, isReduced())
end

-- The RefreshInterval pass: world / flag / tier / templates → (de)spawn; culling; bubbles.
local function refresh()
	local inMain = WorldClient.current() == WorldsConfig.MAIN
	local tier = FxQuality.tier()
	local wanted = (LobbyNpcConfig.Tiers[tier] or LobbyNpcConfig.Tiers.Mid).Count
	if not enabled() then
		if #visitors > 0 then
			despawnAll()
		end
		return
	end
	if tier ~= tierName then
		tierName = tier
		if #visitors > 0 then
			despawnAll() -- respawn at the new tier's budget below
		end
	end
	if #visitors == 0 and inMain then
		local templates = templateFolder()
		if templates ~= nil then
			spawnAll(templates, wanted)
		end
	end
	if #visitors == 0 then
		active = false
		return
	end
	active = inMain
	local camera = Workspace.CurrentCamera
	local eye = if camera ~= nil then camera.CFrame.Position else nil
	local range = (LobbyNpcConfig.Tiers[tierName] or LobbyNpcConfig.Tiers.Mid).Range
	for _, visitor in visitors do
		local show = false
		if inMain and eye ~= nil then
			local limit = if visitor.shown then range + LobbyNpcConfig.RangeHysteresis else range
			show = (visitor.npc.pos - eye).Magnitude <= limit
		end
		setShown(visitor, show)
	end
	if inMain then
		updateBubbles(os.clock(), playerPosition())
	else
		for _, visitor in visitors do
			dropBubble(visitor)
		end
	end
end

--[[
	Advances the visitors one frame (LobbyController's Heartbeat): brains for everyone while in Nuke
	Town, then clips + one BulkMoveTo for the shown ones.
]]
function LobbyNpcs.step(dt: number)
	refreshAccum += dt
	if refreshAccum >= LobbyNpcConfig.RefreshInterval then
		refreshAccum = 0
		refresh()
	end
	local current = crowd
	if not active or current == nil then
		return
	end
	local reduced = isReduced()
	LobbyNpcLogic.step(current, dt, playerPosition(), reduced, rand)
	table.clear(moveParts)
	table.clear(moveCFrames)
	for _, visitor in visitors do
		if not visitor.shown then
			continue
		end
		local npc = visitor.npc
		applyBase(visitor, baseOf(npc))
		local emote = npc.emote
		if emote ~= nil then
			npc.emote = nil
			local track = visitor.tracks[emote]
			if track ~= nil and not reduced then
				track:Play(0.15)
			end
		end
		local base, yaw, blend = LobbyNpcLogic.pose(current, npc)
		local height = visitor.standHeight + (LobbyNpcConfig.SitRootHeight - visitor.standHeight) * blend
		table.insert(moveParts, visitor.root)
		table.insert(moveCFrames, CFrame.new(base.X, base.Y + height, base.Z) * CFrame.Angles(0, yaw, 0))
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

--[[ Creates the client-only folder (idempotent); the first refresh spawns once templates exist. ]]
function LobbyNpcs.start()
	if folder ~= nil then
		return
	end
	local created = Instance.new("Folder")
	created.Name = LobbyNpcConfig.ClientFolder
	created.Parent = Workspace
	folder = created
	tierName = FxQuality.tier()
end

--[[ Debug / QA snapshot (tools/qa/lobby.py). ]]
function LobbyNpcs.stats(): { [string]: any }
	local shown, sitting, walking = 0, 0, 0
	local positions: { string } = {}
	for _, visitor in visitors do
		if visitor.shown then
			shown += 1
		end
		if visitor.base == "sit" then
			sitting += 1
		elseif visitor.base == "walk" then
			walking += 1
		end
		local p = visitor.npc.pos
		table.insert(positions, string.format("%.0f,%.0f", p.X, p.Z))
	end
	return {
		visitors = #visitors,
		shown = shown,
		sitting = sitting,
		walking = walking,
		bubbles = bubbleCount,
		tier = tierName,
		active = active,
		enabled = enabled(),
		templatesReady = templateFolder() ~= nil,
		positions = positions,
	}
end

--[[
	QA: the nearest visitor to `position` (its model) — lets a capture runner frame a visitor.
	@return Model?
]]
function LobbyNpcs.nearest(position: Vector3): Model?
	local best: Model? = nil
	local bestDistance = math.huge
	for _, visitor in visitors do
		local distance = (visitor.npc.pos - position).Magnitude
		if distance < bestDistance then
			best, bestDistance = visitor.model, distance
		end
	end
	return best
end

--[[ QA: forces the next bubble now (next refresh pass). ]]
function LobbyNpcs.speakSoon()
	nextBubbleAt = 0
end

return LobbyNpcs
