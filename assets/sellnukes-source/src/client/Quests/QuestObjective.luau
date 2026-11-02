--!strict
--[[
	QuestObjective — what the HUD's bottom-centre objective chip says once the Nuke Town tutorial
	is done (owner R78 Quests, spec §1.2): the current starter goal with a progress bar and a guide
	arrow to the right pad / producer where one exists; after goal 12, the first unfinished daily
	mission; else nothing. It only feeds HudObjective's SECONDARY layer, so the tutorial (primary,
	Hud.setObjective) and every non-main world's WorldObjectives chip (primary,
	Hud.setWorldObjective) always win; outside Nuke Town this publishes nothing at all.

	Inputs: the QuestClient view (profile.quests + facts, recomputed on every relevant profile push),
	the CurrentWorld player attribute, and TycoonWorld's streaming signals (a pad / producer that
	streams in, a respawn) to re-resolve the arrow target. Updates are coalesced to one per frame.

	Guide targets (QuestConfig.Goal.guide): "pad" → the next pad in the buy chain
	(TycoonLogic.nextPads), "manager" → the first buyable Manager pad (else the chain's next pad,
	which leads to it), "producer" → that producer (the Workbench), "bestProducer" → the highest
	level producer. Daily missions: pad → next pad, upgrade → best producer, others none.

	The chip is tappable (touch / mouse) and opens Quests with analytics source "chip".

	Connects to: UI/Hud/HudObjective (setSecondary), UI/ScreenManager, Client/Tycoon/TycoonWorld,
	Shared/Tycoon/TycoonLogic, Shared/Config/QuestConfig, Client/Quests/QuestClient (calls update).

	Example:
		QuestObjective.start()
		QuestObjective.update(QuestClient.view())
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HudObjective = require(script.Parent.Parent.UI.Hud.HudObjective)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)
local QuestOpenRules = require(script.Parent.QuestOpenRules)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonWorld = require(script.Parent.Parent.Tycoon.TycoonWorld)

-- What QuestClient hands over (the subset this module reads).
export type View = {
	state: QuestConfig.State,
	facts: QuestConfig.Facts,
	today: number,
	tycoon: any, -- the profile's tycoon snapshot (nextPads input)
}

local QuestObjective = {}

local MAIN_WORLD = "main"
local CURRENT_WORLD_ATTR = "CurrentWorld"

local lastView: View? = nil
local queued = false
local started = false
-- The last render wanted a guide arrow whose part had not streamed in yet (only then do
-- TycoonWorld's PadAdded / ProducerAdded bursts trigger a re-render).
local waitingForTarget = false
-- The part the published arrow points at (a streamed-out target re-resolves when it returns).
local currentTarget: BasePart? = nil

-- The player is in Nuke Town (the attribute is server-set; unset = Nuke Town).
local function inMainWorld(): boolean
	local world = Players.LocalPlayer:GetAttribute(CURRENT_WORLD_ATTR)
	return world == nil or world == MAIN_WORLD
end

-- The chain's next pad (or the first buyable Manager pad), streamed in on the local plot.
local function nextPadPart(tycoon: any, wantManager: boolean): BasePart?
	if type(tycoon) ~= "table" then
		return nil
	end
	local ok, pads = pcall(TycoonLogic.nextPads, tycoon)
	if not ok or type(pads) ~= "table" or #pads == 0 then
		return nil
	end
	local chosen = pads[1]
	if wantManager then
		for _, pad in pads do
			if pad.kind == "Manager" then
				chosen = pad
				break
			end
		end
	end
	return TycoonWorld.myPad(chosen.id)
end

-- The world arrow target of a guide kind (nil when nothing fits or it has not streamed in).
local function resolveGuide(guide: QuestConfig.Guide?, goal: QuestConfig.Goal?, view: View): BasePart?
	if guide == "pad" then
		return nextPadPart(view.tycoon, false)
	elseif guide == "manager" then
		return nextPadPart(view.tycoon, true)
	elseif guide == "producer" then
		local producer = if goal ~= nil then goal.producer else nil
		return if producer ~= nil then TycoonWorld.myProducer(producer) else nil
	elseif guide == "bestProducer" then
		local best = view.facts.bestProducer
		return if best ~= nil then TycoonWorld.myProducer(best) else nil
	end
	return nil
end

-- resolveGuide + remembers whether a wanted target is still missing (streaming).
local function guideTarget(guide: QuestConfig.Guide?, goal: QuestConfig.Goal?, view: View): BasePart?
	local target = resolveGuide(guide, goal, view)
	waitingForTarget = guide ~= nil and target == nil
	currentTarget = target
	return target
end

-- Opens the Quests screen from the chip.
-- The last published objective (text / counter / target), so an unchanged chip is never
-- re-laid out (clicks push `stats` several times a second).
local published: HudObjective.Secondary? = nil

-- C-ftue's Platform/JoinFlow, required lazily + guarded (its `guiding()` = the guided first-minute
-- tutorial steps). Missing / failing → treated as "guiding" (fail closed: the chip stays inert).
local joinFlow: any = nil
local function guiding(): boolean
	if joinFlow == nil then
		local platform = script.Parent.Parent:FindFirstChild("Platform")
		local module = if platform ~= nil then platform:FindFirstChild("JoinFlow") else nil
		if module == nil or not module:IsA("ModuleScript") then
			return true
		end
		local ok, result = pcall(require, module)
		if not ok or type(result) ~= "table" or type(result.guiding) ~= "function" then
			return true
		end
		joinFlow = result
	end
	local ok, value = pcall(joinFlow.guiding)
	return not ok or value ~= false
