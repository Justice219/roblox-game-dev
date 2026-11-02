--!strict
--[[
	Codes — the "Codes" window (design spec §7; reference docs/reference/ui-style/05-codes.png):
	blue header with the Codes icon, the big "Follow SellNukes on Roblox for exclusive codes!"
	line ("Roblox" in red), a dark "Code Here" text box next to a green Redeem button, and a
	status line that shows the server's answer (green when redeemed, red otherwise).

	Flow:
		Redeem (or Enter) → RedeemCode(text) → CodeResult { ok, text, codeId? } → status line.
		Redeem is disabled for REDEEM_COOLDOWN s after a press (the server also rate-limits and
		answers "Slow down!"). The status line is cleared every time the window opens; the code
		box is cleared after a successful redeem.

	Console / mobile (owner R11, docs/platform.md §7): the gamepad cursor starts on the code box;
	A on it opens the on-screen keyboard (CaptureFocus when the engine did not already focus
	it); confirming the keyboard (FocusLost with Enter) redeems, and leaving the box returns the
	cursor to Redeem. Box <-> Redeem are linked across, up goes to the header X. B / Back closes
	(ScreenManager never closes while the box is focused). The content is top-aligned so the
	controls stay above Roblox's thumbstick / jump corners on short phones; taps ≥ 44 pt and
	text ≥ 14 pt after the phone scale.

	Security: the client only sends the typed text (trimmed, capped). Normalising, lookup,
	expiry, one-claim-per-player and the reward are all server-side (CodesService / CodeLogic);
	the status text is the server's own message, shown as plain text.

	Connects to: Kit/StudUI (modalScreen, textBox, button, text), UI/{Create, ScreenManager},
	Platform/GamepadNav,
	Client/Analytics/ClientAnalytics, Shared/Config/{CodesConfig, UIStyleConfig},
	Shared/Net/Remotes (RedeemCode, CodeResult).

	Example: ScreenManager.open("Codes")
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local CodesConfig = require(ReplicatedStorage.Shared.Config.CodesConfig)
local Create = require(script.Parent.Parent.Create)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local NAME = "Codes"
local ANALYTICS_SCREEN = "Codes"
-- Seconds Redeem stays disabled after a press.
local REDEEM_COOLDOWN = 1
-- Longest server text shown (defensive cap).
local MAX_SERVER_TEXT = 200
-- Word highlighted in red inside CodesConfig.FollowText (reference: "on Roblox").
local HIGHLIGHT_WORD = "Roblox"

local Neutral = UIStyleConfig.Neutral
local OK_COLOR = UIStyleConfig.Colors.green.accent
local ERROR_COLOR = Neutral.Danger

-- Escapes the five RichText special characters so config text can never inject markup.
local function escapeRich(text: string): string
	return (
		string.gsub(text, "[&<>\"']", {
			["&"] = "&amp;",
			["<"] = "&lt;",
			[">"] = "&gt;",
			['"'] = "&quot;",
			["'"] = "&apos;",
		})
	)
end

-- FollowText as RichText with HIGHLIGHT_WORD in red (plain text when the word is absent).
local function followRichText(): string
	local escaped = escapeRich(CodesConfig.FollowText)
	local colored = `<font color="#{ERROR_COLOR:ToHex()}">{HIGHLIGHT_WORD}</font>`
	return (string.gsub(escaped, HIGHLIGHT_WORD, colored))
end

-- Trims surrounding whitespace.
local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or ""
end

return StudUI.modalScreen({
	name = NAME,
	title = "Codes",
	color = "blue",
	icon = "Codes",
	size = Vector2.new(900, 500),
	--[[
		Fills the window: follow line, code box + Redeem row, status line.
		@param window the StudUI window (content goes in window.body)
		@return ScreenHandle (status cleared on open; gamepad starts on the code box)
	]]
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		local body = window.body
		Create.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			-- Top-aligned: keeps the box / Redeem row out of the bottom touch corners.
			VerticalAlignment = Enum.VerticalAlignment.Top,
			Padding = UDim.new(0, 18),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = body,
		})

		StudUI.text({
			name = "Follow",
			text = followRichText(),
			rich = true,
			textSize = 52,
			scaled = true, -- a longer FollowText shrinks instead of overflowing (52 px cap)
			size = UDim2.new(1, -24, 0, 132),
			layoutOrder = 1,
			parent = body,
		})

		-- Code box + Redeem side by side (the row is a plain layout holder).
		local row = Create.new("Frame", {
			Name = "RedeemRow",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 104),
			LayoutOrder = 2,
			Parent = body,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, 18),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame

		local status = StudUI.text({
			name = "Status",
			text = "",
			textSize = 32,
			wrap = true,
			size = UDim2.new(1, -24, 0, 44),
			layoutOrder = 3,
			parent = body,
		})

		-- Shows `text` in the status line (green ok / red otherwise; dim for neutral hints).
		local function setStatus(text: string, color: Color3)
			status.Text = text
			status.TextColor3 = color
		end

		local cooldownUntil = 0
		local redeemButton: StudUI.Button
		local box: StudUI.TextBoxHandle

		-- Sends the typed code (one press per REDEEM_COOLDOWN s).
		local function redeem()
			local now = os.clock()
			if now < cooldownUntil then
				return
			end
			local code = trim(box.text())
			if code == "" then
				setStatus("Type a code first!", ERROR_COLOR)
				GamepadNav.select(box.instance)
				return
			end
			cooldownUntil = now + REDEEM_COOLDOWN
			redeemButton.setState("disabled")
			task.delay(REDEEM_COOLDOWN, function()
				if os.clock() >= cooldownUntil then
					redeemButton.setState("normal")
				end
			end)
			setStatus("Checking...", Neutral.TextDim)
			-- Intent only; the box already caps typing, the cap here is a second guard.
			Remotes.event("RedeemCode"):FireServer(string.sub(code, 1, CodesConfig.MaxLength * 4))
			-- Gamepad: back onto Redeem (deferred: the engine settles the cursor after a focus
			-- release first). No-op for touch / mouse.
			task.defer(GamepadNav.select, redeemButton.instance)
		end

		box = StudUI.textBox({
			placeholder = "Code Here",
			maxLength = CodesConfig.MaxLength,
			size = UDim2.fromOffset(460, 96),
			layoutOrder = 1,
			parent = row,
			onSubmit = function()
				redeem()
			end,
		})
		redeemButton = StudUI.button({
			text = "Redeem",
			color = "green",
			textSize = 50,
			size = UDim2.fromOffset(240, 90),
			name = "Redeem",
			layoutOrder = 2,
			parent = row,
			onActivated = redeem,
		})

		-- Gamepad: A on the selected box opens the keyboard. The engine usually focuses a
		-- selected TextBox itself; the deferred check covers platforms where it does not.
		local input = box.instance
		input.InputBegan:Connect(function(event: InputObject)
			if event.KeyCode ~= Enum.KeyCode.ButtonA or GuiService.SelectedObject ~= input then
				return
			end
			task.defer(function()
				if not input:IsFocused() and GuiService.SelectedObject == input and ScreenManager.isOpen(NAME) then
					input:CaptureFocus()
				end
			end)
		end)
		-- Leaving the keyboard without Enter: the cursor goes to Redeem (Enter redeems via onSubmit).
		input.FocusLost:Connect(function(enterPressed: boolean)
			if not enterPressed and ScreenManager.isOpen(NAME) then
				task.defer(GamepadNav.select, redeemButton.instance)
			end
		end)
		-- Box <-> Redeem across; up from either reaches the header X (and back down to the box).
		GamepadNav.linkList({ input, redeemButton.instance }, false, { up = window.closeButton })
		local selectDefault = GamepadNav.defaultSelection(body, input)

		-- Server answers (connected off the build thread: Remotes.event may wait for replication).
		task.spawn(function()
			Remotes.event("CodeResult").OnClientEvent:Connect(function(raw: unknown)
				if type(raw) ~= "table" then
					return
				end
				local result = raw :: { [string]: unknown }
				local text = result.text
				if type(text) ~= "string" or #text == 0 or #text > MAX_SERVER_TEXT then
					return
				end
				local ok = result.ok == true
				setStatus(text, if ok then OK_COLOR else ERROR_COLOR)
				if ok then
					box.clear()
				end
			end)
		end)

		return {
			onOpen = function(args: any?)
				setStatus("", Neutral.TextDim)
				local source = if type(args) == "table" and type(args.source) == "string" then args.source else "hud"
				ClientAnalytics.screenOpened(ANALYTICS_SCREEN, source)
			end,
			defaultSelection = selectDefault,
		}
	end,
})
