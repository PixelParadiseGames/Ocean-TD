--!strict
--[[
	Wave-start callout:
	1) Huge "Wave N" at screen center, then flies into the hunger / wave bar.
	2) Critter emoji counts appear center-screen, then scale/fly into the wave bar.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local WaveStartVfx = {}

local HOLD_SEC = 0.35
local FLY_SEC = 0.7 -- Wave N total dwell ~0.5s shorter than before (was 1.2)
local WHITE_SEC = 0.7 -- stay white this long after appear, then flip green
local CRITTER_HOLD_SEC = 1.55 -- center hold (+1s)
local CRITTER_FLY_SEC = 1.15 -- smooth settle into wave bar
local GREEN = Color3.fromRGB(40, 220, 90)
local START_H_FRAC = 0.42 -- fraction of shorter viewport axis (height)
local START_W_MULT = 2.6 -- width vs height for "Wave N"
local CRITTER_H_FRAC = 0.16
local CRITTER_W_MULT = 4.2
local END_SCALE = 0.22
local CRITTER_END_SCALE = 0.22
local GUI_ORDER = 2400
local CRITTER_BUSY_ATTR = "OceanTD_CritterIntroBusy"

export type CritterCounts = {
	fish: number,
	crabs: number?,
	urchins: number?,
	sharks: number?,
}

local token = 0
local activeGui: ScreenGui? = nil

function WaveStartVfx.cancel()
	token += 1
	if activeGui then
		activeGui:Destroy()
		activeGui = nil
	end
	local plr = Players.LocalPlayer
	local pg = plr and plr:FindFirstChildOfClass("PlayerGui")
	if pg then
		pg:SetAttribute(CRITTER_BUSY_ATTR, false)
	end
end

local function formatCritterLine(counts: CritterCounts): string
	local line = "🐟:" .. tostring(math.max(0, math.floor(counts.fish + 0.5)))
	local crabs = math.max(0, math.floor((counts.crabs or 0) + 0.5))
	local urchins = math.max(0, math.floor((counts.urchins or 0) + 0.5))
	local sharks = math.max(0, math.floor((counts.sharks or 0) + 0.5))
	if crabs > 0 then
		line ..= " 🦀:" .. tostring(crabs)
	end
	if urchins > 0 then
		line ..= " ✴:" .. tostring(urchins)
	end
	if sharks > 0 then
		line ..= " 🦈:" .. tostring(sharks)
	end
	return line
end

local function findWaveHud(pg: PlayerGui): Instance?
	local hud = pg:FindFirstChild("OceanTD_WaveHud", true)
	if hud then
		return hud
	end
	for _, name in ipairs({ "MobileRightHUD", "P720RightHUD", "MainHUD" }) do
		local host = pg:FindFirstChild(name)
		if host then
			hud = host:FindFirstChild("OceanTD_WaveHud")
			if hud then
				return hud
			end
		end
	end
	return nil
end

-- AbsolutePosition → Position on IgnoreGuiInset=true overlay (same as HideUiController).
local function overlayCenterOf(gui: GuiObject): Vector2
	local inset = GuiService:GetGuiInset()
	local c = gui.AbsolutePosition + gui.AbsoluteSize * 0.5
	return Vector2.new(c.X + inset.X, c.Y + inset.Y)
end

local function findWaveBarTarget(pg: PlayerGui): Vector2?
	local hud = findWaveHud(pg)
	if not hud then
		return nil
	end
	local bar = hud:FindFirstChild("WaveProgress")
	-- Prefer the in-bar wave title (left side); else bar center.
	local waveLbl = if bar then bar:FindFirstChild("WaveLabel") else nil
	local target: GuiObject? = if waveLbl and waveLbl:IsA("GuiObject")
		then waveLbl
		elseif bar and bar:IsA("GuiObject") then bar
		elseif hud:IsA("GuiObject") then hud
		else nil
	if not target then
		return nil
	end
	if target.Name == "WaveLabel" then
		-- Left-aligned title: aim toward the text mass, not geometric center of full-width label.
		local inset = GuiService:GetGuiInset()
		local pos = target.AbsolutePosition
		local size = target.AbsoluteSize
		return Vector2.new(pos.X + size.X * 0.28 + inset.X, pos.Y + size.Y * 0.5 + inset.Y)
	end
	return overlayCenterOf(target)
end

local function findCritterBarTarget(pg: PlayerGui): Vector2?
	local hud = findWaveHud(pg)
	if not hud then
		return nil
	end
	local bar = hud:FindFirstChild("WaveProgress")
	local crit = if bar then bar:FindFirstChild("CritterEmojis") else nil
	local target: GuiObject? = if crit and crit:IsA("GuiObject")
		then crit
		elseif bar and bar:IsA("GuiObject") then bar
		elseif hud:IsA("GuiObject") then hud
		else nil
	if not target then
		return nil
	end
	return overlayCenterOf(target)
