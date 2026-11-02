--!strict
--[[
	KnockdownConfig — tunables for the temporary area knockdown (owner R50: "attack mode should
	actually do something, like give you money and temporarily knockdown peoples areas depending on
	where it hits"; spec §9; docs/attack.md "Knockdown").

	What a knockdown is:
		A nuke that hits a player's plot knocks down the AREA it lands in for `duration(level)`
		seconds: its stud buildings topple apart like toy bricks (client FX only), its producer
		pauses (no income, no clicks, no manager auto-work) and then everything rebuilds with the
		master-builder fly-in. NOTHING is ever removed or refunded (hard rule 7): cash, pads,
		producers, levels, pets and gems are untouched, and the state is never saved.

	Anti-grief (owner R50 decisions, lead):
		* a plot is knockdown-IMMUNE while any of its areas is down and for `ImmunitySeconds` after
		  its last area comes back up (rebuild taps never shorten that protection);
		* barrage spill: within `VolleyGraceSeconds` of the plot's first knockdown the SAME attacker
		  may knock down at most `VolleyMaxAreas` areas in total (the barrage spills into the
		  neighbouring area), then immunity applies;
		* shields block everything (Server/Tycoon/Knockdown reads the attack profile's shieldUntil).

	Replication contract (server → every client; Client/Tycoon/BuildIn/KnockdownFx, the producer
	billboards, Q2's Rival Factories):
		CollectionService tag `Tag` on the knocked Model / Folder (a plot's `AreaNN` model, or a
		Rival Factory section); attributes `Attr.At` (server time applied), `Attr.Until` (server
		time it rebuilds; missing or <= now = up), `Attr.Center` (Vector3 impact point). Producer
		anchors carry `Attr.PausedAt` while the payout loop has them paused.

	Connects to: Server/Tycoon/Knockdown (state, loop, remote, toasts, analytics), Server/Tycoon/
	TycoonService (production pause), Server/Admin/Handlers/KnockdownHandlers, Shared/Tycoon/KnockdownLogic
	(pure rules), Client/Tycoon/BuildIn/KnockdownFx (topple + rebuild FX), Client/UI/Screens/
	Knockdown/KnockdownHudScreen (target chip), tests/knockdown-logic.luau.

	Example:
		KnockdownConfig.duration(1) --> 45
		KnockdownConfig.duration(5) --> 57
]]

-- Per-device FX budget (FxQuality tier → numbers). See Client/Tycoon/BuildIn/KnockdownFx.
export type FxBudget = {
	MaxAnimated: number, -- pieces per knockdown that tumble; the rest snap straight to the rubble
	Range: number, -- studs from the camera beyond which the topple is not animated (instant rubble)
	ConfettiScale: number, -- multiplier on the confetti puff
	MaxBonks: number, -- bonk sounds per knockdown
}

-- A key binding row (keyboard keys + gamepad buttons), same shape as AttackConfig.Client.Keys.
export type Binding = { keys: { Enum.KeyCode }, pads: { Enum.KeyCode } }

local KnockdownConfig = {}

-- Master switch (admin KnockdownToggle flips the live value in Server/Tycoon/Knockdown).
KnockdownConfig.Enabled = true

-- Duration (owner R50: "45 s, +3 s per launcher level, max 90 s"). Launcher level 1 = 45 s so a
-- fresh Attack Console matches the owner's "Rebuilding 0:45"; every level above adds 3 s.
KnockdownConfig.BaseSeconds = 45
KnockdownConfig.PerLevelSeconds = 3
KnockdownConfig.MaxSeconds = 90
-- Any requested duration is clamped to at least this (a 0 s knockdown would be a no-op).
KnockdownConfig.MinSeconds = 5
-- Admin overrides / admin test knockdowns may be longer (still bounded).
KnockdownConfig.AdminMaxSeconds = 600

-- Anti-grief immunity after the plot's last area comes back up (seconds; admin-overridable).
KnockdownConfig.ImmunitySeconds = 180
KnockdownConfig.AdminMaxImmunitySeconds = 3600
-- Barrage spill window after a plot's FIRST knockdown, and the area cap for that volley.
KnockdownConfig.VolleyGraceSeconds = 6
KnockdownConfig.VolleyMaxAreas = 2

-- "TAP TO REBUILD!": each accepted tap moves the rebuild `TapSeconds` earlier, but never earlier
-- than `MinDownSeconds` after the knockdown started (the topple always plays and lies a moment).
KnockdownConfig.TapSeconds = 1
KnockdownConfig.MinDownSeconds = 6
-- Server rate limit per player (token bucket: burst, refill per second) — ≤ 6 taps / s.
KnockdownConfig.TapBurst = 6
KnockdownConfig.TapPerSecond = 6

-- Server loop period (ends knockdowns, fires toasts). One Heartbeat, early-out when idle.
KnockdownConfig.TickSeconds = 0.25

-- Replication names.
KnockdownConfig.Tag = "KnockdownTarget"
KnockdownConfig.Attr = table.freeze({
	At = "KnockedAt",
	Until = "KnockedUntil",
	Center = "KnockCenter",
	PausedAt = "PausedAt", -- on producer anchors
	Keep = "KnockdownKeep", -- on a part: never topples (Rival Factory floors)
})
-- Child names inside a knocked target: a plot area topples its `Builds` + its `Base` (walls, arch,
-- props — never the ground); other targets topple everything; `Keep` never topples.
KnockdownConfig.BuildsFolder = "Builds"
KnockdownConfig.BaseModel = "Base"
KnockdownConfig.KeepFolder = "Keep"

-- Short area labels for toasts + the HUD chip ("Your LAB got knocked down!"), by area index.
KnockdownConfig.AreaLabels = table.freeze({
	"GARAGE",
	"NUKE STAND",
	"DELIVERY HQ",
	"GLOW MINE",
	"LAB",
	"ROCKET FACTORY",
	"LAUNCH SILOS",
	"MEGASTORE",
	"SPACE PORT",
	"MEGA FACILITY",
} :: { string })

-- Analytics vocabulary (AnalyticsConfig.Metrics.attack knockSrc / knockBlocked / knockEnd).
KnockdownConfig.Sources = table.freeze({ "normal", "revenge", "barrage", "admin", "test", "rival" } :: { string })
KnockdownConfig.BlockReasons = table.freeze({ "immune", "shielded", "not_built", "disabled" } :: { string })
KnockdownConfig.EndReasons = table.freeze({ "timer", "admin", "reset" } :: { string })

--[[
	Knockdown seconds for an attacker's Launcher level (owner R50).
	@param launcherLevel number — 1..n (anything invalid counts as level 1)
	@return number — BaseSeconds + PerLevelSeconds × (level − 1), clamped to [BaseSeconds, MaxSeconds]
	Example: KnockdownConfig.duration(3) --> 51
]]
function KnockdownConfig.duration(launcherLevel: number): number
	local level = if type(launcherLevel) == "number" and launcherLevel == launcherLevel then launcherLevel else 1
	level = math.clamp(math.floor(level), 1, 1000)
	local seconds = KnockdownConfig.BaseSeconds + KnockdownConfig.PerLevelSeconds * (level - 1)
	return math.clamp(seconds, KnockdownConfig.BaseSeconds, KnockdownConfig.MaxSeconds)
end

--[[
	The toast / chip label of an area ("AREA 11" for an index outside the table).
	Example: KnockdownConfig.areaLabel(5) --> "LAB"
]]
function KnockdownConfig.areaLabel(areaIndex: number): string
	return KnockdownConfig.AreaLabels[areaIndex] or `AREA {areaIndex}`
end

-- Client tunables (Client/Tycoon/BuildIn/KnockdownFx + the HUD chip).
KnockdownConfig.Client = table.freeze({
	-- A knockdown older than this (seconds since `At`) is shown as rubble straight away (late
	-- joiner / streamed in) instead of tumbling.
	FreshWindow = 2.5,
	-- Per-piece tumble: flight seconds, outward push (studs; pieces near the impact fly further,
	-- big pieces less), arc height, final tilt about a horizontal axis, landing bounce.
	FlightSeconds = table.freeze({ Min = 0.55, Max = 0.95 }),
	PushNear = 14, -- push at the impact point
	PushFar = 5, -- push at `PushFalloff` studs and beyond
	PushFalloff = 60,
	PushJitter = 3, -- random sideways scatter
	BigPiece = 10, -- pieces larger than this (max dimension) are pushed proportionally less
	ArcHeight = table.freeze({ Min = 2.5, Max = 7 }),
	TiltDegrees = table.freeze({ Min = 70, Max = 100 }),
	-- Flat pieces (world height < FlatAspect × their widest side: roofs, shelves, signs lying
	-- flat) only tip a little instead of standing up on edge.
	FlatAspect = 0.3,
	FlatTiltDegrees = table.freeze({ Min = 6, Max = 22 }),
	-- Ground pieces never topple and keep their collision (floors, driveways, roads, tracks):
	-- world height ≤ GroundMaxHeight and bottom within GroundTolerance of the area's lowest part.
	GroundMaxHeight = 2.5,
	GroundTolerance = 1.5,
	YawDegrees = 70, -- random extra yaw (±)
	BounceSeconds = 0.16,
	BounceHeight = 0.5,
	-- Launch spread: pieces start by distance from the impact (near first) over this many seconds,
	-- plus a small random jitter.
	Spread = 0.4,
	SpreadJitter = 0.12,
	-- FX: confetti puff at the impact (counts × tier ConfettiScale), a bonk every N landings.
	Confetti = 70,
	Sparkle = 14,
	BonkEvery = 3,
	BonkPitch = table.freeze({ Min = 0.5, Max = 0.78 }),
	-- Reduce Motion: the area fades down to this LocalTransparencyModifier and back up.
	ReducedFade = 0.7,
	ReducedFadeSeconds = 0.5,
	Tiers = table.freeze({
		Low = table.freeze({ MaxAnimated = 50, Range = 160, ConfettiScale = 0.45, MaxBonks = 4 }),
		Mid = table.freeze({ MaxAnimated = 120, Range = 220, ConfettiScale = 0.75, MaxBonks = 6 }),
		High = table.freeze({ MaxAnimated = 220, Range = 300, ConfettiScale = 1, MaxBonks = 8 }),
	} :: { [string]: FxBudget }),
	-- Dazed managers: stars orbit above the head (one pooled BillboardGui per manager).
	DazedStars = 3,
	DazedStarSpin = 200, -- degrees per second
	-- HUD chip (KnockdownHudScreen): tap REBUILD with H / LT (gamepad) / the button. Tapping is
	-- throttled on the client to the server's rate so held keys never get refused.
	TapInterval = 1 / 6,
	Keys = table.freeze({
		Rebuild = table.freeze({
			keys = table.freeze({ Enum.KeyCode.H }),
			pads = table.freeze({ Enum.KeyCode.ButtonL2 }),
		}),
	} :: { [string]: Binding }),
})

return table.freeze(KnockdownConfig)
