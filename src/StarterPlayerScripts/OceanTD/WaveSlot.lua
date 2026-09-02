--!strict
--[[
	Slot5 Start / Stop waves — always visible quickbar control.
	Shortcuts: R (keyboard) / ButtonX (gamepad). Help badge green; hidden on touch.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))
local UiIdleCycle = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiIdleCycle"))
local UiPopupScale = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPopupScale"))
local UiViewportTags = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiViewportTags"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local WaveSimConsts = require(script.Parent:WaitForChild("WaveSimConsts"))
local WaveSummaryUi = require(script.Parent:WaitForChild("WaveSummaryUi"))

local WaveSlot = {}

local START_ICON = "rbxassetid://74802566438233"
local STOP_ICON = "rbxassetid://96580667427806"
local HELP_GREEN = Color3.fromRGB(40, 180, 80)
local HELP_RED = Color3.fromRGB(200, 45, 50)
local CONTINUE_HEARTS = 5
local CONFETTI_COUNT = 40
local CONFETTI_LIFE = 2.4
-- Shift camera subject up so the avatar sits ~20% lower on screen during waves.
local WAVE_CAM_SCREEN_SHIFT = 0.2
local STOP_PANEL_W = 420
local STOP_PANEL_H = 220
local STOP_SCALE_IN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local STOP_SCALE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

export type Deps = {
	mainHUD: ScreenGui,
	playerGui: PlayerGui,
	ensureButton: (GuiObject) -> GuiButton,
	passthroughDecor: (GuiObject, GuiButton) -> (),
	ensureCircle: (GuiObject) -> GuiObject,
	ensureStroke: (GuiObject, string, Color3, number) -> UIStroke,
	getShortcutMode: () -> string,
	red: Color3,
	green: Color3,
	log: (...any) -> (),
}

local deps: Deps
local slot5: GuiObject? = nil
local slot5Button: GuiButton? = nil
local slot5Circle: GuiObject? = nil
local helpSlot5: GuiObject? = nil
local helpSlot5Letter: TextLabel? = nil
local helpHit: GuiButton? = nil

local hudFrame: Frame? = nil
local hudWaveBar: Frame? = nil
local hudWaveFill: Frame? = nil
local hudWaveLabel: TextLabel? = nil
local hudWaveHit: TextButton? = nil
local hudCritterBarsEye: TextButton? = nil
local hudWaveStroke: UIStroke? = nil
local hudBarFork: TextLabel? = nil
local hudBarHeart: TextLabel? = nil
local hudBarHeartScale: UIScale? = nil
local hudFinishHint: TextLabel? = nil
local hudReefBar: Frame? = nil
local hudReefFill: Frame? = nil
local hudReefLabel: TextLabel? = nil
local hudReefPlus: TextButton? = nil
local hudTime: TextLabel? = nil
local hudFishNeed: TextLabel? = nil
local hudLayoutConn: RBXScriptConnection? = nil
local finishFlashToken = 0
local feedCompleteUi = false
local lastHungryMissToken = -1
local fillHurtToken = 0
local lastFishFull = 0
local lastFishTotal = 0
local lastCrabTotal = 0
local lastUrchinTotal = 0
local lastWaveIndex = 0
local lastReefHealth = -1
local lastReefMax = 10

local BAR_BG = Color3.fromRGB(0x9e, 0x0b, 0x00)
local BAR_FILL = Color3.fromRGB(0x12, 0xd9, 0x00)
local BAR_DANGER_BG = Color3.fromRGB(255, 40, 45)
local REEF_BAR_BG = Color3.fromRGB(0x00, 0x03, 0x29)
local REEF_BAR_FILL = Color3.fromRGB(0xff, 0x18, 0x14)
local REEF_PLUS_GREEN = Color3.fromRGB(50, 230, 100)
local REEF_PLUS_DARK = Color3.fromRGB(0, 110, 35)
local REEF_PLUS_STROKE = Color3.fromRGB(12, 70, 28)
local FLASH_BRIGHT = Color3.fromRGB(90, 255, 90)
local FLASH_DARK = Color3.fromRGB(0, 110, 35)
local LINE_H = 28
local BAR_H = 26
local REEF_PLUS_SIZE = 26
local REEF_ROW_GAP = 6
local LABEL_TEXT_SIZE = math.floor(15 * 1.25 + 0.5) -- 25% bigger
local FORK_COUNT_TEXT_SIZE = math.max(1, LABEL_TEXT_SIZE - 2)
local SIDE_ICON_PAD = 6
local BAR_TOP_GAP = 20
-- 720p+ wave/reef bars: wider than mobile quickbar track, and taller/larger text than popup baseline.
local WAVE_HUD_WIDTH_MULT = 1.25 * 1.25 -- +25%, then another +25%
local WAVE_HUD_SIZE_MULT = 1.25 -- extra UIScale on top of UiPopupScale (taller + larger text)
local WAVE_HUD_SCALE_NAME = "_OceanTD_WaveHudScale"
local REEF_PANEL_W = 360
local REEF_PANEL_H = 200
local REEF_SCALE_IN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local REEF_SCALE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SUMMARY_SCALE_IN = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SUMMARY_SCALE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local summaryGui: ScreenGui? = nil
local summaryOpen = false
local summaryPausedForSkills = false
local finishBtn: TextButton? = nil
local continueBtn: TextButton? = nil
local prevGuiSelected: GuiObject? = nil
local summarySelectableRestore: { [GuiObject]: boolean } = {}
local confettiConn: RBXScriptConnection? = nil
local confettiToken = 0
local summaryStroke: UIStroke? = nil
local summaryTitleStroke: UIStroke? = nil
local summaryStrokeConn: RBXScriptConnection? = nil
local summaryScaleToken = 0
local SUMMARY_CORNER = 32
local SUMMARY_STROKE_THICKNESS = 3.5
-- Pull stroke inward so top/bottom aren't clipped by safe-area / scale.
local SUMMARY_STROKE_INSET = SUMMARY_STROKE_THICKNESS
local SUMMARY_PANEL_W = 540
local SUMMARY_PANEL_H = 380
-- Full rainbow once every ~12s.
local SUMMARY_RGB_HUE_PER_SEC = 1 / 12
-- Title outline: slow bright↔dark red pulse (~4s full cycle).
local TITLE_STROKE_BRIGHT = Color3.fromRGB(255, 70, 70)
local TITLE_STROKE_DARK = Color3.fromRGB(95, 12, 18)
local TITLE_STROKE_PERIOD_SEC = 4
local waveCamConn: RBXScriptConnection? = nil
local waveCamCharConn: RBXScriptConnection? = nil
-- Fixed offset baked when waves start — must NOT track live zoom or pinch fights CameraOffset.
local waveCamOffset = Vector3.zero

local stopConfirmActive = false
local stopConfirmCheck: TextButton? = nil
local stopConfirmCancel: TextButton? = nil
local stopConfirmGui: ScreenGui? = nil
local stopConfirmPanel: Frame? = nil
local stopConfirmDim: Frame? = nil
local stopConfirmTitle: TextLabel? = nil
local stopConfirmOpenedAt = 0
local stopTitleFlashConn: RBXScriptConnection? = nil
local stopScaleToken = 0
local stopPrevGuiSelected: GuiObject? = nil

local reefHealOpen = false
local reefHealGui: ScreenGui? = nil
local reefHealPanel: Frame? = nil
local reefHealDim: Frame? = nil
local reefHealStroke: UIStroke? = nil
local reefHealTitle: TextLabel? = nil
local reefHealBtn: TextButton? = nil
local reefHealClose: TextButton? = nil
local reefHealOpenedAt = 0
local reefHealStrokeConn: RBXScriptConnection? = nil
local reefHealScaleToken = 0
local reefHealPrevSelected: GuiObject? = nil
local reefPlusFlashToken = 0
local reefPlusIdleStop: UiIdleCycle.StopFn? = nil
local IDLE_HALF_SEC = 2
-- Forward-declared: WaveSlot.refreshHelpBadge runs before these locals are assigned.
local applyReefPlusIdle: (showHelp: boolean) -> ()
local stopReefPlusIdle: () -> ()
local startReefPlusIdle: () -> ()

local function isUsingGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function clearWaveCameraOffset()
	local char = Players.LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.CameraOffset = Vector3.zero
	end
end

local function computeWaveCameraOffset(): Vector3
	local cam = Workspace.CurrentCamera
	if not cam then
		return Vector3.new(0, 3, 0)
	end
	local dist = (cam.CFrame.Position - cam.Focus.Position).Magnitude
	if dist < 1 then
		dist = 12.5
	end
	local halfH = dist * math.tan(math.rad(cam.FieldOfView) * 0.5)
	-- 20% of full vertical view in studs at the focus distance (at bake time).
	return Vector3.new(0, halfH * (WAVE_CAM_SCREEN_SHIFT * 2), 0)
end

local function applyWaveCameraOffset()
	local char = Players.LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.CameraOffset = waveCamOffset
	end
end

local function bakeWaveCameraOffset()
	waveCamOffset = computeWaveCameraOffset()
	applyWaveCameraOffset()
end

local function setWaveCameraActive(on: boolean)
	if on then
		if waveCamConn then
			return
		end
		bakeWaveCameraOffset()
		-- Re-assert fixed offset only (never recompute from zoom distance).
		waveCamConn = RunService.Heartbeat:Connect(applyWaveCameraOffset)
		if not waveCamCharConn then
			waveCamCharConn = Players.LocalPlayer.CharacterAdded:Connect(function()
				task.defer(bakeWaveCameraOffset)
			end)
		end
		return
	end
	if waveCamConn then
		waveCamConn:Disconnect()
		waveCamConn = nil
	end
	if waveCamCharConn then
		waveCamCharConn:Disconnect()
		waveCamCharConn = nil
	end
	waveCamOffset = Vector3.zero
	clearWaveCameraOffset()
end

local function applyIcon(running: boolean)
	if not slot5Circle then
		return
	end
	if slot5Circle:IsA("ImageLabel") or slot5Circle:IsA("ImageButton") then
		(slot5Circle :: any).Image = if running then STOP_ICON else START_ICON
	end
	WaveSlot.refreshHelpBadge()
end

