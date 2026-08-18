--!strict
--[[
	Cam cycle (FreeCam button / DPadDown):
	  1) FreeCam  — fly inside plot SkyCam volume, always looking at SkyCamFocus
	  2) FishCam  — waves on: focus lead hungry fish; waves off: free-look drone
	  3) Off      — Roblox default / game start camera

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
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local Wave1FishCam = require(script.Parent:WaitForChild("Wave1FishCam"))

local RED = Color3.fromRGB(255, 40, 40)
local GREEN = Color3.fromRGB(40, 255, 70)
local FISH_CYAN = Color3.fromRGB(40, 200, 220)
local STROKE_NAME = "_OceanTD_FreeCamStroke"
local STROKE_THICK = 3
local MOVE_SPEED = 48 * 1.3 -- +30%
local TOUCH_STICK_RADIUS = 90
local SINK_ACTION = "OceanTD_FreeCamSink"
local DPAD_ACTION = "OceanTD_FreeCamDPad"
local MARGIN = 0.75
local SKY_CAM_NAME = "SkyCam"
local SKY_FOCUS_NAME = "SkyCamFocus"
local FISH_DAMP_RATE = 0.95 -- same-fish damper; filters path twitches
local FISH_CAM_RATE = 1.7 -- camera body follow (slower than look-at focus)
local FISH_SWITCH_SEC = 3.5
local FISH_CHASE_DIST = 31.2 -- 20% farther than 26 at closest
local FISH_CHASE_HEIGHT = 12
local FISH_ORBIT_SEC = 120 -- full circle at closest distance
local FISH_DIST_BREATHE_SEC = 60 -- 1x → 5x → 1x chase distance
local FISH_DIST_BREATHE_MAX = 2.5 -- peak distance multiplier (was 5; half as far)
local FISH_ORBIT_SLOW_MAX = 3 -- orbit up to this many times slower at max distance
local LOOK_SENS_MOUSE = 0.006
local LOOK_SENS_STICK = 2.4
local LOOK_SENS_TOUCH = 0.008
local LOOK_SENS_KEYS = 1.8
local ATTR_MODE = "OceanTD_CamCycleMode"

type CamMode = "off" | "freecam" | "fishcam"

local mode: CamMode = "off"
local camPos = Vector3.zero
local lookYaw = 0
local lookPitch = 0
local savedCameraType: Enum.CameraType? = nil
local savedWalkSpeed = 16
local savedJumpPower = 50
local savedJumpHeight = 7.2
local renderConn: RBXScriptConnection? = nil
local btnStroke: UIStroke? = nil -- legacy; strokes live on each mode icon
local freeCamButton: GuiButton? = nil -- any-hit fallback; prefer camIcons
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
local REVOLVE_INFO = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local EXPAND_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local COLLAPSE_WAIT_SEC = 2
local ACTIVE_SCALE = 1
local NEXT_SCALE = 0.82
local NEXT_NEXT_SCALE = 0.72
local COLLAPSED_SCALE = 0.08

type ModeIcon = {
	mode: CamMode,
	root: GuiObject,
	hit: GuiButton,
	stroke: UIStroke,
	scale: UIScale,
	brand: Color3,
}

local camIcons: { ModeIcon } = {}
local slotPos = {
	active = UDim2.fromScale(0.5, 0.2),
	next = UDim2.fromScale(0.28, 0.72),
	nextNext = UDim2.fromScale(0.72, 0.72),
}
local carouselToken = 0
local carouselReady = false
local carouselCollapsed = false

local moveTouch: InputObject? = nil
local moveOrigin = Vector2.zero
local touchMoveVec = Vector2.zero -- -1..1
local lookTouch: InputObject? = nil
local lookTouchLast = Vector2.zero
local mouseLookLast: Vector2? = nil
local touchDownCount = 0

local keysDown: { [Enum.KeyCode]: boolean } = {}
local moveStick = Vector2.zero
local lookStick = Vector2.zero

local cachedSkyCam: BasePart? = nil
local cachedFocus: BasePart? = nil
local cachedPlotId: string? = nil

