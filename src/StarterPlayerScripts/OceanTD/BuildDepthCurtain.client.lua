--!strict
--[[
	Plot Fade 1 — soft world Lighting / ColorCorrection / Atmosphere dim.
	Mild long falloff, but starts at the plot rim (visible while looking at the
	plot — no look-away gate). Center fill light keeps the reef bright.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))

local CC_NAME = "OceanTD_PlotFade1CC"
local LIGHT_NAME = "OceanTD_PlotFade1Light"

local DEPTH_TEAL = Color3.fromRGB(10, 45, 70)
local DEPTH_TEAL_DEEP = Color3.fromRGB(5, 25, 42)

-- Outside: mild full strength a bit past the edge (long / gentle peak).
local DIST_SOFT = 0
local DIST_FULL = 40

-- Inside: start fading as you near the rim so the edge murk is visible while
-- still looking at the plot (studs from boundary toward center).
local INSIDE_EDGE_START = 28 -- within this of the rim → fade begins
local INSIDE_EDGE_FULL = 4 -- near the rim → edge fade strength
local INSIDE_EDGE_PEAK = 0.5 -- max intensity from inside-edge alone

local RISE_SPEED = 9
local FALL_SPEED = 7

-- Soft fill light over the plot so the reef stays readable while the world dims.
local PLOT_LIGHT_COLOR = Color3.fromRGB(210, 235, 255)
local PLOT_LIGHT_BRIGHTNESS = 3.0
local PLOT_LIGHT_RANGE_PAD = 8 -- studs past half-diagonal of plot footprint

-- Mild world dim at full intensity (restored from pre-strong pass).
local BRIGHTNESS_MUL = 0.78
local AMBIENT_BLEND = 0.4
local OUTDOOR_BLEND = 0.45
local AMBIENT_DARKEN = 0.85

local CC_SAT_FULL = -0.12
local CC_BRT_FULL = -0.1
local CC_CON_FULL = 0.07
local CC_TINT_FULL = Color3.fromRGB(200, 228, 248)

local active = false
local cc: ColorCorrectionEffect? = nil
local plotLightHost: BasePart? = nil
local plotLight: PointLight? = nil
local updateConn: RBXScriptConnection? = nil
local intensitySmoothed = 0
local tweenToken = 0

local lightingSaved: {
	Brightness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	ColorShift_Top: Color3,
	ColorShift_Bottom: Color3,
}? = nil

local atmosSaved: {
	Density: number,
	Offset: number,
	Color: Color3,
	Decay: Color3,
	Glare: number,
	Haze: number,
}? = nil

local function scaleColor(c: Color3, s: number): Color3
	return Color3.new(
		math.clamp(c.R * s, 0, 1),
		math.clamp(c.G * s, 0, 1),
		math.clamp(c.B * s, 0, 1)
	)
end

local function saveLighting()
	lightingSaved = {
		Brightness = Lighting.Brightness,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		ColorShift_Top = Lighting.ColorShift_Top,
		ColorShift_Bottom = Lighting.ColorShift_Bottom,
	}
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

-- outsideDist (>=0), insideDistToEdge (>=0 when inside; 0 on/outside rim).
local function plotEdgeDistances(camPos: Vector3, cf: CFrame, size: Vector3): (number, number)
	local localPos = cf:PointToObjectSpace(camPos)
	local hx = size.X * 0.5
	local hz = size.Z * 0.5
	local ax = math.abs(localPos.X)
	local az = math.abs(localPos.Z)
	local dx = ax - hx
	local dz = az - hz
	if dx <= 0 and dz <= 0 then
		return 0, math.min(-dx, -dz)
	end
	local ox = math.max(dx, 0)
	local oz = math.max(dz, 0)
	return math.sqrt(ox * ox + oz * oz), 0
end

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / math.max(edge1 - edge0, 1e-3), 0, 1)
	return t * t * (3 - 2 * t)
end

