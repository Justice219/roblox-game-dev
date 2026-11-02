--!strict
--[[
	ProducerJuice — feedback around YOUR producers (owner R71 juice), in every world:

		upgrade      a soft gold glow over the producer (pooled Highlight, fades in ~0.5 s) + a few
		             sparkles, at most one per producer per UpgradeGlow.Gap (MAX buys / held keys)
		milestone    a level-up that crosses a multiple of the world's MilestoneEvery (25 / 50 / 100
		             ...) shows the centre banner "<producer>" / "LEVEL 50!" / "x2 SPEED!" (JuiceBanner)
		             with the "milestone" ding and confetti over the producer. Speed milestones on a
		             producer whose cycle already sits at the floor say "x2 CASH!" (that speed is paid
		             as cash, TycoonLogic floor conversion), so the banner never over-promises.
		manager      Automated false -> true: a soft puff + sparkles and "manager_hired" at the producer
		ambient      gentle steady income sparkles over the nearest automated producers (FxQuality
		             tier count, within Ambient.Range of the camera), re-ranked once a second

	Source of truth: the server's producer anchor attributes (Tycoon/TycoonContract: Level,
	Automated, CycleTime) on anchors in YOUR plot (TycoonWorld.isMine). A producer that streams in
	(or a fresh plot after a rebirth) only records a baseline — no burst for old progress.

	Performance: two attribute signals per own producer; the glow fade runs in the juice pass's one
	Heartbeat (Fx/JuiceLoop) only while a glow is up; the ambient re-rank is a 1 Hz thread that
	reads cached anchors (no Instance scans) and only moves pooled emitters (JuiceParticles).
	Reduce Motion: banners + sounds stay, glow stays (a soft colour change, not motion), no puffs,
	sparkles or confetti.

	Connects to: Tycoon/{TycoonWorld, TycoonContract}, Shared/Config/{JuiceConfig, Worlds/WorldsConfig},
	Client/Tycoon/Fx/{JuiceRules, JuiceParticles, JuiceBanner, JuiceLoop, Confetti, FxQuality,
	FxSound}, UI/Widgets/OfferFx, caller JuiceController.

	Example: ProducerJuice.start()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Confetti = require(script.Parent.Confetti)
local Contract = require(script.Parent.Parent.TycoonContract)
local FxQuality = require(script.Parent.FxQuality)
local FxSound = require(script.Parent.FxSound)
local JuiceBanner = require(script.Parent.JuiceBanner)
local JuiceConfig = require(ReplicatedStorage.Shared.Config.JuiceConfig)
local JuiceLoop = require(script.Parent.JuiceLoop)
local JuiceParticles = require(script.Parent.JuiceParticles)
local JuiceRules = require(script.Parent.JuiceRules)
local OfferFx = require(script.Parent.Parent.Parent.UI.Widgets.OfferFx)
local Sound = require(script.Parent.Parent.Parent.Audio.Sound)
local TycoonWorld = require(script.Parent.Parent.TycoonWorld)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local ProducerJuice = {}

local Attr = Contract.Attr
local Glow = JuiceConfig.UpgradeGlow
local Ambient = JuiceConfig.Ambient
-- Upgrade glows / manager puffs farther than this from the camera are skipped (not in view).
local NEAR = 160

type Watch = {
	anchor: BasePart,
	world: string,
	id: string,
	level: number,
	automated: boolean,
	lastGlow: number,
	connections: { RBXScriptConnection },
}

type GlowSlot = { highlight: Highlight, startedAt: number, live: boolean }

local watches: { [BasePart]: Watch } = {}
local glows: { GlowSlot } = {}
local started = false
local ambientPositions: { Vector3 } = {}
-- One ambient candidate (re-built at 1 Hz from the cached own-producer watches).
type Candidate = { position: Vector3, distance: number }
local ambientCandidates: { Candidate } = {}

local function cameraPosition(): Vector3?
	local camera = Workspace.CurrentCamera
	return if camera ~= nil then camera.CFrame.Position else nil
end

-- True when `position` is within `range` studs of the camera.
local function near(position: Vector3, range: number): boolean
	local eye = cameraPosition()
	return eye ~= nil and (eye - position).Magnitude <= range
end

-- The top centre of an anchor (FX start just above the producer).
local function topOf(anchor: BasePart): Vector3
	return anchor.Position + Vector3.new(0, anchor.Size.Y * 0.5 + 1, 0)
end

