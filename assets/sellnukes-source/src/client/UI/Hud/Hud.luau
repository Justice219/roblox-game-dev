--!strict
--[[
	Hud — the SellNukes HUD shell and its public API (spec §6, reference shots).

	Zones (positions from Widgets/HudPlacement, published to Widgets/HudZones):
		Top centre  Gems, Cash, +$X/s                 (HudCurrency)
		Left        square stud buttons + the MORE tile (HudButtons) and its flyout (HudMoreMenu)
		Right       rotating starburst Robux offers    (HudOffers)
		Bottom      objective chip + world arrow       (HudObjective)
		BottomRight WHAT'S NEW chip + NEW badge        (HudWhatsNew, owner R58; under the offers,
		            published as part of the "Right" zone)
		TopRight    the admin wrench chip, admins only (HudAdminChip, owner R62) + the INVITE
		            button left of it (HudInvite, owner R122: "+10%" Friend Boost sticker, opens
		            Roblox's invite prompt; only while invites are available); both published as
		            the "TopRight" zone (their union)
	Owner R110 ("can we cut down on the cards on the left at all? there is just a bunch lol"): the
	left stack is Shop, Pets, Quests, Rewards, Attack + MORE (a 2 x 3 grid on every device; 5 tiles
	while Attack is hidden). MORE opens a compact stud flyout beside the grid (Hud/HudMoreMenu)
	with Teleport, Rebirth, the Event (while live) and Settings; their badges / NEW tags roll up
	onto MORE. Every Hud.setButton* key keeps working (moved keys route to the flyout items).
	Owner R62: Rewards opens H3-hub's Rewards hub and wears UI/RewardsBadges' total. Owner R59:
	on PHONES the stack is a compact 2 x 3 grid of 44 pt tiles in the top-left corner, the offers
	shrink and WHAT'S NEW becomes an icon-only star (HudPlacement.computePhone).
		Toasts      a separate screen above windows    (Toasts)
	Menus (owner R79): while any menu (modal) is open the HUD keeps only the currency stack (+ the
	admin chip): the left buttons (+ the R110 MORE flyout, which also closes when a menu opens),
	the offers, WHAT'S NEW and the objective chip live in one full-canvas "MenuLayer" that fades
	out with the menu and back in when the last menu closes, so a window is never framed by shop /
	offer buttons.

	Public API (for later builders):
		Hud.setIncomeSource(fn)        the tycoon client installs `fn(): number` returning the
		                               player's current $/s (computed from server state with the
		                               shared TycoonLogic); polled once per second + on every
		                               profile change. Until then the HUD shows
		                               `profile.incomePerSecond` when the server sends it, else
		                               hides the rate row.
		Hud.setObjective(text, target?) objective chip (+ world arrow at a BasePart / Attachment /
		                               Model / Vector3); nil text hides it.
		Hud.setButtonVisible(key, on)  show / hide a left button (Attack after the silo unlock,
		                               Event while Harvest Feast runs — a MORE flyout item since
		                               R110). Attack also auto-shows when profile.attack.launcher > 0.
		Hud.setButtonBadge(key, text?) red badge on a left button ("!" claimable, "3", nil hides);
		                               flyout items' badges also roll up onto MORE (R110)
		Hud.notify(kind, text, icon?)  local toast (same look as server Notify toasts)
		Hud.focusButtons() / focusOffers()  gamepad: move the selection onto the HUD columns
		                               (focusButtons: the open MORE flyout's first item, else Shop)
		Hud.setMoreOpen(on, focus?) / Hud.moreOpen()  R110: open / close the MORE flyout (focus =
		                               gamepad cursor onto its first item / back onto MORE)
		Hud.screens()                  the ScreenModules UIController registers ("Hud", "Toasts")
	Worlds (owner R57 World 2; driven by Client/Worlds/WorldClient, which requires the HUD — the
	HUD never requires it back):
		Hud.setWorld(worldId)          the world the player is in: the currency stack swaps to that
		                               world's currency as primary (+ a Cash pill; HudCurrency), its
		                               "+X/s" comes from the server's Player attribute
		                               IncomePerSecond_<world>, Nuke-Town-only buttons hide (Attack
		                               while WorldDef.features.attack is false), the offers add that
		                               world's rotation rows (Time Traveler Pack) and the objective
		                               chip shows that world's objective instead of the tutorial's
		Hud.setWorldObjective(text?, target?)  the non-main world's objective (WorldObjectives)
		Hud.setButtonNew(key, on)      a yellow NEW tag on a left button (Teleport until the first
		                               visit of an unlocked world; a MORE flyout item since R110,
		                               so MORE wears the rolled-up NEW too)

	Security: display only. Every value shown is server state (ClientState) or derived from it;
	buttons only open screens or send purchase INTENTS (HudOffers).

	Performance: event-driven re-layout (ScreenManager.LayoutChanged / SafeAreaChanged / button
	visibility, incl. the MORE flyout's item count); one 1 Hz income poll only while a source is
	installed; no per-frame work except the objective arrow while a target is set.

	Money FX (owner R46): the build attaches Hud/CurrencyFly to the currency counters — cash / gem
	sprites fly from producers, rewards, purchases and the offline claim into the counters, which
	pop + glint as they land (visual only; the numbers stay the server's).

	Connects to: Client/ClientState, UI/ScreenManager, Widgets/{HudPlacement, HudZones},
	Hud/{HudCurrency, HudButtons (+ HudMoreMenu), HudOffers, HudObjective, Toasts, CurrencyFly,
	HudWhatsNew, HudAdminChip, HudInvite},
	Controllers/UIController.

	Example:
		local Hud = require(Client.UI.Hud.Hud)
		Hud.setIncomeSource(function() return TycoonClient.incomePerSecond() end)
		Hud.setObjective("Buy the Reactor pad!", padPart)
		Hud.setButtonBadge("Pets", "3")
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local WorldsConfig = require(game:GetService("ReplicatedStorage").Shared.Config.Worlds.WorldsConfig)
local LayoutLogic = require(script.Parent.Parent.Parent.Platform.LayoutLogic)
local PlatformConfig = require(game:GetService("ReplicatedStorage").Shared.Config.PlatformConfig)
local TouchLayout = require(game:GetService("ReplicatedStorage").Shared.Util.TouchLayout)
local TouchUIConfig = require(game:GetService("ReplicatedStorage").Shared.Config.TouchUIConfig)
local HudZonesConfig = require(game:GetService("ReplicatedStorage").Shared.Config.HudZonesConfig)
local UIStyleConfig = require(game:GetService("ReplicatedStorage").Shared.Config.UIStyleConfig)
local Create = require(script.Parent.Parent.Create)
local CurrencyFly = require(script.Parent.CurrencyFly)
local GuiFade = require(script.Parent.Parent.Widgets.GuiFade)
local HudFocusConfig = require(game:GetService("ReplicatedStorage").Shared.Config.HudFocusConfig)
local HudButtons = require(script.Parent.HudButtons)
local HudCurrency = require(script.Parent.HudCurrency)
local HudObjective = require(script.Parent.HudObjective)
local HudOffers = require(script.Parent.HudOffers)
local HudWhatsNew = require(script.Parent.HudWhatsNew)
local HudAdminChip = require(script.Parent.HudAdminChip)
-- Owner R122: the top-right INVITE button (co-play; Client/Social/InviteClient).
local HudInvite = require(script.Parent.HudInvite)
local HudPlacement = require(script.Parent.Parent.Widgets.HudPlacement)
local HudZones = require(script.Parent.Parent.Widgets.HudZones)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local Toasts = require(script.Parent.Toasts)

local Hud = {}

local currency: HudCurrency.HudCurrency? = nil
local buttons: HudButtons.HudButtons? = nil
local offers: HudOffers.HudOffers? = nil
local objective: HudObjective.HudObjective? = nil
local whatsNew: HudWhatsNew.HudWhatsNew? = nil
local adminChip: HudAdminChip.HudAdminChip? = nil
local inviteButton: HudInvite.HudInvite? = nil
local root: Frame? = nil
-- R79: the full-canvas layer holding the side columns + bottom chip (hidden while a menu is open).
local menuLayer: Frame? = nil
local menuHidden = false
-- Owner R127: true while a HudFocusConfig.CurrencyHiddenScreens screen hides the currency stack.
local currencyHidden = false
-- R79: the objective chip's last placement (bottom edge y, centre x, max width; design px) so its
-- zone can be re-published when the chip itself grows / shrinks between re-layouts.
local bottomPlacement: { y: number, centerX: number, width: number }? = nil
-- The objective chip's base height (one text line, no bar) — the least the Bottom zone reserves.
local OBJECTIVE_BASE_HEIGHT = UIStyleConfig.Hud.ObjectiveHeight
local incomeSource: (() -> number?)? = nil
local incomeThread: thread? = nil
-- Calls made before the HUD was built are replayed once it exists.
local pendingVisible: { [string]: boolean } = {}
local pendingBadges: { [string]: string | false } = {}
local pendingNew: { [string]: boolean } = {}
-- Objectives: the tutorial's (Nuke Town) and the current non-main world's (R57); the chip shows
-- the one of the world the player is in.
type Objective = { text: string?, target: HudObjective.ArrowTarget? }
local mainObjective: Objective = { text = nil, target = nil }
local worldObjective: Objective = { text = nil, target = nil }
-- R57: the world the player is in (WorldClient drives it) + Attack's automatic visibility.
local currentWorld = WorldsConfig.MAIN
local autoVisible: { [string]: boolean } = {}
local worldRateConnection: RBXScriptConnection? = nil
-- R59: the label floor last applied to the left buttons (phones: 14 pt; applied on change only).
local labelFloorApplied: number? = nil
-- R62: the keys of the left stack (setters ignore any other key, e.g. the folded "Daily"); R110:
-- every Left row (stack or MORE flyout) + the flyout-only rows (Settings) stay routable.
local ROW_KEYS: { [string]: boolean } = {}
for _, row in HudZonesConfig.Left do
	ROW_KEYS[row.key] = true
end
for _, row in HudZonesConfig.MoreExtra do
	ROW_KEYS[row.key] = true
end
local ADMIN_KEY = HudZonesConfig.AdminChip.key

-- Reads a finite number from an untyped profile field (NaN / inf / non-number -> nil).
local function finite(value: unknown): number?
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- The current $/s (installed source first, else the server-sent profile field).
local function currentRate(): number?
	local source = incomeSource
	if source ~= nil then
		local ok, value = pcall(source)
		if ok then
			return finite(value)
		end
		return nil
	end
	local profile = ClientState.profile
	return if profile ~= nil then finite(profile.incomePerSecond) else nil
end

-- R57: a world's income per second from the server's Player attribute IncomePerSecond_<world>.
local function worldRate(worldId: string): number?
	return finite(Players.LocalPlayer:GetAttribute(`IncomePerSecond_{worldId}`))
end

--[[
	Income per second of a money kind (CurrencyFly attribution): "cash" = the $/s, a world
	currency key = that world's IncomePerSecond_<world> attribute; anything else nil.
]]
local function rateOf(kind: string): number?
	if kind == "cash" then
		return currentRate()
	end
	local worldId = WorldsConfig.worldOfCurrency(kind)
	if worldId ~= nil and worldId ~= WorldsConfig.MAIN then
		return worldRate(worldId)
	end
	return nil
end

-- True when the current world hides a Nuke-Town-only left button (R57: Attack in Dino Valley).
local function worldHides(key: string): boolean
	if key ~= "Attack" or currentWorld == WorldsConfig.MAIN then
		return false
	end
	local def = WorldsConfig.get(currentWorld)
	return def ~= nil and def.features.attack == false
end

--[[
	Applies a left button's visibility: an explicit Hud.setButtonVisible wins over the automatic
	rule (Attack after the silo), and the current world may hide it on top (R57).
]]
local function applyVisible(key: string)
	local left = buttons
	if left == nil then
		return
	end
	local wanted = pendingVisible[key]
	if wanted == nil then
		wanted = autoVisible[key]
	end
	if wanted == nil then
		return
	end
	left.setVisible(key, wanted and not worldHides(key))
end

-- Shows the objective of the world the player is in (the tutorial's in Nuke Town).
local function applyObjective()
	local chip = objective
	if chip == nil then
		return
	end
	local shown = if currentWorld == WorldsConfig.MAIN then mainObjective else worldObjective
	chip.set(shown.text, shown.target)
end

--[[
	Publishes HudZones "Bottom" = the objective chip's REAL rect (owner R79: the chip grows upward
	for its progress bar / a second text line, and the gamepad hint bar, attack / knockdown chips and
	touch buttons stack above this zone — a fixed 64 px let the hint bar cover the chip). Reserves
	at least the one-line height even with no objective, as before. HudZones.set ignores equal
	rects, so calling this on every chip resize is cheap.
]]
local function publishBottom()
	local placement, chip = bottomPlacement, objective
	if placement == nil or chip == nil then
		return
	end
	local frame = chip.frame
	local height = math.max(OBJECTIVE_BASE_HEIGHT, if frame.Visible then frame.Size.Y.Offset else 0)
	HudZones.set("Bottom", {
		x = placement.centerX - placement.width / 2,
		y = placement.y - height,
		w = placement.width,
		h = height,
	})
end

--[[
	Owner R123: whether Roblox's player list (leaderboard) CoreGui is enabled for this client (the
	game never disables it; guarded because GetCoreGuiEnabled can error while the CoreGui boots).
]]
local function playerListShown(): boolean
	local ok, enabled = pcall(StarterGui.GetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.PlayerList)
	return ok and enabled == true
end

-- Re-computes and applies the whole HUD layout (event-driven).
local function relayout()
	local frame, left, right, top, bottom = root, buttons, offers, currency, objective
	if frame == nil or left == nil or right == nil or top == nil or bottom == nil then
		return
	end
	local gui = frame:FindFirstAncestorOfClass("ScreenGui")
	local canvas = ScreenManager.canvasSize(gui)
	if canvas.X <= 0 or canvas.Y <= 0 then
		return
	end
	local device = ScreenManager.device
	local touch = ScreenManager.isTouchDevice()
	local pointScale = ScreenManager.pointScale()
	-- Phones (owner R59): the compact layout (a 2 x 3 grid of 44 pt tiles top-left, smaller
	-- offers, icon-only WHAT'S NEW; labels >= 14 pt). Tablets / desktop / console: classic.
	local phone = touch and device.isPhone == true
	local labelFloor = if phone
		then math.ceil(TouchLayout.pointsToDesign(HudZonesConfig.Phone.LabelPoints, pointScale))
		else nil
	if labelFloor ~= labelFloorApplied then
		labelFloorApplied = labelFloor
		left.setLabelFloor(labelFloor)
	end
	local admin = adminChip
	local invite = inviteButton
	-- Roblox's jump button (and the thumbstick ring, which sits as high) on this screen size:
	-- its top edge in points above the bottom, + a 12 pt gap, in design px.
	local touchReserve: number? = nil
	if touch and device.viewportY > 0 then
		local jump = LayoutLogic.jumpRect(device.viewportX, device.viewportY, PlatformConfig.Touch.DefaultJump)
		touchReserve = (device.viewportY - jump.y + 12) / math.max(ScreenManager.pointScale(), 0.01)
	end
	-- Owner R123 ("leaderboard covers the invite ui"): Roblox's player list shows top-right by
	-- default on desktop; reserve its area (sized for the players in this server) so the admin chip /
	-- INVITE row and the offer column keep clear of it. Touch / console: nothing reserved.
	local playerList: Vector2? = nil
	if not touch and device.class == "Desktop" and playerListShown() then
		local spec = HudZonesConfig.PlayerList
		local rows = math.clamp(#Players:GetPlayers(), 1, spec.MaxRows)
		local heightPoints = spec.TopPoints + spec.HeaderPoints + rows * spec.RowPoints + spec.PadPoints
		playerList = Vector2.new(
			TouchLayout.pointsToDesign(spec.WidthPoints, pointScale),
			TouchLayout.pointsToDesign(heightPoints, pointScale)
		)
	end
	local layout = HudPlacement.compute({
		canvas = canvas,
		safeTop = ScreenManager.safeTop(0),
		playerList = playerList,
		wides = left.visibleWides(),
		offerCount = right.count(),
		touch = touch,
		touchReserve = touchReserve,
		phone = device.isPhone,
		-- Touch: a 44 pt tap in design px; small phones may shrink buttons down to it rather than
		-- push the grid under the cash counter or into the thumbstick ring (tests/hud-cluster).
		minTap = if touch then TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, pointScale) else nil,
		-- The bottom-right WHAT'S NEW chip (owner R58): its size is reserved under the offers
		-- (phones: the icon-only square, R59).
		corner = if whatsNew ~= nil then whatsNew.size(touch, pointScale, phone) else nil,
		-- The admin wrench chip (R62), only while it shows (admins).
		chip = if admin ~= nil and admin.visible() then admin.size(touch, pointScale) else nil,
		-- R122: the INVITE button left of it, only while invites are available.
		invite = if invite ~= nil and invite.visible() then invite.size(touch, pointScale, phone) else nil,
		-- R110: the MORE flyout's visible items (placed beside the stack, clear of the HUD).
		flyoutCount = left.moreCount(),
	})
	left.apply(layout.left, layout.flyout)
	if admin ~= nil then
		admin.place(layout.chip)
		local chipButton: any = admin.button()
		if chipButton ~= nil then
			chipButton.NextSelectionDown = right.first()
		end
	end
	-- R122: the INVITE button (Down → the first offer; Right ↔ the admin chip when both show).
	if invite ~= nil then
		invite.place(layout.invite)
		local inviteObject: any = invite.button()
		local chipObject: any = if admin ~= nil then admin.button() else nil
		if inviteObject ~= nil then
			inviteObject.NextSelectionDown = right.first()
			inviteObject.NextSelectionRight = chipObject
		end
		if chipObject ~= nil then
			chipObject.NextSelectionLeft = inviteObject
		end
	end
	right.apply(layout.right)
	-- The WHAT'S NEW chip under the offers (owner R58): placed before the D-pad links below.
	local chip, corner = whatsNew, layout.corner
	if chip ~= nil then
		chip.place(corner)
	end
	-- Predictable D-pad navigation: grid links + the column exits into each other (Down from the
	-- last offer reaches the WHAT'S NEW chip).
	left.linkNav(right.first())
	right.linkNav(left.topRight(), if chip ~= nil and corner ~= nil then chip.button() else nil)
	-- R82: the boost badge on the cash counter joins the D-pad graph (no-op while no boost shows).
	top.linkNav(left.topRight(), right.first())
	top.frame.Position = UDim2.new(0.5, 0, 0, layout.topY)
	bottom.place(layout.bottomY, layout.bottomMaxWidth, canvas.X / 2)
	-- Publish the zones (design px) for overlays that must avoid the HUD.
	HudZones.set("Left", { x = layout.left.x, y = layout.left.y, w = layout.left.width, h = layout.left.height })
	-- The admin chip (R62) + the INVITE button (R122): their union (nil clears it when neither shows).
	local topRight: HudPlacement.Rect? = layout.chip
	local inviteRect = layout.invite
	if inviteRect ~= nil then
		local chipRect = topRight
		if chipRect == nil then
			topRight = inviteRect
		else
			local x1 = math.min(chipRect.x, inviteRect.x)
			local y1 = math.min(chipRect.y, inviteRect.y)
			local x2 = math.max(chipRect.x + chipRect.w, inviteRect.x + inviteRect.w)
			local y2 = math.max(chipRect.y + chipRect.h, inviteRect.y + inviteRect.h)
			topRight = { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
		end
	end
	HudZones.set("TopRight", topRight)
	local stack = layout.right.slots * layout.right.slot + math.max(0, layout.right.slots - 1) * layout.right.gap
	local rightZone = {
		x = layout.right.x - layout.right.slot / 2,
		y = layout.right.y,
		w = layout.right.slot,
		h = stack,
	}
	-- The WHAT'S NEW chip under the offers is part of the Right zone (overlays avoid both).
	if corner ~= nil then
		local x1 = math.min(rightZone.x, corner.x)
		local x2 = math.max(rightZone.x + rightZone.w, corner.x + corner.w)
		rightZone = { x = x1, y = rightZone.y, w = x2 - x1, h = corner.y + corner.h - rightZone.y }
	end
	HudZones.set("Right", rightZone)
	-- The currency stack's content box (its frame is 600 wide, the numbers are narrower).
	HudZones.set("Top", {
		x = canvas.X / 2 - HudPlacement.TopZoneWidth / 2,
		y = layout.topY,
		w = HudPlacement.TopZoneWidth,
		h = HudPlacement.TopZoneHeight,
	})
	bottomPlacement = { y = layout.bottomY, centerX = canvas.X / 2, width = layout.bottomMaxWidth }
	publishBottom()
end

-- Applies a profile push to the HUD (cash / gems / offers / unlocks / rate).
local function onProfile(profile: ClientState.Profile, fields: { string }?, animate: boolean)
	local top, left, right = currency, buttons, offers
	if top == nil or left == nil or right == nil then
		return
	end
	local function touched(name: string): boolean
		return fields == nil or table.find(fields, name) ~= nil
	end
	if touched("cash") then
		top.setCash(finite(profile.cash) or 0, animate)
	end
	-- R57: the shown world's currency (Bones) moves in its own small delta field.
	if currentWorld ~= WorldsConfig.MAIN and touched("worldCash") then
		top.setWorldCash(ClientState.worldCash(currentWorld), animate)
	end
	if touched("gems") then
		top.setGems(finite(profile.gems) or 0, animate)
	end
	-- Offers hide when owned / bought, or (paid random products) when the region restricts them.
	-- R78: `pass` = the Nuke Pass offer (season running + premium not owned; PassService pushes
	-- `pass` on purchases, rollovers and at every season boundary).
	if
		touched("passes")
		or touched("starter")
		or touched("secretPack")
		or touched("policy")
		or touched("worlds")
		or touched("pass")
	then
		right.setProfile(profile)
	end
	if touched("attack") and pendingVisible.Attack == nil then
		local attack = profile.attack
		local launcher = if type(attack) == "table" then finite(attack.launcher) else nil
		autoVisible.Attack = launcher ~= nil and launcher > 0
		applyVisible("Attack")
	end
	top.setRate(currentRate())
end

-- Starts / stops the 1 Hz income poll (only while a source is installed).
local function refreshIncomePoll()
	if incomeSource ~= nil and incomeThread == nil then
		incomeThread = task.spawn(function()
			while incomeSource ~= nil do
				local top = currency
				if top ~= nil then
					top.setRate(currentRate())
				end
				task.wait(1)
			end
			incomeThread = nil
		end)
	end
	local top = currency
	if top ~= nil then
		top.setRate(currentRate())
	end
end

--[[
	Installs (or with nil removes) the function that returns the player's current $/s.
	@param source () -> number?, cheap (called once per second and on profile changes; nil hides the row)
	Example: Hud.setIncomeSource(function() return TycoonLogic.incomePerSecond(...) end)
]]
function Hud.setIncomeSource(source: (() -> number?)?)
	incomeSource = source
	refreshIncomePoll()
end

--[[
	Shows the objective chip (nil / "" hides it) and, with `target`, the world arrow.
	@param text   short objective text
	@param target BasePart | Attachment | Model | Vector3 (optional)
	Example: Hud.setObjective("Click the reactor to build nukes!", reactorPart)
]]
function Hud.setObjective(text: string?, target: HudObjective.ArrowTarget?)
	mainObjective = { text = text, target = target }
	applyObjective()
end

--[[
	R57: the objective of the non-main world the player is in (Worlds/WorldObjectives via
	WorldClient); shown instead of the tutorial's while in that world. nil text hides it.
	Example: Hud.setWorldObjective("Hire Rocky Raptor!", padPart)
]]
function Hud.setWorldObjective(text: string?, target: HudObjective.ArrowTarget?)
	worldObjective = { text = text, target = target }
	applyObjective()
end

--[[
	R57: the world the player is in (WorldClient calls it on every change). Swaps the currency
	stack, the world rate source, Nuke-Town-only buttons, the offers rotation and the objective.
	Example: Hud.setWorld("dino")
]]
function Hud.setWorld(worldId: string)
	local def = WorldsConfig.get(worldId)
	if def == nil then
		return
	end
	currentWorld = worldId
	local top, right = currency, offers
	if top ~= nil then
		top.setWorld(if worldId == WorldsConfig.MAIN then nil else def)
		if worldId ~= WorldsConfig.MAIN then
			top.setWorldCash(ClientState.worldCash(worldId), false)
			top.setWorldRate(worldRate(worldId))
		end
	end
	-- One attribute listener for the shown world's rate (event-driven, replaced on a switch).
	if worldRateConnection ~= nil then
		worldRateConnection:Disconnect()
		worldRateConnection = nil
	end
	if worldId ~= WorldsConfig.MAIN then
		worldRateConnection = Players.LocalPlayer
			:GetAttributeChangedSignal(`IncomePerSecond_{worldId}`)
			:Connect(function()
				local stack = currency
				if stack ~= nil and currentWorld == worldId then
					stack.setWorldRate(worldRate(worldId))
				end
			end)
	end
	applyVisible("Attack")
	if right ~= nil then
		right.setWorld(worldId)
	end
	applyObjective()
	task.defer(relayout)
end

--[[
	R57: shows / hides a yellow NEW tag on a left-column button (Teleport until the first visit
	of an unlocked world).
	Example: Hud.setButtonNew("Teleport", true)
]]
function Hud.setButtonNew(key: string, on: boolean)
	if not ROW_KEYS[key] then
		return -- not a stack button (R62 folded it into the Rewards hub): harmless no-op
	end
	pendingNew[key] = on
	local left = buttons
	if left ~= nil then
		left.setNew(key, on)
	end
end

--[[
	Shows / hides a left-column button by its HudZonesConfig key (re-lays the grid out).
	Example: Hud.setButtonVisible("Event", true)
]]
function Hud.setButtonVisible(key: string, visible: boolean)
	if key == ADMIN_KEY then
		-- R62: Admin is the top-right chip (AdminOverlay calls this with IsAdmin).
		pendingVisible[key] = visible
		local chip = adminChip
		if chip ~= nil then
			chip.setVisible(visible)
			task.defer(relayout)
		end
		return
	end
	if not ROW_KEYS[key] then
		return -- not a stack button (R62 folded it into the Rewards hub): harmless no-op
	end
	pendingVisible[key] = visible
	applyVisible(key)
end

--[[
	Sets / clears the red badge on a left-column button.
	Example: Hud.setButtonBadge("Pets", "3") ; Hud.setButtonBadge("Pets", nil)
]]
function Hud.setButtonBadge(key: string, text: string?)
	if not ROW_KEYS[key] then
		-- R62: Daily / Time / LuckyWheel / Codes badges now roll up into the Rewards button
		-- (UI/RewardsBadges); their screens' calls are harmless no-ops (never replayed).
		return
	end
	pendingBadges[key] = if text ~= nil then text else false
	local left = buttons
	if left ~= nil then
		left.setBadge(key, text)
	end
end

--[[ Shows a local toast (same look as server Notify toasts). ]]
function Hud.notify(kind: string, text: string, icon: string?)
	Toasts.push(kind, text, icon)
end
--[[
	Owner R79: shows the menu layer (left buttons, offers, WHAT'S NEW, objective chip) only while no
	menu (modal) is open. Fades with the HUD focus timings; snaps instead while the HUD itself is
	hidden / fading (focus mode, loading gate) — GuiFade settles nested fades either way.
	@param animate boolean — false on build (the first state applies instantly)
]]
local function applyMenuLayer(animate: boolean)
	local layer = menuLayer
	if layer == nil then
		return
	end
	local hide = ScreenManager.anyModalOpen()
	if hide == menuHidden and layer.Visible == not hide and not GuiFade.isFading(layer) then
		return
	end
	menuHidden = hide
	local gui = layer:FindFirstAncestorOfClass("ScreenGui")
	local steady = gui ~= nil and gui.Enabled and not GuiFade.isFading(gui) and not ScreenManager.isFocusMode()
	if animate and steady then
		GuiFade.setShown(layer, not hide, if hide then HudFocusConfig.FadeOutSeconds else HudFocusConfig.FadeInSeconds)
	else
		GuiFade.cancel(layer)
		layer.Visible = not hide
	end
end

--[[ R79: true while the HUD side columns are hidden because a menu is open (QA / tests). ]]
function Hud.menuHidden(): boolean
	return menuHidden
end

--[[
	Owner R127 ("in the spin UI hide the money counter UI on the top since it clips"): fades the
	currency stack (gems / cash / rate / boost badge) out while any HudFocusConfig.CurrencyHiddenScreens
	screen is open (the Lucky Wheel's title sits where the stack is) and back in when the last one
	closes. Same fade rules as applyMenuLayer (snaps while the HUD itself is hidden / fading).
	@param animate boolean — false on build (the first state applies instantly)
]]
local function applyCurrencyLayer(animate: boolean)
	local top = currency
	if top == nil then
		return
	end
	local hide = false
	for _, name in HudFocusConfig.CurrencyHiddenScreens do
		if ScreenManager.isOpen(name) then
			hide = true
			break
		end
	end
	local frame = top.frame
	if hide == currencyHidden and frame.Visible == not hide and not GuiFade.isFading(frame) then
		return
	end
	currencyHidden = hide
	local gui = frame:FindFirstAncestorOfClass("ScreenGui")
	local steady = gui ~= nil and gui.Enabled and not GuiFade.isFading(gui) and not ScreenManager.isFocusMode()
	if animate and steady then
		GuiFade.setShown(frame, not hide, if hide then HudFocusConfig.FadeOutSeconds else HudFocusConfig.FadeInSeconds)
	else
		GuiFade.cancel(frame)
		frame.Visible = not hide
	end
end

--[[ R127: true while the currency stack is hidden by an open CurrencyHiddenScreens screen (QA). ]]
function Hud.currencyHidden(): boolean
	return currencyHidden
end

--[[
	Gamepad: puts the selection on the first left-column button (no modal open); R110: on the
	MORE flyout's first item while that flyout is open (the cursor is meant to be in it).
]]
function Hud.focusButtons()
	local left = buttons
	if left == nil or ScreenManager.anyModalOpen() then
		return
	end
	local more = left.more()
	if more.isOpen() then
		-- The first VISIBLE flyout item (HudZonesConfig.MoreRows order = the flyout's order).
		for _, row in HudZonesConfig.MoreRows do
			local item = left.button(row.key)
			if item ~= nil and item.Visible then
				GuiService.SelectedObject = item
				return
			end
		end
	end
	GuiService.SelectedObject = left.first()
end

--[[
	R110: opens / closes the MORE flyout (QA runners, tutorials). Opening needs a placed HUD and no
	open menu. `focus` = with a gamepad, the cursor goes onto the first item (open) / back onto
	MORE (close).
	Example: Hud.setMoreOpen(true, true)
]]
function Hud.setMoreOpen(on: boolean, focus: boolean?)
	local left = buttons
	if left == nil then
		return
	end
	local more = left.more()
	if on then
		more.open(focus == true)
	else
		more.close(focus == true)
	end
end

--[[ R110: true while the MORE flyout is open (QA / tests). ]]
function Hud.moreOpen(): boolean
	local left = buttons
	return left ~= nil and left.more().isOpen()
end

--[[ Gamepad: puts the selection on the first visible offer (no modal open). ]]
function Hud.focusOffers()
	local right = offers
	if right ~= nil and not ScreenManager.anyModalOpen() then
		GuiService.SelectedObject = right.first()
	end
end

-- The HUD screen module (non-modal, auto-open, below every window).
local hudScreen: ScreenManager.ScreenModule = {
	name = "Hud",
	modal = false,
	autoOpen = true,
	displayOrder = 5,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		local frame = Create.new("Frame", {
			Name = "HudRoot",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Active = false,
			Parent = gui,
		}) :: Frame
		root = frame
		local top = HudCurrency.new(frame)
		currency = top
		-- Money flies into the counters (owner R46): CurrencyFly's sprites land on the icons and
		-- pop / glint them; it starts / skips by the HUD's own visibility and safe area.
		CurrencyFly.attach({
			target = top.target,
			land = top.land,
			gui = gui,
			area = frame,
			rate = rateOf,
		})
		CurrencyFly.start()
		-- R79: the side columns + bottom chip share one full-canvas layer (same coordinates as
		-- HudRoot) that hides while a menu is open; the currency stack + admin chip stay in HudRoot.
		local layer = Create.new("Frame", {
			Name = "MenuLayer",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Active = false,
			Parent = frame,
		}) :: Frame
		menuLayer = layer
		local left = HudButtons.new(layer)
		buttons = left
		local right = HudOffers.new(layer)
		offers = right
		local chipObjective = HudObjective.new(layer)
		objective = chipObjective
		-- R79: the chip resizes itself (bar / second line) and hides with no objective; keep the
		-- Bottom zone on what is drawn.
		chipObjective.frame:GetPropertyChangedSignal("Size"):Connect(publishBottom)
		chipObjective.frame:GetPropertyChangedSignal("Visible"):Connect(publishBottom)
		whatsNew = HudWhatsNew.new(layer) -- bottom-right WHAT'S NEW chip (owner R58)
		local chip = HudAdminChip.new(frame) -- top-right admin wrench chip (owner R62)
		adminChip = chip
		-- R122: the INVITE button (in the MenuLayer: it fades out with the columns behind a menu);
		-- its visibility follows invite availability, so a change re-lays out the HUD.
		local invite = HudInvite.new(layer)
		inviteButton = invite
		invite.onChanged(function()
			task.defer(relayout)
		end)
		left.onChanged(relayout)
		right.onChanged(relayout)
		-- Replay API calls made before the build.
		for key in pendingVisible do
			if key ~= ADMIN_KEY then
				applyVisible(key)
			end
		end
		for key, text in pendingBadges do
			left.setBadge(key, if text == false then nil else text)
		end
		for key, on in pendingNew do
			left.setNew(key, on)
		end
		-- Admin chip (R62): visible only while the server-set IsAdmin attribute is true (display
		-- only; every admin action is re-authorised on the server by B14's AdminService). An
		-- explicit Hud.setButtonVisible("Admin", ...) (AdminOverlay) wins.
		local localPlayer = Players.LocalPlayer
		local function applyAdmin()
			local wanted = pendingVisible[ADMIN_KEY]
			if wanted == nil then
				wanted = localPlayer:GetAttribute("IsAdmin") == true
			end
			chip.setVisible(wanted == true)
			task.defer(relayout)
		end
		localPlayer:GetAttributeChangedSignal("IsAdmin"):Connect(applyAdmin)
		applyAdmin()
		-- Rewards hub badge (R62, H3-hub's UI/RewardsBadges): the claimable total on the Rewards
		-- button. Optional module: a missing hub never breaks the HUD.
		local badgesOk, RewardsBadges = pcall(require, script.Parent.Parent.RewardsBadges)
		if badgesOk and type(RewardsBadges) == "table" then
			local badges: any = RewardsBadges
			local function applyRewardsBadge()
				local okText, text = pcall(badges.badgeText)
				left.setBadge("Rewards", if okText and type(text) == "string" then text else nil)
			end
			pcall(badges.start)
			if type(badges.Changed) == "table" then
				badges.Changed:Connect(applyRewardsBadge)
			end
			applyRewardsBadge()
		end
		applyObjective()
		-- A world set before the build (WorldClient starts after UIController, so normally none).
		if currentWorld ~= WorldsConfig.MAIN then
			Hud.setWorld(currentWorld)
		end
		ScreenManager.LayoutChanged:Connect(relayout)
		ScreenManager.SafeAreaChanged:Connect(relayout)
		-- R79: menus open / close -> the side columns fade out / in.
		ScreenManager.Opened:Connect(function()
			applyMenuLayer(true)
			applyCurrencyLayer(true)
		end)
		ScreenManager.Closed:Connect(function()
			applyMenuLayer(true)
			applyCurrencyLayer(true)
		end)
		applyMenuLayer(false)
		applyCurrencyLayer(false)
		-- R123: the player list grows / shrinks with the server's players; re-place the top-right
		-- row and the offer column when it changes (its CoreGui state is read on every relayout).
		Players.PlayerAdded:Connect(relayout)
		Players.PlayerRemoving:Connect(function()
			task.defer(relayout) -- the leaving player is still listed during PlayerRemoving
		end)
		-- The canvas size is known once the gui is parented / sized.
		gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
		ClientState.ProfileChanged:Connect(function(profile, fields)
			onProfile(profile, fields, true)
		end)
		local profile = ClientState.profile
		if profile ~= nil then
			onProfile(profile, nil, false)
		end
		task.defer(relayout)
		return {
			onOpen = function()
				task.defer(relayout)
			end,
		}
	end,
}

--[[ The ScreenModules UIController registers for the HUD ("Hud", "Toasts"). ]]
function Hud.screens(): { ScreenManager.ScreenModule }
	return { hudScreen, Toasts.screen }
end

return Hud
