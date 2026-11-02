--!strict
--[[
	Player Titles regressions (owner R73 "give me a name tag ... so people know I'm the developer",
	R74 the titles system). Run:
		lune run tests/player-titles

	Proves on the shipped modules (Shared/Util/PlayerTitles, Shared/Config/PlayerTitlesConfig,
	Server/Economy/ProfileLogic):
	  1. Catalogue: DEVELOPER > FIRST PLAYER > EARLY PLAYER by priority; keys match their table
	     keys; colours / chat colours / prefixes are well-formed; DEVELOPER is never grantable.
	  2. Permanent holders by UserId ONLY: the owner (1586034782) -> DEVELOPER, the first player
	     (0) -> FIRST PLAYER; the unrelated "JusticeDev" account (0) -> nothing.
	  3. Resolution / priority: the highest title wins across permanent + granted; unknown keys
	     and junk never display; a junk UserId has no permanent title.
	  4. Grant / revoke validation: only grantable catalogue titles; no duplicates; the cap;
	     revoking a title they do not have is refused; DEVELOPER can be neither given nor taken.
	  5. Profile schema: reconcile keeps catalogue keys + a newer server's well-formed keys, drops
	     junk, caps at MaxGranted; the default profile has no titles; the `showTitle` setting is
	     allowlisted (booleans, default ON).
	  6. Client rules: shown() follows Title / TitleHidden (junk draws nothing); the chat prefix is
	     the constant coloured catalogue tag in front of the engine's name.
	  7. Tag size (lead review): studs-sized with a small pixel floor, just above the head, never
	     the holder's own, still >= 14 pt tall at 60 studs on a phone.
]]

local Loader = require("./fixtures/RobloxLoader")
local loader = Loader.new()
local PlayerTitles = loader.load("src/shared/Util/PlayerTitles")
local Config = loader.load("src/shared/Config/PlayerTitlesConfig")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")

local checks = 0
local function ok(condition: any, label: string)
	checks += 1
	if not condition then
		error(`[player-titles] FAILED: {label}`, 2)
	end
end

local OWNER = 1586034782
local FIRST = 0
local NOT_THE_OWNER = 0 -- an unrelated account literally named "JusticeDev"

