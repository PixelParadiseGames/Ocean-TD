--!strict
--[[
	Slot7 Wave Speed — slides out from under Slot5 while waves run.
	Cycles 1x → 1.5x → 2x → pause (stage 4) → 1x. Shortcuts: T / L2.
	Stage 1: locked (red overlay) → opens Wave Speed powerup. Stage 2: up to 1.5x.
	Stage 3: up to 2x. Stage 4: pause after 2x. Help badge; idle text opposite Skip.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiIdleCycle = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiIdleCycle"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))

local WaveSpeedSlot = {}

local SLIDE_IN = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SLIDE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local IDLE_HALF_SEC = 2
local HELP_CYAN = Color3.fromRGB(60, 170, 230)
local ORBIT_GREEN = Color3.fromRGB(45, 210, 95)
local FLASH_GREEN = Color3.fromRGB(40, 220, 110)
local PAUSE_FLASH_YELLOW = Color3.fromRGB(255, 220, 40)
local PAUSE_FLASH_WHITE = Color3.new(1, 1, 1)
local PAUSE_FLASH_HALF_SEC = 0.4
-- Seconds per full revolution at speed steps 1 / 2 / 3 / pause (orbit frozen).
local ORBIT_PERIOD = { 2.4, 1.35, 0.75, 999 }
local ORBIT_DOT_SCALE = 0.13 -- fraction of button size
-- Radius so the dot center sits on the button rim.
local ORBIT_RADIUS = 0.5
local SPEED_SOUND_ID = "rbxassetid://135244211779631"
-- PlaybackSpeed for steps 1 / 2 / 3 / pause (low / med / high / low).
local SPEED_SOUND_PITCH = { 0.85, 1.05, 1.3, 0.7 }
local SPEED_LOCK_IMAGE = "rbxassetid://105420423737825"
local SPEED_LOCK_SIZE_PX = 17
local SPEED_LOCK_ORBIT_SPEED = 1.35
local SPEED_LOCK_ORBIT_FRAC = 0.42
local SPEED_LOCK_RED = Color3.fromRGB(220, 40, 45)

local ICON_1X = "rbxassetid://130235737024254"
local ICON_15X = "rbxassetid://93866614390396"
local ICON_2X = "rbxassetid://85700415632293"
local ICON_CROSSFADE = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Hold icon (incl. crossfade) before rejoining shared idle text clock.
local ICON_HOLD_SEC = 1

local speedSoundTemplate = Instance.new("Sound")
speedSoundTemplate.Name = "OceanTD_WaveSpeedSound"
speedSoundTemplate.SoundId = SPEED_SOUND_ID
speedSoundTemplate.Volume = 0.9
speedSoundTemplate.Parent = SoundService
task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ speedSoundTemplate })
	end)
end)

export type Deps = {
	mainHUD: ScreenGui,
	playerGui: PlayerGui,
	ensureButton: (GuiObject) -> GuiButton,
	passthroughDecor: (GuiObject, GuiButton) -> (),
	ensureCircle: (GuiObject) -> GuiObject,
	ensureStroke: (GuiObject, string, Color3, number) -> UIStroke,
	getShortcutMode: () -> string,
	log: (...any) -> (),
}

local deps: Deps
local slot7: GuiObject? = nil
local slot7Button: GuiButton? = nil
local slot7Circle: GuiObject? = nil
local slot7Stroke: UIStroke? = nil
local speedIcon: ImageLabel? = nil
local speedIconFade: ImageLabel? = nil -- outgoing icon during crossfade
local speedLabel: TextLabel? = nil
local orbitDot: Frame? = nil
local orbitConn: RBXScriptConnection? = nil
local orbitAngle = 0
local idleStop: UiIdleCycle.StopFn? = nil
local originalBg = Color3.fromRGB(20, 30, 45)
local originalBgTrans = 0.15
local homePos: UDim2? = nil
local helpSlot: GuiObject? = nil
local helpLetter: TextLabel? = nil
local helpHomePos: UDim2? = nil
local helpHit: GuiButton? = nil
local slot5: GuiObject? = nil
local helpSlot5: GuiObject? = nil
local slot7HomeZ = 1
local helpHomeZ = 1
local slideToken = 0
local clickFlashToken = 0
local iconFadeToken = 0
local iconFadeTweens: { Tween } = {}
local revealed = false
local hudUnsub: (() -> ())? = nil
local showingText = false
local iconFading = false
local pauseFlashToken = 0
local pauseFlashConn: RBXScriptConnection? = nil
local speedLockIcon: ImageLabel? = nil
local speedLockOverlay: Frame? = nil
local speedLockOrbitAngle = 0
local speedLockOrbitConn: RBXScriptConnection? = nil

local function waveSpeedStage(): number
	return SkillPowerUpUI.getStage("WaveSpeed")
end

local function needsSpeedUnlock(): boolean
	return SkillStages.waveSpeedLocked(waveSpeedStage())
end

