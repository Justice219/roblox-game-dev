--!strict
--[[
	CodesConfig — redeemable codes (design spec §7: server-side code table with expiry, one claim
	per player).

	Rules (Server/Retention/CodeLogic + Server/Services/CodesService):
		- input is trimmed and upper-cased, so codes are case-insensitive ("nukes" = "NUKES");
		- a code is redeemable inside [startsAt, expiresAt) (either may be nil = open-ended);
		- each code pays once per player (profile.codes[id]); ids are SAVE DATA — never rename;
		- RedeemCode is rate-limited per player (Limit) and only ever answers with CodeResult.
	Only the server reads this table to grant. It is shared so the Codes screen can hint at the
	format; codes themselves are not secret once announced.

	Admin seam: CodesService.addCode(def) adds a runtime code to the running server only.

	Example:
		local def = CodesConfig.find("  nukes ") --> the NUKES definition
]]

local RetentionConfig = require(script.Parent.RetentionConfig)

export type Code = {
	id: string, -- stable save id (profile.codes key, analytics "code:ok:<id>")
	code: string, -- the text players type (upper case, letters / digits only)
	reward: RetentionConfig.Reward,
	startsAt: number?, -- unix seconds (inclusive); nil = always started
	expiresAt: number?, -- unix seconds (exclusive); nil = never expires
}

local CodesConfig = {}

-- Longest code a player can type (longer input is refused before any lookup).
CodesConfig.MaxLength = 20
-- RedeemCode token bucket per player.
CodesConfig.Limit = table.freeze({ Burst = 4, PerSecond = 0.25 })
-- Where the Codes screen tells players to look for codes.
CodesConfig.FollowText = "Follow SellNukes on Roblox for exclusive codes!"

-- Harvest Feast window (spec §10), Halloween end.
local HARVEST_STARTS = 1_793_491_200 -- 2026-11-01T00:00:00Z
local HARVEST_ENDS = 1_796_083_200 -- 2026-12-01T00:00:00Z
-- THANKYOU (owner R76) runs for the first week after the Moon Base update.
local THANKYOU_ENDS = 1_794_096_000 -- 2026-11-08T00:00:00Z

local CODES: { Code } = {
	{ id = "launch", code = "NUKES", reward = { cashSeconds = 300, cashFloor = 1_000, gems = 10 } },
	{ id = "boom", code = "BOOM", reward = { boost = { key = "cash2x", seconds = 900 } } },
	{ id = "release", code = "RELEASE", reward = { gems = 25, spins = 1 } },
	-- Owner R76 (2026-10-31): Discord codes for the 0.5.0 Moon Base update. Gems stay modest
	-- (GemsSmall = 100 gems for 39 R$), boosts use the existing BoostService keys.
	{ id = "moonbase", code = "MOONBASE", reward = { gems = 30, spins = 2 } },
	{ id = "blastoff", code = "BLASTOFF", reward = { boost = { key = "cash2x", seconds = 20 * 60 } } },
	{ id = "zoomzoom", code = "ZOOMZOOM", reward = { boost = { key = "speed2x", seconds = 15 * 60 } } },
	{ id = "discord", code = "DISCORD", reward = { cashSeconds = 600, cashFloor = 5_000, gems = 15 } },
	-- Limited thank-you for the first week's players (expires 2026-11-08T00:00:00Z).
	{ id = "thankyou", code = "THANKYOU", reward = { gems = 50, spins = 3 }, expiresAt = THANKYOU_ENDS },
	-- Owner R78 (2026-10-31): Discord code for the 0.6.0 Quests + Nuke Pass update.
	{ id = "quests", code = "QUESTS", reward = { gems = 40, spins = 1 } },
	{
		id = "harvest",
		code = "HARVEST",
		reward = { gems = 20, spins = 2 },
		startsAt = HARVEST_STARTS,
		expiresAt = HARVEST_ENDS,
	},
	-- Expired Halloween code: kept so returning players get "This code has expired!".
	{ id = "spooky", code = "SPOOKY", reward = { gems = 10 }, expiresAt = HARVEST_STARTS },
}
for _, def in CODES do
	if def.reward.boost ~= nil then
		table.freeze(def.reward.boost)
	end
	table.freeze(def.reward)
	table.freeze(def)
end
CodesConfig.Codes = table.freeze(CODES)

--[[
	Normalizes player input: trims whitespace and upper-cases. Returns nil for anything that is
	not 1..MaxLength ASCII letters / digits after trimming (so lookups never see junk).
	Example: CodesConfig.normalize("  Nukes ") --> "NUKES"
]]
function CodesConfig.normalize(text: unknown): string?
	if type(text) ~= "string" or #text > CodesConfig.MaxLength * 4 then
		return nil
	end
	local trimmed = string.match(text, "^%s*(.-)%s*$") :: string
	if #trimmed < 1 or #trimmed > CodesConfig.MaxLength or string.find(trimmed, "^%w+$") == nil then
		return nil
	end
	return string.upper(trimmed)
end

--[[ The configured code for player input (case-insensitive), or nil. ]]
function CodesConfig.find(text: unknown): Code?
	local normalized = CodesConfig.normalize(text)
	if normalized == nil then
		return nil
	end
	for _, def in CODES do
		if def.code == normalized then
			return def
		end
	end
	return nil
end

return table.freeze(CodesConfig)
