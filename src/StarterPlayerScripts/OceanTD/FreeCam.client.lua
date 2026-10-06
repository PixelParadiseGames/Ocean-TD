--!strict
--[[
	Cam cycle (DPadDown / revolver icons):
	  Off → PlotCam → FishCam → DroneCam → Off

	  Off       — Roblox default / player follow cam
	  PlotCam   — Plot Cam 2 by default (locked RTS / isometric over plot).
	                FreeCamConfig.PLOT_CAM_VARIANT = 1 restores Plot Cam 1
	                (SkyCam volume free-fly → SkyCamFocus).
	  FishCam   — always orbit furthest unfed fish; if none during waves, orbit W1;
	                idle (no waves): orbit while focus patrols W1→W2→…→Wn then reverses
	  DroneCam  — free-look fly (old FishCam-idle). Studio instance stays named FreeCam.
	                Attr value is "dronecam" (say "drone" if you mean this; "freecam" = old PlotCam).

	Plot1: Workspace.MasterPlotDecor.SkyCam (+ .SkyCamFocus)
	PlotN: Workspace.StaticPlot_N.SkyCam (cloned by DecorReplicator)
	Fish idle focus: Workspace.WaveRoute.A.Waypoints.W1..Wn (remapped per plot)
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local Wave1FishCam = require(script.Parent:WaitForChild("Wave1FishCam"))
local SkyCamParts = require(script.Parent:WaitForChild("SkyCamParts"))
local FC = require(script.Parent:WaitForChild("FreeCamConfig"))
local FreeCamModeLabel = require(script.Parent:WaitForChild("FreeCamModeLabel"))
local PlotCam2 = require(script.Parent:WaitForChild("PlotCam2"))
local PlotCam2Tune = require(script.Parent:WaitForChild("PlotCam2Tune"))

playerGui:SetAttribute(FC.ATTR_CAROUSEL_COLLAPSED, false)

-- Studio FreeCam button = DroneCam mode. PlotCam = Plot Cam 1 or 2 via PLOT_CAM_VARIANT.
type CamMode = FC.CamMode

local mode: CamMode = "off"
-- Enter Plot Cam once as the default seat (cleared after first successful enter / any non-off mode).
local startPlotCamPending = true
-- FishCam/PlotCam/DroneCam to restore after defeat / wave intro cinematics / build mode.
local cinematicResumeMode: CamMode? = nil
local buildResumeMode: CamMode? = nil
local resumePreserveView = false
local camPos = Vector3.zero
local lookYaw = 0
local lookPitch = 0
local savedCameraType: Enum.CameraType? = nil
local savedWalkSpeed = 16
local savedJumpPower = 75
local savedJumpHeight = 10.8
local renderConn: RBXScriptConnection? = nil
local btnStroke: UIStroke? = nil -- legacy; strokes live on each mode icon
local freeCamButton: GuiButton? = nil -- any-hit fallback; prefer camIcons
local dPadIcon: GuiObject? = nil
local dPadIconScale: UIScale? = nil
local dPadIconShown = false
local dPadIconTween: Tween? = nil
local dPadGlowToken = 0
local controlsDisabled = false

type ModeIcon = FreeCamModeLabel.ModeIcon

local camIcons: { ModeIcon } = {}
-- 1 top (active), 2 left (next), 3 bottom, 4 right (last) â€” Positions read from Studio.
local slotPos = {
	active = UDim2.fromScale(0.5, 0.2),
	next = UDim2.fromScale(0.28, 0.72),
	bottom = UDim2.fromScale(0.5, 0.88),
	last = UDim2.fromScale(0.72, 0.72),
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
local cachedSkyPose: SkyCamParts.SkyPose? = nil

-- FishCam follow + idle route patrol (packed to save registers).
local fishSt = {
	targetId = nil :: number?,
	focusPos = Vector3.zero,
	dampPos = Vector3.zero,
	switchFrom = Vector3.zero,
	switchTo = Vector3.zero,
	switchT0 = 0,
	switching = false,
	orbitT0 = 0,
	orbitAngle = 0,
	orbitElev = 0,
}
local route = {
	waypoints = {} :: { Vector3 },
	segIndex = 1,
	segAlpha = 0,
	patrolDir = 1,
}

local function getCamera(): Camera?
	return Workspace.CurrentCamera
end

local function publishMode()
	playerGui:SetAttribute(FC.ATTR_MODE, mode)
end

local function clearSkyCache()
	cachedSkyCam = nil
	cachedFocus = nil
	cachedPlotId = nil
	cachedSkyPose = nil
end

local function resolveSkyParts(): (BasePart?, BasePart?)
	local mirrored = ClientPlot.get()
	local plotId = if mirrored then mirrored.plotId else nil
	if plotId and cachedPlotId == plotId and cachedSkyCam and cachedSkyCam.Parent and cachedFocus and cachedFocus.Parent then
		return cachedSkyCam, cachedFocus
	end
	clearSkyCache()
	cachedPlotId = plotId

	local sky, focus = SkyCamParts.findLocalParts()
	if sky and focus then
		cachedSkyCam = sky
		cachedFocus = focus
		cachedSkyPose = {
			skyCFrame = sky.CFrame,
			skySize = sky.Size,
			focusPos = focus.Position,
			skyPart = sky,
			focusPart = focus,
		}
		return cachedSkyCam, cachedFocus
	end
	return nil, nil
end

-- Prefer live parts; else remapped MasterPlotDecor pose (StaticPlot late / missing SkyCam).
local function resolveSkyPose(): SkyCamParts.SkyPose?
	local sky, focus = resolveSkyParts()
	if sky and focus and cachedSkyPose then
		-- Refresh live CFrames each call when parts exist.
		cachedSkyPose = {
			skyCFrame = sky.CFrame,
			skySize = sky.Size,
			focusPos = focus.Position,
			skyPart = sky,
			focusPart = focus,
		}
		return cachedSkyPose
	end
	local pose = SkyCamParts.resolvePose()
	cachedSkyPose = pose
	return pose
end

local function clampToSkyPose(pos: Vector3, pose: SkyCamParts.SkyPose): Vector3
	return SkyCamParts.clampToPose(pos, pose, FC.MARGIN)
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
	local existing = gui:FindFirstChild(FC.STROKE_NAME)
	if existing and existing:IsA("UIStroke") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local s = Instance.new("UIStroke")
	s.Name = FC.STROKE_NAME
	s.Thickness = FC.STROKE_THICK
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
	if m == "plotcam" then
		return FC.GREEN
	elseif m == "fishcam" then
		return FC.FISH_CYAN
	elseif m == "dronecam" then
		return FC.DRONE_AMBER
	end
	return FC.RED
end

local function modeIndex(m: CamMode): number
	for i, name in ipairs(FC.MODE_ORDER) do
		if name == m then
			return i
		end
	end
	return 1
end

local function nextCamMode(m: CamMode): CamMode
	local i = modeIndex(m)
	return FC.MODE_ORDER[(i % #FC.MODE_ORDER) + 1]
end

local function slotForIconMode(iconMode: CamMode, relativeTo: CamMode): (string, number, number)
	if iconMode == relativeTo then
		return "active", FC.ACTIVE_SCALE, 40
	end
	local n1 = nextCamMode(relativeTo)
	if iconMode == n1 then
		return "next", FC.NEXT_SCALE, 30
	end
	local n2 = nextCamMode(n1)
	if iconMode == n2 then
		return "bottom", FC.BOTTOM_SCALE, 20
	end
	return "last", FC.LAST_SCALE, 10
end

local function iconSlotGoals(iconMode: CamMode, relativeTo: CamMode, collapsed: boolean): (UDim2, number, number)
	local slotName, scaleGoal, z = slotForIconMode(iconMode, relativeTo)
	local posGoal = if slotName == "active"
		then slotPos.active
		elseif slotName == "next" then slotPos.next
		elseif slotName == "bottom" then slotPos.bottom
		else slotPos.last
	if collapsed and slotName ~= "active" then
		return slotPos.active, FC.COLLAPSED_SCALE, z
	end
	return posGoal, scaleGoal, z
end

local function skillsBubblesOpen(): boolean
	return playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true
		or playerGui:GetAttribute("OceanTD_ReefReportOpen") == true
		or playerGui:GetAttribute("OceanTD_StoreOpen") == true
end

-- Skills / backpack own the left HUD â€” never force cam triangle icons back on.
local function camModeIconsSuppressed(): boolean
	return InventoryState.isOpen() or skillsBubblesOpen()
end

local function applyIconChrome(icon: ModeIcon, relativeTo: CamMode, collapsed: boolean)
	local isActive = icon.mode == relativeTo
	-- Collapsed stack: only the front (active) icon should eat clicks / hand cursor.
	local interactive = isActive or not collapsed
	-- Pending carousel collapse used to re-show the active icon after skills hid the dPad.
	if camModeIconsSuppressed() then
		icon.root.Visible = false
		interactive = false
	else
		-- Collapsed = only the active mode circle (normal left HUD). Expanded carousel shows all.
		icon.root.Visible = isActive or not collapsed
	end
	icon.stroke.Enabled = true
	icon.stroke.Thickness = if isActive then FC.STROKE_THICK + 1 else FC.STROKE_THICK
	icon.stroke.Color = if isActive then FC.GREEN else FC.RED
	icon.stroke.Transparency = 0
	icon.root.Rotation = 0
	icon.hit.Active = interactive
	icon.hit.Selectable = interactive
	pcall(function()
		(icon.hit :: any).Interactable = interactive
	end)
	if icon.root:IsA("GuiButton") and icon.root ~= icon.hit then
		local rootBtn = icon.root :: GuiButton
		rootBtn.Active = interactive
		rootBtn.Selectable = interactive
		pcall(function()
			(rootBtn :: any).Interactable = interactive
		end)
	end
end

local function makeDecorNonInteractive(gui: GuiObject)
	-- Pure visual chrome â€” must never steal 3D coral picks or show the hand cursor.
	gui.Active = false
	if gui:IsA("GuiButton") then
		gui.Active = false
		gui.Selectable = false
		gui.AutoButtonColor = false
		pcall(function()
			(gui :: any).Interactable = false
		end)
	end
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("GuiObject") then
			d.Active = false
			if d:IsA("GuiButton") then
				d.Selectable = false
				d.AutoButtonColor = false
				pcall(function()
					(d :: any).Interactable = false
				end)
			end
		end
	end
end

local function raiseDPadIconLayer()
	local icon = dPadIcon
	if not icon then
		return
	end
	-- Above FreeCam / FishCam / OffCam roots (Z 10â€“30) and other dPad siblings.
	local z = 80
	icon.ZIndex = z
	for _, d in ipairs(icon:GetDescendants()) do
		if d:IsA("GuiObject") then
			d.ZIndex = math.max(d.ZIndex, z + 1)
		end
	end
	makeDecorNonInteractive(icon)
	-- Last sibling draws on top when ZIndex ties (Sibling behavior).
	icon.Parent = icon.Parent
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
	raiseDPadIconLayer()
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
	raiseDPadIconLayer()
end

local function setCarouselCollapsedAttr(collapsed: boolean)
	playerGui:SetAttribute(FC.ATTR_CAROUSEL_COLLAPSED, collapsed == true)
end

local function scheduleCollapse(token: number, relativeTo: CamMode)
	task.delay(FC.COLLAPSE_WAIT_SEC, function()
		if token ~= carouselToken or not carouselReady then
			return
		end
		-- Skills/backpack may have opened during the wait — stay collapsed so restore
		-- doesn't snap the full diamond of cam icons.
		carouselCollapsed = true
		if camModeIconsSuppressed() then
			setCarouselCollapsedAttr(true)
			return
		end
		tweenIconsToLayout(relativeTo, true, FC.COLLAPSE_INFO, token, function()
			if token ~= carouselToken then
				return
			end
			setCarouselCollapsedAttr(true)
		end)
	end)
end

local function playCamCarousel(fromMode: CamMode, toMode: CamMode, animate: boolean)
	if not carouselReady or #camIcons == 0 then
		return
	end
	if camModeIconsSuppressed() then
		-- Keep mode/layout state, but never force triangle icons over skills HUD.
		carouselToken += 1
		carouselCollapsed = true
		setCarouselCollapsedAttr(true)
		for _, icon in ipairs(camIcons) do
			applyIconChrome(icon, toMode, true)
		end
		return
	end
	carouselToken += 1
	local my = carouselToken
	-- Expanding / revolving — hide Plot Cam quick pad until collapse finishes again.
	setCarouselCollapsedAttr(false)

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
		tweenIconsToLayout(toMode, false, FC.REVOLVE_INFO, my, function()
			if my ~= carouselToken then
				return
			end
			scheduleCollapse(my, toMode)
		end)
	end

	if carouselCollapsed then
		-- Pop the tucked icons back to the previous triangle, then revolve.
		tweenIconsToLayout(fromMode, false, FC.EXPAND_INFO, my, revolveThenCollapse)
	else
		revolveThenCollapse()
	end
end

-- Cancel delayed carousel collapse so it cannot unhide FreeCam/FishCam/OffCam over skills.
-- Do not set Visible here while suppressed â€” MobileSkillsA rememberHide must record wasVisible=true.
local function syncCamModeIconsForHud()
	if camModeIconsSuppressed() then
		carouselToken += 1
		carouselCollapsed = true
		setCarouselCollapsedAttr(true)
		FreeCamModeLabel.hide()
		return
	end
	if carouselReady and #camIcons > 0 then
		-- Always snap collapsed after skills/backpack — never leave the full diamond up.
		carouselCollapsed = true
		snapIconsToLayout(mode, true)
		setCarouselCollapsedAttr(true)
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
	ContextActionService:UnbindAction(FC.SINK_ACTION)
	if not on then
		return
	end
	-- Sink locomotion so the avatar cannot walk while cam cycle owns the view.
	ContextActionService:BindActionAtPriority(
		FC.SINK_ACTION,
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
	if mag > FC.TOUCH_STICK_RADIUS then
		delta = delta.Unit * FC.TOUCH_STICK_RADIUS
	end
	return delta / FC.TOUCH_STICK_RADIUS
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

local function isDroneCamLook(): boolean
	return mode == "dronecam"
end

local function isFishCamLook(): boolean
	return mode == "fishcam" or mode == "dronecam"
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
	if mode ~= "fishcam" then
		return false
	end
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

	-- Gamepad left stick: Y+ is up â€” do not negate (was inverted).
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
	fishSt.switchFrom = fishSt.focusPos
	fishSt.switchTo = toPos
	fishSt.switchT0 = os.clock()
	fishSt.switching = true
end

local function resetFishOrbitClock()
	fishSt.orbitT0 = os.clock()
	local flat = Vector3.new(camPos.X - fishSt.focusPos.X, 0, camPos.Z - fishSt.focusPos.Z)
	if flat.Magnitude > 0.1 then
		fishSt.orbitAngle = math.atan2(flat.Z, flat.X)
	else
		fishSt.orbitAngle = 0
	end
	fishSt.orbitElev = 0
end

local function resetFishFollowState(seed: Vector3?)
	fishSt.targetId = nil
	fishSt.switching = false
	fishSt.focusPos = seed or camPos
	fishSt.dampPos = fishSt.focusPos
	fishSt.switchFrom = fishSt.focusPos
	fishSt.switchTo = fishSt.focusPos
	resetFishOrbitClock()
end

local function fishDistanceMult(elapsed: number): number
	local breatheU = (elapsed % FC.FISH_DIST_BREATHE_SEC) / FC.FISH_DIST_BREATHE_SEC
	-- Smooth 1 â†’ max â†’ 1 over the breathe period.
	return 1 + (FC.FISH_DIST_BREATHE_MAX - 1) * 0.5 * (1 - math.cos(2 * math.pi * breatheU))
end

local function fishChaseOffset(dt: number): Vector3
	local elapsed = math.max(0, os.clock() - fishSt.orbitT0)
	local mult = fishDistanceMult(elapsed)
	-- Closer = full orbit speed; at max distance, up to FC.FISH_ORBIT_SLOW_MAX slower.
	local farT = math.clamp((mult - 1) / (FC.FISH_DIST_BREATHE_MAX - 1), 0, 1)
	local slow = 1 + farT * (FC.FISH_ORBIT_SLOW_MAX - 1)
	local radPerSec = (math.pi * 2) / (FC.FISH_ORBIT_SEC * slow)
	-- Pause auto-spin while the player is steering; resume from the new angle after.
	if not isUserSteeringOrbit() then
		fishSt.orbitAngle -= radPerSec * math.max(dt, 0)
	end
	local dist = FC.FISH_CHASE_DIST * mult
	local height = FC.FISH_CHASE_HEIGHT * mult
	local r = math.sqrt(dist * dist + height * height)
	local baseElev = math.atan2(height, dist)
	local elev = math.clamp(baseElev + fishSt.orbitElev, 0.12, 1.25)
	local flatLen = r * math.cos(elev)
	local flat = Vector3.new(math.cos(fishSt.orbitAngle), 0, math.sin(fishSt.orbitAngle))
	return flat * flatLen + Vector3.new(0, r * math.sin(elev), 0)
end

local function applyLookDelta(dx: number, dy: number)
	-- Ignore one-frame spikes (touch/mouse emulation jumps) that invert the view.
	if math.abs(dx) > 1.2 or math.abs(dy) > 1.2 then
		return
	end
	if mode == "fishcam" then
		-- Steer around the fish / W1; auto orbit continues from this heading.
		fishSt.orbitAngle -= dx
		fishSt.orbitElev = math.clamp(fishSt.orbitElev - dy, -0.7, 0.85)
		return
	end
	lookYaw -= dx
	lookPitch = math.clamp(lookPitch - dy, -1.2, 1.2)
end

local function tickMouseDragLook()
	-- GetMouseDelta is 0 with a free cursor â€” track screen position instead.
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
			applyLookDelta(d.X * FC.LOOK_SENS_MOUSE, d.Y * FC.LOOK_SENS_MOUSE)
		end
	end
	mouseLookLast = loc
end

local function tickLookInput(dt: number)
	if lookStick.Magnitude > 0.12 then
		applyLookDelta(lookStick.X * FC.LOOK_SENS_STICK * dt, lookStick.Y * FC.LOOK_SENS_STICK * dt)
	end
	tickMouseDragLook()
	if keysDown[Enum.KeyCode.Left] then
		applyLookDelta(-FC.LOOK_SENS_KEYS * dt, 0)
	end
	if keysDown[Enum.KeyCode.Right] then
		applyLookDelta(FC.LOOK_SENS_KEYS * dt, 0)
	end
	if keysDown[Enum.KeyCode.Up] then
		applyLookDelta(0, -FC.LOOK_SENS_KEYS * dt)
	end
	if keysDown[Enum.KeyCode.Down] then
		applyLookDelta(0, FC.LOOK_SENS_KEYS * dt)
	end
end

local function moveSpeedForWish(): number
	local speed = FC.MOVE_SPEED
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
	PlotCam2.stop()
	PlotCam2Tune.setVisible(false)
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

	-- Intro/defeat cinematics own the camera â€” don't yank back to Custom mid-shot.
	if playerGui:GetAttribute("OceanTD_TangCamBusy") == true
		or playerGui:GetAttribute("OceanTD_SharkCamBusy") == true
		or playerGui:GetAttribute("OceanTD_UrchinCamBusy") == true
		or playerGui:GetAttribute("OceanTD_ReefDefeatCamBusy") == true
		or playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true
	then
		savedCameraType = nil
		return
	end

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

local function loadRouteWaypoints(): { Vector3 }
	table.clear(route.waypoints)
	local root = Workspace:FindFirstChild("WaveRoute")
	local routeA = root and root:FindFirstChild("A")
	local wpFolder = routeA and routeA:FindFirstChild("Waypoints")
	if not wpFolder then
		return route.waypoints
	end
	local i = 1
	while true do
		local w = wpFolder:FindFirstChild("W" .. tostring(i))
		if not (w and w:IsA("BasePart")) then
			break
		end
		table.insert(route.waypoints, ClientPlot.remapFromPlot1(w.Position))
		i += 1
	end
	return route.waypoints
end

local function resolveFishSpawnFocus(): Vector3?
	local pts = route.waypoints
	if #pts == 0 then
		pts = loadRouteWaypoints()
	end
	if #pts > 0 then
		return pts[1]
	end
	return nil
end

local function resetRoutePatrol(seedPos: Vector3?)
	loadRouteWaypoints()
	route.segIndex = 1
	route.segAlpha = 0
	route.patrolDir = 1
	if seedPos and #route.waypoints >= 2 then
		local bestI, bestA, bestD = 1, 0, math.huge
		for i = 1, #route.waypoints - 1 do
			local a = route.waypoints[i]
			local b = route.waypoints[i + 1]
			local ab = b - a
			local len2 = ab:Dot(ab)
			local t = if len2 > 1e-4 then math.clamp((seedPos - a):Dot(ab) / len2, 0, 1) else 0
			local closest = a:Lerp(b, t)
			local d = (seedPos - closest).Magnitude
			if d < bestD then
				bestD = d
				bestI = i
				bestA = t
			end
		end
		route.segIndex = bestI
		route.segAlpha = bestA
	end
end

local function tickRoutePatrol(dt: number): Vector3
	if #route.waypoints == 0 then
		loadRouteWaypoints()
	end
	local n = #route.waypoints
	if n == 0 then
		return fishSt.focusPos
	end
	if n == 1 then
		return route.waypoints[1]
	end

	route.segAlpha += (dt / FC.ROUTE_PATROL_SEC) * route.patrolDir
	if route.patrolDir > 0 and route.segAlpha >= 1 then
		if route.segIndex >= n - 1 then
			route.patrolDir = -1
			route.segAlpha = 1 - (route.segAlpha - 1)
		else
			route.segIndex += 1
			route.segAlpha -= 1
		end
	elseif route.patrolDir < 0 and route.segAlpha <= 0 then
		if route.segIndex <= 1 then
			route.patrolDir = 1
			route.segAlpha = -route.segAlpha
		else
			route.segIndex -= 1
			route.segAlpha += 1
		end
	end
	route.segIndex = math.clamp(route.segIndex, 1, n - 1)
	route.segAlpha = math.clamp(route.segAlpha, 0, 1)

	local a = route.waypoints[route.segIndex]
	local b = route.waypoints[route.segIndex + 1]
	return a:Lerp(b, route.segAlpha)
end

local setMode: (CamMode) -> ()
local forceModeOverride = false

local function tickPlotCam1(dt: number)
	-- Plot Cam 1 — legacy SkyCam free-fly, always looking at SkyCamFocus.
	local cam = getCamera()
	local pose = resolveSkyPose()
	if not cam or not pose then
		setMode("off")
		return
	end
	keepCharacterStill()
	local focusPos = pose.focusPos
	if playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true then
		local forced = playerGui:GetAttribute("OceanTD_JoinIntroCamPos")
		if typeof(forced) == "Vector3" then
			camPos = clampToSkyPose(forced, pose)
			cam.CameraType = Enum.CameraType.Scriptable
			cam.CFrame = lookAtFocus(focusPos)
			return
		end
	end
	local cf = lookAtFocus(focusPos)
	local wish = readMoveWish(cf)
	camPos = clampToSkyPose(camPos + wish * moveSpeedForWish() * dt, pose)
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = lookAtFocus(focusPos)
end

local function tickPlotCam2(dt: number)
	local cam = getCamera()
	if not cam then
		PlotCam2Tune.setVisible(false)
		setMode("off")
		return
	end
	-- Join-intro still owns framing when it supplies a forced SkyCam pose.
	if playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true then
		PlotCam2Tune.setVisible(false)
		tickPlotCam1(dt)
		return
	end
	keepCharacterStill()
	if not PlotCam2.isActive() then
		if not PlotCam2.begin(nil) then
			PlotCam2Tune.setVisible(false)
			setMode("off")
			return
		end
	end
	PlotCam2Tune.setVisible(true)
	local preview = PlotCam2.getCFrame()
	-- Finger is moving a coral — don't pan Plot Cam with the same drag.
	local coralDrag = RelocateController.isDragging()
	if coralDrag then
		clearTouchMove()
	end
	local wish = if coralDrag then Vector3.zero elseif preview then readMoveWish(preview) else Vector3.zero
	local cf = PlotCam2.tick(dt, {
		wish = wish,
		panSpeed = moveSpeedForWish(),
	})
	if not cf then
		PlotCam2Tune.setVisible(false)
		setMode("off")
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = cf
	camPos = cf.Position
end

local function tickPlotCam(dt: number)
	if FC.PLOT_CAM_VARIANT == 2 then
		tickPlotCam2(dt)
	else
		tickPlotCam1(dt)
	end
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
		if fishSt.targetId ~= fish.id then
			fishSt.targetId = fish.id
			beginFishSwitch(goal)
		elseif fishSt.switching then
			fishSt.switchTo = goal
		end
	else
		local held = if fishSt.targetId then WaveSim.getFishPosition(fishSt.targetId) else nil
		if held then
			goal = held
			if fishSt.switching then
				fishSt.switchTo = goal
			end
		elseif not WaveSim.isRunning() then
			-- Idle: keep orbiting while focus slowly patrols W1â†’Wnâ†’W1â€¦
			fishSt.targetId = nil
			fishSt.switching = false
			goal = tickRoutePatrol(dt)
		else
			-- Waves on but no hungry fish: hold W1 until the school appears.
			fishSt.targetId = nil
			local spawnFocus = resolveFishSpawnFocus()
			goal = spawnFocus or fishSt.focusPos
			if spawnFocus and not fishSt.switching and (fishSt.focusPos - spawnFocus).Magnitude > 2 then
				beginFishSwitch(spawnFocus)
			end
		end
	end

	-- Damp the live fish pose so path jerks don't snap the camera.
	local dampA = 1 - math.exp(-FC.FISH_DAMP_RATE * math.max(dt, 0))
	fishSt.dampPos = fishSt.dampPos:Lerp(goal, dampA)

	if fishSt.switching then
		local u = math.clamp((os.clock() - fishSt.switchT0) / FC.FISH_SWITCH_SEC, 0, 1)
		local e = u * u * (3 - 2 * u)
		fishSt.switchTo = fishSt.dampPos
		fishSt.focusPos = fishSt.switchFrom:Lerp(fishSt.switchTo, e)
		if u >= 1 then
			fishSt.switching = false
			fishSt.focusPos = fishSt.dampPos
		end
	else
		fishSt.focusPos = fishSt.dampPos
	end

	-- Slow orbit + extra camera-body damper so look stays stable.
	local desired = fishSt.focusPos + fishChaseOffset(dt)
	local aCam = 1 - math.exp(-FC.FISH_CAM_RATE * math.max(dt, 0))
	camPos = camPos:Lerp(desired, aCam)
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = lookAtFocus(fishSt.focusPos)
	syncLookFromCFrame(cam.CFrame)
end

local function tickDroneCam(dt: number)
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
		if skillsBubblesOpen() then
			return
		end
		if playerGui:GetAttribute("OceanTD_PlotSizeCinematicBusy") == true then
			return
		end
		if playerGui:GetAttribute("OceanTD_SharkCamBusy") == true then
			return
		end
		if playerGui:GetAttribute("OceanTD_UrchinCamBusy") == true then
			return
		end
		if playerGui:GetAttribute("OceanTD_TangCamBusy") == true then
			return
		end
		if playerGui:GetAttribute("OceanTD_ReefDefeatCamBusy") == true then
			return
		end
		if playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true then
			-- Still drive plotcam when intro supplies OceanTD_JoinIntroCamPos.
			if mode ~= "plotcam" then
				return
			end
		end
		-- Plot Cam stays live while placing/relocating (default RTS seat).
		if mode == "plotcam" then
			setDroneLookCapture(false)
			tickPlotCam(dt)
			return
		end
		if PlacementController.isActive() or RelocateController.isActive() then
			return
		end
		if mode == "fishcam" then
			setDroneLookCapture(false)
			tickFishFollow(dt)
			return
		end
		-- DroneCam: free-look fly (old FishCam-idle).
		tickDroneCam(dt)
	end)
end

setMode = function(nextMode: CamMode)
	if nextMode == mode then
		return
	end
	if not forceModeOverride and playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true then
		return
	end
	if nextMode ~= "off" then
		if playerGui:GetAttribute("OceanTD_PlotSizeCinematicBusy") == true then
			return
		end
		if playerGui:GetAttribute("OceanTD_SharkCamBusy") == true then
			return
		end
		if playerGui:GetAttribute("OceanTD_UrchinCamBusy") == true then
			return
		end
		if playerGui:GetAttribute("OceanTD_TangCamBusy") == true then
			return
		end
		if playerGui:GetAttribute("OceanTD_ReefDefeatCamBusy") == true then
			return
		end
		if not forceModeOverride and playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true then
			return
		end
		if PlacementController.isActive() or RelocateController.isActive() then
			return
		end
		if nextMode == "plotcam" then
			if FC.PLOT_CAM_VARIANT == 2 then
				if not ClientPlot.get() then
					return
				end
			else
				local pose = resolveSkyPose()
				if not pose then
					warn("[CamCycle] SkyCam / SkyCamFocus missing for local plot — PlotCam unavailable")
					return
				end
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
	-- Wait for the revolve so the active icon is on the top slot before measuring.
	local labelToken = carouselToken
	task.delay(FC.REVOLVE_INFO.Time + 0.05, function()
		if labelToken ~= carouselToken then
			return
		end
		FreeCamModeLabel.show(nextMode, camIcons, mode, slotPos.active, camModeIconsSuppressed(), carouselReady)
	end)

	if nextMode == "off" then
		PlotCam2.stop()
		PlotCam2Tune.setVisible(false)
		restoreDefaultCamera()
		return
	end

	-- Entering / switching into an override mode.
	Wave1FishCam.stopImmediate()
	if nextMode ~= "plotcam" then
		PlotCam2.stop()
		PlotCam2Tune.setVisible(false)
	end
	if prev == "off" then
		if not ensureScriptableFromCurrent() then
			mode = "off"
			publishMode()
			playCamCarousel(nextMode, "off", false)
			return
		end
		if nextMode == "plotcam" and not resumePreserveView and FC.PLOT_CAM_VARIANT ~= 2 then
			local pose = resolveSkyPose()
			if pose then
				camPos = clampToSkyPose(camPos, pose)
			end
		end
		lockAvatarForMode()
	end

	if nextMode == "plotcam" then
		local cam = getCamera()
		if FC.PLOT_CAM_VARIANT == 2 then
			local resumeCf = if resumePreserveView and cam then cam.CFrame else nil
			if not PlotCam2.begin(resumeCf) then
				mode = "off"
				publishMode()
				PlotCam2.stop()
				PlotCam2Tune.setVisible(false)
				restoreDefaultCamera()
				return
			end
			local cf = PlotCam2.getCFrame()
			if cam and cf then
				cam.CameraType = Enum.CameraType.Scriptable
				cam.CFrame = cf
				camPos = cf.Position
			end
			PlotCam2Tune.setVisible(true)
			PlotCam2Tune.refresh()
		else
			PlotCam2Tune.setVisible(false)
			local pose = resolveSkyPose()
			if pose and cam then
				cam.CameraType = Enum.CameraType.Scriptable
				if resumePreserveView then
					camPos = clampToSkyPose(cam.CFrame.Position, pose)
					syncLookFromCFrame(cam.CFrame)
					cam.CFrame = CFrame.new(camPos) * (cam.CFrame - cam.CFrame.Position)
				else
					camPos = clampToSkyPose(camPos, pose)
					cam.CFrame = lookAtFocus(pose.focusPos)
				end
			end
		end
		setDroneLookCapture(false)
	elseif nextMode == "fishcam" then
		local cam = getCamera()
		if resumePreserveView and cam then
			cam.CameraType = Enum.CameraType.Scriptable
			camPos = cam.CFrame.Position
			syncLookFromCFrame(cam.CFrame)
			resetRoutePatrol(camPos)
			local fish = WaveSim.getFurthestUnfedFish()
			local spawnFocus = resolveFishSpawnFocus()
			if fish then
				fishSt.focusPos = fish.position
				fishSt.dampPos = fish.position
				fishSt.targetId = fish.id
			elseif spawnFocus then
				fishSt.focusPos = spawnFocus
				fishSt.dampPos = spawnFocus
				fishSt.targetId = nil
			else
				resetFishFollowState(camPos)
			end
		else
			resetRoutePatrol(camPos)
			local spawnFocus = resolveFishSpawnFocus()
			resetFishFollowState(spawnFocus or camPos)
			if cam then
				cam.CameraType = Enum.CameraType.Scriptable
				local fish = WaveSim.getFurthestUnfedFish()
				if fish then
					fishSt.focusPos = fish.position
					fishSt.dampPos = fish.position
					fishSt.targetId = fish.id
				elseif spawnFocus then
					fishSt.focusPos = spawnFocus
					fishSt.dampPos = spawnFocus
					fishSt.targetId = nil
				end
				camPos = fishSt.focusPos + fishChaseOffset(0)
				cam.CFrame = lookAtFocus(fishSt.focusPos)
				syncLookFromCFrame(cam.CFrame)
			end
		end
		setDroneLookCapture(false)
	elseif nextMode == "dronecam" then
		local cam = getCamera()
		if cam then
			cam.CameraType = Enum.CameraType.Scriptable
			if resumePreserveView then
				camPos = cam.CFrame.Position
				syncLookFromCFrame(cam.CFrame)
			else
				syncLookFromCFrame(cam.CFrame)
				cam.CFrame = droneLookCFrame()
			end
			setDroneLookCapture(true)
		end
	end

	startRenderLoop()
end

local function cycleMode()
	if playerGui:GetAttribute("OceanTD_TutorialGateCam") == true then
		return
	end
	setMode(nextCamMode(mode))
end

-- D-pad Down cycles cam modes while backpack / build UI is closed.
ContextActionService:BindActionAtPriority(FC.DPAD_ACTION, function(_name, state, _input)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if playerGui:GetAttribute("OceanTD_TutorialGateCam") == true then
		return Enum.ContextActionResult.Sink
	end
	if InventoryState.isOpen() then
		return Enum.ContextActionResult.Pass
	end
	if skillsBubblesOpen() then
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
	-- Skills bubbles own the d-pad while open â€” don't stack a second white center glow.
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
	TweenService:Create(sc, FC.DPAD_GLOW_INFO, { Scale = 1.55 }):Play()
	local fade = TweenService:Create(glow, FC.DPAD_GLOW_INFO, { BackgroundTransparency = 1 })
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
				applyLookDelta(delta.X * FC.LOOK_SENS_TOUCH, delta.Y * FC.LOOK_SENS_TOUCH)
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

local function tryEnterStartPlotCam()
	if not startPlotCamPending or not carouselReady then
		return
	end
	if mode ~= "off" then
		startPlotCamPending = false
		return
	end
	setMode("plotcam")
	if mode == "plotcam" then
		startPlotCamPending = false
	end
end

ClientPlot.onChanged(function()
	clearSkyCache()
	table.clear(route.waypoints)
	if mode == "plotcam" then
		local pose = resolveSkyPose()
		if not pose then
			setMode("off")
		else
			camPos = clampToSkyPose(camPos, pose)
		end
	elseif mode == "fishcam" then
		resetRoutePatrol(fishSt.focusPos)
	end
	tryEnterStartPlotCam()
end)

local function ensureHitButton(btn: GuiObject): GuiButton
	if btn:IsA("GuiButton") then
		btn.AutoButtonColor = false
		return btn
	end
	local existing = btn:FindFirstChildWhichIsA("GuiButton", true)
	if existing then
		existing.AutoButtonColor = false
		return existing
	end
	local made = Instance.new("TextButton")
	made.Name = "_OceanTD_CamCycleHit"
	made.Text = ""
	made.BackgroundTransparency = 1
	made.AutoButtonColor = false
	made.Size = UDim2.fromScale(1, 1)
	made.ZIndex = 100
	made.Parent = btn
	return made
end

-- Studio circles default to AutoButtonColor black on hover — use dark grey instead.
local function wireCamHoverGrey(root: GuiObject, hit: GuiButton)
	if root:GetAttribute("_OceanTD_CamHoverGrey") == true then
		return
	end
	root:SetAttribute("_OceanTD_CamHoverGrey", true)
	local target = strokeTarget(root)
	if target:IsA("GuiButton") then
		target.AutoButtonColor = false
	end
	hit.AutoButtonColor = false
	local idleColor = target.BackgroundColor3
	local idleTrans = target.BackgroundTransparency
	-- Opaque black disks are common; keep idle, lighten to grey on hover.
	local function enter()
		if idleTrans >= 0.95 then
			target.BackgroundTransparency = 0
		end
		target.BackgroundColor3 = FC.HOVER_GREY
	end
	local function leave()
		target.BackgroundColor3 = idleColor
		target.BackgroundTransparency = idleTrans
	end
	hit.MouseEnter:Connect(enter)
	hit.MouseLeave:Connect(leave)
	hit.SelectionGained:Connect(enter)
	hit.SelectionLost:Connect(leave)
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

local function applyModeGraphic(gui: GuiObject, camMode: CamMode)
	local id = FC.MODE_GRAPHICS[camMode]
	if gui:IsA("ImageButton") or gui:IsA("ImageLabel") then
		(gui :: ImageLabel).Image = id
	end
	for _, name in ipairs({ "Icon", "Circle", "Image", "icon", "circle" }) do
		local ch = gui:FindFirstChild(name)
		if ch and (ch:IsA("ImageLabel") or ch:IsA("ImageButton")) then
			(ch :: ImageLabel).Image = id
		end
	end
end

local function wireModeIcon(btn: GuiObject, camMode: CamMode)
	centerGuiPivot(btn)
	applyModeGraphic(btn, camMode)
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
	wireCamHoverGrey(btn, hit)
	if camMode == "dronecam" then
		freeCamButton = hit
		btnStroke = stroke
	end
end

local function wireCamCarousel(dPad: Instance)
	table.clear(camIcons)
	carouselReady = false
	-- Studio: FreeCam button = DroneCam mode; PlotCam = SkyCam plot fly.
	local droneGui = dPad:FindFirstChild("FreeCam")
	local plotGui = dPad:FindFirstChild("PlotCam")
	local fishGui = dPad:FindFirstChild("FishCam")
	local offGui = dPad:FindFirstChild("OffCam")
	if not (droneGui and droneGui:IsA("GuiObject")) then
		warn("[CamCycle] MobileLeftUI.dPad.FreeCam (DroneCam) missing")
		return
	end
	if not (plotGui and plotGui:IsA("GuiObject")) then
		warn("[CamCycle] MobileLeftUI.dPad.PlotCam missing")
		return
	end
	if not (fishGui and fishGui:IsA("GuiObject")) then
		warn("[CamCycle] MobileLeftUI.dPad.FishCam missing")
		return
	end
	if not (offGui and offGui:IsA("GuiObject")) then
		warn("[CamCycle] MobileLeftUI.dPad.OffCam missing")
		return
	end

	-- Authored diamond positions: FreeCam top, FishCam left, PlotCam bottom, OffCam right.
	centerGuiPivot(droneGui)
	centerGuiPivot(fishGui)
	centerGuiPivot(plotGui)
	centerGuiPivot(offGui)
	slotPos.active = droneGui.Position
	slotPos.next = fishGui.Position
	slotPos.bottom = plotGui.Position
	slotPos.last = offGui.Position

	wireModeIcon(offGui, "off")
	wireModeIcon(plotGui, "plotcam")
	wireModeIcon(fishGui, "fishcam")
	wireModeIcon(droneGui, "dronecam")
	carouselReady = true
	-- Default seat: Plot Cam (icons + camera). Fall back to icon layout if blocked.
	tryEnterStartPlotCam()
	if mode ~= "plotcam" then
		playCamCarousel("plotcam", "plotcam", false)
	end
end

local function syncDPadIcon()
	if not dPadIcon or not dPadIconScale then
		return
	end
	-- Decorative dPad graphic: visible whenever backpack is closed (all input types).
	-- Hide while skills / reef report own the screen (avoids a second white center dot).
	local want = not InventoryState.isOpen() and not skillsBubblesOpen()
	if want == dPadIconShown then
		if want then
			raiseDPadIconLayer()
		end
		return
	end
	dPadIconShown = want
	if dPadIconTween then
		dPadIconTween:Cancel()
		dPadIconTween = nil
	end
	dPadIcon.Visible = true
	raiseDPadIconLayer()
	local goal = if want then 1 else 0
	local info = if want then FC.ICON_SCALE_IN else FC.ICON_SCALE_OUT
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
	makeDecorNonInteractive(icon)
	-- UIScale pivots from AnchorPoint â€” center so it grows/shrinks in place.
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
	raiseDPadIconLayer()
	dPadIconShown = false
	syncDPadIcon()
end

publishMode()

local leftHudListenersBound = false
local boundLeftUi: Instance? = nil

local function camIconsStillLive(): boolean
	if not carouselReady or #camIcons < 4 then
		return false
	end
	for _, icon in ipairs(camIcons) do
		if not icon.root.Parent or not icon.root:IsDescendantOf(playerGui) then
			return false
		end
		if not icon.root:FindFirstChildOfClass("UIScale") then
			return false
		end
	end
	return true
end

local function bindMobileLeftUi(left: Instance)
	LeftHudLayout.hardenScreenGui(left)
	if left == boundLeftUi and camIconsStillLive() then
		return
	end
	boundLeftUi = left

	local dPad = left:FindFirstChild("dPad") or left:WaitForChild("dPad", 30)
	if not dPad then
		warn("[FreeCam] MobileLeftUI.dPad missing")
		return
	end
	wireCamCarousel(dPad)
	if dPad:IsA("GuiObject") then
		-- Container must not block the world; cam/skills buttons keep their own hits.
		-- Active=false only â€” Interactable=false would disable all child buttons.
		dPad.Active = false
	end

	local icon = dPad:FindFirstChild("dPadIcon")
	if icon and icon:IsA("GuiObject") then
		wireDPadIcon(icon)
	else
		warn("[FreeCam] MobileLeftUI.dPad.dPadIcon missing")
	end

	if not leftHudListenersBound then
		leftHudListenersBound = true
		InventoryState.onOpenChanged(function()
			syncDPadIcon()
			syncCamModeIconsForHud()
		end)
		UserInputService.LastInputTypeChanged:Connect(function()
			syncDPadIcon()
		end)
		playerGui:GetAttributeChangedSignal("OceanTD_SkillsBubblesOpen"):Connect(function()
			syncDPadIcon()
			syncCamModeIconsForHud()
		end)
		playerGui:GetAttributeChangedSignal("OceanTD_ReefReportOpen"):Connect(function()
			syncDPadIcon()
			syncCamModeIconsForHud()
		end)
		playerGui:GetAttributeChangedSignal("OceanTD_StoreOpen"):Connect(function()
			syncDPadIcon()
			syncCamModeIconsForHud()
		end)

		playerGui:GetAttributeChangedSignal("OceanTD_SyncCamCycleFromView"):Connect(function()
			if mode ~= "off" then
				local cam = getCamera()
				if cam then
					camPos = cam.CFrame.Position
					syncLookFromCFrame(cam.CFrame)
				end
			end
		end)

		playerGui:GetAttributeChangedSignal("OceanTD_ForceCloseFreeCam"):Connect(function()
			if mode == "off" then
				return
			end
			-- Plot Cam is the default RTS seat — stay on it through place/build.
			-- Cinematics still stash + close.
			if playerGui:GetAttribute("OceanTD_ReefDefeatCamBusy") == true
				or playerGui:GetAttribute("OceanTD_TangCamBusy") == true
				or playerGui:GetAttribute("OceanTD_SharkCamBusy") == true
				or playerGui:GetAttribute("OceanTD_UrchinCamBusy") == true
				or playerGui:GetAttribute("OceanTD_PlotSizeCinematicBusy") == true
			then
				cinematicResumeMode = mode
				playerGui:SetAttribute(FC.ATTR_CINEMATIC_RESUME_MODE, mode)
			elseif mode == "plotcam" then
				return
			else
				-- Fish/Drone: stash so closing backpack restores them.
				buildResumeMode = mode
			end
			forceModeOverride = true
			setMode("off")
			forceModeOverride = false
		end)

		-- Hard stop FishCam/PlotCam writes the instant shark/urchin/tang intro claims the cam.
		local function onWaveIntroCamBusy()
			if playerGui:GetAttribute("OceanTD_SharkCamBusy") == true
				or playerGui:GetAttribute("OceanTD_UrchinCamBusy") == true
				or playerGui:GetAttribute("OceanTD_TangCamBusy") == true
			then
				stopRender()
				if mode ~= "off" then
					cinematicResumeMode = mode
					playerGui:SetAttribute(FC.ATTR_CINEMATIC_RESUME_MODE, mode)
					forceModeOverride = true
					setMode("off")
					forceModeOverride = false
				end
			end
		end
		playerGui:GetAttributeChangedSignal("OceanTD_SharkCamBusy"):Connect(onWaveIntroCamBusy)
		playerGui:GetAttributeChangedSignal("OceanTD_UrchinCamBusy"):Connect(onWaveIntroCamBusy)
		playerGui:GetAttributeChangedSignal("OceanTD_TangCamBusy"):Connect(onWaveIntroCamBusy)

		playerGui:GetAttributeChangedSignal("OceanTD_ForceCamMode"):Connect(function()
			local raw = playerGui:GetAttribute("OceanTD_ForceCamMode")
			if raw ~= "off" and raw ~= "plotcam" and raw ~= "fishcam" and raw ~= "dronecam" then
				return
			end
			if playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true then
				if raw ~= "plotcam" and raw ~= "off" then
					return
				end
			end
			forceModeOverride = true
			setMode(raw :: CamMode)
			forceModeOverride = false
		end)

		playerGui:GetAttributeChangedSignal("OceanTD_JoinIntroBusy"):Connect(function()
			if playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true then
				return
			end
			-- Defer so we run after JoinIntro's same-frame ForceCamMode write.
			task.defer(function()
				tryEnterStartPlotCam()
			end)
		end)

		local function onResumeCinematicCam()
			local resume = cinematicResumeMode
			cinematicResumeMode = nil
			playerGui:SetAttribute(FC.ATTR_CINEMATIC_RESUME_MODE, "")
			if resume and resume ~= "off" then
				task.defer(function()
					if mode == "off" and not PlacementController.isActive() and not RelocateController.isActive() then
						resumePreserveView = true
						setMode(resume)
						resumePreserveView = false
						local cam = getCamera()
						if cam and mode ~= "off" then
							camPos = cam.CFrame.Position
							syncLookFromCFrame(cam.CFrame)
						end
					end
				end)
			elseif mode == "off" then
				-- No stash: still ensure we aren't stuck Scriptable on the cinematic pose.
				local cam = getCamera()
				if cam and cam.CameraType == Enum.CameraType.Scriptable then
					restoreDefaultCamera()
				end
			end
		end

		local function tryResumeBuildCam()
			local resume = buildResumeMode
			if not resume or resume == "off" then
				return
			end
			if mode ~= "off" then
				buildResumeMode = nil
				return
			end
			if PlacementController.isActive() or RelocateController.isActive() then
				return
			end
			buildResumeMode = nil
			forceModeOverride = true
			setMode(resume)
			forceModeOverride = false
		end

		local function onResumeBuildCam()
			task.defer(tryResumeBuildCam)
		end

		playerGui:GetAttributeChangedSignal("OceanTD_ResumeDefeatCam"):Connect(onResumeCinematicCam)
		playerGui:GetAttributeChangedSignal("OceanTD_ResumeCinematicCam"):Connect(onResumeCinematicCam)
		playerGui:GetAttributeChangedSignal("OceanTD_ResumeBuildCam"):Connect(onResumeBuildCam)

		InventoryState.onOpenChanged(function(open)
			if not open then
				task.defer(tryResumeBuildCam)
			end
		end)

		RelocateController.onActiveChanged(function(active)
			if not active then
				task.defer(tryResumeBuildCam)
			end
		end)

		playerGui:GetAttributeChangedSignal("OceanTD_ClearDefeatCamStash"):Connect(function()
			cinematicResumeMode = nil
			playerGui:SetAttribute(FC.ATTR_CINEMATIC_RESUME_MODE, "")
		end)
	end

	syncDPadIcon()
	syncCamModeIconsForHud()
	print("[CamCycle] Bound MobileLeftUI â€” Off â†’ PlotCam â†’ FishCam â†’ DroneCam")
end

task.spawn(function()
	local left = playerGui:WaitForChild("MobileLeftUI", 60)
	if not left then
		warn("[FreeCam] PlayerGui.MobileLeftUI missing")
		return
	end
	LeftHudLayout.watchMobileLeftUi(playerGui, bindMobileLeftUi)

	-- Recover if ResetOnSpawn / wipe destroyed wiring without a clean ScreenGui replace.
	task.spawn(function()
		while true do
			task.wait(2)
			local cur = playerGui:FindFirstChild("MobileLeftUI")
			if cur and not camIconsStillLive() then
				boundLeftUi = nil
				bindMobileLeftUi(cur)
			end
		end
	end)
end)
