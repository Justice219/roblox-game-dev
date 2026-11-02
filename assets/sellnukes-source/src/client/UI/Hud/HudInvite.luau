--!strict
--[[
	HudInvite — the HUD's INVITE button (owner R122, spec §2.4: "co-play"; tunables
	InviteConfig.Hud; runtime Client/Social/InviteClient).

	Why: Roblox ranks intentional co-play days; 252 of 266 sessions had no friend in the server and
	the Friends window (inside the Rewards hub) was opened once in two days. So inviting is one
	press away on the HUD itself.

	Look: a small blue stud button ([handshake] INVITE) in the top-right corner, right under the
	Roblox top bar, left of the admin chip (Widgets/HudPlacement.inviteRect; the offer column starts
	below it), with a tilted yellow "+10%" sticker on its top-left corner = the LIVE Friend Boost
	percent per friend (InviteClient.badgeText: admin FriendBoostPercent changes it at once; the
	sticker hides while the boost is switched off) and the bound key / button glyph on its left.
	It pops when the sticker first shows or its number changes (Reduce Motion: no pop).

	Press: opens Roblox's invite prompt directly (InviteClient.invite("hud") → the R78 flow,
	Social/SocialClient.invite; counts friends:hud:tap). Hidden while invites are unavailable
	(SocialService:CanSendGameInviteAsync false / unknown) — never a dead button. It lives in the
	HUD's MenuLayer, so it fades out with the side columns while a menu is open (owner R79).

	Console + mobile (owner R11): every input — tap / click, keyboard P, gamepad L3 (bound only
	while it shows and no menu is open; the glyph follows the device and hides on touch), and the
	D-pad cursor (Hud links Down → the first offer, Right → the admin chip). Touch devices grow it
	to the 44 pt tap; phones use the narrower PhoneWidth with labels >= 14 pt. Placement is
	Lune-tested with the rest of the HUD (tests/hud-cluster.luau: on screen, under the top bar, no
	overlap with the currency stack / offers / admin chip / flyout, >= 44 pt, clear of the thumbs).

	Analytics: friends:hud:shown (first time it shows this session), friends:hud:tap.

	Performance: built once; rebuilt only on a size change (device / rotation); the sticker
	re-renders on InviteClient.Changed (availability / Friend Boost settings), never per frame.

	Connects to: Kit/StudUI, Widgets/{HudPlacement, InputGlyph, OfferFx, StudWindow}, UI/{Create,
	ScreenManager}, Client/Social/InviteClient, Shared/Config/{InviteConfig, TouchUIConfig},
	Shared/Util/TouchLayout, UI/Hud/Hud (owner: places it, links its D-pad exits).

	Example (Hud):
		local invite = HudInvite.new(layer)
		invite.onChanged(relayout)
		local layout = HudPlacement.compute({ ..., invite = if invite.visible() then invite.size(touch, scale, phone) else nil })
		invite.place(layout.invite)
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Create = require(script.Parent.Parent.Create)
local HudPlacement = require(script.Parent.Parent.Widgets.HudPlacement)
local InputGlyph = require(script.Parent.Parent.Widgets.InputGlyph)
local InviteClient = require(script.Parent.Parent.Parent.Social.InviteClient)
local InviteConfig = require(ReplicatedStorage.Shared.Config.InviteConfig)
local OfferFx = require(script.Parent.Parent.Widgets.OfferFx)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)

export type HudInvite = {
	-- The button's design size on this device (touch: >= the 44 pt tap; phones: PhoneWidth).
	size: (touch: boolean, pointScale: number, phone: boolean) -> Vector2,
	-- Places (rebuilding on a size change) or, with nil, hides the button.
	place: (rect: HudPlacement.Rect?) -> (),
	-- True while invites are available (the HUD reserves its rect only then).
	visible: () -> boolean,
	-- The selectable button (nil while hidden).
	button: () -> GuiObject?,
	-- Called when the visibility changes (Hud re-lays out).
	onChanged: (callback: () -> ()) -> (),
}

local Config = InviteConfig.Hud
local ACTION = "SellNukesHudInvite"

local HudInvite = {}

