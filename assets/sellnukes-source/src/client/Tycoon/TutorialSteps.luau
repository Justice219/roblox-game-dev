--!strict
--[[
	TutorialSteps — what each server tutorial step looks like on the client: the objective text
	and what the arrow / beam points at.

	Purpose:
		The SERVER owns the tutorial (TutorialState { step }, persisted in profile.tycoon.tutorialStep)
		and decides when a step is complete; the client only renders the current one. Step 0, a
		negative step or any step past this list means "tutorial finished" (chip + beam hidden).
		Targets are symbolic so they survive pad / producer renames:
			{ kind = "producer", area = N }  the area's producer
			{ kind = "nextPad" }             the next pad the player can buy (TycoonLogic.nextPads)
			{ kind = "manager", area = N }   the Manager pad of the area's producer
			{ kind = "unlock", area = N }    the area's final (Unlock) pad
		`{producer}` in a text is replaced with the area-1 producer's display name.
		The server normally sends its own kind + target + text (Tycoon/Tutorial renders that); this
		table is the fallback for a payload without a kind, so it mirrors Server/Tycoon/TutorialLogic
		step for step (index = the server step number; `tut:<n>` analytics keep these meanings):
			1 the free Workbench pad   2 run the Workbench   3 upgrade it   4 Tool Wall
			5 Glow Lamp   6 hire Uncle Atom (the Manager, pad 4 since owner R122)   7 open the Nuke Stand

	Connects to: Tycoon/Tutorial (renders), Screens/TycoonTutorial (intro card on step 1).

	Example: TutorialSteps.get(6).target --> { kind = "manager", area = 1 } (Uncle Atom's pad)
]]

export type Target = {
	kind: "producer" | "nextPad" | "manager" | "unlock",
	area: number?,
}

export type Step = {
	text: string,
	target: Target?,
}

local TutorialSteps = {}

TutorialSteps.Steps = table.freeze({
	-- 1: walk onto the free Workbench pad (the next pad).
	table.freeze({
		text = "Step on the glowing pad to build your {producer}!",
		target = { kind = "nextPad" },
	}) :: Step,
	-- 2: run the Workbench once.
	table.freeze({
		text = "Click the {producer} to make Pocket Nukes!",
		target = { kind = "producer", area = 1 },
	}) :: Step,
	-- 3: buy its first level ($10, owner R65).
	table.freeze({
		text = "Upgrade your {producer}! (E / tap UPGRADE)",
		target = { kind = "producer", area = 1 },
	}) :: Step,
	-- 4 / 5: the Tool Wall and the Glow Lamp (each the next pad at that point).
	table.freeze({
		text = "Buy the Tool Wall!",
		target = { kind = "nextPad" },
	}) :: Step,
	table.freeze({
		text = "The Glow Lamp doubles your cash!",
		target = { kind = "nextPad" },
	}) :: Step,
	-- 6: owner R122 — Uncle Atom (the Manager) right after the Glow Lamp; same line as the server.
	table.freeze({
		text = "Hire Uncle Atom - he makes nukes for you, even offline!",
		target = { kind = "manager", area = 1 },
	}) :: Step,
	-- 7: keep buying the next pad up to the Unlock.
	table.freeze({
		text = "Save up and open the Nuke Stand!",
		target = { kind = "nextPad" },
	}) :: Step,
}) :: { Step }

--[[ The step definition for a server step number, or nil when the tutorial is over. ]]
function TutorialSteps.get(step: number): Step?
	if step ~= step or step < 1 or step ~= math.floor(step) then
		return nil
	end
	return TutorialSteps.Steps[step]
end

return table.freeze(TutorialSteps)
