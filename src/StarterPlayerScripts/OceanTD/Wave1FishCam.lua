--!strict
--[[
	Wave 1 only: CameraSubject follows an invisible part that smoothly tracks the
	furthest-along unfed fish. When the target fish changes, blend slowly to the new
	fish. After wave 1 (or waves stop), tween focus back to the avatar and restore Custom.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local Wave1FishCam = {}

local FOLLOW_RATE = 4.2 -- same-fish smooth follow
local SWITCH_SEC = 3.5 -- slow blend when furthest unfed fish changes
local RESTORE_SEC = 1.35 -- tween focus back to avatar after wave 1

local active = false
local restoring = false
local focusPart: BasePart? = nil
local conn: RBXScriptConnection? = nil
local token = 0
local targetId: number? = nil
local focusPos = Vector3.zero
local switchFrom = Vector3.zero
local switchTo = Vector3.zero
local switchT0 = 0
local switching = false
local savedSubject: Instance? = nil
local savedCamType: Enum.CameraType? = nil

local function getHumanoid(): Humanoid?
	local char = Players.LocalPlayer.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function getHrp(): BasePart?
	local char = Players.LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function ensureFocusPart(): BasePart
	local p = focusPart
	if p and p.Parent then
		return p
	end
	p = Instance.new("Part")
	p.Name = "OceanTD_Wave1FishFocus"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.Parent = Workspace
	focusPart = p
	return p
end

local function destroyFocusPart()
	if focusPart then
		focusPart:Destroy()
		focusPart = nil
	end
end

local function stopConn()
	if conn then
		conn:Disconnect()
		conn = nil
	end
end

local function restoreAvatarSubject()
	local cam = Workspace.CurrentCamera
	local hum = getHumanoid()
	if cam and hum then
		cam.CameraSubject = hum
		if cam.CameraType == Enum.CameraType.Scriptable then
			cam.CameraType = savedCamType or Enum.CameraType.Custom
		end
	end
	savedSubject = nil
	savedCamType = nil
end

local function beginSwitch(toPos: Vector3)
	switchFrom = focusPos
	switchTo = toPos
	switchT0 = os.clock()
	switching = true
end

local function tickFollow(dt: number)
	if restoring or not active then
		return
	end
	local cam = Workspace.CurrentCamera
	local part = focusPart
	if not cam or not part or not part.Parent then
		return
	end
	-- Bail if something else stole Scriptable/subject (placement, freecam, plot cinematic).
	if cam.CameraSubject ~= part then
		return
	end

	local fish = WaveSim.getFurthestUnfedFish()
	local goal: Vector3
	if fish then
		goal = fish.position
		if targetId ~= fish.id then
			targetId = fish.id
			beginSwitch(goal)
		elseif switching then
			switchTo = goal
		end
	else
		-- Last hungry just fed: stay on them until the next wave's fish spawn.
		local held = if targetId then WaveSim.getFishPosition(targetId) else nil
		if held then
			goal = held
			if switching then
				switchTo = goal
			end
		else
			goal = focusPos
		end
	end

	if switching then
		local u = math.clamp((os.clock() - switchT0) / SWITCH_SEC, 0, 1)
		local e = u * u * (3 - 2 * u)
		focusPos = switchFrom:Lerp(switchTo, e)
		if u >= 1 then
			switching = false
			focusPos = switchTo
		end
	else
		local a = 1 - math.exp(-FOLLOW_RATE * math.max(dt, 0))
		focusPos = focusPos:Lerp(goal, a)
	end
	part.CFrame = CFrame.new(focusPos)
end

function Wave1FishCam.isActive(): boolean
	return active
end

function Wave1FishCam.isBusy(): boolean
	return active or restoring
end

function Wave1FishCam.stopImmediate()
	token += 1
	active = false
	restoring = false
	stopConn()
	targetId = nil
	switching = false
	restoreAvatarSubject()
	destroyFocusPart()
end

function Wave1FishCam.restoreToAvatar(onDone: (() -> ())?)
	if restoring then
		return
	end
	if not active and not focusPart then
		if onDone then
			onDone()
		end
		return
	end
	token += 1
	local my = token
	active = false
	restoring = true
	stopConn()
	targetId = nil
	switching = false

	local part = focusPart
	local hrp = getHrp()
	local cam = Workspace.CurrentCamera
	if not part or not part.Parent or not hrp or not cam then
		restoring = false
		restoreAvatarSubject()
		destroyFocusPart()
		if onDone then
			onDone()
		end
		return
	end

	local start = part.Position
	local t0 = os.clock()
	conn = RunService.RenderStepped:Connect(function()
		if my ~= token then
			return
		end
		local humRoot = getHrp()
		local goal = if humRoot then humRoot.Position else start
		local u = math.clamp((os.clock() - t0) / RESTORE_SEC, 0, 1)
		local e = u * u * (3 - 2 * u)
		focusPos = start:Lerp(goal, e)
		if part.Parent then
			part.CFrame = CFrame.new(focusPos)
		end
		if u >= 1 then
			stopConn()
			restoring = false
			restoreAvatarSubject()
			destroyFocusPart()
			if onDone then
				onDone()
			end
		end
	end)
end

function Wave1FishCam.setActive(on: boolean)
	if on then
		if active or restoring then
			return
		end
		local cam = Workspace.CurrentCamera
		if not cam then
			return
		end
		-- Don't fight freecam/fishcam cycle / plot cinematic / placement Scriptable ownership.
		local busy = Players.LocalPlayer:FindFirstChild("PlayerGui")
		if busy then
			if busy:GetAttribute("OceanTD_PlotSizeCinematicBusy") == true then
				return
			end
			local cycle = busy:GetAttribute("OceanTD_CamCycleMode")
			if cycle == "freecam" or cycle == "fishcam" then
				return
			end
		end

		token += 1
		active = true
		restoring = false
		local part = ensureFocusPart()
		local fish = WaveSim.getFurthestUnfedFish()
		local hrp = getHrp()
		if fish then
			focusPos = fish.position
			targetId = fish.id
		elseif hrp then
			focusPos = hrp.Position
			targetId = nil
		else
			focusPos = cam.Focus.Position
			targetId = nil
		end
		part.CFrame = CFrame.new(focusPos)
		switching = false

		savedSubject = cam.CameraSubject
		savedCamType = cam.CameraType
		if cam.CameraType == Enum.CameraType.Scriptable then
			cam.CameraType = Enum.CameraType.Custom
		end
		cam.CameraSubject = part

		stopConn()
		conn = RunService.RenderStepped:Connect(function(dt)
			tickFollow(dt)
		end)
		return
	end

	-- Off: smooth return to avatar, then caller can re-enable wave CameraOffset.
	if active or (focusPart and focusPart.Parent) then
		Wave1FishCam.restoreToAvatar(nil)
	else
		Wave1FishCam.stopImmediate()
	end
end

return Wave1FishCam
