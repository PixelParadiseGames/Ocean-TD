--!strict
--[[
	Reef death: 3s Scriptable zoom onto the reef heart, then GAME OVER + Out Of Reef Health.
	Camera stays on the heart through GAME OVER and the summary; Retry/Continue/Finish must
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
local heldFocus: Vector3? = nil
local heldLook: Vector3? = nil

local function getPlayerGui(): PlayerGui?
	local plr = Players.LocalPlayer
	return plr and plr:FindFirstChildOfClass("PlayerGui")
end

local function setBusyAttr(on: boolean)
	local pg = getPlayerGui()
	if pg then
		pg:SetAttribute("OceanTD_ReefDefeatCamBusy", on)
	end
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
	heldFocus = nil
	heldLook = nil
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
	setBusyAttr(false)
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
	-- Mid-zoom abort (not yet holding for summary): restore now.
	-- While holding the heart for GAME OVER / Out Of Reef Health, keep Scriptable + busy.
	if not holdPose then
		setBusyAttr(false)
		restoreCamera()
	else
		setBusyAttr(true)
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

local function applyFocus(focusPos: Vector3, lookDir: Vector3?)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if not savedType then
		savedType = cam.CameraType
		savedSubject = cam.CameraSubject
		if savedType == Enum.CameraType.Scriptable then
			savedType = Enum.CameraType.Custom
		end
	end
	cam.CameraType = Enum.CameraType.Scriptable
	local look = lookDir or heldLook or Vector3.new(0, 0, -1)
	cam.CFrame = lookAt(focusFrom(focusPos, look), focusPos)
	heldFocus = focusPos
	heldLook = look
	holdPose = true
	setBusyAttr(true)
end

-- Snap/hold Scriptable on a world focus (reef heart during GAME OVER).
function ReefDefeatCam.focusAndHold(focusPos: Vector3, lookDir: Vector3?)
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
	busy = false
	applyFocus(focusPos, lookDir)
	local pg = getPlayerGui()
	if pg then
		pg:SetAttribute("OceanTD_ForceCloseFreeCam", os.clock())
	end
end

-- Re-assert the held heart pose each frame-ish if something nudged the cam.
function ReefDefeatCam.reassertHold()
	if not holdPose or not heldFocus then
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = lookAt(focusFrom(heldFocus, heldLook or Vector3.new(0, 0, -1)), heldFocus)
	setBusyAttr(true)
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
			setBusyAttr(false)
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
		heldFocus = focusPos
		heldLook = look
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

		-- Keep Scriptable on the heart through GAME OVER + Out Of Reef Health.
		holdPose = true
		busy = false
		setBusyAttr(true)
		if onDone then
			onDone()
		end
	end)
end

return ReefDefeatCam
