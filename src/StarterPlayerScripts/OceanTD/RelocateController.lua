--!strict
--[[
	Relocate a previously placed coral while the backpack is open.
	Click coral → move icon + X scale up from its center.
	X (unmoved) → close tool. Drag → show ✓. ✓ saves and closes; X after drag reverts.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = Workspace.CurrentCamera

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local GridMath = require(oceanRoot:WaitForChild("Shared"):WaitForChild("GridMath"))
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))
local BrainStack = require(oceanRoot:WaitForChild("Shared"):WaitForChild("BrainStack"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local PlacedCoralIndex = require(script.Parent:WaitForChild("PlacedCoralIndex"))
local PlaceRaycast = require(script.Parent:WaitForChild("PlaceRaycast"))
local PlaceVfx = require(script.Parent:WaitForChild("PlaceVfx"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local SelectRing = require(script.Parent:WaitForChild("SelectRing"))
local PlaceConfirmChrome = require(script.Parent:WaitForChild("PlaceConfirmChrome"))
local PlaceConfirmHitTest = require(script.Parent:WaitForChild("PlaceConfirmHitTest"))
local RelocateConsts = require(script.Parent:WaitForChild("RelocateConsts"))
local RelocateHitTest = require(script.Parent:WaitForChild("RelocateHitTest"))
local BrainSnapPreview = require(script.Parent:WaitForChild("BrainSnapPreview"))
local RelocateMultiSelect = require(script.Parent:WaitForChild("RelocateMultiSelect"))
local RelocatePickHover = require(script.Parent:WaitForChild("RelocatePickHover"))

local RelocateController = {}

local C = RelocateConsts

local cinematicHold = false
local inspectModal = false
local inspectPanelVisible = false
local activeChanged = Instance.new("BindableEvent")
local r1WhileActive: (() -> boolean)? = nil
local aWhileIdle: (() -> boolean)? = nil
local busy = false
local active = false
local introAnimating = false
local gamepadRelocate = false
local gamepadCursor: Vector2? = nil
local gamepadChromeT0 = 0
local relocateShownAt = 0
local part: BasePart? = nil
local originPos: Vector3? = nil
local gridAnchorPos: Vector3? = nil -- terrain ray-hit stored in grid (sponge pivot is raised)
local moveGridAnchor: Vector3? = nil
local lastChromeScreen: Vector2? = nil -- keep Del locked to coral when projection briefly fails
local placeId = ""
local itemId: string? = nil
local baseColor: Color3? = nil
local baseMaterial: Enum.Material? = nil
local showPaintSolid = false -- after color pick: hide white neon, show real paint
local hasMoved = false
local validSpot = true
local rejectReason: string? = nil
local warnLabel: TextLabel? = nil
-- Recycle confirm: flash recycle btn + show ✓; ✓ removes coral and credits a seed.
local recyclePending = false
local recycleFlying = false
local uiSession = 0 -- bumps when UI is destroyed / new begin; recycle-fly callbacks check this
local recycleSlideU = 0 -- 0 = above X, 1 = centered above ✓+X
local recycleSlideT0 = 0
local recycleSlideActive = false

-- Stationary coral occupying the aimed cell — solid red neon (not flashing).
local blockPart: BasePart? = nil
local blockBaseMaterial: Enum.Material? = nil
local blockBaseColor: Color3? = nil

local gui: ScreenGui? = nil
local checkBtn: TextButton? = nil
local cancelBtn: TextButton? = nil
local rotLeftBtn: ImageButton? = nil
local rotRightBtn: ImageButton? = nil
local recycleBtn: TextButton? = nil
local recycleIcon: ImageLabel? = nil
local recyclePlus: TextLabel? = nil
local moveBillboard: BillboardGui? = nil
local moveIcon: ImageLabel? = nil
local moveIconInspectBlend = 0
local moveIconDropTweenConn: RBXScriptConnection? = nil
local moveAdorneePart: BasePart? = nil
local waistBb: BillboardGui? = nil
local waistAdornee: BasePart? = nil
local chromeBtnDown = false
local chromePressTarget: string? = nil -- "check" | "cancel" | "recycle" | "rotLeft" | "rotRight"
-- "gui" = TextButton claimed the press; "uis" = screen hit-test only.
local chromeClaimSource: string? = nil
local confirmOutroPlaying = false
local confirmOutroTween: Tween? = nil
local confirmOutroGen = 0
local confirmOutroDone = true
local fingerDown = false
local pressOrigin: Vector2? = nil
local dragging = false
local grabFromMoveIcon = false
local relocateFacingYaw: number? = nil
local originFacingYaw: number? = nil
local hasRotated = false

-- Forward decls: makeUi's rot-hold closures call these before their definitions below.
local rotateSelectedSeaFan: (dir: number) -> ()
local rotateBrainSnapOrbit: (dir: number) -> ()

local frozen = false
local savedWalkSpeed = C.DEFAULT_WALK_SPEED
local savedJumpPower = C.DEFAULT_JUMP_POWER
local savedJumpHeight = C.DEFAULT_JUMP_HEIGHT
local savedCameraType: Enum.CameraType? = nil
local savedCameraCFrame: CFrame? = nil
local savedTouchControlsEnabled: boolean? = nil
local jumpUnlockConn: RBXScriptConnection? = nil
local loopConn: RBXScriptConnection? = nil
local inputConns: { RBXScriptConnection } = {}

-- White grow/shrink ring so players can see the interactive coral (hover + move tool).
local selectRing = SelectRing.new()

-- Click pick: press may be marked processed by GUI; confirm on release too.
local pendingPick: BasePart? = nil
local pendingPickScreen: Vector2? = nil
-- While relocating: tap another coral to switch (deferred to release so drag still works).
local pendingCoralSwitch: BasePart? = nil
local pendingCoralSwitchScreen: Vector2? = nil

local function clearHover()
	RelocatePickHover.clearHover()
end

local function chromeRefs(): RelocateHitTest.ChromeRefs
	return {
		playerGui = playerGui,
		checkBtn = checkBtn,
		cancelBtn = cancelBtn,
		rotLeftBtn = rotLeftBtn,
		rotRightBtn = rotRightBtn,
		recycleBtn = recycleBtn,
		moveIcon = moveIcon,
		moveBillboard = moveBillboard,
		chromeBtnDown = chromeBtnDown,
	}
end

local function log(...: any)
	print("[RELOCATE]", ...)
end

-- Prefer Confirm; never let a flaky UIS hit-test downgrade Confirm → Cancel.
local function claimChromeTarget(target: string, source: string?)
	local src = source or "uis"
	if chromeBtnDown and chromePressTarget == "check" and target == "cancel" then
		return
	end
	if chromeClaimSource == "gui" and src == "uis" and chromePressTarget == "check" then
		return
	end
	if target == "check" or not chromeBtnDown or chromePressTarget ~= "check" or src == "gui" then
		chromePressTarget = target
		chromeBtnDown = true
		if src == "gui" or chromeClaimSource ~= "gui" then
			chromeClaimSource = src
		end
	end
end

local function isUsingGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function readThumbstick1(): Vector2
	local ok, states = pcall(function()
		return UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
	end)
	if not ok or typeof(states) ~= "table" then
		return Vector2.zero
	end
	for _, input in ipairs(states :: { InputObject }) do
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			return Vector2.new(input.Position.X, -input.Position.Y)
		end
	end
	return Vector2.zero
end

local function clampGamepadCursor(pos: Vector2): Vector2
	local cam = Workspace.CurrentCamera
	if not cam then
		return pos
	end
	local vp = cam.ViewportSize
	return Vector2.new(math.clamp(pos.X, 8, vp.X - 8), math.clamp(pos.Y, 8, vp.Y - 8))
end

-- GetMouseLocation is viewport space. Pair with ViewportPointToRay / WorldToViewportPoint.
local function viewportRay(cam: Camera, vp: Vector2): Ray
	return cam:ViewportPointToRay(vp.X, vp.Y)
end

local function worldToViewport(cam: Camera, world: Vector3): (Vector2?, boolean)
	local sp, onScreen = cam:WorldToViewportPoint(world)
	if not onScreen or sp.Z <= 0 then
		return nil, false
	end
	return Vector2.new(sp.X, sp.Y), true
end

local function getPlayerControls(): any
	local ok, playerScripts = pcall(function()
		return player:WaitForChild("PlayerScripts", 2)
	end)
	if not ok or not playerScripts then
		return nil
	end
	local pm = playerScripts:FindFirstChild("PlayerModule")
	if not pm then
		return nil
	end
	local ok2, mod = pcall(require, pm)
	if not ok2 or not mod then
		return nil
	end
	local ok3, controls = pcall(function()
		return mod:GetControls()
	end)
	if ok3 then
		return controls
	end
	return nil
end

local function setTouchControlsEnabled(enabled: boolean)
	pcall(function()
		if enabled then
			GuiService.TouchControlsEnabled = true
			savedTouchControlsEnabled = nil
		else
			if savedTouchControlsEnabled == nil then
				savedTouchControlsEnabled = GuiService.TouchControlsEnabled
			end
			GuiService.TouchControlsEnabled = false
		end
	end)
	local touchGui = playerGui:FindFirstChild("TouchGui")
	if enabled then
		if touchGui and touchGui:IsA("ScreenGui") then
			touchGui.Enabled = true
		end
	end
end

local function clearJumpUnlockWatch()
	if jumpUnlockConn then
		jumpUnlockConn:Disconnect()
		jumpUnlockConn = nil
	end
end

local function isConfirmJumpHeld(): boolean
	if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
		return true
	end
	for _, gp in ipairs(UserInputService:GetConnectedGamepads()) do
		if UserInputService:IsGamepadButtonDown(gp, Enum.KeyCode.ButtonA) then
			return true
		end
	end
	return false
end

local function applySavedJump(hum: Humanoid)
	hum.JumpPower = if savedJumpPower > 0 then savedJumpPower else 75
	hum.JumpHeight = if savedJumpHeight > 0 then savedJumpHeight else 10.8
end

local function unfreeze()
	ContextActionService:UnbindAction(C.FREEZE_ACTION)
	setTouchControlsEnabled(true)
	local controls = getPlayerControls()
	if controls then
		pcall(function()
			controls:Enable()
		end)
	end
	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	if frozen then
		frozen = false
		if hum then
			hum.WalkSpeed = if savedWalkSpeed > 0 then savedWalkSpeed else 16
			-- ✓ / A confirm: restoring jump while A/Space is still held causes a hop.
			if isConfirmJumpHeld() then
				hum.JumpPower = 0
				hum.JumpHeight = 0
				clearJumpUnlockWatch()
				jumpUnlockConn = UserInputService.InputEnded:Connect(function(input)
					if input.KeyCode ~= Enum.KeyCode.ButtonA and input.KeyCode ~= Enum.KeyCode.Space then
						return
					end
					if isConfirmJumpHeld() then
						return
					end
					clearJumpUnlockWatch()
					local h = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
					if h and not active then
						applySavedJump(h)
					end
				end)
			else
				clearJumpUnlockWatch()
				applySavedJump(hum)
			end
		end
		if camera then
			local camType = savedCameraType
			if camType == nil or camType == Enum.CameraType.Scriptable then
				camType = Enum.CameraType.Custom
			end
			camera.CameraType = camType
		end
	end
	savedCameraType = nil
	savedCameraCFrame = nil
end

local function bindFreezeAction()
	ContextActionService:UnbindAction(C.FREEZE_ACTION)
	local sinkKeys: { Enum.KeyCode } = {
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
		Enum.KeyCode.Space,
	}
	if not inspectModal then
		table.insert(sinkKeys, Enum.KeyCode.ButtonA)
	end
	if gamepadRelocate then
		table.insert(sinkKeys, Enum.KeyCode.Thumbstick1)
	end
	ContextActionService:BindActionAtPriority(C.FREEZE_ACTION, function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, table.unpack(sinkKeys))
end

local function freeze()
	if frozen then
		if camera and savedCameraCFrame then
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = savedCameraCFrame
		end
		return
	end
	frozen = true
	clearJumpUnlockWatch()
	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
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
	end
	local controls = getPlayerControls()
	if controls then
		pcall(function()
			controls:Disable()
		end)
	end
	setTouchControlsEnabled(false)
	if camera then
		if camera.CameraType ~= Enum.CameraType.Scriptable then
			savedCameraType = camera.CameraType
		else
			savedCameraType = Enum.CameraType.Custom
		end
		savedCameraCFrame = camera.CFrame
		camera.CameraType = Enum.CameraType.Scriptable
	end
	bindFreezeAction()
end

local function keepCameraFrozen()
	if cinematicHold then
		return
	end
	local cam = Workspace.CurrentCamera
	if cam and savedCameraCFrame then
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = savedCameraCFrame
	end
end

local function pointerScreenPos(): Vector2
	return UserInputService:GetMouseLocation()
end

local function aimScreenPos(): Vector2
	local finger = pointerScreenPos()
	if gamepadRelocate and gamepadCursor then
		return Vector2.new(gamepadCursor.X, gamepadCursor.Y - C.AIM_VISUAL_CENTER_OFFSET_Y)
	end
	if UserInputService:GetLastInputType() == Enum.UserInputType.Touch then
		-- Raise aim so the coral / move icon sit above the thumb (thumb below).
		return Vector2.new(finger.X, finger.Y - C.GHOST_SCREEN_OFFSET_Y)
	end
	-- Mouse: aim above the cursor so the ball center lands on it.
	return Vector2.new(finger.X, finger.Y - C.AIM_VISUAL_CENTER_OFFSET_Y)
end

local function worldToScreen(world: Vector3): Vector2?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	-- IgnoreGuiInset ScreenGui layout space (includes top bar).
	local sp = cam:WorldToScreenPoint(world)
	-- Behind camera only — still use projected X/Y when slightly off the viewport
	-- (tall sponge tip can clip the top edge; falling back to the mouse made Del follow the cursor).
	if sp.Z <= 0 then
		return nil
	end
	return Vector2.new(sp.X, sp.Y)
end

-- Balls: center (screen then lifts ~52px). Sponges: mesh pivot is mid-body — use the top.
local function coralChromeWorldPos(p: BasePart): Vector3
	if CoralVisual.isMeshSpecies(p:GetAttribute("OceanTD_SpeciesId")) then
		return p.Position + Vector3.new(0, p.Size.Y * 0.5, 0)
	end
	return p.Position
end

local function coralChromeScreenLift(p: BasePart): number
	-- Sponges already project from the tip; only a small gap. Balls need the larger lift from center.
	if CoralVisual.isMeshSpecies(p:GetAttribute("OceanTD_SpeciesId")) then
		return 8
	end
	return 52
end

local WAIST_BB_DIST = 28

local function hideWaistChrome()
	if waistBb then
		waistBb.Enabled = false
	end
	if gui then
		if checkBtn then
			checkBtn.Parent = gui
		end
		if cancelBtn then
			cancelBtn.Parent = gui
		end
		if rotLeftBtn then
			rotLeftBtn.Parent = gui
			rotLeftBtn.Visible = false
		end
		if rotRightBtn then
			rotRightBtn.Parent = gui
			rotRightBtn.Visible = false
		end
	end
end

local function isSelectedSeaFan(): boolean
	return part ~= nil and CoralVisual.isSeaFan(part:GetAttribute("OceanTD_SpeciesId"))
end

local function isSelectedBrain(): boolean
	return part ~= nil and BrainStack.isBrainId(part:GetAttribute("OceanTD_SpeciesId"))
end

local function layoutWaistChrome(btnPx: number, showCheck: boolean): boolean
	if not checkBtn or not cancelBtn or not gui then
		hideWaistChrome()
		return false
	end
	local showRot = ((isSelectedSeaFan() or (isSelectedBrain() and BrainSnapPreview.isSnapped())) and not recyclePending)
	local bb, adornee = PlaceConfirmChrome.layoutOnTorso(
		btnPx,
		playerGui,
		gui,
		waistBb,
		waistAdornee,
		checkBtn,
		cancelBtn,
		rotLeftBtn,
		rotRightBtn,
		showRot
	)
	waistBb = bb
	waistAdornee = adornee
	return bb ~= nil and adornee ~= nil
end

local function destroyUi()
	PlaceConfirmChrome.stopRotateHold()
	uiSession += 1
	if moveBillboard then
		moveBillboard:Destroy()
		moveBillboard = nil
	end
	moveIcon = nil
	if moveAdorneePart then
		moveAdorneePart:Destroy()
		moveAdorneePart = nil
	end
	if waistBb then
		waistBb:Destroy()
		waistBb = nil
	end
	if waistAdornee then
		waistAdornee:Destroy()
		waistAdornee = nil
	end
	if gui then
		gui:Destroy()
		gui = nil
	end
	checkBtn = nil
	cancelBtn = nil
	rotLeftBtn = nil
	rotRightBtn = nil
	recycleBtn = nil
	recycleIcon = nil
	recyclePlus = nil
end

local function makeUi()
	destroyUi()
	local g = Instance.new("ScreenGui")
	g.Name = "OceanTD_RelocateConfirm"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.ClipToDeviceSafeArea = false
	pcall(function()
		(g :: any).ScreenInsets = Enum.ScreenInsets.None
	end)
	g.DisplayOrder = 12010
	g.Parent = playerGui
	gui = g

	local function roundBtn(text: string, color: Color3, sizePx: number): TextButton
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(sizePx, sizePx)
		b.BackgroundColor3 = color
		b.BackgroundTransparency = 0 -- opaque so the whole disc is clickable (not just text)
		b.BorderSizePixel = 0
		b.Font = UiTheme.Font
		b.Text = text
		b.TextColor3 = Color3.new(1, 1, 1)
		b.TextScaled = true
		b.AutoButtonColor = true
		b.Active = true
		b.Visible = false
		b.ZIndex = 5
		b.Parent = g
		UiCircles.ensure(b)
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.12, 0)
		pad.PaddingBottom = UDim.new(0.12, 0)
		pad.PaddingLeft = UDim.new(0.06, 0)
		pad.PaddingRight = UDim.new(0.06, 0)
		pad.Parent = b
		local edge = Instance.new("UIStroke")
		edge.Color = Color3.new(1, 1, 1)
		edge.Thickness = 2
		edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		edge.Parent = b
		return b
	end

	checkBtn = roundBtn("✓", Color3.fromRGB(40, 180, 80), C.BTN_SIZE)
	cancelBtn = roundBtn("X", Color3.fromRGB(200, 50, 50), C.BTN_SIZE)
	checkBtn.ZIndex = 10
	cancelBtn.ZIndex = 10
	rotLeftBtn = PlaceConfirmChrome.createRotateButton(g, PlaceConfirmChrome.ROT_LEFT_ICON, "RotLeft")
	rotRightBtn = PlaceConfirmChrome.createRotateButton(g, PlaceConfirmChrome.ROT_RIGHT_ICON, "RotRight")
	rotLeftBtn.ZIndex = 5
	rotRightBtn.ZIndex = 5

	recycleBtn = roundBtn("", C.REC_GREEN, C.REC_BTN_SIZE)
	recycleBtn.Name = "Recycle"
	recycleBtn.AutoButtonColor = false
	local recIcon = Instance.new("ImageLabel")
	recIcon.Name = "Icon"
	recIcon.BackgroundTransparency = 1
	recIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	recIcon.Position = UDim2.fromScale(0.5, 0.5)
	recIcon.Size = UDim2.fromScale(0.62, 0.62)
	recIcon.Image = C.RECYCLE_ICON_IMAGE
	recIcon.ScaleType = Enum.ScaleType.Fit
	recIcon.ZIndex = 6
	recIcon.Active = false
	recIcon.Parent = recycleBtn
	recycleIcon = recIcon

	local plus = Instance.new("TextLabel")
	plus.Name = "PlusOne"
	plus.BackgroundTransparency = 1
	plus.AnchorPoint = Vector2.new(0.5, 0.5)
	plus.Position = UDim2.fromScale(0.5, 0.5)
	plus.Size = UDim2.fromScale(0.9, 0.9)
	plus.Font = UiTheme.Font
	plus.Text = "+1"
	plus.TextColor3 = Color3.new(1, 1, 1)
	plus.TextScaled = true
	plus.ZIndex = 6
	plus.Visible = false
	plus.Active = false
	plus.Parent = recycleBtn
	recyclePlus = plus

	local function markDown(claimed: string?)
		local screenPos = UserInputService:GetMouseLocation()
		local resolved = PlaceConfirmHitTest.resolveTarget(screenPos, checkBtn, cancelBtn, playerGui, rotLeftBtn, rotRightBtn)
		local target: string? = nil
		-- Trust ✓/X when they received the press; rot below often shares AbsolutePosition discs.
		if claimed == "check" or claimed == "cancel" or claimed == "recycle" then
			target = claimed
		elseif resolved == "check" or resolved == "cancel" then
			target = resolved
		elseif resolved == "rotLeft" or resolved == "rotRight" then
			target = resolved
		elseif claimed == "rotLeft" and PlaceConfirmHitTest.isOverGui(screenPos, rotLeftBtn) then
			target = "rotLeft"
		elseif claimed == "rotRight" and PlaceConfirmHitTest.isOverGui(screenPos, rotRightBtn) then
			target = "rotRight"
		elseif resolved then
			target = resolved
		else
			return
		end
		claimChromeTarget(target, if claimed ~= nil then "gui" else "uis")
		fingerDown = false
		pressOrigin = nil
		dragging = false
		grabFromMoveIcon = false
		if target == "rotLeft" or target == "rotRight" then
			local dir = if target == "rotLeft" then 1 else -1
			local btn = if target == "rotLeft" then rotLeftBtn else rotRightBtn
			PlaceConfirmChrome.beginRotateHold(btn, function()
				if BrainSnapPreview.isSnapped() then
					rotateBrainSnapOrbit(dir)
				else
					rotateSelectedSeaFan(dir)
				end
			end)
		else
			PlaceConfirmChrome.stopRotateHold()
		end
	end
	checkBtn.MouseButton1Down:Connect(function()
		markDown("check")
	end)
	cancelBtn.MouseButton1Down:Connect(function()
		markDown("cancel")
	end)
	rotLeftBtn.MouseButton1Down:Connect(function()
		markDown("rotLeft")
	end)
	rotRightBtn.MouseButton1Down:Connect(function()
		markDown("rotRight")
	end)
	recycleBtn.MouseButton1Down:Connect(function()
		markDown("recycle")
	end)
	checkBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			markDown("check")
		end
	end)
	cancelBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			markDown("cancel")
		end
	end)
	rotLeftBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			markDown("rotLeft")
		end
	end)
	rotRightBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			markDown("rotRight")
		end
	end)
	recycleBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			markDown("recycle")
		end
	end)
	-- Same path as Enter → commit. Hit-test InputEnded often maps Confirm → Cancel on billboards.
	checkBtn.Activated:Connect(function()
		if not active or busy then
			return
		end
		chromeBtnDown = false
		chromePressTarget = nil
		chromeClaimSource = nil
		RelocateController.commit()
	end)
	cancelBtn.Activated:Connect(function()
		if not active or busy then
			return
		end
		chromeBtnDown = false
		chromePressTarget = nil
		chromeClaimSource = nil
		RelocateController.cancel()
	end)
	recycleBtn.Activated:Connect(function()
		if not active or busy or recyclePending then
			return
		end
		chromeBtnDown = false
		chromePressTarget = nil
		chromeClaimSource = nil
		RelocateController.beginRecycleConfirm()
	end)
