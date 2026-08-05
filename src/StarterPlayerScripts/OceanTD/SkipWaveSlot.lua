--!strict
--[[
	Slot6 Skip Wave — slides out from under Slot5 while waves run.
	Shortcuts: Z (keyboard) / L2 (gamepad) when backpack is closed.
	Help badge orange; hidden on touch. Click / shortcut opens confirm popup.
]]

local ContentProvider = game:GetService("ContentProvider")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiIdleCycle = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiIdleCycle"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local SkipWaveSlot = {}

local SLIDE_IN = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SLIDE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local IDLE_HALF_SEC = 2
local HELP_ORANGE = Color3.fromRGB(255, 140, 40)
local SKIP_GLOW = Color3.fromRGB(255, 150, 50)
local PANEL_W = 420
local PANEL_H = 220
local SCALE_IN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SCALE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local CONFIRM_SOUND_ID = "rbxassetid://132862955422973"
local FLASH_FADE_SEC = 2

export type Deps = {
	mainHUD: ScreenGui,
	playerGui: PlayerGui,
	ensureButton: (GuiObject) -> GuiButton,
	passthroughDecor: (GuiObject, GuiButton) -> (),
	ensureCircle: (GuiObject) -> GuiObject,
	ensureStroke: (GuiObject, string, Color3, number) -> UIStroke,
	getShortcutMode: () -> string,
	isWaveSummaryOpen: () -> boolean,
	isSavePlotsOpen: () -> boolean,
	isClearConfirmActive: () -> boolean,
	red: Color3,
	green: Color3,
	log: (...any) -> (),
}

local deps: Deps
local slot6: GuiObject? = nil
local slot6Button: GuiButton? = nil
local slot6Circle: GuiObject? = nil
local slot6Stroke: UIStroke? = nil
local skipLabel: TextLabel? = nil
local idleStop: UiIdleCycle.StopFn? = nil
local originalImage = ""
local originalBg = Color3.fromRGB(20, 30, 45)
local originalBgTrans = 0.15
local homePos: UDim2? = nil
local helpSlot: GuiObject? = nil
local helpLetter: TextLabel? = nil
local helpHomePos: UDim2? = nil
local helpHit: GuiButton? = nil
local slot5: GuiObject? = nil
local helpSlot5: GuiObject? = nil
local slot6HomeZ = 1
local helpHomeZ = 1
local slideToken = 0
local pressToken = 0
local revealed = false
local confirmActive = false
local confirmCheck: TextButton? = nil
local confirmCancel: TextButton? = nil
local confirmGui: ScreenGui? = nil
local confirmPanel: Frame? = nil
local confirmDim: Frame? = nil
local confirmTitle: TextLabel? = nil
local prevGuiSelected: GuiObject? = nil
local confirmOpenedAt = 0
local titleFlashConn: RBXScriptConnection? = nil
local scaleToken = 0
local hudUnsub: (() -> ())? = nil

local confirmSound = Instance.new("Sound")
confirmSound.Name = "OceanTD_SkipWaveConfirmSound"
confirmSound.SoundId = CONFIRM_SOUND_ID
confirmSound.Volume = 0.95
confirmSound.Parent = SoundService
task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ confirmSound })
	end)
end)

local function isUsingGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

-- Position `mover` so its center matches `target` (same parent preferred).
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
	if slot5 and slot6 then
		return positionCenteredOn(slot5, slot6)
	end
	return homePos or UDim2.new()
end

local function underHelpSlot5Pos(): UDim2
	if helpSlot5 and helpSlot then
		return positionCenteredOn(helpSlot5, helpSlot)
	end
	return helpHomePos or UDim2.new()
end

local function playWhiteFlash()
	local g = Instance.new("ScreenGui")
	g.Name = "OceanTD_SkipFlash"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 20000
	g.Parent = deps.playerGui
	local flash = Instance.new("Frame")
	flash.BackgroundColor3 = Color3.new(1, 1, 1)
	flash.BackgroundTransparency = 0
	flash.BorderSizePixel = 0
	flash.Size = UDim2.fromScale(1, 1)
	flash.ZIndex = 10
	flash.Parent = g
	local tw = TweenService:Create(flash, TweenInfo.new(FLASH_FADE_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	})
	tw:Play()
	tw.Completed:Once(function()
		if g.Parent then
			g:Destroy()
		end
	end)
end

