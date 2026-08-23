--!strict
--[[
	Visitor: detect standing on a foreign plot; mirror host wave HUD + ghost sim.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))
local GridMath = require(oceanRoot:WaitForChild("Shared"):WaitForChild("GridMath"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local WaveGhostSim = require(script.Parent:WaitForChild("WaveGhostSim"))
local WaveWatchMode = require(script.Parent:WaitForChild("WaveWatchMode"))
local WaveWatchHud = require(script.Parent:WaitForChild("WaveWatchHud"))

WaveWatchHud.mount()

export type RosterEntry = {
	plotId: string,
	cframe: CFrame,
	size: Vector3,
	ownerUserId: number,
	ringCFrame: CFrame?,
}

local player = Players.LocalPlayer
local roster: { RosterEntry } = {}
local lastPushByPlot: { [string]: WaveWatchMode.WatchSnap } = {}
local lastPushAtByPlot: { [string]: number } = {}
local pendingKindByPlot: { [string]: string } = {}
local standingPlotId: string? = nil
local STALE_SEC = 8
-- Inflate footprint slightly so plot edges / spawn pads still count.
local BOUNDS_PAD = 1.15

local rosterRemote = Remotes.get("PlotRoster")
local pushRemote = Remotes.get("WaveWatchPush")
local requestRoster = Remotes.getFunction("RequestPlotRoster")

local function num(v: any, fallback: number): number
	local n = tonumber(v)
	return if n then n else fallback
end

local function applyRoster(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local nextRoster: { RosterEntry } = {}
	for _, entry in ipairs(payload) do
		if typeof(entry) == "table"
			and typeof(entry.plotId) == "string"
			and typeof(entry.cframe) == "CFrame"
			and typeof(entry.size) == "Vector3"
		then
			table.insert(nextRoster, {
				plotId = entry.plotId,
				cframe = entry.cframe,
				size = entry.size,
				ownerUserId = num(entry.ownerUserId, 0),
				ringCFrame = if typeof(entry.ringCFrame) == "CFrame" then entry.ringCFrame else entry.cframe,
			})
		end
	end
	if #nextRoster > 0 then
		roster = nextRoster
	end
end

local function refreshRoster()
	local ok, payload = pcall(function()
		return requestRoster:InvokeServer()
	end)
	if ok then
		applyRoster(payload)
	end
end

rosterRemote.OnClientEvent:Connect(applyRoster)

pushRemote.OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" or typeof(payload.plotId) ~= "string" then
		return
	end
	local plotId = payload.plotId
	local kind = if typeof(payload.kind) == "string" then payload.kind else "heartbeat"
	pendingKindByPlot[plotId] = kind
	lastPushByPlot[plotId] = {
		wave = num(payload.wave, 1),
		reefHealth = num(payload.reefHealth, 0),
		reefMax = num(payload.reefMax, 10),
		elapsedSec = num(payload.elapsedSec, 0),
		running = payload.running == true,
		feedProgress = num(payload.feedProgress, 0),
		feedComplete = payload.feedComplete == true,
		hungerDanger = payload.hungerDanger == true,
		hungryMissToken = num(payload.hungryMissToken, 0),
		fishFull = num(payload.fishFull, 0),
		fishTotal = num(payload.fishTotal, 0),
		crabTotal = num(payload.crabTotal, 0),
		speedMult = num(payload.speedMult, 1),
		plotId = plotId,
		hostUserId = num(payload.hostUserId, 0),
		coralEpoch = num(payload.coralEpoch, 0),
		kind = kind,
		plotSizeStage = num(payload.plotSizeStage, 1),
	}
	lastPushAtByPlot[plotId] = os.clock()
	if kind == "coral" then
		WaveGhostSim.markCoralDirty()
	end
end)

local function ownedPlotId(): string?
	local plot = ClientPlot.get()
	return if plot then plot.plotId else nil
end

local function isInsidePadded(worldPos: Vector3, cf: CFrame, size: Vector3): boolean
	local padded = Vector3.new(size.X * BOUNDS_PAD, size.Y, size.Z * BOUNDS_PAD)
	return GridMath.isInsidePlotXZ(worldPos, cf, padded)
end

local function findStandingPlot(): RosterEntry?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return nil
	end
	local own = ownedPlotId()
	-- Prefer roster; if empty, try again once.
	if #roster == 0 then
		refreshRoster()
	end
	for _, entry in ipairs(roster) do
		if entry.plotId ~= own and entry.ownerUserId > 0 then
			if isInsidePadded(hrp.Position, entry.cframe, entry.size) then
				return entry
			end
		end
	end
	-- Fallback: own ClientPlot bounds are known; for foreign plots use player attributes
	-- only when roster has the plot but ownerUserId was 0 (stale) — refresh ownership from attrs.
	for _, entry in ipairs(roster) do
		if entry.plotId ~= own and isInsidePadded(hrp.Position, entry.cframe, entry.size) then
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr ~= player and plr:GetAttribute(Constants.PLOT_ID_ATTR) == entry.plotId then
					entry.ownerUserId = plr.UserId
					return entry
				end
			end
		end
	end
	return nil
end

local function leaveWatch()
	if WaveWatchMode.isWatching() then
		WaveWatchMode.set(false, nil)
	end
	if WaveGhostSim.isActive() then
		WaveGhostSim.stop(true)
	end
	standingPlotId = nil
end

local acc = 0
local rosterAcc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	rosterAcc += dt
	if rosterAcc >= 5 then
		rosterAcc = 0
		refreshRoster()
	end
	if acc < 0.15 then
		return
	end
	acc = 0

	local entry = findStandingPlot()
	if not entry then
		if standingPlotId then
			leaveWatch()
		end
		return
	end

	standingPlotId = entry.plotId
	local snap = lastPushByPlot[entry.plotId]
	local pushAt = lastPushAtByPlot[entry.plotId] or 0
	local fresh = snap ~= nil and (os.clock() - pushAt) <= STALE_SEC
	local pendingKind = pendingKindByPlot[entry.plotId]
	if pendingKind then
		pendingKindByPlot[entry.plotId] = nil
	end
	if fresh and snap and snap.running then
		WaveWatchMode.set(true, snap)
		WaveGhostSim.apply(snap, entry.cframe, pendingKind, entry.size, entry.ringCFrame)
	elseif snap and not snap.running then
		WaveWatchMode.set(false, nil)
		WaveGhostSim.stop(true)
	elseif WaveWatchMode.isWatching() and not fresh then
		leaveWatch()
	end
end)

task.defer(refreshRoster)
task.delay(1, refreshRoster)
task.delay(3, refreshRoster)

print("[WAVEWATCH] Visitor listener ready")
