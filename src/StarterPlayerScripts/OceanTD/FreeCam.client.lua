--!strict
--[[
	FreeCam — leave avatar and fly inside the local plot's SkyCam volume,
	always looking at SkyCamFocus. Touch: left thumb moves only (no look stick).

	Plot1: Workspace.MasterPlotDecor.SkyCam (+ .SkyCamFocus)
	PlotN: Workspace.StaticPlot_N.SkyCam (cloned by DecorReplicator)
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))

local RED = Color3.fromRGB(220, 50, 55)
local GREEN = Color3.fromRGB(40, 220, 110)
local STROKE_NAME = "_OceanTD_FreeCamStroke"
local STROKE_THICK = 3
local MOVE_SPEED = 48 * 1.3 -- +30%
local TOUCH_STICK_RADIUS = 90
local SINK_ACTION = "OceanTD_FreeCamSink"
local DPAD_ACTION = "OceanTD_FreeCamDPad"
local MARGIN = 0.75
local SKY_CAM_NAME = "SkyCam"
local SKY_FOCUS_NAME = "SkyCamFocus"

local active = false
local camPos = Vector3.zero
local savedCameraType: Enum.CameraType? = nil
local savedWalkSpeed = 16
local savedJumpPower = 50
local savedJumpHeight = 7.2
local renderConn: RBXScriptConnection? = nil
local btnStroke: UIStroke? = nil
local freeCamButton: GuiButton? = nil
local dPadIcon: GuiObject? = nil
local dPadIconScale: UIScale? = nil
local dPadIconShown = false
local dPadIconTween: Tween? = nil
local dPadGlowToken = 0
local controlsDisabled = false
local ICON_SCALE_IN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local ICON_SCALE_OUT = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local DPAD_GLOW_SEC = 0.5
local DPAD_GLOW_INFO = TweenInfo.new(DPAD_GLOW_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local moveTouch: InputObject? = nil
local moveOrigin = Vector2.zero
local touchMoveVec = Vector2.zero -- -1..1

local keysDown: { [Enum.KeyCode]: boolean } = {}
local moveStick = Vector2.zero

local cachedSkyCam: BasePart? = nil
local cachedFocus: BasePart? = nil
local cachedPlotId: string? = nil

local function getCamera(): Camera?
	return Workspace.CurrentCamera
end

local function decorRootForPlot(plotId: string): Instance?
	if plotId == "Plot1" then
		return Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
	end
	local n = tonumber(string.match(plotId, "%d+"))
	if n and n >= 2 then
		return Workspace:FindFirstChild(Constants.STATIC_PLOT_PREFIX .. tostring(n))
	end
	return nil
end

local function resolveSkyParts(): (BasePart?, BasePart?)
	local mirrored = ClientPlot.get()
	local plotId = if mirrored then mirrored.plotId else nil
	if plotId and cachedPlotId == plotId and cachedSkyCam and cachedSkyCam.Parent and cachedFocus and cachedFocus.Parent then
		return cachedSkyCam, cachedFocus
	end
	cachedSkyCam = nil
	cachedFocus = nil
	cachedPlotId = plotId

	local root: Instance? = nil
	if plotId then
		root = decorRootForPlot(plotId)
	end
	-- Fallback to master (plot1 authored path) if plot not assigned yet.
	if not root then
		root = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
	end
	if not root then
		return nil, nil
	end

	local sky: Instance? = root:FindFirstChild(SKY_CAM_NAME)
	if not sky then
		sky = root:FindFirstChild(SKY_CAM_NAME, true)
	end
	if not (sky and sky:IsA("BasePart")) then
		return nil, nil
	end
	local focus = sky:FindFirstChild(SKY_FOCUS_NAME)
	if not (focus and focus:IsA("BasePart")) then
		focus = root:FindFirstChild(SKY_FOCUS_NAME, true)
	end
	if not (focus and focus:IsA("BasePart")) then
		return nil, nil
	end

	cachedSkyCam = sky
	cachedFocus = focus :: BasePart
	return cachedSkyCam, cachedFocus
end

local function clampToSkyCam(pos: Vector3, sky: BasePart): Vector3
	local localPos = sky.CFrame:PointToObjectSpace(pos)
	local half = sky.Size * 0.5
	local hx = math.max(half.X - MARGIN, 0.05)
	local hy = math.max(half.Y - MARGIN, 0.05)
	local hz = math.max(half.Z - MARGIN, 0.05)
	local clamped = Vector3.new(
		math.clamp(localPos.X, -hx, hx),
		math.clamp(localPos.Y, -hy, hy),
		math.clamp(localPos.Z, -hz, hz)
	)
	return sky.CFrame:PointToWorldSpace(clamped)
end

local function lookAtFocus(focusPos: Vector3): CFrame
	if (focusPos - camPos).Magnitude < 0.05 then
		return CFrame.new(camPos)
	end
	return CFrame.lookAt(camPos, focusPos)
end

local function ensureStroke(gui: GuiObject): UIStroke
	local existing = gui:FindFirstChild(STROKE_NAME)
	if existing and existing:IsA("UIStroke") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local s = Instance.new("UIStroke")
	s.Name = STROKE_NAME
	s.Thickness = STROKE_THICK
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = gui
	return s
end

local function strokeTarget(btn: GuiObject): GuiObject
	local circle = btn:FindFirstChild("Circle")
	if circle and circle:IsA("GuiObject") then
		return circle
	end
	return btn
end

local function refreshStroke()
	if not btnStroke then
		return
	end
	btnStroke.Enabled = true
	btnStroke.Thickness = STROKE_THICK
	btnStroke.Color = if active then GREEN else RED
end

local function getPlayerControls(): any
	local ok, controls = pcall(function()
		local ps = player:FindFirstChild("PlayerScripts")
		local pm = ps and ps:FindFirstChild("PlayerModule")
		if pm then
			return require(pm):GetControls()
		end
		return nil
	end)
	if ok then
		return controls
	end
	return nil
end

local function setCharacterLocked(locked: boolean)
	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hum then
		if locked then
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
		else
			hum.WalkSpeed = savedWalkSpeed
			hum.JumpPower = savedJumpPower
			hum.JumpHeight = savedJumpHeight
			hum.AutoRotate = true
		end
	end
	if locked and hrp and hrp:IsA("BasePart") then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end
end

local function keepCharacterStill()
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

local function setControlsEnabled(on: boolean)
	local controls = getPlayerControls()
	if not controls then
		controlsDisabled = false
		return
	end
	pcall(function()
		if on then
			controls:Enable()
			controlsDisabled = false
		else
			controls:Disable()
			controlsDisabled = true
		end
	end)
end

local function bindSink(on: boolean)
	ContextActionService:UnbindAction(SINK_ACTION)
	if not on then
		return
	end
	-- Sink locomotion so the avatar cannot walk while freecam is on.
	ContextActionService:BindActionAtPriority(
		SINK_ACTION,
		function()
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
		Enum.KeyCode.Space,
		Enum.KeyCode.ButtonA
	)
end

local function stickFromOrigin(origin: Vector2, pos: Vector2): Vector2
	local delta = pos - origin
	local mag = delta.Magnitude
	if mag < 1e-3 then
		return Vector2.zero
	end
	if mag > TOUCH_STICK_RADIUS then
		delta = delta.Unit * TOUCH_STICK_RADIUS
	end
	return delta / TOUCH_STICK_RADIUS
end

local function isOverFreeCamButton(screenPos: Vector3): boolean
	local btn = freeCamButton
	if not btn then
		return false
	end
	local p = btn.AbsolutePosition
	local s = btn.AbsoluteSize
	local x, y = screenPos.X, screenPos.Y
	return x >= p.X and x <= p.X + s.X and y >= p.Y and y <= p.Y + s.Y
end

local function clearTouchMove()
	moveTouch = nil
	touchMoveVec = Vector2.zero
	moveOrigin = Vector2.zero
end

local function readMoveWish(cf: CFrame): Vector3
	local wish = Vector3.zero
	local flatLook = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	if flatLook.Magnitude > 1e-4 then
		flatLook = flatLook.Unit
	else
		flatLook = Vector3.new(0, 0, -1)
	end
	local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
	if right.Magnitude > 1e-4 then
		right = right.Unit
	else
		right = Vector3.new(1, 0, 0)
	end

	-- Touch virtual stick: screen Y is down-positive, so negate for forward.
	if touchMoveVec.Magnitude > 0.08 then
		wish += flatLook * -touchMoveVec.Y + right * touchMoveVec.X
	end

	if keysDown[Enum.KeyCode.W] then
		wish += flatLook
	end
	if keysDown[Enum.KeyCode.S] then
		wish -= flatLook
	end
	if keysDown[Enum.KeyCode.A] then
		wish -= right
	end
	if keysDown[Enum.KeyCode.D] then
		wish += right
	end
	if keysDown[Enum.KeyCode.E] or keysDown[Enum.KeyCode.Space] then
		wish += Vector3.yAxis
	end
	if keysDown[Enum.KeyCode.Q] or keysDown[Enum.KeyCode.LeftControl] then
		wish -= Vector3.yAxis
	end

	-- Gamepad left stick: Y+ is up — do not negate (was inverted).
	if moveStick.Magnitude > 0.12 then
		wish += flatLook * moveStick.Y + right * moveStick.X
	end

	if wish.Magnitude > 1e-4 then
		return wish.Unit
	end
	return Vector3.zero
end

local function stopRender()
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
end

local setEnabled: (boolean) -> ()

setEnabled = function(on: boolean)
	if on == active then
		return
	end
	if on then
		if PlacementController.isActive() or RelocateController.isActive() then
			return
		end
		local sky, focus = resolveSkyParts()
		if not sky or not focus then
			warn("[FreeCam] SkyCam / SkyCamFocus missing for local plot — freecam unavailable")
			return
		end
		local camera = getCamera()
		if not camera then
			return
		end

		active = true
		refreshStroke()

		if camera.CameraType ~= Enum.CameraType.Scriptable then
			savedCameraType = camera.CameraType
		else
			savedCameraType = Enum.CameraType.Custom
		end
		camPos = clampToSkyCam(camera.CFrame.Position, sky)
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = lookAtFocus(focus.Position)

		setCharacterLocked(true)
		bindSink(true)
		clearTouchMove()
		setControlsEnabled(false)

		stopRender()
		renderConn = RunService.RenderStepped:Connect(function(dt)
			if not active then
				return
			end
			if PlacementController.isActive() or RelocateController.isActive() then
				setEnabled(false)
				return
			end
			local cam = getCamera()
			local box, focusPart = resolveSkyParts()
			if not cam or not box or not focusPart then
				setEnabled(false)
				return
			end

			keepCharacterStill()

			local cf = lookAtFocus(focusPart.Position)
			local wish = readMoveWish(cf)
			local speed = MOVE_SPEED
			if keysDown[Enum.KeyCode.LeftShift] then
				speed *= 1.75
			end
			if touchMoveVec.Magnitude > 0.08 then
				speed *= math.clamp(touchMoveVec.Magnitude, 0.08, 1)
			elseif moveStick.Magnitude > 0.08 then
				speed *= math.clamp(moveStick.Magnitude, 0.08, 1)
			end
			camPos = clampToSkyCam(camPos + wish * speed * dt, box)
			cam.CameraType = Enum.CameraType.Scriptable
			cam.CFrame = lookAtFocus(focusPart.Position)
		end)
	else
		active = false
		refreshStroke()
		stopRender()
		bindSink(false)
		clearTouchMove()
		if controlsDisabled then
			setControlsEnabled(true)
		end
		table.clear(keysDown)
		moveStick = Vector2.zero

		setCharacterLocked(false)
		local camera = getCamera()
		if camera then
			local restore = savedCameraType or Enum.CameraType.Custom
			if restore == Enum.CameraType.Scriptable then
				restore = Enum.CameraType.Custom
			end
			camera.CameraType = restore
			local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if hum then
				camera.CameraSubject = hum
			end
		end
		savedCameraType = nil
	end
end

local function toggle()
	setEnabled(not active)
end

-- D-pad Left toggles freecam while backpack / build UI is closed.
ContextActionService:BindActionAtPriority(DPAD_ACTION, function(_name, state, _input)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if InventoryState.isOpen() then
		return Enum.ContextActionResult.Pass
	end
	if playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true then
		return Enum.ContextActionResult.Pass
	end
	if PlacementController.isActive() or RelocateController.isActive() then
		return Enum.ContextActionResult.Pass
	end
	toggle()
	return Enum.ContextActionResult.Sink
end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.DPadLeft)

local function isDPadKey(code: Enum.KeyCode): boolean
	return code == Enum.KeyCode.DPadLeft
		or code == Enum.KeyCode.DPadRight
		or code == Enum.KeyCode.DPadUp
		or code == Enum.KeyCode.DPadDown
end

local function ensureDPadGlow(): (Frame?, UIScale?)
	if not dPadIcon then
		return nil, nil
	end
	local existing = dPadIcon:FindFirstChild("_OceanTD_DPadGlow")
	if existing and existing:IsA("Frame") then
		local sc = existing:FindFirstChildOfClass("UIScale")
		if sc then
			return existing, sc
		end
	end
	if existing then
		existing:Destroy()
	end
	local f = Instance.new("Frame")
	f.Name = "_OceanTD_DPadGlow"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.Size = UDim2.fromScale(1.15, 1.15)
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.ZIndex = dPadIcon.ZIndex + 8
	f.Active = false
	f.Visible = true
	f.Parent = dPadIcon
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
	local sc = Instance.new("UIScale")
	sc.Scale = 0.2
	sc.Parent = f
	return f, sc
end

local function flashDPadGlow()
	if InventoryState.isOpen() or not dPadIcon then
		return
	end
	-- Skills bubbles own the d-pad while open — don't stack a second white center glow.
	if skillsBubblesOpen() then
		return
	end
	local glow, sc = ensureDPadGlow()
	if not glow or not sc then
		return
	end
	dPadGlowToken += 1
	local my = dPadGlowToken
	glow.Visible = true
	glow.BackgroundTransparency = 0.25
	sc.Scale = 0.15
	TweenService:Create(sc, DPAD_GLOW_INFO, { Scale = 1.55 }):Play()
	local fade = TweenService:Create(glow, DPAD_GLOW_INFO, { BackgroundTransparency = 1 })
	fade:Play()
	fade.Completed:Once(function()
		if my == dPadGlowToken and glow.Parent then
			glow.BackgroundTransparency = 1
			sc.Scale = 0.15
			glow.Visible = false
		end
	end)
end

local function skillsBubblesOpen(): boolean
	return playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true
end

UserInputService.InputBegan:Connect(function(input, _gameProcessed)
	if isDPadKey(input.KeyCode) then
		if not skillsBubblesOpen() then
			flashDPadGlow()
		end
	end
	if input.UserInputType == Enum.UserInputType.Keyboard then
		if active then
			keysDown[input.KeyCode] = true
		end
		return
	end
	if not active then
		return
	end
	if input.UserInputType == Enum.UserInputType.Touch then
		if isOverFreeCamButton(input.Position) then
			return
		end
		-- Any touch (typically left thumb) drives move — no right-thumb look.
		if moveTouch == nil then
			moveTouch = input
			moveOrigin = Vector2.new(input.Position.X, input.Position.Y)
			touchMoveVec = Vector2.zero
		end
	end
end)

UserInputService.InputChanged:Connect(function(input, _gameProcessed)
	if not active then
		return
	end
	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		moveStick = Vector2.new(input.Position.X, input.Position.Y)
		return
	end
	if input.UserInputType == Enum.UserInputType.Touch and input == moveTouch then
		touchMoveVec = stickFromOrigin(moveOrigin, Vector2.new(input.Position.X, input.Position.Y))
	end
end)

UserInputService.InputEnded:Connect(function(input, _gameProcessed)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		keysDown[input.KeyCode] = nil
	end
	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		moveStick = Vector2.zero
	end
	if input == moveTouch then
		clearTouchMove()
	end
end)

player.CharacterAdded:Connect(function()
	if active then
		task.defer(function()
			setCharacterLocked(true)
		end)
	end
end)

ClientPlot.onChanged(function()
	cachedSkyCam = nil
	cachedFocus = nil
	cachedPlotId = nil
	if active then
		local sky, focus = resolveSkyParts()
		if not sky or not focus then
			setEnabled(false)
		else
			camPos = clampToSkyCam(camPos, sky)
		end
	end
end)

local function wireButton(btn: GuiObject)
	local hit: GuiButton
	if btn:IsA("GuiButton") then
		hit = btn
	else
		local existing = btn:FindFirstChildWhichIsA("GuiButton", true)
		if existing then
			hit = existing
		else
			local made = Instance.new("TextButton")
			made.Name = "_OceanTD_FreeCamHit"
			made.Text = ""
			made.BackgroundTransparency = 1
			made.Size = UDim2.fromScale(1, 1)
			made.ZIndex = 100
			made.Parent = btn
			hit = made
		end
	end
	btnStroke = ensureStroke(strokeTarget(btn))
	refreshStroke()
	freeCamButton = hit
	if hit:GetAttribute("_OceanTD_FreeCamBound") ~= true then
		hit:SetAttribute("_OceanTD_FreeCamBound", true)
		hit.Activated:Connect(function()
			toggle()
		end)
	end
end

local function isGamepadMode(): boolean
	local last = UserInputService:GetLastInputType()
	return last == Enum.UserInputType.Gamepad1
		or last == Enum.UserInputType.Gamepad2
		or last == Enum.UserInputType.Gamepad3
		or last == Enum.UserInputType.Gamepad4
end

local function syncDPadIcon()
	if not dPadIcon or not dPadIconScale then
		return
	end
	-- Decorative dPad graphic: visible whenever backpack is closed (all input types).
	-- Hide while skills bubbles own the screen (avoids a second white center dot).
	local skillsOpen = playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true
	local want = not InventoryState.isOpen() and not skillsOpen
	if want == dPadIconShown then
		return
	end
	dPadIconShown = want
	if dPadIconTween then
		dPadIconTween:Cancel()
		dPadIconTween = nil
	end
	dPadIcon.Visible = true
	local goal = if want then 1 else 0
	local info = if want then ICON_SCALE_IN else ICON_SCALE_OUT
	local tw = TweenService:Create(dPadIconScale, info, { Scale = goal })
	dPadIconTween = tw
	tw:Play()
	if not want then
		tw.Completed:Once(function()
			if not dPadIconShown and dPadIcon then
				dPadIcon.Visible = false
			end
		end)
	end
end

local function wireDPadIcon(icon: GuiObject)
	dPadIcon = icon
	-- UIScale pivots from AnchorPoint — center so it grows/shrinks in place.
	if icon:GetAttribute("_OceanTD_DPadIconCentered") ~= true then
		local ap = icon.AnchorPoint
		local pos = icon.Position
		local size = icon.Size
		-- Convert top-left (or current) pivot to center without shifting the visual center.
		local centerX = pos.X + UDim.new(size.X.Scale * (0.5 - ap.X), size.X.Offset * (0.5 - ap.X))
		local centerY = pos.Y + UDim.new(size.Y.Scale * (0.5 - ap.Y), size.Y.Offset * (0.5 - ap.Y))
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.new(centerX.Scale, centerX.Offset, centerY.Scale, centerY.Offset)
		icon:SetAttribute("_OceanTD_DPadIconCentered", true)
	end
	local existing = icon:FindFirstChildOfClass("UIScale")
	if existing then
		dPadIconScale = existing
	else
		local s = Instance.new("UIScale")
		s.Name = "_OceanTD_DPadIconScale"
		s.Parent = icon
		dPadIconScale = s
	end
	dPadIconShown = false
	syncDPadIcon()
end

task.spawn(function()
	local left = playerGui:WaitForChild("MobileLeftUI", 60)
	if not left then
		warn("[FreeCam] PlayerGui.MobileLeftUI missing")
		return
	end
	local dPad = left:WaitForChild("dPad", 30)
	if not dPad then
		warn("[FreeCam] MobileLeftUI.dPad missing")
		return
	end
	local btn = dPad:WaitForChild("FreeCam", 30)
	if not btn or not btn:IsA("GuiObject") then
		warn("[FreeCam] MobileLeftUI.dPad.FreeCam missing")
		return
	end
	wireButton(btn)

	local icon = dPad:FindFirstChild("dPadIcon")
	if icon and icon:IsA("GuiObject") then
		wireDPadIcon(icon)
	else
		warn("[FreeCam] MobileLeftUI.dPad.dPadIcon missing")
	end

	InventoryState.onOpenChanged(function()
		syncDPadIcon()
	end)
	UserInputService.LastInputTypeChanged:Connect(function()
		syncDPadIcon()
	end)
	playerGui:GetAttributeChangedSignal("OceanTD_SkillsBubblesOpen"):Connect(function()
		syncDPadIcon()
	end)

	print("[FreeCam] Ready — plot SkyCam + SkyCamFocus look-at")
end)
