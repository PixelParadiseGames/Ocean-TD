--!strict
--[[
	Power-up stage popup for MobileSkillsA skill bubbles.
	Rebinds Studio PowerUpTemplate (show/hide); bubbles hide while this is open.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local SkillsBubbleSim = require(script.Parent:WaitForChild("SkillsBubbleSim"))

local SkillPowerUpUI = {}

local POWERUP_OPEN_ATTR = "OceanTD_SkillPowerUpOpen"
local UI_FONT = UiTheme.Font

local GREEN = Color3.fromRGB(40, 170, 70)
local GREEN_DARK = Color3.fromRGB(18, 110, 45)
local GREEN_BRIGHT = Color3.fromRGB(70, 255, 110)
local DESC_PULSE_GREEN = Color3.fromRGB(70, 255, 110)
local DESC_PULSE_WHITE = Color3.new(1, 1, 1)
local COST_GREEN = Color3.fromRGB(40, 255, 90) -- same as coral upgrade confirm
local GREY_DARK = Color3.fromRGB(110, 110, 110)
local GREY_LIGHT = Color3.fromRGB(175, 175, 175)
local GREY_DARKER = Color3.fromRGB(70, 70, 70)
local RED = Color3.fromRGB(220, 50, 55)
local BRIGHT_RED = Color3.fromRGB(255, 45, 50)
local BRIGHT_GREEN_RING = Color3.fromRGB(40, 255, 90)
local WHITE = Color3.new(1, 1, 1)
local PANEL_BG = Color3.fromRGB(12, 28, 36)
local RHEALTH_LAYOUT_VER = 6
local RHEALTH_STAGE_TEXT_SIZE = 22 -- +3 vs prior ~19 scaled
local RHEALTH_STAT_TEXT_SIZE = 15 -- Max N (+2 from prior 13)
local RHEALTH_CLOSE_SCALE = 0.7 -- 30% smaller than default CloseBTN
local POWERUP_Z = 500
local ACTIVE_STAGE_SCALE = 1.2
local CLOSE_X_PULSE = TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local UNLOCK_STROKE_THICKNESS = 2
local UNLOCK_SOUND_ID = "rbxassetid://134583420216867"

local unlockSound = Instance.new("Sound")
unlockSound.Name = "OceanTD_SkillUnlock"
unlockSound.SoundId = UNLOCK_SOUND_ID
unlockSound.Volume = 1
unlockSound.Parent = SoundService

local function playUnlockSound()
	local s = unlockSound:Clone()
	s.Parent = SoundService
	s:Play()
	s.Ended:Connect(function()
		s:Destroy()
	end)
	task.delay(4, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

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
local unlockNameBaseTextSize: number? = nil
local unlockNameBaseTextScaled: boolean? = nil
local unlockNameBaseMaxTextSize: number? = nil
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
local nextUnlockPulseConn: RBXScriptConnection? = nil
local nextUnlockPulseToken = 0
local lastPowerUpClickAt = 0

-- Reef Health: horizontal 8-stage layout (replaces Studio ring chrome for this skill only).
local RHEALTH_SUBHEAD = "Raise the reef's maximum health"
local rHealthLayout: Frame? = nil
local rHealthUnlockBtn: TextButton? = nil
local closeLayoutSaved: {
	parent: Instance?,
	pos: UDim2,
	size: UDim2,
	anchor: Vector2,
	absX: number,
	absY: number,
}? = nil
type RHealthCol = {
	root: Frame,
	bubble: TextButton,
	check: TextLabel,
	stageLbl: TextLabel,
	statLbl: TextLabel,
	unlockSlot: Frame,
}
local rHealthCols: { RHealthCol } = {}

local unlockRf = Remotes.getFunction("RequestUnlockSkillStage")
local getStagesRf = Remotes.getFunction("RequestGetSkillStages")
local setActiveRf = Remotes.getFunction("RequestSetSkillActiveStage")
local syncRemote = Remotes.get("SkillStagesSync")

local function navUnlockBtn(): GuiButton?
	if activeSkillId == "RHealth" and rHealthUnlockBtn and rHealthUnlockBtn.Visible then
		return rHealthUnlockBtn
	end
	if unlockBtn and unlockBtn.Visible then
		return unlockBtn
	end
	return nil
end

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
	local btn = navUnlockBtn()
	if not btn then
		return
	end
	applyUnlockStroke(btn)
	local token = unlockBtnPulseToken
	unlockBtnPulseConn = RunService.Heartbeat:Connect(function()
		local live = navUnlockBtn()
		if token ~= unlockBtnPulseToken or not live or not popupOpen then
			return
		end
		if not live.Visible or not live.Active then
			return
		end
		local u = (math.sin(os.clock() * math.pi * 1.35) + 1) * 0.5
		local c = GREEN:Lerp(DESC_PULSE_GREEN, u)
		if live:IsA("GuiObject") then
			(live :: GuiObject).BackgroundColor3 = c
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
	local navUnlock = navUnlockBtn()
	if navUnlock then
		clearNextSelection(navUnlock)
		navUnlock.Selectable = false
	end
	if unlockBtn then
		clearNextSelection(unlockBtn)
		unlockBtn.Selectable = false
	end
	if rHealthUnlockBtn then
		clearNextSelection(rHealthUnlockBtn)
		rHealthUnlockBtn.Selectable = false
	end
	if closeHitBtn then
		clearNextSelection(closeHitBtn)
		closeHitBtn.Selectable = false
	end
end

local function beginGamepadNav()
	table.clear(selectableRestore)
	local navUnlock = navUnlockBtn()
	if unlockBtn then
		clearNextSelection(unlockBtn)
	end
	if rHealthUnlockBtn then
		clearNextSelection(rHealthUnlockBtn)
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
				if obj ~= navUnlock and obj ~= closeHitBtn then
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

	local unlockOk = navUnlock ~= nil and navUnlock.Visible and navUnlock.Active
	local closeOk = closeHitBtn ~= nil and closeBtn ~= nil and closeBtn.Visible
	if closeOk and closeHitBtn then
		closeHitBtn.Selectable = true
		closeHitBtn.Active = true
	elseif closeHitBtn then
		closeHitBtn.Selectable = false
	end
	if unlockOk and navUnlock then
		navUnlock.Selectable = true
		if closeOk and closeHitBtn then
			linkTwoWay(navUnlock, closeHitBtn)
		else
			clearNextSelection(navUnlock)
		end
		GuiService.SelectedObject = navUnlock
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
	-- Key = instance; value = ImageColor3 for images, else Background/Stroke color.
	-- ImageButtons also store background via a parallel attribute on a sidecar key.
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

-- mode: "active" = white checkmark on green fill; "idle" = grey fill (unlocked, not active)
local function paintStageCheckmarks(root: GuiObject, mode: "active" | "idle")
	cacheStageColors(root)
	-- ImageButtons often keep a green BackgroundColor3 separate from ImageColor3 — force both.
	local function forceFill(gui: GuiObject)
		if gui.BackgroundTransparency < 0.99 then
			gui.BackgroundColor3 = if mode == "active" then GREEN else GREY_DARK
		end
		if gui:IsA("ImageLabel") or gui:IsA("ImageButton") then
			(gui :: any).ImageColor3 = if mode == "active" then WHITE else GREY_LIGHT
		end
	end
	forceFill(root)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("GuiObject") then
			forceFill(d)
		end
		if d:IsA("UIStroke") then
			d.Color = if mode == "active" then WHITE else GREY_LIGHT
		end
	end
end

local function ensureStageScale(sb: GuiObject): UIScale
	local existing = sb:FindFirstChild("_OceanTD_StageScale")
	if existing and existing:IsA("UIScale") then
		return existing
	end
	local scale = Instance.new("UIScale")
	scale.Name = "_OceanTD_StageScale"
	scale.Scale = 1
	scale.Parent = sb
	return scale
end

local function stopNextUnlockPulse()
	nextUnlockPulseToken += 1
	if nextUnlockPulseConn then
		nextUnlockPulseConn:Disconnect()
		nextUnlockPulseConn = nil
	end
end

local function startNextUnlockPulse(stroke: UIStroke, fromColor: Color3?, toColor: Color3?)
	stopNextUnlockPulse()
	local a = fromColor or BRIGHT_RED
	local b = toColor or BRIGHT_GREEN_RING
	local token = nextUnlockPulseToken
	nextUnlockPulseConn = RunService.Heartbeat:Connect(function()
		if token ~= nextUnlockPulseToken or not stroke.Parent then
			if token == nextUnlockPulseToken then
				stopNextUnlockPulse()
			end
			return
		end
		local u = (math.sin(os.clock() * math.pi * 1.35) + 1) * 0.5
		stroke.Color = a:Lerp(b, u)
	end)
end

local function applyGameplayForActiveStages()
	local ok, err = pcall(function()
		local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
		local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
		local introBusy = playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true
		if not introBusy then
			WaveEndVfx.syncToPlotSizeStage(currentStage("PlotSize"))
		end
		WaveSim.applyReefHealthStage(currentStage("RHealth"))
		WaveSim.clampSpeedToMaxStep(SkillStages.waveSpeedMaxStep(currentStage("WaveSpeed")))
		if WaveSim.isRunning() and not introBusy and not WaveSim.isJoinIntroDemo() then
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
	stopNextUnlockPulse()
	for _, o in ipairs(lockOverlays) do
		o:Destroy()
	end
	table.clear(lockOverlays)
	for _, sb in ipairs(stageButtons) do
		local stroke = sb:FindFirstChild("_OceanTD_NextUnlockStroke")
		if stroke then
			stroke:Destroy()
		end
		local num = sb:FindFirstChild("_OceanTD_StageNum")
		if num then
			num:Destroy()
		end
	end
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

local function bindLockHit(host: Instance)
	local hit: GuiButton? = if host:IsA("GuiButton") then host :: GuiButton else host:FindFirstChildWhichIsA("GuiButton", true)
	if hit then
		hit.Active = true
		hit.Activated:Connect(function()
			SkillPowerUpUI.requestUnlockNext()
		end)
		return
	end
	local b = Instance.new("TextButton")
	b.Name = "_OceanTD_LockHit"
	b.Text = ""
	b.BackgroundTransparency = 1
	b.Size = UDim2.fromScale(1, 1)
	b.ZIndex = if host:IsA("GuiObject") then (host :: GuiObject).ZIndex + 1 else 10
	b.Parent = host
	b.Activated:Connect(function()
		SkillPowerUpUI.requestUnlockNext()
	end)
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
	bindLockHit(clone)
end

local LOCK_NUM_SWAP_SEC = 0.85

type NextUnlockOpts = {
	lockOnly: boolean?,
	noRing: boolean?,
	strokeFrom: Color3?,
	strokeTo: Color3?,
}

-- Next purchasable stage: red LOCKEDtemplate circle; optional lock↔number swap; pulsing ring.
local function placeNextUnlockOn(stageBtn: GuiObject, stageNum: number, opts: NextUnlockOpts?)
	if not lockedTemplate then
		return
	end
	local lockOnly = opts ~= nil and opts.lockOnly == true
	local noRing = opts ~= nil and opts.noRing == true
	local strokeFrom = if opts then opts.strokeFrom else nil
	local strokeTo = if opts then opts.strokeTo else nil

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
	bindLockHit(clone)

	local oldStroke = clone:FindFirstChild("_OceanTD_NextUnlockStroke")
	if oldStroke then
		oldStroke:Destroy()
	end
	if not noRing then
		-- Prefer stroke on the stage bubble so the pulse rings the full circle.
		local strokeHost: GuiObject = if stageBtn:IsA("GuiObject") then stageBtn else clone :: GuiObject
		local hostOld = strokeHost:FindFirstChild("_OceanTD_NextUnlockStroke")
		if hostOld then
			hostOld:Destroy()
		end
		local stroke = Instance.new("UIStroke")
		stroke.Name = "_OceanTD_NextUnlockStroke"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.LineJoinMode = Enum.LineJoinMode.Round
		stroke.Thickness = 4
		stroke.Color = strokeFrom or BRIGHT_RED
		stroke.Enabled = true
		stroke.Parent = strokeHost
		startNextUnlockPulse(stroke, strokeFrom, strokeTo)
	end

	-- Toggle only lock glyph images (descendants). Keep the red circle fill visible.
	local lockIcons: { GuiObject } = {}
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("ImageLabel") or d:IsA("ImageButton") then
			table.insert(lockIcons, d)
		end
	end
	local rootIsLockImage = (#lockIcons == 0)
		and (clone:IsA("ImageLabel") or clone:IsA("ImageButton"))
	if rootIsLockImage and clone:IsA("GuiObject") then
		-- Root art is the lock glyph — keep a red disc when the image hides.
		clone.BackgroundColor3 = BRIGHT_RED
		if clone.BackgroundTransparency > 0.5 then
			clone.BackgroundTransparency = 0.15
		end
	end

	if lockOnly then
		return
	end

	local num = Instance.new("TextLabel")
	num.Name = "_OceanTD_StageNum"
	num.BackgroundTransparency = 1
	num.AnchorPoint = Vector2.new(0.5, 0.5)
	num.Position = UDim2.fromScale(0.5, 0.5)
	num.Size = UDim2.fromScale(0.72, 0.72)
	num.Font = UI_FONT
	num.TextScaled = true
	num.TextColor3 = WHITE
	num.TextStrokeTransparency = 0.55
	num.TextStrokeColor3 = Color3.new(0, 0, 0)
	num.Text = tostring(stageNum)
	num.ZIndex = (if clone:IsA("GuiObject") then (clone :: GuiObject).ZIndex else stageBtn.ZIndex) + 3
	num.Active = false
	num.Visible = false
	num.Parent = clone

	local token = nextUnlockPulseToken
	task.spawn(function()
		local showNum = false
		while token == nextUnlockPulseToken and clone.Parent do
			showNum = not showNum
			num.Visible = showNum
			num.TextTransparency = if showNum then 0 else 1
			for _, icon in ipairs(lockIcons) do
				if icon.Parent and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
					(icon :: any).ImageTransparency = if showNum then 1 else 0
				end
			end
			if rootIsLockImage and clone.Parent and (clone:IsA("ImageLabel") or clone:IsA("ImageButton")) then
				(clone :: any).ImageTransparency = if showNum then 1 else 0
			end
			task.wait(LOCK_NUM_SWAP_SEC)
		end
	end)
end

local function setStudioRingChromeVisible(visible: boolean)
	-- For Reef Health, hide the Studio ring pack entirely (keep CloseBTN / our layout).
	if template then
		for _, ch in ipairs(template:GetChildren()) do
			if ch.Name == "_OceanTD_RHealthLayout" or ch.Name == "LOCKEDtemplate" or ch.Name == "CloseBTN" then
				continue
			end
			if not ch:IsA("GuiObject") then
				continue
			end
			if not visible then
				if ch:GetAttribute("_OceanTD_RHealthHide") == nil then
					ch:SetAttribute("_OceanTD_RHealthHide", ch.Visible)
				end
				ch.Visible = false
			else
				local was = ch:GetAttribute("_OceanTD_RHealthHide")
				if typeof(was) == "boolean" then
					ch.Visible = was
					ch:SetAttribute("_OceanTD_RHealthHide", nil)
				end
			end
		end
	end
	for _, sb in ipairs(stageButtons) do
		if visible then
			local was = sb:GetAttribute("_OceanTD_RHealthHide")
			if typeof(was) == "boolean" then
				sb.Visible = was
				sb:SetAttribute("_OceanTD_RHealthHide", nil)
			else
				sb.Visible = true
			end
		else
			sb.Visible = false
		end
	end
	if unlockNameLbl then
		unlockNameLbl.Visible = visible
	end
	if nextStageLbl then
		nextStageLbl.Visible = visible
	end
	if unlockDescLbl then
		unlockDescLbl.Visible = visible
	end
	if unlockBtn then
		unlockBtn.Visible = visible
		unlockBtn.Active = visible
	end
end

local function restoreCloseLayoutFromRHealth()
	if not closeBtn or not closeLayoutSaved then
		return
	end
	if closeLayoutSaved.parent then
		closeBtn.Parent = closeLayoutSaved.parent
	end
	closeBtn.AnchorPoint = closeLayoutSaved.anchor
	closeBtn.Position = closeLayoutSaved.pos
	closeBtn.Size = closeLayoutSaved.size
	closeLayoutSaved = nil
end

local function applyRHealthCloseLayout()
	if not closeBtn or not hostScreenGui then
		return
	end
	if not closeLayoutSaved then
		-- Capture pixel size while still under the Studio parent (before reparent).
		closeLayoutSaved = {
			parent = closeBtn.Parent,
			pos = closeBtn.Position,
			size = closeBtn.Size,
			anchor = closeBtn.AnchorPoint,
			absX = math.max(1, closeBtn.AbsoluteSize.X),
			absY = math.max(1, closeBtn.AbsoluteSize.Y),
		}
	end
	-- Top-right of the full screen, 30% smaller (offset size so ScreenGui scale doesn't inflate it).
	local w = math.max(24, closeLayoutSaved.absX * RHEALTH_CLOSE_SCALE)
	local h = math.max(24, closeLayoutSaved.absY * RHEALTH_CLOSE_SCALE)
	closeBtn.Parent = hostScreenGui
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -12, 0, 12)
	closeBtn.Size = UDim2.fromOffset(w, h)
	closeBtn.Visible = true
	raiseInteractive(closeBtn, POWERUP_Z + 700)
	if closeHitBtn then
		closeHitBtn.Active = true
		closeHitBtn.Visible = true
		closeHitBtn.ZIndex = POWERUP_Z + 710
	end
	ensureCloseXVisible()
end

local function hideRHealthLayout()
	if rHealthLayout then
		rHealthLayout.Visible = false
	end
	if rHealthUnlockBtn then
		rHealthUnlockBtn.Visible = false
		rHealthUnlockBtn.Active = false
	end
	restoreCloseLayoutFromRHealth()
end

local function setRHealthBubbleGradient(bubble: GuiObject, dark: Color3, bright: Color3)
	bubble.BackgroundColor3 = WHITE
	local grad = bubble:FindFirstChild("_OceanTD_FillGrad")
	if not (grad and grad:IsA("UIGradient")) then
		if grad then
			grad:Destroy()
		end
		grad = Instance.new("UIGradient")
		grad.Name = "_OceanTD_FillGrad"
		grad.Rotation = 90
		grad.Parent = bubble
	end
	;(grad :: UIGradient).Enabled = true
	;(grad :: UIGradient).Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, dark),
		ColorSequenceKeypoint.new(1, bright),
	})
end

local function clearRHealthBubbleGradient(bubble: GuiObject)
	local grad = bubble:FindFirstChild("_OceanTD_FillGrad")
	if grad and grad:IsA("UIGradient") then
		grad.Enabled = false
	end
end

local function setRHealthCircleStroke(bubble: GuiObject, color: Color3?, thickness: number?)
	local existing = bubble:FindFirstChild("_OceanTD_CircleStroke")
	if not color then
		if existing then
			existing:Destroy()
		end
		return
	end
	local stroke: UIStroke
	if existing and existing:IsA("UIStroke") then
		stroke = existing
	else
		if existing then
			existing:Destroy()
		end
		stroke = Instance.new("UIStroke")
		stroke.Name = "_OceanTD_CircleStroke"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.LineJoinMode = Enum.LineJoinMode.Round
		stroke.Parent = bubble
	end
	stroke.Thickness = thickness or 3.5
	stroke.Color = color
	stroke.Transparency = 0
	stroke.Enabled = true
end

local function ensureRHealthNextUnlockRing(bubble: GuiObject)
	-- Dedicated ring on the circle (not the lock glyph) so red↔white always shows.
	local old = bubble:FindFirstChild("_OceanTD_NextUnlockStroke")
	if old then
		old:Destroy()
	end
	setRHealthCircleStroke(bubble, nil)
	local stroke = Instance.new("UIStroke")
	stroke.Name = "_OceanTD_NextUnlockStroke"
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Thickness = 4.5
	stroke.Color = BRIGHT_RED
	stroke.Transparency = 0
	stroke.Enabled = true
	stroke.Parent = bubble
	startNextUnlockPulse(stroke, BRIGHT_RED, WHITE)
end

local function paintRHealthCheckStroke(check: TextLabel, color: Color3)
	local stroke = check:FindFirstChild("_OceanTD_CheckStroke")
	if not (stroke and stroke:IsA("UIStroke")) then
		if stroke then
			stroke:Destroy()
		end
		stroke = Instance.new("UIStroke")
		stroke.Name = "_OceanTD_CheckStroke"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		stroke.LineJoinMode = Enum.LineJoinMode.Round
		stroke.Thickness = 2.5
		stroke.Parent = check
	end
	;(stroke :: UIStroke).Color = color
	;(stroke :: UIStroke).Transparency = 0
	;(stroke :: UIStroke).Enabled = true
end

local function paintRHealthBubble(col: RHealthCol, mode: "active" | "idle")
	local bubble = col.bubble
	local check = col.check
	-- Same size for active + idle — no +20% scale on Reef Health.
	ensureStageScale(bubble).Scale = 1
	local nextStroke = bubble:FindFirstChild("_OceanTD_NextUnlockStroke")
	if nextStroke then
		nextStroke:Destroy()
	end
	if mode == "active" then
		setRHealthBubbleGradient(bubble, GREEN_DARK, GREEN_BRIGHT)
		setRHealthCircleStroke(bubble, BRIGHT_GREEN_RING, 3.5)
		check.TextColor3 = WHITE
		check.Text = "✓"
		check.Visible = true
		paintRHealthCheckStroke(check, Color3.fromRGB(20, 60, 30))
	else
		setRHealthBubbleGradient(bubble, GREY_DARKER, GREY_DARK)
		setRHealthCircleStroke(bubble, nil)
		check.TextColor3 = GREY_LIGHT
		check.Text = "✓"
		check.Visible = true
		paintRHealthCheckStroke(check, Color3.fromRGB(40, 40, 40))
	end
end

local function ensureRHealthLayout()
	local parent: Instance? = hostScreenGui or template
	if not parent then
		return
	end
	-- Rebuild if still under the old PowerUpTemplate panel or layout version outdated.
	local needsRebuild = not rHealthLayout
		or rHealthLayout.Parent ~= parent
		or rHealthLayout:GetAttribute("LayoutVer") ~= RHEALTH_LAYOUT_VER
		or #rHealthCols < SkillStages.MAX_STAGE
	if not needsRebuild then
		return
	end
	table.clear(rHealthCols)
	if rHealthLayout then
		rHealthLayout:Destroy()
		rHealthLayout = nil
	end
	local legacy = template and template:FindFirstChild("_OceanTD_RHealthLayout")
	if legacy then
		legacy:Destroy()
	end
	local legacySg = hostScreenGui and hostScreenGui:FindFirstChild("_OceanTD_RHealthLayout")
	if legacySg and legacySg ~= rHealthLayout then
		legacySg:Destroy()
	end

	local host = Instance.new("Frame")
	host.Name = "_OceanTD_RHealthLayout"
	host.BackgroundTransparency = 1
	host.BorderSizePixel = 0
	host.Size = UDim2.fromScale(1, 1)
	host.Position = UDim2.fromScale(0, 0)
	host.ZIndex = POWERUP_Z + 20
	host.Visible = false
	host:SetAttribute("LayoutVer", RHEALTH_LAYOUT_VER)
	host.Parent = parent
	rHealthLayout = host

	-- Full-screen blue → dark blue gradient at 90% opaque.
	local bg = Instance.new("Frame")
	bg.Name = "FullBleedBg"
	bg.BorderSizePixel = 0
	bg.Size = UDim2.fromScale(1, 1)
	bg.Position = UDim2.fromScale(0, 0)
	bg.BackgroundColor3 = WHITE
	bg.BackgroundTransparency = 0.1
	bg.ZIndex = host.ZIndex
	bg.Active = false
	bg.Parent = host
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(45, 130, 210)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(22, 70, 140)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(8, 28, 72)),
	})
	grad.Parent = bg

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 1)
	content.ZIndex = host.ZIndex + 1
	content.Parent = host

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0.06, 0)
	title.Size = UDim2.new(0.9, 0, 0.08, 0)
	title.Font = UI_FONT
	title.Text = "Reef Health"
	title.TextColor3 = WHITE
	title.TextScaled = true
	title.ZIndex = content.ZIndex + 1
	title.Parent = content

	local sub = Instance.new("TextLabel")
	sub.Name = "Subhead"
	sub.BackgroundTransparency = 1
	sub.AnchorPoint = Vector2.new(0.5, 0)
	sub.Position = UDim2.new(0.5, 0, 0.14, 0)
	sub.Size = UDim2.new(0.92, 0, 0.06, 0)
	sub.Font = UI_FONT
	sub.Text = RHEALTH_SUBHEAD
	sub.TextColor3 = Color3.fromRGB(180, 200, 220)
	sub.TextScaled = true
	sub.ZIndex = content.ZIndex + 1
	sub.Parent = content

	local row = Instance.new("Frame")
	row.Name = "StageRow"
	row.BackgroundTransparency = 1
	row.AnchorPoint = Vector2.new(0.5, 0)
	row.Position = UDim2.new(0.5, 0, 0.24, 0)
	-- Edge-to-edge: 8 columns fill the full screen width.
	row.Size = UDim2.new(1, 0, 0.64, 0)
	row.ZIndex = content.ZIndex + 1
	row.Parent = content
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	rowLayout.Padding = UDim.new(0, 0)
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Parent = row

	local colW = 1 / SkillStages.MAX_STAGE
	for i = 1, SkillStages.MAX_STAGE do
		local col = Instance.new("Frame")
		col.Name = "Col" .. tostring(i)
		col.BackgroundTransparency = 1
		col.Size = UDim2.new(colW, 0, 1, 0)
		col.LayoutOrder = i
		col.ZIndex = row.ZIndex + 1
		col.Parent = row
		local colLayout = Instance.new("UIListLayout")
		colLayout.FillDirection = Enum.FillDirection.Vertical
		colLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		colLayout.VerticalAlignment = Enum.VerticalAlignment.Top
		colLayout.Padding = UDim.new(0, 2)
		colLayout.SortOrder = Enum.SortOrder.LayoutOrder
		colLayout.Parent = col
		local colPad = Instance.new("UIPadding")
		colPad.PaddingLeft = UDim.new(0.06, 0)
		colPad.PaddingRight = UDim.new(0.06, 0)
		colPad.Parent = col

		local bubble = Instance.new("TextButton")
		bubble.Name = "Bubble"
		bubble.Text = ""
		bubble.AutoButtonColor = false
		bubble.BackgroundColor3 = GREEN
		bubble.BorderSizePixel = 0
		bubble.Size = UDim2.new(1, 0, 0.34, 0)
		bubble.LayoutOrder = 1
		bubble.ZIndex = col.ZIndex + 2
		bubble.Selectable = false
		bubble.Parent = col
		local aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = 1
		aspect.DominantAxis = Enum.DominantAxis.Width
		aspect.Parent = bubble
		local sizeCon = Instance.new("UISizeConstraint")
		sizeCon.MinSize = Vector2.new(48, 48)
		sizeCon.Parent = bubble
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = bubble

		local check = Instance.new("TextLabel")
		check.Name = "Check"
		check.BackgroundTransparency = 1
		check.Size = UDim2.fromScale(1, 1)
		check.Font = UI_FONT
		check.Text = "✓"
		check.TextColor3 = WHITE
		check.TextScaled = true
		check.ZIndex = bubble.ZIndex + 1
		check.Active = false
		check.Parent = bubble
		local checkPad = Instance.new("UIPadding")
		checkPad.PaddingTop = UDim.new(0.12, 0)
		checkPad.PaddingBottom = UDim.new(0.12, 0)
		checkPad.PaddingLeft = UDim.new(0.12, 0)
		checkPad.PaddingRight = UDim.new(0.12, 0)
		checkPad.Parent = check
		paintRHealthCheckStroke(check, Color3.fromRGB(20, 60, 30))

		local stageLbl = Instance.new("TextLabel")
		stageLbl.Name = "StageNum"
		stageLbl.BackgroundTransparency = 1
		stageLbl.Size = UDim2.new(1, 0, 0, RHEALTH_STAGE_TEXT_SIZE + 2)
		stageLbl.Font = UI_FONT
		stageLbl.Text = tostring(i)
		stageLbl.TextColor3 = WHITE
		stageLbl.TextScaled = false
		stageLbl.TextSize = RHEALTH_STAGE_TEXT_SIZE
		stageLbl.LayoutOrder = 2
		stageLbl.ZIndex = col.ZIndex + 1
		stageLbl.Parent = col

		local statLbl = Instance.new("TextLabel")
		statLbl.Name = "Stat"
		statLbl.BackgroundTransparency = 1
		-- Tight to stage number; height fits Max N / +N lines only.
		statLbl.Size = UDim2.new(1, 0, 0, RHEALTH_STAT_TEXT_SIZE * 2 + 4)
		statLbl.Font = UI_FONT
		statLbl.Text = "Max 10"
		statLbl.TextColor3 = Color3.fromRGB(190, 210, 230)
		statLbl.TextScaled = false
		statLbl.TextSize = RHEALTH_STAT_TEXT_SIZE
		statLbl.TextWrapped = true
		statLbl.LayoutOrder = 3
		statLbl.ZIndex = col.ZIndex + 1
		statLbl.Parent = col

		local unlockSlot = Instance.new("Frame")
		unlockSlot.Name = "UnlockSlot"
		unlockSlot.BackgroundTransparency = 1
		unlockSlot.Size = UDim2.new(1, 0, 0, 36)
		unlockSlot.LayoutOrder = 4
		unlockSlot.ZIndex = col.ZIndex + 1
		unlockSlot.Parent = col

		local stageIndex = i
		bubble.Activated:Connect(function()
			if not popupOpen or activeSkillId ~= "RHealth" or not powerUpClickGuard() then
				return
			end
			if confirmGui then
				return
			end
			local unlocked = unlockedStage("RHealth")
			if stageIndex > unlocked then
				SkillPowerUpUI.requestUnlockNext()
				return
			end
			if stageIndex == currentStage("RHealth") then
				return
			end
			requestSetActiveStage("RHealth", stageIndex)
		end)

		table.insert(rHealthCols, {
			root = col,
			bubble = bubble,
			check = check,
			stageLbl = stageLbl,
			statLbl = statLbl,
			unlockSlot = unlockSlot,
		})
	end

	local unlock = Instance.new("TextButton")
	unlock.Name = "RHealthUNLOCK"
	unlock.Text = "UNLOCK"
	unlock.Font = UI_FONT
	unlock.TextSize = 16
	unlock.TextScaled = true
	unlock.TextColor3 = WHITE
	unlock.BackgroundColor3 = GREEN
	unlock.BorderSizePixel = 0
	unlock.Size = UDim2.fromScale(1.5, 1)
	unlock.Visible = false
	unlock.Active = false
	unlock.Selectable = false
	unlock.ZIndex = POWERUP_Z + 650
	unlock.Parent = host
	local uc = Instance.new("UICorner")
	uc.CornerRadius = UDim.new(0, 8)
	uc.Parent = unlock
	applyUnlockStroke(unlock)
	bindButtonPress(unlock, "_OceanTD_RHealthUnlockBound", onUnlockPressed)
	rHealthUnlockBtn = unlock
