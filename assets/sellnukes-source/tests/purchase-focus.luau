--!strict
--[[
	Purchase-focus hygiene regressions (owner R122, spec 2026-11-01-r122-algorithm-pack-design.md
	§2.4: "no accidental purchase prompts"). Run:
		lune run tests/purchase-focus

	Field data: 0 purchases from ~190 Robux prompts in two days, most closed in under 2 s (walk-in
	Lucky Button prompts, console Shop opening on the Starter Pack BUY, one-tap HUD offer chips).
	Proves on the shipped modules:
	  1. Config: PurchaseFocusConfig sane; the DEAL card's BUY is never gamepad A (jump while
	     running) and is bound BELOW every gameplay action (a pad press on the same key always wins);
	     CLOSE is the standard B / close keys at High priority.
	  2. The opening-press guard (UI/PurchaseGuardLogic.allows): the press that opened a surface can
	     never buy (began before / with the open), nothing buys before ArmSeconds, a fresh press
	     after both buys, untracked surfaces are not blocked, NaN / inf clocks never buy;
	     latestPress picks the newest finite press.
	  3. Default selection (pickDefault): never a BUY button, the first usable non-buy candidate
	     wins, nil holes are skipped, nil when only BUY buttons remain.
	  4. Card sizing (UI/Widgets/FeedCardMetrics) for the DEAL and invite cards: at every fit the
	     drawn text is >= the 14 pt floor and buttons >= the 44 pt tap (touch floors of real phone
	     scales), the chosen fit is the largest that fits the area (or MinFit), monotone in room.
	  5. Sources: every client prompt intent in the audited prompt-source screens goes through
	     PurchaseGuard (gate / allow) or the DEAL card; HUD offers never fire a prompt on a chip
	     press; the DEAL card fires its intent only from BUY.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local Enum = (roblox :: any).Enum

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local Config = loader.load("src/shared/Config/PurchaseFocusConfig")
local PlatformConfig = loader.load("src/shared/Config/PlatformConfig")
local InviteConfig = loader.load("src/shared/Config/InviteConfig")
local Logic = loader.load("src/client/UI/PurchaseGuardLogic")
local Metrics = loader.load("src/client/UI/Widgets/FeedCardMetrics")

local checks = 0
local function ok(condition: boolean, label: string)
	checks += 1
	if not condition then
		error(label, 2)
	end
end

-- 1. Config -------------------------------------------------------------------------------------------
do
	local guard = Config.Guard
	ok(table.isfrozen(Config) and table.isfrozen(guard), "frozen")
	ok(
		guard.PressAfterOpen > 0 and guard.PressAfterOpen < 0.15,
		"PressAfterOpen: a frame or few, below any deliberate press"
	)
	ok(guard.ArmSeconds >= guard.PressAfterOpen and guard.ArmSeconds <= 0.5, "ArmSeconds: short, >= PressAfterOpen")
	ok(guard.MaxSurfaces >= 16, "surface memory")
	local keys = Config.DealKeys
	ok(keys.BuyPad ~= Enum.KeyCode.ButtonA, "DEAL BUY is never gamepad A (jump while running)")
	ok(keys.BuyKey ~= Enum.KeyCode.Space, "DEAL BUY is never Space (jump)")
	ok(keys.BuyPriority < PlatformConfig.Priority.Gameplay, "DEAL BUY below every gameplay action")
	ok(keys.ClosePriority >= Enum.ContextActionPriority.High.Value, "DEAL CLOSE at High priority")
	local moment = InviteConfig.Moment
	ok(moment.InvitePad ~= Enum.KeyCode.ButtonA, "invite moment INVITE is never gamepad A")
	ok(moment.InvitePriority < PlatformConfig.Priority.Gameplay, "invite moment INVITE below gameplay")
	local card = Config.DealCard
	ok(card.MinFit > 0 and card.MinFit <= 1, "DEAL MinFit")
	ok(card.ChipAutoClose >= 5 and card.ChipAutoClose <= 30, "chip cards close themselves")
	for _, source in { "lucky", "offer", "attack" } do
		ok(type(card.Colors[source]) == "string", `colour for {source}`)
	end
	ok(card.Pad * 2 + card.CloseWidth + card.BuyWidth + 2 * 40 + card.Gap * 2 <= card.Width, "button row fits the card")
end

-- 2. Opening-press guard --------------------------------------------------------------------------------
do
	local cfg = { PressAfterOpen = 0.08, ArmSeconds = 0.3 }
	-- Untracked surfaces are never blocked.
	ok(Logic.allows(nil, nil, 5, cfg), "untracked surface: allowed")
	-- The press that opened the screen (began before it) can never buy — however late it is released.
	local okOpen, why = Logic.allows(10, 9.95, 12, cfg)
	ok(not okOpen and why == "openingPress", "press began before the open → refused")
	ok(not Logic.allows(10, 10.05, 12, cfg), "press handled in the open's frame → refused")
	-- Nothing buys before the arm time, even a fresh press.
	local okArm, whyArm = Logic.allows(10, 10.2, 10.25, cfg)
	ok(not okArm and whyArm == "arming", "inside ArmSeconds → refused")
	-- A deliberate press after both → buys.
	ok(Logic.allows(10, 10.4, 10.5, cfg), "fresh press after the arm time → allowed")
	ok(Logic.allows(10, nil, 11, cfg), "no press seen (programmatic) after the arm time → allowed")
	-- Hostile clocks.
	ok(not Logic.allows(10, 10.4, 0 / 0, cfg), "NaN now → refused")
	ok(Logic.allows(10, 0 / 0, 11, cfg), "NaN press = unknown press (arm rule only)")
	ok(Logic.allows(0 / 0, 1, 2, cfg), "NaN open = untracked")
	ok(not Logic.allows(10, 10.4, -math.huge, cfg), "-inf now → refused")
	-- Default config.
	ok(Logic.allows(1, 2, 3), "default config works")
	ok(not Logic.allows(1, 0.5, 3), "default config refuses the opening press")
	-- latestPress.
	ok(Logic.latestPress({}) == nil, "no presses")
	ok(Logic.latestPress({ Touch = 3, ButtonA = 5, MouseButton1 = 4 }) == 5, "newest press")
	ok(Logic.latestPress({ Touch = 0 / 0, ButtonA = math.huge, Return = 2 }) == 2, "non-finite presses ignored")
	-- Randomised: a press that began before open + PressAfterOpen never buys; one after (armed) always does.
	local seed = 1122
	local function rand(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	for _ = 1, 4000 do
		local opened = rand() * 100
		local press = opened + (rand() - 0.5) * 2
		local now = math.max(press, opened) + rand()
		local allowed = Logic.allows(opened, press, now, cfg)
		if press < opened + cfg.PressAfterOpen or now - opened < cfg.ArmSeconds then
			ok(not allowed, "opening press / unarmed never buys")
		else
			ok(allowed, "a deliberate armed press buys")
		end
	end
end

-- 3. Default selection -------------------------------------------------------------------------------
do
	type Fake = { name: string, buy: boolean, usable: boolean }
	local function isBuy(item: Fake): boolean
		return item.buy
	end
	local function usable(item: Fake): boolean
		return item.usable
	end
	local starterBuy: Fake = { name = "StarterBuy", buy = true, usable = true }
	local heading: Fake = { name = "Heading", buy = false, usable = true }
	local hidden: Fake = { name = "Hidden", buy = false, usable = false }
	local okay: Fake = { name = "Okay", buy = false, usable = true }
	ok(Logic.pickDefault({ starterBuy, heading }, isBuy, usable) == heading, "never the Starter Pack BUY")
	ok(Logic.pickDefault({ hidden, okay }, isBuy, usable) == okay, "unusable skipped")
	ok(Logic.pickDefault({ nil, starterBuy, nil, okay } :: any, isBuy, usable) == okay, "nil holes skipped")
	ok(Logic.pickDefault({ starterBuy }, isBuy, usable) == nil, "only BUY buttons → nil (no selection)")
	ok(Logic.pickDefault({}, isBuy, usable) == nil, "empty → nil")
	ok(Logic.pickDefault({ okay, heading }, isBuy, usable) == okay, "first preference wins")
end

-- 4. Card sizing --------------------------------------------------------------------------------------
do
	local function specOf(card: any): any
		return {
			width = card.Width,
			artSize = card.ArtSize,
			titleSize = card.TitleSize,
			lineSize = card.LineSize,
			lineRows = card.LineRows,
			buttonHeight = card.ButtonHeight,
			pad = card.Pad,
			gap = card.Gap,
		}
	end
	local cards = {
		{ name = "DEAL", spec = specOf(Config.DealCard), minFit = Config.DealCard.MinFit },
		{ name = "invite", spec = specOf(InviteConfig.Moment), minFit = InviteConfig.Moment.MinFit },
	}
	-- Point scales of real devices (points per design px): phones ~0.5-0.7, tablets ~0.7-0.9.
	for _, card in cards do
		for _, pointScale in { 0.45, 0.55, 0.62, 0.7, 0.85, 1 } do
			local floors = { text = math.ceil(14 / pointScale - 1e-6), tap = math.ceil(44 / pointScale - 1e-6) }
			for _, area in { { 300, 200 }, { 460, 260 }, { 560, 400 }, { 900, 900 }, { 120, 90 } } do
				local m = Metrics.fit(card.spec, area[1], area[2], card.minFit, floors)
				local label = `{card.name} @ {pointScale} in {area[1]}x{area[2]}`
				ok(m.fit >= card.minFit - 1e-9 and m.fit <= 1, `{label}: fit within [MinFit, 1]`)
				-- Floors hold on screen (design px x fit).
				ok(m.lineSize * m.fit >= floors.text - 1e-6, `{label}: body text >= 14 pt`)
				ok(m.titleSize * m.fit >= floors.text - 1e-6, `{label}: title >= 14 pt`)
				ok(m.buttonHeight * m.fit >= floors.tap - 1e-6, `{label}: buttons >= 44 pt`)
				-- It fits whenever MinFit is not the binding limit.
				if m.fit > card.minFit + 1e-6 then
					ok(m.width * m.fit <= area[1] + 1e-6 and m.height * m.fit <= area[2] + 1e-6, `{label}: fits`)
				end
				-- Inner layout is consistent.
				ok(m.buttonY + m.buttonHeight + m.pad == m.height, `{label}: button row at the bottom`)
				ok(m.textX > m.artSize, `{label}: text right of the art`)
			end
		end
		-- No floors (desktop / console): full size when there is room.
		local full = Metrics.fit(card.spec, 2000, 2000, card.minFit, { text = 0, tap = 0 })
		ok(full.fit == 1 and full.lineSize == card.spec.lineSize, `{card.name}: desktop draws at full size`)
		-- Monotone: more room never shrinks the fit.
		local last = 0
		for room = 60, 600, 20 do
			local m = Metrics.fit(card.spec, 2000, room, card.minFit, { text = 23, tap = 71 })
			ok(m.fit >= last - 1e-9, `{card.name}: fit grows with room`)
			last = m.fit
		end
	end
	-- Hostile fit values never error and stay sane.
	local m = Metrics.compute(specOf(Config.DealCard), 0 / 0, { text = 10, tap = 10 })
	ok(m.fit == 1, "NaN fit → 1")
end

-- 5. Sources ------------------------------------------------------------------------------------------
do
	-- HUD offers: a chip press opens the DEAL card; no prompt intent is fired from the HUD column.
	local offers = fs.readFile("src/client/UI/Hud/HudOffers.luau")
	ok(string.find(offers, '"PromptPass"', 1, true) == nil, "HudOffers never fires PromptPass")
	ok(string.find(offers, '"PromptProduct"', 1, true) == nil, "HudOffers never fires PromptProduct")
	ok(string.find(offers, "toggleCard(row", 1, true) ~= nil, "HudOffers opens the DEAL card")
	-- The DEAL card fires its intent only from buy() and BUY is gated.
	local deal = fs.readFile("src/client/UI/Screens/DealCard/init.luau")
	local _, fires = string.gsub(deal, "FireServer%(", "")
	ok(fires == 1, "DealCard fires exactly one intent site")
	ok(string.find(deal, "PurchaseGuard.allow(NAME)", 1, true) ~= nil, "DealCard BUY tap is guarded")
	ok(string.find(deal, "PurchaseGuard.allow(NAME, os.clock())", 1, true) ~= nil, "DealCard BUY key is guarded")
	-- Every audited prompt-source screen routes its prompt intents through PurchaseGuard.
	local screens = {
		"src/client/UI/Screens/Shop/init.luau",
		"src/client/UI/Screens/LuckyWheel/init.luau",
		"src/client/UI/Screens/Teleport/init.luau",
		"src/client/UI/Screens/EggHatch/EggHatchScreen.luau",
		"src/client/UI/Screens/EventShop/init.luau",
		"src/client/UI/Screens/CrateShop/CrateShopScreen.luau",
		"src/client/UI/Screens/NukePass/init.luau",
		"src/client/UI/Screens/WelcomeBack/init.luau",
		"src/client/UI/Screens/AttackTarget/AttackScreen.luau",
		"src/client/UI/Screens/Defense/DefenseScreen.luau",
	}
	for _, path in screens do
		local source = fs.readFile(path)
		local guarded = string.find(source, "PurchaseGuard.gate(", 1, true) ~= nil
			or string.find(source, "PurchaseGuard.allow(", 1, true) ~= nil
		ok(guarded, `{path}: prompt intents go through PurchaseGuard`)
		ok(string.find(source, "PurchaseGuard", 1, true) ~= nil, `{path}: requires PurchaseGuard`)
	end
	-- The Shop never selects a BUY button on open: its default goes through safeDefault / a landing.
	local shop = fs.readFile("src/client/UI/Screens/Shop/init.luau")
	ok(string.find(shop, "PurchaseGuard.landing(", 1, true) ~= nil, "Shop has non-buy landings")
	ok(string.find(shop, "PurchaseGuard.safeDefault(", 1, true) ~= nil, "Shop default goes through safeDefault")
end

print(`[purchase-focus] {checks} checks passed`)
