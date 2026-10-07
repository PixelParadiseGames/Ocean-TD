--!strict
-- Inline recycle confirm in the coral inspect header:
-- Cancel slides left from Recycle; Recycle becomes Confirm.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))

local Consts = require(script.Parent:WaitForChild("CoralInspectPanelConsts"))
local PlaceConfirmChrome = require(script.Parent:WaitForChild("PlaceConfirmChrome"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))

local M = {}

local recycleBtn: TextButton? = nil
local recycleCancelBtn: TextButton? = nil
local recycleIconLbl: ImageLabel? = nil
local nameLbl: TextLabel? = nil
local getRoot: (() -> Frame?)? = nil
local hideStatsKey: (() -> ())? = nil
local hideConfirm: (() -> ())? = nil

local confirmUi = false
local pulseConn: RBXScriptConnection? = nil
local headerSide = 40

local function isGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function stopPulse()
	if pulseConn then
		pulseConn:Disconnect()
		pulseConn = nil
	end
end

local function layoutCancel(side: number, slidOut: boolean)
	local cancel = recycleCancelBtn
	if not cancel then
		return
	end
	cancel.Size = UDim2.fromOffset(side, side)
	if slidOut then
		cancel.Position = UDim2.new(1, -(side + Consts.REC_CANCEL_GAP), 0.5, 2)
	else
		cancel.Position = UDim2.new(1, 0, 0.5, 2)
	end
end

local function restoreIdleFace()
	local btn = recycleBtn
	if not btn then
		return
	end
	btn.BackgroundColor3 = Consts.REC_GREEN
	btn.Text = ""
	btn.TextTransparency = 1
	btn.TextScaled = true
	local checkIcon = btn:FindFirstChild("ConfirmCheckIcon")
	if checkIcon and checkIcon:IsA("ImageLabel") then
		checkIcon.Visible = false
	end
	if recycleIconLbl then
		recycleIconLbl.Visible = true
	end
end

function M.exit(animate: boolean?)
	if not confirmUi and not (recycleCancelBtn and recycleCancelBtn.Visible) then
		restoreIdleFace()
		return
	end
	confirmUi = false
	stopPulse()
	restoreIdleFace()
	local cancel = recycleCancelBtn
	if not cancel then
		return
	end
	local side = headerSide
	local doAnim = animate ~= false and cancel.Visible
	if doAnim then
		local tw = TweenService:Create(
			cancel,
			TweenInfo.new(Consts.REC_SLIDE_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = UDim2.new(1, 0, 0.5, 2) }
		)
		tw:Play()
		tw.Completed:Connect(function()
			if not confirmUi and cancel.Parent then
				cancel.Visible = false
				layoutCancel(side, false)
			end
		end)
	else
		cancel.Visible = false
		layoutCancel(side, false)
	end
end

function M.enter()
	local root = if getRoot then getRoot() else nil
	if not root or not root.Visible then
		return
	end
	local btn = recycleBtn
	local cancel = recycleCancelBtn
	if not btn or not cancel then
		return
	end
	if confirmUi then
		return
	end
	confirmUi = true
	if hideStatsKey then
		hideStatsKey()
	end
	if hideConfirm then
		hideConfirm()
	end
	local side = headerSide
	cancel.Size = UDim2.fromOffset(side, side)
	cancel.Position = UDim2.new(1, 0, 0.5, 2)
	cancel.Visible = true
	cancel.Text = if isGamepad() then "B" else "X"
	cancel.TextScaled = true
	TweenService:Create(
		cancel,
		TweenInfo.new(Consts.REC_SLIDE_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = UDim2.new(1, -(side + Consts.REC_CANCEL_GAP), 0.5, 2) }
	):Play()
	if recycleIconLbl then
		recycleIconLbl.Visible = false
	end
	stopPulse()
	local t0 = os.clock()
	pulseConn = RunService.Heartbeat:Connect(function()
		if not confirmUi or not recycleBtn then
			return
		end
		local age = os.clock() - t0
		local showWord = (math.floor(age / 1) % 2) == 1
		PlaceConfirmChrome.syncConfirmFace(recycleBtn, showWord, isGamepad())
		local phase = (math.sin(os.clock() * 6) + 1) * 0.5
		recycleBtn.BackgroundColor3 = Consts.REC_CONFIRM_BRIGHT:Lerp(Consts.REC_CONFIRM_DARK, phase)
		if recycleCancelBtn and recycleCancelBtn.Visible then
			local tip = if isGamepad() then "B" else "X"
			recycleCancelBtn.Text = if showWord then "CANCEL" else tip
			recycleCancelBtn.TextScaled = not showWord
			if showWord then
				recycleCancelBtn.TextSize = PlaceConfirmChrome.confirmLabelTextSize()
			end
		end
	end)
end