end

local function refreshRHealthLayout()
	ensureRHealthLayout()
	if not rHealthLayout or not rHealthUnlockBtn then
		return
	end
	-- Hide Studio power-up panel + floating skill bubble behind this full-screen layout.
	if template then
		template.Visible = false
	end
	setStudioRingChromeVisible(false)
	rHealthLayout.Visible = true
	raiseTreeAboveBubbles(rHealthLayout)
	local bg = rHealthLayout:FindFirstChild("FullBleedBg")
	if bg and bg:IsA("GuiObject") then
		-- Keep gradient behind the stage columns / title.
		bg.ZIndex = rHealthLayout.ZIndex
	end
	local content = rHealthLayout:FindFirstChild("Content")
	if content and content:IsA("GuiObject") then
		content.ZIndex = rHealthLayout.ZIndex + 1
		for _, d in ipairs(content:GetDescendants()) do
			if d:IsA("GuiObject") then
				d.ZIndex = math.max(d.ZIndex, content.ZIndex + 1)
			end
		end
	end

	local active = currentStage("RHealth")
	local unlocked = unlockedStage("RHealth")
	local nextS = SkillStages.nextStageFor("RHealth", unlocked)
	clearLockOverlays()

	for i, col in ipairs(rHealthCols) do
		local hp = SkillStages.reefHealthAtStage(i)
		col.stageLbl.Text = tostring(i)
		if i <= unlocked then
			col.statLbl.Text = "Max " .. tostring(hp)
			col.statLbl.TextColor3 = if i == active then DESC_PULSE_GREEN else Color3.fromRGB(190, 210, 230)
		else
			local inc = SkillStages.reefHealthIncrementAtStage(i)
			if inc > 0 then
				col.statLbl.Text = "Max " .. tostring(hp) .. "\n+" .. tostring(inc)
			else
				col.statLbl.Text = "Max " .. tostring(hp)
			end
			col.statLbl.TextColor3 = Color3.fromRGB(150, 160, 175)
		end

		-- Clear prior lock/num chrome on custom bubbles.
		local leftoverNum = col.bubble:FindFirstChild("_OceanTD_StageNum")
		if leftoverNum then
			leftoverNum:Destroy()
		end
		local leftoverLock = col.bubble:FindFirstChild("_OceanTD_StageLock")
		if leftoverLock then
			leftoverLock:Destroy()
		end
		local leftoverStroke = col.bubble:FindFirstChild("_OceanTD_NextUnlockStroke")
		if leftoverStroke then
			leftoverStroke:Destroy()
		end

		col.check.Visible = true
		col.root.ClipsDescendants = false
		col.bubble.ClipsDescendants = false
		if nextS and i == nextS then
			col.check.Visible = false
			clearRHealthBubbleGradient(col.bubble)
			col.bubble.BackgroundColor3 = BRIGHT_RED
			ensureStageScale(col.bubble).Scale = 1
			-- Lock only (no number flash); ring applied separately on the circle.
			placeNextUnlockOn(col.bubble, i, {
				lockOnly = true,
				noRing = true,
			})
			ensureRHealthNextUnlockRing(col.bubble)
		elseif i > unlocked then
			col.check.Visible = false
			clearRHealthBubbleGradient(col.bubble)
			col.bubble.BackgroundColor3 = BRIGHT_RED
			setRHealthCircleStroke(col.bubble, nil)
			local ns = col.bubble:FindFirstChild("_OceanTD_NextUnlockStroke")
			if ns then
				ns:Destroy()
			end
			ensureStageScale(col.bubble).Scale = 1
			placeLockOn(col.bubble)
		elseif i == active then
			paintRHealthBubble(col, "active")
		else
			paintRHealthBubble(col, "idle")
		end
	end

	-- Park UNLOCK under the next locked stage column (50% wider than the column).
	local unlock = rHealthUnlockBtn
	if nextS and rHealthCols[nextS] then
		local slot = rHealthCols[nextS].unlockSlot
		unlock.Parent = slot
		unlock.AnchorPoint = Vector2.new(0.5, 0)
		unlock.Position = UDim2.fromScale(0.5, 0)
		unlock.Size = UDim2.fromScale(1.5, 1)
		local cost = SkillStages.stageCost("RHealth", nextS)
		unlock.Text = "UNLOCK\n" .. tostring(cost) .. " $D"
		unlock.Visible = true
		unlock.Active = true
		raiseInteractive(unlock, POWERUP_Z + 650)
		startUnlockBtnPulse()
	else
		unlock.Visible = false
		unlock.Active = false
		unlock.Parent = rHealthLayout
		stopUnlockBtnPulse()
	end

	if popupOpen then
		applyRHealthCloseLayout()
		beginGamepadNav()
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

	if activeSkillId == "RHealth" then
		refreshRHealthLayout()
		return
	end
	hideRHealthLayout()
	if template then
		template.Visible = true
	end
	setStudioRingChromeVisible(true)

	local active = currentStage(activeSkillId)
	local unlocked = unlockedStage(activeSkillId)
	if unlockNameLbl then
		unlockNameLbl.Text = string.gsub(def.displayName, "\n", " ")
		-- Cache Studio defaults once so shorter skill titles stay unchanged.
		if unlockNameBaseTextSize == nil then
			unlockNameBaseTextSize = unlockNameLbl.TextSize
			unlockNameBaseTextScaled = unlockNameLbl.TextScaled
			local constraint = unlockNameLbl:FindFirstChildOfClass("UITextSizeConstraint")
			if constraint then
				unlockNameBaseMaxTextSize = constraint.MaxTextSize
			end
		end
		-- "Reload Speed" is long — two sizes smaller so it stays one line above UnlockDesc.
		if activeSkillId == "ReloadSpeed" then
			local base = unlockNameBaseMaxTextSize or unlockNameBaseTextSize or unlockNameLbl.TextSize
			local smaller = math.max(10, base - 4)
			unlockNameLbl.TextScaled = false
			unlockNameLbl.TextSize = smaller
			unlockNameLbl.TextWrapped = false
			local constraint = unlockNameLbl:FindFirstChildOfClass("UITextSizeConstraint")
			if constraint then
				constraint.MaxTextSize = smaller
			end
		else
			unlockNameLbl.TextScaled = if unlockNameBaseTextScaled ~= nil then unlockNameBaseTextScaled else unlockNameLbl.TextScaled
			if unlockNameBaseTextSize then
				unlockNameLbl.TextSize = unlockNameBaseTextSize
			end
			local constraint = unlockNameLbl:FindFirstChildOfClass("UITextSizeConstraint")
			if constraint and unlockNameBaseMaxTextSize then
				constraint.MaxTextSize = unlockNameBaseMaxTextSize
			end
		end
	end
	local nextS = SkillStages.nextStageFor(activeSkillId, unlocked)
	if nextStageLbl then
		if nextS then
			local cost = SkillStages.stageCost(activeSkillId, nextS)
			nextStageLbl.Text = tostring(cost) .. " $D"
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
			elseif activeSkillId == "AutoRoll" then
				if SkillStages.isAutoRollUnlimited(active) then
					startUnlockDescPulse("AutoRoll", function(c: Color3)
						return string.format('<font color="%s">Unlimited auto rolls</font>', rgbFontTag(c))
					end)
				else
					local n = SkillStages.autoRollBudgetAtStage(active)
					if n <= 0 then
						stopUnlockDescPulse()
						unlockDescLbl.RichText = false
						unlockDescLbl.Text = "Auto roll off"
						unlockDescLbl.Visible = true
					else
						startUnlockDescPulse("AutoRoll", function(c: Color3)
							return string.format(
								'<font color="%s">%d</font> auto rolls',
								rgbFontTag(c),
								n
							)
						end)
					end
				end
			elseif activeSkillId == "ReloadSpeed" then
				if SkillStages.reloadSpeedIsFullAuto(active) then
					startUnlockDescPulse("ReloadSpeed", function(c: Color3)
						return string.format('<font color="%s">Full Auto</font> — hold to shoot', rgbFontTag(c))
					end)
				elseif SkillStages.reloadSpeedIsSemiInstant(active) then
					startUnlockDescPulse("ReloadSpeed", function(c: Color3)
						return string.format('<font color="%s">Semi Auto</font> — no reload', rgbFontTag(c))
					end)
				else
					local pct = SkillStages.reloadSpeedFasterPercent(1, active)
					if pct and pct > 0 then
						startUnlockDescPulse("ReloadSpeed", function(c: Color3)
							return string.format('<font color="%s">%d%% Faster</font>', rgbFontTag(c), pct)
						end)
					else
						stopUnlockDescPulse()
						unlockDescLbl.RichText = false
						unlockDescLbl.Text = "Base reload speed"
						unlockDescLbl.Visible = true
					end
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
			elseif activeSkillId == "AutoRoll" then
				if SkillStages.isAutoRollUnlimited(descStage) then
					startUnlockDescPulse("AutoRoll", function(c: Color3)
						return string.format('<font color="%s">Unlimited auto rolls</font>', rgbFontTag(c))
					end)
				else
					local inc = SkillStages.autoRollIncrementAtStage(descStage)
					if inc <= 0 then
						stopUnlockDescPulse()
						unlockDescLbl.RichText = false
						unlockDescLbl.Text = SkillStages.unlockDesc(activeSkillId, descStage)
						unlockDescLbl.Visible = true
					else
						startUnlockDescPulse("AutoRoll", function(c: Color3)
							return string.format(
								'<font color="%s">+%d</font> auto rolls',
								rgbFontTag(c),
								inc
							)
						end)
					end
				end
			elseif activeSkillId == "ReloadSpeed" then
				if SkillStages.reloadSpeedIsFullAuto(descStage) then
					startUnlockDescPulse("ReloadSpeed", function(c: Color3)
						return string.format('Unlock <font color="%s">Full Auto</font> — hold to shoot', rgbFontTag(c))
					end)
				elseif SkillStages.reloadSpeedIsSemiInstant(descStage) then
					startUnlockDescPulse("ReloadSpeed", function(c: Color3)
						return string.format('Unlock <font color="%s">Semi Auto</font> — no reload', rgbFontTag(c))
					end)
				else
					local pct = SkillStages.reloadSpeedFasterPercent(descStage - 1, descStage)
					if pct and pct > 0 then
						startUnlockDescPulse("ReloadSpeed", function(c: Color3)
							return string.format('<font color="%s">%d%% Faster</font>', rgbFontTag(c), pct)
						end)
					else
						stopUnlockDescPulse()
						unlockDescLbl.RichText = false
						unlockDescLbl.Text = SkillStages.unlockDesc(activeSkillId, descStage)
						unlockDescLbl.Visible = true
					end
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
	local nextUnlock = if nextS then nextS else nil
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
		local stageScale = ensureStageScale(sb)
		stageScale.Scale = 1
		if nextUnlock and i == nextUnlock then
			-- Red locked circle; lock icon ↔ N; ring pulses red→green.
			placeNextUnlockOn(sb, i)
		elseif i > unlocked then
			placeLockOn(sb)
		elseif i == active then
			-- Active stage: white checkmark, +20% size.
			paintStageCheckmarks(sb, "active")
			stageScale.Scale = ACTIVE_STAGE_SCALE
		else
			-- Unlocked but not active: grey background (not dark green).
			paintStageCheckmarks(sb, "idle")
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
		playUnlockSound()
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
			local hint = playerGui:GetAttribute("OceanTD_RollFingerHint")
			if hint == "plotSizeUpgrade" then
				-- Hide finger + skills UI for the grow shot; restore CloseBTN finger after cine.
				playerGui:SetAttribute("OceanTD_PendingClosePlotSizeHint", true)
				playerGui:SetAttribute("OceanTD_RollFingerHint", false)
				pcall(function()
					require(script.Parent:WaitForChild("SkillsAvatarCam")).releaseForCinematic()
				end)
				playerGui:SetAttribute("OceanTD_ForceCloseSkills", os.clock())
			else
				-- Drop avatar-cam ownership before ForceClose so its restore tween can't fight the cinematic.
				pcall(function()
					require(script.Parent:WaitForChild("SkillsAvatarCam")).releaseForCinematic()
				end)
				-- ForceClose always tears down skills + powerup; avoid close() while open
				-- so onClosed cannot race HUD restore mid-cinematic.
				playerGui:SetAttribute("OceanTD_ForceCloseSkills", os.clock())
			end
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

	local cost = SkillStages.stageCost(activeSkillId, nextS)

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(320, 232)
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
	title.Size = UDim2.new(1, -24, 0, 44)
	title.Position = UDim2.fromOffset(12, 16)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 24
	title.TextColor3 = Color3.fromRGB(240, 248, 255)
	title.Text = "Stage " .. tostring(nextS) .. " Unlock"
	title.ZIndex = 3
	title.Parent = panel

	local costLbl = Instance.new("TextLabel")
	costLbl.Name = "Cost"
	costLbl.BackgroundTransparency = 1
	costLbl.Size = UDim2.new(1, -24, 0, 28)
	costLbl.Position = UDim2.fromOffset(12, 58)
	costLbl.Font = Enum.Font.GothamBold
	costLbl.TextSize = 22
	costLbl.TextColor3 = COST_GREEN
	costLbl.Text = tostring(cost) .. " $D"
	costLbl.ZIndex = 3
	costLbl.Parent = panel

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

