--!strict
--[[
	HudFocusConfig — timings for hiding / showing HUD screens (focus mode) with a fade.

	Purpose:
		Some moments want a clean screen: the egg-hatch / crate reveal, the attack target picker
		(◀ name ▶ CANCEL), the tutorial's first click. Those systems call
		ScreenManager.setFocusReason(reason, true, hiddenScreens?) and the listed NON-modal screens
		fade out through Widgets/GuiFade, then fade back in when every reason is cleared
		(setFocusReason(reason, false)). Numbers only; presentation never affects game state.

	Connects to: UI/Widgets/GuiFade, UI/ScreenManager (setFocusReason).

	Example: HudFocusConfig.FadeOutSeconds --> 0.18
]]
return table.freeze({
	-- Seconds a screen takes to fade out / in when focus mode hides / restores it.
	FadeOutSeconds = 0.18,
	FadeInSeconds = 0.24,
	-- A screen with more fadeable elements than this hides / shows instantly (bounded tween count).
	MaxFadeObjects = 400,
	-- Owner R16: the HUD stays hidden under the join loading screen until the player attribute
	-- LoadingDone; if it never arrives the gate (UI/Widgets/LoadingGate) opens after this.
	-- R122: a safety net only — kept ABOVE the loader's Readiness.AUTO_CONTINUE (30 s, which always
	-- hands off) + 5 s slack, so the gate never opens under a live loading screen.
	LoadingTimeoutSeconds = 35,
	-- Screens hidden while the loading screen is up.
	LoadingHidden = table.freeze({ "Hud", "Toasts" }),
	-- Screens hidden by the default focus reason when the caller passes no list.
	DefaultHidden = table.freeze({ "Hud" }),
	-- Owner R127 ("in the spin UI hide the money counter UI on the top since it clips"): while one of
	-- these screens is open the HUD currency stack (gems / cash / rate / boost badge) fades out, and
	-- fades back when the last one closes (Hud.applyCurrencyLayer).
	CurrencyHiddenScreens = table.freeze({ "LuckyWheel" }),
})