-- FishCam follow (waves on)
local fishTargetId: number? = nil
local fishFocusPos = Vector3.zero
local fishDampPos = Vector3.zero
local fishSwitchFrom = Vector3.zero
local fishSwitchTo = Vector3.zero
local fishSwitchT0 = 0
local fishSwitching = false
local lastFishWavesOn = false
local fishOrbitT0 = 0
local fishOrbitAngle = 0
local fishOrbitElev = 0 -- extra elevation around the fish (user orbit steer)

local function getCamera(): Camera?
	return Workspace.CurrentCamera
end

local function publishMode()
	playerGui:SetAttribute(ATTR_MODE, mode)
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

local function droneLookCFrame(): CFrame
	return CFrame.new(camPos) * CFrame.Angles(0, lookYaw, 0) * CFrame.Angles(lookPitch, 0, 0)
end

local function syncLookFromCFrame(cf: CFrame)
	local look = cf.LookVector
	lookYaw = math.atan2(-look.X, -look.Z)
	lookPitch = math.asin(math.clamp(look.Y, -1, 1))
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

local function modeBrand(m: CamMode): Color3
	if m == "freecam" then
		return GREEN
	elseif m == "fishcam" then
		return FISH_CYAN
	end
	return RED
end

local function nextCamMode(m: CamMode): CamMode
	if m == "off" then
		return "freecam"
	elseif m == "freecam" then
		return "fishcam"
	end
	return "off"
end

local function slotForIconMode(iconMode: CamMode, relativeTo: CamMode): (string, number, number)
	if iconMode == relativeTo then
		return "active", ACTIVE_SCALE, 30
	elseif iconMode == nextCamMode(relativeTo) then
		return "next", NEXT_SCALE, 20
	end
	return "nextNext", NEXT_NEXT_SCALE, 10
end

local function iconSlotGoals(iconMode: CamMode, relativeTo: CamMode, collapsed: boolean): (UDim2, number, number)
	local slotName, scaleGoal, z = slotForIconMode(iconMode, relativeTo)
	local posGoal = if slotName == "active"
		then slotPos.active
		elseif slotName == "next" then slotPos.next
		else slotPos.nextNext
	if collapsed and slotName ~= "active" then
		return slotPos.active, COLLAPSED_SCALE, z
	end
	return posGoal, scaleGoal, z
end

local function applyIconChrome(icon: ModeIcon, relativeTo: CamMode, collapsed: boolean)
	local isActive = icon.mode == relativeTo
	icon.root.Visible = true
	icon.stroke.Enabled = true
	icon.stroke.Thickness = if isActive then STROKE_THICK + 1 else STROKE_THICK
	icon.stroke.Color = if isActive then GREEN else RED
	icon.stroke.Transparency = 0
	icon.root.Rotation = 0
end

local function tweenIconsToLayout(relativeTo: CamMode, collapsed: boolean, info: TweenInfo, token: number, onDone: (() -> ())?)
	local remaining = #camIcons
	local function oneDone()
		remaining -= 1
		if remaining <= 0 and token == carouselToken and onDone then
			onDone()
		end
	end
	for _, icon in ipairs(camIcons) do
		local posGoal, scaleGoal, z = iconSlotGoals(icon.mode, relativeTo, collapsed)
		applyIconChrome(icon, relativeTo, collapsed)
		icon.root.ZIndex = z
		icon.hit.ZIndex = z + 1
		local twPos = TweenService:Create(icon.root, info, { Position = posGoal })
		local twScale = TweenService:Create(icon.scale, info, { Scale = scaleGoal })
		twPos:Play()
		twScale:Play()
		twPos.Completed:Once(function()
			oneDone()
		end)
	end
end

local function snapIconsToLayout(relativeTo: CamMode, collapsed: boolean)
	for _, icon in ipairs(camIcons) do
		local posGoal, scaleGoal, z = iconSlotGoals(icon.mode, relativeTo, collapsed)
		applyIconChrome(icon, relativeTo, collapsed)
		icon.root.ZIndex = z
		icon.hit.ZIndex = z + 1
		icon.root.Position = posGoal
		icon.scale.Scale = scaleGoal
		icon.root.Rotation = 0
	end
end

