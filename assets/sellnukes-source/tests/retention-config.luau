--!strict
--[[
	Retention + shop configuration integrity (B7). Run:
		lune run tests/retention-config

	Proves every shipped number / reference is consistent:
	  1. Every reward definition (7 daily days, 7 time gifts, 8 wheel slices, every code, the group,
	     notify, Starter and Secret Pack) is valid (RetentionConfig.isRewardValid), its boosts name
	     a BoostConfig boost and its icons are IconAssets keys.
	  2. Daily: exactly 7 cards indexed 1..7, only Day 7 is big. Time: 7 gifts at the spec's
	     5 / 15 / 30 / 60 / 90 / 120 / 180 minutes, only the last is big.
	  3. Wheel: 8 slices, unique ids, weights sum to 100, MaxFree 3 every 20 min.
	  4. Codes: unique ids and codes, every code already normalized, windows ordered.
	  5. Shop: every section item exists in MonetizationConfig (product / pass), no duplicates,
	     every offer exists, the packs are one-time products of the right kinds, the stock is sane.
	  6. Every product kind B7 owns is a kind of the catalogue (Spins, StarterPack, SecretPack,
	     Cash, Boost, ServerBoost) and every Boost product names a real boost.
	  7. Group: feature off while GroupId is 0.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local RetentionConfig = loader.load("src/shared/Config/RetentionConfig")
local PlaytimeConfig = loader.load("src/shared/Config/PlaytimeConfig")
local LuckySpinConfig = loader.load("src/shared/Config/LuckySpinConfig")
local CodesConfig = loader.load("src/shared/Config/CodesConfig")
local GroupConfig = loader.load("src/shared/Config/GroupConfig")
local BoostConfig = loader.load("src/shared/Config/BoostConfig")
local ShopConfig = loader.load("src/shared/Config/ShopConfig")
local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- The UI kit's canonical icon keys (docs/ui.md §5, StudUI.IconKeys) + Clock (a Glyphs recipe).
local ICON_KEYS: { [string]: boolean } = {}
for _, key in
	{
		"Shop",
		"Rewards",
		"Daily",
		"Codes",
		"LuckyWheel",
		"Time",
		"Pets",
		"Rebirth",
		"Teleport",
		"Attack",
		"Event",
		"x2Cash",
		"StarterPack",
		"VIP",
		"Spins",
		"Teleporter",
		"SecretPack",
		"Cash",
		"Gems",
		"Robux",
		"Close",
		"Star",
		"Check",
		"Lock",
		"Gift",
		"Arrow",
		"Clock",
		-- owner R89 gift ladder pictures (generated IconAssets keys: the money pile, the crate)
		"CashPack",
		"Crate",
	}
do
	ICON_KEYS[key] = true
end
local function iconKnown(key: string): boolean
	return ICON_KEYS[key] == true
end

local function rewardOk(reward: any, label: string)
	check(RetentionConfig.isRewardValid(reward), `{label}: reward valid`)
	if reward.boost ~= nil then
		check(BoostConfig.get(reward.boost.key) ~= nil, `{label}: boost {reward.boost.key} exists`)
	end
	check(table.isfrozen(reward), `{label}: reward frozen`)
end

-- 1 + 2. Daily + time
check(#RetentionConfig.Days == 7, "7 daily cards")
for index, day in RetentionConfig.Days do
	check(day.index == index, `day {index} indexed`)
	check(day.big == (index == 7), `only Day 7 is big ({index})`)
	check(iconKnown(day.icon), `day {index} icon {day.icon}`)
	rewardOk(day.reward, `daily {index}`)
end
-- Owner R89 Early Gift Ladder: ten gifts, the first inside the 2-minute churn window.
local MINUTES = { 1, 3, 5, 10, 15, 25, 40, 60, 90, 120 }
check(#PlaytimeConfig.Gifts == 10, "10 ladder gifts")
for index, gift in PlaytimeConfig.Gifts do
	check(gift.index == index and gift.minutes == MINUTES[index], `gift {index} at {MINUTES[index]} min`)
	check(gift.big == (index == 10), `only the last gift is big ({index})`)
	check(iconKnown(gift.icon), `gift {index} icon`)
	rewardOk(gift.reward, `time {index}`)
end
rewardOk(RetentionConfig.Notify.Reward, "notify")
rewardOk(GroupConfig.Reward, "group")
rewardOk(ShopConfig.StarterPack.reward, "starter pack")
rewardOk(ShopConfig.SecretPack.reward, "secret pack")

-- 3. Wheel
check(#LuckySpinConfig.Slices == 8, "8 slices")
local sliceIds: { [string]: boolean } = {}
local total = 0
for _, slice in LuckySpinConfig.Slices do
	check(not sliceIds[slice.id], `slice id {slice.id} unique`)
	sliceIds[slice.id] = true
	check(string.find(slice.id, "^[%w_]+$") ~= nil and #slice.id <= 32, `slice id {slice.id} is an analytics-safe key`)
	check(slice.weight > 0, `slice {slice.id} weight`)
	check(iconKnown(slice.icon), `slice {slice.id} icon {slice.icon}`)
	check(typeof(slice.color) == "Color3", `slice {slice.id} colour`)
	total += slice.weight
	rewardOk(slice.reward, `slice {slice.id}`)
end
check(total == 100 and LuckySpinConfig.TotalWeight == 100, "weights sum to 100 (weight = % chance)")
check(LuckySpinConfig.MaxFree == 3 and LuckySpinConfig.FreeEverySeconds == 1200, "free spin every 20 min, stack 3")

-- 4. Codes
local codeIds: { [string]: boolean } = {}
local codeTexts: { [string]: boolean } = {}
for _, def in CodesConfig.Codes do
	check(not codeIds[def.id] and not codeTexts[def.code], `code {def.code} unique`)
	codeIds[def.id], codeTexts[def.code] = true, true
	check(CodesConfig.normalize(def.code) == def.code, `code {def.code} normalized`)
	check(string.find(def.id, "^[%w_]+$") ~= nil, `code id {def.id} analytics-safe`)
	if def.startsAt ~= nil and def.expiresAt ~= nil then
		check(def.startsAt < def.expiresAt, `code {def.code} window`)
	end
	rewardOk(def.reward, `code {def.code}`)
end

-- 5. Shop
local seen: { [string]: boolean } = {}
for _, section in ShopConfig.Sections do
	check(#section.items > 0, `section {section.id} has items`)
	for _, item in section.items do
		local key = `{item.kind}:{item.key}`
		check(not seen[key], `{key} listed once`)
		seen[key] = true
		if item.kind == "product" then
			check(MonetizationConfig.getProduct(item.key) ~= nil, `product {item.key} exists`)
		else
			check(MonetizationConfig.getPass(item.key) ~= nil, `pass {item.key} exists`)
		end
	end
end
for _, passKey in MonetizationConfig.PassOrder do
	check(seen[`pass:{passKey}`] == true, `every pass is in the shop ({passKey})`)
end
for _, offer in ShopConfig.Offers do
	local exists = if offer.kind == "product"
		then MonetizationConfig.getProduct(offer.key) ~= nil
		else MonetizationConfig.getPass(offer.key) ~= nil
	check(exists, `offer {offer.key} exists`)
end
local starter = MonetizationConfig.getProduct("StarterPack")
local secret = MonetizationConfig.getProduct("SecretPack")
check(starter.kind == "StarterPack" and starter.oneTime, "starter pack product")
check(secret.kind == "SecretPack" and secret.oneTime, "secret pack product")
check(ShopConfig.Stock.Limit > 0 and ShopConfig.Stock.RefreshSeconds >= 30, "stock limits sane")
check(#ShopConfig.StarterPack.lines > 0 and #ShopConfig.SecretPack.lines > 0, "pack card lines")

-- 6. Product kinds B7 grants
local kinds: { [string]: boolean } = {}
for _, product in MonetizationConfig.Products do
	kinds[product.kind] = true
	if product.kind == "Boost" then
		check(BoostConfig.get(product.boostKey) ~= nil, `boost product {product.key} names a boost`)
	end
end
for _, kind in { "Spins", "StarterPack", "SecretPack", "Cash", "Boost", "ServerBoost" } do
	check(kinds[kind] == true, `catalogue has kind {kind}`)
end

-- 7. Group
check(GroupConfig.GroupId ~= 0 or not GroupConfig.isEnabled(), "group off while id is 0")

print(`[retention-config] {checks} checks passed`)
