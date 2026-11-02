--!strict
--[[
	RequestMemory — per-player request-id idempotency for HatchEgg / OpenCrate (RoBeasts pattern).

	Why: a client may resend a request (lag, double tap, reconnect of the remote queue). The
	server remembers the reply of each player's last `capacity` request ids; a repeated id gets the
	SAME reply back and is never charged or rolled twice. A per-player in-flight flag also refuses a
	second request while one is being processed (the handlers may yield on PolicyService).

	Bounded: at most `capacity` replies per player, oldest evicted first; `forget(player)` on
	PlayerRemoving drops everything (strong Player keys, no weak tables).

	Connects to: Server/Services/PetService (hatches), Server/Services/CrateService (opens),
	tests/pets-logic.luau (eviction + idempotency).

	Example:
		local memory = RequestMemory.new(32)
		local previous = memory:get(player, requestId)
		if previous then return previous end      -- resend: same reply, no second charge
		...
		memory:remember(player, requestId, payload)
]]

export type RequestMemory<T> = {
	capacity: number,
	byPlayer: { [any]: { order: { number }, results: { [number]: T } } },
	busy: { [any]: boolean },
	get: (self: RequestMemory<T>, player: any, requestId: number) -> T?,
	remember: (self: RequestMemory<T>, player: any, requestId: number, payload: T) -> (),
	tryBegin: (self: RequestMemory<T>, player: any) -> boolean,
	finish: (self: RequestMemory<T>, player: any) -> (),
	forget: (self: RequestMemory<T>, player: any) -> (),
}

local RequestMemory = {}

--[[ The remembered reply for `requestId`, or nil. ]]
local function get<T>(self: RequestMemory<T>, player: any, requestId: number): T?
	local memory = self.byPlayer[player]
	return if memory ~= nil then memory.results[requestId] else nil
end

--[[ Remembers a reply (bounded FIFO; re-remembering an id keeps its slot). ]]
local function remember<T>(self: RequestMemory<T>, player: any, requestId: number, payload: T)
	local memory = self.byPlayer[player]
	if memory == nil then
		memory = { order = {}, results = {} }
		self.byPlayer[player] = memory
	end
	if memory.results[requestId] == nil then
		table.insert(memory.order, requestId)
	end
	memory.results[requestId] = payload
	while #memory.order > self.capacity do
		local oldest = table.remove(memory.order, 1)
		if oldest ~= nil then
			memory.results[oldest] = nil
		end
	end
end

--[[ Marks the player busy. @return false when a request is already in flight ]]
local function tryBegin<T>(self: RequestMemory<T>, player: any): boolean
	if self.busy[player] then
		return false
	end
	self.busy[player] = true
	return true
end

--[[ Clears the in-flight flag. ]]
local function finish<T>(self: RequestMemory<T>, player: any)
	self.busy[player] = nil
end

--[[ Drops everything kept for the player (PlayerRemoving). ]]
local function forget<T>(self: RequestMemory<T>, player: any)
	self.byPlayer[player] = nil
	self.busy[player] = nil
end

--[[
	A new memory keeping the last `capacity` replies per player.
	Example: local memory = RequestMemory.new(32)
]]
function RequestMemory.new<T>(capacity: number): RequestMemory<T>
	return {
		capacity = math.max(1, math.floor(capacity)),
		byPlayer = {},
		busy = {},
		get = get,
		remember = remember,
		tryBegin = tryBegin,
		finish = finish,
		forget = forget,
	}
end

return table.freeze(RequestMemory)