local function styleHelpBadge(): boolean
	if not helpSlot5 or not helpSlot5Letter then
		return false
	end
	local mode = deps.getShortcutMode()
	if mode == "touch" then
		return false
	end
	if helpSlot5:IsA("ImageLabel") or helpSlot5:IsA("ImageButton") then
		(helpSlot5 :: any).Image = ""
	end
	helpSlot5.BackgroundColor3 = if WaveSim.isRunning() then HELP_RED else HELP_GREEN
	helpSlot5.BackgroundTransparency = 0
	helpSlot5.Active = false
	UiCircles.ensure(helpSlot5)
	helpSlot5Letter.Text = if mode == "gamepad" then "X" else "R"
	helpSlot5Letter.TextColor3 = Color3.new(1, 1, 1)
	helpSlot5Letter.Visible = true
	return true
end

local function refreshFinishHint()
	if not hudFinishHint then
		return
	end
	if not feedCompleteUi or not hudFrame or not hudFrame.Visible then
		hudFinishHint.Visible = false
		return
	end
	if InventoryState.isOpen() then
		hudFinishHint.Visible = false
		return
	end
	if not deps then
		return
	end
	local mode = deps.getShortcutMode()
	if mode == "touch" then
		hudFinishHint.Visible = false
		return
	end
	hudFinishHint.Text = if mode == "gamepad" then "R2" else "ENTER"
	hudFinishHint.Visible = true
end

local function setSlot5Interactable(on: boolean)
	if slot5Button then
		slot5Button.Selectable = false
		slot5Button.Active = on
	end
	if slot5 then
		slot5.Selectable = false
		if slot5:IsA("GuiButton") then
			(slot5 :: GuiButton).Active = on
		end
	end
	if helpHit then
		helpHit.Selectable = false
		helpHit.Active = on and helpHit.Visible
	end
end

function WaveSlot.refreshHelpBadge()
	if not helpSlot5 then
		return
	end
	if Players.LocalPlayer.PlayerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true then
		helpSlot5.Visible = false
		if helpHit then
			helpHit.Visible = false
			helpHit.Active = false
		end
		refreshFinishHint()
		return
	end
	local backpackOpen = InventoryState.isOpen()
	if styleHelpBadge() then
		helpSlot5.Visible = true
		if helpHit then
			helpHit.Visible = true
			helpHit.Selectable = false
			-- Badge stays visible as a hint, but never clickable while backpack is open.
			helpHit.Active = not backpackOpen
		end
	else
		helpSlot5.Visible = false
		if helpHit then
			helpHit.Visible = false
			helpHit.Active = false
		end
	end
	refreshFinishHint()
	if hudReefPlus and reefPlusIdleStop and hudReefPlus.Text ~= "+" then
		applyReefPlusIdle(true)
	end
end

local dangerFlashToken = 0
local hungerDangerUi = false
local fireworkToken = 0

local function restoreBarChrome()
	if hudWaveBar then
		hudWaveBar.BackgroundColor3 = BAR_BG
		hudWaveBar.BackgroundTransparency = 0.5
	end
	if hudWaveStroke then
		hudWaveStroke.Color = Color3.new(1, 1, 1)
		hudWaveStroke.Thickness = 1.5
	end
	if hudWaveLabel then
		hudWaveLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
		hudWaveLabel.TextStrokeTransparency = 0.35
	end
end

local function stopFinishFlash()
	finishFlashToken += 1
	if not hungerDangerUi then
		restoreBarChrome()
	end
end

local function stopDangerFlash()
	dangerFlashToken += 1
	if hudBarHeartScale then
		hudBarHeartScale.Scale = 1
	end
	if not feedCompleteUi then
		restoreBarChrome()
	end
end

local function startFinishFlash()
	finishFlashToken += 1
	dangerFlashToken += 1
	if hudBarHeartScale then
		hudBarHeartScale.Scale = 1
	end
	local my = finishFlashToken
	if not hudWaveLabel or not hudWaveStroke then
		return
	end
	hudWaveLabel.TextStrokeTransparency = 0.15
	hudWaveStroke.Thickness = 1.5
	if hudWaveBar then
		hudWaveBar.BackgroundColor3 = BAR_BG
		hudWaveBar.BackgroundTransparency = 0.5
	end
	task.spawn(function()
		while my == finishFlashToken and feedCompleteUi do
			if hudWaveLabel then
				hudWaveLabel.TextStrokeColor3 = FLASH_BRIGHT
			end
			if hudWaveStroke then
				hudWaveStroke.Color = FLASH_BRIGHT
			end
			task.wait(0.35)
			if my ~= finishFlashToken or not feedCompleteUi then
				break
			end
			if hudWaveLabel then
				hudWaveLabel.TextStrokeColor3 = FLASH_DARK
			end
			if hudWaveStroke then
				hudWaveStroke.Color = FLASH_DARK
			end
			task.wait(0.35)
		end
	end)
end

local function startDangerFlash()
	if feedCompleteUi then
		return
	end
	dangerFlashToken += 1
	local my = dangerFlashToken
	task.spawn(function()
		while my == dangerFlashToken and hungerDangerUi and not feedCompleteUi do
			if hudWaveBar then
				hudWaveBar.BackgroundColor3 = BAR_DANGER_BG
				hudWaveBar.BackgroundTransparency = 0
			end
			if hudWaveStroke then
				hudWaveStroke.Color = BAR_DANGER_BG
				hudWaveStroke.Thickness = 2
			end
			if hudBarHeartScale then
				hudBarHeartScale.Scale = 1.4
			end
			task.wait(0.28)
			if my ~= dangerFlashToken or not hungerDangerUi or feedCompleteUi then
				break
			end
			if hudWaveBar then
				hudWaveBar.BackgroundColor3 = BAR_BG
				hudWaveBar.BackgroundTransparency = 0.5
			end
			if hudWaveStroke then
				hudWaveStroke.Color = Color3.new(1, 1, 1)
				hudWaveStroke.Thickness = 1.5
			end
			if hudBarHeartScale then
				hudBarHeartScale.Scale = 0.85
			end
			task.wait(0.28)
		end
		if my == dangerFlashToken then
			if hudBarHeartScale then
				hudBarHeartScale.Scale = 1
			end
			if not feedCompleteUi and not hungerDangerUi then
				restoreBarChrome()
			end
		end
	end)
end

local function flashFillHurt()
	fillHurtToken += 1
	local my = fillHurtToken
	if hudWaveFill then
		hudWaveFill.BackgroundColor3 = BAR_DANGER_BG
	end
	task.delay(0.5, function()
		if my == fillHurtToken and hudWaveFill then
			hudWaveFill.BackgroundColor3 = BAR_FILL
		end
	end)
end

local function refreshForkLabel()
	if not hudBarFork then
		return
	end
	hudBarFork.TextSize = FORK_COUNT_TEXT_SIZE
	if feedCompleteUi then
		hudBarFork.Text = "100%"
		return
	end
	hudBarFork.Text = string.format("%d of %d", lastFishFull, lastFishTotal + lastCrabTotal + lastUrchinTotal)
end

local function refreshRightForkEmoji()
	if not hudBarHeart then
		return
	end
	-- Finish hint (ENTER / R2) owns the right slot when feed is complete.
	hudBarHeart.Visible = not feedCompleteUi
	hudBarHeart.Text = "🍴"
	hudBarHeart.TextSize = LABEL_TEXT_SIZE
end

local function refreshCritterBarsEye()
	if not hudCritterBarsEye then
		return
	end
	local on = WaveSim.areCritterHungerBarsVisible()
	hudCritterBarsEye.BackgroundColor3 = if on then HELP_GREEN else HELP_RED
end

