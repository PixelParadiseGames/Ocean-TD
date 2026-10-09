--!strict
--[[
	Plot Cam 2 — locked isometric / RTS god-cam over the local plot.

	Default seat: camera on the far/back side of the plot (yawDeg -180 on
	arena-radial base), looking toward the arena. Distance eases from
	distFront (near arena) → distBack (tall back edge); DistOff fine-tunes.
]]

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("Constants"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))

local PlotCam2 = {}

export type Tune = {
	yawDeg: number, -- extra yaw on top of arena-radial base
	yawBiasDeg: number, -- second yaw offset (for A/B while tuning)
	pitchDeg: number,
	distFront: number, -- baseline dist near arena / front
	distBack: number, -- baseline dist at tall back (away from arena)
	distOffset: number, -- fine-tune on top of front↔back baseline
	focusHeight: number,
	panOut: number, -- extra studs along look (toward arena / front)
	panIn: number, -- extra studs opposite look (toward back / ocean)
	panSide: number, -- extra studs for A/D strafe
}

local DEFAULT_PITCH_DEG = 52
local DEFAULT_YAW_DEG = -180
local DEFAULT_YAW_BIAS_DEG = 0
local DEFAULT_FOCUS_HEIGHT = 30
local DEFAULT_DIST_FRONT = 28
local DEFAULT_DIST_BACK = 200
local DEFAULT_DIST_OFFSET = -110 -- max zoom-in (DistOff floor); manual +/- / wheel can reach this
-- Session start: pulled back. Opening BUILD keeps this zoom (no auto slam to max).
local START_DIST_OFFSET = 55
local DEFAULT_PAN_OUT = 200
local DEFAULT_PAN_IN = 20
local DEFAULT_PAN_SIDE = 90
local PITCH_MIN = 15
local PITCH_MAX = 80
local DIST_OFFSET_MIN = -110 -- closer plot zoom
local DIST_OFFSET_MAX = 160
local DIST_MIN = 5 -- floor for effective camera distance
local DIST_MAX = 360
local PAN_AT_REF_DIST = 70
local PAN_EXTRA_MIN = 0
local PAN_EXTRA_MAX = 400
local WHEEL_ZOOM_STEP = 5
local WHEEL_ACTION = "OceanTD_PlotCam2Wheel"
local WHEEL_PRIORITY = Enum.ContextActionPriority.High.Value + 20
local DIST_TWEEN_RATE = 3.5 -- ease toward pan-based baseline (lower = softer)

local active = false
local focus = Vector3.zero
local wheelConn: RBXScriptConnection? = nil
local liveDist = DEFAULT_DIST_FRONT -- smoothed effective distance
-- Until the player opens BUILD once this session, keep the pulled-back start zoom.
local awaitingBuildZoom = true

-- Live tune (also mirrored per plotId while debugging).
local tune: Tune = {
	yawDeg = DEFAULT_YAW_DEG,
	yawBiasDeg = DEFAULT_YAW_BIAS_DEG,
	pitchDeg = DEFAULT_PITCH_DEG,
	distFront = DEFAULT_DIST_FRONT,
	distBack = DEFAULT_DIST_BACK,
	distOffset = START_DIST_OFFSET,
	focusHeight = DEFAULT_FOCUS_HEIGHT,
	panOut = DEFAULT_PAN_OUT,
	panIn = DEFAULT_PAN_IN,
	panSide = DEFAULT_PAN_SIDE,
}
local perPlotTune: { [string]: Tune } = {}
local activePlotId = ""

local function copyTune(t: Tune): Tune
	return {
		yawDeg = t.yawDeg,
		yawBiasDeg = t.yawBiasDeg,
		pitchDeg = t.pitchDeg,
		distFront = t.distFront,
		distBack = t.distBack,
		distOffset = t.distOffset,
		focusHeight = t.focusHeight,
		panOut = t.panOut,
		panIn = t.panIn,
		panSide = t.panSide,
	}
end

local function defaultDistOffset(): number
	return if awaitingBuildZoom then START_DIST_OFFSET else DEFAULT_DIST_OFFSET
end

local function defaultTune(): Tune
	return {
		yawDeg = DEFAULT_YAW_DEG,
		yawBiasDeg = DEFAULT_YAW_BIAS_DEG,
		pitchDeg = DEFAULT_PITCH_DEG,
		distFront = DEFAULT_DIST_FRONT,
		distBack = DEFAULT_DIST_BACK,
		distOffset = defaultDistOffset(),
		focusHeight = DEFAULT_FOCUS_HEIGHT,
		panOut = DEFAULT_PAN_OUT,
		panIn = DEFAULT_PAN_IN,
		panSide = DEFAULT_PAN_SIDE,
	}
