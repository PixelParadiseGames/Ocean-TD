--!strict
--[[
	Studio: PlayerGui.MobileLeftUI.StopAutoRoll
	Toggles seed-wheel auto roll; animates wheel collapse/expand to this button.
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))

local SeedWheelAutoRollState = require(script.Parent:WaitForChild("SeedWheelAutoRollState"))
local SeedWheelRevealApi = require(script.Parent:WaitForChild("SeedWheelRevealApi"))

local STUDIO_ANCHOR_NAME = "StopAutoRoll"
local HIT_NAME = "_OceanTD_StopAutoRollHit"
local DISK_NAME = "_OceanTD_StopAutoRollDisk"
local DICE_NAME = "_OceanTD_StopAutoRollDice"
local CORAL_NAME = "_OceanTD_StopAutoRollCoral"
local LABEL_NAME = "_OceanTD_StopAutoRollLabel"
local BUTTON_SCALE_NAME = "_OceanTD_StopAutoRollScale"
local LABEL_SCALE_NAME = "_OceanTD_StopAutoRollLabelScale"
local DICE_IMAGE = "rbxassetid://77867192113507"
local CORAL_IMAGE = "rbxassetid://105031093209285"
local START_GREEN = Color3.fromRGB(29, 140, 46)
local BRIGHT_GREEN = Color3.fromRGB(90, 255, 110)
local STOP_RED = Color3.fromRGB(200, 45, 50)
local BRIGHT_RED = Color3.fromRGB(255, 70, 75)
local STROKE_NAME = "_OceanTD_StopAutoRollStroke"
local REST_SCALE = 1.2 -- 20% bigger than Studio anchor
local ICON_SWAP_SEC = 1.35
local DICE_EMOJI = "🎲"
local FOUNTAIN_GUI_NAME = "OceanTD_DiceFountain"
local HOLD_FOUNTAIN_GAP = 0.11
local ROLL_PRESS_SOUND_ID = "rbxassetid://117344652481079"

local rollPressSound = Instance.new("Sound")
rollPressSound.Name = "OceanTD_RollPress"
rollPressSound.SoundId = ROLL_PRESS_SOUND_ID
rollPressSound.Volume = 0.85
rollPressSound.Parent = SoundService

local function playRollPressSound()
	if rollPressSound.IsPlaying then
		rollPressSound:Stop()
	end
	rollPressSound.TimePosition = 0
	rollPressSound:Play()
end

local anchor: GuiObject? = nil
local hitBtn: GuiButton? = nil
local disk: Frame? = nil
local outerStroke: UIStroke? = nil
local diceIcon: ImageLabel? = nil
local coralIcon: ImageLabel? = nil
local label: TextLabel? = nil
local iconSwapConn: RBXScriptConnection? = nil
local flashToken = 0
local showDice = true
local busyAnim = false
local presenting = false
local wiredHost: GuiObject? = nil
local buttonScale: UIScale? = nil
local labelScale: UIScale? = nil
local fountainHoldGen = 0
local fountainRng = Random.new()

local function buttonScreenCenter(): Vector2?
	if not anchor then
		return nil
	end
	local inset = GuiService:GetGuiInset()
	local c = anchor.AbsolutePosition + anchor.AbsoluteSize * 0.5
	-- Fountain ScreenGui uses IgnoreGuiInset=true → inset-inclusive coords.
	return Vector2.new(c.X + inset.X, c.Y + inset.Y)
end

local function ensureFountainLayer(): Frame
	local sg = playerGui:FindFirstChild(FOUNTAIN_GUI_NAME)
	if not (sg and sg:IsA("ScreenGui")) then
		if sg then
			sg:Destroy()
		end
		local gui = Instance.new("ScreenGui")
		gui.Name = FOUNTAIN_GUI_NAME
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 12000
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = playerGui
		sg = gui
	end
	local layer = sg:FindFirstChild("Layer")
	if layer and layer:IsA("Frame") then
		return layer
	end
	if layer then
		layer:Destroy()
	end
	local f = Instance.new("Frame")
	f.Name = "Layer"
	f.BackgroundTransparency = 1
	f.Size = UDim2.fromScale(1, 1)
	f.Active = false
	f.ZIndex = 1
	f.Parent = sg
	return f
end

