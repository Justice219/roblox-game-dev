--!strict
--[[
	FlavorTip — when to show the one-time "what are Lucky Nukes?" tip card (owner R112: "so what is
	the point of a batch?? it's real confusing"). The card itself is UI/Screens/FlavorTip.

	Rule: the FIRST Lucky Nuke (flavoured batch) a player ever gets opens the card once, as soon as
	nothing important is on screen — no tutorial step (Tycoon/Tutorial), no window (modal), no
	cinematic (ScreenManager focus mode / the plot reveal / the Lucky Nuke reveal). A blocked moment
	is simply retried on the next Lucky Nuke (they come every ~20 batches), so there is no timer.
	Shown = profile.flavors.tip (server-saved) is false; dismissing the card (OK / X / B) sends the
	FlavorTipSeen intent, which sets it. A local flag stops a second card before the push lands.
	Nothing shows while Surprise Batches are switched off (FlavorConfig.isEnabled).

	Called by Fx/FlavorPops.show on every own Lucky Nuke (cheap: a few table reads after the first).

	Connects to: Client/ClientState, Tycoon/{Tutorial, PlotReveal}, UI/ScreenManager, Shared/Net/
	Remotes (FlavorTipSeen), Shared/Config/FlavorConfig, UI/Screens/FlavorTip (calls markSeen).

	Example: FlavorTip.maybeShow() -- after a FlavorPop
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.ClientState)
local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local PlotReveal = require(script.Parent.PlotReveal)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local Tutorial = require(script.Parent.Tutorial)

local FlavorTip = {}

local REVEAL_SCREEN = "FlavorReveal"

local shownThisSession = false
local sentSeen = false

-- True when the server says the card was already dismissed.
local function alreadySeen(): boolean
	local profile: any = ClientState.profile
	local book = if type(profile) == "table" then profile.flavors else nil
	return type(book) == "table" and book.tip == true
end

-- True when nothing important is on screen.
local function calm(): boolean
	return Tutorial.step() == 0
		and not ScreenManager.anyModalOpen()
		and not ScreenManager.isFocusMode()
		and not PlotReveal.isPlaying()
		and not ScreenManager.isOpen(REVEAL_SCREEN)
end

--[[
	Opens the tip card if this player has never dismissed it and the moment is calm.
	@return boolean — true when the card opened now
]]
function FlavorTip.maybeShow(): boolean
	if shownThisSession or not FlavorConfig.isEnabled() or alreadySeen() then
		return false
	end
	if type(ClientState.profile) ~= "table" or not ScreenManager.isRegistered(FlavorConfig.TipScreen) then
		return false
	end
	if not calm() then
		return false -- retried on the next Lucky Nuke
	end
	shownThisSession = true
	ScreenManager.open(FlavorConfig.TipScreen, { source = "auto" })
	return true
end

--[[ The card was dismissed (OK / X / B): saves the flag on the server once. ]]
function FlavorTip.markSeen()
	shownThisSession = true
	if sentSeen or alreadySeen() then
		return
	end
	sentSeen = true
	task.spawn(function()
		Remotes.event("FlavorTipSeen"):FireServer()
	end)
end

--[[ QA probe: { shown, sent, seen } for this session. ]]
function FlavorTip.debugState(): { shown: boolean, sent: boolean, seen: boolean }
	return { shown = shownThisSession, sent = sentSeen, seen = alreadySeen() }
end

return FlavorTip