end

local function getPlot(): (CFrame?, Vector3?, string?)
	local plot = ClientPlot.get()
	if not plot then
		return nil, nil, nil
	end
	return plot.cframe, plot.size, plot.plotId
end

local function resolveArenaCenter(): Vector3?
	local arena = Workspace:FindFirstChild(Constants.ARENA_FOLDER_NAME)
	if not arena then
		return nil
	end
	local center = arena:FindFirstChild(Constants.CENTER_FOLDER_NAME)
	if not center then
		center = arena:FindFirstChild("Center", true)
	end
	if not center then
		return nil
	end
	if center:IsA("BasePart") then
		return center.Position
	end
	if center:IsA("Model") then
		local pp = center.PrimaryPart
		if pp then
			return pp.Position
		end
	end
	local part = center:FindFirstChildWhichIsA("BasePart", true)
	return if part then part.Position else nil
end

-- Flat unit from arena center → plot (positive = toward plot back / ocean).
local function outwardFlat(plotCf: CFrame): Vector3
	local center = resolveArenaCenter()
	local plotPos = plotCf.Position
	local flat: Vector3
	if center then
		flat = Vector3.new(plotPos.X - center.X, 0, plotPos.Z - center.Z)
	else
		flat = Vector3.new(plotCf.LookVector.X, 0, plotCf.LookVector.Z)
	end
	if flat.Magnitude < 1e-3 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function baseYawFromArena(plotCf: CFrame): number
	local out = outwardFlat(plotCf)
	-- Offset along -out (arena side) before yawDeg; with default yawDeg -180 the
	-- camera sits on the back/ocean side looking toward the arena.
	return math.atan2(-out.X, -out.Z)
end

local function groundY(plotCf: CFrame, plotSize: Vector3): number
	return plotCf.Position.Y - plotSize.Y * 0.5 + tune.focusHeight
end

local function halfExtentAlong(plotCf: CFrame, plotSize: Vector3, dirFlat: Vector3): number
	local localDir = plotCf:VectorToObjectSpace(dirFlat)
	return math.abs(localDir.X) * plotSize.X * 0.5 + math.abs(localDir.Z) * plotSize.Z * 0.5
end

local function composedYawRad(plotCf: CFrame): number
	return baseYawFromArena(plotCf) + math.rad(tune.yawDeg + tune.yawBiasDeg)
end

local function lookFlat(plotCf: CFrame): Vector3
	local yaw = composedYawRad(plotCf)
	local v = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	if v.Magnitude < 1e-4 then
		return Vector3.new(0, 0, -1)
	end
	return v.Unit
end

local function effectiveDist(): number
	return math.clamp(liveDist, DIST_MIN, DIST_MAX)
end

-- 0 = front (near arena), 1 = back (outer edge). Linear across the full
-- panable focus range — no ease/dead zones at the ends.
local function backAlpha(plotCf: CFrame, plotSize: Vector3): number
	local fwd = lookFlat(plotCf)
	local halfR = math.max(halfExtentAlong(plotCf, plotSize, fwd), 4)
	local pitch = math.rad(tune.pitchDeg)
	-- Mid baseline for horiz so the alpha span doesn't fight liveDist.
	local midDist = math.clamp((tune.distFront + tune.distBack) * 0.5, DIST_MIN, DIST_MAX)
	local horiz = math.cos(pitch) * midDist
	local panOut = math.clamp(tune.panOut, PAN_EXTRA_MIN, PAN_EXTRA_MAX)
	local panIn = math.clamp(tune.panIn, PAN_EXTRA_MIN, PAN_EXTRA_MAX)
	-- Same limits as clampFocus (look axis): +fwd = arena/front, -fwd = back.
	local rFront = halfR + horiz + panOut
	local rBack = -(halfR + horiz + panIn)
	local origin = plotCf.Position
	local radial = (focus.X - origin.X) * fwd.X + (focus.Z - origin.Z) * fwd.Z
	local span = rFront - rBack
	if span < 1e-3 then
		return 0
	end
	-- Invert: +fwd end is outer/back for current yaw seat, not arena.
	return math.clamp((radial - rBack) / span, 0, 1)
end

local function baselineDist(plotCf: CFrame, plotSize: Vector3): number
	local a = backAlpha(plotCf, plotSize)
	return tune.distFront + (tune.distBack - tune.distFront) * a
end

