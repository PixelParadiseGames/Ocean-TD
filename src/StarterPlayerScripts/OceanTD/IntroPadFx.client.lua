--!strict
--[[
	While standing on the remapped IntroPosition pad for this plot:
	- Green glow around screen edges
	- Green rising bubbles with "$D" text (skills-ambient style)
	Server grants free $D purchases on this pad (see PersistenceService + IntroPad).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IntroPad = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("IntroPad"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local GUI_NAME = "OceanTD_IntroPadFx"
local BUBBLE_LAYER = "_OceanTD_IntroPadBubbles"

local GREEN_BRIGHT = Color3.fromRGB(120, 255, 160)
local GREEN_MID = Color3.fromRGB(40, 200, 90)
local GREEN_DEEP = Color3.fromRGB(10, 110, 50)
local EDGE_GREEN = Color3.fromRGB(30, 180, 80)
local EDGE_GREEN_DEEP = Color3.fromRGB(8, 90, 40)

local COUNT_MIN = 12
local COUNT_MAX = 18
local SIZE_MIN = 28
local SIZE_MAX = 64
local SPEED_MIN = 42
local SPEED_MAX = 88
local DRIFT_AMP = 12
local EDGE_FRAC = 0.16
local FADE_SPEED = 10

type RiseBubble = {
	gui: Frame,
	sizePx: number,
	x: number,
	y: number,
	speed: number,
	phase: number,
	driftFreq: number,
}

local gui: ScreenGui? = nil
local edgeFrames: { Frame } = {}
local bubbleLayer: Frame? = nil
local bubbles: { RiseBubble } = {}
local conn: RBXScriptConnection? = nil
local intensity = 0
local wantOn = false
local lastOn = false
local statusAcc = 0
local rng = Random.new()
local tClock = 0

-- Visual teardown only — never disconnect RenderStepped here (that freezes $D bubbles on screen).
local function clearVisuals()
	table.clear(bubbles)
	table.clear(edgeFrames)
	if gui then
		gui:Destroy()
		gui = nil
	end
	bubbleLayer = nil
	intensity = 0
end

local function addEdge(
	parent: Instance,
	name: string,
	size: UDim2,
	pos: UDim2,
	anchor: Vector2,
	gradRotation: number
): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = EDGE_GREEN
	f.BorderSizePixel = 0
	f.Size = size
	f.Position = pos
	f.AnchorPoint = anchor
	f.BackgroundTransparency = 1
	f.ZIndex = 1
	f.Active = false
	f.Parent = parent

	local g = Instance.new("UIGradient")
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.35, 0.45),
		NumberSequenceKeypoint.new(0.7, 0.85),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, EDGE_GREEN_DEEP),
		ColorSequenceKeypoint.new(0.45, EDGE_GREEN),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(60, 220, 120)),
	})
	g.Rotation = gradRotation
	g.Parent = f
	return f
end

local function applyBubbleLook(f: Frame, haze: number)
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
		ColorSequenceKeypoint.new(0, GREEN_BRIGHT),
		ColorSequenceKeypoint.new(0.45, GREEN_MID),
		ColorSequenceKeypoint.new(1, GREEN_DEEP),
	})
	local edge = math.clamp(0.68 + haze * 0.2, 0.65, 0.9)
	local mid = math.clamp(0.38 + haze * 0.12, 0.35, 0.65)
	local center = math.clamp(0.18 + haze * 0.1, 0.15, 0.4)
	;(grad :: UIGradient).Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, center),
		NumberSequenceKeypoint.new(0.5, mid),
		NumberSequenceKeypoint.new(1, edge),
	})

	local corner = f:FindFirstChildOfClass("UICorner")
	if not corner then
		corner = Instance.new("UICorner")
		corner.Parent = f
	end
	corner.CornerRadius = UDim.new(1, 0)

	local lbl = f:FindFirstChild("_OceanTD_DollarLabel")
	if not (lbl and lbl:IsA("TextLabel")) then
		if lbl then
			lbl:Destroy()
		end
		lbl = Instance.new("TextLabel")
		lbl.Name = "_OceanTD_DollarLabel"
		lbl.BackgroundTransparency = 1
		lbl.Size = UDim2.fromScale(0.85, 0.55)
		lbl.Position = UDim2.fromScale(0.5, 0.5)
		lbl.AnchorPoint = Vector2.new(0.5, 0.5)
		lbl.Font = Enum.Font.GothamBold
		lbl.Text = "$D"
		lbl.TextColor3 = Color3.fromRGB(235, 255, 240)
		lbl.TextStrokeColor3 = Color3.fromRGB(10, 60, 25)
		lbl.TextStrokeTransparency = 0.35
		lbl.TextScaled = true
		lbl.ZIndex = f.ZIndex + 2
		lbl.Parent = f
	end
	;(lbl :: TextLabel).TextTransparency = math.clamp(0.05 + haze * 0.25, 0.05, 0.4)