local function computeIntensity(): number
	local plot = ClientPlot.get()
	local cam = Workspace.CurrentCamera
	if not plot or not cam then
		return 1
	end

	local outside, insideToEdge = plotEdgeDistances(cam.CFrame.Position, plot.cframe, plot.size)

	-- Outside: smoothstep only (no extra square) for a softer feather.
	local outsideT = smoothstep(DIST_SOFT, DIST_FULL, outside)

	-- Inside: fade kicks in near the rim so you see murk around the plot edge
	-- while still looking at the reef (no look-away required).
	local insideT = 0
	if outside <= 0 then
		-- insideToEdge large in center → 0; small near rim → peak.
		insideT = (1 - smoothstep(INSIDE_EDGE_FULL, INSIDE_EDGE_START, insideToEdge)) * INSIDE_EDGE_PEAK
	end

	return math.clamp(math.max(outsideT, insideT), 0, 1)
end

local function applyIntensity(intensity: number)
	if not lightingSaved then
		saveLighting()
	end
	local base = lightingSaved
	if not base then
		return
	end

	-- intensity 0 → exact saved (normal) lighting; 1 → full build dim.
	local i = intensity
	Lighting.Brightness = base.Brightness * (1 - (1 - BRIGHTNESS_MUL) * i)
	Lighting.Ambient = scaleColor(base.Ambient:Lerp(DEPTH_TEAL, AMBIENT_BLEND * i), 1 - (1 - AMBIENT_DARKEN) * i)
	Lighting.OutdoorAmbient = scaleColor(base.OutdoorAmbient:Lerp(DEPTH_TEAL_DEEP, OUTDOOR_BLEND * i), 1 - (1 - AMBIENT_DARKEN) * i)
	Lighting.ColorShift_Top = base.ColorShift_Top:Lerp(DEPTH_TEAL, 0.28 * i)
	Lighting.ColorShift_Bottom = base.ColorShift_Bottom:Lerp(DEPTH_TEAL_DEEP, 0.38 * i)

	local effect = ensureCC()
	effect.Enabled = i > 0.001
	effect.Saturation = CC_SAT_FULL * i
	effect.Brightness = CC_BRT_FULL * i
	effect.Contrast = CC_CON_FULL * i
	effect.TintColor = Color3.new(1, 1, 1):Lerp(CC_TINT_FULL, i)

	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if atm then
		if not atmosSaved then
			saveAtmosphere()
		end
		local ab = atmosSaved
		if ab then
			atm.Density = math.clamp(ab.Density + 0.18 * i, 0, 1)
			atm.Haze = math.clamp(ab.Haze + 1.2 * i, 0, 10)
			atm.Color = ab.Color:Lerp(DEPTH_TEAL, 0.45 * i)
			atm.Decay = ab.Decay:Lerp(DEPTH_TEAL_DEEP, 0.4 * i)
			atm.Glare = math.clamp(ab.Glare * (1 - 0.35 * i), 0, 10)
		end
	end
end

local function destroyPlotLight()
	if plotLightHost then
		plotLightHost:Destroy()
	end
	plotLightHost = nil
	plotLight = nil
end

local function layoutPlotLight()
	local plot = ClientPlot.get()
	if not plot or not plotLightHost or not plotLight then
		return
	end
	local size = plot.size
	local halfDiag = 0.5 * math.sqrt(size.X * size.X + size.Z * size.Z)
	-- Slightly above the plot bed so it fills the reef without clipping the floor.
	plotLightHost.CFrame = plot.cframe * CFrame.new(0, math.max(size.Y * 0.15, 4), 0)
	plotLight.Range = halfDiag + PLOT_LIGHT_RANGE_PAD
	plotLight.Brightness = PLOT_LIGHT_BRIGHTNESS
	plotLight.Color = PLOT_LIGHT_COLOR
end

