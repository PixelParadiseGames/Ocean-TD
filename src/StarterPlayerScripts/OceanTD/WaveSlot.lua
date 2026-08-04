--!strict
--[[
	Slot5 Start / Stop waves — always visible quickbar control.
	Shortcuts: R (keyboard) / ButtonX (gamepad). Help badge green; hidden on touch.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local WaveSlot = {}

local START_ICON = "rbxassetid://74802566438233"
local STOP_ICON = "rbxassetid://109069665418357"
local HELP_GREEN = Color3.fromRGB(40, 180, 80)
local FINISH_GREEN = Color3.fromRGB(40, 180, 80)
local CONFETTI_COUNT = 40
local CONFETTI_LIFE = 2.4
-- Shift camera subject up so the avatar sits ~20% lower on screen during waves.
local WAVE_CAM_SCREEN_SHIFT = 0.2

export type Deps = {
	mainHUD: ScreenGui,
	playerGui: PlayerGui,
	ensureButton: (GuiObject) -> GuiButton,
	passthroughDecor: (GuiObject, GuiButton) -> (),
	ensureCircle: (GuiObject) -> GuiObject,
	ensureStroke: (GuiObject, string, Color3, number) -> UIStroke,
	getShortcutMode: () -> string,
	log: (...any) -> (),
}

local deps: Deps
local slot5: GuiObject? = nil
local slot5Button: GuiButton? = nil
local slot5Circle: GuiObject? = nil
local helpSlot5: GuiObject? = nil
local helpSlot5Letter: TextLabel? = nil
local helpHit: GuiButton? = nil

local hudFrame: Frame? = nil
local hudWave: TextLabel? = nil
local hudReef: TextLabel? = nil
local hudTime: TextLabel? = nil
local hudLayoutConn: RBXScriptConnection? = nil

local summaryGui: ScreenGui? = nil
local summaryOpen = false
local finishBtn: TextButton? = nil
local prevGuiSelected: GuiObject? = nil
local confettiConn: RBXScriptConnection? = nil
local confettiToken = 0
local waveCamConn: RBXScriptConnection? = nil
local waveCamCharConn: RBXScriptConnection? = nil

local function isUsingGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function clearWaveCameraOffset()
	local char = Players.LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.CameraOffset = Vector3.zero
	end
end

local function applyWaveCameraOffset()
	local char = Players.LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		hum.CameraOffset = Vector3.new(0, 3, 0)
		return
	end
	local dist = (cam.CFrame.Position - cam.Focus.Position).Magnitude
	if dist < 1 then
		dist = 12.5
	end
	local halfH = dist * math.tan(math.rad(cam.FieldOfView) * 0.5)
	-- 20% of full vertical view in studs at the focus distance.
	hum.CameraOffset = Vector3.new(0, halfH * (WAVE_CAM_SCREEN_SHIFT * 2), 0)
end

local function setWaveCameraActive(on: boolean)
	if on then
		if waveCamConn then
			return
		end
		waveCamConn = RunService.RenderStepped:Connect(applyWaveCameraOffset)
		if not waveCamCharConn then
			waveCamCharConn = Players.LocalPlayer.CharacterAdded:Connect(function()
				task.defer(applyWaveCameraOffset)
			end)
		end
		applyWaveCameraOffset()
		return
	end
	if waveCamConn then
		waveCamConn:Disconnect()
		waveCamConn = nil
	end
	if waveCamCharConn then
		waveCamCharConn:Disconnect()
		waveCamCharConn = nil
	end
	clearWaveCameraOffset()
end

local function applyIcon(running: boolean)
	if not slot5Circle then
		return
	end
	if slot5Circle:IsA("ImageLabel") or slot5Circle:IsA("ImageButton") then
		(slot5Circle :: any).Image = if running then STOP_ICON else START_ICON
	end
end

local function styleHelpBadge(): boolean
	if not helpSlot5 or not helpSlot5Letter then
		return false
	end
	local mode = deps.getShortcutMode()
	if mode == "touch" then
		return false
	end
	if helpSlot5:IsA("ImageLabel") or helpSlot5:IsA("ImageButton") then
		(helpSlot5 :: any).Image = ""
	end
	helpSlot5.BackgroundColor3 = HELP_GREEN
	helpSlot5.BackgroundTransparency = 0
	helpSlot5.Active = false
	UiCircles.ensure(helpSlot5)
	helpSlot5Letter.Text = if mode == "gamepad" then "X" else "R"
	helpSlot5Letter.TextColor3 = Color3.new(1, 1, 1)
	helpSlot5Letter.Visible = true
	return true
end

local function setSlot5Interactable(on: boolean)
	if slot5Button then
		slot5Button.Selectable = false
		slot5Button.Active = on
	end
	if slot5 then
		slot5.Selectable = false
		if slot5:IsA("GuiButton") then
			(slot5 :: GuiButton).Active = on
		end
	end
	if helpHit then
		helpHit.Selectable = false
		helpHit.Active = on and helpHit.Visible
	end
end

function WaveSlot.refreshHelpBadge()
	if not helpSlot5 then
		return
	end
	local backpackOpen = InventoryState.isOpen()
	if styleHelpBadge() then
		helpSlot5.Visible = true
		if helpHit then
			helpHit.Visible = true
			helpHit.Selectable = false
			-- Badge stays visible as a hint, but never clickable while backpack is open.
			helpHit.Active = not backpackOpen
		end
	else
		helpSlot5.Visible = false
		if helpHit then
			helpHit.Visible = false
			helpHit.Active = false
		end
	end
end

local function ensureHud()
	if hudFrame then
		return
	end
	local LINE_H = 28
	local f = Instance.new("Frame")
	f.Name = "OceanTD_WaveHud"
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Visible = false
	f.ZIndex = 25
	f.Size = UDim2.fromOffset(220, LINE_H * 3)
	f.Parent = deps.mainHUD
	hudFrame = f

	local function mk(name: string, order: number): TextLabel
		local t = Instance.new("TextLabel")
		t.Name = name
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(1, -4, 0, LINE_H)
		t.Position = UDim2.fromOffset(0, (order - 1) * LINE_H)
		t.Font = UiTheme.Font
		t.TextSize = 15
		t.TextColor3 = Color3.new(1, 1, 1)
		t.TextStrokeTransparency = 0.35
		t.TextStrokeColor3 = Color3.new(0, 0, 0)
		t.TextXAlignment = Enum.TextXAlignment.Right
		t.TextYAlignment = Enum.TextYAlignment.Center
		t.TextTruncate = Enum.TextTruncate.None
		t.ZIndex = 26
		t.Parent = f
		return t
	end
	hudWave = mk("Wave", 1)
	hudReef = mk("Reef", 2)
	hudTime = mk("Time", 3)
end

local function layoutHud()
	if not hudFrame or not slot5 then
		return
	end
	-- Right-align under Slot5 so long lines (Reef Health) aren't clipped.
	local parent = deps.mainHUD
	local slotPos = slot5.AbsolutePosition
	local slotSize = slot5.AbsoluteSize
	local parentPos = parent.AbsolutePosition
	local w = math.max(220, slotSize.X + 100)
	local h = 84
	local x = (slotPos.X + slotSize.X) - parentPos.X - w
	local y = (slotPos.Y + slotSize.Y + 10) - parentPos.Y
	hudFrame.Size = UDim2.fromOffset(w, h)
	hudFrame.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
end

local function setHudVisible(on: boolean)
	ensureHud()
	if hudFrame then
		hudFrame.Visible = on
	end
	if on then
		layoutHud()
		if not hudLayoutConn then
			hudLayoutConn = RunService.RenderStepped:Connect(function()
				if hudFrame and hudFrame.Visible then
					layoutHud()
				end
			end)
		end
	else
		if hudLayoutConn then
			hudLayoutConn:Disconnect()
			hudLayoutConn = nil
		end
	end
end

local function updateHud(snap: WaveSim.HudSnapshot)
	ensureHud()
	if not snap.running then
		setHudVisible(false)
		setWaveCameraActive(false)
		return
	end
	setWaveCameraActive(true)
	setHudVisible(true)
	if hudWave then
		hudWave.Text = "🌊Wave" .. tostring(snap.wave)
	end
	if hudReef then
		hudReef.Text = "❤️Reef Health " .. tostring(snap.reefHealth)
	end
	if hudTime then
		hudTime.Text = "⏱️" .. WaveSim.formatClock(snap.elapsedSec)
	end
end

local function stopConfetti()
	confettiToken += 1
	if confettiConn then
		confettiConn:Disconnect()
		confettiConn = nil
	end
end

local function playConfetti(parent: Frame)
	stopConfetti()
	local my = confettiToken
	local layer = Instance.new("Frame")
	layer.Name = "Confetti"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = 50
	layer.Parent = parent

	type P = { f: Frame, x: number, y: number, vx: number, vy: number, life: number }
	local parts: { P } = {}
	local rng = Random.new()
	local colors = {
		Color3.fromRGB(255, 80, 80),
		Color3.fromRGB(255, 180, 40),
		Color3.fromRGB(80, 220, 100),
		Color3.fromRGB(60, 160, 255),
		Color3.fromRGB(220, 100, 255),
		Color3.fromRGB(255, 255, 80),
		Color3.fromRGB(255, 120, 200),
		Color3.fromRGB(100, 255, 220),
	}
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	for i = 1, CONFETTI_COUNT do
		local sz = rng:NextNumber(6, 18)
		local f = Instance.new("Frame")
		f.BackgroundColor3 = colors[((i - 1) % #colors) + 1]
		f.BorderSizePixel = 0
		f.Size = UDim2.fromOffset(sz, sz)
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.ZIndex = 51
		f.Parent = layer
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = f
		local x = rng:NextNumber(vp.X * 0.15, vp.X * 0.85)
		local y = vp.Y + rng:NextNumber(4, 40)
		f.Position = UDim2.fromOffset(x, y)
		table.insert(parts, {
			f = f,
			x = x,
			y = y,
			vx = rng:NextNumber(-90, 90),
			vy = rng:NextNumber(-520, -280),
			life = CONFETTI_LIFE + rng:NextNumber(-0.3, 0.4),
		})
	end

	local t0 = os.clock()
	local grav = 520
	confettiConn = RunService.RenderStepped:Connect(function(dt)
		if my ~= confettiToken then
			return
		end
		local age = os.clock() - t0
		local alive = false
		for _, p in ipairs(parts) do
			if age > p.life then
				p.f.Visible = false
				continue
			end
			alive = true
			p.vy += grav * dt
			p.x += p.vx * dt
			p.y += p.vy * dt
			p.f.Position = UDim2.fromOffset(p.x, p.y)
			local fade = math.clamp(1 - (age / p.life), 0, 1)
			p.f.BackgroundTransparency = 1 - fade
		end
		if not alive or age > CONFETTI_LIFE + 1 then
			stopConfetti()
			if layer.Parent then
				layer:Destroy()
			end
		end
	end)
end

local function hideSummary()
	summaryOpen = false
	stopConfetti()
	if summaryGui then
		summaryGui.Enabled = false
	end
	local sel = GuiService.SelectedObject
	if finishBtn and sel == finishBtn then
		GuiService.SelectedObject = prevGuiSelected
	end
	prevGuiSelected = nil
end

function WaveSlot.dismissSummary()
	if summaryOpen then
		hideSummary()
	end
end

local function showSummary(summary: WaveSim.Summary)
	summaryOpen = true
	setHudVisible(false)
	applyIcon(false)

	if not summaryGui then
		local g = Instance.new("ScreenGui")
		g.Name = "OceanTD_WaveSummary"
		g.ResetOnSpawn = false
		g.IgnoreGuiInset = true
		g.DisplayOrder = 13000
		g.Parent = deps.playerGui
		summaryGui = g

		local dim = Instance.new("Frame")
		dim.Name = "Dim"
		dim.BackgroundColor3 = Color3.new(0, 0, 0)
		dim.BackgroundTransparency = 0.4
		dim.Size = UDim2.fromScale(1, 1)
		dim.BorderSizePixel = 0
		dim.ZIndex = 1
		dim.Parent = g

		local panel = Instance.new("Frame")
		panel.Name = "Panel"
		panel.AnchorPoint = Vector2.new(0.5, 0.5)
		panel.Position = UDim2.fromScale(0.5, 0.5)
		panel.Size = UDim2.fromOffset(420, 280)
		panel.BackgroundColor3 = Color3.fromRGB(16, 26, 38)
		panel.BorderSizePixel = 0
		panel.ZIndex = 2
		panel.Parent = g
		local pc = Instance.new("UICorner")
		pc.CornerRadius = UDim.new(0, 16)
		pc.Parent = panel

		local title = Instance.new("TextLabel")
		title.Name = "WaveReached"
		title.BackgroundTransparency = 1
		title.Position = UDim2.fromOffset(16, 36)
		title.Size = UDim2.new(1, -32, 0, 48)
		title.Font = UiTheme.Font
		title.TextSize = 36
		title.TextColor3 = Color3.new(1, 1, 1)
		title.TextXAlignment = Enum.TextXAlignment.Center
		title.ZIndex = 3
		title.Parent = panel

		local fed = Instance.new("TextLabel")
		fed.Name = "FishFed"
		fed.BackgroundTransparency = 1
		fed.Position = UDim2.fromOffset(16, 96)
		fed.Size = UDim2.new(1, -32, 0, 32)
		fed.Font = UiTheme.Font
		fed.TextSize = 24
		fed.TextColor3 = Color3.new(1, 1, 1)
		fed.TextXAlignment = Enum.TextXAlignment.Center
		fed.ZIndex = 3
		fed.Parent = panel

		local lasted = Instance.new("TextLabel")
		lasted.Name = "Lasted"
		lasted.BackgroundTransparency = 1
		lasted.Position = UDim2.fromOffset(16, 140)
		lasted.Size = UDim2.new(1, -32, 0, 28)
		lasted.Font = UiTheme.Font
		lasted.TextSize = 22
		lasted.TextColor3 = Color3.new(1, 1, 1)
		lasted.TextXAlignment = Enum.TextXAlignment.Center
		lasted.ZIndex = 3
		lasted.Parent = panel

		local finish = Instance.new("TextButton")
		finish.Name = "Finish"
		finish.AnchorPoint = Vector2.new(0.5, 1)
		finish.Position = UDim2.new(0.5, 0, 1, -18)
		finish.Size = UDim2.fromOffset(200, 44)
		finish.BackgroundColor3 = FINISH_GREEN
		finish.Font = UiTheme.Font
		finish.Text = "FINISH"
		finish.TextColor3 = Color3.new(1, 1, 1)
		finish.TextSize = 22
		finish.AutoButtonColor = true
		finish.Selectable = true
		finish.ZIndex = 4
		finish.Parent = panel
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(0, 10)
		fc.Parent = finish
		finish.Activated:Connect(function()
			hideSummary()
		end)
		finishBtn = finish
	end

	local g = summaryGui :: ScreenGui
	g.Enabled = true
	local panel = g:FindFirstChild("Panel")
	if panel and panel:IsA("Frame") then
		local title = panel:FindFirstChild("WaveReached")
		local fed = panel:FindFirstChild("FishFed")
		local lasted = panel:FindFirstChild("Lasted")
		if title and title:IsA("TextLabel") then
			title.Text = "Wave " .. tostring(summary.waveReached)
		end
		if fed and fed:IsA("TextLabel") then
			fed.Text = "Fish Fed " .. tostring(summary.fishFed)
		end
		if lasted and lasted:IsA("TextLabel") then
			lasted.Text = WaveSim.formatClock(summary.elapsedSec)
		end
		playConfetti(panel)
	end

	-- Joystick: select FINISH so A activates it immediately.
	if not finishBtn and panel then
		local found = panel:FindFirstChild("Finish")
		if found and found:IsA("TextButton") then
			finishBtn = found
			finishBtn.Selectable = true
		end
	end
	if isUsingGamepad() and finishBtn then
		prevGuiSelected = GuiService.SelectedObject
		GuiService.SelectedObject = finishBtn
	end
end

local function toggleWaves()
	if summaryOpen then
		return
	end
	-- Don't start/stop from Slot5 while backpack chrome is up (accidental focus/clicks).
	if InventoryState.isOpen() then
		return
	end
	if WaveSim.isRunning() then
		WaveSim.stop()
		deps.log("Waves stopped")
		return
	end
	local ok = WaveSim.start()
	if ok then
		applyIcon(true)
		deps.log("Waves started")
	else
		deps.log("Waves failed to start (route/fish?)")
	end
end

function WaveSlot.toggle()
	toggleWaves()
end

function WaveSlot.isSummaryOpen(): boolean
	return summaryOpen
end

function WaveSlot.mount(d: Deps)
	deps = d
	local quickbar = d.mainHUD:FindFirstChild("Quickbar")
	local found = if quickbar then quickbar:FindFirstChild("Slot5") else nil
	if found and found:IsA("GuiObject") then
		slot5 = found
		slot5Button = d.ensureButton(slot5)
		d.passthroughDecor(slot5, slot5Button)
		slot5Circle = d.ensureCircle(slot5)
		UiCircles.forceOnDescendants(slot5)
		applyIcon(false)
		d.ensureStroke(slot5Circle, "_OceanTD_WaveRing", Color3.new(1, 1, 1), 2).Enabled = false
		slot5Button.Selectable = false
		slot5Button.Activated:Connect(function()
			toggleWaves()
		end)
		d.log("Slot5 wave button ready")
	else
		warn("[WAVE] MainHUD.Quickbar.Slot5 missing — wave button unavailable")
	end

	local quickbarHelp = d.mainHUD:FindFirstChild("QuickbarHelp")
	if quickbarHelp then
		local hs = quickbarHelp:FindFirstChild("Slot5")
		if hs and hs:IsA("GuiObject") then
			helpSlot5 = hs
			helpSlot5.Active = false
			helpSlot5.Selectable = false
			for _, desc in ipairs(helpSlot5:GetDescendants()) do
				if desc:IsA("GuiObject") then
					desc.Active = false
					desc.Selectable = false
				end
			end
			local existingLetter = helpSlot5:FindFirstChild("_OceanTD_HelpLetter")
			if existingLetter and existingLetter:IsA("TextLabel") then
				helpSlot5Letter = existingLetter
			else
				if existingLetter then
					existingLetter:Destroy()
				end
				local letter = Instance.new("TextLabel")
				letter.Name = "_OceanTD_HelpLetter"
				letter.BackgroundTransparency = 1
				letter.Size = UDim2.fromScale(1, 1)
				letter.Font = UiTheme.Font
				letter.TextScaled = true
				letter.TextColor3 = Color3.new(1, 1, 1)
				letter.ZIndex = helpSlot5.ZIndex + 5
				letter.Parent = helpSlot5
				local pad = Instance.new("UIPadding")
				pad.PaddingTop = UDim.new(0.18, 0)
				pad.PaddingBottom = UDim.new(0.18, 0)
				pad.Parent = letter
				helpSlot5Letter = letter
			end
			UiCircles.ensure(helpSlot5)
			-- Optional hit proxy for badge click → same as Slot5
			local hit = helpSlot5:FindFirstChild("_OceanTD_HelpHit")
			if hit and hit:IsA("GuiButton") then
				helpHit = hit
			else
				if hit then
					hit:Destroy()
				end
				local btn = Instance.new("TextButton")
				btn.Name = "_OceanTD_HelpHit"
				btn.BackgroundTransparency = 1
				btn.Text = ""
				btn.Size = UDim2.fromScale(1, 1)
				btn.ZIndex = helpSlot5.ZIndex + 6
				btn.Parent = helpSlot5
				helpHit = btn
			end
			helpHit.Selectable = false
			helpHit.Activated:Connect(function()
				toggleWaves()
			end)
		end
	end

	WaveSlot.refreshHelpBadge()
	ensureHud()
	setSlot5Interactable(not InventoryState.isOpen())
	InventoryState.onOpenChanged(function(isOpen)
		setSlot5Interactable(not isOpen)
		WaveSlot.refreshHelpBadge()
	end)

	WaveSim.onHud(updateHud)
	WaveSim.onStopped(function(summary)
		setWaveCameraActive(false)
		applyIcon(false)
		if not summaryOpen then
			showSummary(summary)
		end
	end)

	UserInputService.LastInputTypeChanged:Connect(function()
		WaveSlot.refreshHelpBadge()
	end)
end

return WaveSlot
