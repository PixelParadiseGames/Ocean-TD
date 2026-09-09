--!strict
--[[
	Reef death: 3s Scriptable zoom onto the fish that spent the last heart,
	then callback so WaveSlot can open the Out Of Reef Health popup.
	Camera stays on the defeat pose during the summary; Retry/Continue/Finish must
	call releaseHeldPose() (WaveSim.stop's stopImmediate must NOT cancel that).
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ReefDefeatCam = {}

local ZOOM_SEC = 3
local CAM_DIST = 28
local CAM_HEIGHT = 12

local busy = false
local token = 0
-- True after zoom finishes until Retry/Continue/Finish releases the Scriptable pose.
local holdPose = false
local savedType: Enum.CameraType? = nil
local savedSubject: Instance? = nil
local activeTween: Tween? = nil

local function getPlayerGui(): PlayerGui?
	local plr = Players.LocalPlayer
	return plr and plr:FindFirstChildOfClass("PlayerGui")
end

local function restoreCamera()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local restore = savedType or Enum.CameraType.Custom
	if restore == Enum.CameraType.Scriptable then
		restore = Enum.CameraType.Custom
	end
	cam.CameraType = restore
	if savedSubject and savedSubject.Parent then
		cam.CameraSubject = savedSubject
	else
		local char = Players.LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then
			cam.CameraSubject = hum
		end
	end
	savedType = nil
	savedSubject = nil
end

function ReefDefeatCam.isBusy(): boolean
	return busy
end

function ReefDefeatCam.isHoldingPose(): boolean
	return holdPose
end

-- Summary Retry / Continue / Finish: drop the Scriptable defeat zoom.
function ReefDefeatCam.releaseHeldPose()
	if not holdPose and not busy then
		return
	end
	token += 1
	busy = false
	holdPose = false
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
	local pg = getPlayerGui()
	if pg then
		pg:SetAttribute("OceanTD_ReefDefeatCamBusy", false)
	end
	restoreCamera()
end

-- Cancel an in-flight zoom only. Do NOT clear holdPose — summary still owns the cam.
function ReefDefeatCam.stopImmediate()
	token += 1
	busy = false
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
	local pg = getPlayerGui()
	if pg then
		pg:SetAttribute("OceanTD_ReefDefeatCamBusy", false)
	end
	-- Mid-zoom abort (not yet holding for summary): restore now.
	if not holdPose then
		restoreCamera()
	end
end

local function lookAt(from: Vector3, target: Vector3): CFrame
	return CFrame.lookAt(from, target + Vector3.new(0, 1.5, 0), Vector3.yAxis)
end

local function focusFrom(target: Vector3, look: Vector3): Vector3
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-4 then
		flat = Vector3.new(0, 0, -1)
	else
		flat = flat.Unit
	end
	local side = Vector3.new(-flat.Z, 0, flat.X)
	return target - flat * CAM_DIST + side * (CAM_DIST * 0.18) + Vector3.new(0, CAM_HEIGHT, 0)
end

-- Zoom camera to focus over ZOOM_SEC, then onDone.
function ReefDefeatCam.play(focusPos: Vector3, lookDir: Vector3?, onDone: (() -> ())?)
	if busy or holdPose then
		if onDone then
			onDone()
		end
		return
	end
	token += 1
	local my = token
	busy = true
	holdPose = false

	local pg = getPlayerGui()
	if pg then
		-- Busy before ForceClose so FreeCam can stash fishcam/plotcam for resume.
		pg:SetAttribute("OceanTD_ReefDefeatCamBusy", true)
		pg:SetAttribute("OceanTD_ForceCloseFreeCam", os.clock())
	end

	task.defer(function()
		if my ~= token then
			return
		end
		local cam = Workspace.CurrentCamera
		if not cam then
			busy = false
			if pg then
				pg:SetAttribute("OceanTD_ReefDefeatCamBusy", false)
			end
			if onDone then
				onDone()
			end
			return
		end

		savedType = cam.CameraType
		savedSubject = cam.CameraSubject
		if savedType == Enum.CameraType.Scriptable then
			savedType = Enum.CameraType.Custom
		end
		cam.CameraType = Enum.CameraType.Scriptable

		local look = lookDir or Vector3.new(0, 0, -1)
		local goal = lookAt(focusFrom(focusPos, look), focusPos)
		local tween = TweenService:Create(
			cam,
			TweenInfo.new(ZOOM_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = goal }
		)
		activeTween = tween
		tween:Play()
		tween.Completed:Wait()
		activeTween = nil
		if my ~= token then
			return
		end

		-- Keep Scriptable on the defeat pose for the Out Of Reef Health popup.
		holdPose = true
		busy = false
		if pg and pg.Parent then
			pg:SetAttribute("OceanTD_ReefDefeatCamBusy", false)
		end
		if onDone then
			onDone()
		end
	end)
end

return ReefDefeatCam
