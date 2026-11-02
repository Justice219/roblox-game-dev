--!strict
--[[
	StandClient — the egg stands' stud-UI odds billboards and the display eggs' idle bob (client).

	Billboards (one per Workspace.PetStands Stand_<eggId>, built when the stand streams in; the
	stands are ModelStreamingMode Persistent so that is right after join):
		egg name · price (green when affordable, red when not, grey "Reach <area>" while locked,
		acorns for the Harvest Egg, Bones for Dino Valley's eggs — "unlock Dino Valley" while that
		world is locked — via Pets/EggView, "Held only" for none) · the four pets with their rarity colour
		and THE ODDS THE SERVER ROLLS (EggConfig.oddsFor; with the LuckyEggs pass the boosted odds
		in gold) · the pity line ("Epic guaranteed in 37"). Spec §8: odds shown on the stand.
		Paid random items: where the player's region restricts them (profile.policy →
		EggConfig.policyState) a bought egg's price line reads "NOT IN YOUR REGION" in grey — the
		odds stay visible for everyone; held eggs still say "hatch free".
	A crate-stall sign tops the primitive fallback stall only (the hub mesh stall's caption is written
	on its own Sign board by Client/Lobby/StallSigns, owner R101).

	Updates are event-driven: ProfileChanged with cash / passes / tycoon / event / pets / policy /
	worlds / worldCash fields repaints (text only, no rebuild). BillboardGui.MaxDistance culls far stands.
	Idle: display eggs within BOB_RANGE turn + bob on PetController's single render step (PivotTo
	of one small model each); far ones are left alone; Reduce Motion parks them.

	Connects to: Shared/Config/{EggConfig, PetConfig, UIStyleConfig, Worlds/WorldsConfig},
	Client/Pets/EggView (price / balance / lock text), Client/ClientState, UI/Create, UI/Widgets/StudWindow,
	Client/Pets/PetController (start + step), Server/Pets/EggStands (the stand models).

	Example: StandClient.start(); StandClient.step(dt, clock, reducedMotion)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.UI.Create)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local EggView = require(script.Parent.EggView)
local MeshPlacement = require(ReplicatedStorage.Shared.World.MeshPlacement)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local StudWindow = require(script.Parent.Parent.UI.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local Neutral = UIStyleConfig.Neutral
local LOCAL = Players.LocalPlayer

-- Billboard size (studs) and its height above the display egg's pivot.
local SIZE_STUDS = Vector2.new(8.5, 8)
local OFFSET_Y = 9.2
local MAX_DISTANCE = 75
-- Display eggs closer than this bob / turn.
local BOB_RANGE = 90

type Stand = {
	eggId: string,
	model: Model,
	display: Model?,
	base: CFrame?,
	gui: BillboardGui,
	price: TextLabel,
	rows: { { name: TextLabel, chance: TextLabel } },
	footer: TextLabel,
	phase: number,
	-- What the billboard last showed (paint inputs); a profile change that leaves it equal skips
	-- every property write (perf pass 2026-10-30: cash ticks repainted all stands ~4x / s).
	painted: string?,
}

local StandClient = {}

local stands: { [Model]: Stand } = {}
local started = false

-- Card colour per egg (tier groups read at a glance).
local function colorOf(egg: EggConfig.EggDef): string
	if egg.card ~= nil then
		-- An egg's own card colour (world eggs: Dino green / red, Moon purple / blue).
		return egg.card
	elseif egg.currency == "acorns" then
		return "orange"
	elseif egg.world ~= WorldsConfig.MAIN then
		-- A world egg without its own card: the early egg reads green, the later one red-hot.
		return if egg.area <= 3 then "green" else "red"
	elseif egg.area <= 2 then
		return "green"
	elseif egg.area <= 5 then
		return "blue"
	elseif egg.area <= 8 then
		return "purple"
	end
	return "red"
end

-- An outlined, scaled label.
local function label(
	parent: Instance,
	name: string,
	text: string,
	size: UDim2,
	color: Color3,
	font: Font,
	align: Enum.TextXAlignment?,
	order: number?
): TextLabel
	return Create.new("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		TextScaled = true,
		FontFace = font,
		TextColor3 = color,
		Text = text,
		Size = size,
		TextXAlignment = align or Enum.TextXAlignment.Center,
		LayoutOrder = order or 0,
		Parent = parent,
		Children = {
			Create.new("UIStroke", {
				Color = Neutral.TextStroke,
				Thickness = 2,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
				LineJoinMode = Enum.LineJoinMode.Round,
			}),
		},
	}) :: TextLabel
