--!strict
--[[
	NewPlayerMode — the ONE predicate + the pure rules of the admin "PLAY AS NEW PLAYER" mode
	(spec §14 "New Player Mode: play on a throw-away sandbox profile; purchases refused; analytics
	diverted"; owner R6). Ported from RoBeasts' Shared/Util/NewPlayerMode (WS-H), trimmed to a
	tycoon (no matches, no Practice Island).

	What the mode is:
		An admin presses PLAY AS NEW PLAYER in the admin panel (AdminService command
		"NewPlayerMode", authorised like every other command). PlayerDataService makes the admin's
		real profile durable, PARKS it untouched (it keeps its session lock), and swaps in a
		brand-new ProfileLogic.defaultProfile() held by a SANDBOX ProfileStore session. The plot is
		rebuilt from the empty profile (ProfileLoaded fires again), so the admin sees exactly what a
		first-time player sees: area 1, $0, the tutorial, the first pads. Nothing of the sandbox is
		ever saved; EXIT NEW PLAYER MODE (admin panel, or the HUD badge) swaps the real profile back
		in place, and leaving the game simply ends the mode (the real profile was never overwritten).

	Why one module:
		Every "is this player new / exempt as an admin" check, the save decision, the purchase gate
		and the receipt decision consult THIS module, so the behaviour is defined (and Lune-tested:
		tests/admin-new-player-mode.luau) in one place instead of being scattered as special cases.

	The predicate (server-authoritative):
		The server sets the player attribute `NewPlayerMode` (= true) while the mode is on and
		clears it (nil) on exit. Player attributes written by the server replicate to clients; a
		client can only change its OWN local copy, which never reaches the server, so server reads
		of the attribute are trustworthy (same model as the `IsAdmin` attribute). Clients read it
		for display only (the HUD badge, the admin panel). The attribute name equals
		AnalyticsConfig.NewPlayerModeAttribute: analytics (B13 Runtime.guard) diverts every event
		of a player in the mode to core "npm:<recorder>", so no fake first-timer ever reaches the
		new-player cohorts, retention, revenue or the FTUE funnel.

	Pure rules (no Roblox APIs, no requires; Lune runs them directly):
		isOn(value)                       attribute value → bool (only exactly `true` counts)
		adminExempt(isAdmin, mode)        an admin is exempt from new-player rules ONLY outside the mode
		saveDecision(sandbox, status)     "write" | "heartbeat" | "skip" (ProfileStore.saveAsync)
		purchaseGate(active)              (allowed, refusal toast)
		receiptDecision(sandbox)          "process" | "defer" (ProcessReceipt → NotProcessedYet)
		enterRefusal(facts)               (reason?, message?) — nil reason = may enter
		exitPlan(facts)                   "refuse" | "now"

	Attribute helpers (read player attributes; safe on server and client):
		isActive(player)                  the predicate itself
		isExemptAdmin(player)             IsAdmin == true AND not in the mode

	Connects to: Server/Services/AdminService (commands NewPlayerMode / ExitNewPlayerMode),
	PlayerDataService + ProfileStore + MonetizationService (B1: the sandbox session, the swap, the
	purchase gate and the receipt deferral), Server/Analytics/Runtime (diversion by attribute),
	Client/UI/Screens/Admin (panel tab + HUD badge).

	Example:
		if NewPlayerMode.isExemptAdmin(player) then return end -- skip the tutorial for admins
		local allowed, toast = NewPlayerMode.purchaseGate(NewPlayerMode.isActive(player))
]]

local NewPlayerMode = {}

-- Player attribute (server-set, replicated, display-only on the client): true while the mode is on.
-- MUST equal AnalyticsConfig.NewPlayerModeAttribute (tests/admin-new-player-mode.luau checks it).
NewPlayerMode.Attribute = "NewPlayerMode"

-- Player-facing copy (toasts, HUD badge, admin panel). Kept here so server and client agree.
NewPlayerMode.Copy = table.freeze({
	Badge = "NEW PLAYER MODE",
	BadgeDetail = "nothing is saved",
	BadgeExit = "EXIT",
	BadgeConfirm = "TAP AGAIN",
	Entering = "Saving your real profile, then starting New Player Mode...",
	Entered = "NEW PLAYER MODE: you are a brand-new player now. Nothing is saved; your real profile is safe.",
	Exited = "New Player Mode ended: your real profile is back.",
	PurchaseBlocked = "Robux purchases are off in New Player Mode (nothing here is saved). Exit it first.",
	NotAvailable = "New Player Mode needs PlayerDataService support (B1 seam) - not available yet.",
})

-- Why entering can be refused (codes are stable: tests and the audit log read them).
export type EnterRefusal = "notLoaded" | "released" | "closing" | "already" | "busy"

-- What the server knows when an admin asks to enter.
export type EnterFacts = {
	loaded: boolean, -- the player's profile session exists
	active: boolean, -- already in the mode
	busy: boolean, -- an enter / exit for this player is already in progress
	shuttingDown: boolean, -- BindToClose started
	released: boolean, -- the real session was already released (leaving)
}

-- How an exit request is carried out.
export type ExitPlan = "refuse" | "now"

export type ExitFacts = {
	active: boolean, -- in the mode
	busy: boolean, -- an enter / exit is already in progress
	shuttingDown: boolean, -- BindToClose started (the release path ends the mode anyway)
}

export type SaveDecision = "write" | "heartbeat" | "skip"

--[[
	The attribute value → is the mode on? Only exactly `true` counts (nil / false / anything a
	stale or foreign writer left is "off").
	Example: NewPlayerMode.isOn(true) --> true; NewPlayerMode.isOn("true") --> false
]]
function NewPlayerMode.isOn(value: unknown): boolean
	return value == true
end

--[[
	Is an admin exempt from the new-player rules (forced tutorial, first-time objectives)? Admins
	are exempt in normal play; in New Player Mode they are treated exactly like a brand-new
	player, so the exemption is OFF.
	@param isAdmin the `IsAdmin` attribute value
	@param mode the `NewPlayerMode` attribute value
	Example: adminExempt(true, nil) --> true; adminExempt(true, true) --> false
]]
function NewPlayerMode.adminExempt(isAdmin: unknown, mode: unknown): boolean
	return isAdmin == true and not NewPlayerMode.isOn(mode)
end

--[[
	The ProfileStore save decision for one session (ProfileStore.saveAsync):
		"write"     a healthy, real session: write the profile + refresh the lock
		"heartbeat" a newer-schema ("readOnly") real session: keep the lock alive, never write data
		"skip"      a SANDBOX (New Player Mode) session, an in-memory ("disabled") session or a
		            session that lost its lock: never touch the DataStore at all
	A sandbox is "skip" whatever its status says: it never took the lock and its profile is a
	throwaway, so no path (autosave, leave, shutdown, receipts) can write it.
	Example: saveDecision(true, "ok") --> "skip"; saveDecision(false, "ok") --> "write"
]]
function NewPlayerMode.saveDecision(sandbox: boolean, status: string): SaveDecision
	if sandbox then
		return "skip"
	end
	if status == "ok" then
		return "write"
	end
	if status == "readOnly" then
		return "heartbeat"
	end
	return "skip"
end

--[[
	Robux purchase gate (every server-side MarketplaceService prompt path asks it first): the
	sandbox profile is never saved, so anything bought there would be lost — refuse with a clear
	toast instead of prompting.
	@return (allowed, refusal toast when refused)
	Example: purchaseGate(true) --> false, "Robux purchases are off in New Player Mode ..."
]]
function NewPlayerMode.purchaseGate(active: boolean): (boolean, string?)
	if active then
		return false, NewPlayerMode.Copy.PurchaseBlocked
	end
	return true, nil
end

--[[
	ProcessReceipt for a buyer whose loaded session is a sandbox: "defer" (NotProcessedYet), so
	Roblox re-delivers the receipt later and it is granted into the REAL profile once it is back
	(after EXIT, or on the next join at the latest). Never granted into the sandbox.
	Example: receiptDecision(true) --> "defer"
]]
function NewPlayerMode.receiptDecision(sandbox: boolean): "process" | "defer"
	return if sandbox then "defer" else "process"
end

--[[
	May the admin enter the mode now? Checked in this order (first match wins):
		notLoaded   no profile session yet
		released    the session is being released (leaving)
		closing     the server is shutting down
		already     the mode is already on
		busy        an enter / exit is already running for this player
	@return (nil, nil) when allowed, else (reason, toast)
	Example: enterRefusal({ loaded = true, active = false, busy = false, shuttingDown = false,
		released = false }) --> nil, nil
]]
function NewPlayerMode.enterRefusal(facts: EnterFacts): (EnterRefusal?, string?)
	if not facts.loaded then
		return "notLoaded", "Your profile has not loaded yet."
	end
	if facts.released then
		return "released", "Your profile is being saved (leaving)."
	end
	if facts.shuttingDown then
		return "closing", "The server is shutting down."
	end
	if facts.active then
		return "already", "New Player Mode is already on."
	end
	if facts.busy then
		return "busy", "New Player Mode is already switching - one moment."
	end
	return nil, nil
end

--[[
	How to carry out an EXIT request:
		"refuse"  not in the mode, already switching, or the server is closing (its release path
		          ends the mode by itself)
		"now"     swap the real profile back in place right away
	Example: exitPlan({ active = true, busy = false, shuttingDown = false }) --> "now"
]]
function NewPlayerMode.exitPlan(facts: ExitFacts): ExitPlan
	if not facts.active or facts.busy or facts.shuttingDown then
		return "refuse"
	end
	return "now"
end

--[[
	THE predicate: is this player in New Player Mode? Reads the server-set attribute (see the
	header for why that is trustworthy on the server). nil / non-player → false.
	Example: if NewPlayerMode.isActive(player) then ... end
]]
function NewPlayerMode.isActive(player: Instance?): boolean
	if player == nil then
		return false
	end
	return NewPlayerMode.isOn(player:GetAttribute(NewPlayerMode.Attribute))
end

--[[
	Is this player an admin who is exempt from new-player rules right now? (IsAdmin attribute set
	by AdminService, and NOT in New Player Mode.) Use instead of a plain `IsAdmin == true` check
	wherever admins skip first-time content.
	Example: if NewPlayerMode.isExemptAdmin(player) then skipTutorial() end
]]
function NewPlayerMode.isExemptAdmin(player: Instance): boolean
	return NewPlayerMode.adminExempt(player:GetAttribute("IsAdmin"), player:GetAttribute(NewPlayerMode.Attribute))
end

return table.freeze(NewPlayerMode)
