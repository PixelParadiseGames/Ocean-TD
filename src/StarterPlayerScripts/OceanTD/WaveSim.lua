--!strict
--[[
	Client-only feed-wave simulation (solo). Fish, food, reef health — not replicated.
	Optimized: path samples once, spatial hash for coral↔fish, 10 Hz targeting, pooled FX.
]]

local ContentProvider = game:GetService("ContentProvider")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local SpeciesCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SpeciesCatalog"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
local WaveStartVfx = require(script.Parent:WaitForChild("WaveStartVfx"))

local WaveSim = {}

local WaveSimConsts = require(script.Parent:WaitForChild("WaveSimConsts"))
local C = WaveSimConsts

local feedSound = Instance.new("Sound")
feedSound.Name = "OceanTD_FeedHit"
feedSound.SoundId = C.FEED_SOUND_ID
feedSound.Volume = 0.85
feedSound.Parent = SoundService

local arrowSound = Instance.new("Sound")
arrowSound.Name = "OceanTD_WaveArrows"
arrowSound.SoundId = C.ARROW_SOUND_ID
arrowSound.Volume = 0.9
arrowSound.Parent = SoundService

task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ feedSound, arrowSound })
	end)
end)


export type Summary = {
	waveReached: number,
	fishFed: number,
	elapsedSec: number,
}

export type HudSnapshot = {
	wave: number,
	reefHealth: number,
	reefMax: number,
	elapsedSec: number,
	running: boolean,
	feedProgress: number, -- 0..1 hunger filled this wave
	feedComplete: boolean, -- all wave fish fully fed; early finish available
	hungerDanger: boolean, -- any fish hunger bar flashing red (final path)
	hungryMissToken: number, -- bumps when a hungry fish reaches the end (broken heart)
	fishFull: number, -- fully-fed fish this wave (alive + finished happy)
	fishTotal: number, -- fish expected this wave
}

type PathSegment = {
	w0: Vector3,
	c: Vector3,
	w1: Vector3,
	length: number,
	cumStart: number,
	inTang: Vector3, -- unit tangent at t=0
	outTang: Vector3, -- unit tangent at t=1
}

type PathData = {
	segments: { PathSegment },
	totalLen: number,
	endPos: Vector3,
	waypointDists: { number }, -- path distance at W1..Wn
}

type FishAgent = {
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
	billboard: BillboardGui,
	fill: Frame,
	barFrame: Frame,
	forkLabel: TextLabel,
	happyLabel: TextLabel,
	barScale: UIScale,
	barStroke: UIStroke?,
	pulseToken: number,
	dangerToken: number,
	dangerActive: boolean,
	smoothTang: Vector3,
	lastWorld: Vector3,
	incomingFood: number, -- pending fill units from in-flight food orbs
}

type CoralAgent = {
	part: BasePart,
	color: Color3,
	reloadSec: number,
	foodFill: number,
	diameter: number,
	readyAt: number,
	ammo: BasePart?,
	growing: boolean,
	growT0: number,
	busy: boolean, -- projectile in flight
	hashKeys: { number },
	pathDist: number, -- nearest distance along WaveRoute
	pathSideDist: number, -- world distance from that path point
}

type FoodShot = {
	part: BasePart,
	target: FishAgent?,
	fill: number,
	coral: CoralAgent,
	alive: boolean,
	age: number,
	duration: number,
	startPos: Vector3,
	meetPos: Vector3,
	swayPhase: number,
}

type ArrowPreview = {
	model: Instance,
	dist: number,
	spin: number,
	alive: boolean,
}

type WavePathLabel = {
	part: BasePart,
	dist: number,
	alive: boolean,
}

local running = false
local token = 0
local folder: Folder? = nil
local pathData: PathData? = nil
local fishList: { FishAgent } = {}
local coralList: { CoralAgent } = {}
local hash: { [number]: { CoralAgent } } = {}
local fishPathBuckets: { { FishAgent } } = {}
local foodPool: { BasePart } = {}
local activeShots: { FoodShot } = {}
local spawnQueue = 0
local spawnDelay = 0
local waveIndex = 0
local reefMaxHealth = C.REEF_START_HEALTH
local reefHealth = C.REEF_START_HEALTH
local fishFed = 0
local waveFishExpected = 0
local waveFedUnits = 0 -- sum of maxHunger for fish fully fed this wave (incl. finished)
local startedAt = 0
local waveSpawning = false
local moveConn: RBXScriptConnection? = nil
local combatAcc = 0
local nextFishId = 1
local tangTemplate: Instance? = nil
local greenArrowsTemplate: Instance? = nil
local arrowPreviews: { ArrowPreview } = {}
local wavePathLabels: { WavePathLabel } = {}
local arrowsWarned = false
local hudListeners: { (HudSnapshot) -> () } = {}
local stopListeners: { (Summary) -> () } = {}
local fishRng = Random.new()
local feedPitchCursor = C.FEED_PITCH_MIN

local function fishWorldOffset(agent: FishAgent, pos: Vector3, tang: Vector3, atDist: number?): Vector3
	local side = Vector3.new(-tang.Z, 0, tang.X)
	if side.Magnitude > 1e-4 then
		side = side.Unit
	else
		side = Vector3.new(1, 0, 0)
	end
	local d = atDist or agent.dist
	-- Slow dual-harmonic jitter (path distance → gentle sway).
	local lat = agent.lateral
		+ agent.wanderAmp * math.sin(d * agent.wanderFreq + agent.wanderPhase)
		+ agent.wanderAmp * 0.4 * math.sin(d * agent.wanderFreq * 1.55 + agent.wanderPhase * 1.3)
	local up = agent.vert
		+ agent.bobAmp * math.sin(d * agent.bobFreq + agent.bobPhase)
		+ agent.bobAmp * 0.35 * math.sin(d * agent.bobFreq * 1.4 + agent.bobPhase + 2.0)
	return pos + side * lat + Vector3.yAxis * up
end

local hudDirty = false
local lastHudWave = -1
local lastHudReef = -1
local lastHudSec = -1
local lastHudFeed = -1
local lastHudFeedDone = false
local lastHudDanger = false
local lastHudMissToken = 0
local hungryMissToken = 0
local lastHudFishFull = -1

local function tangHungerForWave(wave: number): number
	if wave <= C.EARLY_HUNGER_WAVE_MAX then
		return C.TANG_HUNGER_EARLY
	end
	return C.TANG_HUNGER
end

local function notifyHud()
	hudDirty = true
end

local function anyHungerDanger(): boolean
	for _, f in ipairs(fishList) do
		if not f.finished and f.dangerActive then
			return true
		end
	end
	return false
end

local function getFishFullCounts(): (number, number)
	local per = tangHungerForWave(waveIndex)
	local full = math.floor(waveFedUnits / math.max(1, per) + 0.5)
	for _, f in ipairs(fishList) do
		if not f.finished and f.hunger >= f.maxHunger then
			full += 1
		end
	end
	return full, waveFishExpected
end

local function getFeedProgress(): (number, boolean)
	if not running or waveFishExpected <= 0 then
		return 0, false
	end
	local total = waveFishExpected * tangHungerForWave(waveIndex)
	if total <= 0 then
		return 0, false
	end
	local filled = waveFedUnits
	local anyHungryAlive = false
	for _, f in ipairs(fishList) do
		if not f.finished then
			filled += math.min(f.hunger, f.maxHunger)
			if f.hunger < f.maxHunger then
				anyHungryAlive = true
			end
		end
	end
	local progress = math.clamp(filled / total, 0, 1)
	local complete = (not waveSpawning)
		and spawnQueue <= 0
		and (not anyHungryAlive)
		and progress >= 0.999
	return progress, complete
