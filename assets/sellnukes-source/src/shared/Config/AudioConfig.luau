--!strict
--[[
	AudioConfig — how SellNukes plays sound: SoundGroups, every SFX key's playback rules, music
	contexts and their playlists. Asset ids + licences live in SoundAssets.

	Consumers: src/client/Audio/Sound.luau (`Sound.play(key, opts)` — the ONE API every system
	calls), src/client/Audio/SoundController.luau (music by context, stings, settings).

	SFX spec fields:
		group        "SFX" (world / gameplay) or "UI" (menus) — both muted by settings.sfx = false
		volume       0..1 before the group volume
		pitchVar     random ±fraction of pitch per play (variation keeps repeats from grating)
		voices       2D voices pooled for this key (oldest voice is re-used when all are busy)
		minInterval  seconds; a second play of the same key inside it is dropped (no stacking buzz)
		preload      hot sound: preloaded at boot (everything else streams on first use)
		range        RollOffMaxDistance when played in 3D (a `position` was given)
	Mobile / console (owner R11): only `preload` keys are fetched up front; music uses at most two
	Sound instances (crossfade) + one sting, never more.

	Example:
		Sound.play("ui_click")
		Sound.play("cash_big", { position = padPosition })
]]

export type SfxSpec = {
	group: "SFX" | "UI",
	volume: number,
	pitchVar: number?,
	voices: number?,
	minInterval: number?,
	preload: boolean?,
	range: number?,
}

local AudioConfig = {}

-- SoundGroup volumes (created under SoundService by Sound.ensure()).
AudioConfig.Groups = {
	Music = 0.4,
	SFX = 0.85,
	UI = 0.7,
} :: { [string]: number }

