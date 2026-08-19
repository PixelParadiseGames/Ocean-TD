--!strict
-- Build-mode inspect for a selected placed coral: name, UPGRADE, S/M/L.

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local CoralSize = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralSize"))
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))

local RelocateController = require(script.Parent:WaitForChild("RelocateController"))

local CoralInspectPanel = {}

local GREEN = Color3.fromRGB(40, 170, 70)
local PULSE_GREEN = Color3.fromRGB(70, 255, 110)
local STROKE_DARK = Color3.fromRGB(16, 80, 32)
local ACTIVE_GREEN = Color3.fromRGB(40, 255, 90)
local WHITE = Color3.new(1, 1, 1)
local STAT_GREY = Color3.fromRGB(200, 200, 205)
local RED = Color3.fromRGB(220, 50, 55)
local PANEL_BG = Color3.fromRGB(12, 28, 36)
local GROW_SOUND_ID = "rbxassetid://134057288"

local function pulseWave(): number
	return (math.sin(os.clock() * math.pi * 2) + 1) * 0.5
end

local LETTERS = { "S", "M", "L" }
local WORDS = { "Small", "Medium", "Large" }

local root: Frame? = nil
local catalog: GuiObject? = nil
local iconLbl: ImageLabel? = nil
local nameLbl: TextLabel? = nil
local upgradeBtn: TextButton? = nil
local h1s: { TextButton } = {}
local h2s: { TextLabel } = {}
local h3s: { Frame } = {}
local h3Labels: { { TextLabel } } = {}
local confirmGui: ScreenGui? = nil
local pulseConn: RBXScriptConnection? = nil
local hintConn: RBXScriptConnection? = nil
local confirmStrokeConn: RBXScriptConnection? = nil
local sizeFlashConn: RBXScriptConnection? = nil
local rangeFolder: Folder? = nil
local rangeBb: BillboardGui? = nil
local rangeFollow: RBXScriptConnection? = nil
local cineToken = 0
local bound = false

local sizeRf = Remotes.getFunction("RequestCoralSize")

local function isGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function applyUnlockStroke(btn: GuiObject)
	local stroke = btn:FindFirstChild("_OceanTD_UnlockStroke")
	if not (stroke and stroke:IsA("UIStroke")) then
		stroke = Instance.new("UIStroke")
		stroke.Name = "_OceanTD_UnlockStroke"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.LineJoinMode = Enum.LineJoinMode.Round
		stroke.Parent = btn
	end
	stroke.Thickness = 2
	stroke.Color = PULSE_GREEN
	stroke.Enabled = true
end

local function linkTwoWay(a: GuiButton, b: GuiButton)
	a.NextSelectionUp = b
	a.NextSelectionDown = b
	a.NextSelectionLeft = b
	a.NextSelectionRight = b
	b.NextSelectionUp = a
	b.NextSelectionDown = a
	b.NextSelectionLeft = a
	b.NextSelectionRight = a
end

local function selectedPart(): BasePart?
	return RelocateController.getSelectedPart()
end

local RANGE_SPIN = { 0.55, -0.7, 0.4, -0.5, 0.62, -0.38 }
local RANGE_PHASE = { 0, 1.05, 2.1, 3.15, 4.2, 5.25 }
local RANGE_RING_N = 6
local RANGE_DASH_N = 14
-- Six evenly spaced great-circle axes (cuboctahedron). Shared tumble keeps gaps.
local RANGE_NORMALS = {
	Vector3.new(1, 1, 0),
	Vector3.new(1, -1, 0),
	Vector3.new(1, 0, 1),
	Vector3.new(1, 0, -1),
	Vector3.new(0, 1, 1),
	Vector3.new(0, 1, -1),
}

local function hideRangeRing()
	if rangeFollow then
		rangeFollow:Disconnect()
		rangeFollow = nil
	end
	if rangeFolder then
		rangeFolder:Destroy()
		rangeFolder = nil
	end
	if rangeBb then
		rangeBb:Destroy()
		rangeBb = nil
	end
