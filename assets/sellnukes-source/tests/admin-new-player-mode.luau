--!strict
--[[
	New Player Mode pure-rule regressions (spec §14 "play on a throw-away sandbox profile;
	purchases refused; analytics diverted"). Run:
		lune run tests/admin-new-player-mode

	Proves on the shipped Shared/Util/NewPlayerMode:
	  1. isOn: only exactly `true` counts.
	  2. adminExempt: admins are exempt from new-player rules only OUTSIDE the mode.
	  3. saveDecision: a sandbox is never written (whatever its status); real sessions write /
	     heartbeat / skip by status.
	  4. purchaseGate + receiptDecision: purchases refused and receipts deferred in the mode.
	  5. enterRefusal: every refusal reason in priority order, nil when allowed.
	  6. exitPlan: refuse / now.
	  7. isActive / isExemptAdmin read the server-set attributes (fake instances).
	  8. The attribute name equals AnalyticsConfig.NewPlayerModeAttribute (analytics diversion
	     keys off the same attribute) and the module is frozen.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local NewPlayerMode = loader.load("src/shared/Util/NewPlayerMode")
local AnalyticsConfig = loader.load("src/shared/Config/AnalyticsConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- 1. isOn
check(NewPlayerMode.isOn(true), "true is on")
for _, value in { false, "true", 1, 0, {} } :: { any } do
	check(not NewPlayerMode.isOn(value), `{tostring(value)} is off`)
end
check(not NewPlayerMode.isOn(nil), "nil is off")

-- 2. adminExempt
check(NewPlayerMode.adminExempt(true, nil), "admin exempt outside the mode")
check(not NewPlayerMode.adminExempt(true, true), "admin NOT exempt in the mode")
check(not NewPlayerMode.adminExempt(false, nil), "non-admin never exempt")
check(not NewPlayerMode.adminExempt("true", nil), "IsAdmin must be exactly true")

-- 3. saveDecision
for _, status in { "ok", "readOnly", "disabled", "lost", "weird" } do
	check(NewPlayerMode.saveDecision(true, status) == "skip", `sandbox {status} → skip`)
end
check(NewPlayerMode.saveDecision(false, "ok") == "write", "real ok → write")
check(NewPlayerMode.saveDecision(false, "readOnly") == "heartbeat", "real readOnly → heartbeat")
check(NewPlayerMode.saveDecision(false, "disabled") == "skip", "real disabled → skip")
check(NewPlayerMode.saveDecision(false, "lost") == "skip", "real lost → skip")

-- 4. purchaseGate / receiptDecision
local allowed, refusal = NewPlayerMode.purchaseGate(true)
check(not allowed and refusal == NewPlayerMode.Copy.PurchaseBlocked, "purchases refused in the mode")
local allowedOutside, none = NewPlayerMode.purchaseGate(false)
check(allowedOutside and none == nil, "purchases allowed outside")
check(NewPlayerMode.receiptDecision(true) == "defer", "sandbox receipts deferred")
check(NewPlayerMode.receiptDecision(false) == "process", "real receipts processed")

-- 5. enterRefusal (priority order)
local base = { loaded = true, active = false, busy = false, shuttingDown = false, released = false }
local reason, message = NewPlayerMode.enterRefusal(base)
check(reason == nil and message == nil, "allowed when everything is fine")
local function refusalFor(patch: { [string]: boolean }): string?
	local facts = table.clone(base)
	for key, value in patch do
		(facts :: any)[key] = value
	end
	local r, m = NewPlayerMode.enterRefusal(facts :: any)
	check(r == nil or type(m) == "string", "every refusal has a message")
	return r
end
check(refusalFor({ loaded = false }) == "notLoaded", "notLoaded")
check(refusalFor({ released = true }) == "released", "released")
check(refusalFor({ shuttingDown = true }) == "closing", "closing")
check(refusalFor({ active = true }) == "already", "already")
check(refusalFor({ busy = true }) == "busy", "busy")
check(refusalFor({ loaded = false, active = true, busy = true }) == "notLoaded", "notLoaded wins")
check(refusalFor({ released = true, shuttingDown = true }) == "released", "released before closing")
check(refusalFor({ shuttingDown = true, active = true }) == "closing", "closing before already")
check(refusalFor({ active = true, busy = true }) == "already", "already before busy")

-- 6. exitPlan
check(NewPlayerMode.exitPlan({ active = true, busy = false, shuttingDown = false }) == "now", "exit now")
check(NewPlayerMode.exitPlan({ active = false, busy = false, shuttingDown = false }) == "refuse", "not active")
check(NewPlayerMode.exitPlan({ active = true, busy = true, shuttingDown = false }) == "refuse", "busy")
check(NewPlayerMode.exitPlan({ active = true, busy = false, shuttingDown = true }) == "refuse", "closing")

-- 7. Attribute helpers on fake instances.
local function fakePlayer(attributes: { [string]: any }): any
	return {
		GetAttribute = function(_self: any, name: string): any
			return attributes[name]
		end,
	}
end
check(NewPlayerMode.isActive(fakePlayer({ NewPlayerMode = true })), "isActive true")
check(not NewPlayerMode.isActive(fakePlayer({ NewPlayerMode = "true" })), "isActive needs exactly true")
check(not NewPlayerMode.isActive(nil), "nil player")
check(NewPlayerMode.isExemptAdmin(fakePlayer({ IsAdmin = true })), "exempt admin")
check(not NewPlayerMode.isExemptAdmin(fakePlayer({ IsAdmin = true, NewPlayerMode = true })), "admin in the mode")

-- 8. Integration constants.
check(NewPlayerMode.Attribute == AnalyticsConfig.NewPlayerModeAttribute, "attribute shared with analytics")
check(table.isfrozen(NewPlayerMode) and table.isfrozen(NewPlayerMode.Copy), "module frozen")
for key, text in NewPlayerMode.Copy do
	check(type(text) == "string" and #text > 0 and #text <= 200, `copy {key} sane`)
end

print(`[admin-new-player-mode] {checks} checks passed`)