local SFX: { [string]: SfxSpec } = {
	-- UI (2D)
	ui_click = { group = "UI", volume = 0.55, pitchVar = 0.05, voices = 3, minInterval = 0.03, preload = true },
	ui_hover = { group = "UI", volume = 0.3, pitchVar = 0.04, voices = 2, minInterval = 0.06, preload = true },
	ui_open = { group = "UI", volume = 0.5, pitchVar = 0.03, voices = 2, minInterval = 0.08, preload = true },
	ui_close = { group = "UI", volume = 0.45, pitchVar = 0.03, voices = 2, minInterval = 0.08, preload = true },
	ui_claim = { group = "UI", volume = 0.6, pitchVar = 0.02, voices = 2, minInterval = 0.1 },
	ui_locked = { group = "UI", volume = 0.5, pitchVar = 0.02, voices = 1, minInterval = 0.15 },
	notification = { group = "UI", volume = 0.55, voices = 1, minInterval = 0.25 },
	-- Cash (2D for your own income; 3D when a position is given)
	cash_small = {
		group = "SFX",
		volume = 0.45,
		pitchVar = 0.08,
		voices = 3,
		minInterval = 0.05,
		preload = true,
		range = 90,
	},
	cash_medium = { group = "SFX", volume = 0.55, pitchVar = 0.06, voices = 2, minInterval = 0.08, range = 110 },
	cash_big = { group = "SFX", volume = 0.65, pitchVar = 0.03, voices = 2, minInterval = 0.2, range = 140 },
	-- Progression
	producer_pop = {
		group = "SFX",
		volume = 0.4,
		pitchVar = 0.1,
		voices = 3,
		minInterval = 0.05,
		preload = true,
		range = 80,
	},
	upgrade = {
		group = "SFX",
		volume = 0.55,
		pitchVar = 0.02,
		voices = 2,
		minInterval = 0.08,
		preload = true,
		range = 100,
	},
	manager_hired = { group = "SFX", volume = 0.65, voices = 1, minInterval = 0.5, range = 140 },
	-- Eggs / crates
	hatch = { group = "SFX", volume = 0.65, voices = 1, minInterval = 0.3, range = 100 },
	crate_open = { group = "SFX", volume = 0.6, pitchVar = 0.03, voices = 1, minInterval = 0.3, range = 100 },
	-- Cartoon nukes (attack mode)
	nuke_launch = { group = "SFX", volume = 0.6, pitchVar = 0.05, voices = 2, minInterval = 0.15, range = 220 },
	nuke_whoosh = { group = "SFX", volume = 0.45, pitchVar = 0.06, voices = 3, minInterval = 0.1, range = 200 },
	nuke_boom = { group = "SFX", volume = 0.7, pitchVar = 0.06, voices = 3, minInterval = 0.12, range = 260 },
	-- Announcer voice lines (owner R54; set `voice`, ForgeGUI/ElevenLabs takes checked with whisper):
	-- the launch countdown "3, 2, 1, LAUNCH!" and the result call-outs, played 2D (no position) by
	-- the launch cinematic for the LOCAL player's own launches. One voice each, no pitch variation
	-- (a pitched voice sounds wrong). NOT in the join-time preload set (tests/audio caps it): the
	-- cinematic calls Sound.warm({ "vo_three", ... }) when the attack picker opens, so the countdown
	-- never waits on a fetch. Example: Sound.play("vo_three")
	vo_three = { group = "SFX", volume = 0.85, voices = 1, minInterval = 0.4 },
	vo_two = { group = "SFX", volume = 0.85, voices = 1, minInterval = 0.4 },
	vo_one = { group = "SFX", volume = 0.85, voices = 1, minInterval = 0.4 },
	vo_launch = { group = "SFX", volume = 0.9, voices = 1, minInterval = 0.4 },
	vo_direct_hit = { group = "SFX", volume = 0.85, voices = 1, minInterval = 0.8 },
	vo_intercepted = { group = "SFX", volume = 0.85, voices = 1, minInterval = 0.8 },
	vo_knockdown = { group = "SFX", volume = 0.85, voices = 1, minInterval = 0.8 },
	-- Event
	turkey_gobble = { group = "SFX", volume = 0.6, pitchVar = 0.12, voices = 2, minInterval = 0.4, range = 120 },
	-- Build-in + world FX (WorldFx / BuildIn controllers via FxSound)
	clack = { group = "SFX", volume = 0.55, voices = 3, minInterval = 0.045, preload = true, range = 160 },
	whoosh = { group = "SFX", volume = 0.25, pitchVar = 0.05, voices = 2, minInterval = 0.1, range = 160 },
	sparkle = {
		group = "SFX",
		volume = 0.6,
		pitchVar = 0.03,
		voices = 2,
		minInterval = 0.1,
		preload = true,
		range = 180,
	},
	kaching = {
		group = "SFX",
		volume = 0.7,
		pitchVar = 0.03,
		voices = 2,
		minInterval = 0.1,
		preload = true,
		range = 160,
	},
	pop = { group = "SFX", volume = 0.5, pitchVar = 0.08, voices = 2, minInterval = 0.05, range = 140 },
	-- Map vehicles (owner R56, Tycoon/Fx/VehicleRoutes; set `forge`, ForgeGUI takes picked by
	-- measured burst count): the toy truck's "honk-honk" and the soft reversing beeper played at
	-- the vehicle (3D, short range so a busy plot never becomes noisy; minInterval stops stacking).
	-- Example: Sound.play("vehicle_honk", { position = van:GetPivot().Position })
	vehicle_honk = { group = "SFX", volume = 0.5, pitchVar = 0.06, voices = 2, minInterval = 0.6, range = 140 },
	vehicle_beep = { group = "SFX", volume = 0.35, voices = 2, minInterval = 0.5, range = 100 },
	fanfare = { group = "SFX", volume = 0.65, voices = 1, minInterval = 1, range = 400 },
	-- Dino Valley (owner R57, W9): the jungle ambience bed (Roblox-licensed Pro Sound Effects, 69 s;
	-- SoundAssets.LibrarySfx). Played 2D and soft while the player is in the Valley; one voice, and
	-- minInterval keeps a re-trigger from stacking before the bed ends.
	-- Example: Sound.play("amb_jungle")
	amb_jungle = { group = "SFX", volume = 0.22, voices = 1, minInterval = 60 },
	-- Dino Valley one-shots (owner R57; set `forge`, ForgeGUI takes screened with whisper so no
	-- words slip in). Specs as W9-valley requested; ptero + volcano are 3D, pass a position.
	-- Example: Sound.play("dino_happy_roar", { position = manager.Head.Position })
	ptero_squawk_cute = { group = "SFX", volume = 0.45, pitchVar = 0.12, voices = 2, minInterval = 0.8, range = 140 },
	dino_happy_roar = { group = "SFX", volume = 0.55, pitchVar = 0.08, voices = 2, minInterval = 0.6, range = 160 },
	volcano_rumble_soft = { group = "SFX", volume = 0.5, voices = 1, minInterval = 2, range = 400 },
	-- Real recordings replacing the earlier whoosh aliases: play at natural pitch (no pitch override).
	warp_whoosh = { group = "SFX", volume = 0.6, voices = 1, minInterval = 0.5, range = 200 },
	geyser_whoosh = { group = "SFX", volume = 0.5, pitchVar = 0.06, voices = 2, minInterval = 0.4, range = 160 },
	-- Juice pass (owner R71, H1; set `forge` = ForgeGUI takes picked by measurement + whisper no-words
	-- check, provenance in assets/audio/forge-sfx/manifest.json; firework_whistle is synthesised in
	-- the `game` set because every ForgeGUI take fell in pitch). docs/audio.md §8, docs/juice.md.
	-- The click ladder: 2D, NO random pitch (ClickCombo sets 1.0 -> 1.6 per press); 4 voices so
	-- fast presses never cut each other. Example: Sound.play("combo_tick", { pitch = 1.26 })
	combo_tick = { group = "SFX", volume = 0.55, voices = 4, minInterval = 0.03 },
	-- Combo 25 / 50 / 100 bursts (2D). Example: Sound.play("coin_burst")
	coin_burst = { group = "SFX", volume = 0.6, pitchVar = 0.04, voices = 2, minInterval = 0.2 },
	-- The layered purchase pop at the pad (3D; replaces "pop" there). Example:
	-- Sound.play("pad_buy", { position = pad:GetPivot().Position })
	pad_buy = { group = "SFX", volume = 0.6, pitchVar = 0.04, voices = 3, minInterval = 0.08, range = 140 },
	-- Producer milestone banner ding (2D). Example: Sound.play("milestone")
	milestone = { group = "UI", volume = 0.7, voices = 1, minInterval = 0.4 },
	-- Toy fireworks (3D per rocket; several rockets per show, so 3-4 voices + small gaps).
	-- Example: Sound.play("firework_pop", { position = apex })
	firework_whistle = { group = "SFX", volume = 0.45, pitchVar = 0.08, voices = 3, minInterval = 0.08, range = 300 },
	firework_pop = { group = "SFX", volume = 0.6, pitchVar = 0.1, voices = 4, minInterval = 0.06, range = 300 },
	-- Lucky Buttons (owner R69, H3): pop-up "ding-ding-ding", claim jingle and the soft last-seconds
	-- blink tick (~1/s); all three play 3D at the button (2D also works).
	-- Example: Sound.play("lucky_spawn", { position = button.Position })
	lucky_spawn = { group = "SFX", volume = 0.65, voices = 2, minInterval = 0.5, range = 160 },
	lucky_claim = { group = "SFX", volume = 0.7, voices = 2, minInterval = 0.3, range = 120 },
	lucky_blink = { group = "SFX", volume = 0.3, voices = 2, minInterval = 0.4, range = 80 },
	-- Moon Base (owner R70): the low-gravity landing boing (2D, your own character; the source is
	-- quiet, hence the high volume), the space ambience bed (2D, 30 s loop, re-triggered like
	-- amb_jungle) and 3D world one-shots for art ambience / managers / vehicles.
	-- Example: Sound.play("moon_boing", { pitch = 1.1 }); Sound.play("ufo_whirr", { position = p })
	moon_boing = { group = "SFX", volume = 0.8, pitchVar = 0.06, voices = 2, minInterval = 0.35 },
	amb_space = { group = "SFX", volume = 0.2, voices = 1, minInterval = 30 },
	ufo_whirr = { group = "SFX", volume = 0.45, pitchVar = 0.08, voices = 2, minInterval = 1.5, range = 140 },
	robot_beep = { group = "SFX", volume = 0.45, pitchVar = 0.1, voices = 2, minInterval = 0.6, range = 120 },
	star_chime = { group = "SFX", volume = 0.45, pitchVar = 0.05, voices = 2, minInterval = 1, range = 160 },
	rocket_launch_soft = { group = "SFX", volume = 0.55, voices = 1, minInterval = 2, range = 220 },
	-- Glow Rock miners' pickaxe strike (owner R75, W7; set `forge`, one-hit "tok-tink" trimmed to
	-- 0.17 s): 3D at the swing's impact, short range so a busy mine stays calm.
	-- Example: Sound.play("pick_clink", { position = pickTip.WorldPosition })
	pick_clink = { group = "SFX", volume = 0.5, pitchVar = 0.08, voices = 3, minInterval = 0.25, range = 60 },
}
AudioConfig.Sfx = SFX

