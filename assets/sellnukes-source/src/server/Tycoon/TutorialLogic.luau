--!strict
--[[
	TutorialLogic — the server-tracked tutorial (spec: "the tutorial is the first area itself").

	Purpose
		The Garage Lab teaches the loop: build the Workbench, click it, upgrade it, buy pads, hire the
		Manager, open the Nuke Stand. The server derives the current step from the player's REAL
		state (pads owned, producer level, clicks), stores the furthest step in
		profile.tycoon.tutorialStep (monotonic: a rebirth never restarts it) and sends TutorialState
		to the client, which draws the objective chip + arrow (B6 keeps the texts client-side and
		can fall back to `text`). Pure: no Instances, runs under Lune.

	Steps (index = TutorialState.step; target = what the arrow points at):
		1 pad     a1_workbench        Step on the glowing pad to build your Workbench!
		2 click   p1_workbench        Click your Workbench to make Pocket Nukes!
		3 upgrade p1_workbench        Press UPGRADE to earn more per nuke!      (level >= 2)
		4 pad     a1_tool_wall        Buy the Tool Wall!
		5 pad     a1_glow_lamp        The Glow Lamp doubles your cash!
		6 pad     a1_uncle_atom       Hire Uncle Atom - he makes nukes for you, even offline!
		7 pad     <next pad>          Save up and open the Nuke Stand!          (until a1_open_stand)
		done      TutorialState { step = 0, done = true }
	Stored value: 0 = never started, 1..7 = current step, DoneStep (8) = finished. The step numbers
	keep their meaning across builds (analytics `tut:<n>`, profile.tycoon.tutorialStep).

	Owner R122 (2026-11-01, spec §2.2): Uncle Atom (the first Manager) is pad 4 of the Garage Lab
	now, right after the Glow Lamp, so step 6 points straight at his pad (it was a chain through
	Garage Door .. Paint Station: ~11 min of hand-clicking and a 74 % drop between step 6 and 7).
	The line sells the idle hook — automation + offline earnings — in the two lines a phone chip
	shows (HudObjective wraps to 2 lines, then truncates; measured in FredokaOne 30 px: ~410 of the
	~426 px a phone line holds). An old-order save that already owns later pads still lands on
	step 6 until it hires Uncle Atom (his pad is offered next to its next pad), and on step 7 the
	chain then walks whatever pads it still lacks.

	Usage
		local step = TutorialLogic.evaluate(profile.tycoon, profile.stats.clicks, profile.tycoon.tutorialStep)
		Remotes.fireClient("TutorialState", player, TutorialLogic.payload(step, profile.tycoon))
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonTypes = require(ReplicatedStorage.Shared.Tycoon.TycoonTypes)

type TycoonState = TycoonTypes.TycoonState

export type StepKind = "pad" | "click" | "upgrade"
export type Step = {
	kind: StepKind,
	pad: string?, -- "pad": this pad; a chain step points at the next pad until `pad` is owned
	chain: boolean?,
	producer: string?, -- "click" / "upgrade"
	level: number?, -- "upgrade": level to reach
	text: string,
}
-- `padId` / `producerId` repeat `target` under the names B6's client parses.
export type Payload = {
	step: number,
	done: boolean,
	kind: StepKind?,
	target: string?,
	padId: string?,
	producerId: string?,
	text: string?,
}

local TutorialLogic = {}

TutorialLogic.Steps = table.freeze({
	{ kind = "pad", pad = "a1_workbench", text = "Step on the glowing pad to build your Workbench!" },
	{ kind = "click", producer = "p1_workbench", text = "Click your Workbench to make Pocket Nukes!" },
	{ kind = "upgrade", producer = "p1_workbench", level = 2, text = "Press UPGRADE to earn more per nuke!" },
	{ kind = "pad", pad = "a1_tool_wall", text = "Buy the Tool Wall!" },
	{ kind = "pad", pad = "a1_glow_lamp", text = "The Glow Lamp doubles your cash!" },
	-- R122: a direct pad step (Uncle Atom is pad 4), no longer a chain through four pads.
	{ kind = "pad", pad = "a1_uncle_atom", text = "Hire Uncle Atom - he makes nukes for you, even offline!" },
	{ kind = "pad", pad = "a1_open_stand", chain = true, text = "Save up and open the Nuke Stand!" },
} :: { Step })

-- Stored step value meaning "finished".
TutorialLogic.DoneStep = #TutorialLogic.Steps + 1

-- True when step `step` is complete for this state.
local function isDone(step: Step, tycoon: TycoonState, clicks: number): boolean
	if step.kind == "pad" then
		return TycoonLogic.ownsPad(tycoon, step.pad)
	elseif step.kind == "click" then
		-- Any later progress on the producer implies the player has clicked it.
		return clicks >= 1 or TycoonLogic.levelOf(tycoon, step.producer) >= 2
	end
	return TycoonLogic.levelOf(tycoon, step.producer) >= (step.level or 2)
end

--[[
	The step the player is on: the first unfinished step, never lower than `stored` (monotonic, so
	a rebirth or admin reset does not restart a finished tutorial).
	@param tycoon TycoonState
	@param clicks number — profile.stats.clicks (lifetime manual clicks)
	@param stored number — profile.tycoon.tutorialStep
	@return number — 1..#Steps, or DoneStep
]]
function TutorialLogic.evaluate(tycoon: TycoonState, clicks: number, stored: number): number
	local current = TutorialLogic.DoneStep
	for index, step in TutorialLogic.Steps do
		if not isDone(step, tycoon, clicks) then
			current = index
			break
		end
	end
	local safeStored = if type(stored) == "number" and stored == stored then math.floor(stored) else 0
	return math.clamp(math.max(current, safeStored), 1, TutorialLogic.DoneStep)
end

--[[
	The TutorialState payload for a step.
	@param step number — from evaluate
	@param tycoon TycoonState — resolves chain steps to the current next pad
	@return Payload — { step = 0, done = true } once finished
]]
function TutorialLogic.payload(step: number, tycoon: TycoonState): Payload
	local def = TutorialLogic.Steps[step]
	if def == nil then
		return { step = 0, done = true }
	end
	local target: string? = def.pad or def.producer
	if def.chain then
		local nextPad = TycoonLogic.nextPads(tycoon)[1]
		target = if nextPad ~= nil then nextPad.id else def.pad
	end
	return {
		step = step,
		done = false,
		kind = def.kind,
		target = target,
		padId = if def.kind == "pad" then target else nil,
		producerId = if def.kind ~= "pad" then target else nil,
		text = def.text,
	}
end

return TutorialLogic
