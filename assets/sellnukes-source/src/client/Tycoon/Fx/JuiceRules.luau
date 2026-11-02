--!strict
--[[
	JuiceRules — pure maths of the R71 juice pass (no Instances, no services; Lune-tested in
	tests/juice.luau). Every number comes from Shared/Config/JuiceConfig.

		comboNext(count, lastAt, now)        the combo after one press (resets after Combo.Window)
		comboPitch(count)                    click pitch ladder: one semitone per press, 1.0 .. MaxPitch
		comboLabel(count)                    "x12!" from Combo.LabelFrom, else nil
		comboEvent(count)                    "big" at 25 / 50 / 100 / every 100, "ring" every 10, else nil
		labelScale(sincePress)               the label's punch scale after a press
		milestoneCrossed(old, new, every)    the highest milestone level crossed by a level-up, else nil
		milestoneKind(level, every, atFloor) "Cash" (odd milestones) | "Speed" (even; "Cash" once the
		                                     cycle is at its floor: speed beyond it is paid as cash)
		milestoneText(level, kind)           "LEVEL 50!", "x2 SPEED!"
		punch(age, seconds)                  camera punch envelope: FOV kick share, shake share (0 = done)
		fireworkPlan(seed, index)            one rocket: launch offset (x, z), height jitter, rise time
		perTier(row, tier)                   a JuiceConfig per-tier value (unknown tier -> Mid)
		rebirthTotal(profile)                main + every world's rebirth count (a rise = a rebirth)

	Connects to: Shared/Config/JuiceConfig, Client/Tycoon/Fx/{ClickCombo, ProducerJuice,
	CameraPunch, Fireworks, JuiceController}.

	Example:
		local count = JuiceRules.comboNext(4, 10.0, 10.5) --> 5
		local pitch = JuiceRules.comboPitch(count)        --> 2 ^ (4 / 12)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JuiceConfig = require(ReplicatedStorage.Shared.Config.JuiceConfig)

export type MilestoneKind = "Cash" | "Speed"
export type ComboEvent = "big" | "ring"

local JuiceRules = {}

local Combo = JuiceConfig.Combo
local Punch = JuiceConfig.Punch
local Fireworks = JuiceConfig.Fireworks

-- A finite number, else nil.
local function finite(value: unknown): number?
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- Deterministic 0..1 noise for (seed, k).
local function noise(seed: number, k: number): number
	local v = math.sin(seed * 12.9898 + k * 78.233) * 43758.5453
	return v - math.floor(v)
end

--[[
	The combo count after one press.
	@param count  combo before the press (0 = none)
	@param lastAt clock of the previous press (-inf = never)
	@param now    clock of this press
	@return the new count (1 when the chain broke)
	Example: JuiceRules.comboNext(4, 10.0, 10.5) --> 5 ; JuiceRules.comboNext(4, 10.0, 11.0) --> 1
]]
function JuiceRules.comboNext(count: number, lastAt: number, now: number): number
	local previous = finite(count) or 0
	local gap = now - lastAt
	if previous < 1 or gap ~= gap or gap < 0 or gap > Combo.Window then
		return 1
	end
	return math.floor(previous) + 1
end

--[[
	Click pitch for a combo: one semitone (SemitonesPerStep) per press above the first, capped.
	Example: JuiceRules.comboPitch(1) --> 1 ; JuiceRules.comboPitch(40) --> 1.6
]]
function JuiceRules.comboPitch(count: number): number
	local steps = math.max((finite(count) or 1) - 1, 0) * Combo.SemitonesPerStep
	return math.min(2 ^ (steps / 12), Combo.MaxPitch)
end

--[[ The combo label text ("x12!") from Combo.LabelFrom presses on, else nil. ]]
function JuiceRules.comboLabel(count: number): string?
	local n = finite(count)
	if n == nil or n < Combo.LabelFrom then
		return nil
	end
	return string.format("x%d!", math.floor(n))
end

--[[
	The extra effect of reaching `count`: "big" at Combo.BigAt (25 / 50 / 100) and every BigEvery
	after the last of them, "ring" every RingEvery presses otherwise, nil for ordinary presses.
	Example: JuiceRules.comboEvent(10) --> "ring" ; JuiceRules.comboEvent(50) --> "big"
]]
function JuiceRules.comboEvent(count: number): ComboEvent?
	local n = finite(count)
	if n == nil or n < 1 or n % 1 ~= 0 then
		return nil
	end
	if table.find(Combo.BigAt, n) ~= nil then
		return "big"
	end
	local lastBig = Combo.BigAt[#Combo.BigAt]
	if n > lastBig and n % Combo.BigEvery == 0 then
		return "big"
	end
	if n % Combo.RingEvery == 0 then
		return "ring"
	end
	return nil
end

--[[ True when a big combo burst also punches the camera (the 100 and every-100 bursts). ]]
function JuiceRules.comboPunches(count: number): boolean
	local n = finite(count) or 0
	return JuiceRules.comboEvent(n) == "big" and n >= Combo.BigAt[#Combo.BigAt]
end

--[[
	The combo label's scale `sincePress` seconds after a press: 1 + LabelPunch, easing back to 1.
	Example: JuiceRules.labelScale(0) --> 1.35 ; JuiceRules.labelScale(1) --> 1
]]
function JuiceRules.labelScale(sincePress: number): number
	local k = math.clamp((finite(sincePress) or math.huge) / Combo.PunchSeconds, 0, 1)
	return 1 + Combo.LabelPunch * (1 - k) * (1 - k)
end

--[[
	The highest milestone level crossed going from `old` to `new` (a level-up), else nil.
	@param every MilestoneEvery of the producer's world (25)
	Example: JuiceRules.milestoneCrossed(24, 26, 25) --> 25 ; JuiceRules.milestoneCrossed(26, 49, 25) --> nil
]]
function JuiceRules.milestoneCrossed(old: number, new: number, every: number): number?
	local a, b, step = finite(old), finite(new), finite(every)
	if a == nil or b == nil or step == nil or step < 1 or b <= a then
		return nil
	end
	local before = math.floor(a / step)
	local after = math.floor(b / step)
	if after <= before or after < 1 then
		return nil
	end
	return after * step
end

--[[
	What a milestone gives: odd milestones (25, 75 ...) x2 cash, even ones (50, 100 ...) x2 speed —
	unless the cycle already sits at its floor, where the extra speed is paid as cash (TycoonLogic
	"floor conversion"), so the banner says CASH.
	Example: JuiceRules.milestoneKind(50, 25, false) --> "Speed"
]]
function JuiceRules.milestoneKind(level: number, every: number, atFloor: boolean): MilestoneKind
	local index = math.floor((finite(level) or 0) / math.max(finite(every) or 1, 1))
	if index % 2 == 1 or atFloor then
		return "Cash"
	end
	return "Speed"
end

--[[
	The milestone banner's two lines.
	Example: JuiceRules.milestoneText(50, "Speed") --> "LEVEL 50!", "x2 SPEED!"
]]
function JuiceRules.milestoneText(level: number, kind: MilestoneKind): (string, string)
	local title = string.format("LEVEL %d!", math.floor(finite(level) or 0))
	return title, if kind == "Speed" then "x2 SPEED!" else "x2 CASH!"
end

--[[
	The camera punch envelope `age` seconds into a punch of `seconds`: the FOV kick share (a fast
	rise over the first 15 %, then an ease-out back to 0) and the shake share (linear decay).
	@return fov, shake (both 0..1; 0, 0 once done)
	Example: JuiceRules.punch(0, 0.45) --> 0, 1
]]
function JuiceRules.punch(age: number, seconds: number): (number, number)
	local length = math.max(finite(seconds) or Punch.Seconds, 1e-3)
	local t = (finite(age) or math.huge) / length
	if t < 0 or t >= 1 then
		return 0, 0
	end
	local attack = 0.15
	local fov = if t < attack then t / attack else (1 - (t - attack) / (1 - attack)) ^ 2
	return fov, 1 - t
end

--[[
	One rocket of a fireworks show.
	@param seed  show seed (decorrelates shows)
	@param index 1-based rocket index (start stagger)
	@return dx, dz (launch offset from the show centre, studs), height (studs), rise (s), delay (s),
	        hue (0..1 spark colour)
]]
function JuiceRules.fireworkPlan(seed: number, index: number): (number, number, number, number, number, number)
	local angle = noise(seed + index, 1) * 2 * math.pi
	local radius = Fireworks.Spread * (0.35 + 0.65 * noise(seed + index, 2))
	local height = Fireworks.Height + (noise(seed + index, 3) - 0.5) * 2 * Fireworks.HeightJitter
	local rise = Fireworks.RiseSeconds + (noise(seed + index, 4) - 0.5) * 2 * Fireworks.RiseJitter
	local delay = (index - 1) * Fireworks.Stagger
	return math.cos(angle) * radius, math.sin(angle) * radius, height, rise, delay, noise(seed + index, 5)
end

--[[
	A JuiceConfig per-tier value for an FxQuality tier (unknown tier -> Mid).
	Example: JuiceRules.perTier(JuiceConfig.PadBuy.Coins, "Low") --> 5
]]
function JuiceRules.perTier(row: { Low: number, Mid: number, High: number }, tier: string): number
	if tier == "Low" then
		return row.Low
	elseif tier == "High" then
		return row.High
	end
	return row.Mid
end

--[[
	Main + every world's rebirth count from an untyped profile (a rise = a rebirth somewhere).
	Example: JuiceRules.rebirthTotal({ rebirths = 2, worlds = { dino = { rebirths = 1 } } }) --> 3
]]
function JuiceRules.rebirthTotal(profile: { [string]: any }?): number
	if type(profile) ~= "table" then
		return 0
	end
	local total = math.max(finite(profile.rebirths) or 0, 0)
	local worlds = profile.worlds
	if type(worlds) == "table" then
		for _, world in worlds do
			if type(world) == "table" then
				total += math.max(finite(world.rebirths) or 0, 0)
			end
		end
	end
	return total
end

return table.freeze(JuiceRules)
