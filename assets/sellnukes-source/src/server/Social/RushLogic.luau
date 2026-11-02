--!strict
--[[
	RushLogic — the PURE rules of the R78 Rush boosts (spec §3; docs/social.md). No services, no
	yields, no clocks: every function takes `now` (server os.time()) so Lune proves the edges
	(tests/social-logic.luau).

	Rookie Rush
		A brand-new profile gets `rookieLeft` = RookieMinutes * 60 seconds ONCE (grantRookie). The
		seconds count down only while the player is online: RushService turns the saved seconds into
		a session end time (`sessionEndsAt`) when the profile loads and writes what is left back
		(`consume`) every SyncSeconds, at leave and before a New Player Mode swap. A rejoin
		therefore continues exactly where the last session stopped.
	Comeback Rush
		On a JOIN whose previous save (profile.offline.lastSeenAt, the server's own clock) is at
		least ComebackAwayHours old, the player gets `comebackUntil` = now + ComebackMinutes * 60
		(wall clock; leaving and coming back inside the window keeps the rest). A brand-new profile
		(lastSeenAt 0) is never a comeback. A player whose Rookie Rush still covers the comeback
		window gets no comeback (the two never stack: `multiplier` takes the larger one).

	Connects to: Shared/Config/SocialConfig (RushState, tunables), Server/Services/RushService,
	tests/social-logic.luau.

	Example:
		local state = SocialConfig.newRush()
		RushLogic.grantRookie(state, 900)                        --> true (rookieLeft = 900)
		local endsAt = RushLogic.sessionEndsAt(state, 1000)      --> 1900
		RushLogic.consume(state, endsAt, 1300)                   --> 600 (rookieLeft = 600)
		RushLogic.multiplier(endsAt, 0, 1300, { rookie = 2, comeback = 2 }) --> 2, 1900, "rookie"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)

type RushState = SocialConfig.RushState

-- The two multipliers (SocialConfig.Rush.RookieMultiplier / ComebackMultiplier).
export type Rates = { rookie: number, comeback: number }

-- Which rush decides the current multiplier ("none" = neutral).
export type Kind = "none" | "rookie" | "comeback"

local RushLogic = {}

-- A finite number, else nil.
local function finite(value: unknown): number?
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

-- The longest rush ever granted (SocialConfig.Rush.MaxMinutes) in seconds.
local MAX_SECONDS = SocialConfig.Rush.MaxMinutes * 60

--[[
	Grants the Rookie Rush: rookieLeft becomes `seconds` (never shortens a longer one).
	@param state RushState (profile.rush; mutated)
	@param seconds number — whole seconds, clamped to [0, MaxMinutes * 60]
	@return true when the state changed
	Example: RushLogic.grantRookie(state, 900) --> true
]]
function RushLogic.grantRookie(state: RushState, seconds: number): boolean
	local amount = finite(seconds)
	if amount == nil or amount <= 0 then
		return false
	end
	local value = math.clamp(math.floor(amount), 0, MAX_SECONDS)
	if value <= state.rookieLeft then
		return false
	end
	state.rookieLeft = value
	return true
end

--[[
	Seconds the player was away (now - lastSeenAt), or nil when there is no usable previous save
	(a brand-new profile, a corrupted stamp, or a stamp in the future).
	Example: RushLogic.awaySeconds(1000, 5000) --> 4000 ; RushLogic.awaySeconds(0, 5000) --> nil
]]
function RushLogic.awaySeconds(lastSeenAt: unknown, now: number): number?
	local seen = finite(lastSeenAt)
	if seen == nil or seen <= 0 or seen > now then
		return nil
	end
	return now - seen
end

--[[
	Whether a JOIN earns a Comeback Rush.
	@param state RushState — the loaded profile.rush (a Rookie Rush that still covers the comeback
	       window blocks it: no stacking, no wasted minutes)
	@param lastSeenAt any — profile.offline.lastSeenAt BEFORE this join re-stamped it
	@param now number — server os.time()
	@param awayHours number — SocialConfig.Rush.ComebackAwayHours
	@param comebackSeconds number — the window that would be granted
	@return (due: boolean, away: number?) — away = seconds since the last save (nil = never seen)
	Example: RushLogic.comebackDue(state, now - 48 * 3600, now, 48, 600) --> true, 172800
]]
function RushLogic.comebackDue(
	state: RushState,
	lastSeenAt: unknown,
	now: number,
	awayHours: number,
	comebackSeconds: number
): (boolean, number?)
	local away = RushLogic.awaySeconds(lastSeenAt, now)
	if away == nil then
		return false, nil
	end
	if away < awayHours * 3600 then
		return false, away
	end
	if state.rookieLeft >= comebackSeconds then
		return false, away
	end
	return true, away
end

--[[
	Grants (or extends) the Comeback Rush to end at now + seconds; never shortens a later end.
	@return the new comebackUntil
	Example: RushLogic.grantComeback(state, 1000, 600) --> 1600
]]
function RushLogic.grantComeback(state: RushState, now: number, seconds: number): number
	local amount = finite(seconds)
	if amount ~= nil and amount > 0 then
		local untilTime = now + math.clamp(math.floor(amount), 0, MAX_SECONDS)
		if untilTime > state.comebackUntil then
			state.comebackUntil = untilTime
		end
	end
	return state.comebackUntil
end

--[[
	The session end time of a saved Rookie Rush (nil when none is left).
	Example: RushLogic.sessionEndsAt({ rookieLeft = 300, comebackUntil = 0 }, 1000) --> 1300
]]
function RushLogic.sessionEndsAt(state: RushState, now: number): number?
	if state.rookieLeft <= 0 then
		return nil
	end
	return now + state.rookieLeft
end

--[[
	Writes what is left of a running Rookie Rush back into the saved seconds.
	@param state RushState (mutated)
	@param endsAt number? — the session end time (nil = no rookie running: rookieLeft unchanged)
	@param now number
	@return rookieLeft after the write (whole seconds, rounded UP so a partial second is kept)
	Example: RushLogic.consume(state, 1300, 1000.2) --> 300
]]
function RushLogic.consume(state: RushState, endsAt: number?, now: number): number
	if endsAt == nil then
		return state.rookieLeft
	end
	local left = math.clamp(math.ceil(endsAt - now), 0, MAX_SECONDS)
	state.rookieLeft = left
	return left
end

--[[
	The rush multiplier right now (Rookie and Comeback never stack: the larger one applies).
	@param rookieEndsAt number? — the running Rookie Rush's session end (nil = none / paused)
	@param comebackUntil number — profile.rush.comebackUntil
	@param now number
	@param rates Rates
	@return (multiplier >= 1, validUntil?: the soonest moment the answer can change, kind)
	Example: RushLogic.multiplier(nil, 1600, 1000, { rookie = 2, comeback = 2 }) --> 2, 1600, "comeback"
]]
function RushLogic.multiplier(
	rookieEndsAt: number?,
	comebackUntil: number,
	now: number,
	rates: Rates
): (number, number?, Kind)
	local best, kind = 1, "none" :: Kind
	local validUntil: number? = nil
	local rookieRate = math.max(1, finite(rates.rookie) or 1)
	local comebackRate = math.max(1, finite(rates.comeback) or 1)
	if rookieEndsAt ~= nil and rookieEndsAt > now then
		best, kind = rookieRate, "rookie"
		validUntil = rookieEndsAt
	end
	if comebackUntil > now then
		if comebackRate > best then
			best, kind = comebackRate, "comeback"
		end
		validUntil = if validUntil == nil then comebackUntil else math.min(validUntil, comebackUntil)
	end
	return best, validUntil, kind
end

return table.freeze(RushLogic)
