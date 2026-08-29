--!strict
--[[
	Studio anchor: PlayerGui.MobileLeftUI.dPad.Settings (♪ opens volume UI).
	Settings modal: SFX/BGM volume, BGM shuffle/skip/play-pause.
	Close: button, B (gamepad), Backspace, Escape. Dim tap closes.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD")
local AudioSettings = require(oceanRoot:WaitForChild("Shared"):WaitForChild("AudioSettings"))
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))
local UiPopupScale = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPopupScale"))
local UiSlider = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiSlider"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local BgmController = require(script.Parent:WaitForChild("BgmController"))

local SettingsUI = {}

local ACCENT = Color3.fromRGB(0, 115, 237)
local PANEL_BG = Color3.fromRGB(18, 28, 40)
local BTN_BG = Color3.fromRGB(32, 44, 58)
local BTN_ON = Color3.fromRGB(40, 180, 80)
local CLOSE_RED = Color3.fromRGB(200, 45, 55)
local MUSIC_GLYPH = "♪"
local STUDIO_SETTINGS_NAME = "Settings"
local PANEL_W = 420
local PANEL_H = 400
local PANEL_STROKE = 2
local VIEWPORT_MARGIN = 12

local uiOpen = false
local openedAt = 0

local settingsAnchor: GuiObject? = nil
local settingsHitBtn: GuiButton? = nil
local settingsGui: ScreenGui? = nil
local settingsPanel: Frame? = nil
local viewportConn: RBXScriptConnection? = nil
local closeBtn: TextButton? = nil
local shuffleBtn: TextButton? = nil
local playBtn: TextButton? = nil
local skipBtn: TextButton? = nil
local trackLabel: TextLabel? = nil
local sfxSlider: UiSlider.SliderHandle? = nil
local bgmSlider: UiSlider.SliderHandle? = nil

local function fittedPanelSize(vp: Vector2): Vector2
	local scale = UiPopupScale.get(vp)
	local maxW = math.min(PANEL_W, math.floor(vp.X * 0.92 / scale))
	local maxH = math.min(PANEL_H, math.floor(vp.Y * 0.88 / scale))
	return Vector2.new(math.max(320, maxW), math.max(340, maxH))
end

local function positionPanelNearAnchor()
	local panel = settingsPanel
	if not panel then
		return
	end
	local anchor = settingsAnchor
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local target = fittedPanelSize(vp)
	local scale = UiPopupScale.get(vp)
	local visualW = target.X * scale
	local visualH = target.Y * scale

	if not anchor or not anchor:IsDescendantOf(playerGui) then
		panel.AnchorPoint = Vector2.new(0.5, 0.5)
		panel.Position = UDim2.fromScale(0.5, 0.5)
		panel.Size = UDim2.fromOffset(target.X, target.Y)
		return
	end

	local aPos = anchor.AbsolutePosition
	local aSize = anchor.AbsoluteSize
	local x = aPos.X + aSize.X + VIEWPORT_MARGIN
	local y = aPos.Y

	if x + visualW > vp.X - VIEWPORT_MARGIN then
		x = math.max(VIEWPORT_MARGIN, aPos.X - VIEWPORT_MARGIN - target.X * scale)
	end
	if y + visualH > vp.Y - VIEWPORT_MARGIN then
		y = math.max(VIEWPORT_MARGIN, vp.Y - VIEWPORT_MARGIN - visualH)
	end
	x = math.clamp(x, VIEWPORT_MARGIN, math.max(VIEWPORT_MARGIN, vp.X - VIEWPORT_MARGIN - visualW))
	y = math.clamp(y, VIEWPORT_MARGIN, math.max(VIEWPORT_MARGIN, vp.Y - VIEWPORT_MARGIN - visualH))

	panel.AnchorPoint = Vector2.new(0, 0)
	panel.Position = UDim2.fromOffset(x, y)
	panel.Size = UDim2.fromOffset(target.X, target.Y)
end

local function ensureSettingsHit(host: GuiObject): GuiButton
	host.Active = true
	if host:IsA("GuiButton") then
		return host
	end
	local existing = host:FindFirstChild("_OceanTD_SettingsHit")
	if existing and existing:IsA("GuiButton") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local hit = Instance.new("TextButton")
	hit.Name = "_OceanTD_SettingsHit"
	hit.BackgroundTransparency = 1
	hit.BorderSizePixel = 0
	hit.Size = UDim2.fromScale(1, 1)
	hit.Text = ""
	hit.ZIndex = host.ZIndex + 10
	hit.AutoButtonColor = false
	hit.Selectable = true
	hit.Parent = host
	return hit
end

