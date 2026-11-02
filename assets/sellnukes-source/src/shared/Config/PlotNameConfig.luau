--!strict
--[[
	PlotNameConfig — tunables of the owner-chosen PLOT NAME on a plot's entrance sign (owner R88:
	"allow players to name there plots by clicking on it and on controller being near the sign in
	the front").

	Purpose:
		One place for every number and word of the feature, read by the server (cap, rate limits,
		toasts), the client (prompt, click distance, highlight, window copy) and the Lune tests:
			MaxChars          the name's character cap (UTF-8 codepoints, after trimming)
			SignTag           CollectionService tag the server puts on every plot's owner-sign part;
			                  the owner's client hangs its click box + prompt on its OWN sign only
			MainSuffix        "<DisplayName>'s Nukes" — the Nuke Town default sign suffix (other
			                  worlds use their world name: "<DisplayName>'s Dino Valley")
			Rename            server rate limit (token bucket) + the throttle of its "slow down" toast
			Prompt            the walk-up ProximityPrompt (controller / keyboard / touch)
			Click             the ClickDetector on the sign (mouse hover cursor + tap)
			Highlight         the hover outline on the sign (mouse)
			Copy              every player-facing string (kid-friendly)

	Security: nothing here is trusted from the client. The server re-validates the text against
	MaxChars, rate limits with Rename, filters with TextService for broadcast and checks plot
	ownership (Server/Tycoon/PlotNames).

	Connects to: Shared/Tycoon/PlotNameLogic (rules), Server/Tycoon/PlotNames (remote RenamePlot),
	Server/World/PlotBuilder (sign tag, default suffix), Server/Economy/ProfileLogic (profile.plotName
	cap), Client/Tycoon/PlotSign (prompt + click), Client/UI/Screens/RenameStand (plot mode),
	tests/plot-name.luau.

	Example:
		PlotNameConfig.MaxChars           --> 24
		PlotNameConfig.Prompt.MaxDistance --> 12
]]

return table.freeze({
	-- Character cap of a plot name (codepoints after trimming; ProfileLogic caps stored names to it).
	MaxChars = 24,
	-- CollectionService tag on each plot's owner-sign part (every world's plots; server-set).
	SignTag = "SNPlotSign",
	-- Default sign suffix in Nuke Town ("<DisplayName>'s Nukes"); other worlds use the world name.
	MainSuffix = "Nukes",
	-- Server: renames per player — a burst of 3, then one more every 10 s (sets + resets share it).
	-- A refused rename answers with at most one "slow down" toast per ToastSeconds.
	Rename = table.freeze({
		Burst = 3,
		RefillPerSecond = 1 / 10,
		ToastSeconds = 4,
	}),
	-- Client: walk-up ProximityPrompt on the owner's own sign (controller X / keyboard E / touch tap).
	-- It sits at chest height under the sign (the sign itself hangs high on the entrance arch), so
	-- MaxDistance is measured from where the owner walks through the arch.
	Prompt = table.freeze({
		ActionText = "Name your plot",
		ActionTextRename = "Rename your plot",
		ObjectText = "Your sign",
		MaxDistance = 12,
		-- A short hold: the prompt sits in the owner's walkway, so a stray tap never opens it.
		HoldSeconds = 0.3,
		Height = 3.5, -- studs above the plot's ground level
		KeyboardKey = Enum.KeyCode.E,
		GamepadKey = Enum.KeyCode.ButtonX,
	}),
	-- Client: ClickDetector on an invisible box over the owner's own sign (mouse hover + click, tap).
	Click = table.freeze({
		MaxDistance = 70, -- the sign hangs ~18 studs up; clicks from the road in front still work
		Padding = 0.6, -- studs the click box grows past the sign on each axis (easier taps)
	}),
	-- Client: hover outline on the sign (one pooled Highlight; mouse only).
	Highlight = table.freeze({
		OutlineColor = Color3.fromRGB(255, 220, 70),
		FillColor = Color3.fromRGB(255, 230, 90),
		-- Clearly visible on the cream arch plate (QA 2026-10-31: 0.82 read too faint).
		FillTransparency = 0.6,
		OutlineTransparency = 0,
	}),
	-- Player-facing copy (kid-friendly; toasts come from the server, window text from the client).
	Copy = table.freeze({
		Title = "Name Your Plot",
		Heading = "Name your plot!",
		Hint = "Up to %d letters. Everyone sees it on your front sign.",
		HintEmpty = "Type 1 to %d letters first.",
		HintAlreadyDefault = "Your sign already shows its starting name.",
		ResetButton = "RESET",
		Saved = "Your plot has a new name!",
		Reset = "Your plot sign is back to its starting name!",
		Same = "That's already your plot's name!",
		FilterFailed = "Couldn't check that name right now - try again!",
		Censored = "That name isn't allowed - try a different one!",
		AdminReset = "Your plot sign was reset to its starting name.",
		NoPlot = "Wait for your plot first, then name it!",
		TooFast = "Whoa, not so fast! Try again in a few seconds.",
	}),
})
