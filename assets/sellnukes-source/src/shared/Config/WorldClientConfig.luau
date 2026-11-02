--!strict
--[[
	WorldClientConfig — presentation tunables of the worlds CLIENT (owner R57 World 2 "Dino Valley",
	spec §4 / §14, plan §3.5): lighting + music presets per world, the warp overlay, the world tabs,
	the friendly travel-failure texts, the WORLD UNLOCKED popup, the rejoin chip, the HUD currency
	swap and the first-run objectives.

	Purpose:
		Display-only numbers and words. Nothing here is a price, a cooldown the server trusts, an
		unlock rule or a reward: the server (WorldService / TravelRules) decides every trip, and the
		client only animates what the server answered (WorldTravel phases). A world's identity
		(name, currency, ambience keys) lives in WorldsConfig; this module maps those keys onto
		client presets, so adding World 3 = one WorldsConfig def + one row in each table here.

	Tables
		Lighting[preset]    client-only Lighting look (Atmosphere / ColorCorrection / Ambient, + an
		                    optional Sky: Moon Base's star-field skybox). The "main" preset is
		                    CAPTURED from the place at boot (`capture = true`), so Nuke Town always
		                    looks exactly as built. ClockTime is NEVER touched (the admin
		                    SetTimeOfDay keeps working in every world), which is why a night sky is a
		                    skybox, not a time of day.
		Music[key]          WorldDef.ambience.music -> a SoundController context override
		                    (nil context = automatic Nuke Town contexts; `fallback` while the
		                    world's own playlist is not in AudioConfig.Contexts yet).
		Overlay             the warp overlay (WorldTravel screen): min on-screen time, fades, swirl.
		Tabs[worldId]       label + IconAssets key + stud colour of each world tab (Teleport,
		                    Rebirth, Welcome Back rows, Shop section headers).
		FailText[reason]    a friendly toast per TravelRules reason (every reason covered —
		                    tests/world-client.luau); FailFallback for anything else.
		Unlock              WORLD UNLOCKED popup copy + the "once per join" slack.
		Rejoin              the "Back to Dino Valley?" chip after the plot reveal.
		Hud                 the top-centre currency stack in a non-main world (the world's
		                    currency + its rate only; owner R60).
		Objectives[worldId] the 3-step first-run objective chip (Worlds/WorldObjectives).
		Offers[worldId]     extra right-column offers that join the rotation while in that world.
		Physics[worldId]    { gravityScale } — Workspace.Gravity multiplier while in that world
		                    (R70 Moon Base 0.4; Client/Worlds/WorldGravity applies it, no row = 1).
		Portals[worldId]    { model, icon, pets } — the world's portal look for the WORLD UNLOCKED
		                    popup (MeshAssets turntable key, IconAssets key, the "{pets}" word);
		                    WorldClientLogic.portal falls back to Unlock.ModelKey / ModelIcon.

	Connects to: Client/Worlds/{WorldClient, WorldClientLogic, WorldObjectives, WorldTabBar},
	UI/Screens/{Teleport, Rebirth, WelcomeBack, Shop, WorldTravel, WorldUnlocked},
	UI/Hud/{Hud, HudCurrency, HudOffers}, Shared/Config/Worlds/WorldsConfig (ids, ambience keys),
	tests/world-client.luau (presets valid, every reason has a text, every world has a tab).

	Example:
		local tab = WorldClientConfig.Tabs.dino --> { label = "DINO VALLEY", icon = "WorldDino", color = "green" }
		local text = WorldClientConfig.FailText.locked
]]

-- One Atmosphere look (every Atmosphere under Lighting is set to it while in the world).
export type AtmosphereLook = {
	Density: number,
	Offset: number,
	Color: Color3,
	Decay: Color3,
	Glare: number,
	Haze: number,
}

-- One ColorCorrection look (applied to the client-only "WorldTint" ColorCorrectionEffect).
export type TintLook = {
	TintColor: Color3,
	Saturation: number,
	Contrast: number,
	Brightness: number,
}

--[[
	A lighting preset. `capture = true` = "whatever the place has at boot" (Nuke Town). Otherwise
	every field is applied (Ambient / OutdoorAmbient on Lighting; Atmosphere to every Atmosphere;
	Tint to the WorldTint effect). Never ClockTime / Brightness / sky (admin + day cycle own those).
]]
export type LightingPreset = {
	capture: boolean,
	Ambient: Color3?,
	OutdoorAmbient: Color3?,
	Atmosphere: AtmosphereLook?,
	Tint: TintLook?,
	Sky: SkyLook?, -- optional skybox swap (nil = keep the place's sky)
}

-- Per-world physics (R70): Workspace.Gravity multiplier while the player is in that world.
export type PhysicsRow = { gravityScale: number }

-- A world's portal look (R70): the WORLD UNLOCKED turntable model, header icon and pets word.
export type PortalStyle = { model: string, icon: string, pets: string }

--[[
	A skybox look (R70 Moon Base's star field, tools/ui/sky/moon_sky.py): six Image asset faces
	("rbxassetid://<id>", or "" while not uploaded), the engine's StarCount (night-only stars),
	CelestialBodiesShown and the sun's apparent size. WorldClient shows it as a client-only Sky
	"WorldSky" and parks the place's own Sky meanwhile (WorldClientLogic.validateSky checks it).
]]
export type SkyLook = {
	SkyboxBk: string,
	SkyboxDn: string,
	SkyboxFt: string,
	SkyboxLf: string,
	SkyboxRt: string,
	SkyboxUp: string,
	StarCount: number,
	CelestialBodiesShown: boolean,
	SunAngularSize: number,
}

-- A music mapping: SoundController.setOverride(context) (nil = automatic contexts), plus the
-- world's optional ambience bed (an AudioConfig.Sfx key looped under the music while there).
export type MusicPreset = {
	context: string?,
	fallback: string?, -- used while AudioConfig.Contexts[context] does not exist yet
	bed: string?, -- AudioConfig.Sfx key of the ambience bed (e.g. "amb_jungle"); nil = none
}

-- One world tab (stud tab button: label, IconAssets key, UIStyleConfig colour name).
export type TabStyle = {
	label: string,
	short: string, -- narrow layouts (phones)
	icon: string,
	color: string,
	spawnLabel: string, -- the world's hub row on the Teleport tab ("Hub", "Base Camp")
	bonusName: string, -- the cross-world link line ("Dino Bonus: +30% Nuke Town cash")
}

-- First-run objective texts ({pad} / {producer} / {manager} / {currency} are filled from config).
export type ObjectiveTexts = {
	build: string,
	click: string,
	hire: string,
}

-- An extra right-column offer that joins the rotation while the player is in that world.
export type WorldOffer = {
	key: string,
	label: string,
	icon: string,
	product: string, -- MonetizationConfig product key
	kind: "product",
	screen: string,
	starter: boolean, -- hidden once profile.worlds.<world>.starter.bought
}

-- Every TravelRules.TravelReason (W4 contract, plan §3.4). Display keys only.
export type TravelReason =
	"unknownWorld"
	| "badTarget"
	| "disabled"
	| "locked"
	| "noPlot"
	| "revealPending"
	| "dead"
	| "busy"
	| "cooldown"
	| "areaLocked"
	| "plotEmpty"
	| "noPass"

local function atmosphere(value: AtmosphereLook): AtmosphereLook
	return table.freeze(value) :: any
end

local function tint(value: TintLook): TintLook
	return table.freeze(value) :: any
end

local function preset(value: LightingPreset): LightingPreset
	return table.freeze(value) :: any
end

local function sky(value: SkyLook): SkyLook
	return table.freeze(value) :: any
end

local function tab(value: TabStyle): TabStyle
	return table.freeze(value) :: any
end

local WorldClientConfig = {}

-- The reason list (order = documentation order; tests check FailText covers every one).
WorldClientConfig.TravelReasons = table.freeze({
	"unknownWorld",
	"badTarget",
	"disabled",
	"locked",
	"noPlot",
	"revealPending",
	"dead",
	"busy",
	"cooldown",
	"areaLocked",
	"plotEmpty",
	"noPass",
} :: { TravelReason })

--[[
	Lighting presets (keys = WorldDef.ambience.lighting). Dino Valley: a warm green jungle haze,
	slightly warmer + more saturated colour, green-gold ambient light. Values were picked against
	the place's own Nuke Town look (Atmosphere density 0.18, CC saturation 0.16 / contrast 0.08),
	so the trip reads as "somewhere else" without blowing out the stud textures (owner R19).
]]
WorldClientConfig.Lighting = table.freeze({
	main = preset({ capture = true }),
	dino = preset({
		capture = false,
		Ambient = Color3.fromRGB(112, 124, 96),
		OutdoorAmbient = Color3.fromRGB(150, 166, 120),
		Atmosphere = atmosphere({
			Density = 0.3,
			Offset = 0.2,
			Color = Color3.fromRGB(206, 226, 170),
			Decay = Color3.fromRGB(120, 150, 92),
			Glare = 0.15,
			Haze = 1.4,
		}),
		Tint = tint({
			TintColor = Color3.fromRGB(255, 246, 226),
			Saturation = 0.12,
			Contrast = 0.04,
			Brightness = 0.02,
		}),
	}),
	--[[
		Moon Base (owner R70, W9b): a NIGHT-SPACE sky over a brightly lit, true-colour moon. The sky
		is the navy star field (skybox, below); the WORLD is lit neutrally so the candy accents
		(mint, coral, sunshine, violet) and the area props pop (lead review 2026-10-31: the first,
		lilac-tinted pass made ground, plots, props and pets one purple-grey):
		  * Ambient / OutdoorAmbient: near-neutral cool greys (shadows stay soft, never lilac).
		  * Atmosphere: very thin (Density 0.02, Haze 0, Glare 0) with a near-white colour, so the
		    stars and far planets stay crisp and distant plots are not washed out.
		  * Tint: pure white with +0.2 saturation and +0.1 contrast (colour separation; Dino uses a
		    warm +0.12 look, Nuke Town its captured place look).
	]]
	moon = preset({
		capture = false,
		Ambient = Color3.fromRGB(128, 132, 142),
		OutdoorAmbient = Color3.fromRGB(168, 172, 182),
		Atmosphere = atmosphere({
			Density = 0.02,
			Offset = 0,
			Color = Color3.fromRGB(214, 220, 240),
			Decay = Color3.fromRGB(120, 128, 176),
			Glare = 0,
			Haze = 0,
		}),
		Tint = tint({
			TintColor = Color3.fromRGB(255, 255, 255),
			Saturation = 0.2,
			Contrast = 0.1,
			Brightness = 0.02,
		}),
		-- Image assets from tools/ui/sky/moon_sky.py (receipts in assets/sky/moon/receipts).
		Sky = sky({
			SkyboxBk = "rbxassetid://97347959003508",
			SkyboxDn = "rbxassetid://106152435846003",
			SkyboxFt = "rbxassetid://131817452495850",
			SkyboxLf = "rbxassetid://140592848344286",
			SkyboxRt = "rbxassetid://74950596165419",
			SkyboxUp = "rbxassetid://110439636602141",
			StarCount = 3000,
			CelestialBodiesShown = true, -- the sun shines in space (small disc, below)
			SunAngularSize = 11,
		}),
	}),
}) :: { [string]: LightingPreset }

-- Name of the client-only ColorCorrectionEffect the presets tint (created on first use).
WorldClientConfig.TintName = "WorldTint"
-- Seconds of the lighting / tint tween when a preset applies (hidden under the warp overlay).
WorldClientConfig.LightingTween = 0.6

--[[
	Music (keys = WorldDef.ambience.music). Nuke Town keeps the automatic hub / early / late /
	event contexts; Dino Valley forces the "dino" playlist (AudioConfig.Contexts.dino, W9) and,
	until that playlist exists, the cheerful hub playlist. Dino Valley also loops the soft 2D
	jungle bed (AudioConfig.Sfx.amb_jungle, W9) under the music while the player is there; it
	stops the moment they leave (spec §14 "World ambience").
]]
WorldClientConfig.Music = table.freeze({
	music_nuke_town = table.freeze({ context = nil, fallback = nil, bed = nil }) :: MusicPreset,
	music_dino_valley = table.freeze({ context = "dino", fallback = "hub", bed = "amb_jungle" }) :: MusicPreset,
	-- Moon Base (owner R70, W9b): the "moon" playlist (two APMOfficial retro-synth children's cues,
	-- SoundAssets moon_*) over H1's calm dreamy space bed (ForgeGUI `amb_space`, AudioConfig.Sfx).
	music_moon_base = table.freeze({ context = "moon", fallback = "hub", bed = "amb_space" }) :: MusicPreset,
}) :: { [string]: MusicPreset }

--[[
	Per-world physics (owner R70, spec r69 §2.4): Moon Base's low gravity. WorldGravity sets
	Workspace.Gravity = the place's default x gravityScale while the player's CurrentWorld is that
	world (restored on leave / respawn / world change); a world without a row keeps 1.
]]
WorldClientConfig.Physics = table.freeze({
	moon = table.freeze({ gravityScale = 0.4 }) :: PhysicsRow,
}) :: { [string]: PhysicsRow }

--[[
	Each world's portal look (owner R70: every world brings its own portal mesh): the WORLD
	UNLOCKED popup turns `model` (a MeshAssets key, the same mesh that stands in the lobby), shows
	`icon` while the mesh streams in, and names the world's pets with `pets`.
]]
WorldClientConfig.Portals = table.freeze({
	dino = table.freeze({ model = "Hub_TimeMachine", icon = "TimeMachine", pets = "dino pets" }) :: PortalStyle,
	moon = table.freeze({ model = "Hub_MoonRocket", icon = "MoonRocket", pets = "space pets" }) :: PortalStyle,
}) :: { [string]: PortalStyle }
--[[
	Ambience bed loop period (WorldClientLogic.ambienceBed): the bed is re-triggered every
	"track length" seconds (SoundAssets.LibrarySfx[bed].seconds); BedFallbackSeconds when the
	length is unknown. Clamped to [BedMinSeconds, BedMaxSeconds] (never a tight loop; the bed's
	own AudioConfig minInterval also guards against stacking).
]]
WorldClientConfig.BedFallbackSeconds = 60
WorldClientConfig.BedMinSeconds = 20
WorldClientConfig.BedMaxSeconds = 300
--[[
	Analytics (W12 ClientAnalytics, AnalyticsConfig.ClientFunnel.Sources): the funnel source each
	travel / popup origin reports as. "menu" = the Teleport screen, opened from the HUD; a trip
	the client did not ask for (a Time Machine portal touch / prompt) is "portal".
]]
WorldClientConfig.AnalyticsSource = table.freeze({
	menu = "hud",
	popup = "popup",
	chip = "chip",
	portal = "portal",
	auto = "auto",
}) :: { [string]: string }
-- A travel intent counts as the origin of the next "out" phase for this many seconds.
WorldClientConfig.IntentMatchSeconds = 6

--[[
	Warp overlay (UI/Screens/WorldTravel): a full-screen stud swirl with a ticking clock and the
	destination's name card. Non-interactive; Reduce Motion = a plain fade. MinSeconds is the
	shortest time it stays up (the server's "in" usually arrives ~1-1.5 s after "out");
	MaxSeconds closes it even if "in" never arrives (the server's own deadline is 4 s).
]]
WorldClientConfig.Overlay = table.freeze({
	MinSeconds = 1.2,
	MaxSeconds = 6,
	FadeSeconds = 0.35,
	SwirlTurnsPerSecond = 0.6, -- the stud swirl's rotation speed (full motion only)
	ClockTicksPerSecond = 4, -- the clock hand jumps this often
	CardPop = 1.08, -- the name card's pop-in scale
	DisplayOrder = 43, -- above windows (20-40) and the HUD, under Toasts (45) so a fail toast shows
}) :: { [string]: number }

--[[
	World tabs (Teleport, Rebirth, Welcome Back, Shop). Icons come from the icon pipeline
	(IconAssets "WorldNukeTown" / "WorldDino" / "WorldMoon"); colours are UIStyleConfig colour names.
]]
WorldClientConfig.Tabs = table.freeze({
	main = tab({
		label = "NUKE TOWN",
		short = "TOWN",
		icon = "WorldNukeTown",
		color = "blue",
		spawnLabel = "Hub",
		bonusName = "Nuke Town",
	}),
	dino = tab({
		label = "DINO VALLEY",
		short = "DINO",
		icon = "WorldDino",
		color = "green",
		spawnLabel = "Base Camp",
		bonusName = "Dino",
	}),
	-- R70 World 3 (R69–R71 spec §2.1 / §2.7): icon WorldMoon = the smiling moon tab (W1b); the
	-- Moon hub is the crater-ring Landing Plaza (§2.3).
	moon = tab({
		label = "MOON BASE",
		short = "MOON",
		icon = "WorldMoon",
		color = "purple",
		spawnLabel = "Landing Plaza",
		bonusName = "Moon",
	}),
}) :: { [string]: TabStyle }

-- Tab buttons are at least this many design px tall / wide (>= 44 pt on every device).
WorldClientConfig.TabHeight = 76
WorldClientConfig.TabMinWidth = 300

-- A world switched off by the admin kill switch (ReplicatedStorage attribute WorldEnabled_<id>).
WorldClientConfig.EnabledAttrPrefix = "WorldEnabled_"
WorldClientConfig.ClosedText = "Closed for a quick fix — back soon!"
-- The locked-world tab hint ({area} = the unlock area's name).
WorldClientConfig.LockedHint = "Reach {area} to unlock!"
WorldClientConfig.LockedProgress = "{bought} / {total} purchases"

--[[
	Friendly toast per TravelRules reason (spec §4.5 step 4). Kid-friendly, short, never blames
	the player. Every reason has a text (tests/world-client.luau).
]]
WorldClientConfig.FailText = table.freeze({
	unknownWorld = "That world isn't on the map yet!",
	badTarget = "The portal got confused. Try again!", -- world-neutral (Time Machine, Moon Rocket, ...)
	disabled = "That world is closed for a quick fix — back soon!",
	locked = "That world is still locked. Keep building to unlock it!",
	noPlot = "Your plot is still getting ready. Try again in a moment!",
	revealPending = "Hang on — your plot is still being revealed!",
	dead = "Respawn first, then hop in!",
	busy = "Already travelling — hold on tight!",
	cooldown = "The portal is recharging. Try again in a sec!",
	areaLocked = "You haven't unlocked that area yet!",
	plotEmpty = "Nobody owns that plot right now.",
	noPass = "Visiting other players' plots needs the Teleporter pass!",
}) :: { [string]: string }
WorldClientConfig.FailFallback = "The trip didn't work. Try again!"
-- Fail toasts of the same reason show at most once per this many seconds.
WorldClientConfig.FailToastGap = 2

-- Client throttle on travel intents (the server also limits: RateLimiter + 2 s cooldown).
WorldClientConfig.TravelThrottleSeconds = 1

--[[
	WORLD UNLOCKED popup (spec §4.2). Shown once per join when the server stamped `unlockedAt`
	after this session began (`JoinSlackSeconds` before the client booted counts too: a legacy
	player who already qualifies is unlocked by the server while the profile loads, just before
	the client boots). Same polite-moment gate as WHAT'S NEW.

	Owner R130 (2026-11-01 live data): the popup no longer opens by itself in the area that
	unlocked the world. Dino Valley unlocks when Nuke Town area 3 opens (~minute 14): 19 of 41
	players pressed GO NOW, landed in a fresh world at zero Bones, stayed ~2.3 min, and 15 of the
	41 never bought area 3's first pad. Now it opens once the player's Nuke Town area is
	`PopupAreasAfterUnlock` past the unlock area (Dino: area 4, Moon Base: area 6), or at once for a
	player who has rebirthed (they finished the main game — owner R57's original ask). The world
	stays unlocked meanwhile: its HUD chip, the Teleport tab and the portal all work.
	Pure rule: WorldClientLogic.unlockPopupOwed / popupArea (tests/world-client.luau).
]]
WorldClientConfig.Unlock = table.freeze({
	-- Owner R130: Nuke Town areas past the unlock area before the popup may open by itself.
	PopupAreasAfterUnlock = 1,
	JoinSlackSeconds = 90,
	CheckSeconds = 1,
	PoliteChecks = 2, -- consecutive polite checks before it opens
	WaitSeconds = 600, -- gives up after this long (the Teleport NEW dot still points the way)
	FirstCheckDelay = 2,
	Title = "WORLD UNLOCKED!",
	-- {world} = the world's name; {currency} = its currency name.
	-- {pets} = WorldClientConfig.Portals[world].pets ("dino pets", "space pets").
	Body = "{world} UNLOCKED! A whole new world with its own {currency}, {pets} and rebirths. "
		.. "Your Nuke Town keeps earning while you're away!",
	Go = "GO NOW!",
	Later = "LATER",
	LockedTitle = "LOCKED",
	-- Locked-preview mode (a locked portal): {area} name + progress.
	LockedBody = "Reach {area}: {bought} / {total} purchases",
	Ok = "OK",
	ModelKey = "Hub_TimeMachine", -- MeshAssets key of the rotating viewport model (R39)
	ModelIcon = "TimeMachine", -- icon fallback while the mesh is not uploaded
})

-- Rejoin chip (spec §4.6): "Back to Dino Valley? [GO] [X]" after the plot reveal, gamepad Y = GO.
WorldClientConfig.Rejoin = table.freeze({
	Seconds = 20,
	DelayAfterReveal = 1.5,
	Text = "Back to {world}?",
	-- Last-resort shrink when even the stacked chip does not fit between the HUD zones (the
	-- stacked layout is preferred so the 72 px buttons keep >= 44 pt on phones).
	MinScale = 0.6,
})
-- Spec name kept for the plan contract (§3.5).
WorldClientConfig.RejoinChipSeconds = 20

--[[
	HUD currency stack while in a non-main world (spec §14, owner R60): Gems | the world's
	currency (big, its colour + icon) | "+X/s <Currency>". Nuke Town's Cash is NOT shown in
	another world (R60: "it doesn't have the same money"; each world's balance shows on its
	Teleport tab). The rows stay inside HudPlacement's Top zone (TopZoneWidth x TopZoneHeight;
	tests/hud-cluster.luau).
]]
WorldClientConfig.Hud = table.freeze({
	PrimaryTextSize = 64, -- = UIStyleConfig.Hud.CashTextSize
	RateTextSize = 24,
	BottomRowHeight = 38, -- = the main rate row (RateTextSize 28 + 10)
})
--[[
	First-run objective texts (spec §14, Worlds/WorldObjectives). Placeholders: {pad} the builder
	pad, {producer} the first producer, {manager} the manager pad, {currency} the currency name.
	A world without a row uses Objectives.default.
]]
WorldClientConfig.Objectives = table.freeze({
	default = table.freeze({
		build = "Step on the green pad to build your {pad}!",
		click = "Click the {producer} to earn {currency}!",
		hire = "Hire {manager}!",
	}) :: ObjectiveTexts,
	dino = table.freeze({
		build = "Step on the green pad to build your {pad}!",
		click = "Click the bench to carve Pebble Nukes!",
		hire = "Hire {manager}!",
	}) :: ObjectiveTexts,
}) :: { [string]: ObjectiveTexts }

-- Right-column offers that join the rotation while in a world (spec §9: Time Traveler Pack; R70:
-- Astronaut Pack).
WorldClientConfig.Offers = table.freeze({
	dino = table.freeze({
		table.freeze({
			key = "TimeTraveler",
			label = "Time Traveler",
			icon = "TimeTravelerPack",
			product = "TimeTravelerPack",
			kind = "product",
			screen = "Shop",
			starter = true,
		}) :: WorldOffer,
	}),
	-- R70 World 3 (R69–R71 spec §2.6): the Astronaut Pack joins the rotation while in Moon Base.
	moon = table.freeze({
		table.freeze({
			key = "Astronaut",
			label = "Astronaut",
			icon = "AstronautPack",
			product = "AstronautPack",
			kind = "product",
			screen = "Shop",
			starter = true,
		}) :: WorldOffer,
	}),
}) :: { [string]: { WorldOffer } }

return table.freeze(WorldClientConfig)
