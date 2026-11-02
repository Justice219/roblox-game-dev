--!strict
--[[
	NumberFormat — every number a player sees: short suffixes ("1.25K", "448B", "6.29Sx"), full
	comma-grouped amounts ("448,087,050,019"), money / rate labels and short durations.

	Purpose:
		SellNukes cash grows from $0 to far beyond 1e30 over a run (plain Luau doubles, fine to
		~1.8e308). Every HUD label, billboard, pad price, offline-earnings popup and shop card
		formats through this one module so the suffix ladder and the rounding rule are the same
		everywhere.

	Rounding rule (important for a money UI):
		Values are TRUNCATED toward zero at the shown precision, never rounded up: a player holding
		$999.6 sees "$999", not "$1K", and a player with $1,259 sees "$1.25K". A label can therefore
		never claim the player can afford something they cannot. A tiny epsilon (1e-7 of a display
		unit) absorbs floating-point division noise (4.48e11 / 1e9 = 447.99999999999994 → "448").

	Precision ladder (3 significant digits once a suffix is used, trailing zeros trimmed):
		1 ≤ mantissa < 10    → 2 decimals   "1.25K", "6.29Sx", "1K" (not "1.00K")
		10 ≤ mantissa < 100  → 1 decimal    "44.8M"
		100 ≤ mantissa       → 0 decimals   "448B"
		below 1000 (no suffix): ≥ 100 → whole, ≥ 10 → 1 decimal, else 2 decimals ("0.5", "12.5").

	Suffixes (thousand-powers, short-scale): K M B T Qa Qi Sx Sp Oc No (1e3 … 1e30), then
		Dc Ud Dd Td Qad Qid Sxd Spd Ocd Nod (1e33 … 1e60), Vg Uvg Dvg … Novg (1e63 … 1e90),
		Tg … (1e93), Qag (1e123), Qig (1e153), Sxg (1e183), Spg (1e213), Ocg (1e243), Nog (1e273),
		Ce (1e303), UCe (1e306) — generated below so every finite double has a suffix.

	Safety: NaN formats as "0", ±inf as "∞" / "-∞" (they should never reach the UI; the server
	clamps every balance, but a label must never error or print "nan"). Negative values keep their
	sign ("-1.25K", "-$1.25K"); a value that truncates to zero never shows "-0".

	Pure (no Roblox APIs): runs on the server, the client and under Lune (tests/number-format.luau).

	Connects to: every UI label of cash / gems / prices (B2 UI kit money label, B6 billboards and
	pads, B7 shop / welcome back), server Notify texts.

	Example:
		NumberFormat.short(1259)              --> "1.25K"
		NumberFormat.short(448e9)             --> "448B"
		NumberFormat.short(6.29e21)           --> "6.29Sx"
		NumberFormat.commas(448087050019)     --> "448,087,050,019"
		NumberFormat.money(1259)              --> "$1.25K"
		NumberFormat.moneyFull(448087050019)  --> "$448,087,050,019"
		NumberFormat.rate(12.5)               --> "+$12.5/s"
		NumberFormat.duration(3725)           --> "1h 02m"
]]

local NumberFormat = {}

-- Absorbs float noise when truncating (fraction of one displayed unit; see the header).
local EPSILON = 1e-7

-- Above this magnitude a double can no longer hold every integer exactly (2^53 ≈ 9.007e15), so
-- comma-grouped digits would be partly invented: commas() falls back to short() at 1e15.
local COMMAS_LIMIT = 1e15

-- Longest duration `duration` spells out (9999 days); longer inputs are clamped.
local MAX_DURATION_SECONDS = 9999 * 86400

