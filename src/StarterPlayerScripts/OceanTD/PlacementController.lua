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
local PlacedCoralIndex = require(script.Parent:WaitForChild("PlacedCoralIndex"))
local PlaceVfx = require(script.Parent:WaitForChild("PlaceVfx"))
local HandOrb = require(script.Parent:WaitForChild("HandOrb"))
local SelectRing = require(script.Parent:WaitForChild("SelectRing"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))
local PlaceConfirmHitTest = require(script.Parent:WaitForChild("PlaceConfirmHitTest"))
local PlaceConfirmChrome = require(script.Parent:WaitForChild("PlaceConfirmChrome"))
local PlaceAimScreen = require(script.Parent:WaitForChild("PlaceAimScreen"))
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))

local PlacementController = {}

local MODE_OFF = "Off"
local MODE_AIM = "Aim"
local MODE_CONFIRM = "Confirm"

local mode = MODE_OFF
local armedItemId: string? = nil
local ghost: BasePart? = nil
local ghostPlaceDiameter: number? = nil
local warnLabel: TextLabel? = nil
local moveHintImage: ImageLabel? = nil
local moveHintBillboard: BillboardGui? = nil
local confirmGui: ScreenGui? = nil
local chromeBillboard: BillboardGui? = nil
local chromeAdorneePart: BasePart? = nil
local checkBtn: TextButton? = nil
local cancelBtn: TextButton? = nil
local confirmPos: Vector3? = nil -- ground anchor under finger (actual place pos)
local placeAnchor: Vector3? = nil
local validSpot = false
local rejectReason: string? = nil
-- Placed coral occupying the aimed cell — neon red/white flash while "Spot Taken".
local blockFlashPart: BasePart? = nil
local blockFlashBaseMaterial: Enum.Material? = nil
local blockFlashBaseColor: Color3? = nil
local backpackDrag = false -- pointer-driven aim from backpack pull
local aimFingerDown = false -- world drag after tap-select (mobile/PC)
local confirmDragging = false
local confirmPressOrigin: Vector2? = nil -- nil while pressing ✓/X
local chromeScreenPos: Vector2? = nil -- move-icon aim freeze; ✓/X sit on torso
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
-- Aim loop: freeze cam every frame; raycast ≤25 Hz or when pointer moves ≥1px.
local AIM_RAYCAST_HZ = 25
local AIM_RAYCAST_DT = 1 / AIM_RAYCAST_HZ
local AIM_MOVE_PX = 1
local aimRayAccum = 0
local lastAimScreen: Vector2? = nil
local placeRayParams: RaycastParams? = nil

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
local CANCEL_FLASH_RED = Color3.fromRGB(255, 70, 70)
local DISARM_SCALE_SEC = 1
local ARM_INTRO_SEC = 0.7
local POST_PLACE_GHOST_DELAY = 1
local GHOST_SCALE_IN_SEC = 0.5

local ghostBaseColor: Color3? = nil
local ghostBaseMaterial: Enum.Material? = nil
local placeSelectRing = SelectRing.new()
local placeResumeToken = 0
local postPlaceWaiting = false
local pendingGhostScaleIn = false
local ghostScaleConn: RBXScriptConnection? = nil
local disarmAnimating = false
local disarmConn: RBXScriptConnection? = nil
local armIntroAnimating = false
local armIntroConn: RBXScriptConnection? = nil
-- Parallel item-switch: old ghost/UI flies home while the new one flies out.
local outgoingConn: RBXScriptConnection? = nil
local outgoingGhost: BasePart? = nil
local outgoingGui: ScreenGui? = nil
-- Optional slot targets when switching items (capture before pulse moves).
local pendingDisarmSlotScreen: Vector2? = nil
local pendingArmSlotScreen: Vector2? = nil
local queuedSwitchItemId: string? = nil
-- ✓/X press owned by confirm chrome (blocks AIM from parking the ghost on that click).
local chromeBtnPointerDown = false
local chromePressTarget: string? = nil -- "check" | "cancel"

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
local stopArmIntro: () -> ()
local startAimLoop: () -> ()
local beginAim: (string, boolean?, boolean?) -> ()

local savedWalkSpeed = 16
local savedJumpPower = 50
local savedJumpHeight = 7.2
local savedCameraType: Enum.CameraType? = nil
local savedCameraCFrame: CFrame? = nil
local aimConn: RBXScriptConnection? = nil
local inputConns: { RBXScriptConnection } = {}
local frozen = false
local savedTouchControlsEnabled: boolean? = nil
local savedTouchGuiEnabled: boolean? = nil

local FREEZE_ACTION = "OceanTD_PlacementFreeze"
local DEFAULT_WALK_SPEED = 16
local DEFAULT_JUMP_POWER = 50
local DEFAULT_JUMP_HEIGHT = 7.2
local CONFIRM_DRAG_PX = 28 -- ignore tiny finger jitter before moving parked ghost
local BTN_SIZE = 52 -- min tappable chrome; PlaceConfirmChrome also floors at 52px

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
		end
	else
		if hum and hum.WalkSpeed <= 0 then
			hum.WalkSpeed = DEFAULT_WALK_SPEED
			hum.JumpPower = DEFAULT_JUMP_POWER
			hum.JumpHeight = DEFAULT_JUMP_HEIGHT
		end
		if camera and camera.CameraType == Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Custom
		end
	end

	savedCameraType = nil
	savedCameraCFrame = nil
end

local function freeze()
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

local clearBlockFlash: () -> ()

local function clearGhost()
	stopGhostScaleIn()
	clearBlockFlash()
	ClientPlot.setOutOfPlotFlash(false)
	warnLabel = nil
	ghostBaseColor = nil
	ghostBaseMaterial = nil
	ghostPlaceDiameter = nil
	SelectRing.destroy(placeSelectRing)
	-- Keep move icon alive (billboard may be Adorned to this ghost).
	detachMoveHintToScreen()
	if ghost then
		ghost:Destroy()
		ghost = nil
	end
	placeAnchor = nil