end

local MOVE_ICON_GROUND_LIFT = 0.9 -- studs above plant point so the handle isn't buried in sand

local function moveIconInspectDropStuds(p: BasePart): number
	if CoralVisual.isMeshSpecies(p:GetAttribute("OceanTD_SpeciesId")) then
		return math.clamp(p.Size.Y * 0.42 + 2.2, 3.5, 14)
	end
	return math.clamp(p.Size.Y * 0.5 + 2.4, 3, 12)
end

local function stopMoveIconDropTween()
	if moveIconDropTweenConn then
		moveIconDropTweenConn:Disconnect()
		moveIconDropTweenConn = nil
	end
end

local function syncMoveIconToGround()
	if not moveBillboard or not part then
		return
	end
	local anchor = moveGridAnchor or gridAnchorPos or CoralVisual.readGridAnchor(part) or part.Position
	local drop = moveIconInspectDropStuds(part) * moveIconInspectBlend
	local yOff = MOVE_ICON_GROUND_LIFT - drop
	local world = Vector3.new(anchor.X, anchor.Y + yOff, anchor.Z)
	local adornee = moveAdorneePart
	if adornee and adornee.Parent then
		adornee.CFrame = CFrame.new(world)
		moveBillboard.Adornee = adornee
		moveBillboard.StudsOffset = Vector3.zero
		moveBillboard.StudsOffsetWorldSpace = Vector3.zero
	elseif CoralVisual.isMeshSpecies(part:GetAttribute("OceanTD_SpeciesId")) then
		-- Fallback: offset from mesh center to plant point.
		moveBillboard.StudsOffsetWorldSpace = world - part.Position
		moveBillboard.StudsOffset = Vector3.zero
	else
		moveBillboard.StudsOffsetWorldSpace = Vector3.zero
		moveBillboard.StudsOffset = Vector3.new(0, yOff, 0)
	end
	moveBillboard.Enabled = true
	if moveIcon then
		moveIcon.Visible = true
		-- Recover if intro tween was interrupted while still tiny.
		if not introAnimating then
			local sc = moveIcon:FindFirstChild("IntroScale")
			if sc and sc:IsA("UIScale") and sc.Scale < 0.5 then
				sc.Scale = 1
			end
		end
	end
