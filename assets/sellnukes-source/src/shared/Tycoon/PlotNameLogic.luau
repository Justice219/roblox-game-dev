--!strict
--[[
	PlotNameLogic — the pure rules of the owner-chosen PLOT NAME on the entrance sign (owner R88).

	Purpose:
		Shared by the server (RenamePlot handler, sign text), the client (naming window) and the
		Lune tests, so "what is a valid name" and "what does the sign say" live in ONE tested place:
			parse(raw, maxChars)          a RenamePlot argument → { kind = "set", text } |
			                              { kind = "reset" } | nil (refused)
			clean(text, maxChars)         the client's pre-send check (same rule as parse "set")
			normalize(text)               invisible characters dropped, Unicode spaces → " ",
			                              whitespace runs collapsed, trimmed
			defaultName(display, suffix)  "<DisplayName>'s Nukes" / "<DisplayName>'s Dino Valley"
			signText(display, suffix, custom)  the custom name when set, else the default
			isCustom(value)               a saved plotName that replaces the default

	Rules (security: the client is never trusted; this only shapes text BEFORE the server's
	TextService broadcast filter, which every shown name still goes through):
		- Validate.text first: a string, ≤ maxChars * 4 bytes before any scan, valid UTF-8, no
		  ASCII / C1 control characters, 1..maxChars characters after trimming.
		- normalize: zero-width / bidi-override / soft-hyphen characters are dropped (they hide words
		  from the filter and can make a sign look blank or reversed), Unicode space characters
		  become plain spaces, runs collapse to one space, the ends are trimmed.
		- A name that normalizes to "" is refused (never silently turned into a reset).
		- An all-whitespace (or empty) argument is the explicit RESET TO DEFAULT intent.

	Connects to: Shared/Net/Validate (text), Shared/Config/PlotNameConfig (cap, suffix),
	Server/Tycoon/PlotNames, Server/World/PlotBuilder (sign text), Client/UI/Screens/RenameStand
	(plot mode), tests/plot-name.luau.

	Example:
		PlotNameLogic.parse("  Sparkle   Base ", 24)          --> { kind = "set", text = "Sparkle Base" }
		PlotNameLogic.parse("   ", 24)                        --> { kind = "reset" }
		PlotNameLogic.parse(42, 24)                           --> nil
		PlotNameLogic.signText("Sam", "Nukes", "")            --> "Sam's Nukes"
		PlotNameLogic.signText("Sam", "Nukes", "Sparkle Base") --> "Sparkle Base"
]]

local Validate = require(script.Parent.Parent.Net.Validate)

local PlotNameLogic = {}

export type Intent = { kind: "set", text: string } | { kind: "reset" }

--[[
	Codepoints dropped by normalize: zero-width space / non-joiner / joiner, LRM / RLM, the bidi
	embedding + override + isolate controls, word joiner + invisible operators, BOM, soft hyphen,
	Mongolian vowel separator, Hangul fillers (render as blank).
]]
local INVISIBLE: { [number]: true } = {
	[0x00AD] = true,
	[0x034F] = true,
	[0x061C] = true,
	[0x115F] = true,
	[0x1160] = true,
	[0x180E] = true,
	[0x3164] = true,
	[0xFEFF] = true,
	[0xFFA0] = true,
}
for codepoint = 0x200B, 0x200F do
	INVISIBLE[codepoint] = true
end
for codepoint = 0x202A, 0x202E do
	INVISIBLE[codepoint] = true
end
for codepoint = 0x2060, 0x206F do
	INVISIBLE[codepoint] = true
end

-- Unicode space characters normalize turns into a plain " " (then collapses).
local SPACES: { [number]: true } = {
	[0x0020] = true,
	[0x00A0] = true,
	[0x1680] = true,
	[0x202F] = true,
	[0x205F] = true,
	[0x3000] = true,
}
for codepoint = 0x2000, 0x200A do
	SPACES[codepoint] = true
end

--[[
	Drops invisible characters, maps Unicode spaces to " ", collapses whitespace runs and trims.
	Invalid UTF-8 returns "" (never forwarded). Callers validate (Validate.text) first.
	@param text string
	@return string — possibly "" (all invisible / blank)
	Example: PlotNameLogic.normalize("Nuke\u{200B}  Town") --> "Nuke Town"
]]
function PlotNameLogic.normalize(text: string): string
	if utf8.len(text) == nil then
		return ""
	end
	local out: { string } = {}
	local pendingSpace = false
	for _, codepoint in utf8.codes(text) do
		if INVISIBLE[codepoint] then
			continue
		end
		if SPACES[codepoint] or codepoint == 0x09 or codepoint == 0x0A or codepoint == 0x0D then
			pendingSpace = #out > 0 -- leading spaces are dropped; inner runs become one space
			continue
		end
		if pendingSpace then
			table.insert(out, " ")
			pendingSpace = false
		end
		table.insert(out, utf8.char(codepoint))
	end
	-- A trailing run is simply never emitted (pendingSpace is dropped here).
	return table.concat(out)
end

--[[
	Reads a RenamePlot argument (raw client data).
	@param raw unknown — what the client sent
	@param maxChars number — PlotNameConfig.MaxChars
	@return Intent? — "set" with the normalized name, "reset" for an empty / all-space string,
	        nil for anything else (wrong type, too long, control characters, invalid UTF-8, or a
	        name that is nothing but invisible characters)
	Example: PlotNameLogic.parse("", 24) --> { kind = "reset" }
]]
function PlotNameLogic.parse(raw: unknown, maxChars: number): Intent?
	if type(raw) ~= "string" or #raw > maxChars * 4 then
		return nil
	end
	if string.match(raw, "^%s*$") ~= nil then
		return { kind = "reset" }
	end
	local text = Validate.text(raw, maxChars)
	if text == nil then
		return nil
	end
	local name = PlotNameLogic.normalize(text)
	local length = utf8.len(name)
	if length == nil or length < 1 or length > maxChars then
		return nil
	end
	return { kind = "set", text = name }
end

--[[
	The client's pre-send check of a typed name (the server re-checks with parse).
	@return the name to send, or nil when it cannot be sent (blank names are a RESET, not a name)
	Example: PlotNameLogic.clean("  Big   Boom ", 24) --> "Big Boom"
]]
function PlotNameLogic.clean(text: string, maxChars: number): string?
	local intent = PlotNameLogic.parse(text, maxChars)
	if intent ~= nil and intent.kind == "set" then
		return intent.text
	end
	return nil
end

--[[
	The default sign text of an owned plot.
	@param displayName string — the owner's Roblox display name (already moderated by Roblox)
	@param suffix string — "Nukes" in Nuke Town, the world's name elsewhere
	Example: PlotNameLogic.defaultName("Sam", "Dino Valley") --> "Sam's Dino Valley"
]]
function PlotNameLogic.defaultName(displayName: string, suffix: string): string
	return `{displayName}'s {suffix}`
end

--[[ True when a saved plotName replaces the default (a non-empty string). ]]
function PlotNameLogic.isCustom(value: unknown): boolean
	return type(value) == "string" and value ~= ""
end

--[[
	The text on an owned plot's entrance sign.
	@param custom string? — the (filtered) custom name; nil / "" = the default
	Example: PlotNameLogic.signText("Sam", "Nukes", nil) --> "Sam's Nukes"
]]
function PlotNameLogic.signText(displayName: string, suffix: string, custom: string?): string
	if custom ~= nil and PlotNameLogic.isCustom(custom) then
		return custom
	end
	return PlotNameLogic.defaultName(displayName, suffix)
end

return table.freeze(PlotNameLogic)
