--!strict
--[[
	FavoritePrompt — the server gate of the owner R89 one-time experience FAVORITE prompt (spec §3).
	The native dialog (AvatarEditorService:PromptSetFavorite) can only open on the client
	(UI/Screens/TimeRewards/FavoriteClient); this module decides WHEN it may and records the answer.

	Flow:
		1. A happy moment on the server: the player claims the 10-minute gift
		   (PlaytimeService → onGift(player, gift) for gift.favoriteMoment) or rebirths
		   (ProgressEvents "rebirth"). If profile.gifts allows it (GiftsLogic.mayAnnounce: not
		   answered, shown < MaxAsks) and nothing was announced yet this session, FavoriteMoment
		   { moment } goes to that client (retention "favorite:moment:<gift|rebirth>").
		2. The client waits for a calm moment (no menu / cinematic / tutorial), shows the dialog and
		   reports FavoriteReport("shown") — accepted only within ShownWindowSeconds of an announced
		   moment, once per session → favoriteAsks + 1, favorite = Shown ("favorite:shown").
		3. The dialog's result → FavoriteReport("Success" | "PermissionDenied" | "Failed"), accepted
		   only within AnswerWindowSeconds after an accepted "shown": Success / PermissionDenied =
		   ANSWERED, never prompted again; Failed keeps it unanswered for a later moment
		   ("favorite:<success|denied|failed>").

	Never rewarded (Roblox rules): nothing is granted, unlocked or changed by the answer except this
	gate. The reports are untrusted: typeof + allowlist + token bucket + session windows; a forged
	report can only stop the player's OWN future prompts.

	Admin (Studio only): FavoriteMomentTest re-announces for QA (ignores the session flag, still
	respects "answered" unless forced). Registered by PlaytimeService's admin block via `announce`.

	Connects to: Shared/Config/GiftsConfig, Retention/{GiftsLogic, RewardGrant (analytics)},
	Services/PlayerDataService, Progression/ProgressEvents, Shared/Net/Remotes (FavoriteMoment S→C,
	FavoriteReport C→S); lifecycle owned by Services/PlaytimeService.

	Example:
		FavoritePrompt.announce(player, "gift") --> true when the client was told
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GiftsConfig = require(ReplicatedStorage.Shared.Config.GiftsConfig)
local GiftsLogic = require(script.Parent.GiftsLogic)
local PlayerDataService = require(ServerScriptService.Server.Services.PlayerDataService)
local ProgressEvents = require(ServerScriptService.Server.Progression.ProgressEvents)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RewardGrant = require(script.Parent.RewardGrant)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)

local FavoritePrompt = {}

-- Analytics suffix per AvatarPromptResult name.
local RESULT_KEY: { [string]: string } = { Success = "success", PermissionDenied = "denied", Failed = "failed" }

-- Reports: a handful per moment is honest (shown + one result); anything more is dropped.
local limiter = RateLimiter.new(4, 0.2)
-- Per-session bookkeeping (os.clock times; nil = not yet).
local announcedAt: { [Player]: number } = {}
local shownAt: { [Player]: number } = {}

--[[
	Announces a happy moment to the player's client when the gate allows it (see the header).
	@param moment "gift" | "rebirth" (analytics + client copy)
	@param force  admin QA: ignore the once-per-session rule and the answered state
	@return true when FavoriteMoment was sent
]]
function FavoritePrompt.announce(player: Player, moment: GiftsConfig.FavoriteMoment, force: boolean?): boolean
	if player.Parent ~= Players or table.find(GiftsConfig.Favorite.Moments, moment) == nil then
		return false
	end
	-- Kill switch (GiftsConfig.FavoriteEnabled); the Studio admin test may still force one.
	if not GiftsConfig.FavoriteEnabled and force ~= true then
		return false
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false
	end
	if force ~= true and (announcedAt[player] ~= nil or not GiftsLogic.mayAnnounce(profile.gifts)) then
		return false
	end
	announcedAt[player] = os.clock()
	shownAt[player] = nil
	Remotes.fireClient("FavoriteMoment", player, { moment = moment })
	RewardGrant.track(player, `favorite:moment:{moment}`)
	return true
end

--[[
	PlaytimeService hook: a gift was claimed (the 10-minute gift is a happy moment). Deferred so
	the claim's own step stays short and non-yielding.
]]
function FavoritePrompt.onGift(player: Player, giftFavoriteMoment: boolean)
	if giftFavoriteMoment then
		task.defer(function()
			FavoritePrompt.announce(player, "gift")
		end)
	end
end

--[[
	FavoriteReport handler (C→S, untrusted): "shown" or an AvatarPromptResult name.
	@return true when the report changed profile.gifts
]]
function FavoritePrompt.onReport(player: Player, rawReport: unknown): boolean
	local report = Validate.oneOf(rawReport, GiftsConfig.Favorite.Reports)
	if report == nil then
		return false
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not PlayerDataService.canMutate(player) then
		return false
	end
	local now = os.clock()
	if report == "shown" then
		local at = announcedAt[player]
		if at == nil or shownAt[player] ~= nil or now - at > GiftsConfig.Favorite.ShownWindowSeconds then
			return false
		end
		if not GiftsLogic.markShown(profile.gifts) then
			return false
		end
		shownAt[player] = now
		PlayerDataService.markChanged(player, true, { "gifts" })
		RewardGrant.track(player, "favorite:shown")
		return true
	end
	local at = shownAt[player]
	if at == nil or now - at > GiftsConfig.Favorite.AnswerWindowSeconds then
		return false
	end
	local state = GiftsLogic.markAnswered(profile.gifts, report)
	if state == nil then
		return false
	end
	shownAt[player] = nil -- one answer per shown dialog
	PlayerDataService.markChanged(player, true, { "gifts" })
	local key = RESULT_KEY[report]
	if key ~= nil then
		RewardGrant.track(player, `favorite:{key}`)
	end
	return true
end

function FavoritePrompt.Init() end

function FavoritePrompt.Start()
	Remotes.onServerEvent("FavoriteReport", function(player: Player, rawReport: unknown)
		if limiter:Allow(player) then
			FavoritePrompt.onReport(player, rawReport)
		end
	end)
	-- A rebirth (any world) is a happy moment too (the gate keeps it to one prompt).
	ProgressEvents.Progress:Connect(function(player: Player, stat: string, _amount: number)
		if stat == "rebirth" then
			task.defer(function()
				FavoritePrompt.announce(player, "rebirth")
			end)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		limiter:Forget(player)
		announcedAt[player] = nil
		shownAt[player] = nil
	end)
end

return FavoritePrompt
