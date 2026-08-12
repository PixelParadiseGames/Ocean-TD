--!strict
--[[
	Power-up stage popup for MobileSkillsA skill bubbles.
	Rebinds Studio PowerUpTemplate (show/hide); bubbles hide while this is open.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))
local SkillsBubbleSim = require(script.Parent:WaitForChild("SkillsBubbleSim"))

local SkillPowerUpUI = {}

local POWERUP_OPEN_ATTR = "OceanTD_SkillPowerUpOpen"

local GREEN = Color3.fromRGB(40, 170, 70)
local DESC_PULSE_GREEN = Color3.fromRGB(70, 255, 110)
local DESC_PULSE_WHITE = Color3.new(1, 1, 1)
local RED = Color3.fromRGB(220, 50, 55)
local PANEL_BG = Color3.fromRGB(12, 28, 36)
local POWERUP_Z = 500
local CLOSE_X_PULSE = TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local stagesMap: { [string]: number } = SkillStages.defaultMap()
local panelRoot: Instance? = nil
local hostScreenGui: ScreenGui? = nil
local dPad: Instance? = nil
local template: GuiObject? = nil
local unlockNameLbl: TextLabel? = nil
local nextStageLbl: TextLabel? = nil
local unlockDescLbl: TextLabel? = nil
local unlockBtn: GuiButton? = nil
local closeBtn: GuiObject? = nil
local lockedTemplate: GuiObject? = nil
local stageButtons: { GuiObject } = {}
local lockOverlays: { GuiObject } = {}
local activeSkillId: string? = nil
local popupOpen = false
local confirmGui: ScreenGui? = nil
local toastGui: ScreenGui? = nil
local bound = false
local lastOpenAt = 0
local closeHitBtn: GuiButton? = nil
local closeXPulseTween: Tween? = nil
local selectableRestore: { [GuiObject]: boolean } = {}
local prevGuiSelected: GuiObject? = nil
local onClosedCb: (() -> ())? = nil
local confirmUnlockBtn: GuiButton? = nil
local confirmCancelBtn: GuiButton? = nil
local confirmPrevSelected: GuiObject? = nil
local unlockDescPulseConn: RBXScriptConnection? = nil
local unlockDescPulseToken = 0
local lastPowerUpClickAt = 0

local unlockRf = Remotes.getFunction("RequestUnlockSkillStage")
local getStagesRf = Remotes.getFunction("RequestGetSkillStages")
local syncRemote = Remotes.get("SkillStagesSync")

local function powerUpClickGuard(): boolean
	local now = os.clock()
	if now - lastPowerUpClickAt < 0.2 then
		return false
	end
	lastPowerUpClickAt = now
	return true
end

local function bindButtonPress(btn: GuiButton, attr: string, fn: () -> ())
	if btn:GetAttribute(attr) == true then
		return
	end
	btn:SetAttribute(attr, true)
	btn.Activated:Connect(fn)
	btn.MouseButton1Click:Connect(fn)
end

local function onClosePressed()
	if not popupOpen or not powerUpClickGuard() then
		return
	end
	if confirmGui then
		hideConfirm()
	else
		SkillPowerUpUI.close()
	end
end

local function onUnlockPressed()
	if not popupOpen or not powerUpClickGuard() then
		return
	end
	if confirmGui then
		return
	end
	SkillPowerUpUI.requestUnlockNext()
end

local function stopUnlockDescPulse()
	unlockDescPulseToken += 1
	if unlockDescPulseConn then
		unlockDescPulseConn:Disconnect()
		unlockDescPulseConn = nil
	end
end

local function rgbFontTag(c: Color3): string
	return string.format(
		"rgb(%d,%d,%d)",
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5)
	)
end

local function startUnlockDescPulse(skillId: string, buildRichText: (Color3) -> string)
	stopUnlockDescPulse()
	if not unlockDescLbl then
		return
	end
	unlockDescLbl.RichText = true
	unlockDescLbl.Visible = true
	local token = unlockDescPulseToken
	unlockDescPulseConn = RunService.Heartbeat:Connect(function()
		if token ~= unlockDescPulseToken or not unlockDescLbl then
			return
		end
		if not popupOpen or activeSkillId ~= skillId then
			return
		end
		local u = (math.sin(os.clock() * math.pi * 1.35) + 1) * 0.5
		local c = DESC_PULSE_GREEN:Lerp(DESC_PULSE_WHITE, u)
		unlockDescLbl.Text = buildRichText(c)
	end)