local function stopIdleCycle()
	if idleStop then
		idleStop()
		idleStop = nil
	end
	if skipLabel then
		skipLabel.Visible = false
	end
end

local function applyIdleFrame(showText: boolean)
	if not slot6Circle then
		return
	end
	if showText then
		if slot6Circle:IsA("ImageLabel") or slot6Circle:IsA("ImageButton") then
			(slot6Circle :: any).Image = ""
		end
		slot6Circle.BackgroundColor3 = Color3.new(0, 0, 0)
		slot6Circle.BackgroundTransparency = 0
		if skipLabel then
			skipLabel.Text = "SKIP\nWAVE"
			skipLabel.TextColor3 = Color3.new(1, 1, 1)
			skipLabel.Visible = true
		end
	else
		if slot6Circle:IsA("ImageLabel") or slot6Circle:IsA("ImageButton") then
			(slot6Circle :: any).Image = originalImage
		end
		slot6Circle.BackgroundColor3 = originalBg
		slot6Circle.BackgroundTransparency = originalBgTrans
		if skipLabel then
			skipLabel.Visible = false
		end
	end
end

local function startIdleCycle()
	if not slot6 or not slot6Circle or not revealed then
		return
	end
	stopIdleCycle()
	if slot6Stroke then
		slot6Stroke.Enabled = true
		slot6Stroke.Color = Color3.new(1, 1, 1)
		slot6Stroke.Thickness = 2
	end
	UiCircles.ensure(slot6Circle)
	-- Opposite phase of Slot4/1/3 so SKIP text doesn't land with BUILD/SAVE/UNDO.
	idleStop = UiIdleCycle.subscribeSharedToggle(IDLE_HALF_SEC, applyIdleFrame, function()
		return revealed and slot6 ~= nil and slot6.Visible and not confirmActive
	end, true)
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
	helpSlot.BackgroundColor3 = HELP_ORANGE
	helpSlot.BackgroundTransparency = 0
	helpSlot.Active = false
	UiCircles.ensure(helpSlot)
	helpLetter.Text = if mode == "gamepad" then "L2" else "Z"
	helpLetter.TextColor3 = Color3.new(1, 1, 1)
	helpLetter.Visible = true
	return true
end

local function setSlot6Interactable(on: boolean)
	if slot6Button then
		slot6Button.Selectable = false
		slot6Button.Active = on
	end
	if slot6 then
		slot6.Selectable = false
		if slot6:IsA("GuiButton") then
			(slot6 :: GuiButton).Active = on
		end
	end
	if helpHit then
		helpHit.Selectable = false
		helpHit.Active = on and helpHit.Visible
	end
end

function SkipWaveSlot.refreshHelpBadge()
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

local function canArm(): boolean
	if not revealed or not slot6 or not slot6.Visible then
		return false
	end
	if not WaveSim.isRunning() then
		return false
	end
	if InventoryState.isOpen() then
		return false
	end
	if deps.isWaveSummaryOpen() or deps.isSavePlotsOpen() or deps.isClearConfirmActive() then
		return false
	end
	return true
end

function SkipWaveSlot.isConfirmActive(): boolean
	return confirmActive
end

function SkipWaveSlot.hideConfirm()
	if not confirmActive and not (confirmGui and confirmGui.Enabled) then
		return
	end
	confirmActive = false
	scaleToken += 1
	local my = scaleToken
	if titleFlashConn then
		titleFlashConn:Disconnect()
		titleFlashConn = nil
	end
	local sel = GuiService.SelectedObject
	if (confirmCheck and sel == confirmCheck) or (confirmCancel and sel == confirmCancel) then
		GuiService.SelectedObject = prevGuiSelected
	end
	prevGuiSelected = nil
	if confirmDim then
		confirmDim.Visible = false
	end
	if confirmPanel and confirmPanel.Visible and slot6 then
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
		local btnPos = slot6.AbsolutePosition
		local btnSize = slot6.AbsoluteSize
		local endX = (btnPos.X + btnSize.X * 0.5) / vp.X
		local endY = (btnPos.Y + btnSize.Y * 0.5) / vp.Y
		local tw = TweenService:Create(confirmPanel, SCALE_OUT, {
			Position = UDim2.fromScale(endX, endY),
			Size = UDim2.fromOffset(40, 40),
		})
		tw:Play()
		tw.Completed:Connect(function()
			if my ~= scaleToken then
				return
			end
			if confirmPanel then
				confirmPanel.Visible = false
			end
			if confirmGui then
				confirmGui.Enabled = false
			end
			if revealed and slot6 and slot6.Visible then
				startIdleCycle()
			end
		end)
	else
		if confirmPanel then
			confirmPanel.Visible = false
		end
		if confirmGui then
			confirmGui.Enabled = false
		end
		if revealed and slot6 and slot6.Visible then
			startIdleCycle()
		end
	end
