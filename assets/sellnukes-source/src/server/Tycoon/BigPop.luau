--!strict
--[[
	BigPop — the server-wide "Big Pop" broadcast of owner R89 (spec §1): a Galaxy+ batch, a Mythic+
	hatch or a rebirth → one banner on every client, a system chat line ("Alex popped a GALAXY
	batch! 1 in 2,500") and toy fireworks over that player's spot.

	Throttle + coalesce (all server-side, so a busy server never floods chat):
		- per player: at most one entry per FlavorConfig.BigPop.PlayerCooldown seconds (any kind);
		- queue: at most MaxPending entries, ONE per player (a better entry replaces theirs; when
		  full, a better entry evicts the weakest, otherwise it is counted in `more`);
		- broadcast: at most one per GapSeconds server-wide, carrying the best MaxPerBroadcast
		  entries (score order) + `more` (how many other pops were folded in). The first pop after a
		  quiet spell goes out on the next step (FlavorService steps this every FlushSeconds).
	Text: entries carry config-derived labels only (flavour names, pet names, world names) + the
	player's DisplayName; clients compose the line (no player free text → no TextService filter;
	display names are already Roblox-moderated). Kill switch: setEnabled(false) (admin).

	API
		BigPop.announce(player, entry) -> boolean      queue one entry (false = throttled / off)
		BigPop.step(now)                                broadcast when due (os.clock seconds)
		BigPop.setEnabled(on) / BigPop.isEnabled()
		BigPop.forget(player)                           PlayerRemoving cleanup
		BigPop.stats() -> { sent, entries, dropped }    admin / analytics counters
		BigPop.positionOf(player) -> Vector3?           the character's spot (fireworks centre)

	Connects to: Server/Tycoon/FlavorService (batches, hatch / rebirth listeners, step loop),
	Shared/Net/Remotes ("BigPop", all clients), Shared/Config/FlavorConfig (BigPop), the client
	UI/Screens/BigPop (banner + chat line) + Client/Tycoon/FlavorController (fireworks).

	Example:
		BigPop.announce(player, { kind = "batch", id = "galaxy", label = "GALAXY batch",
			oneIn = 2500, score = 40, at = anchor.Position })
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)

local Config = FlavorConfig.BigPop

export type Kind = "batch" | "hatch" | "rebirth"

-- What a caller announces (the server fills userId / name).
export type Announcement = {
	kind: Kind,
	id: string, -- flavour id / pet rarity id / world id (client colour + icon)
	label: string, -- config-derived noun ("GALAXY batch", "MYTHIC Golden Nukey", "REBIRTH #3")
	oneIn: number, -- odds shown ("1 in 2,500"); 0 = none
	score: number, -- coalescing priority (higher wins)
	at: Vector3?, -- fireworks centre (nil = no fireworks)
}

-- One queued / sent entry (the wire shape of BigPop payload entries).
type Entry = {
	userId: number,
	name: string,
	kind: Kind,
	id: string,
	label: string,
	oneIn: number,
	score: number,
	at: Vector3?,
}

local BigPop = {}

local enabled = true
local pending: { Entry } = {}
local folded = 0 -- entries dropped by the queue since the last broadcast (sent as `more`)
local lastBroadcast = -math.huge
local lastByUser: { [number]: number } = {}
local counters = { sent = 0, entries = 0, dropped = 0 }

-- Monotonic seconds (os.clock is fine for throttles; never trusted for anything persistent).
local function clock(): number
	return os.clock()
end

--[[
	The character's root position (fireworks centre for hatches / rebirths), or nil.
	@param player Player
	@return Vector3?
]]
function BigPop.positionOf(player: Player): Vector3?
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- A sanitised copy of an announcement (labels capped, numbers finite) or nil for junk.
local function entryOf(player: Player, announcement: Announcement): Entry?
	local kind = announcement.kind
	if kind ~= "batch" and kind ~= "hatch" and kind ~= "rebirth" then
		return nil
	end
	if type(announcement.id) ~= "string" or type(announcement.label) ~= "string" then
		return nil
	end
	local oneIn = announcement.oneIn
	local score = announcement.score
	local at = announcement.at
	return {
		userId = player.UserId,
		name = string.sub(player.DisplayName, 1, 40),
		kind = kind,
		id = string.sub(announcement.id, 1, 24),
		label = string.sub(announcement.label, 1, 48),
		oneIn = if type(oneIn) == "number"
				and oneIn == oneIn
				and oneIn >= 1
				and oneIn < 1e12
			then math.floor(oneIn)
			else 0,
		score = if type(score) == "number" and score == score then score else 0,
		at = if typeof(at) == "Vector3" then at else nil,
	}
end

--[[
	Queues a Big Pop entry for `player` (never yields).
	@param player Player — must still be in the game
	@param announcement Announcement
	@return boolean — true when queued (false: off, throttled, junk, or folded into `more`)
]]
function BigPop.announce(player: Player, announcement: Announcement): boolean
	if not enabled or player.Parent ~= Players then
		return false
	end
	local entry = entryOf(player, announcement)
	if entry == nil then
		return false
	end
	-- One entry per player: while theirs is still queued a better one replaces it (the cooldown
	-- started with the queued one).
	for index, queued in pending do
		if queued.userId == entry.userId then
			if entry.score > queued.score then
				pending[index] = entry
				return true
			end
			counters.dropped += 1
			return false
		end
	end
	local now = clock()
	local last = lastByUser[entry.userId]
	if last ~= nil and now - last < Config.PlayerCooldown then
		counters.dropped += 1
		return false
	end
	if #pending >= Config.MaxPending then
		local weakest, weakestIndex = math.huge, 0
		for index, queued in pending do
			if queued.score < weakest then
				weakest, weakestIndex = queued.score, index
			end
		end
		if entry.score <= weakest then
			folded += 1
			counters.dropped += 1
			return false
		end
		lastByUser[pending[weakestIndex].userId] = nil -- the evicted player may pop again
		pending[weakestIndex] = entry
		folded += 1
	else
		table.insert(pending, entry)
	end
	lastByUser[entry.userId] = now
	return true
end

--[[
	Broadcasts the queue when the global gap allows (FlavorService calls this every flush).
	@param now number? — os.clock seconds (default now)
	@return boolean — true when a broadcast went out
]]
function BigPop.step(now: number?): boolean
	if #pending == 0 then
		return false
	end
	local t = now or clock()
	if t - lastBroadcast < Config.GapSeconds then
		return false
	end
	table.sort(pending, function(a: Entry, b: Entry): boolean
		return a.score > b.score
	end)
	local entries = {}
	for index = 1, math.min(#pending, Config.MaxPerBroadcast) do
		local entry = pending[index]
		table.insert(entries, {
			userId = entry.userId,
			name = entry.name,
			kind = entry.kind,
			id = entry.id,
			label = entry.label,
			oneIn = entry.oneIn,
			at = entry.at,
		})
	end
	local more = math.max(0, #pending - #entries) + folded
	table.clear(pending)
	folded = 0
	lastBroadcast = t
	counters.sent += 1
	counters.entries += #entries
	Remotes.fireAllClients("BigPop", { entries = entries, more = more })
	return true
end

--[[ Turns the broadcast on / off (admin kill switch). Off also drops anything queued. ]]
function BigPop.setEnabled(on: boolean)
	enabled = on == true
	if not enabled then
		table.clear(pending)
		folded = 0
	end
end

--[[ True while Big Pops broadcast. ]]
function BigPop.isEnabled(): boolean
	return enabled
end

--[[ Forgets a leaving player (their queued entry still goes out: it already happened). ]]
function BigPop.forget(player: Player)
	lastByUser[player.UserId] = nil
end

--[[ Counters since boot: broadcasts sent, entries carried, entries throttled / folded. ]]
function BigPop.stats(): { sent: number, entries: number, dropped: number }
	return table.clone(counters)
end

return BigPop
