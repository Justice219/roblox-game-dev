--!strict
--[[
	LobbyNpcConfig — the lobby visitors (owner R100: "The lobby feels a little dead, maybe have some
	random roblox npcs like r15 rigs just walk around and talk and stuff").

	What it is:
		8-12 client-side R15 visitors stroll the Nuke Town lobby walkways (HubLayout.lobbyWalk graph:
		the fountain walk, the plot paths, the avenues and the feature fronts), stop to look at the
		egg stands / Lucky Wheel / leaderboards, sit on benches, wave at a nearby player and say
		short kid-friendly lines in stud speech bubbles. Purely cosmetic: nothing here touches the
		economy, and the server never simulates them.

	Rigs: the SERVER builds one template per `Presets` row ONCE at boot with
	Players:CreateHumanoidModelFromDescriptionAsync (HumanoidDescription: classic shirt / pants,
	hair / hat / face accessories, face, body colours — only Roblox-made catalog items, verified by
	MarketplaceService:GetProductInfo on 2026-10-31: creator Roblox (1), right asset type). They are
	PRESET outfits — never a real player's avatar. Templates sit in ReplicatedStorage
	(Server/World/LobbyNpcService); clients clone them into a client-only folder.

	Animations: Roblox's own default R15 animations (creator Roblox, asset type Animation, verified
	the same way): walk, idle (+ look-around / yawn variants), sit, wave, cheer, point, laugh.

	Performance (owner R11, console + mobile first): Tiers by Tycoon/Fx/FxQuality — how many visitors
	exist, how far they animate (`Range`), and whether they cast shadows. One Heartbeat loop for all
	of them (Client/Lobby/LobbyController), BulkMoveTo of anchored root parts, no per-frame
	Instance.new, pooled bubbles, only while the player is in Nuke Town.

	Kid-safe rules: lines are upbeat, about the game's own features, no real people / brands /
	weapons words, <= Bubble.MaxChars characters (tests/lobby.luau checks length + uniqueness).

	Who reads it:
		- Server/World/LobbyNpcService (Presets → templates, admin LobbyNpcs toggle)
		- Client/Lobby/{LobbyNpcs, LobbyNpcLogic, LobbyBubbles, LobbyController}
		- tests/lobby.luau

	Usage:
		local LobbyNpcConfig = require(ReplicatedStorage.Shared.Config.LobbyNpcConfig)
		local tier = LobbyNpcConfig.Tiers[FxQuality.tier()] --> { Count = 9, Range = 150, ... }
]]

-- One preset outfit (HumanoidDescription fields; 0 / "" = none). Asset ids are Roblox-made catalog
-- items (see header). Colours are the body colours (skin + any limb not covered by clothing).
export type Preset = {
	id: string,
	skin: Color3,
	shirt: number,
	pants: number,
	face: number,
	hair: { number },
	hats: { number },
	faceAccessories: { number },
	-- Optional colours for the torso / legs when no shirt / pants covers them (toy-brick look).
	torsoColor: Color3?,
	legColor: Color3?,
}

export type Tier = {
	Count: number, -- visitors that exist while the player is in Nuke Town
	Range: number, -- studs from the camera within which a visitor is shown + animated
	CastShadow: boolean,
	Bubbles: number, -- most speech bubbles at once
}

local LobbyNpcConfig = {}

-- Template folder in ReplicatedStorage (server-built) and its "ready" attribute.
LobbyNpcConfig.TemplateFolder = "LobbyNpcTemplates"
LobbyNpcConfig.ReadyAttribute = "Ready"
-- ReplicatedStorage attribute: false = the admin turned the visitors off on this server.
LobbyNpcConfig.EnabledAttribute = "LobbyNpcsEnabled"
-- Client-only workspace folder the visitors are cloned into.
LobbyNpcConfig.ClientFolder = "LobbyVisitors"

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Skin tones (a friendly mix) — picked per preset below.
local SKIN = {
	rgb(255, 204, 153),
	rgb(234, 184, 146),
	rgb(204, 142, 105),
	rgb(160, 102, 72),
	rgb(124, 82, 58),
	rgb(255, 220, 178),
}

