--!strict
--[[
	Client-only feed-wave simulation (solo). Fish, food, reef health — not replicated.
	Optimized: path samples once, spatial hash for coral↔fish, 10 Hz targeting, pooled FX.
]]

local Players = game:GetService("Players")
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

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local WaveSim = {}

local FISH_SPEED = 16 -- 20 * 0.8
local FISH_SPEED_VAR = 0.15 -- ±15% smooth speed variation
local FOOD_SPEED = 24 -- 20 * 1.2
local DEFAULT_RELOAD = 3 -- matches BrainCoral (50% slower than original 2s)
local TARGET_RANGE = 50 -- was 30; +20 studs
local TARGET_RANGE_SQ = TARGET_RANGE * TARGET_RANGE
local COMBAT_HZ = 10
local COMBAT_DT = 1 / COMBAT_HZ
local PATH_SAMPLE_STEP = 1.5
local STAGGER_SEC = 0.4
local LATERAL_SPREAD = 7.5 -- base left/right spread across the school
local VERT_SPREAD = 2.8 -- base height spread
local BOB_AMP_MIN = 2.5
local BOB_AMP_MAX = 5.0 -- slow vertical wander
local WANDER_AMP_MIN = 3.5
local WANDER_AMP_MAX = 7.25
local HASH_CELL = 30
local DEFAULT_FOOD_FILL = 1
local WAVE1_COUNT = 6
local WAVE_COUNT_STEP = 4
local WAVE_COUNT_MAX = 40
local REEF_START_HEALTH = 10
local TANG_HUNGER = 4
local FOOD_RADIUS = 0.65
local AMMO_RADIUS = 0.75
local HUNGER_BAR_PX_W = 40
local HUNGER_BAR_STRIP_H = 6
local HUNGER_EMOJI_SIZE = HUNGER_BAR_STRIP_H * 3 -- 18px; outside & in front of the bar
local HUNGER_BAR_GAP = 3
local HUNGER_BAR_PX_H = HUNGER_EMOJI_SIZE
local HUNGER_BAR_HEIGHT = 2.85 -- studs above fish
local HUNGER_BAR_MAX_DIST = 220 -- LOD hide distance when not in danger
local HUNGER_BAR_DANGER_MAX_DIST = 0 -- 0 = no distance cull while flashing red
local HAPPY_EMOJIS = { "😊", "😄", "😁", "😆", "🥰", "😍", "💖", "🤩" }
local HAPPY_FLASH_ON = 2
local HAPPY_FLASH_OFF = 3
local FILL_GREEN = Color3.fromRGB(40, 255, 90)
local DANGER_RED = Color3.fromRGB(255, 45, 55)
local REEF_TICK_SOUND_ID = "rbxassetid://128707491647978"
local REEF_TICK_PITCH_START = 1.2
local REEF_TICK_PITCH_STEP = 0.09
local REEF_TICK_PITCH_MIN = 0.45
local REEF_TICK_GAP = 0.07
local FEED_SOUND_ID = "rbxassetid://139487580236703"
local FEED_PITCH_MIN = 0.82
local FEED_PITCH_MAX = 1.28
local FEED_PITCH_STEP = 0.06
local HEART_LOSS_MAX_STUDS = 100
local HEART_LOSS_PULSE_SEC = 0.55
local ARROW_SPEED_MULT = 4 -- GreenArrows travel this × fish speed
local ARROW_LEAD_SEC = 1 -- fish spawn this long after arrows start
local ARROW_SOUND_ID = "rbxassetid://1845466760"
local ARROW_COUNT = 11
local ARROW_WP_SPACING = 2 -- start each set this many waypoints apart
local ARROW_SPIN_RAD_PER_SEC = 2.2 -- slow corkscrew roll
-- Flat carpet was backwards; yaw 180 fixes facing. Roll 90 stands it up like a fence
-- (pitch ±90 was tipping the tips straight down).
local ARROW_YAW = math.rad(180)
local ARROW_ROLL = math.rad(90)
local WAVE_LABEL_SCALE = Vector2.new(14 * 1.15, 5 * 1.15) -- studs; +15% vs original
local WAVE_LABEL_HEIGHT = 4
local PATH_BEAD_SPEED_MULT = 2 -- green spheres × fish speed
local PATH_BEAD_SPACING = 20
local PATH_BEAD_ACTIVE_SEC = 15 -- was 10; +5s visible
local PATH_BEAD_FADE_SEC = 1.25
local PATH_BEAD_DIAMETER = 1.1
local PATH_BEAD_PULSE_MIN = 0.55 -- shrink/grow scale range
local PATH_BEAD_PULSE_MAX = 3.0 -- 3× base diameter at peak
local PATH_BEAD_PULSE_DIST = 0.22 -- rad per stud along path
local PATH_BEAD_PULSE_TIME = 3.2 -- rad per second
local PATH_BEAD_GREEN = Color3.fromRGB(40, 255, 90)
-- Tang facing: lookAt + fixed yaw (same idea as GreenArrows). −90 was nose-back; +180° → 90°.
local TANG_YAW = math.rad(90)
local TANG_PITCH = 0
local TANG_ROLL = 0
local TURN_RATE = 14 -- higher = snappier yaw toward path tangent

