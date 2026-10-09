--!strict
--[[
	Refund Skills: return all $D spent on skill unlocks and reset every skill to stage 1.
	Button shows while skills bubbles are open; Confirm / Cancel popup is gamepad-friendly.
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))

local resetRf = Remotes.getFunction("RequestResetSkillStages")

local SKILLS_OPEN_ATTR = "OceanTD_SkillsBubblesOpen"
local PANEL_BG = Color3.fromRGB(12, 28, 36)
local GREEN = Color3.fromRGB(40, 170, 70)
local COST_GREEN = Color3.fromRGB(40, 255, 90)
local RED = Color3.fromRGB(220, 50, 55)

local sg = Instance.new("ScreenGui")
sg.Name = "OceanTD_RefundSkills"
sg.ResetOnSpawn = false
sg.IgnoreGuiInset = true
sg.DisplayOrder = 120
sg.Enabled = false
sg.Parent = playerGui

local btn = Instance.new("TextButton")
btn.Name = "RefundSkills"
btn.AnchorPoint = Vector2.new(1, 1)
btn.Position = UDim2.new(1, -12, 1, -12)
btn.Size = UDim2.fromOffset(148, 36)
btn.BackgroundColor3 = Color3.fromRGB(160, 40, 40)
btn.BorderSizePixel = 0
btn.Font = UiTheme.Font
btn.TextSize = 16
btn.TextColor3 = Color3.new(1, 1, 1)
btn.Text = "Refund Skills"
btn.AutoButtonColor = true
btn.Parent = sg
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = btn

local confirmGui: ScreenGui? = nil
local busy = false
local tipConn: RBXScriptConnection? = nil
local selectableRestore: { [GuiObject]: boolean } = {}
local prevSelected: GuiObject? = nil

