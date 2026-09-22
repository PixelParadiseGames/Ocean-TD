--!strict
--[[
	Join Wave-100 showcase:
	1) Loading buffer (sky-up cam + pill bar) so IntroElements / décor can stream
	2) Pan down to CamStartFocus; avatar visible at IntroPosition
	3) Live mid–wave-100 sim; CamStart→CamEnd over 9s; hold through bleach
	4) Bleach + plot-size tween, drop-in, teleport to plot spawn, return follow cam
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Set false to skip the Wave-100 join showcase.
local INTRO_ENABLED = true

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ATTR_BUSY = "OceanTD_JoinIntroBusy"
local ATTR_CAM_POS = "OceanTD_JoinIntroCamPos"
local ATTR_ROLL_FINGER = "OceanTD_RollFingerHint"
local ATTR_FORCE_CAM = "OceanTD_ForceCamMode"
local FREEZE_ACTION = "OceanTD_JoinIntroFreeze"
local SKIP_ACTION = "OceanTD_JoinIntroSkip"

local WHITE = Color3.new(1, 1, 1)
local SKIP_GREEN = Color3.fromRGB(55, 200, 90)
local LOAD_BAR_BG = Color3.fromRGB(28, 36, 48)
local LOAD_BAR_FILL = Color3.fromRGB(70, 200, 255)
local CAM_DOWN_SEC = 9
local LOAD_BAR_FILL_SEC = 3 -- load pill never completes faster than this
local CAM_HANDOFF_SEC = 1.05
local CAM_HANDOFF_SKIP_SEC = 0.45
local PAN_DOWN_SEC = 1.15
-- Bleach: hard cap total wait; tight stagger + high starts/frame = fewer stragglers.
local BLEACH_TOTAL_MAX_SEC = 2.5
local COLOR_WINDOW_SEC = 0.85
local FALL_Y = -100
local CLONE_BATCH = 24
local INTRO_WAVE = 100
local BLEACH_STARTS_PER_FRAME = 64
local BLEACH_FALL_SEC = 1.0 * 0.7
local BLEACH_HOLD_WHITE_SEC = 0.2 * 0.7
local BLEACH_WAIT_PAD_SEC = 0.12
local BLEACH_WAIT_MIN_SEC = 1.5

-- While true, avatar stays visible at IntroPosition (not hidden by early hold).
local introAvatarShown = false
local introStandCf: CFrame? = nil

-- Load bar is shown ASAP (before OceanTD modules / SessionReady) so device joins
-- aren't a blank sky wait while ReplicatedStorage streams in.
local earlyLoadGui: ScreenGui? = nil
local earlyLoadFill: Frame? = nil
local loadBarStartedAt = 0
local loadBarFillDone = false
local loadBarAnimating = false

local function setLoadFillProgress(fill: Frame, u: number)
	u = math.clamp(u, 0, 1)
	local eased = u * u * (3 - 2 * u)
	-- Scale-based so AbsoluteSize=0 during first layout frames doesn't stick the bar.
	if eased <= 0 then
		fill.Size = UDim2.new(0, 0, 1, -8)
	else
		fill.Size = UDim2.new(eased, -8, 1, -8)
	end
end

local function bootstrapImmediateLoadBar()
	if not INTRO_ENABLED then
		return
	end
	playerGui:SetAttribute(ATTR_BUSY, true)
	playerGui:SetAttribute(ATTR_FORCE_CAM, "off")
	local cam = Workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Scriptable
		local pos = cam.CFrame.Position
		cam.CFrame = CFrame.lookAt(pos, pos + Vector3.new(0, 200, 0))
		playerGui:SetAttribute(ATTR_CAM_POS, pos)
	end

	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_JoinIntroLoad"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 2000
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui

	local track = Instance.new("Frame")
	track.Name = "LoadTrack"
	track.AnchorPoint = Vector2.new(0.5, 0.5)
	track.Position = UDim2.fromScale(0.5, 0.5)
	track.Size = UDim2.new(0.55, 0, 0, 36)
	track.BackgroundColor3 = LOAD_BAR_BG
	track.BorderSizePixel = 0
	track.Parent = sg
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track
	local trackAspect = Instance.new("UISizeConstraint")
	trackAspect.MinSize = Vector2.new(220, 28)
	trackAspect.MaxSize = Vector2.new(720, 44)
	trackAspect.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.new(0, 4, 0.5, 0)
	fill.Size = UDim2.new(0, 0, 1, -8)
	fill.BackgroundColor3 = LOAD_BAR_FILL
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	-- Animate immediately so device module streaming isn't 10s of empty pill.
	-- Fill takes LOAD_BAR_FILL_SEC; bar stays up (full) until intro dismisses it.
	earlyLoadGui = sg
	earlyLoadFill = fill
	loadBarStartedAt = os.clock()
	loadBarFillDone = false
	loadBarAnimating = true
	task.spawn(function()
		local t0 = loadBarStartedAt
		while earlyLoadGui == sg and sg.Parent and (os.clock() - t0) < LOAD_BAR_FILL_SEC do
			local u = math.clamp((os.clock() - t0) / LOAD_BAR_FILL_SEC, 0, 1)
			setLoadFillProgress(fill, u)
			RunService.RenderStepped:Wait()
		end
		if earlyLoadGui == sg and sg.Parent then
			setLoadFillProgress(fill, 1)
			loadBarFillDone = true
			loadBarAnimating = false
		end
	end)
end

