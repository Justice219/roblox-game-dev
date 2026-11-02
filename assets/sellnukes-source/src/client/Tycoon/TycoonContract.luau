--!strict
--[[
	TycoonContract — every world name the tycoon CLIENT reads from the server-built plots
	(instance tree of World/PlotBuilder + attributes of Tycoon/TycoonService, B5).

	Instance tree (B5's final contract, World/PlotBuilder + Tycoon/TycoonService):
		Workspace.Plots (Folder)
		  PlotN (Model)              PlotIndex, OwnerUserId (0 = free), OwnerName, StandName
		    YouAnchor (Part)         invisible, above the entrance arch: the YOU marker floats here
		    AreaNN (Model)           AreaIndex
		      Builds (Folder)        <BuildKey> (Model): BuildKey, PadId, [BuildIn, BuyerUserId]
		      Pads (Folder)          <padId> (Model, tag SNPad): PadId, OwnerUserId, Cost, Kind,
		                             Name, Blurb, Color, Area, Order, Value?, Feature?, PressedAt
		                             (set on purchase; destroyed 0.6 s later); children Trigger
		                             (invisible touch volume) + Visual (BuyPad mesh)
		      Producer (Model)
		        Anchor (Part, tag SNProducer) ProducerId, OwnerUserId, Area, Name + the producer
		                             attributes below
		        ClickBox (Part)      invisible sibling of the Anchor with a server ClickDetector
		                             (3D click / tap = one cycle, validated server-side); the
		                             CLICK bar / F / R2 send ProducerClick through the same checks
		Player attributes: PlotIndex (0 = none), PlotAssignedAt, PlotRevealSeconds, PlotRevealed,
		IncomePerSecond (server, ALL modifiers), TycoonArea, FeatureStandRename / FeatureAATower /
		FeatureAttackConsole / FeatureRebirth, CurrentWorld (owner R57: the world the player is in).

	Worlds (owner R57, plan §3.5): every other world builds the SAME tree under
		Workspace.Worlds (Folder)
		  <worldId> (Folder)         e.g. "dino"
		    Plots (Folder)           PlotN (Model) exactly as above + attribute WorldId
		Pad / producer / build-key ids are globally unique and prefixed (d3_..., dp3_..., D3_...),
		so a bare id always tells its world (Tycoon/WorldLookup). Tycoon/PlotFolders discovers
		every Plots folder (both trees) for TycoonWorld, ManagerController and VehicleRoutes.

	Purpose:
		The client reads these names ONLY from here: a server rename is a one-line change.

	Trust: everything read through these names is display input. Values are type-checked where
	they are read (`num`, `str`, `bool`); purchases, clicks and upgrades are server-validated
	intents, never amounts.

	Connects to: Tycoon/{TycoonWorld, ProducerBillboards, PadBillboards, Interaction,
	IncomePops, YouMarker, Tutorial, StandSign}.

	Example:
		local id = TycoonContract.str(model:GetAttribute(TycoonContract.Attr.ProducerId), "")
]]

local TycoonContract = {}

-- Instance names in the plot tree.
TycoonContract.Names = table.freeze({
	PlotsFolder = "Plots",
	PadsFolder = "Pads",
	BuildsFolder = "Builds",
	Producer = "Producer",
	Anchor = "Anchor",
	YouAnchor = "YouAnchor",
	ClickBox = "ClickBox",
	Trigger = "Trigger",
	-- owner R57: Workspace.Worlds.<worldId>.Plots holds every other world's plots
	WorldsFolder = "Worlds",
})

-- Attribute names.
TycoonContract.Attr = table.freeze({
	-- plots
	OwnerUserId = "OwnerUserId",
	OwnerName = "OwnerName",
	StandName = "StandName",
	PlotIndex = "PlotIndex",
	AreaIndex = "AreaIndex",
	-- producer model + anchor
	ProducerId = "ProducerId",
	Level = "Level",
	PerCycle = "PerCycle", -- cash of the next payout
	CycleTime = "CycleTime", -- seconds per cycle
	CycleStart = "CycleStart", -- server time the running cycle began (0 = idle)
	Automated = "Automated",
	Badge = "Badge", -- milestone multiplier text ("x8"; "" below the first milestone)
	BadgeNextAt = "BadgeNextAt", -- level of the next milestone (0 = none)
	PerSecond = "PerSecond", -- automated $/s (0 while manual)
	NextCost = "NextCost", -- x1 upgrade cost
	ClickCooldown = "ClickCooldown", -- seconds between accepted clicks
	-- pads
	PadId = "PadId",
	Cost = "Cost",
	Kind = "Kind",
	Name = "Name",
	Blurb = "Blurb",
	Color = "Color",
	Feature = "Feature",
	PressedAt = "PressedAt", -- server time the pad was bought (model destroyed 0.6 s later)
	-- player
	PlayerPlotIndex = "PlotIndex",
	PlotRevealSeconds = "PlotRevealSeconds",
	IncomePerSecond = "IncomePerSecond",
	-- builds
	BuildKey = "BuildKey",
	BuildIn = "BuildIn",
	BuyerUserId = "BuyerUserId",
	-- worlds (owner R57)
	WorldId = "WorldId", -- on every plot Model (PlotBuilder): "main" / "dino" / ...
	CurrentWorld = "CurrentWorld", -- Player attribute (server, WorldService): the world they are in
})

--[[ A finite number from an untyped attribute value, else `default`. ]]
function TycoonContract.num(value: unknown, default: number): number
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return default
end

--[[ A string attribute value (capped at 200 bytes), else `default`. ]]
function TycoonContract.str(value: unknown, default: string): string
	if type(value) == "string" and #value <= 200 then
		return value
	end
	return default
end

--[[ A boolean attribute value, else false. ]]
function TycoonContract.bool(value: unknown): boolean
	return value == true
end

return table.freeze(TycoonContract)