local function stopSpeedLockOrbit()
	if speedLockOrbitConn then
		speedLockOrbitConn:Disconnect()
		speedLockOrbitConn = nil
	end
end

local function startSpeedLockOrbit(host: GuiObject)
	if speedLockOrbitConn then
		return
	end
	speedLockOrbitConn = RunService.Heartbeat:Connect(function(dt)
		local icon = speedLockIcon
		if not icon or not icon.Parent or not icon.Visible then
			return
		end
		speedLockOrbitAngle += SPEED_LOCK_ORBIT_SPEED * dt
		local abs = host.AbsoluteSize
		local radius = math.max(10, math.min(abs.X, abs.Y) * 0.5 * SPEED_LOCK_ORBIT_FRAC)
		local ox = math.cos(speedLockOrbitAngle) * radius
		local oy = math.sin(speedLockOrbitAngle) * radius
		icon.Position = UDim2.new(0.5, ox, 0.5, oy)
	end)
end

local function openWaveSpeedSkillUi()
	local pg = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
	if not pg then
		return
	end
	UiHaptics.pulseShort()
	pg:SetAttribute("OceanTD_ForceOpenSkillId", "WaveSpeed")
	pg:SetAttribute("OceanTD_ForceOpenSkills", os.clock())
	deps.log("Wave speed locked — opened Skills / Wave Speed")
end

local function syncSpeedLock()
	local host: GuiObject? = if slot7Circle and slot7Circle:IsA("GuiObject") then slot7Circle else slot7
	if not host then
		return
	end
	local show = revealed == true and needsSpeedUnlock()
	if show then
		local overlay = speedLockOverlay
		if not overlay or not overlay.Parent then
			overlay = Instance.new("Frame")
			overlay.Name = "OceanTD_SpeedLockOverlay"
			overlay.BackgroundColor3 = SPEED_LOCK_RED
			overlay.BackgroundTransparency = 0.5
			overlay.BorderSizePixel = 0
			overlay.Size = UDim2.fromScale(1, 1)
			overlay.Position = UDim2.fromScale(0, 0)
			overlay.Active = false
			overlay.ZIndex = host.ZIndex + 18
			overlay.Parent = host
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = overlay
			speedLockOverlay = overlay
		else
			overlay.Visible = true
			overlay.ZIndex = host.ZIndex + 18
		end

		local icon = speedLockIcon
		if not icon or not icon.Parent then
			icon = Instance.new("ImageLabel")
			icon.Name = "OceanTD_SpeedLock"
			icon.BackgroundTransparency = 1
			icon.Image = SPEED_LOCK_IMAGE
			icon.Size = UDim2.fromOffset(SPEED_LOCK_SIZE_PX, SPEED_LOCK_SIZE_PX)
			icon.AnchorPoint = Vector2.new(0.5, 0.5)
			icon.Position = UDim2.fromScale(0.5, 0.5)
			icon.Active = false
			icon.ZIndex = host.ZIndex + 22
			icon.Parent = host
			speedLockIcon = icon
			speedLockOrbitAngle = Random.new():NextNumber(0, math.pi * 2)
		else
			icon.Visible = true
			icon.Size = UDim2.fromOffset(SPEED_LOCK_SIZE_PX, SPEED_LOCK_SIZE_PX)
			icon.ZIndex = host.ZIndex + 22
		end
		startSpeedLockOrbit(host)
	else
		stopSpeedLockOrbit()
		if speedLockOverlay then
			speedLockOverlay.Visible = false
		end
		if speedLockIcon then
			speedLockIcon.Visible = false
		end
	end
end

local function speedStep(): number
	if WaveSim.isSpeedPaused() then
		return 4
	end
	local mult = WaveSim.getSpeedMult()
	if math.abs(mult - 1.5) < 1e-4 then
		return 2
	end
	if math.abs(mult - 2) < 1e-4 then
		return 3
	end
	return 1
end

local function iconForMult(mult: number): string
	if math.abs(mult - 1.5) < 1e-4 then
		return ICON_15X
	end
	if math.abs(mult - 2) < 1e-4 then
		return ICON_2X
	end
	return ICON_1X
end

local function placeOrbitDot(angle: number)
	if not orbitDot then
		return
	end
	local x = 0.5 + math.cos(angle) * ORBIT_RADIUS
	local y = 0.5 + math.sin(angle) * ORBIT_RADIUS
	orbitDot.Position = UDim2.fromScale(x, y)
end

local function stopOrbitAnim()
	if orbitConn then
		orbitConn:Disconnect()
		orbitConn = nil
	end
	if orbitDot then
		orbitDot.Visible = false
	end
end

