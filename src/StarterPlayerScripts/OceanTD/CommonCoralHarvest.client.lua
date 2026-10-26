--!strict
--[[
	Hold to harvest a common coral in follow cam (11 studs) or free cam.
	Species sits left of the type circle. Rarity sits right of the hue circle.
	The hue-colored progress bar appears once the hold starts, with HOLD and the button under it.
	Gamepad shows HOLD beside the button-sheet icon.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local HueRarity = require(oceanRoot:WaitForChild("Shared"):WaitForChild("HueRarity"))
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local SeedWheel = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SeedWheel"))
local GamepadButtonGlyph = require(oceanRoot:WaitForChild("Shared"):WaitForChild("GamepadButtonGlyph"))
local AudioSettings = require(oceanRoot:WaitForChild("Shared"):WaitForChild("AudioSettings"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiViewportTags = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiViewportTags"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local JoinIntroGate = require(script.Parent:WaitForChild("JoinIntroGate"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local PlantWorkerVfx = require(script.Parent:WaitForChild("PlantWorkerVfx"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local RANGE = 11
local HOLD_SEC = 3
local PAINTBRUSH_ICON = "rbxassetid://81636797566300"
local HUE_OF_CORAL = 0.9
local HUE_SHIFT = 1.05

local COIN_SOUND_ID = "rbxassetid://138571475125488"
local coinSound = Instance.new("Sound")
coinSound.Name = "OceanTD_HarvestCoin"
coinSound.SoundId = COIN_SOUND_ID
coinSound.Volume = 0.9
coinSound.Parent = SoundService
AudioSettings.init()
AudioSettings.markPrioritySfx(coinSound)

local function playHarvestCoin()
	local s = coinSound:Clone()
	s.TimePosition = 0
	s.Parent = SoundService
	AudioSettings.markPrioritySfx(s)
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
	task.delay(4, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

type Mode = "idle" | "show" | "arming" | "hold" | "claim" | "present"

local mode: Mode = "idle"
local target: BasePart? = nil
local keyDown = false
local pointerDown = false
local holdPointer: InputObject? = nil
local holdStart = 0
local holdGen = 0
local savedWalk = 16
local savedJump = 50
local lockedHum: Humanoid? = nil
local presentToken = 0

local gui = Instance.new("ScreenGui")
gui.Name = "OceanTD_CommonHarvest"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 80
gui.Enabled = false
gui.Parent = playerGui

local root = Instance.new("TextButton")
root.Name = "Card"
root.BackgroundTransparency = 1
root.BorderSizePixel = 0
root.AnchorPoint = Vector2.new(0.5, 0)
root.AutomaticSize = Enum.AutomaticSize.XY
root.Size = UDim2.fromOffset(0, 0)
root.Text = ""
root.AutoButtonColor = false
root.Active = true
root.Parent = gui

local rootScale = Instance.new("UIScale")
rootScale.Scale = 1
rootScale.Parent = root

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 4)
layout.Parent = root

local topRow = Instance.new("Frame")
topRow.Name = "Top"
topRow.BackgroundTransparency = 1
topRow.BorderSizePixel = 0
topRow.AutomaticSize = Enum.AutomaticSize.XY
topRow.Size = UDim2.fromOffset(0, 0)
topRow.LayoutOrder = 1
topRow.Parent = root
local topLayout = Instance.new("UIListLayout")
topLayout.FillDirection = Enum.FillDirection.Horizontal
topLayout.VerticalAlignment = Enum.VerticalAlignment.Center
topLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
topLayout.SortOrder = Enum.SortOrder.LayoutOrder
topLayout.Padding = UDim.new(0, 8)
topLayout.Parent = topRow

local pair = Instance.new("Frame")
pair.Name = "Pair"
pair.BackgroundTransparency = 1
pair.BorderSizePixel = 0
pair.LayoutOrder = 2
pair.Parent = topRow

local function px(n: number): number
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	return math.max(1, math.floor(n * UiViewportTags.wideUiScale(vp) + 0.5))
end

local function round(parent: Instance)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = parent
end

local function brighten(color: Color3): Color3
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, math.clamp(s * 0.8, 0, 1), math.clamp(v + (1 - v) * 0.55 + 0.12, 0, 1))
end

local function stroke(parent: Instance, color: Color3, thickness: number, transparency: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = parent
	return s
end

local function label(name: string, order: number, textSize: number, color: Color3, outline: Color3): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.Name = name
	lbl.BackgroundTransparency = 1
	lbl.BorderSizePixel = 0
	lbl.AutomaticSize = Enum.AutomaticSize.XY
	lbl.Size = UDim2.fromOffset(0, 0)
	lbl.Font = UiTheme.Font
	lbl.TextSize = textSize
	lbl.TextColor3 = color
	lbl.Text = ""
	lbl.LayoutOrder = order
	lbl.Parent = root
	stroke(lbl, outline, 1.5, 0)
	return lbl
end

local nameLabel = label("Species", 1, 24, Color3.new(1, 1, 1), Color3.fromRGB(52, 52, 58))
local rarityLabel = label("Rarity", 3, 15, Color3.fromRGB(240, 255, 245), Color3.fromRGB(0, 40, 20))
local oddsLabel = label("Odds", 4, 16, Color3.new(1, 1, 1), Color3.new(0, 0, 0))
nameLabel.Parent = topRow
rarityLabel.Parent = topRow
nameLabel.LayoutOrder = 1
rarityLabel.LayoutOrder = 3
nameLabel.TextXAlignment = Enum.TextXAlignment.Right
rarityLabel.TextXAlignment = Enum.TextXAlignment.Left
oddsLabel.Visible = false

local holdRow = Instance.new("Frame")
holdRow.Name = "HoldRow"
holdRow.BackgroundTransparency = 1
holdRow.BorderSizePixel = 0
holdRow.AutomaticSize = Enum.AutomaticSize.XY
holdRow.Size = UDim2.fromOffset(0, 0)
holdRow.LayoutOrder = 3
holdRow.Parent = root
local holdLayout = Instance.new("UIListLayout")
holdLayout.FillDirection = Enum.FillDirection.Horizontal
holdLayout.VerticalAlignment = Enum.VerticalAlignment.Center
holdLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
holdLayout.SortOrder = Enum.SortOrder.LayoutOrder
holdLayout.Padding = UDim.new(0, 8)
holdLayout.Parent = holdRow

local holdWord = Instance.new("TextLabel")
holdWord.Name = "HoldWord"
holdWord.BackgroundTransparency = 1
holdWord.BorderSizePixel = 0
holdWord.AutomaticSize = Enum.AutomaticSize.XY
holdWord.Size = UDim2.fromOffset(0, 0)
holdWord.Font = UiTheme.Font
holdWord.TextSize = 28
holdWord.TextColor3 = Color3.fromRGB(230, 245, 255)
holdWord.Text = "HOLD E"
holdWord.LayoutOrder = 1
holdWord.Parent = holdRow
stroke(holdWord, Color3.fromRGB(20, 40, 55), 1.5, 0)

local padHost = Instance.new("TextLabel")
padHost.Name = "Pad"
padHost.BackgroundTransparency = 1
padHost.BorderSizePixel = 0
padHost.Size = UDim2.fromOffset(36, 36)
padHost.Font = UiTheme.Font
padHost.Text = "B"
padHost.TextTransparency = 1
padHost.TextSize = 28
padHost.LayoutOrder = 2
padHost.Visible = false
padHost.Parent = holdRow
padHost:SetAttribute("_OceanTD_PadScaleMul", 1.15)
GamepadButtonGlyph.apply(padHost)

local barBack = Instance.new("Frame")
barBack.Name = "HoldBar"
barBack.BackgroundColor3 = Color3.fromRGB(20, 30, 40)
barBack.BackgroundTransparency = 0.25
barBack.BorderSizePixel = 0
barBack.Size = UDim2.fromOffset(120, 8)
barBack.LayoutOrder = 2
barBack.Visible = false
barBack.Parent = root
round(barBack)
local barFill = Instance.new("Frame")
barFill.Name = "Fill"
barFill.BackgroundColor3 = Color3.fromRGB(90, 210, 140)
barFill.BorderSizePixel = 0
barFill.Size = UDim2.fromScale(0, 1)
barFill.Parent = barBack
round(barFill)

local function matchBarWidth()
	local scale = rootScale.Scale
	if scale < 0.05 then
		scale = 1
	end
	local w = topRow.AbsoluteSize.X / scale
	if w > 8 then
		barBack.Size = UDim2.fromOffset(math.floor(w + 0.5), px(10))
	end
end
topRow:GetPropertyChangedSignal("AbsoluteSize"):Connect(matchBarWidth)

local function rebuildCircles(itemId: string, hueIndex: number)
	pair:ClearAllChildren()
	local coralPx = px(52)
	local huePx = math.floor(coralPx * HUE_OF_CORAL + 0.5)
	local bias = math.floor(huePx * HUE_SHIFT + 0.5)
	local width = math.floor(coralPx * 0.5 + bias + huePx * 0.5 + 0.5)
	local height = math.max(coralPx, huePx)
	local color = SeedWheel.colorForIndex(hueIndex)
	pair.Size = UDim2.fromOffset(width, height)
	barBack.Size = UDim2.fromOffset(math.max(px(140), width), px(10))
	barFill.BackgroundColor3 = color

	local hue = Instance.new("Frame")
	hue.Name = "ColorCircle"
	hue.AnchorPoint = Vector2.new(0.5, 0.5)
	hue.Position = UDim2.fromOffset(coralPx * 0.5 + bias, height * 0.5)
	hue.Size = UDim2.fromOffset(huePx, huePx)
	hue.BackgroundColor3 = color
	hue.BorderSizePixel = 0
	hue.ZIndex = 2
	hue.Parent = pair
	round(hue)
	stroke(hue, brighten(color), 2, 0.15)

	local ring = Instance.new("Frame")
	ring.Name = "HueCenterStroke"
	ring.BackgroundTransparency = 1
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = hue.Position
	ring.Size = UDim2.fromOffset(huePx, huePx)
	ring.ZIndex = 4
	ring.Parent = pair
	round(ring)
	local ringStroke = stroke(ring, Color3.new(1, 1, 1), UiViewportTags.coralSpinnerStrokeThickness() + 2, 0)
	ringStroke.BorderStrokePosition = Enum.BorderStrokePosition.Outer

	local brush = Instance.new("ImageLabel")
	brush.Name = "HuePaintbrush"
	brush.BackgroundTransparency = 1
	brush.AnchorPoint = Vector2.new(0.5, 0.5)
	brush.Position = hue.Position
	local brushPx = math.floor(huePx * 0.72 + 0.5)
	brush.Size = UDim2.fromOffset(brushPx, brushPx)
	brush.Image = PAINTBRUSH_ICON
	brush.ScaleType = Enum.ScaleType.Fit
	brush.ZIndex = 5
	brush.Parent = pair

	local def = ItemCatalog.get(itemId)
	local icon = if def then def.icon else ""
	local coral = Instance.new("ImageLabel")
	coral.Name = "SeedCircle"
	coral.BackgroundTransparency = 1
	coral.AnchorPoint = Vector2.new(0.5, 0.5)
	coral.Position = UDim2.fromOffset(coralPx * 0.5, height * 0.5)
	coral.Size = UDim2.fromOffset(coralPx, coralPx)
	coral.Image = icon
	coral.ScaleType = Enum.ScaleType.Fit
	coral.ZIndex = 6
	coral.Parent = pair
	round(coral)
	local inner = Instance.new("Frame")
	inner.Name = "InnerRing"
	inner.BackgroundTransparency = 1
	inner.AnchorPoint = Vector2.new(0.5, 0.5)
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.Size = UDim2.new(1, -3, 1, -3)
	inner.ZIndex = 7
	inner.Parent = coral
	round(inner)
	stroke(inner, Color3.new(1, 1, 1), UiViewportTags.coralSpinnerStrokeThickness(), 0.5)

	nameLabel.Text = if def then def.displayName else itemId
	nameLabel.TextSize = px(22)
	nameLabel.TextTransparency = 0
	nameLabel.Visible = true
	rarityLabel.Text = HueRarity.className(itemId, hueIndex) or ""
	rarityLabel.TextSize = px(16)
	rarityLabel.TextTransparency = 0
	rarityLabel.Visible = true
	local nameStroke = nameLabel:FindFirstChildOfClass("UIStroke")
	local rarityStroke = rarityLabel:FindFirstChildOfClass("UIStroke")
	if nameStroke then
		nameStroke.Transparency = 0
	end
	if rarityStroke then
		rarityStroke.Transparency = 0
	end
end

local function showPromptText(lbl: TextLabel)
	lbl.TextTransparency = 0
	lbl.TextStrokeTransparency = 1
	local outline = lbl:FindFirstChildOfClass("UIStroke")
	if outline then
		outline.Transparency = 0
		outline.Enabled = true
	end
end

local function refreshHoldHint()
	local last = UserInputService:GetLastInputType()
	local gamepad = string.sub(last.Name, 1, 7) == "Gamepad"
	holdWord.TextSize = px(30)
	showPromptText(holdWord)
	padHost.Size = UDim2.fromOffset(px(34), px(34))
	if gamepad then
		holdWord.Text = "HOLD"
		padHost.Visible = true
		padHost.Text = "B"
		GamepadButtonGlyph.apply(padHost)
		return
	end
	padHost.Visible = false
	if last == Enum.UserInputType.Touch then
		holdWord.Text = "HOLD"
	else
		holdWord.Text = "HOLD E"
	end
end

local function harvestAllowed(): boolean
	if JoinIntroGate.isBusy() then
		return false
	end
	if playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true then
		return false
	end
	if playerGui:GetAttribute("OceanTD_PlantWorkerBusy") == true or playerGui:GetAttribute("OceanTD_PlantDigCamBusy") == true then
		return false
	end
	if WaveSim.isRunning() then
		return false
	end
	if InventoryState.isOpen() or InventoryState.isBuildModalBlocking() then
		return false
	end
	if PlacementController.isActive() or RelocateController.isActive() then
		return false
	end
	local camMode = playerGui:GetAttribute("OceanTD_CamCycleMode")
	if camMode == nil or camMode == "off" or camMode == "" or camMode == "dronecam" then
		return true
	end
	return false
end

local function isFreeCam(): boolean
	return playerGui:GetAttribute("OceanTD_CamCycleMode") == "dronecam"
end

local function hrp(): BasePart?
	local char = player.Character
	local part = char and char:FindFirstChild("HumanoidRootPart")
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

local function plantPos(part: BasePart): Vector3
	local stamped = part:GetAttribute("OceanTD_PlantPos")
	if typeof(stamped) == "Vector3" then
		return stamped
	end
	return part.Position
end

local function readHarvest(part: BasePart): (string?, number?)
	local itemId = part:GetAttribute("OceanTD_ItemId")
	if typeof(itemId) ~= "string" or itemId == "" then
		itemId = part:GetAttribute("OceanTD_SpeciesId")
	end
	local hue = part:GetAttribute("OceanTD_HueIndex")
	if typeof(itemId) ~= "string" or typeof(hue) ~= "number" then
		return nil, nil
	end
	return itemId, math.clamp(math.floor(hue), 1, 14)
end

local function nearestCoral(): BasePart?
	local folder = Workspace:FindFirstChild("OceanTD_CommonGrow")
	if not folder then
		return nil
	end
	if isFreeCam() then
		local cam = Workspace.CurrentCamera
		if not cam then
			return nil
		end
		local origin = cam.CFrame.Position
		local look = cam.CFrame.LookVector
		local best: BasePart? = nil
		local bestDot = 0.9
		for _, d in ipairs(folder:GetDescendants()) do
			if d:IsA("BasePart") and d:GetAttribute("OceanTD_CommonGrow") == true and typeof(d:GetAttribute("OceanTD_HarvestKey")) == "string" then
				local to = plantPos(d) - origin
				local dist = to.Magnitude
				if dist <= 28 and dist > 1 then
					local dot = look:Dot(to.Unit)
					if dot > bestDot then
						bestDot = dot
						best = d
					end
				end
			end
		end
		return best
	end
	local rootPart = hrp()
	if not rootPart then
		return nil
	end
	local best: BasePart? = nil
	local bestD = RANGE
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("OceanTD_CommonGrow") == true and typeof(d:GetAttribute("OceanTD_HarvestKey")) == "string" then
			local dist = (d.Position - rootPart.Position).Magnitude
			if dist <= bestD then
				bestD = dist
				best = d
			end
		end
	end
	return best
end

local function screenOf(world: Vector3): (Vector2?, boolean)
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil, false
	end
	local v, onScreen = cam:WorldToViewportPoint(world)
	return Vector2.new(v.X, v.Y), onScreen and v.Z > 0
end

local function hideCard()
	gui.Enabled = false
	barBack.Visible = false
	barFill.Size = UDim2.fromScale(0, 1)
	rootScale.Scale = 0.5
	root.AnchorPoint = Vector2.new(0.5, 0)
	holdRow.Visible = true
	showPromptText(holdWord)
	showPromptText(nameLabel)
	showPromptText(rarityLabel)
	playerGui:SetAttribute("OceanTD_CommonHarvestPrompt", false)
end

local function unlockMove()
	local hum = lockedHum
	lockedHum = nil
	if hum and hum.Parent then
		hum.WalkSpeed = savedWalk
		hum.JumpHeight = savedJump
	end
end

local function lockMove()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	lockedHum = hum
	savedWalk = hum.WalkSpeed
	savedJump = hum.JumpHeight
	hum.WalkSpeed = 0
	hum.JumpHeight = 0
	local rootPart = hrp()
	local aim = if target then plantPos(target) else nil
	if rootPart and aim then
		local flat = Vector3.new(aim.X - rootPart.Position.X, 0, aim.Z - rootPart.Position.Z)
		if flat.Magnitude > 0.2 then
			rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + flat.Unit)
		end
	end
end

local origins: { [BasePart]: CFrame } = {}
local savedCollide: { [BasePart]: boolean } = {}
local dropStuds = 4
local holdAnchor: Vector3? = nil
local HOLD_LEASH = 18

local function restoreCollide()
	for part, was in pairs(savedCollide) do
		if part.Parent then
			part.CanCollide = was
		end
	end
	table.clear(savedCollide)
end

local function captureOrigins(part: BasePart)
	table.clear(origins)
	restoreCollide()
	origins[part] = part.CFrame
	savedCollide[part] = part.CanCollide
	part.CanCollide = false
	dropStuds = part.Size.Y + 1.5
	for _, d in ipairs(part:GetDescendants()) do
		if d:IsA("BasePart") then
			origins[d] = d.CFrame
			savedCollide[d] = d.CanCollide
			d.CanCollide = false
			dropStuds = math.max(dropStuds, d.Size.Y + 1.5)
		end
	end
end

local function applyDrop(alpha: number)
	local dy = -dropStuds * math.clamp(alpha, 0, 1)
	for part, cf in pairs(origins) do
		if part.Parent then
			part.CFrame = cf + Vector3.new(0, dy, 0)
		end
	end
end

local useTrip = false
local digAlpha = -1
local cardFrom = Vector2.zero
local holdLatched = false
local PROMPT_SCALE = 0.5
local HOLD_SCALE = 1.25

local function cardCenter(): Vector2
	return root.AbsolutePosition + root.AbsoluteSize * 0.5
end

local function screenCenter(): Vector2
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	return Vector2.new(vp.X * 0.5, vp.Y * 0.5)
end

local function coralScreenOffset(): number
	local coral = pair:FindFirstChild("SeedCircle")
	if not coral or not coral:IsA("GuiObject") or coral.AbsoluteSize.X < 2 then
		return 0
	end
	local coralCenter = coral.AbsolutePosition.X + coral.AbsoluteSize.X * 0.5
	local rootCenter = root.AbsolutePosition.X + root.AbsoluteSize.X * 0.5
	return coralCenter - rootCenter
end

local function placeBelow(part: BasePart)
	local spot, onScreen = screenOf(plantPos(part))
	if not spot or not onScreen then
		gui.Enabled = false
		playerGui:SetAttribute("OceanTD_CommonHarvestPrompt", false)
		return
	end
	gui.Enabled = true
	barBack.Visible = false
	root.AnchorPoint = Vector2.new(0.5, 0)
	rootScale.Scale = PROMPT_SCALE
	root.Position = UDim2.fromOffset(spot.X - coralScreenOffset(), spot.Y + px(12))
	refreshHoldHint()
	playerGui:SetAttribute("OceanTD_CommonHarvestPrompt", true)
end

local function placeHold(alpha: number)
	local p = cardFrom:Lerp(screenCenter(), math.clamp(alpha, 0, 1))
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromOffset(p.X, p.Y)
	rootScale.Scale = PROMPT_SCALE + (HOLD_SCALE - PROMPT_SCALE) * math.clamp(alpha, 0, 1)
	barBack.Visible = true
end

local function cancelHold(restore: boolean)
	if mode ~= "hold" then
		return
	end
	mode = "show"
	pcall(function()
		Remotes.get("CommonHarvestCancel"):FireServer(holdGen)
	end)
	if useTrip then
		PlantWorkerVfx.cancelHarvestTrip()
		useTrip = false
		digAlpha = -1
		holdLatched = false
	else
		PlantWorkerVfx.endInPlaceDig()
	end
	unlockMove()
	if restore then
		applyDrop(0)
	end
	restoreCollide()
	holdAnchor = nil
	table.clear(origins)
	barBack.Visible = false
	barFill.Size = UDim2.fromScale(0, 1)
end

local function backpackPoint(): Vector2?
	local c = InventoryState.getBackpackButtonScreenCenter(true)
	if not c then
		return nil
	end
	local inset = GuiService:GetGuiInset()
	return Vector2.new(c.X + inset.X, c.Y + inset.Y)
end

local function playPresent()
	presentToken += 1
	local token = presentToken
	mode = "present"
	gui.Enabled = true
	holdRow.Visible = false
	barBack.Visible = false
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local center = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
	root.Position = UDim2.fromOffset(center.X, center.Y)
	local function scaleTo(fromS: number, toS: number, sec: number): boolean
		local t0 = os.clock()
		while presentToken == token and os.clock() - t0 < sec do
			local u = (os.clock() - t0) / sec
			rootScale.Scale = fromS + (toS - fromS) * u
			RunService.Heartbeat:Wait()
		end
		if presentToken ~= token then
			return false
		end
		rootScale.Scale = toS
		return true
	end
	if not scaleTo(HOLD_SCALE, 1.5, 0.14) then
		return
	end
	if not scaleTo(1.5, 1, 0.18) then
		return
	end
	local dest = backpackPoint() or Vector2.new(vp.X - 80, vp.Y - 80)
	local hueCircle = pair:FindFirstChild("ColorCircle")
	local hueRing = pair:FindFirstChild("HueCenterStroke")
	local hueBrush = pair:FindFirstChild("HuePaintbrush")
	local coralCircle = pair:FindFirstChild("SeedCircle")
	local flown: { GuiObject } = {}
	local burst: { GuiObject } = {}
	local coralStart: Vector2? = nil
	local hueStart: Vector2? = nil
	local coralPxSize = 0
	local huePxSize = 0
	local brushPxSize = 0
	local hueColor = Color3.fromRGB(90, 210, 140)
	local function screenCenterOf(obj: GuiObject): Vector2
		return obj.AbsolutePosition + obj.AbsoluteSize * 0.5
	end
	local function lift(obj: Instance?)
		if obj and obj:IsA("GuiObject") then
			table.insert(flown, obj)
		end
	end
	lift(hueCircle)
	lift(hueRing)
	lift(hueBrush)
	lift(coralCircle)
	if hueCircle and hueCircle:IsA("GuiObject") then
		hueColor = hueCircle.BackgroundColor3
	end
	if coralCircle and coralCircle:IsA("GuiObject") and hueCircle and hueCircle:IsA("GuiObject") then
		coralStart = screenCenterOf(coralCircle)
		hueStart = screenCenterOf(hueCircle)
		coralPxSize = coralCircle.AbsoluteSize.X
		huePxSize = hueCircle.AbsoluteSize.X
		if hueBrush and hueBrush:IsA("GuiObject") then
			brushPxSize = hueBrush.AbsoluteSize.X
		end
		for _, obj in ipairs(flown) do
			obj.Parent = gui
			obj.AnchorPoint = Vector2.new(0.5, 0.5)
			obj.ZIndex = 30
		end
		coralCircle.Position = UDim2.fromOffset(coralStart.X, coralStart.Y)
		hueCircle.Position = UDim2.fromOffset(hueStart.X, hueStart.Y)
		if hueRing and hueRing:IsA("GuiObject") then
			hueRing.Position = hueCircle.Position
		end
		if hueBrush and hueBrush:IsA("GuiObject") then
			hueBrush.Position = hueCircle.Position
		end
		pair.Visible = false
	end
	local textLabels = { nameLabel, rarityLabel, holdWord }
	local function fadeText(alpha: number)
		local invis = math.clamp(alpha, 0, 1)
		for _, lbl in ipairs(textLabels) do
			lbl.TextTransparency = invis
			local outline = lbl:FindFirstChildOfClass("UIStroke")
			if outline then
				outline.Transparency = invis
			end
		end
	end
	local function dropFlown()
		for _, obj in ipairs(flown) do
			if obj.Parent then
				obj:Destroy()
			end
		end
		for _, obj in ipairs(burst) do
			if obj.Parent then
				obj:Destroy()
			end
		end
		table.clear(flown)
		table.clear(burst)
		pair.Visible = true
	end
	local function park(obj: GuiObject?, at: Vector2, sizePx: number)
		if not obj then
			return
		end
		obj.Position = UDim2.fromOffset(at.X, at.Y)
		local side = math.max(1, math.floor(sizePx + 0.5))
		obj.Size = UDim2.fromOffset(side, side)
	end
	local meet = if coralStart and hueStart then coralStart:Lerp(hueStart, 0.5) else center
	local mergeSec = 0.18
	local merge0 = os.clock()
	while presentToken == token and os.clock() - merge0 < mergeSec do
		local u = (os.clock() - merge0) / mergeSec
		local eased = 1 - (1 - u) * (1 - u) * (1 - u)
		root.Position = UDim2.fromOffset(center.X, center.Y)
		fadeText(eased)
		if coralStart and hueStart then
			local coralAt = coralStart:Lerp(meet, eased)
			local hueAt = hueStart:Lerp(meet, eased)
			if coralCircle and coralCircle:IsA("GuiObject") then
				park(coralCircle, coralAt, coralPxSize)
			end
			if hueCircle and hueCircle:IsA("GuiObject") then
				park(hueCircle, hueAt, huePxSize)
			end
			if hueRing and hueRing:IsA("GuiObject") then
				park(hueRing, hueAt, huePxSize)
			end
			if hueBrush and hueBrush:IsA("GuiObject") then
				park(hueBrush, hueAt, if brushPxSize > 1 then brushPxSize else huePxSize * 0.72)
			end
		end
		RunService.Heartbeat:Wait()
	end
	fadeText(1)
	if coralCircle and coralCircle:IsA("GuiObject") then
		park(coralCircle, meet, coralPxSize)
	end
	if hueCircle and hueCircle:IsA("GuiObject") then
		park(hueCircle, meet, huePxSize)
	end
	if hueRing and hueRing:IsA("GuiObject") then
		park(hueRing, meet, huePxSize)
	end
	if hueBrush and hueBrush:IsA("GuiObject") then
		park(hueBrush, meet, if brushPxSize > 1 then brushPxSize else huePxSize * 0.72)
	end
	playHarvestCoin()
	local rng = Random.new()
	local burstPieces: { { part: Frame, goal: Vector2, size: number } } = {}
	for i = 1, 16 do
		local dot = Instance.new("Frame")
		dot.Name = "Burst"
		dot.BackgroundColor3 = hueColor
		dot.BorderSizePixel = 0
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromOffset(meet.X, meet.Y)
		local size = rng:NextInteger(8, 54)
		dot.Size = UDim2.fromOffset(size, size)
		dot.ZIndex = 22
		dot.Parent = gui
		round(dot)
		local edge = stroke(dot, brighten(hueColor), 1.5, 0.15)
		edge.BorderStrokePosition = Enum.BorderStrokePosition.Outer
		table.insert(burst, dot)
		local angle = (i / 16) * math.pi * 2 + rng:NextNumber(-0.35, 0.35)
		local dist = rng:NextNumber(64, 210)
		table.insert(burstPieces, {
			part = dot,
			goal = meet + Vector2.new(math.cos(angle) * dist, math.sin(angle) * dist),
			size = size,
		})
	end
	local flySec = 0.7
	local burstSec = 0.5
	local fly0 = os.clock()
	while presentToken == token and os.clock() - fly0 < math.max(flySec, burstSec) do
		local elapsed = os.clock() - fly0
		local flyU = math.clamp(elapsed / flySec, 0, 1)
		local flyEased = 1 - (1 - flyU) * (1 - flyU) * (1 - flyU)
		local burstU = math.clamp(elapsed / burstSec, 0, 1)
		local burstEased = 1 - (1 - burstU) * (1 - burstU)
		local cardAt = center:Lerp(dest, flyEased)
		root.Position = UDim2.fromOffset(cardAt.X, cardAt.Y)
		rootScale.Scale = 1 - 0.6 * flyEased
		local stacked = meet:Lerp(dest, flyEased)
		local shrink = 1 - 0.6 * flyEased
		if coralCircle and coralCircle:IsA("GuiObject") then
			park(coralCircle, stacked, coralPxSize * shrink)
		end
		if hueCircle and hueCircle:IsA("GuiObject") then
			park(hueCircle, stacked, huePxSize * shrink)
		end
		if hueRing and hueRing:IsA("GuiObject") then
			park(hueRing, stacked, huePxSize * shrink)
		end
		if hueBrush and hueBrush:IsA("GuiObject") then
			park(hueBrush, stacked, (if brushPxSize > 1 then brushPxSize else huePxSize * 0.72) * shrink)
		end
		for _, piece in ipairs(burstPieces) do
			local at = meet:Lerp(piece.goal, burstEased)
			piece.part.Position = UDim2.fromOffset(at.X, at.Y)
			piece.part.BackgroundTransparency = burstEased
			local pieceStroke = piece.part:FindFirstChildOfClass("UIStroke")
			if pieceStroke then
				pieceStroke.Transparency = 0.15 + 0.85 * burstEased
			end
			local side = math.max(1, math.floor(piece.size * (1 + 0.35 * burstEased) + 0.5))
			piece.part.Size = UDim2.fromOffset(side, side)
		end
		RunService.Heartbeat:Wait()
	end
	fadeText(1)
	dropFlown()
	if presentToken ~= token then
		return
	end
	mode = "idle"
	target = nil
	holdRow.Visible = true
	barBack.Visible = true
	hideCard()
end

local function wantsHold(): boolean
	return keyDown or pointerDown
end

local function finishHold()
	if mode ~= "hold" then
		return
	end
	local part = target
	if not part or not part.Parent then
		cancelHold(false)
		return
	end
	local itemId, hue = readHarvest(part)
	local key = part:GetAttribute("OceanTD_HarvestKey")
	if not itemId or not hue or typeof(key) ~= "string" then
		mode = "hold"
		cancelHold(true)
		return
	end
	mode = "claim"
	applyDrop(1)
	local ok = false
	local invoked = pcall(function()
		ok = Remotes.getFunction("RequestClaimCommonHarvest"):InvokeServer(itemId, hue, holdGen) == true
	end)
	local tripping = useTrip
	useTrip = false
	digAlpha = -1
	holdLatched = false
	if not tripping then
		PlantWorkerVfx.endInPlaceDig()
	end
	unlockMove()
	if not invoked or not ok then
		if tripping then
			PlantWorkerVfx.cancelHarvestTrip()
		end
		applyDrop(0)
		restoreCollide()
		holdAnchor = nil
		table.clear(origins)
		mode = "show"
		barBack.Visible = false
		barFill.Size = UDim2.fromScale(0, 1)
		return
	end
	table.clear(savedCollide)
	holdAnchor = nil
	table.clear(origins)
	local folder = Workspace:FindFirstChild("OceanTD_CommonGrow")
	local bindable = folder and folder:FindFirstChild("OceanTD_Harvested")
	if bindable and bindable:IsA("BindableEvent") then
		bindable:Fire(key)
	elseif part.Parent then
		part:Destroy()
	end
	target = nil
	task.spawn(playPresent)
end

local function beginHold(part: BasePart)
	if mode ~= "show" then
		return
	end
	local itemId, hue = readHarvest(part)
	if not itemId or not hue then
		return
	end
	mode = "arming"
	holdGen += 1
	local gen = holdGen
	local accepted = false
	local invoked = pcall(function()
		accepted = Remotes.getFunction("RequestBeginCommonHarvest"):InvokeServer(itemId, hue, gen) == true
	end)
	if not invoked or not accepted or target ~= part or not wantsHold() then
		if accepted then
			pcall(function()
				Remotes.get("CommonHarvestCancel"):FireServer(holdGen)
			end)
		end
		mode = "show"
		return
	end
	cardFrom = cardCenter()
	captureOrigins(part)
	holdAnchor = plantPos(part)
	if isFreeCam() then
		useTrip = true
		digAlpha = -1
		holdLatched = false
		mode = "hold"
		holdStart = os.clock()
		local started = PlantWorkerVfx.playHarvestTrip(plantPos(part), HOLD_SEC, function(u: number)
			digAlpha = u
		end, function() end)
		if not started then
			useTrip = false
			pcall(function()
				Remotes.get("CommonHarvestCancel"):FireServer(holdGen)
			end)
			mode = "show"
		end
		return
	end
	if not PlantWorkerVfx.beginInPlaceDig() then
		pcall(function()
			Remotes.get("CommonHarvestCancel"):FireServer(holdGen)
		end)
		mode = "show"
		return
	end
	mode = "hold"
	holdStart = os.clock()
	lockMove()
end

local function pointOnChrome(screenPos: Vector3): boolean
	if not gui.Enabled then
		return false
	end
	local origin = root.AbsolutePosition
	local size = root.AbsoluteSize
	return screenPos.X >= origin.X
		and screenPos.Y >= origin.Y
		and screenPos.X <= origin.X + size.X
		and screenPos.Y <= origin.Y + size.Y
end

local function releaseHoldPointer(input: InputObject)
	if holdPointer ~= input then
		return
	end
	holdPointer = nil
	pointerDown = false
end

UserInputService.LastInputTypeChanged:Connect(function()
	if gui.Enabled then
		refreshHoldHint()
	end
end)

UserInputService.InputBegan:Connect(function(input, _processed)
	if UserInputService:GetFocusedTextBox() then
		return
	end
	if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
		-- Only a press that starts on the card. A finger already down that slides onto it does not count.
		if pointOnChrome(input.Position) then
			holdPointer = input
			pointerDown = true
		end
		return
	end
	if input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.ButtonB then
		keyDown = true
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
		releaseHoldPointer(input)
		return
	end
	if input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.ButtonB then
		keyDown = false
	end
end)

RunService.Heartbeat:Connect(function(dt)
	if mode == "present" or mode == "arming" or mode == "claim" then
		return
	end
	if mode == "hold" then
		local part = target
		if not part or not part.Parent or not harvestAllowed() then
			cancelHold(true)
			return
		end
		if useTrip then
			local elapsed = os.clock() - holdStart
			local digDone = digAlpha >= 1 or (digAlpha >= 0 and elapsed >= HOLD_SEC + 1.5)
			if digDone then
				applyDrop(1)
				barFill.Size = UDim2.fromScale(1, 1)
				placeHold(1)
				finishHold()
				return
			end
			if digAlpha < 0 and elapsed > 2.5 then
				cancelHold(true)
				return
			end
			if not wantsHold() then
				cancelHold(true)
				return
			end
			if digAlpha < 0 then
				holdLatched = false
				placeBelow(part)
				return
			end
			if not holdLatched then
				holdLatched = true
				cardFrom = cardCenter()
			end
			applyDrop(digAlpha)
			barFill.Size = UDim2.fromScale(digAlpha, 1)
			placeHold(digAlpha)
			return
		end
		local rootPart = hrp()
		local anchor = holdAnchor
		if not rootPart or not anchor then
			cancelHold(true)
			return
		end
		local flat = Vector3.new(rootPart.Position.X - anchor.X, 0, rootPart.Position.Z - anchor.Z)
		if flat.Magnitude > HOLD_LEASH then
			cancelHold(true)
			return
		end
		if not wantsHold() then
			cancelHold(true)
			return
		end
		local alpha = math.clamp((os.clock() - holdStart) / HOLD_SEC, 0, 1)
		applyDrop(alpha)
		barFill.Size = UDim2.fromScale(alpha, 1)
		placeHold(alpha)
		if alpha >= 1 then
			finishHold()
		end
		return
	end

	if not harvestAllowed() then
		target = nil
		hideCard()
		mode = "idle"
		return
	end
	local near = nearestCoral()
	if near ~= target then
		target = near
		if near then
			local itemId, hue = readHarvest(near)
			if itemId and hue then
				rebuildCircles(itemId, hue)
			else
				target = nil
			end
		end
	end
	if not target then
		hideCard()
		mode = "idle"
		return
	end
	mode = "show"
	placeBelow(target)
	if wantsHold() and gui.Enabled then
		beginHold(target)
	end
end)

player.CharacterAdded:Connect(function()
	if mode == "hold" then
		cancelHold(false)
	end
	unlockMove()
end)
