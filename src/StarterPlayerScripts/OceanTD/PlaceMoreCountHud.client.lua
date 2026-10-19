--!strict
--[[
	Bottom-center build-mode HUD:
	• First-roll plot finger (0 corals, RollFingerHint == "plot"): "Plant Coral In Plot" (no +).
	• When ≤3 slots remain: "N Of N Max" + green + → Place More skill.
	• When at max (0 remaining): red "Increase Max Planted" → Place More skill.
	Count text passes through to corals; only + / Increase capture clicks.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

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
local HINT_ATTR = "OceanTD_RollFingerHint"
-- BillboardGui cannot stack above ScreenGui — hide this HUD while coral PLANT/Confirm chrome is up.
local PLACE_CHROME_ATTR = "OceanTD_PlaceConfirmChromeUp"
local RELOCATE_CHROME_ATTR = "OceanTD_RelocateChromeUp"
-- InventoryUI bumps this (os.clock) when player taps a seed at place-cap.
local FLASH_INCREASE_ATTR = "OceanTD_FlashIncreaseMaxPlanted"
local PLANT_HINT_TEXT = "Plant Coral In Plot"
local INCREASE_TEXT = "Increase Max Planted"
local REMAINING_SHOW_AT = 3 -- show N Of N Max + when this many slots (or fewer) left, but not 0
local ROW_H = 44
local PLUS_CIRCLE = math.floor(ROW_H * 0.6 + 0.5) -- 40% smaller green circle
local PLUS_TEXT_SIZE = 30 -- keep glyph size when circle shrinks
local GREEN = Color3.fromRGB(45, 190, 75)
local INCREASE_RED = Color3.fromRGB(230, 70, 70) -- gradient top
local INCREASE_RED_DARK = Color3.fromRGB(96, 20, 24) -- gradient bottom
local INCREASE_STROKE = Color3.fromRGB(255, 140, 140)
local INCREASE_STROKE_FLASH = Color3.fromRGB(255, 40, 40) -- bright red during bounce
local INCREASE_BTN_SIZE = Vector2.new(220, 44)
local INCREASE_HOLD_SCALE = 1.25
local INCREASE_HOLD_SEC = 5
local PLANT_PULSE_SCALE = 1.12
local PLANT_PULSE_SEC = 0.55
local plantPulseToken = 0

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
local countScale = Instance.new("UIScale")
countScale.Scale = 1
countScale.Parent = countLabel

local function stopPlantPulse()
	plantPulseToken += 1
	countScale.Scale = 1
end

local function startPlantPulse()
	plantPulseToken += 1
	local my = plantPulseToken
	countScale.Scale = 1
	task.spawn(function()
		while my == plantPulseToken and textSg.Enabled and countScale.Parent do
			local up = TweenService:Create(
				countScale,
				TweenInfo.new(PLANT_PULSE_SEC, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Scale = PLANT_PULSE_SCALE }
			)
			up:Play()
			up.Completed:Wait()
			if my ~= plantPulseToken then
				return
			end
			local down = TweenService:Create(
				countScale,
				TweenInfo.new(PLANT_PULSE_SEC, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Scale = 1 }
			)
			down:Play()
			down.Completed:Wait()
		end
	end)
end

-- + button alone — only clickable surface for near-max count.
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
plusBtn.Visible = false
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

-- Maxed: red gradient CTA (same style as Skip Intro / Skip Training).
local increaseBtn = Instance.new("TextButton")
increaseBtn.Name = "IncreaseMaxPlanted"
increaseBtn.AnchorPoint = Vector2.new(0.5, 1)
increaseBtn.Position = UDim2.new(0.5, 0, 1, -28)
increaseBtn.Size = UDim2.fromOffset(INCREASE_BTN_SIZE.X, INCREASE_BTN_SIZE.Y)
increaseBtn.BackgroundColor3 = Color3.new(1, 1, 1)
increaseBtn.BorderSizePixel = 0
increaseBtn.Text = ""
increaseBtn.AutoButtonColor = true
increaseBtn.Active = true
increaseBtn.Interactable = true
increaseBtn.Visible = false
increaseBtn.Parent = btnSg
local incCorner = Instance.new("UICorner")
incCorner.CornerRadius = UDim.new(0, 8)
incCorner.Parent = increaseBtn
local incGrad = Instance.new("UIGradient")
incGrad.Name = "_OceanTD_IncreaseGrad"
incGrad.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, INCREASE_RED),
	ColorSequenceKeypoint.new(1, INCREASE_RED_DARK),
})
incGrad.Rotation = 90
incGrad.Parent = increaseBtn
local incStroke = Instance.new("UIStroke")
incStroke.Thickness = 2.5
incStroke.Color = INCREASE_STROKE
incStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
incStroke.Parent = increaseBtn
local incPad = Instance.new("UIPadding")
incPad.PaddingTop = UDim.new(0.08, 0)
incPad.PaddingBottom = UDim.new(0.08, 0)
incPad.PaddingLeft = UDim.new(0.08, 0)
incPad.PaddingRight = UDim.new(0.08, 0)
incPad.Parent = increaseBtn
local incLbl = Instance.new("TextLabel")
incLbl.Name = "Label"
incLbl.BackgroundTransparency = 1
incLbl.Size = UDim2.fromScale(1, 1)
incLbl.Font = UiTheme.Font
incLbl.Text = INCREASE_TEXT
incLbl.TextColor3 = Color3.new(1, 1, 1)
incLbl.TextScaled = true
incLbl.ZIndex = 2
incLbl.Active = false
incLbl.Interactable = false
incLbl.Parent = increaseBtn
local increaseScale = Instance.new("UIScale")
increaseScale.Scale = 1
increaseScale.Parent = increaseBtn
local increaseFlashToken = 0

