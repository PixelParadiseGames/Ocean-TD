--!strict
--[[
	Join-intro load-bar bubbles only (separate from SkillsAmbientBubbles).
	While spawning: continuous dense rise from below.
	On stopSpawn: no new bubbles; on-screen ones keep rising off the top, then tear down.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local JoinIntroLoadBubbles = {}

local LAYER_NAME = "_OceanTD_JoinIntroLoadRise"
local COUNT = 36
local SIZE_MIN = 6
local SIZE_MAX = 52
local SPEED_MIN = 42
local SPEED_MAX = 110
local DRIFT_AMP = 12
local EXIT_CLEAR_PAD_SEC = 1.25
local EXIT_MAX_SEC = 22
local SPAWN_INTERVAL = 0.07

local BLUE_BRIGHT = Color3.fromRGB(150, 205, 255)
local BLUE_MID = Color3.fromRGB(55, 140, 215)
local BLUE_DEEP = Color3.fromRGB(25, 85, 165)
local CORE_COLOR = Color3.fromRGB(195, 230, 255)

type RiseBubble = {
	gui: Frame,
	sizePx: number,
	x: number,
	y: number,
	speed: number,
	phase: number,
	driftFreq: number,
}

local layer: Frame? = nil
local host: ScreenGui? = nil
local bubbles: { RiseBubble } = {}
local conn: RBXScriptConnection? = nil
local rng = Random.new()
local spawning = false
local exitMode = false
local exitToken = 0
local exitAllClearAt: number? = nil
local tClock = 0
local spawnAcc = 0

local function destroyLayer()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	table.clear(bubbles)
	if layer then
		layer:Destroy()
		layer = nil
	end
	host = nil
	spawning = false
	exitMode = false
	exitAllClearAt = nil
	spawnAcc = 0
end

local function screenSize(): (number, number)
	local f = layer
	if f and f.AbsoluteSize.X > 1 and f.AbsoluteSize.Y > 1 then
		return f.AbsoluteSize.X, f.AbsoluteSize.Y
	end
	local sg = host
	if sg and sg.AbsoluteSize.X > 1 and sg.AbsoluteSize.Y > 1 then
		return sg.AbsoluteSize.X, sg.AbsoluteSize.Y
	end
	local cam = Workspace.CurrentCamera
	if cam and cam.ViewportSize.X > 1 then
		return cam.ViewportSize.X, cam.ViewportSize.Y
	end
	return 800, 600
end

local function speedForSize(sizePx: number): number
	local t = math.clamp((sizePx - SIZE_MIN) / math.max(SIZE_MAX - SIZE_MIN, 1), 0, 1)
	return SPEED_MIN + (SPEED_MAX - SPEED_MIN) * (t * t * 0.35 + t * 0.65)
end

local function applyRadialLook(f: Frame, haze: number)
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.BackgroundTransparency = 0
	local grad = f:FindFirstChild("_OceanTD_RadialGrad")
	if not (grad and grad:IsA("UIGradient")) then
		if grad then
			grad:Destroy()
		end
		grad = Instance.new("UIGradient")
		grad.Name = "_OceanTD_RadialGrad"
		grad.Parent = f
	end
	;(grad :: UIGradient).Rotation = rng:NextNumber(110, 150)
	;(grad :: UIGradient).Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, BLUE_BRIGHT),
		ColorSequenceKeypoint.new(0.42, BLUE_MID),
		ColorSequenceKeypoint.new(1, BLUE_DEEP),
	})
	local edge = math.clamp(0.72 + haze * 0.18, 0.7, 0.92)
	local mid = math.clamp(0.42 + haze * 0.12, 0.4, 0.7)
	local center = math.clamp(0.22 + haze * 0.1, 0.18, 0.45)
	;(grad :: UIGradient).Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, center),
		NumberSequenceKeypoint.new(0.5, mid),
		NumberSequenceKeypoint.new(1, edge),
	})
	local core = f:FindFirstChild("_Core")
	if not (core and core:IsA("Frame")) then
		if core then
			core:Destroy()
		end
		core = Instance.new("Frame")
		core.Name = "_Core"
		core.AnchorPoint = Vector2.new(0.5, 0.5)
		core.Position = UDim2.fromScale(0.34, 0.30)
		core.Size = UDim2.fromScale(0.40, 0.40)
		core.BackgroundColor3 = CORE_COLOR
		core.BorderSizePixel = 0
		core.ZIndex = f.ZIndex + 1
		core.Active = false
		core.Parent = f
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(1, 0)
		cc.Parent = core
	end
	;(core :: Frame).BackgroundTransparency = math.clamp(0.35 + haze * 0.25, 0.3, 0.7)
end

local function makeBubbleGui(parent: Frame, sizePx: number): Frame
	local f = Instance.new("Frame")
	f.Name = "LoadBubble"
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromOffset(sizePx, sizePx)
	f.ZIndex = 1
	f.Active = false
	f.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Color = Color3.fromRGB(120, 190, 245)
	stroke.Transparency = 0.78
	stroke.Parent = f
	applyRadialLook(f, rng:NextNumber(0, 1))
	return f
