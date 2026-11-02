--!strict
--[[
	ManagerTagLogic — the pure maths behind the manager nametags + speech bubbles (owner R87).
	No services, no Instances: tests/manager-tags.luau loads it under lune.

	What it decides:
		* WHAT a tag says (`describe`): role chip, name, "runs <producer>" — see ManagerTagConfig's
		  header for the pool vs canon-name rule.
		* WHICH pooled name a manager gets (`pickName`): a seeded Fisher-Yates shuffle of the pool
		  (seed = FNV-1a of "<ownerUserId>|<world>|<pool>", `seedOf`) indexed by the manager's
		  ordinal among its world's managers drawing from the same pool (`ordinalOf`). Same owner
		  -> same names on every server and plot slot; different managers of one plot never share
		  a name while the pool is big enough (tests prove the pools are).
		* WHEN a plot's managers speak (`newScheduler` / `due` / `choose` / `chooseLine` /
		  `started` / `ended`): one bubble per plot at a time, the first FirstDelay after the plot
		  appears, then one every Interval seconds (uniform in [min, max]); the speaker and the line
		  never repeat back to back when there is a choice.
		* HOW WIDE a tag is (`widthScale`): just wide enough for its own text, so short names cover
		  less of the scene.
		* WHERE a tag goes when it would cover its producer's own billboard (ProducerBillboards) on
		  screen (`overlaps` + `nudge`): the smallest sideways shift that clears the board, keeping
		  the side it is already on; when no shift within the cap clears it, the tag hides.

	Randomness: Park-Miller (multiplier 48271, modulus 2^31 - 1), the same generator NpcBrain uses;
	every product stays below 2^53 so doubles compute it exactly on every platform.

	Example:
		local seed = ManagerTagLogic.seedOf(12345, "main", "crew")
		local name = ManagerTagLogic.pickName(ManagerTagConfig.NamePools.crew, seed, 2) --> e.g. "Gus Gizmo"
		local s = ManagerTagLogic.newScheduler(seed, os.clock(), ManagerTagConfig.Bubble)
		if ManagerTagLogic.due(s, os.clock()) then ... ManagerTagLogic.started(s, os.clock(), cfg, key, line) end
]]

-- The slice of ManagerTagConfig the logic reads (kept structural so tests can pass plain tables).
export type ManagerRow = { pool: string?, role: string? }
export type BubbleTiming = {
	IntervalMin: number,
	IntervalMax: number,
	FirstDelayMin: number,
	FirstDelayMax: number,
	ShowSeconds: number,
}

-- What one tag shows.
export type Tag = {
	role: string, -- chip text (display case; the tag upper-cases it)
	name: string,
	runs: string, -- the producer's display name ("" when unknown)
	pool: string?, -- the name pool used (nil = canon name)
}

-- One plot's bubble timer (mutated in place; one per plot, never per frame).
export type Scheduler = {
	rng: number, -- Park-Miller state in [1, RNG_MOD - 1]
	nextAt: number, -- clock time the next bubble may start
	untilAt: number, -- clock time the current bubble ends (<= now: none showing)
	lastKey: string?, -- the manager that spoke last (not picked again when another can speak)
	lastLine: string?, -- the line said last (not repeated back to back)
}

local ManagerTagLogic = {}

local RNG_MOD = 2147483647
local RNG_MUL = 48271
local FNV_OFFSET = 2166136261
local FNV_PRIME = 16777619
local TWO32 = 4294967296
-- Extra px a nudge moves past the margin (floating-point safety).
local NUDGE_PAD = 0.5

-- Next Park-Miller state (state * 48271 < 2^47: exact in a double).
local function nextState(state: number): number
	return (state * RNG_MUL) % RNG_MOD
end

-- A seed folded into a valid generator state (1 .. RNG_MOD - 1).
local function stateOf(seed: number): number
	local whole = math.floor(math.abs(seed))
	if whole ~= whole or whole == math.huge then
		whole = 0
	end
	return (whole % (RNG_MOD - 1)) + 1
end

-- Advances the scheduler's generator and returns a number in [0, 1).
local function random01(s: Scheduler): number
	s.rng = nextState(s.rng)
	return (s.rng - 1) / (RNG_MOD - 1)
end

