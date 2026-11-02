--!strict
--[[
	NotifySectionLogic — the PURE text rules of the admin panel's RETURN NOTIFICATIONS section
	(owner R122 §2.3; Screens/Admin/NotifySection draws it on the Server tab). Display only: the
	server re-checks every command.

	describe(attrs, kinds, isStudio) turns the ReplicatedStorage display attributes the server
	publishes (NotifyConfig.Attributes: On, KindsOff) and the shared kind table (message ids) into:
		line    "Sending ON · Factory full ON · Daily streak NO ID · Daily missions OFF" (rich text)
		note    what the switches mean / what is missing (owner steps)
		ready   kinds that can send right now
	A missing attribute (server not started yet) reads as "…" (unknown), never as ON.

	Connects to: Shared/Config/NotifyConfig; used by Screens/Admin/NotifySection;
	tests/return-notify-prompt.luau.

	Example:
		local view = NotifySectionLogic.describe({ ReturnNotifyOn = true, ReturnNotifyKindsOff = "" }, NotifyConfig.Kinds, false)
		print(view.line)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NotifyConfig = require(ReplicatedStorage.Shared.Config.NotifyConfig)

export type View = { line: string, note: string, ready: number }

local NotifySectionLogic = {}

local GREEN = "#78F046"
local RED = "#FF4646"
local GREY = "#B4B4B4"

-- A rich-text coloured word.
local function paint(text: string, color: string): string
	return `<font color="{color}">{text}</font>`
end

--[[
	The kinds a KindsOff attribute names (comma list; unknown names ignored).
	Example: NotifySectionLogic.offSet("streak,bogus") --> { streak = true }
]]
function NotifySectionLogic.offSet(raw: unknown): { [string]: boolean }
	local off: { [string]: boolean } = {}
	if type(raw) ~= "string" or #raw > 200 then
		return off
	end
	for _, name in string.split(raw, ",") do
		if NotifyConfig.isKind(name) then
			off[name] = true
		end
	end
	return off
end

--[[
	The section's texts.
	@param attrs { [string]: any } — ReplicatedStorage:GetAttribute values by name
	@param kinds { [Kind]: KindDef } — NotifyConfig.Kinds (message ids)
	@param isStudio boolean — AdminState.isStudio (Studio = dry run, placeholder ids)
	@return View
]]
function NotifySectionLogic.describe(attrs: { [string]: any }, kinds: { [string]: any }, isStudio: boolean): View
	local names = NotifyConfig.Attributes
	local on = attrs[names.On]
	local known = type(on) == "boolean"
	local off = NotifySectionLogic.offSet(attrs[names.KindsOff])
	local parts = {
		"Sending " .. (if not known then paint("…", GREY) elseif on then paint("ON", GREEN) else paint("OFF", RED)),
	}
	local ready = 0
	local missing: { string } = {}
	for _, kind in NotifyConfig.KindOrder do
		local def = kinds[kind]
		local label = if def ~= nil then def.label else kind
		local hasId = def ~= nil and NotifyConfig.isMessageId(def.messageId)
		local state: string
		if not hasId then
			table.insert(missing, label)
			state = if isStudio then paint("DRY", GREY) else paint("NO ID", RED)
		elseif off[kind] then
			state = paint("OFF", RED)
		else
			state = paint("ON", GREEN)
			if known and on then
				ready += 1
			end
		end
		table.insert(parts, `{label} {state}`)
	end
	local note: string
	if known and not on then
		note = "Kill switch is OFF on every server: nothing is planned or sent."
	elseif #missing > 0 and not isStudio then
		note =
			`No message id yet for {table.concat(missing, ", ")}: paste the Creator Dashboard asset ids into NotifyConfig (docs/retention.md).`
	elseif isStudio then
		note = "Studio: everything runs as a dry run (no request is sent). Queue Test below runs the real queue."
	else
		note = "Switches reach every server within seconds. NotifyStatus shows the queue and this server's results."
	end
	return { line = table.concat(parts, " · "), note = note, ready = ready }
end

return table.freeze(NotifySectionLogic)
