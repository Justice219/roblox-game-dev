--!strict
--[[
	BigPopBanner — the server-wide Big Pop announcement as a compact BOTTOM-LEFT pill (owner R108:
	"I think the popping batches are a bit absurd with the UI they take. can they just take up the
	bottom left?"; replaces the R89 centre card), e.g.

		[nuke] JusticeDev got GALAXY nukes! (1 in 2,500)

	OTHER players' Big Pops become small stud pills in the bottom-left FEED (UI/Hud/Toasts.pushPill,
	group "bigPop"): the flavour / rarity colour + an icon (Nuke / Pets / Rebirth) + one line. Owner
	R120: Tycoon/FlavorController shows at most ONE per PopupQueueConfig.Feed.Flavor.BigPopGap (30 s;
	the rest coalesce into it as "+N"), batches Galaxy+ only, never the local player's own (their
	Lucky Nuke already has its pill / card). At most Feed.BigPopMax (3) are stacked, each visible
	about Feed.BigPopSeconds (5 s), then it fades. The column follows the feed
	rules (clear of the left grid, the objective chip, the hint bar, the touch thumbstick reserve and
	any open window; the smaller pill on phones). Display only (never Active / Selectable: gamepad +
	touch input untouched). The toy fireworks over the plot stay (Tycoon/FlavorController).

	Text (owner R112 "Lucky Nukes" wording): FlavorConfig.bigPopLine(name, kind, label, odds) from
	the server's structured entry (DisplayName + config-derived label + odds); names are shown as
	plain text (TextLabel without RichText), never interpreted.

	Connects to: UI/Hud/Toasts (pushPill), Shared/Config/{FlavorConfig, PetConfig, PopupQueueConfig,
	UIStyleConfig}, Shared/Tycoon/FlavorLogic (odds text), caller Tycoon/FlavorController.

	Example:
		BigPopBanner.show({ name = "Alex", kind = "batch", id = "galaxy", label = "GALAXY", oneIn = 2500 }, 2)
		--> pill "Alex got GALAXY nukes! (1 in 2,500) +2"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local FlavorLogic = require(ReplicatedStorage.Shared.Tycoon.FlavorLogic)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PopupQueueConfig = require(ReplicatedStorage.Shared.Config.PopupQueueConfig)
local Toasts = require(script.Parent.Parent.Parent.UI.Hud.Toasts)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type Entry = {
	name: string,
	kind: string, -- "batch" | "hatch" | "rebirth"
	id: string, -- flavour id / pet rarity / world id
	label: string,
	oneIn: number,
}

local BigPopBanner = {}

--[[
	The pill / chat line for an entry, odds included ("Alex got GALAXY nukes! (1 in 2,500)").
	@param entry Entry
	@return string
	Example: BigPopBanner.line({ name = "Alex", kind = "hatch", label = "MYTHIC Nova Fox", oneIn = 0, ... })
		--> "Alex hatched a MYTHIC Nova Fox!"
]]
function BigPopBanner.line(entry: Entry): string
	return FlavorConfig.bigPopLine(entry.name, entry.kind, entry.label, FlavorLogic.formatOdds(entry.oneIn))
end

-- The pill colour of an entry (flavour / rarity preset; rebirths are yellow).
local function colorOf(entry: Entry): UIStyleConfig.ColorName
	if entry.kind == "batch" then
		local def = FlavorConfig.byId(entry.id)
		return if def ~= nil then def.ui else "purple"
	elseif entry.kind == "hatch" then
		local rarity = PetConfig.rarity(entry.id)
		return (if rarity ~= nil then rarity.ui else "red") :: UIStyleConfig.ColorName
	end
	return "yellow"
end

-- The icon key of an entry.
local function iconOf(entry: Entry): string
	if entry.kind == "hatch" then
		return "Pets"
	elseif entry.kind == "rebirth" then
		return "Rebirth"
	end
	return "Nuke"
end

--[[
	Shows one Big Pop entry as a pill in the bottom-left feed (see the header).
	@param entry Entry — one validated entry of a broadcast
	@param more number? — other Big Pops folded into it (shown as " +N")
	@param seconds number? — hold (default Feed.BigPopSeconds; QA captures pass longer)
	@return boolean — true when handed to the feed
]]
function BigPopBanner.show(entry: Entry, more: number?, seconds: number?): boolean
	local folded = if more ~= nil and more == more and more >= 1 then math.min(math.floor(more), 99) else 0
	Toasts.pushPill({
		text = BigPopBanner.line(entry) .. (if folded > 0 then ` +{folded}` else ""),
		color = colorOf(entry),
		icon = iconOf(entry),
		seconds = if seconds ~= nil then seconds else PopupQueueConfig.Feed.BigPopSeconds,
		group = "bigPop",
	})
	return true
end

return BigPopBanner