local function applyMusicGlyph(host: GuiObject)
	if host:IsA("TextButton") then
		host.Text = MUSIC_GLYPH
		host.Font = UiTheme.Font
		host.TextScaled = true
		host.TextColor3 = Color3.new(1, 1, 1)
		return
	end
	if host:IsA("TextLabel") then
		host.Text = MUSIC_GLYPH
		host.Font = UiTheme.Font
		host.TextScaled = true
		return
	end
	local lbl = host:FindFirstChild("_OceanTD_MusicGlyph")
	if lbl and lbl:IsA("TextLabel") then
		lbl.Text = MUSIC_GLYPH
		return
	end
	if lbl then
		lbl:Destroy()
	end
	local note = Instance.new("TextLabel")
	note.Name = "_OceanTD_MusicGlyph"
	note.BackgroundTransparency = 1
	note.Size = UDim2.fromScale(1, 1)
	note.Font = UiTheme.Font
	note.Text = MUSIC_GLYPH
	note.TextColor3 = Color3.new(1, 1, 1)
	note.TextScaled = true
	note.ZIndex = host.ZIndex + 2
	note.Active = false
	note.Parent = host
end

local function wireStudioSettingsButton(leftOpt: Instance?)
	local left = leftOpt or playerGui:FindFirstChild("MobileLeftUI") or playerGui:WaitForChild("MobileLeftUI", 60)
	if not left then
		warn("[SettingsUI] PlayerGui.MobileLeftUI missing")
		return
	end
	LeftHudLayout.hardenScreenGui(left)
	local dPad = left:FindFirstChild("dPad") or left:WaitForChild("dPad", 30)
	if not dPad then
		warn("[SettingsUI] MobileLeftUI.dPad missing")
		return
	end
	local anchor = dPad:FindFirstChild(STUDIO_SETTINGS_NAME) or dPad:WaitForChild(STUDIO_SETTINGS_NAME, 30)
	if not anchor or not anchor:IsA("GuiObject") then
		warn("[SettingsUI] MobileLeftUI.dPad.Settings missing — add anchor in Studio")
		return
	end
	-- Already wired to this live anchor.
	if settingsAnchor == anchor and settingsHitBtn and settingsHitBtn.Parent then
		return
	end
	settingsAnchor = anchor
	applyMusicGlyph(anchor)
	local hit = ensureSettingsHit(anchor)
	settingsHitBtn = hit
	if hit ~= anchor then
		applyMusicGlyph(hit)
	end
	if not hit:GetAttribute("_OceanTD_SettingsWired") then
		hit:SetAttribute("_OceanTD_SettingsWired", true)
		hit.Activated:Connect(function()
			UiHaptics.pulseShort()
			SettingsUI.toggle()
		end)
	end
end

local function ensureViewportWatch()
	if viewportConn then
		return
	end
	local function bind(cam: Camera?)
		if viewportConn then
			viewportConn:Disconnect()
			viewportConn = nil
		end
		if not cam then
			return
		end
		viewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if uiOpen then
				positionPanelNearAnchor()
			end
		end)
	end
	bind(Workspace.CurrentCamera)
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		bind(Workspace.CurrentCamera)
		if uiOpen then
			positionPanelNearAnchor()
		end
	end)
end

local function isUsingGamepad(): boolean
	local last = UserInputService:GetLastInputType()
	return last == Enum.UserInputType.Gamepad1
		or last == Enum.UserInputType.Gamepad2
		or last == Enum.UserInputType.Gamepad3
		or last == Enum.UserInputType.Gamepad4
end

local function refreshCloseLabel()
	if not closeBtn then
		return
	end
	if isUsingGamepad() then
		closeBtn.Text = "B"
	else
		closeBtn.Text = "Close"
	end
end

local function refreshShuffleBtn()
	if not shuffleBtn then
		return
	end
	local on = BgmController.isShuffle()
	shuffleBtn.BackgroundColor3 = if on then BTN_ON else BTN_BG
	shuffleBtn.Text = if on then "Shuffle: On" else "Shuffle: Off"
end

local function refreshPlayBtn()
	if not playBtn then
		return
	end
	if BgmController.isPlaying() then
		playBtn.Text = "Pause"
	else
		playBtn.Text = "Play"
	end
end

local function refreshTrackLabel()
	if not trackLabel then
		return
	end
	if BgmController.getTrackCount() == 0 then
		trackLabel.Text = "Add Sound objects to Workspace.Audio.BG Music"
	else
		trackLabel.Text = BgmController.getCurrentTrackLabel()
	end
end

local function refreshTransport()
	refreshShuffleBtn()
	refreshPlayBtn()
	refreshTrackLabel()
end

