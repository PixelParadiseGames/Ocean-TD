--!strict
--[[
	TEMP: reset all skill stages to 1 for the local player.
	Remove when no longer needed for testing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local resetRf = Remotes.getFunction("RequestResetSkillStages")

local sg = Instance.new("ScreenGui")
sg.Name = "OceanTD_TempResetSkills"
sg.ResetOnSpawn = false
sg.IgnoreGuiInset = true
sg.DisplayOrder = 120
sg.Parent = playerGui

local btn = Instance.new("TextButton")
btn.Name = "ResetSkills"
btn.AnchorPoint = Vector2.new(1, 1)
btn.Position = UDim2.new(1, -12, 1, -12)
btn.Size = UDim2.fromOffset(148, 36)
btn.BackgroundColor3 = Color3.fromRGB(160, 40, 40)
btn.BorderSizePixel = 0
btn.Font = UiTheme.Font
btn.TextSize = 16
btn.TextColor3 = Color3.new(1, 1, 1)
btn.Text = "TEMP Reset Skills"
btn.AutoButtonColor = true
btn.Parent = sg
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = btn

local busy = false
btn.Activated:Connect(function()
	if busy then
		return
	end
	busy = true
	btn.Text = "Resetting…"
	local ok, result = pcall(function()
		return resetRf:InvokeServer()
	end)
	if ok and typeof(result) == "table" and result.ok == true then
		btn.Text = "Reset OK"
	else
		btn.Text = "Reset failed"
		warn("[TEMP] ResetSkillStages failed", result)
	end
	task.delay(1.2, function()
		btn.Text = "TEMP Reset Skills"
		busy = false
	end)
end)

print("[TEMP] Reset Skills button ready (bottom-right)")
