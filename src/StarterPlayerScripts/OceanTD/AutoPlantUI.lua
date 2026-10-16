--!strict
--[[
	Backpack header: Auto Plant toggle, ADD MAX, shuffle dice.
	Mounted above coral sections by InventoryUI.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local AutoPlantSpots = require(oceanRoot:WaitForChild("Shared"):WaitForChild("AutoPlantSpots"))
local AudioSettings = require(oceanRoot:WaitForChild("Shared"):WaitForChild("AudioSettings"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local UiPopupScale = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPopupScale"))
local CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual"))

local DICE_IMAGE = "rbxassetid://77867192113507"
local MOVE_ICON_IMAGE = "rbxassetid://345081302"
local SHUFFLE_CONFIRM_SOUND_ID = "rbxassetid://1837834188"
local AUTO_PLANT_WOOSH_SOUND_ID = "rbxassetid://121895510799294"
local SHUFFLE_COMPLETE_SOUND_ID = "rbxassetid://109783075001296"
local ICON_SWAP_SEC = 0.7
local SLIDE_SOUND_IDS = {
	"rbxassetid://104320740588882",
	"rbxassetid://138097048",
	"rbxassetid://93030066468333",
	"rbxassetid://122348488423751",
	"rbxassetid://72367167667857",
}
local GREEN = Color3.fromRGB(40, 170, 70)
local GREEN_DARK = Color3.fromRGB(18, 90, 36)
local BLUE = Color3.fromRGB(45, 130, 220)
local BLUE_DARK = Color3.fromRGB(18, 60, 130)
local RED = Color3.fromRGB(190, 45, 55)
local RED_DARK = Color3.fromRGB(100, 20, 28)
local GREY = Color3.fromRGB(70, 78, 90)
local WHITE = Color3.new(1, 1, 1)
local ORB_FLY_SEC = 0.85 * 1.2 -- 20% slower backpack → ground
local ADD_MAX_ORB_STAGGER = 0.09
local SHUFFLE_STAGGER_SPREAD = 1.35 -- first coral ~0s, last ~1.35s
local SHUFFLE_SLIDE_MIN = 0.45
local SHUFFLE_SLIDE_MAX = 1.25
local SHUFFLE_SFX_MAX = 10 -- concurrent slide voices cap
local CONFIRM_BTN_MAX_TEXT = 18 -- ~2 sizes smaller than full button fill

local AutoPlantUI = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local unlocked = false
local enabled = false
local manualCount = 0
local addMaxCapacity = 0
local addMaxCount = 0
local cooldownEndsAt = 0
local hostRow: Frame? = nil
local toggleShell: Frame? = nil
local toggleBtn: TextButton? = nil
local addMaxShell: Frame? = nil
local addMaxBtn: TextButton? = nil
local shuffleBtn: ImageButton? = nil
local lockLabel: TextLabel? = nil
local cdLabel: TextLabel? = nil
local confirmGui: ScreenGui? = nil
local confirmPanel: Frame? = nil
local confirmCheck: TextButton? = nil
local confirmCancel: TextButton? = nil
local confirmDim: Frame? = nil
local confirmOpenedAt = 0
local addMaxGui: ScreenGui? = nil
local addMaxPanel: Frame? = nil
local addMaxCheck: TextButton? = nil
local addMaxCancel: TextButton? = nil
local addMaxCountLabel: TextLabel? = nil
local addMaxOpenedAt = 0
local cdToken = 0
local shuffleAnimToken = 0
local shuffleClientStarted = false
local shuffleAnimBusy = false
local shuffleRequestBusy = false -- InvokeServer still applying grid moves
local shuffleAnimEndsAt = 0
local addMaxAnimToken = 0
local addMaxAnimBusy = false
local addMaxRequestBusy = false
local addMaxClientStarted = false
local addMaxAnimEndsAt = 0
local addMaxShowCountdown = false -- placing more than 5 at once
local addMaxCdToken = 0
local slideSfxActive = 0
local shuffleIconShowDice = true
local shuffleIconSwapToken = 0

local confirmSound = Instance.new("Sound")
confirmSound.Name = "OceanTD_AutoPlantShuffleConfirm"
confirmSound.SoundId = SHUFFLE_CONFIRM_SOUND_ID
confirmSound.Volume = 0.9
confirmSound.Parent = SoundService
AudioSettings.markPrioritySfx(confirmSound)

local wooshSound = Instance.new("Sound")
wooshSound.Name = "OceanTD_AutoPlantWoosh"
wooshSound.SoundId = AUTO_PLANT_WOOSH_SOUND_ID
wooshSound.Volume = 1.6
wooshSound.Parent = SoundService
AudioSettings.markPrioritySfx(wooshSound)

local completeSound = Instance.new("Sound")
completeSound.Name = "OceanTD_AutoPlantShuffleComplete"
completeSound.SoundId = SHUFFLE_COMPLETE_SOUND_ID
completeSound.Volume = 1
completeSound.Parent = SoundService
AudioSettings.markPrioritySfx(completeSound)

local slideSoundTemplates: { Sound } = {}
for i, id in ipairs(SLIDE_SOUND_IDS) do
	local s = Instance.new("Sound")
	s.Name = "OceanTD_AutoPlantSlide_" .. tostring(i)
	s.SoundId = id
	s.Volume = 1.35
	s.Parent = SoundService
	AudioSettings.markPrioritySfx(s)
	table.insert(slideSoundTemplates, s)
end

local function playConfirmSfx()
	AudioSettings.markPrioritySfx(confirmSound)
	if confirmSound.IsPlaying then
		confirmSound:Stop()
	end
	confirmSound.TimePosition = 0
	confirmSound:Play()
end

local function playWooshSfx()
	local s = wooshSound:Clone()
	s.Volume = 1.6
	s.Parent = SoundService
	AudioSettings.markPrioritySfx(s)
	s.PlaybackSpeed = 0.85 + math.random() * 0.3
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
end

local function playShuffleCompleteSfx()
	local s = completeSound:Clone()
	s.Volume = 1
	s.Parent = SoundService
	AudioSettings.markPrioritySfx(s)
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
end

local function playSlideSfx(totalMoves: number)
	if slideSfxActive >= SHUFFLE_SFX_MAX or #slideSoundTemplates == 0 then
		return
	end
	-- Soft throttle so big plots don't queue a whoosh for every coral.
	local chance = math.clamp(SHUFFLE_SFX_MAX / math.max(totalMoves * 0.35, 1), 0.45, 1)
	if math.random() > chance then
		return
	end
	-- Denser shuffles: slightly higher / wider pitch; still capped by voice count.
	local density = math.clamp(totalMoves / 16, 0, 1)
	local template = slideSoundTemplates[math.random(1, #slideSoundTemplates)]
	local s = template:Clone()
	s.Volume = 1.25 + math.random() * 0.25
	s.Parent = SoundService
	AudioSettings.markPrioritySfx(s)
	s.PlaybackSpeed = (0.78 + density * 0.22) + math.random() * (0.28 + density * 0.18)
	slideSfxActive += 1
	s:Play()
	s.Ended:Once(function()
		slideSfxActive = math.max(0, slideSfxActive - 1)
		s:Destroy()
	end)
end

local function setGridAnchor(part: BasePart, pos: Vector3)
	part:SetAttribute("OceanTD_GridAnchorX", pos.X)
	part:SetAttribute("OceanTD_GridAnchorY", pos.Y)
	part:SetAttribute("OceanTD_GridAnchorZ", pos.Z)
end

local function applyFillGradient(btn: GuiObject, top: Color3, bottom: Color3)
	local g = btn:FindFirstChildOfClass("UIGradient")
	if not g then
		g = Instance.new("UIGradient")
		g.Parent = btn
	end
	g.Rotation = 90
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, top),
		ColorSequenceKeypoint.new(1, bottom),
	})
end

local function applyStrokeGradient(stroke: UIStroke, top: Color3, bottom: Color3)
	-- White base so the gradient shows at full brightness (default black reads muddy).
	stroke.Color = WHITE
	local g = stroke:FindFirstChildOfClass("UIGradient")
	if not g then
		g = Instance.new("UIGradient")
		g.Parent = stroke
	end
	g.Rotation = 90
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, top),
		ColorSequenceKeypoint.new(1, bottom),
	})
