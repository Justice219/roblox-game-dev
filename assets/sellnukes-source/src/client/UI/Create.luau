--!strict
--[[
	Create — tiny declarative helper for building Instance trees in code (ported from RoBeasts).

	Purpose:
		All UI is built from code (Rojo-friendly, reviewable). This helper keeps that readable:
		set properties, attach children, and connect events in one expression, parenting last so
		nothing renders half-built.

	Special keys in `props`:
		Children = { Instance }                 children to parent under the new instance
		[Event]  = handler                      use Create.event("Activated") as the key
		Parent   = Instance                     applied last

	Connects to: every UI module (Components, Kit/StudUI, Hud, Screens).

	Example:
		local button = Create.new("TextButton", {
			Size = UDim2.fromOffset(200, 60),
			Text = "PLAY",
			[Create.event("Activated")] = function() print("go") end,
			Children = { Create.new("UICorner", { CornerRadius = Theme.Corner }) },
		})
]]

export type EventKey = { __eventName: string }

local Create = {}
local bindButtonFeedback: ((GuiButton) -> ())? = nil

--[[
	Installs a hook that runs for every GuiButton built through Create.new (before its props are
	applied), e.g. a click-sound / press-feel binder. UIController supplies it at boot; keeping
	the tiny factory independent prevents a Create/Sound/Components require cycle.
	@param bind called once per new GuiButton
	Example: Create.setButtonFeedbackBinder(function(button) SoundHooks.bind(button) end)
]]
function Create.setButtonFeedbackBinder(bind: (GuiButton) -> ())
	bindButtonFeedback = bind
end

local eventKeys: { [string]: EventKey } = {}

--[[ Returns a unique key used to connect `eventName` (e.g. "Activated") in Create props. ]]
function Create.event(eventName: string): EventKey
	local key = eventKeys[eventName]
	if key == nil then
		local created: EventKey = { __eventName = eventName }
		eventKeys[eventName] = created
		return created
	end
	return key
end

--[[
	Creates an instance of `className` with `props`. Returns `any` so call sites can cast to the
	concrete class: `local frame = Create.new("Frame", {...}) :: Frame`.
]]
function Create.new(className: string, props: { [any]: any }?): any
	local instance = Instance.new(className :: any)
	-- Register before action callbacks: a click can close its source screen immediately.
	-- Feedback owns no input actions and becomes active only after UIController starts it.
	if instance:IsA("GuiButton") and bindButtonFeedback ~= nil then
		bindButtonFeedback(instance)
	end
	local parent: Instance? = nil
	if props ~= nil then
		for key, value in props do
			if key == "Children" then
				for _, child in value :: { Instance } do
					child.Parent = instance
				end
			elseif key == "Parent" then
				parent = value
			elseif type(key) == "table" and (key :: any).__eventName ~= nil then
				local signal = (instance :: any)[(key :: EventKey).__eventName] :: RBXScriptSignal
				signal:Connect(value)
			else
				(instance :: any)[key] = value
			end
		end
	end
	if parent ~= nil then
		instance.Parent = parent
	end
	return instance
end

return table.freeze(Create)
