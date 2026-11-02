--!strict
--[[
	Loader — runs SellNukes' branded loading screen from ReplicatedFirst.

	What the player sees (back to front):
		BACKDROP (full-bleed ScreenGui, ignores every inset)
			- a bright sky gradient on the very first frame (UI primitives only)
			- the hub key art (BrandImages.KeyArt) fading in once loaded, slowly pushing in
			- a tiled stud texture (BrandImages.StudTexture = the UI kit's stud panel texture)
			- a soft bottom scrim so the footer text always reads
		HUD (ScreenInsets = DeviceSafeInsets: never under a notch, home bar or the Roblox top bar;
		     5 % title-safe margin on TVs; one UIScale fits the 1280 x 720 design canvas, Composition)
			- Nukey the mascot bobbing on the left over a pulsing reactor-green glow
			- the "SELL NUKES" title popping in (image; Luckiest Guy text fallback until it loads)
			- a tip card rotating kid-friendly tips worded for the device (Tips)
			- a chunky stud progress bar driven by REAL progress (Readiness) with a caption per step
			  and a percentage, and a TAP TO CONTINUE prompt after Readiness.TIMEOUT on slow loads
		Hand-off: the bar races to 100 %, the caption cheers, both layers fade out (CanvasGroup) and
		are destroyed.

	Readiness (owner R16: the screen must cover the slow model streaming and come BEFORE the
	"your plot is" reveal; see Readiness for the staged steps): game:IsLoaded() -> ClientBooted ->
	profile (ProfileReady / ClientState.profile) -> Workspace.WorldReady -> the player's plot
	PlotReady -> the CRITICAL preload (brand art + hot UI icons + Shared.World.PreloadList.
	forClientCritical(tycoon): plot frame, owned builds, the current next pads), with a REAL count.
	At least MIN_SHOW seconds; after TIMEOUT (20 s) a "TAP TO CONTINUE" prompt (tap / click
	anywhere, A or Enter); after AUTO_CONTINUE (30 s) it hands off by itself.

	Fast first minute (owner R122, spec 2026-11-01 §2.1; phones averaged 26 s here on 0.7.1, most
	of it the old 30 s asset budget): the critical preload holds the bar for at most
	Readiness.ASSET_BUDGET (6 s) from its start. Whatever is left of it, then the DEFERRED list
	(PreloadList.forClientDeferred: upcoming builds, the shared hub, lobby decor, the next area's
	base) keep downloading in the SAME thread after the hand-off at background pace
	(Readiness.pace: small batches, a pause between them), until done or the player leaves. Holder
	instances are created per batch and destroyed right after it; the queue (PreloadQueue) is
	released at the end.

	Talking to the rest of the client (no remotes; cosmetic and client-side only):
		- LocalPlayer attribute LoadingScreenActive = true while showing, false at hand-off.
		- LocalPlayer attribute LoadingDone = true at hand-off: UI/Widgets/LoadingGate keeps the HUD
		  hidden and Tycoon/PlotReveal waits for it (owner R16).
		- LocalPlayer attribute BootSeconds = seconds from this module's start to the hand-off,
		  set LAST; just before it (R122 boot telemetry, Readiness.stepAttributes) BootStep<step> =
		  each finished step's completion second from the same start, and BootEnd = the hand-off
		  reason ("ready" | "budget" | "tap" | "auto"). Client/Analytics/ClientPerfReporter reports
		  them once per session.
		- Reads (never writes) ClientBooted / ProfileReady / PlotReady (LocalPlayer), WorldReady
		  (Workspace), PlotReady + OwnerUserId (Workspace.Plots children).

	Never in the way: no input sink until the TAP TO CONTINUE prompt shows (then a full-screen
	button continues; nothing else is Active or Selectable), one RenderStepped connection
	(disconnected at hand-off), no Instance.new per frame, every UI instance destroyed within
	AUTO_CONTINUE + ~1 s (only the paced background preload thread outlives the screen).
	Reduced motion (GuiService.ReducedMotionEnabled): no bob, pulse, push-in or pop; plain fades only.

	Example (ReplicatedFirst/LoadingScreen/init.client.luau):
		require(script.Loader).run()
]]

local ContentProvider = game:GetService("ContentProvider")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local BrandImages = require(script.Parent.BrandImages)
local Composition = require(script.Parent.Composition)
local PreloadQueue = require(script.Parent.PreloadQueue)
local Readiness = require(script.Parent.Readiness)
local Tips = require(script.Parent.Tips)

local Loader = {}

-- Colours (mirrors UIStyleConfig: stroke 20/20/28, cash green, stud red).
local STROKE = Color3.fromRGB(20, 20, 28)
local SKY_TOP = Color3.fromRGB(52, 140, 236)
local SKY_BOTTOM = Color3.fromRGB(160, 220, 255)
local BAR_FILL = Color3.fromRGB(96, 220, 72)
local BAR_FILL_LIGHT = Color3.fromRGB(170, 250, 120)
local BAR_BACK = Color3.fromRGB(34, 38, 56)
local SKIP_RED = Color3.fromRGB(232, 64, 56)
local GLOW_GREEN = Color3.fromRGB(120, 255, 90)
local FONT = Enum.Font.LuckiestGuy
-- IconAssets categories preloaded as "hot" (visible in the first seconds of play).
local HOT_CATEGORIES = { "hud", "currency", "ui", "offer" }
-- Batch sizes and pauses: Readiness.pace (critical back to back, background paced).
-- Seconds to wait for ReplicatedStorage.Shared to replicate before skipping icon preloads.
local SHARED_WAIT = 15
-- Seconds between polls of the profile / world / plot readiness flags (cheap attribute reads).
local POLL_SECONDS = 0.25
-- Inputs that answer the TAP TO CONTINUE prompt besides a tap / click.
local CONTINUE_KEYS = { Enum.KeyCode.ButtonA, Enum.KeyCode.Return, Enum.KeyCode.KeypadEnter, Enum.KeyCode.Space }

local started = false

--[[
	Creates an Instance with properties and children (one helper keeps the builder readable).
	@param className  Roblox class
	@param props      property table (assigned in any order; Parent last)
	@param children   optional child Instances
	Example: make("Frame", { Size = UDim2.fromScale(1, 1) }, { make("UICorner", {}) })
]]
local function make(className: string, props: { [string]: any }, children: { Instance }?): any
	local instance = Instance.new(className)
	local parent = props.Parent
	for key, value in props do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	for _, child in children or {} do
		child.Parent = instance
	end
	if parent ~= nil then
		instance.Parent = parent
	end
	return instance
end

--[[ A dark stroke (outlines text and stud panels, like the HUD). ]]
local function stroke(thickness: number, mode: Enum.ApplyStrokeMode?): UIStroke
	return make("UIStroke", {
		Thickness = thickness,
		Color = STROKE,
		ApplyStrokeMode = mode or Enum.ApplyStrokeMode.Contextual,
		LineJoinMode = Enum.LineJoinMode.Round,
	})
end

--[[ Big outlined Luckiest Guy text (captions, percent, fallback title). ]]
local function label(props: { [string]: any }, strokeThickness: number): TextLabel
	local base: { [string]: any } = {
		BackgroundTransparency = 1,
		Font = FONT,
		TextColor3 = Color3.new(1, 1, 1),
		TextScaled = false,
	}
	for key, value in props do
		base[key] = value
	end
	return make("TextLabel", base, { stroke(strokeThickness) })
end

--[[ True when the client prefers reduced motion (pcall: older clients lack the property). ]]
local function reducedMotion(): boolean
	local ok, value = pcall(function()
		return (GuiService :: any).ReducedMotionEnabled
	end)
	return ok and value == true
end

--[[
	Requires a ModuleScript under ReplicatedStorage.Shared by path (waits up to SHARED_WAIT for
	each part to replicate), or nil (missing / errored). Example: sharedModule("World", "PreloadList")
]]
local function sharedModule(...: string): any
	local node: Instance? = ReplicatedStorage:WaitForChild("Shared", SHARED_WAIT)
	for _, name in { ... } do
		node = node and node:WaitForChild(name, SHARED_WAIT)
	end
	if node == nil or not node:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, node)
	return if ok then result else nil