end

local function playCritterIntro(my: number, pg: PlayerGui, counts: CritterCounts)
	pg:SetAttribute(CRITTER_BUSY_ATTR, true)

	local cam = Workspace.CurrentCamera
	if not cam then
		pg:SetAttribute(CRITTER_BUSY_ATTR, false)
		return
	end
	local vp = cam.ViewportSize
	local short = math.min(vp.X, vp.Y)
	local h = math.max(48, short * CRITTER_H_FRAC)
	local w = math.min(vp.X * 0.94, h * CRITTER_W_MULT)

	local gui = Instance.new("ScreenGui")
	gui.Name = "OceanTD_WaveStartCritters"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = GUI_ORDER + 1
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = pg
	activeGui = gui

	local from = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
	-- Lock destination once so mid-flight HUD layout jitter can't snap the path.
	local lockedTarget = findCritterBarTarget(pg) or Vector2.new(vp.X * 0.78, vp.Y * 0.92)

	local label = Instance.new("TextLabel")
	label.Name = "CritterCounts"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromOffset(from.X, from.Y)
	label.Size = UDim2.fromOffset(w, h)
	label.Font = UiTheme.Font
	label.Text = formatCritterLine(counts)
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextTransparency = 0
	label.TextScaled = true
	label.ZIndex = 10
	label.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 3
	stroke.Transparency = 0.3
	stroke.Parent = label

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = label

	local tHold = os.clock()
	while os.clock() - tHold < CRITTER_HOLD_SEC do
		if my ~= token or not label.Parent then
			pg:SetAttribute(CRITTER_BUSY_ATTR, false)
			return
		end
		-- Keep center locked in viewport pixels (handles resize without scale↔offset snap).
		local camHold = Workspace.CurrentCamera
		if camHold then
			local vpHold = camHold.ViewportSize
			label.Position = UDim2.fromOffset(vpHold.X * 0.5, vpHold.Y * 0.5)
			local hHold = math.max(48, math.min(vpHold.X, vpHold.Y) * CRITTER_H_FRAC)
			local wHold = math.min(vpHold.X * 0.94, hHold * CRITTER_W_MULT)
			label.Size = UDim2.fromOffset(wHold, hHold)
			from = Vector2.new(vpHold.X * 0.5, vpHold.Y * 0.5)
			lockedTarget = findCritterBarTarget(pg) or lockedTarget
		end
		RunService.RenderStepped:Wait()
	end
	if my ~= token or not label.Parent then
		pg:SetAttribute(CRITTER_BUSY_ATTR, false)
		return
	end

	-- Refresh lock once more right before fly (HUD should be laid out by now).
	lockedTarget = findCritterBarTarget(pg) or lockedTarget
	local startSize = label.AbsoluteSize
	local endSizeGoal = Vector2.new(math.max(80, startSize.X * CRITTER_END_SCALE), math.max(18, startSize.Y * CRITTER_END_SCALE))
	do
		local barTarget = findCritterBarTarget(pg)
		local hud = pg:FindFirstChild("OceanTD_WaveHud", true)
		if not hud then
			for _, name in ipairs({ "MobileRightHUD", "P720RightHUD", "MainHUD" }) do
				local host = pg:FindFirstChild(name)
				if host then
					hud = host:FindFirstChild("OceanTD_WaveHud")
					if hud then
						break
					end
				end
			end
		end
		local bar = hud and hud:FindFirstChild("WaveProgress")
		local crit = bar and bar:FindFirstChild("CritterEmojis")
		if crit and crit:IsA("GuiObject") and crit.AbsoluteSize.X > 4 then
			endSizeGoal = Vector2.new(math.max(crit.AbsoluteSize.X, 60), math.max(crit.AbsoluteSize.Y, 16))
			lockedTarget = barTarget or lockedTarget
		end
	end

	local t0 = os.clock()
	while os.clock() - t0 < CRITTER_FLY_SEC do
		if my ~= token or not label.Parent then
			pg:SetAttribute(CRITTER_BUSY_ATTR, false)
			return
		end
		local u = math.clamp((os.clock() - t0) / CRITTER_FLY_SEC, 0, 1)
		-- Smooth ease-in-out (quintic) — no linear snap at the ends.
		local a = if u < 0.5
			then 16 * u * u * u * u * u
			else 1 - ((-2 * u + 2) ^ 5) / 2
		local x = from.X + (lockedTarget.X - from.X) * a
		local y = from.Y + (lockedTarget.Y - from.Y) * a
		label.Position = UDim2.fromOffset(x, y)
		local wNow = startSize.X + (endSizeGoal.X - startSize.X) * a
		local hNow = startSize.Y + (endSizeGoal.Y - startSize.Y) * a
		label.Size = UDim2.fromOffset(wNow, hNow)
		-- Crossfade into the bar so destroy doesn't pop.
		local fade = math.clamp((u - 0.82) / 0.18, 0, 1)
		label.TextTransparency = fade
		stroke.Transparency = 0.3 + 0.7 * fade
		RunService.RenderStepped:Wait()
	end

	-- Reveal bar critters a beat before destroying overlay (overlap softens handoff).
	if my == token then
		pg:SetAttribute(CRITTER_BUSY_ATTR, false)
		RunService.RenderStepped:Wait()
	end

	if my == token and activeGui == gui then
		gui:Destroy()
		activeGui = nil
	elseif gui.Parent then
		gui:Destroy()
	end
