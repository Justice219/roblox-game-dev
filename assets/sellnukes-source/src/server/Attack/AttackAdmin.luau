--!strict
--[[
	AttackAdmin — Attack mode's owner-admin commands (spec §14, owner rule 9 "every system is
	controllable from the admin panel"), registered at runtime with B14's
	AdminService.registerCommand(def, handler) through a GUARDED lazy require: when
	Services/AdminService is missing or fails to load nothing is registered and nothing errors.

	Commands (all on the Attack tab — owner R51 — target = an online player; AdminService validates every
	argument against the def BEFORE the handler runs; handler(ctx) -> (ok, message)):
		AttackTestNuke    {}                         a test nuke at their plot (their AA engages;
		                                             no attacker, no reward) — one-player checks
		AttackCooldown    {}                         clears their launch cooldown
		AttackShield      { minutes 1..1440 }        adds shield time (dome appears)
		AttackShieldOff   {}                         removes their shield
		AttackLevels      { aa 0..5, launcher 0..5 } sets stored AA / Launcher levels
		AttackBarrage     { count 1..2000 }          adds stored Barrage nukes
		AttackHitsReset   {}                         resets the free-shield hit counter
		AttackTower       { slot 1..N, level 0..5 }  owner R80: one defence tower slot's stored level
		                                             (QA; 0 shows the BUY pad again — admin only)
		AttackTowersAll   { level 0..5 }             owner R80: every defence tower slot at once
		AttackGolden      { count 1..50 }            owner R85: + stored golden revenge nukes (QA)
	Attack tab, server-wide:
		AttackStats       {}                         nukes in flight / launched this server, rivals on?
		AttackRivals      { on: boolean }            Rival Factory NPC targets on / off (owner R43
		                                             kill switch; this server, live)
		AttackTowerShop   { on: boolean }            owner R80 kill switch: defence tower buys /
		                                             upgrades on / off (owned towers keep defending)
		AttackGrace       { seconds 0..86400 }       owner R85: new-player protection seconds (live,
		                                             this server; 0 = only the tutorial protects)

	Connects to: Server/Services/{AdminService (B14), AttackService, DefenseService},
	Shared/Config/AttackConfig.

	Usage: AttackService.Start → AttackAdmin.install(AttackService, DefenseService)
]]

local ServerScriptService = game:GetService("ServerScriptService")

local AttackConfig = require(game:GetService("ReplicatedStorage").Shared.Config.AttackConfig)

local AttackAdmin = {}

type Ctx = { args: { [string]: any }, target: { player: Player?, label: string }? }
type Handler = (ctx: Ctx) -> (boolean, string)

local installed = false

-- The command's target player (nil when not aimed at an online player).
local function targetOf(ctx: Ctx): Player?
	local target = ctx.target
	return if target ~= nil then target.player else nil
end

-- A Players-tab def aimed at one online player.
local function playerDef(name: string, label: string, description: string, args: { [string]: any }, order: number): any
	return {
		name = name,
		tab = "Attack", -- owner R51: every attack tool lives on the Attack tab
		label = label,
		description = description,
		target = "Player",
		args = args,
		cooldown = 0.5,
		audited = true,
		confirm = false,
		color = "orange",
		order = 300 + order,
	}
end

