--!strict
--[[
	RobloxLoader — loads REAL production modules from src/ under Lune, with just enough Roblox
	around them (pattern from RoBeasts' tests/change-notes.luau harness).

	Why: the pure-logic modules (ProfileLogic, ProfileStore, ProfileDelta, Validate, ...) require
	each other through Roblox instance paths (`script.Parent.X`,
	`game:GetService("ReplicatedStorage").Shared.Util.Signal`). This loader turns those paths into
	file paths, so tests run the shipped source unchanged:
		script                         → a path node for the module's own file
		node.Parent / node.Child        → the parent folder / a child path
		require(node)                   → loads "<path>.luau" (or "<path>/init.luau"), cached
		game:GetService(name)           → a stub table (ReplicatedStorage.Shared = src/shared,
		                                  ServerScriptService.Server = src/server, plus RunService /
		                                  HttpService / Players / Workspace stubs; overridable)
	Roblox datatypes (Vector3, Enum, Color3, ...) come from @lune/roblox; `task` from @lune/task.
	`warn` is captured into loader.warnings (and echoed only when LUNE_VERBOSE=1) so tests can
	assert on it without noisy output.

	Only top-level tests/*.luau files are suites (scripts/test-logic.sh); this folder holds helpers.

	Example:
		local Loader = require("./fixtures/RobloxLoader")
		local loader = Loader.new()
		local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

export type Loader = {
	load: (path: string) -> any,
	warnings: { string },
	services: { [string]: any },
}

local RobloxLoader = {}

-- The folder part of "a/b/c" ("a/b").
local function dirname(path: string): string
	return string.match(path, "^(.*)/[^/]+$") or ""
end

local nodeMeta = {}
-- A path node: indexing walks the tree; rawget(node, "__path") is its path.
local function node(path: string): any
	return setmetatable({ __path = path }, nodeMeta)
end
nodeMeta.__index = function(self: any, key: string): any
	local path = rawget(self, "__path")
	if key == "Parent" then
		return node(dirname(path))
	end
	return node(path .. "/" .. key)
end

RobloxLoader.node = node

--[[
	A deterministic stand-in for Roblox's `Random` (Lune's roblox library has none): a small LCG,
	so tests that touch randomness (e.g. ProfileStore's autosave jitter) are reproducible.
]]
RobloxLoader.Random = {
	new = function(seed: number?): any
		local state = math.floor(seed or 12345) % 2147483647
		if state <= 0 then
			state += 2147483646
		end
		local function step(): number
			state = (state * 48271) % 2147483647
			return state / 2147483647
		end
		return {
			NextNumber = function(_self: any, min: number?, max: number?): number
				local lo, hi = min or 0, max or 1
				return lo + (hi - lo) * step()
			end,
			NextInteger = function(_self: any, min: number, max: number): number
				return min + math.floor(step() * (max - min + 1))
			end,
		}
	end,
}

--[[
	Creates a loader with its own module cache.
	@param overrides service stubs replacing / adding to the defaults (by service name)
]]
function RobloxLoader.new(overrides: { [string]: any }?): Loader
	local guidCounter = 0
	local services: { [string]: any } = {
		ReplicatedStorage = { Shared = node("src/shared") },
		ServerScriptService = { Server = node("src/server") },
		Workspace = {},
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
		},
		HttpService = {
			GenerateGUID = function(_self: any, _braces: boolean?): string
				guidCounter += 1
				return string.format("00000000-0000-0000-0000-%012d", guidCounter)
			end,
		},
		Players = {
			GetPlayers = function()
				return {}
			end,
		},
	}
	for name, stub in overrides or {} do
		services[name] = stub
	end
	local game = {
		GetService = function(_self: any, name: string): any
			local service = services[name]
			if service == nil then
				error(`[RobloxLoader] no stub for service {name}`)
			end
			return service
		end,
	}
	local warnings: { string } = {}
	local verbose = process.env.LUNE_VERBOSE == "1"
	local cache: { [string]: any } = {}

	local loader: Loader
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
		if env.Random == nil then
			env.Random = RobloxLoader.Random
		end
		env.game = game
		env.script = node(path)
		env.task = task
		env.warn = function(...: any)
			local parts = {}
			for index = 1, select("#", ...) do
				parts[index] = tostring((select(index, ...)))
			end
			local text = table.concat(parts, " ")
			table.insert(warnings, text)
			if verbose then
				print("[warn] " .. text)
			end
		end
		env.require = function(target: any): any
			if type(target) == "table" and rawget(target, "__path") ~= nil then
				return load(rawget(target, "__path"))
			end
			error(`[RobloxLoader] unsupported require target in {path}`)
		end
		local chunk = luau.load(fs.readFile(file), {
			debugName = path,
			environment = env,
			injectGlobals = true,
		})
		local result = chunk()
		cache[path] = result
		return result
	end
	loader = { load = load, warnings = warnings, services = services }
	return loader
end

return RobloxLoader