end

local function flushHud()
	local elapsed = if running then os.clock() - startedAt else 0
	local sec = math.floor(elapsed)
	local feedProg, feedDone = getFeedProgress()
	local danger = anyHungerDanger()
	local fishFull, fishTotal = getFishFullCounts()
	local secTick = running and sec ~= lastHudSec
	if not hudDirty and not secTick then
		return
	end
	hudDirty = false
	if not secTick
		and running
		and waveIndex == lastHudWave
		and reefHealth == lastHudReef
		and math.abs(feedProg - lastHudFeed) < 0.002
		and feedDone == lastHudFeedDone
		and danger == lastHudDanger
		and hungryMissToken == lastHudMissToken
		and fishFull == lastHudFishFull
	then
		return
	end
	lastHudWave = waveIndex
	lastHudReef = reefHealth
	lastHudSec = sec
	lastHudFeed = feedProg
	lastHudFeedDone = feedDone
	lastHudDanger = danger
	lastHudMissToken = hungryMissToken
	lastHudFishFull = fishFull
	local snap: HudSnapshot = {
		wave = waveIndex,
		reefHealth = reefHealth,
		reefMax = reefMaxHealth,
		elapsedSec = elapsed,
		running = running,
		feedProgress = feedProg,
		feedComplete = feedDone,
		hungerDanger = danger,
		hungryMissToken = hungryMissToken,
		fishFull = fishFull,
		fishTotal = fishTotal,
	}
	for _, cb in ipairs(hudListeners) do
		cb(snap)
	end
end

local function fireStopped(summary: Summary)
	for _, cb in ipairs(stopListeners) do
		cb(summary)
	end
end

local function clearHash()
	table.clear(hash)
end

local function insertHash(coral: CoralAgent)
	local p = coral.part.Position
	local r = C.TARGET_RANGE
	local x0 = math.floor((p.X - r) / C.HASH_CELL)
	local x1 = math.floor((p.X + r) / C.HASH_CELL)
	local z0 = math.floor((p.Z - r) / C.HASH_CELL)
	local z1 = math.floor((p.Z + r) / C.HASH_CELL)
	coral.hashKeys = {}
	for cx = x0, x1 do
		for cz = z0, z1 do
			local k = cx * 73856093 + cz * 19349663
			local bucket = hash[k]
			if not bucket then
				bucket = {}
				hash[k] = bucket
			end
			table.insert(bucket, coral)
			table.insert(coral.hashKeys, k)
		end
	end
end

local function ensureFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "OceanTD_LocalWaves"
	f.Parent = Workspace
	folder = f
	return f
end

WaveEndVfx.bind(ensureFolder)

local function quadBezier(w0: Vector3, c: Vector3, w1: Vector3, t: number): Vector3
	local u = 1 - t
	return w0 * (u * u) + c * (2 * u * t) + w1 * (t * t)
end

-- Derivative of quadratic Bezier (direction of travel along the curve).
local function quadBezierTangent(w0: Vector3, c: Vector3, w1: Vector3, t: number): Vector3
	local d = (c - w0) * (2 * (1 - t)) + (w1 - c) * (2 * t)
	if d.Magnitude < 1e-5 then
		d = w1 - w0
	end
	if d.Magnitude < 1e-5 then
		return Vector3.new(0, 0, -1)
	end
	return d.Unit
end

-- Stable unit blend; avoids collapse when adjacent tangents are nearly opposite.
local function blendUnitTangents(a: Vector3, b: Vector3, u: number): Vector3
	local t = math.clamp(u, 0, 1)
	t = t * t * (3 - 2 * t) -- smoothstep
	if a:Dot(b) < -0.92 then
		return if t < 0.5 then a else b
	end
	local v = a:Lerp(b, t)
	if v.Magnitude < 1e-5 then
		return if t < 0.5 then a else b
	end
	return v.Unit
end

local function findIndexedPart(folder: Instance, prefix: string, index: number): BasePart?
	local name = prefix .. tostring(index)
	local inst = folder:FindFirstChild(name)
	if inst and inst:IsA("BasePart") then
		return inst
	end
	-- Fallback: scan (handles odd nesting / renames with spaces).
	for _, ch in ipairs(folder:GetDescendants()) do
		if ch:IsA("BasePart") and ch.Name == name then
			return ch
		end
	end
	return nil
end

local function estimateSegLength(w0: Vector3, c: Vector3, w1: Vector3): number
	local samples = math.max(8, math.ceil(((w1 - w0).Magnitude + (c - w0).Magnitude + (w1 - c).Magnitude) / C.PATH_SAMPLE_STEP))
	local len = 0
	local prev = w0
	for s = 1, samples do
		local p = quadBezier(w0, c, w1, s / samples)
		len += (p - prev).Magnitude
		prev = p
	end
	return math.max(len, 0.01)
end

