--!strict
--[[
	EggView — how an egg's price, balance and lock read on the client, for eggs of ANY world
	(owner R57 World 2: Dino Valley's eggs cost Bones and unlock with Dino progress). Pure: a
	profile snapshot goes in, numbers / text come out, so the stand billboards (Pets/StandClient)
	and the EggHatch window (UI/Screens/EggHatch) always say the same thing and `tests/pets-logic`
	can run it in Lune. Display only: the server re-checks money, world, area, range and policy on
	every HatchEgg request (Server/Pets/PetLogic).

	Currencies (EggConfig.Currency):
		cash     profile.cash                       "$1.2K"
		acorns   profile.event.acorns               "30 Acorns"
		<world>  profile.worldCash[world].cash      "24K Bones"   (WorldsConfig currency, "count"
		         (the snapshot's small worldCash     style; ClientState.worldCash reads the same
		         delta field, ProfileSyncState)       field)
		held     never bought                       ""

	Connects to: Shared/Config/{EggConfig, Worlds/WorldsConfig}, Shared/Util/NumberFormat,
	Client/Pets/StandClient, UI/Screens/EggHatch/EggHatchScreen, tests/pets-logic.luau.

	Example:
		local EggView = require(script.Parent.EggView)
		local egg = EggConfig.get("dino_egg")
		print(EggView.formatAmount(egg, egg.price))           --> "24K Bones"
		print(EggView.balance(ClientState.profile, egg))       --> 1250 (Bones)
		print(EggView.lockText(ClientState.profile, egg))      --> "LOCKED - unlock Dino Valley"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local EggView = {}

-- A finite, non-negative number or 0 (snapshot fields are display data; never trust their shape).
local function amount(value: unknown): number
	if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
		return 0
	end
	return value
end

--[[
	The non-main world whose wallet currency `currency` is ("bones" -> "dino"), or nil. Mirrors
	the server's PetLogic.worldWallet (tokens such as "amber" never price an egg).
]]
function EggView.worldWallet(currency: string): string?
	local worldId = WorldsConfig.worldOfCurrency(currency)
	if worldId == nil or worldId == WorldsConfig.MAIN then
		return nil
	end
	local world = WorldsConfig.get(worldId)
	return if world ~= nil and world.currency.key == currency then worldId else nil
end

--[[
	The player's balance of `egg`'s currency in a profile snapshot (0 for held-only eggs, a
	missing snapshot or malformed fields).
	Example: EggView.balance({ worldCash = { dino = { cash = 50 } } }, dinoEgg) --> 50
]]
function EggView.balance(profile: unknown, egg: EggConfig.EggDef): number
	local data: any = if type(profile) == "table" then profile else {}
	if egg.currency == "cash" then
		return amount(data.cash)
	elseif egg.currency == "acorns" then
		return amount(if type(data.event) == "table" then data.event.acorns else nil)
	end
	local worldId = EggView.worldWallet(egg.currency)
	if worldId == nil then
		return 0
	end
	local wallets = data.worldCash
	local wallet = if type(wallets) == "table" then wallets[worldId] else nil
	return amount(if type(wallet) == "table" then wallet.cash else nil)
end

--[[
	An amount of `egg`'s currency as the UI shows it.
	Example: EggView.formatAmount(garage, 560) --> "$560"; EggView.formatAmount(dino, 24000) --> "24K Bones"
]]
function EggView.formatAmount(egg: EggConfig.EggDef, value: number): string
	if egg.currency == "cash" then
		return NumberFormat.money(value)
	elseif egg.currency == "acorns" then
		return `{NumberFormat.commas(value)} Acorns`
	elseif egg.currency == "held" then
		return ""
	end
	return `{NumberFormat.short(value)} {EggConfig.currencyName(egg)}`
end

--[[
	True when the egg's WORLD is open for this snapshot (Nuke Town always; another world once its
	sticky unlock is true). The area is a separate check (EggConfig.isUnlocked).
]]
function EggView.worldOpen(profile: unknown, egg: EggConfig.EggDef): boolean
	local open = EggConfig.progressOf(profile, egg)
	return open
end

--[[
	The short line a locked egg shows: its world first (a closed world reads "unlock Dino Valley"),
	then the area in that world ("reach Fern Market").
	Example: EggView.lockText(profile, EggConfig.get("dino_egg")) --> "LOCKED - unlock Dino Valley"
]]
function EggView.lockText(profile: unknown, egg: EggConfig.EggDef): string
	if not EggView.worldOpen(profile, egg) then
		return `LOCKED - unlock {EggConfig.worldName(egg)}`
	end
	return `LOCKED - reach {EggConfig.areaName(egg)}`
end

--[[
	The locked HATCH button caption (upper case, short): "UNLOCK DINO VALLEY" / "REACH FERN MARKET".
]]
function EggView.lockButton(profile: unknown, egg: EggConfig.EggDef): string
	if not EggView.worldOpen(profile, egg) then
		return `UNLOCK {string.upper(EggConfig.worldName(egg))}`
	end
	return `REACH {string.upper(EggConfig.areaName(egg))}`
end

--[[
	"You have 1.2K Bones" / "You have $5.4M" / "You have 12 acorns" — the balance line.
]]
function EggView.balanceText(profile: unknown, egg: EggConfig.EggDef): string
	local value = EggView.balance(profile, egg)
	if egg.currency == "acorns" then
		return `You have {NumberFormat.commas(value)} acorns`
	end
	return `You have {EggView.formatAmount(egg, value)}`
end

return table.freeze(EggView)
