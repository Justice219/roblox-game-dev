--!strict
--[[
	PickerFocus — streams the attack target picker's target in for the player looking at it
	(owner R104: "you cant see peoples bases in the attack menu").

	Root cause it fixes: Workspace.StreamingEnabled with StreamOutBehavior Opportunistic streams
	content within StreamingTargetRadius (768) of each player's replication focus — their character —
	and drops what is outside. Another player's plot across the hub (900+ studs) or a Rival island
	(1080 studs out) was therefore never on the client; the picker's one-shot client
	RequestStreamAroundAsync is documented as temporary, so the camera flew over empty blue sky.

	What it does: AttackPickerFocus(slot) from the client (picker opened / target cycled / keep-alive;
	0 = picker closed). The server keeps ONE invisible, anchored, non-colliding focus part per player
	at Shared/Attack/PickerStream.focusPoint(slot, built areas) — owner R133: the middle of the
	target's BUILT base (`builtAreasOf`, the server-set SN_AttackAreas) — and registers it with
	Player:AddReplicationFocus (an EXTRA focus: the player's own surroundings keep streaming around
	the character). On 0 the focus lingers AttackConfig.Client.PickerStream.FocusLinger seconds (the
	launch cinematic flies to the target right after the picker closes), then
	Player:RemoveReplicationFocus + Destroy. A focus not refreshed for FocusExpire seconds (a client
	that never said "closed") and every focus of a leaving player are removed by the 1 Hz sweep /
	PlayerRemoving.

	Security (CLAUDE.md "never trust the client"): the only input is the slot number —
	PickerStream.readSlot (number, finite, integer, 0 or a valid target slot), a per-player token
	bucket (AttackConfig.RateLimits.PickerFocus), at most one part per player, connected through
	Remotes.onServerEvent (late events from departed players are dropped). The part carries no
	player id; moving it is a CFrame write. The player's own plot needs no extra focus (cleared).

	Performance: no per-frame work — one 1 Hz sweep over <= 8 entries; parts never collide / query /
	touch / cast shadows; streaming itself is the engine's.

	Analytics (attack family, AnalyticsConfig.Metrics.attack): view:<player|rival> per newly framed
	target slot, view:refused:<slot|rate> for refused intents.

	Connects to: Shared/Attack/PickerStream, Shared/Config/AttackConfig, Shared/Net/Remotes,
	Shared/Util/RateLimiter, Server/Attack/AttackAnalytics; started by Services/AttackService.Start;
	client side Client/Attack/PickerView.

	Example:
		PickerFocus.start()                 -- AttackService.Start
		PickerFocus.set(player, 9)          -- stream Rival 1 for this player (tests / admin)
		PickerFocus.set(player, 0)          -- picker closed: linger, then remove
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttackAnalytics = require(script.Parent.AttackAnalytics)
local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local AttackLogic = require(ReplicatedStorage.Shared.Attack.AttackLogic)
local PickerStream = require(ReplicatedStorage.Shared.Attack.PickerStream)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)

local PickerFocus = {}

local STREAM = AttackConfig.Client.PickerStream
local LIMIT = AttackConfig.RateLimits.PickerFocus
-- Workspace folder holding the focus parts (server-created; the parts are invisible markers).
local FOLDER_NAME = "SN_PickerFoci"
-- Seconds between two sweeps (expiry / linger).
local SWEEP_SECONDS = 1

-- One player's focus.
type Entry = {
	part: BasePart,
	slot: number, -- the framed target slot (0 = closed, lingering)
	added: boolean, -- AddReplicationFocus succeeded (so RemoveReplicationFocus is due)
	expiresAt: number, -- os.clock() deadline (refresh / linger)
}

local entries: { [Player]: Entry } = {}
local limiter = RateLimiter.new(LIMIT.capacity, LIMIT.refill)
local folder: Folder? = nil
local started = false

-- The focus folder (created once; recreated if something removed it).
local function focusFolder(): Folder
	local existing = folder
	if existing ~= nil and existing.Parent == Workspace then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = Workspace
	folder = created
	return created
end

-- A new invisible, physics-free focus part (one per player, reused while it lives).
local function newPart(): BasePart
	local part = Instance.new("Part")
	part.Name = "Focus"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(1, 1, 1)
	part.Locked = true
	part.Parent = focusFolder()
	return part
end

--[[
	The built areas of the player who owns plot `slot`, from the server-set SN_AttackAreas attribute
	(AttackService publishes it; never client data). nil for a Rival island, an empty plot, a test
	bot's plot or a player with nothing built yet: PickerFrame then uses the whole plot / island.
	At most PlotCount players are scanned, only on a (rate-limited) intent.
	@param slot number — a valid target slot
	@return { number }?
	Example: builtAreasOf(3) --> { 1, 2 }
]]
local function builtAreasOf(slot: number): { number }?
	if AttackGeometry.rivalOfSlot(slot) ~= nil then
		return nil
	end
	for _, other in Players:GetPlayers() do
		if other:GetAttribute(AttackConfig.Attr.Plot) == slot then
			local areas = AttackLogic.decodeAreas(other:GetAttribute(AttackConfig.Attr.Areas))
			return if #areas > 0 then areas else nil
		end
	end
	return nil
end

-- Removes a player's focus (RemoveReplicationFocus + Destroy). Never throws.
local function drop(player: Player)
	local entry = entries[player]
	if entry == nil then
		return
	end
	entries[player] = nil
	if entry.added then
		pcall(function()
			player:RemoveReplicationFocus(entry.part)
		end)
	end
	entry.part:Destroy()
end

--[[
	Points a player's stream focus at a target slot (0 = the picker closed: keep the current focus
	for FocusLinger seconds, then drop it). The player's own plot needs no extra focus.
	@param player Player
	@param slot number — 0 or a valid target slot (callers validate with PickerStream.readSlot)
	@return boolean — true when a focus now streams `slot`
]]
function PickerFocus.set(player: Player, slot: number): boolean
	local entry = entries[player]
	local ownPlot = player:GetAttribute(AttackConfig.Attr.Plot)
	if slot == 0 or (type(ownPlot) == "number" and ownPlot == slot) then
		if entry ~= nil then
			if slot == 0 then
				-- Closed: keep streaming the last target briefly (launch cinematic), then drop.
				entry.slot = 0
				entry.expiresAt = math.min(entry.expiresAt, os.clock() + STREAM.FocusLinger)
			else
				drop(player)
			end
		end
		return false
	end
	if AttackGeometry.validTarget(slot) == nil then
		return false
	end
	local now = os.clock()
	if entry == nil then
		entry = { part = newPart(), slot = 0, added = false, expiresAt = now }
		entries[player] = entry
	end
	local current = entry :: Entry
	current.expiresAt = now + STREAM.FocusExpire
	-- Owner R133: the focus sits on the middle of the target's BUILT footprint (a new player's
	-- garage is then well inside StreamingMinRadius), recomputed on every keep-alive so it follows
	-- a growing base.
	local point = PickerStream.focusPoint(slot, builtAreasOf(slot))
	if current.slot == slot and current.added then
		if (current.part.Position - point).Magnitude > 1 then
			current.part.CFrame = CFrame.new(point)
		end
		return true -- keep-alive
	end
	current.slot = slot
	current.part.CFrame = CFrame.new(point)
	if not current.added then
		local ok, err = pcall(function()
			player:AddReplicationFocus(current.part)
		end)
		current.added = ok
		if not ok then
			warn(`[PickerFocus] AddReplicationFocus failed: {err}`)
		end
	end
	AttackAnalytics.record(player, if AttackGeometry.rivalOfSlot(slot) ~= nil then "view:rival" else "view:player")
	return current.added
