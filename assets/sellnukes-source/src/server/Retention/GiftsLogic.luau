--!strict
--[[
	GiftsLogic — pure server rules (no services, never yields) for the owner R89 Pocket Rocket and
	the one-time favorite prompt. State = profile.gifts (Shared/Config/GiftsConfig.State).

	Pocket Rocket:
		promptRefusal(state, today)  "already today" text, or nil (MonetizationService prompt gate)
		markRocket(state, today)     records the grant day (receipt handler; always succeeds for a
		                             valid day, so a late / retried receipt is still granted)

	Favorite prompt (the server is the gate; the client only shows the native dialog):
		mayAnnounce(state)           not answered + shown fewer than MaxAsks times
		markShown(state)             the client reported the dialog SHOWN (asks + 1, state Shown);
		                             false when that would exceed MaxAsks or it was answered
		markAnswered(state, result)  Success / PermissionDenied → Answered (final); Failed keeps
		                             it unanswered; @return the new FavoriteState or nil (refused)

	Connects to: Shared/Config/GiftsConfig, Server/Retention/{PocketRocket, FavoritePrompt},
	tests/gift-ladder.luau.

	Example:
		if GiftsLogic.promptRefusal(profile.gifts, today) == nil then -- prompt allowed
		GiftsLogic.markRocket(profile.gifts, today)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GiftsConfig = require(ReplicatedStorage.Shared.Config.GiftsConfig)

local GiftsLogic = {}

-- Prompt refusal text once today's rocket was granted.
GiftsLogic.RocketUsedText = "Your Pocket Rocket already launched today - come back tomorrow!"

-- True for a whole, finite, non-negative day number.
local function validDay(day: unknown): boolean
	return type(day) == "number" and day == day and day % 1 == 0 and day >= 0 and day < math.huge
end

--[[
	Why the Pocket Rocket must not be prompted right now (nil = OK).
	Example: GiftsLogic.promptRefusal({ rocketDay = 9, favorite = 0, favoriteAsks = 0 }, 9) --> "...today..."
]]
function GiftsLogic.promptRefusal(state: GiftsConfig.State, today: number): string?
	if not validDay(today) then
		return "This offer isn't available right now."
	end
	if state.rocketDay == today then
		return GiftsLogic.RocketUsedText
	end
	return nil
end

--[[
	Records today's Pocket Rocket. A clock behind the stored day never moves it backwards (the
	grant itself still happens: the player paid). @return true when the day was written
]]
function GiftsLogic.markRocket(state: GiftsConfig.State, today: number): boolean
	if not validDay(today) or today < state.rocketDay then
		return false
	end
	state.rocketDay = today
	return true
end

--[[ True when a favorite moment may be announced (see GiftsConfig.mayAskFavorite). ]]
function GiftsLogic.mayAnnounce(state: GiftsConfig.State): boolean
	return GiftsConfig.mayAskFavorite(state)
end

--[[
	The client showed the native favorite dialog. @return true when counted (false: answered
	already or MaxAsks reached — the caller ignores the report)
]]
function GiftsLogic.markShown(state: GiftsConfig.State): boolean
	if not GiftsConfig.mayAskFavorite(state) then
		return false
	end
	state.favoriteAsks += 1
	state.favorite = GiftsConfig.FavoriteState.Shown
	return true
end

--[[
	The dialog's result arrived ("Success" | "PermissionDenied" | "Failed"). Only a SHOWN prompt
	can be answered. @return the new FavoriteState, or nil when refused (unknown result / never
	shown / already answered)
	Example: GiftsLogic.markAnswered(state, "PermissionDenied") --> 2 (never asked again)
]]
function GiftsLogic.markAnswered(state: GiftsConfig.State, result: string): number?
	if state.favorite ~= GiftsConfig.FavoriteState.Shown then
		return nil
	end
	if GiftsConfig.Favorite.Answered[result] == true then
		state.favorite = GiftsConfig.FavoriteState.Answered
		return state.favorite
	end
	if result == "Failed" then
		return state.favorite -- an error is not an answer: a later happy moment may ask again
	end
	return nil
end

return table.freeze(GiftsLogic)
