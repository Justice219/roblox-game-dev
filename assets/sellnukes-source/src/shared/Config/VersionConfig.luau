--!strict
--[[
	VersionConfig — the game's player-facing version number (copied from RoBeasts, where the owner
	asked for "a version counter ... and start updating"). One semver string, shown quietly in a
	corner of the HUD / settings and as a pill on every WHAT'S NEW note, so players (and the owner
	reading feedback / bug reports) can tell exactly which update they are on.

	Versioning policy (CLAUDE.md "After every task": bump VersionConfig + ChangeNotesConfig for
	player-facing changes):
		MAJOR.MINOR.PATCH, e.g. "0.2.0"
		- MINOR (0.1.0 → 0.2.0, PATCH back to 0): a player-facing FEATURE update. It also appends
		  ONE new note to ChangeNotesConfig.Notes with `Version = "0.2.0"`.
		- PATCH (0.2.0 → 0.2.1): fixes / tuning a player can notice. It also appends items to the
		  NEWEST note (usually tagged FIXED / IMPROVED); that note keeps its own Version.
		- MAJOR: 1.0.0 = public launch; later MAJOR bumps are relaunch-sized (the owner decides).
		- Internal-only changes (tests, docs, admin tools, refactors nobody can notice) bump
		  NOTHING and add no note.
		History: 0.1.0 = SellNukes is born (2026-10-30, first playable framework); 0.2.0 = the full
		tycoon + side systems (2026-10-30); 0.3.0 = WHAT'S NEW panel + HUD chip, flying cash / gems,
		live Robux prices (2026-10-31, owner R58); 0.4.0 = the first five permanent Roblox badges
		(2026-10-31); 0.5.0 = World 3 Moon Base, Lucky Buttons, the juice pass, player titles
		(2026-10-31, owner R69–R75); 0.5.1 = gamepass base prices reduced by about 30% (2026-10-31); 0.6.0 = the retention pack:
		Quests, the Nuke Pass Season 1, Rush boosts, Friend Boost + referrals, Pet Index rewards
		(2026-10-31, owner R78); 0.7.0 = Surprise Batches + Flavour Book + Big Pop, Nukey's Happy
		Hours, the 1-minute gift ladder + Pocket Rocket, AA tower defences, plot names, gem upgrades,
		manager name tags, Lucky Wheel juice, boost badge, clean menus + Quests handoff, tutorial
		button highlight (2026-11-01, owner R79–R92).

	Rules checked by ChangeNotesConfig.validate() (tests/change-notes.luau on every
	./scripts/check.sh):
		- `Current` and every note's Version are strict semver "X.Y.Z" (no leading zeros);
		- note versions never go down in list order;
		- `Current` ≥ the newest note's Version AND has the same MAJOR.MINOR (a MINOR bump without
		  its note, or a note newer than the game, fails the check).

	Connects to: Shared/Config/ChangeNotesConfig (Note.Version + validate, menuText while a note is
	hidden), the Settings version label and the WHAT'S NEW screen's version pill,
	tests/change-notes.luau. Same module as RoBeasts' (docs/change-notes.md).

	Example:
		local VersionConfig = require(ReplicatedStorage.Shared.Config.VersionConfig)
		print(VersionConfig.label())                          --> "v0.1.0"
		print(VersionConfig.menuText(game.PlaceVersion))      --> "v0.1.0 · build 12" ("v0.1.0" in Studio)
		print(VersionConfig.compare("1.2.0", "1.10.0"))       --> -1 (numeric, not text, order)
		assert(VersionConfig.parse("1.02.0") == nil)          -- leading zeros are not semver
]]

-- A parsed "MAJOR.MINOR.PATCH" (whole numbers ≥ 0).
export type Version = { major: number, minor: number, patch: number }

local VersionConfig = {}

-- THE current version. Bump it with every player-facing change (see the policy above).
VersionConfig.Current = "0.9.2"

-- Longest accepted version string, and the largest accepted part. Generous for real versions,
-- small enough that parse() never handles absurd input (a 10k-digit "1.1.1" from a bad edit).
VersionConfig.MaxLength = 20
VersionConfig.MaxPart = 9999

-- Separator between the version and the build number in the menu label.
local BUILD_SEPARATOR = " · "

