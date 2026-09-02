--!strict
--[[
	Local neon plot outline + bottom hint bar + PlotOutlineColorPopup.

	Hint: bottom bar tinted with outline color; shows ~3s then fades; must leave
	and return to see again. E / ButtonX / tap bar only while hint is showing.

	Picker: ‹ · swatch/Off · › live-previews wireframe; green Done persists.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))
local PlotOutlineColors = require(oceanRoot:WaitForChild("Shared"):WaitForChild("PlotOutlineColors"))
local PlotOutlineWire = require(oceanRoot:WaitForChild("Shared"):WaitForChild("PlotOutlineWire"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
local HideUiState = require(script.Parent:WaitForChild("HideUiState"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local FOLDER_NAME = "PlayerPlotPropertyLines"
local OWN_THICKNESS = 1
local SHOW_DIST = 3.1
local HIDE_DIST = 5.2
local HINT_VISIBLE_SEC = 3.0
local CLOSE_COOLDOWN_SEC = 4.0
local HINT_POLL_HZ = 12
local FOV_DELTA = 8
local ATTR = Constants.PLOT_OUTLINE_COLOR_ATTR
local SESSION_HIDE_ATTR = "OceanTD_HidePlotOutline"

local setColorRf = Remotes.getFunction("RequestSetPlotOutlineColor")

local outlineFolder: Folder? = nil
local colorIndex = PlotOutlineColors.DEFAULT_INDEX
local previewIndex = PlotOutlineColors.DEFAULT_INDEX
local pickerOpen = false
local hintGui: ScreenGui? = nil
local hintBar: TextButton? = nil
local hintTween: Tween? = nil
local pickerGui: ScreenGui? = nil
local pickerCircle: Frame? = nil
local pickerOffLabel: TextLabel? = nil
local fovBase: number? = nil
local fovTween: Tween? = nil
local guiValue: IntValue? = nil

-- Proximity / hint state
local nearZone = false -- hysteresis: entered < SHOW, left > HIDE
local mustLeave = false -- after 3s fade or after opening picker
local hintShowing = false
local hintShownAt = 0
local closeCooldownUntil = 0
local lastHintPoll = 0

local function ensureFolder(): Folder
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		outlineFolder = existing
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = FOLDER_NAME
	f.Parent = Workspace
	outlineFolder = f
	return f
end

local function ensureGuiValue(): IntValue
	if guiValue and guiValue.Parent then
		return guiValue
	end
	local existing = playerGui:FindFirstChild(ATTR)
	if existing and existing:IsA("IntValue") then
		guiValue = existing
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local v = Instance.new("IntValue")
	v.Name = ATTR
	v.Value = colorIndex
	v.Parent = playerGui
	guiValue = v
	return v
end

local function readColorIndex(): number
	local attr = player:GetAttribute(ATTR)
	if typeof(attr) == "number" then
		return PlotOutlineColors.clampIndex(attr)
	end
	return PlotOutlineColors.DEFAULT_INDEX
end

local function outlineHidden(): boolean
	if HideUiState.isActive() then
		return true
	end
	if player:GetAttribute(SESSION_HIDE_ATTR) == true then
		return true
	end
	return PlotOutlineColors.isNoStroke(colorIndex)
end

-- Jelly / Eel / taxi matches not in Ocean TD yet; attribute hook for future.
local function inMinigameMatch(): boolean
	local a = player:GetAttribute("OceanTD_InMinigameMatch")
	return a == true
end

local function interactionBlocked(): boolean
	if InventoryState.isOpen() then
		return true
	end
	if InventoryState.isBuildModalBlocking() then
		return true
	end
	if PlacementController.isActive() then
		return true
	end
	if RelocateController.isActive() then
		return true
	end
	if inMinigameMatch() then
		return true
	end
	return false
end

local function applyIndexToWire(index: number)
	local folder = outlineFolder
	if not folder then
		return
	end
	PlotOutlineColors.applyToFolder(folder, index, 0)
end

local function rebuildOutline()
	local plot = ClientPlot.get()
	local folder = ensureFolder()
	if not plot or outlineHidden() then
		PlotOutlineWire.clear(folder)
		return
	end
	local idx = if pickerOpen then previewIndex else colorIndex
	local sw = PlotOutlineColors.get(idx)
	PlotOutlineWire.rebuild(folder, plot.cframe, plot.size, {
		thickness = OWN_THICKNESS,
		tagOwn = true,
		color = sw.color or Color3.new(1, 1, 1),
		transparency = if sw.noStroke then 1 else 0,
		namePrefix = "OwnEdge",
	})
end

local function distanceToOutlineParts(worldPos: Vector3): number
	local folder = outlineFolder
	if not folder then
		return math.huge
	end
	local best = math.huge
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("IsPlayerPlotOutline") == true then
			local localPos = d.CFrame:PointToObjectSpace(worldPos)
			local half = d.Size * 0.5
			local closestLocal = Vector3.new(
				math.clamp(localPos.X, -half.X, half.X),
				math.clamp(localPos.Y, -half.Y, half.Y),
				math.clamp(localPos.Z, -half.Z, half.Z)
			)
			local closest = d.CFrame:PointToWorldSpace(closestLocal)
			local dist = (closest - worldPos).Magnitude
			if dist < best then
				best = dist
			end
		end
	end
	if best == math.huge then
		local plot = ClientPlot.get()
		if plot then
			return PlotOutlineWire.distanceToSurface(worldPos, plot.cframe, plot.size)
		end
	end
	return best
end

local function isUsingGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function isUsingTouch(): boolean
	local t = UserInputService:GetLastInputType()
	if t == Enum.UserInputType.Touch then
		return true
	end
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and not isUsingGamepad()
end

local function hintPromptText(): string
	if isUsingTouch() then
		return "Tap To Change Color"
	end
	if isUsingGamepad() then
		return "X To Change Color"
	end
	return "E To Change Color"
end

local function hintTintColor(): Color3
	local sw = PlotOutlineColors.get(colorIndex)
	return sw.color or Color3.fromRGB(60, 60, 60)
end

local function stopHintTween()
	if hintTween then
		hintTween:Cancel()
		hintTween = nil
	end
end

local function ensureHint(): (ScreenGui, TextButton)
	if hintGui and hintGui.Parent and hintBar and hintBar.Parent then
		return hintGui, hintBar
	end
	if hintGui then
		hintGui:Destroy()
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_PlotOutlineHint"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 40
	sg.Enabled = true

	local bar = Instance.new("TextButton")
	bar.Name = "HintBar"
	bar.AutoButtonColor = false
	bar.Text = hintPromptText()
	bar.Font = Enum.Font.GothamMedium
	bar.TextSize = 18
	bar.TextColor3 = Color3.fromRGB(255, 255, 255)
	bar.BackgroundColor3 = hintTintColor()
	bar.BackgroundTransparency = 1 -- start hidden
	bar.TextTransparency = 1
	bar.BorderSizePixel = 0
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -28)
	bar.Size = UDim2.fromOffset(320, 44)
	bar.Parent = sg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = bar
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Stroke"
	stroke.Thickness = 1.5
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Transparency = 1
	stroke.Parent = bar

	sg.Parent = playerGui
	hintGui = sg
	hintBar = bar
	return sg, bar
end

local function hideHintImmediate()
	stopHintTween()
	hintShowing = false
	local _, bar = ensureHint()
	bar.BackgroundTransparency = 1
	bar.TextTransparency = 1
	local stroke = bar:FindFirstChild("Stroke")
	if stroke and stroke:IsA("UIStroke") then
		stroke.Transparency = 1
	end
end

local function fadeHintOut(thenMustLeave: boolean)
	if not hintShowing then
		if thenMustLeave then
			mustLeave = true
		end
		return
	end
	hintShowing = false
	stopHintTween()
	local _, bar = ensureHint()
	local stroke = bar:FindFirstChild("Stroke")
	hintTween = TweenService:Create(bar, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
		TextTransparency = 1,
	})
	hintTween:Play()
	if stroke and stroke:IsA("UIStroke") then
		TweenService:Create(stroke, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = 1,
		}):Play()
	end
	if thenMustLeave then
		mustLeave = true
	end
end

local function showHint()
	if hintShowing or pickerOpen then
		return
	end
	hintShowing = true
	hintShownAt = os.clock()
	stopHintTween()
	local _, bar = ensureHint()
	bar.Text = hintPromptText()
	bar.BackgroundColor3 = hintTintColor()
	bar.BackgroundTransparency = 0.2
	bar.TextTransparency = 0
	local stroke = bar:FindFirstChild("Stroke")
	if stroke and stroke:IsA("UIStroke") then
		stroke.Transparency = 0.35
	end
	hintTween = TweenService:Create(bar, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 0.15,
		TextTransparency = 0,
	})
	hintTween:Play()