local function playFinishFirework(emojis: { string })
	if not hudWaveBar or not deps.mainHUD then
		return
	end
	fireworkToken += 1
	local my = fireworkToken
	local bar = hudWaveBar
	local origin = bar.AbsolutePosition + bar.AbsoluteSize * 0.5
	local parentPos = deps.mainHUD.AbsolutePosition
	local ox = origin.X - parentPos.X
	local oy = origin.Y - parentPos.Y

	local layer = Instance.new("Frame")
	layer.Name = "OceanTD_FinishFirework"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = 80
	layer.Active = false
	layer.Parent = deps.mainHUD

	local n = math.clamp(#emojis * 3, 16, 48)
	local rng = Random.new()
	for i = 1, n do
		local emoji = emojis[((i - 1) % #emojis) + 1]
		local lbl = Instance.new("TextLabel")
		lbl.BackgroundTransparency = 1
		lbl.Text = emoji
		lbl.Font = Enum.Font.SourceSansBold
		lbl.TextSize = rng:NextInteger(22, 40)
		lbl.AnchorPoint = Vector2.new(0.5, 0.5)
		lbl.Position = UDim2.fromOffset(ox, oy)
		lbl.Size = UDim2.fromOffset(48, 48)
		lbl.ZIndex = 81
		lbl.Parent = layer
		local scale = Instance.new("UIScale")
		scale.Scale = 0.12
		scale.Parent = lbl

		local angle = rng:NextNumber(0, math.pi * 2)
		local speed = rng:NextNumber(260, 620)
		local vx = math.cos(angle) * speed
		local vy = math.sin(angle) * speed - rng:NextNumber(120, 280)
		local grav = rng:NextNumber(820, 1200)
		local life = rng:NextNumber(1.15, 1.9)
		local popAt = rng:NextNumber(0.1, 0.24)
		local peak = rng:NextNumber(1.15, 1.85)
		local x = ox
		local y = oy
		task.spawn(function()
			local t0 = os.clock()
			while my == fireworkToken and lbl.Parent do
				local dt = RunService.RenderStepped:Wait()
				local age = os.clock() - t0
				if age >= life then
					break
				end
				vy += grav * dt
				x += vx * dt
				y += vy * dt
				vx *= (1 - 0.55 * dt)
				lbl.Position = UDim2.fromOffset(x, y)
				if age < popAt then
					scale.Scale = 0.12 + (peak - 0.12) * (age / popAt)
				else
					local u = math.clamp((age - popAt) / math.max(0.05, life - popAt), 0, 1)
					scale.Scale = peak * (1 - 0.3 * u)
				end
				lbl.TextTransparency = math.clamp((age - life * 0.6) / (life * 0.4), 0, 1)
			end
			if lbl.Parent then
				lbl:Destroy()
			end
		end)
	end
	task.delay(2.5, function()
		if layer.Parent and my == fireworkToken then
			layer:Destroy()
		end
	end)
end

function WaveSlot.isFinishReady(): boolean
	return feedCompleteUi and WaveSim.isRunning() and not InventoryState.isOpen()
end

function WaveSlot.tryFinishFromShortcut(): boolean
	if not WaveSlot.isFinishReady() then
		return false
	end
	local emojis = WaveSim.getFinishEmojis()
	playFinishFirework(emojis)
	WaveSim.finishWaveEarly()
	return true
end

local function refreshReefHudLabels()
	local cur = math.max(0, lastReefHealth)
	local maxHp = math.max(1, lastReefMax)
	local text = "🤍 Reef Health " .. tostring(cur) .. "/" .. tostring(maxHp)
	if hudReefLabel then
		hudReefLabel.Text = text
	end
	if reefHealTitle then
		reefHealTitle.Text = text
	end
	if hudReefFill then
		hudReefFill.Size = UDim2.fromScale(math.clamp(cur / maxHp, 0, 1), 1)
	end
	if reefHealBtn then
		local atMax = cur >= maxHp
		reefHealBtn.AutoButtonColor = not atMax
		reefHealBtn.BackgroundTransparency = if atMax then 0.45 else 0
	end
end

stopReefPlusIdle = function()
	if reefPlusIdleStop then
		reefPlusIdleStop()
		reefPlusIdleStop = nil
	end
	if hudReefPlus then
		hudReefPlus.Text = "+"
		hudReefPlus.TextSize = 22
	end
end

applyReefPlusIdle = function(showHelp: boolean)
	if not hudReefPlus then
		return
	end
	if not showHelp then
		hudReefPlus.Text = "+"
		hudReefPlus.TextSize = 22
		return
	end
	local mode = if deps then deps.getShortcutMode() else "keyboard"
	if mode == "touch" then
		hudReefPlus.Text = "+"
		hudReefPlus.TextSize = 22
		return
	end
	if mode == "gamepad" then
		hudReefPlus.Text = "L3"
		hudReefPlus.TextSize = 11
	else
		hudReefPlus.Text = "H"
		hudReefPlus.TextSize = 16
	end
end

startReefPlusIdle = function()
	if not hudReefPlus then
		return
	end
	stopReefPlusIdle()
	reefPlusIdleStop = UiIdleCycle.subscribeSharedToggle(IDLE_HALF_SEC, applyReefPlusIdle, function()
		return hudFrame ~= nil
			and hudFrame.Visible
			and WaveSim.isRunning()
			and not reefHealOpen
			and not InventoryState.isOpen()
	end, false)
end

function WaveSlot.isReefHealOpen(): boolean
	return reefHealOpen
end

function WaveSlot.hideReefHeal()
	if not reefHealOpen and not (reefHealGui and reefHealGui.Enabled) then
		return
	end
	reefHealOpen = false
	reefHealScaleToken += 1
	local my = reefHealScaleToken
	if reefHealStrokeConn then
		reefHealStrokeConn:Disconnect()
		reefHealStrokeConn = nil
	end
	local sel = GuiService.SelectedObject
	if (reefHealClose and sel == reefHealClose) or (reefHealBtn and sel == reefHealBtn) then
		GuiService.SelectedObject = reefHealPrevSelected
	end
	reefHealPrevSelected = nil
	if reefHealDim then
		reefHealDim.Visible = false
	end
	if reefHealPanel and reefHealPanel.Visible and hudReefPlus then
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
		local btnPos = hudReefPlus.AbsolutePosition
		local btnSize = hudReefPlus.AbsoluteSize
		local endX = (btnPos.X + btnSize.X * 0.5) / vp.X
		local endY = (btnPos.Y + btnSize.Y * 0.5) / vp.Y
		local tw = TweenService:Create(reefHealPanel, REEF_SCALE_OUT, {
			Position = UDim2.fromScale(endX, endY),
			Size = UDim2.fromOffset(40, 40),
		})
		tw:Play()
		tw.Completed:Connect(function()
			if my ~= reefHealScaleToken then
				return
			end
			if reefHealPanel then
				reefHealPanel.Visible = false
			end
			if reefHealGui then
				reefHealGui.Enabled = false
			end
			if hudFrame and hudFrame.Visible and WaveSim.isRunning() then
				startReefPlusIdle()
			end
		end)
	else
		if reefHealPanel then
			reefHealPanel.Visible = false
		end
		if reefHealGui then
			reefHealGui.Enabled = false
		end
		if hudFrame and hudFrame.Visible and WaveSim.isRunning() then
			startReefPlusIdle()
		end
	end
end

function WaveSlot.cancelReefHeal()
	if not reefHealOpen then
		return
	end
	WaveSlot.hideReefHeal()
end

local function ensureReefHealUi()
	if reefHealGui and reefHealPanel and reefHealBtn and reefHealClose then
		return
	end
	local g = Instance.new("ScreenGui")
	g.Name = "OceanTD_ReefHeal"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 12070
	g.Enabled = false
	g.Parent = deps.playerGui
	reefHealGui = g

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.45
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Visible = false
	dim.Active = true
	dim.ZIndex = 1
	dim.Parent = g
	reefHealDim = dim
	dim.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if os.clock() - reefHealOpenedAt < 0.35 then
				return
			end
			WaveSlot.cancelReefHeal()
		end
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(REEF_PANEL_W, REEF_PANEL_H)
	panel.BackgroundColor3 = Color3.fromRGB(18, 28, 40)
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.ZIndex = 2
	panel.Active = true
	panel.ClipsDescendants = true
	panel.Parent = g
	reefHealPanel = panel
	UiPopupScale.attach(panel)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 40, 45)
	stroke.Thickness = 2.5
	stroke.Parent = panel
	reefHealStroke = stroke

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -10, 0, 8)
	closeBtn.Size = UDim2.fromOffset(36, 32)
	closeBtn.BackgroundColor3 = Color3.fromRGB(200, 45, 50)
	closeBtn.Font = UiTheme.Font
	closeBtn.Text = "X"
	closeBtn.TextColor3 = Color3.new(1, 1, 1)
	closeBtn.TextSize = 18
	closeBtn.AutoButtonColor = true
	closeBtn.ZIndex = 5
	closeBtn.Selectable = true
	closeBtn.Parent = panel
	reefHealClose = closeBtn
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 8)
	cc.Parent = closeBtn
	closeBtn.Activated:Connect(function()
		WaveSlot.cancelReefHeal()
	end)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, 52)
	title.Size = UDim2.new(1, -40, 0, 36)
	title.Font = UiTheme.Font
	title.Text = "🤍 Reef Health 10/10"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextScaled = true
	title.ZIndex = 3
	title.Parent = panel
	reefHealTitle = title

	local heal = Instance.new("TextButton")
	heal.Name = "PlusOne"
	heal.AnchorPoint = Vector2.new(0.5, 1)
	heal.Position = UDim2.new(0.5, 0, 1, -24)
	heal.Size = UDim2.fromOffset(200, 48)
	heal.BackgroundColor3 = deps.green
	heal.Font = UiTheme.Font
	heal.Text = "+1 Health"
	heal.TextColor3 = Color3.new(1, 1, 1)
	heal.TextSize = 22
	heal.AutoButtonColor = true
	heal.Selectable = true
	heal.ZIndex = 4
	heal.Parent = panel
	reefHealBtn = heal
	local hc = Instance.new("UICorner")
	hc.CornerRadius = UDim.new(0, 10)
	hc.Parent = heal
	local hs = Instance.new("UIStroke")
	hs.Color = Color3.fromRGB(12, 70, 28)
	hs.Thickness = 2.5
	hs.Parent = heal
	heal.Activated:Connect(function()
		WaveSlot.commitReefHeal()
	end)
	closeBtn.NextSelectionDown = heal
	heal.NextSelectionUp = closeBtn
end

function WaveSlot.commitReefHeal()
	if not reefHealOpen then
		return
	end
	if WaveSim.healReef(1) then
		UiHaptics.pulseShort()
		local snap = WaveSim.getHudSnapshot()
		lastReefHealth = snap.reefHealth
		lastReefMax = snap.reefMax
		refreshReefHudLabels()
	end
end

function WaveSlot.handleReefHealPrimaryConfirm()
	if not reefHealOpen then
		return
	end
	local sel = GuiService.SelectedObject
	if reefHealClose and sel == reefHealClose then
		WaveSlot.cancelReefHeal()
		return
	end
	WaveSlot.commitReefHeal()
end

local function flashReefPlusThenOpen()
	if not hudReefPlus then
		WaveSlot.beginReefHeal()
		return
	end
	reefPlusFlashToken += 1
	local my = reefPlusFlashToken
	hudReefPlus.BackgroundColor3 = REEF_PLUS_DARK
	task.delay(0.12, function()
		if my ~= reefPlusFlashToken or not hudReefPlus then
			return
		end
		hudReefPlus.BackgroundColor3 = REEF_PLUS_GREEN
		WaveSlot.beginReefHeal()
	end)
end

function WaveSlot.beginReefHeal()
	if reefHealOpen then
		return
	end
	if not WaveSim.isRunning() or InventoryState.isOpen() then
		return
	end
	stopReefPlusIdle()
	if hudReefPlus then
		hudReefPlus.Text = "+"
		hudReefPlus.TextSize = 22
	end
	ensureReefHealUi()
	refreshReefHudLabels()
	reefHealOpenedAt = os.clock()
	reefHealOpen = true
	reefHealScaleToken += 1
	if reefHealGui then
		reefHealGui.Enabled = true
	end
	if reefHealDim then
		reefHealDim.Visible = true
	end
	if reefHealPanel then
		UiPopupScale.attach(reefHealPanel)
		reefHealPanel.Visible = true
		if hudReefPlus then
			local cam = Workspace.CurrentCamera
			local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
			local btnPos = hudReefPlus.AbsolutePosition
			local btnSize = hudReefPlus.AbsoluteSize
			local startX = (btnPos.X + btnSize.X * 0.5) / vp.X
			local startY = (btnPos.Y + btnSize.Y * 0.5) / vp.Y
			reefHealPanel.Position = UDim2.fromScale(startX, startY)
			reefHealPanel.Size = UDim2.fromOffset(40, 40)
			TweenService:Create(reefHealPanel, REEF_SCALE_IN, {
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(REEF_PANEL_W, REEF_PANEL_H),
			}):Play()
		else
			reefHealPanel.Position = UDim2.fromScale(0.5, 0.5)
			reefHealPanel.Size = UDim2.fromOffset(REEF_PANEL_W, REEF_PANEL_H)
		end
	end
	if reefHealStrokeConn then
		reefHealStrokeConn:Disconnect()
		reefHealStrokeConn = nil
	end
	if reefHealStroke then
		local t0 = os.clock()
		local dark = Color3.fromRGB(110, 20, 25)
		local bright = Color3.fromRGB(255, 50, 55)
		reefHealStrokeConn = RunService.RenderStepped:Connect(function()
			if not reefHealOpen or not reefHealStroke then
				return
			end
			local wave = (math.sin((os.clock() - t0) * 2.2) + 1) * 0.5
			reefHealStroke.Color = dark:Lerp(bright, wave)
		end)
	end
	if isUsingGamepad() and reefHealBtn then
		reefHealPrevSelected = GuiService.SelectedObject
		GuiService.SelectedObject = reefHealBtn
	end
