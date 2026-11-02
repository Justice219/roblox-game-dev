--!strict
--[[
	Admin command pipeline regressions (spec §14: re-auth → allowlist → cooldown → strict schema
	→ pcall handler → audit → result). Run:
		lune run tests/admin-pipeline

	Drives the shipped Server/Admin/{AdminPipeline, AdminRegistry, AdminAudit} with fake deps
	(no Roblox services) and proves:
	  1. A non-admin's call is dropped: no handler runs, no result is delivered, the audit gets ONE
	     "DENIED" entry per throttle window (an exploiter cannot flood the log); an authorize()
	     that throws also denies.
	  2. Unknown command names (incl. non-strings) are refused + audited (throttled).
	  3. Studio-only commands are refused on a live server; commands whose seam probe reports a
	     reason are refused with that reason; provider commands without a handler say "needs ...".
	  4. Per-admin per-command cooldown: blocks inside the window, allows after it, independent
	     per admin and per command.
	  5. Bad args are refused before target resolution / the handler.
	  6. Target errors are refused; the handler never runs.
	  7. A throwing handler → failure "internal error", audited, warned; a handler returning a
	     non-boolean → failure.
	  8. The audit ring is capped at AdminConfig.AuditLogSize; tail() is oldest-first.
	  9. registerCommand / registerHandler work end-to-end; clashes and bad defs error;
	     missingBuiltins lists unhandled built-ins; the catalogue hides Meta / Studio-only.
	 10. Order: the deny path never touches the cooldown table (a non-admin cannot burn an
	     admin's cooldown), and steps run in the documented order.
	 11. World "Vehicles on/off" (owner R56): catalogue shape, admin-only, strict boolean schema,
	     audited; the real handler (source) sets VehicleRouteConfig.EnabledAttribute, which the client
	     VehicleRoutes reads.
	 12. World* commands (owner R57 World 2, W4): admin-only, the `world` enum refuses "main" /
	     unknown ids / junk BEFORE the handler (WorldSend alone accepts "main"), every call audited,
	     the area / amount bounds hold, the shipped MultiWorldHandlers installs every World* command
	     with a seam probe where one is needed, and AdminService installs MultiWorldHandlers.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local AdminAudit = loader.load("src/server/Admin/AdminAudit")
local AdminConfig = loader.load("src/shared/Config/AdminConfig")
local AdminPipeline = loader.load("src/server/Admin/AdminPipeline")
local AdminRegistry = loader.load("src/server/Admin/AdminRegistry")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- A fresh world: registry with simple built-ins, a quiet audit, controllable clocks / auth.
local function world(options: { studio: boolean? }?)
	local opts = options or {}
	local state = {
		now = 100,
		wall = 1_800_000_000,
		admins = { [1] = true, [2] = true } :: { [number]: boolean },
		authThrows = false,
		delivered = {} :: { any },
		executed = {} :: { any },
		warnings = {} :: { string },
		handlerRuns = 0,
		targetCalls = 0,
		steps = {} :: { string },
		online = { [10] = true } :: { [number]: boolean },
	}
	local registry = AdminRegistry.new()
	local audit = AdminAudit.new({
		clock = function()
			return state.now
		end,
		time = function()
			return state.wall
		end,
		quiet = true,
	})
	-- Every built-in gets a handler that records the run.
	for _, name in AdminConfig.CommandNames do
		registry.setBuiltin(name, function(ctx: any): (boolean, string)
			state.handlerRuns += 1
			table.insert(state.steps, "handler")
			return true, `{name} ok for {ctx.target.label}`
		end)
	end
	local pipeline = AdminPipeline.new({
		registry = registry,
		audit = audit,
		authorize = function(caller: any): boolean
			table.insert(state.steps, "auth")
			if state.authThrows then
				error("group service down")
			end
			return state.admins[caller.userId] == true
		end,
		isStudio = function()
			return opts.studio == true
		end,
		now = function()
			return state.now
		end,
		resolveTarget = function(def: any, args: any): (any, string?)
			state.targetCalls += 1
			table.insert(state.steps, "target")
			if def.target == "None" then
				return { label = "" }, nil
			end
			if def.target == "Player" and not state.online[args.userId] then
				return nil, "that player is not in this server"
			end
			return { userId = args.userId, label = `user {args.userId}` }, nil
		end,
		deliver = function(caller: any, result: any)
			table.insert(state.delivered, { caller = caller.userId, result = result })
		end,
		onExecuted = function(caller: any, name: string, ok: boolean, message: string)
			table.insert(state.executed, { caller = caller.userId, name = name, ok = ok, message = message })
		end,
		warn = function(message: string)
			table.insert(state.warnings, message)
		end,
	})
	return state, registry, audit, pipeline
end

local admin = { userId = 1, name = "Owner" }
local admin2 = { userId = 2, name = "Mod" }
local hacker = { userId = 666, name = "Hacker" }

-- 1. Non-admins.
do
	local state, _, audit, pipeline = world()
	local result = pipeline.dispatchAsync(hacker, "GrantGems", { userId = 10, amount = 5 })
	check(not result.ok and result.message == "Not authorized", "non-admin refused")
	check(state.handlerRuns == 0 and state.targetCalls == 0, "non-admin: nothing ran")
	check(#state.delivered == 0, "non-admin: nothing delivered (silent drop)")
	check(audit.size() == 1, "non-admin: one audit entry")
	local entry = audit.tail(1)[1]
	check(entry.ok == false and string.find(entry.result, "DENIED", 1, true) ~= nil, "DENIED entry")
	check(entry.command == "GrantGems", "known name kept")
	for _ = 1, 50 do
		pipeline.dispatchAsync(hacker, "Ban", { userId = 1, durationSeconds = -1 })
		pipeline.dispatchAsync(hacker, "LolHax", {})
	end
	check(audit.size() == 1, "denied spam throttled inside the window")
	state.now += AdminConfig.DeniedLogIntervalSeconds + 1
	pipeline.dispatchAsync(hacker, "LolHax", {})
	check(audit.size() == 2 and audit.tail(1)[1].command == "<unknown>", "next window logs again, unknown name hidden")
	state.authThrows = true
	local thrown = pipeline.dispatchAsync(admin, "GrantGems", { userId = 10, amount = 5 })
	check(not thrown.ok and state.handlerRuns == 0, "authorize() throwing denies")
end

-- 2. Unknown command names.
do
	local state, _, audit, pipeline = world()
	local bads = table.pack("NotACommand", 42, nil, {}, "__index", "grantgems")
	for index = 1, bads.n do
		local bad = bads[index]
		local result = pipeline.dispatchAsync(admin, bad, {})
		check(not result.ok and result.message == "Unknown command", `unknown {tostring(bad)} refused`)
	end
	check(state.handlerRuns == 0, "unknown: no handler")
	check(audit.size() == 1, "unknown names audited once per window")
	check(#state.delivered == 6, "admin told about each unknown command")
end

-- 3. Studio-only + availability.
do
	local state, registry, _, pipeline = world({ studio = false })
	local result = pipeline.dispatchAsync(
		admin,
		"TestReceipt",
		{ product = AdminConfig.Commands.TestReceipt.args.product.values[1] }
	)
	check(not result.ok and string.find(result.message, "Studio only", 1, true) ~= nil, "studioOnly refused live")
	registry.setBuiltin("SetArea", function(): (boolean, string)
		state.handlerRuns += 1
		return true, "x"
	end, function(): string?
		return "needs Tycoon (B5 TycoonAdmin)"
	end)
	local refused = pipeline.dispatchAsync(admin, "SetArea", { userId = 10, area = 2 })
	check(not refused.ok and string.find(refused.message, "needs Tycoon", 1, true) ~= nil, "probe reason refuses")
	check(state.handlerRuns == 0, "unavailable: no handler")
	check(registry.availability("SetArea", false) == "needs Tycoon (B5 TycoonAdmin)", "availability reason")
	check(registry.availability("TestReceipt", true) == "", "studioOnly fine in Studio")
	check(registry.availability("TestReceipt", false) == "Studio only", "studioOnly reason live")

	-- A provider command with NO handler at all says "needs <provider>".
	local bare = AdminRegistry.new()
	check(string.find(bare.availability("GrantSpins", true), "needs Retention", 1, true) ~= nil, "needs provider")
	check(bare.availability("Kick", true) == "not available", "built-in without handler")
	local missing = bare.missingBuiltins()
	check(
		table.find(missing, "Kick") ~= nil and table.find(missing, "GrantSpins") == nil,
		"missingBuiltins skips provider commands"
	)
end

-- 4. Cooldowns.
do
	local state, _, _, pipeline = world()
	local cooldown = AdminConfig.Commands.Kick.cooldown
	check(pipeline.dispatchAsync(admin, "Kick", { userId = 10 }).ok, "first kick runs")
	local blocked = pipeline.dispatchAsync(admin, "Kick", { userId = 10 })
	check(
		not blocked.ok and string.find(blocked.message, "wait", 1, true) ~= nil,
		"second kick inside cooldown blocked"
	)
	check(state.handlerRuns == 1, "blocked call ran no handler")
	check(pipeline.dispatchAsync(admin2, "Kick", { userId = 10 }).ok, "another admin has their own cooldown")
	check(pipeline.dispatchAsync(admin, "Bring", { userId = 10 }).ok, "another command has its own cooldown")
	state.now += cooldown + 0.01
	check(pipeline.dispatchAsync(admin, "Kick", { userId = 10 }).ok, "after the window it runs again")
	pipeline.forget(1)
	check(pipeline.dispatchAsync(admin, "Kick", { userId = 10 }).ok, "forget clears the cooldown")
end

-- 5 + 6. Bad args and bad targets.
do
	local state, _, audit, pipeline = world()
	local bad = pipeline.dispatchAsync(admin, "GrantGems", { userId = 10, amount = 0 / 0 })
	check(not bad.ok and string.find(bad.message, "amount", 1, true) ~= nil, "NaN amount refused")
	check(state.targetCalls == 0 and state.handlerRuns == 0, "bad args stop before target / handler")
	check(audit.size() == 1 and audit.tail(1)[1].args == "<rejected>", "rejected args audited without echoing them")
	state.now += 5
	local extra = pipeline.dispatchAsync(admin, "GrantGems", { userId = 10, amount = 5, evil = true })
	check(not extra.ok and string.find(extra.message, "unexpected", 1, true) ~= nil, "extra arg refused")
	state.now += 5
	local offline = pipeline.dispatchAsync(admin, "GrantGems", { userId = 99, amount = 5 })
	check(
		not offline.ok and string.find(offline.message, "not in this server", 1, true) ~= nil,
		"offline target refused"
	)
	check(state.handlerRuns == 0, "target error: no handler")
end

-- 7. Handler failures.
do
	local state, registry, audit, pipeline = world()
	registry.setBuiltin("Announce", function(): (boolean, string)
		error("boom")
	end)
	local thrown = pipeline.dispatchAsync(admin, "Announce", { text = "hi" })
	check(not thrown.ok and string.find(thrown.message, "internal error", 1, true) ~= nil, "throw → internal error")
	check(#state.warnings == 1, "throw warned")
	check(audit.tail(1)[1].ok == false and audit.tail(1)[1].command == "Announce", "throw audited")
	registry.setBuiltin(
		"SetTimeOfDay",
		function(): any
			return "yes"
		end :: any
	)
	local weird = pipeline.dispatchAsync(admin, "SetTimeOfDay", { hour = 12 })
	check(not weird.ok, "non-boolean handler result = failure")
	registry.setBuiltin("CancelShutdown", function(): (boolean, string)
		return false, string.rep("z", 500) .. "\n"
	end)
	local long = pipeline.dispatchAsync(admin, "CancelShutdown", {})
	check(not long.ok and utf8.len(long.message) :: number <= 161, "messages capped")
	check(state.delivered[#state.delivered].result.ok == false, "failure delivered to the caller")
	check(#state.executed == 3, "onExecuted fired for each executed command")
end

-- 8. Audit ring.
do
	local audit = AdminAudit.new({ quiet = true, size = 5 })
	for index = 1, 12 do
		audit.append(admin, "Cmd", `i={index}`, true, "ok")
	end
	check(audit.size() == 5, "ring capped")
	local tail = audit.tail()
	check(tail[1].args == "i=8" and tail[5].args == "i=12", "oldest first, newest kept")
	check(audit.version() == 12, "version counts appends")
	local seen = 0
	audit.onAppend(function()
		seen += 1
	end)
	audit.onAppend(function()
		error("listener bug")
	end)
	audit.append(admin, "Cmd", "", true, "ok")
	check(seen == 1, "listeners run; a broken one does not stop the append")
	local default = AdminAudit.new({ quiet = true })
	for _ = 1, AdminConfig.AuditLogSize + 25 do
		default.append(admin, "Cmd", "", true, "ok")
	end
	check(default.size() == AdminConfig.AuditLogSize, "default ring = AuditLogSize")
end

-- 9. Registration.
do
	local state, registry, _, pipeline = world({ studio = true })
	local before = registry.version()
	local live = registry.registerCommand({
		name = "GivePet",
		tab = "Players",
		label = "Give Pet",
		target = "Player",
		args = { petId = { kind = "enum", values = { "Cat", "Dog" } } },
		cooldown = 1,
		audited = true,
		confirm = false,
	}, function(ctx: any): (boolean, string)
		state.handlerRuns += 1
		return true, `gave {ctx.args.petId}`
	end)
	check(registry.version() > before, "registration bumps the catalogue version")
	check(table.isfrozen(live), "registered def frozen")
	local result = pipeline.dispatchAsync(admin, "GivePet", { userId = 10, petId = "Dog" })
	check(result.ok and result.message == "gave Dog", "registered command runs end-to-end")
	check(
		not pipeline.dispatchAsync(admin, "GivePet", { userId = 10, petId = "Dragon" }).ok,
		"registered schema enforced"
	)
	check(not pcall(registry.registerCommand, { name = "GivePet" }, function() end), "bad / clashing def errors")
	check(not pcall(registry.registerCommand, {
		name = "Kick",
		tab = "Players",
		label = "Kick2",
		target = "None",
		args = {},
		cooldown = 1,
		audited = true,
		confirm = false,
	}, function() end), "built-in name clash errors")
	check(not pcall(registry.registerHandler, "Kick", function() end), "registerHandler refuses non-provider commands")
	check(
		pcall(registry.registerHandler, "GrantSpins", function(): (boolean, string)
			return true, "provided"
		end),
		"registerHandler accepts provider commands"
	)
	state.now += 10
	check(
		pipeline.dispatchAsync(admin, "GrantSpins", { userId = 10, count = 3 }).message == "provided",
		"provided handler wins"
	)
	local catalog = registry.catalog(false)
	local names: { [string]: any } = {}
	for _, info in catalog do
		names[info.name] = info
	end
	check(names.RequestState == nil, "catalogue hides Meta")
	check(names.TestReceipt == nil, "catalogue hides Studio-only live")
	check(names.GivePet ~= nil and names.GivePet.registered == true, "catalogue lists registered commands")
	check(names.Kick ~= nil and names.Kick.registered == false and names.Kick.confirm == true, "catalogue built-in")
	check(#names.Ban.argOrder == 2 and names.Ban.argOrder[1] == "durationSeconds", "argOrder carried")
	check(registry.catalog(true)[1] ~= nil, "catalogue in Studio")
end

-- 10. Order of steps.
do
	local state, _, _, pipeline = world()
	pipeline.dispatchAsync(admin, "GrantGems", { userId = 10, amount = 5 })
	check(table.concat(state.steps, ",") == "auth,target,handler", "auth → target → handler")
	table.clear(state.steps)
	state.admins[1] = nil
	pipeline.dispatchAsync(admin, "GrantGems", { userId = 10, amount = 5 })
	check(table.concat(state.steps, ",") == "auth", "revoked admin stops at auth")
	state.admins[1] = true
	-- The denied call above must not have consumed the cooldown... it did not reach step 4,
	-- but the first call did: wait it out, then a fresh call runs.
	state.now += 1
	check(pipeline.dispatchAsync(admin, "GrantGems", { userId = 10, amount = 5 }).ok, "re-granted admin runs again")
	-- A non-admin spamming a command never touches an admin's cooldown.
	for _ = 1, 10 do
		pipeline.dispatchAsync(hacker, "Kick", { userId = 10 })
	end
	check(pipeline.dispatchAsync(admin, "Kick", { userId = 10 }).ok, "hacker spam cannot burn the admin cooldown")
end

-- 11. World "Vehicles on/off" (owner R56, V1): rule 9 admin control of the map vehicles.
do
	local fs = require("@lune/fs")
	local VehicleRouteConfig = loader.load("src/shared/Config/VehicleRouteConfig")
	local def = AdminConfig.Commands.VehiclesToggle
	check(def ~= nil and def.tab == "World" and def.target == "None", "VehiclesToggle: World tab, no target")
	check(def.audited == true and def.provider == nil, "VehiclesToggle: audited, built into AdminService")
	check(
		def.args.on ~= nil and def.args.on.kind == "boolean" and def.args.on.default == true,
		"VehiclesToggle: boolean `on`"
	)
	local state, _, audit, pipeline = world()
	local denied = pipeline.dispatchAsync(hacker, "VehiclesToggle", { on = false })
	check(not denied.ok and state.handlerRuns == 0, "VehiclesToggle: non-admin refused, nothing ran")
	local before = audit.size()
	for _, bad in { { on = "off" }, { on = 0 }, { on = false, extra = 1 } } do
		local result = pipeline.dispatchAsync(admin, "VehiclesToggle", bad)
		check(
			not result.ok and state.handlerRuns == 0,
			"VehiclesToggle: non-boolean / extra args refused before the handler"
		)
		state.now += def.cooldown + 0.1 -- the cooldown step runs before the schema step
	end
	local ran = pipeline.dispatchAsync(admin, "VehiclesToggle", { on = false })
	check(ran.ok and state.handlerRuns == 1, "VehiclesToggle: admin call runs the handler")
	check(audit.size() > before and audit.tail(1)[1].command == "VehiclesToggle", "VehiclesToggle: audited")
	-- The shipped handler + client agree on the attribute (no Roblox services needed).
	local handlers = fs.readFile("src/server/Admin/Handlers/WorldHandlers.luau")
	check(
		string.find(handlers, 'registry.setBuiltin("VehiclesToggle", vehicles)', 1, true) ~= nil,
		"WorldHandlers installs VehiclesToggle"
	)
	check(
		string.find(handlers, "ReplicatedStorage:SetAttribute(VehicleRouteConfig.EnabledAttribute, on)", 1, true) ~= nil,
		"VehiclesToggle sets the shared EnabledAttribute"
	)
	local client = fs.readFile("src/client/Tycoon/Fx/VehicleRoutes.luau")
	check(
		string.find(client, "VehicleRouteConfig.EnabledAttribute", 1, true) ~= nil,
		"VehicleRoutes reads the same attribute"
	)
	check(VehicleRouteConfig.EnabledAttribute == "VehiclesEnabled", "attribute name is VehiclesEnabled")
end

-- 12. World* commands (owner R57 World 2, W4 MultiWorldHandlers).
do
	local fs = require("@lune/fs")
	local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
	local dino = WorldsConfig.get("dino")
	assert(dino ~= nil, "Dino Valley registered")
	local state, _, audit, pipeline = world()
	-- One valid call per command (target player 10 is online).
	local good: { [string]: { [string]: any } } = {
		WorldUnlock = { userId = 10, world = "dino" },
		WorldRelock = { userId = 10, world = "dino" },
		WorldSetArea = { userId = 10, world = "dino", area = dino.geometry.areaCount },
		WorldUnlockAll = { userId = 10, world = "dino" },
		WorldResetRun = { userId = 10, world = "dino" },
		WorldWipe = { userId = 10, world = "dino" },
		WorldGrantCash = { userId = 10, world = "dino", amount = 1e6 },
		WorldSetCash = { userId = 10, world = "dino", amount = 0 },
		WorldSetRebirths = { userId = 10, world = "dino", rebirths = 3 },
		WorldGrantTokens = { userId = 10, world = "dino", amount = 100 },
		WorldSend = { userId = 10, world = "main", to = "spawn" },
		WorldRebuildPlot = { userId = 10, world = "dino", replay = true },
		WorldOfflinePreview = { userId = 10, hours = 8 },
		WorldEnabled = { world = "dino", on = false },
	}
	local runs = 0
	for name, args in good do
		local def = AdminConfig.Commands[name]
		check(def ~= nil, `{name}: declared`)
		check(def.audited == true, `{name}: audited (spec §13 "every command audited")`)
		check(def.provider == "Worlds (W4 MultiWorldHandlers)", `{name}: provider`)
		-- Non-admins never reach the handler.
		local denied = pipeline.dispatchAsync(hacker, name, args)
		check(not denied.ok and state.handlerRuns == runs, `{name}: non-admin refused`)
		-- The world enum: "main" (except WorldSend), unknown ids and junk are refused first.
		if args.world ~= nil then
			local bads: { any } = { "nope", "Dino", 5, true, "", string.rep("d", 40) }
			if name ~= "WorldSend" then
				table.insert(bads, "main")
			end
			for _, bad in bads do
				local trial = table.clone(args)
				trial.world = bad
				local result = pipeline.dispatchAsync(admin, name, trial)
				check(
					not result.ok and state.handlerRuns == runs,
					`{name}: world {tostring(bad)} refused before the handler`
				)
				state.now += def.cooldown + 0.1
			end
		end
		local before = audit.size()
		local ran = pipeline.dispatchAsync(admin, name, args)
		runs += 1
		check(ran.ok and state.handlerRuns == runs, `{name}: admin call runs the handler`)
		check(audit.size() > before and audit.tail(1)[1].command == name, `{name}: audited`)
		state.now += def.cooldown + 0.1
	end
	-- Bounds: area past the largest world, zero / negative amounts, fractional rebirths.
	local function refused(name: string, args: { [string]: any }, label: string)
		local result = pipeline.dispatchAsync(admin, name, args)
		check(not result.ok and state.handlerRuns == runs, label)
		state.now += AdminConfig.Commands[name].cooldown + 0.1
	end
	refused(
		"WorldSetArea",
		{ userId = 10, world = "dino", area = dino.geometry.areaCount + 1 },
		"area above every world refused"
	)
	refused("WorldSetArea", { userId = 10, world = "dino", area = 0 }, "area 0 refused")
	refused("WorldGrantCash", { userId = 10, world = "dino", amount = 0 }, "grant 0 refused")
	refused("WorldGrantCash", { userId = 10, world = "dino", amount = 0 / 0 }, "grant NaN refused")
	refused("WorldSetCash", { userId = 10, world = "dino", amount = -1 }, "negative balance refused")
	refused("WorldSetRebirths", { userId = 10, world = "dino", rebirths = 1.5 }, "fractional rebirths refused")
	refused("WorldGrantTokens", { userId = 10, world = "dino", amount = 2.5 }, "fractional tokens refused")
	refused("WorldSend", { userId = 10, world = "dino", to = "moon" }, "unknown destination refused")
	refused("WorldEnabled", { world = "dino", on = "off" }, "non-boolean switch refused")
	refused("WorldUnlock", { userId = 99, world = "dino" }, "offline target refused")
	-- Destructive commands confirm in the panel.
	for _, name in { "WorldRelock", "WorldResetRun", "WorldWipe", "WorldSetCash", "WorldEnabled" } do
		check(AdminConfig.Commands[name].confirm == true, `{name}: confirms`)
	end
	check(
		AdminConfig.Commands.WorldResetRun.color == "red" and AdminConfig.Commands.WorldWipe.color == "red",
		"wipes are red"
	)
	check(
		AdminConfig.Commands.WorldEnabled.tab == "Server" and AdminConfig.Commands.WorldEnabled.target == "None",
		"kill switch: Server tab, no target"
	)
	-- The shipped handler module installs every World* command; AdminService installs it.
	local source = fs.readFile("src/server/Admin/Handlers/MultiWorldHandlers.luau")
	for name in good do
		check(string.find(source, `registry.setBuiltin("{name}"`, 1, true) ~= nil, `MultiWorldHandlers installs {name}`)
	end
	for _, seam in
		{
			"worldSetArea",
			"worldUnlockAll",
			"worldResetRun",
			"worldWipe",
			"worldSetRebirths",
			"worldRebuildPlot",
			"offlinePreview",
		}
	do
		check(
			string.find(source, `tycoonProbe("{seam}")`, 1, true) ~= nil,
			`TycoonAdmin.{seam} is probed (greyed while missing)`
		)
	end
	local service = fs.readFile("src/server/Services/AdminService.luau")
	check(
		string.find(service, "MultiWorldHandlers.install(registry, env)", 1, true) ~= nil,
		"AdminService installs MultiWorldHandlers"
	)
	local seams = fs.readFile("src/server/Admin/Seams.luau")
	check(
		string.find(seams, 'lookup("Tycoon", "WorldService")', 1, true) ~= nil,
		"Seams.worldService looks up Tycoon/WorldService"
	)
end

print(`[admin-pipeline] {checks} checks passed`)
