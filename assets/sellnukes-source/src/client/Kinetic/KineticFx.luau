--!strict
--[[
	KineticFx — the pooled, FxQuality-aware effects of owner R90's Mega Lever + Tip Jar
	(docs/kinetic.md). Visual only: nothing here sends or changes a value.

	Effects
		megaPull(lever, cycles, text, sub)  toy nukes (clones of the lever's own HopperNuke mesh piece,
		                                tinted by each bonus cycle's flavour) slide one after the other
		                                from the hopper down the chute into the catch tray
		                                (KineticConfig.Lever.Chute points, model space); the last one
		                                pops confetti + the big "MEGA PULL!" banner over the tray with
		                                its subline "Every machine made bonus nukes: +$X" (owner R112)
		coinBurst(jar)                  gold coins hop out of the jar and scatter around it + sparkles
		coinShower(jar)                 gold coins drop from above into the jar (a bonus tip landed)
		pop(position, text, color, sub) the rising "+$X" billboard (pooled; optional second line)
		run(step)                       the shared driver KineticVisuals swings the lever arm with
	Counts follow FxQuality (KineticConfig.Fx per tier) and Reduce Motion (one nuke, few coins).

	Performance (console / phone): ONE Heartbeat connection that exists only while an effect runs
	(connected by run(), disconnected when the last step finishes); every part / billboard comes
	from a pool built on first use (nukes <= the High tier count, coins CoinPool, pops 3), so there
	is no Instance.new per frame or per pull after warm-up; positions are written straight to the
	pooled parts (Anchored, no collision / query / touch, no shadows).

	Connects to: Shared/Config/{KineticConfig, FlavorConfig}, Tycoon/Fx/{Confetti, FxQuality,
	FxSound}, UI/{Create, Kit/StudUI, Widgets/OfferFx (Reduce Motion)}.

	Example:
		KineticFx.megaPull(leverModel, wire.cycles, "MEGA PULL!", "Every machine made bonus nukes: +$1.2M")
		KineticFx.coinBurst(jarModel)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Confetti = require(script.Parent.Parent.Tycoon.Fx.Confetti)
local Create = require(script.Parent.Parent.UI.Create)
local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local FxQuality = require(script.Parent.Parent.Tycoon.Fx.FxQuality)
local FxSound = require(script.Parent.Parent.Tycoon.Fx.FxSound)
local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)
local OfferFx = require(script.Parent.Parent.UI.Widgets.OfferFx)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)

local FX = KineticConfig.Fx
local CHUTE = KineticConfig.Lever.Chute
local JAR = KineticConfig.TipJar

-- A driver step: (os.clock(), dt) -> keep running?
export type Step = (now: number, dt: number) -> boolean
-- One bonus cycle as the chute FX needs it (KineticLogic.WireCycle).
export type Cycle = { id: string, amount: number, flavor: string }

type Pop = { gui: BillboardGui, anchor: Part, label: TextLabel, sub: TextLabel, busy: boolean, generation: number }

local KineticFx = {}

local steps: { Step } = {}
local connection: RBXScriptConnection? = nil
local folder: Folder? = nil
local nukePool: { BasePart } = {}
local coinPool: { Part } = {}
local pops: { Pop } = {}
local random = Random.new()

-- Flavour colours by id (Plain keeps the mesh's own colour).
local FLAVOR_COLORS: { [string]: Color3 } = {}
for _, def in FlavorConfig.Flavors do
	if def.rank > 0 then
		FLAVOR_COLORS[def.id] = def.color
	end
end

-- The client-only FX folder (created on first use).
local function fxFolder(): Folder
	local existing = folder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local made = Create.new("Folder", { Name = "SN_KineticFx", Parent = Workspace }) :: Folder
	folder = made
	return made
end

-- Reduce Motion (the player setting OfferFx tracks).
local function reduced(): boolean
	return OfferFx.reducedMotion()
end

-- The per-tier count of an FX table ({ Low, Mid, High }).
local function perTier(counts: { read Low: number, read Mid: number, read High: number }): number
	local tier = FxQuality.tier()
	return if tier == "Low" then counts.Low elseif tier == "Mid" then counts.Mid else counts.High
end

-- Heartbeat body: advance every live step, drop finished / failing ones, idle → disconnect.
local function onHeartbeat(dt: number)
	local now = os.clock()
	for index = #steps, 1, -1 do
		local ok, alive = pcall(steps[index], now, dt)
		if not ok or alive ~= true then
			table.remove(steps, index)
		end
	end
	if #steps == 0 and connection ~= nil then
		connection:Disconnect()
		connection = nil
	end
end

--[[
	Runs a step every frame until it returns false (the shared driver; KineticVisuals uses it for
	the arm swing). Errors end that step only.
	@param step Step
]]
function KineticFx.run(step: Step)
	table.insert(steps, step)
	if connection == nil then
		connection = RunService.Heartbeat:Connect(onHeartbeat)
	end
end

-- QA: live steps right now (0 when idle; the driver is then disconnected).
function KineticFx.activeSteps(): number
	return #steps
end

-- A pooled FX part prepared for anchored, collision-free, shadow-free display.
local function inert(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
end

-- A toy nuke from the pool, cloned from a lever's HopperNuke piece on first use.
local function takeNuke(source: BasePart): BasePart?
	local nuke = table.remove(nukePool)
	if nuke == nil then
		local ok, clone = pcall(function(): BasePart
			return source:Clone()
		end)
		if not ok then
			return nil
		end
		nuke = clone
		for _, child in (clone :: BasePart):GetChildren() do
			child:Destroy() -- attributes stay harmless; children (none expected) never ride along
		end
		inert(clone :: BasePart)
	end
	return nuke
end

local function releaseNuke(nuke: BasePart)
	nuke.Parent = nil
	if #nukePool < FX.ChuteNukes.High then
		table.insert(nukePool, nuke)
	else
		nuke:Destroy()
	end
end

-- A gold coin from the pool (created on first use, at most CoinPool kept).
local function takeCoin(): Part
	local coin = table.remove(coinPool)
	if coin == nil then
		coin = Create.new("Part", {
			Name = "KineticCoin",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(FX.CoinSize.Y, FX.CoinSize.X, FX.CoinSize.Z),
			Color = FX.CoinColor,
			Material = Enum.Material.SmoothPlastic,
		}) :: Part
		inert(coin :: Part)
	end
	return coin :: Part
end

local function releaseCoin(coin: Part)
	coin.Parent = nil
	if #coinPool < FX.CoinPool then
		table.insert(coinPool, coin)
	else
		coin:Destroy()
	end
end

-- A free pop billboard (3 pooled; the oldest busy one is reused when all are busy).
local function takePop(): Pop
	for _, entry in pops do
		if not entry.busy then
			return entry
		end
	end
	if #pops >= 3 then
		return pops[1]
	end
	local anchor = Create.new("Part", { Name = "KineticPopAnchor", Size = Vector3.one * 0.2, Transparency = 1 }) :: Part
	inert(anchor)
	local gui = Create.new("BillboardGui", {
		Name = "KineticPop",
		Size = UDim2.fromScale(FX.PopSizeStuds.X, FX.PopSizeStuds.Y),
		MaxDistance = FX.PopMaxDistance,
		LightInfluence = 0,
		AlwaysOnTop = true,
		Adornee = anchor,
		Parent = anchor,
	}) :: BillboardGui
	local label = StudUI.text({
		name = "Text",
		text = "",
		textSize = 64,
		font = "shout",
		scaled = true,
		size = UDim2.fromScale(1, 1),
		parent = gui,
	})
	-- The optional second line (MEGA PULL!'s "Every machine made bonus nukes: +$X").
	local sub = StudUI.text({
		name = "Sub",
		text = "",
		textSize = 40,
		font = "body",
		scaled = true,
		color = FX.PopSubColor,
		size = UDim2.fromScale(1, 0),
		position = UDim2.fromScale(0, 1),
		anchor = Vector2.new(0, 1),
		parent = gui,
	})
	sub.Visible = false
	local entry: Pop = { gui = gui, anchor = anchor, label = label, sub = sub, busy = false, generation = 0 }
	table.insert(pops, entry)
	return entry
end

--[[
	A rising pop at a world position (fades over Fx.PopSeconds), optionally with a second line.
	@param position Vector3
	@param text string — already formatted ("+$1.2M TIPS!" / "MEGA PULL!")
	@param color Color3?
	@param sub string? — a smaller second line under it ("Every machine made bonus nukes: +$1.2M")
]]
function KineticFx.pop(position: Vector3, text: string, color: Color3?, sub: string?)
	local entry = takePop()
	entry.generation += 1
	local generation = entry.generation
	entry.busy = true
	-- One line fills the board; two lines grow it by PopSubStuds and split it title / subline.
	local height = FX.PopSizeStuds.Y + (if sub ~= nil then FX.PopSubStuds else 0)
	entry.gui.Size = UDim2.fromScale(FX.PopSizeStuds.X, height)
	local titleShare = FX.PopSizeStuds.Y / height
	entry.label.Size = UDim2.fromScale(1, titleShare)
	entry.label.Text = text
	entry.label.TextColor3 = color or FX.CoinColor
	entry.label.TextTransparency = 0
	entry.sub.Visible = sub ~= nil
	entry.sub.Size = UDim2.fromScale(1, 1 - titleShare)
	entry.sub.Text = sub or ""
	entry.sub.TextTransparency = 0
	entry.anchor.CFrame = CFrame.new(position)
	entry.anchor.Parent = fxFolder()
	local started = os.clock()
	local rise = if reduced() then 0 else FX.PopRiseStuds
	KineticFx.run(function(now: number): boolean
		if entry.generation ~= generation then
			return false -- reused by a newer pop
		end
		local u = (now - started) / FX.PopSeconds
		if u >= 1 then
			entry.busy = false
			entry.anchor.Parent = nil
			return false
		end
		entry.anchor.CFrame = CFrame.new(position + Vector3.new(0, rise * u, 0))
		local fade = if u > 0.7 then (u - 0.7) / 0.3 else 0
		entry.label.TextTransparency = fade
		entry.sub.TextTransparency = fade
		return true
	end)
end

-- World points of the chute path of a lever (model space → world).
local function chutePath(lever: Model): ({ Vector3 }, { number }, number)
	local pivot = lever:GetPivot()
	local points: { Vector3 } = {}
	for _, point in CHUTE.Points do
		table.insert(points, pivot * point)
	end
	local lengths: { number } = {}
	local total = 0
	for index = 2, #points do
		local length = (points[index] - points[index - 1]).Magnitude
		lengths[index - 1] = length
		total += length
	end
	return points, lengths, total
end

-- Position + travel direction at distance `d` along a polyline.
local function along(points: { Vector3 }, lengths: { number }, d: number): (Vector3, Vector3)
	local remaining = d
	for index, length in lengths do
		if remaining <= length or index == #lengths then
			local a, b = points[index], points[index + 1]
			local t = if length > 0 then math.clamp(remaining / length, 0, 1) else 1
			local direction = if length > 0 then (b - a).Unit else Vector3.yAxis
			return a:Lerp(b, t), direction
		end
		remaining -= length
	end
	return points[#points], Vector3.yAxis
end

--[[
	The Mega Pull ride: nukes slide down the lever's chute, confetti + the big pop at the tray.
	@param lever Model — the MegaLever model (pieces + pivot)
	@param cycles { Cycle } — the wire's bonus cycles (flavours tint the nukes)
	@param text string — the banner ("MEGA PULL!")
	@param sub string? — its subline ("Every machine made bonus nukes: +$1.2M")
]]
function KineticFx.megaPull(lever: Model, cycles: { Cycle }, text: string, sub: string?)
	local source = lever:FindFirstChild(CHUTE.NukePiece)
	local points, lengths, total = chutePath(lever)
	local tray = points[#points]
	local count = math.max(1, math.min(#cycles, perTier(FX.ChuteNukes)))
	if reduced() then
		count = 1
	end
	local finishAt = os.clock() + (count - 1) * CHUTE.StaggerSeconds + CHUTE.RideSeconds
	local celebrated = false
	local function celebrate()
		if celebrated then
			return
		end
		celebrated = true
		local confetti = if reduced() then FX.Confetti.Low else perTier(FX.Confetti)
		Confetti.burst(tray + Vector3.new(0, 1.5, 0), confetti, perTier(FX.Sparkles))
		FxSound.play("kaching", tray)
		KineticFx.pop(tray + Vector3.new(0, 4, 0), text, nil, sub)
	end
	if source == nil or not source:IsA("BasePart") or total <= 0 then
		celebrate() -- no mesh to clone (streamed out mid-pull): still celebrate at the tray
		return
	end
	FxSound.play("whoosh", points[1])
	local sourcePart = source :: BasePart
	for index = 1, count do
		local nuke = takeNuke(sourcePart)
		if nuke == nil then
			break
		end
		local ride = nuke :: BasePart
		local cycle = cycles[index]
		ride.Color = if cycle ~= nil and FLAVOR_COLORS[cycle.flavor] ~= nil
			then FLAVOR_COLORS[cycle.flavor]
			else sourcePart.Color
		local startAt = os.clock() + (index - 1) * CHUTE.StaggerSeconds
		local placed = false
		KineticFx.run(function(now: number): boolean
			local u = (now - startAt) / CHUTE.RideSeconds
			if u < 0 then
				return true
			end
			if u >= 1 then
				releaseNuke(ride)
				if index == count then
					celebrate()
				end
				return false
			end
			if not placed then
				placed = true
				ride.Parent = fxFolder()
			end
			-- Ease in (gravity-ish): slow at the hopper, fast at the tray.
			local position, direction = along(points, lengths, total * u * u)
			-- Lie the nuke along the chute (+Y of the piece points down the slope).
			ride.CFrame = CFrame.lookAt(position, position + direction) * CFrame.Angles(-math.pi / 2, 0, 0)
			return true
		end)
	end
	-- Safety: celebrate even if a ride step errored out early.
	KineticFx.run(function(now: number): boolean
		if now >= finishAt + 0.5 then
			celebrate()
			return false
		end
		return not celebrated
	end)
end

-- The jar's mouth (top of the glass) in world space.
local function jarMouth(jar: Model): Vector3
	return jar:GetPivot() * Vector3.new(0, 4.9, 0)
end

--[[
	Coins hop out of the jar and scatter on the ground around it + sparkles (a payout).
	@param jar Model — the TipJar model
]]
function KineticFx.coinBurst(jar: Model)
	local mouth = jarMouth(jar)
	local ground = jar:GetPivot().Position
	Confetti.burst(mouth, if reduced() then 0 else math.floor(perTier(FX.Confetti) / 2), perTier(FX.Sparkles))
	FxSound.play("kaching", mouth)
	local count = if reduced() then 2 else perTier(FX.TipCoins)
	for index = 1, count do
		local coin = takeCoin()
		local angle = random:NextNumber(0, math.pi * 2)
		local reach = random:NextNumber(2.5, 5)
		local target = ground + Vector3.new(math.cos(angle) * reach, FX.CoinSize.Y / 2, math.sin(angle) * reach)
		local height = random:NextNumber(3, 5)
		local spin = random:NextNumber(6, 12)
		local startAt = os.clock() + (index - 1) * 0.04
		local seconds = 0.7
		local placed = false
		KineticFx.run(function(now: number): boolean
			local u = (now - startAt) / seconds
			if u < 0 then
				return true
			end
			if u >= 1 then
				releaseCoin(coin)
				return false
			end
			if not placed then
				placed = true
				coin.Parent = fxFolder()
			end
			local flat = mouth:Lerp(target, u)
			local arc = Vector3.new(0, height * 4 * u * (1 - u), 0)
			coin.CFrame = CFrame.new(flat + arc) * CFrame.Angles(0, spin * u, math.pi / 2)
			return true
		end)
	end
end

--[[
	Coins drop from above into the jar (a bonus tip from TipJar.addCoins landed in it).
	@param jar Model — the TipJar model
]]
function KineticFx.coinShower(jar: Model)
	local mouth = jarMouth(jar)
	local inside = jar:GetPivot() * Vector3.new(0, JAR.CoinBottom + 1.4, 0)
	local count = if reduced() then 2 else perTier(FX.TipCoins)
	FxSound.play("pop", mouth)
	for index = 1, count do
		local coin = takeCoin()
		local offset = Vector3.new(random:NextNumber(-0.8, 0.8), 0, random:NextNumber(-0.8, 0.8))
		local top = mouth + Vector3.new(0, FX.CoinDropStuds, 0) + offset
		local bottom = inside + offset * 0.5
		local startAt = os.clock() + (index - 1) * 0.07
		local placed = false
		KineticFx.run(function(now: number): boolean
			local u = (now - startAt) / FX.CoinDropSeconds
			if u < 0 then
				return true
			end
			if u >= 1 then
				releaseCoin(coin)
				return false
			end
			if not placed then
				placed = true
				coin.Parent = fxFolder()
			end
			coin.CFrame = CFrame.new(top:Lerp(bottom, u * u)) * CFrame.Angles(u * 9, 0, math.pi / 2)
			return true
		end)
	end
end

--[[ QA: pool sizes + live steps. ]]
function KineticFx.stats(): { steps: number, nukes: number, coins: number, pops: number }
	return { steps = #steps, nukes = #nukePool, coins = #coinPool, pops = #pops }
end

return KineticFx