local function placeMax(): number
	return SkillStages.placeMoreMaxAtStage(SkillPowerUpUI.getStage("PlaceMore"))
end

local function flashIncreaseMaxPlanted()
	-- Force the red CTA on even if chrome/count layout would hide it this frame.
	textSg.Enabled = false
	btnSg.Enabled = true
	plusBtn.Visible = false
	plusBtn.Active = false
	increaseBtn.Visible = true
	increaseBtn.Active = true
	pcall(function()
		local p: any = plusBtn
		local i: any = increaseBtn
		p.Interactable = false
		i.Interactable = true
	end)
	increaseFlashToken += 1
	local my = increaseFlashToken
	increaseScale.Scale = 1
	incStroke.Color = INCREASE_STROKE
	incStroke.Thickness = 2.5
	UiHaptics.pulseShort()
	task.spawn(function()
		for _ = 1, 3 do
			if my ~= increaseFlashToken or not increaseScale.Parent then
				return
			end
			incStroke.Color = INCREASE_STROKE_FLASH
			incStroke.Thickness = 4
			local up = TweenService:Create(
				increaseScale,
				TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = 1.14 }
			)
			local strokeUp = TweenService:Create(
				incStroke,
				TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Color = INCREASE_STROKE_FLASH, Thickness = 4.5 }
			)
			up:Play()
			strokeUp:Play()
			up.Completed:Wait()
			if my ~= increaseFlashToken then
				return
			end
			local down = TweenService:Create(
				increaseScale,
				TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Scale = 1 }
			)
			local strokeDown = TweenService:Create(
				incStroke,
				TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Color = INCREASE_STROKE, Thickness = 2.5 }
			)
			down:Play()
			strokeDown:Play()
			down.Completed:Wait()
		end
		if my ~= increaseFlashToken then
			return
		end
		incStroke.Color = INCREASE_STROKE
		incStroke.Thickness = 2.5
		-- Hold +25% so the CTA stays noticeable, then ease back.
		local holdUp = TweenService:Create(
			increaseScale,
			TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = INCREASE_HOLD_SCALE }
		)
		holdUp:Play()
		holdUp.Completed:Wait()
		if my ~= increaseFlashToken then
			return
		end
		task.wait(INCREASE_HOLD_SEC)
		if my ~= increaseFlashToken or not increaseScale.Parent then
			return
		end
		local holdDown = TweenService:Create(
			increaseScale,
			TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Scale = 1 }
		)
		holdDown:Play()
		holdDown.Completed:Wait()
		if my == increaseFlashToken then
			increaseScale.Scale = 1
			incStroke.Color = INCREASE_STROKE
			incStroke.Thickness = 2.5
		end
	end)
end

local function chromeBlocked(): boolean
	if playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
		return true
	end
	if WaveSlot.isSummaryOpen() then
		return true
	end
	-- World coral chrome (Billboard) loses to this ScreenGui — step aside while PLANT/Confirm is up.
	if playerGui:GetAttribute(PLACE_CHROME_ATTR) == true then
		return true
	end
	if playerGui:GetAttribute(RELOCATE_CHROME_ATTR) == true then
		return true
	end
	return false
end

-- First-roll plot finger: 0 corals + RollFingerHint == "plot".
local function shouldShowPlantHint(): boolean
	if chromeBlocked() then
		return false
	end
	if PlacedCoralIndex.countLocal() > 0 then
		return false
	end
	return playerGui:GetAttribute(HINT_ATTR) == "plot"
end

local function openPlaceMoreSkill()
	UiHaptics.pulseShort()
	playerGui:SetAttribute("OceanTD_ForceOpenSkillId", "PlaceMore")
	playerGui:SetAttribute("OceanTD_ForceOpenSkills", os.clock())
end

