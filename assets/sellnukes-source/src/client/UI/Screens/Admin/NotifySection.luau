--!strict
--[[
	NotifySection — the RETURN NOTIFICATIONS block on the admin panel's SERVER tab (owner R122
	§2.3: kill switch, per-kind on/off, queue size, last results, send test to me). It sits in the
	tab's info block, above the generic command forms (ActionsTab renders NotifyToggle /
	NotifyKind / NotifyStatus / NotifyTest / NotifyQueueTest from the catalogue like every other
	command).

	Shows:
		live line   "Sending ON · Factory full ON · Daily streak NO ID · Daily missions OFF" from
		            the ReplicatedStorage display attributes the server publishes
		            (NotifyConfig.Attributes; the universe control this server runs) + the shared
		            message ids (NotifySectionLogic.describe)
		note        what is missing / what the switches do
		stats       the last NotifyStatus result (mode LIVE / DRY / NO KEY, queue size + due now,
		            this server's plans / sends / results / drops, last result), with its time
		REFRESH     a chip that sends NotifyStatus (the server re-authorises it; not audited)

	Performance: event-driven (three attribute signals + AdminClient.Result filtered by name); no
	loop, nothing per frame. Security: display + one read-only intent.

	Console / mobile (owner R11): the REFRESH chip is a normal selectable stud chip (gamepad ring,
	>= 44 pt via the panel's fit), text wraps; nothing hover-only.

	Connects to: Screens/Admin/{AdminClient, AdminWidgets, NotifySectionLogic}, Shared/Config/
	{NotifyConfig, UIStyleConfig}. Mounted by Screens/Admin/ActionsTab (Server tab).

	Example (ActionsTab, Server tab):
		local notify = NotifySection.new({ parent = infoPanel, layoutOrder = 6, fit = fit })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminClient = require(script.Parent.AdminClient)
local AdminWidgets = require(script.Parent.AdminWidgets)
local NotifyConfig = require(ReplicatedStorage.Shared.Config.NotifyConfig)
local NotifySectionLogic = require(script.Parent.NotifySectionLogic)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type Options = {
	parent: Instance,
	layoutOrder: number,
	fit: (() -> number)?,
}

export type Section = {
	frame: Frame,
	first: () -> GuiObject?,
}

local NotifySection = {}

local Neutral = UIStyleConfig.Neutral

--[[
	Builds the section.
	@param options Options
	@return Section
]]
function NotifySection.new(options: Options): Section
	local panel = AdminWidgets.panel("ReturnNotifications", options.parent, options.layoutOrder)
	AdminWidgets.label({
		text = "Return notifications",
		size = UDim2.new(1, 0, 0, 30),
		textSize = 26,
		font = "title",
		layoutOrder = 1,
		parent = panel,
	})
	local line = AdminWidgets.label({
		name = "Live",
		text = "",
		size = UDim2.fromScale(1, 0),
		textSize = 22,
		wrap = true,
		rich = true,
		layoutOrder = 2,
		parent = panel,
	})
	line.AutomaticSize = Enum.AutomaticSize.Y
	local note = AdminWidgets.label({
		name = "Note",
		text = "",
		size = UDim2.fromScale(1, 0),
		textSize = 18,
		color = Neutral.TextDim,
		wrap = true,
		layoutOrder = 3,
		parent = panel,
	})
	note.AutomaticSize = Enum.AutomaticSize.Y

	local row = AdminWidgets.wrapRow("Stats", panel, 12, 4)
	local refresh = AdminWidgets.chip({
		text = "REFRESH STATUS",
		color = "orange",
		solid = true,
		width = 260,
		height = 56,
		fit = options.fit,
		layoutOrder = 1,
		parent = row,
		onActivated = function()
			AdminClient.send("NotifyStatus", {})
		end,
	})
	local stats = AdminWidgets.label({
		name = "StatusText",
		text = "Press REFRESH STATUS for the queue size and this server's results.",
		size = UDim2.new(1, -280, 0, 0),
		textSize = 18,
		color = Neutral.TextDim,
		wrap = true,
		layoutOrder = 2,
		parent = row,
	})
	stats.AutomaticSize = Enum.AutomaticSize.Y

	-- Repaints the live line + note from the attributes (event-driven).
	local function paint()
		local names = NotifyConfig.Attributes
		local attrs = {
			[names.On] = ReplicatedStorage:GetAttribute(names.On),
			[names.KindsOff] = ReplicatedStorage:GetAttribute(names.KindsOff),
		}
		local state = AdminClient.state
		local view = NotifySectionLogic.describe(attrs, NotifyConfig.Kinds, state ~= nil and state.isStudio)
		line.Text = view.line
		note.Text = view.note
	end

	for _, name in { NotifyConfig.Attributes.On, NotifyConfig.Attributes.KindsOff, NotifyConfig.Attributes.Version } do
		ReplicatedStorage:GetAttributeChangedSignal(name):Connect(paint)
	end
	-- The Studio flag arrives with the first AdminState push.
	local studioKnown = false
	AdminClient.Changed:Connect(function()
		if not studioKnown and AdminClient.state ~= nil then
			studioKnown = true
			paint()
		end
	end)
	AdminClient.Result:Connect(function(result: AdminClient.ResultPayload)
		if result.name == "NotifyStatus" then
			stats.Text = `{result.text}\n(updated {os.date("!%H:%M:%S")} UTC)`
			stats.TextColor3 = if result.ok then Neutral.Text else Neutral.Danger
			paint()
		elseif result.name == "NotifyToggle" or result.name == "NotifyKind" then
			paint()
		end
	end)
	paint()

	return {
		frame = panel,
		first = function(): GuiObject?
			return refresh.button
		end,
	}
end

return NotifySection
