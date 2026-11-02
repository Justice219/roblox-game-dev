--!strict
--[[
	PurchasePromptConfig — limits for opening Roblox purchase prompts (presentation only: these
	never price or grant anything; receipts are handled by MonetizationService.ProcessReceipt).

	Purpose:
		A client can ask the server to open a purchase prompt (PromptProduct / PromptPass). The
		server rate-limits those requests per player and keeps at most ONE native prompt open per
		player: a second request while a prompt is still open is ignored, so a mashed button can
		never stack prompts or spam MarketplaceService. The hold is released when Roblox reports
		the prompt finished (PromptProductPurchaseFinished / PromptGamePassPurchaseFinished) or,
		as a safety net, after PendingSeconds (a finish event can be lost if the client
		disconnects mid-prompt).

	Connects to: Server/Services/MonetizationService (prompt limiter + open-prompt hold).

	Example:
		local limiter = RateLimiter.new(PurchasePromptConfig.RequestBurst, PurchasePromptConfig.RequestRefill)
]]

return table.freeze({
	-- Token bucket per player for PromptProduct + PromptPass requests (shared bucket).
	RequestBurst = 3,
	RequestRefill = 0.5, -- tokens per second (one request every 2 s sustained)
	-- Seconds an open prompt blocks a new one before the hold expires on its own.
	PendingSeconds = 20,
	-- Allowed `source` strings for analytics attribution (anything else becomes "other").
	Sources = table.freeze({
		"shop",
		"offer",
		"hud",
		"welcomeBack",
		"wheel",
		"pad",
		"attack",
		"event",
		"rebirth",
		"pets",
		"teleport",
		"lucky", -- owner R69: a paid Lucky Button on the player's plot (Server/Services/LuckyButtonService)
		"pass", -- owner R78: the Nuke Pass screen's premium CTA / locked premium cells (UI/Screens/NukePass)
		"other",
	}),
})
