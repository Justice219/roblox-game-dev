--!strict
--[[
	TipJar — the server rules of owner R90's Tip Jar (spec docs/superpowers/specs/2026-10-31-r90-
	hands-on-design.md §3; docs/kinetic.md): a glass jar on the player's plot (every world) that fills
	with that world's currency while the owner is ONLINE, in that world and near the plot, and pays
	out when they walk into it (server Touched) or use its Interact prompt (KineticAction "collect").

	Rules (maths in Shared/Tycoon/KineticLogic, numbers in KineticConfig.TipJar)
		fill     every KineticService tick, for the world the player stands in only: + FillFraction x
		         TycoonService.incomePerSecond(player, world) x dt while the character is within
		         NearMargin of the plot, up to jarCap (CapMinutes of filling). Never shrinks.
		tips     TipJar.addCoins adds earned bonus coins to a separate bucket (capped at
		         BonusCapIncomeSeconds of income). Its only caller was the R90 Order Window's big
		         tips; owner R128 removed that system, so today nothing adds tips — a jar still
		         holding old tips pays them out normally, and the API stays for a future bonus.
		collect  owner + jar placed + jar switch on + character within Reach of the jar (server
		         position) + KineticLogic.collectable (min fill or any tips; HardCap ceiling). The
		         jar is emptied BEFORE the grant (a repeated touch / intent finds it empty →
		         idempotent), then PlayerDataService.grantCurrency(world currency, "tipJar").
		rebirth  KineticService empties that world's jar (TipJar.clearWorld): its coins were the old
		         run's currency.
	Display: the jar's Fill (0..1 in FillSteps) / Full attributes change only on a step; a payout
	stamps CollectedAt (everyone nearby sees the coin burst) and sends the owner the "collect" wire
	(CurrencyFly); a tip stamps TippedAt and sends "tip" (coin shower into the jar).

	Security: the client never sends an amount; touches count only the owner's own character
	(Players:GetPlayerFromCharacter) and are debounced per player; reach is measured server-side.
	Performance: O(1) per player per tick; profile writes are in-memory, marked for save at most
	every SaveSeconds (payouts save soon).

	API
		TipJar.addCoins(player, amount, worldId?) -> number   accepted amount (0 = refused: the
		        caller pays those coins itself). Server-only; never wire it to a remote.
		TipJar.collect(player, source: "touch" | "prompt") -> (ok, reason?)
		TipJar.onTouched(owner, hit)          the jar trigger's Touched (KineticWorld)
		TipJar.tick(player, dt)               one fill step (KineticService loop)
		TipJar.publish(player, worldId)       Fill / Full attributes from the saved coins
		TipJar.clearWorld(player, worldId)    empty a world's jar (rebirth)
		TipJar.adminFill(player) -> (ok, message)
		TipJar.stats() -> { collects, tips, paid }
		TipJar.forget(player)

	Connects to: Shared/Config/{KineticConfig, Worlds/WorldsConfig, WorldLayout}, Shared/Tycoon/
	KineticLogic, Shared/Net/Remotes, Server/Kinetic/{KineticWorld, KineticAnalytics},
	Server/Services/PlayerDataService, Server/Tycoon/{TycoonService, WorldService, PlotService},
	Server/Progression/ProgressEvents ("tipjar").

	Example (a bonus source dropping a reward into the jar; pay whatever it refuses directly):
		local TipJar = require(ServerScriptService.Server.Kinetic.TipJar)
		local accepted = TipJar.addCoins(player, extraCoins) -- nil world = the player's current one
		if accepted < extraCoins then PlayerDataService.grantCurrency(player, key, extraCoins - accepted, "bonusTip") end
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local KineticAnalytics = require(script.Parent.KineticAnalytics)
local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)
local KineticLogic = require(ReplicatedStorage.Shared.Tycoon.KineticLogic)
local KineticWorld = require(script.Parent.KineticWorld)
local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService)
local PlotService = require(script.Parent.Parent.Tycoon.PlotService)
local ProgressEvents = require(script.Parent.Parent.Progression.ProgressEvents)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TycoonService = require(script.Parent.Parent.Tycoon.TycoonService)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldService = require(script.Parent.Parent.Tycoon.WorldService)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local ATTR = KineticConfig.Attr
local JAR = KineticConfig.TipJar
local COPY = KineticConfig.Copy
-- markChanged field list: the jar is server-only (no snapshot field moved).
local NO_FIELDS: { string } = table.freeze({}) :: any