end

local function tweenMoveIconInspectBlend(target: number)
	stopMoveIconDropTween()
	local from = moveIconInspectBlend
	if math.abs(from - target) < 0.001 then
		moveIconInspectBlend = target
		syncMoveIconToGround()
		return
	end
	local t0 = os.clock()
	moveIconDropTweenConn = RunService.RenderStepped:Connect(function()
		if not active or not part then
			stopMoveIconDropTween()
			return
		end
		local u = math.clamp((os.clock() - t0) / C.MOVE_ICON_INSPECT_DROP_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		moveIconInspectBlend = from + (target - from) * a
		syncMoveIconToGround()
		if u >= 1 then
			moveIconInspectBlend = target
			stopMoveIconDropTween()
			syncMoveIconToGround()
		end
	end)
end

local function attachMoveIcon(adornee: BasePart)
	if moveBillboard then
		moveBillboard:Destroy()
		moveBillboard = nil
	end
	moveIcon = nil
	if moveAdorneePart then
		moveAdorneePart:Destroy()
		moveAdorneePart = nil
	end

	local anchorPart = Instance.new("Part")
	anchorPart.Name = "OceanTD_RelocateMoveAdornee"
	anchorPart.Anchored = true
	anchorPart.CanCollide = false
	anchorPart.CanQuery = false
	anchorPart.CanTouch = false
	anchorPart.CastShadow = false
	anchorPart.Transparency = 1
	anchorPart.Size = Vector3.new(0.25, 0.25, 0.25)
	anchorPart.Parent = adornee.Parent or Workspace
	moveAdorneePart = anchorPart

	local bb = Instance.new("BillboardGui")
	bb.Name = "OceanTD_RelocateMove"
	bb.AlwaysOnTop = true
	-- Active so a press on the handle is a GUI hit; InputBegan still starts the drag.
	bb.Active = true
	bb.Enabled = true
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(C.MOVE_ICON_SIZE, C.MOVE_ICON_SIZE)
	bb.MaxDistance = 2000
	bb.Adornee = anchorPart
	bb.Parent = playerGui
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Image = C.MOVE_ICON_IMAGE
	img.ScaleType = Enum.ScaleType.Fit
	img.Active = true
	img.Visible = true
	img.Parent = bb
	local scale = Instance.new("UIScale")
	scale.Name = "IntroScale"
	scale.Scale = 1
	scale.Parent = img
	moveBillboard = bb
	moveIcon = img
	syncMoveIconToGround()
end

local function findBlockingCoral(worldPos: Vector3, ignorePart: BasePart?): BasePart?
	local plot = ClientPlot.get()
	if not plot then
		return nil
	end
	return PlacedCoralIndex.getAtWorld(plot.plotId, worldPos, plot.cframe, ignorePart)
end

local function sameGrid(a: Vector3, b: Vector3): boolean
	local plot = ClientPlot.get()
	if not plot then
		return false
	end
	local la = GridMath.worldToPlotLocal(a, plot.cframe)
	local lb = GridMath.worldToPlotLocal(b, plot.cframe)
	local ax, ay, az = GridMath.worldToGrid(la, Vector3.zero)
	local bx, by, bz = GridMath.worldToGrid(lb, Vector3.zero)
	return ax == bx and ay == by and az == bz
end

local function resolveRelocatePos(worldPos: Vector3): Vector3
	if not part or not BrainStack.isBrainId(part:GetAttribute("OceanTD_SpeciesId")) then
		BrainSnapPreview.setVisible(false)
		return worldPos
	end
	local diam = BrainStack.diameterOfPart(part)
	BrainSnapPreview.setVisible(true)
	return PlaceRaycast.resolveBrainStackPos(worldPos, diam, part, aimScreenPos())
end

local function evaluate(worldPos: Vector3): (boolean, string?)
	if not ClientPlot.isInside(worldPos) then
		return false, "Out Of Plot"
	end
	if originPos and sameGrid(worldPos, originPos) then
		return true, nil
	end
	local blocker = findBlockingCoral(worldPos, part)
	if blocker then
		if part
			and BrainStack.isBrainId(part:GetAttribute("OceanTD_SpeciesId"))
			and BrainStack.isBrainId(blocker:GetAttribute("OceanTD_SpeciesId"))
			and worldPos.Y > blocker.Position.Y + 0.25
		then
			return true, nil
		end
		return false, "Spot Taken"
	end
	return true, nil
end

local function clearBlockHighlight()
	if blockPart and blockPart.Parent then
		if blockBaseMaterial then
			blockPart.Material = blockBaseMaterial
		end
		if blockBaseColor then
			blockPart.Color = blockBaseColor
		end
	end
	blockPart = nil
	blockBaseMaterial = nil
	blockBaseColor = nil
end

local function setBlockHighlight(target: BasePart?)
	if blockPart == target then
		return
	end
	clearBlockHighlight()
	if not target or not target.Parent or target == part then
		return
	end
	-- If hover neon is on this coral, restore first so we don't save Neon as the base.
	if RelocatePickHover.getHoverPart() == target then
		clearHover()
	end
	local restMat, restColor = CoralVisual.readRestLook(target)
	CoralVisual.applyRestLook(target)
	blockPart = target
	blockBaseMaterial = restMat
	blockBaseColor = restColor
	-- Solid red neon — stationary blocker (does not flash).
	target.Material = Enum.Material.Neon
	target.Color = Color3.fromRGB(255, 45, 45)
end

local function ensureWarnBillboard(parent: BasePart)
	if warnLabel and warnLabel.Parent then
		local bb = warnLabel.Parent
		if bb:IsA("BillboardGui") and bb.Parent == parent then
			return
		end
		bb:Destroy()
		warnLabel = nil
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "RelocateWarn"
	bb.Size = UDim2.fromOffset(160, 28)
	bb.StudsOffset = Vector3.new(0, 2.2, 0)
	bb.AlwaysOnTop = true
	bb.Parent = parent
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 0.35
	lbl.BackgroundColor3 = Color3.fromRGB(40, 10, 10)
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = UiTheme.Font
	lbl.TextColor3 = Color3.fromRGB(255, 220, 220)
	lbl.TextScaled = true
	lbl.Text = ""
	lbl.Visible = false
	lbl.Parent = bb
	warnLabel = lbl
end

local function syncWarnLabel()
	if not warnLabel then
		return
	end
	if validSpot or not rejectReason then
		warnLabel.Text = ""
		warnLabel.Visible = false
	else
		warnLabel.Text = rejectReason
		warnLabel.Visible = true
	end
end

local function raycastTerrain(screenPos: Vector2): Vector3?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local ray = viewportRay(cam, screenPos)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	local placed = Workspace:FindFirstChild("OceanTD_Placed")
	if placed then
		table.insert(exclude, placed)
	end
	if player.Character then
		table.insert(exclude, player.Character)
	end
	params.FilterDescendantsInstances = exclude
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 800, params)
	if result then
		return result.Position
	end
	local plot = ClientPlot.get()
	if plot then
		local origin = plot.cframe.Position
		local t = (origin.Y - ray.Origin.Y) / ray.Direction.Y
		if t == t and t > 0 then
			return ray.Origin + ray.Direction * t
		end
	end
	return nil
end

local function pickPlacedCoral(screenPos: Vector2): BasePart?
	return RelocatePickHover.pick(screenPos)
end

local function pointerHitsSelectedCoral(screenPos: Vector2): boolean
	return RelocatePickHover.pointerHitsSelected(screenPos)
end

local function stopHoverLoop()
	RelocatePickHover.stopLoop()
end

local function startHoverLoop()
	RelocatePickHover.startLoop()
end