end

local function ringBasis(ri: number, spin: number): CFrame
	local n = RANGE_NORMALS[ri] or Vector3.yAxis
	n = n.Unit
	local spinA = spin * (RANGE_SPIN[ri] or 0.5) + (RANGE_PHASE[ri] or 0)
	local tumble = CFrame.Angles(spin * 0.11, spin * 0.17, spin * 0.07)
	local up = if math.abs(n.Y) > 0.92 then Vector3.xAxis else Vector3.yAxis
	return tumble * CFrame.lookAt(Vector3.zero, n, up) * CFrame.Angles(0, 0, spinA)
end

local function poseRangeRings(part: BasePart, folder: Folder, range: number, spin: number, grow: number)
	local pos = part.Position
	local s = math.clamp(grow, 0, 1)
	s = 1 - (1 - s) * (1 - s)
	local r = range * s
	local thick = 0.55 * math.max(s, 0.15)
	local arcLen = math.max(2.2, (2 * math.pi * range / RANGE_DASH_N) * 0.5) * s
	for _, dash in ipairs(folder:GetChildren()) do
		if not dash:IsA("BasePart") then
			continue
		end
		local ri = dash:GetAttribute("Ring")
		local di = dash:GetAttribute("Dash")
		if typeof(ri) ~= "number" or typeof(di) ~= "number" then
			continue
		end
		local ang = ((di - 1) / RANGE_DASH_N) * math.pi * 2 + spin * (RANGE_SPIN[ri] or 1)
		dash.Size = Vector3.new(math.max(0.05, arcLen), thick, thick)
		dash.CFrame = CFrame.new(pos)
			* ringBasis(ri, spin)
			* CFrame.Angles(0, 0, ang)
			* CFrame.new(r, 0, 0)
			* CFrame.Angles(0, 0, math.pi * 0.5)
	end
end

local function showRangeRing(part: BasePart)
	if rangeFolder and rangeFolder.Parent then
		return
	end
	hideRangeRing()
	local folder = Instance.new("Folder")
	folder.Name = "OceanTD_RangeRing"
	folder.Parent = workspace
	for ri = 1, RANGE_RING_N do
		for di = 1, RANGE_DASH_N do
			local dash = Instance.new("Part")
			dash.Name = "Dash"
			dash.Anchored = true
			dash.CanCollide = false
			dash.CanQuery = false
			dash.CanTouch = false
			dash.CastShadow = false
			dash.Material = Enum.Material.Neon
			dash.Color = ACTIVE_GREEN
			dash.Transparency = 0.05
			dash:SetAttribute("Ring", ri)
			dash:SetAttribute("Dash", di)
			dash.Parent = folder
		end
	end
	rangeFolder = folder
	local spin = 0
	local growT = 0
	local _d0, class0 = CoralSize.readFromPart(part)
	poseRangeRings(part, folder, CoralSize.statsFor(class0).range, spin, 0)
	rangeFollow = RunService.Heartbeat:Connect(function(dt)
		local p = selectedPart()
		local f = rangeFolder
		if not p or not p.Parent or not f or not f.Parent then
			hideRangeRing()
			return
		end
		spin += dt
		growT += dt
		local _dd, cls = CoralSize.readFromPart(p)
		poseRangeRings(p, f, CoralSize.statsFor(cls).range, spin, growT / 2)
	end)
end

local function hideConfirm()
	RelocateController.setInspectModal(false)
	if confirmStrokeConn then
		confirmStrokeConn:Disconnect()
		confirmStrokeConn = nil
	end
	if confirmGui then
		confirmGui:Destroy()
		confirmGui = nil
	end
	GuiService.SelectedObject = nil
end

local function stopSizeFlash()
	if sizeFlashConn then
		sizeFlashConn:Disconnect()
		sizeFlashConn = nil
	end
