--!strict
--[[
	End-of-path VFX for WaveSim: reef heart loss + happy fish exit emoji.
	Extracted so WaveSim stays under Luau's 200-local register limit.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local WaveEndVfx = {}

-- While true, stage/plot sync must not snap the reef heart (Plot Size cinematic owns it).
local routeHeartDriveLocked = false

local REEF_TICK_SOUND_ID = "rbxassetid://128707491647978"
local REEF_TICK_PITCH_START = 1.2
local REEF_TICK_PITCH_STEP = 0.09
local REEF_TICK_PITCH_MIN = 0.45
local REEF_TICK_GAP = 0.07
local HEART_LOSS_MAX_STUDS = 100 * 1.4 -- happy exit base size
local HEART_LOSS_END_SCALE = 3 -- broken heart grows to 3× this max
local HEART_FALL_STUDS = 360
local HEART_FALL_SEC = 2.55
local HEART_LIGHT_RANGE = 50
local HEART_LIGHT_BRIGHTNESS = 0.9
local HEART_GUI_ORDER = 2600 -- above happy-exit billboards
local HAPPY_EXIT_SEC = 1.4
local HAPPY_EXIT_START_SCALE = 0.06 -- tiny at the heart; grows to 1× at the player
local HAPPY_EXIT_FAN_STUDS = 18 -- lateral spread at arrival
local HAPPY_EXIT_SOUND_ID = "rbxassetid://138571475125488"
local HAPPY_EXIT_PITCH_MIN = 0.82
local HAPPY_EXIT_PITCH_MAX = 1.28
-- Finish firework (endpoint burst)
local FIREWORK_SIZE_MIN = 15
local FIREWORK_SIZE_MAX = 33
local FIREWORK_START_SCALE = 0.08
local FIREWORK_SPEED_MIN = 28
local FIREWORK_SPEED_MAX = 62
local FIREWORK_GRAV_MIN = 38
local FIREWORK_GRAV_MAX = 72
local FIREWORK_LIFE_MIN = 1.05
local FIREWORK_LIFE_MAX = 1.75
local END_HEART_RED = Color3.fromRGB(255, 40, 55)
local END_HEART_BLACK = Color3.new(0, 0, 0)
local UNDERFED_HIDE_SEC = 0.25

local reefTickSound = Instance.new("Sound")
reefTickSound.Name = "OceanTD_ReefTick"
reefTickSound.SoundId = REEF_TICK_SOUND_ID
reefTickSound.Volume = 0.95
reefTickSound.Parent = SoundService

local happyExitSound = Instance.new("Sound")
happyExitSound.Name = "OceanTD_HappyExit"
happyExitSound.SoundId = HAPPY_EXIT_SOUND_ID
happyExitSound.Volume = 0.9
happyExitSound.Parent = SoundService

task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ reefTickSound, happyExitSound })
	end)
end)

local getFolder: (() -> Folder)? = nil
local endHeartPart: BasePart? = nil
local endHeartPlotId: string? = nil
local endHeartAnimToken = 0
local heartHideToken = 0
local heartHideUntil = 0
local reefTickStreak = 0
local rng = Random.new()

-- Authored EndPoint sits at W8; plot-size routes end earlier — show a local heart at route end.
local routeEndPosByPlot: { [string]: Vector3 } = {}
local routeHeartCloneByPlot: { [string]: Instance } = {} -- EndPoint clone (or heart part)
local hiddenSourceRootByPlot: { [string]: Instance } = {}

function WaveEndVfx.bind(folderFn: () -> Folder)
	getFolder = folderFn
end

function WaveEndVfx.resetStreak()
	reefTickStreak = 0
	heartHideToken += 1
	heartHideUntil = 0
	local heart = endHeartPart
	if heart and heart.Parent then
		heart.LocalTransparencyModifier = 0
		heart.Color = END_HEART_RED
	end
end

local function resolveFolder(): Folder
	if getFolder then
		return getFolder()
	end
	local existing = Workspace:FindFirstChild("OceanTD_LocalWaves")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = "OceanTD_LocalWaves"
	f.Parent = Workspace
	return f
end

