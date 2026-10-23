--!strict
--[[
	Closed-backpack Auto Plant ON/OFF circle — left of BUILD (Slot3 spot/size).
	Idle flash: "AUTO / PLANT" ↔ ON or OFF (green/red). Hidden when backpack open.
	Training: playTutorialIntro — large center → tween/scale into dock.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiPopupScale = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPopupScale"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiIdleCycle = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiIdleCycle"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local AutoPlantUI = require(script.Parent:WaitForChild("AutoPlantUI"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local AutoPlantHudSlot = {}

local GREEN = Color3.fromRGB(40, 170, 70)
local GREEN_DARK = Color3.fromRGB(18, 90, 36)
local RED = Color3.fromRGB(220, 55, 65)
local RED_DARK = Color3.fromRGB(100, 20, 28)
local GREY = Color3.fromRGB(70, 78, 90)
local WHITE = Color3.new(1, 1, 1)
local IDLE_PERIOD = 2
local INTRO_SCALE = 2.75
local INTRO_SEC = 0.72
-- Tutorial lock: same floating icon as Skip / left HUD, but no red overlay.
local TUTORIAL_LOCK_IMAGE = "rbxassetid://105420423737825"
local TUTORIAL_LOCK_SIZE_PX = 17
local TUTORIAL_LOCK_ORBIT_SPEED = 1.35 -- rad/sec
local TUTORIAL_LOCK_ORBIT_FRAC = 0.42
local TUTORIAL_LOCK_BIG_SEC = 2.0 -- hold at 2× while floating
local TUTORIAL_LOCK_NORMAL_SEC = 2.0 -- then hold at 1×
local TUTORIAL_LOCK_FADE_SEC = 0.45
local TUTORIAL_LOCK_SCALE_DOWN_SEC = 0.35

export type Deps = {
	mainHUD: ScreenGui,
	playerGui: PlayerGui,
	ensureButton: (GuiObject) -> GuiButton,
	passthroughDecor: (GuiObject, GuiButton) -> (),
	ensureCircle: (GuiObject) -> GuiObject,
	ensureStroke: (GuiObject, string, Color3, number) -> UIStroke,
	log: (...any) -> (),
}

local deps: Deps
local host: GuiObject? = nil
local hostButton: GuiButton? = nil
local circle: GuiObject? = nil
local stroke: UIStroke? = nil
local label: TextLabel? = nil
local idleStop: UiIdleCycle.StopFn? = nil
local flashToken = 0
local forcedHidden = false
local introBusy = false
local dockSlot3: GuiObject? = nil
local dockSlot4: GuiObject? = nil
local quickbarRef: Instance? = nil
local REPORT_OPEN_ATTR = "OceanTD_ReefReportOpen"
local tutorialLockIcon: ImageLabel? = nil
local tutorialLockOrbitConn: RBXScriptConnection? = nil
local tutorialLockOrbitAngle = 0
local tutorialLockFeedbackToken = 0
local tutorialLockFeedbackActive = false
local refreshXGlyph: () -> ()

local function applyFillGradient(btn: GuiObject, top: Color3, bottom: Color3)
	local land = btn:FindFirstChild("_OceanTD_LandRadial")
	if land then
		land:Destroy()
	end
	local g = btn:FindFirstChildOfClass("UIGradient")
	if not g then
		g = Instance.new("UIGradient")
		g.Parent = btn
	end
	g.Rotation = 90
	g.Offset = Vector2.zero
	g.Transparency = NumberSequence.new(0)
	-- Reset to linear if Radial was used for land flash.
	local gt = (Enum :: any).GradientType
	if gt and gt.Linear then
		pcall(function()
			(g :: any).Type = gt.Linear
		end)
	end
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, top),
		ColorSequenceKeypoint.new(1, bottom),
	})
end

local function applyBrightGreenRadialFill(btn: GuiObject)
	local g = btn:FindFirstChild("_OceanTD_LandRadial") :: UIGradient?
	if not g then
		local old = btn:FindFirstChildOfClass("UIGradient")
		if old then
			old:Destroy()
		end
		g = Instance.new("UIGradient")
		g.Name = "_OceanTD_LandRadial"
		g.Parent = btn
	end
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(190, 255, 210)),
		ColorSequenceKeypoint.new(0.45, Color3.fromRGB(90, 255, 130)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(28, 140, 60)),
	})
	g.Transparency = NumberSequence.new(0)
	g.Offset = Vector2.zero
	g.Rotation = 0
	local gt = (Enum :: any).GradientType
	if gt and gt.Radial then
		pcall(function()
			(g :: any).Type = gt.Radial
		end)
	else
		g.Rotation = 90
		g.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(28, 140, 60)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(190, 255, 210)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(28, 140, 60)),
		})
	end