end

local function stopUpgradeFx()
	if pulseConn then
		pulseConn:Disconnect()
		pulseConn = nil
	end
	if hintConn then
		hintConn:Disconnect()
		hintConn = nil
	end
end

local function stopPulses()
	stopUpgradeFx()
	stopSizeFlash()
end

local STAT_ICONS = { "↔️", "🍴", "🔄", "🛡️" }

local function statValues(st: CoralSize.SizeStats): { number }
	return { st.range, st.food, st.reload, st.defense }
end

local function formatStatLine(icon: string, n: number, asDelta: boolean): string
	if asDelta then
		if n > 0 then
			return string.format("%s : +%d", icon, n)
		end
		return string.format("%s : %d", icon, n)
	end
	return string.format("%s : %d", icon, n)
end

local function setActiveCircleStroke(btn: GuiObject, on: boolean)
	local stroke = btn:FindFirstChild("_SizeActiveStroke")
	if on then
		if not (stroke and stroke:IsA("UIStroke")) then
			stroke = Instance.new("UIStroke")
			stroke.Name = "_SizeActiveStroke"
			stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			stroke.LineJoinMode = Enum.LineJoinMode.Round
			stroke.Parent = btn
		end
		stroke.Thickness = 3
		stroke.Color = WHITE
		stroke.Enabled = true
	elseif stroke and stroke:IsA("UIStroke") then
		stroke.Enabled = false
	end
end

local function paintStatColumn(i: number, asDelta: boolean, fromClass: number?, isActive: boolean)
	local labels = h3Labels[i]
	if not labels then
		return
	end
	local vals = statValues(CoralSize.statsFor(i))
	local fromVals = if asDelta and fromClass then statValues(CoralSize.statsFor(fromClass)) else nil
	for k, n in ipairs(vals) do
		if fromVals then
			n = n - fromVals[k]
		end
		labels[k].Text = formatStatLine(STAT_ICONS[k], n, asDelta)
		if asDelta then
			labels[k].TextColor3 = ACTIVE_GREEN
		elseif isActive then
			labels[k].TextColor3 = WHITE
		else
			labels[k].TextColor3 = STAT_GREY
		end
	end
end

local function refreshSizeColors()
	local part = selectedPart()
	if not part then
		return
	end
	local _d, class, tier = CoralSize.readFromPart(part)
	local nxt = CoralSize.nextUnlock(tier)
	stopSizeFlash()
	for i = 1, 3 do
		local locked = i > tier
		local isNext = nxt == i
		local btn = h1s[i]
		if btn then
			btn.Active = true
			btn.TextColor3 = WHITE
			if isNext then
				btn.BackgroundColor3 = RED
			elseif locked then
				btn.BackgroundColor3 = RED
			elseif i == class then
				btn.BackgroundColor3 = ACTIVE_GREEN
			else
				btn.BackgroundColor3 = GREEN
			end
			setActiveCircleStroke(btn, i == class)
		end
		if h2s[i] then
			h2s[i].TextColor3 = WHITE
		end
		paintStatColumn(i, false, nil, i == class)
	end
	if nxt and h1s[nxt] then
		local flashBtn = h1s[nxt]
		local flashIdx = nxt
		local fromClass = class
		local t0 = os.clock()
		sizeFlashConn = RunService.Heartbeat:Connect(function()
			if not flashBtn.Parent then
				return
			end
			flashBtn.BackgroundColor3 = RED:Lerp(PULSE_GREEN, pulseWave())
			local showDelta = math.floor((os.clock() - t0) / 2) % 2 == 1
			paintStatColumn(flashIdx, showDelta, fromClass, false)
		end)
	end
	if upgradeBtn then
		upgradeBtn.Visible = nxt ~= nil
		upgradeBtn.Active = nxt ~= nil
		upgradeBtn.Text = "UPGRADE"
	end
	showRangeRing(part)
end