function SkillPowerUpUI.getActiveSkillId(): string?
	return activeSkillId
end

function SkillPowerUpUI.getUnlockButton(): GuiObject?
	return navUnlockBtn()
end

function SkillPowerUpUI.getCloseButton(): GuiObject?
	if not closeBtn or not closeBtn.Visible then
		return nil
	end
	-- Prefer the hit proxy so the finger lands on the clickable close target.
	if closeHitBtn and closeHitBtn.Visible then
		return closeHitBtn
	end
	return closeBtn
end

function SkillPowerUpUI.close()
	hideConfirm()
	popupOpen = false
	activeSkillId = nil
	stopUnlockDescPulse()
	stopUnlockBtnPulse()
	stopNextUnlockPulse()
	SkillsBubbleSim.setSuppressed(false)
	playerGui:SetAttribute(POWERUP_OPEN_ATTR, false)
	endGamepadNav()
	stopCloseXOverlay()
	clearLockOverlays()
	hideRHealthLayout()
	if unlockDescLbl then
		unlockDescLbl.RichText = false
	end
	if template then
		template.Visible = false
	end
	if closeBtn and (not template or not closeBtn:IsDescendantOf(template)) then
		closeBtn.Visible = false
	end
	if playerGui:GetAttribute("OceanTD_RollFingerHint") == "closePlotSize" then
		-- Defer so MobileSkillsA can restore Skills close chrome before the finger aims.
		task.defer(function()
			if playerGui:GetAttribute("OceanTD_RollFingerHint") == "closePlotSize" then
				playerGui:SetAttribute("OceanTD_RollFingerHint", "closeSkills")
			end
		end)
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
	-- Reef Health uses a full-screen layout — hide all skill bubbles (no blue bubble behind).
	-- Other skills keep the selected bubble visible at +20%.
	if skillId == "RHealth" then
		SkillsBubbleSim.setSuppressed(true)
		template.Visible = false
	else
		SkillsBubbleSim.setSuppressed(true, skillId)
		template.Visible = true
		raiseTreeAboveBubbles(template)
	end
	playerGui:SetAttribute(POWERUP_OPEN_ATTR, true)
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
			if playerGui:GetAttribute("OceanTD_JoinIntroBusy") ~= true then
				local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
				WaveEndVfx.syncToPlotSizeStage(currentStage("PlotSize"))
			end
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
			local navUnlock = navUnlockBtn()
			if
				navUnlock
				and navUnlock.Visible
				and navUnlock.Active
				and (obj == navUnlock or obj:IsDescendantOf(navUnlock))
			then
				onUnlockPressed()
				return
			end
			if activeSkillId == "RHealth" and not confirmGui then
				for stageIndex, col in ipairs(rHealthCols) do
					if obj == col.bubble or obj:IsDescendantOf(col.bubble) or obj:IsDescendantOf(col.root) then
						local unlocked = unlockedStage("RHealth")
						if stageIndex > unlocked then
							SkillPowerUpUI.requestUnlockNext()
						elseif stageIndex ~= currentStage("RHealth") then
							if powerUpClickGuard() then
								requestSetActiveStage("RHealth", stageIndex)
							end
						end
						return
					end
				end
			elseif activeSkillId and not confirmGui then
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
	-- Join intro owns max footprint / route until showcase ends.
	if playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true then
		local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
		WaveSim.applyReefHealthStage(currentStage("RHealth"))
		WaveSim.clampSpeedToMaxStep(SkillStages.waveSpeedMaxStep(currentStage("WaveSpeed")))
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