local function makeSectionLabel(parent: Instance, text: string, order: number): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.new(1, 0, 0, 24)
	lbl.Font = UiTheme.Font
	lbl.Text = text
	lbl.TextColor3 = Color3.fromRGB(220, 230, 245)
	lbl.TextSize = 20
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.LayoutOrder = order
	lbl.Parent = parent
	return lbl
end

local function makeTransportBtn(parent: Instance, name: string, text: string, order: number): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Size = UDim2.fromOffset(118, 40)
	btn.BackgroundColor3 = BTN_BG
	btn.BorderSizePixel = 0
	btn.Font = UiTheme.Font
	btn.Text = text
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.TextSize = 18
	btn.AutoButtonColor = true
	btn.Selectable = true
	btn.LayoutOrder = order
	btn.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = btn
	return btn
end

local function ensureSettingsUi()
	if settingsGui and settingsPanel then
		return
	end

	local g = Instance.new("ScreenGui")
	g.Name = "OceanTD_Settings"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 12055
	g.Enabled = false
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	g.Parent = playerGui
	settingsGui = g

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.45
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Active = true
	dim.ZIndex = 1
	dim.Parent = g
	dim.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if os.clock() - openedAt < 0.3 then
				return
			end
			SettingsUI.close()
		end
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 0)
	panel.Position = UDim2.fromOffset(0, 0)
	panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
	panel.BackgroundColor3 = PANEL_BG
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Active = true
	panel.ClipsDescendants = false
	panel.SelectionGroup = true
	panel.Parent = g
	settingsPanel = panel
	UiPopupScale.attach(panel)
	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 14)
	panelCorner.Parent = panel
	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = ACCENT
	panelStroke.Thickness = PANEL_STROKE
	panelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	panelStroke.Parent = panel
	local panelPad = Instance.new("UIPadding")
	panelPad.PaddingTop = UDim.new(0, PANEL_STROKE)
	panelPad.PaddingBottom = UDim.new(0, PANEL_STROKE)
	panelPad.PaddingLeft = UDim.new(0, PANEL_STROKE)
	panelPad.PaddingRight = UDim.new(0, PANEL_STROKE)
	panelPad.Parent = panel
	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = Vector2.new(320, 340)
	sizeConstraint.MaxSize = Vector2.new(520, 520)
	sizeConstraint.Parent = panel

	local chrome = Instance.new("Frame")
	chrome.Name = "Chrome"
	chrome.BackgroundTransparency = 1
	chrome.Size = UDim2.fromScale(1, 1)
	chrome.ZIndex = 3
	chrome.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 12)
	title.Size = UDim2.new(1, -100, 0, 28)
	title.Font = UiTheme.Font
	title.Text = "Settings"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextSize = 24
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 3
	title.Parent = chrome

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -10, 0, 8)
	close.Size = UDim2.fromOffset(78, 32)
	close.BackgroundColor3 = CLOSE_RED
	close.Font = UiTheme.Font
	close.Text = "Close"
	close.TextColor3 = Color3.new(1, 1, 1)
	close.TextSize = 16
	close.AutoButtonColor = true
	close.Selectable = true
	close.ZIndex = 4
	close.Parent = chrome
	closeBtn = close
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 8)
	closeCorner.Parent = close
	close.Activated:Connect(function()
		UiHaptics.pulseShort()
		SettingsUI.close()
	end)

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Position = UDim2.fromOffset(16, 48)
	body.Size = UDim2.new(1, -32, 1, -56)
	body.BackgroundTransparency = 1
	body.ClipsDescendants = false
	body.ZIndex = 3
	body.Parent = chrome
	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.Padding = UDim.new(0, 8)
	bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bodyLayout.Parent = body

	makeSectionLabel(body, "Sound Effects", 1)
	sfxSlider = UiSlider.create(body, {
		name = "SfxSlider",
		layoutOrder = 2,
		height = 44,
		accentColor = ACCENT,
		onChanged = function(v)
			AudioSettings.setSfxVolume(v)
		end,
	})
	sfxSlider.setValue(AudioSettings.getSfxVolume(), false)

	makeSectionLabel(body, "Background Music", 3)
	bgmSlider = UiSlider.create(body, {
		name = "BgmSlider",
		layoutOrder = 4,
		height = 44,
		accentColor = ACCENT,
		onChanged = function(v)
			AudioSettings.setBgmVolume(v)
		end,
	})
	bgmSlider.setValue(AudioSettings.getBgmVolume(), false)

	trackLabel = Instance.new("TextLabel")
	trackLabel.Name = "TrackLabel"
	trackLabel.BackgroundTransparency = 1
	trackLabel.Size = UDim2.new(1, 0, 0, 22)
	trackLabel.Font = UiTheme.Font
	trackLabel.Text = ""
	trackLabel.TextColor3 = Color3.fromRGB(170, 185, 205)
	trackLabel.TextSize = 16
	trackLabel.TextXAlignment = Enum.TextXAlignment.Left
	trackLabel.LayoutOrder = 5
	trackLabel.Parent = body

	local transportRow = Instance.new("Frame")
	transportRow.Name = "Transport"
	transportRow.BackgroundTransparency = 1
	transportRow.Size = UDim2.new(1, 0, 0, 44)
	transportRow.LayoutOrder = 6
	transportRow.Parent = body
	local transportLayout = Instance.new("UIListLayout")
	transportLayout.FillDirection = Enum.FillDirection.Horizontal
	transportLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	transportLayout.Padding = UDim.new(0, 8)
	transportLayout.SortOrder = Enum.SortOrder.LayoutOrder
	transportLayout.Parent = transportRow

	shuffleBtn = makeTransportBtn(transportRow, "Shuffle", "Shuffle: Off", 1)
	playBtn = makeTransportBtn(transportRow, "PlayPause", "Play", 2)
	skipBtn = makeTransportBtn(transportRow, "Skip", "Skip", 3)

	shuffleBtn.Activated:Connect(function()
		UiHaptics.pulseShort()
		BgmController.setShuffle(not BgmController.isShuffle())
		refreshTransport()
	end)
	playBtn.Activated:Connect(function()
		UiHaptics.pulseShort()
		BgmController.togglePlayPause()
		refreshTransport()
	end)
	skipBtn.Activated:Connect(function()
		UiHaptics.pulseShort()
		BgmController.skip()
		refreshTransport()
	end)

	local sfxTrack = sfxSlider.root:FindFirstChild("Track") :: GuiObject?
	local bgmTrack = bgmSlider.root:FindFirstChild("Track") :: GuiObject?
	close.NextSelectionDown = sfxTrack
	if sfxTrack then
		sfxTrack.NextSelectionDown = bgmTrack
	end
	if bgmTrack then
		bgmTrack.NextSelectionDown = shuffleBtn
	end
	shuffleBtn.NextSelectionRight = playBtn
	playBtn.NextSelectionLeft = shuffleBtn
	playBtn.NextSelectionRight = skipBtn
	skipBtn.NextSelectionLeft = playBtn
	skipBtn.NextSelectionDown = close

	BgmController.StateChanged:Connect(refreshTransport)
	refreshTransport()
