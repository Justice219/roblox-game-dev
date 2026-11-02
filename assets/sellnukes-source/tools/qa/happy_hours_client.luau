--!nocheck
--[[
	happy_hours_client.luau — CLIENT half of the R89 Happy Hours Studio QA (E-events), run by
	tools/qa/happy_hours.py through eval_client_runtime in ONE solo playtest.

		COMMAND  "diag"          chip (visible, texts, rects, scale, overlaps with every HUD zone,
		                         the boost badge, the admin chip and the Roblox top bar), schedule
		                         panel rows, HappyHourClient.stats(), pickups, banner, viewport
		         "close_all"     ScreenManager.closeAllModals()
		         "open_schedule" ScreenManager.open("HappyHourSchedule") (what the chip's tap does)
		         "close_schedule"
		         "select_chip"   GuiService.SelectedObject = the chip (gamepad path)
		         "deselect"
		         "goto"          moves the OWN character next to the nearest live pickup (ARGS[1] =
		                         extra height) so the real walk-in claim path runs
		         "hud_off" / "hud_on"   nothing (kept for parity with other runners)
	Presentation only: claims still go HappyHourCollect → server validation.
]]

local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local LOCAL = Players.LocalPlayer
local client = LOCAL:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ClientState = require(client.ClientState)
local HappyHourClient = require(client.HappyHour.HappyHourClient)
local HappyHourPickupsClient = require(client.HappyHour.HappyHourPickupsClient)
local HudCurrency = require(client.UI.Hud.HudCurrency)
local HudZones = require(client.UI.Widgets.HudZones)
local JuiceBanner = require(client.Tycoon.Fx.JuiceBanner)
local ScreenManager = require(client.UI.ScreenManager)

local function rect(item)
	if item == nil or not item:IsA("GuiObject") then
		return nil
	end
	return {
		x = math.floor(item.AbsolutePosition.X),
		y = math.floor(item.AbsolutePosition.Y),
		w = math.floor(item.AbsoluteSize.X),
		h = math.floor(item.AbsoluteSize.Y),
	}
end

local function overlaps(a, b)
	if a == nil or b == nil then
		return false
	end
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

local function chipParts()
	local gui = ScreenManager.getGui("HappyHourChip")
	local canvas = gui and gui:FindFirstChild("HappyHourCanvas")
	local chip = canvas and canvas:FindFirstChild("HappyHourChip")
	return gui, canvas, chip
end

-- A HudZones design rect in absolute px (through the chip gui's full-canvas frame).
local function zoneAbs(name, canvas, gui)
	local zone = HudZones.rect(name)
	if zone == nil or canvas == nil then
		return nil
	end
	local size = ScreenManager.canvasSize(gui)
	local k = canvas.AbsoluteSize.X / math.max(size.X, 1)
	return {
		x = math.floor(canvas.AbsolutePosition.X + zone.x * k),
		y = math.floor(canvas.AbsolutePosition.Y + zone.y * k),
		w = math.floor(zone.w * k),
		h = math.floor(zone.h * k),
	}
end

local function textOf(chip, name)
	local label = chip and chip:FindFirstChild(name, true)
	return label and label.Text or nil, label and math.floor(label.TextBounds.Y) or nil
end

local function scheduleRows()
	local gui = ScreenManager.getGui("HappyHourSchedule")
	local rows = {}
	if gui == nil then
		return rows
	end
	for index = 1, 8 do
		local row = gui:FindFirstChild(`Row{index}`, true)
		if row ~= nil and row.Visible then
			local name = row:FindFirstChild("Name", true)
			local time = row:FindFirstChild("Time", true)
			local go = row:FindFirstChild("Go", true)
			local blurb = row:FindFirstChild("Blurb", true)
			table.insert(rows, {
				name = name and name.Text,
				time = time and time.Text,
				nameH = name and math.floor(name.TextBounds.Y),
				blurbH = blurb and math.floor(blurb.TextBounds.Y),
				timeH = time and math.floor(time.TextBounds.Y),
				go = go ~= nil and go.Visible,
			})
		end
	end
	return rows
end

local function diag()
	local gui, canvas, chip = chipParts()
	local chipRect = rect(chip)
	local zones = {}
	local hits = {}
	for _, name in { "Top", "Left", "Right", "Bottom", "TopRight" } do
		local zone = zoneAbs(name, canvas, gui)
		zones[name] = zone
		if chip ~= nil and chip.Visible and overlaps(chipRect, zone) then
			table.insert(hits, name)
		end
	end
	local corner = HudCurrency.corner()
	local badge = corner and corner:FindFirstChildWhichIsA("GuiObject")
	local badgeRect = badge and badge.Visible and rect(badge) or nil
	if chip ~= nil and chip.Visible and overlaps(chipRect, badgeRect) then
		table.insert(hits, "BoostBadge")
	end
	local playerGui = LOCAL:FindFirstChildOfClass("PlayerGui")
	local admin = playerGui and playerGui:FindFirstChild("AdminChip", true)
	local adminRect = admin and admin.Visible and rect(admin) or nil
	if chip ~= nil and chip.Visible and overlaps(chipRect, adminRect) then
		table.insert(hits, "AdminChip")
	end
	local inset = GuiService.TopbarInset
	local topbarHit = chipRect ~= nil and chip.Visible and chipRect.y < inset.Max.Y
		and (chipRect.x < inset.Min.X or chipRect.x + chipRect.w > inset.Max.X)
	local title, titleH = textOf(chip, "Title")
	-- R92: the pill has ONE line (Title); "detail" mirrors it for older checks.
	local detail, detailH = title, titleH
	local camera = Workspace.CurrentCamera
	local scale = ScreenManager.pointScale()
	local schedule = ScreenManager.getGui("HappyHourSchedule")
	return {
		viewport = camera and { x = camera.ViewportSize.X, y = camera.ViewportSize.Y } or nil,
		pointScale = scale,
		device = ScreenManager.device and ScreenManager.device.class or nil,
		phone = ScreenManager.device and ScreenManager.device.isPhone or false,
		chipVisible = chip ~= nil and chip.Visible,
		hiddenReason = gui and gui:GetAttribute("HappyHourChipHidden") or nil,
		chip = chipRect,
		-- AbsoluteSize / TextBounds are Roblox logical px = points on devices.
		chipPt = chipRect and { w = chipRect.w, h = chipRect.h } or nil,
		title = title,
		detail = detail,
		titlePt = titleH,
		detailPt = detailH,
		selectable = chip ~= nil and chip.Selectable,
		hits = hits,
		topbarHit = topbarHit,
		zones = zones,
		badge = badgeRect,
		admin = adminRect,
		modal = ScreenManager.anyModalOpen(),
		topModal = ScreenManager.topModalName(),
		scheduleOpen = ScreenManager.isOpen("HappyHourSchedule"),
		scheduleWindow = schedule and rect(schedule:FindFirstChild("HappyHourScheduleWindow", true)) or nil,
		rows = scheduleRows(),
		selected = GuiService.SelectedObject and GuiService.SelectedObject.Name or nil,
		banner = JuiceBanner.isShowing(),
		stats = HappyHourClient.stats(),
		pickups = HappyHourPickupsClient.list(),
		profile = ClientState.profile ~= nil,
		hud = ScreenManager.isOpen("Hud"),
	}
end

local out
if COMMAND == "diag" then
	out = diag()
elseif COMMAND == "close_all" then
	ScreenManager.closeAllModals()
	out = { modal = ScreenManager.anyModalOpen() }
elseif COMMAND == "open_schedule" then
	ScreenManager.open("HappyHourSchedule", { source = "qa" })
	task.wait(0.6)
	out = diag()
elseif COMMAND == "close_schedule" then
	ScreenManager.close("HappyHourSchedule")
	task.wait(0.6)
	out = diag()
elseif COMMAND == "select_chip" then
	local _, _, chip = chipParts()
	GuiService.SelectedObject = chip
	task.wait(0.2)
	out = { selected = GuiService.SelectedObject and GuiService.SelectedObject.Name or nil }
elseif COMMAND == "deselect" then
	GuiService.SelectedObject = nil
	out = { selected = nil }
elseif COMMAND == "goto" then
	local character = LOCAL.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local best, bestDistance = nil, math.huge
	for _, pickup in HappyHourPickupsClient.list() do
		if root ~= nil then
			local distance = (pickup.position - root.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = pickup, distance
			end
		end
	end
	if best == nil or root == nil then
		out = { ok = false, reason = "no pickup / character" }
	else
		local before = HappyHourPickupsClient.stats()
		character:PivotTo(CFrame.new(best.position + Vector3.new(0, 3 + (ARGS[1] or 0), 0)))
		task.wait(2)
		out = { ok = true, target = best.id, golden = best.golden, before = before, after = HappyHourPickupsClient.stats() }
	end
elseif COMMAND == "hud_off" or COMMAND == "hud_on" then
	out = { ok = true }
end
return HttpService:JSONEncode(out)
