--!strict
--[[
	NotifyConfig — tunables of the RETURN NOTIFICATIONS (owner R122 §2.3, docs/retention.md
	"Return notifications").

	Purpose:
		When a player leaves, the server plans at most ONE Roblox experience notification for them
		(Roblox allows one per user per experience per day) and puts it in a MemoryStore due queue.
		Every server polls the queue once a minute, claims due entries atomically (exactly one
		server sends each) and sends them with Open Cloud CreateUserNotification through
		HttpService (API key = an experience SECRET, never in this file). The tap brings the
		player back with launch data "rn:<kind>", which analytics attributes.

	Kinds (priority order = KindOrder; the first one that applies is planned):
		cashFull   offline earnings reach their cap: due = leave + the player's offline cap
		           (only with automated income and a cap of at least MinCapHours)
		streak     the player claimed today's Daily reward: the next one unlocks tomorrow (UTC);
		           due = tomorrow at the hour this player usually starts, at least
		           MinAfterLeaveHours after leaving, before the streak would break
		missions   fallback: AfterLeaveHours after leaving, never before the next UTC day's
		           daily-mission reset (+ ResetSlackSeconds)
		Per kind: messageId (the notification string's asset id from the Creator Dashboard; EMPTY
		= that kind is off), text (what the owner types into the dashboard; documentation + the
		admin preview, Roblox renders the dashboard copy), params (the {name} placeholders the
		string uses; every one must be supplied), maxLateHours (a claim later than this after the
		due time is dropped: "rnotify:drop:late"), category (analyticsData.category in the
		Creator Dashboard notification analytics).

	Dashboard setup (docs/retention.md "Owner steps"):
		Kinds.<kind>.messageId     the three notification string asset ids, created 2026-11-01
		SecretName                 the experience secret that holds the Open Cloud API key
		                           (scope user.user-notification:write, universe UniverseId)

	Dry run: Studio, or a live server without the secret, runs everything (plan, queue, claim,
	payload build + validation, analytics "rnotify:result:dry" / "nokey") except the HTTP request.

	Security: shared + read-only. The API key is NEVER here (HttpService:GetSecret on the server
	only). Message ids / the universe id are not secrets. The request URL is fixed (Url below,
	user id substituted as a validated integer).

	Connects to: Server/Retention/{ReturnNotifyLogic, ReturnNotifyService, ReturnNotifyQueue,
	ReturnNotifySender, ReturnNotifyControl, ReturnNotifyAdmin}, Shared/Config/{AdminConfig
	(Notify* commands), AnalyticsConfig (rnotify:* keys, NotifyLaunchData)},
	Client/UI/Screens/{NotifyPrompt (opt-in moments), Admin/NotifySection}, tests/return-notify*.luau.

	Example:
		local def = NotifyConfig.Kinds.streak
		print(def.messageId ~= "", def.maxLateHours) --> true 3
		print(NotifyConfig.launchData("streak")) --> "rn:streak"
]]

export type Kind = "cashFull" | "streak" | "missions"

export type KindDef = {
	id: Kind,
	label: string, -- admin panel name
	messageId: string, -- Creator Dashboard notification string asset id ("" = kind off)
	text: string, -- the copy the owner creates in the dashboard (<= 99 characters)
	params: { string }, -- {placeholder} names the string uses (values built by the server)
	maxLateHours: number, -- drop a claim this many hours after its due time
	category: string, -- analyticsData.category
}

local NotifyConfig = {}

-- Code-level master switch (false = nothing is planned, polled or sent; the admin kill switch is
-- the runtime one and reaches every server).
NotifyConfig.Enabled = true

-- Sell Nukes universe (Creator Dashboard → the experience). Open Cloud `source.universe`.
NotifyConfig.UniverseId = 10773845696

-- Name of the experience secret (Creator Dashboard → Secrets) holding the Open Cloud API key.
NotifyConfig.SecretName = "SellNukesNotifyKey"

