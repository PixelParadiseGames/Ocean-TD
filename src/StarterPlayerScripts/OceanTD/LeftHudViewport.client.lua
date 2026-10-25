--!strict
--[[
	Scale MobileLeftUI.dPad with the HUD.
	$D count sits to the right of the store cart. The $D glyph beside the count stays hidden.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))
local UiPopupScale = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPopupScale"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local CORNER_MARGIN = 16
local ROW_PADDING = 10
local SHOP_DOLLAR_IMAGE = "rbxassetid://74290598144610"
local DARK_GREEN = Color3.fromRGB(0, 78, 50)
local BRIGHT_GREEN = Color3.fromRGB(70, 255, 110)
local COUNT_SKILLS_SCALE = "_OceanTD_CountSkillsScale"
local COUNT_SKILLS_GROW = 1.5 -- while skills / power-up are open
local dressedCarts: { GuiObject } = {}
local dressShopIcon: (GuiObject) -> ()

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

type SavedWidget = {
	parent: Instance,
	position: UDim2,
	anchorPoint: Vector2,
	size: UDim2,
	zIndex: number,
	layoutOrder: number,
}

local savedCount: SavedWidget? = nil
local savedLabel: SavedWidget? = nil
local sizeConn: RBXScriptConnection? = nil
local countGrowTween: Tween? = nil
local countColorTween: Tween? = nil
local countColorCycling = false
local countGrowValue = Instance.new("NumberValue")
countGrowValue.Value = 1

local function saveWidget(widget: GuiObject): SavedWidget
	return {
		parent = widget.Parent :: Instance,
		position = widget.Position,
		anchorPoint = widget.AnchorPoint,
		size = widget.Size,
		zIndex = widget.ZIndex,
		layoutOrder = widget.LayoutOrder,
	}
end

local function saveWidgetDefaults(widget: GuiObject, saved: SavedWidget?): SavedWidget
	if saved then
		return saved
	end
	return saveWidget(widget)
end

local function ensureViewportScale(obj: GuiObject, scale: number): UIScale
	local existing = obj:FindFirstChild(LeftHudLayout.VIEWPORT_SCALE_NAME)
	local s: UIScale
	if existing and existing:IsA("UIScale") then
		s = existing
	else
		s = Instance.new("UIScale")
		s.Name = LeftHudLayout.VIEWPORT_SCALE_NAME
		s.Parent = obj
	end
	s.Scale = scale
	obj:SetAttribute(LeftHudLayout.BASE_SCALE_ATTR, scale)
	return s
end

local function clearViewportScale(obj: GuiObject)
	local sc = obj:FindFirstChild(LeftHudLayout.VIEWPORT_SCALE_NAME)
	if sc and sc:IsA("UIScale") then
		sc.Scale = 1
	end
	obj:SetAttribute(LeftHudLayout.BASE_SCALE_ATTR, 1)
end

local function restoreWidget(widget: GuiObject, saved: SavedWidget?)
	if saved then
		widget.Parent = saved.parent
		widget.Position = saved.position
		widget.AnchorPoint = saved.anchorPoint
		widget.Size = saved.size
		widget.ZIndex = saved.zIndex
		widget.LayoutOrder = saved.layoutOrder
	end
	clearViewportScale(widget)
end

local function ensureSandDollarRow(left: ScreenGui): Frame
	local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
	if row and row:IsA("Frame") then
		local lay = row:FindFirstChildOfClass("UIListLayout")
		if lay then
			lay.Padding = UDim.new(0, ROW_PADDING)
		end
		return row
	end
	if row then
		row:Destroy()
	end
	row = Instance.new("Frame")
	row.Name = LeftHudLayout.ROW_NAME
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.AutomaticSize = Enum.AutomaticSize.XY
	row.Size = UDim2.fromOffset(0, 0)
	row.Parent = left
	local lay = Instance.new("UIListLayout")
	lay.FillDirection = Enum.FillDirection.Horizontal
	lay.HorizontalAlignment = Enum.HorizontalAlignment.Left
	lay.VerticalAlignment = Enum.VerticalAlignment.Center
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Padding = UDim.new(0, ROW_PADDING)
	lay.Parent = row
	return row
