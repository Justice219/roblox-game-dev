--!strict
--[[
	GravityLogic — pure maths of the per-world gravity twist (owner R70: Moon Base low gravity).
	No Instances, no services: Client/Worlds/WorldGravity applies the answers, tests/world-gravity
	.luau proves them.

	Functions:
		scaleFor(physics, worldId, limits)  the gravity multiplier of a world (1 when it has no row
		                                    or a broken one), clamped to the limits
		gravity(default, scale)             Workspace.Gravity for a scale (never compounds)
		landing(fallSpeed, scale, cfg)      should a touchdown boing + puff, at what pitch, how many
		                                    dust particles (before the device-tier scale)
		jumpHeight(jumpPower, gravity)      apex of a JumpPower jump (studs) — docs / reach checks

	Example:
		local scale = GravityLogic.scaleFor(WorldClientConfig.Physics, "moon", Config.Limits) --> 0.4
		Workspace.Gravity = GravityLogic.gravity(196.2, scale)                               --> 78.48
]]

local GravityLogic = {}

export type PhysicsRow = { gravityScale: number? }
export type LandingCfg = {
	FxBelowScale: number,
	MinFallSpeed: number,
	PitchBase: number,
	PitchPerSpeed: number,
	PitchMaxBonus: number,
}
export type PuffCount = { CountMin: number, CountMax: number, CountPerSpeed: number }
export type Limits = { MinScale: number, MaxScale: number }

-- A finite number, else nil.
local function finite(value: unknown): number?
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

--[[
	The gravity multiplier of a world: `physics[worldId].gravityScale` clamped to [MinScale,
	MaxScale]; 1 for a world without a row, a non-table row or a non-finite / non-positive value
	(a config typo never strands a player in zero gravity).
	@param physics WorldClientConfig.Physics (any shape; nil = no world has a row)
	@param worldId the world the player is in
	@param limits  WorldGravityConfig.Limits
	Example: GravityLogic.scaleFor({ moon = { gravityScale = 0.4 } }, "moon", limits) --> 0.4
]]
function GravityLogic.scaleFor(physics: unknown, worldId: string, limits: Limits): number
	if type(physics) ~= "table" then
		return 1
	end
	local row = (physics :: { [string]: unknown })[worldId]
	if type(row) ~= "table" then
		return 1
	end
	local scale = finite((row :: { [string]: unknown }).gravityScale)
	if scale == nil or scale <= 0 then
		return 1
	end
	return math.clamp(scale, limits.MinScale, limits.MaxScale)
end

--[[
	Workspace.Gravity for a scale, always from the captured default (applying twice never compounds).
	Example: GravityLogic.gravity(196.2, 0.4) --> 78.48
]]
function GravityLogic.gravity(default: number, scale: number): number
	return default * scale
end

--[[
	Apex height (studs) of a JumpPower jump under `gravity`: v² / 2g.
	Example: GravityLogic.jumpHeight(55, 78.48) --> 19.27
]]
function GravityLogic.jumpHeight(jumpPower: number, gravity: number): number
	if gravity <= 0 then
		return math.huge
	end
	return jumpPower * jumpPower / (2 * gravity)
end

--[[
	The feedback of one touchdown.
	@param fallSpeed downward speed (studs/s, >= 0) just before touching the ground
	@param scale     the current world's gravity scale (feedback only below cfg.FxBelowScale)
	@param cfg       WorldGravityConfig.Landing
	@param puff      WorldGravityConfig.Puff (particle counts)
	@return (play, pitch, count): play = false for normal gravity or a tiny hop; pitch rises with
	        the fall speed (capped); count = dust particles before the device-tier multiplier
	Example: GravityLogic.landing(30, 0.4, Landing, Puff) --> true, 1.033, 10
]]
function GravityLogic.landing(
	fallSpeed: number,
	scale: number,
	cfg: LandingCfg,
	puff: PuffCount
): (boolean, number, number)
	local speed = finite(fallSpeed) or 0
	if scale >= cfg.FxBelowScale or speed < cfg.MinFallSpeed then
		return false, cfg.PitchBase, 0
	end
	local over = speed - cfg.MinFallSpeed
	local pitch = cfg.PitchBase + math.min(over * cfg.PitchPerSpeed, cfg.PitchMaxBonus)
	local count = math.clamp(math.floor(puff.CountMin + over * puff.CountPerSpeed), puff.CountMin, puff.CountMax)
	return true, pitch, count
end

return table.freeze(GravityLogic)
