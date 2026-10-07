--!strict
--[[
	During a live wave: click/tap near a critter to lob a free food orb
	from mid-screen → fish (+1 hunger, cooldown).
	Successful taps get instant juice: white sphere spray + short haptic.
	TAP_FEED_DEBUG draws a translucent ball = clickable world radius.

	Joystick + FishCam while waves run: on-screen crosshair (left stick aim, A feed).
]]

local ContextActionService = game:GetService("ContextActionService")
local GamepadService = game:GetService("GamepadService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local WaveSimConsts = require(script.Parent:WaitForChild("WaveSimConsts"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
local PlaceConfirmHitTest = require(script.Parent:WaitForChild("PlaceConfirmHitTest"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local TAP_BURST_COUNT = 6
-- Player taps: green spheres (tutorial finger keeps white).
local TAP_BURST_COLOR = WaveSimConsts.FILL_GREEN
local tapBurstRng = Random.new()
local juiceGui: ScreenGui? = nil
local juiceLayer: Frame? = nil

local AIM_GUI_NAME = "OceanTD_FishFeedAim"
local AIM_SINK_ACTION = "OceanTD_FishFeedAimSink"
local AIM_SPEED_PX = 720
local AIM_DEADZONE = 0.18
local CROSS_SIZE = 44
local CROSS_COLOR = Color3.fromRGB(255, 255, 255)
local CROSS_STROKE = Color3.fromRGB(20, 160, 70)
local A_TIP_IDLE = Color3.fromRGB(40, 130, 220)
local A_TIP_HIT = Color3.fromRGB(40, 180, 80)
local A_TIP_FAIL = Color3.fromRGB(200, 45, 55)
local A_TIP_FLASH_SEC = 0.18
local A_STATUS_POP_SEC = 0.22
local A_STATUS_HOLD_SEC = 0.28
local A_STATUS_BASE = Vector2.new(96, 18)
local A_STATUS_SCALE_PEAK = 1.45
local PLAYER_AIM_LIFT_PX = 72 -- raise reticle above avatar head on Player Cam
local ATTR_AIM_ACTIVE = "OceanTD_FishFeedAimActive"

local aimGui: ScreenGui? = nil
local crossRoot: Frame? = nil
local aimPos: Vector2 = Vector2.zero
local aimStick = Vector2.zero
local aTipFlashToken = 0
local aStatusToken = 0
local aimConn: RBXScriptConnection? = nil
local aHeld = false
local locoLocked = false
local savedWalkSpeed = 16
local savedJumpPower = 50
local savedJumpHeight = 7.2
local savedMouseIconEnabled: boolean? = nil
local savedMouseIcon: string? = nil

local function ensureJuiceLayer(): Frame?
	if juiceLayer and juiceLayer.Parent then
		return juiceLayer
	end
	local sg = juiceGui
	if not (sg and sg.Parent) then
		sg = Instance.new("ScreenGui")
		sg.Name = "OceanTD_TapFeedJuice"
		sg.ResetOnSpawn = false
		sg.IgnoreGuiInset = true
		sg.DisplayOrder = 47
		sg.Parent = playerGui
		juiceGui = sg
	end
	local layer = Instance.new("Frame")
	layer.Name = "BurstLayer"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.Active = false
	layer.ZIndex = 5
	pcall(function()
		(layer :: any).Interactable = false
	end)
	layer.Parent = sg
	juiceLayer = layer
	return layer
end

local function spawnTapCircle(layer: Frame, origin: Vector2)
	local sizePx = tapBurstRng:NextInteger(7, 12)
	local circle = Instance.new("Frame")
	circle.Name = "TapBurst"
	circle.BorderSizePixel = 0
	circle.BackgroundColor3 = TAP_BURST_COLOR
	circle.BackgroundTransparency = 0
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromOffset(origin.X, origin.Y)
	circle.Size = UDim2.fromOffset(sizePx, sizePx)
	circle.ZIndex = 5
	circle.Active = false
	pcall(function()
		(circle :: any).Interactable = false
	end)
	circle.Parent = layer
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = circle
	local scale = Instance.new("UIScale")
	scale.Scale = 0.15
	scale.Parent = circle

	local angle = tapBurstRng:NextNumber(-math.pi * 0.85, -math.pi * 0.15)
	local speed = tapBurstRng:NextNumber(180, 420)
	local vx = math.cos(angle) * speed
	local vy = math.sin(angle) * speed
	local grav = tapBurstRng:NextNumber(850, 1200)
	local life = tapBurstRng:NextNumber(0.45, 0.75)
	local popAt = tapBurstRng:NextNumber(0.05, 0.12)
	local peak = tapBurstRng:NextNumber(1.0, 1.35)
	local x = origin.X
	local y = origin.Y
	task.spawn(function()
		local t0 = os.clock()
		while circle.Parent do
			local dt = RunService.RenderStepped:Wait()
			local age = os.clock() - t0
			if age >= life then
				break
			end
			vy += grav * dt
			x += vx * dt
			y += vy * dt
			vx *= (1 - 0.4 * dt)
			circle.Position = UDim2.fromOffset(x, y)
			if age < popAt then
				scale.Scale = 0.15 + (peak - 0.15) * (age / popAt)
			else
				local u = math.clamp((age - popAt) / math.max(0.05, life - popAt), 0, 1)
				scale.Scale = peak * (1 - 0.55 * u)
			end
			circle.BackgroundTransparency = math.clamp((age - life * 0.45) / (life * 0.55), 0, 1)
		end
		if circle.Parent then
			circle:Destroy()
		end
	end)
end

local function playTapJuice(screenPos: Vector2)
	local layer = ensureJuiceLayer()
	if not layer then
		return
	end
	for _ = 1, TAP_BURST_COUNT do
		spawnTapCircle(layer, screenPos)
	end
	UiHaptics.pulseShort()
end

local function screenBlocked(screenPos: Vector2): boolean
	local inset = GuiService:GetGuiInset()
	local guiPos = screenPos - Vector2.new(inset.X, inset.Y)
	local ok, hits = pcall(function()
		return playerGui:GetGuiObjectsAtPosition(guiPos.X, guiPos.Y)
	end)
	if not ok or typeof(hits) ~= "table" then
		return false
	end
	for _, gui in ipairs(hits) do
		-- Only real buttons/text boxes swallow the tap (frames/labels stay pass-through).
		if gui:IsA("GuiButton") or gui:IsA("TextBox") then
			if gui.Visible and gui.Active then
				return true
			end
		end
	end
	return false
end

local function ensureAStatusLabel(): TextLabel?
	local tip = crossRoot and crossRoot:FindFirstChild("ATip")
	if not (tip and tip:IsA("GuiObject")) then
		return nil
	end
	local existing = tip:FindFirstChild("Status")
	if existing and existing:IsA("TextLabel") then
		return existing
	end
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.AnchorPoint = Vector2.new(0.5, 0)
	status.Position = UDim2.new(0.5, 0, 1, 2)
	status.Size = UDim2.fromOffset(A_STATUS_BASE.X, A_STATUS_BASE.Y)
	status.Font = UiTheme.Font
	status.Text = ""
	status.TextColor3 = A_TIP_FAIL
	status.TextScaled = true
	status.TextStrokeTransparency = 0.35
	status.TextStrokeColor3 = Color3.new(0, 0, 0)
	status.Visible = false
	status.ZIndex = 13
	status.Parent = tip
	local scale = Instance.new("UIScale")
	scale.Name = "PopScale"
	scale.Scale = 1
	scale.Parent = status
	return status
end

local function flashATip(kind: "hit" | "fail", statusText: string?)
	local tip = crossRoot and crossRoot:FindFirstChild("ATip")
	if not (tip and tip:IsA("GuiObject")) then
		return
	end
	local accent = if kind == "hit" then A_TIP_HIT else A_TIP_FAIL
	aTipFlashToken += 1
	local my = aTipFlashToken
	-- Button: white → accent flash.
	tip.BackgroundColor3 = Color3.new(1, 1, 1)
	task.delay(A_TIP_FLASH_SEC * 0.45, function()
		if my ~= aTipFlashToken or not tip.Parent then
			return
		end
		tip.BackgroundColor3 = accent
	end)
	task.delay(A_TIP_FLASH_SEC, function()
		if my ~= aTipFlashToken then
			return
		end
		if tip.Parent then
			tip.BackgroundColor3 = A_TIP_IDLE
		end
	end)

	local status = ensureAStatusLabel()
	if not status then
		return
	end
	aStatusToken += 1
	local statusMy = aStatusToken
	if not (statusText and statusText ~= "") then
		status.Visible = false
		status.Text = ""
		return
	end

	local scale = status:FindFirstChild("PopScale")
	if not (scale and scale:IsA("UIScale")) then
		local made = Instance.new("UIScale")
		made.Name = "PopScale"
		made.Parent = status
		scale = made
	end
	assert(scale and scale:IsA("UIScale"))

	status.Text = statusText
	status.TextColor3 = Color3.new(1, 1, 1)
	status.Size = UDim2.fromOffset(A_STATUS_BASE.X, A_STATUS_BASE.Y)
	scale.Scale = 1
	status.Visible = true

	-- White → accent mid-pop; scale grows then settles before hide.
	task.delay(A_STATUS_POP_SEC * 0.35, function()
		if statusMy ~= aStatusToken or not status.Parent then
			return
		end
		status.TextColor3 = accent
	end)
	task.spawn(function()
		local grow = TweenService:Create(
			scale,
			TweenInfo.new(A_STATUS_POP_SEC, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = A_STATUS_SCALE_PEAK }
		)
		grow:Play()
		grow.Completed:Wait()
		if statusMy ~= aStatusToken or not status.Parent then
			return
		end
		local shrink = TweenService:Create(
			scale,
			TweenInfo.new(A_STATUS_POP_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ Scale = 1 }
		)
		shrink:Play()
		shrink.Completed:Wait()
		if statusMy ~= aStatusToken or not status.Parent then
			return
		end
		task.wait(A_STATUS_HOLD_SEC)
		if statusMy ~= aStatusToken or not status.Parent then
			return
		end
		status.Visible = false
		status.Text = ""
		scale.Scale = 1
	end)
end

local function flashScreenStatus(screenPos: Vector2, kind: "hit" | "fail", statusText: string)
	local layer = ensureJuiceLayer()
	if not layer then
		return
	end
	local accent = if kind == "hit" then A_TIP_HIT else A_TIP_FAIL
	local status = Instance.new("TextLabel")
	status.Name = "TapStatus"
	status.BackgroundTransparency = 1
	status.AnchorPoint = Vector2.new(0.5, 0)
	status.Position = UDim2.fromOffset(screenPos.X, screenPos.Y + 10)
	status.Size = UDim2.fromOffset(A_STATUS_BASE.X, A_STATUS_BASE.Y)
	status.Font = UiTheme.Font
	status.Text = statusText
	status.TextColor3 = Color3.new(1, 1, 1)
	status.TextScaled = true
	status.TextStrokeTransparency = 0.35
	status.TextStrokeColor3 = Color3.new(0, 0, 0)
	status.ZIndex = 20
	status.Active = false
	pcall(function()
		(status :: any).Interactable = false
	end)
	status.Parent = layer
	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = status

	task.delay(A_STATUS_POP_SEC * 0.35, function()
		if status.Parent then
			status.TextColor3 = accent
		end
	end)
	task.spawn(function()
		local grow = TweenService:Create(
			scale,
			TweenInfo.new(A_STATUS_POP_SEC, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = A_STATUS_SCALE_PEAK }
		)
		grow:Play()
		grow.Completed:Wait()
		if not status.Parent then
			return
		end
		local shrink = TweenService:Create(
			scale,
			TweenInfo.new(A_STATUS_POP_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ Scale = 1 }
		)
		shrink:Play()
		shrink.Completed:Wait()
		if not status.Parent then
			return
		end
		task.wait(A_STATUS_HOLD_SEC)
		if status.Parent then
			status:Destroy()
		end
	end)
end

local function tryFeedAtScreen(screenPos: Vector2, flashTip: boolean?): boolean
	if not WaveSim.isRunning() then
		return false
	end
	if InventoryState.isOpen() or PlacementController.isActive() or RelocateController.isActive() then
		return false
	end
	if screenBlocked(screenPos) then
		return false
	end
	local result = WaveSim.tryTapFeedAtScreen(screenPos)
	local function showResult(kind: "hit" | "fail", text: string)
		if flashTip then
			flashATip(kind, text)
		else
			-- Mouse / touch: float the same help text under the tap spot.
			flashScreenStatus(screenPos, kind, text)
		end
	end
	if result == "hit" then
		playTapJuice(screenPos)
		showResult("hit", "+1 Food")
		if WaveSim.getWaveIndex() == WaveSimConsts.TANG_FIRST_WAVE then
			-- Dismiss the wave-1 "tap fish to feed" finger after the first successful tap.
			playerGui:SetAttribute("OceanTD_Wave1TapFeedOk", os.clock())
		end
		return true
	end
	if result == "cooldown" then
		showResult("fail", "Reloading")
	elseif result == "full" then
		showResult("hit", "Full")
	elseif result == "miss" then
		showResult("fail", "Miss!")
	end
	return false
end

local function isGamepadMode(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function camCycleMode(): string
	local m = playerGui:GetAttribute("OceanTD_CamCycleMode")
	return if typeof(m) == "string" then m else "off"
end

-- Fish Cam: left stick moves the reticle. Other cams: reticle stays screen-center.
local function usesStickMovedAim(): boolean
	return camCycleMode() == "fishcam"
end

local function isPlayerCamAim(): boolean
	return camCycleMode() == "off"
end

local function feedButtonKey(): Enum.KeyCode
	return if isPlayerCamAim() then Enum.KeyCode.ButtonR1 else Enum.KeyCode.ButtonA
end

local function centerAimPos(vp: Vector2): Vector2
	if isPlayerCamAim() then
		return Vector2.new(vp.X * 0.5, math.max(CROSS_SIZE, vp.Y * 0.5 - PLAYER_AIM_LIFT_PX))
	end
	return vp * 0.5
end

local function syncShootTipLabel()
	local tip = crossRoot and crossRoot:FindFirstChild("ATip")
	if not (tip and tip:IsA("TextLabel")) then
		return
	end
	tip.Text = if isPlayerCamAim() then "R1" else "A"
	-- Slightly wider for "R1".
	tip.Size = if isPlayerCamAim() then UDim2.fromOffset(34, 26) else UDim2.fromOffset(26, 26)
end

local function canShowAimCrosshair(): boolean
	if not isGamepadMode() then
		return false
	end
	if not WaveSim.isRunning() then
		return false
	end
	-- Joystick aim works in Fish / Plot / Drone / Player cam while waves run.
	if InventoryState.isOpen() or PlacementController.isActive() or RelocateController.isActive() then
		return false
	end
	if playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true
		or playerGui:GetAttribute("OceanTD_SkillPowerUpOpen") == true
		or playerGui:GetAttribute("OceanTD_ReefReportOpen") == true
		or playerGui:GetAttribute("OceanTD_HideUiActive") == true
	then
		return false
	end
	return true
end

local function getPlayerControls(): any?
	local ok, controls = pcall(function()
		local ps = player:WaitForChild("PlayerScripts", 2)
		local pm = ps and ps:FindFirstChild("PlayerModule")
		if not pm then
			return nil
		end
		return require(pm):GetControls()
	end)
	if ok then
		return controls
	end
	return nil
end

local function setLocomotionLocked(on: boolean)
	if on == locoLocked then
		if on then
			-- Keep freezing velocity while aim is up.
			local character = player.Character
			local hum = character and character:FindFirstChildOfClass("Humanoid")
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			if hum then
				hum.WalkSpeed = 0
				hum.JumpPower = 0
				hum.JumpHeight = 0
				pcall(function()
					hum:Move(Vector3.zero, false)
				end)
			end
			if hrp and hrp:IsA("BasePart") then
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.AssemblyAngularVelocity = Vector3.zero
			end
		end
		return
	end
	locoLocked = on
	ContextActionService:UnbindAction(AIM_SINK_ACTION)
	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local controls = getPlayerControls()
	if on then
		if hum then
			if hum.WalkSpeed > 0 then
				savedWalkSpeed = hum.WalkSpeed
			end
			if hum.JumpPower > 0 then
				savedJumpPower = hum.JumpPower
			end
			if hum.JumpHeight > 0 then
				savedJumpHeight = hum.JumpHeight
			end
			hum.WalkSpeed = 0
			hum.JumpPower = 0
			hum.JumpHeight = 0
			hum.AutoRotate = false
			pcall(function()
				hum:Move(Vector3.zero, false)
			end)
		end
		if hrp and hrp:IsA("BasePart") then
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
		end
		if controls then
			pcall(function()
				controls:Disable()
			end)
		end
		-- Sink stick so PlayerModule cannot walk the avatar; WaveTapFeed still reads InputChanged.
		ContextActionService:BindActionAtPriority(
			AIM_SINK_ACTION,
			function()
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.ContextActionPriority.High.Value + 10,
			Enum.KeyCode.Thumbstick1,
			Enum.KeyCode.W,
			Enum.KeyCode.A,
			Enum.KeyCode.S,
			Enum.KeyCode.D,
			Enum.KeyCode.Space
		)
	else
		if hum then
			hum.WalkSpeed = savedWalkSpeed
			hum.JumpPower = savedJumpPower
			hum.JumpHeight = savedJumpHeight
			hum.AutoRotate = true
		end
		if controls then
			-- Only re-enable if FreeCam isn't already owning locomotion (FishCam/PlotCam).
			local camMode = playerGui:GetAttribute("OceanTD_CamCycleMode")
			if camMode == nil or camMode == "off" then
				pcall(function()
					controls:Enable()
				end)
			end
		end
	end
end

local function viewportSize(): Vector2
	local cam = workspace.CurrentCamera
	return if cam then cam.ViewportSize else Vector2.new(1920, 1080)
end

local function ensureAimCrosshair(): Frame
	local sg = aimGui
	if not (sg and sg.Parent) then
		if sg then
			sg:Destroy()
		end
		sg = Instance.new("ScreenGui")
		sg.Name = AIM_GUI_NAME
		sg.ResetOnSpawn = false
		sg.IgnoreGuiInset = true
		sg.DisplayOrder = 120
		sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		sg.Parent = playerGui
		aimGui = sg
	end
	local root = crossRoot
	if root and root.Parent then
		local oldDot = root:FindFirstChild("Dot")
		if oldDot and oldDot:IsA("GuiObject") then
			oldDot.Visible = false
		end
		return root
	end
	local f = Instance.new("Frame")
	f.Name = "Crosshair"
	f.BackgroundTransparency = 1
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromOffset(CROSS_SIZE, CROSS_SIZE)
	f.Active = false
	f.ZIndex = 10
	f.Parent = sg

	local function makeBar(name: string, size: UDim2, pos: UDim2)
		local bar = Instance.new("Frame")
		bar.Name = name
		bar.BorderSizePixel = 0
		bar.BackgroundColor3 = CROSS_COLOR
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = pos
		bar.Size = size
		bar.ZIndex = 11
		bar.Parent = f
		local stroke = Instance.new("UIStroke")
		stroke.Color = CROSS_STROKE
		stroke.Thickness = 2
		stroke.Parent = bar
	end
	makeBar("H", UDim2.fromOffset(CROSS_SIZE, 4), UDim2.fromScale(0.5, 0.5))
	makeBar("V", UDim2.fromOffset(4, CROSS_SIZE), UDim2.fromScale(0.5, 0.5))

	local tip = Instance.new("TextLabel")
	tip.Name = "ATip"
	tip.BackgroundColor3 = A_TIP_IDLE
	tip.BackgroundTransparency = 0
	tip.AnchorPoint = Vector2.new(0.5, 0)
	tip.Position = UDim2.new(0.5, 0, 1, 8)
	tip.Size = UDim2.fromOffset(26, 26)
	tip.Font = UiTheme.Font
	tip.Text = "A"
	tip.TextColor3 = Color3.new(1, 1, 1)
	tip.TextScaled = true
	tip.ZIndex = 12
	tip.Parent = f
	local tipCorner = Instance.new("UICorner")
	tipCorner.CornerRadius = UDim.new(1, 0)
	tipCorner.Parent = tip

	crossRoot = f
	return f
end

local function setDefaultCursorHidden(hidden: boolean)
	-- Hide Roblox's default mouse / gamepad virtual-cursor dot while our feed crosshair is up.
	if hidden then
		if savedMouseIconEnabled == nil then
			savedMouseIconEnabled = UserInputService.MouseIconEnabled
			savedMouseIcon = UserInputService.MouseIcon
		end
		UserInputService.MouseIconEnabled = false
		pcall(function()
			UserInputService.MouseIcon = ""
		end)
		pcall(function()
			GamepadService:DisableGamepadCursor()
		end)
	elseif savedMouseIconEnabled ~= nil then
		UserInputService.MouseIconEnabled = savedMouseIconEnabled
		pcall(function()
			UserInputService.MouseIcon = savedMouseIcon or ""
		end)
		savedMouseIconEnabled = nil
		savedMouseIcon = nil
	end
end

local function setAimVisible(on: boolean)
	local f = ensureAimCrosshair()
	f.Visible = on
	if aimGui then
		aimGui.Enabled = on
	end
	local stickAim = on and usesStickMovedAim()
	if on then
		local vp = viewportSize()
		if stickAim then
			if aimPos.X < 1 and aimPos.Y < 1 then
				aimPos = centerAimPos(vp)
			end
		else
			-- Plot / Free / Player: locked reticle; Player Cam sits higher above the avatar.
			aimPos = centerAimPos(vp)
		end
		f.Position = UDim2.fromOffset(aimPos.X, aimPos.Y)
		syncShootTipLabel()
	end
	setDefaultCursorHidden(on)
	-- Only Fish Cam steals left stick / freezes the avatar for free-aim.
	playerGui:SetAttribute(ATTR_AIM_ACTIVE, stickAim)
	playerGui:SetAttribute("OceanTD_FishFeedAimCenter", on and not stickAim)
	setLocomotionLocked(stickAim)
end

local aimWanted = false

local function bindAimLoop(on: boolean)
	if on == aimWanted and (on == false or aimConn ~= nil) then
		if not on then
			setAimVisible(false)
		end
		return
	end
	aimWanted = on
	if aimConn then
		aimConn:Disconnect()
		aimConn = nil
	end
	if not on then
		setAimVisible(false)
		return
	end
	aimConn = RunService.RenderStepped:Connect(function(dt)
		if not canShowAimCrosshair() then
			if aimWanted then
				aimWanted = false
				setAimVisible(false)
				if aimConn then
					aimConn:Disconnect()
					aimConn = nil
				end
			end
			return
		end
		local stickAim = usesStickMovedAim()
		-- Mode can change while the loop runs (Fish ↔ Plot / Free / Player).
		playerGui:SetAttribute(ATTR_AIM_ACTIVE, stickAim)
		playerGui:SetAttribute("OceanTD_FishFeedAimCenter", not stickAim)
		setLocomotionLocked(stickAim)
		-- CoreScripts sometimes re-enable the default cursor; keep it suppressed.
		if UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = false
		end

		local f = crossRoot
		if not f or not f.Visible then
			setAimVisible(true)
			f = crossRoot
		end
		local vp = viewportSize()
		if stickAim then
			local stick = aimStick
			if stick.Magnitude > AIM_DEADZONE then
				local n = stick.Unit * math.clamp(stick.Magnitude, AIM_DEADZONE, 1)
				local pad = CROSS_SIZE
				aimPos = Vector2.new(
					math.clamp(aimPos.X + n.X * AIM_SPEED_PX * dt, pad, vp.X - pad),
					math.clamp(aimPos.Y - n.Y * AIM_SPEED_PX * dt, pad, vp.Y - pad)
				)
			end
		else
			aimPos = centerAimPos(vp)
		end
		if f then
			f.Position = UDim2.fromOffset(aimPos.X, aimPos.Y)
		end
		syncShootTipLabel()
	end)
end

local function refreshAimMode()
	local want = canShowAimCrosshair()
	bindAimLoop(want)
	if want then
		setAimVisible(true)
	else
		setAimVisible(false)
		aHeld = false
	end
end

local function onInput(input: InputObject, gameProcessed: boolean)
	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		if usesStickMovedAim() then
			aimStick = Vector2.new(input.Position.X, input.Position.Y)
		end
		return
	end
	local shootKey = feedButtonKey()
	if input.KeyCode == shootKey and input.UserInputState == Enum.UserInputState.Begin then
		if canShowAimCrosshair() and not aHeld then
			aHeld = true
			tryFeedAtScreen(aimPos, true)
			return
		end
	end
	if gameProcessed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	then
		-- Same pointer space as place/relocate (touch +inset → GetMouseLocation space).
		local screenPos = PlaceConfirmHitTest.pointerScreenPos(input)
		-- Flash tip when aim HUD is up; touch/mouse still feed without requiring gamepad.
		tryFeedAtScreen(screenPos, canShowAimCrosshair())
	end
end

UserInputService.InputBegan:Connect(onInput)
UserInputService.InputChanged:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		aimStick = Vector2.new(input.Position.X, input.Position.Y)
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		aimStick = Vector2.zero
	elseif input.KeyCode == Enum.KeyCode.ButtonA or input.KeyCode == Enum.KeyCode.ButtonR1 then
		aHeld = false
	end
end)

UserInputService.LastInputTypeChanged:Connect(refreshAimMode)
playerGui:GetAttributeChangedSignal("OceanTD_CamCycleMode"):Connect(refreshAimMode)
InventoryState.onOpenChanged(refreshAimMode)
WaveSim.onHud(function()
	refreshAimMode()
end)
WaveSim.onStopped(function()
	refreshAimMode()
end)
task.defer(refreshAimMode)

-- Debug radii are attached by WaveSim when TAP_FEED_DEBUG is true.
if WaveSimConsts.TAP_FEED_DEBUG then
	print("[WaveTapFeed] debug radii ON — cyan ForceField balls = tap radius (", WaveSimConsts.TAP_FEED_RADIUS, "studs)")
end