end

local function prepRowChild(widget: GuiObject, order: number)
	widget.LayoutOrder = order
	widget.AnchorPoint = Vector2.new(0, 0.5)
	widget.Position = UDim2.fromOffset(0, 0)
	widget.ClipsDescendants = false
end

local function layoutSandDollar720p(left: ScreenGui, dLabel: GuiObject?, dCount: GuiObject, scale: number)
	savedCount = saveWidgetDefaults(dCount, savedCount)
	if dLabel then
		savedLabel = saveWidgetDefaults(dLabel, savedLabel)
	end

	local row = ensureSandDollarRow(left)
	row.AnchorPoint = Vector2.new(0, 1)
	local margin = math.floor(CORNER_MARGIN * scale + 0.5)
	-- Skip Training sits on the bottom-left, and the reef/wave bars sit on the bottom edge.
	-- Lift $D above both. Phone layout is restored separately and stays put.
	local skipClear = 28 + math.floor(28 * scale) + 18
	local reefClear = 10 + math.floor((28 + 4 + 36) * scale) + 18
	local lift = math.max(margin, skipClear, reefClear)
	row.Position = UDim2.new(0, margin, 1, -lift)
	row.ZIndex = math.max(dCount.ZIndex, if dLabel then dLabel.ZIndex else 0, 40)

	if dLabel then
		prepRowChild(dLabel, 1)
		dLabel.Parent = row
	end
	prepRowChild(dCount, 2)
	dCount.Parent = row

	ensureViewportScale(row, scale)
	dCount:SetAttribute(LeftHudLayout.BASE_SCALE_ATTR, scale)
end

local function restoreSandDollar(left: ScreenGui, dLabel: GuiObject?, dCount: GuiObject?)
	if dCount then
		restoreWidget(dCount, savedCount)
	end
	if dLabel then
		restoreWidget(dLabel, savedLabel)
	end
	local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
	if row and row:IsA("Frame") then
		row:Destroy()
	end
end