local function findAuthoredEndPoint(): Instance?
	local route = Workspace:FindFirstChild("WaveRoute")
	local a = route and route:FindFirstChild("A")
	return a and a:FindFirstChild("EndPoint")
end

local function findHeartIn(root: Instance?): BasePart?
	if not root then
		return nil
	end
	local heart = root:FindFirstChild("heart", true)
	if heart and heart:IsA("BasePart") then
		return heart
	end
	-- Fallback: any BasePart under EndPoint
	if root:IsA("BasePart") then
		return root
	end
	return root:FindFirstChildWhichIsA("BasePart", true)
end

-- Server replicates EndPoint to Workspace.OceanTD_PlotHearts.PlotN (N>=2).
-- Plot1 uses authored WaveRoute.A.EndPoint.
local function findPlotEndHeartRoot(plotId: string): Instance?
	if plotId == "Plot1" then
		return findAuthoredEndPoint()
	end
	local folder = Workspace:FindFirstChild("OceanTD_PlotHearts")
	if not folder then
		return nil
	end
	return folder:FindFirstChild(plotId)
end

local heartByPlotId: { [string]: BasePart } = {}

local function setTreeLocalHidden(root: Instance, hidden: boolean)
	local mod = if hidden then 1 else 0
	if root:IsA("BasePart") then
		root.LocalTransparencyModifier = mod
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = mod
		end
	end
end

local function destroyRouteHeartClone(plotId: string)
	local clone = routeHeartCloneByPlot[plotId]
	if clone then
		clone:Destroy()
		routeHeartCloneByPlot[plotId] = nil
	end
	local src = hiddenSourceRootByPlot[plotId]
	if src and src.Parent then
		setTreeLocalHidden(src, false)
	end
	hiddenSourceRootByPlot[plotId] = nil
end

local function prepareLocalHeartClone(inst: Instance)
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			d.LocalTransparencyModifier = 0
		elseif d:IsA("WeldConstraint") or d:IsA("Weld") or d:IsA("Motor6D") then
			d:Destroy()
		end
	end
	if inst:IsA("BasePart") then
		inst.Anchored = true
		inst.CanCollide = false
		inst.CanQuery = false
		inst.CanTouch = false
		inst.CastShadow = false
		inst.LocalTransparencyModifier = 0
	end
end

local function pivotOf(inst: Instance): CFrame
	if inst:IsA("Model") then
		return inst:GetPivot()
	end
	if inst:IsA("BasePart") then
		return inst.CFrame
	end
	local p = inst:FindFirstChildWhichIsA("BasePart", true)
	return if p then p.CFrame else CFrame.new()
end

local function setPivot(inst: Instance, cf: CFrame)
	if inst:IsA("Model") then
		inst:PivotTo(cf)
	elseif inst:IsA("BasePart") then
		inst.CFrame = cf
	else
		local heart = findHeartIn(inst)
		if heart then
			local delta = cf * pivotOf(inst):Inverse()
			for _, d in ipairs(inst:GetDescendants()) do
				if d:IsA("BasePart") then
					d.CFrame = delta * d.CFrame
				end
			end
		end
	end
end

local function resolveSourceHeart(plotId: string): (Instance?, BasePart?)
	local root = findPlotEndHeartRoot(plotId)
	local heart = findHeartIn(root)
	if heart then
		heartByPlotId[plotId] = heart
	else
		heartByPlotId[plotId] = nil
	end
	return root, heart
end

