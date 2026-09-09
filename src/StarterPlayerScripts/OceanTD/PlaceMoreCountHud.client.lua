--!strict
--[[
	While build mode (backpack) is open: bottom-center "N Of N Max" + green +
	that opens skills bubbles and the Place More power-up.
	Only the + button captures clicks; the count text passes through to corals.
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

-- Text lives in its own ScreenGui so it never participates in button hit-tests.
local textSg = Instance.new("ScreenGui")
textSg.Name = "OceanTD_PlaceMoreCountText"
textSg.ResetOnSpawn = false
textSg.IgnoreGuiInset = true
textSg.DisplayOrder = 44
textSg.Enabled = false
textSg.Parent = playerGui

local countLabel = Instance.new("TextLabel")
countLabel.Name = "Count"
countLabel.AnchorPoint = Vector2.new(1, 1)
countLabel.Position = UDim2.new(0.5, -6, 1, -28)
countLabel.Size = UDim2.fromOffset(0, ROW_H)
countLabel.AutomaticSize = Enum.AutomaticSize.X
countLabel.BackgroundTransparency = 1
countLabel.Font = UiTheme.Font
countLabel.TextSize = 26
countLabel.TextColor3 = Color3.new(1, 1, 1)
countLabel.TextStrokeTransparency = 0.45
countLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
countLabel.TextXAlignment = Enum.TextXAlignment.Right
countLabel.Text = "0 Of 30 Max"
countLabel.Active = false
countLabel.Interactable = false
countLabel.Parent = textSg

-- + button alone — only clickable surface.
local btnSg = Instance.new("ScreenGui")
btnSg.Name = "OceanTD_PlaceMoreCountHud"
btnSg.ResetOnSpawn = false
btnSg.IgnoreGuiInset = true
btnSg.DisplayOrder = 45
btnSg.Enabled = false
btnSg.Parent = playerGui

local plusBtn = Instance.new("TextButton")
plusBtn.Name = "PlaceMorePlus"
plusBtn.AnchorPoint = Vector2.new(0, 1)
plusBtn.Position = UDim2.new(0.5, 6, 1, -28 - math.floor((ROW_H - PLUS_CIRCLE) * 0.5))
plusBtn.Size = UDim2.fromOffset(PLUS_CIRCLE, PLUS_CIRCLE)
plusBtn.BackgroundColor3 = GREEN
plusBtn.BorderSizePixel = 0
plusBtn.Text = ""
plusBtn.AutoButtonColor = true
plusBtn.Active = true
plusBtn.Interactable = true
plusBtn.Parent = btnSg
local plusCorner = Instance.new("UICorner")
plusCorner.CornerRadius = UDim.new(1, 0)
plusCorner.Parent = plusBtn
local plusStroke = Instance.new("UIStroke")
plusStroke.Thickness = 2
plusStroke.Color = Color3.fromRGB(120, 255, 90)
plusStroke.Transparency = 0
plusStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
plusStroke.Parent = plusBtn
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
plusGlyph.Active = false
plusGlyph.Interactable = false
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
	textSg.Enabled = show
	btnSg.Enabled = show
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
	if textSg.Enabled then
		refreshCount()
	end
end)
ClientPlot.onChanged(function()
	if textSg.Enabled then
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
	while true do
		task.wait(0.5)
		if textSg.Enabled then
			refreshCount()
		end
		if InventoryState.isOpen() then
			refreshVisible()
		end
	end
end)

refreshVisible()
