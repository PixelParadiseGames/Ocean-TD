--!strict
--[[
	Fullscreen store: 3 $D packs (Stacks / Sack / Chest). Opened from dPad cart while NOT in build mode.
	While open: CartIcon becomes pulsing red close (X / B), same pattern as Skills / Reef Report.
	Cart click / DPadUp are routed by ReefReportUI; X / ButtonB / Escape also close.
	BUY buttons are visual stubs for now (purchases wired later).
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD")
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local StoreUI = {}

local STORE_OPEN_ATTR = "OceanTD_StoreOpen"
local FORCE_CLOSE_ATTR = "OceanTD_ForceCloseStore"
local SKILLS_OPEN_ATTR = "OceanTD_SkillsBubblesOpen"
local REPORT_OPEN_ATTR = "OceanTD_ReefReportOpen"
local STORE_GUI_NAME = "OceanTD_Store"
local STORE_DISPLAY_ORDER = 9200
local STORE_LAYOUT_VER = 2 -- bump when pack column spacing / chrome layout changes
-- Cart / close chrome must sit above the store dim (same pattern as Reef Report).
local STORE_LEFT_HUD_ORDER = STORE_DISPLAY_ORDER + 80
-- Match SkillPowerUpUI close X pulse (glyph only, not the red circle).
local CLOSE_X_PULSE = TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

local BUY_GREEN_DARK = Color3.fromRGB(18, 110, 45)
local BUY_GREEN_BRIGHT = Color3.fromRGB(50, 230, 90)
local BUY_STROKE_GREEN = Color3.fromRGB(70, 255, 110)
local AMOUNT_WHITE = Color3.fromRGB(255, 255, 255)
local PANEL_STROKE_TEAL = Color3.fromRGB(40, 220, 210)
local PANEL_STROKE_GREEN = Color3.fromRGB(70, 255, 110)
local PANEL_STROKE_THICK = 5
local PANEL_STROKE_CYCLE_HZ = 0.55
local SHOP_OPEN_SEC = 0.5 -- whole shop UI expands from cart button
local SHOP_OPEN_INFO = TweenInfo.new(SHOP_OPEN_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GRAPHIC_INTRO_SEC = 1
local GRAPHIC_STAGGER_SEC = 0.14 -- Stacks → Sack → Chest
local GRAPHIC_INTRO_INFO = TweenInfo.new(GRAPHIC_INTRO_SEC, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

type DollarPack = {
	id: string,
	imageId: string,
	amount: number,
	priceLabel: string,
}

local DOLLAR_PACKS: { DollarPack } = {
	{
		id = "Stacks",
		imageId = "rbxassetid://99049838462637",
		amount = 100,
		priceLabel = "BUY $1",
	},
	{
		id = "Sack",
		imageId = "rbxassetid://86639674396031",
		amount = 1000,
		priceLabel = "BUY $5",
	},
	{
		id = "Chest",
		imageId = "rbxassetid://88016584740069",
		amount = 10000,
		priceLabel = "BUY $10",
	},
}

local CART_NAMES: { [string]: boolean } = {
	CartIcon = true,
	Cart = true,
	CartBTN = true,
	CartBtn = true,
	Report = true,
	ReefReport = true,
	ShoppingCart = true,
}

local open = false
local storeGui: ScreenGui? = nil
local cartBtn: GuiObject? = nil
local leftGui: ScreenGui? = nil
local leftOrderBase = 0
local leftInsetsSaved: Enum.ScreenInsets? = nil
local leftIgnoreInsetSaved: boolean? = nil
local leftClipSaved: boolean? = nil
local closeChrome: GuiObject? = nil
local closeLabel: TextLabel? = nil
local closeScale: UIScale? = nil
local closeXPulseTween: Tween? = nil
local panelStroke: UIStroke? = nil
local panelStrokeConn: RBXScriptConnection? = nil
local panelStrokeToken = 0
local graphicIntroToken = 0
local graphicIntroTweens: { Tween } = {}
local shopOpenToken = 0
local shopOpenTween: Tween? = nil
local hiddenCartKids: { GuiObject } = {}
local hiddenLeft: { { gui: GuiObject, wasVisible: boolean } } = {}
local lastToggleAt = 0
local TOGGLE_COOLDOWN = 0.2
local inited = false

local function isGamepadMode(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function findCartButton(dPad: Instance): GuiObject?
	local preferred = { "CartIcon", "CartBTN", "CartBtn", "Cart", "cart", "Report", "ReefReport", "ShoppingCart" }
	for _, name in ipairs(preferred) do
		local ch = dPad:FindFirstChild(name)
		if ch and ch:IsA("GuiObject") then
			return ch
		end
	end
	for _, ch in ipairs(dPad:GetChildren()) do
		if ch:IsA("GuiObject") and CART_NAMES[ch.Name] then
			return ch
		end
	end
	return nil
end

local function ensureHitOverlay(btn: GuiObject): GuiButton
	local existing = btn:FindFirstChild("_OceanTD_CartHit")
	if existing and existing:IsA("GuiButton") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local hit = Instance.new("TextButton")
	hit.Name = "_OceanTD_CartHit"
	hit.Text = ""
	hit.BackgroundTransparency = 1
	hit.BorderSizePixel = 0
	hit.Size = UDim2.fromScale(1, 1)
	hit.ZIndex = btn.ZIndex + 5
	hit.AutoButtonColor = false
	hit.Parent = btn
	return hit
end

local function stopClosePulse()
	if closeXPulseTween then
		closeXPulseTween:Cancel()
		closeXPulseTween = nil
	end
	if closeScale then
		closeScale.Scale = 1
	end
end

local function syncCloseLabel()
	if closeLabel then
		closeLabel.Text = if isGamepadMode() then "B" else "X"
		closeLabel.TextColor3 = Color3.new(1, 1, 1)
		closeLabel.TextTransparency = 0
	end
end

local function startClosePulse()
	stopClosePulse()
	if not closeLabel then
		return
	end
	-- SkillPowerUpUI style: pulse only the X/B glyph from center (not the red disc).
	closeLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	closeLabel.Position = UDim2.fromScale(0.5, 0.5)
	closeLabel.Size = UDim2.fromScale(1, 1)
	local scale = closeLabel:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "_OceanTD_CloseXScale"
		scale.Parent = closeLabel
	end
	scale.Scale = 1
	closeScale = scale
	closeXPulseTween = TweenService:Create(scale, CLOSE_X_PULSE, { Scale = 1.28 })
	closeXPulseTween:Play()
end

local function hideCartBtnContent(hide: boolean)
	if not cartBtn then
		return
	end
	if hide then
		table.clear(hiddenCartKids)
		for _, ch in ipairs(cartBtn:GetChildren()) do
			if ch:IsA("GuiObject")
				and ch.Name ~= "_OceanTD_CartHit"
				and ch.Name ~= "_OceanTD_StoreClose"
				and ch.Name ~= "_OceanTD_ReefReportClose"
				and ch.Name ~= "_OceanTD_CartInfoChrome"
			then
				if ch.Name == "_OceanTD_TutorialLeftLock" or ch.Name == "_OceanTD_TutorialLeftLockIcon" then
					ch:Destroy()
					continue
				end
				if ch.Visible then
					table.insert(hiddenCartKids, ch)
					ch.Visible = false
				end
			end
		end
		if cartBtn:IsA("ImageButton") or cartBtn:IsA("ImageLabel") then
			(cartBtn :: ImageButton).ImageTransparency = 1
		end
	else
		for _, ch in ipairs(hiddenCartKids) do
			if ch.Parent
				and ch.Name ~= "_OceanTD_CartInfoChrome"
				and ch.Name ~= "_OceanTD_TutorialLeftLock"
				and ch.Name ~= "_OceanTD_TutorialLeftLockIcon"
			then
				ch.Visible = true
			end
		end
		table.clear(hiddenCartKids)
		-- Build mode owns the info “i” chrome — don’t force the shop glyph back over it.
		if cartBtn:FindFirstChild("_OceanTD_CartInfoChrome") then
			return
		end
		if cartBtn:IsA("ImageButton") or cartBtn:IsA("ImageLabel") then
			(cartBtn :: ImageButton).ImageTransparency = 0
		end
	end
end

local function destroyCloseChrome()
	stopClosePulse()
	if closeChrome then
		closeChrome:Destroy()
		closeChrome = nil
	end
	closeLabel = nil
	closeScale = nil
	hideCartBtnContent(false)
end

local function findPowerUpCloseTemplate(): GuiObject?
	-- Studio CloseBTN used by Plot Size / other skill power-ups (red X graphic).
	local skills = playerGui:FindFirstChild("MobileSkillsA")
	if not skills then
		return nil
	end
	local dPad = skills:FindFirstChild("dPad") or skills:FindFirstChild("dPad", true)
	local close = (dPad and dPad:FindFirstChild("CloseBTN"))
		or skills:FindFirstChild("CloseBTN", true)
	if close and close:IsA("GuiObject") then
		return close
	end
	return nil
end

local function neutralizeCloneInteractives(root: GuiObject)
	root.Active = false
	root.Visible = true
	pcall(function()
		(root :: any).Interactable = false
	end)
	if root:IsA("GuiButton") then
		root.AutoButtonColor = false
		root.Selectable = false
	end
	if root:IsA("ImageButton") or root:IsA("ImageLabel") then
		(root :: ImageButton).ImageTransparency = 0
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("GuiObject") then
			d.Active = false
			pcall(function()
				(d :: any).Interactable = false
			end)
			if d:IsA("GuiButton") then
				d.AutoButtonColor = false
				d.Selectable = false
			end
			-- Drop power-up/runtime overlays; keep Studio art children.
			if d.Name == "_OceanTD_CloseX"
				or d.Name == "_OceanTD_CloseXScale"
				or d.Name == "_OceanTD_RHealthCloseScale"
				or d.Name == "_OceanTD_PowerUpCloseX"
			then
				d:Destroy()
			end
		end
	end
end

local function ensureCloseChrome()
	if not cartBtn then
		return
	end
	destroyCloseChrome()
	hideCartBtnContent(true)

	local chrome: GuiObject
	local template = findPowerUpCloseTemplate()
	if template then
		-- Clone the real CloseBTN graphic so shop matches Plot Size power-up close.
		chrome = template:Clone()
		chrome.Name = "_OceanTD_StoreClose"
		neutralizeCloneInteractives(chrome)
	else
		-- Fallback if Studio CloseBTN is missing.
		chrome = Instance.new("Frame")
		chrome.Name = "_OceanTD_StoreClose"
		chrome.BackgroundColor3 = Color3.fromRGB(220, 40, 50)
		chrome.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = chrome
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = Color3.fromRGB(255, 255, 255)
		stroke.Transparency = 0.15
		stroke.Parent = chrome
	end
	chrome.AnchorPoint = Vector2.new(0.5, 0.5)
	chrome.Position = UDim2.fromScale(0.5, 0.5)
	chrome.Size = UDim2.fromScale(1, 1)
	chrome.ZIndex = cartBtn.ZIndex + 50
	chrome.Active = false
	chrome.Visible = true
	chrome.Parent = cartBtn

	local hitBtn = ensureHitOverlay(cartBtn)
	hitBtn.Visible = true
	hitBtn.Active = true
	hitBtn.ZIndex = chrome.ZIndex + 5

	-- Same pulsing white X/B glyph SkillPowerUp draws on CloseBTN.
	local lbl = Instance.new("TextLabel")
	lbl.Name = "_OceanTD_CloseX"
	lbl.BackgroundTransparency = 1
	lbl.AnchorPoint = Vector2.new(0.5, 0.5)
	lbl.Position = UDim2.fromScale(0.5, 0.5)
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = Enum.Font.GothamBold
	lbl.TextScaled = true
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextTransparency = 0
	lbl.TextStrokeTransparency = 1
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.ZIndex = chrome.ZIndex + 1
	lbl.Active = false
	lbl.Parent = chrome
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.18, 0)
	pad.PaddingBottom = UDim.new(0.18, 0)
	pad.PaddingLeft = UDim.new(0.18, 0)
	pad.PaddingRight = UDim.new(0.18, 0)
	pad.Parent = lbl

	closeChrome = chrome
	closeLabel = lbl
	closeScale = nil
	syncCloseLabel()
	startClosePulse()
end

local function rememberHideGui(gui: GuiObject)
	if gui == cartBtn then
		return
	end
	table.insert(hiddenLeft, { gui = gui, wasVisible = gui.Visible })
	gui.Visible = false
end

local function hideLeftUiExceptCart()
	table.clear(hiddenLeft)
	local left = playerGui:FindFirstChild("MobileLeftUI")
	if not left then
		return
	end
	local dPad = left:FindFirstChild("dPad")
	if dPad then
		for _, ch in ipairs(dPad:GetChildren()) do
			if ch:IsA("GuiObject") then
				-- Keep only the bound cart (close chrome anchors to it).
				if cartBtn and ch == cartBtn then
					continue
				end
				rememberHideGui(ch)
			end
		end
		-- PlotCam yaw/zoom quick pad (may be recreated while shop is open).
		local quick = dPad:FindFirstChild("OceanTD_PlotCam2Quick")
		if quick and quick:IsA("GuiObject") then
			quick.Visible = false
		end
	end
	-- Hide siblings on left HUD (StopAutoRoll / Roll, sand-dollar row, etc.).
	for _, ch in ipairs(left:GetChildren()) do
		if ch:IsA("GuiObject") and ch.Name ~= "dPad" then
			rememberHideGui(ch)
		end
	end
	local dCount = LeftHudLayout.findDCount(left)
	local dLabel = LeftHudLayout.findDLabel(left)
	if dCount then
		rememberHideGui(dCount)
	end
	if dLabel then
		rememberHideGui(dLabel)
	end
	local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
	if row and row:IsA("GuiObject") then
		rememberHideGui(row)
	end
end

local function pushSeedWheelUnderStore()
	local wheel = playerGui:FindFirstChild("OceanTD_SeedWheel")
	local sg = storeGui
	if wheel and wheel:IsA("ScreenGui") and sg then
		wheel.DisplayOrder = math.max(0, sg.DisplayOrder - 1)
	end
end

local function restoreLeftUi()
	for _, entry in ipairs(hiddenLeft) do
		if entry.gui.Parent then
			entry.gui.Visible = entry.wasVisible
		end
	end
	table.clear(hiddenLeft)
end

local function pushLeftHudForStore()
	local left = leftGui
	if not left then
		return
	end
	if leftInsetsSaved == nil then
		local ok, insets = pcall(function()
			return (left :: any).ScreenInsets
		end)
		if ok and typeof(insets) == "EnumItem" then
			leftInsetsSaved = insets
		end
		leftIgnoreInsetSaved = left.IgnoreGuiInset
		leftClipSaved = left.ClipToDeviceSafeArea
	end
	left.DisplayOrder = STORE_LEFT_HUD_ORDER
	left.IgnoreGuiInset = true
	left.ClipToDeviceSafeArea = false
	pcall(function()
		local anyLeft = left :: any
		anyLeft.ScreenInsets = Enum.ScreenInsets.None
	end)
end

local function popLeftHudFromStore()
	local left = leftGui
	if not left then
		return
	end
	left.DisplayOrder = leftOrderBase
	if leftIgnoreInsetSaved ~= nil then
		left.IgnoreGuiInset = leftIgnoreInsetSaved
		leftIgnoreInsetSaved = nil
	end
	if leftClipSaved ~= nil then
		left.ClipToDeviceSafeArea = leftClipSaved
		leftClipSaved = nil
	end
	if leftInsetsSaved ~= nil then
		local saved = leftInsetsSaved
		leftInsetsSaved = nil
		pcall(function()
			(left :: any).ScreenInsets = saved
		end)
	end
end

local function formatDollarAmount(n: number): string
	local s = tostring(math.floor(n))
	local out = s
	while true do
		local nextS, count = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1,%2")
		out = nextS
		if count == 0 then
			break
		end
	end
	return out .. " $D"
end

local function buildPackColumn(parent: Instance, pack: DollarPack, zBase: number): Frame
	local col = Instance.new("Frame")
	col.Name = "Pack_" .. pack.id
	col.BackgroundTransparency = 1
	col.BorderSizePixel = 0
	col.Size = UDim2.fromScale(1, 1)
	col.ZIndex = zBase
	col.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = col

	-- Fixed slot so UIScale grows from center without shifting the list layout.
	local artSlot = Instance.new("Frame")
	artSlot.Name = "GraphicSlot"
	artSlot.BackgroundTransparency = 1
	artSlot.BorderSizePixel = 0
	artSlot.Size = UDim2.fromOffset(160, 160)
	artSlot.LayoutOrder = 1
	artSlot.ZIndex = zBase + 1
	artSlot.Parent = col

	local art = Instance.new("ImageLabel")
	art.Name = "Graphic"
	art.BackgroundTransparency = 1
	art.AnchorPoint = Vector2.new(0.5, 0.5)
	art.Position = UDim2.fromScale(0.5, 0.5)
	art.Size = UDim2.fromScale(1, 1)
	art.Image = pack.imageId
	art.ScaleType = Enum.ScaleType.Fit
	art.ZIndex = zBase + 1
	art.Visible = false -- shown when staggered intro starts
	art.Parent = artSlot
	local artScale = Instance.new("UIScale")
	artScale.Name = "IntroScale"
	artScale.Scale = 0
	artScale.Parent = art

	local amount = Instance.new("TextLabel")
	amount.Name = "Amount"
	amount.BackgroundTransparency = 1
	amount.Size = UDim2.new(1, 0, 0, 44)
	amount.Font = UiTheme.Font
	amount.Text = formatDollarAmount(pack.amount)
	amount.TextSize = 48
	amount.TextColor3 = AMOUNT_WHITE
	amount.TextXAlignment = Enum.TextXAlignment.Center
	amount.TextYAlignment = Enum.TextYAlignment.Top
	amount.LayoutOrder = 2
	amount.ZIndex = zBase + 1
	amount.Parent = col

	local buy = Instance.new("TextButton")
	buy.Name = "Buy"
	buy.AutoButtonColor = true
	buy.BackgroundColor3 = Color3.new(1, 1, 1) -- white base so UIGradient shows true greens
	buy.BorderSizePixel = 0
	buy.Size = UDim2.fromOffset(160, 52)
	buy.Text = "" -- label is a child so UIGradient doesn't tint the text
	buy.LayoutOrder = 3
	buy.ZIndex = zBase + 2
	buy.Parent = col
	local buyCorner = Instance.new("UICorner")
	buyCorner.CornerRadius = UDim.new(0, 12)
	buyCorner.Parent = buy
	local buyGrad = Instance.new("UIGradient")
	buyGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, BUY_GREEN_DARK),
		ColorSequenceKeypoint.new(1, BUY_GREEN_BRIGHT),
	})
	buyGrad.Rotation = 90
	buyGrad.Parent = buy
	local buyStroke = Instance.new("UIStroke")
	buyStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	buyStroke.Thickness = 2.5
	buyStroke.Color = BUY_STROKE_GREEN
	buyStroke.Parent = buy
	local buyLbl = Instance.new("TextLabel")
	buyLbl.Name = "Label"
	buyLbl.BackgroundTransparency = 1
	buyLbl.Size = UDim2.fromScale(1, 1)
	buyLbl.Font = UiTheme.Font
	buyLbl.Text = pack.priceLabel
	buyLbl.TextSize = 22
	buyLbl.TextColor3 = AMOUNT_WHITE
	buyLbl.TextXAlignment = Enum.TextXAlignment.Center
	buyLbl.TextYAlignment = Enum.TextYAlignment.Center
	buyLbl.ZIndex = zBase + 3
	buyLbl.Active = false
	buyLbl.Parent = buy
	-- Stub: purchases wired later.
	buy.Activated:Connect(function() end)

	return col
end

local function stopPanelStrokeCycle()
	panelStrokeToken += 1
	if panelStrokeConn then
		panelStrokeConn:Disconnect()
		panelStrokeConn = nil
	end
end

local function cancelGraphicIntros()
	graphicIntroToken += 1
	for _, tw in ipairs(graphicIntroTweens) do
		pcall(function()
			tw:Cancel()
		end)
	end
	table.clear(graphicIntroTweens)
end

local function cancelShopOpenTween()
	shopOpenToken += 1
	if shopOpenTween then
		pcall(function()
			(shopOpenTween :: Tween):Cancel()
		end)
		shopOpenTween = nil
	end
end

local function forEachPackGraphic(sg: ScreenGui, fn: (art: GuiObject, scale: UIScale, index: number) -> ())
	local content = sg:FindFirstChild("Content")
	local panel = (content and content:FindFirstChild("Panel")) or sg:FindFirstChild("Panel")
	local offers = panel and panel:FindFirstChild("Offers")
	if not offers then
		return
	end
	for i = 1, #DOLLAR_PACKS do
		local col = offers:FindFirstChild("Col" .. tostring(i))
		if not (col and col:IsA("Frame")) then
			continue
		end
		local art = col:FindFirstChild("Graphic", true)
		local scaleObj = art and art:FindFirstChild("IntroScale")
		if art and art:IsA("GuiObject") and scaleObj and scaleObj:IsA("UIScale") then
			fn(art, scaleObj, i)
		end
	end
end

local function resetGraphicScales(sg: ScreenGui)
	-- Hide + zero scale so the shop OpenScale tween never reveals all 3 at once
	-- (first-open UIScale can briefly paint at 1 before Scale=0 sticks).
	forEachPackGraphic(sg, function(art, scale, _)
		scale.Scale = 0
		art.Visible = false
	end)
end

local function playGraphicIntros(sg: ScreenGui)
	cancelGraphicIntros()
	resetGraphicScales(sg)
	local my = graphicIntroToken
	forEachPackGraphic(sg, function(art, scale, i)
		scale.Scale = 0
		art.Visible = false
		local delaySec = (i - 1) * GRAPHIC_STAGGER_SEC
		task.delay(delaySec, function()
			if my ~= graphicIntroToken or not open or not scale.Parent or not art.Parent then
				return
			end
			scale.Scale = 0
			art.Visible = true
			local tw = TweenService:Create(scale, GRAPHIC_INTRO_INFO, { Scale = 1 })
			table.insert(graphicIntroTweens, tw)
			tw:Play()
		end)
	end)
end

local function cartButtonScreenCenter(): Vector2
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local btn = cartBtn
	if not (btn and btn.Parent) then
		return vp * 0.5
	end
	-- AbsolutePosition is inset-exclusive; store ScreenGui IgnoreGuiInset → add inset.
	local inset = GuiService:GetGuiInset()
	return btn.AbsolutePosition + btn.AbsoluteSize * 0.5 + inset
end

local function prepareContentPivot(content: Frame, scale: UIScale)
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local center = cartButtonScreenCenter()
	local ax = math.clamp(center.X / math.max(1, vp.X), 0, 1)
	local ay = math.clamp(center.Y / math.max(1, vp.Y), 0, 1)
	content.AnchorPoint = Vector2.new(ax, ay)
	content.Position = UDim2.fromScale(ax, ay)
	content.Size = UDim2.fromScale(1, 1)
	scale.Scale = 0
end

local function playShopOpenFromCart(sg: ScreenGui)
	cancelShopOpenTween()
	cancelGraphicIntros()
	resetGraphicScales(sg)
	local content = sg:FindFirstChild("Content")
	local scaleObj = content and content:FindFirstChild("OpenScale")
	if not (content and content:IsA("Frame") and scaleObj and scaleObj:IsA("UIScale")) then
		playGraphicIntros(sg)
		return
	end
	local contentFrame = content :: Frame
	local scale = scaleObj :: UIScale
	prepareContentPivot(contentFrame, scale)
	-- Re-assert after pivot: first enable can leave pack art visible for a frame.
	resetGraphicScales(sg)
	local my = shopOpenToken
	local tw = TweenService:Create(scale, SHOP_OPEN_INFO, { Scale = 1 })
	shopOpenTween = tw
	tw:Play()
	local conn: RBXScriptConnection? = nil
	conn = tw.Completed:Connect(function(playbackState)
		if conn then
			conn:Disconnect()
			conn = nil
		end
		if playbackState ~= Enum.PlaybackState.Completed then
			return
		end
		if my ~= shopOpenToken or not open then
			return
		end
		-- Resting layout: normal top-left origin so layout stays stable.
		contentFrame.AnchorPoint = Vector2.new(0, 0)
		contentFrame.Position = UDim2.fromScale(0, 0)
		scale.Scale = 1
		-- Defer one frame so AbsoluteSize is valid before staggered UIScale intros.
		task.defer(function()
			if my ~= shopOpenToken or not open then
				return
			end
			playGraphicIntros(sg)
		end)
	end)
end

local function startPanelStrokeCycle(stroke: UIStroke)
	stopPanelStrokeCycle()
	panelStroke = stroke
	local my = panelStrokeToken
	panelStrokeConn = RunService.Heartbeat:Connect(function()
		if my ~= panelStrokeToken or not open or not stroke.Parent then
			return
		end
		local u = (math.sin(os.clock() * math.pi * 2 * PANEL_STROKE_CYCLE_HZ) + 1) * 0.5
		stroke.Color = PANEL_STROKE_TEAL:Lerp(PANEL_STROKE_GREEN, u)
	end)
end

local function hardenStoreGui(sg: ScreenGui)
	-- Full-bleed over top bar / device safe area (same as Reef Report).
	sg.IgnoreGuiInset = true
	sg.ClipToDeviceSafeArea = false
	pcall(function()
		local anySg = sg :: any
		anySg.ScreenInsets = Enum.ScreenInsets.None
		anySg.SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
	end)
end

local function ensureStoreGui(): ScreenGui
	local existing = playerGui:FindFirstChild(STORE_GUI_NAME)
	-- Rebuild when layout is outdated (Content host + SHOP + stroke + intro scales).
	if existing and existing:IsA("ScreenGui") then
		local content = existing:FindFirstChild("Content")
		local title = content and content:FindFirstChild("Title")
		local panel = content and content:FindFirstChild("Panel")
		local openScale = content and content:FindFirstChild("OpenScale")
		local buyLbl = panel and panel:FindFirstChild("Label", true)
		local stroke = panel and panel:FindFirstChildOfClass("UIStroke")
		local introScale = panel and panel:FindFirstChild("IntroScale", true)
		local titleOk = title and title:IsA("TextLabel") and (title :: TextLabel).Text == "SHOP"
		local strokeOk = stroke and stroke:IsA("UIStroke") and stroke.Thickness >= PANEL_STROKE_THICK
		local verOk = existing:GetAttribute("LayoutVer") == STORE_LAYOUT_VER
		if titleOk
			and verOk
			and content
			and openScale
			and panel
			and panel:FindFirstChild("Offers")
			and buyLbl
			and strokeOk
			and introScale
		then
			hardenStoreGui(existing)
			storeGui = existing
			panelStroke = stroke :: UIStroke
			return existing
		end
	end
	if existing then
		existing:Destroy()
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = STORE_GUI_NAME
	sg.ResetOnSpawn = false
	sg.DisplayOrder = STORE_DISPLAY_ORDER
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Enabled = false
	sg:SetAttribute("LayoutVer", STORE_LAYOUT_VER)
	hardenStoreGui(sg)
	sg.Parent = playerGui

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.fromRGB(6, 10, 16)
	dim.BackgroundTransparency = 0.15
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = 1
	-- Don't steal clicks from the cart close chrome on MobileLeftUI (higher DisplayOrder).
	dim.Active = false
	dim.Parent = sg

	-- Scales up from the cart button; title + panel live inside.
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.Size = UDim2.fromScale(1, 1)
	content.Position = UDim2.fromScale(0, 0)
	content.AnchorPoint = Vector2.new(0, 0)
	content.ZIndex = 2
	content.Parent = sg
	local openScale = Instance.new("UIScale")
	openScale.Name = "OpenScale"
	openScale.Scale = 0
	openScale.Parent = content

	-- Title sits in the top gap above the panel (panel size/position unchanged).
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, 18)
	title.Size = UDim2.new(0.78, 0, 0, 40)
	title.Font = UiTheme.Font
	title.Text = "SHOP"
	title.TextSize = 36
	title.TextColor3 = Color3.fromRGB(230, 245, 255)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.ZIndex = 3
	title.Parent = content

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.78, 0.72)
	panel.BackgroundColor3 = Color3.fromRGB(14, 22, 32)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Active = true
	panel.Parent = content
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 18)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Name = "PanelStroke"
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Thickness = PANEL_STROKE_THICK
	stroke.Color = PANEL_STROKE_TEAL
	stroke.Transparency = 0
	stroke.Parent = panel
	panelStroke = stroke

	local offers = Instance.new("Frame")
	offers.Name = "Offers"
	offers.BackgroundTransparency = 1
	offers.AnchorPoint = Vector2.new(0.5, 0.5)
	offers.Position = UDim2.new(0.5, 0, 0.5, 0)
	offers.Size = UDim2.new(1, -56, 0.88, 0)
	offers.ZIndex = 3
	offers.Parent = panel

	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.HorizontalAlignment = Enum.HorizontalAlignment.Center
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, 28)
	row.Parent = offers

	for i, pack in ipairs(DOLLAR_PACKS) do
		local slot = Instance.new("Frame")
		slot.Name = "Col" .. tostring(i)
		slot.BackgroundTransparency = 1
		slot.BorderSizePixel = 0
		slot.Size = UDim2.new(1 / #DOLLAR_PACKS, -20, 1, 0)
		slot.LayoutOrder = i
		slot.ZIndex = 3
		slot.Parent = offers
		buildPackColumn(slot, pack, 4)
	end

	storeGui = sg
	return sg
end

local function canToggle(): boolean
	local now = os.clock()
	if now - lastToggleAt < TOGGLE_COOLDOWN then
		return false
	end
	lastToggleAt = now
	return true
end

function StoreUI.isOpen(): boolean
	return open
end

function StoreUI.close()
	if not open then
		return
	end
	lastToggleAt = os.clock()
	open = false
	playerGui:SetAttribute(STORE_OPEN_ATTR, false)
	stopPanelStrokeCycle()
	cancelShopOpenTween()
	cancelGraphicIntros()
	destroyCloseChrome()
	restoreLeftUi()
	popLeftHudFromStore()
	local sg = storeGui
	if sg then
		resetGraphicScales(sg)
		local content = sg:FindFirstChild("Content")
		local openScale = content and content:FindFirstChild("OpenScale")
		if content and content:IsA("Frame") then
			content.AnchorPoint = Vector2.new(0, 0)
			content.Position = UDim2.fromScale(0, 0)
		end
		if openScale and openScale:IsA("UIScale") then
			openScale.Scale = 0
		end
		sg.Enabled = false
	end
end

function StoreUI.open()
	if open then
		return
	end
	if playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
		return
	end
	playerGui:SetAttribute("OceanTD_ForceCloseReefReport", os.clock())
	playerGui:SetAttribute("OceanTD_ForceCloseSkills", os.clock())
	lastToggleAt = os.clock()
	open = true
	playerGui:SetAttribute(STORE_OPEN_ATTR, true)
	local sg = ensureStoreGui()
	hardenStoreGui(sg)
	sg.Enabled = true
	pushLeftHudForStore()
	if cartBtn then
		cartBtn.Visible = true
		cartBtn.ZIndex = math.max(cartBtn.ZIndex, 200)
	end
	hideLeftUiExceptCart()
	pushSeedWheelUnderStore()
	if panelStroke and panelStroke.Parent then
		startPanelStrokeCycle(panelStroke)
	else
		local content = sg:FindFirstChild("Content")
		local panel = content and content:FindFirstChild("Panel")
		local stroke = panel and panel:FindFirstChildOfClass("UIStroke")
		if stroke and stroke:IsA("UIStroke") then
			startPanelStrokeCycle(stroke)
		end
	end
	-- Expand shop from cart first; pack graphics start after that finishes.
	playShopOpenFromCart(sg)
	ensureCloseChrome()
	task.defer(function()
		if not open then
			return
		end
		if open then
			pushLeftHudForStore()
		end
		if cartBtn then
			cartBtn.Visible = true
			cartBtn.ZIndex = math.max(cartBtn.ZIndex, 200)
		end
		pushSeedWheelUnderStore()
		if not closeChrome or not closeChrome.Parent then
			ensureCloseChrome()
		end
	end)
end

function StoreUI.toggle()
	if not canToggle() then
		return
	end
	if open then
		StoreUI.close()
	else
		StoreUI.open()
	end
end

function StoreUI.bindCart(btn: GuiObject)
	cartBtn = btn
	ensureHitOverlay(btn)
end

function StoreUI.init()
	if inited then
		return
	end
	inited = true
	playerGui:SetAttribute(STORE_OPEN_ATTR, false)

	task.spawn(function()
		local left = playerGui:WaitForChild("MobileLeftUI", 60)
		if not left then
			warn("[StoreUI] PlayerGui.MobileLeftUI missing")
			return
		end
		LeftHudLayout.hardenScreenGui(left)
		if left:IsA("ScreenGui") then
			leftGui = left
			leftOrderBase = left.DisplayOrder
		else
			leftGui = left:FindFirstAncestorOfClass("ScreenGui")
			if leftGui then
				leftOrderBase = leftGui.DisplayOrder
			end
		end
		local dPad = left:WaitForChild("dPad", 30)
		if not dPad then
			warn("[StoreUI] MobileLeftUI.dPad missing")
			return
		end
		local cart = findCartButton(dPad)
		if cart then
			StoreUI.bindCart(cart)
		end
		LeftHudLayout.watchMobileLeftUi(playerGui, function(leftNow: Instance)
			local dPadNow = leftNow:FindFirstChild("dPad")
			if not dPadNow then
				return
			end
			local newCart = findCartButton(dPadNow)
			if newCart then
				StoreUI.bindCart(newCart)
				if open then
					ensureCloseChrome()
				end
			end
		end)
	end)

	playerGui:GetAttributeChangedSignal(FORCE_CLOSE_ATTR):Connect(function()
		StoreUI.close()
	end)
	playerGui:GetAttributeChangedSignal(SKILLS_OPEN_ATTR):Connect(function()
		if playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
			StoreUI.close()
		end
	end)
	playerGui:GetAttributeChangedSignal(REPORT_OPEN_ATTR):Connect(function()
		if playerGui:GetAttribute(REPORT_OPEN_ATTR) == true then
			StoreUI.close()
		end
	end)

	UserInputService.LastInputTypeChanged:Connect(function()
		if open then
			syncCloseLabel()
		end
	end)

	-- DPadUp / cart are owned by ReefReportUI (routes store vs reef report).
	-- X / B / Escape still close while store is open.
	UserInputService.InputBegan:Connect(function(input, _gameProcessed)
		if not open then
			return
		end
		if input.KeyCode == Enum.KeyCode.X
			or input.KeyCode == Enum.KeyCode.ButtonB
			or input.KeyCode == Enum.KeyCode.Escape
		then
			StoreUI.close()
		end
	end)
end

return StoreUI
