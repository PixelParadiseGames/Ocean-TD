--!strict
--[[
	Placement mode (confirm-ghost flow):
	Aiming → ghost follows pointer; Confirming → parked ghost + ✓ / X.
	✓ = server RequestPlace; X = cancel confirm (back to aiming) or exit.
	Freezes avatar movement + camera while active. Infinite items (no debit).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = Workspace.CurrentCamera

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual"))
local SpeciesCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SpeciesCatalog"))
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local PlaceVfx = require(script.Parent:WaitForChild("PlaceVfx"))
local HandOrb = require(script.Parent:WaitForChild("HandOrb"))
local SelectRing = require(script.Parent:WaitForChild("SelectRing"))
local PlaceConfirmHitTest = require(script.Parent:WaitForChild("PlaceConfirmHitTest"))
local PlaceConfirmChrome = require(script.Parent:WaitForChild("PlaceConfirmChrome"))
local PlaceAimScreen = require(script.Parent:WaitForChild("PlaceAimScreen"))
local PlaceBlockFlash = require(script.Parent:WaitForChild("PlaceBlockFlash"))
local PlaceRaycast = require(script.Parent:WaitForChild("PlaceRaycast"))
local PlaceArmDisarmAnim = require(script.Parent:WaitForChild("PlaceArmDisarmAnim"))
local BrainSnapPreview = require(script.Parent:WaitForChild("BrainSnapPreview"))
local CoralRangeRings = require(script.Parent:WaitForChild("CoralRangeRings"))
local CoralSize = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralSize"))
local BrainStack = require(oceanRoot:WaitForChild("Shared"):WaitForChild("BrainStack"))

local PlacementController = {}

local MODE_OFF = "Off"
local MODE_AIM = "Aim"
local MODE_CONFIRM = "Confirm"

local mode = MODE_OFF
local armedItemId: string? = nil
local ghost: BasePart? = nil
local ghostPlaceDiameter: number? = nil
local ghostPlaceVariant: number? = nil
local ghostPlaceScale: number? = nil
local ghostPlaceScaleWidth: number? = nil
local ghostPlaceScaleHeight: number? = nil
local ghostPlaceFacingYaw: number? = nil
local warnLabel: TextLabel? = nil
local moveHintImage: ImageLabel? = nil
local moveHintBillboard: BillboardGui? = nil
local confirmGui: ScreenGui? = nil
local chromeBillboard: BillboardGui? = nil
local chromeAdorneePart: BasePart? = nil
local checkBtn: TextButton? = nil
local cancelBtn: TextButton? = nil
local rotLeftBtn: ImageButton? = nil
local rotRightBtn: ImageButton? = nil
local confirmPos: Vector3? = nil -- ground anchor under finger (actual place pos)
local placeAnchor: Vector3? = nil
local validSpot = false
local rejectReason: string? = nil
local backpackDrag = false -- pointer-driven aim from backpack pull
local aimFingerDown = false -- world drag after tap-select (mobile/PC)
-- Press started during AIM (including on the backpack). Park on lift unless still on the backpack.
local placePointerHeld = false
local confirmDragging = false
local confirmPressOrigin: Vector2? = nil -- nil while pressing ✓/X
local chromeScreenPos: Vector2? = nil -- move-icon aim freeze; ✓/X sit at feet
local aimPinnedToCenter = false
local aimPinnedToHand = false -- ghost starts in the right hand until the player aims
local aimPinOrigin: Vector2? = nil
local AIM_UNPIN_PX = 14
-- True only while the active place pointer is a touch finger (not mouse / LastInputType guesses).
local aimRaiseForTouch = false
local moveHintScale: UIScale? = nil
local moveHintPulseToken = 0
-- Gamepad: left stick aims; A places immediately (no park/confirm); B returns to list.
local gamepadPlacement = false
local gamepadCursor: Vector2? = nil
local checkPromptConn: RBXScriptConnection? = nil
local gamepadReturnCbs: { () -> () } = {}
local GAMEPAD_STICK_DEADZONE = 0.22
-- Precision aim: 50% of original, then another ~30% slower (980 → 343).
local GAMEPAD_AIM_SPEED = 343 -- px/sec at full deflection
-- Defined early so destroyConfirmUi / exitPlacement never hit a nil forward-ref.
local function stopCheckPrompt()
	if checkPromptConn then
		checkPromptConn:Disconnect()
		checkPromptConn = nil
	end
end

-- Screen stack around the 2D aim point (cursor / raised touch aim), not the 3D
-- projection — ground hits often draw below the cursor and dragged all chrome down.
local MOVE_ICON_SIZE = 48
local MOVE_ICON_IMAGE = "rbxassetid://345081302"
local MOVE_HINT_PULSE_SPEED = 4
local MOVE_HINT_SCALE_IN_SEC = 0.35
local MOVE_HINT_PULSE_AMP = 0.2
local GHOST_INVALID_COLOR = Color3.fromRGB(220, 70, 70)
local GHOST_PULSE_SPEED = 5
local CHECK_BRIGHT_GREEN = Color3.fromRGB(90, 255, 120)
local CHECK_HUNTER_GREEN = Color3.fromRGB(35, 85, 45)
local POST_PLACE_GHOST_DELAY = 1
local GHOST_SCALE_IN_SEC = 0.5

local ghostBaseColor: Color3? = nil
local ghostBaseMaterial: Enum.Material? = nil
local placeSelectRing = SelectRing.new()
local placeResumeToken = 0
local postPlaceWaiting = false
local pendingGhostScaleIn = false
local ghostScaleConn: RBXScriptConnection? = nil
-- Optional slot targets when switching items (capture before pulse moves).
local pendingDisarmSlotScreen: Vector2? = nil
local pendingArmSlotScreen: Vector2? = nil
local queuedSwitchItemId: string? = nil
-- ✓/X press owned by confirm chrome (blocks AIM from parking the ghost on that click).
local chromeBtnPointerDown = false
local chromePressTarget: string? = nil -- "check" | "cancel"
local placeCommitBusy = false

-- Forward decls so confirm UI can wire before bodies are assigned.
local onCheck: () -> ()
local onCancel: () -> ()
local makeConfirmUi: () -> ()
local syncConfirmButtons: () -> ()
local stopMoveHintAttract: () -> ()
local startMoveHintAttract: () -> ()
local detachMoveHintToScreen: () -> ()
local attachMoveHintToGhost: () -> ()
local releaseHandPin: () -> ()
local startAimLoop: () -> ()
local beginAim: (string, boolean?, boolean?) -> ()

local savedWalkSpeed = 16
local savedJumpPower = 75
local savedJumpHeight = 10.8
local savedCameraType: Enum.CameraType? = nil
local savedCameraCFrame: CFrame? = nil
local aimConn: RBXScriptConnection? = nil
local inputConns: { RBXScriptConnection } = {}
local frozen = false
local savedTouchControlsEnabled: boolean? = nil
local savedTouchGuiEnabled: boolean? = nil

local FREEZE_ACTION = "OceanTD_PlacementFreeze"
local DEFAULT_WALK_SPEED = 16
local DEFAULT_JUMP_POWER = 75
local DEFAULT_JUMP_HEIGHT = 10.8 -- StarterPlayer default 7.2 × 1.5
local CONFIRM_DRAG_PX = 28 -- ignore tiny finger jitter before moving parked ghost
local BTN_SIZE = PlaceConfirmChrome.BASE_BTN_PX -- viewport-scaled via PlaceConfirmChrome.chromeBtnSize

local function log(...: any)
	print("[PLACE]", ...)
end

local function getPlayerControls(): any
	local ok, controls = pcall(function()
		local playerScripts = player:FindFirstChild("PlayerScripts")
		if not playerScripts then
			return nil
		end
		local playerModuleScript = playerScripts:FindFirstChild("PlayerModule")
		if not playerModuleScript then
			return nil
		end
		local playerModule = require(playerModuleScript)
		return playerModule:GetControls()
	end)
	if ok then
		return controls
	end
	return nil
end

local touchGuiWatch: RBXScriptConnection? = nil

local function applyTouchGuiDisabled(touchGui: Instance)
	if touchGui:IsA("ScreenGui") then
		if savedTouchGuiEnabled == nil then
			savedTouchGuiEnabled = touchGui.Enabled
		end
		touchGui.Enabled = false
	end
end

local function setTouchControlsEnabled(enabled: boolean)
	pcall(function()
		if enabled then
			-- Always re-enable; restoring a stale `false` left jump/touch missing on mobile.
			GuiService.TouchControlsEnabled = true
			savedTouchControlsEnabled = nil
		else
			if savedTouchControlsEnabled == nil then
				savedTouchControlsEnabled = GuiService.TouchControlsEnabled
			end
			GuiService.TouchControlsEnabled = false
		end
	end)

	if touchGuiWatch then
		touchGuiWatch:Disconnect()
		touchGuiWatch = nil
	end

	local function enableTouchGui(gui: Instance)
		if gui:IsA("ScreenGui") then
			gui.Enabled = true
		end
	end

	if enabled then
		savedTouchGuiEnabled = nil
		for _, child in ipairs(playerGui:GetChildren()) do
			if child.Name == "TouchGui" then
				enableTouchGui(child)
			end
		end
		-- PlayerModule may recreate TouchGui a frame later after Enable().
		touchGuiWatch = playerGui.ChildAdded:Connect(function(child)
			if child.Name == "TouchGui" then
				enableTouchGui(child)
			end
		end)
		task.delay(1, function()
			if touchGuiWatch then
				touchGuiWatch:Disconnect()
				touchGuiWatch = nil
			end
		end)
	else
		local touchGui = playerGui:FindFirstChild("TouchGui")
		if touchGui then
			applyTouchGuiDisabled(touchGui)
		end
		touchGuiWatch = playerGui.ChildAdded:Connect(function(child)
			if child.Name == "TouchGui" then
				applyTouchGuiDisabled(child)
			end
		end)
	end
end

local function unfreeze()
	ContextActionService:UnbindAction(FREEZE_ACTION)
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
		local walk = if savedWalkSpeed > 0 then savedWalkSpeed else DEFAULT_WALK_SPEED
		local jumpP = if savedJumpPower > 0 then savedJumpPower else DEFAULT_JUMP_POWER
		local jumpH = if savedJumpHeight > 0 then savedJumpHeight else DEFAULT_JUMP_HEIGHT
		if hum then
			hum.WalkSpeed = walk
			hum.JumpPower = jumpP
			hum.JumpHeight = jumpH
		end
		local camType = savedCameraType
		if camType == nil or camType == Enum.CameraType.Scriptable then
			camType = Enum.CameraType.Custom
		end
		if camera then
			camera.CameraType = camType
			if camType == Enum.CameraType.Custom and hum then
				camera.CameraSubject = hum
			end
		end
	else
		if hum and hum.WalkSpeed <= 0 then
			hum.WalkSpeed = DEFAULT_WALK_SPEED
			hum.JumpPower = DEFAULT_JUMP_POWER
			hum.JumpHeight = DEFAULT_JUMP_HEIGHT
		end
		if camera and camera.CameraType == Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Custom
			if hum then
				camera.CameraSubject = hum
			end
		end
	end

	savedCameraType = nil
	savedCameraCFrame = nil
end

local function freeze()
	-- FreeCam/FishCam own Scriptable cam; release them first so place freeze/restore is Custom.
	if not frozen then
		playerGui:SetAttribute("OceanTD_ForceCloseFreeCam", os.clock())
	end
	-- Lock walk + camera look while armed / placing.
	if frozen then
		if camera and savedCameraCFrame then
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = savedCameraCFrame
		end
		local character = player.Character
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.WalkSpeed = 0
			hum.JumpPower = 0
			hum.JumpHeight = 0
		end
		setTouchControlsEnabled(false)
		return
	end
	frozen = true

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
		local currentType = camera.CameraType
		if currentType ~= Enum.CameraType.Scriptable then
			savedCameraType = currentType
		else
			savedCameraType = Enum.CameraType.Custom
		end
		savedCameraCFrame = camera.CFrame
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = savedCameraCFrame
	end

	-- Keyboard only — do NOT bind Thumbstick1 (breaks mobile move after unbind).
	ContextActionService:BindActionAtPriority(FREEZE_ACTION, function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Space)
end

local function getSpeciesIdForItem(itemId: string): string?
	local item = ItemCatalog.get(itemId)
	if item and item.speciesId then
		return item.speciesId
	end
	local sp = SpeciesCatalog.getByItemId(itemId)
	return if sp then sp.speciesId else nil
end

local function stopGhostScaleIn()
	if ghostScaleConn then
		ghostScaleConn:Disconnect()
		ghostScaleConn = nil
	end
end

local function startGhostScaleIn(part: BasePart)
	stopGhostScaleIn()
	local target = part.Size
	part.Size = target * 0.05
	local t0 = os.clock()
	ghostScaleConn = RunService.RenderStepped:Connect(function()
		if not part.Parent then
			stopGhostScaleIn()
			return
		end
		local u = math.clamp((os.clock() - t0) / GHOST_SCALE_IN_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		part.Size = target * (0.05 + 0.95 * a)
		if u >= 1 then
			part.Size = target
			stopGhostScaleIn()
		end
	end)
end

local function clearGhost()
	stopGhostScaleIn()
	BrainSnapPreview.hide()
	PlaceBlockFlash.clear()
	ClientPlot.setOutOfPlotFlash(false)
	warnLabel = nil
	ghostBaseColor = nil
	ghostBaseMaterial = nil
	ghostPlaceDiameter = nil
	ghostPlaceVariant = nil
	ghostPlaceScale = nil
	ghostPlaceScaleWidth = nil
	ghostPlaceScaleHeight = nil
	ghostPlaceFacingYaw = nil
	SelectRing.destroy(placeSelectRing)
	CoralRangeRings.hide()
	-- Keep move icon alive (billboard may be Adorned to this ghost).
	detachMoveHintToScreen()
	if ghost then
		ghost:Destroy()
		ghost = nil
	end
	placeAnchor = nil
end

local function destroyConfirmUi()
	PlaceConfirmChrome.stopRotateHold()
	if checkPromptConn then
		checkPromptConn:Disconnect()
		checkPromptConn = nil
	end
	stopMoveHintAttract()
	if moveHintBillboard then
		moveHintBillboard:Destroy()
		moveHintBillboard = nil
	end
	if chromeBillboard then
		chromeBillboard:Destroy()
		chromeBillboard = nil
	end
	if chromeAdorneePart then
		chromeAdorneePart:Destroy()
		chromeAdorneePart = nil
	end
	if confirmGui then
		confirmGui:Destroy()
		confirmGui = nil
	end
	checkBtn = nil
	cancelBtn = nil
	rotLeftBtn = nil
	rotRightBtn = nil
	moveHintImage = nil
	moveHintScale = nil
	chromePressTarget = nil
	chromeBtnPointerDown = false
end

local function rayExclude(): PlaceRaycast.ExcludeRefs
	return {
		ghost = ghost,
		outgoingGhost = PlaceArmDisarmAnim.getOutgoingGhost(),
		character = player.Character,
	}
end

local function placeAimOpts(): PlaceRaycast.PlaceAimOpts
	return {
		gamepadPlacement = gamepadPlacement,
		aimRaiseForTouch = aimRaiseForTouch,
		gamepadCursor = gamepadCursor,
		aimPinnedToCenter = aimPinnedToCenter,
		exclude = rayExclude(),
	}
end

local function getPlaceAimScreenPos(): Vector2
	return PlaceRaycast.getPlaceAimScreenPos(placeAimOpts())
end

local function resolveParkPos(screenPos: Vector2?): Vector3?
	return PlaceRaycast.resolveParkPos({
		screenPos = screenPos,
		aimRaiseForTouch = aimRaiseForTouch,
		gamepadPlacement = gamepadPlacement,
		placeAnchor = placeAnchor,
		ghostPos = if ghost then ghost.Position else nil,
		exclude = rayExclude(),
	})
end

local function raycastForPlace(): Vector3?
	return PlaceRaycast.forPlace(placeAimOpts())
end

local function raycastAimThrottled(dt: number): Vector3?
	return PlaceRaycast.aimThrottled(dt, placeAimOpts(), placeAnchor)
end

local function notePlacePointerInput(input: InputObject)
	if PlaceAimScreen.isEmulatedMouse(input) then
		return
	end
	if input.UserInputType == Enum.UserInputType.Touch then
		aimRaiseForTouch = true
	elseif input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.MouseButton2
		or input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.MouseWheel
		or input.UserInputType == Enum.UserInputType.Gamepad1
		or input.KeyCode == Enum.KeyCode.Thumbstick1
	then
		aimRaiseForTouch = false
	end
end

local function setCheckLabel(text: string)
	if not checkBtn then
		return
	end
	-- Glyph child sat under/behind Billboard chrome and FredokaOne blanked ✓.
	-- Match RelocateController: paint TextButton.Text directly.
	local glyph = checkBtn:FindFirstChild("Glyph")
	if glyph then
		glyph:Destroy()
	end
	local isWord = text == "CONFIRM" or text == "Enter" or text == "A" or text == "OK"
	local strokeColor = if isWord
		then Color3.fromRGB(12, 55, 25)
		else Color3.new(1, 1, 1)
	checkBtn.Text = text
	checkBtn.TextTransparency = 0
	checkBtn.TextColor3 = Color3.new(1, 1, 1)
	checkBtn.TextStrokeColor3 = strokeColor
	checkBtn.TextStrokeTransparency = 0
	checkBtn.ZIndex = 20
	-- CONFIRM needs fixed size; TextScaled crushes long words in the circle.
	-- Mobile chrome is ~30% smaller — keep text small enough for one line.
	if text == "CONFIRM" then
		checkBtn.TextScaled = false
		checkBtn.TextSize = PlaceConfirmChrome.confirmLabelTextSize()
	else
		checkBtn.TextScaled = true
	end
end

local function applyGamepadButtonLabels()
	if not checkBtn or not cancelBtn then
		return
	end
	-- Label cycling is owned by syncConfirmButtons (never force blank ✓ — FredokaOne has no checkmark).
	stopCheckPrompt()
end

local function fireGamepadReturnToList()
	for _, cb in ipairs(gamepadReturnCbs) do
		task.spawn(cb)
	end
end

local function evaluatePos(worldPos: Vector3): (boolean, string?)
	return PlaceRaycast.evaluatePos(worldPos, armedItemId)
end

local function syncBlockFlashForAim(worldPos: Vector3?)
	PlaceBlockFlash.syncForAim(
		worldPos,
		aimPinnedToHand,
		validSpot,
		rejectReason,
		if worldPos then PlaceRaycast.findBlockingCoral(worldPos) else nil
	)
end

local function resolvePlaceAnchor(rawPos: Vector3): Vector3
	if armedItemId == "BrainCoral" then
		local diam = ghostPlaceDiameter
		if typeof(diam) ~= "number" then
			diam = CoralVisual.randomBrainDiameter()
			ghostPlaceDiameter = diam
		end
		BrainSnapPreview.setVisible(true)
		local screen = PlaceRaycast.getPlaceAimScreenPos(placeAimOpts())
		return PlaceRaycast.resolveBrainStackPos(rawPos, diam :: number, nil, screen)
	end
	BrainSnapPreview.setVisible(false)
	return rawPos
end

local function ensureWarnBillboard(parent: BasePart)
	if warnLabel and warnLabel.Parent then
		return
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "PlaceWarn"
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
	lbl.Parent = bb
	warnLabel = lbl
end

local function setMoveHintVisible(visible: boolean)
	if moveHintImage then
		moveHintImage.Visible = visible
	end
end

-- Screen-space mode for backpack fly in/out tweens.
detachMoveHintToScreen = function()
	if not moveHintImage then
		if moveHintBillboard then
			moveHintBillboard:Destroy()
			moveHintBillboard = nil
		end
		return
	end
	if confirmGui and moveHintImage.Parent ~= confirmGui then
		-- Park at the ghost's screen center so tweens start from the right place.
		if camera and ghost and ghost.Parent then
			local sp, _ = camera:WorldToViewportPoint(ghost.Position)
			if sp.Z > 0 then
				moveHintImage.Position = UDim2.fromOffset(sp.X, sp.Y)
			end
		end
		moveHintImage.AnchorPoint = Vector2.new(0.5, 0.5)
		moveHintImage.Size = UDim2.fromOffset(MOVE_ICON_SIZE, MOVE_ICON_SIZE)
		moveHintImage.Parent = confirmGui
	end
	if moveHintBillboard then
		moveHintBillboard:Destroy()
		moveHintBillboard = nil
	end
end

-- Touch: world-anchored on the ghost. Mouse (live aim only): pin to GetMouseLocation
-- so the icon can't drift above the hardware cursor. Parked confirm stays on the ghost.
attachMoveHintToGhost = function()
	if not moveHintImage or not ghost or not ghost.Parent then
		return
	end
	local liveMouseAim = (mode == MODE_AIM or confirmDragging or aimFingerDown or backpackDrag)
		and not gamepadPlacement
		and not PlaceAimScreen.isTouchAim(aimRaiseForTouch, gamepadPlacement)
	if liveMouseAim then
		detachMoveHintToScreen()
		if not confirmGui then
			return
		end
		local m = UserInputService:GetMouseLocation()
		-- ScreenInsets.None → full window; Position matches GetMouseLocation (do not subtract GuiInset).
		moveHintImage.AnchorPoint = Vector2.new(0.5, 0.5)
		moveHintImage.Size = UDim2.fromOffset(MOVE_ICON_SIZE, MOVE_ICON_SIZE)
		moveHintImage.Position = UDim2.fromOffset(m.X, m.Y)
		moveHintImage.Visible = true
		if moveHintImage.Parent ~= confirmGui then
			moveHintImage.Parent = confirmGui
		end
		return
	end
	if moveHintBillboard and moveHintBillboard.Parent and moveHintBillboard.Adornee == ghost then
		moveHintImage.Visible = true
		if moveHintImage.Parent ~= moveHintBillboard then
			moveHintImage.Parent = moveHintBillboard
		end
		return
	end
	if moveHintBillboard then
		moveHintBillboard:Destroy()
		moveHintBillboard = nil
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "OceanTD_MoveHintBillboard"
	bb.AlwaysOnTop = true
	bb.Active = false
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(MOVE_ICON_SIZE, MOVE_ICON_SIZE)
	bb.StudsOffset = Vector3.zero
	bb.MaxDistance = 2000
	bb.Adornee = ghost
	bb.Parent = playerGui
	moveHintImage.AnchorPoint = Vector2.new(0.5, 0.5)
	moveHintImage.Position = UDim2.fromScale(0.5, 0.5)
	moveHintImage.Size = UDim2.fromScale(1, 1)
	moveHintImage.Visible = true
	moveHintImage.Parent = bb
	moveHintBillboard = bb
end

stopMoveHintAttract = function()
	moveHintPulseToken += 1
	if moveHintScale then
		moveHintScale.Scale = 1
	end
end

startMoveHintAttract = function()
	if not moveHintImage then
		return
	end
	stopMoveHintAttract()
	local token = moveHintPulseToken
	local scale = moveHintScale
	if not scale or scale.Parent ~= moveHintImage then
		scale = Instance.new("UIScale")
		scale.Name = "MoveHintScale"
		scale.Parent = moveHintImage
		moveHintScale = scale
	end
	scale.Scale = 0.05
	moveHintImage.Visible = true
	task.spawn(function()
		local t0 = os.clock()
		while token == moveHintPulseToken and scale.Parent do
			local u = math.clamp((os.clock() - t0) / MOVE_HINT_SCALE_IN_SEC, 0, 1)
			local a = 1 - (1 - u) * (1 - u)
			scale.Scale = 0.05 + 0.95 * a
			if u >= 1 then
				break
			end
			RunService.RenderStepped:Wait()
		end
		local t1 = os.clock()
		while token == moveHintPulseToken and scale.Parent and aimPinnedToHand and mode == MODE_AIM do
			local wave = (math.sin((os.clock() - t1) * MOVE_HINT_PULSE_SPEED) + 1) * 0.5
			scale.Scale = 1 + MOVE_HINT_PULSE_AMP * wave
			RunService.RenderStepped:Wait()
		end
		if token == moveHintPulseToken and scale.Parent then
			scale.Scale = 1
		end
	end)
end

releaseHandPin = function()
	if aimPinnedToHand then
		aimPinnedToHand = false
		stopMoveHintAttract()
	end
end

local function readGhostBaseColor(part: BasePart): Color3
	local r = part:GetAttribute("OceanTD_GhostBaseR")
	local g = part:GetAttribute("OceanTD_GhostBaseG")
	local b = part:GetAttribute("OceanTD_GhostBaseB")
	if typeof(r) == "number" and typeof(g) == "number" and typeof(b) == "number" then
		return Color3.new(r, g, b)
	end
	return part.Color
end

local function updateGhostPulse()
	if not ghost then
		return
	end
	local baseMat = ghostBaseMaterial or Enum.Material.Pebble
	local phase = (math.sin(os.clock() * GHOST_PULSE_SPEED) + 1) * 0.5
	ghost.Material = if phase >= 0.5 then Enum.Material.Neon else baseMat
	ghost.Transparency = 0.4
	CoralVisual.setGhostValidColors(ghost, validSpot, ghostBaseColor, GHOST_INVALID_COLOR)
	-- Match ✓ background to the ghost neon flash (bright ↔ hunter green).
	if checkBtn and checkBtn.Visible then
		checkBtn.BackgroundColor3 = CHECK_BRIGHT_GREEN:Lerp(CHECK_HUNTER_GREEN, phase)
	end
	SelectRing.ensure(placeSelectRing, ghost, playerGui)
	SelectRing.pulse(placeSelectRing)
end

local function updateGhostAt(anchorPos: Vector3)
	local speciesId = armedItemId and getSpeciesIdForItem(armedItemId)
	if not speciesId then
		return
	end
	anchorPos = resolvePlaceAnchor(anchorPos)
	placeAnchor = anchorPos
	if aimPinnedToHand then
		-- Still in-hand: don't treat floating hold as an invalid plant spot.
		validSpot = true
		rejectReason = nil
	else
		validSpot, rejectReason = evaluatePos(anchorPos)
	end
	if not ghost then
		local ghostDiameter: number? = nil
		ghostPlaceVariant = nil
		ghostPlaceScale = nil
		ghostPlaceScaleWidth = nil
		ghostPlaceScaleHeight = nil
		ghostPlaceFacingYaw = nil
		if speciesId == "BrainCoral" then
			ghostDiameter = ghostPlaceDiameter or CoralVisual.randomBrainDiameter()
			ghostPlaceDiameter = ghostDiameter
		elseif CoralVisual.isSeaFan(speciesId) then
			ghostPlaceDiameter = nil
			ghostPlaceVariant = 1
			ghostPlaceScale, ghostPlaceScaleWidth, ghostPlaceScaleHeight = CoralVisual.randomSeaFanScales()
			-- Default upright; player rotates with chrome. Do not auto-face the character.
			ghostPlaceFacingYaw = 0
		elseif CoralVisual.isMeshSpecies(speciesId) then
			ghostPlaceDiameter = nil
			ghostPlaceVariant = CoralVisual.randomMeshVariant(speciesId)
			ghostPlaceScale = CoralVisual.randomMeshScale(speciesId)
			-- FireCoral (and any other yaw mesh): random facing; no rotate chrome.
			if CoralVisual.needsFacingYaw(speciesId) then
				ghostPlaceFacingYaw = CoralVisual.randomFacingYaw()
			end
		else
			ghostPlaceDiameter = nil
		end
		ghost = CoralVisual.create(speciesId, anchorPos, {
			ghost = true,
			valid = validSpot,
			diameter = ghostDiameter,
			sizeClass = 1,
			variantIndex = ghostPlaceVariant,
			scaleMult = ghostPlaceScale,
			scaleWidth = ghostPlaceScaleWidth,
			scaleHeight = ghostPlaceScaleHeight,
			facingYaw = ghostPlaceFacingYaw,
			plotCFrame = (function()
				local mir = ClientPlot.get()
				return if mir then mir.cframe else nil
			end)(),
		})
		if ghost then
			ghost.Parent = Workspace
			ensureWarnBillboard(ghost)
			ghostBaseColor = readGhostBaseColor(ghost)
			local sp = SpeciesCatalog.get(speciesId)
			if CoralVisual.isMeshSpecies(speciesId) then
				ghostBaseMaterial = Enum.Material.ForceField
			else
				ghostBaseMaterial = if sp then sp.material else Enum.Material.Pebble
			end
			if pendingGhostScaleIn then
				pendingGhostScaleIn = false
				startGhostScaleIn(ghost)
			end
			-- Range preview until place confirms or cancels (ghost cleared).
			local sid = speciesId
			CoralRangeRings.show(ghost, function()
				return ghost
			end, function()
				return CoralSize.statsFor(1, sid).range
			end)
		end
	else
		if CoralVisual.isSeaFan(speciesId) then
			-- Keep player-adjusted yaw; seed 0 only when unset.
			if typeof(ghostPlaceFacingYaw) ~= "number" then
				ghostPlaceFacingYaw = 0
			end
			local mir = ClientPlot.get()
			CoralVisual.alignMeshToSurface(ghost, anchorPos, ghostPlaceFacingYaw, nil, if mir then mir.cframe else nil)
		elseif CoralVisual.needsFacingYaw(speciesId) then
			if typeof(ghostPlaceFacingYaw) ~= "number" then
				ghostPlaceFacingYaw = CoralVisual.randomFacingYaw()
			end
			local mir = ClientPlot.get()
			CoralVisual.alignMeshToSurface(ghost, anchorPos, ghostPlaceFacingYaw, nil, if mir then mir.cframe else nil)
		elseif CoralVisual.isMeshSpecies(speciesId) then
			CoralVisual.alignMeshToSurface(ghost, anchorPos)
		else
			ghost.CFrame = CFrame.new(anchorPos)
		end
		CoralVisual.setGhostValidColors(ghost, validSpot, ghostBaseColor, GHOST_INVALID_COLOR)
	end
	updateGhostPulse()
	syncBlockFlashForAim(anchorPos)
	ClientPlot.setOutOfPlotFlash(not aimPinnedToHand and rejectReason == "Out Of Plot")
	if warnLabel then
		if validSpot then
			warnLabel.Text = ""
			warnLabel.Visible = false
		else
			warnLabel.Text = rejectReason or "Can't Place"
			warnLabel.Visible = true
		end
	end
	-- ✓/X + move icon appear with the ghost (not after a second tap).
	makeConfirmUi()
	setMoveHintVisible(true)
	syncConfirmButtons()
end

-- Chrome layout/hit-test live in PlaceConfirmChrome / PlaceConfirmHitTest (register budget).

local function syncConfirmButtonsImpl()
	-- Intro owns button tween layout; once parked, always sync ✓ visibility.
	if PlaceArmDisarmAnim.isArmIntroAnimating() and mode ~= MODE_CONFIRM then
		return
	end
	if not confirmGui or not checkBtn or not cancelBtn or not ghost then
		return
	end

	-- Hot-reload / partial UI: rebuild so SeaFan rotate controls exist.
	local rotAlive = rotLeftBtn ~= nil and rotLeftBtn.Parent ~= nil and rotRightBtn ~= nil and rotRightBtn.Parent ~= nil
	if not rotAlive then
		makeConfirmUi()
		if not confirmGui or not checkBtn or not cancelBtn or not ghost then
			return
		end
	end

	-- Move icon tracks the ghost: live while aiming/dragging, frozen when parked in Confirm.
	local aiming = mode == MODE_AIM or confirmDragging or aimFingerDown or backpackDrag or aimPinnedToHand
	if aiming or not chromeScreenPos then
		if aimPinnedToHand and ghost then
			local cam = Workspace.CurrentCamera
			if cam then
				local sp, _ = cam:WorldToViewportPoint(ghost.Position)
				if sp.Z > 0 then
					chromeScreenPos = Vector2.new(sp.X, sp.Y)
				else
					chromeScreenPos = getPlaceAimScreenPos()
				end
			else
				chromeScreenPos = getPlaceAimScreenPos()
			end
		else
			chromeScreenPos = getPlaceAimScreenPos()
		end
	end

	if moveHintImage then
		moveHintImage.Visible = true
		attachMoveHintToGhost()
	end

	-- Visibility first so feet layout can center X-only vs ✓+X pair.
	checkBtn.Visible = validSpot and (mode == MODE_CONFIRM or gamepadPlacement)
	cancelBtn.Visible = true
	local showRot = armedItemId == "SeaFan"
		or CoralVisual.isSeaFan(if armedItemId then getSpeciesIdForItem(armedItemId) else nil)
		or (armedItemId == "BrainCoral" and BrainSnapPreview.isSnapped())
	local bb, adornee = PlaceConfirmChrome.layoutOnTorso(
		BTN_SIZE,
		playerGui,
		confirmGui,
		chromeBillboard,
		chromeAdorneePart,
		checkBtn,
		cancelBtn,
		rotLeftBtn,
		rotRightBtn,
		showRot
	)
	chromeBillboard = bb
	chromeAdorneePart = adornee
	local showWord = (math.floor(os.clock()) % 2) == 1
	cancelBtn.Text = if showWord then "CANCEL" else "X"
	cancelBtn.TextStrokeColor3 = if showWord then Color3.fromRGB(60, 15, 18) else Color3.new(1, 1, 1)
	cancelBtn.TextStrokeTransparency = 0
	if checkBtn.Visible then
		local last = UserInputService:GetLastInputType()
		local gamepad = last == Enum.UserInputType.Gamepad1
			or last == Enum.UserInputType.Gamepad2
			or last == Enum.UserInputType.Gamepad3
			or last == Enum.UserInputType.Gamepad4
			or gamepadPlacement
		local confirmPx = PlaceConfirmChrome.confirmBtnSize(BTN_SIZE)
		checkBtn.Size = UDim2.fromOffset(confirmPx, confirmPx)
		checkBtn.TextColor3 = Color3.new(1, 1, 1)
		checkBtn.ZIndex = 20
		PlaceConfirmChrome.syncConfirmFace(checkBtn, showWord, gamepad)
	end
end
syncConfirmButtons = syncConfirmButtonsImpl

local SEA_FAN_ROT_STEP = math.rad(10)

local function rotateSeaFanGhost(dir: number)
	if not ghost or not placeAnchor then
		return
	end
	local sid = armedItemId and getSpeciesIdForItem(armedItemId)
	if not CoralVisual.isSeaFan(sid) then
		return
	end
	local yaw = ghostPlaceFacingYaw
	if typeof(yaw) ~= "number" then
		yaw = CoralVisual.readFacingYaw(ghost)
	end
	yaw += dir * SEA_FAN_ROT_STEP
	ghostPlaceFacingYaw = yaw
	local mir = ClientPlot.get()
	CoralVisual.alignMeshToSurface(ghost, placeAnchor, yaw, nil, if mir then mir.cframe else nil)
	UiHaptics.pulseShort()
end

local function rotateBrainSnapOrbit(dir: number)
	if armedItemId ~= "BrainCoral" or not ghost then
		return
	end
	local diam = BrainStack.diameterOfPart(ghost)
	if BrainSnapPreview.nudgeOrbit(dir, diam, nil) then
		local snap = BrainSnapPreview.getActive()
		if snap and ghost.Parent then
			ghost.CFrame = CFrame.new(snap.worldPos)
			placeAnchor = snap.worldPos
		end
		UiHaptics.pulseShort()
		syncConfirmButtons()
	end
end

local function makeConfirmUiImpl()
	if confirmGui and checkBtn and cancelBtn and moveHintImage and rotLeftBtn and rotRightBtn
		and rotLeftBtn.Parent and rotRightBtn.Parent
	then
		applyGamepadButtonLabels()
		return
	end
	destroyConfirmUi()
	local gui = Instance.new("ScreenGui")
	gui.Name = "OceanTD_PlaceConfirm"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- ScreenInsets.None; Position = GetMouseLocation
	gui.ClipToDeviceSafeArea = false
	pcall(function()
		(gui :: any).ScreenInsets = Enum.ScreenInsets.None
	end)
	gui.DisplayOrder = 12000
	gui.Parent = playerGui
	confirmGui = gui

	local move = Instance.new("ImageLabel")
	move.Name = "MoveIcon"
	move.BackgroundTransparency = 1
	move.Size = UDim2.fromOffset(MOVE_ICON_SIZE, MOVE_ICON_SIZE)
	move.Image = MOVE_ICON_IMAGE
	move.ScaleType = Enum.ScaleType.Fit
	move.Visible = false
	move.ZIndex = 2
	move.Parent = gui
	moveHintImage = move

	local function roundBtn(text: string, color: Color3): TextButton
		local btnPx = PlaceConfirmChrome.chromeBtnSize(BTN_SIZE)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(btnPx, btnPx)
		b.BackgroundColor3 = color
		b.BackgroundTransparency = 0 -- opaque so touch reliably hits the button
		b.Font = UiTheme.Font
		b.Text = text
		b.TextColor3 = Color3.new(1, 1, 1)
		b.TextTransparency = 0
		b.TextScaled = true
		b.TextStrokeTransparency = 0
		b.AutoButtonColor = true
		b.ZIndex = 20
		b.Parent = gui
		UiCircles.ensure(b)
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.12, 0)
		pad.PaddingBottom = UDim.new(0.12, 0)
		pad.PaddingLeft = UDim.new(0.06, 0)
		pad.PaddingRight = UDim.new(0.06, 0)
		pad.Parent = b

		local edge = Instance.new("UIStroke")
		edge.Name = "EdgeStroke"
		edge.Color = Color3.new(1, 1, 1)
		edge.Thickness = 2
		edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		edge.Parent = b

		return b
	end

	checkBtn = roundBtn("Enter", Color3.fromRGB(40, 180, 80))
	cancelBtn = roundBtn("X", Color3.fromRGB(200, 50, 50))
	checkBtn.ZIndex = 20
	cancelBtn.ZIndex = 20
	rotLeftBtn = PlaceConfirmChrome.createRotateButton(gui, PlaceConfirmChrome.ROT_LEFT_ICON, "RotLeft")
	rotRightBtn = PlaceConfirmChrome.createRotateButton(gui, PlaceConfirmChrome.ROT_RIGHT_ICON, "RotRight")
	rotLeftBtn.ZIndex = 5
	rotRightBtn.ZIndex = 5
	applyGamepadButtonLabels()

	local function markChromePointerDown(claimed: string)
		-- Gui Confirm/Cancel always wins (UIS may have already tried to re-park under the button).
		local fromGuiChrome = claimed == "check" or claimed == "cancel"
		if not fromGuiChrome then
			-- Only a press that *starts* on chrome counts. Sliding onto rot mid-drag must not steal.
			if aimFingerDown or backpackDrag or confirmDragging or confirmPressOrigin ~= nil then
				return
			end
		end
		local screenPos = UserInputService:GetMouseLocation()
		local resolved = PlaceConfirmHitTest.resolveTarget(screenPos, checkBtn, cancelBtn, playerGui, rotLeftBtn, rotRightBtn)
		-- If ✓/X received the press (AutoButtonColor), trust that over disc overlap with rot.
		local target: string?
		if claimed == "check" or claimed == "cancel" then
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
		-- Gui button claim wins: never let a later flaky resolve downgrade Confirm → Cancel.
		if chromeBtnPointerDown and chromePressTarget == "check" and target == "cancel" then
			return
		end
		if target == "check" or not chromeBtnPointerDown then
			chromePressTarget = target
			chromeBtnPointerDown = true
		elseif chromePressTarget ~= "check" then
			chromePressTarget = target
			chromeBtnPointerDown = true
		end
		aimFingerDown = false
		confirmPressOrigin = nil
		confirmDragging = false
		placePointerHeld = false
		if target == "rotLeft" or target == "rotRight" then
			local dir = if target == "rotLeft" then 1 else -1
			local btn = if target == "rotLeft" then rotLeftBtn else rotRightBtn
			PlaceConfirmChrome.beginRotateHold(btn, function()
				if BrainSnapPreview.isSnapped() then
					rotateBrainSnapOrbit(dir)
				else
					rotateSeaFanGhost(dir)
				end
			end)
		else
			PlaceConfirmChrome.stopRotateHold()
		end
	end

	-- MouseButton1Down fires on the button; also blocks ghost-aim if UIS already peeked.
	checkBtn.MouseButton1Down:Connect(function()
		markChromePointerDown("check")
	end)
	cancelBtn.MouseButton1Down:Connect(function()
		markChromePointerDown("cancel")
	end)
	rotLeftBtn.MouseButton1Down:Connect(function()
		markChromePointerDown("rotLeft")
	end)
	rotRightBtn.MouseButton1Down:Connect(function()
		markChromePointerDown("rotRight")
	end)
	checkBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			markChromePointerDown("check")
		end
	end)
	cancelBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			markChromePointerDown("cancel")
		end
	end)
	rotLeftBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			markChromePointerDown("rotLeft")
		end
	end)
	rotRightBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			markChromePointerDown("rotRight")
		end
	end)
	-- Native button click — primary commit path (InputEnded is backup).
	checkBtn.Activated:Connect(function()
		if mode ~= MODE_CONFIRM and not gamepadPlacement then
			return
		end
		chromeBtnPointerDown = false
		chromePressTarget = nil
		PlaceConfirmChrome.stopRotateHold()
		onCheck()
	end)
	cancelBtn.Activated:Connect(function()
		if mode == MODE_OFF then
			return
		end
		chromeBtnPointerDown = false
		chromePressTarget = nil
		PlaceConfirmChrome.stopRotateHold()
		onCancel()
	end)
