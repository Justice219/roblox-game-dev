--!strict
--[[
	ClientPerfReporter — measures this client's performance and reports it to the server about once
	a minute (ported from RoBeasts' ClientPerfController). Measurement only: nothing here changes
	gameplay, quality or rewards.

	What one report (ClientPerfLogic wire v4, a 188-byte buffer on the ClientPerf remote) carries:
		- frame time: ONE per-frame accumulator (RunService.PreRender, MicroProfiler label
		  "SellNukes.ClientPerf") counting rendered frames into a fixed histogram;
		- every SampleIntervalSeconds (5 s): Stats:GetTotalMemoryUsageMb(), Stats.DataReceiveKbps
		  and LocalPlayer:GetNetworkPing() (ms);
		- every MemoryTags.IntervalSeconds (30 s): per-group memory tags (when the engine tracks
		  them) and Stats.InstanceCount, plus the session minutes (leak check by session age);
		- boot seconds once per session: the LocalPlayer attribute ClientPerfConfig.BootAttribute
		  the join loading screen sets at its hand-off (how long the player really waited), else
		  `time()` when the loading gate opens without it (no loading screen in this build). Until
		  R78 the `time()` fallback was taken at start, BEFORE the loading screen finished, so
		  every device reported ~1 s and the real wait was never measured;
		- with it (wire v4, owner R122) the loading screen's boot-step block: the LocalPlayer
		  attributes BootStep<step> (each step's completion second) and BootEnd (the hand-off
		  reason) the Loader sets just before BootSeconds. The report carrying the boot goes out as
		  soon as the boot is known (not at the next 20 s / 60 s tick), so players who leave in
		  the first minute — the bounce Roblox ranks on — are measured too;
		- plot-ready seconds: `plotReady(seconds)` (the tycoon client calls it when the player's
		  plot finished streaming / building in);
		- client FX instance count (Workspace.ClientFX + Terrain descendants) at report time.
	The device class is ClientPerfLogic.reportClass(DeviceProfile class, keyboard): a touch-first
	device WITH a keyboard reports as "TouchLaptop" (analytics only).
	First report after FirstReportSeconds (20 s), then every ReportIntervalSeconds (60 s), on a
	teleport start, and once early when the boot time arrives (the next report then follows
	FirstReportSeconds later when it was the first one). The server (Server/Analytics/
	ClientPerfIngest) treats every value as a claim and counts the boot once per session.

	Performance: per frame one bucket lookup + two adds on a reused window; sampling and sending run
	from the same callback on os.clock() deadlines (no extra threads, no per-frame allocation).

	Example:
		ClientPerfReporter.start()
		ClientPerfReporter.plotReady(3.4)
		print(ClientPerfReporter.reportsSent())
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ClientPerfConfig = require(ReplicatedStorage.Shared.Analytics.ClientPerfConfig)
local ClientPerfLogic = require(ReplicatedStorage.Shared.Analytics.ClientPerfLogic)
local DeviceProfile = require(ReplicatedStorage.Shared.Util.DeviceProfile)
local LoadingGate = require(script.Parent.Parent.UI.Widgets.LoadingGate)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)

local ClientPerfReporter = {}

local localPlayer = Players.LocalPlayer
local window: ClientPerfLogic.Window = ClientPerfLogic.newWindow(os.clock())
local remote: RemoteEvent? = nil -- resolved once on a background thread (Remotes.event may yield)
local nextSampleAt = 0
local reportInterval = ClientPerfConfig.FirstReportSeconds
local bootTaken = false
-- True once the boot is recorded and not sent yet: the next frame with enough data sends it.
local bootDue = false
local sent = 0
local started = false
local sessionStartedAt = os.clock()

local MemoryTags = ClientPerfConfig.MemoryTags
local tagItems: { Enum.DeveloperMemoryTag } = {}
local tagGroups: { number } = {}
local groupScratch: { number } = table.create(#MemoryTags.Groups, 0)
local nextTagAt = 0
local trackingCache: boolean? = nil

-- Client FX instances (Workspace.ClientFX + Terrain descendants); once per report.
local function countClientFx(): number
	local total = #Workspace.Terrain:GetDescendants()
	local fxFolder = Workspace:FindFirstChild("ClientFX")
	if fxFolder ~= nil then
		total += #fxFolder:GetDescendants()
	end
	return total
end

local function readTag(tag: Enum.DeveloperMemoryTag): number
	return Stats:GetMemoryUsageMbForTag(tag)
end
local function readTracking(): boolean
	return Stats.MemoryTrackingEnabled
end
local function readInstanceCount(): number
	return Stats.InstanceCount
end

-- A finite non-negative engine reading, or nil.
local function sane(ok: boolean, value: unknown): number?
	if ok and type(value) == "number" and value == value and value >= 0 and value < math.huge then
		return value
	end
	return nil
end

-- Resolves Enum.DeveloperMemoryTag once, by name (unknown tags → MemoryTags.UnknownGroup).
local function resolveTags()
	local ok, items = pcall(function(): { Enum.DeveloperMemoryTag }
		return Enum.DeveloperMemoryTag:GetEnumItems()
	end)
	if not ok then
		return
	end
	for _, item in items do
		table.insert(tagItems, item)
		table.insert(tagGroups, ClientPerfLogic.tagGroupIndex(item.Name))
	end
end

-- The 30 s memory-tag tick (on a Stats sample tick so totalMb is that sample's total).
local function sampleTags(totalMb: number)
	local tracking = trackingCache
	if tracking == nil then
		local ok, value = pcall(readTracking)
		tracking = ok and value == true
		if ok then
			trackingCache = tracking
		end
	end
	for index = 1, #groupScratch do
		groupScratch[index] = 0
	end
	if tracking then
		for index, tag in tagItems do
			local ok, mb = pcall(readTag, tag)
			local value = sane(ok, mb)
			if value ~= nil then
				local group = tagGroups[index]
				groupScratch[group] += value
			end
		end
	end
	local ok, count = pcall(readInstanceCount)
	ClientPerfLogic.addTagSample(window, tracking == true, totalMb, groupScratch, sane(ok, count) or 0)
end

--[[
	The loading screen's boot-step block (wire v4): BootStep<step> numbers by step name, plus the
	BootEnd reason. Values are passed through as read; ClientPerfLogic.setBoot sanitises them.
]]
local function readBootSteps(): ({ [string]: unknown }, unknown)
	local steps: { [string]: unknown } = {}
	for _, step in ClientPerfConfig.BootSteps do
		steps[step] = localPlayer:GetAttribute(ClientPerfConfig.BootStepAttributePrefix .. step)
	end
	return steps, localPlayer:GetAttribute(ClientPerfConfig.BootEndAttribute)
end

--[[
	The session's boot seconds, once: the loading screen's BootSeconds attribute (with its step
	block), else `fallback` (time() when the loading gate opened without it: no steps). Marks the
	boot due so it is sent right away.
]]
local function takeBoot(fallback: number?)
	if bootTaken then
		return
	end
	local seconds = localPlayer:GetAttribute(ClientPerfConfig.BootAttribute)
	if type(seconds) == "number" then
		bootTaken = true
		bootDue = true
		local steps, reason = readBootSteps()
		ClientPerfLogic.setBoot(window, seconds, steps, reason)
	elseif fallback ~= nil then
		bootTaken = true
		bootDue = true
		ClientPerfLogic.setBoot(window, fallback)
	end
end

--[[
	Sends the current window (when it has enough frames and the remote is ready) and starts the
	next one. A window older than MaxWindowSeconds (remote unavailable for long) is dropped: the
	server would clamp it and overstate fps.
]]
local function sendReport(now: number)
	local age = now - window.startedAt
	local target = remote
	if
		target ~= nil
		and window.frames >= ClientPerfConfig.MinFrames
		and age >= 1
		and age <= ClientPerfConfig.Limits.MaxWindowSeconds
	then
		local class = ClientPerfLogic.reportClass(DeviceProfile.current().class, UserInputService.KeyboardEnabled)
		local classIndex = table.find(ClientPerfConfig.DeviceClasses, class) or 3
		target:FireServer(
			ClientPerfLogic.encode(window, classIndex, age, (now - sessionStartedAt) / 60, countClientFx())
		)
		sent += 1
		-- The window carried the boot (if it was recorded): it is reported exactly once.
		bootDue = false
		ClientPerfLogic.reset(window, now)
	elseif target == nil and age <= ClientPerfConfig.Limits.MaxWindowSeconds then
		return -- keep measuring until the remote replicates
	else
		-- Dropped unsent (stale / too few frames): an unsent boot + its steps wait for the next window.
		ClientPerfLogic.reset(window, now, true)
	end
	reportInterval = ClientPerfConfig.ReportIntervalSeconds
end

-- The single per-frame callback (no allocation on the common path).
local function onFrame(dt: number)
	debug.profilebegin("SellNukes.ClientPerf")
	ClientPerfLogic.addFrame(window, dt)
	local now = os.clock()
	if now >= nextSampleAt then
		nextSampleAt = now + ClientPerfConfig.SampleIntervalSeconds
		local memoryMb = Stats:GetTotalMemoryUsageMb()
		local receive = Stats.DataReceiveKbps
		local ok, ping = pcall(localPlayer.GetNetworkPing, localPlayer)
		ClientPerfLogic.addSample(window, memoryMb, receive, if ok and type(ping) == "number" then ping * 1000 else 0)
		if now >= nextTagAt then
			nextTagAt = now + MemoryTags.IntervalSeconds
			sampleTags(memoryMb)
		end
	end
	local age = now - window.startedAt
	if age >= reportInterval then
		sendReport(now)
	elseif bootDue and remote ~= nil and window.frames >= ClientPerfConfig.MinFrames and age >= 1 then
		-- R122: send the boot as soon as it is known (a bouncing player may leave before the
		-- next tick). When this is the first report, the regular first one still follows
		-- FirstReportSeconds later, so a short session keeps its early gameplay window.
		local first = sent == 0
		sendReport(now)
		if first then
			reportInterval = ClientPerfConfig.FirstReportSeconds
		end
	end
	debug.profileend()
end

--[[
	The player's plot finished streaming / building in, `seconds` after it was assigned (the tycoon
	client calls this once per plot load). Rides the next report as "map ready" seconds.
]]
function ClientPerfReporter.plotReady(seconds: number)
	if type(seconds) == "number" and seconds == seconds and seconds >= 0 then
		ClientPerfLogic.addMapReady(window, seconds)
	end
end

--[[ Reports sent this session (diagnostics / tests). ]]
function ClientPerfReporter.reportsSent(): number
	return sent
end

--[[ Starts measuring (idempotent). Never yields. ]]
function ClientPerfReporter.start()
	if started then
		return
	end
	started = true
	sessionStartedAt = os.clock()
	resolveTags()
	ClientPerfLogic.reset(window, os.clock())
	-- The loading screen's hand-off sets BootSeconds (taken by the attribute listener below);
	-- the time() fallback waits for the loading gate, so it can never pre-empt the real value.
	-- Deferred: the screen sets LoadingDone just before BootSeconds in the same frame.
	LoadingGate.onDone(function()
		task.defer(takeBoot, time())
	end)
	RunService.PreRender:Connect(onFrame)
	localPlayer:GetAttributeChangedSignal(ClientPerfConfig.BootAttribute):Connect(function()
		takeBoot(nil)
	end)
	localPlayer.OnTeleport:Connect(function(state: Enum.TeleportState)
		if state == Enum.TeleportState.Started then
			sendReport(os.clock())
		end
	end)
	task.spawn(function()
		local ok, result = pcall(function(): RemoteEvent
			return Remotes.event("ClientPerf")
		end)
		if ok then
			remote = result
		else
			warn(`[ClientPerfReporter] ClientPerf remote unavailable: {result}`)
		end
	end)
end

return ClientPerfReporter