end

-- AttackPickerFocus(slot) handler: rate limit, validate, apply. Junk is dropped silently.
local function onFocus(player: Player, raw: unknown)
	if not limiter:Allow(player) then
		AttackAnalytics.record(player, "view:refused:rate")
		return
	end
	local slot = PickerStream.readSlot(raw)
	if slot == nil then
		AttackAnalytics.record(player, "view:refused:slot")
		return
	end
	PickerFocus.set(player, slot)
end

-- Drops expired / lingering-out foci (1 Hz).
local function sweep()
	local now = os.clock()
	for player, entry in entries do
		if now >= entry.expiresAt or player.Parent ~= Players then
			drop(player)
		end
	end
end

--[[ Number of live foci + the slot each player streams (QA / admin diagnostics). ]]
function PickerFocus.stats(): { count: number, slots: { [number]: number } }
	local slots: { [number]: number } = {}
	local count = 0
	for player, entry in entries do
		count += 1
		slots[player.UserId] = entry.slot
	end
	return { count = count, slots = slots }
end

--[[ Connects the remote, the sweep and the leave cleanup (idempotent; AttackService.Start). ]]
function PickerFocus.start()
	if started then
		return
	end
	started = true
	Remotes.onServerEvent("AttackPickerFocus", onFocus)
	Players.PlayerRemoving:Connect(function(player: Player)
		drop(player)
		limiter:Forget(player)
	end)
	task.spawn(function()
		while true do
			task.wait(SWEEP_SECONDS)
			sweep()
		end
	end)
end

return PickerFocus