local function syncChrome()
	if recycleFlying or confirmOutroPlaying then
		return
	end
	-- Intro owns recycle tween; still sync ✓ once the coral has been moved.
	if introAnimating and not hasMoved and not recyclePending then
		return
	end
	if not active or not part or not checkBtn or not cancelBtn then
		return
	end
	local screen = worldToScreen(coralChromeWorldPos(part))
	if not screen then
		-- Tip can fail if behind camera; try body center before any soft fallback.
		screen = worldToScreen(part.Position)
	end
	if not screen then
		screen = lastChromeScreen
	end
	if not screen then
		-- Last resort: leave chrome where it already is (never pin to the mouse).
		return
	end
	lastChromeScreen = screen
	local cx = screen.X
	local cy = screen.Y - coralChromeScreenLift(part)

	if recycleSlideActive then
		local u = math.clamp((os.clock() - recycleSlideT0) / C.REC_SLIDE_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		recycleSlideU = a
		if u >= 1 then
			recycleSlideActive = false
			recycleSlideU = 1
		end
	end

	-- Idle close (exit tool): keyboard/mouse instantly; gamepad after 3s.
	-- After a move / recycle confirm: always show cancel for that action.
	local idleCloseReady = (not gamepadRelocate) or ((os.clock() - relocateShownAt) >= C.IDLE_CLOSE_DELAY_SEC)
	local showIdleClose = (not hasMoved) and (not hasRotated) and (not recyclePending) and idleCloseReady
	local showCancel = hasMoved or recyclePending or showIdleClose
	cancelBtn.Visible = showCancel
	local tipLetter = if gamepadRelocate then "B" else "X"
	local showWord = (math.floor((os.clock() - gamepadChromeT0) / C.HOVER_HINT_PERIOD) % 2) == 1
	-- Recycle confirm: ✓/X over the avatar waist (same as move cancel), not coral tip.
	checkBtn.Visible = (hasMoved and validSpot) or hasRotated or recyclePending

	-- Keep button size fixed — shrinking on rotate made the whole chrome jump.
	layoutWaistChrome(C.BTN_SIZE, checkBtn.Visible)
	if recyclePending then
		if rotLeftBtn then
			rotLeftBtn.Visible = false
		end
		if rotRightBtn then
			rotRightBtn.Visible = false
		end
	end
	cancelBtn.Text = if showWord then (if hasMoved or hasRotated or recyclePending then "CANCEL" else "CLOSE") else tipLetter
	cancelBtn.TextStrokeColor3 = if showWord then Color3.fromRGB(60, 15, 18) else Color3.new(1, 1, 1)
	cancelBtn.TextStrokeTransparency = 0

	if checkBtn.Visible then
		checkBtn.Active = true
		checkBtn.BackgroundTransparency = 0
		checkBtn.TextColor3 = Color3.new(1, 1, 1)
		PlaceConfirmChrome.syncConfirmFace(checkBtn, showWord, isUsingGamepad())
		-- Flash dark green ↔ bright green (same as place confirm).
		local phase = (math.sin(os.clock() * 6) + 1) * 0.5
		checkBtn.BackgroundColor3 = Color3.fromRGB(90, 255, 120):Lerp(Color3.fromRGB(35, 85, 45), phase)
	end

	if recycleBtn then
		-- Hide recycle while dragging a move / rotating; show again after confirm, or during recycle confirm.
		local showRecycle = (not hasMoved and not hasRotated) or recyclePending
		-- Coral inspect UI owns the recycle affordance; hide the in-world one while idle.
		if inspectPanelVisible and not recyclePending then
			showRecycle = false
		end
		recycleBtn.Visible = showRecycle
		if showRecycle then
			recycleBtn.AnchorPoint = Vector2.new(0.5, 1)
			recycleBtn.Size = UDim2.fromOffset(C.REC_BTN_SIZE, C.REC_BTN_SIZE)
			-- Park recycle above feet chrome (avatar), not coral tip.
			local waistScreen = PlaceConfirmChrome.screenPos(waistAdornee)
			local chromePx = PlaceConfirmChrome.chromeBtnSize(C.BTN_SIZE)
			local recCx = waistScreen.X
			local recCy = waistScreen.Y - chromePx - C.REC_GAP_PX
			-- Idle (not moved): sit near where X will appear. Recycle confirm: above ✓/X pair.
			local aboveX = recCx + 6 + chromePx * 0.5
			local abovePair = recCx
			local idleRecX = aboveX
			local idleRecY = waistScreen.Y
			local movedRecX = aboveX + (abovePair - aboveX) * recycleSlideU
			local movedRecY = recCy
			local recX = if recyclePending then movedRecX else idleRecX
			local recY = if recyclePending then movedRecY else idleRecY
			-- When idle with inspect hidden, tip-aligned recycle is owned by older path —
			-- keep tip coords for idle non-inspect so existing feel stays; feet only for confirm.
			if not recyclePending then
				recX = cx + 6 + chromePx * 0.5
				recY = cy
			end
			recycleBtn.Position = UDim2.fromOffset(recX, recY)

			if recyclePending then
				local age = os.clock() - recycleSlideT0
				local pulse = (math.floor(age * C.REC_FLASH_HZ) % 2) == 0
				recycleBtn.BackgroundColor3 = if pulse then C.REC_GREEN else C.REC_GREEN_DIM
				local showPlus = (math.floor(age / C.REC_LABEL_PERIOD) % 2) == 1
				if recycleIcon then
					recycleIcon.Visible = not showPlus
				end
				if recyclePlus then
					recyclePlus.Text = "+1"
					recyclePlus.Visible = showPlus
				end
			else
				recycleBtn.BackgroundColor3 = C.REC_GREEN
				-- Touch: icon ↔ COLLECT (no Del). Keyboard/gamepad: icon → Del/L1 → COLLECT.
				local showShortcut = isUsingGamepad() or not UserInputService.TouchEnabled
				local phaseCount = if showShortcut then 3 else 2
				local phase = math.floor((os.clock() - gamepadChromeT0) / C.HOVER_HINT_PERIOD) % phaseCount
				if recycleIcon then
					recycleIcon.Visible = phase == 0
				end
				if recyclePlus then
					if showShortcut then
						if phase == 1 then
							recyclePlus.Text = if isUsingGamepad() then "L1" else "Del"
							recyclePlus.Visible = true
						elseif phase == 2 then
							recyclePlus.Text = "COLLECT"
							recyclePlus.Visible = true
						else
							recyclePlus.Visible = false
						end
					elseif phase == 1 then
						recyclePlus.Text = "COLLECT"
						recyclePlus.Visible = true
					else
						recyclePlus.Visible = false
					end
				end
			end
		end
	end
end

local function updateAt(worldPos: Vector3)
	if recyclePending then
		return
	end
	if cinematicHold then
		return
	end
	if not part or not originPos then
		return
	end
	local surfacePos = resolveRelocatePos(worldPos)
	if CoralVisual.needsFacingYaw(part:GetAttribute("OceanTD_SpeciesId")) then
		if typeof(relocateFacingYaw) ~= "number" then
			relocateFacingYaw = CoralVisual.readFacingYaw(part)
		end
		local mir = ClientPlot.get()
		CoralVisual.alignMeshToSurface(part, surfacePos, relocateFacingYaw, nil, if mir then mir.cframe else nil)
		moveGridAnchor = surfacePos
	elseif CoralVisual.isMeshSpecies(part:GetAttribute("OceanTD_SpeciesId")) then
		CoralVisual.alignMeshToSurface(part, surfacePos)
		moveGridAnchor = surfacePos
	else
		part.CFrame = CFrame.new(surfacePos)
		moveGridAnchor = surfacePos
	end
	syncMoveIconToGround()
	local ok, reason = evaluate(surfacePos)
	validSpot = ok
	rejectReason = reason
	local homeAnchor = gridAnchorPos or originPos
	if not sameGrid(surfacePos, homeAnchor) then
		hasMoved = true
		tweenMoveIconInspectBlend(0)
	end
	if validSpot or rejectReason ~= "Spot Taken" then
		clearBlockHighlight()
	else
		setBlockHighlight(findBlockingCoral(surfacePos, part))
	end
	ClientPlot.setOutOfPlotFlash(rejectReason == "Out Of Plot")
	syncWarnLabel()
	syncChrome()
end

rotateSelectedSeaFan = function(dir: number)
	if recyclePending or not part or not part.Parent then
		return
	end
	if not CoralVisual.isSeaFan(part:GetAttribute("OceanTD_SpeciesId")) then
		return
	end
	local yaw = relocateFacingYaw
	if typeof(yaw) ~= "number" then
		yaw = CoralVisual.readFacingYaw(part)
	end
	yaw += dir * C.SEA_FAN_ROT_STEP
	relocateFacingYaw = yaw
	hasRotated = true
	local anchor = moveGridAnchor or gridAnchorPos or CoralVisual.readGridAnchor(part) or part.Position
	local mir = ClientPlot.get()
	CoralVisual.alignMeshToSurface(part, anchor, yaw, nil, if mir then mir.cframe else nil)
	UiHaptics.pulseShort()
	syncChrome()
end

rotateBrainSnapOrbit = function(dir: number)
	if recyclePending or not part or not part.Parent then
		return
	end
	if not BrainStack.isBrainId(part:GetAttribute("OceanTD_SpeciesId")) then
		return
	end
	local diam = BrainStack.diameterOfPart(part)
	if BrainSnapPreview.nudgeOrbit(dir, diam, part) then
		local snap = BrainSnapPreview.getActive()
		if snap then
			part.CFrame = CFrame.new(snap.worldPos)
			moveGridAnchor = snap.worldPos
			gridAnchorPos = snap.worldPos
		end
		UiHaptics.pulseShort()
		syncChrome()
	end
end

local function restorePartLook(p: BasePart?)
	if not p or not p.Parent then
		return
	end
	local look = RelocateMultiSelect.getLook(p)
	if look then
		p.Material = look.material
		p.Color = look.color
		return
	end
	if p == part and baseMaterial and baseColor then
		p.Material = baseMaterial
		p.Color = baseColor
	else
		CoralVisual.applyRestLook(p)
	end
end

local function updateRelocateFlash()
	if not part or not part.Parent or not baseColor then
		return
	end
	if showPaintSolid and validSpot then
		-- After a color pick, show the real paint (no white neon wash).
		if baseMaterial then
			part.Material = baseMaterial
		end
		part.Color = baseColor
	else
		part.Material = Enum.Material.Neon
		if validSpot then
			-- Flash neon in this coral's color while the move tool is open.
			local pulse = 0.5 + 0.5 * math.sin(os.clock() * 9)
			part.Color = baseColor:Lerp(Color3.new(1, 1, 1), 0.12 + 0.28 * pulse)
		else
			-- Moving coral: red/white neon when the cell is invalid.
			local pulse = (math.sin(os.clock() * 12) + 1) * 0.5
			part.Color = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(255, 45, 45), pulse)
		end
	end
	-- Keep blocker solid red neon (do not pulse it).
	if blockPart and blockPart.Parent then
		blockPart.Material = Enum.Material.Neon
		blockPart.Color = Color3.fromRGB(255, 45, 45)
	end
	SelectRing.ensure(selectRing, part, playerGui)
	SelectRing.pulse(selectRing)
	RelocateMultiSelect.pulse()
end

local function stopLoop()
	if loopConn then
		loopConn:Disconnect()
		loopConn = nil
	end
end

local function startLoop()
	stopLoop()
	loopConn = RunService.RenderStepped:Connect(function(dt)
		if not active then
			return
		end
		keepCameraFrozen()
		updateRelocateFlash()
		syncMoveIconToGround()
		if gamepadRelocate and not busy and not recyclePending and not introAnimating and not recycleFlying then
			local stick = readThumbstick1()
			local mag = stick.Magnitude
			if mag > C.GAMEPAD_STICK_DEADZONE then
				local screen = if part then worldToViewport(Workspace.CurrentCamera :: Camera, coralChromeWorldPos(part)) else nil
				if not gamepadCursor then
					gamepadCursor = screen or UserInputService:GetMouseLocation()
				end
				local dir = stick.Unit
				local speed = C.GAMEPAD_AIM_SPEED * math.clamp((mag - C.GAMEPAD_STICK_DEADZONE) / (1 - C.GAMEPAD_STICK_DEADZONE), 0, 1)
				gamepadCursor = clampGamepadCursor(gamepadCursor + dir * speed * dt)
				local pos = raycastTerrain(aimScreenPos())
				if pos then
					updateAt(pos)
				end
			end
		end
		syncChrome()
	end)
