--!strict
--[[
	Torso-locked ✓/X (+ optional SeaFan rotate) layout helpers for PlacementController.
	Extracted so PlacementController stays under Luau's 200-local limit.
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UiCircles = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("UiCircles"))

local player = Players.LocalPlayer

local PlaceConfirmChrome = {}

local BTN_FALLBACK_BOTTOM_PAD = 28
-- HRP is at the waist; keep ✓/X on the belt line (was 1.35 ≈ chest/head).
local BELT_OFFSET = CFrame.new(0, -0.35, 0)
-- Never smaller than this on screen (freecam / zoomed-out cameras).
local MIN_BTN_PX = 52
-- Beyond this distance, pin to screen space so Offset billboards can't go unreadably small.
local SCREEN_LAYOUT_DIST = 28

local ROT_BG = Color3.fromRGB(0, 162, 237) -- #00a2ed
local ROT_SOUND_ID = "rbxassetid://139911414972673"
local ROT_LEFT_ICON = "rbxassetid://96091927054382"
local ROT_RIGHT_ICON = "rbxassetid://98172417849326"

function PlaceConfirmChrome.ensureAdornee(existing: BasePart?): BasePart?
	local char = player.Character
	if not char then
		return nil
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil
	end
	local part = existing
	if part and part.Parent == char then
		local weld = part:FindFirstChildOfClass("Weld")
		if weld and weld:IsA("Weld") and weld.Part0 == root and weld.Part1 == part then
			weld.C0 = BELT_OFFSET
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
	weld.C0 = BELT_OFFSET
	weld.C1 = CFrame.new()
	weld.Parent = part
	return part
end

function PlaceConfirmChrome.screenPos(adornee: BasePart?): Vector2
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(800, 600)
	local inset = GuiService:GetGuiInset()
	local fallback = Vector2.new(vp.X * 0.5 + inset.X, vp.Y - BTN_FALLBACK_BOTTOM_PAD)
	if not cam then
		return fallback
	end
	local world: Vector3? = if adornee then adornee.Position else nil
	if not world then
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			world = (root.CFrame * BELT_OFFSET).Position
		else
			return fallback
		end
	end
	local sp, onScreen = cam:WorldToScreenPoint(world)
	if not onScreen or sp.Z <= 0 then
		return fallback
	end
	return Vector2.new(sp.X, sp.Y)
end

-- Cyan circle + provided rotate icons (left 96091927054382 / right 98172417849326).
function PlaceConfirmChrome.createRotateButton(parent: Instance, imageId: string, name: string): ImageButton
	local b = Instance.new("ImageButton")
	b.Name = name
	b.Size = UDim2.fromOffset(MIN_BTN_PX, MIN_BTN_PX)
	b.BackgroundColor3 = ROT_BG
	b.BackgroundTransparency = 0
	b.Image = imageId
	b.ImageColor3 = Color3.new(1, 1, 1)
	b.ScaleType = Enum.ScaleType.Fit
	b.AutoButtonColor = true
	b.Visible = false
	-- Active so presses sink into the button and cannot fall through to world coral picks.
	-- Confirm stacks above Close; Y-band hit test still prefers Confirm when overlapping.
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
		Close + rot stay fixed. Confirm is always parked above Close; only Visible toggles.
	]]
	local function setPos(btn: GuiObject, x: number, y: number, visible: boolean?)
		btn.AnchorPoint = Vector2.new(0.5, 0.5)
		btn.Size = UDim2.fromOffset(s, s)
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
	local botY = 0
	local topY = -(s + rowGap)

	if showRot and cancelBtn and rotLeftBtn and rotRightBtn then
		setPos(rotLeftBtn, -(s + gap), botY)
		setPos(cancelBtn, 0, botY)
		setPos(rotRightBtn, (s + gap), botY)
		if checkBtn then
			-- Always park Enter above Close; reveal only (never rebuild offsets).
			setPos(checkBtn, 0, topY, showCheck)
		end
		return
	end

	if cancelBtn then
		setPos(cancelBtn, 0, botY)
	end
	if checkBtn then
		setPos(checkBtn, 0, topY, showCheck)
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
	_playerGui: PlayerGui,
	confirmGui: ScreenGui?,
	chromeBillboard: BillboardGui?,
	chromeAdornee: BasePart?,
	checkBtn: TextButton?,
	cancelBtn: TextButton?,
	rotLeftBtn: GuiObject?,
	rotRightBtn: GuiObject?,
	showRot: boolean?
): (BillboardGui?, BasePart?)
	local s = math.max(btnSize, MIN_BTN_PX)
	local doRot = showRot == true and rotLeftBtn ~= nil and rotRightBtn ~= nil
	local adornee = PlaceConfirmChrome.ensureAdornee(chromeAdornee)

	-- One stable path: always screen-space at the waist. Never swap Billboard↔Screen
	-- when Enter appears (that jump moved Close/rot). Enter is only Visibility.
	if chromeBillboard then
		chromeBillboard.Enabled = false
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

return PlaceConfirmChrome
