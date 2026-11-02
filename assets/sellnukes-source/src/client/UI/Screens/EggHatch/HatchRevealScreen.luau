--!strict
--[[
	HatchRevealScreen ("HatchReveal") — the premium egg hatch cinematic (owner R49: "actually
	animate the egg opening animation, it's really bad right now").

	What the player sees (per egg; HatchStage draws one slot, HatchAnim times it):
		1. the REAL 3D egg (its Blender mesh) pops into a viewport over a dim stud backdrop, bobs,
		   then wobbles in bursts that grow in strength and speed with squash / stretch
		2. cracks spread in three stages (EggShards "Crack<k>" pieces) while light in the PET'S
		   RARITY colour leaks through them; a halo and (Rare+) rotating rays build up behind
		3. a crouch, a soft flash (owner R19: never blinding), the cap + shell chips fly off with
		   spin and gravity while the cup drops away
		4. the pet springs out with an overshoot bounce, then idles + does its happy spin (PetAnim,
		   owner R44)
		5. the stud rarity banner pops in (name, rarity, "1 in N" for Rare+, cash bonus, NEW! /
		   PITY! / EQUIPPED), confetti + sparkles scaled by rarity, rarity sound stingers
	Mythic / Secret: a longer, darker build-up (the room dims, the viewport jitters like a camera
	shake, a low swell), then a gold burst. Triple hatch: three eggs in a row pop in left to right,
	build up staggered, each reveals on its own — the best rarity always last.

	Opened by HatchFlow with ScreenManager.open("HatchReveal", args):
		args = { eggId: string?, pets: { row }, fast: boolean?, auto: boolean?, granted: boolean?,
		         onDone: (() -> ())?, onStopAuto: (() -> ())? }
		pets rows = HatchResult rows { uid, petId, rarity, slot, pityForced, isNew, equipped }
	The server already decided everything: this screen only PRESENTS the result.

	Speed: `fast` (auto-hatch) or the Settings "Fast Hatch" toggle (profile settings.fastHatch)
	plays the short profile; auto-hatch also continues by itself after a short hold. Reduce Motion
	(Roblox or the SellNukes setting): a still egg cross-fades into the pet, no shake / flash /
	jitter / confetti.

	Input (owner R11, console + mobile first): one big button that reads SKIP while the cinematic
	plays and AWESOME! once the result is in (gamepad default selection, so A skips / continues),
	a tap / click anywhere does the same, B / Back skips first and closes after the reveal (and
	stops auto-hatch). A tap right after the last reveal is ignored (HatchAnim.onTap) so a double
	tap never closes the result unseen. Phone / tablet / TV: ModalShell fits the 1400 x 850
	design into the TV-safe canvas.

	Performance: ONE RenderStepped connection, only while the screen is open; slots, confetti and
	light pieces are pooled (built once); models are built at the start of a reveal, never per
	frame; FxQuality Low flies fewer shards / confetti; every property write is change-gated.

	Connects to: UI/Screens/EggHatch/{HatchFlow (opens it), HatchStage, HatchConfetti},
	Client/Pets/{HatchAnim, PetModels, PetUI (haptics)}, Client/Audio/Sound, Client/ClientState,
	UI/{Create, ScreenManager, Kit/StudUI, Widgets/{ModalShell, OfferFx, PanelBackdrop}},
	Tycoon/Fx/FxQuality, Shared/Config/{HatchAnimConfig, PetConfig, EggConfig}.

	Example: ScreenManager.open("HatchReveal", { eggId = "garage_egg", pets = payload.pets, onDone = done })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ClientState = require(script.Parent.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Parent.Create)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local FxQuality = require(script.Parent.Parent.Parent.Parent.Tycoon.Fx.FxQuality)
local HatchAnim = require(script.Parent.Parent.Parent.Parent.Pets.HatchAnim)
local HatchAnimConfig = require(ReplicatedStorage.Shared.Config.HatchAnimConfig)
local HatchConfetti = require(script.Parent.HatchConfetti)
local HatchStage = require(script.Parent.HatchStage)
local ModalShell = require(script.Parent.Parent.Parent.Widgets.ModalShell)
local OfferFx = require(script.Parent.Parent.Parent.Widgets.OfferFx)
local PanelBackdrop = require(script.Parent.Parent.Parent.Widgets.PanelBackdrop)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetModels = require(script.Parent.Parent.Parent.Parent.Pets.PetModels)
local PetUI = require(script.Parent.Parent.Parent.Parent.Pets.PetUI)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local Sound = require(script.Parent.Parent.Parent.Parent.Audio.Sound)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)

local NAME = "HatchReveal"
local DESIGN = Vector2.new(1400, 850)
local ROW_TOP = 92
local SLOT_GAP = 26
-- A single egg is the hero: a little bigger than one of three.
local SINGLE_SCALE = 1.08
-- Each egg of a triple fires this share of its rarity's confetti (three bursts already).
local TRIPLE_CONFETTI = 0.7
-- Longest frame step fed to the animation (a hitch never teleports the timeline).
local MAX_DT = 1 / 15
-- Studio-only verification hook: a number attribute "DebugHoldAt" on this ScreenGui freezes the
-- cinematic clock at that second (screenshots of exact beats). Never read in live servers.
local IS_STUDIO = RunService:IsStudio()
local HOLD_ATTRIBUTE = "DebugHoldAt"

type Row = HatchStage.Row

local module: ScreenManager.ScreenModule = {
	name = NAME,
	modal = true,
	closeOnBack = false,
	lazy = true,
	displayOrder = 40,
	blur = true,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		-- Full-screen dim with soft dark studs (owner rule 2); a tap on it skips / continues.
		local dim = Create.new("TextButton", {
			Name = "Dim",
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = Color3.fromRGB(8, 8, 20),
			BackgroundTransparency = HatchAnimConfig.Light.DimBase,
			-- Over-filled past the TV-safe "SafeArea" padding so a console's outer 5 % is dimmed too.
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1.25, 1.25),
			Selectable = false,
			ZIndex = 0,
			Parent = gui,
		}) :: TextButton
		-- A full-screen orbit burst would look odd: the tap keeps its sound, no particles.
		dim:SetAttribute("ButtonParticlesDisabled", true)
		PanelBackdrop.new(dim, { tint = Color3.fromRGB(70, 74, 110), textureTransparency = 0.86, tileSize = 150 })
		-- Soft full-screen wash at a burst (owner R19: a hint of light, not a white-out).
		local wash = Create.new("Frame", {
			Name = "Wash",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1.25, 1.25),
			Active = false,
			ZIndex = 1,
			Parent = gui,
		}) :: Frame
		local stage = Create.new("Frame", {
			Name = "Stage",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(DESIGN.X, DESIGN.Y),
		}) :: Frame
		local shell = ModalShell.new(gui, stage, DESIGN)
		local title = StudUI.text({
			text = "HATCHING...",
			textSize = 64,
			font = "shout",
			size = UDim2.fromOffset(DESIGN.X, 80),
			position = UDim2.fromOffset(0, 6),
			parent = stage,
		})
		local row = Create.new("Frame", {
			Name = "Slots",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(DESIGN.X, HatchStage.Slot.Y),
			Position = UDim2.fromOffset(0, ROW_TOP),
			Parent = stage,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, SLOT_GAP),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame
		local buttons = Create.new("Frame", {
			Name = "Buttons",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(DESIGN.X, 104),
			Position = UDim2.fromOffset(0, DESIGN.Y - 108),
			ZIndex = 9,
			Parent = stage,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, 24),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame
		-- Confetti flies over everything on the stage (pooled pieces, design px).
		local confettiLayer = Create.new("Frame", {
			Name = "Confetti",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Active = false,
			ZIndex = 8,
			Parent = stage,
		}) :: Frame
		local confetti = HatchConfetti.new(confettiLayer, HatchAnimConfig.Confetti.Pool, 8)

		-- The three pooled slots (a single hatch uses the first).
		local stages: { HatchStage.Stage } = {}
		for index = 1, 3 do
			stages[index] = HatchStage.new(row, index)
		end

		-- Per-reveal state.
		local args: { [string]: any } = {}
		local timelines: { HatchAnim.Timeline } = {}
		local events: { { HatchAnim.Event } } = {}
		local cursors: { number } = {}
		local rows: { Row } = {}
		local count = 0
		local clock = 0
		local total = 0
		local lastBurst = 0
		local playing = false
		local revealed = false
		local canClose = false
		local tier: HatchAnimConfig.Tier = HatchAnimConfig.Tiers.High
		local connection: RBXScriptConnection? = nil
		local doneButtonShown = false
		local lastDim = HatchAnimConfig.Light.DimBase
		local lastWash = 1

		local tap: () -> ()
		local continueButton = StudUI.button({
			text = "SKIP",
			color = "grey",
			size = UDim2.fromOffset(300, 92),
			textSize = 40,
			layoutOrder = 1,
			parent = buttons,
			onActivated = function()
				tap()
			end,
		})
		local stopButton: StudUI.Button
		stopButton = StudUI.button({
			text = "STOP AUTO",
			color = "red",
			size = UDim2.fromOffset(280, 92),
			textSize = 36,
			layoutOrder = 2,
			parent = buttons,
			onActivated = function()
				local stop = args.onStopAuto
				args.onStopAuto = nil
				stopButton.instance.Visible = false
				if type(stop) == "function" then
					(stop :: () -> ())()
				end
			end,
		})

		-- One mesh-ready listener for the whole screen: a slot showing that key rebuilds it.
		PetModels.Ready:Connect(function(key: string)
			if not playing then
				return
			end
			for index = 1, count do
				stages[index].meshReady(key)
			end
		end)

		-- Settings "Fast Hatch" (profile settings.fastHatch).
		local function fastSetting(): boolean
			local profile = ClientState.profile
			local settings = if type(profile) == "table" then profile.settings else nil
			return type(settings) == "table" and settings.fastHatch == true
		end

		-- The LuckyEggs pass (the banner's "1 in N" uses the boosted odds the server rolled).
		local function luckyOwned(): boolean
			local profile = ClientState.profile
			local passes = if type(profile) == "table" then profile.passes else nil
			return type(passes) == "table" and passes[EggConfig.LuckPass] == true
		end

		-- Converts a point inside slot `index` (design px of the slot) to stage design px.
		local function stagePoint(index: number, local_: Vector2): Vector2
			local slotFrame = stages[index].frame
			local ratio = stage.AbsoluteSize.X / DESIGN.X
			if ratio <= 0 or ratio ~= ratio then
				return DESIGN / 2
			end
			local offset = (slotFrame.AbsolutePosition - stage.AbsolutePosition) / ratio
			return offset + local_
		end

		-- Plays one timeline event of slot `index`.
		local function fire(index: number, event: HatchAnim.Event)
			local tl = timelines[index]
			if event.kind == "sound" then
				Sound.play(event.key, { pitch = event.pitch, volume = event.volume })
			elseif event.kind == "haptic" then
				-- The reveal moment: rumble / vibrate (B16 Platform haptics).
				PetUI.haptic("Hatch")
			elseif event.kind == "confetti" then
				local rarity = PetConfig.rarity(rows[index].rarity)
				local palette: { Color3 } = table.clone(
					if tl.beat.gold then HatchAnimConfig.Confetti.Gold else HatchAnimConfig.Confetti.Party
				) :: { Color3 }
				if rarity ~= nil then
					table.insert(palette, rarity.color)
					table.insert(palette, rarity.color)
				end
				local amount = tl.beat.confetti * tier.confetti * (if count > 1 then TRIPLE_CONFETTI else 1)
				confetti.burst(stagePoint(index, stages[index].center()), amount, palette)
			elseif event.kind == "sparkles" then
				local rarity = PetConfig.rarity(rows[index].rarity)
				confetti.sparkle(
					stagePoint(index, stages[index].center()),
					HatchAnimConfig.Confetti.SparkleRadius,
					tl.beat.sparkles * tier.sparkles,
					if rarity ~= nil then rarity.color else Color3.new(1, 1, 1)
				)
			elseif event.kind == "happy" then
				stages[index].happy()
			end
		end

		-- Button / title state once the result is in.
		local function refreshState()
			if not revealed and clock >= lastBurst then
				revealed = true
				if args.granted == true then
					title.Text = "YOU GOT A PET!"
				elseif count == 1 then
					local def = PetConfig.get(rows[1].petId)
					title.Text = if def ~= nil then def.name:upper() .. "!" else "NEW PET!"
				end
			end
			local speed = if timelines[1] ~= nil then timelines[1].speed else HatchAnimConfig.Profiles.Normal
			canClose = clock >= lastBurst + speed.MinReveal
			if canClose and not doneButtonShown then
				doneButtonShown = true
				continueButton.setColor("green")
				continueButton.setText(if args.auto == true then "NEXT" else "AWESOME!")
			end
		end

		-- One frame of the cinematic (the ONLY per-frame work of this screen).
		local function step(rawDt: number)
			if not playing then
				return
			end
			local dt = math.clamp(rawDt, 0, MAX_DT)
			if IS_STUDIO then
				local hold = gui:GetAttribute(HOLD_ATTRIBUTE)
				if type(hold) == "number" and clock + dt > hold then
					dt = math.max(0, hold - clock)
				end
			end
			clock += dt
			for index = 1, count do
				local list = events[index]
				local cursor = cursors[index]
				while cursor <= #list and list[cursor].time <= clock do
					fire(index, list[cursor])
					cursor += 1
				end
				cursors[index] = cursor
				stages[index].apply(clock, dt)
			end
			-- Room dim + wash: the darkest / brightest of all slots.
			local dimT, washO = 1, 0
			for index = 1, count do
				dimT = math.min(dimT, HatchAnim.dim(timelines[index], clock))
				washO = math.max(washO, HatchAnim.wash(timelines[index], clock))
			end
			-- Quantised + compared with the last WRITTEN value (the property stores a float32).
			dimT = math.floor(dimT * 50 + 0.5) / 50
			if dimT ~= lastDim then
				lastDim = dimT
				dim.BackgroundTransparency = dimT
			end
			local washT = 1 - math.floor(washO * 50 + 0.5) / 50
			if washT ~= lastWash then
				lastWash = washT
				wash.BackgroundTransparency = washT
			end
			confetti.step(dt)
			refreshState()
			-- Auto-hatch continues by itself after a short look at the result.
			if args.auto == true and timelines[1] ~= nil and clock >= total + timelines[1].speed.AutoHold then
				ScreenManager.close(NAME)
			end
		end

		-- Jumps the clock to `target` (skip): events before it are dropped, not replayed.
		local function skipTo(target: number)
			if target <= clock then
				return
			end
			clock = target
			for index = 1, count do
				local list = events[index]
				local cursor = cursors[index]
				while cursor <= #list and list[cursor].time < target do
					cursor += 1
				end
				cursors[index] = cursor
				stages[index].apply(clock, 0)
			end
			refreshState()
		end

		tap = function()
			if not playing then
				return
			end
			local action, target = HatchAnim.onTap(timelines, clock)
			if action == "skip" then
				skipTo(target)
			elseif action == "close" then
				ScreenManager.close(NAME)
			end
		end
		dim.Activated:Connect(function()
			tap()
		end)

		-- Starts a reveal from `args`.
		local function play()
			local pets: { Row } = if type(args.pets) == "table" then (args.pets :: any) :: { Row } else {}
			if #pets == 0 then
				ScreenManager.close(NAME)
				return
			end
			count = math.min(#pets, 3)
			rows = {}
			local ranks: { number } = {}
			for index = 1, count do
				local petRow = pets[index]
				rows[index] = petRow
				local rarity = PetConfig.rarity(petRow.rarity)
				ranks[index] = if rarity ~= nil then rarity.rank else 1
			end
			local granted = args.granted == true or type(args.eggId) ~= "string"
			local reduced = OfferFx.reducedMotion()
			local fast = args.fast == true or fastSetting()
			local tierName = FxQuality.tier()
			tier = if tierName == "Low"
				then HatchAnimConfig.Tiers.Low
				elseif tierName == "High" then HatchAnimConfig.Tiers.High
				else HatchAnimConfig.Tiers.Mid
			timelines = HatchAnim.schedule(ranks, { fast = fast, reduced = reduced, granted = granted })
			total = HatchAnim.total(timelines)
			lastBurst = HatchAnim.lastBurst(timelines)
			events = {}
			cursors = {}
			local lucky = luckyOwned()
			for index = 1, 3 do
				local slot = stages[index]
				if index <= count then
					slot.setScale(if count == 1 then SINGLE_SCALE else 1)
					slot.prepare({
						eggId = if granted then nil else args.eggId,
						row = rows[index],
						timeline = timelines[index],
						tier = tier,
						lucky = lucky,
						seed = index * 37 + os.clock() % 1000,
					})
					events[index] = HatchAnim.events(timelines[index])
					cursors[index] = 1
				else
					slot.release()
				end
			end
			clock = 0
			revealed = false
			canClose = false
			doneButtonShown = false
			playing = true
			confetti.clear()
			title.Text = if granted then "YOU GOT A PET!" elseif count > 1 then "TRIPLE HATCH!" else "HATCHING..."
			continueButton.setColor("grey")
			continueButton.setText("SKIP")
			stopButton.instance.Visible = args.auto == true and type(args.onStopAuto) == "function"
			lastDim, lastWash = HatchAnimConfig.Light.DimBase, 1
			dim.BackgroundTransparency = lastDim
			wash.BackgroundTransparency = lastWash
			-- Pose frame 0 now, so nothing shows at rest for a frame before the intro.
			for index = 1, count do
				stages[index].apply(0, 0)
			end
			if connection == nil then
				connection = RunService.RenderStepped:Connect(step)
			end
		end

		return {
			onOpen = function(openArgs: any?)
				args = if type(openArgs) == "table" then openArgs else {}
				-- Warm the shard / crack overlay meshes (no-op once loaded).
				PetModels.request(HatchAnimConfig.ShardsKey)
				shell.popIn()
				play()
			end,
			onClose = function()
				playing = false
				if connection ~= nil then
					connection:Disconnect()
					connection = nil
				end
				for index = 1, 3 do
					stages[index].release()
				end
				confetti.clear()
				timelines = {}
				events = {}
				count = 0
				local done = args.onDone
				args.onDone = nil
				if type(done) == "function" then
					task.defer(done :: () -> ())
				end
			end,
			onBack = function(): boolean
				local stop = args.onStopAuto
				if type(stop) == "function" then
					args.onStopAuto = nil
					stopButton.instance.Visible = false
					local stopAuto = stop :: () -> ()
					stopAuto()
				end
				-- B skips first; once the result has been seen it closes (owner R11).
				if playing and not canClose then
					local action, target = HatchAnim.onTap(timelines, clock)
					if action == "skip" then
						skipTo(target)
					end
				else
					ScreenManager.close(NAME)
				end
				return true
			end,
			defaultSelection = function(): GuiObject?
				return continueButton.instance
			end,
		}
	end,
}

return module