end

function SkipWaveSlot.cancelConfirm()
	if not confirmActive then
		return
	end
	SkipWaveSlot.hideConfirm()
	deps.log("Skip wave confirm cancelled")
end

local function ensureConfirmUi()
	if confirmGui and confirmPanel and confirmCheck and confirmCancel then
		return
	end
	local g = Instance.new("ScreenGui")
	g.Name = "OceanTD_SkipWaveConfirm"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 12060
	g.Enabled = false
	g.Parent = deps.playerGui
	confirmGui = g

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
	confirmDim = dim
	dim.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if os.clock() - confirmOpenedAt < 0.35 then
				return
			end
			SkipWaveSlot.cancelConfirm()
		end
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
	panel.BackgroundColor3 = Color3.fromRGB(18, 28, 40)
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.ZIndex = 2
	panel.Active = true
	panel.Parent = g
	confirmPanel = panel
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(80, 140, 180)
	stroke.Thickness = 2
	stroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 18)
	title.Size = UDim2.new(1, -32, 0, 40)
	title.Font = UiTheme.Font
	title.Text = "Skip Wave?"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextScaled = true
	title.ZIndex = 3
	title.Parent = panel
	confirmTitle = title

	local body = Instance.new("TextLabel")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(16, 70)
	body.Size = UDim2.new(1, -32, 0, 56)
	body.Font = UiTheme.Font
	body.Text = "Jump to the next wave. No hearts lost."
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

	confirmCheck = makeWideBtn("CONFIRM", deps.green, Color3.fromRGB(12, 70, 28))
	confirmCancel = makeWideBtn("CANCEL", deps.red, Color3.fromRGB(90, 12, 18))
	confirmCheck.AnchorPoint = Vector2.new(0, 1)
	confirmCheck.Position = UDim2.new(0, 20, 1, -18)
	confirmCancel.AnchorPoint = Vector2.new(1, 1)
	confirmCancel.Position = UDim2.new(1, -20, 1, -18)
	confirmCheck.NextSelectionRight = confirmCancel
	confirmCancel.NextSelectionLeft = confirmCheck
	confirmCheck.Activated:Connect(function()
		SkipWaveSlot.commit()
	end)
	confirmCancel.Activated:Connect(function()
		SkipWaveSlot.cancelConfirm()
	end)
end

local function playArmFlash()
	if not slot6Circle then
		return
	end
	pressToken += 1
	local token = pressToken
	stopIdleCycle()
	if slot6Circle:IsA("ImageLabel") or slot6Circle:IsA("ImageButton") then
		(slot6Circle :: any).Image = ""
	end
	slot6Circle.BackgroundColor3 = SKIP_GLOW
	slot6Circle.BackgroundTransparency = 0
	if skipLabel then
		skipLabel.Text = "SKIP\nWAVE"
		skipLabel.TextColor3 = Color3.new(1, 1, 1)
		skipLabel.Visible = true
	end
	task.delay(1, function()
		if token ~= pressToken or not slot6Circle then
			return
		end
		if confirmActive then
			slot6Circle.BackgroundColor3 = Color3.new(0, 0, 0)
			return
		end
		if revealed and slot6 and slot6.Visible then
			startIdleCycle()
		end
	end)
end

function SkipWaveSlot.handlePrimaryConfirm()
	if not confirmActive then
		return
	end
	local sel = GuiService.SelectedObject
	if confirmCancel and sel == confirmCancel then
		SkipWaveSlot.cancelConfirm()
		return
	end
	SkipWaveSlot.commit()
end

function SkipWaveSlot.commit()
	if not confirmActive then
		return
	end
	SkipWaveSlot.hideConfirm()
	UiHaptics.pulseShort()
	playWhiteFlash()
	local snd = confirmSound:Clone()
	snd.Parent = SoundService
	snd:Play()
	snd.Ended:Once(function()
		snd:Destroy()
	end)
	local ok = WaveSim.skipToNextWave()
	if ok then
		deps.log("Skip wave confirmed")
	else
		deps.log("Skip wave failed — waves not running")
		SkipWaveSlot.syncToWaveRunning(false)
	end