end

-- Repaints one stand's price / odds / footer for the current profile (no-op when every shown input is
-- unchanged since the last paint: `stand.painted` holds their signature).
local function paint(stand: Stand)
	local egg = EggConfig.get(stand.eggId)
	if egg == nil then
		return
	end
	local profile: any = ClientState.profile or {}
	local passes = if type(profile.passes) == "table" then profile.passes else {}
	local lucky = passes[EggConfig.LuckPass] == true
	local held = 0
	if type(profile.pets) == "table" and type(profile.pets.eggs) == "table" then
		held = tonumber(profile.pets.eggs[egg.id]) or 0
	end
	local pityCounter = 0
	if type(profile.pets) == "table" and type(profile.pets.pity) == "table" then
		pityCounter = tonumber(profile.pets.pity[egg.id]) or 0
	end
	-- World + area progress of the egg's own world (Dino Valley eggs need Dino unlocked + its area).
	local locked = not EggConfig.isUnlocked(profile, egg)
	local worldOpen = EggView.worldOpen(profile, egg)
	local restricted = EggConfig.policyState(profile.policy) == "restricted" and EggConfig.needsPolicy(egg, held, 1)
	local balance = EggView.balance(profile, egg)
	local affordable = if egg.currency == "acorns" then balance >= egg.price else balance >= egg.price or held > 0
	-- Every input the billboard shows; unchanged → nothing to write (most cash / Bones ticks).
	local signature = `{locked}|{worldOpen}|{restricted}|{affordable}|{lucky}|{held}|{pityCounter}`
	if stand.painted == signature then
		return
	end
	stand.painted = signature

	if locked then
		stand.price.Text = EggView.lockText(profile, egg)
		stand.price.TextColor3 = Neutral.TextDim
	elseif restricted then
		-- Paid random items are restricted here: nothing to buy (odds below stay visible).
		stand.price.Text = EggConfig.PolicyText.Locked
		stand.price.TextColor3 = Neutral.TextDim
	else
		stand.price.Text = EggView.formatAmount(egg, egg.price)
		stand.price.TextColor3 = if affordable then Neutral.CashGreen else Color3.fromRGB(255, 90, 90)
	end

	local odds = EggConfig.oddsFor(egg, lucky)
	for index, row in stand.rows do
		local slot = egg.slots[index]
		local pet = PetConfig.get(slot.pet)
		row.name.Text = if pet ~= nil then pet.name else slot.pet
		local boosted = lucky and table.find(egg.luckySlots, index) ~= nil
		row.chance.Text = EggConfig.formatChance(odds[index])
		-- Lucky-boosted odds read in gold.
		row.chance.TextColor3 = if boosted then Color3.fromRGB(255, 220, 70) else Neutral.Text
	end

	local pity = egg.pity
	if held > 0 then
		stand.footer.Text = `You have {held} - hatch free!`
	elseif pity ~= nil then
		local top = PetConfig.get(egg.slots[pity.slot].pet)
		local left = EggConfig.pityLeft(egg, pityCounter) or pity.hatches
		stand.footer.Text = `{if top ~= nil then top.rarity else "Top"} guaranteed in {left}`
	else
		stand.footer.Text = egg.blurb
	end
end

-- Builds the billboard of one stand model.
-- A local (client-only) invisible anchor part above the display egg: the billboard stays steady
-- while the egg bobs.
local function billboardAnchor(model: Model): BasePart?
	local display = model:FindFirstChild("DisplayEgg")
	if display == nil or not display:IsA("Model") then
		return nil
	end
	local anchor = Instance.new("Part")
	anchor.Name = "BillboardAnchor"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	local height = model:GetAttribute("BillboardHeight")
	anchor.CFrame = CFrame.new(
		display:GetPivot().Position + Vector3.new(0, if type(height) == "number" then height else OFFSET_Y, 0)
	)
	anchor.Parent = model
	return anchor