end

local function playIntro(fromScreen: Vector2)
	if not recycleBtn then
		introAnimating = false
		syncChrome()
		return
	end
	introAnimating = true
	-- Cancel stays hidden until the coral actually moves.
	if cancelBtn then
		cancelBtn.Visible = false
	end
	local moveScale = if moveIcon then moveIcon:FindFirstChild("IntroScale") else nil
	if moveScale and moveScale:IsA("UIScale") then
		moveScale.Scale = 0.05
	end
	local recScale: UIScale? = nil
	recycleBtn.Visible = true
	if inspectPanelVisible then
		recycleBtn.Visible = false
	end
	recycleBtn.AnchorPoint = Vector2.new(0.5, 0.5)
	recycleBtn.Position = UDim2.fromOffset(fromScreen.X, fromScreen.Y)
	recycleBtn.Size = UDim2.fromOffset(C.REC_BTN_SIZE, C.REC_BTN_SIZE)
	recycleBtn.BackgroundColor3 = C.REC_GREEN
	recScale = Instance.new("UIScale")
	recScale.Scale = 0.05
	recScale.Parent = recycleBtn

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		if not active then
			conn:Disconnect()
			introAnimating = false
			return
		end
		keepCameraFrozen()
		if inspectPanelVisible and recycleBtn then
			recycleBtn.Visible = false
		end
		local u = math.clamp((os.clock() - t0) / C.INTRO_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		if moveScale and moveScale.Parent then
			moveScale.Scale = 0.05 + 0.95 * a
		end
		if recScale and recScale.Parent then
			recScale.Scale = 0.05 + 0.95 * a
		end
		local screen = if part then worldToScreen(coralChromeWorldPos(part)) else fromScreen
		if not screen then
			screen = fromScreen
		end
		if recycleBtn then
			local cx = screen.X
			local lift = if part then coralChromeScreenLift(part) else 52
			local cy = screen.Y - lift
			-- End: recycle where X will sit (right of coral).
			local recEnd = Vector2.new(cx + 6 + PlaceConfirmChrome.chromeBtnSize(C.BTN_SIZE) * 0.5, cy - C.REC_BTN_SIZE * 0.5)
			local rpos = fromScreen:Lerp(recEnd, a)
			recycleBtn.AnchorPoint = Vector2.new(0.5, 0.5)
			recycleBtn.Position = UDim2.fromOffset(rpos.X, rpos.Y)
		end
		if u >= 1 then
			conn:Disconnect()
			if moveScale and moveScale.Parent then
				moveScale.Scale = 1
			end
			if recScale and recScale.Parent then
				recScale:Destroy()
			end
			introAnimating = false
			syncChrome()
		end
	end)
end

local function clearState()
	BrainSnapPreview.hide()
	clearBlockHighlight()
	ClientPlot.setOutOfPlotFlash(false)
	RelocateMultiSelect.clear(true)
	RelocateMultiSelect.clearPendingInput()
	SelectRing.destroy(selectRing)
	if warnLabel then
		local bb = warnLabel.Parent
		warnLabel = nil
		if bb then
			bb:Destroy()
		end
	end
	stopLoop()
	destroyUi()
	active = false
	busy = false
	introAnimating = false
	gamepadRelocate = false
	gamepadCursor = nil
	part = nil
	originPos = nil
	gridAnchorPos = nil
	moveGridAnchor = nil
	lastChromeScreen = nil
	placeId = ""
	itemId = nil
	baseColor = nil
	baseMaterial = nil
	showPaintSolid = false
	hasMoved = false
	hasRotated = false
	relocateFacingYaw = nil
	originFacingYaw = nil
	validSpot = true
	rejectReason = nil
	recyclePending = false
	recycleFlying = false
	recycleSlideU = 0
	recycleSlideActive = false
	chromeBtnDown = false
	chromePressTarget = nil
	chromeClaimSource = nil
	confirmOutroPlaying = false
	confirmOutroTween = nil
	confirmOutroDone = true
	fingerDown = false
	pressOrigin = nil
	dragging = false
	grabFromMoveIcon = false
	RelocateMultiSelect.clearPendingInput()
	cinematicHold = false
	stopMoveIconDropTween()
	moveIconInspectBlend = 0
	inspectModal = false
	unfreeze()
	activeChanged:Fire(false, nil)
end

function RelocateController.isActive(): boolean
	return active
end

function RelocateController.getSelectedPart(): BasePart?
	return part
end

function RelocateController.getSelectedParts(): { BasePart }
	return RelocateMultiSelect.getParts(part)
end

function RelocateController.isMultiSelect(): boolean
	return RelocateMultiSelect.isMulti()
end

function RelocateController.isPartSelected(p: BasePart): boolean
	return RelocateMultiSelect.isSelected(p, part)
end

function RelocateController.tryRestoreSelectionUndo(): boolean
	return RelocateMultiSelect.tryRestoreUndo()
end

function RelocateController.onActiveChanged(cb: (boolean, BasePart?) -> ()): RBXScriptConnection
	return activeChanged.Event:Connect(cb)
end

function RelocateController.setCinematicHold(on: boolean)
	cinematicHold = on
	if on then
		busy = true
	else
		busy = false
	end
end

function RelocateController.setInspectModal(on: boolean)
	inspectModal = on
	if frozen then
		bindFreezeAction()
	end
end

function RelocateController.setInspectPanelVisible(on: boolean)
	inspectPanelVisible = on
	-- Hide the idle recycle button above the coral while the inspect UI owns recycle.
	if on and recycleBtn then
		recycleBtn.Visible = false
	end
	if not on then
		tweenMoveIconInspectBlend(0)
		syncChrome()
	end
end

function RelocateController.setHueColorEditing(on: boolean)
	if on then
		tweenMoveIconInspectBlend(1)
	else
		tweenMoveIconInspectBlend(0)
	end
end

function RelocateController.setR1WhileActiveHandler(cb: (() -> boolean)?)
	r1WhileActive = cb
end

function RelocateController.setAWhileIdleHandler(cb: (() -> boolean)?)
	aWhileIdle = cb
end

-- After inspect paints a new rest color, drop white neon and show the real paint.
function RelocateController.syncPartRestColor(p: BasePart)
	if not p or not p.Parent then
		return
	end
	CoralVisual.applyRestLook(p)
	local restMat, restColor = CoralVisual.readRestLook(p)
	RelocateMultiSelect.noteLook(p)
	RelocateMultiSelect.setPaintSolid(p, true)
	if p == part then
		showPaintSolid = true
		baseMaterial = restMat
		baseColor = restColor
	end
end

function RelocateController.syncSelectedRestColor()
	if part then
		RelocateController.syncPartRestColor(part)
	end
end

function RelocateController.notePartRestLook(p: BasePart)
	RelocateMultiSelect.noteLook(p)
	if p == part then
		local restMat, restColor = CoralVisual.readRestLook(p)
		baseMaterial = restMat
		baseColor = restColor
	end
end

function RelocateController.isMoveConfirmUp(): boolean
	return active == true and (hasMoved == true or hasRotated == true or recyclePending == true)
end

function RelocateController.getSavedCameraCFrame(): CFrame?
	return savedCameraCFrame
end

function RelocateController.setLiveCameraCFrame(cf: CFrame)
	local cam = Workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = cf
	end
end

function RelocateController.refreshSizedPart(newPart: BasePart, oldPart: BasePart?)
	if not active or not newPart.Parent then
		return
	end
	local priorPart = part
	local newPid = newPart:GetAttribute("OceanTD_PlaceId")
	local rebindOld = oldPart
	if not rebindOld and newPart ~= priorPart and priorPart then
		local curPid = priorPart:GetAttribute("OceanTD_PlaceId")
		if typeof(newPid) == "string" and newPid ~= "" and newPid == curPid then
			rebindOld = priorPart
		end
	end
	if typeof(newPid) == "string" and newPid ~= "" and newPid == placeId then
		part = newPart
	end
	if rebindOld and rebindOld ~= newPart then
		RelocateMultiSelect.rebindPart(rebindOld, newPart)
	end
	local restMat, restColor = CoralVisual.readRestLook(newPart)
	if newPart == part then
		gridAnchorPos = CoralVisual.readGridAnchor(newPart) or newPart.Position
		originPos = gridAnchorPos
		moveGridAnchor = gridAnchorPos
		baseMaterial = restMat
		baseColor = restColor
		SelectRing.ensure(selectRing, newPart, playerGui)
		attachMoveIcon(newPart)
		ensureWarnBillboard(newPart)
		syncWarnLabel()
		hasMoved = false
		hasRotated = false
		validSpot = true
		rejectReason = nil
		syncChrome()
	elseif RelocateMultiSelect.isSelected(newPart, part) then
		RelocateMultiSelect.noteLook(newPart)
	end
end

function RelocateController.restoreSelectionByPlaceIds(ids: { string })
	if not active or #ids == 0 then
		return
	end
	local seen: { [string]: boolean } = {}
	local found: { BasePart } = {}
	for _, pid in ipairs(ids) do
		if typeof(pid) == "string" and pid ~= "" and not seen[pid] then
			seen[pid] = true
			local p = RelocatePickHover.findByPlaceId(pid)
			if p then
				table.insert(found, p)
			end
		end
	end
	if #found == 0 then
		return
	end
	local newPrimary = part
	if newPrimary and newPrimary.Parent then
		local pid = newPrimary:GetAttribute("OceanTD_PlaceId")
		if typeof(pid) ~= "string" or not seen[pid] then
			newPrimary = nil
		end
	else
		newPrimary = nil
	end
	if not newPrimary then
		for _, p in ipairs(found) do
			local pid = p:GetAttribute("OceanTD_PlaceId")
			if typeof(pid) == "string" and pid == placeId then
				newPrimary = p
				break
			end
		end
	end
	if not newPrimary then
		newPrimary = found[1]
	end
	part = newPrimary
	local pid = newPrimary:GetAttribute("OceanTD_PlaceId")
	if typeof(pid) == "string" then
		placeId = pid
	end
	gridAnchorPos = CoralVisual.readGridAnchor(newPrimary) or newPrimary.Position
	originPos = gridAnchorPos
	moveGridAnchor = gridAnchorPos
	local iid = newPrimary:GetAttribute("OceanTD_ItemId")
	if typeof(iid) ~= "string" then
		iid = newPrimary:GetAttribute("OceanTD_SpeciesId")
	end
	if typeof(iid) == "string" then
		itemId = iid
	end
	local restMat, restColor = CoralVisual.readRestLook(newPrimary)
	baseMaterial = restMat
	baseColor = restColor
	RelocateMultiSelect.resyncFromParts(newPrimary, found)
	showPaintSolid = RelocateMultiSelect.isPaintSolid(newPrimary)
	SelectRing.ensure(selectRing, newPrimary, playerGui)
	attachMoveIcon(newPrimary)
	ensureWarnBillboard(newPrimary)
	syncWarnLabel()
	syncChrome()
	activeChanged:Fire(true, newPrimary)
end

