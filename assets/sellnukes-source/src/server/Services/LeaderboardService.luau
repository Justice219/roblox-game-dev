--!strict
--[[
	LeaderboardService — SellNukes' global, all-time leaderboards (spec §4: top cash earned, top
	rebirths, top playtime in the Nuke Town hub; owner R57: MOST DINO REBIRTHS at Dino Valley's
	Base Camp; docs/leaderboards.md). Pattern: RoBeasts LeaderboardService.

	Purpose:
		- SAMPLES trusted server values (profile.totalEarned, profile.rebirths,
		  profile.stats.playSeconds) every FlushEverySeconds, encodes them
		  (LeaderboardConfig.encode: cash is log-encoded, it outgrows 64-bit integers) and queues an
		  OrderedDataStore SetAsync — THROTTLED: a player's value on a board is written only when it
		  changed and at most once per MinUserWriteSeconds while they play; their final values are
		  written when they leave (PlayerDataService.ProfileReleasing) and on shutdown (BindToClose).
		- Every write is pcall'd; failures merge back (a newer pending value wins). Budgets: a flush
		  is skipped while the profile UpdateAsync budget is low; ordered writes keep a reserve; the
		  same key is never written twice within MinKeyWriteSeconds.
		- READS the top TopN of each board every ReadEverySeconds (≤ 60 s, owner) with GetSortedAsync,
		  resolves display names in one batched UserService call (bounded cache, "Player #id"
		  fallback) and publishes a bounded JSON payload per board into
		  ReplicatedStorage.Leaderboards/<BoardId> (StringValue). No remotes exist.
		- Only real, SAVED progress ranks: Studio test players (UserId <= 0), unsaved in-memory
		  profiles and the admin's New Player Mode sandbox never reach a board.
		- Studio without DataStore access (probed once): in-memory boards of this server, published
		  with scope "server" (the boards say THIS SERVER).
		- Builds the hub board SCREENS: an invisible, non-colliding "Screen" part per board at
		  HubLayout.leaderboards[slot] (B8e's board meshes frame it), or a stud-styled fallback stand
		  until the hub art exists. Clients adorn their stud SurfaceGui to the tagged parts.
		  A world board (R57 `def.world`) stands in Workspace.Leaderboards_<world> at that world's
		  hub layout anchors (world-local, WorldLayout.toWorld), with the same fallback stand
		  until the world's art exists. Sampling / writing / reading treat every board alike.

	How it connects:
		PlayerDataService (getProfile, canMutate, isSavingEnabled, ProfileReleasing) → this service →
		ReplicatedStorage.Leaderboards StringValues → Client/Leaderboards/LeaderboardBoardController.
		Pure decisions: Server/Leaderboards/LeaderboardLogic; tunables + schema: LeaderboardConfig.
		Owner admin: "LeaderboardRefresh" (flush + re-read now).

	Example:
		LeaderboardService.getPayload("Cash")   --> last published Payload (or nil)
		LeaderboardService.refreshAsync()       -- tests / admin: flush + re-read every board now
]]

local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local UserService = game:GetService("UserService")
local Workspace = game:GetService("Workspace")

local LeaderboardConfig = require(ReplicatedStorage.Shared.Config.LeaderboardConfig)
local LeaderboardLogic = require(ServerScriptService.Server.Leaderboards.LeaderboardLogic)
local Lazy = require(ServerScriptService.Server.Event.Lazy)
local MeshAssets = require(ReplicatedStorage.Shared.Config.MeshAssets)
local PlayerDataService = require(script.Parent.PlayerDataService)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldMaterials = require(ServerScriptService.Server.World.WorldMaterials)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type BoardId = LeaderboardConfig.BoardId
type BoardDef = LeaderboardConfig.BoardDef
type Payload = LeaderboardConfig.Payload
type Row = LeaderboardLogic.Row
type Write = LeaderboardLogic.Write

type ScopeState = LeaderboardConfig.Scope | "unknown"

local LeaderboardService = {}

local isStudio = RunService:IsStudio()
local scope: ScopeState = "unknown"
local shuttingDown = false
local started = false

