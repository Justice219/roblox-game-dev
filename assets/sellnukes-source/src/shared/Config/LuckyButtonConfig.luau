--!strict
--[[
	LuckyButtonConfig — tunables of the Lucky Buttons (owner R69: "some buttons that are like 2x
	cash that just appear randomly throughout your plot ... simple things to make monetization
	better. Nothing too crazy."). Design: docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-
	design.md §1.

	Purpose:
		Every few minutes a chunky toy arcade button pops up at a random free spot on the player's
		OWN plot (whatever world they are in) and lives 45 s. Walking into it claims it:
			FREE kinds   cash burst (60 s of that world's income), 2 min 2x Cash, 2 min 2x Speed
			ROBUX kinds  a small DEAL card (owner R122) whose BUY opens the purchase prompt for a
			             deal (2x Cash 30 min, 2x Cash pass, Auto Clicker pass, that world's Large
			             pack, Skip Pad) — walking in never prompts by itself
		"Nothing too crazy": at most MaxLive buttons, at most MaxPaidLive paid, the first button of
		every session is free, a pass you own is never offered, no paid buttons in New Player Mode,
		a kind whose product is not live (id 0 / off sale) is never rolled.

	Kind fields:
		id        stable kind id (wire, analytics "lucky*:<id>", admin enum) — never rename
		paid      Robux kind (purchase prompt) vs free grant
		weight    relative roll weight among the kinds allowed right now
		label     the button's billboard label (`cash` builds its label from the amount instead)
		color     Ring + Cap tint of the Lucky_Button mesh
		ui        UIStyleConfig colour preset of the kind's on-screen arrow chip
		boost     free: BoostService key granted for `seconds`
		seconds   free boost duration
		income    free `cash`: seconds of the world's income granted (floor = the area's first pad)
		product   paid: MonetizationConfig product key ("pack" kinds resolve per world instead)
		pass      paid: MonetizationConfig pass key (rule "notOwned")
		rule      extra roll rule: "notOwned" (pass not owned), "worldPack" (that world has a live
		          Large pack), "nextPad" (the player has a next pad to skip)

	Connects to: Shared/Tycoon/LuckyButtonLogic (pure rules), Server/Services/LuckyButtonService
	(spawns / claims / prompts), Client/LuckyButtons/LuckyButtonClient (render, arrow, FX),
	Shared/Config/{MonetizationConfig, BoostConfig, AnalyticsConfig (retention lucky* keys),
	PurchasePromptConfig ("lucky" source)}, Server/Admin (LuckyToggle / LuckySpawn / LuckyInterval
	/ LuckyClear / LuckyStatus via Lazy.registerAdmin).

	Example:
		local kind = LuckyButtonConfig.byId("boost2x") --> { paid = false, boost = "cash2x", ... }
		print(LuckyButtonConfig.Lifetime) --> 45
]]

export type KindId = "cash" | "boost2x" | "speed2x" | "boost30" | "pass2x" | "autoclick" | "pack" | "skip"
export type Rule = "notOwned" | "worldPack" | "nextPad"

export type Kind = {
	id: KindId,
	paid: boolean,
	weight: number,
	label: string,
	color: Color3,
	ui: string,
	boost: string?,
	seconds: number?,
	income: number?,
	product: string?,
	pass: string?,
	rule: Rule?,
}

local LuckyButtonConfig = {}

-- Kind colours (spec: green cash, gold 2x, blue speed, purple Robux).
local GREEN = Color3.fromRGB(96, 214, 70)
local GOLD = Color3.fromRGB(255, 196, 40)
local BLUE = Color3.fromRGB(70, 150, 255)
local PURPLE = Color3.fromRGB(170, 90, 255)

-- Every kind in a fixed order (analytics choice sets + the admin enum follow this order).
LuckyButtonConfig.Kinds = table.freeze({
	table.freeze({
		id = "cash",
		paid = false,
		weight = 38,
		label = "FREE CASH!",
		color = GREEN,
		ui = "green",
		income = 60,
	}) :: Kind,
	table.freeze({
		id = "boost2x",
		paid = false,
		weight = 14,
		label = "2x CASH 2 MIN!",
		color = GOLD,
		ui = "yellow",
		boost = "cash2x",
		seconds = 120,
	}) :: Kind,
	table.freeze({
		id = "speed2x",
		paid = false,
		weight = 8,
		label = "2x SPEED 2 MIN!",
		color = BLUE,
		ui = "blue",
		boost = "speed2x",
		seconds = 120,
	}) :: Kind,
	table.freeze({
		id = "boost30",
		paid = true,
		weight = 14,
		label = "2x CASH 30 MIN",
		color = PURPLE,
		ui = "purple",
		product = "Cash2x30",
	}) :: Kind,
	table.freeze({
		id = "pass2x",
		paid = true,
		weight = 9,
		label = "2x CASH FOREVER!",
		color = PURPLE,
		ui = "purple",
		pass = "DoubleCash",
		rule = "notOwned",
	}) :: Kind,
	table.freeze({
		id = "autoclick",
		paid = true,
		weight = 4,
		label = "AUTO CLICKER!",
		color = PURPLE,
		ui = "purple",
		pass = "AutoClicker",
		rule = "notOwned",
	}) :: Kind,
	table.freeze({
		id = "pack",
		paid = true,
		weight = 8,
		label = "CASH CRATE!",
		color = PURPLE,
		ui = "purple",
		rule = "worldPack",
	}) :: Kind,
	table.freeze({
		id = "skip",
		paid = true,
		weight = 5,
		label = "SKIP PAD!",
		color = PURPLE,
		ui = "purple",
		product = "SkipPad",
		rule = "nextPad",
	}) :: Kind,
}) :: { Kind }

-- Kind ids in config order (admin enum values, analytics choice set).
local ids: { KindId } = {}
for _, kind in LuckyButtonConfig.Kinds do
	table.insert(ids, kind.id)
end
LuckyButtonConfig.KindIds = table.freeze(ids)

-- ── Spawning (server) ────────────────────────────────────────────────────────────────────────

-- First button: this long after the player first stands on their plot in a world (seconds).
LuckyButtonConfig.FirstDelayMin = 45
LuckyButtonConfig.FirstDelayMax = 75
-- Later buttons: this long after the previous one ended (claimed / expired / bought).
LuckyButtonConfig.DelayMin = 120
LuckyButtonConfig.DelayMax = 240
-- Seconds a button lives; it blinks for the last BlinkSeconds.
LuckyButtonConfig.Lifetime = 45
LuckyButtonConfig.BlinkSeconds = 8
-- Live caps per player.
LuckyButtonConfig.MaxLive = 2
LuckyButtonConfig.MaxPaidLive = 1
-- No new spawns after this many seconds without activity (movement, a claim, a pad bought).
LuckyButtonConfig.AfkSeconds = 240
-- Studs the character root must move between server ticks to count as activity.
LuckyButtonConfig.ActivityMoveStuds = 1.5
-- Server loop period (seconds): ONE loop for every player.
LuckyButtonConfig.TickSeconds = 1

-- ── Placement (server; slot-local studs, see Shared/Config/WorldLayout) ───────────────────────

-- Never closer than this to a pad / producer / billboard / another button (spec §1.1).
LuckyButtonConfig.Clearance = 7
-- Walls, buildings and props: no overlap with the button's base (ButtonRadius) + a little air.
LuckyButtonConfig.PropClearance = 3.7
-- Valid spots are pre-computed per slot on this grid (studs); a pick jitters around one.
LuckyButtonConfig.GridStep = 4
LuckyButtonConfig.Jitter = 1.5
-- Random spot draws per roll (from the slot's pre-computed valid spots) before it is skipped.
LuckyButtonConfig.MaxPicks = 12
-- Kept inside the slot edges (x ∈ [-52 + m, 52 - m], z ∈ [m, 70 - m]).
LuckyButtonConfig.SlotMargin = 6
-- A collider whose top lies within this many studs of the slot's ground plane (y = 0) is walkable
-- ground (support); flat props within it (lots, lane paint) are ignored.
LuckyButtonConfig.GroundTolerance = 1.25
-- Boxes whose bottom is at least this high (arch beams, high signs) are overhead: ignored. Lower
-- ones (roofs, canopies) block the spot.
LuckyButtonConfig.HeadRoom = 20
-- The button's base radius: the whole base must sit on one support (no overhang over a gap).
LuckyButtonConfig.ButtonRadius = 2.7
-- Pad footprint half size (PlotBuilder pad trigger 7 x 3 x 7).
LuckyButtonConfig.PadHalf = 3.5
-- Billboard footprint half size (boards stand on legs; this covers the legs + the sign).
LuckyButtonConfig.BillboardHalf = 4

-- ── Claims / prompts (server) ─────────────────────────────────────────────────────────────────

-- The client claims within ClaimRadius (horizontal studs); the server accepts + ClaimSlack (lag).
LuckyButtonConfig.ClaimRadius = 4.5
LuckyButtonConfig.ClaimSlack = 4
-- Highest the character root may be above the button and still claim: generous, so a kid jumping
-- onto it counts — Moon Base's 0.4 g jump apex measures 21.8 studs + ~3 root height (W10b; PadReachVertical
-- is 28 for the same reason). Reach is checked horizontally; this is only the vertical allowance.
LuckyButtonConfig.ClaimHeight = 30
-- One purchase prompt per paid button per this many seconds.
LuckyButtonConfig.PromptCooldown = 6
-- A receipt for a product / pass within this many seconds of its lucky prompt counts as
-- luckyPurchased (and removes the paid button that prompted it).
LuckyButtonConfig.PurchaseWindow = 120
-- LuckyButtonClaim token bucket per player.
LuckyButtonConfig.ClaimBurst = 4
LuckyButtonConfig.ClaimPerSecond = 2
-- Button ids are "L<number>" (wire + claim validation).
LuckyButtonConfig.IdPrefix = "L"
LuckyButtonConfig.IdMaxLength = 24
-- Analytics + purchase-prompt source.
LuckyButtonConfig.PromptSource = "lucky"
-- PlayerDataService grant reason of the free cash kind.
LuckyButtonConfig.GrantReason = "luckyButton"

-- ── Admin (owner panel) ───────────────────────────────────────────────────────────────────────

-- ReplicatedStorage attributes: the kill switch (false = no spawns, live buttons cleared) and
-- the spawn-interval multiplier (delays x this).
LuckyButtonConfig.EnabledAttribute = "LuckyButtonsEnabled"
LuckyButtonConfig.IntervalAttribute = "LuckyButtonsInterval"
LuckyButtonConfig.IntervalMin = 0.25
LuckyButtonConfig.IntervalMax = 10

-- ── DEAL card (owner R122, spec §2.4: no accidental purchase prompts) ──────────────────────────────

--[[
	Walking into a PAID button no longer opens the Robux prompt (10-31: 30 lucky prompts, 20 closed
	in under 2 s). It opens a small non-blocking DEAL card (UI/Screens/DealCard at the bottom of the
	feed: product art, name, line, live price, BUY + CLOSE; never auto-focused on console, X / E or a
	tap buys — never A, which is jump while running). Only BUY sends LuckyButtonClaim(id, "buy") and
	the server prompts (PromptCooldown, attribution and every other rule unchanged). Free kinds are
	unchanged (walk in = claim).
		Radii   the card shows when the character enters ClaimRadius (the same walk-in) and stays
		        while it is within KeepRadius (hysteresis: no flicker on the edge); walking past
		        KeepRadius hides it. After CLOSE / BUY it stays away until the player walks out of
		        KeepRadius and back in.
		Server  "buy" is accepted within KeepRadius + ClaimSlack (the card is still up there); each
		        report is counted at most MaxReportsPerButton times per button.
	Analytics (retention): luckyDeal:<shown|buy|close>:<kind> (close = the player dismissed it).
]]
LuckyButtonConfig.Deal = table.freeze({
	Actions = table.freeze({ "shown", "buy", "close" }),
	KeepRadius = 9,
	MaxReportsPerButton = 8,
})

-- ── Client look / feel ────────────────────────────────────────────────────────────────────────

LuckyButtonConfig.Client = table.freeze({
	MeshKey = "Lucky_Button",
	-- Model scale (the mesh is ~4.8 studs wide, cap top at 2.15).
	Scale = 1.1,
	-- Bob (studs, Hz) and spin (degrees / s); Reduce Motion freezes both.
	BobHeight = 0.35,
	BobHz = 0.8,
	SpinDegrees = 50,
	-- Pop-in: scale from this to 1 over PopSeconds (Reduce Motion: instant).
	PopFrom = 0.2,
	PopSeconds = 0.35,
	-- Blink in the last BlinkSeconds: the cap glows on / off at this rate (Hz).
	BlinkHz = 3,
	-- Beam to the sky: height (studs), width, transparency; Low graphics keeps it (it is how
	-- buttons are found) but thinner.
	BeamHeight = 70,
	BeamWidth = 1.6,
	BeamWidthLow = 1,
	BeamTransparency = 0.45,
	-- Sparkles (Mid / High graphics only; Reduce Motion halves the rate).
	SparkleRate = 8,
	-- Label billboard: size (studs), offset above the cap, visible distance.
	LabelSize = Vector2.new(9, 3.4),
	LabelOffset = 5,
	LabelMaxDistance = 160,
	-- Models farther than this are hidden (and skip the per-frame update).
	RenderDistance = 450,
	-- Behind-the-camera / off-screen models skip their per-frame motion (ViewCone margin, deg).
	ConeMargin = 12,
	-- Spawn toast + icon (IconAssets key; StudUI.hasIcon falls back to IconFallback).
	ToastText = "LUCKY BUTTON!",
	Icon = "LuckyButton",
	IconFallback = "Star",
	-- Sounds: the first key that exists in AudioConfig.Sfx is played (H1's lucky_* keys are live;
	-- the fallbacks only cover an older AudioConfig). spawn / claim are 2D, blink is 3D.
	Sounds = table.freeze({
		spawn = table.freeze({ "lucky_spawn", "sparkle" }),
		claim = table.freeze({ "lucky_claim", "ui_claim" }),
		blink = table.freeze({ "lucky_blink", "pop" }),
	}),
	-- Claim FX: confetti pieces + sparkles at the button (Reduce Motion / Low: fewer).
	Confetti = 26,
	Sparkles = 10,
	-- Re-send a claim for the same button at most this often (the server rate-limits too).
	ClaimRetrySeconds = 1,
	-- Edge arrow (design px at 1080p): size, inset from the safe screen edge, and the extra
	-- clearance kept around the touch thumbstick / jump zones.
	ArrowSize = 92,
	ArrowInset = 70,
	ArrowTouchClearance = 16,
	-- The arrow shows while the nearest button is off-screen or farther than this (studs).
	ArrowNearStuds = 24,
})

--[[
	The kind with `id`, or nil for an unknown id.
	@param id any value (non-strings → nil)
	@return Kind?
	Example: LuckyButtonConfig.byId("skip").product --> "SkipPad"
]]
function LuckyButtonConfig.byId(id: unknown): Kind?
	if type(id) ~= "string" then
		return nil
	end
	for _, kind in LuckyButtonConfig.Kinds do
		if kind.id == id then
			return kind
		end
	end
	return nil
end

return table.freeze(LuckyButtonConfig)