end

local function refreshToggleVisual()
	local btn = toggleBtn
	local shell = toggleShell
	if not btn or not shell then
		return
	end
	btn.TextColor3 = WHITE
	if not unlocked then
		btn.Text = "AUTO PLANT"
		btn.AutoButtonColor = false
		shell.BackgroundColor3 = GREY
		applyFillGradient(shell, Color3.fromRGB(90, 96, 108), GREY)
		local stroke = shell:FindFirstChildOfClass("UIStroke")
		if stroke then
			applyStrokeGradient(stroke, Color3.fromRGB(200, 205, 215), Color3.fromRGB(140, 145, 155))
		end
		if lockLabel then
			local have = math.max(0, manualCount)
			local need = AutoPlantSpots.MANUAL_UNLOCK_COUNT
			local left = math.max(0, need - have)
			lockLabel.Text = if left > 0
				then string.format("Need %d corals on plot (%d/%d)", left, have, need)
				else "Unlocked"
			lockLabel.Visible = true
		end
		return
	end
	if lockLabel then
		lockLabel.Visible = false
	end
	btn.AutoButtonColor = true
	if enabled then
		btn.Text = "AUTO PLANT ON"
		shell.BackgroundColor3 = GREEN
		applyFillGradient(shell, Color3.fromRGB(90, 230, 120), GREEN_DARK)
		local stroke = shell:FindFirstChildOfClass("UIStroke")
		if stroke then
			applyStrokeGradient(stroke, Color3.fromRGB(120, 255, 150), Color3.fromRGB(40, 220, 90))
		end
	else
		btn.Text = "AUTO PLANT OFF"
		shell.BackgroundColor3 = RED
		applyFillGradient(shell, Color3.fromRGB(255, 110, 120), RED_DARK)
		local stroke = shell:FindFirstChildOfClass("UIStroke")
		if stroke then
			applyStrokeGradient(stroke, Color3.fromRGB(255, 120, 130), Color3.fromRGB(255, 50, 70))
		end
	end
end

local function applyShuffleIconImage()
	local btn = shuffleBtn
	if not btn then
		return
	end
	local icon = btn:FindFirstChild("DiceIcon")
	if icon and icon:IsA("ImageLabel") then
		icon.Image = if shuffleIconShowDice then DICE_IMAGE else MOVE_ICON_IMAGE
	end
end

local function tickShuffleIconSwap()
	shuffleIconSwapToken += 1
	local token = shuffleIconSwapToken
	task.spawn(function()
		while token == shuffleIconSwapToken do
			applyShuffleIconImage()
			task.wait(ICON_SWAP_SEC)
			if token ~= shuffleIconSwapToken then
				break
			end
			shuffleIconShowDice = not shuffleIconShowDice
		end
	end)
end

local function refreshShuffleVisual()
	local btn = shuffleBtn
	if not btn then
		return
	end
	local left = math.max(0, cooldownEndsAt - os.clock())
	local locked = left > 0.05 or shuffleAnimBusy or shuffleRequestBusy or addMaxAnimBusy or addMaxRequestBusy
	local ready = not locked and unlocked
	local icon = btn:FindFirstChild("DiceIcon")
	if icon and icon:IsA("ImageLabel") then
		icon.ImageColor3 = if ready then WHITE else Color3.fromRGB(120, 120, 130)
		applyShuffleIconImage()
	end
	btn.BackgroundColor3 = if ready then GREEN else GREY
	btn.AutoButtonColor = ready
	if cdLabel then
		if left > 0.05 then
			cdLabel.Visible = true
			cdLabel.Text = string.format("%.0f", math.ceil(left))
		else
			cdLabel.Visible = false
		end
	end
	local stroke = btn:FindFirstChildOfClass("UIStroke")
	if stroke then
		if ready then
			applyStrokeGradient(stroke, Color3.fromRGB(120, 255, 150), Color3.fromRGB(40, 220, 90))
		else
			applyStrokeGradient(stroke, Color3.fromRGB(180, 185, 195), Color3.fromRGB(120, 125, 135))
		end
	end
end

-- Whole-process duration scale for large ADD MAX (stagger + orb fly + dig).
-- SFX PlaybackSpeed is left alone — only the sequence timing is shortened.
-- 100+: 35% faster; 200+: 55% faster.
local function addMaxDurationScale(count: number): number
	local n = math.max(0, math.floor(count))
	if n >= 200 then
		return 0.45
	elseif n >= 100 then
		return 0.65
	end
	return 1
end

local ADD_MAX_DIG_TAIL_SEC = 3.4 -- plant-only dig window (+ small buffer)

local function estimateAddMaxSec(count: number): number
	local n = math.max(0, math.floor(count))
	local scale = addMaxDurationScale(n)
	-- Orb fly + stagger + plant-only dig work window (matches playAddMaxPlacements).
	return (ORB_FLY_SEC + n * ADD_MAX_ORB_STAGGER + ADD_MAX_DIG_TAIL_SEC) * scale
end

local function refreshAddMaxVisual()
	local btn = addMaxBtn
	local shell = addMaxShell
	if not btn or not shell then
		return
	end
	local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
	local waves = WaveSim.isRunning and WaveSim.isRunning()
	local liveCap = math.min(addMaxCapacity, InventoryState.getTotalSeedCount())
	local busy = addMaxAnimBusy or addMaxRequestBusy
	local left = math.max(0, addMaxAnimEndsAt - os.clock())
	-- Stick at 1s if estimate undershoots but placement is still running.
	local showCd = addMaxShowCountdown and busy
	local canUse = unlocked
		and liveCap > 0
		and not waves
		and not shuffleAnimBusy
		and not shuffleRequestBusy
		and not busy
	btn.TextColor3 = WHITE
	btn.Text = if showCd then string.format("%.0f", math.max(1, math.ceil(left))) else "ADD MAX"
	btn.AutoButtonColor = canUse
	if canUse then
		shell.BackgroundColor3 = BLUE
		applyFillGradient(shell, Color3.fromRGB(95, 175, 255), BLUE_DARK)
		local stroke = shell:FindFirstChildOfClass("UIStroke")
		if stroke then
			applyStrokeGradient(stroke, Color3.fromRGB(140, 210, 255), Color3.fromRGB(40, 140, 255))
		end
	else
		shell.BackgroundColor3 = GREY
		applyFillGradient(shell, Color3.fromRGB(90, 96, 108), GREY)
		local stroke = shell:FindFirstChildOfClass("UIStroke")
		if stroke then
			applyStrokeGradient(stroke, Color3.fromRGB(200, 205, 215), Color3.fromRGB(140, 145, 155))
		end
	end
end

