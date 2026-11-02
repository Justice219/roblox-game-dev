--!nocheck
--[[
	nuke_pass_client.luau — client-VM probe for the R78 Nuke Pass screen (P-pass), run by
	tools/qa/nuke_pass.py through eval_client_runtime during ONE solo playtest.

		COMMAND  "diag"       HUD shown, profile + pass loaded, the HUD "Pass" offer visible
		         "close_all"  closes every modal (Welcome Back etc.)
		         "open"       ScreenManager.open("NukePass", { source = "hud" }); returns state()
		         "state"      state(): window open, header texts, CLAIM ALL text, premium CTA, overlay,
		                      the first tiers' button texts, chest, footer, scroll X, Offer_Pass shown
		         "point"      viewport centre of a control (ARGS[1]: 1 = CLAIM ALL, 2 = Free<ARGS[2]>
		                      button, 3 = Premium<ARGS[2]> button) for simulate_mouse_input
		         "garbage"    fires PassClaim / PassClaimAll with hostile arguments (server must refuse)
		         "fire_claim" fires the REAL PassClaim(track ARGS[1] 1 free / 2 premium / 3 overflow,
		                      tier ARGS[2]) intent (when a simulated click does not land)
		         "fire_all"   fires the REAL PassClaimAll() intent
		         "pad_on" / "pad_off" / "reopen"  forced Gamepad mode; reopen → SelectedObject name
		         "close"      closes the NukePass window
	Presentation only: every intent the server acts on goes through the real remotes.
]]

local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local LOCAL = Players.LocalPlayer
local client = LOCAL:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ClientState = require(client.ClientState)
local InputController = require(client.Controllers.InputController)
local ScreenManager = require(client.UI.ScreenManager)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)

local function gui(): ScreenGui?
	return ScreenManager.getGui("NukePass")
end

local function find(name: string): Instance?
	local root = gui()
	return if root ~= nil then root:FindFirstChild(name, true) else nil
end

local function labelOf(node: Instance?): string
	if node == nil then
		return ""
	end
	if node:IsA("TextLabel") or node:IsA("TextButton") then
		if node.Text ~= "" then
			return node.Text
		end
	end
	for _, child in node:GetDescendants() do
		if child:IsA("TextLabel") and child.Visible and child.Text ~= "" then
			return child.Text
		end
	end
	return ""
end

local function offerShown(): boolean
	local hud = ScreenManager.getGui("Hud")
	local offer = if hud ~= nil then hud:FindFirstChild("Offer_Pass", true) else nil
	return offer ~= nil and offer:IsA("GuiObject") and offer.Visible
end

local function state(): { [string]: any }
	local cells = {}
	for tier = 1, 6 do
		table.insert(cells, {
			tier = tier,
			free = labelOf(find(`Free{tier}_Button`)),
			premium = labelOf(find(`Premium{tier}_Button`)),
		})
	end
	local scroller = find("Track")
	local overlay = find("SeasonOverlay")
	local buy = find("BuyPremium")
	local owned = find("PremiumOwned")
	local window = find("StudWindow")
	return {
		open = ScreenManager.isOpen("NukePass"),
		top = ScreenManager.topModalName() or "",
		windowPx = if window ~= nil then { math.floor(window.AbsoluteSize.X), math.floor(window.AbsoluteSize.Y) } else nil,
		season = labelOf(find("SeasonTitle")),
		xp = labelOf(find("XpText")),
		play = labelOf(find("PlayText")),
		claimAll = labelOf(find("ClaimAll")),
		buyVisible = buy ~= nil and buy.Visible,
		buyLabel = labelOf(buy),
		ownedVisible = owned ~= nil and owned.Visible,
		overlay = overlay ~= nil and overlay.Visible,
		overlayText = if overlay ~= nil and overlay.Visible then labelOf(overlay) else "",
		cells = cells,
		tier30 = { free = labelOf(find("Free30_Button")), premium = labelOf(find("Premium30_Button")) },
		chest = labelOf(find("Chest_Button")),
		footer = labelOf(find("Footer")),
		scrollX = if scroller ~= nil then math.floor(scroller.CanvasPosition.X) else -1,
		claimPx = (function()
			local node = find("Free1_Button")
			return if node ~= nil then { math.floor(node.AbsoluteSize.X), math.floor(node.AbsoluteSize.Y) } else nil
		end)(),
		offer = offerShown(),
		pass = (function()
			local profile = ClientState.profile
			local pass = if type(profile) == "table" then profile.pass else nil
			return if type(pass) == "table" then { season = pass.season, xp = pass.xp, overflow = pass.overflow } else nil
		end)(),
	}