end

function WaveSlot.tryOpenReefHealFromShortcut(): boolean
	if not WaveSim.isRunning() or InventoryState.isOpen() or reefHealOpen then
		return false
	end
	if WaveSlot.isStopConfirmActive() or summaryOpen then
		return false
	end
	flashReefPlusThenOpen()
	return true
end

local function resolveActiveMainHud(): ScreenGui?
	if not deps then
		return nil
	end
	local pg = deps.playerGui
	local mobile = pg:FindFirstChild(UiViewportTags.MOBILE_RIGHT_HUD)
	local p720 = pg:FindFirstChild(UiViewportTags.P720_RIGHT_HUD)
	-- Prefer the Enabled right HUD so bars aren't stuck on a disabled ScreenGui.
	if mobile and mobile:IsA("ScreenGui") and mobile.Enabled then
		return mobile
	end
	if p720 and p720:IsA("ScreenGui") and p720.Enabled then
		return p720
	end
	return deps.mainHUD
end

local function syncWaveHudToActiveRightHud()
	if not deps then
		return
	end
	local hud = resolveActiveMainHud()
	if not hud then
		return
	end
	deps.mainHUD = hud
	local quickbar = hud:FindFirstChild("Quickbar")
	local found = if quickbar then quickbar:FindFirstChild("Slot5") else nil
	if found and found:IsA("GuiObject") then
		slot5 = found
		-- Prefer existing bound hit target if present.
		local existingHit = slot5:FindFirstChild("_OceanTD_Hit")
		if existingHit and existingHit:IsA("GuiButton") then
			slot5Button = existingHit
		elseif slot5:IsA("GuiButton") then
			slot5Button = slot5
		end
		local circle = slot5:FindFirstChild("Circle")
		if circle and circle:IsA("GuiObject") then
			slot5Circle = circle
		end
	end
	if hudFrame and hudFrame.Parent ~= hud then
		hudFrame.Parent = hud
	end
end

local function ensureHud()
	syncWaveHudToActiveRightHud()
	if hudFrame then
		return
	end
	local f = Instance.new("Frame")
	f.Name = "OceanTD_WaveHud"
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Active = false
	f.Visible = false
	f.ZIndex = 25
	f.Size = UDim2.fromOffset(220, BAR_H * 2 + REEF_ROW_GAP + 4 + LINE_H)
	f.Parent = deps.mainHUD
	hudFrame = f

	-- Reef health row (above wave bar): full-width bar, + overlays right end.
	local reefBar = Instance.new("Frame")
	reefBar.Name = "ReefProgress"
	reefBar.BackgroundColor3 = REEF_BAR_BG
	reefBar.BackgroundTransparency = 0.5
	reefBar.BorderSizePixel = 0
	reefBar.Active = false
	reefBar.Size = UDim2.new(1, -4, 0, BAR_H)
	reefBar.Position = UDim2.fromOffset(0, 0)
	reefBar.ZIndex = 26
	reefBar.ClipsDescendants = false
	reefBar.Parent = f
	local reefCorner = Instance.new("UICorner")
	reefCorner.CornerRadius = UDim.new(1, 0)
	reefCorner.Parent = reefBar
	local reefStroke = Instance.new("UIStroke")
	reefStroke.Color = Color3.new(1, 1, 1)
	reefStroke.Thickness = 1.5
	reefStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	reefStroke.Parent = reefBar
	hudReefBar = reefBar

	local reefFill = Instance.new("Frame")
	reefFill.Name = "Fill"
	reefFill.BackgroundColor3 = REEF_BAR_FILL
	reefFill.BackgroundTransparency = 0
	reefFill.BorderSizePixel = 0
	reefFill.Size = UDim2.fromScale(1, 1)
	reefFill.ZIndex = 27
	reefFill.Parent = reefBar
	local reefFillCorner = Instance.new("UICorner")
	reefFillCorner.CornerRadius = UDim.new(1, 0)
	reefFillCorner.Parent = reefFill
	hudReefFill = reefFill

	local reefLabel = Instance.new("TextLabel")
	reefLabel.Name = "ReefLabel"
	reefLabel.BackgroundTransparency = 1
	reefLabel.Size = UDim2.fromScale(1, 1)
	reefLabel.Font = UiTheme.Font
	reefLabel.TextSize = LABEL_TEXT_SIZE
	reefLabel.TextColor3 = Color3.new(1, 1, 1)
	reefLabel.TextStrokeTransparency = 0.35
	reefLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	reefLabel.TextXAlignment = Enum.TextXAlignment.Center
	reefLabel.TextYAlignment = Enum.TextYAlignment.Center
	reefLabel.ZIndex = 29
	reefLabel.Text = "🤍 Reef Health 10/10"
	reefLabel.Parent = reefBar
	local reefPad = Instance.new("UIPadding")
	reefPad.PaddingRight = UDim.new(0, REEF_PLUS_SIZE + 4)
	reefPad.Parent = reefLabel
	hudReefLabel = reefLabel

	local plus = Instance.new("TextButton")
	plus.Name = "ReefPlus"
	plus.AnchorPoint = Vector2.new(1, 0.5)
	plus.Position = UDim2.new(1, 0, 0.5, 0)
	plus.Size = UDim2.fromOffset(BAR_H, BAR_H)
	plus.BackgroundColor3 = REEF_PLUS_GREEN
	plus.BackgroundTransparency = 0
	plus.BorderSizePixel = 0
	plus.Text = "+"
	plus.Font = Enum.Font.SourceSansBold
	plus.TextSize = 22
	plus.TextColor3 = Color3.new(1, 1, 1)
	plus.TextStrokeColor3 = REEF_PLUS_STROKE
	plus.TextStrokeTransparency = 0
	plus.AutoButtonColor = false
	plus.ZIndex = 31
	plus.Parent = reefBar
	hudReefPlus = plus
	UiCircles.ensure(plus)
	local plusStroke = Instance.new("UIStroke")
	plusStroke.Color = REEF_PLUS_STROKE
	plusStroke.Thickness = 1.5
	plusStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	plusStroke.Parent = plus
	plus.Activated:Connect(function()
		if InventoryState.isOpen() or not WaveSim.isRunning() then
			return
		end
		flashReefPlusThenOpen()
	end)

	local waveY = BAR_H + REEF_ROW_GAP
	local bar = Instance.new("Frame")
	bar.Name = "WaveProgress"
	bar.BackgroundColor3 = BAR_BG
	bar.BackgroundTransparency = 0.5
	bar.BorderSizePixel = 0
	bar.Active = false
	bar.Size = UDim2.new(1, -4, 0, BAR_H)
	bar.Position = UDim2.fromOffset(0, waveY)
	bar.ZIndex = 26
	bar.ClipsDescendants = true
	bar.Parent = f
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(1, 0)
	barCorner.Parent = bar
	local barStroke = Instance.new("UIStroke")
	barStroke.Name = "OuterStroke"
	barStroke.Color = Color3.new(1, 1, 1)
	barStroke.Thickness = 1.5
	barStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	barStroke.Parent = bar
	hudWaveBar = bar
	hudWaveStroke = barStroke

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = BAR_FILL
	fill.BackgroundTransparency = 0
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.ZIndex = 27
	fill.Parent = bar
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill
	hudWaveFill = fill

	local label = Instance.new("TextLabel")
	label.Name = "WaveLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = UiTheme.Font
	label.TextSize = LABEL_TEXT_SIZE
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.35
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = 29
	label.Text = "🌊 Wave 1"
	label.Parent = bar
	hudWaveLabel = label

	local function mkSide(name: string, text: string, align: Enum.TextXAlignment): TextLabel
		local t = Instance.new("TextLabel")
		t.Name = name
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(0.35, 0, 1, 0)
		t.Position = if align == Enum.TextXAlignment.Left
			then UDim2.fromOffset(SIDE_ICON_PAD, 0)
			else UDim2.new(1, -SIDE_ICON_PAD, 0, 0)
		t.AnchorPoint = if align == Enum.TextXAlignment.Left then Vector2.new(0, 0) else Vector2.new(1, 0)
		t.Font = UiTheme.Font
		t.TextSize = LABEL_TEXT_SIZE
		t.TextColor3 = Color3.new(1, 1, 1)
		t.TextStrokeTransparency = 0.35
		t.TextStrokeColor3 = Color3.new(0, 0, 0)
		t.TextXAlignment = align
		t.TextYAlignment = Enum.TextYAlignment.Center
		t.ZIndex = 28
		t.Text = text
		t.Parent = bar
		return t
	end
	hudBarFork = mkSide("ForkCount", "0 of 0", Enum.TextXAlignment.Left)
	hudBarFork.TextSize = FORK_COUNT_TEXT_SIZE
	hudBarHeart = mkSide("ForkEmoji", "🍴", Enum.TextXAlignment.Right)
	local heartScale = Instance.new("UIScale")
	heartScale.Scale = 1
	heartScale.Parent = hudBarHeart
	hudBarHeartScale = heartScale

	local finishHint = Instance.new("TextLabel")
	finishHint.Name = "FinishHint"
	finishHint.BackgroundTransparency = 1
	finishHint.Size = UDim2.new(0.4, 0, 1, 0)
	finishHint.Position = UDim2.new(1, -SIDE_ICON_PAD, 0, 0)
	finishHint.AnchorPoint = Vector2.new(1, 0)
	finishHint.Font = UiTheme.Font
	finishHint.TextSize = FORK_COUNT_TEXT_SIZE
	finishHint.TextColor3 = Color3.new(1, 1, 1)
	finishHint.TextStrokeTransparency = 0.35
	finishHint.TextStrokeColor3 = Color3.new(0, 0, 0)
	finishHint.TextXAlignment = Enum.TextXAlignment.Right
	finishHint.TextYAlignment = Enum.TextYAlignment.Center
	finishHint.ZIndex = 28
	finishHint.Visible = false
	finishHint.Text = "ENTER"
	finishHint.Parent = bar
	hudFinishHint = finishHint

	local hit = Instance.new("TextButton")
	hit.Name = "FinishHit"
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.Size = UDim2.fromScale(1, 1)
	hit.ZIndex = 30
	hit.Visible = false
	hit.Active = false
	hit.AutoButtonColor = false
	hit.Parent = bar
	hit.Activated:Connect(function()
		WaveSlot.tryFinishFromShortcut()
	end)
	hudWaveHit = hit

	local timeLabel = Instance.new("TextLabel")
	timeLabel.Name = "Time"
	timeLabel.BackgroundTransparency = 1
	timeLabel.Size = UDim2.new(0.34, -4, 0, LINE_H)
	timeLabel.Position = UDim2.new(1, 0, 0, waveY + BAR_H + 4)
	timeLabel.AnchorPoint = Vector2.new(1, 0)
	timeLabel.Font = UiTheme.Font
	timeLabel.TextSize = 15
	timeLabel.TextColor3 = Color3.new(1, 1, 1)
	timeLabel.TextStrokeTransparency = 0.35
	timeLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	timeLabel.TextXAlignment = Enum.TextXAlignment.Right
	timeLabel.TextYAlignment = Enum.TextYAlignment.Center
	timeLabel.TextTruncate = Enum.TextTruncate.None
	timeLabel.ZIndex = 26
	timeLabel.Parent = f
	hudTime = timeLabel

	local eyeBtn = Instance.new("TextButton")
	eyeBtn.Name = "CritterBarsEye"
	eyeBtn.BackgroundTransparency = 0
	eyeBtn.BackgroundColor3 = HELP_GREEN
	eyeBtn.BorderSizePixel = 0
	eyeBtn.AutoButtonColor = false
	eyeBtn.Text = "👁️"
	eyeBtn.Size = UDim2.fromOffset(LINE_H, LINE_H)
	eyeBtn.Position = UDim2.new(0.62, 0, 0, waveY + BAR_H + 4)
	eyeBtn.Font = UiTheme.Font
	eyeBtn.TextSize = 15
	eyeBtn.TextColor3 = Color3.new(1, 1, 1)
	eyeBtn.TextStrokeTransparency = 0.35
	eyeBtn.TextStrokeColor3 = Color3.new(0, 0, 0)
	eyeBtn.ZIndex = 27
	eyeBtn.Visible = false
	eyeBtn.Active = false
	eyeBtn.Parent = f
	UiCircles.ensure(eyeBtn)
	eyeBtn.Activated:Connect(function()
		if not WaveSim.isRunning() then
			return
		end
		WaveSim.toggleCritterHungerBarsVisible()
		UiHaptics.pulseShort()
		refreshCritterBarsEye()
	end)
	hudCritterBarsEye = eyeBtn

	local fishNeed = Instance.new("TextLabel")
	fishNeed.Name = "FishNeed"
	fishNeed.BackgroundTransparency = 1
	fishNeed.Size = UDim2.new(0.58, -4, 0, LINE_H)
	fishNeed.Position = UDim2.fromOffset(0, waveY + BAR_H + 4)
	fishNeed.Font = UiTheme.Font
	fishNeed.TextSize = 15
	fishNeed.TextColor3 = Color3.new(1, 1, 1)
	fishNeed.TextStrokeTransparency = 0.35
	fishNeed.TextStrokeColor3 = Color3.new(0, 0, 0)
	fishNeed.TextXAlignment = Enum.TextXAlignment.Left
	fishNeed.TextYAlignment = Enum.TextYAlignment.Center
	fishNeed.TextTruncate = Enum.TextTruncate.None
	fishNeed.ZIndex = 26
	fishNeed.Text = "🍴:2x 🐟:0"
	fishNeed.Parent = f
	hudFishNeed = fishNeed
