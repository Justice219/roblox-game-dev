--!strict
--[[
	AdminConfig — who may use the owner admin panel, and the full allowlist of admin commands with
	their argument schemas, limits and panel hints (spec §14; owner R6 "an admin panel built in
	that I have access to as the owner of the experience"). Ported from RoBeasts' AdminConfig.

	Purpose:
		The admin system exposes exactly ONE command remote, `AdminCommand(commandName, args)`.
		Everything an admin can do is declared as data:
			- the command name (an allowlist: anything else is rejected),
			- which panel tab it lives on,
			- who it targets (nobody, an online player, or any Roblox user id),
			- a strict schema for every argument (type, range, length, allowed values),
			- a per-admin cooldown, whether it is audited, and whether the panel confirms first,
			- `provider`: for commands whose handler another system supplies (Tycoon, Retention,
			  PlayerDataService's sandbox). Until it is supplied, the panel shows the command greyed
			  with "needs <provider>" and the server refuses it.
		Systems built later (pets, attack, event) add their own commands at runtime with
		AdminService.registerCommand(def, handler) — same schema rules (validated on
		registration), shown by the panel automatically on the def's tab.

		AdminService (server) validates every call against these schemas and REJECTS unknown or
		extra arguments. The panel (client) reads the same limits / presets to build its steppers
		and pickers, so the UI never offers a value the server would refuse.

	Connects to:
		Server/Services/AdminService + Server/Admin/* (authorisation, validation, execution, audit),
		Client/UI/Screens/Admin/* (the panel), MonetizationConfig (TestReceipt product list),
		BoostConfig (GiveBoost boost list), TycoonConfig (SetArea range), NotifyConfig (owner R122
		Notify* kind pickers).

	Security notes:
		- This module replicates to clients (ReplicatedStorage), so it never holds secrets. The admin
		  UserId allowlist is not a secret (the server already publishes `IsAdmin`), and
		  authorisation itself happens ONLY on the server, re-checked on every command.
		- Clients never decide anything with these values; the server re-validates every call.

	Example (server):
		local def = AdminConfig.Commands.GrantGems
		print(def.args.amount.max) --> 10000000
	Example (owner setup):
		AdminConfig.AdminUserIds = { 1586034782, 12345678 } -- extra moderators besides the creator
]]

local BoostConfig = require(script.Parent.BoostConfig)
local MonetizationConfig = require(script.Parent.MonetizationConfig)
local NotifyConfig = require(script.Parent.NotifyConfig)
local TycoonConfig = require(script.Parent.TycoonConfig)
local WorldsConfig = require(script.Parent.Worlds.WorldsConfig)

local AdminConfig = {}

--------------------------------------------------------------------------------------------------
-- Authorisation
--------------------------------------------------------------------------------------------------

--[[
	Admins by Roblox UserId, besides the place creator (user-owned games) and group admins
	(group-owned games). The owner (user 1586034782, game.CreatorId today) is listed explicitly so
	they keep the panel if the experience ever moves into a group. Every entry can kick and ban.
]]
AdminConfig.OwnerUserId = 1586034782
AdminConfig.AdminUserIds = table.freeze({ 1586034782 } :: { number })

-- Group-owned experiences: members whose highest role rank in the owning group is at least this
-- value are admins. 255 is the group owner; 254 is the conventional "admin" role.
AdminConfig.GroupAdminRank = 254
-- How long a fetched group rank is trusted before it is fetched again (seconds).
AdminConfig.GroupRankCacheSeconds = 120
-- After a failed rank fetch, wait this long before retrying (seconds).
AdminConfig.GroupRankRetrySeconds = 15
-- A cached rank older than this is discarded even if refreshes keep failing (deny by default).
AdminConfig.GroupRankMaxStaleSeconds = 600

--------------------------------------------------------------------------------------------------
-- Rate limiting, logging, pushes
--------------------------------------------------------------------------------------------------

-- Token bucket per user for AdminCommand: bursts of `Capacity`, `RefillPerSecond` sustained.
AdminConfig.RateLimit = table.freeze({ Capacity = 10, RefillPerSecond = 3 })
-- Denied (non-admin) and malformed calls are logged at most once per this many seconds per user,
-- so an exploiter spamming the remote can neither flood output nor push real entries out.
AdminConfig.DeniedLogIntervalSeconds = 10

-- Audit log ring buffer size (server memory) and how many recent entries the panel receives.
AdminConfig.AuditLogSize = 200
AdminConfig.AuditTailSize = 80
-- Max characters of one argument value written to the audit log.
AdminConfig.AuditValueMaxLength = 60

-- AdminState pushes: periodic refresh while any admin is online, and the minimum spacing between
-- change-triggered pushes (bursts are coalesced; at most 1 / StatePushMinInterval = 4 Hz).
AdminConfig.StatePushInterval = 3
AdminConfig.StatePushMinInterval = 0.25

-- Recently issued bans kept for the panel's quick "Unban" list (this server session only).
AdminConfig.RecentBansSize = 20

--------------------------------------------------------------------------------------------------
-- Panel input + replicated attributes
--------------------------------------------------------------------------------------------------

-- Keys / buttons that toggle the panel. Bound (ContextActionService) ONLY while the local
-- player's IsAdmin attribute is true, so regular players never lose D-pad down.
AdminConfig.OpenKeys = table.freeze({ Enum.KeyCode.F2 })
AdminConfig.OpenButtons = table.freeze({ Enum.KeyCode.DPadDown })

-- Server-set attributes on ReplicatedStorage that every client reads (Screens/Admin overlay):
AdminConfig.Attributes = table.freeze({
	AnnounceText = "AdminAnnounceText", -- string: the latest filtered announcement
	AnnounceAt = "AdminAnnounceAt", -- number: server time it was sent (Workspace:GetServerTimeNow)
	ShutdownAt = "AdminShutdownAt", -- number: server time the restart kicks everyone (0 / nil = none)
	ShutdownReason = "AdminShutdownReason", -- string: filtered reason ("" = default text)
})
-- An announcement banner shows for this long (and only if it is younger than this on join).
AdminConfig.AnnounceSeconds = 8
-- Text shown when the graceful shutdown kicks everyone (and refuses late joiners).
AdminConfig.ShutdownKickMessage = "The server is restarting for an update. Please rejoin - your progress is saved!"

--------------------------------------------------------------------------------------------------
-- Limits
--------------------------------------------------------------------------------------------------

AdminConfig.Limits = table.freeze({
	CashMax = 1e100, -- |amount| for cash commands (cash is a double; late game reaches ~1e33)
	GemsMax = 10_000_000, -- per gem command
	RebirthsMax = 1_000_000,
	SpinsMax = 100,
	BoostMinutesMax = 24 * 60,
	ServerBoostMinutesMax = 180,
	ReasonMaxLength = 200, -- characters (kick / ban / shutdown reasons)
	AnnounceMaxLength = 200, -- characters
	CodeMaxLength = 20, -- = CodesConfig.MaxLength
	CodeGemsMax = 100_000,
	CodeSpinsMax = 100,
	CodeCashSecondsMax = 86_400,
	CodeHoursMax = 720,
	BanMinSeconds = 60,
	BanMaxSeconds = 365 * 24 * 3600,
	ShutdownMinSeconds = 10,
	ShutdownMaxSeconds = 600,
	MaxUserId = 2 ^ 53 - 1, -- Roblox UserIds are positive integers
	MaxArgs = 8, -- no command takes more arguments than this
	-- Registered commands (AdminService.registerCommand): sanity bounds on the def itself.
	MaxEnumValues = 400,
	MaxCommandNameLength = 32,
	MaxLabelLength = 40,
	MaxDescriptionLength = 160,
})

-- Whether Ban accepts durationSeconds = -1 (permanent).
AdminConfig.AllowPermanentBans = true

export type DurationOption = { label: string, seconds: number }

-- Ban durations offered by the panel's picker (the server accepts any value within the limits).
AdminConfig.BanDurations = table.freeze({
	table.freeze({ label = "1 hour", seconds = 3600 }),
	table.freeze({ label = "1 day", seconds = 86400 }),
	table.freeze({ label = "3 days", seconds = 3 * 86400 }),
	table.freeze({ label = "7 days", seconds = 7 * 86400 }),
	table.freeze({ label = "30 days", seconds = 30 * 86400 }),
	table.freeze({ label = "1 year", seconds = 365 * 86400 }),
	table.freeze({ label = "Permanent", seconds = -1 }),
} :: { DurationOption })

-- Moderation reasons the panel offers so gamepad / phone admins never need a keyboard.
AdminConfig.ReasonPresets = table.freeze({
	"Exploiting",
	"Harassing other players",
	"Inappropriate behavior",
	"Spamming",
	"Breaking the rules",
})

-- Announcement presets (custom text can be typed too). Every announcement is text-filtered.
AdminConfig.AnnouncePresets = table.freeze({
	"Welcome to SellNukes! Have fun building your empire!",
	"Server 2x cash is coming up - get clicking!",
	"Be kind to each other!",
	"Server restarting in 5 minutes.",
	"Thanks for playing SellNukes!",
})

-- Panel presets for numeric arguments (the server accepts any value inside the schema).
AdminConfig.CashPresets = table.freeze({ 1e3, 1e6, 1e9, 1e12, 1e15, 1e18, 1e21, 1e24, 1e30 })
AdminConfig.GemPresets = table.freeze({ 10, 100, 1000, 10000, 100000 })
AdminConfig.TimeOfDayPresets = table.freeze({ 0, 6, 9, 12, 14, 17, 18.5, 21 })
AdminConfig.ShutdownPresets = table.freeze({ 30, 60, 120, 300 })

--------------------------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------------------------

export type Tab =
	"Players"
	| "Economy"
	| "Server"
	| "World"
	| "Attack"
	| "Live"
	| "Log"
	| "Analytics"
	| "NewPlayer"
	| "Meta"

export type TabDef = { key: Tab, label: string, color: string, icon: string }

-- Panel tab order (Meta = invisible commands such as RequestState). Colours = UIStyleConfig presets.
AdminConfig.Tabs = table.freeze({
	table.freeze({ key = "Players", label = "Players", color = "blue", icon = "Rewards" }),
	table.freeze({ key = "Economy", label = "Economy", color = "green", icon = "Cash" }),
	table.freeze({ key = "Server", label = "Server", color = "orange", icon = "Settings" }),
	table.freeze({ key = "World", label = "World", color = "teal", icon = "Teleport" }),
	-- Owner R51: attack test bots + attack / knockdown test tools (Server/Admin/Handlers/AttackHandlers).
	table.freeze({ key = "Attack", label = "Attack", color = "red", icon = "Shield" }),
	table.freeze({ key = "Live", label = "Live", color = "red", icon = "Clock" }),
	table.freeze({ key = "Log", label = "Log", color = "grey", icon = "Check" }),
	table.freeze({ key = "Analytics", label = "Analytics", color = "purple", icon = "Star" }),
	table.freeze({ key = "NewPlayer", label = "New Player", color = "yellow", icon = "Gift" }),
} :: { TabDef })

--------------------------------------------------------------------------------------------------
-- Command schemas
--------------------------------------------------------------------------------------------------

--[[
	Argument kinds:
		integer      whole number within [min, max]; `nonZero` rejects 0
		number       finite number within [min, max] (cash amounts, time of day)
		text         UTF-8 text without control characters, trimmed, at most `maxLength` characters;
		             empty only when `allowEmpty`
		enum         one of `values` (`labels` = display names, same order)
		boolean      true / false
		banDuration  -1 (permanent, if allowed) or [BanMinSeconds, BanMaxSeconds]
		code         a redeem code: 1..maxLength ASCII letters / digits (upper-cased by the server)
	Panel hints (ignored by the server): label, presets, format ("money" | "gems" | "count" |
	"minutes" | "seconds" | "hour"), default.
]]
export type ArgKind = "integer" | "number" | "text" | "enum" | "boolean" | "banDuration" | "code"

export type ArgSpec = {
	kind: ArgKind,
	optional: boolean?,
	min: number?,
	max: number?,
	nonZero: boolean?,
	maxLength: number?,
	allowEmpty: boolean?,
	values: { string }?,
	labels: { string }?,
	-- panel hints
	label: string?,
	presets: { number }?,
	format: string?,
	default: (string | number | boolean)?,
}

--[[
	Target modes (the arguments they add are validated by AdminService):
		None     no target (server-wide, or the caller themself: New Player Mode, TeleportTo uses Player)
		Player   `userId` of a player who is in THIS server (resolved with GetPlayerByUserId)
		AnyUser  `userId` of any Roblox user, online or not (ban / unban)
]]
export type TargetMode = "None" | "Player" | "AnyUser"

export type CommandDef = {
	name: string,
	tab: Tab,
	label: string, -- button text in the panel
	description: string?, -- one line under the button / in the confirm dialog
	target: TargetMode,
	args: { [string]: ArgSpec },
	argOrder: { string }?, -- panel field order (defaults to sorted keys)
	cooldown: number, -- seconds between uses of this command by the same admin
	audited: boolean, -- written to the audit log (read-only commands are not)
	confirm: boolean, -- the panel asks "are you sure?" in-panel first
	color: string?, -- button colour preset (UIStyleConfig.Colors key); default by tab
	studioOnly: boolean?, -- refused (and hidden) outside Studio
	provider: string?, -- the system that supplies the handler (nil = built into AdminService)
	order: number?, -- sort order inside its tab (lower first)
}

local L = AdminConfig.Limits

-- The SetArea range follows the tycoon catalogue (10 areas today).
local AREA_COUNT = math.max(1, #TycoonConfig.Areas)

-- Product keys for Studio test receipts, in the shop's display order.
local PRODUCT_KEYS: { string } = {}
local PRODUCT_LABELS: { string } = {}
for _, key in MonetizationConfig.ProductOrder do
	local def = MonetizationConfig.getProduct(key)
	table.insert(PRODUCT_KEYS, key)
	table.insert(PRODUCT_LABELS, if def ~= nil then def.name else key)
end

-- Personal boost keys (sorted for a stable picker) + display names.
local BOOST_KEYS: { string } = {}
for key in BoostConfig.Boosts do
	table.insert(BOOST_KEYS, key)
end
table.sort(BOOST_KEYS)
local BOOST_LABELS: { string } = {}
for index, key in BOOST_KEYS do
	BOOST_LABELS[index] = BoostConfig.Boosts[key].name
end

local BAN_SECONDS: { number } = {}
for index, option in AdminConfig.BanDurations do
	BAN_SECONDS[index] = option.seconds
end

-- Providers (shown as "needs <provider>" while the handler is missing).
local TYCOON = "Tycoon (B5 TycoonAdmin)"
local RETENTION = "Retention (B7)"
local SANDBOX = "PlayerDataService sandbox (B1)"
local KNOCKDOWN = "Knockdown (R50 Server/Tycoon/Knockdown)"
-- Owner R122 return notifications (Server/Retention/ReturnNotifyAdmin installs the handlers).
local RETURN_NOTIFY = "Return notifications (R122 ReturnNotifyService)"

-- Return-notification kinds in priority order + their panel names (NotifyConfig.KindOrder).
local NOTIFY_KINDS: { string } = {}
local NOTIFY_KIND_LABELS: { string } = {}
for index, kind in NotifyConfig.KindOrder do
	NOTIFY_KINDS[index] = kind
	NOTIFY_KIND_LABELS[index] = NotifyConfig.Kinds[kind].label
end

local function cash(label: string, min: number): ArgSpec
	return {
		kind = "number",
		min = min,
		max = L.CashMax,
		label = label,
		presets = AdminConfig.CashPresets,
		format = "money",
	}
end

local function gems(label: string): ArgSpec
	return {
		kind = "integer",
		min = 1,
		max = L.GemsMax,
		label = label,
		presets = AdminConfig.GemPresets,
		format = "gems",
	}
end

local function reason(optional: boolean): ArgSpec
	return { kind = "text", maxLength = L.ReasonMaxLength, optional = optional, allowEmpty = true, label = "Reason" }
end

-- Worlds (owner R57; World* commands below) ---------------------------------------------------------
-- The `world` enum: every extra world id in WorldsConfig.Order (never "main"), display names as
-- labels; WorldSend's enum also offers Nuke Town (send them home). The area range is the largest
-- extra world's area count (MultiWorldHandlers re-checks it against the chosen world).
local WORLDS = "Worlds (W4 MultiWorldHandlers)"
local WORLD_IDS: { string } = {}
local WORLD_LABELS: { string } = {}
local SEND_WORLD_IDS: { string } = {}
local SEND_WORLD_LABELS: { string } = {}
local WORLD_AREA_MAX = 1
for _, worldId in WorldsConfig.Order do
	local def = WorldsConfig.get(worldId)
	if def ~= nil then
		if def.id ~= WorldsConfig.MAIN then
			table.insert(WORLD_IDS, def.id)
			table.insert(WORLD_LABELS, def.name)
			WORLD_AREA_MAX = math.max(WORLD_AREA_MAX, def.geometry.areaCount)
		end
		table.insert(SEND_WORLD_IDS, def.id)
		table.insert(SEND_WORLD_LABELS, def.name)
	end
end
-- Per-command caps of the world commands.
local WORLD_TOKENS_MAX = 1_000_000
local WORLD_TOKEN_PRESETS = { 10, 100, 1000, 10000 }
local WORLD_OFFLINE_HOURS_MAX = 72

-- The `world` argument of every World* command (a fresh spec per command; frozen with it).
local function worldArg(): ArgSpec
	return {
		kind = "enum",
		values = table.clone(WORLD_IDS),
		labels = table.clone(WORLD_LABELS),
		label = "World",
		default = WORLD_IDS[1],
	}
end

local COMMANDS: { [string]: CommandDef } = {
	-- Meta -----------------------------------------------------------------------------------------
	RequestState = {
		name = "RequestState",
		tab = "Meta",
		label = "Refresh",
		target = "None",
		args = {},
		cooldown = 0.5,
		audited = false,
		confirm = false,
	},

	-- Players: currency ----------------------------------------------------------------------------
	GrantCash = {
		name = "GrantCash",
		tab = "Players",
		label = "Give Cash",
		target = "Player",
		args = { amount = cash("Amount", 1) },
		cooldown = 0.5,
		audited = true,
		confirm = false,
		color = "green",
		order = 10,
	},
	TakeCash = {
		name = "TakeCash",
		tab = "Players",
		label = "Take Cash",
		description = "Takes up to the amount (never below $0).",
		target = "Player",
		args = { amount = cash("Amount", 1) },
		cooldown = 0.5,
		audited = true,
		confirm = true,
		color = "red",
		order = 11,
	},
	SetCash = {
		name = "SetCash",
		tab = "Players",
		label = "Set Cash",
		target = "Player",
		args = { amount = cash("Cash", 0) },
		cooldown = 0.5,
		audited = true,
		confirm = true,
		color = "yellow",
		order = 12,
	},
	GrantGems = {
		name = "GrantGems",
		tab = "Players",
		label = "Give Gems",
		target = "Player",
		args = { amount = gems("Amount") },
		cooldown = 0.5,
		audited = true,
		confirm = false,
		color = "purple",
		order = 13,
	},
	TakeGems = {
		name = "TakeGems",
		tab = "Players",
		label = "Take Gems",
		description = "Takes up to the amount (never below 0).",
		target = "Player",
		args = { amount = gems("Amount") },
		cooldown = 0.5,
		audited = true,
		confirm = true,
		color = "red",
		order = 14,
	},

	-- Players: tycoon (TycoonAdmin seam) ------------------------------------------------------------
	SetArea = {
		name = "SetArea",
		tab = "Players",
		label = "Set Area",
		description = "Unlocks every area up to this one and builds it in.",
		target = "Player",
		args = { area = { kind = "integer", min = 1, max = AREA_COUNT, label = "Area", format = "count" } },
		cooldown = 2,
		audited = true,
		confirm = true,
		color = "teal",
		provider = TYCOON,
		order = 20,
	},
	UnlockAll = {
		name = "UnlockAll",
		tab = "Players",
		label = "Unlock All Pads",
		description = "Buys and builds every pad in every area.",
		target = "Player",
		args = {},
		cooldown = 3,
		audited = true,
		confirm = true,
		color = "orange",
		provider = TYCOON,
		order = 21,
	},
	ResetPlot = {
		name = "ResetPlot",
		tab = "Players",
		label = "Reset Plot",
		description = "Wipes the tycoon back to area 1 and $0. Cannot be undone.",
		target = "Player",
		args = {},
		cooldown = 3,
		audited = true,
		confirm = true,
		color = "red",
		provider = TYCOON,
		order = 22,
	},
	SetRebirths = {
		name = "SetRebirths",
		tab = "Players",
		label = "Set Rebirths",
		target = "Player",
		args = { rebirths = { kind = "integer", min = 0, max = L.RebirthsMax, label = "Rebirths", format = "count" } },
		cooldown = 1,
		audited = true,
		confirm = true,
		color = "teal",
		provider = TYCOON,
		order = 23,
	},

	-- Players: retention (registered by B7 services) ------------------------------------------------
	GiveBoost = {
		name = "GiveBoost",
		tab = "Players",
		label = "Give Boost",
		target = "Player",
		args = {
			boost = { kind = "enum", values = BOOST_KEYS, labels = BOOST_LABELS, label = "Boost" },
			minutes = {
				kind = "integer",
				min = 1,
				max = L.BoostMinutesMax,
				label = "Minutes",
				presets = { 5, 15, 30, 60, 240 },
				format = "minutes",
			},
		},
		argOrder = { "boost", "minutes" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		provider = RETENTION,
		order = 30,
	},
	GrantSpins = {
		name = "GrantSpins",
		tab = "Players",
		label = "Give Spins",
		target = "Player",
		args = {
			count = {
				kind = "integer",
				min = 1,
				max = L.SpinsMax,
				label = "Spins",
				presets = { 1, 5, 10, 25 },
				format = "count",
			},
		},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "rainbow",
		provider = RETENTION,
		order = 31,
	},
	ResetDaily = {
		name = "ResetDaily",
		tab = "Players",
		label = "Reset Daily",
		description = "Makes the daily reward and today's time rewards claimable again.",
		target = "Player",
		args = {},
		cooldown = 2,
		audited = true,
		confirm = true,
		color = "red",
		provider = RETENTION,
		order = 32,
	},
	AddPlaytime = {
		name = "AddPlaytime",
		tab = "Players",
		label = "Add Playtime",
		description = "Adds minutes to today's time-reward clock (skip the waiting).",
		target = "Player",
		args = {
			minutes = {
				kind = "integer",
				min = 1,
				max = L.BoostMinutesMax,
				label = "Minutes",
				presets = { 5, 15, 30, 60 },
				format = "minutes",
			},
		},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		provider = RETENTION,
		order = 33,
	},
	ResetClaims = {
		name = "ResetClaims",
		tab = "Players",
		label = "Reset One-Time Claims",
		description = "Makes the group and notification rewards claimable again.",
		target = "Player",
		args = {},
		cooldown = 2,
		audited = true,
		confirm = true,
		color = "red",
		provider = RETENTION,
		order = 34,
	},

	-- Players: movement + moderation -----------------------------------------------------------------
	TeleportTo = {
		name = "TeleportTo",
		tab = "Players",
		label = "Go To",
		description = "Teleports you next to this player.",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "sky",
		order = 40,
	},
	Bring = {
		name = "Bring",
		tab = "Players",
		label = "Bring",
		description = "Teleports this player next to you.",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "sky",
		order = 41,
	},
	Kick = {
		name = "Kick",
		tab = "Players",
		label = "Kick",
		target = "Player",
		args = { reason = reason(true) },
		cooldown = 2,
		audited = true,
		confirm = true,
		color = "red",
		order = 50,
	},
	Ban = {
		name = "Ban",
		tab = "Players",
		label = "Ban",
		description = "Bans across every server of the experience (Roblox Ban API).",
		target = "AnyUser",
		args = {
			durationSeconds = {
				kind = "banDuration",
				label = "Duration",
				presets = BAN_SECONDS,
				format = "seconds",
				default = 86400,
			},
			reason = reason(true),
		},
		argOrder = { "durationSeconds", "reason" },
		cooldown = 3,
		audited = true,
		confirm = true,
		color = "red",
		order = 51,
	},
	Unban = {
		name = "Unban",
		tab = "Players",
		label = "Unban",
		target = "AnyUser",
		args = {},
		cooldown = 3,
		audited = true,
		confirm = true,
		color = "green",
		order = 52,
	},

	-- Economy ------------------------------------------------------------------------------------------
	ServerBoost = {
		name = "ServerBoost",
		tab = "Economy",
		label = "Start Server 2x Cash",
		description = "Everyone in this server earns 2x cash (adds time; stacks to the cap).",
		target = "None",
		args = {
			minutes = {
				kind = "integer",
				min = 1,
				max = L.ServerBoostMinutesMax,
				label = "Minutes",
				presets = { 5, 15, 30, 60, 120 },
				format = "minutes",
				default = 15,
			},
		},
		cooldown = 2,
		audited = true,
		confirm = false,
		color = "green",
		provider = RETENTION,
		order = 10,
	},
	ServerBoostOff = {
		name = "ServerBoostOff",
		tab = "Economy",
		label = "Stop Server 2x Cash",
		target = "None",
		args = {},
		cooldown = 2,
		audited = true,
		confirm = true,
		color = "red",
		provider = RETENTION,
		order = 11,
	},
	TestReceipt = {
		name = "TestReceipt",
		tab = "Economy",
		label = "Test Receipt (Studio)",
		description = "Runs a fake receipt through the REAL receipt path for you. Studio only.",
		target = "None",
		args = { product = { kind = "enum", values = PRODUCT_KEYS, labels = PRODUCT_LABELS, label = "Product" } },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "yellow",
		studioOnly = true,
		order = 20,
	},

	-- Server ---------------------------------------------------------------------------------------------
	Announce = {
		name = "Announce",
		tab = "Server",
		label = "Announce",
		description = "A banner for everyone in this server (text-filtered).",
		target = "None",
		args = { text = { kind = "text", maxLength = L.AnnounceMaxLength, label = "Message" } },
		cooldown = 3,
		audited = true,
		confirm = false,
		color = "blue",
		order = 10,
	},
	SetTimeOfDay = {
		name = "SetTimeOfDay",
		tab = "Server",
		label = "Set Time of Day",
		target = "None",
		args = {
			hour = {
				kind = "number",
				min = 0,
				max = 24,
				label = "Hour",
				presets = AdminConfig.TimeOfDayPresets,
				format = "hour",
				default = 14,
			},
		},
		cooldown = 0.5,
		audited = true,
		confirm = false,
		color = "sky",
		order = 20,
	},
	AddCode = {
		name = "AddCode",
		tab = "Server",
		label = "Add Code (this server)",
		description = "A redeem code that works in THIS server until it closes or the hours run out.",
		target = "None",
		args = {
			code = { kind = "code", maxLength = L.CodeMaxLength, label = "Code" },
			gems = { kind = "integer", min = 0, max = L.CodeGemsMax, label = "Gems", format = "gems", default = 0 },
			spins = { kind = "integer", min = 0, max = L.CodeSpinsMax, label = "Spins", format = "count", default = 0 },
			cashSeconds = {
				kind = "integer",
				min = 0,
				max = L.CodeCashSecondsMax,
				label = "Cash (seconds of income)",
				format = "seconds",
				default = 0,
			},
			hours = { kind = "integer", min = 1, max = L.CodeHoursMax, label = "Hours", format = "count", default = 24 },
		},
		argOrder = { "code", "gems", "spins", "cashSeconds", "hours" },
		cooldown = 2,
		audited = true,
		confirm = true,
		color = "blue",
		provider = RETENTION,
		order = 30,
	},
	FlushAnalytics = {
		name = "FlushAnalytics",
		tab = "Server",
		label = "Flush Analytics Now",
		target = "None",
		args = {},
		cooldown = 10,
		audited = true,
		confirm = false,
		color = "purple",
		order = 40,
	},
	Shutdown = {
		name = "Shutdown",
		tab = "Server",
		label = "Restart Server",
		description = "Warns everyone with a countdown, then closes this server (progress is saved).",
		target = "None",
		args = {
			seconds = {
				kind = "integer",
				min = L.ShutdownMinSeconds,
				max = L.ShutdownMaxSeconds,
				label = "Countdown",
				presets = AdminConfig.ShutdownPresets,
				format = "seconds",
				default = 60,
			},
			reason = reason(true),
		},
		argOrder = { "seconds", "reason" },
		cooldown = 5,
		audited = true,
		confirm = true,
		color = "red",
		order = 90,
	},
	CancelShutdown = {
		name = "CancelShutdown",
		tab = "Server",
		label = "Cancel Restart",
		target = "None",
		args = {},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "green",
		order = 91,
	},

	-- Return notifications (owner R122 §2.3; docs/retention.md "Return notifications"). Universe-
	-- wide switches (DataStore + MessagingService, Server/Retention/ReturnNotifyControl); the
	-- panel's Server tab shows the live state (Client/UI/Screens/Admin/NotifySection).
	NotifyToggle = {
		name = "NotifyToggle",
		tab = "Server",
		label = "Return Notifications On/Off",
		description = "Kill switch for EVERY server: OFF = nothing is planned or sent (due ones are dropped).",
		target = "None",
		args = { mode = { kind = "enum", values = { "on", "off" }, labels = { "ON", "OFF" }, label = "Mode" } },
		argOrder = { "mode" },
		cooldown = 3,
		audited = true,
		confirm = true,
		color = "orange",
		provider = RETURN_NOTIFY,
		order = 95,
	},
	NotifyKind = {
		name = "NotifyKind",
		tab = "Server",
		label = "Notification Kind On/Off",
		description = "Turns one kind on / off on every server (a kind also needs its message id in NotifyConfig).",
		target = "None",
		args = {
			kind = { kind = "enum", values = NOTIFY_KINDS, labels = NOTIFY_KIND_LABELS, label = "Kind" },
			mode = { kind = "enum", values = { "on", "off" }, labels = { "ON", "OFF" }, label = "Mode" },
		},
		argOrder = { "kind", "mode" },
		cooldown = 2,
		audited = true,
		confirm = false,
		color = "orange",
		provider = RETURN_NOTIFY,
		order = 96,
	},
	NotifyStatus = {
		name = "NotifyStatus",
		tab = "Server",
		label = "Notification Status",
		description = "Mode, switches, queue size + due now, and this server's plans / sends / results.",
		target = "None",
		args = {},
		cooldown = 2,
		audited = false,
		confirm = false,
		color = "grey",
		provider = RETURN_NOTIFY,
		order = 97,
	},
	NotifyTest = {
		name = "NotifyTest",
		tab = "Server",
		label = "Send Test Notification To Me",
		description = "Owner only: one REAL notification of that kind to you (Studio: dry run, no request).",
		target = "None",
		args = { kind = { kind = "enum", values = NOTIFY_KINDS, labels = NOTIFY_KIND_LABELS, label = "Kind" } },
		argOrder = { "kind" },
		cooldown = 10,
		audited = true,
		confirm = false,
		color = "blue",
		provider = RETURN_NOTIFY,
		order = 98,
	},
	NotifyQueueTest = {
		name = "NotifyQueueTest",
		tab = "Server",
		label = "Queue Test Notification",
		description = "Studio: queues one for you, due in N seconds (0 = poll now); runs the real queue as a dry run.",
		target = "None",
		args = {
			kind = { kind = "enum", values = NOTIFY_KINDS, labels = NOTIFY_KIND_LABELS, label = "Kind" },
			seconds = {
				kind = "integer",
				min = 0,
				max = 300,
				label = "Due in",
				presets = { 0, 30, 60 },
				format = "seconds",
				default = 0,
			},
		},
		argOrder = { "kind", "seconds" },
		cooldown = 3,
		audited = true,
		confirm = false,
		color = "blue",
		studioOnly = true,
		provider = RETURN_NOTIFY,
		order = 99,
	},

	-- World ----------------------------------------------------------------------------------------------
	RebuildPlot = {
		name = "RebuildPlot",
		tab = "World",
		label = "Rebuild Plot",
		description = "Tears the plot down and rebuilds it instantly from the saved profile.",
		target = "Player",
		args = {},
		cooldown = 3,
		audited = true,
		confirm = true,
		color = "orange",
		provider = TYCOON,
		order = 10,
	},
	ReplayBuildIn = {
		name = "ReplayBuildIn",
		tab = "World",
		label = "Replay Build-In",
		description = "Rebuilds the plot with every build-in animation (preview the fly-in).",
		target = "Player",
		args = {},
		cooldown = 5,
		audited = true,
		confirm = false,
		color = "teal",
		provider = TYCOON,
		order = 11,
	},
	-- Map vehicles + machines (owner R56, V1; Server/Admin/Handlers/WorldHandlers): sets the
	-- ReplicatedStorage attribute every client's Tycoon/Fx/VehicleRoutes reads live.
	VehiclesToggle = {
		name = "VehiclesToggle",
		tab = "World",
		label = "Vehicles on/off",
		description = "Off: every truck, cart, forklift and car parks on its spot (this server).",
		target = "None",
		args = {
			on = { kind = "boolean", label = "Vehicles on", default = true },
		},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "teal",
		order = 12,
	},

	-- Worlds (owner R57 World 2, spec §13; Server/Admin/Handlers/MultiWorldHandlers drives
	-- Server/Tycoon/WorldService + TycoonAdmin's per-world seam). `world` is an enum of every
	-- extra world id (WorldsConfig.Order minus "main"); WorldSend also offers Nuke Town.
	WorldUnlock = {
		name = "WorldUnlock",
		tab = "Players",
		label = "Unlock World",
		description = "Unlocks the world (sticky). The WORLD UNLOCKED popup shows for them.",
		target = "Player",
		args = { world = worldArg() },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "teal",
		provider = WORLDS,
		order = 60,
	},
	WorldRelock = {
		name = "WorldRelock",
		tab = "Players",
		label = "Re-lock World",
		description = "Undoes the unlock to re-test the popup (sends them home first). Progress is kept.",
		target = "Player",
		args = { world = worldArg() },
		cooldown = 1,
		audited = true,
		confirm = true,
		color = "yellow",
		provider = WORLDS,
		order = 61,
	},
	WorldSetArea = {
		name = "WorldSetArea",
		tab = "Players",
		label = "World: Set Area",
		description = "Unlocks every area of that world up to this one and builds it in.",
		target = "Player",
		args = {
			world = worldArg(),
			area = { kind = "integer", min = 1, max = WORLD_AREA_MAX, label = "Area", format = "count" },
		},
		argOrder = { "world", "area" },
		cooldown = 2,
		audited = true,
		confirm = true,
		color = "teal",
		provider = WORLDS,
		order = 62,
	},
	WorldUnlockAll = {
		name = "WorldUnlockAll",
		tab = "Players",
		label = "World: Unlock All Pads",
		description = "Buys and builds every pad of that world.",
		target = "Player",
		args = { world = worldArg() },
		cooldown = 3,
		audited = true,
		confirm = true,
		color = "orange",
		provider = WORLDS,
		order = 63,
	},
	WorldResetRun = {
		name = "WorldResetRun",
		tab = "Players",
		label = "World: Reset Run",
		description = "Wipes that world's tycoon back to area 1 and its currency to 0. Cannot be undone.",
		target = "Player",
		args = { world = worldArg() },
		cooldown = 3,
		audited = true,
		confirm = true,
		color = "red",
		provider = WORLDS,
		order = 64,
	},
	WorldWipe = {
		name = "WorldWipe",
		tab = "Players",
		label = "World: Wipe Everything",
		description = "Wipes that world completely: tycoon, currency, rebirths, tokens and shop. Cannot be undone.",
		target = "Player",
		args = { world = worldArg() },
		cooldown = 5,
		audited = true,
		confirm = true,
		color = "red",
		provider = WORLDS,
		order = 65,
	},
	WorldGrantCash = {
		name = "WorldGrantCash",
		tab = "Players",
		label = "World: Give Currency",
		description = "Gives that world's currency (Dino Valley: Bones).",
		target = "Player",
		args = { world = worldArg(), amount = cash("Amount", 1) },
		argOrder = { "world", "amount" },
		cooldown = 0.5,
		audited = true,
		confirm = false,
		color = "green",
		provider = WORLDS,
		order = 66,
	},
	WorldSetCash = {
		name = "WorldSetCash",
		tab = "Players",
		label = "World: Set Currency",
		description = "Sets that world's currency to exactly this amount.",
		target = "Player",
		args = { world = worldArg(), amount = cash("Amount", 0) },
		argOrder = { "world", "amount" },
		cooldown = 0.5,
		audited = true,
		confirm = true,
		color = "yellow",
		provider = WORLDS,
		order = 67,
	},
	WorldSetRebirths = {
		name = "WorldSetRebirths",
		tab = "Players",
		label = "World: Set Rebirths",
		target = "Player",
		args = {
			world = worldArg(),
			rebirths = { kind = "integer", min = 0, max = L.RebirthsMax, label = "Rebirths", format = "count" },
		},
		argOrder = { "world", "rebirths" },
		cooldown = 1,
		audited = true,
		confirm = true,
		color = "teal",
		provider = WORLDS,
		order = 68,
	},
	WorldGrantTokens = {
		name = "WorldGrantTokens",
		tab = "Players",
		label = "World: Give Rebirth Tokens",
		description = "Gives that world's rebirth tokens (Dino Valley: Amber).",
		target = "Player",
		args = {
			world = worldArg(),
			amount = {
				kind = "integer",
				min = 1,
				max = WORLD_TOKENS_MAX,
				label = "Tokens",
				presets = WORLD_TOKEN_PRESETS,
				format = "count",
			},
		},
		argOrder = { "world", "amount" },
		cooldown = 0.5,
		audited = true,
		confirm = false,
		color = "purple",
		provider = WORLDS,
		order = 69,
	},
	WorldSend = {
		name = "WorldSend",
		tab = "Players",
		label = "World: Send Player",
		description = "Travels them (warp) to that world's spawn or their own plot there.",
		target = "Player",
		args = {
			world = {
				kind = "enum",
				values = SEND_WORLD_IDS,
				labels = SEND_WORLD_LABELS,
				label = "World",
				default = SEND_WORLD_IDS[1],
			},
			to = {
				kind = "enum",
				values = { "spawn", "plot" },
				labels = { "Spawn / Base Camp", "Their plot" },
				label = "Where",
				default = "spawn",
			},
		},
		argOrder = { "world", "to" },
		cooldown = 2,
		audited = true,
		confirm = false,
		color = "blue",
		provider = WORLDS,
		order = 70,
	},
	WorldRebuildPlot = {
		name = "WorldRebuildPlot",
		tab = "Players",
		label = "World: Rebuild Plot",
		description = "Rebuilds their plot in that world from the save (optionally replaying every build-in).",
		target = "Player",
		args = {
			world = worldArg(),
			replay = { kind = "boolean", label = "Replay build-in", default = false },
		},
		argOrder = { "world", "replay" },
		cooldown = 3,
		audited = true,
		confirm = false,
		color = "orange",
		provider = WORLDS,
		order = 71,
	},
	WorldOfflinePreview = {
		name = "WorldOfflinePreview",
		tab = "Players",
		label = "World: Offline Preview",
		description = "Read-only: what N hours offline would pay them in every world.",
		target = "Player",
		args = {
			hours = {
				kind = "integer",
				min = 1,
				max = WORLD_OFFLINE_HOURS_MAX,
				label = "Hours",
				format = "count",
				default = 8,
			},
		},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "grey",
		provider = WORLDS,
		order = 72,
	},
	WorldEnabled = {
		name = "WorldEnabled",
		tab = "Server",
		label = "World On/Off",
		description = "Kill switch. Off: nobody can travel there and everyone inside is sent home (they keep earning).",
		target = "None",
		args = {
			world = worldArg(),
			on = { kind = "boolean", label = "World open", default = true },
		},
		argOrder = { "world", "on" },
		cooldown = 2,
		audited = true,
		confirm = true,
		color = "red",
		provider = WORLDS,
		order = 50,
	},

	-- Attack: test bots + my attack helpers (owner R51, Q2; Server/Admin/Handlers/AttackHandlers) ----------
	-- Bots are admin-only test targets on a FREE plot: never saved, never a real Player, removed when
	-- the spawning admin leaves, after 30 min, at shutdown, or when a joining player needs the plot.
	AttackBotSpawn = {
		name = "AttackBotSpawn",
		tab = "Attack",
		label = "Spawn Test Bot",
		description = "A bot base on a free plot, built to the chosen area. Only admins can target it.",
		target = "None",
		args = {
			area = { kind = "integer", min = 1, max = AREA_COUNT, label = "Bot area", default = 7 },
			aa = { kind = "integer", min = 0, max = 5, label = "AA level", default = 1 },
			shield = { kind = "boolean", label = "Shield on", default = false },
		},
		argOrder = { "area", "aa", "shield" },
		cooldown = 3,
		audited = true,
		confirm = false,
		color = "red",
		order = 1,
	},
	AttackBotAttack = {
		name = "AttackBotAttack",
		tab = "Attack",
		label = "Bot attacks me",
		description = "TestBot N launches at your plot (area 0 = your best area). Revenge it back!",
		target = "None",
		args = {
			bot = { kind = "integer", min = 1, max = 8, label = "Bot #", default = 1 },
			kind = {
				kind = "enum",
				values = { "normal", "barrage" },
				labels = { "Normal", "Barrage" },
				label = "Kind",
				default = "normal",
			},
			area = { kind = "integer", min = 0, max = AREA_COUNT, label = "Aim area (0 = auto)", default = 0 },
		},
		argOrder = { "bot", "kind", "area" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "red",
		order = 2,
	},
	AttackBotAuto = {
		name = "AttackBotAuto",
		tab = "Attack",
		label = "Bot auto-attack",
		description = "TestBot N attacks you every N seconds (0 = stop; at least 5 s).",
		target = "None",
		args = {
			bot = { kind = "integer", min = 1, max = 8, label = "Bot #", default = 1 },
			every = {
				kind = "integer",
				min = 0,
				max = 300,
				label = "Every (s)",
				presets = { 0, 10, 30, 60 },
				default = 20,
			},
			kind = {
				kind = "enum",
				values = { "normal", "barrage" },
				labels = { "Normal", "Barrage" },
				label = "Kind",
				default = "normal",
			},
			area = { kind = "integer", min = 0, max = AREA_COUNT, label = "Aim area (0 = auto)", default = 0 },
		},
		argOrder = { "bot", "every", "kind", "area" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = 3,
	},
	AttackBotShield = {
		name = "AttackBotShield",
		tab = "Attack",
		label = "Bot shield",
		description = "Turns TestBot N's shield bubble on (1 hour) or off.",
		target = "None",
		args = {
			bot = { kind = "integer", min = 1, max = 8, label = "Bot #", default = 1 },
			on = { kind = "boolean", label = "Shield on", default = true },
		},
		argOrder = { "bot", "on" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "blue",
		order = 4,
	},
	AttackBotRemove = {
		name = "AttackBotRemove",
		tab = "Attack",
		label = "Remove bots",
		description = "Removes TestBot N (0 = every bot) and frees its plot.",
		target = "None",
		args = {
			bot = { kind = "integer", min = 0, max = 8, label = "Bot # (0 = all)", default = 0 },
		},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "grey",
		order = 5,
	},
	AttackMeReset = {
		name = "AttackMeReset",
		tab = "Attack",
		label = "Reset my cooldowns",
		description = "Your launcher and barrage are ready again right now.",
		target = "None",
		args = {},
		cooldown = 0.5,
		audited = true,
		confirm = false,
		color = "green",
		order = 6,
	},
	AttackMeBarrage = {
		name = "AttackMeBarrage",
		tab = "Attack",
		label = "Give me barrage nukes",
		description = "Adds stored Barrage nukes to your profile (test).",
		target = "None",
		args = {
			count = { kind = "integer", min = 1, max = 2000, label = "Nukes", presets = { 20, 100, 500 }, default = 20 },
		},
		cooldown = 0.5,
		audited = true,
		confirm = false,
		color = "green",
		order = 7,
	},
	AttackMeLevels = {
		name = "AttackMeLevels",
		tab = "Attack",
		label = "Set my launcher + AA",
		description = "Sets your stored Launcher / AA levels (they count while the Area 7 pads are owned).",
		target = "None",
		args = {
			launcher = { kind = "integer", min = 0, max = 5, label = "Launcher", default = 5 },
			aa = { kind = "integer", min = 0, max = 5, label = "AA", default = 5 },
		},
		argOrder = { "launcher", "aa" },
		cooldown = 0.5,
		audited = true,
		confirm = false,
		color = "green",
		order = 8,
	},

	-- Attack: knockdown (owner R50 / R51, Q3; Server/Admin/Handlers/KnockdownHandlers) ------------------------
	-- `bot` 1..8 aims a command at TestBot N; 0 = your own plot. Live on this server, never saved.
	KnockdownArea = {
		name = "KnockdownArea",
		tab = "Attack",
		label = "Knock down an area",
		description = "Knocks down one area (test; no reward). Bypasses the switch, shields and immunity.",
		target = "None",
		args = {
			area = { kind = "integer", min = 1, max = AREA_COUNT, label = "Area", default = 1 },
			seconds = {
				kind = "integer",
				min = 0,
				max = 600,
				label = "Seconds (0 = 45)",
				presets = { 0, 15, 90 },
				default = 0,
			},
			bot = { kind = "integer", min = 0, max = 8, label = "Bot # (0 = me)", default = 0 },
		},
		argOrder = { "area", "seconds", "bot" },
		cooldown = 0.5,
		audited = true,
		confirm = false,
		color = "red",
		provider = KNOCKDOWN,
		order = 20,
	},
	KnockdownRebuild = {
		name = "KnockdownRebuild",
		tab = "Attack",
		label = "Rebuild knocked areas",
		description = "Every knocked-down area rebuilds now (the fly-in plays).",
		target = "None",
		args = {
			bot = { kind = "integer", min = 0, max = 8, label = "Bot # (0 = me)", default = 0 },
		},
		cooldown = 0.5,
		audited = true,
		confirm = false,
		color = "green",
		provider = KNOCKDOWN,
		order = 21,
	},
	KnockdownImmunityOff = {
		name = "KnockdownImmunityOff",
		tab = "Attack",
		label = "Remove knock immunity",
		description = "The plot can be knocked down again right away (skips the 180 s anti-grief window).",
		target = "None",
		args = {
			bot = { kind = "integer", min = 0, max = 8, label = "Bot # (0 = me)", default = 0 },
		},
		cooldown = 0.5,
		audited = true,
		confirm = false,
		color = "blue",
		provider = KNOCKDOWN,
		order = 22,
	},
	KnockdownToggle = {
		name = "KnockdownToggle",
		tab = "Attack",
		label = "Knockdowns on/off",
		description = "Off: hits still pay, nothing gets knocked down (this server).",
		target = "None",
		args = {
			on = { kind = "boolean", label = "Knockdowns on", default = true },
		},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		provider = KNOCKDOWN,
		order = 23,
	},
	KnockdownTuning = {
		name = "KnockdownTuning",
		tab = "Attack",
		label = "Knockdown timers",
		description = "Duration override (0 = 45 s +3 s per launcher level) and the immunity after a knockdown.",
		target = "None",
		args = {
			durationSeconds = {
				kind = "integer",
				min = 0,
				max = 600,
				label = "Duration s (0 = normal)",
				presets = { 0, 20, 45, 90 },
				default = 0,
			},
			immunitySeconds = {
				kind = "integer",
				min = 0,
				max = 3600,
				label = "Immunity s",
				presets = { 0, 60, 180 },
				default = 180,
			},
		},
		argOrder = { "durationSeconds", "immunitySeconds" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		provider = KNOCKDOWN,
		order = 24,
	},
	KnockdownStats = {
		name = "KnockdownStats",
		tab = "Attack",
		label = "Knockdown stats",
		description = "Areas down, immune plots, rivals down and totals on this server.",
		target = "None",
		args = {},
		cooldown = 0.5,
		audited = false,
		confirm = false,
		color = "grey",
		provider = KNOCKDOWN,
		order = 25,
	},

	-- New Player Mode --------------------------------------------------------------------------------------
	NewPlayerMode = {
		name = "NewPlayerMode",
		tab = "NewPlayer",
		label = "Play as New Player",
		description = "Saves your real profile, then you play a brand-new throw-away profile. Nothing is saved; Robux purchases are off.",
		target = "None",
		args = {},
		cooldown = 10, -- the entry saves the real profile first (DataStore write spacing)
		audited = true,
		confirm = true,
		color = "yellow",
		provider = SANDBOX,
		order = 10,
	},
	ExitNewPlayerMode = {
		name = "ExitNewPlayerMode",
		tab = "NewPlayer",
		label = "Exit New Player Mode",
		description = "Your real profile comes back exactly as you left it.",
		target = "None",
		args = {},
		cooldown = 2,
		audited = true,
		confirm = true,
		color = "green",
		provider = SANDBOX,
		order = 11,
	},
}

AdminConfig.Commands = COMMANDS

-- Every built-in command name (stable order: tab, then order, then name).
local names: { string } = {}
for name in COMMANDS do
	table.insert(names, name)
end
table.sort(names, function(a: string, b: string): boolean
	local da, db = COMMANDS[a], COMMANDS[b]
	if da.tab ~= db.tab then
		return da.tab < db.tab
	end
	local oa, ob = da.order or 0, db.order or 0
	if oa ~= ob then
		return oa < ob
	end
	return a < b
end)
AdminConfig.CommandNames = table.freeze(names)

-- Deep-freeze every built-in definition so no module can loosen a schema at runtime (shared
-- preset arrays may already be frozen, hence the isfrozen guards).
local function freezeOnce(t: any)
	if not table.isfrozen(t) then
		table.freeze(t)
	end
end
for _, def in COMMANDS do
	for _, spec in def.args do
		if spec.values ~= nil then
			freezeOnce(spec.values)
		end
		if spec.labels ~= nil then
			freezeOnce(spec.labels)
		end
		if spec.presets ~= nil then
			freezeOnce(spec.presets)
		end
		freezeOnce(spec)
	end
	freezeOnce(def.args)
	if def.argOrder ~= nil then
		freezeOnce(def.argOrder)
	end
	freezeOnce(def)
end
freezeOnce(COMMANDS)

--------------------------------------------------------------------------------------------------
-- Wire payload types (server → admin client). Shared so both sides agree on the shape.
--------------------------------------------------------------------------------------------------

-- One audit log entry (AdminState.log).
export type AuditEntry = {
	id: number,
	time: number, -- os.time() (UTC seconds)
	adminName: string,
	adminUserId: number,
	command: string,
	args: string, -- sanitised summary of the VALIDATED arguments
	ok: boolean,
	result: string,
}

-- One row of the panel's player list (AdminState.players).
export type PlayerRow = {
	name: string,
	displayName: string,
	userId: number,
	isAdmin: boolean,
	loaded: boolean, -- profile loaded
	saving: string, -- profile save status ("ok" | "disabled" | "readOnly" | "lost" | "sandbox" | "none")
	cash: number,
	gems: number,
	area: number,
	rebirths: number,
	totalEarned: number,
	pingMs: number, -- -1 = unknown
	newPlayerMode: boolean,
	sessionSeconds: number,
	device: string, -- analytics device class or ""
}

-- A command as the panel sees it (static payload).
export type CommandInfo = {
	name: string,
	tab: Tab,
	label: string,
	description: string,
	target: TargetMode,
	args: { [string]: ArgSpec },
	argOrder: { string },
	confirm: boolean,
	color: string,
	order: number,
	registered: boolean, -- added at runtime by another system (AdminService.registerCommand)
}

export type RecentBan = {
	userId: number,
	name: string,
	durationSeconds: number,
	reason: string,
	time: number,
	byName: string,
}

-- AdminCommand result (remote AdminResult, to the caller only).
export type ResultPayload = { seq: number, ok: boolean, name: string, text: string }

return table.freeze(AdminConfig)
