--!strict
--[[
	Local-only Clear Plot VFX:
	light flash → neon-green wave → fly into hand sphere → +N count → fly to backpack scroll.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClearPlotVfx = {}

local UiTheme = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("UiTheme"))

local GREEN = Color3.fromRGB(40, 255, 90)

local function randomNeonGreen(): Color3
	-- Slight per-coral variation around the base neon green.
	local r = math.clamp(20 + math.random(0, 50), 0, 255)
	local g = math.clamp(220 + math.random(0, 35), 0, 255)
	local b = math.clamp(55 + math.random(0, 70), 0, 255)
	return Color3.fromRGB(r, g, b)
end
local LIGHT_RANGE = 40
local LIGHT_BRIGHTNESS = 4
local LIGHT_FADE_SEC = 5
local WAVE_MIN_SEC = 1
local WAVE_MAX_SEC = 3
local GREEN_HOLD_SEC = 0.75
local COUNT_MIN_SEC = 0.8 -- ~20% faster than 1
local COUNT_MAX_SEC = 3.2 -- ~20% faster than 4
local COUNT_PER_CORAL = 0.064 -- ~20% faster than 0.08
local TICK_MAX_PER_SEC = 5
local FLY_STAGGER_MAX = 0.65
local FLY_TO_HAND_SEC = 0.55
local FLY_TO_BAG_SEC = 1
local HAND_ORB_SIZE = 1.4
local TICK_SOUND_ID = "rbxassetid://138913815716094"

local player = Players.LocalPlayer
local busy = false
local token = 0

local tickTemplate = Instance.new("Sound")
tickTemplate.Name = "OceanTD_ClearTick"
tickTemplate.SoundId = TICK_SOUND_ID
tickTemplate.Volume = 0.55
tickTemplate.Parent = SoundService
task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ tickTemplate })
	end)
end)

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

local function handWorldPos(): Vector3
	local hand = rightHand()
	if hand then
		return (hand.CFrame * CFrame.new(0, -0.15, -0.35)).Position
	end
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position + Vector3.new(0, 1.5, 0)
	end
	return Vector3.zero
end

local function playerRootPos(): Vector3
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position
	end
	return Vector3.zero
end

local function worldToScreen(worldPos: Vector3): Vector2?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local v, onScreen = cam:WorldToViewportPoint(worldPos)
	if not onScreen and v.Z < 0 then
		return nil
	end
	return Vector2.new(v.X, v.Y)
end