end

local function applyWaveHudScale(root: GuiObject): number
	local popup = UiPopupScale.get()
	local barScale = if popup > 1 then popup * WAVE_HUD_SIZE_MULT else 1
	local existing = root:FindFirstChild(WAVE_HUD_SCALE_NAME)
	local scaleObj: UIScale
	if existing and existing:IsA("UIScale") then
		scaleObj = existing
	else
		if existing then
			existing:Destroy()
		end
		-- Drop shared popup scale if present — wave HUD uses its own boost.
		local shared = root:FindFirstChild("_OceanTD_PopupScale")
		if shared then
			shared:Destroy()
		end
		scaleObj = Instance.new("UIScale")
		scaleObj.Name = WAVE_HUD_SCALE_NAME
		scaleObj.Parent = root
	end
	scaleObj.Scale = barScale
	return barScale
end

local function layoutHud()
	syncWaveHudToActiveRightHud()
	if not hudFrame or not slot5 then
		return
	end
	local parent = deps.mainHUD
	local slotPos = slot5.AbsolutePosition
	local slotSize = slot5.AbsoluteSize
	local parentPos = parent.AbsolutePosition
	local scale = applyWaveHudScale(hudFrame)
	local designW = math.max(260, slotSize.X + 140)
	if scale > 1 then
		designW = math.floor(designW * WAVE_HUD_WIDTH_MULT + 0.5)
	end
	local designH = BAR_H + REEF_ROW_GAP + BAR_H + 4 + LINE_H
	local w = math.floor(designW / scale + 0.5)
	local h = designH
	local gap = math.floor(BAR_TOP_GAP * scale + 0.5)
	local x = (slotPos.X + slotSize.X) - parentPos.X - designW
	local y = (slotPos.Y + slotSize.Y + gap) - parentPos.Y
	hudFrame.Size = UDim2.fromOffset(w, h)
	hudFrame.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
end

local function setHudVisible(on: boolean)
	ensureHud()
	local wasVisible = hudFrame ~= nil and hudFrame.Visible
	local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
	local skillsOpen = pg ~= nil and pg:GetAttribute("OceanTD_SkillsBubblesOpen") == true
	local hideUiActive = pg ~= nil and pg:GetAttribute("OceanTD_HideUiActive") == true
	if hudFrame then
		-- Keep wave sim running; suppress chrome while skills / Hide UI are on.
		hudFrame.Visible = on and not skillsOpen and not hideUiActive
	end
	if on and not hideUiActive then
		layoutHud()
		if not wasVisible then
			refreshForkLabel()
			refreshRightForkEmoji()
			startReefPlusIdle()
		end
		if not hudLayoutConn then
			hudLayoutConn = RunService.RenderStepped:Connect(function()
				if hudFrame and hudFrame.Visible then
					layoutHud()
				end
			end)
		end
	elseif not on then
		if hudLayoutConn then
			hudLayoutConn:Disconnect()
			hudLayoutConn = nil
		end
		feedCompleteUi = false
		hungerDangerUi = false
		lastHungryMissToken = -1
		fillHurtToken += 1
		if reefHealOpen then
			WaveSlot.hideReefHeal()
		end
		stopReefPlusIdle()
		stopFinishFlash()
		stopDangerFlash()
		restoreBarChrome()
		if hudWaveFill then
			hudWaveFill.BackgroundColor3 = BAR_FILL
		end
		if hudBarHeartScale then
			hudBarHeartScale.Scale = 1
		end
		if hudBarFork then
			hudBarFork.Visible = true
		end
		if hudBarHeart then
			hudBarHeart.Visible = true
			hudBarHeart.Text = "🍴"
		end
		if hudFinishHint then
			hudFinishHint.Visible = false
		end
		if hudWaveHit then
			hudWaveHit.Visible = false
			hudWaveHit.Active = false
		end
		if hudCritterBarsEye then
			hudCritterBarsEye.Visible = false
			hudCritterBarsEye.Active = false
		end
	elseif hideUiActive and hudLayoutConn then
		hudLayoutConn:Disconnect()
		hudLayoutConn = nil
	end
end

local function userCamCycleBusy(): boolean
	local m = deps.playerGui:GetAttribute("OceanTD_CamCycleMode")
	return m == "freecam" or m == "fishcam"
end

local function syncWaveCamera(snap: WaveSim.HudSnapshot)
	-- No Humanoid.CameraOffset during waves in standard/follow mode (was shifting the view up).
	if waveCamConn then
		setWaveCameraActive(false)
	else
		clearWaveCameraOffset()
	end
end

local function updateHud(snap: WaveSim.HudSnapshot)
	ensureHud()
	if not snap.running then
		setHudVisible(false)
		syncWaveCamera(snap)
		return
	end
	syncWaveCamera(snap)
	setHudVisible(true)
	local prog = math.clamp(snap.feedProgress or 0, 0, 1)
	if hudWaveFill then
		hudWaveFill.Size = UDim2.fromScale(prog, 1)
	end
	lastReefHealth = snap.reefHealth or 0
	lastReefMax = snap.reefMax or 10
	refreshReefHudLabels()
	lastFishFull = snap.fishFull or 0
	lastFishTotal = snap.fishTotal or 0
	lastCrabTotal = math.max(0, snap.crabTotal or 0)
	lastUrchinTotal = math.max(0, snap.urchinTotal or 0)
	lastWaveIndex = snap.wave or 0
	local complete = snap.feedComplete == true
	local danger = snap.hungerDanger == true
	if hudWaveLabel then
		if complete then
			hudWaveLabel.Text = "NEXT WAVE"
		else
			hudWaveLabel.Text = "🌊 Wave " .. tostring(snap.wave)
		end
	end
	if complete ~= feedCompleteUi then
		feedCompleteUi = complete
		if complete then
			hungerDangerUi = false
			stopDangerFlash()
			if hudWaveHit then
				hudWaveHit.Visible = true
				hudWaveHit.Active = true
			end
			startFinishFlash()
		else
			if hudWaveHit then
				hudWaveHit.Visible = false
				hudWaveHit.Active = false
			end
			stopFinishFlash()
			restoreBarChrome()
			if danger then
				hungerDangerUi = true
				startDangerFlash()
			end
		end
	end
	refreshForkLabel()
	refreshRightForkEmoji()
	if hudBarFork then
		hudBarFork.Visible = true
	end
	local missTok = snap.hungryMissToken or 0
	if lastHungryMissToken < 0 then
		lastHungryMissToken = missTok
	elseif missTok > lastHungryMissToken then
		flashFillHurt()
		lastHungryMissToken = missTok
	else
		lastHungryMissToken = missTok
	end
	refreshFinishHint()
	if not complete and danger ~= hungerDangerUi then
		hungerDangerUi = danger
		if danger then
			startDangerFlash()
		else
			stopDangerFlash()
		end
	end
	if hudTime then
		hudTime.Text = "⏱️" .. WaveSim.formatClock(snap.elapsedSec)
	end
	if hudFishNeed then
		local need = WaveSimConsts.tangHungerForWave(snap.wave)
		local fishCount = math.max(snap.fishTotal or 0, 0)
		local line = "🍴:" .. tostring(need) .. "x 🐟:" .. tostring(fishCount)
		local crabs = math.max(0, snap.crabTotal or 0)
		local urchins = math.max(0, snap.urchinTotal or 0)
		if urchins > 0 then
			line ..= " ✴:" .. tostring(urchins)
		end
		if crabs > 0 then
			line ..= " 🦀:" .. tostring(crabs)
		end
		hudFishNeed.Text = line
	end
	if hudCritterBarsEye then
		hudCritterBarsEye.Visible = snap.running
		hudCritterBarsEye.Active = snap.running
		refreshCritterBarsEye()
	end
