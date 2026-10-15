--!strict
--[[
	Decorative rising bubbles behind MobileSkillsA BackgroundGradient.
	Active only while skills are open. Larger bubbles rise a bit faster.
	On close: stop recycling and accelerate upward off-screen, then tear down.
]]

local RunService = game:GetService("RunService")

local SkillsAmbientBubbles = {}

local LAYER_NAME = "_OceanTD_AmbientRiseLayer"
local COUNT_MIN = 10
local COUNT_MAX = 20
local SIZE_MIN = 4
local SIZE_MAX = 48
-- px/sec at SIZE_MIN / SIZE_MAX — larger slightly quicker.
local SPEED_MIN = 38
local SPEED_MAX = 95
local EXIT_SPEED_MULT_MIN = 3.2
local EXIT_SPEED_MULT_MAX = 5.0
local EXIT_MAX_SEC = 1.5
local DRIFT_AMP = 10

-- Slight blue family (white base so UIGradient colors read true).
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
local exitMode = false
local exitToken = 0
local tClock = 0

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
	exitMode = false
end

local function screenSize(): (number, number)
	local f = layer
	if f and f.AbsoluteSize.X > 1 and f.AbsoluteSize.Y > 1 then
		return f.AbsoluteSize.X, f.AbsoluteSize.Y
	end
	local sg = host
	if sg and sg.AbsoluteSize.X > 1 then
		return sg.AbsoluteSize.X, sg.AbsoluteSize.Y
	end
	return 800, 600
end

local function speedForSize(sizePx: number): number
	local t = math.clamp((sizePx - SIZE_MIN) / math.max(SIZE_MAX - SIZE_MIN, 1), 0, 1)
	local u = t * t * 0.35 + t * 0.65
	return SPEED_MIN + (SPEED_MAX - SPEED_MIN) * u
end

-- Bias toward smaller bubbles (t^2).
local function rollSizePx(): number
	local t = rng:NextNumber()
	t = t * t
	return SIZE_MIN + (SIZE_MAX - SIZE_MIN) * t
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

local function makeBubbleGui(parent: Frame, sizePx: number, z: number, haze: number): Frame
	local f = Instance.new("Frame")
	f.Name = "AmbientBubble"
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromOffset(sizePx, sizePx)
	f.ZIndex = z
	f.Active = false
	f.Selectable = false
	f.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Color = Color3.fromRGB(120, 190, 245)
	stroke.Transparency = 0.78
	stroke.Parent = f

	applyRadialLook(f, haze)
	return f
end

local function spawnBubble(parent: Frame, fromBottom: boolean): RiseBubble
	local sw, sh = screenSize()
	local sizePx = rollSizePx()
	local haze = rng:NextNumber(0, 1)
	local gui = makeBubbleGui(parent, sizePx, 1, haze)

	local x = rng:NextNumber(sizePx * 0.5, math.max(sizePx * 0.5 + 1, sw - sizePx * 0.5))
	local y: number
	if fromBottom then
		y = sh + sizePx * 0.5 + rng:NextNumber(0, sh * 0.35)
	else
		y = rng:NextNumber(-sizePx, sh + sizePx)
	end

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

local function recycleBubble(b: RiseBubble)
	local sw, sh = screenSize()
	local sizePx = rollSizePx()
	local haze = rng:NextNumber(0, 1)
	b.sizePx = sizePx
	b.speed = speedForSize(sizePx) * rng:NextNumber(0.92, 1.08)
	b.phase = rng:NextNumber(0, math.pi * 2)
	b.driftFreq = rng:NextNumber(0.12, 0.35)
	b.x = rng:NextNumber(sizePx * 0.5, math.max(sizePx * 0.5 + 1, sw - sizePx * 0.5))
	b.y = sh + sizePx * 0.5 + rng:NextNumber(0, sh * 0.25)
	b.gui.Size = UDim2.fromOffset(sizePx, sizePx)
	applyRadialLook(b.gui, haze)
end

local function ensureLayer(sg: ScreenGui): Frame
	local existing = sg:FindFirstChild(LAYER_NAME)
	if existing and existing:IsA("Frame") then
		existing:ClearAllChildren()
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local f = Instance.new("Frame")
	f.Name = LAYER_NAME
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Size = UDim2.fromScale(1, 1)
	f.Position = UDim2.fromScale(0, 0)
	f.AnchorPoint = Vector2.new(0, 0)
	f.ZIndex = 0
	f.Active = false
	f.Selectable = false
	f.ClipsDescendants = true
	f.Parent = sg
	return f
end

local function bindHeartbeat()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	tClock = 0
	conn = RunService.Heartbeat:Connect(function(dt)
		if not layer or not layer.Parent then
			return
		end
		tClock += dt
		local allGone = true
		for _, b in ipairs(bubbles) do
			if not b.gui.Parent then
				continue
			end
			b.y -= b.speed * dt
			local drift = math.sin(tClock * b.driftFreq * math.pi * 2 + b.phase) * DRIFT_AMP
			b.gui.Position = UDim2.fromOffset(b.x + drift, b.y)
			if exitMode then
				if b.y + b.sizePx * 0.5 >= -12 then
					allGone = false
				end
			else
				allGone = false
				if b.y + b.sizePx * 0.5 < -8 then
					recycleBubble(b)
				else
					local _sw, sh = screenSize()
					if b.y > sh + b.sizePx * 2 then
						recycleBubble(b)
					end
				end
			end
		end
		if exitMode and allGone then
			destroyLayer()
		end
	end)
end

function SkillsAmbientBubbles.start(sg: ScreenGui, bgGui: GuiObject?)
	destroyLayer()
	exitToken += 1
	host = sg
	if bgGui then
		bgGui.ZIndex = math.max(bgGui.ZIndex, 1)
	end
	local f = ensureLayer(sg)
	layer = f

	local n = rng:NextInteger(COUNT_MIN, COUNT_MAX)
	for _ = 1, n do
		table.insert(bubbles, spawnBubble(f, false))
	end
	bindHeartbeat()
end

-- Soft close: accelerate upward off the top (no recycle), then destroy layer.
function SkillsAmbientBubbles.beginExit()
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
	exitToken += 1
	local my = exitToken
	-- Ensure heartbeat is alive for the rush-out.
	if not conn then
		bindHeartbeat()
	end
	for _, b in ipairs(bubbles) do
		-- Floor so even slow bubbles clear the top quickly.
		local boost = rng:NextNumber(EXIT_SPEED_MULT_MIN, EXIT_SPEED_MULT_MAX)
		b.speed = math.max(b.speed * boost, 220)
		if b.gui.Parent then
			b.gui.Visible = true
		end
	end
	-- Safety: hard teardown if something stalls.
	task.delay(EXIT_MAX_SEC, function()
		if my == exitToken and (exitMode or layer) then
			destroyLayer()
		end
	end)
end

function SkillsAmbientBubbles.stop()
	exitToken += 1
	destroyLayer()
end

function SkillsAmbientBubbles.isRunning(): boolean
	return layer ~= nil and conn ~= nil
end

function SkillsAmbientBubbles.isExiting(): boolean
	return exitMode
end

return SkillsAmbientBubbles