end

local function restoreFov()
	if fovTween then
		fovTween:Cancel()
		fovTween = nil
	end
	local cam = Workspace.CurrentCamera
	if cam and fovBase ~= nil then
		fovTween = TweenService:Create(cam, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			FieldOfView = fovBase,
		})
		fovTween:Play()
	end
	fovBase = nil
end

local function tweenFovOut()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if fovBase == nil then
		fovBase = cam.FieldOfView
	end
	if fovTween then
		fovTween:Cancel()
	end
	-- Ease FOV out (wider) while picker is open.
	fovTween = TweenService:Create(cam, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		FieldOfView = math.min(90, (fovBase :: number) + FOV_DELTA),
	})
	fovTween:Play()
end

local function destroyPicker()
	if pickerGui then
		pickerGui:Destroy()
		pickerGui = nil
	end
	pickerCircle = nil
	pickerOffLabel = nil
end

local function refreshPickerSwatch()
	local sw = PlotOutlineColors.get(previewIndex)
	if pickerCircle then
		if sw.noStroke then
			pickerCircle.BackgroundColor3 = Color3.fromRGB(40, 44, 48)
		else
			pickerCircle.BackgroundColor3 = sw.color :: Color3
		end
	end
	if pickerOffLabel then
		pickerOffLabel.Visible = sw.noStroke
	end
	applyIndexToWire(previewIndex)