end

local function screenSize(): (number, number)
	local f = bubbleLayer
	if f and f.AbsoluteSize.X > 1 then
		return f.AbsoluteSize.X, f.AbsoluteSize.Y
	end
	local sg = gui
	if sg and sg.AbsoluteSize.X > 1 then
		return sg.AbsoluteSize.X, sg.AbsoluteSize.Y
	end
	return 800, 600
end

local function speedForSize(sizePx: number): number
	local t = math.clamp((sizePx - SIZE_MIN) / math.max(SIZE_MAX - SIZE_MIN, 1), 0, 1)
	return SPEED_MIN + (SPEED_MAX - SPEED_MIN) * t
end

local function rollSizePx(): number
	local t = rng:NextNumber()
	t = t * t
	return SIZE_MIN + (SIZE_MAX - SIZE_MIN) * t
end

local function recycleBubble(b: RiseBubble)
	local sw, sh = screenSize()
	local sizePx = rollSizePx()
	local haze = rng:NextNumber(0, 1)
	b.sizePx = sizePx
	b.speed = speedForSize(sizePx)
	b.phase = rng:NextNumber(0, math.pi * 2)
	b.driftFreq = rng:NextNumber(0.15, 0.45)
	b.x = rng:NextNumber(sizePx, math.max(sizePx + 1, sw - sizePx))
	b.y = sh + sizePx * 0.5 + rng:NextNumber(0, sh * 0.35)
	b.gui.Size = UDim2.fromOffset(sizePx, sizePx)
	b.gui.Position = UDim2.fromOffset(b.x, b.y)
	b.gui.ZIndex = 2 + math.floor(haze * 3)
	applyBubbleLook(b.gui, haze)
end

local function spawnBubble(parent: Frame): RiseBubble
	local f = Instance.new("Frame")
	f.Name = "IntroPadBubble"
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Active = false
	f.Parent = parent
	local b: RiseBubble = {
		gui = f,
		sizePx = 32,
		x = 0,
		y = 0,
		speed = SPEED_MIN,
		phase = 0,
		driftFreq = 0.25,
	}
	recycleBubble(b)
	local _sw, sh = screenSize()
	b.y = rng:NextNumber(sh * 0.15, sh + b.sizePx)
	b.gui.Position = UDim2.fromOffset(b.x, b.y)
	return b
end