local values: { [BoardId]: StringValue } = {}
local published: { [BoardId]: Payload } = {}

-- Pending SETs, the last successful write per key, the engine per-key interval, writes in flight.
local pending: LeaderboardLogic.Pending = {}
local records: { [string]: LeaderboardLogic.WriteRecord } = {}
local lastWriteStart: { [string]: number } = {}
local inFlight = 0

local stores: { [string]: OrderedDataStore } = {}
local serverBoards: { [BoardId]: { [number]: number } } = {}
local nameCache: LeaderboardLogic.NameCache = {}
local lastWarn: { [string]: number } = {}
local serverPublishQueued = false

-- Seconds between two warnings of the same kind (an outage must not spam the log).
local WARN_INTERVAL = 300

for _, def in LeaderboardConfig.Boards do
	serverBoards[def.id] = {}
end

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

local function warnOnce(kind: string, message: string)
	local now = os.clock()
	local last = lastWarn[kind]
	if last ~= nil and now - last < WARN_INTERVAL then
		return
	end
	lastWarn[kind] = now
	warn(`[LeaderboardService] {message}`)
end

local function storeNameFor(boardId: BoardId): string
	return LeaderboardConfig.storeName(boardId, isStudio)
end

local function keyOf(store: string, userId: number): string
	return `{store}|{userId}`
end

-- Requests available for a DataStore request type (math.huge when the API itself errors).
local function budget(requestType: Enum.DataStoreRequestType): number
	local ok, value = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(requestType)
	end)
	return if ok and type(value) == "number" then value else math.huge
end

local function orderedStore(name: string): OrderedDataStore?
	local cached = stores[name]
	if cached ~= nil then
		return cached
	end
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(name)
	end)
	if not ok then
		warnOnce("store", `GetOrderedDataStore({name}) failed: {result}`)
		return nil
	end
	stores[name] = result
	return result
end

--[[
	True when this player's progress may rank globally: a real user, a profile that really saves
	(not the in-memory fallback, not read-only / lost), and not the admin New Player Mode sandbox.
]]
local function eligible(player: Player): boolean
	return LeaderboardLogic.isUserId(player.UserId)
		and player:GetAttribute("NewPlayerMode") ~= true
		and PlayerDataService.isSavingEnabled()
		and PlayerDataService.canMutate(player)
end

--------------------------------------------------------------------------------------------------
-- Publishing
--------------------------------------------------------------------------------------------------

local function publish(payload: Payload)
	published[payload.board] = payload
	local value = values[payload.board]
	if value == nil then
		return
	end
	local text = LeaderboardLogic.encodeBounded(payload, function(data: any): string
		return HttpService:JSONEncode(data)
	end)
	if value.Value ~= text then
		value.Value = text
	end
end

-- Display names of everyone online (refreshes the cache too).
local function onlineNames(): { [number]: string }
	local names: { [number]: string } = {}
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		if LeaderboardLogic.isUserId(player.UserId) then
			names[player.UserId] = player.DisplayName
			LeaderboardLogic.cacheName(
				nameCache,
				player.UserId,
				player.DisplayName,
				now,
				LeaderboardConfig.NameCacheSize
			)
		end
	end
	return names
end

-- Names for rows: online first, then the cache, then ONE batched UserService call. Yields.
local function resolveNamesAsync(rows: { Row }): { [number]: string }
	local known = onlineNames()
	local now = os.clock()
	local missing = LeaderboardLogic.missingNames(
		rows,
		known,
		nameCache,
		now,
		LeaderboardConfig.NameCacheSeconds,
		LeaderboardConfig.NameBatchSize
	)
	if #missing > 0 then
		local wanted: { [number]: boolean } = {}
		for _, userId in missing do
			wanted[userId] = true
		end
		local ok, infos = pcall(function()
			return UserService:GetUserInfosByUserIdsAsync(missing)
		end)
		if ok and type(infos) == "table" then
			for _, info in infos do
				if type(info) == "table" and type(info.Id) == "number" and wanted[info.Id] then
					LeaderboardLogic.cacheName(
						nameCache,
						info.Id,
						info.DisplayName,
						now,
						LeaderboardConfig.NameCacheSize
					)
				end
			end
		elseif not ok then
			warnOnce("names", `GetUserInfosByUserIdsAsync failed: {infos}`)
		end
	end
	local names: { [number]: string } = {}
	for _, row in rows do
		local name = known[row.userId]
		if name == nil then
			local cached = nameCache[row.userId]
			name = if cached ~= nil then cached.name else nil
		end
		if name ~= nil then
			names[row.userId] = name
		end
	end
	return names
