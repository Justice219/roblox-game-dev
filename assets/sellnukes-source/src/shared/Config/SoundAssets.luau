--!strict
--[[
	SoundAssets — every audio asset id SellNukes plays, with provenance + licence notes.

	MUSIC — Roblox's licensed APM Music library, published on the Creator Store by the verified
	`APMOfficial` account (userId 7462718749): every track below is free (price 0) and licensed by
	Roblox for use in ANY Roblox experience ("Courtesy of APM Music" in each asset description).
	Each id, title, artist/library and the free + verified status was checked with the Studio MCP
	`get_asset_details` on 2026-10-30. Never add a track whose creator is not APMOfficial (or another
	Roblox-licensed library account) — user uploads can be taken down or carry rights claims.

	SFX — original sounds synthesised by tools/audio/generate_{world,game}_sfx.py and uploaded by
	the SellNukes owner (user 1586034782) through tools/audio/upload_sfx.py; the id block below is
	generated from hash-bound receipts (0 = not uploaded yet -> that key is silent).

	Playback rules (groups, volumes, pitch variation, 3D, pooling) live in AudioConfig.
	API: src/client/Audio/Sound.luau (`Sound.play(key, opts)`), music by SoundController.
]]

export type Track = {
	id: number,
	title: string,
	artist: string, -- APM library / composer credit as listed on the asset
	album: string,
	seconds: number,
	note: string,
}

local SoundAssets = {}

-- Licence statement shared by every MUSIC entry.
SoundAssets.MusicLicence = "Roblox-licensed APM Music library (Creator Store, verified APMOfficial, free): "
	.. "usable in any Roblox experience; credit 'Courtesy of APM Music'."

local MUSIC: { [string]: Track } = {
	hub_sparkling = {
		id = 9039448076,
		title = "Sparkling Clean",
		artist = "Hard",
		album = "Ad Delight",
		seconds = 110,
		note = "lighthearted bright acoustic pop — hub / lobby",
	},
	hub_carefree = {
		id = 9040129352,
		title = "Carefree Living (Main Instrumental)",
		artist = "Kosinus",
		album = "Life Is Beautiful 2",
		seconds = 103,
		note = "cheerful banjo + accordion family pop — hub / lobby",
	},
	early_funtime = {
		id = 9043423222,
		title = "Funtime Festival (a)",
		artist = "Jump",
		album = "Funtime Folky",
		seconds = 138,
		note = "perky playful piano + recorder — areas 1-4",
	},
	early_shenanigans = {
		id = 9045709422,
		title = "Summer Shenanigans",
		artist = "Kosinus",
		album = "Latin Family Comedy",
		seconds = 94,
		note = "whimsical kids-TV ukulele / tuba / mallets — areas 1-4",
	},
	late_upforanything = {
		id = 9038916053,
		title = "Up For Anything (Alt2, NoShouts)",
		artist = "Spot On",
		album = "Positive Vibes 4",
		seconds = 129,
		note = "upbeat energetic electro pop, no vocal shouts — areas 5-10",
	},
	late_funky = {
		id = 9045108886,
		title = "Funky Escapade",
		artist = "Spot On",
		album = "LOL 2",
		seconds = 128,
		note = "quirky groovy funk — areas 5-10",
	},
	event_romp = {
		id = 9045110540,
		title = "Country Romp",
		artist = "Spot On",
		album = "LOL 2",
		seconds = 111,
		note = "comedy bluegrass banjo hoedown — Harvest Feast event",
	},
	event_goodtimes = {
		id = 9039994105,
		title = "Good Times Ahead (Instrumental)",
		artist = "Bruton TV Series",
		album = "Ukulele Whistling",
		seconds = 132,
		note = "sun-kissed ukulele folk — Harvest Feast event",
	},
	rebirth_sting = {
		id = 9040102630,
		title = "Sends Us Soaring (d)",
		artist = "Jump",
		album = "Sends Us Soaring",
		seconds = 8,
		note = "short triumphant indie sting — rebirth fanfare",
	},
	-- Dino Valley (owner R57, W9; AudioConfig.Contexts.dino, WorldClientConfig "music_dino_valley").
	-- Both checked with get_asset_details 2026-10-30: APMOfficial (user 7462718749, verified), free.
	dino_adventure = {
		id = 1838632983,
		title = "Kids Adventure",
		artist = "Kaptain",
		album = "ADVENTURES GATE",
		seconds = 104,
		note = "storybook orchestral, determined + fun (xylophone, glockenspiel, flute) — Dino Valley",
	},
	dino_tiki = {
		id = 1838898404,
		title = "Tiki March",
		artist = "Lionel Wendling",
		album = "HAWAIIAN GUITAR",
		seconds = 78,
		note = "kitsch Hawaiian-guitar march, sunny jungle-island feel — Dino Valley",
	},
	-- Moon Base (owner R70, W9b; AudioConfig.Contexts.moon, WorldClientConfig "music_moon_base").
	-- Both checked with get_asset_details 2026-10-31: APMOfficial (user 7462718749, verified), free,
	-- audioType Music, genre "children" (the album is a set of playful retro-synth cues).
	moon_strange_planet = {
		id = 1836774489,
		title = "Strange Planet",
		artist = "John Baker",
		album = "QUIRKY RETRO TECH",
		seconds = 94,
		note = "quirky retro-synth children's cue, bleepy and curious — Moon Base",
	},
	moon_friendly_robot = {
		id = 1836774293,
		title = "Friendly Robot",
		artist = "Johnny Pearson",
		album = "QUIRKY RETRO TECH",
		seconds = 131,
		note = "cheerful bouncy robot tune, retro synths — Moon Base",
	},
}
SoundAssets.Music = MUSIC