-- Builds one pooled glow Highlight (off until used) and adds it to the pool.
local function makeGlow(): GlowSlot
	local highlight = Instance.new("Highlight")
	highlight.Name = `SN_UpgradeGlow{#glows + 1}`
	highlight.FillColor = Glow.Color
	highlight.OutlineColor = Glow.Color
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.Enabled = false
	highlight.Parent = JuiceParticles.folder()
	local slot = { highlight = highlight, startedAt = 0, live = false }
	table.insert(glows, slot)
	return slot
end

-- A free glow Highlight (built on first use; the oldest is re-used when all are busy).
local function glowSlot(): GlowSlot
	local oldest: GlowSlot? = nil
	for _, slot in glows do
		if not slot.live then
			return slot
		end
		if oldest == nil or slot.startedAt < oldest.startedAt then
			oldest = slot
		end
	end
	if #glows < Glow.Pool then
		return makeGlow()
	end
	return oldest :: GlowSlot
end

-- Fades the glows (JuiceLoop): bright at the start, gone after Glow.Seconds.
local function stepGlows(now: number): boolean
	local any = false
	for _, slot in glows do
		if not slot.live then
			continue
		end
		local k = (now - slot.startedAt) / Glow.Seconds
		if k >= 1 then
			slot.live = false
			slot.highlight.Enabled = false
			slot.highlight.Adornee = nil
			continue
		end
		any = true
		-- Quick rise (first 20 %), then a soft fade.
		local strength = if k < 0.2 then k / 0.2 else 1 - (k - 0.2) / 0.8
		slot.highlight.FillTransparency = 1 - (1 - Glow.FillTransparency) * strength
		slot.highlight.OutlineTransparency = 1 - (1 - Glow.OutlineTransparency) * strength
	end
	return any
end

-- The world economy of a producer's world (nil for an unknown world).
local function economyOf(world: string): any
	local def = WorldsConfig.get(world)
	return if def ~= nil then def.economy else nil
end

-- Upgrade glow + sparkles.
local function upgraded(watch: Watch, now: number)
	if now - watch.lastGlow < Glow.Gap or not near(watch.anchor.Position, NEAR) then
		return
	end
	watch.lastGlow = now
	local model = watch.anchor.Parent
	if model ~= nil and model:IsA("Model") then
		local slot = glowSlot()
		slot.highlight.Adornee = model
		slot.highlight.FillTransparency = 1
		slot.highlight.OutlineTransparency = 1
		slot.highlight.Enabled = true
		slot.startedAt = now
		slot.live = true
		JuiceLoop.wake()
	end
	if not OfferFx.reducedMotion() then
		Confetti.burst(topOf(watch.anchor), 0, JuiceRules.perTier(Glow.Sparkles, FxQuality.tier()))
	end
end

-- Milestone banner + ding + confetti (after the attribute batch settled: CycleTime may follow).
local function milestone(watch: Watch, level: number)
	task.defer(function()
		local economy = economyOf(watch.world)
		local every = if economy ~= nil then economy.MilestoneEvery else 25
		local floor = if economy ~= nil then economy.CycleFloor else 0.1
		local cycle = Contract.num(watch.anchor:GetAttribute(Attr.CycleTime), math.huge)
		local kind = JuiceRules.milestoneKind(level, every, cycle <= floor * 1.001)
		local title, reward = JuiceRules.milestoneText(level, kind)
		local producer = economy ~= nil and economy.ProducersById[watch.id]
		local name = if type(producer) == "table" and type(producer.name) == "string" then producer.name else ""
		JuiceBanner.show(name, title, reward, if kind == "Speed" then "cyan" else "green")
		Sound.play(JuiceConfig.Milestone.Sound)
		if not OfferFx.reducedMotion() and watch.anchor.Parent ~= nil and near(watch.anchor.Position, NEAR) then
			local tier = FxQuality.tier()
			Confetti.burst(
				topOf(watch.anchor) + Vector3.new(0, 2, 0),
				JuiceRules.perTier(JuiceConfig.Milestone.Confetti, tier),
				JuiceRules.perTier(JuiceConfig.Milestone.Sparkles, tier)
			)
		end
	end)
end

-- Level attribute changed on an own producer.
local function onLevel(watch: Watch)
	local level = Contract.num(watch.anchor:GetAttribute(Attr.Level), 0)
	local old = watch.level
	watch.level = level
	if level <= old then
		return -- a rebirth / reset: baseline only
	end
	if old <= 0 then
		return -- just built (level 0 -> 1): the build-in fly-in is its celebration
	end
	upgraded(watch, os.clock())
	local economy = economyOf(watch.world)
	local crossed = JuiceRules.milestoneCrossed(old, level, if economy ~= nil then economy.MilestoneEvery else 25)
	if crossed ~= nil then
		milestone(watch, crossed)
	end
end