end

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

local function clearNextSelection(btn: GuiButton)
	btn.NextSelectionUp = nil
	btn.NextSelectionDown = nil
	btn.NextSelectionLeft = nil
	btn.NextSelectionRight = nil
end

local function endGamepadNav()
	-- Do not re-enable foreign Selectables here — skills may still be open (bubbles mode).
	table.clear(selectableRestore)
	GuiService.SelectedObject = nil
	prevGuiSelected = nil
	if unlockBtn then
		clearNextSelection(unlockBtn)
		unlockBtn.Selectable = false
	end
	if closeHitBtn then
		clearNextSelection(closeHitBtn)
		closeHitBtn.Selectable = false
	end
end

local function beginGamepadNav()
	table.clear(selectableRestore)
	if unlockBtn then
		clearNextSelection(unlockBtn)
	end
	if closeHitBtn then
		clearNextSelection(closeHitBtn)
	end

	if not popupOpen or not isGamepadMode() or not hostScreenGui then
		GuiService.SelectedObject = nil
		return
	end
	prevGuiSelected = nil
	-- Power-up needs GuiService selection for UNLOCK ↔ Close only.
	GuiService.AutoSelectGuiEnabled = true
	GuiService.SelectedObject = nil

	for _, layer in ipairs(playerGui:GetChildren()) do
		if not layer:IsA("LayerCollector") then
			continue
		end
		local function consider(obj: Instance)
			if obj:IsA("GuiObject") and obj.Selectable then
				if obj ~= unlockBtn and obj ~= closeHitBtn then
					selectableRestore[obj] = true
					obj.Selectable = false
				end
			end
		end
		consider(layer)
		for _, d in ipairs(layer:GetDescendants()) do
			consider(d)
		end
	end

	local unlockOk = unlockBtn ~= nil and unlockBtn.Visible and unlockBtn.Active
	local closeOk = closeHitBtn ~= nil and closeBtn ~= nil and closeBtn.Visible
	if closeOk and closeHitBtn then
		closeHitBtn.Selectable = true
		closeHitBtn.Active = true
	elseif closeHitBtn then
		closeHitBtn.Selectable = false
	end
	if unlockOk and unlockBtn then
		unlockBtn.Selectable = true
		if closeOk and closeHitBtn then
			linkTwoWay(unlockBtn, closeHitBtn)
		else
			clearNextSelection(unlockBtn)
		end
		GuiService.SelectedObject = unlockBtn
	elseif closeOk and closeHitBtn then
		clearNextSelection(closeHitBtn)
		GuiService.SelectedObject = closeHitBtn
	end
end

local function stopCloseXPulse()
	if closeXPulseTween then
		closeXPulseTween:Cancel()
		closeXPulseTween = nil
	end
	if closeBtn then
		local lbl = closeBtn:FindFirstChild("_OceanTD_CloseX")
		if lbl then
			local scale = lbl:FindFirstChildOfClass("UIScale")
			if scale then
				scale.Scale = 1
			end
		end
	end
end

local function startCloseXPulse()
	stopCloseXPulse()
	if not closeBtn then
		return
	end
	local lbl = closeBtn:FindFirstChild("_OceanTD_CloseX")
	if not (lbl and lbl:IsA("TextLabel")) then
		return
	end
	-- Scale from center so the glyph doesn't drift toward a corner.
	lbl.AnchorPoint = Vector2.new(0.5, 0.5)
	lbl.Position = UDim2.fromScale(0.5, 0.5)
	lbl.Size = UDim2.fromScale(1, 1)
	local scale = lbl:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "_OceanTD_CloseXScale"
		scale.Parent = lbl
	end
	scale.Scale = 1
	closeXPulseTween = TweenService:Create(scale, CLOSE_X_PULSE, { Scale = 1.28 })
	closeXPulseTween:Play()
end

local function syncCloseGlyph()
	if not closeBtn then
		return
	end
	local lbl = closeBtn:FindFirstChild("_OceanTD_CloseX")
	if lbl and lbl:IsA("TextLabel") then
		lbl.Text = if isGamepadMode() then "B" else "X"
		lbl.TextColor3 = Color3.new(1, 1, 1)
		lbl.TextTransparency = 0
	end