local function spawnDiceEmoji(layer: Frame, origin: Vector2)
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Text = DICE_EMOJI
	lbl.Font = Enum.Font.SourceSansBold
	lbl.TextSize = fountainRng:NextInteger(22, 36)
	lbl.AnchorPoint = Vector2.new(0.5, 0.5)
	lbl.Position = UDim2.fromOffset(origin.X, origin.Y)
	lbl.Size = UDim2.fromOffset(44, 44)
	lbl.ZIndex = 2
	lbl.Active = false
	lbl.Parent = layer
	local scale = Instance.new("UIScale")
	scale.Scale = 0.2
	scale.Parent = lbl

	-- Mostly upward fountain with a bit of side spray.
	local angle = fountainRng:NextNumber(-math.pi * 0.85, -math.pi * 0.15)
	local speed = fountainRng:NextNumber(220, 520)
	local vx = math.cos(angle) * speed
	local vy = math.sin(angle) * speed
	local grav = fountainRng:NextNumber(900, 1300)
	local life = fountainRng:NextNumber(0.7, 1.25)
	local popAt = fountainRng:NextNumber(0.08, 0.16)
	local peak = fountainRng:NextNumber(1.05, 1.45)
	local spin = fountainRng:NextNumber(-420, 420)
	local x = origin.X
	local y = origin.Y
	task.spawn(function()
		local t0 = os.clock()
		while lbl.Parent do
			local dt = RunService.RenderStepped:Wait()
			local age = os.clock() - t0
			if age >= life then
				break
			end
			vy += grav * dt
			x += vx * dt
			y += vy * dt
			vx *= (1 - 0.35 * dt)
			lbl.Position = UDim2.fromOffset(x, y)
			lbl.Rotation += spin * dt
			if age < popAt then
				scale.Scale = 0.2 + (peak - 0.2) * (age / popAt)
			else
				local u = math.clamp((age - popAt) / math.max(0.05, life - popAt), 0, 1)
				scale.Scale = peak * (1 - 0.45 * u)
			end
			lbl.TextTransparency = math.clamp((age - life * 0.55) / (life * 0.45), 0, 1)
		end
		if lbl.Parent then
			lbl:Destroy()
		end
	end)
end

-- Tap: 2–6 dice. Hold: keep spraying until released.
local function fountainBurst(count: number)
	local origin = buttonScreenCenter()
	if not origin then
		return
	end
	local layer = ensureFountainLayer()
	local n = math.clamp(math.floor(count), 1, 8)
	for _ = 1, n do
		spawnDiceEmoji(layer, origin)
	end
end

local function startHoldFountain()
	fountainHoldGen += 1
	local gen = fountainHoldGen
	fountainBurst(fountainRng:NextInteger(2, 6))
	task.spawn(function()
		while gen == fountainHoldGen do
			task.wait(HOLD_FOUNTAIN_GAP)
			if gen ~= fountainHoldGen then
				break
			end
			fountainBurst(fountainRng:NextInteger(1, 3))
		end
	end)
end

local function stopHoldFountain()
	fountainHoldGen += 1
end

local function stopIconSwap()
	if iconSwapConn then
		iconSwapConn:Disconnect()
		iconSwapConn = nil
	end
end

local function refreshIconSwap()
	stopIconSwap()
	if not diceIcon or not coralIcon then
		return
	end
	showDice = true
	diceIcon.Visible = true
	coralIcon.Visible = false
	local t0 = os.clock()
	iconSwapConn = RunService.RenderStepped:Connect(function()
		if not diceIcon or not coralIcon or not diceIcon.Parent then
			stopIconSwap()
			return
		end
		local phase = math.floor((os.clock() - t0) / ICON_SWAP_SEC) % 2
		local wantDice = phase == 0
		if wantDice ~= showDice then
			showDice = wantDice
			diceIcon.Visible = showDice
			coralIcon.Visible = not showDice
		end
	end)
end

local function clearStudioImage(host: GuiObject)
	if host:IsA("ImageButton") or host:IsA("ImageLabel") then
		host.Image = ""
		host.ImageTransparency = 1
	end
	host.BackgroundTransparency = 1
end