-- Tiers 1..10: thousand .. nonillion.
local FIRST_TEN = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No" }
-- Latin unit prefixes 1..9 used inside compound names (Ud = undecillion, Qavg, Sxtg, ...).
local UNIT_PREFIX = { "U", "D", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No" }
-- Tens names for illion indices 10, 20, ..., 90 (decillion, vigintillion, trigintillion, ...).
local TENS = { "Dc", "Vg", "Tg", "Qag", "Qig", "Sxg", "Spg", "Ocg", "Nog" }

-- Largest thousand-power tier a finite double reaches: floor(log10(1.797e308) / 3) = 102.
local MAX_TIER = 102

--[[
	The suffix of an illion index (index 0 = thousand "K", 1 = million "M", 10 = decillion "Dc").
	Index i >= 10 composes unit + tens: 11 → "Ud", 20 → "Vg", 21 → "Uvg", 100 → "Ce", 101 → "UCe".
]]
local function illionName(index: number): string
	if index < 10 then
		return FIRST_TEN[index + 1]
	end
	if index >= 100 then
		local unit = index - 100
		return if unit == 0 then "Ce" else UNIT_PREFIX[unit] .. "Ce"
	end
	local ten = index // 10
	local unit = index % 10
	if ten == 1 then
		return if unit == 0 then "Dc" else UNIT_PREFIX[unit] .. "d"
	end
	local tensName = TENS[ten]
	return if unit == 0 then tensName else UNIT_PREFIX[unit] .. string.lower(tensName)
end

-- SUFFIXES[tier] for tier 1..MAX_TIER (tier = thousand-power: 1 = 1e3, 2 = 1e6, ...).
local suffixes: { string } = {}
for tier = 1, MAX_TIER do
	suffixes[tier] = illionName(tier - 1)
end
NumberFormat.Suffixes = table.freeze(suffixes)

-- True for a real, finite number.
local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

--[[
	`value` (>= 0) truncated to `decimals` decimals, trailing zeros (and a bare ".") trimmed.
	Example: fixed(1.259, 2) --> "1.25" ; fixed(1.2, 2) --> "1.2" ; fixed(7, 2) --> "7"
]]
local function fixed(value: number, decimals: number): string
	local scale = 10 ^ decimals
	local truncated = math.floor(value * scale + EPSILON) / scale
	local text = string.format("%." .. decimals .. "f", truncated)
	if decimals > 0 then
		text = string.gsub(text, "0+$", "")
		text = string.gsub(text, "%.$", "")
	end
	return text
end

-- Decimals shown for a mantissa (or a sub-1000 value): 3 significant digits.
local function decimalsFor(mantissa: number): number
	if mantissa >= 100 then
		return 0
	elseif mantissa >= 10 then
		return 1
	end
	return 2
end

-- The non-finite spellings (NaN → "0"; never "nan" / "inf" on screen).
local function nonFinite(n: number): string
	if n ~= n then
		return "0"
	end
	return if n > 0 then "∞" else "-∞"
end

--[[
	Short form with a thousand-power suffix (see the header for the precision ladder).
	@param n any number (NaN / ±inf are handled)
	@return e.g. "999", "12.5", "1.25K", "44.8M", "448B", "6.29Sx"
	Example: NumberFormat.short(-1259) --> "-1.25K"
]]
function NumberFormat.short(n: number): string
	if not isFinite(n) then
		return nonFinite(n)
	end
	local magnitude = math.abs(n)
	local text: string
	if magnitude < 1000 then
		text = fixed(magnitude, decimalsFor(magnitude))
	else
		local tier = math.min(math.floor(math.log10(magnitude) / 3), MAX_TIER)
		local mantissa = magnitude / 10 ^ (3 * tier)
		-- log10 can land a hair below an exact power (log10(1e15) = 14.999...), or above for a
		-- value a hair below one: re-normalise so the mantissa is in [1, 1000).
		if mantissa >= 1000 and tier < MAX_TIER then
			tier += 1
			mantissa /= 1000
		elseif mantissa < 1 and tier > 1 then
			tier -= 1
			mantissa *= 1000
		end
		text = fixed(mantissa, decimalsFor(mantissa)) .. suffixes[tier]
	end
	if n < 0 and text ~= "0" then
		return "-" .. text
	end
	return text
end

--[[
	Suffixed amount with a FIXED number of decimals on the mantissa (trailing zeros trimmed), for
	the big HUD cash counter. The owner's reference HUD reads "119.08K" — two decimals at every
	tier — where `short` (3 significant digits, for billboards) would read "119K". Values below
	1,000 are whole numbers. Truncates like `short` (never rounds up).
	@param n the amount (non-finite is spelled like `short`)
	@param decimals mantissa decimals, clamped to 0..3 (default 2)
	@return e.g. "999", "1.25K", "119.08K", "6.29Sx", "-3.5M"
	Example: NumberFormat.precise(119_088) --> "119.08K"
]]
function NumberFormat.precise(n: number, decimals: number?): string
	if not isFinite(n) then
		return nonFinite(n)
	end
	local places = math.clamp(math.floor(decimals or 2), 0, 3)
	local magnitude = math.abs(n)
	local text: string
	if magnitude < 1000 then
		text = fixed(magnitude, 0)
	else
		local tier = math.min(math.floor(math.log10(magnitude) / 3), MAX_TIER)
		local mantissa = magnitude / 10 ^ (3 * tier)
		-- Same log10 re-normalisation as `short` keeps the mantissa in [1, 1000).
		if mantissa >= 1000 and tier < MAX_TIER then
			tier += 1
			mantissa /= 1000
		elseif mantissa < 1 and tier > 1 then
			tier -= 1
			mantissa *= 1000
		end
		text = fixed(mantissa, places) .. suffixes[tier]
	end
	if n < 0 and text ~= "0" then
		return "-" .. text
	end
	return text
end

--[[
	Whole amount with comma thousands separators (truncated toward zero). Values of 1e15 or more
	fall back to `short` (doubles cannot hold every digit past 2^53).
	@return e.g. "0", "999", "1,000", "448,087,050,019", "-12,345"
	Example: NumberFormat.commas(448087050019) --> "448,087,050,019"
]]
function NumberFormat.commas(n: number): string
	if not isFinite(n) then
		return nonFinite(n)
	end
	local magnitude = math.abs(n)
	if magnitude >= COMMAS_LIMIT then
		return NumberFormat.short(n)
	end
	local digits = string.format("%d", math.floor(magnitude + EPSILON))
	-- Insert a comma before every group of three digits counted from the right.
	local grouped = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	grouped = string.gsub(grouped, "^,", "")
	if n < 0 and grouped ~= "0" then
		return "-" .. grouped
	end
	return grouped
end

--[[
	Prefixes `$` after the sign: "1.25K" → "$1.25K", "-1.25K" → "-$1.25K".
]]
local function withDollar(text: string): string
	if string.sub(text, 1, 1) == "-" then
		return "-$" .. string.sub(text, 2)
	end
	return "$" .. text
end

--[[
	Short money label (HUD, pads, billboards).
	Example: NumberFormat.money(1259) --> "$1.25K" ; NumberFormat.money(-5) --> "-$5"
]]
function NumberFormat.money(n: number): string
	return withDollar(NumberFormat.short(n))
end

--[[
	Full money label with commas (welcome-back popup, receipts, tooltips).
	Example: NumberFormat.moneyFull(448087050019) --> "$448,087,050,019"
]]
function NumberFormat.moneyFull(n: number): string
	return withDollar(NumberFormat.commas(n))
end

--[[
	Income-rate label for the HUD's `+$X/s` chip (always signed).
	Example: NumberFormat.rate(1259) --> "+$1.25K/s" ; NumberFormat.rate(0) --> "+$0/s"
]]
function NumberFormat.rate(n: number): string
	local text = NumberFormat.money(n)
	if string.sub(text, 1, 1) ~= "-" then
		text = "+" .. text
	end
	return text .. "/s"
end

--[[
	Compact duration for timers (boosts, free spin, offline time). Truncates to whole seconds;
	shows the two largest units with a zero-padded second unit.
	@param seconds any number (NaN / negative / inf → "0s")
	@return "12s", "4m 09s", "2h 05m", "3d 04h"
	Example: NumberFormat.duration(3725) --> "1h 02m"
]]
function NumberFormat.duration(seconds: number): string
	if not isFinite(seconds) or seconds < 1 then
		return "0s"
	end
	-- Clamp absurd values (a bug elsewhere) so %d always receives a small integer.
	local total = math.min(math.floor(seconds), MAX_DURATION_SECONDS)
	local days = total // 86400
	local hours = (total % 86400) // 3600
	local minutes = (total % 3600) // 60
	local secs = total % 60
	if days > 0 then
		return string.format("%dd %02dh", days, hours)
	elseif hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	elseif minutes > 0 then
		return string.format("%dm %02ds", minutes, secs)
	end
	return string.format("%ds", secs)
end

return table.freeze(NumberFormat)
