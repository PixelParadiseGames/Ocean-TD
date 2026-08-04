--!strict
-- Phase 1 client: mirror own plot bounds for future placement previews.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

-- Scroll-wheel zoom-out: 25% further than the place / engine max.
do
	local base = player.CameraMaxZoomDistance
	if base <= 0 or base ~= base then
		base = 128
	end
	player.CameraMaxZoomDistance = base * 1.25
end

local plotAssigned = Remotes.get("PlotAssigned")
local plotCleared = Remotes.get("PlotCleared")
local sessionReady = Remotes.get("SessionReady")

local function log(...: any)
	print("[PLOT]", ...)
end

plotAssigned.OnClientEvent:Connect(function(payload)
	ClientPlot.set(payload)
	log("Assigned", payload.plotId, "size=", payload.size)
end)

plotCleared.OnClientEvent:Connect(function()
	ClientPlot.clear()
	log("Cleared local plot mirror")
end)

sessionReady.OnClientEvent:Connect(function()
	ClientPlot.markReady()
	log("SessionReady")
end)

log("Client bootstrap running for", player.Name)
