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
-- Session start / post-intro seat: pulled back. Opening BUILD eases toward max zoom-in.
-- Was 55; +30% more zoomed out for the intro→plot handoff.
local START_DIST_OFFSET = 72
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
-- DistOff zoom step scales with closeness: ~2% near max zoom-in, ~12% near max zoom-out.
local DIST_ZOOM_PCT_NEAR = 0.02
local DIST_ZOOM_PCT_FAR = 0.12
local WHEEL_ACTION = "OceanTD_PlotCam2Wheel"
local WHEEL_PRIORITY = Enum.ContextActionPriority.High.Value + 20
local DIST_TWEEN_RATE = 3.5 -- ease toward pan-based baseline (lower = softer)

local active = false
local focus = Vector3.zero
local wheelConn: RBXScriptConnection? = nil
local liveDist = DEFAULT_DIST_FRONT -- smoothed effective distance
-- Until the player opens BUILD once this session, keep the pulled-back start zoom.
local awaitingBuildZoom = true
-- TouchPinch: distance at gesture Begin (BaseCamera-style scale apply).
local pinchBeginDist: number? = nil
local PINCH_DELTA_TO_DISTOFF = 8
-- Place-mode zoom: stash pre-place view, tween into close-up, restore on PLANT/cancel.
-- Option 2 (viewport-anchor): pitch + DistOff from size class × coral height; focus Y is
-- solved so the plant point sits at a fixed normalized viewport target (all screens).
-- Tall meshes (sponge / tree / seagrass) pull back more at M/L; short balanced/fast stay closer.
local PLACE_ZOOM_TWEEN_SEC = 0.55
-- Plant X is centered by locking look-at XZ to the plant; Y is solved to this fraction.
local PLACE_ANCHOR_Y = 0.70 -- normalized viewport Y (0 top → 1 bottom)
local PLACE_ANCHOR_SOLVE_ITERS = 16
type PlaceZoomSeat = { pitchDeg: number, distOffset: number }
local PLACE_ZOOM_PITCH = 15
-- Fallback height when caller doesn't pass mesh bounds (studs).
local PLACE_ZOOM_DEFAULT_H: { [number]: number } = {
	[1] = 4,
	[2] = 10,
	[3] = 22,
}

local function placeZoomSeatForClass(sizeClass: number?, heightStuds: number?, speciesId: string?): PlaceZoomSeat
	local c = math.clamp(math.floor(tonumber(sizeClass) or 1), 1, 3)
	local hFallback = PLACE_ZOOM_DEFAULT_H[c] or 4
	local h = math.clamp(tonumber(heightStuds) or hFallback, 1.5, 50)
	-- 0 = short pad coral, 1 = tall column (sponge / tree large).
	local tall = math.clamp((h - 3) / 22, 0, 1)
	local dist: number
	if c <= 1 then
		dist = -78
	elseif c == 2 then
		-- Clear step out from small for every species; tall pulls further.
		dist = -78 + (12 + 14 * tall) -- short ≈ -66, tall ≈ -52
	else
		local med = -78 + (12 + 14 * tall)
		-- Short large: modest extra pullback; tall large: sponge/tree seat (~-41).
		dist = med + (8 + 22 * tall) -- short ≈ -58, tall ≈ -42
		dist = math.clamp(dist, -80, -41)
	end
	-- Species tweaks: SeaGrass Small was too tight; Large is extra tall; SeaFan M/L too pulled-back.
	if speciesId == "SeaGrass" and c <= 1 then
		dist = math.clamp(dist + 14, DIST_OFFSET_MIN, DIST_OFFSET_MAX) -- -78 → ~-64
	elseif speciesId == "SeaGrass" and c >= 3 then
		dist = math.clamp(dist + 10, DIST_OFFSET_MIN, -28)
	elseif speciesId == "SeaFan" and c >= 2 then
		dist = math.clamp(dist - 14, DIST_OFFSET_MIN, DIST_OFFSET_MAX)
	end
	return {
		pitchDeg = PLACE_ZOOM_PITCH,
		distOffset = math.clamp(dist, DIST_OFFSET_MIN, DIST_OFFSET_MAX),
	}