end

-- The hub stand mesh named `hubName`: Nuke Town's Workspace.Hub.Art / HarvestFeastSquare, or a
-- world's own hub (Workspace.Worlds.<world>, built by HubBuilder.buildWorld; R57) for world eggs.
local function findHubModel(worldId: unknown, hubName: string): Instance?
	if type(worldId) == "string" and worldId ~= WorldsConfig.MAIN then
		local worlds = Workspace:FindFirstChild("Worlds")
		local world = if worlds ~= nil then worlds:FindFirstChild(worldId) else nil
		return if world ~= nil then world:FindFirstChild(hubName, true) else nil
	end
	local hub = Workspace:FindFirstChild("Hub")
	local art = if hub ~= nil then hub:FindFirstChild("Art") else nil
	local square = Workspace:FindFirstChild("HarvestFeastSquare")
	return (if art ~= nil then art:FindFirstChild(hubName) else nil)
		or (if square ~= nil then square:FindFirstChild(hubName, true) else nil)
end

-- Writes the egg's name + price on the stand mesh's Sign face (B8e hub stands, the Harvest stand,
-- or a world's nest stands — the model named by the stand's HubModel attribute), once it has
-- streamed in.
local function dressSign(model: Model, egg: EggConfig.EggDef)
	local hubName = model:GetAttribute("HubModel")
	if type(hubName) ~= "string" then
		return
	end
	task.spawn(function()
		-- A world's hub is built lazily on the first trip there (W4 HubBuilder.buildWorld): wait for
		-- its root with a cheap non-recursive check before the bounded search below.
		local worldId = model:GetAttribute("WorldId")
		if type(worldId) == "string" and worldId ~= WorldsConfig.MAIN then
			while model.Parent ~= nil do
				local worlds = Workspace:FindFirstChild("Worlds")
				if worlds ~= nil and worlds:FindFirstChild(worldId) ~= nil then
					break
				end
				task.wait(10)
			end
		end
		for _ = 1, 24 do
			if model.Parent == nil then
				return
			end
			local stand = findHubModel(worldId, hubName)
			local sign = if stand ~= nil then stand:FindFirstChild("Sign", true) else nil
			if sign ~= nil and sign:IsA("BasePart") then
				if sign:FindFirstChild("EggSign") == nil then
					local gui = Create.new("SurfaceGui", {
						Name = "EggSign",
						-- A yawed mesh piece's own Front faces the model's back (MeshPlacement rule 3).
						Face = MeshPlacement.face(sign, Enum.NormalId.Front),
						SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
						PixelsPerStud = 40,
						LightInfluence = 0,
						MaxDistance = MAX_DISTANCE,
						Adornee = sign,
						ResetOnSpawn = false,
					}) :: SurfaceGui
					label(gui, "Name", egg.name, UDim2.fromScale(0.94, 0.55), Neutral.Text, UIStyleConfig.Fonts.Title).Position =
						UDim2.fromScale(0.03, 0.04)
					local price = EggView.formatAmount(egg, egg.price)
					label(
						gui,
						"Price",
						price,
						UDim2.fromScale(0.94, 0.38),
						Neutral.CashGreen,
						UIStyleConfig.Fonts.Number
					).Position =
						UDim2.fromScale(0.03, 0.58)
					gui.Parent = LOCAL:FindFirstChildOfClass("PlayerGui")
					sign.Destroying:Connect(function()
						gui:Destroy()
					end)
				end
				return
			end
			task.wait(5)
		end
	end)
end