local function placeCountBesideStore(left: ScreenGui, dCount: GuiObject)
	local dPad = left:FindFirstChild("dPad")
	if not dPad then
		return
	end
	local cart: GuiObject? = nil
	for _, name in ipairs({ "CartIcon", "CartBTN", "CartBtn", "Cart" }) do
		local ch = dPad:FindFirstChild(name)
		if ch and ch:IsA("GuiObject") then
			cart = ch
			break
		end
	end
	if not cart or cart.AbsoluteSize.X < 2 then
		return
	end
	clearViewportScale(dCount)
	-- Sit on the ScreenGui, flush with the cart.
	local screenX = cart.AbsolutePosition.X + cart.AbsoluteSize.X - left.AbsolutePosition.X
	local screenY = cart.AbsolutePosition.Y + cart.AbsoluteSize.Y * 0.5 - left.AbsolutePosition.Y
	dCount.Parent = left
	dCount.AnchorPoint = Vector2.new(0, 0.5)
	local baseSX = dCount:GetAttribute("_OceanTD_CountBaseSX")
	local baseOX = dCount:GetAttribute("_OceanTD_CountBaseOX")
	local baseSY = dCount:GetAttribute("_OceanTD_CountBaseSY")
	local baseOY = dCount:GetAttribute("_OceanTD_CountBaseOY")
	if typeof(baseSX) ~= "number" or typeof(baseOX) ~= "number" or typeof(baseSY) ~= "number" or typeof(baseOY) ~= "number" then
		baseSX = dCount.Size.X.Scale
		baseOX = dCount.Size.X.Offset
		baseSY = dCount.Size.Y.Scale
		baseOY = dCount.Size.Y.Offset
		dCount:SetAttribute("_OceanTD_CountBaseSX", baseSX)
		dCount:SetAttribute("_OceanTD_CountBaseOX", baseOX)
		dCount:SetAttribute("_OceanTD_CountBaseSY", baseSY)
		dCount:SetAttribute("_OceanTD_CountBaseOY", baseOY)
	end
	local grow = countGrowValue.Value
	dCount.Size = UDim2.new(
		baseSX * 0.8 * grow,
		math.floor(baseOX * 0.8 * grow + 0.5),
		baseSY * 0.8 * grow,
		math.floor(baseOY * 0.8 * grow + 0.5)
	)
	dCount.Position = UDim2.fromOffset(math.floor(screenX + 0.5), math.floor(screenY + 0.5))
	dCount.ZIndex = 80
	dCount.Visible = true
	if not countColorCycling then
		dCount.BackgroundColor3 = DARK_GREEN
	end
	dCount.BackgroundTransparency = 0
	dCount.BorderSizePixel = 0
	dCount.ClipsDescendants = true
	local countCorner = dCount:FindFirstChild("_OceanTD_CountCorner")
	if not countCorner then
		countCorner = Instance.new("UICorner")
		countCorner.Name = "_OceanTD_CountCorner"
		countCorner.Parent = dCount
	end
	if countCorner:IsA("UICorner") then
		countCorner.CornerRadius = UDim.new(0, 6)
	end
	UiPopupScale.attachHud(dCount)
	local function shrinkText(lbl: TextLabel | TextButton)
		if lbl.TextScaled then
			lbl.TextScaled = false
		end
		local base = lbl:GetAttribute("_OceanTD_CountTextBase")
		if typeof(base) ~= "number" then
			base = lbl.TextSize
			lbl:SetAttribute("_OceanTD_CountTextBase", base)
		end
		lbl.TextSize = math.max(8, math.floor((base - 2) * 0.8 * countGrowValue.Value + 0.5))
	end
	if dCount:IsA("TextLabel") or dCount:IsA("TextButton") then
		shrinkText(dCount)
	end
	for _, d in ipairs(dCount:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			shrinkText(d)
		end
	end
	local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
	if row and row ~= dCount.Parent then
		row:Destroy()
	end
end

local function skillsUiOpen(): boolean
	return playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true
		or playerGui:GetAttribute("OceanTD_SkillPowerUpOpen") == true
end

local function restoreBackHome(gui: GuiObject)
	if gui:GetAttribute("_OceanTD_BackHomeSaved") ~= true then
		return
	end
	local xs = gui:GetAttribute("_OceanTD_BackHomeXS")
	local xo = gui:GetAttribute("_OceanTD_BackHomeXO")
	local ys = gui:GetAttribute("_OceanTD_BackHomeYS")
	local yo = gui:GetAttribute("_OceanTD_BackHomeYO")
	if typeof(xs) ~= "number" or typeof(xo) ~= "number" or typeof(ys) ~= "number" or typeof(yo) ~= "number" then
		return
	end
	gui.Position = UDim2.new(xs, xo, ys, yo)
end

local function dropBackBelowCount(gui: GuiObject, count: GuiObject)
	local parent = gui.Parent
	if not parent or not parent:IsA("GuiObject") then
		return
	end
	if gui:GetAttribute("_OceanTD_BackHomeSaved") ~= true then
		gui:SetAttribute("_OceanTD_BackHomeSaved", true)
		gui:SetAttribute("_OceanTD_BackHomeXS", gui.Position.X.Scale)
		gui:SetAttribute("_OceanTD_BackHomeXO", gui.Position.X.Offset)
		gui:SetAttribute("_OceanTD_BackHomeYS", gui.Position.Y.Scale)
		gui:SetAttribute("_OceanTD_BackHomeYO", gui.Position.Y.Offset)
	end
	if count.AbsoluteSize.Y < 2 or gui.AbsoluteSize.Y < 2 then
		return
	end
	local countLeft = count.AbsolutePosition.X
	local countRight = countLeft + count.AbsoluteSize.X
	local btnLeft = gui.AbsolutePosition.X
	local btnRight = btnLeft + gui.AbsoluteSize.X
	if btnRight <= countLeft or btnLeft >= countRight then
		return
	end
	local gap = math.max(18, math.floor(count.AbsoluteSize.Y * 0.35 + 0.5))
	local desiredTop = count.AbsolutePosition.Y + count.AbsoluteSize.Y + gap
	if gui.AbsolutePosition.Y >= desiredTop - 1 then
		return
	end
	local scale = UiPopupScale.ancestorScale(parent)
	if scale < 0.001 then
		scale = 1
	end
	local delta = (desiredTop - gui.AbsolutePosition.Y) / scale
	local pos = gui.Position
	gui.Position = UDim2.new(pos.X.Scale, pos.X.Offset, pos.Y.Scale, pos.Y.Offset + delta)
end

local syncSkillsDollarMark: (ScreenGui, GuiObject) -> ()

local function keepBacksClearOfCount(count: GuiObject)
	local left = count:FindFirstAncestorOfClass("ScreenGui") or count.Parent
	local dPad = left and left:FindFirstChild("dPad")
	local skills = dPad and dPad:FindFirstChild("Skills")
	if skills and skills:IsA("GuiObject") and skillsUiOpen() and skills.Visible then
		dropBackBelowCount(skills, count)
	end
	if not skillsUiOpen() then
		return
	end
	local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))
	SkillPowerUpUI.placeCloseBelowDollarCount()