end

local function stopConfetti()
	confettiToken += 1
	if confettiConn then
		confettiConn:Disconnect()
		confettiConn = nil
	end
end

local function playConfetti(parent: Frame)
	stopConfetti()
	local my = confettiToken
	local layer = Instance.new("Frame")
	layer.Name = "Confetti"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = 50
	layer.Parent = parent

	type P = { f: Frame, x: number, y: number, vx: number, vy: number, life: number }
	local parts: { P } = {}
	local rng = Random.new()
	local colors = {
		Color3.fromRGB(255, 80, 80),
		Color3.fromRGB(255, 180, 40),
		Color3.fromRGB(80, 220, 100),
		Color3.fromRGB(60, 160, 255),
		Color3.fromRGB(220, 100, 255),
		Color3.fromRGB(255, 255, 80),
		Color3.fromRGB(255, 120, 200),
		Color3.fromRGB(100, 255, 220),
	}
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	for i = 1, CONFETTI_COUNT do
		local sz = rng:NextNumber(6, 18)
		local f = Instance.new("Frame")
		f.BackgroundColor3 = colors[((i - 1) % #colors) + 1]
		f.BorderSizePixel = 0
		f.Size = UDim2.fromOffset(sz, sz)
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.ZIndex = 51
		f.Parent = layer
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = f
		local x = rng:NextNumber(vp.X * 0.15, vp.X * 0.85)
		local y = vp.Y + rng:NextNumber(4, 40)
		f.Position = UDim2.fromOffset(x, y)
		table.insert(parts, {
			f = f,
			x = x,
			y = y,
			vx = rng:NextNumber(-90, 90),
			vy = rng:NextNumber(-520, -280),
			life = CONFETTI_LIFE + rng:NextNumber(-0.3, 0.4),
		})
	end

	local t0 = os.clock()
	local grav = 520
	confettiConn = RunService.RenderStepped:Connect(function(dt)
		if my ~= confettiToken then
			return
		end
		local age = os.clock() - t0
		local alive = false
		for _, p in ipairs(parts) do
			if age > p.life then
				p.f.Visible = false
				continue
			end
			alive = true
			p.vy += grav * dt
			p.x += p.vx * dt
			p.y += p.vy * dt
			p.f.Position = UDim2.fromOffset(p.x, p.y)
			local fade = math.clamp(1 - (age / p.life), 0, 1)
			p.f.BackgroundTransparency = 1 - fade
		end
		if not alive or age > CONFETTI_LIFE + 1 then
			stopConfetti()
			if layer.Parent then
				layer:Destroy()
			end
		end
	end)
end

local function styleSummaryEdge(edge: UIStroke)
	edge.Name = "SummaryEdge"
	edge.Thickness = SUMMARY_STROKE_THICKNESS
	edge.BorderOffset = UDim.new(0, SUMMARY_STROKE_INSET)
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	edge.LineJoinMode = Enum.LineJoinMode.Round
end

local function stopSummaryStrokeCycle()
	if summaryStrokeConn then
		summaryStrokeConn:Disconnect()
		summaryStrokeConn = nil
	end
end

local function endSummaryGamepadNav()
	for obj, _ in pairs(summarySelectableRestore) do
		if obj.Parent then
			obj.Selectable = true
		end
	end
	table.clear(summarySelectableRestore)
	if continueBtn then
		continueBtn.NextSelectionUp = nil
		continueBtn.NextSelectionDown = nil
		continueBtn.NextSelectionLeft = nil
		continueBtn.NextSelectionRight = nil
	end
	if finishBtn then
		finishBtn.NextSelectionUp = nil
		finishBtn.NextSelectionDown = nil
		finishBtn.NextSelectionLeft = nil
		finishBtn.NextSelectionRight = nil
	end
end

local function beginSummaryGamepadNav()
	endSummaryGamepadNav()
	if not continueBtn or not finishBtn then
		return
	end
	GuiService.AutoSelectGuiEnabled = true
	for _, layer in ipairs(deps.playerGui:GetChildren()) do
		if not layer:IsA("LayerCollector") then
			continue
		end
		local function consider(obj: Instance)
			if obj:IsA("GuiObject") and obj.Selectable then
				if obj ~= continueBtn and obj ~= finishBtn then
					summarySelectableRestore[obj] = true
					obj.Selectable = false
				end
			end
		end
		consider(layer)
		for _, d in ipairs(layer:GetDescendants()) do
			consider(d)
		end
	end
	continueBtn.Selectable = true
	finishBtn.Selectable = true
	-- Stick / DPad can only bounce between CONTINUE and FINISH.
	continueBtn.NextSelectionUp = finishBtn
	continueBtn.NextSelectionDown = finishBtn
	continueBtn.NextSelectionLeft = finishBtn
	continueBtn.NextSelectionRight = finishBtn
	finishBtn.NextSelectionUp = continueBtn
	finishBtn.NextSelectionDown = continueBtn
	finishBtn.NextSelectionLeft = continueBtn
	finishBtn.NextSelectionRight = continueBtn
	GuiService.SelectedObject = continueBtn
end

local function startSummaryStrokeCycle()
	stopSummaryStrokeCycle()
	if not summaryStroke and not summaryTitleStroke then
		return
	end
	local t0 = os.clock()
	summaryStrokeConn = RunService.RenderStepped:Connect(function()
		if not summaryOpen then
			return
		end
		if summaryStroke then
			local hue = ((os.clock() - t0) * SUMMARY_RGB_HUE_PER_SEC) % 1
			summaryStroke.Color = Color3.fromHSV(hue, 1, 1)
		end
		if summaryTitleStroke and summaryTitleStroke.Parent then
			local phase = ((os.clock() - t0) / TITLE_STROKE_PERIOD_SEC) * math.pi * 2
			local a = (math.sin(phase) + 1) * 0.5
			summaryTitleStroke.Color = TITLE_STROKE_BRIGHT:Lerp(TITLE_STROKE_DARK, a)
		end
	end)
end

local function reefBarScreenCenter(): Vector2?
	local bar = hudReefBar
	if not (bar and bar.Parent) then
		return nil
	end
	local p = bar.AbsolutePosition
	local s = bar.AbsoluteSize
	if s.X < 1 or s.Y < 1 then
		return nil
	end
	return Vector2.new(p.X + s.X * 0.5, p.Y + s.Y * 0.5)
end

local function hideSummary()
	if not summaryOpen and not (summaryGui and summaryGui.Enabled) and not summaryPausedForSkills then
		return
	end
	summaryOpen = false
	summaryPausedForSkills = false
	stopConfetti()
	stopSummaryStrokeCycle()
	endSummaryGamepadNav()
	summaryScaleToken += 1
	local my = summaryScaleToken
	local sel = GuiService.SelectedObject
	if (finishBtn and sel == finishBtn) or (continueBtn and sel == continueBtn) then
		GuiService.SelectedObject = prevGuiSelected
	end
	prevGuiSelected = nil

	local g = summaryGui
	local panel = g and g:FindFirstChild("Panel")
	local dim = g and g:FindFirstChild("Dim")
	if dim and dim:IsA("GuiObject") then
		dim.Visible = false
	end
	if panel and panel:IsA("Frame") and panel.Visible and g and g.Enabled then
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
		local origin = reefBarScreenCenter()
		local endX = if origin then origin.X / vp.X else 0.92
		local endY = if origin then origin.Y / vp.Y else 0.55
		local tw = TweenService:Create(panel, SUMMARY_SCALE_OUT, {
			Position = UDim2.fromScale(endX, endY),
			Size = UDim2.fromOffset(48, 28),
		})
		tw:Play()
		tw.Completed:Connect(function()
			if my ~= summaryScaleToken then
				return
			end
			if panel then
				panel.Visible = false
			end
			if g then
				g.Enabled = false
			end
		end)
	elseif g then
		g.Enabled = false
		if panel and panel:IsA("Frame") then
			panel.Visible = false
		end
	end
end

local function pauseSummaryForSkills()
	if not summaryOpen or summaryPausedForSkills then
		return
	end
	summaryPausedForSkills = true
	endSummaryGamepadNav()
	stopConfetti()
	stopSummaryStrokeCycle()
	local g = summaryGui
	if g then
		g.Enabled = false
	end
end

local function resumeSummaryAfterSkills()
	if not summaryPausedForSkills then
		return
	end
	summaryPausedForSkills = false
	if not summaryOpen then
		return
	end
	local g = summaryGui
	if not g then
		return
	end
	g.Enabled = true
	local dim = g:FindFirstChild("Dim")
	if dim and dim:IsA("GuiObject") then
		dim.Visible = true
	end
	local panel = g:FindFirstChild("Panel")
	if panel and panel:IsA("Frame") then
		panel.ClipsDescendants = false
		panel.Visible = true
		panel.Position = UDim2.fromScale(0.5, 0.5)
		panel.Size = UDim2.fromOffset(SUMMARY_PANEL_W, SUMMARY_PANEL_H)
		local edge = panel:FindFirstChild("SummaryEdge")
		if edge and edge:IsA("UIStroke") then
			styleSummaryEdge(edge)
			summaryStroke = edge
		end
		startSummaryStrokeCycle()
	end
	if isUsingGamepad() and continueBtn and finishBtn then
		prevGuiSelected = GuiService.SelectedObject
		beginSummaryGamepadNav()
	end
end

local function openReefHealthFromSummary()
	if not summaryOpen or summaryPausedForSkills then
		return
	end
	local pg = deps.playerGui
	if not pg then
		return
	end
	UiHaptics.pulseShort()
	pauseSummaryForSkills()
	pg:SetAttribute("OceanTD_ForceOpenSkillId", "RHealth")
	pg:SetAttribute("OceanTD_ForceOpenSkills", os.clock())
	deps.log("Summary — opened Skills / Reef Health")
end

function WaveSlot.dismissSummary()
	if summaryOpen then
		hideSummary()
	end
end

local function continueFromSummary()
	if not summaryOpen then
		return
	end
	hideSummary()
	if WaveSim.continueWithHearts(CONTINUE_HEARTS) then
		applyIcon(true)
		setHudVisible(true)
		clearWaveCameraOffset()
		deps.log("Waves continued (+" .. tostring(CONTINUE_HEARTS) .. " hearts)")
	end
end

function WaveSlot.continueFromSummary()
	continueFromSummary()
end

function WaveSlot.handleSummaryPrimaryConfirm(): boolean
	if not summaryOpen then
		return false
	end
	local sel = GuiService.SelectedObject
	if sel == finishBtn then
		hideSummary()
		return true
	end
	continueFromSummary()
	return true
end

local function ensureSummaryPanelContent(panel: Frame)
	local c, f, titleStroke = WaveSummaryUi.ensurePanelContent(
		panel,
		continueFromSummary,
		hideSummary,
		openReefHealthFromSummary
	)
	continueBtn = c
	finishBtn = f
	summaryTitleStroke = titleStroke
end

local function showSummary(summary: WaveSim.Summary)
	summaryOpen = true
	-- Capture reef bar screen center before HUD hides (summary scales out of it).
	local origin = reefBarScreenCenter()
	setHudVisible(false)
	applyIcon(false)

	local records = WaveSummaryUi.reportAndReadRecords(summary)

	if not summaryGui then
		local g = Instance.new("ScreenGui")
		g.Name = "OceanTD_WaveSummary"
		g.ResetOnSpawn = false
		g.IgnoreGuiInset = true
		g.ClipToDeviceSafeArea = false
		g.DisplayOrder = 13000
		g.Parent = deps.playerGui
		summaryGui = g

		local dim = Instance.new("Frame")
		dim.Name = "Dim"
		dim.BackgroundColor3 = Color3.new(0, 0, 0)
		dim.BackgroundTransparency = 0.4
		dim.Size = UDim2.fromScale(1, 1)
		dim.BorderSizePixel = 0
		dim.ZIndex = 1
		dim.Parent = g

		local panel = Instance.new("Frame")
		panel.Name = "Panel"
		panel.AnchorPoint = Vector2.new(0.5, 0.5)
		panel.Position = UDim2.fromScale(0.5, 0.5)
		panel.Size = UDim2.fromOffset(SUMMARY_PANEL_W, SUMMARY_PANEL_H)
		panel.BackgroundColor3 = Color3.fromRGB(16, 26, 38)
		panel.BorderSizePixel = 0
		panel.ClipsDescendants = false
		panel.ZIndex = 2
		panel.Parent = g
		UiPopupScale.attach(panel)
		local pc = Instance.new("UICorner")
		pc.CornerRadius = UDim.new(0, SUMMARY_CORNER)
		pc.Parent = panel
		local edge = Instance.new("UIStroke")
		styleSummaryEdge(edge)
		edge.Color = Color3.fromHSV(0, 1, 1)
		edge.Parent = panel
		summaryStroke = edge

		ensureSummaryPanelContent(panel)
	end

	local g = summaryGui :: ScreenGui
	g.Enabled = true
	g.ClipToDeviceSafeArea = false
	local dim = g:FindFirstChild("Dim")
	if dim and dim:IsA("GuiObject") then
		dim.Visible = true
	end
	local panel = g:FindFirstChild("Panel")
	if panel and panel:IsA("Frame") then
		panel.ClipsDescendants = false
		UiPopupScale.attach(panel)
		local corner = panel:FindFirstChildOfClass("UICorner")
		if corner then
			corner.CornerRadius = UDim.new(0, SUMMARY_CORNER)
		end
		local edge = panel:FindFirstChild("SummaryEdge")
		if edge and edge:IsA("UIStroke") then
			styleSummaryEdge(edge)
			summaryStroke = edge
		elseif not summaryStroke then
			local stroke = Instance.new("UIStroke")
			styleSummaryEdge(stroke)
			stroke.Color = Color3.fromHSV(0, 1, 1)
			stroke.Parent = panel
			summaryStroke = stroke
		end
		ensureSummaryPanelContent(panel)
		WaveSummaryUi.fillStats(panel, summary, records, openReefHealthFromSummary)
		panel.Visible = true
		summaryScaleToken += 1
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
		local startX = if origin then origin.X / vp.X else 0.92
		local startY = if origin then origin.Y / vp.Y else 0.55
		panel.Position = UDim2.fromScale(startX, startY)
		panel.Size = UDim2.fromOffset(48, 28)
		TweenService:Create(panel, SUMMARY_SCALE_IN, {
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(SUMMARY_PANEL_W, SUMMARY_PANEL_H),
		}):Play()
		playConfetti(panel)
		startSummaryStrokeCycle()
	end

	-- Joystick: only CONTINUE ↔ FINISH (lock every other Selectable in PlayerGui).
	if isUsingGamepad() and continueBtn and finishBtn then
		prevGuiSelected = GuiService.SelectedObject
		beginSummaryGamepadNav()
	end
end

local function toggleWaves()
	if summaryOpen then
		return
	end
	if stopConfirmActive then
		return
	end
	-- Don't start/stop from Slot5 while backpack chrome is up (accidental focus/clicks).
	if InventoryState.isOpen() then
		return
	end
	if WaveSim.isRunning() then
		WaveSlot.beginStopConfirm()
		return
	end
	local ok = WaveSim.start()
	if ok then
		applyIcon(true)
		deps.log("Waves started")
	else
		deps.log("Waves failed to start (route/fish?)")
	end
end

function WaveSlot.isStopConfirmActive(): boolean
	return stopConfirmActive
end

function WaveSlot.hideStopConfirm()
	if not stopConfirmActive and not (stopConfirmGui and stopConfirmGui.Enabled) then
		return
	end
	stopConfirmActive = false
	stopScaleToken += 1
	local my = stopScaleToken
	if stopTitleFlashConn then
		stopTitleFlashConn:Disconnect()
		stopTitleFlashConn = nil
	end
	local sel = GuiService.SelectedObject
	if (stopConfirmCheck and sel == stopConfirmCheck) or (stopConfirmCancel and sel == stopConfirmCancel) then
		GuiService.SelectedObject = stopPrevGuiSelected
	end
	stopPrevGuiSelected = nil
	if stopConfirmDim then
		stopConfirmDim.Visible = false
	end
	if stopConfirmPanel and stopConfirmPanel.Visible and slot5 then
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
		local btnPos = slot5.AbsolutePosition
		local btnSize = slot5.AbsoluteSize
		local endX = (btnPos.X + btnSize.X * 0.5) / vp.X
		local endY = (btnPos.Y + btnSize.Y * 0.5) / vp.Y
		local tw = TweenService:Create(stopConfirmPanel, STOP_SCALE_OUT, {
			Position = UDim2.fromScale(endX, endY),
			Size = UDim2.fromOffset(40, 40),
		})
		tw:Play()
		tw.Completed:Connect(function()
			if my ~= stopScaleToken then
				return
			end
			if stopConfirmPanel then
				stopConfirmPanel.Visible = false
			end
			if stopConfirmGui then
				stopConfirmGui.Enabled = false
			end
		end)
	else
		if stopConfirmPanel then
			stopConfirmPanel.Visible = false
		end
		if stopConfirmGui then
			stopConfirmGui.Enabled = false
		end
	end
end

function WaveSlot.cancelStopConfirm()
	if not stopConfirmActive then
		return
	end
	WaveSlot.hideStopConfirm()
	deps.log("Stop waves confirm cancelled")
end

local function ensureStopConfirmUi()
	if stopConfirmGui and stopConfirmPanel and stopConfirmCheck and stopConfirmCancel then
		return
	end
	local g = Instance.new("ScreenGui")
	g.Name = "OceanTD_StopWaveConfirm"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 12065
	g.Enabled = false
	g.Parent = deps.playerGui
	stopConfirmGui = g

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.45
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Visible = false
	dim.Active = true
	dim.ZIndex = 1
	dim.Parent = g
	stopConfirmDim = dim
	dim.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if os.clock() - stopConfirmOpenedAt < 0.35 then
				return
			end
			WaveSlot.cancelStopConfirm()
		end
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(STOP_PANEL_W, STOP_PANEL_H)
	panel.BackgroundColor3 = Color3.fromRGB(18, 28, 40)
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.ZIndex = 2
	panel.Active = true
	panel.Parent = g
	stopConfirmPanel = panel
	UiPopupScale.attach(panel)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(180, 80, 90)
	stroke.Thickness = 2
	stroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 18)
	title.Size = UDim2.new(1, -32, 0, 40)
	title.Font = UiTheme.Font
	title.Text = "End This Run"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextScaled = true
	title.ZIndex = 3
	title.Parent = panel
	stopConfirmTitle = title

	local body = Instance.new("TextLabel")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(16, 70)
	body.Size = UDim2.new(1, -32, 0, 56)
	body.Font = UiTheme.Font
	body.Text = "Finish Wave Mode Now"
	body.TextColor3 = Color3.fromRGB(170, 190, 210)
	body.TextScaled = true
	body.TextWrapped = true
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.ZIndex = 3
	body.Parent = panel

	local function makeWideBtn(text: string, color: Color3, strokeColor: Color3): TextButton
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.42, 0, 0, 42)
		b.BackgroundColor3 = color
		b.Font = UiTheme.Font
		b.Text = text
		b.TextColor3 = Color3.new(1, 1, 1)
		b.TextScaled = true
		b.AutoButtonColor = true
		b.Selectable = true
		b.ZIndex = 4
		b.Parent = panel
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 10)
		c.Parent = b
		local edge = Instance.new("UIStroke")
		edge.Color = strokeColor
		edge.Thickness = 2.5
		edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		edge.Parent = b
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.12, 0)
		pad.PaddingBottom = UDim.new(0.12, 0)
		pad.PaddingLeft = UDim.new(0.08, 0)
		pad.PaddingRight = UDim.new(0.08, 0)
		pad.Parent = b
		return b
	end

	stopConfirmCheck = makeWideBtn("CONFIRM", deps.green, Color3.fromRGB(12, 70, 28))
	stopConfirmCancel = makeWideBtn("CANCEL", deps.red, Color3.fromRGB(90, 12, 18))
	stopConfirmCheck.AnchorPoint = Vector2.new(0, 1)
	stopConfirmCheck.Position = UDim2.new(0, 20, 1, -18)
	stopConfirmCancel.AnchorPoint = Vector2.new(1, 1)
	stopConfirmCancel.Position = UDim2.new(1, -20, 1, -18)
	stopConfirmCheck.NextSelectionRight = stopConfirmCancel
	stopConfirmCancel.NextSelectionLeft = stopConfirmCheck
	stopConfirmCheck.Activated:Connect(function()
		WaveSlot.commitStopConfirm()
	end)
	stopConfirmCancel.Activated:Connect(function()
		WaveSlot.cancelStopConfirm()
	end)