local function tickAddMaxCountdown()
	addMaxCdToken += 1
	local token = addMaxCdToken
	task.spawn(function()
		while token == addMaxCdToken do
			refreshAddMaxVisual()
			local left = addMaxAnimEndsAt - os.clock()
			if left <= 0.05 and not addMaxAnimBusy and not addMaxRequestBusy then
				refreshAddMaxVisual()
				break
			end
			task.wait(0.2)
		end
	end)
end

local function beginAddMaxCountdown(count: number)
	if count <= 5 then
		addMaxShowCountdown = false
		return
	end
	addMaxShowCountdown = true
	addMaxAnimEndsAt = os.clock() + estimateAddMaxSec(count)
	tickAddMaxCountdown()
end

local function shrinkConfirmBtnText(btn: TextButton)
	local c = btn:FindFirstChildOfClass("UITextSizeConstraint")
	if not c then
		c = Instance.new("UITextSizeConstraint")
		c.Parent = btn
	end
	c.MaxTextSize = CONFIRM_BTN_MAX_TEXT
	c.MinTextSize = 10
end

local function tickCooldown()
	cdToken += 1
	local token = cdToken
	task.spawn(function()
		while token == cdToken do
			refreshShuffleVisual()
			if os.clock() >= cooldownEndsAt and not shuffleAnimBusy and not shuffleRequestBusy then
				refreshShuffleVisual()
				break
			end
			task.wait(0.2)
		end
	end)
end

-- Apply server remaining-cooldown without restarting a full CD from a late packet.
local function applyCooldownRemaining(cd: number?)
	local remaining = tonumber(cd)
	if typeof(remaining) ~= "number" or remaining <= 0.05 then
		return
	end
	local newEnd = os.clock() + remaining
	-- Only extend (or set) — never restart a finished/local timer from a stale full CD.
	if newEnd > cooldownEndsAt + 0.15 then
		cooldownEndsAt = newEnd
		tickCooldown()
	end
end

local function applyState(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	unlocked = payload.unlocked == true
	enabled = payload.enabled == true
	manualCount = math.max(
		0,
		math.floor(tonumber(payload.plotCoralCount) or tonumber(payload.manualPlantCount) or 0)
	)
	local cap = math.floor(tonumber(payload.addMaxCapacity) or 0)
	if cap == cap and cap >= 0 then
		addMaxCapacity = cap
	end
	applyCooldownRemaining(payload.shuffleCooldownSec)
	refreshToggleVisual()
	refreshShuffleVisual()
	refreshAddMaxVisual()
end

local function ensureConfirmUi()
	if confirmGui and confirmPanel and confirmCheck and confirmCancel then
		return
	end
	local g = Instance.new("ScreenGui")
	g.Name = "OceanTD_AutoPlantShuffleConfirm"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 12055
	g.Enabled = false
	g.Parent = playerGui
	confirmGui = g

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.45
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Active = true
	dim.ZIndex = 1
	dim.Parent = g
	confirmDim = dim
	dim.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if os.clock() - confirmOpenedAt < 0.35 then
				return
			end
			AutoPlantUI.cancelConfirm()
		end
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(420, 220)
	panel.BackgroundColor3 = Color3.fromRGB(18, 28, 40)
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Active = true
	panel.Parent = g
	confirmPanel = panel
	UiPopupScale.attach(panel)
	Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 14)
	local pStroke = Instance.new("UIStroke")
	pStroke.Color = Color3.fromRGB(80, 140, 180)
	pStroke.Thickness = 2
	pStroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 18)
	title.Size = UDim2.new(1, -32, 0, 40)
	title.Font = UiTheme.Font
	title.Text = "Shuffle every coral's location on your plot?"
	title.TextColor3 = WHITE
	title.TextScaled = true
	title.TextWrapped = true
	title.ZIndex = 3
	title.Parent = panel

	local sub = Instance.new("TextLabel")
	sub.BackgroundTransparency = 1
	sub.Position = UDim2.fromOffset(16, 68)
	sub.Size = UDim2.new(1, -32, 0, 56)
	sub.Font = UiTheme.Font
	sub.Text = "This will move every coral you have to a new spot (Can Undo)"
	sub.TextColor3 = Color3.fromRGB(170, 190, 210)
	sub.TextScaled = true
	sub.TextWrapped = true
	sub.ZIndex = 3
	sub.Parent = panel

	local function makeWideBtn(text: string, color: Color3, strokeColor: Color3): TextButton
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.42, 0, 0, 42)
		b.BackgroundColor3 = color
		b.Font = UiTheme.Font
		b.Text = text
		b.TextColor3 = WHITE
		b.TextScaled = true
		b.AutoButtonColor = true
		b.ZIndex = 4
		b.Parent = panel
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 10)
		local edge = Instance.new("UIStroke")
		edge.Color = strokeColor
		edge.Thickness = 2.5
		edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		edge.Parent = b
		shrinkConfirmBtnText(b)
		return b
	end

	confirmCheck = makeWideBtn("CONFIRM", GREEN, Color3.fromRGB(12, 70, 28))
	confirmCancel = makeWideBtn("CANCEL", RED, Color3.fromRGB(90, 12, 18))
	confirmCheck.AnchorPoint = Vector2.new(0, 1)
	confirmCheck.Position = UDim2.new(0, 20, 1, -18)
	confirmCancel.AnchorPoint = Vector2.new(1, 1)
	confirmCancel.Position = UDim2.new(1, -20, 1, -18)
	confirmCheck.Activated:Connect(function()
		AutoPlantUI.commitShuffle()
	end)
	confirmCancel.Activated:Connect(function()
		AutoPlantUI.cancelConfirm()
	end)
end

local function refreshAddMaxCountLabel()
	if addMaxCountLabel then
		addMaxCountLabel.Text = tostring(addMaxCount)
	end
end

local function clampAddMaxCount()
	local liveCap = math.max(0, math.min(addMaxCapacity, InventoryState.getTotalSeedCount()))
	if liveCap < 1 then
		addMaxCount = 0
	else
		addMaxCount = math.clamp(addMaxCount, 1, liveCap)
	end
	refreshAddMaxCountLabel()
end

