--!strict
--[[
	InviteLogic — the PURE rules of the owner R122 co-play surfaces (spec §2.4), Lune-tested by
	tests/invite-surface.luau:

		available(canSend)                 the HUD INVITE button / invite moment may show (Roblox
		                                   says this account / device may send invites)
		badgeText(live)                    the "+10%" sticker from the LIVE Friend Boost settings
		                                   (nil while the boost is off)
		newMoment(now) / noteProgress(...) the once-per-session moment state: when area 2 became
		momentDueAt(state, cfg?)           unlocked and when the card may show
		momentGate(context)                may it show right now (invites available, no friend here,
		                                   no tutorial step, not shown this session)
		markShown(state)                   the card showed (never again this session)

	Connects to: Shared/Config/InviteConfig, Client/Social/InviteClient (the runtime: clock,
	profile, friends), UI/Hud/HudInvite, UI/Screens/InviteMoment.

	Example:
		local moment = InviteLogic.newMoment(0)
		InviteLogic.noteProgress(moment, true, 0, true)      -- already past area 2 at join
		InviteLogic.momentDueAt(moment)                       --> 180 (MinSessionSeconds)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InviteConfig = require(ReplicatedStorage.Shared.Config.InviteConfig)

export type MomentState = {
	joinedAt: number, -- session start (client clock)
	eligibleAt: number?, -- when area MinArea was first seen unlocked this session
	unlockedHere: boolean, -- that unlock happened during this session (not already at join)
	shown: boolean, -- the card showed this session
}

export type MomentConfig = {
	AfterUnlockSeconds: number,
	MinSessionSeconds: number,
}

export type GateContext = {
	available: boolean, -- InviteLogic.available(...)
	friendsHere: number, -- Roblox friends in this server (Friend Boost count)
	tutorial: boolean, -- a tutorial step is running
}

export type Refusal = "shown" | "unavailable" | "friends" | "tutorial"

-- The admin-overridable Friend Boost settings the sticker reads (SocialConfig.Live subset).
export type BoostLive = { friendsOn: boolean, friendPercent: number }

local InviteLogic = {}

--[[
	True when invites can be sent: Roblox answered CanSendGameInviteAsync = true. Unknown (still
	asking / the call failed) counts as unavailable, so the button never shows a dead end.
	Example: InviteLogic.available(nil) --> false
]]
function InviteLogic.available(canSend: boolean?): boolean
	return canSend == true
end

--[[
	The sticker text: the live percent per friend ("+10%"), nil while the Friend Boost is off or
	the percent is not a positive whole number.
	Example: InviteLogic.badgeText({ friendsOn = true, friendPercent = 10 }) --> "+10%"
]]
function InviteLogic.badgeText(live: BoostLive): string?
	local percent = live.friendPercent
	if not live.friendsOn or type(percent) ~= "number" or percent ~= percent or percent <= 0 then
		return nil
	end
	return string.format(InviteConfig.Hud.BadgeFormat, math.floor(percent + 0.5))
end

--[[ A fresh session's moment state (the session started at `now`). ]]
function InviteLogic.newMoment(now: number): MomentState
	return { joinedAt = now, eligibleAt = nil, unlockedHere = false, shown = false }
end

--[[
	Feeds the player's progress: `unlocked` = area MinArea is unlocked (or they rebirthed before).
	The FIRST time it is true sets eligibleAt; `atJoin` says whether that was the first look at the
	profile (already unlocked when the session started) or an unlock during play.
	@return the same state (mutated)
]]
function InviteLogic.noteProgress(state: MomentState, unlocked: boolean, now: number, atJoin: boolean): MomentState
	if unlocked and state.eligibleAt == nil then
		state.eligibleAt = now
		state.unlockedHere = not atJoin
	end
	return state
end

--[[
	When the moment may show (client clock), or nil: already shown / not eligible yet. It is the
	later of MinSessionSeconds into the session and (an unlock during this session)
	AfterUnlockSeconds after that unlock.
	Example: InviteLogic.momentDueAt({ joinedAt = 0, eligibleAt = 400, unlockedHere = true, shown = false })
	         --> 490
]]
function InviteLogic.momentDueAt(state: MomentState, cfg: MomentConfig?): number?
	local moment: MomentConfig = cfg or (InviteConfig.Moment :: any)
	local eligible = state.eligibleAt
	if state.shown or eligible == nil then
		return nil
	end
	local due = state.joinedAt + moment.MinSessionSeconds
	if state.unlockedHere then
		due = math.max(due, eligible + moment.AfterUnlockSeconds)
	end
	return math.max(due, eligible)
end

--[[
	May the moment show right now (its due time has passed)?
	@return (ok, refusal?) — "shown" | "unavailable" | "friends" | "tutorial"
]]
function InviteLogic.momentGate(state: MomentState, context: GateContext): (boolean, Refusal?)
	if state.shown then
		return false, "shown"
	end
	if not context.available then
		return false, "unavailable"
	end
	if context.friendsHere > 0 then
		return false, "friends"
	end
	if context.tutorial then
		return false, "tutorial"
	end
	return true, nil
end

--[[ The card showed: it never shows again this session. ]]
function InviteLogic.markShown(state: MomentState)
	state.shown = true
end

return table.freeze(InviteLogic)