--[[
	hash — 32-bit FNV-1a of a string (stable across platforms and sessions).
	The multiply is split into 16-bit halves so every intermediate stays exact in a double.
	@param text  any string
	@return integer in [0, 2^32)
	Example: hash("") --> 2166136261
]]
function ManagerTagLogic.hash(text: string): number
	local h = FNV_OFFSET
	for i = 1, #text do
		h = bit32.bxor(h, string.byte(text, i))
		-- (h * prime) mod 2^32 without losing precision: h = hi * 2^16 + lo.
		local lo = h % 65536
		local hi = (h - lo) / 65536
		h = ((hi * FNV_PRIME % 65536) * 65536 + lo * FNV_PRIME) % TWO32
	end
	return h
end

--[[
	seedOf — the name seed of one owner's pool in one world.
	@param ownerUserId  the plot's OwnerUserId (the PlotIndex works as a fallback when unowned)
	@param worldId      "main", "dino", ...
	@param pool         NamePools key
	@return integer seed (feed to pickName / newScheduler)
	Example: seedOf(1, "main", "crew") ~= seedOf(2, "main", "crew")
]]
function ManagerTagLogic.seedOf(ownerUserId: number, worldId: string, pool: string): number
	return ManagerTagLogic.hash(`{math.floor(ownerUserId)}|{worldId}|{pool}`)
end

--[[
	ordinalOf — 1-based position of `key` among the keys of `worldKeys` that draw from the same
	pool (rows[key].pool), in list order. 0 when `key` draws no pool or is not listed.
	@param worldKeys  ManagerNpcConfig.managerKeysOf(worldId) (area order)
	@param rows       ManagerTagConfig.Managers
	@return number
	Example: ordinalOf({ "A1", "A2", "A3" }, { A1 = {}, A2 = { pool = "crew" }, A3 = { pool = "crew" } }, "A3") --> 2
]]
function ManagerTagLogic.ordinalOf(worldKeys: { string }, rows: { [string]: ManagerRow }, key: string): number
	local row = rows[key]
	local pool = if row ~= nil then row.pool else nil
	if pool == nil then
		return 0
	end
	local ordinal = 0
	for _, other in worldKeys do
		local otherRow = rows[other]
		if otherRow ~= nil and otherRow.pool == pool then
			ordinal += 1
			if other == key then
				return ordinal
			end
		end
	end
	return 0
end

--[[
	pickName — the `ordinal`-th name of the pool shuffled by `seed` (Fisher-Yates, Park-Miller).
	Ordinals past the pool size wrap (tests keep every pool larger than its users).
	@param pool     non-empty list of names
	@param seed     seedOf(...)
	@param ordinal  1-based (ordinalOf); <= 0 reads as 1
	@return string ("" for an empty pool)
	Example: pickName({ "A", "B", "C" }, 7, 1) --> one of "A" / "B" / "C", the same every call
]]
function ManagerTagLogic.pickName(pool: { string }, seed: number, ordinal: number): string
	local count = #pool
	if count == 0 then
		return ""
	end
	local order = table.create(count, 0)
	for i = 1, count do
		order[i] = i
	end
	local state = stateOf(seed)
	for i = count, 2, -1 do
		state = nextState(state)
		local j = (state % i) + 1
		order[i], order[j] = order[j], order[i]
	end
	local slot = ((math.max(math.floor(ordinal), 1) - 1) % count) + 1
	return pool[order[slot]]
end

--[[
	describe — what a manager's tag shows.
	@param key           the manager build key (ManagerNpcConfig.WorldManagerKeys entry)
	@param padName       its Manager pad's display name ("Foreman", "Rocky Raptor")
	@param producerName  the pad's target producer display name ("Glow Rock Drill"; "" when unknown)
	@param worldKeys     managerKeysOf(world) (for the pool ordinal)
	@param rows          ManagerTagConfig.Managers
	@param pools         ManagerTagConfig.NamePools
	@param seedFor       pool -> seed (seedOf bound to the plot owner + world)
	@param defaultRole   ManagerTagConfig.DefaultRole
	@return Tag
	Example: describe("A4_Foreman", "Foreman", "Glow Rock Drill", keys, rows, pools, seeder, "Manager")
		--> { role = "Foreman", name = "Captain Kaboom", runs = "Glow Rock Drill", pool = "crew" }
]]
function ManagerTagLogic.describe(
	key: string,
	padName: string,
	producerName: string,
	worldKeys: { string },
	rows: { [string]: ManagerRow },
	pools: { [string]: { string } },
	seedFor: (pool: string) -> number,
	defaultRole: string
): Tag
	local row = rows[key]
	local poolName = if row ~= nil then row.pool else nil
	local pool = if poolName ~= nil then pools[poolName] else nil
	if poolName ~= nil and pool ~= nil and #pool > 0 then
		local ordinal = ManagerTagLogic.ordinalOf(worldKeys, rows, key)
		return {
			role = if padName ~= "" then padName else defaultRole,
			name = ManagerTagLogic.pickName(pool, seedFor(poolName), ordinal),
			runs = producerName,
			pool = poolName,
		}
	end
	return {
		role = if row ~= nil and row.role ~= nil then row.role else defaultRole,
		name = padName,
		runs = producerName,
		pool = nil,
	}
