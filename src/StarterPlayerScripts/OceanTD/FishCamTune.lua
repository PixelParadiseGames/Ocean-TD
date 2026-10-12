--!strict
--[[
	Four quick buttons under MobileLeftUI.dPad.FishCam (yaw ‹ ›, zoom -/+).
	Mirrors PlotCam2Tune's quick pad; zoom scales chase distance, yaw spins orbit.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UiTheme = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("UiTheme"))
local Constants = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("Constants"))
local FreeCamConfig = require(script.Parent:WaitForChild("FreeCamConfig"))
local HideUiState = require(script.Parent:WaitForChild("HideUiState"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))

local FishCamTune = {}

local YAW_STEP_RAD = math.rad(15)
local ZOOM_STEP = 0.12
local DIST_SCALE_MIN = 0.2 -- twice as close as prior 0.4 floor
local DIST_SCALE_MAX = 2.5
local QUICK_NAME = "OceanTD_FishCamQuick"
local DEBUG_GUI_NAME = "OceanTD_FishCamDebug"
local QUICK_SCALE = 0.52
local QUICK_GAP = 6
local QUICK_ROW_GAP = 6
local BTN_BLACK = Color3.new(0, 0, 0)
local BTN_GREEN = Color3.fromRGB(40, 220, 90)
local BTN_RED = Color3.fromRGB(220, 55, 55)
local FLASH_IN = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FLASH_OUT = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local STEER_HOLD_SEC = 0.85

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
local steerUntil = 0
local yawHandler: ((number) -> ())? = nil
local flashToken: { [TextButton]: number } = {}
local debugGui: ScreenGui? = nil
local zoomLabel: TextLabel? = nil

function FishCamTune.bind(handlers: { onYaw: (number) -> () })
	yawHandler = handlers.onYaw
end

function FishCamTune.getDistScale(): number
	return distScale
end

function FishCamTune.isSteeringOrbit(): boolean
	return os.clock() < steerUntil
end

local function destroyZoomDebug()
	if debugGui then
		debugGui:Destroy()
		debugGui = nil
	end
	zoomLabel = nil
end

local function ensureZoomDebug(): TextLabel?
	if zoomLabel and zoomLabel.Parent and debugGui and debugGui.Parent then
		return zoomLabel
	end
	destroyZoomDebug()
	local sg = Instance.new("ScreenGui")
	sg.Name = DEBUG_GUI_NAME
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 9200
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui

	local lbl = Instance.new("TextLabel")
	lbl.Name = "ZoomLevel"
	lbl.AnchorPoint = Vector2.new(1, 0.5)
	lbl.Position = UDim2.new(1, -18, 0.5, 0)
	lbl.Size = UDim2.fromOffset(120, 36)
	lbl.BackgroundColor3 = Color3.fromRGB(12, 18, 28)
	lbl.BackgroundTransparency = 0.25
	lbl.BorderSizePixel = 0
	lbl.Font = UiTheme.Font
	lbl.TextSize = 18
	lbl.TextColor3 = Color3.fromRGB(220, 245, 255)
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.Text = "Zoom 1.00"
	lbl.Parent = sg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = lbl
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(80, 160, 200)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.35
	stroke.Parent = lbl

	debugGui = sg
	zoomLabel = lbl
	return lbl
end

local function refreshZoomLabel()
	local lbl = zoomLabel
	if not lbl or not lbl.Parent then
		return
	end
	lbl.Text = string.format("Zoom %.2f", distScale)
end

-- BaseCamera-style pinch: beginDistScale / clamp(touchScale).
function FishCamTune.applyPinchScale(beginDistScale: number, touchScale: number): boolean
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

-- PointerAction pinch delta: positive → zoom in (closer).
function FishCamTune.nudgeZoomByDelta(delta: number): boolean
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
	-- Zoom readout debug stays off in shipping builds.
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
		local twOut = TweenService:Create(btn, FLASH_OUT, { BackgroundColor3 = BTN_BLACK })
		twOut:Play()
		twOut.Completed:Once(function()
			if flashToken[btn] == my then
				btn.BackgroundColor3 = BTN_BLACK
				btn.AutoButtonColor = true
			end
		end)
	end)
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
	b.TextSize = math.clamp(math.floor(sizePx * 0.55), 14, 22)
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

local function layoutQuickButtons()
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

	local side = math.max(22, math.floor(math.min(as.X, as.Y) * QUICK_SCALE))
	local width = side * 2 + QUICK_GAP
	local height = side * 2 + QUICK_ROW_GAP
	holder.Size = UDim2.fromOffset(width, height)
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.fromOffset(
		math.floor(ap.X + as.X * 0.5 - dAp.X),
		math.floor(ap.Y + as.Y + QUICK_ROW_GAP - dAp.Y)
	)
	if quickGrid then
		quickGrid.CellSize = UDim2.fromOffset(side, side)
	end
	for _, ch in ipairs(holder:GetChildren()) do
		if ch:IsA("TextButton") then
			ch.Size = UDim2.fromOffset(side, side)
			ch.TextSize = math.clamp(math.floor(side * 0.55), 14, 22)
		end
	end
end

local function nudgeYaw(dir: number): boolean
	local fn = yawHandler
	if not fn then
		return false
	end
	-- dir -1 = ‹ (left), +1 = › (right). Match look-drag: right decreases orbitAngle.
	fn(dir * YAW_STEP_RAD)
	steerUntil = os.clock() + STEER_HOLD_SEC
	return true
end

local function nudgeZoom(zoomOut: boolean): boolean
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

	local yawLeft = makeRoundQuick(holder, "YawLeft", "‹", 1, 36)
	local yawRight = makeRoundQuick(holder, "YawRight", "›", 2, 36)
	local zoomOut = makeRoundQuick(holder, "ZoomOut", "-", 3, 36)
	local zoomIn = makeRoundQuick(holder, "ZoomIn", "+", 4, 36)

	yawLeft.Activated:Connect(function()
		flashQuickButton(yawLeft, nudgeYaw(-1))
	end)
	yawRight.Activated:Connect(function()
		flashQuickButton(yawRight, nudgeYaw(1))
	end)
	zoomOut.Activated:Connect(function()
		flashQuickButton(zoomOut, nudgeZoom(true))
	end)
	zoomIn.Activated:Connect(function()
		flashQuickButton(zoomIn, nudgeZoom(false))
	end)

	quickHolder = holder
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

local function syncQuickVisibility()
	setQuickVisible(visible and carouselCollapsedReady() and not hudBlocksQuick())
end

function FishCamTune.setVisible(on: boolean)
	visible = on == true
	syncQuickVisibility()
	setDebugVisible(visible)
end

function FishCamTune.isVisible(): boolean
	return visible
end

function FishCamTune.resetZoom()
	distScale = 1
	refreshZoomLabel()
end

playerGui:GetAttributeChangedSignal(FreeCamConfig.ATTR_CAROUSEL_COLLAPSED):Connect(syncQuickVisibility)
playerGui:GetAttributeChangedSignal("OceanTD_StoreOpen"):Connect(syncQuickVisibility)
playerGui:GetAttributeChangedSignal("OceanTD_SkillsBubblesOpen"):Connect(syncQuickVisibility)
playerGui:GetAttributeChangedSignal("OceanTD_ReefReportOpen"):Connect(syncQuickVisibility)
playerGui:GetAttributeChangedSignal(Constants.HIDE_UI_ACTIVE_ATTR):Connect(syncQuickVisibility)
HideUiState.onChanged(syncQuickVisibility)
InventoryState.onOpenChanged(function()
	syncQuickVisibility()
end)

return FishCamTune
