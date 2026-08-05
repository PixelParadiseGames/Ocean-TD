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

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local WaveSlot = {}

local START_ICON = "rbxassetid://74802566438233"
local STOP_ICON = "rbxassetid://96580667427806"
local HELP_GREEN = Color3.fromRGB(40, 180, 80)
local HELP_RED = Color3.fromRGB(200, 45, 50)
local FINISH_GREEN = Color3.fromRGB(40, 180, 80)
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
local hudWaveStroke: UIStroke? = nil
local hudBarFork: TextLabel? = nil
local hudBarHeart: TextLabel? = nil
local hudBarHeartScale: UIScale? = nil
local hudFinishHint: TextLabel? = nil
local hudReef: TextLabel? = nil
local hudTime: TextLabel? = nil
local hudLayoutConn: RBXScriptConnection? = nil
local finishFlashToken = 0
local feedCompleteUi = false
local heartHidden = false
local heartHiddenWave = 0
local lastHungryMissToken = -1
local fillHurtToken = 0
local forkCycleToken = 0
local forkShowCount = false
local lastFishFull = 0
local lastFishTotal = 0

local BAR_BG = Color3.fromRGB(0x9e, 0x0b, 0x00)
local BAR_FILL = Color3.fromRGB(0x12, 0xd9, 0x00)
local BAR_DANGER_BG = Color3.fromRGB(255, 40, 45)
local FLASH_BRIGHT = Color3.fromRGB(90, 255, 90)
local FLASH_DARK = Color3.fromRGB(0, 110, 35)
local LINE_H = 28
local BAR_H = 26
local LABEL_TEXT_SIZE = math.floor(15 * 1.25 + 0.5) -- 25% bigger
local FORK_COUNT_TEXT_SIZE = math.max(1, LABEL_TEXT_SIZE - 2)
local HEART_HIDE_AT = 0.95
local FORK_SHOW_AT = 0.05
local SIDE_ICON_PAD = 6
local BAR_TOP_GAP = 20

local summaryGui: ScreenGui? = nil
local summaryOpen = false
local finishBtn: TextButton? = nil
local prevGuiSelected: GuiObject? = nil
local confettiConn: RBXScriptConnection? = nil
local confettiToken = 0
local waveCamConn: RBXScriptConnection? = nil
local waveCamCharConn: RBXScriptConnection? = nil

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

local function applyWaveCameraOffset()
	local char = Players.LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		hum.CameraOffset = Vector3.new(0, 3, 0)
		return
	end
	local dist = (cam.CFrame.Position - cam.Focus.Position).Magnitude
	if dist < 1 then
		dist = 12.5
	end
	local halfH = dist * math.tan(math.rad(cam.FieldOfView) * 0.5)
	-- 20% of full vertical view in studs at the focus distance.
	hum.CameraOffset = Vector3.new(0, halfH * (WAVE_CAM_SCREEN_SHIFT * 2), 0)
end

local function setWaveCameraActive(on: boolean)
	if on then
		if waveCamConn then
			return
		end
		waveCamConn = RunService.RenderStepped:Connect(applyWaveCameraOffset)
		if not waveCamCharConn then
			waveCamCharConn = Players.LocalPlayer.CharacterAdded:Connect(function()
				task.defer(applyWaveCameraOffset)
			end)
		end
		applyWaveCameraOffset()
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
	if feedCompleteUi then
		hudBarFork.Text = "🍴100%"
		hudBarFork.TextSize = FORK_COUNT_TEXT_SIZE
		return
	end
	if forkShowCount then
		hudBarFork.Text = string.format("%d of %d", lastFishFull, lastFishTotal)
		hudBarFork.TextSize = FORK_COUNT_TEXT_SIZE
	else
		hudBarFork.Text = "🍴"
		hudBarFork.TextSize = LABEL_TEXT_SIZE
	end
end

local function stopForkCycle()
	forkCycleToken += 1
	forkShowCount = false
	refreshForkLabel()
end