local function applyRouteHeartForPlot(plotId: string): BasePart?
	local routeEnd = routeEndPosByPlot[plotId]
	local sourceRoot, sourceHeart = resolveSourceHeart(plotId)
	if not sourceHeart then
		destroyRouteHeartClone(plotId)
		return nil
	end

	-- No override → show authored heart in place.
	if not routeEnd then
		destroyRouteHeartClone(plotId)
		endHeartPart = sourceHeart
		endHeartPlotId = plotId
		return sourceHeart
	end

	-- Hide authored EndPoint locally; show clone at the fish stop.
	if sourceRoot then
		setTreeLocalHidden(sourceRoot, true)
		hiddenSourceRootByPlot[plotId] = sourceRoot
	end

	local clone = routeHeartCloneByPlot[plotId]
	if not clone or not clone.Parent then
		local template = sourceRoot or sourceHeart
		clone = template:Clone()
		clone.Name = "OceanTD_RouteHeart_" .. plotId
		prepareLocalHeartClone(clone)
		clone.Parent = resolveFolder()
		routeHeartCloneByPlot[plotId] = clone
	end

	local cloneHeart = findHeartIn(clone) or (clone:IsA("BasePart") and clone or nil)
	if not cloneHeart or not cloneHeart:IsA("BasePart") then
		destroyRouteHeartClone(plotId)
		endHeartPart = sourceHeart
		endHeartPlotId = plotId
		return sourceHeart
	end

	-- Translate whole EndPoint so the heart mesh sits on the route end.
	local delta = routeEnd - cloneHeart.Position
	setPivot(clone, CFrame.new(delta) * pivotOf(clone))

	cloneHeart.Color = END_HEART_RED
	cloneHeart.LocalTransparencyModifier = 0
	endHeartPart = cloneHeart
	endHeartPlotId = plotId
	heartByPlotId[plotId] = cloneHeart
	return cloneHeart
end

local function resolveEndHeartForPlot(plotId: string): BasePart?
	local cached = heartByPlotId[plotId]
	if cached and cached.Parent and routeEndPosByPlot[plotId] then
		-- Prefer live route clone when we have a route end.
		local clone = routeHeartCloneByPlot[plotId]
		if clone and clone.Parent then
			local h = findHeartIn(clone)
			if h then
				endHeartPart = h
				endHeartPlotId = plotId
				return h
			end
		end
	end
	return applyRouteHeartForPlot(plotId)
end

local function waypointWorldForStage(stage: number, plotId: string): Vector3?
	local s = SkillStages.clampStage(stage)
	local finalWp = SkillStages.plotSizeFinalWaypoint(s)
	local route = Workspace:FindFirstChild("WaveRoute")
	local a = route and route:FindFirstChild("A")
	local wpFolder = a and a:FindFirstChild("Waypoints")
	if not wpFolder then
		return nil
	end
	local w: Instance? = wpFolder:FindFirstChild("W" .. tostring(finalWp))
	if not (w and w:IsA("BasePart")) then
		for _, ch in ipairs(wpFolder:GetDescendants()) do
			if ch:IsA("BasePart") and ch.Name == "W" .. tostring(finalWp) then
				w = ch
				break
			end
		end
	end
	if not (w and w:IsA("BasePart")) then
		return nil
	end
	local plot = ClientPlot.get()
	if plotId == "Plot1" or (plot and plot.plotId == plotId) then
		return ClientPlot.remapFromPlot1((w :: BasePart).Position)
	end
	return nil
end

-- Place the visible reef heart at the wave path end (plot-size waypoint).
function WaveEndVfx.setRouteHeartDriveLocked(locked: boolean)
	routeHeartDriveLocked = locked == true
end

function WaveEndVfx.isRouteHeartDriveLocked(): boolean
	return routeHeartDriveLocked
end

function WaveEndVfx.setRouteEndWorldPos(worldPos: Vector3?, plotId: string?)
	local plot = ClientPlot.get()
	local id = plotId or (if plot then plot.plotId else "Plot1")
	if worldPos then
		routeEndPosByPlot[id] = worldPos
	else
		routeEndPosByPlot[id] = nil
	end
	applyRouteHeartForPlot(id)
end

function WaveEndVfx.getRouteEndWorldPosForStage(stage: number, plotId: string?): Vector3?
	local plot = ClientPlot.get()
	local id = plotId or (if plot then plot.plotId else nil)
	if not id then
		return nil
	end
	return waypointWorldForStage(stage, id)
end

function WaveEndVfx.clearRouteEnd(plotId: string?)
	local plot = ClientPlot.get()
	local id = plotId or (if plot then plot.plotId else nil)
	if not id then
		return
	end
	routeEndPosByPlot[id] = nil
	destroyRouteHeartClone(id)
	applyRouteHeartForPlot(id)
end

