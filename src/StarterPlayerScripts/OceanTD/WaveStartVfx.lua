--!strict
--[[
	Wave-start callout: huge "Wave N" at screen center, then flies to W1 and fades.
	White for 0.7s, then green until gone.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local WaveStartVfx = {}

local HOLD_SEC = 0.35
local FLY_SEC = 1.2
local WHITE_SEC = 0.7 -- stay white this long after appear, then flip green
local GREEN = Color3.fromRGB(40, 220, 90)
local START_H_FRAC = 0.42 -- fraction of shorter viewport axis (height)
local START_W_MULT = 2.6 -- width vs height for "Wave N"
local END_SCALE = 0.22
local GUI_ORDER = 2400

local token = 0
local activeGui: ScreenGui? = nil

function WaveStartVfx.cancel()
	token += 1
	if activeGui then
		activeGui:Destroy()
		activeGui = nil
	end
end

local function worldToScreen(worldPos: Vector3): Vector2
	local cam = Workspace.CurrentCamera
	if not cam then
		return Vector2.zero
	end
	local v = cam:WorldToViewportPoint(worldPos)
	return Vector2.new(v.X, v.Y)
end

function WaveStartVfx.play(wave: number, startWorld: Vector3)
	WaveStartVfx.cancel()
	local my = token
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
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

	task.spawn(function()
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
			local a = u * u
			local target = worldToScreen(startWorld)
			local x = from.X + (target.X - from.X) * a
			local y = from.Y + (target.Y - from.Y) * a
			label.Position = UDim2.fromOffset(x, y)
			scale.Scale = 1 + (END_SCALE - 1) * a
			label.TextTransparency = a
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
	end)
end

return WaveStartVfx
