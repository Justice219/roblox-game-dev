--!strict
--[[
	AttackLogic — the pure rules of Attack mode: level stats, effective levels, upgrade prices,
	launch eligibility, rewards, cooldowns and shields (spec §9; tunables in AttackConfig).

	Kid-friendly invariants enforced HERE (and tested in tests/attack-logic.luau):
		* nothing in this module ever computes a loss for the target: a hit only produces a reward
		  (minted for the attacker) and a Revenge token for the target;
		* brand-new players (owner R85 NewPlayer protection: `newbie`, decided by the server) and
		  shielded players are never valid targets (AFK players are: owner R43 "AFK nuke system" —
		  they lose nothing);
		* rewards are bounded by the attacker's OWN income band, so no target/alt can be farmed
		  for more than Reward.MaxRatio x the attacker's income per reward-second;
		* Rival Factories (NPC targets, owner R43) pay rewardRatio (<= Rivals.MaxRewardRatio < 1)
		  x the attacker's own income per reward-second: always less than an equal-income player.

	Shared on purpose: the server decides with it; the client uses the SAME functions to grey out
	the target picker, show the cooldown and price the upgrade buttons (display only — the server
	re-checks everything).

	Hostile input: every function accepts any value (NaN, inf, wrong types) and degrades to the
	safe answer (level 0, "not allowed", reward 0, price math.huge).

	Connects to: Shared/Config/AttackConfig, Server/Services/{AttackService, DefenseService},
	Client/UI/Screens/{AttackTarget, Defense}, tests/attack-logic.luau.

	Example:
		local ok, reason = AttackLogic.canLaunch(attacker, target, "normal", now, false)
		if not ok then print(AttackLogic.reasonText(reason)) end
		local cash = AttackLogic.reward("normal", 3, targetIncome, myIncome, ownsMegaLauncher)
]]

local AttackConfig = require(script.Parent.Parent.Config.AttackConfig)

local AttackLogic = {}

-- "golden" = owner R85's paid golden revenge nuke (a stored charge; AttackConfig.Golden).
export type LaunchKind = "normal" | "revenge" | "barrage" | "golden"
-- Refusal reasons (the analytics "refused:<reason>" labels, plus "empty" → "other").
export type Reason = "target" | "protected" | "shield" | "cooldown" | "locked" | "empty"

--[[
	What the rules need to know about one player (built by the server from the profile + live
	state; built by the client from replicated attributes for display).
]]
export type Actor = {
	userId: number,
	loaded: boolean, -- profile loaded and session live
	plot: number, -- plot index, 0 = none
	area: number, -- highest unlocked area
	console: boolean, -- owns the Attack Console feature pad
	launcher: number, -- EFFECTIVE launcher level (owner R85: >= StarterLauncher for every player)
	cooldownUntil: number, -- server time the next normal launch is allowed
	shieldUntil: number, -- server time the shield ends (<= now = none)
	barrage: number, -- stored Barrage nukes
	newbie: boolean?, -- owner R85: still protected as a brand-new player (server-decided)
	golden: number?, -- owner R85: stored golden revenge nuke charges
}

AttackLogic.Kinds = table.freeze({ "normal", "revenge", "barrage", "golden" } :: { LaunchKind })

