--!strict
--[[
	Visitor spectate sim on a foreign plot.
	Look/feel matches solo WaveSim (Tang, hunger bars, green arrows, Wave N, stagger)
	but food is progress-driven pops (no targeting). Sparse host sync keeps it honest.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local CoralSize = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralSize"))
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local WaveEntityPool = require(script.Parent:WaitForChild("WaveEntityPool"))
local WaveCrab = require(script.Parent:WaitForChild("WaveCrab"))
local WaveUrchin = require(script.Parent:WaitForChild("WaveUrchin"))
local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
local WaveStartVfx = require(script.Parent:WaitForChild("WaveStartVfx"))
local C = require(script.Parent:WaitForChild("WaveSimConsts"))
local WaveWatchMode = require(script.Parent:WaitForChild("WaveWatchMode"))

local WaveGhostSim = {}

type PathSeg = {
	w0: Vector3,
	c: Vector3,
	w1: Vector3,
	length: number,
	cumStart: number,
}

type PathData = {
	segments: { PathSeg },
	totalLen: number,
	endPos: Vector3,
}

type GhostFish = {
	id: number,
	root: BasePart,
	model: Instance,
	dist: number,
	lateral: number,
	vert: number,
	bobAmp: number,
	bobFreq: number,
	bobPhase: number,
	wanderAmp: number,
	wanderFreq: number,
	wanderPhase: number,
	speedPhase: number,
	speedFreq: number,
	hunger: number,
	maxHunger: number,
	finished: boolean,
	billboard: BillboardGui?,
	fill: Frame?,
	forkLabel: TextLabel?,
	happyLabel: TextLabel?,
	remainLabel: TextLabel?,
	barStroke: UIStroke?,
	smoothTang: Vector3,
	lastWorld: Vector3,
	isCrab: boolean?,
	isUrchin: boolean?,
	crabAnim: any?,
	shellHitbox: BasePart?,
	shellLocalCf: CFrame?,
	bodyLocalCf: CFrame?,
	pauseUntil: number?,
	pauseDur: number?,
	stunSkullPart: BasePart?,
	crabSprint: any?,
}

type ArrowPreview = { model: Instance, dist: number, spin: number, alive: boolean }
type WaveLabel = { part: BasePart, dist: number, alive: boolean }

local LOD_NEAR = 220
local LOD_FAR = 480

local folder: Folder? = nil
local pathData: PathData? = nil
local pathDataGround: WaveCrab.PathData? = nil
local fishList: { GhostFish } = {}
local arrowPreviews: { ArrowPreview } = {}
local wavePathLabels: { WaveLabel } = {}
local moveConn: RBXScriptConnection? = nil
local activePlotId: string? = nil
local activePlotCf: CFrame? = nil
local speedMult = 1
local waveIndex = 0
local lastFeed = 0
local lastMiss = 0
local lastReef = -1
local lastCoralEpoch = -1
local fading = false
local rng = Random.new()
local simClock = 0
local nextFishId = 1
local greenArrowsTemplate: Instance? = nil
local coralCache: { Vector3 } = {}
local coralParts: { BasePart } = {}
local stunnedCorals: { [BasePart]: boolean } = {}
local coralCachePlot: string? = nil
local coralDirty = true

-- Stagger spawn (full wave start)
local spawnQueue = 0
local spawnDelay = 0
local crabSpawnQueue = 0
local crabSpawnDelay = 0
local urchinSpawnQueue = 0
local urchinSpawnDelay = 0
local waveSpawning = false
local waveFishExpected = 0
local waveCrabExpected = 0
local waveUrchinExpected = 0
local startedThisWave = false -- true after arrows+stagger begun for current waveIndex

local function isGroundCritter(f: GhostFish): boolean
	return f.isCrab == true or f.isUrchin == true
end

local lodFar = false
local lodTickSkip = false

local feedSound = Instance.new("Sound")
feedSound.Name = "OceanTD_GhostFeed"
feedSound.SoundId = C.FEED_SOUND_ID
feedSound.Volume = 0.85
feedSound.Parent = SoundService

local arrowSound = Instance.new("Sound")
arrowSound.Name = "OceanTD_GhostArrow"
arrowSound.SoundId = C.ARROW_SOUND_ID
arrowSound.Volume = 0.9
arrowSound.Parent = SoundService

task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ feedSound, arrowSound })
	end)
end)

local function ensureFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "OceanTD_GhostWaves"
	f.Parent = Workspace
	folder = f
	return f
end

local function clearFish()
	for _, f in ipairs(fishList) do
		if f.isCrab then
			WaveCrab.resetAnim(f.crabAnim)
			WaveEntityPool.releaseFish(WaveEntityPool.FISH_CRAB, f.model)
		elseif f.isUrchin then
			WaveEntityPool.releaseFish(WaveEntityPool.FISH_URCHIN, f.model)
		else
			WaveEntityPool.releaseFish(WaveEntityPool.FISH_TANG, f.model)
		end
	end
	table.clear(fishList)
end

local function destroyArrowPreview()
	for _, preview in ipairs(arrowPreviews) do
		WaveEntityPool.releaseArrows(preview.model)
	end
	table.clear(arrowPreviews)
	for _, label in ipairs(wavePathLabels) do
		if label.part.Parent then
			label.part:Destroy()
		end
	end
	table.clear(wavePathLabels)
end

local function findIndexedPart(folderInst: Instance, prefix: string, index: number): BasePart?
	local inst = folderInst:FindFirstChild(prefix .. tostring(index))
	if inst and inst:IsA("BasePart") then
		return inst
	end
	return nil
end

local function quadBezier(w0: Vector3, c: Vector3, w1: Vector3, t: number): Vector3
	local u = 1 - t
	return w0 * (u * u) + c * (2 * u * t) + w1 * (t * t)
end

local function quadBezierTangent(w0: Vector3, c: Vector3, w1: Vector3, t: number): Vector3
	local d = 2 * (1 - t) * (c - w0) + 2 * t * (w1 - c)
	if d.Magnitude < 1e-5 then
		return w1 - w0
	end
	return d
end

local function blendUnitTangents(a: Vector3, b: Vector3, u: number): Vector3
	local t = math.clamp(u, 0, 1)
	t = t * t * (3 - 2 * t)
	if a:Dot(b) < -0.92 then
		return if t < 0.5 then a else b
	end
	local v = a:Lerp(b, t)
	if v.Magnitude < 1e-5 then
		return if t < 0.5 then a else b
	end
	return v.Unit