end

local function destroyConfirmUi()
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
	moveHintImage = nil
	moveHintScale = nil
	chromePressTarget = nil
	chromeBtnPointerDown = false
end

local function findBlockingCoral(worldPos: Vector3): BasePart?
	local plot = ClientPlot.get()
	if not plot then
		return nil
	end
	return PlacedCoralIndex.getAtWorld(plot.plotId, worldPos, plot.cframe, nil)
end

local function isSpotTakenClient(worldPos: Vector3): boolean
	return findBlockingCoral(worldPos) ~= nil
end

clearBlockFlash = function()
	if blockFlashPart and blockFlashPart.Parent then
		if blockFlashBaseMaterial then
			blockFlashPart.Material = blockFlashBaseMaterial
		end
		if blockFlashBaseColor then
			blockFlashPart.Color = blockFlashBaseColor
		end
	end
	blockFlashPart = nil
	blockFlashBaseMaterial = nil
	blockFlashBaseColor = nil
end

local function setBlockFlash(target: BasePart?)
	if blockFlashPart == target then
		return
	end
	clearBlockFlash()
	if not target or not target.Parent then
		return
	end
	-- Clear backpack hover neon first so we don't save Neon as the restore base.
	pcall(function()
		local Relocate = require(script.Parent:WaitForChild("RelocateController"))
		if typeof(Relocate.clearHoverHighlight) == "function" then
			Relocate.clearHoverHighlight()
		end
	end)
	local restMat, restColor = CoralVisual.readRestLook(target)
	CoralVisual.applyRestLook(target)
	blockFlashPart = target
	blockFlashBaseMaterial = restMat
	blockFlashBaseColor = restColor
	target.Material = Enum.Material.Neon
end

local function updateBlockFlash()
	if not blockFlashPart or not blockFlashPart.Parent then
		if blockFlashPart then
			clearBlockFlash()
		end
		return
	end
	-- Alternate bright white ↔ red neon.
	local pulse = (math.sin(os.clock() * 12) + 1) * 0.5
	blockFlashPart.Material = Enum.Material.Neon
	blockFlashPart.Color = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(255, 45, 45), pulse)
end

local function syncBlockFlashForAim(worldPos: Vector3?)
	if aimPinnedToHand or not worldPos or validSpot or rejectReason ~= "Spot Taken" then
		clearBlockFlash()
		return
	end
	setBlockFlash(findBlockingCoral(worldPos))
end

local function preparePlaceRayParams()
	if not placeRayParams then
		placeRayParams = RaycastParams.new()
		placeRayParams.FilterType = Enum.RaycastFilterType.Exclude
	end
	local exclude: { Instance } = {}
	if ghost then
		table.insert(exclude, ghost)
	end
	if outgoingGhost then
		table.insert(exclude, outgoingGhost)
	end
	local placed = Workspace:FindFirstChild("OceanTD_Placed")
	if placed then
		table.insert(exclude, placed)
	end
	if player.Character then
		table.insert(exclude, player.Character)
	end
	placeRayParams.FilterDescendantsInstances = exclude
end

local function castPlaceRay(origin: Vector3, direction: Vector3): Vector3?
	preparePlaceRayParams()
	local hit = Workspace:Raycast(origin, direction.Unit * 800, placeRayParams)
	if hit then
		return hit.Position
	end
	local plot = ClientPlot.get()
	if plot then
		local plotOrigin = plot.cframe.Position
		local t = (plotOrigin.Y - origin.Y) / direction.Y
		if t == t and t > 0 then
			return origin + direction.Unit * t
		end
	end
	return nil
end

local function raycastPointer(screenPos: Vector2): Vector3?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	-- ScreenPointToRay matches GetMouseLocation (inset-inclusive).
	local ray = cam:ScreenPointToRay(screenPos.X, screenPos.Y)
	return castPlaceRay(ray.Origin, ray.Direction)
end

-- Finger / chrome aim point helpers live in PlaceAimScreen (register budget).
local function getPlaceAimScreenPos(): Vector2
	return PlaceAimScreen.getPlaceAimPos(gamepadPlacement, gamepadCursor, aimPinnedToCenter, aimRaiseForTouch)
end

local function notePlacePointerInput(input: InputObject)
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

local function resetGamepadCursor()
	gamepadCursor = PlaceAimScreen.resetGamepadCursor()
end

local function readThumbstick1(): Vector2
	return PlaceAimScreen.readThumbstick1()
end

local function clampGamepadCursor(pos: Vector2): Vector2
	return PlaceAimScreen.clampGamepadCursor(pos)
end

local function setCheckGlyphText(text: string)
	if not checkBtn then
		return
	end
	local glyph = checkBtn:FindFirstChild("Glyph")
	local isWord = text == "CONFIRM" or text == "Enter" or text == "A"
	local strokeColor = if isWord
		then Color3.fromRGB(12, 55, 25)
		else Color3.new(1, 1, 1)
	if glyph and glyph:IsA("TextLabel") then
		glyph.Text = text
		glyph.TextStrokeColor3 = strokeColor
		glyph.TextStrokeTransparency = 0
		local glyphStroke = glyph:FindFirstChild("GlyphStroke")
		if glyphStroke and glyphStroke:IsA("UIStroke") then
			glyphStroke.Color = strokeColor
		end
	else
		checkBtn.Text = text
		checkBtn.TextTransparency = 0
		checkBtn.TextStrokeColor3 = strokeColor
		checkBtn.TextStrokeTransparency = 0
	end
end

local function applyGamepadButtonLabels()
	if not checkBtn or not cancelBtn then
		return
	end
	-- Label cycling (✓/CONFIRM, X/CANCEL) is owned by syncConfirmButtons.
	stopCheckPrompt()
	setCheckGlyphText("✓")