local function applyVisualRunning()
	if disk then
		disk.BackgroundColor3 = STOP_RED
		disk.BackgroundTransparency = 0
	end
	if outerStroke then
		outerStroke.Color = BRIGHT_RED
		outerStroke.Enabled = true
	end
	if label then
		label.Text = "OFF"
		label.TextColor3 = Color3.new(1, 1, 1)
	end
	refreshIconSwap()
end

local function applyVisualStopped()
	if disk then
		disk.BackgroundColor3 = START_GREEN
		disk.BackgroundTransparency = 0
	end
	if outerStroke then
		outerStroke.Color = BRIGHT_GREEN
		outerStroke.Enabled = true
	end
	if label then
		label.Text = "ROLL"
		label.TextColor3 = Color3.new(1, 1, 1)
	end
	refreshIconSwap()
end

local function flashPressGreen()
	if not disk or presenting then
		return
	end
	flashToken += 1
	local token = flashToken
	local restoreDisk = if SeedWheelAutoRollState.isEnabled() then STOP_RED else START_GREEN
	local restoreStroke = if SeedWheelAutoRollState.isEnabled() then BRIGHT_RED else BRIGHT_GREEN
	disk.BackgroundColor3 = BRIGHT_GREEN
	if outerStroke then
		outerStroke.Color = Color3.new(1, 1, 1)
	end
	task.delay(0.12, function()
		if token ~= flashToken or not disk then
			return
		end
		local tw = TweenService:Create(disk, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundColor3 = restoreDisk,
		})
		tw:Play()
		if outerStroke then
			TweenService:Create(outerStroke, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Color = restoreStroke,
			}):Play()
		end
	end)
end

local function ensureOuterStroke(host: Frame): UIStroke
	local existing = host:FindFirstChild(STROKE_NAME)
	if existing and existing:IsA("UIStroke") then
		outerStroke = existing
		existing.Color = BRIGHT_GREEN
		existing.Thickness = 3
		existing.Enabled = true
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local stroke = Instance.new("UIStroke")
	stroke.Name = STROKE_NAME
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Thickness = 3
	stroke.Color = BRIGHT_GREEN
	stroke.Enabled = true
	stroke.Parent = host
	outerStroke = stroke
	return stroke
end

local function ensureDisk(host: GuiObject): Frame
	local existing = host:FindFirstChild(DISK_NAME)
	if existing and existing:IsA("Frame") then
		disk = existing
		ensureOuterStroke(existing)
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local f = Instance.new("Frame")
	f.Name = DISK_NAME
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = START_GREEN
	f.BackgroundTransparency = 0
	f.BorderSizePixel = 0
	f.ZIndex = host.ZIndex
	f.Active = false
	f.Parent = host
	UiCircles.ensure(f)
	local hostCorner = host:FindFirstChildOfClass("UICorner")
	if hostCorner then
		local corner = f:FindFirstChildOfClass("UICorner")
		if corner then
			corner.CornerRadius = hostCorner.CornerRadius
		end
	end
	ensureOuterStroke(f)
	disk = f
	return f
end

local function ensureIcon(host: GuiObject, name: string, image: string, z: number, sizeScale: number): ImageLabel
	local existing = host:FindFirstChild(name)
	if existing and existing:IsA("ImageLabel") then
		existing.Image = image
		existing.Visible = true
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local img = Instance.new("ImageLabel")
	img.Name = name
	img.BackgroundTransparency = 1
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Position = UDim2.fromScale(0.5, 0.38)
	img.Size = UDim2.fromScale(sizeScale, sizeScale)
	img.Image = image
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = host.ZIndex + z
	img.Active = false
	img.Parent = host
	return img
end

local function ensureLabel(host: GuiObject): TextLabel
	local existing = host:FindFirstChild(LABEL_NAME)
	if existing and existing:IsA("TextLabel") then
		existing.Size = UDim2.new(1, -4, 0, 13)
		label = existing
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local lbl = Instance.new("TextLabel")
	lbl.Name = LABEL_NAME
	lbl.BackgroundTransparency = 1
	lbl.AnchorPoint = Vector2.new(0.5, 1)
	lbl.Position = UDim2.new(0.5, 0, 1, -2)
	lbl.Size = UDim2.new(1, -4, 0, 13)
	lbl.Font = UiTheme.Font
	lbl.TextScaled = true
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.Text = "ROLL"
	lbl.ZIndex = host.ZIndex + 4
	lbl.Active = false
	lbl.Parent = host
	label = lbl
	return lbl
