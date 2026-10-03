--!strict
--[[
	Wave 10 only: zoom camera onto the shark (1s), hold (3s), restore prior
	camera CFrame + mode (3s).

	Owns the camera at RenderPriority.Last+1 for the whole shot so FishCam /
	SkillsAvatarCam / PlayerModule cannot overwrite mid-frame.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local C = require(script.Parent:WaitForChild("WaveSimConsts"))

local SharkCam = {}

local BIND_NAME = "OceanTD_SharkCam"
-- After SkillsAvatarCam (Last) and default Camera — last writer wins.
local BIND_PRIORITY = Enum.RenderPriority.Last.Value + 1
local HOLD_FOLLOW_RATE = 1.1 -- gentle; shark sway shouldn't rattle the frame

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
	if hum and hum.CameraOffset.Magnitude > 1e-4 then
		hum.CameraOffset = Vector3.zero
	end
end

local function smoothstep(u: number): number
	local t = math.clamp(u, 0, 1)
	return t * t * (3 - 2 * t)
end

local function willResumeCycleCam(pg: PlayerGui?): boolean
	if not pg then
		return false
	end
	local m = pg:GetAttribute("OceanTD_CinematicResumeMode")
	return typeof(m) == "string" and m ~= "" and m ~= "off"
end

local function kickOtherCamOwners(pg: PlayerGui?)
	if not pg then
		return
	end
	pg:SetAttribute("OceanTD_ForceCloseFreeCam", os.clock())
	pg:SetAttribute("OceanTD_ForceCloseSkills", os.clock())
	pcall(function()
		local mod = script.Parent:FindFirstChild("SkillsAvatarCam")
		if mod and mod:IsA("ModuleScript") then
			require(mod).releaseForCinematic()
		end
	end)
end

local function finishAndResume(pg: PlayerGui?, cam: Camera?, savedCf: CFrame, savedType: Enum.CameraType, savedSubject: Instance?)
	stopBind()
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
		-- Busy first so FreeCam stashes FishCam instead of restoring Custom.
		pg:SetAttribute("OceanTD_SharkCamBusy", true)
		kickOtherCamOwners(pg)
	end

	task.defer(function()
		if my ~= token then
			return
		end
		-- Let ForceClose* handlers finish before snapshot / bind.
		task.wait()
		if my ~= token then
			return
		end
		if pg then
			-- Second kick in case FishCam / skills re-entered on the wait frame.
			kickOtherCamOwners(pg)
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
		local fromCf = cam.CFrame
		-- Fixed intro goal — don't chase live shark sway during the zoom-in.
		local inGoalCf = lookAtShark(focusOffset(posePos, lockedFlat), posePos)
		local zoomInDur = math.max(0.2, C.SHARK_CAM_ZOOM_IN_SEC)
		local holdDur = math.max(0.2, C.SHARK_CAM_HOLD_SEC)
		local zoomOutDur = math.max(0.2, C.SHARK_CAM_ZOOM_OUT_SEC)
		local phaseT0 = os.clock()
		local phase: "in" | "hold" | "out" = "in"
		local dampPos = posePos
		local holdCf = inGoalCf
		local outFromCf = inGoalCf

		stopBind()
		RunService:BindToRenderStep(BIND_NAME, BIND_PRIORITY, function(dt)
			if my ~= token then
				return
			end
			local c = Workspace.CurrentCamera
			if not c then
				return
			end
			claimCamera(c)

			local elapsed = os.clock() - phaseT0

			if phase == "in" then
				local u = smoothstep(elapsed / zoomInDur)
				c.CFrame = fromCf:Lerp(inGoalCf, u)
				if elapsed >= zoomInDur then
					phase = "hold"
					phaseT0 = os.clock()
					holdCf = inGoalCf
					dampPos = posePos
					c.CFrame = holdCf
				end
			elseif phase == "hold" then
				local p = select(1, getPose())
				if p then
					local a = 1 - math.exp(-HOLD_FOLLOW_RATE * math.max(dt, 0))
					dampPos = dampPos:Lerp(p, a)
				end
				local goalHold = lookAtShark(focusOffset(dampPos, lockedFlat), dampPos)
				local b = 1 - math.exp(-HOLD_FOLLOW_RATE * math.max(dt, 0))
				holdCf = holdCf:Lerp(goalHold, b)
				c.CFrame = holdCf
				if elapsed >= holdDur then
					phase = "out"
					phaseT0 = os.clock()
					outFromCf = c.CFrame
				end
			else
				local u = smoothstep(elapsed / zoomOutDur)
				c.CFrame = outFromCf:Lerp(savedCf, u)
				if elapsed >= zoomOutDur then
					finishAndResume(pg, c, savedCf, savedType, savedSubject)
				end
			end
		end)
	end)
end

return SharkCam