local function ensureAddMaxConfirmUi()
	if addMaxGui and addMaxPanel and addMaxCheck and addMaxCancel and addMaxCountLabel then
		return
	end
	local g = Instance.new("ScreenGui")
	g.Name = "OceanTD_AutoPlantAddMaxConfirm"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 12056
	g.Enabled = false
	g.Parent = playerGui
	addMaxGui = g

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
			if os.clock() - addMaxOpenedAt < 0.35 then
				return
			end
			AutoPlantUI.cancelAddMaxConfirm()
		end
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(440, 280)
	panel.BackgroundColor3 = Color3.fromRGB(18, 28, 40)
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Active = true
	panel.Parent = g
	addMaxPanel = panel
	UiPopupScale.attach(panel)
	Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 14)
	local pStroke = Instance.new("UIStroke")
	pStroke.Color = Color3.fromRGB(70, 140, 210)
	pStroke.Thickness = 2
	pStroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 16)
	title.Size = UDim2.new(1, -32, 0, 72)
	title.Font = UiTheme.Font
	title.Text = "Add max amount of random corals from your backpack to your plot"
	title.TextColor3 = WHITE
	title.TextScaled = true
	title.TextWrapped = true
	title.ZIndex = 3
	title.Parent = panel

	local stepper = Instance.new("Frame")
	stepper.Name = "Stepper"
	stepper.BackgroundTransparency = 1
	stepper.AnchorPoint = Vector2.new(0.5, 0)
	stepper.Position = UDim2.new(0.5, 0, 0, 100)
	stepper.Size = UDim2.fromOffset(220, 48)
	stepper.ZIndex = 3
	stepper.Parent = panel

	local function makeStepBtn(text: string, order: number): TextButton
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(48, 48)
		b.BackgroundColor3 = BLUE
		b.Font = UiTheme.Font
		b.Text = text
		b.TextColor3 = WHITE
		b.TextScaled = true
		b.AutoButtonColor = true
		b.ZIndex = 4
		b.LayoutOrder = order
		b.Parent = stepper
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 10)
		local edge = Instance.new("UIStroke")
		edge.Color = Color3.fromRGB(20, 70, 140)
		edge.Thickness = 2
		edge.Parent = b
		return b
	end

	local stepLayout = Instance.new("UIListLayout")
	stepLayout.FillDirection = Enum.FillDirection.Horizontal
	stepLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	stepLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	stepLayout.Padding = UDim.new(0, 12)
	stepLayout.SortOrder = Enum.SortOrder.LayoutOrder
	stepLayout.Parent = stepper

	local minus = makeStepBtn("-", 1)
	local countLbl = Instance.new("TextLabel")
	countLbl.Name = "Count"
	countLbl.Size = UDim2.fromOffset(72, 48)
	countLbl.BackgroundColor3 = Color3.fromRGB(28, 40, 58)
	countLbl.Font = UiTheme.Font
	countLbl.Text = "0"
	countLbl.TextColor3 = WHITE
	countLbl.TextScaled = true
	countLbl.ZIndex = 4
	countLbl.LayoutOrder = 2
	countLbl.Parent = stepper
	Instance.new("UICorner", countLbl).CornerRadius = UDim.new(0, 10)
	addMaxCountLabel = countLbl
	local plus = makeStepBtn("+", 3)
	minus.Activated:Connect(function()
		addMaxCount -= 1
		clampAddMaxCount()
	end)
	plus.Activated:Connect(function()
		addMaxCount += 1
		clampAddMaxCount()
	end)

	local function makeWideBtn(text: string, color: Color3, strokeColor: Color3): TextButton
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.42, 0, 0, 42)
		b.BackgroundColor3 = color
		b.Font = UiTheme.Font
		b.Text = text
		b.TextColor3 = WHITE
		b.TextScaled = true
		b.AutoButtonColor = true
		b.ZIndex = 4
		b.Parent = panel
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 10)
		local edge = Instance.new("UIStroke")
		edge.Color = strokeColor
		edge.Thickness = 2.5
		edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		edge.Parent = b
		shrinkConfirmBtnText(b)
		return b
	end

	addMaxCheck = makeWideBtn("CONFIRM", GREEN, Color3.fromRGB(12, 70, 28))
	addMaxCancel = makeWideBtn("CANCEL", RED, Color3.fromRGB(90, 12, 18))
	addMaxCheck.AnchorPoint = Vector2.new(0, 1)
	addMaxCheck.Position = UDim2.new(0, 20, 1, -18)
	addMaxCancel.AnchorPoint = Vector2.new(1, 1)
	addMaxCancel.Position = UDim2.new(1, -20, 1, -18)
	addMaxCheck.Activated:Connect(function()
		AutoPlantUI.commitAddMax()
	end)
	addMaxCancel.Activated:Connect(function()
		AutoPlantUI.cancelAddMaxConfirm()
	end)
end

function AutoPlantUI.cancelConfirm()
	if confirmGui then
		confirmGui.Enabled = false
	end
end

function AutoPlantUI.cancelAddMaxConfirm()
	if addMaxGui then
		addMaxGui.Enabled = false
	end
end

local function animateShuffleMoves(moves: any)
	if typeof(moves) ~= "table" or #moves == 0 then
		return
	end
	local folder = Workspace:FindFirstChild("OceanTD_Placed")
	if not folder then
		return
	end
	local RelocatePickHover = require(script.Parent:WaitForChild("RelocatePickHover"))
	RelocatePickHover.setPickDebugForcedHidden(true)
	shuffleAnimToken += 1
	local token = shuffleAnimToken
	shuffleAnimBusy = true
	shuffleAnimEndsAt = os.clock() + SHUFFLE_STAGGER_SPREAD + SHUFFLE_SLIDE_MAX + 0.2
	local total = #moves
	local rng = Random.new()
	local plot = ClientPlot.get()
	local plotCf = if plot then plot.cframe else nil
	local pending = 0
	local finished = 0

	local function onOneFinished()
		if token ~= shuffleAnimToken then
			return
		end
		finished += 1
		if finished >= pending then
			playShuffleCompleteSfx()
			if token == shuffleAnimToken then
				shuffleAnimBusy = false
				shuffleAnimEndsAt = 0
				RelocatePickHover.fadeInPickDebug()
				refreshShuffleVisual()
			end
		end
	end

	-- Random start order so nearby corals don't peel off in list order.
	local order: { number } = {}
	for i = 1, total do
		order[i] = i
	end
	for i = total, 2, -1 do
		local j = rng:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end

	for rank, idx in ipairs(order) do
		local mv = moves[idx]
		if typeof(mv) ~= "table" or typeof(mv.placeId) ~= "string" or typeof(mv.toWorldPos) ~= "Vector3" then
			continue
		end
		local fromPos = if typeof(mv.fromWorldPos) == "Vector3" then mv.fromWorldPos else nil
		local part: BasePart? = nil
		for _, inst in ipairs(folder:GetDescendants()) do
			if inst:IsA("BasePart") and inst:GetAttribute("OceanTD_PlaceId") == mv.placeId then
				part = inst
				break
			end
		end
		if not part then
			continue
		end

		local goal = mv.toWorldPos
		local startCf = part.CFrame
		local startAnchor = CoralVisual.readGridAnchor(part) or fromPos or part.Position
		local yawAttr = part:GetAttribute("OceanTD_FacingYaw")
		local startYaw = if typeof(yawAttr) == "number" then yawAttr else nil
		local toYaw = if typeof(mv.toFacingYaw) == "number" then mv.toFacingYaw else startYaw
		local sid = part:GetAttribute("OceanTD_SpeciesId")

		-- Compute the real planted pose (height + new yaw) without leaving it there for a frame.
		local endCf: CFrame
		local endAnchor: Vector3
		if CoralVisual.isMeshSpecies(sid) then
			CoralVisual.alignMeshToSurface(part, goal, toYaw, nil, plotCf)
			endCf = part.CFrame
			endAnchor = CoralVisual.readGridAnchor(part) or goal
			part.CFrame = startCf
			setGridAnchor(part, startAnchor)
		else
			local yawCf: CFrame
			if typeof(toYaw) == "number" then
				yawCf = CFrame.Angles(0, toYaw, 0)
				if plotCf then
					yawCf = (plotCf - plotCf.Position) * yawCf
				end
			else
				yawCf = startCf - startCf.Position
			end
			endCf = CFrame.new(goal) * yawCf
			endAnchor = goal
		end

		local startPos = startCf.Position
		local endPos = endCf.Position
		local dist = (Vector3.new(endPos.X, 0, endPos.Z) - Vector3.new(startPos.X, 0, startPos.Z)).Magnitude
		local speed = rng:NextNumber(8, 22)
		local slideSec = math.clamp(dist / speed, SHUFFLE_SLIDE_MIN, SHUFFLE_SLIDE_MAX)
		-- Rotation-only (same spot) still needs a beat to spin.
		if dist < 0.5 then
			slideSec = math.max(slideSec, 0.55)
		end
		slideSec *= rng:NextNumber(0.8, 1.25)
		local hop = if dist < 0.5 then rng:NextNumber(0.05, 0.25) else rng:NextNumber(0.15, 0.7)
		local slot = if total <= 1 then 0 else (rank - 1) / (total - 1)
		local delay = slot * SHUFFLE_STAGGER_SPREAD + rng:NextNumber(0, 0.12)

		pending += 1
		task.delay(delay, function()
			local settled = false
			local function finishOne()
				if settled then
					return
				end
				settled = true
				onOneFinished()
			end
			if token ~= shuffleAnimToken or not part or not part.Parent then
				finishOne()
				return
			end
			playSlideSfx(total)
			local t0 = os.clock()
			local conn: RBXScriptConnection
			conn = RunService.RenderStepped:Connect(function()
				if token ~= shuffleAnimToken or not part or not part.Parent then
					conn:Disconnect()
					finishOne()
					return
				end
				local u = math.clamp((os.clock() - t0) / slideSec, 0, 1)
				local e = u * u * (3 - 2 * u) -- smoothstep
				local ground = startPos:Lerp(endPos, e)
				local yLift = math.sin(e * math.pi) * hop
				local blended = startCf:Lerp(endCf, e)
				part.CFrame = CFrame.new(ground + Vector3.new(0, yLift, 0)) * (blended - blended.Position)
				-- Keep green select/move rings glued to the plant point during the slide.
				setGridAnchor(part, startAnchor:Lerp(endAnchor, e))
				if u >= 1 then
					conn:Disconnect()
					if typeof(toYaw) == "number" then
						part:SetAttribute("OceanTD_FacingYaw", toYaw)
					end
					if CoralVisual.isMeshSpecies(sid) then
						CoralVisual.alignMeshToSurface(part, goal, toYaw, nil, plotCf)
					else
						part.CFrame = endCf
						setGridAnchor(part, endAnchor)
					end
					finishOne()
				end
			end)
		end)
	end

	if pending == 0 then
		playShuffleCompleteSfx()
		if token == shuffleAnimToken then
			shuffleAnimBusy = false
			shuffleAnimEndsAt = 0
			RelocatePickHover.fadeInPickDebug()
			refreshShuffleVisual()
		end
	end