end

function SettingsUI.isOpen(): boolean
	return uiOpen
end

function SettingsUI.close()
	if not uiOpen then
		return
	end
	uiOpen = false
	InventoryState.setSettingsOpen(false)
	if settingsGui then
		settingsGui.Enabled = false
	end
	GuiService.SelectedObject = nil
end

function SettingsUI.open()
	if uiOpen then
		return
	end
	AudioSettings.init()
	ensureSettingsUi()
	if settingsPanel then
		UiPopupScale.attach(settingsPanel)
	end
	positionPanelNearAnchor()
	if sfxSlider then
		sfxSlider.setValue(AudioSettings.getSfxVolume(), false)
	end
	if bgmSlider then
		bgmSlider.setValue(AudioSettings.getBgmVolume(), false)
	end
	refreshCloseLabel()
	refreshTransport()
	uiOpen = true
	openedAt = os.clock()
	InventoryState.setSettingsOpen(true)
	if settingsGui then
		settingsGui.Enabled = true
	end
	task.defer(function()
		if uiOpen and isUsingGamepad() and closeBtn then
			GuiService.SelectedObject = closeBtn
		end
	end)
end

function SettingsUI.toggle()
	if uiOpen then
		SettingsUI.close()
	else
		SettingsUI.open()
	end
end

function SettingsUI.handleCancelInput(): boolean
	if not uiOpen then
		return false
	end
	SettingsUI.close()
	return true
end

function SettingsUI.init()
	AudioSettings.init()
	local legacy = playerGui:FindFirstChild("OceanTD_SettingsMusic")
	if legacy then
		legacy:Destroy()
	end
	ensureViewportWatch()
	task.spawn(function()
		local left = playerGui:WaitForChild("MobileLeftUI", 60)
		if not left then
			warn("[SettingsUI] PlayerGui.MobileLeftUI missing")
			return
		end
		LeftHudLayout.watchMobileLeftUi(playerGui, wireStudioSettingsButton)
		task.spawn(function()
			while true do
				task.wait(2)
				if not settingsHitBtn or not settingsHitBtn.Parent then
					local cur = playerGui:FindFirstChild("MobileLeftUI")
					if cur then
						settingsAnchor = nil
						wireStudioSettingsButton(cur)
					end
				end
			end
		end)
	end)
end

UserInputService.LastInputTypeChanged:Connect(refreshCloseLabel)

return SettingsUI
