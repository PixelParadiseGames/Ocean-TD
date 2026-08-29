--!strict
--[[
	Urchin sting client VFX/knockback. WaveSim can call playLocal immediately;
	server UrchinSting fills in stolen $D (and stings remote victims).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))
local C = require(script.Parent:WaitForChild("WaveSimConsts"))

local UrchinStingEffects = {}

local ORB_COLOR = C.URCHIN_ORB_COLOR
local flashGui: ScreenGui? = nil
local shakeToken = 0
local localStingUntil = 0

local stabSound = Instance.new("Sound")
stabSound.Name = "OceanTD_UrchinStab"
stabSound.SoundId = C.URCHIN_STING_SOUND_STAB
stabSound.Volume = 0.95
stabSound.Parent = SoundService

local oofSound = Instance.new("Sound")
oofSound.Name = "OceanTD_UrchinOof"
oofSound.SoundId = C.URCHIN_STING_SOUND_OOF
oofSound.Volume = 0.85
oofSound.Parent = SoundService

local pickupSound = Instance.new("Sound")
pickupSound.Name = "OceanTD_UrchinOrbPickup"
pickupSound.SoundId = C.URCHIN_ORB_PICKUP_SOUND
pickupSound.Volume = 0.55
pickupSound.Parent = SoundService

local function playOneShot(template: Sound, speed: number?)
	local s = template:Clone()
	s.PlaybackSpeed = speed or 1
	s.Parent = SoundService
	s:Play()
	s.Ended:Connect(function()
		s:Destroy()
	end)
	task.delay(4, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

local function ensureFlash(): Frame
	if flashGui and flashGui.Parent then
		local f = flashGui:FindFirstChild("Red")
		if f and f:IsA("Frame") then
			return f
		end
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_UrchinStingFlash"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 100000
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui
	flashGui = sg
	local f = Instance.new("Frame")
	f.Name = "Red"
	f.BackgroundColor3 = Color3.fromRGB(220, 20, 40)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Size = UDim2.fromScale(1, 1)
	f.Active = false
	f.Parent = sg
	return f
end

local function flashRed()
	local frame = ensureFlash()
	frame.BackgroundTransparency = 0.5
	task.delay(0.18, function()
		if not frame.Parent then
			return
		end
		TweenService:Create(frame, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 1,
		}):Play()
	end)
end

local function cameraShake(durationSec: number)
	shakeToken += 1
	local my = shakeToken
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if my ~= shakeToken or not hum.Parent then
			if conn then
				conn:Disconnect()
			end
			if hum.Parent then
				hum.CameraOffset = Vector3.zero
			end
			return
		end
		local u = (os.clock() - t0) / durationSec
		if u >= 1 then
			hum.CameraOffset = Vector3.zero
			if conn then
				conn:Disconnect()
			end
			return
		end
		local amp = (1 - u) * 0.55
		hum.CameraOffset = Vector3.new(
			(math.noise(os.clock() * 28, 1) - 0.5) * 2 * amp,
			(math.noise(os.clock() * 31, 2) - 0.5) * 2 * amp,
			0
		)
	end)
end

local function applyKnockback(vel: Vector3)
	local char = player.Character
	if not char then
		return
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not (hrp and hrp:IsA("BasePart")) then
		return
	end
	if hum then
		hum:ChangeState(Enum.HumanoidStateType.Freefall)
	end
	hrp.AssemblyLinearVelocity = vel
	UiHaptics.pulseTriple()
end

function UrchinStingEffects.knockVelocityFrom(urchinPos: Vector3): Vector3
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local victimPos = if hrp and hrp:IsA("BasePart") then hrp.Position else urchinPos
	local flat = Vector3.new(victimPos.X - urchinPos.X, 0, victimPos.Z - urchinPos.Z)
	if flat.Magnitude < 0.15 then
		local a = math.random() * math.pi * 2
		flat = Vector3.new(math.cos(a), 0, math.sin(a))
	else
		flat = flat.Unit
	end
	return flat * C.URCHIN_STING_KB_SPEED + Vector3.new(0, C.URCHIN_STING_KB_UP, 0)
