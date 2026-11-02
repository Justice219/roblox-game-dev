--!strict
--[[
	Tutorial — renders the server-driven tutorial (spec: "the tutorial is built into the first
	area: click to build, then buy things").

	Purpose:
		The server (B5 TutorialLogic) sends TutorialState { step, done, kind, target, padId?,
		producerId?, text } on join and on every change: kind "pad" | "click" | "upgrade",
		target = the padId / producerId the arrow points at, text = the objective line;
		{ step = 0, done = true } ends it. Without a server text the line is built from the kind +
		the target's display name (TycoonConfig). Payloads without a kind fall back to the client
		step table (Tycoon/TutorialSteps). This module:
			- shows the HUD objective chip + screen-edge / world arrow (Hud.setObjective),
			- lays a trail of yellow chevron ARROWS on the ground from the character toward the
			  target (Tycoon/TutorialArrows, owner R27; hidden within 8 studs),
			- queues the "TycoonTutorial" coach card once per session on step 1 through the join
			  pop-up queue (Platform/JoinFlow: after the loading screen, the plot reveal and any
			  Welcome Back; the card is NON-blocking since R78),
			- feeds the server step to JoinFlow (the guided first-minute steps hold every other
			  pop-up / the Lucky Button arrow back).
		Objective lines name the control of the device in the player's hands (owner R78 §6 /
		R11): Tycoon/TutorialText turns the step kind into "Press RT at your Workbench to make
		nukes!" (gamepad), "Tap TAP! ..." (touch) or "Press F or click your Workbench ..."
		(keyboard + mouse), re-rendered on a device switch or a gamepad family change. The
		server's own line is the fallback for later pad steps (walking onto a pad is the same
		everywhere).
		Owner R84 ("it doesn't actually point to the GUI ... it kind of points towards the bench"):
		on click / upgrade steps the HUD arrow points at the CONTROL to press, not the model:
		Tycoon/TutorialHighlight rings the producer billboard's UPGRADE pill / make bar (and on
		touch the on-screen TAP! / UPGRADE button), hands the HUD that GuiObject as the arrow
		target (the arrow sits beside it, never over it: UI/Hud/PointerLogic) plus a callout badge
		with the device glyph (X / Square, E + cursor, RT, F + cursor, a tap hand) and leads the
		ground chevrons to the billboard's spot. The objective line names the same control
		(TutorialText: "Press X to UPGRADE your Workbench!"). Pad steps keep the arrow over the
		pad (you walk onto it) and ring the pad label's price button. Rings leave with the step
		(the next render clears them).
		Targets resolve against the local player's streamed world (TycoonWorld) and re-resolve
		when a pad / producer streams in, the profile changes (the next pad moved on) or the
		character respawns. Finished (step 0 / past the list): chip and beam are removed.

	API: Tutorial.start(), Tutorial.step() (current step, 0 = none), Tutorial.hintText() (the
	objective line on screen while a step is active, else nil; Tycoon/FtueTracker reads both),
	Tutorial.hintTarget() (the part the arrows point at; the coach card keeps clear of it),
	Tutorial.keys() (device button names for TutorialText).

	Performance: event-driven; the arrow trail runs one pooled loop only while a target is set;
	the highlight rings pulse on the shared OfferFx driver (TutorialHighlight).

	Connects to: Shared/Net/Remotes ("TutorialState"), Client/ClientState, Tycoon/{TutorialSteps,
	TutorialText, TycoonWorld, TutorialArrows, TutorialHighlight}, UI/Hud/{Hud, HudObjective
	(setCallout)}, UI/ScreenManager, Platform/{JoinFlow,
	GlyphFamily}, Controllers/InputController, Shared/Tycoon/TycoonLogic,
	Shared/Config/{TycoonConfig, PlatformConfig, FtueConfig}.

	Example: Tutorial.start()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.ClientState)
