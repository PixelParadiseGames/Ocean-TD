--!strict
--[[
	Client-only feed-wave simulation (solo). Fish, food, reef health — not replicated.
	Optimized: path samples once, path-bucket coral↔fish, 10 Hz targeting, PlacedCoralIndex gather,
	WaveEntityPool (Tang fish / food / arrows / ammo / SFX).
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local SpeciesCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SpeciesCatalog"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual"))
local CoralSize = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralSize"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local WaveEntityPool = require(script.Parent:WaitForChild("WaveEntityPool"))
local WaveCrab = require(script.Parent:WaitForChild("WaveCrab"))
local WaveUrchin = require(script.Parent:WaitForChild("WaveUrchin"))
local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
local WaveStartVfx = require(script.Parent:WaitForChild("WaveStartVfx"))
local Wave1LeadArrow = require(script.Parent:WaitForChild("Wave1LeadArrow"))
local WaveFeedPayout = require(script.Parent:WaitForChild("WaveFeedPayout"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))
local UrchinStingEffects = require(script.Parent:WaitForChild("UrchinStingEffects"))

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
	hungerDanger: boolean, -- any hungry fish bar flashing red near route end
	hungryMissToken: number, -- bumps when a hungry fish reaches the end (broken heart)
	fishFull: number, -- fully-fed fish this wave (alive + finished happy)
	fishTotal: number, -- fish expected this wave
	crabTotal: number, -- crabs rolled for this wave
	urchinTotal: number, -- urchins on x10 waves (wave / 10)
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
	remainLabel: TextLabel,
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
	isCrab: boolean?,
	isUrchin: boolean?,
	crabAnim: any?,
	shellHitbox: BasePart?,
	-- Root-local offsets so ShellHitbox / mesh stay glued when RootPart teleports.
	shellLocalCf: CFrame?,
	bodyLocalCf: CFrame?,
	pauseUntil: number?,
	pauseDur: number?,
	stunSkullPart: BasePart?,
	crabSprint: any?,
}

type CoralAgent = {
	part: BasePart,
	color: Color3,
	reloadSec: number,
	foodFill: number,
	foodCount: number,
	range: number,
	rangeSq: number,
	defenseSec: number,
	diameter: number,
	-- Lifetime session stats (used by CoralInspectPanel while this client is running).
	fedTotal: number,
	wavesTotal: number,
	readyAt: number,
	ammo: BasePart?,
	ammoSlots: { BasePart },
	ammoSizeMult: number, -- 0.70..0.99 — each neon food is 1–30% smaller
	growing: boolean,
	growT0: number,
	busy: boolean, -- projectile in flight
	shotsOut: number,
	pathDist: number, -- nearest distance along WaveRoute
	pathSideDist: number, -- world distance from that path point
	stunned: boolean, -- crab ShellHitbox hit; white, no food until next wave
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
local pathDataGround: WaveCrab.PathData? = nil
local fishList: { FishAgent } = {}
local critterHungerBarsVisible = true
local coralList: { CoralAgent } = {}
type CoralStats = {
	fed: number, -- fish fully fed (credited when they hit max hunger)
	waves: number, -- waves completed while this coral existed (session-only)
}
local coralStatsByPlaceId: { [string]: CoralStats } = {}
local fishPathBuckets: { { FishAgent } } = {}
local activeShots: { FoodShot } = {}
local spawnQueue = 0
local spawnDelay = 0
local crabSpawnQueue = 0
local crabSpawnDelay = 0
local urchinSpawnQueue = 0
local urchinSpawnDelay = 0
local waveIndex = 0
local reefMaxHealth = C.REEF_START_HEALTH
local reefHealth = C.REEF_START_HEALTH

local function isGroundCritter(f: FishAgent): boolean
	return f.isCrab == true or f.isUrchin == true
end

local function reefMaxFromSkills(): number
	return SkillStages.reefHealthAtStage(SkillPowerUpUI.getStage("RHealth"))
end

local fishFed = 0
local waveFishExpected = 0
local waveFishSpawned = 0 -- successfully spawned this wave (denominator once spawning ends)
local waveFishFullyFed = 0 -- fish that reached full hunger this wave (alive or finished happy)
local lastCoralWaveAwarded = 0
local startedAt = 0
local simClock = 0 -- advances with dt * speedMult (ammo/combat); HUD clock freezes while paused
local speedMult = 1 -- 1 | 1.5 | 2 | 0 (pause); session-only, player-controlled
local pauseWallT0: number? = nil -- wall clock when speed-pause began
local pausedWallAccum = 0 -- total wall time spent paused this run
local waveSpawning = false
local moveConn: RBXScriptConnection? = nil
local combatAcc = 0
local nextFishId = 1
local greenArrowsTemplate: Instance? = nil
local arrowPreviews: { ArrowPreview } = {}
local crabArrowPreviews: { ArrowPreview } = {}
local wavePathLabels: { WavePathLabel } = {}
local arrowsWarned = false
local hudListeners: { (HudSnapshot) -> () } = {}
local stopListeners: { (Summary) -> () } = {}
local fishRng = Random.new()
local feedPitchCursor = C.FEED_PITCH_MIN
local stingReportAt: { [number]: number } = {}
local reportUrchinSting = Remotes.get("ReportUrchinSting")

-- Indices 1–3 are play speeds; index 4 (0) is pause (stage 4 Wave Speed only).
local SPEED_STEPS = { 1, 1.5, 2, 0 }

local function wallElapsedSec(): number
	if not running then
		return 0
	end
	if pauseWallT0 then
		return math.max(0, pauseWallT0 - startedAt - pausedWallAccum)
	end
	return math.max(0, os.clock() - startedAt - pausedWallAccum)
end

local function applySpeedPauseState(nowPaused: boolean)
	if nowPaused then
		if not pauseWallT0 then
			pauseWallT0 = os.clock()
		end
		return
	end
	if pauseWallT0 then
		local dt = os.clock() - pauseWallT0
		pausedWallAccum += dt
		-- Fight timers use wall clock; shift so they don't expire during pause.
		for _, agent in ipairs(fishList) do
			local untilT = agent.pauseUntil
			if untilT then
				agent.pauseUntil = untilT + dt
			end
		end
		pauseWallT0 = nil
	end
end

local function resetSpeedState()
	speedMult = 1
	pauseWallT0 = nil
	pausedWallAccum = 0
end

-- Skip / next-wave while paused → resume at 1x.
local function resumeNormalSpeedIfPaused()
	if speedMult > 1e-6 then
		return
	end
	applySpeedPauseState(false)
	speedMult = 1
end

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

local function markFishFullyFed(agent: FishAgent, fedBy: CoralAgent?)
	if agent.fedCounted then
		return
	end
	agent.fedCounted = true
	-- Urchins don't count toward wave feed progress (they don't gate waves).
	if not agent.isUrchin then
		waveFishFullyFed += 1
	end
	-- Attribute the "fed" credit to the coral that delivered the final shot.
	if fedBy then
		local pid = fedBy.part:GetAttribute("OceanTD_PlaceId")
		if typeof(pid) == "string" and pid ~= "" then
			local st = coralStatsByPlaceId[pid]
			if not st then
				st = { fed = 0, waves = 0 }
				coralStatsByPlaceId[pid] = st
			end
			st.fed += 1
			fedBy.fedTotal = st.fed
			fedBy.part:SetAttribute("OceanTD_CoralFedTotal", fedBy.fedTotal)
		end
	end
	notifyHud()
end

local function awardCoralWaveCompleted(waveNum: number)
	-- Prevent double-awards when multiple "wave complete" paths converge.
	if waveNum <= lastCoralWaveAwarded then
		return
	end
	lastCoralWaveAwarded = waveNum

	for _, coral in ipairs(coralList) do
		local part = coral.part
		if part.Parent then
			local pid = part:GetAttribute("OceanTD_PlaceId")
			if typeof(pid) == "string" and pid ~= "" then
				local st = coralStatsByPlaceId[pid] or { fed = 0, waves = 0 }
				coralStatsByPlaceId[pid] = st
				st.waves += 1
				coral.wavesTotal = st.waves
				part:SetAttribute("OceanTD_CoralWavesTotal", st.waves)
			end
		end
	end
