--!strict
--[[
	Join Wave-100 showcase: remap Workspace.Plots.Intro (authored on Plot4) onto the
	local plot, plotcam top→bottom while corals bleach white, fall away, then drop-in
	the player's real reef and return to follow cam.
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local PlotLoadDropIn = require(script.Parent:WaitForChild("PlotLoadDropIn"))
local SkyCamParts = require(script.Parent:WaitForChild("SkyCamParts"))

-- Set true to re-enable the Wave-100 join showcase.
local INTRO_ENABLED = false

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ATTR_BUSY = "OceanTD_JoinIntroBusy"
local ATTR_CAM_POS = "OceanTD_JoinIntroCamPos"
local ATTR_FORCE_CAM = "OceanTD_ForceCamMode"
local FREEZE_ACTION = "OceanTD_JoinIntroFreeze"
local SKIP_ACTION = "OceanTD_JoinIntroSkip"

local WHITE = Color3.new(1, 1, 1)
local SKIP_GREEN = Color3.fromRGB(55, 200, 90)
local WAVE_HOLD_SEC = 4
local WAVE_COUNT_SEC = 3
local COLOR_WINDOW_SEC = 3
local CAM_DOWN_SEC = 6
local FALL_MIN_SEC = 1
local FALL_MAX_SEC = 2
local FALL_Y = -100
local CLONE_BATCH = 40

local syncPayload: { hasSeenJoinIntro: boolean, introSourceCFrame: CFrame }? = nil
local syncEvent = Instance.new("BindableEvent")
local running = false
local skipRequested = false
local canSkip = false
local markSeenRf = Remotes.getFunction("RequestMarkJoinIntroSeen")
local getIntroRf = Remotes.getFunction("RequestGetJoinIntro")

Remotes.get("JoinIntroSync").OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local source = payload.introSourceCFrame
	local prev = syncPayload
	syncPayload = {
		hasSeenJoinIntro = payload.hasSeenJoinIntro == true,
		introSourceCFrame = if typeof(source) == "CFrame"
			then source
			elseif prev then prev.introSourceCFrame
			else CFrame.identity,
	}
	syncEvent:Fire()
end)

local function waitForSync(timeoutSec: number): typeof(syncPayload)
	local deadline = os.clock() + timeoutSec
	while not syncPayload and os.clock() < deadline do
		task.wait(0.05)
	end
	if syncPayload then
		return syncPayload
	end
	local ok, result = pcall(function()
		return getIntroRf:InvokeServer()
	end)
	if ok and typeof(result) == "table" then
		local source = result.introSourceCFrame
		syncPayload = {
			hasSeenJoinIntro = result.hasSeenJoinIntro == true,
			introSourceCFrame = if typeof(source) == "CFrame" then source else CFrame.identity,
		}
	end
	return syncPayload
end

local function hideIntroTemplatePart(part: BasePart)
	part.LocalTransparencyModifier = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
end

local function hideIntroTemplate()
	local plots = Workspace:FindFirstChild("Plots")
	local intro = plots and plots:FindFirstChild("Intro")
	if not intro then
		return
	end
	for _, d in ipairs(intro:GetDescendants()) do
		if d:IsA("BasePart") then
			hideIntroTemplatePart(d)
		end
	end
end

-- Keep Workspace.Plots.Intro invisible while the join showcase is off / unused as a world prop.
local function watchHideIntroTemplate()
	task.spawn(function()
		local plots = Workspace:WaitForChild("Plots", 60)
		if not plots then
			return
		end
		local intro = plots:WaitForChild("Intro", 60)
		if not intro then
			return
		end
		hideIntroTemplate()
		intro.DescendantAdded:Connect(function(d)
			if d:IsA("BasePart") then
				hideIntroTemplatePart(d)
			end
		end)
	end)
end

local function collectIntroRoots(intro: Instance): { Instance }
	local roots: { Instance } = {}
	local function consider(inst: Instance)
		if inst:IsA("Model") or inst:IsA("BasePart") then
			table.insert(roots, inst)
		end
	end
	for _, ch in ipairs(intro:GetChildren()) do
		if ch:IsA("Folder") then
			for _, nested in ipairs(ch:GetChildren()) do
				consider(nested)
			end
		else
			consider(ch)
		end
	end
	if #roots == 0 then
		for _, d in ipairs(intro:GetDescendants()) do
			if d:IsA("BasePart") then
				table.insert(roots, d)
			end
		end
	end
	return roots
end

local function sanitizeVisual(inst: Instance)
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
		end
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
			d:Destroy()
		end
	end
	if inst:IsA("BasePart") then
		inst.Anchored = true
		inst.CanCollide = false
		inst.CanQuery = false
		inst.CanTouch = false
		inst.CastShadow = false
	end
end

local function gatherParts(root: Instance): { BasePart }
	local parts: { BasePart } = {}
	if root:IsA("BasePart") then
		table.insert(parts, root)
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	return parts
end

local function setOwnedPlotHidden(hidden: boolean)
	for _, part in ipairs(PlotLoadDropIn.gatherOwnedPlotParts()) do
		PlotLoadDropIn.setPartHiddenLocal(part, hidden)
	end
end

local function smoothstep(u: number): number
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

local hiddenHud: { { gui: GuiObject, wasVisible: boolean } } = {}
local hiddenScreens: { { gui: ScreenGui, wasEnabled: boolean } } = {}

local function hideHud()
	table.clear(hiddenHud)
	table.clear(hiddenScreens)
	local skipNames = {
		OceanTD_JoinIntro = true,
		OceanTD_HideUiFly = true,
		TouchGui = true,
	}
	for _, ch in ipairs(playerGui:GetChildren()) do
		if ch:IsA("ScreenGui") then
			if skipNames[ch.Name] then
				continue
			end
			table.insert(hiddenScreens, { gui = ch, wasEnabled = ch.Enabled })
			ch.Enabled = false
		end
	end
end

local function restoreHud()
	for _, entry in ipairs(hiddenScreens) do
		if entry.gui.Parent then
			entry.gui.Enabled = entry.wasEnabled
		end
	end
	table.clear(hiddenScreens)
	for _, entry in ipairs(hiddenHud) do
		if entry.gui.Parent then
			entry.gui.Visible = entry.wasVisible
		end
	end
	table.clear(hiddenHud)
end

local function bindFreeze(on: boolean)
	ContextActionService:UnbindAction(FREEZE_ACTION)
	if not on then
		return
	end
	ContextActionService:BindActionAtPriority(FREEZE_ACTION, function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Space)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.JumpHeight = 0
	end
end

local function makeUi(allowSkip: boolean): (ScreenGui, TextLabel, TextButton?)
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_JoinIntro"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 120
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui

	local wave = Instance.new("TextLabel")
	wave.Name = "WaveLabel"
	wave.BackgroundTransparency = 1
	wave.AnchorPoint = Vector2.new(0.5, 0.5)
	wave.Position = UDim2.fromScale(0.5, 0.18)
	wave.Size = UDim2.fromScale(0.7, 0.1)
	wave.Font = UiTheme.Font
	wave.Text = "Wave 100"
	wave.TextColor3 = Color3.new(1, 1, 1)
	wave.TextScaled = true
	wave.ZIndex = 2
	wave.Parent = sg

	local skipBtn: TextButton? = nil
	if allowSkip then
		local btn = Instance.new("TextButton")
		btn.Name = "Skip"
		btn.AnchorPoint = Vector2.new(1, 1)
		btn.Position = UDim2.new(1, -24, 1, -24)
		btn.Size = UDim2.fromOffset(120, 48)
		btn.BackgroundColor3 = SKIP_GREEN
		btn.Font = UiTheme.Font
		btn.Text = "SKIP"
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.TextScaled = true
		btn.AutoButtonColor = true
		btn.Selectable = true
		btn.ZIndex = 3
		btn.Parent = sg
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = btn
		skipBtn = btn
	end

	return sg, wave, skipBtn
end

local function animateWaveLabel(label: TextLabel, token: { cancelled: boolean })
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < WAVE_HOLD_SEC do
			if token.cancelled then
				return
			end
			label.Text = "Wave 100"
			RunService.Heartbeat:Wait()
		end
		local t1 = os.clock()
		while os.clock() - t1 < WAVE_COUNT_SEC do
			if token.cancelled then
				return
			end
			local u = (os.clock() - t1) / WAVE_COUNT_SEC
			local n = math.floor(100 * (1 - smoothstep(u)) + 0.5)
			label.Text = "Wave " .. tostring(n)
			RunService.Heartbeat:Wait()
		end
		if not token.cancelled then
			label.Text = "Wave 0"
		end
	end)
