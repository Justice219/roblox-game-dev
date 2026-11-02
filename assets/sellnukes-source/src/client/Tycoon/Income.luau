--!strict
--[[
	Income — the HUD's "+$X/s" source: the player's idle income per second.

	Purpose:
		The server computes income with EVERY modifier (pets, passes, boosts, the server-wide
		boost) and publishes it as the player attribute `IncomePerSecond` (Tycoon/TycoonService,
		B5). The client must not recompute it (it cannot see all modifiers), so this module only
		reads that attribute; before it exists the HUD hides the rate row (nil).
		Hud.setIncomeSource polls the source once per second and on profile changes.

	Connects to: UI/Hud/Hud (setIncomeSource), Tycoon/TycoonContract (attribute name).

	Example: Income.start(); print(Income.perSecond())
]]

local Players = game:GetService("Players")

local Contract = require(script.Parent.TycoonContract)
local Hud = require(script.Parent.Parent.UI.Hud.Hud)

local Income = {}

--[[ The server-published income per second, or nil before the server published it. ]]
function Income.perSecond(): number?
	local value = Players.LocalPlayer:GetAttribute(Contract.Attr.IncomePerSecond)
	if type(value) == "number" and value == value and value >= 0 and value < math.huge then
		return value
	end
	return nil
end

--[[ Installs the HUD income source (once). ]]
function Income.start()
	Hud.setIncomeSource(Income.perSecond)
end

return Income