end

--[[
	Queues the CRITICAL images in priority order: brand art + stud texture, then the hot UI icons
	(IconAssets hud / currency / ui / offer). PreloadQueue drops invalid / duplicate ids.
	@param queue the join preload queue (critical part open)
]]
local function queueImages(queue: PreloadQueue.Queue)
	for _, entry in BrandImages.Images do
		queue:add("image", entry.image, true)
	end
	queue:add("image", BrandImages.StudTexture, true)
	local IconAssets = sharedModule("Config", "IconAssets")
	if type(IconAssets) == "table" and type(IconAssets.Categories) == "table" then
		for _, category in HOT_CATEGORIES do
			for _, key in IconAssets.Categories[category] or {} do
				local ok, entry = pcall(IconAssets.get, key)
				if ok and type(entry) == "table" then
					queue:add("image", entry.image, true)
				end
			end
		end
	end
end

--[[
	A PreloadList content-id list (`forClientCritical` / `forClientDeferred`), or {} when the
	module or the function is missing or errors (the loading screen never breaks on it).
	@param PreloadList the required Shared.World.PreloadList, or nil
	@param fnName the list function
	@param tycoon profile.tycoon, or nil when the profile did not arrive
]]
local function meshIds(PreloadList: any, fnName: string, tycoon: any?): { string }
	local fn = if type(PreloadList) == "table" then PreloadList[fnName] else nil
	if type(fn) ~= "function" then
		return {}
	end
	local ok, ids = pcall(fn, tycoon)
	return if ok and type(ids) == "table" then ids else {}
