--!strict
--[[
	Waves 1–3: when feed is complete (NEXT WAVE available), point a finger from
	screen center at the NEXT WAVE button and spray white tap circles.
	Hides when the player taps NEXT WAVE or the next wave starts automatically.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local WaveSlot = require(script.Parent:WaitForChild("WaveSlot"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local GUI_NAME = "OceanTD_NextWaveFingerHint"
local FINGER_PATH = "Plots.IntroElements.Finger"
local MAX_HINT_WAVE = 3
local FINGER_PX = 110
local TIP_ANCHOR = Vector2.new(0.32, 0.12)
local RISE_SEC = 0.7
local PRESS_SEC = 0.17
local HOLD_SEC = 0.12
local RETREAT_SEC = 0.7
local ARC_X_PX = 42
local ARC_Y_PX = 18
local BASE_ROT_DEG = -25
local PRESS_ROT_DEG = 8
local PRESS_SCALE = 0.88
local TAP_BURST_COUNT = 6
local TAP_BURST_COLOR = Color3.new(1, 1, 1)

local gui: ScreenGui? = nil
local finger: ImageLabel? = nil
local scaleObj: UIScale? = nil
local burstLayer: Frame? = nil
local conn: RBXScriptConnection? = nil
local gen = 0
local activeWave: number? = nil
local rng = Random.new()

local function easeOutCubic(t: number): number
	local u = math.clamp(t, 0, 1)
	local inv = 1 - u
	return 1 - inv * inv * inv
end

local function smoothstep(t: number): number
	local u = math.clamp(t, 0, 1)
	return u * u * (3 - 2 * u)
end

local function quadBezier(a: Vector2, ctrl: Vector2, b: Vector2, t: number): Vector2
	local u = 1 - t
	return a * (u * u) + ctrl * (2 * u * t) + b * (t * t)
end

local function viewportCenter(): Vector2
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	return vp * 0.5
end

local function guiCenter(anchor: GuiObject): Vector2
	local pos = anchor.AbsolutePosition
	local size = anchor.AbsoluteSize
	return Vector2.new(pos.X + size.X * 0.5, pos.Y + size.Y * 0.5)
end

local function findByPath(root: Instance, path: string): Instance?
	local cur: Instance? = root
	for name in string.gmatch(path, "[^%.]+") do
		if not cur then
			return nil
		end
		cur = cur:FindFirstChild(name)
	end
	return cur
end

local function resolveFingerImage(src: Instance): string?
	if src:IsA("ImageLabel") or src:IsA("ImageButton") then
		return src.Image
	end
	if src:IsA("Decal") then
		return src.Texture
	end
	local decal = src:FindFirstChildWhichIsA("Decal", true)
	if decal then
		return decal.Texture
	end
	local img = src:FindFirstChildWhichIsA("ImageLabel", true) or src:FindFirstChildWhichIsA("ImageButton", true)
	if img then
		return img.Image
	end
	return nil
end

local function waitFingerSource(timeoutSec: number): Instance?
	local found = findByPath(Workspace, FINGER_PATH)
	if found then
		return found
	end
	local remain = timeoutSec
	local plots = Workspace:FindFirstChild("Plots") or Workspace:WaitForChild("Plots", remain)
	if not plots then
		return nil
	end
	remain = math.max(0.05, remain - 0.05)
	local folder = plots:FindFirstChild("IntroElements") or plots:WaitForChild("IntroElements", remain)
	if not folder then
		return nil
	end
	remain = math.max(0.05, remain - 0.05)
	return folder:FindFirstChild("Finger") or folder:WaitForChild("Finger", remain)
end

local function destroyGui()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	finger = nil
	scaleObj = nil
	burstLayer = nil
	if gui and gui.Parent then
		gui:Destroy()
	end
	gui = nil
end

local function stopHint()
	gen += 1
	activeWave = nil
	destroyGui()
end

local function ensureBurstLayer(sg: ScreenGui): Frame
	local existing = burstLayer
	if existing and existing.Parent == sg then
		return existing
	end
	local layer = sg:FindFirstChild("TapBurstLayer")
	if layer and layer:IsA("Frame") then
		burstLayer = layer
		return layer
	end
	if layer then
		layer:Destroy()
	end
	local f = Instance.new("Frame")
	f.Name = "TapBurstLayer"
	f.BackgroundTransparency = 1
	f.Size = UDim2.fromScale(1, 1)
	f.Active = false
	f.ZIndex = 5
	pcall(function()
		(f :: any).Interactable = false
	end)
	f.Parent = sg
	burstLayer = f
	return f
end

local function spawnTapCircle(layer: Frame, origin: Vector2)
	local sizePx = rng:NextInteger(7, 12)
	local circle = Instance.new("Frame")
	circle.Name = "TapBurst"
	circle.BorderSizePixel = 0
	circle.BackgroundColor3 = TAP_BURST_COLOR
	circle.BackgroundTransparency = 0
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromOffset(origin.X, origin.Y)
	circle.Size = UDim2.fromOffset(sizePx, sizePx)
	circle.ZIndex = 5
	circle.Active = false
	pcall(function()
		(circle :: any).Interactable = false
	end)
	circle.Parent = layer
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = circle
	local scale = Instance.new("UIScale")
	scale.Scale = 0.15
	scale.Parent = circle

	local angle = rng:NextNumber(-math.pi * 0.85, -math.pi * 0.15)
	local speed = rng:NextNumber(180, 420)
	local vx = math.cos(angle) * speed
	local vy = math.sin(angle) * speed
	local grav = rng:NextNumber(850, 1200)
	local life = rng:NextNumber(0.45, 0.75)
	local popAt = rng:NextNumber(0.05, 0.12)
	local peak = rng:NextNumber(1.0, 1.35)
	local x = origin.X
	local y = origin.Y
	task.spawn(function()
		local t0 = os.clock()
		while circle.Parent do
			local dt = RunService.RenderStepped:Wait()
			local age = os.clock() - t0
			if age >= life then
				break
			end
			vy += grav * dt
			x += vx * dt
			y += vy * dt
			vx *= (1 - 0.4 * dt)
			circle.Position = UDim2.fromOffset(x, y)
			if age < popAt then
				scale.Scale = 0.15 + (peak - 0.15) * (age / popAt)
			else
				local u = math.clamp((age - popAt) / math.max(0.05, life - popAt), 0, 1)
				scale.Scale = peak * (1 - 0.55 * u)
			end
			circle.BackgroundTransparency = math.clamp((age - life * 0.45) / (life * 0.55), 0, 1)
		end
		if circle.Parent then
			circle:Destroy()
		end
	end)
end

local function spawnTapBurst(origin: Vector2)
	local sg = gui
	if not sg or not sg.Parent then
		return
	end
	local layer = ensureBurstLayer(sg)
	for _ = 1, TAP_BURST_COUNT do
		spawnTapCircle(layer, origin)
	end
end

local function ensureGui(imageId: string): ImageLabel?
	if gui and finger and finger.Parent then
		finger.Image = imageId
		return finger
	end
	destroyGui()

	local sg = Instance.new("ScreenGui")
	sg.Name = GUI_NAME
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 8600
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		(sg :: any).ClipToDeviceSafeArea = false
		(sg :: any).SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
	end)
	sg.Parent = playerGui
	gui = sg
	ensureBurstLayer(sg)

	local img = Instance.new("ImageLabel")
	img.Name = "Finger"
	img.BackgroundTransparency = 1
	img.AnchorPoint = TIP_ANCHOR
	img.Size = UDim2.fromOffset(FINGER_PX, FINGER_PX)
	img.Image = imageId
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = 10
	img.Active = false
	pcall(function()
		(img :: any).Interactable = false
	end)
	img.Visible = false
	img.Parent = sg

	local us = Instance.new("UIScale")
	us.Scale = 1
	us.Parent = img

	finger = img
	scaleObj = us
	return img
end

local function resolveNextWavePos(): Vector2?
	local hit = WaveSlot.getNextWaveHit()
	if not hit then
		return nil
	end
	local c = guiCenter(hit)
	if c.X < 2 and c.Y < 2 then
		return nil
	end
	return c
end

local function startHint(wave: number)
	if activeWave == wave and gui and gui.Parent then
		return
	end
	gen += 1
	local my = gen
	activeWave = wave

	task.spawn(function()
		local src = waitFingerSource(8)
		if my ~= gen or not src then
			return
		end
		local imageId = resolveFingerImage(src)
		if not imageId then
			return
		end
		local img = ensureGui(imageId)
		if not img or my ~= gen then
			return
		end

		local phase = "rise"
		local t0 = os.clock()
		local fromPos = viewportCenter()
		local toPos = fromPos
		local ctrlPos = fromPos
		local laidOut = false
		local arcSign = -1

		local function setArc(from: Vector2, to: Vector2, sign: number)
			local mid = from:Lerp(to, 0.5)
			local delta = to - from
			local len = delta.Magnitude
			local perp = if len > 1e-3
				then Vector2.new(-delta.Y, delta.X).Unit
				else Vector2.new(1, 0)
			ctrlPos = mid + perp * (ARC_X_PX * sign) + Vector2.new(0, -ARC_Y_PX * sign * 0.35)
		end

		local function beginRise(btn: Vector2)
			fromPos = viewportCenter()
			toPos = btn
			arcSign = -1
			setArc(fromPos, toPos, arcSign)
			phase = "rise"
			t0 = os.clock()
		end

		local function beginRetreat(btn: Vector2)
			fromPos = btn
			toPos = viewportCenter()
			arcSign = 1
			setArc(fromPos, toPos, arcSign)
			phase = "retreat"
			t0 = os.clock()
		end

		if conn then
			conn:Disconnect()
			conn = nil
		end
		conn = RunService.RenderStepped:Connect(function()
			if my ~= gen then
				return
			end
			local f = finger
			local sc = scaleObj
			if not (f and sc and f.Parent) then
				return
			end

			-- Button gone / wave advanced → hide.
			if not WaveSlot.isFinishReady() then
				stopHint()
				return
			end

			local btn = resolveNextWavePos()
			if not btn then
				f.Visible = false
				laidOut = false
				return
			end

			f.Visible = true
			if not laidOut then
				beginRise(btn)
				laidOut = true
				f.Position = UDim2.fromOffset(fromPos.X, fromPos.Y)
				f.Rotation = BASE_ROT_DEG
				sc.Scale = 1
			end

			local now = os.clock()
			local elapsed = now - t0

			if phase == "rise" then
				toPos = btn
				setArc(fromPos, toPos, arcSign)
				local u = easeOutCubic(elapsed / RISE_SEC)
				local p = quadBezier(fromPos, ctrlPos, toPos, u)
				f.Position = UDim2.fromOffset(p.X, p.Y)
				f.Rotation = BASE_ROT_DEG
				sc.Scale = 1
				if elapsed >= RISE_SEC then
					phase = "pressIn"
					t0 = now
					f.Position = UDim2.fromOffset(btn.X, btn.Y)
				end
			elseif phase == "pressIn" then
				local u = smoothstep(math.clamp(elapsed / PRESS_SEC, 0, 1))
				sc.Scale = 1 + (PRESS_SCALE - 1) * u
				f.Rotation = BASE_ROT_DEG + PRESS_ROT_DEG * u
				f.Position = UDim2.fromOffset(btn.X, btn.Y)
				if elapsed >= PRESS_SEC then
					spawnTapBurst(btn)
					phase = "pressOut"
					t0 = now
					sc.Scale = PRESS_SCALE
					f.Rotation = BASE_ROT_DEG + PRESS_ROT_DEG
				end
			elseif phase == "pressOut" then
				local u = smoothstep(math.clamp(elapsed / PRESS_SEC, 0, 1))
				sc.Scale = PRESS_SCALE + (1 - PRESS_SCALE) * u
				f.Rotation = BASE_ROT_DEG + PRESS_ROT_DEG * (1 - u)
				f.Position = UDim2.fromOffset(btn.X, btn.Y)
				if elapsed >= PRESS_SEC then
					phase = "hold"
					t0 = now
					sc.Scale = 1
					f.Rotation = BASE_ROT_DEG
				end
			elseif phase == "hold" then
				f.Position = UDim2.fromOffset(btn.X, btn.Y)
				f.Rotation = BASE_ROT_DEG
				sc.Scale = 1
				if elapsed >= HOLD_SEC then
					beginRetreat(btn)
				end
			elseif phase == "retreat" then
				fromPos = btn
				toPos = viewportCenter()
				setArc(fromPos, toPos, arcSign)
				local u = easeOutCubic(elapsed / RETREAT_SEC)
				local p = quadBezier(fromPos, ctrlPos, toPos, u)
				f.Position = UDim2.fromOffset(p.X, p.Y)
				f.Rotation = BASE_ROT_DEG
				sc.Scale = 1
				if elapsed >= RETREAT_SEC then
					beginRise(btn)
				end
			end
		end)
	end)
end

WaveSim.onHud(function(snap)
	local wave = math.floor(snap.wave or 0)
	local want = snap.running == true
		and snap.feedComplete == true
		and wave >= 1
		and wave <= MAX_HINT_WAVE
	if want then
		startHint(wave)
	elseif activeWave ~= nil then
		stopHint()
	end
end)

WaveSim.onStopped(function()
	stopHint()
end)
