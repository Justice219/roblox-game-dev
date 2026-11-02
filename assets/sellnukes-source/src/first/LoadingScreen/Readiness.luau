--!strict
--[[
	Readiness — what "SellNukes is ready to play" means, and how far along we are.

	Purpose (owner R16: "all the models took forever to load in. Make sure there's a loading screen
	before the 'your plot is' shows"; owner R122: the loading screen must not eat the first minute):
		The loading screen stays up until the player's world is genuinely there, not for a fixed
		time — but never longer than a phone on a slow connection can bear. This module is the pure
		bookkeeping for that (no Instances, no yielding, unit-tested by tests/loading-screen.luau):
		a STAGED list of weighted steps, each done or partly done, the asset budget, the timing
		rules for when to hand off and why, and the boot-step telemetry attributes.
		Ported from RoBeasts' ReplicatedFirst loader.

	Steps (in the order the player reads their captions):
		Loaded   game:IsLoaded() — the initial world snapshot has replicated
		Client   LocalPlayer attribute ClientBooted (every client controller started)
		Profile  the profile snapshot arrived (LocalPlayer attribute ProfileReady, or
		         ClientState.profile ~= nil)
		World    Workspace attribute WorldReady == true (server built the hub / world, B4)
		Plot     the player's plot has PlotReady == true (B4; plot model attribute, or the
		         LocalPlayer attribute)
		Assets   the CRITICAL preload (Shared.World.PreloadList.forClientCritical: brand art, hot UI
		         icons, this player's plot frame + owned builds + the current next pads), with a
		         REAL count. Bounded by ASSET_BUDGET: when the budget runs out the step is CUT
		         (done, flagged) and the rest keeps downloading in the background after hand-off,
		         followed by the DEFERRED list (every other hub / area mesh, Loader).
		Loaded / Client / Profile / World / Plot are CRITICAL: they always gate the hand-off (only
		the TAP TO CONTINUE prompt after TIMEOUT or AUTO_CONTINUE skip them). Assets gates it for
		at most ASSET_BUDGET seconds.

	Timing rules (R122 field data: phones averaged 26 s on build 0.7.1 because the 30 s asset
	budget held the bar; Roblox ranks on first-play bounce < 60 s, so the screen must be quick):
		- Hand off when every step is done AND at least MIN_SHOW seconds passed ("ready", or
		  "budget" when the Assets step was cut by ASSET_BUDGET).
		- After TIMEOUT seconds a "TAP TO CONTINUE" prompt appears (tap / click anywhere, A / Enter)
		  so nobody is stuck ("tap" when the player uses it).
		- After AUTO_CONTINUE seconds it hands off by itself ("auto": an AFK player still gets in).
		  HudFocusConfig.LoadingTimeoutSeconds (the HUD gate's safety net, Client/UI/Widgets/
		  LoadingGate) must stay ABOVE AUTO_CONTINUE so the gate never opens under a live screen.

	Boot-step telemetry (R122): at hand-off the Loader publishes, as LocalPlayer attributes,
	`BootStep<StepId>` = the step's completion second relative to the loader start (only steps
	that finished) and `BootEnd` = the hand-off reason ("ready" | "budget" | "tap" | "auto"), BEFORE
	`BootSeconds`; Client/Analytics/ClientPerfReporter sends them once per session (the names and
	orders mirror Shared/Analytics/ClientPerfConfig, which this ReplicatedFirst module cannot
	require; tests/loading-screen.luau asserts they match).

	Example:
		local tracker = Readiness.new(os.clock())
		tracker:complete("Loaded", os.clock())
		tracker:startAssets(os.clock())
		tracker:setFraction("Assets", 0.5)
		print(tracker:progress(), tracker:caption())
		local go, reason = tracker:handOff(os.clock()) --> false, "waiting"
]]

export type StepId = "Loaded" | "Client" | "Profile" | "World" | "Plot" | "Assets"

