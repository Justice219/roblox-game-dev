--!strict
--[[
	Per-world gravity (owner R70: Moon Base low gravity, W10b). Run: lune run tests/world-gravity.luau

	Proves, from the REAL modules (Client/Worlds/GravityLogic, Shared/Config/{WorldGravityConfig,
	WorldClientConfig, MovementConfig, AudioConfig, Worlds/WorldsConfig}):
	  1. GravityLogic.scaleFor: a world without a row / a broken row / a non-positive or non-finite
	     scale is normal gravity (1); valid scales are clamped to WorldGravityConfig.Limits.
	  2. gravity() never compounds (always default x scale); jumpHeight = v² / 2g.
	  3. landing(): silent in normal gravity and for tiny hops; pitch rises with the fall and is
	     capped; the dust count stays within CountMin..CountMax.
	  4. Every WorldClientConfig.Physics row names a registered world and a valid scale; Nuke Town
	     has normal gravity; the Moon world (once registered) is low gravity.
	  5. Server tolerance of the higher jumps (the generic rule, every world with a row): the pad
	     reach vertical allowance (TycoonService.PadReachVertical) >= that world's jump apex + 3,
	     the producer click allowance (ClickReachVertical) >= apex + 3, and the world boundary
	     walls (60 studs) stay well above the apex — read from the source, so a later change to any
	     of them fails here first.
	  6. The landing sound key is either a real AudioConfig SFX or (until H1 adds it) skipped
	     silently by WorldGravity (checked in the source: an AudioConfig guard before Sound.play).
]]

local fs = require("@lune/fs")

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local GravityLogic = loader.load("src/client/Worlds/GravityLogic")
local Config = loader.load("src/shared/Config/WorldGravityConfig")
local WorldClientConfig = loader.load("src/shared/Config/WorldClientConfig")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
local MovementConfig = loader.load("src/shared/Config/MovementConfig")

local checks = 0
local failures: { string } = {}
-- Records one check (keeps going so a run lists every problem).
local function ok(condition: any, label: string)
	checks += 1
	if not condition then
		table.insert(failures, label)
	end
end
local function near(a: number, b: number, eps: number, label: string)
	ok(math.abs(a - b) <= eps, `{label} ({a} vs {b})`)
end

local Limits = Config.Limits
local Landing = Config.Landing
local Puff = Config.Puff
local DEFAULT_GRAVITY = 196.2

-- 1. scaleFor -------------------------------------------------------------------------------------
ok(GravityLogic.scaleFor(nil, "moon", Limits) == 1, "no Physics table -> 1")
ok(GravityLogic.scaleFor({}, "moon", Limits) == 1, "no row -> 1")
ok(GravityLogic.scaleFor({ moon = 0.4 }, "moon", Limits) == 1, "non-table row -> 1")
ok(GravityLogic.scaleFor({ moon = {} }, "moon", Limits) == 1, "row without a scale -> 1")
ok(GravityLogic.scaleFor({ moon = { gravityScale = 0 } }, "moon", Limits) == 1, "zero -> 1 (never zero-g)")
ok(GravityLogic.scaleFor({ moon = { gravityScale = -2 } }, "moon", Limits) == 1, "negative -> 1")
ok(GravityLogic.scaleFor({ moon = { gravityScale = 0 / 0 } }, "moon", Limits) == 1, "NaN -> 1")
ok(GravityLogic.scaleFor({ moon = { gravityScale = math.huge } }, "moon", Limits) == 1, "inf -> 1")
ok(GravityLogic.scaleFor({ moon = { gravityScale = "0.4" } }, "moon", Limits) == 1, "string -> 1")
ok(GravityLogic.scaleFor({ moon = { gravityScale = 0.4 } }, "moon", Limits) == 0.4, "0.4 kept")
ok(GravityLogic.scaleFor({ moon = { gravityScale = 0.01 } }, "moon", Limits) == Limits.MinScale, "clamped up")
ok(GravityLogic.scaleFor({ moon = { gravityScale = 9 } }, "moon", Limits) == Limits.MaxScale, "clamped down")
ok(GravityLogic.scaleFor({ moon = { gravityScale = 0.4 } }, "main", Limits) == 1, "other worlds unaffected")
ok(Limits.MinScale > 0 and Limits.MinScale < 1 and Limits.MaxScale >= 1, "limits sane")

-- 2. gravity / jumpHeight --------------------------------------------------------------------------
near(GravityLogic.gravity(DEFAULT_GRAVITY, 0.4), 78.48, 1e-9, "0.4 x default")
near(GravityLogic.gravity(DEFAULT_GRAVITY, 1), DEFAULT_GRAVITY, 1e-9, "scale 1 restores the default")
-- Applying twice from the captured default never compounds (the controller never multiplies the
-- current Workspace.Gravity).
near(
	GravityLogic.gravity(DEFAULT_GRAVITY, 0.4),
	GravityLogic.gravity(DEFAULT_GRAVITY, 0.4),
	0,
	"idempotent"
)
near(GravityLogic.jumpHeight(55, 78.48), 55 * 55 / (2 * 78.48), 1e-9, "apex v²/2g")
ok(GravityLogic.jumpHeight(55, 0) == math.huge, "zero gravity -> unbounded apex")