end
makeConfirmUi = makeConfirmUiImpl

local function stopAimLoop()
	if aimConn then
		aimConn:Disconnect()
		aimConn = nil
	end
end

local function keepCameraFrozen()
	if camera and savedCameraCFrame then
		camera.CFrame = savedCameraCFrame
	end
end

local animEnv: PlaceArmDisarmAnim.Env = {
	modeOff = MODE_OFF,
	playerGui = playerGui,
	camera = camera,
	getMode = function()
		return mode
	end,
	getGhost = function()
		return ghost
	end,
	setGhost = function(v)
		ghost = v
	end,
	getPlaceAnchor = function()
		return placeAnchor
	end,
	setPlaceAnchor = function(v)
		placeAnchor = v
	end,
	getConfirmPos = function()
		return confirmPos
	end,
	getArmedItemId = function()
		return armedItemId
	end,
	getGhostBaseColor = function()
		return ghostBaseColor
	end,
	setGhostBaseColor = function(v)
		ghostBaseColor = v
	end,
	setGhostBaseMaterial = function(v)
		ghostBaseMaterial = v
	end,
	setWarnLabel = function(v)
		warnLabel = v
	end,
	getConfirmGui = function()
		return confirmGui
	end,
	getChromeBillboard = function()
		return chromeBillboard
	end,
	setChromeBillboard = function(v)
		chromeBillboard = v
	end,
	getChromeAdorneePart = function()
		return chromeAdorneePart
	end,
	setChromeAdorneePart = function(v)
		chromeAdorneePart = v
	end,
	getCheckBtn = function()
		return checkBtn
	end,
	getCancelBtn = function()
		return cancelBtn
	end,
	getRotLeftBtn = function()
		return rotLeftBtn
	end,
	getRotRightBtn = function()
		return rotRightBtn
	end,
	getMoveHintImage = function()
		return moveHintImage
	end,
	getPendingDisarmSlotScreen = function()
		return pendingDisarmSlotScreen
	end,
	setPendingDisarmSlotScreen = function(v)
		pendingDisarmSlotScreen = v
	end,
	getPendingArmSlotScreen = function()
		return pendingArmSlotScreen
	end,
	setPendingArmSlotScreen = function(v)
		pendingArmSlotScreen = v
	end,
	getAimPinnedToHand = function()
		return aimPinnedToHand
	end,
	setAimPinnedToHand = function(v)
		aimPinnedToHand = v
	end,
	getAimPinOrigin = function()
		return aimPinOrigin
	end,
	setAimPinOrigin = function(v)
		aimPinOrigin = v
	end,
	getAimFingerDown = function()
		return aimFingerDown
	end,
	setAimFingerDown = function(v)
		aimFingerDown = v
	end,
	getPlacePointerHeld = function()
		return placePointerHeld
	end,
	keepCameraFrozen = keepCameraFrozen,
	detachMoveHintToScreen = detachMoveHintToScreen,
	stopMoveHintAttract = stopMoveHintAttract,
	startMoveHintAttract = startMoveHintAttract,
	releaseHandPin = releaseHandPin,
	makeConfirmUi = makeConfirmUi,
	syncConfirmButtons = syncConfirmButtons,
	setMoveHintVisible = setMoveHintVisible,
	stopAimLoop = stopAimLoop,
	stopGhostScaleIn = stopGhostScaleIn,
	updateGhostAt = updateGhostAt,
	resolveParkPos = resolveParkPos,
	startAimLoop = function()
		startAimLoop()
	end,
	setPendingGhostScaleIn = function(v)
		pendingGhostScaleIn = v
	end,
}