end

local function ensureCountSkillsScale(dCount: GuiObject): UIScale
	local existing = dCount:FindFirstChild(COUNT_SKILLS_SCALE)
	if existing and existing:IsA("UIScale") then
		return existing
	end
	local s = Instance.new("UIScale")
	s.Name = COUNT_SKILLS_SCALE
	s.Scale = 1
	s.Parent = dCount
	s:GetPropertyChangedSignal("Scale"):Connect(function()
		keepBacksClearOfCount(dCount)
	end)
	return s
end

local function syncCountSkillsGrow()
	local left = playerGui:FindFirstChild("MobileLeftUI")
	if not left or not left:IsA("ScreenGui") then
		return
	end
	local dCount = LeftHudLayout.findDCount(left)
	if not dCount then
		return
	end
	syncSkillsDollarMark(left, dCount)
	local goal = if skillsUiOpen() then COUNT_SKILLS_GROW else 1
	if skillsUiOpen() then
		if not countColorCycling then
			countColorCycling = true
			dCount.BackgroundColor3 = DARK_GREEN
			if countColorTween then
				countColorTween:Cancel()
			end
			local colorTw = TweenService:Create(
				dCount,
				TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ BackgroundColor3 = BRIGHT_GREEN }
			)
			countColorTween = colorTw
			colorTw:Play()
		end
	else
		countColorCycling = false
		if countColorTween then
			countColorTween:Cancel()
			countColorTween = nil
		end
		dCount.BackgroundColor3 = DARK_GREEN
	end
	if countGrowTween then
		countGrowTween:Cancel()
		countGrowTween = nil
	end
	local tw = TweenService:Create(
		countGrowValue,
		TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Value = goal }
	)
	countGrowTween = tw
	tw.Completed:Connect(function()
		if countGrowTween == tw then
			countGrowTween = nil
		end
		if dCount.Parent then
			placeCountBesideStore(left, dCount)
			syncSkillsDollarMark(left, dCount)
			keepBacksClearOfCount(dCount)
		end
		if not skillsUiOpen() then
			local dPad = left:FindFirstChild("dPad")
			local skills = dPad and dPad:FindFirstChild("Skills")
			if skills and skills:IsA("GuiObject") then
				restoreBackHome(skills)
			end
		end
	end)
	tw:Play()
