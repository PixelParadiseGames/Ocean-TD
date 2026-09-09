--!strict
--[[
	Path geometry + food-meet / flight math for WaveSim.
	Extracted so WaveSim.lua stays under Luau's 200 module-local limit.
	WaveSim should keep ONE local (`Path`) and call Path.foo — do not re-bind each fn.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))
local WaveCrab = require(script.Parent:WaitForChild("WaveCrab"))
local WaveUrchin = require(script.Parent:WaitForChild("WaveUrchin"))
local WaveShark = require(script.Parent:WaitForChild("WaveShark"))
local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
local C = require(script.Parent:WaitForChild("WaveSimConsts"))

local WaveSimPath = {}

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

-- Minimal fish fields used by offset / predict / flight (WaveSim FishAgent is compatible).
export type SwimAgent = {
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
	smoothTang: Vector3,
	root: BasePart,
	isCrab: boolean?,
	isUrchin: boolean?,
	isShark: boolean?,
	groundPath: WaveCrab.PathData?,
	swimPath: PathData?,
	crabSprint: any?,
}

export type FoodFlightShot = {
	startPos: Vector3,
	swayPhase: number,
	target: SwimAgent?,
}

function WaveSimPath.isGroundCritter(f: SwimAgent): boolean
	return f.isCrab == true or f.isUrchin == true
end

function WaveSimPath.fishWorldOffset(agent: SwimAgent, pos: Vector3, tang: Vector3, atDist: number?): Vector3
	local side = Vector3.new(-tang.Z, 0, tang.X)
	if side.Magnitude > 1e-4 then
		side = side.Unit
	else
		side = Vector3.new(1, 0, 0)
	end
	local d = atDist or agent.dist
	local lat = agent.lateral
		+ agent.wanderAmp * math.sin(d * agent.wanderFreq + agent.wanderPhase)
		+ agent.wanderAmp * 0.4 * math.sin(d * agent.wanderFreq * 1.55 + agent.wanderPhase * 1.3)
	local up = agent.vert
		+ agent.bobAmp * math.sin(d * agent.bobFreq + agent.bobPhase)
		+ agent.bobAmp * 0.35 * math.sin(d * agent.bobFreq * 1.4 + agent.bobPhase + 2.0)
	up = math.max(up, C.FISH_MIN_PATH_Y)
	return pos + side * lat + Vector3.yAxis * up
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

function WaveSimPath.stepSwimTang(agent: SwimAgent, tang: Vector3, dt: number): Vector3
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