end

local function fireGamepadReturnToList()
	for _, cb in ipairs(gamepadReturnCbs) do
		task.spawn(cb)
	end
end

local function raycastForPlace(): Vector3?
	-- Mouse: PlayerMouse.UnitRay tracks the hardware cursor (incl. Scriptable cam).
	-- Touch / gamepad keep screen-point rays (touch uses the above-finger aim pos).
	if not gamepadPlacement and not PlaceAimScreen.isTouchAim(aimRaiseForTouch, gamepadPlacement) then
		local mouse = player:GetMouse()
		local unit = mouse.UnitRay
		return castPlaceRay(unit.Origin, unit.Direction)
	end
	return raycastPointer(getPlaceAimScreenPos())
end

local function shouldRaycastAim(screenPos: Vector2, dt: number): boolean
	aimRayAccum += dt
	local moved = lastAimScreen == nil or (screenPos - lastAimScreen).Magnitude >= AIM_MOVE_PX
	if moved or aimRayAccum >= AIM_RAYCAST_DT then
		aimRayAccum = 0
		lastAimScreen = screenPos
		return true
	end
	return false
end

-- World aim at ≤25 Hz, or immediately when the pointer moves ≥1px.
local function raycastAimThrottled(dt: number): Vector3?
	local screen = getPlaceAimScreenPos()
	if not shouldRaycastAim(screen, dt) then
		return placeAnchor
	end
	return raycastForPlace()
end

local function evaluatePos(worldPos: Vector3): (boolean, string?)
	local placeMax = SkillStages.placeMoreMaxAtStage(SkillPowerUpUI.getStage("PlaceMore"))
	if PlacedCoralIndex.countLocal() >= placeMax then
		return false, "Max Placed"
	end
	if not ClientPlot.isInside(worldPos) then
		return false, "Out Of Plot"
	end
	if isSpotTakenClient(worldPos) then
		return false, "Spot Taken"
	end
	return true, nil
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
	if validSpot then
		ghost.Color = ghostBaseColor or ghost.Color
	else
		ghost.Color = GHOST_INVALID_COLOR
	end
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
		if speciesId == "BrainCoral" then
			ghostDiameter = CoralVisual.randomBrainDiameter()
			ghostPlaceDiameter = ghostDiameter
		else
			ghostPlaceDiameter = nil
		end
		ghost = CoralVisual.create(speciesId, anchorPos, {
			ghost = true,
			valid = validSpot,
			diameter = ghostDiameter,
		})
		if ghost then
			ghost.Parent = Workspace
			ensureWarnBillboard(ghost)
			ghostBaseColor = readGhostBaseColor(ghost)
			local sp = SpeciesCatalog.get(speciesId)
			ghostBaseMaterial = if sp then sp.material else Enum.Material.Pebble
			if pendingGhostScaleIn then
				pendingGhostScaleIn = false
				startGhostScaleIn(ghost)
			end
		end
	else
		ghost.CFrame = CFrame.new(anchorPos)
		if validSpot then
			ghost.Color = ghostBaseColor or ghost.Color
		else
			ghost.Color = GHOST_INVALID_COLOR
		end
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
	if armIntroAnimating and mode ~= MODE_CONFIRM then
		return
	end
	if not confirmGui or not checkBtn or not cancelBtn or not ghost then
		return
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

	-- Visibility first so torso layout can center X-only vs ✓+X pair.
	checkBtn.Visible = validSpot and (mode == MODE_CONFIRM or gamepadPlacement)
	cancelBtn.Visible = true
	local bb, adornee = PlaceConfirmChrome.layoutOnTorso(
		BTN_SIZE,
		playerGui,
		confirmGui,
		chromeBillboard,
		chromeAdorneePart,
		checkBtn,
		cancelBtn
	)
	chromeBillboard = bb
	chromeAdorneePart = adornee
	local showWord = (math.floor(os.clock()) % 2) == 1
	cancelBtn.Text = if showWord then "CANCEL" else "X"
	cancelBtn.TextStrokeColor3 = if showWord then Color3.fromRGB(60, 15, 18) else Color3.new(1, 1, 1)
	cancelBtn.TextStrokeTransparency = 0
	if checkBtn.Visible then
		local confirmWord = "CONFIRM"
		local last = UserInputService:GetLastInputType()
		if last == Enum.UserInputType.Gamepad1
			or last == Enum.UserInputType.Gamepad2
			or last == Enum.UserInputType.Gamepad3
			or last == Enum.UserInputType.Gamepad4
			or gamepadPlacement
		then
			confirmWord = "A"
		elseif last ~= Enum.UserInputType.Touch then
			confirmWord = "Enter"
		end
		setCheckGlyphText(if showWord then confirmWord else "✓")
	end
end
syncConfirmButtons = syncConfirmButtonsImpl

