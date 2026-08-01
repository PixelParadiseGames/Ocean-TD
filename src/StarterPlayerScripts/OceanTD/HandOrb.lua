--!strict
-- Client-only coral “seed” orb in the right hand. Other players never see it.
-- Arm → neon sphere in hand. Disarm → scale to 0. Place → fly to plant, fade 1s, return + scale up.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local REST_SIZE = 1.15 * 1.3 -- 30% larger while armed
local HAND_OFFSET = CFrame.new(0, -0.15, -0.35)
local SCALE_IN_SEC = 0.28
local SCALE_OUT_SEC = 0.2
local FLY_FADE_SEC = 1

local HandOrb = {}

local player = Players.LocalPlayer
local orb: Part? = nil
local followConn: RBXScriptConnection? = nil
local animToken = 0
local attached = false
local flying = false
local activeColor: Color3 = Color3.fromRGB(255, 220, 80)
local armed = false

local function fxFolder(): Folder
	local cam = Workspace.CurrentCamera
	local folder = cam and cam:FindFirstChild("OceanTD_LocalFX")
	if folder and folder:IsA("Folder") then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "OceanTD_LocalFX"
	f.Parent = cam or Workspace
	return f
end

local function rightHand(): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if hand and hand:IsA("BasePart") then
		return hand
	end
	return nil
end

local function stopFollow()
	if followConn then
		followConn:Disconnect()
		followConn = nil
	end
end

local function destroyOrb()
	stopFollow()
	if orb then
		orb:Destroy()
		orb = nil
	end
	attached = false
end

local function makeOrb(color: Color3, size: number): Part
	local p = Instance.new("Part")
	p.Name = "OceanTD_HandOrb"
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.new(size, size, size)
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Massless = true
	p.Transparency = 0
	p.Parent = fxFolder()
	return p
end

local function startFollow(part: Part)
	stopFollow()
	attached = true
	followConn = RunService.RenderStepped:Connect(function()
		if not attached or not part.Parent then
			return
		end
		local hand = rightHand()
		if hand then
			part.CFrame = hand.CFrame * HAND_OFFSET
		end
	end)
end

local function tweenSize(part: Part, from: number, to: number, sec: number, token: number): () -> boolean
	local t0 = os.clock()
	local done = false
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		if token ~= animToken or not part.Parent then
			conn:Disconnect()
			done = true
			return
		end
		local u = if sec <= 0 then 1 else math.clamp((os.clock() - t0) / sec, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		local s = from + (to - from) * a
		part.Size = Vector3.new(s, s, s)
		if u >= 1 then
			part.Size = Vector3.new(to, to, to)
			conn:Disconnect()
			done = true
		end
	end)
	return function()
		return done
	end
end

function HandOrb.isArmed(): boolean
	return armed
end

function HandOrb.getHoldWorldPos(): Vector3?
	local hand = rightHand()
	if not hand then
		return nil
	end
	return (hand.CFrame * HAND_OFFSET).Position
end

function HandOrb.arm(color: Color3)
	armed = true
	activeColor = color
	-- Successful plant-fly owns the orb until it returns; don't interrupt it.
	if flying then
		return
	end
	animToken += 1
	local token = animToken

	if orb and orb.Parent and attached then
		orb.Color = color
		orb.Transparency = 0
		local from = orb.Size.X
		tweenSize(orb, from, REST_SIZE, SCALE_IN_SEC, token)
		return
	end

	destroyOrb()
	orb = makeOrb(color, 0.05)
	startFollow(orb)
	tweenSize(orb, 0.05, REST_SIZE, SCALE_IN_SEC, token)
end

function HandOrb.disarm(durationSec: number?)
	armed = false
	flying = false
	animToken += 1
	local token = animToken
	local part = orb
	if not part or not part.Parent then
		destroyOrb()
		return
	end
	local from = part.Size.X
	local sec = if typeof(durationSec) == "number" and durationSec > 0 then durationSec else SCALE_OUT_SEC
	task.spawn(function()
		local isDone = tweenSize(part, from, 0.05, sec, token)
		while not isDone() do
			RunService.RenderStepped:Wait()
		end
		if token == animToken then
			destroyOrb()
		end
	end)
end

function HandOrb.flyToPlant(worldPos: Vector3)
	if not armed then
		return
	end
	animToken += 1
	local token = animToken
	local part = orb
	local color = activeColor
	flying = true

	if not part or not part.Parent then
		task.delay(FLY_FADE_SEC, function()
			flying = false
			if token ~= animToken or not armed then
				return
			end
			HandOrb.arm(color)
		end)
		return
	end

	stopFollow()
	attached = false
	orb = nil
	part.Transparency = 0
	local startCF = part.CFrame
	local startSize = part.Size.X
	local t0 = os.clock()

	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		if token ~= animToken or not part.Parent then
			conn:Disconnect()
			flying = false
			if part.Parent then
				part:Destroy()
			end
			return
		end
		local u = math.clamp((os.clock() - t0) / FLY_FADE_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		local pos = startCF.Position:Lerp(worldPos, a)
		part.CFrame = CFrame.new(pos)
		part.Transparency = a
		local s = startSize * (1 - 0.5 * a)
		part.Size = Vector3.new(s, s, s)
		if u >= 1 then
			conn:Disconnect()
			part:Destroy()
			flying = false
			if token == animToken and armed then
				local fresh = makeOrb(color, 0.05)
				orb = fresh
				startFollow(fresh)
				tweenSize(fresh, 0.05, REST_SIZE, SCALE_IN_SEC, token)
			end
		end
	end)
end

function HandOrb.clear()
	armed = false
	flying = false
	animToken += 1
	destroyOrb()
end

player.CharacterRemoving:Connect(function()
	HandOrb.clear()
end)

return HandOrb