end

-- Publishes every in-memory board ("server" scope only). Never yields.
local function publishServerBoards()
	if scope ~= "server" then
		return
	end
	local names: { [number]: string } = {}
	for userId, entry in nameCache do
		names[userId] = entry.name
	end
	for userId, name in onlineNames() do
		names[userId] = name
	end
	for _, def in LeaderboardConfig.Boards do
		local rows = LeaderboardLogic.topRows(serverBoards[def.id], LeaderboardConfig.TopN)
		publish(
			LeaderboardLogic.buildPayload(
				{ def = def, scope = "server", status = "ok", updatedAt = os.time() },
				rows,
				names
			)
		)
	end
end

-- Coalesces server-scope publishes (many samples in one second = one publish).
local function queueServerPublish()
	if scope ~= "server" or serverPublishQueued then
		return
	end
	serverPublishQueued = true
	task.delay(1, function()
		serverPublishQueued = false
		publishServerBoards()
	end)
end

-- Reads one board's top N and publishes it (keeps the last payload on failure). Yields.
local function readBoardAsync(def: BoardDef)
	local function unavailable()
		if published[def.id] == nil then
			publish(
				LeaderboardLogic.buildPayload(
					{ def = def, scope = "global", status = "unavailable", updatedAt = os.time() },
					{},
					{}
				)
			)
		end
	end
	if budget(Enum.DataStoreRequestType.GetSortedAsync) <= LeaderboardConfig.ReadBudgetReserve then
		warnOnce("readBudget", `GetSortedAsync budget low; {def.id} read skipped`)
		unavailable()
		return
	end
	local store = orderedStore(storeNameFor(def.id))
	if store == nil then
		unavailable()
		return
	end
	local ok, result = pcall(function(): { Row }
		local pages = store:GetSortedAsync(false, LeaderboardConfig.TopN)
		return LeaderboardLogic.sanitizePage(pages:GetCurrentPage(), LeaderboardConfig.TopN)
	end)
	if not ok then
		warnOnce(`read{def.id}`, `GetSortedAsync({def.id}) failed: {result}`)
		unavailable()
		return
	end
	local names = resolveNamesAsync(result)
	publish(
		LeaderboardLogic.buildPayload(
			{ def = def, scope = "global", status = "ok", updatedAt = os.time() },
			result,
			names
		)
	)
end

-- One read cycle (global) or a server-board publish. Yields.
local function readAllAsync()
	if scope == "server" then
		publishServerBoards()
		return
	end
	if scope ~= "global" then
		return
	end
	for index, def in LeaderboardConfig.Boards do
		if shuttingDown then
			return
		end
		readBoardAsync(def)
		if index < #LeaderboardConfig.Boards then
			task.wait(1) -- spread the reads instead of bursting them
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Sampling + writing
--------------------------------------------------------------------------------------------------

--[[
	Samples one player's board values from `profile` (defaults to their live profile). Updates the
	server-scope boards and, for eligible players, queues the writes that are due.
	@param final the player is leaving / the server is closing (skip the user throttle)
]]
local function sample(player: Player, profile: any?, final: boolean)
	local userId = player.UserId
	if not LeaderboardLogic.isUserId(userId) or player:GetAttribute("NewPlayerMode") == true then
		return
	end
	local source = profile or PlayerDataService.getProfile(player)
	if source == nil then
		return
	end
	local canWrite = scope == "global" and eligible(player)
	local now = os.clock()
	for _, def in LeaderboardConfig.Boards do
		local stored = LeaderboardConfig.encode(def, LeaderboardConfig.valueOf(def, source))
		if stored == nil then
			continue
		end
		LeaderboardLogic.setServerBoard(serverBoards[def.id], userId, stored, LeaderboardConfig.ServerBoardSize)
		if canWrite then
			local store = storeNameFor(def.id)
			if LeaderboardLogic.dueForWrite(records[keyOf(store, userId)], stored, now, final) then
				LeaderboardLogic.setPending(pending, store, userId, stored)
			end
		end
	end
	queueServerPublish()
