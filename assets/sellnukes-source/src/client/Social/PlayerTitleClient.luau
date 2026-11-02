--!strict
--[[
	PlayerTitleClient — draws Player Titles (owner R73: "give me a name tag whenever I'm in the game
	so people know I'm the developer"; R74: DEVELOPER / FIRST PLAYER / EARLY PLAYER). A boot
	controller (Init / Start): "Social/PlayerTitleClient".

	What it shows (display only; WHICH title a player wears is decided on the server):
		- Overhead tag: a stud panel "[icon] DEVELOPER" in the title's colour
		  (PlayerTitlesConfig.Titles) in a BillboardGui on the character's Head, just above
		  Roblox's own name (StudsOffset ~2). Sized in STUDS like a real name tag (it shrinks with
		  distance and never dominates the screen) + a small pixel floor so it stays readable at
		  ~20-60 studs on phones and TVs; MaxDistance 120; AlwaysOnTop off (walls hide it).
		  Every OTHER client draws it; the holder sees their own only when the title allows it
		  (TitleDef.showOwn, owner R77: FIRST / EARLY PLAYER yes, DEVELOPER no — it sat in the middle
		  of the owner's view, lead review 2026-10-31).
		- Chat: TextChatService.OnIncomingMessage puts the title's coloured chat tag ("[DEV]",
		  "[FIRST PLAYER]", "[EARLY]") in front of the speaker's name (PlayerTitles.chatPrefix:
		  constant catalogue rich text in front of the engine's already-escaped name; nothing
		  player-written is interpreted). This module is the ONLY OnIncomingMessage callback in the
		  game (the property holds one function).
	Both follow the server-set Player attributes Title (catalogue key) and TitleHidden (the
	holder's own "MY TITLE TAG: ON / OFF" chip), read through PlayerTitles.shown.

	Robustness: survives respawn (Character changes), world travel (the tag follows its Head
	adornee to Dino Valley / Moon Base; nothing is world-specific), New Player Mode (the server
	keeps permanent titles in the sandbox) and streaming (a streamed-out Head detaches the tag; the
	Head or a new character streaming back in re-attaches it).

	Performance: one BillboardGui per VISIBLE titled player (usually 0-2 per server), built once and
	pooled; a title change only restyles (colour, icon, text). Everything is event-driven
	(attribute, Character, ChildAdded, AncestryChanged signals): no per-frame work, no polling.

	Security: clients cannot set replicated Player attributes, so nobody can fake a title; this
	module only reads them.

	Connects to: Shared/Config/PlayerTitlesConfig, Shared/Util/PlayerTitles, UI/{Create,
	Kit/StudUI, Widgets/StudWindow}, Server/Services/PlayerTitleService (sets the attributes).

	Example: PlayerTitleClient.shownTitle(owner) --> "developer" while the owner's tag is drawn
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Create = require(script.Parent.Parent.UI.Create)
local PlayerTitles = require(ReplicatedStorage.Shared.Util.PlayerTitles)
local PlayerTitlesConfig = require(ReplicatedStorage.Shared.Config.PlayerTitlesConfig)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.UI.Widgets.StudWindow)

local PlayerTitleClient = {}

local Tag = PlayerTitlesConfig.Tag

-- One pooled tag: the billboard + the parts a restyle touches.
type Visual = {
	gui: BillboardGui,
	surface: StudWindow.Surface,
	label: TextLabel,
	iconHolder: Frame,
	icons: { [string]: Frame },
}

-- One drawn tag: its visual + the connections that follow the player's character.
type Entry = {
	visual: Visual,
	title: string,
	character: Model?,
	characterConnections: { RBXScriptConnection },
	head: BasePart?, -- the Head the tag is attached to
	headConnection: RBXScriptConnection?, -- that Head's AncestryChanged (streamed out / destroyed)
}

local localPlayer = Players.LocalPlayer
local entries: { [Player]: Entry } = {}
local pool: { Visual } = {}
-- Per-player attribute / character listeners (every player, so a tag can appear any time).
local watchers: { [Player]: { RBXScriptConnection } } = {}
local started = false

-- Builds one tag billboard (pooled; parented to PlayerGui so it survives respawns).
local function buildVisual(): Visual
	local gui = Create.new("BillboardGui", {
		Name = "PlayerTitle",
		Size = UDim2.new(Tag.StudsWidth, Tag.PixelWidth, Tag.StudsHeight, Tag.PixelHeight),
		StudsOffset = Tag.StudsOffset,
		MaxDistance = Tag.MaxDistance,
		AlwaysOnTop = false,
		LightInfluence = 0,
		ResetOnSpawn = false,
		Active = false,
		Enabled = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}) :: BillboardGui
	local panel = Create.new("Frame", {
		Name = "Panel",
		Size = UDim2.fromScale(1, 1),
		Active = false,
		Parent = gui,
	}) :: Frame
	local surface = StudWindow.surface(panel, "yellow", { edge = 3, corner = 10 })
	-- The icon slot on the left (square, scales with the tag); icons are built per key, once.
	local iconHolder = Create.new("Frame", {
		Name = "IconSlot",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0.03, 0.5),
		Size = UDim2.fromScale(0.2, 0.86),
		Active = false,
		ZIndex = 3,
		Parent = panel,
		Children = { Create.new("UIAspectRatioConstraint", { AspectRatio = 1 }) },
	}) :: Frame
	local label = StudUI.text({
		name = "Label",
		text = "",
		textSize = 40,
		font = "shout",
		scaled = true,
		anchor = Vector2.new(0, 0.5),
		position = UDim2.fromScale(0.24, 0.5),
		size = UDim2.fromScale(0.73, Tag.TextScale),
		zIndex = 4,
		parent = panel,
	})
	label.TextXAlignment = Enum.TextXAlignment.Center
	return { gui = gui, surface = surface, label = label, iconHolder = iconHolder, icons = {} }