end

-- Holder instances of the batch in flight (reused table; one preload thread per client).
local holderScratch: { Instance } = {}
-- ContentProvider:PreloadAsync's per-asset callback type (contentId, status).
type PreloadCallback = (...any) -> ...any

--[[
	Preloads one batch and releases its holders.

	Why instances, never bare content-id strings (QA 2026-10-30, measured in a Studio playtest):
	PreloadAsync on a string reported Failure even for images the HUD shows fine, and every mesh
	id failed with "Asset type does not match requested type" (~1,800 warnings per join, flooding
	the log ring buffer and hiding real errors), so nothing was warmed. An instance tells
	PreloadAsync the asset's type (ImageLabel.Image = image, SpecialMesh.MeshId = mesh); the same
	ids then report Success and the plot's MeshParts / the HUD's ImageLabels reuse the download.
	The holders are never parented, exist only for the batch (a handful per PreloadAsync call,
	never per frame) and are destroyed right after it.
	@param ids the batch's content ids (PreloadQueue.take)
	@param kinds their kinds ("image" -> ImageLabel, "mesh" -> SpecialMesh)
	@param onAsset optional per-asset callback (PreloadAsync's (contentId, status); progress of a
	       critical batch)
]]
local function preloadBatch(ids: { string }, kinds: { PreloadQueue.Kind }, onAsset: PreloadCallback?)
	table.clear(holderScratch)
	for index, id in ids do
		if kinds[index] == "image" then
			local holder = Instance.new("ImageLabel")
			holder.Image = id
			table.insert(holderScratch, holder)
		else
			local holder = Instance.new("SpecialMesh")
			holder.MeshType = Enum.MeshType.FileMesh
			holder.MeshId = id
			table.insert(holderScratch, holder)
		end
	end
	pcall(function()
		if onAsset ~= nil then
			ContentProvider:PreloadAsync(holderScratch, onAsset)
		else
			ContentProvider:PreloadAsync(holderScratch)
		end
	end)
	for _, holder in holderScratch do
		holder:Destroy()
	end
	table.clear(holderScratch)
end