end

-- Starts one SetAsync on its own thread; a failure merges back into `pending`.
local function startWrite(write: Write)
	local key = keyOf(write.store, write.userId)
	inFlight += 1
	lastWriteStart[key] = os.clock()
	task.spawn(function()
		local store = orderedStore(write.store)
		local ok: boolean, err: unknown = false, "store unavailable"
		if store ~= nil then
			ok, err = pcall(function()
				store:SetAsync(tostring(write.userId), write.value)
			end)
		end
		inFlight -= 1
		if ok then
			records[key] = { written = write.value, at = os.clock() }
		else
			LeaderboardLogic.mergeBack(pending, write)
			warnOnce("write", `SetAsync to {write.store} failed: {err}`)
		end
	end)
end

--[[ Starts the pending writes allowed now. @return writes started ]]
local function flushNow(onlyUser: number?): number
	if scope ~= "global" then
		return 0
	end
	if not shuttingDown and budget(Enum.DataStoreRequestType.UpdateAsync) <= LeaderboardConfig.ProfileBudgetReserve then
		warnOnce("profileBudget", "profile save budget low; leaderboard flush deferred")
		return 0
	end
	local reserve = if shuttingDown then 0 else LeaderboardConfig.WriteBudgetReserve
	local available = budget(Enum.DataStoreRequestType.SetIncrementSortedAsync) - reserve
	local limit = math.min(LeaderboardConfig.MaxWritesPerFlush, available)
	if limit < 1 then
		warnOnce("writeBudget", "ordered write budget low; leaderboard flush deferred")
		return 0
	end
	local now = os.clock()
	local writes = LeaderboardLogic.selectWrites(pending, limit, function(store: string, userId: number): boolean
		if onlyUser ~= nil and userId ~= onlyUser then
			return false
		end
		local last = lastWriteStart[keyOf(store, userId)]
		return shuttingDown or last == nil or now - last >= LeaderboardConfig.MinKeyWriteSeconds
	end)
	for _, write in writes do
		startWrite(write)
	end
	return #writes
end

-- Drops bookkeeping of players who left and whose writes finished.
local function prune()
	local now = os.clock()
	for key, at in lastWriteStart do
		if now - at >= LeaderboardConfig.MinKeyWriteSeconds then
			lastWriteStart[key] = nil
		end
	end
	local present: { [string]: boolean } = {}
	for _, player in Players:GetPlayers() do
		present[tostring(player.UserId)] = true
	end
	for key in records do
		local userId = string.match(key, "|(%d+)$")
		if userId ~= nil and not present[userId] then
			records[key] = nil
		end
	end
end

-- One flush tick: sample everyone, start the due writes, prune.
local function flushTick()
	for _, player in Players:GetPlayers() do
		sample(player, nil, false)
	end
	flushNow(nil)
	prune()
end

-- A leaver's final values: written after the per-key interval allows (twice for safety).
local function flushLeaverAsync(userId: number)
	for _ = 1, 2 do
		task.wait(LeaderboardConfig.MinKeyWriteSeconds)
		if shuttingDown then
			return -- BindToClose flushes everything
		end
		flushNow(userId)
	end
end

-- BindToClose: final samples, then start every pending write and wait (bounded).
local function onClose()
	if shuttingDown then
		return
	end
	for _, player in Players:GetPlayers() do
		sample(player, nil, true)
	end
	shuttingDown = true
	if scope ~= "global" then
		return
	end
	local deadline = os.clock() + LeaderboardConfig.ShutdownBudgetSeconds
	repeat
		flushNow(nil)
		task.wait(0.2)
	until (inFlight == 0 and next(pending) == nil) or os.clock() >= deadline
end

