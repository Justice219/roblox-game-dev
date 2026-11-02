--!strict
--[[
	WheelFx — the Lucky Wheel's spin presentation (owner R81: "spin needs like a ticker effect and
	more effects. It's just kind of boring."). It animates the layers WheelDrawing built; the
	screen (Screens/LuckyWheel) tells it WHAT happens, WheelFx decides how it looks and sounds.

	PRESENTATION ONLY: the server already rolled the slice and paid the reward (LuckySpinService).
	WheelFx only ever lands on the target rotation the screen computed from the server's slice.

	A spin, beat by beat (numbers in Shared/Config/LuckyWheelFxConfig):
		windUp   SPIN pressed: the disc is pulled back (the flapper presses on the peg behind it),
		         then trembles until the server answers (this hides the request round trip)
		spin     launch to top speed, motion arcs + a fast bulb chase, one tick per rim peg (pitch +
		         volume follow the speed, a fast spin is a rattle), the flapper knocked aside and
		         snapping back; the long slowdown spaces the ticks out by itself
		land     the disc stops a hair past the slice centre and rocks back; the screen's callback
		         runs (rotation, button, toast) and calls win()
		win      the slice under the pointer glows + pulses, rays turn behind the wheel, every bulb
		         blinks in the slice's colour, pooled confetti + sparkles, a shake, the reward pop
		         (slice icon over the hub + "You won ...!") punches in, and a sting sized to the
		         reward (RARE PET / EGG get the fanfare + fireworks + a Hatch rumble)
		unwind   the request failed / timed out: the disc eases back to where it rested
		settle   the screen closed: everything stops at once on the final rotation (no callbacks)
	Back-to-back spins (QuickSpin) use fewer turns and a shorter curve; a new wind-up cancels the
	previous celebration (confetti already in the air keeps falling).

	Performance (CLAUDE.md rules):
		- ONE RunService.PreRender connection, connected only while something moves (a spin, a
		  celebration, confetti in the air, the flapper still swinging, a shake) and dropped the
		  frame everything is at rest. Idle bulbs chase through the shared Widgets/OfferFx driver
		  instead (throttled per graphics tier, parked on Low and with Reduce Motion, only while on
		  screen), disabled while this driver runs so a bulb never has two writers.
		- Zero Instance.new after `new`: confetti / sparkles come from the HatchConfetti pool, the
		  pop + its eight icons are built once, every other layer is WheelDrawing's.
		- Property writes only on change: the flapper and streak / glow / ray opacities are
		  quantised, bulbs repaint only when the chase step or blink state changes.
		- Graphics tier (OfferFx.tier()) trims the extras on Low (no arcs, no rays, fewer confetti).
		  Reduce Motion never reaches the driver: the screen snaps the disc and win() shows a static
		  celebration (glow + solid bulbs + pop + sting, no motion).
	Input: every layer is Active = false / not Selectable and lives under the wheel's root, which
	the screen keeps BELOW the title, message, SPIN, X and bundle buttons (wheel root ZIndex 0).

	Connects to: Screens/LuckyWheel (owner; init.luau), Screens/LuckyWheel/{WheelDrawing, SpinMotion},
	Screens/EggHatch/HatchConfetti (pool), Widgets/OfferFx (tier, reduced motion, idle driver),
	Kit/StudUI (pop text + icons), Client/Audio/Sound, Client/Platform/Haptics,
	Shared/Config/{LuckyWheelFxConfig, LuckySpinConfig, HatchAnimConfig (confetti palettes)}.

	Example:
		local fx = WheelFx.new(wheel, LuckySpinConfig.Slices, 337.5)
		fx.windUp(false)                                       -- SPIN pressed
		fx.spin(target, false, function() fx.win(3, "You won 5 GEMS!", false) end)
		fx.settle()                                            -- screen closed mid-spin
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Create = require(script.Parent.Parent.Parent.Create)
local HatchAnimConfig = require(ReplicatedStorage.Shared.Config.HatchAnimConfig)
local HatchConfetti = require(script.Parent.Parent.EggHatch.HatchConfetti)
local Haptics = require(script.Parent.Parent.Parent.Parent.Platform.Haptics)
local LuckySpinConfig = require(ReplicatedStorage.Shared.Config.LuckySpinConfig)
local LuckyWheelFxConfig = require(ReplicatedStorage.Shared.Config.LuckyWheelFxConfig)
local OfferFx = require(script.Parent.Parent.Parent.Widgets.OfferFx)
local Sound = require(script.Parent.Parent.Parent.Parent.Audio.Sound)
local SpinMotion = require(script.Parent.SpinMotion)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WheelDrawing = require(script.Parent.WheelDrawing)

local Cfg = LuckyWheelFxConfig

-- Longest frame step fed to the animation (s): a hitch slows the show instead of skipping it.
local MAX_DT = 1 / 15
-- Studio-only verification hooks (never active in live servers; docs/verification/r81-*):
--   attribute "DebugHold" = true on the wheel root freezes the animation clock (device-matrix
--   captures of an exact mid-spin / win frame), attribute "FxDriving" mirrors whether the
--   PreRender connection is live (the "connected only while animating" probe).
local IS_STUDIO = RunService:IsStudio()
-- Text size of the "You won ...!" line (design px).
local POP_TEXT = 58
-- Seconds of the win shake.
local SHAKE_SECONDS = 0.45
-- Quantisation of the glow / ray opacity writes.
local GLOW_STEP = 0.02
local RAY_STEP = 0.04
-- Confetti origin: the winning slice, this far up from the hub (× disc radius).
local CONFETTI_RISE = 0.62
-- Sparkles twinkle within this radius of the winning slice (× disc radius).
local SPARKLE_RADIUS = 0.32
-- Pop text centre below the hub (× disc radius): the winning slice at the top stays clear.
local POP_DROP = 0.5
local WHITE = Color3.new(1, 1, 1)

type Phase = "idle" | "windup" | "hold" | "spin" | "settle" | "unwind"
type Pending = { target: number, quick: boolean, onLanded: () -> () }

export type Fx = {
	-- SPIN pressed: pull the disc back and hold until spin() / unwind().
	windUp: (quick: boolean) -> (),
	-- The server's answer: launch onto `target` (an absolute rotation from
	-- WheelDrawing.targetRotation); `onLanded` runs once the disc stops on it.
	spin: (target: number, quick: boolean, onLanded: () -> ()) -> (),
	-- The request failed: ease back to the resting rotation.
	unwind: () -> (),
	-- Put the disc on `rotation` at once (Reduce Motion / closed): stops all motion and FX.
	snap: (rotation: number) -> (),
	-- Celebrate slice `index` (it is under the pointer); `reduced` = static version.
	win: (index: number, message: string, reduced: boolean) -> (),
	-- Stop everything now on the final rotation (screen closing). Never runs onLanded.
	settle: () -> (),
	-- True while the disc is moving towards a server result (wind-up included).
	busy: () -> boolean,
	Destroy: () -> (),
}

local WheelFx = {}

--[[
	Builds the presenter for `wheel` (call once, right after WheelDrawing.build).
	@param wheel    WheelDrawing handle (its layers are animated, never rebuilt)
	@param slices   LuckySpinConfig.Slices (colours, icons, ids → celebration tier)
	@param rotation the disc's resting rotation now (a slice centre under the pointer)
	@return Fx
]]
function WheelFx.new(wheel: WheelDrawing.Wheel, slices: { LuckySpinConfig.Slice }, rotation: number): Fx
	local canvas, flapperGui, body = wheel.canvas, wheel.flapper, wheel.body
	local glow, streaks, rays = wheel.glow, wheel.streaks, wheel.rays
	local bulbs, rayBars, segments = wheel.bulbs, wheel.rayBars, wheel.streakSegments
	local spacing = wheel.pegSpacing
	local centre, radius = wheel.centre, wheel.radius
	local bulbCfg = Cfg.Bulbs
	local group = math.max(1, bulbCfg.Group)

	-- ── Pooled layers owned here (built once) ───────────────────────────────────────────────

	-- Confetti / sparkles above the wheel, below the pop (root children: Body 1, Confetti 5,
	-- WinPop 6, PopIcon 7).
	local confettiLayer = Create.new("Frame", {
		Name = "Confetti",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Active = false,
		Selectable = false,
		ZIndex = 5,
		Parent = wheel.root,
	}) :: Frame
	confettiLayer:SetAttribute("Decorative", true)
	local confetti = HatchConfetti.new(confettiLayer, Cfg.ConfettiPool, 5)

	-- "You won ...!" under the hub (the winning slice at the top stays visible).
	local pop = StudUI.text({
		name = "WinPop",
		text = "",
		textSize = POP_TEXT,
		font = "shout",
		color = UIStyleConfig.Colors.yellow.accent,
		wrap = true,
		size = UDim2.fromOffset(math.floor(wheel.size * 0.92), POP_TEXT * 2 + 24),
		position = UDim2.fromOffset(centre, centre + radius * POP_DROP),
		anchor = Vector2.new(0.5, 0.5),
		zIndex = 6,
		parent = wheel.root,
	})
	pop.Visible = false
	local popScale = Create.new("UIScale", { Name = "Pop", Scale = 1, Parent = pop }) :: UIScale

	-- The won slice's icon over the hub: one pre-built icon per slice in one holder.
	local iconSide = Cfg.Pop.IconSize
	local iconHolder = Create.new("Frame", {
		Name = "PopIcon",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(centre, centre),
		Size = UDim2.fromOffset(iconSide, iconSide),
		BackgroundTransparency = 1,
		Visible = false,
		Active = false,
		Selectable = false,
		ZIndex = 7,
		Parent = wheel.root,
	}) :: Frame
	local iconScale = Create.new("UIScale", { Name = "Pop", Scale = 1, Parent = iconHolder }) :: UIScale
	local popIcons: { GuiObject } = {}
	for index, slice in slices do
		local icon = StudUI.icon(slice.icon, iconSide, 7)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Visible = false
		icon.Parent = iconHolder
		popIcons[index] = icon
	end

	-- Confetti palette per slice: its colour (and a light tint) mixed into the party colours;
	-- the rare / jackpot slices add gold.
	local palettes: { { Color3 } } = {}
	for index, slice in slices do
		local palette = { slice.color, slice.color:Lerp(WHITE, 0.45) }
		for _, color in HatchAnimConfig.Confetti.Party do
			table.insert(palette, color)
		end
		local _, tierName = Cfg.tierFor(slice.id)
		if tierName == "rare" or tierName == "jackpot" then
			for _, color in HatchAnimConfig.Confetti.Gold do
				table.insert(palette, color)
			end
		end
		palettes[index] = palette
	end

	-- Fetch every wheel sound now (first open), so the first tick never waits on a download.
	Sound.warm(Cfg.soundKeys())

	-- ── State ───────────────────────────────────────────────────────────────────────────────

	local phase: Phase = "idle"
	local phaseT = 0
	local angle = rotation -- the disc rotation shown now
	local lastAngle = rotation -- last frame's rotation (peg crossings)
	local home = rotation -- the resting rotation (a slice centre); wind-up / unwind pivot on it
	local fromOffset = 0 -- offset from `home` a wind-up / unwind started at
	local windSeconds = Cfg.WindUp.Seconds
	local plan: SpinMotion.Plan? = nil
	local landing = rotation -- the spin's final rotation (without the overshoot)
	local onLanded: (() -> ())? = nil
	local pending: Pending? = nil
	local flap: SpinMotion.Flapper = { angle = 0, velocity = 0 }
	local lastTickAt = -math.huge

	-- Written-value caches (a write happens only when the value changes).
	local canvasWritten = rotation
	local flapWritten = 0
	local streakWritten = 0
	local glowWritten = 1
	local rayWritten = -1
	local rayAngle = 0
	local popWritten = 1
	local popT = -1 -- seconds the animated pop has been up (< 0 = not shown by the driver)
	local held = false -- Studio DebugHold
	local shaken = false

	-- Bulbs: "chase" (every group-th lit, stepping clockwise), "blink" / "solid" (win colour).
	local chasePhase = 0
	local chaseStep = 0
	local bulbMode = "chase"
	local blinkLit = false

	-- Celebration.
	local winT = -1 -- seconds into the celebration (< 0 = none)
	local winTier: LuckyWheelFxConfig.Tier? = nil
	local winColor = bulbCfg.Lit
	local raysOn = false
	local winToken = 0 -- bumps cancel delayed cues / pop hides of an older win
	local shakeT, shakeAmp = math.huge, 0

	local connection: RBXScriptConnection? = nil
	local idleHandle: OfferFx.Handle
	-- Forward declaration: `step` hands a queued launch over to `launch` (defined after the
	-- driver, which it needs).
	local launch: (queued: Pending) -> ()

	-- ── Writers ─────────────────────────────────────────────────────────────────────────────

	local function writeCanvas()
		if angle ~= canvasWritten then
			canvasWritten = angle
			canvas.Rotation = angle
		end
	end

	local function writeFlapper()
		local q = SpinMotion.quantize(flap.angle, Cfg.Flapper.WriteStep)
		if q ~= flapWritten then
			flapWritten = q
			flapperGui.Rotation = q
		end
	end

	-- Motion arcs at `opacity` (0 hides them); they turn with the disc while shown.
	local function writeStreaks(opacity: number)
		if opacity ~= streakWritten then
			streakWritten = opacity
			streaks.Visible = opacity > 0
			if opacity > 0 then
				for _, segment in segments do
					segment.frame.BackgroundTransparency = 1 - opacity * (1 - segment.fade)
				end
			end
		end
		if streakWritten > 0 then
			streaks.Rotation = angle
		end
	end

	-- Shows chase step `step`: from another chase step only the bulbs that switch are written
	-- (two thirds of them for a group of 3), from a blink / solid colour every bulb.
	local function setChase(step: number)
		if bulbMode == "chase" and step == chaseStep then
			return
		end
		local full = bulbMode ~= "chase"
		for index, bulb in bulbs do
			local lit = SpinMotion.bulbLit(index, step, group)
			if full or lit ~= SpinMotion.bulbLit(index, chaseStep, group) then
				bulb.BackgroundColor3 = if lit then bulbCfg.Lit else bulbCfg.Dim
			end
		end
		bulbMode = "chase"
		chaseStep = step
	end

	-- Advances the chase by `hz` steps / s.
	local function advanceChase(hz: number, dt: number)
		-- Wrapped by a multiple of the group, so the pattern never jumps.
		chasePhase = (chasePhase + hz * dt) % (group * 1000)
		setChase(math.floor(chasePhase) % group)
	end

	local function paintAll(color: Color3)
		for _, bulb in bulbs do
			bulb.BackgroundColor3 = color
		end
	end

	local function playCue(cue: LuckyWheelFxConfig.Cue)
		Sound.play(cue.key, { pitch = cue.pitch, volume = cue.volume })
	end

	-- One tick for a peg crossing at `speed` deg/s (at most one per Tick.MinGap).
	local function tick(speed: number)
		local now = os.clock()
		if now - lastTickAt < Cfg.Tick.MinGap then
			return
		end
		lastTickAt = now
		local u = SpinMotion.speedNorm(speed, Cfg.Tick.TopSpeed)
		Sound.play(Cfg.Tick.Key, {
			pitch = SpinMotion.lerpRange(Cfg.Tick.Pitch, u),
			volume = SpinMotion.lerpRange(Cfg.Tick.Volume, u),
		})
	end

	-- FX budget for the current graphics tier.
	local function quality(): LuckyWheelFxConfig.Quality
		local tier = OfferFx.tier()
		return if tier == "Low"
			then Cfg.Quality.Low
			elseif tier == "Medium" then Cfg.Quality.Medium
			else Cfg.Quality.High
	end

	-- True when the idle chase may move (the same gate the OfferFx idle animator has: a rate
	-- above 0 for this graphics tier and no Reduce Motion).
	local function idleChaseAllowed(): boolean
		if OfferFx.reducedMotion() then
			return false
		end
		local tier, rates = OfferFx.tier(), bulbCfg.IdleRates
		local hz = if tier == "Low" then rates.Low elseif tier == "Medium" then rates.Medium else rates.High
		return hz > 0
	end

	local function hidePop()
		popT = -1
		pop.Visible = false
		iconHolder.Visible = false
	end

	-- Ends the celebration's glow / rays / blink (confetti already in the air keeps falling).
	local function clearWin()
		winT = -1
		winTier = nil
		raysOn = false
		if glowWritten ~= 1 then
			glowWritten = 1
			glow.GroupTransparency = 1
		end
		glow.Visible = false
		rays.Visible = false
		rayWritten = -1
		-- Back to the chase pattern (a full repaint, since the bulbs show the win colour).
		setChase(chaseStep)
	end

	-- A new wind-up / snap: the old celebration (and its pending cues / pop hide) is over.
	local function cancelWin()
		winToken += 1
		clearWin()
		hidePop()
	end

	-- ── Driver ──────────────────────────────────────────────────────────────────────────────

	local function stopDriver()
		local current = connection
		if current ~= nil then
			connection = nil
			current:Disconnect()
			if IS_STUDIO then
				wheel.root:SetAttribute("FxDriving", false)
			end
		end
		idleHandle.setEnabled(true)
	end

	-- The disc reached the plan's end (slice centre + overshoot): normalise, rock back, callback.
	local function land()
		-- Subtract whole turns from every angle in play (same picture, small numbers, and a
		-- multiple of 360 is a multiple of the peg spacing, so crossings stay exact).
		local wrap = landing - landing % 360
		home = landing - wrap
		angle -= wrap
		lastAngle -= wrap
		plan = nil
		phase = "settle"
		phaseT = 0
		local callback = onLanded
		onLanded = nil
		if callback ~= nil then
			callback()
		end
	end

	-- One celebration frame (glow pulse, rays, end of the window).
	local function stepWin(dt: number, tier: LuckyWheelFxConfig.Tier)
		winT += dt
		local strength = SpinMotion.pulse(winT, tier.seconds, tier.pulseHz) * tier.glow
		local transparency = SpinMotion.quantize(1 - strength, GLOW_STEP)
		if transparency ~= glowWritten then
			glowWritten = transparency
			glow.GroupTransparency = transparency
			glow.Visible = transparency < 1
		end
		if raysOn then
			local opacity =
				SpinMotion.quantize(SpinMotion.fade(winT, tier.seconds, Cfg.Rays.FadeIn, Cfg.Rays.FadeOut), RAY_STEP)
			if opacity ~= rayWritten then
				rayWritten = opacity
				rays.Visible = opacity > 0
				for _, bar in rayBars do
					bar.BackgroundTransparency = 1 - opacity
				end
			end
			rayAngle = (rayAngle + Cfg.Rays.DegreesPerSecond * dt) % 360
			rays.Rotation = rayAngle
		end
		if winT >= tier.seconds then
			clearWin()
		end
	end

	-- The reward pop: punch in (both scales finish at exactly 1), hide after Pop.Seconds. Driven
	-- here (not a timer) so it outlives a short celebration and freezes with DebugHold.
	local function stepPop(dt: number)
		popT += dt
		local punch = SpinMotion.backOut(popT / Cfg.Pop.PunchSeconds)
		local scale = Cfg.Pop.StartScale + (1 - Cfg.Pop.StartScale) * punch
		if scale ~= popWritten then
			popWritten = scale
			popScale.Scale = scale
			iconScale.Scale = scale
		end
		if popT >= Cfg.Pop.Seconds then
			hidePop()
		end
	end

	-- The one per-frame step (see the module header).
	local function step(rawDt: number)
		local dt = if held then 0 else math.clamp(rawDt, 0, MAX_DT)
		local direction = 0
		local speed = 0
		local measured = true

		-- 1. Disc motion for the current phase.
		if phase == "windup" then
			phaseT += dt
			angle = home + SpinMotion.blend(fromOffset, -Cfg.WindUp.Degrees, phaseT, windSeconds)
			direction = -1
			if phaseT >= windSeconds then
				local queued = pending
				if queued ~= nil then
					launch(queued)
				else
					phase = "hold"
					phaseT = 0
				end
			end
		elseif phase == "hold" then
			phaseT += dt
			local tremble = Cfg.WindUp.Tremble * math.sin(phaseT * 2 * math.pi * Cfg.WindUp.TrembleHz)
			angle = home - Cfg.WindUp.Degrees + tremble
			direction = -1
		elseif phase == "spin" then
			local current = plan
			if current ~= nil then
				phaseT += dt
				local sampled, velocity = SpinMotion.sample(current, phaseT)
				angle = sampled
				speed = velocity
				measured = false
				direction = 1
				if phaseT >= SpinMotion.duration(current) then
					land()
				end
			end
		elseif phase == "settle" then
			phaseT += dt
			angle = home + SpinMotion.blend(Cfg.Spin.Overshoot, 0, phaseT, Cfg.Spin.Settle)
			direction = -1
			if phaseT >= Cfg.Spin.Settle then
				angle = home
				phase = "idle"
			end
		elseif phase == "unwind" then
			phaseT += dt
			angle = home + SpinMotion.blend(fromOffset, 0, phaseT, Cfg.WindUp.Unwind)
			direction = 1
			if phaseT >= Cfg.WindUp.Unwind then
				angle = home
				phase = "idle"
			end
		end
		if measured and dt > 0 then
			speed = math.abs(angle - lastAngle) / dt
		end

		-- 2. Pegs: a tick per crossing, the flapper knocked / pushed / springing back.
		local crossed = SpinMotion.crossings(lastAngle, angle, spacing)
		lastAngle = angle
		if crossed ~= 0 then
			tick(speed)
		end
		SpinMotion.stepFlapper(flap, angle, direction, crossed, dt, spacing, Cfg.Flapper)
		writeCanvas()
		writeFlapper()

		-- 3. Motion arcs (spin only, not on Low graphics).
		local streakOpacity = 0
		if phase == "spin" and quality().streaks then
			local s = Cfg.Streaks
			streakOpacity = SpinMotion.streakOpacity(speed, s.StartSpeed, s.FullSpeed, s.MaxOpacity, s.Step)
		end
		writeStreaks(streakOpacity)

		-- 4. Celebration, then bulbs (blink while celebrating, speed-linked chase while moving,
		-- idle chase otherwise unless the idle chase is parked for this tier / Reduce Motion).
		local tier = winTier
		if winT >= 0 and tier ~= nil then
			stepWin(dt, tier)
		end
		if winT >= 0 then
			local lit = SpinMotion.blinkOn(winT, bulbCfg.WinBlinkHz)
			if bulbMode ~= "blink" or lit ~= blinkLit then
				bulbMode = "blink"
				blinkLit = lit
				paintAll(if lit then winColor else bulbCfg.Dim)
			end
		elseif bulbMode ~= "solid" then -- (a static Reduce Motion win colour holds until clearWin)
			if phase ~= "idle" then
				advanceChase(SpinMotion.lerpRange(bulbCfg.SpinHz, SpinMotion.speedNorm(speed, Cfg.Tick.TopSpeed)), dt)
			elseif idleChaseAllowed() then
				advanceChase(bulbCfg.IdleHz, dt)
			end
		end

		-- 5. Pop, confetti + shake.
		if popT >= 0 then
			stepPop(dt)
		end
		confetti.step(dt)
		if shakeT < SHAKE_SECONDS then
			shakeT += dt
			local x, y = SpinMotion.shake(shakeT, SHAKE_SECONDS, shakeAmp)
			body.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
			shaken = true
		elseif shaken then
			shaken = false
			body.Position = UDim2.new()
		end

		-- 6. Everything at rest: drop the connection (the idle chase takes over).
		if
			phase == "idle"
			and winT < 0
			and popT < 0
			and confetti.active() == 0
			and not shaken
			and SpinMotion.flapperResting(flap)
		then
			flap.angle, flap.velocity = 0, 0
			writeFlapper()
			writeStreaks(0)
			stopDriver()
		end
	end

	local function ensureDriver()
		if connection ~= nil then
			return
		end
		idleHandle.setEnabled(false)
		connection = RunService.PreRender:Connect(step)
		if IS_STUDIO then
			wheel.root:SetAttribute("FxDriving", true)
		end
	end

	if IS_STUDIO then
		wheel.root:SetAttribute("FxDriving", false)
		wheel.root:GetAttributeChangedSignal("DebugHold"):Connect(function()
			held = wheel.root:GetAttribute("DebugHold") == true
		end)
	end

	-- Idle bulb chase through the shared decoration driver (see the module header).
	idleHandle = OfferFx.register({
		root = body,
		rates = bulbCfg.IdleRates,
		step = function(dt: number, _elapsed: number)
			if connection == nil then
				advanceChase(bulbCfg.IdleHz, dt)
			end
		end,
	})

	-- Starts the spin phase from the current rotation (wind-up pose or rest).
	launch = function(queued: Pending)
		pending = nil
		local scale = if queued.quick then Cfg.QuickSpin.Scale else 1
		local total = LuckySpinConfig.SpinAnimationSeconds * scale
		local launchT = math.min(Cfg.Spin.Launch * scale, total * 0.5)
		landing = queued.target
		plan = SpinMotion.plan(angle, queued.target + Cfg.Spin.Overshoot, launchT, total - launchT, Cfg.Spin.Power)
		onLanded = queued.onLanded
		phase = "spin"
		phaseT = 0
		playCue(Cfg.Sounds.Launch)
		ensureDriver()
	end

	-- Stops every animation and FX immediately and rests the disc on `final`.
	local function stopAll(final: number)
		pending = nil
		plan = nil
		onLanded = nil
		phase = "idle"
		phaseT = 0
		home = final
		angle = final
		lastAngle = final
		writeCanvas()
		flap.angle, flap.velocity = 0, 0
		writeFlapper()
		writeStreaks(0)
		cancelWin()
		confetti.clear()
		shakeT = math.huge
		if shaken then
			shaken = false
			body.Position = UDim2.new()
		end
		stopDriver()
	end

	local fx: Fx = {
		windUp = function(quick: boolean)
			if phase == "spin" or phase == "windup" or phase == "hold" then
				return
			end
			cancelWin()
			fromOffset = angle - home
			windSeconds = if quick then Cfg.WindUp.QuickSeconds else Cfg.WindUp.Seconds
			phase = "windup"
			phaseT = 0
			playCue(Cfg.Sounds.WindUp)
			ensureDriver()
		end,
		spin = function(target: number, quick: boolean, callback: () -> ())
			local queued: Pending = { target = target, quick = quick, onLanded = callback }
			if phase == "windup" then
				-- Finish pulling back first (the launch reads better from the full wind-up).
				pending = queued
			else
				cancelWin()
				launch(queued)
			end
		end,
		unwind = function()
			pending = nil
			if phase == "windup" or phase == "hold" then
				fromOffset = angle - home
				phase = "unwind"
				phaseT = 0
				ensureDriver()
			end
		end,
		snap = function(final: number)
			stopAll(final)
		end,
		win = function(index: number, message: string, reduced: boolean)
			local slice = slices[index]
			if slice == nil then
				return
			end
			local tier, tierName = Cfg.tierFor(slice.id)
			winToken += 1
			local token = winToken
			-- Sting (always; Sound skips it when SFX are muted) + the rumble for the big ones.
			for _, cue in tier.sting do
				if cue.delay <= 0 then
					playCue(cue)
				else
					task.delay(cue.delay, function()
						if winToken == token then
							playCue(cue)
						end
					end)
				end
			end
			local haptic = tier.haptic
			if haptic ~= nil then
				Haptics.play(haptic)
			end
			-- Reward pop: the slice icon over the hub, the line under it.
			pop.Text = message
			pop.Visible = true
			for i, icon in popIcons do
				icon.Visible = i == index
			end
			iconHolder.Visible = true
			winColor = slice.color:Lerp(WHITE, 0.25)
			if reduced then
				-- Static celebration: no motion at all, gone after the tier's window (timers: the
				-- driver never runs with Reduce Motion).
				task.delay(Cfg.Pop.Seconds, function()
					if winToken == token then
						hidePop()
					end
				end)
				popWritten = 1
				popScale.Scale = 1
				iconScale.Scale = 1
				glowWritten = 1 - tier.glow * 0.7
				glow.GroupTransparency = glowWritten
				glow.Visible = true
				bulbMode = "solid"
				paintAll(winColor)
				task.delay(tier.seconds, function()
					if winToken == token then
						clearWin()
					end
				end)
				return
			end
			popT = 0
			popWritten = Cfg.Pop.StartScale
			popScale.Scale = popWritten
			iconScale.Scale = popWritten
			winTier = tier
			winT = 0
			local budget = quality()
			-- Rays behind the wheel in the slice's colour.
			raysOn = tier.rays and budget.rays
			if raysOn then
				local rayColor = slice.color:Lerp(WHITE, Cfg.Rays.Whiten)
				for _, bar in rayBars do
					bar.BackgroundColor3 = rayColor
					bar.BackgroundTransparency = 1
				end
				rayWritten = 0
				rays.Visible = false
			end
			-- Confetti from the winning slice (+ side cannons for the jackpot) and sparkles on it.
			local palette = palettes[index]
			local origin = Vector2.new(centre, centre - radius * CONFETTI_RISE)
			local pieces = math.floor(tier.confetti * budget.confetti + 0.5)
			if tier.sideBursts then
				local sidePieces = math.floor(pieces / 4)
				confetti.burst(Vector2.new(centre - radius * 1.05, centre + radius * 0.2), sidePieces, palette)
				confetti.burst(Vector2.new(centre + radius * 1.05, centre + radius * 0.2), sidePieces, palette)
				pieces -= 2 * sidePieces
			end
			confetti.burst(origin, pieces, palette)
			confetti.sparkle(
				origin,
				radius * SPARKLE_RADIUS,
				math.floor(tier.sparkles * budget.sparkles + 0.5),
				slice.color
			)
			if budget.shake and tier.shake > 0 then
				shakeT = 0
				shakeAmp = tier.shake
			end
			-- QA hook: Studio probes (docs/verification/r81-*) read which celebration played.
			wheel.root:SetAttribute("LastWinTier", tierName)
			ensureDriver()
		end,
		settle = function()
			local final = home
			if phase == "spin" then
				final = landing % 360
			elseif pending ~= nil then
				final = (pending :: Pending).target % 360
			end
			stopAll(final)
		end,
		busy = function(): boolean
			return phase == "windup" or phase == "hold" or phase == "spin"
		end,
		Destroy = function()
			stopAll(home)
			idleHandle.destroy()
			confetti.Destroy()
		end,
	}
	return fx
end

return WheelFx