--[[
	Step 6 — the join preload, ONE thread for the whole session (owner R122):
		1 right after game:IsLoaded() the Assets budget starts (Readiness.startAssets) and the
		  profile-independent critical part is queued: brand art, hot UI icons,
		  PreloadList.forClientCritical(nil) (frame, locked slot, BuyPad, area 1 base);
		2 as soon as the profile is known (or PROFILE_WAIT passed) the plot's own critical part
		  joins (forClientCritical(tycoon): owned builds + the next pads), the critical list is
		  sealed and the deferred list queued behind it (forClientDeferred(tycoon));
		3 critical batches run back to back while the bar waits; the Assets step completes when the
		  critical list is loaded — or is cut by ASSET_BUDGET (Readiness.applyBudget, every frame);
		4 then everything left (rest of the critical list, the deferred list) continues at
		  background pace (Readiness.pace), across the hand-off, until the queue is empty or the
		  player leaves; the queue is released at the end.
	@param tracker the screen's Readiness tracker
	@param player the local player
	@param profileOf () -> (ready, profile?) — the polling thread's latest profile state
]]
local function runPreload(tracker: Readiness.Tracker, player: Player, profileOf: () -> (boolean, any?))
	-- Shared modules (IconAssets, PreloadList) are only required after the initial snapshot
	-- (B4: PreloadList's WaitForChild chain expects a loaded game).
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
	tracker:startAssets(os.clock())
	local queue = PreloadQueue.new()
	queueImages(queue)
	local PreloadList = sharedModule("World", "PreloadList")
	queue:addAll("mesh", meshIds(PreloadList, "forClientCritical", nil), true)
	local ids: { string } = {}
	local kinds: { PreloadQueue.Kind } = {}
	local plotQueued = false
	local waitedFrom = os.clock()
	-- One callback for every critical batch (no per-batch closure).
	local onCriticalAsset: PreloadCallback = function()
		queue:markLoaded()
		tracker:setFraction("Assets", queue:criticalFraction())
	end
	while player.Parent ~= nil do
		if not plotQueued then
			local ready, profile = profileOf()
			if ready or os.clock() - waitedFrom >= Readiness.PROFILE_WAIT then
				local tycoon = if type(profile) == "table" then profile.tycoon else nil
				queue:addAll("mesh", meshIds(PreloadList, "forClientCritical", tycoon), true)
				queue:seal()
				queue:addAll("mesh", meshIds(PreloadList, "forClientDeferred", tycoon), false)
				plotQueued = true
			end
		end
		-- The bar stops waiting the moment the sealed critical list is loaded (never one deferred
		-- batch later). The budget is applied here too: after the hand-off the render loop that
		-- usually applies it is gone, and a tap / auto hand-off must not leave the rest of the
		-- preload at critical pace.
		if queue:criticalDone() then
			tracker:complete("Assets", os.clock())
		end
		tracker:applyBudget(os.clock())
		local size, gap = Readiness.pace(not tracker:isDone("Assets"))
		local count, critical = queue:take(size, ids, kinds)
		if count == 0 then
			if plotQueued then
				break -- everything is loaded
			end
			task.wait(POLL_SECONDS) -- the shared critical part is loaded; the plot part needs the profile
		else
			preloadBatch(ids, kinds, if critical then onCriticalAsset else nil)
			if critical then
				queue:settle()
				tracker:setFraction("Assets", queue:criticalFraction())
			end
			if gap > 0 then
				task.wait(gap)
			end
		end
	end
	tracker:complete("Assets", os.clock())
	queue:release()
	table.clear(ids)
	table.clear(kinds)
end

--[[ The local player's plot Model in Workspace.Plots (OwnerUserId match), or nil. ]]
local function ownPlot(userId: number): Instance?
	local plots = Workspace:FindFirstChild("Plots")
	if plots == nil then
		return nil
	end
	for _, plot in plots:GetChildren() do
		if plot:GetAttribute("OwnerUserId") == userId then
			return plot
		end
	end
	return nil
end

--[[
	The player's profile once it arrived: the ProfileReady attribute, or ClientState.profile
	(StarterPlayerScripts.Client.ClientState, read only after ClientBooted so this never
	initialises it early). Returns (ready, profile?).
]]
local function profileState(player: Player): (boolean, any?)
	local profile = nil
	if player:GetAttribute("ClientBooted") == true then
		local scripts = player:FindFirstChildOfClass("PlayerScripts")
		local client = scripts and scripts:FindFirstChild("Client")
		local module = client and client:FindFirstChild("ClientState")
		if module ~= nil and module:IsA("ModuleScript") then
			local ok, ClientState = pcall(require, module)
			if ok and type(ClientState) == "table" then
				profile = ClientState.profile
			end
		end
	end
	return player:GetAttribute("ProfileReady") == true or profile ~= nil, profile
end

-- The built UI (both layers) and the parts the animation loop drives.
type Ui = {
	backdrop: ScreenGui,
	hud: ScreenGui,
	backFade: CanvasGroup,
	hudFade: CanvasGroup,
	root: Frame,
	rootScale: UIScale,
	keyArt: ImageLabel,
	keyArtScale: UIScale,
	glow: Frame,
	nukey: ImageLabel,
	logo: ImageLabel,
	logoScale: UIScale,
	fallbackTitle: TextLabel,
	tip: TextLabel,
	caption: TextLabel,
	percent: TextLabel,
	fill: Frame,
	skip: TextButton,
}

--[[
	Builds both ScreenGuis under PlayerGui (first paint uses primitives only; images fade in
	when they load).
]]
local function build(playerGui: PlayerGui): Ui
	local backdrop = make("ScreenGui", {
		Name = "SellNukesLoadingBackdrop",
		IgnoreGuiInset = true,
		ScreenInsets = Enum.ScreenInsets.None,
		ResetOnSpawn = false,
		DisplayOrder = 1000,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	local backFade = make("CanvasGroup", {
		Name = "Fade",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = backdrop,
	}, {
		make("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new(SKY_TOP, SKY_BOTTOM),
		}),
	})
	local keyArtScale = make("UIScale", { Scale = 1 })
	local keyArt = make("ImageLabel", {
		Name = "KeyArt",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Image = BrandImages.Images.KeyArt.image,
		ImageTransparency = 1,
		ScaleType = Enum.ScaleType.Crop,
		Parent = backFade,
	}, { keyArtScale })
	make("ImageLabel", {
		Name = "Studs",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Image = BrandImages.StudTexture,
		ImageTransparency = 0.88,
		ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromOffset(96, 96),
		Parent = backFade,
	})
	make("Frame", {
		Name = "Scrim",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0.42),
		BackgroundColor3 = Color3.fromRGB(10, 18, 40),
		BorderSizePixel = 0,
		Parent = backFade,
	}, {
		make("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new(1, 0.35),
		}),
	})

	local hud = make("ScreenGui", {
		Name = "SellNukesLoading",
		IgnoreGuiInset = false,
		ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
		ResetOnSpawn = false,
		DisplayOrder = 1001,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	local hudFade = make("CanvasGroup", {
		Name = "Fade",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = hud,
	})
	local rootScale = make("UIScale", { Scale = 1 })
	local root = make("Frame", {
		Name = "Root",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(Composition.DESIGN_WIDTH, Composition.DESIGN_HEIGHT),
		BackgroundTransparency = 1,
		Parent = hudFade,
	}, { rootScale })

	-- Nukey over a pulsing reactor glow (left column).
	local glow = make("Frame", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.22, 0, 0.5, -20),
		Size = UDim2.fromOffset(440, 440),
		BackgroundColor3 = GLOW_GREEN,
		BorderSizePixel = 0,
		Parent = root,
	}, {
		make("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		make("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.35),
				NumberSequenceKeypoint.new(0.6, 0.75),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}),
	})
	local nukeySize = BrandImages.Images.Nukey.size
	local nukey = make("ImageLabel", {
		Name = "Nukey",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.22, 0, 0.5, -20),
		Size = UDim2.fromOffset(360 * nukeySize.X / nukeySize.Y, 360),
		BackgroundTransparency = 1,
		Image = BrandImages.Images.Nukey.image,
		ImageTransparency = 1,
		-- Explicitly above the Glow sibling (equal ZIndex siblings have no guaranteed order), so the
		-- reactor halo always sits BEHIND Nukey and never tints / hazes him (owner R47).
		ZIndex = 2,
		Parent = root,
	})

	-- Title (right column): image, with a text fallback until (or unless) it loads.
	local logoSize = BrandImages.Images.Logo.size
	local logoScale = make("UIScale", { Scale = 1 })
	local logo = make("ImageLabel", {
		Name = "Logo",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.64, 0.32),
		Size = UDim2.fromOffset(560, 560 * logoSize.Y / logoSize.X),
		BackgroundTransparency = 1,
		Image = BrandImages.Images.Logo.image,
		ImageTransparency = 1,
		Parent = root,
	}, { logoScale })
	local fallbackTitle = label({
		Name = "TitleFallback",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.64, 0.32),
		Size = UDim2.fromOffset(560, 200),
		Text = "SELL\nNUKES",
		TextSize = 96,
		TextColor3 = Color3.fromRGB(255, 214, 50),
		Parent = root,
	}, 6)

	-- Tip card (right column, under the title).
	local tip = label({
		Name = "Tip",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.64, 0.58),
		Size = UDim2.fromOffset(600, 90),
		TextSize = 28,
		TextWrapped = true,
		Text = "",
	}, 3)
	make("Frame", {
		Name = "TipCard",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.64, 0, 0.58, -10),
		Size = UDim2.fromOffset(640, 110),
		BackgroundColor3 = Color3.fromRGB(20, 26, 48),
		BackgroundTransparency = 0.35,
		Parent = root,
	}, {
		make("UICorner", { CornerRadius = UDim.new(0, 18) }),
		stroke(3, Enum.ApplyStrokeMode.Border),
	})
	tip.ZIndex = 2
	tip.Parent = root

	-- Footer: caption + percent over a chunky stud progress bar, SKIP on the right.
	local caption = label({
		Name = "Caption",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 80, 1, -92),
		Size = UDim2.new(1, -420, 0, 44),
		TextSize = 34,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = Readiness.new(0):caption(),
		Parent = root,
	}, 4)
	local percent = label({
		Name = "Percent",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -80, 1, -92),
		Size = UDim2.fromOffset(160, 44),
		TextSize = 34,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = BAR_FILL_LIGHT,
		Text = "0%",
		Parent = root,
	}, 4)
	local bar = make("Frame", {
		Name = "Bar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -40),
		Size = UDim2.new(1, -160, 0, 44),
		BackgroundColor3 = BAR_BACK,
		ClipsDescendants = true,
		Parent = root,
	}, {
		make("UICorner", { CornerRadius = UDim.new(0, 14) }),
		stroke(4, Enum.ApplyStrokeMode.Border),
	})
	local fill = make("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = bar,
	}, {
		make("UICorner", { CornerRadius = UDim.new(0, 14) }),
		make("UIGradient", { Rotation = 90, Color = ColorSequence.new(BAR_FILL_LIGHT, BAR_FILL) }),
		make("ImageLabel", {
			Name = "Studs",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Image = BrandImages.StudTexture,
			ImageTransparency = 0.55,
			ScaleType = Enum.ScaleType.Tile,
			TileSize = UDim2.fromOffset(44, 44),
		}),
	})
	-- TAP TO CONTINUE (after Readiness.TIMEOUT): a full-screen catcher so a tap / click anywhere
	-- continues, with a big red stud button as the visible target (selected for gamepads).
	make("TextButton", {
		Name = "ContinueCatcher",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		Visible = false,
		Active = false,
		Selectable = false,
		Parent = hudFade,
	})
	local skip = make("TextButton", {
		Name = "Continue",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -150),
		Size = UDim2.fromOffset(520, 70),
		BackgroundColor3 = SKIP_RED,
		Font = FONT,
		Text = "TAP TO CONTINUE",
		TextSize = 38,
		TextColor3 = Color3.new(1, 1, 1),
		AutoButtonColor = true,
		Visible = false,
		Active = false,
		Selectable = false,
		Parent = root,
	}, {
		make("UICorner", { CornerRadius = UDim.new(0, 14) }),
		stroke(4, Enum.ApplyStrokeMode.Border),
	})
	backdrop.Parent = playerGui
	hud.Parent = playerGui
	return {
		backdrop = backdrop,
		hud = hud,
		backFade = backFade,
		hudFade = hudFade,
		root = root,
		rootScale = rootScale,
		keyArt = keyArt,
		keyArtScale = keyArtScale,
		glow = glow,
		nukey = nukey,
		logo = logo,
		logoScale = logoScale,
		fallbackTitle = fallbackTitle,
		tip = tip,
		caption = caption,
		percent = percent,
		fill = fill,
		skip = skip,
	}
