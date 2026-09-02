--!strict
--[[
	Feet-locked ✓/X (+ optional SeaFan rotate) layout helpers for PlacementController.
	Extracted so PlacementController stays under Luau's 200-local limit.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiViewportTags = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiViewportTags"))

local player = Players.LocalPlayer

local PlaceConfirmChrome = {}

local BTN_FALLBACK_BOTTOM_PAD = 28
-- Small lift so chrome sits at the ankles, not buried in the floor.
local FEET_LIFT = 0.45
-- Base chrome diameter before viewport scale (PlacementController default).
local BASE_BTN_PX = 52
-- Confirm is 20% larger than Close / rot.
local CONFIRM_BTN_SCALE = 1.2
-- ≤720p class (mobile): 30% smaller. 720p+: 20% larger.
local MOBILE_BTN_SCALE = 0.7
local DESKTOP_BTN_SCALE = 1.2

local ROT_BG = Color3.fromRGB(0, 162, 237) -- #00a2ed
local ROT_SOUND_ID = "rbxassetid://139911414972673"
local ROT_LEFT_ICON = "rbxassetid://96091927054382"
local ROT_RIGHT_ICON = "rbxassetid://98172417849326"

function PlaceConfirmChrome.chromeBtnSize(basePx: number?): number
	local base = if typeof(basePx) == "number" and basePx > 0 then basePx else BASE_BTN_PX
	local scale = if UiViewportTags.is720p() then DESKTOP_BTN_SCALE else MOBILE_BTN_SCALE
	return math.max(math.floor(base * scale + 0.5), 28)
end

function PlaceConfirmChrome.confirmBtnSize(basePx: number?): number
	return math.max(math.floor(PlaceConfirmChrome.chromeBtnSize(basePx) * CONFIRM_BTN_SCALE + 0.5), 28)
end

-- Fixed px for the word "CONFIRM" inside the circle (TextScaled wraps it on mobile).
function PlaceConfirmChrome.confirmLabelTextSize(): number
	return if UiViewportTags.is720p() then 12 else 9
end

local CONFIRM_CHECK_IMAGE = "rbxassetid://114269375380072"

function PlaceConfirmChrome.ensureConfirmCheckIcon(btn: GuiObject): ImageLabel
	local existing = btn:FindFirstChild("ConfirmCheckIcon")
	if existing and existing:IsA("ImageLabel") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local icon = Instance.new("ImageLabel")
	icon.Name = "ConfirmCheckIcon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(0.58, 0.58)
	icon.Image = CONFIRM_CHECK_IMAGE
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Active = false
	icon.Visible = false
	icon.ZIndex = (btn :: GuiObject).ZIndex + 1
	icon.Parent = btn
	return icon
end

-- Alternate CONFIRM text ↔ check graphic (same 1s cadence as CANCEL/X). Gamepad stays on "A".
function PlaceConfirmChrome.syncConfirmFace(btn: TextButton, showWord: boolean, gamepadLetter: boolean?)
	local icon = PlaceConfirmChrome.ensureConfirmCheckIcon(btn)
	if gamepadLetter then
		icon.Visible = false
		btn.Text = "A"
		btn.TextTransparency = 0
		btn.TextScaled = true
		btn.TextStrokeColor3 = Color3.fromRGB(12, 55, 25)
		btn.TextStrokeTransparency = 0
		return
	end
	if showWord then
		icon.Visible = false
		btn.Text = "CONFIRM"
		btn.TextTransparency = 0
		btn.TextScaled = false
		btn.TextSize = PlaceConfirmChrome.confirmLabelTextSize()
		btn.TextStrokeColor3 = Color3.fromRGB(12, 55, 25)
		btn.TextStrokeTransparency = 0
	else
		btn.Text = ""
		btn.TextTransparency = 1
		icon.Visible = true
	end
end

PlaceConfirmChrome.CONFIRM_CHECK_IMAGE = CONFIRM_CHECK_IMAGE

-- Centered on the character (root XZ), Y at average foot height.
local function feetOffsetFromRoot(char: Model, root: BasePart): CFrame
	local left = char:FindFirstChild("LeftFoot") or char:FindFirstChild("Left Leg")
	local right = char:FindFirstChild("RightFoot") or char:FindFirstChild("Right Leg")
	local feetY: number? = nil
	if left and left:IsA("BasePart") and right and right:IsA("BasePart") then
		local mid = (left.Position + right.Position) * 0.5
		if left.Name == "Left Leg" or right.Name == "Right Leg" then
			-- R6 legs are mid-shin; drop to the sole.
			mid = mid - Vector3.new(0, (left.Size.Y + right.Size.Y) * 0.25, 0)
		end
		feetY = mid.Y + FEET_LIFT
	elseif left and left:IsA("BasePart") then
		local y = left.Position.Y
		if left.Name == "Left Leg" or left.Name == "Right Leg" then
			y -= left.Size.Y * 0.5
		end
		feetY = y + FEET_LIFT
	elseif right and right:IsA("BasePart") then
		local y = right.Position.Y
		if right.Name == "Left Leg" or right.Name == "Right Leg" then
			y -= right.Size.Y * 0.5
		end
		feetY = y + FEET_LIFT
	end
	if typeof(feetY) == "number" then
		-- Root-local Y only — keeps chrome centered under the avatar, not on one foot.
		local localY = root.CFrame:PointToObjectSpace(Vector3.new(root.Position.X, feetY, root.Position.Z)).Y
		return CFrame.new(0, localY, 0)
	end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local hip = if humanoid and humanoid.HipHeight > 0.5 then humanoid.HipHeight else 2
	return CFrame.new(0, -hip + FEET_LIFT, 0)
end

local function feetWorldCFrame(char: Model, root: BasePart): CFrame
	return root.CFrame * feetOffsetFromRoot(char, root)
end

function PlaceConfirmChrome.ensureAdornee(existing: BasePart?): BasePart?
	local char = player.Character
	if not char then
		return nil
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil
	end
	local offset = feetOffsetFromRoot(char, root)
	local part = existing
	if part and part.Parent == char then
		local weld = part:FindFirstChildOfClass("Weld")
		if weld and weld:IsA("Weld") and weld.Part0 == root and weld.Part1 == part then
			weld.C0 = offset
			weld.C1 = CFrame.new()
			return part
		end
		part:Destroy()
		part = nil
	elseif part then
		part:Destroy()
		part = nil
	end
	part = Instance.new("Part")
	part.Name = "OceanTD_PlaceChromeAdornee"
	part.Size = Vector3.new(0.15, 0.15, 0.15)
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Anchored = false
	part.CastShadow = false
	part.Parent = char
	local weld = Instance.new("Weld")
	weld.Part0 = root
	weld.Part1 = part
	weld.C0 = offset
	weld.C1 = CFrame.new()
	weld.Parent = part
	return part
end

-- IgnoreGuiInset + ScreenInsets.None → Position matches WorldToViewportPoint (viewport origin).
-- Do NOT use WorldToScreenPoint / TopbarInset here — that overshoots right on phones.
local function projectToGuiPos(cam: Camera, world: Vector3): Vector2?
	local sp, _onScreen = cam:WorldToViewportPoint(world)
	if sp.Z <= 0 then
		return nil
	end
	return Vector2.new(sp.X, sp.Y)
end

function PlaceConfirmChrome.screenPos(adornee: BasePart?): Vector2
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(800, 600)
	local fallback = Vector2.new(vp.X * 0.5, vp.Y - BTN_FALLBACK_BOTTOM_PAD)
	if not cam then
		return fallback
	end

	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and char then
		-- X from HRP (body center). Y from feet. Mixing them avoids perspective skew.
		local feetWorld = feetWorldCFrame(char, root).Position
		local rootPos = projectToGuiPos(cam, root.Position)
		local feetPos = projectToGuiPos(cam, Vector3.new(root.Position.X, feetWorld.Y, root.Position.Z))
		if rootPos and feetPos then
			return Vector2.new(rootPos.X, feetPos.Y)
		end
		if rootPos then
			return rootPos
		end
	end

	local world: Vector3? = if adornee then adornee.Position else nil
	if not world then
		return fallback
	end
	return projectToGuiPos(cam, world) or fallback
end

-- Cyan circle + provided rotate icons (left 96091927054382 / right 98172417849326).
function PlaceConfirmChrome.createRotateButton(parent: Instance, imageId: string, name: string): ImageButton
	local s = PlaceConfirmChrome.chromeBtnSize(BASE_BTN_PX)
	local b = Instance.new("ImageButton")
	b.Name = name
	b.Size = UDim2.fromOffset(s, s)
	b.BackgroundColor3 = ROT_BG
	b.BackgroundTransparency = 0
	b.Image = imageId
	b.ImageColor3 = Color3.new(1, 1, 1)
	b.ScaleType = Enum.ScaleType.Fit
	b.AutoButtonColor = true
	b.Visible = false
	-- Active so presses sink into the button and cannot fall through to world coral picks.
	b.Active = true
	b.ZIndex = 5
	b.Parent = parent
	UiCircles.ensure(b)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.18, 0)
	pad.PaddingBottom = UDim.new(0.18, 0)
	pad.PaddingLeft = UDim.new(0.18, 0)
	pad.PaddingRight = UDim.new(0.18, 0)
	pad.Parent = b
	local edge = Instance.new("UIStroke")
	edge.Name = "EdgeStroke"
	edge.Color = Color3.new(1, 1, 1)
	edge.Thickness = 2.5
	edge.Transparency = 1
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	edge.Parent = b
	local scale = Instance.new("UIScale")
	scale.Name = "PressScale"
	scale.Scale = 1
	scale.Parent = b
	return b
end

function PlaceConfirmChrome.playRotatePressFeedback(btn: GuiObject)
	local edge = btn:FindFirstChild("EdgeStroke")
	local scale = btn:FindFirstChild("PressScale")
	if edge and edge:IsA("UIStroke") then
		edge.Transparency = 0
		task.delay(0.5, function()
			if edge.Parent then
				TweenService:Create(edge, TweenInfo.new(0.15), { Transparency = 1 }):Play()
			end
		end)
	end
	if scale and scale:IsA("UIScale") then
		scale.Scale = 1
		local up = TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.18 })
		up:Play()
		up.Completed:Connect(function()
			if scale.Parent then
				TweenService:Create(scale, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			end
		end)
	end
	local s = Instance.new("Sound")
	s.SoundId = ROT_SOUND_ID
	s.Volume = 0.85
	s.Parent = SoundService
	s:Play()
	s.Ended:Connect(function()
		s:Destroy()
	end)
	task.delay(3, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

local ROT_HOLD_INTERVAL = 0.5
local rotHoldConn: RBXScriptConnection? = nil
local rotHoldToken = 0

function PlaceConfirmChrome.stopRotateHold()
	rotHoldToken += 1
	if rotHoldConn then
		rotHoldConn:Disconnect()
		rotHoldConn = nil
	end
end

-- Immediate step, then another every 0.5s while held. Call stopRotateHold on release.
function PlaceConfirmChrome.beginRotateHold(btn: GuiObject?, onStep: () -> ())
	-- Ignore duplicate start from both Gui MouseButton1Down and UIS InputBegan.
	if rotHoldConn then
		return
	end
	local token = rotHoldToken
	if btn then
		PlaceConfirmChrome.playRotatePressFeedback(btn)
	end
	onStep()
	local elapsed = 0
	rotHoldConn = RunService.Heartbeat:Connect(function(dt)
		if token ~= rotHoldToken then
			return
		end
		elapsed += dt
		while elapsed >= ROT_HOLD_INTERVAL do
			elapsed -= ROT_HOLD_INTERVAL
			if btn and btn.Parent then
				PlaceConfirmChrome.playRotatePressFeedback(btn)
			end
			onStep()
		end
	end)
end

local function placeChrome(
	origin: Vector2,
	s: number,
	gap: number,
	showCheck: boolean,
	showRot: boolean,
	checkBtn: GuiObject?,
	rotLeftBtn: GuiObject?,
	cancelBtn: GuiObject?,
	rotRightBtn: GuiObject?,
	useScale: boolean -- BillboardGui uses scale-centered coords
)
	--[[
		Close + rot stay fixed on the top row. Confirm parks below Close; only Visible toggles.
		Confirm is larger than Close — space centers so discs don't overlap.
	]]
	local checkS = math.max(math.floor(s * CONFIRM_BTN_SCALE + 0.5), s)
	local function setPos(btn: GuiObject, x: number, y: number, sizePx: number, visible: boolean?)
		btn.AnchorPoint = Vector2.new(0.5, 0.5)
		btn.Size = UDim2.fromOffset(sizePx, sizePx)
		if useScale then
			btn.Position = UDim2.new(0.5, x, 0.5, y)
		else
			btn.Position = UDim2.fromOffset(origin.X + x, origin.Y + y)
		end
		if visible ~= nil then
			btn.Visible = visible
		else
			btn.Visible = true
		end
	end

	if not showRot then
		if rotLeftBtn then
			rotLeftBtn.Visible = false
		end
		if rotRightBtn then
			rotRightBtn.Visible = false
		end
	end

	local rowGap = math.max(math.floor(s * 0.35 + 0.5), 10)
	local topY = 0
	local confirmY = checkS * 0.5 + s * 0.5 + rowGap

	if showRot and cancelBtn and rotLeftBtn and rotRightBtn then
		setPos(rotLeftBtn, -(s + gap), topY, s)
		setPos(cancelBtn, 0, topY, s)
		setPos(rotRightBtn, (s + gap), topY, s)
		if checkBtn then
			setPos(checkBtn, 0, confirmY, checkS, showCheck)
		end
		return
	end

	if cancelBtn then
		setPos(cancelBtn, 0, topY, s)
	end
	if checkBtn then
		setPos(checkBtn, 0, confirmY, checkS, showCheck)
	end
end

function PlaceConfirmChrome.layoutAt(
	chrome: Vector2,
	btnSize: number,
	confirmGui: ScreenGui?,
	chromeBillboard: BillboardGui?,
	checkBtn: TextButton?,
	cancelBtn: TextButton?,
	rotLeftBtn: GuiObject?,
	rotRightBtn: GuiObject?,
	showRot: boolean?
)
	local s = btnSize
	local gap = 6
	if not confirmGui then
		return
	end
	if chromeBillboard then
		chromeBillboard.Enabled = false
	end
	local showCheck = checkBtn ~= nil and checkBtn.Visible
	local doRot = showRot == true and rotLeftBtn ~= nil and rotRightBtn ~= nil
	local function parentToGui(btn: GuiObject?)
		if btn and btn.Parent ~= confirmGui then
			btn.Parent = confirmGui
		end
	end
	parentToGui(checkBtn)
	parentToGui(cancelBtn)
	parentToGui(rotLeftBtn)
	parentToGui(rotRightBtn)
	placeChrome(chrome, s, gap, showCheck, doRot, checkBtn, rotLeftBtn, cancelBtn, rotRightBtn, false)
end

function PlaceConfirmChrome.layoutOnTorso(
	btnSize: number,
	playerGui: PlayerGui,
	confirmGui: ScreenGui?,
	chromeBillboard: BillboardGui?,
	chromeAdornee: BasePart?,
	checkBtn: TextButton?,
	cancelBtn: TextButton?,
	rotLeftBtn: GuiObject?,
	rotRightBtn: GuiObject?,
	showRot: boolean?
): (BillboardGui?, BasePart?)
	local s = PlaceConfirmChrome.chromeBtnSize(btnSize)
	local doRot = showRot == true and rotLeftBtn ~= nil and rotRightBtn ~= nil
	local adornee = PlaceConfirmChrome.ensureAdornee(chromeAdornee)

	-- Always ScreenGui: Billboard AbsolutePosition / hit tests are unreliable (clicks land
	-- below the visible disc). Screen-space buttons behave like normal GuiButtons.
	if chromeBillboard then
		chromeBillboard.Enabled = false
	end
	if not adornee or not confirmGui then
		return chromeBillboard, adornee
	end
	PlaceConfirmChrome.layoutAt(
		PlaceConfirmChrome.screenPos(adornee),
		s,
		confirmGui,
		chromeBillboard,
		checkBtn,
		cancelBtn,
		rotLeftBtn,
		rotRightBtn,
		doRot
	)
	return chromeBillboard, adornee
end

PlaceConfirmChrome.ROT_LEFT_ICON = ROT_LEFT_ICON
PlaceConfirmChrome.ROT_RIGHT_ICON = ROT_RIGHT_ICON
PlaceConfirmChrome.BASE_BTN_PX = BASE_BTN_PX

return PlaceConfirmChrome
