--!strict
--[[
	Studio: PlayerGui.MobileLeftUI.StopAutoRoll
	Toggles seed-wheel auto roll; animates wheel collapse/expand to this button.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))

local SeedWheelAutoRollState = require(script.Parent:WaitForChild("SeedWheelAutoRollState"))
local SeedWheelRevealApi = require(script.Parent:WaitForChild("SeedWheelRevealApi"))

local STUDIO_ANCHOR_NAME = "StopAutoRoll"
local DICE_IMAGE = "rbxassetid://77867192113507"
local CORAL_IMAGE = "rbxassetid://105031093209285"
local START_GREEN = Color3.fromRGB(29, 140, 46)
local ICON_SWAP_SEC = 1.35

local anchor: GuiObject? = nil
local hitBtn: GuiButton? = nil
local diceIcon: ImageLabel? = nil
local coralIcon: ImageLabel? = nil
local label: TextLabel? = nil
local iconSwapConn: RBXScriptConnection? = nil
local showDice = true
local busyAnim = false
local savedBg: Color3? = nil
local savedBgTrans: number? = nil

local function stopIconSwap()
	if iconSwapConn then
		iconSwapConn:Disconnect()
		iconSwapConn = nil
	end
end

local function refreshIconSwap()
	stopIconSwap()
	if not diceIcon or not coralIcon then
		return
	end
	showDice = true
	diceIcon.Visible = true
	coralIcon.Visible = false
	local t0 = os.clock()
	iconSwapConn = RunService.RenderStepped:Connect(function()
		if not diceIcon or not coralIcon or not diceIcon.Parent then
			stopIconSwap()
			return
		end
		local phase = math.floor((os.clock() - t0) / ICON_SWAP_SEC) % 2
		local wantDice = phase == 0
		if wantDice ~= showDice then
			showDice = wantDice
			diceIcon.Visible = showDice
			coralIcon.Visible = not showDice
		end
	end)
end

local function applyVisualRunning()
	if not anchor or not label then
		return
	end
	if savedBg then
		if anchor:IsA("GuiObject") then
			(anchor :: GuiObject).BackgroundColor3 = savedBg
			if anchor:IsA("Frame") then
				(anchor :: Frame).BackgroundTransparency = savedBgTrans or 0
			end
		end
	end
	label.Text = "STOP"
	label.TextColor3 = Color3.new(1, 1, 1)
	refreshIconSwap()
end

local function applyVisualStopped()
	stopIconSwap()
	if not anchor or not label or not diceIcon or not coralIcon then
		return
	end
	if anchor:IsA("GuiObject") then
		(anchor :: GuiObject).BackgroundColor3 = START_GREEN
		if anchor:IsA("Frame") then
			(anchor :: Frame).BackgroundTransparency = 0
		end
	end
	label.Text = "START"
	label.TextColor3 = Color3.new(1, 1, 1)
	diceIcon.Visible = true
	coralIcon.Visible = false
	showDice = true
end

local function ensureHit(host: GuiObject): GuiButton
	host.Active = true
	if host:IsA("GuiButton") then
		return host
	end
	local existing = host:FindFirstChild("_OceanTD_StopAutoRollHit")
	if existing and existing:IsA("GuiButton") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local hit = Instance.new("TextButton")
	hit.Name = "_OceanTD_StopAutoRollHit"
	hit.BackgroundTransparency = 1
	hit.BorderSizePixel = 0
	hit.Size = UDim2.fromScale(1, 1)
	hit.Text = ""
	hit.ZIndex = host.ZIndex + 12
	hit.AutoButtonColor = false
	hit.Selectable = true
	hit.Parent = host
	return hit
end

