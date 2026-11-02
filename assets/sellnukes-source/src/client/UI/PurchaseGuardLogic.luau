--!strict
--[[
	PurchaseGuardLogic — the PURE rules of the owner R122 purchase-focus hygiene (spec §2.4), so
	tests/purchase-focus.luau proves them without Roblox:

		allows(openedAt, pressAt, now, cfg?)   may a Robux BUY activation go through? Only when the
		                                       press BEGAN after its surface opened (+ PressAfterOpen)
		                                       and the surface has been up ArmSeconds. So the press
		                                       that opened a screen / card (a tap, a click, a gamepad A
		                                       that the newly selected button would see on release) can
		                                       never buy something inside it.
		pickDefault(candidates, isBuy, usable) the first usable candidate that is NOT a BUY button
		                                       (a screen never opens with the gamepad cursor on one).
		latestPress(times)                     the newest press time among the tracked inputs.

	Connects to: Shared/Config/PurchaseFocusConfig (Guard), UI/PurchaseGuard (runtime: the clock,
	the input listener, the surface open times), tests/purchase-focus.luau.

	Example:
		PurchaseGuardLogic.allows(10, 10.5, 10.6) --> true
		PurchaseGuardLogic.allows(10, 9.9, 11)    --> false, "openingPress"
		PurchaseGuardLogic.pickDefault({ buyButton, tab }, isBuy, usable) --> tab
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PurchaseFocusConfig = require(ReplicatedStorage.Shared.Config.PurchaseFocusConfig)

export type GuardConfig = { PressAfterOpen: number, ArmSeconds: number }
export type Refusal = "arming" | "openingPress" | "noPress"

local PurchaseGuardLogic = {}

-- A finite number, else nil (NaN / inf / non-numbers are "unknown").
local function finite(value: unknown): number?
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

--[[
	Whether a BUY activation on a surface may open the Robux prompt.
	@param openedAt when the surface (screen / card) opened (os.clock seconds); nil = the surface
	                was never tracked (always allowed: the guard only protects what registered)
	@param pressAt  when the newest activating press (tap, click, gamepad A, Enter) BEGAN; nil = no
	                press seen since the guard started (only the arm time then applies)
	@param now      the clock now
	@param cfg      optional override of PurchaseFocusConfig.Guard (tests)
	@return (ok, refusal?) — "arming" (opened < ArmSeconds ago) | "openingPress" (the press began
	        before / together with the open)
	Example: PurchaseGuardLogic.allows(10, 10.2, 10.4) --> true
]]
function PurchaseGuardLogic.allows(
	openedAt: number?,
	pressAt: number?,
	now: number,
	cfg: GuardConfig?
): (boolean, Refusal?)
	local guard: GuardConfig = cfg or (PurchaseFocusConfig.Guard :: any)
	local opened = finite(openedAt)
	if opened == nil then
		return true, nil
	end
	local clock = finite(now)
	if clock == nil or clock - opened < guard.ArmSeconds then
		return false, "arming"
	end
	local press = finite(pressAt)
	if press ~= nil and press < opened + guard.PressAfterOpen then
		return false, "openingPress"
	end
	return true, nil
end

--[[
	The newest press time among `times` (nil when empty / all unknown).
	Example: PurchaseGuardLogic.latestPress({ Touch = 3, ButtonA = 5 }) --> 5
]]
function PurchaseGuardLogic.latestPress(times: { [any]: number }): number?
	local best: number? = nil
	for _, value in times do
		local at = finite(value)
		if at ~= nil and (best == nil or at > (best :: number)) then
			best = at
		end
	end
	return best
end

--[[
	The first candidate that is usable (shown / selectable) and NOT a BUY button, in order. A
	screen's default gamepad selection goes through this, so it never starts on a Robux button.
	@param candidates ordered preferences (nil holes allowed: missing optional controls)
	@param isBuy      true for a Robux BUY button (PurchaseGuard.isBuy)
	@param usable     true when the candidate can take the selection right now
	@return the pick, or nil when every candidate is a BUY button / unusable
	Example: PurchaseGuardLogic.pickDefault({ starterBuy, heading }, isBuy, usable) --> heading
]]
function PurchaseGuardLogic.pickDefault<T>(candidates: { [number]: T? }, isBuy: (T) -> boolean, usable: (T) -> boolean): T?
	local count = 0
	for index in candidates do
		if type(index) == "number" and index > count then
			count = index
		end
	end
	for index = 1, count do
		local candidate = candidates[index]
		if candidate ~= nil and usable(candidate) and not isBuy(candidate) then
			return candidate
		end
	end
	return nil
end

return table.freeze(PurchaseGuardLogic)
