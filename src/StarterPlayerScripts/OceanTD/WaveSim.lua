--!strict
--[[
	Client-only feed-wave simulation (solo). Fish, food, reef health — not replicated.
	Optimized: path samples once, path-bucket coral↔fish, 10 Hz targeting, PlacedCoralIndex gather,
	WaveEntityPool (Tang fish / food / arrows / ammo / SFX).
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
local WaveEntityPool = require(script.Parent:WaitForChild("WaveEntityPool"))
local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
local WaveStartVfx = require(script.Parent:WaitForChild("WaveStartVfx"))
local WaveFeedPayout = require(script.Parent:WaitForChild("WaveFeedPayout"))

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
	speedMult: number,
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
	payoutDone: boolean, -- $D already reported for this fill
	fedCounted: boolean, -- counted toward this wave's feed bar / early-finish
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
local fishPathBuckets: { { FishAgent } } = {}
local activeShots: { FoodShot } = {}
local spawnQueue = 0
local spawnDelay = 0
local waveIndex = 0
local reefMaxHealth = C.REEF_START_HEALTH
local reefHealth = C.REEF_START_HEALTH
local fishFed = 0
local waveFishExpected = 0
local waveFishSpawned = 0 -- successfully spawned this wave (denominator once spawning ends)
local waveFishFullyFed = 0 -- fish that reached full hunger this wave (alive or finished happy)
local startedAt = 0
local simClock = 0 -- advances with dt * speedMult (ammo/combat); HUD clock stays real-time
local speedMult = 1 -- 1 | 1.5 | 2; session-only, player-controlled
local waveSpawning = false
local moveConn: RBXScriptConnection? = nil
local combatAcc = 0
local nextFishId = 1
local greenArrowsTemplate: Instance? = nil
local arrowPreviews: { ArrowPreview } = {}
local wavePathLabels: { WavePathLabel } = {}
local arrowsWarned = false
local hudListeners: { (HudSnapshot) -> () } = {}
local stopListeners: { (Summary) -> () } = {}
local fishRng = Random.new()
local feedPitchCursor = C.FEED_PITCH_MIN

local SPEED_STEPS = { 1, 1.5, 2 }

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
	-- Don't dive into the floor / out of view under the route.
	up = math.max(up, C.FISH_MIN_PATH_Y)
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

local function markFishFullyFed(agent: FishAgent)
	if agent.fedCounted then
		return
	end
	agent.fedCounted = true
	waveFishFullyFed += 1
	notifyHud()
end

local function waveProgressDenominator(): number
	-- After spawning finishes, use actual spawns so a failed acquire can't soft-lock the bar.
	if (not waveSpawning) and spawnQueue <= 0 then
		return math.max(1, waveFishSpawned)
	end
	return math.max(1, waveFishExpected)
end

local function getFishFullCounts(): (number, number)
	return waveFishFullyFed, waveProgressDenominator()
end

local function getFeedProgress(): (number, boolean)
	if not running or waveFishExpected <= 0 then
		return 0, false
	end
	local total = waveProgressDenominator()
	local filled = waveFishFullyFed
	local anyHungryAlive = false
	for _, f in ipairs(fishList) do
		if not f.finished and f.hunger < f.maxHunger then
			anyHungryAlive = true
			-- Partial credit so the bar moves before a fish is fully fed.
			if f.maxHunger > 0 then
				filled += math.clamp(f.hunger / f.maxHunger, 0, 0.999)
			end
		end
	end
	local progress = math.clamp(filled / total, 0, 1)
	local spawningDone = (not waveSpawning) and spawnQueue <= 0
	-- Complete only when every spawned fish was fully fed (underfed exits permanently block).
	local complete = spawningDone
		and waveFishSpawned > 0
		and (not anyHungryAlive)
		and waveFishFullyFed >= waveFishSpawned
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
		speedMult = speedMult,
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

	-- WaveRoute is authored on Plot1; remap into the local player's plot CFrame.
	local mirrored = ClientPlot.get()
	local plotLabel = if mirrored then mirrored.plotId else "?"
	if mirrored and not ClientPlot.getPlot1CFrame() then
		warn("[WAVE] Cannot remap WaveRoute onto", plotLabel, "(missing Plot1 CFrame from server)")
		return nil
	end

	-- Rigid Plot1→local remap only (same frame as coral/décor). Do not snap to
	-- Terrain — that flattens authored swim height onto the seafloor.
	local function wpPos(part: BasePart): Vector3
		return ClientPlot.remapFromPlot1(part.Position)
	end

	local segments: { PathSegment } = {}
	local total = 0
	for s = 1, #waypoints - 1 do
		local ctrl = findIndexedPart(ctrlFolder, "C", s)
		if not ctrl then
			warn("[WAVE] Missing control C" .. tostring(s) .. " for segment W" .. tostring(s) .. "→W" .. tostring(s + 1))
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
			inTang = quadBezierTangent(w0, c, w1, 0),
			outTang = quadBezierTangent(w0, c, w1, 1),
		})
		total += length
	end

	local waypointDists: { number } = { 0 }
	for s = 1, #segments do
		table.insert(waypointDists, segments[s].cumStart + segments[s].length)
	end

	print(
		"[WAVE] Path ready:",
		#waypoints,
		"waypoints,",
		#segments,
		"curve segments, len=",
		string.format("%.1f", total),
		"plot=",
		plotLabel,
		"rigidRemap=true"
	)
	return {
		segments = segments,
		totalLen = total,
		endPos = wpPos(waypoints[#waypoints]),
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
	return WaveEntityPool.findPrimary(inst)
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

local function playArrowStartSound()
	WaveEntityPool.playSound("arrow", arrowSound, 1, 0.9)
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
		local clone = WaveEntityPool.acquireArrows("OceanTD_GreenArrows_" .. tostring(i), folderFx)
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
		destroyArrowPreview()
		return
	end
	local speed = C.FISH_SPEED * C.ARROW_SPEED_MULT
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
			preview.alive = false
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
	WaveEntityPool.playSound("feed", feedSound, pitch, 0.85)
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
		markFishFullyFed(agent)
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
		WaveEntityPool.releaseAmmo(coral.ammo)
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
		WaveEntityPool.releaseAmmo(coral.ammo)
		coral.ammo = nil
	end
	local s = C.AMMO_RADIUS * 2 * math.clamp(scale, 0.08, 1)
	local p = WaveEntityPool.acquireAmmo(ensureFolder(), coral.color, s)
	p.CFrame = CFrame.new(ammoWorldPos(coral))
	coral.ammo = p
end

local function startAmmoGrow(coral: CoralAgent)
	createAmmo(coral, 0.08)
	coral.growing = true
	coral.growT0 = simClock
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
	return WaveEntityPool.acquireFood(ensureFolder(), C.FOOD_RADIUS)
end

local function releaseFoodPart(p: BasePart)
	WaveEntityPool.releaseFood(p)
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
		pathDist = 0,
		pathSideDist = 0,
	}
end

local function gatherPlotCoralParts(): { BasePart }
	local mirrored = ClientPlot.get()
	if not mirrored then
		return {}
	end
	local PlacedCoralIndex = require(script.Parent:WaitForChild("PlacedCoralIndex"))
	local indexed = PlacedCoralIndex.getParts(mirrored.plotId)
	local parts: { BasePart } = {}
	for _, inst in ipairs(indexed) do
		if inst.Parent then
			table.insert(parts, inst)
		end
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

	for _, c in ipairs(coralList) do
		-- Prefer rest look for shot color (ignore transient hover/relocate neon wash).
		local _, restColor = CoralVisual.readRestLook(c.part)
		c.color = restColor
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
	WaveEntityPool.releaseFish(WaveEntityPool.FISH_TANG, agent.model)
end

-- Drop finished agents (models already released) so the next wave won't share refs.
local function pruneFinishedFish()
	local kept: { FishAgent } = {}
	for _, f in ipairs(fishList) do
		if not f.finished then
			table.insert(kept, f)
		end
	end
	fishList = kept
end

local function finishFish(agent: FishAgent, skipHappyVfx: boolean?)
	if agent.finished then
		return
	end
	local empty = agent.maxHunger - agent.hunger
	if empty > 0 then
		local dealt = math.min(empty, reefHealth)
		reefHealth = math.max(0, reefHealth - empty)
		local endPos = if pathData then pathData.endPos else nil
		WaveEndVfx.notifyUnderfedArrival()
		WaveEndVfx.playReefHealthTicks(dealt, endPos)
		hungryMissToken += 1
		if dealt > 0 then
			UiHaptics.pulseReef()
		end
	else
		fishFed += 1
		markFishFullyFed(agent)
		if not skipHappyVfx then
			local emoji = agent.happyLabel.Text
			if emoji == "" then
				emoji = C.HAPPY_EMOJIS[1]
			end
			local endPos = if pathData then pathData.endPos else nil
			if not endPos then
				endPos = WaveEndVfx.getEndHeartWorldPos()
			end
			if endPos then
				WaveEndVfx.pulseHappyExit(emoji, endPos)
			end
		end
	end
	destroyFish(agent)
	notifyHud()
end

local function spawnOneFish(spawnIndex: number)
	local path = pathData
	if not path then
		return
	end
	local clone, root = WaveEntityPool.acquireFish(WaveEntityPool.FISH_TANG, "Tang_" .. tostring(nextFishId))
	if not clone or not root then
		return
	end
	clone.Parent = ensureFolder()
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
		payoutDone = false,
		fedCounted = false,
	}
	nextFishId += 1
	waveFishSpawned += 1
	notifyHud()
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
	pruneFinishedFish()
	waveIndex = wave
	waveFishExpected = waveFishCount(wave)
	waveFishSpawned = 0
	waveFishFullyFed = 0
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

	local function consider(f: FishAgent)
		if not fishNeedsFood(f, fill) then
			return
		end
		local fp = f.root.Position
		local dx = fp.X - origin.X
		local dy = fp.Y - origin.Y
		local dz = fp.Z - origin.Z
		local d2 = dx * dx + dy * dy + dz * dz
		if d2 > C.TARGET_RANGE_SQ then
			return
		end
		-- Prefer fish at/past this coral so stragglers don't slip through unfed
		-- while the school still approaching soaks every shot.
		local score = d2
		if f.dist >= cd - 1 then
			score *= 0.4
		elseif f.dist < cd then
			score *= 0.9
		end
		if score < bestScore then
			bestScore = score
			best = f
		end
	end

	for bi = b0, b1 do
		local bucket = fishPathBuckets[bi]
		if bucket then
			for _, f in ipairs(bucket) do
				consider(f)
			end
		end
	end

	-- Fallback: any hungry fish in 3D range (catches window misses / bucket edge cases).
	if not best then
		for _, f in ipairs(fishList) do
			consider(f)
		end
	end
	return best
end

-- Predict mouth world pos using the same path + offset math the fish uses.
-- Integrates each fish's ±FISH_SPEED_VAR surge (constant FISH_SPEED caused systematic misses).
local function fishSpeedFactorAt(agent: FishAgent, clock: number): number
	return 1 + C.FISH_SPEED_VAR * math.sin(clock * agent.speedFreq + agent.speedPhase)
end

local function predictFishDistAhead(agent: FishAgent, aheadSec: number): number
	local steps = math.max(4, math.ceil(aheadSec * 24))
	local stepDt = aheadSec / steps
	local dist = agent.dist
	local t = simClock
	for _ = 1, steps do
		dist += C.FISH_SPEED * fishSpeedFactorAt(agent, t) * stepDt
		t += stepDt
	end
	return dist
end

local function predictFishMeetPos(agent: FishAgent, aheadSec: number): Vector3?
	local path = pathData
	if not path then
		return nil
	end
	local futureDist = predictFishDistAhead(agent, aheadSec)
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

local function fishMouthWorld(target: FishAgent): Vector3
	local fwd = target.smoothTang
	if fwd.Magnitude > 1e-5 then
		fwd = fwd.Unit
	else
		fwd = Vector3.new(0, 0, -1)
	end
	return target.root.Position + fwd * C.FOOD_FRONT_LEAD
end

local function fishCanEatFood(foodPos: Vector3, fishPos: Vector3, radiusSq: number?, maxY: number?): boolean
	local r2 = if radiusSq ~= nil then radiusSq else C.FOOD_EAT_RADIUS_SQ
	local yMax = if maxY ~= nil then maxY else C.FOOD_EAT_Y
	local dx = fishPos.X - foodPos.X
	local dz = fishPos.Z - foodPos.Z
	if dx * dx + dz * dz > r2 then
		return false
	end
	return math.abs(fishPos.Y - foodPos.Y) <= yMax
end

-- Ease-in so the orb is still rising when the fish arrives at the meet.
local function foodFlightPos(shot: FoodShot, u: number, meetPos: Vector3): Vector3
	local t = math.clamp(u, 0, 1)
	local ease = t * t
	local base = shot.startPos:Lerp(meetPos, ease)
	local along = meetPos - shot.startPos
	local side = Vector3.new(-along.Z, 0, along.X)
	local sideLen = side.Magnitude
	if sideLen > 1e-4 then
		side = side / sideLen
		-- Envelope 0 at ends, peak mid — reads as current, not a target lock.
		-- Fade sway earlier so late flight can home cleanly.
		local envelope = math.sin(t * math.pi)
		if t > 0.7 then
			envelope *= (1 - t) / 0.3
		end
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
	-- Estimate duration from distance; prediction uses the fish's live speed curve.
	local speedNow = C.FISH_SPEED * math.max(0.55, fishSpeedFactorAt(target, simClock))
	local duration = math.clamp(flat / speedNow + C.FOOD_FIRE_LEAD_SEC, C.FOOD_RISE_MIN, C.FOOD_RISE_MAX)
	local meet = predictFishMeetPos(target, duration)
	-- Near route end (or bad predict): still fire at the live mouth — don't let them ghost past.
	if not meet then
		meet = fishMouthWorld(target)
		duration = math.clamp(duration * 0.65, C.FOOD_RISE_MIN * 0.75, C.FOOD_RISE_MAX)
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
		if (not target.payoutDone) and target.hunger >= target.maxHunger then
			target.payoutDone = true
			WaveFeedPayout.noteFilled(target.root.Position)
		end
		if target.hunger >= target.maxHunger then
			markFishFullyFed(target)
		end
		updateHungerVisual(target)
		playFeedSound()
	end
	releaseFoodPart(shot.part)
end

local function tickCombat()
	local now = simClock
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
		local mouth = fishMouthWorld(target)
		-- Late flight: home toward the live mouth so surge/wander don't waste the shot.
		local meet = shot.meetPos
		local homeStart = C.FOOD_HOME_START_U
		if u > homeStart then
			local homeT = math.clamp((u - homeStart) / math.max(1e-3, 1 - homeStart), 0, 1)
			homeT = homeT * homeT
			meet = shot.meetPos:Lerp(mouth, homeT)
		end
		local foodPos = foodFlightPos(shot, math.min(u, 1), meet)
		shot.part.CFrame = CFrame.new(foodPos)

		if fishCanEatFood(foodPos, mouth) or fishCanEatFood(foodPos, target.root.Position) then
			finishShot(shot, true)
			table.remove(activeShots, i)
			continue
		end

		if u >= 1 then
			-- Last-chance credit if the orb ended near the fish (prediction leftover).
			local fed = fishCanEatFood(foodPos, mouth, C.FOOD_END_GRACE_RADIUS_SQ, C.FOOD_END_GRACE_Y)
				or fishCanEatFood(foodPos, target.root.Position, C.FOOD_END_GRACE_RADIUS_SQ, C.FOOD_END_GRACE_Y)
			finishShot(shot, fed)
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
		agent.dist += C.FISH_SPEED * (1 + C.FISH_SPEED_VAR * math.sin(simClock * agent.speedFreq + agent.speedPhase)) * dt
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
	pruneFinishedFish()
	local kept: { FishAgent } = {}
	for _, f in ipairs(fishList) do
		if f.model.Parent then
			table.insert(kept, f)
		else
			-- Orphaned visual (should be rare with pool in-use tracking) — drop without re-release.
			f.finished = true
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
		speedMult = speedMult,
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
	local burstEmojis = WaveSim.getFinishEmojis()
	local endPos = if pathData then pathData.endPos else nil
	if not endPos then
		endPos = WaveEndVfx.getEndHeartWorldPos()
	end
	-- Credit remaining full fish (same as reaching the heart fed); one firework instead of N stacked exits.
	for _, f in ipairs(fishList) do
		if not f.finished and f.hunger >= f.maxHunger then
			finishFish(f, true)
		end
	end
	if endPos and #burstEmojis > 0 then
		WaveEndVfx.burstHappyFirework(burstEmojis, endPos)
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

local function attachSimLoop(myToken: number)
	disconnectMove()
	moveConn = RunService.Heartbeat:Connect(function(dt)
		if myToken ~= token or not running then
			return
		end
		local simDt = dt * speedMult
		simClock += simDt
		-- Spawning (first fish waits C.ARROW_LEAD_SEC after GreenArrows start)
		if waveSpawning and spawnQueue > 0 then
			spawnDelay -= simDt
			if spawnDelay <= 0 then
				local idx = waveFishCount(waveIndex) - spawnQueue + 1
				spawnOneFish(idx)
				spawnQueue -= 1
				-- Slight random gap so the school reads as a parade, not a metronome.
				spawnDelay = C.STAGGER_SEC * fishRng:NextNumber(0.7, 1.35)
				if spawnQueue <= 0 then
					waveSpawning = false
				end
			end
		end

		tickArrowPreview(simDt)
		tickFish(simDt)
		tickShots(simDt)
		tickAmmoGrow(simClock)

		-- Ammo grow + combat cadence; also pick up newly placed corals (~10 Hz).
		combatAcc += simDt
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
end

-- After defeat / stop summary: set reef hearts and begin the next wave (keeps run stats).
function WaveSim.continueWithHearts(hearts: number): boolean
	if running then
		return false
	end
	pathData = buildPath()
	if not pathData then
		return false
	end
	if not WaveEntityPool.hasFishKind(WaveEntityPool.FISH_TANG) then
		warn("[WAVE] ReplicatedStorage.Fish.Tang missing")
		return false
	end
	token += 1
	local myToken = token
	running = true
	reefMaxHealth = C.REEF_START_HEALTH
	reefHealth = math.clamp(math.floor(hearts + 0.5), 1, reefMaxHealth)
	ensureFolder()
	WaveEndVfx.refreshLocalEndHeart()
	beginWave(math.max(1, waveIndex) + 1)
	notifyHud()
	flushHud()
	attachSimLoop(myToken)
	return true
end

function WaveSim.start(): boolean
	if running then
		return false
	end
	pathData = buildPath()
	if not pathData then
		return false
	end
	if not WaveEntityPool.hasFishKind(WaveEntityPool.FISH_TANG) then
		warn("[WAVE] ReplicatedStorage.Fish.Tang missing")
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
	simClock = 0
	combatAcc = 0
	nextFishId = 1
	ensureFolder()
	hardCleanup()
	WaveEndVfx.refreshLocalEndHeart()
	beginWave(1)
	notifyHud()
	flushHud()
	attachSimLoop(myToken)
	return true
end

function WaveSim.getSpeedMult(): number
	return speedMult
end

-- Returns new mult after cycle: 1 → 1.5 → 2 → 1
function WaveSim.cycleSpeed(): number
	local idx = 1
	for i, s in ipairs(SPEED_STEPS) do
		if math.abs(speedMult - s) < 1e-4 then
			idx = i
			break
		end
	end
	idx = idx % #SPEED_STEPS + 1
	speedMult = SPEED_STEPS[idx]
	notifyHud()
	return speedMult
end

function WaveSim.formatClock(sec: number): string
	local s = math.max(0, math.floor(sec + 0.5))
	local h = s // 3600
	local m = (s % 3600) // 60
	local r = s % 60
	return string.format("%02d:%02d:%02d", h, m, r)
end

return WaveSim
