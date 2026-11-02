--!strict
--[[
	LobbyConfig — the Nuke Town lobby FIXTURES the client brings to life (owner R99 "the lobby lucky
	spin doesnt work", R101 "the stall nametags clip in loby").

	Root cause of R99: the hub's Lucky Wheel stage (HubLayout.anchors.LuckyWheelStage) was art only.
	No system ever built a ProximityPrompt, touch volume or sign for it (the egg stands and the crate
	stall get theirs from Server/Pets/EggStands; the wheel stage, the group chest and the codes board
	got nothing), so standing on it did nothing. Client/Lobby/LobbyFixtures now gives every fixture
	below its interaction (opens the existing screen; every spin / claim stays a server-validated
	intent in that screen) and its sign text.

	Root cause of R101: the crate stall's "SUPPLY CRATES" label was a BillboardGui floating 5.4 studs
	over the middle display crate — inside the stall's awning (y 8.9-10.95), so the awning cut the
	yellow card and its text. The stall mesh has a real Sign board ABOVE the awning (Hub_CrateStall
	piece "Sign", 9.65 x 2.45 at y 12.6) that nothing wrote on. Client/Lobby/StallSigns now writes
	every fixture's caption on its own Sign / Screen piece with padding + TextScaled + a text-size
	cap, so the text always fits inside the board and never meets the awning.

	Fixture fields:
		id        unique key (analytics / debug)
		anchor    HubLayout.anchors key; `anchor.model` names the art model in Workspace.Hub.Art
		screen    ScreenManager screen opened by the prompt / platform action / walk-on (nil = sign
		          only: the crate stall's prompt already comes from Server/Pets/EggStands)
		prompt    { action, object } ProximityPrompt texts (E / gamepad X / tap)
		hint      hint-bar / touch-button caption of the LobbyUse platform action (owner R11)
		sign      { title, feature?, piece?, face? } — title on the art's `piece` ("Sign" default),
		          the status line from RewardsBadges.forFeature(feature) (+ statusText) when set
		walkOn    { offset, size, octagon? } stage-local box (clipped to the stage's octagon):
		          stepping INTO it opens the screen once (re-armed
		          after stepping off) — the Lucky Wheel platform only (owner: "walking onto the
		          platform ... opens the LuckyWheel screen")
		spin      true: Client/Lobby/LobbyFixtures turns the physical wheel (anchor.wheelModel) on
		          the local player's own spin results (cosmetic; the server rolls)

	Who reads it: Client/Lobby/{LobbyFixtures, StallSigns, LobbyLogic, LobbyController},
	tests/lobby.luau.

	Example:
		local fixture = LobbyConfig.byId.LuckyWheel
		print(fixture.screen) --> "LuckyWheel"
]]

export type SignSpec = {
	title: string,
	feature: string?, -- RewardsBadges feature id for the live status line
	piece: string?, -- art piece name ("Sign" default)
	dark: boolean?, -- true: a dark board (codes screen) → bright title colour
}
-- offset / size: a box in the anchor's frame; octagon (optional): also inside the regular octagon of
-- this apothem centred on the anchor (XZ), e.g. the Lucky Wheel stage's footprint.
export type WalkOn = { offset: CFrame, size: Vector3, octagon: number? }
export type Fixture = {
	id: string,
	anchor: string,
	screen: string?,
	prompt: { action: string, object: string }?,
	hint: string?,
	sign: SignSpec?,
	walkOn: WalkOn?,
	spin: boolean?,
}

local LobbyConfig = {}

LobbyConfig.Fixtures = table.freeze({
	table.freeze({
		id = "LuckyWheel",
		anchor = "LuckyWheelStage",
		screen = "LuckyWheel",
		prompt = { action = "Spin!", object = "Lucky Wheel" },
		hint = "Spin!",
		sign = { title = "LUCKY WHEEL", feature = "LuckyWheel" },
		-- The stage top in front of the wheel (Hub_LuckyWheelStage: octagon apothem 10, top y 1.8;
		-- wheel frame from z -0.1 back; steps at z -11.3 / -9.9): the box x +-9, z -10..-1.4, y 1..8
		-- clipped to the octagon (apothem 9.6) = a root standing anywhere on the front half of the
		-- platform. The stage is solid inside the octagon, so a player on the bed beside it (any
		-- avatar height) can never be inside.
		walkOn = { offset = CFrame.new(0, 4.5, -5.7), size = Vector3.new(18, 7, 8.6), octagon = 9.6 },
		spin = true,
	}),
	table.freeze({
		id = "GroupChest",
		anchor = "GroupChest",
		screen = "GroupRewards",
		prompt = { action = "Open", object = "Group Gift" },
		hint = "Group gift",
		sign = { title = "GROUP GIFT", feature = "Group" },
	}),
	table.freeze({
		id = "Codes",
		anchor = "CodesBoard",
		screen = "Codes",
		prompt = { action = "Enter code", object = "Codes Board" },
		hint = "Codes",
		sign = { title = "CODES", feature = "Codes", piece = "Screen", dark = true },
	}),
	table.freeze({
		id = "CrateStall",
		anchor = "CrateStall",
		-- No screen / prompt: Server/Pets/EggStands owns the stall's "Open Crates" prompt.
		sign = { title = "SUPPLY CRATES" },
	}),
} :: { Fixture })

-- Fixtures by id.
local byId: { [string]: Fixture } = {}
for _, fixture in LobbyConfig.Fixtures do
	byId[fixture.id] = fixture
end
LobbyConfig.byId = table.freeze(byId)

-- ProximityPrompt reach (studs) and the LobbyUse platform action's reach from the prompt point.
LobbyConfig.PromptDistance = 12
LobbyConfig.ActionReach = 12

--[[
	Walk-on (Lucky Wheel platform): checked at PollHz; an entry opens the screen only when no other
	window is open, at least Cooldown seconds after the last walk-on open, and only after the player
	was OFF the platform for RearmSeconds (closing the wheel while standing on it never re-opens it).
]]
LobbyConfig.WalkOn = table.freeze({
	PollHz = 10,
	Cooldown = 3,
	RearmSeconds = 0.6,
})

-- Seconds between re-scans for streamed-in fixture art (signs + wheel model). Event-free and cheap:
-- a handful of FindFirstChild calls.
LobbyConfig.RescanSeconds = 2

--[[
	Physical wheel (cosmetic, client-only): an idle drift while the camera is near (not on the Low
	tier / with reduced motion), and a spin on each of the local player's own spin results:
	Turns + a random part turn, eased out over LuckySpinConfig.SpinAnimationSeconds.
]]
LobbyConfig.Wheel = table.freeze({
	IdleDegPerSecond = 9,
	IdleRange = 110, -- camera distance (studs) within which the idle drift runs
	Turns = 4,
})

--[[
	Sign text (Client/Lobby/StallSigns): a SurfaceGui on the art piece's Front face, PixelsPerStud,
	padding as a fraction of the board (keeps the text and its outline inside the frame), the title /
	status split of the padded height, and a text-size cap so a short word never balloons.
]]
LobbyConfig.Sign = table.freeze({
	PixelsPerStud = 50,
	PadX = 0.07,
	PadY = 0.1,
	TitleShare = 0.62, -- of the padded height when a status line shows (1 without one)
	MaxTitleSize = 96,
	MaxStatusSize = 54,
	MaxDistance = 140, -- engine cull distance (studs)
	StatusRefresh = 1, -- seconds between status re-reads while a fixture's sign is in range
})

return table.freeze(LobbyConfig)
