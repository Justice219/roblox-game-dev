--!strict
--[[
	WorldSections — the WORLDS part of the analytics report (owner R57 World 2; spec §12 "Admin
	Analytics tab: a WORLDS section ... COPY FOR AI includes it"). Pure: no services, no yields.
	ReportSections.build calls `build(out, ctx)` right after the tycoon tables, so the admin
	Analytics tab shows these as section buttons and AnalyticsReport.toText (COPY FOR AI) prints
	them with every other table.

	Tables (each only when the range holds its counters; one set per EXTRA world, in
	WorldsConfig.Order):
		worlds                 Worlds · overview — per world (Nuke Town included for time):
		                       unlocks, unique visitor-days, first visits, avg minutes per
		                       visitor-day, trips in, rebirths
		worldFunnel_<w>        <World> · funnel — unlocked → firstTravel → firstPad → manager →
		                       area2 … → finale → rebirth (players, % of unlocked, step-to-step)
		worldPacing_<w>        <World> · area pacing (first run) — avg minutes into the world's
		                       first run when each area opened vs the world's Pacing targets, pads
		                       bought per area
		worldEntry_<w>         <World> · unlock popup & travel — popup shown / GO NOW / LATER /
		                       locked preview, locked-portal uses, trips by source, refusals
		worldMoney_<w>         <World> · rebirths, eggs & Robux — rebirths (+ count tiers), Amber
		                       granted / shop, currency earned / spent, income share, offline
		                       payouts, the world's egg hatches, the world's product revenue
		worldPerf              Worlds · client performance — avg fps / frame p95 / memory per
		                       world (health "perfW:<world>:*", the server-known world)
	Currency sources / sinks by reason ("Sources: bones", "Sinks: amber", ...) come from the
	generic economy tables (AnalyticsConfig.Economy.Currencies includes every world currency).

	Connects to: ReportSections (caller), AnalyticsLogic (makeTable, pctOf, Entry), AnalyticsReport
	(formatting), AnalyticsConfig (Worlds, Tycoon), Worlds/WorldsConfig (names, pacing, eggs),
	MonetizationConfig (world products), ClientPerfConfig / ClientPerfLogic (frame buckets),
	tests/analytics-report.luau.

	Example:
		WorldSections.build(out, ctx)   -- appends the WORLDS tables to `out`
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
local AnalyticsReport = require(ReplicatedStorage.Shared.Analytics.AnalyticsReport)
local ClientPerfConfig = require(ReplicatedStorage.Shared.Analytics.ClientPerfConfig)
local ClientPerfLogic = require(ReplicatedStorage.Shared.Analytics.ClientPerfLogic)
local AnalyticsLogic = require(script.Parent.AnalyticsLogic)

type Counters = AnalyticsLogic.Counters
type Entry = AnalyticsLogic.Entry
type Table = AnalyticsReport.Table
type Ctx = AnalyticsLogic.SectionContext
type WorldDef = WorldsConfig.WorldDef

local WorldSections = {}

local makeTable = AnalyticsLogic.makeTable
local pctOf = AnalyticsLogic.pctOf
local formatInteger = AnalyticsReport.formatInteger
local formatPercent = AnalyticsReport.formatPercent
local worldsConfig = AnalyticsConfig.Worlds

-- One decimal ("12.3").
local function oneDecimal(value: number): string
	return tostring(math.floor(value * 10 + 0.5) / 10)
end

-- Big currency sums as short text ("1.2M"; sums reach 1e300).
local function shortNumber(value: number): string
	local magnitude = math.abs(value)
	if magnitude < 1e6 then
		return formatInteger(value)
	end
	local suffixes = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
	local exponent = math.floor(math.log10(magnitude) / 3)
	if exponent <= #suffixes then
		return `{oneDecimal(value / 10 ^ (exponent * 3))}{suffixes[exponent]}`
	end
	return string.format("%.2e", value)
end

-- Adds `section` when it has rows.
local function push(out: { Table }, section: Table)
	if #section.rows > 0 or (section.more or 0) > 0 then
		table.insert(out, section)
	end
end

-- Sum of every counter whose key starts with `prefix`.
local function sumPrefix(counters: Counters, prefix: string): number
	local total = 0
	for key, value in counters do
		if string.sub(key, 1, #prefix) == prefix then
			total += value
		end
	end
	return total
end

-- Products (dev products) that belong to a world (MonetizationConfig `world` field), in order.
local function worldProducts(worldId: string): { string }
	local keys: { string } = {}
	for _, key in MonetizationConfig.ProductOrder do
		local product = MonetizationConfig.getProduct(key)
		if product ~= nil and product.world == worldId then
			table.insert(keys, key)
		end
	end
	return keys
end

--------------------------------------------------------------------------------------------------
-- Overview
--------------------------------------------------------------------------------------------------

local function overview(out: { Table }, worlds: Counters)
	local entries: { Entry } = {}
	for _, worldId in WorldsConfig.Order do
		local def = WorldsConfig.get(worldId)
		if def == nil then
			continue
		end
		local seconds = worlds[`seconds:{worldId}`] or 0
		local visitors = worlds[`visitor:{worldId}`] or 0
		local unlocks = worlds[`unlock:{worldId}`] or 0
		local trips = sumPrefix(worlds, `travel:{worldId}:`)
		if seconds <= 0 and visitors <= 0 and unlocks <= 0 and trips <= 0 then
			continue
		end
		local parts: { string } = {}
		if worldId ~= WorldsConfig.MAIN then
			table.insert(parts, `{formatInteger(unlocks)} unlocks`)
			table.insert(parts, `{formatInteger(visitors)} visitor-days`)
			table.insert(parts, `{formatInteger(worlds[`firstVisit:{worldId}`] or 0)} first visits`)
			table.insert(
				parts,
				`avg {if visitors > 0 then oneDecimal(seconds / 60 / visitors) else "n/a"} min per visitor-day`
			)
			table.insert(parts, `{formatInteger(worlds[`rebirth:{worldId}`] or 0)} rebirths`)
		end
		table.insert(parts, `{formatInteger(trips)} trips in`)
		table.insert(entries, {
			id = worldId,
			label = def.name,
			value = math.floor(seconds / 60),
			display = `{formatInteger(math.floor(seconds / 60))} min`,
			extra = table.concat(parts, " · "),
		})
	end
	push(
		out,
		makeTable(
			"worlds",
			"Worlds · overview",
			"Player minutes spent in each world (worlds seconds:<world>, measured by the server). Extra worlds: "
				.. "unlocks, unique visitor-days (once per player per UTC day), first-ever visits, average minutes "
				.. "per visitor-day, rebirths and trips in (all sources).",
			entries,
			"given",
			#WorldsConfig.Order
		)
	)
end

--------------------------------------------------------------------------------------------------
-- Per extra world
--------------------------------------------------------------------------------------------------

-- unlocked → … → rebirth, with % of unlocked and the step-to-step conversion.
local function funnel(out: { Table }, worlds: Counters, def: WorldDef)
	local spec = worldsConfig.Funnels[def.id]
	if spec == nil then
		return
	end
	local base = worlds[`step:{def.id}:unlocked`] or 0
	local entries: { Entry } = {}
	local previous: number? = nil
	for _, step in spec.steps do
		local value = worlds[`step:{def.id}:{step}`] or 0
		local fromPrevious = if previous ~= nil and previous > 0 then formatPercent(value / previous) else "n/a"
		table.insert(entries, {
			id = step,
			label = step,
			value = value,
			extra = `{if base > 0 then pctOf(value, base) else "n/a"} of unlocked · {if previous == nil
				then "first step"
				else `{fromPrevious} of the step before`}`,
		})
		previous = value
	end
	if base <= 0 and (worlds[`step:{def.id}:firstTravel`] or 0) <= 0 then
		return
	end
	push(
		out,
		makeTable(
			`worldFunnel_{def.id}`,
			`{def.name} · funnel`,
			`Players reaching each step once (worlds step:{def.id}:<step>; mirrored to the Creator Dashboard funnel "{spec.name}"). `
				.. "Area / finale / manager / first pad steps count on the world's FIRST run only.",
			entries,
			"given",
			#entries
		)
	)
end

-- First-run minutes into the world's run when each area opened, vs its Pacing targets.
local function pacing(out: { Table }, worlds: Counters, def: WorldDef)
	local entries: { Entry } = {}
	local cumulative = 0
	local targets = def.economy.Pacing.TargetMinutes
	for index, area in def.economy.Areas do
		-- Target minutes to OPEN area n = the sum of the targets of areas 1..n-1.
		local target = cumulative
		cumulative += targets[index] or 0
		local reached = worlds[`area:{def.id}:{index}`] or 0
		local n = worlds[`areaN:{def.id}:{index}`] or 0
		local pads = worlds[`padArea:{def.id}:{index}`] or 0
		if reached <= 0 and n <= 0 and pads <= 0 then
			continue
		end
		local minutes = if n > 0 then (worlds[`areaAt:{def.id}:{index}`] or 0) / n / 60 else 0
		table.insert(entries, {
			id = tostring(index),
			label = `{index}. {area.name}`,
			value = n,
			display = if index == 1 then "start" elseif n > 0 then `{oneDecimal(minutes)} min` else "n/a",
			extra = `first-run reaches {n} · target {target} min ({if n > 0 and target > 0
				then formatPercent(minutes / target)
				else "n/a"} of target) · all-run reaches {reached} · {formatInteger(pads)} pads bought`,
		})
	end
	push(
		out,
		makeTable(
			`worldPacing_{def.id}`,
			`{def.name} · area pacing (first run)`,
			`Average minutes into the world's FIRST run (world-play clock) when each area opened (areaAt / areaN) vs the `
				.. `world's Pacing (cumulative target). >100% = slower than designed. Pads bought per area: padArea:{def.id}:<area>.`,
			entries,
			"given",
			#entries
		)
	)
end

-- The WORLD UNLOCKED popup funnel, locked-portal uses, trips by source and refusals.
local function entry(out: { Table }, worlds: Counters, def: WorldDef)
	local entries: { Entry } = {}
	local shown = worlds[`popup:{def.id}:shown`] or 0
	for _, action in worldsConfig.PopupActions do
		local value = worlds[`popup:{def.id}:{action}`] or 0
		if value > 0 then
			table.insert(entries, {
				id = `popup:{action}`,
				label = `popup {action}`,
				value = value,
				extra = if action ~= "shown"
						and action ~= "lockedPreview"
						and shown > 0
					then `{pctOf(value, shown)} of shown`
					else "",
			})
		end
	end
	local locked = worlds[`portalLocked:{def.id}`] or 0
	if locked > 0 then
		table.insert(entries, {
			id = "portalLocked",
			label = "locked portal used",
			value = locked,
			extra = "throttled per player",
		})
	end
	local trips = sumPrefix(worlds, `travel:{def.id}:`)
	for _, source in worldsConfig.TravelSources do
		local value = worlds[`travel:{def.id}:{source}`] or 0
		if value > 0 then
			table.insert(entries, {
				id = `travel:{source}`,
				label = `trip in by {source}`,
				value = value,
				extra = `{pctOf(value, trips)} of trips in`,
			})
		end
	end
	local refused = sumPrefix(worlds, `travelFail:{def.id}:`)
	for _, reason in worldsConfig.TravelReasons do
		local value = worlds[`travelFail:{def.id}:{reason}`] or 0
		if value > 0 then
			table.insert(entries, {
				id = `fail:{reason}`,
				label = `refused: {reason}`,
				value = value,
				extra = `{pctOf(value, refused)} of refusals`,
			})
		end
	end
	push(
		out,
		makeTable(
			`worldEntry_{def.id}`,
			`{def.name} · unlock popup & travel`,
			"WORLD UNLOCKED popup claims (capped per session; lockedPreview = the locked-portal version), locked "
				.. "portal uses, successful trips in by source and refused trips by TravelRules reason.",
			entries,
			"given",
			#entries
		)
	)
end

-- Rebirths, the tokens track, the world currency, eggs and the world's Robux products.
local function money(out: { Table }, ctx: Ctx, worlds: Counters, def: WorldDef)
	local economy: Counters = ctx.totals.economy or {}
	local revenue: Counters = ctx.totals.revenue or {}
	local pets: Counters = ctx.totals.pets or {}
	local entries: { Entry } = {}
	local function add(id: string, label: string, value: number, display: string?, extra: string?)
		if value > 0 then
			table.insert(entries, { id = id, label = label, value = value, display = display, extra = extra })
		end
	end
	local rebirths = worlds[`rebirth:{def.id}`] or 0
	local tiers: { string } = {}
	for _, label in AnalyticsLogic.countBucketLabels(AnalyticsConfig.Tycoon.RebirthBuckets) do
		local value = worlds[`rebirthN:{def.id}:{label}`] or 0
		if value > 0 then
			table.insert(tiers, `{label}: {formatInteger(value)}`)
		end
	end
	add("rebirths", "rebirths", rebirths, nil, `by count after: {table.concat(tiers, " · ")}`)
	add("tokens", `{def.tokens.name} granted`, worlds[`tokens:{def.id}`] or 0)
	for _, key in def.rebirth.ShopOrder do
		add(`shop:{key}`, `{def.tokens.name} shop: {key}`, worlds[`rebirthShop:{def.id}:{key}`] or 0)
	end
	local currency = def.currency.key
	local earned = economy[`earn:{currency}`] or 0
	local spent = economy[`spend:{currency}`] or 0
	add(
		"earned",
		`{def.currency.name} earned`,
		earned,
		shortNumber(earned),
		`spent {shortNumber(spent)} ({pctOf(spent, earned)}) · by reason: Sources / Sinks: {currency}`
	)
	local click = worlds[`incomeW:{def.id}:click`] or 0
	local auto = worlds[`incomeW:{def.id}:auto`] or 0
	local offline = worlds[`incomeW:{def.id}:offline`] or 0
	local produced = click + auto + offline
	add(
		"income",
		`{def.currency.name} produced`,
		produced,
		shortNumber(produced),
		`clicked {pctOf(click, produced)} · automated {pctOf(auto, produced)} · offline {pctOf(offline, produced)}`
	)
	local payouts = worlds[`offline:{def.id}:pay`] or 0
	add(
		"offline",
		"offline payouts",
		payouts,
		nil,
		`{formatInteger(worlds[`offline:{def.id}:double`] or 0)} doubled · avg {if payouts > 0
			then oneDecimal((worlds[`offlineSec:{def.id}`] or 0) / payouts / 3600)
			else "n/a"} h away`
	)
	for _, eggId in def.eggs do
		add(`egg:{eggId}`, `hatched: {eggId}`, pets[`hatch:{eggId}`] or 0)
	end
	for _, key in worldProducts(def.id) do
		local robux = revenue[`product:{key}:robux`] or 0
		local count = revenue[`product:{key}:count`] or 0
		add(`product:{key}`, `R$ {key}`, robux, `R$ {formatInteger(robux)}`, `{formatInteger(count)} bought`)
	end
	push(
		out,
		makeTable(
			`worldMoney_{def.id}`,
			`{def.name} · rebirths, eggs & Robux`,
			`Rebirths in the world, {def.tokens.name} (its rebirth tokens) and its shop, {def.currency.name} earned / `
				.. "spent and the produced income share, offline payouts, hatches of the world's eggs and Robux of "
				.. "the world's products.",
			entries,
			"given",
			#entries
		)
	)
end

--------------------------------------------------------------------------------------------------
-- Client performance per world
--------------------------------------------------------------------------------------------------

local FRAME_BOUNDS = ClientPerfConfig.Buckets.FrameMs

local function perf(out: { Table }, ctx: Ctx)
	local health: Counters = ctx.totals.health or {}
	local entries: { Entry } = {}
	for _, worldId in WorldsConfig.Order do
		local def = WorldsConfig.get(worldId)
		local prefix = `perfW:{worldId}:`
		local reports = health[prefix .. "reports"] or 0
		local seconds = health[prefix .. "seconds"] or 0
		if def == nil or reports <= 0 or seconds <= 0 then
			continue
		end
		local counts: { number } = {}
		for index = 1, #FRAME_BOUNDS + 1 do
			counts[index] = health[`{prefix}ft:{ClientPerfLogic.bucketLabel(index, FRAME_BOUNDS)}`] or 0
		end
		local p95 = ClientPerfLogic.percentileIndex(counts, 0.95)
		local sampled = health[prefix .. "sampled"] or 0
		local instN = health[prefix .. "instN"] or 0
		local parts: { string } = {}
		if p95 > 0 then
			table.insert(parts, `frame p95 {ClientPerfLogic.bucketLabel(p95, FRAME_BOUNDS)} ms`)
		end
		if sampled > 0 then
			table.insert(parts, `mem {math.round((health[prefix .. "memMb"] or 0) / sampled)} MB`)
			table.insert(parts, `ping {math.round((health[prefix .. "pingMs"] or 0) / sampled)} ms`)
		end
		if instN > 0 then
			table.insert(parts, `{formatInteger(math.round((health[prefix .. "inst"] or 0) / instN))} instances`)
		end
		table.insert(parts, `{formatInteger(reports)} reports`)
		local fps = (health[prefix .. "frames"] or 0) / seconds
		table.insert(entries, {
			id = worldId,
			label = def.name,
			value = math.round(fps * 10) / 10,
			display = string.format("%.0f fps", fps),
			extra = table.concat(parts, " · "),
		})
	end
	push(
		out,
		makeTable(
			"worldPerf",
			"Worlds · client performance",
			"Client reports split by the world the SERVER knows the player was in (Player attribute CurrentWorld; "
				.. "health perfW:<world>:*). Average fps, frame-time p95 bucket, memory, ping and Stats.InstanceCount.",
			entries,
			"given",
			#WorldsConfig.Order
		)
	)
end

--[[
	Appends every WORLDS table the range holds counters for (see the header) to `out`.
	@param out the report's table list (ReportSections order)
	@param ctx the summary context (totals per family)
]]
function WorldSections.build(out: { Table }, ctx: Ctx)
	local worlds: Counters = ctx.totals.worlds or {}
	if next(worlds) ~= nil then
		overview(out, worlds)
		for _, def in WorldsConfig.extra() do
			funnel(out, worlds, def)
			pacing(out, worlds, def)
			entry(out, worlds, def)
			money(out, ctx, worlds, def)
		end
	end
	perf(out, ctx)
end

return table.freeze(WorldSections)
