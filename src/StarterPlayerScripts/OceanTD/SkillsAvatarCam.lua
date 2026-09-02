--!strict
--[[
	While skills bubbles are open: Scriptable camera zooms on the local avatar in the
	left third of the screen (humanoid fills vertically). Avatar spins to face the
	camera on open, then spins back on close. Restores prior camera mode after.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SkillsAvatarCam = {}

local CAM_CYCLE_ATTR = "OceanTD_CamCycleMode"
local SKILLS_OPEN_ATTR = "OceanTD_SkillsBubblesOpen"
local CINEMATIC_BUSY_ATTR = "OceanTD_PlotSizeCinematicBusy"
local RENDER_STEP = "OceanTD_SkillsAvatarCam"

local TWEEN_IN_SEC = 0.4
local TWEEN_OUT_SEC = 0.45
local TURN_SEC = 0.35
local VERTICAL_FILL = 0.88
local LEFT_THIRD_CENTER = 1 / 6

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local active = false
local token = 0
local renderBound = false
local attrBound = false

local savedCamType: Enum.CameraType? = nil
local savedCf: CFrame? = nil
local savedSubject: Instance? = nil
local savedCamCycleMode: string? = nil

local savedHrpCf: CFrame? = nil
local savedAutoRotate: boolean? = nil
local faceYaw: number? = nil

local lockedYaw = 0
local lockedDist = 8

local function getCamera(): Camera?
	return Workspace.CurrentCamera
end

local function getCharacter(): Model?
	local char = player.Character
	if char and char:IsA("Model") then
		return char
	end
	return nil
end

local function getHrp(char: Model?): BasePart?
	if not char then
		return nil
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function getHumanoid(char: Model?): Humanoid?
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function yawFromFlat(dir: Vector3): number
	return math.atan2(-dir.X, -dir.Z)
end

local function flatLookCFrame(pos: Vector3, yaw: number): CFrame
	return CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
end

local function shouldSkip(): boolean
	if playerGui:GetAttribute(CINEMATIC_BUSY_ATTR) == true then
		return true
	end
	local okPlace, PlacementController = pcall(function()
		return require(script.Parent:WaitForChild("PlacementController"))
	end)
	local okRel, RelocateController = pcall(function()
		return require(script.Parent:WaitForChild("RelocateController"))
	end)
	if okPlace and PlacementController.isActive() then
		return true
	end
	if okRel and RelocateController.isActive() then
		return true
	end
	return false
end

local function avatarFocus(char: Model): (Vector3, number)
	local head = char:FindFirstChild("Head")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	local height = 5
	if hum then
		height = math.max(hum.HipHeight * 2 + 2, 4.5)
	end
	local focus: Vector3
	if head and head:IsA("BasePart") and hrp and hrp:IsA("BasePart") then
		focus = (head.Position + hrp.Position) * 0.5
		height = math.max(height, (head.Position - hrp.Position).Magnitude + 2.5)
	elseif hrp and hrp:IsA("BasePart") then
		focus = hrp.Position + Vector3.new(0, 1.2, 0)
	else
		focus = char:GetPivot().Position
	end
	return focus, height
end

local function frameCFrame(focus: Vector3, height: number, yaw: number, dist: number, fovDeg: number, aspect: number): CFrame
	local flat = Vector3.new(math.sin(yaw), 0, math.cos(yaw))
	local pos = focus + flat * dist + Vector3.new(0, height * 0.05, 0)
	local lookAt = focus + Vector3.new(0, height * 0.02, 0)
	local centered = CFrame.lookAt(pos, lookAt)
	local targetNdcX = LEFT_THIRD_CENTER * 2 - 1
	local halfH = math.tan(math.rad(fovDeg * 0.5)) * aspect
	local yawBias = math.atan(targetNdcX * halfH)
	return centered * CFrame.Angles(0, yawBias, 0)
end

local function solveFrame(fromCf: CFrame, char: Model): CFrame
	local cam = getCamera()
	local fov = if cam then cam.FieldOfView else 70
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local aspect = vp.X / math.max(vp.Y, 1)
	local focus, height = avatarFocus(char)

	local delta = fromCf.Position - focus
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude > 0.35 then
		lockedYaw = math.atan2(flat.X, flat.Z)
	else
		local hrp = getHrp(char)
		if hrp then
			lockedYaw = yawFromFlat(hrp.CFrame.LookVector)
		else
			lockedYaw = 0
		end
	end

	local halfFov = math.rad(fov * 0.5)
	lockedDist = (height * 0.5) / (math.tan(halfFov) * VERTICAL_FILL)
	lockedDist = math.clamp(lockedDist, 3.5, 18)

	return frameCFrame(focus, height, lockedYaw, lockedDist, fov, aspect)
end

local function goalFromLocked(char: Model): CFrame
	local cam = getCamera()
	local fov = if cam then cam.FieldOfView else 70
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local aspect = vp.X / math.max(vp.Y, 1)
	local focus, height = avatarFocus(char)
	return frameCFrame(focus, height, lockedYaw, lockedDist, fov, aspect)
end

local function lockAutoRotate(char: Model)
	local hum = getHumanoid(char)
	if hum and savedAutoRotate == nil then
		savedAutoRotate = hum.AutoRotate
		hum.AutoRotate = false
	end
end

local function unlockAutoRotate(char: Model?)
	local hum = getHumanoid(char)
	if hum and savedAutoRotate ~= nil then
		hum.AutoRotate = savedAutoRotate
	end
	savedAutoRotate = nil
end

local function faceYawTowardCamera(camPos: Vector3, hrpPos: Vector3): number?
	local flat = Vector3.new(camPos.X - hrpPos.X, 0, camPos.Z - hrpPos.Z)
	if flat.Magnitude < 0.05 then
		return nil
	end
	return yawFromFlat(flat.Unit)
end

local function applyHrpYaw(hrp: BasePart, yaw: number)
	local pos = hrp.Position
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	hrp.CFrame = flatLookCFrame(pos, yaw)
end

local function tweenAvatarYaw(toYaw: number, duration: number, my: number): boolean
	local char = getCharacter()
	local hrp = getHrp(char)
	if not hrp then
		return false
	end
	lockAutoRotate(char :: Model)
	local startYaw = yawFromFlat(hrp.CFrame.LookVector)
	-- Shortest turn
	local delta = (toYaw - startYaw + math.pi) % (math.pi * 2) - math.pi
	local t0 = os.clock()
	while os.clock() - t0 < duration do
		if my ~= token then
			return false
		end
		local live = getHrp(getCharacter())
		if not live then
			return false
		end
		local u = math.clamp((os.clock() - t0) / duration, 0, 1)
		local e = u * u * (3 - 2 * u)
		applyHrpYaw(live, startYaw + delta * e)
		RunService.RenderStepped:Wait()
	end
	if my == token then
		local live = getHrp(getCharacter())
		if live then
			applyHrpYaw(live, toYaw)
		end
	end
	return my == token
end

local function holdAvatarFacing(cam: Camera)
	local hrp = getHrp(getCharacter())
	if not hrp then
		return
	end
	local yaw = faceYaw
	if yaw == nil then
		yaw = faceYawTowardCamera(cam.CFrame.Position, hrp.Position)
		faceYaw = yaw
	end
	if yaw ~= nil then
		applyHrpYaw(hrp, yaw)
	end
end

local function unbindRender()
	if renderBound then
		pcall(function()
			RunService:UnbindFromRenderStep(RENDER_STEP)
		end)
		renderBound = false
	end
end

local function tweenCameraTo(goal: CFrame, duration: number, my: number): boolean
	local cam = getCamera()
	if not cam then
		return false
	end
	local start = cam.CFrame
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CameraSubject = nil
	local t0 = os.clock()
	while os.clock() - t0 < duration do
		if my ~= token then
			return false
		end
		local u = math.clamp((os.clock() - t0) / duration, 0, 1)
		local e = u * u * (3 - 2 * u)
		local c = getCamera()
		if not c then
			return false
		end
		c.CameraType = Enum.CameraType.Scriptable
		c.CameraSubject = nil
		c.CFrame = start:Lerp(goal, e)
		RunService.RenderStepped:Wait()
	end
	if my == token then
		local c = getCamera()
		if c then
			c.CameraType = Enum.CameraType.Scriptable
			c.CameraSubject = nil
			c.CFrame = goal
		end
	end
	return my == token
end

local function restoreSavedCamera()
	local cam = getCamera()
	if not cam then
		return
	end
	local char = getCharacter()
	local hum = getHumanoid(char)
	local cycle = savedCamCycleMode
	if savedSubject and savedSubject.Parent then
		cam.CameraSubject = savedSubject
	elseif hum then
		cam.CameraSubject = hum
	end
	if cycle == "plotcam" or cycle == "fishcam" or cycle == "dronecam" or cycle == "freecam" then
		cam.CameraType = Enum.CameraType.Scriptable
		if savedCf then
			cam.CFrame = savedCf
		end
		playerGui:SetAttribute("OceanTD_SyncCamCycleFromView", os.clock())
	else
		local restore = savedCamType or Enum.CameraType.Custom
		if restore == Enum.CameraType.Scriptable then
			restore = Enum.CameraType.Custom
		end
		cam.CameraType = restore
		playerGui:SetAttribute("OceanTD_RestoreWaveCam", os.clock())
	end
end

local function restoreAvatarFacing(my: number)
	local saved = savedHrpCf
	if not saved then
		unlockAutoRotate(getCharacter())
		faceYaw = nil
		return
	end
	local restoreYaw = yawFromFlat(saved.LookVector)
	tweenAvatarYaw(restoreYaw, TURN_SEC, my)
	local hrp = getHrp(getCharacter())
	if hrp and my == token then
		-- Keep position (may have shifted slightly); restore original facing only.
		applyHrpYaw(hrp, restoreYaw)
	end
	unlockAutoRotate(getCharacter())
	savedHrpCf = nil
	faceYaw = nil
end

function SkillsAvatarCam.isActive(): boolean
	return active
end

-- Drop avatar-cam ownership immediately (no restore tween) so a cinematic can take the camera.
function SkillsAvatarCam.releaseForCinematic()
	if not active then
		-- Still cancel any in-flight stop tween that would fight the cinematic.
		token += 1
		unbindRender()
		return
	end
	token += 1
	active = false
	unbindRender()
	local char = getCharacter()
	unlockAutoRotate(char)
	-- Snap facing back without a long turn so the plot cinematic can start cleanly.
	local saved = savedHrpCf
	local hrp = getHrp(char)
	if hrp and saved then
		applyHrpYaw(hrp, yawFromFlat(saved.LookVector))
	end
	savedCamType = nil
	savedCf = nil
	savedSubject = nil
	savedCamCycleMode = nil
	savedHrpCf = nil
	faceYaw = nil
end

function SkillsAvatarCam.stop()
	if not active then
		return
	end
	token += 1
	local my = token
	active = false
	unbindRender()

	local goal = savedCf
	task.spawn(function()
		-- Spin avatar back while camera returns.
		task.spawn(function()
			restoreAvatarFacing(my)
		end)
		if goal then
			tweenCameraTo(goal, TWEEN_OUT_SEC, my)
		end
		if my == token then
			restoreSavedCamera()
		end
		savedCamType = nil
		savedCf = nil
		savedSubject = nil
		savedCamCycleMode = nil
	end)
end

function SkillsAvatarCam.start()
	if active then
		return
	end
	if shouldSkip() then
		return
	end
	local cam = getCamera()
	local char = getCharacter()
	local hrp = getHrp(char)
	if not cam or not char or not hrp then
		return
	end

	token += 1
	local my = token
	active = true

	savedCamType = cam.CameraType
	savedCf = cam.CFrame
	savedSubject = cam.CameraSubject
	savedCamCycleMode = playerGui:GetAttribute(CAM_CYCLE_ATTR) :: string?
	savedHrpCf = hrp.CFrame
	faceYaw = nil

	local goal = solveFrame(savedCf, char)
	-- Face the camera's goal position (front toward lens).
	faceYaw = faceYawTowardCamera(goal.Position, hrp.Position)

	cam.CameraType = Enum.CameraType.Scriptable
	cam.CameraSubject = nil
	cam.CFrame = savedCf:Lerp(goal, 0.12)

	task.spawn(function()
		if faceYaw ~= nil then
			task.spawn(function()
				tweenAvatarYaw(faceYaw :: number, TURN_SEC, my)
			end)
		end
		if not tweenCameraTo(goal, TWEEN_IN_SEC, my) then
			return
		end
		if my ~= token or not active then
			return
		end
		unbindRender()
		renderBound = true
		RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Last.Value, function(dt)
			if my ~= token or not active then
				return
			end
			if playerGui:GetAttribute(SKILLS_OPEN_ATTR) ~= true then
				return
			end
			local c = getCamera()
			local ch = getCharacter()
			if not c or not ch then
				return
			end
			local nextGoal = goalFromLocked(ch)
			c.CameraType = Enum.CameraType.Scriptable
			c.CameraSubject = nil
			local a = 1 - math.exp(-14 * math.max(dt, 1 / 120))
			c.CFrame = c.CFrame:Lerp(nextGoal, a)
			holdAvatarFacing(c)
		end)
	end)
end

function SkillsAvatarCam.bindAttribute()
	if attrBound then
		return
	end
	attrBound = true
	local function sync()
		if playerGui:GetAttribute(CINEMATIC_BUSY_ATTR) == true then
			SkillsAvatarCam.releaseForCinematic()
			return
		end
		if playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
			SkillsAvatarCam.start()
		else
			SkillsAvatarCam.stop()
		end
	end
	playerGui:GetAttributeChangedSignal(SKILLS_OPEN_ATTR):Connect(sync)
	playerGui:GetAttributeChangedSignal(CINEMATIC_BUSY_ATTR):Connect(sync)
	sync()
end

SkillsAvatarCam.bindAttribute()

return SkillsAvatarCam
