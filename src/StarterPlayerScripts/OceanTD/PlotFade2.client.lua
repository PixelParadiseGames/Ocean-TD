--!strict
--[[
	Plot Fade 2 (saved) — distance/look-reactive teal screen vignette.
	Disabled while trying Plot Fade 1. Set ENABLED = true (and disable
	BuildDepthCurtain / Plot Fade 1) to restore this look.
]]

local ENABLED = false
if not ENABLED then
	return
end

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local GUI_NAME = "OceanTD_BuildDepthVignette"
local CC_NAME = "OceanTD_BuildDepthCC"

local DEPTH_TEAL = Color3.fromRGB(6, 38, 62)
local DEPTH_TEAL_DEEP = Color3.fromRGB(3, 18, 34)

local TWEEN_OUT = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- Edge band width as fraction of screen (scaled up slightly when far).
local EDGE_FRAC_NEAR = 0.2
local EDGE_FRAC_FAR = 0.4

-- Outside-plot XZ distance (studs) — kicks in right at the boundary, peaks quickly.
local DIST_SOFT = 0 -- start ramping as soon as you leave the footprint
local DIST_FULL = 28 -- full strength much closer to the plot edge

-- Looking at the plot: 1 = fully clear vignette when aimed at it.
local LOOK_FADE = 1
-- Dot product above this counts as "looking at plot" (starts fading earlier).
local LOOK_START = 0.05
local LOOK_FULL = 0.55 -- fully faded once look-at reaches this

-- BackgroundTransparency when intensity is 1 (lower = darker edge).
local BT_AT_FULL = 0
-- No forced floor — looking at the plot can clear the vignette completely.
local INTENSITY_MIN = 0
local INTENSITY_MAX = 1

-- Ease response when intensity rises (away) vs falls (toward / looking at plot).
local RISE_SPEED = 14
local FALL_SPEED = 8

local CC_SAT_FULL = -0.2
local CC_BRT_FULL = -0.1
local CC_CON_FULL = 0.08
local CC_TINT_FULL = Color3.fromRGB(200, 230, 255)

local active = false
local gui: ScreenGui? = nil
local edgeFrames: { Frame } = {}
local cc: ColorCorrectionEffect? = nil
local updateConn: RBXScriptConnection? = nil
local intensitySmoothed = 0
local tweenToken = 0

local atmosSaved: {
	Density: number,
	Offset: number,
	Color: Color3,
	Decay: Color3,
	Glare: number,
	Haze: number,
}? = nil

local function destroyGui()
	if gui then
		gui:Destroy()
		gui = nil
	end
	table.clear(edgeFrames)
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
	f.BackgroundColor3 = DEPTH_TEAL
	f.BorderSizePixel = 0
	f.Size = size
	f.Position = pos
	f.AnchorPoint = anchor
	f.BackgroundTransparency = 1
	f.ZIndex = 1
	f.Parent = parent

	local g = Instance.new("UIGradient")
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.4, 0.55),
		NumberSequenceKeypoint.new(0.75, 0.9),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, DEPTH_TEAL_DEEP),
		ColorSequenceKeypoint.new(0.5, DEPTH_TEAL),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(30, 80, 110)),
	})
	g.Rotation = gradRotation
	g.Parent = f

	return f
end

local function ensureGui(): ScreenGui
	local existing = playerGui:FindFirstChild(GUI_NAME)
	if existing and existing:IsA("ScreenGui") and #edgeFrames >= 4 then
		gui = existing
		return existing
	end
	destroyGui()

	local sg = Instance.new("ScreenGui")
	sg.Name = GUI_NAME
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 5
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Enabled = true
	sg.Parent = playerGui
	gui = sg

	local frac = EDGE_FRAC_NEAR
	table.insert(edgeFrames, addEdge(sg, "Top", UDim2.new(1, 0, frac, 0), UDim2.fromScale(0.5, 0), Vector2.new(0.5, 0), 90))
	table.insert(edgeFrames, addEdge(sg, "Bottom", UDim2.new(1, 0, frac, 0), UDim2.fromScale(0.5, 1), Vector2.new(0.5, 1), -90))
	table.insert(edgeFrames, addEdge(sg, "Left", UDim2.new(frac, 0, 1, 0), UDim2.fromScale(0, 0.5), Vector2.new(0, 0.5), 0))
	table.insert(edgeFrames, addEdge(sg, "Right", UDim2.new(frac, 0, 1, 0), UDim2.fromScale(1, 0.5), Vector2.new(1, 0.5), 180))

	return sg
