--!strict
--[[
	GiftsConfig — the two side pieces of the owner R89 Early Gift Ladder wave (spec
	2026-10-31-r89-competitive-wave-design §3): the POCKET ROCKET daily impulse product and the
	one-time experience FAVORITE prompt, plus the profile block both keep (profile.gifts).

	Pocket Rocket (developer product MonetizationConfig.Products.PocketRocket, kind "PocketRocket"):
		- grants `incomeSeconds` of the buyer's OWN automated income (at least `cashFloor`) through
		  the shared reward path (RetentionConfig.Reward cashSeconds + cashFloor →
		  RewardLogic.cashFor), so the HUD's "+$42.4K" preview (RewardPreview.cash) is the grant;
		- once per UTC day: the prompt is refused once profile.gifts.rocketDay == today and the HUD
		  offer hides; a receipt that still arrives (bought just before midnight, a retry) is ALWAYS
		  granted — Robux are never taken for nothing;
		- priced so its value per Robux never beats any Cash pack (MonetizationConfig.validate +
		  tests/gift-ladder.luau): 300 s for 15 R$ = 20 s/R$ vs Stack of Cash 600 s / 23 R$ =
		  26.1 s/R$ (the worst pack); floor 500 / 15 = 33.3 $/R$ vs 1,000 / 23 = 43.5 $/R$.

	Favorite prompt (AvatarEditorService:PromptSetFavorite(game.PlaceId, Asset, true), client):
		- offered at a happy moment the SERVER detects: claiming the 10-minute gift
		  (PlaytimeConfig gift.favoriteMoment) or a rebirth (ProgressEvents "rebirth");
		- NEVER rewarded (Roblox rules) — nothing in the game reads the answer except this gate;
		- never shown again once ANSWERED (Success / PermissionDenied → favorite = Answered);
		  a prompt that was shown but never answered (left mid-prompt, Failed) may come back at
		  the next happy moment, at most MaxAsks times in total;
		- the client waits for a calm moment (Platform/JoinFlow.isQuiet: no menu, no plot reveal /
		  focus cinematic, no purchase prompt, not in the guided tutorial) AND a finished tutorial,
		  at most ClientMaxWaitSeconds, else it drops the moment (nothing counted).

	State (profile.gifts, additive v2 block: missing in older saves → newState()):
		rocketDay     UTC day of the last Pocket Rocket grant (-1 = never)
		favorite      FavoriteState: 0 None (never shown), 1 Shown (not answered), 2 Answered
		favoriteAsks  how many times the prompt was SHOWN (client "shown" report, server-gated)

	Connects to: Shared/Config/{MonetizationConfig (the product row), RetentionConfig (Reward)},
	Server/Retention/{GiftsLogic (rules), PocketRocket (receipts + prompt refusal),
	FavoritePrompt (moments + reports)}, Server/Economy/ProfileLogic (newState / reconcileState /
	toWire), UI/Hud/HudOffers (the HUD offer), UI/Screens/TimeRewards/FavoriteClient (the prompt),
	tests/gift-ladder.luau, docs/gifts.md.

	Example:
		local reward = GiftsConfig.rocketReward()           --> { cashSeconds = 300, cashFloor = 500 }
		GiftsConfig.rocketBoughtToday(profile.gifts, today) --> false (offer visible)
]]

local MonetizationConfig = require(script.Parent.MonetizationConfig)
local RetentionConfig = require(script.Parent.RetentionConfig)

-- profile.gifts (see the header).
export type State = { rocketDay: number, favorite: number, favoriteAsks: number }

-- The client's report about the favorite prompt (FavoriteReport remote, allowlisted).
export type FavoriteReport = "shown" | "Success" | "PermissionDenied" | "Failed"

-- A happy moment the server announces (FavoriteMoment remote payload `moment`).
export type FavoriteMoment = "gift" | "rebirth"

local GiftsConfig = {}