end

local function floatingLossText(stolen: number, worldPos: Vector3)
	if stolen <= 0 then
		return
	end
	local part = Instance.new("Part")
	part.Name = "OceanTD_UrchinLossText"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.new(worldPos + Vector3.new(0, 3, 0))
	part.Parent = Workspace

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(6, 2.2)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 200
	bb.Parent = part
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = UiTheme.Font
	lbl.Text = "-" .. tostring(stolen) .. " $D"
	lbl.TextColor3 = Color3.fromRGB(255, 70, 70)
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.2
	lbl.TextStrokeColor3 = Color3.fromRGB(40, 0, 0)
	lbl.Parent = bb

	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function()
		local u = (os.clock() - t0) / 1.35
		if u >= 1 or not part.Parent then
			if conn then
				conn:Disconnect()
			end
			part:Destroy()
			return
		end
		part.CFrame = CFrame.new(worldPos + Vector3.new(0, 3 + u * 4, 0))
		lbl.TextTransparency = math.clamp((u - 0.55) / 0.45, 0, 1)
		lbl.TextStrokeTransparency = 0.2 + lbl.TextTransparency * 0.8
	end)
end

local function floatingGainText(worldPos: Vector3, amount: number)
	local part = Instance.new("Part")
	part.Name = "OceanTD_UrchinGainText"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.new(worldPos + Vector3.new(0, 2.2, 0))
	part.Parent = Workspace
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(4, 1.6)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 120
	bb.Parent = part
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = UiTheme.Font
	lbl.Text = "+$" .. tostring(amount)
	lbl.TextColor3 = ORB_COLOR
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.25
	lbl.TextStrokeColor3 = Color3.fromRGB(0, 40, 15)
	lbl.Parent = bb
	TweenService:Create(part, TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = CFrame.new(worldPos + Vector3.new(0, 5.5, 0)),
	}):Play()
	task.delay(0.45, function()
		if lbl.Parent then
			TweenService:Create(lbl, TweenInfo.new(0.4), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
	task.delay(0.9, function()
		part:Destroy()
	end)
end

local function playImpact(vel: Vector3, urchinPos: Vector3)
	playOneShot(stabSound, 1)
	task.delay(0.08, function()
		playOneShot(oofSound, 1)
	end)
	flashRed()
	cameraShake(0.5)
	applyKnockback(vel)
end

-- Immediate local sting (wave host walking into urchin). Server confirms stolen after.
function UrchinStingEffects.playLocal(urchinPos: Vector3)
	localStingUntil = os.clock() + 0.75
	playImpact(UrchinStingEffects.knockVelocityFrom(urchinPos), urchinPos)
end

function UrchinStingEffects.applyServerPayload(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local stolen = math.max(0, math.floor(tonumber(payload.stolen) or 0))
	local ux = tonumber(payload.urchinX) or 0
	local uy = tonumber(payload.urchinY) or 0
	local uz = tonumber(payload.urchinZ) or 0
	local urchinPos = Vector3.new(ux, uy, uz)
	if os.clock() < localStingUntil then
		-- Already played knockback/flash locally; only show -$D once server resolves.
		floatingLossText(stolen, urchinPos)
		return
	end
	local vx = tonumber(payload.velX) or 0
	local vy = tonumber(payload.velY) or C.URCHIN_STING_KB_UP
	local vz = tonumber(payload.velZ) or 0
	playImpact(Vector3.new(vx, vy, vz), urchinPos)
	floatingLossText(stolen, urchinPos)
end

function UrchinStingEffects.playOrbPickup(pos: Vector3, amount: number)
	playOneShot(pickupSound, 1.05 + math.random() * 0.15)
	floatingGainText(pos, amount)
	UiHaptics.pulseShort()
end

return UrchinStingEffects
