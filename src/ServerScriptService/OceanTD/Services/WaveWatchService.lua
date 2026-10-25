--!strict
--[[
	Relays host wave-watch packets to other clients.
	Visitor feeds are accepted only inside the stage-8 footprint while the host applies the shot.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))

local PlotService = require(script.Parent:WaitForChild("PlotService"))
local PersistenceService = require(script.Parent:WaitForChild("PersistenceService"))

local WaveWatchService = {}

local pushRemote: RemoteEvent
local feedRemote: RemoteEvent
local rosterRemote: RemoteEvent
local lastPushAt: { [Player]: number } = {}
local lastFeedAt: { [Player]: number } = {}
local MIN_PUSH_GAP = 0.08
local MAX_BLOB = 12000

local function log(...: any)
	print("[WAVEWATCH]", ...)
end

function WaveWatchService.broadcastRoster(toPlayer: Player?)
	local payload = PlotService.getRosterPayload()
	if toPlayer then
		rosterRemote:FireClient(toPlayer, payload)
		return
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		rosterRemote:FireClient(plr, payload)
	end
end

local function onPush(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local now = os.clock()
	local last = lastPushAt[player]
	if last and now - last < MIN_PUSH_GAP then
		return
	end
	lastPushAt[player] = now

	local owned = PlotService.getOwnerPlotId(player)
	if not owned then
		return
	end
	local plotId = payload.plotId
	if typeof(plotId) ~= "string" or plotId ~= owned then
		return
	end

	local blob = payload.visitBlob
	if typeof(blob) ~= "string" or #blob > MAX_BLOB or #blob % 3 ~= 0 then
		blob = ""
	end
	local seed = tonumber(payload.seed) or 0
	local planT0 = tonumber(payload.planT0) or 0
	local simClock = tonumber(payload.simClock) or 0

	-- Copy so we don't mutate client table oddly across peers
	local out = {
		kind = payload.kind,
		plotId = owned,
		hostUserId = player.UserId,
		wave = payload.wave,
		speedMult = payload.speedMult,
		reefHealth = payload.reefHealth,
		reefMax = payload.reefMax,
		feedProgress = payload.feedProgress,
		feedComplete = payload.feedComplete,
		fishFull = payload.fishFull,
		fishTotal = payload.fishTotal,
		crabTotal = payload.crabTotal,
		urchinTotal = payload.urchinTotal,
		sharkTotal = payload.sharkTotal,
		elapsedSec = payload.elapsedSec,
		running = payload.running == true,
		hungerDanger = payload.hungerDanger == true,
		hungryMissToken = payload.hungryMissToken,
		coralEpoch = payload.coralEpoch,
		plotSizeStage = payload.plotSizeStage,
		seed = seed,
		planT0 = planT0,
		simClock = simClock,
		visitBlob = blob,
	}

	for _, visitor in ipairs(Players:GetPlayers()) do
		if visitor ~= player then
			pushRemote:FireClient(visitor, out)
		end
	end
end

local function onFeed(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local plotId = payload.plotId
	local fishId = tonumber(payload.fishId)
	if typeof(plotId) ~= "string" or not fishId then
		return
	end
	fishId = math.floor(fishId)
	if fishId < 1 or fishId > 4000 then
		return
	end
	local owner = PlotService.getPlotOwner(plotId)
	if not owner or owner == player then
		return
	end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return
	end
	if not PlotService.isInsideStageBox(plotId, hrp.Position, 8) then
		return
	end
	local now = os.clock()
	local stage = PersistenceService.getSkillStage(player, "ReloadSpeed")
	local cd = SkillStages.reloadSpeedCooldownSec(stage)
	local minGap = if cd <= 1e-4 then 0.04 else math.max(0.05, cd - 0.02)
	local last = lastFeedAt[player]
	if last and now - last < minGap then
		return
	end
	lastFeedAt[player] = now
	local out = {
		plotId = plotId,
		fishId = fishId,
		fromUserId = player.UserId,
	}
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			feedRemote:FireClient(other, out)
		end
	end
end

function WaveWatchService.init()
	pushRemote = Remotes.get("WaveWatchPush")
	feedRemote = Remotes.get("WaveVisitFeed")
	rosterRemote = Remotes.get("PlotRoster")
	pushRemote.OnServerEvent:Connect(onPush)
	feedRemote.OnServerEvent:Connect(onFeed)

	local requestRoster = Remotes.getFunction("RequestPlotRoster")
	requestRoster.OnServerInvoke = function(_player: Player)
		return PlotService.getRosterPayload()
	end

	Players.PlayerRemoving:Connect(function(player)
		lastPushAt[player] = nil
		lastFeedAt[player] = nil
	end)
	log("Ready")
end

return WaveWatchService