local function scheduleCollapse(token: number, relativeTo: CamMode)
	task.delay(COLLAPSE_WAIT_SEC, function()
		if token ~= carouselToken or not carouselReady then
			return
		end
		carouselCollapsed = true
		tweenIconsToLayout(relativeTo, true, COLLAPSE_INFO, token, nil)
	end)
end

local function playCamCarousel(fromMode: CamMode, toMode: CamMode, animate: boolean)
	if not carouselReady or #camIcons == 0 then
		return
	end
	carouselToken += 1
	local my = carouselToken

	if not animate or fromMode == toMode then
		snapIconsToLayout(toMode, false)
		carouselCollapsed = false
		scheduleCollapse(my, toMode)
		return
	end

	local function revolveThenCollapse()
		if my ~= carouselToken then
			return
		end
		carouselCollapsed = false
		tweenIconsToLayout(toMode, false, REVOLVE_INFO, my, function()
			if my ~= carouselToken then
				return
			end
			scheduleCollapse(my, toMode)
		end)
	end

	if carouselCollapsed then
		-- Pop the tucked icons back to the previous triangle, then revolve.
		tweenIconsToLayout(fromMode, false, EXPAND_INFO, my, revolveThenCollapse)
	else
		revolveThenCollapse()
	end
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
	-- Sink locomotion so the avatar cannot walk while cam cycle owns the view.
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

local function isOverCamCycleButton(screenPos: Vector3): boolean
	local x, y = screenPos.X, screenPos.Y
	for _, icon in ipairs(camIcons) do
		local p = icon.root.AbsolutePosition
		local s = icon.root.AbsoluteSize
		if x >= p.X and x <= p.X + s.X and y >= p.Y and y <= p.Y + s.Y then
			return true
		end
	end
	local btn = freeCamButton
	if not btn then
		return false
	end
	local p = btn.AbsolutePosition
	local s = btn.AbsoluteSize
	return x >= p.X and x <= p.X + s.X and y >= p.Y and y <= p.Y + s.Y
end

local function clearTouchMove()
	moveTouch = nil
	touchMoveVec = Vector2.zero
	moveOrigin = Vector2.zero
end

local function clearTouchLook()
	lookTouch = nil
	lookTouchLast = Vector2.zero
end

local function isFishDroneLook(): boolean
	return mode == "fishcam" and not WaveSim.isRunning()
end

local function isFishCamLook(): boolean
	return mode == "fishcam"
end

local function isMouseLookHeld(): boolean
	-- Touch is emulated as MouseButton1; GetMouseLocation jumps during touch and fights look.
	if touchDownCount > 0 then
		return false
	end
	return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
		or UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
end

local function isUserSteeringOrbit(): boolean
	if isMouseLookHeld() then
		return true
	end
	if lookStick.Magnitude > 0.12 then
		return true
	end
	if lookTouch ~= nil then
		return true
	end
	return keysDown[Enum.KeyCode.Left] == true
		or keysDown[Enum.KeyCode.Right] == true
		or keysDown[Enum.KeyCode.Up] == true
		or keysDown[Enum.KeyCode.Down] == true
end

local function mouseScreenPos(): Vector2
	return UserInputService:GetMouseLocation()
end

local function setDroneLookCapture(_on: boolean)
	-- Mouse/keyboard: free cursor; look only while a mouse button is held.
	pcall(function()
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end)
end

local function readDroneMoveWish(cf: CFrame): Vector3
	local wish = Vector3.zero
	local look = cf.LookVector
	local right = cf.RightVector
	if look.Magnitude > 1e-4 then
		look = look.Unit
	else
		look = Vector3.new(0, 0, -1)
	end
	if right.Magnitude > 1e-4 then
		right = right.Unit
	else
		right = Vector3.new(1, 0, 0)
	end

	-- Fly along camera axes so FishCam is not stuck on FreeCam's flat plane.
	if touchMoveVec.Magnitude > 0.08 then
		wish += look * -touchMoveVec.Y + right * touchMoveVec.X
	end

	if keysDown[Enum.KeyCode.W] then
		wish += look
	end
	if keysDown[Enum.KeyCode.S] then
		wish -= look
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

	if moveStick.Magnitude > 0.12 then
		wish += look * moveStick.Y + right * moveStick.X
	end

	if wish.Magnitude > 1e-4 then
		return wish.Unit
	end
	return Vector3.zero
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

