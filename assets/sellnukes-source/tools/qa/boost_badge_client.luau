--!nocheck
--[[
	boost_badge_client.luau — CLIENT half of the R82 boost-badge Studio QA (B-boost), run by
	tools/qa/boost_badge.py through eval_client_runtime in ONE solo playtest.

		COMMAND  "diag"        the badge (visible, texts, anchor parent, sticker / hit rects), the
		                       clearance between the tilted sticker's leftmost corner and the
		                       counter's number (screen px, must stay > the outline), rendered text
		                       heights (points), the top-bar overlap, the breakdown (open, rect,
		                       rows, text heights), the gamepad links, the HudZones "Boosts" zone
		         "select"      puts the gamepad selection on the badge (opens the breakdown)
		         "deselect"    drops the selection (closes it)
		         "long"        DISPLAY-ONLY width probe: writes ARGS[1] (1 = "$0", 2 = "$608.05Sx",
		                       3 = "$888.88Dc", 4 = restore) into the visible counter's number and
		                       reports the clearance at that width (the next server push rewrites it)
		         "close_all"   closes every modal (boot windows)
	Presentation only: nothing is sent to the server, no economy value is touched.
]]

local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local HudCurrency = require(client.UI.Hud.HudCurrency)
local HudZones = require(client.UI.Widgets.HudZones)
local ScreenManager = require(client.UI.ScreenManager)

local function rect(item)
	if item == nil then
		return nil
	end
	return {
		x = math.floor(item.AbsolutePosition.X),
		y = math.floor(item.AbsolutePosition.Y),
		w = math.floor(item.AbsoluteSize.X),
		h = math.floor(item.AbsoluteSize.Y),
	}
end

-- The rotated sticker's leftmost screen x (rotation about its centre).
local function leftmost(sticker)
	local size = sticker.AbsoluteSize
	local centre = sticker.AbsolutePosition + size / 2
	local r = math.rad(sticker.Rotation)
	local best = math.huge
	for _, c in { Vector2.new(-1, -1), Vector2.new(1, -1), Vector2.new(-1, 1), Vector2.new(1, 1) } do
		local x = c.X * size.X / 2 * math.cos(r) - c.Y * size.Y / 2 * math.sin(r)
		best = math.min(best, centre.X + x)
	end
	return best
end

local function badgeParts()
	local anchor = HudCurrency.corner()
	local badge = anchor and anchor:FindFirstChild("BoostBadge")
	local sticker = badge and badge:FindFirstChild("Sticker")
	return anchor, badge, sticker
end

local function clearance()
	local anchor, badge, sticker = badgeParts()
	if anchor == nil or sticker == nil or not badge.Visible then
		return nil
	end
	local label = anchor.Parent
	local stroke = label:FindFirstChild("TextOutline")
	local right = label.AbsolutePosition.X + label.AbsoluteSize.X
	return {
		labelText = label.Text,
		labelRight = math.floor(right),
		stickerLeft = math.floor(leftmost(sticker) * 10) / 10,
		clearPx = math.floor((leftmost(sticker) - right) * 10) / 10,
		outlinePx = stroke and stroke.Thickness or nil,
	}
end

local function diag()
	local anchor, badge, sticker = badgeParts()
	local gui = ScreenManager.getGui("BoostChips")
	local panel = gui and gui:FindFirstChild("Breakdown", true)
	local rows = {}
	if panel ~= nil then
		for _, row in panel:GetChildren() do
			if row:IsA("Frame") and row.Name:match("^Row") and row.Visible then
				local name, time = row:FindFirstChild("Name"), row:FindFirstChild("Time")
				table.insert(rows, {
					name = name and name.Text,
					time = time and time.Text,
					nameH = name and math.floor(name.TextBounds.Y),
					timeH = time and math.floor(time.TextBounds.Y),
				})
			end
		end
	end
	local camera = Workspace.CurrentCamera
	local inset = GuiService.TopbarInset
	local stickerRect = rect(sticker)
	local topbarHit = false
	if stickerRect ~= nil then
		-- Roblox's own top-bar buttons: left of TopbarInset.Min.X / right of Max.X, above Max.Y.
		local inBand = stickerRect.y < inset.Max.Y
		local hitsLeft = stickerRect.x < inset.Min.X
		local hitsRight = stickerRect.x + stickerRect.w > inset.Max.X
		topbarHit = inBand and (hitsLeft or hitsRight)
	end
	local big = sticker and sticker:FindFirstChild("Multiplier")
	local small = sticker and sticker:FindFirstChild("Timer")
	local back = badge and badge:FindFirstChild("Back")
	return {
		viewport = camera and { x = camera.ViewportSize.X, y = camera.ViewportSize.Y } or nil,
		scale = ScreenManager.pointScale(),
		phone = ScreenManager.device.isPhone,
		anchorParent = anchor and anchor.Parent and anchor.Parent.Parent and anchor.Parent.Parent.Name or nil,
		visible = badge ~= nil and badge.Visible,
		selectable = badge ~= nil and badge.Selectable,
		big = big and big.Text,
		small = small and small.Text,
		bigH = big and math.floor(big.TextBounds.Y),
		smallH = small and math.floor(small.TextBounds.Y),
		back = back ~= nil and back.Visible,
		sticker = stickerRect,
		hit = rect(badge),
		clearance = clearance(),
		topbar = { minX = inset.Min.X, maxX = inset.Max.X, maxY = inset.Max.Y },
		topbarHit = topbarHit,
		navLeft = badge and badge.NextSelectionLeft and badge.NextSelectionLeft.Name or nil,
		navRight = badge and badge.NextSelectionRight and badge.NextSelectionRight.Name or nil,
		entryUp = (function()
			local left = HudCurrency.navExits()
			return left and left.NextSelectionUp and left.NextSelectionUp.Name or nil
		end)(),
		panelOpen = panel ~= nil and panel.Visible,
		panel = panel and panel.Visible and rect(panel) or nil,
		panelTitle = panel and panel:FindFirstChild("Total") and panel.Total.Text or nil,
		rows = rows,
		boostsZone = HudZones.rect("Boosts"),
		selected = GuiService.SelectedObject and GuiService.SelectedObject.Name or nil,
	}
end

local saved = nil
local out
if COMMAND == "diag" then
	out = diag()
elseif COMMAND == "select" then
	local _, badge = badgeParts()
	GuiService.SelectedObject = badge
	task.wait(0.4)
	out = diag()
elseif COMMAND == "deselect" then
	GuiService.SelectedObject = nil
	task.wait(0.3)
	out = diag()
elseif COMMAND == "long" then
	local anchor = HudCurrency.corner()
	local label = anchor and anchor.Parent
	local texts = { "$0", "$608.05Sx", "$888.88Dc" }
	if label ~= nil then
		saved = label:GetAttribute("QaSavedText") or label.Text
		label:SetAttribute("QaSavedText", saved)
		local which = ARGS[1]
		if which >= 4 then
			label.Text = saved
			label:SetAttribute("QaSavedText", nil)
		else
			label.Text = texts[which]
		end
		task.wait(0.3)
	end
	out = diag()
elseif COMMAND == "close_all" then
	ScreenManager.closeAllModals()
	out = { closed = true }
else
	out = { error = "unknown command" }
end
return HttpService:JSONEncode(out)
