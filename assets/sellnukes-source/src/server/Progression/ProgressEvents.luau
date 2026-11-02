--!strict
--[[
	ProgressEvents — the one server-side bus that every gameplay success path fires so the R78
	progression systems (Quests, Nuke Pass) can count things without each service knowing who
	listens (spec docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md §1.1).

	Purpose:
		Missions, trophies and the season pass all need the same facts ("a pad was bought", "3 eggs
		hatched"). Instead of TycoonService / PetService / LuckySpinService ... requiring
		QuestService (boot-order coupling, cycles), each success path fires ONE non-yielding line
		here, right next to its existing AnalyticsService call. Listeners subscribe in their Start().

	Rules (security + performance):
		- Fire ONLY from authoritative server success paths (after the state change committed),
		  never from a client claim. Amounts are computed by the server.
		- `progress` validates stat ids against STATS and clamps amounts to [1, MAX_AMOUNT] whole
		  numbers; anything else is dropped silently (a bad call must never break the caller).
		- Firing never yields and never throws into the caller (Signal catches handler errors).
		- `playMinute` is fired by QuestService's own once-per-60 s tick, never per frame.

	API:
		ProgressEvents.progress(player, stat, amount?)   amount defaults to 1
		ProgressEvents.xp(player, amount, source)        Nuke Pass XP (QuestService → PassService)
		ProgressEvents.Progress: Signal<Player, Stat, number>
		ProgressEvents.Xp: Signal<Player, number, string>
		ProgressEvents.isStat(value) -> boolean

	Connects to: Server/Services/QuestService (Progress listener, Xp source),
	Server/Services/PassService (Xp listener), and the firing services listed in spec §1.1.

	Example:
		-- TycoonService, after a pad purchase committed:
		ProgressEvents.progress(player, "pad")
		-- PetService, after a triple hatch committed:
		ProgressEvents.progress(player, "hatch", 3)
		-- PassService:
		ProgressEvents.Xp:Connect(function(player, amount, source) ... end)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)

-- Every stat a success path may fire (spec §1.1). Quest / trophy configs reference these ids.
export type Stat =
	"click"
	| "pad"
	| "upgrade"
	| "manager"
	| "area"
	| "hatch"
	| "crate"
	| "spin"
	| "daily"
	| "gift"
	| "rebirth"
	| "lucky"
	| "turkey"
	| "playMinute"
	| "world"
	-- Owner R89 Surprise Batches: special-flavour batches in the world the player is in, credited
	-- through FlavorService's token bucket (FlavorConfig.QuestCredit), never per raw batch.
	| "flavor"
	-- Owner R90 Mega Lever + Tip Jar (Server/Kinetic): one Mega Lever pull / one Tip Jar payout,
	-- fired after the payout was granted (cooldown / min-fill rules make them rate-bounded).
	| "lever"
	| "tipjar"

local STATS: { [string]: boolean } = table.freeze({
	click = true,
	pad = true,
	upgrade = true,
	manager = true,
	area = true,
	hatch = true,
	crate = true,
	spin = true,
	daily = true,
	gift = true,
	rebirth = true,
	lucky = true,
	turkey = true,
	playMinute = true,
	world = true,
	flavor = true, -- owner R89 (Server/Tycoon/FlavorService)
	lever = true, -- owner R90 (Server/Kinetic/MegaLever)
	tipjar = true, -- owner R90 (Server/Kinetic/TipJar)
} :: { [string]: boolean })

-- Largest single increment accepted (a bulk upgrade buys at most a few hundred levels; a triple
-- hatch is 3). Anything bigger is a bug, so it is clamped rather than trusted.
local MAX_AMOUNT = 1000
-- Largest XP grant accepted in one call (the biggest quest reward is a few hundred XP).
local MAX_XP = 5000

local ProgressEvents = {}

ProgressEvents.Progress = Signal.new() :: Signal.Signal<Player, Stat, number>
ProgressEvents.Xp = Signal.new() :: Signal.Signal<Player, number, string>

--[[
	True when `value` is a known stat id.
	@param value unknown
	@return boolean
]]
function ProgressEvents.isStat(value: unknown): boolean
	return type(value) == "string" and STATS[value] == true
end

--[[
	Normalises an amount: whole number in [1, max]; nil → 1; NaN / inf / non-number → nil (drop).
]]
local function cleanAmount(amount: unknown, max: number): number?
	if amount == nil then
		return 1
	end
	if type(amount) ~= "number" or amount ~= amount or amount == math.huge or amount == -math.huge then
		return nil
	end
	local whole = math.floor(amount)
	if whole < 1 then
		return nil
	end
	return math.min(whole, max)
end

--[[
	Reports that `player` did `stat` `amount` times (server success paths only).
	@param player Player — must still be in the game (a departed player is ignored)
	@param stat Stat — one of STATS
	@param amount number? — defaults to 1; clamped to [1, 1000]
]]
function ProgressEvents.progress(player: Player, stat: Stat, amount: number?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent == nil then
		return
	end
	if not ProgressEvents.isStat(stat) then
		return
	end
	local clean = cleanAmount(amount, MAX_AMOUNT)
	if clean == nil then
		return
	end
	ProgressEvents.Progress:Fire(player, stat, clean)
end

--[[
	Grants Nuke Pass XP (fired by QuestService on claims; PassService listens and applies caps).
	@param player Player
	@param amount number — whole, clamped to [1, 5000]
	@param source string — analytics label ("starter", "daily", "chest", "trophy", "play")
]]
function ProgressEvents.xp(player: Player, amount: number, source: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent == nil then
		return
	end
	if type(source) ~= "string" or source == "" or #source > 24 then
		return
	end
	local clean = cleanAmount(amount, MAX_XP)
	if clean == nil then
		return
	end
	ProgressEvents.Xp:Fire(player, clean, source)
end

return table.freeze(ProgressEvents)
