--!strict
--[[
	QuestOpenRules — when the Quests screen may open, as one PURE rule (no services; Lune-tested in
	tests/quest-logic.luau §11).

	Root cause it closes (P-pass Studio QA, 2026-10-31: "Quests opened by itself over the open
	NukePass window"): the objective chip's tap target lives on the HUD ScreenGui UNDER every
	window, and a window's plain Frames do not sink input, so a click on an open window's empty
	area right above the chip fell through to the chip and stacked Quests over that window. No code
	path auto-opens Quests: the only ways in are player intent — the HUD Quests button and the menu
	wheel (both replace any open window first), the WHAT'S NEW call-to-action (closes What's New
	first), and the chip tap. The chip is the only one that could land over another window, so
	its rule is the strict one:
		- never while ANY modal window is open (no stacking, no click-through),
		- never while the join flow guides the first minute (C-ftue's JoinFlow.guiding(): tutorial
		  steps 1-3) or the tutorial still owns the chip,
		- only while the chip is actually showing a quest objective.

	Example:
		local ok, why = QuestOpenRules.chip({ anyModalOpen = false, guiding = false, tutorialDone = true, shown = true })
		--> true, "ok"
]]

export type ChipContext = {
	anyModalOpen: boolean, -- ScreenManager.anyModalOpen()
	guiding: boolean, -- JoinFlow.guiding(): the guided first-minute tutorial steps
	tutorialDone: boolean, -- QuestConfig.facts(profile).tutorialDone
	shown: boolean, -- the chip shows a quest objective (HudObjective secondary layer)
}

export type Reason = "ok" | "modal" | "guiding" | "tutorial" | "hidden"

local QuestOpenRules = {}

--[[
	May a chip tap open Quests (and may the chip's tap target be live at all)?
	@return allowed, reason
]]
function QuestOpenRules.chip(context: ChipContext): (boolean, Reason)
	if context.shown ~= true then
		return false, "hidden"
	end
	if context.anyModalOpen ~= false then
		return false, "modal"
	end
	if context.guiding ~= false then
		return false, "guiding"
	end
	if context.tutorialDone ~= true then
		return false, "tutorial"
	end
	return true, "ok"
end

return table.freeze(QuestOpenRules)
