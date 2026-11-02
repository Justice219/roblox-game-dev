--!strict
--[[
	PlayerHandlers — built-in handlers of the admin panel's PLAYERS tab (spec §14): currency,
	tycoon state (B5 TycoonAdmin seam), retention resets / boosts / spins (B7 service seams),
	teleport to / bring, kick, ban / unban (Roblox Ban API).

	Every handler receives VALIDATED args and a resolved target (AdminPipeline): a Player-target
	command always has an online `ctx.target.player`; an AnyUser command (Ban / Unban) has a
	range-checked `ctx.target.userId` and the Player only when online. Handlers re-check state
	that can change between validation and execution (profile loaded, character alive) and
	return `(ok, human message)`.

	Moderation safety:
		- nobody can kick / ban themself, the owner, an allowlisted admin, a group admin or anyone
		  currently holding admin rights here (env.isProtectedAsync, live rules even in Studio),
		- kick / ban reasons shown to the player are TextService-filtered; when filtering fails the
		  player sees a generic reason and the log says "(reason withheld)" — never unfiltered text,
		- bans go through Players:BanAsync with ApplyToUniverse (every server, the Creator Hub
		  moderation list) and the raw reason only in the PrivateReason (moderators only).

	Connects to: Server/Admin/HandlerKit, Server/Admin/Seams (TycoonAdmin, BoostService,
	LuckySpinService, RetentionService, PlaytimeService, GroupRewardService, NotifyRewardService),
	Server/Services/PlayerDataService (currency API), Shared/Config/AdminConfig.

	Example:
		PlayerHandlers.install(registry, env)
		print(#PlayerHandlers.recentBans()) --> 0
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local AdminValidate = require(script.Parent.Parent.AdminValidate)
local BoostConfig = require(ReplicatedStorage.Shared.Config.BoostConfig)
local HandlerKit = require(script.Parent.HandlerKit)
local PlayerDataService = require(script.Parent.Parent.Parent.Services.PlayerDataService)
local Seams = require(script.Parent.Parent.Seams)

type Context = HandlerKit.Context
type RecentBan = AdminConfig.RecentBan

local PlayerHandlers = {}

-- Currency reason label (analytics: economy "admin" source / sink).
local REASON = "admin"
-- Studs between the two characters after a teleport.
local TELEPORT_OFFSET = CFrame.new(0, 0, 5)
-- Seconds the server waits for the destination to stream in before moving the caller.
local STREAM_TIMEOUT = 5

local recentBans: { RecentBan } = {}

local Kit = HandlerKit
local num, str = Kit.num, Kit.str

--------------------------------------------------------------------------------------------------
-- Currency
--------------------------------------------------------------------------------------------------

-- Grants cash (amount validated > 0, finite).
local function grantCash(ctx: Context): (boolean, string)
	local player = Kit.targetPlayer(ctx)
	local amount = num(ctx, "amount") :: number
	local profile = Kit.loadedProfile(player)
	if profile == nil then
		return false, `{Kit.label(player)}'s profile is not loaded`
	end
	local added = PlayerDataService.grantCash(player, amount, REASON)
	if added <= 0 then
		return false, `Could not add cash to {Kit.label(player)} (balance cap?)`
	end
	return true, `Gave {Kit.money(added)} to {Kit.label(player)}, now {Kit.money(profile.cash)}`
end

-- Takes up to `amount` cash (never below $0).
local function takeCash(ctx: Context): (boolean, string)
	local player = Kit.targetPlayer(ctx)
	local amount = num(ctx, "amount") :: number
	local profile = Kit.loadedProfile(player)
	if profile == nil then
		return false, `{Kit.label(player)}'s profile is not loaded`
	end
	local take = math.min(amount, profile.cash)
	if take <= 0 then
		return false, `{Kit.label(player)} has no cash to take`
	end
	if not PlayerDataService.trySpendCash(player, take, REASON) then
		return false, `Could not take cash from {Kit.label(player)}`
	end
	return true, `Took {Kit.money(take)} from {Kit.label(player)}, now {Kit.money(profile.cash)}`
end

--[[
	Sets cash to an exact value. Prefers B5's TycoonAdmin.setCash (it can leave totalEarned and
	leaderboards untouched); falls back to a grant / spend of the difference.
]]
local function setCash(ctx: Context): (boolean, string)
	local player = Kit.targetPlayer(ctx)
	local amount = num(ctx, "amount") :: number
	local profile = Kit.loadedProfile(player)
	if profile == nil then
		return false, `{Kit.label(player)}'s profile is not loaded`
	end
	local tycoon = Seams.tycoonAdmin()
	if Seams.has(tycoon, "setCash") then
		return Kit.seamResult(
			tycoon,
			"setCash",
			Kit.TYCOON,
			`Set {Kit.label(player)}'s cash to {Kit.money(amount)}`,
			player,
			amount
		)
	end
	local diff = amount - profile.cash
	if diff > 0 then
		PlayerDataService.grantCash(player, diff, REASON)
	elseif diff < 0 then
		if not PlayerDataService.trySpendCash(player, -diff, REASON) then
			return false, `Could not lower {Kit.label(player)}'s cash`
		end
	end
	return true, `{Kit.label(player)} now has {Kit.money(profile.cash)}`
end

-- Grants gems (whole, ≥ 1).
local function grantGems(ctx: Context): (boolean, string)
	local player = Kit.targetPlayer(ctx)
	local amount = num(ctx, "amount") :: number
	local profile = Kit.loadedProfile(player)
	if profile == nil then
		return false, `{Kit.label(player)}'s profile is not loaded`
	end
	local added = PlayerDataService.grantGems(player, amount, REASON)
	if added <= 0 then
		return false, `Could not add gems to {Kit.label(player)} (balance cap?)`
	end
	return true, `Gave {Kit.short(added)} gems to {Kit.label(player)}, now {Kit.short(profile.gems)}`
end

-- Takes up to `amount` gems (never below 0).
local function takeGems(ctx: Context): (boolean, string)
	local player = Kit.targetPlayer(ctx)
	local amount = num(ctx, "amount") :: number
	local profile = Kit.loadedProfile(player)
	if profile == nil then
		return false, `{Kit.label(player)}'s profile is not loaded`
	end
	local take = math.min(amount, profile.gems)
	if take <= 0 then
		return false, `{Kit.label(player)} has no gems to take`
	end
	if not PlayerDataService.trySpendGems(player, take, REASON) then
		return false, `Could not take gems from {Kit.label(player)}`
	end
	return true, `Took {Kit.short(take)} gems from {Kit.label(player)}, now {Kit.short(profile.gems)}`
end

--------------------------------------------------------------------------------------------------
-- Tycoon (B5 TycoonAdmin seam)
--------------------------------------------------------------------------------------------------

-- Builds a handler forwarding to TycoonAdmin.<fnName>(player, <arg>?).
local function tycoon(fnName: string, argKey: string?, describe: (Player, number?) -> string): HandlerKit.Handler
	return function(ctx: Context): (boolean, string)
		local player = Kit.targetPlayer(ctx)
		if Kit.loadedProfile(player) == nil then
			return false, `{Kit.label(player)}'s profile is not loaded`
		end
		local value = if argKey ~= nil then num(ctx, argKey) else nil
		local fallback = describe(player, value)
		if argKey ~= nil then
			return Kit.seamResult(Seams.tycoonAdmin(), fnName, Kit.TYCOON, fallback, player, value)
		end
		return Kit.seamResult(Seams.tycoonAdmin(), fnName, Kit.TYCOON, fallback, player)
	end
end

--------------------------------------------------------------------------------------------------
-- Retention (B7 service seams)
--------------------------------------------------------------------------------------------------

-- GiveBoost: BoostService.grant(player, key, seconds) -> new expiry or nil.
local function giveBoost(ctx: Context): (boolean, string)
	local player = Kit.targetPlayer(ctx)
	local key = str(ctx, "boost") :: string
	local minutes = num(ctx, "minutes") :: number
	local found, expiry = Seams.call(Seams.service("BoostService"), "grant", player, key, minutes * 60)
	if not found then
		return false, Kit.RETENTION
	end
	if type(expiry) ~= "number" then
		return false, `Could not give the boost to {Kit.label(player)} (profile not loaded?)`
	end
	local def = BoostConfig.Boosts[key]
	local name = if def ~= nil then def.name else key
	return true, `Gave {name} for {minutes} min to {Kit.label(player)}`
end

-- GrantSpins: LuckySpinService.grantSpins(player, count) -> spins added.
local function grantSpins(ctx: Context): (boolean, string)
	local player = Kit.targetPlayer(ctx)
	local count = num(ctx, "count") :: number
	local found, added = Seams.call(Seams.service("LuckySpinService"), "grantSpins", player, count)
	if not found then
		return false, Kit.RETENTION
	end
	if type(added) ~= "number" or added <= 0 then
		return false, `Could not give spins to {Kit.label(player)} (profile not loaded?)`
	end
	return true, `Gave {added} spin{if added == 1 then "" else "s"} to {Kit.label(player)}`
end

-- ResetDaily: daily streak claim + today's time-reward ladder become claimable again.
local function resetDaily(ctx: Context): (boolean, string)
	local player = Kit.targetPlayer(ctx)
	local foundDaily, dailyOk = Seams.call(Seams.service("RetentionService"), "resetDaily", player)
	if not foundDaily then
		return false, Kit.RETENTION
	end
	local foundTime, timeOk = Seams.call(Seams.service("PlaytimeService"), "resetToday", player)
	local parts: { string } = {}
	table.insert(parts, if dailyOk == true then "daily reset" else "daily NOT reset")
	if foundTime then
		table.insert(parts, if timeOk == true then "time rewards reset" else "time rewards NOT reset")
	end
	local ok = dailyOk == true and (not foundTime or timeOk == true)
	return ok, `{Kit.label(player)}: {table.concat(parts, ", ")}`
end

-- AddPlaytime: PlaytimeService.addSeconds(player, seconds) -> boolean.
local function addPlaytime(ctx: Context): (boolean, string)
	local player = Kit.targetPlayer(ctx)
	local minutes = num(ctx, "minutes") :: number
	local found, ok = Seams.call(Seams.service("PlaytimeService"), "addSeconds", player, minutes * 60)
	if not found then
		return false, Kit.RETENTION
	end
	if ok ~= true then
		return false, `Could not add playtime to {Kit.label(player)} (profile not loaded?)`
	end
	return true, `Added {minutes} min of playtime to {Kit.label(player)}`
end

-- ResetClaims: group + notification one-time rewards claimable again.
local function resetClaims(ctx: Context): (boolean, string)
	local player = Kit.targetPlayer(ctx)
	local foundGroup, groupOk = Seams.call(Seams.service("GroupRewardService"), "resetClaim", player)
	local foundNotify, notifyOk = Seams.call(Seams.service("NotifyRewardService"), "resetClaim", player)
	if not foundGroup and not foundNotify then
		return false, Kit.RETENTION
	end
	local parts: { string } = {}
	if foundGroup then
		table.insert(parts, if groupOk == true then "group reset" else "group NOT reset")
	end
	if foundNotify then
		table.insert(parts, if notifyOk == true then "notifications reset" else "notifications NOT reset")
	end
	local ok = (not foundGroup or groupOk == true) and (not foundNotify or notifyOk == true)
	return ok, `{Kit.label(player)}: {table.concat(parts, ", ")}`
end

-- ResetClaims is usable when either service exists.
local function resetClaimsProbe(): string?
	if
		Seams.has(Seams.service("GroupRewardService"), "resetClaim")
		or Seams.has(Seams.service("NotifyRewardService"), "resetClaim")
	then
		return nil
	end
	return Kit.RETENTION
end

--------------------------------------------------------------------------------------------------
-- Movement
--------------------------------------------------------------------------------------------------

-- The root part of a player's living character, or nil.
local function aliveRoot(player: Player): BasePart?
	local character = player.Character
	if character == nil then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
		return nil
	end
	return root
end

-- Moves `mover`'s character next to `anchor`'s (both alive). Yields (stream-around request).
local function moveNextTo(mover: Player, anchor: Player): (boolean, string)
	local anchorRoot = aliveRoot(anchor)
	local moverRoot = aliveRoot(mover)
	if anchorRoot == nil then
		return false, `{Kit.label(anchor)} has no living character`
	end
	if moverRoot == nil then
		return false, `{Kit.label(mover)} has no living character`
	end
	local destination = anchorRoot.CFrame * TELEPORT_OFFSET
	-- StreamingEnabled: ask the mover's client to stream the destination in first (best effort).
	pcall(function()
		mover:RequestStreamAroundAsync(destination.Position, STREAM_TIMEOUT)
	end)
	-- Re-check after the yield: either character may have died / left meanwhile.
	local character = mover.Character
	if character == nil or aliveRoot(mover) == nil or aliveRoot(anchor) == nil then
		return false, "A character changed during the teleport; try again"
	end
	character:PivotTo((aliveRoot(anchor) :: BasePart).CFrame * TELEPORT_OFFSET)
	return true, `Moved {Kit.label(mover)} to {Kit.label(anchor)}`
end

-- TeleportTo: the caller goes to the target.
local function teleportTo(ctx: Context): (boolean, string)
	local target = Kit.targetPlayer(ctx)
	local me = ctx.caller.player
	if me == nil then
		return false, "Only an in-game admin can teleport"
	end
	if me == target then
		return false, "That is you"
	end
	return moveNextTo(me, target)
end

-- Bring: the target comes to the caller.
local function bring(ctx: Context): (boolean, string)
	local target = Kit.targetPlayer(ctx)
	local me = ctx.caller.player
	if me == nil then
		return false, "Only an in-game admin can bring players"
	end
	if me == target then
		return false, "That is you"
	end
	return moveNextTo(target, me)
end

--------------------------------------------------------------------------------------------------
-- Moderation
--------------------------------------------------------------------------------------------------

-- Kick (filtered reason; never the caller or a protected user).
local function makeKick(env: HandlerKit.Env): HandlerKit.Handler
	return function(ctx: Context): (boolean, string)
		local player = Kit.targetPlayer(ctx)
		if player.UserId == ctx.caller.userId then
			return false, "You cannot kick yourself"
		end
		if env.isProtectedAsync(player.UserId) then
			return false, "Admins cannot be kicked from the panel"
		end
		local reason = str(ctx, "reason") or ""
		local shown = "Removed by a moderator."
		if reason ~= "" then
			local filtered = Kit.filterBroadcastAsync(reason, ctx.caller.userId)
			if filtered ~= nil and string.match(filtered, "%S") ~= nil then
				shown = `Removed by a moderator: {filtered}`
			end
		end
		if player.Parent ~= Players then
			return false, `{Kit.label(player)} already left`
		end
		local label = Kit.label(player)
		player:Kick(shown)
		return true, `Kicked {label}`
	end
end

-- Records a ban for the panel's quick-unban list (ring of RecentBansSize).
local function rememberBan(entry: RecentBan)
	for index = #recentBans, 1, -1 do
		if recentBans[index].userId == entry.userId then
			table.remove(recentBans, index)
		end
	end
	table.insert(recentBans, entry)
	while #recentBans > AdminConfig.RecentBansSize do
		table.remove(recentBans, 1)
	end
end

-- Ban (Roblox Ban API, universe-wide).
local function makeBan(env: HandlerKit.Env): HandlerKit.Handler
	return function(ctx: Context): (boolean, string)
		local userId = ctx.target.userId
		local duration = num(ctx, "durationSeconds")
		assert(userId ~= nil and duration ~= nil, "schema guarantees userId and durationSeconds")
		if userId == ctx.caller.userId then
			return false, "You cannot ban yourself"
		end
		if env.isProtectedAsync(userId) then
			return false, "Admins cannot be banned from the panel"
		end
		local reason = str(ctx, "reason") or ""
		-- nil = filtering failed (never show the raw reason); "" = no reason given.
		local filtered: string? = if reason ~= "" then Kit.filterBroadcastAsync(reason, ctx.caller.userId) else ""
		local displayReason = "Banned by a moderator."
		local loggedReason = "(reason withheld: filtering failed)"
		if filtered ~= nil then
			loggedReason = filtered
			if string.match(filtered, "%S") ~= nil then
				displayReason = `Banned by a moderator: {filtered}`
			end
		end
		-- The private reason is only visible to the experience's moderators in the Creator Hub.
		local rawReason: string = if reason ~= "" then reason else "none"
		local privateReason =
			string.sub(`Admin panel ban by {ctx.caller.name} ({ctx.caller.userId}). Reason: {rawReason}`, 1, 1000)
		local online = ctx.target.player
		local name = if online ~= nil then online.Name else `user {userId}`
		local ok, err = pcall(function()
			Players:BanAsync({
				UserIds = { userId },
				Duration = duration,
				DisplayReason = string.sub(displayReason, 1, 400),
				PrivateReason = privateReason,
				ExcludeAltAccounts = false,
				ApplyToUniverse = true,
			})
		end)
		if not ok then
			return false, `Ban failed: {AdminValidate.sanitizeForLog(err, 120)}`
		end
		rememberBan({
			userId = userId,
			name = AdminValidate.sanitizeForLog(name, 32),
			durationSeconds = duration,
			reason = AdminValidate.sanitizeForLog(loggedReason, 80),
			time = os.time(),
			byName = AdminValidate.sanitizeForLog(ctx.caller.name, 32),
		})
		local span = if duration == -1 then "permanently" else `for {duration}s`
		return true, `Banned {ctx.target.label} {span}`
	end
end

-- Unban (Roblox Ban API).
local function unban(ctx: Context): (boolean, string)
	local userId = ctx.target.userId
	assert(userId ~= nil, "schema guarantees userId")
	local ok, err = pcall(function()
		Players:UnbanAsync({ UserIds = { userId }, ApplyToUniverse = true })
	end)
	if not ok then
		return false, `Unban failed: {AdminValidate.sanitizeForLog(err, 120)}`
	end
	for index = #recentBans, 1, -1 do
		if recentBans[index].userId == userId then
			table.remove(recentBans, index)
		end
	end
	return true, `Unbanned {ctx.target.label}`
end

--------------------------------------------------------------------------------------------------
-- Install
--------------------------------------------------------------------------------------------------

--[[
	Installs every Players-tab handler into the registry.
	@param registry AdminRegistry instance
	@param env protection / admin checks from AdminService
]]
function PlayerHandlers.install(registry: HandlerKit.Registry, env: HandlerKit.Env)
	registry.setBuiltin("GrantCash", grantCash)
	registry.setBuiltin("TakeCash", takeCash)
	registry.setBuiltin("SetCash", setCash)
	registry.setBuiltin("GrantGems", grantGems)
	registry.setBuiltin("TakeGems", takeGems)

	registry.setBuiltin(
		"SetArea",
		tycoon("setArea", "area", function(player: Player, area: number?): string
			return `{Kit.label(player)} is now in area {area or "?"}`
		end),
		Kit.tycoonProbe("setArea")
	)
	registry.setBuiltin(
		"UnlockAll",
		tycoon("unlockAll", nil, function(player: Player): string
			return `Unlocked every pad for {Kit.label(player)}`
		end),
		Kit.tycoonProbe("unlockAll")
	)
	registry.setBuiltin(
		"ResetPlot",
		tycoon("resetPlot", nil, function(player: Player): string
			return `Reset {Kit.label(player)}'s plot`
		end),
		Kit.tycoonProbe("resetPlot")
	)
	registry.setBuiltin(
		"SetRebirths",
		tycoon("setRebirths", "rebirths", function(player: Player, rebirths: number?): string
			return `{Kit.label(player)} now has {rebirths or "?"} rebirths`
		end),
		Kit.tycoonProbe("setRebirths")
	)

	registry.setBuiltin("GiveBoost", giveBoost, Kit.serviceProbe("BoostService", "grant", Kit.RETENTION))
	registry.setBuiltin("GrantSpins", grantSpins, Kit.serviceProbe("LuckySpinService", "grantSpins", Kit.RETENTION))
	registry.setBuiltin("ResetDaily", resetDaily, Kit.serviceProbe("RetentionService", "resetDaily", Kit.RETENTION))
	registry.setBuiltin("AddPlaytime", addPlaytime, Kit.serviceProbe("PlaytimeService", "addSeconds", Kit.RETENTION))
	registry.setBuiltin("ResetClaims", resetClaims, resetClaimsProbe)

	registry.setBuiltin("TeleportTo", teleportTo)
	registry.setBuiltin("Bring", bring)
	registry.setBuiltin("Kick", makeKick(env))
	registry.setBuiltin("Ban", makeBan(env))
	registry.setBuiltin("Unban", unban)
end

--[[ Bans issued from this server's panel (newest last; copy). ]]
function PlayerHandlers.recentBans(): { RecentBan }
	return table.clone(recentBans)
end

return table.freeze(PlayerHandlers)