-- Verified Roblox-made catalog ids (GetProductInfo 2026-10-31).
local SHIRT = {
	jersey = 382538059, -- Green Jersey
	teal = 382537702, -- Teal Shirt
	plaid = 398635081, -- Blue Plaid Shirt
	moto = 144076358, -- Blue and Black Motorcycle Shirt
	pizza = 4047884939, -- My Favorite Pizza Shirt
	purpleTeal = 4047886060, -- Purple and Teal Top
	guitar = 382538295, -- Guitar Tee with Black Jacket
	denim = 398633584, -- Denim Jacket with White Hoodie
	jacket = 607785314, -- ROBLOX Jacket
}
local PANTS = {
	greenJeans = 144076760, -- Dark Green Jeans
	blackJeans = 382537569, -- Black Jeans
	sneakers = 382538503, -- Black Jeans with Sneakers
	skater = 398635338, -- Ripped Skater Pants
}
local HAIR = {
	pal = 63690008, -- Pal Hair
	lavender = 451220849, -- Lavender Updo
	charmer = 376548738, -- Brown Charmer Hair
	bun = 62724852, -- Chestnut Bun
	brown = 62234425, -- Brown Hair
	girl = 48474294, -- ROBLOX Girl - Hair
	classic = 4637267557, -- Classic Female v2 - Hair
	ponytail = 376527350, -- Black Ponytail
	blue = 451221329, -- True Blue Hair
}
local HAT = {
	cap = 607702162, -- Roblox Baseball Cap
	redCap = 48474313, -- Red Roblox Cap
	robox = 4819740796, -- Robox
	duck = 9254254, -- Rubber Duckie
	plaid = 102611803, -- Verified, Bonafide, Plaidafied
}
local FACE_ACC = {
	shades = 376527500, -- Orange Shades
}
local FACE = {
	smile = 144075659, -- Smile
	chill = 7074764, -- Chill
	silly = 7699174, -- Silly Fun
}

--[[
	Twelve preset outfits (the most a High tier spawns). Order = spawn order, so the Low tier's six
	are already a varied crowd. Each template is built once on the server.
]]
LobbyNpcConfig.Presets = table.freeze({
	{
		id = "Sporty",
		skin = SKIN[1],
		shirt = SHIRT.jersey,
		pants = PANTS.sneakers,
		face = FACE.smile,
		hair = { HAIR.pal },
		hats = { HAT.redCap },
		faceAccessories = {},
	},
	{
		id = "Artist",
		skin = SKIN[4],
		shirt = SHIRT.purpleTeal,
		pants = PANTS.blackJeans,
		face = FACE.smile,
		hair = { HAIR.lavender },
		hats = {},
		faceAccessories = {},
	},
	{
		id = "Skater",
		skin = SKIN[3],
		shirt = SHIRT.denim,
		pants = PANTS.skater,
		face = FACE.chill,
		hair = { HAIR.charmer },
		hats = {},
		faceAccessories = { FACE_ACC.shades },
	},
	{
		id = "Pizza",
		skin = SKIN[2],
		shirt = SHIRT.pizza,
		pants = PANTS.greenJeans,
		face = FACE.silly,
		hair = { HAIR.bun },
		hats = {},
		faceAccessories = {},
	},
	{
		id = "Rocker",
		skin = SKIN[5],
		shirt = SHIRT.guitar,
		pants = PANTS.blackJeans,
		face = FACE.chill,
		hair = { HAIR.brown },
		hats = { HAT.cap },
		faceAccessories = {},
	},
	{
		id = "Explorer",
		skin = SKIN[6],
		shirt = SHIRT.plaid,
		pants = PANTS.sneakers,
		face = FACE.smile,
		hair = { HAIR.ponytail },
		hats = {},
		faceAccessories = {},
	},
	{
		id = "Builder",
		skin = SKIN[1],
		shirt = 0,
		pants = 0,
		face = FACE.smile,
		hair = {},
		hats = { HAT.robox },
		faceAccessories = {},
		torsoColor = rgb(255, 196, 40),
		legColor = rgb(60, 110, 200),
	},
	{
		id = "Racer",
		skin = SKIN[3],
		shirt = SHIRT.moto,
		pants = PANTS.blackJeans,
		face = FACE.smile,
		hair = { HAIR.blue },
		hats = {},
		faceAccessories = { FACE_ACC.shades },
	},
	{
		id = "Duck",
		skin = SKIN[2],
		shirt = SHIRT.teal,
		pants = PANTS.greenJeans,
		face = FACE.silly,
		hair = { HAIR.classic },
		hats = { HAT.duck },
		faceAccessories = {},
	},
	{
		id = "Classic",
		skin = SKIN[4],
		shirt = SHIRT.jacket,
		pants = PANTS.sneakers,
		face = FACE.smile,
		hair = { HAIR.girl },
		hats = {},
		faceAccessories = {},
	},
	{
		id = "Plaid",
		skin = SKIN[6],
		shirt = SHIRT.jersey,
		pants = PANTS.skater,
		face = FACE.chill,
		hair = {},
		hats = { HAT.plaid },
		faceAccessories = {},
	},
	{
		id = "Mint",
		skin = SKIN[5],
		shirt = 0,
		pants = PANTS.greenJeans,
		face = FACE.smile,
		hair = { HAIR.ponytail },
		hats = {},
		faceAccessories = {},
		torsoColor = rgb(110, 222, 170),
	},
} :: { Preset })

-- Budget per FxQuality tier (Tycoon/Fx/FxQuality: Low = phones / low quality).
LobbyNpcConfig.Tiers = table.freeze({
	Low = table.freeze({ Count = 6, Range = 110, CastShadow = false, Bubbles = 1 }),
	Mid = table.freeze({ Count = 9, Range = 150, CastShadow = false, Bubbles = 2 }),
	High = table.freeze({ Count = 12, Range = 190, CastShadow = true, Bubbles = 2 }),
} :: { [string]: Tier })

