--!strict
--[[
	While build mode (backpack) is open: bottom-center "N Of N Max" + green +
	that opens skills bubbles and the Place More power-up.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacedCoralIndex = require(script.Parent:WaitForChild("PlacedCoralIndex"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))
local WaveSlot = require(script.Parent:WaitForChild("WaveSlot"))

local SKILLS_OPEN_ATTR = "OceanTD_SkillsBubblesOpen"
local ROW_H = 44
local PLUS_CIRCLE = math.floor(ROW_H * 0.6 + 0.5) -- 40% smaller green circle
local PLUS_TEXT_SIZE = 30 -- keep glyph size when circle shrinks
local GREEN = Color3.fromRGB(45, 190, 75)

local sg = Instance.new("ScreenGui")
sg.Name = "OceanTD_PlaceMoreCountHud"
sg.ResetOnSpawn = false
sg.IgnoreGuiInset = true
sg.DisplayOrder = 45
sg.Enabled = false
sg.Parent = playerGui

local row = Instance.new("Frame")
row.Name = "Row"
row.AnchorPoint = Vector2.new(0.5, 1)
row.Position = UDim2.new(0.5, 0, 1, -28)
row.Size = UDim2.fromOffset(320, ROW_H)
row.BackgroundTransparency = 1
row.Parent = sg

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.VerticalAlignment = Enum.VerticalAlignment.Center
layout.Padding = UDim.new(0, 12)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = row

local countLabel = Instance.new("TextLabel")
countLabel.Name = "Count"
countLabel.BackgroundTransparency = 1
countLabel.Size = UDim2.fromOffset(220, ROW_H)
countLabel.Font = UiTheme.Font
countLabel.TextSize = 26
countLabel.TextColor3 = Color3.new(1, 1, 1)
countLabel.TextStrokeTransparency = 0.45
countLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
countLabel.TextXAlignment = Enum.TextXAlignment.Right
countLabel.Text = "0 Of 30 Max"
countLabel.LayoutOrder = 1
countLabel.Parent = row

local plusBtn = Instance.new("TextButton")
plusBtn.Name = "PlaceMorePlus"
plusBtn.Size = UDim2.fromOffset(PLUS_CIRCLE, PLUS_CIRCLE)
plusBtn.BackgroundColor3 = GREEN
plusBtn.BorderSizePixel = 0
plusBtn.Text = ""
plusBtn.AutoButtonColor = true
plusBtn.LayoutOrder = 2
plusBtn.Parent = row
local plusCorner = Instance.new("UICorner")
plusCorner.CornerRadius = UDim.new(1, 0)
plusCorner.Parent = plusBtn
local plusStroke = Instance.new("UIStroke")
plusStroke.Thickness = 2
plusStroke.Color = Color3.fromRGB(120, 255, 90)
plusStroke.Transparency = 0
plusStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
plusStroke.Parent = plusBtn
-- Separate glyph so TextSize stays 30 while the circle shrinks; nudge up for optical center.
local plusGlyph = Instance.new("TextLabel")
plusGlyph.Name = "Glyph"
plusGlyph.BackgroundTransparency = 1
plusGlyph.Size = UDim2.fromScale(1, 1)
plusGlyph.AnchorPoint = Vector2.new(0.5, 0.5)
plusGlyph.Position = UDim2.new(0.5, 0, 0.5, -1)
plusGlyph.Font = UiTheme.Font
plusGlyph.TextSize = PLUS_TEXT_SIZE
plusGlyph.TextColor3 = Color3.new(1, 1, 1)
plusGlyph.Text = "+"
plusGlyph.ZIndex = 2
plusGlyph.Parent = plusBtn

local function placeMax(): number
	return SkillStages.placeMoreMaxAtStage(SkillPowerUpUI.getStage("PlaceMore"))
end

local function refreshCount()
	local n = PlacedCoralIndex.countLocal()
	local maxN = placeMax()
	countLabel.Text = string.format("%d Of %d Max", n, maxN)
end

local function shouldShow(): boolean
	if not InventoryState.isOpen() then
		return false
	end
	if playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
		return false
	end
	if WaveSlot.isSummaryOpen() then
		return false
	end
	return true
end

local function refreshVisible()
	local show = shouldShow()
	sg.Enabled = show
	if show then
		refreshCount()
	end
end

plusBtn.Activated:Connect(function()
	UiHaptics.pulseShort()
	playerGui:SetAttribute("OceanTD_ForceOpenSkillId", "PlaceMore")
	playerGui:SetAttribute("OceanTD_ForceOpenSkills", os.clock())
end)

PlacedCoralIndex.ensure()
PlacedCoralIndex.onChanged(function()
	if sg.Enabled then
		refreshCount()
	end
end)
ClientPlot.onChanged(function()
	if sg.Enabled then
		refreshCount()
	end
end)
InventoryState.onOpenChanged(function()
	refreshVisible()
end)
playerGui:GetAttributeChangedSignal(SKILLS_OPEN_ATTR):Connect(function()
	refreshVisible()
end)

task.spawn(function()
	-- Stages may load after this script; keep max text fresh while open.
	while true do
		task.wait(0.5)
		if sg.Enabled then
			refreshCount()
		end
		-- Summary open can change without InventoryState events.
		if InventoryState.isOpen() then
			refreshVisible()
		end
	end
end)

refreshVisible()
