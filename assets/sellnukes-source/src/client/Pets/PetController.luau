--!strict
--[[
	PetController — the client half of pets (boot entry "Pets/PetController", after UIController).

	1. FOLLOWERS: every player's equipped pets follow them, rendered locally from the replicated
	   Player attribute PetConfig.Attribute ("SNPets" = "id,id,..."; the server sends no per-frame
	   data). ONE RenderStepped step moves every visible pet with ONE workspace:BulkMoveTo:
	     - formation arcs behind the owner (PetFollow.slotOffset), frame-rate independent smoothing
	       of the base position (ground + species hover);
	     - ANIMATION (owner R44, PetAnim): every pet is rigged from its piece names (Head* / Tail* /
	       WingL/R* / ClawL/R* / Orbit*) and posed every frame on top of the smoothed base: walkers
	       waddle + bounce with squash-stretch, hoppers hop, flyers flap + bank, swimmers paddle,
	       floaters pulse + drift, tails wag, rings spin, glows pulse; idle breathing / looking
	       around / random cute actions; a happy spin + hearts (PetEmotes) on the owner's purchase,
	       hatch or equip; a sleepy pose + Zzz when the owner is AFK for Sleep.After seconds;
	     - DETAIL per owner (PetAnimConfig.Tiers via FxQuality, decided in the culling pass):
	       Full near the camera (budget MaxFull, your pets first), Simple (body bob + wings — the
	       whole Low tier), Off far away (rigid, no pose maths). Reduce Motion = gentle idle only;
	     - ground height by a downward raycast per pet every Follow.GroundRayEvery frames
	       (staggered), cached in between;
	     - culling pass every CULL_INTERVAL s (not per frame): other players' pets beyond
	       Follow.CullDistance, beyond the Follow.MaxOtherPets budget (nearest first) or hidden by the
	       "hide other players' pets" setting (profile.settings.hideOtherPets) are unparented (kept
	       for reuse, zero render cost); far / respawning owners snap instead of sliding; AFK
	       samples (root movement; your own input too) and the Zzz bubbles are refreshed here;
	     - models are rebuilt only when an owner's equipped ids change (diffed per slot) or a
	       species' meshes finish loading (PetModels.Ready; the pose state carries over).
	2. STANDS: StandClient adds the stud-UI odds billboards to the egg stands and bobs the display
	   eggs near the player; ProximityPrompts open the EggHatch / CrateShop screens, and near a
	   stand the B16 Platform "Egg" context binds the Hatch action (E / gamepad X / HATCH touch
	   button) to the same window.
	3. ROUTING: server pet grants (HatchResult id 0, `granted`) play the reveal; a Robux crate
	   (PurchaseGranted kind "Crate") opens the CrateOpen screen with the held crate ready; the HUD
	   Pets button shows a badge while eggs / crates are held or a Pet Index milestone is ready to
	   claim (owner R78, PetIndexConfig.claimable).

	Happy triggers: any player's fresh purchase build (PlotWatcher.BuildAdded, younger than
	Happy.FreshBuild), any player's equip change (new pets in their SNPets attribute), your hatch
	(after the reveal closes) and your Robux purchases (ClientState.PurchaseGranted).

	Connects to: Client/Pets/{PetModels, PetFollow, PetAnim, PetEmotes, PetRequests, StandClient},
	Client/ClientState, Client/Tycoon/Fx/{FxQuality, PlotWatcher}, UI/ScreenManager, UI/Hud/Hud,
	UI/Screens/EggHatch/HatchFlow, Shared/Config/{PetConfig, PetAnimConfig, CrateConfig}.

	Example: (boot) PetController.Init(); PetController.Start()
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.Parent.ClientState)
local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig) -- owner R89 ship switch (badge)
local FlavorLogic = require(ReplicatedStorage.Shared.Tycoon.FlavorLogic) -- owner R89 Book rewards (badge)
local FxQuality = require(script.Parent.Parent.Tycoon.Fx.FxQuality)
local Hud = require(script.Parent.Parent.UI.Hud.Hud)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local PetAnim = require(script.Parent.PetAnim)
local PetAnimConfig = require(ReplicatedStorage.Shared.Config.PetAnimConfig)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetEmotes = require(script.Parent.PetEmotes)
local PetIndexConfig = require(ReplicatedStorage.Shared.Config.PetIndexConfig)
local PetFollow = require(script.Parent.PetFollow)
local PetModels = require(script.Parent.PetModels)
local PetRequests = require(script.Parent.PetRequests)
local PlotWatcher = require(script.Parent.Parent.Tycoon.Fx.PlotWatcher)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local StandClient = require(script.Parent.StandClient)