end

local function bleachAndFall(parts: { BasePart }, token: { cancelled: boolean }): number
	local rng = Random.new()
	local maxEnd = 0
	for _, part in ipairs(parts) do
		if token.cancelled then
			break
		end
		local delaySec = rng:NextNumber(0, COLOR_WINDOW_SEC)
		local fadeSec = rng:NextNumber(0.35, 1.1)
		local fallSec = rng:NextNumber(FALL_MIN_SEC, FALL_MAX_SEC)
		maxEnd = math.max(maxEnd, delaySec + fadeSec + fallSec)
		task.delay(delaySec, function()
			if token.cancelled or not part.Parent then
				return
			end
			part.Material = Enum.Material.SmoothPlastic
			local tw = TweenService:Create(part, TweenInfo.new(fadeSec, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Color = WHITE,
			})
			tw:Play()
			tw.Completed:Wait()
			if token.cancelled or not part.Parent then
				return
			end
			local startCF = part.CFrame
			local target = CFrame.new(startCF.Position.X, FALL_Y, startCF.Position.Z) * (startCF - startCF.Position)
			local fall = TweenService:Create(part, TweenInfo.new(fallSec, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				CFrame = target,
			})
			fall:Play()
			fall.Completed:Wait()
			if part.Parent then
				part:Destroy()
			end
		end)
	end
	return maxEnd