local reefTickSound = Instance.new("Sound")
reefTickSound.Name = "OceanTD_ReefTick"
reefTickSound.SoundId = REEF_TICK_SOUND_ID
reefTickSound.Volume = 0.95
reefTickSound.Parent = SoundService

local feedSound = Instance.new("Sound")
feedSound.Name = "OceanTD_FeedHit"
feedSound.SoundId = FEED_SOUND_ID
feedSound.Volume = 0.85
feedSound.Parent = SoundService

local arrowSound = Instance.new("Sound")
arrowSound.Name = "OceanTD_WaveArrows"
arrowSound.SoundId = ARROW_SOUND_ID
arrowSound.Volume = 0.9
arrowSound.Parent = SoundService

task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ reefTickSound, feedSound, arrowSound })
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
	elapsedSec: number,
	running: boolean,
}

type PathSegment = {
	w0: Vector3,
	c: Vector3,
	w1: Vector3,
	length: number,
	cumStart: number,
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
	incomingFood: number, -- >0 means a homing orb is already locked onto this fish
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
}

type FoodShot = {
	part: BasePart,
	target: FishAgent?,
	fill: number,
	coral: CoralAgent,
	alive: boolean,
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

type PathBead = {
	part: BasePart,
	dist: number,
}

local running = false
local token = 0
local folder: Folder? = nil
local pathData: PathData? = nil
local fishList: { FishAgent } = {}
local coralList: { CoralAgent } = {}
local hash: { [number]: { CoralAgent } } = {}
local foodPool: { BasePart } = {}
local activeShots: { FoodShot } = {}
local spawnQueue = 0
local spawnDelay = 0
local waveIndex = 0
local reefHealth = REEF_START_HEALTH
local fishFed = 0
local startedAt = 0
local waveSpawning = false
local moveConn: RBXScriptConnection? = nil
local combatAcc = 0
local nextFishId = 1
local tangTemplate: Instance? = nil
local greenArrowsTemplate: Instance? = nil
local arrowPreviews: { ArrowPreview } = {}
local wavePathLabels: { WavePathLabel } = {}
local pathBeads: { PathBead } = {}
local pathBeadWaveT0 = 0
local pathBeadsFading = false
local arrowsWarned = false
local hudListeners: { (HudSnapshot) -> () } = {}
local stopListeners: { (Summary) -> () } = {}
local fishRng = Random.new()
local reefTickStreak = 0
local feedPitchCursor = FEED_PITCH_MIN

local function fishWorldOffset(agent: FishAgent, pos: Vector3, tang: Vector3): Vector3
	local side = Vector3.new(-tang.Z, 0, tang.X)
	if side.Magnitude > 1e-4 then
		side = side.Unit
	else
		side = Vector3.new(1, 0, 0)
	end
	local d = agent.dist
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

local function notifyHud()
	hudDirty = true
end

local function flushHud()
	local elapsed = if running then os.clock() - startedAt else 0
	local sec = math.floor(elapsed)
	-- Cheap second-tick: only push HUD when the clock second changes (or a dirty event).
	local secTick = running and sec ~= lastHudSec
	if not hudDirty and not secTick then
		return
	end
	hudDirty = false
	if not secTick and running and waveIndex == lastHudWave and reefHealth == lastHudReef then
		return
	end
	lastHudWave = waveIndex
	lastHudReef = reefHealth
	lastHudSec = sec
	local snap: HudSnapshot = {
		wave = waveIndex,
		reefHealth = reefHealth,
		elapsedSec = elapsed,
		running = running,
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

local function hashKey(x: number, z: number): number
	local cx = math.floor(x / HASH_CELL)
	local cz = math.floor(z / HASH_CELL)
	return cx * 73856093 + cz * 19349663
end

local function clearHash()
	table.clear(hash)
end

local function insertHash(coral: CoralAgent)
	local p = coral.part.Position
	local r = TARGET_RANGE
	local x0 = math.floor((p.X - r) / HASH_CELL)
	local x1 = math.floor((p.X + r) / HASH_CELL)
	local z0 = math.floor((p.Z - r) / HASH_CELL)
	local z1 = math.floor((p.Z + r) / HASH_CELL)
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
	local samples = math.max(8, math.ceil(((w1 - w0).Magnitude + (c - w0).Magnitude + (w1 - c).Magnitude) / PATH_SAMPLE_STEP))
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
	local t = math.clamp((d - seg.cumStart) / seg.length, 0, 1)
	return quadBezier(seg.w0, seg.c, seg.w1, t), quadBezierTangent(seg.w0, seg.c, seg.w1, t)
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
	local desired = look * CFrame.Angles(0, ARROW_YAW, ARROW_ROLL + spin)
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

local function waypointStartDist(path: PathData, waypointIndex: number): number
	local dists = path.waypointDists
	if waypointIndex < 1 then
		return 0
	end
	if waypointIndex > #dists then
		return path.totalLen
	end
	return dists[waypointIndex]
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
	bb.Size = UDim2.fromScale(WAVE_LABEL_SCALE.X, WAVE_LABEL_SCALE.Y)
	bb.StudsOffset = Vector3.new(0, WAVE_LABEL_HEIGHT, 0)
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
	if not path then
		return
	end
	playArrowStartSound()
	local folderFx = ensureFolder()
	local waveText = "Wave " .. tostring(math.max(1, waveIndex))

	-- 11 arrow sets at W1, W3, W5... ; "Wave N" labels between them + after last.
	if tmpl then
		for i = 1, ARROW_COUNT do
			local wpIndex = 1 + (i - 1) * ARROW_WP_SPACING
			local startDist = waypointStartDist(path, wpIndex)
			if startDist >= path.totalLen - 0.05 then
				continue
			end
			local clone = cloneGreenArrowsSet(tmpl, "OceanTD_GreenArrows_" .. tostring(i))
			clone.Parent = folderFx
			local spin0 = (i - 1) * (math.pi * 2 / ARROW_COUNT)
			local pos, tang = samplePath(path, startDist)
			setArrowCFrame(clone, pos, tang, spin0)
			table.insert(arrowPreviews, {
				model = clone,
				dist = startDist,
				spin = spin0,
				alive = true,
			})
		end
	end

	for i = 1, ARROW_COUNT - 1 do
		local wpIndex = 2 + (i - 1) * ARROW_WP_SPACING
		local startDist = waypointStartDist(path, wpIndex)
		if startDist >= path.totalLen - 0.05 then
			continue
		end
		local pos = samplePath(path, startDist)
		local part = createWavePathLabel(waveText, pos, folderFx)
		table.insert(wavePathLabels, {
			part = part,
			dist = startDist,
			alive = true,
		})
	end

	-- Extra "Wave N" after the last green-arrow set.
	do
		local lastArrowWp = 1 + (ARROW_COUNT - 1) * ARROW_WP_SPACING
		local afterWp = lastArrowWp + 1
		local startDist = waypointStartDist(path, afterWp)
		if startDist >= path.totalLen - 0.05 then
			startDist = math.max(0, path.totalLen - 0.5)
		end
		if startDist < path.totalLen - 0.05 then
			local pos = samplePath(path, startDist)
			local part = createWavePathLabel(waveText, pos, folderFx)
			table.insert(wavePathLabels, {
				part = part,
				dist = startDist,
				alive = true,
			})
		end
	end
end

local function tickArrowPreview(dt: number)
	local path = pathData
	if not path then
		destroyArrowPreview()
		return
	end
	local speed = FISH_SPEED * ARROW_SPEED_MULT
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
		preview.spin += ARROW_SPIN_RAD_PER_SEC * dt
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

local function destroyPathBeads()
	for _, bead in ipairs(pathBeads) do
		if bead.part.Parent then
			bead.part:Destroy()
		end
	end
	table.clear(pathBeads)
	pathBeadsFading = false
end

local function startPathBeads()
	destroyPathBeads()
	local path = pathData
	if not path or path.totalLen < 1 then
		return
	end
	pathBeadWaveT0 = os.clock()
	pathBeadsFading = false
	local folderFx = ensureFolder()
	local i = 0
	local d = 0
	while d < path.totalLen - 0.01 do
		local part = Instance.new("Part")
		part.Name = "OceanTD_PathBead"
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.new(PATH_BEAD_DIAMETER, PATH_BEAD_DIAMETER, PATH_BEAD_DIAMETER)
		part.Material = if (i % 2) == 0 then Enum.Material.Plastic else Enum.Material.Neon
		part.Color = PATH_BEAD_GREEN
		part.Transparency = 0
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		local pos = samplePath(path, d)
		part.CFrame = CFrame.new(pos)
		part.Parent = folderFx
		table.insert(pathBeads, {
			part = part,
			dist = d,
		})
		i += 1
		d += PATH_BEAD_SPACING
	end
end

local function tickPathBeads(dt: number)
	if #pathBeads == 0 then
		return
	end
	local path = pathData
	if not path or path.totalLen < 1 then
		destroyPathBeads()
		return
	end
	local age = os.clock() - pathBeadWaveT0
	if not pathBeadsFading and age >= PATH_BEAD_ACTIVE_SEC then
		pathBeadsFading = true
	end
	if pathBeadsFading then
		local fadeU = (age - PATH_BEAD_ACTIVE_SEC) / PATH_BEAD_FADE_SEC
		if fadeU >= 1 then
			destroyPathBeads()
			return
		end
	end

	local speed = FISH_SPEED * PATH_BEAD_SPEED_MULT
	local len = path.totalLen
	local now = os.clock()
	local fadeMul = if pathBeadsFading
		then 1 - math.clamp((age - PATH_BEAD_ACTIVE_SEC) / PATH_BEAD_FADE_SEC, 0, 1)
		else 1
	for _, bead in ipairs(pathBeads) do
		if not bead.part.Parent then
			continue
		end
		bead.dist = (bead.dist + speed * dt) % len
		local pos = samplePath(path, bead.dist)
		local wave = 0.5 + 0.5 * math.sin(bead.dist * PATH_BEAD_PULSE_DIST + now * PATH_BEAD_PULSE_TIME)
		local scale = PATH_BEAD_PULSE_MIN + (PATH_BEAD_PULSE_MAX - PATH_BEAD_PULSE_MIN) * wave
		local diam = PATH_BEAD_DIAMETER * scale
		bead.part.Size = Vector3.new(diam, diam, diam)
		bead.part.CFrame = CFrame.new(pos)
		bead.part.Transparency = 1 - fadeMul
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
		local alpha = 1 - math.exp(-TURN_RATE * math.max(dt, 1e-4))
		local blended = prev:Lerp(move, alpha)
		if blended.Magnitude > 1e-5 then
			move = blended.Unit
		end
	end
	agent.smoothTang = move

	-- Same as GreenArrows: look along swim dir, then fixed authored yaw/pitch/roll.
	local desired = CFrame.lookAt(pos, pos + move, Vector3.yAxis)
		* CFrame.Angles(TANG_PITCH, TANG_YAW, TANG_ROLL)

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
	local totalW = HUNGER_EMOJI_SIZE + HUNGER_BAR_GAP + HUNGER_BAR_PX_W
	local bb = Instance.new("BillboardGui")
	bb.Name = "HungerBar"
	bb.Size = UDim2.fromOffset(totalW, HUNGER_BAR_PX_H)
	bb.StudsOffset = Vector3.new(0, HUNGER_BAR_HEIGHT, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = HUNGER_BAR_MAX_DIST
	bb.Adornee = adornee
	bb.Parent = adornee

	-- Bar on the right; emoji sits outside in front (left), 3x bar height.
	local barHost = Instance.new("Frame")
	barHost.Name = "BarHost"
	barHost.BackgroundTransparency = 1
	barHost.AnchorPoint = Vector2.new(1, 0.5)
	barHost.Position = UDim2.new(1, 0, 0.5, 0)
	barHost.Size = UDim2.fromOffset(HUNGER_BAR_PX_W, HUNGER_BAR_STRIP_H)
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
	fork.Size = UDim2.fromOffset(HUNGER_EMOJI_SIZE, HUNGER_EMOJI_SIZE)
	fork.Font = Enum.Font.SourceSansBold
	fork.Text = "🍴"
	fork.TextSize = HUNGER_EMOJI_SIZE
	fork.TextScaled = false
	fork.ZIndex = 4
	fork.Parent = bb

	local happy = Instance.new("TextLabel")
	happy.Name = "Happy"
	happy.BackgroundTransparency = 1
	happy.AnchorPoint = Vector2.new(0, 0.5)
	happy.Position = UDim2.new(0, 0, 0.5, 0)
	happy.Size = UDim2.fromOffset(HUNGER_EMOJI_SIZE, HUNGER_EMOJI_SIZE)
	happy.Font = Enum.Font.SourceSansBold
	happy.Text = "😊"
	happy.TextSize = HUNGER_EMOJI_SIZE
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
	if agent.billboard and agent.billboard.Parent then
		-- Keep red-flashing bars visible when zoomed far out (skip LOD hide).
		agent.billboard.MaxDistance = if enable then HUNGER_BAR_DANGER_MAX_DIST else HUNGER_BAR_MAX_DIST
	end
	if not enable then
		if agent.hunger < agent.maxHunger and agent.fill.Parent then
			agent.fill.BackgroundColor3 = FILL_GREEN
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
			agent.fill.BackgroundColor3 = DANGER_RED
			if agent.barStroke then
				agent.barStroke.Color = DANGER_RED
			end
			task.wait(0.28)
			if agent.dangerToken ~= my or agent.finished then
				return
			end
			agent.fill.BackgroundColor3 = FILL_GREEN
			if agent.barStroke then
				agent.barStroke.Color = Color3.new(1, 1, 1)
			end
			task.wait(0.28)
		end
	end)
end

local function playFeedSound()
	local pitch = feedPitchCursor
	feedPitchCursor += FEED_PITCH_STEP
	if feedPitchCursor > FEED_PITCH_MAX then
		feedPitchCursor = FEED_PITCH_MIN
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

local function pulseReefHeartLoss(at: Vector3)
	local folder = ensureFolder()
	local anchor = Instance.new("Part")
	anchor.Name = "OceanTD_HeartLoss"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	-- Billboard grows in studs around the final waypoint.
	anchor.CFrame = CFrame.new(at + Vector3.new(0, 2, 0))
	anchor.Parent = folder

	local bb = Instance.new("BillboardGui")
	bb.Name = "HeartPulse"
	bb.Adornee = anchor
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 2000
	bb.Size = UDim2.fromScale(0.01, 0.01)
	bb.Parent = anchor

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = Enum.Font.SourceSansBold
	lbl.Text = "❤️"
	lbl.TextColor3 = Color3.fromRGB(255, 35, 55)
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.35
	lbl.TextStrokeColor3 = Color3.fromRGB(80, 0, 10)
	lbl.Parent = bb

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local u = (os.clock() - t0) / HEART_LOSS_PULSE_SEC
		if u >= 1 or not anchor.Parent then
			conn:Disconnect()
			if anchor.Parent then
				anchor:Destroy()
			end
			return
		end
		-- Scale up to max then back down.
		local s = math.sin(u * math.pi) * HEART_LOSS_MAX_STUDS
		bb.Size = UDim2.fromScale(math.max(0.01, s), math.max(0.01, s))
		lbl.TextTransparency = u * 0.35
	end)
end

local function playReefHealthTicks(amount: number)
	if amount <= 0 then
		return
	end
	local endPos = if pathData then pathData.endPos else nil
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
			if endPos then
				pulseReefHeartLoss(endPos)
			end
		end)
	end