end

local function applyStages(raw: any)
	stagesMap = SkillStages.sanitizeMap(raw)
end

local function currentStage(skillId: string): number
	return SkillStages.clampStage(stagesMap[skillId])
end

local function findTextLabel(host: Instance, name: string): TextLabel?
	local n = host:FindFirstChild(name, true)
	if n and n:IsA("TextLabel") then
		return n
	end
	return nil
end

local function findGuiButton(host: Instance, name: string): GuiButton?
	local n = host:FindFirstChild(name, true)
	if n and n:IsA("GuiButton") then
		return n
	end
	if n and n:IsA("GuiObject") then
		local inner = n:FindFirstChildWhichIsA("GuiButton", true)
		if inner then
			return inner
		end
	end
	return nil
end

local function stopCloseXOverlay()
	stopCloseXPulse()
	-- Legacy floating X (ScreenGui) — remove if present from older builds.
	if hostScreenGui then
		local floating = hostScreenGui:FindFirstChild("_OceanTD_PowerUpCloseX")
		if floating then
			floating:Destroy()
		end
	end
	local nested = if closeBtn then closeBtn:FindFirstChild("_OceanTD_CloseX") else nil
	if nested then
		nested:Destroy()
	end
end

-- Single white X on CloseBTN (no second floating overlay).
local function ensureCloseXVisible()
	if not closeBtn then
		return
	end
	if hostScreenGui then
		local floating = hostScreenGui:FindFirstChild("_OceanTD_PowerUpCloseX")
		if floating then
			floating:Destroy()
		end
	end

	local nested = closeBtn:FindFirstChild("_OceanTD_CloseX")
	if not (nested and nested:IsA("TextLabel")) then
		if nested then
			nested:Destroy()
		end
		local lbl = Instance.new("TextLabel")
		lbl.Name = "_OceanTD_CloseX"
		lbl.BackgroundTransparency = 1
		lbl.AnchorPoint = Vector2.new(0.5, 0.5)
		lbl.Position = UDim2.fromScale(0.5, 0.5)
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.Font = Enum.Font.GothamBold
		lbl.Text = if isGamepadMode() then "B" else "X"
		lbl.TextColor3 = Color3.new(1, 1, 1)
		lbl.TextTransparency = 0
		lbl.TextScaled = true
		lbl.Active = false
		lbl.ZIndex = math.max(closeBtn.ZIndex + 5, POWERUP_Z + 720)
		lbl.Parent = closeBtn
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.18, 0)
		pad.PaddingBottom = UDim.new(0.18, 0)
		pad.PaddingLeft = UDim.new(0.18, 0)
		pad.PaddingRight = UDim.new(0.18, 0)
		pad.Parent = lbl
	else
		local lbl = nested :: TextLabel
		lbl.AnchorPoint = Vector2.new(0.5, 0.5)
		lbl.Position = UDim2.fromScale(0.5, 0.5)
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.Text = if isGamepadMode() then "B" else "X"
		lbl.TextColor3 = Color3.new(1, 1, 1)
		lbl.TextTransparency = 0
		lbl.Visible = true
		lbl.Active = false
		lbl.ZIndex = math.max(closeBtn.ZIndex + 5, POWERUP_Z + 720)
		lbl.Parent = closeBtn
	end
	syncCloseGlyph()
	startCloseXPulse()
end

local function clearLockOverlays()
	for _, o in ipairs(lockOverlays) do
		o:Destroy()
	end
	table.clear(lockOverlays)
end

-- Global ZIndex: raise whole tree so popup sits above floating bubbles (Z ~20–90).
-- Keep a flat +1 boost so we don't bury CloseBTN / UNLOCK under random TextButtons.
local function raiseTreeAboveBubbles(root: GuiObject)
	root.ZIndex = math.max(root.ZIndex, POWERUP_Z)
	local base = root.ZIndex
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("GuiObject") then
			d.ZIndex = math.max(d.ZIndex, base + 1)
		end
	end
end

local function raiseInteractive(root: GuiObject, z: number)
	root.ZIndex = z
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("GuiObject") then
			d.ZIndex = z + 1
		end
	end
end