function WaveSimPath.buildNamedPath(routeName: string, plotSizeStageOverride: number?): PathData?
	local root = Workspace:FindFirstChild("WaveRoute")
	if not root then
		warn("[WAVE] Workspace.WaveRoute missing")
		return nil
	end
	local route = root:FindFirstChild(routeName)
	if not route then
		if routeName == "A" then
			warn("[WAVE] WaveRoute.A missing")
		end
		return nil
	end
	local wpFolder = route:FindFirstChild("Waypoints")
	local ctrlFolder = route:FindFirstChild("Controls")
	if not wpFolder or not ctrlFolder then
		warn("[WAVE] Waypoints/Controls missing on WaveRoute." .. routeName)
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
		warn("[WAVE] Need W1..Wn (at least 2) on", routeName, "; found", #waypoints)
		return nil
	end

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
		warn("[WAVE] PlotSize stage", plotSizeStage, "final W" .. tostring(finalWp), "left <2 waypoints on", routeName)
		return nil
	end

	local mirrored = ClientPlot.get()
	local plotLabel = if mirrored then mirrored.plotId else "?"
	if mirrored and not ClientPlot.getPlot1CFrame() then
		warn("[WAVE] Cannot remap WaveRoute onto", plotLabel, "(missing Plot1 CFrame from server)")
		return nil
	end

	local function wpPos(part: BasePart): Vector3
		return ClientPlot.remapFromPlot1(part.Position)
	end

	local segments: { PathSegment } = {}
	local total = 0
	for s = 1, #waypoints - 1 do
		local ctrl = findIndexedPart(ctrlFolder, "C", s)
		if not ctrl then
			warn("[WAVE] Missing control C" .. tostring(s) .. " for segment W" .. tostring(s) .. "→W" .. tostring(s + 1) .. " on", routeName)
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
		routeName,
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
	local path: PathData = {
		segments = segments,
		totalLen = total,
		endPos = wpPos(waypoints[#waypoints]),
		waypointDists = waypointDists,
	}
	if routeName == "A" then
		WaveEndVfx.setRouteEndWorldPos(path.endPos, if mirrored then mirrored.plotId else nil)
	end
	return path
end

function WaveSimPath.buildPath(plotSizeStageOverride: number?): PathData?
	return WaveSimPath.buildNamedPath("A", plotSizeStageOverride)
end

function WaveSimPath.samplePath(path: PathData, dist: number): (Vector3, Vector3)
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
	local toEnd = seg.cumStart + seg.length - d
	if toEnd < C.TANGENT_BLEND_STUDS and lo < #segs then
		local blend = 1 - math.clamp(toEnd / C.TANGENT_BLEND_STUDS, 0, 1)
		tang = blendUnitTangents(tang, segs[lo + 1].inTang, blend)
	end
	return pos, tang
end

function WaveSimPath.isNearPathEnd(totalLen: number, dist: number): boolean
	return totalLen - dist <= C.DANGER_NEAR_END_STUDS
end

function WaveSimPath.projectPointOntoPath(path: PathData, worldPos: Vector3): (number, number)
	local bestD2 = math.huge
	local bestDist = 0
	local d = 0
	local step = C.PATH_PROJECT_STEP
	while d <= path.totalLen do
		local p = WaveSimPath.samplePath(path, d)
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
	local pEnd = WaveSimPath.samplePath(path, path.totalLen)
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

function WaveSimPath.fishSpeedFactorAt(agent: SwimAgent, clock: number): number
	if WaveSimPath.isGroundCritter(agent) or agent.isShark then
		return 1
	end
	return 1 + C.FISH_SPEED_VAR * math.sin(clock * agent.speedFreq + agent.speedPhase)
end

function WaveSimPath.predictFishDistAhead(agent: SwimAgent, aheadSec: number, simClock: number): number
	local steps = math.max(4, math.ceil(aheadSec * 24))
	local stepDt = aheadSec / steps
	local dist = agent.dist
	local t = simClock
	local speed = if agent.isUrchin
		then WaveUrchin.speedNow() * agent.speedPhase
		elseif agent.isCrab then WaveCrab.speedNow(agent.crabSprint, simClock)
		elseif agent.isShark then WaveShark.speed()
		else C.FISH_SPEED
	for _ = 1, steps do
		dist += speed * WaveSimPath.fishSpeedFactorAt(agent, t) * stepDt
		t += stepDt
	end
	return dist
end

function WaveSimPath.predictFishMeetPos(
	agent: SwimAgent,
	aheadSec: number,
	simClock: number,
	sharkPath: WaveCrab.PathData?,
	groundA: WaveCrab.PathData?,
	groundB: WaveCrab.PathData?,
	swimPath: PathData?
): Vector3?
	if agent.isShark then
		if not sharkPath then
			return nil
		end
		local futureDist = WaveSimPath.predictFishDistAhead(agent, aheadSec, simClock)
		if futureDist >= sharkPath.totalLen - 0.35 then
			return nil
		end
		local pathPos, tang = WaveShark.sample(sharkPath, futureDist)
		local fwd = if tang.Magnitude > 1e-5 then tang.Unit else agent.smoothTang
		if fwd.Magnitude < 1e-5 then
			fwd = Vector3.new(0, 0, -1)
		else
			fwd = fwd.Unit
		end
		return pathPos + fwd * C.FOOD_FRONT_LEAD
	end
	if WaveSimPath.isGroundCritter(agent) then
		local ground = agent.groundPath or WaveCrab.anyGroundPath(groundA, groundB)
		if not ground then
			return nil
		end
		local futureDist = WaveSimPath.predictFishDistAhead(agent, aheadSec, simClock)
		if futureDist >= ground.totalLen - 0.35 then
			return nil
		end
		local pathPos, tang = WaveCrab.sample(ground, futureDist)
		local offset = WaveSimPath.fishWorldOffset(agent, pathPos, tang, futureDist)
		local pos = WaveCrab.worldOnGround(offset, nil, 1)
		local fwd = if tang.Magnitude > 1e-5 then tang.Unit else agent.smoothTang
		if fwd.Magnitude < 1e-5 then
			fwd = Vector3.new(0, 0, -1)
		else
			fwd = fwd.Unit
		end
		return pos + fwd * C.FOOD_FRONT_LEAD
	end
	if not swimPath then
		return nil
	end
	local futureDist = WaveSimPath.predictFishDistAhead(agent, aheadSec, simClock)
	if futureDist >= swimPath.totalLen - 0.35 then
		return nil
	end
	local pos, tang = WaveSimPath.samplePath(swimPath, futureDist)
	local world = WaveSimPath.fishWorldOffset(agent, pos, tang, futureDist)
	local fwd = if tang.Magnitude > 1e-5 then tang.Unit else agent.smoothTang
	if fwd.Magnitude < 1e-5 then
		fwd = Vector3.new(0, 0, -1)
	else
		fwd = fwd.Unit
	end
	return world + fwd * C.FOOD_FRONT_LEAD
end

function WaveSimPath.fishMouthWorld(target: SwimAgent): Vector3
	local fwd = target.smoothTang
	if fwd.Magnitude > 1e-5 then
		fwd = fwd.Unit
	else
		fwd = Vector3.new(0, 0, -1)
	end
	return target.root.Position + fwd * C.FOOD_FRONT_LEAD
end

function WaveSimPath.fishCanEatFood(foodPos: Vector3, fishPos: Vector3, radiusSq: number?, maxY: number?): boolean
	local r2 = if radiusSq ~= nil then radiusSq else C.FOOD_EAT_RADIUS_SQ
	local yMax = if maxY ~= nil then maxY else C.FOOD_EAT_Y
	local dx = fishPos.X - foodPos.X
	local dz = fishPos.Z - foodPos.Z
	if dx * dx + dz * dz > r2 then
		return false
	end
	return math.abs(fishPos.Y - foodPos.Y) <= yMax
end

function WaveSimPath.foodFlightPos(shot: FoodFlightShot, u: number, meetPos: Vector3): Vector3
	local t = math.clamp(u, 0, 1)
	local ease = t * t
	local base = shot.startPos:Lerp(meetPos, ease)
	local along = meetPos - shot.startPos
	local side = Vector3.new(-along.Z, 0, along.X)
	local sideLen = side.Magnitude
	if sideLen > 1e-4 then
		side = side / sideLen
		local envelope = math.sin(t * math.pi)
		if t > 0.7 then
			envelope *= (1 - t) / 0.3
		end
		local sway = math.sin(t * math.pi * 2 + shot.swayPhase) * C.FOOD_SWAY_AMP * envelope
		base = base + side * sway
	end
	local target = shot.target
	if target and WaveSimPath.isGroundCritter(target) then
		local flat = Vector3.new(along.X, 0, along.Z).Magnitude
		local arcH = math.clamp(flat * C.FOOD_CRAB_ARC_FRAC, C.FOOD_CRAB_ARC_MIN, C.FOOD_CRAB_ARC_MAX)
		base = base + Vector3.yAxis * (math.sin(t * math.pi) * arcH)
	end
	return base
end

return WaveSimPath