end

--[[ Refits the HUD canvas into the (device-safe) HUD ScreenGui at the current size. ]]
local function fit(ui: Ui)
	local scale, width, height = Composition.fit(ui.hud.AbsoluteSize, GuiService:IsTenFootInterface())
	ui.rootScale.Scale = scale
	ui.root.Size = UDim2.fromOffset(width, height)
end

--[[
	Shows the loading screen and drives it until hand-off. Safe to call once (later calls are
	ignored). Never yields the caller beyond building the first frame.
]]
function Loader.run()
	if started then
		return
	end
	started = true
	local bootStart = os.clock()
	pcall(function()
		ReplicatedFirst:RemoveDefaultLoadingScreen()
	end)
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local tracker = Readiness.new(os.clock())
	local reduced = reducedMotion()
	local device = Tips.device()
	local ui = build(playerGui)
	player:SetAttribute("LoadingScreenActive", true)
	fit(ui)
	-- Brand art (logo, Nukey, key art) starts invisible and fades in once loaded. QA 2026-10-30:
	-- gated on IsLoaded alone it never appeared (three Studio joins: glow without Nukey, text
	-- title, no key art), because nothing requested those images while they were fully
	-- transparent. Preloading the on-screen labels themselves fetches them (Success in ~1 s);
	-- their content ids are remembered so the render step can fade them in.
	local brandLoaded: { [string]: boolean } = {}
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync({ ui.logo, ui.nukey, ui.keyArt }, function(contentId: string, status)
				if status == Enum.AssetFetchStatus.Success then
					brandLoaded[contentId] = true
				end
			end)
		end)
	end)
	-- True once `image` can be shown (the engine says so, or its brand preload succeeded).
	local function imageReady(image: ImageLabel): boolean
		return image.IsLoaded or brandLoaded[image.Image] == true
	end
	local connections: { RBXScriptConnection } = {}
	table.insert(
		connections,
		ui.hud:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			fit(ui)
		end)
	)

	local finished = false
	local skipRequested = false
	local shown = 0
	local tipIndex = math.random(1, Tips.count())
	local tipChangedAt = os.clock()
	ui.tip.Text = Tips.line(tipIndex, device)

	-- Step 1: the initial world snapshot.
	task.spawn(function()
		if not game:IsLoaded() then
			game.Loaded:Wait()
		end
		tracker:complete("Loaded", os.clock())
	end)
	-- Steps 2-5: ClientBooted, profile, Workspace.WorldReady, the player's plot PlotReady
	-- (polled: attribute reads are cheap, and the plot Model can appear / be assigned late).
	local profile: any? = nil
	task.spawn(function()
		while
			not finished
			and not (
				tracker:isDone("Client")
				and tracker:isDone("Profile")
				and tracker:isDone("World")
				and tracker:isDone("Plot")
			)
		do
			local now = os.clock()
			if player:GetAttribute("ClientBooted") == true then
				tracker:complete("Client", now)
			end
			local ready, current = profileState(player)
			if ready then
				profile = current
				tracker:complete("Profile", now)
			end
			if Workspace:GetAttribute("WorldReady") == true then
				tracker:complete("World", now)
			end
			local plot = ownPlot(player.UserId)
			if player:GetAttribute("PlotReady") == true or (plot ~= nil and plot:GetAttribute("PlotReady") == true) then
				tracker:complete("Plot", now)
			end
			task.wait(POLL_SECONDS)
		end
	end)
	-- Step 6: the critical preload (bounded by ASSET_BUDGET), then the paced background
	-- continuation that outlives the screen (runPreload).
	task.spawn(runPreload, tracker, player, function(): (boolean, any?)
		return tracker:isDone("Profile"), profile
	end)
	-- TAP TO CONTINUE: the button, a tap / click anywhere (catcher), or A / Enter / Space.
	local catcher = ui.hudFade:FindFirstChild("ContinueCatcher") :: TextButton
	local function continueRequested()
		if ui.skip.Visible then
			skipRequested = true
		end
	end
	table.insert(connections, ui.skip.Activated:Connect(continueRequested))
	table.insert(connections, catcher.Activated:Connect(continueRequested))
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input: InputObject)
			if table.find(CONTINUE_KEYS, input.KeyCode) ~= nil then
				continueRequested()
			end
		end)
	)

	local renderConnection: RBXScriptConnection? = nil

	--[[
		Hand-off: bar to 100 %, cheer, publish the boot telemetry, fade both layers, destroy
		everything. Idempotent.
		@param reason "ready" | "budget" | "auto" (Readiness.handOff) or "tap" (TAP TO CONTINUE)
	]]
	local function finish(reason: string)
		if finished then
			return
		end
		finished = true
		if renderConnection ~= nil then
			renderConnection:Disconnect()
		end
		for _, connection in connections do
			connection:Disconnect()
		end
		ui.fill.Size = UDim2.fromScale(1, 1)
		ui.percent.Text = "100%"
		ui.caption.Text = if reason == "auto" then Readiness.TIMEOUT_CAPTION else Readiness.READY_CAPTION
		ui.skip.Visible = false
		if GuiService.SelectedObject ~= nil and GuiService.SelectedObject:IsDescendantOf(ui.hud) then
			GuiService.SelectedObject = nil
		end
		player:SetAttribute("LoadingScreenActive", false)
		-- R122 boot telemetry: every finished step's second + the reason, BEFORE BootSeconds
		-- (ClientPerfReporter reads the steps when BootSeconds changes).
		for _, attribute in tracker:stepAttributes(bootStart, reason) do
			player:SetAttribute(attribute.name, attribute.value)
		end
		player:SetAttribute("LoadingDone", true)
		player:SetAttribute(Readiness.BOOT_ATTRIBUTE, Readiness.bootSeconds(bootStart, os.clock()))
		local info = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.35, function()
			if not reduced then
				TweenService:Create(ui.logoScale, TweenInfo.new(0.2, Enum.EasingStyle.Back), { Scale = 1.12 }):Play()
			end
			TweenService:Create(ui.hudFade, info, { GroupTransparency = 1 }):Play()
			local fade = TweenService:Create(ui.backFade, info, { GroupTransparency = 1 })
			fade:Play()
			fade.Completed:Wait()
			ui.hud:Destroy()
			ui.backdrop:Destroy()
		end)
	end

	if not reduced then
		ui.logoScale.Scale = 0.6
	end
	renderConnection = RunService.RenderStepped:Connect(function(dt: number)
		local now = os.clock()
		local t = now - tracker.startedAt
		-- Progress bar (smoothed, never backwards) + caption.
		shown = Composition.approach(shown, tracker:progress(), dt)
		ui.fill.Size = UDim2.fromScale(shown, 1)
		ui.percent.Text = `{math.floor(shown * 100)}%`
		ui.caption.Text = tracker:caption()
		-- Images fade in once loaded; the text title hides when the logo image is ready.
		if imageReady(ui.keyArt) and ui.keyArt.ImageTransparency > 0.2 then
			ui.keyArt.ImageTransparency = math.max(0.2, ui.keyArt.ImageTransparency - dt * 2)
		end
		if imageReady(ui.nukey) and ui.nukey.ImageTransparency > 0 then
			ui.nukey.ImageTransparency = math.max(0, ui.nukey.ImageTransparency - dt * 3)
		end
		if imageReady(ui.logo) and ui.logo.ImageTransparency > 0 then
			ui.logo.ImageTransparency = math.max(0, ui.logo.ImageTransparency - dt * 3)
			ui.fallbackTitle.Visible = false
		end
		-- Motion (skipped with reduced motion).
		if not reduced then
			ui.logoScale.Scale = math.min(1, ui.logoScale.Scale + dt * 2.2)
			ui.nukey.Position = UDim2.new(0.22, 0, 0.5, -20 + math.sin(t * 2.4) * 10)
			ui.nukey.Rotation = math.sin(t * 1.7) * 5
			local pulse = 1 + 0.07 * math.sin(t * 3)
			ui.glow.Size = UDim2.fromOffset(440 * pulse, 440 * pulse)
			ui.keyArtScale.Scale = 1 + math.min(t / Readiness.TIMEOUT, 1) * 0.08
		end
		-- Tips rotate.
		if now - tipChangedAt >= Tips.ROTATE_SECONDS then
			tipChangedAt = now
			tipIndex += 1
			ui.tip.Text = Tips.line(tipIndex, device)
		end
		-- TAP TO CONTINUE after TIMEOUT while still loading (selected for gamepads once shown).
		if not ui.skip.Visible and tracker:canSkip(now) then
			ui.skip.Text = if device == "Gamepad"
				then "PRESS A TO CONTINUE"
				elseif device == "Keyboard" then "CLICK TO CONTINUE"
				else "TAP TO CONTINUE"
			ui.skip.Visible = true
			ui.skip.Active = true
			ui.skip.Selectable = true
			catcher.Visible = true
			catcher.Active = true
			if device == "Gamepad" then
				GuiService.SelectedObject = ui.skip
			end
		end
		if ui.skip.Visible then
			ui.caption.Text = Readiness.PROMPT_CAPTION
		end
		-- Hand off: the player answered TAP TO CONTINUE, or Readiness says ready / budget / auto.
		local go, reason = tracker:handOff(now)
		if skipRequested then
			finish("tap")
		elseif go then
			finish(reason)
		end
	end)
end

return Loader
