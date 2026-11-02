--!strict
--[[
	FlavorConfig — every number of the R89 Surprise Batches (core-loop luck), the Flavour Book and the
	Big Pop broadcast (spec docs/superpowers/specs/2026-10-31-r89-competitive-wave-design.md §1).

	The idea (owner R89, "make our game super unique"):
		Every finished producer batch (one cycle) rolls a FLAVOUR on the server. Plain is the normal
		batch; the five special flavours pay `mult` x the batch and are shown to players with their
		"1 in N" odds. The first time a flavour pops in a world it lands in the Flavour Book, where
		its discovery reward (`gems`) is claimed once. Galaxy+ batches, Mythic+ hatches and rebirths
		fire a server-wide Big Pop (banner + system chat line + toy fireworks over that plot).

	Flavours (rank 0 = Plain, rising rarity; `oneIn` = base odds per batch, `mult` = payout):
		Plain        —            x1
		Sprinkle     1 in 20      x1.5    5 gems
		Glitter      1 in 100     x3     10 gems
		Rainbow      1 in 500     x5     25 gems    (+ a rainbow glow on the producer, everyone sees it)
		Galaxy       1 in 2,500   x20    60 gems    (+ the owner's 3 s reveal + a Big Pop)
		Mystery Pop  1 in 25,000  x100  150 gems    (+ reveal + Big Pop)
	Average income lift at luck 1: Σ p (mult - 1) = +6.46 %; at the pacing luck (PacingLuck, the
	time-weighted Happy Hour luck) +7.1 % — every area ~6 % faster than its target in the sim, well
	inside the +/-20 % pacing tolerance. tests/economy-sim.luau multiplies every producer's
	income by FlavorLogic.expectedMultiplier(PacingLuck), so the shipped pacing already contains the
	lift (docs/economy.md "Surprise Batches"). Re-tune odds / multipliers here, never the areas.

	Luck: a multiplier on every SPECIAL flavour's chance (Plain absorbs the rest). Sources: the
	Happy Hours' Sprinkle Surge (Shared/Events/HappyHourLogic.flavorLuckAt, E-events) × the admin
	odds multiplier (FlavorOdds command). Clamped to [MinLuck, MaxLuck]; the special flavours'
	total chance never exceeds MaxSpecialShare (Plain always keeps >= 10 %).

	Connects to: Shared/Tycoon/FlavorLogic (all math), Server/Tycoon/{FlavorService, BigPop,
	FlavorAdmin}, Client/Tycoon/{FlavorController, FlavorPops, FlavorGlow}, UI/Screens/{FlavorBook,
	FlavorReveal, BigPop}, tests/{flavor-logic, economy-sim}.luau, docs/flavors.md.

	Example:
		local galaxy = FlavorConfig.byId("galaxy")
		print(galaxy.name, galaxy.oneIn, galaxy.mult) --> Galaxy 2500 25
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldGeometry = require(ReplicatedStorage.Shared.Config.Worlds.WorldGeometry)

export type FlavorDef = {
	id: string, -- stable save / analytics id ("sprinkle"); NEVER rename a shipped id
	rank: number, -- 0 = Plain, 1..#Special rising rarity
	name: string, -- display name ("Mystery Pop")
	shout: string, -- the big pop / reveal word ("MYSTERY POP!")
	oneIn: number, -- base odds per batch (1 in N); 0 for Plain
	mult: number, -- payout multiplier of the batch (Plain 1)
	gems: number, -- Flavour Book discovery reward per world (claimed once); 0 for Plain
	ui: UIStyleConfig.ColorName, -- StudUI colour preset of its Book card / reveal
	color: Color3, -- tint of its income pop, sparkle and glow
	glow: boolean, -- the producer glows where everyone can see (Rainbow+)
	reveal: boolean, -- the owner's short reveal + a Big Pop (Galaxy+)
}

-- A per-FxQuality-tier count (Client/Tycoon/Fx/FxQuality "Low" | "Mid" | "High"; JuiceRules.perTier).
export type PerTier = { Low: number, Mid: number, High: number }

local FlavorConfig = {}

-- A frozen per-tier row (cast so readers see a plain PerTier, like JuiceConfig's rows).
local function perTier(low: number, mid: number, high: number): PerTier
	local value: any = table.freeze({ Low = low, Mid = mid, High = high })
	return value
end

local function flavor(def: FlavorDef): FlavorDef
	return table.freeze(def) :: any
end

-- Plain + the special flavours, in rank order (index = rank + 1). Odds / multipliers / gems: see
-- the header table and docs/economy.md. Ids are save data (profile.flavors keys) + analytics keys.
FlavorConfig.Flavors = table.freeze({
	flavor({
		id = "plain",
		rank = 0,
		name = "Plain",
		shout = "",
		oneIn = 0,
		mult = 1,
		gems = 0,
		ui = "grey",
		color = Color3.fromRGB(120, 240, 70),
		glow = false,
		reveal = false,
	}),
	flavor({
		id = "sprinkle",
		rank = 1,
		name = "Sprinkle",
		shout = "SPRINKLE!",
		oneIn = 20,
		mult = 1.5,
		gems = 5,
		ui = "sky",
		color = Color3.fromRGB(255, 132, 206),
		glow = false,
		reveal = false,
	}),
	flavor({
		id = "glitter",
		rank = 2,
		name = "Glitter",
		shout = "GLITTER!",
		oneIn = 100,
		mult = 3,
		gems = 10,
		ui = "yellow",
		color = Color3.fromRGB(255, 214, 64),
		glow = false,
		reveal = false,
	}),
	flavor({
		id = "rainbow",
		rank = 3,
		name = "Rainbow",
		shout = "RAINBOW!",
		oneIn = 500,
		mult = 5,
		gems = 25,
		ui = "rainbow",
		color = Color3.fromRGB(255, 110, 120),
		glow = true,
		reveal = false,
	}),
	flavor({
		id = "galaxy",
		rank = 4,
		name = "Galaxy",
		shout = "GALAXY!",
		oneIn = 2500,
		mult = 20,
		gems = 60,
		ui = "purple",
		color = Color3.fromRGB(160, 116, 255),
		glow = true,
		reveal = true,
	}),
	flavor({
		id = "mystery",
		rank = 5,
		name = "Mystery Pop",
		shout = "MYSTERY POP!",
		oneIn = 25000,
		mult = 100,
		gems = 150,
		ui = "teal",
		color = Color3.fromRGB(40, 240, 200),
		glow = true,
		reveal = true,
	}),
}) :: { FlavorDef }

-- The special flavours only (ranks 1..n, rank order) — the Book columns and the roll tiers.
local SPECIAL: { FlavorDef } = {}
local BY_ID: { [string]: FlavorDef } = {}
for _, def in FlavorConfig.Flavors do
	BY_ID[def.id] = def
	if def.rank > 0 then
		table.insert(SPECIAL, def)
	end
end
FlavorConfig.Special = table.freeze(SPECIAL)
FlavorConfig.SpecialCount = #SPECIAL

-- Special flavour ids in rank order (admin enums, analytics docs).
local SPECIAL_IDS: { string } = {}
local SPECIAL_NAMES: { string } = {}
for _, def in SPECIAL do
	table.insert(SPECIAL_IDS, def.id)
	table.insert(SPECIAL_NAMES, def.name)
end
FlavorConfig.SpecialIds = table.freeze(SPECIAL_IDS)
FlavorConfig.SpecialNames = table.freeze(SPECIAL_NAMES)

-- Book rows: every world in display order (Shared/Config/Worlds/WorldGeometry is require-free, so
-- ProfileLogic can load this config without pulling the world economies in).
FlavorConfig.Worlds = WorldGeometry.Order

--------------------------------------------------------------------------------------------------
-- Luck + economy
--------------------------------------------------------------------------------------------------

--[[ Ship switch (lead / owner): the whole feature's DEFAULT on a fresh server. true = Surprise Batches
     roll, the FLAVOURS button + Book, FX, Big Pop and the "flavor" daily mission exist. false = ZERO
     player-visible / economy change: no rolls (the TycoonService hook returns 0 at once), no FX, no
     FLAVOURS button / Book / Pets badge count, no Big Pop broadcasts, no "flavor" mission, and the
     economy sim drops the lift. The admin FlavorSettings switch overrides it per server at runtime;
     clients read the live state from the FlavorEnabled attribute (this default while unset). ]]
FlavorConfig.DefaultEnabled = true

FlavorConfig.MinLuck = 0 -- admin may switch rare flavours off entirely (0 = Plain only)
FlavorConfig.MaxLuck = 10 -- combined event x admin luck cap
-- The special flavours together never take more than this share of batches (Plain keeps the rest).
FlavorConfig.MaxSpecialShare = 0.9
-- Time-weighted average luck the pacing simulator assumes: the Happy Hours' Sprinkle Surge is x1.5
-- for the 3-min mini at :30 every hour + x2 for the 5-min headline every 5th hour
-- (HappyHourConfig) = 1 + 0.5 x 3/60 + 1 x 5/300 = 1.042; 1.1 is a conservative upper bound that
-- also covers admin force-starts (tests/economy-sim.luau, docs/economy.md).
FlavorConfig.PacingLuck = 1.1
-- Largest average income lift (expectedMultiplier(PacingLuck) - 1) tests/flavor-logic.luau allows.
FlavorConfig.MaxPacingLift = 0.08

--------------------------------------------------------------------------------------------------
-- Server rolling (bounded work per producer per tick)
--------------------------------------------------------------------------------------------------

FlavorConfig.Roll = table.freeze({
	-- Up to this many finished cycles are rolled one by one (one uniform draw each); more cycles
	-- (automated producers at the cycle floor, a hitch catch-up of up to MaxCatchUpCycles) roll in
	-- AGGREGATE: one binomial per special flavour (multinomial by conditionals).
	ExactCap = 24,
	-- A binomial with a mean below this is sampled exactly by inversion (at most InversionCap
	-- steps); above it by a normal approximation (two uniform draws, clamped to [0, n]).
	SmallMean = 15,
	InversionCap = 64,
})

-- Seconds between the server's flavour flush passes (pops / glows / discoveries / quest credit).
FlavorConfig.FlushSeconds = 0.25
-- Least seconds between two FlavorPop sends of one producer for Sprinkle / Glitter (they fold into
-- the next send: best flavour + count); Rainbow+ always send at once. Same pace as IncomePop.
FlavorConfig.PopSendSeconds = 0.5
-- Seconds between two pushes of the `flavors` snapshot field caused only by found-counts (a new
-- discovery or a claim pushes at once).
FlavorConfig.PushSeconds = 20
-- Seconds between the server's luck refreshes (event x admin) + the replicated attribute write.
FlavorConfig.LuckRefreshSeconds = 1
-- Lifetime found-count cap per flavour per world (profile.flavors.found values).
FlavorConfig.MaxFoundCount = 1e12
-- Most entries kept per profile.flavors map (worlds x flavours is 15 today; room for new worlds).
FlavorConfig.MaxEntries = 64

-- Seconds between two Rainbow+ glows of the same producer (server; the glow lasts Glow.Seconds).
FlavorConfig.GlowCooldown = 6

-- Quests stat "flavor" (owner R78 ProgressEvents): special-flavour batches in the world the player
-- is in, credited at most this fast (a token bucket), so fast late-game producers can't finish a
-- daily mission in seconds.
FlavorConfig.QuestCredit = table.freeze({ PerMinute = 20, Burst = 10 })

-- Analytics batch flush period (seconds): flavour counts + bonus are summed per player first.
FlavorConfig.AnalyticsFlushSeconds = 10

-- ReplicatedStorage attributes written ONLY by Server/Tycoon/FlavorService (clients display them).
FlavorConfig.Attr = table.freeze({
	Enabled = "FlavorEnabled", -- boolean: flavours roll at all (admin kill switch)
	Luck = "FlavorLuck", -- number: the live combined luck (Book odds, "LUCK x2" chip)
	EventLuck = "FlavorEventLuck", -- number: the Happy Hour part only (chip text)
})

-- Remote rate limits (burst, refill per second) of FlavorClaim.
FlavorConfig.ClaimBurst = 6
FlavorConfig.ClaimPerSecond = 2
-- Analytics / gem reason label of Flavour Book rewards.
FlavorConfig.Reason = "flavorBook"

--------------------------------------------------------------------------------------------------
-- Big Pop broadcast
--------------------------------------------------------------------------------------------------

FlavorConfig.BigPop = table.freeze({
	MinBatchRank = 4, -- Galaxy+ batches
	MinHatchRank = 6, -- PetConfig rarity rank: Mythic (6) and Secret (7)
	GapSeconds = 30, -- owner R120: at most one broadcast per 30 s server-wide (coalesced into "+N more")
	PlayerCooldown = 60, -- one player triggers at most one broadcast entry per this long
	MaxPending = 6, -- queued entries (the best per player is kept; the rest are counted "more")
	MaxPerBroadcast = 3, -- chat lines + fireworks shows per broadcast
	HatchDelay = 6, -- seconds after a hatch (the hatch reveal plays first for the hatcher)
	RebirthDelay = 2.5, -- seconds after a rebirth (the rebirth flash first)
	BannerSeconds = 4.5, -- client banner hold
	Rockets = 5, -- toy rockets per fireworks show (High tier; JuiceRules.perTier scales)
	FireworksRange = 420, -- clients farther than this (studs) from the plot skip the fireworks
	SystemColor = "#FFD84A", -- the chat line's colour (rich text font color)
})

--------------------------------------------------------------------------------------------------
-- Client FX
--------------------------------------------------------------------------------------------------

FlavorConfig.Pop = table.freeze({
	TintSeconds = 1.2, -- the producer's income pops wear the flavour colour this long
	Seconds = 1.1, -- the flavour word's rise + fade
	RiseStuds = 4.5,
	SizeStuds = Vector2.new(8, 2.2),
	Pool = 8, -- pooled BillboardGuis
	MaxDistance = 120,
	Sparkles = perTier(6, 12, 18), -- per pop (FxQuality tiers)
	MinGap = 0.35, -- seconds between two flavour words over the same producer
})

FlavorConfig.Glow = table.freeze({
	MinRank = 3, -- Rainbow+
	Seconds = 4, -- glow length
	Pool = 12, -- pooled glow rigs (PointLight + sparkle emitter)
	MaxDistance = 260, -- glows farther than this from the camera are skipped
	LightRange = 10, -- owner R19 light caps (tests/glow-budget.luau: range <= 10)
	LightBrightness = 0.6, -- owner R19 cap: soft, never a hard flash
	SparkleRate = perTier(10, 20, 34),
	HueSpeed = 0.6, -- rainbow cycles per second (Rainbow only; others keep their colour)
})

FlavorConfig.Reveal = table.freeze({
	MinRank = 4, -- Galaxy+
	Seconds = 2.8, -- whole reveal (<= 3 s), SKIP ends it early
	CountSeconds = 1.1, -- "1 in N" counts up this long
	Cooldown = 45, -- seconds between two reveals for this client (others become toasts)
	HoldSeconds = 20, -- a reveal blocked by a menu / cinematic waits at most this long
	BarHeight = 120, -- letterbox bars (design px)
	Confetti = perTier(20, 40, 70),
})

-- The Book's FLAVOURS entry point in the Pets window (UI/Screens/FlavorBook/EntryButton).
FlavorConfig.BookScreen = "FlavorBook"
-- The one-time "what are Lucky Nukes?" tip card (UI/Screens/FlavorTip).
FlavorConfig.TipScreen = "FlavorTip"

--------------------------------------------------------------------------------------------------
-- Player-facing words (owner R112: "what is the point of a batch?? it's real confusing")
--------------------------------------------------------------------------------------------------

--[[
	EVERY word players see about this feature lives here, so every presenter (reveal, income pops,
	Big Pop banner + chat line, Flavour Book, tip card, server toasts, the daily mission) says the
	same thing. Players never read "batch": a flavoured batch is a LUCKY NUKE ("Your Workbench made
	GALAXY nukes — sold for x20"). Formats use string.format (%s / %d); helpers below build lines.
]]
FlavorConfig.Text = table.freeze({
	FeatureName = "Lucky Nukes",
	-- Owner reveal (Galaxy+): "LUCKY NUKES!" / "Your <Producer> made GALAXY nukes" / "Sold for x20: +$31.8M".
	RevealTitle = "LUCKY NUKES!",
	RevealMade = "Your %s made %s nukes", -- producer name, FLAVOUR
	RevealMadeNoProducer = "You made %s nukes", -- FLAVOUR (producer unknown / not streamed)
	RevealSold = "Sold for %s: +%s", -- "x20", the payout text ("$31.8M" / "1.2K Bones")
	RevealSoldNoAmount = "Sold for %s!", -- "x20"
	-- Small fallback shout (a reveal that could not play): the reward line under "GALAXY!".
	ShoutReward = "SOLD FOR %s!", -- "x20"
	-- Income pop word over the producer: "GALAXY x20" (+ "  +2" when several folded in).
	PopWord = "%s %s", -- FLAVOUR, "x20"
	PopMore = "  +%d",
	-- Big Pop chat line / banner.
	BigPopNukes = "%s got %s nukes!", -- name, FLAVOUR
	BigPopHatch = "%s hatched a %s!", -- name, "MYTHIC Nova Fox"
	BigPopRebirth = "%s did a %s!", -- name, "REBIRTH #3"
	BigPopOdds = " (%s)", -- " (1 in 2,500)"
	BigPopChatPrefix = "BIG POP!",
	BigPopMore = "+%d more Big Pops on this server!",
	-- Owner R120 bottom-left feed pills (Q-queue's PopupQueue feed reads these).
	FeedPill = "%s nukes %s", -- FLAVOUR, "x20" → "GALAXY nukes x20"
	FeedPillMerged = "%s x%d", -- FLAVOUR, count → "GALAXY x3" (several folded into one pill)
	FeedAmount = " +%s", -- the payout text → " +$31.8M"
	-- Flavour Book.
	BookTitle = "Flavour Book",
	BookSubtitle = "Rare nukes your machines can make. Find each one for gems!",
	BookButton = "FLAVOURS",
	TileSells = "SELLS %s", -- "x3"
	TileUnknown = "???",
	TileClaim = "CLAIM +%d",
	TileFound = "FOUND %s",
	TileGems = "+%d GEMS",
	-- One-time tip card (the first Lucky Nuke a player ever gets).
	TipTitle = "Lucky Nukes!",
	TipBody = "Lucky Nukes! Sometimes your machines make rare flavoured nukes that sell for more. Collect them all in Pets \u{2192} FLAVOURS for gems!",
	TipOk = "OK",
	-- Server toasts.
	DiscoveryToast = "New Lucky Nuke: %s in %s! Claim %d Gems in Pets \u{2192} FLAVOURS.", -- FLAVOUR, world, gems
	ClaimToast = "Flavour Book reward! +%d Gems (%s)", -- gems, what
	ClaimedAlready = "You already claimed this flavour!",
	ClaimLocked = "Make this Lucky Nuke first to claim its reward!",
	-- Daily mission (QuestConfig "flavor").
	MissionOne = "Make a Lucky Nuke",
	MissionMany = "Make %d Lucky Nukes",
})

--[[
	"x1.5" / "x20" — a multiplier the way every presenter prints it.
	@param mult number
	@return string
]]
function FlavorConfig.multText(mult: number): string
	if mult == math.floor(mult) then
		return `x{math.floor(mult)}`
	end
	return `x{string.format("%.1f", mult)}`
end

--[[
	The reveal card's three lines (the payout always shows when known).
	@param def FlavorDef — the flavour
	@param producerName string? — "Pocket Nuke Workbench" (nil / "" = unknown)
	@param amountText string? — the formatted payout ("$31.8M"; nil / "" = unknown)
	@return { title: string, made: string, sold: string }
	Example: FlavorConfig.revealLines(galaxy, "Pocket Nuke Workbench", "$31.8M").sold --> "Sold for x20: +$31.8M"
]]
function FlavorConfig.revealLines(
	def: FlavorDef,
	producerName: string?,
	amountText: string?
): { title: string, made: string, sold: string }
	local Text = FlavorConfig.Text
	local flavour = string.upper(def.name)
	local mult = FlavorConfig.multText(def.mult)
	return {
		title = Text.RevealTitle,
		made = if producerName ~= nil and producerName ~= ""
			then string.format(Text.RevealMade, producerName, flavour)
			else string.format(Text.RevealMadeNoProducer, flavour),
		sold = if amountText ~= nil and amountText ~= ""
			then string.format(Text.RevealSold, mult, amountText)
			else string.format(Text.RevealSoldNoAmount, mult),
	}
end

--[[
	The income pop word: "GALAXY x20" (+ "  +2" when `count` Lucky Nukes folded into one pop).
	@param def FlavorDef
	@param count number?
	@return string
	Example: FlavorConfig.popWord(galaxy, 1) --> "GALAXY x20"
]]
function FlavorConfig.popWord(def: FlavorDef, count: number?): string
	local Text = FlavorConfig.Text
	local word = string.format(Text.PopWord, string.upper(def.name), FlavorConfig.multText(def.mult))
	if count ~= nil and count > 1 then
		word ..= string.format(Text.PopMore, math.min(math.floor(count) - 1, 999))
	end
	return word
end

--[[
	A Big Pop line (banner + chat). `label` is the server's config-derived label: the FLAVOUR for
	"batch" entries ("GALAXY"), "MYTHIC Nova Fox" for hatches, "REBIRTH #3" for rebirths;
	`oddsText` the formatted "1 in N" ("" / nil = none). The caller escapes rich text for chat.
	@return string
	Example: FlavorConfig.bigPopLine("Alex", "batch", "GALAXY", "1 in 2,500") --> "Alex got GALAXY nukes! (1 in 2,500)"
]]
function FlavorConfig.bigPopLine(name: string, kind: string, label: string, oddsText: string?): string
	local Text = FlavorConfig.Text
	local line = if kind == "hatch"
		then string.format(Text.BigPopHatch, name, label)
		elseif kind == "rebirth" then string.format(Text.BigPopRebirth, name, label)
		else string.format(Text.BigPopNukes, name, label)
	if oddsText ~= nil and oddsText ~= "" then
		line ..= string.format(Text.BigPopOdds, oddsText)
	end
	return line
end

--[[
	A flavour by id (nil for unknown / non-string ids).
	@param id unknown
	@return FlavorDef?
	Example: FlavorConfig.byId("rainbow").mult --> 10
]]
function FlavorConfig.byId(id: unknown): FlavorDef?
	if type(id) ~= "string" then
		return nil
	end
	return BY_ID[id :: string]
end

--[[
	A flavour by rank (0 = Plain).
	@param rank unknown
	@return FlavorDef?
	Example: FlavorConfig.byRank(4).id --> "galaxy"
]]
function FlavorConfig.byRank(rank: unknown): FlavorDef?
	if type(rank) ~= "number" or rank ~= rank then
		return nil
	end
	return FlavorConfig.Flavors[(rank :: number) + 1]
end

--[[
	True while Surprise Batches are on: the replicated FlavorEnabled attribute (server-written; the
	admin switch), else FlavorConfig.DefaultEnabled while it is unset (boot, Lune). Client display
	gates (FLAVOURS button, Pets badge) read this; the server uses its own live state.
	@return boolean
]]
function FlavorConfig.isEnabled(): boolean
	local ok, value = pcall(function(): any
		return (ReplicatedStorage :: any):GetAttribute(FlavorConfig.Attr.Enabled)
	end)
	if ok and type(value) == "boolean" then
		return value
	end
	return FlavorConfig.DefaultEnabled
end

--[[ True for a SPECIAL flavour id (analytics registerIds, admin enums). ]]
function FlavorConfig.isSpecial(id: unknown): boolean
	local def = FlavorConfig.byId(id)
	return def ~= nil and def.rank > 0
end

-- Load-time validation: ranks dense from 0, odds strictly rarer, multipliers strictly bigger,
-- positive gems, the configured share cap reachable, Rainbow+ glow / Galaxy+ reveal flags.
do
	local previousOdds, previousMult = 1, 1
	for index, def in FlavorConfig.Flavors do
		assert(def.rank == index - 1, `FlavorConfig: {def.id} rank must be {index - 1}`)
		assert(string.match(def.id, "^[a-z]+$") ~= nil and #def.id <= 16, `FlavorConfig: bad id {def.id}`)
		if def.rank > 0 then
			assert(def.oneIn > previousOdds, `FlavorConfig: {def.id} must be rarer than the flavour before it`)
			assert(def.mult > previousMult, `FlavorConfig: {def.id} must pay more than the flavour before it`)
			assert(def.gems > 0 and def.gems == math.floor(def.gems), `FlavorConfig: {def.id} gems`)
			previousOdds, previousMult = def.oneIn, def.mult
		end
		-- The per-flavour flags and the section thresholds must agree (both are read).
		assert(def.glow == (def.rank >= FlavorConfig.Glow.MinRank), `FlavorConfig: {def.id} glow flag`)
		assert(def.reveal == (def.rank >= FlavorConfig.Reveal.MinRank), `FlavorConfig: {def.id} reveal flag`)
	end
	local share = 0
	for _, def in SPECIAL do
		share += 1 / def.oneIn
	end
	assert(share < FlavorConfig.MaxSpecialShare, "FlavorConfig: base special share above MaxSpecialShare")
	assert(FlavorConfig.Glow.MinRank <= FlavorConfig.Reveal.MinRank, "FlavorConfig: reveal implies glow")
	assert(FlavorConfig.BigPop.MinBatchRank == FlavorConfig.Reveal.MinRank, "FlavorConfig: Big Pop = reveal tier")
end

return table.freeze(FlavorConfig)
