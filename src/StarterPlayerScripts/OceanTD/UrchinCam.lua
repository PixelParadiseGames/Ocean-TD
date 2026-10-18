--!strict
--[[
	Urchin / crab / shark intro cameras:

	1) play(getPose) — crab first-appear: orbit zoom onto the critter (legacy SharkCam beat).
	2) playPathTour(opts) — focus → soft POV path ride → tween back.
	   Caller pauses the wave for the whole tour; onEnd fires after the restore tween.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local C = require(script.Parent:WaitForChild("WaveSimConsts"))
local FC = require(script.Parent:WaitForChild("FreeCamConfig"))

local UrchinCam = {}

local BIND_NAME = "OceanTD_UrchinCam"
local BIND_PRIORITY = Enum.RenderPriority.Last.Value + 1
local FOLLOW_RATE = 2.2

local busy = false
local token = 0

export type PathTourOpts = {
	sample: (dist: number) -> (Vector3, Vector3),
	-- Path ride span in studs along the route (e.g. W2 → penultimate waypoint).
	startDist: number,
	endDist: number,
	getFocusPose: () -> (Vector3?, Vector3?),
	-- Called when leaving urchin-focus and beginning the path ride (pause wave here).
	onPathBegin: (() -> ())?,
	onEnd: (() -> ())?,
	-- Shark / rollercoaster routes: look toward the next WN (includes pitch) instead of horizon.
	lookNextWaypoint: boolean?,
	waypointDists: { number }?,
	-- Eye height above the path (studs). Shark uses ~2; default keeps urchin POV height.
	pathHeight: number?,
}

local function getPlayerGui(): PlayerGui?
	local plr = Players.LocalPlayer
	return plr and plr:FindFirstChildOfClass("PlayerGui")
end

local function getHumanoid(): Humanoid?
	local char = Players.LocalPlayer.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function stopBind()
	pcall(function()
		RunService:UnbindFromRenderStep(BIND_NAME)
	end)
end

function UrchinCam.isBusy(): boolean
	return busy
end

local function willResumeCycleCam(pg: PlayerGui?): boolean
	if not pg then
		return false
	end
	local m = pg:GetAttribute("OceanTD_CinematicResumeMode")
	return typeof(m) == "string" and m ~= "" and m ~= "off"
end

local pathTourOnEnd: (() -> ())? = nil
local pathTourSavedFov: number? = nil
local pathTourPovActive = false

local function setPathTourPovAttr(on: boolean)
	pathTourPovActive = on == true
	local pg = getPlayerGui()
	if pg then
		pg:SetAttribute(FC.ATTR_PATH_TOUR_POV, pathTourPovActive)
	end
end

function UrchinCam.stopImmediate()
	token += 1
	busy = false
	stopBind()
	setPathTourPovAttr(false)
	local endCb = pathTourOnEnd
	pathTourOnEnd = nil
	local fov = pathTourSavedFov
	pathTourSavedFov = nil
	if endCb then
		pcall(endCb)
	end
	local pg = getPlayerGui()
	local cam = Workspace.CurrentCamera
	if cam and typeof(fov) == "number" then
		cam.FieldOfView = fov
	end
	if pg then
		local resume = willResumeCycleCam(pg)
		pg:SetAttribute("OceanTD_UrchinCamBusy", false)
		if resume then
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

local function lookAtTarget(from: Vector3, targetPos: Vector3): CFrame
	local target = targetPos + Vector3.new(0, 1.2, 0)
	return CFrame.lookAt(from, target, Vector3.yAxis)
end

local function focusOffset(targetPos: Vector3, flatLook: Vector3): Vector3
	local flat = flatUnit(flatLook)
	local side = Vector3.new(-flat.Z, 0, flat.X)
	return targetPos
		+ flat * C.SHARK_CAM_DIST
		+ side * (C.SHARK_CAM_DIST * 0.22)
		+ Vector3.new(0, C.SHARK_CAM_HEIGHT + 10, 0)
end