--------------------------------------------------------------------------------------------------
-- Hub boards
--------------------------------------------------------------------------------------------------

-- An anchored stud part for the fallback stand (properties set before parenting).
local function boardPart(name: string, size: Vector3, cframe: CFrame, color: Color3, collide: boolean): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.CanCollide = collide
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	WorldMaterials.apply(part, "Studs")
	return part
end

-- One screen: the face centre (LookVector out of the face, toward viewers), its size, its board.
type Anchor = { cf: CFrame, size: Vector2, boardId: BoardId? }

-- HubLayout anchors.Leaderboards[i].stat -> board id. Every board id maps to itself (R70 framework
-- fix: a new world's board, e.g. Moon Base's "MoonRebirths", needs only its LeaderboardConfig row —
-- this table used to list each world board by hand), plus the hub's legacy alias "CashEarned".
local STAT_TO_BOARD: { [string]: BoardId } = { CashEarned = "Cash" }
for _, board in LeaderboardConfig.Boards do
	STAT_TO_BOARD[board.id] = board.id
end

-- How far the invisible screen part sits in front of the mesh's screen face (no z-fighting).
local FACE_GAP = 0.04

--[[
	The screen face of one HubLayout leaderboard anchor: the mesh's "Screen" piece (HubLayout.surfaces
	[key] → MeshAssets[key].pieces[piece]) in front of its front face; nil when the art data is
	incomplete. `entry.model` is the placement name "<key>_<index>".
]]
local function screenOf(layout: { [string]: any }, entry: { [string]: any }): (CFrame?, Vector2?)
	local name = if type(entry.model) == "string" then entry.model else ""
	local key = string.match(name, "^(.-)_%d+$") or name
	local allSurfaces: any = layout.surfaces
	local surfaces: any = if type(allSurfaces) == "table" then allSurfaces[key] else nil
	local surface: any = if type(surfaces) == "table" then surfaces[1] else nil
	local asset = (MeshAssets :: any)[key]
	if type(surface) ~= "table" or type(surface.piece) ~= "string" or asset == nil then
		return nil, nil
	end
	local piece = asset.pieces[surface.piece]
	if piece == nil then
		return nil, nil
	end
	local size = if typeof(surface.size) == "Vector2" then surface.size else Vector2.new(piece.size.X, piece.size.Y)
	local face = (entry.cf :: CFrame) * CFrame.new(piece.offset) * CFrame.new(0, 0, -(piece.size.Z / 2) - FACE_GAP)
	return face, size
end

-- The Nuke Town hub's boards (slots 1..3) and the R57 world boards (each in its world's hub).
local MAIN_BOARDS = LeaderboardConfig.boardsIn(nil)

--[[
	The fallback row of `count` screens around `centre`, facing `lookAt` (no hub art yet).
	@return anchors (boardId nil: boards fill them in slot order)
]]
local function fallbackRow(count: number, centre: Vector3, lookAt: Vector3): { Anchor }
	local cfg = LeaderboardConfig.Board
	local faceY = cfg.faceBottom + cfg.faceSize.Y / 2
	local list: { Anchor } = {}
	for index = 1, count do
		local x = (index - (count + 1) / 2) * cfg.fallbackSpacing
		local position = centre + Vector3.new(x, faceY, 0)
		-- Face the hub centre (LookVector = out of the face, toward the viewers).
		table.insert(
			list,
			{ cf = CFrame.lookAt(position, Vector3.new(lookAt.X, faceY, lookAt.Z)), size = cfg.faceSize, boardId = nil }
		)
	end
	return list
end