-- Place heart at W# for this Plot Size stage (works even when waves aren't running).
function WaveEndVfx.syncToPlotSizeStage(stage: number?, plotId: string?)
	if routeHeartDriveLocked then
		return
	end
	local plot = ClientPlot.get()
	local id = plotId or (if plot then plot.plotId else nil)
	if not id then
		return
	end
	local s = if stage ~= nil then SkillStages.clampStage(stage) else nil
	if s == nil then
		local ok, SkillPowerUpUI = pcall(function()
			return require(script.Parent:WaitForChild("SkillPowerUpUI"))
		end)
		if ok and SkillPowerUpUI and typeof(SkillPowerUpUI.getStage) == "function" then
			s = SkillPowerUpUI.getStage("PlotSize")
		else
			s = 1
		end
	end
	local worldPos = waypointWorldForStage(s :: number, id)
	if not worldPos then
		return
	end
	WaveEndVfx.setRouteEndWorldPos(worldPos, id)
end

function WaveEndVfx.getEndHeartPart(): BasePart?
	local plot = ClientPlot.get()
	local plotId = if plot then plot.plotId else "Plot1"
	return resolveEndHeartForPlot(plotId)
end

function WaveEndVfx.getEndHeartPartForPlot(plotId: string): BasePart?
	return resolveEndHeartForPlot(plotId)
end

function WaveEndVfx.getEndHeartWorldPos(): Vector3?
	local plot = ClientPlot.get()
	local plotId = if plot then plot.plotId else "Plot1"
	local routed = routeEndPosByPlot[plotId]
	if routed then
		return routed
	end
	local heart = WaveEndVfx.getEndHeartPart()
	if heart then
		return heart.Position
	end
	-- Fallback remap if server hearts not ready yet
	local authored = findHeartIn(findAuthoredEndPoint())
	if authored then
		return ClientPlot.remapFromPlot1(authored.Position)
	end
	return nil
end

function WaveEndVfx.getEndHeartWorldPosForPlot(plotId: string): Vector3?
	local routed = routeEndPosByPlot[plotId]
	if routed then
		return routed
	end
	local heart = resolveEndHeartForPlot(plotId)
	if heart then
		return heart.Position
	end
	local authored = findHeartIn(findAuthoredEndPoint())
	if authored and plotId ~= "Plot1" then
		-- Soft fallback until OceanTD_PlotHearts replicates
		local plot = ClientPlot.get()
		if plot and plot.plotId == plotId then
			return ClientPlot.remapFromPlot1(authored.Position)
		end
	end
	return nil
end

function WaveEndVfx.refreshLocalEndHeart()
	table.clear(heartByPlotId)
	endHeartPart = nil
	endHeartPlotId = nil
	local plot = ClientPlot.get()
	if not plot then
		return
	end
	-- Keep route-end overrides; re-apply clone against the current source heart.
	if plot.plotId == "Plot1" then
		resolveEndHeartForPlot("Plot1")
		return
	end
	local heart = resolveEndHeartForPlot(plot.plotId)
	if heart then
		return
	end
	task.spawn(function()
		local folder = Workspace:WaitForChild("OceanTD_PlotHearts", 10)
		if folder then
			folder:WaitForChild(plot.plotId, 5)
		end
		heartByPlotId[plot.plotId] = nil
		endHeartPart = nil
		endHeartPlotId = nil
		resolveEndHeartForPlot(plot.plotId)
	end)
end

local function setEndHeartHidden(heart: BasePart, hidden: boolean)
	heart.LocalTransparencyModifier = if hidden then 1 else 0
end

-- Underfed fish hit the end: hide mesh 0.25s.
function WaveEndVfx.notifyUnderfedArrival()
	local heart = WaveEndVfx.getEndHeartPart()
	if not heart then
		return
	end
	heartHideToken += 1
	local myHide = heartHideToken
	heartHideUntil = os.clock() + UNDERFED_HIDE_SEC
	setEndHeartHidden(heart, true)
	task.delay(UNDERFED_HIDE_SEC, function()
		if myHide ~= heartHideToken or os.clock() < heartHideUntil then
			return
		end
		if heart.Parent then
			setEndHeartHidden(heart, false)
		end
	end)
end