startAimLoop = function()
	stopAimLoop()
	PlaceRaycast.resetAimThrottle()
	aimConn = RunService.RenderStepped:Connect(function(dt)
		if mode ~= MODE_AIM then
			return
		end
		do
			local last = UserInputService:GetLastInputType()
			if last ~= Enum.UserInputType.Touch then
				aimRaiseForTouch = false
			end
		end
		keepCameraFrozen()
		if postPlaceWaiting or PlaceArmDisarmAnim.isArmIntroAnimating() then
			return
		end
		updateGhostPulse()
		PlaceBlockFlash.update()
		syncConfirmButtons()

		if gamepadPlacement then
			local stick = PlaceAimScreen.readThumbstick1()
			local mag = stick.Magnitude
			if mag > GAMEPAD_STICK_DEADZONE and gamepadCursor then
				releaseHandPin()
				local dir = stick.Unit
				local speed = GAMEPAD_AIM_SPEED * math.clamp((mag - GAMEPAD_STICK_DEADZONE) / (1 - GAMEPAD_STICK_DEADZONE), 0, 1)
				gamepadCursor = PlaceAimScreen.clampGamepadCursor(gamepadCursor + dir * speed * dt)
			end
			if aimPinnedToHand then
				local handPos = HandOrb.getHoldWorldPos()
				if handPos then
					updateGhostAt(handPos)
				end
				return
			end
			chromeScreenPos = nil
			local pos = raycastAimThrottled(dt)
			if pos then
				updateGhostAt(pos)
			end
			return
		end

		if backpackDrag then
			releaseHandPin()
			return
		end
		if aimFingerDown then
			releaseHandPin()
			local pos = raycastAimThrottled(dt)
			if pos then
				updateGhostAt(pos)
			end
			return
		end
		if aimPinnedToHand then
			local now = UserInputService:GetMouseLocation()
			if aimPinOrigin and (now - aimPinOrigin).Magnitude >= AIM_UNPIN_PX then
				releaseHandPin()
			else
				local handPos = HandOrb.getHoldWorldPos()
				if handPos then
					updateGhostAt(handPos)
				end
				return
			end
		end
		if aimPinnedToCenter then
			local now = UserInputService:GetMouseLocation()
			if aimPinOrigin and (now - aimPinOrigin).Magnitude >= AIM_UNPIN_PX then
				aimPinnedToCenter = false
			else
				local pos = raycastAimThrottled(dt)
				if pos then
					updateGhostAt(pos)
				end
				return
			end
		end
		local pos = raycastAimThrottled(dt)
		if pos then
			updateGhostAt(pos)
		end
	end)
