--!strict
--[[
	Wave 1 only:
	1) Tween to near-center overview (path + heart) — Fish Cam stays selected (UI/lock)
	2) ~1s before fish spawn: brief blend toward the path start / fish
	3) Hand camera back to Fish Cam cycle (aim crosshair / follow)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local C = require(script.Parent:WaitForChild("WaveSimConsts"))

local TangCam = {}

export type PlayArgs = {
	getPathLen: () -> number,
	samplePath: (dist: number) -> Vector3?,
	getHeartPos: () -> Vector3?,
	getArenaCenter: () -> Vector3?,
	haveFishStarted: () -> boolean,
	getFishPositions: () -> { Vector3 },
	areFishFed: () -> boolean,
}

local busy = false
local token = 0
local conn: RBXScriptConnection? = nil

local function getPlayerGui(): PlayerGui?
	local plr = Players.LocalPlayer
	return plr and plr:FindFirstChildOfClass("PlayerGui")
end

local function stopConn()
	if conn then
		conn:Disconnect()
		conn = nil
	end
end

local function willResumeCycleCam(pg: PlayerGui?): boolean
	if not pg then
		return false
	end
	local m = pg:GetAttribute("OceanTD_CinematicResumeMode")
	return typeof(m) == "string" and m ~= "" and m ~= "off"
end

function TangCam.isBusy(): boolean
	return busy
end

function TangCam.stopImmediate()
	token += 1
	busy = false
	stopConn()
	local pg = getPlayerGui()
	if pg then
		local resume = willResumeCycleCam(pg)
		pg:SetAttribute("OceanTD_TangCamBusy", false)
		-- Waves stopped mid-shot: hand camera back to Plot/Fish/Drone stash.
		if resume then
			local cam = Workspace.CurrentCamera
			if cam then
				cam.CameraType = Enum.CameraType.Scriptable
				cam.CameraSubject = nil
			end
			pg:SetAttribute("OceanTD_ResumeCinematicCam", os.clock())
		end
	end
end

local function flatUnit(look: Vector3): Vector3
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-4 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function getHumanoid(): Humanoid?
	local char = Players.LocalPlayer.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function collectFocusPoints(args: PlayArgs, includeFish: boolean): { Vector3 }
	local points: { Vector3 } = {}
	local pathLen = math.max(0, args.getPathLen())
	local step = math.max(8, C.TANG_CAM_OVERVIEW_SAMPLE_STEP)
	if pathLen > 0 then
		local d = 0
		while d <= pathLen do
			local p = args.samplePath(d)
			if p then
				table.insert(points, p)
			end
			if d >= pathLen then
				break
			end
			d = math.min(pathLen, d + step)
		end
	end
	local heart = args.getHeartPos()
	if heart then
		table.insert(points, heart)
	end
	if includeFish then
		for _, p in ipairs(args.getFishPositions()) do
			table.insert(points, p)
		end
	end
	return points
end