end

function AutoPlantUI.playShuffleMoves(moves: any)
	animateShuffleMoves(moves)
end

function AutoPlantUI.isShuffleAnimBusy(): boolean
	return shuffleAnimBusy == true or addMaxAnimBusy == true
end

function AutoPlantUI.getShuffleAnimEndsAt(): number
	return math.max(shuffleAnimEndsAt, addMaxAnimEndsAt)
end

function AutoPlantUI.getShuffleAnimSecondsLeft(): number
	if not shuffleAnimBusy and not addMaxAnimBusy then
		return 0
	end
	return math.max(0, math.max(shuffleAnimEndsAt, addMaxAnimEndsAt) - os.clock())
end

function AutoPlantUI.commitShuffle()
	AutoPlantUI.cancelConfirm()
	playConfirmSfx()
	shuffleClientStarted = false
	shuffleRequestBusy = true
	local RelocatePickHover = require(script.Parent:WaitForChild("RelocatePickHover"))
	RelocatePickHover.setPickDebugForcedHidden(true)
	refreshShuffleVisual()
	tickCooldown()
	-- Optimistic CD from the shared constant; ShuffleApplied confirms / sync may trim.
	applyCooldownRemaining(AutoPlantSpots.SHUFFLE_COOLDOWN_SEC)
	-- Don't block the confirm click on the round-trip; animation starts from the early FireClient.
	task.spawn(function()
		local result = Remotes.getFunction("RequestAutoPlantShuffle"):InvokeServer()
		shuffleRequestBusy = false
		if typeof(result) ~= "table" then
			if not shuffleAnimBusy then
				RelocatePickHover.fadeInPickDebug()
			end
			refreshShuffleVisual()
			return
		end
		if result.ok then
			-- cooldownSec is REMAINING time at invoke-return (not a fresh full CD).
			applyCooldownRemaining(result.cooldownSec)
			-- Fallback if the applied event was missed (rare).
			if not shuffleClientStarted and typeof(result.moves) == "table" and #result.moves > 0 then
				shuffleClientStarted = true
				animateShuffleMoves(result.moves)
			elseif not shuffleAnimBusy then
				RelocatePickHover.fadeInPickDebug()
			end
			refreshShuffleVisual()
			tickCooldown()
		else
			if not shuffleAnimBusy then
				RelocatePickHover.fadeInPickDebug()
			end
			if result.errorCode == "Cooldown" then
				applyCooldownRemaining(result.cooldownSec)
			end
			refreshShuffleVisual()
		end
	end)
end

local function openConfirm()
	if InventoryState.isPlotOpBusy() or InventoryState.isBuildModalBlocking() then
		return
	end
	if shuffleAnimBusy or shuffleRequestBusy or addMaxAnimBusy or addMaxRequestBusy then
		return
	end
	local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
	if WaveSim.isRunning and WaveSim.isRunning() then
		return
	end
	if os.clock() < cooldownEndsAt then
		return
	end
	if PlacementController.isActive and PlacementController.isActive() then
		PlacementController.cancel()
	end
	if RelocateController.isActive and RelocateController.isActive() then
		RelocateController.cancel()
	end
	AutoPlantUI.cancelAddMaxConfirm()
	ensureConfirmUi()
	confirmOpenedAt = os.clock()
	if confirmGui then
		confirmGui.Enabled = true
	end
end

local function openAddMaxConfirm()
	if InventoryState.isPlotOpBusy() or InventoryState.isBuildModalBlocking() then
		return
	end
	if shuffleAnimBusy or shuffleRequestBusy or addMaxAnimBusy or addMaxRequestBusy then
		return
	end
	local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
	if WaveSim.isRunning and WaveSim.isRunning() then
		return
	end
	if PlacementController.isActive and PlacementController.isActive() then
		PlacementController.cancel()
	end
	if RelocateController.isActive and RelocateController.isActive() then
		RelocateController.cancel()
	end
	-- Always refresh capacity from server (clear/load used to leave a stale leftover N).
	task.spawn(function()
		local ok, state = pcall(function()
			return Remotes.getFunction("RequestGetAutoPlantState"):InvokeServer()
		end)
		if ok and typeof(state) == "table" then
			applyState(state)
		end
		if not unlocked then
			refreshAddMaxVisual()
			return
		end
		local liveCap = math.min(addMaxCapacity, InventoryState.getTotalSeedCount())
		if liveCap < 1 then
			refreshAddMaxVisual()
			return
		end
		AutoPlantUI.cancelConfirm()
		ensureAddMaxConfirmUi()
		addMaxCount = liveCap
		clampAddMaxCount()
		addMaxOpenedAt = os.clock()
		if addMaxGui then
			addMaxGui.Enabled = true
		end
	end)
end

