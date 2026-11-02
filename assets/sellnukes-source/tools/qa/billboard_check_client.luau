--!strict
--[[
	billboard_check_client.luau — CLIENT half of the producer-billboard placement check
	(tools/qa/billboard_check.py; eval_client_runtime, so it shares the live client's require cache).

	Placeholders filled by billboard_check.py with whitelisted values only:
		COMMAND  "views" | "before" | "after" | "knock" | "report"
		ARGS     numbers: views = { area, stand, back? }; knock = { area, seconds };
		         before / after / report = {}

	views   world eye + target of the solver's standard player camera for `area` (slot-local:
	        `stand` studs (x the solver's StandScale factor) in front of the click box's front
	        face, `back` (default Placement.CameraBack) behind and
	        Placement.CameraUp above the ground, looking at the click box centre), as JSON
	before  re-applies the pre-solver rule (HEAD before owner R31/R32 + lead QA: 2.5 studs in front
	        of the click box, centre 7.5 above its bottom clamped to [6, roof], fixed 11 x 8.8 studs,
	        x1.3 on devices; its overlap nudge never fired because visual meshes are CanQuery = false)
	        to every billboard, sized for the CURRENT camera so the live resize loop leaves it alone
	after   re-places every billboard with the live code (ProducerBillboards.place) and forces the
	        size refresh
	knock   client-side preview of the R50 knockdown plate on an own area (seconds; 0 clears)
	report  per producer: family / clear / slab / rays / elevation of the live placement, as JSON
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local COMMAND = "__COMMAND__"
local ARGS: { number } = { --[[ARGS]]
}

local Client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Tycoon = Client:WaitForChild("Tycoon")
local BillboardPlacement = (require :: any)(Tycoon.BillboardPlacement)
local ProducerBillboards = (require :: any)(Tycoon.ProducerBillboards)
local TycoonWorld = (require :: any)(Tycoon.TycoonWorld)
local Contract = (require :: any)(Tycoon.TycoonContract)
local TycoonClientConfig = (require :: any)(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local WorldLayout = (require :: any)(ReplicatedStorage.Shared.Config.WorldLayout)

local Config = TycoonClientConfig.Billboard
local Placement = TycoonClientConfig.Placement
local camera = workspace.CurrentCamera

-- Own producer records keyed by area index.
local function ownRecords(): { [number]: any }
	local out: { [number]: any } = {}
	for _, anchor in TycoonWorld.producers() do
		local record = ProducerBillboards.byAnchor(anchor)
		if record ~= nil and record.mine then
			out[record.area] = record
		end
	end
	return out
end

local function plotIndex(): number
	local plot = TycoonWorld.myPlot()
	return if plot ~= nil then Contract.num(plot:GetAttribute(Contract.Attr.PlotIndex), 0) else 0
end

if COMMAND == "views" then
	local area = ARGS[1]
	local stand = ARGS[2]
	-- Camera distance behind the player (default: the solver's CameraBack). A smaller value frames
	-- an indoor producer from inside its room (A1 bench: the owner's uncle-atom-work.jpg angle).
	local back = ARGS[3] or Placement.CameraBack
	local index = plotIndex()
	local layout = (require :: any)(ReplicatedStorage.Shared.Config.AreaLayouts[string.format("Area%02d", area)])
	local click = layout.producer.click
	local half = click.size / 2
	local centre = click.cf.Position
	local ground = centre.Y - half.Y
	local front = centre.Z - half.Z -- slot -Z faces the road
	-- The solver's stand scaling (BillboardPlacement `prepare`): big producers are viewed from
	-- further back.
	stand *= math.max(1, math.max(click.size.X, click.size.Y) / Placement.StandScale)
	local slot = WorldLayout.slotOrigin(index, area)
	local eye = slot * Vector3.new(centre.X, ground + Placement.CameraUp, front - stand - back)
	local target = slot * centre
	-- The (hidden) character stands 10 studs behind the camera, so its pet stays out of the shot.
	local behind = slot * Vector3.new(centre.X, ground + 3, front - stand - back - 10)
	-- World-only shots: no modal blur / depth of field left over from a closed menu.
	for _, holder in { game:GetService("Lighting"), camera } do
		for _, effect in holder:GetChildren() do
			if effect:IsA("BlurEffect") or effect:IsA("DepthOfFieldEffect") then
				effect.Enabled = false
			end
		end
	end
	return HttpService:JSONEncode({
		eye = { eye.X, eye.Y, eye.Z },
		target = { target.X, target.Y, target.Z },
		focus = { behind.X, behind.Y, behind.Z },
	})
elseif COMMAND == "before" then
	local count = 0
	for _, record in ownRecords() do
		local box = TycoonWorld.clickBox(record.anchor)
		local cf, size = box.CFrame, box.Size
		local index = plotIndex()
		local forward = WorldLayout.slotOrigin(index, record.area).LookVector
		local half = size / 2
		local depth = math.abs(cf.RightVector:Dot(forward)) * half.X
			+ math.abs(cf.UpVector:Dot(forward)) * half.Y
			+ math.abs(cf.LookVector:Dot(forward)) * half.Z
		local bottom = cf.Position.Y - half.Y
		local roof = cf.Position.Y + half.Y
		local base = cf.Position + forward * (depth + 2.5)
		local height = math.clamp(7.5, 6, math.max(6, roof - bottom))
		record.point.WorldPosition = Vector3.new(base.X, bottom + height, base.Z)
		local grow = if record.device then 1.3 else 1
		record.gui.Size = UDim2.fromScale(11 * grow, 8.8 * grow)
		-- Freeze the live resize loop for this camera (it only rewrites on a > SizeEpsilon change).
		record.height = BillboardPlacement.heightAt(
			(record.point.WorldPosition - camera.CFrame.Position).Magnitude,
			Config,
			record.device,
			camera.FieldOfView
		)
		count += 1
	end
	return `before applied to {count} billboards`
elseif COMMAND == "after" then
	local count = 0
	for _, record in ownRecords() do
		ProducerBillboards.place(record)
		record.height = -1 -- force the next refresh tick to size it for the current camera
		count += 1
	end
	return `after applied to {count} billboards`
elseif COMMAND == "knock" then
	-- Client-side preview of the owner R50 knockdown plate: the area's KnockedUntil (+ the anchor's
	-- PausedAt) set locally for ARGS[2] seconds (0 clears). Visual check only: the server owns the
	-- real knockdown state; local attribute writes never replicate.
	local record = ownRecords()[ARGS[1]]
	if record == nil or record.areaModel == nil then
		return "ERROR no own producer in that area"
	end
	local now = workspace:GetServerTimeNow()
	local seconds = ARGS[2]
	record.areaModel:SetAttribute("KnockedUntil", if seconds > 0 then now + seconds else nil)
	record.anchor:SetAttribute("PausedAt", if seconds > 0 then now else nil)
	return `knock {seconds}s`
elseif COMMAND == "report" then
	local rows = {}
	for area, record in ownRecords() do
		local p = record.placement
		table.insert(rows, {
			area = area,
			family = if p then p.family else "none",
			clear = if p then p.clear else false,
			slabClear = if p then p.slabClear else false,
			rays = if p then p.blockedRays else -1,
			elevation = if p then math.floor(p.elevation * 10) / 10 else -1,
			height = math.floor(record.height * 100) / 100,
			fallback = record.fallback,
			device = record.device,
		})
	end
	table.sort(rows, function(a: any, b: any): boolean
		return a.area < b.area
	end)
	return HttpService:JSONEncode(rows)
end
return `ERROR unknown command {COMMAND}`