end

local function hideLooseDollarGlyphs(left: Instance)
	local dCount = LeftHudLayout.findDCount(left)
	local function hide(gui: GuiObject)
		if gui.Name == "_OceanTD_ShopDollarFace" or gui.Name == "_OceanTD_SkillsDollarFace" then
			return
		end
		if dCount and (gui == dCount or gui:IsDescendantOf(dCount)) then
			return
		end
		gui.Visible = false
	end
	local named = left:FindFirstChild("$D", true)
	if named and named:IsA("GuiObject") then
		hide(named)
	end
	local dLabel = LeftHudLayout.findDLabel(left)
	if dLabel then
		hide(dLabel)
	end
	for _, d in ipairs(left:GetDescendants()) do
		if d.Name == "_OceanTD_ShopDollarFace" or d.Name == "_OceanTD_SkillsDollarFace" then
			continue
		end
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d ~= dCount and not (dCount and d:IsDescendantOf(dCount)) then
			local t = string.gsub(d.Text, "%s+", "")
			if t == "$D" or t == "D$" then
				hide(d)
			end
		end
	end
end

function dressShopIcon(cart: GuiObject)
	cart.BackgroundColor3 = DARK_GREEN
	cart.BackgroundTransparency = 0
	cart.BorderSizePixel = 0
	local art: ImageLabel? = nil
	if cart:GetAttribute("_OceanTD_ShopDressed") ~= true then
		cart:SetAttribute("_OceanTD_ShopDressed", true)
		local cartImage = ""
		if (cart:IsA("ImageButton") or cart:IsA("ImageLabel")) and cart.Image ~= "" and cart.Image ~= SHOP_DOLLAR_IMAGE then
			cartImage = cart.Image
			cart.Image = SHOP_DOLLAR_IMAGE
			cart.ScaleType = Enum.ScaleType.Fit
		else
			local bg = Instance.new("ImageLabel")
			bg.Name = "_OceanTD_ShopDollarBg"
			bg.BackgroundTransparency = 1
			bg.BorderSizePixel = 0
			bg.Size = UDim2.fromScale(1, 1)
			bg.Image = SHOP_DOLLAR_IMAGE
			bg.ScaleType = Enum.ScaleType.Fit
			bg.ZIndex = cart.ZIndex
			bg.Active = false
			bg.Parent = cart
		end
		local icon = Instance.new("ImageLabel")
		icon.Name = "_OceanTD_ShopCartArt"
		icon.BackgroundTransparency = 1
		icon.BorderSizePixel = 0
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = UDim2.fromScale(0.828, 0.828)
		icon.Image = cartImage
		icon.ScaleType = Enum.ScaleType.Fit
		icon.ZIndex = cart.ZIndex + 2
		icon.Active = false
		icon.Parent = cart
		local face = Instance.new("TextLabel")
		face.Name = "_OceanTD_ShopDollarFace"
		face.BackgroundTransparency = 1
		face.BorderSizePixel = 0
		face.Size = UDim2.fromScale(1, 1)
		face.Font = UiTheme.Font
		face.Text = "$D"
		face.TextColor3 = Color3.new(1, 1, 1)
		face.TextStrokeColor3 = DARK_GREEN
		face.TextStrokeTransparency = 0
		face.TextScaled = true
		face.Visible = false
		face.ZIndex = cart.ZIndex + 3
		face.Active = false
		face.Parent = cart
		local outline = Instance.new("UIStroke")
		outline.Name = "Edge"
		outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		outline.Color = DARK_GREEN
		outline.Thickness = 2
		outline.Parent = face
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.22, 0)
		pad.PaddingBottom = UDim.new(0.22, 0)
		pad.PaddingLeft = UDim.new(0.12, 0)
		pad.PaddingRight = UDim.new(0.12, 0)
		pad.Parent = face
		art = icon
		table.insert(dressedCarts, cart)
	else
		local existing = cart:FindFirstChild("_OceanTD_ShopCartArt")
		if existing and existing:IsA("ImageLabel") then
			existing.Size = UDim2.fromScale(0.828, 0.828)
			art = existing
		end
		local face = cart:FindFirstChild("_OceanTD_ShopDollarFace")
		if face and face:IsA("TextLabel") then
			face.Font = UiTheme.Font
			face.TextStrokeColor3 = DARK_GREEN
			face.TextStrokeTransparency = 0
			local outline = face:FindFirstChild("Edge")
			if not outline then
				outline = Instance.new("UIStroke")
				outline.Name = "Edge"
				outline.Parent = face
			end
			if outline:IsA("UIStroke") then
				outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
				outline.Color = DARK_GREEN
				outline.Thickness = 2
			end
		end
	end
	if art and art.Image == "" then
		for _, d in ipairs(cart:GetChildren()) do
			if d:IsA("ImageLabel") and d.Name ~= "_OceanTD_ShopDollarBg" and d.Name ~= "_OceanTD_ShopCartArt" and d.Image ~= "" then
				art.Image = d.Image
				d.Visible = false
				break
			end
		end
	end
