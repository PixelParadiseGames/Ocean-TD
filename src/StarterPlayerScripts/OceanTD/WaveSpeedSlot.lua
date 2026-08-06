--!strict
--[[
	Slot7 Wave Speed — slides out from under Slot5 while waves run.
	Cycles 1x → 1.5x → 2x → 1x. Shortcuts: T / L2 (backpack closed).
	Help badge; hidden on touch. Idle text opposite Skip Wave (shared clock).
	Green orbiting dot on the rim; angular speed scales with speed step.
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

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local WaveSpeedSlot = {}

local SLIDE_IN = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SLIDE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local IDLE_HALF_SEC = 2
local HELP_CYAN = Color3.fromRGB(60, 170, 230)
local ORBIT_GREEN = Color3.fromRGB(45, 210, 95)
local FLASH_GREEN = Color3.fromRGB(40, 220, 110)
-- Seconds per full revolution at speed steps 1 / 2 / 3 (1x / 1.5x / 2x).
local ORBIT_PERIOD = { 2.4, 1.35, 0.75 }
local ORBIT_DOT_SCALE = 0.13 -- fraction of button size
-- Radius so the dot center sits on the button rim.
local ORBIT_RADIUS = 0.5
local SPEED_SOUND_ID = "rbxassetid://135244211779631"
-- PlaybackSpeed for steps 1 / 2 / 3 (low / med / high).
local SPEED_SOUND_PITCH = { 0.85, 1.05, 1.3 }

local ICON_1X = "rbxassetid://130235737024254"
local ICON_15X = "rbxassetid://93866614390396"
local ICON_2X = "rbxassetid://85700415632293"

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
local revealed = false
local hudUnsub: (() -> ())? = nil
local showingText = false

local function speedStep(): number
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
	local img = iconForMult(WaveSim.getSpeedMult())
	if slot7Circle:IsA("ImageLabel") or slot7Circle:IsA("ImageButton") then
		(slot7Circle :: any).Image = ""
	end
	slot7Circle.BackgroundColor3 = originalBg
	slot7Circle.BackgroundTransparency = originalBgTrans
	if speedIcon then
		speedIcon.Image = img
		speedIcon.Visible = true
	end
	if speedLabel then
		speedLabel.Visible = false
	end
	showingText = false
end

local function applyTextVisual()
	if not slot7Circle then
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
	if speedLabel then
		speedLabel.Visible = false
	end
	showingText = false
end

-- Shared idle: Skip uses invert=true (text when others show icon).
-- We use invert=false so WAVE SPEED text appears when Skip shows its icon.
local function applyIdleFrame(showText: boolean)
	if showText then
		applyTextVisual()
	else
		applyIconVisual()
	end
end

local function startIdleCycle()
	if not slot7 or not slot7Circle or not revealed then
		return
	end
	stopIdleCycle()
	if slot7Stroke then
		slot7Stroke.Enabled = true
		slot7Stroke.Color = Color3.new(1, 1, 1)
		slot7Stroke.Thickness = 2
	end
	UiCircles.ensure(slot7Circle)
	idleStop = UiIdleCycle.subscribeSharedToggle(IDLE_HALF_SEC, applyIdleFrame, function()
		return revealed and slot7 ~= nil and slot7.Visible
	end, false)
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
	WaveSim.cycleSpeed()
	UiHaptics.pulseShort()
	playSpeedSound()
	-- Orbit reads the current speed each frame; icon still needs a refresh.
	if not showingText then
		applyIconVisual()
	end
	flashClickFeedback()
	deps.log("Wave speed →", WaveSim.getSpeedMult(), "x")
	return true
end

function WaveSpeedSlot.playReveal()
	if not slot7 or not homePos then
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
end

function WaveSpeedSlot.playHide()
	if not slot7 or not homePos then
		return
	end
	slideToken += 1
	local token = slideToken
	local home = homePos

	stopIdleCycle()
	stopOrbitAnim()
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
		if not revealed then
			task.spawn(WaveSpeedSlot.playReveal)
		else
			WaveSpeedSlot.refreshHelpBadge()
			WaveSpeedSlot.refreshIcon()
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

	if hudUnsub then
		hudUnsub()
		hudUnsub = nil
	end
	local lastRunning = WaveSim.isRunning()
	hudUnsub = WaveSim.onHud(function(snap)
		if snap.running == lastRunning then
			return
		end
		lastRunning = snap.running
		WaveSpeedSlot.syncToWaveRunning(snap.running)
	end)
	if lastRunning then
		WaveSpeedSlot.syncToWaveRunning(true)
	end
end

return WaveSpeedSlot