local function beginFishSwitch(toPos: Vector3)
	fishSwitchFrom = fishFocusPos
	fishSwitchTo = toPos
	fishSwitchT0 = os.clock()
	fishSwitching = true
end

local function resetFishOrbitClock()
	fishOrbitT0 = os.clock()
	local flat = Vector3.new(camPos.X - fishFocusPos.X, 0, camPos.Z - fishFocusPos.Z)
	if flat.Magnitude > 0.1 then
		fishOrbitAngle = math.atan2(flat.Z, flat.X)
	else
		fishOrbitAngle = 0
	end
	fishOrbitElev = 0
end

local function resetFishFollowState(seed: Vector3?)
	fishTargetId = nil
	fishSwitching = false
	fishFocusPos = seed or camPos
	fishDampPos = fishFocusPos
	fishSwitchFrom = fishFocusPos
	fishSwitchTo = fishFocusPos
	resetFishOrbitClock()
end

local function fishDistanceMult(elapsed: number): number
	local breatheU = (elapsed % FISH_DIST_BREATHE_SEC) / FISH_DIST_BREATHE_SEC
	-- Smooth 1 → max → 1 over the breathe period.
	return 1 + (FISH_DIST_BREATHE_MAX - 1) * 0.5 * (1 - math.cos(2 * math.pi * breatheU))
end

local function fishChaseOffset(dt: number): Vector3
	local elapsed = math.max(0, os.clock() - fishOrbitT0)
	local mult = fishDistanceMult(elapsed)
	-- Closer = full orbit speed; at max distance, up to FISH_ORBIT_SLOW_MAX slower.
	local farT = math.clamp((mult - 1) / (FISH_DIST_BREATHE_MAX - 1), 0, 1)
	local slow = 1 + farT * (FISH_ORBIT_SLOW_MAX - 1)
	local radPerSec = (math.pi * 2) / (FISH_ORBIT_SEC * slow)
	-- Pause auto-spin while the player is steering; resume from the new angle after.
	if not isUserSteeringOrbit() then
		fishOrbitAngle -= radPerSec * math.max(dt, 0)
	end
	local dist = FISH_CHASE_DIST * mult
	local height = FISH_CHASE_HEIGHT * mult
	local r = math.sqrt(dist * dist + height * height)
	local baseElev = math.atan2(height, dist)
	local elev = math.clamp(baseElev + fishOrbitElev, 0.12, 1.25)
	local flatLen = r * math.cos(elev)
	local flat = Vector3.new(math.cos(fishOrbitAngle), 0, math.sin(fishOrbitAngle))
	return flat * flatLen + Vector3.new(0, r * math.sin(elev), 0)
end

local function applyLookDelta(dx: number, dy: number)
	-- Ignore one-frame spikes (touch/mouse emulation jumps) that invert the view.
	if math.abs(dx) > 1.2 or math.abs(dy) > 1.2 then
		return
	end
	if mode == "fishcam" and WaveSim.isRunning() then
		-- Steer around the fish; auto orbit continues from this heading.
		fishOrbitAngle -= dx
		fishOrbitElev = math.clamp(fishOrbitElev - dy, -0.7, 0.85)
		return
	end
	lookYaw -= dx
	lookPitch = math.clamp(lookPitch - dy, -1.2, 1.2)
end

local function tickMouseDragLook()
	-- GetMouseDelta is 0 with a free cursor — track screen position instead.
	-- Never mix this with touch: emulated cursor coords fight the finger look.
	if not isFishCamLook() or not isMouseLookHeld() then
		mouseLookLast = nil
		return
	end
	local loc = mouseScreenPos()
	local prev = mouseLookLast
	if prev then
		local d = loc - prev
		if d.Magnitude > 0.5 and d.Magnitude < 180 then
			applyLookDelta(d.X * LOOK_SENS_MOUSE, d.Y * LOOK_SENS_MOUSE)
		end
	end
	mouseLookLast = loc
end