local function targetDist(plotCf: CFrame, plotSize: Vector3): number
	return math.clamp(baselineDist(plotCf, plotSize) + tune.distOffset, DIST_MIN, DIST_MAX)
end

local function clampFocus(pos: Vector3, plotCf: CFrame, plotSize: Vector3): Vector3
	local fwd = lookFlat(plotCf)
	local tan = Vector3.new(-fwd.Z, 0, fwd.X)
	local halfR = math.max(halfExtentAlong(plotCf, plotSize, fwd), 4)
	local halfT = math.max(halfExtentAlong(plotCf, plotSize, tan), 4)

	local pitch = math.rad(tune.pitchDeg)
	local dist = effectiveDist()
	local horiz = math.cos(pitch) * dist

	local origin = plotCf.Position
	local dx = pos.X - origin.X
	local dz = pos.Z - origin.Z
	local radial = dx * fwd.X + dz * fwd.Z
	local lateral = dx * tan.X + dz * tan.Z

	local rMax = halfR + horiz + math.clamp(tune.panOut, PAN_EXTRA_MIN, PAN_EXTRA_MAX)
	local rMin = -(halfR + horiz + math.clamp(tune.panIn, PAN_EXTRA_MIN, PAN_EXTRA_MAX))
	local tMax = halfT + math.clamp(tune.panSide, PAN_EXTRA_MIN, PAN_EXTRA_MAX)

	radial = math.clamp(radial, rMin, rMax)
	lateral = math.clamp(lateral, -tMax, tMax)

	local flat = origin + fwd * radial + tan * lateral
	return Vector3.new(flat.X, groundY(plotCf, plotSize), flat.Z)
end

local function cameraCFrame(plotCf: CFrame): CFrame
	local pitch = math.rad(tune.pitchDeg)
	local yaw = composedYawRad(plotCf)
	local distance = effectiveDist()
	local horiz = math.cos(pitch) * distance
	local up = math.sin(pitch) * distance
	local flat = Vector3.new(math.sin(yaw) * horiz, 0, math.cos(yaw) * horiz)
	local camPos = focus + flat + Vector3.new(0, up, 0)
	return CFrame.lookAt(camPos, focus)
end

local function syncDistOffsetAchievable(plotCf: CFrame, plotSize: Vector3)
	-- Kill DistOff dead-zone: when baseline+offset is clamped by DIST_MIN/MAX,
	-- further +/- clicks must move the camera on the first notch.
	local base = baselineDist(plotCf, plotSize)
	local minOff = math.max(DIST_OFFSET_MIN, DIST_MIN - base)
	local maxOff = math.min(DIST_OFFSET_MAX, DIST_MAX - base)
	if minOff > maxOff then
		minOff, maxOff = maxOff, minOff
	end
	tune.distOffset = math.clamp(tune.distOffset, minOff, maxOff)
end

local function snapLiveDist()
	local plotCf, plotSize = getPlot()
	if plotCf and plotSize then
		syncDistOffsetAchievable(plotCf, plotSize)
		liveDist = targetDist(plotCf, plotSize)
	end
end

-- Same as DistOff +/- quick buttons: scroll up zooms in (-DistOff), down zooms out.
local function applyWheelZoom(wheelZ: number): boolean
	if not active or wheelZ == 0 or wheelZ ~= wheelZ then
		return false
	end
	if InventoryState.isOpen() then
		local mouse = UserInputService:GetMouseLocation()
		if InventoryState.isPointerOverBackpack(mouse) then
			return false
		end
	end
	-- Multi-notch wheels: |Z| can be >1. Scroll up (+Z) -> zoom in -> lower DistOff.
	local delta = -wheelZ * WHEEL_ZOOM_STEP
	return PlotCam2.nudge("distOffset", delta)
end

local function bindWheel()
	ContextActionService:UnbindAction(WHEEL_ACTION)
	if wheelConn then
		return
	end
	wheelConn = UserInputService.InputChanged:Connect(function(input, _gameProcessed)
		if not active or input.UserInputType ~= Enum.UserInputType.MouseWheel then
			return
		end
		local z = input.Position.Z
		if (z == 0 or z ~= z) and typeof(input.Delta) == "Vector3" then
			z = input.Delta.Z
		end
		applyWheelZoom(z)
	end)
end

local function unbindWheel()
	ContextActionService:UnbindAction(WHEEL_ACTION)
	if wheelConn then
		wheelConn:Disconnect()
		wheelConn = nil
	end
end

local function persistTune()
	if activePlotId ~= "" then
		perPlotTune[activePlotId] = copyTune(tune)
	end