local function placeLockOn(stageBtn: GuiObject)
	if not lockedTemplate then
		return
	end
	local clone = lockedTemplate:Clone()
	clone.Name = "_OceanTD_StageLock"
	clone.Visible = true
	if clone:IsA("GuiObject") then
		clone.Size = UDim2.fromScale(1, 1)
		clone.Position = UDim2.fromScale(0, 0)
		clone.AnchorPoint = Vector2.new(0, 0)
		clone.ZIndex = stageBtn.ZIndex + 5
	end
	clone.Parent = stageBtn
	table.insert(lockOverlays, clone)
	local hit: GuiButton? = if clone:IsA("GuiButton") then clone else clone:FindFirstChildWhichIsA("GuiButton", true)
	if hit then
		hit.Active = true
		hit.Activated:Connect(function()
			SkillPowerUpUI.requestUnlockNext()
		end)
	elseif clone:IsA("GuiButton") then
		(clone :: GuiButton).Activated:Connect(function()
			SkillPowerUpUI.requestUnlockNext()
		end)
	else
		local b = Instance.new("TextButton")
		b.Name = "_OceanTD_LockHit"
		b.Text = ""
		b.BackgroundTransparency = 1
		b.Size = UDim2.fromScale(1, 1)
		b.ZIndex = clone:IsA("GuiObject") and (clone :: GuiObject).ZIndex + 1 or 10
		b.Parent = clone
		b.Activated:Connect(function()
			SkillPowerUpUI.requestUnlockNext()
		end)
	end
end

local function refreshTemplate()
	if not template or not activeSkillId then
		return
	end
	local def = SkillStages.get(activeSkillId)
	if not def then
		return
	end
	local stage = currentStage(activeSkillId)
	if unlockNameLbl then
		unlockNameLbl.Text = def.displayName
	end
	local nextS = SkillStages.nextStage(stage)
	if nextStageLbl then
		if nextS then
			nextStageLbl.Text = "Stage " .. tostring(nextS)
			nextStageLbl.Visible = true
		else
			nextStageLbl.Text = "Max Stage"
			nextStageLbl.Visible = true
		end
	end
	if unlockDescLbl then
		-- Describe the next unlock; if maxed, describe the current stage.
		local descStage = nextS or stage
		if activeSkillId == "PlaceMore" then
			local newMax = SkillStages.placeMoreMaxAtStage(descStage)
			startUnlockDescPulse("PlaceMore", function(c: Color3)
				return string.format(
					'<font color="%s">+20</font>  New Max: %d',
					rgbFontTag(c),
					newMax
				)
			end)
		elseif activeSkillId == "EarnMore" then
			local mult = SkillStages.clampStage(descStage)
			if mult <= 1 then
				stopUnlockDescPulse()
				unlockDescLbl.RichText = false
				unlockDescLbl.Text = SkillStages.unlockDesc(activeSkillId, descStage)
				unlockDescLbl.Visible = true
			else
				startUnlockDescPulse("EarnMore", function(c: Color3)
					return string.format(
						'Get <font color="%s">%dx</font> per fish fed',
						rgbFontTag(c),
						mult
					)
				end)
			end
		else
			stopUnlockDescPulse()
			unlockDescLbl.RichText = false
			unlockDescLbl.Text = SkillStages.unlockDesc(activeSkillId, descStage)
			unlockDescLbl.Visible = true
		end
	end
	if unlockBtn then
		unlockBtn.Visible = nextS ~= nil
		unlockBtn.Active = nextS ~= nil
		if nextS ~= nil then
			raiseInteractive(unlockBtn, POWERUP_Z + 650)
		end
		if unlockBtn:IsA("TextButton") or unlockBtn:IsA("ImageButton") then
			(unlockBtn :: any).BackgroundColor3 = GREEN
		end
		local textChild = unlockBtn:FindFirstChildWhichIsA("TextLabel", true)
		if unlockBtn:IsA("TextButton") then
			(unlockBtn :: TextButton).TextColor3 = Color3.new(1, 1, 1)
			if (unlockBtn :: TextButton).Text == "" and textChild then
				textChild.TextColor3 = Color3.new(1, 1, 1)
			end
		elseif textChild then
			textChild.TextColor3 = Color3.new(1, 1, 1)
		end
	end

	clearLockOverlays()
	for i = 1, SkillStages.MAX_STAGE do
		local sb = stageButtons[i]
		if not sb then
			continue
		end
		sb.Visible = true
		local leftoverNum = sb:FindFirstChild("_OceanTD_StageNum")
		if leftoverNum then
			leftoverNum:Destroy()
		end
		if i <= stage then
			-- Unlocked: green StageN visible, no lock
		else
			placeLockOn(sb)
		end
	end
	-- Locks / stage chrome can cover UNLOCK — keep interactives above.
	if closeBtn and popupOpen then
		raiseInteractive(closeBtn, POWERUP_Z + 700)
		if closeHitBtn then
			closeHitBtn.ZIndex = POWERUP_Z + 710
		end
	end
	if unlockBtn and unlockBtn.Visible and unlockBtn.Active then
		raiseInteractive(unlockBtn, POWERUP_Z + 650)
	end
	if popupOpen then
		beginGamepadNav()
	end