local function applySelectionSnapshot(ids: { string }): boolean
	if #ids == 0 then
		if active then
			RelocateController.cancel(true)
			return true
		end
		return false
	end
	local seen: { [string]: boolean } = {}
	local found: { BasePart } = {}
	for _, pid in ipairs(ids) do
		if typeof(pid) == "string" and pid ~= "" and not seen[pid] then
			seen[pid] = true
			local p = RelocatePickHover.findByPlaceId(pid)
			if p then
				table.insert(found, p)
			end
		end
	end
	if #found == 0 then
		return false
	end
	if not active then
		RelocateController.begin(found[1])
		if not active then
			return false
		end
		for i = 2, #found do
			local p = found[i]
			if p.Parent and not RelocateMultiSelect.isSelected(p, part) then
				CoralVisual.applyRestLook(p)
				local m, c = CoralVisual.readRestLook(p)
				RelocateMultiSelect.ensureMembership(p, m, c)
			end
		end
		activeChanged:Fire(true, part)
		return true
	end
	RelocateController.restoreSelectionByPlaceIds(ids)
	return true
end

function RelocateController.snapshotSelectionPlaceIds(): { string }
	local seen: { [string]: boolean } = {}
	local ids: { string } = {}
	for _, p in ipairs(RelocateMultiSelect.getParts(part)) do
		local pid = p:GetAttribute("OceanTD_PlaceId")
		if typeof(pid) == "string" and pid ~= "" and not seen[pid] then
			seen[pid] = true
			table.insert(ids, pid)
		end
	end
	return ids
end

-- After server mesh swap (sponge upgrade), rebind selection without replaying intro chrome.
function RelocateController.swapSelectedPart(target: BasePart)
	if not active or not target.Parent then
		return
	end
	local existingId = target:GetAttribute("OceanTD_PlaceId")
	if typeof(existingId) ~= "string" or existingId == "" or existingId ~= placeId then
		return
	end
	part = target
	gridAnchorPos = CoralVisual.readGridAnchor(target) or target.Position
	originPos = gridAnchorPos
	moveGridAnchor = gridAnchorPos
	SelectRing.ensure(selectRing, target, playerGui)
	attachMoveIcon(target)
	ensureWarnBillboard(target)
	syncWarnLabel()
	syncChrome()
	activeChanged:Fire(true, target)
end

function RelocateController.refreshSelectRing()
	if part then
		SelectRing.ensure(selectRing, part, playerGui)
		SelectRing.pulse(selectRing)
	end
end

