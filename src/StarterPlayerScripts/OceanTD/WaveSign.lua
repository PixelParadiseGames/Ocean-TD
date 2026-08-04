--!strict
--[[
	Updates Workspace … "Current Wave Sign" for the local player's plot.
	While waves run: "Wave N". Idle: all-time high from OceanTD_HighestWave.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))
local Remotes = require(oceanRoot:WaitForChild("Remotes"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local WaveSign = {}

local player = Players.LocalPlayer
local reportRemote = Remotes.get("ReportHighestWave")
local cachedHigh = 0
local lastReported = 0
local lastText = ""
local signCache: Instance? = nil
local signPlotId: string? = nil
local mounted = false

local function readHigh(): number
	local attr = player:GetAttribute(Constants.HIGHEST_WAVE_ATTR)
	if typeof(attr) == "number" and attr >= 0 then
		return math.floor(attr)
	end
	return math.max(0, cachedHigh)
end

local function reportHigh(wave: number)
	local w = math.max(0, math.floor(wave))
	if w <= 0 then
		return
	end
	if w > cachedHigh then
		cachedHigh = w
	end
	if w > lastReported then
		lastReported = w
		reportRemote:FireServer(w)
	end
	if w > readHigh() then
		player:SetAttribute(Constants.HIGHEST_WAVE_ATTR, w)
	end
end

local function findSignRoot(plotId: string): Instance?
	if signCache and signCache.Parent and signPlotId == plotId then
		return signCache
	end
	signCache = nil
	signPlotId = plotId
	local name = Constants.CURRENT_WAVE_SIGN_NAME
	if plotId == "Plot1" then
		local master = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
		local sign = master and master:FindFirstChild(name, true)
		if sign then
			signCache = sign
			return sign
		end
	end
	local n = tonumber(string.match(plotId, "%d+"))
	if n and n >= 2 then
		local root = Workspace:FindFirstChild(Constants.STATIC_PLOT_PREFIX .. tostring(n))
		local sign = root and root:FindFirstChild(name, true)
		if sign then
			signCache = sign
			return sign
		end
	end
	return nil
end

local function applyText(sign: Instance, text: string)
	if text == lastText and sign == signCache then
		return
	end
	lastText = text
	for _, d in ipairs(sign:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextBox") then
			d.Text = text
		end
	end
	if sign:IsA("TextLabel") or sign:IsA("TextBox") then
		(sign :: TextLabel).Text = text
	end
end

local function refresh()
	local mirrored = ClientPlot.get()
	if not mirrored then
		return
	end
	local sign = findSignRoot(mirrored.plotId)
	if not sign then
		return
	end
	local snap = WaveSim.getHudSnapshot()
	if snap.running and snap.wave > 0 then
		applyText(sign, "Wave " .. tostring(snap.wave))
		reportHigh(snap.wave)
	else
		applyText(sign, "Wave " .. tostring(readHigh()))
	end
end

function WaveSign.mount()
	if mounted then
		refresh()
		return
	end
	mounted = true
	cachedHigh = readHigh()
	lastReported = cachedHigh
	player:GetAttributeChangedSignal(Constants.HIGHEST_WAVE_ATTR):Connect(function()
		cachedHigh = math.max(cachedHigh, readHigh())
		if not WaveSim.isRunning() then
			refresh()
		end
	end)
	WaveSim.onHud(function(_snap)
		refresh()
	end)
	WaveSim.onStopped(function(summary)
		reportHigh(summary.waveReached)
		refresh()
	end)
	ClientPlot.onChanged(function()
		signCache = nil
		signPlotId = nil
		lastText = ""
		refresh()
	end)
	task.defer(refresh)
end

return WaveSign
