--!strict
--[[
	Relocate a previously placed coral while the backpack is open.
	Click coral → move icon + X scale up from its center.
	X (unmoved) → close tool. Drag → show ✓. ✓ saves; X after drag reverts.
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
local GridMath = require(oceanRoot:WaitForChild("Shared"):WaitForChild("GridMath"))
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local PlaceVfx = require(script.Parent:WaitForChild("PlaceVfx"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local SelectRing = require(script.Parent:WaitForChild("SelectRing"))

local RelocateController = {}

local BTN_SIZE = 60
local REC_BTN_SIZE = 40
local REC_GAP_PX = 6
local MOVE_ICON_SIZE = 48
local MOVE_ICON_IMAGE = "rbxassetid://345081302"
local RECYCLE_ICON_IMAGE = "rbxassetid://75091344292202"
local GHOST_INVALID_COLOR = Color3.fromRGB(220, 70, 70)
-- Raycast above the cursor so the coral center (+ move icon) sits under the mouse.
-- (Terrain hit is below the ball center on screen; +Y offset made this worse.)
local AIM_VISUAL_CENTER_OFFSET_Y = 56
-- Softer greens (less neon-bright).
local REC_GREEN = Color3.fromRGB(48, 145, 70)
local REC_GREEN_DIM = Color3.fromRGB(28, 88, 44)
local REC_FLASH_HZ = 1.5 -- background color flips / sec (slower)
local REC_LABEL_PERIOD = 1 -- seconds showing icon, then "+1"
local REC_SLIDE_SEC = 0.3
local REC_FLY_SEC = 0.55
local INTRO_SEC = 0.35
local REVERT_SEC = 0.4
local IDLE_CLOSE_DELAY_SEC = 3 -- gamepad: delay before showing idle close (B)
local DRAG_PX = 28
local GHOST_SCREEN_OFFSET_Y = 105
local FREEZE_ACTION = "OceanTD_RelocateFreeze"
local HOVER_HINT_PERIOD = 1 -- R1 badge ↔ move icon
local HOVER_HINT_SIZE = 32
local GAMEPAD_STICK_DEADZONE = 0.22
local GAMEPAD_AIM_SPEED = 343 -- px/sec at full deflection

local active = false
local busy = false
local introAnimating = false
local gamepadRelocate = false
local gamepadCursor: Vector2? = nil
local gamepadChromeT0 = 0
local relocateShownAt = 0
local part: BasePart? = nil
local originPos: Vector3? = nil
local placeId = ""
local itemId: string? = nil
local baseColor: Color3? = nil
local baseMaterial: Enum.Material? = nil
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
local recycleBtn: TextButton? = nil
local recycleIcon: ImageLabel? = nil
local recyclePlus: TextLabel? = nil
local moveBillboard: BillboardGui? = nil
local moveIcon: ImageLabel? = nil
local chromeBtnDown = false
local fingerDown = false
local pressOrigin: Vector2? = nil
local dragging = false

local frozen = false
local savedWalkSpeed = 16
local savedJumpPower = 50
local savedJumpHeight = 7.2
local savedCameraType: Enum.CameraType? = nil
local savedCameraCFrame: CFrame? = nil
local savedTouchControlsEnabled: boolean? = nil
local jumpUnlockConn: RBXScriptConnection? = nil
local loopConn: RBXScriptConnection? = nil
local hoverConn: RBXScriptConnection? = nil
local inputConns: { RBXScriptConnection } = {}

-- Hover neon flash (backpack open, not relocating).
local hoverPart: BasePart? = nil
local hoverBaseMaterial: Enum.Material? = nil
local hoverBaseColor: Color3? = nil
local hoverHintBb: BillboardGui? = nil
local hoverHintBadge: Frame? = nil
local hoverHintMove: Frame? = nil
local hoverHintT0 = 0

-- White grow/shrink ring so players can see the interactive coral (hover + move tool).
local selectRing = SelectRing.new()

-- Click pick: press may be marked processed by GUI; confirm on release too.
local pendingPick: BasePart? = nil
local pendingPickScreen: Vector2? = nil
local PICK_TAP_PX = 48
-- Max screen-space distance from a coral's projected center to count as a tap/hover.
local PICK_SCREEN_PX = 42

local function log(...: any)
	print("[RELOCATE]", ...)
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
	local inset = GuiService:GetGuiInset()
	local vp = cam.ViewportSize
	return Vector2.new(
		math.clamp(pos.X, inset.X + 8, inset.X + vp.X - 8),
		math.clamp(pos.Y, inset.Y + 8, inset.Y + vp.Y - 8)
	)
end

local function hoverPickScreenPos(): Vector2
	-- Gamepad: highlight coral near screen center (look / walk aim).
	if isUsingGamepad() then
		local cam = Workspace.CurrentCamera
		if cam then
			local vp = cam.ViewportSize
			return Vector2.new(vp.X * 0.5, vp.Y * 0.5)
		end
	end
	return UserInputService:GetMouseLocation()
end

local function viewportToScreen(v: Vector2): Vector2
	local inset = GuiService:GetGuiInset()
	return Vector2.new(v.X + inset.X, v.Y + inset.Y)
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
	hum.JumpPower = if savedJumpPower > 0 then savedJumpPower else 50
	hum.JumpHeight = if savedJumpHeight > 0 then savedJumpHeight else 7.2
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
	-- Keyboard always. Sink ButtonA so confirm doesn't queue a jump. Thumbstick1 only while
	-- gamepad relocate (don't bind on touch — unbinding Thumbstick1 can break mobile movement).
	local sinkKeys: { Enum.KeyCode } = {
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
		Enum.KeyCode.Space,
		Enum.KeyCode.ButtonA,
	}
	if gamepadRelocate then
		table.insert(sinkKeys, Enum.KeyCode.Thumbstick1)
	end
	ContextActionService:BindActionAtPriority(FREEZE_ACTION, function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, table.unpack(sinkKeys))
end

local function keepCameraFrozen()
	if camera and savedCameraCFrame then
		camera.CFrame = savedCameraCFrame
	end
end

local function pointerScreenPos(): Vector2
	return UserInputService:GetMouseLocation()
end

local function aimScreenPos(): Vector2
	local finger = pointerScreenPos()
	if gamepadRelocate and gamepadCursor then
		return Vector2.new(gamepadCursor.X, gamepadCursor.Y - AIM_VISUAL_CENTER_OFFSET_Y)
	end
	if UserInputService:GetLastInputType() == Enum.UserInputType.Touch then
		return Vector2.new(finger.X, finger.Y - GHOST_SCREEN_OFFSET_Y)
	end
	-- Mouse: aim above the cursor so the ball center lands on it.
	return Vector2.new(finger.X, finger.Y - AIM_VISUAL_CENTER_OFFSET_Y)
end

local function worldToScreen(world: Vector3): Vector2?
	if not camera then
		return nil
	end
	local sp, _ = camera:WorldToViewportPoint(world)
	if sp.Z <= 0 then
		return nil
	end
	return Vector2.new(sp.X, sp.Y)
end

local function destroyUi()
	uiSession += 1
	if moveBillboard then
		moveBillboard:Destroy()
		moveBillboard = nil
	end
	moveIcon = nil
	if gui then
		gui:Destroy()
		gui = nil
	end
	checkBtn = nil
	cancelBtn = nil
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
		b.BackgroundTransparency = 0
		b.Font = UiTheme.Font
		b.Text = text
		b.TextColor3 = Color3.new(1, 1, 1)
		b.TextScaled = true
		b.AutoButtonColor = true
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

	checkBtn = roundBtn("✓", Color3.fromRGB(40, 180, 80), BTN_SIZE)
	cancelBtn = roundBtn("X", Color3.fromRGB(200, 50, 50), BTN_SIZE)

	recycleBtn = roundBtn("", REC_GREEN, REC_BTN_SIZE)
	recycleBtn.Name = "Recycle"
	recycleBtn.AutoButtonColor = false
	local recIcon = Instance.new("ImageLabel")
	recIcon.Name = "Icon"
	recIcon.BackgroundTransparency = 1
	recIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	recIcon.Position = UDim2.fromScale(0.5, 0.5)
	recIcon.Size = UDim2.fromScale(0.62, 0.62)
	recIcon.Image = RECYCLE_ICON_IMAGE
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

	local function markDown()
		chromeBtnDown = true
		fingerDown = false
		pressOrigin = nil
		dragging = false
	end
	checkBtn.MouseButton1Down:Connect(markDown)
	cancelBtn.MouseButton1Down:Connect(markDown)
	recycleBtn.MouseButton1Down:Connect(markDown)
	checkBtn.MouseButton1Click:Connect(function()
		RelocateController.commit()
	end)
	cancelBtn.MouseButton1Click:Connect(function()
		-- X always closes move/recycle UI (cancels recycle confirm if open).
		RelocateController.cancel()
	end)
	recycleBtn.MouseButton1Click:Connect(function()
		RelocateController.beginRecycleConfirm()
	end)
end

local function attachMoveIcon(adornee: BasePart)
	if moveBillboard then
		moveBillboard:Destroy()
		moveBillboard = nil
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "OceanTD_RelocateMove"
	bb.AlwaysOnTop = true
	bb.Active = false
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(MOVE_ICON_SIZE, MOVE_ICON_SIZE)
	bb.MaxDistance = 2000
	bb.Adornee = adornee
	bb.Parent = playerGui
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Image = MOVE_ICON_IMAGE
	img.ScaleType = Enum.ScaleType.Fit
	img.Parent = bb
	local scale = Instance.new("UIScale")
	scale.Name = "IntroScale"
	scale.Scale = 1
	scale.Parent = img
	moveBillboard = bb
	moveIcon = img
end

local function findBlockingCoral(worldPos: Vector3, ignorePart: BasePart?): BasePart?
	local plot = ClientPlot.get()
	if not plot then
		return nil
	end
	local localPos = GridMath.worldToPlotLocal(worldPos, plot.cframe)
	local gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
	local root = Workspace:FindFirstChild("OceanTD_Placed")
	local folder = root and root:FindFirstChild(plot.plotId)
	if not folder then
		return nil
	end
	for _, inst in ipairs(folder:GetChildren()) do
		if inst:IsA("BasePart") and inst ~= ignorePart then
			local lp = GridMath.worldToPlotLocal(inst.Position, plot.cframe)
			local ax, ay, az = GridMath.worldToGrid(lp, Vector3.zero)
			if ax == gx and ay == gy and az == gz then
				return inst
			end
		end
	end
	return nil
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

local function evaluate(worldPos: Vector3): (boolean, string?)
	if not ClientPlot.isInside(worldPos) then
		return false, "Out Of Plot"
	end
	if originPos and sameGrid(worldPos, originPos) then
		return true, nil
	end
	if findBlockingCoral(worldPos, part) then
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
	if hoverPart == target then
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
		return
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
	local ray = cam:ScreenPointToRay(screenPos.X, screenPos.Y)
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

local function isPlacedCoralPart(inst: Instance): BasePart?
	if not inst:IsA("BasePart") then
		return nil
	end
	-- Ignore local wave FX (food orbs / ammo) if they ever share a folder.
	local n = inst.Name
	if n == "OceanTD_CoralAmmo" or n == "OceanTD_FoodOrb" or string.find(n, "Tang_", 1, true) == 1 then
		return nil
	end
	if typeof(inst:GetAttribute("OceanTD_GhostBaseR")) == "number" then
		return nil
	end
	if typeof(inst:GetAttribute("OceanTD_ItemId")) == "string" or typeof(inst:GetAttribute("OceanTD_SpeciesId")) == "string" then
		return inst
	end
	return nil
end

local function getPlotFolder(): Folder?
	local plot = ClientPlot.get()
	if not plot then
		return nil
	end
	local root = Workspace:FindFirstChild("OceanTD_Placed")
	local folder = root and root:FindFirstChild(plot.plotId)
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

-- Prefer a real physics hit on the coral. Fallback: coral center near the tap in screen space
-- (NOT along-ray 3D proximity — that grabbed distant corals when tapping empty ground).
-- Occlusion: never pick a coral behind terrain / other world geometry.
local function pickPlacedCoral(screenPos: Vector2): BasePart?
	local folder = getPlotFolder()
	local cam = Workspace.CurrentCamera
	if not folder or not cam then
		return nil
	end

	-- World pick must hit terrain first if it blocks — do NOT Include-only the coral folder
	-- (that passes through terrain and selects the far side).
	local exclude: { Instance } = {}
	if player.Character then
		table.insert(exclude, player.Character)
	end
	if part then
		table.insert(exclude, part)
	end

	local worldParams = RaycastParams.new()
	worldParams.FilterType = Enum.RaycastFilterType.Exclude
	worldParams.FilterDescendantsInstances = exclude

	local function coralFromHit(inst: Instance): BasePart?
		local cur: Instance? = inst
		while cur and cur ~= folder.Parent do
			if cur == folder then
				break
			end
			if cur:IsA("BasePart") and cur:IsDescendantOf(folder) then
				local coral = isPlacedCoralPart(cur)
				if coral then
					return coral
				end
			end
			cur = cur.Parent
		end
		return nil
	end

	local function directWorldHit(useViewport: boolean): BasePart?
		local ray = if useViewport
			then cam:ViewportPointToRay(screenPos.X, screenPos.Y)
			else cam:ScreenPointToRay(screenPos.X, screenPos.Y)
		local result = Workspace:Raycast(ray.Origin, ray.Direction * 800, worldParams)
		if not result then
			return nil
		end
		-- First solid hit must be the coral itself (visible).
		return coralFromHit(result.Instance)
	end

	local hit = directWorldHit(false) or directWorldHit(true)
	if hit then
		return hit
	end

	-- Near-miss fallback: closest on-screen coral that still has clear LOS from camera.
	local losParams = RaycastParams.new()
	losParams.FilterType = Enum.RaycastFilterType.Exclude

	local function hasLineOfSight(coral: BasePart): boolean
		local origin = cam.CFrame.Position
		local target = coral.Position
		local delta = target - origin
		local dist = delta.Magnitude
		if dist < 0.25 then
			return true
		end
		local list: { Instance } = { coral }
		if player.Character then
			table.insert(list, player.Character)
		end
		losParams.FilterDescendantsInstances = list
		-- Ray only as far as the coral center so we can't "hit" geometry behind it.
		local result = Workspace:Raycast(origin, delta.Unit * dist, losParams)
		if not result then
			return true
		end
		return result.Distance >= dist - 0.35
	end

	local radius = if isUsingGamepad() then math.max(PICK_SCREEN_PX, 72) else PICK_SCREEN_PX
	-- Top-3 nearest on screen, then LOS-test in order (at most 3 occlusion rays).
	local c1: BasePart? = nil
	local c2: BasePart? = nil
	local c3: BasePart? = nil
	local d1, d2, d3 = radius + 1, radius + 1, radius + 1
	for _, inst in ipairs(folder:GetChildren()) do
		local coral = isPlacedCoralPart(inst)
		if coral and coral ~= part then
			local sp, onScreen = cam:WorldToViewportPoint(coral.Position)
			if onScreen and sp.Z > 0 then
				local d = (Vector2.new(sp.X, sp.Y) - screenPos).Magnitude
				if d <= radius then
					if d < d1 then
						c3, d3 = c2, d2
						c2, d2 = c1, d1
						c1, d1 = coral, d
					elseif d < d2 then
						c3, d3 = c2, d2
						c2, d2 = coral, d
					elseif d < d3 then
						c3, d3 = coral, d
					end
				end
			end
		end
	end

	if c1 and hasLineOfSight(c1) then
		return c1
	end
	if c2 and hasLineOfSight(c2) then
		return c2
	end
	if c3 and hasLineOfSight(c3) then
		return c3
	end
	return nil
end

local function destroyHoverHint()
	if hoverHintBb then
		hoverHintBb:Destroy()
		hoverHintBb = nil
	end
	hoverHintBadge = nil
	hoverHintMove = nil
end

local function ensureHoverHint(adornee: BasePart)
	if hoverHintBb and hoverHintBb.Parent and hoverHintBb.Adornee == adornee then
		return
	end
	destroyHoverHint()
	local bb = Instance.new("BillboardGui")
	bb.Name = "OceanTD_RelocateHoverHint"
	bb.AlwaysOnTop = true
	bb.Active = false
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(HOVER_HINT_SIZE, HOVER_HINT_SIZE)
	bb.StudsOffset = Vector3.new(0, 2.6, 0)
	bb.MaxDistance = 2000
	bb.Adornee = adornee
	bb.Parent = playerGui

	local badge = Instance.new("Frame")
	badge.Name = "R1Badge"
	badge.BackgroundColor3 = Color3.new(0, 0, 0)
	badge.BackgroundTransparency = 0.15
	badge.BorderSizePixel = 0
	badge.Size = UDim2.fromScale(1, 1)
	badge.Parent = bb
	UiCircles.ensure(badge)
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = UiTheme.Font
	lbl.Text = "R1"
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextScaled = true
	lbl.Parent = badge

	local moveBg = Instance.new("Frame")
	moveBg.Name = "MoveHint"
	moveBg.BackgroundColor3 = Color3.new(0, 0, 0)
	moveBg.BackgroundTransparency = 0.15
	moveBg.BorderSizePixel = 0
	moveBg.Size = UDim2.fromScale(1, 1)
	moveBg.Visible = false
	moveBg.Parent = bb
	UiCircles.ensure(moveBg)
	local move = Instance.new("ImageLabel")
	move.BackgroundTransparency = 1
	move.AnchorPoint = Vector2.new(0.5, 0.5)
	move.Position = UDim2.fromScale(0.5, 0.5)
	move.Size = UDim2.fromScale(0.7, 0.7)
	move.Image = MOVE_ICON_IMAGE
	move.ScaleType = Enum.ScaleType.Fit
	move.Parent = moveBg

	hoverHintBb = bb
	hoverHintBadge = badge
	hoverHintMove = moveBg
	hoverHintT0 = os.clock()
end

local function updateHoverHint()
	if not isUsingGamepad() or not hoverPart or not hoverPart.Parent then
		destroyHoverHint()
		return
	end
	ensureHoverHint(hoverPart)
	local showMove = (math.floor((os.clock() - hoverHintT0) / HOVER_HINT_PERIOD) % 2) == 1
	if hoverHintBadge then
		hoverHintBadge.Visible = not showMove
	end
	if hoverHintMove then
		hoverHintMove.Visible = showMove
	end
end

local function clearHover()
	destroyHoverHint()
	-- Don't tear down the relocate ring while the move tool owns the coral.
	if SelectRing.getAdornee(selectRing) == hoverPart then
		SelectRing.destroy(selectRing)
	end
	if hoverPart and hoverPart.Parent then
		-- Prefer stored rest look so a failed prior capture can't leave Neon stuck.
		if hoverBaseMaterial and hoverBaseColor then
			hoverPart.Material = hoverBaseMaterial
			hoverPart.Color = hoverBaseColor
		else
			CoralVisual.applyRestLook(hoverPart)
		end
	elseif hoverPart then
		-- Part was destroyed while highlighted — still drop SelectRing if needed.
		SelectRing.destroy(selectRing)
	end
	hoverPart = nil
	hoverBaseMaterial = nil
	hoverBaseColor = nil
end

local function setHover(target: BasePart?)
	if hoverPart == target then
		return
	end
	clearHover()
	if not target or not target.Parent then
		return
	end
	-- Don't hover-paint a coral that's already in spot-taken neon.
	if blockPart == target then
		return
	end
	-- Skip wave ammo / food if mis-picked.
	if not isPlacedCoralPart(target) then
		return
	end
	hoverPart = target
	-- Always restore from rest attributes (never capture mid-pulse Neon as base).
	local restMat, restColor = CoralVisual.readRestLook(target)
	hoverBaseMaterial = restMat
	hoverBaseColor = restColor
	target.Material = Enum.Material.Neon
	SelectRing.ensure(selectRing, target, playerGui)
end

local function updateHoverFlash()
	if not hoverPart or not hoverPart.Parent or not hoverBaseColor then
		return
	end
	-- Pulse bright neon in the coral's own color.
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * 9)
	hoverPart.Material = Enum.Material.Neon
	hoverPart.Color = hoverBaseColor:Lerp(Color3.new(1, 1, 1), 0.12 + 0.28 * pulse)
	SelectRing.pulse(selectRing)
end

local function stopHoverLoop()
	if hoverConn then
		hoverConn:Disconnect()
		hoverConn = nil
	end
	clearHover()
end

local function startHoverLoop()
	if hoverConn then
		return
	end
	hoverConn = RunService.RenderStepped:Connect(function()
		if active or busy or not InventoryState.isOpen() or PlacementController.isActive()
			or InventoryState.isBuildModalBlocking()
		then
			clearHover()
			return
		end
		-- Waves run local neon ammo FX; still allow pick, but always clear cleanly when nothing hit.
		local screenPos = hoverPickScreenPos()
		if not isUsingGamepad() and InventoryState.isPointerOverBackpack(screenPos) then
			clearHover()
			return
		end
		local hit = pickPlacedCoral(screenPos)
		if hit then
			setHover(hit)
			updateHoverFlash()
			updateHoverHint()
		else
			clearHover()
		end
	end)
end

local function syncChrome()
	if recycleFlying or introAnimating then
		return
	end
	if not active or not part or not checkBtn or not cancelBtn then
		return
	end
	local screen = worldToScreen(part.Position)
	if not screen then
		-- Behind camera / off-screen — still show chrome near pointer so the tool isn't blank.
		screen = pointerScreenPos()
	end
	local cx = screen.X
	local cy = screen.Y - 52

	if recycleSlideActive then
		local u = math.clamp((os.clock() - recycleSlideT0) / REC_SLIDE_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		recycleSlideU = a
		if u >= 1 then
			recycleSlideActive = false
			recycleSlideU = 1
		end
	end

	-- Idle close (exit tool): keyboard/mouse instantly; gamepad after 3s.
	-- After a move / recycle confirm: always show cancel for that action.
	local idleCloseReady = (not gamepadRelocate) or ((os.clock() - relocateShownAt) >= IDLE_CLOSE_DELAY_SEC)
	local showIdleClose = (not hasMoved) and (not recyclePending) and idleCloseReady
	local showCancel = hasMoved or recyclePending or showIdleClose
	cancelBtn.Visible = showCancel
	cancelBtn.Size = UDim2.fromOffset(BTN_SIZE, BTN_SIZE)
	local tipLetter = if gamepadRelocate then "B" else "X"
	local showWord = (math.floor((os.clock() - gamepadChromeT0) / HOVER_HINT_PERIOD) % 2) == 1
	if hasMoved or recyclePending then
		-- Right side: cancel the pending move / recycle.
		cancelBtn.AnchorPoint = Vector2.new(0, 1)
		cancelBtn.Position = UDim2.fromOffset(cx + 6, cy)
		cancelBtn.Text = if showWord then "CANCEL" else tipLetter
		cancelBtn.TextStrokeColor3 = if showWord then Color3.fromRGB(60, 15, 18) else Color3.new(1, 1, 1)
		cancelBtn.TextStrokeTransparency = 0
	else
		-- Idle close: left of coral (recycle stays on the right).
		cancelBtn.AnchorPoint = Vector2.new(1, 1)
		cancelBtn.Position = UDim2.fromOffset(cx - 6, cy)
		cancelBtn.Text = if showWord then "CLOSE" else tipLetter
		cancelBtn.TextStrokeColor3 = if showWord then Color3.fromRGB(60, 15, 18) else Color3.new(1, 1, 1)
		cancelBtn.TextStrokeTransparency = 0
	end

	-- ✓ for move confirm, or for recycle confirm.
	checkBtn.Visible = (hasMoved and validSpot) or recyclePending
	checkBtn.AnchorPoint = Vector2.new(1, 1)
	checkBtn.Position = UDim2.fromOffset(cx - 6, cy)
	checkBtn.Size = UDim2.fromOffset(BTN_SIZE, BTN_SIZE)
	if checkBtn.Visible then
		local confirmWord = if isUsingGamepad() then "A" else "Enter"
		-- Touch has no keyboard tip — keep CONFIRM.
		if UserInputService:GetLastInputType() == Enum.UserInputType.Touch then
			confirmWord = "CONFIRM"
		end
		local label = if showWord then confirmWord else "✓"
		checkBtn.Text = label
		checkBtn.TextStrokeColor3 = if showWord then Color3.fromRGB(12, 55, 25) else Color3.new(1, 1, 1)
		checkBtn.TextStrokeTransparency = 0
	end

	if recycleBtn then
		-- Hide recycle while dragging a move; show again after confirm, or during recycle confirm.
		local showRecycle = (not hasMoved) or recyclePending
		recycleBtn.Visible = showRecycle
		if showRecycle then
			recycleBtn.AnchorPoint = Vector2.new(0.5, 1)
			recycleBtn.Size = UDim2.fromOffset(REC_BTN_SIZE, REC_BTN_SIZE)
			-- Idle (not moved): recycle sits where X will appear. Recycle confirm: above ✓/X pair.
			local aboveX = cx + 6 + BTN_SIZE * 0.5
			local abovePair = cx
			local idleRecX = aboveX
			local idleRecY = cy
			local movedRecX = aboveX + (abovePair - aboveX) * recycleSlideU
			local movedRecY = cy - BTN_SIZE - REC_GAP_PX
			local recX = if recyclePending then movedRecX else idleRecX
			local recY = if recyclePending then movedRecY else idleRecY
			recycleBtn.Position = UDim2.fromOffset(recX, recY)

			if recyclePending then
				local age = os.clock() - recycleSlideT0
				local pulse = (math.floor(age * REC_FLASH_HZ) % 2) == 0
				recycleBtn.BackgroundColor3 = if pulse then REC_GREEN else REC_GREEN_DIM
				local showPlus = (math.floor(age / REC_LABEL_PERIOD) % 2) == 1
				if recycleIcon then
					recycleIcon.Visible = not showPlus
				end
				if recyclePlus then
					recyclePlus.Text = "+1"
					recyclePlus.Visible = showPlus
				end
			else
				recycleBtn.BackgroundColor3 = REC_GREEN
				-- icon → shortcut → COLLECT (1s each)
				local phase = math.floor((os.clock() - gamepadChromeT0) / HOVER_HINT_PERIOD) % 3
				if recycleIcon then
					recycleIcon.Visible = phase == 0
				end
				if recyclePlus then
					if phase == 1 then
						recyclePlus.Text = if isUsingGamepad() then "L1" else "Del"
						recyclePlus.Visible = true
					elseif phase == 2 then
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
	if not part or not originPos then
		return
	end
	part.CFrame = CFrame.new(worldPos)
	local ok, reason = evaluate(worldPos)
	validSpot = ok
	rejectReason = reason
	if not sameGrid(worldPos, originPos) then
		hasMoved = true
	end
	if validSpot or rejectReason ~= "Spot Taken" then
		clearBlockHighlight()
	else
		setBlockHighlight(findBlockingCoral(worldPos, part))
	end
	ClientPlot.setOutOfPlotFlash(rejectReason == "Out Of Plot")
	syncWarnLabel()
	syncChrome()
end

local function restorePartLook(p: BasePart?)
	if not p or not p.Parent then
		return
	end
	if baseMaterial and baseColor then
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
	-- Keep blocker solid red neon (do not pulse it).
	if blockPart and blockPart.Parent then
		blockPart.Material = Enum.Material.Neon
		blockPart.Color = Color3.fromRGB(255, 45, 45)
	end
	SelectRing.ensure(selectRing, part, playerGui)
	SelectRing.pulse(selectRing)
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
		if gamepadRelocate and not busy and not recyclePending and not introAnimating and not recycleFlying then
			local stick = readThumbstick1()
			local mag = stick.Magnitude
			if mag > GAMEPAD_STICK_DEADZONE then
				local screen = if part then worldToScreen(part.Position) else nil
				if not gamepadCursor then
					gamepadCursor = if screen
						then viewportToScreen(screen)
						else UserInputService:GetMouseLocation()
				end
				local dir = stick.Unit
				local speed = GAMEPAD_AIM_SPEED * math.clamp((mag - GAMEPAD_STICK_DEADZONE) / (1 - GAMEPAD_STICK_DEADZONE), 0, 1)
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
	recycleBtn.AnchorPoint = Vector2.new(0.5, 0.5)
	recycleBtn.Position = UDim2.fromOffset(fromScreen.X, fromScreen.Y)
	recycleBtn.Size = UDim2.fromOffset(REC_BTN_SIZE, REC_BTN_SIZE)
	recycleBtn.BackgroundColor3 = REC_GREEN
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
		local u = math.clamp((os.clock() - t0) / INTRO_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		if moveScale and moveScale.Parent then
			moveScale.Scale = 0.05 + 0.95 * a
		end
		if recScale and recScale.Parent then
			recScale.Scale = 0.05 + 0.95 * a
		end
		local screen = if part then worldToScreen(part.Position) else fromScreen
		if not screen then
			screen = fromScreen
		end
		if recycleBtn then
			local cx = screen.X
			local cy = screen.Y - 52
			-- End: recycle where X will sit (right of coral).
			local recEnd = Vector2.new(cx + 6 + BTN_SIZE * 0.5, cy - REC_BTN_SIZE * 0.5)
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
	clearBlockHighlight()
	ClientPlot.setOutOfPlotFlash(false)
	restorePartLook(part)
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
	placeId = ""
	itemId = nil
	baseColor = nil
	baseMaterial = nil
	hasMoved = false
	validSpot = true
	rejectReason = nil
	recyclePending = false
	recycleFlying = false
	recycleSlideU = 0
	recycleSlideActive = false
	chromeBtnDown = false
	fingerDown = false
	pressOrigin = nil
	dragging = false
	unfreeze()
end

function RelocateController.isActive(): boolean
	return active
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
	local p = part
	local origin = originPos
	local moved = hasMoved
	local color = baseColor

	local function snapHome()
		if p and origin and p.Parent then
			p.CFrame = CFrame.new(origin)
		end
		clearState()
	end

	if moved and p and origin and p.Parent and not instant then
		busy = true
		local start = p.Position
		local t0 = os.clock()
		local conn: RBXScriptConnection
		conn = RunService.RenderStepped:Connect(function()
			keepCameraFrozen()
			local u = math.clamp((os.clock() - t0) / REVERT_SEC, 0, 1)
			local a = 1 - (1 - u) * (1 - u)
			if p.Parent then
				p.CFrame = CFrame.new(start:Lerp(origin, a))
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
	part.CFrame = CFrame.new(originPos)
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
	recycleBtn.BackgroundColor3 = REC_GREEN
	recycleBtn.Active = false

	local startSize = REC_BTN_SIZE
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
		local u = math.clamp((os.clock() - t0) / REC_FLY_SEC, 0, 1)
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
	local fromPos = originPos
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
			placeId = ""
			itemId = nil
			baseColor = nil
			baseMaterial = nil
			hasMoved = false
			validSpot = true
			rejectReason = nil
			chromeBtnDown = false
			fingerDown = false
			pressOrigin = nil
			dragging = false
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

function RelocateController.commit()
	if not active or busy then
		return
	end
	if recyclePending then
		commitRecycle()
		return
	end
	if not hasMoved or not validSpot then
		return
	end
	if not part or not originPos or not itemId then
		return
	end
	local toPos = part.Position
	local fromPos = originPos
	local id = placeId
	busy = true
	PlaceVfx.playSound(toPos)
	local rf = Remotes.getFunction("RequestMove")
	local result = rf:InvokeServer(id, fromPos, toPos)
	if typeof(result) == "table" and result.ok then
		UiHaptics.pulseShort()
		if part and part.Parent then
			local finalPos = if typeof(result.worldPos) == "Vector3" then result.worldPos else toPos
			part.CFrame = CFrame.new(finalPos)
			if typeof(result.placeId) == "string" and result.placeId ~= "" then
				part:SetAttribute("OceanTD_PlaceId", result.placeId)
				placeId = result.placeId
			elseif placeId ~= "" then
				part:SetAttribute("OceanTD_PlaceId", placeId)
			end
			-- Stay on this coral: reset move state so recycle returns until the next drag.
			originPos = finalPos
		end
		PlaceVfx.playVisuals(toPos, baseColor or Color3.fromRGB(100, 200, 255))
		hasMoved = false
		validSpot = true
		rejectReason = nil
		busy = false
		recycleSlideU = 0
		recycleSlideActive = false
		syncChrome()
		log("Saved move")
	else
		local code = typeof(result) == "table" and result.errorCode or "Reject"
		log("Move rejected", code)
		busy = false
		validSpot = false
		syncChrome()
	end
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
	part = target
	originPos = target.Position
	itemId = iid
	baseColor = restColor
	baseMaterial = restMat
	hasMoved = false
	validSpot = true
	rejectReason = nil
	recyclePending = false
	recycleFlying = false
	introAnimating = false
	recycleSlideU = 0
	recycleSlideActive = false
	local existingId = target:GetAttribute("OceanTD_PlaceId")
	placeId = if typeof(existingId) == "string" then existingId else ""

	local vpScreen = worldToScreen(target.Position)
	local screen = vpScreen or pointerScreenPos()
	if gamepadRelocate then
		-- Aim cursor is GetMouseLocation / ScreenPoint space.
		gamepadCursor = if vpScreen then viewportToScreen(vpScreen) else screen
	else
		gamepadCursor = nil
	end

	target.Material = Enum.Material.Neon
	SelectRing.ensure(selectRing, target, playerGui)
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

local function isOverChrome(screenPos: Vector2): boolean
	if chromeBtnDown then
		return true
	end
	local function hit(btn: GuiObject?): boolean
		if not btn or not btn.Visible then
			return false
		end
		local p = btn.AbsolutePosition
		local s = btn.AbsoluteSize
		local pad = 12
		return screenPos.X >= p.X - pad
			and screenPos.X <= p.X + s.X + pad
			and screenPos.Y >= p.Y - pad
			and screenPos.Y <= p.Y + s.Y + pad
	end
	return hit(checkBtn) or hit(cancelBtn) or hit(recycleBtn)
end

table.insert(inputConns, UserInputService.InputBegan:Connect(function(input, processed)
	local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1
	local isTouch = input.UserInputType == Enum.UserInputType.Touch

	if active then
		if busy then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.X or input.KeyCode == Enum.KeyCode.ButtonB then
			RelocateController.cancel()
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonA then
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
		local screenPos = pointerScreenPos()
		if isOverChrome(screenPos) then
			chromeBtnDown = true
			return
		end
		if InventoryState.isPointerOverBackpack(screenPos) then
			return
		end
		if processed then
			return
		end
		-- Lock drag while confirming recycle.
		if recyclePending then
			return
		end
		fingerDown = true
		pressOrigin = screenPos
		dragging = false
		return
	end

	-- Gamepad: R1 / RB starts move on the neon-highlighted coral.
	if input.KeyCode == Enum.KeyCode.ButtonR1 then
		if PlacementController.isActive() or not InventoryState.isOpen() then
			return
		end
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
		if (now - pressOrigin).Magnitude < DRAG_PX then
			return
		end
		dragging = true
	end
	if not dragging and not fingerDown then
		return
	end
	local pos = raycastTerrain(aimScreenPos())
	if pos then
		updateAt(pos)
	end
end))

table.insert(inputConns, UserInputService.InputEnded:Connect(function(input, _processed)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local screenPos = pointerScreenPos()
	chromeBtnDown = false
	fingerDown = false
	pressOrigin = nil
	dragging = false

	-- Tap fallback: if press didn't open the tool (processed/ray miss), try again on release.
	if not active and not PlacementController.isActive() and pendingPick and pendingPickScreen then
		if (screenPos - pendingPickScreen).Magnitude <= PICK_TAP_PX then
			if pendingPick.Parent then
				RelocateController.begin(pendingPick)
			else
				tryBeginFromPick(screenPos)
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

log("Ready")

return RelocateController