local function ensurePlotLight()
	if plotLightHost and plotLightHost.Parent and plotLight then
		layoutPlotLight()
		return
	end
	destroyPlotLight()
	local host = Instance.new("Part")
	host.Name = LIGHT_NAME
	host.Anchored = true
	host.CanCollide = false
	host.CanQuery = false
	host.CanTouch = false
	host.CastShadow = false
	host.Transparency = 1
	host.Size = Vector3.new(0.2, 0.2, 0.2)
	host.Parent = Workspace
	local light = Instance.new("PointLight")
	light.Name = "Fill"
	light.Shadows = false
	light.Parent = host
	plotLightHost = host
	plotLight = light
	layoutPlotLight()
end

local function restoreExact()
	if lightingSaved then
		Lighting.Brightness = lightingSaved.Brightness
		Lighting.Ambient = lightingSaved.Ambient
		Lighting.OutdoorAmbient = lightingSaved.OutdoorAmbient
		Lighting.ColorShift_Top = lightingSaved.ColorShift_Top
		Lighting.ColorShift_Bottom = lightingSaved.ColorShift_Bottom
	end
	if atmosSaved then
		local atm = Lighting:FindFirstChildOfClass("Atmosphere")
		if atm then
			atm.Density = atmosSaved.Density
			atm.Offset = atmosSaved.Offset
			atm.Color = atmosSaved.Color
			atm.Decay = atmosSaved.Decay
			atm.Glare = atmosSaved.Glare
			atm.Haze = atmosSaved.Haze
		end
	end
	if cc then
		cc:Destroy()
		cc = nil
	end
	destroyPlotLight()
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
		local speed = if target > intensitySmoothed then RISE_SPEED else FALL_SPEED
		local alpha = 1 - math.exp(-dt * speed)
		intensitySmoothed += (target - intensitySmoothed) * alpha
		applyIntensity(intensitySmoothed)
		layoutPlotLight()
	end)
end

local function isPlotSizeStage1(): boolean
	return SkillPowerUpUI.getStage("PlotSize") <= 1
end

local function wantEnabled(): boolean
	return InventoryState.isOpen() == true and ClientPlot.get() ~= nil and isPlotSizeStage1()
end

local function setEnabled(on: boolean)
	if on and not wantEnabled() then
		on = false
	end
	if on == active then
		if on then
			ensurePlotLight()
			startUpdate()
		end
		return
	end
	tweenToken += 1
	local token = tweenToken

	if on then
		active = true
		saveLighting()
		saveAtmosphere()
		ensurePlotLight()
		intensitySmoothed = computeIntensity()
		applyIntensity(intensitySmoothed)
		startUpdate()
	else
		active = false
		stopUpdate()
		local startI = intensitySmoothed
		local t0 = os.clock()
		local dur = 0.4
		local fadeConn: RBXScriptConnection
		fadeConn = RunService.RenderStepped:Connect(function()
			if token ~= tweenToken then
				fadeConn:Disconnect()
				return
			end
			local u = math.clamp((os.clock() - t0) / dur, 0, 1)
			applyIntensity(startI * (1 - u))
			if plotLight then
				plotLight.Brightness = PLOT_LIGHT_BRIGHTNESS * (1 - u)
			end
			if u >= 1 then
				fadeConn:Disconnect()
				restoreExact()
				intensitySmoothed = 0
			end
		end)
	end
end

local function refreshEnabled()
	setEnabled(wantEnabled())
end

InventoryState.onOpenChanged(function(_isOpen: boolean)
	refreshEnabled()
end)

ClientPlot.onChanged(function()
	if active then
		layoutPlotLight()
	end
	refreshEnabled()
end)

-- Drop the fade after Plot Size upgrades past stage 1.
Remotes.get("PlotSizeChanged").OnClientEvent:Connect(function()
	refreshEnabled()
end)

Remotes.get("SkillStagesSync").OnClientEvent:Connect(function()
	refreshEnabled()
end)

refreshEnabled()