-- BEGIN GENERATED SFX IDS (tools/audio/upload_sfx.py)
local SFX_IDS: { [string]: number } = {
	amb_space = 90782420974296,
	cash_big = 135851880365086,
	cash_medium = 86179728263964,
	cash_small = 88440810605155,
	clack = 90679986310786,
	coin_burst = 84534789524525,
	combo_tick = 106829999344174,
	crate_open = 109340834001878,
	dino_happy_roar = 102465691617590,
	fanfare = 126010595327928,
	firework_pop = 129861968358589,
	firework_whistle = 105453621071596,
	geyser_whoosh = 134127936413315,
	hatch = 112859854857002,
	kaching = 81755934500547,
	lucky_blink = 79502180862059,
	lucky_claim = 133028852626089,
	lucky_spawn = 111096596665803,
	manager_hired = 115776697858457,
	milestone = 116620689324273,
	moon_boing = 119119944802449,
	notification = 103454202365560,
	nuke_boom = 136626566410583,
	nuke_launch = 122870118383187,
	nuke_whoosh = 95991955109241,
	pad_buy = 110783497080402,
	pick_clink = 100562593762437,
	pop = 113120514061985,
	producer_pop = 121810135386274,
	ptero_squawk_cute = 81157147553029,
	robot_beep = 125340984870125,
	rocket_launch_soft = 97164005981484,
	sparkle = 96716830629202,
	star_chime = 96146923484942,
	turkey_gobble = 72616868914767,
	ufo_whirr = 140470364099037,
	ui_claim = 98892080333897,
	ui_click = 85937564553902,
	ui_close = 82963812551447,
	ui_hover = 99742459018578,
	ui_locked = 132539408448258,
	ui_open = 131355904311837,
	upgrade = 120859570642502,
	vehicle_beep = 116659155138913,
	vehicle_honk = 91980602046494,
	vo_direct_hit = 103450362500468,
	vo_intercepted = 118660432028997,
	vo_knockdown = 138096328499105,
	vo_launch = 70608701750645,
	vo_one = 134441894996637,
	vo_three = 138051997456501,
	vo_two = 135237700642650,
	volcano_rumble_soft = 109933791077689,
	warp_whoosh = 107196971815834,
	whoosh = 93061351246667,
}
-- END GENERATED SFX IDS

--[[
	Roblox-licensed LIBRARY sound effects (not synthesised, so not in the generated block above,
	which upload_sfx.py rewrites; these lines sit after its END marker and survive). Same rule as
	MUSIC: only verified Roblox-licensed library accounts. Provenance in SoundAssets.LibrarySfx.
]]
local LIBRARY_SFX: { [string]: Track } = {
	-- Dino Valley ambience bed (owner R57, W9): checked with get_asset_details 2026-10-30 —
	-- ProSoundEffects (user 7462895450, verified), free, "Courtesy of Pro Sound Effects".
	amb_jungle = {
		id = 9114891241,
		title = "Jungle Ambience 4 (SFX)",
		artist = "Pro Sound Effects",
		album = "Ambience - Jungle",
		seconds = 69,
		note = "day jungle bed: light insects, warbler, chirps, whistles (no predators, no screams)",
	},
}
for key, track in LIBRARY_SFX do
	SFX_IDS[key] = track.id
end
SoundAssets.LibrarySfx = LIBRARY_SFX

-- Synthesised SFX asset ids by key (0 = not uploaded -> silent).
SoundAssets.SfxIds = SFX_IDS

return SoundAssets