end

beginAim = function(itemId: string, scaleIn: boolean?, keepChromePinned: boolean?)
	postPlaceWaiting = false
	placeCommitBusy = false
	PlaceArmDisarmAnim.stopArmIntro()
	armedItemId = itemId
	mode = MODE_AIM
	confirmPos = nil
	backpackDrag = false
	aimFingerDown = false
	confirmDragging = false
	confirmPressOrigin = nil
	chromeScreenPos = nil
	aimPinnedToCenter = false
	aimPinnedToHand = true
	aimPinOrigin = UserInputService:GetMouseLocation()
	-- Default: mouse centers on cursor. Touch raise only when the selecting input was touch.
	aimRaiseForTouch = false
	do
		local last = UserInputService:GetLastInputType()
		if last == Enum.UserInputType.Touch then
			aimRaiseForTouch = true
		end
	end

	local spId = getSpeciesIdForItem(itemId)
	local sp = spId and SpeciesCatalog.get(spId)
	local seedColor = if sp then sp.colorMin:Lerp(sp.colorMax, 0.5) else Color3.fromRGB(255, 220, 80)

	if gamepadPlacement and not gamepadCursor then
		gamepadCursor = PlaceAimScreen.resetGamepadCursor()
	end

	freeze()
	stopAimLoop()

	local postPlace = scaleIn == true
	if postPlace then
		-- After plant: ghost appears in-hand (no backpack-slot fly-in).
		pendingGhostScaleIn = true
		HandOrb.arm(seedColor)
		local startPos = HandOrb.getHoldWorldPos() or raycastForPlace()
		if startPos then
			updateGhostAt(startPos)
		end
		if ghostBaseColor then
			HandOrb.arm(ghostBaseColor)
		elseif ghost then
			HandOrb.arm(ghost.Color)
		end
		startMoveHintAttract()
		startAimLoop()
		log("Aim mode", itemId, if gamepadPlacement then "gamepad" else "pointer", "postPlace")
		return
	end

	-- Armed from backpack: fly ghost + move from the item cell into the hand.
	pendingGhostScaleIn = false
	PlaceArmDisarmAnim.playArmIntroFromSlot(animEnv, itemId, seedColor, function()
		if gamepadPlacement then
			local handPos = HandOrb.getHoldWorldPos()
			if handPos and camera then
				local spoint, _ = camera:WorldToViewportPoint(handPos)
				if spoint.Z > 0 then
					gamepadCursor = PlaceAimScreen.clampGamepadCursor(Vector2.new(spoint.X, spoint.Y))
				end
			end
		end
		startAimLoop()
		log("Aim mode", itemId, if gamepadPlacement then "gamepad" else "pointer", "fromSlot")
	end, keepChromePinned == true)
