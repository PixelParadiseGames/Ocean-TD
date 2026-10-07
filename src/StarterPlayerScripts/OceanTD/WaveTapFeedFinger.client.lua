--!strict
--[[
	Wave 1: finger taps on hungry Tang once they enter the last 35% of the path,
	so the player learns they can tap/clip fish to feed them.
	White sphere spray on each press (same language as other finger tutorials).
	Stops after the first successful tap-feed this wave, or when the wave ends.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local C = require(script.Parent:WaitForChild("WaveSimConsts"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local LAST_PATH_FRAC = 0.35
local FINGER_PX = 100
local PRESS_SCALE = 0.82
local PRESS_SEC = 0.16
local HOLD_SEC = 0.12
local RISE_SEC = 0.45
local RETREAT_SEC = 0.45
local REST_OFFSET = Vector2.new(0, 72)
local FINGER_PATH = "Plots.IntroElements.Finger"
local ATTR_TAP_OK = "OceanTD_Wave1TapFeedOk"
local TAP_BURST_COUNT = 6
local TAP_BURST_COLOR = Color3.new(1, 1, 1)

local gui: ScreenGui? = nil
local finger: ImageLabel? = nil
local scaleObj: UIScale? = nil
local burstLayer: Frame? = nil
local dismissedThisWave = false
local lastWave = -1
local phase = "rise"
local phaseT0 = 0
local tapBurstRng = Random.new()

local function findByPathFallback(): Instance?
	local cur: Instance? = Workspace
	for name in string.gmatch(FINGER_PATH, "[^%.]+") do
		if not cur then
			return nil
		end
		cur = cur:FindFirstChild(name)
	end
	return cur
end

local function resolveFingerImage(src: Instance): string?
	if src:IsA("ImageLabel") or src:IsA("ImageButton") then
		if src.Image ~= "" then
			return src.Image
		end
	elseif src:IsA("Decal") or src:IsA("Texture") then
		if src.Texture ~= "" then
			return src.Texture
		end
	end
	local img = src:FindFirstChildWhichIsA("ImageLabel", true) or src:FindFirstChildWhichIsA("ImageButton", true)
	if img and (img:IsA("ImageLabel") or img:IsA("ImageButton")) and img.Image ~= "" then
		return img.Image
	end
	local decal = src:FindFirstChildWhichIsA("Decal", true) or src:FindFirstChildWhichIsA("Texture", true)
	if decal and (decal:IsA("Decal") or decal:IsA("Texture")) and decal.Texture ~= "" then
		return decal.Texture
	end
	return nil
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
	local sizePx = tapBurstRng:NextInteger(7, 12)
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

	local angle = tapBurstRng:NextNumber(-math.pi * 0.85, -math.pi * 0.15)
	local speed = tapBurstRng:NextNumber(180, 420)
	local vx = math.cos(angle) * speed
	local vy = math.sin(angle) * speed
	local grav = tapBurstRng:NextNumber(850, 1200)
	local life = tapBurstRng:NextNumber(0.45, 0.75)
	local popAt = tapBurstRng:NextNumber(0.05, 0.12)
	local peak = tapBurstRng:NextNumber(1.0, 1.35)
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

local function ensureGui(): (ScreenGui?, ImageLabel?, UIScale?)
	if gui and finger and scaleObj and gui.Parent then
		return gui, finger, scaleObj
	end
	local fingerSrc = findByPathFallback()
	local imageId = if fingerSrc then resolveFingerImage(fingerSrc) else nil
	if not imageId then
		return nil, nil, nil
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_WaveTapFeedFinger"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 46
	sg.Enabled = false
	sg.Parent = playerGui
	local img = Instance.new("ImageLabel")
	img.Name = "Finger"
	img.BackgroundTransparency = 1
	img.AnchorPoint = Vector2.new(0.2, 0.1)
	img.Size = UDim2.fromOffset(FINGER_PX, FINGER_PX)
	img.Image = imageId
	img.ScaleType = Enum.ScaleType.Fit
	img.Active = false
	img.Visible = false
	img.Parent = sg
	local sc = Instance.new("UIScale")
	sc.Scale = 1
	sc.Parent = img
	gui = sg
	finger = img
	scaleObj = sc
	ensureBurstLayer(sg)
	return sg, img, sc
end

local function easeOut(u: number): number
	local t = math.clamp(u, 0, 1)
	return 1 - (1 - t) * (1 - t)
end

local function easeIn(u: number): number
	local t = math.clamp(u, 0, 1)
	return t * t
end

local function hideFinger()
	if finger then
		finger.Visible = false
	end
	if gui then
		gui.Enabled = false
	end
	phase = "rise"
end

playerGui:GetAttributeChangedSignal(ATTR_TAP_OK):Connect(function()
	if playerGui:GetAttribute(ATTR_TAP_OK) ~= nil then
		dismissedThisWave = true
		hideFinger()
		playerGui:SetAttribute(ATTR_TAP_OK, nil)
	end
end)

RunService.RenderStepped:Connect(function()
	local wave = WaveSim.getWaveIndex()
	if wave ~= lastWave then
		lastWave = wave
		dismissedThisWave = false
		phase = "rise"
		phaseT0 = os.clock()
	end

	if dismissedThisWave
		or not WaveSim.isRunning()
		or wave ~= C.TANG_FIRST_WAVE
		or playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true
	then
		hideFinger()
		return
	end

	local aim = WaveSim.getWave1TapFeedFingerScreen(LAST_PATH_FRAC)
	if not aim then
		hideFinger()
		return
	end

	local sg, f, sc = ensureGui()
	if not (sg and f and sc) then
		return
	end
	sg.Enabled = true
	f.Visible = true
	local restPos = aim + REST_OFFSET

	local now = os.clock()
	local elapsed = now - phaseT0
	if phase == "rise" then
		local u = easeOut(elapsed / RISE_SEC)
		local p = restPos:Lerp(aim, u)
		f.Position = UDim2.fromOffset(p.X, p.Y)
		sc.Scale = 1
		if elapsed >= RISE_SEC then
			phase = "press"
			phaseT0 = now
			f.Position = UDim2.fromOffset(aim.X, aim.Y)
			spawnTapBurst(aim)
		end
	elseif phase == "press" then
		f.Position = UDim2.fromOffset(aim.X, aim.Y)
		local u = math.clamp(elapsed / PRESS_SEC, 0, 1)
		sc.Scale = 1 - (1 - PRESS_SCALE) * u
		if elapsed >= PRESS_SEC then
			phase = "hold"
			phaseT0 = now
			sc.Scale = PRESS_SCALE
		end
	elseif phase == "hold" then
		f.Position = UDim2.fromOffset(aim.X, aim.Y)
		sc.Scale = PRESS_SCALE
		if elapsed >= HOLD_SEC then
			phase = "retreat"
			phaseT0 = now
		end
	elseif phase == "retreat" then
		local u = easeIn(elapsed / RETREAT_SEC)
		local p = aim:Lerp(restPos, u)
		f.Position = UDim2.fromOffset(p.X, p.Y)
		sc.Scale = PRESS_SCALE + (1 - PRESS_SCALE) * u
		if elapsed >= RETREAT_SEC then
			phase = "rise"
			phaseT0 = now
			sc.Scale = 1
		end
	end
end)