local function tweenSize(part: BasePart, fromD: number, toD: number, sec: number)
	part.Size = Vector3.new(fromD, fromD, fromD)
	local tw = TweenService:Create(
		part,
		TweenInfo.new(sec, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(toD, toD, toD) }
	)
	tw:Play()
	tw.Completed:Wait()
end

local function playGrowSound()
	local s = Instance.new("Sound")
	s.SoundId = GROW_SOUND_ID
	s.Volume = 0.85
	s.Parent = SoundService
	s:Play()
	s.Ended:Connect(function()
		s:Destroy()
	end)
	task.delay(4, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

local function zoomToward(part: BasePart, fromCf: CFrame, closer: boolean): CFrame
	local look = part.Position
	local origin = fromCf.Position
	local delta = look - origin
	local mag = delta.Magnitude
	if mag < 0.05 then
		return fromCf
	end
	local dist = if closer then mag * 0.6 else mag
	local pos = look - delta.Unit * dist
	return CFrame.lookAt(pos, look)
end

local function runUnlockCinematic(part: BasePart, newDiam: number)
	cineToken += 1
	local token = cineToken
	local saved = RelocateController.getSavedCameraCFrame()
	local startCf = saved or (workspace.CurrentCamera and workspace.CurrentCamera.CFrame)
	if not startCf then
		CoralSize.applyToPart(part, newDiam, CoralSize.classFromDiameter(newDiam), CoralSize.classFromDiameter(newDiam))
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		CoralSize.applyToPart(part, newDiam, CoralSize.classFromDiameter(newDiam), CoralSize.classFromDiameter(newDiam))
		return
	end
	local fromD = math.max(part.Size.X, 0.05)
	local zoomCf = zoomToward(part, startCf, true)
	RelocateController.setCinematicHold(true)

	local camTw = TweenService:Create(
		cam,
		TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = zoomCf }
	)
	camTw:Play()
	tweenSize(part, fromD, fromD * 0.1, 0.5)
	if token ~= cineToken or not part.Parent then
		RelocateController.setCinematicHold(false)
		if saved then
			RelocateController.setLiveCameraCFrame(saved)
		end
		return
	end
	playGrowSound()
	tweenSize(part, fromD * 0.1, newDiam, 0.7)
	if token ~= cineToken or not part.Parent then
		RelocateController.setCinematicHold(false)
		return
	end
	local backCam = workspace.CurrentCamera
	if backCam then
		local backTw = TweenService:Create(
			backCam,
			TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = startCf }
		)
		backTw:Play()
		backTw.Completed:Wait()
	end
	RelocateController.setCinematicHold(false)
	if saved then
		RelocateController.setLiveCameraCFrame(saved)
	end
	local _finD, class, tier = CoralSize.readFromPart(part)
	CoralSize.applyToPart(part, newDiam, class, tier)
	RelocateController.refreshSelectRing()
end

local function applyServerSize(result: any, unlock: boolean)
	if typeof(result) ~= "table" or result.ok ~= true then
		return
	end
	local part = selectedPart()
	if not part then
		return
	end
	local d = tonumber(result.diameter)
	local class = tonumber(result.sizeClass)
	local tier = tonumber(result.sizeTier)
	if typeof(d) ~= "number" then
		return
	end
	part:SetAttribute("OceanTD_Diameter", d)
	if typeof(class) == "number" then
		part:SetAttribute("OceanTD_SizeClass", class)
	end
	if typeof(tier) == "number" then
		part:SetAttribute("OceanTD_SizeTier", tier)
	end
	if unlock then
		task.spawn(function()
			runUnlockCinematic(part, d)
			refreshSizeColors()
		end)
	else
		local fromD = math.max(part.Size.X, 0.05)
		task.spawn(function()
			tweenSize(part, fromD, d, 0.28)
			CoralSize.applyToPart(part, d, class or CoralSize.classFromDiameter(d), tier or (class or 1))
			RelocateController.refreshSelectRing()
			refreshSizeColors()
		end)
	end