local function computeOverviewCFrame(
	points: { Vector3 },
	arenaCenter: Vector3?,
	zoomOut: boolean?,
	heartPos: Vector3?
): CFrame?
	if #points < 1 then
		return nil
	end
	local minV = points[1]
	local maxV = points[1]
	for i = 2, #points do
		local p = points[i]
		minV = Vector3.new(math.min(minV.X, p.X), math.min(minV.Y, p.Y), math.min(minV.Z, p.Z))
		maxV = Vector3.new(math.max(maxV.X, p.X), math.max(maxV.Y, p.Y), math.max(maxV.Z, p.Z))
	end
	local pathCenter = (minV + maxV) * 0.5
	local extents = (maxV - minV) * 0.5
	local radius = math.max(extents.X, extents.Y, extents.Z, 20)

	local pathStart = points[1]
	local heart = heartPos or points[#points]
	local pivot = arenaCenter or pathStart
	local lookFlat = flatUnit(heart - pivot)
	if (heart - pathStart).Magnitude > 1e-3 then
		lookFlat = flatUnit(heart - pathStart)
	end

	local cam = Workspace.CurrentCamera
	local fov = if cam then math.rad(math.clamp(cam.FieldOfView, 20, 90)) else math.rad(70)
	local pad = C.TANG_CAM_OVERVIEW_PAD * (if zoomOut then C.TANG_CAM_OVERVIEW_FISH_PAD_MULT else 1)
	local fitDist = math.max(C.TANG_CAM_OVERVIEW_MIN_DIST, (radius * pad) / math.tan(fov * 0.5))
	local height = C.TANG_CAM_OVERVIEW_HEIGHT * (if zoomOut then C.TANG_CAM_OVERVIEW_FISH_HEIGHT_MULT else 1)

	-- Sit near arena center (slightly toward path start), elevated — not far outside looking in.
	local back = math.clamp(fitDist * (if zoomOut then 0.22 else 0.12), 6, if zoomOut then 48 else 28)
	local from = pivot - lookFlat * back + Vector3.new(0, height, 0)
	local lookAt = pathCenter:Lerp(heart, 0.35) + Vector3.new(0, extents.Y * 0.1, 0)

	local toHeart = heart - from
	local along = toHeart:Dot(lookFlat)
	if along > 1 then
		local need = (radius * pad) / math.tan(fov * 0.5)
		local extra = math.max(0, need - along)
		if extra > 0 then
			from = from - lookFlat * math.min(extra, fitDist * (if zoomOut then 0.5 else 0.35))
		end
	end

	return CFrame.lookAt(from, lookAt, Vector3.yAxis)
end

-- Behind the fish, looking toward the heart: fish foreground, heart background (no 180° spin).
local function computeFishFocusCFrame(
	fishPts: { Vector3 },
	_arenaCenter: Vector3?,
	pathStart: Vector3?,
	heartPos: Vector3?
): CFrame?
	if #fishPts < 1 then
		return nil
	end
	local minV = fishPts[1]
	local maxV = fishPts[1]
	local sum = fishPts[1]
	for i = 2, #fishPts do
		local p = fishPts[i]
		minV = Vector3.new(math.min(minV.X, p.X), math.min(minV.Y, p.Y), math.min(minV.Z, p.Z))
		maxV = Vector3.new(math.max(maxV.X, p.X), math.max(maxV.Y, p.Y), math.max(maxV.Z, p.Z))
		sum += p
	end
	local fishCenter = sum / #fishPts
	local extents = (maxV - minV) * 0.5
	local radius = math.max(extents.X, extents.Y, extents.Z, 14)

	local heart = heartPos
	if not heart and pathStart then
		-- Fallback: keep looking along start→fish if heart missing.
		heart = fishCenter + flatUnit(fishCenter - pathStart) * 80
	end
	if not heart then
		heart = fishCenter + Vector3.new(0, 0, -80)
	end

	-- Same facing as overview: toward the reef heart.
	local lookFlat = flatUnit(heart - fishCenter)
	if lookFlat.Magnitude < 1e-4 and pathStart then
		lookFlat = flatUnit(heart - pathStart)
	end

	local cam = Workspace.CurrentCamera
	local fov = if cam then math.rad(math.clamp(cam.FieldOfView, 20, 90)) else math.rad(70)
	local pad = C.TANG_CAM_OVERVIEW_PAD * C.TANG_CAM_OVERVIEW_FISH_PAD_MULT
	local fitDist = math.max(C.TANG_CAM_FISH_FOCUS_MIN_DIST, (radius * pad) / math.tan(fov * 0.5))
	local height = C.TANG_CAM_FISH_FOCUS_HEIGHT
	-- Sit behind the school on XZ (not between fish and heart).
	local back = math.clamp(fitDist * 0.85, C.TANG_CAM_FISH_FOCUS_BACK_MIN, C.TANG_CAM_FISH_FOCUS_BACK_MAX)
	local from = fishCenter - lookFlat * back + Vector3.new(0, height, 0)
	-- Aim near the fish (mid-screen); slight blend keeps the heart in the distant background.
	local lookAt = fishCenter:Lerp(heart, C.TANG_CAM_FISH_FOCUS_LOOK_BLEND)
		+ Vector3.new(0, C.TANG_CAM_FISH_FOCUS_LOOK_Y, 0)

	return CFrame.lookAt(from, lookAt, Vector3.yAxis)
end

local function waitWhile(my: number, pred: () -> boolean)
	while my == token and pred() do
		task.wait(0.05)
	end
end

function TangCam.play(args: PlayArgs)
	if busy then
		return
	end
	token += 1
	local my = token
	busy = true

	local pg = getPlayerGui()
	if pg then
		-- Pause FreeCam writes while overview runs; keep CamCycleMode (Fish Cam) for UI/lock/crosshair.
		pg:SetAttribute("OceanTD_TangCamBusy", true)
		-- Re-stamp Fish Cam after busy so ForceCamMode applies even if the string was already "fishcam".
		pg:SetAttribute("OceanTD_ForceCamMode", "fishcam")
		pg:SetAttribute("OceanTD_ForceCamStamp", os.clock())
	end

	task.defer(function()
		if my ~= token then
			return
		end
		local cam = Workspace.CurrentCamera
		if not cam then
			TangCam.stopImmediate()
			return
		end

		-- Clear humanoid offset so nothing fights Scriptable (Wave1FishCam is unused; avoid require cycle via WaveSim).
		do
			local hum = getHumanoid()
			if hum then
				hum.CameraOffset = Vector3.zero
			end
		end

		local overviewCf = computeOverviewCFrame(
			collectFocusPoints(args, false),
			args.getArenaCenter(),
			false,
			args.getHeartPos()
		)
		if not overviewCf then
			TangCam.stopImmediate()
			return
		end

		cam.CameraType = Enum.CameraType.Scriptable
		cam.CameraSubject = nil
		local tweenIn = TweenService:Create(
			cam,
			TweenInfo.new(C.TANG_CAM_OVERVIEW_ZOOM_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = overviewCf }
		)
		tweenIn:Play()
		tweenIn.Completed:Wait()
		if my ~= token then
			return
		end

		-- Hold near-center overview until fish are about to spawn (lead) or swimming.
		waitWhile(my, function()
			return not args.haveFishStarted()
		end)
		if my ~= token then
			return
		end

		-- Brief blend toward fish, then hand the camera back to Fish Cam cycle (full UI/lock/aim).
		local pathStart = args.samplePath(0)
		local cFish = Workspace.CurrentCamera
		if not cFish then
			TangCam.stopImmediate()
			return
		end
		cFish.CameraType = Enum.CameraType.Scriptable
		cFish.CameraSubject = nil
		local blendStartCf = cFish.CFrame
		local blendT0 = os.clock()
		local blendDur = math.max(0.4, C.TANG_CAM_OVERVIEW_FISH_ZOOM_SEC)
		local followRate = C.TANG_CAM_FISH_FOCUS_FOLLOW_RATE
		local dampGoal: CFrame? = nil

		stopConn()
		conn = RunService.RenderStepped:Connect(function(dt)
			if my ~= token then
				return
			end
			local c = Workspace.CurrentCamera
			if not c then
				return
			end
			if c.CameraType ~= Enum.CameraType.Scriptable then
				c.CameraType = Enum.CameraType.Scriptable
			end
			c.CameraSubject = nil
			local pts = args.getFishPositions()
			if #pts < 1 and pathStart then
				pts = { pathStart }
			end
			local goal = computeFishFocusCFrame(pts, args.getArenaCenter(), pathStart, args.getHeartPos())
			if not goal then
				return
			end
			if not dampGoal then
				dampGoal = goal
			else
				local ga = 1 - math.exp(-followRate * 0.85 * math.max(dt, 0))
				dampGoal = dampGoal:Lerp(goal, ga)
			end
			local u = math.clamp((os.clock() - blendT0) / blendDur, 0, 1)
			local e = u * u * (3 - 2 * u)
			c.CFrame = blendStartCf:Lerp(dampGoal :: CFrame, e)
		end)

		waitWhile(my, function()
			return (os.clock() - blendT0) < blendDur
		end)
		stopConn()
		if my ~= token then
			return
		end

		busy = false
		if pg and pg.Parent then
			pg:SetAttribute("OceanTD_TangCamBusy", false)
			pg:SetAttribute("OceanTD_ForceCamMode", "fishcam")
			pg:SetAttribute("OceanTD_ForceCamStamp", os.clock())
		end
	end)
end

return TangCam