end
type PlaceZoomStash = {
	focus: Vector3,
	distOffset: number,
	pitchDeg: number,
	focusHeight: number,
	liveDist: number,
}
type PlaceZoomTween = {
	t0: number,
	dur: number,
	fromPitch: number,
	toPitch: number,
	fromDist: number,
	toDist: number,
	fromFocusH: number,
	toFocusH: number,
	fromFocus: Vector3,
	toFocus: Vector3,
	restore: boolean,
}
local placeZoomStash: PlaceZoomStash? = nil
local placeZoomTween: PlaceZoomTween? = nil
local placeZoomFocusGoal: Vector3? = nil
-- focus.Y - plant.Y after last viewport solve (kept while dragging so ± seats stay stable).
local placeZoomFocusOffsetY: number? = nil
-- Follow coral plant height while settled in close-up (slopes / 0.5s ground refresh).
local placeZoomFocusYLive: number? = nil
local placeZoomFocusYTarget: number? = nil
local PLACE_ZOOM_Y_SOFT = 1.2 -- studs: small rises/drops — gentle nudge only
local PLACE_ZOOM_Y_SOFT_RATE = 2.5
local PLACE_ZOOM_Y_CATCH_RATE = 5.5 -- larger gaps — smooth lerp into view

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

local function zoomBlockedByBackpack(): boolean
	if InventoryState.isOpen() then
		local mouse = UserInputService:GetMouseLocation()
		if InventoryState.isPointerOverBackpack(mouse) then
			return true
		end
	end
	return false
end

-- DistOff step magnitude: small when zoomed in (precision), large when zoomed out (speed).
function PlotCam2.distOffsetZoomStep(): number
	local span = DIST_OFFSET_MAX - DIST_OFFSET_MIN
	if span <= 1e-3 then
		return 1
	end
	local t = math.clamp((tune.distOffset - DIST_OFFSET_MIN) / span, 0, 1)
	local pct = DIST_ZOOM_PCT_NEAR + (DIST_ZOOM_PCT_FAR - DIST_ZOOM_PCT_NEAR) * t
	return math.max(1, span * pct)
end

-- Same as DistOff +/- quick buttons: scroll up zooms in (-DistOff), down zooms out.
local function applyWheelZoom(wheelZ: number): boolean
	if not active or wheelZ == 0 or wheelZ ~= wheelZ then
		return false
	end
	if zoomBlockedByBackpack() then
		return false
	end
	-- Multi-notch wheels: |Z| can be >1. Scroll up (+Z) -> zoom in -> lower DistOff.
	local delta = -wheelZ * PlotCam2.distOffsetZoomStep()
	return PlotCam2.nudge("distOffset", delta)
end

-- Roblox BaseCamera pinch: newDist = beginDist / clamp(scale). Spread → zoom in.
function PlotCam2.applyPinchGesture(phase: string, scale: number): boolean
	if not active then
		return false
	end
	if zoomBlockedByBackpack() then
		return false
	end
	if phase == "begin" then
		local plotCf, plotSize = getPlot()
		if not plotCf or not plotSize then
			pinchBeginDist = nil
			return false
		end
		pinchBeginDist = targetDist(plotCf, plotSize)
		return true
	end
	if phase ~= "change" and phase ~= "end" then
		return false
	end
	local beginDist = pinchBeginDist
	if not beginDist or typeof(scale) ~= "number" or scale ~= scale or scale <= 0 then
		if phase == "end" then
			pinchBeginDist = nil
		end
		return false
	end
	local plotCf, plotSize = getPlot()
	if not plotCf or not plotSize then
		if phase == "end" then
			pinchBeginDist = nil
		end
		return false
	end
	local clampedScale = math.clamp(scale, 0.1, 10)
	local wantDist = math.clamp(beginDist / clampedScale, DIST_MIN, DIST_MAX)
	local base = baselineDist(plotCf, plotSize)
	tune.distOffset = math.clamp(wantDist - base, DIST_OFFSET_MIN, DIST_OFFSET_MAX)
	snapLiveDist()
	if phase == "end" then
		pinchBeginDist = nil
	end
	return true
end

-- PointerAction pinch delta: positive → zoom in (lower DistOff).
function PlotCam2.applyPinchDelta(pinchDelta: number): boolean
	if not active or typeof(pinchDelta) ~= "number" or pinchDelta ~= pinchDelta or pinchDelta == 0 then
		return false
	end
	if zoomBlockedByBackpack() then
		return false
	end
	return PlotCam2.nudge("distOffset", -pinchDelta * PINCH_DELTA_TO_DISTOFF)
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