local function ensureGui()
	if gui and gui.Parent then
		return
	end
	clearVisuals()
	local sg = Instance.new("ScreenGui")
	sg.Name = GUI_NAME
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 120
	sg.ResetOnSpawn = false
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		(sg :: any).ScreenInsets = Enum.ScreenInsets.None
	end)
	sg.Parent = playerGui
	gui = sg

	local e = EDGE_FRAC
	table.insert(edgeFrames, addEdge(sg, "Top", UDim2.new(1, 0, e, 0), UDim2.fromScale(0.5, 0), Vector2.new(0.5, 0), 90))
	table.insert(edgeFrames, addEdge(sg, "Bottom", UDim2.new(1, 0, e, 0), UDim2.fromScale(0.5, 1), Vector2.new(0.5, 1), -90))
	table.insert(edgeFrames, addEdge(sg, "Left", UDim2.new(e, 0, 1, 0), UDim2.fromScale(0, 0.5), Vector2.new(0, 0.5), 0))
	table.insert(edgeFrames, addEdge(sg, "Right", UDim2.new(e, 0, 1, 0), UDim2.fromScale(1, 0.5), Vector2.new(1, 0.5), 180))

	local layer = Instance.new("Frame")
	layer.Name = BUBBLE_LAYER
	layer.BackgroundTransparency = 1
	layer.BorderSizePixel = 0
	layer.Size = UDim2.fromScale(1, 1)
	layer.Position = UDim2.fromScale(0, 0)
	layer.ZIndex = 2
	layer.Active = false
	layer.ClipsDescendants = true
	layer.Parent = sg
	bubbleLayer = layer

	local n = rng:NextInteger(COUNT_MIN, COUNT_MAX)
	for _ = 1, n do
		table.insert(bubbles, spawnBubble(layer))
	end
end

local function setEdgeIntensity(a: number)
	local inv = 1 - math.clamp(a, 0, 1)
	local bt = 0.12 + inv * 0.88
	for _, f in ipairs(edgeFrames) do
		f.BackgroundTransparency = bt
	end
	if bubbleLayer then
		bubbleLayer.Visible = a > 0.02
	end
end

local function bindLoop()
	if conn then
		return
	end
	tClock = 0
	conn = RunService.RenderStepped:Connect(function(dt)
		-- Local HRP vs remapped pad only — ignore sticky server ON_PAD_ATTR for FX.
		wantOn = IntroPad.isPlayerOnPad(player)
		if player:GetAttribute("OceanTD_OnIntroPadClient") ~= wantOn then
			player:SetAttribute("OceanTD_OnIntroPadClient", wantOn)
		end

		if wantOn ~= lastOn then
			lastOn = wantOn
			print("[IntroPadFx]", if wantOn then "ENTER" else "LEAVE", IntroPad.debugStatus(player))
			if not wantOn then
				clearVisuals()
				return
			end
		end

		statusAcc += dt
		if statusAcc >= 6 then
			statusAcc = 0
			if #IntroPad.getPadWorldPositionsForPlayer(player) == 0 then
				print("[IntroPadFx] waiting for pad…", IntroPad.debugStatus(player))
			end
		end

		if not wantOn then
			if gui then
				clearVisuals()
			end
			return
		end

		intensity = math.min(1, intensity + dt * FADE_SPEED)
		ensureGui()
		setEdgeIntensity(intensity)

		if not bubbleLayer or #bubbles == 0 then
			return
		end
		tClock += dt
		local _sw, sh = screenSize()
		for _, b in ipairs(bubbles) do
			if not b.gui.Parent then
				continue
			end
			b.y -= b.speed * dt
			local drift = math.sin(tClock * b.driftFreq * math.pi * 2 + b.phase) * DRIFT_AMP
			b.gui.Position = UDim2.fromOffset(b.x + drift, b.y)
			b.gui.Visible = true
			if b.y + b.sizePx * 0.5 < -12 then
				recycleBubble(b)
			elseif b.y > sh + b.sizePx * 2.5 then
				recycleBubble(b)
			end
		end
	end)
end

bindLoop()
player.CharacterAdded:Connect(function()
	lastOn = false
	clearVisuals()
end)

task.spawn(function()
	local deadline = os.clock() + 30
	while os.clock() < deadline do
		if IntroPad.getPadWorldPosForPlayer(player) then
			break
		end
		task.wait(0.4)
	end
	print("[IntroPadFx] Ready —", IntroPad.debugStatus(player))
end)