local function startOrbitAnim()
	if not orbitDot or not revealed then
		return
	end
	if orbitConn then
		orbitConn:Disconnect()
		orbitConn = nil
	end
	orbitDot.Visible = true
	placeOrbitDot(orbitAngle)
	orbitConn = RunService.Heartbeat:Connect(function(dt)
		if not revealed or not orbitDot then
			return
		end
		if WaveSim.isSpeedPaused() then
			orbitDot.Visible = false
			return
		end
		if not orbitDot.Visible then
			orbitDot.Visible = true
		end
		local period = ORBIT_PERIOD[speedStep()] or ORBIT_PERIOD[1]
		orbitAngle += dt * (math.pi * 2) / period
		if orbitAngle > math.pi * 2 then
			orbitAngle %= (math.pi * 2)
		end
		placeOrbitDot(orbitAngle)
	end)
end

local function ensureOrbitLayers(circle: GuiObject)
	-- Keep circle Image clear so bg sits behind a dedicated icon child.
	if circle:IsA("ImageLabel") or circle:IsA("ImageButton") then
		(circle :: any).Image = ""
	end

	-- Remove legacy stripe visuals from the previous iteration.
	local legacy = circle:FindFirstChild("_OceanTD_SpeedStripeHost")
	if legacy then
		legacy:Destroy()
	end

	local icon = circle:FindFirstChild("_OceanTD_SpeedIcon")
	if icon and icon:IsA("ImageLabel") then
		speedIcon = icon
	else
		if icon then
			icon:Destroy()
		end
		local img = Instance.new("ImageLabel")
		img.Name = "_OceanTD_SpeedIcon"
		img.BackgroundTransparency = 1
		img.BorderSizePixel = 0
		img.Size = UDim2.fromScale(1, 1)
		img.Position = UDim2.fromScale(0, 0)
		img.ScaleType = Enum.ScaleType.Fit
		img.Active = false
		img.ZIndex = circle.ZIndex + 1
		img.Parent = circle
		UiCircles.ensure(img)
		speedIcon = img
	end

	-- Reused outgoing layer for 0.25s icon crossfades (no per-click alloc).
	local fade = circle:FindFirstChild("_OceanTD_SpeedIconFade")
	if fade and fade:IsA("ImageLabel") then
		speedIconFade = fade
	else
		if fade then
			fade:Destroy()
		end
		local img = Instance.new("ImageLabel")
		img.Name = "_OceanTD_SpeedIconFade"
		img.BackgroundTransparency = 1
		img.BorderSizePixel = 0
		img.Size = UDim2.fromScale(1, 1)
		img.Position = UDim2.fromScale(0, 0)
		img.ScaleType = Enum.ScaleType.Fit
		img.Active = false
		img.Visible = false
		img.ImageTransparency = 1
		img.ZIndex = circle.ZIndex + 2
		img.Parent = circle
		UiCircles.ensure(img)
		speedIconFade = img
	end
	speedIcon.ZIndex = circle.ZIndex + 1
	speedIconFade.ZIndex = circle.ZIndex + 2

	local dot = circle:FindFirstChild("_OceanTD_SpeedOrbit")
	if dot and dot:IsA("Frame") then
		orbitDot = dot
	else
		if dot then
			dot:Destroy()
		end
		local f = Instance.new("Frame")
		f.Name = "_OceanTD_SpeedOrbit"
		f.BackgroundColor3 = ORBIT_GREEN
		f.BackgroundTransparency = 0.05
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Size = UDim2.fromScale(ORBIT_DOT_SCALE, ORBIT_DOT_SCALE)
		f.Position = UDim2.fromScale(0.5, 0)
		f.Active = false
		f.Visible = false
		f.ZIndex = circle.ZIndex + 3
		f.Parent = circle
		UiCircles.ensure(f)
		orbitDot = f
	end
	orbitDot.Size = UDim2.fromScale(ORBIT_DOT_SCALE, ORBIT_DOT_SCALE)
	orbitDot.BackgroundColor3 = ORBIT_GREEN
	orbitDot.ZIndex = circle.ZIndex + 3
end
local function positionCenteredOn(target: GuiObject, mover: GuiObject): UDim2
	local parent = mover.Parent
	if not parent or not parent:IsA("GuiObject") then
		return mover.Position
	end
	local size = mover.AbsoluteSize
	if size.X < 1 or size.Y < 1 then
		size = Vector2.new(math.max(1, mover.Size.X.Offset), math.max(1, mover.Size.Y.Offset))
	end
	local center = target.AbsolutePosition + target.AbsoluteSize * 0.5
	local absTopLeft = center - size * 0.5
	local localTopLeft = absTopLeft - parent.AbsolutePosition
	local ap = mover.AnchorPoint
	return UDim2.fromOffset(
		math.floor(localTopLeft.X + size.X * ap.X + 0.5),
		math.floor(localTopLeft.Y + size.Y * ap.Y + 0.5)
	)
end

local function underSlot5Pos(): UDim2
	if slot5 and slot7 then
		return positionCenteredOn(slot5, slot7)
	end
	return homePos or UDim2.new()
end

local function underHelpSlot5Pos(): UDim2
	if helpSlot5 and helpSlot then
		return positionCenteredOn(helpSlot5, helpSlot)
	end
	return helpHomePos or UDim2.new()
end