type Runtime = {
	touchAt: number, -- os.clock() of the last touch payout attempt
	noticeAt: number, -- os.clock() of the last "still filling" toast
	saveAt: number, -- os.clock() the passive fill was last marked for save
	dirty: boolean, -- passive coins changed since that mark
	full: { [string]: boolean }, -- worlds whose jar was full at the last publish (jarFull once)
}

local TipJar = {}

local runtimes: { [Player]: Runtime } = {}
local counters = { collects = 0, tips = 0, paid = 0 }

-- The per-player runtime (created on demand).
local function runtimeOf(player: Player): Runtime
	local rt = runtimes[player]
	if rt == nil then
		rt = { touchAt = -math.huge, noticeAt = -math.huge, saveAt = os.clock(), dirty = false, full = {} }
		runtimes[player] = rt
	end
	return rt
end

-- The jar switch (ReplicatedStorage attribute, admin KineticSwitch; missing = on).
local function enabled(): boolean
	return ReplicatedStorage:GetAttribute(ATTR.JarOn) ~= false
end

-- The character root (nil when dead / not spawned).
local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

-- The wallet key of a world ("cash" / "bones" / ...), nil for an unknown world.
local function currencyOf(worldId: string): string?
	local def = WorldsConfig.get(worldId)
	return if def ~= nil then def.currency.key else nil
end

-- The saved jar entry of a world (nil while the profile is not loaded).
local function entryOf(player: Player, worldId: string): KineticLogic.WorldEntry?
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return nil
	end
	return KineticLogic.entry((profile :: any).kinetic, worldId)
end

-- A throttled info toast (the prompt path only; touches stay silent).
local function notice(player: Player, text: string)
	local rt = runtimeOf(player)
	local t = os.clock()
	if t - rt.noticeAt >= KineticConfig.NoticeSeconds then
		rt.noticeAt = t
		PlayerDataService.notify(player, text, "info")
	end
end

--[[
	Refreshes a world jar's Fill / Full attributes from the saved coins (writes only on a step).
	Also records jarFull once each time the jar reaches its passive cap.
]]
function TipJar.publish(player: Player, worldId: string)
	local jar = KineticWorld.jar(player, worldId)
	local entry = entryOf(player, worldId)
	if jar == nil or entry == nil then
		return
	end
	local income = TycoonService.incomePerSecond(player, worldId)
	local cap = KineticLogic.jarCap(income)
	local full = cap > 0 and entry.jar >= cap
	KineticWorld.setAttr(jar, ATTR.Fill, KineticLogic.fillRatio(entry.jar, entry.tips, income))
	KineticWorld.setAttr(jar, ATTR.Full, full)
	local rt = runtimeOf(player)
	if full and not rt.full[worldId] then
		KineticAnalytics.record(player, `jarFull:{worldId}`)
	end
	rt.full[worldId] = full
end