end

local function flipShopIcons()
	local storeOpen = playerGui:GetAttribute("OceanTD_StoreOpen") == true
	for i = #dressedCarts, 1, -1 do
		local cart = dressedCarts[i]
		if not cart.Parent then
			table.remove(dressedCarts, i)
			continue
		end
		local icon = cart:FindFirstChild("_OceanTD_ShopCartArt")
		local face = cart:FindFirstChild("_OceanTD_ShopDollarFace")
		if not icon or not icon:IsA("GuiObject") or not face or not face:IsA("GuiObject") then
			continue
		end
		if storeOpen then
			continue
		end
		local showCart = math.floor(os.clock() / 0.8) % 2 == 0
		icon.Visible = showCart
		face.Visible = not showCart
	end
end

function syncSkillsDollarMark(left: ScreenGui, dCount: GuiObject)
	local mark = left:FindFirstChild("_OceanTD_SkillsDollarMark")
	if not skillsUiOpen() then
		if mark and mark:IsA("GuiObject") then
			mark.Visible = false
		end
		return
	end
	if not mark or not mark:IsA("Frame") then
		if mark then
			mark:Destroy()
		end
		local made = Instance.new("Frame")
		made.Name = "_OceanTD_SkillsDollarMark"
		made.BackgroundColor3 = DARK_GREEN
		made.BorderSizePixel = 0
		made.AnchorPoint = Vector2.new(1, 0.5)
		made.Active = false
		made.ZIndex = 79
		made.Parent = left
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = made
		local image = Instance.new("ImageLabel")
		image.Name = "SandDollar"
		image.BackgroundTransparency = 1
		image.Size = UDim2.fromScale(1, 1)
		image.Image = SHOP_DOLLAR_IMAGE
		image.ScaleType = Enum.ScaleType.Fit
		image.ZIndex = 80
		image.Active = false
		image.Parent = made
		local face = Instance.new("TextLabel")
		face.Name = "_OceanTD_SkillsDollarFace"
		face.BackgroundTransparency = 1
		face.Size = UDim2.fromScale(1, 1)
		face.Font = UiTheme.Font
		face.Text = "$D"
		face.TextColor3 = Color3.new(1, 1, 1)
		face.TextStrokeColor3 = DARK_GREEN
		face.TextStrokeTransparency = 0
		face.TextScaled = true
		face.ZIndex = 81
		face.Active = false
		face.Parent = made
		local outline = Instance.new("UIStroke")
		outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		outline.Color = DARK_GREEN
		outline.Thickness = 2
		outline.Parent = face
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.18, 0)
		pad.PaddingBottom = UDim.new(0.18, 0)
		pad.PaddingLeft = UDim.new(0.12, 0)
		pad.PaddingRight = UDim.new(0.12, 0)
		pad.Parent = face
		mark = made
	end
	local side = dCount.Size.Y
	mark.Size = UDim2.new(side.Scale, side.Offset, side.Scale, side.Offset)
	mark.Position = dCount.Position
	mark.Visible = true
	UiPopupScale.attachHud(mark)
