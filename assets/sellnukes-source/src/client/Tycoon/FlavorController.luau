--!strict
--[[
	FlavorController — the client of owner R89's Surprise Batches + Big Pop (spec §1). It only
	DISPLAYS what the server decided; every roll, multiplier and broadcast is server-side
	(Server/Tycoon/FlavorService + BigPop).

	Remotes → effects (every payload is validated: types, lengths, known flavour ids, tagged anchors)
		FlavorPop (unreliable, owner)     → Fx/FlavorPops: income-pop tint, flavour word, sparkle
		                                    + the feed rule below (Sprinkle .. Rainbow)
		FlavorGlow (unreliable, world)    → Fx/FlavorGlow: soft light + sparkles over that producer
		FlavorHighlight (reliable, owner) → the feed rule below for Galaxy+ (it carries the payout)
		BigPop (reliable, all)            → one system chat line per entry (TextChatService
		                                    RBXSystem) + toy fireworks at each entry's spot
		                                    (Fx/Fireworks; Reduce Motion: a sparkle burst) + OTHER
		                                    players' entries as ONE small bottom-left pill per
		                                    Feed.Flavor.BigPopGap (30 s, the rest coalesced "+N";
		                                    batches Galaxy+ only; Fx/BigPopBanner)
	Feed rule (owner R120: "these popups are real annoying bro ngl"; pure FlavorFeedLogic): no
		Lucky Nuke ever shows centre-screen. Besides its income pop, each one shows AT MOST:
		- the bottom-left REVEAL card (UI/Screens/FlavorReveal) for the FIRST find of that flavour in
		  that world (the Flavour Book had no entry), at most once per Feed.Flavor.CardCooldown
		  (5 min); it carries the Book claim line, so the server's identical discovery toast is
		  dropped (Toasts.suppress); a first find inside the cooldown shows only that toast,
		- else ONE small bottom-left pill "GALAXY nukes x20 +$31.8M" (flavour colour; same-flavour
		  pills inside Feed.Flavor.MergeSeconds merge: "GALAXY x3 +$95M"),
		- nothing more for the quiet commons (Sprinkle, Glitter) after their first find.
	Reveal gate (the card): never during a tutorial step (Tycoon/Tutorial.step() > 0), a menu
		(ScreenManager.anyModalOpen), a cinematic (ScreenManager.isFocusMode: egg hatch, attack
		target, launch cam, loading) or the plot reveal. A blocked card waits (one pending, the
		rarest kept) up to Reveal.HoldSeconds, re-checked every half second by ONE delayed task
		chain; then it is dropped (its discovery toast already told the player).
	Popup queue (owner R102): the card opens through UI/Widgets/PopupQueue's centre lane (kind
		"flavorReveal": it pre-empts a juice / Happy Hour banner, which comes back after it, and
		holds the lane until the screen closes); since owner R108 it is a card at the bottom of the
		bottom-left feed (no letterbox, no HUD fade).
	Words (owner R112 "Lucky Nukes"): FlavorConfig.Text / bigPopLine / revealLines — never "batch".
	Chat lines are plain DisplayName + config labels, with every rich-text character escaped.

	Boot: controller contract Init() / Start() (init.client.luau "Tycoon/FlavorController", after
	the juice pass). Connects to: Shared/Net/Remotes, Shared/Config/{FlavorConfig, PopupQueueConfig,
	Worlds/WorldsConfig}, Client/ClientState (the Flavour Book), Tycoon/{FlavorFeedLogic, Tutorial,
	PlotReveal, ProducerBillboards, WorldLookup, Fx/{FlavorPops, FlavorGlow, BigPopBanner,
	Fireworks, Confetti, FxQuality, JuiceRules}}, UI/{ScreenManager, Hud/Toasts,
	Widgets/{OfferFx, PopupQueue}}.

	Example (Studio probe): require(Client.Tycoon.FlavorController).preview("galaxy")
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local Workspace = game:GetService("Workspace")

local BigPopBanner = require(script.Parent.Fx.BigPopBanner)
local ClientState = require(script.Parent.Parent.ClientState)
local Confetti = require(script.Parent.Fx.Confetti)
local Fireworks = require(script.Parent.Fx.Fireworks)
local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local FlavorFeedLogic = require(script.Parent.FlavorFeedLogic)
local FlavorGlow = require(script.Parent.Fx.FlavorGlow)
local FlavorPops = require(script.Parent.Fx.FlavorPops)
local FxQuality = require(script.Parent.Fx.FxQuality)
local JuiceConfig = require(ReplicatedStorage.Shared.Config.JuiceConfig)
local JuiceRules = require(script.Parent.Fx.JuiceRules)
local OfferFx = require(script.Parent.Parent.UI.Widgets.OfferFx)
local PlotReveal = require(script.Parent.PlotReveal)
local PopupQueue = require(script.Parent.Parent.UI.Widgets.PopupQueue)
local PopupQueueConfig = require(ReplicatedStorage.Shared.Config.PopupQueueConfig)
local ProducerBillboards = require(script.Parent.ProducerBillboards)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local Toasts = require(script.Parent.Parent.UI.Hud.Toasts)
local Tutorial = require(script.Parent.Tutorial)
local WorldLookup = require(script.Parent.WorldLookup)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local FlavorController = {}

local localPlayer = Players.LocalPlayer

-- One validated Big Pop entry (BigPopBanner.Entry + the fireworks spot).
type WireEntry = {
	name: string,
	kind: string,
	id: string,
	label: string,
	oneIn: number,
	at: Vector3?,
	userId: number?,
}

local REVEAL_SCREEN = "FlavorReveal"
local PRODUCER_TAG = "SNProducer" -- PlotBuilder.Tags.Producer (client contract)
local MAX_ENTRIES = 5
local Reveal = FlavorConfig.Reveal
local BigPopCfg = FlavorConfig.BigPop

local started = false
-- Remote events handled since boot (QA probes / Studio captures read FlavorController.stats()).
local counters = { pops = 0, glows = 0, highlights = 0, reveals = 0, pills = 0, bigPops = 0, bigPopPills = 0 }
-- Owner R120 feed state (card cooldown, first-find guard, Big Pop gap / coalescing).
local feed = FlavorFeedLogic.new()
local Rules = PopupQueueConfig.Feed.Flavor
local bigPopFlushToken = 0
local pendingReveal: { [string]: any }? = nil
local pendingAt = 0
local pendingRank = 0
local chainRunning = false
-- The PopupQueue slot of the reveal on screen (released when the screen closes).
local revealHandle: PopupQueue.Handle? = nil
-- Seconds past Reveal.Seconds the queue waits before it ends a reveal that never closed itself.
local REVEAL_SLACK = 3

--------------------------------------------------------------------------------------------------
-- Validation helpers
--------------------------------------------------------------------------------------------------

-- A short string field (1..max characters) or nil.
local function str(value: unknown, max: number): string?
	if type(value) ~= "string" or #(value :: string) < 1 or #(value :: string) > max then
		return nil
	end
	return value :: string
end

-- A finite number in [min, max] or nil.
local function num(value: unknown, min: number, max: number): number?
	if type(value) ~= "number" or value ~= value or (value :: number) < min or (value :: number) > max then
		return nil
	end
	return value :: number
end

--------------------------------------------------------------------------------------------------
-- Reveal gate
--------------------------------------------------------------------------------------------------

-- True when nothing important is on screen (see the header).
local function canReveal(): boolean
	return Tutorial.step() == 0
		and not ScreenManager.anyModalOpen()
		and not ScreenManager.isFocusMode()
		and not PlotReveal.isPlaying()
		and not ScreenManager.isOpen(REVEAL_SCREEN)
end

-- True when the player's Flavour Book (profile.flavors.found) already lists "<world>:<flavour>".
local function bookHas(worldId: string, flavorId: string): boolean
	local profile: any = ClientState.profile
	local book = if type(profile) == "table" then profile.flavors else nil
	local found = if type(book) == "table" then book.found else nil
	return type(found) == "table" and found[`{worldId}:{flavorId}`] ~= nil
end

-- The server's discovery toast for (flavour, world) — built exactly like FlavorService does.
local function discoveryText(def: FlavorConfig.FlavorDef, worldId: string): string
	local world = WorldsConfig.get(worldId)
	return string.format(
		FlavorConfig.Text.DiscoveryToast,
		string.upper(def.name),
		if world ~= nil then world.name else worldId,
		def.gems
	)
end

-- One small bottom-left pill for a Lucky Nuke; same flavour + world pills merge (owner R120).
local function pill(def: FlavorConfig.FlavorDef, worldId: string, amount: number)
	counters.pills += 1
	local function amountText(total: number): string?
		return if total > 0 then WorldLookup.label(worldId, total) else nil
	end
	Toasts.pushPill({
		text = FlavorFeedLogic.pillText(def, 1, amountText(amount)),
		color = def.ui,
		icon = "Nuke",
		seconds = Rules.PillSeconds,
		group = "flavor",
		mergeId = `flavor:{worldId}:{def.id}`,
		mergeSeconds = Rules.MergeSeconds,
		amount = amount,
		build = function(count: number, total: number): string
			return FlavorFeedLogic.pillText(def, count, amountText(total))
		end,
	})
end

-- The queue's extra gate for the reveal (menus / cinematics are its kind's own gates).
local function revealAllowed(): boolean
	return Tutorial.step() == 0 and not PlotReveal.isPlaying()