function PlotCam2.getFocus(): Vector3
	return focus
end

export type ViewSnapshot = {
	focus: Vector3,
	pitchDeg: number,
	distOffset: number,
	focusHeight: number,
	yawDeg: number,
	yawBiasDeg: number,
	liveDist: number,
}

function PlotCam2.captureView(): ViewSnapshot?
	if not active then
		return nil
	end
	return {
		focus = focus,
		pitchDeg = tune.pitchDeg,
		distOffset = tune.distOffset,
		focusHeight = tune.focusHeight,
		yawDeg = tune.yawDeg,
		yawBiasDeg = tune.yawBiasDeg,
		liveDist = liveDist,
	}
end

function PlotCam2.applyViewSnapshot(snap: ViewSnapshot): boolean
	if not active then
		return false
	end
	local plotCf, plotSize = getPlot()
	if not plotCf or not plotSize then
		return false
	end
	tune.pitchDeg = math.clamp(snap.pitchDeg, PITCH_MIN, PITCH_MAX)
	tune.distOffset = math.clamp(snap.distOffset, DIST_OFFSET_MIN, DIST_OFFSET_MAX)
	tune.focusHeight = snap.focusHeight
	tune.yawDeg = snap.yawDeg
	tune.yawBiasDeg = snap.yawBiasDeg
	focus = clampFocus(snap.focus, plotCf, plotSize)
	liveDist = math.clamp(snap.liveDist, DIST_MIN, DIST_MAX)
	syncDistOffsetAchievable(plotCf, plotSize)
	return true
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

local function easeOutCubic(t: number): number
	local u = 1 - math.clamp(t, 0, 1)
	return 1 - u * u * u
end

local function plotFloorY(plotCf: CFrame, plotSize: Vector3): number
	return plotCf.Position.Y - plotSize.Y * 0.5
end

local function focusHeightForLookY(lookY: number, plotCf: CFrame, plotSize: Vector3): number
	return lookY - plotFloorY(plotCf, plotSize)
end

-- Focus under a destination seat so clamp/Y match that pitch / DistOff / height.
local function placeZoomFocusAt(worldPos: Vector3, pitchDeg: number, focusH: number, distOff: number): Vector3
	local plotCf, plotSize = getPlot()
	if not plotCf or not plotSize then
		return worldPos
	end
	local prevPitch = tune.pitchDeg
	local prevH = tune.focusHeight
	local prevOff = tune.distOffset
	local prevLive = liveDist
	tune.pitchDeg = pitchDeg
	tune.focusHeight = focusH
	tune.distOffset = distOff
	liveDist = targetDist(plotCf, plotSize)
	local result = clampFocus(worldPos, plotCf, plotSize)
	tune.pitchDeg = prevPitch
	tune.focusHeight = prevH
	tune.distOffset = prevOff
	liveDist = prevLive
	return result
end

local function placeZoomCamAt(focusPos: Vector3, pitchDeg: number, dist: number, plotCf: CFrame): CFrame
	local pitch = math.rad(pitchDeg)
	local yaw = composedYawRad(plotCf)
	local horiz = math.cos(pitch) * dist
	local up = math.sin(pitch) * dist
	local flat = Vector3.new(math.sin(yaw) * horiz, 0, math.cos(yaw) * horiz)
	local camPos = focusPos + flat + Vector3.new(0, up, 0)
	return CFrame.lookAt(camPos, focusPos)
end

-- Normalized screen Y (0 = top, 1 = bottom) for plant under a candidate look-at.
local function plantScreenYNorm(plantPos: Vector3, camCf: CFrame, fovDeg: number, vp: Vector2): number?
	local rel = camCf:PointToObjectSpace(plantPos)
	local depth = -rel.Z
	if depth <= 1e-3 then
		return nil
	end
	local tanHalf = math.tan(math.rad(fovDeg) * 0.5)
	if tanHalf < 1e-6 then
		return nil
	end
	local ndcY = (rel.Y / depth) / tanHalf
	return (1 - ndcY) * 0.5
end