end

local function stepSwimTang(agent: GhostFish, tang: Vector3, dt: number): Vector3
	local goal = if tang.Magnitude > 1e-5 then tang.Unit else agent.smoothTang
	if goal.Magnitude < 1e-5 then
		goal = Vector3.new(0, 0, -1)
	end
	local prev = agent.smoothTang
	if prev.Magnitude < 1e-5 then
		agent.smoothTang = goal
		return goal
	end
	local alpha = 1 - math.exp(-C.PATH_TANG_SMOOTH_RATE * math.max(dt, 1e-4))
	agent.smoothTang = blendUnitTangents(prev, goal, alpha)
	return agent.smoothTang
end

local function estimateSegLength(w0: Vector3, c: Vector3, w1: Vector3): number
	local len = 0
	local prev = w0
	for i = 1, 8 do
		local p = quadBezier(w0, c, w1, i / 8)
		len += (p - prev).Magnitude
		prev = p
	end
	return math.max(len, 0.01)
end

local function buildPath(
	targetCf: CFrame,
	targetPlotId: string,
	targetSize: Vector3,
	plotSizeStage: number?,
	targetRingCf: CFrame?
): PathData?
	local plot1 = ClientPlot.getPlot1CFrame()
	if not plot1 then
		return nil
	end
	local root = Workspace:FindFirstChild("WaveRoute")
	local route = root and root:FindFirstChild("A")
	local wpFolder = route and route:FindFirstChild("Waypoints")
	local ctrlFolder = route and route:FindFirstChild("Controls")
	if not wpFolder or not ctrlFolder then
		return nil
	end
	local waypoints: { BasePart } = {}
	local i = 1
	while true do
		local w = findIndexedPart(wpFolder, "W", i)
		if not w then
			break
		end
		table.insert(waypoints, w)
		i += 1
	end
	if #waypoints < 2 then
		return nil
	end
	local finalWp = SkillStages.plotSizeFinalWaypoint(plotSizeStage or 1)
	if finalWp < #waypoints then
		local trimmed: { BasePart } = {}
		for wi = 1, math.min(finalWp, #waypoints) do
			table.insert(trimmed, waypoints[wi])
		end
		waypoints = trimmed
	end
	if #waypoints < 2 then
		return nil
	end
	-- Rigid remap only — keep authored height (no terrain floor snap).
	local function wpPos(part: BasePart): Vector3
		return ClientPlot.remapFromPlot1To(part.Position, targetPlotId, targetCf, targetSize, targetRingCf)
	end
	local segments: { PathSeg } = {}
	local total = 0
	for s = 1, #waypoints - 1 do
		local ctrl = findIndexedPart(ctrlFolder, "C", s)
		if not ctrl then
			return nil
		end
		local w0 = wpPos(waypoints[s])
		local w1 = wpPos(waypoints[s + 1])
		local c = wpPos(ctrl)
		local length = estimateSegLength(w0, c, w1)
		table.insert(segments, {
			w0 = w0,
			c = c,
			w1 = w1,
			length = length,
			cumStart = total,
		})
		total += length
	end
	return {
		segments = segments,
		totalLen = total,
		endPos = wpPos(waypoints[#waypoints]),
	}
end

local function samplePath(path: PathData, dist: number): (Vector3, Vector3)
	local d = math.clamp(dist, 0, path.totalLen)
	for _, seg in ipairs(path.segments) do
		local localD = d - seg.cumStart
		if localD <= seg.length or seg == path.segments[#path.segments] then
			local t = math.clamp(localD / math.max(seg.length, 1e-4), 0, 1)
			return quadBezier(seg.w0, seg.c, seg.w1, t), quadBezierTangent(seg.w0, seg.c, seg.w1, t)
		end
	end
	local last = path.segments[#path.segments]
	return last.w1, quadBezierTangent(last.w0, last.c, last.w1, 1)
end

local function getGreenArrowsTemplate(): Instance?
	if greenArrowsTemplate and greenArrowsTemplate.Parent then
		return greenArrowsTemplate
	end
	local arrows = ReplicatedStorage:FindFirstChild("GreenArrows")
	if not arrows then
		return nil
	end
	greenArrowsTemplate = arrows
	return arrows
end

local function waveFishCount(wave: number): number
	return C.WAVE1_COUNT + (wave - 1) * C.WAVE_COUNT_STEP
end

local function makeHungerBillboard(adornee: BasePart, hungryGlyphs: string?): (BillboardGui, Frame, Frame, TextLabel, TextLabel, UIScale, UIStroke?)
	local glyphs = hungryGlyphs or "🍴"
	local glyphN = utf8.len(glyphs) or 1
	local emojiW = C.HUNGER_EMOJI_SIZE * glyphN
	local totalW = emojiW + C.HUNGER_BAR_GAP + C.HUNGER_BAR_PX_W
	local bb = Instance.new("BillboardGui")
	bb.Name = "HungerBar"
	bb.Size = UDim2.fromOffset(totalW, C.HUNGER_BAR_PX_H)
	bb.StudsOffset = Vector3.new(0, C.HUNGER_BAR_HEIGHT, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = C.HUNGER_BAR_MAX_DIST
	bb.Adornee = adornee
	bb.Parent = adornee

	local barHost = Instance.new("Frame")
	barHost.Name = "BarHost"
	barHost.BackgroundTransparency = 1
	barHost.AnchorPoint = Vector2.new(1, 0.5)
	barHost.Position = UDim2.new(1, 0, 0.5, 0)
	barHost.Size = UDim2.fromOffset(C.HUNGER_BAR_PX_W, C.HUNGER_BAR_STRIP_H)
	barHost.ZIndex = 1
	barHost.Parent = bb

	local scale = Instance.new("UIScale")
	scale.Name = "BarScale"
	scale.Scale = 1
	scale.Parent = barHost

	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.BackgroundColor3 = Color3.new(0, 0, 0)
	bg.BackgroundTransparency = 0.5
	bg.BorderSizePixel = 0
	bg.Size = UDim2.fromScale(1, 1)
	bg.Parent = barHost
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = bg
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = 1
	stroke.Parent = bg

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Color3.fromRGB(40, 255, 90)
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.ZIndex = 1
	fill.Parent = bg
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	local fork = Instance.new("TextLabel")
	fork.Name = "Fork"
	fork.BackgroundTransparency = 1
	fork.AnchorPoint = Vector2.new(0, 0.5)
	fork.Position = UDim2.new(0, 0, 0.5, 0)
	fork.Size = UDim2.fromOffset(emojiW, C.HUNGER_EMOJI_SIZE)
	fork.Font = Enum.Font.SourceSansBold
	fork.Text = glyphs
	fork.TextSize = C.HUNGER_EMOJI_SIZE
	fork.TextScaled = false
	fork.TextXAlignment = Enum.TextXAlignment.Left
	fork.ZIndex = 4
	fork.Parent = bb

	local happy = Instance.new("TextLabel")
	happy.Name = "Happy"
	happy.BackgroundTransparency = 1
	happy.AnchorPoint = Vector2.new(0, 0.5)
	happy.Position = UDim2.new(0, emojiW - C.HUNGER_EMOJI_SIZE, 0.5, 0)
	happy.Size = UDim2.fromOffset(C.HUNGER_EMOJI_SIZE, C.HUNGER_EMOJI_SIZE)
	happy.Font = Enum.Font.SourceSansBold
	happy.Text = C.HAPPY_EMOJIS[1]
	happy.TextSize = C.HUNGER_EMOJI_SIZE
	happy.TextScaled = false
	happy.Visible = false
	happy.ZIndex = 5
	happy.Parent = bb

	return bb, fill, barHost, fork, happy, scale, stroke
end

local function fishWorldOffset(agent: GhostFish, pos: Vector3, tang: Vector3): Vector3
	local flat = Vector3.new(tang.X, 0, tang.Z)
	if flat.Magnitude < 1e-4 then
		flat = Vector3.new(0, 0, -1)
	else
		flat = flat.Unit
	end
	local right = flat:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-4 then
		right = Vector3.xAxis
	else
		right = right.Unit
	end
	local bob = math.sin(simClock * agent.bobFreq * math.pi * 2 + agent.bobPhase) * agent.bobAmp
	local wander = math.sin(simClock * agent.wanderFreq * math.pi * 2 + agent.wanderPhase) * agent.wanderAmp
	return pos + right * (agent.lateral + wander) + Vector3.new(0, agent.vert + bob, 0)
end

local function syncUrchinRig(agent: GhostFish)
	local rootCf = agent.root.CFrame
	local shell = agent.shellHitbox
	local shellLocal = agent.shellLocalCf
	if shell and shell.Parent and shellLocal then
		shell.CFrame = rootCf * shellLocal
	end
	local bodyLocal = agent.bodyLocalCf
	local model = agent.model
	if bodyLocal and model:IsA("BasePart") and model ~= agent.root then
		model.CFrame = rootCf * bodyLocal
	end
end

local function captureUrchinRigLocals(agent: GhostFish)
	local root = agent.root
	local shell = agent.shellHitbox
	if shell and shell.Parent then
		agent.shellLocalCf = root.CFrame:ToObjectSpace(shell.CFrame)
	end
	local model = agent.model
	if model:IsA("BasePart") and model ~= root then
		agent.bodyLocalCf = root.CFrame:ToObjectSpace(model.CFrame)
	end
end

local function setFishCFrame(agent: GhostFish, world: Vector3, swimTang: Vector3, dt: number)
	agent.lastWorld = world
	local move = if swimTang.Magnitude > 1e-5 then swimTang.Unit else Vector3.new(0, 0, -1)
	local desired = if isGroundCritter(agent)
		then WaveCrab.facingCFrame(world, move)
		else CFrame.lookAt(world, world + move, Vector3.yAxis) * CFrame.Angles(C.TANG_PITCH, C.TANG_YAW, C.TANG_ROLL)
	if agent.isCrab then
		WaveCrab.applyPose(agent.root, desired)
		local anim = agent.crabAnim
		if anim then
			WaveCrab.stepAnim(anim, dt, world)
		end
		return
	end
	if agent.isUrchin then
		WaveCrab.applyPose(agent.root, desired)
		syncUrchinRig(agent)
		return
	end
	if agent.model:IsA("Model") then
		agent.model:PivotTo(desired)
	else
		agent.root.CFrame = desired
	end
end

local function refreshHungerVisual(agent: GhostFish)
	if not agent.fill then
		return
	end
	local u = math.clamp(agent.hunger / math.max(1, agent.maxHunger), 0, 1)
	agent.fill.Size = UDim2.fromScale(u, 1)
	local full = agent.hunger >= agent.maxHunger
	if agent.forkLabel then
		agent.forkLabel.Visible = not full
	end
	if agent.happyLabel then
		agent.happyLabel.Visible = full
		if full then
			agent.happyLabel.Text = C.HAPPY_EMOJIS[((agent.id - 1) % #C.HAPPY_EMOJIS) + 1]
		end
	end
end

local function setBarsVisible(visible: boolean)
	for _, agent in ipairs(fishList) do
		if agent.billboard then
			agent.billboard.Enabled = visible
		end
	end
end

local function spawnFishAt(path: PathData, dist: number, wave: number, hungerFrac: number?): GhostFish?
	local clone, root = WaveEntityPool.acquireFish(WaveEntityPool.FISH_TANG, "GhostTang_" .. tostring(nextFishId))
	if not clone or not root then
		return nil
	end
	clone.Parent = ensureFolder()
	local maxH = C.tangHungerForWave(wave)
	local hunger = math.floor(maxH * math.clamp(hungerFrac or 0, 0, 0.95))
	local bb, fill, _bar, fork, happy, _scale, stroke = makeHungerBillboard(root)
	if lodFar then
		bb.Enabled = false
	end
	local agent: GhostFish = {
		id = nextFishId,
		root = root,
		model = clone,
		dist = dist,
		lateral = rng:NextNumber(-C.LATERAL_SPREAD, C.LATERAL_SPREAD),
		vert = rng:NextNumber(-C.VERT_SPREAD, C.VERT_SPREAD),
		bobAmp = rng:NextNumber(C.BOB_AMP_MIN, C.BOB_AMP_MAX),
		bobFreq = rng:NextNumber(0.012, 0.032),
		bobPhase = rng:NextNumber(0, math.pi * 2),
		wanderAmp = rng:NextNumber(C.WANDER_AMP_MIN, C.WANDER_AMP_MAX),
		wanderFreq = rng:NextNumber(0.014, 0.038),
		wanderPhase = rng:NextNumber(0, math.pi * 2),
		speedPhase = rng:NextNumber(0, math.pi * 2),
		speedFreq = rng:NextNumber(0.22, 0.55),
		hunger = hunger,
		maxHunger = maxH,
		finished = false,
		billboard = bb,
		fill = fill,
		forkLabel = fork,
		happyLabel = happy,
		barStroke = stroke,
		smoothTang = Vector3.new(0, 0, -1),
		lastWorld = Vector3.zero,
		isCrab = false,
		isUrchin = false,
		crabAnim = nil,
		shellHitbox = nil,
		pauseUntil = nil,
		crabSprint = nil,
	}
	nextFishId += 1
	local pos, tang = samplePath(path, dist)
	local world = fishWorldOffset(agent, pos, tang)
	agent.lastWorld = world
	setFishCFrame(agent, world, tang, 1)
	refreshHungerVisual(agent)
	table.insert(fishList, agent)
	return agent
end

local function spawnCrabAt(path: WaveCrab.PathData, dist: number, wave: number, hungerFrac: number?): GhostFish?
	if not WaveCrab.shouldSpawn(wave) then
		return nil
	end
	local clone, root = WaveEntityPool.acquireFish(WaveEntityPool.FISH_CRAB, "GhostCrab_" .. tostring(nextFishId))
	if not clone or not root then
		return nil
	end
	clone.Parent = ensureFolder()
	local maxH = WaveCrab.hungerForWave(wave)
	local hunger = math.floor(maxH * math.clamp(hungerFrac or 0, 0, 0.95))
	local bb, fill, _bar, fork, happy, _scale, stroke = makeHungerBillboard(root, "⚡🍴")
	if lodFar then
		bb.Enabled = false
	end
	local anim = WaveCrab.bindAnim(clone, root)
	local agent: GhostFish = {
		id = nextFishId,
		root = root,
		model = clone,
		dist = dist,
		lateral = 0,
		vert = 0,
		bobAmp = 0,
		bobFreq = 1,
		bobPhase = 0,
		wanderAmp = 0,
		wanderFreq = 1,
		wanderPhase = 0,
		speedPhase = 0,
		speedFreq = 1,
		hunger = hunger,
		maxHunger = maxH,
		finished = false,
		billboard = bb,
		fill = fill,
		forkLabel = fork,
		happyLabel = happy,
		barStroke = stroke,
		smoothTang = Vector3.new(0, 0, -1),
		lastWorld = Vector3.zero,
		isCrab = true,
		isUrchin = false,
		crabAnim = anim,
		shellHitbox = WaveCrab.findShell(clone),
		pauseUntil = nil,
		stunSkullPart = nil,
		crabSprint = WaveCrab.newSprint(),
	}
	nextFishId += 1
	local pos, tang = WaveCrab.sample(path, dist)
	pos = WaveCrab.worldOnGround(pos, nil, 1)
	agent.lastWorld = pos
	setFishCFrame(agent, pos, tang, 1)
	refreshHungerVisual(agent)
	table.insert(fishList, agent)
	return agent
end

local function spawnUrchinAt(path: WaveCrab.PathData, dist: number, wave: number, hungerFrac: number?): GhostFish?
	if not WaveUrchin.shouldSpawn(wave) then
		return nil
	end
	local clone, root = WaveEntityPool.acquireFish(WaveEntityPool.FISH_URCHIN, "GhostUrchin_" .. tostring(nextFishId))
	if not clone or not root then
		return nil
	end
	clone.Parent = ensureFolder()
	local maxH = WaveUrchin.hungerForWave(wave)
	local hunger = math.floor(maxH * math.clamp(hungerFrac or 0, 0, 0.95))
	local bb, fill, _bar, fork, happy, _scale, stroke = makeHungerBillboard(root, "✴🍴")
	if lodFar then
		bb.Enabled = false
	end
	local agent: GhostFish = {
		id = nextFishId,
		root = root,
		model = clone,
		dist = dist,
		lateral = 0,
		vert = 0,
		bobAmp = 0,
		bobFreq = 1,
		bobPhase = 0,
		wanderAmp = 0,
		wanderFreq = 1,
		wanderPhase = 0,
		speedPhase = 0,
		speedFreq = 1,
		hunger = hunger,
		maxHunger = maxH,
		finished = false,
		billboard = bb,
		fill = fill,
		forkLabel = fork,
		happyLabel = happy,
		barStroke = stroke,
		smoothTang = Vector3.new(0, 0, -1),
		lastWorld = Vector3.zero,
		isCrab = false,
		isUrchin = true,
		crabAnim = nil,
		shellHitbox = WaveUrchin.findShell(clone),
		shellLocalCf = nil,
		bodyLocalCf = nil,
		pauseUntil = nil,
		stunSkullPart = nil,
		crabSprint = nil,
	}
	nextFishId += 1
	local pos, tang = WaveUrchin.sample(path, dist)
	pos = WaveUrchin.worldOnGround(pos, nil, 1)
	agent.lastWorld = pos
	captureUrchinRigLocals(agent)
	setFishCFrame(agent, pos, tang, 1)
	captureUrchinRigLocals(agent)
	refreshHungerVisual(agent)
	table.insert(fishList, agent)
	return agent
end

local function releaseGroundCritter(agent: GhostFish)
	agent.finished = true
	if agent.isCrab then
		WaveCrab.resetAnim(agent.crabAnim)
		WaveEntityPool.releaseFish(WaveEntityPool.FISH_CRAB, agent.model)
	elseif agent.isUrchin then
		WaveEntityPool.releaseFish(WaveEntityPool.FISH_URCHIN, agent.model)
	end
end

local function setArrowCFrame(model: Instance, pos: Vector3, tang: Vector3, spin: number)
	local move = if tang.Magnitude > 1e-5 then tang.Unit else Vector3.new(0, 0, -1)
	local look = CFrame.lookAt(pos, pos + move, Vector3.yAxis)
	local desired = look * CFrame.Angles(0, C.ARROW_YAW, C.ARROW_ROLL + spin)
	if model:IsA("Model") then
		model:PivotTo(desired)
	elseif model:IsA("BasePart") then
		model.CFrame = desired
	end
end

local function createWavePathLabel(text: string, pos: Vector3, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = "OceanTD_GhostWaveLabel"
	part.Size = Vector3.new(0.4, 0.4, 0.4)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CFrame = CFrame.new(pos)
	part.Parent = parent

	local bb = Instance.new("BillboardGui")
	bb.Name = "Label"
	bb.Adornee = part
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 2000
	bb.Size = UDim2.fromScale(C.WAVE_LABEL_SCALE.X, C.WAVE_LABEL_SCALE.Y)
	bb.StudsOffset = Vector3.new(0, C.WAVE_LABEL_HEIGHT, 0)
	bb.Parent = part

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = UiTheme.Font
	lbl.Text = text
	lbl.TextColor3 = Color3.fromRGB(40, 255, 120)
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.25
	lbl.TextStrokeColor3 = Color3.fromRGB(0, 40, 15)
	lbl.Parent = bb
	return part
end

local function playArrowStartSound()
	if lodFar then
		return
	end
	WaveEntityPool.playSound("arrow", arrowSound, 1, 0.9, true)
end

local function startWaveArrowPreview(wave: number)
	destroyArrowPreview()
	local path = pathData
	local tmpl = getGreenArrowsTemplate()
	if not path or not tmpl or lodFar then
		return
	end
	playArrowStartSound()
	local folderFx = ensureFolder()
	local waveText = "Wave " .. tostring(math.max(1, wave))
	local d = 0
	local i = 0
	while d < path.totalLen - 0.05 do
		i += 1
		local clone = WaveEntityPool.acquireArrows("OceanTD_GhostArrows_" .. tostring(i), folderFx)
		if not clone then
			break
		end
		local spin0 = (i - 1) * 0.55
		local pos, tang = samplePath(path, d)
		setArrowCFrame(clone, pos, tang, spin0)
		table.insert(arrowPreviews, {
			model = clone,
			dist = d,
			spin = spin0,
			alive = true,
		})
		if i % C.ARROW_LABEL_EVERY == 0 then
			local part = createWavePathLabel(waveText, pos, folderFx)
			table.insert(wavePathLabels, {
				part = part,
				dist = d,
				alive = true,
			})
		end
		d += C.ARROW_PATH_SPACING
	end
end

local function tickArrowPreview(dt: number)
	local path = pathData
	if not path then
		return
	end
	local speed = C.FISH_SPEED * C.ARROW_SPEED_MULT * speedMult
	for i = #arrowPreviews, 1, -1 do
		local preview = arrowPreviews[i]
		if not preview.alive or not preview.model.Parent then
			WaveEntityPool.releaseArrows(preview.model)
			table.remove(arrowPreviews, i)
			continue
		end
		preview.dist += speed * dt
		preview.spin += C.ARROW_SPIN_RAD_PER_SEC * dt
		if preview.dist >= path.totalLen then
			WaveEntityPool.releaseArrows(preview.model)
			table.remove(arrowPreviews, i)
			continue
		end
		local pos, tang = samplePath(path, preview.dist)
		setArrowCFrame(preview.model, pos, tang, preview.spin)
	end
	for i = #wavePathLabels, 1, -1 do
		local label = wavePathLabels[i]
		if not label.alive or not label.part.Parent then
			table.remove(wavePathLabels, i)
			continue
		end
		label.dist += speed * dt
		if label.dist >= path.totalLen then
			label.part:Destroy()
			table.remove(wavePathLabels, i)
			continue
		end
		local pos = samplePath(path, label.dist)
		label.part.CFrame = CFrame.new(pos)
	end
end

local function restoreGhostStunned(fade: boolean)
	for part in pairs(stunnedCorals) do
		if part.Parent then
			WaveCrab.clearCoralStun(part, fade)
		end
	end
	table.clear(stunnedCorals)
	coralDirty = true
end

local function refreshCoralCache(plotId: string)
	coralDirty = false
	coralCachePlot = plotId
	table.clear(coralCache)
	table.clear(coralParts)
	local PlacedCoralIndex = require(script.Parent:WaitForChild("PlacedCoralIndex"))
	for _, part in ipairs(PlacedCoralIndex.getParts(plotId)) do
		if part.Parent then
			table.insert(coralParts, part)
			if not stunnedCorals[part] then
				table.insert(coralCache, part.Position)
			end
		end
	end
end

local function gatherCoralPositions(plotId: string): { Vector3 }
	if coralDirty or coralCachePlot ~= plotId then
		refreshCoralCache(plotId)
	end
	return coralCache
end

local function playFeedSound()
	if lodFar then
		return
	end
	WaveEntityPool.playSound("feed", feedSound, rng:NextNumber(C.FEED_PITCH_MIN, C.FEED_PITCH_MAX), 0.85)
end

local function spawnFoodPop(from: Vector3, toFish: GhostFish)
	if lodFar then
		toFish.hunger = math.min(toFish.maxHunger, toFish.hunger + 1)
		refreshHungerVisual(toFish)
		return
	end
	local folderFx = ensureFolder()
	local p = WaveEntityPool.acquireFood(folderFx, C.FOOD_RADIUS)
	p.Color = Color3.fromRGB(90, 220, 120)
	p.CFrame = CFrame.new(from)
	local dur = rng:NextNumber(0.45, 0.85)
	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		if toFish.finished or not toFish.model.Parent then
			conn:Disconnect()
			WaveEntityPool.releaseFood(p)
			return
		end
		local u = math.clamp((os.clock() - t0) / dur, 0, 1)
		local target = toFish.root.Position + Vector3.new(0, 1, 0)
		local mid = from:Lerp(target, 0.5) + Vector3.new(0, 6, 0)
		local a = from:Lerp(mid, u)
		local b = mid:Lerp(target, u)
		p.CFrame = CFrame.new(a:Lerp(b, u))
		if u >= 1 then
			conn:Disconnect()
			WaveEntityPool.releaseFood(p)
			toFish.hunger = math.min(toFish.maxHunger, toFish.hunger + 1)
			refreshHungerVisual(toFish)
			playFeedSound()
		end
	end)
end

local function applyFeedDelta(delta: number, plotId: string)
	if delta <= 0.002 or not pathData then
		return
	end
	local corals = gatherCoralPositions(plotId)
	local pops = math.clamp(math.ceil(delta * 14), 1, if lodFar then 2 else 8)
	for _ = 1, pops do
		local hungry: { GhostFish } = {}
		for _, f in ipairs(fishList) do
			if not f.finished and f.hunger < f.maxHunger then
				table.insert(hungry, f)
			end
		end
		if #hungry == 0 then
			break
		end
		local fish = hungry[rng:NextInteger(1, #hungry)]
		local from = if #corals > 0 then corals[rng:NextInteger(1, #corals)] else fish.root.Position + Vector3.new(0, 8, 0)
		spawnFoodPop(from, fish)
	end
end

-- Drive individual hunger bars from host fishFull / feedProgress (same source as the wave HUD bar).
local function syncHungerFromHost(snap: WaveWatchMode.WatchSnap)
	local alive: { GhostFish } = {}
	for _, f in ipairs(fishList) do
		if not f.finished and f.model.Parent then
			table.insert(alive, f)
		end
	end
	if #alive == 0 then
		return
	end

	local total = math.max(1, if (snap.fishTotal or 0) > 0 then snap.fishTotal else #alive)
	total += math.max(0, snap.crabTotal or 0)
	total += math.max(0, snap.urchinTotal or 0)
	-- How many fish should look fully fed vs still hungry.
	local fullCount = math.clamp(math.floor((snap.fishFull or 0) + 0.5), 0, total)
	local fromBar = math.clamp(math.floor((snap.feedProgress or 0) * total + 1e-4), 0, total)
	-- Prefer the higher signal so bars stay aligned with the filling wave bar.
	fullCount = math.max(fullCount, fromBar)
	if snap.feedComplete or (snap.feedProgress or 0) >= 0.999 then
		fullCount = total
	end

	-- Partial fill on the "next" hungry fish from leftover progress.
	local filledExact = (snap.feedProgress or 0) * total
	local partial = math.clamp(filledExact - fullCount, 0, 0.99)

	-- Fish farther along the path read as fed first (matches finishing toward the heart).
	table.sort(alive, function(a, b)
		return a.dist > b.dist
	end)

	-- Map host fullCount onto our visible school size.
	local visibleFull = math.clamp(math.floor(fullCount * (#alive / total) + 0.5), 0, #alive)
	if fullCount >= total then
		visibleFull = #alive
	elseif fullCount <= 0 then
		visibleFull = 0
	end

	for i, f in ipairs(alive) do
		if i <= visibleFull then
			f.hunger = f.maxHunger
		elseif i == visibleFull + 1 and partial > 0.05 and visibleFull < #alive then
			f.hunger = math.max(0, math.floor(f.maxHunger * partial))
		else
			f.hunger = 0
		end
		refreshHungerVisual(f)
	end
end

-- Lightweight mid-wave snapshot: spawn the wave's fish count, then paint hunger from host progress.
local function snapshotSchool(snap: WaveWatchMode.WatchSnap, path: PathData)
	clearFish()
	destroyArrowPreview()
	waveSpawning = false
	spawnQueue = 0
	crabSpawnQueue = 0
	crabSpawnDelay = 0
	urchinSpawnQueue = 0
	urchinSpawnDelay = 0
	local total = math.max(1, snap.fishTotal > 0 and snap.fishTotal or waveFishCount(snap.wave))
	local spawnN = total
	if lodFar then
		spawnN = math.min(spawnN, 8)
	end
	-- School packs near estimated front (feed progress), not evenly W1→end.
	local front = path.totalLen * math.clamp(0.12 + snap.feedProgress * 0.7, 0.12, 0.88)
	local spacing = math.clamp(C.FISH_SPEED * C.STAGGER_SEC * 1.1, 4, 14)
	for i = 1, spawnN do
		local behind = (spawnN - i) * spacing
		local dist = math.clamp(front - behind, 0.5, path.totalLen * 0.95)
		spawnFishAt(path, dist, snap.wave, 0)
	end
	if pathDataGround and WaveUrchin.shouldSpawn(snap.wave) then
		local g = pathDataGround
		local nUrchin = math.max(0, snap.urchinTotal or 0)
		local frontU = math.clamp(g.totalLen * math.clamp(0.12 + snap.feedProgress * 0.7, 0.12, 0.88), 0.5, g.totalLen * 0.95)
		for ui = 1, nUrchin do
			local urchinDist = math.clamp(frontU - (ui - 1) * 3.2, 0.5, g.totalLen * 0.95)
			spawnUrchinAt(g, urchinDist, snap.wave, 0)
		end
	end
	if pathDataGround and WaveCrab.shouldSpawn(snap.wave) then
		local g = pathDataGround
		local nCrab = math.max(0, snap.crabTotal or 0)
		local frontC = math.clamp(g.totalLen * math.clamp(0.12 + snap.feedProgress * 0.7, 0.12, 0.88), 0.5, g.totalLen * 0.95)
		for ci = 1, nCrab do
			local crabDist = math.clamp(frontC - (ci - 1) * 3.2, 0.5, g.totalLen * 0.95)
			spawnCrabAt(g, crabDist, snap.wave, 0)
		end
	end
	syncHungerFromHost(snap)
	startedThisWave = true -- mid-join: don't re-run arrows until next wave
end

local function beginWaveFull(snap: WaveWatchMode.WatchSnap, path: PathData)
	clearFish()
	destroyArrowPreview()
	restoreGhostStunned(snap.wave > 1)
	waveIndex = snap.wave
	waveFishExpected = if snap.fishTotal > 0 then snap.fishTotal else waveFishCount(snap.wave)
	waveCrabExpected = math.max(0, snap.crabTotal or 0)
	waveUrchinExpected = math.max(0, snap.urchinTotal or 0)
	spawnQueue = waveFishExpected
	spawnDelay = C.ARROW_LEAD_SEC
	crabSpawnQueue = 0
	crabSpawnDelay = 0
	urchinSpawnQueue = waveUrchinExpected
	urchinSpawnDelay = if waveUrchinExpected > 0
		then rng:NextNumber(C.URCHIN_FIRST_DELAY_MIN, C.URCHIN_FIRST_DELAY_MAX)
		else 0
	waveSpawning = true
	startedThisWave = true
	lastFeed = snap.feedProgress
	startWaveArrowPreview(snap.wave)
	if #path.segments > 0 and not lodFar then
		WaveStartVfx.play(snap.wave, path.segments[1].w0)
	end
end

local function updateLod()
	if not activePlotCf then
		lodFar = false
		return
	end
	local cam = Workspace.CurrentCamera
	local origin = activePlotCf.Position
	local from = if cam then cam.CFrame.Position else origin
	local char = Players.LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		from = hrp.Position
	end
	local dist = (from - origin).Magnitude
	local wasFar = lodFar
	lodFar = dist > LOD_FAR
	local near = dist <= LOD_NEAR
	if lodFar ~= wasFar then
		setBarsVisible(not lodFar)
		if lodFar then
			destroyArrowPreview()
		end
	end
	if near then
		lodTickSkip = false
	end
end

local function tick(dt: number)
	if fading or not pathData then
		return
	end
	updateLod()
	if lodFar then
		lodTickSkip = not lodTickSkip
		if lodTickSkip then
			return
		end
		dt *= 2
	end

	local simDt = dt * speedMult
	simClock += simDt
	tickArrowPreview(simDt)

	if urchinSpawnQueue > 0 and pathDataGround then
		urchinSpawnDelay -= simDt
		if urchinSpawnDelay <= 0 then
			spawnUrchinAt(pathDataGround, 0, waveIndex, 0)
			urchinSpawnQueue -= 1
			urchinSpawnDelay = if urchinSpawnQueue > 0
				then rng:NextNumber(C.URCHIN_STAGGER_MIN, C.URCHIN_STAGGER_MAX)
				else 0
		end
	end

	if waveSpawning and spawnQueue > 0 and pathData then
		spawnDelay -= simDt
		if spawnDelay <= 0 then
			local first = spawnQueue == waveFishExpected
			spawnFishAt(pathData, 0, waveIndex, 0)
			if first and pathDataGround then
				if waveCrabExpected > 0 then
					crabSpawnQueue = waveCrabExpected
					crabSpawnDelay = rng:NextNumber(C.CRAB_FIRST_DELAY_MIN, C.CRAB_FIRST_DELAY_MAX)
				end
			end
			spawnQueue -= 1
			spawnDelay = C.STAGGER_SEC
			if spawnQueue <= 0 then
				waveSpawning = false
			end
		end
	end

	if crabSpawnQueue > 0 and pathDataGround then
		crabSpawnDelay -= simDt
		if crabSpawnDelay <= 0 then
			spawnCrabAt(pathDataGround, 0, waveIndex, 0)
			crabSpawnQueue -= 1
			crabSpawnDelay = if crabSpawnQueue > 0
				then rng:NextNumber(C.CRAB_STAGGER_MIN, C.CRAB_STAGGER_MAX)
				else 0
		end
	end

	local path = pathData
	local ground = pathDataGround
	if not path then
		return
	end
	for _, agent in ipairs(fishList) do
		if agent.finished then
			continue
		end
		if isGroundCritter(agent) then
			if not ground then
				releaseGroundCritter(agent)
				continue
			end
			local isCrab = agent.isCrab == true
			local wasFighting = agent.pauseUntil ~= nil
			local paused = wasFighting and os.clock() < (agent.pauseUntil :: number)
			if paused and agent.hunger >= agent.maxHunger then
				local part = agent.stunSkullPart
				agent.stunSkullPart = nil
				agent.pauseUntil = nil
				if part then
					stunnedCorals[part] = nil
					if part.Parent then
						WaveCrab.clearCoralStun(part, true)
					end
					coralDirty = true
				end
				paused = false
				wasFighting = false
			end
			if not paused then
				if wasFighting then
					local skullPart = agent.stunSkullPart
					agent.stunSkullPart = nil
					if skullPart and agent.hunger < agent.maxHunger then
						WaveCrab.playDeathSkullFromCoral(skullPart)
					elseif skullPart then
						stunnedCorals[skullPart] = nil
						if skullPart.Parent then
							WaveCrab.clearCoralStun(skullPart, true)
						end
						coralDirty = true
					end
				end
				agent.pauseUntil = nil
				if isCrab then
					local sprint = agent.crabSprint
					if sprint then
						WaveCrab.tickSprint(sprint, simClock)
					end
					agent.dist += WaveCrab.speedNow(sprint, simClock) * simDt
				else
					agent.dist += WaveUrchin.speedNow() * simDt
				end
			end
			if agent.dist >= ground.totalLen then
				releaseGroundCritter(agent)
			else
				local pos, tang = WaveCrab.sample(ground, agent.dist)
				local swimTang = stepSwimTang(agent, tang, simDt)
				pos = WaveCrab.worldOnGround(pos, agent.lastWorld.Y, simDt)
				if paused then
					WaveCrab.applyFightPose(
						agent.root,
						agent.crabAnim,
						pos,
						swimTang,
						simDt,
						WaveCrab.pauseElapsed(agent.pauseUntil, agent.pauseDur),
						agent.id,
						agent.pauseDur
					)
					if agent.isUrchin then
						syncUrchinRig(agent)
					end
				else
					setFishCFrame(agent, pos, swimTang, simDt)
				end
				if agent.hunger < agent.maxHunger and not paused then
					local shell = agent.shellHitbox or agent.root
					if shell then
						if coralDirty or coralCachePlot ~= activePlotId then
							if activePlotId then
								refreshCoralCache(activePlotId)
							end
						end
						for _, part in ipairs(coralParts) do
							if stunnedCorals[part] or not part.Parent then
								continue
							end
							if WaveCrab.shellOverlapsCoral(shell, part) then
								stunnedCorals[part] = true
								WaveCrab.stunCoralPart(part)
								coralDirty = true
								local _d, class = CoralSize.readFromPart(part)
								local sid = part:GetAttribute("OceanTD_SpeciesId")
								local def = CoralSize.statsFor(class, if typeof(sid) == "string" then sid else nil).defense
								local pauseSec = if isCrab then def else WaveUrchin.coralPauseSec(def)
								agent.pauseDur = pauseSec
								agent.pauseUntil = os.clock() + pauseSec
								agent.stunSkullPart = part
								local follow = agent
								local fallback = pos
								WaveCrab.playZapBurst(ensureFolder(), function()
									if follow.finished or not follow.root.Parent then
										return fallback
									end
									local shellNow = follow.shellHitbox
									if shellNow and shellNow.Parent then
										return shellNow.Position
									end
									return follow.root.Position
								end, pauseSec)
								break
							end
						end
					end
				end
			end
			continue
		end
		local surge = 1 + C.FISH_SPEED_VAR * math.sin(simClock * agent.speedFreq + agent.speedPhase)
		agent.dist += C.FISH_SPEED * surge * simDt
		if agent.dist >= path.totalLen then
			agent.finished = true
			WaveEntityPool.releaseFish(WaveEntityPool.FISH_TANG, agent.model)
		else
			local pos, tang = samplePath(path, agent.dist)
			local swimTang = stepSwimTang(agent, tang, simDt)
			setFishCFrame(agent, fishWorldOffset(agent, pos, swimTang), swimTang, simDt)
		end
	end
end

local function ensureMoving()
	if moveConn then
		return
	end
	moveConn = RunService.Heartbeat:Connect(function(dt)
		tick(dt)
	end)
end

local function hardClear()
	WaveStartVfx.cancel()
	if moveConn then
		moveConn:Disconnect()
		moveConn = nil
	end
	destroyArrowPreview()
	clearFish()
	restoreGhostStunned(false)
	if activePlotId then
		WaveEndVfx.clearRouteEnd(activePlotId)
	end
	if folder then
		folder:Destroy()
		folder = nil
	end
	pathData = nil
	pathDataGround = nil
	activePlotId = nil
	activePlotCf = nil
	fading = false
	waveSpawning = false
	spawnQueue = 0
	crabSpawnQueue = 0
	crabSpawnDelay = 0
	urchinSpawnQueue = 0
	urchinSpawnDelay = 0
	startedThisWave = false
	waveIndex = 0
end

function WaveGhostSim.stop(fade: boolean?)
	local doFade = fade ~= false
	fading = true
	WaveStartVfx.cancel()
	if moveConn then
		moveConn:Disconnect()
		moveConn = nil
	end
	destroyArrowPreview()
	local f = folder
	local plotId = activePlotId
	activePlotId = nil
	activePlotCf = nil
	pathData = nil
	pathDataGround = nil
	waveSpawning = false
	spawnQueue = 0
	crabSpawnQueue = 0
	crabSpawnDelay = 0
	urchinSpawnQueue = 0
	urchinSpawnDelay = 0
	startedThisWave = false
	restoreGhostStunned(false)
	if plotId then
		WaveEndVfx.clearRouteEnd(plotId)
	end
	if f and f.Parent and doFade then
		for _, d in ipairs(f:GetDescendants()) do
			if d:IsA("BasePart") then
				TweenService:Create(d, TweenInfo.new(0.85), { Transparency = 1 }):Play()
			elseif d:IsA("BillboardGui") then
				d.Enabled = false
			end
		end
		task.delay(1, function()
			if f.Parent then
				f:Destroy()
			end
			if folder == f then
				folder = nil
			end
			clearFish()
			fading = false
		end)
	else
		clearFish()
		if f then
			f:Destroy()
		end
		folder = nil
		fading = false
	end
end

function WaveGhostSim.isActive(): boolean
	return activePlotId ~= nil and not fading
end

function WaveGhostSim.markCoralDirty()
	coralDirty = true
end

function WaveGhostSim.apply(snap: WaveWatchMode.WatchSnap, plotCf: CFrame, kind: string?, plotSize: Vector3?, plotRingCf: CFrame?)
	if not snap.running then
		WaveGhostSim.stop(true)
		return
	end

	local eventKind = kind or "heartbeat"
	local plotChanged = activePlotId ~= snap.plotId
	if pathData == nil or plotChanged then
		hardClear()
		local size = plotSize or Vector3.new(64, 32, 64)
		local ringCf = plotRingCf or plotCf
		pathData = buildPath(plotCf, snap.plotId, size, snap.plotSizeStage, ringCf)
		pathDataGround = WaveCrab.buildOn(snap.plotId, plotCf, size, ringCf)
		if not pathData then
			return
		end
		WaveEndVfx.setRouteEndWorldPos(pathData.endPos, snap.plotId)
		activePlotId = snap.plotId
		activePlotCf = plotCf
		ensureFolder()
		coralDirty = true
		speedMult = snap.speedMult
		lastFeed = snap.feedProgress
		lastMiss = snap.hungryMissToken
		lastReef = snap.reefHealth
		lastCoralEpoch = snap.coralEpoch or 0
		waveIndex = snap.wave
		-- Fresh join: full wave start if early, else lightweight snapshot.
		if eventKind == "start" or eventKind == "next" or snap.feedProgress < 0.08 then
			beginWaveFull(snap, pathData)
		else
			snapshotSchool(snap, pathData)
		end
		syncHungerFromHost(snap)
		ensureMoving()
		return
	end

	speedMult = snap.speedMult
	activePlotCf = plotCf

	if (snap.coralEpoch or 0) ~= lastCoralEpoch then
		lastCoralEpoch = snap.coralEpoch or 0
		coralDirty = true
	end
	if eventKind == "coral" then
		coralDirty = true
	end

	-- New wave / skip / next → full arrows + stagger (accurate)
	if eventKind == "next" or eventKind == "start" or snap.wave ~= waveIndex then
		waveIndex = snap.wave
		beginWaveFull(snap, pathData :: PathData)
		lastFeed = snap.feedProgress
		lastMiss = snap.hungryMissToken
		lastReef = snap.reefHealth
		syncHungerFromHost(snap)
		ensureMoving()
		return
	end

	-- Keep fish hunger bars aligned with host wave bar / fishFull counts.
	if snap.feedProgress > lastFeed + 0.01 then
		applyFeedDelta(snap.feedProgress - lastFeed, snap.plotId)
	end
	syncHungerFromHost(snap)
	lastFeed = snap.feedProgress

	if snap.hungryMissToken > lastMiss or (lastReef >= 0 and snap.reefHealth < lastReef) then
		local endPos = (pathData :: PathData).endPos
		WaveEndVfx.playReefHealthTicks(1, endPos, false)
	end
	lastMiss = snap.hungryMissToken
	lastReef = snap.reefHealth

	ensureMoving()
end

return WaveGhostSim
