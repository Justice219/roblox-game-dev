--!strict
--[[
	TextUtil — UTF-8-safe text trimming for names that travel over the wire or into attributes.

	Purpose:
		Roblox display names can hold multi-byte characters (accents, CJK, emoji: up to 4 bytes
		each). Capping them with `string.sub(text, 1, n)` counts BYTES and can cut a character in
		half, leaving invalid UTF-8. Invalid UTF-8 renders as a replacement glyph at best, and
		`HttpService:JSONEncode` can refuse it at worst (which would abort an attribute publish).
		These helpers always cut on a character boundary and refuse invalid input.

	Connects to (copied from RoBeasts):
		- Server/Economy/ProfileLogic  reconcile caps the stand sign name (tycoon.standName) and
		  the event season id without ever splitting a character
		- Shared/Net/Validate.text     caps player-typed text (RenameStand) before filtering
		- any future name label (leaderboards, plot signs)

	Kept free of Instance access, so it is safe on the server, the client and under Lune
	(tests/validate.luau).

	Example:
		TextUtil.cutChars("Zoë the Brave", 3)   --> "Zoë"
		TextUtil.cutBytes("Zoë the Brave", 3)   --> "Zo"   (ë needs 2 bytes; 4 would not fit)
		TextUtil.cutChars("\255bad", 10)        --> ""     (invalid UTF-8 is never forwarded)
]]

local TextUtil = {}

--[[
	Keeps at most `maxChars` characters (codepoints) of `text`.
	@param text     the input string
	@param maxChars the character cap (values < 1 return "")
	@return the cut string; "" when `text` is not valid UTF-8
	Example: TextUtil.cutChars("日本語のなまえ", 3) --> "日本語"
]]
function TextUtil.cutChars(text: string, maxChars: number): string
	local length = utf8.len(text)
	if length == nil then
		return "" -- invalid UTF-8: never forward it
	end
	if maxChars < 1 then
		return ""
	end
	if length <= maxChars then
		return text
	end
	-- utf8.offset(text, n) is the byte index where character n starts, so the first maxChars
	-- characters end one byte before character maxChars + 1 begins.
	local stop = utf8.offset(text, maxChars + 1)
	return if stop == nil then text else string.sub(text, 1, stop - 1)
end

--[[
	Keeps the longest prefix of `text` that fits in `maxBytes` bytes without splitting a character
	(a byte budget, e.g. for wire-size caps).
	@param text     the input string
	@param maxBytes the byte cap (values < 1 return "")
	@return the cut string; "" when `text` is not valid UTF-8
	Example: TextUtil.cutBytes("Zoë", 3) --> "Zo"
]]
function TextUtil.cutBytes(text: string, maxBytes: number): string
	if utf8.len(text) == nil or maxBytes < 1 then
		return ""
	end
	if #text <= maxBytes then
		return text
	end
	-- Walk character starts; keep every character whose last byte still fits the budget.
	local keep = 0
	for position, _ in utf8.codes(text) do
		local nextStart = utf8.offset(text, 2, position) or (#text + 1)
		if nextStart - 1 > maxBytes then
			break
		end
		keep = nextStart - 1
	end
	return string.sub(text, 1, keep)
end

return TextUtil
