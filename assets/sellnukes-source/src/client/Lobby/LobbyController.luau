--!strict
--[[
	LobbyController — the Nuke Town lobby's client life (owner R99 / R100 / R101, L-lobby):

		Client/Lobby/LobbyFixtures  the Lucky Wheel stage works (ProximityPrompt "Spin!", the LobbyUse
		                            platform action, walk onto the platform → the wheel opens; the
		                            physical wheel spins on your own results), the group chest and
		                            the codes board open their screens, every fixture board carries
		                            its caption (crate stall "SUPPLY CRATES" now on its own sign above
		                            the awning instead of a billboard the awning cut off)
		Client/Lobby/LobbyNpcs      8-12 R15 visitors stroll, look, sit, wave and chat

	ONE Heartbeat connection drives both (owner perf rule: one RunService connection per system).

	Boot: controller contract Init() / Start(), listed after UIController + Worlds/WorldClient (it
	opens screens and reads the current world) in src/client/init.client.luau as
	"Lobby/LobbyController".

	Connects to: Client/Lobby/{LobbyFixtures, LobbyNpcs}.

	Example: require(Client.Lobby.LobbyController).Start()
]]

local RunService = game:GetService("RunService")

local LobbyFixtures = require(script.Parent.LobbyFixtures)
local LobbyNpcs = require(script.Parent.LobbyNpcs)

local LobbyController = {}

local connection: RBXScriptConnection? = nil

--[[ Nothing to wire before every controller exists. ]]
function LobbyController.Init() end

--[[ Builds the fixture prompts / visitor folder and starts the one shared Heartbeat (idempotent). ]]
function LobbyController.Start()
	if connection ~= nil then
		return
	end
	LobbyFixtures.start()
	LobbyNpcs.start()
	connection = RunService.Heartbeat:Connect(function(dt: number)
		LobbyFixtures.step(dt)
		LobbyNpcs.step(dt)
	end)
end

return LobbyController