end

local function applyLeftHud()
	local left = playerGui:FindFirstChild("MobileLeftUI")
	if not left or not left:IsA("ScreenGui") then
		return
	end

	LeftHudLayout.hardenScreenGui(left)
	left.IgnoreGuiInset = true
	left.ClipToDeviceSafeArea = false

	local dPad = left:FindFirstChild("dPad")
	if not dPad or not dPad:IsA("GuiObject") then
		return
	end

	-- Studio often authors dPad as Active=true. That Frame is ~400×270 and sits in the
	-- top-left — it eats world clicks/pinches and shows the hand cursor. Children
	-- (Skills / FreeCam / $D) stay interactive on their own Active buttons.
	-- Do NOT set Interactable=false here — that disables the entire subtree.
	dPad.Active = false

	UiPopupScale.attachHud(dPad)

	local dCount = LeftHudLayout.findDCount(left)
	hideLooseDollarGlyphs(left)
	if dCount then
		placeCountBesideStore(left, dCount)
		syncSkillsDollarMark(left, dCount)
		local dPadNow = left:FindFirstChild("dPad")
		local cart: GuiObject? = nil
		if dPadNow then
			for _, name in ipairs({ "CartIcon", "CartBTN", "CartBtn", "Cart" }) do
				local ch = dPadNow:FindFirstChild(name)
				if ch and ch:IsA("GuiObject") then
					cart = ch
					break
				end
			end
		end
		if cart then
			dressShopIcon(cart)
		end
		task.defer(function()
			if dCount.Parent then
				placeCountBesideStore(left, dCount)
				syncSkillsDollarMark(left, dCount)
			end
			if cart then
				dressShopIcon(cart)
			end
		end)
	end
end

local function bindCamera(cam: Camera?)
	if sizeConn then
		sizeConn:Disconnect()
		sizeConn = nil
	end
	if not cam then
		return
	end
	sizeConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		applyLeftHud()
	end)
	applyLeftHud()
end

task.spawn(function()
	playerGui:WaitForChild("MobileLeftUI", 60)
	bindCamera(Workspace.CurrentCamera)
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		bindCamera(Workspace.CurrentCamera)
	end)
	task.delay(0.5, applyLeftHud)
	task.delay(1.5, applyLeftHud)
	playerGui:GetAttributeChangedSignal("OceanTD_SkillsBubblesOpen"):Connect(syncCountSkillsGrow)
	playerGui:GetAttributeChangedSignal("OceanTD_SkillPowerUpOpen"):Connect(syncCountSkillsGrow)
	syncCountSkillsGrow()
	countGrowValue.Changed:Connect(function()
		local left = playerGui:FindFirstChild("MobileLeftUI")
		if not left or not left:IsA("ScreenGui") then
			return
		end
		local dCount = LeftHudLayout.findDCount(left)
		if not dCount then
			return
		end
		placeCountBesideStore(left, dCount)
		syncSkillsDollarMark(left, dCount)
		keepBacksClearOfCount(dCount)
	end)
	task.spawn(function()
		while true do
			local left = playerGui:FindFirstChild("MobileLeftUI")
			if left then
				hideLooseDollarGlyphs(left)
			end
			flipShopIcons()
			task.wait(0.25)
		end
	end)
	local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
	WaveSim.onHud(function(snap)
		local left = playerGui:FindFirstChild("MobileLeftUI")
		if not left then
			return
		end
		hideLooseDollarGlyphs(left)
		if snap.running == true then
			local dCount = LeftHudLayout.findDCount(left)
			if dCount then
				dCount.Visible = true
			end
		end
	end)
end)