local function pulseReefHeartLoss(at: Vector3, tintHeart: boolean?)
	local folder = resolveFolder()
	local startPos = at + Vector3.new(0, 2, 0)
	local anchor = Instance.new("Part")
	anchor.Name = "OceanTD_HeartLoss"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(startPos)
	anchor.Parent = folder

	-- ScreenGui so broken hearts draw above happy-exit world billboards.
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_HeartLossGui"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = HEART_GUI_ORDER
	sg.Parent = playerGui or folder

	local holder = Instance.new("Frame")
	holder.Name = "Heart"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(8, 8)
	holder.Parent = sg

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = holder

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = Enum.Font.SourceSansBold
	lbl.Text = "💔"
	lbl.TextColor3 = Color3.fromRGB(255, 35, 55)
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.35
	lbl.TextStrokeColor3 = Color3.fromRGB(80, 0, 10)
	lbl.Parent = holder

	-- Local plot heart (Plot1 authored, or remapped clone on Plot2+).
	local worldHeart = if tintHeart ~= false then WaveEndVfx.getEndHeartPart() else nil
	endHeartAnimToken += 1
	local myHeartToken = endHeartAnimToken
	if worldHeart then
		worldHeart.Color = END_HEART_RED
	end

	local lightHost = worldHeart or anchor
	local light = Instance.new("PointLight")
	light.Name = "OceanTD_HeartLossLight"
	light.Color = END_HEART_RED
	light.Brightness = HEART_LIGHT_BRIGHTNESS
	light.Range = HEART_LIGHT_RANGE
	light.Shadows = false
	light.Parent = lightHost

	local function studsToPx(worldPos: Vector3, studs: number): number
		local cam = Workspace.CurrentCamera
		if not cam then
			return studs * 2
		end
		local dist = math.max(1, (cam.CFrame.Position - worldPos).Magnitude)
		local halfFov = math.rad(cam.FieldOfView) * 0.5
		local vp = cam.ViewportSize
		return studs / dist * (vp.Y * 0.5) / math.tan(halfFov)
	end

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local u = math.clamp((os.clock() - t0) / HEART_FALL_SEC, 0, 1)
		local ease = u * u
		local worldPos = startPos - Vector3.new(0, HEART_FALL_STUDS * ease, 0)
		anchor.CFrame = CFrame.new(worldPos)

		local cam = Workspace.CurrentCamera
		if cam then
			local sp, onScreen = cam:WorldToViewportPoint(worldPos)
			holder.Visible = onScreen and sp.Z > 0
			holder.Position = UDim2.fromOffset(sp.X, sp.Y)
			local px = studsToPx(worldPos, HEART_LOSS_MAX_STUDS)
			holder.Size = UDim2.fromOffset(math.max(8, px), math.max(8, px))
		end
		scale.Scale = 1 + (HEART_LOSS_END_SCALE - 1) * ease
		lbl.TextTransparency = u
		lbl.TextStrokeTransparency = 0.35 + 0.65 * u
		light.Brightness = HEART_LIGHT_BRIGHTNESS * (1 - u)
		if worldHeart and myHeartToken == endHeartAnimToken then
			worldHeart.Color = END_HEART_RED:Lerp(END_HEART_BLACK, u)
		end
		if u >= 1 then
			conn:Disconnect()
			if light.Parent then
				light:Destroy()
			end
			if sg.Parent then
				sg:Destroy()
			end
			if anchor.Parent then
				anchor:Destroy()
			end
			if worldHeart and worldHeart.Parent and myHeartToken == endHeartAnimToken then
				worldHeart.Color = END_HEART_RED
			end
		end
	end)
end

local function playHappyExitSound()
	local pitch = rng:NextNumber(HAPPY_EXIT_PITCH_MIN, HAPPY_EXIT_PITCH_MAX)
	local snd = happyExitSound:Clone()
	snd.PlaybackSpeed = pitch
	snd.Volume = 0.9
	snd.Parent = SoundService
	snd:Play()
	local ttl = math.max(0.8, (snd.TimeLength > 0 and snd.TimeLength or 0.5) / math.max(0.2, pitch) + 0.25)
	task.delay(ttl, function()
		if snd.Parent then
			snd:Destroy()
		end
	end)
end

local function characterAimPos(fallback: Vector3): Vector3
	local char = Players.LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position + Vector3.new(0, 1.5, 0)
	end
	return fallback
