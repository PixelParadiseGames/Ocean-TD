--!strict
--[[
	Temporary in-game tuner for Plot Cam 2.
	Visible only while Plot Cam (variant 2) is active. ±5 per click, live apply.
	Readout is paste-ready for baking defaults later.
	Also: four small black round quick buttons under MobileLeftUI.dPad.PlotCam
	(yaw ‹ ›, DistOff -/+).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UiTheme = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("UiTheme"))
local FreeCamConfig = require(script.Parent:WaitForChild("FreeCamConfig"))
local PlotCam2 = require(script.Parent:WaitForChild("PlotCam2"))

local PlotCam2Tune = {}

local STEP = 5
local YAW_STEP = 10
local GUI_NAME = "OceanTD_PlotCam2Tune"
local SHOW_DEBUG_PANEL = false
local QUICK_NAME = "OceanTD_PlotCam2Quick"
local PANEL_W = 320
local PANEL_H = 250
local TITLE_H = 22
local RESET_H = 28
local READOUT_H = 56
local GAP = 6
local QUICK_SCALE = 0.52 -- vs PlotCam button size
local QUICK_GAP = 6
local QUICK_ROW_GAP = 6
local BTN_BLACK = Color3.new(0, 0, 0)
local BTN_GREEN = Color3.fromRGB(40, 220, 90)
local BTN_RED = Color3.fromRGB(220, 55, 55)
local FLASH_IN = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FLASH_OUT = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

-- Drop stale panel if this module hot-reloads with new rows.
do
	local old = playerGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local left = playerGui:FindFirstChild("MobileLeftUI")
	local dPad = left and left:FindFirstChild("dPad")
	local oldQuick = (dPad and dPad:FindFirstChild(QUICK_NAME)) or playerGui:FindFirstChild(QUICK_NAME)
	if oldQuick then
		oldQuick:Destroy()
	end
end

local gui: ScreenGui? = nil
local quickHolder: Frame? = nil
local quickGrid: UIGridLayout? = nil
local plotCamBtn: GuiObject? = nil
local layoutConn: RBXScriptConnection? = nil
local readout: TextBox? = nil
local visible = false

local function refreshReadout()
	if readout then
		readout.Text = PlotCam2.formatTune()
	end
end

local function makeBtn(parent: Instance, text: string, order: number, z: number): TextButton
	local b = Instance.new("TextButton")
	b.Name = text
	b.LayoutOrder = order
	b.Size = UDim2.new(0, 36, 0, 28)
	b.BackgroundColor3 = Color3.fromRGB(40, 52, 68)
	b.BorderSizePixel = 0
	b.Font = UiTheme.Font
	b.TextSize = 16
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Text = text
	b.AutoButtonColor = true
	b.ZIndex = z
	b.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = b
	return b
end

local function addRow(parent: Frame, label: string, key: string, order: number, z: number)
	local row = Instance.new("Frame")
	row.Name = key
	row.LayoutOrder = order
	row.Size = UDim2.new(1, -4, 0, 32)
	row.BackgroundTransparency = 1
	row.ZIndex = z
	row.Parent = parent

	local lay = Instance.new("UIListLayout")
	lay.FillDirection = Enum.FillDirection.Horizontal
	lay.VerticalAlignment = Enum.VerticalAlignment.Center
	lay.Padding = UDim.new(0, 6)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Parent = row

	local minus = makeBtn(row, "-", 1, z)
	local name = Instance.new("TextLabel")
	name.Name = "Label"
	name.LayoutOrder = 2
	name.Size = UDim2.new(0, 120, 1, 0)
	name.BackgroundTransparency = 1
	name.Font = UiTheme.Font
	name.TextSize = 14
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = Color3.fromRGB(220, 235, 245)
	name.Text = label
	name.ZIndex = z
	name.Parent = row
	local plus = makeBtn(row, "+", 3, z)

	minus.Activated:Connect(function()
		PlotCam2.nudge(key, -STEP)
		refreshReadout()
	end)
	plus.Activated:Connect(function()
		PlotCam2.nudge(key, STEP)
		refreshReadout()
	end)
end

local function ensureGui(): ScreenGui
	if gui and gui.Parent then
		return gui
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = GUI_NAME
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 9200
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Enabled = false
	sg.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -16, 0, 72)
	panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
	panel.BackgroundColor3 = Color3.fromRGB(16, 22, 30)
	panel.BackgroundTransparency = 0.15
	panel.BorderSizePixel = 0
	panel.ClipsDescendants = true
	panel.ZIndex = 10
	panel.Parent = sg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, TITLE_H)
	title.BackgroundTransparency = 1
	title.Font = UiTheme.Font
	title.TextSize = 16
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(120, 220, 160)
	title.Text = "Plot Cam 2 Tune  (±5)"
	title.ZIndex = 11
	title.Parent = panel

	local box = Instance.new("TextBox")
	box.Name = "Readout"
	box.AnchorPoint = Vector2.new(0, 1)
	box.Position = UDim2.new(0, 0, 1, 0)
	box.Size = UDim2.new(1, 0, 0, READOUT_H)
	box.BackgroundColor3 = Color3.fromRGB(8, 12, 18)
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.TextEditable = true
	box.TextWrapped = true
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Top
	box.Font = Enum.Font.Code
	box.TextSize = 12
	box.TextColor3 = Color3.fromRGB(200, 255, 210)
	box.Text = ""
	box.ZIndex = 12
	box.Parent = panel
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 6)
	bc.Parent = box
	local bpad = Instance.new("UIPadding")
	bpad.PaddingTop = UDim.new(0, 4)
	bpad.PaddingLeft = UDim.new(0, 6)
	bpad.PaddingRight = UDim.new(0, 6)
	bpad.Parent = box

	local reset = Instance.new("TextButton")
	reset.Name = "Reset"
	reset.AnchorPoint = Vector2.new(0, 1)
	reset.Position = UDim2.new(0, 0, 1, -(READOUT_H + GAP))
	reset.Size = UDim2.new(1, 0, 0, RESET_H)
	reset.BackgroundColor3 = Color3.fromRGB(90, 50, 50)
	reset.BorderSizePixel = 0
	reset.Font = UiTheme.Font
	reset.TextSize = 14
	reset.TextColor3 = Color3.new(1, 1, 1)
	reset.Text = "Reset this plot"
	reset.ZIndex = 12
	reset.Parent = panel
	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0, 6)
	rc.Parent = reset
	reset.Activated:Connect(function()
		PlotCam2.resetTune()
		refreshReadout()
	end)

	local scrollBottom = READOUT_H + GAP + RESET_H + GAP
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Rows"
	scroll.Position = UDim2.fromOffset(0, TITLE_H + GAP)
	scroll.Size = UDim2.new(1, 0, 1, -(TITLE_H + GAP + scrollBottom))
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = Color3.fromRGB(90, 140, 160)
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ZIndex = 11
	scroll.Parent = panel

	local list = Instance.new("Frame")
	list.Name = "Content"
	list.Size = UDim2.new(1, -8, 0, 0)
	list.AutomaticSize = Enum.AutomaticSize.Y
	list.BackgroundTransparency = 1
	list.ZIndex = 11
	list.Parent = scroll
	local listLay = Instance.new("UIListLayout")
	listLay.SortOrder = Enum.SortOrder.LayoutOrder
	listLay.Padding = UDim.new(0, 4)
	listLay.Parent = list
	local listPad = Instance.new("UIPadding")
	listPad.PaddingBottom = UDim.new(0, 4)
	listPad.Parent = list

	addRow(list, "Yaw", "yawDeg", 1, 12)
	addRow(list, "YawBias", "yawBiasDeg", 2, 12)
	addRow(list, "Pitch", "pitchDeg", 3, 12)
	addRow(list, "DistFront", "distFront", 4, 12)
	addRow(list, "DistBack", "distBack", 5, 12)
	addRow(list, "DistOff", "distOffset", 6, 12)
	addRow(list, "FocusH", "focusHeight", 7, 12)
	addRow(list, "PanOut", "panOut", 8, 12)
	addRow(list, "PanIn", "panIn", 9, 12)
	addRow(list, "PanSide", "panSide", 10, 12)

	readout = box
	gui = sg
	return sg