-- Seconds between culling / ranking passes (distance, world, tier, enable flag).
LobbyNpcConfig.RefreshInterval = 0.5
-- Extra studs past Range before a shown visitor is hidden again (no flicker at the edge).
LobbyNpcConfig.RangeHysteresis = 12

-- Default R15 animations (Roblox-made; verified 2026-10-31).
LobbyNpcConfig.Animations = table.freeze({
	walk = "rbxassetid://507777826", -- R15Walk
	idle = "rbxassetid://507766388", -- R15Idle
	look = "rbxassetid://507766666", -- R15IdleLookAround (idle variant)
	yawn = "rbxassetid://507766951", -- R15IdleYawn (idle variant)
	sit = "rbxassetid://2506281703", -- SitV2
	wave = "rbxassetid://507770239", -- R15Wave
	cheer = "rbxassetid://507770677", -- R15Cheer
	point = "rbxassetid://507770453", -- R15Point
	laugh = "rbxassetid://507770818", -- R15Laugh
})
-- Walk speed (studs/s) at which the R15 walk animation plays at speed 1 (Roblox's Animate script
-- normalises the walk clip to ~6.4 studs/s at the default scale).
LobbyNpcConfig.WalkAnimStudsPerSecond = 6.4

--[[
	Brain tunables (Client/Lobby/LobbyNpcLogic). Times in seconds, speeds in studs/s, angles in
	degrees per second.
]]
LobbyNpcConfig.Brain = table.freeze({
	WalkSpeedMin = 6.5, -- players walk 16+, visitors stroll
	WalkSpeedMax = 9,
	TurnSpeed = 300, -- deg/s toward the walking direction / the look target
	IdleMin = 2.5, -- a stop at a node with something to look at
	IdleMax = 7,
	SitMin = 10,
	SitMax = 22,
	SitChance = 0.3, -- at a node with a free seat
	SitCooldown = 40, -- a visitor that just sat walks a while first
	SitBlend = 0.45, -- seconds to slide onto / off the seat
	EmoteChance = 0.35, -- an idle stop at a feature: cheer / point / laugh
	WaveRange = 11, -- the local player passing this close may get a wave ...
	WaveChance = 0.6, -- ... with this chance (checked once per approach) ...
	WaveCooldown = 25, -- ... at most once per this many seconds per visitor
	MaxStep = 0.1, -- a frame hitch is simulated in steps of at most this (no teleporting)
})

-- Root height above the floor while sitting (studs above the seat top), and the seat-relative
-- offset back onto the bench (the SitV2 pose puts the hips over the seat).
LobbyNpcConfig.SitRootHeight = 1.25

--[[
	Speech bubbles (Client/Lobby/LobbyBubbles + LobbyNpcLogic.pickSpeaker): every IntervalMin..Max
	seconds ONE visitor within NearRange of the player says a line for ShowSeconds; never the same
	line twice within RecentLines picks.
]]
LobbyNpcConfig.Bubble = table.freeze({
	IntervalMin = 5,
	IntervalMax = 11,
	FirstDelay = 3,
	ShowSeconds = 4.5,
	NearRange = 48,
	MaxDistance = 70, -- engine cull distance of a bubble billboard
	RecentLines = 8,
	MaxChars = 34,
	HeadGap = 1.6, -- studs above the head piece's centre
	StudsWidthBase = 1.2,
	StudsWidthPerChar = 0.16,
	StudsHeight = 1.5,
	PixelWidthBase = 40,
	PixelWidthPerChar = 6.4,
	PixelHeight = 34,
	DeviceScale = 1.2, -- phones / tablets / consoles: a little bigger
	TextSize = 30,
	PopSeconds = 0.2,
})

-- Kid-friendly lines (about the game's own features; tests/lobby.luau checks length + uniqueness).
LobbyNpcConfig.Lines = table.freeze({
	"Did you see the Galaxy batch?!",
	"I love the Lucky Wheel!",
	"Nukey says hi!",
	"Free spin time!",
	"My pet just hatched!",
	"I'm saving up for a new egg!",
	"Supply crates are the best!",
	"Have you been to Dino Valley?",
	"The Moon Rocket is SO fast!",
	"Is it Happy Hour yet?",
	"Boom! Confetti everywhere!",
	"My factory makes candy nukes!",
	"Check the codes board!",
	"Rebirth makes you go faster!",
	"Nice outfit!",
	"This fountain is so cool!",
	"Race you to the plots!",
	"I just hired a manager!",
	"Who's on the leaderboard?",
	"Glitter batch! Woohoo!",
	"I want a Rainbow Jelly pet!",
	"Let's build a Mega Facility!",
	"Wave hi to Nukey!",
	"Best lobby ever!",
	"My plot is growing so fast!",
	"Spin it to win it!",
	"I found a Lucky Button!",
	"Pets make you more cash!",
})

return table.freeze(LobbyNpcConfig)
