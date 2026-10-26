--!strict
-- Server-only AnalyticsService funnels.
-- join_to_training: client reports steps in order, once per join.
-- play_time: this visit, step n at minute 1+(n-1)*2, up to 90 steps.
-- waves: this visit, wave 1 through wave 99, as soon as that wave is reached.

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local FunnelCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("FunnelCatalog"))

local FunnelService = {}

type Session = {
	joinId: string,
	playId: string,
	waveId: string,
	joinedAt: number,
	joinNext: number,
	playNext: number,
	waveNext: number,
	frozen: boolean,
}

local sessions: { [Player]: Session } = {}

local function customFields(field: string?): { [string]: string }?
	if typeof(field) ~= "string" or field == "" then
		return nil
	end
	return {
		[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = string.sub(field, 1, 40),
	}
end

local warnedFail: { [string]: boolean } = {}

local function logStep(player: Player, funnelName: string, sessionId: string, step: number, stepName: string, field: string?): boolean
	local function attempt(useField: boolean): (boolean, any)
		return pcall(function()
			local fields = if useField then customFields(field) else nil
			if fields then
				AnalyticsService:LogFunnelStepEvent(player, funnelName, sessionId, step, stepName, fields)
			else
				AnalyticsService:LogFunnelStepEvent(player, funnelName, sessionId, step, stepName)
			end
		end)
	end
	local useField = typeof(field) == "string" and field ~= ""
	local ok, err = attempt(useField)
	if not ok and useField then
		ok, err = attempt(false)
	end
	if not ok then
		local key = funnelName .. ":" .. tostring(step)
		if not warnedFail[key] then
			warnedFail[key] = true
			warn("[FUNNEL] not sent", funnelName, step, stepName, err)
		end
		return false
	end
	print("[FUNNEL] sent", funnelName, step, stepName)
	return true
end

local function beginSession(player: Player)
	sessions[player] = {
		joinId = HttpService:GenerateGUID(false),
		playId = HttpService:GenerateGUID(false),
		waveId = HttpService:GenerateGUID(false),
		joinedAt = os.clock(),
		joinNext = 1,
		playNext = 1,
		waveNext = 1,
		frozen = false,
	}
end

local function fieldFor(stepId: string, raw: any): string?
	if typeof(raw) ~= "string" then
		raw = nil
	end
	if stepId == "load_bar_shown" then
		if raw == "gamepad" or raw == "touch" or raw == "keyboard" then
			return raw
		end
		return "keyboard"
	end
	if stepId == "showcase_exit" then
		if raw == "skip" or raw == "watched" then
			return raw
		end
		return "watched"
	end
	return nil
end

local function logWave(player: Player, sess: Session, raw: any)
	local n = tonumber(raw)
	if n == nil then
		return
	end
	local target = math.clamp(math.floor(n), 1, FunnelCatalog.WAVE_MAX)
	if target < sess.waveNext then
		return
	end
	local guard = 0
	while sess.waveNext <= target do
		local step = sess.waveNext
		local sent = logStep(player, FunnelCatalog.WAVE_NAME, sess.waveId, step, FunnelCatalog.waveStepName(step), nil)
		if not sent then
			break
		end
		sess.waveNext = step + 1
		guard += 1
		if guard > FunnelCatalog.WAVE_MAX then
			break
		end
	end
	player:SetAttribute("OceanTD_WaveFunnelAck", sess.waveNext - 1)
end

local function onClientStep(player: Player, stepId: any, field: any)
	if typeof(stepId) ~= "string" then
		return
	end
	local sess = sessions[player]
	if not sess then
		beginSession(player)
		sess = sessions[player]
	end
	if not sess then
		return
	end
	if stepId == "freeze" then
		sess.frozen = true
		player:SetAttribute("OceanTD_JoinFunnelFrozen", true)
		return
	end
	if stepId == "wave" then
		logWave(player, sess, field)
		return
	end
	if sess.frozen then
		return
	end
	local index = FunnelCatalog.joinIndex(stepId)
	if index == nil or index ~= sess.joinNext then
		return
	end
	local sent = logStep(player, FunnelCatalog.JOIN_NAME, sess.joinId, index, stepId, fieldFor(stepId, field))
	if not sent then
		return
	end
	sess.joinNext = index + 1
	player:SetAttribute("OceanTD_JoinFunnelAck", index)
end

local function tickPlayTime()
	local now = os.clock()
	for player, sess in pairs(sessions) do
		if player.Parent == nil then
			continue
		end
		local elapsedMin = (now - sess.joinedAt) / 60
		local guard = 0
		while sess.playNext <= FunnelCatalog.PLAY_STEP_COUNT and elapsedMin >= FunnelCatalog.playMinutes(sess.playNext) do
			local step = sess.playNext
			local sent = logStep(player, FunnelCatalog.PLAY_NAME, sess.playId, step, FunnelCatalog.playStepName(step), nil)
			if not sent then
				break
			end
			sess.playNext = step + 1
			guard += 1
			if guard > FunnelCatalog.PLAY_STEP_COUNT then
				break
			end
		end
	end
end

function FunnelService.init()
	if RunService:IsStudio() then
		warn("[FUNNEL] Studio play is not recorded on the Roblox website. Publish, then join the live game. Charts can take up to 24 hours. Analytics → Funnel → View Events updates sooner.")
	end
	local remote = Remotes.get("FunnelStep")
	remote.OnServerEvent:Connect(onClientStep)

	for _, player in ipairs(Players:GetPlayers()) do
		beginSession(player)
	end
	Players.PlayerAdded:Connect(beginSession)
	Players.PlayerRemoving:Connect(function(player)
		sessions[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(5)
			tickPlayTime()
		end
	end)
end

return FunnelService
