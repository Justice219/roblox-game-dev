--!strict
--[[
	BoostChipLogic — the PURE rules of the HUD boost badge (owner R82: "the two x cash UI can kind of
	be like a corner piece for the cash"; it replaced the R78 chip row): which boosts are active,
	what each one multiplies, the badge's big multiplier text, which timer it shows, its size, how
	far it must sit from the digits, and the breakdown rows. No Instances, no clocks (every function
	takes `now`), so Lune proves it (tests/social-logic.luau).

	Boosts (in this order, each only while active; `chips` keeps its R78 name):
		rookie / comeback  the Rush that applies right now (they never stack: the larger multiplier;
		                   the Rookie Rush on a tie, the same rule as the server's RushLogic)
		cash / speed       personal timed boosts (profile.boosts: cash2x / speed2x expiry times)
		server             the Server 2x Cash boost (ReplicatedStorage ServerBoostEndsAt)
		friends            the Friend Boost percent (no timer)

	The badge (decision R82, docs/social.md):
		big text   the COMBINED income multiplier: every active boost multiplied ("2x", "4x", "2.4x");
		           a Friend Boost alone reads "+20%" (clearer for kids than "1.2x"). 2x Speed counts:
		           every producer cycles twice as fast, so money comes in twice as fast.
		small text the timer of the boost that ends FIRST (when the big number next drops), or
		           "FRIENDS" when no boost has a timer. The Friend Boost has no separate indicator:
		           it is part of the number and a row of the breakdown.
		colour     the colour of the boost whose timer shows (friends blue when it is alone)
		stack      2+ boosts: a second sticker peeks out behind it (the screen reads `count`)

	Connects to: Shared/Config/{SocialConfig (Client look, Text), BoostConfig (boost icons and
	multipliers)}, UI/Screens/BoostChips/BoostChipsScreen (renders), Client/Social/SocialClient (rush
	/ friends state), tests/social-logic.luau.

	Example:
		local chips = BoostChipLogic.chips({ now = 100, rushOn = true, friendsOn = true,
			rookieEndsAt = 861, comebackEndsAt = 0, rookieMultiplier = 2, comebackMultiplier = 2,
			friendPercent = 20, boosts = {}, serverEndsAt = 0 })
		BoostChipLogic.label(chips[1], 100, false)       --> "ROOKIE RUSH 2x 12:41"
		local badge = BoostChipLogic.badge(chips) :: BoostChipLogic.Badge
		badge.text                                       --> "2.4x"
		BoostChipLogic.badgeSmall(badge, 100)            --> "12:41"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoostConfig = require(ReplicatedStorage.Shared.Config.BoostConfig)
local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)

export type ChipKind = "rookie" | "comeback" | "cash" | "speed" | "server" | "friends"

export type Chip = {
	kind: ChipKind,
	color: string, -- UIStyleConfig ColorName
	icon: string, -- IconAssets key (the screen falls back when it is not uploaded)
	text: string, -- full label without the timer ("ROOKIE RUSH 2x")
	compact: string, -- short label without the timer ("2x"; the friends-only badge text "+20%")
	endsAt: number?, -- server unix time the boost ends (nil = no timer)
	multiplier: number, -- what it multiplies income by (>= 1; friends +20 % = 1.2)
}

export type Input = {
	now: number, -- server unix time (Workspace:GetServerTimeNow())
	rushOn: boolean,
	friendsOn: boolean,
	rookieEndsAt: number, -- 0 = no Rookie Rush
	comebackEndsAt: number, -- 0 = no Comeback Rush
	rookieMultiplier: number,
	comebackMultiplier: number,
	friendPercent: number,
	boosts: { [string]: any }?, -- profile.boosts (untrusted shape)
	serverEndsAt: number?, -- ReplicatedStorage ServerBoostEndsAt (nil / 0 = none)
}

-- What the corner badge shows (BoostChipLogic.badge).
export type Badge = {
	multiplier: number, -- combined income multiplier (every active boost multiplied)
	text: string, -- the big text: "2x" / "2.4x" / "+20%" (Friend Boost alone)
	color: string, -- UIStyleConfig ColorName of the headline boost
	headline: Chip, -- the boost whose timer shows (soonest end; the first boost when none is timed)
	second: Chip?, -- the boost the stacked back sticker is tinted with (2+ boosts)
	endsAt: number?, -- the headline timer's end (nil = no boost has a timer)
	count: number, -- active boosts
}

-- Badge size inputs (design px). Text sizes already include any phone floor.
export type SizeInput = {
	big: string, -- the multiplier text
	small: string, -- the timer text
	bigSize: number,
	smallSize: number,
	padX: number,
	padY: number,
	charRatio: number, -- character width / text size (safe upper bound for the badge fonts)
	minWidth: number,
}

local BoostChipLogic = {}

local CLIENT = SocialConfig.Client
local TEXT = SocialConfig.Text

-- The personal timed boosts shown (profile.boosts keys), in display order.
type Personal = { key: string, kind: ChipKind, color: string, text: string }
local PERSONAL: { Personal } = {
	{ key = "cash2x", kind = "cash", color = "green", text = TEXT.CashChip },
	{ key = "speed2x", kind = "speed", color = "sky", text = TEXT.SpeedChip },
}

-- A finite number, else nil.
local function finite(value: unknown): number?
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

-- A multiplier >= 1 (junk / below 1 = neutral 1, the server's SafeMath.bonus rule).
local function factor(value: unknown): number
	local number = finite(value)
	return if number ~= nil and number >= 1 then number else 1
end

--[[
	Formats seconds as "12:41" (< 1 h) or "1:02:03".
	Example: BoostChipLogic.clock(761) --> "12:41"
]]
function BoostChipLogic.clock(seconds: number): string
	local s = math.max(0, math.ceil(if seconds == seconds then seconds else 0))
	local hours = s // 3600
	local minutes = (s % 3600) // 60
	local rest = s % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, rest)
	end
	return string.format("%d:%02d", minutes, rest)
end

--[[
	The active boosts at `now`, in display order.
	@param input Input (see the type; junk numbers read as "none")
	@return { Chip }
]]
function BoostChipLogic.chips(input: Input): { Chip }
	local now = finite(input.now) or 0
	local out: { Chip } = {}
	if input.rushOn then
		local rookieEnds = finite(input.rookieEndsAt) or 0
		local comebackEnds = finite(input.comebackEndsAt) or 0
		local rookieRate = factor(input.rookieMultiplier)
		local comebackRate = factor(input.comebackMultiplier)
		local rookie = rookieEnds > now
		local comeback = comebackEnds > now
		-- No stacking: the larger multiplier applies; Rookie wins a tie (RushLogic.multiplier).
		if rookie and (not comeback or rookieRate >= comebackRate) then
			local chip: Chip = {
				kind = "rookie",
				color = "orange",
				icon = "Upgrade",
				text = string.format(TEXT.RookieChip, SocialConfig.times(rookieRate)),
				compact = string.format(TEXT.RookieChipCompact, SocialConfig.times(rookieRate)),
				endsAt = rookieEnds,
				multiplier = rookieRate,
			}
			table.insert(out, chip)
		elseif comeback then
			local chip: Chip = {
				kind = "comeback",
				color = "red",
				icon = "Star",
				text = string.format(TEXT.ComebackChip, SocialConfig.times(comebackRate)),
				compact = string.format(TEXT.ComebackChipCompact, SocialConfig.times(comebackRate)),
				endsAt = comebackEnds,
				multiplier = comebackRate,
			}
			table.insert(out, chip)
		end
	end
	local boosts = input.boosts
	if type(boosts) == "table" then
		for _, entry in PERSONAL do
			local ends = finite(boosts[entry.key])
			if ends ~= nil and ends > now then
				local def = BoostConfig.get(entry.key)
				local chip: Chip = {
					kind = entry.kind,
					color = entry.color,
					icon = if def ~= nil then def.icon else "Clock",
					text = entry.text,
					compact = TEXT.CompactBoost,
					endsAt = ends,
					multiplier = factor(if def ~= nil then def.multiplier else 1),
				}
				table.insert(out, chip)
			end
		end
	end
	local serverEnds = finite(input.serverEndsAt)
	if serverEnds ~= nil and serverEnds > now then
		local chip: Chip = {
			kind = "server",
			color = "purple",
			icon = "ServerBoost",
			text = TEXT.ServerChip,
			compact = TEXT.CompactBoost,
			endsAt = serverEnds,
			multiplier = factor(BoostConfig.Server.Multiplier),
		}
		table.insert(out, chip)
	end
	local percent = finite(input.friendPercent) or 0
	if input.friendsOn and percent > 0 then
		local whole = math.floor(percent)
		local chip: Chip = {
			kind = "friends",
			color = "blue",
			icon = CLIENT.FriendsIcon,
			text = string.format(TEXT.FriendsChip, whole),
			compact = string.format(TEXT.FriendsChipCompact, whole),
			endsAt = nil,
			multiplier = factor(1 + whole / 100),
		}
		table.insert(out, chip)
	end
	return out
end

--[[
	A boost's label at `now`: its text plus the countdown when it has a timer.
	Example: BoostChipLogic.label(chip, now, true) --> "2x 4:59"
]]
function BoostChipLogic.label(chip: Chip, now: number, compact: boolean): string
	local text = if compact then chip.compact else chip.text
	local ends = chip.endsAt
	if ends == nil then
		return text
	end
	return `{text} {BoostChipLogic.clock(ends - now)}`
end

--[[
	A breakdown row's right-hand text: the time left ("12:41"), or "" for a boost without a timer
	(its name already says "+20%").
	Example: BoostChipLogic.rowTime(chip, now) --> "4:59"
]]
function BoostChipLogic.rowTime(chip: Chip, now: number): string
	local ends = chip.endsAt
	return if ends ~= nil then BoostChipLogic.clock(ends - now) else ""
end

--[[
	The soonest server time a boost ends (the screen re-evaluates then), or nil.
	Example: BoostChipLogic.nextChange(chips) --> 861
]]
function BoostChipLogic.nextChange(chips: { Chip }): number?
	local soonest: number? = nil
	for _, chip in chips do
		local ends = chip.endsAt
		if ends ~= nil and (soonest == nil or ends < soonest) then
			soonest = ends
		end
	end
	return soonest
end

--[[
	A multiplier as badge text, rounded DOWN to one decimal (never shows more than the player
	gets; the epsilon keeps 4.8 from reading 4.7 after float maths).
	Example: BoostChipLogic.times(2.42) --> "2.4x"; BoostChipLogic.times(4) --> "4x"
]]
function BoostChipLogic.times(multiplier: number): string
	local value = factor(multiplier)
	return SocialConfig.times(math.floor(value * 10 + 1e-6) / 10)
end

--[[
	What the corner badge shows for the active boosts (nil when there are none).
	@param chips { Chip } from BoostChipLogic.chips
	@return Badge?
	Example: BoostChipLogic.badge(chips).text --> "4x" (2x Cash + Rookie Rush)
]]
function BoostChipLogic.badge(chips: { Chip }): Badge?
	local count = #chips
	if count == 0 then
		return nil
	end
	local multiplier = 1
	local headline: Chip? = nil
	for _, chip in chips do
		multiplier *= factor(chip.multiplier)
		local ends = chip.endsAt
		if ends ~= nil then
			local best = if headline ~= nil then headline.endsAt else nil
			if best == nil or ends < best then
				headline = chip
			end
		end
	end
	local lead: Chip = headline or chips[1]
	-- The stacked back sticker takes the colour of the first OTHER boost.
	local second: Chip? = nil
	for _, chip in chips do
		if chip ~= lead then
			second = chip
			break
		end
	end
	local alone = count == 1 and lead.kind == "friends"
	return {
		multiplier = multiplier,
		text = if alone then lead.compact else BoostChipLogic.times(multiplier),
		color = lead.color,
		headline = lead,
		second = second,
		endsAt = lead.endsAt,
		count = count,
	}
end

--[[
	The badge's small line at `now`: the headline timer, or "FRIENDS" when no boost is timed.
	Example: BoostChipLogic.badgeSmall(badge, now) --> "1:25"
]]
function BoostChipLogic.badgeSmall(badge: Badge, now: number): string
	local ends = badge.endsAt
	return if ends ~= nil then BoostChipLogic.clock(ends - now) else TEXT.BadgeNoTimer
end

--[[
	The badge sticker's size (design px): wide enough for the longer of its two lines at a safe
	character width, two lines tall plus padding.
	@return (width, height)
	Example: BoostChipLogic.badgeSize({ big = "2x", small = "1:25", bigSize = 34, smallSize = 20,
		padX = 10, padY = 6, charRatio = 0.62, minWidth = 72 }) --> 72, 66
]]
function BoostChipLogic.badgeSize(input: SizeInput): (number, number)
	local bigChars = utf8.len(input.big) or #input.big
	local smallChars = utf8.len(input.small) or #input.small
	local textWidth = math.max(bigChars * input.bigSize, smallChars * input.smallSize) * input.charRatio
	local width = math.max(input.minWidth, math.ceil(textWidth + input.padX * 2))
	local height = math.ceil(input.bigSize + input.smallSize + input.padY * 2)
	return width, height
end

--[[
	How far right of the counter's box the badge must start so no tilted corner, outline or edge
	ever reaches the digits. Rotating a w x h box by `tilt` degrees about its centre moves its
	leftmost corner by h/2 * |sin| - w/2 * (1 - cos) past the unrotated left edge.
	@param width / height the sticker (design px)
	@param tilt degrees (either sign)
	@param base the plain gap (the digits' outline + the badge's own edge + air)
	@return whole design px
	Example: BoostChipLogic.cornerGap(96, 64, 8, 11) --> 15
]]
function BoostChipLogic.cornerGap(width: number, height: number, tilt: number, base: number): number
	local radians = math.rad(math.abs(finite(tilt) or 0))
	local overhang = height / 2 * math.sin(radians) - width / 2 * (1 - math.cos(radians))
	return math.ceil(math.max(0, base) + math.max(0, overhang))
end

return table.freeze(BoostChipLogic)