end

-- Opens the first-find card through PopupQueue's centre lane (see the header). When it really
-- appears: the 5-minute cooldown starts and the duplicate discovery toast is dropped.
local function openReveal(data: { [string]: any })
	local previous = revealHandle
	if previous ~= nil then
		revealHandle = nil
		previous.done()
	end
	local def = FlavorConfig.byId(data.flavor)
	local handle = PopupQueue.request({
		kind = "flavorReveal",
		maxShow = Reveal.Seconds + REVEAL_SLACK,
		canShow = revealAllowed,
		show = function(): boolean
			ScreenManager.open(REVEAL_SCREEN, data)
			local opened = ScreenManager.isOpen(REVEAL_SCREEN)
			if opened then
				counters.reveals += 1
				FlavorFeedLogic.cardShown(feed, os.clock())
				if def ~= nil and type(data.claim) == "string" then
					Toasts.suppress(data.claim, Rules.DiscoverySuppress)
				end
			end
			return opened
		end,
		hide = function(reason: string)
			-- Studio QA (tools/qa/flavors.py, popup_queue.py) keeps a DebugHold reveal up past the
			-- cap and closes it itself; never live.
			local gui = ScreenManager.getGui(REVEAL_SCREEN)
			if
				reason == "timeout"
				and RunService:IsStudio()
				and gui ~= nil
				and gui:GetAttribute("DebugHold") == true
			then
				return
			end
			ScreenManager.close(REVEAL_SCREEN)
		end,
	})
	revealHandle = handle