end

local function centre(node: GuiObject?): { [string]: number }
	if node == nil then
		return {}
	end
	-- simulate_mouse_input takes coordinates from the top of the viewport while the modal's
	-- AbsolutePosition starts under the Roblox top bar (verified 2026-10-31: exactly one
	-- GetGuiInset().Y short), so the inset is always added.
	local c = node.AbsolutePosition + node.AbsoluteSize / 2 + GuiService:GetGuiInset()
	local viewport = Workspace.CurrentCamera.ViewportSize
	return { x = math.floor(c.X), y = math.floor(c.Y), viewportX = math.floor(viewport.X) }
end

if COMMAND == "diag" then
	local hud = ScreenManager.getGui("Hud")
	local profile = ClientState.profile
	return HttpService:JSONEncode({
		hud = hud ~= nil and hud.Enabled,
		profile = type(profile) == "table" and type(profile.pass) == "table",
		top = ScreenManager.topModalName() or "",
		offer = offerShown(),
	})
elseif COMMAND == "close_all" then
	ScreenManager.closeAllModals()
	return "closed"
elseif COMMAND == "open" then
	ScreenManager.open("NukePass", { source = "hud" })
	task.wait(0.9)
	return HttpService:JSONEncode(state())
elseif COMMAND == "state" then
	return HttpService:JSONEncode(state())
elseif COMMAND == "point" then
	local which = math.floor(ARGS[1] or 1)
	local tier = math.floor(ARGS[2] or 1)
	local node = if which == 1
		then find("ClaimAll")
		elseif which == 2 then find(`Free{tier}_Button`)
		else find(`Premium{tier}_Button`)
	return HttpService:JSONEncode(centre(node :: GuiObject?))
elseif COMMAND == "garbage" then
	local claim = Remotes.event("PassClaim")
	local all = Remotes.event("PassClaimAll")
	for _, args in {
		{ "free", 0 / 0 },
		{ "free", math.huge },
		{ "free", 31 },
		{ "free", -1 },
		{ "free", 2.5 },
		{ "premium", 1 },
		{ "gold", 1 },
		{ 1, "free" },
		{ { "free" }, 1 },
		{ "free", "1" },
	} do
		claim:FireServer(args[1], args[2])
	end
	all:FireServer("junk", { 1, 2 })
	return "sent"
elseif COMMAND == "fire_claim" then
	local tracks = { "free", "premium", "overflow" }
	Remotes.event("PassClaim"):FireServer(tracks[math.floor(ARGS[1] or 1)], math.floor(ARGS[2] or 0))
	return "sent"
elseif COMMAND == "fire_all" then
	Remotes.event("PassClaimAll"):FireServer()
	return "sent"
elseif COMMAND == "pad_on" then
	InputController.setForcedMode("Gamepad")
	return InputController.mode
elseif COMMAND == "pad_off" then
	InputController.setForcedMode(nil)
	return InputController.mode
elseif COMMAND == "reopen" then
	ScreenManager.close("NukePass")
	task.wait(0.3)
	ScreenManager.open("NukePass", { source = "hud" })
	task.wait(0.8)
	local selected = GuiService.SelectedObject
	return if selected ~= nil then selected.Name else ""
elseif COMMAND == "close" then
	ScreenManager.close("NukePass")
	return "closed"
end
return HttpService:JSONEncode({ error = "unknown command " .. COMMAND })