local function ensureChrome(host: GuiObject)
	for _, ch in ipairs(host:GetChildren()) do
		if ch:IsA("GuiObject") and string.sub(ch.Name, 1, 9) == "_OceanTD_" then
			ch:Destroy()
		end
	end
	for _, ch in ipairs(host:GetChildren()) do
		if ch:IsA("GuiObject") and ch.Name ~= "_OceanTD_StopAutoRollHit" then
			ch.Visible = false
		end
	end

	local function makeIcon(name: string, image: string, z: number, sizeScale: number?): ImageLabel
		local scale = sizeScale or 0.52
		local img = Instance.new("ImageLabel")
		img.Name = name
		img.BackgroundTransparency = 1
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.fromScale(0.5, 0.38)
		img.Size = UDim2.fromScale(scale, scale)
		img.Image = image
		img.ScaleType = Enum.ScaleType.Fit
		img.ZIndex = host.ZIndex + z
		img.Parent = host
		return img
	end

	diceIcon = makeIcon("_OceanTD_StopAutoRollDice", DICE_IMAGE, 3, 0.52 * 0.8)
	coralIcon = makeIcon("_OceanTD_StopAutoRollCoral", CORAL_IMAGE, 3)
	coralIcon.Visible = false

	local lbl = Instance.new("TextLabel")
	lbl.Name = "_OceanTD_StopAutoRollLabel"
	lbl.BackgroundTransparency = 1
	lbl.AnchorPoint = Vector2.new(0.5, 1)
	lbl.Position = UDim2.new(0.5, 0, 1, -2)
	lbl.Size = UDim2.new(1, -4, 0, 16)
	lbl.Font = UiTheme.Font
	lbl.TextScaled = true
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.Text = "START"
	lbl.ZIndex = host.ZIndex + 4
	lbl.Parent = host
	label = lbl
end

local function onToggleActivated()
	if busyAnim or not anchor then
		return
	end
	UiHaptics.pulseShort()
	local api = SeedWheelRevealApi
	if SeedWheelAutoRollState.isEnabled() then
		busyAnim = true
		-- Disable before claim/collapse so the server does not queue another reveal mid-collapse.
		SeedWheelAutoRollState._setEnabled(false)
		Remotes.get("SeedWheelAutoRoll"):FireServer(false)
		local collapse = api.collapseToTarget
		if collapse then
			collapse(anchor, function()
				applyVisualStopped()
				busyAnim = false
			end)
		else
			if api.abortActiveReveal then
				api.abortActiveReveal(true)
			end
			applyVisualStopped()
			busyAnim = false
		end
	else
		busyAnim = true
		applyVisualRunning()
		local expand = api.expandFromTarget
		if expand then
			expand(anchor, function()
				SeedWheelAutoRollState._setEnabled(true)
				Remotes.get("SeedWheelAutoRoll"):FireServer(true)
				busyAnim = false
			end)
		else
			SeedWheelAutoRollState._setEnabled(true)
			Remotes.get("SeedWheelAutoRoll"):FireServer(true)
			busyAnim = false
		end
	end
end

local function wireStopAutoRoll(leftOpt: Instance?)
	local left = leftOpt or playerGui:FindFirstChild("MobileLeftUI") or playerGui:WaitForChild("MobileLeftUI", 60)
	if not left then
		warn("[StopAutoRoll] PlayerGui.MobileLeftUI missing")
		return
	end
	LeftHudLayout.hardenScreenGui(left)
	local host = left:FindFirstChild(STUDIO_ANCHOR_NAME) or left:WaitForChild(STUDIO_ANCHOR_NAME, 30)
	if not host or not host:IsA("GuiObject") then
		warn("[StopAutoRoll] MobileLeftUI.StopAutoRoll missing — add anchor in Studio")
		return
	end
	if anchor == host and hitBtn and hitBtn.Parent then
		return
	end
	anchor = host
	if host:IsA("Frame") or host:IsA("ImageLabel") or host:IsA("ImageButton") then
		savedBg = (host :: GuiObject).BackgroundColor3
		if host:IsA("Frame") then
			savedBgTrans = (host :: Frame).BackgroundTransparency
		end
	end
	ensureChrome(host)
	local hit = ensureHit(host)
	hitBtn = hit
	if not hit:GetAttribute("_OceanTD_StopAutoRollWired") then
		hit:SetAttribute("_OceanTD_StopAutoRollWired", true)
		hit.Activated:Connect(onToggleActivated)
	end
	if SeedWheelAutoRollState.isEnabled() then
		applyVisualRunning()
	else
		applyVisualStopped()
	end
end

Remotes.get("SeedWheelAutoRollSync").OnClientEvent:Connect(function(enabled: any)
	local on = enabled == true
	SeedWheelAutoRollState._setEnabled(on)
	if on then
		applyVisualRunning()
	else
		applyVisualStopped()
	end
end)

SeedWheelAutoRollState.onChanged(function(on)
	if on then
		applyVisualRunning()
	else
		applyVisualStopped()
	end
end)

LeftHudLayout.watchMobileLeftUi(playerGui, wireStopAutoRoll)

task.spawn(function()
	while true do
		task.wait(2)
		if not hitBtn or not hitBtn.Parent then
			wireStopAutoRoll(nil)
		end
	end
end)

print("[StopAutoRoll] Ready")
