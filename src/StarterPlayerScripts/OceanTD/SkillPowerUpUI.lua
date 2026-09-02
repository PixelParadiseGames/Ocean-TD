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
local GREY_DARK = Color3.fromRGB(90, 90, 90)
local GREY_LIGHT = Color3.fromRGB(175, 175, 175)
local RED = Color3.fromRGB(220, 50, 55)
local PANEL_BG = Color3.fromRGB(12, 28, 36)
local POWERUP_Z = 500
local CLOSE_X_PULSE = TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local UNLOCK_STROKE_THICKNESS = 2

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local unlockedMap: { [string]: number } = SkillStages.defaultMap()
local activeMap: { [string]: number } = SkillStages.defaultMap()
local stageColorCache: { [GuiObject]: { [Instance]: Color3 } } = {}
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
local refreshTemplate: () -> ()
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
local unlockBtnPulseConn: RBXScriptConnection? = nil
local unlockBtnPulseToken = 0
local lastPowerUpClickAt = 0

local unlockRf = Remotes.getFunction("RequestUnlockSkillStage")
local getStagesRf = Remotes.getFunction("RequestGetSkillStages")
local setActiveRf = Remotes.getFunction("RequestSetSkillActiveStage")
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

local function stopUnlockBtnPulse()
	unlockBtnPulseToken += 1
	if unlockBtnPulseConn then
		unlockBtnPulseConn:Disconnect()
		unlockBtnPulseConn = nil
	end
end

local function applyUnlockStroke(btn: GuiObject)
	local stroke = btn:FindFirstChild("_OceanTD_UnlockStroke")
	if not (stroke and stroke:IsA("UIStroke")) then
		stroke = Instance.new("UIStroke")
		stroke.Name = "_OceanTD_UnlockStroke"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.LineJoinMode = Enum.LineJoinMode.Round
		stroke.Parent = btn
	end
	stroke.Thickness = UNLOCK_STROKE_THICKNESS
	stroke.Color = DESC_PULSE_GREEN
	stroke.Enabled = true
end

local function startUnlockBtnPulse()
	stopUnlockBtnPulse()
	if not unlockBtn then
		return
	end
	applyUnlockStroke(unlockBtn)
	local token = unlockBtnPulseToken
	unlockBtnPulseConn = RunService.Heartbeat:Connect(function()
		if token ~= unlockBtnPulseToken or not unlockBtn or not popupOpen then
			return
		end
		if not unlockBtn.Visible or not unlockBtn.Active then
			return
		end
		local u = (math.sin(os.clock() * math.pi * 1.35) + 1) * 0.5
		local c = GREEN:Lerp(DESC_PULSE_GREEN, u)
		if unlockBtn:IsA("GuiObject") then
			(unlockBtn :: GuiObject).BackgroundColor3 = c
		end
	end)
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
	-- Apply immediately so dial-down doesn't wait a frame (or stick on old copy).
	unlockDescLbl.Text = buildRichText(DESC_PULSE_GREEN)
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
	if typeof(raw) == "table" and typeof(raw.unlocked) == "table" then
		unlockedMap = SkillStages.sanitizeMap(raw.unlocked)
		activeMap = SkillStages.sanitizeActiveMap(raw.active, unlockedMap)
	elseif typeof(raw) == "table" and typeof(raw.active) == "table" then
		-- Alternate payload shape
		unlockedMap = SkillStages.sanitizeMap(raw.unlocked or raw)
		activeMap = SkillStages.sanitizeActiveMap(raw.active, unlockedMap)
	else
		-- Legacy flat map = both unlocked and active
		unlockedMap = SkillStages.sanitizeMap(raw)
		activeMap = SkillStages.sanitizeActiveMap(unlockedMap, unlockedMap)
	end
	if SkillsBubbleSim.isRunning() then
		SkillsBubbleSim.refreshStageLayouts()
	end
end

-- Gameplay / bubble size: currently enabled stage.
local function currentStage(skillId: string): number
	return SkillStages.clampStageFor(skillId, activeMap[skillId])
end

