--!strict
--[[
	ForgetOnDestroy — strong-key Instance registries that clean themselves up (ported from RoBeasts).

	Purpose:
		UI modules often keep per-Instance state (a countdown per label, a binding per button).
		Weak Instance keys are unreliable in Roblox (an Instance's Lua wrapper can be collected
		while the Instance lives on, silently dropping live entries), so registries use STRONG
		keys and drop them when the Instance is destroyed. This tracker owns exactly those
		Destroying connections and calls the owner's `forget(instance)` once.

	Connects to: UI/Kit/StudUI (shared countdown ticker), UI/Widgets/InputGlyph (live glyphs),
	UI/Components (touch-hidden hints).

	Example:
		local rows: { [TextLabel]: number } = {}
		local tracker = ForgetOnDestroy.new(function(instance) rows[instance :: TextLabel] = nil end)
		rows[label] = 42
		tracker.track(label) -- rows[label] is cleared automatically when label is destroyed
]]

local ForgetOnDestroy = {}

export type Options = {
	-- Also forget the Instance when it leaves the DataModel (replicated world instances only).
	whenRemoved: boolean?,
}

export type Tracker = {
	-- Starts watching `instance` (no-op if already watched). `forget` runs once when it goes.
	track: (instance: Instance) -> (),
	-- Stops watching without calling `forget` (the caller already cleared its entries).
	untrack: (instance: Instance) -> (),
	-- True while `instance` is watched (tests and assertions).
	isTracked: (instance: Instance) -> boolean,
	-- Number of watched instances (tests: proves cleanup leaves nothing behind).
	count: () -> number,
}

--[[
	Creates a tracker. `forget(instance)` must clear every entry its caller keeps for
	`instance`; it runs at most once per `track` call, after the tracker has already dropped
	its own connections (so `forget` may call `track` again safely).

	@param forget   clears the caller's state for one Instance
	@param options  `whenRemoved`: also forget on leaving the DataModel (see the header)
	@return Tracker
]]
function ForgetOnDestroy.new(forget: (Instance) -> (), options: Options?): Tracker
	local whenRemoved = options ~= nil and options.whenRemoved == true
	-- Strong on purpose: the connections must live exactly as long as the watch.
	local watching: { [Instance]: { RBXScriptConnection } } = {}
	local watched = 0

	-- Drops the watch on `instance`; true if there was one.
	local function release(instance: Instance): boolean
		local connections = watching[instance]
		if connections == nil then
			return false
		end
		watching[instance] = nil
		watched -= 1
		for _, connection in connections do
			connection:Disconnect()
		end
		return true
	end

	local tracker = {} :: Tracker

	function tracker.track(instance: Instance)
		if watching[instance] ~= nil then
			return
		end
		local function gone()
			if release(instance) then
				forget(instance)
			end
		end
		local connections = { instance.Destroying:Connect(gone) }
		if whenRemoved then
			-- Fires for every ancestry change; only leaving the DataModel counts as gone.
			table.insert(
				connections,
				instance.AncestryChanged:Connect(function()
					if not instance:IsDescendantOf(game) then
						gone()
					end
				end)
			)
		end
		watching[instance] = connections
		watched += 1
	end

	function tracker.untrack(instance: Instance)
		release(instance)
	end

	function tracker.isTracked(instance: Instance): boolean
		return watching[instance] ~= nil
	end

	function tracker.count(): number
		return watched
	end

	return tracker
end

return table.freeze(ForgetOnDestroy)