end

-- Restyles a visual for a title (colour, icon, text); cheap, only on a title change.
local function style(visual: Visual, entry: PlayerTitlesConfig.TitleDef)
	visual.surface.setColor(entry.color :: any)
	visual.label.Text = entry.label
	if visual.icons[entry.icon] == nil then
		local icon = StudUI.icon(entry.icon, 32, 3)
		icon.Size = UDim2.fromScale(1, 1)
		icon.Parent = visual.iconHolder
		visual.icons[entry.icon] = icon
	end
	for key, icon in visual.icons do
		icon.Visible = key == entry.icon
	end
end

-- Disconnects a list of connections in place.
local function disconnectAll(list: { RBXScriptConnection })
	for _, connection in list do
		connection:Disconnect()
	end
	table.clear(list)
end

-- Points the tag at the character's Head (detached while the Head is not streamed in) and
-- follows that Head leaving the world (stream-out / destroy) with one AncestryChanged connection.
local function attach(entry: Entry)
	local character = entry.character
	local found = if character ~= nil then character:FindFirstChild("Head") else nil
	local head: BasePart? = if found ~= nil
			and found:IsA("BasePart")
			and found:IsDescendantOf(workspace)
		then found
		else nil
	if head ~= entry.head then
		local old = entry.headConnection
		if old ~= nil then
			old:Disconnect()
			entry.headConnection = nil
		end
		entry.head = head
		if head ~= nil then
			entry.headConnection = head.AncestryChanged:Connect(function()
				attach(entry)
			end)
		end
	end
	local gui: any = entry.visual.gui
	-- `any` view: a nil Adornee (detached) is valid but the definitions type it non-optional.
	gui.Adornee = head
	gui.Enabled = head ~= nil
end

-- Follows a (new) character: attach now, re-attach when its Head streams in.
local function bindCharacter(entry: Entry, character: Model?)
	disconnectAll(entry.characterConnections)
	entry.character = character
	if character ~= nil then
		table.insert(
			entry.characterConnections,
			character.ChildAdded:Connect(function(child: Instance)
				if child.Name == "Head" then
					attach(entry)
				end
			end)
		)
	end
	attach(entry)
end

-- Removes a player's tag (the visual goes back to the pool).
local function hide(player: Player)
	local entry = entries[player]
	if entry == nil then
		return
	end
	entries[player] = nil
	disconnectAll(entry.characterConnections)
	local headConnection = entry.headConnection
	if headConnection ~= nil then
		headConnection:Disconnect()
	end
	local gui: any = entry.visual.gui
	gui.Enabled = false
	gui.Adornee = nil
	table.insert(pool, entry.visual)
end

-- Shows / restyles a player's tag for a title (reusing a pooled visual).
local function show(player: Player, entry: PlayerTitlesConfig.TitleDef)
	local existing = entries[player]
	if existing ~= nil then
		if existing.title ~= entry.key then
			existing.title = entry.key
			style(existing.visual, entry)
		end
		return
	end
	local visual = table.remove(pool) or buildVisual()
	style(visual, entry)
	visual.gui.Name = `PlayerTitle_{player.UserId}`
	visual.gui.Parent = localPlayer:FindFirstChildOfClass("PlayerGui")
	local drawn: Entry = {
		visual = visual,
		title = entry.key,
		character = nil,
		characterConnections = {},
		head = nil,
		headConnection = nil,
	}
	entries[player] = drawn
	bindCharacter(drawn, player.Character)