end

-- Drag-out from backpack: skip slot intro, aim under the finger immediately.
local function beginAimFromDrag(itemId: string)
	postPlaceWaiting = false
	PlaceArmDisarmAnim.stopArmIntro()
	armedItemId = itemId
	mode = MODE_AIM
	confirmPos = nil
	aimFingerDown = false
	confirmDragging = false
	confirmPressOrigin = nil
	chromeScreenPos = nil
	aimPinnedToCenter = false
	aimPinnedToHand = false
	aimPinOrigin = nil
	pendingGhostScaleIn = true
	aimRaiseForTouch = UserInputService:GetLastInputType() == Enum.UserInputType.Touch

	local spId = getSpeciesIdForItem(itemId)
	local sp = spId and SpeciesCatalog.get(spId)
	local seedColor = if sp then sp.colorMin:Lerp(sp.colorMax, 0.5) else Color3.fromRGB(255, 220, 80)
	HandOrb.arm(seedColor)
	freeze()
	stopAimLoop()
	local pos = raycastForPlace()
	if pos then
		updateGhostAt(pos)
	end
	if ghostBaseColor then
		HandOrb.arm(ghostBaseColor)
	end
	startMoveHintAttract()
	startAimLoop()
	log("Aim mode", itemId, "drag")
end

