--!nocheck
--[[
	currency_fly_client.luau — client-VM probe for UI/Hud/CurrencyFly (owner R46), run by
	tools/qa/currency_fly.py through eval_client_runtime during ONE solo playtest.

		COMMAND  "state"    CurrencyFly.state() as JSON (pool, live sprites, PreRender running,
		                    bursts per source)
		         "approach" stands the character in front of the first producer (p1_workbench)
		         "click"    clicks it like a player (ProducerBillboards.click -> ProducerClick)
		         "reward"   claims today's daily reward (ClaimDaily intent)
		         "storm"    keeps reward / gem / producer bursts flying for ~18 s (screenshots)
		         "diag"     top modal, cash, daily state, the producer's cycle fields
		         "modal_open" / "modal_close"  the Settings window (covers the world: no world flies)
	(Reduce Motion is covered by tests/currency-fly.luau: the profile setting re-applies on every push.)
	Presentation only: the only intents sent are the normal player ones (ProducerClick, ClaimDaily).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local COMMAND = "__COMMAND__"
local PRODUCER = "p1_workbench"

local client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local CurrencyFly = require(client.UI.Hud.CurrencyFly)
local ProducerBillboards = require(client.Tycoon.ProducerBillboards)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ClientState = require(client.ClientState)
local ScreenManager = require(client.UI.ScreenManager)

local function state(): string
	return HttpService:JSONEncode(CurrencyFly.state())
end

if COMMAND == "state" then
	return state()
elseif COMMAND == "approach" then
	local record = ProducerBillboards.byId(PRODUCER)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if record == nil or root == nil then
		return `missing record={record ~= nil} root={root ~= nil}`
	end
	local anchor = record.anchor
	local front = anchor.Position + anchor.CFrame.LookVector * 9 + Vector3.new(0, 3, 0)
	root.CFrame = CFrame.lookAt(front, Vector3.new(anchor.Position.X, front.Y, anchor.Position.Z))
	return `at {front} mine={record.mine} automated={record.automated}`
elseif COMMAND == "click" then
	local record = ProducerBillboards.byId(PRODUCER)
	if record == nil then
		return "no record"
	end
	return tostring(ProducerBillboards.click(record, true))
elseif COMMAND == "reward" then
	Remotes.event("ClaimDaily"):FireServer()
	return "claimed"
elseif COMMAND == "storm" then
	task.spawn(function()
		for index = 1, 60 do
			CurrencyFly.fromScreen("cash", 1e6, "reward")
			if index % 3 == 0 then
				CurrencyFly.fromScreen("gems", 100, "purchase")
			end
			local record = ProducerBillboards.byId(PRODUCER)
			if record ~= nil then
				CurrencyFly.fromWorld("cash", 500, record.popPoint.WorldPosition, "click")
			end
			task.wait(0.3)
		end
	end)
	return "storming"
elseif COMMAND == "diag" then
	local record = ProducerBillboards.byId(PRODUCER)
	local profile = ClientState.profile or {}
	return HttpService:JSONEncode({
		modal = ScreenManager.topModalName() or "",
		loadingDone = Players.LocalPlayer:GetAttribute("LoadingDone") == true,
		hud = ScreenManager.getGui("Hud") ~= nil and (ScreenManager.getGui("Hud") :: ScreenGui).Enabled,
		cash = profile.cash,
		daily = profile.daily,
		now = workspace:GetServerTimeNow(),
		cycleStart = record and record.cycleStart,
		localStart = record and record.localStart,
		cycleTime = record and record.cycleTime,
		lastClick = record and record.lastClick,
		cooldown = record and record.cooldown,
	})
elseif COMMAND == "modal_open" then
	ScreenManager.closeAllModals()
	ScreenManager.open("Settings")
	return tostring(ScreenManager.anyModalOpen())
elseif COMMAND == "modal_close" then
	ScreenManager.closeAllModals()
	return tostring(ScreenManager.anyModalOpen())
end
return "unknown command"