end

local function invokeSize(targetClass: number, unlockNext: boolean)
	local part = selectedPart()
	if not part then
		return
	end
	local placeId = part:GetAttribute("OceanTD_PlaceId")
	if typeof(placeId) ~= "string" then
		return
	end
	UiHaptics.pulseShort()
	local ok, result = pcall(function()
		return sizeRf:InvokeServer(placeId, targetClass, unlockNext)
	end)
	if ok then
		applyServerSize(result, unlockNext)
	end
	refreshSizeColors()
end

local function showConfirmUnlock()
	local part = selectedPart()
	if not part then
		return
	end
	local _d, _class, tier = CoralSize.readFromPart(part)
	local nxt = CoralSize.nextUnlock(tier)
	if not nxt then
		return
	end
	hideConfirm()
	RelocateController.setInspectModal(true)
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_CoralSizeConfirm"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 25000
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui
	confirmGui = sg

	local dim = Instance.new("TextButton")
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.BackgroundColor3 = Color3.fromRGB(0, 8, 16)
	dim.BackgroundTransparency = 0.4
	dim.Size = UDim2.fromScale(1, 1)
	dim.Selectable = false
	dim.ZIndex = 1
	dim.Parent = sg
	dim.Activated:Connect(hideConfirm)

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(320, 220)
	panel.BackgroundColor3 = PANEL_BG
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Selectable = false
	panel.Parent = sg
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 14)
	pc.Parent = panel
	local panelStroke = Instance.new("UIStroke")
	panelStroke.Name = "_OceanTD_UnlockStroke"
	panelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	panelStroke.LineJoinMode = Enum.LineJoinMode.Round
	panelStroke.Thickness = 3
	panelStroke.Color = STROKE_DARK
	panelStroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -24, 0, 56)
	title.Position = UDim2.fromOffset(12, 20)
	title.Font = UiTheme.Font
	title.TextSize = 26
	title.TextColor3 = Color3.fromRGB(240, 248, 255)
	title.Text = "Unlock " .. CoralSize.labelFor(nxt)
	title.ZIndex = 3
	title.Parent = panel

	local unlock = Instance.new("TextButton")
	unlock.Name = "UNLOCK"
	unlock.Text = "UNLOCK"
	unlock.Font = UiTheme.Font
	unlock.TextSize = 20
	unlock.TextColor3 = WHITE
	unlock.BackgroundColor3 = GREEN
	unlock.BorderSizePixel = 0
	unlock.Size = UDim2.fromOffset(200, 48)
	unlock.AnchorPoint = Vector2.new(0.5, 0)
	unlock.Position = UDim2.new(0.5, 0, 0, 96)
	unlock.ZIndex = 3
	unlock.Parent = panel
	local uc = Instance.new("UICorner")
	uc.CornerRadius = UDim.new(0, 10)
	uc.Parent = unlock
	applyUnlockStroke(unlock)
	local unlockStroke = unlock:FindFirstChild("_OceanTD_UnlockStroke")
	if confirmStrokeConn then
		confirmStrokeConn:Disconnect()
		confirmStrokeConn = nil
	end
	confirmStrokeConn = RunService.Heartbeat:Connect(function()
		if confirmGui ~= sg then
			return
		end
		local u = (math.sin(os.clock() * math.pi * 1.35) + 1) * 0.5
		local c = STROKE_DARK:Lerp(PULSE_GREEN, u)
		panelStroke.Color = c
		if unlockStroke and unlockStroke:IsA("UIStroke") then
			unlockStroke.Color = c
			unlockStroke.Thickness = 2 + u * 2
		end
		panelStroke.Thickness = 3 + u * 2
	end)
	unlock.Activated:Connect(function()
		local n = nxt
		hideConfirm()
		invokeSize(n, true)
	end)

	local cancel = Instance.new("TextButton")
	cancel.Name = "CANCEL"
	cancel.Text = "CANCEL"
	cancel.Font = UiTheme.Font
	cancel.TextSize = 18
	cancel.TextColor3 = WHITE
	cancel.BackgroundColor3 = RED
	cancel.BorderSizePixel = 0
	cancel.Size = UDim2.fromOffset(200, 44)
	cancel.AnchorPoint = Vector2.new(0.5, 0)
	cancel.Position = UDim2.new(0.5, 0, 0, 156)
	cancel.ZIndex = 3
	cancel.Parent = panel
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 10)
	cc.Parent = cancel
	cancel.Activated:Connect(hideConfirm)

	if isGamepad() then
		unlock.Selectable = true
		cancel.Selectable = true
		linkTwoWay(unlock, cancel)
		GuiService.AutoSelectGuiEnabled = true
		GuiService.SelectedObject = unlock
	end