local function playTick(pitch: number)
	local s = tickTemplate:Clone()
	s.PlaybackSpeed = math.clamp(pitch, 0.85, 1.8)
	s.Parent = SoundService
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
	task.delay(2, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

local function tweenPartToHand(part: BasePart, duration: number, myToken: number): boolean
	local startPos = part.Position
	local startSize = part.Size
	local t0 = os.clock()
	while os.clock() - t0 < duration do
		if myToken ~= token or not part.Parent then
			return false
		end
		local u = math.clamp((os.clock() - t0) / duration, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		local target = handWorldPos()
		part.CFrame = CFrame.new(startPos:Lerp(target, a))
		local s = startSize:Lerp(Vector3.new(0.12, 0.12, 0.12), a)
		part.Size = s
		RunService.RenderStepped:Wait()
	end
	if part.Parent then
		part:Destroy()
	end
	return myToken == token
end

function ClearPlotVfx.isBusy(): boolean
	return busy
end

function ClearPlotVfx.cancel()
	token += 1
	busy = false
end

export type PlayArgs = {
	parts: { BasePart },
	count: number,
	getScrollCenter: () -> Vector2?,
	onDone: (() -> ())?,
}

function ClearPlotVfx.play(args: PlayArgs)
	if busy then
		ClearPlotVfx.cancel()
	end
	token += 1
	local myToken = token
	busy = true
	local parts = args.parts
	local count = math.max(0, math.floor(args.count))
	local getScrollCenter = args.getScrollCenter
	local onDone = args.onDone

	task.spawn(function()
		local folder = fxFolder()

		-- Reparent live corals into local FX so server destroy is a no-op / already gone.
		local animParts: { BasePart } = {}
		for _, p in ipairs(parts) do
			if p.Parent then
				p.Anchored = true
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
				p.CastShadow = false
				p.Parent = folder
				table.insert(animParts, p)
			end
		end

		-- Light flash at player (range 40), then fade over 5s.
		local lightHost = Instance.new("Part")
		lightHost.Name = "OceanTD_ClearLight"
		lightHost.Anchored = true
		lightHost.CanCollide = false
		lightHost.CanQuery = false
		lightHost.CanTouch = false
		lightHost.Transparency = 1
		lightHost.Size = Vector3.new(0.2, 0.2, 0.2)
		lightHost.CFrame = CFrame.new(playerRootPos())
		lightHost.Parent = folder
		local light = Instance.new("PointLight")
		light.Color = GREEN
		light.Brightness = LIGHT_BRIGHTNESS
		light.Range = LIGHT_RANGE
		light.Parent = lightHost
		task.spawn(function()
			local t0 = os.clock()
			while myToken == token and light.Parent do
				local u = math.clamp((os.clock() - t0) / LIGHT_FADE_SEC, 0, 1)
				lightHost.CFrame = CFrame.new(playerRootPos())
				light.Brightness = LIGHT_BRIGHTNESS * (1 - u)
				if u >= 1 then
					break
				end
				RunService.RenderStepped:Wait()
			end
			if lightHost.Parent then
				lightHost:Destroy()
			end
		end)

		if #animParts == 0 or count <= 0 then
			busy = false
			if onDone then
				onDone()
			end
			return
		end

		-- Neon green wave from player outward (1–3s).
		local root = playerRootPos()
		table.sort(animParts, function(a, b)
			return (a.Position - root).Magnitude < (b.Position - root).Magnitude
		end)
		local maxDist = 1
		for _, p in ipairs(animParts) do
			maxDist = math.max(maxDist, (p.Position - root).Magnitude)
		end
		local waveSpan = WAVE_MIN_SEC + (WAVE_MAX_SEC - WAVE_MIN_SEC) * math.clamp(maxDist / 80, 0, 1)

		local greened = 0
		for _, p in ipairs(animParts) do
			local dist = (p.Position - root).Magnitude
			local delaySec = (dist / maxDist) * waveSpan
			task.delay(delaySec, function()
				if myToken ~= token or not p.Parent then
					return
				end
				p.Material = Enum.Material.Neon
				p.Color = randomNeonGreen()
				greened += 1
			end)
		end

		-- Wait until wave finishes.
		local waveWait = waveSpan + 0.05
		local tw0 = os.clock()
		while os.clock() - tw0 < waveWait and myToken == token do
			RunService.RenderStepped:Wait()
		end
		if myToken ~= token then
			busy = false
			return
		end

		-- Hold green briefly, then stagger flies while counting starts early in-hand.
		task.wait(GREEN_HOLD_SEC)
		if myToken ~= token then
			busy = false
			return
		end

		local orb = Instance.new("Part")
		orb.Name = "OceanTD_ClearHandOrb"
		orb.Shape = Enum.PartType.Ball
		orb.Material = Enum.Material.Neon
		orb.Color = GREEN
		orb.Size = Vector3.new(HAND_ORB_SIZE, HAND_ORB_SIZE, HAND_ORB_SIZE)
		orb.Anchored = true
		orb.CanCollide = false
		orb.CanQuery = false
		orb.CanTouch = false
		orb.CastShadow = false
		orb.Parent = folder

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "ClearCount"
		billboard.Size = UDim2.fromOffset(80, 40)
		billboard.StudsOffset = Vector3.new(0, 1.4, 0)
		billboard.AlwaysOnTop = true
		billboard.Parent = orb
		local countLabel = Instance.new("TextLabel")
		countLabel.BackgroundTransparency = 1
		countLabel.Size = UDim2.fromScale(1, 1)
		countLabel.Font = UiTheme.Font
		countLabel.Text = "+0"
		countLabel.TextColor3 = Color3.new(1, 1, 1)
		countLabel.TextScaled = true
		countLabel.TextStrokeTransparency = 0.4
		countLabel.Parent = billboard

		local followConn = RunService.RenderStepped:Connect(function()
			if myToken ~= token or not orb.Parent then
				return
			end
			orb.CFrame = CFrame.new(handWorldPos())
		end)

		local countSec = math.clamp(COUNT_MIN_SEC + (count - 1) * COUNT_PER_CORAL, COUNT_MIN_SEC, COUNT_MAX_SEC)
		local tickInterval = 1 / TICK_MAX_PER_SEC
		local lastTickAt = -1
		local displayed = 0
		local countDone = false
		local c0 = os.clock()

		-- Count up in parallel with staggered coral flights.
		task.spawn(function()
			while os.clock() - c0 < countSec and myToken == token do
				local u = math.clamp((os.clock() - c0) / countSec, 0, 1)
				local n = math.floor(count * u + 1e-6)
				if n > displayed then
					displayed = n
					countLabel.Text = "+" .. tostring(displayed)
					local now = os.clock()
					if now - lastTickAt >= tickInterval then
						lastTickAt = now
						local pitch = 0.95 + (displayed / math.max(count, 1)) * 0.7
						playTick(pitch)
					end
				end
				RunService.RenderStepped:Wait()
			end
			if myToken == token then
				countLabel.Text = "+" .. tostring(count)
				if lastTickAt < 0 or (os.clock() - lastTickAt) >= tickInterval * 0.5 then
					playTick(1.65)
				end
			end
			countDone = true
		end)

		local flyJobs = 0
		local flyDone = 0
		local toFly: { BasePart } = {}
		for _, p in ipairs(animParts) do
			if p.Parent then
				table.insert(toFly, p)
			end
		end
		local nFly = #toFly
		for i, p in ipairs(toFly) do
			flyJobs += 1
			local t = if nFly <= 1 then 0 else (i - 1) / (nFly - 1)
			local stagger = t * FLY_STAGGER_MAX * (0.65 + math.random() * 0.7)
			task.delay(stagger, function()
				if myToken ~= token then
					flyDone += 1
					return
				end
				tweenPartToHand(p, FLY_TO_HAND_SEC, myToken)
				flyDone += 1
			end)
		end

		while (flyDone < flyJobs or not countDone) and myToken == token do
			RunService.RenderStepped:Wait()
		end
		if myToken ~= token then
			followConn:Disconnect()
			if orb.Parent then
				orb:Destroy()
			end
			busy = false
			return
		end

		followConn:Disconnect()
		if myToken ~= token then
			if orb.Parent then
				orb:Destroy()
			end
			busy = false
			return
		end

		-- Fly orb + counter to backpack scroll center (screen-space), fade 1s.
		local startScreen = worldToScreen(orb.Position) or Vector2.new(0, 0)
		local target = getScrollCenter()
		if not target then
			local cam = Workspace.CurrentCamera
			local vp = if cam then cam.ViewportSize else Vector2.new(800, 600)
			target = Vector2.new(vp.X * 0.82, vp.Y * 0.5)
		end

		local gui = Instance.new("ScreenGui")
		gui.Name = "OceanTD_ClearFly"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 12100
		gui.Parent = player:WaitForChild("PlayerGui")

		local fly = Instance.new("Frame")
		fly.Name = "Orb"
		fly.AnchorPoint = Vector2.new(0.5, 0.5)
		fly.Position = UDim2.fromOffset(startScreen.X, startScreen.Y)
		fly.Size = UDim2.fromOffset(48, 48)
		fly.BackgroundColor3 = GREEN
		fly.BorderSizePixel = 0
		fly.Parent = gui
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = fly
		local flyLabel = Instance.new("TextLabel")
		flyLabel.BackgroundTransparency = 1
		flyLabel.Size = UDim2.fromScale(1, 1)
		flyLabel.Font = UiTheme.Font
		flyLabel.Text = "+" .. tostring(count)
		flyLabel.TextColor3 = Color3.new(1, 1, 1)
		flyLabel.TextScaled = true
		flyLabel.Parent = fly

		if orb.Parent then
			orb:Destroy()
		end

		local fade = TweenService:Create(fly, TweenInfo.new(FLY_TO_BAG_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.fromOffset(target.X, target.Y),
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(18, 18),
		})
		local fadeText = TweenService:Create(flyLabel, TweenInfo.new(FLY_TO_BAG_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			TextTransparency = 1,
		})
		fade:Play()
		fadeText:Play()
		fade.Completed:Wait()
		if gui.Parent then
			gui:Destroy()
		end

		if myToken == token then
			busy = false
			if onDone then
				onDone()
			end
		end
	end)
end

return ClearPlotVfx