end

local function hideConfirm()
	confirmUnlockBtn = nil
	confirmCancelBtn = nil
	confirmPrevSelected = nil
	if confirmGui then
		confirmGui:Destroy()
		confirmGui = nil
	end
	if popupOpen and isGamepadMode() then
		beginGamepadNav()
	end
end

local function beginConfirmGamepadNav(unlock: GuiButton, cancel: GuiButton)
	confirmPrevSelected = GuiService.SelectedObject
	if unlockBtn then
		unlockBtn.Selectable = false
	end
	if closeHitBtn then
		closeHitBtn.Selectable = false
	end
	-- Only UNLOCK ↔ CANCEL across the whole PlayerGui.
	for _, layer in ipairs(playerGui:GetChildren()) do
		if not layer:IsA("LayerCollector") then
			continue
		end
		for _, d in ipairs(layer:GetDescendants()) do
			if d:IsA("GuiObject") then
				d.Selectable = (d == unlock or d == cancel)
			end
		end
	end
	unlock.Selectable = true
	cancel.Selectable = true
	linkTwoWay(unlock, cancel)
	confirmUnlockBtn = unlock
	confirmCancelBtn = cancel
	GuiService.AutoSelectGuiEnabled = true
	GuiService.SelectedObject = unlock
end

local function showToast(msg: string)
	if toastGui then
		toastGui:Destroy()
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_SkillToast"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 80
	sg.Parent = playerGui
	toastGui = sg
	local lbl = Instance.new("TextLabel")
	lbl.AnchorPoint = Vector2.new(0.5, 1)
	lbl.Position = UDim2.new(0.5, 0, 1, -48)
	lbl.Size = UDim2.fromOffset(360, 44)
	lbl.BackgroundColor3 = PANEL_BG
	lbl.BackgroundTransparency = 0.1
	lbl.BorderSizePixel = 0
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 20
	lbl.TextColor3 = Color3.fromRGB(255, 230, 200)
	lbl.Text = msg
	lbl.Parent = sg
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 10)
	c.Parent = lbl
	task.delay(2.2, function()
		if toastGui == sg then
			sg:Destroy()
			toastGui = nil
		end
	end)
end

local function doUnlockRemote()
	if not activeSkillId then
		return
	end
	local skillId = activeSkillId
	local ok, result = pcall(function()
		return unlockRf:InvokeServer(skillId)
	end)
	if not ok or typeof(result) ~= "table" then
		showToast("Unlock failed")
		return
	end
	if result.ok == true then
		stagesMap[skillId] = SkillStages.clampStage(result.stage)
		hideConfirm()
		refreshTemplate()
		if skillId == "PlotSize" then
			-- ForceClose always tears down skills + powerup; avoid close() while open
			-- so onClosed cannot race HUD restore mid-cinematic.
			playerGui:SetAttribute("OceanTD_ForceCloseSkills", os.clock())
			local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
			WaveEndVfx.syncToPlotSizeStage(stagesMap[skillId])
			local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
			if WaveSim.isRunning() then
				WaveSim.rebuildRouteForPlotSize(stagesMap[skillId])
			end
		end
		return
	end
	local code = result.errorCode
	if code == "CantAfford" then
		showToast("Collect More $D")
	elseif code == "Maxed" then
		showToast("Max Stage")
	else
		showToast("Can't unlock")
	end
	hideConfirm()
end