local function isGamepadMode(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function linkTwoWay(a: GuiButton, b: GuiButton)
	a.NextSelectionUp = b
	a.NextSelectionDown = b
	a.NextSelectionLeft = b
	a.NextSelectionRight = b
	b.NextSelectionUp = a
	b.NextSelectionDown = a
	b.NextSelectionLeft = a
	b.NextSelectionRight = a
end

local function hideConfirm()
	if tipConn then
		tipConn:Disconnect()
		tipConn = nil
	end
	if confirmGui then
		confirmGui:Destroy()
		confirmGui = nil
	end
	for obj, was in pairs(selectableRestore) do
		if obj.Parent then
			obj.Selectable = was
		end
	end
	table.clear(selectableRestore)
	if prevSelected and prevSelected.Parent then
		GuiService.SelectedObject = prevSelected
	end
	prevSelected = nil
end

local function computeRefundPreview(): number
	local map: { [string]: number } = {}
	for _, def in ipairs(SkillStages.all()) do
		map[def.id] = SkillPowerUpUI.getUnlockedStage(def.id)
	end
	return SkillStages.spentSandDollarsForMap(map)
end

local function beginConfirmGamepadNav(confirm: GuiButton, cancel: GuiButton)
	prevSelected = GuiService.SelectedObject
	table.clear(selectableRestore)
	for _, layer in ipairs(playerGui:GetChildren()) do
		if not layer:IsA("LayerCollector") then
			continue
		end
		for _, d in ipairs(layer:GetDescendants()) do
			if d:IsA("GuiObject") then
				selectableRestore[d] = d.Selectable
				d.Selectable = (d == confirm or d == cancel)
			end
		end
	end
	confirm.Selectable = true
	cancel.Selectable = true
	linkTwoWay(confirm, cancel)
	GuiService.AutoSelectGuiEnabled = true
	GuiService.SelectedObject = confirm
end

local function doRefundRemote()
	if busy then
		return
	end
	busy = true
	hideConfirm()
	btn.Text = "Refunding…"
	local ok, result = pcall(function()
		return resetRf:InvokeServer()
	end)
	if ok and typeof(result) == "table" and result.ok == true then
		local refunded = math.floor(tonumber(result.refunded) or 0)
		btn.Text = if refunded > 0 then ("+" .. tostring(refunded) .. " $D") else "Refunded"
		-- Close skill power-up so ring/chrome refresh from SkillStagesSync.
		if SkillPowerUpUI.isOpen() then
			SkillPowerUpUI.close()
		end
	else
		btn.Text = "Refund failed"
		warn("[RefundSkills] failed", result)
	end
	task.delay(1.4, function()
		btn.Text = "Refund Skills"
		busy = false
	end)
end

local function showConfirm()
	if busy or confirmGui then
		return
	end
	hideConfirm()
	local refund = computeRefundPreview()

	local csg = Instance.new("ScreenGui")
	csg.Name = "OceanTD_RefundSkillsConfirm"
	csg.ResetOnSpawn = false
	csg.IgnoreGuiInset = true
	csg.DisplayOrder = 200
	csg.Parent = playerGui
	confirmGui = csg

	local dim = Instance.new("TextButton")
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.BackgroundColor3 = Color3.fromRGB(0, 8, 16)
	dim.BackgroundTransparency = 0.4
	dim.Size = UDim2.fromScale(1, 1)
	dim.Selectable = false
	dim.Parent = csg
	dim.Activated:Connect(hideConfirm)

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(320, 248)
	panel.BackgroundColor3 = PANEL_BG
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Selectable = false
	panel.Parent = csg
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 14)
	pc.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -24, 0, 40)
	title.Position = UDim2.fromOffset(12, 14)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 24
	title.TextColor3 = Color3.fromRGB(240, 248, 255)
	title.Text = "Refund Skills?"
	title.ZIndex = 3
	title.Parent = panel

	local body = Instance.new("TextLabel")
	body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, -24, 0, 36)
	body.Position = UDim2.fromOffset(12, 54)
	body.Font = UiTheme.Font
	body.TextSize = 16
	body.TextColor3 = Color3.fromRGB(200, 220, 235)
	body.TextWrapped = true
	body.Text = "Reset all skills to stage 1 and return spent $D."
	body.ZIndex = 3
	body.Parent = panel

	local costLbl = Instance.new("TextLabel")
	costLbl.Name = "RefundAmount"
	costLbl.BackgroundTransparency = 1
	costLbl.Size = UDim2.new(1, -24, 0, 28)
	costLbl.Position = UDim2.fromOffset(12, 94)
	costLbl.Font = Enum.Font.GothamBold
	costLbl.TextSize = 22
	costLbl.TextColor3 = COST_GREEN
	costLbl.Text = "+" .. tostring(refund) .. " $D"
	costLbl.ZIndex = 3
	costLbl.Parent = panel

	local confirm = Instance.new("TextButton")
	confirm.Name = "CONFIRM"
	confirm.Text = "CONFIRM"
	confirm.Font = Enum.Font.GothamBold
	confirm.TextSize = 20
	confirm.TextColor3 = Color3.new(1, 1, 1)
	confirm.BackgroundColor3 = GREEN
	confirm.BorderSizePixel = 0
	confirm.Size = UDim2.fromOffset(200, 48)
	confirm.AnchorPoint = Vector2.new(0.5, 0)
	confirm.Position = UDim2.new(0.5, 0, 0, 132)
	confirm.ZIndex = 3
	confirm.Parent = panel
	local uc = Instance.new("UICorner")
	uc.CornerRadius = UDim.new(0, 10)
	uc.Parent = confirm
	confirm.Activated:Connect(doRefundRemote)

	local cancel = Instance.new("TextButton")
	cancel.Name = "CANCEL"
	cancel.Text = "CANCEL"
	cancel.Font = Enum.Font.GothamBold
	cancel.TextSize = 18
	cancel.TextColor3 = Color3.new(1, 1, 1)
	cancel.BackgroundColor3 = RED
	cancel.BorderSizePixel = 0
	cancel.Size = UDim2.fromOffset(200, 44)
	cancel.AnchorPoint = Vector2.new(0.5, 0)
	cancel.Position = UDim2.new(0.5, 0, 0, 188)
	cancel.ZIndex = 3
	cancel.Parent = panel
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 10)
	cc.Parent = cancel
	cancel.Activated:Connect(hideConfirm)

	if isGamepadMode() then
		beginConfirmGamepadNav(confirm, cancel)
	else
		local tipT0 = os.clock()
		tipConn = RunService.Heartbeat:Connect(function()
			if not confirmGui or confirmGui ~= csg then
				if tipConn then
					tipConn:Disconnect()
					tipConn = nil
				end
				return
			end
			local showTip = (math.floor((os.clock() - tipT0) / 1) % 2) == 1
			confirm.Text = if showTip then "Enter" else "CONFIRM"
			cancel.Text = if showTip then "Backspace" else "CANCEL"
		end)
	end
end

local function syncVisible()
	local open = playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true
	sg.Enabled = open
	if not open then
		hideConfirm()
	end
end

syncVisible()
playerGui:GetAttributeChangedSignal(SKILLS_OPEN_ATTR):Connect(syncVisible)

btn.Activated:Connect(function()
	if busy then
		return
	end
	showConfirm()
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not confirmGui then
		return
	end
	if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.ButtonA then
		doRefundRemote()
	elseif input.KeyCode == Enum.KeyCode.Backspace or input.KeyCode == Enum.KeyCode.ButtonB then
		hideConfirm()
	end
end)
