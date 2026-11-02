--!strict
--[[
	HappyHourScheduleScreen — the small Happy Hours schedule panel (owner R89 §2,
	docs/happy-hours.md), opened from the HUD chip (HappyHourChipScreen).

		┌ (clock) HAPPY HOURS ─────────────────────────────── [X] ┐
		│ Every hour on the hour, plus a mini Sprinkle Surge at :30! │
		│ [icon] CONFETTI STORM          Coins rain...     LIVE 3:12 │  ← live row (event colour)
		│ [icon] SPRINKLE SURGE          Rare flavours...    in 55:40 │
		│ [icon] DOUBLE POPS             Every payout...      4:00 PM │
		│ [icon] EGG STAMPEDE · DINO     Dino eggs...  [GO]   5:00 PM │  ← GO = travel there
		│ ...                                     (PanelRows rows)    │
		└─────────────────────────────────────────────────────────────┘

	Rows = the live event first, then the next HEADLINE events (HappyHourClient.upcoming; the :30 mini
	surge is named in the subtitle instead of filling every other row), with the
	player's LOCAL clock time (DateTime:FormatLocalTime) — times past local midnight say
	"Tomorrow". A world event happening elsewhere gets a GO button (WorldClient travel; a locked
	world shows its locked preview instead). Everything comes from the shared deterministic
	schedule + the replicated admin override, so the panel is exactly what will happen.

	Input (owner R11): StudUI.modalScreen — the red X / keyboard X / gamepad B close it; gamepad
	selection starts on the first GO button (else the close button); every button ≥ 44 pt.
	Updates: rebuilt on HappyHourClient.Changed, the time texts tick once per second only while the
	panel is open.

	Connects to: HappyHour/{HappyHourClient, HappyHourChipLogic}, UI/{Kit/StudUI, ScreenManager},
	Shared/Config/{HappyHourConfig, Worlds/WorldsConfig, UIStyleConfig}, Worlds/WorldClient.

	Example: ScreenManager.open("HappyHourSchedule", { source = "chip" })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HappyHourChipLogic = require(script.Parent.Parent.Parent.Parent.HappyHour.HappyHourChipLogic)
local HappyHourClient = require(script.Parent.Parent.Parent.Parent.HappyHour.HappyHourClient)
local HappyHourConfig = require(ReplicatedStorage.Shared.Config.HappyHourConfig)
local HappyHourLogic = require(ReplicatedStorage.Shared.Events.HappyHourLogic)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldClient = require(script.Parent.Parent.Parent.Parent.Worlds.WorldClient)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type Live = HappyHourLogic.Live

local NAME = "HappyHourSchedule"
local Client = HappyHourConfig.Client
local ROWS = HappyHourConfig.Schedule.PanelRows
-- Sized so every text stays >= 14 pt on a phone after ModalShell's fit (measured in Studio: a
-- phone's usable band is ~485 design px tall, so the window is short and wide; 4 rows = the live
-- event + the next headlines, the :30 mini surge is named in the subtitle and on the chip).
local WINDOW = Vector2.new(1000, 560)
local ROW_HEIGHT = 84
local ROW_GAP = 8
local TOP = 56 -- design px under the subtitle

-- A player-local clock string ("4:00 PM"), "Tomorrow 1:00 AM" past local midnight.
local function localTime(unix: number): string
	local ok, text = pcall(function(): string
		local stamp = DateTime.fromUnixTimestamp(math.floor(unix))
		local clock = stamp:FormatLocalTime("LT", "en-us")
		local today: any = DateTime.now():ToLocalTime()
		local day: any = stamp:ToLocalTime()
		if day.Day ~= today.Day or day.Month ~= today.Month then
			return `Tomorrow {clock}`
		end
		return clock
	end)
	return if ok then text else os.date("%H:%M", math.floor(unix))
end

-- One pooled row.
type Row = {
	card: StudUI.Card,
	icons: { [string]: Frame },
	name: TextLabel,
	blurb: TextLabel,
	time: TextLabel,
	go: StudUI.Button,
	live: Live?,
}

return StudUI.modalScreen({
	name = NAME,
	title = Client.PanelTitle,
	color = "purple",
	icon = Client.ChipIcon,
	size = WINDOW,
	lazy = true,
	build = function(window: StudUI.Window, _gui: ScreenGui): ScreenManager.ScreenHandle
		local body = window.body
		StudUI.text({
			name = "Subtitle",
			text = Client.PanelSubtitle,
			textSize = 28,
			scaled = true,
			color = UIStyleConfig.Neutral.Text,
			position = UDim2.fromOffset(24, 10),
			size = UDim2.new(1, -48, 0, 38),
			zIndex = 4,
			parent = body,
		})
		local empty = StudUI.text({
			name = "Empty",
			text = "Happy Hours are taking a break. Check back soon!",
			textSize = 34,
			scaled = true,
			position = UDim2.fromOffset(24, TOP + 40),
			size = UDim2.new(1, -48, 0, 60),
			zIndex = 4,
			parent = body,
		})
		empty.Visible = false

		local rows: { Row } = {}
		for index = 1, ROWS do
			local card = StudUI.card({
				name = `Row{index}`,
				color = "grey",
				size = UDim2.new(1, -40, 0, ROW_HEIGHT),
				position = UDim2.fromOffset(20, TOP + (index - 1) * (ROW_HEIGHT + ROW_GAP)),
				parent = body,
			})
			local name = StudUI.text({
				name = "Name",
				text = "",
				textSize = 34,
				font = "shout",
				scaled = true,
				align = Enum.TextXAlignment.Left,
				position = UDim2.fromOffset(78, 4),
				size = UDim2.new(1, -408, 0, 40),
				zIndex = 5,
				parent = card.content,
			})
			local blurb = StudUI.text({
				name = "Blurb",
				text = "",
				textSize = 28,
				scaled = true,
				align = Enum.TextXAlignment.Left,
				color = UIStyleConfig.Neutral.Text,
				position = UDim2.fromOffset(78, 46),
				size = UDim2.new(1, -408, 0, 34),
				zIndex = 5,
				parent = card.content,
			})
			local time = StudUI.text({
				name = "Time",
				text = "",
				textSize = 32,
				font = "number",
				scaled = true,
				align = Enum.TextXAlignment.Right,
				anchor = Vector2.new(1, 0.5),
				position = UDim2.new(1, -14, 0.5, 0),
				size = UDim2.fromOffset(200, 44),
				zIndex = 5,
				parent = card.content,
			})
			local go = StudUI.button({
				text = Client.TravelText,
				color = "green",
				name = "Go",
				size = UDim2.fromOffset(96, 56),
				textSize = 30,
				anchor = Vector2.new(1, 0.5),
				position = UDim2.new(1, -224, 0.5, 0),
				parent = card.content,
			})
			go.instance.Visible = false
			local row: Row = { card = card, icons = {}, name = name, blurb = blurb, time = time, go = go, live = nil }
			go.setCallback(function()
				local live = row.live
				if live ~= nil and HappyHourClient.travelTo(live) then
					ScreenManager.close(NAME)
				end
			end)
			table.insert(rows, row)
		end

		-- Shows the row's icon (built lazily per key).
		local function showIcon(row: Row, key: string)
			if row.icons[key] == nil then
				local icon = StudUI.icon(key, 60, 5)
				icon.AnchorPoint = Vector2.new(0, 0.5)
				icon.Position = UDim2.new(0, 10, 0.5, 0)
				icon.Parent = row.card.content
				row.icons[key] = icon
			end
			for other, frame in row.icons do
				frame.Visible = other == key
			end
		end

		local firstGo: GuiObject? = nil

		-- Rebuilds every row from the schedule.
		local function rebuild()
			local now = HappyHourClient.now()
			-- The live event (whatever it is) + the next HEADLINE events: the :30 mini surge repeats
			-- every hour, so listing it would halve how far ahead the panel looks.
			local list: { Live } = {}
			for index, entry in HappyHourClient.upcoming(ROWS * 2 + 2) do
				if #list >= ROWS then
					break
				end
				if not entry.mini or (index == 1 and entry.startsAt <= now) then
					table.insert(list, entry)
				end
			end
			empty.Visible = #list == 0
			firstGo = nil
			for index, row in rows do
				local entry = list[index]
				row.live = entry
				row.card.frame.Visible = entry ~= nil
				if entry == nil then
					row.go.instance.Visible = false
					continue
				end
				local def = HappyHourConfig.get(entry.id)
				if def == nil then
					row.card.frame.Visible = false
					continue
				end
				local worldDef = if entry.world ~= nil then WorldsConfig.get(entry.world) else nil
				local label = if entry.mini then `MINI {def.name}` else def.name
				row.name.Text = if worldDef ~= nil then `{label} · {string.upper(worldDef.name)}` else label
				row.blurb.Text = if entry.mini then Client.MiniTagline else def.tagline
				row.time.Text = HappyHourChipLogic.rowTime(entry, now, localTime)
				row.card.setColor((if entry.startsAt <= now then def.color else "grey") :: any)
				showIcon(row, def.icon)
				local canGo = entry.world ~= nil
					and not HappyHourClient.inWorld(entry)
					and WorldClient.isEnabled(entry.world :: string)
				row.go.instance.Visible = canGo
				if canGo and firstGo == nil then
					firstGo = row.go.instance
				end
			end
		end

		-- Ticks the time texts once per second while open.
		local generation = 0
		local function tick(gen: number)
			task.spawn(function()
				while gen == generation and ScreenManager.isOpen(NAME) do
					task.wait(1)
					if gen ~= generation or not ScreenManager.isOpen(NAME) then
						break
					end
					local now = HappyHourClient.now()
					local refreshNeeded = false
					for _, row in rows do
						local entry = row.live
						if entry ~= nil then
							if now >= entry.endsAt then
								refreshNeeded = true
							end
							row.time.Text = HappyHourChipLogic.rowTime(entry, now, localTime)
						end
					end
					if refreshNeeded then
						rebuild()
					end
				end
			end)
		end

		HappyHourClient.Changed:Connect(function()
			if ScreenManager.isOpen(NAME) then
				rebuild()
			end
		end)

		return {
			onOpen = function()
				generation += 1
				rebuild()
				tick(generation)
			end,
			onClose = function()
				generation += 1
			end,
			defaultSelection = function(): GuiObject?
				return firstGo or window.closeButton
			end,
		}
	end,
})
