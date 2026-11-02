--!strict
--[[
	Owner R88 plot-name regressions (src/shared/Tycoon/PlotNameLogic.luau + PlotNameConfig). Run:
		lune run tests/plot-name

	Proves on the shipped modules:
	  1. parse (the RenamePlot argument): "" / all-space → reset; a valid name → set (trimmed,
	     spaces collapsed, invisible characters dropped); wrong types, NaN-ish junk, tables, too
	     many characters, a byte flood, ASCII / C1 control characters, invalid UTF-8 and names made
	     only of invisible characters are refused (nil) — and a refusal is never turned into a reset.
	  2. normalize: zero-width / bidi-override / soft-hyphen characters dropped, Unicode spaces
	     mapped to " ", runs collapsed, ends trimmed, invalid UTF-8 → "".
	  3. clean (the window's pre-send check) agrees with parse "set" and never returns a reset.
	  4. Sign text: the default "<DisplayName>'s Nukes" / "<DisplayName>'s Dino Valley", a custom
	     name replaces it, "" / nil fall back to the default; isCustom.
	  5. Config: the cap matches ProfileLogic's MaxPlotNameChars, the rate limit is sane, every
	     player-facing string is present, short and kid-friendly (no "#" placeholders).
	  6. Hostile fuzz: random strings / bytes never throw and anything accepted is valid UTF-8,
	     within the cap, control-free and already normalized.
	  7. Analytics: renamePlot:set / reset / admin pass the tycoon KeySpec allowlist; others don't.
]]

local Loader = require("./fixtures/RobloxLoader")
local Random = Loader.Random

local loader = Loader.new()
local PlotNameLogic = loader.load("src/shared/Tycoon/PlotNameLogic")
local PlotNameConfig = loader.load("src/shared/Config/PlotNameConfig")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local MAX = PlotNameConfig.MaxChars

-- Shorthand: the parsed intent's kind and text ("nil" when refused).
local function parsed(raw: any): (string, string?)
	local intent = PlotNameLogic.parse(raw, MAX)
	if intent == nil then
		return "nil", nil
	end
	return intent.kind, intent.text
end

-- 1. parse ------------------------------------------------------------------------------------------
do
	local kind, text = parsed("Sparkle Base")
	check(kind == "set" and text == "Sparkle Base", "a plain name is a set")
	kind, text = parsed("   Big    Boom   Shop  ")
	check(kind == "set" and text == "Big Boom Shop", "trimmed + collapsed")
	kind = parsed("")
	check(kind == "reset", "empty string = reset")
	kind = parsed("     ")
	check(kind == "reset", "all spaces = reset")
	kind = parsed("\t \n")
	check(kind == "reset", "ASCII whitespace only = reset (explicit reset intent)")
	kind, text = parsed(string.rep("a", MAX))
	check(kind == "set" and text == string.rep("a", MAX), "exactly the cap is fine")
	check(parsed(string.rep("a", MAX + 1)) == "nil", "one over the cap is refused")
	check(parsed(string.rep("Ü", MAX)) == "set", "the cap counts characters, not bytes")
	check(parsed(string.rep("Ü", MAX + 1)) == "nil", "multi-byte over the cap refused")
	check(parsed(string.rep(" ", MAX * 4 + 1)) == "nil", "byte flood refused before any scan (even spaces)")
	check(parsed(string.rep("a", 100_000)) == "nil", "huge string refused")
	for _, junk in { 42, 0 / 0, math.huge, true, false, {}, { "name" }, function() end } do
		check(parsed(junk) == "nil", `non-string {typeof(junk)} refused`)
	end
	check(parsed(nil) == "nil", "nil refused (never a reset)")
	check(parsed("Nuke\0Town") == "nil", "NUL refused")
	check(parsed("Nuke\nTown") == "nil", "newline inside refused")
	check(parsed("Nuke\tTown") == "nil", "tab inside refused")
	check(parsed("Nuke\127Town") == "nil", "DEL refused")
	check(parsed("Nuke\u{85}Town") == "nil", "C1 control refused")
	check(parsed("\255\254bad") == "nil", "invalid UTF-8 refused")
	check(parsed("\u{200B}\u{200B}") == "nil", "only zero-width characters refused (not a reset)")
	check(parsed("\u{00A0}\u{3000}") == "nil", "only Unicode spaces refused (not a reset)")
	kind, text = parsed("Ka\u{200B}boom")
	check(kind == "set" and text == "Kaboom", "zero-width space dropped (filter can see the word)")
	kind, text = parsed("Moon\u{202E}Base")
	check(kind == "set" and text == "MoonBase", "bidi override dropped (no reversed signs)")
	kind, text = parsed("Space\u{00A0}\u{00A0}Rock")
	check(kind == "set" and text == "Space Rock", "NBSP becomes one space")
	kind, text = parsed("Zoë's Nukes 日本")
	check(kind == "set" and text == "Zoë's Nukes 日本", "accents / CJK / apostrophes kept")
end

-- 2. normalize ----------------------------------------------------------------------------------------
check(PlotNameLogic.normalize("  a  b  ") == "a b", "normalize trims + collapses")
check(PlotNameLogic.normalize("\u{FEFF}a\u{00AD}b\u{2060}") == "ab", "BOM / soft hyphen / word joiner dropped")
check(PlotNameLogic.normalize("a\u{2003}\u{2009}b") == "a b", "em / thin spaces collapse to one")
check(PlotNameLogic.normalize("\255") == "", "invalid UTF-8 normalizes to empty")
check(PlotNameLogic.normalize("") == "", "empty stays empty")

-- 3. clean ------------------------------------------------------------------------------------------
check(PlotNameLogic.clean("  Big   Boom ", MAX) == "Big Boom", "clean = parse set")
check(PlotNameLogic.clean("", MAX) == nil and PlotNameLogic.clean("   ", MAX) == nil, "clean never returns a reset")
check(PlotNameLogic.clean(string.rep("x", MAX + 1), MAX) == nil, "clean respects the cap")
check(PlotNameLogic.clean("abc", 2) == nil and PlotNameLogic.clean("ab", 2) == "ab", "clean takes its cap argument")

-- 4. Sign text ------------------------------------------------------------------------------------------
check(PlotNameLogic.defaultName("Sam", PlotNameConfig.MainSuffix) == "Sam's Nukes", "Nuke Town default")
check(PlotNameLogic.defaultName("Sam", "Dino Valley") == "Sam's Dino Valley", "other world default")
check(PlotNameLogic.signText("Sam", "Nukes", nil) == "Sam's Nukes", "nil custom → default")
check(PlotNameLogic.signText("Sam", "Nukes", "") == "Sam's Nukes", "empty custom → default")
check(PlotNameLogic.signText("Sam", "Nukes", "Sparkle Base") == "Sparkle Base", "custom replaces the default")
check(PlotNameLogic.signText("Sam", "Moon Base", "Sparkle Base") == "Sparkle Base", "custom shows in every world")
check(PlotNameLogic.isCustom("x") and not PlotNameLogic.isCustom("") and not PlotNameLogic.isCustom(nil), "isCustom")
check(not PlotNameLogic.isCustom(5), "isCustom rejects non-strings")

-- 5. Config ------------------------------------------------------------------------------------------
check(MAX == ProfileLogic.Limits.MaxPlotNameChars, "the cap matches the save format")
check(MAX >= 12 and MAX <= 32, "a sensible cap")
check(PlotNameConfig.MainSuffix == "Nukes", "Nuke Town suffix")
check(type(PlotNameConfig.SignTag) == "string" and #PlotNameConfig.SignTag > 0, "sign tag")
local rename = PlotNameConfig.Rename
check(rename.Burst >= 1 and rename.Burst <= 5, "rename burst bounded")
check(rename.RefillPerSecond > 0 and rename.RefillPerSecond <= 1, "rename refill bounded")
check(rename.ToastSeconds >= 1, "slow-down toast throttled")
local prompt = PlotNameConfig.Prompt
check(prompt.MaxDistance >= 6 and prompt.MaxDistance <= 20, "prompt reach sensible")
check(prompt.HoldSeconds > 0 and prompt.HoldSeconds <= 1, "short hold")
check(PlotNameConfig.Click.MaxDistance >= 30, "the high sign is clickable from the road")
for key, text in PlotNameConfig.Copy do
	check(type(text) == "string" and #text > 0 and #text <= 80, `copy {key} present and short`)
	check(string.find(text, "#", 1, true) == nil, `copy {key} has no filter placeholders`)
end
check(string.format(PlotNameConfig.Copy.Hint, MAX) ~= PlotNameConfig.Copy.Hint, "hint shows the cap")
check(table.isfrozen(PlotNameConfig) and table.isfrozen(PlotNameConfig.Copy), "config frozen")

-- 6. Hostile fuzz -------------------------------------------------------------------------------------
do
	local rng = Random.new(88)
	local alphabet = {
		"a",
		"Z",
		" ",
		"\t",
		"\0",
		"\127",
		"\u{85}",
		"\u{200B}",
		"\u{202E}",
		"\u{00A0}",
		"Ü",
		"日",
		"#",
		"\255",
		"'",
		"!",
	}
	for _ = 1, 4000 do
		local parts: { string } = {}
		for _ = 1, rng:NextInteger(0, 40) do
			table.insert(parts, alphabet[rng:NextInteger(1, #alphabet)])
		end
		local raw = table.concat(parts)
		local ok, intent = pcall(PlotNameLogic.parse, raw, MAX)
		check(ok, "parse never throws")
		if intent ~= nil and intent.kind == "set" then
			local text = intent.text
			local length = utf8.len(text)
			check(length ~= nil and length >= 1 and length <= MAX, "accepted names are valid + capped")
			check(string.find(text, "%c") == nil, "accepted names are control-free")
			check(PlotNameLogic.normalize(text) == text, "accepted names are already normalized")
			check(string.find(text, "\u{200B}", 1, true) == nil, "accepted names carry no zero-width space")
		end
	end
end

-- 7. Analytics: every renamePlot key the server records passes KeySpec (the tycoon family allowlist).
do
	local AnalyticsLoader = require("./analytics-fixtures/Loader")
	local env = AnalyticsLoader.new()
	local KeySpec = env.load("src/server/Analytics/KeySpec")
	for _, how in { "set", "reset", "admin" } do
		check(KeySpec.check("tycoon", `renamePlot:{how}`) == `renamePlot:{how}`, `analytics key renamePlot:{how}`)
	end
	check(KeySpec.check("tycoon", "renamePlot:evil") == nil, "unknown renamePlot suffix refused")
end

print(`[plot-name] {checks} checks passed`)