--[[
	Parses a strict semver core "X.Y.Z" (digits only, no leading zeros except a lone "0", no
	pre-release / build suffixes, each part ≤ MaxPart). Anything else (non-strings included)
	returns nil.
	@param value  any value (untrusted input is fine)
	@return the parts, or nil
	Example: VersionConfig.parse("1.12.3") --> { major = 1, minor = 12, patch = 3 }
	         VersionConfig.parse("v1.2.0") --> nil
]]
function VersionConfig.parse(value: unknown): Version?
	if type(value) ~= "string" or #value > VersionConfig.MaxLength then
		return nil
	end
	local a, b, c = string.match(value, "^(%d+)%.(%d+)%.(%d+)$")
	if a == nil or b == nil or c == nil then
		return nil
	end
	local parts = { a, b, c }
	for _, part in parts do
		-- Semver: numeric identifiers MUST NOT include leading zeros ("01" is not "1").
		if #part > 1 and string.sub(part, 1, 1) == "0" then
			return nil
		end
	end
	local major, minor, patch = tonumber(a), tonumber(b), tonumber(c)
	if major == nil or minor == nil or patch == nil then
		return nil
	end
	local maxPart = VersionConfig.MaxPart
	if major > maxPart or minor > maxPart or patch > maxPart then
		return nil
	end
	return { major = major, minor = minor, patch = patch }
end

--[[ True when `value` is a strict "X.Y.Z" version (see parse). ]]
function VersionConfig.isValid(value: unknown): boolean
	return VersionConfig.parse(value) ~= nil
end

--[[
	Orders two versions numerically (MAJOR, then MINOR, then PATCH): -1 when a < b, 0 when equal,
	1 when a > b. Errors on an invalid version: callers validate first (validate() reports bad
	strings as problems before it ever compares them).
	Example: VersionConfig.compare("1.9.0", "1.10.0") --> -1
]]
function VersionConfig.compare(a: string, b: string): number
	local left, right = VersionConfig.parse(a), VersionConfig.parse(b)
	if left == nil or right == nil then
		error(`VersionConfig.compare: invalid version ({tostring(a)}, {tostring(b)})`)
	end
	local l, r = left :: Version, right :: Version
	-- The first differing part decides (MAJOR outranks MINOR outranks PATCH).
	local function order(x: number, y: number): number
		return if x < y then -1 elseif x > y then 1 else 0
	end
	local result = order(l.major, r.major)
	if result == 0 then
		result = order(l.minor, r.minor)
	end
	if result == 0 then
		result = order(l.patch, r.patch)
	end
	return result
end

--[[
	True when both versions are valid and share MAJOR.MINOR (they belong to the same feature
	update; PATCH may differ). ChangeNotesConfig uses it for "Current matches the newest note".
	Example: VersionConfig.sameMinor("1.2.3", "1.2.0") --> true
]]
function VersionConfig.sameMinor(a: string, b: string): boolean
	local left, right = VersionConfig.parse(a), VersionConfig.parse(b)
	return left ~= nil and right ~= nil and left.major == right.major and left.minor == right.minor
end

--[[
	The player-facing version label: "v" + `version` (default: Current). The WHAT'S NEW card passes
	its note's Version for the version pill.
	Example: VersionConfig.label()        --> "v0.1.0"
	         VersionConfig.label("1.2.0") --> "v1.2.0"
]]
function VersionConfig.label(version: string?): string
	return `v{version or VersionConfig.Current}`
end

--[[
	The version label text: the label plus the Roblox place build when there is one, e.g.
	"v0.1.0 · build 431". `placeVersion` is game.PlaceVersion: 0 in an unpublished Studio
	session (then only "v0.1.0"); anything that is not a whole number in 1..2^31-1 is ignored.
	@param placeVersion  game.PlaceVersion (any value)
	Example: VersionConfig.menuText(431) --> "v0.1.0 · build 431"
	         VersionConfig.menuText(0)   --> "v0.1.0"
]]
function VersionConfig.menuText(placeVersion: unknown): string
	local label = VersionConfig.label()
	if
		type(placeVersion) ~= "number"
		or placeVersion ~= placeVersion
		or placeVersion % 1 ~= 0
		or placeVersion < 1
		or placeVersion > 2_147_483_647
	then
		return label
	end
	return `{label}{BUILD_SEPARATOR}build {string.format("%d", placeVersion)}`
end

--[[
	Checks this module's own data (`Current` is a valid version). The cross-checks against the
	change notes live in ChangeNotesConfig.validate().
	@return problems (empty = valid)
]]
function VersionConfig.validate(): { string }
	local problems: { string } = {}
	if not VersionConfig.isValid(VersionConfig.Current) then
		table.insert(problems, `VersionConfig.Current {tostring(VersionConfig.Current)} must be "X.Y.Z"`)
	end
	return problems
end

return table.freeze(VersionConfig)
