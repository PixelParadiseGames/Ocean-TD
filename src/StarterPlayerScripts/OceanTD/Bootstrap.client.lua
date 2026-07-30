--!strict
-- Phase 1 client: mirror own plot bounds for future placement previews.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

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
