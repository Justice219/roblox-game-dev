--!strict
--[[
	WheelLogic — server rules for the Lucky Wheel (mutation side of LuckySpinConfig.status).

	Rules:
		refill   banks the free spins earned since lastFreeAt (one per FreeEverySeconds, up to
		         MaxFree); the first contact starts the timer instead of back-filling; while at
		         MaxFree the timer idles
		peek     which bank the next spin would use after a refill: "free" → "bonus" → "paid"
		         (nil = none). The service awaits PolicyService only when it is "paid".
		consume  uses a spin from the first non-empty bank (free → bonus → paid); restarts the
		         timer when a full free bank drops below MaxFree. A PAID spin (Robux-sourced: a
		         paid random item) is only used when `allowPaid` is true (the caller resolved the
		         player's policy to unrestricted, fail closed); otherwise nothing changes and the
		         reason is "restricted". Returns (source, nil) or (nil, "none" | "restricted").
		roll     weighted slice index for a unit random number in [0, 1) (deterministic for tests;
		         the service feeds it a server Random — never anything from the client)
		receipt  a Spins product receipt (Robux): policy unknown → "defer" (Roblox re-delivers;
		         never decided on an unknown answer), KNOWN restricted → "gems" (GemsPerSpin per
		         spin: the CALLER grants them through RewardGrant so analytics see the source),
		         else "spins" (added to the paid bank here). Nothing changes on "defer" / "gems".

	Example:
		WheelLogic.refill(profile.spin, now)
		local source, why = WheelLogic.consume(profile.spin, now, not restricted)
		if source then local index = WheelLogic.roll(rng:NextNumber()) end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LuckySpinConfig = require(ReplicatedStorage.Shared.Config.LuckySpinConfig)
local ProfileLogic = require(script.Parent.Parent.Economy.ProfileLogic)

export type SpinState = { free: number, lastFreeAt: number, paid: number, bonus: number }
export type Source = "free" | "bonus" | "paid"
export type Refusal = "none" | "restricted"

local WheelLogic = {}

--[[ Banks earned free spins (see the header). @return free spins after the refill ]]
function WheelLogic.refill(spin: SpinState, now: number): number
	local maxFree = LuckySpinConfig.MaxFree
	local every = LuckySpinConfig.FreeEverySeconds
	now = math.floor(now)
	spin.free = math.clamp(math.floor(spin.free), 0, maxFree)
	if spin.free >= maxFree then
		return spin.free
	end
	if spin.lastFreeAt <= 0 or spin.lastFreeAt > now then
		-- First contact (or a clock jump backwards): start the timer, never back-fill.
		spin.lastFreeAt = now
		return spin.free
	end
	local gained = (now - spin.lastFreeAt) // every
	if gained > 0 then
		spin.free = math.min(maxFree, spin.free + gained)
		spin.lastFreeAt = if spin.free >= maxFree then now else spin.lastFreeAt + gained * every
	end
	return spin.free
end

-- A whole, non-negative bank count (NaN / negatives / non-numbers → 0; fail closed).
local function bank(value: unknown): number
	return if type(value) == "number" and value == value and value > 0 then math.floor(value) else 0
end

--[[
	The bank the next spin would use (after banking earned free spins; mutates only the refill).
	@return "free" | "bonus" | "paid", or nil when every bank is empty
]]
function WheelLogic.peek(spin: SpinState, now: number): Source?
	WheelLogic.refill(spin, now)
	if spin.free > 0 then
		return "free"
	elseif bank(spin.bonus) > 0 then
		return "bonus"
	elseif bank(spin.paid) > 0 then
		return "paid"
	end
	return nil
end

--[[
	Uses one spin (free → bonus → paid; see the header).
	@param allowPaid the caller's resolved policy allows paid random items (false = fail closed)
	@return (source, nil), or (nil, "none") when every bank is empty, or (nil, "restricted") when
	        only paid spins are left and they are not allowed (nothing changes)
	Example: WheelLogic.consume(profile.spin, os.time(), false) --> nil, "restricted"
]]
function WheelLogic.consume(spin: SpinState, now: number, allowPaid: boolean): (Source?, Refusal?)
	local source = WheelLogic.peek(spin, now)
	if source == "free" then
		if spin.free >= LuckySpinConfig.MaxFree then
			spin.lastFreeAt = math.floor(now) -- the timer restarts when the bank drops below max
		end
		spin.free -= 1
		return "free", nil
	elseif source == "bonus" then
		spin.bonus = bank(spin.bonus) - 1
		return "bonus", nil
	elseif source == "paid" then
		if allowPaid ~= true then
			return nil, "restricted"
		end
		spin.paid = bank(spin.paid) - 1
		return "paid", nil
	end
	return nil, "none"
end

export type ReceiptOutcome = "defer" | "gems" | "spins"

--[[
	Applies a Spins product receipt for the buyer's policy (see the header; no yield).
	@param spins       the product's spin count (whole, ≥ 1; anything else → "defer", unchanged)
	@param policyKnown PolicyService has answered for the buyer
	@param restricted  that answer restricts paid random items
	@return (outcome, amount): "spins" + spins added to the paid bank, "gems" + the gems the caller
	        must grant instead, or "defer" + 0
	Example: WheelLogic.receipt(profile, 5, true, true) --> "gems", 200
]]
function WheelLogic.receipt(
	profile: any,
	spins: unknown,
	policyKnown: boolean,
	restricted: boolean
): (ReceiptOutcome, number)
	if type(spins) ~= "number" or spins ~= spins or spins < 1 or spins % 1 ~= 0 or policyKnown ~= true then
		return "defer", 0
	end
	if restricted ~= false then
		return "gems", spins * LuckySpinConfig.GemsPerSpin
	end
	local spin = profile.spin
	local before = bank(spin.paid)
	spin.paid = math.min(before + spins, ProfileLogic.Limits.MaxSpins)
	return "spins", spin.paid - before
end

--[[ The slice index (1-based) for a unit random number (weights from LuckySpinConfig). ]]
function WheelLogic.roll(unit: number): number
	local slices = LuckySpinConfig.Slices
	local safe = if unit == unit then math.clamp(unit, 0, 0.999999) else 0
	local target = safe * LuckySpinConfig.TotalWeight
	local cumulative = 0
	for index, slice in slices do
		cumulative += slice.weight
		if target < cumulative then
			return index
		end
	end
	return #slices
end

return table.freeze(WheelLogic)
