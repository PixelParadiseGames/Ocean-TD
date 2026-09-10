--!strict
--[[
	Wave 10 only: zoom camera onto the shark (1s), hold (3s), restore prior
	camera CFrame + mode (3s).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local C = require(script.Parent:WaitForChild("WaveSimConsts"))

local SharkCam = {}

local BIND_NAME = "OceanTD_SharkCam"
local FOLLOW_RATE = 2.2

local busy = false
local token = 0

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

function SharkCam.isBusy(): boolean
	return busy
end

function SharkCam.stopImmediate()
	token += 1
	busy = false
	stopBind()
	local pg = getPlayerGui()
	if pg then
		pg:SetAttribute("OceanTD_SharkCamBusy", false)
	end
end

local function flatUnit(look: Vector3): Vector3
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-4 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function lookAtShark(from: Vector3, sharkPos: Vector3): CFrame
	local target = sharkPos + Vector3.new(0, 2, 0)
	return CFrame.lookAt(from, target, Vector3.yAxis)
end

local function focusOffset(sharkPos: Vector3, flatLook: Vector3): Vector3
	local flat = flatUnit(flatLook)
	local side = Vector3.new(-flat.Z, 0, flat.X)
	return sharkPos - flat * C.SHARK_CAM_DIST + side * (C.SHARK_CAM_DIST * 0.22) + Vector3.new(0, C.SHARK_CAM_HEIGHT, 0)
end

local function claimCamera(cam: Camera)
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CameraSubject = nil
	local hum = getHumanoid()
	if hum then
		hum.CameraOffset = Vector3.zero
	end
end

local function willResumeCycleCam(pg: PlayerGui?): boolean
	if not pg then
		return false
	end
	local m = pg:GetAttribute("OceanTD_CinematicResumeMode")
	return typeof(m) == "string" and m ~= "" and m ~= "off"
end

local function finishAndResume(pg: PlayerGui?, cam: Camera?, savedCf: CFrame, savedType: Enum.CameraType, savedSubject: Instance?)
	if cam then
		cam.CFrame = savedCf
	end
	busy = false
	if pg and pg.Parent then
		pg:SetAttribute("OceanTD_SharkCamBusy", false)
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

-- getPose: () -> (position, lookDir)? while shark is alive
function SharkCam.play(getPose: () -> (Vector3?, Vector3?))
	if busy then
		return
	end
	token += 1
	local my = token
	busy = true

	local pg = getPlayerGui()
	if pg then
		pg:SetAttribute("OceanTD_SharkCamBusy", true)
		pg:SetAttribute("OceanTD_ForceCloseFreeCam", os.clock())
	end

	task.defer(function()
		if my ~= token then
			return
		end
		local cam = Workspace.CurrentCamera
		if not cam then
			SharkCam.stopImmediate()
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
		local goalCf = lookAtShark(goalPos, posePos)

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
			local goal = lookAtShark(focusOffset(dampPos, lockedFlat), dampPos)
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
			SharkCam.stopImmediate()
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

return SharkCam