end

function WaveSlot.commitStopConfirm()
	if not stopConfirmActive then
		return
	end
	WaveSlot.hideStopConfirm()
	UiHaptics.pulseShort()
	WaveSim.stop()
	deps.log("Waves stopped")
end

function WaveSlot.handleStopPrimaryConfirm()
	if not stopConfirmActive then
		return
	end
	local sel = GuiService.SelectedObject
	if stopConfirmCancel and sel == stopConfirmCancel then
		WaveSlot.cancelStopConfirm()
		return
	end
	WaveSlot.commitStopConfirm()
end

function WaveSlot.beginStopConfirm()
	if stopConfirmActive then
		return
	end
	if not WaveSim.isRunning() then
		return
	end
	if InventoryState.isOpen() or summaryOpen then
		return
	end
	ensureStopConfirmUi()
	stopConfirmOpenedAt = os.clock()
	stopConfirmActive = true
	stopScaleToken += 1
	if stopConfirmGui then
		stopConfirmGui.Enabled = true
	end
	if stopConfirmDim then
		stopConfirmDim.Visible = true
	end
	if stopConfirmPanel then
		UiPopupScale.attach(stopConfirmPanel)
		stopConfirmPanel.Visible = true
		if slot5 then
			local cam = Workspace.CurrentCamera
			local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
			local btnPos = slot5.AbsolutePosition
			local btnSize = slot5.AbsoluteSize
			local startX = (btnPos.X + btnSize.X * 0.5) / vp.X
			local startY = (btnPos.Y + btnSize.Y * 0.5) / vp.Y
			stopConfirmPanel.Position = UDim2.fromScale(startX, startY)
			stopConfirmPanel.Size = UDim2.fromOffset(40, 40)
			TweenService:Create(stopConfirmPanel, STOP_SCALE_IN, {
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(STOP_PANEL_W, STOP_PANEL_H),
			}):Play()
		else
			stopConfirmPanel.Position = UDim2.fromScale(0.5, 0.5)
			stopConfirmPanel.Size = UDim2.fromOffset(STOP_PANEL_W, STOP_PANEL_H)
		end
	end
	if stopTitleFlashConn then
		stopTitleFlashConn:Disconnect()
		stopTitleFlashConn = nil
	end
	if stopConfirmTitle then
		local t0 = os.clock()
		stopTitleFlashConn = RunService.RenderStepped:Connect(function()
			if not stopConfirmActive or not stopConfirmTitle then
				return
			end
			local wave = (math.sin((os.clock() - t0) * 7) + 1) * 0.5
			stopConfirmTitle.TextColor3 = Color3.new(1, 1, 1):Lerp(HELP_RED, wave)
		end)
	end
	if isUsingGamepad() and stopConfirmCheck then
		stopPrevGuiSelected = GuiService.SelectedObject
		GuiService.SelectedObject = stopConfirmCheck
	end
	deps.log("Stop waves confirm")