local Contract = require(script.Parent.TycoonContract)
local FtueConfig = require(ReplicatedStorage.Shared.Config.FtueConfig)
local GlyphFamily = require(script.Parent.Parent.Platform.GlyphFamily)
local Hud = require(script.Parent.Parent.UI.Hud.Hud)
local HudObjective = require(script.Parent.Parent.UI.Hud.HudObjective)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local InputGlyph = require(script.Parent.Parent.UI.Widgets.InputGlyph)
local JoinFlow = require(script.Parent.Parent.Platform.JoinFlow)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local TutorialArrows = require(script.Parent.TutorialArrows)
local TutorialHighlight = require(script.Parent.TutorialHighlight)
local TutorialSteps = require(script.Parent.TutorialSteps)
local TutorialText = require(script.Parent.TutorialText)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonWorld = require(script.Parent.TycoonWorld)

local Tutorial = {}

local currentStep = 0
-- The server's current step description (validated): kind + target id, or nil.
local serverKind: string? = nil
local serverTarget: string? = nil
local serverText: string? = nil
local finished = false
local introShown = false
local started = false
-- The objective line currently on the chip (nil = no active step) and its world target.
local shownText: string? = nil
local shownTarget: BasePart? = nil

-- The coach card's screen (Screens/TycoonTutorial) and its join-queue key.
local COACH_SCREEN = "TycoonTutorial"
local COACH_KEY = "TutorialCoach"

-- The current step number (0 = no tutorial).
function Tutorial.step(): number
	return currentStep
end

--[[ The objective line on screen while a tutorial step is active, else nil. ]]
function Tutorial.hintText(): string?
	return shownText
end

--[[ The part the tutorial arrows point at right now (nil = none / not streamed in). ]]
function Tutorial.hintTarget(): BasePart?
	return shownTarget
end

-- The first keyboard key / gamepad button of an action binding (nil when it has none).
local function firstKey(list: { Enum.KeyCode }?): Enum.KeyCode?
	return if list ~= nil then list[1] else nil
end

--[[
	The button names TutorialText needs, from the SAME bindings the hint bar and the touch
	buttons use (PlatformConfig.Actions), with the Xbox / PlayStation label from GlyphFamily.
	Example: Tutorial.keys().producePad --> "RT" (Xbox) / "R2" (PlayStation)
]]
function Tutorial.keys(): TutorialText.Keys
	local produce = PlatformConfig.Actions.Produce
	local interact = PlatformConfig.Actions.Interact
	local produceKey, producePad = firstKey(produce.keys), firstKey(produce.buttons)
	local interactKey, interactPad = firstKey(interact.keys), firstKey(interact.buttons)
	return {
		produceKey = if produceKey ~= nil then InputGlyph.keyboardText(produceKey) else "F",
		producePad = if producePad ~= nil then GlyphFamily.label(producePad) else "RT",
		produceTouch = if produce.touch ~= nil then produce.touch.label else "TAP!",
		interactKey = if interactKey ~= nil then InputGlyph.keyboardText(interactKey) else "E",
		interactPad = if interactPad ~= nil then GlyphFamily.label(interactPad) else "X",
		interactTouch = if interact.touch ~= nil then interact.touch.label else "UPGRADE",
	}
end

