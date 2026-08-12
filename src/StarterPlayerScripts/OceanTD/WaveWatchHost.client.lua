--!strict
--[[
	Host broadcaster: sparse wave-watch packets + coral epoch while WaveSim runs.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))

local player = Players.LocalPlayer
local pushRemote = Remotes.get("WaveWatchPush")

local HEARTBEAT_SEC = 2
local lastHbAt = 0
local lastWave = -1
local lastRunning = false
local lastSpeed = -1
local lastReef = -1
local lastMiss = -1
local lastFeedComplete = false
local coralEpoch = 0
local coralConns: { RBXScriptConnection } = {}
local coralBumpAt = 0

local function ownedPlotId(): string?
	local plot = ClientPlot.get()
	return if plot then plot.plotId else nil
end

local function buildPayload(kind: string): any?
	local plotId = ownedPlotId()
	if not plotId then
		return nil
	end
	local snap = WaveSim.getHudSnapshot()
	return {
		kind = kind,
		plotId = plotId,
		hostUserId = player.UserId,
		wave = snap.wave,
		speedMult = WaveSim.getSpeedMult(),
		reefHealth = snap.reefHealth,
		reefMax = snap.reefMax,
		feedProgress = snap.feedProgress,
		feedComplete = snap.feedComplete,
		fishFull = snap.fishFull,
		fishTotal = snap.fishTotal,
		elapsedSec = snap.elapsedSec,
		running = snap.running,
		hungerDanger = snap.hungerDanger,
		hungryMissToken = snap.hungryMissToken,
		coralEpoch = coralEpoch,
		plotSizeStage = SkillPowerUpUI.getStage("PlotSize"),
	}
end

local function fire(kind: string)
	local payload = buildPayload(kind)
	if not payload then
		return
	end
	pushRemote:FireServer(payload)
	lastHbAt = os.clock()
end

local function disconnectCoralWatch()
	for _, c in ipairs(coralConns) do
		c:Disconnect()
	end
	table.clear(coralConns)
end

local function watchCoralFolder()
	disconnectCoralWatch()
	local plotId = ownedPlotId()
	if not plotId then
		return
	end
	local root = Workspace:FindFirstChild("OceanTD_Placed")
	local plotFolder = root and root:FindFirstChild(plotId)
	if not plotFolder then
		if root then
			table.insert(coralConns, root.ChildAdded:Connect(function(ch)
				if ch.Name == plotId then
					watchCoralFolder()
				end
			end))
		end
		return
	end
	local function bump()
		if not WaveSim.isRunning() then
			return
		end
		local now = os.clock()
		if now - coralBumpAt < 0.35 then
			return
		end
		coralBumpAt = now
		coralEpoch += 1
		fire("coral")
	end
	table.insert(coralConns, plotFolder.ChildAdded:Connect(bump))
	table.insert(coralConns, plotFolder.ChildRemoved:Connect(bump))
end

WaveSim.onHud(function(snap)
	if not ownedPlotId() then
		return
	end

	local speed = WaveSim.getSpeedMult()

	if snap.running and not lastRunning then
		watchCoralFolder()
		fire("start")
	elseif not snap.running and lastRunning then
		disconnectCoralWatch()
		fire("stop")
	elseif snap.running then
		if snap.wave ~= lastWave and lastWave >= 0 then
			fire("next")
		elseif math.abs(speed - lastSpeed) > 1e-4 and lastSpeed > 0 then
			fire("speed")
		elseif snap.reefHealth < lastReef and lastReef >= 0 then
			fire("reef")
		elseif snap.hungryMissToken > lastMiss and lastMiss >= 0 then
			fire("reef")
		elseif snap.feedComplete ~= lastFeedComplete then
			fire("heartbeat")
		end
	end

	lastRunning = snap.running
	lastWave = snap.wave
	lastSpeed = speed
	lastReef = snap.reefHealth
	lastMiss = snap.hungryMissToken
	lastFeedComplete = snap.feedComplete
end)

WaveSim.onStopped(function()
	disconnectCoralWatch()
	fire("stop")
	lastRunning = false
end)

ClientPlot.onChanged(function()
	if WaveSim.isRunning() then
		watchCoralFolder()
	end
end)

local hbAcc = 0
RunService.Heartbeat:Connect(function(dt)
	if not WaveSim.isRunning() then
		hbAcc = 0
		return
	end
	hbAcc += dt
	if hbAcc < HEARTBEAT_SEC then
		return
	end
	hbAcc = 0
	if os.clock() - lastHbAt >= HEARTBEAT_SEC * 0.9 then
		fire("heartbeat")
	end
end)

print("[WAVEWATCH] Host broadcaster ready")