-- Purchase progress: highest unlocked stage.
local function unlockedStage(skillId: string): number
	return SkillStages.clampStageFor(skillId, unlockedMap[skillId])
end

local function isGreenish(c: Color3): boolean
	return c.G > c.R + 0.04 and c.G > c.B + 0.04 and c.G > 0.2
end

local function cacheStageColors(root: GuiObject)
	if stageColorCache[root] then
		return
	end
	local cache: { [Instance]: Color3 } = {}
	local function store(inst: Instance, color: Color3)
		cache[inst] = color
	end
	if root:IsA("GuiObject") and root.BackgroundTransparency < 0.99 then
		store(root, root.BackgroundColor3)
	end
	if root:IsA("ImageLabel") or root:IsA("ImageButton") then
		store(root, (root :: any).ImageColor3)
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("ImageLabel") or d:IsA("ImageButton") then
			store(d, d.ImageColor3)
		elseif d:IsA("GuiObject") and d.BackgroundTransparency < 0.99 then
			store(d, d.BackgroundColor3)
		elseif d:IsA("UIStroke") then
			store(d, d.Color)
		end
	end
	stageColorCache[root] = cache
end

-- mode: "on" = dark/bright green, "off" = dark/light grey (unlocked but disabled)
local function paintStageCheckmarks(root: GuiObject, mode: "on" | "off")
	cacheStageColors(root)
	local cache = stageColorCache[root]
	if not cache then
		return
	end
	for inst, orig in pairs(cache) do
		if not inst.Parent then
			continue
		end
		local useBright = false
		if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
			useBright = true
		elseif inst:IsA("UIStroke") then
			useBright = true
		elseif isGreenish(orig) and orig.G > 0.45 then
			useBright = true
		end
		local color: Color3
		if mode == "on" then
			color = if useBright then DESC_PULSE_GREEN else GREEN
			-- Prefer original green when restoring "on"
			if isGreenish(orig) then
				color = orig
			end
		else
			color = if useBright then GREY_LIGHT else GREY_DARK
		end
		if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
			(inst :: any).ImageColor3 = color
		elseif inst:IsA("UIStroke") then
			(inst :: UIStroke).Color = color
		elseif inst:IsA("GuiObject") then
			(inst :: GuiObject).BackgroundColor3 = color
		end
	end
end

local function applyGameplayForActiveStages()
	local ok, err = pcall(function()
		local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
		local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
		WaveEndVfx.syncToPlotSizeStage(currentStage("PlotSize"))
		WaveSim.applyReefHealthStage(currentStage("RHealth"))
		WaveSim.clampSpeedToMaxStep(SkillStages.waveSpeedMaxStep(currentStage("WaveSpeed")))
		if WaveSim.isRunning() then
			WaveSim.rebuildRouteForPlotSize(currentStage("PlotSize"))
		end
		if SkillsBubbleSim.isRunning() then
			SkillsBubbleSim.refreshStageLayouts()
		end
	end)
	if not ok then
		warn("[SkillPowerUp] applyGameplayForActiveStages failed:", err)
	end
end

local function requestSetActiveStage(skillId: string, stage: number)
	local prevPlotSize = if skillId == "PlotSize" then currentStage("PlotSize") else nil
	if skillId == "PlotSize" and stage ~= prevPlotSize then
		local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
		WaveEndVfx.setRouteHeartDriveLocked(true)
		local park = WaveEndVfx.getRouteEndWorldPosForStage(prevPlotSize :: number)
		if park then
			WaveEndVfx.setRouteEndWorldPos(park)
		end
	end
	local ok, result = pcall(function()
		return setActiveRf:InvokeServer(skillId, stage)
	end)
	if not ok or typeof(result) ~= "table" or result.ok ~= true then
		if skillId == "PlotSize" and stage ~= prevPlotSize then
			local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
			WaveEndVfx.setRouteHeartDriveLocked(false)
		end
		return false
	end
	if typeof(result.active) == "number" then
		activeMap[skillId] = SkillStages.clampStageFor(skillId, result.active)
	else
		activeMap[skillId] = SkillStages.clampStageFor(skillId, stage)
	end
	if typeof(result.unlocked) == "number" then
		unlockedMap[skillId] = SkillStages.clampStageFor(skillId, result.unlocked)
	end
	if skillId == "PlotSize" and prevPlotSize and currentStage("PlotSize") ~= prevPlotSize then
		if popupOpen then
			refreshTemplate()
		end
		if SkillsBubbleSim.isRunning() then
			SkillsBubbleSim.refreshStageLayouts()
		end
		return true
	end
	applyGameplayForActiveStages()
	if popupOpen then
		refreshTemplate()
	end
	return true
