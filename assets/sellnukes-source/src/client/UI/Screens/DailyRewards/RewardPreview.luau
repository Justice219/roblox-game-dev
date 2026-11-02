--!strict
--[[
	RewardPreview — client-side DISPLAY of a RetentionConfig.Reward (what a card / slice / code /
	pack will give), shared by every B7 screen (DailyRewards, TimeRewards, LuckyWheel, Shop,
	GroupRewards, NotifyPrompt). Display only: the server computes and grants the real amounts.

	Cash parts are previewed with the same rule the server uses (RewardLogic.cashFor):
	max(cashFloor, cashSeconds × automated income), where income comes from the player's own
	profile snapshot (tycoon pads / producer levels + rebirths) through the shared TycoonLogic — so
	a card shows "$1.25K" that matches the grant (timed boosts excluded on both sides).

	Lives inside Screens/DailyRewards (a ModuleScript folder) so UIController's screen discovery
	never registers it as a screen. Other screens require it by path:
		local RewardPreview = require(script.Parent.DailyRewards.RewardPreview) -- from Screens/<Name>/init.luau

	Example:
		for _, line in RewardPreview.lines(day.reward, ClientState.profile) do
			print(line.icon, line.text) --> "Cash" "$1.25K" / "Gems" "10 Gems"
		end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BoostConfig = require(ReplicatedStorage.Shared.Config.BoostConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)

export type Line = { icon: string, text: string }

local RewardPreview = {}

--[[ The server clock (synced unix seconds) — never os.time() on the client. ]]
function RewardPreview.serverNow(): number
	return Workspace:GetServerTimeNow()
end

--[[ The automated income ($/s) rewards scale with, from a profile snapshot (0 when unknown). ]]
function RewardPreview.income(profile: { [string]: any }?): number
	if profile == nil then
		return 0
	end
	-- The snapshot is an untyped table: read it as `any`, then check its shape.
	local tycoon: any = profile.tycoon
	if type(tycoon) ~= "table" then
		return 0
	end
	local ok, income = pcall(
		TycoonLogic.incomePerSecond,
		tycoon,
		{
			rebirths = profile.rebirths,
			rebirthShop = profile.rebirthShop,
		} :: any
	)
	if not ok or type(income) ~= "number" or income ~= income or income < 0 or income == math.huge then
		return 0
	end
	return income
end

--[[ The cash a reward would pay for this profile (0 when it has no cash part). ]]
function RewardPreview.cash(reward: RetentionConfig.Reward, profile: { [string]: any }?): number
	if reward.cashSeconds == nil and reward.cashFloor == nil then
		return 0
	end
	local income = RewardPreview.income(profile)
	local scaled = if reward.cashSeconds ~= nil and income > 0 then reward.cashSeconds * income else 0
	local cash = math.max(reward.cashFloor or 0, scaled)
	if cash ~= cash or cash == math.huge or cash <= 0 then
		return 0
	end
	return math.floor(cash)
end

--[[
	Display lines for a reward: one { icon (IconAssets key), text } per part, in a fixed order
	(cash, gems, spins, boost, pet, egg). Items show their name only (their fallback gems are a
	server detail).
]]
function RewardPreview.lines(reward: RetentionConfig.Reward, profile: { [string]: any }?): { Line }
	local lines: { Line } = {}
	local cash = RewardPreview.cash(reward, profile)
	if cash > 0 then
		table.insert(lines, { icon = "Cash", text = NumberFormat.money(cash) })
	end
	if reward.gems ~= nil and reward.gems > 0 then
		table.insert(lines, { icon = "Gems", text = `{NumberFormat.commas(reward.gems)} Gems` })
	end
	if reward.spins ~= nil and reward.spins > 0 then
		table.insert(lines, { icon = "Spins", text = `{reward.spins} Spin{if reward.spins == 1 then "" else "s"}` })
	end
	if reward.boost ~= nil then
		local def = BoostConfig.get(reward.boost.key)
		local name = if def ~= nil then def.name else "Boost"
		table.insert(lines, {
			icon = if def ~= nil then def.icon else "x2Cash",
			text = `{name} {NumberFormat.duration(reward.boost.seconds)}`,
		})
	end
	if reward.pet ~= nil then
		table.insert(lines, { icon = "Pets", text = "Pet" })
	end
	if reward.egg ~= nil then
		table.insert(lines, { icon = "Gift", text = "Egg" })
	end
	return lines
end

--[[ A one-line summary ("$1.25K + 10 Gems"), for compact cards. ]]
function RewardPreview.headline(reward: RetentionConfig.Reward, profile: { [string]: any }?): string
	local parts: { string } = {}
	for _, line in RewardPreview.lines(reward, profile) do
		table.insert(parts, line.text)
	end
	return table.concat(parts, " + ")
end

return table.freeze(RewardPreview)
