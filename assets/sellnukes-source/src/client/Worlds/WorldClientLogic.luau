--!strict
--[[
	WorldClientLogic — the pure decisions of the worlds client (owner R57 World 2, spec §4 / §14).

	Purpose:
		No Instances, no services, no yields: Lune-testable rules the worlds UI shares, so the
		Teleport / Rebirth / Welcome Back / Shop tabs, the HUD and WorldClient all agree.
			tabs(current, unlocked, enabled)   the world tab model in WorldsConfig.Order
			cycle(tabs, currentId, delta)      LB / RB: the next tab id (wraps)
			failText(reason)                   the friendly toast of a TravelRules reason
			shouldShowUnlock(at, anchor, slack) the WORLD UNLOCKED "once per join" rule
			sessionAnchor(plotAssigned, synced) that rule's session start (never an unsynced 0)
			lockHint(worldId, mainTycoon)      "Reach BoomDash Delivery to unlock!" + progress
			formatAmount / formatRate          "$1.2T" / "4.5M Bones" / "+1.25K/s Bones"
			balanceText(currency, amount)      the Teleport tab balance pill text (R60)
			linkLines(rebirthsByWorld)         "Dino Bonus: +30% Nuke Town cash (3 Dino rebirths)"
			musicContext(key, has)             the SoundController override of a music key
			ambienceBed(key, has, seconds)     the world's ambience bed SFX + its loop period
			validatePreset(preset)             lighting preset sanity (finite, in engine ranges)
			rejoinOffer(last, ...)             whether the "Back to Dino Valley?" chip shows
			chipLayout(band, wide, stackedMin) the rejoin chip's one-row / stacked / shrunk layout
			isNewWorld(world)                  the Teleport NEW dot (unlocked, never visited)
			travelAllowed(now, last, gap)      the client-side throttle (1 / s)
		Everything here is DISPLAY logic over server state; the server decides every trip.

	Connects to: Shared/Config/{WorldClientConfig, Worlds/WorldsConfig}, Shared/Tycoon/TycoonLogic,
	Shared/Util/NumberFormat; callers Client/Worlds/WorldClient, UI/Screens/{Teleport, Rebirth,
	WelcomeBack, Shop, WorldUnlocked}, UI/Hud/{Hud, HudCurrency}; tests/world-client.luau.

	Example:
		local tabs = WorldClientLogic.tabs("main", ClientState.worldUnlocked, WorldClient.isEnabled)
		print(tabs[2].label, tabs[2].state) --> "DINO VALLEY", "locked"
		WorldClientLogic.formatAmount(WorldsConfig.get("dino").currency, 4.5e6) --> "4.5M Bones"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local WorldClientConfig = require(ReplicatedStorage.Shared.Config.WorldClientConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

export type TabState = "open" | "locked" | "closed"

-- One world tab (display model).
export type Tab = {
	id: string,
	label: string,
	short: string,
	icon: string,
	color: string,
	state: TabState,
	current: boolean, -- the player is in this world right now
}

-- One cross-world link line (spec §6.5).
export type LinkLine = {
	worldId: string, -- the world whose rebirths pay the bonus
	text: string,
	percent: number, -- whole percent (30 = +30 %)
}

local WorldClientLogic = {}

local MAIN = WorldsConfig.MAIN

-- A finite number, else nil.
local function finite(value: unknown): number?
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- A whole, non-negative count (junk -> 0).
local function count(value: unknown): number
	local n = finite(value)
	if n == nil or n < 0 then
		return 0
	end
	return math.floor(n)
end

-- "{key}" placeholders filled from `values` (unknown keys stay as written).
local function fill(template: string, values: { [string]: string }): string
	-- A table replacement keeps the original "{key}" text for keys it does not have.
	return (string.gsub(template, "{(%w+)}", values))
end
WorldClientLogic.fill = fill

--[[
	The tab style of a world (WorldClientConfig.Tabs, or a safe default built from WorldsConfig so
	a World 3 without a style row still shows a working tab).
]]
function WorldClientLogic.style(worldId: string): WorldClientConfig.TabStyle
	local style = WorldClientConfig.Tabs[worldId]
	if style ~= nil then
		return style
	end
	local def = WorldsConfig.get(worldId)
	local name = if def ~= nil then def.name else worldId
	return {
		label = string.upper(name),
		short = string.upper(string.sub(name, 1, 6)),
		icon = "Teleport",
		color = "blue",
		spawnLabel = "Hub",
		bonusName = name,
	}
end

export type Portal = {
	model: string, -- MeshAssets key of the world's portal (the WORLD UNLOCKED turntable)
	icon: string, -- IconAssets key (popup header, travel toasts, model fallback)
	pets: string, -- how the unlock copy names the world's pets ("dino pets", "space pets")
}

--[[
	A world's portal look (R70: every world has its own portal — Dino the Time Machine, Moon Base
	the rocket): WorldClientConfig.Portals[worldId] (W9b rows), field by field falling back to the
	shared Unlock.ModelKey / ModelIcon and "pets", so a world without a row still shows something
	sensible and nothing errors.
	Example: WorldClientLogic.portal("moon").model --> "Hub_MoonRocket"
]]
function WorldClientLogic.portal(worldId: string): Portal
	local rows = (WorldClientConfig :: any).Portals
	local row = if type(rows) == "table" then rows[worldId] else nil
	local function field(name: string, fallback: string): string
		local value = if type(row) == "table" then row[name] else nil
		return if type(value) == "string" and value ~= "" then value else fallback
	end
	local unlock = WorldClientConfig.Unlock
	return {
		model = field("model", unlock.ModelKey),
		icon = field("icon", unlock.ModelIcon),
		pets = field("pets", "pets"),
	}
end

--[[
	The world tab model, in WorldsConfig.Order.
	@param current  the world the player is in ("main" default)
	@param unlocked (worldId) -> boolean   server truth (ClientState.worldUnlocked)
	@param enabled  (worldId) -> boolean   admin kill switch (WorldEnabled_<id>; main always on)
	@return { Tab } — state: closed (kill switch) > locked > open; `current` marks the player's world
	Example: WorldClientLogic.tabs("dino", unlocked, enabled)[2].current --> true
]]
function WorldClientLogic.tabs(
	current: string,
	unlocked: (worldId: string) -> boolean,
	enabled: (worldId: string) -> boolean
): { Tab }
	local list: { Tab } = {}
	for _, worldId in WorldsConfig.Order do
		local style = WorldClientLogic.style(worldId)
		local state: TabState = "open"
		if worldId ~= MAIN and not enabled(worldId) then
			state = "closed"
		elseif worldId ~= MAIN and not unlocked(worldId) then
			state = "locked"
		end
		table.insert(list, {
			id = worldId,
			label = style.label,
			short = style.short,
			icon = style.icon,
			color = style.color,
			state = state,
			current = worldId == current,
		})
	end
	return list
end

--[[
	LB / RB: the id `delta` tabs away from `currentId` (wraps; locked / closed tabs are still
	selectable — they show their hint, never send anything).
	Example: WorldClientLogic.cycle(tabs, "main", 1) --> "dino" ; cycle(tabs, "main", -1) --> "dino"
]]
function WorldClientLogic.cycle(tabs: { Tab }, currentId: string, delta: number): string
	local n = #tabs
	if n == 0 then
		return currentId
	end
	local index = 1
	for i, entry in tabs do
		if entry.id == currentId then
			index = i
			break
		end
	end
	local step = if delta < 0 then -1 else 1
	return tabs[(index - 1 + step) % n + 1].id
end

--[[
	The friendly toast of a TravelRules reason (WorldClientConfig.FailText; FailFallback for an
	unknown / missing reason — never shows raw server text).
	Example: WorldClientLogic.failText("cooldown") --> "The portal is recharging. Try again in a sec!"
]]
function WorldClientLogic.failText(reason: unknown): string
	if type(reason) == "string" then
		local text = WorldClientConfig.FailText[reason]
		if text ~= nil then
			return text
		end
	end
	return WorldClientConfig.FailFallback
end

--[[
	The WORLD UNLOCKED "once" rule (spec §4.2): show when the server's `unlockedAt` (unix seconds)
	is at or after this session's start minus `slack` seconds (the server unlocks a legacy player
	while the profile loads, just before the session anchor is stamped).
	@param unlockedAt server unix seconds (0 / junk = never)
	@param anchor     this session's start in server time (sessionAnchor); nil / <= 0 / junk =
	                  "not known yet" -> false (W12 QA: an unsynced client clock reads 0, which
	                  used to make every old unlock look new)
	@param slack      WorldClientConfig.Unlock.JoinSlackSeconds
	Example: WorldClientLogic.shouldShowUnlock(1000, 1010, 90) --> true
	         WorldClientLogic.shouldShowUnlock(1000, 0, 90) --> false (anchor not known yet)
]]
function WorldClientLogic.shouldShowUnlock(unlockedAt: unknown, anchor: unknown, slack: number): boolean
	local at = finite(unlockedAt)
	local start = finite(anchor)
	if at == nil or at <= 0 or start == nil or start <= 0 then
		return false
	end
	return at >= start - math.max(0, slack)
end

--[[
	Owner R130: the first Nuke Town area at which a world's WORLD UNLOCKED popup may open by itself
	= the unlock area + WorldClientConfig.Unlock.PopupAreasAfterUnlock (Dino Valley 3 + 1 = 4,
	Moon Base 5 + 1 = 6). A world that does not unlock by Nuke Town progress (none today) is not
	gated (1).
	@param def a WorldsConfig world definition
	Example: WorldClientLogic.popupArea(WorldsConfig.get("dino")) --> 4
]]
function WorldClientLogic.popupArea(def: WorldsConfig.WorldDef): number
	local rule = def.unlock
	if rule.kind == "progress" and rule.world == MAIN then
		return rule.area + math.max(0, WorldClientConfig.Unlock.PopupAreasAfterUnlock)
	end
	return 1
end

-- Facts the WORLD UNLOCKED popup decision reads (all display state from the synced profile).
export type UnlockPopupFacts = {
	unlocked: boolean, -- the server says the world is unlocked
	unlockedAt: unknown, -- the world's server unlock stamp (unix seconds)
	anchor: unknown, -- this session's start in server time (sessionAnchor)
	slack: number, -- WorldClientConfig.Unlock.JoinSlackSeconds
	mainArea: unknown, -- the player's Nuke Town area now (profile.tycoon.area)
	startArea: unknown, -- their Nuke Town area when this session's profile first synced (nil = not yet)
	rebirths: unknown, -- Nuke Town rebirths (profile.rebirths)
	visits: unknown, -- trips into the world so far (worlds[id].stats.visits)
	popupArea: number, -- WorldClientLogic.popupArea(def)
}

--[[
	Owner R130: whether the WORLD UNLOCKED popup is owed right now (the caller still waits for a
	polite moment and shows it once per session). Rules, in order:
	  1. Never for a locked world.
	  2. Never while the player is still short of `popupArea` in Nuke Town AND has never rebirthed
	     — the popup used to fire at minute ~14 (area 3) and pull new players out of a fresh area
	     into a world starting from zero (2026-11-01 data, docs/owner-requests.md R129 / R130).
	  3. The world was unlocked during this session (spec §4.2 shouldShowUnlock: area reached in
	     this session, an unlock by rebirth, a legacy / admin unlock) -> owed.
	  4. The world was unlocked in an EARLIER session (at the unlock area) and the player crossed
	     `popupArea` during THIS session without ever visiting -> owed, so the discovery moment is
	     not lost. A visited world, or a session that started at / past `popupArea`, owes nothing
	     (the chip, the Teleport NEW dot and the portal still point the way) — so a player is
	     never shown it again after a rebirth.
	Example: WorldClientLogic.unlockPopupOwed({ unlocked = true, unlockedAt = 1000, anchor = 990,
	         slack = 90, mainArea = 3, startArea = 1, rebirths = 0, visits = 0, popupArea = 4 })
	         --> false (still in area 3)
]]
function WorldClientLogic.unlockPopupOwed(facts: UnlockPopupFacts): boolean
	if facts.unlocked ~= true then
		return false
	end
	local mainArea = count(facts.mainArea)
	if mainArea < facts.popupArea and count(facts.rebirths) <= 0 then
		return false
	end
	if WorldClientLogic.shouldShowUnlock(facts.unlockedAt, facts.anchor, facts.slack) then
		return true
	end
	local startArea = finite(facts.startArea)
	return startArea ~= nil and startArea < facts.popupArea and mainArea >= facts.popupArea and count(facts.visits) <= 0
end

--[[
	This session's start in server time, the anchor of the WORLD UNLOCKED once-rule (W12 QA fix):
	the server-set Player attribute PlotAssignedAt of this join when present (server clock, set
	at join), else the first SYNCED client reading of Workspace:GetServerTimeNow() (0 / junk =
	not synced yet). nil = not known yet: nothing is owed until it is.
	Example: WorldClientLogic.sessionAnchor(1793418000.5, 0) --> 1793418000.5
	         WorldClientLogic.sessionAnchor(nil, 0) --> nil
]]
function WorldClientLogic.sessionAnchor(plotAssignedAt: unknown, firstSynced: unknown): number?
	local assigned = finite(plotAssignedAt)
	if assigned ~= nil and assigned > 0 then
		return assigned
	end
	local synced = finite(firstSynced)
	if synced ~= nil and synced > 0 then
		return synced
	end
	return nil
end

--[[
	The locked-world hint (spec §4.3): "Reach BoomDash Delivery to unlock!" plus the progress of
	the area BEFORE the unlock area in the rule's world (bought, total), as the Teleport list does
	for locked areas. A world without a progress rule returns the hint with 0 / 0.
	@param worldId    the locked world
	@param ruleTycoon the tycoon state of the rule's world (main: profile.tycoon), or nil
	@return (hint, areaName, bought, total)
	Example: WorldClientLogic.lockHint("dino", profile.tycoon) --> "Reach BoomDash Delivery to unlock!", "BoomDash Delivery", 6, 9
]]
function WorldClientLogic.lockHint(worldId: string, ruleTycoon: any): (string, string, number, number)
	local def = WorldsConfig.get(worldId)
	if def == nil or def.unlock.kind ~= "progress" then
		return fill(WorldClientConfig.LockedHint, { area = "the next area" }), "the next area", 0, 0
	end
	local rule = def.unlock :: any
	local ruleWorld = WorldsConfig.get(rule.world)
	local areaConfig = if ruleWorld ~= nil then ruleWorld.economy.Areas[rule.area] else nil
	local areaName = if areaConfig ~= nil then areaConfig.name else `area {rule.area}`
	local bought, total = 0, 0
	if ruleWorld ~= nil and type(ruleTycoon) == "table" and type(ruleTycoon.pads) == "table" and rule.area > 1 then
		local logic = TycoonLogic.forWorld(ruleWorld.id)
		bought, total = logic.areaProgress(ruleTycoon, rule.area - 1)
	end
	return fill(WorldClientConfig.LockedHint, { area = areaName }), areaName, bought, total
end

--[[
	A currency amount for display: "money" style -> "$1.2T", "count" style -> "4.5M Bones".
	Example: WorldClientLogic.formatAmount(dino.currency, 4500000) --> "4.5M Bones"
]]
function WorldClientLogic.formatAmount(currency: WorldsConfig.CurrencyDef, amount: number): string
	local value = finite(amount) or 0
	if currency.style == "money" then
		return NumberFormat.money(value)
	end
	return `{NumberFormat.short(value)} {currency.name}`
end

--[[
	A world's balance for its Teleport tab pill (owner R60): money -> "$1.2T", count -> "4.5M"
	(the pill shows the currency icon beside it). Junk amounts read as 0.
	Example: WorldClientLogic.balanceText(dino.currency, 4.5e6) --> "4.5M"
]]
function WorldClientLogic.balanceText(currency: WorldsConfig.CurrencyDef, amount: unknown): string
	local value = finite(amount) or 0
	if currency.style == "money" then
		return NumberFormat.money(value)
	end
	return NumberFormat.short(value)
end

--[[
	An income rate for display: money -> "+$1.25K/s", count -> "+1.25K/s Bones".
	Example: WorldClientLogic.formatRate(dino.currency, 1250) --> "+1.25K/s Bones"
]]
function WorldClientLogic.formatRate(currency: WorldsConfig.CurrencyDef, perSecond: number): string
	local value = finite(perSecond) or 0
	if currency.style == "money" then
		return NumberFormat.rate(value)
	end
	return `+{NumberFormat.short(value)}/s {currency.name}`
end

--[[
	The cross-world link lines (spec §6.5), shown on every Rebirth tab: for each non-main world
	with a link, "<World> Bonus: +X% Nuke Town cash (N <World> rebirths)" and
	"Nuke Town Bonus: +Y% <Currency>". Percentages come from WorldsConfig.linkCash maths (capped).
	@param rebirths { [worldId] = rebirth count } (main = profile.rebirths)
	@return { LinkLine } in WorldsConfig.Order (toMain line, then fromMain line, per world)
]]
function WorldClientLogic.linkLines(rebirths: { [string]: any }): { LinkLine }
	local lines: { LinkLine } = {}
	local mainName = WorldClientLogic.style(MAIN).bonusName
	local mainCount = count(rebirths[MAIN])
	for _, def in WorldsConfig.extra() do
		local link = def.link
		if link == nil then
			continue
		end
		local name = WorldClientLogic.style(def.id).bonusName
		local worldCount = count(rebirths[def.id])
		local toMain = link.toMainPerRebirth * math.min(worldCount, link.toMainMaxRebirths)
		local fromMain = link.fromMainPerRebirth * math.min(mainCount, link.fromMainMaxRebirths)
		local toPercent = math.floor(toMain * 100 + 0.5)
		local fromPercent = math.floor(fromMain * 100 + 0.5)
		local plural = if worldCount == 1 then "rebirth" else "rebirths"
		table.insert(lines, {
			worldId = def.id,
			percent = toPercent,
			text = `{name} Bonus: +{toPercent}% {mainName} cash ({worldCount} {name} {plural})`,
		})
		table.insert(lines, {
			worldId = MAIN,
			percent = fromPercent,
			text = `{mainName} Bonus: +{fromPercent}% {def.currency.name}`,
		})
	end
	return lines
end

--[[
	The SoundController override for a world's music key: the preset's context when the playlist
	exists (`has(context)`), else its fallback, else nil (automatic Nuke Town contexts).
	Example: WorldClientLogic.musicContext("music_dino_valley", function(c) return c == "hub" end) --> "hub"
]]
function WorldClientLogic.musicContext(musicKey: string, has: (context: string) -> boolean): string?
	local music = WorldClientConfig.Music[musicKey]
	if music == nil then
		return nil
	end
	local context = music.context
	if context ~= nil and has(context) then
		return context
	end
	local fallback = music.fallback
	if fallback ~= nil and has(fallback) then
		return fallback
	end
	return nil
end

--[[
	The ambience bed of a world's music key (spec §14: the Dino Valley jungle bed) and how often
	it is re-triggered: the bed key when the preset names one AND `has(key)` says it is a known
	SFX, plus its loop period = the track's length (`seconds(key)`, e.g. SoundAssets.LibrarySfx
	seconds) or WorldClientConfig.BedFallbackSeconds when unknown, clamped to
	[BedMinSeconds, BedMaxSeconds] so a bad length can never spin a tight loop.
	@param musicKey WorldDef.ambience.music
	@param has      (sfxKey) -> boolean (AudioConfig.Sfx lookup; injected for tests)
	@param seconds  (sfxKey) -> number? (the track's length; injected for tests)
	@return (bedKey, periodSeconds) or (nil, 0) when the world has no bed
	Example: WorldClientLogic.ambienceBed("music_dino_valley", hasSfx, lengthOf) --> "amb_jungle", 69
]]
function WorldClientLogic.ambienceBed(
	musicKey: string,
	has: (key: string) -> boolean,
	seconds: (key: string) -> number?
): (string?, number)
	local music = WorldClientConfig.Music[musicKey]
	local bed = if music ~= nil then music.bed else nil
	if bed == nil or not has(bed) then
		return nil, 0
	end
	local length = finite(seconds(bed))
	local period = if length ~= nil and length > 0 then length else WorldClientConfig.BedFallbackSeconds
	return bed, math.clamp(period, WorldClientConfig.BedMinSeconds, WorldClientConfig.BedMaxSeconds)
end

-- True when `value` is a finite number in [low, high].
local function inRange(value: unknown, low: number, high: number): boolean
	local n = finite(value)
	return n ~= nil and n >= low and n <= high
end

--[[
	Lighting preset sanity: a captured preset needs nothing; an applied one needs Ambient /
	OutdoorAmbient Color3s and in-range Atmosphere (Density / Offset 0..1, Glare / Haze 0..10) and
	Tint (Saturation / Contrast / Brightness -1..1) values (the engine's own clamps).
	@return (ok, problem?)
]]
function WorldClientLogic.validatePreset(preset: WorldClientConfig.LightingPreset): (boolean, string?)
	if preset.capture then
		return true, nil
	end
	if typeof(preset.Ambient) ~= "Color3" or typeof(preset.OutdoorAmbient) ~= "Color3" then
		return false, "Ambient / OutdoorAmbient must be Color3"
	end
	local atmosphere = preset.Atmosphere
	if atmosphere == nil then
		return false, "Atmosphere missing"
	end
	if not inRange(atmosphere.Density, 0, 1) or not inRange(atmosphere.Offset, 0, 1) then
		return false, "Atmosphere Density / Offset out of 0..1"
	end
	if not inRange(atmosphere.Glare, 0, 10) or not inRange(atmosphere.Haze, 0, 10) then
		return false, "Atmosphere Glare / Haze out of 0..10"
	end
	if typeof(atmosphere.Color) ~= "Color3" or typeof(atmosphere.Decay) ~= "Color3" then
		return false, "Atmosphere Color / Decay must be Color3"
	end
	local tintLook = preset.Tint
	if tintLook == nil then
		return false, "Tint missing"
	end
	if typeof(tintLook.TintColor) ~= "Color3" then
		return false, "Tint TintColor must be Color3"
	end
	for _, value in { tintLook.Saturation, tintLook.Contrast, tintLook.Brightness } do
		if not inRange(value, -1, 1) then
			return false, "Tint Saturation / Contrast / Brightness out of -1..1"
		end
	end
	-- Optional night sky (R70 Moon Base: ClockTime is never touched, so stars come from a Sky).
	local sky = (preset :: any).Sky
	if sky ~= nil then
		local skyOk, problem = WorldClientLogic.validateSky(sky)
		if not skyOk then
			return false, `Sky: {problem}`
		end
	end
	return true, nil
end

-- The six skybox faces a Sky look must name.
local SKY_FACES = { "SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp" }

--[[
	Validates a preset's optional Sky look (R70, W9b's moon star field): six faces that are each
	an "rbxassetid://<digits>" (or "" while not uploaded: the engine draws its default face),
	StarCount 0..5000, SunAngularSize 0..60, CelestialBodiesShown a boolean.
	@return (ok, problem?)
	Example: WorldClientLogic.validateSky({ SkyboxBk = "rbxassetid://1", ..., StarCount = 3000,
		CelestialBodiesShown = false, SunAngularSize = 11 }) --> true
]]
function WorldClientLogic.validateSky(sky: unknown): (boolean, string?)
	if type(sky) ~= "table" then
		return false, "must be a table"
	end
	local look = sky :: { [string]: unknown }
	for _, face in SKY_FACES do
		local value = look[face]
		if type(value) ~= "string" or (value ~= "" and string.match(value, "^rbxassetid://%d+$") == nil) then
			return false, `{face} must be "rbxassetid://<id>" or ""`
		end
	end
	if not inRange(look.StarCount, 0, 5000) then
		return false, "StarCount out of 0..5000"
	end
	if not inRange(look.SunAngularSize, 0, 60) then
		return false, "SunAngularSize out of 0..60"
	end
	if type(look.CelestialBodiesShown) ~= "boolean" then
		return false, "CelestialBodiesShown must be a boolean"
	end
	return true, nil
end

--[[
	The rejoin chip (spec §4.6): offered when the last session ended in another (still unlocked
	and open) world and the player is in Nuke Town now.
	Example: WorldClientLogic.rejoinOffer("dino", "main", true, true) --> true
]]
function WorldClientLogic.rejoinOffer(lastWorld: string, current: string, unlocked: boolean, enabled: boolean): boolean
	return lastWorld ~= MAIN and WorldsConfig.get(lastWorld) ~= nil and current == MAIN and unlocked and enabled
end

--[[
	The rejoin chip's layout for a free horizontal band (design px between the HUD's left grid and
	right column, spec §4.6 / owner R11):
		band >= wide          one row at its natural width
		band >= stackedMin    two rows (text over GO / X), as wide as the band (never wider than
		                      `wide`), full size
		0 < band < stackedMin two rows at `stackedMin`, shrunk to fit (never below
		                      WorldClientConfig.Rejoin.MinScale)
		unknown / <= 0        one row (the HUD zones are not laid out yet)
	@return { stacked, width (design px before scale), scale }
	Example: WorldClientLogic.chipLayout(560, 720, 440) --> { stacked = true, width = 560, scale = 1 }
]]
function WorldClientLogic.chipLayout(
	band: number,
	wide: number,
	stackedMin: number
): { stacked: boolean, width: number, scale: number }
	local free = finite(band)
	if free == nil or free <= 0 or free >= wide then
		return { stacked = false, width = wide, scale = 1 }
	end
	if free >= stackedMin then
		return { stacked = true, width = math.floor(free), scale = 1 }
	end
	return {
		stacked = true,
		width = stackedMin,
		scale = math.max(WorldClientConfig.Rejoin.MinScale, free / stackedMin),
	}
end

--[[
	The Teleport NEW dot (spec §4.2): an unlocked world the player never visited
	(worlds.<id>.stats.visits == 0). `world` is ClientState.world(id) (nil = no data -> false).
]]
function WorldClientLogic.isNewWorld(world: { [string]: any }?): boolean
	if world == nil or world.unlocked ~= true then
		return false
	end
	local stats = world.stats
	local visits = if type(stats) == "table" then count(stats.visits) else 0
	return visits == 0
end

--[[ Client-side travel throttle: true when `gap` seconds passed since `lastAt`. ]]
function WorldClientLogic.travelAllowed(now: number, lastAt: number, gap: number): boolean
	return now - lastAt >= gap
end

return table.freeze(WorldClientLogic)
