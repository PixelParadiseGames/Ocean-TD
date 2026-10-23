--!strict
--[[
	Fish Cam quick pad under MobileLeftUI.dPad.FishCam:
	  Top-left  POV  — toggle coaster POV vs classic orbit (Fish Cam A)
	  Top-right II/▶ — pause path; hold-drag look while paused
	  Bottom (orbit): - / + zoom
	  Bottom (POV playing): slow / fast path rate (10 steps, default 6)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UiTheme = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiPopupScale = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("UiPopupScale"))
local Constants = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("Constants"))
local FreeCamConfig = require(script.Parent:WaitForChild("FreeCamConfig"))
local HideUiState = require(script.Parent:WaitForChild("HideUiState"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local UiIdleCycle = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("UiIdleCycle"))

local FishCamTune = {}

local ZOOM_STEP = 0.12
local DIST_SCALE_MIN = 0.2
local DIST_SCALE_MAX = 2.5
local POV_SPEED_STEPS = 10
local POV_SPEED_DEFAULT = 6 -- step 6 = 1× baseline loop rate
local POV_SLOW_ICON = "rbxassetid://82552395380168"
local POV_FAST_ICON = "rbxassetid://89015939761469"
local QUICK_NAME = "OceanTD_FishCamQuick"
local DEBUG_GUI_NAME = "OceanTD_FishCamDebug"
local QUICK_SCALE = 0.52 * 1.15 -- +15% vs cam icon
local QUICK_GAP = 6
local QUICK_ROW_GAP = 6
local BTN_BLACK = Color3.new(0, 0, 0)
local BTN_GREEN = Color3.fromRGB(40, 220, 90)
local BTN_POV_GREEN = Color3.fromRGB(28, 150, 68) -- slightly darker than pad green
local BTN_RED = Color3.fromRGB(220, 55, 55)
local BTN_DIM = Color3.fromRGB(28, 28, 32)
local FLASH_IN = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FLASH_OUT = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

do
	local left = playerGui:FindFirstChild("MobileLeftUI")
	local dPad = left and left:FindFirstChild("dPad")
	local oldQuick = (dPad and dPad:FindFirstChild(QUICK_NAME)) or playerGui:FindFirstChild(QUICK_NAME)
	if oldQuick then
		oldQuick:Destroy()
	end
	local oldDebug = playerGui:FindFirstChild(DEBUG_GUI_NAME)
	if oldDebug then
		oldDebug:Destroy()
	end
	local oldFocus = workspace:FindFirstChild("OceanTD_FishCamFocusDebug")
	if oldFocus then
		oldFocus:Destroy()
	end
end

local quickHolder: Frame? = nil
local quickGrid: UIGridLayout? = nil
local fishCamBtn: GuiObject? = nil
local layoutConn: RBXScriptConnection? = nil
local visible = false
local distScale = 1
-- Default POV on (backpack ride); pad toggle is remembered for the session.
local povOn = true
local paused = false
local povSpeedStep = POV_SPEED_DEFAULT
local yawHandler: ((number) -> ())? = nil
local onPovChanged: ((boolean) -> ())? = nil
local onPauseChanged: ((boolean) -> ())? = nil
local flashToken: { [TextButton]: number } = {}
local debugGui: ScreenGui? = nil
local zoomLabel: TextLabel? = nil

local povBtn: TextButton? = nil
local pauseBtn: TextButton? = nil
local pauseIcon: Frame? = nil -- two-bar pause glyph (❚❚ often missing from fonts)
local pausePlayLbl: TextLabel? = nil
local zoomOutBtn: TextButton? = nil
local zoomInBtn: TextButton? = nil
local zoomGlyphStop: (() -> ())? = nil
local povSlowBtn: TextButton? = nil
local povFastBtn: TextButton? = nil

local refreshToggleChrome: () -> ()
local syncBottomRow: () -> ()
local syncZoomGlyphs: () -> ()
local layoutQuickButtons: () -> ()
local syncPauseGlyph: () -> ()

function FishCamTune.bind(handlers: {
	onYaw: ((number) -> ())?,
	onPovChanged: ((boolean) -> ())?,
	onPauseChanged: ((boolean) -> ())?,
})
	yawHandler = handlers.onYaw
	onPovChanged = handlers.onPovChanged
	onPauseChanged = handlers.onPauseChanged
end

function FishCamTune.getDistScale(): number
	return distScale
end

function FishCamTune.isPovOn(): boolean
	return povOn
end

function FishCamTune.isPaused(): boolean
	return paused
end

function FishCamTune.getPovSpeedStep(): number
	return povSpeedStep
end

-- Step 6 = 1× FISH_POV_LOOP_SEC baseline; 1 = slowest, 10 = fastest.
function FishCamTune.getPovSpeedMult(): number
	return povSpeedStep / POV_SPEED_DEFAULT
end

-- Kept for FreeCam orbit steer hold compatibility (yaw buttons removed).
function FishCamTune.isSteeringOrbit(): boolean
	return false
end

function FishCamTune.setPovOn(on: boolean, silent: boolean?)
	local nextOn = on == true
	if povOn == nextOn then
		refreshToggleChrome()
		syncBottomRow()
		return
	end
	povOn = nextOn
	if not povOn then
		-- Orbit mode: pause only applies to the POV ride.
		if paused then
			paused = false
			local fn = onPauseChanged
			if fn and not silent then
				fn(false)
			end
		end
	end
	refreshToggleChrome()
	syncBottomRow()
	layoutQuickButtons()
	syncZoomGlyphs()
	local fn = onPovChanged
	if fn and not silent then
		fn(povOn)
	end
end

function FishCamTune.setPaused(on: boolean, silent: boolean?)
	local nextOn = on == true
	if not povOn then
		nextOn = false
	end
	if paused == nextOn then
		refreshToggleChrome()
		syncBottomRow()
		return
	end
	paused = nextOn
	refreshToggleChrome()
	syncBottomRow()
	layoutQuickButtons()
	syncZoomGlyphs()
	local fn = onPauseChanged
	if fn and not silent then
		fn(paused)
	end
end

local function nudgePovSpeed(delta: number): boolean
	local before = povSpeedStep
	povSpeedStep = math.clamp(povSpeedStep + delta, 1, POV_SPEED_STEPS)
	return before ~= povSpeedStep
end

local function destroyZoomDebug()
	if debugGui then
		debugGui:Destroy()
		debugGui = nil
	end
	zoomLabel = nil
end

local function refreshZoomLabel()
	local lbl = zoomLabel
	if not lbl or not lbl.Parent then
		return
	end
	lbl.Text = string.format("Zoom %.2f", distScale)
end

function FishCamTune.applyPinchScale(beginDistScale: number, touchScale: number): boolean
	if povOn then
		return false
	end
	if typeof(beginDistScale) ~= "number" or typeof(touchScale) ~= "number" then
		return false
	end
	if beginDistScale ~= beginDistScale or touchScale ~= touchScale or touchScale <= 0 then
		return false
	end
	local clamped = math.clamp(touchScale, 0.1, 10)
	local nextScale = math.clamp(beginDistScale / clamped, DIST_SCALE_MIN, DIST_SCALE_MAX)
	if nextScale == distScale then
		return false
	end
	distScale = nextScale
	refreshZoomLabel()
	return true
end

function FishCamTune.nudgeZoomByDelta(delta: number): boolean
	if povOn then
		return false
	end
	if typeof(delta) ~= "number" or delta ~= delta or delta == 0 then
		return false
	end
	local before = distScale
	distScale = math.clamp(distScale - delta * ZOOM_STEP * 2.5, DIST_SCALE_MIN, DIST_SCALE_MAX)
	if before ~= distScale then
		refreshZoomLabel()
	end
	return before ~= distScale
end

local function setDebugVisible(_on: boolean)
	destroyZoomDebug()
end

local function resolveFishCamButton(): GuiObject?
	if fishCamBtn and fishCamBtn.Parent then
		return fishCamBtn
	end
	local left = playerGui:FindFirstChild("MobileLeftUI")
	local dPad = left and left:FindFirstChild("dPad")
	local fish = dPad and dPad:FindFirstChild("FishCam")
	if fish and fish:IsA("GuiObject") then
		fishCamBtn = fish
		return fish
	end
	return nil
end

local function flashQuickButton(btn: TextButton, ok: boolean)
	flashToken[btn] = (flashToken[btn] or 0) + 1
	local my = flashToken[btn]
	btn.AutoButtonColor = false
	local twIn = TweenService:Create(btn, FLASH_IN, {
		BackgroundColor3 = if ok then BTN_GREEN else BTN_RED,
	})
	twIn:Play()
	twIn.Completed:Once(function()
		if flashToken[btn] ~= my then
			return
		end
		local twOut = TweenService:Create(btn, FLASH_OUT, {
			BackgroundColor3 = BTN_BLACK,
		})
		twOut:Play()
		twOut.Completed:Once(function()
			if flashToken[btn] == my then
				btn.BackgroundColor3 = BTN_BLACK
				btn.AutoButtonColor = true
			end
		end)
	end)
end

local function paintToggle(btn: TextButton?, on: boolean, enabled: boolean, offColor: Color3?)
	if not btn then
		return
	end
	btn.AutoButtonColor = false
	if not enabled then
		btn.BackgroundColor3 = BTN_DIM
		btn.TextTransparency = 0.45
		return
	end
	btn.TextTransparency = 0
	btn.BackgroundColor3 = if on then BTN_GREEN else (offColor or BTN_BLACK)
end

syncPauseGlyph = function()
	if pauseBtn then
		pauseBtn.Text = ""
		pauseBtn.Active = povOn
		pauseBtn.AutoButtonColor = false
	end
	if pauseIcon then
		pauseIcon.Visible = povOn and not paused
	end
	if pausePlayLbl then
		pausePlayLbl.Visible = povOn and paused
	end
end

refreshToggleChrome = function()
	-- POV on = darker green, off = red. Pause/play stays black (glyph only swaps).
	if povBtn then
		povBtn.AutoButtonColor = false
		povBtn.Text = "POV"
		povBtn.TextTransparency = 0
		povBtn.BackgroundColor3 = if povOn then BTN_POV_GREEN else BTN_RED
	end
	if pauseBtn then
		pauseBtn.AutoButtonColor = false
		pauseBtn.BackgroundColor3 = if povOn then BTN_BLACK else BTN_DIM
		pauseBtn.TextTransparency = 0
	end
	syncPauseGlyph()
end

syncBottomRow = function()
	local showZoom = not povOn
	local showPovSpeed = povOn and not paused
	if zoomOutBtn then
		zoomOutBtn.Visible = showZoom
	end
	if zoomInBtn then
		zoomInBtn.Visible = showZoom
	end
	if povSlowBtn then
		povSlowBtn.Visible = showPovSpeed
	end
	if povFastBtn then
		povFastBtn.Visible = showPovSpeed
	end
end

local function makeRoundQuick(parent: Frame, name: string, text: string, order: number, sizePx: number): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.LayoutOrder = order
	b.Size = UDim2.fromOffset(sizePx, sizePx)
	b.BackgroundColor3 = BTN_BLACK
	b.BackgroundTransparency = 0
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = UiTheme.Font
	b.TextSize = math.clamp(math.floor(sizePx * 0.42), 11, 18)
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Text = text
	b.ZIndex = 50
	b.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = Color3.fromRGB(80, 100, 120)
	stroke.Transparency = 0.35
	stroke.Parent = b
	return b
end

local function carouselCollapsedReady(): boolean
	return playerGui:GetAttribute(FreeCamConfig.ATTR_CAROUSEL_COLLAPSED) == true
end

layoutQuickButtons = function()
	local holder = quickHolder
	local fish = resolveFishCamButton()
	if not holder or not fish then
		return
	end
	local dPad = fish.Parent
	if not (dPad and dPad:IsA("GuiObject")) then
		return
	end
	if holder.Parent ~= dPad then
		holder.Parent = dPad
	end

	local as = fish.AbsoluteSize
	local ap = fish.AbsolutePosition
	local dAp = dPad.AbsolutePosition
	if as.X < 2 or as.Y < 2 then
		return
	end

	-- Same as the plot-cam pad: dPad's 720p UIScale is already in AbsoluteSize.
	-- Offsets are in unscaled parent space so the pad stays under the fish button.
	local uiScale = UiPopupScale.ancestorScale(dPad)
	local side = math.max(22, math.floor(math.min(as.X, as.Y) * QUICK_SCALE / uiScale))
	local gap = QUICK_GAP / uiScale
	local rowGap = QUICK_ROW_GAP / uiScale
	local width = side * 2 + gap
	-- One row only while POV is paused (play); otherwise top + bottom.
	local rows = if (povOn and paused) then 1 else 2
	local height = side * rows + rowGap * (rows - 1)
	holder.Size = UDim2.fromOffset(width, height)
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.fromOffset(
		math.floor((ap.X + as.X * 0.5 - dAp.X) / uiScale),
		math.floor((ap.Y + as.Y - dAp.Y) / uiScale + rowGap)
	)
	if quickGrid then
		quickGrid.CellSize = UDim2.fromOffset(side, side)
		quickGrid.CellPadding = UDim2.fromOffset(gap, rowGap)
	end
	for _, ch in ipairs(holder:GetChildren()) do
		if ch:IsA("TextButton") then
			ch.Size = UDim2.fromOffset(side, side)
			local isPov = ch.Name == "PovToggle"
			local shoulder = ch.Text == "L2" or ch.Text == "R2"
			local factor = if isPov then 0.34 elseif shoulder then 0.30 else 0.42
			ch.TextScaled = false
			ch.TextSize = math.clamp(math.floor(side * factor), 10, if shoulder then 14 else 18)
		end
	end
	syncBottomRow()
	refreshToggleChrome()
end

local function nudgeZoom(zoomOut: boolean): boolean
	if povOn then
		return false
	end
	local before = distScale
	if zoomOut then
		distScale = math.clamp(distScale + ZOOM_STEP, DIST_SCALE_MIN, DIST_SCALE_MAX)
	else
		distScale = math.clamp(distScale - ZOOM_STEP, DIST_SCALE_MIN, DIST_SCALE_MAX)
	end
	if before ~= distScale then
		refreshZoomLabel()
	end
	return before ~= distScale
end

local function ensureQuickPad(): Frame?
	if quickHolder and quickHolder.Parent then
		return quickHolder
	end
	local fish = resolveFishCamButton()
	local dPad = fish and fish.Parent
	if not (dPad and dPad:IsA("GuiObject")) then
		return nil
	end

	local holder = Instance.new("Frame")
	holder.Name = QUICK_NAME
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Visible = false
	holder.ZIndex = 40
	holder.Parent = dPad

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(36, 36)
	grid.CellPadding = UDim2.fromOffset(QUICK_GAP, QUICK_ROW_GAP)
	grid.FillDirectionMaxCells = 2
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.VerticalAlignment = Enum.VerticalAlignment.Top
	grid.Parent = holder
	quickGrid = grid

	local pov = makeRoundQuick(holder, "PovToggle", "POV", 1, 36)
	local pause = makeRoundQuick(holder, "PauseToggle", "", 2, 36)
	local zoomOut = makeRoundQuick(holder, "ZoomOut", "-", 3, 36)
	local zoomIn = makeRoundQuick(holder, "ZoomIn", "+", 4, 36)
	local slow = makeRoundQuick(holder, "PovSlow", "", 5, 36)
	local fast = makeRoundQuick(holder, "PovFast", "", 6, 36)
	povBtn = pov
	pauseBtn = pause
	zoomOutBtn = zoomOut
	zoomInBtn = zoomIn
	povSlowBtn = slow
	povFastBtn = fast

	local function addPadIcon(btn: TextButton, imageId: string)
		local img = Instance.new("ImageLabel")
		img.Name = "Icon"
		img.BackgroundTransparency = 1
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.fromScale(0.5, 0.5)
		img.Size = UDim2.fromScale(0.62, 0.62)
		img.Image = imageId
		img.ScaleType = Enum.ScaleType.Fit
		img.ZIndex = 51
		img.Parent = btn
	end
	addPadIcon(slow, POV_SLOW_ICON)
	addPadIcon(fast, POV_FAST_ICON)
	slow.Visible = false
	fast.Visible = false

	-- Classic pause bars (same idea as wave-speed pause affordance; font glyphs often blank).
	local bars = Instance.new("Frame")
	bars.Name = "PauseBars"
	bars.BackgroundTransparency = 1
	bars.AnchorPoint = Vector2.new(0.5, 0.5)
	bars.Position = UDim2.fromScale(0.5, 0.5)
	bars.Size = UDim2.fromScale(0.42, 0.48)
	bars.ZIndex = 51
	bars.Parent = pause
	local barL = Instance.new("Frame")
	barL.Name = "L"
	barL.BackgroundColor3 = Color3.new(1, 1, 1)
	barL.BorderSizePixel = 0
	barL.Size = UDim2.new(0.32, 0, 1, 0)
	barL.Position = UDim2.fromScale(0, 0)
	barL.ZIndex = 52
	barL.Parent = bars
	local barR = Instance.new("Frame")
	barR.Name = "R"
	barR.BackgroundColor3 = Color3.new(1, 1, 1)
	barR.BorderSizePixel = 0
	barR.Size = UDim2.new(0.32, 0, 1, 0)
	barR.Position = UDim2.fromScale(0.68, 0)
	barR.ZIndex = 52
	barR.Parent = bars
	pauseIcon = bars

	local playLbl = Instance.new("TextLabel")
	playLbl.Name = "PlayGlyph"
	playLbl.BackgroundTransparency = 1
	playLbl.Size = UDim2.fromScale(1, 1)
	playLbl.Font = UiTheme.Font
	playLbl.Text = "▶"
	playLbl.TextColor3 = Color3.new(1, 1, 1)
	playLbl.TextScaled = true
	playLbl.ZIndex = 51
	playLbl.Visible = false
	playLbl.Parent = pause
	local playPad = Instance.new("UIPadding")
	playPad.PaddingLeft = UDim.new(0.18, 0)
	playPad.PaddingRight = UDim.new(0.12, 0)
	playPad.PaddingTop = UDim.new(0.12, 0)
	playPad.PaddingBottom = UDim.new(0.12, 0)
	playPad.Parent = playLbl
	pausePlayLbl = playLbl

	pov.Activated:Connect(function()
		FishCamTune.setPovOn(not povOn)
	end)
	pause.Activated:Connect(function()
		if not povOn then
			flashQuickButton(pause, false)
			refreshToggleChrome()
			return
		end
		FishCamTune.setPaused(not paused)
	end)
	zoomOut.Activated:Connect(function()
		flashQuickButton(zoomOut, nudgeZoom(true))
	end)
	zoomIn.Activated:Connect(function()
		flashQuickButton(zoomIn, nudgeZoom(false))
	end)
	slow.Activated:Connect(function()
		flashQuickButton(slow, nudgePovSpeed(-1))
	end)
	fast.Activated:Connect(function()
		flashQuickButton(fast, nudgePovSpeed(1))
	end)

	quickHolder = holder
	syncBottomRow()
	refreshToggleChrome()
	layoutQuickButtons()
	return holder
end

local function setQuickVisible(on: boolean)
	local holder = ensureQuickPad()
	if holder then
		holder.Visible = on
	end
	if layoutConn then
		layoutConn:Disconnect()
		layoutConn = nil
	end
	if on then
		layoutQuickButtons()
		layoutConn = RunService.RenderStepped:Connect(layoutQuickButtons)
	end
end

local function hudBlocksQuick(): boolean
	if playerGui:GetAttribute("OceanTD_StoreOpen") == true
		or playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true
		or playerGui:GetAttribute("OceanTD_ReefReportOpen") == true
	then
		return true
	end
	if HideUiState.isActive() and not InventoryState.isOpen() then
		return true
	end
	return false
end

local function isGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function applyZoomGlyph(btn: TextButton, base: string, shoulder: string, alt: boolean)
	btn.TextScaled = false
	btn.Text = if alt then shoulder else base
end

function syncZoomGlyphs()
	if zoomGlyphStop then
		zoomGlyphStop()
		zoomGlyphStop = nil
	end
	local minus = zoomOutBtn
	local plus = zoomInBtn
	if not minus or not plus then
		return
	end
	local holder = quickHolder
	if not holder or not holder.Visible or not isGamepad() or not minus.Visible then
		applyZoomGlyph(minus, "-", "L2", false)
		applyZoomGlyph(plus, "+", "R2", false)
		return
	end
	zoomGlyphStop = UiIdleCycle.subscribeSharedToggle(2, function(alt: boolean)
		if zoomOutBtn then
			applyZoomGlyph(zoomOutBtn, "-", "L2", alt)
		end
		if zoomInBtn then
			applyZoomGlyph(zoomInBtn, "+", "R2", alt)
		end
	end, function()
		return isGamepad()
			and quickHolder ~= nil
			and (quickHolder :: Frame).Visible
			and zoomOutBtn ~= nil
			and (zoomOutBtn :: TextButton).Visible
	end)
end

local function syncQuickVisibility()
	local camMode = playerGui:GetAttribute(FreeCamConfig.ATTR_MODE)
	if camMode ~= nil and camMode ~= "fishcam" then
		setQuickVisible(false)
		return
	end
	setQuickVisible(visible and carouselCollapsedReady() and not hudBlocksQuick())
	syncZoomGlyphs()
end

function FishCamTune.setVisible(on: boolean)
	visible = on == true
	syncQuickVisibility()
	setDebugVisible(false)
end

function FishCamTune.isVisible(): boolean
	return visible
end

function FishCamTune.resetZoom()
	distScale = 1
	refreshZoomLabel()
end

playerGui:GetAttributeChangedSignal(FreeCamConfig.ATTR_CAROUSEL_COLLAPSED):Connect(syncQuickVisibility)
playerGui:GetAttributeChangedSignal(FreeCamConfig.ATTR_MODE):Connect(syncQuickVisibility)
playerGui:GetAttributeChangedSignal("OceanTD_StoreOpen"):Connect(syncQuickVisibility)
playerGui:GetAttributeChangedSignal("OceanTD_SkillsBubblesOpen"):Connect(syncQuickVisibility)
playerGui:GetAttributeChangedSignal("OceanTD_ReefReportOpen"):Connect(syncQuickVisibility)
playerGui:GetAttributeChangedSignal(Constants.HIDE_UI_ACTIVE_ATTR):Connect(syncQuickVisibility)
HideUiState.onChanged(syncQuickVisibility)
InventoryState.onOpenChanged(function()
	syncQuickVisibility()
end)
UserInputService.LastInputTypeChanged:Connect(syncQuickVisibility)

UserInputService.InputBegan:Connect(function(input, _gameProcessed)
	if input.UserInputType ~= Enum.UserInputType.Gamepad1
		and input.UserInputType ~= Enum.UserInputType.Gamepad2
		and input.UserInputType ~= Enum.UserInputType.Gamepad3
		and input.UserInputType ~= Enum.UserInputType.Gamepad4
	then
		return
	end
	local minus = zoomOutBtn
	local plus = zoomInBtn
	local holder = quickHolder
	if not minus or not plus or not holder or not holder.Visible or not minus.Visible then
		return
	end
	if input.KeyCode == Enum.KeyCode.ButtonL2 then
		local ok = nudgeZoom(true)
		flashQuickButton(minus, ok)
	elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
		local ok = nudgeZoom(false)
		flashQuickButton(plus, ok)
	end
end)

return FishCamTune