local function exitPlacement(clearArmed: boolean)
	placeResumeToken += 1
	postPlaceWaiting = false
	placeCommitBusy = false
	pendingGhostScaleIn = false
	PlaceArmDisarmAnim.stopDisarmAnim()
	PlaceArmDisarmAnim.stopOutgoingFlyback()
	PlaceArmDisarmAnim.stopArmIntro()
	stopMoveHintAttract()
	chromeBtnPointerDown = false
	mode = MODE_OFF
	backpackDrag = false
	aimFingerDown = false
	placePointerHeld = false
	confirmDragging = false
	confirmPressOrigin = nil
	chromeScreenPos = nil
	aimPinnedToCenter = false
	aimPinnedToHand = false
	aimPinOrigin = nil
	stopCheckPrompt()
	stopAimLoop()
	clearGhost()
	destroyConfirmUi()
	unfreeze()
	confirmPos = nil
	armedItemId = nil
	HandOrb.clear()
	if clearArmed then
		pendingDisarmSlotScreen = nil
		pendingArmSlotScreen = nil
		queuedSwitchItemId = nil
		gamepadPlacement = false
		gamepadCursor = nil
		InventoryState.clearSelection()
	end
	log("Placement off")
end

local function commitPlace()
	if placeCommitBusy then
		return
	end
	if not armedItemId or not confirmPos or not validSpot then
		return
	end
	if postPlaceWaiting or PlaceArmDisarmAnim.isDisarmAnimating() or PlaceArmDisarmAnim.isArmIntroAnimating() then
		return
	end
	placeCommitBusy = true
	local placePos = confirmPos
	if ghost and ghost.Parent and armedItemId == "BrainCoral" then
		-- Save the exact stacked pose the ghost shows (not a stale aim sample).
		placePos = ghost.Position
		placeAnchor = placePos
		confirmPos = placePos
	end
	local vfxColor = if ghost then ghost.Color else Color3.fromRGB(100, 200, 255)
	-- Sound + hand-orb fly on ✓ immediately; don't wait for the server.
	PlaceVfx.playSound(placePos)
	HandOrb.flyToPlant(placePos)

	local rf = Remotes.getFunction("RequestPlace")
	local placePayload: any = {
		diameter = ghostPlaceDiameter,
		placementHue = if armedItemId then InventoryState.getPlacementHue(armedItemId) else nil,
	}
	if armedItemId == "BrainCoral" then
		local snap = BrainSnapPreview.getActive()
		if snap and snap.valid and typeof(snap.hostPlaceId) == "string" and snap.hostPlaceId ~= "" then
			placePayload.parentPlaceId = snap.hostPlaceId
		end
	end
	if CoralVisual.isMeshSpecies(armedItemId) or ghostPlaceVariant ~= nil then
		local yaw = ghostPlaceFacingYaw
		if typeof(yaw) ~= "number" and ghost then
			yaw = CoralVisual.readFacingYaw(ghost)
		end
		if typeof(yaw) ~= "number" then
			yaw = 0
		end
		placePayload.variantIndex = ghostPlaceVariant
		placePayload.scaleMult = ghostPlaceScale
		placePayload.sizeClass = 1
		placePayload.scaleWidth = ghostPlaceScaleWidth
		placePayload.scaleHeight = ghostPlaceScaleHeight
		placePayload.facingYaw = yaw
	end
	local result = rf:InvokeServer(armedItemId, placePos, placePayload)
	if typeof(result) == "table" and result.ok then
		log("Committed", armedItemId)
		UiHaptics.rampOpen(1)
		local keepId = armedItemId :: string
		local vfxPos = (typeof(result.worldPos) == "Vector3" and result.worldPos) or placePos
		PlaceVfx.playVisuals(vfxPos, vfxColor)
		clearGhost()
		destroyConfirmUi()
		confirmPos = nil
		-- Hold freeze for 1s, then bring the next ghost in with a scale-up.
		postPlaceWaiting = true
		mode = MODE_AIM
		armedItemId = keepId
		stopAimLoop()
		freeze()
		placeResumeToken += 1
		local token = placeResumeToken
		aimConn = RunService.RenderStepped:Connect(function()
			if token ~= placeResumeToken or mode == MODE_OFF then
				return
			end
			keepCameraFrozen()
		end)
		task.delay(POST_PLACE_GHOST_DELAY, function()
			if token ~= placeResumeToken then
				return
			end
			if mode == MODE_OFF or not InventoryState.isOpen() then
				return
			end
			if armedItemId ~= keepId then
				return
			end
			beginAim(keepId, true)
		end)
	else
		local code = typeof(result) == "table" and result.errorCode or "Reject"
		log("Place rejected", code)
		placeCommitBusy = false
		-- Place failed: cancel fly and put orb back in hand.
		HandOrb.clear()
		if ghostBaseColor then
			HandOrb.arm(ghostBaseColor)
		elseif ghost then
			HandOrb.arm(ghost.Color)
		end
		if code == "OutOfPlot" or code == "SpotTaken" or code == "PlaceCap" then
			rejectReason = if code == "OutOfPlot"
				then "Out Of Plot"
				elseif code == "PlaceCap" then "Max Placed"
				else "Spot Taken"
			validSpot = false
			if ghost then
				ghost.Color = GHOST_INVALID_COLOR
			end
			if warnLabel then
				warnLabel.Text = rejectReason
				warnLabel.Visible = true
			end
			ClientPlot.setOutOfPlotFlash(code == "OutOfPlot")
			if code == "SpotTaken" and placePos then
				syncBlockFlashForAim(placePos)
			end
		elseif code == "NoSeeds" then
			rejectReason = "No Seeds"
			validSpot = false
			if warnLabel then
				warnLabel.Text = rejectReason
				warnLabel.Visible = true
			end
		end
	end
end

onCheck = function()
	if not placeAnchor or not validSpot then
		return
	end
	-- Gamepad: place from Aim with one A press (no park/confirm step).
	if gamepadPlacement then
		if mode == MODE_OFF then
			return
		end
		confirmPos = placeAnchor
		commitPlace()
		return
	end
	if mode ~= MODE_CONFIRM then
		return
	end
	confirmPos = placeAnchor
	commitPlace()
end