local function applyCountLabelLayout(plantHint: boolean)
	if plantHint then
		countLabel.AnchorPoint = Vector2.new(0.5, 1)
		countLabel.Position = UDim2.new(0.5, 0, 1, -28)
		countLabel.TextXAlignment = Enum.TextXAlignment.Center
		countLabel.Text = PLANT_HINT_TEXT
	else
		countLabel.AnchorPoint = Vector2.new(1, 1)
		countLabel.Position = UDim2.new(0.5, -6, 1, -28)
		countLabel.TextXAlignment = Enum.TextXAlignment.Right
		local n = PlacedCoralIndex.countLocal()
		local maxN = placeMax()
		countLabel.Text = string.format("%d Of %d Max", n, maxN)
	end
end

local plantPulseActive = false

local function joinIntroHidesPlaceMore(): boolean
	return playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true
		or playerGui:GetAttribute("OceanTD_JoinIntroShowBackpack") == true
		or InventoryState.isJoinIntroDemo()
end

local function refreshVisible()
	if shouldShowPlantHint() then
		applyCountLabelLayout(true)
		textSg.Enabled = true
		btnSg.Enabled = false
		plusBtn.Visible = false
		increaseBtn.Visible = false
		if not plantPulseActive then
			plantPulseActive = true
			startPlantPulse()
		end
		return
	end
	if plantPulseActive then
		plantPulseActive = false
		stopPlantPulse()
	end

	if not InventoryState.isOpen() or chromeBlocked() or joinIntroHidesPlaceMore() then
		textSg.Enabled = false
		btnSg.Enabled = false
		plusBtn.Visible = false
		increaseBtn.Visible = false
		plusBtn.Active = false
		increaseBtn.Active = false
		pcall(function()
			local p: any = plusBtn
			local i: any = increaseBtn
			p.Interactable = false
			i.Interactable = false
		end)
		return
	end

	local n = PlacedCoralIndex.countLocal()
	local maxN = placeMax()
	local remaining = maxN - n

	if remaining <= 0 then
		-- At / over max (also when place aim shows "Max Placed"): red CTA only.
		textSg.Enabled = false
		btnSg.Enabled = true
		plusBtn.Visible = false
		plusBtn.Active = false
		increaseBtn.Visible = true
		increaseBtn.Active = true
		pcall(function()
			local p: any = plusBtn
			local i: any = increaseBtn
			p.Interactable = false
			i.Interactable = true
		end)
		return
	end

	if remaining <= REMAINING_SHOW_AT then
		applyCountLabelLayout(false)
		textSg.Enabled = true
		btnSg.Enabled = true
		plusBtn.Visible = true
		plusBtn.Active = true
		increaseBtn.Visible = false
		increaseBtn.Active = false
		pcall(function()
			local p: any = plusBtn
			local i: any = increaseBtn
			p.Interactable = true
			i.Interactable = false
		end)
		return
	end

	textSg.Enabled = false
	btnSg.Enabled = false
	plusBtn.Visible = false
	increaseBtn.Visible = false
	plusBtn.Active = false
	increaseBtn.Active = false
	pcall(function()
		local p: any = plusBtn
		local i: any = increaseBtn
		p.Interactable = false
		i.Interactable = false
	end)
end

plusBtn.Activated:Connect(openPlaceMoreSkill)
increaseBtn.Activated:Connect(openPlaceMoreSkill)

PlacedCoralIndex.ensure()
PlacedCoralIndex.onChanged(function()
	refreshVisible()
end)
ClientPlot.onChanged(function()
	refreshVisible()
end)
InventoryState.onOpenChanged(function()
	refreshVisible()
end)
playerGui:GetAttributeChangedSignal(SKILLS_OPEN_ATTR):Connect(function()
	refreshVisible()
end)
playerGui:GetAttributeChangedSignal(HINT_ATTR):Connect(function()
	refreshVisible()
end)
playerGui:GetAttributeChangedSignal(PLACE_CHROME_ATTR):Connect(function()
	refreshVisible()
end)
playerGui:GetAttributeChangedSignal(RELOCATE_CHROME_ATTR):Connect(function()
	refreshVisible()
end)
playerGui:GetAttributeChangedSignal(FLASH_INCREASE_ATTR):Connect(function()
	if joinIntroHidesPlaceMore() then
		return
	end
	if typeof(playerGui:GetAttribute(FLASH_INCREASE_ATTR)) == "number" then
		flashIncreaseMaxPlanted()
	end
end)
playerGui:GetAttributeChangedSignal("OceanTD_JoinIntroBusy"):Connect(function()
	refreshVisible()
end)
playerGui:GetAttributeChangedSignal("OceanTD_JoinIntroShowBackpack"):Connect(function()
	refreshVisible()
end)

task.spawn(function()
	while true do
		task.wait(0.5)
		if InventoryState.isOpen() or shouldShowPlantHint() or textSg.Enabled or btnSg.Enabled then
			refreshVisible()
		end
	end
end)

refreshVisible()
