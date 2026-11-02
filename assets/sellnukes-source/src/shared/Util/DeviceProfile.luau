--!strict
--[[
	DeviceProfile — classifies the client's device and computes the UI scale (ported from RoBeasts).

	Purpose:
		Pure classification + scale math (DeviceConfig holds the numbers) plus two tiny CLIENT
		readers (hasTouchScreen, isTenFootInterface) and `current()`, the snapshot UIController
		feeds into ScreenManager.setDeviceProfile on boot and on every viewport / input change.
		The pure functions (classify, uiScale) have no Roblox service access, so Lune tests can
		call them directly.

	Connects to: Shared/Config/DeviceConfig, Controllers/UIController, UI/ScreenManager
	(device-aware layout), UI/Widgets/HudPlacement and ModalShell (phone layouts).

	Example:
		local profile = DeviceProfile.current()
		if profile.isPhone then ... end
		print(DeviceProfile.uiScale(844, 390, "Phone")) --> 0.62 (floor)
]]

local DeviceConfig = require(script.Parent.Parent.Config.DeviceConfig)

export type DeviceClass = DeviceConfig.DeviceClass

-- Snapshot of the client's device (a fresh table per `current()` call; cache it per event).
export type Profile = {
	class: DeviceClass,
	isTouch: boolean, -- touch-screen device (Phone or Tablet; never Desktop / Console)
	isPhone: boolean,
	isTablet: boolean,
	viewportX: number, -- points
	viewportY: number,
	uiScale: number, -- DeviceProfile.uiScale for this viewport and class
}

local DeviceProfile = {}

-- GuiService:IsTenFootInterface() is fixed for the session: read it once (nil = not read yet).
local tenFootCache: boolean? = nil

-- True for a finite, strictly positive number (rejects NaN, ±inf, 0 and negatives).
local function positive(value: number): boolean
	return value == value and value > 0 and value < math.huge
end