end

local function resolvePlotCamButton(): GuiObject?
	if plotCamBtn and plotCamBtn.Parent then
		return plotCamBtn
	end
	local left = playerGui:FindFirstChild("MobileLeftUI")
	local dPad = left and left:FindFirstChild("dPad")
	local plot = dPad and dPad:FindFirstChild("PlotCam")
	if plot and plot:IsA("GuiObject") then
		plotCamBtn = plot
		return plot
	end
	return nil
end

local flashToken: { [TextButton]: number } = {}

local function flashQuickButton(btn: TextButton, ok: boolean)
	flashToken[btn] = (flashToken[btn] or 0) + 1
	local my = flashToken[btn]
	btn.AutoButtonColor = false
	btn.BackgroundColor3 = if ok then BTN_GREEN else BTN_RED
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
	local plot = resolvePlotCamButton()
	if not holder or not plot then
		return
	end
	local dPad = plot.Parent
	if not (dPad and dPad:IsA("GuiObject")) then
		return
	end
	if holder.Parent ~= dPad then
		holder.Parent = dPad
	end

	local as = plot.AbsoluteSize
	local ap = plot.AbsolutePosition
	local dAp = dPad.AbsolutePosition
	if as.X < 2 or as.Y < 2 then
		return
	end

	local side = math.max(22, math.floor(math.min(as.X, as.Y) * QUICK_SCALE))
	local width = side * 2 + QUICK_GAP
	local height = side * 2 + QUICK_ROW_GAP
	holder.Size = UDim2.fromOffset(width, height)
	holder.AnchorPoint = Vector2.new(0.5, 0)
	-- Same parent as PlotCam — place just under its absolute bottom.
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