end

local function spawnBelow(parent: Frame, belowFrac: number): RiseBubble
	local sw, sh = screenSize()
	local t = rng:NextNumber()
	local sizePx = SIZE_MIN + (SIZE_MAX - SIZE_MIN) * (t * t)
	local gui = makeBubbleGui(parent, sizePx)
	local x = rng:NextNumber(sizePx * 0.5, math.max(sizePx * 0.5 + 1, sw - sizePx * 0.5))
	local y = sh + sizePx * 0.5 + math.max(0, belowFrac) * sh
	local b: RiseBubble = {
		gui = gui,
		sizePx = sizePx,
		x = x,
		y = y,
		speed = speedForSize(sizePx) * rng:NextNumber(0.92, 1.08),
		phase = rng:NextNumber(0, math.pi * 2),
		driftFreq = rng:NextNumber(0.12, 0.35),
	}
	gui.Position = UDim2.fromOffset(b.x, b.y)
	return b
end

local function livingCount(): number
	local n = 0
	for _, b in ipairs(bubbles) do
		if b.gui.Parent then
			n += 1
		end
	end
	return n
end

local function bindHeartbeat()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	tClock = 0
	spawnAcc = 0
	-- RenderStepped so bubbles keep rising during join-intro cam pan (same cadence as applyIntroCam).
	conn = RunService.RenderStepped:Connect(function(dt)
		if not layer or not layer.Parent then
			return
		end
		local step = math.clamp(dt, 0, 0.1)
		tClock += step
		-- Continuous spawn while load bar is filling.
		if spawning and not exitMode then
			spawnAcc += step
			while spawnAcc >= SPAWN_INTERVAL and livingCount() < COUNT do
				spawnAcc -= SPAWN_INTERVAL
				table.insert(bubbles, spawnBelow(layer, rng:NextNumber(0.02, 0.35)))
			end
		end
		local allGone = true
		local alive: { RiseBubble } = {}
		for _, b in ipairs(bubbles) do
			if not b.gui.Parent then
				continue
			end
			b.y -= b.speed * step
			local drift = math.sin(tClock * b.driftFreq * math.pi * 2 + b.phase) * DRIFT_AMP
			b.gui.Position = UDim2.fromOffset(b.x + drift, b.y)
			local fullyOut = b.y + b.sizePx * 0.5 < -2
			if fullyOut then
				b.gui:Destroy()
			else
				allGone = false
				table.insert(alive, b)
			end
		end
		bubbles = alive
		if exitMode then
			if allGone then
				if exitAllClearAt == nil then
					exitAllClearAt = os.clock()
				elseif os.clock() - (exitAllClearAt :: number) >= EXIT_CLEAR_PAD_SEC then
					destroyLayer()
				end
			else
				exitAllClearAt = nil
			end
		end
	end)
end

function JoinIntroLoadBubbles.start(sg: ScreenGui)
	if layer and layer.Parent and conn and spawning and not exitMode and host == sg then
		return
	end
	destroyLayer()
	exitToken += 1
	host = sg
	sg.Enabled = true
	local existing = sg:FindFirstChild(LAYER_NAME)
	if existing then
		existing:Destroy()
	end
	local f = Instance.new("Frame")
	f.Name = LAYER_NAME
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Size = UDim2.fromScale(1, 1)
	f.ZIndex = 1
	f.Active = false
	f.ClipsDescendants = false
	f.Parent = sg
	layer = f
	spawning = true
	exitMode = false
	-- Seed a ladder under the fold so the stream is immediate + dense.
	for i = 1, COUNT do
		local belowFrac = ((i - 0.5) / COUNT) * 1.4
		table.insert(bubbles, spawnBelow(f, belowFrac))
	end
	bindHeartbeat()
end

-- Load bar full: stop spawning; let on-screen bubbles finish rising, then despawn.
function JoinIntroLoadBubbles.beginExit()
	spawning = false
	if not layer or not layer.Parent then
		destroyLayer()
		return
	end
	if #bubbles == 0 then
		destroyLayer()
		return
	end
	if exitMode then
		return
	end
	exitMode = true
	exitAllClearAt = nil
	exitToken += 1
	local my = exitToken
	if not conn then
		bindHeartbeat()
	end
	task.delay(EXIT_MAX_SEC, function()
		if my == exitToken and (exitMode or layer) then
			destroyLayer()
		end
	end)
end

function JoinIntroLoadBubbles.stop()
	exitToken += 1
	destroyLayer()
end

function JoinIntroLoadBubbles.isRunning(): boolean
	return layer ~= nil and conn ~= nil
end

function JoinIntroLoadBubbles.isExiting(): boolean
	return exitMode
end

return JoinIntroLoadBubbles