--[[
	Classifies a device from its viewport size (points) and whether it is a touch-screen device.
	A ten-foot-interface client (Xbox / PlayStation) is always "Console" (checked first: consoles
	have no touch screen, and their class must not depend on the TV's resolution). A non-touch
	device is otherwise always "Desktop" whatever its window size (a small desktop window must
	keep the desktop scale policy). A touch device whose viewport short side is below
	DeviceConfig.PhoneShortSide is a "Phone", otherwise a "Tablet". An invalid viewport (0 / NaN,
	e.g. before the camera exists) classifies a touch device as "Phone" — the conservative,
	most-readable choice — and is re-evaluated on the next viewport change.
	@param viewportX viewport width in points
	@param viewportY viewport height in points
	@param touchScreen true on a touch-screen device (see hasTouchScreen)
	@param tenFoot true on a ten-foot-interface client (see isTenFootInterface); nil = false, so
	       every pre-console caller keeps its exact result
	@return "Phone" | "Tablet" | "Desktop" | "Console"
	Example: DeviceProfile.classify(1180, 820, true) --> "Tablet"
	Example: DeviceProfile.classify(1920, 1080, false, true) --> "Console"
]]
function DeviceProfile.classify(
	viewportX: number,
	viewportY: number,
	touchScreen: boolean,
	tenFoot: boolean?
): DeviceClass
	if tenFoot == true then
		return "Console"
	end
	if not touchScreen then
		return "Desktop"
	end
	if not positive(viewportX) or not positive(viewportY) then
		return "Phone"
	end
	return if math.min(viewportX, viewportY) < DeviceConfig.PhoneShortSide then "Phone" else "Tablet"
end

--[[
	The UI scale (fraction of the 1920x1080 design) for a viewport on a device class. See the
	module header for the per-class policy. An invalid viewport returns the class's floor.
	@return scale in [DeviceConfig.Scale[class].min, .max]
	Example: DeviceProfile.uiScale(1920, 1080, "Desktop") --> 1
]]
function DeviceProfile.uiScale(viewportX: number, viewportY: number, class: DeviceClass): number
	local scales = DeviceConfig.Scale
	local limits = if class == "Phone"
		then scales.Phone
		elseif class == "Tablet" then scales.Tablet
		elseif class == "Console" then scales.Console
		else scales.Desktop
	if not positive(viewportX) or not positive(viewportY) then
		return limits.min
	end
	if class == "Phone" then
		-- Height-led: the short side (landscape height) against the design height.
		return math.clamp(math.min(viewportX, viewportY) / DeviceConfig.DesignHeight, limits.min, limits.max)
	end
	-- Desktop / Tablet / Console: fit the whole design (the smaller axis ratio, so nothing is cut off).
	local fit = math.min(viewportX / DeviceConfig.DesignWidth, viewportY / DeviceConfig.DesignHeight)
	return math.clamp(fit, limits.min, limits.max)
end

--[[
	CLIENT: true on a touch-screen device. A touch screen with no keyboard (phones, tablets) is
	always one; a touch screen WITH a keyboard (touch laptops, tablets with a keyboard cover)
	counts only while the engine reports touch as the preferred input
	(UserInputService.PreferredInput; read in a pcall so an older client without the property
	falls back to "keyboard present = not a touch device").
]]
function DeviceProfile.hasTouchScreen(): boolean
	local UserInputService = game:GetService("UserInputService")
	if not UserInputService.TouchEnabled then
		return false
	end
	if not UserInputService.KeyboardEnabled then
		return true
	end
	local ok, preferredTouch = pcall(function(): boolean
		return UserInputService.PreferredInput == Enum.PreferredInput.Touch
	end)
	return ok and preferredTouch
end

--[[
	CLIENT: true on a ten-foot-interface client (Xbox / PlayStation). Read once per session and
	cached (the engine fixes it at launch). Wrapped in a pcall so a context without GuiService
	(or an engine build that ever drops the method) falls back to "not a console": the device
	then keeps the Desktop class it had before the Console class existed.
	Example: if DeviceProfile.isTenFootInterface() then ... end
]]
function DeviceProfile.isTenFootInterface(): boolean
	local cached = tenFootCache
	if cached ~= nil then
		return cached
	end
	local ok, tenFoot = pcall(function(): boolean
		return game:GetService("GuiService"):IsTenFootInterface()
	end)
	local value = ok and tenFoot == true
	-- Fixed for a live session, but Studio's device emulator can switch to a console mid-session
	-- (B16 QA): only cache outside Studio. The pcall keeps pure Lune tests working.
	local studio = false
	pcall(function()
		studio = game:GetService("RunService"):IsStudio()
	end)
	if not studio then
		tenFootCache = value
	end
	return value
end

--[[
	CLIENT: the current device profile (fresh table). Reads the camera viewport; before the
	camera exists the viewport is 0x0 and the profile is the conservative one (see classify).
	Re-read it when the viewport changes (Camera:GetPropertyChangedSignal("ViewportSize")).
	Example:
		local profile = DeviceProfile.current()
		print(profile.class, profile.uiScale)
]]
function DeviceProfile.current(): Profile
	local camera = game:GetService("Workspace").CurrentCamera
	local viewport = if camera ~= nil then camera.ViewportSize else Vector2.zero
	local class = DeviceProfile.classify(
		viewport.X,
		viewport.Y,
		DeviceProfile.hasTouchScreen(),
		DeviceProfile.isTenFootInterface()
	)
	return {
		class = class,
		isTouch = class == "Phone" or class == "Tablet",
		isPhone = class == "Phone",
		isTablet = class == "Tablet",
		viewportX = viewport.X,
		viewportY = viewport.Y,
		uiScale = DeviceProfile.uiScale(viewport.X, viewport.Y, class),
	}
end

return table.freeze(DeviceProfile)
