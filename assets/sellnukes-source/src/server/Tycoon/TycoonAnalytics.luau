--!strict
--[[
	TycoonAnalytics — the tycoon's seam to AnalyticsService (B13), guarded and batched.

	Purpose
		The tycoon reports its trusted events (plot claimed, pads, clicks, income, upgrades, areas,
		rebirths, offline payouts, tutorial steps, renames, teleports) to the analytics recorders
		documented in Server/Services/AnalyticsService. The tycoon must work whether or not that
		module exists or is booted, so it is required lazily inside a pcall on first use; every call
		is pcall-guarded (recorders never throw, but analytics can never break gameplay).
		Income is reported per cycle by the payout loop (up to ~80 events/s per server), so it is
		summed per player per producer and flushed every FlushSeconds instead.

	Usage
		TycoonAnalytics.call("padBought", player, padId, false)
		TycoonAnalytics.income(player, producerId, amount, automated)   -- batched
		TycoonAnalytics.flush()                                          -- loop, every few seconds
		TycoonAnalytics.forget(player)                                   -- leave: flush + drop
]]

local ServerScriptService = game:GetService("ServerScriptService")

local TycoonAnalytics = {}

-- Seconds between income batch flushes.
TycoonAnalytics.FlushSeconds = 10

local service: any = nil
local resolved = false

-- The AnalyticsService module, required once (nil when missing / failing).
local function analytics(): any
	if resolved then
		return service
	end
	resolved = true
	local server = ServerScriptService:FindFirstChild("Server")
	local services = if server ~= nil then server:FindFirstChild("Services") else nil
	local module = if services ~= nil then services:FindFirstChild("AnalyticsService") else nil
	if module ~= nil and module:IsA("ModuleScript") then
		local ok, loaded = pcall(require, module)
		if ok and type(loaded) == "table" then
			service = loaded
		else
			warn(`[TycoonAnalytics] AnalyticsService failed to load: {loaded}`)
		end
	end
	return service
end

--[[
	Calls one AnalyticsService recorder by name, if it exists. Never throws, never yields.
	@param name string — recorder ("padBought", "producerClick", "tycoon", ...)
	@param ... any — its arguments
]]
function TycoonAnalytics.call(name: string, ...: any)
	local module = analytics()
	if module == nil then
		return
	end
	local recorder = module[name]
	if type(recorder) == "function" then
		pcall(recorder, ...)
	end
end

-- Pending income per player per producer: { [player] = { [producerId] = { click, auto } } }.
local pending: { [Player]: { [string]: { click: number, auto: number } } } = {}

--[[
	Adds one payout to the batch (flushed by flush()).
	@param player Player, producerId string, amount number, automated boolean
]]
function TycoonAnalytics.income(player: Player, producerId: string, amount: number, automated: boolean)
	if amount ~= amount or amount <= 0 or amount == math.huge then
		return
	end
	local byProducer = pending[player]
	if byProducer == nil then
		byProducer = {}
		pending[player] = byProducer
	end
	local entry = byProducer[producerId]
	if entry == nil then
		entry = { click = 0, auto = 0 }
		byProducer[producerId] = entry
	end
	if automated then
		entry.auto += amount
	else
		entry.click += amount
	end
end

-- Sends one player's batch.
local function flushPlayer(player: Player)
	local byProducer = pending[player]
	if byProducer == nil then
		return
	end
	pending[player] = nil
	for producerId, entry in byProducer do
		if entry.click > 0 then
			TycoonAnalytics.call("producerIncome", player, producerId, entry.click, false)
		end
		if entry.auto > 0 then
			TycoonAnalytics.call("producerIncome", player, producerId, entry.auto, true)
		end
	end
end

--[[ Sends every pending income batch. ]]
function TycoonAnalytics.flush()
	for player in pending do
		flushPlayer(player)
	end
end

--[[ Flushes and forgets a leaving player. ]]
function TycoonAnalytics.forget(player: Player)
	flushPlayer(player)
end

return TycoonAnalytics
