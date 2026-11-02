--!strict
--[[
	dump_catalogue.luau — prints the SellNukes Robux catalogue (MonetizationConfig) as JSON on stdout.

	Purpose:
		tools/monetization/publish.py creates / updates every game pass and developer product on
		Roblox. Rather than re-parsing Luau in Python, it runs this script, which loads the REAL
		shipped module through the same Roblox loader the Lune tests use, so the published names,
		descriptions and prices can never drift from what the game reads.

	Output: { "passes": [PassRow], "products": [ProductRow] } sorted by key, where a row is
		{ key, name, description, price, icon, order, kind? } (kind only for products).

	Usage: lune run tools/monetization/dump_catalogue.luau
]]

local serde = require("@lune/serde")
local Loader = require("../../tests/fixtures/RobloxLoader")

local loader = Loader.new()
local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")

--[[
	Copies the publishable fields of one pass / product definition into a plain row.
	@param def  MonetizationConfig.Passes[key] or .Products[key]
	@return the JSON row (strings / numbers only)
]]
local function row(def: any): { [string]: any }
	return {
		key = def.key,
		name = def.name,
		description = def.description,
		price = def.price,
		icon = def.icon,
		order = def.order,
		kind = def.kind,
	}
end

--[[ Rows of a key -> def map, sorted by key for a deterministic output. ]]
local function rows(map: { [string]: any }): { { [string]: any } }
	local list = {}
	for _, def in map do
		table.insert(list, row(def))
	end
	table.sort(list, function(a, b)
		return a.key < b.key
	end)
	return list
end

print(serde.encode("json", {
	passes = rows(MonetizationConfig.Passes),
	products = rows(MonetizationConfig.Products),
}, false))
