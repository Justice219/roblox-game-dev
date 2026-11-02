--!strict
--[[
	ReturnNotifySender — sends ONE return notification with Open Cloud CreateUserNotification
	through HttpService (owner R122 §2.3; the officially supported in-experience route: Creator
	Docs "In-game HTTP requests" → Open Cloud from HttpService lists Notifications /
	CreateUserNotification; the `x-api-key` header MUST be a Secret from HttpService:GetSecret,
	only `x-api-key` + `content-type` headers are allowed, Open Cloud calls have their own
	2500 / min / server limit).

	Request (fixed; never built from client data):
		POST NotifyConfig.Url (user id validated as an integer)
		Headers { ["Content-Type"] = "application/json", ["x-api-key"] = <Secret> }
		Body    ReturnNotifyLogic.buildBody(kind, params) (camelCase Open Cloud v2 JSON)

	Modes (mode()):
		"dry"    Studio (always): the body is built + validated + JSON-encoded, no request
		"nokey"  live, but HttpService:GetSecret(NotifyConfig.SecretName) failed: no request; the
		         secret is looked up again after Send.SecretRetrySeconds
		"live"   the secret was found: real requests
	Results: ok / throttled / rejected / http (ReturnNotifyLogic.classify), dry, nokey, and off (the
	kind has no message id / bad parameters — nothing to send).

	Security: the Secret object is fetched on the server only, kept in this module's upvalue,
	never printed, never put in a body / error text / analytics key / client payload (Roblox
	prints a Secret as "Secret(<name>)" anyway). Errors are reduced to short status / code text.

	Performance: one RequestAsync per send; the caller (ReturnNotifyRunner) owns the token bucket,
	concurrency cap, timeout race and back-off.

	Connects to: Server/Retention/ReturnNotifyLogic (url / buildBody / classify), Shared/Config/
	NotifyConfig. Used by ReturnNotifyRunner (queue sends + admin test). Tests inject fake
	getSecret / request / clock (tests/return-notify.luau).

	Example:
		local sender = ReturnNotifySender.new({
			isStudio = RunService:IsStudio(),
			getSecret = function(name) return HttpService:GetSecret(name) end,
			request = function(options) return HttpService:RequestAsync(options) end,
			encode = function(v) return HttpService:JSONEncode(v) end,
			decode = function(s) return HttpService:JSONDecode(s) end,
			clock = os.clock,
		})
		local result = sender.send(1586034782, "streak", { day = "3" })
		print(result.result) --> "dry" in Studio
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NotifyConfig = require(ReplicatedStorage.Shared.Config.NotifyConfig)
local ReturnNotifyLogic = require(script.Parent.ReturnNotifyLogic)

type Kinds = ReturnNotifyLogic.Kinds

export type Mode = "live" | "dry" | "nokey"
export type ResultKey = "ok" | "throttled" | "rejected" | "http" | "nokey" | "dry" | "off"

export type SendResult = {
	result: ResultKey,
	verdict: ReturnNotifyLogic.Verdict?, -- set when a request was made
	detail: string?, -- short reason for the admin status ("no message id", "HTTP 429 ...")
}

export type Deps = {
	isStudio: boolean,
	getSecret: (name: string) -> any, -- HttpService:GetSecret (throws when missing)
	request: (options: { [string]: any }) -> any, -- HttpService:RequestAsync
	encode: (value: any) -> string, -- HttpService:JSONEncode
	decode: (text: string) -> any, -- HttpService:JSONDecode
	clock: () -> number, -- os.clock (secret retry)
	kinds: Kinds?,
}

export type Sender = {
	mode: () -> Mode,
	send: (userId: number, kind: ReturnNotifyLogic.Kind, params: { [string]: string }?) -> SendResult,
}

local Send = NotifyConfig.Send

local ReturnNotifySender = {}

--[[
	Builds a sender around injected HttpService functions.
	@param deps Deps
	@return Sender
]]
function ReturnNotifySender.new(deps: Deps): Sender
	local secret: any = nil
	local lastLookup = -math.huge

	-- JSONDecode that never throws (classify reads the error code from the body).
	local function safeDecode(text: string): any
		local ok, value = pcall(deps.decode, text)
		return if ok then value else nil
	end

	-- The API key Secret, looked up at most every SecretRetrySeconds while missing.
	local function apiKey(): any
		if secret ~= nil then
			return secret
		end
		local now = deps.clock()
		if now - lastLookup < Send.SecretRetrySeconds then
			return nil
		end
		lastLookup = now
		local ok, value = pcall(deps.getSecret, NotifyConfig.SecretName)
		if ok and value ~= nil then
			secret = value
		end
		return secret
	end

	local sender = {} :: Sender

	--[[ The current mode (see the module header). Live servers try the secret lookup here. ]]
	function sender.mode(): Mode
		if deps.isStudio then
			return "dry"
		end
		return if apiKey() ~= nil then "live" else "nokey"
	end

	--[[
		Sends one notification (yields on the request in live mode).
		@param userId number — the recipient (validated)
		@param kind Kind
		@param params { [string]: string }? — the kind's declared parameters
		@return SendResult
	]]
	function sender.send(userId: number, kind: ReturnNotifyLogic.Kind, params: { [string]: string }?): SendResult
		local url = ReturnNotifyLogic.url(userId)
		if url == nil then
			return { result = "off", detail = "bad user id" }
		end
		local body, err = ReturnNotifyLogic.buildBody(kind, params, deps.kinds)
		if body == nil then
			return { result = "off", detail = err }
		end
		local okEncode, encoded = pcall(deps.encode, body)
		if not okEncode or type(encoded) ~= "string" then
			return { result = "off", detail = "body did not encode" }
		end
		local mode = sender.mode()
		if mode == "dry" then
			return { result = "dry", detail = `dry run ({#encoded} bytes)` }
		end
		local key = apiKey()
		if key == nil then
			return { result = "nokey", detail = `secret {NotifyConfig.SecretName} missing` }
		end
		local called, response = pcall(deps.request, {
			Url = url,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["x-api-key"] = key,
			},
			Body = encoded,
		})
		local verdict = ReturnNotifyLogic.classify(called, response, safeDecode)
		local detail = if verdict.status > 0 then `HTTP {verdict.status}` else "no response"
		if verdict.code ~= nil then
			detail ..= ` {verdict.code}`
		end
		return { result = verdict.result, verdict = verdict, detail = detail }
	end

	return sender
end

return ReturnNotifySender
