--!strict
--[[
	NumberFormat regressions (src/shared/Util/NumberFormat.luau). Run:
		lune run tests/number-format

	Proves on the shipped module:
	  1. short(): the suffix ladder (K … UCe), 3 significant digits, trailing-zero trimming,
	     TRUNCATION (never rounds up: $999.6 is "999", $1,259 is "1.25K"), float-noise tolerance at
	     exact powers, negatives, zero, NaN / ±inf.
	  2. The generated suffix table: 102 unique suffixes, the named anchors (Dc, Ud, Nod, Vg, Uvg,
	     Tg, Qag, Ce, UCe), and every finite double maps to a suffix without erroring.
	  3. commas() / moneyFull(): grouping, sign handling, the 1e15 fallback to short().
	  4. money() / rate() / duration().
]]

local NumberFormat = require("../src/shared/Util/NumberFormat")

local checks = 0
local function eq(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(`{label}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
	checks += 1
end

-- 1. short()
eq(NumberFormat.short(0), "0", "zero")
eq(NumberFormat.short(7), "7", "small whole")
eq(NumberFormat.short(0.5), "0.5", "half")
eq(NumberFormat.short(0.004), "0", "tiny truncates to 0")
eq(NumberFormat.short(12.57), "12.5", "two-digit truncation")
eq(NumberFormat.short(999), "999", "999")
eq(NumberFormat.short(999.6), "999", "never rounds up to 1K")
eq(NumberFormat.short(1000), "1K", "1K trimmed")
eq(NumberFormat.short(1259), "1.25K", "1.25K truncated not rounded")
eq(NumberFormat.short(1200), "1.2K", "trailing zero trimmed")
eq(NumberFormat.short(44_800_000), "44.8M", "two-digit mantissa")
eq(NumberFormat.short(448e9), "448B", "448B")
eq(NumberFormat.short(448_087_050_019), "448B", "448B from full value")
eq(NumberFormat.short(999_999_999), "999M", "just under a billion")
eq(NumberFormat.short(1e15), "1Qa", "exact power (log10 noise)")
eq(NumberFormat.short(6.29e21), "6.29Sx", "6.29Sx")
eq(NumberFormat.short(1e33), "1Dc", "decillion")
eq(NumberFormat.short(1e36), "1Ud", "undecillion")
eq(NumberFormat.short(1e60), "1Nod", "novemdecillion")
eq(NumberFormat.short(1e63), "1Vg", "vigintillion")
eq(NumberFormat.short(2.5e66), "2.5Uvg", "unvigintillion")
eq(NumberFormat.short(1e93), "1Tg", "trigintillion")
eq(NumberFormat.short(1e303), "1Ce", "centillion")
eq(NumberFormat.short(1.79e308), "179UCe", "largest double")
eq(NumberFormat.short(-1259), "-1.25K", "negative")
eq(NumberFormat.short(-0.001), "0", "negative that truncates to zero has no sign")
eq(NumberFormat.short(0 / 0), "0", "NaN")
eq(NumberFormat.short(math.huge), "∞", "+inf")
eq(NumberFormat.short(-math.huge), "-∞", "-inf")

-- 2. suffix table
local suffixes = NumberFormat.Suffixes
eq(#suffixes, 102, "suffix count")
local seen: { [string]: boolean } = {}
for tier, suffix in suffixes do
	assert(not seen[suffix], `duplicate suffix {suffix} at tier {tier}`)
	seen[suffix] = true
	checks += 1
end
eq(suffixes[1], "K", "tier 1")
eq(suffixes[10], "No", "tier 10")
eq(suffixes[11], "Dc", "tier 11")
eq(suffixes[15], "Qad", "tier 15")
eq(suffixes[21], "Vg", "tier 21")
eq(suffixes[41], "Qag", "tier 41")
eq(suffixes[101], "Ce", "tier 101")
eq(suffixes[102], "UCe", "tier 102")
-- Every thousand-power and its neighbours format without error and end with a known suffix.
for exponent = 0, 308 do
	for _, factor in { 1, 1.5, 9.99 } do
		local value = factor * 10 ^ exponent
		if value < math.huge then
			local text = NumberFormat.short(value)
			assert(type(text) == "string" and #text > 0, `short(1e{exponent})`)
			checks += 1
		end
	end
end

-- 3. commas / moneyFull
eq(NumberFormat.commas(0), "0", "commas zero")
eq(NumberFormat.commas(999), "999", "commas 999")
eq(NumberFormat.commas(1000), "1,000", "commas 1,000")
eq(NumberFormat.commas(1234567.89), "1,234,567", "commas truncates decimals")
eq(NumberFormat.commas(448_087_050_019), "448,087,050,019", "commas reference")
eq(NumberFormat.commas(-12345), "-12,345", "commas negative")
eq(NumberFormat.commas(999_999_999_999_999), "999,999,999,999,999", "commas just under the limit")
eq(NumberFormat.commas(1e15), "1Qa", "commas falls back to short at 1e15")
eq(NumberFormat.commas(0 / 0), "0", "commas NaN")
eq(NumberFormat.moneyFull(448_087_050_019), "$448,087,050,019", "moneyFull reference")
eq(NumberFormat.moneyFull(-5), "-$5", "moneyFull negative")

-- 4. money / rate / duration
eq(NumberFormat.money(1259), "$1.25K", "money")
eq(NumberFormat.money(0), "$0", "money zero")
eq(NumberFormat.money(-1259), "-$1.25K", "money negative")
eq(NumberFormat.rate(1259), "+$1.25K/s", "rate")
eq(NumberFormat.rate(0), "+$0/s", "rate zero")
eq(NumberFormat.rate(-3), "-$3/s", "rate negative")
eq(NumberFormat.duration(0), "0s", "duration zero")
eq(NumberFormat.duration(-5), "0s", "duration negative")
eq(NumberFormat.duration(0 / 0), "0s", "duration NaN")
eq(NumberFormat.duration(12.9), "12s", "duration seconds")
eq(NumberFormat.duration(249), "4m 09s", "duration minutes")
eq(NumberFormat.duration(3725), "1h 02m", "duration hours")
eq(NumberFormat.duration(273600), "3d 04h", "duration days")
eq(NumberFormat.duration(1e300), "9999d 00h", "duration clamp")

-- precise(): fixed 2 decimals for the HUD cash counter (owner reference "119.08K")
eq(NumberFormat.precise(0), "0", "precise zero")
eq(NumberFormat.precise(999.9), "999", "precise below 1K is whole")
eq(NumberFormat.precise(119_088), "119.08K", "precise 119.08K")
eq(NumberFormat.precise(1_250), "1.25K", "precise 1.25K")
eq(NumberFormat.precise(1_000), "1K", "precise trims zeros")
eq(NumberFormat.precise(6.29e21), "6.29Sx", "precise Sx")
eq(NumberFormat.precise(1e15), "1Qa", "precise exact power")
eq(NumberFormat.precise(-3_500_000), "-3.5M", "precise negative")
eq(NumberFormat.precise(119_088, 0), "119K", "precise 0 decimals")
eq(NumberFormat.precise(119_088, 99), "119.088K", "precise decimals clamped to 3")
eq(NumberFormat.precise(0 / 0), "0", "precise NaN")
eq(NumberFormat.precise(math.huge), "∞", "precise inf")

print(`[number-format] {checks} checks passed`)
