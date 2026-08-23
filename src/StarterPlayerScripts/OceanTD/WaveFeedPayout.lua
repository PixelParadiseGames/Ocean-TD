--!strict
--[[
	Batches "hunger bar filled" events from WaveSim → server ReportFishFed.
	Server decides $D (EarnMore stage). Client only reports fish count.
	Juice: green "$D" (FredokaOne, thin white stroke) flies fish → $DCount.
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local WaveFeedPayout = {}

local FLY_SEC = 0.55
local STROKE_GREEN = Color3.fromRGB(0, 170, 0) -- #00aa00
local COUNT_NAME = Constants.SAND_DOLLARS_COUNT_NAME

local pending = 0
local flushQueued = false
local remote: RemoteEvent? = nil
local overlay: ScreenGui? = nil
local cachedCount: GuiObject? = nil

local player = Players.LocalPlayer

local function getRemote(): RemoteEvent
	if remote then
		return remote
	end
	remote = Remotes.get("ReportFishFed")
	return remote
end

local function flush()
	flushQueued = false
	local n = pending
	pending = 0
	if n <= 0 then
		return
	end
	local ok, err = pcall(function()
		getRemote():FireServer(n)
	end)
	if not ok then
		warn("[ECONOMY] ReportFishFed failed", err)
	end
end

local function getOverlay(): ScreenGui
	if overlay and overlay.Parent then
		return overlay
	end
	local pg = player:WaitForChild("PlayerGui")
	local existing = pg:FindFirstChild("OceanTD_SandDollarFly")
	if existing and existing:IsA("ScreenGui") then
		overlay = existing
		return existing
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_SandDollarFly"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 90
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = pg
	overlay = sg
	return sg
end

local function getCountGui(): GuiObject?
	if cachedCount and cachedCount.Parent then
		return cachedCount
	end
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return nil
	end
	local left = pg:FindFirstChild("MobileLeftUI")
	if not left then
		return nil
	end
	local count = LeftHudLayout.findDCount(left)
	if count then
		cachedCount = count
		return count
	end
	return nil
end

local function worldToScreen(worldPos: Vector3): Vector2?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local v, onScreen = cam:WorldToViewportPoint(worldPos)
	if v.Z <= 0 then
		return nil
	end
	local vp = cam.ViewportSize
	local x = v.X
	local y = v.Y
	if not onScreen then
		x = math.clamp(x, 24, vp.X - 24)
		y = math.clamp(y, 24, vp.Y - 24)
	end
	return Vector2.new(x, y)
end

local function countScreenCenter(): Vector2?
	local count = getCountGui()
	if not count then
		return nil
	end
	-- AbsolutePosition is relative to the ScreenGui content origin. Our fly overlay
	-- uses IgnoreGuiInset=true, so add inset when the HUD respects the top bar.
	local pos = count.AbsolutePosition + count.AbsoluteSize * 0.5
	local sg = count:FindFirstAncestorOfClass("ScreenGui")
	if sg and sg.IgnoreGuiInset ~= true then
		local inset = GuiService:GetGuiInset()
		pos = Vector2.new(pos.X + inset.X, pos.Y + inset.Y)
	end
	return pos
end

local function punchCount()
	local count = getCountGui()
	if not count then
		return
	end
	local scale = count:FindFirstChild(LeftHudLayout.PUNCH_SCALE_NAME)
	if not scale or not scale:IsA("UIScale") then
		scale = Instance.new("UIScale")
		scale.Name = LeftHudLayout.PUNCH_SCALE_NAME
		scale.Scale = 1
		scale.Parent = count
	end
	scale.Scale = 1.18
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function flyDollar(worldPos: Vector3)
	local start = worldToScreen(worldPos)
	local dest0 = countScreenCenter()
	if not start or not dest0 then
		return
	end

	local dest = dest0
	local mid = (start + dest) * 0.5
	local delta = dest - start
	-- Mild upward arc; endpoint stays locked to $DCount center.
	local len = math.max(40, delta.Magnitude)
	local arc = Vector2.new(-delta.Y, delta.X)
	if arc.Magnitude > 1e-3 then
		arc = arc.Unit * math.clamp(len * 0.18, 20, 70)
	else
		arc = Vector2.new(0, -36)
	end
	if arc.Y > 0 then
		arc = -arc
	end
	local ctrl = mid + arc

	local sg = getOverlay()
	local lbl = Instance.new("TextLabel")
	lbl.Name = "FlyD"
	lbl.BackgroundTransparency = 1
	lbl.AnchorPoint = Vector2.new(0.5, 0.5)
	lbl.Position = UDim2.fromOffset(start.X, start.Y)
	lbl.Size = UDim2.fromOffset(56, 32)
	lbl.Font = UiTheme.Font
	lbl.Text = "$D"
	lbl.TextSize = 26
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextStrokeColor3 = STROKE_GREEN
	lbl.TextStrokeTransparency = 1
	lbl.ZIndex = 5
	lbl.Parent = sg
	local stroke = Instance.new("UIStroke")
	stroke.Color = STROKE_GREEN
	stroke.Thickness = 1.4
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = lbl

	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if not lbl.Parent then
			if conn then
				conn:Disconnect()
			end
			return
		end
		local live = countScreenCenter()
		if live then
			dest = live
			-- Keep control point relative to the live endpoint so the arc doesn't drift.
			mid = (start + dest) * 0.5
			delta = dest - start
			len = math.max(40, delta.Magnitude)
			arc = Vector2.new(-delta.Y, delta.X)
			if arc.Magnitude > 1e-3 then
				arc = arc.Unit * math.clamp(len * 0.18, 20, 70)
			else
				arc = Vector2.new(0, -36)
			end
			if arc.Y > 0 then
				arc = -arc
			end
			ctrl = mid + arc
		end
		local u = math.clamp((os.clock() - t0) / FLY_SEC, 0, 1)
		local e = u * u * (3 - 2 * u) -- smoothstep
		local omt = 1 - e
		local p = omt * omt * start + 2 * omt * e * ctrl + e * e * dest
		lbl.Position = UDim2.fromOffset(p.X, p.Y)
		lbl.TextSize = 26 - 6 * e
		if u >= 1 then
			if conn then
				conn:Disconnect()
			end
			-- Snap exactly onto the counter before destroy.
			local final = countScreenCenter()
			if final then
				lbl.Position = UDim2.fromOffset(final.X, final.Y)
			end
			punchCount()
			lbl:Destroy()
		end
	end)
end

function WaveFeedPayout.noteFilled(worldPos: Vector3?)
	pending += 1
	if typeof(worldPos) == "Vector3" then
		flyDollar(worldPos)
	end
	if flushQueued then
		return
	end
	flushQueued = true
	task.defer(flush)
end

return WaveFeedPayout