end

local function cyclePreview(delta: number)
	if not pickerOpen then
		return
	end
	local nextIdx = previewIndex + delta
	if nextIdx < PlotOutlineColors.MIN_INDEX then
		nextIdx = PlotOutlineColors.MAX_INDEX
	elseif nextIdx > PlotOutlineColors.MAX_INDEX then
		nextIdx = PlotOutlineColors.MIN_INDEX
	end
	previewIndex = nextIdx
	refreshPickerSwatch()
end

local function requestSetColor(index: number)
	local clamped = PlotOutlineColors.clampIndex(index)
	colorIndex = clamped
	previewIndex = clamped
	ensureGuiValue().Value = colorIndex
	applyIndexToWire(colorIndex)
	task.spawn(function()
		local ok, result = pcall(function()
			return setColorRf:InvokeServer(clamped)
		end)
		if ok and typeof(result) == "number" then
			colorIndex = PlotOutlineColors.clampIndex(result)
			previewIndex = colorIndex
			ensureGuiValue().Value = colorIndex
			applyIndexToWire(colorIndex)
		end
	end)
end

local function closePicker(save: boolean)
	if not pickerOpen then
		return
	end
	pickerOpen = false
	destroyPicker()
	restoreFov()
	closeCooldownUntil = os.clock() + CLOSE_COOLDOWN_SEC
	mustLeave = true
	hideHintImmediate()

	if save then
		requestSetColor(previewIndex)
	else
		-- Revert live preview
		previewIndex = colorIndex
		applyIndexToWire(colorIndex)
	end
end

