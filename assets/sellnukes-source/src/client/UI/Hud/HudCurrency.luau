--!strict
--[[
	HudCurrency — the HUD's top-centre currency stack: Gems (purple gem + number), Cash (green
	money stack + chunky green number) and the "+$X/s" income rate (spec §6; reference 21).

	Purpose:
		Pure presentation of SERVER values: cash / gems come from ClientState.profile (synced from
		the server); the income rate comes from a source function the tycoon client installs
		(Hud.setIncomeSource) or, until then, from `profile.incomePerSecond` when the server
		includes it. Nothing here computes economy values.
		Cash rolls up on increases (StudUI.moneyLabel), snaps on spending.

	Worlds (owner R57 World 2, spec §14): in a non-main world (`setWorld(def)`) the stack becomes
		Gems | the world's currency, BIG (its icon + colour, e.g. the bone + a cream-amber number)
		| "+X/s Bones"
	inside the same Top zone (WorldClientConfig.Hud sizes; tests/hud-cluster.luau). Owner R60
	("if I go into Dino Valley from the main map, it doesn't have the same money"): another
	world shows ONLY its own currency (+ gems) — Nuke Town's Cash is not on screen there (each
	world's balance shows on its Teleport tab instead). Each world's widgets are built once, the
	first time the player enters that world; switching is a visibility swap. Nuke Town
	(`setWorld(nil)`) is exactly the original stack.

	Fly-to target (owner R46): `target(kind)` is the VISIBLE counter's icon of that kind in the
	current world (CurrencyFlyRules.counterFor, owner R61), where UI/Hud/CurrencyFly's sprites
	land (nil = no such counter on screen: nothing flies); `land(kind, reduced)` is the landing feedback — the icon pops inside
	its fixed-size slot (so the stack's list layout never shifts), a soft sparkle glints on its
	corner and the number flashes towards white. Every tween is built once and replayed; pops /
	glints are rate-limited (CurrencyFlyConfig.Land), and Reduce Motion keeps only the colour flash.
	Visual only: the number itself stays the server's value.

	Boost corner (owner R82: "the two x cash UI can kind of be like a corner piece for the cash"):
		a zero-size "BoostCorner" frame sits on the top-right corner of the VISIBLE primary
		counter's number (Nuke Town's Cash, or the shown world's currency: boosts multiply every
		world's income). It is positioned by scale (1, 0), so the engine keeps it on the digits'
		right end at any width with no script work, and a scale-positioned zero-size child never
		feeds the label's AutomaticSize (verified in Studio 2026-10-31). UI/Screens/BoostChips
		parents its badge into it (`HudCurrency.corner()`; `HudCurrency.Changed` fires when the
		anchor is built or the D-pad neighbours change). `linkNav(left, right)` (Hud.relayout)
		records the HUD buttons beside the stack so the badge can join the D-pad graph
		(`HudCurrency.navExits()`).

	Connects to: Kit/StudUI.moneyLabel, UI/Hud/Hud (owner: feeds values + position, attaches
	CurrencyFly), UI/Hud/CurrencyFly (target / land), UI/Screens/BoostChips (the R82 badge in the
	corner anchor), Shared/Config/{CurrencyFlyConfig, WorldClientConfig, Worlds/WorldsConfig},
	Worlds/WorldClientLogic (rate text), Shared/Util/Signal.

	Example:
		local currency = HudCurrency.new(container)
		currency.setCash(119080, true)
		currency.setRate(12.5)
		currency.land("cash", false) -- a flying coin arrived
		currency.setWorld(WorldsConfig.get("dino")) -- Bones primary (+ gems) only
		currency.setWorldCash(4500, true)
		badge.Parent = HudCurrency.corner() -- R82: rides on the shown counter's right end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Create = require(script.Parent.Parent.Create)
local CurrencyFlyConfig = require(ReplicatedStorage.Shared.Config.CurrencyFlyConfig)
local CurrencyFlyRules = require(script.Parent.CurrencyFlyRules)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldClientConfig = require(ReplicatedStorage.Shared.Config.WorldClientConfig)
local WorldClientLogic = require(script.Parent.Parent.Parent.Worlds.WorldClientLogic)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local Land = CurrencyFlyConfig.Land
-- Glint sparkle tint: warm white, never a blown-out neon (owner R19).
local GLINT_COLOR = Color3.fromRGB(255, 249, 214)

export type HudCurrency = {
	frame: Frame,
	setCash: (amount: number, animate: boolean?) -> (),
	setGems: (amount: number, animate: boolean?) -> (),
	setRate: (perSecond: number?) -> (), -- nil hides the rate row
	-- R57: the world shown (nil / Nuke Town = the original stack; else its currency is primary).
	setWorld: (def: WorldsConfig.WorldDef?) -> (),
	setWorldCash: (amount: number, animate: boolean?) -> (), -- the shown world's currency
	setWorldRate: (perSecond: number?) -> (), -- its "+X/s Bones" (nil hides the rate)
	height: () -> number,
	-- Where flying sprites land (the counter's icon); nil when no counter of that kind shows.
	target: (kind: FlyKind) -> GuiObject?,
	land: (kind: FlyKind, reduced: boolean) -> (), -- landing feedback (pop + glint + flash)
	-- R82: the HUD buttons left / right of the stack (D-pad exits of the boost badge).
	linkNav: (leftExit: GuiObject?, rightExit: GuiObject?) -> (),
	corner: () -> Frame, -- R82: the boost corner anchor (also HudCurrency.corner())
}

-- The counters money can fly into (UI/Hud/CurrencyFly): "cash", "gems", or a world currency key.
export type FlyKind = string

-- One non-main world's widgets (built once, on the first visit).
type WorldStack = {
	def: WorldsConfig.WorldDef,
	primary: StudUI.MoneyLabel,
	row: Frame,
	rate: StudUI.MoneyLabel,
	primaryLander: Lander,
	lastRate: number?,
}

-- One counter's landing feedback (built once per counter).
type Lander = {
	target: GuiObject,
	land: (reduced: boolean) -> (),
}

--[[
	Builds the landing feedback of one money counter: every Instance and Tween is created here,
	once; `land` only replays them (no allocation per landing).
	@param money    the StudUI money label (its icon slot is the child named `iconName`)
	@param iconName "Icon_Cash" / "Icon_Gems" (StudUI.icon names its slot Icon_<key>)
	@return Lander { target, land }
]]
local function lander(money: StudUI.MoneyLabel, iconName: string): Lander
	local label = money.label
	local holder = money.frame:FindFirstChild(iconName)
	local slot: GuiObject? = if holder ~= nil and holder:IsA("GuiObject") then holder else nil
	-- The icon's drawing (uploaded image or glyph fallback) pops inside its fixed-size slot.
	local visual: GuiObject? = nil
	if slot ~= nil then
		for _, child in slot:GetChildren() do
			if child:IsA("GuiObject") then
				visual = child
				break
			end
		end
	end
	local popUp: Tween? = nil
	local settle: Tween? = nil
	if visual ~= nil then
		-- Centre-anchored so the pop grows from the middle (identical at scale 1).
		visual.AnchorPoint = Vector2.new(0.5, 0.5)
		visual.Position = UDim2.fromScale(0.5, 0.5)
		visual.Size = UDim2.fromScale(1, 1)
		local up = TweenService:Create(
			visual,
			TweenInfo.new(Land.BumpSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(Land.BumpScale, Land.BumpScale) }
		)
		local back = TweenService:Create(
			visual,
			TweenInfo.new(Land.BumpSeconds * 2, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(1, 1) }
		)
		up.Completed:Connect(function(state: Enum.PlaybackState)
			if state == Enum.PlaybackState.Completed then
				back:Play()
			end
		end)
		popUp, settle = up, back
	end
	-- Sparkle glint on the icon's upper-right corner: two crossed rounded bars that grow, turn
	-- and fade (soft warm white, owner R19).
	local glint: Frame? = nil
	local glintTweens: { Tween } = {}
	local bars: { Frame } = {}
	if slot ~= nil then
		local star = Create.new("Frame", {
			Name = "Glint",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.82, 0.2),
			Size = UDim2.fromScale(0.6, 0.6),
			Active = false,
			Visible = false,
			ZIndex = slot.ZIndex + 2,
			Parent = slot,
		}) :: Frame
		for index = 1, 2 do
			local bar = Create.new("Frame", {
				Name = `Bar{index}`,
				BackgroundColor3 = GLINT_COLOR,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = if index == 1 then UDim2.fromScale(0.16, 1) else UDim2.fromScale(1, 0.16),
				Active = false,
				ZIndex = slot.ZIndex + 2,
				Children = { Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }) },
				Parent = star,
			}) :: Frame
			table.insert(bars, bar)
		end
		local info = TweenInfo.new(Land.GlintSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		table.insert(glintTweens, TweenService:Create(star, info, { Size = UDim2.fromScale(0.6, 0.6), Rotation = 90 }))
		for _, bar in bars do
			table.insert(glintTweens, TweenService:Create(bar, info, { BackgroundTransparency = 1 }))
		end
		glintTweens[1].Completed:Connect(function(state: Enum.PlaybackState)
			if state == Enum.PlaybackState.Completed then
				star.Visible = false
			end
		end)
		glint = star
	end
	-- Number flash: jump towards white, ease back to the counter's own colour.
	local baseColor = label.TextColor3
	local flashColor = baseColor:Lerp(Color3.new(1, 1, 1), Land.GlintLighten)
	local flash = TweenService:Create(
		label,
		TweenInfo.new(Land.GlintSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ TextColor3 = baseColor }
	)
	local lastBump, lastGlint = -math.huge, -math.huge
	return {
		target = slot or label,
		land = function(reduced: boolean)
			local now = os.clock()
			local up, back = popUp, settle
			if not reduced and up ~= nil and back ~= nil and now - lastBump >= Land.BumpGap then
				lastBump = now
				back:Cancel()
				up:Play()
			end
			if now - lastGlint < Land.GlintGap then
				return
			end
			lastGlint = now
			label.TextColor3 = flashColor
			flash:Play()
			local star = glint
			if not reduced and star ~= nil then
				star.Size = UDim2.fromScale(0.12, 0.12)
				star.Rotation = 0
				for _, bar in bars do
					bar.BackgroundTransparency = 0.15
				end
				star.Visible = true
				for _, tween in glintTweens do
					tween:Play()
				end
			end
		end,
	}
end

local HudCurrency = {}

-- R82 boost corner, module-level because UI/Screens/BoostChips never sees the Hud's handle (the
-- HUD builds ONE stack per client; the latest build wins).
local cornerAnchor: Frame? = nil
local navLeft: GuiObject? = nil
local navRight: GuiObject? = nil