local function ensureQuickPad(): Frame?
	if quickHolder and quickHolder.Parent then
		return quickHolder
	end
	local plot = resolvePlotCamButton()
	local dPad = plot and plot.Parent
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
	local offMinus = makeRoundQuick(holder, "DistOffMinus", "-", 3, 36)
	local offPlus = makeRoundQuick(holder, "DistOffPlus", "+", 4, 36)

	local function wireQuick(btn: TextButton, key: string, delta: number)
		btn.Activated:Connect(function()
			local ok = PlotCam2.nudge(key, delta)
			flashQuickButton(btn, ok)
			refreshReadout()
		end)
	end
	wireQuick(yawLeft, "yawDeg", -YAW_STEP)
	wireQuick(yawRight, "yawDeg", YAW_STEP)
	-- "-" zooms out (raise DistOff); "+" zooms in (lower DistOff).
	wireQuick(offMinus, "distOffset", STEP)
	wireQuick(offPlus, "distOffset", -STEP)

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

local function syncQuickVisibility()
	-- Yaw / DistOff quick pad under Plot Cam — keep these even when the full tuner panel is off.
	setQuickVisible(visible and carouselCollapsedReady())
end

function PlotCam2Tune.setVisible(on: boolean)
	visible = on == true
	if SHOW_DEBUG_PANEL then
		local sg = ensureGui()
		sg.Enabled = visible
		if visible then
			refreshReadout()
		end
	elseif gui then
		gui.Enabled = false
	end
	syncQuickVisibility()
end

playerGui:GetAttributeChangedSignal(FreeCamConfig.ATTR_CAROUSEL_COLLAPSED):Connect(function()
	syncQuickVisibility()
end)

function PlotCam2Tune.isVisible(): boolean
	return visible
end

function PlotCam2Tune.refresh()
	if visible then
		refreshReadout()
		layoutQuickButtons()
	end
end

-- Keep readout fresh while open (wheel zoom / pan don't change angles, but dist can).
task.spawn(function()
	while true do
		if visible and PlotCam2.isActive() then
			refreshReadout()
		end
		task.wait(0.2)
	end
end)

-- Convenience: press ; while plotcam tune is up to print readout to output.
UserInputService.InputBegan:Connect(function(input, gp)
	if gp or not visible then
		return
	end
	if input.KeyCode == Enum.KeyCode.Semicolon then
		print("[PlotCam2Tune]", PlotCam2.formatTune())
		refreshReadout()
	end
end)

return PlotCam2Tune