end

local function migrateTune(saved: Tune, base: Tune): Tune
	local s = saved :: any
	local t = copyTune(base)
	t.yawDeg = if s.yawDeg ~= nil then s.yawDeg else t.yawDeg
	t.yawBiasDeg = if s.yawBiasDeg ~= nil then s.yawBiasDeg else t.yawBiasDeg
	t.pitchDeg = if s.pitchDeg ~= nil then s.pitchDeg else t.pitchDeg
	t.focusHeight = if s.focusHeight ~= nil then s.focusHeight else t.focusHeight
	t.panOut = if s.panOut ~= nil then s.panOut else t.panOut
	t.panIn = if s.panIn ~= nil then s.panIn else t.panIn
	t.panSide = if s.panSide ~= nil then s.panSide else t.panSide
	t.distFront = if s.distFront ~= nil then s.distFront else t.distFront
	t.distBack = if s.distBack ~= nil then s.distBack else t.distBack
	if s.distOffset ~= nil then
		t.distOffset = s.distOffset
	elseif s.dist ~= nil then
		-- Old absolute dist → treat as offset from front baseline.
		t.distOffset = (s.dist :: number) - t.distFront
	end
	t.pitchDeg = math.clamp(t.pitchDeg, PITCH_MIN, PITCH_MAX)
	t.distOffset = math.clamp(t.distOffset, DIST_OFFSET_MIN, DIST_OFFSET_MAX)
	t.distFront = math.clamp(t.distFront, DIST_MIN, DIST_MAX)
	t.distBack = math.clamp(t.distBack, DIST_MIN, DIST_MAX)
	return t
end

local function loadTuneForPlot(plotId: string, plotSize: Vector3)
	activePlotId = plotId
	local saved = perPlotTune[plotId]
	local base = defaultTune()
	if saved then
		tune = migrateTune(saved, base)
	else
		tune = base
	end
	-- Fresh join: prefer start zoom even if a prior session baked DistOff in.
	if awaitingBuildZoom then
		tune.distOffset = START_DIST_OFFSET
	end
end

function PlotCam2.isActive(): boolean
	return active
end

function PlotCam2.getTune(): Tune
	return copyTune(tune)
end

function PlotCam2.getPlotId(): string
	return activePlotId
end

function PlotCam2.getBaseYawDeg(): number
	local plotCf = select(1, getPlot())
	if not plotCf then
		return 0
	end
	return math.deg(baseYawFromArena(plotCf))
end

function PlotCam2.getLiveDist(): number
	return effectiveDist()
end

function PlotCam2.formatTune(): string
	local base = PlotCam2.getBaseYawDeg()
	return string.format(
		"plotId=%s baseYawDeg=%.1f yawDeg=%g yawBiasDeg=%g pitchDeg=%g distFront=%g distBack=%g distOffset=%g liveDist=%.1f focusHeight=%g panOut=%g panIn=%g panSide=%g",
		if activePlotId ~= "" then activePlotId else "?",
		base,
		tune.yawDeg,
		tune.yawBiasDeg,
		tune.pitchDeg,
		tune.distFront,
		tune.distBack,
		tune.distOffset,
		effectiveDist(),
		tune.focusHeight,
		tune.panOut,
		tune.panIn,
		tune.panSide
	)
end

function PlotCam2.nudge(key: string, delta: number): boolean
	local before: number
	local after: number
	if key == "yawDeg" then
		before = tune.yawDeg
		tune.yawDeg += delta
		after = tune.yawDeg
	elseif key == "yawBiasDeg" then
		before = tune.yawBiasDeg
		tune.yawBiasDeg += delta
		after = tune.yawBiasDeg
	elseif key == "pitchDeg" then
		before = tune.pitchDeg
		tune.pitchDeg = math.clamp(tune.pitchDeg + delta, PITCH_MIN, PITCH_MAX)
		after = tune.pitchDeg
	elseif key == "dist" or key == "distOffset" then
		before = tune.distOffset
		tune.distOffset = math.clamp(tune.distOffset + delta, DIST_OFFSET_MIN, DIST_OFFSET_MAX)
		snapLiveDist()
		after = tune.distOffset
	elseif key == "distFront" then
		before = tune.distFront
		tune.distFront = math.clamp(tune.distFront + delta, DIST_MIN, DIST_MAX)
		after = tune.distFront
	elseif key == "distBack" then
		before = tune.distBack
		tune.distBack = math.clamp(tune.distBack + delta, DIST_MIN, DIST_MAX)
		after = tune.distBack
	elseif key == "focusHeight" then
		before = tune.focusHeight
		tune.focusHeight = math.clamp(tune.focusHeight + delta, -10, 80)
		after = tune.focusHeight
	elseif key == "panOut" then
		before = tune.panOut
		tune.panOut = math.clamp(tune.panOut + delta, PAN_EXTRA_MIN, PAN_EXTRA_MAX)
		after = tune.panOut
	elseif key == "panIn" then
		before = tune.panIn
		tune.panIn = math.clamp(tune.panIn + delta, PAN_EXTRA_MIN, PAN_EXTRA_MAX)
		after = tune.panIn
	elseif key == "panSide" then
		before = tune.panSide
		tune.panSide = math.clamp(tune.panSide + delta, PAN_EXTRA_MIN, PAN_EXTRA_MAX)
		after = tune.panSide
	else
		return false
	end
	persistTune()
	return before ~= after