end

-- Re-evaluates one player's tag from its replicated attributes.
local function refresh(player: Player)
	if player.Parent ~= Players then
		hide(player)
		return
	end
	local entry = PlayerTitles.shown(
		player:GetAttribute(PlayerTitlesConfig.Attr),
		player:GetAttribute(PlayerTitlesConfig.HiddenAttr)
	)
	-- Owner R77: the holder sees their own tag only when the title allows it (FIRST / EARLY
	-- PLAYER yes, DEVELOPER no); every other client always draws a shown title.
	if entry ~= nil and (player ~= localPlayer or entry.showOwn) then
		show(player, entry)
	else
		hide(player)
	end
end

-- Starts watching one player (attributes + character changes).
local function watch(player: Player)
	if watchers[player] ~= nil then
		return
	end
	local connections: { RBXScriptConnection } = {}
	watchers[player] = connections
	local function onAttr()
		refresh(player)
	end
	table.insert(connections, player:GetAttributeChangedSignal(PlayerTitlesConfig.Attr):Connect(onAttr))
	table.insert(connections, player:GetAttributeChangedSignal(PlayerTitlesConfig.HiddenAttr):Connect(onAttr))
	-- Respawns and streamed-in characters (Character is replaced): follow the new one.
	table.insert(
		connections,
		player:GetPropertyChangedSignal("Character"):Connect(function()
			local entry = entries[player]
			if entry ~= nil then
				bindCharacter(entry, player.Character)
			end
		end)
	)
	refresh(player)
end

-- Stops watching a player who left.
local function unwatch(player: Player)
	hide(player)
	local connections = watchers[player]
	if connections ~= nil then
		disconnectAll(connections)
		watchers[player] = nil
	end
end

--[[
	The chat hook: the speaker's title tag in front of their name while their title shows.
	Returns nil for everyone else (the default look).
]]
local function onIncomingMessage(message: TextChatMessage): TextChatMessageProperties?
	local source = message.TextSource
	if source == nil then
		return nil
	end
	local speaker = Players:GetPlayerByUserId(source.UserId)
	if speaker == nil then
		return nil
	end
	local entry = PlayerTitles.shown(
		speaker:GetAttribute(PlayerTitlesConfig.Attr),
		speaker:GetAttribute(PlayerTitlesConfig.HiddenAttr)
	)
	if entry == nil then
		return nil
	end
	local properties = Instance.new("TextChatMessageProperties")
	properties.PrefixText = PlayerTitles.chatPrefix(entry, message.PrefixText)
	return properties
end

--[[
	Draws a title on any rig (a test NPC / dummy: Studio captures of the "second player" view, which
	a solo playtest cannot show, and any future showcase NPC). Display only; nothing is sent.
	@param model a character-like Model with a Head
	@param key   a catalogue title key
	@return a cleanup function, or nil for an unknown key
	Example: local stop = PlayerTitleClient.preview(dummy, "firstPlayer") ... stop()
]]
function PlayerTitleClient.preview(model: Model, key: string): (() -> ())?
	local entry = PlayerTitles.def(key)
	if entry == nil then
		return nil
	end
	local visual = table.remove(pool) or buildVisual()
	style(visual, entry)
	visual.gui.Name = `PlayerTitlePreview_{key}`
	visual.gui.Parent = localPlayer:FindFirstChildOfClass("PlayerGui")
	local drawn: Entry = {
		visual = visual,
		title = key,
		character = nil,
		characterConnections = {},
		head = nil,
		headConnection = nil,
	}
	bindCharacter(drawn, model)
	return function()
		disconnectAll(drawn.characterConnections)
		local headConnection = drawn.headConnection
		if headConnection ~= nil then
			headConnection:Disconnect()
		end
		local gui: any = visual.gui
		gui.Enabled = false
		gui.Adornee = nil
		table.insert(pool, visual)
	end
end

--[[ The title drawn over `player` right now (catalogue key), or nil (QA / Studio probes). ]]
function PlayerTitleClient.shownTitle(player: Player): string?
	local entry = entries[player]
	return if entry ~= nil and entry.visual.gui.Enabled then entry.title else nil
end

function PlayerTitleClient.Init() end

--[[ Starts the tags + the chat hook (once). ]]
function PlayerTitleClient.Start()
	if started then
		return
	end
	started = true
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(unwatch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	-- The chat tag needs the modern TextChatService (this place uses it; the legacy chat has no
	-- per-message hook and is not used here).
	if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		TextChatService.OnIncomingMessage = onIncomingMessage
	end
end

return PlayerTitleClient