-- Binary-search look-at Y so plant lands on PLACE_ANCHOR (seat pitch/dist fixed).
local function solveViewportAnchorFocus(plantPos: Vector3, pitchDeg: number, distOff: number): (Vector3, number)
	local plotCf, plotSize = getPlot()
	if not plotCf or not plotSize then
		return plantPos, tune.focusHeight
	end
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local fovDeg = if cam then cam.FieldOfView else 70

	local prevPitch = tune.pitchDeg
	local prevH = tune.focusHeight
	local prevOff = tune.distOffset
	local prevLive = liveDist
	local prevFocus = focus

	tune.pitchDeg = pitchDeg
	tune.distOffset = distOff
	tune.focusHeight = math.max(plantPos.Y - plotFloorY(plotCf, plotSize), 1)
	focus = clampFocus(plantPos, plotCf, plotSize)
	liveDist = targetDist(plotCf, plotSize)
	local dist = liveDist
	local baseX, baseZ = focus.X, focus.Z

	local lo = plantPos.Y - 12
	local hi = plantPos.Y + 120
	local bestY = focus.Y
	for _ = 1, PLACE_ANCHOR_SOLVE_ITERS do
		local mid = (lo + hi) * 0.5
		local fpos = Vector3.new(baseX, mid, baseZ)
		local sy = plantScreenYNorm(plantPos, placeZoomCamAt(fpos, pitchDeg, dist, plotCf), fovDeg, vp)
		if sy == nil then
			-- Plant behind / degenerate — pull look-at toward plant.
			hi = mid
		elseif sy < PLACE_ANCHOR_Y then
			-- Plant too high on screen → raise look-at so it drops.
			lo = mid
		else
			hi = mid
		end
		bestY = mid
	end

	tune.pitchDeg = prevPitch
	tune.focusHeight = prevH
	tune.distOffset = prevOff
	liveDist = prevLive
	focus = prevFocus

	local look = Vector3.new(baseX, bestY, baseZ)
	return look, focusHeightForLookY(bestY, plotCf, plotSize)
end

local function startPlaceZoomTween(
	toPitch: number,
	toDist: number,
	toFocusH: number,
	toFocus: Vector3,
	restore: boolean
)
	local plotCf, plotSize = getPlot()
	-- Sync fromFocusH to the live look-at Y so the first tween frame doesn't snap.
	local fromFocusH = tune.focusHeight
	if plotCf and plotSize then
		fromFocusH = focusHeightForLookY(focus.Y, plotCf, plotSize)
		tune.focusHeight = fromFocusH
	end
	placeZoomTween = {
		t0 = os.clock(),
		dur = PLACE_ZOOM_TWEEN_SEC,
		fromPitch = tune.pitchDeg,
		toPitch = toPitch,
		fromDist = tune.distOffset,
		toDist = toDist,
		fromFocusH = fromFocusH,
		toFocusH = toFocusH,
		fromFocus = focus,
		toFocus = toFocus,
		restore = restore,
	}
end

local function stepPlaceZoomTween()
	local tw = placeZoomTween
	if not tw then
		return
	end
	local a = math.clamp((os.clock() - tw.t0) / math.max(tw.dur, 1e-3), 0, 1)
	local e = easeOutCubic(a)
	tune.pitchDeg = tw.fromPitch + (tw.toPitch - tw.fromPitch) * e
	tune.distOffset = tw.fromDist + (tw.toDist - tw.fromDist) * e
	tune.focusHeight = tw.fromFocusH + (tw.toFocusH - tw.fromFocusH) * e
	local lerped = tw.fromFocus:Lerp(tw.toFocus, e)
	local plotCf, plotSize = getPlot()
	if plotCf and plotSize then
		focus = Vector3.new(lerped.X, groundY(plotCf, plotSize), lerped.Z)
		-- Distance follows the lerped seat every frame — no lag-then-catch-up second motion.
		liveDist = targetDist(plotCf, plotSize)
	else
		focus = lerped
	end
	if a < 1 then
		return
	end
	tune.pitchDeg = tw.toPitch
	tune.distOffset = tw.toDist
	tune.focusHeight = tw.toFocusH
	if plotCf and plotSize then
		focus = Vector3.new(tw.toFocus.X, groundY(plotCf, plotSize), tw.toFocus.Z)
		liveDist = targetDist(plotCf, plotSize)
	else
		focus = tw.toFocus
	end
	placeZoomTween = nil
	if tw.restore then
		placeZoomStash = nil
		placeZoomFocusGoal = nil
		placeZoomFocusOffsetY = nil
		placeZoomFocusYLive = nil
		placeZoomFocusYTarget = nil
		persistTune()
	else
		-- Seat arrived — start height tracking from this look-at Y.
		placeZoomFocusYLive = focus.Y
		placeZoomFocusYTarget = focus.Y
	end
