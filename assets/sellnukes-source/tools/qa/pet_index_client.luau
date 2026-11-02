--!nocheck
--[[
	pet_index_client.luau — client-VM probe for the R78 Pet Index rewards panel + Golden Nukey, run
	by tools/qa/pet_index.py through eval_client_runtime during ONE solo playtest.

		COMMAND  "diag"        HUD shown, profile loaded, Pets HUD badge text
		         "close_all"   closes every modal (Welcome Back etc.)
		         "open_index"  ScreenManager.open("Pets", { tab = "index" }); returns panelState()
		         "state"       panelState(): panel visible, header stat, bonus, pips, bar, next line,
		                       CLAIM text / state, INDEX tab badge, HUD Pets badge
		         "point"       viewport pixel centre of a named control (ARGS[1]: 1 = CLAIM,
		                       2 = pager ">", 3 = card 1) for simulate_mouse_input
		         "open_nukey"  the deep link { tab = "index", select = "golden_nukey" } → side texts
		         "side"        the side card's visible texts
		         "pad_on" / "pad_off" / "reopen"  forced Gamepad mode; reopen → SelectedObject name
		         "pets_cam"    hides the HUD + points the camera at the player's following pets
		         "cam_reset"   restores the camera + HUD
	Presentation only: the CLAIM intent is sent by a real click (simulate_mouse_input) in the .py.
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
local InputController = require(client.Controllers.InputController)
local ScreenManager = require(client.UI.ScreenManager)

local function gui(): ScreenGui?
	return ScreenManager.getGui("Pets")
end

local function find(name: string): Instance?
	local root = gui()
	return if root ~= nil then root:FindFirstChild(name, true) else nil
end

local function textOf(parent: Instance?, name: string): string
	local node = if parent ~= nil then parent:FindFirstChild(name, true) else nil
	return if node ~= nil and node:IsA("TextLabel") then node.Text else ""
end

local function hudBadge(): string
	local hud = ScreenManager.getGui("Hud")
	if hud == nil then
		return "?"
	end
	for _, node in hud:GetDescendants() do
		if node.Name == "Badge" and node:IsA("Frame") and node.Visible then
			local holder = node.Parent
			if holder ~= nil and string.find(holder.Name, "Pets", 1, true) ~= nil then
				local label = node:FindFirstChild("BadgeText", true)
				return if label ~= nil then label.Text else "!"
			end
		end
	end
	return ""
end

local function panelState(): { [string]: any }
	local panel = find("IndexRewards")
	local claim = find("IndexClaim")
	local pips = {}
	if panel ~= nil then
		local row = panel:FindFirstChild("Pips", true)
		if row ~= nil then
			for _, pip in row:GetChildren() do
				if pip:IsA("Frame") then
					local gradient = pip:FindFirstChildWhichIsA("UIGradient", true)
					table.insert(pips, {
						name = pip.Name,
						order = pip.LayoutOrder,
						top = if gradient ~= nil then gradient.Color.Keypoints[1].Value:ToHex() else "",
					})
				end
			end
			table.sort(pips, function(a, b)
				return a.order < b.order
			end)
		end
	end
	local badge = find("IndexBadge")
	local claimLabel = if claim ~= nil then claim:FindFirstChildWhichIsA("TextLabel", true) else nil
	local topBar = find("TopBar")
	local stat = ""
	if topBar ~= nil then
		for _, node in topBar:GetChildren() do
			if node:IsA("TextLabel") and string.find(node.Text, "Discovered", 1, true) then
				stat = node.Text
			end
		end
	end
	local panelBox = if panel ~= nil
		then {
			x = math.floor(panel.AbsolutePosition.X),
			y = math.floor(panel.AbsolutePosition.Y),
			w = math.floor(panel.AbsoluteSize.X),
			h = math.floor(panel.AbsoluteSize.Y),
		}
		else nil
	local card = find("SideCard")
	local cardBox = if card ~= nil
		then {
			y = math.floor(card.AbsolutePosition.Y),
			h = math.floor(card.AbsoluteSize.Y),
		}
		else nil
	return {
		open = ScreenManager.isOpen("Pets"),
		top = ScreenManager.topModalName() or "",
		panelVisible = panel ~= nil and panel.Visible,
		panelBox = panelBox,
		cardBox = cardBox,
		stat = stat,
		bonus = textOf(panel, "Bonus"),
		bar = textOf(panel, "Count"),
		nextLine = textOf(panel, "Next"),
		claim = if claimLabel ~= nil then claimLabel.Text else "",
		claimPx = if claim ~= nil then { math.floor(claim.AbsoluteSize.X), math.floor(claim.AbsoluteSize.Y) } else nil,
		pips = pips,
		tabBadge = badge ~= nil and badge.Visible,
		hudBadge = hudBadge(),
	}
end

local function centre(node: GuiObject?): { [string]: number }
	if node == nil then
		return {}
	end
	local root = gui()
	local inset = if root ~= nil and root.IgnoreGuiInset then Vector2.zero else GuiService:GetGuiInset()
	local c = node.AbsolutePosition + node.AbsoluteSize / 2 + inset
	local viewport = Workspace.CurrentCamera.ViewportSize
	return { x = math.floor(c.X), y = math.floor(c.Y), viewportX = math.floor(viewport.X) }
end

if COMMAND == "diag" then
	local hud = ScreenManager.getGui("Hud")
	local profile = ClientState.profile
	return HttpService:JSONEncode({
		hud = hud ~= nil and hud.Enabled,
		profile = type(profile) == "table" and type(profile.pets) == "table",
		top = ScreenManager.topModalName() or "",
		hudBadge = hudBadge(),
	})
elseif COMMAND == "close_all" then
	ScreenManager.closeAllModals()
	return "closed"
elseif COMMAND == "open_index" then
	ScreenManager.open("Pets", { tab = "index" })
	task.wait(0.6)
	return HttpService:JSONEncode(panelState())
elseif COMMAND == "state" then
	return HttpService:JSONEncode(panelState())
elseif COMMAND == "point" then
	local which = math.floor(ARGS[1] or 1)
	local node = if which == 1 then find("IndexClaim") elseif which == 2 then find("Button_>") else find("Card1")
	return HttpService:JSONEncode(centre(node :: GuiObject?))
elseif COMMAND == "open_nukey" then
	ScreenManager.open("Pets", { tab = "index", select = "golden_nukey" })
	task.wait(0.8)
	local card = find("SideCard")
	local texts = {}
	if card ~= nil then
		for _, node in card:GetDescendants() do
			if node:IsA("TextLabel") and node.Visible and node.Text ~= "" then
				table.insert(texts, node.Text)
			end
		end
	end
	return HttpService:JSONEncode(texts)
elseif COMMAND == "side" then
	local card = find("SideCard")
	local texts = {}
	if card ~= nil then
		for _, node in card:GetDescendants() do
			if node:IsA("TextLabel") and node.Visible and node.Text ~= "" then
				table.insert(texts, node.Text)
			end
		end
	end
	return HttpService:JSONEncode(texts)
elseif COMMAND == "pad_on" then
	InputController.setForcedMode("Gamepad")
	return InputController.mode
elseif COMMAND == "pad_off" then
	InputController.setForcedMode(nil)
	return InputController.mode
elseif COMMAND == "reopen" then
	ScreenManager.close("Pets")
	task.wait(0.3)
	ScreenManager.open("Pets", { tab = "index" })
	task.wait(0.6)
	local selected = GuiService.SelectedObject
	return if selected ~= nil then selected.Name else ""
elseif COMMAND == "pets_cam" then
	ScreenManager.closeAllModals()
	local hud = ScreenManager.getGui("Hud")
	if hud ~= nil then
		hud.Enabled = false
	end
	local character = LOCAL.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil then
		return "no character"
	end
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	-- Behind-left of the player, looking at the pet arc behind them (pets follow ~5.5 studs back).
	local back = root.CFrame * CFrame.new(0, 0, 5.5)
	local eye = root.CFrame * CFrame.new(-5, 3.2, 12)
	camera.CFrame = CFrame.lookAt(eye.Position, back.Position + Vector3.new(0, 1, 0))
	return "ok"
elseif COMMAND == "pets_front" then
	local character = LOCAL.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil then
		return "no character"
	end
	-- Find the local Golden Nukey model under workspace.ClientPets (PetController's folder).
	-- The local Golden Nukey's Body piece (PetController names the model "Pet_golden_nukey"; its
	-- Root part is a pivot helper, so the visible Body is the camera target).
	local folder = Workspace:FindFirstChild("ClientPets")
	local target: BasePart? = nil
	if folder ~= nil then
		for _, node in folder:GetDescendants() do
			if node:IsA("BasePart") and node.Name == "Body" and node.Parent ~= nil and node.Parent.Name == "Pet_golden_nukey" then
				target = node
				break
			end
		end
	end
	local hud = ScreenManager.getGui("Hud")
	if hud ~= nil then
		hud.Enabled = false
	end
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	local focus = if target ~= nil then target.Position else (root.CFrame * CFrame.new(0, 0, 5.5)).Position
	-- In front of the pet (it faces the owner's walk direction), slightly right and above, looking
	-- back at its face: the owner stands further ahead, behind the camera.
	local look = root.CFrame.LookVector
	local right = root.CFrame.RightVector
	local eye = focus + look * 4.2 + right * 1.6 + Vector3.new(0, 1.3, 0)
	camera.CFrame = CFrame.lookAt(eye, focus + Vector3.new(0, 0.2, 0))
	return if target ~= nil then `{target.Parent.Name} @ {math.floor((eye - focus).Magnitude * 10) / 10}` else "pet model not found"
elseif COMMAND == "cam_reset" then
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom
	local hud = ScreenManager.getGui("Hud")
	if hud ~= nil then
		hud.Enabled = true
	end
	return "ok"
end
return "unknown"