local function addStand(model: Model)
	if stands[model] ~= nil then
		return
	end
	local eggId = model:GetAttribute("EggId")
	local egg = EggConfig.get(eggId)
	if egg == nil then
		return
	end
	local adornee = billboardAnchor(model)
	if adornee == nil then
		return
	end
	dressSign(model, egg)
	local gui = Create.new("BillboardGui", {
		Name = `EggOdds_{egg.id}`,
		Adornee = adornee,
		Size = UDim2.fromScale(SIZE_STUDS.X, SIZE_STUDS.Y),
		StudsOffsetWorldSpace = Vector3.zero,
		MaxDistance = MAX_DISTANCE,
		LightInfluence = 0,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}) :: BillboardGui
	local card = Create.new("Frame", { Name = "Card", Size = UDim2.fromScale(1, 1), Parent = gui }) :: Frame
	StudWindow.surface(card, colorOf(egg) :: any, { edge = 3, corner = 14 })
	local content = Create.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.92, 0.94),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 2,
		Parent = card,
		Children = {
			Create.new("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0.01, 0),
			}),
		},
	}) :: Frame
	label(content, "Title", egg.name, UDim2.fromScale(1, 0.16), Neutral.Text, UIStyleConfig.Fonts.Title, nil, 1)
	local price =
		label(content, "Price", "", UDim2.fromScale(1, 0.14), Neutral.CashGreen, UIStyleConfig.Fonts.Number, nil, 2)
	local rows: { { name: TextLabel, chance: TextLabel } } = {}
	for index, slot in egg.slots do
		local pet = PetConfig.get(slot.pet)
		local rarity = if pet ~= nil then PetConfig.rarity(pet.rarity) else nil
		local row = Create.new("Frame", {
			Name = `Odds{index}`,
			BackgroundColor3 = Neutral.Well,
			BackgroundTransparency = 0.25,
			Size = UDim2.fromScale(1, 0.135),
			LayoutOrder = 2 + index,
			Parent = content,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.25, 0) }) },
		}) :: Frame
		Create.new("Frame", {
			Name = "Rarity",
			BackgroundColor3 = if rarity ~= nil then rarity.color else Neutral.TextDim,
			Size = UDim2.fromScale(0.05, 0.7),
			Position = UDim2.fromScale(0.03, 0.15),
			Parent = row,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
		})
		local name = label(
			row,
			"Pet",
			"",
			UDim2.fromScale(0.6, 0.8),
			if rarity ~= nil then rarity.color else Neutral.Text,
			UIStyleConfig.Fonts.Title,
			Enum.TextXAlignment.Left
		)
		name.Position = UDim2.fromScale(0.11, 0.1)
		local chance = label(
			row,
			"Chance",
			"",
			UDim2.fromScale(0.3, 0.8),
			Neutral.Text,
			UIStyleConfig.Fonts.Number,
			Enum.TextXAlignment.Right
		)
		chance.Position = UDim2.fromScale(0.67, 0.1)
		table.insert(rows, { name = name, chance = chance })
	end
	local footer =
		label(content, "Footer", "", UDim2.fromScale(1, 0.11), Neutral.TextDim, UIStyleConfig.Fonts.Body, nil, 10)
	gui.Parent = LOCAL:FindFirstChildOfClass("PlayerGui")

	local display = model:FindFirstChild("DisplayEgg")
	local stand: Stand = {
		eggId = egg.id,
		model = model,
		display = if display ~= nil and display:IsA("Model") then display else nil,
		base = if display ~= nil and display:IsA("Model") then display:GetPivot() else nil,
		gui = gui,
		price = price,
		rows = rows,
		footer = footer,
		phase = egg.order * 0.7,
		painted = nil,
	}
	stands[model] = stand
	paint(stand)
end

-- Drops a stand's billboard (streamed out / destroyed).
local function removeStand(model: Model)
	local stand = stands[model]
	if stand ~= nil then
		stands[model] = nil
		stand.gui:Destroy()
	end
end

