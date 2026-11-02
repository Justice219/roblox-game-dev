--!strict
--[[
	player_titles_client.luau — CLIENT half of the Player Titles check (owner R73 / R74;
	tools/qa/player_titles.py, eval_client_runtime). Whitelisted COMMAND + numeric ARGS only (no
	free-form text reaches Luau).

	state     JSON: Title / TitleHidden attributes, the title PlayerTitleClient draws, the
	          billboard's adornee / enabled / label, LoadingDone / PlotRevealed, the chat version,
	          whether the admin catalogue lists TitleGrant / TitleRevoke
	camera    a Scriptable camera framing the local character's head from the front (ARGS[1] =
	          distance in studs) so the tag and Roblox's own name show in one capture
	chat      sends one chat message through the REAL TextChatService (RBXGeneral:SendAsync); the
	          title's chat tag is added by PlayerTitleClient's OnIncomingMessage
	toggle    the REAL SetSetting intent: ARGS[1] 1 = show, 0 = hide (the admin chip sends the same)
	panel     opens the admin panel: ARGS[1] 1 = Server tab (title chip), 2 = Players tab, 0 closes
	grant     the REAL admin path (AdminClient.send -> AdminCommand remote -> server re-auth,
	          validation, audit): ARGS[1] 1 = TitleGrant earlyPlayer on yourself, 0 = TitleRevoke
	modals    closes every open window
	reset     back to the default follow camera
	dummies   the "second player" view a solo playtest cannot have: two anchored clones of the
	          local character ARGS[1] studs ahead, wearing DEVELOPER and FIRST PLAYER through
	          PlayerTitleClient.preview (Roblox's own names "JusticeDev" / "<player>" under them),
	          and a camera looking at them from ARGS[1] studs; ARGS[1] = 0 removes them
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local COMMAND = "__COMMAND__"
local ARGS: { number } = { --[[ARGS]]
}

local player = Players.LocalPlayer
local client = player:WaitForChild("PlayerScripts"):WaitForChild("Client")
local camera = workspace.CurrentCamera

if COMMAND == "state" then
	local PlayerTitleClient = (require :: any)(client.Social.PlayerTitleClient)
	local AdminClient = (require :: any)(client.UI.Screens.Admin.AdminClient)
	local gui = player:WaitForChild("PlayerGui"):FindFirstChild(`PlayerTitle_{player.UserId}`)
	local label = if gui ~= nil then gui:FindFirstChild("Label", true) else nil
	local commands: { string } = {}
	for _, info in AdminClient.commandsFor("Players") do
		if string.sub(info.name, 1, 5) == "Title" then
			table.insert(commands, info.name)
		end
	end
	return HttpService:JSONEncode({
		title = player:GetAttribute("Title"),
		hidden = player:GetAttribute("TitleHidden"),
		shown = PlayerTitleClient.shownTitle(player),
		gui = if gui ~= nil and gui:IsA("BillboardGui")
			then {
				enabled = gui.Enabled,
				adornee = if gui.Adornee ~= nil then gui.Adornee:GetFullName() else "",
				maxDistance = gui.MaxDistance,
				alwaysOnTop = gui.AlwaysOnTop,
				label = if label ~= nil and label:IsA("TextLabel") then label.Text else "",
			}
			else nil,
		loadingDone = player:GetAttribute("LoadingDone") == true,
		revealed = player:GetAttribute("PlotRevealed") == true,
		chatVersion = TextChatService.ChatVersion.Name,
		adminCommands = commands,
		world = player:GetAttribute("CurrentWorld") or "main",
	})
elseif COMMAND == "camera" then
	local character = player.Character
	local head = if character ~= nil then character:FindFirstChild("Head") else nil
	if head == nil or not head:IsA("BasePart") then
		return "ERROR no head"
	end
	local distance = math.clamp(ARGS[1] or 12, 4, 60)
	local look = head.CFrame.LookVector
	local target = head.Position + Vector3.new(0, 1.8, 0)
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 60
	camera.CFrame = CFrame.lookAt(target + look * distance + Vector3.new(0, 1.2, 0), target)
	return "camera set"
elseif COMMAND == "chat" then
	local channels = TextChatService:FindFirstChild("TextChannels")
	local general = if channels ~= nil then channels:FindFirstChild("RBXGeneral") else nil
	if general == nil or not general:IsA("TextChannel") then
		return "ERROR no RBXGeneral"
	end
	general:SendAsync("Hi everyone, welcome to Sell Nukes!")
	return "sent"
elseif COMMAND == "toggle" then
	local Remotes = (require :: any)(ReplicatedStorage.Shared.Net.Remotes)
	Remotes.event("SetSetting"):FireServer("showTitle", (ARGS[1] or 1) ~= 0)
	return "toggled"
elseif COMMAND == "panel" then
	local ScreenManager = (require :: any)(client.UI.ScreenManager)
	local code = math.floor(ARGS[1] or 1)
	if code == 0 then
		ScreenManager.close("AdminPanel")
		return "closed"
	end
	ScreenManager.open("AdminPanel", { tab = if code == 2 then "Players" else "Server" })
	return "opened"
elseif COMMAND == "grant" then
	local AdminClient = (require :: any)(client.UI.Screens.Admin.AdminClient)
	local give = (ARGS[1] or 1) ~= 0
	local sent = AdminClient.send(
		if give then "TitleGrant" else "TitleRevoke",
		{ userId = player.UserId, title = "earlyPlayer" }
	)
	return `{if give then "grant" else "revoke"} sent={sent}`
elseif COMMAND == "modals" then
	local ScreenManager = (require :: any)(client.UI.ScreenManager)
	local closed = 0
	while ScreenManager.anyModalOpen() and closed < 8 do
		ScreenManager.closeTopModal()
		closed += 1
		task.wait(0.3)
	end
	return `closed {closed}`
elseif COMMAND == "dummies" then
	local PlayerTitleClient = (require :: any)(client.Social.PlayerTitleClient)
	local store = (_G :: any).__TitleDummies or {}
	(_G :: any).__TitleDummies = store
	for _, item in store do
		item.stop()
		item.model:Destroy()
	end
	table.clear(store)
	local distance = ARGS[1] or 20
	if distance <= 0 then
		camera.CameraType = Enum.CameraType.Custom
		return "dummies removed"
	end
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if character == nil or root == nil or not root:IsA("BasePart") then
		return "ERROR no character"
	end
	character.Archivable = true
	local base = root.CFrame
	local ahead = base * CFrame.new(0, 0, -distance)
	for index, spec in { { key = "developer", name = "JusticeDev" }, { key = "firstPlayer", name = "<player>" } } do
		local clone = character:Clone()
		clone.Name = `TitleDummy{index}`
		for _, part in clone:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = true
			elseif part:IsA("Script") or part:IsA("LocalScript") then
				part:Destroy()
			end
		end
		local humanoid = clone:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil then
			humanoid.DisplayName = spec.name
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
		end
		-- Side by side, facing the camera (back towards the player).
		clone:PivotTo(ahead * CFrame.new((index - 1.5) * 6, 0, 0) * CFrame.Angles(0, math.pi, 0))
		clone.Parent = workspace
		local stop = PlayerTitleClient.preview(clone, spec.key)
		table.insert(store, { model = clone, stop = stop or function() end })
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 70
	local eye = (base * CFrame.new(0, 3, 0)).Position
	camera.CFrame = CFrame.lookAt(eye, ahead.Position + Vector3.new(0, 2.5, 0))
	return `dummies at {distance}`
elseif COMMAND == "reset" then
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	return "reset"
end
return `ERROR unknown command {COMMAND}`