local function applyIconVisual()
	if not slot7Circle then
		return
	end
	if slot7Circle:IsA("ImageLabel") or slot7Circle:IsA("ImageButton") then
		(slot7Circle :: any).Image = ""
	end
	slot7Circle.BackgroundColor3 = originalBg
	slot7Circle.BackgroundTransparency = originalBgTrans
	if speedIconFade then
		speedIconFade.Visible = false
		speedIconFade.ImageTransparency = 1
	end
	if WaveSim.isSpeedPaused() then
		if speedIcon then
			speedIcon.Visible = false
		end
		if speedLabel then
			speedLabel.Text = "WAVE\nSPEED"
			speedLabel.TextColor3 = PAUSE_FLASH_WHITE
			speedLabel.Visible = true
		end
		if orbitDot then
			orbitDot.Visible = false
		end
		showingText = true
		return
	end
	local img = iconForMult(WaveSim.getSpeedMult())
	if speedIcon then
		speedIcon.Image = img
		speedIcon.ImageTransparency = 0
		speedIcon.Visible = true
	end
	if speedLabel then
		speedLabel.Visible = false
	end
	showingText = false
end

local function applyTextVisual()
	if not slot7Circle or iconFading then
		return
	end
	if WaveSim.isSpeedPaused() then
		applyIconVisual()
		return
	end
	if slot7Circle:IsA("ImageLabel") or slot7Circle:IsA("ImageButton") then
		(slot7Circle :: any).Image = ""
	end
	slot7Circle.BackgroundColor3 = Color3.new(0, 0, 0)
	slot7Circle.BackgroundTransparency = 0
	if speedIcon then
		speedIcon.Visible = false
	end
	if speedIconFade then
		speedIconFade.Visible = false
	end
	if speedLabel then
		speedLabel.Text = "WAVE\nSPEED"
		speedLabel.TextColor3 = Color3.new(1, 1, 1)
		speedLabel.Visible = true
	end
	showingText = true
end

local function stopIdleCycle()
	if idleStop then
		idleStop()
		idleStop = nil
	end
	if speedLabel and not WaveSim.isSpeedPaused() then
		speedLabel.Visible = false
	end
	if not WaveSim.isSpeedPaused() then
		showingText = false
	end
end

-- Shared idle: Skip uses invert=true (text when others show icon).
-- We use invert=false so WAVE SPEED text appears when Skip shows its icon.
local function applyIdleFrame(showText: boolean)
	if WaveSim.isSpeedPaused() then
		return
	end
	if showText then
		applyTextVisual()
	else
		applyIconVisual()
	end
end

local function cancelIconFade()
	iconFadeToken += 1
	for _, tw in ipairs(iconFadeTweens) do
		tw:Cancel()
	end
	table.clear(iconFadeTweens)
	iconFading = false
	if speedIconFade then
		speedIconFade.Visible = false
		speedIconFade.ImageTransparency = 1
	end
	if speedIcon then
		speedIcon.ImageTransparency = 0
	end
end

local function stopPauseFlash()
	pauseFlashToken += 1
	if pauseFlashConn then
		pauseFlashConn:Disconnect()
		pauseFlashConn = nil
	end
	if slot7Stroke and revealed then
		slot7Stroke.Color = Color3.new(1, 1, 1)
		slot7Stroke.Thickness = 2
	end
end

local function startPauseFlash()
	if not slot7Circle or not revealed then
		return
	end
	stopPauseFlash()
	if idleStop then
		idleStop()
		idleStop = nil
	end
	cancelIconFade()
	applyIconVisual()
	if slot7Stroke then
		slot7Stroke.Enabled = true
		slot7Stroke.Thickness = 2
	end
	local my = pauseFlashToken
	local t0 = os.clock()
	pauseFlashConn = RunService.Heartbeat:Connect(function()
		if my ~= pauseFlashToken or not revealed or not WaveSim.isSpeedPaused() then
			if pauseFlashConn then
				pauseFlashConn:Disconnect()
				pauseFlashConn = nil
			end
			if slot7Stroke and revealed then
				slot7Stroke.Color = Color3.new(1, 1, 1)
				slot7Stroke.Thickness = 2
			end
			return
		end
		local phase = math.floor((os.clock() - t0) / PAUSE_FLASH_HALF_SEC) % 2
		local strokeColor = if phase == 0 then PAUSE_FLASH_WHITE else PAUSE_FLASH_YELLOW
		if speedLabel then
			if phase == 0 then
				speedLabel.Text = "WAVE\nSPEED"
				speedLabel.TextColor3 = PAUSE_FLASH_WHITE
			else
				speedLabel.Text = "PAUSED"
				speedLabel.TextColor3 = PAUSE_FLASH_YELLOW
			end
			speedLabel.Visible = true
			showingText = true
		end
		if slot7Stroke then
			slot7Stroke.Enabled = true
			slot7Stroke.Color = strokeColor
			slot7Stroke.Thickness = 2
		end
	end)
end

