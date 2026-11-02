--!strict
--[[
	ActionMap — the runtime of SellNukes' ONE action map (PlatformConfig.Actions): binds every
	action through ContextActionService with its priority, enables / disables actions by
	context, and keeps the hint texts the hint bar and touch buttons show.

	How an action flows:
		key / button ─► ContextActionService (BindActionAtPriority, only while the action is
		ACTIVE) ─► ActionMap.onCas ─► InputController.pressAction(action) ─► ActionPressed
		─► listeners (Tycoon/Interaction, UIController, ActionMap's own screen toggles).
		touch button ─► ActionMap.tap(action) ─► the same InputController.pressAction path.
		A press that fired is Sunk, so a lower-priority binding of the same key (Roblox's jump on
		ButtonA while you stand on a pad) never sees it.

	Active = ActionLogic.isActive(binding, env) where env is:
		- menu:      ScreenManager.anyModalOpen() (gameplay actions unbound behind menus),
		- selecting: GuiService.SelectedObject ~= nil (freeNav D-pad actions unbound so the
		             D-pad walks the selection),
		- contexts:  setContext (systems), context providers (polled at PlatformConfig.ContextHz
		             in ONE loop), AttackUnlocked (profile.attack.launcher > 0 AND the world the
		             player is in allows attacks: WorldsConfig features.attack ~= false, so the
		             G / D-pad-down Attack action, its hint chip and the menu-wheel row hide in
		             Dino Valley like the HUD's Attack button, owner R57), Selecting.
	Re-evaluation is event-driven and coalesced (task.defer): many changes in one frame cost
	one recompute and one Changed.

	Migration guard: if InputController has no pressAction / releaseAction yet (B2 change
	pending), ActionMap stays in STANDBY: it binds nothing (InputController's own key dispatch
	keeps working, nothing fires twice), still computes active actions for the hint bar / touch
	buttons, and touch taps fire InputController.ActionPressed directly.

	Security: presentation only — every listener ends in a server-validated intent remote.

	Studio test hook: the LocalPlayer attribute `DevPlatformContexts` ("Producer,Pad", Studio
	only) switches contexts on for device-matrix screenshots without walking to a producer.

	Connects to: Shared/Config/PlatformConfig, Platform/{ActionLogic, HintBar, TouchButtons,
	GamepadNav, MenuWheel, PlatformController}, Controllers/InputController, UI/ScreenManager,
	Client/ClientState, Shared/Config/Worlds/WorldsConfig (features.attack per world).

	Example:
		ActionMap.addContextProvider(function(root: Vector3)
			return { Producer = nearestProducer(root) ~= nil }
		end)
		ActionMap.setHintText("Interact", "Upgrade x10")
		ActionMap.Changed:Connect(function() print(ActionMap.isActive("Produce")) end)
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ActionLogic = require(script.Parent.ActionLogic)
local ClientState = require(script.Parent.Parent.ClientState)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type ActionName = PlatformConfig.ActionName
export type ContextName = PlatformConfig.ContextName
-- A context provider: called with the character root position, returns the contexts it sees.
export type Provider = (root: Vector3) -> { [string]: boolean }?

local ActionMap = {}

-- Fires () after the active set or a hint text changed (HintBar / TouchButtons re-render).
ActionMap.Changed = Signal.new() :: Signal.Signal<>

-- ContextActionService action-name prefix (unique per action).
local CAS_PREFIX = "SNPlatform_"
-- Hint texts longer than this are cut (they are display strings from local code).
local MAX_HINT_LENGTH = 32
local DEV_CONTEXTS_ATTR = "DevPlatformContexts"

local actions = PlatformConfig.Actions :: { [string]: PlatformConfig.Binding }
local knownContexts: { [string]: boolean } = {}
for _, name in PlatformConfig.Contexts do
	knownContexts[name] = true
end

local manualContexts: { [string]: boolean } = {}
local providedContexts: { [string]: boolean } = {}
local devContexts: { [string]: boolean } = {}
local providers: { [number]: Provider } = {}
local nextProviderId = 0
local hintText: { [string]: string } = {}
local active: { [string]: boolean } = {}
local bound: { [string]: boolean } = {}
-- Actions currently held through a CAS press (released on End / Cancel / unbind).
local heldByCas: { [string]: boolean } = {}
-- KeyCodes whose Begin we Sank (their End is Sunk too, so nothing sees half a press).
local sunk: { [Enum.KeyCode]: boolean } = {}
local attackUnlocked = false
-- R57: false while the player is in a world whose features.attack is false (Dino Valley).
local attackWorld = true
local selecting = false
local dirty = false
local started = false
-- True once InputController exposes pressAction / releaseAction (see the module header).
local casMode = false

type PressFn = (action: string) -> boolean
type ReleaseFn = (action: string) -> ()
local pressFn: PressFn? = nil
local releaseFn: ReleaseFn? = nil

-- The environment ActionLogic evaluates (a fresh table per recompute).
local function currentEnv(): ActionLogic.Env
	local contexts: { [string]: boolean } = table.clone(manualContexts)
	for name, on in providedContexts do
		contexts[name] = contexts[name] or on
	end
	for name, on in devContexts do
		contexts[name] = contexts[name] or on
	end
	contexts.AttackUnlocked = attackUnlocked and attackWorld
	contexts.Selecting = selecting
	return {
		studio = RunService:IsStudio(),
		menu = ScreenManager.anyModalOpen(),
		selecting = selecting,
		contexts = contexts,
	}
end

-- Releases an action pressed through CAS (InputController fires ActionReleased).
local function releaseHeld(name: string)
	if not heldByCas[name] then
		return
	end
	heldByCas[name] = nil
	local release = releaseFn
	if release ~= nil then
		release(name)
	end
end

--[[
	The single ContextActionService handler for every platform action.
	Begin: fire the action (if still active) and Sink the press when it fired.
	End / Cancel: release it; Sink the End when its Begin was sunk.
	Change (trigger travel): ignored.
]]
local function onCas(actionName: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	local name = string.sub(actionName, #CAS_PREFIX + 1)
	local binding = actions[name]
	if binding == nil then
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		if not active[name] then
			return Enum.ContextActionResult.Pass
		end
		-- Belt and braces: a freeNav D-pad press never fights the menu selection.
		if binding.freeNav == true and GuiService.SelectedObject ~= nil then
			return Enum.ContextActionResult.Pass
		end
		local press = pressFn
		if press ~= nil and press(name) then
			heldByCas[name] = true
			sunk[input.KeyCode] = true
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		releaseHeld(name)
		if sunk[input.KeyCode] then
			sunk[input.KeyCode] = nil
			return Enum.ContextActionResult.Sink
		end
	end
	return Enum.ContextActionResult.Pass
end

-- Binds one action's keys + buttons at its priority.
local function bind(name: string)
	local binding = actions[name]
	local inputs: { Enum.KeyCode } = {}
	for _, key in binding.keys do
		table.insert(inputs, key)
	end
	for _, button in binding.buttons do
		table.insert(inputs, button)
	end
	if #inputs == 0 then
		return
	end
	ContextActionService:BindActionAtPriority(CAS_PREFIX .. name, onCas, false, binding.priority, table.unpack(inputs))
	bound[name] = true
end

-- Unbinds one action (CAS sends Cancel to a held press; releaseHeld covers it either way).
local function unbind(name: string)
	ContextActionService:UnbindAction(CAS_PREFIX .. name)
	bound[name] = nil
	releaseHeld(name)
end

-- Re-evaluates every action (coalesced through `schedule`).
local function recompute()
	dirty = false
	local nextActive = ActionLogic.activeSet(actions, currentEnv())
	local changed = false
	for name in actions do
		local on = nextActive[name] == true
		if on ~= (active[name] == true) then
			changed = true
		end
		if casMode then
			if on and not bound[name] then
				bind(name)
			elseif not on and bound[name] then
				unbind(name)
			end
		end
	end
	active = nextActive
	if changed then
		ActionMap.Changed:Fire()
	end
end

-- Schedules one recompute at the end of this frame (many changes = one recompute).
local function schedule()
	if dirty then
		return
	end
	dirty = true
	task.defer(recompute)
end

--[[
	Switches a context on / off (systems that track it themselves).
	@param name a PlatformConfig.Contexts name (unknown names are ignored with a warning)
	@param on   true = on
	Example: ActionMap.setContext("Egg", true)
]]
function ActionMap.setContext(name: ContextName, on: boolean)
	if not knownContexts[name] then
		warn(`[ActionMap] unknown context {name}`)
		return
	end
	local value = if on then true else nil
	if manualContexts[name] == value then
		return
	end
	manualContexts[name] = value
	schedule()
end

--[[ True when a context is on from any source (setContext, providers, ActionMap's own). ]]
function ActionMap.context(name: ContextName): boolean
	return currentEnv().contexts[name] == true
end

--[[
	Registers a context provider, polled at PlatformConfig.ContextHz with the character's root
	position (not called while the character is missing). Errors are caught and warned once.
	@param provider (root) -> { [ContextName]: boolean }?
	@return remove() — unregisters it
	Example: local remove = ActionMap.addContextProvider(function(root) return { Pad = near(root) } end)
]]
function ActionMap.addContextProvider(provider: Provider): () -> ()
	nextProviderId += 1
	local id = nextProviderId
	providers[id] = provider
	return function()
		providers[id] = nil
	end
end

--[[ True while `action` is bound (its context applies and no menu blocks it). ]]
function ActionMap.isActive(action: ActionName): boolean
	return active[action] == true
end

--[[ A copy of the active set ({ [name]: true }). ]]
function ActionMap.activeSet(): { [string]: boolean }
	return table.clone(active)
end

--[[
	Overrides an action's hint / touch caption (nil restores the PlatformConfig default).
	@param action the action
	@param text   short display text ("Upgrade x10", "Buy $1.2K"); cut to 32 characters
	Example: ActionMap.setHintText("UpgradeMode", "x10")
]]
function ActionMap.setHintText(action: ActionName, text: string?)
	local value: string? = nil
	if type(text) == "string" and text ~= "" then
		value = if #text > MAX_HINT_LENGTH then string.sub(text, 1, MAX_HINT_LENGTH) else text
	end
	if hintText[action] == value then
		return
	end
	hintText[action] = value
	ActionMap.Changed:Fire()
end

--[[ The live hint-text overrides (a copy; ActionLogic reads it). ]]
function ActionMap.hintTexts(): { [string]: string }
	return table.clone(hintText)
end

--[[
	Presses an action programmatically (touch buttons): same gating as a key press.
	@return true when the action fired
	Example: ActionMap.tap("Produce")
]]
function ActionMap.tap(action: ActionName): boolean
	if not active[action] then
		return false
	end
	local press, release = pressFn, releaseFn
	if press ~= nil and release ~= nil then
		local fired = press(action)
		if fired then
			release(action)
		end
		return fired
	end
	-- STANDBY: InputController has no programmatic press yet; fire its signals directly with
	-- the same blocking rule it applies to keys.
	local binding = actions[action]
	if not InputController.isGameplayEnabled() and not binding.whileBlocked then
		return false
	end
	InputController.ActionPressed:Fire(action :: any)
	InputController.ActionReleased:Fire(action :: any)
	return true
end

--[[ True once actions are bound through ContextActionService (false = standby). ]]
function ActionMap.isCasMode(): boolean
	return casMode
end

-- Toggles a screen for an action with `screen` (Menu also replaces another open modal).
local function toggleScreen(name: string, binding: PlatformConfig.Binding)
	if ScreenManager.isOpen(name) then
		ScreenManager.close(name)
		return
	end
	if binding.whileBlocked and ScreenManager.anyModalOpen() then
		ScreenManager.closeAllModals()
	end
	ScreenManager.open(name)
end

-- ActionMap's own reactions to its actions (screen toggles, Deselect).
local function onActionPressed(action: string)
	local binding = actions[action]
	if binding == nil or not active[action] then
		return -- STANDBY gating: InputController may dispatch actions whose context is off
	end
	if binding.screen ~= nil then
		toggleScreen(binding.screen, binding)
	elseif action == "Deselect" then
		GuiService.SelectedObject = nil
	end
end

-- The character root position, or nil (not spawned / dead).
local function rootPosition(): Vector3?
	local character = Players.LocalPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root.Position else nil
end

-- Providers that errored (warned once each).
local providerWarned: { [number]: boolean } = {}

-- One provider poll: merge every provider's contexts; schedule a recompute on change.
local function pollProviders()
	local merged: { [string]: boolean } = {}
	local root = rootPosition()
	if root ~= nil then
		for id, provider in providers do
			local ok, result = pcall(provider, root)
			if not ok then
				if not providerWarned[id] then
					providerWarned[id] = true
					warn(`[ActionMap] context provider {id} failed: {result}`)
				end
			elseif type(result) == "table" then
				for name, on in result do
					if knownContexts[name] and on == true then
						merged[name] = true
					end
				end
			end
		end
	end
	local changed = false
	for name in merged do
		if not providedContexts[name] then
			changed = true
		end
	end
	for name in providedContexts do
		if not merged[name] then
			changed = true
		end
	end
	if changed then
		providedContexts = merged
		schedule()
	end
end

-- Reads profile.attack.launcher (> 0 unlocks the Attack action).
local function readAttack(profile: ClientState.Profile?)
	local attack = if profile ~= nil then profile.attack else nil
	local launcher = if type(attack) == "table" then attack.launcher else nil
	local unlocked = type(launcher) == "number" and launcher > 0
	if unlocked ~= attackUnlocked then
		attackUnlocked = unlocked
		schedule()
	end
end

--[[
	R57: reads the server-set Player attribute CurrentWorld; attacks are allowed in Nuke Town and in
	any world whose WorldsConfig features.attack is not false (junk / unknown ids = Nuke Town).
	Same rule as the HUD's Attack button (UI/Hud/Hud worldHides).
]]
local function readWorld()
	local worldId = Players.LocalPlayer:GetAttribute("CurrentWorld")
	local def = if type(worldId) == "string" then WorldsConfig.get(worldId) else nil
	local allowed = def == nil or def.id == WorldsConfig.MAIN or def.features.attack ~= false
	if allowed ~= attackWorld then
		attackWorld = allowed
		schedule()
	end
end

-- Studio-only: DevPlatformContexts = "Producer,Pad" switches contexts on for screenshots.
local function readDevContexts()
	local raw = Players.LocalPlayer:GetAttribute(DEV_CONTEXTS_ATTR)
	table.clear(devContexts)
	if type(raw) == "string" and #raw <= 200 then
		for _, part in string.split(raw, ",") do
			local name = string.gsub(part, "%s", "")
			if knownContexts[name] then
				devContexts[name] = true
			end
		end
	end
	schedule()
end

--[[
	Starts the action map (once; PlatformController). Detects the InputController dispatch API,
	wires the menu / selection / profile / provider sources and binds the first active set.
]]
function ActionMap.start()
	if started then
		return
	end
	started = true
	-- Typed locals (assigned from `any`) keep the calls checkable under the new solver.
	local api = InputController :: any
	local rawPress: (string) -> any = api.pressAction
	local rawRelease: (string) -> () = api.releaseAction
	if rawPress ~= nil and rawRelease ~= nil then
		casMode = true
		pressFn = function(action: string): boolean
			return rawPress(action) == true
		end
		releaseFn = function(action: string)
			rawRelease(action)
		end
	else
		warn("[ActionMap] InputController.pressAction missing: STANDBY (legacy key dispatch)")
	end
	if RunService:IsStudio() then
		for _, problem in ActionLogic.validate(actions) do
			warn(`[ActionMap] config: {problem}`)
		end
		Players.LocalPlayer:GetAttributeChangedSignal(DEV_CONTEXTS_ATTR):Connect(readDevContexts)
		readDevContexts()
	end
	InputController.ActionPressed:Connect(onActionPressed)
	ScreenManager.Opened:Connect(schedule)
	ScreenManager.Closed:Connect(schedule)
	GuiService:GetPropertyChangedSignal("SelectedObject"):Connect(function()
		local now = GuiService.SelectedObject ~= nil
		if now ~= selecting then
			selecting = now
			schedule()
		end
	end)
	selecting = GuiService.SelectedObject ~= nil
	ClientState.ProfileChanged:Connect(function(profile, fields)
		if fields == nil or table.find(fields, "attack") ~= nil then
			readAttack(profile)
		end
	end)
	readAttack(ClientState.profile)
	Players.LocalPlayer:GetAttributeChangedSignal("CurrentWorld"):Connect(readWorld)
	readWorld()
	-- One provider loop for every provider (skips the poll while none is registered).
	task.spawn(function()
		local period = 1 / math.max(PlatformConfig.ContextHz, 1)
		while true do
			task.wait(period)
			if next(providers) ~= nil or next(providedContexts) ~= nil then
				pollProviders()
			end
		end
	end)
	recompute()
end

return ActionMap
