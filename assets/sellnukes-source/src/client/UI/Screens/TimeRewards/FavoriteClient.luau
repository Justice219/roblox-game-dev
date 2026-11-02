--!strict
--[[
	FavoriteClient — the client half of the owner R89 one-time experience FAVORITE prompt (spec §3;
	the server gate is Server/Retention/FavoritePrompt, the rules Shared/Config/GiftsConfig).

	Flow:
		1. The server announces a happy moment (FavoriteMoment { moment }: the 10-minute gift was
		   claimed, or a rebirth) — only while the prompt was never answered and asks are left.
		2. This module waits for a CALM moment, polling every ClientCheckSeconds for at most
		   ClientMaxWaitSeconds (one thread, only while a moment is pending):
		     - Platform/JoinFlow.isQuiet(): loading done, no plot reveal / focus-mode cinematic, no
		       modal menu (e.g. the Time Rewards window the gift was claimed in), no Roblox purchase
		       prompt, nothing in the join queue, not in the guided tutorial steps;
		     - the tutorial is finished (profile tycoon.tutorialStep 0 or >= TutorialDoneStep);
		     - the answer was not recorded meanwhile (profile.gifts.favorite ~= Answered).
		   No calm moment in time → the moment is dropped (nothing counted, nothing shown).
		3. AvatarEditorService:PromptSetFavorite(game.PlaceId, Enum.AvatarItemType.Asset, true)
		   (a place id IS the experience's asset id), then FavoriteReport("shown"); the dialog's
		   PromptSetFavoriteCompleted result name ("Success" / "PermissionDenied" / "Failed") is
		   reported back once. At most ONE prompt per session.

	Never rewarded (Roblox rules): no reward, toast or unlock follows any answer. The reports only
	let the server stop future prompts.

	Connects to: Shared/Config/{GiftsConfig, QuestConfig (TutorialDoneStep)}, Shared/Net/Remotes
	(FavoriteMoment, FavoriteReport), Platform/JoinFlow, Client/ClientState. Started by
	Screens/TimeRewards (built at boot, lazy = false).

	Example:
		FavoriteClient.start() -- once, from the Time Rewards screen's build
]]

local AvatarEditorService = game:GetService("AvatarEditorService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.Parent.Parent.ClientState)
local GiftsConfig = require(ReplicatedStorage.Shared.Config.GiftsConfig)
local JoinFlow = require(script.Parent.Parent.Parent.Parent.Platform.JoinFlow)
local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)

local FavoriteClient = {}

local started = false
local promptedThisSession = false
-- os.clock() deadline of the pending moment (nil = nothing pending).
local pendingUntil: number? = nil
local polling = false

-- True while the player is still inside the tycoon tutorial (1 .. DoneStep - 1).
local function inTutorial(): boolean
	local profile = ClientState.profile
	local tycoon: any = if profile ~= nil then profile.tycoon else nil
	local step = if type(tycoon) == "table" then tycoon.tutorialStep else nil
	if type(step) ~= "number" or step ~= step then
		return true -- unknown yet: treat as busy (the moment waits)
	end
	return step >= 1 and step < QuestConfig.TutorialDoneStep
end

-- True once the server recorded an answer (never prompt again, even mid-wait).
local function answered(): boolean
	local profile = ClientState.profile
	local gifts: any = if profile ~= nil then profile.gifts else nil
	return type(gifts) == "table" and gifts.favorite == GiftsConfig.FavoriteState.Answered
end

-- Shows the native dialog once and reports what happened.
local function showPrompt()
	promptedThisSession = true
	pendingUntil = nil
	local reported = false
	local connection: RBXScriptConnection? = nil
	connection = AvatarEditorService.PromptSetFavoriteCompleted:Connect(function(result: Enum.AvatarPromptResult)
		if reported then
			return
		end
		reported = true
		local current = connection
		if current ~= nil then
			current:Disconnect()
		end
		local name = result.Name
		if table.find(GiftsConfig.Favorite.Reports, name :: any) ~= nil and name ~= "shown" then
			Remotes.event("FavoriteReport"):FireServer(name)
		end
	end)
	local ok, err = pcall(function()
		AvatarEditorService:PromptSetFavorite(game.PlaceId, Enum.AvatarItemType.Asset, true)
	end)
	if not ok then
		-- Could not open (e.g. an unsupported client): nothing was shown, nothing is reported.
		reported = true
		local current = connection
		if current ~= nil then
			current:Disconnect()
		end
		warn(`[FavoriteClient] favorite prompt unavailable: {err}`)
		return
	end
	Remotes.event("FavoriteReport"):FireServer("shown")
end

-- The single wait loop (runs only while a moment is pending).
local function ensurePolling()
	if polling then
		return
	end
	polling = true
	task.spawn(function()
		while pendingUntil ~= nil do
			local deadline = pendingUntil
			if deadline == nil or os.clock() > deadline or answered() or promptedThisSession then
				pendingUntil = nil
				break
			end
			if not inTutorial() and JoinFlow.isQuiet() then
				showPrompt()
				break
			end
			task.wait(GiftsConfig.Favorite.ClientCheckSeconds)
		end
		polling = false
	end)
end

--[[
	Handles one FavoriteMoment push (validated: a table with a known `moment`). Exposed for QA.
	@return true when the moment is now pending
]]
function FavoriteClient.onMoment(payload: unknown): boolean
	if promptedThisSession or answered() or type(payload) ~= "table" then
		return false
	end
	local moment = (payload :: any).moment
	if table.find(GiftsConfig.Favorite.Moments, moment) == nil then
		return false
	end
	pendingUntil = os.clock() + GiftsConfig.Favorite.ClientMaxWaitSeconds
	ensurePolling()
	return true
end

--[[ QA probe: { pending, prompted } (no side effects). ]]
function FavoriteClient.debugState(): { pending: boolean, prompted: boolean }
	return { pending = pendingUntil ~= nil, prompted = promptedThisSession }
end

--[[ Connects the FavoriteMoment listener (idempotent). ]]
function FavoriteClient.start()
	if started then
		return
	end
	started = true
	Remotes.event("FavoriteMoment").OnClientEvent:Connect(function(payload: unknown)
		FavoriteClient.onMoment(payload)
	end)
end

return FavoriteClient