--[[
	Registers every attack admin command (idempotent).
	@param AttackService any — the attack service (testFlight, resetCooldown, giveBarrage, ...)
	@param DefenseService any — the defense service (addShield, clearShield, setLevels,
	       setTowerLevel / setAllTowers / setTowersEnabled — owner R80)
	@return boolean — true when AdminService accepted the commands
]]
function AttackAdmin.install(AttackService: any, DefenseService: any): boolean
	if installed then
		return true
	end
	local module = ServerScriptService.Server.Services:FindFirstChild("AdminService")
	if module == nil or not module:IsA("ModuleScript") then
		return false
	end
	local ok, AdminService = pcall(require, module)
	if not ok or type(AdminService) ~= "table" or type((AdminService :: any).registerCommand) ~= "function" then
		warn("[AttackAdmin] AdminService could not be loaded; attack admin commands not registered")
		return false
	end
	installed = true
	local register = (AdminService :: any).registerCommand

	local function add(def: any, handler: Handler)
		local registered, err = pcall(register, def, handler)
		if not registered then
			warn(`[AttackAdmin] {def.name} not registered: {err}`)
		end
	end

	-- Wraps a handler that needs an online target.
	local function withPlayer(fn: (player: Player, args: { [string]: any }) -> (boolean, string)): Handler
		return function(ctx: Ctx): (boolean, string)
			local player = targetOf(ctx)
			if player == nil then
				return false, "Pick a player first"
			end
			return fn(player, ctx.args)
		end
	end

	add(
		playerDef(
			"AttackTestNuke",
			"Test nuke",
			"Sends a harmless test nuke at their plot (their AA tower engages).",
			{},
			1
		),
		withPlayer(function(player: Player)
			local sent = AttackService.testFlight(player)
			return sent, if sent then `Test nuke sent at {player.Name}'s plot` else `{player.Name} has no plot`
		end)
	)
	add(
		playerDef("AttackCooldown", "Reset nuke cooldown", "Their launcher is ready again.", {}, 2),
		withPlayer(function(player: Player)
			return AttackService.resetCooldown(player), `Cooldown cleared for {player.Name}`
		end)
	)
	add(
		playerDef("AttackShield", "Give shield", "Adds shield bubble time.", {
			minutes = {
				kind = "integer",
				min = 1,
				max = 1440,
				label = "Minutes",
				presets = { 10, 60, 240 },
				format = "minutes",
			},
		}, 3),
		withPlayer(function(player: Player, args)
			local untilTime = DefenseService.addShield(player, args.minutes * 60, "admin")
			return untilTime > 0, `Shield +{args.minutes} min for {player.Name}`
		end)
	)
	add(
		playerDef("AttackShieldOff", "Remove shield", "Turns their shield bubble off.", {}, 4),
		withPlayer(function(player: Player)
			DefenseService.clearShield(player)
			return true, `Shield removed for {player.Name}`
		end)
	)
	add(
		playerDef(
			"AttackLevels",
			"Set attack levels",
			"Stored AA / Launcher levels (they count once the pads are owned).",
			{
				aa = {
					kind = "integer",
					min = 0,
					max = AttackConfig.MaxLevel,
					label = "AA level",
					presets = { 1, 3, 5 },
				},
				launcher = {
					kind = "integer",
					min = 0,
					max = AttackConfig.MaxLevel,
					label = "Launcher level",
					presets = { 1, 3, 5 },
				},
			},
			5
		),
		withPlayer(function(player: Player, args)
			DefenseService.setLevels(player, args.aa, args.launcher)
			return true, `{player.Name}: AA {args.aa}, Launcher {args.launcher}`
		end)
	)
	add(
		playerDef("AttackBarrage", "Give Barrage nukes", "Adds stored Barrage nukes.", {
			count = {
				kind = "integer",
				min = 1,
				max = AttackConfig.MaxStoredBarrage,
				label = "Nukes",
				presets = { 20, 100 },
				format = "count",
			},
		}, 6),
		withPlayer(function(player: Player, args)
			local total = AttackService.giveBarrage(player, args.count)
			return total > 0, `{player.Name} now has {total} Barrage nukes`
		end)
	)
	add(
		playerDef("AttackHitsReset", "Reset hits", "Resets the free-shield hit counter.", {}, 7),
		withPlayer(function(player: Player)
			return AttackService.resetHits(player), `Hit counter reset for {player.Name}`
		end)
	)
	add(
		playerDef(
			"AttackTower",
			"Set defence tower",
			"One defence tower slot's level (0 = not bought, the BUY pad shows again).",
			{
				slot = {
					kind = "integer",
					min = 1,
					max = #AttackConfig.Towers.Slots,
					label = "Slot",
					presets = { 1, 2, 3 },
				},
				level = {
					kind = "integer",
					min = 0,
					max = AttackConfig.MaxLevel,
					label = "Level",
					presets = { 0, 1, 5 },
				},
			},
			8
		),
		withPlayer(function(player: Player, args)
			local done = DefenseService.setTowerLevel(player, args.slot, args.level)
			local slot = AttackConfig.Towers.Slots[args.slot]
			local name = if slot ~= nil then slot.name else `slot {args.slot}`
			return done, if done then `{player.Name}: {name} level {args.level}` else `{player.Name} is not loaded`
		end)
	)
	add(
		playerDef("AttackTowersAll", "Set all defence towers", "Every defence tower slot at one level (QA).", {
			level = {
				kind = "integer",
				min = 0,
				max = AttackConfig.MaxLevel,
				label = "Level",
				presets = { 0, 1, 5 },
			},
		}, 9),
		withPlayer(function(player: Player, args)
			local applied = DefenseService.setAllTowers(player, args.level)
			return applied,
				if applied
					then `{player.Name}: every defence tower level {args.level}`
					else `{player.Name} is not loaded`
		end)
	)
	add(
		playerDef("AttackGolden", "Give Golden Nukes", "Adds stored golden revenge nukes (owner R85, QA).", {
			count = {
				kind = "integer",
				min = 1,
				max = AttackConfig.Golden.MaxStored,
				label = "Nukes",
				presets = { 1, 5 },
				format = "count",
			},
		}, 10),
		withPlayer(function(player: Player, args)
			local total = AttackService.giveGolden(player, args.count)
			return total > 0, `{player.Name} now has {total} Golden Nukes`
		end)
	)
	add({
		name = "AttackStats",
		tab = "Attack",
		label = "Attack stats",
		description = "Nukes in flight and launched on this server.",
		target = "None",
		args = {},
		cooldown = 0.5,
		audited = false,
		confirm = false,
		color = "orange",
		order = 300,
	}, function(_ctx: Ctx): (boolean, string)
		local stats = AttackService.stats()
		local rivals = if DefenseService.rivalsEnabled() then "on" else "OFF"
		local towers = if DefenseService.towersEnabled() then "on" else "OFF"
		return true,
			`In flight {stats.inFlight} · launched {stats.launched} · toasts {stats.pendingToasts} · rivals {rivals} · tower shop {towers} · grace {DefenseService.graceSeconds()} s`
	end)
	-- Rival Factory kill switch (owner R43 NPC targets): live, this server only.
	add({
		name = "AttackRivals",
		tab = "Attack",
		label = "Rival Factories on/off",
		description = "Turns the Rival Factory NPC targets on or off on this server (islands stay as scenery).",
		target = "None",
		args = {
			on = { kind = "boolean", label = "Rivals on" },
		},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = 301,
	}, function(ctx: Ctx): (boolean, string)
		local on = ctx.args.on == true
		DefenseService.setRivalsEnabled(on)
		return true, if on then "Rival Factories are ON" else "Rival Factories are OFF on this server"
	end)
	-- New-player protection seconds (owner R85): live, this server only.
	add({
		name = "AttackGrace",
		tab = "Attack",
		label = "New-player protection",
		description = "Seconds of play before a player can be nuked (tutorial must be done too). This server, live.",
		target = "None",
		args = {
			seconds = {
				kind = "integer",
				min = 0,
				max = AttackConfig.NewPlayer.MaxGraceSeconds,
				label = "Seconds",
				presets = { 0, 300, 900 },
			},
		},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = 303,
	}, function(ctx: Ctx): (boolean, string)
		DefenseService.setGraceSeconds(ctx.args.seconds)
		return true, `New players are protected for {DefenseService.graceSeconds()} s of play on this server`
	end)
	-- Defence tower shop kill switch (owner R80): live, this server only.
	add({
		name = "AttackTowerShop",
		tab = "Attack",
		label = "Defence tower shop on/off",
		description = "Turns defence tower buys / upgrades on or off on this server (owned towers keep defending).",
		target = "None",
		args = {
			on = { kind = "boolean", label = "Tower shop on" },
		},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = 302,
	}, function(ctx: Ctx): (boolean, string)
		local on = ctx.args.on == true
		DefenseService.setTowersEnabled(on)
		return true, if on then "Defence tower shop is ON" else "Defence tower shop is OFF on this server"
	end)
	return true
end

return AttackAdmin