--[[
	Builds the INVITE holder under the HUD's MenuLayer (hidden until placed while available) and
	starts InviteClient (availability check + the invite moment watcher).
	@param parent the HUD's MenuLayer frame
	@return HudInvite handle
]]
function HudInvite.new(parent: Frame): HudInvite
	InviteClient.start()
	local holder = Create.new("Frame", {
		Name = "InviteButton",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 0),
		Visible = false,
		Active = false,
		ZIndex = 4,
		Parent = parent,
	}) :: Frame
	local current: StudUI.Button? = nil
	local builtSize: Vector2? = nil
	local builtText = 0
	local changed: (() -> ())? = nil
	local shown = InviteClient.available()
	local bound = false
	local lastBadge: string? = nil

	-- The "+10%" sticker: a tilted yellow stud chip over the top-left corner (display only).
	local badge = Create.new("Frame", {
		Name = "BoostSticker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Rotation = Config.BadgeTilt,
		Active = false,
		Visible = false,
		ZIndex = 8,
		Parent = holder,
	}) :: Frame
	StudWindow.surface(badge, Config.BadgeColor :: any, { edge = 3, corner = 10, highlight = true, zIndex = 8 })
	local badgeScale = Create.new("UIScale", { Name = "Pop", Scale = 1, Parent = badge }) :: UIScale
	local badgeLabel = StudUI.text({
		name = "Percent",
		text = "",
		textSize = Config.BadgeTextSize,
		font = "shout",
		scaled = true,
		size = UDim2.fromScale(0.9, 0.86),
		position = UDim2.fromScale(0.05, 0.07),
		zIndex = 9,
		parent = badge,
	})

	-- The key / button glyph on the left edge (keyboard P / gamepad L3; hidden on touch).
	local glyph = InputGlyph.dynamic(Config.Key, Config.Pad, Config.GlyphHeight)
	glyph.AnchorPoint = Vector2.new(1, 0.5)
	glyph.ZIndex = 8
	glyph.Parent = holder

	-- The press: Roblox's invite prompt (no-op while a prompt is already open).
	local function press()
		InviteClient.invite("hud")
	end

	-- (Re)builds the stud button at `size` (rare: a size change).
	local function build(size: Vector2, textSize: number)
		local old = current
		if old ~= nil then
			old.Destroy()
		end
		current = StudUI.button({
			name = "Hud_Invite",
			text = Config.Label,
			icon = if StudUI.hasIcon(Config.Icon) then Config.Icon else Config.IconFallback,
			color = Config.Color :: any,
			textSize = textSize,
			size = UDim2.fromOffset(size.X, size.Y),
			parent = holder,
			onActivated = press,
		})
		builtSize = size
		builtText = textSize
	end

	-- Sizes + places the sticker and glyph for the button height `h` (design px).
	local function decorate(h: number)
		local scale = h / Config.Height
		local floor = if ScreenManager.touchTargets()
			then TouchLayout.pointsToDesign(Config.BadgePoints, ScreenManager.pointScale())
			else 0
		local textSize = math.max(math.floor(Config.BadgeTextSize * scale), floor)
		local grow = textSize / Config.BadgeTextSize
		local w, bh = math.floor(Config.BadgeWidth * grow), math.floor(Config.BadgeHeight * grow)
		badge.Size = UDim2.fromOffset(w, bh)
		-- Centre over the corner, pulled out by the overhang (it never reaches the admin chip on
		-- the right: the sticker sits on the LEFT corner).
		badge.Position = UDim2.fromOffset(w / 2 - Config.BadgeOverhang.X, bh / 2 - Config.BadgeOverhang.Y)
		badgeLabel.TextSize = textSize
		glyph.Position = UDim2.new(0, -6, 0.5, math.floor(bh / 4))
	end

	-- Sticker text from the live Friend Boost settings; pops when it first shows / changes.
	local function renderBadge()
		local text = InviteClient.badgeText()
		badge.Visible = text ~= nil
		if text ~= nil then
			badgeLabel.Text = text
			if text ~= lastBadge and holder.Visible and not OfferFx.reducedMotion() then
				badgeScale.Scale = Config.PopScale
				TweenService:Create(
					badgeScale,
					TweenInfo.new(Config.PopSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
					{ Scale = 1 }
				):Play()
			end
		end
		lastBadge = text
	end

	-- Binds / unbinds P / L3 with the button's visibility (never while a menu is open).
	local function setBound(on: boolean)
		if bound == on then
			return
		end
		bound = on
		if not on then
			ContextActionService:UnbindAction(ACTION)
			return
		end
		ContextActionService:BindAction(
			ACTION,
			function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
				if state ~= Enum.UserInputState.Begin or ScreenManager.anyModalOpen() or not holder.Visible then
					return Enum.ContextActionResult.Pass
				end
				press()
				return Enum.ContextActionResult.Sink
			end,
			false,
			Config.Key,
			Config.Pad
		)
	end

	-- Availability / sticker changes: re-render, and re-lay out the HUD when visibility flips.
	InviteClient.Changed:Connect(function()
		local available = InviteClient.available()
		renderBadge()
		if available ~= shown then
			shown = available
			if not available then
				holder.Visible = false
				setBound(false)
			end
			local callback = changed
			if callback ~= nil then
				callback()
			end
		end
	end)

	return {
		size = function(touch: boolean, pointScale: number, phone: boolean): Vector2
			local minTap = if touch
				then TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, math.max(pointScale, 0.01))
				else 0
			local h = math.ceil(math.max(Config.Height, minTap))
			local w = math.ceil((if phone then Config.PhoneWidth else Config.Width) * h / Config.Height)
			return Vector2.new(w, h)
		end,
		place = function(rect: HudPlacement.Rect?)
			if rect == nil or not shown then
				holder.Visible = false
				setBound(false)
				return
			end
			local size = Vector2.new(rect.w, rect.h)
			-- Label size: the design size scaled with the height; phones never under 14 pt.
			local floor = if ScreenManager.touchTargets()
				then TouchLayout.pointsToDesign(14, ScreenManager.pointScale())
				else 0
			local textSize = math.max(math.floor(Config.TextSize * rect.h / Config.Height), floor)
			if current == nil or builtSize ~= size or builtText ~= textSize then
				build(size, textSize)
			end
			holder.Position = UDim2.fromOffset(rect.x, rect.y)
			holder.Size = UDim2.fromOffset(rect.w, rect.h)
			decorate(rect.h)
			local wasVisible = holder.Visible
			holder.Visible = true
			renderBadge()
			setBound(true)
			if not wasVisible then
				InviteClient.report("hud:shown")
			end
		end,
		visible = function(): boolean
			return shown
		end,
		button = function(): GuiObject?
			local button = current
			return if button ~= nil and holder.Visible then button.instance else nil
		end,
		onChanged = function(callback: () -> ())
			changed = callback
		end,
	}
end

return table.freeze(HudInvite)
