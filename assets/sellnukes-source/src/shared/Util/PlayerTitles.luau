--!strict
--[[
	PlayerTitles — the pure rules of Player Titles (owner R73 / R74). No Roblox APIs; only
	Shared/Config/PlayerTitlesConfig is required, so tests/player-titles.luau runs it directly.

		def(key)                      the catalogue entry of a key, or nil (junk -> nil)
		resolve(userId, granted)      the ONE title a player displays: the highest-priority
		                              catalogue key among their permanent (UserId) titles and their
		                              granted profile titles; nil = none
		canGrant(key)                 whether the admin panel may give / revoke `key`
		grant(state, key) / revoke(state, key)   validated edits of a profile's granted set
		newState() / reconcileState(raw)         the profile `titles` field (schema-safe)
		hiddenFromSetting(show)       the TitleHidden attribute from the `showTitle` setting
		shown(title, hidden)          the def a client draws for a player, from that player's
		                              REPLICATED attributes (nil = draw nothing)
		chatPrefix(def, existing)     the chat PrefixText with the coloured tag in front

	Security: titles are decided on the server from the UserId + the server-held profile; clients
	only read the server-set Player attributes (they cannot forge them). Admin arguments are
	validated against the catalogue here and in AdminService's enum check.

	Connects to: Shared/Config/PlayerTitlesConfig, Server/Services/PlayerTitleService,
	Server/Economy/ProfileLogic, Client/Social/PlayerTitleClient.

	Example:
		PlayerTitles.resolve(1586034782, nil) --> "developer"
		PlayerTitles.resolve(42, { earlyPlayer = true }) --> "earlyPlayer"
]]

local PlayerTitlesConfig = require(script.Parent.Parent.Config.PlayerTitlesConfig)

export type State = { [string]: true }
type TitleDef = PlayerTitlesConfig.TitleDef

local Titles = PlayerTitlesConfig.Titles

local PlayerTitles = {}

-- A saved key's shape (catalogue keys, or a newer server's: ^[a-z][a-zA-Z0-9]{0,23}$).
local function wellFormed(key: unknown): boolean
	return type(key) == "string" and #key <= 24 and string.match(key, "^[a-z][a-zA-Z0-9]*$") ~= nil
end

--[[ The catalogue entry of `key` (exact key), else nil. ]]
function PlayerTitles.def(key: unknown): TitleDef?
	if type(key) ~= "string" then
		return nil
	end
	return Titles[key]
end