local function tickLookInput(dt: number)
	if lookStick.Magnitude > 0.12 then
		applyLookDelta(lookStick.X * LOOK_SENS_STICK * dt, lookStick.Y * LOOK_SENS_STICK * dt)
	end
	tickMouseDragLook()
	if keysDown[Enum.KeyCode.Left] then
		applyLookDelta(-LOOK_SENS_KEYS * dt, 0)
	end
	if keysDown[Enum.KeyCode.Right] then
		applyLookDelta(LOOK_SENS_KEYS * dt, 0)
	end
	if keysDown[Enum.KeyCode.Up] then
		applyLookDelta(0, -LOOK_SENS_KEYS * dt)
	end
	if keysDown[Enum.KeyCode.Down] then
		applyLookDelta(0, LOOK_SENS_KEYS * dt)
	end
end

local function moveSpeedForWish(): number
	local speed = MOVE_SPEED
	if keysDown[Enum.KeyCode.LeftShift] then
		speed *= 1.75
	end
	if touchMoveVec.Magnitude > 0.08 then
		speed *= math.clamp(touchMoveVec.Magnitude, 0.08, 1)
	elseif moveStick.Magnitude > 0.08 then
		speed *= math.clamp(moveStick.Magnitude, 0.08, 1)
	end
	return speed
end

local function restoreDefaultCamera()
	stopRender()
	bindSink(false)
	clearTouchMove()
	if controlsDisabled then
		setControlsEnabled(true)
	end
	table.clear(keysDown)
	moveStick = Vector2.zero
	lookStick = Vector2.zero
	mouseLookLast = nil
	clearTouchLook()
	setCharacterLocked(false)
	setDroneLookCapture(false)

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
	playerGui:SetAttribute("OceanTD_RestoreWaveCam", os.clock())
end

local function ensureScriptableFromCurrent()
	local camera = getCamera()
	if not camera then
		return false
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		savedCameraType = camera.CameraType
	elseif not savedCameraType then
		savedCameraType = Enum.CameraType.Custom
	end
	camPos = camera.CFrame.Position
	syncLookFromCFrame(camera.CFrame)
	camera.CameraType = Enum.CameraType.Scriptable
	return true
end

local function lockAvatarForMode()
	setCharacterLocked(true)
	bindSink(true)
	clearTouchMove()
	setControlsEnabled(false)
end

local setMode: (CamMode) -> ()

local function tickFreeCam(dt: number)
	local cam = getCamera()
	local box, focusPart = resolveSkyParts()
	if not cam or not box or not focusPart then
		setMode("off")
		return
	end
	keepCharacterStill()
	local cf = lookAtFocus(focusPart.Position)
	local wish = readMoveWish(cf)
	camPos = clampToSkyCam(camPos + wish * moveSpeedForWish() * dt, box)
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = lookAtFocus(focusPart.Position)
end

local function tickFishFollow(dt: number)
	local cam = getCamera()
	if not cam then
		setMode("off")
		return
	end
	keepCharacterStill()
	tickLookInput(dt)

	local fish = WaveSim.getFurthestUnfedFish()
	local goal: Vector3
	if fish then
		goal = fish.position
		if fishTargetId ~= fish.id then
			fishTargetId = fish.id
			beginFishSwitch(goal)
		elseif fishSwitching then
			fishSwitchTo = goal
		end
	else
		-- Last hungry just fed: stay on them until the next wave's fish spawn.
		local held = if fishTargetId then WaveSim.getFishPosition(fishTargetId) else nil
		if held then
			goal = held
			if fishSwitching then
				fishSwitchTo = goal
			end
		else
			goal = fishFocusPos
		end
	end

	-- Damp the live fish pose so path jerks don't snap the camera.
	local dampA = 1 - math.exp(-FISH_DAMP_RATE * math.max(dt, 0))
	fishDampPos = fishDampPos:Lerp(goal, dampA)

	if fishSwitching then
		local u = math.clamp((os.clock() - fishSwitchT0) / FISH_SWITCH_SEC, 0, 1)
		local e = u * u * (3 - 2 * u)
		fishSwitchTo = fishDampPos
		fishFocusPos = fishSwitchFrom:Lerp(fishSwitchTo, e)
		if u >= 1 then
			fishSwitching = false
			fishFocusPos = fishDampPos
		end
	else
		fishFocusPos = fishDampPos
	end

	-- Slow orbit + extra camera-body damper so look stays stable.
	local desired = fishFocusPos + fishChaseOffset(dt)
	local aCam = 1 - math.exp(-FISH_CAM_RATE * math.max(dt, 0))
	camPos = camPos:Lerp(desired, aCam)
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = lookAtFocus(fishFocusPos)
	syncLookFromCFrame(cam.CFrame)
