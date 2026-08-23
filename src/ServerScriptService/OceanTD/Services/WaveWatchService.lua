--!strict
--[[
	Relays host wave-watch packets to other clients.
	Standing-on-plot is enforced on the visitor client (more reliable than server HRP checks).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))

local PlotService = require(script.Parent:WaitForChild("PlotService"))

local WaveWatchService = {}

local pushRemote: RemoteEvent
local rosterRemote: RemoteEvent
local lastPushAt: { [Player]: number } = {}
local MIN_PUSH_GAP = 0.08

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
		elapsedSec = payload.elapsedSec,
		running = payload.running == true,
		hungerDanger = payload.hungerDanger == true,
		hungryMissToken = payload.hungryMissToken,
		coralEpoch = payload.coralEpoch,
		plotSizeStage = payload.plotSizeStage,
	}

	for _, visitor in ipairs(Players:GetPlayers()) do
		if visitor ~= player then
			pushRemote:FireClient(visitor, out)
		end
	end
end

function WaveWatchService.init()
	pushRemote = Remotes.get("WaveWatchPush")
	rosterRemote = Remotes.get("PlotRoster")
	pushRemote.OnServerEvent:Connect(onPush)

	local requestRoster = Remotes.getFunction("RequestPlotRoster")
	requestRoster.OnServerInvoke = function(_player: Player)
		return PlotService.getRosterPayload()
	end

	Players.PlayerRemoving:Connect(function(player)
		lastPushAt[player] = nil
	end)
	log("Ready")
end

return WaveWatchService