end

local function startHappyFlash(agent: FishAgent)
	agent.pulseToken += 1
	agent.dangerToken += 1
	agent.dangerActive = false
	local my = agent.pulseToken
	agent.happyLabel.Text = HAPPY_EMOJIS[fishRng:NextInteger(1, #HAPPY_EMOJIS)]
	task.spawn(function()
		while agent.pulseToken == my and not agent.finished and agent.model.Parent do
			agent.happyLabel.Visible = true
			task.wait(HAPPY_FLASH_ON)
			if agent.pulseToken ~= my or agent.finished then
				return
			end
			agent.happyLabel.Visible = false
			task.wait(HAPPY_FLASH_OFF)
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
			agent.fill.BackgroundColor3 = FILL_GREEN
		end
	end
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
	return coral.part.Position + Vector3.new(0, r + AMMO_RADIUS, 0)
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
	local s = AMMO_RADIUS * 2 * math.clamp(scale, 0.08, 1)
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
				local s = AMMO_RADIUS * 2
				coral.ammo.Size = Vector3.new(s, s, s)
				coral.ammo.CFrame = CFrame.new(ammoWorldPos(coral))
			else
				createAmmo(coral, 1)
			end
		elseif coral.ammo and coral.ammo.Parent then
			local s = AMMO_RADIUS * 2 * math.max(0.08, u)
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
	n.Size = Vector3.new(FOOD_RADIUS * 2, FOOD_RADIUS * 2, FOOD_RADIUS * 2)
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
	local reload = DEFAULT_RELOAD
	local fillAmt = DEFAULT_FOOD_FILL
	local diameter = part.Size.Y
	if species then
		reload = species.reloadSec or DEFAULT_RELOAD
		fillAmt = species.foodFill or DEFAULT_FOOD_FILL
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
		playReefHealthTicks(dealt)
	else
		fishFed += 1
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
	local lateral = fishRng:NextNumber(-LATERAL_SPREAD, LATERAL_SPREAD)
	local vert = fishRng:NextNumber(-VERT_SPREAD, VERT_SPREAD)
	local bobAmp = fishRng:NextNumber(BOB_AMP_MIN, BOB_AMP_MAX)
	local bobFreq = fishRng:NextNumber(0.012, 0.032) -- slow vertical jitter
	local bobPhase = fishRng:NextNumber(0, math.pi * 2)
	local wanderAmp = fishRng:NextNumber(WANDER_AMP_MIN, WANDER_AMP_MAX)
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
		maxHunger = TANG_HUNGER,
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
	return math.min(WAVE_COUNT_MAX, WAVE1_COUNT + (wave - 1) * WAVE_COUNT_STEP)
end

local function beginWave(wave: number)
	waveIndex = wave
	-- Path preview: GreenArrows race the route; fish follow 1s later.
	startWaveArrowPreview()
	startPathBeads()
	waveSpawning = true
	spawnQueue = waveFishCount(wave)
	spawnDelay = ARROW_LEAD_SEC
	-- Session start: arm all corals. Later waves: keep reload state; only pick up new places.
	syncCorals(wave == 1)
	notifyHud()
end

local function findClosestHungryFish(coral: CoralAgent): FishAgent?
	local origin = coral.part.Position
	local best: FishAgent? = nil
	local bestDist = TARGET_RANGE_SQ
	for _, f in ipairs(fishList) do
		if f.finished or f.hunger >= f.maxHunger or f.incomingFood > 0 then
			continue
		end
		local fp = f.root.Position
		local dx = fp.X - origin.X
		local dy = fp.Y - origin.Y
		local dz = fp.Z - origin.Z
		local d2 = dx * dx + dy * dy + dz * dz
		if d2 <= bestDist then
			bestDist = d2
			best = f
		end
	end
	return best
end

local function fireShot(coral: CoralAgent, target: FishAgent)
	coral.busy = true
	destroyAmmo(coral)
	target.incomingFood += 1
	local part = acquireFoodPart()
	part.Color = coral.color
	part.Transparency = 0
	part.CFrame = CFrame.new(ammoWorldPos(coral))
	local shot: FoodShot = {
		part = part,
		target = target,
		fill = coral.foodFill,
		coral = coral,
		alive = true,
	}
	table.insert(activeShots, shot)
end

local function clearShotTarget(shot: FoodShot)
	local target = shot.target
	if target then
		target.incomingFood = math.max(0, target.incomingFood - 1)
		shot.target = nil
	end
end

local function onShotHit(shot: FoodShot)
	shot.alive = false
	local coral = shot.coral
	coral.busy = false
	startAmmoGrow(coral)

	local target = shot.target
	clearShotTarget(shot)
	if target and not target.finished and target.hunger < target.maxHunger then
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
	for _, coral in ipairs(coralList) do
		if coral.busy or coral.growing then
			continue
		end
		if not anyHungry or now < coral.readyAt then
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
			-- Target gone: still complete hit logic for reload.
			onShotHit(shot)
			table.remove(activeShots, i)
			continue
		end
		local pos = shot.part.Position
		local goal = target.root.Position
		local delta = goal - pos
		local dist = delta.Magnitude
		local step = FOOD_SPEED * dt
		if dist <= step or dist < 0.35 then
			onShotHit(shot)
			table.remove(activeShots, i)
			continue
		end
		shot.part.CFrame = CFrame.new(pos + delta.Unit * step)
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
		agent.dist += FISH_SPEED * (1 + FISH_SPEED_VAR * math.sin(os.clock() * agent.speedFreq + agent.speedPhase)) * dt
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
	destroyPathBeads()
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
	reefHealth = REEF_START_HEALTH
	fishFed = 0
	reefTickStreak = 0
	feedPitchCursor = FEED_PITCH_MIN
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
		-- Spawning (first fish waits ARROW_LEAD_SEC after GreenArrows start)
		if waveSpawning and spawnQueue > 0 then
			spawnDelay -= dt
			if spawnDelay <= 0 then
				local idx = waveFishCount(waveIndex) - spawnQueue + 1
				spawnOneFish(idx)
				spawnQueue -= 1
				spawnDelay = STAGGER_SEC
				if spawnQueue <= 0 then
					waveSpawning = false
				end
			end
		end

		tickArrowPreview(dt)
		tickPathBeads(dt)
		tickFish(dt)
		tickShots(dt)
		tickAmmoGrow(os.clock())

		-- Ammo grow + combat cadence; also pick up newly placed corals (~10 Hz).
		combatAcc += dt
		if combatAcc >= COMBAT_DT then
			combatAcc -= COMBAT_DT
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

-- Silence unused.
local _ = Players
local _ = hashKey

return WaveSim