--[[
	Kill switches (lead, publish 2026-10-31: both OFF until the lead's Studio pass). OFF = no HUD
	offer, the prompt is refused (PocketRocket.refusal), and no favorite moment is announced or
	shown. The receipt handler stays registered either way, so a receipt can never go unpaid.
]]
GiftsConfig.RocketEnabled = true
GiftsConfig.FavoriteEnabled = true

-- Pocket Rocket -----------------------------------------------------------------------------------

GiftsConfig.Rocket = table.freeze({
	-- MonetizationConfig product key (kind "PocketRocket"; incomeSeconds / cashFloor live there).
	Product = "PocketRocket",
	-- HUD offer row key (UI/Hud/HudOffers; the starburst's Instance name is Offer_<key>).
	OfferKey = "Rocket",
	-- HUD picture: the IconAssets key (falls back to the cartoon rocket while it is not uploaded).
	Icon = "PocketRocket",
	FallbackIcon = "MoonRocket",
	-- HUD label when the live amount is unknown (no profile yet).
	Label = "Rocket",
})

--[[
	The Pocket Rocket product definition (nil only if the catalogue lost the row — tests catch it).
	Example: GiftsConfig.rocketProduct().price --> 15
]]
function GiftsConfig.rocketProduct(): MonetizationConfig.ProductDef?
	return MonetizationConfig.getProduct(GiftsConfig.Rocket.Product)
end

--[[
	The Pocket Rocket grant in the shared reward shape (RewardLogic.cashFor / RewardPreview.cash).
	Built from the product row so the price table and the grant can never drift apart.
	Example: GiftsConfig.rocketReward() --> { cashSeconds = 300, cashFloor = 500 }
]]
function GiftsConfig.rocketReward(): RetentionConfig.Reward
	local product = GiftsConfig.rocketProduct()
	if product == nil then
		return { cashFloor = 0 }
	end
	return { cashSeconds = product.incomeSeconds, cashFloor = product.cashFloor }
end

--[[
	True when the player already got today's Pocket Rocket (offer hidden, prompt refused).
	Accepts the server state or the client snapshot (junk reads as "not bought").
	Example: GiftsConfig.rocketBoughtToday({ rocketDay = 20_757 }, 20_757) --> true
]]
function GiftsConfig.rocketBoughtToday(state: unknown, today: number): boolean
	if type(state) ~= "table" then
		return false
	end
	local day = (state :: any).rocketDay
	return type(day) == "number" and day == today
end

--[[
	Seconds of income per Robux a "Cash"-style grant gives (incomeSeconds / price), and the floor
	per Robux (cashFloor / price) — the value metric of the Pocket Rocket price rule.
	Example: GiftsConfig.valuePerRobux(MonetizationConfig.getProduct("CashSmall")) --> 26.09, 43.48
]]
function GiftsConfig.valuePerRobux(def: MonetizationConfig.ProductDef): (number, number)
	local price = def.price
	if type(price) ~= "number" or price <= 0 then
		return math.huge, math.huge
	end
	return (def.incomeSeconds or 0) / price, (def.cashFloor or 0) / price
end

--[[
	The price rule (spec §3): the Pocket Rocket's income seconds per Robux AND its floor per Robux
	are both <= those of EVERY "Cash" pack, so it never undercuts a pack. Returns the offending
	pack keys (empty = OK). Used by MonetizationConfig.validate-style checks and the Lune test.
	Example: GiftsConfig.rocketBeatsCashPacks() --> {}
]]
function GiftsConfig.rocketBeatsCashPacks(): { string }
	local rocket = GiftsConfig.rocketProduct()
	local offenders: { string } = {}
	if rocket == nil then
		table.insert(offenders, "PocketRocket missing")
		return offenders
	end
	local rocketSeconds, rocketFloor = GiftsConfig.valuePerRobux(rocket)
	for _, key in MonetizationConfig.ProductOrder do
		local def = MonetizationConfig.Products[key]
		if def.kind == "Cash" then
			local packSeconds, packFloor = GiftsConfig.valuePerRobux(def)
			if rocketSeconds > packSeconds or rocketFloor > packFloor then
				table.insert(offenders, key)
			end
		end
	end
	return offenders
end

-- Favorite prompt ---------------------------------------------------------------------------------

GiftsConfig.FavoriteState = table.freeze({ None = 0, Shown = 1, Answered = 2 })

GiftsConfig.Favorite = table.freeze({
	-- The prompt is SHOWN at most this many times ever (only unanswered prompts come back).
	MaxAsks = 2,
	-- Moments the server may announce (analytics "favorite:moment:<m>").
	Moments = table.freeze({ "gift", "rebirth" }) :: { FavoriteMoment },
	-- Client reports the server accepts ("shown" first, then the AvatarPromptResult name).
	Reports = table.freeze({ "shown", "Success", "PermissionDenied", "Failed" }) :: { FavoriteReport },
	-- Results that count as ANSWERED (never prompt again).
	Answered = table.freeze({ Success = true, PermissionDenied = true }) :: { [string]: boolean },
	-- Client: wait at most this long for a calm moment after a happy moment, polling this often.
	ClientMaxWaitSeconds = 600,
	ClientCheckSeconds = 1,
	-- Server: a "shown" report is accepted only this long after the moment was announced.
	ShownWindowSeconds = 900,
	-- Server: the answer may arrive this long after "shown" (the native dialog can stay open).
	AnswerWindowSeconds = 600,
})

--[[
	True when the server may announce a favorite moment for this state (not answered, asks left).
	Example: GiftsConfig.mayAskFavorite({ favorite = 0, favoriteAsks = 0, rocketDay = -1 }) --> true
]]
function GiftsConfig.mayAskFavorite(state: State): boolean
	return state.favorite ~= GiftsConfig.FavoriteState.Answered and state.favoriteAsks < GiftsConfig.Favorite.MaxAsks
end

-- Profile block -----------------------------------------------------------------------------------

-- A whole number in [lo, hi], else `default` (NaN / inf / fractions / non-numbers refused).
local function whole(value: unknown, lo: number, hi: number, default: number): number
	if type(value) ~= "number" or value ~= value or value % 1 ~= 0 or value < lo or value > hi then
		return default
	end
	return value
end

--[[ A fresh profile.gifts block (nothing bought, never prompted). ]]
function GiftsConfig.newState(): State
	return { rocketDay = -1, favorite = GiftsConfig.FavoriteState.None, favoriteAsks = 0 }
end

--[[
	profile.gifts from untrusted saved data (missing in pre-R89 saves → newState()). Days are
	whole UTC day numbers; the favorite state is 0..2; asks are capped at MaxAsks.
	Example: GiftsConfig.reconcileState({ rocketDay = 1.5, favorite = 9 }) --> { -1, 0, 0 }
]]
function GiftsConfig.reconcileState(raw: unknown): State
	local state = GiftsConfig.newState()
	if type(raw) ~= "table" or getmetatable(raw :: any) ~= nil then
		return state
	end
	local source = raw :: { [string]: unknown }
	state.rocketDay = whole(source.rocketDay, -1, 10_000_000, -1)
	state.favorite = whole(source.favorite, 0, GiftsConfig.FavoriteState.Answered, 0)
	state.favoriteAsks = whole(source.favoriteAsks, 0, GiftsConfig.Favorite.MaxAsks, 0)
	return state
end

--[[ The owner's snapshot copy of profile.gifts (a fresh table; asks are private bookkeeping). ]]
function GiftsConfig.toWire(state: State): { rocketDay: number, favorite: number }
	return { rocketDay = state.rocketDay, favorite = state.favorite }
end

return table.freeze(GiftsConfig)