end

local function tickFishDrone(dt: number)
	local cam = getCamera()
	if not cam then
		setMode("off")
		return
	end
	keepCharacterStill()
	setDroneLookCapture(true)
	tickLookInput(dt)
	local cf = droneLookCFrame()
	local wish = readDroneMoveWish(cf)
	camPos += wish * moveSpeedForWish() * dt
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = droneLookCFrame()
end

local function startRenderLoop()
	stopRender()
	renderConn = RunService.RenderStepped:Connect(function(dt)
		if mode == "off" then
			return
		end
		if playerGui:GetAttribute("OceanTD_PlotSizeCinematicBusy") == true then
			return
		end
		if PlacementController.isActive() or RelocateController.isActive() then
			setMode("off")
			return
		end

		if mode == "freecam" then
			setDroneLookCapture(false)
			tickFreeCam(dt)
			return
		end

		-- FishCam: waves → lead hungry fish; idle → free-look drone.
		local wavesOn = WaveSim.isRunning()
		if wavesOn ~= lastFishWavesOn then
			if wavesOn then
				resetFishFollowState(camPos)
				setDroneLookCapture(false)
			else
				local cam = getCamera()
				if cam then
					syncLookFromCFrame(cam.CFrame)
				end
			end
			lastFishWavesOn = wavesOn
		end
		if wavesOn then
			setDroneLookCapture(false)
			tickFishFollow(dt)
		else
			tickFishDrone(dt)
		end
	end)
end

setMode = function(nextMode: CamMode)
	if nextMode == mode then
		return
	end
	if nextMode ~= "off" then
		if playerGui:GetAttribute("OceanTD_PlotSizeCinematicBusy") == true then
			return
		end
		if PlacementController.isActive() or RelocateController.isActive() then
			return
		end
		if nextMode == "freecam" then
			local sky, focus = resolveSkyParts()
			if not sky or not focus then
				warn("[FreeCam] SkyCam / SkyCamFocus missing for local plot — freecam unavailable")
				return
			end
		end
		if not getCamera() then
			return
		end
	end

	local prev = mode
	mode = nextMode
	publishMode()
	playCamCarousel(prev, nextMode, true)

	if nextMode == "off" then
		restoreDefaultCamera()
		return
	end

	-- Entering / switching into an override mode.
	Wave1FishCam.stopImmediate()
	if prev == "off" then
		if not ensureScriptableFromCurrent() then
			mode = "off"
			publishMode()
			playCamCarousel(nextMode, "off", false)
			return
		end
		if nextMode == "freecam" then
			local sky = resolveSkyParts()
			if sky then
				camPos = clampToSkyCam(camPos, sky)
			end
		end
		lockAvatarForMode()
	end

	if nextMode == "freecam" then
		local sky, focus = resolveSkyParts()
		local cam = getCamera()
		if sky and focus and cam then
			camPos = clampToSkyCam(camPos, sky)
			cam.CameraType = Enum.CameraType.Scriptable
			cam.CFrame = lookAtFocus(focus.Position)
		end
	elseif nextMode == "fishcam" then
		lastFishWavesOn = WaveSim.isRunning()
		resetFishFollowState(camPos)
		local cam = getCamera()
		if cam then
			cam.CameraType = Enum.CameraType.Scriptable
			if WaveSim.isRunning() then
				local fish = WaveSim.getFurthestUnfedFish()
				if fish then
					fishFocusPos = fish.position
					fishDampPos = fish.position
					fishTargetId = fish.id
					camPos = fish.position + fishChaseOffset(0)
					cam.CFrame = lookAtFocus(fishFocusPos)
					syncLookFromCFrame(cam.CFrame)
				else
					syncLookFromCFrame(cam.CFrame)
					cam.CFrame = droneLookCFrame()
				end
			else
				syncLookFromCFrame(cam.CFrame)
				cam.CFrame = droneLookCFrame()
				setDroneLookCapture(true)
			end
		end
	end

	startRenderLoop()