end

-- Plays the pending card when allowed; re-checks every 0.5 s while one waits (one chain). A card
-- blocked past Reveal.HoldSeconds is dropped (the discovery toast already told the player).
local function tryReveal()
	local data = pendingReveal
	if data == nil then
		chainRunning = false
		return
	end
	if os.clock() - pendingAt > Reveal.HoldSeconds then
		pendingReveal, pendingRank = nil, 0
		chainRunning = false
		return
	end
	if canReveal() then
		pendingReveal, pendingRank = nil, 0
		chainRunning = false
		openReveal(data)
		return
	end
	chainRunning = true
	task.delay(0.5, tryReveal)
end

-- Queues the first-find card (one pending: the rarest kept while the chain runs).
local function queueCard(data: { [string]: any }, rank: number)
	if pendingReveal ~= nil then
		if rank > pendingRank then
			pendingReveal, pendingRank = data, rank
		end
		return
	end
	pendingReveal, pendingRank, pendingAt = data, rank, os.clock()
	if not chainRunning then
		tryReveal()
	end
end

-- One Lucky Nuke of the local player (owner R120 feed rule; see the header).
local function luckyNuke(def: FlavorConfig.FlavorDef, data: { [string]: any })
	local worldId: string = data.worldId
	local decision = FlavorFeedLogic.decide(feed, {
		flavorId = def.id,
		worldId = worldId,
		found = bookHas(worldId, def.id),
		now = os.clock(),
	})
	if decision == "card" then
		data.claim = discoveryText(def, worldId)
		queueCard(data, def.rank)
	elseif decision == "pill" then
		pill(def, worldId, data.amount)
	end