end

local function destroyFolder(folder: Folder?)
	if folder and folder.Parent then
		folder:Destroy()
	end
end

local function finishCamToFollow()
	playerGui:SetAttribute(ATTR_CAM_POS, nil)
	playerGui:SetAttribute(ATTR_BUSY, false)
	playerGui:SetAttribute(ATTR_FORCE_CAM, "off")
	playerGui:SetAttribute("OceanTD_ForceCloseFreeCam", os.clock())
	local cam = Workspace.CurrentCamera
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if cam then
		cam.CameraType = Enum.CameraType.Custom
		if hum then
			cam.CameraSubject = hum
		end
	end
end

local function markSeen()
	pcall(function()
		markSeenRf:InvokeServer()
	end)
end

local function runIntro()
	if running then
		return
	end
	running = true
	skipRequested = false

	hideIntroTemplate()

	if not ClientPlot.isReady() then
		local readyDeadline = os.clock() + 15
		while not ClientPlot.isReady() and os.clock() < readyDeadline do
			task.wait(0.05)
		end
	end
	local plot = ClientPlot.get()
	if not plot then
		running = false
		return
	end

	local payload = waitForSync(12)
	if not payload then
		warn("[JoinIntro] JoinIntroSync missing — skip showcase")
		running = false
		return
	end

	local plotsFolder = Workspace:FindFirstChild("Plots")
	local intro = plotsFolder and plotsFolder:FindFirstChild("Intro")
	if not intro then
		warn("[JoinIntro] Workspace.Plots.Intro missing")
		running = false
		return
	end

	local decorDeadline = os.clock() + 10
	while Workspace:GetAttribute("DecorEnvReplicationReady") ~= true and os.clock() < decorDeadline do
		task.wait(0.05)
	end

	local pose = SkyCamParts.waitForPose(12)
	if not pose then
		warn("[JoinIntro] SkyCam / SkyCamFocus missing — skip showcase")
		running = false
		return
	end

	canSkip = payload.hasSeenJoinIntro == true
	local token = { cancelled = false }
	local uiToken = { cancelled = false }
	local showcase = Instance.new("Folder")
	showcase.Name = "OceanTD_JoinIntroShowcase"
	showcase.Parent = Workspace

	local sg, waveLabel, skipBtn = makeUi(canSkip)
	hideHud()
	bindFreeze(true)
	playerGui:SetAttribute(ATTR_BUSY, true)
	playerGui:SetAttribute("OceanTD_ForceCloseSkills", os.clock())
	playerGui:SetAttribute("OceanTD_ForceCloseReefReport", os.clock())
	setOwnedPlotHidden(true)

	local top = SkyCamParts.topMiddle(pose)
	local bottom = SkyCamParts.bottomMiddle(pose)
	local focusPos = pose.focusPos
	playerGui:SetAttribute(ATTR_CAM_POS, top)
	-- Enter plotcam when possible (SkyCamParts remaps MasterPlotDecor if StaticPlot is late).
	playerGui:SetAttribute(ATTR_FORCE_CAM, "plotcam")
	task.defer(function()
		if playerGui:GetAttribute(ATTR_BUSY) == true then
			playerGui:SetAttribute(ATTR_FORCE_CAM, "plotcam")
		end
	end)

	animateWaveLabel(waveLabel, uiToken)

	local function requestSkip()
		if not canSkip or skipRequested then
			return
		end
		skipRequested = true
		token.cancelled = true
	end

	local skipConns: { RBXScriptConnection } = {}
	if skipBtn then
		table.insert(skipConns, skipBtn.Activated:Connect(requestSkip))
		GuiService.SelectedObject = skipBtn
		ContextActionService:BindActionAtPriority(SKIP_ACTION, function(_name, state)
			if state == Enum.UserInputState.Begin then
				requestSkip()
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonA)
		table.insert(skipConns, UserInputService.InputBegan:Connect(function(input, gp)
			if gp then
				return
			end
			if input.KeyCode == Enum.KeyCode.ButtonA then
				requestSkip()
			end
		end))
	end

	local sourceCf = payload.introSourceCFrame
	local roots = collectIntroRoots(intro)
	local showcaseParts: { BasePart } = {}
	for i, root in ipairs(roots) do
		if token.cancelled then
			break
		end
		local clone = root:Clone()
		sanitizeVisual(clone)
		if clone:IsA("Model") then
			local pivot = (root :: Model):GetPivot()
			;(clone :: Model):PivotTo(ClientPlot.remapCFrameFromSource(sourceCf, pivot))
		elseif clone:IsA("BasePart") then
			clone.CFrame = ClientPlot.remapCFrameFromSource(sourceCf, (root :: BasePart).CFrame)
		end
		clone.Parent = showcase
		for _, p in ipairs(gatherParts(clone)) do
			table.insert(showcaseParts, p)
		end
		if i % CLONE_BATCH == 0 then
			RunService.Heartbeat:Wait()
		end
	end

	-- Cam down while bleach/fall runs — always look at SkyCamFocus (plotcam behavior).
	local camT0 = os.clock()
	local camConn = RunService.RenderStepped:Connect(function()
		if token.cancelled then
			return
		end
		local u = smoothstep((os.clock() - camT0) / CAM_DOWN_SEC)
		local pos = top:Lerp(bottom, u)
		playerGui:SetAttribute(ATTR_CAM_POS, pos)
		local cam = Workspace.CurrentCamera
		if cam then
			cam.CameraType = Enum.CameraType.Scriptable
			if (focusPos - pos).Magnitude < 0.05 then
				cam.CFrame = CFrame.new(pos)
			else
				cam.CFrame = CFrame.lookAt(pos, focusPos)
			end
		end
	end)

	local fallWindow = 0
	if not token.cancelled then
		fallWindow = bleachAndFall(showcaseParts, token)
	end

	local waitUntil = os.clock() + math.max(CAM_DOWN_SEC, fallWindow)
	while os.clock() < waitUntil and not token.cancelled do
		task.wait(0.05)
	end

	camConn:Disconnect()
	destroyFolder(showcase)

	-- Handoff: real plot drop-in + follow cam.
	uiToken.cancelled = true
	setOwnedPlotHidden(false)
	local owned = PlotLoadDropIn.gatherOwnedPlotParts()
	local span = if #owned >= 400 then 3 elseif #owned >= 80 then 2 else 1
	PlotLoadDropIn.play(#owned, span)
	task.wait(math.min(span + 0.5, 3.2))

	finishCamToFollow()
	bindFreeze(false)
	ContextActionService:UnbindAction(SKIP_ACTION)
	for _, c in ipairs(skipConns) do
		c:Disconnect()
	end
	if sg.Parent then
		sg:Destroy()
	end
	restoreHud()
	markSeen()
	playerGui:SetAttribute(ATTR_CAM_POS, nil)
	running = false
end

task.spawn(function()
	-- Always hide the authored template in the world (even when showcase is off).
	watchHideIntroTemplate()

	if not INTRO_ENABLED then
		return
	end
	local sessionReady = Remotes.get("SessionReady")
	-- Late join / hot reload: SessionReady may have already fired.
	local gotReady = false
	local conn = sessionReady.OnClientEvent:Connect(function()
		gotReady = true
	end)
	if ClientPlot.isReady() then
		gotReady = true
	else
		local deadline = os.clock() + 30
		while not gotReady and os.clock() < deadline do
			task.wait(0.05)
		end
	end
	conn:Disconnect()
	-- Let hydrate visuals land one frame.
	task.wait(0.35)
	local ok, err = pcall(runIntro)
	if not ok then
		warn("[JoinIntro] failed:", err)
		playerGui:SetAttribute(ATTR_BUSY, false)
		playerGui:SetAttribute(ATTR_CAM_POS, nil)
		bindFreeze(false)
		ContextActionService:UnbindAction(SKIP_ACTION)
		restoreHud()
		finishCamToFollow()
		running = false
	end
end)