end

function SkipWaveSlot.beginConfirm()
	if confirmActive then
		return
	end
	if not canArm() then
		return
	end
	ensureConfirmUi()
	playArmFlash()
	confirmOpenedAt = os.clock()
	confirmActive = true
	scaleToken += 1
	if confirmGui then
		confirmGui.Enabled = true
	end
	if confirmDim then
		confirmDim.Visible = true
	end
	if confirmPanel then
		confirmPanel.Visible = true
		if slot6 then
			local cam = Workspace.CurrentCamera
			local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
			local btnPos = slot6.AbsolutePosition
			local btnSize = slot6.AbsoluteSize
			local startX = (btnPos.X + btnSize.X * 0.5) / vp.X
			local startY = (btnPos.Y + btnSize.Y * 0.5) / vp.Y
			confirmPanel.Position = UDim2.fromScale(startX, startY)
			confirmPanel.Size = UDim2.fromOffset(40, 40)
			TweenService:Create(confirmPanel, SCALE_IN, {
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(PANEL_W, PANEL_H),
			}):Play()
		else
			confirmPanel.Position = UDim2.fromScale(0.5, 0.5)
			confirmPanel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
		end
	end
	if titleFlashConn then
		titleFlashConn:Disconnect()
		titleFlashConn = nil
	end
	if confirmTitle then
		local t0 = os.clock()
		titleFlashConn = RunService.RenderStepped:Connect(function()
			if not confirmActive or not confirmTitle then
				return
			end
			local wave = (math.sin((os.clock() - t0) * 7) + 1) * 0.5
			confirmTitle.TextColor3 = Color3.new(1, 1, 1):Lerp(HELP_ORANGE, wave)
		end)
	end
	if isUsingGamepad() and confirmCheck then
		prevGuiSelected = GuiService.SelectedObject
		GuiService.SelectedObject = confirmCheck
	end
	deps.log("Skip wave confirm")
end

function SkipWaveSlot.playReveal()
	if not slot6 or not homePos then
		return
	end
	if revealed and slot6.Visible then
		return
	end
	slideToken += 1
	local token = slideToken
	local home = homePos

	-- Measure while briefly visible, start stacked on Slot5 center (behind).
	slot6.Visible = true
	local hidden = underSlot5Pos()
	slot6.Position = hidden
	slot6.ZIndex = if slot5 then math.max(0, slot5.ZIndex - 1) else slot6HomeZ
	revealed = true
	if slot6Stroke then
		slot6Stroke.Enabled = true
		slot6Stroke.Color = Color3.new(1, 1, 1)
		slot6Stroke.Thickness = 2
	end
	startIdleCycle()

	local showHelp = styleHelpBadge()
	if showHelp and helpSlot and helpHomePos then
		helpSlot.Visible = true
		helpSlot.ZIndex = if helpSlot5 then math.max(0, helpSlot5.ZIndex - 1) else helpHomeZ
		helpSlot.Position = underHelpSlot5Pos()
		TweenService:Create(helpSlot, SLIDE_IN, { Position = helpHomePos }):Play()
	elseif helpSlot then
		helpSlot.Visible = false
	end

	local tw = TweenService:Create(slot6, SLIDE_IN, { Position = home })
	tw:Play()
	tw.Completed:Wait()
	if token ~= slideToken then
		return
	end
	slot6.Position = home
	slot6.ZIndex = slot6HomeZ
	if showHelp and helpSlot and helpHomePos then
		helpSlot.Position = helpHomePos
		helpSlot.ZIndex = helpHomeZ
	end
	SkipWaveSlot.refreshHelpBadge()
	setSlot6Interactable(not InventoryState.isOpen())
end

function SkipWaveSlot.playHide()
	if not slot6 or not homePos then
		return
	end
	slideToken += 1
	local token = slideToken
	local home = homePos

	SkipWaveSlot.hideConfirm()
	stopIdleCycle()
	pressToken += 1
	revealed = false
	if not slot6.Visible then
		if helpSlot then
			helpSlot.Visible = false
			if helpHomePos then
				helpSlot.Position = helpHomePos
			end
			helpSlot.ZIndex = helpHomeZ
		end
		slot6.Position = home
		slot6.ZIndex = slot6HomeZ
		if slot6Stroke then
			slot6Stroke.Enabled = false
		end
		return
	end

	slot6.Position = home
	local hidden = underSlot5Pos()
	slot6.ZIndex = if slot5 then math.max(0, slot5.ZIndex - 1) else slot6HomeZ
	local tw = TweenService:Create(slot6, SLIDE_OUT, { Position = hidden })
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
	slot6.Visible = false
	slot6.Position = home
	slot6.ZIndex = slot6HomeZ
	if slot6Stroke then
		slot6Stroke.Enabled = false
	end
	if helpSlot then
		helpSlot.Visible = false
		if helpHomePos then
			helpSlot.Position = helpHomePos
		end
		helpSlot.ZIndex = helpHomeZ
	end