bootstrapImmediateLoadBar()

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local PlotLoadDropIn = require(script.Parent:WaitForChild("PlotLoadDropIn"))
local PlotSizeCinematic = require(script.Parent:WaitForChild("PlotSizeCinematic"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))
local WaveSign = require(script.Parent:WaitForChild("WaveSign"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local syncPayload: { hasSeenJoinIntro: boolean, introSourceCFrame: CFrame }? = nil
local syncEvent = Instance.new("BindableEvent")
local running = false
local skipRequested = false
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

-- Intro corals stream in over time on device — snapshot only after part count goes quiet.
local function countIntroParts(intro: Instance): number
	local n = 0
	for _, d in ipairs(intro:GetDescendants()) do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

local function waitIntroStreamStable(intro: Instance, quietSec: number, timeoutSec: number): number
	local deadline = os.clock() + timeoutSec
	local lastCount = -1
	local quietSince = os.clock()
	while os.clock() < deadline do
		local n = countIntroParts(intro)
		if n ~= lastCount then
			lastCount = n
			quietSince = os.clock()
		elseif n > 0 and (os.clock() - quietSince) >= quietSec then
			return n
		end
		task.wait(0.08)
	end
	return math.max(0, lastCount)
end

local function waitHungryFishReady(timeoutSec: number): boolean
	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		local folder = ReplicatedStorage:FindFirstChild("HungryFish")
		if folder then
			for _, d in ipairs(folder:GetDescendants()) do
				if d:IsA("BasePart") or d:IsA("MeshPart") then
					return true
				end
			end
		end
		task.wait(0.1)
	end
	return false
end

local function waitJoinIntroPackage(timeoutSec: number): Instance?
	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		if oceanRoot:GetAttribute("JoinIntroPackageReady") == true then
			local package = oceanRoot:FindFirstChild("JoinIntroPackage")
			local introSrc = package and (package:FindFirstChild("Intro") or package)
			if introSrc then
				return introSrc
			end
		end
		task.wait(0.05)
	end
	-- Fallback: live Workspace.Plots.Intro (may still be streaming).
	local plots = Workspace:FindFirstChild("Plots")
	return plots and plots:FindFirstChild("Intro")
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
local hiddenScreens: { [ScreenGui]: boolean } = {}
local hudSuppressConn: RBXScriptConnection? = nil
local hudChildConn: RBXScriptConnection? = nil

local HUD_SKIP_NAMES = {
	OceanTD_JoinIntro = true,
	OceanTD_JoinIntroLoad = true,
	OceanTD_HideUiFly = true,
	TouchGui = true,
}

local function shouldKeepScreenGui(sg: ScreenGui): boolean
	return HUD_SKIP_NAMES[sg.Name] == true
end

local function suppressScreenGui(sg: ScreenGui)
	if shouldKeepScreenGui(sg) then
		return
	end
	if hiddenScreens[sg] == nil then
		hiddenScreens[sg] = sg.Enabled
	end
	if sg.Enabled then
		sg.Enabled = false
	end
end

local function hideHud()
	for _, ch in ipairs(playerGui:GetChildren()) do
		if ch:IsA("ScreenGui") then
			suppressScreenGui(ch)
		end
	end
end

local function startHudSuppress()
	hideHud()
	if not hudChildConn then
		hudChildConn = playerGui.ChildAdded:Connect(function(ch)
			if playerGui:GetAttribute(ATTR_BUSY) ~= true then
				return
			end
			if ch:IsA("ScreenGui") then
				task.defer(function()
					if playerGui:GetAttribute(ATTR_BUSY) == true and ch.Parent then
						suppressScreenGui(ch)
					end
				end)
			end
		end)
	end
	if not hudSuppressConn then
		-- InventoryUI / remotes often re-enable MainHUD after our first pass.
		hudSuppressConn = RunService.Heartbeat:Connect(function()
			if playerGui:GetAttribute(ATTR_BUSY) ~= true then
				return
			end
			for _, ch in ipairs(playerGui:GetChildren()) do
				if ch:IsA("ScreenGui") and not shouldKeepScreenGui(ch) and ch.Enabled then
					suppressScreenGui(ch)
				end
			end
		end)
	end
end

local function stopHudSuppress()
	if hudSuppressConn then
		hudSuppressConn:Disconnect()
		hudSuppressConn = nil
	end
	if hudChildConn then
		hudChildConn:Disconnect()
		hudChildConn = nil
	end
end

local function restoreHud()
	stopHudSuppress()
	for sg, wasEnabled in pairs(hiddenScreens) do
		if sg.Parent then
			sg.Enabled = wasEnabled
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

local DEFAULT_WALK_SPEED = 16
local DEFAULT_JUMP_HEIGHT = 10.8
local savedWalkSpeed = DEFAULT_WALK_SPEED
local savedJumpHeight = DEFAULT_JUMP_HEIGHT
local freezeSaved = false

local function bindFreeze(on: boolean)
	ContextActionService:UnbindAction(FREEZE_ACTION)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if on then
		ContextActionService:BindActionAtPriority(FREEZE_ACTION, function()
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Space)
		if hum then
			if not freezeSaved then
				if hum.WalkSpeed > 0 then
					savedWalkSpeed = hum.WalkSpeed
				end
				if hum.JumpHeight > 0 then
					savedJumpHeight = hum.JumpHeight
				end
				freezeSaved = true
			end
			hum.WalkSpeed = 0
			hum.JumpPower = 0
			hum.JumpHeight = 0
		end
		return
	end
	if hum then
		hum.WalkSpeed = if savedWalkSpeed > 0 then savedWalkSpeed else DEFAULT_WALK_SPEED
		hum.JumpHeight = if savedJumpHeight > 0 then savedJumpHeight else DEFAULT_JUMP_HEIGHT
	end
	freezeSaved = false
end

local function makeUi(): (ScreenGui, TextButton)
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_JoinIntro"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 120
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui

	local btn = Instance.new("TextButton")
	btn.Name = "Skip"
	btn.AnchorPoint = Vector2.new(1, 1)
	btn.Position = UDim2.new(1, -28, 1, -28)
	btn.Size = UDim2.fromOffset(140, 52)
	btn.BackgroundColor3 = SKIP_GREEN
	btn.Font = UiTheme.Font
	btn.Text = "SKIP"
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.TextScaled = true
	btn.AutoButtonColor = true
	btn.Selectable = true
	btn.Active = true
	btn.ZIndex = 3
	btn.Parent = sg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = btn

	return sg, btn
end

local function makeLoadingUi(): (ScreenGui, Frame)
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_JoinIntroLoad"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 2000
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui

	local track = Instance.new("Frame")
	track.Name = "LoadTrack"
	track.AnchorPoint = Vector2.new(0.5, 0.5)
	track.Position = UDim2.fromScale(0.5, 0.5)
	track.Size = UDim2.new(0.55, 0, 0, 36)
	track.BackgroundColor3 = LOAD_BAR_BG
	track.BorderSizePixel = 0
	track.Parent = sg
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track
	local trackAspect = Instance.new("UISizeConstraint")
	trackAspect.MinSize = Vector2.new(220, 28)
	trackAspect.MaxSize = Vector2.new(720, 44)
	trackAspect.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.new(0, 4, 0.5, 0)
	fill.Size = UDim2.new(0, 0, 1, -8)
	fill.BackgroundColor3 = LOAD_BAR_FILL
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	return sg, fill
end

local function runLoadingBar(fill: Frame, durationSec: number, cancelled: () -> boolean)
	local t0 = os.clock()
	while os.clock() - t0 < durationSec do
		if cancelled() then
			return
		end
		local u = math.clamp((os.clock() - t0) / durationSec, 0, 1)
		setLoadFillProgress(fill, u)
		RunService.RenderStepped:Wait()
	end
	setLoadFillProgress(fill, 1)
end

local function destroyEarlyLoadBar()
	loadBarFillDone = true
	loadBarAnimating = false
	if earlyLoadGui and earlyLoadGui.Parent then
		earlyLoadGui:Destroy()
	end
	earlyLoadGui = nil
	earlyLoadFill = nil
end

local function startEarlyLoadBarFill()
	local sg = earlyLoadGui
	local fill = earlyLoadFill
	if not (sg and sg.Parent and fill and fill.Parent) then
		return
	end
	-- Don't restart if bootstrap already started the fill.
	if loadBarAnimating or loadBarStartedAt > 0 then
		return
	end
	loadBarAnimating = true
	loadBarFillDone = false
	loadBarStartedAt = os.clock()
	setLoadFillProgress(fill, 0)
	task.spawn(function()
		runLoadingBar(fill, LOAD_BAR_FILL_SEC, function()
			return earlyLoadGui ~= sg or not sg.Parent or playerGui:GetAttribute(ATTR_BUSY) ~= true
		end)
		if earlyLoadGui == sg then
			loadBarFillDone = true
			loadBarAnimating = false
		end
	end)
end

local function showEarlyLoadBar()
	-- bootstrapImmediateLoadBar may have already created this before modules loaded.
	if earlyLoadGui and earlyLoadGui.Parent then
		return
	end
	local sg, fill = makeLoadingUi()
	earlyLoadGui = sg
	earlyLoadFill = fill
	loadBarStartedAt = 0
	loadBarFillDone = false
	loadBarAnimating = false
	startEarlyLoadBarFill()
end

local function waitEarlyLoadBarMin()
	startEarlyLoadBarFill()
	-- Don't dismiss until the fill has had time to play (may already be done from bootstrap).
	while earlyLoadGui and earlyLoadGui.Parent do
		if loadBarStartedAt > 0 and (os.clock() - loadBarStartedAt) >= LOAD_BAR_FILL_SEC then
			break
		end
		task.wait(0.05)
	end
end

local function bleachPartLook(part: BasePart)
	-- Instant white (no per-part TweenService Color tweens — those dominated CPU).
	if part:IsA("MeshPart") then
		(part :: MeshPart).TextureID = ""
	end
	for _, ch in ipairs(part:GetChildren()) do
		if ch:IsA("SurfaceAppearance") or ch:IsA("Texture") or ch:IsA("Decal") then
			ch:Destroy()
		end
	end
	part.Material = Enum.Material.SmoothPlastic
	part.Color = WHITE
end

local function bleachAndFall(parts: { BasePart }, token: { cancelled: boolean }): number
	-- One job per Model (or loose part) so accents bleach with the coral —
	-- never destroy a Model while sibling accents are still colorful.
	local jobs: { { parts: { BasePart }, drive: BasePart | Model } } = {}
	local seenModel: { [Model]: boolean } = {}
	local seenLoose: { [BasePart]: boolean } = {}

	for _, part in ipairs(parts) do
		if not part.Parent then
			continue
		end
		local model = part:FindFirstAncestorOfClass("Model")
		if model and model.Parent and model.Parent.Name == "OceanTD_JoinIntroShowcase" then
			if seenModel[model] then
				continue
			end
			seenModel[model] = true
			local bundle: { BasePart } = {}
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") then
					table.insert(bundle, d)
				end
			end
			if #bundle > 0 then
				table.insert(jobs, { parts = bundle, drive = model })
			end
		else
			if seenLoose[part] then
				continue
			end
			seenLoose[part] = true
			local bundle: { BasePart } = { part }
			for _, d in ipairs(part:GetDescendants()) do
				if d:IsA("BasePart") then
					table.insert(bundle, d)
				end
			end
			table.insert(jobs, { parts = bundle, drive = part })
		end
	end

	local rng = Random.new()
	local n = #jobs
	-- Drain faster (64/frame); shrink stagger if needed so worst-case ≤ BLEACH_TOTAL_MAX_SEC.
	local queueDrainSec = (n / math.max(1, BLEACH_STARTS_PER_FRAME)) * (1 / 60)
	local fixedTail = BLEACH_HOLD_WHITE_SEC + BLEACH_FALL_SEC + BLEACH_WAIT_PAD_SEC
	local colorWindow = math.min(
		COLOR_WINDOW_SEC,
		math.max(0.2, BLEACH_TOTAL_MAX_SEC - fixedTail - queueDrainSec)
	)
	local maxEnd = math.min(BLEACH_TOTAL_MAX_SEC, colorWindow + queueDrainSec + fixedTail)

	-- Pre-roll delays so wait duration is exact (not racing an async maxEnd).
	local delays: { number } = table.create(n)
	for i = 1, n do
		delays[i] = rng:NextNumber(0, colorWindow)
	end

	task.spawn(function()
		local qi = 1
		while qi <= n and not token.cancelled do
			local started = 0
			while started < BLEACH_STARTS_PER_FRAME and qi <= n do
				if token.cancelled then
					return
				end
				local job = jobs[qi]
				local delaySec = delays[qi]
				qi += 1
				started += 1
				task.delay(delaySec, function()
					if token.cancelled then
						return
					end
					local anyAlive = false
					for _, p in ipairs(job.parts) do
						if p.Parent then
							bleachPartLook(p)
							anyAlive = true
						end
					end
					if not anyAlive then
						return
					end
					task.delay(BLEACH_HOLD_WHITE_SEC, function()
						if token.cancelled then
							return
						end
						local drive = job.drive
						if not drive.Parent then
							return
						end
						if drive:IsA("Model") then
							local startPivot = drive:GetPivot()
							local target = CFrame.new(startPivot.Position.X, FALL_Y, startPivot.Position.Z)
								* (startPivot - startPivot.Position)
							local t0 = os.clock()
							while os.clock() - t0 < BLEACH_FALL_SEC do
								if token.cancelled or not drive.Parent then
									return
								end
								local u = math.clamp((os.clock() - t0) / BLEACH_FALL_SEC, 0, 1)
								local e = u * u
								drive:PivotTo(startPivot:Lerp(target, e))
								RunService.Heartbeat:Wait()
							end
							if drive.Parent then
								drive:Destroy()
							end
						elseif drive:IsA("BasePart") then
							local startCF = drive.CFrame
							local target = CFrame.new(startCF.Position.X, FALL_Y, startCF.Position.Z)
								* (startCF - startCF.Position)
							TweenService:Create(drive, TweenInfo.new(BLEACH_FALL_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
								CFrame = target,
							}):Play()
							task.delay(BLEACH_FALL_SEC, function()
								if drive.Parent then
									drive:Destroy()
								end
							end)
						end
					end)
				end)
			end
			RunService.Heartbeat:Wait()
		end
	end)

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

local function followHandoffCFrame(hrp: BasePart): CFrame
	local cam = Workspace.CurrentCamera
	local dist = 12.5
	if cam then
		local d = (cam.CFrame.Position - hrp.Position).Magnitude
		if d > 2 then
			dist = math.clamp(d, 8, 20)
		end
	end
	local back = -hrp.CFrame.LookVector * dist
	local camPos = hrp.Position + Vector3.new(0, 2, 0) + back
	local lookAt = hrp.Position + Vector3.new(0, 1.5, 0)
	return CFrame.lookAt(camPos, lookAt)
end

local function tweenCamToFollowHandoff(durationSec: number)
	local cam = Workspace.CurrentCamera
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (cam and hrp and hrp:IsA("BasePart") and hum) then
		finishCamToFollow()
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	local startCf = cam.CFrame
	local t0 = os.clock()
	while os.clock() - t0 < durationSec and player.Parent do
		local u = smoothstep((os.clock() - t0) / durationSec)
		local goal = followHandoffCFrame(hrp)
		cam.CFrame = startCf:Lerp(goal, u)
		playerGui:SetAttribute(ATTR_CAM_POS, cam.CFrame.Position)
		RunService.RenderStepped:Wait()
	end
	finishCamToFollow()
end

local function markSeen()
	pcall(function()
		markSeenRf:InvokeServer()
	end)
end

local function worldCFrameOf(inst: Instance): CFrame?
	if inst:IsA("BasePart") then
		return inst.CFrame
	end
	if inst:IsA("Model") then
		return (inst :: Model):GetPivot()
	end
	local part = inst:FindFirstChildWhichIsA("BasePart", true)
	return if part then part.CFrame else nil
end

local function findIntroElementChild(folder: Instance, name: string): Instance?
	local direct = folder:FindFirstChild(name)
	if direct then
		return direct
	end
	return folder:FindFirstChild(name, true)
end

export type IntroCamPose = {
	camStart: CFrame,
	camEnd: CFrame,
	focusStart: CFrame,
	focusEnd: CFrame,
	introPos: CFrame?,
}

local function waitIntroElements(timeoutSec: number): IntroCamPose?
	local deadline = os.clock() + timeoutSec
	local plots = Workspace:FindFirstChild("Plots")
	if not plots then
		plots = Workspace:WaitForChild("Plots", timeoutSec)
	end
	if not plots then
		return nil
	end
	local remain = math.max(0.05, deadline - os.clock())
	local folder = plots:FindFirstChild("IntroElements")
	if not folder then
		folder = plots:WaitForChild("IntroElements", remain)
	end
	if not folder then
		return nil
	end

	local function waitChild(name: string): Instance?
		local found = findIntroElementChild(folder, name)
		if found then
			return found
		end
		local left = deadline - os.clock()
		if left <= 0 then
			return nil
		end
		return folder:WaitForChild(name, left)
	end

	local camStartInst = waitChild("CamStart")
	local camEndInst = waitChild("CamEnd")
	local focusStartInst = waitChild("CamStartFocus")
	local focusEndInst = waitChild("CamEndFocus")
	local introPosInst = findIntroElementChild(folder, "IntroPosition") or waitChild("IntroPosition")

	local camStart = if camStartInst then worldCFrameOf(camStartInst) else nil
	local camEnd = if camEndInst then worldCFrameOf(camEndInst) else nil
	local focusStart = if focusStartInst then worldCFrameOf(focusStartInst) else nil
	local focusEnd = if focusEndInst then worldCFrameOf(focusEndInst) else nil
	local introPos = if introPosInst then worldCFrameOf(introPosInst) else nil
	if not camStart or not camEnd or not focusStart or not focusEnd then
		return nil
	end
	return {
		camStart = camStart,
		camEnd = camEnd,
		focusStart = focusStart,
		focusEnd = focusEnd,
		introPos = introPos,
	}
end

local function hideCharacterLocal(hidden: boolean)
	local char = player.Character
	if not char then
		return
	end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = if hidden then 1 else 0
		elseif d:IsA("Decal") then
			d.LocalTransparencyModifier = if hidden then 1 else 0
		end
	end
end

local function standAtCFrame(cf: CFrame, faceWorldPos: Vector3?)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (hrp and hrp:IsA("BasePart")) then
		return
	end
	local hip = if hum then math.max(2.5, hum.HipHeight + 1.5) else 3
	local pos = cf.Position + Vector3.new(0, hip, 0)
	local flatLook: Vector3
	if faceWorldPos then
		flatLook = Vector3.new(faceWorldPos.X - pos.X, 0, faceWorldPos.Z - pos.Z)
	else
		flatLook = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	end
	if flatLook.Magnitude < 1e-3 then
		flatLook = Vector3.new(0, 0, -1)
	else
		flatLook = flatLook.Unit
	end
	hrp.CFrame = CFrame.lookAt(pos, pos + flatLook, Vector3.yAxis)
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
end

local function standAtIntroFacingCam()
	if not introStandCf then
		return
	end
	local cam = Workspace.CurrentCamera
	standAtCFrame(introStandCf, if cam then cam.CFrame.Position else nil)
end

local function teleportToPlotSpawn()
	local plot = ClientPlot.get()
	local spawnCf = plot and plot.spawnCFrame
	if spawnCf then
		standAtCFrame(spawnCf)
	end
end

local function applyIntroCam(pos: Vector3, lookAt: Vector3)
	playerGui:SetAttribute(ATTR_CAM_POS, pos)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	if (lookAt - pos).Magnitude < 0.05 then
		cam.CFrame = CFrame.new(pos)
	else
		cam.CFrame = CFrame.lookAt(pos, lookAt)
	end
end

local earlyCamConn: RBXScriptConnection? = nil
local earlyCamStart: Vector3? = nil

local function stopEarlyCamHold()
	if earlyCamConn then
		earlyCamConn:Disconnect()
		earlyCamConn = nil
	end
end

local function peekIntroElementPos(name: string): Vector3?
	local plots = Workspace:FindFirstChild("Plots")
	local folder = plots and plots:FindFirstChild("IntroElements")
	local inst = folder and (folder:FindFirstChild(name) or folder:FindFirstChild(name, true))
	if not inst then
		return nil
	end
	local cf = worldCFrameOf(inst)
	return if cf then ClientPlot.remapCFrameFromPlot1(cf).Position else nil
end

-- Claim Scriptable cam + hide reef/avatar before SessionReady so join spawn isn't seen.
-- Loading buffer looks straight up at the sky from CamStart (when available).
local function beginEarlyIntroHold()
	playerGui:SetAttribute(ATTR_BUSY, true)
	playerGui:SetAttribute(ATTR_FORCE_CAM, "off")
	playerGui:SetAttribute("OceanTD_ForceCloseFreeCam", os.clock())
	startHudSuppress()
	-- Show the pill bar immediately — SessionReady / DataStore can take seconds on device.
	showEarlyLoadBar()
	bindFreeze(true)
	hideCharacterLocal(true)
	setOwnedPlotHidden(true)
	stopEarlyCamHold()
	earlyCamConn = RunService.RenderStepped:Connect(function()
		setOwnedPlotHidden(true)
		if introStandCf then
			standAtIntroFacingCam()
		end
		if not introAvatarShown then
			hideCharacterLocal(true)
		else
			hideCharacterLocal(false)
		end
		if not earlyCamStart then
			earlyCamStart = peekIntroElementPos("CamStart")
		end
		local pos = earlyCamStart
		if not pos then
			local cam = Workspace.CurrentCamera
			pos = if cam then cam.CFrame.Position else Vector3.new(0, 40, 0)
		end
		-- Straight up at the sky until the loading buffer finishes.
		applyIntroCam(pos, pos + Vector3.new(0, 200, 0))
	end)
	task.spawn(function()
		local root = Workspace:WaitForChild("OceanTD_Placed", 45)
		if not root then
			return
		end
		local function hideIfBusy(inst: Instance)
			if playerGui:GetAttribute(ATTR_BUSY) ~= true then
				return
			end
			if inst:IsA("BasePart") then
				inst.LocalTransparencyModifier = 1
			end
		end
		for _, d in ipairs(root:GetDescendants()) do
			hideIfBusy(d)
		end
		root.DescendantAdded:Connect(hideIfBusy)
	end)
end

local function notifyIntroComplete()
	pcall(function()
		Remotes.get("JoinIntroComplete"):FireServer()
	end)
end

local function restorePlotMirror(saved: ClientPlot.MirroredPlot)
	ClientPlot.set({
		plotId = saved.plotId,
		cframe = saved.cframe,
		size = saved.size,
		spawnCFrame = saved.spawnCFrame,
		plot1CFrame = saved.plot1CFrame,
		ringCFrame = saved.ringCFrame,
	})
	local realStage = SkillPowerUpUI.getStage("PlotSize")
	local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
	WaveEndVfx.syncToPlotSizeStage(realStage)
end

local function runIntro()
	if running then
		return
	end
	running = true
	skipRequested = false
	local finishedNotified = false
	local savedPlot: ClientPlot.MirroredPlot? = nil
	local realPlotSizeStage = 1
	local finished = false
	local function finishAndNotify()
		if finishedNotified then
			return
		end
		finishedNotified = true
		stopEarlyCamHold()
		notifyIntroComplete()
	end

	local function abortIntro()
		if finished then
			return
		end
		finished = true
		introAvatarShown = false
		introStandCf = nil
		stopEarlyCamHold()
		pcall(function()
			WaveSim.stopJoinIntroDemo()
		end)
		WaveSign.endJoinIntroDisplay()
		if savedPlot then
			restorePlotMirror(savedPlot)
			PlotSizeCinematic.applyStageLocal(realPlotSizeStage)
		end
		setOwnedPlotHidden(false)
		hideCharacterLocal(false)
		bindFreeze(false)
		ContextActionService:UnbindAction(SKIP_ACTION)
		for _, name in ipairs({ "OceanTD_JoinIntro", "OceanTD_JoinIntroLoad" }) do
			local leftover = playerGui:FindFirstChild(name)
			if leftover then
				leftover:Destroy()
			end
		end
		destroyEarlyLoadBar()
		restoreHud()
		finishCamToFollow()
		running = false
		finishAndNotify()
	end

	hideIntroTemplate()

	-- PlotAssigned (early, before DataStore) is enough for cam remap — don't wait SessionReady.
	if not ClientPlot.get() then
		local readyDeadline = os.clock() + 15
		while not ClientPlot.get() and os.clock() < readyDeadline do
			task.wait(0.05)
		end
	end
	local plot = ClientPlot.get()
	if not plot then
		abortIntro()
		return
	end
	savedPlot = {
		plotId = plot.plotId,
		cframe = plot.cframe,
		size = plot.size,
		spawnCFrame = plot.spawnCFrame,
		plot1CFrame = plot.plot1CFrame,
		ringCFrame = plot.ringCFrame,
	}
	realPlotSizeStage = SkillPowerUpUI.getStage("PlotSize")

	local function ensureIntroMaxPlotSize()
		if PlotSizeCinematic.applyStageLocal(SkillStages.MAX_STAGE) then
			return true
		end
		return false
	end

	local function waitWavePathReady(timeoutSec: number): boolean
		local deadline = os.clock() + timeoutSec
		while os.clock() < deadline and not finished do
			ensureIntroMaxPlotSize()
			if ClientPlot.get() and ClientPlot.getPlot1CFrame() then
				local root = Workspace:FindFirstChild("WaveRoute")
				local route = root and root:FindFirstChild("A")
				local wp = route and route:FindFirstChild("Waypoints")
				if wp and wp:FindFirstChild("W1") and wp:FindFirstChild("W2") then
					return true
				end
			end
			task.wait(0.1)
		end
		return false
	end

	-- ============================================================
	-- Serialized join intro (no parallel preload races):
	-- A) plot assign  B) Intro ready  C) clone  D) HungryFish+path
	-- E) pan  F) wave demo
	-- ============================================================

	-- (A) Plot assign — already waited above; force max footprint for showcase.
	ensureIntroMaxPlotSize()
	task.spawn(function()
		local deadline = os.clock() + 8
		while not finished and os.clock() < deadline do
			if ensureIntroMaxPlotSize() then
				return
			end
			task.wait(0.15)
		end
	end)
	WaveSign.beginJoinIntroDisplay(true)

	local token = { cancelled = false }
	local showcase: Folder? = nil
	local camConn: RBXScriptConnection? = nil
	local camState = { tweenDone = false, hold = true }
	local skipConns: { RBXScriptConnection } = {}
	local sg: ScreenGui? = nil
	local skipBtn: TextButton? = nil

	local function cleanupSkipUi()
		ContextActionService:UnbindAction(SKIP_ACTION)
		for _, c in ipairs(skipConns) do
			c:Disconnect()
		end
		table.clear(skipConns)
		if skipBtn and GuiService.SelectedObject == skipBtn then
			GuiService.SelectedObject = nil
		end
		if sg and sg.Parent then
			sg:Destroy()
		end
		sg = nil
		skipBtn = nil
		destroyEarlyLoadBar()
	end

	local function finishIntro(skipped: boolean)
		if finished then
			return
		end
		finished = true
		token.cancelled = true
		camState.tweenDone = true
		camState.hold = false
		introAvatarShown = false
		introStandCf = nil

		pcall(function()
			WaveSim.stopJoinIntroDemo()
		end)
		destroyFolder(showcase)
		WaveSign.endJoinIntroDisplay()
		if savedPlot then
			restorePlotMirror(savedPlot)
		end
		realPlotSizeStage = SkillPowerUpUI.getStage("PlotSize")
		PlotSizeCinematic.applyStageLocal(realPlotSizeStage)

		if not ClientPlot.isReady() then
			local hydrateDeadline = os.clock() + 20
			while not ClientPlot.isReady() and os.clock() < hydrateDeadline and player.Parent do
				task.wait(0.05)
			end
		end

		local owned = PlotLoadDropIn.gatherOwnedPlotParts()
		if skipped then
			for _, part in ipairs(owned) do
				PlotLoadDropIn.setPartHiddenLocal(part, false)
			end
		else
			for _, part in ipairs(owned) do
				PlotLoadDropIn.setPartHiddenLocal(part, true)
			end
			local span = if #owned >= 400 then 3 elseif #owned >= 80 then 2 else 1
			PlotLoadDropIn.play(#owned, span)
			task.wait(math.min(span + 0.5, 3.2))
		end

		-- Server owns the one spawn seat (JoinIntroComplete). Wait for it, fallback local snap.
		finishAndNotify()
		do
			local plotNow = ClientPlot.get()
			local spawnCf = plotNow and plotNow.spawnCFrame
			local deadline = os.clock() + 0.9
			local near = false
			while os.clock() < deadline and player.Parent do
				local char = player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				if spawnCf and hrp and hrp:IsA("BasePart") then
					local hip = if hum then math.max(2.5, hum.HipHeight + 1.5) else 3
					local target = spawnCf.Position + Vector3.new(0, hip, 0)
					if (hrp.Position - target).Magnitude < 16 then
						hrp.AssemblyLinearVelocity = Vector3.zero
						hrp.AssemblyAngularVelocity = Vector3.zero
						near = true
						break
					end
				end
				task.wait()
			end
			if not near then
				teleportToPlotSpawn()
			end
		end
		hideCharacterLocal(false)
		if camConn and camConn.Connected then
			camConn:Disconnect()
		end
		stopEarlyCamHold()
		tweenCamToFollowHandoff(if skipped then CAM_HANDOFF_SKIP_SEC else CAM_HANDOFF_SEC)
		bindFreeze(false)
		cleanupSkipUi()
		restoreHud()
		markSeen()
		running = false
		-- Player can walk — nudge them to roll for corals.
		playerGui:SetAttribute(ATTR_ROLL_FINGER, "roll")
		playerGui:SetAttribute("OceanTD_TutorialFreeUpgrade", true)
		-- Tutorial gates: waves unlock after first place; left HUD after first wave session ends.
		playerGui:SetAttribute("OceanTD_TutorialGateWaves", true)
		playerGui:SetAttribute("OceanTD_TutorialGateLeftHud", true)
		playerGui:SetAttribute("OceanTD_TutorialWavesSlotReady", false)
	end

	local function requestSkip()
		if skipRequested or finished then
			return
		end
		skipRequested = true
		task.spawn(function()
			finishIntro(true)
		end)
	end

	local payload: typeof(syncPayload) = nil
	local pose: IntroCamPose? = nil
	local showcaseParts: { BasePart } = {}
	local demoStarted = false

	-- (B) Intro package ready: sync + frozen package + cam markers.
	waitEarlyLoadBarMin()
	payload = waitForSync(12)
	if finished then
		return
	end
	if not payload then
		warn("[JoinIntro] JoinIntroSync missing — skip showcase")
		abortIntro()
		return
	end
	local introInst = waitJoinIntroPackage(45)
	if finished then
		return
	end
	if not introInst then
		warn("[JoinIntro] JoinIntroPackage / Plots.Intro missing — skip showcase")
		abortIntro()
		return
	end
	local poseResult = waitIntroElements(12)
	if finished then
		return
	end
	if not poseResult then
		warn("[JoinIntro] IntroElements missing — skip showcase")
		abortIntro()
		return
	end
	pose = poseResult
	if poseResult.introPos and ClientPlot.get() then
		introStandCf = ClientPlot.remapCFrameFromPlot1(poseResult.introPos)
		standAtIntroFacingCam()
	end
	-- Package is server-frozen; no client stream-stable wait needed.
	local partCount = countIntroParts(introInst)
	if partCount < 1 then
		warn("[JoinIntro] Intro package has 0 parts — showcase empty")
	end

	-- (C) Clone showcase from frozen package (blocking — no pan until done).
	local folder = Instance.new("Folder")
	folder.Name = "OceanTD_JoinIntroShowcase"
	folder.Parent = Workspace
	showcase = folder
	local sourceCf = payload.introSourceCFrame
	local function cloneRoot(root: Instance)
		local clone = root:Clone()
		sanitizeVisual(clone)
		if clone:IsA("Model") then
			local pivot = (root :: Model):GetPivot()
			;(clone :: Model):PivotTo(ClientPlot.remapCFrameFromSource(sourceCf, pivot))
		elseif clone:IsA("BasePart") then
			clone.CFrame = ClientPlot.remapCFrameFromSource(sourceCf, (root :: BasePart).CFrame)
		end
		clone.Parent = folder
		for _, part in ipairs(gatherParts(clone)) do
			part.LocalTransparencyModifier = 1
			table.insert(showcaseParts, part)
		end
	end
	local roots = collectIntroRoots(introInst)
	for i, root in ipairs(roots) do
		if token.cancelled or finished then
			break
		end
		cloneRoot(root)
		if i % CLONE_BATCH == 0 then
			RunService.Heartbeat:Wait()
		end
	end
	if finished then
		return
	end

	-- (D) HungryFish + wave path ready before any camera beat / demo.
	ensureIntroMaxPlotSize()
	if not waitHungryFishReady(8) then
		warn("[JoinIntro] HungryFish not ready in time")
	end
	if not waitWavePathReady(8) then
		warn("[JoinIntro] WaveRoute path not ready in time")
	end
	if finished then
		return
	end

	destroyEarlyLoadBar()
	WaveSign.beginJoinIntroDisplay(true)

	local camStart = ClientPlot.remapCFrameFromPlot1(pose.camStart).Position
	local camEnd = ClientPlot.remapCFrameFromPlot1(pose.camEnd).Position
	local focusStart = ClientPlot.remapCFrameFromPlot1(pose.focusStart).Position
	local focusEnd = ClientPlot.remapCFrameFromPlot1(pose.focusEnd).Position
	local introWorldCf = if pose.introPos then ClientPlot.remapCFrameFromPlot1(pose.introPos) else nil
	if introWorldCf then
		introStandCf = introWorldCf
		standAtIntroFacingCam()
	end

	for _, part in ipairs(showcaseParts) do
		if part.Parent then
			part.LocalTransparencyModifier = 0
		end
	end

	-- (E) Pan down.
	WaveSign.fadeInJoinIntroSign(1)
	introAvatarShown = true
	hideCharacterLocal(false)
	stopEarlyCamHold()
	playerGui:SetAttribute(ATTR_FORCE_CAM, "off")
	local skyLook = camStart + Vector3.new(0, 200, 0)
	applyIntroCam(camStart, skyLook)
	local panHoldConn = RunService.RenderStepped:Connect(function()
		standAtIntroFacingCam()
	end)
	local panT0 = os.clock()
	while os.clock() - panT0 < PAN_DOWN_SEC do
		if finished or token.cancelled then
			break
		end
		local u = smoothstep((os.clock() - panT0) / PAN_DOWN_SEC)
		applyIntroCam(camStart, skyLook:Lerp(focusStart, u))
		RunService.RenderStepped:Wait()
	end
	if panHoldConn.Connected then
		panHoldConn:Disconnect()
	end
	if finished then
		return
	end
	applyIntroCam(camStart, focusStart)
	if introWorldCf then
		introStandCf = introWorldCf
		standAtIntroFacingCam()
	end
	introAvatarShown = true
	hideCharacterLocal(false)

	local skipSg, skip = makeUi()
	sg = skipSg
	skipBtn = skip
	table.insert(skipConns, skip.Activated:Connect(requestSkip))
	table.insert(skipConns, skip.MouseButton1Click:Connect(requestSkip))
	GuiService.SelectedObject = skip
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

	local camT0 = os.clock()
	camState.tweenDone = false
	camState.hold = true
	camConn = RunService.RenderStepped:Connect(function()
		if not camState.hold then
			return
		end
		if introAvatarShown then
			standAtIntroFacingCam()
		end
		local u = if camState.tweenDone then 1 else smoothstep((os.clock() - camT0) / CAM_DOWN_SEC)
		if u >= 1 then
			camState.tweenDone = true
			u = 1
		end
		applyIntroCam(camStart:Lerp(camEnd, u), focusStart:Lerp(focusEnd, u))
	end)

	-- (F) Wave demo only after A–E prerequisites.
	if not demoStarted and not token.cancelled and #showcaseParts > 0 then
		ensureIntroMaxPlotSize()
		local okDemo = false
		for _ = 1, 5 do
			if finished or token.cancelled then
				break
			end
			okDemo = WaveSim.startJoinIntroDemo(showcaseParts, INTRO_WAVE)
			if okDemo then
				break
			end
			task.wait(0.35)
		end
		if okDemo then
			demoStarted = true
			WaveSign.beginJoinIntroDisplay(false)
		else
			warn("[JoinIntro] WaveSim demo failed to start after retries")
		end
	elseif #showcaseParts < 1 then
		warn("[JoinIntro] No showcase parts — skipping wave demo")
	end

	if finished then
		return
	end

	local waitUntil = os.clock() + CAM_DOWN_SEC
	while os.clock() < waitUntil and not token.cancelled and not finished do
		task.wait(0.05)
	end
	if finished then
		return
	end
	camState.tweenDone = true

	WaveSim.stopJoinIntroDemo()

	local fallWindow = 0
	if not token.cancelled and #showcaseParts > 0 then
		fallWindow = bleachAndFall(showcaseParts, token)
		task.spawn(function()
			PlotSizeCinematic.tweenStagesLocal(SkillStages.MAX_STAGE, realPlotSizeStage, {
				duration = BLEACH_TOTAL_MAX_SEC,
				cancelled = function()
					return token.cancelled or finished
				end,
			})
		end)
	elseif savedPlot then
		restorePlotMirror(savedPlot)
	end

	local bleachWait = os.clock() + math.max(fallWindow, BLEACH_WAIT_MIN_SEC)
	while os.clock() < bleachWait and not token.cancelled and not finished do
		task.wait(0.05)
	end
	if finished then
		return
	end

	finishIntro(false)
end

task.spawn(function()
	watchHideIntroTemplate()

	if not INTRO_ENABLED then
		destroyEarlyLoadBar()
		playerGui:SetAttribute(ATTR_BUSY, false)
		notifyIntroComplete()
		return
	end

	beginEarlyIntroHold()
	player.CharacterAdded:Connect(function()
		if playerGui:GetAttribute(ATTR_BUSY) ~= true then
			return
		end
		task.defer(function()
			bindFreeze(true)
			if introAvatarShown then
				if introStandCf then
					standAtIntroFacingCam()
				end
				hideCharacterLocal(false)
			else
				hideCharacterLocal(true)
			end
		end)
	end)

	-- Start as soon as the seat is assigned (fires before DataStore load on server).
	-- Waiting on SessionReady kept the full load bar up for 10–20s on device.
	local deadline = os.clock() + 20
	while not ClientPlot.get() and os.clock() < deadline do
		task.wait(0.05)
	end
	task.wait(0.05)
	local ok, err = pcall(runIntro)
	if not ok then
		warn("[JoinIntro] failed:", err)
		pcall(function()
			WaveSim.stopJoinIntroDemo()
		end)
		stopEarlyCamHold()
		destroyEarlyLoadBar()
		hideCharacterLocal(false)
		playerGui:SetAttribute(ATTR_BUSY, false)
		playerGui:SetAttribute(ATTR_CAM_POS, nil)
		bindFreeze(false)
		ContextActionService:UnbindAction(SKIP_ACTION)
		restoreHud()
		finishCamToFollow()
		running = false
		notifyIntroComplete()
	end
end)
