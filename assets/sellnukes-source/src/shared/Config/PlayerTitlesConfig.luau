--!strict
--[[
	PlayerTitlesConfig — the Player Titles catalogue (owner R73 "give me a name tag whenever I'm in
	the game so people know I'm the developer", grown by R74 into titles: DEVELOPER, FIRST PLAYER,
	EARLY PLAYER).

	Purpose:
		WHAT titles exist (label, stud colour, icon, chat prefix, priority) and WHO holds one
		permanently, by Roblox UserId ONLY (names change and collide: an unrelated account is
		literally called "JusticeDev", so names are never keys). Granted titles live in each
		player's profile (`titles`, Shared/Util/PlayerTitles.reconcileState), given / revoked by
		the owner through the audited admin commands TitleGrant / TitleRevoke.
		One title is displayed per player: the highest `priority` they hold
		(DEVELOPER > FIRST PLAYER > EARLY PLAYER). The server (Server/Services/PlayerTitleService)
		decides it and sets the replicated Player attribute `Title`; clients only render it.

	Rules of the catalogue:
		key        stable id (SAVE DATA in profiles: never rename or reuse)
		label      the overhead tag text
		color      UIStyleConfig colour name of the stud panel
		icon       IconAssets key on the tag
		chatPrefix the chat tag in front of the speaker's name ("[DEV]")
		chatColor  its rich-text hex colour
		priority   higher wins when a player holds several
		grantable  the admin panel may give / revoke it (DEVELOPER never: nobody can be made to
		           look like the developer)

	Connects to: Shared/Util/PlayerTitles (pure rules), Server/Services/PlayerTitleService,
	Client/Social/PlayerTitleClient, Server/Economy/ProfileLogic (`titles`, `showTitle`),
	UI/Screens/Admin/ActionsTab (the owner's ON / OFF chip), tests/player-titles.luau.

	Example:
		local def = PlayerTitlesConfig.Titles.developer --> { label = "DEVELOPER", chatPrefix = "[DEV]", ... }
]]

local PlayerTitlesConfig = {}

export type TitleDef = {
	key: string,
	label: string,
	color: string,
	icon: string,
	chatPrefix: string,
	chatColor: string,
	priority: number,
	grantable: boolean,
	-- Owner R77: does the HOLDER see this tag over their own head? FIRST / EARLY PLAYER holders
	-- want to see their badge of honour; the owner's DEVELOPER tag stays off on his own screen
	-- (it sat in the middle of his view). Everybody else always sees every shown title.
	showOwn: boolean,
}

local function title(def: TitleDef): TitleDef
	return table.freeze(def) :: any
end

PlayerTitlesConfig.Titles = table.freeze({
	developer = title({
		key = "developer",
		label = "DEVELOPER",
		color = "yellow", -- gold: reads as special
		icon = "Admin", -- the wrench (same as the HUD admin chip)
		chatPrefix = "[DEV]",
		chatColor = "#FFB43C",
		priority = 300,
		grantable = false,
		showOwn = false, -- the owner's own view stays clear
	}),
	firstPlayer = title({
		key = "firstPlayer",
		label = "FIRST PLAYER",
		color = "teal",
		icon = "Star",
		chatPrefix = "[FIRST PLAYER]",
		chatColor = "#4FE0D2",
		priority = 200,
		grantable = true,
		showOwn = true, -- owner R77: the first player sees his own tag
	}),
	earlyPlayer = title({
		key = "earlyPlayer",
		label = "EARLY PLAYER",
		color = "green",
		icon = "Star",
		chatPrefix = "[EARLY]",
		chatColor = "#8BE36A",
		priority = 100,
		grantable = true,
		showOwn = true,
	}),
	-- R78 Nuke Pass exclusives (Shared/Config/PassConfig.Exclusives; granted by PassService through
	-- PlayerTitleService.grant, saved in profile.titles). Below the honour titles: a player who
	-- holds EARLY PLAYER keeps showing it. Grantable so the owner can give / revoke them too.
	nukePass = title({
		key = "nukePass",
		label = "NUKE PASS",
		color = "purple", -- premium colour (docs/ui.md §4)
		icon = "NukePass", -- the pass's own icon
		chatPrefix = "[NUKE PASS]",
		chatColor = "#C77DFF",
		priority = 60,
		grantable = true,
		showOwn = true, -- earned / bought: the holder sees their own tag
	}),
	season1 = title({
		key = "season1",
		label = "SEASON 1",
		color = "orange", -- Harvest Season colour
		icon = "Trophy",
		chatPrefix = "[SEASON 1]",
		chatColor = "#FF9A3C",
		priority = 50,
		grantable = true,
		showOwn = true,
	}),
}) :: { [string]: TitleDef }

-- Catalogue order (admin dropdown order, highest priority first).
PlayerTitlesConfig.Order =
	table.freeze({ "developer", "firstPlayer", "earlyPlayer", "nukePass", "season1" }) :: { string }

--[[
	Permanent holders, by UserId only (verified 2026-10-31):
		1586034782  owner (username JusticeTTV1, display "JusticeDev")             -> DEVELOPER
		0 the game's first player (username <player>, display
		            "<player>"; first on the live Playtime + Cash leaderboards)     -> FIRST PLAYER
	(0 is an unrelated account literally named "JusticeDev": NOT the owner.)
]]
PlayerTitlesConfig.Holders = table.freeze({
	[1586034782] = table.freeze({ "developer" }),
	[0] = table.freeze({ "firstPlayer" }),
}) :: { [number]: { string } }

-- Replicated Player attributes (server-set): the displayed title key ("" = none) and whether the
-- player hid their own title.
PlayerTitlesConfig.Attr = "Title"
PlayerTitlesConfig.HiddenAttr = "TitleHidden"
-- The profile setting (ProfileLogic SettingKeys) behind the owner's ON / OFF chip. Default ON.
PlayerTitlesConfig.SettingKey = "showTitle"
-- Most granted titles a profile keeps (reconcile bound; the catalogue is far smaller).
PlayerTitlesConfig.MaxGranted = 8

--[[
	The overhead tag (a BillboardGui on the character's Head; stud panel, kid-friendly). Lead review
	2026-10-31: sized in STUDS like a real name tag (it shrinks with distance and never dominates
	the screen) with only a small pixel floor so it stays readable at ~20-60 studs on phones and
	TVs; it sits just above Roblox's own name (StudsOffset ~2 over the head's centre). Whether the
	HOLDER sees their own tag is per title (`TitleDef.showOwn`, owner R77): FIRST / EARLY PLAYER yes,
	DEVELOPER no (it sat in the middle of the owner's view). Everybody else always sees it.
]]
PlayerTitlesConfig.Tag = table.freeze({
	StudsWidth = 5,
	StudsHeight = 1.15,
	PixelWidth = 40, -- readability floor far away (added to the studs size)
	PixelHeight = 10,
	StudsOffset = Vector3.new(0, 2.1, 0),
	MaxDistance = 120,
	TextScale = 0.62, -- label height share of the tag (TextScaled within it)
})

return table.freeze(PlayerTitlesConfig)
