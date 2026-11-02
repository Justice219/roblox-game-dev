--!strict
--[[
	ChangeNotesAdmin — the owner-admin controls of WHAT'S NEW (owner R58; hard rule 9 "every system
	is controllable from the admin panel"), registered at runtime with B14's
	AdminService.registerCommand(def, handler) through a GUARDED lazy require (the KnockdownAdmin
	pattern): when Services/AdminService is missing or fails to load nothing is registered and
	nothing errors. The admin panel lists registered commands on their tab automatically
	(Players → "More"), so no client code is needed.

	Commands (Players tab, target = an online player; AdminService validates every argument
	against the def BEFORE the handler runs; handler(ctx) -> (ok, message)):
		WhatsNewReset    { seenUpTo: "none" | <note id> }  sets their seen note BACK ("none" = every
		                                                    note unseen), saves + pushes, and their
		                                                    client replays the returning-player
		                                                    auto pop-up at the next calm moment
		WhatsNewPreview  {}                                  opens the panel on their screen in
		                                                    PREVIEW mode: every note incl. ones still
		                                                    hidden by ShowFrom; nothing is marked
		                                                    seen or counted
	Pick yourself in the Players tab for "reset my seen version" / "preview".

	Connects to: Server/Services/AdminService (B14), Server/Services/ChangeNotesService (passed in:
	adminReset, adminPreview), Shared/Config/ChangeNotesConfig (note ids + labels).

	Usage: ChangeNotesService.Start → ChangeNotesAdmin.install(ChangeNotesService)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ChangeNotesConfig = require(ReplicatedStorage.Shared.Config.ChangeNotesConfig)
local TextUtil = require(ReplicatedStorage.Shared.Util.TextUtil)
local VersionConfig = require(ReplicatedStorage.Shared.Config.VersionConfig)

local ChangeNotesAdmin = {}

type Ctx = { args: { [string]: any }, target: { player: Player?, label: string }? }
type Handler = (ctx: Ctx) -> (boolean, string)

-- The "nothing seen" choice of WhatsNewReset (note ids never equal it: they start with a date).
local NONE = "none"
-- Panel order: after the knockdown commands (340+).
local ORDER = 380
-- Longest enum label the panel accepts (AdminValidate: 64 characters).
local MAX_LABEL = 64

local installed = false

-- The command's target player (nil when not aimed at an online player).
local function targetOf(ctx: Ctx): Player?
	local target = ctx.target
	return if target ~= nil then target.player else nil
end

--[[
	The WhatsNewReset choices: "none" then every note, oldest first, labelled
	"Seen up to v0.2.0 BUILD YOUR NUKE EMPIRE!" (cut to the panel's label cap).
	@return values, labels
]]
local function resetChoices(): ({ string }, { string })
	local values: { string } = { NONE }
	local labels: { string } = { "Nothing seen (all notes new)" }
	for _, note in ChangeNotesConfig.Notes do
		table.insert(values, note.Id)
		local label = `Seen up to {VersionConfig.label(note.Version)} {note.Title}`
		table.insert(labels, TextUtil.cutChars(label, MAX_LABEL)) -- UTF-8 safe cut
	end
	return values, labels
end

--[[
	Registers both WHAT'S NEW admin commands (idempotent).
	@param Service any — Server/Services/ChangeNotesService (adminReset, adminPreview)
	@return boolean — true when AdminService accepted the commands
]]
function ChangeNotesAdmin.install(Service: any): boolean
	if installed then
		return true
	end
	local module = ServerScriptService.Server.Services:FindFirstChild("AdminService")
	if module == nil or not module:IsA("ModuleScript") then
		return false
	end
	local ok, AdminService = pcall(require, module)
	if not ok or type(AdminService) ~= "table" or type((AdminService :: any).registerCommand) ~= "function" then
		warn("[ChangeNotesAdmin] AdminService could not be loaded; What's New admin commands not registered")
		return false
	end
	installed = true
	local register = (AdminService :: any).registerCommand

	local function add(def: any, handler: Handler)
		local registered, err = pcall(register, def, handler)
		if not registered then
			warn(`[ChangeNotesAdmin] {def.name} not registered: {err}`)
		end
	end

	local values, labels = resetChoices()
	add({
		name = "WhatsNewReset",
		tab = "Players",
		label = "Reset What's New",
		description = "Sets their seen update back; the What's New pop-up replays for them.",
		target = "Player",
		args = {
			seenUpTo = { kind = "enum", values = values, labels = labels, label = "Seen up to" },
		},
		argOrder = { "seenUpTo" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "purple",
		order = ORDER + 1,
	}, function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		local choice = ctx.args.seenUpTo
		local id = if choice == NONE then "" else choice
		if type(id) ~= "string" then
			return false, "Pick a note"
		end
		return Service.adminReset(player, id)
	end)
	add({
		name = "WhatsNewPreview",
		tab = "Players",
		label = "Preview What's New",
		description = "Opens What's New on their screen (all notes, even unreleased; nothing is marked).",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "purple",
		order = ORDER + 2,
	}, function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		return Service.adminPreview(player)
	end)
	return true
end

return ChangeNotesAdmin