-- Fires () when the corner anchor was built or the D-pad neighbours beside the stack changed.
HudCurrency.Changed = Signal.new() :: Signal.Signal<>

--[[
	The boost corner anchor: a zero-size frame on the top-right corner of the visible primary
	counter's number (nil until the HUD built). Children ride along as the number's width changes.
	Example: badge.Parent = HudCurrency.corner()
]]
function HudCurrency.corner(): Frame?
	return cornerAnchor
end

--[[
	The HUD buttons beside the stack, as last linked by Hud.relayout (`linkNav`): the left grid's
	top-right button and the first offer. Either may be nil (none shown / not linked yet).
	@return (leftExit, rightExit)
]]
function HudCurrency.navExits(): (GuiObject?, GuiObject?)
	return navLeft, navRight
end

--[[
	Builds the stack under `container` (the HUD's full-screen frame); Hud positions `frame`.
	@return HudCurrency handle
]]
function HudCurrency.new(container: Frame): HudCurrency
	local frame = Create.new("Frame", {
		Name = "Currency",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(600, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = container,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, 0),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
	local gems = StudUI.moneyLabel({ kind = "gems", layoutOrder = 1, parent = frame })
	local cash = StudUI.moneyLabel({ kind = "cash", layoutOrder = 2, parent = frame })
	local rate = StudUI.moneyLabel({ kind = "rate", layoutOrder = 3, parent = frame })
	rate.frame.Visible = false
	local lastRate: number? = nil
	-- Fly-to targets + landing feedback (owner R46).
	local landers: { [string]: Lander } = {
		cash = lander(cash, "Icon_Cash"),
		gems = lander(gems, "Icon_Gems"),
	}
	-- R57 worlds: one stack per non-main world (lazy), and the one shown (nil = Nuke Town).
	local stacks: { [string]: WorldStack } = {}
	local active: WorldStack? = nil
	local Sizes = WorldClientConfig.Hud
	-- R82 boost corner (see the header): starts on Cash's number, moves with setWorld. Zero size,
	-- scale-positioned: never shifts the stack's list layout or the label's automatic width.
	local corner = Create.new("Frame", {
		Name = "BoostCorner",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(0, 0),
		Active = false,
		Selectable = false,
		Parent = cash.label,
	}) :: Frame
	cornerAnchor = corner
	HudCurrency.Changed:Fire()

	--[[
		Builds a world's primary counter + bottom row (its "+X/s" rate) once.
		Primary: a cash-sized money label with the world currency's icon and colour.
	]]
	local function buildStack(def: WorldsConfig.WorldDef): WorldStack
		local currency = def.currency
		local primary = StudUI.moneyLabel({
			kind = "cash",
			icon = false,
			textSize = Sizes.PrimaryTextSize,
			layoutOrder = 2,
			parent = frame,
			format = function(amount: number): string
				return if currency.style == "money" then NumberFormat.money(amount) else NumberFormat.precise(amount)
			end,
		})
		primary.frame.Name = `Money_{currency.key}`
		local icon = StudUI.icon(currency.icon, math.floor(Sizes.PrimaryTextSize * UIStyleConfig.IconFill.Money), 2)
		icon.LayoutOrder = 1
		icon.Parent = primary.frame
		-- The number takes the currency colour BEFORE the lander captures it (flash returns to it).
		primary.label.TextColor3 = currency.color
		-- Bottom row: "+X/s Bones" (R60: no Nuke Town cash in another world).
		local row = Create.new("Frame", {
			Name = `WorldRow_{def.id}`,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(0, Sizes.BottomRowHeight),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = 3,
			Visible = false,
			Parent = frame,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					Padding = UDim.new(0, 0),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame
		local worldRate = StudUI.moneyLabel({
			kind = "rate",
			textSize = Sizes.RateTextSize,
			layoutOrder = 1,
			parent = row,
			format = function(perSecond: number): string
				return WorldClientLogic.formatRate(currency, perSecond)
			end,
		})
		worldRate.label.TextColor3 = currency.color
		worldRate.frame.Visible = false
		primary.frame.Visible = false
		return {
			def = def,
			primary = primary,
			row = row,
			rate = worldRate,
			primaryLander = lander(primary, `Icon_{currency.icon}`),
			lastRate = nil,
		}
	end

	return {
		frame = frame,
		target = function(kind: FlyKind): GuiObject?
			local stack = active
			local counterKind = CurrencyFlyRules.counterFor(kind, if stack ~= nil then stack.def.currency.key else nil)
			if counterKind == "world" then
				return if stack ~= nil then stack.primaryLander.target else nil
			end
			local entry = if counterKind ~= nil then landers[counterKind] else nil
			return if entry ~= nil then entry.target else nil
		end,
		land = function(kind: FlyKind, reduced: boolean)
			local stack = active
			local counterKind = CurrencyFlyRules.counterFor(kind, if stack ~= nil then stack.def.currency.key else nil)
			if counterKind == "world" then
				if stack ~= nil then
					stack.primaryLander.land(reduced)
				end
				return
			end
			local entry = if counterKind ~= nil then landers[counterKind] else nil
			if entry ~= nil then
				entry.land(reduced)
			end
		end,
		setCash = cash.setAmount,
		setGems = gems.setAmount,
		setRate = function(perSecond: number?)
			if perSecond == lastRate then
				return
			end
			lastRate = perSecond
			if perSecond == nil or perSecond ~= perSecond then
				rate.frame.Visible = false
				return
			end
			rate.frame.Visible = active == nil
			rate.setAmount(perSecond, false)
		end,
		setWorld = function(def: WorldsConfig.WorldDef?)
			local nextStack: WorldStack? = nil
			if def ~= nil and def.id ~= WorldsConfig.MAIN then
				nextStack = stacks[def.id]
				if nextStack == nil then
					nextStack = buildStack(def)
					stacks[def.id] = nextStack
				end
			end
			if nextStack == active then
				return
			end
			local previous = active
			if previous ~= nil then
				previous.primary.frame.Visible = false
				previous.row.Visible = false
			end
			active = nextStack
			cash.frame.Visible = nextStack == nil
			rate.frame.Visible = nextStack == nil and lastRate ~= nil and lastRate == lastRate
			if nextStack ~= nil then
				nextStack.primary.frame.Visible = true
				nextStack.row.Visible = true
			end
			-- R82: the boost badge follows the counter that is now primary.
			corner.Parent = if nextStack ~= nil then nextStack.primary.label else cash.label
			HudCurrency.Changed:Fire()
		end,
		setWorldCash = function(amount: number, animate: boolean?)
			local stack = active
			if stack ~= nil and amount == amount then
				stack.primary.setAmount(amount, animate)
			end
		end,
		setWorldRate = function(perSecond: number?)
			local stack = active
			if stack == nil or perSecond == stack.lastRate then
				return
			end
			stack.lastRate = perSecond
			if perSecond == nil or perSecond ~= perSecond then
				stack.rate.frame.Visible = false
				return
			end
			stack.rate.frame.Visible = true
			stack.rate.setAmount(perSecond, false)
		end,
		height = function(): number
			return frame.AbsoluteSize.Y
		end,
		linkNav = function(leftExit: GuiObject?, rightExit: GuiObject?)
			-- Hud.relayout calls this right after the HUD columns re-linked their buttons (which
			-- resets their NextSelection* links), so the badge always re-applies its links: a
			-- handful of property writes per re-layout (event-driven, never per frame).
			navLeft, navRight = leftExit, rightExit
			HudCurrency.Changed:Fire()
		end,
		corner = function(): Frame
			return corner
		end,
	}
end

return table.freeze(HudCurrency)