end

local function clearPlaceZoomHeightTrack()
	placeZoomFocusYLive = nil
	placeZoomFocusYTarget = nil
end

local function stepPlaceZoomHeightFollow(dt: number)
	local live = placeZoomFocusYLive
	local target = placeZoomFocusYTarget
	if live == nil or target == nil then
		return
	end
	local dy = target - live
	local ady = math.abs(dy)
	if ady < 1e-3 then
		placeZoomFocusYLive = target
		focus = Vector3.new(focus.X, target, focus.Z)
		return
	end
	local rate = if ady <= PLACE_ZOOM_Y_SOFT then PLACE_ZOOM_Y_SOFT_RATE else PLACE_ZOOM_Y_CATCH_RATE
	live += dy * math.clamp(rate * dt, 0, 1)
	placeZoomFocusYLive = live
	focus = Vector3.new(focus.X, live, focus.Z)
end

function PlotCam2.isPlaceZoomActive(): boolean
	return placeZoomStash ~= nil
end

local function startSeatTween(seat: PlaceZoomSeat, worldPos: Vector3?, restore: boolean)
	local toPitch = math.clamp(seat.pitchDeg, PITCH_MIN, PITCH_MAX)
	local toDist = math.clamp(seat.distOffset, DIST_OFFSET_MIN, DIST_OFFSET_MAX)
	local plant = if typeof(worldPos) == "Vector3" then worldPos else focus
	local toFocus, toFocusH = solveViewportAnchorFocus(plant, toPitch, toDist)
	placeZoomFocusOffsetY = toFocus.Y - plant.Y
	placeZoomFocusGoal = toFocus
	-- Seat ease owns Y until it finishes (then height-follow re-arms).
	clearPlaceZoomHeightTrack()
	startPlaceZoomTween(toPitch, toDist, toFocusH, toFocus, restore)
end

-- Capture current view once, then tween into the coral close-up (small by default).
function PlotCam2.beginPlaceZoom(worldPos: Vector3?, sizeClass: number?, heightStuds: number?, speciesId: string?): boolean
	if not active then
		return false
	end
	if not placeZoomStash then
		placeZoomStash = {
			focus = focus,
			distOffset = tune.distOffset,
			pitchDeg = tune.pitchDeg,
			focusHeight = tune.focusHeight,
			liveDist = liveDist,
		}
		startSeatTween(placeZoomSeatForClass(sizeClass or 1, heightStuds, speciesId), worldPos, false)
	elseif not placeZoomTween then
		if typeof(worldPos) == "Vector3" then
			local seat = placeZoomSeatForClass(sizeClass or 1, heightStuds, speciesId)
			local toPitch = math.clamp(seat.pitchDeg, PITCH_MIN, PITCH_MAX)
			local toDist = math.clamp(seat.distOffset, DIST_OFFSET_MIN, DIST_OFFSET_MAX)
			local toFocus, toFocusH = solveViewportAnchorFocus(worldPos, toPitch, toDist)
			tune.pitchDeg = toPitch
			tune.distOffset = toDist
			tune.focusHeight = toFocusH
			focus = toFocus
			placeZoomFocusOffsetY = toFocus.Y - worldPos.Y
			placeZoomFocusGoal = focus
			placeZoomFocusYLive = focus.Y
			placeZoomFocusYTarget = focus.Y
		end
	end
	return true
end

-- Soft-plant size upgrade: re-tween from the current close-up into the medium/large seat.
function PlotCam2.retargetPlaceZoom(worldPos: Vector3?, sizeClass: number?, heightStuds: number?, speciesId: string?): boolean
	if not active then
		return false
	end
	if not placeZoomStash then
		return PlotCam2.beginPlaceZoom(worldPos, sizeClass, heightStuds, speciesId)
	end
	-- Keep original pre-place stash; ease into new pitch/DistOff + same viewport anchor.
	startSeatTween(placeZoomSeatForClass(sizeClass or 1, heightStuds, speciesId), worldPos, false)
	return true
end