function AutoPlantUI.commitAddMax()
	AutoPlantUI.cancelAddMaxConfirm()
	if addMaxCount < 1 then
		return
	end
	playConfirmSfx()
	addMaxClientStarted = false
	addMaxRequestBusy = true
	local want = addMaxCount
	beginAddMaxCountdown(want)
	local RelocatePickHover = require(script.Parent:WaitForChild("RelocatePickHover"))
	RelocatePickHover.setPickDebugForcedHidden(true)
	refreshAddMaxVisual()
	refreshShuffleVisual()
	task.spawn(function()
		local result = Remotes.getFunction("RequestAutoPlantAddMax"):InvokeServer(want)
		addMaxRequestBusy = false
		local startedVfx = false
		if typeof(result) == "table" then
			if typeof(result.addMaxCapacity) == "number" then
				addMaxCapacity = math.max(0, math.floor(result.addMaxCapacity))
			end
			-- VFX usually starts from AutoPlantAddMaxApplied; fallback if event missed.
			if result.ok
				and not addMaxClientStarted
				and typeof(result.placements) == "table"
				and #result.placements > 0
			then
				addMaxClientStarted = true
				startedVfx = true
				AutoPlantUI.playAddMaxPlacements(result.placements)
			end
		end
		-- No VFX batch (fail / empty) — restore pick circles immediately.
		if not startedVfx and not addMaxAnimBusy then
			addMaxShowCountdown = false
			addMaxAnimEndsAt = 0
			RelocatePickHover.fadeInPickDebug()
		end
		refreshAddMaxVisual()
		refreshShuffleVisual()
	end)
end

function AutoPlantUI.mount(parent: Instance): Frame
	local wrap = Instance.new("Frame")
	wrap.Name = "AutoPlantHeader"
	wrap.BackgroundTransparency = 1
	wrap.Size = UDim2.new(1, -4, 0, 108)
	wrap.AutomaticSize = Enum.AutomaticSize.Y
	wrap.LayoutOrder = 0
	wrap.Parent = parent
	hostRow = wrap

	local col = Instance.new("UIListLayout")
	col.FillDirection = Enum.FillDirection.Vertical
	col.HorizontalAlignment = Enum.HorizontalAlignment.Center
	col.VerticalAlignment = Enum.VerticalAlignment.Top
	col.Padding = UDim.new(0, 6)
	col.SortOrder = Enum.SortOrder.LayoutOrder
	col.Parent = wrap

	-- Row 1: Auto Plant (centered, wider, same height).
	local top = Instance.new("Frame")
	top.Name = "AutoPlantTop"
	top.BackgroundTransparency = 1
	top.Size = UDim2.new(1, 0, 0, 40)
	top.LayoutOrder = 1
	top.Parent = wrap

	local shell = Instance.new("Frame")
	shell.Name = "AutoPlantToggleShell"
	shell.AnchorPoint = Vector2.new(0.5, 0.5)
	shell.Position = UDim2.fromScale(0.5, 0.5)
	shell.Size = UDim2.new(0.88, 0, 0, 40)
	shell.BorderSizePixel = 0
	shell.Parent = top
	Instance.new("UICorner", shell).CornerRadius = UDim.new(0, 10)
	local tStroke = Instance.new("UIStroke")
	tStroke.Thickness = 2.5
	tStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	tStroke.Color = WHITE
	tStroke.Parent = shell
	toggleShell = shell

	local btn = Instance.new("TextButton")
	btn.Name = "AutoPlantToggle"
	btn.Size = UDim2.fromScale(1, 1)
	btn.BackgroundTransparency = 1
	btn.Font = UiTheme.Font
	btn.Text = "AUTO PLANT OFF"
	btn.TextColor3 = WHITE
	btn.TextScaled = true
	btn.AutoButtonColor = true
	btn.Parent = shell
	toggleBtn = btn
	btn.Activated:Connect(function()
		if not unlocked then
			return
		end
		local result = Remotes.getFunction("RequestSetAutoPlant"):InvokeServer(not enabled)
		if typeof(result) == "table" and result.ok then
			enabled = result.enabled == true
			unlocked = result.unlocked ~= false
			refreshToggleVisual()
			refreshAddMaxVisual()
		end
	end)

	-- Row 2: ADD MAX + shuffle dice.
	local bottom = Instance.new("Frame")
	bottom.Name = "AutoPlantBottom"
	bottom.BackgroundTransparency = 1
	bottom.Size = UDim2.new(1, 0, 0, 44)
	bottom.LayoutOrder = 2
	bottom.Parent = wrap

	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.HorizontalAlignment = Enum.HorizontalAlignment.Center
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.Padding = UDim.new(0, 8)
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Parent = bottom

	local addShell = Instance.new("Frame")
	addShell.Name = "AddMaxShell"
	addShell.Size = UDim2.new(0.55, 0, 0, 40)
	addShell.BorderSizePixel = 0
	addShell.LayoutOrder = 1
	addShell.Parent = bottom
	Instance.new("UICorner", addShell).CornerRadius = UDim.new(0, 10)
	local aStroke = Instance.new("UIStroke")
	aStroke.Thickness = 2.5
	aStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	aStroke.Color = WHITE
	aStroke.Parent = addShell
	addMaxShell = addShell

	local addBtn = Instance.new("TextButton")
	addBtn.Name = "AddMax"
	addBtn.Size = UDim2.fromScale(1, 1)
	addBtn.BackgroundTransparency = 1
	addBtn.Font = UiTheme.Font
	addBtn.Text = "ADD MAX"
	addBtn.TextColor3 = WHITE
	addBtn.TextScaled = true
	addBtn.AutoButtonColor = true
	addBtn.Parent = addShell
	addMaxBtn = addBtn
	addBtn.Activated:Connect(function()
		openAddMaxConfirm()
	end)

	local dice = Instance.new("ImageButton")
	dice.Name = "AutoPlantShuffle"
	dice.Size = UDim2.fromOffset(40, 40)
	dice.BackgroundColor3 = GREEN
	dice.Image = ""
	dice.LayoutOrder = 2
	dice.Parent = bottom
	Instance.new("UICorner", dice).CornerRadius = UDim.new(1, 0)
	local dStroke = Instance.new("UIStroke")
	dStroke.Thickness = 2.5
	dStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	dStroke.Color = WHITE
	dStroke.Parent = dice
	local diceIcon = Instance.new("ImageLabel")
	diceIcon.Name = "DiceIcon"
	diceIcon.BackgroundTransparency = 1
	diceIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	diceIcon.Position = UDim2.fromScale(0.5, 0.5)
	diceIcon.Size = UDim2.fromScale(0.58, 0.58)
	diceIcon.Image = DICE_IMAGE
	diceIcon.ScaleType = Enum.ScaleType.Fit
	diceIcon.ZIndex = 1
	diceIcon.Parent = dice
	shuffleBtn = dice
	tickShuffleIconSwap()

	local cd = Instance.new("TextLabel")
	cd.Name = "Cooldown"
	cd.BackgroundTransparency = 1
	cd.Size = UDim2.fromScale(1, 1)
	cd.Font = UiTheme.Font
	cd.TextColor3 = WHITE
	cd.TextStrokeTransparency = 0.3
	cd.TextScaled = true
	cd.Visible = false
	cd.ZIndex = 2
	cd.Parent = dice
	cdLabel = cd

	dice.Activated:Connect(function()
		openConfirm()
	end)

	local lock = Instance.new("TextLabel")
	lock.Name = "UnlockHint"
	lock.BackgroundTransparency = 1
	lock.Size = UDim2.new(1, 0, 0, 16)
	lock.LayoutOrder = 3
	lock.Font = UiTheme.Font
	lock.TextColor3 = Color3.fromRGB(180, 190, 200)
	lock.TextScaled = true
	lock.Visible = false
	lock.Parent = wrap
	lockLabel = lock

	refreshToggleVisual()
	refreshShuffleVisual()
	refreshAddMaxVisual()
	return wrap
end

function AutoPlantUI.refreshFromServer()
	local ok, state = pcall(function()
		return Remotes.getFunction("RequestGetAutoPlantState"):InvokeServer()
	end)
	if ok and typeof(state) == "table" then
		applyState(state)
	end
end