local function claimCamera(cam: Camera)
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CameraSubject = nil
	local hum = getHumanoid()
	if hum then
		hum.CameraOffset = Vector3.zero
	end
end

local function smoothstep(u: number): number
	local t = math.clamp(u, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Gentler ease than smoothstep — softer accel/decel on path curves.
local function smootherstep(u: number): number
	local t = math.clamp(u, 0, 1)
	return t * t * t * (t * (t * 6 - 15) + 10)
end

local function pathPovCf(pos: Vector3, tang: Vector3): CFrame
	local flat = flatUnit(tang)
	local height = C.URCHIN_POV_HEIGHT or 15
	local back = C.URCHIN_POV_BACK or 6
	local ahead = C.URCHIN_POV_LOOK_AHEAD or 18
	local eye = pos + Vector3.new(0, height, 0) - flat * back
	-- Look along the path, slightly below eye so the line reads without hard pitch snaps.
	local lookAt = pos + flat * ahead + Vector3.new(0, height * 0.55, 0)
	return CFrame.lookAt(eye, lookAt, Vector3.yAxis)
end

-- Rollercoaster-style: eye rides the path; look target includes Y (next WN / ahead sample).
local function pathPovCfLookAt(pos: Vector3, tang: Vector3, lookAt: Vector3, pathHeight: number): CFrame
	local height = math.max(0.25, pathHeight)
	local back = math.min(C.URCHIN_POV_BACK or 6, 4)
	local move = if tang.Magnitude > 1e-4 then tang.Unit else Vector3.new(0, 0, -1)
	local eye = pos + Vector3.new(0, height, 0) - move * back
	local aim = lookAt + Vector3.new(0, height * 0.5, 0)
	if (aim - eye).Magnitude < 0.5 then
		aim = eye + move * 8
	end
	return CFrame.lookAt(eye, aim, Vector3.yAxis)
end

-- First waypoint distance strictly ahead of `dist` (falls back to ride end).
local function nextWaypointDist(dist: number, waypointDists: { number }?, rideEnd: number): number
	if typeof(waypointDists) == "table" then
		for _, wd in ipairs(waypointDists) do
			if typeof(wd) == "number" and wd > dist + 0.75 then
				return math.min(wd, rideEnd)
			end
		end
	end
	return rideEnd
end

local function finishAndResume(
	pg: PlayerGui?,
	cam: Camera?,
	savedCf: CFrame,
	savedType: Enum.CameraType,
	savedSubject: Instance?,
	savedFov: number?
)
	stopBind()
	if cam then
		cam.CFrame = savedCf
		if typeof(savedFov) == "number" then
			cam.FieldOfView = savedFov
		end
	end
	busy = false
	if pg and pg.Parent then
		pg:SetAttribute("OceanTD_UrchinCamBusy", false)
	end
	if willResumeCycleCam(pg) and cam then
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CameraSubject = nil
		if pg then
			pg:SetAttribute("OceanTD_ResumeCinematicCam", os.clock())
		end
		return
	end
	if cam then
		local restore = savedType
		if restore == Enum.CameraType.Scriptable then
			restore = Enum.CameraType.Custom
		end
		cam.CameraType = restore
		if savedSubject and savedSubject.Parent then
			cam.CameraSubject = savedSubject
		else
			local hum = getHumanoid()
			if hum then
				cam.CameraSubject = hum
			end
		end
	end
end

local function kickOtherCamOwners(pg: PlayerGui?)
	if not pg then
		return
	end
	pg:SetAttribute("OceanTD_ForceCloseFreeCam", os.clock())
	pcall(function()
		local mod = script.Parent:FindFirstChild("SkillsAvatarCam")
		if mod and mod:IsA("ModuleScript") then
			require(mod).releaseForCinematic()
		end
	end)
end

local function urchinFocusCf(pos: Vector3, tang: Vector3): CFrame
	local flat = flatUnit(tang)
	return lookAtTarget(focusOffset(pos, flat), pos)
end

-- First urchin: focus on entry → tween down to path POV → soft path fly → restore.
function UrchinCam.playPathTour(opts: PathTourOpts)
	if busy then
		return
	end
	token += 1
	local my = token
	busy = true

	local sample = opts.sample
	local getFocusPose = opts.getFocusPose
	local rideStartDist = math.max(0, opts.startDist)
	local rideEndDist = math.max(rideStartDist + 1, opts.endDist)
	local lookNextWaypoint = opts.lookNextWaypoint == true
	local waypointDists = opts.waypointDists
	local pathHeight = if typeof(opts.pathHeight) == "number" then opts.pathHeight :: number else (C.URCHIN_POV_HEIGHT or 15)
	local focusInSec = math.max(0.2, C.URCHIN_POV_FOCUS_IN_SEC or 0.85)
	local focusHoldSec = math.max(0.2, C.URCHIN_POV_FOCUS_SEC or 3)
	local tweenOutSec = math.max(0.2, C.URCHIN_POV_TWEEN_OUT_SEC or 1.1)
	local pathSec = math.max(0.5, C.URCHIN_POV_PATH_SEC or 10)
	local followRate = math.max(0.5, C.URCHIN_POV_FOLLOW_RATE or 2.4)
	local lookRate = math.max(0.5, (C.URCHIN_POV_FOLLOW_RATE or 2.4) * 0.85)
	local fovMult = math.max(1, C.URCHIN_POV_FOV_MULT or 1.2)

	-- Snapshot the player's live seat BEFORE ForceClose so restore matches their view.
	local preCam = Workspace.CurrentCamera
	local savedCf = if preCam then preCam.CFrame else CFrame.new()
	local savedType = if preCam then preCam.CameraType else Enum.CameraType.Custom
	local savedSubject = if preCam then preCam.CameraSubject else nil
	local savedFov = if preCam then preCam.FieldOfView else 70
	local wideFov = math.clamp(savedFov * fovMult, 20, 120)

	local pg = getPlayerGui()
	if pg then
		pg:SetAttribute("OceanTD_UrchinCamBusy", true)
		kickOtherCamOwners(pg)
	end
	pathTourOnEnd = opts.onEnd
	pathTourSavedFov = savedFov

	local function finishTour(cam: Camera?)
		stopBind()
		pathTourSavedFov = nil
		setPathTourPovAttr(false)
		finishAndResume(pg, cam, savedCf, savedType, savedSubject, savedFov)
		local endCb = pathTourOnEnd
		pathTourOnEnd = nil
		if endCb then
			pcall(endCb)
		end
	end

	task.spawn(function()
		if my ~= token then
			return
		end
		task.wait()
		if my ~= token then
			return
		end

		local cam = Workspace.CurrentCamera
		if not cam then
			UrchinCam.stopImmediate()
			return
		end

		claimCamera(cam)
		cam.FieldOfView = savedFov

		local focusPos, focusTang = getFocusPose()
		if not focusPos then
			finishTour(cam)
			return
		end
		local lockedFlat = flatUnit(focusTang or Vector3.new(0, 0, -1))
		local focusGoal = urchinFocusCf(focusPos, lockedFlat)

		-- focusIn → focus (3s) → path (seamless from W3) → out
		local phase: "focusIn" | "focus" | "path" | "out" | "done" = "focusIn"
		local phaseT0 = os.clock()
		local fromCf = savedCf
		local toCf = focusGoal
		local dampCf = savedCf
		local dampFov = savedFov
		local dampTang = lockedFlat
		local dampPos = focusPos
		local dampLookAt = focusPos + lockedFlat * (C.URCHIN_POV_LOOK_AHEAD or 18)
		local startDist = rideStartDist
		local endDist = rideEndDist
		local pathBegun = false

		stopBind()
		RunService:BindToRenderStep(BIND_NAME, BIND_PRIORITY, function(dt)
			if my ~= token or phase == "done" then
				return
			end
			local c = Workspace.CurrentCamera
			if not c then
				return
			end
			claimCamera(c)
			local elapsed = os.clock() - phaseT0
			local a = 1 - math.exp(-followRate * math.max(dt, 0))

			if phase == "focusIn" then
				local livePos, liveTang = getFocusPose()
				if livePos then
					dampPos = dampPos:Lerp(livePos, a)
					lockedFlat = flatUnit(liveTang or lockedFlat)
					toCf = urchinFocusCf(dampPos, lockedFlat)
				end
				local u = smootherstep(elapsed / focusInSec)
				local goal = fromCf:Lerp(toCf, u)
				dampCf = dampCf:Lerp(goal, math.max(a, u))
				c.CFrame = dampCf
				c.FieldOfView = savedFov
				if elapsed >= focusInSec then
					phase = "focus"
					phaseT0 = os.clock()
					dampCf = toCf
					c.CFrame = dampCf
				end
				return
			end

			if phase == "focus" then
				local livePos, liveTang = getFocusPose()
				if livePos then
					dampPos = dampPos:Lerp(livePos, a)
					lockedFlat = flatUnit(liveTang or lockedFlat)
				end
				local goal = urchinFocusCf(dampPos, lockedFlat)
				dampCf = dampCf:Lerp(goal, a)
				c.CFrame = dampCf
				c.FieldOfView = savedFov
				if elapsed >= focusHoldSec then
					-- Seamless handoff: keep current dampCf and start riding from W3.
					startDist = rideStartDist
					endDist = rideEndDist
					local p0, t0 = sample(startDist)
					-- Seed path damp toward W3 without snapping the lens.
					dampPos = dampPos:Lerp(p0, 0.35)
					if lookNextWaypoint then
						dampTang = dampTang:Lerp(if t0.Magnitude > 1e-4 then t0.Unit else lockedFlat, 0.35)
						local lookD = nextWaypointDist(startDist, waypointDists, endDist)
						local lookPos = sample(lookD)
						dampLookAt = dampLookAt:Lerp(lookPos, 0.35)
					else
						dampTang = dampTang:Lerp(flatUnit(t0), 0.35)
					end
					if dampTang.Magnitude > 1e-4 then
						dampTang = dampTang.Unit
					end
					phase = "path"
					phaseT0 = os.clock()
					-- Shark/urchin path tour: fade near ribbon segments like Fish Cam POV.
					setPathTourPovAttr(true)
					if not pathBegun then
						pathBegun = true
						if opts.onPathBegin then
							pcall(opts.onPathBegin)
						end
					end
				end
				return
			end

			if phase == "path" then
				local u = math.clamp(elapsed / pathSec, 0, 1)
				local pathU = smootherstep(u)
				local dist = startDist + (endDist - startDist) * pathU
				local pos, tang = sample(dist)
				local lookA = 1 - math.exp(-lookRate * math.max(dt, 0))
				dampPos = dampPos:Lerp(pos, a)
				local goal: CFrame
				if lookNextWaypoint then
					local move = if tang.Magnitude > 1e-4 then tang.Unit else dampTang
					dampTang = dampTang:Lerp(move, a)
					if dampTang.Magnitude > 1e-4 then
						dampTang = dampTang.Unit
					end
					-- Aim at the next WN so downhill pitch follows the drop (not the horizon).
					local lookD = nextWaypointDist(dist, waypointDists, endDist)
					local lookPos = sample(lookD)
					dampLookAt = dampLookAt:Lerp(lookPos, lookA)
					goal = pathPovCfLookAt(dampPos, dampTang, dampLookAt, pathHeight)
				else
					local flat = flatUnit(tang)
					dampTang = dampTang:Lerp(flat, a)
					if dampTang.Magnitude > 1e-4 then
						dampTang = dampTang.Unit
					end
					goal = pathPovCf(dampPos, dampTang)
				end
				dampCf = dampCf:Lerp(goal, a)
				-- Widen FOV as we settle into the path ride (no hard FOV cut).
				local fovBlend = math.min(1, elapsed / 1.2)
				local wantFov = savedFov + (wideFov - savedFov) * smootherstep(fovBlend)
				dampFov = dampFov + (wantFov - dampFov) * a
				c.CFrame = dampCf
				c.FieldOfView = dampFov
				if elapsed >= pathSec then
					phase = "out"
					phaseT0 = os.clock()
					fromCf = dampCf
					toCf = savedCf
					-- Keep wave paused until out tween finishes (onEnd in finishTour).
				end
				return
			end

			-- out: return to the player's starting perspective + FOV
			local u = smootherstep(elapsed / tweenOutSec)
			local goal = fromCf:Lerp(toCf, u)
			dampCf = dampCf:Lerp(goal, math.max(a, u))
			dampFov = wideFov + (savedFov - wideFov) * u
			c.CFrame = dampCf
			c.FieldOfView = dampFov
			if elapsed >= tweenOutSec then
				phase = "done"
				c.CFrame = savedCf
				c.FieldOfView = savedFov
				task.defer(function()
					if my ~= token then
						return
					end
					-- onEnd fires here after cam has fully restored (wave can unpause).
					finishTour(Workspace.CurrentCamera)
				end)
			end
		end)
	end)
end

-- getPose: () -> (position, lookDir)? — crab intro orbit zoom (unchanged beat).
function UrchinCam.play(getPose: () -> (Vector3?, Vector3?))
	if busy then
		return
	end
	token += 1
	local my = token
	busy = true

	local pg = getPlayerGui()
	if pg then
		pg:SetAttribute("OceanTD_UrchinCamBusy", true)
		pg:SetAttribute("OceanTD_ForceCloseFreeCam", os.clock())
	end

	task.defer(function()
		if my ~= token then
			return
		end
		local cam = Workspace.CurrentCamera
		if not cam then
			UrchinCam.stopImmediate()
			return
		end

		local savedCf = cam.CFrame
		local savedType = cam.CameraType
		local savedSubject = cam.CameraSubject
		if savedType == Enum.CameraType.Scriptable then
			savedType = Enum.CameraType.Custom
		end

		claimCamera(cam)

		local posePos, poseLook = getPose()
		if not posePos then
			finishAndResume(pg, cam, savedCf, savedType, savedSubject)
			return
		end
		local lockedFlat = flatUnit(poseLook or Vector3.new(0, 0, -1))
		local goalPos = focusOffset(posePos, lockedFlat)
		local goalCf = lookAtTarget(goalPos, posePos)

		local tweenIn = TweenService:Create(
			cam,
			TweenInfo.new(C.SHARK_CAM_ZOOM_IN_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = goalCf }
		)
		tweenIn:Play()
		tweenIn.Completed:Wait()
		if my ~= token then
			return
		end

		local holdEnd = os.clock() + C.SHARK_CAM_HOLD_SEC
		local dampPos = posePos
		local dampCf = Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame or goalCf
		stopBind()
		RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
			if my ~= token then
				return
			end
			local c = Workspace.CurrentCamera
			if not c then
				return
			end
			claimCamera(c)
			local p = select(1, getPose())
			if p then
				local a = 1 - math.exp(-FOLLOW_RATE * math.max(dt, 0))
				dampPos = dampPos:Lerp(p, a)
			end
			local goal = lookAtTarget(focusOffset(dampPos, lockedFlat), dampPos)
			local b = 1 - math.exp(-FOLLOW_RATE * math.max(dt, 0))
			dampCf = dampCf:Lerp(goal, b)
			c.CFrame = dampCf
		end)

		while os.clock() < holdEnd and my == token do
			task.wait(0.05)
		end
		stopBind()
		if my ~= token then
			return
		end

		local c2 = Workspace.CurrentCamera
		if not c2 then
			UrchinCam.stopImmediate()
			return
		end
		claimCamera(c2)
		local tweenOut = TweenService:Create(
			c2,
			TweenInfo.new(C.SHARK_CAM_ZOOM_OUT_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ CFrame = savedCf }
		)
		tweenOut:Play()
		tweenOut.Completed:Wait()
		if my ~= token then
			return
		end

		finishAndResume(pg, Workspace.CurrentCamera, savedCf, savedType, savedSubject)
	end)
end

return UrchinCam
