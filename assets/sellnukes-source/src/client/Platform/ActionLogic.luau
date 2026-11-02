--!strict
--[[
	ActionLogic — pure rules of the action map: which actions are bound right now, which hints
	the hint bar shows for a device, which touch buttons appear (no services, no Instances, so
	tests/platform-actions.luau runs it under Lune).

	Rules (PlatformConfig header has the field meanings):
		isActive(binding, env)
			- studioOnly actions only in Studio,
			- a modal open (env.menu) unbinds every action without whileBlocked
			  ("menu open → only UI navigation"),
			- freeNav actions are unbound while a GUI object holds the gamepad selection,
			- `contexts` = any-of; nil = always.
		hints(actions, active, device, hintText, max)
			- only actions with a `hint` and a binding on the device (Buy has no key, so the
			  keyboard hint for buying is Interact's),
			- contextual hints first (hintOrder), then gamepad idle hints (idleHint),
			- de-duplicated by text (Buy "[A] Buy" beats Interact "[X] Buy" on a pad),
			- Touch shows no hints (on-screen buttons instead).
		touchButtons(actions, active, hintText)
			- active actions with a `touch` spec, ordered by spec.order; the caption is the live
			  hint-text override upper-cased when one is set ("UPGRADE X10" / "BUY $1.2K").

	Connects to: Shared/Config/PlatformConfig, Platform/{ActionMap, HintBar, TouchButtons}.

	Example:
		local env = { studio = false, menu = false, selecting = false, contexts = { Producer = true } }
		print(ActionLogic.isActive(PlatformConfig.Actions.UpgradeMode, env)) --> true
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)

export type Binding = PlatformConfig.Binding
export type Device = "KeyboardMouse" | "Gamepad" | "Touch"

-- Everything isActive needs to know about the client right now.
export type Env = {
	studio: boolean, -- RunService:IsStudio()
	menu: boolean, -- a modal screen is open
	selecting: boolean, -- GuiService.SelectedObject ~= nil
	contexts: { [string]: boolean }, -- context name -> on
}

-- One hint-bar chip.
export type Hint = {
	action: string,
	text: string,
	keyCodes: { Enum.KeyCode }, -- glyph(s) to draw (first key / button of the device)
}

-- One touch button to show.
export type TouchButton = {
	action: string,
	label: string,
	spec: PlatformConfig.TouchSpec,
}

local ActionLogic = {}

--[[
	True when `binding` must be bound in `env` (rules in the module header).
	@param binding the action's PlatformConfig binding
	@param env     the client state snapshot
	Example: ActionLogic.isActive(PlatformConfig.Actions.Buy, env) --> env.contexts.Pad == true
]]
function ActionLogic.isActive(binding: Binding, env: Env): boolean
	if binding.studioOnly == true and not env.studio then
		return false
	end
	if env.menu and not binding.whileBlocked then
		return false
	end
	if binding.freeNav == true and env.selecting then
		return false
	end
	local contexts = binding.contexts
	if contexts == nil then
		return true
	end
	for _, name in contexts do
		if env.contexts[name] == true then
			return true
		end
	end
	return false
end

--[[
	The set of active action names for `env`.
	@param actions the action table (PlatformConfig.Actions)
	@return { [name]: true } for every active action
]]
function ActionLogic.activeSet(actions: { [string]: Binding }, env: Env): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for name, binding in actions do
		if ActionLogic.isActive(binding, env) then
			set[name] = true
		end
	end
	return set
end

--[[
	The KeyCodes a device presses for `binding` (keyboard keys, gamepad buttons, none on touch).
	Example: ActionLogic.deviceKeys(PlatformConfig.Actions.Produce, "Gamepad") --> { ButtonR2 }
]]
function ActionLogic.deviceKeys(binding: Binding, device: Device): { Enum.KeyCode }
	if device == "Gamepad" then
		return binding.buttons
	elseif device == "KeyboardMouse" then
		return binding.keys
	end
	return {}
end

-- Stable order for hints / buttons: hintOrder (or order), then name.
local function byOrder(a: { order: number, name: string }, b: { order: number, name: string }): boolean
	if a.order ~= b.order then
		return a.order < b.order
	end
	return a.name < b.name
end

--[[
	The hint-bar chips for `device` (rules in the module header).
	@param actions  the action table
	@param active   ActionLogic.activeSet result
	@param device   the current input device
	@param hintText live text overrides by action (ActionMap.setHintText)
	@param maxHints chip cap
	@return ordered hints (empty on Touch)
	Example: ActionLogic.hints(PlatformConfig.Actions, active, "Gamepad", {}, 4)
]]
function ActionLogic.hints(
	actions: { [string]: Binding },
	active: { [string]: boolean },
	device: Device,
	hintText: { [string]: string },
	maxHints: number
): { Hint }
	if device == "Touch" then
		return {}
	end
	local contextual: { { order: number, name: string } } = {}
	local idle: { { order: number, name: string } } = {}
	for name, binding in actions do
		if active[name] and binding.hint ~= nil and #ActionLogic.deviceKeys(binding, device) > 0 then
			local entry = { order = binding.hintOrder or 100, name = name }
			if binding.idleHint == true or binding.contexts == nil then
				-- Context-free actions are navigation: gamepad-only idle hints, and only the ones
				-- flagged idleHint (D-pad up / right / down stay unhinted to keep the bar short).
				if device == "Gamepad" and binding.idleHint == true then
					table.insert(idle, entry)
				end
			else
				table.insert(contextual, entry)
			end
		end
	end
	table.sort(contextual, byOrder)
	table.sort(idle, byOrder)
	local result: { Hint } = {}
	local seen: { [string]: boolean } = {}
	local function push(entry: { order: number, name: string })
		if #result >= maxHints then
			return
		end
		local binding = actions[entry.name]
		local text = hintText[entry.name] or binding.hint or binding.label
		local key = string.lower(text)
		if seen[key] then
			return
		end
		seen[key] = true
		table.insert(result, {
			action = entry.name,
			text = text,
			keyCodes = { ActionLogic.deviceKeys(binding, device)[1] },
		})
	end
	for _, entry in contextual do
		push(entry)
	end
	for _, entry in idle do
		push(entry)
	end
	return result
end

--[[
	The touch buttons to show (rules in the module header).
	@return ordered by spec.order (1 = beside the jump button)
	Example: ActionLogic.touchButtons(PlatformConfig.Actions, active, { Interact = "Buy $10" })
]]
function ActionLogic.touchButtons(
	actions: { [string]: Binding },
	active: { [string]: boolean },
	hintText: { [string]: string }
): { TouchButton }
	local entries: { { order: number, name: string } } = {}
	for name, binding in actions do
		if active[name] and binding.touch ~= nil then
			table.insert(entries, { order = (binding.touch :: PlatformConfig.TouchSpec).order, name = name })
		end
	end
	table.sort(entries, byOrder)
	local result: { TouchButton } = {}
	local seenOrder: { [number]: boolean } = {}
	for _, entry in entries do
		-- Two actions on the same slot (Hatch and Produce are both order 1) never both show: the
		-- higher priority one (the one that wins the shared key) takes the slot.
		local spec = actions[entry.name].touch :: PlatformConfig.TouchSpec
		if seenOrder[spec.order] then
			local other: TouchButton? = nil
			for _, existing in result do
				if existing.spec.order == spec.order then
					other = existing
				end
			end
			if other ~= nil and actions[entry.name].priority > actions[other.action].priority then
				other.action = entry.name
				other.spec = spec
				other.label = string.upper(hintText[entry.name] or spec.label)
			end
			continue
		end
		seenOrder[spec.order] = true
		table.insert(result, {
			action = entry.name,
			label = string.upper(hintText[entry.name] or spec.label),
			spec = spec,
		})
	end
	return result
end

--[[
	Configuration problems in an action table (tests + a Studio boot warning):
		- unknown context names,
		- an action with no gamepad button (console first; studioOnly tools excepted),
		- an action with no keyboard key unless listed in PlatformConfig.NoKeyboardOk,
		- two actions that can be bound together on the same key at the same priority (CAS
		  would then pick whichever bound last).
	@return list of human-readable problems (empty = valid)
]]
function ActionLogic.validate(actions: { [string]: Binding }): { string }
	local problems: { string } = {}
	local known: { [string]: boolean } = {}
	for _, name in PlatformConfig.Contexts do
		known[name] = true
	end
	local names: { string } = {}
	for name in actions do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local binding = actions[name]
		for _, context in binding.contexts or {} do
			if not known[context] then
				table.insert(problems, `{name}: unknown context {context}`)
			end
		end
		if binding.studioOnly ~= true then
			if #binding.buttons == 0 then
				table.insert(problems, `{name}: no gamepad button`)
			end
			if #binding.keys == 0 and not PlatformConfig.NoKeyboardOk[name] then
				table.insert(problems, `{name}: no keyboard key`)
			end
		end
	end
	-- Same key + same priority: a conflict when both can be bound together (either is
	-- context-free, or they share a context). Different contexts that merely could overlap at
	-- runtime (Producer vs Pad) are allowed: their actions differ in priority where it matters.
	for i = 1, #names do
		for j = i + 1, #names do
			local a, b = actions[names[i]], actions[names[j]]
			if a.priority == b.priority then
				local shared = false
				for _, keyList in { { a.keys, b.keys }, { a.buttons, b.buttons } } do
					for _, key in keyList[1] do
						if table.find(keyList[2], key) ~= nil then
							shared = true
						end
					end
				end
				if shared then
					local overlap = a.contexts == nil or b.contexts == nil
					for _, context in a.contexts or {} do
						if table.find(b.contexts or {}, context) ~= nil then
							overlap = true
						end
					end
					if overlap then
						table.insert(problems, `{names[i]} / {names[j]}: same key at the same priority`)
					end
				end
			end
		end
	end
	return problems
end

return table.freeze(ActionLogic)