local function openPicker()
	if pickerOpen or not ClientPlot.get() then
		return
	end
	if outlineHidden() or interactionBlocked() then
		return
	end
	if not hintShowing then
		return
	end

	pickerOpen = true
	previewIndex = colorIndex
	mustLeave = true
	fadeHintOut(true)
	destroyPicker()
	tweenFovOut()

	local sg = Instance.new("ScreenGui")
	sg.Name = "PlotOutlineColorPopup"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 55
	sg.Parent = playerGui
	pickerGui = sg

	local dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.BackgroundColor3 = Color3.fromRGB(0, 10, 18)
	dim.BackgroundTransparency = 0.4
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = 1
	dim.Parent = sg
	dim.Activated:Connect(function()
		closePicker(false)
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.48)
	panel.Size = UDim2.fromOffset(300, 220)
	panel.BackgroundColor3 = Color3.fromRGB(14, 32, 42)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Parent = sg
	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 14)
	panelCorner.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -24, 0, 28)
	title.Position = UDim2.fromOffset(12, 14)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextColor3 = Color3.fromRGB(240, 248, 255)
	title.Text = "Plot Outline Color"
	title.ZIndex = 3
	title.Parent = panel

	local subtitle = Instance.new("TextLabel")
	subtitle.BackgroundTransparency = 1
	subtitle.Size = UDim2.new(1, -24, 0, 20)
	subtitle.Position = UDim2.fromOffset(12, 42)
	subtitle.Font = Enum.Font.Gotham
	subtitle.TextSize = 14
	subtitle.TextColor3 = Color3.fromRGB(140, 180, 200)
	subtitle.Text = "Primo Feature"
	subtitle.ZIndex = 3
	subtitle.Parent = panel

	local row = Instance.new("Frame")
	row.Name = "CycleRow"
	row.BackgroundTransparency = 1
	row.Position = UDim2.fromOffset(16, 78)
	row.Size = UDim2.new(1, -32, 0, 72)
	row.ZIndex = 3
	row.Parent = panel

	local prevBtn = Instance.new("TextButton")
	prevBtn.Name = "Prev"
	prevBtn.Text = "‹"
	prevBtn.Font = Enum.Font.GothamBold
	prevBtn.TextSize = 36
	prevBtn.TextColor3 = Color3.fromRGB(230, 245, 255)
	prevBtn.BackgroundColor3 = Color3.fromRGB(30, 50, 62)
	prevBtn.BorderSizePixel = 0
	prevBtn.Size = UDim2.fromOffset(48, 48)
	prevBtn.Position = UDim2.new(0, 0, 0.5, -24)
	prevBtn.ZIndex = 4
	prevBtn.Parent = row
	local prevCorner = Instance.new("UICorner")
	prevCorner.CornerRadius = UDim.new(1, 0)
	prevCorner.Parent = prevBtn
	prevBtn.Activated:Connect(function()
		cyclePreview(-1)
	end)

	local nextBtn = Instance.new("TextButton")
	nextBtn.Name = "Next"
	nextBtn.Text = "›"
	nextBtn.Font = Enum.Font.GothamBold
	nextBtn.TextSize = 36
	nextBtn.TextColor3 = Color3.fromRGB(230, 245, 255)
	nextBtn.BackgroundColor3 = Color3.fromRGB(30, 50, 62)
	nextBtn.BorderSizePixel = 0
	nextBtn.Size = UDim2.fromOffset(48, 48)
	nextBtn.Position = UDim2.new(1, -48, 0.5, -24)
	nextBtn.ZIndex = 4
	nextBtn.Parent = row
	local nextCorner = Instance.new("UICorner")
	nextCorner.CornerRadius = UDim.new(1, 0)
	nextCorner.Parent = nextBtn
	nextBtn.Activated:Connect(function()
		cyclePreview(1)
	end)

	local circle = Instance.new("Frame")
	circle.Name = "Swatch"
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromScale(0.5, 0.5)
	circle.Size = UDim2.fromOffset(64, 64)
	circle.BorderSizePixel = 0
	circle.ZIndex = 4
	circle.Parent = row
	local circleCorner = Instance.new("UICorner")
	circleCorner.CornerRadius = UDim.new(1, 0)
	circleCorner.Parent = circle
	local circleStroke = Instance.new("UIStroke")
	circleStroke.Thickness = 2
	circleStroke.Color = Color3.fromRGB(255, 255, 255)
	circleStroke.Transparency = 0.25
	circleStroke.Parent = circle
	pickerCircle = circle

	local offLbl = Instance.new("TextLabel")
	offLbl.Name = "Off"
	offLbl.BackgroundTransparency = 1
	offLbl.Size = UDim2.fromScale(1, 1)
	offLbl.Font = Enum.Font.GothamBold
	offLbl.TextSize = 16
	offLbl.TextColor3 = Color3.fromRGB(230, 230, 230)
	offLbl.Text = "Off"
	offLbl.Visible = false
	offLbl.ZIndex = 5
	offLbl.Parent = circle
	pickerOffLabel = offLbl

	local done = Instance.new("TextButton")
	done.Name = "Done"
	done.Text = "Done"
	done.Font = Enum.Font.GothamBold
	done.TextSize = 18
	done.TextColor3 = Color3.fromRGB(255, 255, 255)
	done.BackgroundColor3 = Color3.fromRGB(40, 190, 90)
	done.BorderSizePixel = 0
	done.AnchorPoint = Vector2.new(0.5, 1)
	done.Position = UDim2.new(0.5, 0, 1, -16)
	done.Size = UDim2.fromOffset(160, 44)
	done.ZIndex = 4
	done.Parent = panel
	local doneCorner = Instance.new("UICorner")
	doneCorner.CornerRadius = UDim.new(0, 10)
	doneCorner.Parent = done
	done.Activated:Connect(function()
		closePicker(true)
	end)

	refreshPickerSwatch()
