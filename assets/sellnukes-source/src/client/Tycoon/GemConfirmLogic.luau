--!strict
--[[
	GemConfirmLogic — the kid-friendly confirm of the owner R86 gem upgrade, as a pure state machine
	(no Instances, no clock of its own: callers pass `now`). Unit-tested by tests/gem-upgrade.luau.

	Behaviour (exact):
		1. A press while nothing is armed ARMS that producer's gem button ("SURE? 75") and buys
		   nothing.
		2. A second press on the SAME producer within ConfirmSeconds (3 s) of arming BUYS one level
		   and disarms.
		3. After a gem buy, every press (any producer) within RepeatSeconds (6 s) of the LAST buy buys
		   straight away (no "SURE?" again while the player is clearly buying on purpose). Each buy
		   restarts that window.
		4. An armed button that is not pressed again within ConfirmSeconds disarms by itself
		   (`isArmed` turns false; the billboard re-renders on its own timer).
		5. A press on ANOTHER producer while one is armed moves the arm there (it does not buy).
	Presses the player cannot afford never reach this machine (the billboard plays the locked
	sound instead), so an unaffordable press neither arms nor starts the repeat window.

	Connects to: Tycoon/ProducerBillboards (gem button + the GemUpgrade action),
	Shared/Config/TycoonConfig (GemUpgrade.ConfirmSeconds / RepeatSeconds), tests/gem-upgrade.luau.

	Example:
		local state = GemConfirmLogic.new()
		GemConfirmLogic.press(state, "p1_workbench", 10, 3, 6) --> "arm"
		GemConfirmLogic.press(state, "p1_workbench", 11, 3, 6) --> "buy"
		GemConfirmLogic.press(state, "p2_stand", 14, 3, 6)     --> "buy" (within 6 s of the last buy)
]]

export type Action = "arm" | "buy"

export type State = {
	armedId: string?, -- the producer whose gem button shows "SURE?"
	armedAt: number, -- when it was armed
	lastBuyAt: number, -- when the last gem buy was sent (-inf = never)
}

local GemConfirmLogic = {}

--[[ A fresh state (nothing armed, no recent buy). ]]
function GemConfirmLogic.new(): State
	return { armedId = nil, armedAt = -math.huge, lastBuyAt = -math.huge }
end

--[[
	True while `id`'s gem button is armed at `now`.
	@param confirmSeconds how long an arm lasts
]]
function GemConfirmLogic.isArmed(state: State, id: string, now: number, confirmSeconds: number): boolean
	return state.armedId == id and now - state.armedAt <= confirmSeconds
end

--[[
	True while presses buy straight away (within `repeatSeconds` of the last buy).
]]
function GemConfirmLogic.inRepeat(state: State, now: number, repeatSeconds: number): boolean
	return now - state.lastBuyAt <= repeatSeconds
end

--[[
	One press of `id`'s gem button (see the module header).
	@return "arm" (show "SURE?", buy nothing) | "buy" (send one gem upgrade now)
]]
function GemConfirmLogic.press(
	state: State,
	id: string,
	now: number,
	confirmSeconds: number,
	repeatSeconds: number
): Action
	if
		GemConfirmLogic.inRepeat(state, now, repeatSeconds) or GemConfirmLogic.isArmed(state, id, now, confirmSeconds)
	then
		state.armedId = nil
		state.armedAt = -math.huge
		state.lastBuyAt = now
		return "buy"
	end
	state.armedId = id
	state.armedAt = now
	return "arm"
end

--[[ Drops any arm (e.g. the board went away). The repeat window is kept. ]]
function GemConfirmLogic.cancel(state: State)
	state.armedId = nil
	state.armedAt = -math.huge
end

return table.freeze(GemConfirmLogic)
