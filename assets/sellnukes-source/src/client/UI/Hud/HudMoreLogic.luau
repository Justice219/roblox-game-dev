--!strict
--[[
	HudMoreLogic — the PURE rules of the HUD's MORE flyout (owner R110: "can we cut down on the
	cards on the left at all? there is just a bunch lol"). No instances, so tests/hud-more.luau
	runs the shipped rules under Lune.

	Purpose:
		Teleport, Rebirth, Event and Settings moved off the left stack into the MORE flyout
		(UI/Hud/HudMoreMenu). Their red badges ("!", "3") and yellow NEW tags must still be seen
		while the flyout is closed, so they ROLL UP onto the MORE tile:
			rollup(children)  the MORE tile's badge text (nil = none) + whether it wears NEW
		Only VISIBLE children count (a hidden Event's stale "!" never badges MORE).

	Badge rule: one badged child -> its text verbatim; several -> the sum when every text is a
	whole number ("2" + "3" -> "5", capped at BADGE_CAP like the Pets badge), else "!".

	Connects to: UI/Hud/HudMoreMenu (calls rollup on every badge / NEW / visibility change),
	tests/hud-more.luau.

	Example:
		HudMoreLogic.rollup({
			{ visible = true, badge = nil, new = true },  -- Teleport (NEW world)
			{ visible = true, badge = "!", new = false }, -- Event (redeemable)
		}) --> "!", true
]]

-- The roll-up of a MORE child: whether it shows, its badge text (nil = none), its NEW tag.
export type Child = {
	visible: boolean,
	badge: string?,
	new: boolean,
}

local HudMoreLogic = {}

-- Largest summed number shown on the MORE badge (PetController caps its badge the same way).
HudMoreLogic.BADGE_CAP = 99

--[[
	The MORE tile's roll-up of its children (see the module header).
	@param children Child list (any order)
	@return (badge text or nil, true when any visible child wears NEW)
	Example: HudMoreLogic.rollup({ { visible = true, badge = "2", new = false },
	         { visible = true, badge = "3", new = false } }) --> "5", false
]]
function HudMoreLogic.rollup(children: { Child }): (string?, boolean)
	local texts: { string } = {}
	local anyNew = false
	for _, child in children do
		if child.visible then
			local badge = child.badge
			if badge ~= nil and badge ~= "" then
				table.insert(texts, badge)
			end
			anyNew = anyNew or child.new
		end
	end
	if #texts == 0 then
		return nil, anyNew
	end
	if #texts == 1 then
		return texts[1], anyNew
	end
	local sum = 0
	for _, text in texts do
		-- Whole numbers only ("3"); "!", "9+" or "1.5" make the roll-up a plain "!".
		local value = if string.match(text, "^%d+$") ~= nil then tonumber(text) else nil
		if value == nil then
			return "!", anyNew
		end
		sum += value
	end
	return tostring(math.min(sum, HudMoreLogic.BADGE_CAP)), anyNew
end

return table.freeze(HudMoreLogic)