local function buildPath(): PathData?
	local root = Workspace:FindFirstChild("WaveRoute")
	if not root then
		warn("[WAVE] Workspace.WaveRoute missing")
		return nil
	end
	local route = root:FindFirstChild("A")
	if not route then
		warn("[WAVE] WaveRoute.A missing")
		return nil
	end
	local wpFolder = route:FindFirstChild("Waypoints")
	local ctrlFolder = route:FindFirstChild("Controls")
	if not wpFolder or not ctrlFolder then
		warn("[WAVE] Waypoints/Controls missing")
		return nil
	end

	-- Ordered W1, W2, W3... until a gap (never sort GetChildren — avoids zigzag from bad order).
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
		warn("[WAVE] Need W1..Wn (at least 2); found", #waypoints)
		return nil
	end

	local segments: { PathSegment } = {}
	local total = 0
	for s = 1, #waypoints - 1 do
		local ctrl = findIndexedPart(ctrlFolder, "C", s)
		if not ctrl then
			warn("[WAVE] Missing control C" .. tostring(s) .. " for segment W" .. tostring(s) .. "→W" .. tostring(s + 1))
			return nil
		end
		local w0 = waypoints[s].Position
		local w1 = waypoints[s + 1].Position
		local c = ctrl.Position
		local length = estimateSegLength(w0, c, w1)
		table.insert(segments, {
			w0 = w0,
			c = c,
			w1 = w1,
			length = length,
			cumStart = total,
			inTang = quadBezierTangent(w0, c, w1, 0),
			outTang = quadBezierTangent(w0, c, w1, 1),
		})
		total += length
	end

	local waypointDists: { number } = { 0 }
	for s = 1, #segments do
		table.insert(waypointDists, segments[s].cumStart + segments[s].length)
	end

	print("[WAVE] Path ready:", #waypoints, "waypoints,", #segments, "curve segments, len=", string.format("%.1f", total))
	return {
		segments = segments,
		totalLen = total,
		endPos = waypoints[#waypoints].Position,
		waypointDists = waypointDists,
	}
end

local function samplePath(path: PathData, dist: number): (Vector3, Vector3)
	local d = math.clamp(dist, 0, path.totalLen)
	local segs = path.segments
	if #segs == 0 then
		return Vector3.zero, Vector3.new(0, 0, -1)
	end
	local lo = 1
	local hi = #segs
	while lo < hi do
		local mid = (lo + hi) // 2
		local s = segs[mid]
		if d > s.cumStart + s.length then
			lo = mid + 1
		else
			hi = mid
		end
	end
	local seg = segs[lo]
	local t = if seg.length > 1e-5 then math.clamp((d - seg.cumStart) / seg.length, 0, 1) else 0
	local pos = quadBezier(seg.w0, seg.c, seg.w1, t)
	local tang = quadBezierTangent(seg.w0, seg.c, seg.w1, t)

	-- Independent W/C quads are only G0 at waypoints — blend heading into the next
	-- segment so lateral school offsets don't snap when the tangent jumps.
	local toEnd = seg.cumStart + seg.length - d
	if toEnd < C.TANGENT_BLEND_STUDS and lo < #segs then
		local blend = 1 - math.clamp(toEnd / C.TANGENT_BLEND_STUDS, 0, 1)
		tang = blendUnitTangents(tang, segs[lo + 1].inTang, blend)
	end
	return pos, tang
end

-- 1-based segment index along the route (W_i → W_{i+1}).
local function pathSegmentIndex(path: PathData, dist: number): number
	local d = math.clamp(dist, 0, path.totalLen)
	local segs = path.segments
	if #segs == 0 then
		return 1
	end
	local lo = 1
	local hi = #segs
	while lo < hi do
		local mid = (lo + hi) // 2
		local s = segs[mid]
		if d > s.cumStart + s.length then
			lo = mid + 1
		else
			hi = mid
		end
	end
	return lo
end

-- Final two waypoints ≈ last two curve segments.
local function isOnFinalTwoWaypoints(path: PathData, dist: number): boolean
	local n = #path.segments
	if n <= 0 then
		return false
	end
	return pathSegmentIndex(path, dist) >= math.max(1, n - 1)
end

local function getTangTemplate(): Instance?
	if tangTemplate and tangTemplate.Parent then
		return tangTemplate
	end
	local fishFolder = ReplicatedStorage:FindFirstChild("Fish")
	if not fishFolder then
		warn("[WAVE] ReplicatedStorage.Fish missing")
		return nil
	end
	local tang = fishFolder:FindFirstChild("Tang")
	if not tang then
		warn("[WAVE] ReplicatedStorage.Fish.Tang missing")
		return nil
	end
	tangTemplate = tang
	return tang
end

local function getGreenArrowsTemplate(): Instance?
	if greenArrowsTemplate and greenArrowsTemplate.Parent then
		return greenArrowsTemplate
	end
	local arrows = ReplicatedStorage:FindFirstChild("GreenArrows")
	if not arrows then
		if not arrowsWarned then
			arrowsWarned = true
			warn("[WAVE] ReplicatedStorage.GreenArrows missing")
		end
		return nil
	end
	greenArrowsTemplate = arrows
	return arrows
end

local function findPrimary(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") then
		if inst.PrimaryPart then
			return inst.PrimaryPart
		end
		return inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return inst:FindFirstChildWhichIsA("BasePart", true)
end

local function prepareLocalFxInstance(inst: Instance)
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.CastShadow = false
		end
	end
	if inst:IsA("BasePart") then
		inst.Anchored = true
		inst.CanCollide = false
		inst.CanTouch = false
		inst.CanQuery = false
		inst.CastShadow = false
	end
end

local function setArrowCFrame(model: Instance, pos: Vector3, tang: Vector3, spin: number)
	local move = if tang.Magnitude > 1e-5 then tang.Unit else Vector3.new(0, 0, -1)
	-- Face along path (yaw flip), stand like a fence (roll), corkscrew via spin.
	local look = CFrame.lookAt(pos, pos + move, Vector3.yAxis)
	local desired = look * CFrame.Angles(0, C.ARROW_YAW, C.ARROW_ROLL + spin)
	if model:IsA("Model") then
		model:PivotTo(desired)
	elseif model:IsA("BasePart") then
		model.CFrame = desired
	else
		local root = findPrimary(model)
		if root then
			local old = root.CFrame
			root.CFrame = desired
			local delta = desired * old:Inverse()
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") and d ~= root then
					d.CFrame = delta * d.CFrame
				end
			end
		end
	end
end

local function destroyArrowPreview()
	for _, preview in ipairs(arrowPreviews) do
		if preview.model.Parent then
			preview.model:Destroy()
		end
	end
	table.clear(arrowPreviews)
	for _, label in ipairs(wavePathLabels) do
		if label.part.Parent then
			label.part:Destroy()
		end
	end
	table.clear(wavePathLabels)
end

local function playArrowStartSound()
	local snd = arrowSound:Clone()
	snd.Volume = 0.9
	snd.Parent = SoundService
	snd:Play()
	local ttl = math.max(1.5, (snd.TimeLength > 0 and snd.TimeLength or 1.2) + 0.4)
	task.delay(ttl, function()
		if snd.Parent then
			snd:Destroy()
		end
	end)
end

local function cloneGreenArrowsSet(tmpl: Instance, name: string): Instance
	local clone = tmpl:Clone()
	clone.Name = name
	if clone:IsA("Folder") then
		local model = Instance.new("Model")
		model.Name = name
		for _, ch in ipairs(clone:GetChildren()) do
			ch.Parent = model
		end
		clone:Destroy()
		clone = model
	end
	prepareLocalFxInstance(clone)
	if clone:IsA("Model") then
		local root = findPrimary(clone)
		if root and not clone.PrimaryPart then
			clone.PrimaryPart = root
		end
	end
	return clone
end

local function createWavePathLabel(text: string, pos: Vector3, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = "OceanTD_WaveLabel"
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
	lbl.Font = UiTheme.Font -- FredokaOne (project default)
	lbl.Text = text
	lbl.TextColor3 = Color3.fromRGB(40, 255, 120)
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.25
	lbl.TextStrokeColor3 = Color3.fromRGB(0, 40, 15)
	lbl.Parent = bb

	return part
end

local function startWaveArrowPreview()
	destroyArrowPreview()
	local path = pathData
	local tmpl = getGreenArrowsTemplate()
	if not path or not tmpl then
		return
	end
	playArrowStartSound()
	local folderFx = ensureFolder()
	local waveText = "Wave " .. tostring(math.max(1, waveIndex))

	-- GreenArrow sets along the full path; "Wave N" on every 4th set.
	local d = 0
	local i = 0
	while d < path.totalLen - 0.05 do
		i += 1
		local clone = cloneGreenArrowsSet(tmpl, "OceanTD_GreenArrows_" .. tostring(i))
		clone.Parent = folderFx
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
		destroyArrowPreview()
		return
	end
	local speed = C.FISH_SPEED * C.ARROW_SPEED_MULT
	for i = #arrowPreviews, 1, -1 do
		local preview = arrowPreviews[i]
		if not preview.alive or not preview.model.Parent then
			if preview.model.Parent then
				preview.model:Destroy()
			end
			table.remove(arrowPreviews, i)
			continue
		end
		preview.dist += speed * dt
		preview.spin += C.ARROW_SPIN_RAD_PER_SEC * dt
		if preview.dist >= path.totalLen then
			preview.alive = false
			preview.model:Destroy()
			table.remove(arrowPreviews, i)
			continue
		end
		local pos, tang = samplePath(path, preview.dist)
		setArrowCFrame(preview.model, pos, tang, preview.spin)
	end

	for i = #wavePathLabels, 1, -1 do
		local label = wavePathLabels[i]
		if not label.alive or not label.part.Parent then
			if label.part.Parent then
				label.part:Destroy()
			end
			table.remove(wavePathLabels, i)
			continue
		end
		label.dist += speed * dt
		if label.dist >= path.totalLen then
			label.alive = false
			label.part:Destroy()
			table.remove(wavePathLabels, i)
			continue
		end
		local pos = samplePath(path, label.dist)
		label.part.CFrame = CFrame.new(pos)
	end
end

local function setFishCFrame(agent: FishAgent, pos: Vector3, pathTang: Vector3, dt: number)
	-- Prefer actual swim velocity (path + wander) so the mouth leads the motion.
	local move = pos - agent.lastWorld
	if move.Magnitude < 0.02 then
		move = pathTang
	end
	if move.Magnitude < 1e-5 then
		move = agent.smoothTang
	end
	if move.Magnitude < 1e-5 then
		move = Vector3.new(0, 0, -1)
	else
		move = move.Unit
	end
	agent.lastWorld = pos

	local prev = agent.smoothTang
	if prev.Magnitude > 1e-5 then
		local alpha = 1 - math.exp(-C.TURN_RATE * math.max(dt, 1e-4))
		local blended = prev:Lerp(move, alpha)
		if blended.Magnitude > 1e-5 then
			move = blended.Unit
		end
	end
	agent.smoothTang = move

	-- Same as GreenArrows: look along swim dir, then fixed authored yaw/pitch/roll.
	local desired = CFrame.lookAt(pos, pos + move, Vector3.yAxis)
		* CFrame.Angles(C.TANG_PITCH, C.TANG_YAW, C.TANG_ROLL)

	local model = agent.model
	if model:IsA("Model") then
		model:PivotTo(desired)
	elseif model:IsA("BasePart") then
		model.CFrame = desired
	else
		local oldRoot = agent.root.CFrame
		agent.root.CFrame = desired
		local delta = desired * oldRoot:Inverse()
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d ~= agent.root then
				d.CFrame = delta * d.CFrame
			end
		end
	end
end

local function makeHungerBillboard(adornee: BasePart): (BillboardGui, Frame, Frame, TextLabel, TextLabel, UIScale)
	local totalW = C.HUNGER_EMOJI_SIZE + C.HUNGER_BAR_GAP + C.HUNGER_BAR_PX_W
	local bb = Instance.new("BillboardGui")
	bb.Name = "HungerBar"
	bb.Size = UDim2.fromOffset(totalW, C.HUNGER_BAR_PX_H)
	bb.StudsOffset = Vector3.new(0, C.HUNGER_BAR_HEIGHT, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = C.HUNGER_BAR_MAX_DIST
	bb.Adornee = adornee
	bb.Parent = adornee

	-- Bar on the right; emoji sits outside in front (left), 3x bar height.
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
	fill.BackgroundTransparency = 0
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
	fork.Size = UDim2.fromOffset(C.HUNGER_EMOJI_SIZE, C.HUNGER_EMOJI_SIZE)
	fork.Font = Enum.Font.SourceSansBold
	fork.Text = "🍴"
	fork.TextSize = C.HUNGER_EMOJI_SIZE
	fork.TextScaled = false
	fork.ZIndex = 4
	fork.Parent = bb

	local happy = Instance.new("TextLabel")
	happy.Name = "Happy"
	happy.BackgroundTransparency = 1
	happy.AnchorPoint = Vector2.new(0, 0.5)
	happy.Position = UDim2.new(0, 0, 0.5, 0)
	happy.Size = UDim2.fromOffset(C.HUNGER_EMOJI_SIZE, C.HUNGER_EMOJI_SIZE)
	happy.Font = Enum.Font.SourceSansBold
	happy.Text = "😊"
	happy.TextSize = C.HUNGER_EMOJI_SIZE
	happy.TextScaled = false
	happy.Visible = false
	happy.ZIndex = 5
	happy.Parent = bb

	return bb, fill, barHost, fork, happy, scale
end

local function setDangerFlash(agent: FishAgent, enable: boolean)
	if agent.dangerActive == enable then
		return
	end
	agent.dangerActive = enable
	agent.dangerToken += 1
	notifyHud()
	if agent.billboard and agent.billboard.Parent then
		-- Keep red-flashing bars visible when zoomed far out (skip LOD hide).
		agent.billboard.MaxDistance = if enable then C.HUNGER_BAR_DANGER_MAX_DIST else C.HUNGER_BAR_MAX_DIST
	end
	if not enable then
		if agent.hunger < agent.maxHunger and agent.fill.Parent then
			agent.fill.BackgroundColor3 = C.FILL_GREEN
			if agent.barStroke then
				agent.barStroke.Color = Color3.new(1, 1, 1)
			end
		end
		return
	end
	local my = agent.dangerToken
	task.spawn(function()
		while agent.dangerToken == my
			and not agent.finished
			and agent.hunger < agent.maxHunger
			and agent.model.Parent
		do
			agent.fill.BackgroundColor3 = C.DANGER_RED
			if agent.barStroke then
				agent.barStroke.Color = C.DANGER_RED
			end
			task.wait(0.28)
			if agent.dangerToken ~= my or agent.finished then
				return
			end
			agent.fill.BackgroundColor3 = C.FILL_GREEN
			if agent.barStroke then
				agent.barStroke.Color = Color3.new(1, 1, 1)
			end
			task.wait(0.28)
		end
	end)
end

local function playFeedSound()
	local pitch = feedPitchCursor
	feedPitchCursor += C.FEED_PITCH_STEP
	if feedPitchCursor > C.FEED_PITCH_MAX then
		feedPitchCursor = C.FEED_PITCH_MIN
	end
	local snd = feedSound:Clone()
	snd.PlaybackSpeed = pitch
	snd.Volume = 0.85
	snd.Parent = SoundService
	snd:Play()
	local ttl = math.max(0.8, (snd.TimeLength > 0 and snd.TimeLength or 0.5) / math.max(0.2, pitch) + 0.25)
	task.delay(ttl, function()
		if snd.Parent then
			snd:Destroy()
		end
	end)
end

local function startHappyFlash(agent: FishAgent)
	agent.pulseToken += 1
	agent.dangerToken += 1
	agent.dangerActive = false
	local my = agent.pulseToken
	agent.happyLabel.Text = C.HAPPY_EMOJIS[fishRng:NextInteger(1, #C.HAPPY_EMOJIS)]
	task.spawn(function()
		while agent.pulseToken == my and not agent.finished and agent.model.Parent do
			agent.happyLabel.Visible = true
			task.wait(C.HAPPY_FLASH_ON)
			if agent.pulseToken ~= my or agent.finished then
				return
			end
			agent.happyLabel.Visible = false
			task.wait(C.HAPPY_FLASH_OFF)
		end
	end)
end

local function updateHungerVisual(agent: FishAgent)
	local u = agent.hunger / agent.maxHunger
	agent.fill.Size = UDim2.fromScale(math.clamp(u, 0, 1), 1)
	if agent.hunger >= agent.maxHunger then
		agent.barFrame.Visible = false
		agent.forkLabel.Visible = false
		setDangerFlash(agent, false)
		startHappyFlash(agent)
	else
		agent.pulseToken += 1
		agent.barFrame.Visible = true
		agent.forkLabel.Visible = true
		agent.happyLabel.Visible = false
		if not agent.dangerActive then
			agent.fill.BackgroundColor3 = C.FILL_GREEN
		end
	end
	notifyHud()
end

local function destroyAmmo(coral: CoralAgent)
	if coral.ammo then
		coral.ammo:Destroy()
		coral.ammo = nil
	end
	-- Do not clear coral.growing here — createAmmo calls this while starting a grow.
end

local function ammoWorldPos(coral: CoralAgent): Vector3
	local r = coral.diameter * 0.5
	return coral.part.Position + Vector3.new(0, r + C.AMMO_RADIUS, 0)
end

local function createAmmo(coral: CoralAgent, scale: number)
	if coral.ammo and coral.ammo.Parent then
		coral.ammo:Destroy()
		coral.ammo = nil
	end
	local p = Instance.new("Part")
	p.Name = "OceanTD_CoralAmmo"
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Color = coral.color
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	local s = C.AMMO_RADIUS * 2 * math.clamp(scale, 0.08, 1)
	p.Size = Vector3.new(s, s, s)
	p.CFrame = CFrame.new(ammoWorldPos(coral))
	p.Parent = ensureFolder()
	coral.ammo = p
end

local function startAmmoGrow(coral: CoralAgent)
	createAmmo(coral, 0.08)
	coral.growing = true
	coral.growT0 = os.clock()
	coral.readyAt = math.huge
end

local function tickAmmoGrow(now: number)
	for _, coral in ipairs(coralList) do
		if not coral.growing then
			continue
		end
		local reload = math.max(0.05, coral.reloadSec)
		local u = (now - coral.growT0) / reload
		if u >= 1 then
			coral.growing = false
			coral.readyAt = now
			if coral.ammo and coral.ammo.Parent then
				local s = C.AMMO_RADIUS * 2
				coral.ammo.Size = Vector3.new(s, s, s)
				coral.ammo.CFrame = CFrame.new(ammoWorldPos(coral))
			else
				createAmmo(coral, 1)
			end
		elseif coral.ammo and coral.ammo.Parent then
			local s = C.AMMO_RADIUS * 2 * math.max(0.08, u)
			coral.ammo.Size = Vector3.new(s, s, s)
			coral.ammo.CFrame = CFrame.new(ammoWorldPos(coral))
		end
	end
end

local function acquireFoodPart(): BasePart
	local p = table.remove(foodPool)
	if p and p.Parent then
		p.Transparency = 0
		return p
	end
	local n = Instance.new("Part")
	n.Name = "OceanTD_FoodOrb"
	n.Shape = Enum.PartType.Ball
	n.Material = Enum.Material.Neon
	n.Anchored = true
	n.CanCollide = false
	n.CanQuery = false
	n.CanTouch = false
	n.CastShadow = false
	n.Size = Vector3.new(C.FOOD_RADIUS * 2, C.FOOD_RADIUS * 2, C.FOOD_RADIUS * 2)
	n.Parent = ensureFolder()
	return n
end

local function releaseFoodPart(p: BasePart)
	p.Transparency = 1
	p.CFrame = CFrame.new(0, -1000, 0)
	if #foodPool < 64 then
		table.insert(foodPool, p)
	else
		p:Destroy()
	end
end

local function makeCoralAgent(part: BasePart): CoralAgent?
	if typeof(part:GetAttribute("OceanTD_GhostBaseR")) == "number" then
		return nil
	end
	local itemId = part:GetAttribute("OceanTD_ItemId")
	local speciesId = part:GetAttribute("OceanTD_SpeciesId")
	local id = if typeof(itemId) == "string" and itemId ~= "" then itemId
		elseif typeof(speciesId) == "string" and speciesId ~= "" then speciesId
		elseif part.Name ~= "" and ItemCatalog.get(part.Name) then part.Name
		else nil
	if not id then
		return nil
	end
	local item = ItemCatalog.get(id)
	local species = SpeciesCatalog.get(if typeof(speciesId) == "string" then speciesId else id)
		or (if item then SpeciesCatalog.get(item.speciesId) else nil)
	local reload = C.DEFAULT_RELOAD
	local fillAmt = C.DEFAULT_FOOD_FILL
	local diameter = part.Size.Y
	if species then
		reload = species.reloadSec or C.DEFAULT_RELOAD
		fillAmt = species.foodFill or C.DEFAULT_FOOD_FILL
		diameter = species.diameter
	end
	return {
		part = part,
		color = select(2, CoralVisual.readRestLook(part)),
		reloadSec = reload,
		foodFill = fillAmt,
		diameter = diameter,
		readyAt = 0,
		ammo = nil,
		growing = false,
		growT0 = 0,
		busy = false,
		hashKeys = {},
		pathDist = 0,
		pathSideDist = 0,
	}
end

local function gatherPlotCoralParts(): { BasePart }
	local parts: { BasePart } = {}
	local seen: { [BasePart]: boolean } = {}
	local root = Workspace:FindFirstChild("OceanTD_Placed")
	if not root then
		return parts
	end
	local function consider(inst: Instance)
		if not inst:IsA("BasePart") or seen[inst] then
			return
		end
		local agent = makeCoralAgent(inst)
		if not agent then
			return
		end
		seen[inst] = true
		table.insert(parts, inst)
	end
	local mirrored = ClientPlot.get()
	local plotFolder = if mirrored then root:FindFirstChild(mirrored.plotId) else nil
	if plotFolder then
		for _, inst in ipairs(plotFolder:GetDescendants()) do
			consider(inst)
		end
	end
	for _, inst in ipairs(root:GetDescendants()) do
		consider(inst)
	end
	return parts
end

local function projectPointOntoPath(path: PathData, worldPos: Vector3): (number, number)
	local bestD2 = math.huge
	local bestDist = 0
	local d = 0
	local step = C.PATH_PROJECT_STEP
	while d <= path.totalLen do
		local p = samplePath(path, d)
		local dx = p.X - worldPos.X
		local dy = p.Y - worldPos.Y
		local dz = p.Z - worldPos.Z
		local d2 = dx * dx + dy * dy + dz * dz
		if d2 < bestD2 then
			bestD2 = d2
			bestDist = d
		end
		d += step
	end
	local pEnd = samplePath(path, path.totalLen)
	local ex = pEnd.X - worldPos.X
	local ey = pEnd.Y - worldPos.Y
	local ez = pEnd.Z - worldPos.Z
	local endD2 = ex * ex + ey * ey + ez * ez
	if endD2 < bestD2 then
		bestD2 = endD2
		bestDist = path.totalLen
	end
	return bestDist, math.sqrt(bestD2)
end

local function refreshCoralPathProjections()
	local path = pathData
	if not path then
		return
	end
	for _, c in ipairs(coralList) do
		local pd, side = projectPointOntoPath(path, c.part.Position)
		c.pathDist = pd
		c.pathSideDist = side
	end
end

-- Keep coral reload/ammo state across waves. Only arm new places; remove destroyed.
local function syncCorals(sessionStart: boolean)
	local liveParts = gatherPlotCoralParts()
	local liveSet: { [BasePart]: boolean } = {}
	for _, p in ipairs(liveParts) do
		liveSet[p] = true
	end

	for i = #coralList, 1, -1 do
		local c = coralList[i]
		if not c.part.Parent or not liveSet[c.part] then
			c.growing = false
			c.busy = false
			destroyAmmo(c)
			table.remove(coralList, i)
		end
	end

	local known: { [BasePart]: boolean } = {}
	for _, c in ipairs(coralList) do
		known[c.part] = true
	end

	for _, part in ipairs(liveParts) do
		if not known[part] then
			local c = makeCoralAgent(part)
			if c then
				table.insert(coralList, c)
				-- New coral (session start or mid-wave place): spawn food and ready to shoot.
				createAmmo(c, 1)
				c.readyAt = 0
				c.busy = false
				c.growing = false
				local path = pathData
				if path then
					local pd, side = projectPointOntoPath(path, part.Position)
					c.pathDist = pd
					c.pathSideDist = side
				end
			end
		elseif sessionStart then
			-- First wave only: ensure existing corals have a full ammo orb if idle.
			local c: CoralAgent? = nil
			for _, existing in ipairs(coralList) do
				if existing.part == part then
					c = existing
					break
				end
			end
			if c and not c.busy and not c.growing then
				createAmmo(c, 1)
				c.readyAt = 0
			end
		end
	end

	clearHash()
	for _, c in ipairs(coralList) do
		-- Prefer rest look for shot color (ignore transient hover/relocate neon wash).
		local _, restColor = CoralVisual.readRestLook(c.part)
		c.color = restColor
		insertHash(c)
	end
	-- Full reproject only when arming a wave session (path is live); new places project above.
	if sessionStart then
		refreshCoralPathProjections()
	end
end

local function countAliveFish(): number
	local n = 0
	for _, f in ipairs(fishList) do
		if not f.finished then
			n += 1
		end
	end
	return n
end

local function destroyFish(agent: FishAgent)
	agent.finished = true
	agent.pulseToken += 1
	agent.dangerToken += 1
	agent.dangerActive = false
	if agent.model.Parent then
		agent.model:Destroy()
	end
end

local function finishFish(agent: FishAgent)
	if agent.finished then
		return
	end
	local empty = agent.maxHunger - agent.hunger
	if empty > 0 then
		local dealt = math.min(empty, reefHealth)
		reefHealth = math.max(0, reefHealth - empty)
		local endPos = if pathData then pathData.endPos else nil
		WaveEndVfx.playReefHealthTicks(dealt, endPos)
		hungryMissToken += 1
		if dealt > 0 then
			UiHaptics.pulseReef()
		end
	else
		fishFed += 1
		waveFedUnits += agent.maxHunger
		local emoji = agent.happyLabel.Text
		if emoji == "" then
			emoji = C.HAPPY_EMOJIS[1]
		end
		local endPos = if pathData then pathData.endPos else nil
		if not endPos then
			local heart = WaveEndVfx.getEndHeartPart()
			if heart then
				endPos = heart.Position
			end
		end
		if endPos then
			WaveEndVfx.pulseHappyExit(emoji, endPos)
		end
	end
	destroyFish(agent)
	notifyHud()
end

local function spawnOneFish(spawnIndex: number)
	local path = pathData
	local tmpl = getTangTemplate()
	if not path or not tmpl then
		return
	end
	local clone = tmpl:Clone()
	clone.Name = "Tang_" .. tostring(nextFishId)
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.CastShadow = false
		end
	end
	if clone:IsA("BasePart") then
		clone.Anchored = true
		clone.CanCollide = false
		clone.CanQuery = false
		clone.CanTouch = false
	end
	clone.Parent = ensureFolder()
	local root = findPrimary(clone)
	if not root then
		clone:Destroy()
		return
	end
	if clone:IsA("Model") and not clone.PrimaryPart then
		clone.PrimaryPart = root
	end
	-- Wide random school placement (no tight 5-lane file).
	local lateral = fishRng:NextNumber(-C.LATERAL_SPREAD, C.LATERAL_SPREAD)
	local vert = fishRng:NextNumber(-C.VERT_SPREAD, C.VERT_SPREAD)
	local bobAmp = fishRng:NextNumber(C.BOB_AMP_MIN, C.BOB_AMP_MAX)
	local bobFreq = fishRng:NextNumber(0.012, 0.032) -- slow vertical jitter
	local bobPhase = fishRng:NextNumber(0, math.pi * 2)
	local wanderAmp = fishRng:NextNumber(C.WANDER_AMP_MIN, C.WANDER_AMP_MAX)
	local wanderFreq = fishRng:NextNumber(0.014, 0.038) -- slow side jitter
	local wanderPhase = fishRng:NextNumber(0, math.pi * 2)
	local speedPhase = fishRng:NextNumber(0, math.pi * 2)
	local speedFreq = fishRng:NextNumber(0.22, 0.55) -- slow surge/coast over the wave
	local pos, tang = samplePath(path, 0)
	local agent: FishAgent = {
		id = nextFishId,
		root = root,
		model = clone,
		dist = 0,
		lateral = lateral,
		vert = vert,
		bobAmp = bobAmp,
		bobFreq = bobFreq,
		bobPhase = bobPhase,
		wanderAmp = wanderAmp,
		wanderFreq = wanderFreq,
		wanderPhase = wanderPhase,
		speedPhase = speedPhase,
		speedFreq = speedFreq,
		hunger = 0,
		maxHunger = tangHungerForWave(waveIndex),
		finished = false,
		billboard = nil :: any,
		fill = nil :: any,
		barFrame = nil :: any,
		forkLabel = nil :: any,
		happyLabel = nil :: any,
		barScale = nil :: any,
		barStroke = nil :: any,
		pulseToken = 0,
		dangerToken = 0,
		dangerActive = false,
		smoothTang = tang.Magnitude > 1e-5 and tang.Unit or Vector3.new(0, 0, -1),
		lastWorld = pos,
		incomingFood = 0,
	}
	nextFishId += 1
	local bb, fill, barFrame, forkLabel, happyLabel, barScale = makeHungerBillboard(root)
	agent.billboard = bb
	agent.fill = fill
	agent.barFrame = barFrame
	agent.forkLabel = forkLabel
	agent.happyLabel = happyLabel
	agent.barScale = barScale
	local bg = barFrame:FindFirstChild("Bg")
	if bg then
		local stroke = bg:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			agent.barStroke = stroke
		end
	end
	local world0 = fishWorldOffset(agent, pos, tang)
	agent.lastWorld = world0
	setFishCFrame(agent, world0, tang, 1)
	table.insert(fishList, agent)
end

local function waveFishCount(wave: number): number
	return C.WAVE1_COUNT + (wave - 1) * C.WAVE_COUNT_STEP
end

local function beginWave(wave: number)
	waveIndex = wave
	waveFishExpected = waveFishCount(wave)
	waveFedUnits = 0
	-- Path preview: GreenArrows race the full route; fish follow 1s later.
	startWaveArrowPreview()
	waveSpawning = true
	spawnQueue = waveFishCount(wave)
	spawnDelay = C.ARROW_LEAD_SEC
	-- Session start: arm all corals. Later waves: keep reload state; only pick up new places.
	syncCorals(wave == 1)
	local path = pathData
	if path and #path.segments > 0 then
		WaveStartVfx.play(wave, path.segments[1].w0)
	end
	notifyHud()
end

local function rebuildFishPathBuckets()
	for i = 1, #fishPathBuckets do
		table.clear(fishPathBuckets[i])
	end
	local path = pathData
	if not path or path.totalLen < 1 then
		return
	end
	local maxBi = math.max(1, math.ceil(path.totalLen / C.PATH_BUCKET_SIZE) + 1)
	while #fishPathBuckets < maxBi do
		table.insert(fishPathBuckets, {})
	end
	for _, f in ipairs(fishList) do
		-- Skip if already full or in-flight food will fill them.
		if f.finished or f.hunger + f.incomingFood >= f.maxHunger then
			continue
		end
		local bi = math.clamp(math.floor(f.dist / C.PATH_BUCKET_SIZE) + 1, 1, maxBi)
		table.insert(fishPathBuckets[bi], f)
	end
end

local function fishNeedsFood(f: FishAgent, fill: number): boolean
	return (not f.finished) and (f.hunger + f.incomingFood + fill <= f.maxHunger)
end

local function findClosestHungryFish(coral: CoralAgent): FishAgent?
	local path = pathData
	if not path then
		return nil
	end
	-- Too far from the swim lane to meet fish reliably.
	if coral.pathSideDist > C.TARGET_RANGE + C.LATERAL_SPREAD then
		return nil
	end
	local fill = coral.foodFill
	local cd = coral.pathDist
	local d0 = math.max(0, cd - C.PATH_TARGET_LEAD_MAX)
	local d1 = math.min(path.totalLen, cd + C.PATH_TARGET_PAST)
	local b0 = math.floor(d0 / C.PATH_BUCKET_SIZE) + 1
	local b1 = math.floor(d1 / C.PATH_BUCKET_SIZE) + 1
	local origin = coral.part.Position
	local best: FishAgent? = nil
	local bestScore = C.TARGET_RANGE_SQ
	for bi = b0, b1 do
		local bucket = fishPathBuckets[bi]
		if not bucket then
			continue
		end
		for _, f in ipairs(bucket) do
			-- Same-tick: earlier corals may have already reserved this fish.
			if not fishNeedsFood(f, fill) then
				continue
			end
			local fp = f.root.Position
			local dx = fp.X - origin.X
			local dy = fp.Y - origin.Y
			local dz = fp.Z - origin.Z
			local d2 = dx * dx + dy * dy + dz * dz
			if d2 > C.TARGET_RANGE_SQ then
				continue
			end
			-- Prefer fish still approaching this coral's path station.
			local score = d2
			if f.dist < cd then
				score *= 0.7
			end
			if score < bestScore then
				bestScore = score
				best = f
			end
		end
	end
	return best
end

-- Predict mouth world pos using the same path + offset math the fish uses.
local function predictFishMeetPos(agent: FishAgent, aheadSec: number): Vector3?
	local path = pathData
	if not path then
		return nil
	end
	local futureDist = agent.dist + C.FISH_SPEED * aheadSec
	if futureDist >= path.totalLen - 0.35 then
		return nil
	end
	local pos, tang = samplePath(path, futureDist)
	local world = fishWorldOffset(agent, pos, tang, futureDist)
	local fwd = if tang.Magnitude > 1e-5 then tang.Unit else agent.smoothTang
	if fwd.Magnitude < 1e-5 then
		fwd = Vector3.new(0, 0, -1)
	else
		fwd = fwd.Unit
	end
	return world + fwd * C.FOOD_FRONT_LEAD
end

local function fishCanEatFood(foodPos: Vector3, fishPos: Vector3): boolean
	local dx = fishPos.X - foodPos.X
	local dz = fishPos.Z - foodPos.Z
	if dx * dx + dz * dz > C.FOOD_EAT_RADIUS_SQ then
		return false
	end
	return math.abs(fishPos.Y - foodPos.Y) <= C.FOOD_EAT_Y
end

-- Ease-in so the orb is still rising when the fish arrives at the meet.
local function foodFlightPos(shot: FoodShot, u: number): Vector3
	local t = math.clamp(u, 0, 1)
	local ease = t * t
	local base = shot.startPos:Lerp(shot.meetPos, ease)
	local along = shot.meetPos - shot.startPos
	local side = Vector3.new(-along.Z, 0, along.X)
	local sideLen = side.Magnitude
	if sideLen > 1e-4 then
		side = side / sideLen
		-- Envelope 0 at ends, peak mid — reads as current, not a target lock.
		local envelope = math.sin(t * math.pi)
		local sway = math.sin(t * math.pi * 2 + shot.swayPhase) * C.FOOD_SWAY_AMP * envelope
		base = base + side * sway
	end
	return base
end

local function fireShot(coral: CoralAgent, target: FishAgent)
	local start = ammoWorldPos(coral)
	local fp = target.root.Position
	local flatX = fp.X - start.X
	local flatZ = fp.Z - start.Z
	local flat = math.sqrt(flatX * flatX + flatZ * flatZ)
	local duration = math.clamp(flat / C.FISH_SPEED + C.FOOD_FIRE_LEAD_SEC, C.FOOD_RISE_MIN, C.FOOD_RISE_MAX)
	local meet = predictFishMeetPos(target, duration)
	if not meet then
		return
	end

	coral.busy = true
	destroyAmmo(coral)
	target.incomingFood += coral.foodFill
	local part = acquireFoodPart()
	part.Color = coral.color
	part.Transparency = 0
	part.CFrame = CFrame.new(start)
	local shot: FoodShot = {
		part = part,
		target = target,
		fill = coral.foodFill,
		coral = coral,
		alive = true,
		age = 0,
		duration = duration,
		startPos = start,
		meetPos = meet,
		swayPhase = fishRng:NextNumber(0, math.pi * 2),
	}
	table.insert(activeShots, shot)
end

local function clearShotTarget(shot: FoodShot)
	local target = shot.target
	if target then
		target.incomingFood = math.max(0, target.incomingFood - shot.fill)
		shot.target = nil
	end
end

local function finishShot(shot: FoodShot, fed: boolean)
	shot.alive = false
	local coral = shot.coral
	coral.busy = false
	startAmmoGrow(coral)
	local target = shot.target
	clearShotTarget(shot)
	if fed and target and not target.finished and target.hunger < target.maxHunger then
		target.hunger = math.min(target.maxHunger, target.hunger + shot.fill)
		updateHungerVisual(target)
		playFeedSound()
	end
	releaseFoodPart(shot.part)
end

local function tickCombat()
	local now = os.clock()
	local anyHungry = false
	for _, f in ipairs(fishList) do
		if not f.finished and f.hunger < f.maxHunger then
			anyHungry = true
			break
		end
	end
	if not anyHungry then
		return
	end
	rebuildFishPathBuckets()
	for _, coral in ipairs(coralList) do
		if coral.busy or coral.growing then
			continue
		end
		if now < coral.readyAt then
			continue
		end
		local target = findClosestHungryFish(coral)
		if target then
			fireShot(coral, target)
		end
	end
end

local function tickShots(dt: number)
	local i = 1
	while i <= #activeShots do
		local shot = activeShots[i]
		if not shot.alive then
			table.remove(activeShots, i)
			continue
		end
		local target = shot.target
		if not target or target.finished or not target.model.Parent then
			finishShot(shot, false)
			table.remove(activeShots, i)
			continue
		end

		shot.age += dt
		local u = shot.age / math.max(0.05, shot.duration)
		local foodPos = foodFlightPos(shot, math.min(u, 1))
		shot.part.CFrame = CFrame.new(foodPos)

		-- Mouth-ish: slight lead on live fish for forgiveness vs speed jitter.
		local fwd = target.smoothTang
		if fwd.Magnitude > 1e-5 then
			fwd = fwd.Unit
		else
			fwd = Vector3.new(0, 0, -1)
		end
		local mouth = target.root.Position + fwd * C.FOOD_FRONT_LEAD
		if fishCanEatFood(foodPos, mouth) or fishCanEatFood(foodPos, target.root.Position) then
			finishShot(shot, true)
			table.remove(activeShots, i)
			continue
		end

		if u >= 1 then
			finishShot(shot, false)
			table.remove(activeShots, i)
			continue
		end
		i += 1
	end
end

local function tickFish(dt: number)
	local path = pathData
	if not path then
		return
	end
	for _, agent in ipairs(fishList) do
		if agent.finished then
			continue
		end
		agent.dist += C.FISH_SPEED * (1 + C.FISH_SPEED_VAR * math.sin(os.clock() * agent.speedFreq + agent.speedPhase)) * dt
		if agent.dist >= path.totalLen then
			finishFish(agent)
			continue
		end
		local pos, tang = samplePath(path, agent.dist)
		local world = fishWorldOffset(agent, pos, tang)
		setFishCFrame(agent, world, tang, dt)
		local hungry = agent.hunger < agent.maxHunger
		setDangerFlash(agent, hungry and isOnFinalTwoWaypoints(path, agent.dist))
	end
end

local function compactFishList()
	local kept: { FishAgent } = {}
	for _, f in ipairs(fishList) do
		if not f.finished and f.model.Parent then
			table.insert(kept, f)
		end
	end
	fishList = kept
end

local function makeSummary(): Summary
	return {
		waveReached = math.max(1, waveIndex),
		fishFed = fishFed,
		elapsedSec = math.max(0, os.clock() - startedAt),
	}
end

local function hardCleanup()
	for _, shot in ipairs(activeShots) do
		if shot.part.Parent then
			releaseFoodPart(shot.part)
		end
		shot.alive = false
		shot.coral.busy = false
		clearShotTarget(shot)
	end
	table.clear(activeShots)
	for _, f in ipairs(fishList) do
		destroyFish(f)
	end
	table.clear(fishList)
	for _, c in ipairs(coralList) do
		c.growing = false
		c.busy = false
		destroyAmmo(c)
	end
	table.clear(coralList)
	clearHash()
	spawnQueue = 0
	waveSpawning = false
	destroyArrowPreview()
	WaveStartVfx.cancel()
end

-- Wipe current wave entities without scoring hearts / fishFed, then start the next wave.
local function clearActiveWaveEntities()
	for _, shot in ipairs(activeShots) do
		if shot.part.Parent then
			releaseFoodPart(shot.part)
		end
		shot.alive = false
		local coral = shot.coral
		clearShotTarget(shot)
		coral.busy = false
		if not coral.ammo and not coral.growing then
			startAmmoGrow(coral)
		end
	end
	table.clear(activeShots)
	for _, f in ipairs(fishList) do
		destroyFish(f)
	end
	table.clear(fishList)
	spawnQueue = 0
	waveSpawning = false
	destroyArrowPreview()
end

local function disconnectMove()
	if moveConn then
		moveConn:Disconnect()
		moveConn = nil
	end
end

function WaveSim.isRunning(): boolean
	return running
end

function WaveSim.healReef(amount: number): boolean
	if not running or amount <= 0 then
		return false
	end
	if reefHealth >= reefMaxHealth then
		return false
	end
	local before = reefHealth
	reefHealth = math.clamp(reefHealth + amount, 0, reefMaxHealth)
	if reefHealth == before then
		return false
	end
	notifyHud()
	flushHud()
	return true
end

function WaveSim.getHudSnapshot(): HudSnapshot
	local feedProg, feedDone = getFeedProgress()
	local fishFull, fishTotal = getFishFullCounts()
	return {
		wave = waveIndex,
		reefHealth = reefHealth,
		reefMax = reefMaxHealth,
		elapsedSec = if running then math.max(0, os.clock() - startedAt) else 0,
		running = running,
		feedProgress = feedProg,
		feedComplete = feedDone,
		hungerDanger = anyHungerDanger(),
		hungryMissToken = hungryMissToken,
		fishFull = fishFull,
		fishTotal = fishTotal,
	}
end

-- Happy emojis on fully-fed fish still in the wave (for finish firework).
function WaveSim.getFinishEmojis(): { string }
	local out: { string } = {}
	for _, f in ipairs(fishList) do
		if not f.finished and f.hunger >= f.maxHunger then
			local e = f.happyLabel.Text
			if e == "" then
				e = C.HAPPY_EMOJIS[((f.id - 1) % #C.HAPPY_EMOJIS) + 1]
			end
			table.insert(out, e)
		end
	end
	if #out == 0 then
		for i = 1, math.min(8, #C.HAPPY_EMOJIS) do
			table.insert(out, C.HAPPY_EMOJIS[i])
		end
	end
	return out
end

-- When every fish this wave is fully fed, clear the rest with full credit and start next wave.
function WaveSim.finishWaveEarly(): boolean
	if not running then
		return false
	end
	local _, complete = getFeedProgress()
	if not complete then
		return false
	end
	-- Credit remaining full fish (same as reaching the heart fed).
	for _, f in ipairs(fishList) do
		if not f.finished and f.hunger >= f.maxHunger then
			finishFish(f)
		end
	end
	clearActiveWaveEntities()
	UiHaptics.pulseTriple()
	beginWave(waveIndex + 1)
	notifyHud()
	flushHud()
	return true
end

function WaveSim.skipToNextWave(): boolean
	if not running then
		return false
	end
	clearActiveWaveEntities()
	UiHaptics.pulseTriple()
	beginWave(waveIndex + 1)
	notifyHud()
	flushHud()
	return true
end

function WaveSim.onHud(cb: (HudSnapshot) -> ()): () -> ()
	table.insert(hudListeners, cb)
	return function()
		local i = table.find(hudListeners, cb)
		if i then
			table.remove(hudListeners, i)
		end
	end
end

function WaveSim.onStopped(cb: (Summary) -> ()): () -> ()
	table.insert(stopListeners, cb)
	return function()
		local i = table.find(stopListeners, cb)
		if i then
			table.remove(stopListeners, i)
		end
	end
end

function WaveSim.stop(): Summary
	if not running then
		return makeSummary()
	end
	token += 1
	running = false
	disconnectMove()
	local summary = makeSummary()
	hardCleanup()
	lastHudWave = -1
	lastHudReef = -1
	lastHudSec = -1
	lastHudFeed = -1
	lastHudFeedDone = false
	lastHudDanger = false
	notifyHud()
	flushHud()
	fireStopped(summary)
	return summary
end

function WaveSim.start(): boolean
	if running then
		return false
	end
	pathData = buildPath()
	if not pathData then
		return false
	end
	if not getTangTemplate() then
		return false
	end
	token += 1
	local myToken = token
	running = true
	waveIndex = 0
	reefMaxHealth = C.REEF_START_HEALTH
	reefHealth = C.REEF_START_HEALTH
	fishFed = 0
	WaveEndVfx.resetStreak()
	feedPitchCursor = C.FEED_PITCH_MIN
	startedAt = os.clock()
	combatAcc = 0
	nextFishId = 1
	ensureFolder()
	hardCleanup()
	beginWave(1)
	notifyHud()
	flushHud()

	disconnectMove()
	moveConn = RunService.Heartbeat:Connect(function(dt)
		if myToken ~= token or not running then
			return
		end
		-- Spawning (first fish waits C.ARROW_LEAD_SEC after GreenArrows start)
		if waveSpawning and spawnQueue > 0 then
			spawnDelay -= dt
			if spawnDelay <= 0 then
				local idx = waveFishCount(waveIndex) - spawnQueue + 1
				spawnOneFish(idx)
				spawnQueue -= 1
				spawnDelay = C.STAGGER_SEC
				if spawnQueue <= 0 then
					waveSpawning = false
				end
			end
		end

		tickArrowPreview(dt)
		tickFish(dt)
		tickShots(dt)
		tickAmmoGrow(os.clock())

		-- Ammo grow + combat cadence; also pick up newly placed corals (~10 Hz).
		combatAcc += dt
		if combatAcc >= C.COMBAT_DT then
			combatAcc -= C.COMBAT_DT
			syncCorals(false)
			tickCombat()
		end

		-- Compact finished fish occasionally
		if math.random() < 0.02 then
			compactFishList()
		end

		flushHud()

		if reefHealth <= 0 then
			WaveSim.stop()
			return
		end

		-- Wave complete → next wave immediately (no intermission pause).
		if not waveSpawning and spawnQueue <= 0 and countAliveFish() == 0 then
			UiHaptics.pulseTriple()
			beginWave(waveIndex + 1)
		end
	end)

	return true
end

function WaveSim.formatClock(sec: number): string
	local s = math.max(0, math.floor(sec + 0.5))
	local h = s // 3600
	local m = (s % 3600) // 60
	local r = s % 60
	return string.format("%02d:%02d:%02d", h, m, r)
end

return WaveSim