local function showConfirmUnlock()
	if not activeSkillId then
		return
	end
	local stage = currentStage(activeSkillId)
	local nextS = SkillStages.nextStage(stage)
	if not nextS then
		showToast("Max Stage")
		return
	end
	hideConfirm()
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_SkillUnlockConfirm"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 70
	sg.Parent = playerGui
	confirmGui = sg

	local dim = Instance.new("TextButton")
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.BackgroundColor3 = Color3.fromRGB(0, 8, 16)
	dim.BackgroundTransparency = 0.4
	dim.Size = UDim2.fromScale(1, 1)
	dim.Selectable = false
	dim.Parent = sg
	dim.Activated:Connect(hideConfirm)

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(320, 220)
	panel.BackgroundColor3 = PANEL_BG
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Selectable = false
	panel.Parent = sg
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 14)
	pc.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -24, 0, 56)
	title.Position = UDim2.fromOffset(12, 20)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 28
	title.TextColor3 = Color3.fromRGB(240, 248, 255)
	title.Text = "Stage " .. tostring(nextS) .. " Unlock"
	title.ZIndex = 3
	title.Parent = panel

	local unlock = Instance.new("TextButton")
	unlock.Name = "UNLOCK"
	unlock.Text = "UNLOCK"
	unlock.Font = Enum.Font.GothamBold
	unlock.TextSize = 20
	unlock.TextColor3 = Color3.new(1, 1, 1)
	unlock.BackgroundColor3 = GREEN
	unlock.BorderSizePixel = 0
	unlock.Size = UDim2.fromOffset(200, 48)
	unlock.AnchorPoint = Vector2.new(0.5, 0)
	unlock.Position = UDim2.new(0.5, 0, 0, 96)
	unlock.ZIndex = 3
	unlock.Parent = panel
	local uc = Instance.new("UICorner")
	uc.CornerRadius = UDim.new(0, 10)
	uc.Parent = unlock
	unlock.Activated:Connect(doUnlockRemote)

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
	cancel.Position = UDim2.new(0.5, 0, 0, 156)
	cancel.ZIndex = 3
	cancel.Parent = panel
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 10)
	cc.Parent = cancel
	cancel.Activated:Connect(hideConfirm)

	if isGamepadMode() then
		beginConfirmGamepadNav(unlock, cancel)
	end
end

function SkillPowerUpUI.getStage(skillId: string): number
	return currentStage(skillId)
end

function SkillPowerUpUI.requestUnlockNext()
	if not activeSkillId or not popupOpen then
		return
	end
	local stage = currentStage(activeSkillId)
	local nextS = SkillStages.nextStage(stage)
	if not nextS then
		showToast("Max Stage")
		return
	end
	showConfirmUnlock()
end

function SkillPowerUpUI.setOnClosed(cb: (() -> ())?)
	onClosedCb = cb
end

function SkillPowerUpUI.isConfirmOpen(): boolean
	return confirmGui ~= nil
end

function SkillPowerUpUI.cancelConfirm()
	if confirmGui then
		hideConfirm()
	end
end

function SkillPowerUpUI.syncCloseGlyph()
	syncCloseGlyph()
end

function SkillPowerUpUI.isOpen(): boolean
	return popupOpen
end

function SkillPowerUpUI.close()
	hideConfirm()
	popupOpen = false
	activeSkillId = nil
	stopUnlockDescPulse()
	SkillsBubbleSim.setSuppressed(false)
	playerGui:SetAttribute(POWERUP_OPEN_ATTR, false)
	endGamepadNav()
	stopCloseXOverlay()
	clearLockOverlays()
	if unlockDescLbl then
		unlockDescLbl.RichText = false
	end
	if template then
		template.Visible = false
	end
	if closeBtn and (not template or not closeBtn:IsDescendantOf(template)) then
		closeBtn.Visible = false
	end
	if onClosedCb then
		onClosedCb()
	end
end