local function startIdleCycle()
	if not slot7 or not slot7Circle or not revealed then
		return
	end
	if WaveSim.isSpeedPaused() then
		startPauseFlash()
		return
	end
	stopPauseFlash()
	stopIdleCycle()
	if slot7Stroke then
		slot7Stroke.Enabled = true
		slot7Stroke.Color = Color3.new(1, 1, 1)
		slot7Stroke.Thickness = 2
	end
	UiCircles.ensure(slot7Circle)
	idleStop = UiIdleCycle.subscribeSharedToggle(IDLE_HALF_SEC, applyIdleFrame, function()
		return revealed and slot7 ~= nil and slot7.Visible and not iconFading and not WaveSim.isSpeedPaused()
	end, false)
end

-- Force icon mode and crossfade old → new; keep icon up for ICON_HOLD_SEC total, then rejoin idle.
local function crossfadeSpeedIcons(oldImg: string, newImg: string)
	if not speedIcon or not speedIconFade or not slot7Circle then
		applyIconVisual()
		return
	end
	cancelIconFade()
	local my = iconFadeToken
	iconFading = true

	-- Pause idle so text doesn't steal the hold window.
	if idleStop then
		idleStop()
		idleStop = nil
	end
	if speedLabel then
		speedLabel.Visible = false
	end
	if slot7Circle:IsA("ImageLabel") or slot7Circle:IsA("ImageButton") then
		(slot7Circle :: any).Image = ""
	end
	slot7Circle.BackgroundColor3 = originalBg
	slot7Circle.BackgroundTransparency = originalBgTrans
	showingText = false

	speedIconFade.Image = oldImg
	speedIconFade.ImageTransparency = 0
	speedIconFade.Visible = true
	speedIcon.Image = newImg
	speedIcon.ImageTransparency = 1
	speedIcon.Visible = true

	local twOut = TweenService:Create(speedIconFade, ICON_CROSSFADE, { ImageTransparency = 1 })
	local twIn = TweenService:Create(speedIcon, ICON_CROSSFADE, { ImageTransparency = 0 })
	table.insert(iconFadeTweens, twOut)
	table.insert(iconFadeTweens, twIn)
	twOut:Play()
	twIn:Play()
	twIn.Completed:Once(function()
		if my ~= iconFadeToken then
			return
		end
		if speedIconFade then
			speedIconFade.Visible = false
			speedIconFade.ImageTransparency = 1
		end
		if speedIcon then
			speedIcon.ImageTransparency = 0
		end
		table.clear(iconFadeTweens)
	end)

	-- One timer covers fade + post-fade hold (≥1s icon), then sync with shared slot clock.
	task.delay(ICON_HOLD_SEC, function()
		if my ~= iconFadeToken then
			return
		end
		iconFading = false
		if speedIconFade then
			speedIconFade.Visible = false
			speedIconFade.ImageTransparency = 1
		end
		if speedIcon then
			speedIcon.ImageTransparency = 0
		end
		if revealed then
			startIdleCycle()
		end
	end)
end

local function styleHelpBadge(): boolean
	if not helpSlot or not helpLetter then
		return false
	end
	local mode = deps.getShortcutMode()
	if mode == "touch" then
		return false
	end
	if helpSlot:IsA("ImageLabel") or helpSlot:IsA("ImageButton") then
		(helpSlot :: any).Image = ""
	end
	helpSlot.BackgroundColor3 = HELP_CYAN
	helpSlot.BackgroundTransparency = 0
	helpSlot.Active = false
	UiCircles.ensure(helpSlot)
	helpLetter.Text = if mode == "gamepad" then "L2" else "T"
	helpLetter.TextColor3 = Color3.new(1, 1, 1)
	helpLetter.Visible = true
	return true
end

local function setSlot7Interactable(on: boolean)
	if slot7Button then
		slot7Button.Selectable = false
		slot7Button.Active = on
	end
	if slot7 then
		slot7.Selectable = false
		if slot7:IsA("GuiButton") then
			(slot7 :: GuiButton).Active = on
		end
	end
	if helpHit then
		helpHit.Selectable = false
		helpHit.Active = on and helpHit.Visible
	end
end

function WaveSpeedSlot.refreshHelpBadge()
	if not helpSlot then
		return
	end
	local pg = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
	if pg and pg:GetAttribute("OceanTD_SkillsBubblesOpen") == true then
		helpSlot.Visible = false
		if helpHit then
			helpHit.Visible = false
			helpHit.Active = false
		end
		return
	end
	local backpackOpen = InventoryState.isOpen()
	if revealed and styleHelpBadge() then
		helpSlot.Visible = true
		if helpHomePos then
			helpSlot.Position = helpHomePos
		end
		if helpHit then
			helpHit.Visible = true
			helpHit.Selectable = false
			helpHit.Active = not backpackOpen
		end
	else
		helpSlot.Visible = false
		if helpHit then
			helpHit.Visible = false
			helpHit.Active = false
		end
	end
end