end

local function onLetter(i: number)
	local part = selectedPart()
	if not part then
		return
	end
	local _d, class, tier = CoralSize.readFromPart(part)
	if i == class then
		return
	end
	if i <= tier then
		invokeSize(i, false)
		return
	end
	showConfirmUnlock()
end

local function startUpgradeFx()
	stopUpgradeFx()
	local btn = upgradeBtn
	if not btn then
		return
	end
	applyUnlockStroke(btn)
	pulseConn = RunService.Heartbeat:Connect(function()
		if not upgradeBtn or not upgradeBtn.Visible then
			return
		end
		upgradeBtn.BackgroundColor3 = GREEN:Lerp(PULSE_GREEN, pulseWave())
	end)
	hintConn = RunService.Heartbeat:Connect(function()
		if not upgradeBtn or not upgradeBtn.Visible or not isGamepad() then
			if upgradeBtn and upgradeBtn.Visible then
				upgradeBtn.Text = "UPGRADE"
			end
			return
		end
		-- 1s R1, 1s UPGRADE (flash 1 second every 2 seconds).
		local phase = os.clock() % 2
		upgradeBtn.Text = if phase < 1 then "R1" else "UPGRADE"
	end)
end

local function fillHeader(part: BasePart)
	local itemId = part:GetAttribute("OceanTD_ItemId")
	local def = if typeof(itemId) == "string" then ItemCatalog.get(itemId) else nil
	if iconLbl then
		iconLbl.Image = if def then def.icon else ""
	end
	if nameLbl then
		nameLbl.Text = if def then def.displayName else "Coral"
	end
end

local function setVisible(on: boolean)
	if root then
		root.Visible = on
	end
	if catalog then
		catalog.Visible = not on
	end
	if on then
		local part = selectedPart()
		if part then
			fillHeader(part)
			refreshSizeColors()
			startUpgradeFx()
			showRangeRing(part)
		end
	else
		stopPulses()
		hideRangeRing()
		hideConfirm()
		cineToken += 1
	end
end