local function screenToWorld(screen: Vector2, depth: number): Vector3?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local ray = cam:ViewportPointToRay(screen.X, screen.Y)
	return ray.Origin + ray.Direction * depth
end

local function backpackScreenCenter(): Vector2?
	local c = InventoryState.getBackpackButtonScreenCenter()
	if not c then
		return nil
	end
	local inset = game:GetService("GuiService"):GetGuiInset()
	return Vector2.new(c.X + inset.X, c.Y + inset.Y)
end

local function playOrbArrive(payload: any, opts: {
	skipAvatar: boolean?,
	token: number?,
	onDone: (() -> ())?,
	-- ADD MAX: orb flies immediately; coral is found on land (already hidden by watcher).
	deferCoralFind: boolean?,
	onReveal: ((placeId: string) -> ())?,
	flySec: number?, -- override ORB_FLY_SEC (batch speed scale)
}?)
	if typeof(payload) ~= "table" then
		if opts and opts.onDone then
			opts.onDone()
		end
		return
	end
	local worldPos = payload.worldPos
	local placeId = payload.placeId
	local colorIndex = tonumber(payload.colorIndex)
	if typeof(worldPos) ~= "Vector3" then
		if opts and opts.onDone then
			opts.onDone()
		end
		return
	end
	local PlotOutlineColors = require(oceanRoot:WaitForChild("Shared"):WaitForChild("PlotOutlineColors"))
	local hueDefaulted = PlotOutlineColors.DEBUG_HUE_DEFAULT_DOT
		and PlotOutlineColors.isMissingCoralIndex(payload.colorIndex)
	local hue = if typeof(colorIndex) == "number"
		then PlotOutlineColors.clampCoralIndex(colorIndex)
		else PlotOutlineColors.DEFAULT_INDEX
	local orbColor = PlotOutlineColors.coralColor(hue)

	local PlantWorkerVfx = require(script.Parent:WaitForChild("PlantWorkerVfx"))
	local RelocatePickHover = require(script.Parent:WaitForChild("RelocatePickHover"))

	local deferFind = opts ~= nil and opts.deferCoralFind == true
	local coral: BasePart? = nil
	if not deferFind and typeof(placeId) == "string" then
		-- Single auto-plant: wait briefly so the orb can hide the new coral.
		for _ = 1, 45 do
			coral = RelocatePickHover.findByPlaceId(placeId)
			if coral and coral.Parent then
				break
			end
			task.wait()
		end
		if coral then
			coral.LocalTransparencyModifier = 1
		end
	end

	local screen = backpackScreenCenter()
	local startPos = if screen then screenToWorld(screen, 14) else nil
	if not startPos then
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		startPos = if hrp and hrp:IsA("BasePart") then hrp.Position + Vector3.new(0, 3, 0) else worldPos + Vector3.new(0, 8, 0)
	end

	local folder = Workspace.CurrentCamera and Workspace.CurrentCamera:FindFirstChild("OceanTD_LocalFX")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "OceanTD_LocalFX"
		folder.Parent = Workspace.CurrentCamera or Workspace
	end

	local orb = Instance.new("Part")
	orb.Name = "OceanTD_AutoPlantOrb"
	orb.Shape = Enum.PartType.Ball
	orb.Anchored = true
	orb.CanCollide = false
	orb.CanQuery = false
	orb.CanTouch = false
	orb.CastShadow = false
	orb.Material = Enum.Material.Neon
	orb.Color = orbColor
	orb.Size = Vector3.new(2.4, 2.4, 2.4)
	orb.CFrame = CFrame.new(startPos)
	orb.Parent = folder

	local light = Instance.new("PointLight")
	light.Brightness = 3.5
	light.Range = 18
	light.Color = orbColor
	light.Parent = orb

	playWooshSfx()

	local skipAvatar = opts ~= nil and opts.skipAvatar == true
	local flySec = ORB_FLY_SEC
	if opts and typeof(opts.flySec) == "number" and opts.flySec > 0 then
		flySec = opts.flySec
	end
	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		if opts and opts.token and opts.token ~= addMaxAnimToken then
			conn:Disconnect()
			orb:Destroy()
			if coral and coral.Parent then
				coral.LocalTransparencyModifier = 0
			end
			-- Stale batch — do not onDone (would premature-stop orbit cam).
			return
		end
		local u = math.clamp((os.clock() - t0) / flySec, 0, 1)
		local e = 1 - (1 - u) * (1 - u)
		local mid = startPos:Lerp(worldPos, 0.5) + Vector3.new(0, 6, 0)
		-- Quadratic bezier backpack → arc → plant
		local p = startPos:Lerp(mid, e):Lerp(mid:Lerp(worldPos, e), e)
		local pulse = 2.2 + math.sin(u * math.pi * 4) * 0.35
		orb.Size = Vector3.new(pulse, pulse, pulse)
		orb.CFrame = CFrame.new(p)
		orb.Transparency = math.clamp((u - 0.85) / 0.15, 0, 1)
		if u >= 1 then
			conn:Disconnect()
			orb:Destroy()
			task.spawn(function()
				local part = coral
				if deferFind and typeof(placeId) == "string" then
					part = RelocatePickHover.findByPlaceId(placeId)
					for _ = 1, 30 do
						if opts and opts.token and opts.token ~= addMaxAnimToken then
							return
						end
						if part and part.Parent then
							break
						end
						part = RelocatePickHover.findByPlaceId(placeId)
						task.wait()
					end
				end
				if deferFind and typeof(placeId) == "string" and placeId ~= "" then
					if opts and opts.onReveal then
						opts.onReveal(placeId)
					end
					pcall(function()
						Remotes.get("AutoPlantRevealCoral"):FireServer(placeId)
					end)
				end
				if part and part.Parent then
					local function revealPart(p: BasePart)
						p.LocalTransparencyModifier = 0
					end
					local model = part:FindFirstAncestorOfClass("Model")
					local root: Instance = if model then model else part
					if root:IsA("BasePart") then
						revealPart(root)
					end
					for _, d in ipairs(root:GetDescendants()) do
						if d:IsA("BasePart") then
							revealPart(d)
						end
					end
					-- TEMP: local red dot if this orb had a missing colorIndex → teal.
					if hueDefaulted then
						pcall(function()
							local HueDefaultDebug = require(script.Parent:WaitForChild("HueDefaultDebug"))
							HueDefaultDebug.attachDot(part)
						end)
					end
				end
				PlantWorkerVfx.playAt(worldPos, {
					coralPart = part,
					skipAvatar = skipAvatar,
					onDone = if opts then opts.onDone else nil,
				})
			end)
		end
	end)
end

local function playAutoPlantArrive(payload: any)
	playOrbArrive(payload, nil)
end