function WaveSpeedSlot.refreshIcon()
	if WaveSim.isSpeedPaused() then
		startPauseFlash()
		return
	end
	if showingText then
		return
	end
	applyIconVisual()
end

local function flashClickFeedback()
	clickFlashToken += 1
	local my = clickFlashToken
	if slot7Stroke then
		slot7Stroke.Enabled = true
		slot7Stroke.Color = FLASH_GREEN
		slot7Stroke.Thickness = 3.5
	end
	local flashText = showingText and speedLabel ~= nil and speedLabel.Visible
	if flashText and speedLabel then
		speedLabel.TextColor3 = FLASH_GREEN
	end
	task.delay(0.12, function()
		if my ~= clickFlashToken then
			return
		end
		if slot7Stroke and revealed then
			slot7Stroke.Color = Color3.new(1, 1, 1)
			slot7Stroke.Thickness = 2
		end
		if flashText and speedLabel and showingText and speedLabel.Visible then
			speedLabel.TextColor3 = Color3.new(1, 1, 1)
		end
	end)
	-- Second beat so it reads as a flash, not a single tint.
	task.delay(0.22, function()
		if my ~= clickFlashToken or not revealed then
			return
		end
		if slot7Stroke then
			slot7Stroke.Color = FLASH_GREEN
			slot7Stroke.Thickness = 3
		end
		if flashText and speedLabel and showingText and speedLabel.Visible then
			speedLabel.TextColor3 = FLASH_GREEN
		end
	end)
	task.delay(0.34, function()
		if my ~= clickFlashToken then
			return
		end
		if slot7Stroke and revealed then
			slot7Stroke.Color = Color3.new(1, 1, 1)
			slot7Stroke.Thickness = 2
		end
		if flashText and speedLabel and showingText and speedLabel.Visible then
			speedLabel.TextColor3 = Color3.new(1, 1, 1)
		end
	end)
end

local function playSpeedSound()
	local pitch = SPEED_SOUND_PITCH[speedStep()] or SPEED_SOUND_PITCH[1]
	local snd = speedSoundTemplate:Clone()
	snd.PlaybackSpeed = pitch
	snd.Parent = SoundService
	snd:Play()
	snd.Ended:Once(function()
		snd:Destroy()
	end)
	task.delay(4, function()
		if snd.Parent then
			snd:Destroy()
		end
	end)
end

function WaveSpeedSlot.cycle()
	if not revealed or InventoryState.isOpen() then
		return false
	end
	if not WaveSim.isRunning() then
		return false
	end
	if needsSpeedUnlock() then
		openWaveSpeedSkillUi()
		return false
	end
	local maxStep = SkillStages.waveSpeedMaxStep(waveSpeedStage())
	local wasPaused = WaveSim.isSpeedPaused()
	local oldMult = WaveSim.getSpeedMult()
	local oldImg = iconForMult(oldMult)
	WaveSim.cycleSpeed(maxStep)
	local nowPaused = WaveSim.isSpeedPaused()
	local newMult = WaveSim.getSpeedMult()
	UiHaptics.pulseShort()
	playSpeedSound()
	if nowPaused or wasPaused then
		cancelIconFade()
		if nowPaused then
			startPauseFlash()
		else
			stopPauseFlash()
			applyIconVisual()
			startIdleCycle()
		end
	else
		crossfadeSpeedIcons(oldImg, iconForMult(newMult))
	end
	flashClickFeedback()
	deps.log("Wave speed →", if nowPaused then "PAUSE" else tostring(newMult) .. "x", "maxStep=", maxStep)
	return true
end

function WaveSpeedSlot.playReveal()
	if not slot7 or not homePos then
		return
	end
	local pg = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
	if pg and pg:GetAttribute("OceanTD_SkillsBubblesOpen") == true then
		return
	end
	if revealed and slot7.Visible then
		return
	end
	slideToken += 1
	local token = slideToken
	local home = homePos

	slot7.Visible = true
	local hidden = underSlot5Pos()
	slot7.Position = hidden
	slot7.ZIndex = if slot5 then math.max(0, slot5.ZIndex - 1) else slot7HomeZ
	revealed = true
	if slot7Stroke then
		slot7Stroke.Enabled = true
		slot7Stroke.Color = Color3.new(1, 1, 1)
		slot7Stroke.Thickness = 2
	end
	startIdleCycle()
	startOrbitAnim()

	local showHelp = styleHelpBadge()
	if showHelp and helpSlot and helpHomePos then
		helpSlot.Visible = true
		helpSlot.ZIndex = if helpSlot5 then math.max(0, helpSlot5.ZIndex - 1) else helpHomeZ
		helpSlot.Position = underHelpSlot5Pos()
		TweenService:Create(helpSlot, SLIDE_IN, { Position = helpHomePos }):Play()
	elseif helpSlot then
		helpSlot.Visible = false
	end

	local tw = TweenService:Create(slot7, SLIDE_IN, { Position = home })
	tw:Play()
	tw.Completed:Wait()
	if token ~= slideToken then
		return
	end
	slot7.Position = home
	slot7.ZIndex = slot7HomeZ
	if showHelp and helpSlot and helpHomePos then
		helpSlot.Position = helpHomePos
		helpSlot.ZIndex = helpHomeZ
	end
	WaveSpeedSlot.refreshHelpBadge()
	setSlot7Interactable(not InventoryState.isOpen())
	syncSpeedLock()
