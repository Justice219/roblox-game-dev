--!strict
--[[
	NewPlayerFunnel — the SellNukes new-player (FTUE) funnel: step ids, labels and the report rows.
	Pure (no services): shared so the server report, the admin Analytics tab and lune tests agree.

	The funnel (ids in AnalyticsConfig.Ftue.Steps, append-only SAVE DATA order; read in
	AnalyticsConfig.Ftue.Order) follows the tycoon's first minutes: join → plot ready → loading
	done → saw the tutorial hint → first move (R78) → first pad (the free Workbench, tutorial step
	1) → first click → first payout → first upgrade → 5th pad → first Manager (automation; the end
	of the tutorial area's core lesson) → areas 2..5 → first rebirth; side steps (HUD shown, first
	window closed) are listed after it. Each step counts ONCE per tracked new
	player across sessions (profile.analytics.ftue bits; Server/Analytics/Runtime.markFtue), plus
	whether it happened in the FIRST session and after how many minutes of play.

	Connects to: AnalyticsConfig.Ftue, Server/Analytics/Runtime (markFtue), Sessions (client steps,
	ftueLeft / ftueLen at leave), ReportSections (the "New player funnel" tables).

	Example:
		NewPlayerFunnel.label("manager")  --> "Hired the first Manager (automation)"
		local rows = NewPlayerFunnel.rows(core, AnalyticsReport.formatPercent)
]]

local AnalyticsConfig = require(script.Parent.Parent.Config.AnalyticsConfig)

export type StepId = string

-- One report row (ReportSections turns it into a table entry).
export type Row = { id: string, label: string, value: number, display: string?, extra: string }

local NewPlayerFunnel = {}

NewPlayerFunnel.Steps = AnalyticsConfig.Ftue.Steps
NewPlayerFunnel.ClientSteps = AnalyticsConfig.Ftue.ClientSteps
-- Report order: the main path (AnalyticsConfig.Ftue.Order) then the side steps.
NewPlayerFunnel.SideSteps = AnalyticsConfig.Ftue.SideSteps
NewPlayerFunnel.Order = (function(): { string }
	local order = table.clone(AnalyticsConfig.Ftue.Order)
	for _, step in AnalyticsConfig.Ftue.SideSteps do
		table.insert(order, step)
	end
	return table.freeze(order)
end)()

-- Human labels per step id.
local LABELS: { [string]: string } = {
	joined = "Joined as a new player",
	loadingDone = "Loading screen finished (client)",
	plotReady = "Got a plot",
	firstPad = "Bought the first pad (Workbench)",
	firstClick = "Clicked the producer",
	firstCash = "First nukes sold (first payout)",
	firstUpgrade = "First producer upgrade",
	pad5 = "Bought 5 pads",
	manager = "Hired the first Manager (automation)",
	area2 = "Opened area 2 (Nuke Stand)",
	area3 = "Opened area 3 (BoomDash Delivery)",
	area4 = "Opened area 4 (Glow Rock Mine)",
	area5 = "Opened area 5 (Enrichment Lab)",
	firstRebirth = "First rebirth",
	hudShown = "HUD visible (client)",
	-- R78 §6 first-minute steps (client claims, server plausibility-checked).
	tutorialSeen = "Saw the tutorial hint (client)",
	firstMove = "Walked 12 studs on their plot (client)",
	firstScreenClosed = "Closed their first window (client)",
}

--[[ The display label of a step (the id itself for an unknown one). ]]
function NewPlayerFunnel.label(step: string): string
	return LABELS[step] or step
end

--[[ True when `raw` is a client-reported funnel step id. ]]
function NewPlayerFunnel.isClientStep(raw: unknown): boolean
	return type(raw) == "string" and table.find(AnalyticsConfig.Ftue.ClientSteps, raw) ~= nil
end

--[[
	Funnel rows from the summed core counters: per step its count, % of joined, % of the previous
	(main-path) step, the share reached in the first session and the average play minutes at reach.
	Rows follow the READING order (AnalyticsConfig.Ftue.Order: join → plot → loading done → saw the
	tutorial hint → first move → first pad → ...); side steps (hudShown, firstScreenClosed) are
	listed last without a previous-step ratio.
	@param core          summed core counters of a range
	@param formatPercent fraction → "12.5%" (AnalyticsReport.formatPercent)
	@return rows in funnel order
]]
function NewPlayerFunnel.rows(core: { [string]: number }, formatPercent: (number) -> string): { Row }
	local rows: { Row } = {}
	local joined = core["ftue:joined"] or 0
	local previous: number? = nil
	for _, step in NewPlayerFunnel.Order do
		local side = table.find(NewPlayerFunnel.SideSteps, step) ~= nil
		local value = core[`ftue:{step}`] or 0
		local firstSession = core[`ftueS1:{step}`] or 0
		local minutes = core[`ftueMin:{step}`] or 0
		local parts: { string } = {}
		if joined > 0 then
			table.insert(parts, `{formatPercent(value / joined)} of joined`)
		end
		if not side and previous ~= nil and previous > 0 then
			table.insert(parts, `{formatPercent(value / previous)} of previous step`)
		end
		if value > 0 then
			table.insert(parts, `{formatPercent(firstSession / value)} in session 1`)
			table.insert(parts, `avg {math.floor(minutes / value * 10 + 0.5) / 10} play-min`)
		end
		table.insert(rows, {
			id = step,
			label = NewPlayerFunnel.label(step),
			value = value,
			extra = table.concat(parts, " · "),
		})
		if not side then
			previous = value
		end
	end
	return rows
end

return table.freeze(NewPlayerFunnel)