-- Why the screen handed off ("waiting" = not yet). See the module header.
export type HandOffReason = "ready" | "budget" | "tap" | "auto" | "waiting"

export type Step = {
	id: StepId,
	caption: string, -- shown while this step is the current one
	weight: number, -- share of the progress bar (weights sum to 1)
	fraction: number, -- 0..1 partial progress
	doneAt: number?, -- os.clock() when completed (or cut by the budget)
	cut: boolean, -- true when the budget ended the step before its work finished (Assets only)
}

-- One LocalPlayer attribute the Loader sets at hand-off (ordered: see stepAttributes).
export type Attribute = { name: string, value: number | string }

local Readiness = {}
Readiness.__index = Readiness

--[[
	Timing tunables (seconds). ReplicatedFirst runs before ReplicatedStorage.Shared replicates, so
	these live here instead of Shared/Config. R122 values: TIMEOUT 45 → 20, AUTO_CONTINUE 60 → 30,
	ASSET_BUDGET 30 → 6.
]]
-- Seconds the screen stays up at minimum (the logo entrance always lands).
Readiness.MIN_SHOW = 2.4
-- Seconds before the "TAP TO CONTINUE" prompt.
Readiness.TIMEOUT = 20
-- Seconds after which the screen hands off by itself.
Readiness.AUTO_CONTINUE = 30
-- Seconds the CRITICAL asset preload may hold the bar back, counted from startAssets (the moment
-- the preload begins, right after game:IsLoaded()).
Readiness.ASSET_BUDGET = 6
-- Seconds to wait for the profile before preloading without the plot's own builds (the plot part
-- of the critical list; past the budget it only orders the background continuation).
Readiness.PROFILE_WAIT = 12

--[[
	Preload pacing. CRITICAL batches run back to back while the bar waits; after the critical
	list (or when the budget cut it) the remaining critical entries and the DEFERRED list continue
	in ONE background thread: small batches with a pause between them so the downloads never
	crowd gameplay streaming / remotes on a phone's connection.
]]
Readiness.CRITICAL_BATCH = 8
Readiness.BACKGROUND_BATCH = 4
Readiness.BACKGROUND_GAP = 0.5

Readiness.READY_CAPTION = "LET'S SELL SOME NUKES!"
Readiness.TIMEOUT_CAPTION = "JUMPING IN!"
Readiness.PROMPT_CAPTION = "STILL LOADING... TAP TO CONTINUE"

-- Boot telemetry attribute names (mirror ClientPerfConfig.BootStepAttributePrefix /
-- BootEndAttribute; BootSeconds = ClientPerfConfig.BootAttribute).
Readiness.STEP_ATTRIBUTE_PREFIX = "BootStep"
Readiness.END_ATTRIBUTE = "BootEnd"
Readiness.BOOT_ATTRIBUTE = "BootSeconds"
-- Every hand-off reason, in the wire order of ClientPerfConfig.BootEndReasons.
local END_REASONS: { HandOffReason } = { "ready", "budget", "tap", "auto" }
Readiness.END_REASONS = table.freeze(END_REASONS)

-- Step definitions: id, caption, weight. Weights sum to 1; Assets (the real downloads) is the
-- biggest share so the bar moves with what the player is actually waiting on.
local DEFINITIONS: { { id: StepId, caption: string, weight: number } } = {
	{ id = "Loaded", caption = "Unboxing the garage...", weight = 0.12 },
	{ id = "Client", caption = "Waking up Nukey...", weight = 0.08 },
	{ id = "Profile", caption = "Finding your business...", weight = 0.1 },
	{ id = "World", caption = "Building the hub...", weight = 0.12 },
	{ id = "Plot", caption = "Building your plot...", weight = 0.13 },
	{ id = "Assets", caption = "Polishing the pocket nukes...", weight = 0.45 },
}