end

local function ensureScale(parent: Instance, name: string): UIScale
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("UIScale") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local scale = Instance.new("UIScale")
	scale.Name = name
	scale.Scale = 1
	scale.Parent = parent
	return scale
end

local function tweenScale(scale: UIScale, to: number, duration: number, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
	local tw = TweenService:Create(
		scale,
		TweenInfo.new(duration, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out),
		{ Scale = to }
	)
	tw:Play()
	return tw
end

local function spinVisibleIcon()
	local icon = if coralIcon and coralIcon.Visible then coralIcon else diceIcon
	if not icon then
		return
	end
	icon.Rotation = 0
	local tw = TweenService:Create(icon, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Rotation = 360,
	})
	tw:Play()
	tw.Completed:Once(function()
		if icon.Parent then
			icon.Rotation = 0
		end
	end)
end

local function pulseThenHideLabel(onHidden: () -> ())
	if not label or not labelScale then
		onHidden()
		return
	end
	labelScale.Scale = 1
	local down = tweenScale(labelScale, 0.55, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	down.Completed:Once(function()
		if not labelScale then
			onHidden()
			return
		end
		local up = tweenScale(labelScale, 1.25, 0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		up.Completed:Once(function()
			if not labelScale then
				onHidden()
				return
			end
			local hide = tweenScale(labelScale, 0, 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			hide.Completed:Once(onHidden)
		end)
	end)
end

-- Same shrink → grow → hide as the ROLL label, but for the whole green disk + icons.
local function pulseThenHideButton(onHidden: () -> ())
	if not buttonScale then
		onHidden()
		return
	end
	buttonScale.Scale = REST_SCALE
	local down = tweenScale(buttonScale, REST_SCALE * 0.55, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	down.Completed:Once(function()
		if not buttonScale then
			onHidden()
			return
		end
		local up = tweenScale(buttonScale, REST_SCALE * 1.25, 0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		up.Completed:Once(function()
			if not buttonScale then
				onHidden()
				return
			end
			local hide = tweenScale(buttonScale, 0, 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			hide.Completed:Once(onHidden)
		end)
	end)
end

local function restoreLabel()
	if not labelScale then
		return
	end
	tweenScale(labelScale, 1, 0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
end

local function overscaleThenHideButton(onHidden: () -> ())
	if not buttonScale then
		onHidden()
		return
	end
	buttonScale.Scale = REST_SCALE
	local up = tweenScale(buttonScale, REST_SCALE * 1.35, 0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	up.Completed:Once(function()
		if not buttonScale then
			onHidden()
			return
		end
		local hide = tweenScale(buttonScale, 0, 0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		hide.Completed:Once(onHidden)
	end)
end

local function restoreButton()
	if not buttonScale then
		return
	end
	tweenScale(buttonScale, REST_SCALE, 0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
end

-- Fires when the spin awards the seed and the circle finishes sliding to the backpack.
-- Returns the callback and a cancel so a 28s safety timer cannot restore twice.
local function whenRollSettled(onDone: () -> ()): (() -> (), () -> ())
	local fired = false
	local alive = true
	local function fire()
		if not alive or fired then
			return
		end
		fired = true
		if SeedWheelRevealApi.onCycleFinished == fire then
			SeedWheelRevealApi.onCycleFinished = nil
		end
		onDone()
	end
	local function cancel()
		alive = false
		if SeedWheelRevealApi.onCycleFinished == fire then
			SeedWheelRevealApi.onCycleFinished = nil
		end
	end
	SeedWheelRevealApi.onCycleFinished = fire
	task.delay(28, fire)
	return fire, cancel
end

-- Always use an overlay hit target. Fully transparent GuiButtons often miss touch.
local function ensureHit(host: GuiObject): GuiButton
	host.Active = true
	pcall(function()
		(host :: any).Interactable = true
	end)
	local existing = host:FindFirstChild(HIT_NAME)
	if existing and existing:IsA("GuiButton") then
		existing.Active = true
		pcall(function()
			(existing :: any).Interactable = true
		end)
		hitBtn = existing
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local hit = Instance.new("TextButton")
	hit.Name = HIT_NAME
	-- Near-invisible but still hittable (0 transparency often eats input on mobile).
	hit.BackgroundColor3 = Color3.new(1, 1, 1)
	hit.BackgroundTransparency = 0.99
	hit.BorderSizePixel = 0
	hit.Size = UDim2.fromScale(1, 1)
	hit.Position = UDim2.fromScale(0, 0)
	hit.Text = ""
	hit.ZIndex = host.ZIndex + 20
	hit.AutoButtonColor = false
	hit.Selectable = true
	hit.Active = true
	hit.Parent = host
	pcall(function()
		(hit :: any).Interactable = true
	end)
	hitBtn = hit
	return hit
end

local function ensureChrome(host: GuiObject)
	clearStudioImage(host)
	-- Hide Studio-authored children; keep our runtime chrome.
	for _, ch in ipairs(host:GetChildren()) do
		if ch:IsA("GuiObject") then
			local n = ch.Name
			if n ~= HIT_NAME
				and n ~= DISK_NAME
				and n ~= DICE_NAME
				and n ~= CORAL_NAME
				and n ~= LABEL_NAME
				and not ch:IsA("UICorner")
				and not ch:IsA("UIStroke")
				and not ch:IsA("UIAspectRatioConstraint")
				and not ch:IsA("UIPadding")
			then
				ch.Visible = false
				ch.Active = false
			end
		end
	end
	ensureDisk(host)
	diceIcon = ensureIcon(host, DICE_NAME, DICE_IMAGE, 3, 0.48)
	coralIcon = ensureIcon(host, CORAL_NAME, CORAL_IMAGE, 3, 0.48)
	coralIcon.Visible = false
	ensureLabel(host)
	buttonScale = ensureScale(host, BUTTON_SCALE_NAME)
	if not presenting then
		buttonScale.Scale = REST_SCALE
	end
	if label then
		labelScale = ensureScale(label, LABEL_SCALE_NAME)
	end
end

local HOLD_SEC = 0.45
local pressGen = 0

local function isPointerPress(input: InputObject): boolean
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		return true
	end
	return input.KeyCode == Enum.KeyCode.ButtonA
end

local function startAutoRoll()
	if busyAnim or presenting or not anchor then
		return
	end
	busyAnim = true
	applyVisualRunning()
	local expand = SeedWheelRevealApi.expandFromTarget
	if expand then
		expand(anchor, function()
			SeedWheelAutoRollState._setEnabled(true)
			Remotes.get("SeedWheelAutoRoll"):FireServer(true)
			busyAnim = false
		end)
	else
		SeedWheelAutoRollState._setEnabled(true)
		Remotes.get("SeedWheelAutoRoll"):FireServer(true)
		busyAnim = false
	end
end

local function stopAutoRoll()
	if busyAnim or presenting or not anchor then
		return
	end
	presenting = true
	busyAnim = true
	SeedWheelAutoRollState._setEnabled(false)
	Remotes.get("SeedWheelAutoRoll"):FireServer(false)
	local isBusy = SeedWheelRevealApi.isBusy
	local cycleDone = not (isBusy and isBusy())
	local hideDone = false
	local function tryRestore()
		if not hideDone or not cycleDone then
			return
		end
		presenting = false
		busyAnim = false
		restoreButton()
		if labelScale then
			labelScale.Scale = 1
		end
		applyVisualStopped()
	end
	local markCycle, cancelWait = whenRollSettled(function()
		cycleDone = true
		tryRestore()
	end)
	if cycleDone then
		cancelWait()
	end
	overscaleThenHideButton(function()
		hideDone = true
		local busyNow = SeedWheelRevealApi.isBusy
		if not cycleDone and busyNow and not busyNow() then
			cycleDone = true
			cancelWait()
		end
		tryRestore()
	end)
end

-- One coral + hue. Does not enable auto-roll, so the server will not queue another seed.
local function rollOnce()
	if busyAnim or presenting or SeedWheelAutoRollState.isEnabled() then
		return
	end
	local isBusy = SeedWheelRevealApi.isBusy
	if isBusy and isBusy() then
		return
	end
	presenting = true
	busyAnim = true
	spinVisibleIcon()
	SeedWheelAutoRollState.armManual()
	Remotes.get("SeedWheelRollOnce"):FireServer()
	local cycleDone = false
	local hideDone = false
	local function tryRestore()
		if not hideDone or not cycleDone then
			return
		end
		presenting = false
		busyAnim = false
		if labelScale then
			labelScale.Scale = 1
		end
		restoreButton()
		applyVisualStopped()
	end
	local _, cancelWait = whenRollSettled(function()
		cycleDone = true
		tryRestore()
	end)
	-- Green disk + dice/coral + ROLL text pulse then shrink away together.
	pulseThenHideButton(function()
		hideDone = true
		local busyNow = SeedWheelRevealApi.isBusy
		if not cycleDone and busyNow and not busyNow() then
			-- Reveal has not started yet — keep waiting for it, or give up shortly.
			task.delay(2.5, function()
				if cycleDone then
					return
				end
				local still = SeedWheelRevealApi.isBusy
				if still and still() then
					return
				end
				cycleDone = true
				cancelWait()
				tryRestore()
			end)
			return
		end
		tryRestore()
	end)
end

local function wireHit(hit: GuiButton)
	if hit:GetAttribute("_OceanTD_StopAutoRollWired") == true then
		return
	end
	hit:SetAttribute("_OceanTD_StopAutoRollWired", true)
	local holding = false
	hit.InputBegan:Connect(function(input)
		if not isPointerPress(input) then
			return
		end
		flashPressGreen()
		playRollPressSound()
		UiHaptics.pulseDouble()
		startHoldFountain()
		pressGen += 1
		local gen = pressGen
		holding = true
		local wasAuto = SeedWheelAutoRollState.isEnabled()
		task.delay(HOLD_SEC, function()
			if gen ~= pressGen or not holding then
				return
			end
			holding = false
			pressGen += 1
			-- Hold completed — stop spray before toggling auto-roll.
			stopHoldFountain()
			UiHaptics.pulseLong()
			if wasAuto then
				stopAutoRoll()
			else
				startAutoRoll()
			end
		end)
	end)
	hit.InputEnded:Connect(function(input)
		if not isPointerPress(input) or not holding then
			return
		end
		holding = false
		pressGen += 1
		stopHoldFountain()
		if SeedWheelAutoRollState.isEnabled() then
			stopAutoRoll()
		else
			rollOnce()
		end
	end)
end

local function wireStopAutoRoll(leftOpt: Instance?)
	local left = leftOpt or playerGui:FindFirstChild("MobileLeftUI") or playerGui:WaitForChild("MobileLeftUI", 60)
	if not left then
		warn("[StopAutoRoll] PlayerGui.MobileLeftUI missing")
		return
	end
	LeftHudLayout.hardenScreenGui(left)
	local host = left:FindFirstChild(STUDIO_ANCHOR_NAME)
	if not host then
		host = left:WaitForChild(STUDIO_ANCHOR_NAME, 30)
	end
	if not host or not host:IsA("GuiObject") then
		warn("[StopAutoRoll] MobileLeftUI.StopAutoRoll missing — add anchor in Studio")
		return
	end

	anchor = host
	host.Visible = true
	host.Active = true
	pcall(function()
		(host :: any).Interactable = true
	end)

	ensureChrome(host)
	local hit = ensureHit(host)
	wireHit(hit)
	wiredHost = host

	if SeedWheelAutoRollState.isEnabled() then
		applyVisualRunning()
	else
		applyVisualStopped()
	end
end

Remotes.get("SeedWheelAutoRollSync").OnClientEvent:Connect(function(enabled: any)
	local on = enabled == true
	SeedWheelAutoRollState._setEnabled(on)
	if presenting then
		return
	end
	if on then
		applyVisualRunning()
	else
		applyVisualStopped()
	end
end)

SeedWheelAutoRollState.onChanged(function(on)
	if presenting then
		return
	end
	if on then
		applyVisualRunning()
	else
		applyVisualStopped()
	end
end)

LeftHudLayout.watchMobileLeftUi(playerGui, wireStopAutoRoll)

task.spawn(function()
	while true do
		task.wait(2)
		local left = playerGui:FindFirstChild("MobileLeftUI")
		local host = left and left:FindFirstChild(STUDIO_ANCHOR_NAME)
		if not host or not host:IsA("GuiObject") or not hitBtn or not hitBtn.Parent or wiredHost ~= host then
			wireStopAutoRoll(nil)
		elseif not host.Visible then
			host.Visible = true
			host.Active = true
		end
	end
end)

print("[StopAutoRoll] Ready")