end

--[[
	linesFor — the speech lines of a manager: general + its world's + robot lines (robot pool or
	the Moon's crew). Returns a fresh list (call once per kind and cache it, never per frame).
	@param lines    ManagerTagConfig.Lines
	@param worldId  "main" / "dino" / "moon" ...
	@param robot    true for robot-named managers
	@return { string }
]]
function ManagerTagLogic.linesFor(lines: { [string]: { string } }, worldId: string, robot: boolean): { string }
	local out: { string } = {}
	local function add(list: { string }?)
		if list ~= nil then
			for _, line in list do
				table.insert(out, line)
			end
		end
	end
	add(lines.general)
	if worldId ~= "general" and worldId ~= "robot" then
		add(lines[worldId])
	end
	if robot then
		add(lines.robot)
	end
	return out
end

---------------------------------------------------------------------------------------------------
-- Bubble scheduling
---------------------------------------------------------------------------------------------------

-- Uniform number in [lo, hi] from the scheduler's generator.
local function between(s: Scheduler, lo: number, hi: number): number
	return lo + random01(s) * math.max(hi - lo, 0)
end

--[[
	newScheduler — a plot's bubble timer; the first bubble is due FirstDelay seconds from `now`.
	@param seed    any integer (the plot owner's id hash: plots never speak in lock-step)
	@param now     the clock the caller uses (os.clock)
	@param timing  ManagerTagConfig.Bubble
	@return Scheduler
]]
function ManagerTagLogic.newScheduler(seed: number, now: number, timing: BubbleTiming): Scheduler
	local s: Scheduler = { rng = stateOf(seed), nextAt = now, untilAt = -math.huge, lastKey = nil, lastLine = nil }
	s.nextAt = now + between(s, timing.FirstDelayMin, timing.FirstDelayMax)
	return s
end

--[[ True when no bubble of this plot is up and the next one may start. ]]
function ManagerTagLogic.due(s: Scheduler, now: number): boolean
	return now >= s.untilAt and now >= s.nextAt
end

--[[ True while this plot's bubble is up. ]]
function ManagerTagLogic.showing(s: Scheduler, now: number): boolean
	return now < s.untilAt
end

--[[
	choose — index of the speaker among `keys` (the eligible managers' keys): random, but never the
	one that spoke last when someone else can. Returns 0 for an empty list.
]]
function ManagerTagLogic.choose(s: Scheduler, keys: { string }): number
	local count = #keys
	if count == 0 then
		return 0
	end
	if count == 1 then
		return 1
	end
	local index = math.floor(random01(s) * count) + 1
	if keys[index] == s.lastKey then
		-- Step to the next eligible manager (deterministic, uniform over the others).
		index = (index % count) + 1
	end
	return index
end

--[[
	chooseLine — a line from `lines`, never the previous line of this plot when there are others.
	Returns "" for an empty list.
]]
function ManagerTagLogic.chooseLine(s: Scheduler, lines: { string }): string
	local count = #lines
	if count == 0 then
		return ""
	end
	local index = math.floor(random01(s) * count) + 1
	if count > 1 and lines[index] == s.lastLine then
		index = (index % count) + 1
	end
	return lines[index]
end

--[[
	started — a bubble went up now (speaker `key`, `line`): it ends ShowSeconds later and the next
	one is due a random Interval after that.
]]
function ManagerTagLogic.started(s: Scheduler, now: number, timing: BubbleTiming, key: string, line: string)
	s.untilAt = now + timing.ShowSeconds
	s.nextAt = s.untilAt + between(s, timing.IntervalMin, timing.IntervalMax)
	s.lastKey = key
	s.lastLine = line
end

--[[
	ended — the bubble was cut short now (its manager got knocked down, streamed out, the owner
	walked away): it is gone at once; the next one keeps its schedule.
]]
function ManagerTagLogic.ended(s: Scheduler, now: number)
	if s.untilAt > now then
		s.untilAt = now
	end
end

---------------------------------------------------------------------------------------------------
-- Screen layout
---------------------------------------------------------------------------------------------------

--[[
	overlaps — do two axis-aligned screen rectangles (centre + size, pixels) overlap once `margin`
	pixels of clear space are required between them?
	Example: overlaps(100, 100, 50, 20, 100, 125, 50, 20, 6) --> true (only 5 px apart vertically)
]]
function ManagerTagLogic.overlaps(
	ax: number,
	ay: number,
	aw: number,
	ah: number,
	bx: number,
	by: number,
	bw: number,
	bh: number,
	margin: number
): boolean
	return math.abs(ax - bx) * 2 < aw + bw + margin * 2 and math.abs(ay - by) * 2 < ah + bh + margin * 2
end

--[[
	nudge — the smallest SIDEWAYS screen shift (px; < 0 left, > 0 right) that moves a tag rect
	(centre tx, ty, size tw x th) clear of a board rect (+ margin). `prefer` (-1 / 0 / 1, the side
	the tag is already on) wins whenever it is feasible, so a tag never flips sides while the camera
	drifts. A shift larger than `maxShift` would detach the tag from its manager: then `ok` is false
	(the caller hides the tag instead).
	@return shift px (0 when there is no overlap), ok
	Example: nudge(100, 50, 100, 30, 160, 50, 40, 40, 6, 80, 0) --> -16.5, true (move left 16.5 px)
]]
function ManagerTagLogic.nudge(
	tx: number,
	ty: number,
	tw: number,
	th: number,
	bx: number,
	by: number,
	bw: number,
	bh: number,
	margin: number,
	maxShift: number,
	prefer: number
): (number, boolean)
	if not ManagerTagLogic.overlaps(tx, ty, tw, th, bx, by, bw, bh, margin) then
		return 0, true
	end
	-- Shifts that put the tag's right edge left of the board / its left edge right of the board
	-- (half a pixel past the margin, so rounding never leaves it exactly on the edge).
	local left = (bx - bw / 2 - margin) - (tx + tw / 2) - NUDGE_PAD
	local right = (bx + bw / 2 + margin) - (tx - tw / 2) + NUDGE_PAD
	local first, second = left, right
	if prefer > 0 or (prefer == 0 and right < -left) then
		first, second = right, left
	end
	if math.abs(first) <= maxShift then
		return first, true
	end
	if math.abs(second) <= maxShift then
		return second, true
	end
	return 0, false
end

--[[
	widthScale — how much of the full tag width a tag's text needs (the full width fits a
	`fullChars`-long "runs" line). The name and "runs" rows are compared in row-height units (a
	glyph is about as wide as its row is tall, times a constant that cancels out), so a big name and
	a small "runs" line weigh correctly; the role chip needs its own width share
	(ChipBase + ChipPerChar * #role of the full width) to stay inside ChipMaxWidth of the tag.
	A narrower tag covers less of the scene (fewer clashes with producer boards).
	@param name, runsText, role  the three texts as shown
	@param sizes  ManagerTagConfig.Tag (row heights + chip width rule)
	@param fullChars  characters of a "runs" line the full width holds
	@param minScale  floor (0..1)
	@return scale in [minScale, 1]
	Example: widthScale("Zappy-3", "runs Nuke Stand", "CASHIER BOT", Tag, 26, 0.5) --> ~0.62
]]
function ManagerTagLogic.widthScale(
	name: string,
	runsText: string,
	role: string,
	sizes: {
		NameHeight: number,
		RunsHeight: number,
		ChipBase: number,
		ChipPerChar: number,
		ChipMaxWidth: number,
	},
	fullChars: number,
	minScale: number
): number
	local need = math.max(sizes.NameHeight * #name, sizes.RunsHeight * #runsText)
	local full = sizes.RunsHeight * math.max(fullChars, 1)
	-- 8% breathing room so TextScaled never has to shrink a line that "just" fits.
	local textShare = need / full * 1.08
	local chipShare = (sizes.ChipBase + sizes.ChipPerChar * #role) / math.max(sizes.ChipMaxWidth, 0.01)
	return math.clamp(math.max(textShare, chipShare), minScale, 1)
end

return ManagerTagLogic