function PlotCam2.updatePlaceZoom(worldPos: Vector3?)
	if not active or not placeZoomStash then
		return
	end
	-- Seat tween owns framing; only follow the coral after we've settled.
	if placeZoomTween then
		return
	end
	local plotCf, plotSize = getPlot()
	if not plotCf or not plotSize then
		return
	end
	if typeof(worldPos) == "Vector3" then
		local goal = clampFocus(worldPos, plotCf, plotSize)
		placeZoomFocusGoal = goal
		-- XZ follow plant; Y keeps the solved plant→look-at offset (viewport anchor).
		local off = placeZoomFocusOffsetY
		if off == nil then
			off = focus.Y - worldPos.Y
			placeZoomFocusOffsetY = off
		end
		local desiredY = worldPos.Y + off
		placeZoomFocusYTarget = desiredY
		if placeZoomFocusYLive == nil then
			placeZoomFocusYLive = goal.Y
		end
		focus = Vector3.new(goal.X, placeZoomFocusYLive, goal.Z)
		tune.focusHeight = focusHeightForLookY(placeZoomFocusYLive or desiredY, plotCf, plotSize)
	end
end

function PlotCam2.endPlaceZoom()
	local stash = placeZoomStash
	if not stash then
		placeZoomTween = nil
		placeZoomFocusGoal = nil
		placeZoomFocusOffsetY = nil
		clearPlaceZoomHeightTrack()
		return
	end
	-- finishConfirm + exitPlacement both call this — only one restore tween.
	if placeZoomTween and placeZoomTween.restore then
		return
	end
	if not active then
		placeZoomStash = nil
		placeZoomTween = nil
		placeZoomFocusGoal = nil
		placeZoomFocusOffsetY = nil
		clearPlaceZoomHeightTrack()
		return
	end
	clearPlaceZoomHeightTrack()
	placeZoomFocusOffsetY = nil
	local toPitch = math.clamp(stash.pitchDeg, PITCH_MIN, PITCH_MAX)
	local toDist = math.clamp(stash.distOffset, DIST_OFFSET_MIN, DIST_OFFSET_MAX)
	local toFocus = placeZoomFocusAt(stash.focus, toPitch, stash.focusHeight, toDist)
	-- Tween back to the pre-place seat (debug ± during close-up is discarded).
	startPlaceZoomTween(toPitch, toDist, stash.focusHeight, toFocus, true)
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

	-- Place-zoom tween owns pitch/DistOff/focus/liveDist — don't fight it with sync/pan.
	if not placeZoomTween then
		syncDistOffsetAchievable(plotCf, plotSize)
	end

	local wish = input.wish
	-- E/Q keyboard zoom (wheel applies DistOff immediately via nudge).
	local zoom = -wish.Y * input.panSpeed * dt * 0.85
	if math.abs(zoom) > 1e-4 and not placeZoomTween then
		tune.distOffset = math.clamp(tune.distOffset + zoom, DIST_OFFSET_MIN, DIST_OFFSET_MAX)
		syncDistOffsetAchievable(plotCf, plotSize)
		persistTune()
	end

	if not placeZoomTween then
		local pan = Vector3.new(wish.X, 0, wish.Z)
		if pan.Magnitude > 1e-4 then
			local scale = math.clamp(effectiveDist() / PAN_AT_REF_DIST, 0.55, 2.4)
			local keepY = focus.Y
			focus = clampFocus(focus + pan.Unit * (input.panSpeed * scale * dt), plotCf, plotSize)
			-- Place-zoom height follow owns Y — don't let clamp/pan snap it to seat groundY.
			if placeZoomStash and placeZoomFocusYLive ~= nil then
				focus = Vector3.new(focus.X, keepY, focus.Z)
			end
		elseif not (placeZoomStash and placeZoomFocusYLive ~= nil) then
			focus = Vector3.new(focus.X, groundY(plotCf, plotSize), focus.Z)
		end
	end

	stepPlaceZoomTween()
	if placeZoomStash and not placeZoomTween then
		stepPlaceZoomHeightFollow(dt)
	end

	if not placeZoomTween then
		local want = targetDist(plotCf, plotSize)
		if placeZoomStash then
			-- Settled close-up: keep distance glued (no second ease after inbound tween).
			liveDist = want
		else
			local alpha = math.clamp(DIST_TWEEN_RATE * dt, 0, 1)
			liveDist += (want - liveDist) * alpha
		end
	end

	return cameraCFrame(plotCf)
end

return PlotCam2
