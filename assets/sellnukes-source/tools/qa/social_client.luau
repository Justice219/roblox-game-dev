--!nocheck
--[[
	social_client.luau — CLIENT half of the R78 Rush + Friends Studio QA (R-social), run by
	tools/qa/social.py through eval_client_runtime in ONE solo playtest.

		COMMAND  "diag"          HUD open, SocialClient state, the R82 boost badge ("2x 14:29") + rect,
		                         the HudZones "Boosts" rect, the toast stack top, Welcome Back /
		                         Friends / hub state, the gamepad selection
		         "close_all"     closes every modal (boot windows)
		         "open_friends"  opens the Friends window from the hub source
		         "open_hub"      opens the Rewards hub
		         "text_fit"      every visible scaled label of the hub / Friends / Welcome Back:
		                         box vs text bounds, the size floor, TextFits
	Presentation only (reads + opening screens). No intents are sent from here.
]]

local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }
local _ = ARGS

local client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local HudZones = require(client.UI.Widgets.HudZones)
local RewardsBadges = require(client.UI.RewardsBadges)
local ScreenManager = require(client.UI.ScreenManager)
local SocialClient = require(client.Social.SocialClient)

-- Visible text labels under a gui (name → text), bounded.
local function labels(gui, nameFilter)
	local out = {}
	if gui == nil then
		return out
	end
	for _, item in gui:GetDescendants() do
		if item:IsA("TextLabel") and (nameFilter == nil or item.Name == nameFilter) then
			local visible = item.Visible
			local node = item.Parent
			while visible and node ~= nil and node ~= gui do
				if node:IsA("GuiObject") and not node.Visible then
					visible = false
				end
				node = node.Parent
			end
			if visible and item.Text ~= "" and #out < 24 then
				table.insert(out, item.Text)
			end
		end
	end
	return out
end

-- Owner R82: the R78 chip row became ONE badge on the cash counter's corner (BoostChipsScreen
-- inside HudCurrency's BoostCorner). Reported as one "chip": "<multiplier> <timer>" (e.g.
-- "2x 14:29", "2.4x 14:29", "+20% FRIENDS") with the sticker's screen rect.
local function chips()
	local out = {}
	local HudCurrency = require(client.UI.Hud.HudCurrency)
	local anchor = HudCurrency.corner()
	local badge = anchor and anchor:FindFirstChild("BoostBadge")
	local sticker = badge and badge:FindFirstChild("Sticker")
	if sticker == nil or not badge.Visible then
		return out
	end
	local big, small = sticker:FindFirstChild("Multiplier"), sticker:FindFirstChild("Timer")
	table.insert(out, {
		text = `{big and big.Text or ""} {small and small.Text or ""}`,
		x = math.floor(sticker.AbsolutePosition.X),
		y = math.floor(sticker.AbsolutePosition.Y),
		w = math.floor(sticker.AbsoluteSize.X),
		h = math.floor(sticker.AbsoluteSize.Y),
	})
	return out
end

local out
if COMMAND == "diag" then
	local now = Workspace:GetServerTimeNow()
	local rush = SocialClient.rush()
	local toasts = ScreenManager.getGui("Toasts")
	local stack = toasts and toasts:FindFirstChild("Stack")
	local friendsTile = RewardsBadges.forFeature("Friends")
	out = {
		hud = ScreenManager.isOpen("Hud"),
		rookieLeft = math.floor(math.max(0, rush.rookieEndsAt - now)),
		comebackLeft = math.floor(math.max(0, rush.comebackEndsAt - now)),
		friends = SocialClient.friends(),
		referral = SocialClient.referral(),
		chips = chips(),
		boostsZone = HudZones.rect("Boosts"),
		topZone = HudZones.rect("Top"),
		toastTop = stack and stack.Position.Y.Offset or nil,
		welcomeOpen = ScreenManager.isOpen("WelcomeBack"),
		welcomeText = if ScreenManager.isOpen("WelcomeBack") then labels(ScreenManager.getGui("WelcomeBack")) else nil,
		friendsOpen = ScreenManager.isOpen("Friends"),
		friendsText = if ScreenManager.isOpen("Friends") then labels(ScreenManager.getGui("Friends")) else nil,
		friendsTile = friendsTile and { kind = friendsTile.kind, value = friendsTile.value } or nil,
		selected = GuiService.SelectedObject and GuiService.SelectedObject.Name or nil,
		topModal = ScreenManager.topModalName(),
	}
elseif COMMAND == "text_fit" then
	-- Every visible scaled label of the open modal windows: does its text fit its box?
	local rows = {}
	for _, name in { "RewardsHub", "Friends", "WelcomeBack" } do
		local gui = ScreenManager.getGui(name)
		if gui ~= nil and gui.Enabled then
			for _, item in gui:GetDescendants() do
				if item:IsA("TextLabel") and item.TextScaled and item.Text ~= "" and item.AbsoluteSize.Y > 0 then
					local limit = item:FindFirstChildOfClass("UITextSizeConstraint")
					table.insert(rows, {
						screen = name,
						text = string.sub(item.Text, 1, 24),
						boxH = math.floor(item.AbsoluteSize.Y),
						boxW = math.floor(item.AbsoluteSize.X),
						textH = math.floor(item.TextBounds.Y),
						textW = math.floor(item.TextBounds.X),
						min = limit and limit.MinTextSize or nil,
						fits = item.TextFits,
					})
				end
			end
		end
	end
	out = { rows = rows }
elseif COMMAND == "close_all" then
	ScreenManager.closeAllModals()
	out = { closed = true }
elseif COMMAND == "open_friends" then
	ScreenManager.open("Friends", { source = "hub" })
	task.wait(0.6)
	out = { open = ScreenManager.isOpen("Friends"), selected = GuiService.SelectedObject and GuiService.SelectedObject.Name }
elseif COMMAND == "open_hub" then
	ScreenManager.open("RewardsHub", { source = "hud" })
	task.wait(0.6)
	out = { open = ScreenManager.isOpen("RewardsHub") }
else
	out = { error = "unknown command" }
end
return HttpService:JSONEncode(out)
