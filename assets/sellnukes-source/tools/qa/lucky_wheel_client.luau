--!nocheck
--[[
	lucky_wheel_client.luau — client-VM probe for the R81 Lucky Wheel spin juice (W-wheel), run by
	tools/qa/lucky_wheel.py through eval_client_runtime during ONE solo playtest.

		COMMAND  "diag"     HUD shown, profile loaded, usable spins, top modal
		         "open"     ScreenManager.open("LuckyWheel", { source = "qa" }); returns probe()
		         "close"    closes the wheel (mid-spin = the settle-at-once path)
		         "point"    viewport centre of the SPIN button (simulate_mouse_input: a REAL press)
		         "hold"     Studio DebugHold on the wheel root: freezes the FX clock (exact frames)
		         "release"  clears DebugHold
		         "preview"  fires the Studio-only DebugPreview(ARGS[1]) — the real presentation onto
		                    a fixed slice, no server call (RARE PET / EGG celebrations)
		         "probe"    probe(): disc / flapper rotation, arcs, glow, rays, lit bulbs, pop,
		                    confetti pieces, LastWinTier, FxDriving, SPIN text, control rects vs FX
	Presentation only: the real spin goes through the SPIN button → SpinWheel → server roll.
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

local function gui(): ScreenGui?
	return ScreenManager.getGui("LuckyWheel")
end

local function find(name: string): Instance?
	local root = gui()
	return if root ~= nil then root:FindFirstChild(name, true) else nil
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

local function labelOf(node: Instance?): string
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

local function probe()
	local wheel = find("Wheel")
	local canvas = find("Disc")
	local flapper = find("Flapper")
	local streaks = find("Streaks")
	local glow = find("WinGlow")
	local rays = find("WinRays")
	local pop = find("WinPop")
	local confetti = find("Confetti")
	local lit, bulbs = 0, 0
	local body = find("Body")
	if body ~= nil then
		for _, child in body:GetChildren() do
			if child:IsA("Frame") and string.match(child.Name, "^Bulb%d+$") then
				bulbs += 1
				if child.BackgroundColor3.R > 0.95 and child.BackgroundColor3.G > 0.9 then
					lit += 1
				end
			end
		end
	end
	local pieces = 0
	if confetti ~= nil then
		for _, child in confetti:GetChildren() do
			if child:IsA("Frame") and child.Visible then
				pieces += 1
			end
		end
	end
	local spin = find("Spin")
	return {
		open = ScreenManager.isOpen("LuckyWheel"),
		wheelZ = if wheel ~= nil then wheel.ZIndex else -99,
		disc = if canvas ~= nil then math.floor(canvas.Rotation * 10) / 10 else nil,
		flapper = if flapper ~= nil then math.floor(flapper.Rotation * 10) / 10 else nil,
		streaks = streaks ~= nil and streaks.Visible,
		glow = if glow ~= nil and glow.Visible then math.floor((1 - glow.GroupTransparency) * 100) / 100 else 0,
		rays = rays ~= nil and rays.Visible,
		bulbs = bulbs,
		lit = lit,
		pop = if pop ~= nil and pop.Visible then pop.Text else "",
		confetti = pieces,
		tier = if wheel ~= nil then wheel:GetAttribute("LastWinTier") else nil,
		driving = if wheel ~= nil then wheel:GetAttribute("FxDriving") else nil,
		spinText = labelOf(spin),
		spinRect = rect(spin),
		closeRect = rect(find("Close") or find("CloseButton")),
		wheelRect = rect(wheel),
	}
end

local function usableSpins(): number
	local profile = ClientState.profile
	local spin = if type(profile) == "table" then profile.spin else nil
	if type(spin) ~= "table" then
		return -1
	end
	return (spin.free or 0) + (spin.bonus or 0) + (spin.paid or 0)
end

if COMMAND == "diag" then
	local hud = ScreenManager.getGui("Hud")
	return HttpService:JSONEncode({
		hud = hud ~= nil and hud.Enabled,
		profile = type(ClientState.profile) == "table",
		spins = usableSpins(),
		top = ScreenManager.topModalName() or "",
	})
elseif COMMAND == "open" then
	ScreenManager.closeAllModals()
	ScreenManager.open("LuckyWheel", { source = "qa" })
	task.wait(0.8)
	return HttpService:JSONEncode(probe())
elseif COMMAND == "close" then
	ScreenManager.close("LuckyWheel")
	task.wait(0.1)
	return HttpService:JSONEncode(probe())
elseif COMMAND == "point" then
	local node = find("Spin")
	if node == nil then
		return "{}"
	end
	-- simulate_mouse_input counts from the top of the viewport; AbsolutePosition starts under the
	-- top bar inset (same correction as tools/qa/nuke_pass_client.luau).
	local c = node.AbsolutePosition + node.AbsoluteSize / 2 + GuiService:GetGuiInset()
	local viewport = Workspace.CurrentCamera.ViewportSize
	return HttpService:JSONEncode({ x = math.floor(c.X), y = math.floor(c.Y), viewportX = math.floor(viewport.X) })
elseif COMMAND == "hold" or COMMAND == "release" then
	local wheel = find("Wheel")
	if wheel ~= nil then
		wheel:SetAttribute("DebugHold", COMMAND == "hold")
	end
	return HttpService:JSONEncode(probe())
elseif COMMAND == "preview" then
	local event = find("DebugPreview")
	if event == nil then
		return "no DebugPreview"
	end
	event:Fire(ARGS[1])
	return "previewing"
elseif COMMAND == "probe" then
	return HttpService:JSONEncode(probe())
end
return "unknown command"