end

local function cycleMode()
	if mode == "off" then
		setMode("freecam")
	elseif mode == "freecam" then
		setMode("fishcam")
	else
		setMode("off")
	end
end

-- D-pad Down cycles cam modes while backpack / build UI is closed.
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
	cycleMode()
	return Enum.ContextActionResult.Sink
end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.DPadDown)

local function isDPadKey(code: Enum.KeyCode): boolean
	return code == Enum.KeyCode.DPadLeft
		or code == Enum.KeyCode.DPadRight
		or code == Enum.KeyCode.DPadUp
		or code == Enum.KeyCode.DPadDown
end

local function skillsBubblesOpen(): boolean
	return playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true
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

UserInputService.InputBegan:Connect(function(input, _gameProcessed)
	if input.UserInputType == Enum.UserInputType.Touch then
		touchDownCount += 1
	end
	if isDPadKey(input.KeyCode) then
		if not skillsBubblesOpen() then
			flashDPadGlow()
		end
	end
	if input.UserInputType == Enum.UserInputType.Keyboard then
		if mode ~= "off" then
			keysDown[input.KeyCode] = true
		end
		return
	end
	if mode == "off" then
		return
	end
	if isFishCamLook()
		and (
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.MouseButton2
		)
	then
		if touchDownCount == 0 and not isOverCamCycleButton(input.Position) then
			mouseLookLast = mouseScreenPos()
		end
		return
	end
	if input.UserInputType == Enum.UserInputType.Touch then
		if isOverCamCycleButton(input.Position) then
			return
		end
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		if isFishCamLook() then
			local cam = getCamera()
			local viewW = if cam then cam.ViewportSize.X else 0
			local rightSide = viewW > 0 and pos.X > viewW * 0.55
			-- Right-side / second finger looks; left-side / first finger moves.
			if lookTouch == nil and (moveTouch ~= nil or rightSide) then
				lookTouch = input
				lookTouchLast = pos
				return
			end
		end
		if moveTouch == nil then
			moveTouch = input
			moveOrigin = pos
			touchMoveVec = Vector2.zero
		end
	end
end)

UserInputService.InputChanged:Connect(function(input, _gameProcessed)
	if mode == "off" then
		return
	end
	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		moveStick = Vector2.new(input.Position.X, input.Position.Y)
		return
	end
	if input.KeyCode == Enum.KeyCode.Thumbstick2 then
		lookStick = Vector2.new(input.Position.X, input.Position.Y)
		return
	end
	if input.UserInputType == Enum.UserInputType.Touch then
		if input == lookTouch then
			local pos = Vector2.new(input.Position.X, input.Position.Y)
			local delta = pos - lookTouchLast
			lookTouchLast = pos
			if delta.Magnitude < 180 then
				applyLookDelta(delta.X * LOOK_SENS_TOUCH, delta.Y * LOOK_SENS_TOUCH)
			end
			return
		end
		if input == moveTouch then
			touchMoveVec = stickFromOrigin(moveOrigin, Vector2.new(input.Position.X, input.Position.Y))
		end
	end
end)

UserInputService.InputEnded:Connect(function(input, _gameProcessed)
	if input.UserInputType == Enum.UserInputType.Touch then
		touchDownCount = math.max(0, touchDownCount - 1)
	end
	if input.UserInputType == Enum.UserInputType.Keyboard then
		keysDown[input.KeyCode] = nil
	end
	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		moveStick = Vector2.zero
	end
	if input.KeyCode == Enum.KeyCode.Thumbstick2 then
		lookStick = Vector2.zero
	end
	if input == lookTouch then
		clearTouchLook()
	end
	if input == moveTouch then
		clearTouchMove()
	end
end)

player.CharacterAdded:Connect(function()
	if mode ~= "off" then
		task.defer(function()
			setCharacterLocked(true)
		end)
	end
end)

ClientPlot.onChanged(function()
	cachedSkyCam = nil
	cachedFocus = nil
	cachedPlotId = nil
	if mode == "freecam" then
		local sky, focus = resolveSkyParts()
		if not sky or not focus then
			setMode("off")
		else
			camPos = clampToSkyCam(camPos, sky)
		end
	end
end)