end

function WaveEndVfx.pulseHappyExit(emoji: string, at: Vector3)
	playHappyExitSound()

	local folder = resolveFolder()
	local startPos = at + Vector3.new(0, 2, 0)
	-- Random lateral/vertical fan so simultaneous exits don't stack.
	local fanYaw = rng:NextNumber(0, math.pi * 2)
	local fanReach = rng:NextNumber(HAPPY_EXIT_FAN_STUDS * 0.45, HAPPY_EXIT_FAN_STUDS)
	local fanSide = Vector3.new(math.cos(fanYaw), 0, math.sin(fanYaw)) * fanReach
	local fanUp = Vector3.new(0, rng:NextNumber(-6, 10), 0)

	local anchor = Instance.new("Part")
	anchor.Name = "OceanTD_HappyExit"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(startPos)
	anchor.Parent = folder

	local bb = Instance.new("BillboardGui")
	bb.Name = "HappyFace"
	bb.Adornee = anchor
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 2000
	local startStuds = HEART_LOSS_MAX_STUDS * HAPPY_EXIT_START_SCALE
	bb.Size = UDim2.fromScale(startStuds, startStuds)
	bb.Parent = anchor

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = Enum.Font.SourceSansBold
	lbl.Text = emoji
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.4
	lbl.TextStrokeColor3 = Color3.fromRGB(20, 40, 10)
	lbl.Parent = bb

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local u = math.clamp((os.clock() - t0) / HAPPY_EXIT_SEC, 0, 1)
		local ease = 1 - (1 - u) * (1 - u)
		local goal = characterAimPos(startPos) + fanSide + fanUp
		local pos = startPos:Lerp(goal, ease)
		anchor.CFrame = CFrame.new(pos)
		-- Grow with remaining distance to the player (not just elapsed time).
		local startDist = (startPos - goal).Magnitude
		local dist = (pos - goal).Magnitude
		local approach = if startDist > 1 then 1 - math.clamp(dist / startDist, 0, 1) else ease
		local grow = approach * approach
		local studs = HEART_LOSS_MAX_STUDS * (HAPPY_EXIT_START_SCALE + (1 - HAPPY_EXIT_START_SCALE) * grow)
		bb.Size = UDim2.fromScale(studs, studs)
		lbl.TextTransparency = u
		lbl.TextStrokeTransparency = 0.4 + 0.6 * u
		if u >= 1 then
			conn:Disconnect()
			if anchor.Parent then
				anchor:Destroy()
			end
		end
	end)
end

