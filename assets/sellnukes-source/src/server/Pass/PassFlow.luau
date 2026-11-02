--!strict
--[[
	PassFlow — the PURE ordering rules between Nuke Pass XP and the season settle (rollover), so a
	quest claim / play tick can never settle a season with a GUESSED paid-random policy (lead review
	2026-10-31). Server/Services/PassService applies them; tests/pass-logic.luau §11 proves them.

	The race it closes: a season ended with unclaimed PREMIUM tiers holding spins / eggs; the buyer
	joins and PassService.settle waits (≤ 10 s) for PolicyService. If XP arrived meanwhile and
	settled immediately with the fail-closed answer, an ALLOWED player would get gems instead of
	spins / eggs and the waiting settle would find nothing left. So:

		decide(state, now, policyKnown, busy) →
			"settled"  nothing to roll over → XP applies directly
			"now"      settle right away (no premium spins / eggs owed, or the policy is known, so
			           the cached answer is exact) and nothing else is in flight
			"wait"     another settle / claim is in flight (busy), or the rollover owes premium
			           spins / eggs and the policy is not known yet → do NOT settle here; the
			           waiting settle (PassService.settle: resolve the policy, then settle) does it

	XP that arrives while the decision is "wait" is HELD (hold), never applied to the stale state
	and never dropped, then drained exactly once (drain) right after the settle / claim finishes and
	applied through the normal XP path:
		- a NEW season is active → the held XP lands in it (after the reset);
		- between seasons → the documented between-season rule drops it (addXp adds nothing).
	The hold queue is bounded (MaxHeld entries); a full queue refuses more (a flood of quest
	claims within one ≤ 10 s policy wait is not a real pattern).

	Example (PassService.giveXp):
		local decision = PassFlow.decide(profile.pass, at, policyKnown, busy[player] == true)
		if decision == "wait" then PassFlow.hold(heldXp[player], amount, source, at) return 0 end
		if decision == "now" then settleNow(player, profile, cachedAllow(player), at) end
		PassLogic.addXp(profile.pass, amount, source, at)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PassConfig = require(ReplicatedStorage.Shared.Config.PassConfig)
local PassLogic = require(ServerScriptService.Server.Pass.PassLogic)

export type Decision = "settled" | "now" | "wait"
export type HeldXp = { amount: number, source: string, at: number }

local PassFlow = {}

-- Most XP grants held per player while a settle waits for the policy.
PassFlow.MaxHeld = 64

--[[
	What to do about the season before applying XP / a claim (see the header).
	@param state the repaired profile.pass (never mutated)
	@param policyKnown PolicyService answered for this player
	@param busy a settle / claim of this player is in flight
]]
function PassFlow.decide(state: PassConfig.State, now: number, policyKnown: boolean, busy: boolean): Decision
	if not PassLogic.needsRollover(state, now) then
		return "settled"
	end
	if busy then
		return "wait"
	end
	if not policyKnown then
		local preview = PassLogic.rollover(PassLogic.clone(state), now)
		if PassLogic.needsPolicy(preview.grants) then
			return "wait"
		end
	end
	return "now"
end

--[[
	Holds one XP grant until the waiting settle has run.
	@return true when held (false: bad amount / the queue is full)
]]
function PassFlow.hold(queue: { HeldXp }, amount: number, source: string, at: number): boolean
	if type(amount) ~= "number" or amount ~= amount or amount < 1 or #queue >= PassFlow.MaxHeld then
		return false
	end
	table.insert(queue, { amount = math.floor(amount), source = source, at = at })
	return true
end

--[[ Takes every held grant out of the queue (oldest first); the queue is empty afterwards. ]]
function PassFlow.drain(queue: { HeldXp }): { HeldXp }
	local out = table.clone(queue)
	table.clear(queue)
	return out
end

return table.freeze(PassFlow)
