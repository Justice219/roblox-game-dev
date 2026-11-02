--!strict
--[[
	WorldTabBar — the shared stud world-tab row (NUKE TOWN | DINO VALLEY | ...) of the Teleport,
	Rebirth and Shop screens (owner R57 World 2, spec §4.3 / §14).

	Purpose:
		One stud tab button per world in WorldsConfig.Order (WorldClientLogic.tabs model): the
		selected tab wears its world colour, the others are grey; a locked world shows the Lock
		icon, a world closed by the admin kill switch the Clock icon. Tabs are >= 44 pt on every
		device (WorldClientConfig.TabHeight / TabMinWidth design px; phones use the short labels).
		Width (R70, a third world): each tab is TabMinWidth design px when the row has room, else
		the row's width shared evenly (minus the gaps), so 3+ worlds always fit the screen's body
		(re-measured when the row's size or the UI scale changes; never per frame).
		LB / RB (Q / E) cycle the tabs through a GamepadNav cycler (enable in the screen's onOpen,
		disable in onClose); the hint bar shows "LB RB Tabs" meanwhile. Selecting a locked /
		closed tab only shows its hint — the bar never sends anything.
		Balances (owner R60, opt-in `balances = true`, the Teleport screen): each OPEN world's tab
		wears its own balance in a small dark pill hanging under it (currency icon + the compact
		amount, e.g. "$252SX" / "9.99T"), so every world's money is visible where you pick the
		world, while the HUD shows only the current world's currency. `setBalance(id, icon, text?)`
		updates one pill (nil text hides it, e.g. a locked world).

	Connects to: Worlds/{WorldClientLogic, WorldClient}, Kit/StudUI, UI/{Create, ScreenManager},
	Platform/GamepadNav, Shared/Config/WorldClientConfig; callers UI/Screens/{Teleport, Rebirth,
	Shop}.

	Example:
		local bar = WorldTabBar.new({ parent = window.body, layoutOrder = 1, onSelect = showWorld })
		bar.render(WorldClient.tabs(), "dino")
		bar.enable() -- onOpen ; bar.disable() -- onClose
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.UI.Create)
local GamepadNav = require(script.Parent.Parent.Platform.GamepadNav)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)
local WorldClientConfig = require(ReplicatedStorage.Shared.Config.WorldClientConfig)
local WorldClientLogic = require(script.Parent.WorldClientLogic)

export type Options = {
	parent: Instance,
	layoutOrder: number?,
	onSelect: (worldId: string) -> (),
	textSize: number?,
	balances: boolean?, -- R60: a balance pill under each tab (setBalance)
}

export type TabBar = {
	frame: Frame,
	-- Re-draws the tabs (model from WorldClient.tabs()) with `selected` highlighted.
	render: (tabs: { WorldClientLogic.Tab }, selected: string) -> (),
	-- The tab button of a world (gamepad links), or nil.
	button: (worldId: string) -> GuiObject?,
	-- Every tab button in order (gamepad links).
	buttons: () -> { GuiObject },
	-- R60 (balances = true): one tab's balance pill (IconAssets key + text; nil text hides it).
	setBalance: (worldId: string, icon: string, text: string?) -> (),
	enable: () -> (),
	disable: () -> (),
	Destroy: () -> (),
}

local WorldTabBar = {}

-- Design px of the lock / clock corner badge.
local BADGE_SIZE = 40
-- R60 balance pill (design px): height, how far it hangs below the tab, text (>= 14 pt on a
-- phone at 0.62 pt / px), icon, side padding.
local BALANCE_HEIGHT = 34
local BALANCE_DROP = 22
local BALANCE_TEXT = 24
local BALANCE_ICON = 26
local BALANCE_PAD = 10
-- Gap between tabs (design px; the UIListLayout padding).
local TAB_GAP = 12

--[[
	Builds the tab row (a horizontal list; height = WorldClientConfig.TabHeight).
	@param options parent / layoutOrder / onSelect(worldId) / textSize
	@return TabBar
]]
function WorldTabBar.new(options: Options): TabBar
	local height = WorldClientConfig.TabHeight
	local withBalances = options.balances == true
	local frame = Create.new("Frame", {
		Name = "WorldTabs",
		BackgroundTransparency = 1,
		-- Balances hang under the tabs: the row reserves their drop so nothing overlaps them.
		Size = UDim2.new(1, 0, 0, height + (if withBalances then BALANCE_DROP else 0)),
		LayoutOrder = options.layoutOrder or 0,
		Parent = options.parent,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = if withBalances then Enum.VerticalAlignment.Top else Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, TAB_GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
	local buttons: { [string]: StudUI.Button } = {}
	local badges: { [string]: { lock: Frame, closed: Frame } } = {}
	-- R60: per world, the balance pill + its label + the icon frames by key (built on first use).
	type Pill = { frame: Frame, label: TextLabel, icons: { [string]: Frame } }
	local pills: { [string]: Pill } = {}
	local order: { string } = {}
	local tabs: { WorldClientLogic.Tab } = {}
	local selected = ""
	local onSelect = options.onSelect
	local tabWidth = WorldClientConfig.TabMinWidth

	--[[
		Fits the tabs to the row: TabMinWidth each when there is room, else the row's design width
		(AbsoluteSize / UI scale) shared evenly. A row not laid out yet keeps TabMinWidth and is
		re-fitted when its AbsoluteSize arrives.
	]]
	local function fit()
		local count = #order
		if count == 0 then
			return
		end
		local scale = math.max(ScreenManager.scale, 0.01)
		local available = frame.AbsoluteSize.X / scale
		local width = WorldClientConfig.TabMinWidth
		if available > 0 then
			width = math.min(width, math.floor((available - TAB_GAP * (count - 1)) / count))
		end
		if width ~= tabWidth then
			tabWidth = width
			for _, worldId in order do
				local button = buttons[worldId]
				if button ~= nil then
					button.instance.Size = UDim2.fromOffset(width, height)
				end
			end
		end
	end
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)

	-- Builds a tab button once per world (ids never change at runtime).
	local function ensure(tab: WorldClientLogic.Tab, index: number): StudUI.Button
		local existing = buttons[tab.id]
		if existing ~= nil then
			return existing
		end
		local worldId = tab.id
		local button = StudUI.button({
			text = tab.label,
			color = "grey",
			icon = tab.icon,
			size = UDim2.fromOffset(tabWidth, height),
			textSize = options.textSize or 28,
			layoutOrder = index,
			name = `Tab_{worldId}`,
			parent = frame,
			onActivated = function()
				onSelect(worldId)
			end,
		})
		buttons[worldId] = button
		table.insert(order, worldId)
		-- Corner badges (built once, toggled by render): Lock = locked, Clock = kill switch.
		local function badge(key: string): Frame
			local mark = StudUI.icon(key, BADGE_SIZE, 6)
			mark.AnchorPoint = Vector2.new(0.5, 0.5)
			mark.Position = UDim2.new(1, -8, 0, 8)
			mark.Visible = false
			mark.Parent = button.instance
			return mark
		end
		badges[worldId] = { lock = badge("Lock"), closed = badge("Clock") }
		if withBalances then
			-- The balance pill: centred under the tab, overlapping its bottom edge a little.
			local pill = Create.new("Frame", {
				Name = "Balance",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 1, BALANCE_DROP - BALANCE_HEIGHT),
				Size = UDim2.fromOffset(0, BALANCE_HEIGHT),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundColor3 = Color3.fromRGB(28, 24, 40),
				BackgroundTransparency = 0.1,
				Visible = false,
				ZIndex = 7,
				Parent = button.instance,
				Children = {
					Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
					Create.new("UIPadding", {
						PaddingLeft = UDim.new(0, BALANCE_PAD),
						PaddingRight = UDim.new(0, BALANCE_PAD),
					}),
					Create.new("UIListLayout", {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, 6),
						SortOrder = Enum.SortOrder.LayoutOrder,
					}),
				},
			}) :: Frame
			pill:SetAttribute("Decorative", true)
			local text = StudUI.text({
				name = "Amount",
				text = "",
				textSize = BALANCE_TEXT,
				size = UDim2.fromOffset(0, BALANCE_HEIGHT),
				zIndex = 8,
				parent = pill,
			})
			text.AutomaticSize = Enum.AutomaticSize.X
			text.LayoutOrder = 2
			pills[worldId] = { frame = pill, label = text, icons = {} }
		end
		return button
	end

	-- LB / RB: the neighbouring tab (wraps).
	local cycler = GamepadNav.cycler(function()
		if #tabs > 0 then
			onSelect(WorldClientLogic.cycle(tabs, selected, -1))
		end
	end, function()
		if #tabs > 0 then
			onSelect(WorldClientLogic.cycle(tabs, selected, 1))
		end
	end)

	return {
		frame = frame,
		render = function(model: { WorldClientLogic.Tab }, selectedId: string)
			tabs = model
			selected = selectedId
			-- Phones: the short labels keep every tab >= 44 pt and readable.
			local compact = ScreenManager.device ~= nil and ScreenManager.device.isPhone == true
			local before = #order
			for index, tab in model do
				local button = ensure(tab, index)
				local text = if compact then tab.short else tab.label
				button.setText(text)
				local isSelected = tab.id == selectedId
				button.setColor((if isSelected then tab.color else "grey") :: any)
				-- Lock / clock badge on a locked / closed world (top-right corner of the tab).
				local marks = badges[tab.id]
				if marks ~= nil then
					marks.lock.Visible = tab.state == "locked"
					marks.closed.Visible = tab.state == "closed"
				end
				button.instance:SetAttribute("WorldState", tab.state)
				button.instance:SetAttribute("Selected", isSelected)
			end
			if #order ~= before then
				fit() -- a tab was added: share the row again
			end
		end,
		button = function(worldId: string): GuiObject?
			local button = buttons[worldId]
			return if button ~= nil then button.instance else nil
		end,
		buttons = function(): { GuiObject }
			local list: { GuiObject } = {}
			for _, worldId in order do
				table.insert(list, buttons[worldId].instance)
			end
			return list
		end,
		setBalance = function(worldId: string, icon: string, text: string?)
			local pill = pills[worldId]
			if pill == nil then
				return
			end
			if text == nil then
				pill.frame.Visible = false
				return
			end
			if pill.icons[icon] == nil then
				local mark = StudUI.icon(icon, BALANCE_ICON, 8)
				mark.LayoutOrder = 1
				mark.Parent = pill.frame
				pill.icons[icon] = mark
			end
			for key, mark in pill.icons do
				mark.Visible = key == icon
			end
			pill.label.Text = text
			pill.frame.Visible = true
		end,
		enable = cycler.enable,
		disable = cycler.disable,
		Destroy = function()
			cycler.Destroy()
			frame:Destroy()
		end,
	}
end

return table.freeze(WorldTabBar)