end

local function applyStrokeGradient(s: UIStroke, top: Color3, bottom: Color3)
	s.Color = WHITE
	local g = s:FindFirstChildOfClass("UIGradient")
	if not g then
		g = Instance.new("UIGradient")
		g.Parent = s
	end
	g.Rotation = 90
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, top),
		ColorSequenceKeypoint.new(1, bottom),
	})
end

-- autoPlant chapter: locked ON. manualPlant chapter: locked OFF until backpack closes after plant/upgrade/hue.
local function tutorialLockMode(): ("on" | "off" | nil)
	local pg = deps and deps.playerGui
	if not pg then
		return nil
	end
	local chapter = pg:GetAttribute("OceanTD_TutorialChapter")
	if chapter == "autoPlant" then
		return "on"
	end
	if chapter == "manualPlant" then
		local hint = pg:GetAttribute("OceanTD_RollFingerHint")
		-- Unlocked once Manual Plant pipeline hands off to cam (or tutorial cleared).
		if hint == "cam" or hint == "waves" or hint == "skills" or hint == false or hint == nil then
			return nil
		end
		return "off"
	end
	return nil
end

local function tutorialLocksAutoPlant(): boolean
	return tutorialLockMode() ~= nil
end

local function usingGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function ensureXGlyph(parent: GuiObject)
	local existing = parent:FindFirstChild("_OceanTD_AutoPlantX")
	if existing and existing:IsA("TextLabel") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local tip = Instance.new("TextLabel")
	tip.Name = "_OceanTD_AutoPlantX"
	tip.AnchorPoint = Vector2.new(1, 1)
	tip.Position = UDim2.new(1, 8, 1, 8)
	tip.Size = UDim2.fromScale(0.42, 0.42)
	tip.BackgroundColor3 = Color3.fromRGB(40, 130, 220)
	tip.BorderSizePixel = 0
	tip.Font = Enum.Font.GothamBold
	tip.Text = "L1"
	tip.TextColor3 = Color3.new(1, 1, 1)
	tip.TextScaled = true
	tip.ZIndex = parent.ZIndex + 8
	tip.Active = false
	tip.Visible = false
	tip.Parent = parent
	parent.ClipsDescendants = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = tip
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.12, 0)
	pad.PaddingBottom = UDim.new(0.12, 0)
	pad.PaddingLeft = UDim.new(0.12, 0)
	pad.PaddingRight = UDim.new(0.12, 0)
	pad.Parent = tip
	return tip
end

local function shouldShow(): boolean
	if forcedHidden then
		return false
	end
	if InventoryState.isOpen() then
		return false
	end
	-- Visible during waves so players can toggle Auto Plant on/off.
	local pg = deps and deps.playerGui
	if not pg then
		return false
	end
	if pg:GetAttribute("OceanTD_SkillsBubblesOpen") == true then
		return false
	end
	if pg:GetAttribute(REPORT_OPEN_ATTR) == true then
		return false
	end
	if pg:GetAttribute("OceanTD_StoreOpen") == true then
		return false
	end
	return true
end

local function stopTutorialLockOrbit()
	if tutorialLockOrbitConn then
		tutorialLockOrbitConn:Disconnect()
		tutorialLockOrbitConn = nil
	end
end

