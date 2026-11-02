--!strict
--[[
	Signal — a tiny, typed, pure-Luau event (no BindableEvent, no Instance overhead).

	Purpose:
		Server/client systems publish events to each other (BeastSpawned, BeastEliminated,
		RoundPhaseChanged, ...). A pure-Luau signal keeps arguments by reference (BindableEvents
		deep-copy tables and strip metatables), never crosses the network, and is cheap to fire.

	Behavior notes:
		- Handlers run synchronously in connection order, each inside task.spawn-free direct calls,
		  so a handler error is caught and reported without stopping later handlers.
		- Disconnecting during Fire is safe (we iterate over a snapshot).

	Example:
		local onScored = Signal.new() :: Signal.Signal<Player, number>
		local conn = onScored:Connect(function(player, points) print(player.Name, points) end)
		onScored:Fire(somePlayer, 10)
		conn:Disconnect()
]]

local Signal = {}
Signal.__index = Signal

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

type Handler = (...any) -> ()

type SignalData = {
	_handlers: { { fn: Handler, connection: Connection } },
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	Wait: (self: Signal<T...>) -> T...,
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> (),
	handlerCount: (self: Signal<T...>) -> number,
	placeholder: (self: Signal<T...>) -> Connection,
	settle: (self: Signal<T...>, anchor: Connection, since: number) -> (),
}

--[[ Creates a new signal. Cast the result to `Signal.Signal<Args...>` for typed handlers. ]]
function Signal.new(): Signal<...any>
	local self: SignalData = { _handlers = {} }
	return (setmetatable(self, Signal) :: any) :: Signal<...any>
end

--[[
	Connects a handler.
	@return Connection with :Disconnect().
]]
function Signal.Connect(self: any, fn: Handler): Connection
	local data = self :: SignalData
	local connection = {
		Connected = true,
	} :: any
	function connection.Disconnect(conn: Connection)
		if not conn.Connected then
			return
		end
		conn.Connected = false
		for index, entry in data._handlers do
			if entry.connection == conn then
				table.remove(data._handlers, index)
				break
			end
		end
	end
	table.insert(data._handlers, { fn = fn, connection = connection })
	return connection
end

--[[ Connects a handler that disconnects itself after the first fire. ]]
function Signal.Once(self: any, fn: Handler): Connection
	local connection: Connection
	connection = Signal.Connect(self, function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

--[[
	xpcall message handler: it runs AT the error site, before the stack unwinds, so the traceback
	shows the failing handler's own frames. (The old pcall + debug.traceback() ran after the
	unwind and only ever showed Signal.Fire, e.g. "Signal:99 Fire <- TycoonWorld:197", N2.)
	@param err the raised error value
	@return the error text followed by the traceback from the failing frame
]]
local function errorWithTraceback(err: any): string
	return debug.traceback(tostring(err), 2)
end

--[[
	Fires all handlers with the given arguments. Handler errors are reported (with the failing
	handler's traceback), never propagated, so one bad listener cannot break the others.
	Example: changed:Fire(newValue)
]]
function Signal.Fire(self: any, ...: any)
	local data = self :: SignalData
	-- Snapshot so handlers may connect/disconnect while we iterate.
	local snapshot = table.clone(data._handlers)
	for _, entry in snapshot do
		if entry.connection.Connected then
			local handler = entry.fn
			local ok: boolean, report: any = xpcall(handler :: any, errorWithTraceback, ...)
			if not ok then
				warn(`[Signal] handler error: {report}`)
			end
		end
	end
end

--[[ Yields the current thread until the next Fire and returns its arguments. ]]
function Signal.Wait(self: any): ...any
	local thread = coroutine.running()
	Signal.Once(self, function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

--[[ Disconnects every handler. ]]
function Signal.DisconnectAll(self: any)
	local data = self :: SignalData
	for _, entry in data._handlers do
		entry.connection.Connected = false
	end
	table.clear(data._handlers)
end

--[[ Alias of DisconnectAll so a Signal can be tracked by a Trove. ]]
function Signal.Destroy(self: any)
	Signal.DisconnectAll(self)
end

--[[
	Connection-order bookkeeping (UI/ScreenManager lazy screens, perf audit row 8). Handlers run
	in connection order, so a screen built later than it used to be (lazily, on first open) would
	run its Opened / Closed handlers after every screen built at boot. ScreenManager therefore
	reserves the screen's boot-time position with a placeholder and, after the late build, moves
	the handlers that build connected into that position:
		local anchor = signal:placeholder()       -- at register (boot) time
		local before = signal:handlerCount()      -- right before the late build
		build()                                   -- connects its handlers (appended)
		signal:settle(anchor, before)             -- moved to the anchor; anchor removed
]]

--[[ Number of connected handlers. ]]
function Signal.handlerCount(self: any): number
	return #(self :: SignalData)._handlers
end

--[[ Appends a no-op handler that marks a position; returns its connection (the anchor). ]]
function Signal.placeholder(self: any): Connection
	return Signal.Connect(self, function() end)
end

--[[
	Moves every handler connected after the first `since` ones (in order) to the anchor's
	position, then removes the anchor. A missing / already removed anchor changes nothing.
]]
function Signal.settle(self: any, anchor: Connection, since: number)
	local data = self :: SignalData
	local handlers = data._handlers
	local anchorIndex: number? = nil
	for index, entry in handlers do
		if entry.connection == anchor then
			anchorIndex = index
			break
		end
	end
	if anchorIndex == nil then
		return
	end
	local moved: { { fn: Handler, connection: Connection } } = {}
	for index = #handlers, math.max(since, anchorIndex) + 1, -1 do
		table.insert(moved, 1, table.remove(handlers, index) :: any)
	end
	anchor.Connected = false
	table.remove(handlers, anchorIndex)
	for offset, entry in moved do
		table.insert(handlers, anchorIndex + offset - 1, entry)
	end
end

return Signal