-- Friendly names other systems may use; resolved before lookup.
local ALIASES: { [string]: string } = {
	area_unlock = "fanfare",
	build_clack = "clack",
	purchase = "kaching",
	-- Dino Valley (owner R57, W9) reusing an existing sound; callers pass the pitch that sells it:
	--   Sound.play("bones_pickup", { pitch = 1.25, volume = 0.35 })      -- Bones landing on the HUD
	-- (warp_whoosh / geyser_whoosh are real recordings now, see AudioConfig.Sfx.)
	bones_pickup = "cash_small",
	-- Lucky Wheel ticker (owner R81, W-wheel): one tick per rim peg passing the flapper. Plays the
	-- trimmed one-hit click (combo_tick: 2D, no random pitch, 4 voices); LuckyWheelFxConfig.Tick sets
	-- pitch + volume from the disc speed. Replace with a dedicated sound by deleting this line.
	--   Sound.play("wheel_tick", { pitch = 1.3, volume = 1 })
	wheel_tick = "combo_tick",
}
AudioConfig.Aliases = ALIASES

-- Pooled 3D emitters (Attachments under Workspace.Terrain).
AudioConfig.Emitters3D = 8

-- Music contexts -> playlists of SoundAssets.Music keys (played in order, looping the list).
local CONTEXTS: { [string]: { string } } = {
	hub = { "hub_sparkling", "hub_carefree" },
	early = { "early_funtime", "early_shenanigans" },
	late = { "late_upforanything", "late_funky" },
	event = { "event_romp", "event_goodtimes" },
	-- Dino Valley (owner R57): WorldClientConfig "music_dino_valley" -> context "dino" (W5 sets it
	-- with SoundController.setOverride while the player is in the Valley).
	dino = { "dino_adventure", "dino_tiki" },
	-- Moon Base (owner R70): WorldClientConfig "music_moon_base" -> context "moon" (APMOfficial
	-- "Strange Planet" + "Friendly Robot", SoundAssets.Music; the amb_space bed plays under it).
	moon = { "moon_strange_planet", "moon_friendly_robot" },
}
AudioConfig.Contexts = CONTEXTS

-- Short one-shot music cues (duck the current track while they play).
local STINGS: { [string]: string } = {
	rebirth = "rebirth_sting",
}
AudioConfig.Stings = STINGS

AudioConfig.Music = {
	Volume = 0.6, -- track volume inside the Music group
	Crossfade = 2.2, -- seconds
	ContextCheck = 1.0, -- seconds between "where is the player?" checks (never per frame)
	HubPadding = 30, -- studs beyond WorldLayout.HubRadius still counted as the hub
	EarlyRows = 2, -- plot rows 1..2 (areas 1-4) play the "early" playlist, deeper rows "late"
	DuckVolume = 0.2, -- music volume factor while a sting plays
	DuckFade = 0.35,
	StingVolume = 0.8,
}

return AudioConfig