local function ensureHitButton(btn: GuiObject): GuiButton
	if btn:IsA("GuiButton") then
		return btn
	end
	local existing = btn:FindFirstChildWhichIsA("GuiButton", true)
	if existing then
		return existing
	end
	local made = Instance.new("TextButton")
	made.Name = "_OceanTD_CamCycleHit"
	made.Text = ""
	made.BackgroundTransparency = 1
	made.Size = UDim2.fromScale(1, 1)
	made.ZIndex = 100
	made.Parent = btn
	return made
end

local function ensureIconScale(gui: GuiObject): UIScale
	local existing = gui:FindFirstChildOfClass("UIScale")
	if existing then
		return existing
	end
	local s = Instance.new("UIScale")
	s.Name = "_OceanTD_CamIconScale"
	s.Scale = 1
	s.Parent = gui
	return s
end

local function centerGuiPivot(gui: GuiObject)
	if gui:GetAttribute("_OceanTD_CamIconCentered") == true then
		return
	end
	local ap = gui.AnchorPoint
	local pos = gui.Position
	local size = gui.Size
	local centerX = pos.X + UDim.new(size.X.Scale * (0.5 - ap.X), size.X.Offset * (0.5 - ap.X))
	local centerY = pos.Y + UDim.new(size.Y.Scale * (0.5 - ap.Y), size.Y.Offset * (0.5 - ap.Y))
	gui.AnchorPoint = Vector2.new(0.5, 0.5)
	gui.Position = UDim2.new(centerX.Scale, centerX.Offset, centerY.Scale, centerY.Offset)
	gui:SetAttribute("_OceanTD_CamIconCentered", true)
end

local function wireModeIcon(btn: GuiObject, camMode: CamMode)
	centerGuiPivot(btn)
	local hit = ensureHitButton(btn)
	local stroke = ensureStroke(strokeTarget(btn))
	local scale = ensureIconScale(btn)
	btn.Visible = true
	table.insert(camIcons, {
		mode = camMode,
		root = btn,
		hit = hit,
		stroke = stroke,
		scale = scale,
		brand = modeBrand(camMode),
	})
	if hit:GetAttribute("_OceanTD_CamCycleBound") ~= true then
		hit:SetAttribute("_OceanTD_CamCycleBound", true)
		hit.Activated:Connect(function()
			cycleMode()
		end)
	end
	if camMode == "freecam" then
		freeCamButton = hit
		btnStroke = stroke
	end
end

local function wireCamCarousel(dPad: Instance)
	table.clear(camIcons)
	carouselReady = false
	local freeGui = dPad:FindFirstChild("FreeCam")
	local fishGui = dPad:FindFirstChild("FishCam")
	local offGui = dPad:FindFirstChild("OffCam")
	if not (freeGui and freeGui:IsA("GuiObject")) then
		warn("[FreeCam] MobileLeftUI.dPad.FreeCam missing")
		return
	end
	if not (fishGui and fishGui:IsA("GuiObject")) then
		warn("[FreeCam] MobileLeftUI.dPad.FishCam missing")
		return
	end
	if not (offGui and offGui:IsA("GuiObject")) then
		warn("[FreeCam] MobileLeftUI.dPad.OffCam missing")
		return
	end

	-- Authored triangle: FreeCam = active (top), FishCam = next (BL), OffCam = next-next (BR).
	centerGuiPivot(freeGui)
	centerGuiPivot(fishGui)
	centerGuiPivot(offGui)
	slotPos.active = freeGui.Position
	slotPos.next = fishGui.Position
	slotPos.nextNext = offGui.Position

	wireModeIcon(freeGui, "freecam")
	wireModeIcon(fishGui, "fishcam")
	wireModeIcon(offGui, "off")
	carouselReady = true
	-- Default Off: OffCam on top, FreeCam next, FishCam next-next.
	playCamCarousel("off", "off", false)
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

publishMode()

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
	wireCamCarousel(dPad)

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

	playerGui:GetAttributeChangedSignal("OceanTD_ForceCloseFreeCam"):Connect(function()
		if mode ~= "off" then
			setMode("off")
		end
	end)

	print("[FreeCam] Ready — cycle FreeCam → FishCam → Off (DPadDown + triangle icons)")
end)