onCancel = function()
	if PlaceArmDisarmAnim.isDisarmAnimating() or mode == MODE_OFF then
		return
	end
	if PlaceArmDisarmAnim.isArmIntroAnimating() then
		PlaceArmDisarmAnim.stopArmIntro()
	end
	if gamepadPlacement then
		-- Deactivate coral, keep backpack open, restore D-pad list select.
		PlaceArmDisarmAnim.playDisarmOutro(animEnv, function()
			gamepadPlacement = false
			gamepadCursor = nil
			exitPlacement(false)
			InventoryState.clearSelection()
			fireGamepadReturnToList()
		end)
		return
	end
	-- Pointer: exit placement (deactivate armed coral) after scale-out.
	PlaceArmDisarmAnim.playDisarmOutro(animEnv, function()
		exitPlacement(true)
	end)
end

local function enterConfirm(worldPos: Vector3)
	-- Parking must win over a mid-flight arm intro (otherwise ✓ sync is skipped).
	if PlaceArmDisarmAnim.isArmIntroAnimating() then
		PlaceArmDisarmAnim.stopArmIntro()
	end
	local introFullSize = PlaceArmDisarmAnim.getArmIntroFullSize()
	if ghost and ghost.Parent and introFullSize then
		ghost.Size = introFullSize
		ghost.Transparency = 0.4
	end
	mode = MODE_CONFIRM
	backpackDrag = false
	confirmDragging = false
	confirmPressOrigin = nil
	aimFingerDown = false
	placePointerHeld = false
	aimPinnedToHand = false
	aimPinnedToCenter = false
	confirmPos = worldPos
	placeAnchor = worldPos
	chromeScreenPos = getPlaceAimScreenPos() -- freeze ✓/X + move on the aim point
	PlaceVfx.playParkSound(worldPos)
	makeConfirmUi()
	updateGhostAt(worldPos)
	stopAimLoop()
	aimConn = RunService.RenderStepped:Connect(function()
		if mode ~= MODE_CONFIRM then
			return
		end
		keepCameraFrozen()
		updateGhostPulse()
		PlaceBlockFlash.update()
		syncConfirmButtons()
	end)
	syncConfirmButtons()
	log("Confirm mode", if validSpot then "valid" else (rejectReason or "invalid"))
end

-- World press (or drag off the backpack): show ✓ while the finger is still down, then drag to slide.
local function parkAtPointer(screenPos: Vector2)
	if gamepadPlacement then
		return
	end
	if PlaceArmDisarmAnim.isArmIntroAnimating() then
		PlaceArmDisarmAnim.abortArmIntroToAim(animEnv, screenPos)
	else
		releaseHandPin()
	end
	-- Mouse click: same hardware ray as click-drag. resolveParkPos is for touch (raised finger).
	local pos: Vector3?
	if PlaceAimScreen.touchHeld() or PlaceAimScreen.shouldRaiseGhost(aimRaiseForTouch, gamepadPlacement) then
		pos = resolveParkPos(screenPos)
	else
		pos = raycastForPlace() or resolveParkPos(screenPos)
	end
	if not pos then
		aimFingerDown = true
		placePointerHeld = true
		return
	end
	if mode ~= MODE_CONFIRM then
		enterConfirm(pos)
	else
		confirmPos = pos
		updateGhostAt(pos)
	end
	confirmPressOrigin = screenPos
	confirmDragging = true
end

function PlacementController.isActive(): boolean
	return mode ~= MODE_OFF
end

function PlacementController.isGamepadPlacement(): boolean
	return gamepadPlacement
end

function PlacementController.setGamepadPlacement(enabled: boolean)
	gamepadPlacement = enabled
	if enabled then
		if not gamepadCursor then
			gamepadCursor = PlaceAimScreen.resetGamepadCursor()
		end
	else
		gamepadCursor = nil
		stopCheckPrompt()
	end
end

function PlacementController.onGamepadReturnToList(cb: () -> ())
	table.insert(gamepadReturnCbs, cb)
end

-- Capture backpack cell centers before the green pulse moves (disarm → old, arm → new).
function PlacementController.setSwitchSlotScreens(disarmTo: Vector2?, armFrom: Vector2?)
	pendingDisarmSlotScreen = disarmTo
	pendingArmSlotScreen = armFrom
end

function PlacementController.beginForItem(itemId: string)
	if InventoryState.isBuildModalBlocking() then
		pendingDisarmSlotScreen = nil
		pendingArmSlotScreen = nil
		queuedSwitchItemId = nil
		return
	end
	if not ClientPlot.isReady() then
		warn("[PLACE] Plot not ready")
		pendingDisarmSlotScreen = nil
		pendingArmSlotScreen = nil
		queuedSwitchItemId = nil
		return
	end
	if not getSpeciesIdForItem(itemId) then
		warn("[PLACE] No species for", itemId)
		pendingDisarmSlotScreen = nil
		pendingArmSlotScreen = nil
		queuedSwitchItemId = nil
		return
	end
	-- Selecting a backpack coral cancels relocate (RelocateController listens to selection too).
	if PlaceArmDisarmAnim.isDisarmAnimating() then
		-- Full cancel fly-home in progress — arm this item when it finishes.
		queuedSwitchItemId = itemId
		pendingDisarmSlotScreen = nil
		return
	end
	-- Switching corals: fly old ghost home AND new ghost out at the same time.
	if mode ~= MODE_OFF then
		local nextId = queuedSwitchItemId or itemId
		queuedSwitchItemId = nil

		if PlaceArmDisarmAnim.isArmIntroAnimating() then
			PlaceArmDisarmAnim.stopArmIntro()
		end
		stopAimLoop()
		stopGhostScaleIn()
		stopMoveHintAttract()

		local worldPos = placeAnchor or confirmPos or (ghost and ghost.Position) or Vector3.zero
		local targetScreen = PlaceArmDisarmAnim.resolveDisarmTargetScreen(animEnv, armedItemId)
		PlaceVfx.playCancelSound(worldPos)

		local outGhost, outMove, outGui = PlaceArmDisarmAnim.detachGhostForSwitch(animEnv)
		PlaceArmDisarmAnim.startOutgoingFlyback(animEnv, outGhost, outMove, outGui, targetScreen, worldPos)

		confirmPos = nil
		chromeScreenPos = nil
		backpackDrag = false
		aimFingerDown = false
		confirmDragging = false
		confirmPressOrigin = nil
		chromeBtnPointerDown = false
		postPlaceWaiting = false

		-- Keep the same X at feet; only ghost + move icon crossfade.
		beginAim(nextId, nil, true)
		return
	end
	queuedSwitchItemId = nil
	beginAim(itemId)
end

function PlacementController.cancel()
	-- Always fly ghost + UI back into the backpack slot (X, re-click, etc.).
	onCancel()
end

-- Instant exit (no disarm outro) — used when picking a placed coral to relocate.
function PlacementController.forceExit()
	if mode == MODE_OFF and not PlaceArmDisarmAnim.isDisarmAnimating() then
		return
	end
	PlaceArmDisarmAnim.stopDisarmAnim()
	PlaceArmDisarmAnim.stopOutgoingFlyback()
	PlaceArmDisarmAnim.stopArmIntro()
	exitPlacement(true)
end

-- Drag-out from backpack (mobile) / click-drop (PC)
function PlacementController.notifyPointerDownFromBackpack(itemId: string, _screenPos: Vector2, fromTouch: boolean?)
	PlacementController.setGamepadPlacement(false)
	aimRaiseForTouch = fromTouch == true
	local function startDrag()
		beginAimFromDrag(itemId)
		backpackDrag = true
		aimFingerDown = true
		placePointerHeld = true
		-- beginAimFromDrag may overwrite from LastInputType — keep the caller's pointer kind.
		aimRaiseForTouch = fromTouch == true
		local pos = raycastForPlace()
		if pos then
			updateGhostAt(pos)
		end
	end
	if mode ~= MODE_OFF then
		if PlaceArmDisarmAnim.isDisarmAnimating() then
			return
		end
		-- Pulling the same coral during the slot→hand fly-in: follow the finger.
		-- Don't fly the ghost home first or the lift can happen before AIM is ready and ✓ never shows.
		if PlaceArmDisarmAnim.isArmIntroAnimating() and (armedItemId == nil or armedItemId == itemId) then
			parkAtPointer(_screenPos)
			backpackDrag = true
			aimFingerDown = true
			placePointerHeld = true
			aimRaiseForTouch = fromTouch == true
			return
		end
		PlaceArmDisarmAnim.playDisarmOutro(animEnv, function()
			exitPlacement(false)
			startDrag()
			parkAtPointer(_screenPos)
		end)
		return
	end
	startDrag()
	parkAtPointer(_screenPos)
end

function PlacementController.notifyPointerMove(_screenPos: Vector2)
	if mode ~= MODE_AIM and mode ~= MODE_CONFIRM then
		return
	end
	local pos = raycastForPlace()
	if pos then
		if mode == MODE_CONFIRM then
			confirmPos = pos
		end
		updateGhostAt(pos)
	end
end

function PlacementController.notifyPointerUp(_screenPos: Vector2)
	if mode == MODE_AIM then
		backpackDrag = false
		aimFingerDown = false
		placePointerHeld = false
		local pos = resolveParkPos(_screenPos)
		if pos then
			enterConfirm(pos)
		end
		return
	end
	if mode == MODE_CONFIRM then
		confirmDragging = false
	end
end

-- Wire selection → placement (PC tap in backpack)
InventoryState.onSelectionChanged(function(id)
	if id == nil then
		-- Backpack close clears selection first; onOpenChanged owns the fly-back there.
		if not InventoryState.isOpen() then
			return
		end
		if mode ~= MODE_OFF and not PlaceArmDisarmAnim.isDisarmAnimating() then
			onCancel()
		end
		return
	end
	PlacementController.beginForItem(id)
end)

