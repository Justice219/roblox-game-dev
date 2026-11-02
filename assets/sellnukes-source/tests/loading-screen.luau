--!strict
--[[
	Loading screen regressions (src/first/LoadingScreen pure modules). Run:
		lune run tests/loading-screen

	Proves:
	  1. Readiness (owner R16 staged gate): the six steps in order (Loaded, Client, Profile, World,
	     Plot, Assets); weights sum to 1; progress is weighted, monotonic and clamped; NaN / >1
	     fractions are ignored or clamped; complete() is idempotent; captions follow the first
	     pending step; hand-off needs EVERY step AND MIN_SHOW (World / Plot block it); TAP TO
	     CONTINUE only after TIMEOUT while loading; AUTO_CONTINUE always hands off ("auto").
	  2. Composition: the 1280 x 720 canvas fits 1080p at 1.5x, phones get the readability floor,
	     TVs keep the 5 % title-safe margin, ultra-wide grows the canvas width; approach() never
	     goes backwards, converges and snaps.
	  3. R122 fast first minute: TIMEOUT 20 / AUTO_CONTINUE 30 / ASSET_BUDGET 6 (MIN_SHOW kept);
	     HudFocusConfig.LoadingTimeoutSeconds stays above AUTO_CONTINUE (the HUD gate never opens
	     under a live screen); the asset budget only runs after startAssets, cuts ONLY the Assets
	     step ("budget" reason), never a critical step (Loaded / Client / Profile / World / Plot
	     still gate the hand-off until TIMEOUT / AUTO_CONTINUE); hand-off reasons ready / budget /
	     auto; pace() = critical batches back to back, background batches with a pause.
	  4. R122 boot telemetry: stepAttributes = one BootStep<step> per FINISHED step (seconds since
	     the loader origin, rounded down, never above bootSeconds) then BootEnd; unknown reasons
	     report "auto"; the names / orders mirror ClientPerfConfig (BootSteps, BootEndReasons,
	     attribute names) so the reporter reads what the loader writes.
	  5. PreloadQueue: only "rbxassetid://<positive>" ids, deduped across both parts; critical
	     entries first, batches never mix critical and deferred; the bar fraction is halved until
	     the critical list is sealed and never counts past the handed-out entries; criticalDone
	     needs the seal; release() drops everything.
]]