--[[
	One fill step for the world the player stands in (KineticService loop, every TickSeconds).
	@param player Player
	@param dt number — seconds since the last step
]]
function TipJar.tick(player: Player, dt: number)
	local worldId = WorldService.currentWorld(player)
	local jar = KineticWorld.jar(player, worldId)
	local entry = entryOf(player, worldId)
	if jar == nil or entry == nil then
		return
	end
	local rt = runtimeOf(player)
	if enabled() then
		local root = rootOf(player)
		local plot = PlotService.getPlotIndex(player)
		if root ~= nil and plot ~= nil and WorldLayout.worldAt(root.Position) == worldId then
			local localPoint = WorldLayout.plotOrigin(plot, worldId):PointToObjectSpace(root.Position)
			if KineticLogic.nearPlot(localPoint, WorldLayout.plotLength(worldId)) then
				local income = TycoonService.incomePerSecond(player, worldId)
				local filled = KineticLogic.jarFill(entry.jar, income, dt)
				if filled ~= entry.jar then
					entry.jar = filled
					rt.dirty = true
				end
			end
		end
	end
	TipJar.publish(player, worldId)
	-- Passive fill is low-value bookkeeping: mark it for the regular autosave now and then.
	local t = os.clock()
	if rt.dirty and t - rt.saveAt >= JAR.SaveSeconds then
		rt.dirty = false
		rt.saveAt = t
		PlayerDataService.markChanged(player, false, NO_FIELDS)
	end
end

-- Records a refusal and answers the prompt path with a toast where it helps.
local function refuse(player: Player, reason: string, source: string): (boolean, string?)
	-- Touches are noisy by nature (walking past an empty jar): only prompt refusals are counted.
	if source == "prompt" then
		KineticAnalytics.record(player, `jarRefused:{reason}`)
		if reason == "empty" or reason == "noIncome" then
			notice(player, COPY.JarFilling)
		elseif reason == "off" then
			notice(player, COPY.JarOff)
		end
	end
	return false, reason
end

--[[
	Pays the owner's jar of the world they stand in.
	@param player Player
	@param source "touch" | "prompt"
	@return (ok, reason?) — reason: off | locked | reach | empty | noIncome
]]
function TipJar.collect(player: Player, source: "touch" | "prompt"): (boolean, string?)
	if not enabled() then
		return refuse(player, "off", source)
	end
	local worldId = WorldService.currentWorld(player)
	local jar = KineticWorld.jar(player, worldId)
	local entry = entryOf(player, worldId)
	local currency = currencyOf(worldId)
	if jar == nil or entry == nil or currency == nil then
		return refuse(player, "locked", source)
	end
	local root = rootOf(player)
	if
		root == nil
		or not KineticLogic.withinReach(root.Position, jar:GetPivot().Position, JAR.Reach, JAR.ReachVertical)
	then
		return refuse(player, "reach", source)
	end
	local income = TycoonService.incomePerSecond(player, worldId)
	local payout, reason = KineticLogic.collectable(entry.jar, entry.tips, income)
	if payout <= 0 then
		return refuse(player, reason or "empty", source)
	end
	-- Empty first (idempotent: a second touch / intent in the same frame finds nothing), then pay.
	local jarBefore, tipsBefore = entry.jar, entry.tips
	entry.jar, entry.tips = 0, 0
	local granted = PlayerDataService.grantCurrency(player, currency, payout, KineticConfig.Reasons.Jar)
	if granted <= 0 then
		entry.jar, entry.tips = jarBefore, tipsBefore -- nothing paid (wallet at its cap): keep the coins
		return refuse(player, "locked", source)
	end
	PlayerDataService.markChanged(player, true, NO_FIELDS)
	KineticWorld.setAttr(jar, ATTR.Fill, 0)
	KineticWorld.setAttr(jar, ATTR.Full, false)
	jar:SetAttribute(ATTR.CollectedAt, Workspace:GetServerTimeNow())
	runtimeOf(player).full[worldId] = false
	Remotes.fireClient("Kinetic", player, {
		kind = "collect",
		world = worldId,
		amount = granted,
		currency = currency,
	})
	ProgressEvents.progress(player, "tipjar")
	counters.collects += 1
	counters.paid += granted
	KineticAnalytics.record(player, `jar:{worldId}`)
	KineticAnalytics.record(player, `jarPaid:{worldId}`, granted)
	if source == "touch" then
		KineticAnalytics.record(player, `jarTouch:{worldId}`)
	end
	return true, nil
end

