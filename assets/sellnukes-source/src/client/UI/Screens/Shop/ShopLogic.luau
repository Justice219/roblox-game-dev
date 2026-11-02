--!strict
--[[
	ShopLogic — the Shop screen's small pure helpers: what state each card's buy button is in,
	how the Secret Pack's global stock reads, which icon key a card uses and how a section title
	is cleaned for StudUI.sectionLabel.

	Purpose:
		The Shop (Screens/Shop/init) builds every card ONCE and then only re-applies a status
		when something changes. Keeping the "is it owned / coming soon / sold out / buyable?"
		rules here means the card modules only draw and the screen only wires events.

	Status rules (first match wins; the server re-checks every prompt anyway):
		1. owned       pass owned (profile.passes[key] or a PurchaseGranted this session), or a
		               one-time pack already bought (profile.starter.bought /
		               profile.secretPack.bought / R57 world bundles:
		               profile.worlds.<world>.starter.bought)                      -> "OWNED"
		2. soon        not published / outside its sale window
		               (MonetizationConfig.isProductAvailable / isPassAvailable)     -> "SOON"
		3. soldout     Secret Pack with every unit of the global stock sold          -> "SOLD OUT"
		4. restricted  a paid random item (Lucky Spins) for a player whose region does not allow
		               them (profile.policy.paidRandomRestricted)                    -> "UNAVAILABLE"
		5. buy         the green Robux price button

	World sections (R57 World 2, ShopConfig.WorldSections):
		worldItemHidden    a one-time world bundle (Time Traveler Pack) leaves the Shop once
		                   bought (profile.worlds.<world>.starter.bought or granted this session)
		worldCashAmount    the Bones a "WorldCash" / "WorldStarter" product would pay NOW, by the
		                   same rule the server grants with (TycoonService.grantWorldCash:
		                   max(cashFloor, incomeSeconds x that world's idle income)), mirroring
		                   what the Cash packs preview (RewardPreview.cash) — display only

	Security: display only. Nothing here grants, prompts or trusts the client; the server's
	MonetizationService refuses every prompt that these rules would hide.

	Connects to: Shared/Config/{MonetizationConfig, ShopConfig, UIStyleConfig}, Kit/StudUI
	(iconImage, ButtonState), Shared/Util/NumberFormat, Shared/Tycoon/TycoonLogic (forWorld:
	world idle income). Used by Shop/init, Shop/ShopCard, Shop/PackCard.

	Example:
		local status = ShopLogic.productStatus(MonetizationConfig.getProduct("SecretPack"), {
			profile = ClientState.profile, granted = {}, now = workspace:GetServerTimeNow(),
			stock = ShopLogic.readStock(),
		})
		local state, text = ShopLogic.buttonLook(status) --> "locked", "SOLD OUT"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type Status = "buy" | "owned" | "soon" | "soldout" | "restricted"

-- The Secret Pack's replicated global stock (ShopService writes ReplicatedStorage attributes).
export type Stock = {
	known: boolean, -- false until the server has read the counter once (At attribute > 0)
	sold: number,
	limit: number,
	left: number,
	soldOut: boolean,
}

-- What a status check needs: the server snapshot, this session's durable grants, the server
-- clock and the current stock.
export type Context = {
	profile: { [string]: any }?,
	granted: { [string]: boolean }, -- keys granted this session (PurchaseGranted)
	now: number,
	stock: Stock,
}

local ShopLogic = {}

-- Button look per status: (StudUI button state, state text). "buy" keeps the price label.
local LOOKS: { [Status]: { state: StudUI.ButtonState, text: string? } } = {
	buy = { state = "normal", text = nil },
	owned = { state = "claimed", text = "OWNED" },
	soon = { state = "locked", text = "SOON" },
	soldout = { state = "locked", text = "SOLD OUT" },
	restricted = { state = "locked", text = "UNAVAILABLE" },
}

-- A finite, non-negative whole number read from an untrusted attribute value, else nil.
local function wholeNumber(value: unknown): number?
	if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
		return nil
	end
	return math.floor(value)
end

-- True when `profile[field]` is a table whose `bought` flag is true (starter / secretPack).
local function bought(profile: { [string]: any }?, field: string): boolean
	if profile == nil then
		return false
	end
	local entry = profile[field]
	return type(entry) == "table" and entry.bought == true
end

--[[
	A non-main world's snapshot table (profile.worlds[worldId]) read defensively, else nil.
	Same shape rule as ClientState.world, kept local so this module stays a pure helper over the
	snapshot it is given.
	Example: worldState(ClientState.profile, "dino")
]]
local function worldState(profile: { [string]: any }?, worldId: string): { [string]: any }?
	if profile == nil then
		return nil
	end
	local worlds = profile.worlds
	if type(worlds) ~= "table" then
		return nil
	end
	local world = worlds[worldId]
	return if type(world) == "table" then world else nil
end

--[[
	R57: true when the player already bought `worldId`'s one-time world bundle
	(profile.worlds.<world>.starter.bought — the flag MonetizationService checks at the prompt).
	@param profile ClientState.profile (may be nil early)
	@param worldId WorldsConfig id ("dino")
	Example: ShopLogic.worldStarterBought(ClientState.profile, "dino") --> false
]]
function ShopLogic.worldStarterBought(profile: { [string]: any }?, worldId: string): boolean
	local world = worldState(profile, worldId)
	return world ~= nil and bought(world, "starter")
end

--[[
	R57: true when a world-section product must not show at all: a one-time world bundle
	("WorldStarter", e.g. the Time Traveler Pack) once bought — by the profile flag or a
	PurchaseGranted this session (the profile push that records it may land a moment later).
	@param def product definition (MonetizationConfig.getProduct)
	@param ctx status context (profile / grants)
	@return boolean
	Example: ShopLogic.worldItemHidden(MonetizationConfig.getProduct("TimeTravelerPack"), ctx)
]]
function ShopLogic.worldItemHidden(def: MonetizationConfig.ProductDef, ctx: Context): boolean
	if def.kind ~= "WorldStarter" then
		return false
	end
	if ctx.granted[def.key] == true then
		return true
	end
	return def.world ~= nil and ShopLogic.worldStarterBought(ctx.profile, def.world)
end

--[[
	R57: the world currency (Bones) a "WorldCash" / "WorldStarter" product would pay this player
	NOW: max(cashFloor, incomeSeconds x the world's automated idle income), floored — the same rule
	TycoonService.grantWorldCash uses, previewed from the snapshot exactly like the Cash packs
	(RewardPreview.cash: the world's rebirths + rebirth shop, no timed boosts). Display only; the
	server computes the real grant.
	@param def     product definition with `world` set
	@param profile ClientState.profile (may be nil early)
	@return whole amount (0 = no preview: no world, no floor and no income yet, or junk data)
	Example: ShopLogic.worldCashAmount(MonetizationConfig.getProduct("BonesLarge"), ClientState.profile) --> 50000
]]
function ShopLogic.worldCashAmount(def: MonetizationConfig.ProductDef, profile: { [string]: any }?): number
	local worldId = def.world
	if worldId == nil or (def.kind ~= "WorldCash" and def.kind ~= "WorldStarter") then
		return 0
	end
	local income = 0
	local world = worldState(profile, worldId)
	if world ~= nil and type(world.tycoon) == "table" and def.incomeSeconds ~= nil then
		-- pcall: forWorld errors on an unknown world id; the snapshot is untrusted-shaped data.
		local ok, value = pcall(function(): number
			return TycoonLogic.forWorld(worldId)
				.incomePerSecond(world.tycoon :: any, { rebirths = world.rebirths, rebirthShop = world.rebirthShop } :: any)
		end)
		if ok and type(value) == "number" and value == value and value > 0 and value < math.huge then
			income = value
		end
	end
	local scaled = if def.incomeSeconds ~= nil and income > 0 then def.incomeSeconds * income else 0
	local amount = math.max(def.cashFloor or 0, scaled)
	if amount ~= amount or amount == math.huge or amount <= 0 then
		return 0
	end
	return math.floor(amount)
end

--[[
	The Shop's section heading text: ShopConfig titles may already carry the "- X -" dashes, and
	StudUI.sectionLabel adds its own, so leading / trailing dashes and spaces are stripped.
	@param title ShopConfig section title
	@return cleaned title (never empty)
	Example: ShopLogic.cleanTitle("- LIMITED TIME -") --> "LIMITED TIME"
]]
function ShopLogic.cleanTitle(title: string): string
	local cleaned = string.match(title, "^[%s%-]*(.-)[%s%-]*$") or title
	return if cleaned ~= "" then cleaned else title
end

--[[
	A ShopConfig colour name as a StudUI colour preset (unknown names fall back).
	@param name     ShopConfig section colour ("red", "rainbow", ...)
	@param fallback preset used when `name` is not a UIStyleConfig colour
	@return StudUI.ColorName
	Example: ShopLogic.colorName("purple", "sky") --> "purple"
]]
function ShopLogic.colorName(name: string, fallback: StudUI.ColorName): StudUI.ColorName
	local presets: { [string]: unknown } = UIStyleConfig.Colors :: any
	if presets[name] ~= nil then
		return name :: any
	end
	return fallback
end

--[[
	The icon key a card shows: the item's own key when B15 uploaded an icon for it (IconAssets
	aliases product / pass keys, e.g. "CashLarge" -> CashPack), else MonetizationConfig's
	lowercase icon name (which the Glyphs fallback understands).
	@param key      product / pass key
	@param fallback MonetizationConfig icon name ("cash", "gem", ...)
	@return icon key for StudUI.icon
	Example: ShopLogic.iconFor("VIP", "crown")
]]
function ShopLogic.iconFor(key: string, fallback: string): string
	if StudUI.iconImage(key) ~= nil then
		return key
	end
	return fallback
end

--[[
	Reads the Secret Pack stock from the ReplicatedStorage attributes ShopService replicates.
	Missing / malformed values read as "not known yet" (never as sold out by accident).
	@return Stock
	Example: local stock = ShopLogic.readStock(); print(stock.left, stock.limit)
]]
function ShopLogic.readStock(): Stock
	local cfg = ShopConfig.Stock
	local sold = wholeNumber(ReplicatedStorage:GetAttribute(cfg.SoldAttribute))
	local limit: number = wholeNumber(ReplicatedStorage:GetAttribute(cfg.LimitAttribute)) or 0
	if limit <= 0 then
		limit = cfg.Limit -- not replicated yet: the configured global limit
	end
	local at = wholeNumber(ReplicatedStorage:GetAttribute(cfg.AtAttribute)) or 0
	-- At == 0 means the server has not read the cross-server counter yet.
	local known = sold ~= nil and at > 0
	local soldCount = if known and sold ~= nil then sold else 0
	local left = math.max(0, limit - soldCount)
	return {
		known = known,
		sold = soldCount,
		limit = limit,
		left = left,
		soldOut = known and soldCount >= limit,
	}
end

--[[
	The Secret Pack card's stock line.
	@param stock ShopLogic.readStock()
	@return "123 / 500 left" | "Stock updating..."
	Example: ShopLogic.stockText(ShopLogic.readStock())
]]
function ShopLogic.stockText(stock: Stock): string
	if not stock.known then
		return "Stock updating..."
	end
	return `{NumberFormat.commas(stock.left)} / {NumberFormat.commas(stock.limit)} left`
end

--[[
	True when the player owns game pass `key` (server snapshot or a grant this session).
	@param profile ClientState.profile (may be nil early)
	@param granted keys granted this session
	@param key     pass key
	Example: ShopLogic.ownsPass(ClientState.profile, {}, "VIP")
]]
function ShopLogic.ownsPass(profile: { [string]: any }?, granted: { [string]: boolean }, key: string): boolean
	if granted[key] == true then
		return true
	end
	if profile == nil then
		return false
	end
	local passes: any = profile.passes
	if type(passes) ~= "table" then
		return false
	end
	return (passes :: { [string]: unknown })[key] == true
end

--[[
	The status of a game pass card.
	@param key pass key
	@param ctx status context (profile / grants / clock / stock)
	@return Status ("owned" | "soon" | "buy")
	Example: ShopLogic.passStatus("VIP", ctx)
]]
function ShopLogic.passStatus(key: string, ctx: Context): Status
	if ShopLogic.ownsPass(ctx.profile, ctx.granted, key) then
		return "owned"
	end
	if not MonetizationConfig.isPassAvailable(key) then
		return "soon"
	end
	return "buy"
end

--[[
	The status of a developer product card (see the module header for the rule order).
	@param def product definition (MonetizationConfig.getProduct)
	@param ctx status context (profile / grants / clock / stock)
	@return Status
	Example: ShopLogic.productStatus(MonetizationConfig.getProduct("StarterPack"), ctx)
]]
function ShopLogic.productStatus(def: MonetizationConfig.ProductDef, ctx: Context): Status
	-- One-time packs: granted this session, or the profile's bought flag for that pack.
	if def.oneTime and ctx.granted[def.key] == true then
		return "owned"
	end
	if def.kind == "StarterPack" and bought(ctx.profile, "starter") then
		return "owned"
	end
	if def.kind == "SecretPack" and bought(ctx.profile, "secretPack") then
		return "owned"
	end
	-- R57 world bundle (the Shop hides it once bought; OWNED covers the frame before that).
	if def.kind == "WorldStarter" and def.world ~= nil and ShopLogic.worldStarterBought(ctx.profile, def.world) then
		return "owned"
	end
	if not MonetizationConfig.isProductAvailable(def.key, ctx.now) then
		return "soon"
	end
	if def.kind == "SecretPack" and ctx.stock.soldOut then
		return "soldout"
	end
	if def.paidRandom then
		local profile = ctx.profile
		local policy = if profile ~= nil then profile.policy else nil
		if type(policy) == "table" and policy.paidRandomRestricted == true then
			return "restricted"
		end
	end
	return "buy"
end

--[[
	The buy button's look for a status.
	@param status card status
	@return (StudUI button state, state text or nil for the price label)
	Example: local state, text = ShopLogic.buttonLook("owned") --> "claimed", "OWNED"
]]
function ShopLogic.buttonLook(status: Status): (StudUI.ButtonState, string?)
	local look = LOOKS[status]
	return look.state, look.text
end

--[[
	True when a card should show its price beside a locked button (the button label then says
	SOON / SOLD OUT / UNAVAILABLE instead of the price, but the price stays visible).
	Example: ShopLogic.showsSidePrice("soon") --> true
]]
function ShopLogic.showsSidePrice(status: Status): boolean
	return status == "soon" or status == "soldout" or status == "restricted"
end

return table.freeze(ShopLogic)