end

function WaveSpeedSlot.playHide()
	if not slot7 or not homePos then
		return
	end
	slideToken += 1
	local token = slideToken
	local home = homePos
	stopSpeedLockOrbit()
	if speedLockOverlay then
		speedLockOverlay.Visible = false
	end
	if speedLockIcon then
		speedLockIcon.Visible = false
	end

	stopPauseFlash()
	stopIdleCycle()
	stopOrbitAnim()
	cancelIconFade()
	clickFlashToken += 1
	revealed = false
	if slot7Stroke then
		slot7Stroke.Color = Color3.new(1, 1, 1)
		slot7Stroke.Thickness = 2
	end
	if speedLabel then
		speedLabel.TextColor3 = Color3.new(1, 1, 1)
	end
	if not slot7.Visible then
		if helpSlot then
			helpSlot.Visible = false
			if helpHomePos then
				helpSlot.Position = helpHomePos
			end
			helpSlot.ZIndex = helpHomeZ
		end
		slot7.Position = home
		slot7.ZIndex = slot7HomeZ
		if slot7Stroke then
			slot7Stroke.Enabled = false
		end
		return
	end

	slot7.Position = home
	local hidden = underSlot5Pos()
	slot7.ZIndex = if slot5 then math.max(0, slot5.ZIndex - 1) else slot7HomeZ
	local tw = TweenService:Create(slot7, SLIDE_OUT, { Position = hidden })
	tw:Play()
	if helpSlot and helpSlot.Visible and helpHomePos then
		helpSlot.Position = helpHomePos
		helpSlot.ZIndex = if helpSlot5 then math.max(0, helpSlot5.ZIndex - 1) else helpHomeZ
		TweenService:Create(helpSlot, SLIDE_OUT, { Position = underHelpSlot5Pos() }):Play()
	end
	tw.Completed:Wait()
	if token ~= slideToken then
		return
	end
	slot7.Visible = false
	slot7.Position = home
	slot7.ZIndex = slot7HomeZ
	if slot7Stroke then
		slot7Stroke.Enabled = false
	end
	if helpSlot then
		helpSlot.Visible = false
		if helpHomePos then
			helpSlot.Position = helpHomePos
		end
		helpSlot.ZIndex = helpHomeZ
	end
end

function WaveSpeedSlot.syncToWaveRunning(running: boolean)
	if running then
		WaveSim.clampSpeedToMaxStep(SkillStages.waveSpeedMaxStep(waveSpeedStage()))
		if not revealed then
			task.spawn(WaveSpeedSlot.playReveal)
		else
			WaveSpeedSlot.refreshHelpBadge()
			WaveSpeedSlot.refreshIcon()
			syncSpeedLock()
		end
	else
		task.spawn(WaveSpeedSlot.playHide)
	end
end

