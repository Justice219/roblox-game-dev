--!strict
--[[
	JuiceLoop — the ONE Heartbeat of the juice pass (owner R71). Juice modules register a step
	function once and call JuiceLoop.wake() whenever they start something animated (a combo label,
	a fireworks show, an upgrade glow). The connection exists only while some step still reports
	work and disconnects itself the frame every step returns false, so an idle game pays nothing.

	A step that errors is reported once and dropped, so one broken effect never stops the others.

	Connects to: Client/Tycoon/Fx/{ClickCombo, Fireworks, ProducerJuice, JuiceController}.

	Example:
		JuiceLoop.add("labels", function(now) return animateLabels(now) end)
		JuiceLoop.wake()
]]

local RunService = game:GetService("RunService")

export type Step = (now: number) -> boolean

local JuiceLoop = {}

local steps: { { name: string, fn: Step } } = {}
local connection: RBXScriptConnection? = nil

-- One frame: every step; disconnect when none reports more work.
local function frame()
	local now = os.clock()
	local busy = false
	local index = 1
	while index <= #steps do
		local entry = steps[index]
		local ok, more = pcall(entry.fn, now)
		if not ok then
			warn(`[JuiceLoop] step {entry.name} failed and was removed: {more}`)
			table.remove(steps, index)
			continue
		end
		if more == true then
			busy = true
		end
		index += 1
	end
	if not busy and connection ~= nil then
		connection:Disconnect()
		connection = nil
	end
end

--[[
	Registers a step (once per name).
	@param name label for warnings
	@param fn   (now: os.clock()) -> true while it has more to animate
]]
function JuiceLoop.add(name: string, fn: Step)
	for _, entry in steps do
		if entry.name == name then
			return
		end
	end
	table.insert(steps, { name = name, fn = fn })
end

--[[ Makes sure the Heartbeat runs (call after starting any animated effect). ]]
function JuiceLoop.wake()
	if connection == nil and #steps > 0 then
		connection = RunService.Heartbeat:Connect(frame)
	end
end

--[[ True while the Heartbeat is connected (Studio probes: idle = false). ]]
function JuiceLoop.running(): boolean
	return connection ~= nil
end

return JuiceLoop