local function startTutorialLockOrbit(lockHost: GuiObject)
	if tutorialLockOrbitConn then
		return
	end
	tutorialLockOrbitConn = RunService.Heartbeat:Connect(function(dt)
		local icon = tutorialLockIcon
		if not icon or not icon.Parent or not icon.Visible then
			return
		end
		local lockPx = TUTORIAL_LOCK_SIZE_PX
		local hud = UiPopupScale.getHud()
		if hud > 1.01 then
			lockPx = math.max(TUTORIAL_LOCK_SIZE_PX, math.floor(TUTORIAL_LOCK_SIZE_PX * hud + 0.5))
		end
		if icon.Size.X.Offset ~= lockPx then
			icon.Size = UDim2.fromOffset(lockPx, lockPx)
		end
		tutorialLockOrbitAngle += TUTORIAL_LOCK_ORBIT_SPEED * dt
		local abs = lockHost.AbsoluteSize
		local radius = math.max(10, math.min(abs.X, abs.Y) * 0.5 * TUTORIAL_LOCK_ORBIT_FRAC)
		local ox = math.cos(tutorialLockOrbitAngle) * radius
		local oy = math.sin(tutorialLockOrbitAngle) * radius
		icon.Position = UDim2.new(0.5, ox, 0.5, oy)
	end)
end

local function ensureTutorialLockIcon(lockHost: GuiObject): ImageLabel
	local icon = tutorialLockIcon
	if not icon or not icon.Parent then
		icon = Instance.new("ImageLabel")
		icon.Name = "OceanTD_AutoPlantTutorialLock"
		icon.BackgroundTransparency = 1
		icon.Image = TUTORIAL_LOCK_IMAGE
		icon.ImageColor3 = WHITE
		icon.ImageTransparency = 1
		local lockPx = TUTORIAL_LOCK_SIZE_PX
		local hud = UiPopupScale.getHud()
		if hud > 1.01 then
			lockPx = math.max(TUTORIAL_LOCK_SIZE_PX, math.floor(TUTORIAL_LOCK_SIZE_PX * hud + 0.5))
		end
		icon.Size = UDim2.fromOffset(lockPx, lockPx)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Active = false
		icon.Visible = false
		icon.ZIndex = lockHost.ZIndex + 22
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Parent = lockHost
		local sc = Instance.new("UIScale")
		sc.Name = "_OceanTD_TutorialLockScale"
		sc.Scale = 1
		sc.Parent = icon
		tutorialLockIcon = icon
		tutorialLockOrbitAngle = Random.new():NextNumber(0, math.pi * 2)
	else
		icon.ZIndex = lockHost.ZIndex + 22
		if not icon:FindFirstChild("_OceanTD_TutorialLockScale") then
			local sc = Instance.new("UIScale")
			sc.Name = "_OceanTD_TutorialLockScale"
			sc.Scale = 1
			sc.Parent = icon
		end
	end
	return icon
end

local function hideTutorialLockIcon()
	stopTutorialLockOrbit()
	tutorialLockFeedbackActive = false
	local icon = tutorialLockIcon
	if not icon then
		return
	end
	icon.Visible = false
	icon.ImageTransparency = 1
	local sc = icon:FindFirstChild("_OceanTD_TutorialLockScale")
	if sc and sc:IsA("UIScale") then
		sc.Scale = 1
	end
end

-- Tap while locked: float lock at 2× (2s) → 1× (2s) → fade out until next tap.
local function playTutorialLockReject()
	local lockHost: GuiObject? = if circle and circle:IsA("GuiObject") then circle else host
	if not lockHost or not tutorialLocksAutoPlant() then
		return
	end
	tutorialLockFeedbackToken += 1
	local my = tutorialLockFeedbackToken
	tutorialLockFeedbackActive = true
	local icon = ensureTutorialLockIcon(lockHost)
	local scale = icon:FindFirstChild("_OceanTD_TutorialLockScale") :: UIScale?
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "_OceanTD_TutorialLockScale"
		scale.Parent = icon
	end
	icon.Visible = true
	icon.ImageTransparency = 0
	icon.ImageColor3 = WHITE
	scale.Scale = 2
	startTutorialLockOrbit(lockHost)
	task.spawn(function()
		local holdBigUntil = os.clock() + TUTORIAL_LOCK_BIG_SEC
		while os.clock() < holdBigUntil and my == tutorialLockFeedbackToken do
			task.wait()
		end
		if my ~= tutorialLockFeedbackToken or not icon.Parent then
			return
		end
		local down = TweenService:Create(
			scale,
			TweenInfo.new(TUTORIAL_LOCK_SCALE_DOWN_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = 1 }
		)
		down:Play()
		local holdNormalUntil = os.clock() + TUTORIAL_LOCK_NORMAL_SEC
		while os.clock() < holdNormalUntil and my == tutorialLockFeedbackToken do
			task.wait()
		end
		if my ~= tutorialLockFeedbackToken or not icon.Parent then
			return
		end
		local fade = TweenService:Create(
			icon,
			TweenInfo.new(TUTORIAL_LOCK_FADE_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ ImageTransparency = 1 }
		)
		fade:Play()
		fade.Completed:Wait()
		if my == tutorialLockFeedbackToken then
			hideTutorialLockIcon()
		end
	end)
