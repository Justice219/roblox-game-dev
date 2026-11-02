--!strict
--[[
	HatchConfetti — the pooled screen-space confetti + sparkle twinkles of the hatch reveal
	(owner R49 "confetti/sparkles scaled by rarity", R22 particles on everything).

	Two kinds of pieces, all from ONE fixed pool of plain Frames built once with the screen:
		confetti  little candy-coloured paper strips shot up from the egg in a cone, tumbling
		          (Rotation), pulled down by gravity, slowed by air drag, fading at the end
		sparkle   a diamond that twinkles in place around the pet (grow → shrink)
	A burst asking for more pieces than are free re-uses the oldest live ones (never allocates).

	Performance (owner R11): zero Instance.new after `new`; the screen calls `step(dt)` from its
	single RenderStepped connection; a parked piece is Visible = false and costs nothing; property
	writes only for live pieces.

	Connects to: Shared/Config/HatchAnimConfig (Confetti budgets / colours), UI/Create,
	UI/Screens/EggHatch/HatchRevealScreen (the only owner).

	Example:
		local confetti = HatchConfetti.new(stage, 96, 8)
		confetti.burst(Vector2.new(700, 300), 40, HatchAnimConfig.Confetti.Party)
		confetti.sparkle(Vector2.new(700, 300), 150, 12, Color3.new(1, 0.9, 0.4))
		confetti.step(dt) -- every frame while the screen is open
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Parent.Create)
local HatchAnimConfig = require(ReplicatedStorage.Shared.Config.HatchAnimConfig)

local Cfg = HatchAnimConfig.Confetti

type Piece = {
	frame: Frame,
	live: boolean,
	sparkle: boolean,
	born: number,
	life: number,
	position: Vector2,
	velocity: Vector2,
	rotation: number,
	spin: number,
	size: Vector2,
}

export type Confetti = {
	burst: (origin: Vector2, count: number, palette: { Color3 }) -> (),
	sparkle: (origin: Vector2, radius: number, count: number, color: Color3) -> (),
	step: (dt: number) -> (),
	clear: () -> (),
	active: () -> number,
	Destroy: () -> (),
}

local HatchConfetti = {}

--[[
	Builds the pool under `parent` (a full-stage, transparent, non-clipping Frame).
	@param parent  layer the pieces live in (design px coordinates)
	@param size    pool size (HatchAnimConfig.Confetti.Pool)
	@param zIndex  ZIndex of every piece
	@return Confetti handle
]]
function HatchConfetti.new(parent: GuiObject, size: number, zIndex: number): Confetti
	local random = Random.new()
	local pieces: { Piece } = {}
	local clock = 0
	local liveCount = 0
	for index = 1, math.max(1, size) do
		local frame = Create.new("Frame", {
			Name = `Confetti{index}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			BorderSizePixel = 0,
			Visible = false,
			Active = false,
			Selectable = false,
			ZIndex = zIndex,
			Parent = parent,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 3) }) },
		}) :: Frame
		table.insert(pieces, {
			frame = frame,
			live = false,
			sparkle = false,
			born = 0,
			life = 1,
			position = Vector2.zero,
			velocity = Vector2.zero,
			rotation = 0,
			spin = 0,
			size = Vector2.one,
		})
	end

	-- A free piece, or the oldest live one when the pool is exhausted.
	local function take(): Piece
		local oldest: Piece = pieces[1]
		for _, piece in pieces do
			if not piece.live then
				return piece
			end
			if piece.born < oldest.born then
				oldest = piece
			end
		end
		liveCount -= 1
		return oldest
	end

	local function park(piece: Piece)
		if piece.live then
			piece.live = false
			piece.frame.Visible = false
			liveCount -= 1
		end
	end

	local function between(range: Vector2): number
		return random:NextNumber(range.X, range.Y)
	end

	local handle: Confetti
	handle = {
		burst = function(origin: Vector2, count: number, palette: { Color3 })
			if #palette == 0 then
				return
			end
			for _ = 1, math.max(0, math.floor(count)) do
				local piece = take()
				local angle = math.rad(random:NextNumber(-Cfg.Spread, Cfg.Spread))
				local speed = between(Cfg.Speed)
				local width = between(Cfg.Size)
				piece.live = true
				piece.sparkle = false
				piece.born = clock
				piece.life = between(Cfg.Life)
				piece.position = origin
				piece.velocity = Vector2.new(math.sin(angle) * speed, -math.cos(angle) * speed)
				piece.rotation = random:NextNumber(0, 360)
				piece.spin = between(Cfg.Spin) * (if random:NextNumber() < 0.5 then -1 else 1)
				piece.size = Vector2.new(width, width * random:NextNumber(0.45, 0.7))
				local frame = piece.frame
				frame.BackgroundColor3 = palette[random:NextInteger(1, #palette)]
				frame.BackgroundTransparency = 0
				frame.Size = UDim2.fromOffset(piece.size.X, piece.size.Y)
				frame.Position = UDim2.fromOffset(origin.X, origin.Y)
				frame.Rotation = piece.rotation
				frame.Visible = true
				liveCount += 1
			end
		end,
		sparkle = function(origin: Vector2, radius: number, count: number, color: Color3)
			for _ = 1, math.max(0, math.floor(count)) do
				local piece = take()
				local angle = random:NextNumber(0, math.pi * 2)
				local distance = radius * math.sqrt(random:NextNumber())
				local side = between(Cfg.SparkleSize)
				piece.live = true
				piece.sparkle = true
				-- Staggered start: twinkles appear one after another, not all at once.
				piece.born = clock + random:NextNumber(0, 0.5)
				piece.life = between(Cfg.SparkleLife)
				piece.position = origin + Vector2.new(math.cos(angle), math.sin(angle)) * distance
				piece.velocity = Vector2.zero
				piece.rotation = 45
				piece.spin = 0
				piece.size = Vector2.new(side, side)
				local frame = piece.frame
				frame.BackgroundColor3 = color:Lerp(Color3.new(1, 1, 1), 0.45)
				frame.BackgroundTransparency = 1
				frame.Size = UDim2.fromOffset(0, 0)
				frame.Position = UDim2.fromOffset(piece.position.X, piece.position.Y)
				frame.Rotation = 45
				frame.Visible = true
				liveCount += 1
			end
		end,
		step = function(dt: number)
			clock += dt
			if liveCount <= 0 then
				return
			end
			local drag = Cfg.Drag ^ dt
			for _, piece in pieces do
				if piece.live then
					local age = clock - piece.born
					if age >= piece.life then
						park(piece)
					elseif piece.sparkle then
						if age >= 0 then
							-- Grow fast, shrink slowly; fully opaque only at the peak.
							local u = age / piece.life
							local s = if u < 0.3 then u / 0.3 else 1 - (u - 0.3) / 0.7
							local frame = piece.frame
							frame.Size = UDim2.fromOffset(piece.size.X * s, piece.size.Y * s)
							frame.BackgroundTransparency = 1 - s * 0.9
						end
					else
						piece.velocity =
							Vector2.new(piece.velocity.X * drag, piece.velocity.Y * drag + Cfg.Gravity * dt)
						piece.position += piece.velocity * dt
						piece.rotation += piece.spin * dt
						local frame = piece.frame
						frame.Position = UDim2.fromOffset(piece.position.X, piece.position.Y)
						frame.Rotation = piece.rotation % 360
						local u = age / piece.life
						if u > 0.7 then
							frame.BackgroundTransparency = (u - 0.7) / 0.3
						end
					end
				end
			end
		end,
		clear = function()
			for _, piece in pieces do
				park(piece)
			end
			liveCount = 0
		end,
		active = function(): number
			return liveCount
		end,
		Destroy = function()
			for _, piece in pieces do
				piece.frame:Destroy()
			end
			table.clear(pieces)
			liveCount = 0
		end,
	}
	return handle
end

return HatchConfetti