end

function WaveStartVfx.play(wave: number, _startWorld: Vector3, critters: CritterCounts?)
	WaveStartVfx.cancel()
	local my = token
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end

	task.spawn(function()
		-- Hide bar critters for the whole intro (including wave-1 delay).
		if critters then
			pg:SetAttribute(CRITTER_BUSY_ATTR, true)
		end

		-- Wave 1: TangCam overview needs a beat before the center callouts.
		if wave == 1 then
			local tDelay = os.clock()
			while os.clock() - tDelay < 2 do
				if my ~= token then
					return
				end
				RunService.RenderStepped:Wait()
			end
			if my ~= token then
				return
			end
		end

		local cam = Workspace.CurrentCamera
		if not cam then
			return
		end

		local vp = cam.ViewportSize
		local short = math.min(vp.X, vp.Y)
		local h = math.max(90, short * START_H_FRAC)
		local w = math.min(vp.X * 0.92, h * START_W_MULT)

		local gui = Instance.new("ScreenGui")
		gui.Name = "OceanTD_WaveStart"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = GUI_ORDER
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = pg
		activeGui = gui

		local label = Instance.new("TextLabel")
		label.Name = "WaveLabel"
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Size = UDim2.fromOffset(w, h)
		label.Font = UiTheme.Font
		label.Text = "Wave " .. tostring(math.max(1, math.floor(wave)))
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextTransparency = 0
		label.TextScaled = true
		label.ZIndex = 10
		label.Parent = gui

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Thickness = 4
		stroke.Transparency = 0.35
		stroke.Parent = label

		local scale = Instance.new("UIScale")
		scale.Scale = 1
		scale.Parent = label

		local appearedAt = os.clock()
		local flippedGreen = false

		local function tickColor()
			if flippedGreen then
				return
			end
			if os.clock() - appearedAt >= WHITE_SEC then
				flippedGreen = true
				label.TextColor3 = GREEN
			end
		end

		local tHold = appearedAt
		while os.clock() - tHold < HOLD_SEC do
			if my ~= token or not label.Parent then
				return
			end
			tickColor()
			RunService.RenderStepped:Wait()
		end
		if my ~= token or not label.Parent then
			return
		end

		local from = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
		local lockedTarget = findWaveBarTarget(pg) or Vector2.new(vp.X * 0.78, vp.Y * 0.92)
		local t0 = os.clock()
		while os.clock() - t0 < FLY_SEC do
			if my ~= token or not label.Parent then
				return
			end
			tickColor()
			local camNow = Workspace.CurrentCamera
			if not camNow then
				break
			end
			local vpNow = camNow.ViewportSize
			local u = math.clamp((os.clock() - t0) / FLY_SEC, 0, 1)
			-- Smooth ease-in-out toward hunger / wave bar.
			local a = if u < 0.5
				then 16 * u * u * u * u * u
				else 1 - ((-2 * u + 2) ^ 5) / 2
			lockedTarget = findWaveBarTarget(pg) or lockedTarget
			local x = from.X + (lockedTarget.X - from.X) * a
			local y = from.Y + (lockedTarget.Y - from.Y) * a
			label.Position = UDim2.fromOffset(x, y)
			scale.Scale = 1 + (END_SCALE - 1) * a
			label.TextTransparency = a * 0.85
			stroke.Transparency = 0.35 + 0.65 * a
			local hNow = math.max(70, math.min(vpNow.X, vpNow.Y) * START_H_FRAC)
			local wNow = math.min(vpNow.X * 0.92, hNow * START_W_MULT)
			label.Size = UDim2.fromOffset(wNow, hNow)
			RunService.RenderStepped:Wait()
		end

		if my == token and activeGui == gui then
			gui:Destroy()
			activeGui = nil
		elseif gui.Parent then
			gui:Destroy()
		end

		if my ~= token then
			return
		end
		if critters and (critters.fish > 0 or (critters.crabs or 0) > 0 or (critters.urchins or 0) > 0 or (critters.sharks or 0) > 0) then
			playCritterIntro(my, pg, critters)
		elseif pg.Parent then
			pg:SetAttribute(CRITTER_BUSY_ATTR, false)
		end
	end)
end

return WaveStartVfx
