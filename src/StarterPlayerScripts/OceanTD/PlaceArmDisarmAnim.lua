--!strict
--[[
	Arm/disarm fly animations for PlacementController.
	Extracted so PlacementController stays under Luau's 200-local limit.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlaceConfirmChrome = require(script.Parent:WaitForChild("PlaceConfirmChrome"))
local PlaceVfx = require(script.Parent:WaitForChild("PlaceVfx"))
local HandOrb = require(script.Parent:WaitForChild("HandOrb"))

local PlaceArmDisarmAnim = {}

local disarmAnimating = false
local disarmConn: RBXScriptConnection? = nil
local armIntroAnimating = false
local armIntroConn: RBXScriptConnection? = nil
local armIntroFullSize: Vector3? = nil
local outgoingConn: RBXScriptConnection? = nil
local outgoingGhost: BasePart? = nil
local outgoingGui: ScreenGui? = nil

local DISARM_SCALE_SEC = 1
local ARM_INTRO_SEC = 0.38
local ARM_INTRO_START_SCALE = 0.22
local MOVE_ICON_SIZE = 48
local BTN_SIZE = PlaceConfirmChrome.BASE_BTN_PX
local CANCEL_FLASH_RED = Color3.fromRGB(255, 70, 70)

export type Env = {
	modeOff: string,
	playerGui: PlayerGui,
	camera: Camera?,
	getMode: () -> string,
	getGhost: () -> BasePart?,
	setGhost: (BasePart?) -> (),
	getPlaceAnchor: () -> Vector3?,
	setPlaceAnchor: (Vector3?) -> (),
	getConfirmPos: () -> Vector3?,
	getArmedItemId: () -> string?,
	getGhostBaseColor: () -> Color3?,
	setGhostBaseColor: (Color3?) -> (),
	setGhostBaseMaterial: (Enum.Material?) -> (),
	setWarnLabel: (TextLabel?) -> (),
	getConfirmGui: () -> ScreenGui?,
	getChromeBillboard: () -> BillboardGui?,
	setChromeBillboard: (BillboardGui?) -> (),
	getChromeAdorneePart: () -> BasePart?,
	setChromeAdorneePart: (BasePart?) -> (),
	getCheckBtn: () -> TextButton?,
	getCancelBtn: () -> TextButton?,
	getRotLeftBtn: (() -> ImageButton?)?,
	getRotRightBtn: (() -> ImageButton?)?,
	getMoveHintImage: () -> ImageLabel?,
	getPendingDisarmSlotScreen: () -> Vector2?,
	setPendingDisarmSlotScreen: (Vector2?) -> (),
	getPendingArmSlotScreen: () -> Vector2?,
	setPendingArmSlotScreen: (Vector2?) -> (),
	getAimPinnedToHand: () -> boolean,
	setAimPinnedToHand: (boolean) -> (),
	getAimPinOrigin: () -> Vector2?,
	setAimPinOrigin: (Vector2?) -> (),
	getAimFingerDown: () -> boolean,
	setAimFingerDown: (boolean) -> (),
	getPlacePointerHeld: () -> boolean,
	keepCameraFrozen: () -> (),
	detachMoveHintToScreen: () -> (),
	stopMoveHintAttract: () -> (),
	startMoveHintAttract: () -> (),
	releaseHandPin: () -> (),
	makeConfirmUi: () -> (),
	syncConfirmButtons: () -> (),
	setMoveHintVisible: (boolean) -> (),
	stopAimLoop: () -> (),
	stopGhostScaleIn: () -> (),
	updateGhostAt: (Vector3) -> (),
	resolveParkPos: (Vector2?) -> Vector3?,
	startAimLoop: () -> (),
	setPendingGhostScaleIn: (boolean) -> (),
}

local function layoutChrome(env: Env, checkBtn: TextButton?, cancelBtn: TextButton?)
	local rotL = if env.getRotLeftBtn then env.getRotLeftBtn() else nil
	local rotR = if env.getRotRightBtn then env.getRotRightBtn() else nil
	local armed = env.getArmedItemId()
	local showRot = armed == "SeaFan"
	if rotL then
		rotL.Visible = showRot
	end
	if rotR then
		rotR.Visible = showRot
	end
	local bb, adornee = PlaceConfirmChrome.layoutOnTorso(
		BTN_SIZE,
		env.playerGui,
		env.getConfirmGui(),
		env.getChromeBillboard(),
		env.getChromeAdorneePart(),
		checkBtn,
		cancelBtn,
		rotL,
		rotR,
		showRot
	)
	env.setChromeBillboard(bb)
	env.setChromeAdorneePart(adornee)
end

function PlaceArmDisarmAnim.isDisarmAnimating(): boolean
	return disarmAnimating
end

function PlaceArmDisarmAnim.isArmIntroAnimating(): boolean
	return armIntroAnimating
end

function PlaceArmDisarmAnim.getArmIntroFullSize(): Vector3?
	return armIntroFullSize
end

function PlaceArmDisarmAnim.getOutgoingGhost(): BasePart?
	return outgoingGhost
end

function PlaceArmDisarmAnim.stopDisarmAnim()
	if disarmConn then
		disarmConn:Disconnect()
		disarmConn = nil
	end
	disarmAnimating = false
end

function PlaceArmDisarmAnim.stopOutgoingFlyback()
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

function PlaceArmDisarmAnim.stopArmIntro()
	if armIntroConn then
		armIntroConn:Disconnect()
		armIntroConn = nil
	end
	armIntroAnimating = false
end

local function guiCenterOf(go: GuiObject): Vector2
	local p = go.AbsolutePosition
	local s = go.AbsoluteSize
	return Vector2.new(p.X + s.X * 0.5, p.Y + s.Y * 0.5)
end

local function resolveDisarmTargetScreen(env: Env, itemId: string?): Vector2
	local targetScreen = env.getPendingDisarmSlotScreen()
	env.setPendingDisarmSlotScreen(nil)
	if not targetScreen and itemId then
		targetScreen = InventoryState.getItemSlotScreenCenter(itemId)
	end
	if not targetScreen then
		local cam = env.camera
		local vp = if cam then cam.ViewportSize else Vector2.new(800, 600)
		targetScreen = Vector2.new(vp.X * 0.85, vp.Y * 0.55)
	end
	return targetScreen
end

function PlaceArmDisarmAnim.resolveDisarmTargetScreen(env: Env, itemId: string?): Vector2
	return resolveDisarmTargetScreen(env, itemId)
end

function PlaceArmDisarmAnim.detachGhostForSwitch(env: Env): (BasePart?, ImageLabel?, ScreenGui?)
	env.detachMoveHintToScreen()
	local g = env.getGhost()
	env.setGhost(nil)
	env.setPlaceAnchor(nil)
	env.setWarnLabel(nil)
	env.setGhostBaseColor(nil)
	env.setGhostBaseMaterial(nil)

	local moveHintImage = env.getMoveHintImage()
	local outMove: ImageLabel? = nil
	local outGui: ScreenGui? = nil
	if moveHintImage and moveHintImage.Parent and moveHintImage.Visible then
		outGui = Instance.new("ScreenGui")
		outGui.Name = "OceanTD_PlaceOutgoing"
		outGui.ResetOnSpawn = false
		outGui.IgnoreGuiInset = true
		outGui.ClipToDeviceSafeArea = false
		outGui.DisplayOrder = 11999
		outGui.Parent = env.playerGui
		outMove = moveHintImage:Clone()
		outMove.Parent = outGui
		moveHintImage.Visible = false
		moveHintImage.ImageTransparency = 0
		moveHintImage.Size = UDim2.fromOffset(MOVE_ICON_SIZE, MOVE_ICON_SIZE)
	end
	env.stopMoveHintAttract()

	local cancelBtn = env.getCancelBtn()
	local checkBtn = env.getCheckBtn()
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
		layoutChrome(env, checkBtn, cancelBtn)
	end

	return g, outMove, outGui
end

function PlaceArmDisarmAnim.startOutgoingFlyback(
	env: Env,
	ghostPart: BasePart?,
	moveRef: ImageLabel?,
	guiRef: ScreenGui?,
	targetScreen: Vector2,
	worldPos: Vector3
)
	PlaceArmDisarmAnim.stopOutgoingFlyback()
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
	local cam = env.camera
	if cam and ghostStartPos then
		local ray = cam:ViewportPointToRay(targetScreen.X, targetScreen.Y)
		endWorld = ray.Origin + ray.Direction * 4
	end

	local t0 = os.clock()
	outgoingConn = RunService.RenderStepped:Connect(function()
		env.keepCameraFrozen()
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
			PlaceArmDisarmAnim.stopOutgoingFlyback()
		end
	end)
end

function PlaceArmDisarmAnim.playDisarmOutro(env: Env, thenExit: () -> ())
	if disarmAnimating then
		return
	end
	PlaceArmDisarmAnim.stopOutgoingFlyback()
	if armIntroAnimating then
		PlaceArmDisarmAnim.stopArmIntro()
	end
	env.detachMoveHintToScreen()
	if not env.getGhost() and not env.getConfirmGui() then
		env.setPendingDisarmSlotScreen(nil)
		thenExit()
		return
	end
	disarmAnimating = true
	env.stopAimLoop()
	env.stopGhostScaleIn()
	env.stopMoveHintAttract()

	local itemId = env.getArmedItemId()
	local ghost = env.getGhost()
	local worldPos = env.getPlaceAnchor() or env.getConfirmPos() or (if ghost then ghost.Position else Vector3.zero)
	PlaceVfx.playCancelSound(worldPos)

	local cancelBtn = env.getCancelBtn()
	if cancelBtn then
		cancelBtn.BackgroundColor3 = CANCEL_FLASH_RED
		cancelBtn.AutoButtonColor = false
	end

	local ghostPart = ghost
	local ghostStartSize = if ghostPart then ghostPart.Size else nil
	local ghostStartPos = if ghostPart then ghostPart.Position else nil

	local targetScreen = resolveDisarmTargetScreen(env, itemId)
	local checkBtn = env.getCheckBtn()
	local moveHintImage = env.getMoveHintImage()
	local confirmGui = env.getConfirmGui()

	local cancelStart = if cancelBtn then guiCenterOf(cancelBtn) else targetScreen
	local checkStart = if checkBtn and checkBtn.Visible then guiCenterOf(checkBtn) else nil
	local moveStart = if moveHintImage and moveHintImage.Visible then guiCenterOf(moveHintImage) else targetScreen
	local cancelStartSize = if cancelBtn then cancelBtn.AbsoluteSize.X else BTN_SIZE
	local checkStartSize = if checkBtn then checkBtn.AbsoluteSize.X else BTN_SIZE
	local moveStartSize = if moveHintImage then moveHintImage.AbsoluteSize.X else MOVE_ICON_SIZE

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

	local endWorld = worldPos
	local cam = env.camera
	if cam and ghostStartPos then
		local ray = cam:ViewportPointToRay(targetScreen.X, targetScreen.Y)
		endWorld = ray.Origin + ray.Direction * 4
	end

	HandOrb.disarm(DISARM_SCALE_SEC)

	local t0 = os.clock()
	disarmConn = RunService.RenderStepped:Connect(function()
		env.keepCameraFrozen()
		local u = math.clamp((os.clock() - t0) / DISARM_SCALE_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		local scale = math.max(1 - a, 0.02)

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
			PlaceArmDisarmAnim.stopDisarmAnim()
			thenExit()
		end
	end)
end

function PlaceArmDisarmAnim.abortArmIntroToAim(env: Env, screenPos: Vector2)
	if not armIntroAnimating then
		return
	end
	PlaceArmDisarmAnim.stopArmIntro()
	local ghost = env.getGhost()
	local fullSize = armIntroFullSize
	if ghost and ghost.Parent and fullSize then
		ghost.Size = fullSize
		ghost.Transparency = 0.4
	end
	local moveHintImage = env.getMoveHintImage()
	if moveHintImage then
		moveHintImage.Size = UDim2.fromOffset(MOVE_ICON_SIZE, MOVE_ICON_SIZE)
	end
	local checkBtn = env.getCheckBtn()
	local cancelBtn = env.getCancelBtn()
	if checkBtn then
		checkBtn.Visible = false
	end
	if cancelBtn then
		cancelBtn.Visible = true
	end
	do
		layoutChrome(env, checkBtn, cancelBtn)
	end
	local color = env.getGhostBaseColor()
	if color then
		HandOrb.arm(color)
	end
	env.setAimFingerDown(true)
	env.releaseHandPin()
	env.startMoveHintAttract()
	env.startAimLoop()
	local pos = env.resolveParkPos(screenPos)
	if pos then
		env.updateGhostAt(pos)
	end
	env.syncConfirmButtons()
end

function PlaceArmDisarmAnim.playArmIntroFromSlot(
	env: Env,
	itemId: string,
	seedColor: Color3,
	onDone: () -> (),
	keepChromePinned: boolean?
)
	PlaceArmDisarmAnim.stopArmIntro()
	armIntroAnimating = true
	env.setAimPinnedToHand(true)
	env.setPendingGhostScaleIn(false)
	env.detachMoveHintToScreen()

	local slotScreen = env.getPendingArmSlotScreen()
	env.setPendingArmSlotScreen(nil)
	if not slotScreen then
		slotScreen = InventoryState.getItemSlotScreenCenter(itemId)
	end
	if not slotScreen then
		local cam = env.camera
		local vp = if cam then cam.ViewportSize else Vector2.new(800, 600)
		slotScreen = Vector2.new(vp.X * 0.85, vp.Y * 0.5)
	end

	local startWorld: Vector3
	local cam = env.camera
	if cam then
		local ray = cam:ViewportPointToRay(slotScreen.X, slotScreen.Y)
		startWorld = ray.Origin + ray.Direction * 7
	else
		startWorld = HandOrb.getHoldWorldPos() or Vector3.zero
	end

	HandOrb.clear()
	env.updateGhostAt(startWorld)
	local ghostPart = env.getGhost()
	if not ghostPart then
		armIntroAnimating = false
		HandOrb.arm(seedColor)
		onDone()
		return
	end

	local fullSize = ghostPart.Size
	armIntroFullSize = fullSize
	ghostPart.Size = fullSize * ARM_INTRO_START_SCALE
	env.makeConfirmUi()
	env.setMoveHintVisible(true)

	local chromePos = PlaceConfirmChrome.screenPos(env.getChromeAdorneePart())
	local checkBtn = env.getCheckBtn()
	local cancelBtn = env.getCancelBtn()
	local moveHintImage = env.getMoveHintImage()
	-- SeaFan: show yaw controls as soon as chrome exists (not only after fly-in ends).
	do
		local showRot = itemId == "SeaFan"
		local rotL = if env.getRotLeftBtn then env.getRotLeftBtn() else nil
		local rotR = if env.getRotRightBtn then env.getRotRightBtn() else nil
		if rotL then
			rotL.Visible = showRot
		end
		if rotR then
			rotR.Visible = showRot
		end
	end
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
	-- Always lay out once so rot circles sit beside Close immediately (not only when pinned).
	layoutChrome(env, checkBtn, cancelBtn)

	local t0 = os.clock()
	armIntroConn = RunService.RenderStepped:Connect(function()
		env.keepCameraFrozen()
		if env.getMode() == env.modeOff then
			PlaceArmDisarmAnim.stopArmIntro()
			return
		end
		local handWorld = HandOrb.getHoldWorldPos()
		local player = Players.LocalPlayer
		if not handWorld and player.Character then
			local hand = player.Character:FindFirstChild("RightHand") or player.Character:FindFirstChild("Right Arm")
			if hand and hand:IsA("BasePart") then
				handWorld = hand.Position
			end
		end
		handWorld = handWorld or startWorld

		local handScreen: Vector2 = slotScreen
		if cam then
			local sp, _ = cam:WorldToViewportPoint(handWorld)
			if sp.Z > 0 then
				handScreen = Vector2.new(sp.X, sp.Y)
			end
		end
		chromePos = PlaceConfirmChrome.screenPos(env.getChromeAdorneePart())

		local u = math.clamp((os.clock() - t0) / ARM_INTRO_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		local scale = ARM_INTRO_START_SCALE + (1 - ARM_INTRO_START_SCALE) * a

		local ghostBaseColor = env.getGhostBaseColor()
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
				layoutChrome(env, checkBtn, cancelBtn)
			end
		else
			local btnTravel = slotScreen:Lerp(chromePos, a)
			local fullBtn = PlaceConfirmChrome.chromeBtnSize(BTN_SIZE)
			local bsize = fullBtn * math.max(scale, 0.35)
			local rotL = if env.getRotLeftBtn then env.getRotLeftBtn() else nil
			local rotR = if env.getRotRightBtn then env.getRotRightBtn() else nil
			local showRot = env.getArmedItemId() == "SeaFan"
			if rotL then
				rotL.Visible = showRot
			end
			if rotR then
				rotR.Visible = showRot
			end
			PlaceConfirmChrome.layoutAt(
				btnTravel,
				bsize,
				env.getConfirmGui(),
				env.getChromeBillboard(),
				checkBtn,
				cancelBtn,
				rotL,
				rotR,
				showRot
			)
			if cancelBtn and cancelBtn.Parent then
				cancelBtn.Visible = true
			end
			if checkBtn and checkBtn.Parent then
				checkBtn.Visible = false
			end
		end

		if u >= 1 then
			PlaceArmDisarmAnim.stopArmIntro()
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
				layoutChrome(env, checkBtn, cancelBtn)
			end
			local color = ghostBaseColor or seedColor
			HandOrb.arm(color)
			env.setAimPinnedToHand(true)
			env.setAimPinOrigin(UserInputService:GetMouseLocation())
			if env.getPlacePointerHeld() and not InventoryState.isPointerOverBackpack(env.getAimPinOrigin() or Vector2.zero) then
				env.setAimFingerDown(true)
				env.releaseHandPin()
			end
			env.startMoveHintAttract()
			env.syncConfirmButtons()
			onDone()
		end
	end)
end

return PlaceArmDisarmAnim
