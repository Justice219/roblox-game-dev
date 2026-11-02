--!strict
--[[
	HappyHourPickupsClient — draws the player's own Happy Hour pickups (owner R89 §2,
	docs/happy-hours.md) and claims them when the character walks in (keyboard / gamepad / touch all
	just walk: no extra binding needed).

	Purpose:
		The server (Server/HappyHour/HappyHourPickups) keeps the pickups and tells only the owner
		("HappyHour" spawn / claimed / gone / clear). Each becomes a pooled model of an EXISTING
		Blender mesh (HappyHourConfig PickupDef meshKey / goldenMeshKey via Pets/PetModels.fromKey,
		stud boxes until the mesh is loaded; golden eggs take the gold tint):
			fall   a coin drops out of the Confetti Storm cloud and spins where it lands
			float  a moon rock hangs at jump height and bobs (Low-Gravity Hour)
			run    a dino egg runs its loop (the Golden Turkey path maths) and wobbles
		Walking within CatchRadius sends HappyHourCollect(id) and retries every RetrySeconds while
		inside until the server answers. Claim feedback: confetti burst, coins / gems flying into
		the HUD counters (CurrencyFly), a jingle.

	Performance: models pooled per (mesh, golden) and reused; ONE Heartbeat exists only while a
	pickup is live and moves every visible pickup with ONE Workspace:BulkMoveTo; pickups beyond
	RenderDistance are unparented; Reduce Motion stops spin / bob / wobble (pickups still move
	along their path so they stay where the server thinks they are).

	Security: display + intents only. Every payload is validated (HappyHourPickupLogic.readWire);
	the client sends only pickup ids; the server decides validity, amounts and gems.

	Connects to: Shared/Config/{HappyHourConfig, AudioConfig}, Shared/Events/HappyHourPickupLogic,
	Shared/Net/Remotes, Client/{Pets/PetModels, Audio/Sound, Tycoon/Fx/{Confetti, FxQuality}},
	UI/{Hud/CurrencyFly, Create, Widgets/OfferFx}. Started by Client/HappyHour/HappyHourClient.

	Example:
		HappyHourPickupsClient.start()
		print(HappyHourPickupsClient.stats().live) --> 3
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AudioConfig = require(ReplicatedStorage.Shared.Config.AudioConfig)
local Confetti = require(script.Parent.Parent.Tycoon.Fx.Confetti)
local Create = require(script.Parent.Parent.UI.Create)
local CurrencyFly = require(script.Parent.Parent.UI.Hud.CurrencyFly)
local FxQuality = require(script.Parent.Parent.Tycoon.Fx.FxQuality)
local HappyHourConfig = require(ReplicatedStorage.Shared.Config.HappyHourConfig)
local HappyHourPickupLogic = require(ReplicatedStorage.Shared.Events.HappyHourPickupLogic)
local OfferFx = require(script.Parent.Parent.UI.Widgets.OfferFx)
local PetModels = require(script.Parent.Parent.Pets.PetModels)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Sound = require(script.Parent.Parent.Audio.Sound)

type Wire = HappyHourPickupLogic.Wire

-- A pooled model with its rig (BulkMoveTo parts + offsets from the root).
type Pooled = {
	model: Model,
	parts: { BasePart },
	offsets: { CFrame },
	key: string, -- pool key "<meshKey>|<golden>"
	meshKey: string,
	meshed: boolean, -- built from loaded meshes (false = stud boxes until PetModels.Ready)
}

-- One live pickup on this client.
type Entry = {
	wire: Wire,
	compiled: HappyHourPickupLogic.Compiled,
	pooled: Pooled,
	lastSent: number, -- os.clock() of the last collect intent
	phase: number, -- random animation phase
	last: Vector3, -- last drawn position (claim FX, facing)
}

local Pickups = HappyHourConfig.Pickups
local Client = HappyHourConfig.Client

local HappyHourPickupsClient = {}

local localPlayer = Players.LocalPlayer
local live: { [string]: Entry } = {}
local pools: { [string]: { Pooled } } = {}
local folder: Folder? = nil
local heartbeat: RBXScriptConnection? = nil
local started = false
local counters = { spawned = 0, claimed = 0, sent = 0 }

-- Shared BulkMoveTo buffers (reused every frame: no per-frame tables).
local movedParts: { BasePart } = {}
local movedFrames: { CFrame } = {}

-- The client-only folder pickups live in.
local function folderOf(): Folder
	local existing = folder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local created = Create.new("Folder", { Name = "SN_HappyHourPickups", Parent = Workspace }) :: Folder
	folder = created
	return created
end

-- Reduce Motion (Roblox's or SellNukes' setting, via the shared animation driver).
local function reduced(): boolean
	return OfferFx.reducedMotion()
end

-- Plays a sound key if it exists (a missing key is skipped silently).
local function playSound(key: string, position: Vector3?)
	if AudioConfig.Sfx[key] ~= nil then
		Sound.play(key, if position ~= nil then { position = position } else nil)
	end
end

-- A small stand-in when a mesh key is missing from MeshAssets (never expected; defensive).
local function standIn(golden: boolean): Model
	local model = Create.new("Model", { Name = "HappyHourPickup" }) :: Model
	local root = Create.new("Part", {
		Name = "Root",
		Size = Vector3.new(2, 2, 2),
		Shape = Enum.PartType.Ball,
		Color = if golden then Color3.fromRGB(255, 205, 60) else Color3.fromRGB(120, 220, 120),
		Material = Enum.Material.SmoothPlastic,
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Parent = model,
	}) :: Part
	model.PrimaryPart = root
	return model
end

-- Builds one pooled model for a mesh key (golden pieces take the event's gold tint).
local function build(meshKey: string, golden: boolean, def: HappyHourConfig.PickupDef): Pooled
	local model = PetModels.fromKey(meshKey) or standIn(golden)
	model.Name = "HappyHourPickup"
	if def.scale ~= 1 then
		model:ScaleTo(def.scale)
	end
	local tint = if golden then def.goldenTint else nil
	if tint ~= nil then
		for _, item in model:GetDescendants() do
			if item:IsA("BasePart") and item.Transparency < 1 then
				item.Color = tint
			end
		end
	end
	local parts, offsets = PetModels.rig(model)
	-- Everything client-side and inert (no physics, no clicks, no queries).
	for _, part in parts do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end
	local root = model.PrimaryPart
	if root ~= nil then
		root.Anchored = true
		root.CanCollide = false
		root.CanQuery = false
		root.CanTouch = false
	end
	return {
		model = model,
		parts = parts,
		offsets = offsets,
		key = `{meshKey}|{golden}`,
		meshKey = meshKey,
		meshed = PetModels.isMeshReady(meshKey),
	}
end

-- A pooled model for a wire (rebuilt once the real mesh finished loading).
local function acquire(wire: Wire, def: HappyHourConfig.PickupDef): Pooled
	local meshKey = if wire.golden then def.goldenMeshKey else def.meshKey
	local key = `{meshKey}|{wire.golden}`
	local pool = pools[key]
	local pooled: Pooled? = nil
	if pool ~= nil and #pool > 0 then
		pooled = table.remove(pool)
	end
	if pooled ~= nil and not pooled.meshed and PetModels.isMeshReady(meshKey) then
		pooled.model:Destroy()
		pooled = nil
	end
	return pooled or build(meshKey, wire.golden, def)
end

-- Returns a model to its pool (unparented).
local function release(pooled: Pooled)
	pooled.model.Parent = nil
	local pool = pools[pooled.key]
	if pool == nil then
		pool = {}
		pools[pooled.key] = pool
	end
	if #pool < 8 then
		table.insert(pool, pooled)
	else
		pooled.model:Destroy()
	end
end

-- The character root position, or nil.
local function rootPosition(): Vector3?
	local character = localPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root.Position else nil
end

-- Removes one pickup (no FX).
local function remove(id: string)
	local entry = live[id]
	if entry == nil then
		return
	end
	live[id] = nil
	release(entry.pooled)
end

-- The pose CFrame of an entry at `now` (spin / bob / wobble unless Reduce Motion).
local function frameOf(entry: Entry, now: number, still: boolean): (CFrame, Vector3)
	local position = HappyHourPickupLogic.position(entry.compiled, now)
	local wire = entry.wire
	local clock = os.clock() + entry.phase
	if wire.style == "run" then
		local ahead = HappyHourPickupLogic.position(entry.compiled, now + 0.1)
		local dir = Vector3.new(ahead.X - position.X, 0, ahead.Z - position.Z)
		local look = if dir.Magnitude > 1e-3 then CFrame.lookAt(position, position + dir) else CFrame.new(position)
		if still then
			return look, position
		end
		-- A bouncy waddle while running.
		local hop = math.abs(math.sin(clock * 9)) * 0.6
		return look * CFrame.new(0, hop, 0) * CFrame.Angles(0, 0, math.sin(clock * 9) * 0.18), position
	end
	if still then
		return CFrame.new(position), position
	end
	local bob = if wire.style == "float" then math.sin(clock * 2.2) * 0.7 else math.sin(clock * 3) * 0.25
	return CFrame.new(position + Vector3.new(0, bob, 0)) * CFrame.Angles(0, clock * 2.4, 0), position
end

-- Heartbeat: move every visible pickup, drop ended ones, send walk-in claims.
local function step()
	local now = Workspace:GetServerTimeNow()
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera ~= nil then camera.CFrame.Position else nil
	local root = rootPosition()
	local still = reduced()
	local parent = folderOf()
	local count = 0
	local any = false
	for id, entry in live do
		any = true
		if now >= entry.compiled.ends + Pickups.ExpiryGrace then
			remove(id)
			continue
		end
		local _, alive = HappyHourPickupLogic.position(entry.compiled, now)
		local cf, position = frameOf(entry, now, still)
		entry.last = position
		local near = cameraPosition == nil or (position - cameraPosition).Magnitude <= Pickups.RenderDistance
		local model = entry.pooled.model
		if not alive or not near then
			if model.Parent ~= nil then
				model.Parent = nil
			end
		else
			if model.Parent ~= parent then
				model.Parent = parent
			end
			local primary = model.PrimaryPart
			if primary ~= nil then
				count += 1
				movedParts[count] = primary
				movedFrames[count] = cf
			end
			local pooled = entry.pooled
			for index, part in pooled.parts do
				count += 1
				movedParts[count] = part
				movedFrames[count] = cf * pooled.offsets[index]
			end
		end
		-- Walk-in claim (the server re-checks everything).
		if alive and root ~= nil then
			local distance = HappyHourPickupLogic.distance(entry.compiled, now, root, { 0 })
			if distance <= Pickups.CatchRadius and os.clock() - entry.lastSent >= Pickups.RetrySeconds then
				entry.lastSent = os.clock()
				counters.sent += 1
				Remotes.event("HappyHourCollect"):FireServer(id)
			end
		end
	end
	if count > 0 then
		-- Trim the shared buffers to this frame's length.
		for index = #movedParts, count + 1, -1 do
			movedParts[index] = nil
			movedFrames[index] = nil
		end
		Workspace:BulkMoveTo(movedParts, movedFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	if not any then
		local connection = heartbeat
		if connection ~= nil then
			connection:Disconnect()
			heartbeat = nil
		end
	end
end

-- Ensures the Heartbeat runs while pickups are live.
local function ensureHeartbeat()
	if heartbeat == nil then
		heartbeat = RunService.Heartbeat:Connect(step)
	end
end

-- A new pickup from the server.
local function onSpawn(raw: unknown)
	local wire = HappyHourPickupLogic.readWire(raw)
	if wire == nil then
		return
	end
	local def = HappyHourConfig.Events[wire.event].pickup
	if def == nil then
		return
	end
	remove(wire.id)
	local compiled = HappyHourPickupLogic.compile(wire)
	local entry: Entry = {
		wire = wire,
		compiled = compiled,
		pooled = acquire(wire, def),
		lastSent = -math.huge,
		phase = math.random() * 10,
		last = wire.points[1],
	}
	live[wire.id] = entry
	counters.spawned += 1
	ensureHeartbeat()
end

-- The server paid a pickup: FX, money flying into the HUD, then it is gone.
local function onClaimed(data: { [string]: unknown })
	local id = data.id
	if type(id) ~= "string" then
		return
	end
	local entry = live[id]
	if entry == nil then
		return
	end
	counters.claimed += 1
	local position = entry.last
	local low = FxQuality.tier() == "Low" or reduced()
	local golden = data.golden == true
	Confetti.burst(
		position,
		if low then 6 else (if golden then 26 else 14),
		if low then 3 else (if golden then 14 else 6)
	)
	playSound(if golden then Client.GoldenSound else Client.ClaimSound, nil)
	local amount, currency, gems = data.amount, data.currency, data.gems
	if type(amount) == "number" and amount > 0 and amount == amount and type(currency) == "string" then
		CurrencyFly.fromWorld(currency, amount, position, "reward")
	end
	if type(gems) == "number" and gems > 0 and gems == gems then
		CurrencyFly.fromWorld("gems", gems, position, "reward")
	end
	remove(id)
end

-- Server messages ("HappyHour").
local function onMessage(payload: unknown)
	if type(payload) ~= "table" then
		return
	end
	local data = payload :: { [string]: unknown }
	local kind = data.kind
	if kind == "spawn" then
		onSpawn(data.pickup)
	elseif kind == "claimed" then
		onClaimed(data)
	elseif kind == "gone" then
		if type(data.id) == "string" then
			remove(data.id :: string)
		end
	elseif kind == "clear" then
		HappyHourPickupsClient.clear()
	end
end

-- ── Public API ───────────────────────────────────────────────────────────────────────────────

--[[ Drops every pickup locally (event over / world change). ]]
function HappyHourPickupsClient.clear()
	for id in live do
		remove(id)
	end
end

--[[ The live pickups (QA): { id, event, style, golden, position }. ]]
function HappyHourPickupsClient.list(): { { [string]: any } }
	local list: { { [string]: any } } = {}
	for id, entry in live do
		local row: { [string]: any } = {
			id = id,
			event = entry.wire.event,
			style = entry.wire.style,
			golden = entry.wire.golden,
			position = entry.last,
			meshed = entry.pooled.meshed,
		}
		table.insert(list, row)
	end
	return list
end

--[[ Verification counters (Studio QA). ]]
function HappyHourPickupsClient.stats(): { [string]: number }
	local count = 0
	for _ in live do
		count += 1
	end
	return { live = count, spawned = counters.spawned, claimed = counters.claimed, sent = counters.sent }
end

--[[ Starts listening (once). ]]
function HappyHourPickupsClient.start()
	if started then
		return
	end
	started = true
	-- Warm the mesh loads of every pickup kind (they are small; first drops look right).
	for _, id in HappyHourConfig.EventIds do
		local def = HappyHourConfig.Events[id].pickup
		if def ~= nil then
			PetModels.request(def.meshKey)
			PetModels.request(def.goldenMeshKey)
		end
	end
	task.spawn(function()
		Remotes.event("HappyHour").OnClientEvent:Connect(onMessage)
	end)
end

return HappyHourPickupsClient