end

-- Opens Quests from a chip tap, only when QuestOpenRules.chip allows it (never over another
-- window, never during the guided first minute; see QuestOpenRules for the root cause).
local function openQuests()
	local view = lastView
	local allowed = QuestOpenRules.chip({
		anyModalOpen = ScreenManager.anyModalOpen(),
		guiding = guiding(),
		tutorialDone = view ~= nil and view.facts.tutorialDone,
		shown = published ~= nil,
	})
	if allowed then
		ScreenManager.open("Quests", { source = "chip" })
	end
end

-- Publishes `objective` unless it equals the last one.
local function publish(objective: HudObjective.Secondary?)
	local last = published
	if
		(objective == nil and last == nil)
		or (
			objective ~= nil
			and last ~= nil
			and objective.text == last.text
			and objective.progressText == last.progressText
			and objective.progress == last.progress
			and objective.target == last.target
		)
	then
		return
	end
	published = objective
	HudObjective.setSecondary(objective)
end

-- Recomputes and publishes the secondary objective from the last view.
local function render()
	local view = lastView
	waitingForTarget = false
	currentTarget = nil
	if view == nil or not inMainWorld() or not view.facts.tutorialDone then
		publish(nil)
		return
	end
	local state = view.state
	local goal = QuestConfig.currentGoal(state)
	if goal ~= nil then
		local value = QuestConfig.goalProgress(goal, view.facts, state)
		publish({
			text = goal.text,
			target = guideTarget(goal.guide, goal, view),
			progress = value / goal.target,
			progressText = `{NumberFormat.commas(value)}/{NumberFormat.commas(goal.target)}`,
			onActivated = openQuests,
		})
		return
	end
	local missions = QuestConfig.dailyViews(state, view.today)
	for _, mission in missions do
		if mission.state == "active" then
			local guide: QuestConfig.Guide? = if mission.stat == "pad"
				then "pad"
				elseif mission.stat == "upgrade" then "bestProducer"
				else nil
			publish({
				text = `Daily: {mission.text}`,
				target = guideTarget(guide, nil, view),
				progress = mission.progress / mission.target,
				progressText = `{NumberFormat.commas(mission.progress)}/{NumberFormat.commas(mission.target)}`,
				onActivated = openQuests,
			})
			return
		end
	end
	publish(nil)
end

-- Coalesces every trigger in a frame into one render.
local function requestRender()
	if queued then
		return
	end
	queued = true
	task.defer(function()
		queued = false
		render()
	end)
end

--[[
	Publishes the chip for a new QuestClient view (cheap; coalesced).
	@param view View
]]
function QuestObjective.update(view: View)
	lastView = view
	requestRender()
end

--[[ Hooks the re-resolve triggers (once; QuestClient.Start calls it). ]]
function QuestObjective.start()
	if started then
		return
	end
	started = true
	Players.LocalPlayer:GetAttributeChangedSignal(CURRENT_WORLD_ATTR):Connect(requestRender)
	-- A wanted target that streams in (or a new plot / respawn) re-resolves the arrow.
	local function onStreamed()
		if waitingForTarget then
			requestRender()
		end
	end
	-- The arrow's own part streaming out: look again (it may come back as a new instance).
	local function onRemoved(part: BasePart)
		if part == currentTarget then
			waitingForTarget = true
			requestRender()
		end
	end
	TycoonWorld.PadAdded:Connect(onStreamed)
	TycoonWorld.ProducerAdded:Connect(onStreamed)
	TycoonWorld.PadRemoved:Connect(onRemoved)
	TycoonWorld.ProducerRemoved:Connect(onRemoved)
	TycoonWorld.MyPlotChanged:Connect(requestRender)
	Players.LocalPlayer.CharacterAdded:Connect(requestRender)
end

return table.freeze(QuestObjective)