end

-- FlavorHighlight: a Galaxy+ batch on one of your producers (it carries the payout + odds).
local function onHighlight(payload: unknown)
	if type(payload) ~= "table" then
		return
	end
	local raw = payload :: { [string]: unknown }
	local producerId = str(raw.producerId, 32)
	local def = FlavorConfig.byId(raw.flavor)
	if producerId == nil or def == nil or not def.reveal then
		return
	end
	counters.highlights += 1
	luckyNuke(def, {
		producerId = producerId,
		flavor = def.id,
		worldId = WorldLookup.normalize(str(raw.worldId, 16) or "main"),
		oneIn = num(raw.oneIn, 1, 1e12) or def.oneIn,
		mult = def.mult,
		amount = num(raw.amount, 0, 1e300) or 0,
	})
end

--------------------------------------------------------------------------------------------------
-- Big Pop
--------------------------------------------------------------------------------------------------

-- Escapes rich-text markup characters (chat lines are rich text).
local function escape(text: string): string
	return (
		string.gsub(text, "[&<>\"']", {
			["&"] = "&amp;",
			["<"] = "&lt;",
			[">"] = "&gt;",
			['"'] = "&quot;",
			["'"] = "&apos;",
		})
	)
end

-- One system chat line (no-op without TextChatService's default channels).
local function systemLine(text: string)
	pcall(function()
		local channels = TextChatService:FindFirstChild("TextChannels")
		local system = if channels ~= nil then channels:FindFirstChild("RBXSystem") else nil
		if system ~= nil and system:IsA("TextChannel") then
			system:DisplaySystemMessage(text)
		end
	end)
end

-- Toy fireworks over an entry's spot (only near the camera; Reduce Motion: a sparkle burst).
local function fireworksAt(at: Vector3)
	local camera = Workspace.CurrentCamera
	if camera == nil or (camera.CFrame.Position - at).Magnitude > BigPopCfg.FireworksRange then
		return
	end
	local tier = FxQuality.tier()
	local sparks = JuiceRules.perTier(JuiceConfig.Fireworks.Sparks, tier)
	local ground = at - Vector3.new(0, 3, 0)
	if OfferFx.reducedMotion() then
		Confetti.burst(at + Vector3.new(0, JuiceConfig.Fireworks.Height * 0.6, 0), 0, sparks)
		return
	end
	local rockets = math.max(1, math.floor(BigPopCfg.Rockets * (if tier == "Low" then 0.5 else 1)))
	Fireworks.show(ground, rockets, sparks)
end

-- Releases the coalesced Big Pop pill when its gap is over (one delayed task, re-armed).
local function scheduleBigPopFlush()
	local at = FlavorFeedLogic.nextBigPopAt(feed)
	bigPopFlushToken += 1
	if at == nil then
		return
	end
	local mine = bigPopFlushToken
	task.delay(math.max(0, at - os.clock()) + 0.05, function()
		if mine ~= bigPopFlushToken then
			return
		end
		local show, folded = FlavorFeedLogic.flushBigPop(feed, os.clock())
		if show ~= nil then
			counters.bigPopPills += 1
			BigPopBanner.show(show :: any, folded)
		end
		scheduleBigPopFlush()
	end)
end

-- BigPop: a server-wide broadcast (banner + chat lines + fireworks).
local function onBigPop(payload: unknown)
	if type(payload) ~= "table" then
		return
	end
	local raw = payload :: { [string]: unknown }
	local list = raw.entries
	if type(list) ~= "table" then
		return
	end
	local entries: { WireEntry } = {}
	for index, value in list :: { unknown } do
		if index > MAX_ENTRIES or type(value) ~= "table" then
			break
		end
		local item = value :: { [string]: unknown }
		local name = str(item.name, 40)
		local kind = str(item.kind, 8)
		local id = str(item.id, 24)
		local label = str(item.label, 48)
		if name == nil or id == nil or label == nil or (kind ~= "batch" and kind ~= "hatch" and kind ~= "rebirth") then
			continue
		end
		table.insert(entries, {
			name = name,
			kind = kind :: string,
			id = id,
			label = label,
			oneIn = num(item.oneIn, 0, 1e12) or 0,
			at = if typeof(item.at) == "Vector3" then item.at :: Vector3 else nil,
			userId = num(item.userId, 1, 2 ^ 53),
		})
	end
	if #entries == 0 then
		return
	end
	counters.bigPops += 1
	local more = math.floor(num(raw.more, 0, 1e6) or 0)
	-- Chat: one line per entry (owner R112 wording, odds included), then the folded count.
	local Text = FlavorConfig.Text
	for _, entry in entries do
		local text = escape(BigPopBanner.line(entry))
		systemLine(`<font color="{BigPopCfg.SystemColor}"><b>{escape(Text.BigPopChatPrefix)}</b> {text}</font>`)
	end
	if more > 0 then
		systemLine(`<font color="{BigPopCfg.SystemColor}">{escape(string.format(Text.BigPopMore, more))}</font>`)
	end
	-- Fireworks at every entry's spot (near the camera only).
	for _, entry in entries do
		if entry.at ~= nil then
			fireworksAt(entry.at)
		end
	end
	-- The pill (owner R120): OTHER players only (your own Lucky Nuke already has its pill / card),
	-- batches Galaxy+ only, at most one per Feed.Flavor.BigPopGap — the rest coalesce ("+N").
	local others: { FlavorFeedLogic.BigPopEntry } = {}
	for _, entry in entries do
		local def = if entry.kind == "batch" then FlavorConfig.byId(entry.id) else nil
		local mine = entry.userId ~= nil and entry.userId == localPlayer.UserId
		if not mine and (entry.kind ~= "batch" or (def ~= nil and def.reveal)) then
			table.insert(others, entry)
		end
	end
	local show, folded = FlavorFeedLogic.bigPop(feed, others, more, os.clock())
	if show ~= nil then
		counters.bigPopPills += 1
		BigPopBanner.show(show :: any, folded)
	end
	scheduleBigPopFlush()
end

--------------------------------------------------------------------------------------------------
-- Pops + glows
--------------------------------------------------------------------------------------------------

-- FlavorPop: a flavoured batch on one of your producers.
local function onPop(payload: unknown)
	if type(payload) ~= "table" then
		return
	end
	local raw = payload :: { [string]: unknown }
	local producerId = str(raw.producerId, 32)
	local def = FlavorConfig.byId(raw.flavor)
	local count = num(raw.count, 1, 1e9)
	if producerId == nil or def == nil or def.rank < 1 or count == nil then
		return
	end
	counters.pops += 1
	FlavorPops.show(producerId, def, math.floor(count))
	-- Galaxy+ go through FlavorHighlight (payout + odds); the rest follow the feed rule here.
	if not def.reveal then
		local worldId = WorldLookup.normalize(str(raw.worldId, 16) or (WorldLookup.producer(producerId)))
		luckyNuke(def, {
			producerId = producerId,
			flavor = def.id,
			worldId = worldId,
			oneIn = def.oneIn,
			mult = def.mult,
			-- Optional (FlavorService may send it): the flavoured payout of the batch.
			amount = num(raw.amount, 0, 1e300) or 0,
		})
	end
end

-- FlavorGlow: a Rainbow+ batch on any producer in your world.
local function onGlow(payload: unknown)
	if type(payload) ~= "table" then
		return
	end
	local raw = payload :: { [string]: unknown }
	local anchor = raw.anchor
	local def = FlavorConfig.byId(raw.flavor)
	if def == nil or not def.glow or typeof(anchor) ~= "Instance" then
		return
	end
	local part = anchor :: Instance
	if not part:IsA("BasePart") or not CollectionService:HasTag(part, PRODUCER_TAG) then
		return
	end
	counters.glows += 1
	FlavorGlow.show(part :: BasePart, def)
end

--------------------------------------------------------------------------------------------------
-- Lifecycle + probes
--------------------------------------------------------------------------------------------------

--[[
	Studio / QA probe: plays the local look of `flavorId` on your first own producer (pop, glow and
	the first-find reveal card, forced past its cooldown) without any server roll. Cosmetic only.
	@param flavorId string
	@return boolean — true when something played
]]
function FlavorController.preview(flavorId: string): boolean
	local def = FlavorConfig.byId(flavorId)
	local record = ProducerBillboards.ownRecords()[1]
	if def == nil or def.rank < 1 or record == nil then
		return false
	end
	FlavorPops.show(record.id, def, 1)
	if def.glow then
		FlavorGlow.show(record.anchor, def)
	end
	-- The first-find card, forced (no cooldown, no Book check): QA captures of the card.
	queueCard({
		producerId = record.id,
		flavor = def.id,
		worldId = record.worldId,
		oneIn = def.oneIn,
		mult = def.mult,
		amount = 1250000,
		claim = discoveryText(def, record.worldId),
	}, def.rank)
	return true
end

--[[ Studio / QA probe: one feed pill of `flavorId` (merges like live ones). ]]
function FlavorController.previewPill(flavorId: string, amount: number?): boolean
	local def = FlavorConfig.byId(flavorId)
	local record = ProducerBillboards.ownRecords()[1]
	if def == nil or def.rank < 1 or record == nil then
		return false
	end
	pill(def, record.worldId, amount or 31800000)
	return true
end

--[[ Studio / QA probe: plays a Big Pop broadcast locally (banner, chat line, fireworks). ]]
function FlavorController.previewBigPop(payload: { [string]: any })
	onBigPop(payload)
end

--[[ Remote events handled since boot + live glows (QA probes). ]]
function FlavorController.stats(): { [string]: number }
	local out = table.clone(counters)
	out.liveGlows = FlavorGlow.live()
	return out
end

function FlavorController.Init() end

function FlavorController.Start()
	if started then
		return
	end
	started = true
	-- The reveal closed (its timer, SKIP, or the queue): free the centre lane for the next popup.
	ScreenManager.Closed:Connect(function(name: string)
		local handle = revealHandle
		if name == REVEAL_SCREEN and handle ~= nil then
			revealHandle = nil
			handle.done()
		end
	end)
	task.spawn(function()
		Remotes.unreliable("FlavorPop").OnClientEvent:Connect(onPop)
		Remotes.unreliable("FlavorGlow").OnClientEvent:Connect(onGlow)
		Remotes.event("FlavorHighlight").OnClientEvent:Connect(onHighlight)
		Remotes.event("BigPop").OnClientEvent:Connect(onBigPop)
	end)
end

return FlavorController
