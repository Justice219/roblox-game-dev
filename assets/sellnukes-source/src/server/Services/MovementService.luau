--!strict
--[[
	MovementService — server-authoritative run speed and jump (owner R21: "make the player run
	faster, they feel a little too slow").

	What it does:
		- Every character (CharacterAdded, and players already in game at Start) gets
		  WalkSpeed = MovementConfig.walkSpeedFor(active multipliers) and JumpPower.
		- Multipliers: owned game passes in MovementConfig.Passes (FastWalk ×1.35; re-applied on
		  MonetizationService.PassChanged), active personal boosts in
		  MovementConfig.BoostWalkMultipliers (BoostService.secondsLeft, guarded lazy require; empty
		  today) and server sources set with `setMultiplier` (admin tools, future events).
		- If another SERVER script changes the Humanoid's WalkSpeed / JumpPower, ours is put back
		  (one property-changed connection per humanoid, removed with the character).
	Authority: the server sets the values and they replicate to the owning client. A client cannot
	change the server's value (property writes do not replicate client → server); an exploiter's
	local change only affects their own simulation, which is out of scope here (no physics
	anti-cheat, per the R21 brief).

	Public API (server):
		MovementService.refresh(player)                          re-apply now
		MovementService.setMultiplier(player, sourceId, value?)  set / clear (nil) a speed source
		MovementService.walkSpeedOf(player) → number             the speed this service applies

	Boot: feature service "MovementService" (after MonetizationService; BoostService optional).

	Example:
		MovementService.setMultiplier(player, "adminTurbo", 2)   -- doubles the run speed
		MovementService.setMultiplier(player, "adminTurbo", nil) -- back to normal
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConfig = require(ReplicatedStorage.Shared.Config.MovementConfig)

local MovementService = {}

-- MonetizationService / BoostService once resolved (guarded: movement works without either).
local monetization: any = nil
local boosts: any = nil
-- Server speed sources per player: sourceId → multiplier (strong keys; cleared on leave).
local sources: { [Player]: { [string]: number } } = {}
-- The humanoid connections guarding our values, per player (replaced on respawn).
local guards: { [Player]: { RBXScriptConnection } } = {}
local started = false

local MAX_SOURCES = 16 -- per player; setMultiplier refuses more distinct ids

-- A guarded require of a sibling service (nil when missing or broken).
local function service(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, value = pcall(require, module)
	return if ok and type(value) == "table" then value else nil
end

--[[ Every active multiplier of the player (passes, boosts, server sources). Never yields. ]]
local function multipliersOf(player: Player): { number }
	local out: { number } = {}
	if monetization ~= nil then
		for passKey, multiplier in MovementConfig.Passes do
			local ok, owns = pcall(monetization.ownsPass, player, passKey)
			if ok and owns == true then
				table.insert(out, multiplier)
			end
		end
	end
	if boosts ~= nil then
		for boostKey, multiplier in MovementConfig.BoostWalkMultipliers do
			local ok, left = pcall(boosts.secondsLeft, player, boostKey)
			if ok and type(left) == "number" and left > 0 then
				table.insert(out, multiplier)
			end
		end
	end
	for _, multiplier in sources[player] or {} do
		table.insert(out, multiplier)
	end
	return out
end

--[[ The WalkSpeed this service applies to `player` right now. ]]
function MovementService.walkSpeedOf(player: Player): number
	return MovementConfig.walkSpeedFor(multipliersOf(player))
end

-- Writes our values onto a humanoid (only when they differ: no needless replication).
local function applyTo(humanoid: Humanoid, walkSpeed: number)
	if humanoid.WalkSpeed ~= walkSpeed then
		humanoid.WalkSpeed = walkSpeed
	end
	if humanoid.UseJumpPower ~= MovementConfig.UseJumpPower then
		humanoid.UseJumpPower = MovementConfig.UseJumpPower
	end
	if humanoid.JumpPower ~= MovementConfig.JumpPower then
		humanoid.JumpPower = MovementConfig.JumpPower
	end
end

--[[ Re-applies the player's run speed / jump to their current character (no-op without one). ]]
function MovementService.refresh(player: Player)
	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid ~= nil then
		applyTo(humanoid, MovementService.walkSpeedOf(player))
	end
end

--[[
	Sets (value) or clears (nil) one server speed source of the player and re-applies. Values are
	clamped to (0, MaxSourceMultiplier]; non-finite / non-positive values clear the source.
	@return true when the source was stored or cleared
]]
function MovementService.setMultiplier(player: Player, sourceId: string, value: number?): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") or type(sourceId) ~= "string" or #sourceId > 32 then
		return false
	end
	local map = sources[player]
	if value == nil or type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
		if map ~= nil then
			map[sourceId] = nil
		end
	else
		if map == nil then
			map = {}
			sources[player] = map
		end
		if map[sourceId] == nil then
			local n = 0
			for _ in map do
				n += 1
			end
			if n >= MAX_SOURCES then
				return false
			end
		end
		map[sourceId] = math.min(value, MovementConfig.MaxSourceMultiplier)
	end
	MovementService.refresh(player)
	return true
end

-- A new character: apply, then guard the values against other server scripts.
local function onCharacter(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
	if humanoid == nil or not humanoid:IsA("Humanoid") or player.Character ~= character then
		return
	end
	local function release(list: { RBXScriptConnection }?)
		for _, connection in list or {} do
			connection:Disconnect()
		end
	end
	release(guards[player])
	applyTo(humanoid, MovementService.walkSpeedOf(player))
	local function restore()
		-- Deferred: never fights a write inside the same frame; re-reads the live value.
		task.defer(function()
			if humanoid.Parent ~= nil and player.Character == character then
				applyTo(humanoid, MovementService.walkSpeedOf(player))
			end
		end)
	end
	local list = {
		humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(restore),
		humanoid:GetPropertyChangedSignal("JumpPower"):Connect(restore),
	}
	guards[player] = list
	humanoid.Destroying:Once(function()
		release(list)
		if guards[player] == list then
			guards[player] = nil
		end
	end)
end

local function onPlayer(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		onCharacter(player, character)
	end)
	if player.Character ~= nil then
		task.spawn(onCharacter, player, player.Character)
	end
end

function MovementService.Init() end

function MovementService.Start()
	if started then
		return
	end
	started = true
	monetization = service("MonetizationService")
	boosts = service("BoostService")
	if monetization ~= nil and monetization.PassChanged ~= nil then
		monetization.PassChanged:Connect(function(player: Player, passKey: string)
			if MovementConfig.Passes[passKey] ~= nil then
				MovementService.refresh(player)
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		sources[player] = nil
		for _, connection in guards[player] or {} do
			connection:Disconnect()
		end
		guards[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	-- Boost expiry re-checks: only when some boost affects running (none today).
	if boosts ~= nil and next(MovementConfig.BoostWalkMultipliers) ~= nil then
		task.spawn(function()
			while true do
				task.wait(MovementConfig.BoostCheckSeconds)
				for _, player in Players:GetPlayers() do
					MovementService.refresh(player)
				end
			end
		end)
	end
end

return MovementService