-- Resolves a symbolic target to the local player's streamed-in part, or nil.
local function resolve(target: TutorialSteps.Target?): BasePart?
	if target == nil then
		return nil
	end
	local area = TycoonConfig.Areas[target.area or 1]
	if target.kind == "producer" then
		return if area ~= nil then TycoonWorld.myProducer(area.producer.id) else nil
	end
	if target.kind == "manager" then
		local padId = if area ~= nil then TycoonConfig.ManagerPadOf[area.producer.id] else nil
		return if padId ~= nil then TycoonWorld.myPad(padId) else nil
	end
	if target.kind == "unlock" then
		local pads = TycoonConfig.AreaPads[target.area or 1]
		local last = if pads ~= nil then pads[#pads] else nil
		return if last ~= nil then TycoonWorld.myPad(last.id) else nil
	end
	-- nextPad: the first pad the player can buy right now.
	local profile = ClientState.profile
	if profile == nil or type(profile.tycoon) ~= "table" then
		return nil
	end
	local next = TycoonLogic.nextPads(profile.tycoon :: any)[1]
	return if next ~= nil then TycoonWorld.myPad(next.id) else nil
end

-- Hides the ground arrow trail.
local function clearBeam()
	TutorialArrows.clear()
end

-- Shows the ground arrow trail toward `target` (owner R27: arrows, not a line; R84: a producer
-- step's trail leads to its billboard spot Attachment).
local function drawBeam(target: BasePart | Attachment)
	TutorialArrows.setTarget(target)
end

-- True while a tutorial step is active (a server kind, or a known client step).
local function active(): boolean
	return not finished and currentStep > 0 and (serverKind ~= nil or TutorialSteps.get(currentStep) ~= nil)
end

-- Display name of a server target: the pad's name, or the producer's short name ("Workbench").
local function targetName(kind: string, target: string): string
	if kind == "pad" then
		local pad = TycoonConfig.PadsById[target]
		return if pad ~= nil then pad.name else "glowing"
	end
	local producer = TycoonConfig.ProducersById[target]
	if producer == nil then
		return "machine"
	end
	local builder = if producer.builtBy ~= nil then TycoonConfig.PadsById[producer.builtBy] else nil
	return TutorialText.shortName(producer.name, if builder ~= nil then builder.name else nil)
end

-- Objective text for a server kind + target on the player's device (Tycoon/TutorialText).
local function serverObjective(kind: string, target: string): string
	return TutorialText.objective(
		kind,
		targetName(kind, target),
		currentStep,
		serverText,
		InputController.mode,
		Tutorial.keys()
	)
end

-- Re-renders the current step (chip, arrow, beam).
local function render()
	local step = TutorialSteps.get(currentStep)
	if not active() then
		shownText = nil
		shownTarget = nil
		HudObjective.setCallout(nil)
		Hud.setObjective(nil)
		TutorialHighlight.clear()
		clearBeam()
		JoinFlow.cancel(COACH_KEY)
		return
	end
	local firstArea = TycoonConfig.Areas[1]
	local text: string
	local target: BasePart? = nil
	local focus: TutorialHighlight.Result? = nil
	local kind, targetId = serverKind, serverTarget
	if kind ~= nil then
		text = serverObjective(kind, targetId or "")
		if targetId ~= nil then
			target = if kind == "pad" then TycoonWorld.myPad(targetId) else TycoonWorld.myProducer(targetId)
		end
		-- Owner R84: ring the exact control to press and learn where the arrow must point.
		focus = TutorialHighlight.show(kind, targetId, InputController.mode)
	else
		local template = if step ~= nil then step.text else ""
		text = string.gsub(template, "{producer}", if firstArea ~= nil then firstArea.producer.name else "machine")
		target = if step ~= nil then resolve(step.target) else nil
		TutorialHighlight.clear()
	end
	shownText = text
	shownTarget = target
	-- The arrow points at the control itself (the billboard's UPGRADE pill / make bar, the TAP!
	-- button) when it exists, else at the target part (pads; a board not streamed in yet). The
	-- callout (device glyph badge) goes first so the arrow's first frame already carries it.
	local pointer = if focus ~= nil then focus.pointer else nil
	HudObjective.setCallout(if focus ~= nil then focus.callout else nil)
	Hud.setObjective(text, if pointer ~= nil then pointer else target)
	-- The chevrons lead to the billboard's spot (walkway side, in reach of E / X / RT and the
	-- touch buttons) on producer steps, else to the target part.
	local trail: (BasePart | Attachment)? = if focus ~= nil and focus.trail ~= nil then focus.trail else target
	if trail ~= nil then
		drawBeam(trail)
	else
		clearBeam()
	end
	if currentStep == 1 and not introShown then
		introShown = true
		-- Owner R16 + R78: through the join queue, i.e. after the loading screen, the plot reveal
		-- and any Welcome Back; still step 1 when its moment comes (else it is skipped).
		JoinFlow.request(COACH_KEY, FtueConfig.Join.Priority.TutorialCoach, function()
			if currentStep == 1 and active() then
				ScreenManager.open(COACH_SCREEN)
			end
		end)
	end
end

-- The step JoinFlow should see (0 once the tutorial is finished).
local function feedJoinFlow()
	JoinFlow.setTutorialStep(if finished then 0 else currentStep)
end

-- Applies a step number from the server / profile.
local function setStep(step: number)
	if step == currentStep then
		return
	end
	currentStep = step
	feedJoinFlow()
	-- The coach card only explains step 1: it leaves as soon as the Workbench pad is bought.
	if step ~= 1 and ScreenManager.isOpen(COACH_SCREEN) then
		ScreenManager.close(COACH_SCREEN)
	end
	render()
end

-- A short display string from an untyped payload field, else nil.
local function shortText(value: unknown, cap: number): string?
	if type(value) == "string" and #value >= 1 and #value <= cap and utf8.len(value) ~= nil then
		return value
	end
	return nil
end

--[[ Starts listening (once; TycoonClient calls it after TycoonWorld.start). ]]
function Tutorial.start()
	if started then
		return
	end
	started = true
	task.spawn(function()
		Remotes.event("TutorialState").OnClientEvent:Connect(function(payload: unknown)
			if type(payload) ~= "table" then
				return
			end
			local data = payload :: { [string]: unknown }
			local kind = shortText(data.kind, 16)
			serverKind = if kind == "pad" or kind == "click" or kind == "upgrade" then kind else nil
			serverTarget = shortText(data.target, 64) or shortText(data.padId, 64) or shortText(data.producerId, 64)
			serverText = shortText(data.text, 140)
			finished = data.done == true
			local step = Contract.num(data.step, 0)
			if step == currentStep then
				feedJoinFlow()
				render() -- same step, new server target
			else
				setStep(step)
			end
		end)
	end)
	ClientState.ProfileChanged:Connect(function(profile, fields)
		if fields ~= nil and table.find(fields, "tycoon") == nil then
			return
		end
		local tycoon = profile.tycoon
		if type(tycoon) == "table" then
			local step = Contract.num(tycoon.tutorialStep, currentStep)
			if step ~= currentStep then
				setStep(step)
				return
			end
		end
		-- Same step, new purchases: the "next pad" target may have moved on.
		if active() then
			render()
		end
	end)
	local profile = ClientState.profile
	local tycoon: any = if profile ~= nil then profile.tycoon else nil
	if type(tycoon) == "table" then
		setStep(Contract.num(tycoon.tutorialStep, 0))
	end
	-- Targets streaming in / the character respawning re-resolve the arrow + beam.
	local function rerender()
		if active() then
			render()
		end
	end
	TycoonWorld.PadAdded:Connect(rerender)
	TycoonWorld.ProducerAdded:Connect(rerender)
	TycoonWorld.MyPlotChanged:Connect(rerender)
	-- Owner R84: the step's control appeared / vanished (a billboard streamed in or was rebuilt,
	-- the TAP! / UPGRADE touch button showed up in reach): move the arrow + ring onto it.
	TutorialHighlight.start()
	TutorialHighlight.Changed:Connect(rerender)
	-- A device switch (or another gamepad family) changes the words: "Press RT" / "Tap TAP!".
	InputController.ModeChanged:Connect(rerender)
	GlyphFamily.Changed:Connect(rerender)
	Players.LocalPlayer.CharacterAdded:Connect(function()
		task.defer(rerender)
	end)
end

return Tutorial