local function startForkCycle()
	if feedCompleteUi then
		stopForkCycle()
		return
	end
	forkCycleToken += 1
	local my = forkCycleToken
	forkShowCount = false
	refreshForkLabel()
	task.spawn(function()
		while my == forkCycleToken do
			task.wait(3)
			if my ~= forkCycleToken then
				break
			end
			forkShowCount = not forkShowCount
			refreshForkLabel()
		end
	end)
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
		lbl.TextSize = 28
		lbl.AnchorPoint = Vector2.new(0.5, 0.5)
		lbl.Position = UDim2.fromOffset(ox, oy)
		lbl.Size = UDim2.fromOffset(36, 36)
		lbl.ZIndex = 81
		lbl.Parent = layer
		local scale = Instance.new("UIScale")
		scale.Scale = 0.15
		scale.Parent = lbl

		local angle = rng:NextNumber(0, math.pi * 2)
		local speed = rng:NextNumber(220, 520)
		local vx = math.cos(angle) * speed
		local vy = math.sin(angle) * speed - rng:NextNumber(80, 220)
		local grav = rng:NextNumber(780, 1100)
		local life = rng:NextNumber(1.15, 1.85)
		local popAt = rng:NextNumber(0.12, 0.28)
		local x = ox
		local y = oy
		task.spawn(function()
			local t0 = os.clock()
			local popped = false
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
				if not popped and age >= popAt then
					popped = true
					scale.Scale = 1.55
				elseif popped then
					scale.Scale = 1.55 + (1.05 - 1.55) * math.clamp((age - popAt) / 0.2, 0, 1)
				else
					scale.Scale = 0.15 + (1.2 - 0.15) * (age / popAt)
				end
				lbl.TextTransparency = math.clamp((age - life * 0.65) / (life * 0.35), 0, 1)
			end
			if lbl.Parent then
				lbl:Destroy()
			end
		end)
	end
	task.delay(2.4, function()
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

local function ensureHud()
	if hudFrame then
		return
	end
	local f = Instance.new("Frame")
	f.Name = "OceanTD_WaveHud"
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Visible = false
	f.ZIndex = 25
	f.Size = UDim2.fromOffset(220, LINE_H * 3)
	f.Parent = deps.mainHUD
	hudFrame = f

	local bar = Instance.new("Frame")
	bar.Name = "WaveProgress"
	bar.BackgroundColor3 = BAR_BG
	bar.BackgroundTransparency = 0.5
	bar.BorderSizePixel = 0
	bar.Size = UDim2.new(1, -4, 0, BAR_H)
	bar.Position = UDim2.fromOffset(0, 0)
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
	label.Text = "🌊Wave1"
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
	hudBarFork = mkSide("Fork", "🍴", Enum.TextXAlignment.Left)
	hudBarHeart = mkSide("BrokenHeart", "-💔", Enum.TextXAlignment.Right)
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

	local function mk(name: string, order: number): TextLabel
		local t = Instance.new("TextLabel")
		t.Name = name
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(1, -4, 0, LINE_H)
		t.Position = UDim2.fromOffset(0, BAR_H + 4 + (order - 2) * LINE_H)
		t.Font = UiTheme.Font
		t.TextSize = 15
		t.TextColor3 = Color3.new(1, 1, 1)
		t.TextStrokeTransparency = 0.35
		t.TextStrokeColor3 = Color3.new(0, 0, 0)
		t.TextXAlignment = Enum.TextXAlignment.Right
		t.TextYAlignment = Enum.TextYAlignment.Center
		t.TextTruncate = Enum.TextTruncate.None
		t.ZIndex = 26
		t.Parent = f
		return t
	end
	hudReef = mk("Reef", 2)
	hudTime = mk("Time", 3)
end

local function layoutHud()
	if not hudFrame or not slot5 then
		return
	end
	local parent = deps.mainHUD
	local slotPos = slot5.AbsolutePosition
	local slotSize = slot5.AbsoluteSize
	local parentPos = parent.AbsolutePosition
	local w = math.max(240, slotSize.X + 120)
	local h = BAR_H + 4 + LINE_H * 2
	local x = (slotPos.X + slotSize.X) - parentPos.X - w
	local y = (slotPos.Y + slotSize.Y + BAR_TOP_GAP) - parentPos.Y
	hudFrame.Size = UDim2.fromOffset(w, h)
	hudFrame.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
end

local function setHudVisible(on: boolean)
	ensureHud()
	local wasVisible = hudFrame ~= nil and hudFrame.Visible
	if hudFrame then
		hudFrame.Visible = on
	end
	if on then
		layoutHud()
		if not wasVisible then
			startForkCycle()
		end
		if not hudLayoutConn then
			hudLayoutConn = RunService.RenderStepped:Connect(function()
				if hudFrame and hudFrame.Visible then
					layoutHud()
				end
			end)
		end
	else
		if hudLayoutConn then
			hudLayoutConn:Disconnect()
			hudLayoutConn = nil
		end
		feedCompleteUi = false
		hungerDangerUi = false
		heartHidden = false
		heartHiddenWave = 0
		lastHungryMissToken = -1
		fillHurtToken += 1
		stopForkCycle()
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
			hudBarFork.Visible = false
		end
		if hudBarHeart then
			hudBarHeart.Visible = true
		end
		if hudFinishHint then
			hudFinishHint.Visible = false
		end
		if hudWaveHit then
			hudWaveHit.Visible = false
			hudWaveHit.Active = false
		end
	end
end

local function updateHud(snap: WaveSim.HudSnapshot)
	ensureHud()
	if not snap.running then
		setHudVisible(false)
		setWaveCameraActive(false)
		return
	end
	setWaveCameraActive(true)
	setHudVisible(true)
	local prog = math.clamp(snap.feedProgress or 0, 0, 1)
	if hudWaveFill then
		hudWaveFill.Size = UDim2.fromScale(prog, 1)
	end
	if snap.wave ~= heartHiddenWave then
		heartHiddenWave = snap.wave
		heartHidden = false
	end
	if not heartHidden and prog >= HEART_HIDE_AT then
		heartHidden = true
	end
	lastFishFull = snap.fishFull or 0
	lastFishTotal = snap.fishTotal or 0
	if forkShowCount then
		refreshForkLabel()
	end
	if hudBarFork then
		hudBarFork.Visible = prog >= FORK_SHOW_AT
	end
	if hudBarHeart then
		hudBarHeart.Visible = not heartHidden
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
	local complete = snap.feedComplete == true
	local danger = snap.hungerDanger == true
	if hudWaveLabel then
		if complete then
			hudWaveLabel.Text = "FINISH WAVE " .. tostring(snap.wave)
		else
			hudWaveLabel.Text = "🌊 Wave " .. tostring(snap.wave)
		end
	end
	if complete ~= feedCompleteUi then
		feedCompleteUi = complete
		if complete then
			hungerDangerUi = false
			stopDangerFlash()
			stopForkCycle()
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
			startForkCycle()
			if danger then
				hungerDangerUi = true
				startDangerFlash()
			end
		end
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
	if hudReef then
		hudReef.Text = "❤️Reef Health " .. tostring(snap.reefHealth)
	end
	if hudTime then
		hudTime.Text = "⏱️" .. WaveSim.formatClock(snap.elapsedSec)
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

local function hideSummary()
	summaryOpen = false
	stopConfetti()
	if summaryGui then
		summaryGui.Enabled = false
	end
	local sel = GuiService.SelectedObject
	if finishBtn and sel == finishBtn then
		GuiService.SelectedObject = prevGuiSelected
	end
	prevGuiSelected = nil
end

function WaveSlot.dismissSummary()
	if summaryOpen then
		hideSummary()
	end
end

local function showSummary(summary: WaveSim.Summary)
	summaryOpen = true
	setHudVisible(false)
	applyIcon(false)

	if not summaryGui then
		local g = Instance.new("ScreenGui")
		g.Name = "OceanTD_WaveSummary"
		g.ResetOnSpawn = false
		g.IgnoreGuiInset = true
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
		panel.Size = UDim2.fromOffset(420, 280)
		panel.BackgroundColor3 = Color3.fromRGB(16, 26, 38)
		panel.BorderSizePixel = 0
		panel.ZIndex = 2
		panel.Parent = g
		local pc = Instance.new("UICorner")
		pc.CornerRadius = UDim.new(0, 16)
		pc.Parent = panel

		local title = Instance.new("TextLabel")
		title.Name = "WaveReached"
		title.BackgroundTransparency = 1
		title.Position = UDim2.fromOffset(16, 36)
		title.Size = UDim2.new(1, -32, 0, 48)
		title.Font = UiTheme.Font
		title.TextSize = 36
		title.TextColor3 = Color3.new(1, 1, 1)
		title.TextXAlignment = Enum.TextXAlignment.Center
		title.ZIndex = 3
		title.Parent = panel

		local fed = Instance.new("TextLabel")
		fed.Name = "FishFed"
		fed.BackgroundTransparency = 1
		fed.Position = UDim2.fromOffset(16, 96)
		fed.Size = UDim2.new(1, -32, 0, 32)
		fed.Font = UiTheme.Font
		fed.TextSize = 24
		fed.TextColor3 = Color3.new(1, 1, 1)
		fed.TextXAlignment = Enum.TextXAlignment.Center
		fed.ZIndex = 3
		fed.Parent = panel

		local lasted = Instance.new("TextLabel")
		lasted.Name = "Lasted"
		lasted.BackgroundTransparency = 1
		lasted.Position = UDim2.fromOffset(16, 140)
		lasted.Size = UDim2.new(1, -32, 0, 28)
		lasted.Font = UiTheme.Font
		lasted.TextSize = 22
		lasted.TextColor3 = Color3.new(1, 1, 1)
		lasted.TextXAlignment = Enum.TextXAlignment.Center
		lasted.ZIndex = 3
		lasted.Parent = panel

		local finish = Instance.new("TextButton")
		finish.Name = "Finish"
		finish.AnchorPoint = Vector2.new(0.5, 1)
		finish.Position = UDim2.new(0.5, 0, 1, -18)
		finish.Size = UDim2.fromOffset(200, 44)
		finish.BackgroundColor3 = FINISH_GREEN
		finish.Font = UiTheme.Font
		finish.Text = "FINISH"
		finish.TextColor3 = Color3.new(1, 1, 1)
		finish.TextSize = 22
		finish.AutoButtonColor = true
		finish.Selectable = true
		finish.ZIndex = 4
		finish.Parent = panel
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(0, 10)
		fc.Parent = finish
		finish.Activated:Connect(function()
			hideSummary()
		end)
		finishBtn = finish
	end

	local g = summaryGui :: ScreenGui
	g.Enabled = true
	local panel = g:FindFirstChild("Panel")
	if panel and panel:IsA("Frame") then
		local title = panel:FindFirstChild("WaveReached")
		local fed = panel:FindFirstChild("FishFed")
		local lasted = panel:FindFirstChild("Lasted")
		if title and title:IsA("TextLabel") then
			title.Text = "Wave " .. tostring(summary.waveReached)
		end
		if fed and fed:IsA("TextLabel") then
			fed.Text = "Fish Fed " .. tostring(summary.fishFed)
		end
		if lasted and lasted:IsA("TextLabel") then
			lasted.Text = WaveSim.formatClock(summary.elapsedSec)
		end
		playConfetti(panel)
	end

	-- Joystick: select FINISH so A activates it immediately.
	if not finishBtn and panel then
		local found = panel:FindFirstChild("Finish")
		if found and found:IsA("TextButton") then
			finishBtn = found
			finishBtn.Selectable = true
		end
	end
	if isUsingGamepad() and finishBtn then
		prevGuiSelected = GuiService.SelectedObject
		GuiService.SelectedObject = finishBtn
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
	local quickbar = d.mainHUD:FindFirstChild("Quickbar")
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
		slot5Button.Activated:Connect(function()
			toggleWaves()
		end)
		d.log("Slot5 wave button ready")
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
			helpHit.Activated:Connect(function()
				toggleWaves()
			end)
		end
	end

	WaveSlot.refreshHelpBadge()
	ensureHud()
	setSlot5Interactable(not InventoryState.isOpen())
	InventoryState.onOpenChanged(function(isOpen)
		setSlot5Interactable(not isOpen)
		WaveSlot.refreshHelpBadge()
	end)

	WaveSim.onHud(updateHud)
	WaveSim.onStopped(function(summary)
		setWaveCameraActive(false)
		applyIcon(false)
		if stopConfirmActive then
			WaveSlot.hideStopConfirm()
		end
		if not summaryOpen then
			showSummary(summary)
		end
	end)

	UserInputService.LastInputTypeChanged:Connect(function()
		WaveSlot.refreshHelpBadge()
	end)
end

return WaveSlot