export type Tracker = typeof(setmetatable(
	{} :: {
		steps: { Step },
		byId: { [StepId]: Step },
		startedAt: number,
		assetsStartedAt: number?, -- os.clock() when the critical preload began (budget clock)
	},
	Readiness
))

-- Two decimals, rounded DOWN (BootSeconds uses the same rule, so a step is never above it).
local function centiseconds(seconds: number): number
	return math.floor(math.max(seconds, 0) * 100) / 100
end

--[[
	Creates a tracker with every step pending.
	@param now  os.clock() when the screen appeared
	Example: local tracker = Readiness.new(os.clock())
]]
function Readiness.new(now: number): Tracker
	local steps: { Step } = {}
	local byId: { [StepId]: Step } = {}
	for _, definition in DEFINITIONS do
		local step: Step = {
			id = definition.id,
			caption = definition.caption,
			weight = definition.weight,
			fraction = 0,
			doneAt = nil,
			cut = false,
		}
		table.insert(steps, step)
		byId[definition.id] = step
	end
	return setmetatable({ steps = steps, byId = byId, startedAt = now, assetsStartedAt = nil }, Readiness)
end

--[[ Every step id in display order (= ClientPerfConfig.BootSteps). ]]
function Readiness.stepIds(): { StepId }
	local ids: { StepId } = {}
	for _, definition in DEFINITIONS do
		table.insert(ids, definition.id)
	end
	return ids
end

--[[ Marks a step finished (idempotent: the first completion time is kept). ]]
function Readiness.complete(self: Tracker, id: StepId, now: number)
	local step = self.byId[id]
	if step.doneAt == nil then
		step.doneAt = now
		step.fraction = 1
	end
end

--[[
	Starts the Assets budget clock (idempotent: the first call wins). The Loader calls it when the
	critical preload begins; until then the budget cannot cut anything.
	@param now os.clock()
]]
function Readiness.startAssets(self: Tracker, now: number)
	if self.assetsStartedAt == nil then
		self.assetsStartedAt = now
	end
end

--[[
	Cuts the Assets step once ASSET_BUDGET seconds passed since startAssets and it is still running:
	the step counts as done (flagged `cut`) so it stops holding the bar; the Loader keeps the
	downloads going in the background. Called by handOff every frame; safe to call any time.
	@param now os.clock()
	@return true when the Assets step is (now or already) cut by the budget
	Example: tracker:startAssets(0); tracker:applyBudget(Readiness.ASSET_BUDGET) --> true
]]
function Readiness.applyBudget(self: Tracker, now: number): boolean
	local assets = self.byId.Assets
	local started = self.assetsStartedAt
	if assets.doneAt == nil and started ~= nil and now - started >= Readiness.ASSET_BUDGET then
		assets.doneAt = now
		assets.cut = true
	end
	return assets.cut
end

--[[ True when the budget ended the Assets step before its critical list finished. ]]
function Readiness.wasCut(self: Tracker): boolean
	return self.byId.Assets.cut
end

--[[ Partial progress (0..1) of a running step; never goes backwards; NaN ignored. ]]
function Readiness.setFraction(self: Tracker, id: StepId, fraction: number)
	local step = self.byId[id]
	if step.doneAt == nil and fraction == fraction then
		step.fraction = math.max(step.fraction, math.clamp(fraction, 0, 0.999))
	end
end

--[[ True once `id` completed (or, for Assets, was cut by the budget). ]]
function Readiness.isDone(self: Tracker, id: StepId): boolean
	return self.byId[id].doneAt ~= nil
end

--[[ True when every step is done. ]]
function Readiness.allDone(self: Tracker): boolean
	for _, step in self.steps do
		if step.doneAt == nil then
			return false
		end
	end
	return true
end

--[[ Weighted overall progress 0..1 (where the bar heads). ]]
function Readiness.progress(self: Tracker): number
	local total = 0
	for _, step in self.steps do
		total += step.weight * (if step.doneAt ~= nil then 1 else step.fraction)
	end
	return math.clamp(total, 0, 1)