--[[
	The displayed title of a player: the highest-priority CATALOGUE key among the permanent titles
	of `userId` (PlayerTitlesConfig.Holders) and the `granted` profile set. Unknown keys (e.g. a
	newer server's title kept by reconcile) never display.
	@param userId  the player's UserId (junk -> no permanent titles)
	@param granted the profile's `titles` set (nil = none / not loaded yet)
	@return a catalogue key, or nil
]]
function PlayerTitles.resolve(userId: unknown, granted: { [string]: any }?): string?
	local best: TitleDef? = nil
	local function consider(key: unknown)
		local candidate = PlayerTitles.def(key)
		if candidate ~= nil and (best == nil or candidate.priority > (best :: TitleDef).priority) then
			best = candidate
		end
	end
	if type(userId) == "number" and userId == userId and userId > 0 and userId % 1 == 0 then
		local held = PlayerTitlesConfig.Holders[userId]
		if held ~= nil then
			for _, key in held do
				consider(key)
			end
		end
	end
	if type(granted) == "table" then
		for key, value in granted do
			if value == true then
				consider(key)
			end
		end
	end
	local chosen = best
	return if chosen ~= nil then chosen.key else nil
end

--[[ True when the admin panel may give / revoke `key` (a grantable catalogue title). ]]
function PlayerTitles.canGrant(key: unknown): boolean
	local entry = PlayerTitles.def(key)
	return entry ~= nil and entry.grantable
end

--[[ The grantable keys in catalogue order (the admin dropdown) + their labels. ]]
function PlayerTitles.grantChoices(): ({ string }, { string })
	local values: { string } = {}
	local labels: { string } = {}
	for _, key in PlayerTitlesConfig.Order do
		local entry = Titles[key]
		if entry ~= nil and entry.grantable then
			table.insert(values, key)
			table.insert(labels, entry.label)
		end
	end
	return values, labels
end

--[[
	Gives `key` to a profile's granted set (validated: a grantable catalogue title; capped).
	@return (changed, problem) — problem names why it was refused
	Example: PlayerTitles.grant(state, "earlyPlayer") --> true, nil
]]
function PlayerTitles.grant(state: State, key: unknown): (boolean, string?)
	if not PlayerTitles.canGrant(key) then
		return false, "not a grantable title"
	end
	local id = key :: string
	if state[id] == true then
		return false, "already has it"
	end
	local count = 0
	for _ in state do
		count += 1
	end
	if count >= PlayerTitlesConfig.MaxGranted then
		return false, "too many titles"
	end
	state[id] = true
	return true, nil
end

--[[
	Removes a granted `key` (validated like grant; permanent UserId titles are config, never here).
	@return (changed, problem)
]]
function PlayerTitles.revoke(state: State, key: unknown): (boolean, string?)
	if not PlayerTitles.canGrant(key) then
		return false, "not a grantable title"
	end
	local id = key :: string
	if state[id] ~= true then
		return false, "does not have it"
	end
	state[id] = nil
	return true, nil
end

--[[ A fresh profile's granted titles (none). ]]
function PlayerTitles.newState(): State
	return {}
end

--[[
	The profile `titles` field from untrusted save data: only well-formed keys mapped to true,
	at most MaxGranted (catalogue keys first, then others in sorted order, so a newer server's
	titles survive a rollback without ever displaying here).
]]
function PlayerTitles.reconcileState(raw: unknown): State
	local out: State = {}
	if type(raw) ~= "table" then
		return out
	end
	local count = 0
	local source = raw :: { [any]: any }
	for _, key in PlayerTitlesConfig.Order do
		if source[key] == true and count < PlayerTitlesConfig.MaxGranted then
			out[key] = true
			count += 1
		end
	end
	local extra: { string } = {}
	for key, value in source do
		if value == true and wellFormed(key) and Titles[key] == nil then
			table.insert(extra, key)
		end
	end
	table.sort(extra)
	for _, key in extra do
		if count >= PlayerTitlesConfig.MaxGranted then
			break
		end
		out[key] = true
		count += 1
	end
	return out
end

--[[
	The TitleHidden attribute from the `showTitle` setting: only an explicit false hides.
	Example: PlayerTitles.hiddenFromSetting(false) --> true ; (nil) --> false
]]
function PlayerTitles.hiddenFromSetting(show: unknown): boolean
	return show == false
end

--[[
	What a client draws for a player from the replicated attributes: the catalogue def of the
	Title attribute unless TitleHidden is exactly true. Junk attributes draw nothing.
	Example: PlayerTitles.shown("developer", nil).label --> "DEVELOPER"
]]
function PlayerTitles.shown(title: unknown, hidden: unknown): TitleDef?
	if hidden == true then
		return nil
	end
	return PlayerTitles.def(title)
end

--[[
	The chat PrefixText with the title's coloured tag in front. `existing` is the engine's prefix
	(the speaker's already-escaped display name); the tag is constant catalogue text, so nothing
	player-written is ever interpreted as rich text here.
]]
function PlayerTitles.chatPrefix(entry: TitleDef, existing: unknown): string
	local rest = if type(existing) == "string" then existing else ""
	local tag = `<font color="{entry.chatColor}">{entry.chatPrefix}</font>`
	return if rest == "" then tag else `{tag} {rest}`
end

return table.freeze(PlayerTitles)
