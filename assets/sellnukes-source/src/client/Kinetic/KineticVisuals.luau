--!strict
--[[
	KineticVisuals — the two animated pieces of owner R90's props (docs/kinetic.md), shown the same
	way on every client from server attributes:
		swing(lever)          the candy-striped arm (pieces KineticConfig.Lever.ArmPieces) swings
		                      forward about the hinge axle (Lever.Hinge, the model's +X axis), holds,
		                      and springs back with a little wobble (PulledAt changed: anyone's pull)
		setCoins(jar, fill)   the gold Coins pile scales to `fill` of its full height with its bottom
		                      fixed (TipJar.CoinBottom); empty = hidden
	Rest poses come from MeshAssets (piece offsets) + the model pivot through
	MeshPlacement.pieceCFrame — never from the parts' current CFrames — so a swing or a fill change
	can never capture a half-flown LEGO build-in pose. While a model is still building in
	(BuildIn attribute fresh) a swing is skipped and the coin pile is applied again once it settles.

	Performance: the swing runs on KineticFx's shared driver (one transient Heartbeat); setCoins
	writes two properties on change only.

	Connects to: Shared/Config/{KineticConfig, MeshAssets, BuildInConfig}, Shared/World/
	MeshPlacement, Kinetic/KineticFx (run).

	Example:
		KineticVisuals.swing(leverModel)
		KineticVisuals.setCoins(jarModel, 0.45)
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BuildInConfig = require(ReplicatedStorage.Shared.Config.BuildInConfig)
local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)
local KineticFx = require(script.Parent.KineticFx)
local MeshAssets = require(ReplicatedStorage.Shared.Config.MeshAssets)
local MeshPlacement = require(ReplicatedStorage.Shared.World.MeshPlacement)

local LEVER = KineticConfig.Lever
local JAR = KineticConfig.TipJar

-- Seconds a build-in may still be animating after its server stamp (fresh window + the longest
-- build + one flight + slack).
local SETTLE_SECONDS = BuildInConfig.FreshWindow + BuildInConfig.MaxTotal + BuildInConfig.Flight + 0.5

local KineticVisuals = {}
KineticVisuals.SettleSeconds = SETTLE_SECONDS

-- Levers mid-swing (a new pull restarts the swing instead of stacking a second one).
local swinging: { [Model]: number } = {}

--[[
	Seconds until a model's LEGO build-in has surely finished (0 = settled / never built in).
	@param model Model
]]
function KineticVisuals.buildInLeft(model: Model): number
	if not CollectionService:HasTag(model, BuildInConfig.Tag) then
		return 0
	end
	local stamp = model:GetAttribute(BuildInConfig.TimeAttribute)
	if type(stamp) ~= "number" then
		return 0
	end
	return math.max(0, stamp + SETTLE_SECONDS - Workspace:GetServerTimeNow())
end

-- The rest CFrame of one mesh piece of a model (MeshAssets offset + pivot), or nil.
local function restOf(model: Model, key: string, part: BasePart): CFrame?
	local asset = MeshAssets[key]
	local piece = if asset ~= nil then asset.pieces[part.Name] else nil
	if piece == nil then
		return nil
	end
	return MeshPlacement.pieceCFrame(
		model:GetPivot(),
		piece.offset,
		part:GetAttribute(MeshPlacement.YawAttribute) == true
	)
end

-- Arm angle (degrees, forward) at `t` seconds into a swing; nil once the swing is over.
local function armAngle(t: number): number?
	local down, hold, up = LEVER.DownSeconds, LEVER.HoldSeconds, LEVER.UpSeconds
	local pull = LEVER.PullDegrees
	if t < down then
		local u = t / down
		return pull * (1 - (1 - u) * (1 - u)) -- ease-out: a fast yank
	elseif t < down + hold then
		return pull
	elseif t < down + hold + up then
		local u = (t - down - hold) / up
		-- Spring back with a small overshoot wobble that dies out.
		return pull * (1 - u) * (1 - u) - 9 * math.sin(u * math.pi * 2) * (1 - u)
	end
	return nil
end

--[[
	Swings a lever's arm once (any client: PulledAt changed). Skipped while the lever is still
	building in; a second pull mid-swing restarts it.
	@param lever Model — a MegaLever model
]]
function KineticVisuals.swing(lever: Model)
	if KineticVisuals.buildInLeft(lever) > 0 then
		return
	end
	local key = KineticConfig.Models.Lever
	type Arm = { part: BasePart, rest: CFrame }
	local arms: { Arm } = {}
	for _, name in LEVER.ArmPieces do
		local part = lever:FindFirstChild(name)
		if part ~= nil and part:IsA("BasePart") then
			local rest = restOf(lever, key, part)
			if rest ~= nil then
				table.insert(arms, { part = part, rest = rest })
			end
		end
	end
	if #arms == 0 then
		return
	end
	local hinge = lever:GetPivot() * CFrame.new(LEVER.Hinge)
	local hingeInverse = hinge:Inverse()
	local token = (swinging[lever] or 0) + 1
	swinging[lever] = token
	local startedAt = os.clock()
	KineticFx.run(function(now: number): boolean
		if swinging[lever] ~= token or lever.Parent == nil then
			return false
		end
		local angle = armAngle(now - startedAt)
		-- Forward = toward the model's -Z: a negative rotation about the hinge's +X axis.
		local turn = hinge * CFrame.Angles(-math.rad(angle or 0), 0, 0) * hingeInverse
		for _, arm in arms do
			arm.part.CFrame = turn * arm.rest
		end
		if angle == nil then
			swinging[lever] = nil
			return false
		end
		return true
	end)
end

--[[
	Scales a jar's coin pile to `fill` (0..1) of its full height, bottom fixed; 0 hides it.
	@param jar Model — a TipJar model
	@param fill number
]]
function KineticVisuals.setCoins(jar: Model, fill: number)
	local part = jar:FindFirstChild(JAR.CoinPiece)
	local asset = MeshAssets[KineticConfig.Models.Jar]
	local piece = if asset ~= nil then asset.pieces[JAR.CoinPiece] else nil
	if part == nil or not part:IsA("BasePart") or piece == nil then
		return
	end
	local ratio = math.clamp(if fill == fill then fill else 0, 0, 1)
	local full = piece.size
	local bottom = piece.offset.Y - full.Y / 2
	local height = math.max(full.Y * ratio, 0.05)
	local offset = Vector3.new(piece.offset.X, bottom + height / 2, piece.offset.Z)
	local size = Vector3.new(full.X, height, full.Z)
	if part.Size ~= size then
		part.Size = size
	end
	part.CFrame =
		MeshPlacement.pieceCFrame(jar:GetPivot(), offset, part:GetAttribute(MeshPlacement.YawAttribute) == true)
	local transparency = if ratio <= 0 then 1 else piece.transparency
	if part.Transparency ~= transparency then
		part.Transparency = transparency
	end
end

return KineticVisuals
