--!strict
--[[
	Bottom-right spectate HUD while visiting another player's reef.
	Shows host name + reef / wave bar / clock (same info as center HUD).
	Does not take over Slot5–7 or the player's own center wave HUD.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiViewportTags = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiViewportTags"))

local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local WaveWatchMode = require(script.Parent:WaitForChild("WaveWatchMode"))

local WaveWatchHud = {}

local BAR_H = 28
local REEF_ROW_GAP = 6
local LINE_H = 22
local LABEL_TEXT_SIZE = 16
local NAME_H = 20
local GAP_BELOW_OWN = 10
local BAR_BG = Color3.fromRGB(18, 22, 30)
local BAR_FILL = Color3.fromRGB(40, 200, 255)
local REEF_BAR_BG = Color3.fromRGB(40, 18, 28)
local REEF_BAR_FILL = Color3.fromRGB(255, 70, 110)

local playerGui: PlayerGui? = nil
local root: Frame? = nil
local nameLabel: TextLabel? = nil
local reefFill: Frame? = nil
local reefLabel: TextLabel? = nil
local waveFill: Frame? = nil
local waveLabel: TextLabel? = nil
local timeLabel: TextLabel? = nil
local forkLabel: TextLabel? = nil
local layoutConn: RBXScriptConnection? = nil

local function resolveHudParent(): ScreenGui?
	local pg = playerGui or Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	playerGui = pg
	local mobile = pg:FindFirstChild(UiViewportTags.MOBILE_RIGHT_HUD)
	local p720 = pg:FindFirstChild(UiViewportTags.P720_RIGHT_HUD)
	if mobile and mobile:IsA("ScreenGui") and mobile.Enabled then
		return mobile
	end
	if p720 and p720:IsA("ScreenGui") and p720.Enabled then
		return p720
	end
	local main = pg:FindFirstChild("MainHUD")
	if main and main:IsA("ScreenGui") then
		return main
	end
	return nil
end

local function hostDisplayName(userId: number): string
	if userId <= 0 then
		return "Host"
	end
	local plr = Players:GetPlayerByUserId(userId)
	if plr then
		return plr.DisplayName
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and typeof(name) == "string" and name ~= "" then
		return name
	end
	return "Player"
end

local function ensureUi(): Frame?
	local parent = resolveHudParent()
	if not parent then
		return nil
	end
	if root and root.Parent == parent then
		return root
	end
	if root then
		root:Destroy()
		root = nil
	end

	local f = Instance.new("Frame")
	f.Name = "OceanTD_WatchHud"
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Active = false
	f.Visible = false
	f.ZIndex = 24
	f.Size = UDim2.fromOffset(240, NAME_H + BAR_H * 2 + REEF_ROW_GAP + 4 + LINE_H)
	f.Parent = parent
	root = f

	local name = Instance.new("TextLabel")
	name.Name = "HostName"
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, 0, 0, NAME_H)
	name.Position = UDim2.fromOffset(0, 0)
	name.Font = UiTheme.Font
	name.TextSize = LABEL_TEXT_SIZE
	name.TextColor3 = Color3.fromRGB(255, 220, 140)
	name.TextStrokeTransparency = 0.35
	name.TextStrokeColor3 = Color3.new(0, 0, 0)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextYAlignment = Enum.TextYAlignment.Center
	name.Text = "Watching…"
	name.ZIndex = 25
	name.Parent = f
	nameLabel = name

	local function makeBar(barName: string, y: number, bg: Color3, fillCol: Color3): (Frame, Frame, TextLabel)
		local bar = Instance.new("Frame")
		bar.Name = barName
		bar.BackgroundColor3 = bg
		bar.BackgroundTransparency = 0.5
		bar.BorderSizePixel = 0
		bar.Size = UDim2.new(1, -4, 0, BAR_H)
		bar.Position = UDim2.fromOffset(0, y)
		bar.ZIndex = 25
		bar.ClipsDescendants = true
		bar.Parent = f
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = bar
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(1, 1, 1)
		stroke.Thickness = 1.5
		stroke.Parent = bar

		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.BackgroundColor3 = fillCol
		fill.BorderSizePixel = 0
		fill.Size = UDim2.fromScale(1, 1)
		fill.ZIndex = 26
		fill.Parent = bar
		local fillCorner = Instance.new("UICorner")
		fillCorner.CornerRadius = UDim.new(1, 0)
		fillCorner.Parent = fill

		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = UiTheme.Font
		label.TextSize = LABEL_TEXT_SIZE
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextStrokeTransparency = 0.35
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.ZIndex = 27
		label.Parent = bar
		return bar, fill, label
	end

	local _, rFill, rLabel = makeBar("ReefProgress", NAME_H, REEF_BAR_BG, REEF_BAR_FILL)
	reefFill = rFill
	reefLabel = rLabel
	rLabel.Text = "🤍 Reef Health 10/10"

	local _, wFill, wLabel = makeBar("WaveProgress", NAME_H + BAR_H + REEF_ROW_GAP, BAR_BG, BAR_FILL)
	waveFill = wFill
	waveLabel = wLabel
	wLabel.Text = "🌊 Wave 1"

	local fork = Instance.new("TextLabel")
	fork.Name = "ForkCount"
	fork.BackgroundTransparency = 1
	fork.Size = UDim2.new(0.45, 0, 1, 0)
	fork.Position = UDim2.fromOffset(8, 0)
	fork.Font = UiTheme.Font
	fork.TextSize = 14
	fork.TextColor3 = Color3.new(1, 1, 1)
	fork.TextStrokeTransparency = 0.35
	fork.TextXAlignment = Enum.TextXAlignment.Left
	fork.TextYAlignment = Enum.TextYAlignment.Center
	fork.ZIndex = 28
	fork.Text = "0 of 0"
	fork.Parent = wLabel.Parent
	forkLabel = fork

	local clockY = NAME_H + BAR_H * 2 + REEF_ROW_GAP + 4
	local clock = Instance.new("TextLabel")
	clock.Name = "Clock"
	clock.BackgroundTransparency = 1
	clock.Size = UDim2.new(1, 0, 0, LINE_H)
	clock.Position = UDim2.fromOffset(0, clockY)
	clock.Font = UiTheme.Font
	clock.TextSize = LABEL_TEXT_SIZE
	clock.TextColor3 = Color3.new(1, 1, 1)
	clock.TextStrokeTransparency = 0.35
	clock.TextStrokeColor3 = Color3.new(0, 0, 0)
	clock.TextXAlignment = Enum.TextXAlignment.Right
	clock.TextYAlignment = Enum.TextYAlignment.Center
	clock.ZIndex = 25
	clock.Text = "⏱️00:00:00"
	clock.Parent = f
	timeLabel = clock

	return f
end

local function layout()
	local f = ensureUi()
	local parent = resolveHudParent()
	if not f or not parent then
		return
	end
	if f.Parent ~= parent then
		f.Parent = parent
	end

	local w = 240
	local h = NAME_H + BAR_H * 2 + REEF_ROW_GAP + 4 + LINE_H
	local own = parent:FindFirstChild("OceanTD_WaveHud")
	local x: number
	local y: number
	if own and own:IsA("GuiObject") and own.Visible then
		w = math.max(220, own.AbsoluteSize.X)
		x = own.AbsolutePosition.X - parent.AbsolutePosition.X
		y = (own.AbsolutePosition.Y - parent.AbsolutePosition.Y) + own.AbsoluteSize.Y + GAP_BELOW_OWN
	else
		local quickbar = parent:FindFirstChild("Quickbar")
		local slot5 = quickbar and quickbar:FindFirstChild("Slot5")
		if slot5 and slot5:IsA("GuiObject") then
			w = math.max(220, slot5.AbsoluteSize.X + 140)
			x = (slot5.AbsolutePosition.X + slot5.AbsoluteSize.X) - parent.AbsolutePosition.X - w
			-- Sit where own HUD would be, then one block lower so it's "below" that band.
			y = (slot5.AbsolutePosition.Y + slot5.AbsoluteSize.Y + 8) - parent.AbsolutePosition.Y
			y += (BAR_H * 2 + REEF_ROW_GAP + LINE_H + 8)
		else
			local vp = parent.AbsoluteSize
			x = vp.X - w - 16
			y = vp.Y - h - 16
		end
	end
	f.Size = UDim2.fromOffset(math.floor(w + 0.5), h)
	f.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
end

local function applySnap(snap: WaveWatchMode.WatchSnap)
	local f = ensureUi()
	if not f then
		return
	end
	f.Visible = true
	layout()

	if nameLabel then
		nameLabel.Text = "👁 " .. hostDisplayName(snap.hostUserId)
	end
	local reefMax = math.max(1, snap.reefMax or 10)
	local reefH = math.clamp(snap.reefHealth or 0, 0, reefMax)
	if reefFill then
		reefFill.Size = UDim2.fromScale(reefH / reefMax, 1)
	end
	if reefLabel then
		reefLabel.Text = "🤍 Reef Health " .. tostring(reefH) .. "/" .. tostring(reefMax)
	end
	local prog = math.clamp(snap.feedProgress or 0, 0, 1)
	if waveFill then
		waveFill.Size = UDim2.fromScale(prog, 1)
	end
	if waveLabel then
		if snap.feedComplete then
			waveLabel.Text = "NEXT WAVE"
		else
			waveLabel.Text = "🌊 Wave " .. tostring(snap.wave)
		end
	end
	if forkLabel then
		forkLabel.Text = tostring(snap.fishFull or 0) .. " of " .. tostring((snap.fishTotal or 0) + (snap.crabTotal or 0))
	end
	if timeLabel then
		timeLabel.Text = "⏱️" .. WaveSim.formatClock(snap.elapsedSec or 0)
	end
end

local function hide()
	if root then
		root.Visible = false
	end
end

function WaveWatchHud.mount()
	WaveWatchMode.onChanged(function(watching, snap)
		if watching and snap then
			applySnap(snap)
		else
			hide()
		end
	end)
	if not layoutConn then
		layoutConn = RunService.RenderStepped:Connect(function()
			if root and root.Visible then
				layout()
			end
		end)
	end
	local snap = WaveWatchMode.getSnap()
	if WaveWatchMode.isWatching() and snap then
		applySnap(snap)
	end
end

return WaveWatchHud
