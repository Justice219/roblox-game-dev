--!strict
--[[
	IncomePops — floating green "+$1.25K" pops over the local player's producers when they pay
	out (server IncomePop, unreliable: `{ producerId, amount }`). Owner R57: a Dino Valley
	producer pops "+1.25K" beside the bone icon in the Bones colour (the producer's world comes
	from its billboard record; Tycoon/WorldLookup formats, Tycoon/CurrencyText lays out), and its
	coins fly into the HUD's Bones counter (CurrencyFly kind = the world currency key).

	Purpose:
		The reference tycoons float the payout above the producer. Pops are pure feedback: cash
		itself always comes from the profile sync. A dropped (unreliable) pop just shows nothing.

	Performance:
		- POOLED: TycoonClientConfig.Pops.PoolSize BillboardGuis are built once and reused (never
		  Instance.new per pop); when every one is busy the oldest is recycled.
		- Rate-limited per producer: fast producers (0.1 s cycles) would pop ten times a second, so
		  pops closer than MIN_GAP are summed into the next one (flushed by one task.delay).
		- Each pop is two tweens (rise + fade); no per-frame code.
		- Pops that would be invisible (off screen / past MaxDistance) are skipped entirely.

	Security: payload validated (table, known own producer id, finite positive amount).

	Connects to: Shared/Net/Remotes ("IncomePop"), Tycoon/ProducerBillboards (own anchors),
	Tycoon/{WorldLookup, CurrencyText},
	UI/Hud/CurrencyFly (coins fly from each pop into the HUD cash counter: "click" right after the
	player's click, "tick" for managers / the auto clicker; also its income ledger), Shared/Config/TycoonClientConfig,
	Tycoon/WorldLookup (format).

	Owner R89 Surprise Batches: IncomePops.tint(producerId, color, seconds) makes that producer's next
	pops wear a flavour colour for a moment (Tycoon/FlavorController on a FlavorPop) — the "+$X" of a
	Glitter batch pops gold, a Galaxy one purple. Display only; the amount still comes from the server.

	Example: IncomePops.start(); IncomePops.show(anchor, 1259); IncomePops.show(anchor, 80, nil, "dino")
		IncomePops.tint("garage", Color3.fromRGB(255, 214, 64), 1.2)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Contract = require(script.Parent.TycoonContract)
local Create = require(script.Parent.Parent.UI.Create)
local CurrencyFly = require(script.Parent.Parent.UI.Hud.CurrencyFly)
local CurrencyText = require(script.Parent.CurrencyText)
local ProducerBillboards = require(script.Parent.ProducerBillboards)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldLookup = require(script.Parent.WorldLookup)

local Config = TycoonClientConfig.Pops

type Pop = {
	gui: BillboardGui,
	amount: CurrencyText.Handle, -- "+$1.25K" (plain) or [icon] "+1.25K" (icon worlds)
	busyUntil: number,
	tweens: { Tween },
}

local IncomePops = {}

-- Seconds between two pops of the same producer (faster payouts are summed).
local MIN_GAP = 0.25

local pool: { Pop } = {}
local lastPop: { [string]: number } = {}
-- Owner R89: active flavour tints per producer (colour + os.clock() it ends; Tycoon/FlavorController).
local tints: { [string]: { color: Color3, untilAt: number } } = {}
local pending: { [string]: number } = {}
local started = false

-- Builds the pool once (parented on first use: PlayerGui exists by then).
local function ensurePool()
	if #pool > 0 then
		return
	end
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	for index = 1, Config.PoolSize do
		local gui = Create.new("BillboardGui", {
			Name = `IncomePop{index}`,
			Size = UDim2.fromScale(Config.SizeStuds.X, Config.SizeStuds.Y),
			MaxDistance = Config.MaxDistance,
			LightInfluence = 0,
			AlwaysOnTop = true,
			ResetOnSpawn = false,
			Enabled = false,
			Parent = playerGui,
		}) :: BillboardGui
		-- The whole pop is the amount (holder = the gui: SizeStuds.X / SizeStuds.Y aspect).
		local amount = CurrencyText.new(gui, {
			aspect = Config.SizeStuds.X / Config.SizeStuds.Y,
			font = UIStyleConfig.Fonts.Number,
			color = UIStyleConfig.Neutral.CashGreen,
			stroke = 3,
			strokeColor = UIStyleConfig.Neutral.TextStroke,
		})
		table.insert(pool, { gui = gui, amount = amount, busyUntil = 0, tweens = {} } :: Pop)
	end
end

-- A free pop (or the one finishing soonest).
local function takePop(): Pop
	ensurePool()
	local best = pool[1]
	for _, pop in pool do
		if pop.busyUntil < best.busyUntil then
			best = pop
		end
	end
	for _, tween in best.tweens do
		tween:Cancel()
	end
	table.clear(best.tweens)
	return best
end

--[[
	Shows one "+$X" pop at `adornee`, drifting along `drift` (world studs) while it fades.
	@param adornee the producer's pop point (beside its billboard) or any part / attachment
	@param amount currency paid (finite, > 0)
	@param drift world offset travelled (default straight up RiseStuds)
	@param worldId the paying producer's world (nil = Nuke Town): its currency style / icon / colour
	@param tint owner R89: a flavour colour that replaces the currency colour (nil = normal)
]]
function IncomePops.show(
	adornee: BasePart | Attachment,
	amount: number,
	drift: Vector3?,
	worldId: string?,
	tint: Color3?
)
	local pop = takePop()
	local seconds = Config.Seconds
	pop.busyUntil = os.clock() + seconds
	local withIcon = WorldLookup.usesIcon(worldId)
	local currency = WorldLookup.currencyOf(worldId)
	local handle = pop.amount
	CurrencyText.set(handle, `+{WorldLookup.format(worldId, amount)}`, if withIcon then currency.icon else nil)
	CurrencyText.setColor(handle, tint or (if withIcon then currency.color else UIStyleConfig.Neutral.CashGreen))
	local label = handle.label
	label.TextTransparency = 0
	local stroke = handle.stroke
	if stroke ~= nil then
		stroke.Transparency = 0
	end
	local image = if withIcon then CurrencyText.iconImage(handle) else nil
	if image ~= nil then
		image.ImageTransparency = 0
	end
	local jitter = Vector3.new(0, (math.random() - 0.5) * 0.8, 0)
	pop.gui.Adornee = adornee
	pop.gui.StudsOffsetWorldSpace = jitter
	pop.gui.Enabled = true
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local rise = TweenService:Create(pop.gui, info, {
		StudsOffsetWorldSpace = jitter + (drift or Vector3.new(0, Config.RiseStuds, 0)),
	})
	local fadeInfo =
		TweenInfo.new(seconds * 0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, seconds * 0.5)
	local fade = TweenService:Create(label, fadeInfo, { TextTransparency = 1 })
	pop.tweens = { rise, fade }
	if stroke ~= nil then
		table.insert(pop.tweens, TweenService:Create(stroke, fadeInfo, { Transparency = 1 }))
	end
	if image ~= nil then
		table.insert(pop.tweens, TweenService:Create(image, fadeInfo, { ImageTransparency = 1 }))
	end
	for _, tween in pop.tweens do
		tween:Play()
	end
	fade.Completed:Once(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed then
			pop.gui.Enabled = false
		end
	end)
end

-- Shows (or accumulates) a payout for an own producer.
local function onPop(producerId: string, amount: number)
	local now = os.clock()
	local last = lastPop[producerId] or -math.huge
	if now - last < MIN_GAP then
		local had = pending[producerId]
		pending[producerId] = (had or 0) + amount
		if had == nil then
			task.delay(MIN_GAP - (now - last), function()
				local total = pending[producerId]
				pending[producerId] = nil
				if total ~= nil then
					onPop(producerId, total)
				end
			end)
		end
		return
	end
	local record = ProducerBillboards.byId(producerId)
	if record == nil then
		return
	end
	lastPop[producerId] = now
	-- From beside the billboard, drifting outward + up (never over its text: owner R32). A pop
	-- nobody can see (off screen, or past the pop MaxDistance) skips the pooled-gui + text work
	-- (P2 perf pass: ~15 pops/s for one owner).
	local camera = Workspace.CurrentCamera
	local visible = true
	if camera ~= nil then
		local start = record.popPoint.WorldPosition
		local _, onScreen = camera:WorldToViewportPoint(start)
		visible = onScreen and (start - camera.CFrame.Position).Magnitude <= Config.MaxDistance
	end
	if visible then
		local tint = tints[producerId]
		local color = if tint ~= nil and tint.untilAt > now then tint.color else nil
		IncomePops.show(record.popPoint, amount, record.popDrift, record.worldId, color)
	end
	-- Coins fly from the pop into the HUD counter of the producer's currency (owner R46 / R57;
	-- visual only, on-screen only): a "click" burst right after the player's own click, else an
	-- occasional "tick". Dino producers fly bones into the Bones counter.
	CurrencyFly.fromProducer(
		amount,
		record.popPoint.WorldPosition,
		record.automated,
		record.lastClick,
		record.cycleTime,
		WorldLookup.currencyOf(record.worldId).key
	)
end

--[[
	Owner R89: the producer's pops wear `color` for `seconds` (a flavoured batch just paid). A newer
	tint replaces the old one; expired tints are ignored (no timers, checked when a pop shows).
	@param producerId string
	@param color Color3
	@param seconds number
]]
function IncomePops.tint(producerId: string, color: Color3, seconds: number)
	local untilAt = os.clock() + math.max(0, seconds)
	local entry = tints[producerId]
	if entry == nil then
		tints[producerId] = { color = color, untilAt = untilAt }
	else
		entry.color, entry.untilAt = color, untilAt -- reused: no table per flavoured pop
	end
end

--[[ Starts listening to IncomePop (once). ]]
function IncomePops.start()
	if started then
		return
	end
	started = true
	task.spawn(function()
		Remotes.unreliable("IncomePop").OnClientEvent:Connect(function(payload: unknown)
			if type(payload) ~= "table" then
				return
			end
			local data = payload :: { [string]: unknown }
			local id = Contract.str(data.producerId, "")
			local amount = Contract.num(data.amount, 0)
			if id ~= "" and amount > 0 then
				onPop(id, amount)
			end
		end)
	end)
end

return IncomePops