function SkillPowerUpUI.open(skillId: string)
	if not template then
		warn("[SkillPowerUp] PowerUpTemplate missing")
		return
	end
	local def = SkillStages.get(skillId)
	if not def then
		warn("[SkillPowerUp] Unknown skill", skillId)
		return
	end
	local now = os.clock()
	if skillId == activeSkillId and popupOpen and (now - lastOpenAt) < 0.25 then
		return
	end
	lastOpenAt = now
	activeSkillId = skillId
	popupOpen = true
	SkillsBubbleSim.setSuppressed(true)
	playerGui:SetAttribute(POWERUP_OPEN_ATTR, true)
	template.Visible = true
	raiseTreeAboveBubbles(template)
	if closeBtn then
		closeBtn.Visible = true
		-- Must sit above PowerUpTemplate children or the white X never receives clicks.
		raiseInteractive(closeBtn, POWERUP_Z + 700)
		if closeBtn:IsA("GuiButton") then
			(closeBtn :: GuiButton).Active = true
		end
		if closeHitBtn then
			closeHitBtn.Active = true
			closeHitBtn.Visible = true
			closeHitBtn.ZIndex = POWERUP_Z + 710
		end
		ensureCloseXVisible()
	else
		warn("[SkillPowerUp] CloseBTN missing — add MobileSkillsA.dPad.CloseBTN")
	end
	if unlockBtn then
		unlockBtn.Active = true
		raiseInteractive(unlockBtn, POWERUP_Z + 650)
	end
	if lockedTemplate then
		lockedTemplate.Visible = false
	end
	refreshTemplate() -- also beginGamepadNav
	-- refreshTemplate can re-order stage chrome; keep interactives on top.
	if closeBtn then
		raiseInteractive(closeBtn, POWERUP_Z + 700)
		if closeHitBtn then
			closeHitBtn.ZIndex = POWERUP_Z + 710
		end
		ensureCloseXVisible()
	end
	if unlockBtn and unlockBtn.Visible then
		raiseInteractive(unlockBtn, POWERUP_Z + 650)
	end
end

function SkillPowerUpUI.openFromButtonName(buttonName: string)
	local def = SkillStages.fromButtonName(buttonName)
	if def then
		SkillPowerUpUI.open(def.id)
	else
		warn("[SkillPowerUp] No skill for button", buttonName)
	end
end

function SkillPowerUpUI.bind(mobileSkillsRoot: Instance)
	panelRoot = mobileSkillsRoot
	local sg: ScreenGui? = if mobileSkillsRoot:IsA("ScreenGui")
		then mobileSkillsRoot
		else mobileSkillsRoot:FindFirstAncestorOfClass("ScreenGui")
	hostScreenGui = sg
	if sg then
		sg.ZIndexBehavior = Enum.ZIndexBehavior.Global
	end
	dPad = mobileSkillsRoot:FindFirstChild("dPad") or mobileSkillsRoot:FindFirstChild("dPad", true)
	if not dPad then
		warn("[SkillPowerUp] MobileSkillsA.dPad missing")
		return
	end
	local tmpl = dPad:FindFirstChild("PowerUpTemplate")
		or mobileSkillsRoot:FindFirstChild("PowerUpTemplate", true)
	if not tmpl or not tmpl:IsA("GuiObject") then
		warn("[SkillPowerUp] PowerUpTemplate missing under dPad")
		return
	end
	template = tmpl
	template.Visible = false
	raiseTreeAboveBubbles(template)

	unlockNameLbl = findTextLabel(template, "UnlockName")
	nextStageLbl = findTextLabel(template, "NextStage")
	unlockDescLbl = findTextLabel(template, "UnlockDesc")
	unlockBtn = findGuiButton(template, "UNLOCKbtn")
	lockedTemplate = template:FindFirstChild("LOCKEDtemplate")
	if lockedTemplate and lockedTemplate:IsA("GuiObject") then
		lockedTemplate.Visible = false
	end

	table.clear(stageButtons)
	for i = 1, SkillStages.MAX_STAGE do
		local s = template:FindFirstChild("Stage" .. tostring(i))
		if s and s:IsA("GuiObject") then
			stageButtons[i] = s
			local leftoverNum = s:FindFirstChild("_OceanTD_StageNum")
			if leftoverNum then
				leftoverNum:Destroy()
			end
			if s:IsA("GuiButton") then
				s.Active = true
			end
		end
	end

	local close = dPad:FindFirstChild("CloseBTN")
		or template:FindFirstChild("CloseBTN")
		or mobileSkillsRoot:FindFirstChild("CloseBTN", true)
	if close and close:IsA("GuiObject") then
		closeBtn = close
		close.Visible = false
		raiseTreeAboveBubbles(close)
		local closeHit = if close:IsA("GuiButton") then close else close:FindFirstChildWhichIsA("GuiButton", true)
		if not closeHit then
			local b = Instance.new("TextButton")
			b.Name = "_OceanTD_CloseHit"
			b.Text = ""
			b.BackgroundTransparency = 1
			b.TextTransparency = 1
			b.Size = UDim2.fromScale(1, 1)
			b.ZIndex = close.ZIndex + 10
			b.Selectable = false
			b.Parent = close
			closeHit = b
		end
		closeHitBtn = closeHit :: GuiButton
		closeHitBtn.Selectable = false
		bindButtonPress(closeHitBtn, "_OceanTD_PowerUpCloseBound", onClosePressed)
		if closeBtn:IsA("GuiButton") and closeBtn ~= closeHitBtn then
			bindButtonPress(closeBtn :: GuiButton, "_OceanTD_PowerUpCloseBound", onClosePressed)
		end
	else
		warn("[SkillPowerUp] CloseBTN missing under MobileSkillsA.dPad")
	end

	if unlockBtn then
		unlockBtn.Selectable = false
	end
	if unlockBtn then
		bindButtonPress(unlockBtn, "_OceanTD_PowerUpUnlockBound", onUnlockPressed)
	end
	if unlockBtn then
		if unlockBtn:IsA("GuiObject") then
			(unlockBtn :: GuiObject).BackgroundColor3 = GREEN
		end
		if unlockBtn:IsA("TextButton") then
			(unlockBtn :: TextButton).TextColor3 = Color3.new(1, 1, 1)
		end
		local label = unlockBtn:FindFirstChildWhichIsA("TextLabel", true)
		if label then
			label.TextColor3 = Color3.new(1, 1, 1)
		end
	end
	bound = true

	task.spawn(function()
		local ok, payload = pcall(function()
			return getStagesRf:InvokeServer()
		end)
		if ok then
			applyStages(payload)
			if popupOpen then
				refreshTemplate()
			end
			local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
			WaveEndVfx.syncToPlotSizeStage(currentStage("PlotSize"))
		end
	end)
