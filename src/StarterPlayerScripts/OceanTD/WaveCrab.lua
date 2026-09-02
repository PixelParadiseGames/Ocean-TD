--!strict
--[[
	GroundA hungry crabs (wave 5+): hunger 10× fish, sprint bursts on GroundA.
	Counts: W5–10 0–1, W11–20 1–3, W21–40 2–4, W41+ 3–6.
	Weld tripod walk (not IK). Path is never trimmed by Plot Size.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local WaveEntityPool = require(script.Parent:WaitForChild("WaveEntityPool"))
local C = require(script.Parent:WaitForChild("WaveSimConsts"))
local CoralVisual = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("CoralVisual"))

local WaveCrab = {}

export type PathSegment = {
	w0: Vector3,
	c: Vector3,
	w1: Vector3,
	length: number,
	cumStart: number,
	inTang: Vector3,
	outTang: Vector3,
}

export type PathData = {
	segments: { PathSegment },
	totalLen: number,
	endPos: Vector3,
	waypointDists: { number },
}

export type Sprint = {
	untilClock: number,
	restUntil: number,
	mult: number,
}

export type AnimHandle = {
	group1: { any },
	group2: { any },
	rest1: { CFrame },
	rest2: { CFrame },
	phase: number,
	lastPos: Vector3,
}

local GROUP1: { [string]: boolean } = { LLeg1Weld = true, LLeg3Weld = true, RLeg2Weld = true }
local GROUP2: { [string]: boolean } = { LLeg2Weld = true, RLeg1Weld = true, RLeg3Weld = true }

local spawnedThisWave = 0
local expectedThisWave = 0
local pathWarned = false
local sprintRng = Random.new()

local function findIndexedPart(folder: Instance, prefix: string, index: number): BasePart?
	local name = prefix .. tostring(index)
	local inst = folder:FindFirstChild(name)
	if inst and inst:IsA("BasePart") then
		return inst
	end
	for _, ch in ipairs(folder:GetDescendants()) do
		if ch:IsA("BasePart") and ch.Name == name then
			return ch
		end
	end
	return nil
end

local function quadBezier(w0: Vector3, c: Vector3, w1: Vector3, t: number): Vector3
	local u = 1 - t
	return w0 * (u * u) + c * (2 * u * t) + w1 * (t * t)
end

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

local function buildFromRemap(remap: (BasePart) -> Vector3): PathData?
	local root = Workspace:FindFirstChild("WaveRoute")
	if not root then
		return nil
	end
	local route = root:FindFirstChild(C.CRAB_ROUTE_NAME)
	if not route then
		if not pathWarned then
			pathWarned = true
			warn("[WAVE] WaveRoute." .. C.CRAB_ROUTE_NAME .. " missing")
		end
		return nil
	end
	local wpFolder = route:FindFirstChild("Waypoints")
	local ctrlFolder = route:FindFirstChild("Controls")
	if not wpFolder or not ctrlFolder then
		if not pathWarned then
			pathWarned = true
			warn("[WAVE] " .. C.CRAB_ROUTE_NAME .. " Waypoints/Controls missing")
		end
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
		if not pathWarned then
			pathWarned = true
			warn("[WAVE] " .. C.CRAB_ROUTE_NAME .. " needs W1..Wn (at least 2); found", #waypoints)
		end
		return nil
	end

	local segments: { PathSegment } = {}
	local total = 0
	for s = 1, #waypoints - 1 do
		local ctrl = findIndexedPart(ctrlFolder, "C", s)
		if not ctrl then
			if not pathWarned then
				pathWarned = true
				warn("[WAVE] " .. C.CRAB_ROUTE_NAME .. " missing control C" .. tostring(s))
			end
			return nil
		end
		local w0 = remap(waypoints[s])
		local w1 = remap(waypoints[s + 1])
		local c = remap(ctrl)
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

	return {
		segments = segments,
		totalLen = total,
		endPos = remap(waypoints[#waypoints]),
		waypointDists = waypointDists,
	}
end

function WaveCrab.shouldSpawn(wave: number): boolean
	return wave >= C.CRAB_FIRST_WAVE and WaveEntityPool.hasFishKind(WaveEntityPool.FISH_CRAB)
end

function WaveCrab.rollCount(wave: number): number
	if not WaveCrab.shouldSpawn(wave) then
		return 0
	end
	local lo, hi = C.crabCountRangeForWave(wave)
	if hi <= 0 then
		return 0
	end
	return sprintRng:NextInteger(lo, hi)
end

function WaveCrab.hungerForWave(wave: number): number
	return C.tangHungerForWave(wave) * C.CRAB_HUNGER_MULT
end

function WaveCrab.baseSpeed(): number
	return C.FISH_SPEED * C.CRAB_SPEED_MULT
end

function WaveCrab.speed(): number
	return WaveCrab.baseSpeed()
end

function WaveCrab.newSprint(): Sprint
	-- Short delay then first sprint so they pull ahead of a constant 0.75× walk.
	return {
		untilClock = 0,
		restUntil = sprintRng:NextNumber(0.05, 0.45),
		mult = 1,
	}
end

function WaveCrab.speedNow(sprint: Sprint?, clock: number): number
	local mult = 1
	if sprint and clock < sprint.untilClock then
		mult = sprint.mult
	end
	return WaveCrab.baseSpeed() * mult
end

function WaveCrab.tickSprint(sprint: Sprint, clock: number)
	if clock < sprint.untilClock then
		return
	end
	if clock < sprint.restUntil then
		sprint.mult = 1
		return
	end
	sprint.mult = sprintRng:NextNumber(C.CRAB_SPRINT_MULT_MIN, C.CRAB_SPRINT_MULT_MAX)
	local dur = sprintRng:NextNumber(C.CRAB_SPRINT_DUR_MIN, C.CRAB_SPRINT_DUR_MAX)
	sprint.untilClock = clock + dur
	sprint.restUntil = sprint.untilClock + sprintRng:NextNumber(C.CRAB_SPRINT_REST_MIN, C.CRAB_SPRINT_REST_MAX)
end

function WaveCrab.beginWave(expected: number?)
	spawnedThisWave = 0
	expectedThisWave = math.max(0, math.floor(expected or 0))
end

function WaveCrab.expectedCount(): number
	return expectedThisWave
end

function WaveCrab.markSpawned()
	spawnedThisWave += 1
end

function WaveCrab.spawnedCount(): number
	return spawnedThisWave
end

function WaveCrab.buildLocal(): PathData?
	return buildFromRemap(function(part: BasePart): Vector3
		return ClientPlot.remapFromPlot1(part.Position)
	end)
end

function WaveCrab.buildOn(targetPlotId: string, targetCf: CFrame, targetSize: Vector3, targetRingCf: CFrame?): PathData?
	return buildFromRemap(function(part: BasePart): Vector3
		return ClientPlot.remapFromPlot1To(part.Position, targetPlotId, targetCf, targetSize, targetRingCf)
	end)
end

function WaveCrab.sample(path: PathData, dist: number): (Vector3, Vector3)
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
	return quadBezier(seg.w0, seg.c, seg.w1, t), quadBezierTangent(seg.w0, seg.c, seg.w1, t)
end

function WaveCrab.facingCFrame(pos: Vector3, move: Vector3): CFrame
	local look = if move.Magnitude > 1e-5 then move.Unit else Vector3.new(0, 0, -1)
	-- Flatten heading so pitch stays level while Y follows the seafloor.
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude > 1e-5 then
		look = flat.Unit
	end
	return CFrame.lookAt(pos, pos + look, Vector3.yAxis) * CFrame.Angles(C.CRAB_PITCH, C.CRAB_YAW, C.CRAB_ROLL)
end

function WaveCrab.pauseElapsed(pauseUntil: number?, pauseDur: number?): number
	if pauseUntil == nil then
		return 0
	end
	local dur = if typeof(pauseDur) == "number" and pauseDur > 0 then pauseDur else C.CRAB_CORAL_PAUSE_SEC
	return math.clamp(dur - math.max(0, pauseUntil - os.clock()), 0, dur)
end

-- Bounce + spin in place during the coral zap (settles in the last fraction of the pause).
function WaveCrab.applyFightPose(root: BasePart, anim: AnimHandle?, pathPos: Vector3, pathTang: Vector3, dt: number, elapsed: number, id: number, pauseDur: number?)
	local dur = if typeof(pauseDur) == "number" and pauseDur > 0 then pauseDur else C.CRAB_CORAL_PAUSE_SEC
	local fade = 1
	if elapsed > dur * 0.8 then
		fade = math.clamp(1 - (elapsed - dur * 0.8) / math.max(dur * 0.2, 1e-3), 0, 1)
	end
	local t = elapsed
	local seed = id * 0.73
	local ox = (math.sin(t * 10.4 + seed) * 0.65 + math.sin(t * 17.6 + seed * 1.3) * 0.35) * C.CRAB_FIGHT_RADIUS * fade
	local oz = (math.cos(t * 8.7 + seed * 0.9) * 0.65 + math.sin(t * 14.1 + seed) * 0.35) * C.CRAB_FIGHT_RADIUS * fade
	local hop = (math.abs(math.sin(t * 15.2 + seed)) * 0.7 + math.abs(math.sin(t * 23.5 + seed * 1.1)) * 0.3) * C.CRAB_FIGHT_HOP * fade
	local yaw = (t * C.CRAB_FIGHT_SPIN + math.sin(t * 7.4 + seed) * C.CRAB_FIGHT_YAW_WOBBLE) * fade
	local pitch = math.sin(t * 13.2 + seed) * C.CRAB_FIGHT_PITCH * fade
	local pos = Vector3.new(pathPos.X + ox, pathPos.Y + hop, pathPos.Z + oz)
	local look = Vector3.new(pathTang.X, 0, pathTang.Z)
	if look.Magnitude < 1e-5 then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end
	local desired = CFrame.lookAt(pos, pos + look, Vector3.yAxis)
		* CFrame.Angles(C.CRAB_PITCH + pitch, C.CRAB_YAW + yaw, C.CRAB_ROLL)
	root.CFrame = desired
	if anim then
		-- Fake displacement so legs scramble during the tussle.
		WaveCrab.stepAnim(anim, dt, pos)
	end
end

local groundParams: RaycastParams? = nil

local function getGroundParams(): RaycastParams
	local p = groundParams
	if p then
		return p
	end
	p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Include
	p.FilterDescendantsInstances = { Workspace.Terrain }
	p.IgnoreWater = true
	groundParams = p
	return p
end

local function terrainYBelow(pathPos: Vector3): number?
	local params = getGroundParams()
	local origin = Vector3.new(pathPos.X, pathPos.Y + C.CRAB_RAY_UP, pathPos.Z)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -C.CRAB_RAY_DOWN, 0), params)
	if not hit then
		origin = Vector3.new(pathPos.X, pathPos.Y + 80, pathPos.Z)
		hit = Workspace:Raycast(origin, Vector3.new(0, -160, 0), params)
	end
	if hit then
		return hit.Position.Y
	end
	return nil
end

-- Keep GroundA XZ; sit roughly on the seafloor under the crab (smoothed).
function WaveCrab.worldOnGround(pathPos: Vector3, prevY: number?, dt: number): Vector3
	local y = terrainYBelow(pathPos)
	if y == nil then
		y = pathPos.Y
	else
		y += C.CRAB_GROUND_CLEARANCE
	end
	if prevY ~= nil then
		local a = 1 - math.exp(-C.CRAB_GROUND_FOLLOW * math.max(dt, 1e-4))
		y = prevY + (y - prevY) * a
	end
	return Vector3.new(pathPos.X, y, pathPos.Z)
end

function WaveCrab.applyPose(root: BasePart, desired: CFrame)
	root.CFrame = desired
end

local function collectWelds(model: Instance): ({ any }, { any }, { CFrame }, { CFrame })
	local g1: { any } = {}
	local g2: { any } = {}
	local r1: { CFrame } = {}
	local r2: { CFrame } = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Weld") or d:IsA("Motor6D") then
			if GROUP1[d.Name] then
				table.insert(g1, d)
				table.insert(r1, d.C0)
			elseif GROUP2[d.Name] then
				table.insert(g2, d)
				table.insert(r2, d.C0)
			end
		end
	end
	return g1, g2, r1, r2
end

function WaveCrab.bindAnim(model: Instance, root: BasePart): AnimHandle
	local g1, g2, r1, r2 = collectWelds(model)
	return {
		group1 = g1,
		group2 = g2,
		rest1 = r1,
		rest2 = r2,
		phase = 0,
		lastPos = root.Position,
	}
end

function WaveCrab.resetAnim(handle: AnimHandle?)
	if not handle then
		return
	end
	for i, w in ipairs(handle.group1) do
		w.C0 = handle.rest1[i]
	end
	for i, w in ipairs(handle.group2) do
		w.C0 = handle.rest2[i]
	end
	handle.phase = 0
end

function WaveCrab.stepAnim(handle: AnimHandle, dt: number, rootPos: Vector3)
	local delta = (rootPos - handle.lastPos).Magnitude
	handle.lastPos = rootPos
	local speed = if dt > 1e-4 then delta / dt else 0
	if speed > C.CRAB_ANIM_MIN_SPEED then
		handle.phase += speed * C.CRAB_ANIM_PHASE_RATE * dt
	end
	local lift = math.sin(handle.phase) * C.CRAB_ANIM_LIFT
	local fade = math.clamp(speed / C.CRAB_ANIM_FADE_SPEED, 0, 1)
	local offset = lift * fade
	local up = CFrame.new(0, offset, 0)
	local down = CFrame.new(0, -offset, 0)
	for i, w in ipairs(handle.group1) do
		w.C0 = handle.rest1[i] * up
	end
	for i, w in ipairs(handle.group2) do
		w.C0 = handle.rest2[i] * down
	end
end

function WaveCrab.findShell(model: Instance): BasePart?
	local s = model:FindFirstChild("ShellHitbox", true)
	if s and s:IsA("BasePart") then
		return s
	end
	return nil
end

local function closestPointOnPart(part: BasePart, worldPt: Vector3): Vector3
	local localPos = part.CFrame:PointToObjectSpace(worldPt)
	local half = part.Size * 0.5
	return part.CFrame:PointToWorldSpace(Vector3.new(
		math.clamp(localPos.X, -half.X, half.X),
		math.clamp(localPos.Y, -half.Y, half.Y),
		math.clamp(localPos.Z, -half.Z, half.Z)
	))
end

-- OBB vs OBB via closest-point pair (not a sphere from max(Size) — tall SeaGrass
-- was stunning crabs many studs away horizontally).
function WaveCrab.shellOverlapsCoral(shell: BasePart, coral: BasePart): boolean
	local onCoral = closestPointOnPart(coral, shell.Position)
	local onShell = closestPointOnPart(shell, onCoral)
	onCoral = closestPointOnPart(coral, onShell)
	return (onShell - onCoral).Magnitude <= 0.05
end

function WaveCrab.stunCoralPart(part: BasePart)
	part:SetAttribute("OceanTD_CrabStunned", true)
	part.Color = Color3.new(1, 1, 1)
end

function WaveCrab.playDeathSkullFromCoral(part: BasePart)
	if not part.Parent then
		return
	end
	local top = math.max(part.Size.X, part.Size.Y, part.Size.Z) * 0.28
	WaveCrab.playDeathSkull(part.Position + Vector3.new(0, top, 0))
end

function WaveCrab.playDeathSkull(worldPos: Vector3)
	local parent: Instance = Workspace.CurrentCamera or Workspace
	local dur = C.CRAB_SKULL_SEC
	local anchor = Instance.new("Part")
	anchor.Name = "OceanTD_CrabSkull"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(worldPos)
	anchor.Parent = parent

	local bb = Instance.new("BillboardGui")
	bb.Name = "Skull"
	bb.Adornee = anchor
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 2000
	bb.Size = UDim2.fromScale(C.CRAB_SKULL_START_STUDS, C.CRAB_SKULL_START_STUDS)
	bb.Parent = anchor

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = Enum.Font.SourceSansBold
	lbl.Text = C.CRAB_SKULL_EMOJI
	lbl.TextScaled = true
	lbl.TextTransparency = 0
	lbl.TextStrokeTransparency = 0.4
	lbl.TextStrokeColor3 = Color3.fromRGB(20, 10, 10)
	lbl.Parent = bb

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		if not anchor.Parent then
			conn:Disconnect()
			return
		end
		local u = math.clamp((os.clock() - t0) / dur, 0, 1)
		local grow = 1 - (1 - u) * (1 - u)
		local rise = u -- slow linear lift
		local studs = C.CRAB_SKULL_START_STUDS + (C.CRAB_SKULL_END_STUDS - C.CRAB_SKULL_START_STUDS) * grow
		anchor.CFrame = CFrame.new(worldPos + Vector3.new(0, C.CRAB_SKULL_RISE * rise, 0))
		bb.Size = UDim2.fromScale(studs, studs)
		local fade = if u > 0.42 then math.clamp((u - 0.42) / 0.58, 0, 1) else 0
		lbl.TextTransparency = fade
		lbl.TextStrokeTransparency = 0.4 + 0.6 * fade
		if u >= 1 then
			conn:Disconnect()
			anchor:Destroy()
		end
	end)
end

function WaveCrab.clearCoralStun(part: BasePart, fade: boolean)
	part:SetAttribute("OceanTD_CrabStunned", nil)
	local _, color = CoralVisual.readRestLook(part)
	if fade then
		TweenService:Create(part, TweenInfo.new(C.CRAB_STUN_FADE_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Color = color,
		}):Play()
	else
		part.Color = color
	end
end

function WaveCrab.playZapBurst(parent: Instance, follow: () -> Vector3, pauseDur: number?, stillFighting: (() -> boolean)?)
	local rng = Random.new()
	local dur = if typeof(pauseDur) == "number" and pauseDur > 0 then pauseDur else C.CRAB_CORAL_PAUSE_SEC
	type Zap = {
		anchor: BasePart,
		bb: BillboardGui,
		lbl: TextLabel,
		spin: number,
		dir: Vector3,
		startStuds: number,
		endStuds: number,
		trans: number,
		pulse: number,
		pulseOff: number,
		life: number,
	}
	local zaps: { Zap } = {}
	local origin0 = follow()

	local function spawnBubble(at: Vector3)
		local size = rng:NextNumber(C.CRAB_ZAP_BUBBLE_SIZE_MIN, C.CRAB_ZAP_BUBBLE_SIZE_MAX)
		local p = Instance.new("Part")
		p.Name = "OceanTD_CrabBubble"
		p.Shape = Enum.PartType.Ball
		p.Material = Enum.Material.Glass
		p.Color = C.CRAB_ZAP_BUBBLE_COLOR
		p.Transparency = rng:NextNumber(C.CRAB_ZAP_BUBBLE_TRANS_MIN, C.CRAB_ZAP_BUBBLE_TRANS_MAX)
		p.Size = Vector3.new(size, size, size)
		p.Anchored = true
		p.Massless = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		local spawnOff = Vector3.new(rng:NextNumber(-1.1, 1.1), rng:NextNumber(0, 0.4), rng:NextNumber(-1.1, 1.1))
		local startPos = at + spawnOff
		p.CFrame = CFrame.new(startPos)
		p.Parent = parent
		local rise = C.CRAB_ZAP_BUBBLE_RISE_MIN + rng:NextNumber() * C.CRAB_ZAP_BUBBLE_RISE_SPAN
		local drift = Vector3.new(rng:NextNumber(-1.2, 1.2), rise, rng:NextNumber(-1.2, 1.2))
		local life = C.CRAB_ZAP_BUBBLE_LIFE
		TweenService:Create(p, TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			CFrame = CFrame.new(startPos + drift),
			Transparency = 1,
		}):Play()
		task.delay(life + 0.15, function()
			if p.Parent then
				p:Destroy()
			end
		end)
	end

	for _ = 1, C.CRAB_ZAP_COUNT do
		local yaw = rng:NextNumber(0, math.pi * 2)
		local pitch = rng:NextNumber(-0.15, 1.15)
		local reach = rng:NextNumber(2.2, 9.5)
		local dir = Vector3.new(math.cos(yaw) * math.cos(pitch), math.sin(pitch) + 0.55, math.sin(yaw) * math.cos(pitch)) * reach
		local startStuds = rng:NextNumber(C.CRAB_ZAP_START_STUDS, C.CRAB_ZAP_START_STUDS_MAX)
		local endStuds = rng:NextNumber(math.max(startStuds, C.CRAB_ZAP_END_STUDS), C.CRAB_ZAP_END_STUDS_MAX)
		local anchor = Instance.new("Part")
		anchor.Name = "OceanTD_CrabZap"
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.CastShadow = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(0.2, 0.2, 0.2)
		anchor.CFrame = CFrame.new(origin0)
		anchor.Parent = parent

		local bb = Instance.new("BillboardGui")
		bb.Name = "Zap"
		bb.Adornee = anchor
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		bb.MaxDistance = 2000
		bb.Size = UDim2.fromScale(startStuds, startStuds)
		bb.Parent = anchor

		local trans = rng:NextNumber(C.CRAB_ZAP_TRANS_MIN, C.CRAB_ZAP_TRANS_MAX)
		local lbl = Instance.new("TextLabel")
		lbl.BackgroundTransparency = 1
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.Font = Enum.Font.SourceSansBold
		lbl.Text = C.CRAB_ZAP_EMOJI
		lbl.TextScaled = true
		lbl.Rotation = rng:NextNumber(0, 360)
		lbl.TextTransparency = trans
		lbl.TextStrokeTransparency = 0.35 + 0.4 * trans
		lbl.TextStrokeColor3 = Color3.fromRGB(40, 10, 0)
		lbl.Parent = bb

		table.insert(zaps, {
			anchor = anchor,
			bb = bb,
			lbl = lbl,
			spin = rng:NextNumber(180, 520) * (if rng:NextNumber() < 0.5 then -1 else 1),
			dir = dir,
			startStuds = startStuds,
			endStuds = endStuds,
			trans = trans,
			pulse = rng:NextNumber(2.2, 5.5),
			pulseOff = rng:NextNumber(0, math.pi * 2),
			life = rng:NextNumber(C.CRAB_ZAP_LIFE_MIN, C.CRAB_ZAP_LIFE_MAX),
		})
	end

	for _ = 1, C.CRAB_ZAP_BUBBLE_COUNT do
		spawnBubble(origin0)
	end

	local t0 = os.clock()
	local nextBubbleAt = t0 + rng:NextNumber(0.08, 0.18)
	local bubblesDone = false
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		local u = math.clamp((now - t0) / dur, 0, 1)
		local origin = follow()
		local fighting = if stillFighting then stillFighting() else true
		if not bubblesDone then
			if not fighting then
				bubblesDone = true
			elseif u < 0.78 and now >= nextBubbleAt then
				spawnBubble(origin)
				nextBubbleAt = now + rng:NextNumber(0.07, 0.2)
			end
		end
		for _, z in ipairs(zaps) do
			if not z.anchor.Parent then
				continue
			end
			local zu = math.clamp((now - t0) / z.life, 0, 1)
			if zu >= 1 then
				z.anchor:Destroy()
				continue
			end
			local ease = 1 - (1 - zu) * (1 - zu)
			local fade = if zu > 0.72 then math.clamp((zu - 0.72) / 0.28, 0, 1) else 0
			z.lbl.Rotation += z.spin * dt
			z.anchor.CFrame = CFrame.new(origin + z.dir * ease)
			local studs = z.startStuds + (z.endStuds - z.startStuds) * ease
			z.bb.Size = UDim2.fromScale(studs, studs)
			local pulse = 0.5 + 0.5 * math.sin(now * z.pulse + z.pulseOff)
			local liveT = z.trans + (C.CRAB_ZAP_TRANS_MAX - z.trans) * pulse * 0.45
			liveT = math.clamp(liveT, C.CRAB_ZAP_TRANS_MIN, C.CRAB_ZAP_TRANS_MAX)
			z.lbl.TextTransparency = liveT + (1 - liveT) * fade
			z.lbl.TextStrokeTransparency = 0.35 + 0.65 * fade
		end
		if u >= 1 then
			conn:Disconnect()
			for _, z in ipairs(zaps) do
				if z.anchor.Parent then
					z.anchor:Destroy()
				end
			end
		end
	end)
end

return WaveCrab