end

local function ensureCC(): ColorCorrectionEffect
	local existing = Lighting:FindFirstChild(CC_NAME)
	if existing and existing:IsA("ColorCorrectionEffect") then
		cc = existing
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = CC_NAME
	effect.Enabled = true
	effect.Brightness = 0
	effect.Contrast = 0
	effect.Saturation = 0
	effect.TintColor = Color3.new(1, 1, 1)
	effect.Parent = Lighting
	cc = effect
	return effect
end

local function saveAtmosphere()
	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atm then
		atmosSaved = nil
		return
	end
	atmosSaved = {
		Density = atm.Density,
		Offset = atm.Offset,
		Color = atm.Color,
		Decay = atm.Decay,
		Glare = atm.Glare,
		Haze = atm.Haze,
	}
end

local function restoreAtmosphere(info: TweenInfo?)
	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atm or not atmosSaved then
		return
	end
	local props = {
		Density = atmosSaved.Density,
		Offset = atmosSaved.Offset,
		Color = atmosSaved.Color,
		Decay = atmosSaved.Decay,
		Glare = atmosSaved.Glare,
		Haze = atmosSaved.Haze,
	}
	if info then
		TweenService:Create(atm, info, props):Play()
	else
		atm.Density = props.Density
		atm.Offset = props.Offset
		atm.Color = props.Color
		atm.Decay = props.Decay
		atm.Glare = props.Glare
		atm.Haze = props.Haze
	end
end

-- Horizontal distance outside the plot footprint (0 while inside / on the edge).
local function outsidePlotDistance(camPos: Vector3, cf: CFrame, size: Vector3): number
	local localPos = cf:PointToObjectSpace(camPos)
	local hx = size.X * 0.5
	local hz = size.Z * 0.5
	local dx = math.max(math.abs(localPos.X) - hx, 0)
	local dz = math.max(math.abs(localPos.Z) - hz, 0)
	return math.sqrt(dx * dx + dz * dz)
end

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / math.max(edge1 - edge0, 1e-3), 0, 1)
	return t * t * (3 - 2 * t)
end

local function computeIntensity(): number
	local plot = ClientPlot.get()
	local cam = Workspace.CurrentCamera
	if not plot or not cam then
		return INTENSITY_MAX
	end

	local camPos = cam.CFrame.Position
	local plotCf = plot.cframe
	local plotSize = plot.size
	local center = plotCf.Position

	local outside = outsidePlotDistance(camPos, plotCf, plotSize)
	-- Ease-in-out, then square so strength climbs faster just past the boundary.
	local distT = smoothstep(DIST_SOFT, DIST_FULL, outside)
	distT = distT * distT

	-- Looking at the plot: fully fade vignette out; looking away keeps distance murk.
	local toPlot = center - camPos
	local toPlotFlat = Vector3.new(toPlot.X, 0, toPlot.Z)
	local lookFlat = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
	local lookAt = 0
	if toPlotFlat.Magnitude > 1e-2 and lookFlat.Magnitude > 1e-2 then
		lookAt = lookFlat.Unit:Dot(toPlotFlat.Unit)
	elseif outside <= 0 then
		-- Inside the footprint: aimed at plot center / into the reef counts as looking in.
		local toCenter = center - camPos
		if toCenter.Magnitude > 1e-2 then
			lookAt = cam.CFrame.LookVector:Dot(toCenter.Unit)
		else
			lookAt = 1
		end
	end
	-- 0 when looking away, 1 when looking at the plot → wipe intensity.
	local lookFade = smoothstep(LOOK_START, LOOK_FULL, lookAt) * LOOK_FADE
	local intensity = distT * (1 - lookFade)

	-- Inside the plot and looking in → fully clear.
	if outside <= 0 and lookFade > 0.85 then
		intensity = 0
	end

	return math.clamp(intensity, INTENSITY_MIN, INTENSITY_MAX)