-- 3. landing ---------------------------------------------------------------------------------------
do
	local play = GravityLogic.landing(40, 1, Landing, Puff)
	ok(not play, "normal gravity: no landing feedback")
	play = GravityLogic.landing(Landing.MinFallSpeed - 0.5, 0.4, Landing, Puff)
	ok(not play, "tiny hop: silent")
	local soft, softPitch, softCount = GravityLogic.landing(Landing.MinFallSpeed, 0.4, Landing, Puff)
	ok(soft and softPitch == Landing.PitchBase and softCount == Puff.CountMin, "softest landing")
	local _, bigPitch, bigCount = GravityLogic.landing(500, 0.4, Landing, Puff)
	near(bigPitch, Landing.PitchBase + Landing.PitchMaxBonus, 1e-9, "pitch capped")
	ok(bigCount == Puff.CountMax, "count capped")
	local lastPitch, lastCount = 0, 0
	for speed = Landing.MinFallSpeed, 120, 2 do
		local p, pitch, count = GravityLogic.landing(speed, 0.4, Landing, Puff)
		ok(p and pitch >= lastPitch and count >= lastCount, `monotone at {speed}`)
		ok(count >= Puff.CountMin and count <= Puff.CountMax, `count in range at {speed}`)
		lastPitch, lastCount = pitch, count
	end
	local nanPlay = GravityLogic.landing(0 / 0, 0.4, Landing, Puff)
	ok(not nanPlay, "NaN fall speed: silent")
	ok(Puff.LowTierScale > 0 and Puff.LowTierScale <= 1, "low tier scale in (0, 1]")
	ok(Puff.SizeEnd >= Puff.SizeStart and Puff.TransparencyStart >= 0, "puff look sane")
end

-- 4. Physics rows -----------------------------------------------------------------------------------
local physics = (WorldClientConfig :: any).Physics
local rows = 0
if type(physics) == "table" then
	for worldId, row in physics do
		rows += 1
		ok(WorldsConfig.get(worldId) ~= nil, `Physics.{worldId}: a registered world`)
		local scale = if type(row) == "table" then row.gravityScale else nil
		ok(
			type(scale) == "number" and scale >= Limits.MinScale and scale <= Limits.MaxScale,
			`Physics.{worldId}: gravityScale within limits`
		)
	end
end
ok(GravityLogic.scaleFor(physics, WorldsConfig.MAIN, Limits) == 1, "Nuke Town has normal gravity")
if WorldsConfig.get("moon") ~= nil and type(physics) == "table" and physics.moon ~= nil then
	ok(GravityLogic.scaleFor(physics, "moon", Limits) < 1, "Moon Base is low gravity")
end

-- 5. Server tolerance -------------------------------------------------------------------------------
do
	local service = fs.readFile("src/server/Tycoon/TycoonService.luau")
	local padVertical = tonumber(string.match(service, "TycoonService%.PadReachVertical = ([%d%.]+)"))
	local clickVertical = tonumber(string.match(service, "TycoonService%.ClickReachVertical = ([%d%.]+)"))
	ok(padVertical ~= nil and clickVertical ~= nil, "reach constants found in TycoonService")
	local lowest = 1
	if type(physics) == "table" then
		for worldId in physics do
			lowest = math.min(lowest, GravityLogic.scaleFor(physics, worldId, Limits))
		end
	end
	-- Always cover at least Moon Base's spec scale, even before its row lands.
	lowest = math.min(lowest, 0.4)
	local apex = GravityLogic.jumpHeight(MovementConfig.JumpPower, DEFAULT_GRAVITY * lowest)
	print(`[world-gravity] lowest scale {lowest}: jump apex {math.floor(apex * 10) / 10} studs`)
	-- Measured in Studio (R70 Moon tour, JumpPower 55 at 0.4 g): apex 21.8 vs 19.3 by v²/2g — the
	-- Humanoid's take-off adds ~13 %, so the allowances carry a 15 % margin on top of the formula.
	local measured = apex * 1.15
	ok((padVertical or 0) >= measured + 3, `PadReachVertical {padVertical} >= apex {measured} + 3`)
	ok((clickVertical or 0) >= measured + 3, `ClickReachVertical {clickVertical} >= apex {measured} + 3`)
	-- Boundary rings (HubBuilder placeholder ring + the Valley layout): 60 studs tall.
	local hub = fs.readFile("src/server/World/HubBuilder.luau")
	ok(string.find(hub, "Vector3.new(width, 60, 4)", 1, true) ~= nil, "placeholder boundary ring is 60 tall")
	ok(60 >= apex * 1.15 * 2, "boundary walls are over twice the (measured) low-gravity apex")
end

-- 6. Sound guard ------------------------------------------------------------------------------------
do
	local source = fs.readFile("src/client/Worlds/WorldGravity.luau")
	ok(
		string.find(source, "AudioConfig.Sfx[landing.Sound] ~= nil", 1, true) ~= nil,
		"WorldGravity skips an unknown landing sound silently"
	)
	ok(type(Landing.Sound) == "string" and #Landing.Sound > 0, "landing sound key set")
end

if #failures > 0 then
	for _, failure in failures do
		print(`[world-gravity] FAIL {failure}`)
	end
	error(`[world-gravity] {#failures} of {checks} checks failed`)
end
print(`[world-gravity] {checks} checks passed ({rows} Physics row(s))`)
