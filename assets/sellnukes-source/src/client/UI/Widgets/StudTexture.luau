--!strict
-- StudTexture — binds stud-textured ImageLabels to the best available stud source (ported from
-- RoBeasts). Connects to Widgets/StudTextureLocal, Shared/Config/PanelTextureAssets and every
-- stud surface (PanelBackdrop, Kit/StudUI, LauncherStuds).
-- Prefer the shared local bitmap of the original stud art. When editable images are
-- unavailable, recover its uploaded asset through one shared bounded request sequence.
-- PreloadAsync may return normally after Failure; only its matching Success callback counts.
-- No render loop, per-surface pixel buffers, style changes or weak Instance keys are involved.
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Assets = require(ReplicatedStorage.Shared.Config.PanelTextureAssets)
local Config = require(script.Parent.StudTextureConfig)
local LocalTexture = require(script.Parent.StudTextureLocal)

type Binding = {
	image: ImageLabel,
	live: boolean,
	resetting: boolean,
	connections: { RBXScriptConnection },
}
local StudTexture = {}
local IMAGE = Assets.StudImage
local bindings: { [ImageLabel]: Binding } = {}
local attempts, nextAttemptAt = 0, 0
local settledUntil: number? = nil
local queued: thread? = nil
local inFlight = false
local queue: () -> ()

-- A detached image may still be under construction. Only explicit cleanup/Destroying,
-- successful native loading, or changing its Image ends this binding; Parent is irrelevant.
local function release(binding: Binding)
	if not binding.live then
		return
	end
	binding.live = false
	if bindings[binding.image] == binding then
		bindings[binding.image] = nil
	end
	for _, connection in binding.connections do
		connection:Disconnect()
	end
	table.clear(binding.connections)
	if next(bindings) == nil and queued ~= nil then
		task.cancel(queued)
		queued = nil
	end
end

-- Failed native ImageLabel fetches can remain stranded even after the cache recovers.
-- Reassign only this exact asset on still-unloaded live labels, never a loaded image or a
-- caller's replacement artwork. Reentrant destruction between the two writes is respected.
local function retryImages()
	for image, binding in bindings do
		if image.IsLoaded or image.Image ~= IMAGE then
			release(binding)
		else
			binding.resetting = true
			image.Image = ""
			if binding.live and image.Image == "" then
				image.Image = IMAGE
			end
			binding.resetting = false
			if binding.live and (image.IsLoaded or image.Image ~= IMAGE) then
				release(binding)
			end
		end
	end
end

-- Called only by a single queued task. PreloadAsync yields, so the completion must inspect
-- current bindings instead of retaining a snapshot of UI that may have been destroyed.
local function request()
	queued = nil
	if inFlight or next(bindings) == nil then
		return
	end
	inFlight = true
	if attempts > 0 then
		retryImages()
	end
	if next(bindings) == nil then
		inFlight = false
		return
	end
	attempts += 1
	local delivered = false
	local ok = pcall(function()
		ContentProvider:PreloadAsync({ IMAGE }, function(contentId: string, status: Enum.AssetFetchStatus)
			if contentId == IMAGE then
				delivered = status == Enum.AssetFetchStatus.Success
			end
		end)
	end)
	inFlight = false
	if ok and delivered then
		-- A successful fetch ends this automatic burst. Reset existing failed labels once
		-- against the warm cache; fresh native loading is still verified by IsLoaded.
		settledUntil = os.clock() + Config.RearmSeconds
		retryImages()
	elseif attempts >= Config.MaxAttempts then
		settledUntil = os.clock() + Config.RearmSeconds
	else
		nextAttemptAt = os.clock() + Config.RetrySeconds[attempts]
		queue()
	end
end

-- All bind/refresh calls coalesce; user-driven refresh cannot bypass a pending backoff.
queue = function()
	if inFlight or queued ~= nil or next(bindings) == nil or settledUntil ~= nil then
		return
	end
	local delay = math.max(0, nextAttemptAt - os.clock())
	queued = task.delay(delay, request)
end

--[[
	Re-arms the uploaded-image recovery after its cooldown (called when a panel opens).
	Opening a panel after the bounded burst may rearm recovery, but no timer rearms itself.
	The same cooldown follows Success so repeated open/layout refreshes cannot refetch cached
	art continuously while a label is not yet painted by the engine.
]]
function StudTexture.refresh()
	local cooldown = settledUntil
	if cooldown ~= nil then
		if os.clock() < cooldown then
			return
		end
		settledUntil = nil
		attempts, nextAttemptAt = 0, 0
	end
	queue()
end

--[[
	Binds a stud ImageLabel: switches it to the shared local bitmap, or (when that is
	unavailable) watches the uploaded fallback and retries failed loads with bounded backoff.
	Bind after assigning `image.Image = PanelTextureAssets.StudImage` (before parenting is fine).
	Rebinding replaces ownership; an older cleanup cannot unregister the newer binding.
	@param image the stud ImageLabel
	@return cleanup function (idempotent; also runs when the image is destroyed)
	Example: local stop = StudTexture.bind(tile)
]]
function StudTexture.bind(image: ImageLabel): () -> ()
	local previous = bindings[image]
	if previous ~= nil then
		release(previous)
	end
	if image.Image ~= IMAGE then
		return function() end
	end
	-- Release old fallback ownership before switching content. The local image need not
	-- report IsLoaded immediately, and must never be cleared by an uploaded-asset retry.
	-- The local bitmap only when the owner switched it on (PanelTextureAssets.LocalBitmap header).
	if (Assets.LocalBitmap and LocalTexture.apply(image)) or image.IsLoaded then
		return function() end
	end
	local binding: Binding = { image = image, live = true, resetting = false, connections = {} }
	bindings[image] = binding
	table.insert(
		binding.connections,
		image.Destroying:Connect(function()
			release(binding)
		end)
	)
	table.insert(
		binding.connections,
		image:GetPropertyChangedSignal("Image"):Connect(function()
			if not binding.resetting and image.Image ~= IMAGE then
				release(binding)
			end
		end)
	)
	table.insert(
		binding.connections,
		image:GetPropertyChangedSignal("IsLoaded"):Connect(function()
			if image.IsLoaded then
				release(binding)
			end
		end)
	)
	StudTexture.refresh()
	return function()
		release(binding)
	end
end

return table.freeze(StudTexture)
