--!strict
--[[
	Client-only feed-wave simulation (solo). Fish, food, reef health — not replicated.
	Optimized: path samples once, spatial hash for coral↔fish, 10 Hz targeting, pooled FX.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local SpeciesCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SpeciesCatalog"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local WaveSim = {}

local FISH_SPEED = 16 -- 20 * 0.8
local FOOD_SPEED = 24 -- 20 * 1.2
local TARGET_RANGE = 30
local TARGET_RANGE_SQ = TARGET_RANGE * TARGET_RANGE
local COMBAT_HZ = 10
local COMBAT_DT = 1 / COMBAT_HZ
local PATH_SAMPLE_STEP = 1.5
local STAGGER_SEC = 0.4
local LATERAL_SPACING = 1.35
local LATERAL_JITTER = 1.15
local VERT_JITTER = 0.6 -- small resting height bias
local BOB_AMP_MIN = 2.2
local BOB_AMP_MAX = 3.5 -- slow vertical wander ≈ ±3.5 studs
local WANDER_AMP_MIN = 2.5
local WANDER_AMP_MAX = 5.75
local HASH_CELL = 30
local DEFAULT_RELOAD = 2
local DEFAULT_FOOD_FILL = 1
local WAVE1_COUNT = 2
local WAVE_COUNT_STEP = 2
local WAVE_COUNT_MAX = 40
local INTERMISSION_SEC = 5
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
local HAPPY_EMOJIS = { "😊", "😄", "😁", "😆", "🥰", "😍", "💖", "🤩" }
local HAPPY_FLASH_ON = 2
local HAPPY_FLASH_OFF = 3

local LEAD_NAMES = { "Mouth", "mouth", "Lead", "Front", "Nose", "Forward", "Face", "Heading", "Leading" }
local BODY_NAMES = { "Body", "body", "Torso", "torso" }
local TURN_RATE = 14 -- higher = snappier yaw toward path tangent


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
	hunger: number,
	maxHunger: number,
	finished: boolean,
	billboard: BillboardGui,
	fill: Frame,
	barFrame: Frame,
	forkLabel: TextLabel,
	happyLabel: TextLabel,
	barScale: UIScale,
	pulseToken: number,
	facingOffset: CFrame,
	smoothTang: Vector3,
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
local intermissionUntil = 0
local waveSpawning = false
local moveConn: RBXScriptConnection? = nil
local combatAcc = 0
local nextFishId = 1
local tangTemplate: Instance? = nil
local hudListeners: { (HudSnapshot) -> () } = {}
local stopListeners: { (Summary) -> () } = {}
local fishRng = Random.new()

local function fishWorldOffset(agent: FishAgent, pos: Vector3, tang: Vector3): Vector3
	local side = Vector3.new(-tang.Z, 0, tang.X)
	if side.Magnitude > 1e-4 then
		side = side.Unit
	else
		side = Vector3.new(1, 0, 0)
	end
	-- Cheap per-fish path deviation: fixed lane + slow lateral wander + vertical bob (scalars only).
	local lat = agent.lateral
		+ agent.wanderAmp * math.sin(agent.dist * agent.wanderFreq + agent.wanderPhase)
	local up = agent.vert + agent.bobAmp * math.sin(agent.dist * agent.bobFreq + agent.bobPhase)
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
	if not hudDirty then
		return
	end
	hudDirty = false
	local elapsed = if running then os.clock() - startedAt else 0
	local sec = math.floor(elapsed)
	if running and waveIndex == lastHudWave and reefHealth == lastHudReef and sec == lastHudSec then
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

	print("[WAVE] Path ready:", #waypoints, "waypoints,", #segments, "curve segments, len=", string.format("%.1f", total))
	return { segments = segments, totalLen = total }
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

local function setFishCFrame(agent: FishAgent, pos: Vector3, tang: Vector3, dt: number)
	local move = tang
	if move.Magnitude < 1e-5 then
		move = agent.smoothTang
	end
	if move.Magnitude < 1e-5 then
		move = Vector3.new(0, 0, -1)
	else
		move = move.Unit
	end

	-- Turn smoothing (shark-style): ease current facing toward path tangent.
	local prev = agent.smoothTang
	if prev.Magnitude > 1e-5 then
		local alpha = 1 - math.exp(-TURN_RATE * math.max(dt, 1e-4))
		local blended = prev:Lerp(move, alpha)
		if blended.Magnitude > 1e-5 then
			move = blended.Unit
		end
	end
	agent.smoothTang = move

	-- Build orthonormal basis: Look (-Z) = moveDir
	local f = move
	local r = f:Cross(Vector3.yAxis)
	if r.Magnitude < 1e-4 then
		r = f:Cross(Vector3.xAxis)
	end
	r = r.Unit
	local u = r:Cross(f).Unit
	local desired = CFrame.fromMatrix(pos, r, u, -f) * agent.facingOffset

	local model = agent.model
	if model:IsA("Model") then
		model:PivotTo(desired)
	elseif model:IsA("BasePart") then
		model.CFrame = desired
	else
		-- Folder / misc: rotate every BasePart relative to root.
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

local function findNamedPart(inst: Instance, names: { string }): BasePart?
	for _, name in ipairs(names) do
		local p = inst:FindFirstChild(name, true)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	return nil
end

-- Mouth should lead along the path. Prefer Mouth→Body vector (matches shark-style facing).
local function computeFacingOffset(model: Instance, root: BasePart): CFrame
	local pivot = if model:IsA("Model") then model:GetPivot() else root.CFrame
	local mouth = findNamedPart(model, LEAD_NAMES)
	local body = findNamedPart(model, BODY_NAMES)

	local worldDir: Vector3? = nil
	if mouth and body then
		worldDir = mouth.Position - body.Position
	elseif mouth then
		worldDir = mouth.Position - pivot.Position
	else
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d:GetAttribute("OceanTD_Lead") == true then
				worldDir = d.Position - pivot.Position
				d.Transparency = 1
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				break
			end
		end
	end

	if not worldDir or worldDir.Magnitude < 1e-3 then
		warn("[WAVE] Tang missing Mouth/Body markers — facing may be wrong")
		return CFrame.identity
	end

	local localDir = pivot:VectorToObjectSpace(worldDir)
	if localDir.Magnitude < 1e-3 then
		return CFrame.identity
	end
	-- Maps mouth direction → Roblox forward (-Z) so path travel points the mouth ahead.
	return CFrame.lookAt(Vector3.zero, localDir.Unit):Inverse()
end

local function makeHungerBillboard(adornee: BasePart): (BillboardGui, Frame, Frame, TextLabel, TextLabel, UIScale)
	local totalW = HUNGER_EMOJI_SIZE + HUNGER_BAR_GAP + HUNGER_BAR_PX_W
	local bb = Instance.new("BillboardGui")
	bb.Name = "HungerBar"
	bb.Size = UDim2.fromOffset(totalW, HUNGER_BAR_PX_H)
	bb.StudsOffset = Vector3.new(0, HUNGER_BAR_HEIGHT, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 220
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

local function startHappyFlash(agent: FishAgent)
	agent.pulseToken += 1
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
		startHappyFlash(agent)
	else
		agent.pulseToken += 1
		agent.barFrame.Visible = true
		agent.forkLabel.Visible = true
		agent.happyLabel.Visible = false
		agent.fill.BackgroundColor3 = Color3.fromRGB(40, 255, 90)
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

local function gatherPlotCorals(): { CoralAgent }
	local list: { CoralAgent } = {}
	local seen: { [BasePart]: boolean } = {}
	local root = Workspace:FindFirstChild("OceanTD_Placed")
	if not root then
		return list
	end

	local function consider(inst: Instance)
		if not inst:IsA("BasePart") or seen[inst] then
			return
		end
		if typeof(inst:GetAttribute("OceanTD_GhostBaseR")) == "number" then
			return
		end
		local itemId = inst:GetAttribute("OceanTD_ItemId")
		local speciesId = inst:GetAttribute("OceanTD_SpeciesId")
		local id = if typeof(itemId) == "string" and itemId ~= "" then itemId
			elseif typeof(speciesId) == "string" and speciesId ~= "" then speciesId
			elseif inst.Name ~= "" and ItemCatalog.get(inst.Name) then inst.Name
			else nil
		if not id then
			return
		end
		seen[inst] = true
		local item = ItemCatalog.get(id)
		local species = SpeciesCatalog.get(if typeof(speciesId) == "string" then speciesId else id)
			or (if item then SpeciesCatalog.get(item.speciesId) else nil)
		local reload = DEFAULT_RELOAD
		local fillAmt = DEFAULT_FOOD_FILL
		local diameter = inst.Size.Y
		if species then
			reload = species.reloadSec or DEFAULT_RELOAD
			fillAmt = species.foodFill or DEFAULT_FOOD_FILL
			diameter = species.diameter
		end
		table.insert(list, {
			part = inst,
			color = inst.Color,
			reloadSec = reload,
			foodFill = fillAmt,
			diameter = diameter,
			readyAt = 0,
			ammo = nil,
			growing = false,
			growT0 = 0,
			busy = false,
			hashKeys = {},
		})
	end

	local mirrored = ClientPlot.get()
	local plotFolder = if mirrored then root:FindFirstChild(mirrored.plotId) else nil
	if plotFolder then
		for _, inst in ipairs(plotFolder:GetDescendants()) do
			consider(inst)
		end
	end
	-- Full scan so every placed coral gets ammo (plotId / folder edge cases).
	for _, inst in ipairs(root:GetDescendants()) do
		consider(inst)
	end
	return list
end

local function rebuildCorals()
	for _, c in ipairs(coralList) do
		destroyAmmo(c)
	end
	table.clear(coralList)
	clearHash()
	coralList = gatherPlotCorals()
	-- Every local coral gets ammo at wave start (even if far from the current route).
	for _, c in ipairs(coralList) do
		insertHash(c)
		c.readyAt = 0
		c.busy = false
		c.growing = false
		createAmmo(c, 1)
	end
	print("[WAVE] Coral ammo ready:", #coralList)
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
		reefHealth = math.max(0, reefHealth - empty)
	else
		fishFed += 1
	end
	destroyFish(agent)
	notifyHud()
	if reefHealth <= 0 and running then
		-- Caller stop via WaveSim.stop from WaveSlot after health check in tick.
	end
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
	local lane = ((spawnIndex - 1) % 5 - 2) * LATERAL_SPACING
	local lateral = lane + fishRng:NextNumber(-LATERAL_JITTER, LATERAL_JITTER)
	local vert = fishRng:NextNumber(-VERT_JITTER, VERT_JITTER)
	local bobAmp = fishRng:NextNumber(BOB_AMP_MIN, BOB_AMP_MAX)
	local bobFreq = fishRng:NextNumber(0.035, 0.075) -- slow vertical (≈ multi-second cycles)
	local bobPhase = fishRng:NextNumber(0, math.pi * 2)
	local wanderAmp = fishRng:NextNumber(WANDER_AMP_MIN, WANDER_AMP_MAX)
	local wanderFreq = fishRng:NextNumber(0.06, 0.14)
	local wanderPhase = fishRng:NextNumber(0, math.pi * 2)
	local pos, tang = samplePath(path, 0)
	local facingOffset = computeFacingOffset(clone, root)
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
		hunger = 0,
		maxHunger = TANG_HUNGER,
		finished = false,
		billboard = nil :: any,
		fill = nil :: any,
		barFrame = nil :: any,
		forkLabel = nil :: any,
		happyLabel = nil :: any,
		barScale = nil :: any,
		pulseToken = 0,
		facingOffset = facingOffset,
		smoothTang = tang.Magnitude > 1e-5 and tang.Unit or Vector3.new(0, 0, -1),
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
	setFishCFrame(agent, fishWorldOffset(agent, pos, tang), tang, 1)
	table.insert(fishList, agent)
end

local function waveFishCount(wave: number): number
	return math.min(WAVE_COUNT_MAX, WAVE1_COUNT + (wave - 1) * WAVE_COUNT_STEP)
end

local function beginWave(wave: number)
	waveIndex = wave
	waveSpawning = true
	spawnQueue = waveFishCount(wave)
	spawnDelay = 0
	rebuildCorals()
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
		agent.dist += FISH_SPEED * dt
		if agent.dist >= path.totalLen then
			finishFish(agent)
			continue
		end
		local pos, tang = samplePath(path, agent.dist)
		local world = fishWorldOffset(agent, pos, tang)
		setFishCFrame(agent, world, tang, dt)
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
	intermissionUntil = 0
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
		-- Spawning
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

		tickFish(dt)
		tickShots(dt)
		tickAmmoGrow(os.clock())

		-- Ammo grow + combat cadence
		combatAcc += dt
		if combatAcc >= COMBAT_DT then
			combatAcc -= COMBAT_DT
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

		-- Wave complete → intermission → next
		if not waveSpawning and spawnQueue <= 0 and countAliveFish() == 0 and intermissionUntil <= 0 then
			intermissionUntil = os.clock() + INTERMISSION_SEC
		end
		if intermissionUntil > 0 and os.clock() >= intermissionUntil then
			intermissionUntil = 0
			beginWave(waveIndex + 1)
		end
	end)

	return true
end

function WaveSim.formatClock(sec: number): string
	local s = math.max(0, math.floor(sec + 0.5))
	local m = s // 60
	local r = s % 60
	if m >= 60 then
		local h = m // 60
		m = m % 60
		return string.format("%02d:%02d", h, m)
	end
	return string.format("%02d:%02d", m, r)
end

-- Silence unused.
local _ = Players
local _ = hashKey

return WaveSim