function AutoPlantUI.playAddMaxPlacements(placements: any)
	if typeof(placements) ~= "table" or #placements == 0 then
		return
	end
	-- Re-entrant start (event + Invoke race) would cancel the orbit mid-shot.
	if addMaxAnimBusy then
		return
	end
	local PlantWorkerVfx = require(script.Parent:WaitForChild("PlantWorkerVfx"))
	-- Cancel prior batch budgets if a new ADD MAX starts.
	pcall(function()
		PlantWorkerVfx.endBatchVfx()
	end)
	addMaxAnimToken += 1
	local token = addMaxAnimToken
	local total = #placements
	addMaxAnimBusy = true
	-- Refresh ETA from actual placement count (server may place fewer than requested).
	if total > 5 then
		addMaxShowCountdown = true
		addMaxAnimEndsAt = os.clock() + estimateAddMaxSec(total)
		tickAddMaxCountdown()
	else
		addMaxShowCountdown = false
		addMaxAnimEndsAt = os.clock() + estimateAddMaxSec(total)
	end
	refreshAddMaxVisual()
	refreshShuffleVisual()

	local speedScale = addMaxDurationScale(total)
	PlantWorkerVfx.beginBatchVfx({
		-- Over 40: hard 3 bubbles + 5 hearts per coral (no periodic bubble spam).
		bubblesPerCoral = if total > 40 then 3 else nil,
		heartsPerCoral = if total > 40 then 5 else nil,
		wowCap = 40,
		-- Dust on a random subset of digs (not every coral).
		dustChance = if total > 100 then 0.1 elseif total > 40 then 0.5 else 1,
		-- Big batches: dig/run loops at half volume.
		workVolScale = if total > 100 then 0.5 else 1,
		-- Shorten plant-only dig so the whole batch finishes sooner.
		workSecScale = speedScale,
	})
	-- >100: drone half-moon orbit (left → right) across plot center for the batch.
	if total > 100 then
		local AddMaxOrbitCam = require(script.Parent:WaitForChild("AddMaxOrbitCam"))
		-- Span the arch across almost the whole batch (leave room for in/out tweens).
		local totalSec = estimateAddMaxSec(total)
		local orbitSec = math.max(4, totalSec - 1.35 - 1.35)
		AddMaxOrbitCam.begin(orbitSec)
	end
	local RelocatePickHover = require(script.Parent:WaitForChild("RelocatePickHover"))
	RelocatePickHover.setPickDebugForcedHidden(true)

	local hideIds: { [string]: boolean } = {}
	local revealedIds: { [string]: boolean } = {}
	for _, pl in ipairs(placements) do
		if typeof(pl) == "table" and typeof(pl.placeId) == "string" then
			hideIds[pl.placeId] = true
		end
	end

	local function hideCoralTree(anchor: BasePart)
		local model = anchor:FindFirstAncestorOfClass("Model")
		local root: Instance = if model then model else anchor
		local function hidePart(p: BasePart)
			p.LocalTransparencyModifier = 1
		end
		if root:IsA("BasePart") then
			hidePart(root)
		end
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BasePart") then
				hidePart(d)
			end
		end
	end

	-- Keep corals invisible until that placeId's orb lands (entire batch, not a short sweep).
	local folder = Workspace:FindFirstChild("OceanTD_Placed")
	local hideConns: { RBXScriptConnection } = {}
	local function tryHide(inst: Instance)
		if not inst:IsA("BasePart") then
			return
		end
		local pid = inst:GetAttribute("OceanTD_PlaceId")
		if typeof(pid) ~= "string" or not hideIds[pid] or revealedIds[pid] then
			return
		end
		hideCoralTree(inst)
	end
	if folder then
		for _, d in ipairs(folder:GetDescendants()) do
			tryHide(d)
		end
		table.insert(hideConns, folder.DescendantAdded:Connect(function(inst)
			tryHide(inst)
			if inst:IsA("BasePart") then
				local pid = inst:GetAttribute("OceanTD_PlaceId")
				if typeof(pid) ~= "string" or not hideIds[pid] then
					local attrConn: RBXScriptConnection
					attrConn = inst:GetAttributeChangedSignal("OceanTD_PlaceId"):Connect(function()
						tryHide(inst)
						local nextPid = inst:GetAttribute("OceanTD_PlaceId")
						if typeof(nextPid) == "string" and hideIds[nextPid] then
							attrConn:Disconnect()
						end
					end)
					table.insert(hideConns, attrConn)
				end
			end
		end))
		table.insert(hideConns, RunService.Heartbeat:Connect(function()
			if token ~= addMaxAnimToken or not folder.Parent then
				return
			end
			for _, d in ipairs(folder:GetChildren()) do
				if d:IsA("BasePart") then
					tryHide(d)
				elseif d:IsA("Model") then
					local pid = d:GetAttribute("OceanTD_PlaceId")
					if typeof(pid) ~= "string" then
						for _, ch in ipairs(d:GetDescendants()) do
							if ch:IsA("BasePart") and typeof(ch:GetAttribute("OceanTD_PlaceId")) == "string" then
								tryHide(ch)
								break
							end
						end
					end
				end
			end
		end))
	end

	local pending = total
	local finished = 0
	local function onOneDone()
		if token ~= addMaxAnimToken then
			return
		end
		finished += 1
		if finished >= pending then
			for _, c in ipairs(hideConns) do
				c:Disconnect()
			end
			table.clear(hideConns)
			pcall(function()
				PlantWorkerVfx.endBatchVfx()
			end)
			pcall(function()
				local AddMaxOrbitCam = require(script.Parent:WaitForChild("AddMaxOrbitCam"))
				AddMaxOrbitCam.stop()
			end)
			playShuffleCompleteSfx()
			if token == addMaxAnimToken then
				addMaxAnimBusy = false
				addMaxAnimEndsAt = 0
				addMaxShowCountdown = false
				RelocatePickHover.fadeInPickDebug()
				-- Pull live leftover capacity (should be 0 when plot/seeds are full).
				task.defer(function()
					AutoPlantUI.refreshFromServer()
				end)
				refreshAddMaxVisual()
				refreshShuffleVisual()
			end
		end
	end

	local orbStagger = ADD_MAX_ORB_STAGGER * speedScale
	local orbFlySec = ORB_FLY_SEC * speedScale
	for i, pl in ipairs(placements) do
		local delaySec = (i - 1) * orbStagger
		task.delay(delaySec, function()
			-- Stale batch (re-entrant playAddMax) — do NOT count toward onOneDone
			-- or the orbit cam gets stop()'d while the new batch is still planting.
			if token ~= addMaxAnimToken then
				return
			end
			task.spawn(function()
				playOrbArrive(pl, {
					skipAvatar = true,
					token = token,
					onDone = onOneDone,
					deferCoralFind = true,
					flySec = orbFlySec,
					onReveal = function(pid: string)
						revealedIds[pid] = true
					end,
				})
			end)
		end)
	end
end

function AutoPlantUI.bind()
	Remotes.get("AutoPlantSync").OnClientEvent:Connect(function(payload)
		applyState(payload)
	end)
	Remotes.get("AutoPlantShuffleApplied").OnClientEvent:Connect(function(payload)
		if typeof(payload) == "table" then
			-- Shuffle sets cooldown; undo-shuffle omits it.
			if typeof(payload.cooldownSec) == "number" and payload.cooldownSec > 0 then
				applyCooldownRemaining(payload.cooldownSec)
			end
			if typeof(payload.moves) == "table" and #payload.moves > 0 then
				shuffleClientStarted = true
				animateShuffleMoves(payload.moves)
				tickCooldown() -- keep button grey while slides finish even if CD elapsed
			end
		end
	end)
	Remotes.get("AutoPlantAddMaxApplied").OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" or typeof(payload.placements) ~= "table" or #payload.placements == 0 then
			return
		end
		-- InvokeServer fallback may have won the race — don't restart VFX/orbit.
		if addMaxClientStarted or addMaxAnimBusy then
			return
		end
		addMaxClientStarted = true
		AutoPlantUI.playAddMaxPlacements(payload.placements)
	end)
	Remotes.get("AutoPlantPlaced").OnClientEvent:Connect(function(payload)
		task.spawn(playAutoPlantArrive, payload)
	end)
	InventoryState.onCountsChanged(function()
		refreshAddMaxVisual()
	end)
	task.defer(function()
		AutoPlantUI.refreshFromServer()
	end)
end

return AutoPlantUI