end

local function waveFishDenominator(): number
	-- After spawning finishes, use actual spawns so a failed acquire can't soft-lock the bar.
	if (not waveSpawning) and spawnQueue <= 0 then
		return math.max(1, waveFishSpawned)
	end
	return math.max(1, waveFishExpected)
end

local function waveProgressDenominator(): number
	local n = waveFishDenominator()
	if WaveCrab.shouldSpawn(waveIndex) and pathDataGround then
		if (not waveSpawning) and spawnQueue <= 0 and crabSpawnQueue <= 0 and urchinSpawnQueue <= 0 then
			n += WaveCrab.spawnedCount()
		else
			n += WaveCrab.expectedCount()
		end
	end
	-- Urchins do not gate wave progress / feed bar (they linger on GroundA).
	return math.max(1, n)
end

local function getFishFullCounts(): (number, number)
	return waveFishFullyFed, waveFishDenominator()
end

local function getFeedProgress(): (number, boolean)
	if not running or waveFishExpected <= 0 then
		return 0, false
	end
	local total = waveProgressDenominator()
	local filled = waveFishFullyFed
	local anyHungryAlive = false
	for _, f in ipairs(fishList) do
		-- Trailing urchins never block feed-complete / early finish.
		if f.isUrchin or f.finished or f.hunger >= f.maxHunger then
			continue
		end
		anyHungryAlive = true
		-- Partial credit so the bar moves before a fish is fully fed.
		if f.maxHunger > 0 then
			filled += math.clamp(f.hunger / f.maxHunger, 0, 0.999)
		end
	end
	local progress = math.clamp(filled / total, 0, 1)
	local spawningDone = (not waveSpawning) and spawnQueue <= 0 and crabSpawnQueue <= 0 and urchinSpawnQueue <= 0
	-- Fish + crabs only; urchins walk off on their own without holding the wave.
	local unitsSpawned = waveFishSpawned + WaveCrab.spawnedCount()
	local complete = spawningDone
		and unitsSpawned > 0
		and (not anyHungryAlive)
		and waveFishFullyFed >= unitsSpawned
	return progress, complete
end

local function flushHud()
	local elapsed = wallElapsedSec()
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
		crabTotal = WaveCrab.expectedCount(),
		urchinTotal = WaveUrchin.expectedCount(),
		speedMult = speedMult,
	}
	for _, cb in ipairs(hudListeners) do
		cb(snap)
	end
end

-- Grow max (and current) when Reef Health skill stages up. Safe while idle too.
function WaveSim.applyReefHealthStage(stage: number)
	local newMax = SkillStages.reefHealthAtStage(stage)
	local delta = newMax - reefMaxHealth
	reefMaxHealth = newMax
	if delta > 0 then
		reefHealth = math.min(reefMaxHealth, reefHealth + delta)
	else
		reefHealth = math.min(reefHealth, reefMaxHealth)
	end
	if running then
		notifyHud()
		flushHud()
	end
end

local function fireStopped(summary: Summary)
	for _, cb in ipairs(stopListeners) do
		cb(summary)
	end
end

local function ensureFolder(): Folder
	if folder and folder.Parent then
		-- Drop any leftover stand-on blockers from older builds.
		for _, ch in ipairs(folder:GetChildren()) do
			if ch.Name == "OceanTD_UrchinBlocker" then
				ch:Destroy()
			end
		end
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

-- One smoothed heading per fish: drives lateral offset frame and facing (no world-step clamp).
local function stepSwimTang(agent: FishAgent, tang: Vector3, dt: number): Vector3
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

