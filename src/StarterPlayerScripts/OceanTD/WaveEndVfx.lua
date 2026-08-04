--!strict
--[[
	End-of-path VFX for WaveSim: reef heart loss + happy fish exit emoji.
	Extracted so WaveSim stays under Luau's 200-local register limit.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local WaveEndVfx = {}

local REEF_TICK_SOUND_ID = "rbxassetid://128707491647978"
local REEF_TICK_PITCH_START = 1.2
local REEF_TICK_PITCH_STEP = 0.09
local REEF_TICK_PITCH_MIN = 0.45
local REEF_TICK_GAP = 0.07
local HEART_LOSS_MAX_STUDS = 100 * 1.4 -- happy exit base size
local HEART_LOSS_END_SCALE = 3 -- broken heart grows to 3× this max
local HEART_FALL_STUDS = 360
local HEART_FALL_SEC = 2.55
local HEART_LIGHT_RANGE = 50
local HEART_LIGHT_BRIGHTNESS = 0.9
local HEART_GUI_ORDER = 2600 -- above happy-exit billboards
local HAPPY_EXIT_SEC = 1.4
local HAPPY_EXIT_START_SCALE = 0.6 -- 40% smaller at spawn
local HAPPY_EXIT_FAN_STUDS = 18 -- lateral spread at arrival
local HAPPY_EXIT_SOUND_ID = "rbxassetid://138571475125488"
local HAPPY_EXIT_PITCH_MIN = 0.82
local HAPPY_EXIT_PITCH_MAX = 1.28
local END_HEART_RED = Color3.fromRGB(255, 40, 55)
local END_HEART_BLACK = Color3.new(0, 0, 0)

local reefTickSound = Instance.new("Sound")
reefTickSound.Name = "OceanTD_ReefTick"
reefTickSound.SoundId = REEF_TICK_SOUND_ID
reefTickSound.Volume = 0.95
reefTickSound.Parent = SoundService

local happyExitSound = Instance.new("Sound")
happyExitSound.Name = "OceanTD_HappyExit"
happyExitSound.SoundId = HAPPY_EXIT_SOUND_ID
happyExitSound.Volume = 0.9
happyExitSound.Parent = SoundService

task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ reefTickSound, happyExitSound })
	end)
end)

local getFolder: (() -> Folder)? = nil
local endHeartPart: BasePart? = nil
local endHeartAnimToken = 0
local reefTickStreak = 0
local rng = Random.new()

function WaveEndVfx.bind(folderFn: () -> Folder)
	getFolder = folderFn
end

function WaveEndVfx.resetStreak()
	reefTickStreak = 0
end

local function resolveFolder(): Folder
	if getFolder then
		return getFolder()
	end
	local existing = Workspace:FindFirstChild("OceanTD_LocalWaves")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = "OceanTD_LocalWaves"
	f.Parent = Workspace
	return f
end

function WaveEndVfx.getEndHeartPart(): BasePart?
	if endHeartPart and endHeartPart.Parent then
		return endHeartPart
	end
	local route = Workspace:FindFirstChild("WaveRoute")
	local a = route and route:FindFirstChild("A")
	local ep = a and a:FindFirstChild("EndPoint")
	local heart = ep and ep:FindFirstChild("heart")
	if heart and heart:IsA("BasePart") then
		endHeartPart = heart
		return heart
	end
	return nil
end

local function pulseReefHeartLoss(at: Vector3)
	local folder = resolveFolder()
	local startPos = at + Vector3.new(0, 2, 0)
	local anchor = Instance.new("Part")
	anchor.Name = "OceanTD_HeartLoss"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(startPos)
	anchor.Parent = folder

	-- ScreenGui so broken hearts draw above happy-exit world billboards.
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_HeartLossGui"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = HEART_GUI_ORDER
	sg.Parent = playerGui or folder

	local holder = Instance.new("Frame")
	holder.Name = "Heart"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(8, 8)
	holder.Parent = sg

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = holder

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = Enum.Font.SourceSansBold
	lbl.Text = "💔"
	lbl.TextColor3 = Color3.fromRGB(255, 35, 55)
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.35
	lbl.TextStrokeColor3 = Color3.fromRGB(80, 0, 10)
	lbl.Parent = holder

	local worldHeart = WaveEndVfx.getEndHeartPart()
	endHeartAnimToken += 1
	local myHeartToken = endHeartAnimToken
	if worldHeart then
		worldHeart.Color = END_HEART_RED
	end

	local lightHost = worldHeart or anchor
	local light = Instance.new("PointLight")
	light.Name = "OceanTD_HeartLossLight"
	light.Color = END_HEART_RED
	light.Brightness = HEART_LIGHT_BRIGHTNESS
	light.Range = HEART_LIGHT_RANGE
	light.Shadows = false
	light.Parent = lightHost

	local function studsToPx(worldPos: Vector3, studs: number): number
		local cam = Workspace.CurrentCamera
		if not cam then
			return studs * 2
		end
		local dist = math.max(1, (cam.CFrame.Position - worldPos).Magnitude)
		local halfFov = math.rad(cam.FieldOfView) * 0.5
		local vp = cam.ViewportSize
		return studs / dist * (vp.Y * 0.5) / math.tan(halfFov)
	end

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local u = math.clamp((os.clock() - t0) / HEART_FALL_SEC, 0, 1)
		local ease = u * u
		local worldPos = startPos - Vector3.new(0, HEART_FALL_STUDS * ease, 0)
		anchor.CFrame = CFrame.new(worldPos)

		local cam = Workspace.CurrentCamera
		if cam then
			local sp, onScreen = cam:WorldToViewportPoint(worldPos)
			holder.Visible = onScreen and sp.Z > 0
			holder.Position = UDim2.fromOffset(sp.X, sp.Y)
			local px = studsToPx(worldPos, HEART_LOSS_MAX_STUDS)
			holder.Size = UDim2.fromOffset(math.max(8, px), math.max(8, px))
		end
		scale.Scale = 1 + (HEART_LOSS_END_SCALE - 1) * ease
		lbl.TextTransparency = u
		lbl.TextStrokeTransparency = 0.35 + 0.65 * u
		light.Brightness = HEART_LIGHT_BRIGHTNESS * (1 - u)
		if worldHeart and myHeartToken == endHeartAnimToken then
			worldHeart.Color = END_HEART_RED:Lerp(END_HEART_BLACK, u)
		end
		if u >= 1 then
			conn:Disconnect()
			if light.Parent then
				light:Destroy()
			end
			if sg.Parent then
				sg:Destroy()
			end
			if anchor.Parent then
				anchor:Destroy()
			end
			if worldHeart and worldHeart.Parent and myHeartToken == endHeartAnimToken then
				worldHeart.Color = END_HEART_RED
			end
		end
	end)