local function makeConfirmUiImpl()
	if confirmGui and checkBtn and cancelBtn and moveHintImage then
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

	local function roundBtn(text: string, color: Color3, strokeLabel: boolean): TextButton
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(BTN_SIZE, BTN_SIZE)
		b.BackgroundColor3 = color
		b.BackgroundTransparency = 0 -- opaque so touch reliably hits the button
		b.Font = UiTheme.Font
		b.Text = text
		b.TextColor3 = Color3.new(1, 1, 1)
		b.TextScaled = true
		b.AutoButtonColor = true
		b.ZIndex = 5
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

		if strokeLabel then
			local label = Instance.new("TextLabel")
			label.Name = "Glyph"
			label.BackgroundTransparency = 1
			label.Size = UDim2.fromScale(1, 1)
			label.Font = UiTheme.Font
			label.Text = text
			label.TextColor3 = Color3.new(1, 1, 1)
			label.TextScaled = true
			label.Active = false
			label.ZIndex = b.ZIndex + 1
			label.Parent = b
			b.TextTransparency = 1
			local glyphStroke = Instance.new("UIStroke")
			glyphStroke.Name = "GlyphStroke"
			glyphStroke.Color = Color3.new(1, 1, 1)
			glyphStroke.Thickness = 1.5
			glyphStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
			glyphStroke.Parent = label
		end

		return b
	end

	checkBtn = roundBtn("✓", Color3.fromRGB(40, 180, 80), true)
	cancelBtn = roundBtn("X", Color3.fromRGB(200, 50, 50), false)
	applyGamepadButtonLabels()

	local function markChromePointerDown(target: string)
		-- Only a press that *starts* on ✓/X counts. Sliding onto the button mid-drag
		-- (common on phone when releasing over Cancel) must not steal the gesture.
		if aimFingerDown or backpackDrag or confirmDragging or confirmPressOrigin ~= nil then
			return
		end
		chromePressTarget = target
		chromeBtnPointerDown = true
		aimFingerDown = false
		confirmPressOrigin = nil
		confirmDragging = false
	end

	-- MouseButton1Down fires on the button; also blocks ghost-aim if UIS already peeked.
	checkBtn.MouseButton1Down:Connect(function()
		markChromePointerDown("check")
	end)
	cancelBtn.MouseButton1Down:Connect(function()
		markChromePointerDown("cancel")
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
	-- Clicks are committed in UserInputService.InputEnded (BillboardGui Click is flaky).
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

local function stopDisarmAnim()
	if disarmConn then
		disarmConn:Disconnect()
		disarmConn = nil
	end
	disarmAnimating = false
end

local function stopOutgoingFlyback()
	if outgoingConn then
		outgoingConn:Disconnect()
		outgoingConn = nil
	end
	if outgoingGhost then
		outgoingGhost:Destroy()
		outgoingGhost = nil
	end
	if outgoingGui then
		outgoingGui:Destroy()
		outgoingGui = nil
	end
end

local function guiCenterOf(go: GuiObject): Vector2
	local p = go.AbsolutePosition
	local s = go.AbsoluteSize
	return Vector2.new(p.X + s.X * 0.5, p.Y + s.Y * 0.5)
end

local function resolveDisarmTargetScreen(itemId: string?): Vector2
	local targetScreen = pendingDisarmSlotScreen
	pendingDisarmSlotScreen = nil
	if not targetScreen and itemId then
		targetScreen = InventoryState.getItemSlotScreenCenter(itemId)
	end
	if not targetScreen then
		local vp = camera and camera.ViewportSize or Vector2.new(800, 600)
		targetScreen = Vector2.new(vp.X * 0.85, vp.Y * 0.55)
	end
	return targetScreen
end

-- Steal ghost (+ optional move-icon clone) for parallel switch. Keeps ✓/X chrome in place.
local function detachGhostForSwitch(): (BasePart?, ImageLabel?, ScreenGui?)
	detachMoveHintToScreen()
	local g = ghost
	ghost = nil
	placeAnchor = nil
	warnLabel = nil
	ghostBaseColor = nil
	ghostBaseMaterial = nil

	local outMove: ImageLabel? = nil
	local outGui: ScreenGui? = nil
	if moveHintImage and moveHintImage.Parent and moveHintImage.Visible then
		outGui = Instance.new("ScreenGui")
		outGui.Name = "OceanTD_PlaceOutgoing"
		outGui.ResetOnSpawn = false
		outGui.IgnoreGuiInset = true
		outGui.ClipToDeviceSafeArea = false
		outGui.DisplayOrder = 11999
		outGui.Parent = playerGui
		outMove = moveHintImage:Clone()
		outMove.Parent = outGui
		moveHintImage.Visible = false
		moveHintImage.ImageTransparency = 0
		moveHintImage.Size = UDim2.fromOffset(MOVE_ICON_SIZE, MOVE_ICON_SIZE)
	end
	stopMoveHintAttract()

	-- Ensure the live X stays usable and parked on torso (not mid-flash / not flying).
	if cancelBtn then
		cancelBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
		cancelBtn.AutoButtonColor = true
		cancelBtn.Active = true
		cancelBtn.Visible = true
		cancelBtn.BackgroundTransparency = 0
	end
	if checkBtn then
		checkBtn.Visible = false
		checkBtn.BackgroundTransparency = 0
		checkBtn.Active = true
	end
	do
		local bb, adornee = PlaceConfirmChrome.layoutOnTorso(
			BTN_SIZE,
			playerGui,
			confirmGui,
			chromeBillboard,
			chromeAdorneePart,
			checkBtn,
			cancelBtn
		)
		chromeBillboard = bb
		chromeAdorneePart = adornee
	end

	return g, outMove, outGui
end

-- Fly detached ghost + move icon into a backpack slot (✓/X stay on the live chrome).
local function startOutgoingFlyback(
	ghostPart: BasePart?,
	moveRef: ImageLabel?,
	guiRef: ScreenGui?,
	targetScreen: Vector2,
	worldPos: Vector3
)
	stopOutgoingFlyback()
	outgoingGhost = ghostPart
	outgoingGui = guiRef

	if not ghostPart and not guiRef then
		return
	end

	local ghostStartSize = if ghostPart then ghostPart.Size else nil
	local ghostStartPos = if ghostPart then ghostPart.Position else nil
	local moveStart = if moveRef then guiCenterOf(moveRef) else targetScreen
	local moveStartSize = if moveRef then moveRef.AbsoluteSize.X else MOVE_ICON_SIZE

	local endWorld = worldPos
	if camera and ghostStartPos then
		local ray = camera:ViewportPointToRay(targetScreen.X, targetScreen.Y)
		endWorld = ray.Origin + ray.Direction * 4
	end

	local t0 = os.clock()
	outgoingConn = RunService.RenderStepped:Connect(function()
		keepCameraFrozen()
		local u = math.clamp((os.clock() - t0) / DISARM_SCALE_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		local scale = math.max(1 - a, 0.02)

		if moveRef and moveRef.Parent then
			moveRef.Visible = true
			moveRef.AnchorPoint = Vector2.new(0.5, 0.5)
			local mpos = moveStart:Lerp(targetScreen, a)
			local msize = moveStartSize * scale
			moveRef.Position = UDim2.fromOffset(mpos.X, mpos.Y)
			moveRef.Size = UDim2.fromOffset(msize, msize)
			moveRef.ImageTransparency = a
		end

		if ghostPart and ghostPart.Parent and ghostStartSize and ghostStartPos then
			ghostPart.Size = ghostStartSize * scale
			ghostPart.Transparency = 0.4 + 0.55 * a
			ghostPart.CFrame = CFrame.new(ghostStartPos:Lerp(endWorld, a))
		end

		if u >= 1 then
			stopOutgoingFlyback()
		end
	end)
end

local function playDisarmOutro(thenExit: () -> ())
	if disarmAnimating then
		return
	end
	stopOutgoingFlyback()
	if armIntroAnimating then
		stopArmIntro()
	end
	detachMoveHintToScreen()
	-- Nothing to animate — finish immediately.
	if not ghost and not confirmGui then
		pendingDisarmSlotScreen = nil
		thenExit()
		return
	end
	disarmAnimating = true
	stopAimLoop()
	stopGhostScaleIn()
	stopMoveHintAttract()

	local itemId = armedItemId
	local worldPos = placeAnchor or confirmPos or (ghost and ghost.Position) or Vector3.zero
	PlaceVfx.playCancelSound(worldPos)

	if cancelBtn then
		cancelBtn.BackgroundColor3 = CANCEL_FLASH_RED
		cancelBtn.AutoButtonColor = false
	end

	local ghostPart = ghost
	local ghostStartSize = if ghostPart then ghostPart.Size else nil
	local ghostStartPos = if ghostPart then ghostPart.Position else nil

	local targetScreen = resolveDisarmTargetScreen(itemId)

	local cancelStart = if cancelBtn then guiCenterOf(cancelBtn) else targetScreen
	local checkStart = if checkBtn and checkBtn.Visible then guiCenterOf(checkBtn) else nil
	local moveStart = if moveHintImage and moveHintImage.Visible then guiCenterOf(moveHintImage) else targetScreen
	local cancelStartSize = if cancelBtn then cancelBtn.AbsoluteSize.X else BTN_SIZE
	local checkStartSize = if checkBtn then checkBtn.AbsoluteSize.X else BTN_SIZE
	local moveStartSize = if moveHintImage then moveHintImage.AbsoluteSize.X else MOVE_ICON_SIZE

	-- Park buttons in ScreenGui space for the fly-out (AbsolutePosition → Position).
	if confirmGui then
		if cancelBtn then
			cancelBtn.Parent = confirmGui
			cancelBtn.AnchorPoint = Vector2.new(0.5, 0.5)
			cancelBtn.Position = UDim2.fromOffset(cancelStart.X, cancelStart.Y)
		end
		if checkBtn then
			checkBtn.Parent = confirmGui
			checkBtn.AnchorPoint = Vector2.new(0.5, 0.5)
			if checkStart then
				checkBtn.Position = UDim2.fromOffset(checkStart.X, checkStart.Y)
			end
		end
	end

	-- Ghost flies toward a near-camera point under the item slot so it reads as UI suck-in.
	local endWorld = worldPos
	if camera and ghostStartPos then
		local ray = camera:ViewportPointToRay(targetScreen.X, targetScreen.Y)
		endWorld = ray.Origin + ray.Direction * 4
	end

	HandOrb.disarm(DISARM_SCALE_SEC)

	local t0 = os.clock()
	disarmConn = RunService.RenderStepped:Connect(function()
		keepCameraFrozen()
		local u = math.clamp((os.clock() - t0) / DISARM_SCALE_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		local scale = math.max(1 - a, 0.02)

		-- Flash bright red for the first quarter, then hold bright red.
		if cancelBtn and cancelBtn.Parent then
			if u < 0.28 then
				local pulse = (math.floor(os.clock() * 14) % 2) == 0
				cancelBtn.BackgroundColor3 = if pulse then CANCEL_FLASH_RED else Color3.fromRGB(160, 15, 15)
			else
				cancelBtn.BackgroundColor3 = CANCEL_FLASH_RED
			end
			cancelBtn.Visible = true
			cancelBtn.AnchorPoint = Vector2.new(0.5, 0.5)
			local cpos = cancelStart:Lerp(targetScreen, a)
			local csize = cancelStartSize * scale
			cancelBtn.Position = UDim2.fromOffset(cpos.X, cpos.Y)
			cancelBtn.Size = UDim2.fromOffset(csize, csize)
		end

		if checkBtn and checkBtn.Parent and checkStart then
			checkBtn.Visible = true
			checkBtn.AnchorPoint = Vector2.new(0.5, 0.5)
			local cpos = checkStart:Lerp(targetScreen, a)
			local csize = checkStartSize * scale
			checkBtn.Position = UDim2.fromOffset(cpos.X, cpos.Y)
			checkBtn.Size = UDim2.fromOffset(csize, csize)
			checkBtn.BackgroundTransparency = a
		end

		if moveHintImage and moveHintImage.Parent then
			moveHintImage.Visible = true
			moveHintImage.AnchorPoint = Vector2.new(0.5, 0.5)
			local mpos = (moveStart or targetScreen):Lerp(targetScreen, a)
			local msize = moveStartSize * scale
			moveHintImage.Position = UDim2.fromOffset(mpos.X, mpos.Y)
			moveHintImage.Size = UDim2.fromOffset(msize, msize)
			moveHintImage.ImageTransparency = a
		end

		if ghostPart and ghostPart.Parent and ghostStartSize and ghostStartPos then
			ghostPart.Size = ghostStartSize * scale
			ghostPart.Transparency = 0.4 + 0.55 * a
			ghostPart.CFrame = CFrame.new(ghostStartPos:Lerp(endWorld, a))
		end

		if u >= 1 then
			stopDisarmAnim()
			thenExit()
		end
	end)
end

stopArmIntro = function()
	if armIntroConn then
		armIntroConn:Disconnect()
		armIntroConn = nil
	end
	armIntroAnimating = false
end

startAimLoop = function()
	stopAimLoop()
	aimRayAccum = 0
	lastAimScreen = nil
	aimConn = RunService.RenderStepped:Connect(function(dt)
		if mode ~= MODE_AIM then
			return
		end
		-- Sticky Touch LastInputType must not keep raising once the mouse is aiming.
		do
			local last = UserInputService:GetLastInputType()
			if last ~= Enum.UserInputType.Touch then
				aimRaiseForTouch = false
			end
		end
		keepCameraFrozen()
		if postPlaceWaiting or armIntroAnimating then
			return
		end
		updateGhostPulse()
		updateBlockFlash()
		syncConfirmButtons()

		if gamepadPlacement then
			local stick = readThumbstick1()
			local mag = stick.Magnitude
			if mag > GAMEPAD_STICK_DEADZONE and gamepadCursor then
				releaseHandPin()
				local dir = stick.Unit
				local speed = GAMEPAD_AIM_SPEED * math.clamp((mag - GAMEPAD_STICK_DEADZONE) / (1 - GAMEPAD_STICK_DEADZONE), 0, 1)
				gamepadCursor = clampGamepadCursor(gamepadCursor + dir * speed * dt)
			end
			if aimPinnedToHand then
				local handPos = HandOrb.getHoldWorldPos()
				if handPos then
					updateGhostAt(handPos)
				end
				return
			end
			chromeScreenPos = nil
			-- Stick motion already moves cursor; still throttle world rays.
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

-- Tween ghost + move icon from the backpack item cell into the avatar's hand.
-- keepChromePinned: leave ✓/X at torso (used when swapping corals).
local function playArmIntroFromSlot(itemId: string, seedColor: Color3, onDone: () -> (), keepChromePinned: boolean?)
	stopArmIntro()
	armIntroAnimating = true
	aimPinnedToHand = true
	pendingGhostScaleIn = false
	detachMoveHintToScreen()

	local slotScreen = pendingArmSlotScreen
	pendingArmSlotScreen = nil
	if not slotScreen then
		slotScreen = InventoryState.getItemSlotScreenCenter(itemId)
	end
	if not slotScreen then
		local vp = if camera then camera.ViewportSize else Vector2.new(800, 600)
		slotScreen = Vector2.new(vp.X * 0.85, vp.Y * 0.5)
	end

	local startWorld: Vector3
	if camera then
		local ray = camera:ViewportPointToRay(slotScreen.X, slotScreen.Y)
		startWorld = ray.Origin + ray.Direction * 7
	else
		startWorld = HandOrb.getHoldWorldPos() or Vector3.zero
	end

	HandOrb.clear()
	updateGhostAt(startWorld)
	local ghostPart = ghost
	if not ghostPart then
		armIntroAnimating = false
		HandOrb.arm(seedColor)
		onDone()
		return
	end

	local fullSize = ghostPart.Size
	ghostPart.Size = fullSize * 0.08
	makeConfirmUi()
	setMoveHintVisible(true)

	local chromePos = PlaceConfirmChrome.screenPos(chromeAdorneePart)
	-- Swap path: park X on torso immediately; only ghost + move fly in.
	if keepChromePinned then
		if cancelBtn then
			cancelBtn.Visible = true
			cancelBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
			cancelBtn.AutoButtonColor = true
			cancelBtn.Active = true
			cancelBtn.BackgroundTransparency = 0
		end
		if checkBtn then
			checkBtn.Visible = false
		end
		do
			local bb, adornee = PlaceConfirmChrome.layoutOnTorso(
				BTN_SIZE,
				playerGui,
				confirmGui,
				chromeBillboard,
				chromeAdorneePart,
				checkBtn,
				cancelBtn
			)
			chromeBillboard = bb
			chromeAdorneePart = adornee
		end
	end

	local t0 = os.clock()
	armIntroConn = RunService.RenderStepped:Connect(function()
		keepCameraFrozen()
		if mode == MODE_OFF then
			stopArmIntro()
			return
		end
		local handWorld = HandOrb.getHoldWorldPos()
		if not handWorld and player.Character then
			local hand = player.Character:FindFirstChild("RightHand") or player.Character:FindFirstChild("Right Arm")
			if hand and hand:IsA("BasePart") then
				handWorld = hand.Position
			end
		end
		handWorld = handWorld or startWorld

		local handScreen: Vector2 = slotScreen
		if camera then
			local sp, _ = camera:WorldToViewportPoint(handWorld)
			if sp.Z > 0 then
				handScreen = Vector2.new(sp.X, sp.Y)
			end
		end
		chromePos = PlaceConfirmChrome.screenPos(chromeAdorneePart)

		local u = math.clamp((os.clock() - t0) / ARM_INTRO_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		local scale = 0.08 + 0.92 * a

		if ghostPart.Parent then
			ghostPart.Size = fullSize * scale
			ghostPart.Transparency = 0.4
			ghostPart.CFrame = CFrame.new(startWorld:Lerp(handWorld, a))
			if ghostBaseColor then
				ghostPart.Color = ghostBaseColor
			end
		end

		local travel = slotScreen:Lerp(handScreen, a)
		if moveHintImage and moveHintImage.Parent then
			moveHintImage.Visible = true
			moveHintImage.AnchorPoint = Vector2.new(0.5, 0.5)
			moveHintImage.Position = UDim2.fromOffset(travel.X, travel.Y)
			local m = MOVE_ICON_SIZE * scale
			moveHintImage.Size = UDim2.fromOffset(m, m)
			moveHintImage.ImageTransparency = 0
		end

		if keepChromePinned then
			if cancelBtn and cancelBtn.Parent then
				cancelBtn.Visible = true
			end
			if checkBtn and checkBtn.Parent then
				checkBtn.Visible = false
			end
			do
				local bb, adornee = PlaceConfirmChrome.layoutOnTorso(
					BTN_SIZE,
					playerGui,
					confirmGui,
					chromeBillboard,
					chromeAdorneePart,
					checkBtn,
					cancelBtn
				)
				chromeBillboard = bb
				chromeAdorneePart = adornee
			end
		else
			-- Fly ✓/X from backpack cell toward torso chrome.
			local btnTravel = slotScreen:Lerp(chromePos, a)
			local bsize = BTN_SIZE * math.max(scale, 0.35)
			PlaceConfirmChrome.layoutAt(btnTravel, bsize, confirmGui, chromeBillboard, checkBtn, cancelBtn)
			if cancelBtn and cancelBtn.Parent then
				cancelBtn.Visible = true
			end
			if checkBtn and checkBtn.Parent then
				checkBtn.Visible = false
			end
		end

		if u >= 1 then
			stopArmIntro()
			if ghostPart.Parent then
				ghostPart.Size = fullSize
				ghostPart.CFrame = CFrame.new(handWorld)
			end
			if moveHintImage then
				moveHintImage.Size = UDim2.fromOffset(MOVE_ICON_SIZE, MOVE_ICON_SIZE)
			end
			if checkBtn then
				checkBtn.Visible = false
			end
			if cancelBtn then
				cancelBtn.Visible = true
			end
			do
				local bb, adornee = PlaceConfirmChrome.layoutOnTorso(
					BTN_SIZE,
					playerGui,
					confirmGui,
					chromeBillboard,
					chromeAdorneePart,
					checkBtn,
					cancelBtn
				)
				chromeBillboard = bb
				chromeAdorneePart = adornee
			end
			local color = ghostBaseColor or seedColor
			HandOrb.arm(color)
			aimPinnedToHand = true
			aimPinOrigin = UserInputService:GetMouseLocation()
			startMoveHintAttract()
			syncConfirmButtons()
			onDone()
		end
	end)
end

beginAim = function(itemId: string, scaleIn: boolean?, keepChromePinned: boolean?)
	postPlaceWaiting = false
	stopArmIntro()
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
		resetGamepadCursor()
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
	playArmIntroFromSlot(itemId, seedColor, function()
		if gamepadPlacement then
			local handPos = HandOrb.getHoldWorldPos()
			if handPos and camera then
				local spoint, _ = camera:WorldToViewportPoint(handPos)
				if spoint.Z > 0 then
					gamepadCursor = clampGamepadCursor(Vector2.new(spoint.X, spoint.Y))
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
	stopArmIntro()
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
	pendingGhostScaleIn = false
	stopDisarmAnim()
	stopOutgoingFlyback()
	stopArmIntro()
	stopMoveHintAttract()
	chromeBtnPointerDown = false
	mode = MODE_OFF
	backpackDrag = false
	aimFingerDown = false
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
	if not armedItemId or not confirmPos or not validSpot then
		return
	end
	if postPlaceWaiting or disarmAnimating or armIntroAnimating then
		return
	end
	local placePos = confirmPos
	local vfxColor = if ghost then ghost.Color else Color3.fromRGB(100, 200, 255)
	-- Sound + hand-orb fly on ✓ immediately; don't wait for the server.
	PlaceVfx.playSound(placePos)
	HandOrb.flyToPlant(placePos)

	local rf = Remotes.getFunction("RequestPlace")
	local result = rf:InvokeServer(armedItemId, placePos, ghostPlaceDiameter)
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
	if disarmAnimating or mode == MODE_OFF then
		return
	end
	if armIntroAnimating then
		stopArmIntro()
	end
	if gamepadPlacement then
		-- Deactivate coral, keep backpack open, restore D-pad list select.
		playDisarmOutro(function()
			gamepadPlacement = false
			gamepadCursor = nil
			exitPlacement(false)
			InventoryState.clearSelection()
			fireGamepadReturnToList()
		end)
		return
	end
	-- Pointer: exit placement (deactivate armed coral) after scale-out.
	playDisarmOutro(function()
		exitPlacement(true)
	end)
end

local function enterConfirm(worldPos: Vector3)
	-- Parking must win over a mid-flight arm intro (otherwise ✓ sync is skipped).
	if armIntroAnimating then
		stopArmIntro()
	end
	mode = MODE_CONFIRM
	backpackDrag = false
	confirmDragging = false
	confirmPressOrigin = nil
	aimFingerDown = false
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
		updateBlockFlash()
		syncConfirmButtons()
	end)
	syncConfirmButtons()
	log("Confirm mode", if validSpot then "valid" else (rejectReason or "invalid"))
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
			resetGamepadCursor()
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
	if disarmAnimating then
		-- Full cancel fly-home in progress — arm this item when it finishes.
		queuedSwitchItemId = itemId
		pendingDisarmSlotScreen = nil
		return
	end
	-- Switching corals: fly old ghost home AND new ghost out at the same time.
	if mode ~= MODE_OFF then
		local nextId = queuedSwitchItemId or itemId
		queuedSwitchItemId = nil

		if armIntroAnimating then
			stopArmIntro()
		end
		stopAimLoop()
		stopGhostScaleIn()
		stopMoveHintAttract()

		local worldPos = placeAnchor or confirmPos or (ghost and ghost.Position) or Vector3.zero
		local targetScreen = resolveDisarmTargetScreen(armedItemId)
		PlaceVfx.playCancelSound(worldPos)

		local outGhost, outMove, outGui = detachGhostForSwitch()
		startOutgoingFlyback(outGhost, outMove, outGui, targetScreen, worldPos)

		confirmPos = nil
		chromeScreenPos = nil
		backpackDrag = false
		aimFingerDown = false
		confirmDragging = false
		confirmPressOrigin = nil
		chromeBtnPointerDown = false
		postPlaceWaiting = false

		-- Keep the same X at torso; only ghost + move icon crossfade.
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
	if mode == MODE_OFF and not disarmAnimating then
		return
	end
	stopDisarmAnim()
	stopOutgoingFlyback()
	stopArmIntro()
	exitPlacement(true)
end

-- Drag-out from backpack (mobile) / click-drop (PC)
function PlacementController.notifyPointerDownFromBackpack(itemId: string, _screenPos: Vector2, fromTouch: boolean?)
	PlacementController.setGamepadPlacement(false)
	aimRaiseForTouch = fromTouch == true
	local function startDrag()
		beginAimFromDrag(itemId)
		backpackDrag = true
		-- beginAimFromDrag may overwrite from LastInputType — keep the caller's pointer kind.
		aimRaiseForTouch = fromTouch == true
		local pos = raycastForPlace()
		if pos then
			updateGhostAt(pos)
		end
	end
	if mode ~= MODE_OFF then
		if disarmAnimating then
			return
		end
		playDisarmOutro(function()
			exitPlacement(false)
			startDrag()
		end)
		return
	end
	startDrag()
end

function PlacementController.notifyPointerMove(_screenPos: Vector2)
	if mode ~= MODE_AIM then
		return
	end
	local pos = raycastForPlace()
	if pos then
		updateGhostAt(pos)
	end
end

function PlacementController.notifyPointerUp(_screenPos: Vector2)
	if mode == MODE_AIM then
		local pos = placeAnchor or raycastForPlace()
		backpackDrag = false
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
		if mode ~= MODE_OFF and not disarmAnimating then
			onCancel()
		end
		return
	end
	PlacementController.beginForItem(id)
end)

-- Closing backpack ends placement so the player can move again.
InventoryState.onOpenChanged(function(isOpen)
	if not isOpen then
		if disarmAnimating then
			return
		end
		if mode ~= MODE_OFF then
			playDisarmOutro(function()
				exitPlacement(true)
			end)
		else
			exitPlacement(true)
		end
	end
end)

-- Hit tests live in PlaceConfirmHitTest (register budget).

table.insert(inputConns, UserInputService.InputBegan:Connect(function(input, _processed)
	if mode ~= MODE_OFF then
		notePlacePointerInput(input)
	end
	if mode == MODE_OFF then
		return
	end
	if disarmAnimating then
		return
	end
	if armIntroAnimating then
		-- Allow cancel during the slot→hand fly-in; ignore aim/place.
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.X or input.KeyCode == Enum.KeyCode.ButtonB then
			onCancel()
			return
		end
		local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1
		local isTouch = input.UserInputType == Enum.UserInputType.Touch
		if isMouse or isTouch then
			local screenPos = PlaceConfirmHitTest.pointerScreenPos(input)
			local target = PlaceConfirmHitTest.resolveTarget(screenPos, checkBtn, cancelBtn, playerGui)
			if target then
				chromePressTarget = target
				chromeBtnPointerDown = true
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
	local chromeTarget = PlaceConfirmHitTest.resolveTarget(screenPos, checkBtn, cancelBtn, playerGui)
	if chromeTarget then
		confirmPressOrigin = nil
		confirmDragging = false
		aimFingerDown = false
		chromePressTarget = chromeTarget
		chromeBtnPointerDown = true
		return
	end
	-- Touches on the open backpack list must not aim/park the ghost under the panel.
	if InventoryState.isPointerOverBackpack(screenPos) then
		confirmPressOrigin = nil
		confirmDragging = false
		aimFingerDown = false
		return
	end
	-- Ignore gameProcessed for world aim/park: HUD/quickbar often marks clicks processed
	-- even when the press is meant for the plot, which left ghosts stuck without ✓.

	if mode == MODE_CONFIRM then
		confirmPressOrigin = screenPos
		confirmDragging = false
		return
	end

	-- Aim: hold + slide moves ghost (tap-select then drag on mobile). Park on release.
	if mode == MODE_AIM and not backpackDrag then
		aimFingerDown = true
		aimPinnedToCenter = false
		releaseHandPin()
		aimPinOrigin = nil
		local pos = raycastForPlace()
		if pos then
			updateGhostAt(pos)
		end
	end
end))

table.insert(inputConns, UserInputService.InputChanged:Connect(function(input, _processed)
	if mode ~= MODE_OFF then
		notePlacePointerInput(input)
	end
	if postPlaceWaiting or mode == MODE_OFF or disarmAnimating or chromeBtnPointerDown then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local now = PlaceConfirmHitTest.pointerScreenPos(input)
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
	if postPlaceWaiting or mode == MODE_OFF then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local screenPos = PlaceConfirmHitTest.pointerScreenPos(input)
	-- Cancel/check press: commit on release (BillboardGui MouseButton1Click is unreliable).
	if chromeBtnPointerDown then
		local target = chromePressTarget
		chromeBtnPointerDown = false
		chromePressTarget = nil
		aimFingerDown = false
		confirmPressOrigin = nil
		confirmDragging = false
		if target == "check" then
			onCheck()
		elseif target == "cancel" then
			onCancel()
		end
		return
	end
	if disarmAnimating then
		return
	end
	if mode == MODE_AIM and aimFingerDown then
		aimFingerDown = false
		-- Park where the finger lifted — even if release is over ✓/X. Cancel/confirm
		-- only run when the press *started* on those buttons (chromeBtnPointerDown).
		local pos = placeAnchor or raycastForPlace()
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