end

local function syncTutorialLock()
	-- Lock icon is tap-to-reveal only (not always floating during training).
	if tutorialLockFeedbackActive then
		return
	end
	if not tutorialLocksAutoPlant() then
		tutorialLockFeedbackToken += 1
		hideTutorialLockIcon()
	elseif tutorialLockIcon and tutorialLockIcon.Visible and tutorialLockIcon.ImageTransparency >= 0.99 then
		hideTutorialLockIcon()
	end
end

local function stopIdle()
	if idleStop then
		idleStop()
		idleStop = nil
	end
end

local function paintChrome()
	if not circle or not stroke then
		return
	end
	local unlocked = AutoPlantUI.isUnlocked()
	local enabled = AutoPlantUI.isEnabled()
	if circle:IsA("ImageLabel") or circle:IsA("ImageButton") then
		(circle :: any).Image = ""
	end
	circle.BackgroundTransparency = 0
	stroke.Enabled = true
	stroke.Thickness = 3
	if not unlocked then
		circle.BackgroundColor3 = GREY
		applyFillGradient(circle, Color3.fromRGB(90, 96, 108), GREY)
		applyStrokeGradient(stroke, Color3.fromRGB(200, 205, 215), Color3.fromRGB(140, 145, 155))
		return
	end
	if enabled then
		circle.BackgroundColor3 = GREEN
		applyFillGradient(circle, Color3.fromRGB(90, 230, 120), GREEN_DARK)
		applyStrokeGradient(stroke, Color3.fromRGB(120, 255, 150), Color3.fromRGB(40, 220, 90))
	else
		circle.BackgroundColor3 = RED
		applyFillGradient(circle, Color3.fromRGB(255, 110, 120), RED_DARK)
		applyStrokeGradient(stroke, Color3.fromRGB(255, 120, 130), Color3.fromRGB(255, 50, 70))
	end
end

local function setOnTextScale(isOn: boolean)
	if not label then
		return
	end
	local sc = label:FindFirstChild("_OceanTD_OnScale")
	if isOn then
		-- UIScale uses AnchorPoint — center so "ON" doesn't sit top-left.
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextYAlignment = Enum.TextYAlignment.Center
		if not sc then
			sc = Instance.new("UIScale")
			sc.Name = "_OceanTD_OnScale"
			sc.Parent = label
		end
		(sc :: UIScale).Scale = 0.82 -- one step smaller than AUTO PLANT / OFF
	else
		if sc then
			sc:Destroy()
		end
		label.AnchorPoint = Vector2.new(0, 0)
		label.Position = UDim2.fromScale(0, 0)
	end
end

-- alt=true → ON/OFF (or locked hint); alt=false → AUTO / PLANT
local function applyIdleFrame(showStatus: boolean)
	if not label then
		return
	end
	paintChrome()
	label.TextColor3 = WHITE
	label.Visible = true
	if showStatus then
		if not AutoPlantUI.isUnlocked() then
			label.Text = "AUTO\nPLANT"
			setOnTextScale(false)
		elseif AutoPlantUI.isEnabled() then
			label.Text = "ON"
			setOnTextScale(true)
		else
			label.Text = "OFF"
			setOnTextScale(false)
		end
	else
		label.Text = "AUTO\nPLANT"
		setOnTextScale(false)
	end
end

local function startIdle()
	stopIdle()
	if not shouldShow() then
		return
	end
	-- Invert so this flips opposite BUILD's text frame (side-by-side variety).
	idleStop = UiIdleCycle.subscribeSharedToggle(IDLE_PERIOD, applyIdleFrame, shouldShow, true)
