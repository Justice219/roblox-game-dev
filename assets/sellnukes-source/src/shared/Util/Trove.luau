--!strict
--[[
	Trove — a cleanup container ("maid").

	Purpose:
		Every system in RoBeasts creates connections, instances and threads whose lifetime is tied to
		something else (a beast, a round, a map, a UI screen). A Trove collects those resources so a
		single `:Clean()` call releases all of them. This is how we avoid the classic Roblox leaks
		(connections that outlive their beast, threads that keep running after a map unloads).

	Connects to:
		Used by nearly every service/controller (BeastService, MapService, maps, UI screens, ...).

	Supported items:
		- RBXScriptConnection  -> :Disconnect()
		- Instance             -> :Destroy()
		- function             -> called with no arguments
		- thread               -> task.cancel()
		- Trove                -> :Clean() (nested troves)
		- table with :Destroy() / :Disconnect() method (e.g. our Signal connections)

	Example:
		local trove = Trove.new()
		trove:Add(part)                                        -- destroyed on Clean
		trove:Connect(RunService.Heartbeat, function(dt) end)  -- disconnected on Clean
		trove:Add(function() print("cleaned!") end)            -- called on Clean
		trove:Clean()
]]

local Trove = {}
Trove.__index = Trove

type TroveData = {
	_items: { any },
	_cleaning: boolean,
}

export type Trove = typeof(setmetatable({} :: TroveData, Trove))

--[[
	Creates an empty Trove.
	@return Trove
]]
function Trove.new(): Trove
	local self: TroveData = {
		_items = {},
		_cleaning = false,
	}
	return setmetatable(self, Trove)
end

--[[
	Releases a single tracked item according to its type.
	Errors inside cleanup are caught and reported so one bad item never prevents the rest from
	being cleaned (important during map unloads where dozens of items are released at once).
]]
local function cleanupItem(item: any)
	local itemType = typeof(item)
	local ok, err = pcall(function()
		if itemType == "RBXScriptConnection" then
			item:Disconnect()
		elseif itemType == "Instance" then
			item:Destroy()
		elseif itemType == "function" then
			item()
		elseif itemType == "thread" then
			-- Cancelling the currently running thread errors; skip it in that case.
			if coroutine.running() ~= item then
				task.cancel(item)
			end
		elseif itemType == "table" then
			local object = item :: {
				Clean: ((any) -> ())?,
				Destroy: ((any) -> ())?,
				Disconnect: ((any) -> ())?,
			}
			local clean = object.Clean
			local destroy = object.Destroy
			local disconnect = object.Disconnect
			if clean ~= nil then
				clean(object)
			elseif destroy ~= nil then
				destroy(object)
			elseif disconnect ~= nil then
				disconnect(object)
			end
		end
	end)
	if not ok then
		warn(`[Trove] cleanup error: {err}`)
	end
end

--[[
	Tracks an item and returns it unchanged (so creation and tracking can be one expression).
	@param item  Any supported item (see header).
	@return The same item.
	Example: local part = trove:Add(Instance.new("Part"))
]]
function Trove.Add<T>(self: Trove, item: T): T
	if self._cleaning then
		-- Adding during cleanup would leak the item; release it immediately instead.
		cleanupItem(item)
		return item
	end
	table.insert(self._items, item)
	return item
end

--[[
	Connects to an RBXScriptSignal and tracks the connection.
	@return The RBXScriptConnection.
]]
function Trove.Connect(self: Trove, signal: RBXScriptSignal, fn: (...any) -> ()): RBXScriptConnection
	local connection = signal:Connect(fn)
	self:Add(connection)
	return connection
end

--[[
	Creates a child Trove that is cleaned when this one is cleaned.
	Useful for sub-lifetimes (e.g. a per-round trove inside a per-server trove).
]]
function Trove.Extend(self: Trove): Trove
	local child = Trove.new()
	self:Add(child)
	return child
end

--[[
	Stops tracking an item and releases it right away.
	@return true if the item was tracked.
]]
function Trove.Remove(self: Trove, item: any): boolean
	local index = table.find(self._items, item)
	if index == nil then
		return false
	end
	table.remove(self._items, index)
	cleanupItem(item)
	return true
end

--[[
	Releases every tracked item (in reverse order of addition, so dependents are cleaned before the
	things they depend on). The Trove can be reused afterwards.
]]
function Trove.Clean(self: Trove)
	if self._cleaning then
		return
	end
	self._cleaning = true
	local items = self._items
	self._items = {}
	for i = #items, 1, -1 do
		cleanupItem(items[i])
	end
	self._cleaning = false
end

--[[ Alias so a Trove can itself be tracked by anything that calls :Destroy(). ]]
function Trove.Destroy(self: Trove)
	self:Clean()
end

return Trove