local Readiness = require("../src/first/LoadingScreen/Readiness")
local Composition = require("../src/first/LoadingScreen/Composition")
local PreloadQueue = require("../src/first/LoadingScreen/PreloadQueue")
local ClientPerfConfig = require("../src/shared/Analytics/ClientPerfConfig")
local HudFocusConfig = require("../src/shared/Config/HudFocusConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end
local function near(a: number, b: number, epsilon: number?): boolean
	return math.abs(a - b) <= (epsilon or 1e-6)
end

-- 1. Readiness -------------------------------------------------------------------------------
local tracker = Readiness.new(100)
local ids = Readiness.stepIds()
check(
	#ids == 6
		and ids[1] == "Loaded"
		and ids[2] == "Client"
		and ids[3] == "Profile"
		and ids[4] == "World"
		and ids[5] == "Plot"
		and ids[6] == "Assets",
	"staged step order"
)
check(Readiness.TIMEOUT == 20 and Readiness.AUTO_CONTINUE > Readiness.TIMEOUT, "20 s prompt, later auto-continue")
local weights = 0
for _, step in tracker.steps do
	weights += step.weight
end
check(near(weights, 1), "weights sum to 1")
check(tracker:progress() == 0 and not tracker:allDone(), "starts empty")
check(tracker:caption() == "Unboxing the garage...", "first caption")

tracker:setFraction("Assets", 0.5)
check(near(tracker:progress(), 0.45 * 0.5), "fractional progress is weighted")
tracker:setFraction("Assets", 0.2)
check(near(tracker:progress(), 0.225), "fraction never goes backwards")
tracker:setFraction("Assets", 0 / 0)
check(near(tracker:progress(), 0.225), "NaN ignored")
tracker:setFraction("Assets", 5)
check(tracker.byId.Assets.fraction < 1 and not tracker:isDone("Assets"), "fraction < 1 never completes")

tracker:complete("Loaded", 101)
tracker:complete("Loaded", 150)
check(tracker.byId.Loaded.doneAt == 101, "complete is idempotent")
check(tracker:caption() == "Waking up Nukey...", "caption follows the first pending step")

local go, reason = tracker:handOff(101)
check(not go and reason == "waiting", "waits while steps are pending")
check(not tracker:canSkip(100 + Readiness.TIMEOUT - 0.1), "no prompt before TIMEOUT")
check(tracker:canSkip(100 + Readiness.TIMEOUT), "TAP TO CONTINUE on a slow load")

for _, id in { "Client", "Profile", "Assets" } do
	tracker:complete(id :: any, 101.5)
end
check(tracker:caption() == "Building the hub...", "world caption")
check(not tracker:handOff(100 + Readiness.MIN_SHOW + 5), "World + Plot block the hand-off")
tracker:complete("World", 101.6)
check(tracker:caption() == "Building your plot...", "plot caption")
check(not tracker:handOff(100 + Readiness.MIN_SHOW + 5), "the plot blocks the hand-off")
tracker:complete("Plot", 101.7)
check(tracker:allDone() and near(tracker:progress(), 1), "all done = 100 %")
check(tracker:caption() == Readiness.READY_CAPTION, "ready caption")
go = tracker:handOff(100 + Readiness.MIN_SHOW - 0.01)
check(not go, "MIN_SHOW holds an instant load")
go, reason = tracker:handOff(100 + Readiness.MIN_SHOW)
check(go and reason == "ready", "hands off when ready after MIN_SHOW")
check(not tracker:canSkip(100 + Readiness.TIMEOUT), "no prompt once loaded")

local stuck = Readiness.new(0)
check(not stuck:handOff(Readiness.TIMEOUT), "the prompt does not hand off by itself")
go, reason = stuck:handOff(Readiness.AUTO_CONTINUE)
check(go and reason == "auto", "AUTO_CONTINUE always hands off")

-- 2. Composition ----------------------------------------------------------------------------
local function size(x: number, y: number): any
	return { X = x, Y = y }
end
local scale, width, height = Composition.fit(size(1920, 1080), false)
check(near(scale, 1.5) and near(width, 1280) and near(height, 720), "1080p fits at 1.5x")
scale, width, height = Composition.fit(size(2560, 1080), false)
check(near(scale, 1.5) and width > 1280 and near(height, 720), "ultra-wide grows the canvas width")
scale = Composition.fit(size(1920, 1080), true)
check(near(scale, 1.5 * 0.9), "TV keeps the 5 % title-safe margin")
scale, width, height = Composition.fit(size(568, 270), false)
check(near(scale, Composition.MIN_SCALE) and width == 1280 and height == 720, "tiny phone: readability floor")
scale = Composition.fit(size(0, 0), false)
check(scale == Composition.MIN_SCALE, "zero size never divides by zero")

local shown = 0
for _ = 1, 120 do
	shown = Composition.approach(shown, 0.8, 1 / 60)
end
check(near(shown, 0.8), "approach converges and snaps")
check(Composition.approach(0.9, 0.5, 1 / 60) == 0.9, "approach never goes backwards")
check(Composition.approach(0.2, 0.6, -1) == 0.2, "negative dt is a no-op")

-- 3. R122 fast first minute ---------------------------------------------------------------
check(
	Readiness.TIMEOUT == 20 and Readiness.AUTO_CONTINUE == 30 and Readiness.ASSET_BUDGET == 6,
	"R122 timings: prompt 20 s, auto 30 s, asset budget 6 s"
)
check(Readiness.MIN_SHOW == 2.4, "MIN_SHOW kept")
check(
	HudFocusConfig.LoadingTimeoutSeconds > Readiness.AUTO_CONTINUE,
	"the HUD gate's safety timeout stays above AUTO_CONTINUE (never opens under a live screen)"
)
check(Readiness.ASSET_BUDGET < Readiness.TIMEOUT, "the asset budget ends long before the prompt")

-- The budget only starts with the preload, and only cuts Assets.
local budget = Readiness.new(0)
check(not budget:applyBudget(100), "no budget before startAssets")
check(not budget:isDone("Assets"), "Assets still pending without startAssets")
budget:startAssets(1)
budget:startAssets(3) -- idempotent: the first start wins
check(not budget:applyBudget(1 + Readiness.ASSET_BUDGET - 0.01), "within the budget nothing is cut")
for _, id in { "Loaded", "Client", "Profile", "World" } do
	budget:complete(id :: any, 2)
end
go, reason = budget:handOff(1 + Readiness.ASSET_BUDGET)
check(budget:isDone("Assets") and budget:wasCut(), "the budget cuts the Assets step")
check(not go and reason == "waiting", "a cut Assets step never skips a pending critical step (Plot)")
check(not budget:isDone("Plot"), "Plot is never cut by the budget")
budget:complete("Assets", 50)
check(budget.byId.Assets.doneAt == 1 + Readiness.ASSET_BUDGET, "a late finish keeps the cut time")
budget:complete("Plot", 9)
go, reason = budget:handOff(9)
check(go and reason == "budget", "every step done after a cut = budget hand-off")

local quick = Readiness.new(0)
quick:startAssets(0.5)
for _, id in Readiness.stepIds() do
	quick:complete(id, 1)
end
go, reason = quick:handOff(Readiness.MIN_SHOW)
check(go and reason == "ready" and not quick:wasCut(), "everything loaded in time = ready")
check(not quick:applyBudget(100), "a finished Assets step is never cut afterwards")

-- Critical steps gate until TIMEOUT (prompt) / AUTO_CONTINUE (auto), whatever the budget did.
local slowPlot = Readiness.new(0)
slowPlot:startAssets(0)
for _, id in { "Loaded", "Client", "Profile", "World" } do
	slowPlot:complete(id :: any, 1)
end
check(not slowPlot:handOff(Readiness.TIMEOUT - 0.01), "no hand-off while Plot is pending")
check(slowPlot:canSkip(Readiness.TIMEOUT), "TAP TO CONTINUE at TIMEOUT while Plot is pending")
go, reason = slowPlot:handOff(Readiness.AUTO_CONTINUE)
check(go and reason == "auto", "AUTO_CONTINUE hands off a stuck Plot")

local size, gap = Readiness.pace(true)
check(size == Readiness.CRITICAL_BATCH and gap == 0, "critical batches run back to back")
size, gap = Readiness.pace(false)
check(
	size == Readiness.BACKGROUND_BATCH and size < Readiness.CRITICAL_BATCH and gap > 0,
	"background batches are smaller and paced"
)

-- 4. R122 boot telemetry -------------------------------------------------------------------
check(Readiness.STEP_ATTRIBUTE_PREFIX == ClientPerfConfig.BootStepAttributePrefix, "step attribute prefix mirrors")
check(Readiness.END_ATTRIBUTE == ClientPerfConfig.BootEndAttribute, "end attribute mirrors")
check(Readiness.BOOT_ATTRIBUTE == ClientPerfConfig.BootAttribute, "boot attribute mirrors")
for index, id in Readiness.stepIds() do
	check(ClientPerfConfig.BootSteps[index] == id, `boot step {index} mirrors ({id})`)
end
check(#ClientPerfConfig.BootSteps == #Readiness.stepIds(), "same step count")
for index, why in Readiness.END_REASONS do
	check(ClientPerfConfig.BootEndReasons[index] == why, `hand-off reason {index} mirrors ({why})`)
end
check(#ClientPerfConfig.BootEndReasons == #Readiness.END_REASONS, "same reason count")

local timed = Readiness.new(10.5)
timed:complete("Loaded", 10.749)
timed:complete("Client", 12)
timed:startAssets(10.75)
timed:applyBudget(10.75 + Readiness.ASSET_BUDGET)
local attributes = timed:stepAttributes(10, "tap")
local byName: { [string]: any } = {}
local order: { string } = {}
for _, attribute in attributes do
	byName[attribute.name] = attribute.value
	table.insert(order, attribute.name)
end
check(near(byName.BootStepLoaded, 0.74), "step seconds since the origin, rounded down")
check(near(byName.BootStepClient, 2), "Client step second")
check(near(byName.BootStepAssets, 0.75 + Readiness.ASSET_BUDGET), "a cut Assets step reports its cut time")
check(byName.BootStepProfile == nil and byName.BootStepPlot == nil, "unfinished steps are not published")
check(order[#order] == "BootEnd" and byName.BootEnd == "tap", "BootEnd last, with the reason")
check(byName.BootSeconds == nil, "BootSeconds is left to the Loader (set last)")
check(timed:stepAttributes(10, "skip")[#timed:stepAttributes(10, "skip")].value == "auto", "unknown reason -> auto")
check(Readiness.bootSeconds(10, 16.239) == 6.23, "BootSeconds rounded down to 0.01 s")
check(Readiness.bootSeconds(10, 9) == 0, "BootSeconds never negative")
for _, attribute in attributes do
	if attribute.name ~= "BootEnd" then
		check((attribute.value :: number) <= Readiness.bootSeconds(10, 17), `{attribute.name} <= BootSeconds`)
	end
end

-- 5. PreloadQueue ----------------------------------------------------------------------------
for _, bad in { "rbxassetid://0", "rbxassetid://", "rbxassetid://12a", "http://x/1", "rbxasset://1", 5, nil } :: { any } do
	check(not PreloadQueue.validId(bad), `invalid id refused ({tostring(bad)})`)
end
check(PreloadQueue.validId("rbxassetid://123"), "a real asset id is valid")
local queue = PreloadQueue.new()
check(queue:criticalFraction() == 0.5, "an empty unsealed queue shows half (more critical ids will join)")
check(queue:add("image", "rbxassetid://1", true), "critical image queued")
check(not queue:add("mesh", "rbxassetid://1", true), "duplicate id refused")
check(not queue:add("mesh", "rbxassetid://0", true), "id 0 refused")
check(queue:addAll("mesh", { "rbxassetid://2", "rbxassetid://3", "bad" }, true) == 2, "addAll counts queued ids")
local ids: { string } = {}
local kinds: { any } = {}
local count, critical = queue:take(2, ids, kinds)
check(count == 2 and critical and ids[1] == "rbxassetid://1" and kinds[1] == "image", "critical first, in order")
queue:markLoaded()
queue:markLoaded()
queue:markLoaded() -- never past the handed-out entries
check(near(queue:criticalFraction(), 0.5 * 2 / 3), "unsealed share is halved; capped at handed-out entries")
queue:settle()
check(not queue:criticalDone(), "not done before the seal")
queue:add("mesh", "rbxassetid://4", true) -- the plot's part joins before the seal
queue:seal()
check(queue:add("mesh", "rbxassetid://5", false), "deferred id queued")
check(queue:add("mesh", "rbxassetid://6", true), "a critical add after the seal is queued as deferred")
local total, criticalCount = queue:counts()
check(total == 6 and criticalCount == 4, "4 critical + 2 deferred")
count, critical = queue:take(8, ids, kinds)
check(
	count == 2 and critical and ids[1] == "rbxassetid://3" and ids[2] == "rbxassetid://4",
	"a batch stops at the critical edge"
)
check(not queue:criticalDone(), "critical entries handed out but not settled")
queue:settle()
check(queue:criticalDone() and queue:criticalFraction() == 1, "critical done once every entry settled")
count, critical = queue:take(8, ids, kinds)
check(count == 2 and not critical and #ids == 2 and ids[1] == "rbxassetid://5", "deferred batch (reused arrays)")
check(queue:remaining() == 0, "nothing left")
count = queue:take(8, ids, kinds)
check(count == 0 and #ids == 0, "an empty take clears the arrays")
queue:release()
total, criticalCount = queue:counts()
check(total == 0 and criticalCount == 0 and queue:criticalDone(), "release drops everything")
check(not queue:add("mesh", "rbxassetid://9", true) or select(2, queue:counts()) == 0, "a released queue stays sealed")

print(`[loading-screen] {checks} checks passed`)