end

local function restoreDockLayout()
	local h = host
	local s3 = dockSlot3
	local s4 = dockSlot4
	local qb = quickbarRef
	if not h or not s3 or not s4 or not qb then
		return
	end
	-- Never leave the live button under an intro overlay — that destroyed layout before.
	if h.Parent ~= qb then
		h.Parent = qb
	end
	h.AnchorPoint = s3.AnchorPoint
	h.Position = s3.Position
	h.Size = s4.Size
	h.ZIndex = s3.ZIndex
	local sc = h:FindFirstChild("_OceanTD_TutorialIntroScale")
	if sc then
		sc:Destroy()
	end
end

local function ensureHostInQuickbar(): boolean
	local s3 = dockSlot3
	local s4 = dockSlot4
	local qb = quickbarRef
	local d = deps
	if not s3 or not s4 or not qb or not d then
		return false
	end
	if host and host.Parent == qb then
		restoreDockLayout()
		return true
	end
	-- Recreate if a prior intro Destroy()'d the docked button with its overlay.
	local existing = qb:FindFirstChild("AutoPlantHudSlot")
	if existing and existing:IsA("GuiObject") then
		host = existing
	else
		local frame = Instance.new("Frame")
		frame.Name = "AutoPlantHudSlot"
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Parent = qb
		host = frame
		hostButton = d.ensureButton(host)
		d.passthroughDecor(host, hostButton)
		circle = d.ensureCircle(host)
		UiCircles.forceOnDescendants(host)
		stroke = d.ensureStroke(circle, "_OceanTD_AutoPlantHudRing", WHITE, 3)
		stroke.Enabled = true
		local lbl = Instance.new("TextLabel")
		lbl.Name = "_OceanTD_AutoPlantHudLabel"
		lbl.BackgroundTransparency = 1
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.Font = UiTheme.Font
		lbl.Text = "AUTO\nPLANT"
		lbl.TextColor3 = WHITE
		lbl.TextScaled = true
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.TextYAlignment = Enum.TextYAlignment.Center
		lbl.ZIndex = circle.ZIndex + 2
		lbl.Active = false
		lbl.Parent = circle
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.14, 0)
		pad.PaddingBottom = UDim.new(0.14, 0)
		pad.PaddingLeft = UDim.new(0.08, 0)
		pad.PaddingRight = UDim.new(0.08, 0)
		pad.Parent = lbl
		label = lbl
		if circle then
			ensureXGlyph(circle)
		end
		if hostButton:GetAttribute("_OceanTD_AutoPlantHudBound") ~= true then
			hostButton:SetAttribute("_OceanTD_AutoPlantHudBound", true)
			local function press()
				onPress()
			end
			hostButton.MouseButton1Down:Connect(press)
			hostButton.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.Touch then
					press()
				end
			end)
		end
	end
	restoreDockLayout()
	return host ~= nil and host.Parent == qb
end

function AutoPlantHudSlot.syncVisibility()
	if introBusy then
		return
	end
	if not host or not host.Parent then
		ensureHostInQuickbar()
	end
	if not host then
		return
	end
	local show = shouldShow()
	host.Visible = show
	if show then
		startIdle()
	else
		stopIdle()
	end
	syncTutorialLock()
	refreshXGlyph()
end

function AutoPlantHudSlot.setVisible(on: boolean)
	if not host then
		return
	end
	if on then
		AutoPlantHudSlot.syncVisibility()
	else
		stopIdle()
		tutorialLockFeedbackToken += 1
		hideTutorialLockIcon()
		host.Visible = false
	end
end

function AutoPlantHudSlot.setForcedHidden(on: boolean)
	forcedHidden = on == true
	if forcedHidden then
		stopIdle()
		tutorialLockFeedbackToken += 1
		hideTutorialLockIcon()
		if host and not introBusy then
			host.Visible = false
		end
	else
		AutoPlantHudSlot.syncVisibility()
	end
end