end

local function findTextLabel(host: Instance, name: string): TextLabel?
	local n = host:FindFirstChild(name, true)
	if n and n:IsA("TextLabel") then
		return n
	end
	return nil
end

-- Studio sometimes renames the blurb under the title; keep dial-down text working.
local function findUnlockDescLabel(host: Instance): TextLabel?
	local aliases = { "UnlockDesc", "UnlockDescription", "Desc", "Description", "SkillDesc", "PowerUpDesc" }
	for _, name in ipairs(aliases) do
		local found = findTextLabel(host, name)
		if found then
			return found
		end
	end
	local nameLbl = findTextLabel(host, "UnlockName")
	if nameLbl and nameLbl.Parent then
		for _, ch in ipairs(nameLbl.Parent:GetChildren()) do
			if ch:IsA("TextLabel") and ch ~= nameLbl then
				local lower = string.lower(ch.Name)
				if ch.Name ~= "NextStage" and (string.find(lower, "desc", 1, true) or string.find(lower, "info", 1, true)) then
					return ch
				end
			end
		end
		for _, ch in ipairs(nameLbl.Parent:GetChildren()) do
			if ch:IsA("TextLabel") and ch ~= nameLbl and ch.Name ~= "NextStage" then
				return ch
			end
		end
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

refreshTemplate = function()
	if not template or not activeSkillId then
		return
	end
	local def = SkillStages.get(activeSkillId)
	if not def then
		return
	end
	local active = currentStage(activeSkillId)
	local unlocked = unlockedStage(activeSkillId)
	if unlockNameLbl then
		unlockNameLbl.Text = def.displayName
	end
	local nextS = SkillStages.nextStageFor(activeSkillId, unlocked)
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
		-- Climbing unlocks (active at unlocked tip): preview the next purchase.
		-- Maxed or dialed down: show what the *active* stage currently gives.
		local showActiveStatus = nextS == nil or active < unlocked

		if showActiveStatus then
			-- Always driven by `active`, never unlocked max.
			if activeSkillId == "PlaceMore" then
				local newMax = SkillStages.placeMoreMaxAtStage(active)
				startUnlockDescPulse("PlaceMore", function(c: Color3)
					return string.format('Max: <font color="%s">%d</font>', rgbFontTag(c), newMax)
				end)
			elseif activeSkillId == "EarnMore" then
				local mult = SkillStages.clampStage(active)
				if mult <= 1 then
					stopUnlockDescPulse()
					unlockDescLbl.RichText = false
					unlockDescLbl.Text = SkillStages.activeStatusDesc(activeSkillId, active)
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
			elseif activeSkillId == "RHealth" then
				local newMax = SkillStages.reefHealthAtStage(active)
				startUnlockDescPulse("RHealth", function(c: Color3)
					return string.format('Max: <font color="%s">%d</font>', rgbFontTag(c), newMax)
				end)
			elseif activeSkillId == "Skip" then
				if SkillStages.isSkipUnlimited(active) then
					startUnlockDescPulse("Skip", function(c: Color3)
						return string.format('<font color="%s">Unlimited Skips</font>', rgbFontTag(c))
					end)
				else
					local uses = SkillStages.skipUsesAtStage(active)
					if uses <= 0 then
						stopUnlockDescPulse()
						unlockDescLbl.RichText = false
						unlockDescLbl.Text = "0 Skips"
						unlockDescLbl.Visible = true
					elseif uses == 1 then
						startUnlockDescPulse("Skip", function(c: Color3)
							return string.format('<font color="%s">1 Skip</font>', rgbFontTag(c))
						end)
					else
						startUnlockDescPulse("Skip", function(c: Color3)
							return string.format('<font color="%s">%d Skips</font>', rgbFontTag(c), uses)
						end)
					end
				end
			elseif activeSkillId == "WaveSpeed" then
				if SkillStages.waveSpeedPauseUnlocked(active) then
					startUnlockDescPulse("WaveSpeed", function(c: Color3)
						return string.format('<font color="%s">All speeds + pause</font>', rgbFontTag(c))
					end)
				elseif active >= 3 then
					startUnlockDescPulse("WaveSpeed", function(c: Color3)
						return string.format('<font color="%s">2x</font> wave speed', rgbFontTag(c))
					end)
				elseif active >= 2 then
					startUnlockDescPulse("WaveSpeed", function(c: Color3)
						return string.format('<font color="%s">1.5x</font> wave speed', rgbFontTag(c))
					end)
				else
					stopUnlockDescPulse()
					unlockDescLbl.RichText = false
					unlockDescLbl.Text = "Normal wave speed"
					unlockDescLbl.Visible = true
				end
			else
				stopUnlockDescPulse()
				unlockDescLbl.RichText = false
				unlockDescLbl.Text = SkillStages.activeStatusDesc(activeSkillId, active)
				unlockDescLbl.Visible = true
			end
		else
			-- Still climbing: preview the next unlock purchase.
			local descStage = nextS :: number
			if activeSkillId == "PlaceMore" then
				local newMax = SkillStages.placeMoreMaxAtStage(descStage)
				local inc = SkillStages.placeMoreIncrementAtStage(descStage)
				startUnlockDescPulse("PlaceMore", function(c: Color3)
					return string.format(
						'<font color="%s">+%d</font>  New Max: %d',
						rgbFontTag(c),
						inc,
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
			elseif activeSkillId == "RHealth" then
				local newMax = SkillStages.reefHealthAtStage(descStage)
				local inc = SkillStages.reefHealthIncrementAtStage(descStage)
				startUnlockDescPulse("RHealth", function(c: Color3)
					return string.format(
						'<font color="%s">+%d</font>  New Max: %d',
						rgbFontTag(c),
						inc,
						newMax
					)
				end)
			elseif activeSkillId == "Skip" then
				local uses = SkillStages.skipUsesAtStage(descStage)
				if uses <= 0 then
					stopUnlockDescPulse()
					unlockDescLbl.RichText = false
					unlockDescLbl.Text = SkillStages.unlockDesc(activeSkillId, descStage)
					unlockDescLbl.Visible = true
				else
					local inc = SkillStages.skipUsesIncrementAtStage(descStage)
					startUnlockDescPulse("Skip", function(c: Color3)
						return string.format(
							'<font color="%s">+%d</font>  New Max: %d per session',
							rgbFontTag(c),
							inc,
							uses
						)
					end)
				end
			elseif activeSkillId == "WaveSpeed" then
				if descStage == 2 then
					startUnlockDescPulse("WaveSpeed", function(c: Color3)
						return string.format('Unlock <font color="%s">1.5x</font> wave speed', rgbFontTag(c))
					end)
				elseif descStage == 3 then
					startUnlockDescPulse("WaveSpeed", function(c: Color3)
						return string.format('Unlock <font color="%s">2x</font> wave speed', rgbFontTag(c))
					end)
				else
					startUnlockDescPulse("WaveSpeed", function(c: Color3)
						return string.format('Unlock wave <font color="%s">pause</font>', rgbFontTag(c))
					end)
				end
			else
				stopUnlockDescPulse()
				unlockDescLbl.RichText = false
				unlockDescLbl.Text = SkillStages.unlockDesc(activeSkillId, descStage)
				unlockDescLbl.Visible = true
			end
		end
	end
	if unlockBtn then
		unlockBtn.Visible = nextS ~= nil
		unlockBtn.Active = nextS ~= nil
		if nextS ~= nil then
			raiseInteractive(unlockBtn, POWERUP_Z + 650)
			startUnlockBtnPulse()
		else
			stopUnlockBtnPulse()
		end
		if unlockBtn:IsA("TextButton") or unlockBtn:IsA("ImageButton") then
			if nextS == nil then
				(unlockBtn :: any).BackgroundColor3 = GREEN
			end
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
	local maxS = SkillStages.maxStageFor(activeSkillId)
	for i = 1, SkillStages.MAX_STAGE do
		local sb = stageButtons[i]
		if not sb then
			continue
		end
		if i > maxS then
			sb.Visible = false
			continue
		end
		sb.Visible = true
		local leftoverNum = sb:FindFirstChild("_OceanTD_StageNum")
		if leftoverNum then
			leftoverNum:Destroy()
		end
		if i > unlocked then
			placeLockOn(sb)
		elseif i <= active then
			-- Enabled: dark / bright green checkmarks
			paintStageCheckmarks(sb, "on")
		else
			-- Unlocked but dialed off: dark / light grey checkmarks
			paintStageCheckmarks(sb, "off")
		end
	end
	-- Locks / stage chrome can cover UNLOCK — keep interactives above.
	if closeBtn and popupOpen then
		raiseInteractive(closeBtn, POWERUP_Z + 700)
		if closeHitBtn then
			closeHitBtn.ZIndex = POWERUP_Z + 710
		end
		-- raiseInteractive flattens child ZIndex; put the white X back on top.
		ensureCloseXVisible()
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
		if skillId == "PlotSize" then
			-- Lock before SkillStagesSync arrives (fires before PlotSizeChanged) so the heart
			-- stays at the old route end until PlotSizeCinematic tweens it.
			local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
			local prevStage = SkillStages.clampStage(result.prevStage or (result.stage - 1))
			WaveEndVfx.setRouteHeartDriveLocked(true)
			local park = WaveEndVfx.getRouteEndWorldPosForStage(prevStage)
			if park then
				WaveEndVfx.setRouteEndWorldPos(park)
			end
		end
		local newStage = SkillStages.clampStageFor(skillId, result.stage)
		unlockedMap[skillId] = newStage
		activeMap[skillId] = newStage
		hideConfirm()
		refreshTemplate()
		if skillId == "RHealth" then
			local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
			WaveSim.applyReefHealthStage(newStage)
		end
		if skillId == "WaveSpeed" then
			local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
			WaveSim.clampSpeedToMaxStep(SkillStages.waveSpeedMaxStep(newStage))
		end
		if skillId == "PlotSize" then
			-- ForceClose always tears down skills + powerup; avoid close() while open
			-- so onClosed cannot race HUD restore mid-cinematic.
			playerGui:SetAttribute("OceanTD_ForceCloseSkills", os.clock())
		else
			SkillsBubbleSim.refreshStageLayouts()
		end
		return
	end
	local code = result.errorCode
	if code == "CantAfford" then
		showToast("Collect More $D")
	elseif code == "Maxed" then
		showToast("Max Stage")
	elseif code == "PlotSizeGate" then
		showToast("Unlock Plot Size Stage 2 first")
	elseif code == "PlaceMoreGate" then
		showToast("Unlock Place More Stage 2 first")
	else
		showToast("Can't unlock")
	end
	hideConfirm()
end

local function showConfirmUnlock()
	if not activeSkillId then
		return
	end
	local stage = unlockedStage(activeSkillId)
	local nextS = SkillStages.nextStageFor(activeSkillId, stage)
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
	applyUnlockStroke(unlock)
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
	else
		-- Keyboard tips: Enter = unlock, Backspace = cancel.
		local tipT0 = os.clock()
		local tipConn: RBXScriptConnection? = nil
		tipConn = RunService.Heartbeat:Connect(function()
			if not confirmGui or confirmGui ~= sg then
				if tipConn then
					tipConn:Disconnect()
				end
				return
			end
			local showTip = (math.floor((os.clock() - tipT0) / 1) % 2) == 1
			unlock.Text = if showTip then "Enter" else "UNLOCK"
			cancel.Text = if showTip then "Backspace" else "CANCEL"
		end)
	end
end

function SkillPowerUpUI.getStage(skillId: string): number
	return currentStage(skillId)
end

function SkillPowerUpUI.getUnlockedStage(skillId: string): number
	return unlockedStage(skillId)
end

function SkillPowerUpUI.requestUnlockNext()
	if not activeSkillId or not popupOpen then
		return
	end
	local stage = unlockedStage(activeSkillId)
	local nextS = SkillStages.nextStageFor(activeSkillId, stage)
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
	stopUnlockBtnPulse()
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
	if SkillStages.isSkillLocked(skillId, unlockedMap) then
		SkillsBubbleSim.playLockedRejectFx(skillId)
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
	unlockDescLbl = findUnlockDescLabel(template)
	if not unlockDescLbl then
		warn("[SkillPowerUp] UnlockDesc TextLabel missing under PowerUpTemplate — stage dial text won't update")
	end
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
			local stageIndex = i
			local function onStagePressed()
				if not popupOpen or not activeSkillId or not powerUpClickGuard() then
					return
				end
				if confirmGui then
					return
				end
				local unlocked = unlockedStage(activeSkillId)
				if stageIndex > unlocked then
					SkillPowerUpUI.requestUnlockNext()
					return
				end
				if stageIndex == currentStage(activeSkillId) then
					return
				end
				requestSetActiveStage(activeSkillId, stageIndex)
			end
			local hit: GuiButton? = if s:IsA("GuiButton") then s :: GuiButton else s:FindFirstChildWhichIsA("GuiButton", true)
			if not hit then
				local b = Instance.new("TextButton")
				b.Name = "_OceanTD_StageHit"
				b.Text = ""
				b.BackgroundTransparency = 1
				b.TextTransparency = 1
				b.Size = UDim2.fromScale(1, 1)
				b.ZIndex = s.ZIndex + 10
				b.Selectable = false
				b.Parent = s
				hit = b
			end
			hit.Active = true
			hit.Selectable = false
			bindButtonPress(hit, "_OceanTD_StageBound", onStagePressed)
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
			applyUnlockStroke(unlockBtn)
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

-- Keyboard: Enter = Unlock, Backspace = Cancel (confirm). X / B owned by MobileSkillsA.
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
			if activeSkillId and not confirmGui then
				for stageIndex, sb in ipairs(stageButtons) do
					if sb.Visible and (obj == sb or obj:IsDescendantOf(sb)) then
						local unlocked = unlockedStage(activeSkillId)
						if stageIndex > unlocked then
							SkillPowerUpUI.requestUnlockNext()
						elseif stageIndex ~= currentStage(activeSkillId) then
							if powerUpClickGuard() then
								requestSetActiveStage(activeSkillId, stageIndex)
							end
						end
						return
					end
				end
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
		return
	end
	if key == Enum.KeyCode.Backspace then
		if confirmGui then
			hideConfirm()
		end
		return
	end
end)

syncRemote.OnClientEvent:Connect(function(payload)
	applyStages(payload)
	if popupOpen then
		refreshTemplate()
	end
	local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
	-- Plot Size cinematic owns heart + live route until the grow tween finishes.
	if WaveEndVfx.isRouteHeartDriveLocked() then
		return
	end
	local PlotSizeCinematic = require(script.Parent:WaitForChild("PlotSizeCinematic"))
	if PlotSizeCinematic.isBusy() then
		return
	end
	WaveEndVfx.syncToPlotSizeStage(currentStage("PlotSize"))
	local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
	WaveSim.applyReefHealthStage(currentStage("RHealth"))
	WaveSim.clampSpeedToMaxStep(SkillStages.waveSpeedMaxStep(currentStage("WaveSpeed")))
	if WaveSim.isRunning() then
		WaveSim.rebuildRouteForPlotSize(currentStage("PlotSize"))
	end
end)

return SkillPowerUpUI
