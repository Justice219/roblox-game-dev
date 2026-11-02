--!strict
--[[
	PlaytimeService — the Early Gift Ladder (owner R89 §3: TEN gifts at 1 / 3 / 5 / 10 / 15 / 25 /
	40 / 60 / 90 / 120 minutes of TODAY's online playtime, counted by the server; progress kept
	across rejoins the same UTC day). Also owns the lifecycle of the wave's two side modules:
	Retention/PocketRocket (daily impulse product) and Retention/FavoritePrompt (one-time favorite).

	One loop for every player (TickSeconds): credits the real elapsed time since the previous tick
	(capped at PlaytimeConfig.MaxTickCredit so a server hitch never mints time) to
	profile.timeRewards on the server's UTC day, and to profile.stats.playSeconds. The client never
	sends a time. The profile is pushed every PushEverySeconds and on a day rollover; between pushes
	the client extrapolates.

	Remotes (C→S, token bucket each):
		ClaimTimeReward (index 1..#Gifts)  valid index → profile + canMutate → PlaytimeLogic.claim
		                                   (enough seconds today, not claimed) → paid in the same step
		ClaimTimeRewardsAll ()             PlaytimeLogic.claimAll → every ready gift paid in the same
		                                   step, ONE toast
	Paying a gift (payGift, no yield): its RetentionConfig.Reward through RewardGrant.grant, plus a
	held crate (CrateLogic.grantHeld) when the gift has one and paid random items are allowed for
	the player (PlayerDataService.isPaidRandomRestricted, fail closed), else its fallback gems.
	Each claimed gift fires ProgressEvents "gift" (Quests / Pass); the favorite-moment gift tells
	FavoritePrompt.

	Analytics (retention): "time:claim:<1-10>", "time:claimAll:<2-10>", "time:crate:<crate|gems>",
	"time:admin:<reset|unlock|claim>". Admin (Players tab, audited): GiftLadderStatus,
	GiftLadderReset { part }, GiftLadderStep { step, mode }; Studio only: FavoriteMomentTest.
	Seams kept for B7 AdminHooks: addSeconds(player, seconds), resetToday(player).

	Example: PlaytimeService.addSeconds(player, 3600) -- admin / tests: +1 h of today's playtime
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local CrateLogic = require(ServerScriptService.Server.Pets.CrateLogic)
local FavoritePrompt = require(ServerScriptService.Server.Retention.FavoritePrompt)
local GiftsConfig = require(ReplicatedStorage.Shared.Config.GiftsConfig)
local Lazy = require(ServerScriptService.Server.Event.Lazy)
local PlayerDataService = require(script.Parent.PlayerDataService)
local PlaytimeConfig = require(ReplicatedStorage.Shared.Config.PlaytimeConfig)
local PlaytimeLogic = require(ServerScriptService.Server.Retention.PlaytimeLogic)
local PocketRocket = require(ServerScriptService.Server.Retention.PocketRocket)
local ProgressEvents = require(ServerScriptService.Server.Progression.ProgressEvents)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local RewardGrant = require(ServerScriptService.Server.Retention.RewardGrant)
local RewardLogic = require(ServerScriptService.Server.Retention.RewardLogic)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)

local PlaytimeService = {}

local limiter = RateLimiter.new(RetentionConfig.Limits.Claim.Burst, RetentionConfig.Limits.Claim.PerSecond)
-- os.clock() of each player's last credited tick, and seconds since their last push.
local lastTick: { [Player]: number } = {}
local sincePush: { [Player]: number } = {}

-- Today's UTC day number on the server clock.
local function today(): number
	return RetentionConfig.utcDay(os.time())
end

-- One tick for one player: credit elapsed playtime, push when due.
local function tickPlayer(player: Player, nowClock: number, day: number)
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		lastTick[player] = nil
		return
	end
	local previous = lastTick[player]
	lastTick[player] = nowClock
	if previous == nil then
		return -- first tick after load: start counting from here
	end
	local state = profile.timeRewards :: PlaytimeLogic.State
	local rolled = PlaytimeLogic.rollover(state, day)
	local credited = PlaytimeLogic.accrue(state, nowClock - previous, day)
	if credited > 0 then
		profile.stats.playSeconds = math.min(profile.stats.playSeconds + credited, 1e15)
	end
	sincePush[player] = (sincePush[player] or 0) + credited
	if rolled or (sincePush[player] or 0) >= PlaytimeConfig.PushEverySeconds then
		sincePush[player] = 0
		PlayerDataService.markChanged(player, false, { "timeRewards", "stats" })
	end
end

-- The single playtime loop.
local function loop()
	while true do
		task.wait(PlaytimeConfig.TickSeconds)
		local nowClock = os.clock()
		local day = today()
		for _, player in Players:GetPlayers() do
			tickPlayer(player, nowClock, day)
		end
	end
end

-- What one gift paid: the reward summary and the crate part ("crate" | "gems" | nil).
type Paid = { summary: RewardLogic.Summary?, crate: "crate" | "gems" | nil, crateName: string?, crateGems: number }

--[[
	Pays one ALREADY-MARKED gift (no yield): its reward, then its crate (or the crate's fallback
	gems where paid random items are restricted / the policy is unknown).
]]
local function payGift(player: Player, gift: PlaytimeConfig.Gift): Paid
	local summary =
		RewardGrant.grant(player, gift.reward, "timeReward", { saveSoon = true, extraFields = { "timeRewards" } })
	local paid: Paid = { summary = summary, crate = nil, crateName = nil, crateGems = 0 }
	local crate = gift.crate
	local profile = PlayerDataService.getProfile(player)
	if crate == nil or profile == nil then
		return paid
	end
	local def = CrateConfig.get(crate.id)
	if
		def ~= nil
		and not PlayerDataService.isPaidRandomRestricted(player)
		and CrateLogic.grantHeld(profile, crate.id, crate.count)
	then
		PlayerDataService.markChanged(player, true, { "crates" })
		paid.crate, paid.crateName = "crate", def.name
	else
		local fallback = RewardGrant.grant(player, { gems = crate.fallbackGems }, "timeReward", { saveSoon = true })
		paid.crate = "gems"
		paid.crateGems = if fallback ~= nil then fallback.gems else 0
	end
	RewardGrant.track(player, `time:crate:{paid.crate}`)
	return paid
end

-- The toast text of a set of paid gifts ("+$1.25K, +10 Gems, Supply Crate").
local function describe(paidList: { Paid }): string
	local merged: RewardLogic.Summary = { cash = 0, gems = 0, spins = 0, fallbackGems = 0, fields = {} }
	local crates: { string } = {}
	for _, paid in paidList do
		local summary = paid.summary
		if summary ~= nil then
			merged.cash += summary.cash
			merged.gems += summary.gems
			merged.spins += summary.spins
			local boost = summary.boost
			if boost ~= nil then
				local current = merged.boost
				merged.boost = if current ~= nil and current.key == boost.key
					then { key = boost.key, seconds = current.seconds + boost.seconds }
					else boost
			end
		end
		merged.gems += paid.crateGems
		if paid.crateName ~= nil then
			table.insert(crates, paid.crateName)
		end
	end
	local text = RewardLogic.describe(merged)
	if #crates > 0 then
		text = if text == "nothing" then table.concat(crates, ", ") else `{text}, {table.concat(crates, ", ")}`
	end
	return text
end

-- Profile + save checks shared by both claim remotes; nil (with a toast) when not claimable now.
local function claimableProfile(player: Player): any
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not PlayerDataService.canMutate(player) then
		PlayerDataService.notify(player, "Your save is still loading - try again in a moment.", "info")
		return nil
	end
	return profile
end

--[[
	Claims gift `index` for `player` (the ClaimTimeReward handler; tests call it).
	@return true when paid
]]
function PlaytimeService.claim(player: Player, rawIndex: unknown): boolean
	local index = Validate.integer(rawIndex, 1, #PlaytimeConfig.Gifts)
	if index == nil then
		return false
	end
	local profile = claimableProfile(player)
	if profile == nil then
		return false
	end
	local code = PlaytimeLogic.claim(profile.timeRewards :: PlaytimeLogic.State, index, today())
	if code == "claimed" then
		PlayerDataService.notify(player, "You already opened this gift today!", "info", "Time")
		return false
	elseif code ~= "ok" then
		PlayerDataService.notify(player, "Keep playing to unlock this gift!", "info", "Time")
		return false
	end
	local gift = PlaytimeConfig.Gifts[index]
	local paid = payGift(player, gift)
	RewardGrant.track(player, `time:claim:{index}`)
	ProgressEvents.progress(player, "gift") -- R78 Quests / Pass: a time gift opened
	PlayerDataService.notify(player, `Gift {index} opened! {describe({ paid })}`, "reward", "Gift")
	FavoritePrompt.onGift(player, gift.favoriteMoment)
	return true
end

--[[
	CLAIM ALL: opens every gift that is ready today in one step (the ClaimTimeRewardsAll handler).
	@return the number of gifts paid (0 = nothing was ready / not claimable)
]]
function PlaytimeService.claimAll(player: Player): number
	local profile = claimableProfile(player)
	if profile == nil then
		return 0
	end
	local opened = PlaytimeLogic.claimAll(profile.timeRewards :: PlaytimeLogic.State, today())
	if #opened == 0 then
		PlayerDataService.notify(player, "Keep playing to unlock the next gift!", "info", "Time")
		return 0
	end
	local paidList: { Paid } = {}
	local moment = false
	for _, index in opened do
		local gift = PlaytimeConfig.Gifts[index]
		table.insert(paidList, payGift(player, gift))
		RewardGrant.track(player, `time:claim:{index}`)
		moment = moment or gift.favoriteMoment
	end
	if #opened >= 2 then
		RewardGrant.track(player, `time:claimAll:{#opened}`)
	end
	ProgressEvents.progress(player, "gift", #opened)
	local title = if #opened == 1 then `Gift {opened[1]} opened!` else `{#opened} gifts opened!`
	PlayerDataService.notify(player, `{title} {describe(paidList)}`, "reward", "Gift")
	FavoritePrompt.onGift(player, moment)
	return #opened
end

--[[ Admin / tests: adds playtime to today's counter (bypasses the per-tick cap, not the day cap). ]]
function PlaytimeService.addSeconds(player: Player, seconds: number): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or seconds ~= seconds or seconds <= 0 or seconds == math.huge then
		return false
	end
	local state = profile.timeRewards :: PlaytimeLogic.State
	PlaytimeLogic.rollover(state, today())
	state.seconds = math.min(state.seconds + seconds, PlaytimeConfig.MaxSecondsPerDay)
	PlayerDataService.markChanged(player, false, { "timeRewards" })
	return true
end

--[[ Admin: restarts today's ladder (seconds 0, nothing claimed). ]]
function PlaytimeService.resetToday(player: Player): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not PlaytimeLogic.reset(profile.timeRewards :: PlaytimeLogic.State, today()) then
		return false
	end
	PlayerDataService.markChanged(player, true, { "timeRewards" })
	return true
end

-- Admin ------------------------------------------------------------------------------------------

-- The target player of an admin command (nil when the command was not aimed at an online player).
local function targetOf(ctx: any): Player?
	local target = if type(ctx) == "table" then ctx.target else nil
	return if type(target) == "table" then target.player else nil
end

-- One line describing a player's ladder + side state (GiftLadderStatus).
local function statusLine(player: Player, profile: any): string
	local day = today()
	local state = profile.timeRewards
	local claimed: { string } = {}
	for _, view in PlaytimeConfig.status(state, day) do
		if view.state == "claimed" then
			table.insert(claimed, tostring(view.index))
		end
	end
	local ready = PlaytimeConfig.readyIndices(state, day)
	local gifts = profile.gifts
	local favorite = if gifts.favorite == GiftsConfig.FavoriteState.Answered
		then "answered"
		elseif gifts.favorite == GiftsConfig.FavoriteState.Shown then "shown"
		else "never"
	local minutes = math.floor(PlaytimeConfig.secondsToday(state, day) / 60)
	local rocket = if GiftsConfig.rocketBoughtToday(gifts, day) then "used today" else "available"
	local asks = `{gifts.favoriteAsks}/{GiftsConfig.Favorite.MaxAsks} asks`
	return `{player.Name}: {minutes} min today, claimed [{table.concat(claimed, ",")}], ready {#ready}; `
		.. `Pocket Rocket {rocket}; favorite {favorite} ({asks})`
end

-- Registers the gift ladder's owner-admin commands (guarded; AdminService may be missing).
local function registerAdmin()
	Lazy.registerAdmin({
		name = "GiftLadderStatus",
		tab = "Players",
		label = "Gifts: Status",
		description = "Today's gift ladder (minutes, claimed, ready), Pocket Rocket and favorite prompt state.",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = false,
		confirm = false,
		color = "green",
		order = 420,
	}, function(ctx: any): (boolean, string)
		local player = targetOf(ctx)
		local profile = if player ~= nil then PlayerDataService.getProfile(player) else nil
		if player == nil or profile == nil then
			return false, "Player not in this server / not loaded"
		end
		return true, statusLine(player, profile)
	end)
	Lazy.registerAdmin({
		name = "GiftLadderReset",
		tab = "Players",
		label = "Gifts: Reset",
		description = "QA reset: today's gift ladder (0 min, nothing claimed), the Pocket Rocket day, the favorite prompt record, or all.",
		target = "Player",
		args = {
			part = {
				kind = "enum",
				values = { "ladder", "rocket", "favorite", "all" },
				labels = { "LADDER", "POCKET ROCKET", "FAVORITE", "ALL" },
				label = "Reset",
			},
		},
		argOrder = { "part" },
		cooldown = 2,
		audited = true,
		confirm = true,
		color = "red",
		order = 421,
	}, function(ctx: any): (boolean, string)
		local player = targetOf(ctx)
		local profile = if player ~= nil then PlayerDataService.getProfile(player) else nil
		if player == nil or profile == nil then
			return false, "Player not in this server / not loaded"
		end
		local part = ctx.args.part
		if part == "ladder" or part == "all" then
			if not PlaytimeLogic.reset(profile.timeRewards :: PlaytimeLogic.State, today()) then
				return false, "Ladder not reset (server clock behind the saved day)"
			end
		end
		if part == "rocket" or part == "all" then
			profile.gifts.rocketDay = -1
		end
		if part == "favorite" or part == "all" then
			profile.gifts.favorite = GiftsConfig.FavoriteState.None
			profile.gifts.favoriteAsks = 0
		end
		PlayerDataService.markChanged(player, true, { "timeRewards", "gifts" })
		RewardGrant.track(player, "time:admin:reset")
		return true, `Gifts reset ({part}) for {player.Name}`
	end)
	Lazy.registerAdmin({
		name = "GiftLadderStep",
		tab = "Players",
		label = "Gifts: Ladder Step",
		description = "UNLOCK sets today's playtime to that gift's mark (gifts up to it become ready); CLAIM also opens and pays it.",
		target = "Player",
		args = {
			step = {
				kind = "integer",
				min = 1,
				max = #PlaytimeConfig.Gifts,
				presets = { 1, 4, 7, 10 },
				label = "Gift",
				default = 4,
			},
			mode = { kind = "enum", values = { "unlock", "claim" }, labels = { "UNLOCK", "CLAIM" }, label = "Mode" },
		},
		argOrder = { "step", "mode" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "green",
		order = 422,
	}, function(ctx: any): (boolean, string)
		local player = targetOf(ctx)
		local profile = if player ~= nil then PlayerDataService.getProfile(player) else nil
		local gift = PlaytimeConfig.Gifts[ctx.args.step]
		if player == nil or profile == nil or gift == nil then
			return false, "Player not in this server / not loaded"
		end
		local state = profile.timeRewards :: PlaytimeLogic.State
		local mark = gift.minutes * 60
		-- Never lower today's playtime for a CLAIM (other ready gifts stay ready).
		local target = if ctx.args.mode == "claim"
			then math.max(mark, PlaytimeConfig.secondsToday(state, today()))
			else mark
		if PlaytimeLogic.setSeconds(state, target, today()) == nil then
			return false, "Ladder not changed (server clock behind the saved day)"
		end
		PlayerDataService.markChanged(player, true, { "timeRewards" })
		if ctx.args.mode == "claim" then
			RewardGrant.track(player, "time:admin:claim")
			if not PlaytimeService.claim(player, gift.index) then
				return false, `Gift {gift.index} was already opened today`
			end
			return true, `Opened gift {gift.index} ({gift.minutes} min) for {player.Name}`
		end
		RewardGrant.track(player, "time:admin:unlock")
		return true, `{player.Name} is at {gift.minutes} min today (gift {gift.index} ready)`
	end)
	Lazy.registerAdmin({
		name = "FavoriteMomentTest",
		tab = "Players",
		label = "Gifts: Favorite Prompt (test)",
		description = "Studio QA: sends a favorite-prompt moment now (even when answered before). Never rewarded.",
		target = "Player",
		args = {},
		cooldown = 5,
		audited = true,
		confirm = false,
		color = "purple",
		order = 423,
		studioOnly = true,
	}, function(ctx: any): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Player not in this server"
		end
		local sent = FavoritePrompt.announce(player, "gift", true)
		return sent, if sent then `Favorite moment sent to {player.Name}` else "Not sent (profile not loaded)"
	end)
end

function PlaytimeService.Init()
	PocketRocket.Init()
	FavoritePrompt.Init()
end

function PlaytimeService.Start()
	Remotes.onServerEvent("ClaimTimeReward", function(player: Player, rawIndex: unknown)
		if limiter:Allow(player) then
			PlaytimeService.claim(player, rawIndex)
		end
	end)
	Remotes.onServerEvent("ClaimTimeRewardsAll", function(player: Player)
		if limiter:Allow(player) then
			PlaytimeService.claimAll(player)
		end
	end)
	-- A fresh UTC day on join pushes the new ladder at once.
	PlayerDataService.ProfileLoaded:Connect(function(player: Player, profile, _isNew: boolean)
		if PlaytimeLogic.rollover(profile.timeRewards :: PlaytimeLogic.State, today()) then
			PlayerDataService.markChanged(player, false, { "timeRewards" })
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		limiter:Forget(player)
		lastTick[player] = nil
		sincePush[player] = nil
	end)
	PocketRocket.Start()
	FavoritePrompt.Start()
	registerAdmin()
	task.spawn(loop)
end

return PlaytimeService