-- Closing backpack ends placement so the player can move again.
InventoryState.onOpenChanged(function(isOpen)
	if not isOpen then
		if PlaceArmDisarmAnim.isDisarmAnimating() then
			return
		end
		if mode ~= MODE_OFF then
			PlaceArmDisarmAnim.playDisarmOutro(animEnv, function()
				exitPlacement(true)
			end)
		else
			exitPlacement(true)
		end
	end
end)

-- Hit tests live in PlaceConfirmHitTest (register budget).

table.insert(inputConns, UserInputService.InputBegan:Connect(function(input, _processed)
	PlaceAimScreen.trackTouch(input, false)
	if mode ~= MODE_OFF then
		notePlacePointerInput(input)
	end
	if PlaceAimScreen.isEmulatedMouse(input) then
		return
	end
	if mode == MODE_OFF then
		return
	end
	if PlaceArmDisarmAnim.isDisarmAnimating() then
		return
	end
	if PlaceArmDisarmAnim.isArmIntroAnimating() then
		-- Allow cancel during the slot→hand fly-in; ignore aim/place.
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.X or input.KeyCode == Enum.KeyCode.ButtonB then
			onCancel()
			return
		end
		local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1
		local isTouch = input.UserInputType == Enum.UserInputType.Touch
		if isMouse or isTouch then
			local screenPos = PlaceConfirmHitTest.pointerScreenPos(input)
			local target = PlaceConfirmHitTest.resolveTarget(screenPos, checkBtn, cancelBtn, playerGui, rotLeftBtn, rotRightBtn)
			if target then
				chromePressTarget = target
				chromeBtnPointerDown = true
				if target == "rotLeft" or target == "rotRight" then
					local dir = if target == "rotLeft" then 1 else -1
					local btn = if target == "rotLeft" then rotLeftBtn else rotRightBtn
					PlaceConfirmChrome.beginRotateHold(btn, function()
						if BrainSnapPreview.isSnapped() then
							rotateBrainSnapOrbit(dir)
						else
							rotateSeaFanGhost(dir)
						end
					end)
				end
			else
				-- Remember the press even if it starts on the backpack (drag-off parks).
				placePointerHeld = true
				aimRaiseForTouch = isTouch
				if not InventoryState.isPointerOverBackpack(screenPos) then
					parkAtPointer(screenPos)
				end
			end
		end
		return
	end
	if postPlaceWaiting then
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.X or input.KeyCode == Enum.KeyCode.ButtonB then
			onCancel()
		end
		return
	end
	if input.KeyCode == Enum.KeyCode.Escape then
		onCancel()
		return
	end

	-- Gamepad placement: A places immediately, B returns to backpack list.
	if gamepadPlacement then
		if input.KeyCode == Enum.KeyCode.ButtonA then
			onCheck()
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB then
			onCancel()
			return
		end
	elseif input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.KeypadEnter then
		-- Keyboard: Enter matches the confirm shortcut tip.
		if mode == MODE_CONFIRM then
			onCheck()
		end
		return
	elseif input.KeyCode == Enum.KeyCode.X then
		-- Mouse/keyboard: X matches the red cancel glyph — disarm coral.
		onCancel()
		return
	end

	local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1
	local isTouch = input.UserInputType == Enum.UserInputType.Touch
	if not isMouse and not isTouch then
		return
	end

	local screenPos = PlaceConfirmHitTest.pointerScreenPos(input)

	-- ✓ / X own the press: never start a ghost drag.
	-- BillboardGui often skips MouseButton1Click — commit happens on InputEnded.
	-- AbsolutePosition hit-tests on billboard chrome can mis-resolve Confirm as Cancel;
	-- never downgrade an existing Confirm claim.
	local chromeTarget = PlaceConfirmHitTest.resolveTarget(screenPos, checkBtn, cancelBtn, playerGui, rotLeftBtn, rotRightBtn)
	if chromeTarget then
		confirmPressOrigin = nil
		confirmDragging = false
		aimFingerDown = false
		if chromeBtnPointerDown and chromePressTarget == "check" and chromeTarget == "cancel" then
			return
		end
		if chromeTarget == "check" or not chromeBtnPointerDown or chromePressTarget ~= "check" then
			chromePressTarget = chromeTarget
			chromeBtnPointerDown = true
			if chromeTarget == "rotLeft" or chromeTarget == "rotRight" then
				local dir = if chromeTarget == "rotLeft" then 1 else -1
				local btn = if chromeTarget == "rotLeft" then rotLeftBtn else rotRightBtn
				PlaceConfirmChrome.beginRotateHold(btn, function()
					if BrainSnapPreview.isSnapped() then
						rotateBrainSnapOrbit(dir)
					else
						rotateSeaFanGhost(dir)
					end
				end)
			else
				PlaceConfirmChrome.stopRotateHold()
			end
		end
		return
	end
	-- Gui already claimed Confirm/Cancel this frame — never re-park under the button.
	if chromeBtnPointerDown then
		return
	end
	-- Touches on the open backpack list must not aim/park the ghost under the panel.
	if InventoryState.isPointerOverBackpack(screenPos) then
		confirmPressOrigin = nil
		confirmDragging = false
		aimFingerDown = false
		placePointerHeld = true
		return
	end
	-- Ignore gameProcessed for world aim/park: HUD/quickbar often marks clicks processed
	-- even when the press is meant for the plot, which left ghosts stuck without ✓.

	if mode == MODE_CONFIRM then
		-- Move icon is a grab handle: drag from it (don't wait for a second plot click).
		if PlaceConfirmHitTest.isOverGui(screenPos, moveHintImage) then
			confirmPressOrigin = screenPos
			confirmDragging = true
			return
		end
		-- Do not re-park on a bare click. That ray often goes through Confirm at the feet
		-- when hit-test misses, then ✓ places the wrong cell and the orb snaps back.
		-- Reposition via the move handle (or touch-drag below).
		if isTouch then
			confirmPressOrigin = screenPos
			confirmDragging = false
		end
		return
	end

	-- Aim / intro: world press parks immediately so ✓ shows while the finger is still down.
	if mode == MODE_AIM and not backpackDrag then
		parkAtPointer(screenPos)
	end
end))

table.insert(inputConns, UserInputService.InputChanged:Connect(function(input, _processed)
	if mode ~= MODE_OFF then
		notePlacePointerInput(input)
	end
	if PlaceAimScreen.isEmulatedMouse(input) then
		return
	end
	if postPlaceWaiting or mode == MODE_OFF or PlaceArmDisarmAnim.isDisarmAnimating() or chromeBtnPointerDown then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local now = PlaceConfirmHitTest.pointerScreenPos(input)
	if PlaceArmDisarmAnim.isArmIntroAnimating() then
		if (placePointerHeld or aimFingerDown) and not InventoryState.isPointerOverBackpack(now) then
			parkAtPointer(now)
		end
		return
	end
	if mode == MODE_AIM and placePointerHeld and not aimFingerDown and not backpackDrag then
		if not InventoryState.isPointerOverBackpack(now) then
			parkAtPointer(now)
			return
		end
	end
	if mode == MODE_AIM and (aimFingerDown or backpackDrag) then
		local pos = raycastForPlace()
		if pos then
			updateGhostAt(pos)
		end
		return
	end
	if mode == MODE_CONFIRM and confirmPressOrigin then
		if not confirmDragging then
			if (now - confirmPressOrigin).Magnitude < CONFIRM_DRAG_PX then
				return
			end
			confirmDragging = true
		end
		local pos = raycastForPlace()
		if pos then
			confirmPos = pos
			updateGhostAt(pos)
		end
	end
end))

table.insert(inputConns, UserInputService.InputEnded:Connect(function(input, _processed)
	if PlaceAimScreen.isEmulatedMouse(input) then
		return
	end
	PlaceAimScreen.trackTouch(input, true)
	if postPlaceWaiting or mode == MODE_OFF then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local screenPos = PlaceConfirmHitTest.pointerScreenPos(input)
	-- Cancel/check press: commit on release (backup if Activated didn't fire).
	if chromeBtnPointerDown then
		local target = chromePressTarget
		chromeBtnPointerDown = false
		chromePressTarget = nil
		aimFingerDown = false
		placePointerHeld = false
		confirmPressOrigin = nil
		confirmDragging = false
		if target == "rotLeft" or target == "rotRight" then
			PlaceConfirmChrome.stopRotateHold()
			return
		end
		PlaceConfirmChrome.stopRotateHold()
		if target == "check" then
			onCheck()
		elseif target == "cancel" then
			onCancel()
		end
		return
	end
	if PlaceArmDisarmAnim.isDisarmAnimating() then
		return
	end
	if mode == MODE_AIM then
		local overBackpack = InventoryState.isPointerOverBackpack(screenPos)
		local ghostOnPlot = not aimPinnedToHand
		local shouldPark = aimFingerDown or backpackDrag or ghostOnPlot or (placePointerHeld and not overBackpack)
		aimFingerDown = false
		backpackDrag = false
		placePointerHeld = false
		-- Select-tap lift is still on the backpack with the coral in-hand — don't park.
		if (overBackpack and not ghostOnPlot) or not shouldPark then
			return
		end
		-- Park where the finger lifted — even if release is over ✓/X. Cancel/confirm
		-- only run when the press *started* on those buttons (chromeBtnPointerDown).
		local pos = resolveParkPos(screenPos)
		if pos then
			enterConfirm(pos)
		end
		return
	end
	confirmDragging = false
	confirmPressOrigin = nil
end))

player.CharacterAdded:Connect(function()
	if mode ~= MODE_OFF then
		exitPlacement(true)
	end
end)

log("PlacementController ready")

return PlacementController