end

local function tryOpenFromHintInput()
	if pickerOpen then
		return
	end
	if not hintShowing then
		return
	end
	if os.clock() < closeCooldownUntil then
		return
	end
	if outlineHidden() or interactionBlocked() then
		return
	end
	openPicker()
end

local function syncFromAttribute()
	colorIndex = readColorIndex()
	if not pickerOpen then
		previewIndex = colorIndex
	end
	ensureGuiValue().Value = colorIndex
	rebuildOutline()
	if hintShowing and hintBar then
		hintBar.BackgroundColor3 = hintTintColor()
	end
	if outlineHidden() then
		hideHintImmediate()
		if pickerOpen then
			closePicker(false)
		end
	end
end

-- Boot
colorIndex = readColorIndex()
previewIndex = colorIndex
ensureGuiValue().Value = colorIndex
rebuildOutline()
ensureHint()

ClientPlot.onChanged(function(_plot)
	rebuildOutline()
	if not ClientPlot.get() then
		if pickerOpen then
			closePicker(false)
		end
		hideHintImmediate()
		nearZone = false
		mustLeave = false
	end
end)

player:GetAttributeChangedSignal(ATTR):Connect(syncFromAttribute)
player:GetAttributeChangedSignal(SESSION_HIDE_ATTR):Connect(function()
	rebuildOutline()
	if outlineHidden() then
		hideHintImmediate()
		if pickerOpen then
			closePicker(false)
		end
	end
end)

HideUiState.onChanged(function()
	rebuildOutline()
	if outlineHidden() then
		hideHintImmediate()
		if pickerOpen then
			closePicker(false)
		end
	end
end)

UserInputService.LastInputTypeChanged:Connect(function()
	if hintShowing and hintBar then
		hintBar.Text = hintPromptText()
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if pickerOpen then
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			closePicker(false)
		elseif input.KeyCode == Enum.KeyCode.Left or input.KeyCode == Enum.KeyCode.DPadLeft then
			cyclePreview(-1)
		elseif input.KeyCode == Enum.KeyCode.Right or input.KeyCode == Enum.KeyCode.DPadRight then
			cyclePreview(1)
		elseif input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.ButtonA then
			closePicker(true)
		end
		return
	end
	if input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.ButtonX then
		tryOpenFromHintInput()
	end
end)

do
	local _, bar = ensureHint()
	bar.Activated:Connect(tryOpenFromHintInput)
end

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if now - lastHintPoll < (1 / HINT_POLL_HZ) then
		return
	end
	lastHintPoll = now

	if pickerOpen then
		return
	end

	if inMinigameMatch() then
		hideHintImmediate()
		nearZone = false
		return
	end

	if outlineHidden() or interactionBlocked() then
		hideHintImmediate()
		return
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not ClientPlot.get() or not hrp or not hrp:IsA("BasePart") then
		hideHintImmediate()
		nearZone = false
		return
	end

	local dist = distanceToOutlineParts(hrp.Position)
	if nearZone then
		if dist > HIDE_DIST then
			nearZone = false
			mustLeave = false
			hideHintImmediate()
		end
	else
		if dist < SHOW_DIST then
			nearZone = true
		end
	end

	if not nearZone then
		return
	end

	-- Cleared mustLeave by walking away (nearZone false path above).
	if mustLeave then
		hideHintImmediate()
		return
	end

	if now < closeCooldownUntil then
		hideHintImmediate()
		return
	end

	if hintShowing then
		if now - hintShownAt >= HINT_VISIBLE_SEC then
			fadeHintOut(true)
		end
	else
		showHint()
	end
end)

print("[PLOT_OUTLINE] Ready — hint bar + cycle picker")