function M.onRecyclePressed()
	if not RelocateController.isActive() then
		return
	end
	if RelocateController.isRecyclePending() then
		UiHaptics.pulseShort()
		RelocateController.commit()
		return
	end
	if hideStatsKey then
		hideStatsKey()
	end
	if hideConfirm then
		hideConfirm()
	end
	UiHaptics.pulseShort()
	RelocateController.beginRecycleConfirm()
end

function M.onCancelPressed()
	if not RelocateController.isRecyclePending() then
		return
	end
	UiHaptics.pulseShort()
	RelocateController.cancelRecycleConfirm()
end

function M.refreshHeader(side: number)
	headerSide = side
	if recycleBtn then
		recycleBtn.Size = UDim2.fromOffset(side, side)
	end
	layoutCancel(side, confirmUi)
	if nameLbl then
		nameLbl.ZIndex = 1
	end
end

function M.mount(row1: Frame, nm: TextLabel, opts: {
	getRoot: () -> Frame?,
	hideStatsKey: () -> (),
	hideConfirm: () -> (),
}): TextButton
	getRoot = opts.getRoot
	hideStatsKey = opts.hideStatsKey
	hideConfirm = opts.hideConfirm
	nameLbl = nm
	row1.ClipsDescendants = false

	local recycle = Instance.new("TextButton")
	recycle.Name = "Recycle"
	recycle.Text = ""
	recycle.Font = UiTheme.Font
	recycle.TextScaled = true
	recycle.TextColor3 = Consts.WHITE
	recycle.BackgroundColor3 = Consts.REC_GREEN
	recycle.BorderSizePixel = 0
	recycle.AnchorPoint = Vector2.new(1, 0.5)
	recycle.Position = UDim2.new(1, 0, 0.5, 2)
	recycle.Size = UDim2.fromOffset(40, 40)
	recycle.AutoButtonColor = false
	recycle.ZIndex = 3
	recycle.Parent = row1
	UiCircles.ensure(recycle)
	local edge = Instance.new("UIStroke")
	edge.Color = Consts.WHITE
	edge.Thickness = 2
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	edge.Parent = recycle

	local recycleIcon = Instance.new("ImageLabel")
	recycleIcon.Name = "Icon"
	recycleIcon.BackgroundTransparency = 1
	recycleIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	recycleIcon.Position = UDim2.fromScale(0.5, 0.5)
	recycleIcon.Size = UDim2.fromScale(0.5, 0.5)
	recycleIcon.Image = Consts.RECYCLE_ICON_IMAGE
	recycleIcon.ScaleType = Enum.ScaleType.Fit
	recycleIcon.ZIndex = 4
	recycleIcon.Active = false
	recycleIcon.Parent = recycle

	local recycleCancel = Instance.new("TextButton")
	recycleCancel.Name = "RecycleCancel"
	recycleCancel.Text = "X"
	recycleCancel.Font = UiTheme.Font
	recycleCancel.TextScaled = true
	recycleCancel.TextColor3 = Consts.WHITE
	recycleCancel.TextStrokeColor3 = Color3.fromRGB(60, 15, 18)
	recycleCancel.TextStrokeTransparency = 0
	recycleCancel.BackgroundColor3 = Consts.RED
	recycleCancel.BorderSizePixel = 0
	recycleCancel.AnchorPoint = Vector2.new(1, 0.5)
	recycleCancel.Position = UDim2.new(1, 0, 0.5, 2)
	recycleCancel.Size = UDim2.fromOffset(40, 40)
	recycleCancel.AutoButtonColor = false
	recycleCancel.Visible = false
	recycleCancel.ZIndex = 2
	recycleCancel.Parent = row1
	UiCircles.ensure(recycleCancel)
	local cancelEdge = Instance.new("UIStroke")
	cancelEdge.Color = Consts.WHITE
	cancelEdge.Thickness = 2
	cancelEdge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	cancelEdge.Parent = recycleCancel
	local cancelPad = Instance.new("UIPadding")
	cancelPad.PaddingTop = UDim.new(0.12, 0)
	cancelPad.PaddingBottom = UDim.new(0.12, 0)
	cancelPad.PaddingLeft = UDim.new(0.06, 0)
	cancelPad.PaddingRight = UDim.new(0.06, 0)
	cancelPad.Parent = recycleCancel

	recycleBtn = recycle
	recycleIconLbl = recycleIcon
	recycleCancelBtn = recycleCancel
	RelocateController.setInspectRecycleBtn(recycle)
	RelocateController.setRecycleConfirmUiHandler(function(on: boolean)
		if on then
			M.enter()
		else
			M.exit(true)
		end
	end)
	recycle.Activated:Connect(M.onRecyclePressed)
	recycleCancel.Activated:Connect(M.onCancelPressed)
	return recycle
end

return M