end

--[[ Caption of the first pending step (or the ready caption). ]]
function Readiness.caption(self: Tracker): string
	for _, step in self.steps do
		if step.doneAt == nil then
			return step.caption
		end
	end
	return Readiness.READY_CAPTION
end

--[[
	Whether to hand off now, and why (applies the asset budget first).
	@return (shouldHandOff, reason):
		"ready"   every step done, nothing cut, MIN_SHOW passed
		"budget"  every step done but ASSET_BUDGET cut the critical preload, MIN_SHOW passed
		"auto"    AUTO_CONTINUE passed (whatever is still loading)
		"waiting" not yet ("tap" is decided by the Loader: the player answered TAP TO CONTINUE)
	Example: local go, why = tracker:handOff(os.clock())
]]
function Readiness.handOff(self: Tracker, now: number): (boolean, HandOffReason)
	self:applyBudget(now)
	local elapsed = now - self.startedAt
	if self:allDone() and elapsed >= Readiness.MIN_SHOW then
		return true, if self:wasCut() then "budget" else "ready"
	end
	if elapsed >= Readiness.AUTO_CONTINUE then
		return true, "auto"
	end
	return false, "waiting"
end

--[[ True when the "TAP TO CONTINUE" prompt should show (TIMEOUT passed, still loading). ]]
function Readiness.canSkip(self: Tracker, now: number): boolean
	return not self:allDone() and now - self.startedAt >= Readiness.TIMEOUT
end

--[[
	Size of the next preload batch and the pause after it.
	@param barWaiting true while the Assets step still holds the bar (critical list, budget left)
	@return (batchSize, gapSeconds): CRITICAL_BATCH back to back while the bar waits, else
	        BACKGROUND_BATCH with BACKGROUND_GAP between batches (the low-priority continuation)
	Example: Readiness.pace(false) --> 4, 0.5
]]
function Readiness.pace(barWaiting: boolean): (number, number)
	if barWaiting then
		return Readiness.CRITICAL_BATCH, 0
	end
	return Readiness.BACKGROUND_BATCH, Readiness.BACKGROUND_GAP
end

--[[
	Boot telemetry attributes for the hand-off, in the order the Loader must set them: one
	`BootStep<StepId>` per FINISHED step (seconds since `origin`, two decimals rounded down, so a
	step is never above BootSeconds measured from the same origin), then `BootEnd` = `reason`.
	BootSeconds is NOT included: the Loader sets it last (ClientPerfReporter reads the step
	attributes when BootSeconds changes).
	@param origin os.clock() of the loader start (the BootSeconds origin)
	@param reason the hand-off reason ("ready" | "budget" | "tap" | "auto"; anything else is
	       reported as "auto" — the screen handed off without the player or a finished load)
	@return ordered { name, value } list
	Example: tracker:stepAttributes(bootStart, "ready")[1] --> { name = "BootStepLoaded", value = 0.42 }
]]
function Readiness.stepAttributes(self: Tracker, origin: number, reason: string): { Attribute }
	local out: { Attribute } = {}
	for _, step in self.steps do
		local doneAt = step.doneAt
		if doneAt ~= nil then
			table.insert(
				out,
				{ name = Readiness.STEP_ATTRIBUTE_PREFIX .. step.id, value = centiseconds(doneAt - origin) }
			)
		end
	end
	local known = table.find(Readiness.END_REASONS, reason :: HandOffReason) ~= nil
	table.insert(out, { name = Readiness.END_ATTRIBUTE, value = if known then reason else "auto" })
	return out
end

--[[
	BootSeconds for the hand-off: seconds since `origin`, two decimals rounded down (the same rule
	as the step attributes, so every step <= BootSeconds).
	Example: Readiness.bootSeconds(10, 16.239) --> 6.23
]]
function Readiness.bootSeconds(origin: number, now: number): number
	return centiseconds(now - origin)
end

return Readiness