-- Finish-button burst: tiny sparks that explode outward from the endpoint and arc down.
function WaveEndVfx.burstHappyFirework(emojis: { string }, at: Vector3)
	if #emojis == 0 then
		return
	end
	playHappyExitSound()

	local folder = resolveFolder()
	local origin = at + Vector3.new(0, 2.5, 0)
	local count = math.clamp(#emojis * 2, 14, 36)

	for i = 1, count do
		local emoji = emojis[((i - 1) % #emojis) + 1]
		local delaySec = rng:NextNumber(0, 0.08)
		task.delay(delaySec, function()
			local anchor = Instance.new("Part")
			anchor.Name = "OceanTD_HappyFirework"
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.CanQuery = false
			anchor.CanTouch = false
			anchor.CastShadow = false
			anchor.Transparency = 1
			anchor.Size = Vector3.new(0.4, 0.4, 0.4)
			anchor.CFrame = CFrame.new(origin)
			anchor.Parent = folder

			local sizeStuds = rng:NextNumber(FIREWORK_SIZE_MIN, FIREWORK_SIZE_MAX)
			local bb = Instance.new("BillboardGui")
			bb.Name = "HappySpark"
			bb.Adornee = anchor
			bb.AlwaysOnTop = true
			bb.LightInfluence = 0
			bb.MaxDistance = 2000
			bb.Size = UDim2.fromScale(sizeStuds, sizeStuds)
			bb.Parent = anchor

			local scale = Instance.new("UIScale")
			scale.Scale = FIREWORK_START_SCALE
			scale.Parent = bb

			local lbl = Instance.new("TextLabel")
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.Font = Enum.Font.SourceSansBold
			lbl.Text = emoji
			lbl.TextScaled = true
			lbl.TextStrokeTransparency = 0.45
			lbl.TextStrokeColor3 = Color3.fromRGB(20, 40, 10)
			lbl.Parent = bb

			-- Full sphere with a slight upward bias so arcs read as fireworks.
			local yaw = rng:NextNumber(0, math.pi * 2)
			local pitch = rng:NextNumber(-0.35, 1.15) -- more up than down at launch
			local dir = Vector3.new(
				math.cos(yaw) * math.cos(pitch),
				math.sin(pitch),
				math.sin(yaw) * math.cos(pitch)
			).Unit
			local speed = rng:NextNumber(FIREWORK_SPEED_MIN, FIREWORK_SPEED_MAX)
			local vel = dir * speed
			local grav = rng:NextNumber(FIREWORK_GRAV_MIN, FIREWORK_GRAV_MAX)
			local life = rng:NextNumber(FIREWORK_LIFE_MIN, FIREWORK_LIFE_MAX)
			local peakScale = rng:NextNumber(0.85, 1.45)
			local popAt = rng:NextNumber(0.1, 0.22)
			local pos = origin
			local t0 = os.clock()
			local conn: RBXScriptConnection
			conn = RunService.RenderStepped:Connect(function(dt)
				local age = os.clock() - t0
				if age >= life then
					conn:Disconnect()
					if anchor.Parent then
						anchor:Destroy()
					end
					return
				end
				vel += Vector3.new(0, -grav, 0) * dt
				-- Light air drag so they don't fly forever.
				vel *= (1 - 0.35 * dt)
				pos += vel * dt
				anchor.CFrame = CFrame.new(pos)

				if age < popAt then
					scale.Scale = FIREWORK_START_SCALE
						+ (peakScale - FIREWORK_START_SCALE) * (age / popAt)
				else
					local fadeU = math.clamp((age - popAt) / math.max(0.05, life - popAt), 0, 1)
					scale.Scale = peakScale * (1 - 0.35 * fadeU)
				end
				local fade = math.clamp((age - life * 0.55) / (life * 0.45), 0, 1)
				lbl.TextTransparency = fade
				lbl.TextStrokeTransparency = 0.45 + 0.55 * fade
			end)
		end)
	end
end

function WaveEndVfx.playReefHealthTicks(amount: number, endPos: Vector3?, tintHeart: boolean?)
	if amount <= 0 then
		return
	end
	local at = endPos
	if not at then
		at = WaveEndVfx.getEndHeartWorldPos()
	end
	for i = 1, amount do
		local pitch = math.max(REEF_TICK_PITCH_MIN, REEF_TICK_PITCH_START - reefTickStreak * REEF_TICK_PITCH_STEP)
		reefTickStreak += 1
		local delaySec = (i - 1) * REEF_TICK_GAP
		task.delay(delaySec, function()
			local snd = reefTickSound:Clone()
			snd.PlaybackSpeed = pitch
			snd.Volume = 0.95
			snd.Parent = SoundService
			snd:Play()
			local ttl = math.max(1.2, (snd.TimeLength > 0 and snd.TimeLength or 1) + 0.4)
			task.delay(ttl, function()
				if snd.Parent then
					snd:Destroy()
				end
			end)
			if at then
				pulseReefHeartLoss(at, tintHeart)
			end
		end)
	end
end

ClientPlot.onChanged(function(plot)
	-- Plot Size grow updates ClientPlot every frame; don't tear down / re-snap the heart.
	if routeHeartDriveLocked then
		return
	end
	table.clear(heartByPlotId)
	endHeartPart = nil
	endHeartPlotId = nil
	if plot then
		-- Drop stale clones; caller / sync will re-place at the plot-size end.
		for id in pairs(routeHeartCloneByPlot) do
			destroyRouteHeartClone(id)
		end
		WaveEndVfx.refreshLocalEndHeart()
		WaveEndVfx.syncToPlotSizeStage(nil, plot.plotId)
	end
end)

task.defer(function()
	if ClientPlot.get() then
		WaveEndVfx.refreshLocalEndHeart()
		WaveEndVfx.syncToPlotSizeStage()
	end
end)

return WaveEndVfx