-- 1. Catalogue
local titles = Config.Titles
ok(titles.developer.priority > titles.firstPlayer.priority, "DEVELOPER outranks FIRST PLAYER")
ok(titles.firstPlayer.priority > titles.earlyPlayer.priority, "FIRST PLAYER outranks EARLY PLAYER")
ok(titles.developer.chatPrefix == "[DEV]", "developer chat tag is [DEV]")
ok(titles.firstPlayer.chatPrefix == "[FIRST PLAYER]", "first player chat tag")
ok(titles.earlyPlayer.chatPrefix == "[EARLY]", "early player chat tag")
ok(not titles.developer.grantable, "DEVELOPER is never grantable")
for key, entry in titles do
	ok(entry.key == key, `{key}: key matches its table key`)
	ok(string.match(entry.chatColor, "^#%x%x%x%x%x%x$") ~= nil, `{key}: chat colour is a rich-text hex`)
	ok(string.find(entry.chatPrefix, "[<>&]") == nil, `{key}: chat tag has no markup characters`)
	ok(#entry.label > 0 and #entry.label <= 16, `{key}: label fits the tag`)
	ok(table.find(Config.Order, key) ~= nil, `{key}: listed in Order`)
end
-- R78: + the Nuke Pass exclusives NUKE PASS (premium tier 20) and SEASON 1 (free tier 30).
ok(#Config.Order == 5, "five titles in the catalogue")
ok(titles.earlyPlayer.priority > titles.nukePass.priority, "EARLY PLAYER outranks NUKE PASS")
ok(titles.nukePass.priority > titles.season1.priority, "NUKE PASS outranks SEASON 1")
ok(titles.nukePass.grantable and titles.season1.grantable, "the pass titles can be granted (PassService)")
ok(titles.nukePass.showOwn and titles.season1.showOwn, "pass title holders see their own tag")

-- 2. Permanent holders (UserId only)
ok(PlayerTitles.resolve(OWNER, nil) == "developer", "the owner wears DEVELOPER")
ok(PlayerTitles.resolve(FIRST, nil) == "firstPlayer", "the first player wears FIRST PLAYER")
ok(PlayerTitles.resolve(NOT_THE_OWNER, nil) == nil, "the unrelated JusticeDev account wears nothing")
ok(PlayerTitles.resolve(42, nil) == nil, "a random player wears nothing")

-- 3. Resolution / priority
ok(PlayerTitles.resolve(42, { earlyPlayer = true }) == "earlyPlayer", "a granted title shows")
ok(PlayerTitles.resolve(42, { earlyPlayer = true, firstPlayer = true }) == "firstPlayer", "highest granted wins")
ok(PlayerTitles.resolve(OWNER, { earlyPlayer = true }) == "developer", "DEVELOPER beats a granted EARLY PLAYER")
ok(PlayerTitles.resolve(FIRST, { earlyPlayer = true }) == "firstPlayer", "FIRST PLAYER beats EARLY PLAYER")
ok(PlayerTitles.resolve(42, { futureTitle = true }) == nil, "an unknown (newer) key never displays")
ok(PlayerTitles.resolve(42, { earlyPlayer = "yes" }) == nil, "only true grants count")
ok(PlayerTitles.resolve(0 / 0, nil) == nil and PlayerTitles.resolve("1586034782", nil) == nil, "junk ids")
ok(PlayerTitles.resolve(OWNER + 0.5, nil) == nil, "fractional ids")

-- 4. Grant / revoke validation
local state = PlayerTitles.newState()
ok(PlayerTitles.grant(state, "earlyPlayer") == true and state.earlyPlayer == true, "grant EARLY PLAYER")
local again, problem = PlayerTitles.grant(state, "earlyPlayer")
ok(again == false and problem ~= nil, "no duplicate grant")
ok(PlayerTitles.grant(state, "developer") == false and state.developer == nil, "DEVELOPER cannot be given")
ok(PlayerTitles.grant(state, "nope") == false, "unknown titles cannot be given")
ok(PlayerTitles.grant(state, 5) == false, "junk args cannot be given")
ok(PlayerTitles.revoke(state, "developer") == false, "DEVELOPER cannot be taken")
ok(PlayerTitles.revoke(state, "firstPlayer") == false, "revoking a title they lack is refused")
ok(PlayerTitles.revoke(state, "earlyPlayer") == true and state.earlyPlayer == nil, "revoke EARLY PLAYER")
local full = {}
for i = 1, Config.MaxGranted do
	full[`old{i}`] = true
end
ok(PlayerTitles.grant(full :: any, "earlyPlayer") == false, "the cap holds")
local values, labels = PlayerTitles.grantChoices()
ok(table.find(values, "developer") == nil, "the admin dropdown never offers DEVELOPER")
ok(#values == #labels and #values >= 2, "dropdown lists the grantable titles with labels")

-- 5. Profile schema
ok(next(ProfileLogic.defaultProfile().titles) == nil, "a fresh profile has no granted titles")
local reconciled = PlayerTitles.reconcileState({
	earlyPlayer = true,
	futureTitle = true, -- a newer server's title: kept, never displayed here
	BadKey = true,
	["has space"] = true,
	firstPlayer = "yes",
	[5] = true,
})
ok(reconciled.earlyPlayer == true and reconciled.futureTitle == true, "keeps catalogue + newer well-formed keys")
ok(reconciled.BadKey == nil and reconciled["has space"] == nil, "drops malformed keys")
ok(reconciled.firstPlayer == nil, "drops non-true values")
ok(next(PlayerTitles.reconcileState("junk")) == nil, "junk save data -> none")
local many = {}
for i = 1, 30 do
	many[`title{i}`] = true
end
local capped = 0
for _ in PlayerTitles.reconcileState(many) do
	capped += 1
end
ok(capped == Config.MaxGranted, "reconcile caps the granted set")
ok(ProfileLogic.defaultProfile().settings[Config.SettingKey] == true, "showTitle defaults ON")
ok(table.find(ProfileLogic.SettingKeys, Config.SettingKey) ~= nil, "showTitle is allowlisted")
local settings = ProfileLogic.defaultProfile().settings
ok(ProfileLogic.applySetting(settings, Config.SettingKey, false), "a holder can hide their tag")
ok(not ProfileLogic.applySetting(settings, Config.SettingKey, "off"), "booleans only")

-- 6. Client rules
ok(PlayerTitles.shown("developer", nil) == titles.developer, "Title attribute draws its def")
ok(PlayerTitles.shown("developer", true) == nil, "TitleHidden hides it")
ok(PlayerTitles.shown("", false) == nil, "empty Title draws nothing")
ok(PlayerTitles.shown("futureTitle", nil) == nil and PlayerTitles.shown(5, nil) == nil, "junk draws nothing")
ok(PlayerTitles.hiddenFromSetting(false) and not PlayerTitles.hiddenFromSetting(nil), "only an explicit false hides")
local dev = titles.developer
ok(
	PlayerTitles.chatPrefix(dev, "Sam:") == `<font color="{dev.chatColor}">[DEV]</font> Sam:`,
	"chat: coloured [DEV] in front of the name"
)
ok(PlayerTitles.chatPrefix(dev, nil) == `<font color="{dev.chatColor}">[DEV]</font>`, "non-string prefix is safe")

-- 7. Tag size (lead review 2026-10-31): a real name tag sized in studs, just above Roblox's name,
-- the holder's own per title (owner R77: the FIRST PLAYER sees his; the DEVELOPER tag blocked the
-- centre of the owner's view, so it stays off on his own screen).
local tag = Config.Tag
ok(titles.developer.showOwn == false, "the owner never sees his own DEVELOPER tag")
ok(titles.firstPlayer.showOwn == true, "the first player sees his own FIRST PLAYER tag (R77)")
ok(titles.earlyPlayer.showOwn == true, "early players see their own tag")
for key, def in titles do
	ok(type(def.showOwn) == "boolean", `{key}: showOwn is set`)
end
ok(tag.StudsOffset.Y >= 1.5 and tag.StudsOffset.Y <= 2.5, "sits just above the head / Roblox name")
ok(tag.StudsWidth >= 4 and tag.StudsWidth <= 6.5 and tag.StudsHeight <= 1.5, "studs-sized like a name tag")
ok(tag.PixelWidth <= 48 and tag.PixelHeight <= 12, "only a small pixel floor (it shrinks with distance)")
-- Readability floor at 60 studs on a phone (390 pt tall, fov 70): studs part + the pixel floor.
local pointsPerStud = 390 / (2 * 60 * math.tan(math.rad(70) / 2))
ok(tag.StudsHeight * pointsPerStud + tag.PixelHeight >= 14, "readable (>= 14 pt tall) at 60 studs on a phone")

print(`[player-titles] {checks} checks passed`)
