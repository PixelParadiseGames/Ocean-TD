--!strict
--[[
	Studio: PlayerGui.MobileLeftUI.StopAutoRoll — hidden; auto-roll is always on (server default).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))

local SeedWheelAutoRollState = require(script.Parent:WaitForChild("SeedWheelAutoRollState"))

local STUDIO_ANCHOR_NAME = "StopAutoRoll"

local function hideStopAutoRoll(leftOpt: Instance?)
	local left = leftOpt or playerGui:FindFirstChild("MobileLeftUI") or playerGui:WaitForChild("MobileLeftUI", 60)
	if not left then
		return
	end
	LeftHudLayout.hardenScreenGui(left)
	local host = left:FindFirstChild(STUDIO_ANCHOR_NAME)
	if not host and leftOpt == nil then
		host = left:WaitForChild(STUDIO_ANCHOR_NAME, 30)
	end
	if host and host:IsA("GuiObject") then
		host.Visible = false
		host.Active = false
	end
end

Remotes.get("SeedWheelAutoRollSync").OnClientEvent:Connect(function(enabled: any)
	SeedWheelAutoRollState._setEnabled(enabled == true)
end)

LeftHudLayout.watchMobileLeftUi(playerGui, hideStopAutoRoll)

task.spawn(function()
	while true do
		task.wait(2)
		hideStopAutoRoll(nil)
	end
end)

print("[StopAutoRoll] Ready (hidden, auto on)")
