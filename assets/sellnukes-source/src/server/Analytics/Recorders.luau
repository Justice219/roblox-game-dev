--!strict
--[[
	Recorders — the gameplay analytics API other server systems call (through AnalyticsService):
	generic allowlisted family recorders, typed tycoon helpers that also drive the new-player
	funnel / first-day milestones / time-to-X, and the cash / gem economy hook.

	Generic recorders (KeySpec-validated; undocumented keys are refused and counted as core
	"ops:badKey:<family>"):
		record(family, player?, key, amount?)    family ∈ AnalyticsConfig.RecorderFamilies
		tycoon / worlds / retention / pets / crates / attack / event / social (player?, key, amount?)
	A key's first part may carry side effects (AnalyticsConfig.KeyHooks): a unique-per-day surface
	(core "uniq:<surface>") and a first-day milestone (core "cohort:<milestone>").

	Typed tycoon helpers (B5 TycoonService / PlotService / Offline / Rebirth call these):
		plotAssigned(player, plotIndex)                       plot:<i>, funnel plotReady
		padBought(player, padId, skipped?)                    pad / padKind / padArea / first-run
		                                                      time-to-pad / manager / feature /
		                                                      unlock → areaReached, funnel steps
		producerClick(player, producerId)                     clicks, funnel firstClick
		producerIncome(player, producerId, amount, automated) click vs automated income share
		producerUpgraded(player, producerId, from, to, mode?) levels, level marks, funnel
		areaReached(player, area)                             area / first-run time-to-area
		rebirthed(player, rebirthsAfter, tokens)              run length, rebirth tiers
		offlinePaid(player, seconds, cash) / offlineDoubled(player)
		tutorialStep(player, step, done?)
	World routing (owner R57): padBought / producerClick / producerIncome / producerUpgraded accept
	ANY world's ids (WorldsConfig: a1_… / d3_…, p1_… / dp3_…). Nuke Town ids keep the exact
	behaviour above; an extra world's ids go to Server/Analytics/WorldRecorders (world-scoped
	first run, worlds padArea / incomeW, the world funnel; no Nuke Town new-player funnel).
	Typed pets / crates helpers: eggHatched(player, eggId, results, auto?),
	crateOpened(player, crateId, payWith, rewards).
	Economy: currencyChanged(player, currency, delta, reason, balance) — PlayerDataService hook.
	Currencies = AnalyticsConfig.Economy.Currencies (incl. each extra world's "bones" / "amber");
	unmapped earnings of an extra world's currency are batched like cash (WorldRecorders).

	Every recorder: never throws (Runtime.guard), never yields, New Player Mode → core "npm:*",
	staff on live servers → core "staff:*". Hot paths (clicks, income, currency) are O(1) after
	their first call per session (memoized key strings, per-session "already marked" flags).

	Connects to: Runtime, Recorder, KeySpec, WorldRecorders, AnalyticsConfig (KeyHooks, Tycoon,
	Economy), TycoonConfig (pads / producers), Worlds/WorldsConfig (world of an id), Sessions (none),
	ServerHealth (systemTime).

	Example:
		AnalyticsService.padBought(player, "a1_tool_wall")
		AnalyticsService.pets(player, "hatch:BasicEgg")
		AnalyticsService.retention(player, "daily:claim:3")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
local AnalyticsLogic = require(script.Parent.AnalyticsLogic)
local KeySpec = require(script.Parent.KeySpec)
local Recorder = require(script.Parent.Recorder)
local Runtime = require(script.Parent.Runtime)
local WorldRecorders = require(script.Parent.WorldRecorders)

local Recorders = {}

local count = Recorder.count
local guard = Runtime.economyGuard
local tycoonConfig = AnalyticsConfig.Tycoon

local RECORDER_FAMILY: { [string]: boolean } = {}
for _, family in AnalyticsConfig.RecorderFamilies do
	RECORDER_FAMILY[family] = true
end

-- Per-session flags of the hot recorders (cleared with the session table by weak keys).
type HotState = { clickDay: number, cashSeen: boolean, upgradeSeen: boolean, areas: { [number]: boolean } }
local hot: { [any]: HotState } = setmetatable({}, { __mode = "k" }) :: any

-- The hot state of the player's CURRENT session (nil without a session).
local function hotOf(player: Player): HotState?
	local info = Runtime.sessions[player]
	if info == nil then
		return nil
	end
	local state = hot[info]
	if state == nil then
		state = { clickDay = -1, cashSeen = false, upgradeSeen = false, areas = {} }
		hot[info] = state
	end
	return state
end

-- A finite amount (default 1), or nil for anything else (NaN / inf / non-number).
local function amountOf(raw: unknown): number?
	if raw == nil then
		return 1
	end
	if type(raw) ~= "number" or raw ~= raw or raw == math.huge or raw == -math.huge then
		return nil
	end
	return raw
end

--[[
	The generic allowlisted recorder (no guard: the public wrappers add it).
	@return true when counted
]]
local function recordKey(family: string, player: Player?, rawKey: unknown, rawAmount: unknown): boolean
	if not RECORDER_FAMILY[family] then
		count("core", "ops:badKey:family")
		return false
	end
	local amount = amountOf(rawAmount)
	local metric, why = KeySpec.check(family, rawKey)
	if metric == nil or amount == nil then
		count("core", `ops:badKey:{family}`)
		Recorder.warn(`badKey:{family}`, `refused {family} key {tostring(rawKey)} ({why or "amount"})`)
		return false
	end
	count(family, metric, amount)
	local hooks = AnalyticsConfig.KeyHooks[family]
	if hooks ~= nil and player ~= nil then
		local head = string.match(metric, "^[^:]+") :: string
		local hook = hooks[head]
		if hook ~= nil then
			if hook.unique ~= nil then
				Runtime.markUnique(player, hook.unique)
			end
			if hook.firstDay ~= nil then
				Runtime.markFirstDay(player, hook.firstDay)
			end
		end
	end
	return true
end
Recorders.recordKey = recordKey

--[[
	Generic recorder: `family` must be a recorder family and `key` a documented pattern.
	Example: Recorders.record("attack", player, "launch:revenge")
]]
Recorders.record = guard("record", function(family: string, player: Player?, key: string, amount: number?)
	recordKey(family, Runtime.asPlayer(player), key, amount)
end)

-- One guarded wrapper per recorder family: (player?, key, amount?).
local function familyRecorder(family: string): (player: Player?, key: string, amount: number?) -> ()
	return guard(family, function(player: Player?, key: string, amount: number?)
		recordKey(family, Runtime.asPlayer(player), key, amount)
	end)
end
Recorders.tycoon = familyRecorder("tycoon")
Recorders.worlds = familyRecorder("worlds")
Recorders.retention = familyRecorder("retention")
Recorders.pets = familyRecorder("pets")
Recorders.crates = familyRecorder("crates")
Recorders.attack = familyRecorder("attack")
Recorders.event = familyRecorder("event")
Recorders.social = familyRecorder("social")

--[[ Registers the validator of an id kind (see KeySpec.register). ]]
function Recorders.registerIds(kind: string, isValid: (id: string) -> boolean): boolean
	return KeySpec.register(kind, isValid)
end

--------------------------------------------------------------------------------------------------
-- Tycoon
--------------------------------------------------------------------------------------------------

--[[
	The EXTRA world (not Nuke Town) an id belongs to, or nil (a Nuke Town id, an unknown id or a
	non-string). `lookup` = WorldsConfig.worldOfPad / worldOfProducer.
]]
local function extraWorldOf(lookup: (id: unknown) -> string?, id: unknown): WorldsConfig.WorldDef?
	local worldId = lookup(id)
	if worldId == nil or worldId == WorldsConfig.MAIN then
		return nil
	end
	return WorldsConfig.get(worldId)
end

-- First run = no rebirth yet: the pacing metrics compare against TycoonConfig.Pacing.
local function firstRun(player: Player): boolean
	return Runtime.rebirthsOf(player) == 0
end

-- Funnel steps / first-day milestones per area reached.
local AREA_STEP: { [number]: string } = { [2] = "area2", [3] = "area3", [4] = "area4", [5] = "area5" }

--[[ The player was given plot `plotIndex` (1..8). ]]
Recorders.plotAssigned = guard("plotAssigned", function(player: Player, plotIndex: number)
	local index = AnalyticsLogic.integerIn(plotIndex, 1, AnalyticsConfig.Social.MaxPlayers)
	if index ~= nil then
		count("tycoon", `plot:{index}`)
	end
	Runtime.markFtue(player, "plotReady")
end)

--[[
	A tycoon area opened for the player (deduped per session per run). First-run reaches add the
	play seconds into the run (time-to-area vs TycoonConfig.Pacing).
]]
local function reachArea(player: Player, area: number)
	local n = AnalyticsLogic.integerIn(area, 1, #TycoonConfig.Areas)
	if n == nil then
		count("core", "ops:badKey:tycoon")
		return
	end
	local state = hotOf(player)
	if state ~= nil then
		if state.areas[n] then
			return
		end
		state.areas[n] = true
	end
	count("tycoon", `area:{n}`)
	if firstRun(player) then
		local seconds = Runtime.runSeconds(player)
		count("tycoon", `areaN:{n}`)
		count("tycoon", `areaAt:{n}`, math.floor(seconds))
		count("tycoon", `areaB:{n}:{AnalyticsLogic.bucketOf(seconds / 60, tycoonConfig.AreaMinuteBuckets, "m")}`)
	end
	local step = AREA_STEP[n]
	if step ~= nil then
		Runtime.markFtue(player, step)
		Runtime.markFirstDay(player, step)
	end
	local live = Runtime.livePlayer(player)
	if live ~= nil then
		Runtime.forwarder.progression(live, "Area", n)
	end
end

--[[ An area opened (usually through its Unlock pad, which padBought forwards here). ]]
Recorders.areaReached = guard("areaReached", function(player: Player, area: number)
	reachArea(player, area)
end)

--[[
	A pad was bought (after the purchase is applied). `skipped` = bought with the Skip Pad product.
	Unlock pads also report the area they open; Manager / Feature pads count their target.
]]
Recorders.padBought = guard("padBought", function(player: Player, padId: string, skipped: boolean?)
	local pad = if type(padId) == "string" then TycoonConfig.PadsById[padId] else nil
	if pad == nil then
		local world = extraWorldOf(WorldsConfig.worldOfPad, padId)
		if world ~= nil then
			WorldRecorders.padBought(player, world, padId, skipped)
		else
			count("core", "ops:badKey:tycoon")
		end
		return
	end
	count("tycoon", `pad:{padId}`)
	count("tycoon", `padKind:{pad.kind}`)
	count("tycoon", `padArea:{pad.area}`)
	if skipped == true then
		count("tycoon", `padSkip:{padId}`)
	end
	if firstRun(player) then
		count("tycoon", `padN:{padId}`)
		count("tycoon", `padAt:{padId}`, math.floor(Runtime.runSeconds(player)))
	end
	Runtime.markFtue(player, "firstPad")
	local index = TycoonConfig.PadIndex[padId] or 0
	if index >= 5 then
		Runtime.markFtue(player, "pad5")
		Runtime.markFirstDay(player, "pad5")
	end
	local live = Runtime.livePlayer(player)
	if live ~= nil then
		Runtime.forwarder.custom(live, "PadBought", 1, padId, tostring(pad.area))
	end
	if pad.kind == "Manager" then
		local target = pad.target
		if type(target) == "string" and TycoonConfig.ProducersById[target] ~= nil then
			count("tycoon", `manager:{target}`)
		end
		Runtime.markFtue(player, "manager")
		Runtime.markFirstDay(player, "manager")
		if live ~= nil then
			Runtime.forwarder.custom(live, "ManagerHired", 1, padId)
		end
	end
	local feature = pad.feature
	if type(feature) == "string" and TycoonConfig.FeaturePadOf[feature] ~= nil then
		count("tycoon", `feature:{feature}`)
	end
	if pad.kind == "Unlock" then
		local unlocks = pad.unlocks
		if type(unlocks) == "number" then
			reachArea(player, unlocks)
		end
	end
end)

-- Memoized per-producer income keys (producer ids are a fixed config set).
local incomeKeys: { [string]: { click: string, auto: string } } = {}
local clickKeys: { [string]: string } = {}

--[[ A producer cycle was started by a click (manual production). ]]
Recorders.producerClick = guard("producerClick", function(player: Player, producerId: string)
	local metric = clickKeys[producerId]
	if metric == nil then
		if type(producerId) ~= "string" or TycoonConfig.ProducersById[producerId] == nil then
			local world = extraWorldOf(WorldsConfig.worldOfProducer, producerId)
			if world ~= nil then
				WorldRecorders.producerClick(player, world, producerId)
			else
				count("core", "ops:badKey:tycoon")
			end
			return
		end
		metric = `click:{producerId}`
		clickKeys[producerId] = metric
	end
	count("tycoon", "clicks")
	count("tycoon", metric)
	local state = hotOf(player)
	local today = Recorder.today()
	if state ~= nil and state.clickDay ~= today then
		state.clickDay = today
		Runtime.markFtue(player, "firstClick")
		Runtime.markFirstDay(player, "click")
		Runtime.markUnique(player, "click")
	end
end)

--[[
	A producer paid out (each cycle, or a batch of cycles). `automated` = the producer has its
	Manager (idle income) vs a clicked cycle. Feeds the click vs automated income share.
]]
Recorders.producerIncome = guard(
	"producerIncome",
	function(player: Player, producerId: string, amount: number, automated: boolean)
		if type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount == math.huge then
			return
		end
		local keys = incomeKeys[producerId]
		if keys == nil then
			if type(producerId) ~= "string" or TycoonConfig.ProducersById[producerId] == nil then
				local world = extraWorldOf(WorldsConfig.worldOfProducer, producerId)
				if world ~= nil then
					WorldRecorders.producerIncome(world, producerId, amount, automated)
				else
					count("core", "ops:badKey:tycoon")
				end
				return
			end
			keys = { click = `incomeP:{producerId}:click`, auto = `incomeP:{producerId}:auto` }
			incomeKeys[producerId] = keys
		end
		if automated == true then
			count("tycoon", "income:auto", amount)
			count("tycoon", keys.auto, amount)
		else
			count("tycoon", "income:click", amount)
			count("tycoon", keys.click, amount)
		end
		local state = hotOf(player)
		if state ~= nil and not state.cashSeen then
			state.cashSeen = true
			Runtime.markFtue(player, "firstCash")
		end
	end
)

--[[
	A producer was upgraded from `fromLevel` to `toLevel` (one purchase, possibly many levels).
	`mode` = the bulk mode ("1" | "10" | "max"). Counts every level mark crossed.
]]
Recorders.producerUpgraded = guard(
	"producerUpgraded",
	function(player: Player, producerId: string, fromLevel: number, toLevel: number, mode: string?)
		if type(producerId) ~= "string" or TycoonConfig.ProducersById[producerId] == nil then
			local world = extraWorldOf(WorldsConfig.worldOfProducer, producerId)
			if world ~= nil then
				WorldRecorders.producerUpgraded(world, producerId, fromLevel, toLevel, mode)
			else
				count("core", "ops:badKey:tycoon")
			end
			return
		end
		local from = AnalyticsLogic.integerIn(fromLevel, 0, TycoonConfig.MaxLevel)
		local to = AnalyticsLogic.integerIn(toLevel, 0, TycoonConfig.MaxLevel)
		if from == nil or to == nil or to <= from then
			count("core", "ops:badKey:tycoon")
			return
		end
		count("tycoon", `upgrade:{producerId}`)
		count("tycoon", `levels:{producerId}`, to - from)
		if mode ~= nil and table.find(tycoonConfig.UpgradeModes, mode) ~= nil then
			count("tycoon", `upgradeMode:{mode}`)
		end
		for _, mark in tycoonConfig.LevelMarks do
			if from < mark and mark <= to then
				count("tycoon", `lvl:{producerId}:{mark}`)
			end
		end
		local state = hotOf(player)
		if state ~= nil and not state.upgradeSeen then
			state.upgradeSeen = true
			Runtime.markFtue(player, "firstUpgrade")
			Runtime.markFirstDay(player, "upgrade")
		end
	end
)

--[[
	The player rebirthed: `rebirthsAfter` = their rebirth count now, `tokens` = Rebirth Tokens
	granted. Records the finished run's length and starts a new run clock.
]]
Recorders.rebirthed = guard("rebirthed", function(player: Player, rebirthsAfter: number, tokens: number?)
	local after = AnalyticsLogic.integerIn(rebirthsAfter, 1, 1e9)
	if after == nil then
		count("core", "ops:badKey:tycoon")
		return
	end
	local runSeconds = Runtime.runSeconds(player)
	count("tycoon", "rebirth")
	count("tycoon", `rebirthN:{AnalyticsLogic.countBucket(after, tycoonConfig.RebirthBuckets)}`)
	count("tycoon", "rebirthSec", math.floor(runSeconds))
	count("tycoon", `runB:{AnalyticsLogic.bucketOf(runSeconds / 60, tycoonConfig.RunMinuteBuckets, "m")}`)
	if type(tokens) == "number" and tokens == tokens and tokens > 0 and tokens < 1e15 then
		count("tycoon", "rebirthTokens", tokens)
	end
	-- New run: its clock starts now; areas can be reached again.
	local data, profile = Runtime.dataOf(player)
	if data ~= nil and Runtime.canMark(player, profile) then
		data.runAt = math.floor(Runtime.playSeconds(player))
		Runtime.saveMarks(player)
	end
	local state = hotOf(player)
	if state ~= nil then
		table.clear(state.areas)
	end
	Runtime.markFtue(player, "firstRebirth")
	Runtime.markFirstDay(player, "rebirth")
	Runtime.markUnique(player, "rebirth")
	local live = Runtime.livePlayer(player)
	if live ~= nil then
		Runtime.forwarder.progression(live, "Rebirth", after)
	end
end)

--[[ An offline payout on join (`seconds` credited, `cash` paid). ]]
Recorders.offlinePaid = guard("offlinePaid", function(_player: Player, seconds: number, cash: number)
	if type(seconds) ~= "number" or seconds ~= seconds or seconds <= 0 or seconds > 1e7 then
		return
	end
	count("tycoon", "offline:pay")
	count("tycoon", "offlineSec", math.floor(seconds))
	count("tycoon", `offlineB:{AnalyticsLogic.bucketOf(seconds / 3600, tycoonConfig.OfflineHourBuckets, "h")}`)
	if type(cash) == "number" and cash == cash and cash > 0 and cash ~= math.huge then
		count("tycoon", "offlineCash", cash)
		count("tycoon", "income:offline", cash)
	end
end)

--[[ The offline payout was doubled with the DOUBLE IT! product. ]]
Recorders.offlineDoubled = guard("offlineDoubled", function(_player: Player)
	count("tycoon", "offline:double")
end)

--[[ The server tutorial advanced to `step` (once per step per session); `done` = completed. ]]
Recorders.tutorialStep = guard("tutorialStep", function(player: Player, step: number, done: boolean?)
	local info = Runtime.sessions[player]
	local n = AnalyticsLogic.integerIn(step, 1, tycoonConfig.MaxTutorialStep)
	if info == nil or n == nil then
		return
	end
	if not info.tutSteps[n] then
		info.tutSteps[n] = true
		count("tycoon", `tut:{n}`)
	end
	if done == true and not info.tutSteps[0] then
		info.tutSteps[0] = true
		count("tycoon", "tutDone")
	end
end)

--------------------------------------------------------------------------------------------------
-- Pets and crates (typed conveniences over the generic recorders)
--------------------------------------------------------------------------------------------------

export type HatchResult = { petId: string, rarity: string }

--[[
	An egg hatch request succeeded: `results` = the pets rolled (1 or 3), `auto` = auto-hatch.
	Example: Recorders.eggHatched(player, "BasicEgg", { { petId = "GlowSlime", rarity = "Common" } })
]]
Recorders.eggHatched = guard(
	"eggHatched",
	function(player: Player, eggId: string, results: { HatchResult }, auto: boolean?)
		if type(results) ~= "table" or #results < 1 then
			return
		end
		local n = math.min(#results, 3)
		if not recordKey("pets", player, `hatch:{eggId}`, n) then
			return
		end
		recordKey("pets", player, `hatchN:{eggId}:{if n >= 3 then 3 else 1}`, nil)
		if auto == true then
			recordKey("pets", player, "hatchAuto", nil)
		end
		local best = ""
		local bestIndex = 0
		for index = 1, n do
			local result = results[index]
			if type(result) == "table" and type(result.rarity) == "string" and type(result.petId) == "string" then
				recordKey("pets", player, `rarity:{result.rarity}`, nil)
				recordKey("pets", player, `eggRarity:{eggId}:{result.rarity}`, nil)
				recordKey("pets", player, `pet:{result.petId}`, nil)
				local rank = table.find(AnalyticsConfig.Pets.Rarities, result.rarity) or 0
				if rank > bestIndex then
					best, bestIndex = result.rarity, rank
				end
			end
		end
		local live = Runtime.livePlayer(player)
		if live ~= nil then
			Runtime.forwarder.custom(
				live,
				"EggHatched",
				n,
				AnalyticsLogic.part(eggId),
				if best ~= "" then best else nil
			)
		end
	end
)

export type CrateReward = { kind: string, rarity: string? }

--[[
	A supply crate opened: `payWith` = "gems" | "robux" | "free", `rewards` = what it gave.
	Example: Recorders.crateOpened(player, "SupplyCrate", "gems", { { kind = "boost", rarity = "Rare" } })
]]
Recorders.crateOpened = guard(
	"crateOpened",
	function(player: Player, crateId: string, payWith: string, rewards: { CrateReward }?)
		if not recordKey("crates", player, `open:{crateId}`, nil) then
			return
		end
		recordKey("crates", player, `openPay:{crateId}:{payWith}`, nil)
		if type(rewards) == "table" then
			for index = 1, math.min(#rewards, 10) do
				local reward = rewards[index]
				if type(reward) == "table" and type(reward.kind) == "string" then
					recordKey("crates", player, `reward:{crateId}:{reward.kind}`, nil)
					if type(reward.rarity) == "string" then
						recordKey("crates", player, `rarity:{reward.rarity}`, nil)
					end
				end
			end
		end
		local live = Runtime.livePlayer(player)
		if live ~= nil then
			Runtime.forwarder.custom(live, "CrateOpened", 1, AnalyticsLogic.part(crateId), AnalyticsLogic.part(payWith))
		end
	end
)

--------------------------------------------------------------------------------------------------
-- Economy (PlayerDataService.CurrencyChanged)
--------------------------------------------------------------------------------------------------

-- Creator Dashboard currency names ("bones" → "Bones"; every booked currency has one).
local CURRENCY_NAME: { [string]: string } = AnalyticsConfig.Economy.CurrencyNames
-- Memoized key sets per currency + reason id, bounded per currency and direction (MaxReasons).
type ReasonKeys = { earn: string, nEarn: string, spend: string, nSpend: string, transaction: string? }
local reasonKeys: { [string]: { [string]: ReasonKeys } } = {}
local reasonCount: { [string]: number } = {}

-- A bounded reason id: the leading letters of the reason ("Admin:123" → "Admin"), ≤ MaxKeyPart.
local function reasonId(reason: unknown): string
	if type(reason) ~= "string" then
		return "other"
	end
	local head = string.match(reason, "^%a+")
	if head == nil then
		return "other"
	end
	return string.sub(head, 1, AnalyticsConfig.MaxKeyPart)
end

-- The Roblox transaction type of a reason: exact id, then its leading capitalised word.
local function transactionOf(reason: string): string?
	local types = AnalyticsConfig.Economy.TransactionTypes
	local exact = types[reason]
	if exact ~= nil then
		return exact
	end
	local word = string.match(reason, "^%u%l*")
	return if word ~= nil then types[word] else nil
end

-- The memoized keys of (currency, reason); "other" past MaxReasons distinct reasons.
local function keysOf(currency: string, rawReason: unknown): ReasonKeys
	local byReason = reasonKeys[currency]
	if byReason == nil then
		byReason = {}
		reasonKeys[currency] = byReason
	end
	local reason = reasonId(rawReason)
	local keys = byReason[reason]
	if keys ~= nil then
		return keys
	end
	local n = reasonCount[currency] or 0
	if n >= AnalyticsConfig.Economy.MaxReasons then
		reason = "other"
		keys = byReason.other
		if keys ~= nil then
			return keys
		end
	else
		reasonCount[currency] = n + 1
	end
	keys = {
		earn = `earn:{currency}:{reason}`,
		nEarn = `n:earn:{currency}:{reason}`,
		spend = `spend:{currency}:{reason}`,
		nSpend = `n:spend:{currency}:{reason}`,
		transaction = transactionOf(reason),
	}
	byReason[reason] = keys
	return keys
end

--[[
	A currency changed (every grant > 0 / spend < 0). Counts the economy family by reason and
	mirrors to Roblox's economy dashboard: mapped reasons one by one (rate-limited), unmapped cash
	EARNINGS batched into one Source per player per flush.
]]
Recorders.currencyChanged = guard(
	"currencyChanged",
	function(player: Player, currency: string, delta: number, reason: string, balance: number)
		if type(delta) ~= "number" or delta ~= delta or delta == 0 or delta == math.huge or delta == -math.huge then
			return
		end
		if type(currency) ~= "string" or CURRENCY_NAME[currency] == nil then
			return
		end
		local keys = keysOf(currency, reason)
		local live = Runtime.livePlayer(player)
		local ending = if type(balance) == "number" and balance == balance then balance else 0
		if delta > 0 then
			count("economy", `earn:{currency}`, delta)
			count("economy", keys.earn, delta)
			count("economy", keys.nEarn)
			if live ~= nil then
				if keys.transaction ~= nil then
					Runtime.forwarder.economy(
						live,
						"Source",
						CURRENCY_NAME[currency],
						delta,
						ending,
						keys.transaction,
						nil
					)
				elseif currency == "cash" then
					local info = Runtime.sessions[live]
					if info ~= nil then
						info.incomeBatch = math.min(1e300, info.incomeBatch + delta)
					end
				elseif not WorldRecorders.batchIncome(live, currency, delta) then
					-- Anything else unmapped goes one by one (an extra world's currency, "bones",
					-- was batched above and is forwarded once per flush by Sessions).
					Runtime.forwarder.economy(live, "Source", CURRENCY_NAME[currency], delta, ending, "Gameplay", nil)
				end
			end
		else
			local spent = -delta
			count("economy", `spend:{currency}`, spent)
			count("economy", keys.spend, spent)
			count("economy", keys.nSpend)
			if live ~= nil then
				Runtime.forwarder.economy(
					live,
					"Sink",
					CURRENCY_NAME[currency],
					spent,
					ending,
					keys.transaction or "Shop",
					nil
				)
			end
		end
	end
)

return table.freeze(Recorders)
