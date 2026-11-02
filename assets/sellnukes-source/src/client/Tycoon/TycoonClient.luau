--!strict
--[[
	TycoonClient — boots the tycoon client UI (B6): the world registry, producer + pad billboards,
	keyboard / gamepad interaction, income pops, the YOU marker, the HUD income source, the
	tutorial and the stand-sign rename prompt.

	Boot: Controllers/UIController.Start calls TycoonClient.start() after the HUD and screens are
	registered (the tutorial and stand sign open screens; Income installs Hud.setIncomeSource).
	The build-in fly-in (Tycoon/BuildIn) and world FX (Tycoon/Fx) are B4's and boot themselves.
	Each piece starts under pcall so one failing module never takes the others down.

	Connects to: Tycoon/{TycoonWorld, ProducerBillboards, PadBillboards, Interaction, GemUpgrade
	(owner R86), IncomePops, YouMarker, Income, Tutorial, StandSign, PlotReveal}; screens Teleport / RenameStand / Rebirth /
	TycoonTutorial (UI/Screens, discovered by UIController); docs/tycoon-client.md.

	Example: TycoonClient.start()
]]

local GemUpgrade = require(script.Parent.GemUpgrade)
local Income = require(script.Parent.Income)
local IncomePops = require(script.Parent.IncomePops)
local Interaction = require(script.Parent.Interaction)
local PadBillboards = require(script.Parent.PadBillboards)
local PlotReveal = require(script.Parent.PlotReveal)
local ProducerBillboards = require(script.Parent.ProducerBillboards)
local StandSign = require(script.Parent.StandSign)
local Tutorial = require(script.Parent.Tutorial)
local TycoonWorld = require(script.Parent.TycoonWorld)
local YouMarker = require(script.Parent.YouMarker)

local TycoonClient = {}

local started = false

-- Ordered pieces (the world registry first: everything else reads it).
local PIECES: { { name: string, start: () -> () } } = {
	{ name = "TycoonWorld", start = TycoonWorld.start },
	{ name = "ProducerBillboards", start = ProducerBillboards.start },
	{ name = "PadBillboards", start = PadBillboards.start },
	{ name = "Interaction", start = Interaction.start },
	{ name = "GemUpgrade", start = GemUpgrade.start }, -- owner R86 gem button + C / LB
	{ name = "IncomePops", start = IncomePops.start },
	{ name = "YouMarker", start = YouMarker.start },
	{ name = "Income", start = Income.start },
	{ name = "Tutorial", start = Tutorial.start },
	{ name = "StandSign", start = StandSign.start },
	{ name = "PlotReveal", start = PlotReveal.start },
}

--[[ Starts every tycoon client piece (idempotent). ]]
function TycoonClient.start()
	if started then
		return
	end
	started = true
	for _, piece in PIECES do
		local ok, err = pcall(piece.start)
		if not ok then
			warn(`[TycoonClient] {piece.name} failed to start: {err}`)
		end
	end
end

return TycoonClient
