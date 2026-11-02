--!strict
--[[
	Settings — the "Settings" window (design spec §6): ON / OFF toggles, shortcuts to WHAT'S NEW
	and GET NOTIFIED, and the quiet version label.

	Layout (each toggle row a sky stud card):
		Music                 Background songs              [  ON ]
		Sound Effects         Clicks, cash and blasts       [  ON ]
		Reduced Motion        Calmer menus, less spinning   [ OFF ]
		Hide Others' Pets     Only show your own pets       [ OFF ]
		Fast Hatch            Shorter egg opening           [ OFF ]   (owner R49)
		Auto Clicker          Your pass clicks for you      [  ON ]   ← only with the pass (R64)
		Vibration             Controller rumble             [  ON ]   ← only with a gamepad
		[ WHAT'S NEW ]  [ GET NOTIFIED ]
		v0.1.0 · build 431
	Console + mobile (owner R11): a ResponsiveModal — one column ("tall") on desktop / console /
	tablet; two columns in a wide, short window ("wide") on a landscape phone, where it renders
	unshrunk. Toggles and buttons are at least 44 pt tall and text at least 14 pt on touch
	(the layout's `tap` / `minText`). Gamepad: every visible toggle and both shortcut buttons form
	one linked list (GamepadNav.linkList, re-linked when a row shows / hides); the cursor starts
	on the first toggle (never the close X); B closes.

	Toggles: pressing one flips it at once (optimistic) and sends the intent
	Remotes.event("SetSetting"):FireServer(key, newValue); the server (SettingsService →
	ProfileLogic.applySetting, allowlisted keys, rate-limited) stores it and pushes `settings`,
	and every push snaps the rows back to the server's truth. A press the server dropped (rate
	limit / a key it does not accept yet) gets no change, so one reconcile timer snaps the rows to
	the profile shortly after the last press. Other systems read the stored settings themselves
	(UIController → Reduce Motion, FxSound → SFX, Platform/Haptics → vibration, music / pets).

	Vibration (key `haptics`, value `profile.settings.haptics ~= false`) is shown only while a
	gamepad is connected (UserInputService.GamepadEnabled, updated on GamepadConnected /
	GamepadDisconnected).

	Auto Clicker (key `autoClicker`, owner R64) is the AutoClicker game pass's advertised "Toggle it
	any time": shown only while profile.passes.AutoClicker is true (re-placed on a `passes` push,
	e.g. right after buying it; hidden in New Player Mode, whose sandbox owns no passes). OFF makes
	every un-managed producer manual again (the server reads it: TycoonService via
	SettingsService.Changed → TycoonRules.autoClickerOn); it never grants anything.

	GET NOTIFIED opens the NotifyPrompt screen and is hidden once profile.notify.claimed (the
	opt-in reward was paid). WHAT'S NEW opens the WhatsNew screen (stacked over this one; Back
	returns here).

	Performance: built once on first open (lazy); event-driven (profile pushes, gamepad
	connect / disconnect, layout changes, one reconcile timer). Security: intents only; the
	server validates key + boolean.

	Connects to: Kit/StudUI, Screens/DailyRewards/ResponsiveModal, Platform/GamepadNav,
	Client/ClientState (profile.settings / notify), Analytics/ClientAnalytics (screenOpened
	"Settings"), Shared/Config/{ChangeNotesConfig (version label), UIStyleConfig},
	Shared/Net/Remotes (SetSetting), ChangeNotes/ChangeNotesClient (WHAT'S NEW opener + clock),
	UI/ScreenManager (NotifyPrompt).

	Example:
		ScreenManager.open("Settings")
		ScreenManager.open("Settings", { source = "menu" })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ResponsiveModal = require(script.Parent.DailyRewards.ResponsiveModal)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
-- WHAT'S NEW (owner R58): the panel's "menu" opener + the version label (ChangeNotesConfig keeps
-- the last visible version while an early-published note is still hidden by ShowFrom).
local ChangeNotesClient = require(script.Parent.Parent.Parent.ChangeNotes.ChangeNotesClient)
local ChangeNotesConfig = require(ReplicatedStorage.Shared.Config.ChangeNotesConfig)

local NAME = "Settings"
local ANALYTICS_ID = "Settings"
-- Window modes (ResponsiveModal): one column first (the reference), two columns for phones.
local MODES: { ResponsiveModal.Mode } = {
	-- Heights grew by one toggle row for Fast Hatch (owner R49) and one for Auto Clicker (R64):
	-- room for all seven rows (pass owner on a console); ModalShell shrinks it to fit any screen.
	{ name = "tall", size = Vector2.new(820, 980) },
	{ name = "wide", size = Vector2.new(1320, 560) },
}
-- Seconds after the LAST toggle press before the rows re-sync with the stored profile (covers
-- a press the server dropped; a normal push snaps the rows much sooner).
local RECONCILE_SECONDS = 2.5

-- Authored geometry (design px; lifted to the layout's tap / minText on touch).
local ROW_HEIGHT = 92
local ROW_GAP = 10
local COLUMN_GAP = 24
local LABEL_SIZE = 38
local HINT_SIZE = 22
local TOGGLE_SIZE = Vector2.new(150, 62)
local ACTION_SIZE = Vector2.new(320, 72)
local ACTION_GAP = 20
-- Action button text cap (both labels must fit next to their icon in the narrow phone column).
local ACTION_TEXT_MAX = 30
local VERSION_SIZE = 22
local SECTION_GAP = 14
-- Card padding (StudUI) + the space a button's 3D lip needs below its face.
local CARD_PADDING = UIStyleConfig.Card.Padding
local BUTTON_LIP = UIStyleConfig.Button.Lip

-- One toggle row: the settings key (ProfileLogic.SettingKeys), its label, a short hint, the value
-- shown before any profile arrives (ProfileLogic's defaults), whether it needs a gamepad and the
-- game pass it belongs to (nil = everyone; MonetizationConfig pass key = only its owners).
type RowSpec = {
	key: string,
	label: string,
	hint: string,
	default: boolean,
	gamepadOnly: boolean,
	pass: string?,
}

local ROWS: { RowSpec } = {
	{ key = "music", label = "Music", hint = "Background songs", default = true, gamepadOnly = false },
	{ key = "sfx", label = "Sound Effects", hint = "Clicks, cash and blasts", default = true, gamepadOnly = false },
	{
		key = "reducedMotion",
		label = "Reduced Motion",
		hint = "Calmer menus, less spinning",
		default = false,
		gamepadOnly = false,
	},
	{
		key = "hideOtherPets",
		label = "Hide Others' Pets",
		hint = "Only show your own pets",
		default = false,
		gamepadOnly = false,
	},
	-- Owner R49: the short egg hatch cinematic (auto-hatch always uses it).
	{
		key = "fastHatch",
		label = "Fast Hatch",
		hint = "Shorter egg opening",
		default = false,
		gamepadOnly = false,
	},
	-- Owner R64: the AutoClicker pass's "Toggle it any time" (pass owners only). OFF = click by hand.
	{
		key = "autoClicker",
		label = "Auto Clicker",
		hint = "Your pass clicks for you",
		default = true,
		gamepadOnly = false,
		pass = "AutoClicker",
	},
	-- Stored as `haptics`; anything but an explicit false counts as ON.
	{ key = "haptics", label = "Vibration", hint = "Controller rumble", default = true, gamepadOnly = true },
}

-- A built toggle row.
type Row = {
	spec: RowSpec,
	card: StudUI.Card,
	label: TextLabel,
	hint: TextLabel,
	button: StudUI.Button,
}

--[[
	The stored value of a setting from the profile snapshot (the row default when missing).
	@param profile the ClientState snapshot (may be nil early)
	@param spec    the row
	@return boolean
]]
local function storedValue(profile: ClientState.Profile?, spec: RowSpec): boolean
	-- Read through an `any` local: a `type(...) == "table"` refinement on the profile path would
	-- narrow it to a key-less `table`.
	local settings: any = if profile ~= nil then profile.settings else nil
	if type(settings) == "table" then
		local value = settings[spec.key]
		if type(value) == "boolean" then
			return value
		end
	end
	return spec.default
end

--[[
	True when the profile snapshot owns a game pass (server-synced profile.passes cache; the
	sandbox profile of New Player Mode owns none). Only decides whether a pass row is SHOWN.
	@param profile the ClientState snapshot (may be nil early)
	@param passKey MonetizationConfig pass key, e.g. "AutoClicker"
]]
local function ownsPass(profile: ClientState.Profile?, passKey: string): boolean
	local passes: any = if profile ~= nil then profile.passes else nil
	return type(passes) == "table" and passes[passKey] == true
end

--[[ True once the notification opt-in reward was paid (GET NOTIFIED hides then). ]]
local function notifyClaimed(profile: ClientState.Profile?): boolean
	local notify: any = if profile ~= nil then profile.notify else nil
	return type(notify) == "table" and notify.claimed == true
end

--[[ The analytics source from ScreenManager.open's args ({ source = "..." }), default "hud". ]]
local function sourceOf(args: any?): string
	if type(args) == "table" and type(args.source) == "string" then
		return args.source
	end
	return "hud"
end

-- Sets a label's text size and the kit's matching outline thickness (StudUI's rule).
local function restyle(label: TextLabel, size: number)
	label.TextSize = size
	StudWindow.outline(label, math.max(2, math.floor(size * UIStyleConfig.Button.TextStrokeRatio + 0.5)))
end

return ResponsiveModal.screen({
	name = NAME,
	title = "Settings",
	color = "blue",
	-- The gear when the kit can draw it (uploaded icon or fallback glyph), else the check.
	icon = if StudUI.hasIcon("Settings") then "Settings" else "Check",
	modes = MODES,
	build = function(
		window: StudUI.Window,
		_gui: ScreenGui,
		layout: ResponsiveModal.Controller
	): ScreenManager.ScreenHandle?
		local body = window.body
		local rows: { Row } = {}
		-- The value each row shows right now (optimistic until the server's push arrives).
		local shown: { [string]: boolean } = {}
		local reconcileThread: thread? = nil

		-- Paints one toggle: green ON / grey OFF (state stays "normal" so it stays pressable).
		local function paint(row: Row)
			local on = shown[row.spec.key] == true
			row.button.setText(if on then "ON" else "OFF")
			row.button.setColor(if on then "green" else "grey")
		end

		-- Snaps every row to the stored profile values (server truth).
		local function snapToProfile()
			local profile = ClientState.profile
			for _, row in rows do
				shown[row.spec.key] = storedValue(profile, row.spec)
				paint(row)
			end
		end

		-- Flips one toggle optimistically and sends the intent; re-syncs after the last press.
		local function toggle(row: Row)
			local key = row.spec.key
			local newValue = not shown[key]
			shown[key] = newValue
			paint(row)
			Remotes.event("SetSetting"):FireServer(key, newValue)
			local pending = reconcileThread
			if pending ~= nil then
				task.cancel(pending)
			end
			reconcileThread = task.delay(RECONCILE_SECONDS, function()
				reconcileThread = nil
				snapToProfile()
			end)
		end

		for order, spec in ROWS do
			local card = StudUI.card({
				name = `Row_{spec.key}`,
				color = "sky",
				layoutOrder = order,
				parent = body,
			})
			local label = StudUI.text({
				name = "Label",
				text = spec.label,
				textSize = LABEL_SIZE,
				align = Enum.TextXAlignment.Left,
				zIndex = 4,
				parent = card.content,
			})
			local hint = StudUI.text({
				name = "Hint",
				text = spec.hint,
				textSize = HINT_SIZE,
				align = Enum.TextXAlignment.Left,
				zIndex = 4,
				parent = card.content,
			})
			local row: Row
			local button = StudUI.button({
				name = `Toggle_{spec.key}`,
				text = if spec.default then "ON" else "OFF",
				color = if spec.default then "green" else "grey",
				anchor = Vector2.new(1, 0.5),
				parent = card.content,
				onActivated = function()
					toggle(row)
				end,
			})
			button.instance.ZIndex = 5
			row = { spec = spec, card = card, label = label, hint = hint, button = button }
			table.insert(rows, row)
		end

		-- Shortcut buttons.
		local whatsNew = StudUI.button({
			name = "WhatsNew",
			text = "WHAT'S NEW",
			icon = "Star",
			color = "purple",
			parent = body,
			onActivated = function()
				ChangeNotesClient.openMenu() -- the WHAT'S NEW panel, source "menu"
			end,
		})
		local notify = StudUI.button({
			name = "GetNotified",
			text = "GET NOTIFIED",
			icon = "Gift",
			color = "yellow",
			parent = body,
			onActivated = function()
				ScreenManager.open("NotifyPrompt", { source = "settings" })
			end,
		})

		-- The quiet version label ("v0.1.0 · build 431"; just "v0.1.0" in unpublished Studio).
		local version = StudUI.text({
			name = "Version",
			text = ChangeNotesConfig.menuText(game.PlaceVersion, ChangeNotesClient.now()),
			textSize = VERSION_SIZE,
			color = UIStyleConfig.Neutral.TextDim,
			parent = body,
		})

		--[[
			Places every visible row, the shortcuts and the version label for the active layout
			(design px; see the module header), then re-links the gamepad list. Runs on open, on
			layout changes and when a row / GET NOTIFIED shows or hides.
		]]
		local function place()
			local current = layout.current()
			local area = current.area
			local minText = current.minText
			local wide = current.mode == "wide"
			local gamepad = UserInputService.GamepadEnabled
			notify.instance.Visible = not notifyClaimed(ClientState.profile)

			-- Shared sizes (authored, lifted to the touch minimums).
			local toggleHeight = math.max(TOGGLE_SIZE.Y, current.tap)
			local labelSize = math.max(LABEL_SIZE, minText)
			local hintSize = math.max(HINT_SIZE, minText)
			-- A row fits the label + hint stack and the toggle (+ its lip) inside the card padding.
			local rowHeight = math.max(
				ROW_HEIGHT,
				toggleHeight + BUTTON_LIP + 2 * CARD_PADDING + 4,
				labelSize + hintSize + 14 + 2 * CARD_PADDING
			)
			local actionHeight = math.max(ACTION_SIZE.Y, current.tap)
			local versionSize = math.max(VERSION_SIZE, minText)

			local visible: { Row } = {}
			local profile = ClientState.profile
			for _, row in rows do
				local pass = row.spec.pass
				row.card.frame.Visible = (not row.spec.gamepadOnly or gamepad)
					and (pass == nil or ownsPass(profile, pass))
				if row.card.frame.Visible then
					table.insert(visible, row)
				end
			end

			-- Columns: one ("tall") or two ("wide": the first half of the rows on the left, the
			-- rest + the shortcuts on the right).
			local columnWidth = if wide then (area.X - COLUMN_GAP) // 2 else area.X
			local leftCount = if wide then math.ceil(#visible / 2) else #visible
			local rowsHeightLeft = leftCount * rowHeight + math.max(0, leftCount - 1) * ROW_GAP
			local rightCount = #visible - leftCount
			local actionsBlock = actionHeight + BUTTON_LIP
			local versionHeight = versionSize + 8
			-- Total content height, used to centre the stack vertically in the body.
			local total = if wide
				then math.max(
					rowsHeightLeft + SECTION_GAP + versionHeight,
					rightCount * (rowHeight + ROW_GAP) + SECTION_GAP + actionsBlock
				)
				else rowsHeightLeft + SECTION_GAP + actionsBlock + SECTION_GAP + versionHeight
			local top = math.max(0, (area.Y - total) // 2)

			for index, row in visible do
				local inLeft = index <= leftCount
				local slot = if inLeft then index - 1 else index - leftCount - 1
				local x = if inLeft then 0 else columnWidth + COLUMN_GAP
				row.card.frame.Position = UDim2.fromOffset(x, top + slot * (rowHeight + ROW_GAP))
				row.card.frame.Size = UDim2.fromOffset(columnWidth, rowHeight)
				-- Text column: left of the toggle, label over hint, centred in the row.
				local inner = rowHeight - 2 * CARD_PADDING
				local textWidth = -(TOGGLE_SIZE.X + 28)
				local stack = labelSize + 6 + hintSize + 6
				local textTop = math.max(0, (inner - stack) // 2)
				row.label.Position = UDim2.fromOffset(12, textTop)
				row.label.Size = UDim2.new(1, textWidth, 0, labelSize + 6)
				restyle(row.label, labelSize)
				row.hint.Position = UDim2.fromOffset(12, textTop + labelSize + 6)
				row.hint.Size = UDim2.new(1, textWidth, 0, hintSize + 6)
				restyle(row.hint, hintSize)
				-- Toggle: right edge, centred (nudged up by half the lip so face + lip look centred).
				row.button.instance.Size = UDim2.fromOffset(TOGGLE_SIZE.X, toggleHeight)
				row.button.instance.Position = UDim2.new(1, -8, 0.5, -math.floor(BUTTON_LIP / 2))
				restyle(row.button.label, math.floor(toggleHeight * 0.58))
			end

			-- Shortcuts: centred under the rows ("tall") or under the right column ("wide").
			local actionsX = if wide then columnWidth + COLUMN_GAP else 0
			local actionsTop = if wide
				then top + rightCount * (rowHeight + ROW_GAP) + SECTION_GAP - ROW_GAP
				else top + rowsHeightLeft + SECTION_GAP
			local shortcuts: { StudUI.Button } = { whatsNew }
			if notify.instance.Visible then
				table.insert(shortcuts, notify)
			end
			local actionWidth = math.min(ACTION_SIZE.X, (columnWidth - ACTION_GAP) // 2)
			local rowWidth = #shortcuts * actionWidth + (#shortcuts - 1) * ACTION_GAP
			local startX = actionsX + (columnWidth - rowWidth) // 2
			for index, button in shortcuts do
				button.instance.AnchorPoint = Vector2.zero
				button.instance.Position =
					UDim2.fromOffset(startX + (index - 1) * (actionWidth + ACTION_GAP), actionsTop)
				button.instance.Size = UDim2.fromOffset(actionWidth, actionHeight)
				restyle(button.label, math.min(ACTION_TEXT_MAX, math.floor(actionHeight * 0.58)))
			end

			-- Version label: under the left column ("wide") or at the bottom ("tall").
			local versionTop = if wide
				then top + rowsHeightLeft + SECTION_GAP
				else actionsTop + actionsBlock + SECTION_GAP
			version.Position = UDim2.fromOffset(0, versionTop)
			version.Size = UDim2.fromOffset(columnWidth, versionHeight)
			restyle(version, versionSize)

			-- Gamepad: every visible toggle, then the shortcuts, as one linked list.
			local items: { GuiObject } = {}
			for _, row in visible do
				table.insert(items, row.button.instance)
			end
			for _, button in shortcuts do
				table.insert(items, button.instance)
			end
			GamepadNav.linkList(items, true)
		end

		layout.onChanged(function()
			place()
		end)
		-- A gamepad (dis)connecting shows / hides the Vibration row.
		UserInputService.GamepadConnected:Connect(place)
		UserInputService.GamepadDisconnected:Connect(place)
		ClientState.ProfileChanged:Connect(function(_profile: ClientState.Profile, fields: { string }?)
			if fields == nil or table.find(fields, "settings") ~= nil then
				snapToProfile()
			end
			-- `passes`: buying (or the server confirming) the AutoClicker pass shows its row.
			if fields == nil or table.find(fields, "notify") ~= nil or table.find(fields, "passes") ~= nil then
				place()
			end
		end)
		snapToProfile()
		place()

		return {
			onOpen = function(args: any?)
				snapToProfile()
				place()
				ClientAnalytics.screenOpened(ANALYTICS_ID, sourceOf(args))
			end,
			-- Gamepad starts on the first visible toggle (never the close X).
			defaultSelection = function(): GuiObject?
				local first: GuiObject? = nil
				for _, row in rows do
					if row.card.frame.Visible then
						first = row.button.instance
						break
					end
				end
				return GamepadNav.defaultSelection(body, first)()
			end,
		}
	end,
})
