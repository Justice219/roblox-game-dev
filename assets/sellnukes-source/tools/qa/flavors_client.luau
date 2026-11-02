--!nocheck
--[[
	flavors_client.luau — client-VM probe for the owner R89 Surprise Batches / Flavour Book / Big Pop
	(tools/qa/flavors.py, eval_client_runtime during ONE solo playtest).

		COMMAND  "diag"      HUD shown, profile loaded, tutorial step, top modal, controller stats
		         "closeall"  closes every window (Welcome Back, What's New, ...) — the reveal gate
		         "hold"      DebugHold on the FlavorReveal ScreenGui (Studio: stays up for captures)
		         "release"   clears DebugHold and closes the reveal
		         "probe"     FlavorController.stats(), reveal open + its texts, banner visibility
		         "focus"     scriptable camera looking at your first producer (glow / pop shots)
		         "unfocus"   camera back to Custom
		         "pets"      opens Pets; returns the FLAVOURS button point + its "!" badge
		         "book"      probe of the open Flavour Book: tiles (state, rect, texts), CLAIM ALL,
		                     default selection, the smallest tile + text in device points
		         "claimpoint" viewport centre of CLAIM ALL (the runner presses it for real)
		         "bigpop"    the Big Pop banner for a sample broadcast, held 30 s (captures)
		         "preview"   FlavorController.preview(rank ARGS[1]) — local look only
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
local ScreenManager = require(client.UI.ScreenManager)
local FlavorController = require(client.Tycoon.FlavorController)
local ProducerBillboards = require(client.Tycoon.ProducerBillboards)
local Tutorial = require(client.Tycoon.Tutorial)
local BigPopBanner = require(client.Tycoon.Fx.BigPopBanner)
local FlavorConfig = require(game:GetService("ReplicatedStorage").Shared.Config.FlavorConfig)

local function gui(name: string): ScreenGui?
	return ScreenManager.getGui(name)
end

local function rect(node: Instance?): { number }?
	if node == nil or not node:IsA("GuiObject") then
		return nil
	end
	return {
		math.floor(node.AbsolutePosition.X),
		math.floor(node.AbsolutePosition.Y),
		math.floor(node.AbsoluteSize.X),
		math.floor(node.AbsoluteSize.Y),
	}
end

local function textOf(node: Instance?, name: string): string
	local label = if node ~= nil then node:FindFirstChild(name, true) else nil
	return if label ~= nil and label:IsA("TextLabel") then label.Text else ""
end

-- The first visible non-empty text under a node (a stud button's label).
local function firstText(node: Instance?): string
	if node == nil then
		return ""
	end
	for _, child in node:GetDescendants() do
		if child:IsA("TextLabel") and child.Visible and child.Text ~= "" then
			return child.Text
		end
	end
	return ""
end

local function point(node: Instance?)
	if node == nil or not node:IsA("GuiObject") then
		return {}
	end
	local inset = GuiService:GetGuiInset()
	local c = node.AbsolutePosition + node.AbsoluteSize / 2 + inset
	local viewport = Workspace.CurrentCamera.ViewportSize
	return { x = math.floor(c.X), y = math.floor(c.Y), viewportX = math.floor(viewport.X) }
end

local function revealProbe()
	local root = gui("FlavorReveal")
	return {
		open = ScreenManager.isOpen("FlavorReveal"),
		shout = textOf(root, "Shout"),
		mult = textOf(root, "Mult"),
		odds = textOf(root, "Odds"),
		amount = textOf(root, "Amount"),
		skip = rect(if root ~= nil then root:FindFirstChild("Skip", true) else nil),
	}
end

local function bookProbe()
	local root = gui(FlavorConfig.BookScreen)
	local tiles = {}
	local smallestTile, smallestText = math.huge, math.huge
	local states = { locked = 0, ready = 0, claimed = 0 }
	if root ~= nil then
		for _, node in root:GetDescendants() do
			if node:IsA("TextButton") and string.match(node.Name, "^Tile_") then
				local pill = firstText(node:FindFirstChild("Pill"))
				local state = if string.find(pill, "CLAIM", 1, true) then "ready"
					elseif string.find(pill, "FOUND", 1, true) then "claimed"
					else "locked"
				states[state] += 1
				table.insert(tiles, {
					key = string.sub(node.Name, 6),
					state = state,
					name = textOf(node, "Name"),
					odds = textOf(node, "Odds"),
					pill = pill,
					rect = rect(node),
				})
				smallestTile = math.min(smallestTile, node.AbsoluteSize.X, node.AbsoluteSize.Y)
				for _, child in node:GetDescendants() do
					if child:IsA("TextLabel") and child.Visible and child.Text ~= "" then
						smallestText = math.min(smallestText, child.TextBounds.Y)
					end
				end
			end
		end
	end
	local claimAll = if root ~= nil then root:FindFirstChild("ClaimAll", true) else nil
	local selected = GuiService.SelectedObject
	return {
		open = ScreenManager.isOpen(FlavorConfig.BookScreen),
		count = #tiles,
		states = states,
		tiles = tiles,
		claimAll = firstText(claimAll),
		discovered = textOf(root, "Discovered"),
		luckChip = if root ~= nil and root:FindFirstChild("LuckChip", true) then root:FindFirstChild("LuckChip", true).Visible else false,
		selected = if selected ~= nil then selected.Name else "",
		smallestTilePx = smallestTile,
		smallestTextPx = smallestText,
		flavors = ClientState.profile and ClientState.profile.flavors or nil,
		gems = ClientState.profile and ClientState.profile.gems or nil,
	}
end

if COMMAND == "diag" then
	local hud = gui("Hud")
	return HttpService:JSONEncode({
		hud = hud ~= nil and hud.Enabled,
		profile = type(ClientState.profile) == "table",
		tutorial = Tutorial.step(),
		top = ScreenManager.topModalName() or "",
		stats = FlavorController.stats(),
	})
elseif COMMAND == "closeall" then
	ScreenManager.closeAllModals()
	return ScreenManager.topModalName() or ""
elseif COMMAND == "hold" then
	-- The reveal builds lazily: make sure its ScreenGui exists, then hold it.
	local root = gui("FlavorReveal")
	if root ~= nil then
		root:SetAttribute("DebugHold", true)
	end
	return tostring(root ~= nil)
elseif COMMAND == "release" then
	local root = gui("FlavorReveal")
	if root ~= nil then
		root:SetAttribute("DebugHold", nil)
	end
	ScreenManager.close("FlavorReveal")
	return "released"
elseif COMMAND == "probe" then
	local banner = gui("BigPopBanner")
	local card = if banner ~= nil then banner:FindFirstChild("BigPop", true) else nil
	return HttpService:JSONEncode({
		stats = FlavorController.stats(),
		reveal = revealProbe(),
		banner = card ~= nil and card.Visible,
		bannerLine = textOf(card, "Line"),
	})
elseif COMMAND == "focus" then
	local record = ProducerBillboards.ownRecords()[1]
	if record == nil then
		return "no producer"
	end
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	local target = record.anchor.Position
	local eye = target + record.popAway * 26 + Vector3.new(0, 10, 0)
	camera.CFrame = CFrame.lookAt(eye, target)
	return record.id
elseif COMMAND == "unfocus" then
	Workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
	return "custom"
elseif COMMAND == "pets" then
	ScreenManager.closeAllModals()
	ScreenManager.open("Pets", { tab = "pets" })
	task.wait(1.2)
	local root = gui("Pets")
	local button = if root ~= nil then root:FindFirstChild("FlavorBook", true) else nil
	local badge = if button ~= nil then button:FindFirstChild("Badge") else nil
	return HttpService:JSONEncode({
		open = ScreenManager.isOpen("Pets"),
		point = point(button),
		rect = rect(button),
		badge = badge ~= nil and badge.Visible,
	})
elseif COMMAND == "book" then
	task.wait(0.6)
	return HttpService:JSONEncode(bookProbe())
elseif COMMAND == "claimpoint" then
	local root = gui(FlavorConfig.BookScreen)
	return HttpService:JSONEncode(point(if root ~= nil then root:FindFirstChild("ClaimAll", true) else nil))
elseif COMMAND == "bigpop" then
	local shown = BigPopBanner.show({
		name = LOCAL.DisplayName,
		kind = "batch",
		id = "galaxy",
		label = "GALAXY batch",
		oneIn = 2500,
	}, 2, 30)
	return tostring(shown)
elseif COMMAND == "preview" then
	local def = FlavorConfig.byRank(math.floor(ARGS[1] or 4))
	return tostring(def ~= nil and FlavorController.preview(def.id))
end
return "unknown command"