end

UserInputService.LastInputTypeChanged:Connect(function()
	if not popupOpen then
		return
	end
	syncCloseGlyph()
	if SkillPowerUpUI.isConfirmOpen() then
		return
	end
	if isGamepadMode() then
		beginGamepadNav()
	else
		endGamepadNav()
	end
end)

-- Keyboard: Enter = Unlock. X / B are owned by MobileSkillsA (power-up first, then bubbles).
-- Pointer fallback: ZIndex fights can swallow Activated — resolve by hit list.
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if not popupOpen then
		return
	end
	local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1
	local isTouch = input.UserInputType == Enum.UserInputType.Touch
	if isMouse or isTouch then
		local wx: number
		local wy: number
		if isMouse then
			local m = UserInputService:GetMouseLocation()
			local inset = GuiService:GetGuiInset()
			wx, wy = m.X - inset.X, m.Y - inset.Y
		else
			wx, wy = input.Position.X, input.Position.Y
		end
		local objs = playerGui:GetGuiObjectsAtPosition(wx, wy)
		for _, obj in ipairs(objs) do
			if closeBtn and (obj == closeBtn or obj:IsDescendantOf(closeBtn)) then
				onClosePressed()
				return
			end
			if
				unlockBtn
				and unlockBtn.Visible
				and unlockBtn.Active
				and (obj == unlockBtn or obj:IsDescendantOf(unlockBtn))
			then
				onUnlockPressed()
				return
			end
			-- First non-matching GUI under the cursor wins; don't dig through whole stack.
			if obj:IsA("GuiButton") then
				return
			end
		end
		return
	end
	if gameProcessed then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	local key = input.KeyCode
	if key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
		if confirmGui then
			doUnlockRemote()
		else
			SkillPowerUpUI.requestUnlockNext()
		end
	end
end)

syncRemote.OnClientEvent:Connect(function(payload)
	applyStages(payload)
	if popupOpen then
		refreshTemplate()
	end
	local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
	WaveEndVfx.syncToPlotSizeStage(currentStage("PlotSize"))
	local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
	if WaveSim.isRunning() then
		WaveSim.rebuildRouteForPlotSize(currentStage("PlotSize"))
	end
end)

return SkillPowerUpUI
