--!strict
--[[
	analytics-fixtures/Loader — loads the REAL analytics modules from src/ under Lune with just
	enough Roblox around them (same idea as tests/fixtures/RobloxLoader, plus what the analytics
	layer needs): fake Player instances (typeof → "Instance", attributes + changed signals),
	controllable os.time / os.clock (multi-day retention tests), JSON via @lune/serde, and stubs
	for Players, DataStoreService, MarketplaceService, Stats, Roblox's AnalyticsService (records
	every forwarded call) and ServerScriptService.

	Also used by tests/world-currency-isolation.luau (owner R60), which boots REAL server services
	(PlayerDataService, TycoonService, RebirthService, OfflineService) with three opt-in extras:
		options.lenientServices   unknown services resolve to empty tables instead of erroring
		env.stub(path, module)    pre-seeds the module cache (heavy world / build modules)
		env.close()               runs every game:BindToClose callback (ends service loops)
	The fake player also answers FindFirstChild (Character / leaderstats lookups) and Kick.
	env.game is the fake DataModel: a test may set server facts on it (owner R122 co-play reads
	game.PrivateServerOwnerId; unset = a public server).

	Not a suite: scripts/test-logic.sh only runs top-level tests/*.luau files.

	Example:
		local Loader = require("./analytics-fixtures/Loader")
		local env = Loader.new()
		local AnalyticsLogic = env.load("src/server/Analytics/AnalyticsLogic")
		local player = env.player(101)
		env.setTime(20380 * 86400 + 3600)
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local SharedLoader = require("../fixtures/RobloxLoader")

export type Signal = {
	Connect: (any, (...any) -> ()) -> { Disconnect: (any) -> () },
	Once: (any, (...any) -> ()) -> { Disconnect: (any) -> () },
	Fire: (any, ...any) -> (),
}

local Loader = {}

-- The folder part of "a/b/c" ("a/b").
local function dirname(path: string): string
	return string.match(path, "^(.*)/[^/]+$") or ""
end

local nodeMeta = {}
local function node(path: string): any
	return setmetatable({ __path = path }, nodeMeta)
end
nodeMeta.__index = function(self: any, key: string): any
	local path = rawget(self, "__path")
	if key == "Parent" then
		return node(dirname(path))
	end
	if key == "FindFirstChild" then
		return function(_self: any, _name: string): any
			return nil -- optional modules (VersionConfig, AdminService) are "not shipped" in tests
		end
	end
	return node(path .. "/" .. key)
end

--[[ A minimal Roblox-style signal (Connect / Once / Fire). ]]
function Loader.signal(): Signal
	local listeners: { (...any) -> () } = {}
	local signal = {}
	function signal.Connect(_self: any, fn: (...any) -> ())
		table.insert(listeners, fn)
		return {
			Disconnect = function()
				local index = table.find(listeners, fn)
				if index ~= nil then
					table.remove(listeners, index)
				end
			end,
		}
	end
	function signal.Once(self: any, fn: (...any) -> ())
		local connection
		connection = signal.Connect(self, function(...)
			connection.Disconnect()
			fn(...)
		end)
		return connection
	end
	function signal.Fire(_self: any, ...: any)
		for _, fn in table.clone(listeners) do
			fn(...)
		end
	end
	return signal :: any
end

export type Env = {
	load: (path: string) -> any,
	services: { [string]: any },
	warnings: { string },
	forwarded: { { kind: string, args: { any } } },
	players: { any },
	player: (userId: number) -> any,
	removePlayer: (player: any) -> (),
	setTime: (unix: number?) -> (),
	setClock: (seconds: number?) -> (),
	advance: (seconds: number) -> (),
	stub: (path: string, module: any) -> (),
	close: () -> (),
	-- The fake DataModel `game` (tests set server facts on it, e.g. R122's PrivateServerOwnerId).
	game: any,
}

export type Options = { lenientServices: boolean? }

--[[
	Creates an isolated environment (own module cache, own fake players and clocks).
	@param overrides service stubs replacing / adding to the defaults (by service name)
	@param options   opt-in extras (see the header); existing suites pass nothing
]]
function Loader.new(overrides: { [string]: any }?, options: Options?): Env
	local fakeTime: number? = nil
	local fakeClock: number? = nil
	local warnings: { string } = {}
	local forwarded: { { kind: string, args: { any } } } = {}
	local players: { any } = {}
	local playersService: any = {
		PlayerAdded = Loader.signal(),
		PlayerRemoving = Loader.signal(),
		GetPlayers = function()
			return table.clone(players)
		end,
		GetPlayerByUserId = function(_self: any, userId: number)
			for _, p in players do
				if p.UserId == userId then
					return p
				end
			end
			return nil
		end,
	}
	local function recordForward(kind: string)
		return function(_self: any, ...: any)
			table.insert(forwarded, { kind = kind, args = table.pack(...) })
		end
	end
	local services: { [string]: any } = {
		ReplicatedStorage = setmetatable({}, {
			__index = function(_self: any, key: string): any
				if key == "Shared" then
					return node("src/shared")
				elseif key == "FindFirstChild" then
					return function()
						return nil
					end
				end
				return nil
			end,
		}),
		ServerScriptService = {
			Server = node("src/server"),
			FindFirstChild = function()
				return nil
			end,
		},
		Workspace = { Terrain = {
			GetDescendants = function()
				return {}
			end,
		} },
		RunService = {
			IsStudio = function()
				return true
			end,
			IsServer = function()
				return true
			end,
			IsClient = function()
				return false
			end,
			Heartbeat = Loader.signal(),
			PreRender = Loader.signal(),
		},
		HttpService = {
			JSONEncode = function(_self: any, value: any): string
				return serde.encode("json", value)
			end,
			JSONDecode = function(_self: any, value: string): any
				return serde.decode("json", value)
			end,
			GenerateGUID = (function()
				local n = 0
				return function(): string
					n += 1
					return string.format("00000000-0000-0000-0000-%012d", n)
				end
			end)(),
		},
		Players = playersService,
		DataStoreService = {},
		MarketplaceService = {
			GetProductInfoAsync = function()
				return { PriceInRobux = 99 }
			end,
		},
		Stats = {},
		AnalyticsService = {
			LogEconomyEvent = recordForward("economy"),
			LogFunnelStepEvent = recordForward("funnel"),
			LogOnboardingFunnelStepEvent = recordForward("onboarding"),
			LogProgressionEvent = recordForward("progression"),
			LogCustomEvent = recordForward("custom"),
		},
		UserInputService = {},
	}
	for name, stub in overrides or {} do
		services[name] = stub
	end
	local lenient = options ~= nil and options.lenientServices == true
	local closers: { () -> () } = {}
	local game: any = {
		GetService = function(_self: any, name: string): any
			local service = services[name]
			if service == nil then
				if lenient then
					service = {}
					services[name] = service
				else
					error(`[analytics Loader] no stub for service {name}`)
				end
			end
			return service
		end,
		BindToClose = function(_self: any, callback: () -> ())
			table.insert(closers, callback)
		end,
		PlaceVersion = 0,
		PlaceId = 0,
		JobId = "",
		CreatorId = 0,
	}

	-- Controllable clocks (nil = the real one).
	local fakeOs = setmetatable({
		time = function(t: any?): number
			if t ~= nil then
				return os.time(t)
			end
			return fakeTime or os.time()
		end,
		clock = function(): number
			return fakeClock or os.clock()
		end,
	}, { __index = os })

	local function isFake(value: any): boolean
		return type(value) == "table" and rawget(value, "__fakeInstance") == true
	end
	local realTypeof = roblox.typeof or typeof
	local function fakeTypeof(value: any): string
		if isFake(value) then
			return "Instance"
		end
		return realTypeof(value)
	end

	local cache: { [string]: any } = {}
	local function load(path: string): any
		local cached = cache[path]
		if cached ~= nil then
			return cached
		end
		local file = path .. ".luau"
		if not fs.isFile(file) then
			file = path .. "/init.luau"
		end
		local env: { [string]: any } = table.clone(roblox) :: any
		env.game = game
		env.script = node(path)
		env.task = task
		env.os = fakeOs
		env.typeof = fakeTypeof
		-- Lune has no Roblox `Random`: the shared fixture's deterministic LCG stands in.
		if env.Random == nil then
			env.Random = SharedLoader.Random
		end
		env.warn = function(...: any)
			local parts = {}
			for index = 1, select("#", ...) do
				parts[index] = tostring((select(index, ...)))
			end
			table.insert(warnings, table.concat(parts, " "))
		end
		env.require = function(target: any): any
			if type(target) == "table" and rawget(target, "__path") ~= nil then
				return load(rawget(target, "__path"))
			end
			error(`[analytics Loader] unsupported require target in {path}`)
		end
		local chunk = luau.load(fs.readFile(file), { debugName = path, environment = env, injectGlobals = true })
		local result = chunk()
		cache[path] = result
		return result
	end

	--[[ A fake connected Player (typeof → "Instance"). ]]
	local function player(userId: number): any
		local attributes: { [string]: any } = {}
		local changed: { [string]: Signal } = {}
		local p: any = {
			__fakeInstance = true,
			UserId = userId,
			Name = `Player{userId}`,
			DisplayName = `Player{userId}`,
			FollowUserId = 0,
			Parent = playersService,
			joinData = {},
			Character = nil,
			children = {},
		}
		-- Named children a test hangs on the player (leaderstats, ...); nil = none.
		function p.FindFirstChild(self: any, name: string): any
			return self.children[name]
		end
		function p.Kick(self: any, _message: string?)
			self.kicked = true
		end
		function p.IsA(_self: any, className: string): boolean
			return className == "Player" or className == "Instance"
		end
		function p.GetAttribute(_self: any, name: string): any
			return attributes[name]
		end
		function p.SetAttribute(_self: any, name: string, value: any)
			attributes[name] = value
			local signal = changed[name]
			if signal ~= nil then
				signal:Fire()
			end
		end
		function p.GetAttributeChangedSignal(_self: any, name: string): Signal
			local signal = changed[name]
			if signal == nil then
				signal = Loader.signal()
				changed[name] = signal
			end
			return signal
		end
		function p.GetJoinData(self: any): any
			return self.joinData
		end
		function p.IsFriendsWithAsync(): boolean
			return false
		end
		function p.GetNetworkPing(): number
			return 0.05
		end
		table.insert(players, p)
		return p
	end

	local function removePlayer(p: any)
		local index = table.find(players, p)
		if index ~= nil then
			table.remove(players, index)
		end
		p.Parent = nil
	end

	return {
		load = load,
		services = services,
		warnings = warnings,
		forwarded = forwarded,
		players = players,
		player = player,
		removePlayer = removePlayer,
		setTime = function(unix: number?)
			fakeTime = unix
		end,
		setClock = function(seconds: number?)
			fakeClock = seconds
		end,
		advance = function(seconds: number)
			fakeClock = (fakeClock or os.clock()) + seconds
			if fakeTime ~= nil then
				fakeTime += seconds
			end
		end,
		stub = function(path: string, module: any)
			cache[path] = module
		end,
		close = function()
			for _, callback in closers do
				task.spawn(callback)
			end
			table.clear(closers)
		end,
		game = game,
	}
end

--[[ A tiny assertion helper shared by the analytics suites. ]]
function Loader.checker(): ((boolean, string) -> (), (string) -> ())
	local count = 0
	local function check(ok: boolean, message: string)
		if not ok then
			error(message, 2)
		end
		count += 1
	end
	local function done(name: string)
		print(`[{name}] {count} checks passed`)
	end
	return check, done
end

return Loader
