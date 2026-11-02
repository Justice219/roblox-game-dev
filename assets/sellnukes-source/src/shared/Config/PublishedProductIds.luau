--!strict
--[[
	PublishedProductIds — the Creator Dashboard ids of every SellNukes game pass and developer
	product (universe 10773845696, place 132667741281890).

	Purpose:
		MonetizationConfig holds WHAT each item is (kind, price, name, text, icon); this module
		holds only WHERE it lives on Roblox. Keeping ids separate means publishing a product is a
		one-line change here and can never alter a grant.

	Rule: an id of 0 means "not created on the Creator Dashboard yet". MonetizationConfig maps 0
	to an unconfigured item: the server never prompts it, never looks its ownership up and never
	matches a receipt to it, and the UI shows COMING SOON. B12 (live monetization ids) fills these
	in after creating the products (scripts/studio_mcp.py → manage_monetization) and records the
	dashboard setup in docs.

	Every key here must exist in MonetizationConfig.Passes / .Products and vice versa
	(MonetizationConfig.validate() and tests/validate.luau check both directions).

	Example:
		local vipId = PublishedProductIds.Passes.VIP -- 0 until published
]]

local PublishedProductIds = {
	-- Game passes (one-time; ownership via MarketplaceService:UserOwnsGamePassAsync).
	Passes = table.freeze({
		VIP = 2062649466,
		DoubleCash = 2058433191,
		AutoClicker = 2063279399,
		FastWalk = 2061923824,
		Teleporter = 2061497904,
		LuckyEggs = 2060658474,
		PetSlots = 2058229188,
		TripleHatch = 2061353920,
		AutoHatch = 2062643469,
		OfflineMax = 2058463264,
		MegaLauncher = 2061437855,
	}),
	-- Developer products (repeatable unless MonetizationConfig marks them oneTime; ProcessReceipt).
	Products = table.freeze({
		CashSmall = 3724190991,
		CashMedium = 3724190966,
		CashLarge = 3724190921,
		CashHuge = 3724190895,
		GemsSmall = 3724191246,
		GemsMedium = 3724191199,
		GemsLarge = 3724191167,
		Spins2 = 3724191510,
		Spins5 = 3724191555,
		Spins10 = 3724191484,
		StarterPack = 3724191589,
		SecretPack = 3724191289,
		DoubleOffline = 3724191121,
		ServerCash2x = 3724191337,
		Cash2x30 = 3724190860,
		Barrage = 3724190831,
		Shield1h = 3724191393,
		SkipPad = 3724191461,
		AcornsSmall = 3724190807,
		AcornsLarge = 3724190798,
		TurkeyLure = 3724191635,
		CrateSupply = 3724191091,
		CrateMega = 3724191056,
		CrateGolden = 3724191016,
		-- R57 World 2 "Dino Valley" (spec §9): created 2026-10-30 by tools/monetization/publish.py.
		BonesSmall = 3724510192,
		BonesMedium = 3724510147,
		BonesLarge = 3724510119,
		TimeTravelerPack = 3724510226,
		-- R70 World 3 "Moon Base" (R69–R71 spec §2.6): created 2026-10-31 by tools/monetization/publish.py.
		MoonRocksSmall = 3724649324,
		MoonRocksMedium = 3724649274,
		MoonRocksLarge = 3724649223,
		AstronautPack = 3724649081,
		-- R78 Nuke Pass (spec §2): created by tools/monetization/publish.py.
		NukePassPremium = 3725022864,
		-- R89 Pocket Rocket (gift ladder wave §3): created 2026-10-31 by tools/monetization/publish.py
		-- (19 R$ fixed, managed pricing off: the MCP manage_monetization key was expired).
		PocketRocket = 3725469699,
		RevengeNuke = 3725620060,
	}),
}

return table.freeze(PublishedProductIds)