function WaveSpeedSlot.mount(d: Deps)
	deps = d
	local quickbar = d.mainHUD:FindFirstChild("Quickbar")
	local found5 = if quickbar then quickbar:FindFirstChild("Slot5") else nil
	if found5 and found5:IsA("GuiObject") then
		slot5 = found5
	end
	local found = if quickbar then quickbar:FindFirstChild("Slot7") else nil
	if found and found:IsA("GuiObject") then
		slot7 = found
		homePos = slot7.Position
		slot7HomeZ = slot7.ZIndex
		slot7Button = d.ensureButton(slot7)
		d.passthroughDecor(slot7, slot7Button)
		slot7Circle = d.ensureCircle(slot7)
		UiCircles.forceOnDescendants(slot7)
		originalBg = slot7Circle.BackgroundColor3
		originalBgTrans = slot7Circle.BackgroundTransparency
		ensureOrbitLayers(slot7Circle)
		applyIconVisual()
		slot7Stroke = d.ensureStroke(slot7Circle, "_OceanTD_SpeedRing", Color3.new(1, 1, 1), 2)
		slot7Stroke.Enabled = false

		local existing = slot7Circle:FindFirstChild("_OceanTD_SpeedLabel")
		if existing and existing:IsA("TextLabel") then
			speedLabel = existing
		else
			if existing then
				existing:Destroy()
			end
			local lbl = Instance.new("TextLabel")
			lbl.Name = "_OceanTD_SpeedLabel"
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.Font = UiTheme.Font
			lbl.Text = "WAVE\nSPEED"
			lbl.TextColor3 = Color3.new(1, 1, 1)
			lbl.TextScaled = true
			lbl.TextWrapped = true
			lbl.Visible = false
			lbl.ZIndex = slot7Circle.ZIndex + 2
			lbl.Active = false
			lbl.Parent = slot7Circle
			local pad = Instance.new("UIPadding")
			pad.PaddingTop = UDim.new(0.12, 0)
			pad.PaddingBottom = UDim.new(0.12, 0)
			pad.PaddingLeft = UDim.new(0.06, 0)
			pad.PaddingRight = UDim.new(0.06, 0)
			pad.Parent = lbl
			speedLabel = lbl
		end
		speedLabel.ZIndex = slot7Circle.ZIndex + 2
		slot7.Visible = false
		slot7Button.Selectable = false
		if slot7Button:GetAttribute("_OceanTD_ActBound") ~= true then
			slot7Button:SetAttribute("_OceanTD_ActBound", true)
			slot7Button.Activated:Connect(function()
				WaveSpeedSlot.cycle()
			end)
		end
		d.log("Slot7 wave-speed button ready")
	else
		warn("[WAVE] MainHUD.Quickbar.Slot7 missing — wave speed unavailable")
	end

	local quickbarHelp = d.mainHUD:FindFirstChild("QuickbarHelp")
	if quickbarHelp then
		local hs5 = quickbarHelp:FindFirstChild("Slot5")
		if hs5 and hs5:IsA("GuiObject") then
			helpSlot5 = hs5
		end
		local hs = quickbarHelp:FindFirstChild("Slot7")
		if hs and hs:IsA("GuiObject") then
			helpSlot = hs
			helpHomePos = hs.Position
			helpHomeZ = hs.ZIndex
			helpSlot.Active = false
			helpSlot.Selectable = false
			helpSlot.Visible = false
			for _, desc in ipairs(helpSlot:GetDescendants()) do
				if desc:IsA("GuiObject") and desc.Name ~= "_OceanTD_HelpHit" then
					desc.Active = false
					desc.Selectable = false
				end
			end
			local existingLetter = helpSlot:FindFirstChild("_OceanTD_HelpLetter")
			if existingLetter and existingLetter:IsA("TextLabel") then
				helpLetter = existingLetter
			else
				if existingLetter then
					existingLetter:Destroy()
				end
				local letter = Instance.new("TextLabel")
				letter.Name = "_OceanTD_HelpLetter"
				letter.BackgroundTransparency = 1
				letter.Size = UDim2.fromScale(1, 1)
				letter.Font = UiTheme.Font
				letter.Text = "T"
				letter.TextColor3 = Color3.new(1, 1, 1)
				letter.TextScaled = true
				letter.ZIndex = helpSlot.ZIndex + 5
				letter.Parent = helpSlot
				helpLetter = letter
			end
			UiCircles.ensure(helpSlot)
			local hit = helpSlot:FindFirstChild("_OceanTD_HelpHit")
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
				btn.ZIndex = helpSlot.ZIndex + 6
				btn.Parent = helpSlot
				helpHit = btn
			end
			helpHit.Selectable = false
			if helpHit:GetAttribute("_OceanTD_ActBound") ~= true then
				helpHit:SetAttribute("_OceanTD_ActBound", true)
				helpHit.Activated:Connect(function()
					WaveSpeedSlot.cycle()
				end)
			end
		end
	end

	setSlot7Interactable(not InventoryState.isOpen())
	InventoryState.onOpenChanged(function(isOpen)
		setSlot7Interactable(not isOpen)
		WaveSpeedSlot.refreshHelpBadge()
	end)

	local playerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	playerGui:GetAttributeChangedSignal("OceanTD_SkillsBubblesOpen"):Connect(function()
		if playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true then
			if slot7 then
				slot7.Visible = false
			end
			if helpSlot then
				helpSlot.Visible = false
			end
		else
			WaveSpeedSlot.syncToWaveRunning(WaveSim.isRunning())
		end
	end)

	if hudUnsub then
		hudUnsub()
		hudUnsub = nil
	end
	local lastRunning = WaveSim.isRunning()
	local lastSpeed = WaveSim.getSpeedMult()
	hudUnsub = WaveSim.onHud(function(snap)
		if snap.running ~= lastRunning then
			lastRunning = snap.running
			WaveSpeedSlot.syncToWaveRunning(snap.running)
		end
		if math.abs(snap.speedMult - lastSpeed) >= 1e-4 then
			lastSpeed = snap.speedMult
			if snap.running and revealed then
				cancelIconFade()
				if WaveSim.isSpeedPaused() then
					startPauseFlash()
				else
					stopPauseFlash()
					applyIconVisual()
					startIdleCycle()
				end
			end
		end
	end)
	if lastRunning then
		WaveSpeedSlot.syncToWaveRunning(true)
	end

	Remotes.get("SkillStagesSync").OnClientEvent:Connect(function()
		WaveSim.clampSpeedToMaxStep(SkillStages.waveSpeedMaxStep(waveSpeedStage()))
		WaveSpeedSlot.refreshIcon()
		syncSpeedLock()
	end)
end

return WaveSpeedSlot