--[[
	The crate stall sign, floating above the middle display crate — ONLY for the primitive fallback
	stall (no awning). The hub mesh stall (HubModel attribute set by Server/Pets/EggStands) gets
	"SUPPLY CRATES" written on its own Sign board above the awning by Client/Lobby/StallSigns (owner
	R101: this billboard sat inside the awning, which cut the card and its text off).
]]
local function addCrateSign(model: Model)
	if model:FindFirstChild("CrateSign") ~= nil or type(model:GetAttribute("HubModel")) == "string" then
		return
	end
	local middle = model:FindFirstChild("Crate_mega_crate")
	local position: Vector3? = nil
	if middle ~= nil and middle:IsA("Model") then
		position = middle:GetPivot().Position
	elseif middle ~= nil and middle:IsA("BasePart") then
		position = middle.Position
	elseif model.PrimaryPart ~= nil then
		position = model.PrimaryPart.Position
	end
	if position == nil then
		return
	end
	local anchor = Instance.new("Part")
	anchor.Name = "CrateSign"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CFrame = CFrame.new(position + Vector3.new(0, 5.4, 0))
	anchor.Parent = model
	local gui = Create.new("BillboardGui", {
		Name = "CrateSign",
		Adornee = anchor,
		Size = UDim2.fromScale(9, 2.6),
		MaxDistance = MAX_DISTANCE,
		LightInfluence = 0,
		ResetOnSpawn = false,
	}) :: BillboardGui
	local card = Create.new("Frame", { Name = "Card", Size = UDim2.fromScale(1, 1), Parent = gui }) :: Frame
	StudWindow.surface(card, "yellow", { edge = 3, corner = 14 })
	local title =
		label(card, "Title", "SUPPLY CRATES", UDim2.fromScale(0.92, 0.8), Neutral.Text, UIStyleConfig.Fonts.Shout)
	title.Position = UDim2.fromScale(0.04, 0.1)
	title.ZIndex = 2
	gui.Parent = LOCAL:FindFirstChildOfClass("PlayerGui")
	model.Destroying:Connect(function()
		gui:Destroy()
	end)
end

-- Watches one child of the PetStands folder.
local function watch(child: Instance)
	if not child:IsA("Model") then
		return
	end
	if child:GetAttribute("EggId") ~= nil then
		-- The display egg may replicate a moment after the model.
		if child:FindFirstChild("DisplayEgg") == nil then
			task.spawn(function()
				if child:WaitForChild("DisplayEgg", 30) ~= nil then
					addStand(child)
				end
			end)
		else
			addStand(child)
		end
		child.Destroying:Connect(function()
			removeStand(child)
		end)
	elseif child:GetAttribute("CrateStall") == true then
		-- The display crates may replicate a moment after the model.
		task.spawn(function()
			child:WaitForChild("PromptPoint", 30)
			addCrateSign(child)
		end)
	end
end

--[[ Starts watching the stands folder and repainting on profile changes. ]]
function StandClient.start()
	if started then
		return
	end
	started = true
	task.spawn(function()
		local folder = Workspace:WaitForChild("PetStands", 120)
		if folder == nil then
			return
		end
		for _, child in folder:GetChildren() do
			watch(child)
		end
		folder.ChildAdded:Connect(watch)
		folder.ChildRemoved:Connect(function(child: Instance)
			if child:IsA("Model") then
				removeStand(child)
			end
		end)
	end)
	ClientState.ProfileChanged:Connect(function(_profile: any, fields: { string }?)
		local relevant = fields == nil
		if fields ~= nil then
			for _, field in fields do
				if
					field == "cash"
					or field == "passes"
					or field == "tycoon"
					or field == "event"
					or field == "pets"
					or field == "policy"
					or field == "worlds"
					or field == "worldCash"
				then
					relevant = true
					break
				end
			end
		end
		if relevant then
			for _, stand in stands do
				paint(stand)
			end
		end
	end)
end

--[[
	Idle animation of the display eggs near the player (called from PetController's step).
	@param still Reduce Motion: eggs rest at their base pose
]]
function StandClient.step(_dt: number, clock: number, still: boolean)
	local character = LOCAL.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return
	end
	for _, stand in stands do
		local display, base = stand.display, stand.base
		if display ~= nil and base ~= nil and display.Parent ~= nil then
			if not still and (base.Position - root.Position).Magnitude <= BOB_RANGE then
				local t = clock + stand.phase
				display:PivotTo(
					base * CFrame.new(0, math.sin(t * 1.6) * 0.3, 0) * CFrame.Angles(0, math.sin(t * 0.5) * 0.6, 0)
				)
			end
		end
	end
end

return StandClient