--[[
	The jar trigger's Touched: only the owner's own character counts, debounced per player.
	@param owner Player — the jar's owner (bound by KineticWorld at placement)
	@param hit BasePart — the part that touched the trigger
]]
function TipJar.onTouched(owner: Player, hit: BasePart)
	if owner.Parent ~= Players then
		return
	end
	local character = hit.Parent
	if character == nil or not character:IsA("Model") or Players:GetPlayerFromCharacter(character) ~= owner then
		return
	end
	local rt = runtimeOf(owner)
	local t = os.clock()
	if t - rt.touchAt < JAR.TouchCooldown then
		return
	end
	rt.touchAt = t
	TipJar.collect(owner, "touch")
end

--[[
	Drops earned bonus coins into the player's jar (no caller since owner R128 removed the Order
	Window, whose big tips used it; kept as the jar's bonus API). Server-only.
	@param player Player
	@param amount number — that world's currency (finite > 0)
	@param worldId string? — nil = the world the player stands in
	@return number — the amount accepted (0 = refused: no jar on that plot / switch off / bucket
	        full / no income; the caller then pays those coins directly)
	Example: local accepted = TipJar.addCoins(player, 2500)
]]
function TipJar.addCoins(player: Player, amount: number, worldId: string?): number
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return 0
	end
	if not KineticLogic.isFinite(amount) or amount <= 0 then
		KineticAnalytics.record(player, "tipRefused:bad")
		return 0
	end
	local world = worldId or WorldService.currentWorld(player)
	local currency = currencyOf(world)
	local jar = KineticWorld.jar(player, world)
	local entry = entryOf(player, world)
	if not enabled() or currency == nil or jar == nil or entry == nil then
		KineticAnalytics.record(player, "tipRefused:locked")
		return 0
	end
	local income = TycoonService.incomePerSecond(player, world)
	if income <= 0 then
		KineticAnalytics.record(player, "tipRefused:noIncome")
		return 0
	end
	local tips, accepted = KineticLogic.addTips(entry.tips, amount, income)
	if accepted <= 0 then
		KineticAnalytics.record(player, "tipRefused:full")
		return 0
	end
	entry.tips = tips
	PlayerDataService.markChanged(player, true, NO_FIELDS)
	jar:SetAttribute(ATTR.TippedAt, Workspace:GetServerTimeNow())
	TipJar.publish(player, world)
	Remotes.fireClient("Kinetic", player, { kind = "tip", world = world, amount = accepted, currency = currency })
	counters.tips += 1
	KineticAnalytics.record(player, `tip:{world}`)
	KineticAnalytics.record(player, `tipPaid:{world}`, accepted)
	return accepted
end

--[[ Empties a world's jar (passive coins + tips): rebirth of that world. ]]
function TipJar.clearWorld(player: Player, worldId: string)
	local entry = entryOf(player, worldId)
	if entry == nil then
		return
	end
	entry.jar, entry.tips = 0, 0
	runtimeOf(player).full[worldId] = false
	TipJar.publish(player, worldId)
end

--[[
	Admin (KineticJarFill): fills the jar of the world the player stands in to its passive cap.
	@return (ok, message)
]]
function TipJar.adminFill(player: Player): (boolean, string)
	local worldId = WorldService.currentWorld(player)
	local entry = entryOf(player, worldId)
	if entry == nil then
		return false, "Profile not loaded"
	end
	local cap = KineticLogic.jarCap(TycoonService.incomePerSecond(player, worldId))
	if cap <= 0 then
		return false, "No income yet in that world (the jar is sized from income)"
	end
	entry.jar = cap
	runtimeOf(player).dirty = true
	TipJar.publish(player, worldId)
	return true, `Filled {player.Name}'s Tip Jar in {worldId} (cap {math.floor(cap)})`
end

--[[ Server totals since boot (admin KineticStatus / QA). ]]
function TipJar.stats(): { collects: number, tips: number, paid: number }
	return table.clone(counters)
end

--[[ Drops a leaving player's runtime. ]]
function TipJar.forget(player: Player)
	runtimes[player] = nil
end

return TipJar