end

function SkipWaveSlot.syncToWaveRunning(running: boolean)
	if running then
		if not revealed then
			task.spawn(SkipWaveSlot.playReveal)
		else
			SkipWaveSlot.refreshHelpBadge()
		end
	else
		task.spawn(SkipWaveSlot.playHide)
	end
end

function SkipWaveSlot.mount(d: Deps)
	deps = d
	local quickbar = d.mainHUD:FindFirstChild("Quickbar")
	local found5 = if quickbar then quickbar:FindFirstChild("Slot5") else nil
	if found5 and found5:IsA("GuiObject") then
		slot5 = found5
	end
	local found = if quickbar then quickbar:FindFirstChild("Slot6") else nil
	if found and found:IsA("GuiObject") then
		slot6 = found
		homePos = slot6.Position
		slot6HomeZ = slot6.ZIndex
		slot6Button = d.ensureButton(slot6)
		d.passthroughDecor(slot6, slot6Button)
		slot6Circle = d.ensureCircle(slot6)
		UiCircles.forceOnDescendants(slot6)
		if slot6Circle:IsA("ImageLabel") or slot6Circle:IsA("ImageButton") then
			originalImage = (slot6Circle :: any).Image
		end
		originalBg = slot6Circle.BackgroundColor3
		originalBgTrans = slot6Circle.BackgroundTransparency
		slot6Stroke = d.ensureStroke(slot6Circle, "_OceanTD_SkipRing", Color3.new(1, 1, 1), 2)
		slot6Stroke.Enabled = false

		local existing = slot6Circle:FindFirstChild("_OceanTD_SkipLabel")
		if existing and existing:IsA("TextLabel") then
			skipLabel = existing
		else
			if existing then
				existing:Destroy()
			end
			local lbl = Instance.new("TextLabel")
			lbl.Name = "_OceanTD_SkipLabel"
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.Font = UiTheme.Font
			lbl.Text = "SKIP\nWAVE"
			lbl.TextColor3 = Color3.new(1, 1, 1)
			lbl.TextScaled = true
			lbl.TextWrapped = true
			lbl.Visible = false
			lbl.ZIndex = slot6Circle.ZIndex + 2
			lbl.Active = false
			lbl.Parent = slot6Circle
			local pad = Instance.new("UIPadding")
			pad.PaddingTop = UDim.new(0.12, 0)
			pad.PaddingBottom = UDim.new(0.12, 0)
			pad.PaddingLeft = UDim.new(0.06, 0)
			pad.PaddingRight = UDim.new(0.06, 0)
			pad.Parent = lbl
			skipLabel = lbl
		end
		slot6.Visible = false
		slot6Button.Selectable = false
		slot6Button.Activated:Connect(function()
			SkipWaveSlot.beginConfirm()
		end)
		d.log("Slot6 skip-wave button ready")
	else
		warn("[WAVE] MainHUD.Quickbar.Slot6 missing — skip wave unavailable")
	end

	local quickbarHelp = d.mainHUD:FindFirstChild("QuickbarHelp")
	if quickbarHelp then
		local hs5 = quickbarHelp:FindFirstChild("Slot5")
		if hs5 and hs5:IsA("GuiObject") then
			helpSlot5 = hs5
		end
		local hs = quickbarHelp:FindFirstChild("Slot6")
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
				letter.Text = "Z"
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
			helpHit.Activated:Connect(function()
				SkipWaveSlot.beginConfirm()
			end)
		end
	end

	setSlot6Interactable(not InventoryState.isOpen())
	InventoryState.onOpenChanged(function(isOpen)
		setSlot6Interactable(not isOpen)
		SkipWaveSlot.refreshHelpBadge()
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
		SkipWaveSlot.syncToWaveRunning(snap.running)
	end)
	if lastRunning then
		SkipWaveSlot.syncToWaveRunning(true)
	end
end

return SkipWaveSlot