-- A finite number, else `fallback`.
local function num(value: unknown, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

-- A whole level in [0, MaxLevel] from any value.
local function level(value: unknown): number
	return math.clamp(math.floor(num(value, 0)), 0, AttackConfig.MaxLevel)
end

--[[
	Launcher stats for an effective level (1..MaxLevel). Level 0 / invalid → nil.
	@param launcherLevel any
	@return LauncherLevel?
	Example: AttackLogic.launcherStats(2).cooldown --> 25
]]
function AttackLogic.launcherStats(launcherLevel: unknown): AttackConfig.LauncherLevel?
	local l = level(launcherLevel)
	return if l >= 1 then AttackConfig.Launcher[l] else nil
end

--[[
	AA tower stats for an effective level (1..MaxLevel). Level 0 / invalid → nil (no tower).
	@param aaLevel any
	@return AALevel?
]]
function AttackLogic.aaStats(aaLevel: unknown): AttackConfig.AALevel?
	local l = level(aaLevel)
	return if l >= 1 then AttackConfig.AA[l] else nil
end

--[[
	The level that counts in play: 0 without the feature pad, else the stored level clamped to
	1..MaxLevel (the pad itself is level 1). Levels persist through Rebirth; they come back when
	the pad is bought again.
	@param stored any — profile.attack.aa / .launcher
	@param hasFeature boolean — TycoonLogic.hasFeature(state, "AATower" / "AttackConsole")
	@return number
	Example: AttackLogic.effectiveLevel(0, true) --> 1
]]
function AttackLogic.effectiveLevel(stored: unknown, hasFeature: boolean): number
	if hasFeature ~= true then
		return 0
	end
	return math.max(level(stored), 1)
end

--[[
	Owner R85: the launcher level that counts in play — every player has StarterLauncher; owning
	the Attack Console makes it at least ConsoleLauncher and lets the stored (upgraded) level count.
	@param stored any — profile.attack.launcher
	@param hasConsole boolean — owns the Attack Console feature pad
	@return number — StarterLauncher..MaxLevel
	Example: AttackLogic.launcherLevel(0, false) --> 1 ; launcherLevel(1, true) --> 2
]]
function AttackLogic.launcherLevel(stored: unknown, hasConsole: boolean): number
	if hasConsole ~= true then
		return AttackConfig.StarterLauncher
	end
	return math.max(level(stored), AttackConfig.ConsoleLauncher)
end

--[[
	Owner R85: a golden revenge nuke's armor vs AA — the launcher's armor + Golden.ArmorBonus,
	capped at Golden.MaxArmor.
	@param launcherLevel any — the attacker's effective launcher level
	@return number — 0..MaxArmor
]]
function AttackLogic.goldenArmor(launcherLevel: unknown): number
	local stats = AttackLogic.launcherStats(launcherLevel) or AttackConfig.Launcher[1]
	return math.min(stats.armor + AttackConfig.Golden.ArmorBonus, AttackConfig.Golden.MaxArmor)
end

--[[
	Price to raise `kind` from effective level `current` to current + 1.
	@param current any — effective level (must be >= 1: the pad gives level 1)
	@param padPrice any — the kind's Area 7 Feature pad price (TycoonConfig)
	@return number — cash, or math.huge when it cannot be bought (max level / no feature / bad input)
	Example: AttackLogic.upgradeCost(1, 1.7e14) --> 6.8e14
]]
function AttackLogic.upgradeCost(current: unknown, padPrice: unknown): number
	local l = level(current)
	local price = num(padPrice, 0)
	local multiplier = AttackConfig.CostMultiplier[l + 1]
	if l < 1 or multiplier == nil or price <= 0 then
		return math.huge
	end
	return price * multiplier
end

--[[
	Cash minted for ONE hit (target loses nothing). See AttackConfig.Reward for the band.
	@param kind LaunchKind
	@param launcherLevel any — the attacker's effective level at launch
	@param targetIncome any — the target's $/s at launch
	@param attackerIncome any — the attacker's $/s at launch
	@param megaLauncher boolean — owns the Mega Launcher pass (x2)
	@return number — >= 0, finite
	Example: AttackLogic.reward("normal", 1, 100, 100, false) --> 2000
]]
function AttackLogic.reward(
	kind: LaunchKind,
	launcherLevel: unknown,
	targetIncome: unknown,
	attackerIncome: unknown,
	megaLauncher: boolean
): number
	local stats = AttackLogic.launcherStats(launcherLevel)
	local factors: { [string]: number } = AttackConfig.Reward.Factor :: any
	local factor = factors[kind]
	if stats == nil or type(factor) ~= "number" then
		return 0
	end
	local mine = math.max(num(attackerIncome, 0), 0)
	local theirs = math.max(num(targetIncome, 0), 0)
	local base = math.clamp(theirs, mine * AttackConfig.Reward.MinRatio, mine * AttackConfig.Reward.MaxRatio)
	local amount = stats.rewardSeconds * base * factor
	if megaLauncher == true then
		amount *= AttackConfig.Reward.MegaLauncherMultiplier
	end
	return if amount == amount and amount < math.huge then amount else 0
end

-- True when a shield is up at `now`.
function AttackLogic.shieldActive(shieldUntil: unknown, now: number): boolean
	return num(shieldUntil, 0) > now
end

--[[
	New shieldUntil after adding `seconds` of shield (stacks on an active one).
	@param shieldUntil any — current value
	@param now number — server time
	@param seconds number
	@return number — whole seconds (profile timestamps are whole)
	Example: AttackLogic.addShield(0, 1000, 600) --> 1600
]]
function AttackLogic.addShield(shieldUntil: unknown, now: number, seconds: number): number
	local base = math.max(num(shieldUntil, 0), now)
	return math.ceil(base + math.max(num(seconds, 0), 0))
end

-- True when enough hits were taken to activate the free shield.
function AttackLogic.freeShieldReady(hitsTaken: unknown): boolean
	return num(hitsTaken, 0) >= AttackConfig.FreeShieldHits
end

-- Shield seconds still held at `now` (0 when none).
function AttackLogic.shieldRemaining(shieldUntil: unknown, now: number): number
	return math.max(num(shieldUntil, 0) - now, 0)
end

--[[
	True when the free shield (FreeShieldSeconds) fits on top of the shield already held without
	passing MaxShieldSeconds — the same 48 h cap the paid Shield product obeys (security audit,
	Q2 2026-10-30: the free shield used to stack past it). When it does not fit, the earned hits
	are kept for later.
	@param shieldUntil any — current value
	@param now number — server time
	@return boolean
	Example: AttackLogic.freeShieldFits(0, 1000) --> true
]]
function AttackLogic.freeShieldFits(shieldUntil: unknown, now: number): boolean
	return AttackLogic.shieldRemaining(shieldUntil, now) + AttackConfig.FreeShieldSeconds
		<= AttackConfig.MaxShieldSeconds
end

--[[
	True when a Barrage pack of `nukes` may be PROMPTED: it must fit under MaxStoredBarrage, so a
	player is refused before paying instead of receiving fewer nukes than bought (security audit).
	Granted receipts are never clamped (AttackProfile.addBarrage).
	@param stored any — stored Barrage nukes now
	@param nukes any — the pack size (MonetizationConfig Barrage.nukes)
	@return boolean
	Example: AttackLogic.barrageFits(1990, 20) --> false; AttackLogic.barrageFits(1980, 20) --> true
]]
function AttackLogic.barrageFits(stored: unknown, nukes: unknown): boolean
	local have = math.max(math.floor(num(stored, 0)), 0)
	local pack = math.floor(num(nukes, 0))
	return pack >= 1 and have + pack <= AttackConfig.MaxStoredBarrage
end

--[[
	New cooldownUntil after a normal launch.
	@param now number — server time
	@param launcherLevel any — effective level
	@return number — whole seconds
]]
function AttackLogic.cooldownAfter(now: number, launcherLevel: unknown): number
	local stats = AttackLogic.launcherStats(launcherLevel)
	local seconds = if stats ~= nil then stats.cooldown else AttackConfig.Launcher[1].cooldown
	return math.ceil(now + seconds)
end

--[[
	True when `target` may be picked by anyone right now (the public "targetable" flag; shields are
	shown separately so the picker can say "Shielded"). Ignores who is attacking.
	@param target Actor
	@return (boolean, Reason?)
]]
function AttackLogic.isTargetable(target: Actor): (boolean, Reason?)
	if target.loaded ~= true or num(target.plot, 0) < 1 then
		return false, "target"
	end
	-- Owner R85: only brand-new players are protected (no area gate any more).
	if target.newbie == true then
		return false, "protected"
	end
	return true, nil
end

--[[
	The launch rule. `hasRevenge` = the attacker holds a live Revenge token against this target.
	Order: attacker can attack at all → target exists / not self → kind rules.
		normal   console, target targetable, no shield, off cooldown
		barrage  console, target targetable, no shield, >= 1 stored barrage nuke (no cooldown)
		revenge  a live token; ignores the cooldown and the target's shield (never vs a Rival)
	@param attacker Actor
	@param target Actor?
	@param kind LaunchKind
	@param now number — server time
	@param hasRevenge boolean
	@return (boolean, Reason?)
	Example: AttackLogic.canLaunch(me, them, "normal", now, false) --> false, "cooldown"
]]
function AttackLogic.canLaunch(
	attacker: Actor,
	target: Actor?,
	kind: LaunchKind,
	now: number,
	hasRevenge: boolean
): (boolean, Reason?)
	if attacker.loaded ~= true or num(attacker.plot, 0) < 1 then
		return false, "locked"
	end
	if target == nil or target.userId == attacker.userId or target.loaded ~= true or num(target.plot, 0) < 1 then
		return false, "target"
	end
	if kind == "revenge" then
		if hasRevenge == true then
			return true, nil
		end
		return false, "target"
	end
	-- Owner R85: every player has a launcher (no Attack Console needed to attack).
	if level(attacker.launcher) < 1 then
		return false, "locked"
	end
	local targetable, reason = AttackLogic.isTargetable(target)
	if not targetable then
		return false, reason
	end
	if AttackLogic.shieldActive(target.shieldUntil, now) then
		return false, "shield"
	end
	if kind == "normal" then
		if num(attacker.cooldownUntil, 0) > now then
			return false, "cooldown"
		end
		return true, nil
	elseif kind == "barrage" then
		if math.floor(num(attacker.barrage, 0)) < 1 then
			return false, "empty"
		end
		return true, nil
	elseif kind == "golden" then
		-- Owner R85: a stored golden revenge nuke — no cooldown, any targetable, unshielded target.
		if math.floor(num(attacker.golden, 0)) < 1 then
			return false, "empty"
		end
		return true, nil
	end
	return false, "locked"
end

-- Player-facing text for a refusal (toasts + picker hints).
local REASON_TEXT: { [string]: string } = {
	target = "That player can't be targeted right now.",
	protected = "They're still new - give them a few minutes!",
	shield = "Their shield bubble is up!",
	cooldown = "Your launcher is reloading...",
	locked = "Claim your plot first!",
	empty = "No Barrage nukes left - grab a Barrage!",
	rate = "Whoa, slow down!",
	aim = "Aim at one of their built areas!",
}

--[[
	The toast text for a refusal reason.
	@param reason any
	@return string
]]
function AttackLogic.reasonText(reason: unknown): string
	return if type(reason) == "string" and REASON_TEXT[reason] ~= nil
		then REASON_TEXT[reason]
		else "Can't launch right now."
end

-- The analytics label of a refusal ("refused:<cooldown|protected|shield|target|rate|locked|other>").
function AttackLogic.analyticsReason(reason: unknown): string
	if
		reason == "cooldown"
		or reason == "protected"
		or reason == "shield"
		or reason == "target"
		or reason == "rate"
		or reason == "locked"
	then
		return reason :: string
	end
	return "other"
end

--[[
	Which silos (1..3) can launch: silo k needs its pad (AttackConfig.Geometry.SiloPads[k]).
	Silo 1 is always available once the attacker can launch at all (a revenge launch from a player
	whose silo pad is not built yet rises from the silo 1 spot).
	@param pads { [string]: any }? — profile.tycoon.pads
	@return { number } — available silo indices, never empty
]]
function AttackLogic.silos(pads: { [string]: any }?): { number }
	local available = { 1 }
	if type(pads) == "table" then
		for index = 2, #AttackConfig.Geometry.SiloPads do
			if pads[AttackConfig.Geometry.SiloPads[index]] == true then
				table.insert(available, index)
			end
		end
	end
	return available
end

--------------------------------------------------------------------------------------------------
-- Rival Factories (owner R43): NPC targets judged by the SAME rules as players
--------------------------------------------------------------------------------------------------

local RIVALS = AttackConfig.Rivals
-- Wire id → rival index (the AttackLaunch allowlist for string targets).
local RIVAL_INDEX: { [string]: number } = {}
local rivalIds: { string } = {}
for index, rival in RIVALS.List do
	RIVAL_INDEX[rival.id] = index
	table.insert(rivalIds, rival.id)
end
-- Every rival wire id in picker order (also the analytics <rivalId> allowlist).
AttackLogic.RivalIds = table.freeze(rivalIds)

--[[
	The rival index for a wire id (exact allowlist match; any other value → nil).
	@param id any — the client-supplied target id
	@return number?
	Example: AttackLogic.rivalIndex("toy_factory") --> 1
]]
function AttackLogic.rivalIndex(id: unknown): number?
	if type(id) ~= "string" or #id > 32 then
		return nil
	end
	return RIVAL_INDEX[id]
end

--[[ The rival definition at `index` (whole 1..#Rivals.List), else nil. ]]
function AttackLogic.rival(index: unknown): AttackConfig.RivalDef?
	if type(index) ~= "number" or index ~= index or index % 1 ~= 0 then
		return nil
	end
	return RIVALS.List[index]
end

--[[
	Server time the rival's current shield bubble ends (0 = no bubble at `now`). Deterministic from
	the shared server clock, so the server (launch rule, dome) and every client (picker countdown)
	agree with no network traffic: cycle position p = (now + offset) mod every, a bubble is up
	while p < lasts.
	@param index any — rival index
	@param now number — server time
	@return number
	Example: shield { every = 240, lasts = 30, offset = 0 }, now = 4810 → p = 10 → 4830
]]
function AttackLogic.rivalShieldUntil(index: unknown, now: number): number
	local rival = AttackLogic.rival(index)
	if rival == nil then
		return 0
	end
	local shield = rival.shield
	if shield.every <= 0 or shield.lasts <= 0 then
		return 0
	end
	local t = num(now, 0)
	local position = (t + shield.offset) % shield.every
	if position < shield.lasts then
		return t - position + shield.lasts
	end
	return 0
end

--[[
	A rival as an Actor, so canLaunch applies the player rules unchanged: always loaded on its
	island slot and past Launch Silos, shielded per its cycle, userId 0 (never a player, so never
	"self" and never a Revenge token holder — a "revenge" launch at a rival is refused).
	@param index number — rival index
	@param slot number — its target slot (AttackGeometry.rivalSlot(index))
	@param now number — server time
	@return Actor? — nil for an unknown index
]]
function AttackLogic.rivalActor(index: number, slot: number, now: number): Actor?
	if AttackLogic.rival(index) == nil then
		return nil
	end
	return {
		userId = 0,
		loaded = true,
		plot = slot,
		area = AttackConfig.UnlockArea,
		console = false,
		launcher = 0,
		cooldownUntil = 0,
		shieldUntil = AttackLogic.rivalShieldUntil(index, now),
		barrage = 0,
		newbie = false,
		golden = 0,
	}
end

--[[
	Reward of one hit on a rival: rewardSeconds(launcher) x the ATTACKER's income x rewardRatio
	(clamped to Rivals.MaxRewardRatio) x factor(kind) x MegaLauncher. Revenge never applies (0).
	Always below the same hit on an equal-income player (tests).
	@return number — >= 0, finite
	Example: AttackLogic.rivalReward("normal", 1, 1, 1000, false) --> 8 x 1000 x 0.2 = 1600
]]
function AttackLogic.rivalReward(
	kind: LaunchKind,
	launcherLevel: unknown,
	index: unknown,
	attackerIncome: unknown,
	megaLauncher: boolean
): number
	local rival = AttackLogic.rival(index)
	local stats = AttackLogic.launcherStats(launcherLevel)
	local factors: { [string]: number } = AttackConfig.Reward.Factor :: any
	local factor = factors[kind]
	if rival == nil or stats == nil or kind == "revenge" or type(factor) ~= "number" then
		return 0
	end
	local mine = math.max(num(attackerIncome, 0), 0)
	local ratio = math.clamp(num(rival.rewardRatio, 0), 0, RIVALS.MaxRewardRatio)
	local amount = stats.rewardSeconds * mine * ratio * factor
	if megaLauncher == true then
		amount *= AttackConfig.Reward.MegaLauncherMultiplier
	end
	return if amount == amount and amount < math.huge then amount else 0
end

--[[
	Target picker order (owner R43: the list is never empty and never unexplained), lower first:
		1 Revenge-ready players, 2 eligible players, 3 shielded players (greyed, with a countdown),
		4 protected players (greyed, "still new"), then 100 + i for Rival Factory i (config order,
		easiest first). Ties are sorted by name by the caller.
	@param rivalIndex number? — the rival's index, nil for a player
	@param status string — the player's picker status ("revenge" | "ready" | "shield" | "protected")
	@return number
]]
function AttackLogic.pickerRank(rivalIndex: number?, status: string): number
	if rivalIndex ~= nil then
		return 100 + rivalIndex
	end
	if status == "revenge" then
		return 1
	elseif status == "ready" then
		return 2
	elseif status == "shield" then
		return 3
	end
	return 4
end

--------------------------------------------------------------------------------------------------
-- Aiming (owner R50): pure helpers shared by the server (decides) and the picker (displays)
--------------------------------------------------------------------------------------------------

--[[
	The scatter offset of one nuke around the aimed area centre: a uniform point in a disc whose
	radius shrinks with the launcher level (Aim.Scatter), smaller on a Rival section. `u` and `v`
	are the nuke's seeded uniforms in [0, 1) (AttackRng), so the server alone decides it.
	@param launcherLevel any
	@param u number, v number — uniforms in [0, 1)
	@param rival boolean — a Rival Factory section (RivalScatterScale)
	@return (number, number) — sx, sz in studs
	Example: AttackLogic.scatter(5, 0.25, 0.5, false) --> about (-4, 0) (radius 8 x sqrt(0.25))
]]
function AttackLogic.scatter(launcherLevel: unknown, u: number, v: number, rival: boolean): (number, number)
	local aim = AttackConfig.Aim
	local index = math.max(level(launcherLevel), 1)
	local radius = (aim.Scatter[index] or aim.Scatter[1]) * (if rival then aim.RivalScatterScale else 1)
	local r = radius * math.sqrt(math.clamp(num(u, 0), 0, 1))
	local angle = 2 * math.pi * math.clamp(num(v, 0), 0, 1)
	return r * math.cos(angle), r * math.sin(angle)
end

--[[
	Encodes built areas for the public Player attribute Attr.Areas ("1,2,5"); ascending, whole,
	1..99 only.
	@param areas { number }
	@return string
]]
function AttackLogic.encodeAreas(areas: { number }): string
	local parts: { string } = {}
	for _, area in areas do
		if type(area) == "number" and area % 1 == 0 and area >= 1 and area <= 99 then
			table.insert(parts, tostring(area))
		end
	end
	return table.concat(parts, ",")
end

--[[
	Decodes Attr.Areas (any value; junk entries are dropped, at most 16 areas, sorted).
	@param text any
	@return { number }
	Example: AttackLogic.decodeAreas("3,1,x,2") --> { 1, 2, 3 }
]]
function AttackLogic.decodeAreas(text: unknown): { number }
	local areas: { number } = {}
	if type(text) ~= "string" or #text > 64 then
		return areas
	end
	for part in string.gmatch(text, "[^,]+") do
		local area = tonumber(part)
		if area ~= nil and area % 1 == 0 and area >= 1 and area <= 99 and not table.find(areas, area) then
			table.insert(areas, area)
			if #areas >= 16 then
				break
			end
		end
	end
	table.sort(areas)
	return areas
end

--[[
	The area a launch aims at: the requested one when it is built, the default (the target's
	highest built area — usually its biggest earner) when none was requested; nil when the
	request names an area that is not built (refused) or nothing is built.
	@param built { number } — the target's built areas
	@param requested any — the client's aim (nil / 0 = default)
	@return number?
]]
function AttackLogic.resolveAim(built: { number }, requested: unknown): number?
	if requested == nil or requested == 0 then
		local best: number? = nil
		for _, area in built do
			if best == nil or area > best then
				best = area
			end
		end
		return best
	end
	if type(requested) ~= "number" or requested % 1 ~= 0 then
		return nil
	end
	return if table.find(built, requested) ~= nil then requested else nil
end

--[[
	Barrage spill (owner R50): the ONE built neighbour (aim - 1 or aim + 1) a volley may spill into,
	picked with uniform `u`; nil when neither neighbour is built.
	@param built { number }, aim number, u number
	@return number?
]]
function AttackLogic.spillNeighbour(built: { number }, aim: number, u: number): number?
	local options: { number } = {}
	for _, area in { aim - 1, aim + 1 } do
		if table.find(built, area) ~= nil then
			table.insert(options, area)
		end
	end
	if #options == 0 then
		return nil
	end
	return options[math.clamp(math.floor(num(u, 0) * #options) + 1, 1, #options)]
end

return AttackLogic