--[[
	Training Auto Plant chapter: clone pops large at screen center (ON), then
	tweens/scales into the Slot3 dock. The live quickbar button never leaves
	its parent (reparent+Destroy was blowing away layout / wheels).
]]
function AutoPlantHudSlot.playTutorialIntro(durationSec: number?): boolean
	local s3 = dockSlot3
	local s4 = dockSlot4
	local d = deps
	if not s3 or not s4 or not d then
		return false
	end
	if introBusy then
		return false
	end
	if not ensureHostInQuickbar() then
		return false
	end
	local h = host
	if not h then
		return false
	end

	introBusy = true
	forcedHidden = false
	stopIdle()

	-- Measure dock from Slot3/4 (live button stays hidden so it doesn't shove the bar).
	h.Visible = false
	restoreDockLayout()
	for _ = 1, 4 do
		if s3.AbsoluteSize.X >= 2 and s4.AbsoluteSize.X >= 2 then
			break
		end
		task.wait()
	end
	local dockPos = s3.AbsolutePosition
	local dockSize = s4.AbsoluteSize
	local dockCenter = Vector2.new(dockPos.X + dockSize.X * 0.5, dockPos.Y + dockSize.Y * 0.5)
	local dockW = math.max(48, dockSize.X)
	local dockH = math.max(48, dockSize.Y)

	paintChrome()
	applyIdleFrame(true)

	local overlay = d.playerGui:FindFirstChild("OceanTD_AutoPlantTutorialIntro")
	if overlay then
		overlay:Destroy()
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_AutoPlantTutorialIntro"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 12500
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = d.playerGui

	-- Animate a clone only — never reparent the docked host.
	local clone = h:Clone()
	clone.Name = "AutoPlantHudIntroClone"
	clone.AnchorPoint = Vector2.new(0.5, 0.5)
	clone.Size = UDim2.fromOffset(dockW, dockH)
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	clone.Position = UDim2.fromOffset(vp.X * 0.5, vp.Y * 0.5)
	clone.Visible = true
	clone.ZIndex = 10
	clone.Active = false
	clone.Parent = sg
	local clonedTip = clone:FindFirstChild("_OceanTD_AutoPlantX", true)
	if clonedTip and clonedTip:IsA("GuiObject") then
		clonedTip.Visible = false
	end
	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("GuiButton") then
			desc.Active = false
			desc.AutoButtonColor = false
		end
	end

	local uiScale = Instance.new("UIScale")
	uiScale.Name = "_OceanTD_TutorialIntroScale"
	uiScale.Scale = INTRO_SCALE
	uiScale.Parent = clone

	local sec = if typeof(durationSec) == "number" and durationSec > 0.2 then durationSec else INTRO_SEC
	local info = TweenInfo.new(sec, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local twPos = TweenService:Create(clone, info, {
		Position = UDim2.fromOffset(dockCenter.X, dockCenter.Y),
	})
	local twScale = TweenService:Create(uiScale, info, { Scale = 1 })
	twPos:Play()
	twScale:Play()
	twPos.Completed:Wait()

	sg:Destroy()
	restoreDockLayout()
	introBusy = false
	AutoPlantHudSlot.syncVisibility()
	return true
end

-- Screen center of the HUD circle (IgnoreGuiInset = false AbsolutePosition space).
function AutoPlantHudSlot.getScreenCenter(): Vector2?
	local h = host
	if not h or not h.Parent then
		return nil
	end
	local pos = h.AbsolutePosition
	local size = h.AbsoluteSize
	if size.X < 1 or size.Y < 1 then
		return nil
	end
	return Vector2.new(pos.X + size.X * 0.5, pos.Y + size.Y * 0.5)
end

-- Brief bright-green pop when a seed orb / slide lands on this button.
function AutoPlantHudSlot.flashArrive()
	if not circle or not host or not host.Visible then
		return
	end
	flashToken += 1
	local token = flashToken
	stopIdle()
	if circle:IsA("ImageLabel") or circle:IsA("ImageButton") then
		(circle :: any).Image = ""
	end
	circle.BackgroundTransparency = 0
	circle.BackgroundColor3 = Color3.fromRGB(90, 255, 120)
	applyBrightGreenRadialFill(circle)
	if label then
		local isOn = AutoPlantUI.isEnabled()
		label.Text = if isOn then "ON" else "OFF"
		label.Visible = true
		setOnTextScale(isOn)
	end
	task.delay(0.55, function()
		if token ~= flashToken then
			return
		end
		if host and host.Visible then
			startIdle()
		end
	end)
end

local function onPress()
	if not shouldShow() then
		return
	end
	if not AutoPlantUI.isUnlocked() then
		return
	end
	-- Training chapters: keep Auto Plant locked — show floating lock on tap only.
	if tutorialLocksAutoPlant() then
		playTutorialLockReject()
		return
	end
	AutoPlantUI.requestToggle()
end

local function layoutAutoPlantTip(tip: TextLabel, parent: GuiObject)
	tip.Text = "L1"
	tip.AnchorPoint = Vector2.new(1, 1)
	parent.ClipsDescendants = false
	local slot = dockSlot4
	local hud = deps and deps.mainHUD
	local helpRoot = hud and hud:FindFirstChild("QuickbarHelp")
	local help = helpRoot and helpRoot:FindFirstChild("Slot4")
	if slot and slot:IsA("GuiObject") and help and help:IsA("GuiObject")
		and slot.AbsoluteSize.X >= 2 and help.AbsoluteSize.X >= 2 and parent.AbsoluteSize.X >= 2
	then
		local slotCorner = slot.AbsolutePosition + slot.AbsoluteSize
		local helpCorner = help.AbsolutePosition + help.AbsoluteSize
		local delta = helpCorner - slotCorner
		tip.Size = UDim2.fromOffset(help.AbsoluteSize.X, help.AbsoluteSize.Y)
		tip.Position = UDim2.new(1, math.floor(delta.X + 0.5), 1, math.floor(delta.Y + 0.5))
		return
	end
	tip.Size = UDim2.fromScale(0.42, 0.42)
	tip.Position = UDim2.new(1, 8, 1, 8)
end

local function autoPlantXReady(): boolean
	-- L1 is wave speed during a wave, and Collect while a coral tool is up.
	if WaveSim.isRunning() or InventoryState.isOpen() or not shouldShow() then
		return false
	end
	local relocate = require(script.Parent:WaitForChild("RelocateController"))
	local placement = require(script.Parent:WaitForChild("PlacementController"))
	if relocate.isActive() or placement.isActive() then
		return false
	end
	return true
end

refreshXGlyph = function()
	local parent = host or circle
	if not parent then
		return
	end
	if circle and circle ~= parent then
		local stale = circle:FindFirstChild("_OceanTD_AutoPlantX")
		if stale then
			stale:Destroy()
		end
	end
	local tip = ensureXGlyph(parent)
	layoutAutoPlantTip(tip, parent)
	tip.Visible = usingGamepad() and autoPlantXReady()
end

function AutoPlantHudSlot.tryGamepadToggle(): boolean
	if not autoPlantXReady() then
		return false
	end
	onPress()
	return true
end

function AutoPlantHudSlot.mount(d: Deps)
	deps = d
	local quickbar = d.mainHUD:FindFirstChild("Quickbar")
	if not quickbar then
		warn("[AutoPlantHud] Quickbar missing")
		return
	end
	local slot3 = quickbar:FindFirstChild("Slot3")
	local slot4 = quickbar:FindFirstChild("Slot4")
	if not slot3 or not slot3:IsA("GuiObject") then
		warn("[AutoPlantHud] Slot3 missing — cannot place Auto Plant HUD button")
		return
	end
	if not slot4 or not slot4:IsA("GuiObject") then
		warn("[AutoPlantHud] Slot4 missing — cannot size Auto Plant HUD button")
		return
	end

	local existing = quickbar:FindFirstChild("AutoPlantHudSlot")
	if existing and existing:IsA("GuiObject") then
		host = existing
	else
		if existing then
			existing:Destroy()
		end
		local frame = Instance.new("Frame")
		frame.Name = "AutoPlantHudSlot"
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Parent = quickbar
		host = frame
	end

	dockSlot3 = slot3
	dockSlot4 = slot4
	quickbarRef = quickbar
	-- Kill any leftover intro overlay from a prior broken run.
	local leftover = d.playerGui:FindFirstChild("OceanTD_AutoPlantTutorialIntro")
	if leftover then
		leftover:Destroy()
	end
	host.AnchorPoint = slot3.AnchorPoint
	host.Position = slot3.Position
	host.Size = slot4.Size
	host.ZIndex = slot3.ZIndex
	host.Visible = false
	local strayScale = host:FindFirstChild("_OceanTD_TutorialIntroScale")
	if strayScale then
		strayScale:Destroy()
	end

	hostButton = d.ensureButton(host)
	d.passthroughDecor(host, hostButton)
	circle = d.ensureCircle(host)
	UiCircles.forceOnDescendants(host)
	stroke = d.ensureStroke(circle, "_OceanTD_AutoPlantHudRing", WHITE, 3)
	stroke.Enabled = true

	local existingLbl = circle:FindFirstChild("_OceanTD_AutoPlantHudLabel")
	if existingLbl and existingLbl:IsA("TextLabel") then
		label = existingLbl
	else
		if existingLbl then
			existingLbl:Destroy()
		end
		local lbl = Instance.new("TextLabel")
		lbl.Name = "_OceanTD_AutoPlantHudLabel"
		lbl.BackgroundTransparency = 1
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.Font = UiTheme.Font
		lbl.Text = "AUTO\nPLANT"
		lbl.TextColor3 = WHITE
		lbl.TextScaled = true
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.TextYAlignment = Enum.TextYAlignment.Center
		lbl.ZIndex = circle.ZIndex + 2
		lbl.Active = false
		lbl.Parent = circle
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.14, 0)
		pad.PaddingBottom = UDim.new(0.14, 0)
		pad.PaddingLeft = UDim.new(0.08, 0)
		pad.PaddingRight = UDim.new(0.08, 0)
		pad.Parent = lbl
		label = lbl
	end
	label.Text = "AUTO\nPLANT"
	if host then
		ensureXGlyph(host)
	end

	if hostButton:GetAttribute("_OceanTD_AutoPlantHudBound") ~= true then
		hostButton:SetAttribute("_OceanTD_AutoPlantHudBound", true)
		hostButton.MouseButton1Down:Connect(onPress)
		hostButton.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				onPress()
			end
		end)
	end

	AutoPlantUI.onStateChanged(function()
		if host and host.Visible then
			-- Keep idle running; refresh colors / current frame text.
			startIdle()
		end
	end)
	InventoryState.onOpenChanged(function()
		AutoPlantHudSlot.syncVisibility()
	end)
	WaveSim.onHud(function()
		AutoPlantHudSlot.syncVisibility()
	end)
	WaveSim.onStopped(function()
		AutoPlantHudSlot.syncVisibility()
	end)
	local pg = d.playerGui
	pg:GetAttributeChangedSignal("OceanTD_SkillsBubblesOpen"):Connect(function()
		AutoPlantHudSlot.syncVisibility()
	end)
	pg:GetAttributeChangedSignal(REPORT_OPEN_ATTR):Connect(function()
		AutoPlantHudSlot.syncVisibility()
	end)
	pg:GetAttributeChangedSignal("OceanTD_StoreOpen"):Connect(function()
		AutoPlantHudSlot.syncVisibility()
	end)
	pg:GetAttributeChangedSignal("OceanTD_TutorialChapter"):Connect(function()
		AutoPlantHudSlot.syncVisibility()
	end)
	pg:GetAttributeChangedSignal("OceanTD_RollFingerHint"):Connect(function()
		syncTutorialLock()
		refreshXGlyph()
	end)
	UserInputService.LastInputTypeChanged:Connect(refreshXGlyph)
	require(script.Parent:WaitForChild("RelocateController")).onActiveChanged(function()
		refreshXGlyph()
	end)
	pg:GetAttributeChangedSignal("OceanTD_PlaceConfirmChromeUp"):Connect(refreshXGlyph)
	local cam = Workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(refreshXGlyph)
	end

	task.defer(function()
		-- Remotes + state even if backpack never opened (toggle lives on HUD now).
		if not AutoPlantUI.ensureBound() then
			AutoPlantUI.refreshFromServer()
		end
		AutoPlantHudSlot.syncVisibility()
	end)
	d.log("AutoPlantHudSlot ready (AUTO PLANT ↔ ON/OFF idle)")
end

return AutoPlantHudSlot