end

local function applyIntensity(intensity: number)
	ensureGui()
	local effect = ensureCC()

	-- BT: 1 = invisible, BT_AT_FULL = strongest edge.
	local bt = 1 - intensity * (1 - BT_AT_FULL)
	local edgeFrac = EDGE_FRAC_NEAR + (EDGE_FRAC_FAR - EDGE_FRAC_NEAR) * intensity

	for _, f in ipairs(edgeFrames) do
		f.BackgroundTransparency = bt
		if f.Name == "Top" or f.Name == "Bottom" then
			f.Size = UDim2.new(1, 0, edgeFrac, 0)
		else
			f.Size = UDim2.new(edgeFrac, 0, 1, 0)
		end
	end

	effect.Enabled = true
	effect.Saturation = CC_SAT_FULL * intensity
	effect.Brightness = CC_BRT_FULL * intensity
	effect.Contrast = CC_CON_FULL * intensity
	effect.TintColor = Color3.new(1, 1, 1):Lerp(CC_TINT_FULL, intensity)

	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if atm and atmosSaved then
		atm.Density = math.clamp(atmosSaved.Density + 0.22 * intensity, 0, 1)
		atm.Haze = math.clamp(atmosSaved.Haze + 1.6 * intensity, 0, 10)
		atm.Color = atmosSaved.Color:Lerp(DEPTH_TEAL, 0.55 * intensity)
		atm.Decay = atmosSaved.Decay:Lerp(DEPTH_TEAL_DEEP, 0.5 * intensity)
		atm.Glare = math.clamp(atmosSaved.Glare * (1 - 0.4 * intensity), 0, 10)
	end
end

local function stopUpdate()
	if updateConn then
		updateConn:Disconnect()
		updateConn = nil
	end
end

local function startUpdate()
	stopUpdate()
	updateConn = RunService.RenderStepped:Connect(function(dt)
		if not active then
			return
		end
		local target = computeIntensity()
		-- Snap up fast when leaving the plot; ease down slower when returning.
		local speed = if target > intensitySmoothed then RISE_SPEED else FALL_SPEED
		local alpha = 1 - math.exp(-dt * speed)
		intensitySmoothed += (target - intensitySmoothed) * alpha
		applyIntensity(intensitySmoothed)
	end)
end

local function setEnabled(on: boolean)
	if on and not ClientPlot.get() then
		on = false
	end
	if on == active then
		if on then
			ensureGui()
			startUpdate()
		end
		return
	end
	tweenToken += 1
	local token = tweenToken

	if on then
		active = true
		if not atmosSaved then
			saveAtmosphere()
		end
		ensureGui()
		intensitySmoothed = computeIntensity()
		applyIntensity(intensitySmoothed)
		startUpdate()
	else
		active = false
		stopUpdate()
		-- Fade vignette / grade out, then clean up.
		local startI = intensitySmoothed
		local t0 = os.clock()
		local dur = TWEEN_OUT.Time
		local fadeConn: RBXScriptConnection
		fadeConn = RunService.RenderStepped:Connect(function()
			if token ~= tweenToken then
				fadeConn:Disconnect()
				return
			end
			local u = math.clamp((os.clock() - t0) / dur, 0, 1)
			local i = startI * (1 - u)
			applyIntensity(i)
			if u >= 1 then
				fadeConn:Disconnect()
				restoreAtmosphere(nil)
				if cc then
					cc:Destroy()
					cc = nil
				end
				destroyGui()
				intensitySmoothed = 0
			end
		end)
	end
end

InventoryState.onOpenChanged(function(isOpen: boolean)
	setEnabled(isOpen == true)
end)

ClientPlot.onChanged(function()
	if active and not ClientPlot.get() then
		setEnabled(false)
	elseif InventoryState.isOpen() and ClientPlot.get() then
		setEnabled(true)
	end
end)

if InventoryState.isOpen() then
	setEnabled(true)
end