-- The ONLY URL the sender ever requests (%d = the recipient's validated user id).
NotifyConfig.Url = "https://apis.roblox.com/cloud/v2/users/%d/notifications"

-- Launch data = Prefix .. kind (Roblox caps launch data at 200 bytes).
NotifyConfig.LaunchPrefix = "rn:"
NotifyConfig.MaxLaunchDataBytes = 200

-- Roblox notification string limit (characters) — the docs' 99.
NotifyConfig.MaxTextChars = 99

-- Only notify players who reported an opt-in (profile.notify.claimed). false = every leaver
-- (Roblox itself delivers only to opted-in users aged 13+; non-delivered sends cost nothing).
NotifyConfig.OptedInOnly = false
-- A session shorter than this plans nothing unless the player has reported an opt-in (a
-- sub-minute bounce never saw the opt-in card).
NotifyConfig.MinSessionSeconds = 60

-- Priority order (first applicable kind wins).
NotifyConfig.KindOrder = table.freeze({ "cashFull", "streak", "missions" } :: { Kind })

NotifyConfig.Kinds = table.freeze({
	cashFull = table.freeze({
		id = "cashFull" :: Kind,
		label = "Factory full",
		messageId = "69dbd79b-5308-924f-96bd-8559db8ae66f",
		text = "Your nuke factory is full! Come collect your cash!",
		params = table.freeze({}),
		maxLateHours = 6,
		category = "rn_cashFull",
	}) :: KindDef,
	streak = table.freeze({
		id = "streak" :: Kind,
		label = "Daily streak",
		messageId = "31d33d80-7cd8-b34c-8b86-8dc056f9e575",
		text = "Day {day} reward is ready - keep your streak!",
		params = table.freeze({ "day" }),
		maxLateHours = 3,
		category = "rn_streak",
	}) :: KindDef,
	missions = table.freeze({
		id = "missions" :: Kind,
		label = "Daily missions",
		messageId = "2418369b-d35f-754a-bffd-3a1beac68bb5",
		text = "New daily missions + Nuke Pass XP are waiting!",
		params = table.freeze({}),
		maxLateHours = 8,
		category = "rn_missions",
	}) :: KindDef,
}) :: { [Kind]: KindDef }

-- Planning rules (hours / seconds after the player LEFT).
NotifyConfig.Plan = table.freeze({
	-- cashFull: only when the offline cap is at least this long (a short cap = nothing to call
	-- them back for).
	MinCapHours = 1,
	-- streak: at least this long after leaving; must land this many minutes before the streak breaks.
	MinAfterLeaveHours = 16,
	StreakDeadlineMarginMinutes = 60,
	-- missions: this long after leaving, and never before the next UTC mission reset + slack.
	AfterLeaveHours = 20,
	ResetSlackSeconds = 600,
	-- Usual start hour: weight of the stored hour when blending in this session's start hour.
	UsualHourKeep = 0.7,
})

-- MemoryStore due queue (SortedMap; key = userId, sort key = due unix time).
NotifyConfig.Queue = table.freeze({
	MapName = "SellNukesReturnNotify_v1",
	-- Roblox maximum is 45 days; this queue never keeps an item longer than this.
	MaxExpirationSeconds = 2 * 86400,
	-- Seconds between polls on every server (+ up to PollJitterSeconds random so servers spread).
	PollSeconds = 60,
	PollJitterSeconds = 10,
	-- Entries read per poll (Roblox max 200; each returned item costs one request unit).
	BatchSize = 20,
	-- A claim hides the entry this long (sort key pushed); a server that dies mid-send frees it.
	LeaseSeconds = 120,
	-- Roblox: one notification per user per experience per day. A new plan is never due within
	-- this many hours of the user's last send (the "sent" marker carries the time).
	SendGapHours = 24,
	-- A join writes a marker so a plan from a server the player just LEFT (written late) is
	-- skipped; the marker lives this long (unless it carries a send time).
	JoinMarkerSeconds = 300,
	-- The join re-checks the queue once after this many seconds (a slow plan write elsewhere).
	JoinRecheckSeconds = 60,
	-- A retried entry (429 / 5xx / transport error) comes back after RetryBaseSeconds × 2^(n-1);
	-- at most MaxAttempts sends per entry.
	RetryBaseSeconds = 300,
	MaxAttempts = 3,
	-- Seconds a finished entry without a send time stays as a marker before it expires.
	DoneTtlSeconds = 60,
	-- Largest stored value accepted back from the queue (bytes of JSON, defensive).
	MaxValueBytes = 1024,
	-- Admin status: due entries counted at most (one request unit each).
	StatusScan = 200,
	-- BindToClose waits at most this long for plan writes still in flight (players leaving at
	-- shutdown still get their plan).
	CloseWaitSeconds = 5,
})

-- Sender (Open Cloud through HttpService).
NotifyConfig.Send = table.freeze({
	-- Per-server token bucket for sends (dry runs included).
	Burst = 10,
	PerSecond = 0.5,
	-- Concurrent requests per server.
	MaxInFlight = 4,
	-- The poll loop stops waiting for one request after this many seconds (the request thread
	-- still finishes the entry when the answer comes).
	TimeoutSeconds = 12,
	-- Server back-off after 429 / 5xx / transport errors: Base × 2^(n-1), capped at Max (a
	-- Retry-After header up to Max wins when larger); reset by a success.
	BackoffBaseSeconds = 2,
	BackoffMaxSeconds = 300,
	-- 401 / 403 (bad key or scope): this server stops sending this long.
	KeyBackoffSeconds = 600,
	-- A missing secret is looked up again after this many seconds.
	SecretRetrySeconds = 300,
	-- Response body bytes parsed at most (error code for the admin status).
	MaxBodyBytes = 4096,
	-- Recent results kept for the admin status (ring).
	RecentResults = 6,
})

-- Universe-wide admin control (kill switch + per-kind switches): DataStore + MessagingService.
NotifyConfig.Control = table.freeze({
	StoreName = "SellNukesReturnNotifyCtl_v1",
	StoreKey = "control",
	Topic = "SellNukesReturnNotifyCtl_v1",
	PollSeconds = 90,
	MaxWireBytes = 512,
})

-- ReplicatedStorage attributes (display only: the admin panel's notifications section).
NotifyConfig.Attributes = table.freeze({
	On = "ReturnNotifyOn", -- boolean: the universe kill switch state this server runs
	KindsOff = "ReturnNotifyKindsOff", -- "cashFull,streak" = kinds switched off ("" = none)
	Version = "ReturnNotifyVersion", -- number: control version (ms)
})

-- Opt-in card moments (Client/UI/Screens/NotifyPrompt; owner R122 §2.3 "Opt-in reach").
NotifyConfig.Prompt = table.freeze({
	-- Seconds after the first manager hire / reaching area 2 before the card asks for its turn.
	MomentDelaySeconds = 2.5,
	-- Returning players (manager + area 2 already done at join): the card asks after this long.
	FallbackDelaySeconds = 180,
	-- Every other session: if no moment showed the card by this long after the profile loaded,
	-- it asks once anyway ("other"; the pre-R122 8-minute suggestion as a floor).
	LateFallbackSeconds = 480,
	-- Seconds a moment may wait for a calm screen (popup queue maxWait / fallback loop), plus the
	-- slack after which a queued request that never answered is given up.
	MaxWaitSeconds = 90, -- = PopupQueueConfig.Kinds.notifyPrompt.maxWait
	WaitSlackSeconds = 5,
	-- The popup-queue slot is released when the card closes; this only caps a card left open.
	MaxShowSeconds = 600,
	-- Fallback loop (when the popup queue has no notifyPrompt kind): check interval, and how
	-- many calm checks in a row before it opens.
	CheckSeconds = 1,
	CalmChecks = 2,
	-- The popup queue kind the card uses (Shared/Config/PopupQueueConfig.Kinds).
	QueueKind = "notifyPrompt",
})

-- Analytics moments for "rnotify:promptAt:<moment>".
NotifyConfig.PromptMoments = table.freeze({ "manager", "area2", "other" })

-- Studio only: a kind whose message id is still empty dry-runs with this placeholder, so the
-- whole pipeline (plan → queue → claim → payload) can still be verified when a kind has no id.
NotifyConfig.StudioPlaceholderId = "studio-dry-run"

--[[
	The kind table a server runs: the config itself on live servers; in Studio a copy whose empty
	message ids are StudioPlaceholderId (Studio never sends a request, so no placeholder ever
	reaches Roblox).
	@param isStudio boolean
	@return { [Kind]: KindDef }
	Example: NotifyConfig.kindsFor(true).streak.messageId --> NotifyConfig.Kinds.streak.messageId
]]
function NotifyConfig.kindsFor(isStudio: boolean): { [Kind]: KindDef }
	if not isStudio then
		return NotifyConfig.Kinds
	end
	local kinds: { [Kind]: KindDef } = {}
	for kind, def in NotifyConfig.Kinds do
		local copy: KindDef = table.clone(def)
		if copy.messageId == "" then
			copy.messageId = NotifyConfig.StudioPlaceholderId
		end
		kinds[kind] = (table.freeze(copy) :: any) :: KindDef
	end
	return table.freeze(kinds)
end

--[[
	The launch data a notification of `kind` carries ("rn:<kind>").
	@param kind Kind
	@return string
	Example: NotifyConfig.launchData("cashFull") --> "rn:cashFull"
]]
function NotifyConfig.launchData(kind: Kind): string
	return NotifyConfig.LaunchPrefix .. kind
end

--[[
	The kind named by a join's launch data, or nil (exact "rn:<kind>" match only; anything else,
	including other games' / hand-made launch data, is ignored).
	@param launchData unknown — Player:GetJoinData().LaunchData (untrusted)
	@return Kind?
	Example: NotifyConfig.kindFromLaunchData("rn:streak") --> "streak"
]]
function NotifyConfig.kindFromLaunchData(launchData: unknown): Kind?
	if type(launchData) ~= "string" or #launchData > NotifyConfig.MaxLaunchDataBytes then
		return nil
	end
	for _, kind in NotifyConfig.KindOrder do
		if launchData == NotifyConfig.launchData(kind) then
			return kind
		end
	end
	return nil
end

--[[
	True when `kind` is a known kind id.
	Example: NotifyConfig.isKind("streak") --> true
]]
function NotifyConfig.isKind(kind: unknown): boolean
	return type(kind) == "string" and NotifyConfig.Kinds[kind :: Kind] ~= nil
end

--[[
	True when a message id has the shape of a Creator Dashboard asset id (letters, digits and
	dashes, 1..64 characters). "" (not filled in yet) is not valid.
	Example: NotifyConfig.isMessageId("5dd7024b-68e3-ac4d-8232-4217f86ca244") --> true
]]
function NotifyConfig.isMessageId(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= 64 and string.find(value, "^[%w%-]+$") ~= nil
end

--[[
	Self-check of every tunable (tests/return-notify.luau). Empty message ids are allowed (the
	owner fills them in); a non-empty one must have the asset-id shape.
	@return { string } problems (empty = fine)
]]
function NotifyConfig.validate(): { string }
	local problems: { string } = {}
	local function positive(label: string, value: number)
		if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
			table.insert(problems, `{label} must be a positive finite number`)
		end
	end
	if
		type(NotifyConfig.UniverseId) ~= "number"
		or NotifyConfig.UniverseId <= 0
		or NotifyConfig.UniverseId % 1 ~= 0
	then
		table.insert(problems, "UniverseId must be a positive integer")
	end
	if type(NotifyConfig.SecretName) ~= "string" or string.find(NotifyConfig.SecretName, "^[%a][%w_]*$") == nil then
		table.insert(problems, "SecretName must be a plain identifier")
	end
	if string.sub(NotifyConfig.Url, 1, 28) ~= "https://apis.roblox.com/clou" then
		table.insert(problems, "Url must be the fixed Open Cloud endpoint")
	end
	local seen: { [string]: boolean } = {}
	for _, kind in NotifyConfig.KindOrder do
		local def = NotifyConfig.Kinds[kind]
		if def == nil then
			table.insert(problems, `KindOrder names unknown kind {kind}`)
			continue
		end
		seen[kind] = true
		if def.id ~= kind then
			table.insert(problems, `{kind}: id mismatch`)
		end
		if def.messageId ~= "" and not NotifyConfig.isMessageId(def.messageId) then
			table.insert(problems, `{kind}: messageId must be an asset id (letters, digits, dashes)`)
		end
		if utf8.len(def.text) == nil or (utf8.len(def.text) :: number) > NotifyConfig.MaxTextChars then
			table.insert(problems, `{kind}: text must be <= {NotifyConfig.MaxTextChars} characters`)
		end
		for _, param in def.params do
			local placeholder = "{" .. param .. "}"
			if string.find(def.text, placeholder, 1, true) == nil then
				table.insert(problems, `{kind}: text has no {placeholder} placeholder`)
			end
		end
		positive(`{kind}.maxLateHours`, def.maxLateHours)
		if string.find(def.category, "^[%w_]+$") == nil or #def.category > 64 then
			table.insert(problems, `{kind}: category must be [A-Za-z0-9_] (<= 64)`)
		end
		if #NotifyConfig.launchData(kind) > NotifyConfig.MaxLaunchDataBytes then
			table.insert(problems, `{kind}: launch data too long`)
		end
	end
	for kind in NotifyConfig.Kinds do
		if not seen[kind] then
			table.insert(problems, `{kind} is missing from KindOrder`)
		end
	end
	for key, value in NotifyConfig.Plan :: { [string]: number } do
		positive(`Plan.{key}`, value)
	end
	if NotifyConfig.Plan.UsualHourKeep >= 1 then
		table.insert(problems, "Plan.UsualHourKeep must be below 1")
	end
	for key, value in NotifyConfig.Queue :: { [string]: any } do
		if type(value) == "number" then
			positive(`Queue.{key}`, value)
		end
	end
	if NotifyConfig.Queue.MaxExpirationSeconds > 3888000 then
		table.insert(problems, "Queue.MaxExpirationSeconds exceeds Roblox's 45 days")
	end
	if NotifyConfig.Queue.BatchSize > 200 or NotifyConfig.Queue.StatusScan > 200 then
		table.insert(problems, "Queue.BatchSize / StatusScan exceed GetRangeAsync's 200")
	end
	if NotifyConfig.Queue.LeaseSeconds <= NotifyConfig.Send.TimeoutSeconds then
		table.insert(problems, "Queue.LeaseSeconds must exceed Send.TimeoutSeconds")
	end
	for key, value in NotifyConfig.Send :: { [string]: number } do
		positive(`Send.{key}`, value)
	end
	if NotifyConfig.Send.BackoffBaseSeconds > NotifyConfig.Send.BackoffMaxSeconds then
		table.insert(problems, "Send.BackoffBaseSeconds must not exceed BackoffMaxSeconds")
	end
	positive("Control.PollSeconds", NotifyConfig.Control.PollSeconds)
	positive("Control.MaxWireBytes", NotifyConfig.Control.MaxWireBytes)
	for key, value in NotifyConfig.Prompt :: { [string]: any } do
		if type(value) == "number" then
			positive(`Prompt.{key}`, value)
		end
	end
	return problems
end

return table.freeze(NotifyConfig)
