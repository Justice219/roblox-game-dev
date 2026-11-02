--!strict
--[[
	ChangeNotesLogic — the pure WHAT'S NEW rules (port of RoBeasts' module, owner R58; data in
	Shared/Config/ChangeNotesConfig). No Instances, no services, no yields: the server
	(ChangeNotesService), the client (ChangeNotes/ChangeNotesClient) and tests/change-notes.luau all
	run exactly this code.

	Rules:
		Seen position: profile.notes.seen holds the newest note id the player has seen. Its index in
		  ChangeNotesConfig.Notes is the position; "" = 0 (nothing seen). A well-formed id this build
		  does not know was written by a NEWER server (a rolling update): it counts as "everything
		  here seen", so an old server never re-shows notes the player already read.
		Visible notes: a note with a future ShowFrom does not exist for players yet. Every rule
		  below takes `now` (unix seconds: os.time() on the server, the client's lagged server clock
		  on the client) and reads ChangeNotesConfig.visibleCount(now) (the first N notes).
		Unseen: any VISIBLE note after the seen position.
		Mark seen (server, ChangeNotesAction "seen"): the id must be a known note, visible now
		  ("Hidden" otherwise) AND strictly newer than the stored position ("only moves forward");
		  otherwise refused (Unknown / Hidden / NotForward). Only the owner admin's reset
		  (ChangeNotesAdmin → `resetSeen`) ever moves it back.
		No-context players (server, on profile load): a brand-new profile (migration "new") or a
		  player who has not finished the tutorial yet has no context for "what changed", so the
		  newest VISIBLE note is marked seen at once: they never get the auto pop-up and the HUD dot
		  stays off. (RoBeasts: "no finished match"; SellNukes: "tutorial not finished".) A note
		  still hidden stays unseen, so it greets them once it is revealed.
		Actions (C→S): verb ∈ Actions, a known note id that is visible now, and for "shown" a
		  Source; "closed" may carry the seconds the panel was open (clamped, analytics only).

	Example:
		local now = os.time()
		local state = ChangeNotesConfig.newState()
		ChangeNotesLogic.hasUnseen(state.seen, now)                          --> true
		ChangeNotesLogic.markSeen(state, newest.Id, now)                     --> "Ok"
		ChangeNotesLogic.markSeen(state, newest.Id, now)                     --> "NotForward"
		ChangeNotesLogic.onProfileLoaded(fresh, "new", false, now)           --> true (newest marked)
		ChangeNotesLogic.shouldAutoShow(state.seen, "current", true, now)    --> false (all seen)
]]

local ChangeNotesConfig = require(script.Parent.Parent.Config.ChangeNotesConfig)

-- "Hidden": a known note whose ShowFrom is still in the future.
export type Verdict = "Ok" | "Unknown" | "Hidden" | "NotForward"
-- A validated ChangeNotesAction: the verb, a KNOWN, VISIBLE note id, the source (verb "shown"
-- only) and the seconds the panel was open (verb "closed" only, clamped; nil when not sent).
export type ParsedAction = {
	verb: ChangeNotesConfig.Action,
	id: string,
	source: ChangeNotesConfig.Source?,
	seconds: number?,
}

local ChangeNotesLogic = {}

--[[
	The seen position: the stored id's index (1 = oldest note), 0 for "" / malformed, and
	#Notes for a well-formed id this build does not know (written by a newer server).
	Example: seenIndex("") --> 0
]]
function ChangeNotesLogic.seenIndex(seen: unknown): number
	local index = ChangeNotesConfig.indexOf(seen)
	if index ~= nil then
		return index
	end
	if ChangeNotesConfig.isIdShape(seen) then
		return #ChangeNotesConfig.Notes
	end
	return 0
end

--[[ How many VISIBLE notes are newer than the seen position at `now` (0 = up to date). ]]
function ChangeNotesLogic.unseenCount(seen: unknown, now: number): number
	return math.max(0, ChangeNotesConfig.visibleCount(now) - ChangeNotesLogic.seenIndex(seen))
end

