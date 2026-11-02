--!strict
--[[
	TimeQueue — a binary min-heap of timed events (the nuke impact schedule).

	Why: hundreds of nukes can be in flight (barrages). One heap + one Heartbeat check of its head
	costs O(1) per frame when nothing is due and O(log n) per event, with no per-nuke threads or
	task.delay closures.

	Example:
		local queue = TimeQueue.new()
		queue:push(serverTime + 6.2, nuke)
		while queue:peekTime() <= now do local _, item = queue:pop() ... end
]]

local TimeQueue = {}
TimeQueue.__index = TimeQueue

export type TimeQueue<T> = typeof(setmetatable({} :: { times: { number }, items: { T }, size: number }, TimeQueue))

--[[ Creates an empty queue. ]]
function TimeQueue.new<T>(): TimeQueue<T>
	return setmetatable({ times = {}, items = {}, size = 0 }, TimeQueue) :: any
end

-- Swaps two heap slots.
local function swap(self: any, a: number, b: number)
	self.times[a], self.times[b] = self.times[b], self.times[a]
	self.items[a], self.items[b] = self.items[b], self.items[a]
end

--[[
	Adds an item due at `time`.
	@param time number — any finite number (earlier = popped first)
	@param item T
]]
function TimeQueue.push<T>(self: TimeQueue<T>, time: number, item: T)
	self.size += 1
	local index = self.size
	self.times[index] = time
	self.items[index] = item
	while index > 1 do
		local parent = index // 2
		if self.times[parent] <= self.times[index] then
			break
		end
		swap(self, parent, index)
		index = parent
	end
end

--[[ The earliest due time, or math.huge when empty. ]]
function TimeQueue.peekTime<T>(self: TimeQueue<T>): number
	return if self.size > 0 then self.times[1] else math.huge
end

--[[
	Removes and returns the earliest item.
	@return (number?, T?) — (time, item), nil when empty
]]
function TimeQueue.pop<T>(self: TimeQueue<T>): (number?, T?)
	if self.size == 0 then
		return nil, nil
	end
	local time, item = self.times[1], self.items[1]
	local last = self.size
	self.times[1], self.items[1] = self.times[last], self.items[last]
	self.times[last] = nil :: any
	self.items[last] = nil :: any
	self.size -= 1
	local index = 1
	while true do
		local left, right = index * 2, index * 2 + 1
		local smallest = index
		if left <= self.size and self.times[left] < self.times[smallest] then
			smallest = left
		end
		if right <= self.size and self.times[right] < self.times[smallest] then
			smallest = right
		end
		if smallest == index then
			break
		end
		swap(self, smallest, index)
		index = smallest
	end
	return time, item
end

--[[ Number of queued items. ]]
function TimeQueue.count<T>(self: TimeQueue<T>): number
	return self.size
end

return TimeQueue