end

function WaveSlot.toggle()
	toggleWaves()
end

function WaveSlot.isSummaryOpen(): boolean
	return summaryOpen
end

function WaveSlot.mount(d: Deps)
	deps = d
	syncWaveHudToActiveRightHud()
	local quickbar = deps.mainHUD:FindFirstChild("Quickbar")
	local found = if quickbar then quickbar:FindFirstChild("Slot5") else nil
	if found and found:IsA("GuiObject") then
		slot5 = found
		slot5Button = d.ensureButton(slot5)
		d.passthroughDecor(slot5, slot5Button)
		slot5Circle = d.ensureCircle(slot5)
		UiCircles.forceOnDescendants(slot5)
		applyIcon(false)
		d.ensureStroke(slot5Circle, "_OceanTD_WaveRing", Color3.new(1, 1, 1), 2).Enabled = false
		slot5Button.Selectable = false
		if slot5Button:GetAttribute("_OceanTD_ActBound") ~= true then
			slot5Button:SetAttribute("_OceanTD_ActBound", true)
			slot5Button.Activated:Connect(function()
				WaveSlot.toggle()
			end)
		end
		d.log("Slot5 wave button ready on", deps.mainHUD.Name)
	else
		warn("[WAVE] MainHUD.Quickbar.Slot5 missing — wave button unavailable")
	end

	local quickbarHelp = d.mainHUD:FindFirstChild("QuickbarHelp")
	if quickbarHelp then
		local hs = quickbarHelp:FindFirstChild("Slot5")
		if hs and hs:IsA("GuiObject") then
			helpSlot5 = hs
			helpSlot5.Active = false
			helpSlot5.Selectable = false
			for _, desc in ipairs(helpSlot5:GetDescendants()) do
				if desc:IsA("GuiObject") then
					desc.Active = false
					desc.Selectable = false
				end
			end
			local existingLetter = helpSlot5:FindFirstChild("_OceanTD_HelpLetter")
			if existingLetter and existingLetter:IsA("TextLabel") then
				helpSlot5Letter = existingLetter
			else
				if existingLetter then
					existingLetter:Destroy()
				end
				local letter = Instance.new("TextLabel")
				letter.Name = "_OceanTD_HelpLetter"
				letter.BackgroundTransparency = 1
				letter.Size = UDim2.fromScale(1, 1)
				letter.Font = UiTheme.Font
				letter.TextScaled = true
				letter.TextColor3 = Color3.new(1, 1, 1)
				letter.ZIndex = helpSlot5.ZIndex + 5
				letter.Parent = helpSlot5
				local pad = Instance.new("UIPadding")
				pad.PaddingTop = UDim.new(0.18, 0)
				pad.PaddingBottom = UDim.new(0.18, 0)
				pad.Parent = letter
				helpSlot5Letter = letter
			end
			UiCircles.ensure(helpSlot5)
			-- Optional hit proxy for badge click → same as Slot5
			local hit = helpSlot5:FindFirstChild("_OceanTD_HelpHit")
			if hit and hit:IsA("GuiButton") then
				helpHit = hit
			else
				if hit then
					hit:Destroy()
				end
				local btn = Instance.new("TextButton")
				btn.Name = "_OceanTD_HelpHit"
				btn.BackgroundTransparency = 1
				btn.Text = ""
				btn.Size = UDim2.fromScale(1, 1)
				btn.ZIndex = helpSlot5.ZIndex + 6
				btn.Parent = helpSlot5
				helpHit = btn
			end
			helpHit.Selectable = false
			if helpHit:GetAttribute("_OceanTD_ActBound") ~= true then
				helpHit:SetAttribute("_OceanTD_ActBound", true)
				helpHit.Activated:Connect(function()
					toggleWaves()
				end)
			end
		end
	end

	WaveSlot.refreshHelpBadge()
	ensureHud()
	setSlot5Interactable(not InventoryState.isOpen())
	InventoryState.onOpenChanged(function(isOpen)
		setSlot5Interactable(not isOpen)
		WaveSlot.refreshHelpBadge()
		if isOpen and WaveSlot.isReefHealOpen() then
			WaveSlot.cancelReefHeal()
		end
	end)
	Players.LocalPlayer.PlayerGui:GetAttributeChangedSignal("OceanTD_SkillsBubblesOpen"):Connect(function()
		local skillsOpen = Players.LocalPlayer.PlayerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true
		if skillsOpen then
			if slot5 then
				slot5.Visible = false
			end
			WaveSlot.refreshHelpBadge()
			if hudFrame then
				hudFrame.Visible = false
			end
		else
			if slot5 then
				slot5.Visible = true
			end
			WaveSlot.refreshHelpBadge()
			if WaveSim.isRunning() then
				setHudVisible(true)
			end
			resumeSummaryAfterSkills()
		end
	end)

	WaveSim.onHud(updateHud)
	WaveSim.onStopped(function(summary)
		setWaveCameraActive(false)
		applyIcon(false)
		if stopConfirmActive then
			WaveSlot.hideStopConfirm()
		end
		if WaveSlot.isReefHealOpen() then
			WaveSlot.hideReefHeal()
		end
		if not summaryOpen then
			showSummary(summary)
		end
	end)

	deps.playerGui:GetAttributeChangedSignal("OceanTD_RestoreWaveCam"):Connect(function()
		if userCamCycleBusy() then
			return
		end
		local cam = Workspace.CurrentCamera
		local char = Players.LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if cam and hum then
			cam.CameraSubject = hum
			if cam.CameraType == Enum.CameraType.Scriptable then
				cam.CameraType = Enum.CameraType.Custom
			end
		end
		-- Follow/standard mode: never re-apply wave CameraOffset.
		if waveCamConn then
			setWaveCameraActive(false)
		else
			clearWaveCameraOffset()
		end
	end)

	deps.playerGui:GetAttributeChangedSignal("OceanTD_CamCycleMode"):Connect(function()
		if userCamCycleBusy() then
			if waveCamConn then
				setWaveCameraActive(false)
			end
			return
		end
		-- Returning to follow/standard during a wave: keep offset cleared.
		clearWaveCameraOffset()
		if waveCamConn then
			setWaveCameraActive(false)
		end
	end)

	UserInputService.LastInputTypeChanged:Connect(function()
		WaveSlot.refreshHelpBadge()
	end)
end

return WaveSlot