local Follow = PetConfig.Follow
local Happy = PetAnimConfig.Happy
local Sleep = PetAnimConfig.Sleep
local LOCAL = Players.LocalPlayer

local OFF = PetAnim.Detail.Off
local SIMPLE = PetAnim.Detail.Simple
local FULL = PetAnim.Detail.Full

-- Seconds between culling / raycast-filter / detail / AFK refreshes.
local CULL_INTERVAL = 0.5
-- Fallback ground offset below the root when a ray finds nothing (≈ R15 hip + root half).
local ROOT_TO_GROUND = 3
-- Within this many studs of a stand's prompt point the "Egg" platform context is on.
local STAND_REACH = 11
-- Emote billboards of your own pets stay visible this far (others use the tier's EmoteRange).
local LOCAL_EMOTE_RANGE = 200
-- Studs above the top of a pet where hearts / Zzz float.
local EMOTE_CLEARANCE = 0.6
-- Seconds after a hatch result before celebrating when no reveal is showing.
local HATCH_NO_REVEAL = 1.5

type PetSlot = {
	petId: string,
	model: Model,
	parts: { BasePart },
	offsets: { CFrame },
	rig: PetAnim.Rig,
	anim: PetAnim.State,
	pose: { CFrame }, -- model-space piece frames written by PetAnim.pose (reused)
	detail: number, -- PetAnim.Detail, set by the culling pass
	hover: number, -- species flying height (0 = ground)
	position: Vector3?, -- smoothed base position (ground + hover), nil = snap next frame
	yaw: number,
	groundY: number?,
	rayIn: number,
}

type Owner = {
	player: Player,
	ids: { string },
	pets: { PetSlot },
	visible: boolean,
	connection: RBXScriptConnection,
	lastActive: number, -- os.clock() of the last movement / input / event
	lastRoot: Vector3?, -- root position at the last AFK sample
	asleep: boolean,
	distance: number, -- camera → owner root at the last culling pass
}

local PetController = {}

local owners: { [Player]: Owner } = {}
local folder: Folder
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

-- Reused per-frame buffers (no per-frame allocation once warm).
local moveParts: { BasePart } = {}
local moveFrames: { CFrame } = {}
local fullSlots: { PetSlot } = {}
local clock = 0
local cullTimer = 0
-- Last local input (keyboard / mouse / touch / gamepad), for the local AFK check.
local localInputAt = os.clock()
-- A hatch result waiting for its reveal to close (os.clock() of the result), or nil.
local pendingHatchAt: number? = nil

--------------------------------------------------------------------------------------------------
-- Settings helpers
--------------------------------------------------------------------------------------------------

local function settings(): { [string]: any }
	local profile = ClientState.profile
	local value = if type(profile) == "table" then profile.settings else nil
	return if type(value) == "table" then value else {}
end

local function reducedMotion(): boolean
	return settings().reducedMotion == true
end

-- The current tier's animation budget.
local function animTier(): PetAnimConfig.Tier
	return PetAnimConfig.Tiers[FxQuality.tier()] or PetAnimConfig.Tiers.Mid
end

--------------------------------------------------------------------------------------------------
-- Owners and their pets
--------------------------------------------------------------------------------------------------

-- A stable seed per owner + slot + species, so a team never moves in lockstep.
local function seedOf(player: Player, petId: string, index: number): number
	local seed = (player.UserId % 100003) * 31 + index * 131
	for position = 1, #petId do
		seed = (seed * 31 + string.byte(petId, position)) % 1000003
	end
	return seed
end

-- Builds one follower slot (model + rig + animation state).
local function buildSlot(player: Player, petId: string, index: number): PetSlot
	local model = PetModels.pet(petId)
	model.Name = `Pet_{petId}`
	local parts, offsets, rig = PetModels.animRig(model)
	local def = PetConfig.get(petId)
	return {
		petId = petId,
		model = model,
		parts = parts,
		offsets = offsets,
		rig = rig,
		anim = PetAnim.newState(seedOf(player, petId, index)),
		pose = table.clone(offsets),
		detail = OFF,
		hover = if def ~= nil then def.hover else 0,
		position = nil,
		yaw = 0,
		groundY = nil,
		rayIn = index % Follow.GroundRayEvery,
	}
end

-- Destroys a slot's model and frees its emotes.
local function destroySlot(slot: PetSlot)
	PetEmotes.release(slot)
	slot.model:Destroy()
end

-- Sets a slot's animation detail; leaving Full puts squashed sizes / pulsed glows back to rest.
local function setDetail(slot: PetSlot, detail: number)
	if slot.detail == detail then
		return
	end
	if slot.detail == FULL then
		PetModels.resetLook(slot.rig, slot.anim, slot.parts)
	end
	slot.detail = detail
end

-- Parents / unparents an owner's pet models.
local function setVisible(owner: Owner, visible: boolean)
	if owner.visible == visible then
		return
	end
	owner.visible = visible
	for _, slot in owner.pets do
		slot.model.Parent = if visible then folder else nil
		-- Snap on reappearing (no slide in from where it was hidden).
		slot.position = nil
		if not visible then
			PetEmotes.release(slot)
			setDetail(slot, OFF)
		end
	end
end

--[[
	Applies a new equipped id list (diffed per slot; unchanged slots keep their model).
	@return true when at least one new pet model was built (an equip, not just a removal)
]]
local function applyIds(owner: Owner, ids: { string }): boolean
	owner.ids = ids
	local added = false
	for index = #owner.pets, #ids + 1, -1 do
		destroySlot(owner.pets[index])
		table.remove(owner.pets, index)
	end
	for index, petId in ids do
		local slot = owner.pets[index]
		if slot == nil or slot.petId ~= petId then
			if slot ~= nil then
				destroySlot(slot)
			end
			local fresh = buildSlot(owner.player, petId, index)
			fresh.model.Parent = if owner.visible then folder else nil
			owner.pets[index] = fresh
			added = true
		end
	end
	if added then
		cullTimer = 0 -- assign the new pets' detail next frame
	end
	return added
end

--[[
	Celebrates on `player`'s pets: staggered happy spins + heart bursts (owner R44). Wakes the team
	up. Pets already mid-spin, hidden or rigid (Off detail) are skipped.
]]
local function celebrate(player: Player)
	local owner = owners[player]
	if owner == nil then
		return
	end
	owner.lastActive = os.clock()
	if owner.asleep then
		owner.asleep = false
		cullTimer = 0 -- drop the Zzz bubbles next frame
	end
	if not owner.visible then
		return
	end
	local isLocal = player == LOCAL
	local tier = animTier()
	local showHearts = isLocal or owner.distance <= tier.EmoteRange
	local range = if isLocal then LOCAL_EMOTE_RANGE else tier.EmoteRange
	for index, slot in owner.pets do
		if slot.detail == OFF or PetAnim.isHappy(slot.anim) then
			continue
		end
		local delay = (index - 1) * Happy.Stagger
		PetAnim.happy(slot.anim, delay)
		local anchor = slot.parts[slot.rig.anchor]
		if showHearts and anchor ~= nil then
			local above = slot.rig.height - slot.offsets[slot.rig.anchor].Position.Y + EMOTE_CLEARANCE
			PetEmotes.hearts(anchor, above, delay, range)
		end
	end
end

-- Starts tracking a player (any player, including the local one).
local function track(player: Player)
	if owners[player] ~= nil then
		return
	end
	local owner: Owner = {
		player = player,
		ids = {},
		pets = {},
		visible = false,
		connection = player:GetAttributeChangedSignal(PetConfig.Attribute):Connect(function()
			local current = owners[player]
			if current ~= nil then
				local added = applyIds(current, PetConfig.decodeEquipped(player:GetAttribute(PetConfig.Attribute)))
				if added then
					-- An equip: the whole team cheers (new pets join in once rendered).
					celebrate(player)
				end
			end
		end),
		lastActive = os.clock(),
		lastRoot = nil,
		asleep = false,
		distance = 0,
	}
	owners[player] = owner
	owner.visible = player == LOCAL
	applyIds(owner, PetConfig.decodeEquipped(player:GetAttribute(PetConfig.Attribute)))
end

local function untrack(player: Player)
	local owner = owners[player]
	if owner == nil then
		return
	end
	owners[player] = nil
	owner.connection:Disconnect()
	for _, slot in owner.pets do
		destroySlot(slot)
	end
end

--[[
	A species finished loading its meshes: rebuild every slot of that species with the real mesh.
	Position, heading and the animation state carry over (no snap, no restarted idle).
]]
local function onMeshReady(key: string)
	for _, owner in owners do
		for index, slot in owner.pets do
			if PetModels.keyOf("pet", slot.petId) == key then
				destroySlot(slot)
				local fresh = buildSlot(owner.player, slot.petId, index)
				fresh.position = slot.position
				fresh.yaw = slot.yaw
				fresh.groundY = slot.groundY
				fresh.anim = slot.anim
				-- The new parts are at rest: reset the look bookkeeping, keep the detail level.
				fresh.anim.lastSx, fresh.anim.lastSy, fresh.anim.lastGlow = 1, 1, 0
				fresh.detail = slot.detail
				fresh.model.Parent = if owner.visible then folder else nil
				owner.pets[index] = fresh
			end
		end
	end
	cullTimer = 0
end

-- The HumanoidRootPart of a player's character, or nil.
local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

--[[
	AFK sample for one owner (every culling pass): root movement beyond Sleep.MoveStuds, or (for
	you) any input, counts as activity; Sleep.After seconds without any → asleep.
]]
local function sampleActivity(owner: Owner, now: number)
	local root = rootOf(owner.player)
	if root ~= nil then
		local position = root.Position
		local last = owner.lastRoot
		if last == nil or (position - last).Magnitude > Sleep.MoveStuds then
			owner.lastActive = now
		end
		owner.lastRoot = position
	end
	if owner.player == LOCAL and localInputAt > owner.lastActive then
		owner.lastActive = localInputAt
	end
	owner.asleep = now - owner.lastActive >= Sleep.After
end

--[[
	Detail + Zzz for one visible owner's pets.
	@param fullBudget remaining Full-detail pet budget
	@return the budget left
]]
local function assignDetail(owner: Owner, tier: PetAnimConfig.Tier, fullBudget: number): number
	local isLocal = owner.player == LOCAL
	local count = #owner.pets
	local detail: number
	if owner.distance <= tier.FullRange and count <= fullBudget then
		detail = FULL
		fullBudget -= count
	elseif isLocal or owner.distance <= tier.SimpleRange then
		detail = SIMPLE
	else
		detail = OFF
	end
	local showZzz = owner.asleep and detail ~= OFF and (isLocal or owner.distance <= tier.EmoteRange)
	local range = if isLocal then LOCAL_EMOTE_RANGE else tier.EmoteRange
	for _, slot in owner.pets do
		setDetail(slot, detail)
		local anchor = slot.parts[slot.rig.anchor]
		if showZzz and anchor ~= nil then
			local above = slot.rig.height - slot.offsets[slot.rig.anchor].Position.Y + EMOTE_CLEARANCE
			PetEmotes.setZzz(slot, anchor, above, true, range)
		else
			PetEmotes.setZzz(slot, nil, 0, false, 0)
		end
	end
	return fullBudget
end

--[[
	Culling pass (every CULL_INTERVAL s): local pets always visible; others by the hide setting,
	distance and the nearest-first pet budget. Also refreshes the raycast exclude list, the AFK
	state, every visible pet's animation detail (nearest first) and the Zzz bubbles.
]]
local function cull()
	local now = os.clock()
	local hideOthers = settings().hideOtherPets == true
	local localRoot = rootOf(LOCAL)
	local camera = Workspace.CurrentCamera
	local eye = if camera ~= nil
		then camera.CFrame.Position
		elseif localRoot ~= nil then localRoot.Position
		else Vector3.zero
	local candidates: { { owner: Owner, distance: number } } = {}
	local exclude: { Instance } = { folder }
	for player, owner in owners do
		local character = player.Character
		if character ~= nil then
			table.insert(exclude, character)
		end
		sampleActivity(owner, now)
		local root = rootOf(player)
		owner.distance = if root ~= nil then (root.Position - eye).Magnitude else math.huge
		if player == LOCAL then
			setVisible(owner, root ~= nil)
		elseif hideOthers or localRoot == nil then
			setVisible(owner, false)
		else
			local distance = if root ~= nil then (root.Position - localRoot.Position).Magnitude else math.huge
			if distance <= Follow.CullDistance and #owner.ids > 0 then
				table.insert(candidates, { owner = owner, distance = distance })
			else
				setVisible(owner, false)
			end
		end
	end
	table.sort(
		candidates,
		function(a: { owner: Owner, distance: number }, b: { owner: Owner, distance: number }): boolean
			return a.distance < b.distance
		end
	)
	local budget = Follow.MaxOtherPets
	for _, candidate in candidates do
		local count = #candidate.owner.ids
		if count <= budget then
			budget -= count
			setVisible(candidate.owner, true)
		else
			setVisible(candidate.owner, false)
		end
	end
	rayParams.FilterDescendantsInstances = exclude

	-- Animation detail: your pets first, then the nearest owners, within the tier's Full budget.
	local tier = animTier()
	local fullBudget = tier.MaxFull
	local localOwner = owners[LOCAL]
	if localOwner ~= nil and localOwner.visible then
		fullBudget = assignDetail(localOwner, tier, fullBudget)
	end
	for _, candidate in candidates do
		if candidate.owner.visible then
			fullBudget = assignDetail(candidate.owner, tier, fullBudget)
		end
	end

	-- A hatch whose reveal never showed (or never closed): celebrate anyway.
	local hatchAt = pendingHatchAt
	if hatchAt ~= nil then
		local age = now - hatchAt
		if (age > HATCH_NO_REVEAL and not ScreenManager.isOpen("HatchReveal")) or age > Happy.HatchFallback then
			pendingHatchAt = nil
			celebrate(LOCAL)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- The one render step
--------------------------------------------------------------------------------------------------

local function step(dt: number)
	clock += dt
	cullTimer -= dt
	if cullTimer <= 0 then
		cullTimer = CULL_INTERVAL
		cull()
	end
	local still = reducedMotion()
	local follow = PetFollow.alpha(Follow.FollowSharpness, dt)
	local turn = PetFollow.alpha(Follow.TurnSharpness, dt)
	local inverseDt = if dt > 0 then 1 / dt else 0
	local count = 0
	local fullCount = 0
	for player, owner in owners do
		if not owner.visible or #owner.pets == 0 then
			continue
		end
		local root = rootOf(player)
		if root == nil then
			continue
		end
		local rootCf = root.CFrame
		local look = rootCf.LookVector * Vector3.new(1, 0, 1)
		local yaw = if look.Magnitude > 0.01 then math.atan2(-look.X, -look.Z) else 0
		local flat = CFrame.new(rootCf.Position) * CFrame.Angles(0, yaw, 0)
		local total = #owner.pets
		local asleep = owner.asleep
		for index, slot in owner.pets do
			local target = flat * PetFollow.slotOffset(index, total)
			-- Ground height: a ray every GroundRayEvery frames per pet (staggered), else cached.
			slot.rayIn -= 1
			if slot.rayIn <= 0 or slot.groundY == nil then
				slot.rayIn = Follow.GroundRayEvery
				local hit = Workspace:Raycast(target + Vector3.new(0, 6, 0), Vector3.new(0, -24, 0), rayParams)
				slot.groundY = if hit ~= nil then hit.Position.Y else rootCf.Position.Y - ROOT_TO_GROUND
			end
			-- The smoothed BASE (ground + species hover); hops / bobs are PetAnim's pose on top, so
			-- the follow smoothing never flattens them.
			local goal = Vector3.new(target.X, (slot.groundY :: number) + slot.hover, target.Z)
			local previous = slot.position
			local position: Vector3
			local speed = 0
			local yawBefore = slot.yaw
			if previous == nil or (previous - goal).Magnitude > Follow.TeleportDistance then
				position = goal
				slot.yaw = yaw
				yawBefore = yaw
			else
				position = previous:Lerp(goal, follow)
				local moved = position - previous
				speed = Vector3.new(moved.X, 0, moved.Z).Magnitude * inverseDt
			end
			slot.position = position
			slot.yaw += PetFollow.angleDelta(slot.yaw, yaw) * turn
			local cf = CFrame.new(position) * CFrame.Angles(0, slot.yaw, 0)
			local parts = slot.parts
			if slot.detail ~= OFF then
				local turnRate = (slot.yaw - yawBefore) * inverseDt
				PetAnim.step(slot.rig, slot.anim, dt, speed, turnRate, asleep, slot.detail, still)
				PetAnim.pose(slot.rig, slot.anim, slot.pose, slot.detail)
				local pose = slot.pose
				for partIndex, part in parts do
					count += 1
					moveParts[count] = part
					moveFrames[count] = cf * pose[partIndex]
				end
				if slot.detail == FULL then
					fullCount += 1
					fullSlots[fullCount] = slot
				end
			else
				local offsets = slot.offsets
				for partIndex, part in parts do
					count += 1
					moveParts[count] = part
					moveFrames[count] = cf * offsets[partIndex]
				end
			end
		end
	end
	-- Trim stale tail entries (fewer parts than last frame) without reallocating.
	for index = #moveParts, count + 1, -1 do
		moveParts[index] = nil
		moveFrames[index] = nil
	end
	if count > 0 then
		Workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	-- Size squash + glow pulse of the fully animated pets (writes only on change).
	for index = 1, fullCount do
		local slot = fullSlots[index]
		PetModels.applyLook(slot.rig, slot.anim, slot.parts)
	end
	for index = #fullSlots, fullCount + 1, -1 do
		fullSlots[index] = nil
	end
	PetEmotes.step(dt)
	StandClient.step(dt, clock, still)
end

--------------------------------------------------------------------------------------------------
-- Routing
--------------------------------------------------------------------------------------------------

-- Held eggs + crates + ready Pet Index milestones (R78) + ready Flavour Book rewards (R89) → HUD
-- Pets badge ("3", nil when none).
local function refreshBadge(profile: any)
	local total = 0
	local pets = if type(profile) == "table" then profile.pets else nil
	-- A claimable Index milestone (PetIndexConfig) counts like a held egg: something to open.
	total += #PetIndexConfig.claimable(pets)
	-- Owner R89: ready Flavour Book rewards too (the Book opens from the Pets window's FLAVOURS button).
	if FlavorConfig.isEnabled() then
		total += FlavorLogic.claimableCount(if type(profile) == "table" then profile.flavors else nil)
	end
	if type(pets) == "table" and type(pets.eggs) == "table" then
		for _, count in pets.eggs do
			if type(count) == "number" then
				total += count
			end
		end
	end
	local crates = if type(profile) == "table" then profile.crates else nil
	if type(crates) == "table" and type(crates.held) == "table" then
		for _, count in crates.held do
			if type(count) == "number" then
				total += count
			end
		end
	end
	pcall(Hud.setButtonBadge, "Pets", if total > 0 then tostring(math.min(total, 99)) else nil)
end

-- Opens a screen unless it is already open (the prompt and the Hatch action can both fire).
local function openOnce(name: string, args: any?)
	if not ScreenManager.isOpen(name) then
		ScreenManager.open(name, args)
	end
end

-- A ProximityPrompt the local player triggered: egg stands / crate stall open their screens.
local function onPrompt(prompt: ProximityPrompt)
	local eggId = prompt:GetAttribute("EggId")
	if type(eggId) == "string" then
		openOnce("EggHatch", { eggId = eggId })
		return
	end
	if prompt:GetAttribute("CrateStall") == true then
		openOnce("CrateShop")
	end
end

-- The egg whose stand prompt is within reach of `position` (nearest), or nil.
local function nearestEgg(position: Vector3): string?
	local stands = Workspace:FindFirstChild("PetStands")
	if stands == nil then
		return nil
	end
	local best: string? = nil
	local bestDistance = STAND_REACH
	for _, model in stands:GetChildren() do
		local eggId = model:GetAttribute("EggId")
		local point = model:FindFirstChild("PromptPoint")
		if type(eggId) == "string" and point ~= nil and point:IsA("BasePart") then
			local distance = (point.Position - position).Magnitude
			if distance <= bestDistance then
				best, bestDistance = eggId, distance
			end
		end
	end
	return best
end

--[[
	Console + mobile (B16 Platform, owner R11): the "Egg" context turns on near a stand, which binds
	the Hatch action (E / gamepad X / the big HATCH touch button, hint bar glyph); pressing it opens
	the nearest stand's window. Guarded: a missing Platform layer leaves the ProximityPrompts.
]]
local function wirePlatform()
	local platform = script.Parent.Parent:FindFirstChild("Platform")
	local module = if platform ~= nil then platform:FindFirstChild("ActionMap") else nil
	if module == nil or not module:IsA("ModuleScript") then
		return
	end
	local ok, result = pcall(require, module)
	local ActionMap: any = if ok then result else nil
	if type(ActionMap) ~= "table" or type(ActionMap.addContextProvider) ~= "function" then
		return
	end
	local addContextProvider = ActionMap.addContextProvider :: (provider: (root: Vector3) -> any) -> any
	addContextProvider(function(root: Vector3): { [string]: boolean }
		return { Egg = nearestEgg(root) ~= nil }
	end)
	InputController.ActionPressed:Connect(function(action: string)
		if action ~= "Hatch" then
			return
		end
		local root = rootOf(LOCAL)
		local eggId = if root ~= nil then nearestEgg(root.Position) else nil
		if eggId ~= nil then
			openOnce("EggHatch", { eggId = eggId })
		end
	end)
end

function PetController.Init()
	folder = Instance.new("Folder")
	folder.Name = "ClientPets"
	folder.Parent = Workspace
end

function PetController.Start()
	PetRequests.start()
	StandClient.start()
	PetModels.Ready:Connect(onMeshReady)
	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(untrack)
	RunService.RenderStepped:Connect(step)
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if player == LOCAL then
			onPrompt(prompt)
		end
	end)
	wirePlatform()

	-- Any input keeps your pets awake (the AFK check samples this in the culling pass).
	UserInputService.InputBegan:Connect(function()
		localInputAt = os.clock()
	end)
	-- Happy spins (owner R44): any player's fresh purchase build ...
	PlotWatcher.BuildAdded:Connect(function(_model: Model, info: PlotWatcher.BuildInfo)
		if info.age <= Happy.FreshBuild then
			local buyer = Players:GetPlayerByUserId(info.buyerUserId)
			if buyer ~= nil then
				celebrate(buyer)
			end
		end
	end)
	-- ... and your hatch, once its reveal has closed (cull() covers a reveal that never shows).
	ScreenManager.Closed:Connect(function(name: string)
		if name == "HatchReveal" and pendingHatchAt ~= nil then
			pendingHatchAt = nil
			celebrate(LOCAL)
		end
	end)

	-- Server grants (group / event / pack / admin pets) play the reveal.
	local hatchFlow = require(script.Parent.Parent.UI.Screens.EggHatch.HatchFlow) :: any
	PetRequests.HatchResult:Connect(function(requestId: number, payload: any)
		if type(payload) ~= "table" or payload.ok ~= true then
			return
		end
		pendingHatchAt = os.clock()
		if requestId == 0 and payload.granted == true then
			hatchFlow.playGrant(payload)
		end
	end)
	-- A Robux purchase cheers your pets; a Robux crate is shown ready to open.
	ClientState.PurchaseGranted:Connect(function(grant: any)
		celebrate(LOCAL)
		if type(grant) == "table" and grant.kind == "Crate" and type(grant.key) == "string" then
			local crateId = CrateConfig.ByProduct[grant.key]
			if crateId ~= nil then
				ScreenManager.open("CrateOpen", { crateId = crateId, ready = true })
			end
		end
	end)
	ClientState.ProfileChanged:Connect(function(profile: any, fields: { string }?)
		if
			fields == nil
			or table.find(fields, "pets")
			or table.find(fields, "crates")
			or table.find(fields, "flavors")
		then
			refreshBadge(profile)
		end
		if fields == nil or table.find(fields, "settings") then
			cullTimer = 0 -- hideOtherPets toggled: re-cull next frame
		end
	end)
	if ClientState.profile ~= nil then
		refreshBadge(ClientState.profile)
	end
end

return PetController