-- Automated attribute changed on an own producer (a manager arrived).
local function onAutomated(watch: Watch)
	local automated = Contract.bool(watch.anchor:GetAttribute(Attr.Automated))
	local was = watch.automated
	watch.automated = automated
	if not automated or was or not near(watch.anchor.Position, NEAR) then
		return
	end
	local position = topOf(watch.anchor)
	FxSound.play(JuiceConfig.Manager.Sound, position)
	if not OfferFx.reducedMotion() then
		local tier = FxQuality.tier()
		JuiceParticles.puff(
			position,
			JuiceRules.perTier(JuiceConfig.Manager.Puff, tier),
			JuiceRules.perTier(JuiceConfig.Manager.Sparkles, tier)
		)
	end
end

-- Stops watching a producer anchor.
local function remove(anchor: BasePart)
	local watch = watches[anchor]
	if watch == nil then
		return
	end
	watches[anchor] = nil
	for _, connection in watch.connections do
		connection:Disconnect()
	end
end

-- Starts watching an own producer anchor (baseline only, no FX).
local function add(anchor: BasePart)
	if watches[anchor] ~= nil or not TycoonWorld.isMine(anchor) then
		return
	end
	local watch: Watch = {
		anchor = anchor,
		world = TycoonWorld.worldOf(anchor),
		id = TycoonWorld.producerId(anchor),
		level = Contract.num(anchor:GetAttribute(Attr.Level), 0),
		automated = Contract.bool(anchor:GetAttribute(Attr.Automated)),
		lastGlow = -math.huge,
		connections = {},
	}
	watches[anchor] = watch
	table.insert(
		watch.connections,
		anchor:GetAttributeChangedSignal(Attr.Level):Connect(function()
			onLevel(watch)
		end)
	)
	table.insert(
		watch.connections,
		anchor:GetAttributeChangedSignal(Attr.Automated):Connect(function()
			onAutomated(watch)
		end)
	)
	table.insert(
		watch.connections,
		anchor.Destroying:Connect(function()
			remove(anchor)
		end)
	)
end

-- Re-checks every streamed producer (plot ownership arrived / changed).
local function rescan()
	for anchor in watches do
		if not TycoonWorld.isMine(anchor) then
			remove(anchor)
		end
	end
	for _, anchor in TycoonWorld.producers() do
		add(anchor)
	end
end

-- One ambient re-rank: the nearest automated own producers get the steady sparkle emitters.
local function refreshAmbient()
	local eye = cameraPosition()
	table.clear(ambientCandidates)
	table.clear(ambientPositions)
	if eye ~= nil and not OfferFx.reducedMotion() then
		for anchor, watch in watches do
			if watch.automated and anchor.Parent ~= nil then
				local distance = (anchor.Position - eye).Magnitude
				if distance <= Ambient.Range then
					table.insert(ambientCandidates, {
						position = anchor.Position + Vector3.new(0, anchor.Size.Y * 0.5 + Ambient.Rise, 0),
						distance = distance,
					})
				end
			end
		end
		table.sort(ambientCandidates, function(a: Candidate, b: Candidate): boolean
			return a.distance < b.distance
		end)
		for _, candidate in ambientCandidates do
			table.insert(ambientPositions, candidate.position)
		end
	end
	JuiceParticles.setAmbient(ambientPositions, JuiceRules.perTier(Ambient.Emitters, FxQuality.tier()))
end

--[[ Starts watching own producers + the 1 Hz ambient re-rank (once; JuiceController.Start). ]]
function ProducerJuice.start()
	if started then
		return
	end
	started = true
	JuiceLoop.add("UpgradeGlow", stepGlows)
	TycoonWorld.ProducerAdded:Connect(add)
	TycoonWorld.ProducerRemoved:Connect(remove)
	TycoonWorld.MyPlotChanged:Connect(rescan)
	TycoonWorld.MyWorldPlotChanged:Connect(rescan)
	rescan()
	task.spawn(function()
		while true do
			local ok, err = pcall(refreshAmbient)
			if not ok then
				warn(`[ProducerJuice] ambient refresh failed: {err}`)
			end
			task.wait(Ambient.Refresh)
		end
	end)
end

--[[ Builds the glow Highlight pool up front (JuiceController.Start, deferred). ]]
function ProducerJuice.prewarm()
	while #glows < Glow.Pool do
		makeGlow()
	end
end

--[[ Watched producers + live glows (Studio probes). ]]
function ProducerJuice.stats(): { watched: number, glowing: number }
	local watched, glowing = 0, 0
	for _ in watches do
		watched += 1
	end
	for _, slot in glows do
		if slot.live then
			glowing += 1
		end
	end
	return { watched = watched, glowing = glowing }
end

return ProducerJuice