end

function PlotCam2.resetTune()
	tune = defaultTune()
	liveDist = tune.distFront + tune.distOffset
	persistTune()
end

-- First BUILD open this session: ease DistOff 60% of the way from start → max zoom-in
-- (not all the way; DistOff +/- / wheel still reach DIST_OFFSET_MIN).
function PlotCam2.notifyBuildOpened()
	if not awaitingBuildZoom then
		return
	end
	awaitingBuildZoom = false
	local from = START_DIST_OFFSET
	local to = DEFAULT_DIST_OFFSET
	tune.distOffset = math.clamp(from + (to - from) * 0.60, DIST_OFFSET_MIN, DIST_OFFSET_MAX)
	persistTune()
	-- liveDist keeps easing via DIST_TWEEN_RATE in tick().
end

function PlotCam2.begin(resumeCf: CFrame?): boolean
	local plotCf, plotSize, plotId = getPlot()
	if not plotCf or not plotSize or not plotId then
		active = false
		return false
	end
	loadTuneForPlot(plotId, plotSize)
	focus = clampFocus(plotCf.Position, plotCf, plotSize)

	if resumeCf then
		local look = resumeCf.LookVector
		local origin = resumeCf.Position
		local gy = groundY(plotCf, plotSize)
		if math.abs(look.Y) > 0.05 then
			local t = (gy - origin.Y) / look.Y
			if t > 0 then
				focus = clampFocus(origin + look * t, plotCf, plotSize)
			end
		end
	end

	syncDistOffsetAchievable(plotCf, plotSize)
	liveDist = targetDist(plotCf, plotSize)
	active = true
	bindWheel()
	return true
end

function PlotCam2.stop()
	active = false
	unbindWheel()
end

function PlotCam2.getCFrame(): CFrame?
	if not active then
		return nil
	end
	local plotCf = select(1, getPlot())
	if not plotCf then
		return nil
	end
	return cameraCFrame(plotCf)
end

export type TickInput = {
	wish: Vector3,
	panSpeed: number,
}

function PlotCam2.tick(dt: number, input: TickInput): CFrame?
	if not active then
		return nil
	end
	local plotCf, plotSize, plotId = getPlot()
	if not plotCf or not plotSize then
		PlotCam2.stop()
		return nil
	end
	if plotId and plotId ~= activePlotId then
		loadTuneForPlot(plotId, plotSize)
		focus = clampFocus(plotCf.Position, plotCf, plotSize)
	end

	syncDistOffsetAchievable(plotCf, plotSize)

	local wish = input.wish
	-- E/Q keyboard zoom (wheel applies DistOff immediately via nudge).
	local zoom = -wish.Y * input.panSpeed * dt * 0.85
	if math.abs(zoom) > 1e-4 then
		tune.distOffset = math.clamp(tune.distOffset + zoom, DIST_OFFSET_MIN, DIST_OFFSET_MAX)
		syncDistOffsetAchievable(plotCf, plotSize)
		persistTune()
	end

	local pan = Vector3.new(wish.X, 0, wish.Z)
	if pan.Magnitude > 1e-4 then
		local scale = math.clamp(effectiveDist() / PAN_AT_REF_DIST, 0.55, 2.4)
		focus = clampFocus(focus + pan.Unit * (input.panSpeed * scale * dt), plotCf, plotSize)
	else
		focus = Vector3.new(focus.X, groundY(plotCf, plotSize), focus.Z)
	end

	local want = targetDist(plotCf, plotSize)
	local alpha = math.clamp(DIST_TWEEN_RATE * dt, 0, 1)
	liveDist += (want - liveDist) * alpha

	return cameraCFrame(plotCf)
end

return PlotCam2