--[[
	The three screen anchors: HubLayout.leaderboards[1..3] = { cf, size } (B8e: [1] cash, [2]
	rebirths, [3] playtime), else anchors.Leaderboards + surfaces + the Hub_Leaderboard "Screen"
	piece (both describe B8e's meshes, built by HubBuilder), else — no hub art — a fallback row
	north of the hub centre.
	@return anchors, true when they come from the hub art (no fallback stands needed)
]]
local function anchors(): ({ Anchor }, boolean)
	local layout = Lazy.hubLayout()
	local list: { Anchor } = {}
	-- B8e's direct screens: leaderboards[1..3] = { cf (0.05 in front of the Screen face), size }.
	local direct = layout.leaderboards
	if type(direct) == "table" then
		local ids: { BoardId } = { "Cash", "Rebirths", "Playtime" }
		for index, entry in direct do
			if type(entry) == "table" and typeof(entry.cf) == "CFrame" and typeof(entry.size) == "Vector2" then
				table.insert(list, { cf = entry.cf, size = entry.size, boardId = ids[index] })
			end
		end
		if #list >= #MAIN_BOARDS then
			return list, true
		end
		table.clear(list)
	end
	local hubAnchors = layout.anchors
	local raw = if type(hubAnchors) == "table" then hubAnchors.Leaderboards else nil
	if type(raw) == "table" then
		for _, entry in raw do
			if type(entry) ~= "table" or typeof(entry.cf) ~= "CFrame" then
				continue
			end
			local face, size = screenOf(layout, entry)
			if face == nil or size == nil then
				continue
			end
			local stat = if type(entry.stat) == "string" then STAT_TO_BOARD[entry.stat] else nil
			table.insert(list, { cf = face, size = size, boardId = stat })
		end
	end
	if #list >= #MAIN_BOARDS then
		return list, true
	end
	local centre = LeaderboardConfig.Board.fallbackCentre
	return fallbackRow(#MAIN_BOARDS, centre, Vector3.zero), false
end

--[[
	R57: the hub layout module of an extra world (WorldsConfig def.hubLayout, a path under
	ReplicatedStorage.Shared.Config, e.g. { "Worlds", "Dino", "ValleyLayout" }); nil while that
	world's art (W9) is not in the place yet or fails to load.
]]
local function worldLayoutOf(worldId: string): { [string]: any }?
	local def = WorldsConfig.get(worldId)
	if def == nil then
		return nil
	end
	local node: Instance? = ReplicatedStorage:FindFirstChild("Shared")
	node = if node ~= nil then node:FindFirstChild("Config") else nil
	for _, name in def.hubLayout do
		node = if node ~= nil then node:FindFirstChild(name) else nil
	end
	if node == nil or not node:IsA("ModuleScript") then
		return nil
	end
	local ok, layout = pcall(require, node)
	return if ok and type(layout) == "table" then layout :: any else nil
end

--[[
	R57: the screen anchors of an extra world's boards, in WORLD space. The world's hub layout is
	WORLD-LOCAL (WorldLayout.toWorld places it): leaderboards[i] = { cf, size } direct screens, or
	anchors.Leaderboards[i] = { cf, model, stat?, screen?, screenSize? } — the screen face given
	directly (ValleyLayout) or derived from surfaces + the mesh "Screen" piece (the Nuke Town hub
	contract). Without that art: a fallback row 70 studs north of the world's
	origin, facing it.
	@return anchors, true when they come from the world's art
]]
local function worldAnchors(worldId: string, count: number): ({ Anchor }, boolean)
	local layout = worldLayoutOf(worldId)
	local list: { Anchor } = {}
	if layout ~= nil then
		local direct = layout.leaderboards
		if type(direct) == "table" then
			for _, entry in direct do
				if type(entry) == "table" and typeof(entry.cf) == "CFrame" and typeof(entry.size) == "Vector2" then
					table.insert(
						list,
						{ cf = WorldLayout.toWorld(worldId, entry.cf), size = entry.size, boardId = nil }
					)
				end
			end
		end
		local worldAnchorsRaw = layout.anchors
		local raw = if type(worldAnchorsRaw) == "table" then worldAnchorsRaw.Leaderboards else nil
		if #list < count and type(raw) == "table" then
			table.clear(list)
			for _, entry in raw do
				if type(entry) ~= "table" or typeof(entry.cf) ~= "CFrame" then
					continue
				end
				-- The Valley's anchors carry the screen face directly (W9: `screen` = the face
				-- centre 0.05 in front of it, `screenSize`); else derive it from the mesh piece.
				local face: CFrame?, size: Vector2? = nil, nil
				if typeof(entry.screen) == "CFrame" and typeof(entry.screenSize) == "Vector2" then
					face, size = entry.screen, entry.screenSize
				else
					face, size = screenOf(layout, entry)
				end
				if face ~= nil and size ~= nil then
					local stat = if type(entry.stat) == "string" then STAT_TO_BOARD[entry.stat] else nil
					table.insert(list, { cf = WorldLayout.toWorld(worldId, face), size = size, boardId = stat })
				end
			end
		end
		if #list >= count then
			return list, true
		end
	end
	local origin = WorldLayout.toWorld(worldId, CFrame.identity).Position
	local centre = origin + LeaderboardConfig.Board.fallbackCentre
	return fallbackRow(count, centre, origin), false
end

--[[
	Builds one board model: per board an invisible Screen part (tagged; attribute BoardId), plus —
	only while the art has no boards (`fromLayout` false) — a stud backing, trim and posts.
	Persistent streaming so every client always has the (tiny) screen parts to adorn.
]]
local function buildModel(name: string, boards: { BoardDef }, list: { Anchor }, fromLayout: boolean)
	local cfg = LeaderboardConfig.Board
	local existing = Workspace:FindFirstChild(name)
	if existing ~= nil then
		existing:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = name
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	for index, def in boards do
		-- The art names each board's stat; otherwise boards fill slots 1..N in order.
		local anchor = list[def.slot] or list[index]
		for _, candidate in list do
			if candidate.boardId == def.id then
				anchor = candidate
				break
			end
		end
		local w, h = anchor.size.X, anchor.size.Y
		if not fromLayout then
			local back = anchor.cf * CFrame.new(0, 0, cfg.depth / 2 + 0.05)
			boardPart(
				`Backing_{def.id}`,
				Vector3.new(w + cfg.frame * 2, h + cfg.frame * 2, cfg.depth),
				back,
				cfg.colors.backing,
				true
			).Parent =
				model
			boardPart(
				`Trim_{def.id}`,
				Vector3.new(w + cfg.frame * 2 + 0.6, 0.6, cfg.depth + 0.4),
				back * CFrame.new(0, h / 2 + cfg.frame + 0.3, 0),
				cfg.colors.trim,
				true
			).Parent =
				model
			local postHeight = cfg.faceBottom + h + cfg.frame
			for side = -1, 1, 2 do
				local postCf = back
					* CFrame.new(side * (w / 2 + cfg.frame + 0.5), -(h / 2) - cfg.faceBottom + postHeight / 2, 0)
				boardPart(`Post_{def.id}_{side}`, Vector3.new(1, postHeight, 1), postCf, cfg.colors.post, true).Parent =
					model
			end
		end
		local screen = Instance.new("Part")
		screen.Name = `Screen_{def.id}`
		screen.Anchored = true
		screen.CanCollide = false
		screen.CanQuery = false
		screen.CanTouch = false
		screen.CastShadow = false
		screen.Transparency = 1
		screen.Size = Vector3.new(w, h, 0.1)
		screen.CFrame = anchor.cf
		screen:SetAttribute(LeaderboardConfig.BoardAttribute, def.id)
		CollectionService:AddTag(screen, LeaderboardConfig.ScreenTag)
		screen.Parent = model
	end
	model.Parent = Workspace
end

--[[
	Builds Workspace.Leaderboards (the Nuke Town hub's boards) and, per extra world with boards
	(R57), Workspace.Leaderboards_<worldId> at that world's hub anchors.
]]
local function buildBoards()
	local list, fromLayout = anchors()
	buildModel(LeaderboardConfig.Board.modelName, MAIN_BOARDS, list, fromLayout)
	for _, worldId in LeaderboardConfig.boardWorlds() do
		if worldId ~= WorldsConfig.MAIN and WorldsConfig.get(worldId) ~= nil then
			local boards = LeaderboardConfig.boardsIn(worldId)
			local worldList, worldFromLayout = worldAnchors(worldId, #boards)
			buildModel(`{LeaderboardConfig.Board.modelName}_{worldId}`, boards, worldList, worldFromLayout)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Loops + lifecycle
--------------------------------------------------------------------------------------------------

-- Decides global vs server scope (Studio probe), then runs the flush + read loops. Yields.
local function runAsync()
	local probe = orderedStore(storeNameFor("Cash"))
	local usable = probe ~= nil
	if usable and isStudio and probe ~= nil then
		local ok, err = pcall(function()
			return probe:GetSortedAsync(false, 1)
		end)
		if not ok then
			usable = false
			warn(
				`[LeaderboardService] DataStores unavailable in Studio ({err}). Leaderboards show THIS SERVER only`
					.. " (enable Game Settings > Security > Studio Access to API Services for global boards)."
			)
		end
	end
	scope = if usable then "global" else "server"
	for _, player in Players:GetPlayers() do
		sample(player, nil, false)
	end
	task.spawn(function()
		while not shuttingDown do
			task.wait(LeaderboardConfig.FlushEverySeconds)
			if not shuttingDown then
				local ok, err = pcall(flushTick)
				if not ok then
					warnOnce("flushTick", `flush tick failed: {err}`)
				end
			end
		end
	end)
	while not shuttingDown do
		local ok, err = pcall(readAllAsync)
		if not ok then
			warnOnce("readTick", `read cycle failed: {err}`)
		end
		task.wait(LeaderboardConfig.ReadEverySeconds)
	end
end

--------------------------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------------------------

--[[ "global" (OrderedDataStores), "server" (in-memory) or "unknown" (probing). ]]
function LeaderboardService.getScope(): ScopeState
	return scope
end

--[[ The last payload published for a board (nil before the first read). ]]
function LeaderboardService.getPayload(boardId: BoardId): Payload?
	return published[boardId]
end

--[[ Pending + in-flight writes (diagnostics / tests). ]]
function LeaderboardService.pendingCount(): number
	return LeaderboardLogic.pendingCount(pending) + inFlight
end

--[[ Samples everyone, starts the allowed writes and re-reads every board now. Yields. ]]
function LeaderboardService.refreshAsync()
	for _, player in Players:GetPlayers() do
		sample(player, nil, true)
	end
	flushNow(nil)
	readAllAsync()
end

function LeaderboardService.Init()
	local existing = ReplicatedStorage:FindFirstChild(LeaderboardConfig.ContainerName)
	if existing ~= nil then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = LeaderboardConfig.ContainerName
	for _, def in LeaderboardConfig.Boards do
		local value = Instance.new("StringValue")
		value.Name = def.id
		value.Value = ""
		value.Parent = folder
		values[def.id] = value
	end
	folder.Parent = ReplicatedStorage
end

function LeaderboardService.Start()
	if started then
		return
	end
	started = true
	local ok, err = pcall(buildBoards)
	if not ok then
		warn(`[LeaderboardService] hub boards failed to build: {err}`)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		LeaderboardLogic.cacheName(
			nameCache,
			player.UserId,
			player.DisplayName,
			os.clock(),
			LeaderboardConfig.NameCacheSize
		)
	end)
	PlayerDataService.ProfileLoaded:Connect(function(player: Player)
		sample(player, nil, false)
	end)
	-- Final values while the profile is still live (fires before the release save; never yields).
	PlayerDataService.ProfileReleasing:Connect(function(player: Player, profile: any)
		sample(player, profile, true)
		if scope == "global" and not shuttingDown and LeaderboardLogic.isUserId(player.UserId) then
			task.spawn(flushLeaverAsync, player.UserId)
		end
	end)
	game:BindToClose(onClose)
	Lazy.registerAdmin({
		name = "LeaderboardRefresh",
		tab = "Server",
		label = "Refresh Leaderboards",
		description = "Write everyone's current values and re-read every leaderboard now (hub + world boards).",
		target = "None",
		args = {},
		cooldown = 30,
		audited = true,
		confirm = false,
		color = "teal",
		order = 70,
	}, function(_ctx: any): (boolean, string)
		task.spawn(LeaderboardService.refreshAsync)
		return true, `Leaderboards refreshing ({scope} scope, {LeaderboardService.pendingCount()} writes pending)`
	end)
	task.spawn(runAsync)
end

return LeaderboardService