end

local function playHappyExitSound()
	local pitch = rng:NextNumber(HAPPY_EXIT_PITCH_MIN, HAPPY_EXIT_PITCH_MAX)
	local snd = happyExitSound:Clone()
	snd.PlaybackSpeed = pitch
	snd.Volume = 0.9
	snd.Parent = SoundService
	snd:Play()
	local ttl = math.max(0.8, (snd.TimeLength > 0 and snd.TimeLength or 0.5) / math.max(0.2, pitch) + 0.25)
	task.delay(ttl, function()
		if snd.Parent then
			snd:Destroy()
		end
	end)
end

local function characterAimPos(fallback: Vector3): Vector3
	local char = Players.LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position + Vector3.new(0, 1.5, 0)
	end
	return fallback
end

function WaveEndVfx.pulseHappyExit(emoji: string, at: Vector3)
	playHappyExitSound()

	local folder = resolveFolder()
	local startPos = at + Vector3.new(0, 2, 0)
	-- Random lateral/vertical fan so simultaneous exits don't stack.
	local fanYaw = rng:NextNumber(0, math.pi * 2)
	local fanReach = rng:NextNumber(HAPPY_EXIT_FAN_STUDS * 0.45, HAPPY_EXIT_FAN_STUDS)
	local fanSide = Vector3.new(math.cos(fanYaw), 0, math.sin(fanYaw)) * fanReach
	local fanUp = Vector3.new(0, rng:NextNumber(-6, 10), 0)

	local anchor = Instance.new("Part")
	anchor.Name = "OceanTD_HappyExit"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(startPos)
	anchor.Parent = folder

	local bb = Instance.new("BillboardGui")
	bb.Name = "HappyFace"
	bb.Adornee = anchor
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 2000
	bb.Size = UDim2.fromScale(HEART_LOSS_MAX_STUDS, HEART_LOSS_MAX_STUDS)
	bb.Parent = anchor

	local scale = Instance.new("UIScale")
	scale.Scale = HAPPY_EXIT_START_SCALE
	scale.Parent = bb

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = Enum.Font.SourceSansBold
	lbl.Text = emoji
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.4
	lbl.TextStrokeColor3 = Color3.fromRGB(20, 40, 10)
	lbl.Parent = bb

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local u = math.clamp((os.clock() - t0) / HAPPY_EXIT_SEC, 0, 1)
		local ease = 1 - (1 - u) * (1 - u)
		local goal = characterAimPos(startPos) + fanSide + fanUp
		anchor.CFrame = CFrame.new(startPos:Lerp(goal, ease))
		scale.Scale = HAPPY_EXIT_START_SCALE + (1 - HAPPY_EXIT_START_SCALE) * ease
		lbl.TextTransparency = u
		lbl.TextStrokeTransparency = 0.4 + 0.6 * u
		if u >= 1 then
			conn:Disconnect()
			if anchor.Parent then
				anchor:Destroy()
			end
		end
	end)
end

function WaveEndVfx.playReefHealthTicks(amount: number, endPos: Vector3?)
	if amount <= 0 then
		return
	end
	local at = endPos
	if not at then
		local heart = WaveEndVfx.getEndHeartPart()
		if heart then
			at = heart.Position
		end
	end
	for i = 1, amount do
		local pitch = math.max(REEF_TICK_PITCH_MIN, REEF_TICK_PITCH_START - reefTickStreak * REEF_TICK_PITCH_STEP)
		reefTickStreak += 1
		local delaySec = (i - 1) * REEF_TICK_GAP
		task.delay(delaySec, function()
			local snd = reefTickSound:Clone()
			snd.PlaybackSpeed = pitch
			snd.Volume = 0.95
			snd.Parent = SoundService
			snd:Play()
			local ttl = math.max(1.2, (snd.TimeLength > 0 and snd.TimeLength or 1) + 0.4)
			task.delay(ttl, function()
				if snd.Parent then
					snd:Destroy()
				end
			end)
			if at then
				pulseReefHeartLoss(at)
			end
		end)
	end
end

return WaveEndVfx