--[[ True while at least one visible note is newer than the seen position (the HUD chip's dot). ]]
function ChangeNotesLogic.hasUnseen(seen: unknown, now: number): boolean
	return ChangeNotesLogic.unseenCount(seen, now) > 0
end

--[[
	True when the note at `index` (1 = oldest) is newer than the seen position — the panel draws a
	NEW ribbon on it. Example: isUnseenIndex("", 1) --> true
]]
function ChangeNotesLogic.isUnseenIndex(seen: unknown, index: number): boolean
	return index > ChangeNotesLogic.seenIndex(seen)
end

--[[
	Whether `id` may become the new seen position at `now` (see the module header).
	@return "Ok" | "Unknown" (not a note in this build) | "Hidden" (its ShowFrom is in the future)
	        | "NotForward" (not newer than stored)
]]
function ChangeNotesLogic.canMarkSeen(seen: unknown, id: unknown, now: number): Verdict
	local index = ChangeNotesConfig.indexOf(id)
	if index == nil then
		return "Unknown"
	end
	if index > ChangeNotesConfig.visibleCount(now) then
		return "Hidden"
	end
	if index <= ChangeNotesLogic.seenIndex(seen) then
		return "NotForward"
	end
	return "Ok"
end

--[[
	Moves the seen position forward to `id` (mutates `state` only on "Ok").
	@param state profile.notes
	@param id    the note id the player has now seen (untrusted)
	@param now   unix seconds (visibility, and stored as state.at)
	@return Verdict
	Example: markSeen(profile.notes, "2026-10-31-whats-new", os.time()) --> "Ok"
]]
function ChangeNotesLogic.markSeen(state: ChangeNotesConfig.State, id: unknown, now: number): Verdict
	local verdict = ChangeNotesLogic.canMarkSeen(state.seen, id, now)
	if verdict == "Ok" then
		state.seen = id :: string
		state.at = math.max(0, math.floor(now))
	end
	return verdict
end

--[[
	OWNER ADMIN ONLY (ChangeNotesAdmin "WhatsNewReset"): sets the seen position BACK to `id` (a
	known note) or to "" (nothing seen), so the returning-player pop-up can be tested. Never
	reachable from a client remote.
	@return true when `id` was accepted ("" or a known note id)
	Example: resetSeen(profile.notes, "", os.time()) --> true (every note unseen again)
]]
function ChangeNotesLogic.resetSeen(state: ChangeNotesConfig.State, id: unknown, now: number): boolean
	if id ~= "" and ChangeNotesConfig.indexOf(id) == nil then
		return false
	end
	state.seen = id :: string
	state.at = math.max(0, math.floor(now))
	return true
end

--[[
	True when the player has no context for change notes: a brand-new profile this session
	(ProfileStore migration "new") or the tutorial is not finished yet (TutorialLogic.DoneStep).
	Example: isNoContextPlayer("current", true) --> false (a returning player)
]]
function ChangeNotesLogic.isNoContextPlayer(migration: string, tutorialDone: boolean): boolean
	return migration == "new" or tutorialDone ~= true
end

--[[
	Server, once per profile load: a no-context player with an unseen note gets the newest VISIBLE
	note marked seen (never an auto pop-up for them). Returning players are left untouched.
	@return true when `state` changed (the caller saves + pushes the profile)
	Example: onProfileLoaded(profile.notes, session.migration, tutorialDone, os.time())
]]
function ChangeNotesLogic.onProfileLoaded(
	state: ChangeNotesConfig.State,
	migration: string,
	tutorialDone: boolean,
	now: number
): boolean
	if not ChangeNotesLogic.isNoContextPlayer(migration, tutorialDone) then
		return false
	end
	local newest = ChangeNotesConfig.newestVisible(now)
	if newest == nil then
		return false
	end
	return ChangeNotesLogic.markSeen(state, newest.Id, now) == "Ok"
end

--[[
	THE "should the panel auto-open on this join?" rule, in one place (server-side semantics; the
	client's driver reads the result of the server's load rule through the snapshot and applies
	autoNote). True only for a RETURNING player (not a fresh profile, tutorial finished) whose seen
	position is behind the newest visible note at `now`. Malformed seen values count as "nothing
	seen" (a returning player then gets the newest note once); a newer server's id counts as "all
	seen". Pure: Lune covers new vs returning, older / equal / newer, malformed.
	Example: shouldAutoShow("2026-10-30-nuke-empire", "current", true, now) --> true (0.3.0 unseen)
]]
function ChangeNotesLogic.shouldAutoShow(seen: unknown, migration: string, tutorialDone: boolean, now: number): boolean
	if ChangeNotesLogic.isNoContextPlayer(migration, tutorialDone) then
		return false
	end
	return ChangeNotesLogic.hasUnseen(seen, now)
end

-- Clamps a client-measured "seconds open" (untrusted): finite, 0..MaxOpenSeconds, whole seconds.
local function cleanSeconds(value: unknown): number?
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return math.floor(math.clamp(value, 0, ChangeNotesConfig.Server.MaxOpenSeconds))
end

--[[
	Validates one ChangeNotesAction (C→S) payload at `now`. Every argument is untrusted.
	@param verb  "seen" | "shown" | "cta" | "closed"
	@param id    a note id
	@param arg   "shown": the source ("auto" | "menu", required); "closed": seconds open (optional
	             number, clamped); ignored otherwise
	@return the parsed action, or nil (unknown verb / note id, a note still hidden by ShowFrom,
	        missing or bad source on "shown")
	Example: parseAction("shown", newest.Id, "auto", os.time()) --> { verb = "shown", id = newest.Id, source = "auto" }
]]
function ChangeNotesLogic.parseAction(verb: unknown, id: unknown, arg: unknown, now: number): ParsedAction?
	if type(verb) ~= "string" or not ChangeNotesConfig.ActionSet[verb] then
		return nil
	end
	if type(id) ~= "string" or #id > ChangeNotesConfig.Limits.MaxIdLength then
		return nil
	end
	local note = ChangeNotesConfig.get(id)
	if note == nil or not ChangeNotesConfig.isVisible(note, now) then
		return nil
	end
	if verb == "shown" then
		if type(arg) ~= "string" or not ChangeNotesConfig.SourceSet[arg] then
			return nil
		end
		return { verb = verb :: ChangeNotesConfig.Action, id = id, source = arg :: ChangeNotesConfig.Source }
	end
	if verb == "closed" then
		return { verb = verb :: ChangeNotesConfig.Action, id = id, seconds = cleanSeconds(arg) }
	end
	return { verb = verb :: ChangeNotesConfig.Action, id = id }
end

--[[
	The analytics counter of a parsed action (family retention; KeySpec kind "noteId"):
	"notes:shown:<id>:<auto|menu>", "notes:cta:<id>", "notes:closed:<id>", "notes:seen:<id>".
]]
function ChangeNotesLogic.metricKey(action: ParsedAction): string
	if action.verb == "shown" then
		return `notes:shown:{action.id}:{action.source or "menu"}`
	end
	return `notes:{action.verb}:{action.id}`
end

--[[
	The "time open" histogram label for `seconds` (ChangeNotesConfig.OpenBuckets / Labels).
	Example: openBucket(3) --> "lt5"; openBucket(61) --> "gt60"
]]
function ChangeNotesLogic.openBucket(seconds: number): string
	local labels = ChangeNotesConfig.OpenBucketLabels
	for index, bound in ChangeNotesConfig.OpenBuckets do
		if seconds < bound then
			return labels[index]
		end
	end
	return labels[#labels]
end

--[[
	Client: the seen id from the profile snapshot's `notes` field (untyped; "" when absent, e.g.
	a server without the field, or malformed).
	Example: readSeen(ClientState.profile and ClientState.profile.notes) --> "2026-10-31-..."
]]
function ChangeNotesLogic.readSeen(raw: unknown): string
	if type(raw) ~= "table" then
		return ""
	end
	local seen = (raw :: { [string]: unknown }).seen
	return if ChangeNotesConfig.isIdShape(seen) then seen :: string else ""
end

--[[
	Client: the note the auto pop-up should open at `now`, or nil. Only when a visible note is
	unseen and the pop-up has not already been attempted (`attempted`): once per join, plus once
	more for a note revealed mid-session (ChangeNotesClient re-arms the attempt at a reveal).
]]
function ChangeNotesLogic.autoNote(seen: string, attempted: boolean, now: number): ChangeNotesConfig.Note?
	if attempted or not ChangeNotesLogic.hasUnseen(seen, now) then
		return nil
	end
	return ChangeNotesConfig.newestVisible(now)
end

return table.freeze(ChangeNotesLogic)