function CoralInspectPanel.bind(panel: GuiObject, catalogFrame: GuiObject)
	if bound then
		return
	end
	bound = true
	catalog = catalogFrame

	local frame = Instance.new("Frame")
	frame.Name = "CoralInspect"
	frame.BackgroundTransparency = 1
	frame.Position = catalogFrame.Position
	frame.Size = catalogFrame.Size
	frame.Visible = false
	frame.Parent = panel
	root = frame

	local col = Instance.new("UIListLayout")
	col.FillDirection = Enum.FillDirection.Vertical
	col.SortOrder = Enum.SortOrder.LayoutOrder
	col.Padding = UDim.new(0, 6)
	col.Parent = frame

	local row1 = Instance.new("Frame")
	row1.BackgroundTransparency = 1
	row1.Size = UDim2.new(1, 0, 0.22, 0)
	row1.LayoutOrder = 1
	row1.Parent = frame

	local icon = Instance.new("ImageLabel")
	icon.Name = "Circle"
	icon.BackgroundColor3 = Color3.fromRGB(20, 30, 45)
	icon.BackgroundTransparency = 0.15
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.new(0, 4, 0.5, 0)
	icon.Size = UDim2.new(0.28, 0, 0.9, 0)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = row1
	UiCircles.ensure(icon)
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.DominantAxis = Enum.DominantAxis.Height
	aspect.Parent = icon
	iconLbl = icon

	local nm = Instance.new("TextLabel")
	nm.BackgroundTransparency = 1
	nm.AnchorPoint = Vector2.new(0, 0.5)
	nm.Position = UDim2.new(0.32, 8, 0.5, 0)
	nm.Size = UDim2.new(0.66, -12, 0.42, 0)
	nm.Font = UiTheme.Font
	nm.Text = "Coral"
	nm.TextColor3 = WHITE
	nm.TextScaled = true
	nm.TextXAlignment = Enum.TextXAlignment.Left
	nm.Parent = row1
	nameLbl = nm

	local upRow = Instance.new("Frame")
	upRow.BackgroundTransparency = 1
	upRow.Size = UDim2.new(1, 0, 0.18, 0)
	upRow.LayoutOrder = 2
	upRow.Parent = frame

	local up = Instance.new("TextButton")
	up.Name = "UPGRADE"
	up.Text = "UPGRADE"
	up.Font = UiTheme.Font
	up.TextScaled = true
	up.TextColor3 = WHITE
	up.BackgroundColor3 = GREEN
	up.BorderSizePixel = 0
	up.AnchorPoint = Vector2.new(0.5, 0.5)
	up.Position = UDim2.fromScale(0.5, 0.5)
	up.Size = UDim2.new(0.9, 0, 0.7, 0)
	up.AutoButtonColor = true
	up.Parent = upRow
	local upPad = Instance.new("UIPadding")
	upPad.PaddingLeft = UDim.new(0.05, 0)
	upPad.PaddingRight = UDim.new(0.05, 0)
	upPad.PaddingTop = UDim.new(0.05, 0)
	upPad.PaddingBottom = UDim.new(0.05, 0)
	upPad.Parent = up
	local uc = Instance.new("UICorner")
	uc.CornerRadius = UDim.new(0, 10)
	uc.Parent = up
	applyUnlockStroke(up)
	upgradeBtn = up
	up.Activated:Connect(function()
		showConfirmUnlock()
	end)

	local row3 = Instance.new("Frame")
	row3.BackgroundTransparency = 1
	row3.Size = UDim2.new(1, 0, 0.55, 0)
	row3.LayoutOrder = 3
	row3.Parent = frame
	local sizeGrid = Instance.new("UIGridLayout")
	sizeGrid.Name = "SizeGrid"
	sizeGrid.FillDirection = Enum.FillDirection.Horizontal
	sizeGrid.FillDirectionMaxCells = 3
	sizeGrid.SortOrder = Enum.SortOrder.LayoutOrder
	sizeGrid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	sizeGrid.CellPadding = UDim2.fromOffset(6, 0)
	sizeGrid.Parent = row3

	for i = 1, 3 do
		local cell = Instance.new("Frame")
		cell.BackgroundTransparency = 1
		cell.LayoutOrder = i
		cell.Parent = row3
		local letter = Instance.new("TextButton")
		letter.BackgroundColor3 = GREEN
		letter.BackgroundTransparency = 0
		letter.BorderSizePixel = 0
		letter.AnchorPoint = Vector2.new(0.5, 0)
		letter.Position = UDim2.new(0.5, 0, 0, 2)
		letter.Size = UDim2.fromOffset(48, 48)
		letter.Font = UiTheme.Font
		letter.Text = LETTERS[i]
		letter.TextColor3 = WHITE
		letter.TextScaled = true
		letter.AutoButtonColor = false
		letter.Parent = cell
		UiCircles.ensure(letter)
		h1s[i] = letter
		local word = Instance.new("TextLabel")
		word.BackgroundTransparency = 1
		word.AnchorPoint = Vector2.new(0.5, 0)
		word.Position = UDim2.new(0.5, 0, 0, 54)
		word.Size = UDim2.new(1, -4, 0, 16)
		word.Font = UiTheme.Font
		word.Text = WORDS[i]
		word.TextColor3 = WHITE
		word.TextScaled = false
		word.Parent = cell
		h2s[i] = word
		local vals = statValues(CoralSize.statsFor(i))
		local stats = Instance.new("Frame")
		stats.BackgroundTransparency = 1
		stats.AnchorPoint = Vector2.new(0.5, 0)
		stats.Position = UDim2.new(0.5, 0, 0, 72)
		stats.Size = UDim2.new(1, -2, 0, 45)
		stats.Parent = cell
		local statsLay = Instance.new("UIListLayout")
		statsLay.FillDirection = Enum.FillDirection.Vertical
		statsLay.HorizontalAlignment = Enum.HorizontalAlignment.Center
		statsLay.SortOrder = Enum.SortOrder.LayoutOrder
		statsLay.Padding = UDim.new(0, 0)
		statsLay.Parent = stats
		local labels: { TextLabel } = {}
		for li, n in ipairs(vals) do
			local row = Instance.new("TextLabel")
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, 0, 0, 15)
			row.LayoutOrder = li
			row.Font = UiTheme.Font
			row.Text = formatStatLine(STAT_ICONS[li], n, false)
			row.TextColor3 = WHITE
			row.TextSize = 13
			row.TextXAlignment = Enum.TextXAlignment.Center
			row.Parent = stats
			labels[li] = row
		end
		h3s[i] = stats
		h3Labels[i] = labels
		local idx = i
		letter.Activated:Connect(function()
			onLetter(idx)
		end)
	end

	local function refreshSizeRow()
		local w = row3.AbsoluteSize.X
		if w < 3 then
			return
		end
		local pad = 6
		local cellW = math.floor((w - pad * 2) / 3)
		local circle = math.clamp(math.floor(cellW * 0.72), 36, 72)
		local wordH = 16
		local statText = 13
		local statLine = math.floor(statText * 1.15 + 0.5)
		local statH = statLine * 4
		local cellH = 2 + circle + 4 + wordH + 2 + statH + 4
		sizeGrid.CellSize = UDim2.fromOffset(math.max(1, cellW), cellH)
		for i = 1, 3 do
			local letter = h1s[i]
			local word = h2s[i]
			local stats = h3s[i]
			if letter then
				letter.Size = UDim2.fromOffset(circle, circle)
			end
			local wordY = 2 + circle + 4
			if word then
				word.Position = UDim2.new(0.5, 0, 0, wordY)
				word.Size = UDim2.new(1, -4, 0, wordH)
				word.TextSize = math.max(10, math.floor(wordH * 0.9))
			end
			if stats then
				stats.Position = UDim2.new(0.5, 0, 0, wordY + wordH + 2)
				stats.Size = UDim2.new(1, -2, 0, statH)
				for _, row in ipairs(stats:GetChildren()) do
					if row:IsA("TextLabel") then
						row.TextSize = statText
						row.Size = UDim2.new(1, 0, 0, statLine)
					end
				end
			end
		end
	end
	row3:GetPropertyChangedSignal("AbsoluteSize"):Connect(refreshSizeRow)
	task.defer(refreshSizeRow)

	RelocateController.onActiveChanged(function(active: boolean)
		setVisible(active)
	end)
	RelocateController.setR1WhileActiveHandler(function(): boolean
		if confirmGui then
			return true
		end
		showConfirmUnlock()
		return true
	end)

	UserInputService.InputBegan:Connect(function(input)
		if not confirmGui then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.Escape then
			hideConfirm()
		end
	end)
end

return CoralInspectPanel