local function buildPath(plotSizeStageOverride: number?): PathData?
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

	-- Plot Size stage truncates the route (stage 1–2 → W4 … stage 6+ → W8).
	local plotSizeStage = if plotSizeStageOverride ~= nil
		then SkillStages.clampStage(plotSizeStageOverride)
		else SkillPowerUpUI.getStage("PlotSize")
	local finalWp = SkillStages.plotSizeFinalWaypoint(plotSizeStage)
	if finalWp < #waypoints then
		local trimmed: { BasePart } = {}
		for wi = 1, math.min(finalWp, #waypoints) do
			table.insert(trimmed, waypoints[wi])
		end
		waypoints = trimmed
	end
	if #waypoints < 2 then
		warn("[WAVE] PlotSize stage", plotSizeStage, "final W" .. tostring(finalWp), "left <2 waypoints")
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
		"waypoints (end W" .. tostring(#waypoints) .. "),",
		#segments,
		"curve segments, len=",
		string.format("%.1f", total),
		"plot=",
		plotLabel,
		"plotSizeStage=",
		plotSizeStage,
		"rigidRemap=true"
	)
	local path = {
		segments = segments,
		totalLen = total,
		endPos = wpPos(waypoints[#waypoints]),
		waypointDists = waypointDists,
	}
	WaveEndVfx.setRouteEndWorldPos(path.endPos, if mirrored then mirrored.plotId else nil)
	return path
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

	local fromStart = d - seg.cumStart
	if fromStart < C.TANGENT_BLEND_STUDS and lo > 1 then
		local blend = 1 - math.clamp(fromStart / C.TANGENT_BLEND_STUDS, 0, 1)
		tang = blendUnitTangents(segs[lo - 1].outTang, tang, blend)
	end
	-- Independent W/C quads are only G0 at waypoints — blend heading into the next
	-- segment so lateral school offsets don't snap when the tangent jumps.
	local toEnd = seg.cumStart + seg.length - d
	if toEnd < C.TANGENT_BLEND_STUDS and lo < #segs then
		local blend = 1 - math.clamp(toEnd / C.TANGENT_BLEND_STUDS, 0, 1)
		tang = blendUnitTangents(tang, segs[lo + 1].inTang, blend)
	end
	return pos, tang
end

local function isNearPathEnd(totalLen: number, dist: number): boolean
	return totalLen - dist <= C.DANGER_NEAR_END_STUDS
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
	for _, preview in ipairs(crabArrowPreviews) do
		WaveEntityPool.releaseRedArrows(preview.model)
	end
	table.clear(crabArrowPreviews)
	for _, label in ipairs(wavePathLabels) do
		if label.part.Parent then
			label.part:Destroy()
		end
	end
	table.clear(wavePathLabels)
end

local function playArrowStartSound()
	WaveEntityPool.playSound("arrow", arrowSound, 1, 0.9, true)
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

local function startCrabArrowPreview()
	for _, preview in ipairs(crabArrowPreviews) do
		WaveEntityPool.releaseRedArrows(preview.model)
	end
	table.clear(crabArrowPreviews)
	local path = pathDataGround
	-- Same GroundA red train for crabs and/or urchins.
	if not path or (WaveCrab.expectedCount() <= 0 and WaveUrchin.expectedCount() <= 0) then
		return
	end
	local folderFx = ensureFolder()
	local lift = Vector3.new(0, C.CRAB_ARROW_Y_LIFT, 0)
	local d = 0
	for i = 1, C.CRAB_ARROW_COUNT do
		if d >= path.totalLen - 0.05 then
			break
		end
		local clone = WaveEntityPool.acquireRedArrows(
			"OceanTD_RedArrows_" .. tostring(i),
			folderFx,
			C.CRAB_ARROW_COLOR
		)
		if not clone then
			break
		end
		local spin0 = (i - 1) * 0.55
		local pos, tang = WaveCrab.sample(path, d)
		setArrowCFrame(clone, pos + lift, tang, spin0)
		table.insert(crabArrowPreviews, {
			model = clone,
			dist = d,
			spin = spin0,
			alive = true,
		})
		d += C.CRAB_ARROW_PATH_SPACING
	end
end

local function startWaveArrowPreview()
	destroyArrowPreview()
	local path = pathData
	local tmpl = getGreenArrowsTemplate()
	if path and tmpl then
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
	-- Red GroundA train when crabs and/or urchins spawn this wave.
	startCrabArrowPreview()
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

	local ground = pathDataGround
	if ground then
		local crabSpeed = C.FISH_SPEED * C.CRAB_SPEED_MULT * C.ARROW_SPEED_MULT
		local lift = Vector3.new(0, C.CRAB_ARROW_Y_LIFT, 0)
		for i = #crabArrowPreviews, 1, -1 do
			local preview = crabArrowPreviews[i]
			if not preview.alive or not preview.model.Parent then
				WaveEntityPool.releaseRedArrows(preview.model)
				table.remove(crabArrowPreviews, i)
				continue
			end
			preview.dist += crabSpeed * dt
			preview.spin += C.ARROW_SPIN_RAD_PER_SEC * dt
			if preview.dist >= ground.totalLen then
				preview.alive = false
				WaveEntityPool.releaseRedArrows(preview.model)
				table.remove(crabArrowPreviews, i)
				continue
			end
			local pos, tang = WaveCrab.sample(ground, preview.dist)
			setArrowCFrame(preview.model, pos + lift, tang, preview.spin)
		end
	elseif #crabArrowPreviews > 0 then
		for _, preview in ipairs(crabArrowPreviews) do
			WaveEntityPool.releaseRedArrows(preview.model)
		end
		table.clear(crabArrowPreviews)
	end
end

-- UrchinMesh is a MeshPart container with RootPart + ShellHitbox children. WeldConstraints
-- don't reliably follow Anchored RootPart teleports, so snap body/shell from stored locals.
local function syncUrchinRig(agent: FishAgent)
	local rootCf = agent.root.CFrame
	local shell = agent.shellHitbox
	local shellLocal = agent.shellLocalCf
	if shell and shell.Parent and shellLocal then
		shell.Anchored = true
		shell.CFrame = rootCf * shellLocal
	end
	local bodyLocal = agent.bodyLocalCf
	local model = agent.model
	if bodyLocal and model:IsA("BasePart") and model ~= agent.root then
		model.Anchored = true
		model.CFrame = rootCf * bodyLocal
	end
	if agent.root.Parent then
		agent.root.Anchored = true
	end
end

local function captureUrchinRigLocals(agent: FishAgent)
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

local function setFishCFrame(agent: FishAgent, pos: Vector3, swimTang: Vector3, dt: number)
	agent.lastWorld = pos
	local move = if swimTang.Magnitude > 1e-5 then swimTang.Unit else Vector3.new(0, 0, -1)

	-- Same as GreenArrows: look along swim dir, then fixed authored yaw/pitch/roll.
	local desired = if isGroundCritter(agent)
		then WaveCrab.facingCFrame(pos, move)
		else CFrame.lookAt(pos, pos + move, Vector3.yAxis) * CFrame.Angles(C.TANG_PITCH, C.TANG_YAW, C.TANG_ROLL)

	if agent.isCrab then
		WaveCrab.applyPose(agent.root, desired)
		local anim = agent.crabAnim
		if anim then
			WaveCrab.stepAnim(anim, dt, pos)
		end
		return
	end
	if agent.isUrchin then
		WaveCrab.applyPose(agent.root, desired)
		syncUrchinRig(agent)
		return
	end

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

local function makeHungerBillboard(adornee: BasePart, hungryGlyphs: string?): (BillboardGui, Frame, Frame, TextLabel, TextLabel, TextLabel, UIScale)
	local glyphs = hungryGlyphs or "🍴"
	local glyphN = utf8.len(glyphs) or 1
	local emojiW = C.HUNGER_EMOJI_SIZE * glyphN
	local remainW = C.HUNGER_REMAIN_W
	local remainGap = C.HUNGER_REMAIN_GAP
	-- [fork] [N] [bar]
	local totalW = emojiW + remainGap + remainW + C.HUNGER_BAR_GAP + C.HUNGER_BAR_PX_W
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
	happy.Text = "😊"
	happy.TextSize = C.HUNGER_EMOJI_SIZE
	happy.TextScaled = false
	happy.Visible = false
	happy.ZIndex = 5
	happy.Parent = bb

	local remain = Instance.new("TextLabel")
	remain.Name = "Remain"
	remain.BackgroundTransparency = 1
	remain.AnchorPoint = Vector2.new(0, 0.5)
	remain.Position = UDim2.new(0, emojiW + remainGap, 0.5, 0)
	remain.Size = UDim2.fromOffset(remainW, C.HUNGER_REMAIN_TEXT_SIZE + 2)
	remain.Font = Enum.Font.FredokaOne
	remain.Text = ""
	remain.TextColor3 = Color3.new(1, 1, 1)
	remain.TextSize = C.HUNGER_REMAIN_TEXT_SIZE
	remain.TextScaled = false
	remain.TextXAlignment = Enum.TextXAlignment.Center
	remain.TextYAlignment = Enum.TextYAlignment.Center
	remain.ZIndex = 6
	remain.Parent = bb
	local remainStroke = Instance.new("UIStroke")
	remainStroke.Color = Color3.fromRGB(48, 48, 48)
	remainStroke.Thickness = 1.35
	remainStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	remainStroke.Parent = remain

	return bb, fill, barHost, fork, happy, remain, scale
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
	local left = math.max(0, math.ceil(agent.maxHunger - agent.hunger))
	if agent.remainLabel then
		if left > 0 then
			agent.remainLabel.Text = tostring(left)
			agent.remainLabel.Visible = true
		else
			agent.remainLabel.Text = ""
			agent.remainLabel.Visible = false
		end
	end
	if agent.hunger >= agent.maxHunger then
		markFishFullyFed(agent, nil)
		agent.barFrame.Visible = false
		agent.forkLabel.Visible = false
		if agent.remainLabel then
			agent.remainLabel.Visible = false
		end
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

local function applyCritterHungerBarsVisible()
	for _, agent in ipairs(fishList) do
		if agent.billboard then
			agent.billboard.Enabled = critterHungerBarsVisible
		end
	end
	WaveEndVfx.setHappyExitVisible(critterHungerBarsVisible)
end

local function applySizeStats(coral: CoralAgent)
	local _d, class = CoralSize.readFromPart(coral.part)
	local speciesId = coral.part:GetAttribute("OceanTD_SpeciesId")
	local sid = if typeof(speciesId) == "string" then speciesId else nil
	local st = CoralSize.statsFor(class, sid)
	coral.foodCount = st.food
	coral.range = st.range
	coral.rangeSq = st.range * st.range
	coral.defenseSec = st.defense
	coral.reloadSec = st.reload
	coral.foodFill = 1
end

local function destroyAmmo(coral: CoralAgent)
	for _, p in ipairs(coral.ammoSlots) do
		WaveEntityPool.releaseAmmo(p)
	end
	table.clear(coral.ammoSlots)
	coral.ammo = nil
	-- Do not clear coral.growing here — createAmmo calls this while starting a grow.
end

local function rollAmmoSizeMult(): number
	-- 1%–30% smaller than base AMMO_RADIUS.
	return 1 - (0.01 + math.random() * 0.29)
end

local function ammoFullDiameter(coral: CoralAgent): number
	applySizeStats(coral)
	return C.AMMO_RADIUS * 2 * coral.ammoSizeMult * CoralSize.ammoSizeScale(coral.foodCount)
end

local function ammoWorldPos(coral: CoralAgent, slot: number?): Vector3
	applySizeStats(coral)
	local r = CoralSize.ammoAnchorRadius(coral.part)
	local ammoR = C.AMMO_RADIUS * coral.ammoSizeMult * CoralSize.ammoSizeScale(coral.foodCount)
	local nVis = #coral.ammoSlots
	if nVis < 1 then
		nVis = coral.foodCount
	end
	local speciesId = coral.part:GetAttribute("OceanTD_SpeciesId")
	local sid = if typeof(speciesId) == "string" then speciesId else nil
	local offs = CoralSize.ammoLocalOffsets(nVis, r, ammoR, sid, coral.part.Size, coral.part)
	local i = math.clamp(slot or 1, 1, #offs)
	return coral.part.CFrame:PointToWorldSpace(offs[i])
end

local function parkAmmo(coral: CoralAgent)
	for i, p in ipairs(coral.ammoSlots) do
		if p.Parent then
			p.CFrame = CFrame.new(ammoWorldPos(coral, i))
		end
	end
end

local function createAmmo(coral: CoralAgent, scale: number)
	if coral.stunned then
		return
	end
	destroyAmmo(coral)
	local clamped = math.clamp(scale, 0.08, 1)
	-- New orb (grow start or instant full): pick a random 1–30% smaller size.
	if clamped <= 0.08 or clamped >= 1 then
		coral.ammoSizeMult = rollAmmoSizeMult()
	end
	applySizeStats(coral)
	local s = ammoFullDiameter(coral) * clamped
	local n = coral.foodCount
	for _ = 1, n do
		local p = WaveEntityPool.acquireAmmo(ensureFolder(), coral.color, s)
		table.insert(coral.ammoSlots, p)
	end
	parkAmmo(coral)
	coral.ammo = coral.ammoSlots[1]
end

local function startAmmoGrow(coral: CoralAgent)
	if coral.stunned or coral.growing or #coral.ammoSlots > 0 then
		return
	end
	createAmmo(coral, 0.08)
	coral.growing = true
	coral.growT0 = simClock
	coral.readyAt = math.huge
end

local function tickAmmoGrow(now: number)
	for _, coral in ipairs(coralList) do
		if coral.stunned or not coral.growing then
			continue
		end
		local reload = math.max(0.05, coral.reloadSec)
		local u = (now - coral.growT0) / reload
		if u >= 1 then
			coral.growing = false
			coral.readyAt = now
			if #coral.ammoSlots > 0 then
				local s = ammoFullDiameter(coral)
				for i, p in ipairs(coral.ammoSlots) do
					if p.Parent then
						p.Size = Vector3.new(s, s, s)
						p.CFrame = CFrame.new(ammoWorldPos(coral, i))
					end
				end
			else
				createAmmo(coral, 1)
			end
		elseif #coral.ammoSlots > 0 then
			local s = ammoFullDiameter(coral) * math.max(0.08, u)
			for i, p in ipairs(coral.ammoSlots) do
				if p.Parent then
					p.Size = Vector3.new(s, s, s)
					p.CFrame = CFrame.new(ammoWorldPos(coral, i))
				end
			end
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
	local diameter = math.max(part.Size.X, part.Size.Y, part.Size.Z)
	if species then
		reload = species.reloadSec or C.DEFAULT_RELOAD
		fillAmt = species.foodFill or C.DEFAULT_FOOD_FILL
	end
	local pid = part:GetAttribute("OceanTD_PlaceId")
	local initFed = 0
	local initWaves = 0
	if typeof(pid) == "string" and pid ~= "" then
		local st = coralStatsByPlaceId[pid] or { fed = 0, waves = 0 }
		coralStatsByPlaceId[pid] = st
		initFed = st.fed
		initWaves = st.waves
	end
	local agent: CoralAgent = {
		part = part,
		color = select(2, CoralVisual.readRestLook(part)),
		reloadSec = reload,
		foodFill = fillAmt,
		foodCount = 1,
		range = C.TARGET_RANGE,
		rangeSq = C.TARGET_RANGE_SQ,
		defenseSec = 2,
		diameter = diameter,
		readyAt = 0,
		ammo = nil,
		ammoSlots = {},
		ammoSizeMult = 1,
		growing = false,
		growT0 = 0,
		busy = false,
		shotsOut = 0,
		pathDist = 0,
		pathSideDist = 0,
		stunned = false,
		fedTotal = initFed,
		wavesTotal = initWaves,
	}
	applySizeStats(agent)
	-- Expose lifetime counters on the part for the inspect UI.
	if typeof(pid) == "string" and pid ~= "" then
		part:SetAttribute("OceanTD_CoralFedTotal", initFed)
		part:SetAttribute("OceanTD_CoralWavesTotal", initWaves)
	end
	part:GetPropertyChangedSignal("Size"):Connect(function()
		agent.diameter = math.max(part.Size.X, part.Size.Y, part.Size.Z)
		applySizeStats(agent)
		parkAmmo(agent)
	end)
	return agent
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
			if c and not c.stunned and not c.busy and not c.growing then
				createAmmo(c, 1)
				c.readyAt = 0
			end
		end
	end

	for _, c in ipairs(coralList) do
		-- Prefer rest look for shot color (ignore transient hover/relocate neon wash).
		local _, restColor = CoralVisual.readRestLook(c.part)
		c.color = restColor
		c.diameter = math.max(c.part.Size.X, c.part.Size.Y, c.part.Size.Z)
		applySizeStats(c)
		parkAmmo(c)
	end
	-- Full reproject only when arming a wave session (path is live); new places project above.
	if sessionStart then
		refreshCoralPathProjections()
	end
end

local function countAliveWaveBlockers(): number
	-- Urchins linger on GroundA after the wave advances; they must not gate the next wave.
	local n = 0
	for _, f in ipairs(fishList) do
		if not f.finished and not f.isUrchin then
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
	if agent.isCrab then
		WaveCrab.resetAnim(agent.crabAnim)
		WaveEntityPool.releaseFish(WaveEntityPool.FISH_CRAB, agent.model)
	elseif agent.isUrchin then
		WaveEntityPool.releaseFish(WaveEntityPool.FISH_URCHIN, agent.model)
	else
		WaveEntityPool.releaseFish(WaveEntityPool.FISH_TANG, agent.model)
	end
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
		markFishFullyFed(agent, nil)
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
		maxHunger = C.tangHungerForWave(waveIndex),
		finished = false,
		billboard = nil :: any,
		fill = nil :: any,
		barFrame = nil :: any,
		forkLabel = nil :: any,
		happyLabel = nil :: any,
		remainLabel = nil :: any,
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
		isCrab = false,
		isUrchin = false,
		crabAnim = nil,
		shellHitbox = nil,
		pauseUntil = nil,
		crabSprint = nil,
	}
	nextFishId += 1
	waveFishSpawned += 1
	notifyHud()
	local bb, fill, barFrame, forkLabel, happyLabel, remainLabel, barScale = makeHungerBillboard(root)
	agent.billboard = bb
	agent.fill = fill
	agent.barFrame = barFrame
	agent.forkLabel = forkLabel
	agent.happyLabel = happyLabel
	agent.remainLabel = remainLabel
	agent.barScale = barScale
	local bg = barFrame:FindFirstChild("Bg")
	if bg then
		local stroke = bg:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			agent.barStroke = stroke
		end
	end
	if bb then
		bb.Enabled = critterHungerBarsVisible
	end
	updateHungerVisual(agent)
	local world0 = fishWorldOffset(agent, pos, tang)
	agent.lastWorld = world0
	setFishCFrame(agent, world0, tang, 1)
	table.insert(fishList, agent)
end

local function spawnOneCrab(startDist: number?)
	if not WaveCrab.shouldSpawn(waveIndex) then
		return
	end
	local path = pathDataGround
	if not path then
		return
	end
	local clone, root = WaveEntityPool.acquireFish(WaveEntityPool.FISH_CRAB, "Crab_" .. tostring(nextFishId))
	if not clone or not root then
		return
	end
	clone.Parent = ensureFolder()
	local dist0 = math.clamp(startDist or 0, 0, math.max(0, path.totalLen - 1))
	local pos, tang = WaveCrab.sample(path, dist0)
	local lateral = fishRng:NextNumber(-C.CRAB_LATERAL_SPREAD, C.CRAB_LATERAL_SPREAD)
	local wanderAmp = fishRng:NextNumber(C.CRAB_WANDER_AMP_MIN, C.CRAB_WANDER_AMP_MAX)
	local wanderFreq = fishRng:NextNumber(0.08, 0.18)
	local wanderPhase = fishRng:NextNumber(0, math.pi * 2)
	-- Apply lateral before ground snap so spawn matches move loop.
	do
		local side = Vector3.new(-tang.Z, 0, tang.X)
		if side.Magnitude > 1e-4 then
			side = side.Unit
			pos = pos + side * lateral
		end
	end
	pos = WaveCrab.worldOnGround(pos, nil, 1)
	local anim = WaveCrab.bindAnim(clone, root)
	local agent: FishAgent = {
		id = nextFishId,
		root = root,
		model = clone,
		dist = dist0,
		lateral = lateral,
		vert = 0,
		bobAmp = 0,
		bobFreq = 1,
		bobPhase = 0,
		wanderAmp = wanderAmp,
		wanderFreq = wanderFreq,
		wanderPhase = wanderPhase,
		speedPhase = 0,
		speedFreq = 1,
		hunger = 0,
		maxHunger = WaveCrab.hungerForWave(waveIndex),
		finished = false,
		billboard = nil :: any,
		fill = nil :: any,
		barFrame = nil :: any,
		forkLabel = nil :: any,
		happyLabel = nil :: any,
		remainLabel = nil :: any,
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
		isCrab = true,
		isUrchin = false,
		crabAnim = anim,
		shellHitbox = WaveCrab.findShell(clone),
		pauseUntil = nil,
		stunSkullPart = nil,
		crabSprint = WaveCrab.newSprint(),
	}
	nextFishId += 1
	WaveCrab.markSpawned()
	notifyHud()
	local bb, fill, barFrame, forkLabel, happyLabel, remainLabel, barScale = makeHungerBillboard(root, "⚡🍴")
	agent.billboard = bb
	agent.fill = fill
	agent.barFrame = barFrame
	agent.forkLabel = forkLabel
	agent.happyLabel = happyLabel
	agent.remainLabel = remainLabel
	agent.barScale = barScale
	local bg = barFrame:FindFirstChild("Bg")
	if bg then
		local stroke = bg:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			agent.barStroke = stroke
		end
	end
	if bb then
		bb.Enabled = critterHungerBarsVisible
	end
	updateHungerVisual(agent)
	agent.lastWorld = pos
	setFishCFrame(agent, pos, tang, 1)
	table.insert(fishList, agent)
end

local function spawnOneUrchin(startDist: number?)
	if not WaveUrchin.shouldSpawn(waveIndex) then
		return
	end
	local path = pathDataGround
	if not path then
		return
	end
	local clone, root = WaveEntityPool.acquireFish(WaveEntityPool.FISH_URCHIN, "Urchin_" .. tostring(nextFishId))
	if not clone or not root then
		return
	end
	clone.Parent = ensureFolder()
	local dist0 = math.clamp(startDist or 0, 0, math.max(0, path.totalLen - 1))
	local pos, tang = WaveUrchin.sample(path, dist0)
	local lateral = fishRng:NextNumber(-C.CRAB_LATERAL_SPREAD, C.CRAB_LATERAL_SPREAD)
	local wanderAmp = fishRng:NextNumber(C.CRAB_WANDER_AMP_MIN, C.CRAB_WANDER_AMP_MAX)
	local wanderFreq = fishRng:NextNumber(0.08, 0.18)
	local wanderPhase = fishRng:NextNumber(0, math.pi * 2)
	do
		local side = Vector3.new(-tang.Z, 0, tang.X)
		if side.Magnitude > 1e-4 then
			side = side.Unit
			pos = pos + side * lateral
		end
	end
	pos = WaveUrchin.worldOnGround(pos, nil, 1)
	local agent: FishAgent = {
		id = nextFishId,
		root = root,
		model = clone,
		dist = dist0,
		lateral = lateral,
		vert = 0,
		bobAmp = 0,
		bobFreq = 1,
		bobPhase = 0,
		wanderAmp = wanderAmp,
		wanderFreq = wanderFreq,
		wanderPhase = wanderPhase,
		speedPhase = 0,
		speedFreq = 1,
		hunger = 0,
		maxHunger = WaveUrchin.hungerForWave(waveIndex),
		finished = false,
		billboard = nil :: any,
		fill = nil :: any,
		barFrame = nil :: any,
		forkLabel = nil :: any,
		happyLabel = nil :: any,
		remainLabel = nil :: any,
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
	WaveUrchin.markSpawned()
	notifyHud()
	captureUrchinRigLocals(agent)
	local bb, fill, barFrame, forkLabel, happyLabel, remainLabel, barScale = makeHungerBillboard(root, "✴🍴")
	agent.billboard = bb
	agent.fill = fill
	agent.barFrame = barFrame
	agent.forkLabel = forkLabel
	agent.happyLabel = happyLabel
	agent.remainLabel = remainLabel
	agent.barScale = barScale
	local bg = barFrame:FindFirstChild("Bg")
	if bg then
		local stroke = bg:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			agent.barStroke = stroke
		end
	end
	if bb then
		bb.Enabled = critterHungerBarsVisible
	end
	updateHungerVisual(agent)
	agent.lastWorld = pos
	setFishCFrame(agent, pos, tang, 1)
	-- Re-capture after first pose so locals match the grounded spawn orientation.
	captureUrchinRigLocals(agent)
	table.insert(fishList, agent)
end

local function waveFishCount(wave: number): number
	return C.WAVE1_COUNT + (wave - 1) * C.WAVE_COUNT_STEP
end

local function spawnGapForWave(wave: number): number
	local w = math.max(1, math.floor(wave))
	local gap = C.STAGGER_SEC * (C.STAGGER_PER_WAVE_MULT ^ (w - 1))
	return math.max(C.STAGGER_MIN_SEC, gap)
end

local function restoreStunnedCorals(fade: boolean)
	for _, c in ipairs(coralList) do
		if not c.stunned then
			continue
		end
		c.stunned = false
		c.busy = false
		c.growing = false
		c.readyAt = simClock
		if c.part.Parent then
			WaveCrab.clearCoralStun(c.part, fade)
		end
		if running then
			createAmmo(c, 1)
		end
	end
end

local function beginWave(wave: number)
	pruneFinishedFish()
	waveIndex = wave
	waveFishExpected = waveFishCount(wave)
	waveFishSpawned = 0
	waveFishFullyFed = 0
	WaveCrab.beginWave(WaveCrab.rollCount(wave))
	WaveUrchin.beginWave(WaveUrchin.rollCount(wave))
	restoreStunnedCorals(wave > 1)
	-- Path preview: GreenArrows race the full route; fish follow 1s later.
	startWaveArrowPreview()
	waveSpawning = true
	spawnQueue = waveFishCount(wave)
	spawnDelay = C.ARROW_LEAD_SEC
	local nUrchin = WaveUrchin.expectedCount()
	urchinSpawnQueue = nUrchin
	urchinSpawnDelay = if nUrchin > 0
		then fishRng:NextNumber(C.URCHIN_FIRST_DELAY_MIN, C.URCHIN_FIRST_DELAY_MAX)
		else 0
	crabSpawnQueue = 0
	crabSpawnDelay = 0
	-- Session start: arm all corals. Later waves: keep reload state; only pick up new places.
	syncCorals(wave == 1)
	local path = pathData
	if path and #path.segments > 0 then
		WaveStartVfx.play(wave, path.segments[1].w0)
	end
	if wave == 1 then
		Wave1LeadArrow.start(function()
			local fish = WaveSim.getFurthestLiveFish()
			return if fish then fish.position else nil
		end)
	else
		Wave1LeadArrow.stop()
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
		if f.finished or isGroundCritter(f) or f.hunger + f.incomingFood >= f.maxHunger then
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
	local fill = coral.foodFill
	local cd = coral.pathDist
	local lead = math.max(C.PATH_TARGET_LEAD_MAX, coral.range)
	local d0 = math.max(0, cd - lead)
	local d1 = math.min(path.totalLen, cd + C.PATH_TARGET_PAST)
	local b0 = math.floor(d0 / C.PATH_BUCKET_SIZE) + 1
	local b1 = math.floor(d1 / C.PATH_BUCKET_SIZE) + 1
	local origin = coral.part.Position
	local best: FishAgent? = nil
	local bestScore = coral.rangeSq
	local laneOk = coral.pathSideDist <= coral.range + C.LATERAL_SPREAD

	local function consider(f: FishAgent)
		if not fishNeedsFood(f, fill) then
			return
		end
		local fp = f.root.Position
		local dx = fp.X - origin.X
		local dy = fp.Y - origin.Y
		local dz = fp.Z - origin.Z
		local d2 = dx * dx + dy * dy + dz * dz
		if d2 > coral.rangeSq then
			return
		end
		local score = d2
		-- Prefer fish at/past this coral so stragglers don't slip through unfed
		-- while the school still approaching soaks every shot. Crabs use GroundA.
		if not isGroundCritter(f) then
			if f.dist >= cd - 1 then
				score *= 0.4
			elseif f.dist < cd then
				score *= 0.9
			end
		end
		if score < bestScore then
			bestScore = score
			best = f
		end
	end

	if laneOk then
		for bi = b0, b1 do
			local bucket = fishPathBuckets[bi]
			if bucket then
				for _, f in ipairs(bucket) do
					consider(f)
				end
			end
		end
		if not best then
			for _, f in ipairs(fishList) do
				if not isGroundCritter(f) then
					consider(f)
				end
			end
		end
	end
	-- Hungry fish first; urchins before crabs if no fish in range.
	if not best then
		for _, f in ipairs(fishList) do
			if f.isUrchin then
				consider(f)
			end
		end
	end
	if not best then
		for _, f in ipairs(fishList) do
			if f.isCrab then
				consider(f)
			end
		end
	end
	return best
end

-- Predict mouth world pos using the same path + offset math the fish uses.
-- Integrates each fish's ±FISH_SPEED_VAR surge (constant FISH_SPEED caused systematic misses).
local function fishSpeedFactorAt(agent: FishAgent, clock: number): number
	if isGroundCritter(agent) then
		return 1
	end
	return 1 + C.FISH_SPEED_VAR * math.sin(clock * agent.speedFreq + agent.speedPhase)
end

local function predictFishDistAhead(agent: FishAgent, aheadSec: number): number
	local steps = math.max(4, math.ceil(aheadSec * 24))
	local stepDt = aheadSec / steps
	local dist = agent.dist
	local t = simClock
	local speed = if agent.isUrchin
		then WaveUrchin.speedNow()
		elseif agent.isCrab then WaveCrab.speedNow(agent.crabSprint, simClock)
		else C.FISH_SPEED
	for _ = 1, steps do
		dist += speed * fishSpeedFactorAt(agent, t) * stepDt
		t += stepDt
	end
	return dist
end

local function predictFishMeetPos(agent: FishAgent, aheadSec: number): Vector3?
	if isGroundCritter(agent) then
		local ground = pathDataGround
		if not ground then
			return nil
		end
		local futureDist = predictFishDistAhead(agent, aheadSec)
		if futureDist >= ground.totalLen - 0.35 then
			return nil
		end
		local pathPos, tang = WaveCrab.sample(ground, futureDist)
		local offset = fishWorldOffset(agent, pathPos, tang, futureDist)
		local pos = WaveCrab.worldOnGround(offset, nil, 1)
		local fwd = if tang.Magnitude > 1e-5 then tang.Unit else agent.smoothTang
		if fwd.Magnitude < 1e-5 then
			fwd = Vector3.new(0, 0, -1)
		else
			fwd = fwd.Unit
		end
		return pos + fwd * C.FOOD_FRONT_LEAD
	end
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
	-- Ground critters: lob up then down onto the shell (fish keep the flatter path).
	local target = shot.target
	if target and isGroundCritter(target) then
		local flat = Vector3.new(along.X, 0, along.Z).Magnitude
		local arcH = math.clamp(flat * C.FOOD_CRAB_ARC_FRAC, C.FOOD_CRAB_ARC_MIN, C.FOOD_CRAB_ARC_MAX)
		base = base + Vector3.yAxis * (math.sin(t * math.pi) * arcH)
	end
	return base
end

local function fireShot(coral: CoralAgent, target: FishAgent)
	local orb = coral.ammoSlots[1]
	local start = if orb then orb.Position else ammoWorldPos(coral, 1)
	if orb then
		WaveEntityPool.releaseAmmo(orb)
		table.remove(coral.ammoSlots, 1)
		coral.ammo = coral.ammoSlots[1]
		parkAmmo(coral)
	end
	local fp = target.root.Position
	local flatX = fp.X - start.X
	local flatZ = fp.Z - start.Z
	local flat = math.sqrt(flatX * flatX + flatZ * flatZ)
	-- Estimate duration from distance; prediction uses the fish's live speed curve.
	local speedNow = (if target.isUrchin
		then WaveUrchin.speedNow()
		elseif target.isCrab then WaveCrab.speedNow(target.crabSprint, simClock)
		else C.FISH_SPEED) * math.max(0.55, fishSpeedFactorAt(target, simClock))
	local duration = math.clamp(flat / speedNow + C.FOOD_FIRE_LEAD_SEC, C.FOOD_RISE_MIN, C.FOOD_RISE_MAX)
	local meet = predictFishMeetPos(target, duration)
	-- Near route end (or bad predict): still fire at the live mouth — don't let them ghost past.
	if not meet then
		meet = fishMouthWorld(target)
		duration = math.clamp(duration * 0.65, C.FOOD_RISE_MIN * 0.75, C.FOOD_RISE_MAX)
	end

	coral.shotsOut += 1
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
	coral.shotsOut = math.max(0, coral.shotsOut - 1)
	if coral.shotsOut <= 0 and #coral.ammoSlots == 0 then
		coral.busy = false
		startAmmoGrow(coral)
	end
	local target = shot.target
	clearShotTarget(shot)
	if fed and target and not target.finished and target.hunger < target.maxHunger then
		target.hunger = math.min(target.maxHunger, target.hunger + shot.fill)
		if (not target.payoutDone) and target.hunger >= target.maxHunger then
			target.payoutDone = true
			WaveFeedPayout.noteFilled(target.root.Position)
		end
		if target.hunger >= target.maxHunger then
			markFishFullyFed(target, coral)
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
		if coral.stunned or coral.growing then
			continue
		end
		if now < coral.readyAt then
			continue
		end
		if #coral.ammoSlots == 0 then
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

local function findCoralByPart(part: BasePart): CoralAgent?
	for _, c in ipairs(coralList) do
		if c.part == part then
			return c
		end
	end
	return nil
end

local function reviveCoralFromAttack(coral: CoralAgent)
	if not coral.stunned then
		return
	end
	coral.stunned = false
	coral.busy = false
	coral.growing = false
	coral.readyAt = simClock
	if coral.part.Parent then
		WaveCrab.clearCoralStun(coral.part, true)
	end
	if running then
		createAmmo(coral, 1)
	end
end

local function abortCrabCoralKill(agent: FishAgent)
	local part = agent.stunSkullPart
	agent.stunSkullPart = nil
	agent.pauseUntil = nil
	if part then
		local coral = findCoralByPart(part)
		if coral then
			reviveCoralFromAttack(coral)
		elseif part.Parent then
			WaveCrab.clearCoralStun(part, true)
		end
	end
end

local function stunCoralFromCrab(coral: CoralAgent)
	if coral.stunned then
		return
	end
	coral.stunned = true
	coral.growing = false
	coral.busy = false
	coral.readyAt = math.huge
	destroyAmmo(coral)
	if coral.part.Parent then
		WaveCrab.stunCoralPart(coral.part)
	end
	for _, shot in ipairs(activeShots) do
		if shot.alive and shot.coral == coral then
			finishShot(shot, false)
		end
	end
end

local function tickFish(dt: number)
	local path = pathData
	if not path then
		return
	end
	local ground = pathDataGround
	for _, agent in ipairs(fishList) do
		if agent.finished then
			continue
		end
		if isGroundCritter(agent) then
			if not ground then
				finishFish(agent)
				continue
			end
			local isCrab = agent.isCrab == true
			local wasFighting = agent.pauseUntil ~= nil
			local paused = wasFighting and os.clock() < (agent.pauseUntil :: number)
			-- Fed mid-fight: drop the attack, restore the coral, keep walking.
			if paused and agent.hunger >= agent.maxHunger then
				abortCrabCoralKill(agent)
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
						local coral = findCoralByPart(skullPart)
						if coral then
							reviveCoralFromAttack(coral)
						elseif skullPart.Parent then
							WaveCrab.clearCoralStun(skullPart, true)
						end
					end
				end
				agent.pauseUntil = nil
				if isCrab then
					local sprint = agent.crabSprint
					if sprint then
						WaveCrab.tickSprint(sprint, simClock)
					end
					agent.dist += WaveCrab.speedNow(sprint, simClock) * dt
				else
					agent.dist += WaveUrchin.speedNow() * dt
				end
			end
			if agent.dist >= ground.totalLen then
				finishFish(agent)
				continue
			end
			local pathPos, tang = WaveCrab.sample(ground, agent.dist)
			local swimTang = stepSwimTang(agent, tang, dt)
			local offset = fishWorldOffset(agent, pathPos, swimTang, agent.dist)
			local pos = WaveCrab.worldOnGround(offset, agent.lastWorld.Y, dt)
			if paused then
				agent.lastWorld = pos
				WaveCrab.applyFightPose(
					agent.root,
					agent.crabAnim,
					pos,
					swimTang,
					dt,
					WaveCrab.pauseElapsed(agent.pauseUntil, agent.pauseDur),
					agent.id,
					agent.pauseDur
				)
				if agent.isUrchin then
					syncUrchinRig(agent)
				end
			else
				setFishCFrame(agent, pos, swimTang, dt)
			end
			local hungry = agent.hunger < agent.maxHunger
			setDangerFlash(agent, hungry and isNearPathEnd(ground.totalLen, agent.dist))
			-- Only hungry ground critters fight; a full one walks through without stunning the coral.
			if hungry and not paused then
				local shell = agent.shellHitbox
				-- Fallback: root-centered box if shell never resolved (shouldn't happen).
				local hitPart = shell or agent.root
				if hitPart then
					for _, coral in ipairs(coralList) do
						if coral.stunned or not coral.part.Parent then
							continue
						end
						if WaveCrab.shellOverlapsCoral(hitPart, coral.part) then
							stunCoralFromCrab(coral)
							local pauseSec = if isCrab
								then coral.defenseSec
								else WaveUrchin.coralPauseSec(coral.defenseSec)
							agent.pauseDur = pauseSec
							agent.pauseUntil = os.clock() + pauseSec
							agent.stunSkullPart = coral.part
							local follow = agent
							WaveCrab.playZapBurst(
								ensureFolder(),
								function()
									if follow.finished or not follow.root.Parent then
										return pos
									end
									local shellNow = follow.shellHitbox
									if shellNow and shellNow.Parent then
										return shellNow.Position
									end
									return follow.root.Position
								end,
								pauseSec,
								function()
									local untilT = follow.pauseUntil
									return untilT ~= nil and os.clock() < untilT
								end
							)
							break
						end
					end
				end
			end
			continue
		end
		agent.dist += C.FISH_SPEED * (1 + C.FISH_SPEED_VAR * math.sin(simClock * agent.speedFreq + agent.speedPhase)) * dt
		if agent.dist >= path.totalLen then
			finishFish(agent)
			continue
		end
		local pos, tang = samplePath(path, agent.dist)
		local swimTang = stepSwimTang(agent, tang, dt)
		local world = fishWorldOffset(agent, pos, swimTang)
		setFishCFrame(agent, world, swimTang, dt)
		local hungry = agent.hunger < agent.maxHunger
		setDangerFlash(agent, hungry and isNearPathEnd(path.totalLen, agent.dist))
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

local function tickUrchinPlayerStings()
	local now = os.clock()
	local cooldown = C.URCHIN_STING_COOLDOWN_SEC
	local hitR = C.URCHIN_STING_HIT_RADIUS
	local hitY = C.URCHIN_STING_HIT_Y
	local localPlayer = Players.LocalPlayer
	for _, agent in ipairs(fishList) do
		if agent.finished or not agent.isUrchin then
			continue
		end
		local uPos = agent.lastWorld
		for _, plr in ipairs(Players:GetPlayers()) do
			local uid = plr.UserId
			local last = stingReportAt[uid]
			if last and now - last < cooldown then
				continue
			end
			local char = plr.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if not (hrp and hrp:IsA("BasePart")) then
				continue
			end
			local p = hrp.Position
			local dx = p.X - uPos.X
			local dz = p.Z - uPos.Z
			if dx * dx + dz * dz > hitR * hitR then
				continue
			end
			if math.abs(p.Y - uPos.Y) > hitY then
				continue
			end
			stingReportAt[uid] = now
			if plr == localPlayer then
				UrchinStingEffects.playLocal(uPos)
			end
			reportUrchinSting:FireServer(uid, uPos.X, uPos.Y, uPos.Z)
		end
	end
end

local function makeSummary(): Summary
	return {
		waveReached = math.max(1, waveIndex),
		fishFed = fishFed,
		elapsedSec = wallElapsedSec(),
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
	table.clear(stingReportAt)
	restoreStunnedCorals(false)
	for _, c in ipairs(coralList) do
		c.growing = false
		c.busy = false
		destroyAmmo(c)
	end
	table.clear(coralList)
	spawnQueue = 0
	crabSpawnQueue = 0
	crabSpawnDelay = 0
	urchinSpawnQueue = 0
	urchinSpawnDelay = 0
	waveSpawning = false
	destroyArrowPreview()
	WaveStartVfx.cancel()
	Wave1LeadArrow.stop()
end

-- Wipe fish/crabs for the next wave; trailing urchins keep walking GroundA.
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
	local kept: { FishAgent } = {}
	for _, f in ipairs(fishList) do
		if f.isUrchin and not f.finished then
			table.insert(kept, f)
		else
			destroyFish(f)
		end
	end
	fishList = kept
	spawnQueue = 0
	crabSpawnQueue = 0
	crabSpawnDelay = 0
	urchinSpawnQueue = 0
	urchinSpawnDelay = 0
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

function WaveSim.areCritterHungerBarsVisible(): boolean
	return critterHungerBarsVisible
end

function WaveSim.setCritterHungerBarsVisible(visible: boolean)
	if critterHungerBarsVisible == visible then
		return
	end
	critterHungerBarsVisible = visible
	applyCritterHungerBarsVisible()
end

function WaveSim.toggleCritterHungerBarsVisible(): boolean
	critterHungerBarsVisible = not critterHungerBarsVisible
	applyCritterHungerBarsVisible()
	return critterHungerBarsVisible
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
		elapsedSec = wallElapsedSec(),
		running = running,
		feedProgress = feedProg,
		feedComplete = feedDone,
		hungerDanger = anyHungerDanger(),
		hungryMissToken = hungryMissToken,
		fishFull = fishFull,
		fishTotal = fishTotal,
		crabTotal = WaveCrab.expectedCount(),
		urchinTotal = WaveUrchin.expectedCount(),
		speedMult = speedMult,
	}
end

-- Furthest along the route among fish that still need food (wave-1 cam focus).
function WaveSim.getFurthestUnfedFish(): { id: number, position: Vector3 }?
	local best: FishAgent? = nil
	for _, f in ipairs(fishList) do
		if f.finished or isGroundCritter(f) or f.hunger >= f.maxHunger then
			continue
		end
		if not f.root.Parent then
			continue
		end
		if not best or f.dist > best.dist then
			best = f
		end
	end
	if not best then
		return nil
	end
	return { id = best.id, position = best.root.Position }
end

-- Furthest along the route among fish still swimming (fed or hungry).
function WaveSim.getFurthestLiveFish(): { id: number, position: Vector3 }?
	local best: FishAgent? = nil
	for _, f in ipairs(fishList) do
		if f.finished or isGroundCritter(f) or not f.root.Parent then
			continue
		end
		if not best or f.dist > best.dist then
			best = f
		end
	end
	if not best then
		return nil
	end
	return { id = best.id, position = best.root.Position }
end

-- Live world pose for a fish still on the path (fed or hungry).
function WaveSim.getFishPosition(id: number): Vector3?
	for _, f in ipairs(fishList) do
		if f.id == id and not f.finished and f.root.Parent then
			return f.root.Position
		end
	end
	return nil
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
	-- Credit remaining full fish/crabs; urchins keep walking their route.
	for _, f in ipairs(fishList) do
		if not f.finished and not f.isUrchin and f.hunger >= f.maxHunger then
			finishFish(f, true)
		end
	end
	if endPos and #burstEmojis > 0 then
		WaveEndVfx.burstHappyFirework(burstEmojis, endPos)
	end
	awardCoralWaveCompleted(waveIndex)
	clearActiveWaveEntities()
	UiHaptics.pulseTriple()
	resumeNormalSpeedIfPaused()
	beginWave(waveIndex + 1)
	notifyHud()
	flushHud()
	return true
end

function WaveSim.skipToNextWave(): boolean
	if not running then
		return false
	end
	awardCoralWaveCompleted(waveIndex)
	clearActiveWaveEntities()
	UiHaptics.pulseTriple()
	resumeNormalSpeedIfPaused()
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
	critterHungerBarsVisible = true
	WaveEndVfx.setHappyExitVisible(true)
	resetSpeedState()
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
		-- Speed pause: freeze fish, crabs, food, ammo, combat, spawns; HUD clock holds.
		-- Urchin sting still runs so players can walk into paused urchins.
		if speedMult <= 1e-6 then
			tickUrchinPlayerStings()
			flushHud()
			return
		end
		local simDt = dt * speedMult
		simClock += simDt
		-- Urchins spawn before the fish school (waves 10/20/30…).
		if urchinSpawnQueue > 0 then
			urchinSpawnDelay -= simDt
			if urchinSpawnDelay <= 0 then
				spawnOneUrchin(0)
				urchinSpawnQueue -= 1
				urchinSpawnDelay = if urchinSpawnQueue > 0
					then fishRng:NextNumber(C.URCHIN_STAGGER_MIN, C.URCHIN_STAGGER_MAX)
					else 0
			end
		end
		-- Spawning (first fish waits C.ARROW_LEAD_SEC after GreenArrows start)
		if waveSpawning and spawnQueue > 0 then
			spawnDelay -= simDt
			if spawnDelay <= 0 then
				local idx = waveFishCount(waveIndex) - spawnQueue + 1
				spawnOneFish(idx)
				if idx == 1 then
					local nCrab = WaveCrab.expectedCount()
					if nCrab > 0 then
						crabSpawnQueue = nCrab
						crabSpawnDelay = fishRng:NextNumber(C.CRAB_FIRST_DELAY_MIN, C.CRAB_FIRST_DELAY_MAX)
					end
				end
				spawnQueue -= 1
				-- Slight random gap so the school reads as a parade, not a metronome.
				spawnDelay = spawnGapForWave(waveIndex) * fishRng:NextNumber(0.7, 1.35)
				if spawnQueue <= 0 then
					waveSpawning = false
				end
			end
		end

		if crabSpawnQueue > 0 then
			crabSpawnDelay -= simDt
			if crabSpawnDelay <= 0 then
				spawnOneCrab(0)
				crabSpawnQueue -= 1
				crabSpawnDelay = if crabSpawnQueue > 0
					then fishRng:NextNumber(C.CRAB_STAGGER_MIN, C.CRAB_STAGGER_MAX)
					else 0
			end
		end

		tickArrowPreview(simDt)
		tickFish(simDt)
		tickUrchinPlayerStings()
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

		-- Wave complete → next wave immediately (urchins may still be walking GroundA).
		if not waveSpawning and spawnQueue <= 0 and crabSpawnQueue <= 0 and urchinSpawnQueue <= 0 and countAliveWaveBlockers() == 0 then
			awardCoralWaveCompleted(waveIndex)
			UiHaptics.pulseTriple()
			resumeNormalSpeedIfPaused()
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
	pathDataGround = WaveCrab.buildLocal()
	if not pathData then
		return false
	end
	if not WaveEntityPool.hasFishKind(WaveEntityPool.FISH_TANG) then
		warn("[WAVE] ReplicatedStorage.HungryFish missing")
		return false
	end
	token += 1
	local myToken = token
	running = true
	reefMaxHealth = reefMaxFromSkills()
	reefHealth = math.clamp(math.floor(hearts + 0.5), 1, reefMaxHealth)
	resetSpeedState()
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
	pathDataGround = WaveCrab.buildLocal()
	if not pathData then
		return false
	end
	if not WaveEntityPool.hasFishKind(WaveEntityPool.FISH_TANG) then
		warn("[WAVE] ReplicatedStorage.HungryFish missing")
		return false
	end
	token += 1
	local myToken = token
	running = true
	waveIndex = 0
	reefMaxHealth = reefMaxFromSkills()
	reefHealth = reefMaxHealth
	fishFed = 0
	WaveEndVfx.resetStreak()
	feedPitchCursor = C.FEED_PITCH_MIN
	startedAt = os.clock()
	simClock = 0
	resetSpeedState()
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

function WaveSim.rebuildRouteForPlotSize(plotSizeStage: number?): boolean
	local p = buildPath(plotSizeStage)
	if not p then
		return false
	end
	pathData = p
	pathDataGround = WaveCrab.buildLocal()
	-- Fish already past the new end finish there; others keep swimming on the longer/shorter route.
	for _, agent in ipairs(fishList) do
		if agent.isCrab or agent.isUrchin then
			continue
		end
		if not agent.finished and agent.dist >= p.totalLen then
			finishFish(agent)
		end
	end
	if running then
		refreshCoralPathProjections()
		notifyHud()
		flushHud()
	end
	return true
end

function WaveSim.getSpeedMult(): number
	return speedMult
end

function WaveSim.isSpeedPaused(): boolean
	return speedMult <= 1e-6
end

-- Cycle within unlocked steps: 1 → 1.5 → 2 → (pause if stage 4) → 1.
function WaveSim.cycleSpeed(maxStep: number?): number
	local cap = math.clamp(math.floor(tonumber(maxStep) or 3), 1, #SPEED_STEPS)
	local n = if cap >= 4 then 4 else math.min(cap, 3)
	local idx = 1
	local found = false
	for i = 1, n do
		if math.abs(speedMult - SPEED_STEPS[i]) < 1e-4 then
			idx = i
			found = true
			break
		end
	end
	if not found then
		-- Paused without unlock, or unknown mult → start from normal.
		if speedMult <= 1e-6 and n < 4 then
			idx = n -- will wrap to 1
		else
			idx = 1
		end
	end
	idx = idx % n + 1
	local wasPaused = speedMult <= 1e-6
	speedMult = SPEED_STEPS[idx]
	local nowPaused = speedMult <= 1e-6
	if wasPaused ~= nowPaused then
		applySpeedPauseState(nowPaused)
	end
	notifyHud()
	return speedMult
end

function WaveSim.clampSpeedToMaxStep(maxStep: number)
	local cap = math.clamp(math.floor(tonumber(maxStep) or 3), 1, #SPEED_STEPS)
	if speedMult <= 1e-6 then
		if cap < 4 then
			applySpeedPauseState(false)
			speedMult = 1
			notifyHud()
		end
		return
	end
	local maxPlay = math.min(cap, 3)
	local allowed = SPEED_STEPS[maxPlay]
	if speedMult > allowed + 1e-4 then
		speedMult = allowed
		notifyHud()
	end
end

function WaveSim.formatClock(sec: number): string
	local s = math.max(0, math.floor(sec + 0.5))
	local h = s // 3600
	local m = (s % 3600) // 60
	local r = s % 60
	return string.format("%02d:%02d:%02d", h, m, r)
end

return WaveSim