-- After stack reflow / size upgrade: home is the new lifted pose (don't snap back to pre-grow).
function RelocateController.syncHomeToPart(target: BasePart?)
	local p = target or part
	if not p or not p.Parent then
		return
	end
	if part and p ~= part then
		local pid = p:GetAttribute("OceanTD_PlaceId")
		if typeof(pid) ~= "string" or pid ~= placeId then
			return
		end
	end
	local home = CoralVisual.readGridAnchor(p) or p.Position
	gridAnchorPos = home
	originPos = home
	moveGridAnchor = home
	hasMoved = false
	hasRotated = false
	validSpot = true
	rejectReason = nil
	if part == p then
		SelectRing.ensure(selectRing, p, playerGui)
		syncChrome()
	end
end

function RelocateController.clearHoverHighlight()
	clearHover()
end

-- instant=true snaps home (used when arming a new backpack coral).
function RelocateController.cancel(instant: boolean?)
	if not active then
		return
	end
	if busy and not instant then
		return
	end
	BrainSnapPreview.hide()
	local p = part
	local origin = originPos
	local moved = hasMoved
	local rotated = hasRotated
	local color = baseColor

	if not moved and not rotated and not recyclePending then
		RelocateMultiSelect.pushUndo()
	end

	local function snapHome()
		if p and p.Parent then
			if CoralVisual.needsFacingYaw(p:GetAttribute("OceanTD_SpeciesId")) and gridAnchorPos then
				local yaw = originFacingYaw
				if typeof(yaw) ~= "number" then
					yaw = CoralVisual.readFacingYaw(p)
				end
				local mir = ClientPlot.get()
				CoralVisual.alignMeshToSurface(p, gridAnchorPos, yaw, nil, if mir then mir.cframe else nil)
			elseif CoralVisual.isMeshSpecies(p:GetAttribute("OceanTD_SpeciesId")) and gridAnchorPos then
				CoralVisual.alignMeshToSurface(p, gridAnchorPos)
			elseif origin then
				p.CFrame = CFrame.new(origin)
			end
		end
		clearState()
	end

	if (moved or rotated) and p and origin and p.Parent and not instant then
		if CoralVisual.isMeshSpecies(p:GetAttribute("OceanTD_SpeciesId")) and gridAnchorPos then
			snapHome()
			log("Cancelled — reverted")
			return
		end
		busy = true
		local start = p.Position
		local home = origin
		local t0 = os.clock()
		local conn: RBXScriptConnection
		conn = RunService.RenderStepped:Connect(function()
			keepCameraFrozen()
			local u = math.clamp((os.clock() - t0) / C.REVERT_SEC, 0, 1)
			local a = 1 - (1 - u) * (1 - u)
			if p.Parent then
				p.CFrame = CFrame.new(start:Lerp(home, a))
				if color then
					local pulse = 0.5 + 0.5 * math.sin(os.clock() * 9)
					p.Material = Enum.Material.Neon
					p.Color = color:Lerp(Color3.new(1, 1, 1), 0.12 + 0.28 * pulse)
				end
			end
			if u >= 1 then
				conn:Disconnect()
				snapHome()
				log("Cancelled — reverted")
			end
		end)
		return
	end
	snapHome()
	log(if instant then "Cancelled (instant)" else "Cancelled")
end

function RelocateController.beginRecycleConfirm()
	if not active or busy or recyclePending or recycleFlying then
		return
	end
	if not part or not originPos then
		return
	end
	-- Snap home so recycle matches the grid cell about to be vacated.
	clearBlockHighlight()
	if CoralVisual.isMeshSpecies(part:GetAttribute("OceanTD_SpeciesId")) and gridAnchorPos then
		CoralVisual.alignMeshToSurface(part, gridAnchorPos)
	else
		part.CFrame = CFrame.new(originPos)
	end
	hasMoved = false
	validSpot = true
	rejectReason = nil
	syncWarnLabel()
	recyclePending = true
	recycleSlideU = 0
	recycleSlideT0 = os.clock()
	recycleSlideActive = true
	fingerDown = false
	dragging = false
	pressOrigin = nil
	grabFromMoveIcon = false
	syncChrome()
	log("Recycle confirm")
end

local function flyRecycleToBackpack(creditedItemId: string, onDone: () -> ())
	if not recycleBtn or not recycleBtn.Parent then
		onDone()
		return
	end
	local session = uiSession
	recycleFlying = true
	if checkBtn then
		checkBtn.Visible = false
	end
	if cancelBtn then
		cancelBtn.Visible = false
	end
	if moveBillboard then
		moveBillboard.Enabled = false
	end

	local startPos = Vector2.new(
		recycleBtn.AbsolutePosition.X + recycleBtn.AbsoluteSize.X * 0.5,
		recycleBtn.AbsolutePosition.Y + recycleBtn.AbsoluteSize.Y * 0.5
	)
	local target = InventoryState.getItemSlotScreenCenter(creditedItemId)
	if not target then
		local vp = if camera then camera.ViewportSize else Vector2.new(800, 600)
		target = Vector2.new(vp.X * 0.85, vp.Y * 0.55)
	end

	-- Prefer showing "+1" while flying into the backpack.
	if recycleIcon then
		recycleIcon.Visible = false
	end
	if recyclePlus then
		recyclePlus.Text = "+1"
		recyclePlus.TextTransparency = 0
		recyclePlus.Visible = true
	end
	recycleBtn.AnchorPoint = Vector2.new(0.5, 0.5)
	recycleBtn.Position = UDim2.fromOffset(startPos.X, startPos.Y)
	recycleBtn.BackgroundColor3 = C.REC_GREEN
	recycleBtn.Active = false

	local startSize = C.REC_BTN_SIZE
	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		-- Aborted: a new relocate began (or UI was torn down).
		if session ~= uiSession or not recycleFlying then
			conn:Disconnect()
			onDone()
			return
		end
		-- Player is already unfrozen — do not re-lock camera during the fly.
		local u = math.clamp((os.clock() - t0) / C.REC_FLY_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		local pos = startPos:Lerp(target, a)
		local scale = math.max(1 - a, 0.12)
		local size = startSize * scale
		if recycleBtn and recycleBtn.Parent then
			recycleBtn.Position = UDim2.fromOffset(pos.X, pos.Y)
			recycleBtn.Size = UDim2.fromOffset(size, size)
			recycleBtn.BackgroundTransparency = a * 0.35
			if recyclePlus then
				recyclePlus.TextTransparency = a * 0.2
			end
		end
		if u >= 1 then
			conn:Disconnect()
			onDone()
		end
	end)
end

local function commitRecycle()
	if not active or busy or not recyclePending or recycleFlying then
		return
	end
	if not part or not originPos or not itemId then
		return
	end
	UiHaptics.pulseShort()
	local fromPos = gridAnchorPos or originPos
	local id = placeId
	local p = part
	local creditedId = itemId
	busy = true
	PlaceVfx.playCancelSound(fromPos)
	local rf = Remotes.getFunction("RequestRecycle")
	local result = rf:InvokeServer(id, fromPos)
	if typeof(result) == "table" and result.ok then
		if typeof(result.itemId) == "string" then
			creditedId = result.itemId
		end
		-- Server destroys the part; drop local refs so clearState won't restore it.
		if warnLabel then
			local bb = warnLabel.Parent
			warnLabel = nil
			if bb then
				bb:Destroy()
			end
		end
		part = nil
		if p and p.Parent then
			p:Destroy()
		end
		clearBlockHighlight()
		-- Unlock walk/camera immediately; +1 fly is cosmetic only.
		stopLoop()
		active = false
		busy = false
		recyclePending = false
		introAnimating = false
		gamepadRelocate = false
		gamepadCursor = nil
		unfreeze()
		SelectRing.destroy(selectRing)
		inspectModal = false
		activeChanged:Fire(false, nil)
		flyRecycleToBackpack(creditedId, function()
			recycleFlying = false
			-- A new relocate may have started mid-fly — don't wipe its chrome.
			if active then
				return
			end
			destroyUi()
			recycleSlideU = 0
			recycleSlideActive = false
			originPos = nil
			gridAnchorPos = nil
			moveGridAnchor = nil
			placeId = ""
			itemId = nil
			baseColor = nil
			baseMaterial = nil
			hasMoved = false
			validSpot = true
			rejectReason = nil
			chromeBtnDown = false
			chromePressTarget = nil
			fingerDown = false
			pressOrigin = nil
			dragging = false
			grabFromMoveIcon = false
			log("Recycled", creditedId, "seeds=", result.seedCount)
		end)
	else
		local code = typeof(result) == "table" and result.errorCode or "Reject"
		log("Recycle rejected", code)
		busy = false
		recyclePending = false
		recycleSlideU = 0
		recycleSlideActive = false
		syncChrome()
	end
end

-- Dark green pop: scale up 0.2s, then scale to 0 over 0.5s on Confirm press.
local CONFIRM_SCALE_UP_SEC = 0.2
local CONFIRM_SCALE_DOWN_SEC = 0.5
local CONFIRM_SCALE_PEAK = 1.2
local CONFIRM_DARK_GREEN = Color3.fromRGB(35, 85, 45)

local function beginConfirmPressedLook()
	local btn = checkBtn
	if not btn then
		return
	end
	confirmOutroPlaying = true
	confirmOutroDone = false
	confirmOutroGen += 1
	local gen = confirmOutroGen
	if cancelBtn then
		cancelBtn.Visible = false
	end
	if rotLeftBtn then
		rotLeftBtn.Visible = false
	end
	if rotRightBtn then
		rotRightBtn.Visible = false
	end
	if recycleBtn then
		recycleBtn.Visible = false
	end
	if moveIcon then
		moveIcon.Visible = false
	end
	btn.Visible = true
	btn.Active = false
	btn.Text = if isUsingGamepad() then "A" else ""
	btn.TextTransparency = if isUsingGamepad() then 0 else 1
	btn.BackgroundColor3 = CONFIRM_DARK_GREEN
	local checkIcon = PlaceConfirmChrome.ensureConfirmCheckIcon(btn)
	checkIcon.Visible = not isUsingGamepad()
	local scale = btn:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "ConfirmOutroScale"
		scale.Parent = btn
	end
	scale.Scale = 1
	if confirmOutroTween then
		confirmOutroTween:Cancel()
		confirmOutroTween = nil
	end
	task.spawn(function()
		local twUp = TweenService:Create(
			scale,
			TweenInfo.new(CONFIRM_SCALE_UP_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = CONFIRM_SCALE_PEAK }
		)
		confirmOutroTween = twUp
		twUp:Play()
		twUp.Completed:Wait()
		if gen ~= confirmOutroGen or not btn.Parent then
			confirmOutroDone = true
			return
		end
		local twDown = TweenService:Create(
			scale,
			TweenInfo.new(CONFIRM_SCALE_DOWN_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Scale = 0 }
		)
		confirmOutroTween = twDown
		twDown:Play()
		twDown.Completed:Wait()
		if gen == confirmOutroGen then
			confirmOutroTween = nil
			confirmOutroDone = true
		end
	end)
end

local function playConfirmSuccessOutro(thenDone: () -> ())
	local btn = checkBtn
	if not btn or not btn.Parent then
		confirmOutroPlaying = false
		confirmOutroTween = nil
		confirmOutroDone = true
		thenDone()
		return
	end
	confirmOutroPlaying = true
	btn.BackgroundColor3 = CONFIRM_DARK_GREEN
	task.spawn(function()
		while not confirmOutroDone do
			task.wait()
		end
		confirmOutroPlaying = false
		confirmOutroTween = nil
		thenDone()
	end)
end

function RelocateController.commit()
	if not active or busy then
		return
	end
	if recyclePending then
		commitRecycle()
		return
	end
	if (not hasMoved and not hasRotated) or not validSpot then
		return
	end
	if not part or not originPos or not itemId then
		return
	end
	local toPos = moveGridAnchor or CoralVisual.readGridAnchor(part) or part.Position
	local fromPos = gridAnchorPos or originPos
	local id = placeId
	local yaw = relocateFacingYaw
	busy = true
	beginConfirmPressedLook()
	PlaceVfx.playSound(toPos)
	local rf = Remotes.getFunction("RequestMove")
	local parentId: string? = nil
	if BrainStack.isBrainId(part:GetAttribute("OceanTD_SpeciesId")) then
		local snap = BrainSnapPreview.getActive()
		if snap and snap.valid and typeof(snap.hostPlaceId) == "string" and snap.hostPlaceId ~= "" then
			parentId = snap.hostPlaceId
		end
	end
	local result = rf:InvokeServer(id, fromPos, toPos, yaw, parentId)
	if typeof(result) == "table" and result.ok then
		UiHaptics.pulseShort()
		if part and part.Parent then
			local finalPos = if typeof(result.worldPos) == "Vector3" then result.worldPos else toPos
			if CoralVisual.needsFacingYaw(part:GetAttribute("OceanTD_SpeciesId")) then
				local finalYaw = if typeof(result.facingYaw) == "number" then result.facingYaw else yaw
				local mir = ClientPlot.get()
				CoralVisual.alignMeshToSurface(part, finalPos, finalYaw, nil, if mir then mir.cframe else nil)
			elseif CoralVisual.isMeshSpecies(part:GetAttribute("OceanTD_SpeciesId")) then
				CoralVisual.alignMeshToSurface(part, finalPos)
			else
				part.CFrame = CFrame.new(finalPos)
			end
			PlacedCoralIndex.reindex(part)
			if typeof(result.placeId) == "string" and result.placeId ~= "" then
				part:SetAttribute("OceanTD_PlaceId", result.placeId)
			elseif placeId ~= "" then
				part:SetAttribute("OceanTD_PlaceId", placeId)
			end
		end
		PlaceVfx.playVisuals(toPos, baseColor or Color3.fromRGB(100, 200, 255))
		log("Saved move")
		playConfirmSuccessOutro(function()
			clearState()
		end)
	else
		local code = typeof(result) == "table" and result.errorCode or "Reject"
		log("Move rejected", code)
		confirmOutroPlaying = false
		confirmOutroGen += 1
		confirmOutroDone = true
		if confirmOutroTween then
			confirmOutroTween:Cancel()
			confirmOutroTween = nil
		end
		busy = false
		validSpot = false
		if checkBtn then
			checkBtn.Active = true
			local sc = checkBtn:FindFirstChildOfClass("UIScale")
			if sc then
				sc.Scale = 1
			end
		end
		syncChrome()
	end
end

local function promotePrimary(nextPart: BasePart)
	if not nextPart.Parent then
		return
	end
	local look = RelocateMultiSelect.getLook(nextPart)
	part = nextPart
	gridAnchorPos = CoralVisual.readGridAnchor(nextPart) or nextPart.Position
	originPos = gridAnchorPos
	moveGridAnchor = gridAnchorPos
	local iid = nextPart:GetAttribute("OceanTD_ItemId")
	if typeof(iid) ~= "string" then
		iid = nextPart:GetAttribute("OceanTD_SpeciesId")
	end
	itemId = if typeof(iid) == "string" then iid else itemId
	if look then
		baseColor = look.color
		baseMaterial = look.material
	else
		local m, c = CoralVisual.readRestLook(nextPart)
		baseMaterial = m
		baseColor = c
	end
	showPaintSolid = false
	hasMoved = false
	hasRotated = false
	originFacingYaw = CoralVisual.readFacingYaw(nextPart)
	relocateFacingYaw = originFacingYaw
	local existingId = nextPart:GetAttribute("OceanTD_PlaceId")
	placeId = if typeof(existingId) == "string" then existingId else ""
	RelocateMultiSelect.stripSecondaryRing(nextPart)
	SelectRing.ensure(selectRing, nextPart, playerGui)
	nextPart.Material = Enum.Material.Neon
	attachMoveIcon(nextPart)
	ensureWarnBillboard(nextPart)
	syncWarnLabel()
	syncChrome()
	activeChanged:Fire(true, nextPart)
end

function RelocateController.begin(target: BasePart)
	-- Recover from stuck recycle-fly / intro so mid-wave picks always get chrome.
	if recycleFlying or introAnimating then
		recycleFlying = false
		introAnimating = false
		if not active then
			busy = false
			destroyUi()
		end
	end
	if busy then
		return
	end
	-- Armed placement owns the pointer — don't steal into move/recycle.
	if PlacementController.isActive() then
		return
	end
	if InventoryState.isBuildModalBlocking() then
		return
	end
	if active then
		if part == target then
			return
		end
		RelocateController.cancel(true)
	end
	if not ClientPlot.isReady() or not target.Parent then
		return
	end
	local iid = target:GetAttribute("OceanTD_ItemId")
	if typeof(iid) ~= "string" then
		local speciesId = target:GetAttribute("OceanTD_SpeciesId")
		if typeof(speciesId) == "string" then
			iid = speciesId
		else
			return
		end
	end

	-- Restore hover neon so we capture the real coral color/material.
	clearHover()
	local restMat, restColor = CoralVisual.readRestLook(target)
	CoralVisual.applyRestLook(target)

	active = true
	gamepadRelocate = isUsingGamepad()
	gamepadChromeT0 = os.clock()
	relocateShownAt = os.clock()
	pendingPick = nil
	pendingPickScreen = nil
	pendingCoralSwitch = nil
	pendingCoralSwitchScreen = nil
	part = target
	gridAnchorPos = CoralVisual.readGridAnchor(target) or target.Position
	-- Mesh species: home / out-of-plot checks use the planted grid point, not mesh center.
	originPos = gridAnchorPos
	moveGridAnchor = gridAnchorPos
	itemId = iid
	baseColor = restColor
	baseMaterial = restMat
	showPaintSolid = false
	hasMoved = false
	hasRotated = false
	originFacingYaw = CoralVisual.readFacingYaw(target)
	relocateFacingYaw = originFacingYaw
	validSpot = true
	rejectReason = nil
	recyclePending = false
	recycleFlying = false
	introAnimating = false
	recycleSlideU = 0
	recycleSlideActive = false
	chromeBtnDown = false
	chromePressTarget = nil
	chromeClaimSource = nil
	fingerDown = false
	pressOrigin = nil
	dragging = false
	grabFromMoveIcon = false
	local existingId = target:GetAttribute("OceanTD_PlaceId")
	placeId = if typeof(existingId) == "string" then existingId else ""

	local vpScreen = if Workspace.CurrentCamera
		then worldToViewport(Workspace.CurrentCamera :: Camera, target.Position)
		else nil
	local screen = vpScreen or pointerScreenPos()
	if gamepadRelocate then
		-- Aim cursor is GetMouseLocation / viewport space.
		gamepadCursor = screen
	else
		gamepadCursor = nil
	end

	target.Material = Enum.Material.Neon
	SelectRing.ensure(selectRing, target, playerGui)
	RelocateMultiSelect.clear(false)
	RelocateMultiSelect.ensureMembership(target, restMat, restColor)
	freeze()
	makeUi()
	if cancelBtn then
		cancelBtn.Text = if gamepadRelocate then "B" else "X"
	end
	attachMoveIcon(target)
	ensureWarnBillboard(target)
	syncWarnLabel()
	playIntro(screen)
	startLoop()
	-- Ensure chrome appears even if intro early-outs (missing move icon).
	if not introAnimating then
		syncChrome()
	end
	log("Begin", itemId, if gamepadRelocate then "gamepad" else "pointer")
	activeChanged:Fire(true, target)
end

local function tryBeginFromPick(screenPos: Vector2): boolean
	if active or busy or PlacementController.isActive() then
		return false
	end
	if not InventoryState.isOpen() then
		return false
	end
	if InventoryState.isPointerOverBackpack(screenPos) then
		return false
	end
	local hit = pickPlacedCoral(screenPos)
	if not hit then
		return false
	end
	RelocateController.begin(hit)
	return true
end

local function isOverMoveIcon(screenPos: Vector2): boolean
	return RelocateHitTest.isOverMoveIcon(chromeRefs(), screenPos)
end

local function isOverChrome(screenPos: Vector2): boolean
	return RelocateHitTest.isOverChrome(chromeRefs(), screenPos)
end

local function resolveRelocateChrome(screenPos: Vector2): string?
	return RelocateHitTest.resolveChrome(chromeRefs(), screenPos)
end

table.insert(inputConns, UserInputService.InputBegan:Connect(function(input, _processed)
	local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1
	local isTouch = input.UserInputType == Enum.UserInputType.Touch

	if active then
		if inspectModal then
			return
		end
		if busy then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonR1 then
			if r1WhileActive and r1WhileActive() then
				return
			end
		end
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.X or input.KeyCode == Enum.KeyCode.ButtonB then
			RelocateController.cancel()
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonA then
			-- Idle (no ✓ / recycle confirm): allow inspect A (e.g. color pick).
			if not hasMoved and not recyclePending then
				if aWhileIdle and aWhileIdle() then
					return
				end
			end
			RelocateController.commit()
			return
		end
		if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.KeypadEnter then
			RelocateController.commit()
			return
		end
		-- L1 / LB / Delete → recycle confirm (same as tapping the recycle button).
		if input.KeyCode == Enum.KeyCode.ButtonL1 or input.KeyCode == Enum.KeyCode.Delete then
			RelocateController.beginRecycleConfirm()
			return
		end
		if not isMouse and not isTouch then
			return
		end
		local screenPos = PlaceConfirmHitTest.pointerScreenPos(input)
		-- World picks use viewport space (GetMouseLocation / Touch Position).
		-- PlaceConfirmHitTest adds GuiInset for touch — that breaks ViewportPointToRay.
		local pickPos = if isTouch
			then Vector2.new(input.Position.X, input.Position.Y)
			else UserInputService:GetMouseLocation()
		-- Move handle wins over ✓/X/recycle so grabbing the icon starts a drag.
		local grabHandle = isOverMoveIcon(screenPos)
		if not grabHandle then
			local chromeTarget = resolveRelocateChrome(screenPos)
			if chromeTarget then
				claimChromeTarget(chromeTarget, "uis")
				pendingCoralSwitch = nil
				pendingCoralSwitchScreen = nil
				fingerDown = false
				dragging = false
				if chromeTarget == "rotLeft" or chromeTarget == "rotRight" then
					local dir = if chromeTarget == "rotLeft" then 1 else -1
					local btn = if chromeTarget == "rotLeft" then rotLeftBtn else rotRightBtn
					PlaceConfirmChrome.beginRotateHold(btn, function()
						if BrainSnapPreview.isSnapped() then
							rotateBrainSnapOrbit(dir)
						else
							rotateSelectedSeaFan(dir)
						end
					end)
				else
					PlaceConfirmChrome.stopRotateHold()
				end
				return
			end
		end
		if InventoryState.isPointerOverBackpack(screenPos) then
			return
		end
		if recyclePending then
			return
		end
		-- Never world-pick through chrome. Never default unresolved hits to Cancel.
		if isOverChrome(screenPos) then
			local resolved = resolveRelocateChrome(screenPos)
			if resolved then
				claimChromeTarget(resolved, "uis")
			end
			pendingCoralSwitch = nil
			pendingCoralSwitchScreen = nil
			return
		end
		-- Switching coral must not steal the press used to drag the current one.
		-- pickPlacedCoral excludes the selected part, so presses on it often "hit"
		-- a neighbor — defer switch to a clean tap on release instead.
		pendingCoralSwitch = nil
		pendingCoralSwitchScreen = nil
		RelocateMultiSelect.clearPendingInput()
		if RelocateMultiSelect.isShiftHeld() then
			-- Additive toggle: hit primary via pointerHits, others via pick.
			local hit: BasePart? = nil
			if pointerHitsSelectedCoral(pickPos) then
				hit = part
			else
				hit = pickPlacedCoral(pickPos)
			end
			if hit then
				RelocateMultiSelect.setPendingShift(hit, pickPos)
			end
			return
		end
		local other = pickPlacedCoral(pickPos)
		if other and other ~= part and not grabHandle and not pointerHitsSelectedCoral(pickPos) then
			pendingCoralSwitch = other
			pendingCoralSwitchScreen = pickPos
			return
		end
		if not other and not grabHandle and not pointerHitsSelectedCoral(pickPos) then
			-- Empty ground: clear multi-select on release (Windows Explorer).
			RelocateMultiSelect.setPendingClear(true)
			fingerDown = true
			pressOrigin = pickPos
			dragging = false
			return
		end
		fingerDown = true
		pressOrigin = pickPos
		dragging = grabHandle
		grabFromMoveIcon = grabHandle
		return
	end

	-- Gamepad: R1 / RB starts move on the neon-highlighted coral.
	if input.KeyCode == Enum.KeyCode.ButtonR1 then
		if PlacementController.isActive() or not InventoryState.isOpen() then
			return
		end
		local hoverPart = RelocatePickHover.getHoverPart()
		if hoverPart and hoverPart.Parent then
			RelocateController.begin(hoverPart)
		end
		return
	end

	-- Idle pick: backpack open — open move tool on press (don't require drag).
	-- Ignore `processed`: open backpack GUIs often mark clicks processed even over the world.
	-- Skip while a coral is armed for place — touches aim/place instead of relocating.
	if not isMouse and not isTouch then
		return
	end
	if not InventoryState.isOpen() or PlacementController.isActive() then
		return
	end
	local screenPos = pointerScreenPos()
	if InventoryState.isPointerOverBackpack(screenPos) then
		pendingPick = nil
		pendingPickScreen = nil
		return
	end
	local hit = pickPlacedCoral(screenPos)
	if hit then
		pendingPick = hit
		pendingPickScreen = screenPos
		RelocateController.begin(hit)
	else
		pendingPick = nil
		pendingPickScreen = nil
	end
end))

table.insert(inputConns, UserInputService.InputChanged:Connect(function(input, _processed)
	if not active or busy or chromeBtnDown then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	if not fingerDown and not dragging then
		return
	end
	local now = pointerScreenPos()
	if pressOrigin and not dragging then
		if (now - pressOrigin).Magnitude < C.DRAG_PX then
			return
		end
		dragging = true
		-- Sliding = move, not a switch-tap.
		pendingCoralSwitch = nil
		pendingCoralSwitchScreen = nil
		RelocateMultiSelect.clearPendingInput()
	end
	if not dragging and not fingerDown then
		return
	end
	-- Grabbing the on-coral handle: keep icon under the pointer on mouse;
	-- on touch always raise so the coral sits above the thumb.
	if grabFromMoveIcon and pressOrigin and (now - pressOrigin).Magnitude < 2 then
		return
	end
	local aim: Vector2
	if grabFromMoveIcon and UserInputService:GetLastInputType() ~= Enum.UserInputType.Touch then
		aim = now
	else
		aim = aimScreenPos()
	end
	local pos = raycastTerrain(aim)
	if pos then
		updateAt(pos)
	end
end))

table.insert(inputConns, UserInputService.InputEnded:Connect(function(input, _processed)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local screenPos = PlaceConfirmHitTest.pointerScreenPos(input)
	local pickPos = if input.UserInputType == Enum.UserInputType.Touch
		then Vector2.new(input.Position.X, input.Position.Y)
		else UserInputService:GetMouseLocation()
	local switchTarget = pendingCoralSwitch
	local switchOrigin = pendingCoralSwitchScreen
	local shiftTarget, shiftOrigin = RelocateMultiSelect.getPendingShift()
	local clearSel = RelocateMultiSelect.getPendingClear()
	local wasDragging = dragging
	local chromeTarget = chromePressTarget
	local wasChrome = chromeBtnDown
	chromeBtnDown = false
	chromePressTarget = nil
	chromeClaimSource = nil
	fingerDown = false
	pressOrigin = nil
	dragging = false
	grabFromMoveIcon = false
	pendingCoralSwitch = nil
	pendingCoralSwitchScreen = nil
	RelocateMultiSelect.clearPendingInput()

	-- Trust the press target (same as PlacementController). Re-hit-testing on release
	-- fought ScreenGui/Billboard coords and canceled moves when tapping Confirm.
	if active and wasChrome and chromeTarget then
		if chromeTarget == "rotLeft" or chromeTarget == "rotRight" then
			PlaceConfirmChrome.stopRotateHold()
			return
		end
		PlaceConfirmChrome.stopRotateHold()
		if chromeTarget == "check" then
			RelocateController.commit()
			return
		end
		if chromeTarget == "cancel" then
			RelocateController.cancel()
			return
		end
		if chromeTarget == "recycle" then
			RelocateController.beginRecycleConfirm()
			return
		end
		return
	end

	-- Shift+click toggle add/remove.
	if active and shiftTarget and shiftTarget.Parent and shiftOrigin and not wasDragging then
		if (pickPos - shiftOrigin).Magnitude <= C.PICK_TAP_PX then
			RelocateMultiSelect.toggle(shiftTarget)
			return
		end
	end

	-- Empty ground tap clears selection (cancel snapshots undo).
	if active and clearSel and not wasDragging and not hasMoved and not hasRotated and not recyclePending then
		RelocateController.cancel(true)
		return
	end

	-- Tap another coral while one is selected → switch (no drag happened).
	if active and switchTarget and switchTarget.Parent and switchOrigin then
		if (pickPos - switchOrigin).Magnitude <= C.PICK_TAP_PX then
			RelocateController.begin(switchTarget)
			return
		end
	end

	-- Tap fallback: if press didn't open the tool (processed/ray miss), try again on release.
	if not active and not PlacementController.isActive() and pendingPick and pendingPickScreen then
		if (pickPos - pendingPickScreen).Magnitude <= C.PICK_TAP_PX then
			if pendingPick.Parent then
				RelocateController.begin(pendingPick)
			else
				tryBeginFromPick(pickPos)
			end
		end
	end
	pendingPick = nil
	pendingPickScreen = nil
end))

InventoryState.onOpenChanged(function(isOpen)
	if isOpen then
		startHoverLoop()
	else
		stopHoverLoop()
		if active then
			RelocateController.cancel()
		end
	end
end)

if InventoryState.isOpen() then
	startHoverLoop()
end

-- Arming a new coral from the backpack cancels an open relocate (snap home).
InventoryState.onSelectionChanged(function(id)
	if id ~= nil and active then
		RelocateController.cancel(true)
	end
end)

player.CharacterAdded:Connect(function()
	if active then
		RelocateController.cancel()
	end
end)

RelocateMultiSelect.mount({
	getPrimary = function(): BasePart?
		return part
	end,
	promotePrimary = promotePrimary,
	isActive = function(): boolean
		return active
	end,
	isBusy = function(): boolean
		return busy
	end,
	getRecyclePending = function(): boolean
		return recyclePending
	end,
	getHasMoved = function(): boolean
		return hasMoved
	end,
	getHasRotated = function(): boolean
		return hasRotated
	end,
	beginCoral = function(p: BasePart)
		RelocateController.begin(p)
	end,
	cancelCoral = function(skipHome: boolean?)
		RelocateController.cancel(skipHome)
	end,
	applySelectionSnapshot = applySelectionSnapshot,
	clearHover = clearHover,
	restorePartLook = restorePartLook,
	findByPlaceId = RelocatePickHover.findByPlaceId,
	playerGui = playerGui,
	getSelectRing = function()
		return selectRing
	end,
	fireActiveChanged = function(p: BasePart)
		activeChanged:Fire(true, p)
	end,
})

RelocatePickHover.mount({
	getPrimary = function(): BasePart?
		return part
	end,
	getBlockPart = function(): BasePart?
		return blockPart
	end,
	getSelectRing = function()
		return selectRing
	end,
	isActive = function(): boolean
		return active
	end,
	isBusy = function(): boolean
		return busy
	end,
	playerGui = playerGui,
})

log("Ready")

return RelocateController
